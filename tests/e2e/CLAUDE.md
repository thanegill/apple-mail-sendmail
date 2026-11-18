# CLAUDE.md (tests/e2e/)

Guidance for changing the live end-to-end harness (`e2e.sh`, `nix run .#e2e`) and its Tart VM wrapper (`vm.sh`, `nix run .#e2e-vm`). Setup, safety rules and how to run them are in `README.md` in this directory; the repository's guidance is in `../../CLAUDE.md`.

## Running it

- **A plain `nix run .#e2e` drives Mail.app and sends mail.** Agents must not run it, or anything that runs `osascript`, without the user's explicit go-ahead. `--check-only` and `--self-test` do not drive Mail.
- Run `--self-test` after changing any assertion, guard, parser or `dry-run.sb`. It probes each sandbox rule alone and the whole profile against unsandboxed controls; `lsopen` and `iokit-open` are only presence-checked.

## Guards

- Every guard fails closed. Address headers and argv go through allowlist parsers (`parse_address_list`, `guard_argv`, which parses argv the way the binary does). Keep new checks in that shape: refuse on anything unrecognised, and add a self-test case for the bypass.
- Dry-run output is matched structurally, by the path each scenario names in `EXPECT_PATH`: `eml` (the default) or `apple-events` (`plain-send-no-ui`). The `.eml` plan must equal `templates/eml-plan-{send,draft}.jsonl.tmpl` apart from the `.eml` path (`analyze_eml_plan`: exactly one `open_eml` step, path without a quote or backslash, and that `.eml` must exist in the dry run's temp dir and pass the header guards; `dry-run.sb` forbids deletes so it survives a binary that cleans up). `analyze_plain_plan` requires each plain-plan line to equal `jq -cS` of itself (no duplicate keys or whitespace variants), checks each step's exact keys and types with `PLAIN_STEP_JQ`, passes the strings it checks out base64-encoded, and requires the order launch, make, content, recipients, attachments, then `send` only for a send run.
- **Any change to `EmlPlan` must regenerate those templates (`README.md`, "When the binary's dry-run output changes"), and any change to `PlainPlan` must update `analyze_plain_plan`, or every scenario on that path is refused.** Templates always match the binary of the branch they are on. The crafted self-test cases build their variants from the templates (`.eml` path) or `plain_plan` (`--no-ui`; `run_analysis_case` takes `plain-send-no-ui:draft` for a draft variant), and each asserts the reason it is refused (`run_analysis_case`'s fifth argument).
- The dry-run self-test requires the binary to refuse `--send` with a missing, empty or whitespace-only Subject (exit 65, both paths) and to accept a draft without one, because Mail would hold such a message unsent.
- `guard_argv` accepts `--no-ui` like `--send`, and dry and live runs unset `SENDMAIL_NO_UI` (with `SENDMAIL_SEND`), so only argv chooses the path.
- e2e-b sends through `SMTP_B_ALIAS` (defined once in `e2e.sh`; the profile must match, and `--self-test` checks it) because macOS 27 allows only one profile-managed SMTP account per host. `check_smtp_alias`'s `dig` check is an extra look at resolv.conf's servers only, not `/etc/resolver/*`, scoped or VPN DNS, DNS over HTTPS or Private Relay; it passes only on exit 0 with no answer, or exit 9. `dscacheutil` is the authoritative gate.
- `check_proxies` and `check_smtp_alias` run inside `check_accounts`, so before every scenario too. Self-tests stub them and add read-only positive controls with the real tools; never edit the real `/etc/hosts` from the harness.
- Mail keeps messages sent with `--no-ui` in `outgoing messages` until it is relaunched, so that count is logged, not checked; compose windows are caught as non-viewer windows instead.

## Mailpit

- Every Mailpit, including self-test sinks and controls, starts under `env -i` with only the `MP_*` variables that case needs. Webhooks show in neither `/api/v1/webui` nor the log, so the empty environment is what rules them out.
- It runs in its own session under the `run_supervised` watchdog, because Go Mailpit would otherwise exit on the terminal's Ctrl-C before the Outbox drain. The watchdog stops it when the harness exits, even by SIGKILL, unless cleanup detached it because the Outbox drain could not confirm empty.
- Every `curl` goes through `CURL` (`-q --noproxy '*'`). Do not add a bare `curl` or a bare `mailpit`.
- The `socat` POP3 forwarder (1111 -> 1110) is started, stopped and supervised with Mailpit; `--serve` starts it too, since profile installation needs both ports up.
- Mailpit prepends its own trace headers (and a `Bcc:` header for envelope-only recipients) to the stored raw message. Header assertions must use `sender_headers`, which keeps only what follows Mailpit's `Received:` line, or every Bcc scenario reports a Bcc header that Mail never sent.

## Mail and the AppleScripts

- Every place the harness touches Mail is `/usr/bin/osascript` in `e2e.sh` (`preflight.applescript`, `mail-windows.applescript`, both read-only, and `send-compose-window.applescript`) plus the binary itself in live mode. Keep it that way, so the surface stays reviewable. All run under `timeout --foreground` so Ctrl-C reaches them at once.
- `send-compose-window.applescript` matches the compose window by title, which the product must never do. It is acceptable here only because the subject embeds the run's timestamp and a random number, and the click is refused unless exactly one window has that title and is frontmost.
- In `send-compose-window.applescript`, do not name variables after System Events terms (`titled` is a window property): inside `tell process`, `set titled to …` sets that property instead of a variable.
- Mail serialises a From display name with both an RFC 5322 special and a non-ASCII character as one encoded-word with the quoted-string's quotes inside it (`=?utf-8?B?IkLDpGNrZXIsIEFubmEi?=`). `display_name_matches` accepts exactly one surrounding pair of quotes in that case only.

## Shell

- `writeShellApplication` runs `e2e.sh` and `vm.sh` under `pipefail`. Never end a status-bearing pipeline in an early-exit reader (`grep -q`, `head`, an awk or sed that quits): the producer gets SIGPIPE and the pipeline reports 141 exactly when the match is found. Capture the output first, check the producer's status, then match on a here-string (see `mail_is_running`). Do not hide a producer behind `| reader || true` either.

## Scenarios

- New scenarios: add a `define_<name>` function that sets a one-line `DESCRIPTION` (what `--list` prints) and list it in `SCENARIOS`. Recipients must be `@example.test` and the sender an e2e account, or the guards refuse it.
- Attachment names are matched exactly. On the `.eml` path an attachment keeps its own name; a `--no-ui` attachment arrives under the binary's temp name (`att-01-<name>`).
- `check_quoting` runs for every scenario (FB11734014: Mail quotes a body set through its dictionary). With `EXPECT_QUOTED=false` (the default) a `text/plain` line matching `^>( |$)` fails unless the fixture's own body has that exact line, and so does a `<blockquote type="cite">` the fixture lacks. `plain-send-no-ui` sets `EXPECT_QUOTED=true` and requires the marker on a quoted line only, and the cite blockquote if there is an HTML part, so it fails when Apple fixes the bug; then switch it to `EXPECT_QUOTED=false` and reconsider making `--no-ui` less of a last resort. The self-test's `body-quoted` and `html-cite-wrapped` variants (and `body-unquoted` and `html-cite-dropped` for the quoted scenario, built by `quote_wire_body`) must FAIL.
- The self-test derives its broken variants from the scenario's expectations, so a new scenario is covered by `--self-test` automatically.

## Packaging

- The harness's resources (`E2E_RESOURCES`) are a fileset of this directory without `README.md`, `CLAUDE.md` and `vm.sh`, so editing the docs or the VM wrapper does not change the harness's store path. `vm.sh` gets the same store path through `E2E_VM_RESOURCES`, which also supplies the profile.

## Running it in a Tart VM (`vm.sh`)

- Agents must not create, clone, run, stop or delete VMs, pull images, or run either mode without the user's explicit go-ahead: setup pulls about 32 GB, and a run drives Mail (inside the VM). Fine without asking: `tart list`, the wrapper's own `--help`, `nix run .#e2e-vm -- -- --help` and `-- --list` (run on the host, where they only print), and building the package. Every other harness argument set boots a clone once the host-side argument check passes.
- Every boot passes `tart run --no-audio` (in `start_vm`'s `run_args`), so no VM plays sound on the host; keep it when adding display modes.
- Every step that can take long runs through `run_interruptibly` (a background job plus `wait`), because bash runs an INT/TERM trap only after a foreground child exits, so a supervisor's TERM-then-KILL would otherwise leak a running clone. Keep new long steps on that path, and test signal handling with a stub `tart` on `PATH`, never a real VM. `run_interruptibly` passes its stdin on explicitly (`<&0`): a non-interactive bash gives background jobs `/dev/null`.
- Remote commands whose status is a yes/no answer go through `guest_test` (0 yes, 1 no, anything else stops setup), and those whose exit code overlaps failures (`lsof`, `pgrep` via `tart exec`) report it in-band.
- An approval pass counts only if the harness exits 0 and its summary has a `RESULT: success` line and a `<scenario>   PASS` row for each of `APPROVAL_SCENARIOS` (`approval_pass_passed`). `self_test_summary` in `e2e.sh` checks the summary with the same patterns, so change the summary format, those patterns and that self-test together.
- `--setup-golden` only touches a VM it created: it writes `golden-<name>.marker` before cloning and refuses an existing VM without a matching marker.
- Anything that drives Mail must go through `tart exec`, never SSH: the guest agent runs in the GUI session, and the golden image's Automation and Accessibility grants belong to it as the responsible process. SSH is for `nix copy`, file transfer and logs only.
- The guest has `/nix` (official installer, pinned by URL and hash in `../../flake.nix`) with `trusted-users` including `admin`, and `nix copy` passes `--no-check-sigs`: host-built paths are unsigned, and the guest refuses them without both. `--binary` must resolve into `/nix/store`.
- SSH can come up before launchd has the guest's nix-daemon ready, and a copy then fails with "Nix daemon disconnected unexpectedly", so `copy_closure` first waits for `nix store info --store daemon` (bounded) and retries only that error, a few times with a growing pause; any other copy error stops at once.
- Automation prompts can only be raised by `osascript`: when the binary is the requester, tccd's hardened-runtime policy wants the `com.apple.security.automation.apple-events` entitlement, so it denies the event (-1743) without a prompt (tccd logs `AUTHREQ_ATTRIBUTION ... responsible=tart-guest-agent`). That is why setup asks through `osascript` before the approval pass; do not replace that step with a harness scenario.
- During `--setup-golden`, the harness's `--serve` runs in the guest (over SSH) from before the profile opens until the manual Mail steps are done, because macOS checks each account's POP login when installing the profile. It is stopped with SIGTERM to the harness, whose exit trap stops the watchdogs (they ignore SIGINT). `MAILPIT_PORTS` in `vm.sh` must list every port `--serve` binds, or a leftover listener goes undetected.
- `vm.sh` has no copy of e2e-b's SMTP hostname: `read_smtp_b_alias` reads it from `e2e.sh` in `E2E_VM_RESOURCES` and stops before touching any VM unless there is exactly one plain `readonly SMTP_B_ALIAS=<lowercase hostname>` line. Keep that definition in that shape.
- Setup makes the guest's `/etc/hosts` satisfy `check_smtp_alias`: exactly the two mentions `127.0.0.1 name` and `::1 name` (any order and whitespace, `#` comments stripped, names compared case-insensitively, no other names on those lines). `ensure_hosts_lines` (sent to the guest's root `sh` with `declare -f`, so keep it POSIX) parses the file the same way, appends only the missing lines and refuses rather than edits anything else.
- Setup duplicates two more harness checks so it fails before the first approval pass: nothing may answer on `[::1]:1025` (the harness's perl probe; only ECONNREFUSED passes) and no system proxy may be on (`scutil --proxy`, the harness's key list). These copies, and the hosts parsing above, must change with the harness's `check_smtp_alias`, `probe_ipv6_loopback` and `check_proxies`.
- `profiles remove` leaves a profile's mail accounts behind in `~/Library/Accounts/Accounts4.sqlite`. `sqlite3 -readonly` reads that file over SSH as admin without Full Disk Access. The profile's POP rows carry its account description and the username `e2e-a` or `e2e-b`, and its SMTP rows the description with an empty username; `LEFTOVER_ACCOUNTS_QUERY` matches both. Setup stops with deletion steps when it finds any (or cannot read the file) and never deletes accounts itself.
