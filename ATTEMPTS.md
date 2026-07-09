# Approaches ruled out

The empirical record of alternatives probed while building this tool and
rejected in favor of the `.eml` + Cmd-Shift-D path (see the README's
"Rich HTML rendering" section). Extracted from the README so that stays
focused; referenced from README.md and CLAUDE.md. Findings are from running
probes on current macOS Mail (Sequoia/Tahoe, 2026), not just reading docs.

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
