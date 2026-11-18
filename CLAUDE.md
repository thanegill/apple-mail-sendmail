# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build, test, and dev loop

Tests are wired into the package's `checkPhase`, so a standard build runs them:

```sh
nix build               # builds binary + runs all unit tests
nix flake check         # same, plus evaluates other flake outputs
```

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
- `MailDriver.deliver(...)` chooses between two AppleScript emitters and hands the result to a `ScriptRunner`. The HTML path (`buildEditDraftScript`) is **pass-through**: `main.swift` constructs the .eml bytes via `EmlBuilder.buildEml(raw:finalRecipients:options:)` (raw stdin headers + body, with CLI flag-driven header overrides applied to To/Cc/Bcc/From), `MailDriver.deliver` writes them to a temp `.eml`, and the emitted script (1) probes Accessibility, (2) `do shell script "open -a Mail ..."` to spawn a viewer window, (3) polls for the viewer by window-id diff (never by subject/title -- see the gotcha below), (4) `keystroke "d" using {shift down, command down}` to invoke Mail's "Send Again" command — converting the viewer into a brand-new editable compose with full WKWebView fidelity, (5) on `--send`, clicks `Message > Send` via System Events, (6) closes the leftover viewer. The plain-text path (`buildClassicScript`) runs for messages without HTML and uses `make new outgoing message` + `set content to (read POSIX file ... as «class utf8»)`.

### The ScriptRunner injection seam

`MailDriver.deliver` takes `runner: ScriptRunner? = nil`. Default is `AppleScript.run` (NSAppleScript execution). Tests inject a `Recorder` closure that captures the script source into an array. **Anything new that drives Mail.app should go through this seam** — never call `NSAppleScript` directly from new code, or the tests can't exercise it without actually launching Mail.app.

### Tests don't need WebKit or pandoc anymore

The edit-draft path is pure script emission + .eml byte assembly. The test runner injects a recording `ScriptRunner`, so Mail.app is never invoked. `nix build .#default`'s `checkPhase` runs the full test suite in the sandbox without any WebKit/pandoc/Accessibility prerequisites.

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
3. Send `keystroke "d" using {shift down, command down}` via System Events. Mail's File menu has `Send Again` bound to that shortcut; on a standalone .eml viewer it spawns a brand-new editable compose with the .eml's `From` / `To` / `Subject` / body all carried into the compose.
4. With `--send`, click `Message > Send` menu item via System Events (`tell process "Mail" to click menu item "Send" of menu "Message" of menu bar 1`).

The compose is a fresh outgoing message from Mail's perspective — no `Resent-*` headers on the wire, no "Redirected by" banner. The CLI flag overrides MUST be applied to the .eml before `open` because the compose window is not addressable via the AppleScript `outgoing messages` collection after Cmd-Shift-D — Mail doesn't surface it to dictionary scripting.

Two non-obvious gotchas:

1. **Window matching is by `id`-diff, never by title.** The emitter snapshots `id of every window` of Mail, opens the `.eml`, then polls for the one window id that wasn't present before — that's the viewer. It snapshots again before the Cmd-Shift-D keystroke and finds the new compose window the same way. Titles are never used: a message with no `Subject`, a duplicate subject, or a title Mail rewrites would all break title-matching (empty subject matched nothing and the poll timed out). The leftover viewer is closed by its exact captured id (`close (first window whose id is viewerID)`), because closing the first title-match could hit the compose window, which carries the same subject. A `tell application "Mail" to launch` + `delay 0.5` precedes the first snapshot so Mail's auto-restored windows are counted as "before" rather than mistaken for the viewer on a cold start. **The poll MUST assign `id of every window` to a plain variable first (`set winIDs to id of every window` then `repeat with wid in winIDs`)** -- iterating `repeat with wid in (id of every window)` directly keeps the right side as a live Mail reference, so `item i of id of every window` is sent back to Mail and fails with -1700 ("can't make ... into type specifier"), aborting right after the open so the viewer just sits there.

Before the Cmd-Shift-D keystroke (and the Send menu click), the emitter **waits until Mail is actually the frontmost process** (`repeat until frontmost or (current date) > fdeadline`) rather than using a fixed delay. A fixed delay races on a busy Mail -- e.g. a second HTML send right after the first -- so the keystroke lands before Mail is frontmost, Send Again never fires, and the compose-window poll times out with -2700 ("Compose window did not appear after Send Again within 5s").
2. **Accessibility permission is a hard requirement** for the calling process (System Events keystroke + menu click both need it). The emitted script probes Accessibility upfront by reading a UI element of another process (`get name of menu bar 1 of process "Finder"` — Accessibility-gated, unlike merely enumerating processes) and converts the -1719 / 1002 error into a clear "Grant Accessibility in System Settings" message. No silent fallback — if Accessibility is denied, the HTML path fails fast.

The plain-text path is unchanged and does NOT require Accessibility — only Automation for Mail.

**Bcc stays blind on the HTML path.** `EmlBuilder` serializes `Bcc:` as a plain rfc822 header into the `.eml`. Verified empirically (2026-07-08, via `View > Message > Raw Source` on a self-send with a marker Bcc address): Mail's Send Again consumes it as an envelope recipient and strips the `Bcc:` header from every transmitted copy — including the Bcc recipient's own — while still delivering to it. No special handling is needed and no warning should be emitted; this matches the classic path's dedicated bcc-recipient objects.

**HTML messages with attachments work via the `.eml` pass-through.** A message with an HTML body AND attachments routes to the edit-draft path, so `MailDriver.deliver`'s classic `make new attachment` block (after the `shouldUseEditDraft` early return) is bypassed. The attachment is NOT lost -- it rides inside the raw `.eml` that Send Again reconstructs. Verified live (2026-07-09): a `multipart/mixed` html+attachment message arrived with the file attached (Mail nests the sent parts as `multipart/alternative` > `multipart/mixed`, a little oddly but valid). So the `make new attachment` code being dead for HTML messages is expected, not a bug; do not "fix" it by forcing html+attachment onto the classic path.

### Draft injection from outside Mail is not reachable — empirically confirmed

Mail's "editable draft" state cannot be conjured by any combination of mbox headers, `.emlx` flag bits, IMAP `\Draft` flag, or Apple-internal headers. Editable drafts only exist when Mail itself creates the message — through its compose UI, `make new outgoing message` (AppleScript), or reply/forward/redirect derivatives of an existing message. Empirically verified during this branch (full probe scripts in `/tmp/import-redirect-probe/` during session work):

| Approach | Result |
|---|---|
| `import Mail mailbox at <Apple .mbox bundle>` + `redirect m with opening window` | Mechanically works — creates an editable compose with full WKWebView body fidelity (real bordered tables, `<pre>` Menlo+grey, inline red italic). Subject, To/Cc/Bcc programmatically overridable. **But** `send` emits `Resent-From`/`Resent-To`/`Resent-Date` on the wire AND preserves the source mbox's `To:` header verbatim (the post-redirect `to recipients` override only flows into `Resent-To:`). Recipient sees "redirected from X" semantics; unsuitable for sendmail's "fresh outgoing" expectation. Also leaves a top-level mailbox in Mail's sidebar per invocation that needs cleanup. |
| `import` + `move <msg> to <account>/Drafts` + `open <msg>` | Move succeeds (synced over IMAP). Open spawns a read-only viewer (Reply/Forward/Redirect buttons), NOT an editable compose. `outgoing messages` count remains 0; the window has no addressable `message` element. |
| `Status: D` (mbox), `X-Status: T` (Thunderbird), `X-Mozilla-Status: 0040` (Mozilla draft bit) | Either stripped during import or preserved-but-ignored. No effect on draft recognition. |
| Apple `.emlx` format with trailer plist `flags=64` (the draft bit, instead of Berkeley `mbox` inside the bundle) | Imported but landed in nested `Import-N/<bundle>` and treated as a regular message. flags bit had no effect. |
| `X-Uniform-Type-Identifier: com.apple.mail-draft` in rfc822 headers — the UTI Mail itself stamps on real drafts | Header survives import AND IMAP round-trip to Fastmail's Drafts folder intact. Mail still opens as read-only viewer. UTI is informational only. |
| `redirect <window>` / `first message of window` on a standalone .eml viewer opened via `open -a Mail file.eml` | "window doesn't understand the redirect message" / "Can't get message 1 of window". Standalone .eml viewers register as generic `class=window` with no `message` element; `message viewers` enumerates only mailbox-list viewers. |
| Mail's `open <file>` AppleScript verb on an .eml path | Returns a `class` literal (not a message reference). No usable handle on the opened message. |
| `open -a Mail <eml-path>` + UI-script `keystroke "d" using {shift down, command down}` on the viewer | ✅ **Works.** Triggers Mail's "Send Again" command, which spawns a brand-new editable compose carrying the .eml's `To` / `Subject` / `From` / body in full WKWebView fidelity. Sends as a clean message — no `Resent-*` headers. No sidebar mailbox churn. Requires **Accessibility** permission for the controlling process; without it, `keystroke` fails with `-1719 ("not allowed assistive access")` / error number 1002. |

The converted compose does NOT appear in the `outgoing messages` collection — AppleScript dictionary cannot drive it post-conversion. So everything (recipients, subject, sender, body, attachments) must be baked into the source `.eml` **before** the open; we never override anything after Cmd-Shift-D fires.

Send-on-`--send` for the edit-draft path is `click menu item "Send" of menu "Message" of menu bar 1` via System Events on the freshly-opened compose. Menu items are more stable than shortcut bindings across Mail versions. `tell process "Mail" to click menu item` requires the same Accessibility permission as `keystroke`.

The mechanically-working but semantically-wrong paths above (`redirect`, move-to-Drafts) are intentionally avoided. Do not re-investigate them as "primary path" candidates without re-reading this table — the wire-level Resent-* leak is real and was confirmed end-to-end via `View > Message > Raw Source` on a probe send to `me@thanegill.com`.

### Font preferences are not applied by this binary

The .eml + Cmd-Shift-D path renders bodies in Mail's WKWebView, which honors any CSS the HTML supplies and otherwise inherits Mail's "Fonts & Colors" preferences automatically. The binary does not read `com.apple.mail` defaults; no `MailFontPrefs` type exists. If the source HTML wants specific fonts, declare them in the inline CSS.

## Packaging

`flake.nix` uses flake-parts. The package factory is wrapped in `pkgs.lib.makeOverridable` and takes `withSendmailSymlink ? true`. Its `src` is a `lib.fileset` of `Package.swift` and `Sources/` only, so editing docs or `tests/e2e/` does not rebuild the Swift binary or rerun its tests. Named packages:

- `packages.default` — installs `apple-mail-sendmail` plus a `sendmail` symlink.
- `packages.without-sendmail-symlink` — canonical binary only.
- `packages.e2e` (also `apps.e2e`, and `checks.e2e-shellcheck` so `nix flake check` shellchecks it) — the live end-to-end harness. Building it only shellchecks `tests/e2e/e2e.sh`; it never runs in `checkPhase`.
- `packages.e2e-vm` (also `apps.e2e-vm`, and `checks.e2e-vm-shellcheck`) — `tests/e2e/vm.sh`, which runs the harness in a Tart VM. Building it only shellchecks the script.

Consumers from other flakes can also call `self.packages.${system}.default.override { withSendmailSymlink = false; }`.

`meta.mainProgram = "apple-mail-sendmail"`, so `nix run` always invokes the canonical name even though both names are on `PATH` in the `default` package.

Tests run in the package's `checkPhase`, not as a separate test derivation; `checks.default` is the package itself, so both `nix build .#default` and `nix flake check` fail when tests fail.

The dev shell includes [Tart](https://tart.run) for the VM-based e2e runs. Nixpkgs marks Tart unfree (FSL-1.1), so `perSystem` sets `_module.args.pkgs` to a nixpkgs import whose `allowUnfreePredicate` admits only `tart`; do not replace that with a blanket `allowUnfree`. The `tart` binding in `flake.nix` overrides the pinned nixpkgs package to 2.42.0 (2.41.1 fixed `tart exec` dropping large output, openai/tart#1347) with `doInstallCheck = false`: on macOS 27, running `tart.app` inside the build tags the bundle with `com.apple.macl`, and Nix then fails to register the output ("clearing flags of path ...: Operation not permitted"), leaving an invalid store path that macOS's app-bundle protection also stops `nix store gc` from deleting unless the Nix daemon has Full Disk Access. Never run a store `.app` during a build. Drop the override once `flake.lock` pins a nixpkgs with Tart 2.41.1 or newer.
