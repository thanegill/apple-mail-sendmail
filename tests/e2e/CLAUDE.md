# CLAUDE.md (tests/e2e/)

Guidance for working on the live end-to-end harness in this directory. The repository's own guidance is in `../../CLAUDE.md`.

`nix run .#e2e` (source `e2e.sh`, packaged with `writeShellApplication` in `../../flake.nix`) drives the real binary through Mail.app into a Mailpit capture server on `127.0.0.1` and asserts on Mailpit's API. Setup, safety rules and scenarios are in `README.md` in this directory.

## Running it

- **A plain `nix run .#e2e` drives Mail.app and sends mail.** Agents must not run it, or anything that runs `osascript`, without the user's explicit go-ahead.
- `--check-only` and `--self-test` do not drive Mail. They run the binary only with `SENDMAIL_DRY_RUN=1` inside `sandbox-exec` with `dry-run.sb` (no Apple Events, Mach lookups, network, fork/exec, signals, IOKit, tty/pty devices, deletes or renames, or writes outside the per-run temp dir; reads are not blocked), in a new session with no controlling terminal.
- `--self-test` probes every rule alone and the whole profile against unsandboxed controls (a read-only Apple Event to Finder, a fork, TIOCSTI into a private `script` pty); `lsopen` and `iokit-open` are only presence-checked. Run `--self-test` after changing any assertion, guard, parser or the profile.
- A live run exits non-zero unless every selected scenario passed (`--allow-refused` also accepts guard refusals).

## Guards

- Every guard fails closed. Address headers and argv go through an allowlist parser (`parse_address_list`, `guard_argv`). Keep new checks in that shape: refuse on anything unrecognised, and add a self-test case for the bypass.
- Dry-run scripts are matched structurally. The HTML script must equal `templates/edit-draft-{send,draft}.applescript.tmpl` apart from the `.eml` path. The plain script must be MailDriver's statement sequence (see `analyze_plain_script`), read with `scan_applescript`, which handles `\"`, `\\` and `\t` escapes and refuses `\n`/`\r`.
- **Any change to `MailDriver`'s emitted AppleScript must regenerate those templates (the command is in `README.md`, "When MailDriver's AppleScript changes") or update `analyze_plain_script`, or every scenario on that path is refused.** Templates always match the binary of the branch they are on.
- e2e-b sends through `SMTP_B_ALIAS` (`e2e-b-smtp.test`, defined once at the top of `e2e.sh`; the profile must match and `--self-test` checks it), an `/etc/hosts` alias for 127.0.0.1, because macOS 27 allows only one profile-managed SMTP account per host. `check_smtp_alias` accepts it only while all of these hold:
  - `/etc/hosts` has exactly `127.0.0.1 <alias>` and `::1 <alias>` (with only the IPv4 line, macOS sends the AAAA query to DNS);
  - the system resolver (`dscacheutil`, the authoritative gate) answers exactly 127.0.0.1 and ::1;
  - nothing listens on `[::1]:1025`;
  - `dig` (an extra check of resolv.conf's servers only) exits 0 with no answer, or 9; any other `dig` exit refuses.
- `check_proxies` refuses any enabled system proxy (`scutil --proxy`). It and `check_smtp_alias` run inside `check_accounts`, so before every scenario too. Self-tests stub them and add read-only positive controls with the real tools; never edit the real `/etc/hosts` from the harness.
- Mail keeps sent plain-text messages in `outgoing messages` until it is relaunched, so that count is not checked; compose windows are caught as non-viewer windows instead.

## Mailpit

- Every Mailpit, including self-test sinks and controls, starts under `env -i` with only the `MP_*` variables that case needs. The harness's own must report relaying and SpamAssassin off through `/api/v1/webui`, with no relay/forward line in its log.
- It runs in its own session under the `run_supervised` watchdog (Go Mailpit would otherwise exit on the terminal's Ctrl-C before the Outbox drain). The watchdog stops it when the harness exits, even by SIGKILL, unless cleanup detached it because the Outbox drain could not confirm empty.
- Every `curl` goes through `CURL` (`-q --noproxy '*'`). Do not add a bare `curl` or a bare `mailpit`.
- e2e-b fetches POP3 on 1111 through a `socat` forwarder (127.0.0.1 only) to Mailpit's 1110, started, stopped and supervised with Mailpit, because macOS refuses two POP accounts on the same host and port. `--serve` starts it too; profile installation needs both ports up.
- Mailpit prepends its own trace headers (and a `Bcc:` header for envelope-only recipients) to the stored raw message. Header assertions must use `sender_headers`, which keeps only what follows Mailpit's `Received:` line, or every Bcc scenario reports a Bcc header that Mail never sent.

## Mail and the AppleScripts

- Every place the harness touches Mail is `/usr/bin/osascript` in `e2e.sh` plus the binary itself in live mode. Keep it that way, so the surface stays reviewable. The scripts are:
  - the read-only `preflight.applescript`, which lists accounts, SMTP servers and rules and runs before every scenario;
  - the read-only `mail-windows.applescript`, also used by the exit-time Outbox drain;
  - `send-compose-window.applescript`, for draft-then-send scenarios.

  All of them run under `timeout --foreground` so Ctrl-C reaches them at once.
- `send-compose-window.applescript` matches the compose window by title, which the product must never do. It is acceptable here only because the subject embeds the run's timestamp and a random number, and the click is refused unless exactly one window has that title and is frontmost.
- In `send-compose-window.applescript`, do not name variables after System Events terms (`titled` is a window property): inside `tell process`, `set titled to …` sets that property instead of a variable.
- Mail serialises a From display name that has both an RFC 5322 special and a non-ASCII character (e.g. `Bäcker, Anna`) as one encoded-word with the quoted-string's quotes inside it (`=?utf-8?B?IkLDpGNrZXIsIEFubmEi?=`), so it decodes as `"Bäcker, Anna"`, whatever form the binary handed Mail. `display_name_matches` accepts exactly one surrounding pair of quotes in that case only; every other display name must match exactly.

## Shell

- `writeShellApplication` runs `e2e.sh` under `pipefail`. Never end a status-bearing pipeline in an early-exit reader (`grep -q`, `head`): the producer gets SIGPIPE and the pipeline reports 141 exactly when the match is found. Capture the output first, check the producer's status, then match on a here-string (see `mail_is_running`).

## Scenarios

- New scenarios: add a `define_<name>` function and list it in `SCENARIOS`. Recipients must be `@example.test` and the sender an e2e account, or the guards refuse that scenario.
- Plain-path attachment names on the wire are the binary's temp names (`att-01-<name>`), and the assertion matches names exactly.
- The self-test derives its broken variants from the scenario's expectations, so a new scenario is covered by `--self-test` automatically.

## Packaging

- `packages.e2e`, `apps.e2e` and `checks.e2e-shellcheck` are defined in `../../flake.nix`. Building the harness only shellchecks `e2e.sh`; it never runs in the package's `checkPhase`.
- The harness's resources (`E2E_RESOURCES`) are a fileset of this directory without `README.md` and `CLAUDE.md`, so editing the docs does not change the harness's store path.
