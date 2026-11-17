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
| `--help`         | Print usage                                              |
| `--version`      | Print version                                            |

Legacy sendmail flags accepted for compatibility and otherwise ignored:
`-i`, `-oi`, `-bm`, `-bs`, `-oem`, `-oeq`, `-O*`, `-q*`, `-v`, `-n`,
`-M*`. The value-taking flags `-B`, `-N`, `-R`, `-X`, `-O`, and `-C`
consume their argument (attached like `-B8BITMIME`, or the next token
like `-B 8BITMIME`) so the value is not mistaken for a recipient.
`-h N` (sendmail's hop count) is accepted and ignored the same way, but
its value is required and must be all digits (`-h 20` or `-h20`); a
missing or non-numeric hop count is a usage error. This is stricter than
sendmail, which also accepts a sign or leading spaces. `-h` is not a help
flag; use `--help`.

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

Before settling on the `.eml` + Cmd-Shift-D approach above, many other
paths were tried and ruled out: MailKit / `MEExtension`, opening an
`.eml` as a draft, `import mail` + `redirect`, NSSharingService,
`mailto:` URLs, an `NSAttributedString` / RTF-read dictionary path,
per-paragraph rich-text-suite building, and a range of UI-scripting
tricks. Each was empirically probed against current macOS Mail and
rejected. The full record -- what was tried, what happened, and why --
is in [ATTEMPTS.md](ATTEMPTS.md).

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
