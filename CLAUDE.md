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
doing it: the step plan of whichever path the message takes (`HTMLPlan` or
`PlainPlan`), one JSON object per line. It still writes the `.eml` and the
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
- `MailDriver.deliver(...)` chooses the path, stages files in the temp dir, and hands the message to a `MailAutomation`: its `html` delivery for a message with an HTML body, its `plain` delivery otherwise. The HTML path is **pass-through**: `main.swift` constructs the .eml bytes via `EmlBuilder.buildEml(raw:finalRecipients:options:)` (raw stdin headers + body, with CLI flag-driven header overrides applied to To/Cc/Bcc/From), `MailDriver.deliver` writes them to a temp `.eml`, and `AXHTMLDelivery` runs `HTMLPlan.steps` through Accessibility and Launch Services, with no Apple Events: check Accessibility, start Mail if needed, open the `.eml` as a viewer, find the viewer by window diff (never by subject/title -- see the gotcha below), press Message > Send Again (found by its ⇧⌘D shortcut, so localized Mail works) after the key-window guard, which converts the viewer into a brand-new editable compose with full WKWebView fidelity, find the compose the same way, on `--send` press Message > Send on it with a bounded retry, and close the leftover viewer. The plain-text path (`AppleEventPlainDelivery`) runs for messages without HTML and sends Mail one raw Apple Event per `PlainPlan` step: make the outgoing message, set its content, add each recipient and attachment, and send it on `--send` (see "The plain path sends raw Apple Events" below).

### The MailAutomation injection seam

`MailDriver.deliver(_:emlBytes:options:tmp:automation:)` takes a `MailAutomation` (`Sources/SendmailCore/MailAutomation.swift`): a `PlainDelivery` and an `HTMLDelivery`. `main.swift` builds `AppleEventPlainDelivery` over `SystemAppleEventSender` (`AppleEvents.swift`) and `AXHTMLDelivery` over `SystemAXClient`, both with `SystemMailWorkspace` and `SystemClock` (`SystemMailUI.swift`); the dry run uses `PlainPlanPrinter` and `HTMLPlanPrinter`. The deliveries reach Mail only through narrow protocols: `AppleEventSending` (send one event, get the reply) for the plain path, and `AXClient`, `MailWorkspace` and `Clock` (`MailUI.swift`) for the HTML path and for starting Mail. In tests, `AppleEventRecorder` (`Sources/sendmail-test/AppleEventRecorder.swift`) records each event decoded into class, ID and typed parameters (`AEValue`: text, specifiers, insertion locations, file URLs, ...) and answers `make new outgoing message` with a message specifier, and `FakeMail` (`FakeMail.swift`) implements the HTML protocols as a state machine: windows, focus, sheets, menus that act on the key window and only while Mail is frontmost, and a clock that advances only when the code under test sleeps. `RecordingDeliveries.swift` has the test target's `MailDriver.deliver(..., recorder:html:)` and `plainSender` helpers. **Anything new that drives Mail.app goes behind these protocols** — never send an Apple Event, call AX or NSWorkspace directly from new code, or the tests can't exercise it without launching Mail.app.

`FailureReport` (`FailureReport.swift`) turns a delivery error into the message `main.swift` prints and its exit code; the tests cover each mapping.

### Tests never touch Mail

The plain path's events go to `AppleEventRecorder` and the HTML path runs against `FakeMail`, so `nix build .#default`'s `checkPhase` runs the full suite without Mail, WebKit, pandoc, an Automation grant or an Accessibility grant. Building and decoding descriptors (including coercing records to object specifiers) happens in-process and sends nothing.

### The plain path sends raw Apple Events

`AppleEventPlainDelivery` (`PlainPlan.swift`) sends one `NSAppleEventDescriptor` per `PlainPlan` step after `launch_mail`, the same events the old AppleScript compiled to, with codes from Mail's sdef (`/System/Applications/Mail.app/Contents/Resources/Mail.sdef`) and CocoaStandard:

| Step | AppleScript it replaces | Event | Parameters |
|---|---|---|---|
| `launch_mail` | (implicit in `tell application "Mail"`) | none: `NSWorkspace.openApplication`, not activated | — |
| `make_message` | `make new outgoing message with properties {subject, visible, sender}` | `core`/`crel` | `kocl` type `bcke`; `prdt` {`subj` text, `pvis` bool, `sndr` text only when a sender is set} |
| `set_content` | `set content of msg to ...` | `core`/`setd` | `----` property `ctnt` of msg; `data` the body text (no temp file) |
| `add_recipient` | `make new to/cc/bcc recipient at end of ... recipients with properties {address, name}` | `core`/`crel` | `kocl` `trcp`/`crcp`/`brcp`; `insh` insertion {`kobj` every same-class element of msg, `kpos` `end `}; `prdt` {`radd`, `pnam` only when non-empty} |
| `add_attachment` | `tell content to make new attachment with properties {file name: POSIX file ...} at after last paragraph` | `core`/`crel` | `kocl` `atts`; `insh` {`kobj` last `cpar` of `ctnt` of msg, `kpos` `afte`}; `prdt` {`atfn` file URL} |
| `send` | `send msg` | `emsg`/`send` | `----` msg |

`msg` is the object specifier Mail returns from `make_message`; a reply without one is an error before anything else is sent. Every event targets Mail by bundle ID, so Mail is started through NSWorkspace first (an event to a Mail that is not running fails with -600, procNotFound). `SystemAppleEventSender` sends with `[.waitForReply, .canInteract]` (NSAppleScript's default) and an explicit 120s timeout, because the default and no-timeout flags are reported unreliable (rdar://21477694), and turns both a thrown error and a reply carrying `keyErrorNumber` into `AppleEventError`. The first failed event stops the run, so a failed recipient never reaches `send`.

Errors (`FailureReport`): -1743 keeps the Automation wording ("Mail.app automation denied. Grant permission in System Settings → Privacy & Security → Automation.") and exits 78 (`EX_CONFIG`); -600 says Mail is not running and exits 75 (`EX_TEMPFAIL`), since the event never reached Mail and a retry cannot send twice; any other event error names its code and exits 71. The plain path still needs Automation for Mail, like the AppleScript it replaced: an event from the binary is charged to its responsible process (the terminal, or `tart-guest-agent` in the e2e VM).

Text goes to Mail as a text descriptor, verbatim: there is no literal to escape, so a quote, backslash, line separator or control character in a subject, name or body cannot change the event.

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

The plain plan makes the message with `visible` true and has no `send` step unless `options.send` is true, and the HTML plan has no Send press (`press_until_window_closes`) unless it is. The default behavior is **draft, not send**. The `--send` flag and `SENDMAIL_SEND=1` environment variable both flip it; the env-var path exists for callers (cron, scripts) that cannot easily change their argv.

### HTML rendering uses `.eml` + Message > Send Again, not RTF

Mail's compose body is a WKWebView. Its AppleScript dictionary `content` setter accepts only `«class RTF »` and plain-text byte formats — every other coercion class (HTML, RTFD even with valid bytes, WebArchive, the deprecated `html content` property, AppKit-bridge NSAttributedString) is rejected with -1700. The full 26-class empirical sweep is recorded in `ATTEMPTS.md`.

The viable path for full HTML fidelity is to **bypass the dictionary entirely**. `AXHTMLDelivery` (`Sources/SendmailCore/AXHTMLDelivery.swift`) executes `HTMLPlan.steps` (`HTMLPlan.swift`), which the dry run prints, so the printed plan is what a live run does. It sends no Apple Events: only Accessibility (AX) and Launch Services (NSWorkspace).

1. `MailDriver` writes the rfc822 bytes (raw stdin headers + body, with CLI flag overrides applied via `EmlBuilder`) to a temporary `.eml`.
2. Check Accessibility. Start Mail without activating it if it is not running (`NSWorkspace.openApplication`, `activates = false`), wait up to 10s for its AX window list to answer, then snapshot its windows once the list has stayed the same for 0.6s (at most 5s), so session-restored windows count as "before".
3. `NSWorkspace.open([eml], withApplicationAt: Mail)` with `activates = true` opens it as a Mail viewer window, rendered in WKWebView. Waiting for Launch Services' completion handler needs the main run loop, which `SystemClock.sleep` runs.
4. Press Message > Send Again with `AXPress` once the key-window guard passes. The item is found by its ⇧⌘D shortcut, not its title, so a localized Mail works (see "Menu items are found by shortcut" below). On a standalone .eml viewer it spawns a brand-new editable compose with the .eml's `From` / `To` / `Subject` / body all carried into the compose. Pressing a menu item element can only reach Mail, whereas a synthesized keystroke goes to whichever app is frontmost. But Mail must still be frontmost: live (macOS 27 VM), with another app frontmost the item is absent from the menu, and pressing it by name does nothing.
5. With `--send`, press Message > Send on the compose, after waiting for the item to be enabled, with a bounded retry while the compose stays open (see the gotchas).
6. Press the leftover viewer's close button (`kAXCloseButtonAttribute`) and wait up to 2s for it to go. Best effort: by then the message is in its compose or sent, so a viewer left open does not fail the run.

The compose is a fresh outgoing message from Mail's perspective — no `Resent-*` headers on the wire, no "Redirected by" banner. The CLI flag overrides MUST be applied to the .eml before the open because the compose window is not addressable via the AppleScript `outgoing messages` collection after Send Again — Mail doesn't surface it to dictionary scripting.

Two non-obvious gotchas:

1. **Windows are matched by AX element identity, never by title.** Each wait diffs Mail's `kAXWindowsAttribute` against the snapshot taken before the step, with `CFEqual` as the identity (`UIElement` hashes through it), and takes the one new window whose subrole is `AXStandardWindow`. Titles are never used: a message with no `Subject`, a duplicate subject, or a title Mail rewrites would all break title matching (under the old AppleScript, an empty subject matched nothing and the poll timed out). Sheets (e.g. the Attach sheet) are AX children of their window with role `AXSheet`, not top-level windows, and panels have other subroles, so neither counts. If two or more new standard windows appear at once it fails closed ("Mail opened more than one new window ...; refusing to guess") instead of taking the first. A stray standard window that appears alone, or one poll before ours, is still mis-selected (#33). The leftover viewer is closed through its own element's close button, so the compose window, which carries the same subject, cannot be hit.

**Every menu press runs the key-window guard first.** Mail's menu commands act on its KEY window, not on a window we name -- and ⇧⌘D is "Send Again" on a viewer but **"Send" on a compose window**, so acting with the user's draft key would send it. Key can differ from main: with the Fonts panel (Cmd-T) open, AXFocusedWindow is "Fonts" (subrole AXFloatingWindow) while AXMainWindow is the user's compose; with an Attach sheet open on the compose, AXFocusedWindow is the sheet. AXDocument is missing on every Mail window and AXIdentifier ("Mail.messageViewer.window.N", "_NS:41") is not stable, so neither can identify a window.

So for up to 3s the driver raises the target (its `kAXMain` = true, `kAXRaiseAction`, then the app's `kAXFrontmost` = true), and requires, in order: the target is still in Mail's window list (otherwise "The ... window closed before the ... press"); Mail is frontmost (`kAXFrontmost`); `kAXFocusedWindow` is the target; `kAXMainWindow` is the target; the target is an `AXStandardWindow`; it has no `AXSheet` child; and the menu item, looked up afresh through `kAXMenuBarAttribute` (by shortcut, else by English title; see below), exists and is enabled. Only then is the item pressed, once. A failed check re-raises and retries; at the deadline it throws "The ... window did not pass the key-window check within 3s; the Message > ... press was not sent. Last failed check: ...", and nothing is pressed unverified. The plan lists the checks (`"guard":[...]`) and the driver runs exactly that list, so a plan that drops one no longer matches the e2e templates. Every AX call has a 2s messaging timeout (`AXUIElementSetMessagingTimeout`), and an unreadable window list counts as the target still being open. What this does NOT guarantee:
- **It trusts the window diff.** If the diff picked the wrong window (#33), the driver raises, verifies and acts on that wrong window.
- **Check-then-act race.** The checks narrow the gap to a few AX round-trips but cannot close it.

Send Again is never pressed twice: if no compose appears within 5s, the run fails with "Compose window did not appear after Send Again within 5s".

**Menu items are found by shortcut, so a localized Mail works.** Titles are translated ("Nachricht > Erneut senden" in German), but key equivalents are not. Each press names a `MenuItemTarget` (`HTMLPlan.swift`): a shortcut plus an English fallback title. `AXHTMLDelivery.resolve` reads the items of every top-level menu-bar menu (not just one titled "Message"; submenus are not searched) and keeps those that are enabled and whose `kAXMenuItemCmdCharAttribute` is exactly "D" and `kAXMenuItemCmdModifiersAttribute` exactly 1 (Shift; Command is implied unless bit 8 is set). Exactly one: press it. Two or more: fail closed ("Mail has N enabled menu items with the shift-cmd-D shortcut; refusing to guess ..."), nothing pressed. None: fall back to the English title path (menu "Message", item by title), which on a localized Mail finds nothing and the guard times out without pressing. The lookup runs again right before every press, and in the Send readiness poll. Live (2026-11-18, macOS 27, English Mail, `.eml` viewer front): Message > Send Again is "D" / 1, and Edit > Start Dictation is "D" / 24, which the exact modifier match rules out. **Unverified**: that Message > Send is "D" / 1 with a compose front, and that Send Again and Send are never both enabled at once (FakeMail models them as mutually exclusive: Send Again enabled only with a viewer key, Send only with a compose key); if both are, every HTML run fails closed on the ambiguity. The dry-run plan prints the target as `"item":{"fallback_menu":"Message","fallback_title":"Send Again","shortcut":"shift-cmd-D"}`, and the live run logs which way each item was found ("found by its shift-cmd-D shortcut" or "found by its English title") through the `trace` closure, which `main.swift` sends to the unified log (subsystem `apple-mail-sendmail`, category `html`; `log stream --predicate 'subsystem == "apple-mail-sendmail"'`), never to stdout or stderr, where cron would mail it.

**A Send pressed right after Send Again can be ignored while Mail loads an attachment.** Live (macOS 27 VM, under the earlier AppleScript path), html+attachment `--send` failed 3 of 3 with a single click: once because the Message menu had not been rebuilt yet, twice with the compose still open after the click, although Mail was frontmost, the compose was main and key and fully formed, and a manual Message > Send a few seconds later sent it at once. So `--send` makes up to 3 presses while the compose is open. Each waits up to 10s for Message > Send to exist and be enabled, runs the full guard, presses, then polls ~3s for the compose element to leave the window list. If the compose is still open with a sheet on it (e.g. a Mail warning), it fails at once rather than press through it. After the third press it fails with "Send did not complete: the compose window is still open after 3 Message > Send presses". **`AXPress` can return `kAXErrorCannotComplete` (-25204) even when it acted**, so the press result never decides a retry: only whether the compose is still open does. **Retrying is safe only because Mail closes the compose window when it accepts Send**, so an open compose means the press was not taken; if that ever stops holding, a retry would send twice. A compose that closes while a later attempt is waiting, after at least one press, counts as sent; one that closes before the first press is an error.
2. **Accessibility permission is a hard requirement** for the calling process, and the only one on the HTML path: it sends no Apple Events, so it needs no Automation grant for Mail or System Events. The plan's first step checks it with `AXIsProcessTrusted()` (no prompt) before Launch Services or AX touch Mail, and throws `AccessibilityNotGranted`, which `main.swift` prints and exits 78 (`EX_CONFIG`). The message names **System Settings > Privacy & Security > Device Control and Data Access** on macOS 27 and later (Apple renamed the pane) and **... > Accessibility** before that, by `ProcessInfo`'s major version (which reports 27 on macOS 27 even for this SDK 14.4 build). TCC charges the grant to the responsible process (the terminal, or `tart-guest-agent` in the e2e VM). No silent fallback — if Accessibility is denied, the HTML path fails fast.

The plain-text path does NOT require Accessibility — only Automation for Mail.

**Bcc stays blind on the HTML path.** `EmlBuilder` serializes `Bcc:` as a plain rfc822 header into the `.eml`. Verified empirically (2026-07-08, via `View > Message > Raw Source` on a self-send with a marker Bcc address): Mail's Send Again consumes it as an envelope recipient and strips the `Bcc:` header from every transmitted copy — including the Bcc recipient's own — while still delivering to it. No special handling is needed and no warning should be emitted; this matches the plain path's dedicated bcc-recipient objects.

**HTML messages with attachments work via the `.eml` pass-through.** A message with an HTML body AND attachments routes to the HTML path, so the plain path's `add_attachment` steps (after the `shouldUseEditDraft` early return) never run. The attachment is NOT lost -- it rides inside the raw `.eml` that Send Again reconstructs. Verified live (2026-07-09): a `multipart/mixed` html+attachment message arrived with the file attached (Mail nests the sent parts as `multipart/alternative` > `multipart/mixed`, a little oddly but valid). So `add_attachment` never running for HTML messages is expected, not a bug; do not "fix" it by forcing html+attachment onto the plain path.

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

Send-on-`--send` for the HTML path is an `AXPress` on Message > Send for the freshly-opened compose. Pressing the menu item element (found by its shortcut, then pressed) reaches only Mail, unlike a synthesized keystroke. Both presses (Send Again and Send) require Accessibility permission.

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
