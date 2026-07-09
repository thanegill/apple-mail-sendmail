# apple-mail-sendmail

A sendmail-compatible command-line interface for Apple Mail on macOS.
Reads an RFC 822 message on stdin and hands it to Mail.app. By default it
opens a visible compose window so you can review and edit before sending;
pass `--send` (or set `SENDMAIL_SEND=1`) to deliver instead.

This exists so cron jobs, `git send-email`, mailx, and other tools that
expect a `sendmail` binary can route through your existing Mail.app
accounts without configuring a separate SMTP relay.

## Install

This project is packaged as a Nix flake.

Try it without installing:

```sh
nix run github:thanegill/apple-mail-sendmail -- --help
```

Install into your profile:

```sh
nix profile install github:thanegill/apple-mail-sendmail
```

Or build locally:

```sh
nix build
./result/bin/apple-mail-sendmail --help
```

The default package installs:

- `bin/apple-mail-sendmail` — the canonical binary
- `bin/sendmail` — symlink to the above (drop-in compatibility)

If you don't want the `sendmail` symlink (for example, because another
package owns that path), use the variant without it:

```sh
nix build .#without-sendmail-symlink
```

Or override the parameter from another flake:

```nix
inputs.apple-mail-sendmail.url = "github:thanegill/apple-mail-sendmail";
# ...
inputs.apple-mail-sendmail.packages.${system}.default.override {
  withSendmailSymlink = false;
}
```

## Permissions

Mail.app uses macOS automation. The first time the binary runs, you'll
be prompted to grant the calling terminal (or whichever process invokes
it) automation access in **System Settings -> Privacy & Security ->
Automation**. If automation is denied, the binary exits with status 78
(`EX_CONFIG`) and prints a hint pointing at the settings panel.

**Messages with an HTML body require an additional Accessibility grant**
for the calling process in **System Settings -> Privacy & Security ->
Accessibility**. The HTML path opens the message in Mail, sends a
Cmd-Shift-D keystroke ("Send Again") to convert the viewer into an
editable compose, and (with `--send`) clicks `Message > Send` — all of
which need Accessibility. Plain-text-only messages take the classic
AppleScript path and do not need Accessibility.

## Usage

### Draft mode (default)

Opens a visible compose window in Mail.app. Nothing is sent.

```sh
apple-mail-sendmail -t <<'EOF'
To: alice@example.com
Subject: hi

Body text here.
EOF
```

### Send mode

Either flag the invocation or set the environment variable:

```sh
apple-mail-sendmail --send -t < message.eml
SENDMAIL_SEND=1 apple-mail-sendmail -t < message.eml
```

### Positional recipients

When `-t` is not given, the addresses on the command line are the
recipients (legacy sendmail behavior); existing `To:` headers in the
message are replaced.

```sh
apple-mail-sendmail you@example.com <<'EOF'
Subject: positional

Body.
EOF
```

With `-t`, positional addresses are added on top of the header
recipients, deduplicated: an address already present in a header is
not added a second time.

### From overrides

```sh
apple-mail-sendmail -F "Build Bot" -f bot@example.com you@example.com < msg.eml
```

Mail.app picks the enabled account whose address matches `-f`. If
nothing matches, it falls back to the default account silently; the
binary prints a stderr notice so you know `-f` was honored only as a
hint.

### Attachments

If the input is a multipart message, parts with `Content-Disposition:
attachment` (or any part carrying a `filename=` parameter) are decoded
and attached. Plain-text messages attach them via Mail's dictionary
(`make new attachment`); HTML messages carry them inside the `.eml`
that Send Again reconstructs (see Rich HTML rendering), so both paths
deliver attachments.

```sh
apple-mail-sendmail -t <<'EOF'
To: alice@example.com
Subject: with attachment
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="B"

--B
Content-Type: text/plain; charset=utf-8

Body text.
--B
Content-Type: application/octet-stream; name="note.txt"
Content-Disposition: attachment; filename="note.txt"
Content-Transfer-Encoding: base64

aGVsbG8K
--B--
EOF
```

### Rich HTML rendering

When the input has an HTML body (a `text/html` part, or a
`multipart/alternative` with `text/html` inside), the binary
hands the message to Mail by:

1. Writing the rfc822 bytes (with any `-t` / `-f` / positional
   overrides applied to the headers; body bytes verbatim) to a
   temporary `.eml`.
2. `open -a Mail file.eml` so Mail opens it as a viewer window —
   rendered by WKWebView, the same engine Mail uses for received
   mail.
3. Sending `Cmd-Shift-D` ("Send Again") via System Events. Mail
   converts the viewer into a brand-new editable compose carrying
   the .eml's `To` / `Subject` / `From` and the rendered HTML.
4. With `--send`, clicking `Message > Send` via System Events.
5. Closing the leftover viewer window.

This preserves **everything** the source HTML expresses — tables,
CSS padding and backgrounds, monospace `<pre>` styling, inline
colors, fonts, lists — because the compose body never leaves the
WKWebView pipeline. There is no RTF or NSAttributedString
intermediate that flattens layout.

Because the new compose window is spawned by Mail's "Send Again"
verb rather than `make new outgoing message`, AppleScript's
`outgoing messages` collection does not see it; CLI flag overrides
must be applied to the .eml bytes **before** Mail opens it, not
afterward. That is what the binary does.

The wire-level result is a regular outgoing message — no
`Resent-From` / `Resent-To` headers, no "Redirected by" banner in
the recipient's client. The only operational side effect is the
brief viewer window that flashes open and closes before send.

Tradeoffs:

- **Accessibility permission required** for the calling process.
  Without it the binary fails fast with an explicit error pointing
  at System Settings.
- **One Mail window briefly flashes** during each invocation.
  Cron-style use is fine but the binary cannot run "completely
  silently" the way the classic plain-text path can.
- **Mail must be running** (or quickly launchable) — `open -a Mail`
  starts it if not already running, then needs the window to
  appear before the keystroke fires. The script polls up to 5
  seconds; longer cold-starts produce a clean timeout error.

### Dry run

Set `SENDMAIL_DRY_RUN=1` to print the AppleScript that would be executed
and skip the call to Mail.app. Useful for debugging.

```sh
SENDMAIL_DRY_RUN=1 apple-mail-sendmail -t < msg.eml
```

## Flag reference

| Flag             | Behavior                                                 |
|------------------|----------------------------------------------------------|
| `-t`             | Read recipients from `To`, `Cc`, `Bcc` headers           |
| `-f <addr>`      | Set the From address                                     |
| `-F <name>`      | Set the From display name                                |
| `--send`         | Actually deliver (default: draft for review)             |
| `-h`, `--help`   | Print usage                                              |
| `--version`      | Print version                                            |

Legacy sendmail flags accepted for compatibility and otherwise ignored:
`-i`, `-oi`, `-bm`, `-bs`, `-oem`, `-oeq`, `-O*`, `-q*`, `-v`, `-n`,
`-M*`. The value-taking flags `-B`, `-N`, `-R`, `-X`, `-O`, and `-C`
consume their argument (attached like `-B8BITMIME`, or the next token
like `-B 8BITMIME`) so the value is not mistaken for a recipient.

## Exit codes

Following `sysexits.h`:

| Code | Meaning                                                       |
|-----:|---------------------------------------------------------------|
|    0 | Message handed to Mail.app successfully                       |
|   64 | Usage error (unknown flag, malformed argv)                    |
|   65 | Data error (unparseable message)                              |
|   67 | No recipients resolved                                        |
|   71 | AppleScript execution failed                                  |
|   75 | Temporary failure: could not create the temp file (EX_TEMPFAIL) |
|   78 | Automation permission denied                                  |

## Alternatives considered

Recorded so future contributors (and future Claude sessions) don't redo
the research. Each of these was empirically probed against current
macOS Mail (verified on Sequoia/Tahoe, 2026) and ruled out in favor of
the `.eml` + Cmd-Shift-D approach described under "Rich HTML rendering"
above. Findings are based on running probes, not just reading
documentation. Some entries below describe the earlier RTF-read and
rich-text-suite approaches, which worked but were themselves superseded
by `.eml` + Cmd-Shift-D for true WKWebView fidelity.

### Architecture-level dead-ends

- **MailKit / `MEExtension` (macOS 12+).** `MEComposeSessionHandler`
  exposes `additionalHeaders(for:)`, `allowMessageSendForSession:`, and
  lifecycle hooks — but no body-rewrite API. Apple explicitly states
  the compose editor body cannot be modified from extensions.
  Extensions can't be triggered from an external CLI either, and
  shipping one requires Developer ID signing + Xcode + user enablement
  — none of which fit this Nix-flake build path.
- **Opening an `.eml` file as a draft.**
  `tell application "Mail" to open POSIX file "foo.eml"` produces a
  read-only viewer, not a compose window. `import mail` accepts only
  `.mbox` bundles and lands messages as immutable `message` objects,
  not editable `outgoing message` objects. Writing `.emlx` files into
  `~/Library/Mail/.../Drafts.mbox/` is undocumented and version-fragile.
- **`import mail` + `redirect` to inject HTML content.** Probed in
  detail in 2026. `import Mail mailbox at <Apple-format .mbox>`
  imports our crafted message; `redirect msg with opening window`
  returns an editable `outgoing message` with full WKWebView
  rendering and works around almost everything. **Killed by wire
  semantics**: Mail emits `Resent-From` / `Resent-To` / `Resent-Date`
  headers on send AND preserves the original `To:` header from the
  source verbatim. Recipients see `To: <placeholder>` plus
  `Resent-To: <real>` — most clients render this as a "Redirected
  by" banner. Wrong shape for a sendmail-style transport.
- **`import mail` + move to Drafts + `open`.** Probed in 2026.
  Moving the imported message into a Drafts mailbox and `open`-ing
  it produces a read-only viewer, not an editable compose. Apple's
  draft state is gated on internal metadata that Mail only sets
  when ITS OWN compose flow created the message — mbox status
  headers (`X-Status`, `X-Mozilla-Status`), `.emlx` trailer
  `flags=64` (RFC 3501 `\Draft`), and the
  `X-Uniform-Type-Identifier: com.apple.mail-draft` header all
  survive but are informational-only and don't flip the message
  into editable state.

### `outgoing message` `content` property dead-ends

- **`html content` AppleScript property.** Present in `outgoing
  message` via Mail's sdef but marked `"Does nothing at all
  (deprecated)"` by Apple since macOS El Capitan (2015). Setting it
  yields a blank body — verified by probe.
- **`set content of msg to NSAttributedString`.** Passing an
  `NSAttributedString` value (built from HTML via the Cocoa bridge)
  fails with `Can't get «class ocid» id ...` coercion errors. Mail
  expects AppleScript text, not Cocoa attributed-string pointers.
- **`set content of msg to (read POSIX file "x.rtf" as «class RTF »)`.**
  Works when Mail's app-level `default message format` is `rich
  format` (flipped via try/restore inside the script). RTF fidelity
  is the ceiling: tables flatten, CSS padding disappears, monospace
  `<pre>` backgrounds vanish unless hand-patched. Superseded by the
  `.eml` + Cmd-Shift-D path which delivers true WKWebView fidelity.
- **`set content` accepts only `«class RTF »` and plain-text
  variants.** Empirically swept 26 four-char-code coercion classes
  (`HTML`, `htda`, `WBAR` WebArchive, `RTFD` with valid bytes from
  `NSAttributedString.data(from:.rtfd)`, `XWRD` Word, `docx`,
  `odft` OpenDocument, `macs` MacWrite, `furl`, `data`, `plis`,
  `alis`, lowercase variants, etc.) — every one except RTF and
  plain text fails with AppleScript error -1700 `Can't make «data
  XXXX...» into type rich text`. Mail's content setter is
  hard-coded to RTF parsing. Do not re-investigate.
- **`set content` AFTER `make new attachment`.** Silently no-ops — the
  body keeps just the attachment glyph (`U+FFFC`) and the assigned
  text is dropped. The reverse order (set content, then attach) works
  and is what the rich-RTF and classic paths both use.
- **Per-paragraph rich-text-suite build (superseded).** An earlier
  iteration of this branch built the rich body in the dictionary by
  emitting `make new paragraph at end of content with data "..." with
  properties {font:..., size:..., color:{r,g,b}}` per paragraph,
  then `make new attachment ...`, then `send` — all via Mail's rich
  text suite (`paragraph`, `attribute run`, `attachment` are
  elements of the `rich text` class, which inherits from
  `NSTextStorage`). It worked but only carried the first character's
  attributes of each paragraph, so inline runs (bold spans, colored
  links inside a paragraph) and CSS-derived backgrounds were lost.
  The RTF-read approach above replaced it because RTF carries the
  full character-attribute table.

### NSSharingService dead-ends

NSSharingService (`sharingServiceNamed:NSSharingServiceNameComposeEmail`)
DOES open a compose window with `NSAttributedString` body — earlier
versions of this branch used it. But:

- **The window does not register as `outgoing message` in Mail's
  AppleScript dictionary.** Per Shane Stanley (MacScripter, 2019), the
  NSSharingService-created compose window surfaces only as a read-only
  `message` in Drafts — there is no scriptable handle to address from
  `tell application "Mail"`. Confirmed empirically by enumerating
  `outgoing messages` before and after `performWithItems:` — the count
  doesn't change.
- **No attachment API.** NSSharingService's
  `NSSharingServiceNameComposeEmail` accepts subject + recipients
  but not attachments.
- **No auto-send.** It opens a visible window and waits for the user
  to click Send.
- **UI-scripted attachment follow-up is broken.** Even if you find
  the compose window via System Events, a known Mail.app bug
  (documented on MacScripter through 2025) wipes the rich-text body
  the instant an attachment is added unless the body is first cut,
  then attached, then pasted. Too fragile to maintain.
- **Async dispatch needs runloop spin.** `performWithItems:` returns
  immediately; wrapping it in `performSelectorOnMainThread:withObject:
  waitUntilDone:true` reports `done` but the window never opens
  unless you also `runUntilDate:` for a couple of seconds after.
- **Mail's compose-format setting controlled survival.** With Mail's
  "Composing → Message Format" set to Plain Text, NSSharingService's
  per-paragraph fonts and background colors were stripped on receipt;
  only Rich Text preserved them. The later rich-text-suite path
  sidestepped this by setting fonts via dictionary properties (itself
  since superseded by `.eml` + Cmd-Shift-D).

### `mailto:` URL via `GetURL` / `open`

Opens a compose window with `To`/`Cc`/`Bcc`/`Subject`/plain-body all
populated from query params (verified empirically). But:

- **The window does not register as `outgoing message`** — same
  architectural limit as NSSharingService. No dictionary handle, no
  attachment API, no auto-send.
- **Plain text only.** No HTML rendering of any kind.
- **`+` is NOT decoded as a space.** Mail.app honors `%20` but not
  the form-encoded `+` convention.
- **URL-length-bound** to ~2K characters for the whole URL.

### UI scripting dead-ends

- **`click webArea` on Mail's WKWebView compose body.** Mail's compose
  body is an `AXWebArea` (WebKit). AppleScript's `click` on a UI
  element calls `AXPress`, which is not a real mouse event; WKWebView
  ignores it and the text-edit caret never moves. Cmd+V keystrokes
  subsequently land in whatever field was actually focused — usually
  the To: field, where they overwrite the selected recipient pill.
- **`set focused of webArea to true`.** Reports success but does not
  actually establish keyboard focus inside the WKWebView.
- **`click at {x,y}` synthesizing a click via System Events.** Same as
  `click webArea` — the click event isn't a real HID-level mouse
  event from WKWebView's perspective, so no caret.
- **CGEventPost from the AppleScript-ObjC bridge.** The opaque
  `CGEventSource` pointer can't be passed back into
  `CGEventCreateMouseEvent` through AppleScript — the bridge can't
  marshal the opaque-pointer type. Workable only from native Swift,
  which then still needs the Accessibility grant.
- **Pasteboard + Cmd+V.** With an `NSAttributedString` on
  `NSPasteboard` and a Cmd+V keystroke, the paste does fire but lands
  in whatever has focus (typically not the compose body — see above).
- **System Events Tab keystrokes to traverse to the body.** 5 Tabs
  cycle through the header fields (To, Cc, Bcc, Reply-To, Subject)
  but never descend into the `AXWebArea`. The body is not in Tab's
  focus chain.

### The RTF-read approach (worked, then superseded)

Before the `.eml` + Cmd-Shift-D path, the binary rendered HTML to RTF
and set it via the dictionary. It worked, but RTF is a fidelity
ceiling -- tables flatten, CSS padding and `<pre>` backgrounds are
lost -- so it was superseded. The mechanics, kept for reference:

Mail's `rich text` class (the type of `outgoing message`'s
`content`) is backed by `NSTextStorage`. Setting that property to a
plain string drops to plain text, and setting it to an
`NSAttributedString` from the Cocoa bridge fails with a
`«class ocid»` coercion error. But `read POSIX file "..." as
«class RTF »` returns a value Mail accepts directly:

```applescript
set rtfData to (read POSIX file "/tmp/body.rtf" as «class RTF »)
tell application "Mail" to set content of newMessage to rtfData
```

Two conditions matter:

1. The `read` must run **outside** any `tell application "Mail"`
   block, since `read` is a Standard Additions verb and Mail.app
   doesn't recognize it.
2. Mail's app-level `default message format` must be `rich format`
   at the moment `set content` runs, otherwise the RTF data is
   coerced to plain. Snapshot/flip/restore around the compose.

Once those are in place, an HTML email rendered to RTF via
`NSAttributedString.initWithHTML:` + per-run font substitution
arrives in the compose window with the full character-attribute
table intact: per-run fonts, colors, bold/italic, background
colors from CSS, paragraph structure. Attachments via dictionary
`make new attachment` after the content is set do not wipe the
body (verified empirically). `send` via dictionary closes the loop
for `--send` mode.

## Development

The project is a SwiftPM package with three targets:

- `SendmailCore` — library with all parsing and AppleScript logic
- `apple-mail-sendmail` — thin executable that orchestrates them
- `sendmail-test` — standalone test runner using a custom assertion
  harness (no XCTest, because the Nix Swift toolchain on macOS does
  not include the `xctest` helper)

### Build

```sh
nix develop
swift build
```

### Run tests

The tests use a recording AppleScript runner, so they never drive
Mail.app.

```sh
nix develop
swift run sendmail-test
```

Tests also run automatically as part of `nix build .#default`
(in the package's `checkPhase`) and `nix flake check`.

## Layout

```
.
├── flake.nix
├── flake.lock
├── Package.swift
├── Sources/
│   ├── SendmailCore/         (library)
│   ├── apple-mail-sendmail/  (thin executable entry)
│   └── sendmail-test/        (test runner + assertion harness)
└── README.md
```
