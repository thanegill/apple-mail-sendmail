# CLAUDE.md (tests/e2e/)

Guidance for working on the live end-to-end harness in this directory and its Tart VM wrapper, `vm.sh`. The repository's own guidance is in `../../CLAUDE.md`.

`nix run .#e2e` (source `e2e.sh`, packaged with `writeShellApplication` in `../../flake.nix`) drives the real binary through Mail.app into a Mailpit capture server on `127.0.0.1` and asserts on Mailpit's API. Setup, safety rules and scenarios are in `README.md` in this directory.

## Running it

- **A plain `nix run .#e2e` drives Mail.app and sends mail.** Agents must not run it, or anything that runs `osascript`, without the user's explicit go-ahead.
- `--check-only` and `--self-test` do not drive Mail. They run the binary only with `SENDMAIL_DRY_RUN=1` inside `sandbox-exec` with `dry-run.sb` (no Apple Events, Mach lookups, network, fork/exec, signals, IOKit, tty/pty devices, deletes or renames, or writes outside the per-run temp dir; reads are not blocked), in a new session with no controlling terminal.
- `--self-test` probes every rule alone and the whole profile against unsandboxed controls (a read-only Apple Event to Finder, a fork, TIOCSTI into a private `script` pty); `lsopen` and `iokit-open` are only presence-checked. Run `--self-test` after changing any assertion, guard, parser or the profile.
- A live run exits non-zero unless every selected scenario passed (`--allow-refused` also accepts guard refusals).

## Guards

- Every guard fails closed. Address headers and argv go through an allowlist parser (`parse_address_list`, `guard_argv`). Keep new checks in that shape: refuse on anything unrecognised, and add a self-test case for the bypass.
- Dry-run output is matched structurally. The HTML path prints its step plan (one JSON object per line, from `HTMLPlan`, the code a live run executes), which must equal `templates/html-plan-{send,draft}.jsonl.tmpl` apart from the `.eml` path (`analyze_html_plan`; exactly one `open_eml` step, path without a quote or backslash). The plain script must be MailDriver's statement sequence (see `analyze_plain_script`), read with `scan_applescript`, which handles `\"`, `\\` and `\t` escapes and refuses `\n`/`\r`.
- **Any change to `HTMLPlan` must regenerate those templates (the command is in `README.md`, "When the binary's dry-run output changes"), and any change to the plain path's AppleScript must update `analyze_plain_script`, or every scenario on that path is refused.** Templates always match the binary of the branch they are on. The crafted HTML self-test cases build their variants from the templates and each asserts the reason it is refused (`run_analysis_case`'s fifth argument).
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
- The harness's resources (`E2E_RESOURCES`) are a fileset of this directory without `README.md`, `CLAUDE.md` and `vm.sh`, so editing the docs or the VM wrapper does not change the harness's store path.
- `packages.e2e-vm`, `apps.e2e-vm` and `checks.e2e-vm-shellcheck` package `vm.sh` the same way; building it only shellchecks the script. It gets the harness's resources through `E2E_VM_RESOURCES` (the same store path, which also supplies the profile), not this directory.

## Running it in a Tart VM (`vm.sh`)

`nix run .#e2e-vm` clones a prepared golden VM, runs the harness in the clone through `tart exec`, copies results back and deletes the clone; `--setup-golden` builds the golden VM with a human. `README.md` in this directory, "Running it in a Tart VM", has the details.

- Agents must not create, clone, run, stop or delete VMs, pull images, or run either mode without the user's explicit go-ahead: setup pulls about 32 GB, and a run drives Mail (inside the VM). Fine without asking: `tart list`, the wrapper's own `--help`, `nix run .#e2e-vm -- -- --help` and `-- --list` (the wrapper runs those in the harness on the host, where they only print), and building the package. Every other harness argument set boots a clone once the host-side argument check passes.
- Every boot passes `tart run --no-audio` (in `start_vm`'s `run_args`), so no VM plays sound on the host; keep it when adding display modes.
- Every step that can take long runs through `run_interruptibly` (a background job plus `wait`), because bash runs an INT/TERM trap only after a foreground child exits; a supervisor's TERM-then-KILL would otherwise leak a running clone. Keep new long steps on that path, and test signal handling with a stub `tart` on `PATH`, never a real VM. `run_interruptibly` passes its stdin on explicitly (`<&0`): a non-interactive bash gives background jobs `/dev/null`, which once made `install_authorized_key` write an empty key line.
- `vm.sh` runs under `pipefail`, so never pipe a command whose status matters into an early-exiting reader (`| grep -q`, `| head`, an awk or sed that quits): a match makes the producer die of SIGPIPE and the pipeline fail with 141. Capture the output first, then parse it from a here-string, and check the producer's own status. Do not hide a producer behind `| reader || true` either. Remote commands whose status is a yes/no answer go through `guest_test` (0 yes, 1 no, anything else stops setup), and those whose exit code overlaps failures (`lsof`, `pgrep` via `tart exec`) report it in-band.
- `--setup-golden` only touches a VM it created: it writes `golden-<name>.marker` in the state directory before cloning and refuses an existing VM without a matching marker.
- Anything that drives Mail must go through `tart exec`, never SSH: the guest agent runs in the GUI session, and the golden image's Automation and Accessibility grants belong to it as the responsible process. SSH is for `nix copy`, file transfer and logs only.
- The guest has `/nix` (official installer, pinned by URL and hash in `../../flake.nix`) with `trusted-users` including `admin`, and `nix copy` passes `--no-check-sigs`: host-built paths are unsigned, and the guest refuses them without both. `--binary` must resolve into `/nix/store`.
- SSH can come up before launchd has the guest's nix-daemon ready, and a copy then fails with "Nix daemon disconnected unexpectedly", so `copy_closure` first waits for `nix store info --store daemon` to succeed in the guest (bounded) and retries only that specific error, a few times with a growing pause; any other copy error stops at once.
- TCC charges `tart-guest-agent` as the responsible process for everything `tart exec` starts (the prompts name it, and tccd logs `AUTHREQ_ATTRIBUTION ... responsible=tart-guest-agent`), so the golden image's grants cover every rebuilt ad-hoc-signed binary, and clones keep them. Accessibility comes pre-granted to the agent by the Cirrus Labs image. Automation prompts can only be raised by `osascript`: when the binary is the requester, tccd's hardened-runtime policy wants the `com.apple.security.automation.apple-events` entitlement, so it denies the event (-1743) without showing a prompt. That is why setup asks through `osascript` before the approval pass; do not replace that step with a harness scenario.
- During `--setup-golden`, the harness's `--serve` runs in the guest (over SSH) from before the profile opens until the manual Mail steps are done: macOS checks each account's POP login (e2e-a on 1110, e2e-b through the forwarder on 1111) when installing the profile. It is stopped with SIGTERM to the harness, whose exit trap stops the watchdogs of Mailpit and the forwarder (they ignore SIGINT). `MAILPIT_PORTS` in `vm.sh` must list every port the harness's `--serve` binds, or a leftover listener goes undetected.
- `vm.sh` has no copy of e2e-b's SMTP hostname: `--setup-golden` reads `SMTP_B_ALIAS` from the harness's `e2e.sh` in `E2E_VM_RESOURCES` (`read_smtp_b_alias`) and stops before touching any VM unless there is exactly one plain `readonly SMTP_B_ALIAS=<lowercase hostname>` line. Keep that definition in that shape.
- Setup makes the guest's `/etc/hosts` satisfy the harness's `check_smtp_alias`: exactly the two mentions `127.0.0.1 name` and `::1 name` (any order and whitespace, `#` comments stripped, names compared case-insensitively, no other names on those lines). `ensure_hosts_lines` (sent to the guest's root `sh` with `declare -f`, so keep it POSIX) parses the file the same way, appends only the missing lines, TAB-separated, and refuses rather than edits anything else. Setup then checks with `dscacheutil` that the name resolves to exactly 127.0.0.1 and ::1.
- Setup duplicates two more harness checks so it fails before the first approval pass: nothing may answer on `[::1]:1025` (the harness's perl probe; only ECONNREFUSED passes) and no system proxy may be on (`scutil --proxy`, the harness's key list). These copies, and the hosts parsing above, must change with the harness's `check_smtp_alias`, `probe_ipv6_loopback` and `check_proxies`.
- `profiles remove` leaves a profile's mail accounts behind in `~/Library/Accounts/Accounts4.sqlite`, and reinstalling then fails with "already exists". `sqlite3 -readonly` reads that file over SSH as admin without Full Disk Access. The profile's POP rows carry its account description and the username `e2e-a` or `e2e-b`, and its SMTP rows the description with an empty username; `LEFTOVER_ACCOUNTS_QUERY` matches both. Setup stops with deletion steps when it finds any (or cannot read the file) and never deletes accounts itself.
