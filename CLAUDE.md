# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build, test, and dev loop

Tests are wired into the package's `checkPhase`, so a standard build runs them:

```sh
nix build               # builds binary + runs all unit tests
nix flake check         # same, plus evaluates other flake outputs
```

CI (`.github/workflows/ci.yml`) runs `nix flake check -L` on `macos-latest` for every PR and every push to `master`, with Nix installed by `DeterminateSystems/nix-installer-action` and `sandbox = false` so the AppleScriptCompile suite runs instead of skipping. Actions are pinned to full commit SHAs with the version in a comment; lint workflow edits with `nix run nixpkgs#actionlint -- .github/workflows/*.yml`.

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

`SENDMAIL_DRY_RUN=1` makes the binary print the generated AppleScript to
stdout instead of executing it. Useful when iterating on `MailDriver`.

The live end-to-end harness (`nix run .#e2e`, which drives Mail.app and must not be run without the user's go-ahead) and its Tart VM wrapper (`nix run .#e2e-vm`) have their own guidance in `tests/e2e/CLAUDE.md`.

## Architecture

Three SwiftPM targets, all under `Sources/`:

- `SendmailCore` (library) — all parsing and AppleScript logic; public API.
- `apple-mail-sendmail` (executable) — thin orchestrator (`main.swift`).
- `sendmail-test` (executable) — custom test runner. **Not** an XCTest target (see constraints below).

The split exists because the test runner needs to `import SendmailCore`. The thin executable just wires stdin and argv into the core pipeline and chooses a `ScriptRunner`.

### Message pipeline

```
stdin bytes -> RFC822Parser -> MIMEParser -> ParsedMessage -> MailDriver -> ScriptRunner
```

- `RFC822Parser.parse(Data)` produces `RawMessage` (ordered headers + raw body bytes; no MIME interpretation).
- `MIMEParser.parse(RawMessage)` interprets `Content-Type`, walks `multipart/*` parts, decodes `base64` / `quoted-printable` transfer encodings, and decodes RFC 2047 encoded-words in `Subject` and display names. Populates `htmlBody` from any `text/html` part alongside the stripped plain-text `body`.
- `MailDriver.deliver(...)` chooses between two AppleScript emitters and hands the result to a `ScriptRunner`. The HTML path (`buildEditDraftScript`) is **pass-through**: `main.swift` constructs the .eml bytes via `EmlBuilder.buildEml(raw:finalRecipients:options:)` (raw stdin headers + body, with CLI flag-driven header overrides applied to To/Cc/Bcc/From), `MailDriver.deliver` writes them to a temp `.eml`, and the emitted script (1) probes Accessibility, (2) `do shell script "open -a Mail ..."` to spawn a viewer window, (3) polls for the viewer by window-id diff (never by subject/title -- see the gotcha below), (4) raises the viewer and verifies it is Mail's front, main and key window (see the key-window gotcha below), then invokes Message > Send Again (⇧⌘D) via a System Events menu click — converting the viewer into a brand-new editable compose with full WKWebView fidelity, (5) on `--send`, raises the compose window and verifies it the same way, then clicks `Message > Send` via System Events, (6) closes the leftover viewer. The plain-text path (`buildClassicScript`) runs for messages without HTML and uses `make new outgoing message` + `set content to (read POSIX file ... as «class utf8»)`.

### The ScriptRunner injection seam

`MailDriver.deliver` takes `runner: ScriptRunner? = nil`. Default is `AppleScript.run` (NSAppleScript execution). Tests inject a `Recorder` closure that captures the script source into an array. **Anything new that drives Mail.app should go through this seam** — never call `NSAppleScript` directly from new code, or the tests can't exercise it without actually launching Mail.app.

### Tests don't need WebKit or pandoc anymore

The edit-draft path is pure script emission + .eml byte assembly. The test runner injects a recording `ScriptRunner`, so Mail.app is never invoked. `nix build .#default`'s `checkPhase` runs the full test suite without any WebKit/pandoc/Accessibility prerequisites.

### AppleScript compile check

The `AppleScriptCompile` suite (`Sources/sendmail-test/AppleScriptCompileTests.swift`) compiles, never executes, every script the MailDriver suite's recording runner captured, plus a classic-emitter matrix (send/draft x attachments x odd subjects and names) and edit-draft scripts for send/draft with an `.eml` path containing quotes, a backslash, spaces and non-ASCII, via `NSAppleScript.compileAndReturnError`. A failure names the originating test, the compiler error, and the offending line.

What a compile pass catches: broken block structure (a dropped `end tell` / `end if`, an unclosed record or literal) and unknown class or command terms that break parsing (e.g. `make new to recipient` outside a Mail `tell`). What it does NOT catch: misspelled record labels (`{visable:true}` compiles as a user label), misspelled bare properties that compile as variables, menu / menu-item name strings, and any runtime error (e.g. the -1700 live-reference poll bug). Those still need the text-match tests or a live run.

Compiling an app's terms is safe only because Mail and System Events declare a static `OSAScriptingDefinition`: the compiler reads the sdef and neither launches the app, sends it an AppleEvent, nor triggers an Automation prompt. Before compiling, the suite looks each app up through Launch Services and fails (without compiling) if the key is missing, since compiling would then launch the app.

`every_script_captured_from_maildriver_suite_compiles` reads the MailDriver suite's captures and asserts both emitters are represented, so `appleScriptCompileTests` must stay after `mailDriverTests` in `main.swift`, and focusing on AppleScriptCompile alone still needs MailDriver enabled.

Where it runs: the dev shell (`nix develop --command swift run sendmail-test`) and `nix build` under the default macOS Nix setting `sandbox = false`. The only skip condition is the compiler failing to compile a bare `return 1`; under `sandbox = true` that was observed failing with error -2147450879, so the five cases print `SKIP ... (the AppleScript compiler is unavailable here ...)` while the rest of the suite runs. Every other problem (Mail's terms not loading, a missing static sdef) is a FAIL.

## Project-specific constraints (read before changing)

### Tests do not use XCTest

The Nix Swift toolchain on macOS does not ship the `xctest` helper binary, so `swift test` fails at the test-bundle link step with `FileSystemError ... path: "/private"`. We sidestep this by building an executable test target with a hand-written assertion harness (`Sources/sendmail-test/TestHarness.swift`). Do not migrate this to XCTest or a `.testTarget` — the build will break under Nix on darwin.

### CLI parser is hand-rolled, not swift-argument-parser

Sendmail compatibility requires bundled short flags (`-ti`, `-oi`, `-bm`, `-OFoo=bar`) and silently swallowing many legacy flags. `swift-argument-parser` does not handle that syntax. Don't add it — the cost is a few cases in `CLI.swift`, the payoff is zero SPM dependencies and a hermetic flake (no `swiftpm2nix`).

### CRLF normalization in the header parser

Swift treats `"\r\n"` as a single `Character` (grapheme cluster). `RFC822Parser.unfold` normalizes `\r\n` to `\n` on the header string before splitting on `\n`. Removing that normalization silently merges adjacent headers into the previous one. There is a regression test (`RFC822Parser.crlf_separator`).

### Package.swift macOS floor is `.v13` deliberately

Nixpkgs Swift 5.10 stdlib dylibs are built for macOS 14.0. Lower floors produce linker warnings that escalate to errors during test-bundle handling. `.v13` is the lowest value that links cleanly.

### Draft is the product invariant

`MailDriver` emits `visible:true` and omits the `send` verb unless `options.send` is true. The default behavior is **draft, not send**. The `--send` flag and `SENDMAIL_SEND=1` environment variable both flip it; the env-var path exists for callers (cron, scripts) that cannot easily change their argv.

### HTML rendering uses `.eml` + Cmd-Shift-D ("Send Again"), not RTF

Mail's compose body is a WKWebView. Its AppleScript dictionary `content` setter accepts only `«class RTF »` and plain-text byte formats — every other coercion class (HTML, RTFD even with valid bytes, WebArchive, the deprecated `html content` property, AppKit-bridge NSAttributedString) is rejected with -1700. The full 26-class empirical sweep is recorded in `ATTEMPTS.md`.

The viable path for full HTML fidelity is to **bypass the dictionary entirely**:

1. Write the rfc822 bytes (raw stdin headers + body, with CLI flag overrides applied via `EmlBuilder`) to a temporary `.eml`.
2. `do shell script "open -a Mail <eml-path>"` so Launch Services opens it as a Mail viewer window — rendered in WKWebView.
3. Invoke Message > Send Again (⇧⌘D) via a System Events menu click (`tell process "Mail" to click menu item "Send Again" of menu "Message" of menu bar 1`). On a standalone .eml viewer it spawns a brand-new editable compose with the .eml's `From` / `To` / `Subject` / body all carried into the compose. A menu click on `process "Mail"` can only reach Mail, whereas a keystroke goes to whichever app is frontmost. But Mail must still be frontmost: live (macOS 27 VM), with Finder frontmost the item is absent from a menu scan, and clicking it by name "succeeds" without doing anything -- no compose appears.
4. With `--send`, click `Message > Send` menu item via System Events (`tell process "Mail" to click menu item "Send" of menu "Message" of menu bar 1`), after waiting for the item to be enabled, with a bounded retry while the compose stays open (see the gotchas).

The compose is a fresh outgoing message from Mail's perspective — no `Resent-*` headers on the wire, no "Redirected by" banner. The CLI flag overrides MUST be applied to the .eml before `open` because the compose window is not addressable via the AppleScript `outgoing messages` collection after Cmd-Shift-D — Mail doesn't surface it to dictionary scripting.

Two non-obvious gotchas:

1. **Window matching is by `id`-diff, never by title.** The emitter snapshots `id of every window` of Mail, opens the `.eml`, then polls for the one window id that wasn't present before — that's the viewer. It snapshots again before the Send Again click and finds the new compose window the same way. Titles are never used: a message with no `Subject`, a duplicate subject, or a title Mail rewrites would all break title-matching (empty subject matched nothing and the poll timed out). The leftover viewer is closed by its exact captured id (`close (first window whose id is viewerID)`), because closing the first title-match could hit the compose window, which carries the same subject. A `tell application "Mail" to launch` + `delay 0.5` precedes the first snapshot so Mail's auto-restored windows are counted as "before" rather than mistaken for the viewer on a cold start. **The poll MUST assign `id of every window` to a plain variable first (`set winIDs to id of every window` then `repeat with wid in winIDs`)** -- iterating `repeat with wid in (id of every window)` directly keeps the right side as a live Mail reference, so `item i of id of every window` is sent back to Mail and fails with -1700 ("can't make ... into type specifier"), aborting right after the open so the viewer just sits there. **Sheets are windows to Mail:** an open sheet (e.g. the Attach sheet, Cmd-Shift-A) adds an entry to Mail's `windows` with a new id and the `name` "Save Panel Accessory View", so both polls skip entries with that name. If two or more non-sheet ids are new at the same poll, it fails closed ("Mail opened more than one new window ...; refusing to guess") instead of taking the first. A stray window that appears alone, or one poll before ours, is still mis-selected (#33).

**The Send Again click and the Send click only fire after a key-window check** (`appendVerifiedFrontWindowAction`). Mail's menu commands act on its KEY window, not on a window we name -- and ⇧⌘D is "Send Again" on a viewer but **"Send" on a compose window**, so acting with the user's draft key would send it. Key can differ from main and from Mail's `window 1`: with the Fonts panel (Cmd-T) open, AXFocusedWindow is "Fonts" (subrole AXFloatingWindow) while AXMainWindow and Mail's `window 1` are the user's compose; with an Attach sheet open on the compose, AXFocusedWindow is the sheet (whose AXTitle cannot be read). In every state observed, Mail's `window 1` / `index` order matched AXMainWindow. AXDocument is `missing value` on every Mail window and AXIdentifier ("Mail.messageViewer.window.N", "_NS:41") is not stable, so neither can identify a window. Live in a macOS 27 VM, in plain, panel and sheet states alike, `set index of (first window whose id is viewerID) to 1` made the viewer both AXMainWindow and AXFocusedWindow with Mail frontmost, and ⇧⌘D then did Send Again on it, leaving the user's draft (sheet still open) untouched.

So the emitter activates Mail, raises the target by id (`index` is the read-write "ordered front to back" property of Cocoa Standard `window`), then up to 3s retries an attempt that runs inside ONE `tell application "System Events"` / `tell process "Mail"` block and requires, in order: Mail `frontmost`; Mail's `id of window 1` is the target id; `AXMain` of the AXFocusedWindow is true (key == main, so no panel or sheet holds key -- read as a boolean rather than by comparing two System Events references); AXMainWindow's AXSubrole is AXStandardWindow; it has no `sheets`; and its AXTitle equals Mail's `name` of the target window. The title is only a cross-check on a window already chosen by id, never how a window is picked. The menu click is the next statement after the last check, with no delay. The frontmost check stays even though a click on `process "Mail"` cannot reach another app, because with Mail in the background the click silently does nothing. A failed check, or an AX read that errors (as a sheet's does), re-raises and retries; at the deadline it `error`s with "Last failed check: ...", and the action never runs unverified. Each Mail window lookup is wrapped in `try`, so a target window that disappears mid-poll errors as "The ... window (id N) closed before ..." rather than an uncaught -1719; there is deliberately no viewer cleanup on that error path (with #33 open, `close ... saving no` on a wrongly picked id could discard the user's draft). The `--send` menu click does the same for `composeID`. What this does NOT guarantee:
- **It trusts the id-diff.** If the id-diff picked the wrong window (#33), the emitter raises, verifies and acts on that wrong window.
- **Check-then-act race.** The checks narrow the gap to a few AppleEvent round-trips but cannot close it.
- **Same-titled windows (assumption, not verified).** System Events usually returns window references by title. If AXFocusedWindow/AXMainWindow come back that way, then with two same-titled windows (on `--send`, the viewer and its compose share the subject) the follow-up AX reads resolve to the frontmost window with that title. Once Mail's `window 1` check has passed, that window is the target. A live `--send` run with the viewer still open exercises this.

A fixed delay is not a substitute for the poll -- it races on a busy Mail (e.g. a second HTML send right after the first), so the click lands before Mail is frontmost, does nothing, and the compose-window poll times out with -2700.

**A Send clicked right after Send Again can be ignored while Mail loads an attachment** (`appendSendWithRetry`). Live (macOS 27 VM), html+attachment `--send` failed 3 of 3: once with -1728 (`Can't get menu item "Send"` -- the menu not rebuilt yet) and twice with the compose still open after the click, although Mail was frontmost, the compose was main and key and fully formed, and a manual Message > Send a few seconds later sent it at once. So `--send` runs up to 3 attempts while the compose is open. Each attempt waits up to 10s for `menu item "Send" of menu "Message"` to exist and be enabled (a failed read counts as not ready), runs the full key-window guard, clicks Send, then polls ~3s for the compose id to disappear. If the compose is still open and is Mail's `window 1` with a sheet on AXMainWindow (e.g. a Mail warning), it fails closed at once rather than click through it; otherwise the next attempt's guard refuses to click while the main window has a sheet. After the third click it errors "Send did not complete: the compose window is still open after 3 Send menu clicks". **Retrying is safe only because Mail closes the compose window when it accepts Send**, so an open compose means the click was not taken; if that ever stops holding, a retry would send twice.
2. **Accessibility permission is a hard requirement** for the calling process (both System Events menu clicks, Send Again and Send, need it). The emitted script probes Accessibility upfront by reading a UI element of another process (`get name of menu bar 1 of process "Finder"` — Accessibility-gated, unlike merely enumerating processes) and converts the -1719 / 1002 error into a clear "Grant Accessibility in System Settings" message. No silent fallback — if Accessibility is denied, the HTML path fails fast.

The plain-text path is unchanged and does NOT require Accessibility — only Automation for Mail.

**Bcc stays blind on the HTML path.** `EmlBuilder` serializes `Bcc:` as a plain rfc822 header into the `.eml`. Verified empirically (2026-07-08, via `View > Message > Raw Source` on a self-send with a marker Bcc address): Mail's Send Again consumes it as an envelope recipient and strips the `Bcc:` header from every transmitted copy — including the Bcc recipient's own — while still delivering to it. No special handling is needed and no warning should be emitted; this matches the classic path's dedicated bcc-recipient objects.

**HTML messages with attachments work via the `.eml` pass-through.** A message with an HTML body AND attachments routes to the edit-draft path, so `MailDriver.deliver`'s classic `make new attachment` block (after the `shouldUseEditDraft` early return) is bypassed. The attachment is NOT lost -- it rides inside the raw `.eml` that Send Again reconstructs. Verified live (2026-07-09): a `multipart/mixed` html+attachment message arrived with the file attached (Mail nests the sent parts as `multipart/alternative` > `multipart/mixed`, a little oddly but valid). So the `make new attachment` code being dead for HTML messages is expected, not a bug; do not "fix" it by forcing html+attachment onto the classic path.

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

Send-on-`--send` for the edit-draft path is `click menu item "Send" of menu "Message" of menu bar 1` via System Events on the freshly-opened compose. Menu items are more stable than shortcut bindings across Mail versions. Both menu clicks (Send Again and Send) require Accessibility permission.

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
