# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build, test, and dev loop

Tests are wired into the package's `checkPhase`, so a standard build runs them:

```sh
nix build               # builds binary + runs all unit tests
nix flake check         # same, plus evaluates other flake outputs
```

CI (`.github/workflows/ci.yml`) runs `nix flake check -L` on `macos-latest` for every PR and every push to `master`, with Nix installed by `DeterminateSystems/nix-installer-action` and `sandbox = false`, the default macOS Nix setting the suite is run under locally. Actions are pinned to full commit SHAs with the version in a comment, which Dependabot (`.github/dependabot.yml`, weekly `github-actions` updates labelled `cleanup`) keeps current; lint workflow edits with `nix run nixpkgs#actionlint -- .github/workflows/*.yml`, which also catches YAML errors in them (it does not read `dependabot.yml`; `nix run nixpkgs#check-jsonschema -- --builtin-schema vendor.dependabot .github/dependabot.yml` validates that).

For iterative work, enter the dev shell and use Swift directly:

```sh
nix develop
swift build                                   # builds the default product
swift run sendmail-test                       # runs the test executable
swift build --product apple-mail-sendmail     # build only the main binary
```

There is no single-test selector built in. To focus on one suite during
debugging, comment out the others in `Sources/sendmail-test/main.swift`.

End-to-end smoke test without touching Mail.app:

```sh
SENDMAIL_DRY_RUN=1 ./result/bin/apple-mail-sendmail -t < msg.eml
```

`SENDMAIL_DRY_RUN=1` makes the binary print what it would do instead of
doing it: the step plan of whichever path the message takes (`EmlPlan`, or
`PlainPlan` with `--no-ui`), one JSON object per line. It still writes the `.eml` and the
attachment files, and makes no Apple Event, Accessibility or Launch Services
call.
Useful when iterating on `MailDriver`.

The live end-to-end harness (`nix run .#e2e`, which drives Mail.app and must not be run without the user's go-ahead) and its Tart VM wrapper (`nix run .#e2e-vm`) have their own guidance in `tests/e2e/CLAUDE.md`. CI cannot run the live suite (GitHub-hosted runners cannot grant Accessibility), so it runs in the Tart VM before every release and the golden VM is rebuilt after a macOS or Mail update; the cadence is in `RELEASING.md`, "Live end-to-end tests".

## Architecture

Three SwiftPM targets, all under `Sources/`:

- `SendmailCore` (library) — all parsing and Mail automation logic; public API.
- `apple-mail-sendmail` (executable) — thin orchestrator (`main.swift`).
- `sendmail-test` (executable) — custom test runner. **Not** an XCTest target (see constraints below).

The split exists because the test runner needs to `import SendmailCore`. The thin executable just wires stdin and argv into the core pipeline and chooses a `MailAutomation`.

### Message pipeline

```
stdin bytes -> RFC822Parser -> MIMEParser -> ParsedMessage -> MailDriver -> MailAutomation
```

- `RFC822Parser.parse(Data)` produces `RawMessage` (ordered headers + raw body bytes; no MIME interpretation).
- `MIMEParser.parse(RawMessage)` interprets `Content-Type`, walks `multipart/*` parts, decodes `base64` / `quoted-printable` transfer encodings, and decodes RFC 2047 encoded-words in `Subject` and display names. Populates `htmlBody` from any `text/html` part alongside the stripped plain-text `body`.
- `MailDriver.deliver(...)` chooses the path, stages files in the temp dir, and hands the message to a `MailAutomation`: its `eml` delivery for every message by default, plain text or HTML, and its `plain` delivery only with `--no-ui` (`Options.noUI`, also `SENDMAIL_NO_UI=1`), which refuses a message with an HTML body (`HTMLNeedsUI`, exit 64; `main.swift` checks it through `MailDriver.requireDeliverable` before creating the temp dir). The .eml path is **pass-through**: `main.swift` constructs the .eml bytes via `EmlBuilder.buildEml(raw:finalRecipients:options:)` (raw stdin headers + body, with CLI flag-driven header overrides applied to To/Cc/Bcc/From), `MailDriver.deliver` writes them to a temp `.eml`, and `AXEmlDelivery` runs `EmlPlan.steps` through Accessibility and Launch Services, with no Apple Events: check Accessibility, start Mail if needed, open the `.eml` as a viewer, find the viewer by window diff (never by subject/title; the title only verifies the find before a press -- see the gotcha below), press Message > Send Again (found by its ⇧⌘D shortcut, so localized Mail works) after the key-window guard, which converts the viewer into a brand-new editable compose with full WKWebView fidelity, find the compose the same way, on `--send` press Message > Send on it with a bounded retry, and close the leftover viewer. A plain-text body goes out as written, as `text/plain`. The `--no-ui` path (`AppleEventPlainDelivery`) sends Mail one raw Apple Event per `PlainPlan` step: make the outgoing message, set its content, add each recipient and attachment, and send it on `--send`; Mail then sends the body quoted (see "`--no-ui` sends raw Apple Events, and Mail quotes the body" below).

### The MailAutomation injection seam

`MailDriver.deliver(_:emlBytes:options:tmp:automation:)` takes a `MailAutomation` (`Sources/SendmailCore/MailAutomation.swift`): a `PlainDelivery` and an `EmlDelivery`. `main.swift` builds `AppleEventPlainDelivery` over `SystemAppleEventSender` (`AppleEvents.swift`) and `AXEmlDelivery` over `SystemAXClient`, both with `SystemMailWorkspace` and `SystemClock` (`SystemMailUI.swift`); the dry run uses `PlainPlanPrinter` and `EmlPlanPrinter`. The deliveries reach Mail only through narrow protocols: `AppleEventSending` (send one event, get the reply) for the `--no-ui` path, and `AXClient`, `MailWorkspace` and `Clock` (`MailUI.swift`) for the .eml path and for starting Mail. In tests, `AppleEventRecorder` (`Sources/sendmail-test/AppleEventRecorder.swift`) records each event decoded into class, ID and typed parameters (`AEValue`: text, specifiers, insertion locations, file URLs, ...) and answers `make new outgoing message` with a message specifier, and `FakeMail` (`FakeMail.swift`) implements the .eml path's protocols as a state machine: windows, focus, sheets, menus that act on the key window and only while Mail is frontmost, and a clock that advances only when the code under test sleeps. `RecordingDeliveries.swift` has the test target's `MailDriver.deliver(..., recorder:eml:)`, `noUIOptions` and `plainSender` helpers; the plain-path event tests pass `noUIOptions()`, since a plain message takes the .eml path by default. **Anything new that drives Mail.app goes behind these protocols** — never send an Apple Event, call AX or NSWorkspace directly from new code, or the tests can't exercise it without launching Mail.app.

`FailureReport` (`FailureReport.swift`) turns a delivery error into the message `main.swift` prints and its exit code; the tests cover each mapping.

### Tests never touch Mail

The `--no-ui` path's events go to `AppleEventRecorder` and the .eml path runs against `FakeMail`, so `nix build .#default`'s `checkPhase` runs the full suite without Mail, WebKit, pandoc, an Automation grant or an Accessibility grant. Building and decoding descriptors (including coercing records to object specifiers) happens in-process and sends nothing.

### `--no-ui` sends raw Apple Events, and Mail quotes the body

**Mail sends a body set through its dictionary as a quotation** (FB11734014; live-verified 2026-11-18, macOS 27, Mail 16.0): `multipart/alternative`, every `text/plain` line prefixed with `> `, the HTML part wrapped in `<blockquote type="cite">`. It happens whether the content is set at creation, after it, or with Mail's `default message format` set to plain first, and the old AppleScript path had it too. A `text/plain` `.eml` sent through Message > Send Again arrives clean and byte-faithful, so every message takes the .eml path by default and this path runs only with `--no-ui`, for headless jobs that can grant Automation but cannot bring Mail to the front. Do not make it the default again unless the e2e scenario `plain-send-no-ui`, which asserts the quoting, starts failing because Apple fixed it. `--no-ui` with an HTML body is refused (`HTMLNeedsUI`, exit 64 `EX_USAGE`: no grant or Mail setting can make that invocation work, and 78 means "fix a permission" in this binary) rather than sent as its text part.

`AppleEventPlainDelivery` (`PlainPlan.swift`) sends one `NSAppleEventDescriptor` per `PlainPlan` step after `launch_mail`, the same events the old AppleScript compiled to, with codes from Mail's sdef (`/System/Applications/Mail.app/Contents/Resources/Mail.sdef`) and CocoaStandard:

| Step | AppleScript it replaces | Event | Parameters |
|---|---|---|---|
| `launch_mail` | (implicit in `tell application "Mail"`) | none: `NSWorkspace.openApplication`, not activated | — |
| `make_message` | `make new outgoing message with properties {subject, visible, sender}` | `core`/`crel` | `kocl` type `bcke`; `prdt` {`subj` text, `pvis` bool, `sndr` text only when a sender is set} |
| `set_content` | `set content of msg to ...` | `core`/`setd` | `----` property `ctnt` of msg; `data` the body text (no temp file) |
| `add_recipient` | `make new to/cc/bcc recipient at end of ... recipients with properties {address, name}` | `core`/`crel` | `kocl` `trcp`/`crcp`/`brcp`; `insh` insertion {`kobj` every same-class element of msg, `kpos` `end `}; `prdt` {`radd`, `pnam` only when non-empty} |
| `add_attachment` | `tell content to make new attachment with properties {file name: POSIX file ...} at after last paragraph` | `core`/`crel` | `kocl` `atts`; `insh` {`kobj` last `cpar` of `ctnt` of msg, `kpos` `afte`}; `prdt` {`atfn` file URL} |
| `send` | `send msg` | `emsg`/`send` | `----` msg |

`msg` is the object specifier Mail returns from `make_message`; a reply without one is an error before anything else is sent. Every event targets Mail by bundle ID, so Mail is started through NSWorkspace first (an event to a Mail that is not running fails with -600, procNotFound). A just-launched Mail can be running before it answers events, so `make_message`, and only it, is retried on -600 or -609 (connectionInvalid) with a growing pause (0.25 s doubling to 2 s, through the `Clock` seam) for up to 10 s (`readinessTimeout`), then fails with the last error. No later event is ever retried: once `make_message` has reached Mail, resending anything could make a second message or send twice. `SystemAppleEventSender` sends with `[.waitForReply, .canInteract]` (NSAppleScript's default) and an explicit 120s timeout, because the default and no-timeout flags are reported unreliable (rdar://21477694), and turns both a thrown error and a reply carrying `keyErrorNumber` into `AppleEventError`. The first failed event stops the run, so a failed recipient never reaches `send`.

Errors (`FailureReport`): -1743 keeps the Automation wording ("Mail.app automation denied. --no-ui drives Mail with Apple Events, which needs Automation for Mail: grant it in System Settings → Privacy & Security → Automation, or run without --no-ui, which needs Accessibility instead.") and exits 78 (`EX_CONFIG`); -600 says Mail is not running and exits 75 (`EX_TEMPFAIL`), since the event never reached Mail and a retry cannot send twice; any other event error names its code and exits 71. Mail's sdef gives `send` a boolean result: a reply whose result is boolean `false` fails with "Mail.app did not send the message: its send command returned false" and exits 71. A reply with no result, or one of another type, counts as success, as before: it says nothing about the send, and failing would make an MTA retry a message Mail may already have sent. The `--no-ui` path needs Automation for Mail, like the AppleScript it replaced, and no Accessibility: an event from the binary is charged to its responsible process (the terminal, or `tart-guest-agent` in the e2e VM).

Text goes to Mail as a text descriptor: there is no literal to escape, so a quote, backslash, line separator or control character in a subject, name or body cannot change the event. `PlainPlan.steps` still normalizes every text value it hands Mail (subject, content, sender, recipient names and addresses) with `MailText.sanitized`, so the dry-run plan shows exactly what Mail gets: CR and CRLF become LF, U+2028 and U+2029 become LF, and every other C0 control except tab and LF becomes a space; DEL, C1 controls and combining marks are kept. It works per Unicode scalar, as the old `AppleScript.quote` did, so a control fused with a combining mark into one `Character` is still mapped. This restores what the AppleScript plain path gave Mail through `AppleScript.quote` (removed in 9fea116), with two deliberate differences: `quote` kept CR (it wrote it as the `\r` escape, which AppleScript decodes back to CR), and the body never went through `quote` (the script read it verbatim from a temp file), so CR and controls in the body used to reach Mail unchanged.

### MIME conformance check

`tests/conformance/differential.py` parses every message in the corpus (see
below) with both SendmailCore (via `sendmail-test
--parse-dump FILE...`, a test-target-only entry, so the shipped binary has no
dump mode) and CPython's `email` package (`policy.default`), and compares the
decoded Subject, From, To/Cc/Bcc mailboxes, text/plain and text/html bodies,
and attachment filenames and decoded bytes. It also re-parses the `.eml`
`EmlBuilder` writes, checking that Python reads back the same recipients and
that no header line exceeds RFC 5322's 998 octets. Python
picks body and attachment parts by SendmailCore's own rules, so only the MIME
decoding is compared, not the part-selection policy.

Every divergence must be listed in `tests/conformance/expected-divergences.json`
under a finding classed `ours-bug`, `python-quirk` (the spec is on our side) or
`intentional`. An unlisted divergence or a listed one that no longer occurs
fails the run; `--emit-unexpected` prints new cases ready to paste into a
finding, and `--show-all` prints the expected ones with both values. A fix for
an `ours-bug` finding removes its cases (and the finding) in the same commit.

The package's `checkPhase` runs it after the unit tests, so `nix build` fails
on an unclassified divergence, including one caused by a nixpkgs bump changing
Python. To run it directly:

```sh
nix develop --command swift build --product sendmail-test
nix develop --command python3 -I tests/conformance/differential.py --dump .build/debug/sendmail-test \
  --corpus tests/conformance/corpus --corpus "$(nix build --no-link --print-out-paths .#conformance-corpus)"
```

Each `--corpus` is a root; messages are named by their path below it (e.g.
`cpython/msg_33.txt`), and the expectations file uses those names. Leaving out
the fetched corpus makes its expected cases report as stale.

The repo's corpus, `tests/conformance/corpus/`, holds `rfc/` (the RFC
2045/2046/2047/2231/5322/6532 worked examples) and `local/` (the repo's own edge
cases). Its files keep their exact bytes (CRLF variants, trailing whitespace in
the quoted-printable vector; `.gitattributes` marks them `-text`), so edit them
with a byte-preserving tool.

The third-party messages are fetched, not committed. `.#conformance-corpus`
(`conformanceCorpus` in `flake.nix`) builds a directory with:

- `cpython/`: CPython's `Lib/test/test_email/data/msg_*.txt`, extracted from
  `pkgs.python3.src`, the source of the very Python the check runs (PSF License).
  These move with the nixpkgs pin, so a `flake.lock` bump that changes them shows
  up as stale or unexpected cases to reclassify.
- `mail-parser/`: Stalwart mail-parser's `resources/eml/rfc/*.eml` (as
  `rfc-*.eml`) and `resources/eml/issues/98-*.eml` (as `issue-98-*.eml`), from
  `mailParserSrc`, a `fetchFromGitHub` pinned by `rev` and `hash` (Apache-2.0 OR
  MIT). To bump it, change `rev`, set `hash = pkgs.lib.fakeHash`, build
  `.#conformance-corpus` to get the real hash, then reclassify any new cases.

## Project-specific constraints (read before changing)

### Tests do not use XCTest

The Nix Swift toolchain on macOS does not ship the `xctest` helper binary, so `swift test` fails at the test-bundle link step with `FileSystemError ... path: "/private"`. We sidestep this by building an executable test target with a hand-written assertion harness (`Sources/sendmail-test/TestHarness.swift`). Do not migrate this to XCTest or a `.testTarget` — the build will break under Nix on darwin.

### CLI parser is hand-rolled, not swift-argument-parser

Sendmail compatibility requires bundled short flags (`-ti`, `-oi`, `-bm`, `-OFoo=bar`) and silently swallowing many legacy flags. `swift-argument-parser` does not handle that syntax. Don't add it — the cost is a few cases in `CLI.swift`, the payoff is zero SPM dependencies and a hermetic flake (no `swiftpm2nix`).

### CRLF normalization in the header parser

Swift treats `"\r\n"` as a single `Character` (grapheme cluster). `RFC822Parser.unfold` normalizes `\r\n` to `\n` on the header string before splitting on `\n`. Removing that normalization silently merges adjacent headers into the previous one. There is a regression test (`RFC822Parser.crlf_separator`).

### Package.swift macOS floor is `.v13` deliberately

`.v13` was chosen under nixpkgs Swift 5.10, whose stdlib dylibs were built for macOS 14.0: lower floors produced linker warnings that escalated to errors during test-bundle handling, and `.v13` was the lowest value that linked cleanly. Under the current Swift 6.4 toolchain, `.v12` also builds without linker warnings, so lowering the floor further is a product decision, no longer a toolchain limit.

### Draft is the product invariant

The .eml plan has no Send press (`press_until_window_closes`) unless `options.send` is true, and the `--no-ui` plain plan makes the message with `visible` true and has no `send` step unless it is. The default behavior is **draft, not send**. The `--send` flag and `SENDMAIL_SEND=1` environment variable both flip it; the env-var path exists for callers (cron, scripts) that cannot easily change their argv.

### Messages go through `.eml` + Message > Send Again, not the dictionary

Mail's compose body is a WKWebView. Its AppleScript dictionary `content` setter accepts only `«class RTF »` and plain-text byte formats — every other coercion class (HTML, RTFD even with valid bytes, WebArchive, the deprecated `html content` property, AppKit-bridge NSAttributedString) is rejected with -1700. The full 26-class empirical sweep is recorded in `ATTEMPTS.md`.

The viable path for full HTML fidelity is to **bypass the dictionary entirely**, and the same path is the only one on which a plain-text body is not sent quoted (see "`--no-ui` sends raw Apple Events, and Mail quotes the body" above), so every message takes it unless `--no-ui` is given. `AXEmlDelivery` (`Sources/SendmailCore/AXEmlDelivery.swift`) executes `EmlPlan.steps` (`EmlPlan.swift`), which the dry run prints, so the printed plan is what a live run does. It sends no Apple Events: only Accessibility (AX) and Launch Services (NSWorkspace).

1. `MailDriver` writes the rfc822 bytes (raw stdin headers + body, with CLI flag overrides applied via `EmlBuilder`) to a temporary `.eml`.
2. Check Accessibility. Start Mail without activating it if it is not running (`NSWorkspace.openApplication`, `activates = false`), wait up to 10s for its AX window list to answer, then snapshot its windows once the list has stayed the same for 0.6s (at most 5s), so session-restored windows count as "before".
3. `NSWorkspace.open([eml], withApplicationAt: Mail)` with `activates = true` opens it as a Mail viewer window, rendered in WKWebView. Waiting for Launch Services' completion handler needs the main run loop, which `SystemClock.sleep` runs.
4. Press Message > Send Again with `AXPress` once the key-window guard passes. The item is found by its ⇧⌘D shortcut, not its title, so a localized Mail works (see "Menu items are found by shortcut" below). On a standalone .eml viewer it spawns a brand-new editable compose with the .eml's `From` / `To` / `Subject` / body all carried into the compose. Pressing a menu item element can only reach Mail, whereas a synthesized keystroke goes to whichever app is frontmost. But Mail must still be frontmost: live (macOS 27 VM), with another app frontmost the item is absent from the menu, and pressing it by name does nothing.
5. With `--send`, press Message > Send on the compose, after waiting for the item to be enabled, with a bounded retry while the compose stays open (see the gotchas).
6. Press the leftover viewer's close button (`kAXCloseButtonAttribute`) and wait up to 2s for it to go. Best effort: by then the message is in its compose or sent, so a viewer left open does not fail the run.

The compose is a fresh outgoing message from Mail's perspective — no `Resent-*` headers on the wire, no "Redirected by" banner. The CLI flag overrides MUST be applied to the .eml before the open because the compose window is not addressable via the AppleScript `outgoing messages` collection after Send Again — Mail doesn't surface it to dictionary scripting.

Two non-obvious gotchas:

1. **Windows are found by AX element identity, never by title; the title only verifies the find.** Each wait diffs Mail's `kAXWindowsAttribute` against the snapshot taken before the step, with `CFEqual` as the identity (`UIElement` hashes through it), and takes the one new window whose subrole is `AXStandardWindow`. Titles are never used to find a window: a message with no `Subject`, a duplicate subject, or a title Mail rewrites would all break title matching (under the old AppleScript, an empty subject matched nothing and the poll timed out). Sheets (e.g. the Attach sheet) are AX children of their window with role `AXSheet`, not top-level windows, and panels have other subroles, so neither counts. If two or more new standard windows appear at once it fails closed ("Mail opened more than one new window ...; refusing to guess") instead of taking the first. A stray standard window that appears alone, or one poll before ours, still wins the diff (#33), so before each press the window's contents are checked (below). The leftover viewer is closed through its own element's close button, so the compose window, which carries the same subject, cannot be hit.

   **Before each press, the window must show this message** (the plan's `"verify":["title_matches_subject"]` on `press_menu_item` and `press_until_window_closes`). `MailDriver` hands `AXEmlDelivery` the message's decoded Subject (`msg.subject`, RFC 2047 already decoded by `MIMEParser`), and inside the guard loop, after the key-window checks pass, the target's `kAXTitleAttribute` must equal it, both normalized by `WindowCheck.normalizedTitle` (every run of whitespace, newlines and tabs included, collapsed to one space, ends trimmed) and compared exactly, case included. Like the guard checks it is retried until the guard timeout (a compose may briefly show "New Message" before taking the subject); at the deadline it fails closed without a press, naming the field and both values: "The compose window does not show this message, so it may be a stray window and not ours; the Message > Send press was not sent: the compose window's title (AXTitle) is "New Message", but the message's Subject is "..."". An unreadable title fails the same way. **An empty (or all-whitespace) Subject skips the check**: Mail titles that window with a localized placeholder ("No Subject" on the viewer, which a German Mail translates), so the window diff alone identifies it, and the run traces "the message has no Subject, ... its title is not checked" through `AXEmlDelivery`'s `trace` closure, which `main.swift` sends to the unified log (subsystem `apple-mail-sendmail`, category `eml`; `log stream --predicate 'subsystem == "apple-mail-sendmail"'`), never to stdout or stderr, where cron would mail it. The compose's To field is **not** checked: Mail's address fields are token fields whose AX roles and descriptions (which are localized) are unknown here, so a reliable lookup could not be written against FakeMail; title only. Verified live (all 12 e2e scenarios, macOS 27 VM, when only HTML messages took this path): Mail titles both the standalone `.eml` viewer and the compose exactly with the Subject, and an empty Subject skips the check as designed. Not yet verified for a `text/plain` `.eml`, which now takes the same path. Still unverified: how Mail displays a Subject with folded whitespace, a leading `Re:`, or an encoded-word Mail decodes differently from `EncodedWord`; any difference fails closed.

   **`--send` needs a Subject, plain text and HTML alike, and this stays fail-closed.** On a compose with no Subject, Message > Send makes Mail open a "This message has no subject. Send anyway?" sheet (live, 2026-11-18) instead of sending. The binary never presses through a sheet, so the run fails with exit 71 and the compose stays open as a draft. When the Subject is empty and a sheet appears after the Send press, the error says why: "Mail is asking to confirm sending a message with no Subject (a sheet opened on the compose window after the Message > Send press); it is not confirmed, and the message was not sent. --send needs a Subject: add a non-empty Subject header, or leave out --send to get a draft". Plain messages used to reach Mail through Apple Events, which never showed this sheet, so a subjectless plain `--send` that used to go out now stops as a draft; whether `--no-ui` still sends one without asking is unverified. The sheet's text is not read (it is localized), so with a non-empty Subject any sheet still gets the generic "A sheet is open on the compose window after the Message > Send press ..." error. Do not "fix" this by confirming the sheet: answering Mail's prompts on the user's behalf is out of scope. A draft (no `--send`) with no Subject works.

**Every menu press runs the key-window guard first.** Mail's menu commands act on its KEY window, not on a window we name -- and ⇧⌘D is "Send Again" on a viewer but **"Send" on a compose window**, so acting with the user's draft key would send it. Key can differ from main: with the Fonts panel (Cmd-T) open, AXFocusedWindow is "Fonts" (subrole AXFloatingWindow) while AXMainWindow is the user's compose; with an Attach sheet open on the compose, AXFocusedWindow is the sheet. AXDocument is missing on every Mail window and AXIdentifier ("Mail.messageViewer.window.N", "_NS:41") is not stable, so neither can identify a window.

So for up to 3s the driver raises the target (its `kAXMain` = true, `kAXRaiseAction`, then the app's `kAXFrontmost` = true), and requires, in order: the target is still in Mail's window list (otherwise "The ... window closed before the ... press"); Mail is frontmost (`kAXFrontmost`); `kAXFocusedWindow` is the target; `kAXMainWindow` is the target; the target is an `AXStandardWindow`; it has no `AXSheet` child; its title matches the Subject (above); and the menu item, looked up afresh through `kAXMenuBarAttribute` (by shortcut, else by English title; see below), exists and is enabled. Only then is the item pressed, once. A failed check re-raises and retries; at the deadline it throws "The ... window did not pass the key-window check within 3s; the Message > ... press was not sent. Last failed check: ...", and nothing is pressed unverified. The plan lists the checks (`"guard":[...]`) and the driver runs exactly that list, so a plan that drops one no longer matches the e2e templates. Every AX call has a 2s messaging timeout (`AXUIElementSetMessagingTimeout`), and an unreadable window list counts as the target still being open. What this does NOT guarantee:
- **It trusts the window diff for a message with no Subject**, and for a stray window that happens to carry the same title (e.g. a second viewer of the same message). Otherwise a window the diff picked by mistake (#33) is refused by the title check.
- **Check-then-act race.** The checks narrow the gap to a few AX round-trips but cannot close it.

Send Again is never pressed twice: if no compose appears within 5s, the run fails with "Compose window did not appear after Send Again within 5s".

**Menu items are found by shortcut, so a localized Mail works.** Titles are translated ("Nachricht > Erneut senden" in German), but key equivalents are not. Each press names a `MenuItemTarget` (`EmlPlan.swift`): a shortcut plus an English fallback title. `AXEmlDelivery.resolve` reads the items of every top-level menu-bar menu (not just one titled "Message"; submenus are not searched) and keeps those that are enabled and whose `kAXMenuItemCmdCharAttribute` is exactly "D" and `kAXMenuItemCmdModifiersAttribute` exactly 1 (Shift; Command is implied unless bit 8 is set). Exactly one: press it. Two or more: fail closed ("Mail has N enabled menu items with the shift-cmd-D shortcut; refusing to guess ..."), nothing pressed. None: fall back to the English title path (menu "Message", item by title), which on a localized Mail finds nothing and the guard times out without pressing. The lookup runs again right before every press, and in the Send readiness poll. Live (2026-11-18, macOS 27, English Mail, `.eml` viewer front): Message > Send Again is "D" / 1, and Edit > Start Dictation is "D" / 24, which the exact modifier match rules out. Verified live: a German Mail found both Send Again and Send by ⇧⌘D, so Message > Send is "D" / 1 with a compose in front, and no run hit the ambiguity, so Send Again and Send were never both enabled at once (FakeMail models them as mutually exclusive: Send Again enabled only with a viewer key, Send only with a compose key); if that ever changes, every HTML run fails closed on the ambiguity. The dry-run plan prints the target as `"item":{"fallback_menu":"Message","fallback_title":"Send Again","shortcut":"shift-cmd-D"}`, and the live run logs which way each item was found ("found by its shift-cmd-D shortcut" or "found by its English title") through the `trace` closure, which `main.swift` sends to the unified log (subsystem `apple-mail-sendmail`, category `eml`; `log stream --predicate 'subsystem == "apple-mail-sendmail"'`), never to stdout or stderr, where cron would mail it.

**A Send pressed right after Send Again can be ignored while Mail loads an attachment.** Live (macOS 27 VM, under the earlier AppleScript path), html+attachment `--send` failed 3 of 3 with a single click: once because the Message menu had not been rebuilt yet, twice with the compose still open after the click, although Mail was frontmost, the compose was main and key and fully formed, and a manual Message > Send a few seconds later sent it at once. So `--send` makes up to 3 presses while the compose is open. Each waits up to 10s for Message > Send to exist and be enabled, runs the full guard, presses, then polls ~3s for the compose element to leave the window list. If the compose is still open with a sheet on it (e.g. a Mail warning), it fails at once rather than press through it. After the third press it fails with "Send did not complete: the compose window is still open after 3 Message > Send presses". **`AXPress` can return `kAXErrorCannotComplete` (-25204) even when it acted**, so the press result never decides a retry: only whether the compose is still open does. **Retrying is safe only because Mail closes the compose window when it accepts Send**, so an open compose means the press was not taken; if that ever stops holding, a retry would send twice. A compose that closes while a later attempt is waiting, after at least one press, counts as sent; one that closes before the first press is an error.
2. **Accessibility permission is a hard requirement** for the calling process, and the only one on the .eml path: it sends no Apple Events, so it needs no Automation grant for Mail or System Events. The plan's first step checks it with `AXIsProcessTrusted()` (no prompt) before Launch Services or AX touch Mail, and throws `AccessibilityNotGranted`, which `main.swift` prints and exits 78 (`EX_CONFIG`). The message names **System Settings > Privacy & Security > Device Control and Data Access** on macOS 27 and later (Apple renamed the pane) and **... > Accessibility** before that, by `ProcessInfo`'s major version (which reports 27 on macOS 27 even for this SDK 14.4 build). TCC charges the grant to the responsible process (the terminal, or `tart-guest-agent` in the e2e VM). No silent fallback — if Accessibility is denied, the .eml path fails fast, for plain and HTML messages alike; the message points plain-text callers at `--no-ui`.

The `--no-ui` path does NOT require Accessibility — only Automation for Mail.

### `--check-permissions`

`--check-permissions` (`InfoRequest.checkPermissions`; like `--help` it wins over the rest of argv and reads no stdin) runs `PermissionCheck.run` (`PermissionCheck.swift`) and prints its `PermissionReport`: Accessibility via `AXIsProcessTrusted()`, then, after starting Mail without activating it (`MailWorkspace.ensureMailRunning`, as both paths do), Automation via `AEDeterminePermissionToAutomateTarget(com.apple.mail, typeWildCard, typeWildCard, askUserIfNeeded: true)`, which prompts when macOS can. -600 and -609 from a just-launched Mail are polled for up to 10 s. Its report labels Accessibility "for every message" and Automation "only for --no-ui". It exits 0 only when both are granted, 78 otherwise (so a default-path user without Automation still gets 78) (also when Mail would not start or answer), and lists a fix for each missing grant: the Accessibility pane by OS version (`AccessibilityNotGranted.settingsLocation`), and Privacy & Security > Automation, where an app appears only after macOS has asked it. The two probes sit behind `PermissionProbe` (`SystemPermissionProbe` in production); tests use a fake probe with `FakeMail` as workspace and clock, so they never touch AX or Apple Events. With `SENDMAIL_DRY_RUN=1` it refuses (exit 64), because it launches Mail and may prompt.

The report explains the responsible-process rule instead of naming the app: the only API that returns a process's responsible process (`responsibility_get_pid_responsible_for_pid`) is private, and walking parent pids is wrong for tmux, launchd jobs and apps that disclaim responsibility for their children.

Before first use from cron, launchd or another non-interactive launcher, run `apple-mail-sendmail --check-permissions` once from Terminal, or grant the launching app the listed permissions: the binary cannot raise its own Automation prompt when its responsible process is not an app that can show one. Verified live: under a VM guest agent it got -1743 with no prompt, with or without an embedded `Info.plist`. The default .eml path needs only Accessibility; `--no-ui` needs only Automation for Mail. A grant belongs to the responsible process it was made for, so one made from Terminal does not cover a launcher that is its own responsible process.

**Bcc stays blind on the .eml path.** `EmlBuilder` serializes `Bcc:` as a plain rfc822 header into the `.eml`. Verified empirically (2026-07-08, via `View > Message > Raw Source` on a self-send with a marker Bcc address): Mail's Send Again consumes it as an envelope recipient and strips the `Bcc:` header from every transmitted copy — including the Bcc recipient's own — while still delivering to it. No special handling is needed and no warning should be emitted; this matches the `--no-ui` path's dedicated bcc-recipient objects.

**Attachments ride inside the `.eml`.** Every message routes to the .eml path unless `--no-ui` is given, so the plain plan's `add_attachment` steps run only with `--no-ui`, and an attachment keeps its own name on the wire (the `--no-ui` path sends the staged `att-NN-<name>` file). The attachment is NOT lost -- it rides inside the raw `.eml` that Send Again reconstructs. Verified live (2026-07-09): a `multipart/mixed` html+attachment message arrived with the file attached (Mail nests the sent parts as `multipart/alternative` > `multipart/mixed`, a little oddly but valid). So `add_attachment` not running on the default path is expected, not a bug; do not "fix" it by forcing attachments onto the `--no-ui` path. A plain+attachment `.eml` (`multipart/mixed`) is expected to arrive the same way; the e2e scenarios `plain-attachment-send` and `attachment-filename-plain` check it live.

### Draft injection from outside Mail — reachable only by opening it through the UI, rejected for import churn

No mbox header, `.emlx` flag bit, or Apple-internal header turns a message into an editable draft, and AppleScript `open <message>` gives a read-only viewer wherever the message lives. A message in the sending account's own Drafts mailbox does open as an editable compose when it is opened through the UI (double-click, Return, or `File > Open Message`). That route works on the wire but is **rejected**: getting a message into Drafts takes `import Mail mailbox`, and every import leaves a stray "Import" / "Import-N" mailbox under On My Mac in the user's sidebar, which a sendmail transport must not do. Probe scripts were in `/tmp/import-redirect-probe/` during session work; the Drafts-mailbox UI-open row was probed 2026-11-18 on macOS 27 (Mail 16.0, build 3901.200.71.1.16) with POP accounts and a Mailpit SMTP capture.

| Approach | Result |
|---|---|
| `import Mail mailbox at <Apple .mbox bundle>` + `redirect m with opening window` | Mechanically works — creates an editable compose with full WKWebView body fidelity (real bordered tables, `<pre>` Menlo+grey, inline red italic). Subject, To/Cc/Bcc programmatically overridable. **But** `send` emits `Resent-From`/`Resent-To`/`Resent-Date` on the wire AND preserves the source mbox's `To:` header verbatim (the post-redirect `to recipients` override only flows into `Resent-To:`). Recipient sees "redirected from X" semantics; unsuitable for sendmail's "fresh outgoing" expectation. Also leaves a top-level mailbox in Mail's sidebar per invocation that needs cleanup. |
| `import` + `move <msg> to <account>/Drafts` + AppleScript `open <msg>` | Move succeeds (synced over IMAP). `open` spawns a read-only viewer titled `<subject> — Drafts` (Reply/Forward/Redirect buttons), NOT an editable compose. `outgoing messages` count remains 0; the window has no addressable `message` element. |
| `import` + `move <msg> to mailbox "Drafts" of account <sender>` + open through the UI (double-click, Return, or `File > Open Message` on the selected row) | Opens an **editable** compose titled just the subject, with full WKWebView fidelity (`<style>` classes, inline styles, table borders and padding, `<pre>` background, 24px div padding). `Message > Send` sends a clean message: new `Message-Id`, no `Resent-*`, `X-Uniform-Type-Identifier` dropped, `Bcc:` stripped while the Bcc recipient still receives it, attachment kept, draft removed from Drafts. The compose is not in `outgoing messages`. POP only; IMAP server-side Drafts untested. **Rejected** for the stray import mailbox each send leaves behind (see below). |
| `Status: D` (mbox), `X-Status: T` (Thunderbird), `X-Mozilla-Status: 0040` (Mozilla draft bit) | Either stripped during import or preserved-but-ignored. No effect on draft recognition. |
| Apple `.emlx` format with trailer plist `flags=64` (the draft bit, instead of Berkeley `mbox` inside the bundle) | Imported but landed in nested `Import-N/<bundle>` and treated as a regular message when opened with AppleScript `open`. flags bit had no effect. |
| `X-Uniform-Type-Identifier: com.apple.mail-draft` in rfc822 headers — the UTI Mail itself stamps on real drafts | Header survives import AND IMAP round-trip to a hosted IMAP provider's Drafts folder intact. AppleScript `open` still gives a read-only viewer; a UI open of that IMAP Drafts message was not tried. On a send from the POP Drafts route, Mail drops the header. |
| `redirect <window>` / `first message of window` on a standalone .eml viewer opened via `open -a Mail file.eml` | "window doesn't understand the redirect message" / "Can't get message 1 of window". Standalone .eml viewers register as generic `class=window` with no `message` element; `message viewers` enumerates only mailbox-list viewers. |
| Mail's `open <file>` AppleScript verb on an .eml path | Returns a `class` literal (not a message reference). No usable handle on the opened message. |
| `open -a Mail <eml-path>` + UI-script `keystroke "d" using {shift down, command down}` on the viewer | ✅ **Works.** Triggers Mail's "Send Again" command, which spawns a brand-new editable compose carrying the .eml's `To` / `Subject` / `From` / body in full WKWebView fidelity. Sends as a clean message — no `Resent-*` headers. No sidebar mailbox churn. Requires **Accessibility** permission for the controlling process; without it, `keystroke` fails with `-1719 ("not allowed assistive access")` / error number 1002. The binary now invokes the same command as a `Message > Send Again` menu click rather than a keystroke. |

The converted compose does NOT appear in the `outgoing messages` collection — AppleScript dictionary cannot drive it post-conversion. So everything (recipients, subject, sender, body, attachments) must be baked into the source `.eml` **before** the open; we never override anything after Cmd-Shift-D fires.

Send-on-`--send` for the .eml path is an `AXPress` on Message > Send for the freshly-opened compose. Pressing the menu item element (found by its shortcut, then pressed) reaches only Mail, unlike a synthesized keystroke. Both presses (Send Again and Send) require Accessibility permission.

`redirect` is intentionally avoided: the wire-level Resent-* leak is real and was confirmed end-to-end via `View > Message > Raw Source` on a probe send to the maintainer's own address.

The Drafts-mailbox route is also rejected, for sidebar churn rather than wire shape. Mechanics, so nobody re-derives them:

- `import Mail mailbox at` needs an Apple `.mbox` bundle (a directory containing a file named `mbox`); a plain mbox file is ignored. Every import leaves an "Import" / "Import-N" mailbox under On My Mac.
- `move` the message into `mailbox "Drafts" of account <sender>`. The app-level `drafts mailbox` property is the unified "All Drafts" view; a move into it does nothing.
- `set selected messages of message viewer 1` silently does nothing. Select through System Events instead: the `AXTable` whose description is "messages", the row matched by its subject text, `set selected to true`; Mail's `selected messages` then follows. Then open via Return or `File > Open Message`, and click `Message > Send` for `--send` -- the same Accessibility requirement as Send Again.

Do not re-investigate `redirect` or the Drafts-mailbox route as "primary path" candidates without re-reading this table and ATTEMPTS.md.

### Font preferences are not applied by this binary

The .eml + Cmd-Shift-D path renders bodies in Mail's WKWebView, which honors any CSS the HTML supplies and otherwise inherits Mail's "Fonts & Colors" preferences automatically. The binary does not read `com.apple.mail` defaults; no `MailFontPrefs` type exists. If the source HTML wants specific fonts, declare them in the inline CSS.

## Packaging

`flake.nix` uses flake-parts. The package factory is wrapped in `pkgs.lib.makeOverridable` and takes `withSendmailSymlink ? true`. Its `src` is a `lib.fileset` of `Package.swift` and `Sources/` only, so editing docs or `tests/e2e/` does not rebuild the Swift binary or rerun its tests. Named packages:

- `packages.default` — installs `apple-mail-sendmail` plus a `sendmail` symlink.
- `packages.without-sendmail-symlink` — canonical binary only.
- `packages.e2e` (also `apps.e2e`, and `checks.e2e-shellcheck` so `nix flake check` shellchecks it) — the live end-to-end harness. Building it only shellchecks `tests/e2e/e2e.sh`; it never runs in `checkPhase`.
- `packages.e2e-vm` (also `apps.e2e-vm`, and `checks.e2e-vm-shellcheck`) — `tests/e2e/vm.sh`, which runs the harness in a Tart VM. Building it only shellchecks the script.
- `packages.release` (also `apps.release`, and `checks.release-shellcheck`) — `scripts/release.sh`, which opens a release PR and tags it once merged (see Releases below). Building it only shellchecks the script.

Consumers from other flakes can also call `self.packages.${system}.default.override { withSendmailSymlink = false; }`.

`meta.mainProgram = "apple-mail-sendmail"`, so `nix run` always invokes the canonical name even though both names are on `PATH` in the `default` package.

Tests run in the package's `checkPhase`, not as a separate test derivation; `checks.default` is the package itself, so both `nix build .#default` and `nix flake check` fail when tests fail.

The dev shell includes [Tart](https://tart.run) for the VM-based e2e runs. Nixpkgs marks Tart unfree (FSL-1.1), so `perSystem` sets `_module.args.pkgs` to a nixpkgs import whose `allowUnfreePredicate` admits only `tart`; do not replace that with a blanket `allowUnfree`. The `tart` binding in `flake.nix` overrides the pinned nixpkgs package to 2.42.0 (2.41.1 fixed `tart exec` dropping large output, openai/tart#1347) with `doInstallCheck = false`: on macOS 27, running `tart.app` inside the build tags the bundle with `com.apple.macl`, and Nix then fails to register the output ("clearing flags of path ...: Operation not permitted"), leaving an invalid store path that macOS's app-bundle protection also stops `nix store gc` from deleting unless the Nix daemon has Full Disk Access. Never run a store `.app` during a build. Drop the override once `flake.lock` pins a nixpkgs with Tart 2.41.1 or newer.

## Releases

The version lives only in `PackageVersion.string` in `Sources/SendmailCore/Version.swift`. `CLI.versionText` interpolates it, and `flake.nix` extracts the package version from that line with `builtins.match` (throwing if the line is missing or not `X.Y.Z`), so keep its `public static let string = "X.Y.Z"` shape and never write the version anywhere else. versionCheckHook confirms the built binary's `--version` matches.

Releases are cut locally with `scripts/release.sh`, not by CI. `nix run .#release -- prepare X.Y.Z [--dry-run]` opens the release PR from `release/vX.Y.Z`; after it merges, `nix run .#release -- tag X.Y.Z [--dry-run]` pushes the annotated tag `vX.Y.Z` on the PR's merge commit and creates the GitHub release with notes grouped by `.github/release.yml`. `release/` branch names and the `release` label are reserved for release PRs: never use them for other work, because `tag` finds the commit to tag through the merged `release/vX.Y.Z` PR and the notes leave out `release`-labelled PRs. Policy, steps and failure recovery are in `RELEASING.md`. Never run either mode without `--dry-run` unless the user asks for a release.
