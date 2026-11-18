# apple-mail-sendmail

A sendmail-compatible command-line interface for Apple Mail on macOS.
It reads an RFC 822 message on stdin and hands it to Mail.app. By
default it opens a visible compose window so you can review and edit
before sending; pass `--send` (or set `SENDMAIL_SEND=1`) to deliver
instead.

Cron jobs, `git send-email`, mailx and other tools that expect a
`sendmail` binary can then send through your existing Mail.app
accounts, with no separate SMTP relay.

## Install

The project is a Nix flake.

```sh
nix run github:thanegill/apple-mail-sendmail -- --help    # try it
nix profile install github:thanegill/apple-mail-sendmail  # install
```

To pin a release, add its tag to the flake reference, e.g.
`github:thanegill/apple-mail-sendmail/vX.Y.Z` (see
[Releases](https://github.com/thanegill/apple-mail-sendmail/releases)).

The default package installs `bin/apple-mail-sendmail` and a
`bin/sendmail` symlink to it. If another package owns `sendmail`, use
`.#without-sendmail-symlink`, or override the parameter from another
flake:

```nix
inputs.apple-mail-sendmail.packages.${system}.default.override {
  withSendmailSymlink = false;
}
```

## Permissions

- **By default**, every message, plain text or HTML, is turned into a
  compose through Mail's windows and menus with the Accessibility API,
  and no Apple Events are sent. That needs only **Accessibility**:
  System Settings -> Privacy & Security -> Accessibility, or on macOS
  27 and later Privacy & Security -> Device Control and Data Access.
- **With `--no-ui`** (see [Without Mail's windows](#without-mails-windows---no-ui)),
  a plain-text message goes to Mail through Apple Events instead, which
  needs **Automation** access to Mail (System Settings -> Privacy &
  Security -> Automation) and not Accessibility. macOS prompts for it
  the first time.

A missing grant exits with status 78 (`EX_CONFIG`) and names the pane.

### Checking the grants

```sh
apple-mail-sendmail --check-permissions
```

reports whether Accessibility and Automation for Mail are granted, and
how to grant whichever is missing. It sends nothing and reads no stdin,
but it starts Mail if needed (without bringing it to the front) and
asks macOS for Automation, which shows the prompt when macOS can. It
exits 0 when both are granted and 78 otherwise, so without `--no-ui` a
missing Automation grant is reported although nothing you run needs it.

macOS charges both grants to the *responsible process*, not to the
binary: usually the app it was started from, such as Terminal, iTerm2
or an editor's terminal. Under cron, launchd, SSH or a remote agent it
is that launcher or the binary itself. No public API names it, so the
check explains the rule rather than naming the app.

**Before the first run from cron, launchd or another non-interactive
launcher**, run `apple-mail-sendmail --check-permissions` once from
Terminal, or grant the launching app the permissions it lists. The
binary cannot raise its own Automation prompt when its responsible
process is not an app that can show one: `--no-ui` messages then fail
with -1743 (exit 78) and no prompt appears (verified under a VM guest
agent, with or without an `Info.plist` embedded in the binary). A grant
made from Terminal covers runs from Terminal and the scripts it starts,
not a launcher that is its own responsible process.

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

```sh
apple-mail-sendmail --send -t < message.eml
SENDMAIL_SEND=1 apple-mail-sendmail -t < message.eml
```

**`--send` needs a Subject**, with or without `--no-ui`. Mail holds a
message with no Subject for a "Send anyway?" confirmation that the
binary cannot answer (with `--no-ui`, Mail keeps it unsent while
reporting success), so the binary refuses `--send` with an empty
Subject before touching Mail and exits 65 (`EX_DATAERR`). A draft
works without a Subject.

### Positional recipients

Without `-t`, the addresses on the command line are the recipients and
replace the message's `To:` header. With `-t`, they are added to the
header recipients, skipping any address a header already has.

```sh
apple-mail-sendmail you@example.com < msg.eml
```

### From overrides

```sh
apple-mail-sendmail -F "Build Bot" -f bot@example.com you@example.com < msg.eml
```

Mail.app picks the enabled account whose address matches `-f`. If none
matches, Mail silently uses its default account, and the binary prints
a stderr notice. `-F` applies only together with `-f`; on its own it is
ignored with a notice. Without `-f`, Mail picks the account from the
message's own `From:`. A `From:` with no `@domain` (cron's
`root (Cron Daemon)`, for example) goes out from Mail's default
account.

### Attachments

Parts with `Content-Disposition: attachment`, or any part with a
`filename=` / `name=` parameter (including the RFC 2231 `filename*=` /
`name*=` forms), are attached under their own names. With `--no-ui`
the recipient sees them named `att-NN-<name>`.

### How a message reaches Mail

Unless `--no-ui` is given:

1. The binary writes the message, with any `-t` / `-f` / positional
   overrides applied to its headers and the body verbatim, to a
   temporary `.eml`.
2. Mail opens it in a viewer window; an HTML body is rendered by
   WKWebView like received mail.
3. The binary brings Mail to the front and presses Message > Send Again
   (shift-cmd-D) through Accessibility. Mail turns the viewer into a new
   editable compose with the `.eml`'s headers, body and attachments.
4. With `--send`, it presses Message > Send on that compose, at most
   three times and only while the compose is still open.
5. It closes the leftover viewer.

Everything the HTML expresses (tables, CSS padding and backgrounds,
`<pre>` styling, colors, fonts, lists) survives, because the body never
leaves WKWebView; HTML without its own font CSS uses Mail's Fonts &
Colors preferences. A plain-text body arrives as written, as
`text/plain`. The sent message is a regular outgoing message: no
`Resent-*` headers and no "Redirected by" banner. Bcc recipients get
the message without a `Bcc:` header on any copy.

Before each press, the window must be Mail's key window and titled with
the message's Subject, so a stray window is refused rather than acted
on. A message with no Subject skips the title check, because Mail
titles that window with a placeholder.

Tradeoffs:

- A viewer window briefly appears on every run, and Mail comes to the
  front, so this needs a logged-in user; `--no-ui` avoids both.
- Mail is started if it is not running, and the viewer must appear
  within 5 seconds; a slower cold start fails with a timeout error.

The many other approaches that were tried and rejected are recorded in
[ATTEMPTS.md](ATTEMPTS.md).

### Without Mail's windows (`--no-ui`)

For headless jobs where Mail cannot come to the front, or where the
launcher can be granted Automation but not Accessibility, pass
`--no-ui` (or set `SENDMAIL_NO_UI=1`):

```sh
apple-mail-sendmail --no-ui --send -t < report.txt
```

The binary then builds the message in Mail with Apple Events and opens
or presses nothing. Two limits:

- **Mail sends the body as a quotation.** A body set through Mail's
  scripting dictionary goes out as `multipart/alternative` with every
  `text/plain` line prefixed with `> ` and the HTML part in
  `<blockquote type="cite">` (Mail bug FB11734014, still present in
  Mail 16.0 on macOS 27). The default path does not have this problem.
- **Plain text only.** A message with an HTML body is refused with exit
  64 (`EX_USAGE`) before touching Mail, rather than sent as its text
  part.

### Dry run

`SENDMAIL_DRY_RUN=1` prints the steps the binary would take, one JSON
object per line, and makes no call to Mail.app. `--check-permissions`
refuses to run under it (exit 64), since it starts Mail and may prompt.

```sh
SENDMAIL_DRY_RUN=1 apple-mail-sendmail -t < msg.eml
```

## Flags

`apple-mail-sendmail --help` lists every flag, including the legacy
sendmail flags it accepts and ignores. `-h` is sendmail's hop count, not
help.

## Exit codes

Following `sysexits.h`:

| Code | Meaning |
|-----:|---------|
|    0 | Message handed to Mail.app; with `--check-permissions`, both grants in place |
|   64 | Usage error, or `--no-ui` with an HTML body |
|   65 | Unparseable message, or `--send` with no Subject |
|   67 | No recipients |
|   71 | Driving Mail failed |
|   75 | Temporary failure: no temp file, or Mail not running |
|   78 | Accessibility (or, with `--no-ui`, Automation) not granted; with `--check-permissions`, either not confirmed |

## Development

```sh
nix build                          # builds and runs the unit tests and MIME conformance check
nix flake check -L                 # what CI runs on every PR
nix develop --command swift run sendmail-test
```

The unit tests never drive Mail.app. The live end-to-end harness, which
does, is described in [`tests/e2e/README.md`](tests/e2e/README.md).
Maintainer notes are in [CLAUDE.md](CLAUDE.md), and the release
procedure in [RELEASING.md](RELEASING.md).

## License

MIT; see [LICENSE](LICENSE).
