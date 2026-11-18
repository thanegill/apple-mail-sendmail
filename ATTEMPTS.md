# Approaches ruled out

The empirical record of alternatives probed while building this tool and
rejected in favor of the `.eml` + Cmd-Shift-D path (see the README's
"Rich HTML rendering" section). Extracted from the README so that stays
focused; referenced from README.md and CLAUDE.md. Findings are from running
probes on current macOS Mail (Sequoia/Tahoe, 2026; the sections marked
2026-11-18 on macOS 27, Mail 16.0 build 3901.200.71.1.16, in a disposable
VM with POP accounts and a Mailpit SMTP capture), not just reading docs.

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
  not editable `outgoing message` objects (an imported message moved
  into Drafts can be opened as a compose through the UI; see the
  Drafts-mailbox section below). Writing `.emlx` files into
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
- **`import mail` + move to Drafts + AppleScript `open`.** Probed in
  2026. AppleScript `open <message>` on an imported message moved into
  a Drafts mailbox produces a read-only viewer (titled
  `<subject> — Drafts`), not an editable compose. mbox status headers
  (`X-Status`, `X-Mozilla-Status`), `.emlx` trailer `flags=64`
  (RFC 3501 `\Draft`), and the
  `X-Uniform-Type-Identifier: com.apple.mail-draft` header all
  survive import but don't change what `open` returns. Opening the
  same message through the UI is a different story; see the next
  section.

### Drafts mailbox + UI open (works, rejected)

Probed 2026-11-18. A foreign HTML message moved into the sending
account's own Drafts mailbox opens as an **editable** compose (titled
just the subject) when opened by double-click, by Return, or by
`File > Open Message`. Only AppleScript `open` gives the viewer.

- **Getting it there.** `import Mail mailbox at` an Apple `.mbox`
  bundle (a directory containing a file named `mbox`; a plain mbox
  file is ignored), then `move` the message into
  `mailbox "Drafts" of account <sender>`. The app-level
  `drafts mailbox` property is the unified "All Drafts" view, and a
  move into it does nothing.
- **Selecting it.** `set selected messages of message viewer 1`
  silently does nothing. Selecting through System Events works: the
  `AXTable` whose description is "messages", the row matched by its
  subject text, `set selected to true`. Mail's `selected messages`
  then follows.
- **Fidelity.** Full: classes from a `<style>` block, inline styles,
  table borders and padding, `<pre>` background, a div's 24px padding.
- **Wire.** `Message > Send` produced a clean message: a new
  `Message-Id`, no `Resent-*` headers, the `X-Uniform-Type-Identifier`
  header dropped. `Bcc:` was stripped and the Bcc recipient still
  received it. An attachment was kept. The draft left Drafts.
- **Not scriptable.** The compose is not in `outgoing messages`, so
  everything must be baked into the imported message, as with Send
  Again.
- **Untested:** IMAP server-side Drafts (the earlier IMAP probe used
  AppleScript `open`).
- **Rejected because** every `import Mail mailbox` leaves a stray
  "Import" / "Import-N" mailbox under On My Mac in the user's sidebar,
  which a sendmail transport must not do. It also needs UI row
  selection plus a menu click for `--send`, so it saves nothing over
  Send Again on permissions.

### Services: `Mail/New Email With Selection`

Probed 2026-11-18 via `NSPerformService("Mail/New Email With
Selection", pasteboard)`. Not viable.

- **Only Web Archive matches.** Mail's Info.plist declares the send
  types as the literal constant NAMES `NSPasteboardTypeRTFD`,
  `NSPasteboardTypeRTF` and `NSPasteboardTypeString`, which resolve to
  unusable `dyn.*` UTIs, so plain-text and RTF pasteboards are rejected
  with "service expects types". Only `com.apple.webarchive` ("Apple Web
  Archive pasteboard type") matches.
- **Body unreliable.** A Web Archive body sometimes rendered well
  (classes, inline styles, borders and backgrounds kept; the div
  padding lost) but was empty in about 3 of 4 runs.
- **No handle.** The compose is not in `outgoing messages`, and
  AppleScript `close ... saving no` on it produced "Unable to Load
  Window" sheets.
- **Headers by UI only.** Typed keystrokes landed in the wrong field.
  Setting the To text field's AX value did create a recipient token.
- **Send did not send.** Clicking `Message > Send` had no effect.

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
  and is what the rich-RTF path used and the plain path still does
  (`set_content` before `add_attachment` in `PlainPlan`).
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
  marshal the opaque-pointer type. JXA's ObjC bridge can do it with a
  null event source (next bullet); either way it needs the
  Accessibility grant.
- **CGEvent click + HTML paste into a scripted compose (2026-11-18).**
  `make new outgoing message`, then a real CGEvent click into the
  body's `AXWebArea` posted from the JXA ObjC bridge with a null event
  source (this does focus the body), an HTML / Web Archive general
  pasteboard, Cmd+V, then dictionary `send`. Full fidelity on the
  wire, and the message stays a scriptable `outgoing message`
  (recipients via the dictionary). Reading `content` right after the
  paste returned only whitespace, although the sent message had the
  full HTML. Rejected: adding an attachment through the dictionary,
  before OR after the paste, lost the HTML body (the known
  attachment-wipes-rich-body bug, see NSSharingService above); it also
  overwrites the user's clipboard, and Cmd+V needs Accessibility and
  focus.
- **Pasteboard + Cmd+V.** With an `NSAttributedString` on
  `NSPasteboard` and a Cmd+V keystroke, the paste does fire but lands
  in whatever has focus (typically not the compose body — see above,
  unless a CGEvent click focused it).
- **System Events Tab keystrokes to traverse to the body.** 5 Tabs
  cycle through the header fields (To, Cc, Bcc, Reply-To, Subject)
  but never descend into the `AXWebArea`. The body is not in Tab's
  focus chain.

### Mail UI observations (2026-11-18)

- **`Message > Send Again`** is the ⇧⌘D item when Mail is frontmost.
  With another app frontmost it is missing from a menu scan, and
  clicking it by name reports success but does nothing.
- **AX window attributes.** `AXDocument` is missing value on every
  Mail window, `.eml` viewers included; `AXFocusedWindow` and
  `AXMainWindow` are readable.

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

### Driving the HTML path with System Events (worked, then superseded)

Until the Accessibility (AX) driver, the HTML path was one generated
AppleScript: `do shell script "open -a Mail ..."`, window polls over
Mail's `id of every window`, and `click menu item` on Message > Send
Again and Message > Send through System Events, after a key-window check
read through System Events' AX attributes. It worked live, but it needed
an Automation grant for Mail and for System Events on top of
Accessibility, and AppleScript added failure modes of its own:

- `repeat with wid in (id of every window)` kept the id list as a live
  Mail reference, so `item i of id of every window` went back to Mail
  and failed with -1700 ("can't make ... into type specifier"). The poll
  had to copy the list into a plain variable first.
- A sheet showed up in Mail's `windows` as an extra entry with its own
  id, named "Save Panel Accessory View", which both polls had to skip.
  Through AX, a sheet is a child of its window instead.
- Comparing two System Events window references was unreliable (they
  are usually resolved by title), so key == main had to be read as
  `AXMain` of `AXFocusedWindow`, with an `AXTitle` cross-check.

The AX driver (`AXHTMLDelivery`) does the same steps with AX element
identity (`CFEqual`) and NSWorkspace, sends no Apple Events, and is unit
tested against a fake Mail rather than by matching script text.

### The plain path as generated AppleScript (worked, then superseded)

Until the raw Apple Events in `AppleEventPlainDelivery`, the plain path
was one generated `tell application "Mail"` script run through
NSAppleScript. Every subject, name and address had to be escaped into an
AppleScript string literal (`AppleScript.quote`, which had to work on
Unicode scalars, because a `"` fused with a combining mark is one Swift
`Character` and slipped past a Character-level escape), and the body was
written to a temp `body.txt` and read back with `read POSIX file ... as
«class utf8»`. A compile-only test suite caught broken block structure.
The events are the same ones that script compiled to (see CLAUDE.md, "The
plain path sends raw Apple Events"), but text now travels as text
descriptors with nothing to escape, the body needs no file, and the tests
assert on event classes and parameters rather than on script text.
