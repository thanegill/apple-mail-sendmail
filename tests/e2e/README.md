# Live end-to-end tests

The unit tests (see [`../../README.md`](../../README.md)) never touch
the real Mail. This harness, `nix run .#e2e`, runs
the real binary against Mail.app and checks what Mail actually puts on
the wire.

Mail sends to [Mailpit](https://mailpit.axllent.org/), a capture server
the harness starts on `127.0.0.1` (SMTP 1025, POP3 1110, API 8025) with a
fresh temporary database and stops on exit. It also starts a `socat`
forwarder from `127.0.0.1:1111` to Mailpit's POP3 port: macOS refuses two
POP accounts on the same host and port, so `e2e-b` fetches through 1111.

Each scenario pipes a fixture through the binary and asserts on
Mailpit's API: sender, To/Cc and envelope-only Bcc recipients, display
names, raw headers (no `Resent-*`, no `Bcc:`), the HTML part, and each
attachment's exact name, size and SHA-256.

A live run sends real messages from Mail. Run it only in a dedicated
macOS user or VM that has nothing but the two test accounts (see
[One-time setup](#one-time-setup)), or let `nix run .#e2e-vm` run it in a
disposable Tart VM (see [Running it in a Tart VM](#running-it-in-a-tart-vm)).

## Running it

Run these from the repository root:

```sh
nix run .#e2e -- --list          # scenarios and the PRs they depend on
nix run .#e2e -- --check-only    # fixtures, guards, sandboxed dry runs
nix run .#e2e -- --self-test     # proves the assertions and guards
nix run .#e2e                    # live run of every scenario
nix run .#e2e -- html-send bcc-only-html   # selected scenarios
nix run .#e2e -- --serve         # just Mailpit and the forwarder, for setup
```

`--check-only` and `--self-test` never drive Mail. They run the binary
only with `SENDMAIL_DRY_RUN=1` inside `sandbox-exec` with
[`dry-run.sb`](dry-run.sb), which denies:

- Apple Events;
- every Mach service lookup, so WindowServer, Launch Services and the
  Accessibility plumbing are unreachable;
- network access, fork and exec, signals and IOKit;
- any tty or pty device;
- deleting or renaming files;
- writing anywhere but a temp directory the harness creates for that
  one dry run.

The dry run also runs in a new session with no controlling terminal,
with stdin from the fixture and output to files. The sandbox does not
stop the binary reading files.

`--self-test` probes each rule on its own and the whole profile against
unsandboxed controls: a read-only Apple Event to Finder (`get name of
startup disk`), a fork, and a TIOCSTI keystroke into a private pty from
`script`. `lsopen` and `iokit-open` are only checked to be present. The
Finder control and the sandboxed `osascript` probes are the only
AppleScript the two modes run; neither talks to Mail or System Events.

### Results

A live run ends with a table of results, with the reason for each, then
a `RESULT:` line:

- **PASS**
- **FAIL**
- **REFUSED**: a guard refused the scenario before Mail was touched.
- **ABORTED**: a pre-scenario check stopped the run.
- **SKIP**: for example, no `e2e-b` account.

The run exits non-zero unless every selected scenario passed.
`--allow-refused` also accepts REFUSED, for runs against a binary that
lacks a PR some scenarios need; ABORTED, SKIP and FAIL always fail the
run. Ctrl-C stops the run at once, including a binary or AppleScript
that is running.

### Testing another build

To test another build, such as a PR branch, pass its binary:

```sh
nix run .#e2e -- --binary "$(nix build --no-link --print-out-paths \
  'github:thanegill/apple-mail-sendmail?ref=<branch>')/bin/apple-mail-sendmail"
```

Nine scenarios need an open PR (see `--list`). Against master's binary,
only three of them are refused by the guards: `bcc-only-plain` (#40),
`display-names-html` (#39) and `from-header-account-plain` (#38). The
other six run:

- `bcc-only-html` (#40), `display-names-plain` (#39) and
  `attachment-filename-plain` (#37) are expected to fail on master.
- The three #36 scenarios (`plain-attachment-send` and the two
  `draft-later-*`) are expected to pass on master, since they check that
  #36's temp-file cleanup does not break attachments.

### Display names

Display names must match exactly, with one exception. For a name that
has both an RFC 5322 special and a non-ASCII character (e.g.
`Bäcker, Anna`), Mail puts the quoted-string's quotes inside the
encoded-word, so it decodes as `"Bäcker, Anna"`, whatever form the
binary handed it. Exactly one surrounding pair of quotes is accepted in
that case only.

## Safety

Every guard fails closed: input that is missing, unparseable or
unexpected is a refusal. A scenario that fails a guard is skipped
(reported as REFUSED), never run.

### Before Mail is touched

- **Addresses.** Each fixture's top-level headers must be on a short
  allowlist, and every address header (From, Sender, Reply-To, To, Cc,
  Bcc) must parse completely as `local@example.test`,
  `"Name" <local@example.test>`, `Name <local@example.test>` or groups
  of those. `example.test` is a reserved domain that never resolves.
  From and Sender must be `e2e-a@example.test` or `e2e-b@example.test`.
- **Argv** is parsed the way the binary parses it (bundled flags, `--`):
  positional recipients must be bare `@example.test` addresses and `-f`
  an e2e account.
- **The binary** is copied into the run's work directory and hashed once.
  Dry runs and live runs use that copy, and each live scenario re-checks
  its hash and the hash of the fixture that passed the guards.
- **The dry-run output.** A sandboxed dry run of the binary must print
  exactly the expected steps:
  - The HTML path prints its step plan, one JSON object per line, from
    the same code a live run executes. It must equal
    [`templates/`](templates) for its mode once the `.eml` path is
    replaced, so an extra press, a dropped guard check or a changed
    retry bound is refused. The plan must have exactly one `open_eml`
    step, whose path has no quote or backslash. That `.eml` must exist
    inside the dry run's temp dir and pass the same header checks; the
    sandbox forbids deleting files, so it survives even a binary that
    cleans up.
  - Output or an `.eml` containing a NUL byte is refused before anything
    reads it.
  - The plain path prints its step plan too, one JSON object per line,
    read with `jq`. Each line must be exactly `jq`'s compact, key-sorted
    form of itself (so a duplicated key or stray whitespace is refused),
    have exactly its step's keys and value types, and the steps must come
    in order: launch, make the message, set its content, recipients,
    attachments, and `send` only for a send run. That means one message
    whose `sender` holds exactly one e2e account (otherwise Mail would
    use its default account); `visible` true and no `send` for a draft,
    or `visible` false and one `send` otherwise; recipients with exactly
    one allowed address each; and attachments that are files in the dry
    run's temp dir.

### Mail's state, checked before every scenario

- **Mail must already be running.** The preflight does not launch it.
- **Accounts.** A read-only AppleScript preflight requires an enabled
  account for `e2e-a@example.test` whose incoming and outgoing servers
  are exactly `127.0.0.1:1110` and `127.0.0.1:1025`. For `e2e-b`, if
  present, they must be `127.0.0.1:1111` and `e2e-b-smtp.test:1025`, and
  the alias is accepted only while it resolves to this machine alone
  (see [One-time setup](#one-time-setup), step 1).
- **No other enabled account.**
- **No other SMTP server**, enabled or not, including a disabled
  account's, other than Mailpit's exact `127.0.0.1:1025` and
  `e2e-b-smtp.test:1025`. A local relay such as a mail bridge on another
  `127.0.0.1` port is refused too.
- **No enabled Mail rule.** Rules act on the test mail Mail fetches;
  Mail's built-in "News From Apple" rule counts.
- **No system proxy**: HTTP, HTTPS, SOCKS or automatic configuration, as
  read from `scutil --proxy`. Mail honours them, and a SOCKS proxy
  resolves names on the proxy side, bypassing `/etc/hosts`.
- **An empty Outbox, no message selected in Mail's viewer, and no window
  other than its main viewer windows.** Standalone message windows and
  the Settings window also count, because Mail's dictionary cannot tell
  them apart from a compose window. Mail's `outgoing messages` count is
  logged but not checked: Mail keeps every plain-text message it has
  sent in that list until it is relaunched, so it cannot tell an open
  compose from a sent one. An open compose is a non-viewer window and is
  refused.

The account preflight runs again before every scenario, so an account
or rule switched on mid-run stops the run.

**Close every compose window first, and select an empty mailbox.**
Message > Send Again, which the HTML path presses, acts on Mail's key
window: it is Send Again on a viewer but Send on a compose window. The
binary presses only after checking that its own viewer or compose is
Mail's key and main window and that Mail is frontmost, but the check
cannot close the gap before the press entirely. With nothing selected,
a stray Send Again has nothing to resend.

### Mailpit

- Every Mailpit the harness or its self-test starts gets an empty
  environment (plus only the variables a self-test case needs), so
  `MP_*` variables that would make it relay, forward, call a webhook or
  use SpamAssassin are not inherited.
- The harness's Mailpit must:
  - be the only thing on its ports;
  - answer with its own SMTP and POP3 banners;
  - report relaying and SpamAssassin off through its API, with no relay
    or forward line in its log (webhooks show in neither, so the empty
    environment is what rules them out);
  - still be running before each scenario.
- Every `curl` ignores `~/.curlrc` and proxies.
- Mailpit runs in its own session under a small watchdog, so Ctrl-C does
  not reach it. The watchdog stops it when the harness exits, even if the
  harness is killed.

### Stopping

- A run refused by the preflight stops Mailpit at once.
- Once the binary has run against Mail, the harness ends every run
  (including one stopped by Ctrl-C) by waiting up to a minute for Mail's
  Outbox to empty, then prints what is still open, queued or selected in
  Mail.
- If it cannot confirm the Outbox is empty (including when Mail cannot
  be read), it says a message may be stuck and **leaves Mailpit
  running**, keeping the work directory, so Mail can still deliver. The
  report gives the `kill` command to stop it afterwards.
- A second Ctrl-C during that wait stops Mailpit at once.

If Mail ever says it cannot send using `127.0.0.1` or `e2e-b-smtp.test`
and offers other servers, **never pick one**: that would send the test
message through a real account. Delete the message from the Outbox
instead.

### Matching the draft window by title

The draft-then-send scenarios click Message > Send in the window titled
with that scenario's subject. The product never matches windows by title
(subjects can be empty, duplicated or rewritten), but here the subject is
unique to the run, so a title match cannot hit an unrelated window. The
click is refused unless exactly one window has that title and is
frontmost.

## One-time setup

Run the harness from a dedicated macOS user that has only the e2e
accounts. If other accounts exist there, delete them and remove their
SMTP servers: disabling an account is not enough, because its SMTP
server stays in Mail's list and the preflight refuses it.

In that user, from the repository root:

1. Map `e2e-b`'s SMTP alias to this machine, for both IPv4 and IPv6,
   and flush the DNS cache:

   ```sh
   sudo sh -c 'printf "127.0.0.1\te2e-b-smtp.test\n::1\te2e-b-smtp.test\n" >> /etc/hosts'
   sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
   ```

   macOS 27 allows only one profile-managed SMTP account per host (the
   install fails with "This account already exists"; the log says "Only
   a single "SMTP" account is allowed to be saved"). So `e2e-b` sends
   through `e2e-b-smtp.test:1025` while `e2e-a` uses `127.0.0.1:1025`.
   The name is defined once, as `SMTP_B_ALIAS` in [`e2e.sh`](e2e.sh); the
   profile must match it (`--self-test` checks).

   Both lines are needed. With only the IPv4 one, macOS answers the A
   query from `/etc/hosts` but sends the AAAA query to DNS, so an outside
   IPv6 answer could reach Mail. Before using the alias, the preflight
   and every scenario check that:
   - `/etc/hosts` has exactly those two lines for it;
   - the system resolver (`dscacheutil`, which is what Mail uses and the
     authoritative check) gives exactly 127.0.0.1 and ::1;
   - nothing listens on `[::1]:1025` (Mailpit binds 127.0.0.1 only, so
     Mail's IPv6 attempt is refused and it falls back to 127.0.0.1);
   - `dig` gets no answer for it. This is an extra check of the servers
     in `/etc/resolv.conf` only, not of `/etc/resolver/*`, scoped or VPN
     DNS, DNS over HTTPS or Private Relay. Only "no answer" or "no server
     reachable" passes; any other `dig` failure refuses.

   `.test` is reserved and never resolves publicly, but that is not
   relied on.
2. Start Mailpit and leave it running for the next step, because macOS
   logs in to the POP server when it installs the accounts:

   ```sh
   nix run .#e2e -- --serve
   ```

   It serves POP3 on `127.0.0.1:1110` (for `e2e-a`) and, through its
   forwarder, `127.0.0.1:1111` (for `e2e-b`), and SMTP on 1025, which
   `e2e-b` reaches through the alias.

   Then, in another terminal, install the two Mail accounts:
   - `e2e-a@example.test`, with SMTP on `127.0.0.1:1025`;
   - `e2e-b@example.test`, with SMTP on `e2e-b-smtp.test:1025`;
   - POP password `e2e-local-only` for both.

   Mail's AppleScript `make new pop account` creates accounts that never
   appear in Mail's settings, so the repo ships a configuration profile,
   [`e2e-accounts.mobileconfig`](e2e-accounts.mobileconfig), instead:

   ```sh
   open tests/e2e/e2e-accounts.mobileconfig
   ```

   Approve it in **System Settings -> General -> Device Management**,
   then stop `--serve` with Ctrl-C.

   To add the accounts by hand instead, use **Mail -> Settings ->
   Accounts -> + -> Other Mail Account** while `--serve` runs:
   - POP server `127.0.0.1`, port 1110 for `e2e-a` and 1111 for `e2e-b`;
   - SMTP server `127.0.0.1` for `e2e-a` and `e2e-b-smtp.test` for
     `e2e-b`, port 1025;
   - not `localhost`, no TLS, and no SMTP authentication.

   On a fresh Mail, quit and relaunch it once after its first-run
   sheets: they leave an invisible, untitled window behind, which the
   window check refuses until Mail is relaunched.
3. In Mail's settings:
   - For both accounts, set **Remove copy from server after retrieving a
     message** to **Never** or to a number of days. The preflight
     refuses "right away", which would delete messages before they are
     checked, and refuses if it cannot read the setting.
   - Disable or delete every rule under **Rules**.
   - Remove every other SMTP server (**Accounts -> Server Settings ->
     Outgoing Mail Account -> Edit SMTP Server List**); only Mailpit's
     `127.0.0.1:1025` and `e2e-b-smtp.test:1025` may remain.
4. Grant the terminal you run from **Accessibility** (System Settings
   -> Privacy & Security -> Accessibility; on macOS 27 and later,
   Privacy & Security -> Device Control and Data Access), which the
   binary's HTML path needs, and allow its **Automation** requests for
   Mail and System Events on the first run: the binary's plain path
   needs Mail, and the harness's own AppleScripts need both.

Only `e2e-a` is required. Scenarios that send from `e2e-b` are skipped
when that account is missing. While Mailpit is not running, Mail reports
the e2e accounts as offline; that is expected.

## When the binary's dry-run output changes

The HTML-path templates in [`templates/`](templates)
(`html-plan-{send,draft}.jsonl.tmpl`) are the dry-run step plans of the
binary on the branch the harness lives on, with the `.eml` path replaced
by `<EML>`. A branch that changes `HTMLPlan` makes every HTML scenario
refuse, with a "plan differs from the … template" diff, until the
templates are regenerated from that branch's binary. Review the diff
before committing it. From the repository root:

```sh
nix build
printf 'From: e2e-a@example.test\nTo: x@example.test\nSubject: t\nMIME-Version: 1.0\nContent-Type: text/html\n\n<p>t</p>\n' >/tmp/template.eml
for mode in send draft; do
  args=(-t); [ "$mode" = send ] && args+=(--send)
  SENDMAIL_DRY_RUN=1 ./result/bin/apple-mail-sendmail "${args[@]}" </tmp/template.eml |
    sed -E 's#^(\{"activates":true,"path":)"/[^"\\]*\.eml"(,"step":"open_eml"\})$#\1"<EML>"\2#' \
      >"tests/e2e/templates/html-plan-$mode.jsonl.tmpl"
done
```

A binary that keeps its temp files leaves one `sendmail-*` directory per
mode in its temp dir. The plain path's plan has no template: a change to
`PlainPlan` needs `analyze_plain_plan` (and its `PLAIN_STEP_JQ` program)
in [`e2e.sh`](e2e.sh) updated instead.

## Running it in a Tart VM

A live run presses Message > Send Again and Message > Send in Mail, which
act on whichever Mail window is key, so running it on your own desktop is
risky. `nix run .#e2e-vm`
([`vm.sh`](vm.sh)) runs the same harness inside a throwaway macOS VM
instead, using [Tart](https://tart.run) (in the dev shell; Apple Silicon
only). From the repository root:

```sh
nix run .#e2e-vm -- --setup-golden          # once, guided (see below)
nix run .#e2e-vm                            # every scenario, in a fresh clone
nix run .#e2e-vm -- html-send bcc-only-html # harness arguments pass through
nix run .#e2e-vm -- --check-only            # also boots a clone
nix run .#e2e-vm -- -- --help               # the harness's help; no VM
nix run .#e2e-vm -- --list                  # its scenario list; no VM
```

Wrapper options (`--golden`, `--results`, `--boot-timeout`,
`--mail-settle`, `--vnc` for setup, `--help`) come first; the first other
argument, or everything after `--`, goes to the harness. Which commands
boot a VM:

- `-h`, `--help` or `--list` for the harness run it on the host, where it
  only prints. No VM boots.
- `--serve` is refused; run `nix run .#e2e -- --serve` on the host.
- Anything else is first checked on the host by the harness's own
  parser, which rejects unknown options and scenario names and malformed
  values; only if that passes does a clone boot. That includes
  `--check-only` and `--self-test`, which then run inside the VM.

Each run:

1. clones the golden VM (`sendmail-e2e-golden`, or `--golden NAME`) to
   `sendmail-e2e-golden-run-<time>-<pid>` (an APFS clone, so it takes
   seconds and little disk) and boots it headless, with `tart run
   --no-audio` so no VM plays sound on the host;
2. waits for the Tart guest agent, which answers once the auto-login
   session is up, then for SSH;
3. waits (up to 60 seconds) until the guest's nix-daemon answers, then
   copies the harness's Nix closure (about 200 MB, most of it already in
   the golden image) into the guest with `nix copy` over SSH, retrying up
   to three times if the daemon disconnects (it can still be starting
   after boot);
4. launches Mail with `tart exec` and runs the harness there with your
   arguments plus `--keep`, streaming its output;
5. copies the harness's work directory, the guest's TCC log for the run
   and the guest agent's log into
   `~/.local/state/apple-mail-sendmail-e2e-vm/results/<clone>/`
   (`--results DIR` to change);
6. stops and deletes the clone, also on failure, Ctrl-C or SIGTERM
   (results are still collected if the guest is up). Only SIGKILL can
   leave a clone behind; the next run lists any such clone and whether
   it is still running (`tart stop NAME`, then `tart delete NAME`).

The exit status is the harness's. `--binary PATH` works as with
`nix run .#e2e`, as long as `PATH` resolves into `/nix/store`; its closure
is copied in too.

**How it reaches the guest.** The harness and binary reference
`/nix/store` paths (the Swift runtime, Mailpit, bash and the rest), so
the golden image has Nix installed (the official installer, pinned in
[`../../flake.nix`](../../flake.nix)) and trusts the `admin` user, and each run
copies the closure in with `nix copy --no-check-sigs` (host-built paths
are unsigned, and the guest refuses them otherwise). Everything that
drives Mail runs through `tart exec`, whose guest agent is a LaunchAgent
in the logged-in GUI session; SSH is used only for `nix copy`, file
transfer and logs. SSH uses a key generated in
`~/.local/state/apple-mail-sendmail-e2e-vm/` and the golden image's host
key, pinned during setup over the agent's channel. Every clone boots from
a copy of the golden disk, so the pin covers the whole image lineage.

**Permissions.** macOS charges an Apple Event or Accessibility call to the
*responsible* process, and for everything `tart exec` starts that is
`tart-guest-agent`: the Automation prompts name it, and the guest's TCC
log records `responsible=tart-guest-agent`. The golden image's grants to
the agent (Automation for Mail and System Events, given during setup;
Accessibility, which the Cirrus Labs image grants in advance) therefore
cover the harness, `osascript` and the binary however often the
ad-hoc-signed binary is rebuilt, and every clone keeps them. Only
`osascript` can raise an Automation prompt: when the binary asks, macOS
denies the event (error -1743) without a prompt, because the agent lacks
the hardened-runtime Apple Events entitlement. Every run saves the
guest's TCC log (`tcc.log`) and prints the `AUTHREQ` lines that name the
agent, `osascript`, the binary, or the Automation and Accessibility
services.

### Preparing the golden VM

`nix run .#e2e-vm -- --setup-golden` (add `--base-image REF` for another
image than `ghcr.io/cirruslabs/macos-golden-gate-base:latest`) pulls the
base image the first time (about 32 GB to download, about 50 GB on disk),
boots it with a window, and then automatically:

- installs an SSH key for `admin` and pins the guest's SSH host key;
- turns on auto-login for `admin` if it is off, and turns off sleep;
- installs Nix with `trusted-users = root admin` and copies the
  harness's closure in;
- adds whichever of the `127.0.0.1 e2e-b-smtp.test` and
  `::1 e2e-b-smtp.test` lines the guest's `/etc/hosts` lacks (so neither
  the IPv4 nor the IPv6 lookup goes to real DNS), flushes the DNS cache
  and checks that the name resolves to exactly 127.0.0.1 and ::1: macOS
  27 keeps a single profile-managed SMTP account per host, so `e2e-b`
  sends through that name (see [One-time setup](#one-time-setup), step
  1). Existing lines count if the harness would accept them (any
  whitespace, trailing comments). The name is read from the harness's
  single definition (`SMTP_B_ALIAS` in [`e2e.sh`](e2e.sh)), and setup
  stops before touching any VM if it cannot read it. It also stops if
  `/etc/hosts` maps the name any other way, if anything answers on
  `[::1]:1025`, or if a system proxy is on, all of which the harness's
  preflight would refuse later;
- before the profile is installed, checks the guest's account database
  read-only for e2e mail accounts left from an earlier install, both the
  POP accounts and their SMTP servers (removing a profile with
  `profiles remove` leaves them behind, and installing it again then
  fails with "already exists"), and stops, asking you to delete them in
  **Mail -> Settings -> Accounts** (select, then the minus button);
- starts the harness's Mailpit (`--serve`, which also starts the POP3
  forwarder) in the guest, because macOS checks each account's POP login
  when the profile is installed: e2e-a on `127.0.0.1:1110`, e2e-b through
  the forwarder on `127.0.0.1:1111` ("Unable to verify account name or
  password" otherwise);
- copies [`e2e-accounts.mobileconfig`](e2e-accounts.mobileconfig) to the
  guest's Desktop and opens it, which queues it in System Settings.

It then prints the manual steps and waits: install the profile, open
Mail, dismiss its first-run sheets and relaunch it once (the sheets
leave an invisible window behind that the harness's window check
refuses), set both accounts to never remove messages from the server,
turn off every rule, check the SMTP server list, and select an empty
mailbox. It then stops that Mailpit and asks for Automation access with
`osascript` through `tart exec`, once for Mail and once for System
Events; click Allow on each prompt, which must name `tart-guest-agent`.
Next it runs the harness's `plain-send` and `html-send` scenarios through
`tart exec`, as often as you like. A pass counts only if the harness
exits 0, its summary ends in `RESULT: success`, and both scenarios' rows
say PASS. Last, you quit Mail (the script checks that it has) and the VM
shuts down.

With `--vnc`, setup boots the VM with Virtualization.framework's VNC
server instead of a window; the `vnc://` URL and its password are in
the setup's `tart-run.log`. A VNC client, or a tool such as vncdotool,
can then do every manual step, including the profile approval and the
Allow buttons, because its input reaches the guest as hardware input.

Setup writes `golden-<name>.marker` in the state directory before it
clones. Rerunning `--setup-golden` resumes only a VM with a matching
marker, where each automatic step checks whether it is already done; it
refuses to touch any other VM of that name.

If an approval pass fails with mail stuck in Mail's Outbox, the harness
leaves its Mailpit and POP3 forwarder running in the guest so Mail can
still deliver, and the next pass could not bind their ports (1025, 1110,
1111, 8025). Before each pass the script checks for that, shows the
process, asks you to empty the Outbox in the VM, and offers to stop it.

If setup is interrupted while Nix is installing, the next
`--setup-golden` stops with a message rather than run the installer
over its leftovers, which it refuses. Start over (the base image usually
stays in Tart's cache, so nothing is downloaded again), from the
repository root:

```sh
tart delete sendmail-e2e-golden
rm ~/.local/state/apple-mail-sendmail-e2e-vm/golden-sendmail-e2e-golden.marker
nix run .#e2e-vm -- --setup-golden
```

or uninstall Nix inside the VM following the macOS steps in the
[Nix manual](https://nix.dev/manual/nix/stable/installation/uninstall.html)
and rerun `--setup-golden`.
