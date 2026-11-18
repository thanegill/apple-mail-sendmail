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

To pin a release, add its tag to the flake reference, e.g.
`github:thanegill/apple-mail-sendmail/vX.Y.Z` (see
[Releases](https://github.com/thanegill/apple-mail-sendmail/releases)).

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

The two kinds of message need different grants, each for the calling
terminal (or whichever process invokes the binary):

- **Plain-text messages** drive Mail through Apple Events, so they need
  **Automation** access to Mail. The first time, macOS prompts for it
  in **System Settings -> Privacy & Security -> Automation**. If it is
  denied, the binary exits with status 78 (`EX_CONFIG`) and prints a
  hint pointing at that panel.
- **Messages with an HTML body** drive Mail's windows and menus
  through the Accessibility API and send no Apple Events, so they need
  only **Accessibility**: **System Settings -> Privacy & Security ->
  Accessibility**, or on macOS 27 and later **Privacy & Security ->
  Device Control and Data Access**. Without it the binary exits with
  status 78 (`EX_CONFIG`) before touching Mail, and names that pane.

### Checking the grants

```sh
apple-mail-sendmail --check-permissions
```

reports, without sending anything or reading stdin, whether
Accessibility and Automation for Mail are granted, and how to grant
whichever is missing. It starts Mail if it is not running (without
bringing it to the front) and asks macOS for Automation, which shows
the prompt when macOS can. It exits 0 when both are granted and 78
(`EX_CONFIG`) otherwise.

macOS charges both grants to the *responsible process*, not to the
binary: usually the app it was started from, such as Terminal, iTerm2
or an editor's terminal. Under cron, launchd, SSH or a remote agent it
is that launcher or the binary itself. There is no public API that
names it, so the check explains the rule rather than naming the app.

**Before the first run from cron, launchd or another non-interactive
launcher**, run `apple-mail-sendmail --check-permissions` once from
Terminal, or grant the launching app the listed permissions. The
binary cannot raise its own Automation prompt when its responsible
process is not an app that can show one: plain-text messages then fail
with -1743 (exit 78) and no prompt appears. This was verified under a
VM guest agent, with or without an `Info.plist` embedded in the
binary. Plain-text messages need Automation for Mail; HTML messages
need only Accessibility. A grant belongs to the responsible process it
was made for, so a grant made from Terminal covers runs from Terminal
and the scripts it starts, not a launcher that is its own responsible
process.

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

`-F` sets the display name only together with `-f`; on its own it is
ignored with a stderr notice. Without `-f`, the message's own `From:`
header is handed to Mail unchanged: as the new message's `sender` for
plain-text messages, and inside the `.eml` for HTML messages. On the
plain-text path, a `From:` address with no `@domain` (cron's
`root (Cron Daemon)`, for example) is not passed, so no sender is set.

### Attachments

If the input is a multipart message, parts with `Content-Disposition:
attachment` (or any part carrying a `filename=` / `name=` parameter,
including the RFC 2231 `filename*=` / `name*=` forms) are decoded
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
2. Opening it with Mail through Launch Services, so Mail shows it in
   a viewer window — rendered by WKWebView, the same engine Mail uses
   for received mail.
3. Pressing `Message > Send Again` (⇧⌘D) through the Accessibility
   API, once the viewer is verified as Mail's frontmost, main and key
   window, titled with the message's Subject. Mail converts the viewer into a brand-new editable
   compose carrying the .eml's `To` / `Subject` / `From` and the
   rendered HTML. The press targets Mail's own menu item, so unlike a
   keystroke it cannot land in another app; Mail must still be
   frontmost, because in the background the item is hidden.
4. With `--send`, verifying the compose window the same way, then
   pressing `Message > Send`, at most three times and only while the
   compose is still open.
5. Closing the leftover viewer window.

A window titled differently from the Subject is refused before any
press, in case another window appeared in place of ours. With no
Subject, Mail shows a placeholder title instead, so that check is
skipped.

**HTML `--send` needs a Subject.** Sending a compose with no
Subject makes Mail ask "This message has no subject. Send anyway?".
The binary never answers Mail's prompts, so it stops there: the
compose stays open as a draft, nothing is sent, and it exits 71 with
"Mail is asking to confirm sending a message with no Subject ...
HTML --send needs a Subject". Add a `Subject:` header, or leave out
`--send` and send the draft by hand.

This preserves **everything** the source HTML expresses — tables,
CSS padding and backgrounds, monospace `<pre>` styling, inline
colors, fonts, lists — because the compose body never leaves the
WKWebView pipeline. There is no RTF or NSAttributedString
intermediate that flattens layout.

Because the new compose window is spawned by Mail's "Send Again"
verb rather than `make new outgoing message`, Mail's scripting
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
  silently" the way the plain-text path can.
- **Mail must be running** (or quickly launchable) — the binary
  starts it if not already running, then needs the viewer window to
  appear before the Send Again press. It waits up to 5 seconds;
  longer cold-starts produce a clean timeout error.

### Dry run

Set `SENDMAIL_DRY_RUN=1` to print what the binary would do and skip
every call to Mail.app: the steps of whichever path the message takes,
one JSON object per line. Useful for debugging. `--check-permissions`
refuses to run under it (exit 64), since it starts Mail and may prompt.

```sh
SENDMAIL_DRY_RUN=1 apple-mail-sendmail -t < msg.eml
```

## Flag reference

| Flag             | Behavior                                                 |
|------------------|----------------------------------------------------------|
| `-t`             | Read recipients from `To`, `Cc`, `Bcc` headers           |
| `-f <addr>`      | Set the From address (default: the message's `From:`)    |
| `-F <name>`      | Set the From display name; applies only with `-f`        |
| `--send`         | Actually deliver (default: draft for review)             |
| `--check-permissions` | Report the Accessibility and Automation grants and how to fix them; sends nothing (see [Checking the grants](#checking-the-grants)) |
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
|    0 | Message handed to Mail.app successfully; with `--check-permissions`, both grants in place |
|   64 | Usage error (unknown flag, malformed argv)                    |
|   65 | Data error (unparseable message)                              |
|   67 | No recipients resolved                                        |
|   71 | Driving Mail failed (an Apple Event or an HTML-path step)     |
|   75 | Temporary failure: no temp file, or Mail not running (EX_TEMPFAIL) |
|   78 | Automation or Accessibility permission denied (or, with `--check-permissions`, not confirmed) |

## Alternatives considered

Before settling on the `.eml` + Send Again approach above, many other
paths were tried and ruled out: MailKit / `MEExtension`, opening an
`.eml` as a draft, `import mail` + `redirect`, NSSharingService,
`mailto:` URLs, an `NSAttributedString` / RTF-read dictionary path,
per-paragraph rich-text-suite building, and a range of UI-scripting
tricks. Each was empirically probed against current macOS Mail and
rejected. The full record -- what was tried, what happened, and why --
is in [ATTEMPTS.md](ATTEMPTS.md).

## Development

The project is a SwiftPM package with three targets:

- `SendmailCore` — library with all parsing and Mail automation logic
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

The tests record the plain path's Apple Events and run the HTML path
against a fake Mail, so they never drive Mail.app.

```sh
nix develop
swift run sendmail-test
```

Tests also run automatically as part of `nix build .#default`
(in the package's `checkPhase`) and `nix flake check`.

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs
`nix flake check -L` on a `macos-latest` runner for every pull request
and every push to `master`.

### End-to-end tests

The unit tests never touch the real Mail. A separate
harness, `nix run .#e2e`, runs the real binary against Mail.app in a
dedicated test user or VM and checks what Mail sends to a local Mailpit
capture server; `nix run .#e2e-vm` runs it in a disposable Tart VM. Its
setup, safety rules and scenarios are in
[`tests/e2e/README.md`](tests/e2e/README.md).

### Releases

`nix run .#release -- prepare X.Y.Z` opens a release PR; once it is
merged, `nix run .#release -- tag X.Y.Z` tags `vX.Y.Z` and publishes the
GitHub release. The version policy, steps and recovery are in
[RELEASING.md](RELEASING.md).

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
├── tests/
│   └── e2e/                  (live end-to-end harness, `nix run .#e2e`)
├── scripts/
│   └── release.sh            (`nix run .#release`)
├── .github/                  (CI workflow, release-notes categories)
├── RELEASING.md
└── README.md
```

## License

MIT; see [LICENSE](LICENSE).
