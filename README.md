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
Automation**.

If automation is denied, the binary exits with status 78 (`EX_CONFIG`)
and prints a hint pointing at the settings panel.

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
recipients.

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
and attached to the compose window.

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
converts it to RTF in Swift — via
`NSAttributedString.initWithHTML:` plus per-run font substitution
to Mail's configured fonts — writes the RTF bytes to a temp file,
and has AppleScript do `set content of msg to (read POSIX file ...
as «class RTF »)`. Attachments are added inline via dictionary
`make new attachment`; `send msg` via dictionary covers `--send`
mode. No NSSharingService, no UI scripting, no Accessibility
permission.

Per-run fonts mirror what Mail's "Fonts & Colors" panel is
configured to use:

- Proportional content (`<p>`, headings, ordinary body) → Mail's
  **Message font** (default `Helvetica 12`).
- Monospace content (`<pre>`, `<code>`) → Mail's **Fixed-width
  font** (default `Menlo-Regular 11`).

The binary reads those at runtime from the `com.apple.mail`
preferences (`NSFont`, `NSFontSize`, `NSFixedPitchFont`,
`NSFixedPitchFontSize`) and falls back to Apple's stock defaults
when a key is missing.

Because the RTF coercion only survives into the compose body when
Mail's app-level `default message format` is `rich format`, the
emitter:

1. Snapshots `default message format` before composing.
2. Sets it to `rich format` only if it wasn't already.
3. Restores the original value in both the success and `on error`
   paths of an enclosing `try`.

If the binary crashes between steps 2 and 3 (rare — would require
a SIGKILL during the AppleScript run), the user's Mail default
could be left as rich format until they change it back. Mitigation:
the snapshot/restore happens entirely inside the AppleScript, so
any Swift-side crash before `NSAppleScript.executeAndReturnError`
returns will only ever leave the preference untouched.

Tradeoffs:

- **Tables don't render.** Mail's rich text model has no table
  class; `<table>` content becomes paragraphs of its cell text in
  reading order.
- **JavaScript / flexbox / grid / web fonts do not apply.** The
  HTML is parsed by `NSAttributedString.initWithHTML:` (WebKit
  archival), which is structural only.
- **On any runtime failure** (HTML parse error, missing default
  message format, RTF read error) the binary falls back to the
  classic plain-text path with a stderr warning, so you always end
  up with a draft.

What does survive: paragraph structure, inline character spans
with their own fonts/colors/bold/italic/underline, background
colors from CSS (e.g. `pre { background: #F0F0F0 }`), em dashes
and box-drawing characters, ordered/unordered lists, headings
sized relative to the paragraph base.

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

Legacy sendmail flags accepted and silently ignored for compatibility:
`-i`, `-oi`, `-bm`, `-bs`, `-oem`, `-oeq`, `-O*`, `-q*`, `-v`, `-N*`,
`-R*`, `-X*`, `-M*`, `-B*`, `-C *`.

## Exit codes

Following `sysexits.h`:

| Code | Meaning                                                       |
|-----:|---------------------------------------------------------------|
|    0 | Message handed to Mail.app successfully                       |
|   64 | Usage error (unknown flag, malformed argv)                    |
|   65 | Data error (unparseable message)                              |
|   67 | No recipients resolved                                        |
|   71 | AppleScript execution failed                                  |
|   75 | Mail.app could not be launched                                |
|   78 | Automation permission denied                                  |

## Alternatives considered

Recorded so future contributors (and future Claude sessions) don't redo
the research. Each of these was empirically probed against current
macOS Mail (verified on Sequoia/Tahoe, 2026) and ruled out in favor of
the dictionary rich-text-suite approach actually in use. Findings are
based on running probes, not just reading documentation.

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
- **`import mail` + `redirect` to inject HTML content.** Hypothetical
  path: import a pre-crafted HTML message, then `redirect` it (which
  preserves the source body verbatim). Not probed in detail because
  every other simpler path was either working or definitively dead;
  noted for completeness only. Would require maintaining a temporary
  mailbox and tolerate Mail's drafts/inbox UI side-effects.

### `outgoing message` `content` property dead-ends

- **`html content` AppleScript property.** Present in `outgoing
  message` via Mail's sdef but marked `"Does nothing at all
  (deprecated)"` by Apple since macOS El Capitan (2015). Setting it
  yields a blank body — verified by probe.
- **`set content of msg to NSAttributedString`.** Passing an
  `NSAttributedString` value (built from HTML via the Cocoa bridge)
  fails with `Can't get «class ocid» id ...` coercion errors. Mail
  expects AppleScript text, not Cocoa attributed-string pointers.
- **`set content of msg to (read POSIX file "x.rtf" as «class RTF »)`
  with default-plain-format.** Mail coerces the read value to plain
  text — rich-text formatting does not survive. **This is the
  approach we now use, but only because we additionally flip Mail's
  app-level `default message format` to `rich format` for the
  duration of the compose.** Two non-obvious gotchas: the `read`
  call must be **outside** any `tell application "Mail"` block (it's
  a Standard Additions verb, not Mail's), and the script must NOT
  carry a `use AppleScript version "2.4"` preamble — that preamble
  makes the parser reject the raw `«class RTF »` four-char-code
  coercion syntax. See "Why the RTF-read approach won" below.
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
  only Rich Text preserved them. The rich-text-suite path (our
  current approach) sidesteps this since it sets fonts via dictionary
  properties.

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

### Why the RTF-read approach won

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
