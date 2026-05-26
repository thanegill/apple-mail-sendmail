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
`multipart/alternative` with `text/html` inside) **and** there are no
attachments **and** `--send` is not set, the compose window is opened via
`NSSharingService` with the HTML converted to an `NSAttributedString`. The
result is a draft that renders inline styles, tables, lists, colors, and
headings — not a stripped plain-text dump.

Tradeoffs you should know about:

- **Attachments force the classic path.** `NSSharingService` does not
  accept attachments. When the message has both HTML and attachments, the
  binary falls back to the classic `tell application "Mail"` route with
  stripped plain text and prints a stderr note. Attachments are
  preserved; styling is not.
- **`--send` forces the classic path.** `NSSharingService` opens a
  visible window and cannot auto-deliver. With `--send`, the classic
  invisible-compose + `send` route is used with stripped plain text.
- **Bcc becomes visible.** `NSSharingService` has no Bcc field, so Bcc
  recipients are merged into the To list. The binary warns on stderr; you
  can edit the draft before sending.
- **Mail.app drops font and background overrides on receipt.** When
  NSSharingService hands the NSAttributedString to Mail's compose
  window, structural HTML (paragraphs, lists, preformatted-block
  whitespace, line breaks) is preserved, but custom fonts and
  background colors specified by `<style>` rules or inline attributes
  are replaced by Mail's default Helvetica + transparent. This is
  a Mail.app limitation, not something we can work around from the
  sender side. JavaScript, flexbox/grid layout, and web fonts also
  do not apply.
- **On any failure** (malformed HTML, missing sharing service), the
  binary automatically falls back to the classic path with a warning, so
  you always get a draft.

No new flags and no new permissions; the existing Automation grant is
sufficient.

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

Recorded so future contributors don't redo the research. Each of these was
investigated and ruled out:

- **MailKit / `MEExtension` (macOS 12+).** `MEComposeSessionHandler` does
  not expose a body-rewrite API; Apple explicitly states the compose
  editor body cannot be modified from extensions. Extensions also can't
  be triggered from an external CLI, and shipping requires Developer ID
  signing + Xcode + user enablement — incompatible with this Nix build.
- **Opening an `.eml` file as a draft.**
  `tell application "Mail" to open POSIX file "foo.eml"` produces a
  read-only viewer, not a compose window. `import mail` accepts only
  `.mbox` bundles and lands messages as immutable `message` objects, not
  editable `outgoing message` objects. Writing `.emlx` files into
  `~/Library/Mail/.../Drafts.mbox/` is undocumented and version-fragile.
- **Mail's `html content` AppleScript property.** Present in the sdef but
  marked "Does nothing at all (deprecated)" by Apple since macOS El
  Capitan (2015); setting it yields a blank body.
- **`read POSIX file ... as «class RTF »` for `outgoing message`'s
  `content`.** Mail stores the read value as plain text; rich-text
  coercion does not survive.
- **Clipboard + Cmd+V via System Events.** Requires an Accessibility
  permission grant on top of Automation, and is brittle to compose
  window focus state.
- **NSSharingService body + follow-up
  `tell application "Mail" to make new attachment`.** The
  NSSharingService-created compose window does not register as an
  `outgoing message` in Mail's AppleScript dictionary; it surfaces only
  as a read-only `message` in Drafts. Per Shane Stanley (MacScripter,
  2019) there is no way to address the window from
  `tell application "Mail"`.
- **NSSharingService body + UI scripting attachments via System Events.**
  Requires Accessibility permission, and a known Mail.app bug wipes the
  HTML body the moment an attachment is added unless the body is first
  cut, then attached, then pasted. Too fragile to maintain across macOS
  releases.

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
