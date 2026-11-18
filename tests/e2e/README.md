# Live end-to-end tests

`nix run .#e2e` runs the real binary against Mail.app and checks what
Mail actually sends. Mail sends to [Mailpit](https://mailpit.axllent.org/),
a capture server the harness starts on `127.0.0.1` (SMTP 1025, POP3
1110, API 8025) with a fresh database and stops on exit. A `socat`
forwarder on `127.0.0.1:1111` lets `e2e-b` fetch from the same Mailpit,
because macOS refuses two POP accounts on the same host and port.

Each scenario pipes a fixture through the binary and asserts on
Mailpit's API: sender, To/Cc and envelope-only Bcc recipients, display
names, raw headers (no `Resent-*`, no `Bcc:`), the HTML part, each
attachment's exact name, size and SHA-256, and that the body is not sent
as a quotation. The `subject-*` scenarios (folded, `Re:`/`Fwd:` and
encoded Subjects) also read the binary's unified-log trace with `log
show` and check that every press followed a title check that found the
Subject in Mail's window title.

Every scenario but `plain-send-no-ui` runs the binary's default `.eml`
path. `plain-send-no-ui` runs the `--no-ui` Apple Event path, on which
Mail sends the body as a quotation (Mail bug FB11734014), so it asserts
the quoting *is* there and fails once Apple fixes the bug. Every other
scenario fails on a `text/plain` line starting with `> ` or a
`<blockquote type="cite">` that the fixture does not have; checking only
that the body contains the scenario's marker would pass a quoted body.

A live run sends real messages from Mail. Run it only in a dedicated
macOS user or VM that has nothing but the two test accounts (see
[One-time setup](#one-time-setup)), or let `nix run .#e2e-vm` run it in
a disposable Tart VM (see [Running it in a Tart VM](#running-it-in-a-tart-vm)).
CI cannot run it; when it must be run is in
[`RELEASING.md`](../../RELEASING.md#live-end-to-end-tests).

## Running it

From the repository root:

```sh
nix run .#e2e -- --list          # scenarios and what each one checks
nix run .#e2e -- --check-only    # fixtures, guards, sandboxed dry runs
nix run .#e2e -- --self-test     # proves the assertions and guards
nix run .#e2e                    # live run of every scenario
nix run .#e2e -- html-send bcc-only-html   # selected scenarios
nix run .#e2e -- --serve         # just Mailpit and the forwarder, for setup
```

`--check-only` and `--self-test` never drive Mail. They run the binary
only with `SENDMAIL_DRY_RUN=1`, inside `sandbox-exec` with
[`dry-run.sb`](dry-run.sb) and in a new session with no controlling
terminal. The profile denies Apple Events, every Mach service lookup
(so WindowServer, Launch Services and Accessibility are unreachable),
network, fork and exec, signals, IOKit, tty and pty devices, deletes
and renames, and writes outside a per-run temp directory; it does not
stop reads. `--self-test` checks each rule against unsandboxed
controls: a read-only Apple Event to Finder, a fork, and a TIOCSTI
keystroke into a private pty. Those and the sandboxed `osascript`
probes are the only AppleScript these modes run; none talks to Mail or
System Events.

### Results

A live run ends with a table of each scenario's result and the reasons
for any that did not pass, then a `RESULT:` line. Results are PASS,
FAIL, REFUSED (a guard refused the scenario before Mail was touched),
ABORTED (a pre-scenario check stopped the run) and SKIP (for example,
no `e2e-b` account). The run exits non-zero unless every selected
scenario passed; `--allow-refused` also accepts REFUSED, for an older
binary whose dry-run output some guards refuse. Ctrl-C stops the run at
once, including a running binary or AppleScript.

### Testing another build

```sh
nix run .#e2e -- --binary "$(nix build --no-link --print-out-paths \
  'github:thanegill/apple-mail-sendmail?ref=<branch>')/bin/apple-mail-sendmail"
```

### Display names

Display names must match exactly, with one exception. For a name with
both an RFC 5322 special and a non-ASCII character (e.g. `Bäcker,
Anna`), Mail puts the quoted-string's quotes inside the encoded-word,
so it decodes as `"Bäcker, Anna"` whatever form the binary handed it.
Exactly one surrounding pair of quotes is accepted in that case only.

## Safety

Every guard fails closed: input that is missing, unparseable or
unexpected is a refusal, and a refused scenario is never run.

### Before Mail is touched

Each scenario's fixture headers, its argv and the binary's sandboxed
dry-run output must pass allowlist guards: every address is
`@example.test` (a reserved domain that never resolves), the sender is
`e2e-a@example.test` or `e2e-b@example.test`, the dry run takes the path
the scenario expects, and the `.eml` path's step plan equals
[`templates/`](templates) for its mode. The binary is copied and hashed
once, and each live scenario re-checks that hash and the fixture's. The
harness unsets `SENDMAIL_SEND`, `SENDMAIL_NO_UI` and, for live runs,
`SENDMAIL_DRY_RUN`, so only argv picks the path.

### Mail's state, checked before every scenario

- **Mail must already be running.** The preflight does not launch it.
- **Accounts.** An enabled `e2e-a@example.test` account whose incoming
  and outgoing servers are exactly `127.0.0.1:1110` and
  `127.0.0.1:1025`. For `e2e-b`, if present, `127.0.0.1:1111` and
  `e2e-b-smtp.test:1025`, accepted only while that alias resolves to
  this machine alone (see [One-time setup](#one-time-setup), step 1).
- **No other enabled account**, and **no other SMTP server**, enabled
  or not, including a local relay on another `127.0.0.1` port.
- **No enabled Mail rule**, including Mail's built-in "News From Apple".
- **No system proxy** (HTTP, HTTPS, SOCKS or automatic configuration):
  Mail honours them, and a SOCKS proxy resolves names on the proxy
  side, bypassing `/etc/hosts`.
- **An empty Outbox, no message selected, and no window other than
  Mail's main viewer windows.** Mail's dictionary cannot tell a
  standalone message window or the Settings window from a compose
  window, so they are refused too.

**Close every compose window first, and select an empty mailbox.**
Message > Send Again, which the `.eml` path presses, acts on Mail's key
window: it is Send Again on a viewer but Send on a compose window. The
binary checks before each press that its own window is key, but the
check cannot close the gap entirely. With nothing selected, a stray
Send Again has nothing to resend.

### Mailpit

Every Mailpit the harness starts gets an empty environment, so `MP_*`
variables that would make it relay, forward, call a webhook or use
SpamAssassin are not inherited. Before each scenario, the harness's
Mailpit must be the only thing on its ports, answer with its own
banners, and report relaying and SpamAssassin off. Every `curl` ignores
`~/.curlrc` and proxies. A watchdog stops Mailpit when the harness
exits, even if it is killed.

### Stopping

Once the binary has run against Mail, every run (including one stopped
by Ctrl-C) waits up to a minute for Mail's Outbox to empty, then prints
what is still open, queued or selected. If it cannot confirm the Outbox
is empty, it says a message may be stuck and **leaves Mailpit running**
with the work directory kept, so Mail can still deliver, and prints the
`kill` command to stop it afterwards. A second Ctrl-C during that wait
stops Mailpit at once.

If Mail ever says it cannot send using `127.0.0.1` or `e2e-b-smtp.test`
and offers other servers, **never pick one**: that would send the test
message through a real account. Delete the message from the Outbox
instead.

## One-time setup

Run the harness from a dedicated macOS user that has only the e2e
accounts. Delete any other accounts and their SMTP servers: disabling
an account is not enough, because its SMTP server stays in Mail's list
and the preflight refuses it.

In that user, from the repository root:

1. Map `e2e-b`'s SMTP alias to this machine, for both IPv4 and IPv6,
   and flush the DNS cache:

   ```sh
   sudo sh -c 'printf "127.0.0.1\te2e-b-smtp.test\n::1\te2e-b-smtp.test\n" >> /etc/hosts'
   sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
   ```

   macOS 27 allows only one profile-managed SMTP account per host (the
   install fails with "This account already exists"; the log says "Only
   a single "SMTP" account is allowed to be saved"), so `e2e-b` sends
   through `e2e-b-smtp.test:1025` while `e2e-a` uses `127.0.0.1:1025`.

   Both lines are needed: with only the IPv4 one, macOS sends the AAAA
   query to DNS, so an outside answer could reach Mail. The preflight
   refuses the alias unless `/etc/hosts` has exactly those two lines,
   the system resolver (`dscacheutil`) gives exactly 127.0.0.1 and ::1,
   nothing listens on `[::1]:1025`, and `dig` gets no answer from the
   servers in `/etc/resolv.conf`.
2. Start Mailpit and leave it running, because macOS logs in to the POP
   server when it installs the accounts:

   ```sh
   nix run .#e2e -- --serve
   ```

   In another terminal, install the two accounts (`e2e-a@example.test`
   with SMTP on `127.0.0.1:1025`, `e2e-b@example.test` with SMTP on
   `e2e-b-smtp.test:1025`, POP password `e2e-local-only`) from the
   configuration profile. Mail's AppleScript `make new pop account`
   creates accounts that never appear in Mail's settings, so use the
   profile:

   ```sh
   open tests/e2e/e2e-accounts.mobileconfig
   ```

   Approve it in **System Settings -> General -> Device Management**,
   then stop `--serve` with Ctrl-C.

   To add the accounts by hand instead, use **Mail -> Settings ->
   Accounts -> + -> Other Mail Account** while `--serve` runs: POP server
   `127.0.0.1`, port 1110 for `e2e-a` and 1111 for `e2e-b`; SMTP server
   `127.0.0.1` for `e2e-a` and `e2e-b-smtp.test` for `e2e-b`, port 1025;
   not `localhost`, no TLS, no SMTP authentication.

   On a fresh Mail, quit and relaunch it once after its first-run
   sheets: they leave an invisible, untitled window behind, which the
   window check refuses until Mail is relaunched.
3. In Mail's settings:
   - For both accounts, set **Remove copy from server after retrieving a
     message** to **Never** or a number of days. The preflight refuses
     "right away", which would delete messages before they are checked.
   - Disable or delete every rule under **Rules**.
   - Remove every other SMTP server (**Accounts -> Server Settings ->
     Outgoing Mail Account -> Edit SMTP Server List**).
4. Grant the terminal you run from **Accessibility** (System Settings
   -> Privacy & Security -> Accessibility; on macOS 27 and later,
   Privacy & Security -> Device Control and Data Access), which the
   binary's default `.eml` path needs, and allow its **Automation**
   requests for Mail and System Events on the first run: the binary's
   `--no-ui` path (scenario `plain-send-no-ui`) needs Mail, and the
   harness's own AppleScripts need both.

Only `e2e-a` is required; scenarios that send from `e2e-b` are skipped
without it. While Mailpit is not running, Mail reports the e2e accounts
as offline; that is expected.

## When the binary's dry-run output changes

The `.eml`-path templates (`templates/eml-plan-{send,draft}.jsonl.tmpl`)
are the binary's dry-run step plans with the `.eml` path replaced by
`<EML>`. A branch that changes `EmlPlan` makes every scenario but
`plain-send-no-ui` refuse with a "plan differs from the … template" diff
until the templates are regenerated from that branch's binary. Review the diff
before committing it. From the repository root:

```sh
nix build
printf 'From: e2e-a@example.test\nTo: x@example.test\nSubject: t\nMIME-Version: 1.0\nContent-Type: text/html\n\n<p>t</p>\n' >/tmp/template.eml
for mode in send draft; do
  args=(-t); [ "$mode" = send ] && args+=(--send)
  SENDMAIL_DRY_RUN=1 ./result/bin/apple-mail-sendmail "${args[@]}" </tmp/template.eml |
    sed -E 's#^(\{"activates":true,"path":)"/[^"\\]*\.eml"(,"step":"open_eml"\})$#\1"<EML>"\2#' \
      >"tests/e2e/templates/eml-plan-$mode.jsonl.tmpl"
done
```

The `--no-ui` path's plan has no template: a change to `PlainPlan` needs
`analyze_plain_plan` (and its `PLAIN_STEP_JQ` program) in
[`e2e.sh`](e2e.sh) updated instead.

## Running it in a Tart VM

A live run presses Message > Send Again and Message > Send in Mail,
which act on whichever Mail window is key, so running it on your own
desktop is risky. `nix run .#e2e-vm` ([`vm.sh`](vm.sh)) runs the same
harness in a throwaway macOS VM with [Tart](https://tart.run) (in the
dev shell; Apple Silicon only). From the repository root:

```sh
nix run .#e2e-vm -- --setup-golden          # once, guided (see below)
nix run .#e2e-vm                            # every scenario, in a fresh clone
nix run .#e2e-vm -- html-send bcc-only-html # harness arguments pass through
nix run .#e2e-vm -- --check-only            # also boots a clone
nix run .#e2e-vm -- -- --help               # the harness's help; no VM
nix run .#e2e-vm -- --list                  # its scenario list; no VM
```

Wrapper options come first (`nix run .#e2e-vm -- --help` lists them);
the first other argument, or everything after `--`, goes to the
harness. `--help` and `--list` for the harness run on the host and
boot no VM, and `--serve` is refused. Any other arguments are first
checked on the host by the harness's own parser, and only then does a
clone boot.

Each run clones the golden VM (`sendmail-e2e-golden`) as an APFS clone,
boots it headless, copies the harness's Nix closure in, runs the
harness there with `--keep`, copies its work directory and the guest's
TCC and agent logs to
`~/.local/state/apple-mail-sendmail-e2e-vm/results/<clone>/`, and
deletes the clone, also on failure, Ctrl-C or SIGTERM. Only SIGKILL can
leave a clone behind; the next run lists any such clone (`tart stop
NAME`, then `tart delete NAME`). The exit status is the harness's.
`--binary PATH` works as with `nix run .#e2e` if `PATH` resolves into
`/nix/store`.

**Permissions.** macOS charges an Apple Event or Accessibility call to
the *responsible* process, which for everything `tart exec` starts is
`tart-guest-agent` (the prompts name it, and the guest's TCC log
records `responsible=tart-guest-agent`). The golden image's grants to
the agent (Automation for Mail and System Events, given during setup;
Accessibility, which the Cirrus Labs image grants in advance) cover
every rebuild of the ad-hoc-signed binary, and every clone keeps them.
Only `osascript` can raise an Automation prompt: when the binary asks,
macOS denies the event (-1743) without a prompt, because the agent
lacks the hardened-runtime Apple Events entitlement. Each run saves the
guest's `tcc.log` and prints the relevant `AUTHREQ` lines.

### Preparing the golden VM

`nix run .#e2e-vm -- --setup-golden` (`--base-image REF` for another
image than the pinned `ghcr.io/cirruslabs/macos-golden-gate-base` digest
in `vm.sh`) pulls the
base image the first time (about 32 GB to download, about 50 GB on
disk), boots it with a window, and automatically sets up SSH, auto-login,
no sleep, Nix, the `e2e-b-smtp.test` lines in `/etc/hosts`, and a running
Mailpit for the profile's POP login checks. It stops before the profile
install if the guest still has e2e accounts from an earlier install:
`profiles remove` leaves them behind, and reinstalling then fails with
"already exists". Delete them in **Mail -> Settings -> Accounts**.

It then copies [`e2e-accounts.mobileconfig`](e2e-accounts.mobileconfig)
to the guest's Desktop, opens it, prints the manual steps and waits:
install the profile, open Mail, dismiss its first-run sheets and
relaunch it once, set both accounts to never remove messages from the
server, turn off every rule, check the SMTP server list, and select an
empty mailbox. It then asks for Automation through `osascript`, once
for Mail and once for System Events; click Allow on each prompt, which
must name `tart-guest-agent`. Next it runs the `plain-send`,
`plain-send-no-ui` and `html-send` scenarios (Accessibility for the
first and last, Automation for the `--no-ui` one) as often as you like,
and a pass counts only if all three pass. Last, you quit Mail and the VM shuts down.

With `--vnc`, setup boots the VM with Virtualization.framework's VNC
server instead of a window; the `vnc://` URL and its password are in
the setup's `tart-run.log`. A VNC client (or vncdotool) can do every
manual step, including the profile approval and the Allow buttons,
because its input reaches the guest as hardware input.

Setup writes `golden-<name>.marker` in the state directory before it
clones; rerunning `--setup-golden` resumes only a VM with a matching
marker and refuses to touch any other VM of that name.

If an approval pass fails with mail stuck in Mail's Outbox, the harness
leaves its Mailpit and forwarder running in the guest so Mail can still
deliver. The next pass checks for them, asks you to empty the Outbox in
the VM, and offers to stop them.

If setup is interrupted while Nix is installing, the next
`--setup-golden` stops rather than run the installer over its
leftovers. Start over (the base image usually stays in Tart's cache)
from the repository root:

```sh
tart delete sendmail-e2e-golden
rm ~/.local/state/apple-mail-sendmail-e2e-vm/golden-sendmail-e2e-golden.marker
nix run .#e2e-vm -- --setup-golden
```

or uninstall Nix inside the VM following the macOS steps in the
[Nix manual](https://nix.dev/manual/nix/stable/installation/uninstall.html)
and rerun `--setup-golden`.
