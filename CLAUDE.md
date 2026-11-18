# CLAUDE.md

Maintainer and agent notes. User-facing behaviour (install, permissions, usage, exit codes) is in `README.md`.

## Build, test, and dev loop

```sh
nix build                                       # binary, unit tests and the MIME conformance check (checkPhase)
nix flake check -L                              # same, plus shellcheck of the scripts; what CI runs
nix develop --command swift run sendmail-test   # iterate on the unit tests
```

There is no single-test selector. To focus on one suite, comment out the others in `Sources/sendmail-test/main.swift`.

`SENDMAIL_DRY_RUN=1 ./result/bin/apple-mail-sendmail -t < msg.eml` prints the step plan of the path the message takes (`EmlPlan`, or `PlainPlan` with `--no-ui`), one JSON object per line, and makes no Apple Event, Accessibility or Launch Services call. It still writes the `.eml` and attachment files.

CI runs `nix flake check -L` with `sandbox = false`, as on a default local macOS Nix install. Lint workflow edits with `nix run nixpkgs#actionlint -- .github/workflows/*.yml`; it does not read `dependabot.yml`, which `nix run nixpkgs#check-jsonschema -- --builtin-schema vendor.dependabot .github/dependabot.yml` validates.

The live end-to-end harness (`nix run .#e2e`) and its Tart VM wrapper (`nix run .#e2e-vm`) drive Mail.app: never run them without the user's go-ahead. Their guidance is in `tests/e2e/CLAUDE.md`. CI cannot run them (GitHub-hosted runners cannot grant Accessibility); the release cadence is in `RELEASING.md`, "Live end-to-end tests".

## Architecture

### Message pipeline

```
stdin bytes -> RFC822Parser -> MIMEParser -> ParsedMessage -> MailDriver -> MailAutomation
```

By default every message, plain text or HTML, takes the `.eml` path: `EmlBuilder.buildEml` applies the CLI overrides (To/Cc/Bcc/From) to the raw stdin headers and keeps the body bytes, `MailDriver` writes that `.eml`, and `AXEmlDelivery` runs `EmlPlan.steps` through Accessibility and Launch Services only, with no Apple Events. With `--no-ui` (`SENDMAIL_NO_UI=1`), `AppleEventPlainDelivery` instead sends Mail one raw Apple Event per `PlainPlan` step. The dry run prints the same plans the live run executes.

### The MailAutomation injection seam

The deliveries reach Mail only through narrow protocols: `AppleEventSending` for the `--no-ui` path, and `AXClient`, `MailWorkspace` and `Clock` (`MailUI.swift`) for the `.eml` path and for starting Mail. **Anything new that drives Mail.app goes behind these protocols**: never send an Apple Event or call AX or NSWorkspace directly, or the tests can't exercise it without launching Mail. Plain-path event tests pass `noUIOptions()`, since a plain message takes the `.eml` path by default.

### Tests never touch Mail

The `--no-ui` path's events go to `AppleEventRecorder` and the `.eml` path runs against `FakeMail`, a state machine of windows, focus, sheets and menus that act on the key window only while Mail is frontmost, with a clock that advances only when the code under test sleeps. So `checkPhase` needs no Mail, Automation or Accessibility grant.

### `--no-ui` sends raw Apple Events, and Mail quotes the body

**Mail sends a body set through its dictionary as a quotation** (FB11734014; live-verified 2026-11-18, macOS 27, Mail 16.0): `multipart/alternative`, every `text/plain` line prefixed with `> `, the HTML part in `<blockquote type="cite">`, however the content is set (at creation, after it, or with `default message format` set to plain first). A `text/plain` `.eml` sent through Send Again arrives clean and byte-faithful, so `--no-ui` is opt-in, for headless jobs that can grant Automation but cannot bring Mail to the front. Do not make it the default again unless the e2e scenario `plain-send-no-ui`, which asserts the quoting, starts failing because Apple fixed it. `--no-ui` with an HTML body is refused (`HTMLNeedsUI`, exit 64): no grant or Mail setting can make that invocation work, and 78 means "fix a permission" in this binary.

Event and property codes come from Mail's sdef (`/System/Applications/Mail.app/Contents/Resources/Mail.sdef`) and CocoaStandard. Text goes as text descriptors, so nothing needs escaping; `MailText.sanitized` still normalizes every value so the dry-run plan shows exactly what Mail gets.

Only `make_message` is retried (on -600 / -609 while a just-launched Mail is not answering yet). No later event is ever retried: once `make_message` has reached Mail, resending anything could make a second message or send twice. The first failed event stops the run, so a failed recipient never reaches `send`.

### MIME conformance check

`tests/conformance/differential.py` compares SendmailCore's parse of every corpus message (via `sendmail-test --parse-dump`, a test-target-only entry, so the shipped binary has no dump mode) with CPython's `email` package. `checkPhase` runs it after the unit tests, so `nix build` fails on an unclassified divergence, including one caused by a nixpkgs bump changing Python.

Every divergence must be listed in `tests/conformance/expected-divergences.json` under a finding classed `ours-bug`, `python-quirk` or `intentional`; an unlisted divergence, or a listed one that no longer occurs, fails the run. A fix for an `ours-bug` finding removes its cases (and the finding) in the same commit. `--emit-unexpected` prints new cases ready to paste into a finding, and `--show-all` prints the expected ones with both values. To run it directly:

```sh
nix develop --command swift build --product sendmail-test
nix develop --command python3 -I tests/conformance/differential.py --dump .build/debug/sendmail-test \
  --corpus tests/conformance/corpus --corpus "$(nix build --no-link --print-out-paths .#conformance-corpus)"
```

Leaving out the fetched corpus makes its expected cases report as stale.

`tests/conformance/corpus/` holds `rfc/` (RFC worked examples) and `local/` (the repo's own edge cases). Its files keep their exact bytes (CRLF variants, trailing whitespace in the quoted-printable vector; `.gitattributes` marks them `-text`), so edit them with a byte-preserving tool.

Third-party messages are fetched, not committed, by `.#conformance-corpus` (`conformanceCorpus` in `flake.nix`):

- `cpython/` comes from `pkgs.python3.src`, the Python the check runs, so a `flake.lock` bump that changes it shows up as stale or unexpected cases to reclassify.
- `mail-parser/` comes from `mailParserSrc`, a `fetchFromGitHub` pinned by `rev` and `hash`. To bump it, change `rev`, set `hash = pkgs.lib.fakeHash`, build `.#conformance-corpus` to get the real hash, then reclassify any new cases.

## Project-specific constraints (read before changing)

### Tests do not use XCTest

The Nix Swift toolchain on macOS does not ship the `xctest` helper binary, so `swift test` fails at the test-bundle link step with `FileSystemError ... path: "/private"`. The test target is an executable with a hand-written harness (`Sources/sendmail-test/TestHarness.swift`). Do not migrate it to XCTest or a `.testTarget`.

### CLI parser is hand-rolled, not swift-argument-parser

Sendmail compatibility needs bundled short flags (`-ti`, `-oi`, `-bm`, `-OFoo=bar`) and silently swallowing legacy flags, which `swift-argument-parser` does not handle. Don't add it: the package has zero SwiftPM dependencies, which keeps the flake hermetic (no `swiftpm2nix`).

### CRLF normalization in the header parser

Swift treats `"\r\n"` as a single `Character`. `RFC822Parser.unfold` normalizes `\r\n` to `\n` before splitting on `\n`; without it adjacent headers silently merge (regression test `RFC822Parser.crlf_separator`).

### Package.swift macOS floor is `.v13` deliberately

`.v13` was the lowest floor that linked cleanly under nixpkgs Swift 5.10, whose stdlib was built for macOS 14.0. Under the current Swift 6.4 toolchain `.v12` also builds without linker warnings, so lowering it further is a product decision, not a toolchain limit. Below 13 the `OSAllocatedUnfairLock` in `SystemMailUI.swift` needs replacing.

### Swift 6 language mode: the delivery path is nonisolated on purpose

Everything runs synchronously on the main thread; `SystemClock.sleep` pumps `RunLoop.current`, which is the main run loop only there. The one off-main hop is NSWorkspace's open completion handler, which runs on a concurrent queue: keep it `@Sendable` and nonisolated, never `@MainActor` (Swift 6 traps on that isolation mismatch at runtime). Marking `Clock` / `MailWorkspace` / `AXClient` `@MainActor` cascades through every delivery type, `MailDriver`, `PermissionCheck` and the test harness for no checked benefit, so they are left nonisolated.

### Draft is the product invariant

The default is **draft, not send**: the `.eml` plan has no Send press (`press_until_window_closes`), and the `--no-ui` plan makes the message `visible` with no `send` step, unless `options.send` is true. `--send` and `SENDMAIL_SEND=1` both set it; the env var is for callers (cron, scripts) that cannot easily change their argv.

### Messages go through `.eml` + Message > Send Again, not the dictionary

Mail's compose body is a WKWebView, and its AppleScript `content` setter accepts only `«class RTF »` and plain text: HTML, RTFD, WebArchive, `html content` and NSAttributedString are all rejected with -1700 (the full sweep is in `ATTEMPTS.md`), and plain text set through it goes out quoted (above). So the default path bypasses the dictionary: Mail opens the `.eml` as a viewer, and Message > Send Again turns it into a new editable compose with full WKWebView fidelity.

Send Again's compose is a fresh outgoing message (no `Resent-*` headers, no "Redirected by" banner), but it is not in the AppleScript `outgoing messages` collection, so nothing can be changed after Send Again: every override must be in the `.eml` before the open.

Both presses are `AXPress` on Mail's own menu item elements, never synthesized keystrokes, which go to whichever app is frontmost.

Facts and hazards behind `AXEmlDelivery`:

1. **Windows are found by AX element identity, never by title; the title only verifies the find.** Each wait diffs Mail's window list against a snapshot taken before the step and takes the one new `AXStandardWindow`. Title matching breaks on an empty, duplicate or rewritten Subject. Two or more new standard windows fail closed, but a stray window that appears alone still wins the diff, hence the title check. The leftover viewer is closed through its own close button, because the compose carries the same title.

   **Before each press the window's title must equal the decoded Subject** (whitespace collapsed, case kept). It is retried with the guard checks, since a compose may briefly be titled "New Message". Verified live (all 12 e2e scenarios, macOS 27 VM, when only HTML messages took this path): Mail titles both the `.eml` viewer and the compose exactly with the Subject. Not yet verified for a `text/plain` `.eml`. An empty Subject skips the check, because Mail shows a localized placeholder ("No Subject"). The compose's To field is not checked: Mail's address token fields have unknown, localized AX roles and descriptions. Still unverified: a Subject with folded whitespace, a leading `Re:`, or an encoded-word Mail decodes differently from `EncodedWord`; any difference fails closed. The run traces which check ran, and how each menu item was found, to the unified log (`log stream --predicate 'subsystem == "apple-mail-sendmail"'`), never to stdout or stderr, where cron would mail it.

   **`--send` needs a Subject, on both paths, and the binary refuses it up front** (`SendNeedsSubject`, before any Mail call; exit 65 because the input lacks something, while 64 is for the invocation). Mail holds a message with no Subject for a "This message has no subject. Send anyway?" confirmation (live, 2026-11-18, macOS 27). On the `.eml` path it is a sheet on the compose, and the binary never presses through a sheet. On the `--no-ui` path there is no window to show it: Mail keeps an invisible `outgoing message`, never sends it and leaves the Outbox empty, while `send` reports success, so without the refusal the binary would exit 0 with nothing delivered. A draft with no Subject works on both paths. `AXEmlDelivery` keeps its no-Subject sheet error as a backstop that `MailDriver` makes unreachable; the sheet's text is not read (it is localized). Do not "fix" this by confirming the sheet: answering Mail's prompts for the user is out of scope.

   **Every menu press runs the key-window guard first.** Mail's menu commands act on its KEY window, and shift-cmd-D is "Send Again" on a viewer but **"Send" on a compose**, so acting with the user's draft key would send it. Key can differ from main: with the Fonts panel open, AXFocusedWindow is "Fonts" (AXFloatingWindow) while AXMainWindow is the compose; with an Attach sheet open, AXFocusedWindow is the sheet. AXDocument is missing on every Mail window and AXIdentifier is not stable, so neither identifies a window. Mail must be frontmost: live (macOS 27 VM), with another app frontmost the item is absent from the menu. The plan's `"guard"` list is exactly what the driver checks, and the e2e templates compare it. What the guard does not cover: a message with no Subject (it trusts the diff), a stray window with the same title, and the check-then-act race.

   **Menu items are found by shortcut, so a localized Mail works.** Titles are translated ("Nachricht > Erneut senden"); key equivalents are not. Live (2026-11-18, macOS 27, English Mail): Send Again is "D" / modifiers 1, and Edit > Start Dictation is "D" / 24, which the exact modifier match rules out. A German Mail found both Send Again and Send by shift-cmd-D, and Send Again and Send were never enabled at once (FakeMail models them as mutually exclusive); if that changes, every run fails closed on the ambiguity.

   **A Send pressed right after Send Again can be ignored while Mail loads an attachment.** Live (macOS 27 VM): html+attachment `--send` with a single press failed 3 of 3, although the compose was frontmost, main, key and fully formed, and a manual Send seconds later worked. Hence the bounded Send retry while the compose stays open. **`AXPress` can return `kAXErrorCannotComplete` (-25204) even when it acted**, so only whether the compose is still open decides a retry. **Retrying is safe only because Mail closes the compose when it accepts Send**; if that ever stops holding, a retry would send twice. Send Again is never pressed twice.
2. **Accessibility is the only grant the `.eml` path needs**, and Automation is the only one `--no-ui` needs. The plan checks `AXIsProcessTrusted()` (no prompt) before touching Mail and exits 78. The pane name depends on the OS: `ProcessInfo` reports 27 on macOS 27 even for this SDK 14.4 build.

**Bcc stays blind on the `.eml` path.** `EmlBuilder` writes `Bcc:` into the `.eml`. Verified (2026-07-08, `View > Message > Raw Source` on a self-send with a marker Bcc): Send Again uses it as an envelope recipient and strips the `Bcc:` header from every transmitted copy, the Bcc recipient's included. No special handling or warning is needed.

**Attachments ride inside the `.eml`.** The plain plan's `add_attachment` steps run only with `--no-ui`, which sends the staged `att-NN-<name>` file; on the default path an attachment keeps its own name. Verified live (2026-07-09): a `multipart/mixed` html+attachment message arrived with the file attached (Mail nests the sent parts as `multipart/alternative` > `multipart/mixed`, oddly but validly); the e2e scenarios `plain-attachment-send` and `attachment-filename-plain` cover plain text. Do not force attachments onto the `--no-ui` path.

**A From with no `@domain`** (cron's `root (Cron Daemon)`) goes into the `.eml` as it is, and Mail then sends from its default account (verified live, macOS 27, Mail 16.0). With `--no-ui` it sets no sender.

### `--check-permissions`

It labels Accessibility "for every message" and Automation "only for --no-ui", but exits 78 unless both are granted, so a default-path user without Automation still gets 78. The report explains the responsible-process rule instead of naming the app: the only API that returns a process's responsible process (`responsibility_get_pid_responsible_for_pid`) is private, and walking parent pids is wrong for tmux, launchd jobs and apps that disclaim responsibility for their children. The binary cannot raise its own Automation prompt when its responsible process cannot show one (see README, "Checking the grants").

### Draft injection from outside Mail — reachable only by opening it through the UI, rejected for import churn

No mbox header, `.emlx` flag bit or Apple-internal header turns a message into an editable draft, and AppleScript `open <message>` gives a read-only viewer wherever the message lives. A message in the sending account's own Drafts mailbox does open as an editable compose through the UI, but getting it there takes `import Mail mailbox`, and every import leaves a stray "Import" / "Import-N" mailbox under On My Mac, which a sendmail transport must not do. The Drafts-mailbox UI-open row was probed 2026-11-18 on macOS 27 (Mail 16.0, build 3901.200.71.1.16) with POP accounts and a Mailpit SMTP capture.

| Approach | Result |
|---|---|
| `import Mail mailbox at <Apple .mbox bundle>` + `redirect m with opening window` | Editable compose with full WKWebView fidelity, recipients overridable. **But** `send` emits `Resent-From`/`Resent-To`/`Resent-Date` and keeps the source's `To:` verbatim (the override only reaches `Resent-To:`), confirmed via Raw Source on a probe send. Also leaves a sidebar mailbox per run. |
| `import` + `move <msg> to <account>/Drafts` + AppleScript `open <msg>` | Read-only viewer titled `<subject> — Drafts`, not a compose; `outgoing messages` stays 0. |
| `import` + `move <msg> to mailbox "Drafts" of account <sender>` + open through the UI (double-click, Return, or `File > Open Message`) | **Editable** compose with full fidelity; `Message > Send` sends a clean message (new `Message-Id`, no `Resent-*`, `X-Uniform-Type-Identifier` and `Bcc:` dropped, Bcc still delivered, attachment kept, draft removed). Not in `outgoing messages`. POP only; IMAP Drafts untested. **Rejected** for the stray import mailbox. |
| `Status: D` (mbox), `X-Status: T` (Thunderbird), `X-Mozilla-Status: 0040` | Stripped or ignored. |
| Apple `.emlx` with trailer plist `flags=64` (the draft bit) | Landed in nested `Import-N/<bundle>` as a regular message; the bit had no effect. |
| `X-Uniform-Type-Identifier: com.apple.mail-draft` (the UTI Mail stamps on real drafts) | Survives import and an IMAP round-trip, but AppleScript `open` still gives a read-only viewer (a UI open of the IMAP Drafts copy was not tried). |
| `redirect <window>` / `first message of window` on an `open -a Mail file.eml` viewer | Fails: standalone `.eml` viewers are generic windows with no `message` element, and `message viewers` lists only mailbox viewers. |
| Mail's `open <file>` verb on an `.eml` | Returns a `class` literal, not a message reference. |
| Open the `.eml` in Mail + Send Again on the viewer | **Works**, and is what the binary does: a new editable compose with the `.eml`'s headers and body, sent clean, no sidebar churn. Needs Accessibility (a keystroke without it fails with -1719, error number 1002). |

Drafts-route mechanics, so nobody re-derives them:

- `import Mail mailbox at` needs an Apple `.mbox` bundle (a directory containing a file named `mbox`); a plain mbox file is ignored.
- `move` into `mailbox "Drafts" of account <sender>`. The app-level `drafts mailbox` is the unified "All Drafts" view; a move into it does nothing.
- `set selected messages of message viewer 1` silently does nothing. Select through System Events instead (the `AXTable` described "messages", the row matched by subject, `set selected to true`), then open with Return or `File > Open Message`.

Do not re-investigate `redirect` or the Drafts-mailbox route as "primary path" candidates without re-reading this table and `ATTEMPTS.md`.

### Font preferences are not applied by this binary

WKWebView applies the HTML's own CSS and otherwise Mail's "Fonts & Colors" preferences; the binary reads no `com.apple.mail` defaults. HTML that wants specific fonts must declare them in its CSS.

## Packaging

The package's `src` is a fileset of `Package.swift` and `Sources/` (plus `tests/conformance` for the check), so editing other docs or `tests/e2e/` does not rerun the Swift tests. `packages.e2e`, `packages.e2e-vm` and `packages.release` only shellcheck their scripts when built; their `checks.*` put that in `nix flake check`.

The dev shell includes [Tart](https://tart.run) for the e2e VM. Nixpkgs marks it unfree, so `perSystem` admits only `tart` through `allowUnfreePredicate`; do not replace that with a blanket `allowUnfree`. The `tart` override sets `doInstallCheck = false`: on macOS 27, running `tart.app` inside a build tags the bundle with `com.apple.macl`, Nix then cannot register the output ("clearing flags of path ...: Operation not permitted"), and the invalid store path cannot be garbage-collected unless the Nix daemon has Full Disk Access. Never run a store `.app` during a build. Drop the override once `flake.lock` pins a nixpkgs with Tart 2.41.1 or newer.

## Releases

The version lives only in `PackageVersion.string` in `Sources/SendmailCore/Version.swift`. `flake.nix` extracts it with `builtins.match` and throws unless the line keeps its `public static let string = "X.Y.Z"` shape, so never write the version anywhere else.

`scripts/release.sh` (`nix run .#release -- prepare|tag X.Y.Z [--dry-run]`) cuts releases locally. `tag` finds the commit through the merged `release/vX.Y.Z` PR, and the notes leave out `release`-labelled PRs, so never use `release/` branch names or the `release` label for other work. Never run either mode without `--dry-run` unless the user asks for a release. Steps and recovery are in `RELEASING.md`.
