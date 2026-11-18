# Changelog

Notable changes to apple-mail-sendmail. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.1] - 2026-11-18

### Development

- The Nix build is bit-for-bit reproducible: the binary's `LC_UUID` no longer changes between builds of the same source.

## [0.2.0] - 2026-11-18

### Added

- `--no-ui` (or `SENDMAIL_NO_UI=1`): send a plain-text message through Apple Events without bringing Mail to the front. It needs Automation for Mail instead of Accessibility. On this path Mail sends the body quoted (Apple bug FB11734014), and HTML messages are refused (exit 64). (#65)
- `--check-permissions`: reports whether Accessibility and Automation for Mail are granted, which app macOS charges them to, and how to grant them. (#61)
- RFC 2231 encoded attachment filenames are decoded. (#37)
- RFC 5322 group syntax in address headers (for example `undisclosed-recipients:;`). (#40)

### Changed

- Every message, plain text as well as HTML, is handed to Mail as an `.eml` and sent through Message > Send Again, driven through the Accessibility API. The default path needs only the Accessibility permission. Mail sends the body exactly as written instead of quoting it. (#55, #65)
- No AppleScript is generated or run any more; `--no-ui` sends raw Apple Events. (#54, #55, #56)
- `--send` with an empty Subject is refused (exit 65) before Mail is touched, because Mail holds such a message for a confirmation it can't show. Drafts without a Subject still work. (#65)
- Before each Send Again or Send press, Mail must be frontmost and the target window must be key and main, with no sheet open and a title matching the Subject. Otherwise nothing is pressed. (#44, #55, #64)
- Mail's menu items are found by their ⇧⌘D shortcut, so non-English macOS works. (#62)
- `-h` is the sendmail hop count; only `--help` shows help. (#41)
- An Accessibility denial exits 78 with instructions; on macOS 27 they name the "Device Control and Data Access" pane. (#54)
- On a plain-text send, Mail's `send` returning false is an error, and the first event waits for a Mail that is still launching. (#60)

### Fixed

- Plain-text bodies were sent quoted ("> " lines in the text part and a blockquote in the HTML part). (#65)
- A plain-text message with no Subject sent with `--send` could be silently left unsent while the command exited 0. (#65)
- The message's `From:` header now chooses the sending account on the plain-text path. (#38)
- Display names with commas or other specials are quoted, and non-ASCII names are RFC 2047-encoded in the `.eml`. (#39)
- `-vt` and `-nt` dropped `-t`. (#59)
- Attachment filenames lost their case. (#37)
- The temporary directory is removed after delivery. (#36)
- AppleScript string escaping could be bypassed with combining marks. (#43)
- MIME and RFC 5322 conformance (#63):
  - text attachments lost their final newline;
  - quoted-printable trailing whitespace and soft line breaks were mishandled;
  - a MIME part without headers lost its first paragraph;
  - comments in addresses broke on `\)`;
  - folded headers lost their folding whitespace;
  - `.eml` header lines over 998 octets were not folded.

### Development

- A live end-to-end harness checks what Mail actually sends, through a local Mailpit, inside a disposable Tart macOS VM (`nix run .#e2e-vm`). (#45, #46)
- CI runs `nix flake check` on macOS. (#49)
- Releases are cut with `nix run .#release`. (#52)
- MIME parsing is checked against the RFC examples and against Python's `email` package. (#63)
- The toolchain is Swift 6.4, and the code builds in Swift 6 language mode. (#58, #67)
- The project is licensed under MIT. (#51)

## [0.1.0] - 2026-11-03

The first tagged version: a sendmail-compatible CLI that hands each message to Apple Mail, rendering HTML bodies by opening them as an `.eml` and turning that into a compose with Send Again.

### Fixed

- An HTML message with no Subject timed out waiting for Mail's window; windows are matched by id, not title. (#1)
- Charset decoding: cp1252 was read as Latin-1, and a bad byte dropped the body. (#21)
- MIME: inline parts were treated as attachments, and HTML entities weren't decoded. (#22)
- Space-separated legacy flag values were parsed as recipients. (#23)
- An HTML `--send` reported success even if the compose window never closed. (#24)
- With `-t`, a recipient given both as an argument and in the headers was added twice. (#28)
- A temporary-directory failure exited 71; it now exits 75 (EX_TEMPFAIL), so the caller retries. (#28)
- CR or LF in a header value could inject headers into the `.eml`. (#29)
- HTML sends failed on a cold or busy Mail (-1700, -2700). (#30)

[Unreleased]: https://github.com/thanegill/apple-mail-sendmail/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/thanegill/apple-mail-sendmail/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/thanegill/apple-mail-sendmail/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/thanegill/apple-mail-sendmail/releases/tag/v0.1.0
