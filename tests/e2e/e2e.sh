#!/usr/bin/env bash
# Live end-to-end harness for apple-mail-sendmail. See the "Live end-to-end
# tests" section of README.md. Packaged as `nix run .#e2e`.
#
# Every guard fails closed: input that is missing, unparseable or unexpected
# is a refusal, never a pass.
set -euo pipefail

readonly PROGRAM=apple-mail-sendmail-e2e
readonly MAILPIT_HOST=127.0.0.1
# Not readonly: the self-test starts extra Mailpits on other ports.
SMTP_PORT=1025
POP3_PORT=1110
POP3_B_PORT=1111
HTTP_PORT=8025
API="http://${MAILPIT_HOST}:${HTTP_PORT}/api/v1"
# -q skips ~/.curlrc; --noproxy keeps http_proxy from rerouting 127.0.0.1.
readonly CURL=(curl -q --noproxy '*')
readonly ACCOUNT_A=e2e-a@example.test
readonly ACCOUNT_B=e2e-b@example.test
# e2e-b's outgoing server. macOS 27 allows only one profile-managed SMTP
# account per host ("Only a single "SMTP" account is allowed to be saved"),
# so B reaches Mailpit's SMTP through this /etc/hosts alias for 127.0.0.1.
# This is the single definition: e2e-accounts.mobileconfig must use the same
# name (--self-test checks it), and other tooling should read it from here.
readonly SMTP_B_ALIAS=e2e-b-smtp.test
HOSTS_FILE=/etc/hosts
readonly POP3_PASSWORD=e2e-local-only
readonly MAIL_APP_PROCESS=/System/Applications/Mail.app/Contents/MacOS/Mail
readonly FIELD_SEPARATOR=$'\x1f'

# The only address form any guard accepts: a dot-atom local part at
# example.test (a reserved domain that never resolves).
readonly ADDR_RE='[A-Za-z0-9._+-]+@[Ee][Xx][Aa][Mm][Pp][Ll][Ee]\.[Tt][Ee][Ss][Tt]'
# A display-name phrase: no specials, quotes, angle brackets or controls.
# Non-ASCII bytes and RFC 2047 encoded-words pass.
readonly PHRASE_RE='[^]["<>@,;:()\\[:cntrl:]]+'
readonly ALLOWED_HEADERS=" from sender reply-to to cc bcc subject date message-id mime-version content-type content-transfer-encoding content-disposition "
readonly ADDRESS_HEADERS=" from sender reply-to to cc bcc "

E2E_RESOURCES=${E2E_RESOURCES:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
SENDMAIL_BIN=${E2E_SENDMAIL:-$(command -v apple-mail-sendmail || true)}

readonly SCENARIOS=(
  plain-send
  plain-send-no-ui
  plain-attachment-send
  html-send
  html-attachment-send
  bcc-only-plain
  bcc-only-html
  display-names-plain
  display-names-html
  from-header-account-plain
  attachment-filename-plain
  draft-later-plain-attachment
  draft-later-html-attachment
)

mode=live
keep_workdir=false
allow_refused=false
draft_wait=10
delivery_timeout=30
settle_seconds=2
selected=()

usage() {
  cat <<EOF
Usage: ${PROGRAM} [mode] [options] [scenario ...]
       (from a checkout: nix run .#e2e -- [mode] [options] [scenario ...])

Live end-to-end tests: pipes fixtures through apple-mail-sendmail into Apple
Mail, which sends them to a Mailpit capture server on ${MAILPIT_HOST}, then
asserts on what Mailpit received. With no scenario names, runs all of them.

Modes (default: live run, which drives Mail.app and sends mail):
  --check-only    Validate fixtures, safety guards and the binary's dry-run
                  output, and check that Mailpit starts.
  --self-test     Prove the assertions against Mailpit by injecting correct
                  and deliberately broken messages over SMTP, and test the
                  guards, the dry-run checks, the sandbox and the preflight
                  parsers.
  --serve         Run the Mailpit capture server in the foreground (for
                  setting up or inspecting the Mail accounts). Ctrl-C stops it.
  --list          List the scenarios and what each one checks.

  --check-only and --self-test never drive Mail. They run the binary only
  with SENDMAIL_DRY_RUN=1 inside sandbox-exec (tests/e2e/dry-run.sb), which denies
  Apple Events, all Mach service lookups (so WindowServer, Launch Services and
  Accessibility are unreachable), network, fork and exec, signals, IOKit,
  tty and pty devices, deleting or renaming files, and writing anywhere but
  a per-run temp dir, in a new session with no controlling terminal. It
  does not stop the binary reading files. --self-test also sends one
  read-only Apple Event to Finder (get name of startup disk) unsandboxed, as
  the control for the sandbox checks, and runs osascript inside the sandbox
  to prove it is blocked; neither talks to Mail or System Events.

Options:
  --binary PATH           apple-mail-sendmail binary to test (default: the
                          one this flake built: ${SENDMAIL_BIN:-none})
  --draft-wait SECONDS    Wait before sending a draft by hand (default ${draft_wait})
  --timeout SECONDS       How long to wait for a message to arrive (default ${delivery_timeout})
  --keep                  Keep the work directory (fixtures, logs, Mailpit DB).
  --allow-refused         Let a live run succeed when scenarios were refused
                          by a guard (e.g. against an older binary);
                          by default anything but PASS fails the run.
  -h, --help              Show this help.
EOF
}

die() {
  printf 'e2e: %s\n' "$*" >&2
  exit 2
}

log() {
  printf '%s\n' "$*" >&2
}

while (($# > 0)); do
  case $1 in
    --check-only) mode=check-only ;;
    --self-test) mode=self-test ;;
    --serve) mode=serve ;;
    --list) mode=list ;;
    --binary)
      (($# >= 2)) || die "--binary needs a path"
      SENDMAIL_BIN=$2
      shift
      ;;
    --draft-wait)
      (($# >= 2)) || die "--draft-wait needs a number of seconds"
      draft_wait=$2
      shift
      ;;
    --timeout)
      (($# >= 2)) || die "--timeout needs a number of seconds"
      delivery_timeout=$2
      shift
      ;;
    --keep) keep_workdir=true ;;
    --allow-refused) allow_refused=true ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) selected+=("$1") ;;
  esac
  shift
done

[[ $draft_wait =~ ^[0-9]+$ ]] || die "--draft-wait must be a whole number of seconds"
[[ $delivery_timeout =~ ^[0-9]+$ ]] || die "--timeout must be a whole number of seconds"

if ((${#selected[@]} == 0)); then
  selected=("${SCENARIOS[@]}")
fi
for name in "${selected[@]}"; do
  [[ " ${SCENARIOS[*]} " == *" $name "* ]] || die "unknown scenario: $name (see --list)"
done

# ---------------------------------------------------------------------------
# Process control. Children run in the terminal's process group
# (--foreground), so Ctrl-C reaches them at once instead of waiting behind
# bash's deferred INT trap.

run_bounded() {
  local seconds=$1
  shift
  timeout --foreground "$seconds" "$@"
}

workdir=""
mailpit_pid=""
forwarder_pid=""
mailpit_tag=mailpit
mail_touched=false
DRY_RUN_TEMP_DIRS=()

cleanup() {
  local status=$?
  # A second Ctrl-C during the drain below stops Mailpit at once.
  trap 'log "e2e: interrupted again; stopping Mailpit now, so a message still in Mail'"'"'s Outbox may be stranded"; stop_mailpit; exit 130' INT TERM
  local leave_mailpit_running=false
  if [[ $mail_touched == true ]]; then
    if ! wait_for_outbox_empty 60; then
      leave_mailpit_running=true
    fi
    final_mail_report "$leave_mailpit_running" || true
  fi
  if [[ $leave_mailpit_running == true ]] && mailpit_alive; then
    detach_mailpit
    keep_workdir=true
  else
    if mailpit_alive; then
      log "e2e: stopping Mailpit (pid $mailpit_pid), which was still running and answering"
    fi
    stop_mailpit
  fi
  remove_dry_run_temp_dirs
  if [[ -n $workdir && -d $workdir ]]; then
    if [[ $keep_workdir == true ]]; then
      log "e2e: kept work directory $workdir"
    else
      rm -rf "$workdir"
    fi
  fi
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

make_workdir() {
  workdir=$(mktemp -d "${TMPDIR:-/tmp}/apple-mail-sendmail-e2e.XXXXXX")
  workdir=$(realpath "$workdir")
  mkdir -p "$workdir/fixtures" "$workdir/checked" "$workdir/messages" "$workdir/logs" "$workdir/dry-run-tmp" "$workdir/bin"
  RUN_ID=$(date +%Y%m%d-%H%M%S)-$RANDOM
  head -c 5000 /dev/urandom >"$workdir/attachment.bin"
  ATTACH_SIZE=$(wc -c <"$workdir/attachment.bin" | tr -d ' ')
  ATTACH_SHA256=$(sha256sum "$workdir/attachment.bin" | cut -d' ' -f1)
  base64 -w 76 "$workdir/attachment.bin" >"$workdir/attachment.b64"
  ATTACH_B64_FIRST_LINE=$(head -n 1 "$workdir/attachment.b64")
}

# The binary under test is copied into the work dir once and hashed; dry runs
# and live runs both use that copy, and live runs re-check the hash.
BINARY_SHA256=""

prepare_binary() {
  [[ -n $SENDMAIL_BIN && -x $SENDMAIL_BIN ]] ||
    die "apple-mail-sendmail binary not found (pass --binary PATH)"
  local source_binary
  source_binary=$(realpath "$SENDMAIL_BIN")
  cp "$source_binary" "$workdir/bin/apple-mail-sendmail"
  chmod 555 "$workdir/bin/apple-mail-sendmail"
  SENDMAIL_BIN="$workdir/bin/apple-mail-sendmail"
  BINARY_SHA256=$(sha256sum "$SENDMAIL_BIN" | cut -d' ' -f1)
  log "e2e: testing a copy of $source_binary (sha256 $BINARY_SHA256)"
}

binary_unchanged() {
  [[ -n $BINARY_SHA256 && $(sha256sum "$SENDMAIL_BIN" | cut -d' ' -f1) == "$BINARY_SHA256" ]]
}

# ---------------------------------------------------------------------------
# Mailpit lifecycle

port_in_use() {
  (exec 3<>"/dev/tcp/${MAILPIT_HOST}/$1") 2>/dev/null
}

read_banner() {
  local port=$1 line=""
  exec 3<>"/dev/tcp/${MAILPIT_HOST}/${port}" || return 1
  IFS= read -r -t 5 line <&3 || true
  printf 'QUIT\r\n' >&3 || true
  exec 3>&-
  printf '%s\n' "${line%$'\r'}"
}

MAILPIT_REASON=""

check_mailpit_banners() {
  local smtp_banner
  smtp_banner=$(read_banner "$SMTP_PORT") || smtp_banner=""
  if [[ ! $smtp_banner =~ ^220\ .*Mailpit ]]; then
    MAILPIT_REASON="port ${SMTP_PORT} did not answer with a Mailpit SMTP banner (got \"$smtp_banner\")"
    return 1
  fi
  check_pop3_banner "$POP3_PORT"
}

check_pop3_banner() {
  local port=$1 pop3_banner
  pop3_banner=$(read_banner "$port") || pop3_banner=""
  if [[ ! $pop3_banner =~ ^\+OK\ .*Mailpit ]]; then
    MAILPIT_REASON="port ${port} did not answer with a Mailpit POP3 banner (got \"$pop3_banner\")"
    return 1
  fi
}

# check_pop3_login USER PASSWORD [PORT]
check_pop3_login() {
  local port=${3:-$POP3_PORT}
  if ! "${CURL[@]}" -fsS --max-time 5 -u "$1:$2" "pop3://${MAILPIT_HOST}:${port}/" >/dev/null 2>&1; then
    MAILPIT_REASON="POP3 login as $1 on ${port} failed"
    return 1
  fi
}

# Mailpit honours MP_* environment variables that relay, forward, call a
# webhook or consult SpamAssassin. The main defence is starting every Mailpit
# under `env -i`. This is a second check, refusing on anything it cannot
# read: relaying and SpamAssassin must be off in /api/v1/webui, and the
# startup log must not announce relaying or forwarding (forwarding is not in
# the API). Webhooks show in neither, so only the scrub covers them.
check_mailpit_not_relaying() {
  local log_file=$1 webui
  if ! webui=$("${CURL[@]}" -fsS --max-time 5 "$API/webui"); then
    MAILPIT_REASON="could not read Mailpit's /api/v1/webui"
    return 1
  fi
  if ! jq -e '(.MessageRelay | type) == "object" and .MessageRelay.Enabled == false and .MessageRelay.SMTPServer == ""' <<<"$webui" >/dev/null 2>&1; then
    MAILPIT_REASON="Mailpit reports message relay enabled or unreadable: $(jq -c '.MessageRelay' <<<"$webui" 2>/dev/null || printf '%s' "${webui:0:120}")"
    return 1
  fi
  if ! jq -e '.SpamAssassin == false' <<<"$webui" >/dev/null 2>&1; then
    MAILPIT_REASON="Mailpit reports SpamAssassin enabled or unreadable: $(jq -c '.SpamAssassin' <<<"$webui" 2>/dev/null || printf '?')"
    return 1
  fi
  if [[ ! -s $log_file ]]; then
    MAILPIT_REASON="Mailpit's startup log is missing"
    return 1
  fi
  if grep -qiE '\[(relay|forward)\]' "$log_file"; then
    MAILPIT_REASON="Mailpit's log shows relaying or forwarding: $(grep -iE '\[(relay|forward)\]' "$log_file" | sed -n '1p')"
    return 1
  fi
}

# Runs a command in a new session under a watchdog. The session keeps the
# terminal's Ctrl-C away from it (Mailpit, being Go, would otherwise shut
# down on the group SIGINT before the Outbox drain), and the watchdog stops
# it with SIGTERM when told to or when the harness (PARENT_PID) disappears,
# even by SIGKILL. SIGUSR1 detaches it: it then leaves the command running.
#
# The function execs perl, so when it is started in the background `$!` is
# the watchdog itself. TERM, INT, HUP and USR1 stay blocked from before the
# fork until the handlers are in place, so a signal in that gap is delivered
# to the handler rather than killing the watchdog and orphaning Mailpit.
run_supervised() {
  local parent_pid=$1
  shift
  exec perl -e '
    use POSIX ();
    POSIX::setsid() or die "setsid: $!\n";
    my $parent = shift @ARGV;
    my $blocked = POSIX::SigSet->new(POSIX::SIGTERM(), POSIX::SIGINT(), POSIX::SIGHUP(), POSIX::SIGUSR1());
    my $previous = POSIX::SigSet->new();
    POSIX::sigprocmask(POSIX::SIG_BLOCK(), $blocked, $previous) or die "sigprocmask: $!\n";
    my $child = fork();
    die "fork: $!\n" unless defined $child;
    if ($child == 0) {
      POSIX::sigprocmask(POSIX::SIG_SETMASK(), $previous);
      exec @ARGV or die "exec: $!\n";
    }
    my $detached = 0;
    $SIG{INT} = "IGNORE";
    $SIG{HUP} = "IGNORE";
    $SIG{USR1} = sub { $detached = 1 };
    $SIG{TERM} = sub { kill "TERM", $child; waitpid($child, 0); exit 0 };
    POSIX::sigprocmask(POSIX::SIG_SETMASK(), $previous) or die "sigprocmask: $!\n";
    while (1) {
      exit 0 if waitpid($child, POSIX::WNOHANG()) == $child;
      if (!$detached && !kill(0, $parent)) { kill "TERM", $child; waitpid($child, 0); exit 0 }
      sleep 1;
    }
  ' -- "$parent_pid" "$@"
}

# Mailpit serves one POP3 port, but macOS refuses a second POP account on the
# same host and port ("This account already exists"), so e2e-b fetches
# through a localhost-only TCP forwarder from POP3_B_PORT to POP3_PORT,
# supervised like Mailpit.
start_pop3_forwarder() {
  run_supervised "$$" env -i PATH="$PATH" \
    socat "TCP-LISTEN:${POP3_B_PORT},bind=${MAILPIT_HOST},reuseaddr,fork" "TCP:${MAILPIT_HOST}:${POP3_PORT}" \
    >"$workdir/logs/${mailpit_tag}-pop3-forwarder.log" 2>&1 &
  forwarder_pid=$!
  local attempt
  for attempt in $(seq 1 50); do
    kill -0 "$forwarder_pid" 2>/dev/null || break
    if check_pop3_banner "$POP3_B_PORT" 2>/dev/null; then
      check_pop3_login e2e-b "$POP3_PASSWORD" "$POP3_B_PORT" || die "$MAILPIT_REASON (through the forwarder)"
      return 0
    fi
    sleep 0.1
  done
  die "the POP3 forwarder on ${MAILPIT_HOST}:${POP3_B_PORT} did not come up; see $workdir/logs/${mailpit_tag}-pop3-forwarder.log"
}

start_mailpit() {
  local port
  for port in "$SMTP_PORT" "$POP3_PORT" "$POP3_B_PORT" "$HTTP_PORT"; do
    if port_in_use "$port"; then
      die "something is already listening on ${MAILPIT_HOST}:${port}; stop it first so only this run's Mailpit receives mail"
    fi
  done
  local log_file="$workdir/logs/${mailpit_tag}.log"
  printf 'e2e-a:%s\ne2e-b:%s\n' "$POP3_PASSWORD" "$POP3_PASSWORD" >"$workdir/${mailpit_tag}-pop3-auth"
  chmod 600 "$workdir/${mailpit_tag}-pop3-auth"
  run_supervised "$$" env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    mailpit \
    --database "$workdir/${mailpit_tag}.db" \
    --listen "${MAILPIT_HOST}:${HTTP_PORT}" \
    --smtp "${MAILPIT_HOST}:${SMTP_PORT}" \
    --pop3 "${MAILPIT_HOST}:${POP3_PORT}" \
    --pop3-auth-file "$workdir/${mailpit_tag}-pop3-auth" \
    --smtp-auth-accept-any \
    --smtp-auth-allow-insecure \
    --smtp-disable-rdns \
    --disable-version-check \
    >"$log_file" 2>&1 &
  mailpit_pid=$!

  local attempt
  for attempt in $(seq 1 100); do
    kill -0 "$mailpit_pid" 2>/dev/null || break
    if "${CURL[@]}" -fsS --max-time 1 "$API/info" >/dev/null 2>&1; then
      sleep 0.2
      kill -0 "$mailpit_pid" 2>/dev/null || break
      check_mailpit_banners || die "$MAILPIT_REASON"
      check_pop3_login e2e-a "$POP3_PASSWORD" || die "$MAILPIT_REASON; see $log_file"
      check_mailpit_not_relaying "$log_file" || die "$MAILPIT_REASON"
      start_pop3_forwarder
      log "e2e: Mailpit up (SMTP ${SMTP_PORT}, POP3 ${POP3_PORT} and ${POP3_B_PORT}, API ${HTTP_PORT}, relay off) after ${attempt} tries"
      return 0
    fi
    sleep 0.1
  done
  cat "$log_file" >&2 || true
  die "Mailpit did not start; see the log above"
}

stop_supervised() {
  local pid=$1
  if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}

# mailpit_pid and forwarder_pid are watchdog pids; SIGTERM to each stops
# what it supervises.
stop_mailpit() {
  stop_supervised "$forwarder_pid"
  stop_supervised "$mailpit_pid"
}

detach_mailpit() {
  kill -USR1 "$mailpit_pid" 2>/dev/null || true
  kill -USR1 "$forwarder_pid" 2>/dev/null || true
  log "e2e: left Mailpit and its POP3 forwarder running (supervisor pids $mailpit_pid $forwarder_pid) so Mail can still deliver; the work directory $workdir is kept for Mailpit's database"
  log "e2e: once Mail's Outbox is empty (or you have deleted what is stuck there), stop them with: kill $mailpit_pid $forwarder_pid"
}

mailpit_alive() {
  [[ -n $mailpit_pid ]] && kill -0 "$mailpit_pid" 2>/dev/null &&
    [[ -n $forwarder_pid ]] && kill -0 "$forwarder_pid" 2>/dev/null &&
    "${CURL[@]}" -fsS --max-time 3 "$API/info" >/dev/null 2>&1
}

clear_mailpit() {
  "${CURL[@]}" -fsS --max-time 5 -X DELETE "$API/messages" >/dev/null
}

# ---------------------------------------------------------------------------
# Scenarios. Each define_* function writes $FIXTURE and sets the expectations
# below; check_delivery compares them against what Mailpit received.

reset_expectations() {
  NAME=$1
  SUBJECT="e2e ${RUN_ID} ${NAME}"
  BODY_MARKER="e2e-body ${RUN_ID} ${NAME}"
  FIXTURE="$workdir/fixtures/${NAME}.eml"
  DESCRIPTION=""
  DELIVERY=send
  EXPECT_PATH=eml
  EXPECT_QUOTED=false
  SEND_ARGS=(-t)
  EXPECT_FROM_ADDR=""
  EXPECT_FROM_NAME=""
  EXPECT_TO=()
  EXPECT_CC=()
  EXPECT_BCC=()
  EXPECT_TEXT=$BODY_MARKER
  EXPECT_HTML=""
  EXPECT_ATTACH=()
  ALLOW_MULTIPLE=false
}

define_scenario() {
  reset_expectations "$1"
  "define_${1//-/_}"
}

html_alternative_part() {
  local boundary=$1
  cat <<EOF
Content-Type: multipart/alternative; boundary="${boundary}"

--${boundary}
Content-Type: text/plain; charset=utf-8

${BODY_MARKER}
--${boundary}
Content-Type: text/html; charset=utf-8

<html><body><p>${BODY_MARKER}</p><table border="1" cellpadding="6"><tr><td>e2e-html-cell</td><td style="color:red">styled</td></tr></table></body></html>
--${boundary}--
EOF
}

attachment_part() {
  local disposition=$1
  cat <<EOF
Content-Type: application/octet-stream
Content-Disposition: ${disposition}
Content-Transfer-Encoding: base64

EOF
  cat "$workdir/attachment.b64"
}

write_plain_with_attachment() {
  local headers=$1 disposition=$2
  {
    printf '%s\n' "$headers"
    cat <<EOF
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="mixed-b"

--mixed-b
Content-Type: text/plain; charset=utf-8

${BODY_MARKER}
--mixed-b
EOF
    attachment_part "$disposition"
    printf -- '--mixed-b--\n'
  } >"$FIXTURE"
}

write_html() {
  local headers=$1
  {
    printf '%s\nMIME-Version: 1.0\n' "$headers"
    html_alternative_part alt-b
  } >"$FIXTURE"
}

write_html_with_attachment() {
  local headers=$1
  {
    printf '%s\n' "$headers"
    cat <<EOF
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="mixed-b"

--mixed-b
EOF
    html_alternative_part alt-b
    printf -- '--mixed-b\n'
    attachment_part 'attachment; filename="e2e-data.bin"'
    printf -- '--mixed-b--\n'
  } >"$FIXTURE"
}

# Attachment names are exact. Every scenario but plain-send-no-ui takes the
# .eml path, where the attachment keeps its own name on the wire.

define_plain_send() {
  DESCRIPTION="plain text, --send: sender account, subject, body"
  SEND_ARGS=(-t -f "$ACCOUNT_A")
  EXPECT_FROM_ADDR=$ACCOUNT_A
  EXPECT_TO=(to-plain@example.test)
  cat >"$FIXTURE" <<EOF
From: ${ACCOUNT_A}
To: to-plain@example.test
Subject: ${SUBJECT}

${BODY_MARKER}
EOF
}

# The only scenario on the Apple Event path. Mail sends a body set through its
# dictionary as a quotation (FB11734014), so this one asserts that the quoting
# IS there: it fails, and needs updating, once Apple fixes the bug.
define_plain_send_no_ui() {
  DESCRIPTION="plain text, --no-ui --send (Apple Events): recipients, sender, and Mail quotes the body (FB11734014)"
  EXPECT_PATH=apple-events
  EXPECT_QUOTED=true
  SEND_ARGS=(-t -f "$ACCOUNT_A" --no-ui)
  EXPECT_FROM_ADDR=$ACCOUNT_A
  EXPECT_TO=(to-no-ui@example.test)
  EXPECT_CC=(cc-no-ui@example.test)
  cat >"$FIXTURE" <<EOF
From: ${ACCOUNT_A}
To: to-no-ui@example.test
Cc: cc-no-ui@example.test
Subject: ${SUBJECT}

${BODY_MARKER}
EOF
}

define_plain_attachment_send() {
  DESCRIPTION="plain text + attachment, --send: attachment arrives intact"
  SEND_ARGS=(-t -f "$ACCOUNT_A")
  EXPECT_FROM_ADDR=$ACCOUNT_A
  EXPECT_TO=(to-plain-att@example.test)
  EXPECT_ATTACH=("e2e-data.bin|$ATTACH_SIZE|$ATTACH_SHA256")
  write_plain_with_attachment "From: ${ACCOUNT_A}
To: to-plain-att@example.test
Subject: ${SUBJECT}" 'attachment; filename="e2e-data.bin"'
}

define_html_send() {
  DESCRIPTION="HTML, --send: HTML part arrives, no Resent-* headers"
  EXPECT_FROM_ADDR=$ACCOUNT_A
  EXPECT_TO=(to-html@example.test)
  EXPECT_HTML="e2e-html-cell"
  write_html "From: E2E A <${ACCOUNT_A}>
To: to-html@example.test
Subject: ${SUBJECT}"
}

define_html_attachment_send() {
  DESCRIPTION="HTML + attachment, --send: both arrive"
  EXPECT_FROM_ADDR=$ACCOUNT_A
  EXPECT_TO=(to-html-att@example.test)
  EXPECT_HTML="e2e-html-cell"
  EXPECT_ATTACH=("e2e-data.bin|$ATTACH_SIZE|$ATTACH_SHA256")
  write_html_with_attachment "From: E2E A <${ACCOUNT_A}>
To: to-html-att@example.test
Subject: ${SUBJECT}"
}

define_bcc_only_plain() {
  DESCRIPTION="To: undisclosed-recipients:; + Bcc, plain: Bcc delivered, no Bcc header"
  SEND_ARGS=(-t -f "$ACCOUNT_A")
  EXPECT_FROM_ADDR=$ACCOUNT_A
  EXPECT_BCC=(hidden-plain@example.test)
  ALLOW_MULTIPLE=true
  cat >"$FIXTURE" <<EOF
From: ${ACCOUNT_A}
To: undisclosed-recipients:;
Bcc: hidden-plain@example.test
Subject: ${SUBJECT}

${BODY_MARKER}
EOF
}

define_bcc_only_html() {
  DESCRIPTION="To: undisclosed-recipients:; + Bcc, HTML: Bcc delivered, no Bcc header"
  EXPECT_FROM_ADDR=$ACCOUNT_A
  EXPECT_BCC=(hidden-html@example.test)
  EXPECT_HTML="e2e-html-cell"
  ALLOW_MULTIPLE=true
  write_html "From: E2E A <${ACCOUNT_A}>
To: undisclosed-recipients:;
Bcc: hidden-html@example.test
Subject: ${SUBJECT}"
}

define_display_names_plain() {
  DESCRIPTION="comma and non-ASCII display names in To, Cc and From (-F), plain"
  SEND_ARGS=(-t -f "$ACCOUNT_A" -F "Bäcker, Anna")
  EXPECT_FROM_ADDR=$ACCOUNT_A
  EXPECT_FROM_NAME="Bäcker, Anna"
  EXPECT_TO=("doe-plain@example.test|Doe, John" "juergen-plain@example.test|Jürgen Müller")
  EXPECT_CC=("roe-plain@example.test|Roe, Jane")
  cat >"$FIXTURE" <<EOF
From: ${ACCOUNT_A}
To: "Doe, John" <doe-plain@example.test>, Jürgen Müller <juergen-plain@example.test>
Cc: "Roe, Jane" <roe-plain@example.test>
Subject: ${SUBJECT}

${BODY_MARKER}
EOF
}

define_display_names_html() {
  DESCRIPTION="comma and non-ASCII display names in To, Cc and From (header), HTML"
  EXPECT_FROM_ADDR=$ACCOUNT_A
  EXPECT_FROM_NAME="Bäcker, Anna"
  EXPECT_TO=("doe-html@example.test|Doe, John" "juergen-html@example.test|Jürgen Müller")
  EXPECT_CC=("roe-html@example.test|Roe, Jane")
  EXPECT_HTML="e2e-html-cell"
  write_html "From: \"Bäcker, Anna\" <${ACCOUNT_A}>
To: \"Doe, John\" <doe-html@example.test>, =?UTF-8?Q?J=C3=BCrgen_M=C3=BCller?= <juergen-html@example.test>
Cc: \"Roe, Jane\" <roe-html@example.test>
Subject: ${SUBJECT}"
}

define_from_header_account_plain() {
  DESCRIPTION="plain, no -f: header From selects the second account"
  EXPECT_FROM_ADDR=$ACCOUNT_B
  EXPECT_TO=(to-account-b@example.test)
  cat >"$FIXTURE" <<EOF
From: E2E B <${ACCOUNT_B}>
To: to-account-b@example.test
Subject: ${SUBJECT}

${BODY_MARKER}
EOF
}

define_attachment_filename_plain() {
  DESCRIPTION="plain + RFC 2231 mixed-case attachment filename keeps its name"
  SEND_ARGS=(-t -f "$ACCOUNT_A")
  EXPECT_FROM_ADDR=$ACCOUNT_A
  EXPECT_TO=(to-filename@example.test)
  EXPECT_ATTACH=("Report-Q3.BIN|$ATTACH_SIZE|$ATTACH_SHA256")
  write_plain_with_attachment "From: ${ACCOUNT_A}
To: to-filename@example.test
Subject: ${SUBJECT}" "attachment; filename*=UTF-8''Report%2DQ3.BIN"
}

define_draft_later_plain_attachment() {
  DESCRIPTION="plain + attachment as a draft, sent by hand after --draft-wait"
  DELIVERY=draft-later
  SEND_ARGS=(-t -f "$ACCOUNT_A")
  EXPECT_FROM_ADDR=$ACCOUNT_A
  EXPECT_TO=(to-draft-plain@example.test)
  EXPECT_ATTACH=("e2e-data.bin|$ATTACH_SIZE|$ATTACH_SHA256")
  write_plain_with_attachment "From: ${ACCOUNT_A}
To: to-draft-plain@example.test
Subject: ${SUBJECT}" 'attachment; filename="e2e-data.bin"'
}

define_draft_later_html_attachment() {
  DESCRIPTION="HTML + attachment as a draft, sent by hand after --draft-wait"
  DELIVERY=draft-later
  EXPECT_FROM_ADDR=$ACCOUNT_A
  EXPECT_TO=(to-draft-html@example.test)
  EXPECT_HTML="e2e-html-cell"
  EXPECT_ATTACH=("e2e-data.bin|$ATTACH_SIZE|$ATTACH_SHA256")
  write_html_with_attachment "From: E2E A <${ACCOUNT_A}>
To: to-draft-html@example.test
Subject: ${SUBJECT}"
}

binary_args() {
  local -n args_out=$1
  args_out=()
  if [[ $DELIVERY == send ]]; then
    args_out+=(--send)
  fi
  args_out+=("${SEND_ARGS[@]}")
}

# ---------------------------------------------------------------------------
# Address allowlist. Every address-bearing value must parse completely as a
# list of allowed forms, or it is refused.

ltrim() {
  local value=$1
  printf '%s' "${value#"${value%%[![:space:]]*}"}"
}

# Parses an RFC 5322 address list restricted to: bare local@example.test,
# "Quoted" <addr>, Phrase <addr>, <addr>, and groups of those (including
# empty groups). Sets PARSED_ADDRESSES (lowercased) or PARSE_ERROR.
parse_address_list() {
  local LC_ALL=C
  local rest=$1 in_group=false expect_item=true
  local group_re='^('"$PHRASE_RE"'):(.*)$'
  local quoted_re='^"([^"\[:cntrl:]]*)"[[:space:]]*<('"$ADDR_RE"')>(.*)$'
  local phrase_re='^('"$PHRASE_RE"')<('"$ADDR_RE"')>(.*)$'
  local angle_re='^<('"$ADDR_RE"')>(.*)$'
  local bare_re='^('"$ADDR_RE"')(.*)$'
  PARSED_ADDRESSES=()
  PARSE_ERROR=""
  rest=$(ltrim "$rest")
  if [[ -z $rest ]]; then
    PARSE_ERROR="empty address list"
    return 1
  fi
  while :; do
    rest=$(ltrim "$rest")
    if [[ -z $rest ]]; then
      if [[ $in_group == true ]]; then
        PARSE_ERROR="unterminated group"
        return 1
      fi
      if [[ $expect_item == true ]]; then
        PARSE_ERROR="trailing comma"
        return 1
      fi
      return 0
    fi

    if [[ $in_group == false && $rest =~ $group_re ]]; then
      in_group=true
      rest=$(ltrim "${BASH_REMATCH[2]}")
      if [[ $rest == \;* ]]; then
        in_group=false
        rest=${rest:1}
        expect_item=false
        rest=$(ltrim "$rest")
        [[ -z $rest ]] && return 0
        if [[ $rest == ,* ]]; then
          rest=${rest:1}
          expect_item=true
          continue
        fi
        PARSE_ERROR="unexpected text after group: ${rest:0:40}"
        return 1
      fi
      continue
    fi

    if [[ $rest =~ $quoted_re ]]; then
      PARSED_ADDRESSES+=("${BASH_REMATCH[2],,}")
      rest=${BASH_REMATCH[3]}
    elif [[ $rest =~ $phrase_re ]]; then
      PARSED_ADDRESSES+=("${BASH_REMATCH[2],,}")
      rest=${BASH_REMATCH[3]}
    elif [[ $rest =~ $angle_re ]]; then
      PARSED_ADDRESSES+=("${BASH_REMATCH[1],,}")
      rest=${BASH_REMATCH[2]}
    elif [[ $rest =~ $bare_re ]]; then
      PARSED_ADDRESSES+=("${BASH_REMATCH[1],,}")
      rest=${BASH_REMATCH[2]}
    else
      PARSE_ERROR="not an allowed address form: ${rest:0:60}"
      return 1
    fi
    expect_item=false

    rest=$(ltrim "$rest")
    if [[ -z $rest ]]; then
      continue
    fi
    if [[ $rest == ,* ]]; then
      rest=${rest:1}
      expect_item=true
      continue
    fi
    if [[ $in_group == true && $rest == \;* ]]; then
      in_group=false
      rest=$(ltrim "${rest:1}")
      [[ -z $rest ]] && return 0
      if [[ $rest == ,* ]]; then
        rest=${rest:1}
        expect_item=true
        continue
      fi
    fi
    PARSE_ERROR="unexpected text after address: ${rest:0:60}"
    return 1
  done
}

is_e2e_sender() {
  local address=${1,,}
  [[ $address == "$ACCOUNT_A" || $address == "$ACCOUNT_B" ]]
}

is_allowed_bare_address() {
  local LC_ALL=C
  local bare_only_re='^'"$ADDR_RE"'$'
  [[ $1 =~ $bare_only_re ]]
}

unfolded_headers() {
  awk '
    { sub(/\r$/, "") }
    /^$/ { exit }
    /^[ \t]/ { sub(/^[ \t]+/, " "); current = current $0; next }
    { if (current != "") print current; current = $0 }
    END { if (current != "") print current }
  ' "$1"
}

GUARD_REASONS=()
HEADER_FROM_ADDRESS=""

# Checks a message's top-level headers: every header name is on the
# allowlist, every address-bearing header parses as allowed addresses, and
# there is exactly one From with exactly one e2e mailbox. Sets
# HEADER_FROM_ADDRESS.
guard_header_block() {
  local file=$1 label=$2 line header_name header_value lower_name address from_count=0
  local LC_ALL=C
  HEADER_FROM_ADDRESS=""
  if [[ ! -s $file ]]; then
    GUARD_REASONS+=("$label: message file missing or empty")
    return
  fi
  local header_re='^([A-Za-z0-9-]+)[[:blank:]]*:(.*)$'
  while IFS= read -r line; do
    if [[ ! $line =~ $header_re ]]; then
      GUARD_REASONS+=("$label: malformed header line: ${line:0:60}")
      continue
    fi
    header_name=${BASH_REMATCH[1]}
    header_value=${BASH_REMATCH[2]}
    lower_name=${header_name,,}
    if [[ $ALLOWED_HEADERS != *" $lower_name "* ]]; then
      GUARD_REASONS+=("$label: header $header_name is not on the allowlist")
      continue
    fi
    [[ $ADDRESS_HEADERS == *" $lower_name "* ]] || continue
    if ! parse_address_list "$header_value"; then
      GUARD_REASONS+=("$label: $header_name: $PARSE_ERROR")
      continue
    fi
    if [[ $lower_name == from || $lower_name == sender ]]; then
      for address in "${PARSED_ADDRESSES[@]}"; do
        is_e2e_sender "$address" ||
          GUARD_REASONS+=("$label: $header_name address $address is not an e2e account")
      done
    fi
    if [[ $lower_name == from ]]; then
      from_count=$((from_count + 1))
      if ((${#PARSED_ADDRESSES[@]} != 1)); then
        GUARD_REASONS+=("$label: From must hold exactly one mailbox")
      else
        HEADER_FROM_ADDRESS=${PARSED_ADDRESSES[0]}
      fi
    fi
  done < <(unfolded_headers "$file")
  if ((from_count != 1)); then
    GUARD_REASONS+=("$label: expected exactly one From header, found $from_count")
    HEADER_FROM_ADDRESS=""
  fi
}

# Mirrors the binary's argv grammar for the flags the scenarios use and
# refuses everything else: -t, -f ADDR / -fADDR, -F NAME / -FNAME, bundles of
# those, --send, --no-ui, -- and positional recipients.
guard_argv() {
  local args=("$@") i=0 j arg flag value end_of_options=false
  while ((i < ${#args[@]})); do
    arg=${args[i]}
    i=$((i + 1))
    if [[ $end_of_options == true || $arg != -* || $arg == - ]]; then
      is_allowed_bare_address "$arg" ||
        GUARD_REASONS+=("$NAME: argv recipient \"$arg\" is not a bare @example.test address")
      continue
    fi
    case $arg in
      --) end_of_options=true ;;
      --send | --no-ui) ;;
      --*) GUARD_REASONS+=("$NAME: argv option $arg is not allowed") ;;
      *)
        for ((j = 1; j < ${#arg}; j++)); do
          flag=${arg:j:1}
          case $flag in
            t) ;;
            f | F)
              value=${arg:j+1}
              if [[ -z $value ]]; then
                if ((i >= ${#args[@]})); then
                  GUARD_REASONS+=("$NAME: -$flag without a value")
                  break
                fi
                value=${args[i]}
                i=$((i + 1))
              fi
              if [[ $flag == f ]] && ! { is_allowed_bare_address "$value" && is_e2e_sender "$value"; }; then
                GUARD_REASONS+=("$NAME: -f \"$value\" is not an e2e account")
              fi
              break
              ;;
            *)
              GUARD_REASONS+=("$NAME: argv flag -$flag (in $arg) is not allowed")
              break
              ;;
          esac
        done
        ;;
    esac
  done
}

guard_scenario() {
  GUARD_REASONS=()
  local args=()
  binary_args args
  guard_header_block "$FIXTURE" "$NAME fixture"
  guard_argv "${args[@]}"
  if [[ -z $EXPECT_FROM_ADDR ]] || ! is_e2e_sender "$EXPECT_FROM_ADDR"; then
    GUARD_REASONS+=("$NAME: expected From ${EXPECT_FROM_ADDR:-none} is not an e2e account")
  fi
  grep -qxF "Subject: $SUBJECT" "$FIXTURE" ||
    GUARD_REASONS+=("$NAME: fixture Subject is not the unique run subject")
  ((${#GUARD_REASONS[@]} == 0))
}


# ---------------------------------------------------------------------------
# Dry runs. The binary runs only with SENDMAIL_DRY_RUN=1, inside
# tests/e2e/dry-run.sb, with TMPDIR set to a fresh per-run directory that is the
# only place the sandbox lets it write. The sandbox also forbids deleting
# files, so the .eml it would hand Mail can be checked whatever the binary's
# cleanup does.

readonly SANDBOX_PROFILE="$E2E_RESOURCES/dry-run.sb"
readonly SANDBOX=(/usr/bin/sandbox-exec -f "$SANDBOX_PROFILE")
readonly TEMPLATES="$E2E_RESOURCES/templates"
DRY_RUN_COUNTER=0
DRY_RUN_TMP=""

is_binary_temp_dir() {
  local dir=$1 parent=$2
  [[ $(basename "$dir") =~ ^sendmail-[0-9]+-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ ]] &&
    [[ $(dirname "$dir") == "$parent" ]]
}

list_binary_temp_dirs() {
  local parent=$1 dir
  for dir in "$parent"/sendmail-*; do
    [[ -d $dir ]] && is_binary_temp_dir "$dir" "$parent" && printf '%s\n' "$dir"
  done
  return 0
}

# Queues for deletion only the dirs that this dry run created (absent from
# the snapshot taken before it ran) and that the printed output names, or
# that are empty (a --no-ui message without attachments names no file).
collect_dry_run_temp_dirs() {
  local script_file=$1 snapshot_file=$2 dir path printed_dirs=""
  while IFS= read -r path; do
    printed_dirs+="$(dirname "$path")"$'\n'
  done < <(grep -oE '"/[^"]*/sendmail-[^/"]+/[^"/]+"' "$script_file" | tr -d '"' || true)
  while IFS= read -r dir; do
    grep -qxF "$dir" "$snapshot_file" && continue
    if grep -qxF "$dir" <<<"$printed_dirs" || [[ -z $(find "$dir" -mindepth 1 -print -quit) ]]; then
      DRY_RUN_TEMP_DIRS+=("$dir")
    else
      log "e2e: leaving $dir in place: it is new, not empty, and the dry-run output does not name it"
    fi
  done < <(list_binary_temp_dirs "$DRY_RUN_TMP")
}

remove_dry_run_temp_dirs() {
  local dir
  for dir in "${DRY_RUN_TEMP_DIRS[@]}"; do
    if [[ -n $workdir && $dir == "$workdir/dry-run-tmp/"* ]] && is_binary_temp_dir "$dir" "$(dirname "$dir")"; then
      rm -rf "$dir" || log "e2e: could not remove $dir"
    fi
  done
  DRY_RUN_TEMP_DIRS=()
}

DRY_RUN_SENDER=""

has_nul_byte() {
  [[ $(wc -c <"$1") != "$(tr -d '\000' <"$1" | wc -c)" ]]
}

# Prefix that runs a command in a new session, so it has no controlling
# terminal.
readonly NO_TERMINAL=(perl -e 'use POSIX (); POSIX::setsid() or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n"' --)

# Runs the binary in the sandbox, in a new session with stdin from the
# fixture and stdout/stderr to files, then checks what it printed: the .eml
# path's step plan, or the --no-ui Apple Event path's.
dry_run_scenario() {
  local args=() script_file="$workdir/logs/${NAME}.dry-run.out" status=0 snapshot_file
  DRY_RUN_SENDER=""
  binary_args args
  DRY_RUN_COUNTER=$((DRY_RUN_COUNTER + 1))
  DRY_RUN_TMP="$workdir/dry-run-tmp/${NAME}.${DRY_RUN_COUNTER}"
  mkdir -p "$DRY_RUN_TMP"
  snapshot_file="$DRY_RUN_TMP.before"
  list_binary_temp_dirs "$DRY_RUN_TMP" >"$snapshot_file"
  run_bounded 60 env -u SENDMAIL_SEND -u SENDMAIL_NO_UI SENDMAIL_DRY_RUN=1 TMPDIR="$DRY_RUN_TMP/" \
    "${NO_TERMINAL[@]}" "${SANDBOX[@]}" -D "BINARY=$SENDMAIL_BIN" -D "TEMP_DIR=$DRY_RUN_TMP" "$SENDMAIL_BIN" "${args[@]}" \
    <"$FIXTURE" >"$script_file" 2>"$workdir/logs/${NAME}.dry-run.stderr" || status=$?
  collect_dry_run_temp_dirs "$script_file" "$snapshot_file"
  if ((status != 0)); then
    GUARD_REASONS+=("$NAME: dry run exited $status: $(tail -n 1 "$workdir/logs/${NAME}.dry-run.stderr") (if the binary now renames or deletes files, for example an atomic write, the sandbox's file-write-unlink rule, which also blocks rename, is the likely cause)")
    remove_dry_run_temp_dirs
    return 1
  fi
  local analysis=0
  analyze_dry_run_script "$script_file" || analysis=$?
  remove_dry_run_temp_dirs
  return "$analysis"
}

# A path the script names must be a file inside a binary temp dir that this
# dry run created.
is_dry_run_file() {
  local path=$1
  [[ $path != *..* && -f $path ]] && is_binary_temp_dir "$(dirname "$path")" "$DRY_RUN_TMP"
}

# The .eml path, which every message but a --no-ui one takes, prints its step
# plan, one JSON object per line. The plan is fixed apart from the .eml path,
# so it must equal the template for its mode (tests/e2e/templates) once that
# path is replaced. The path may not contain a quote or backslash, so it
# cannot end its JSON string early.
readonly OPEN_EML_STEP_RE='^\{"activates":true,"path":"(/[^"\\]*\.eml)","step":"open_eml"\}$'

analyze_eml_plan() {
  local plan_file=$1 template mode open_lines eml_path normalized_file differences
  if [[ $DELIVERY == send ]]; then mode=send; else mode=draft; fi
  template="$TEMPLATES/eml-plan-$mode.jsonl.tmpl"
  if [[ ! -s $template ]]; then
    GUARD_REASONS+=("$NAME: template $template is missing")
    return
  fi
  open_lines=$(grep -F '"open_eml"' "$plan_file" || true)
  if [[ $(grep -c . <<<"$open_lines") -ne 1 || ! $open_lines =~ $OPEN_EML_STEP_RE ]]; then
    GUARD_REASONS+=("$NAME: expected exactly one open_eml step with a plain .eml path")
    return
  fi
  eml_path=${BASH_REMATCH[1]}
  normalized_file="$plan_file.normalized"
  sed -E 's#^(\{"activates":true,"path":)"/[^"\\]*\.eml"(,"step":"open_eml"\})$#\1"<EML>"\2#' "$plan_file" >"$normalized_file"
  if ! differences=$(diff -u "$template" "$normalized_file"); then
    GUARD_REASONS+=("$NAME: plan differs from the $mode template: $(grep -E '^[-+][^-+]' <<<"$differences" | sed -n '1,6p' | paste -sd'|' -)")
    return
  fi
  if ! is_dry_run_file "$eml_path"; then
    GUARD_REASONS+=("$NAME: the .eml the binary would open is missing or outside this dry run's temp dir: $eml_path")
    return
  fi
  if has_nul_byte "$eml_path"; then
    GUARD_REASONS+=("$NAME: the .eml the binary would open contains a NUL byte")
    return
  fi
  cp "$eml_path" "$workdir/logs/${NAME}.dry-run.eml"
  guard_header_block "$eml_path" "$NAME generated .eml"
  DRY_RUN_SENDER=$HEADER_FROM_ADDRESS
}

# The --no-ui Apple Event path prints its PlainPlan, one JSON object per
# line, in this order: launch_mail, make_message, set_content, add_recipient per recipient,
# add_attachment per attachment, then send only for --send. Each line must be
# exactly jq's compact, key-sorted form of itself, so a duplicated key (jq
# keeps the last) or stray whitespace cannot make jq and the binary read a
# line differently, and must have exactly its step's keys and value types.
# The strings checked here leave jq base64-encoded, so no separator or
# control character inside them can shift a field.
readonly PLAIN_STEP_JQ='
  def str: type == "string";
  if type != "object" then "BAD"
  elif .step == "launch_mail" and keys == ["activates", "step", "timeout_ms"] and .activates == false and (.timeout_ms | type) == "number" then "L"
  elif .step == "make_message" and keys == ["sender", "step", "subject", "visible"] and (.subject | str) and (.visible | type) == "boolean" and ((.sender | str) or .sender == null) then
    "M \(.visible) \(if .sender == null then "-" else (.sender | @base64) end)"
  elif .step == "set_content" and keys == ["step", "text"] and (.text | str) then "C"
  elif .step == "add_recipient" and keys == ["address", "kind", "name", "step"] and (.kind == "to" or .kind == "cc" or .kind == "bcc") and (.address | str) and ((.name | str) or .name == null) then
    "R \(.address | @base64)"
  elif .step == "add_attachment" and keys == ["path", "step"] and (.path | str) then "A \(.path | @base64)"
  elif .step == "send" and keys == ["step"] then "S"
  else "BAD" end'

analyze_plain_plan() {
  local plan_file=$1 line line_number=0 canonical record kind value sequence="" visible="" sender="" sender_set=no
  local disallowed_count=0
  while IFS= read -r line || [[ -n $line ]]; do
    line_number=$((line_number + 1))
    if ! canonical=$(jq -cS . <<<"$line" 2>/dev/null) || [[ -z $canonical || $canonical == *$'\n'* ]]; then
      GUARD_REASONS+=("$NAME: plain plan line $line_number is not valid JSON")
      continue
    fi
    if [[ $canonical != "$line" ]]; then
      GUARD_REASONS+=("$NAME: plain plan line $line_number is not in canonical form (compact, sorted keys, no duplicate keys)")
      continue
    fi
    if ! record=$(jq -r "$PLAIN_STEP_JQ" <<<"$line" 2>/dev/null) || [[ $record == BAD || -z $record ]]; then
      disallowed_count=$((disallowed_count + 1))
      ((disallowed_count <= 5)) &&
        GUARD_REASONS+=("$NAME: plain plan line $line_number is not an allowed step: ${line:0:200}")
      continue
    fi
    kind=${record%% *}
    value=${record#* }
    case $kind in
      M)
        visible=${value%% *}
        if [[ ${value#* } == - ]]; then
          GUARD_REASONS+=("$NAME: plain-text plan sets no sender, so Mail would use its default account")
        else
          sender=$(base64 -d <<<"${value#* }")
          sender_set=yes
        fi
        ;;
      R)
        value=$(base64 -d <<<"$value")
        is_allowed_bare_address "$value" ||
          GUARD_REASONS+=("$NAME: plain plan adds recipient \"$value\"")
        ;;
      A)
        value=$(base64 -d <<<"$value")
        is_dry_run_file "$value" ||
          GUARD_REASONS+=("$NAME: plain plan attaches $value, not a file in this dry run's temp dir")
        ;;
    esac
    sequence+=$kind
  done <"$plan_file"
  ((disallowed_count > 5)) &&
    GUARD_REASONS+=("$NAME: ...and $((disallowed_count - 5)) more lines that are not allowed steps")

  local wanted_sequence_re='^LMCR+A*$' wanted_visible=true
  if [[ $DELIVERY == send ]]; then
    wanted_sequence_re='^LMCR+A*S$'
    wanted_visible=false
  fi
  [[ $sequence =~ $wanted_sequence_re ]] ||
    GUARD_REASONS+=("$NAME: plain plan steps $sequence do not match $wanted_sequence_re (L launch, M make message, C content, R recipient, A attachment, S send)")
  [[ $visible == "$wanted_visible" ]] ||
    GUARD_REASONS+=("$NAME: plain plan has visible ${visible:-none}, expected visible $wanted_visible for a $DELIVERY run")

  if [[ $sender_set == yes ]]; then
    local sender_tokens
    sender_tokens=$(grep -oE '[^<>"[:space:],]+@[^<>"[:space:],]+' <<<"$sender" || true)
    if [[ $(grep -c . <<<"$sender_tokens") -ne 1 ]] || ! is_e2e_sender "$sender_tokens"; then
      GUARD_REASONS+=("$NAME: plain-text sender \"$sender\" is not exactly one e2e account")
    else
      DRY_RUN_SENDER=${sender_tokens,,}
    fi
  fi
}

analyze_dry_run_script() {
  local script_file=$1 token
  DRY_RUN_SENDER=""
  if [[ ! -f $script_file ]] || has_nul_byte "$script_file"; then
    GUARD_REASONS+=("$NAME: the dry-run output is missing or contains a NUL byte")
    return 1
  fi
  case $EXPECT_PATH in
    eml) analyze_eml_plan "$script_file" ;;
    apple-events) analyze_plain_plan "$script_file" ;;
    *) GUARD_REASONS+=("$NAME: unknown expected path ${EXPECT_PATH:-none}") ;;
  esac
  while IFS= read -r token; do
    [[ -z $token ]] && continue
    is_allowed_bare_address "$token" ||
      GUARD_REASONS+=("$NAME: the dry-run output names $token")
  done < <(grep -oE '[^<>"[:space:],(){}:]+@[^<>"[:space:],(){}]+' "$script_file" || true)
  if [[ -z $DRY_RUN_SENDER ]] && ((${#GUARD_REASONS[@]} == 0)); then
    GUARD_REASONS+=("$NAME: no e2e sender could be established from the dry run")
  fi
  ((${#GUARD_REASONS[@]} == 0))
}

declare -A REFUSED
declare -A SCENARIO_SENDER
declare -A FIXTURE_SHA256

# Each fixture that passes is copied to checked/ and hashed; a live run sends
# exactly that file after re-checking the hash.
checked_fixture() {
  printf '%s\n' "$workdir/checked/$1.eml"
}

validate_all_scenarios() {
  local name runnable=0
  for name in "${selected[@]}"; do
    define_scenario "$name"
    GUARD_REASONS=()
    if guard_scenario && dry_run_scenario; then
      SCENARIO_SENDER[$name]=$DRY_RUN_SENDER
      cp "$FIXTURE" "$(checked_fixture "$name")"
      chmod 444 "$(checked_fixture "$name")"
      FIXTURE_SHA256[$name]=$(sha256sum "$(checked_fixture "$name")" | cut -d' ' -f1)
      runnable=$((runnable + 1))
      log "ok      $name (sender $DRY_RUN_SENDER)"
    else
      REFUSED[$name]=$(printf '%s\n' "${GUARD_REASONS[@]}")
      log "REFUSED $name"
      printf '          %s\n' "${GUARD_REASONS[@]}" >&2
    fi
  done
  log "e2e: $runnable of ${#selected[@]} scenario(s) pass the guards; refused ones are skipped in a live run"
  ((runnable > 0))
}


# ---------------------------------------------------------------------------
# Mail preflight. The AppleScripts only read state.

ACCOUNT_B_READY=false
PREFLIGHT_REASONS=()

# Under pipefail, `producer | grep -q` reports a match as failure whenever
# grep exits before the producer finishes writing (SIGPIPE, status 141). So
# the output is captured first, the producer's own status is checked (a ps
# failure counts as "not running", which refuses), and the match runs on a
# here-string. Every early-exit reader in this file follows that rule.
process_list() {
  /bin/ps -Ao comm
}

mail_is_running() {
  local processes
  processes=$(process_list) || return 1
  grep -qxF -- "$MAIL_APP_PROCESS" <<<"$processes"
}

# Reads the report from preflight.applescript on stdin: account, smtp and
# rule records, fields separated by ASCII 31, record type first.
validate_accounts() {
  PREFLIGHT_REASONS=()
  ACCOUNT_B_READY=false
  SMTP_ALIAS_REFERENCED=false
  local account_a_ready=false line separators record_type
  local name enabled addresses in_host in_port out_host out_port pop_deletion address e2e_address is_e2e
  local server_host server_port

  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line ]] && continue
    separators=${line//[!$FIELD_SEPARATOR]/}
    record_type=${line%%"$FIELD_SEPARATOR"*}
    case $record_type:${#separators} in
      smtp:4)
        IFS=$FIELD_SEPARATOR read -r record_type name enabled server_host server_port <<<"$line"
        if [[ $server_host == "$SMTP_B_ALIAS" && $server_port == "$SMTP_PORT" ]]; then
          SMTP_ALIAS_REFERENCED=true
        elif [[ $server_host != "$MAILPIT_HOST" || $server_port != "$SMTP_PORT" ]]; then
          PREFLIGHT_REASONS+=("SMTP server \"$name\" points at \"$server_host:$server_port\" (enabled: $enabled); only ${MAILPIT_HOST}:${SMTP_PORT} and ${SMTP_B_ALIAS}:${SMTP_PORT} (Mailpit) are allowed, so remove it, deleting its account if it has one")
        fi
        continue
        ;;
      rule:2)
        IFS=$FIELD_SEPARATOR read -r record_type name enabled <<<"$line"
        if [[ $enabled != false ]]; then
          PREFLIGHT_REASONS+=("Mail rule \"$name\" is enabled (\"$enabled\"); rules act on fetched test mail, so disable or delete it")
        fi
        continue
        ;;
      account:8) ;;
      *)
        PREFLIGHT_REASONS+=("malformed preflight record (type \"${record_type:0:20}\", ${#separators} separators): ${line:0:60}")
        continue
        ;;
    esac
    IFS=$FIELD_SEPARATOR read -r record_type name enabled addresses in_host in_port out_host out_port pop_deletion <<<"$line"
    if [[ -z $name ]]; then
      PREFLIGHT_REASONS+=("account record with an empty name: ${line:0:60}")
      continue
    fi

    is_e2e=false
    e2e_address=""
    IFS=',' read -r -a address_list <<<"$addresses"
    for address in "${address_list[@]}"; do
      address=${address// /}
      if is_e2e_sender "$address"; then
        is_e2e=true
        e2e_address=${address,,}
      fi
    done

    if [[ $is_e2e == false ]]; then
      if [[ $enabled != false ]]; then
        PREFLIGHT_REASONS+=("non-e2e account \"$name\" ($addresses) is enabled (\"$enabled\"): Mail could fall back to it; delete it and its SMTP server (disabling leaves the SMTP server, which is refused too), or use a dedicated macOS user")
      fi
      continue
    fi

    for address in "${address_list[@]}"; do
      address=${address// /}
      is_e2e_sender "$address" ||
        PREFLIGHT_REASONS+=("e2e account \"$name\" also carries non-e2e address $address")
    done
    case $enabled in
      true) ;;
      false)
        [[ $e2e_address == "$ACCOUNT_A" ]] && PREFLIGHT_REASONS+=("e2e account \"$name\" ($e2e_address) is disabled")
        continue
        ;;
      *)
        PREFLIGHT_REASONS+=("e2e account \"$name\" has an unreadable enabled state \"$enabled\"")
        continue
        ;;
    esac
    local wanted_in_port=$POP3_PORT
    [[ $e2e_address == "$ACCOUNT_B" ]] && wanted_in_port=$POP3_B_PORT
    if [[ $in_host != "$MAILPIT_HOST" || $in_port != "$wanted_in_port" ]]; then
      PREFLIGHT_REASONS+=("e2e account \"$name\" incoming server is $in_host:$in_port, expected ${MAILPIT_HOST}:${wanted_in_port}")
      continue
    fi
    local wanted_out_host=$MAILPIT_HOST
    [[ $e2e_address == "$ACCOUNT_B" ]] && wanted_out_host=$SMTP_B_ALIAS
    if [[ $out_host != "$wanted_out_host" || $out_port != "$SMTP_PORT" ]]; then
      PREFLIGHT_REASONS+=("e2e account \"$name\" outgoing server is ${out_host:-none}:${out_port:-none}, expected ${wanted_out_host}:${SMTP_PORT}")
      continue
    fi
    [[ $out_host == "$SMTP_B_ALIAS" ]] && SMTP_ALIAS_REFERENCED=true
    if [[ $pop_deletion != never && ! $pop_deletion =~ ^[1-9][0-9]*$ ]]; then
      PREFLIGHT_REASONS+=("e2e account \"$name\" POP server-copy deletion is \"$pop_deletion\"; set Remove copy from server after retrieving a message to Never")
      continue
    fi
    case $e2e_address in
      "$ACCOUNT_A") account_a_ready=true ;;
      "$ACCOUNT_B") ACCOUNT_B_READY=true ;;
    esac
  done

  [[ $account_a_ready == true ]] ||
    PREFLIGHT_REASONS+=("no enabled Mail account for $ACCOUNT_A pointing at Mailpit; see README.md one-time setup")
  ((${#PREFLIGHT_REASONS[@]} == 0))
}

MAIL_OUTGOING_COUNT=""
MAIL_OUTBOX_COUNT=""
MAIL_SELECTED_COUNT=""
MAIL_EXTRA_WINDOWS=()

# Reads the report from mail-windows.applescript on stdin: outgoing messages,
# Outbox messages, messages selected in main viewers, then one line per
# window that is not a main viewer. Anything but 0, 0, 0 and no windows is a
# refusal, as is any value that is not a number.
validate_mail_windows() {
  PREFLIGHT_REASONS=()
  MAIL_EXTRA_WINDOWS=()
  local line
  MAIL_OUTGOING_COUNT=""
  MAIL_OUTBOX_COUNT=""
  MAIL_SELECTED_COUNT=""
  IFS= read -r MAIL_OUTGOING_COUNT || true
  IFS= read -r MAIL_OUTBOX_COUNT || true
  IFS= read -r MAIL_SELECTED_COUNT || true
  # The outgoing-message count is recorded but not checked: Mail keeps every
  # --no-ui message it has sent in `outgoing messages` until it is
  # relaunched, so a nonzero count does not mean a compose is open. A real
  # compose window is a non-viewer window and is refused below; an invisible
  # outgoing message has no window for a keystroke to reach and cannot be
  # sent without an AppleScript `send`, which only the checked binary issues.
  # The line must still be present, so a truncated report is refused.
  if [[ -z $MAIL_OUTGOING_COUNT ]]; then
    PREFLIGHT_REASONS+=("Mail state report is empty")
  fi
  if [[ ! $MAIL_OUTBOX_COUNT =~ ^[0-9]+$ ]]; then
    PREFLIGHT_REASONS+=("unreadable Outbox count \"$MAIL_OUTBOX_COUNT\"")
  elif ((MAIL_OUTBOX_COUNT != 0)); then
    PREFLIGHT_REASONS+=("Mail's Outbox holds $MAIL_OUTBOX_COUNT message(s); delete them from the Outbox (never pick another server)")
  fi
  if [[ ! $MAIL_SELECTED_COUNT =~ ^[0-9]+$ ]]; then
    PREFLIGHT_REASONS+=("unreadable selected-message count \"$MAIL_SELECTED_COUNT\"")
  elif ((MAIL_SELECTED_COUNT != 0)); then
    PREFLIGHT_REASONS+=("$MAIL_SELECTED_COUNT message(s) are selected in Mail's viewer; select an empty mailbox so a stray Send Again has nothing to resend")
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line ]] && continue
    MAIL_EXTRA_WINDOWS+=("${line//$FIELD_SEPARATOR/, }")
    PREFLIGHT_REASONS+=("Mail window that is not a main viewer is open (id, title): ${line//$FIELD_SEPARATOR/, }")
  done
  ((${#PREFLIGHT_REASONS[@]} == 0))
}

# Every value starts as "unknown" so a failed or timed-out read can never
# leave a stale 0 behind.
read_mail_state() {
  local report_file="$workdir/logs/mail-windows.txt"
  MAIL_OUTGOING_COUNT=unknown
  MAIL_OUTBOX_COUNT=unknown
  MAIL_SELECTED_COUNT=unknown
  MAIL_EXTRA_WINDOWS=()
  mail_is_running || {
    PREFLIGHT_REASONS=("Mail is not running")
    return 1
  }
  if ! run_bounded 30 /usr/bin/osascript "$E2E_RESOURCES/mail-windows.applescript" >"$report_file" 2>"$workdir/logs/mail-windows.stderr"; then
    PREFLIGHT_REASONS=("Mail state check failed: $(tail -n 1 "$workdir/logs/mail-windows.stderr")")
    return 1
  fi
  validate_mail_windows <"$report_file"
}

# Cmd-Shift-D is Send Again on a viewer but Send on a compose window, so a
# run only proceeds while Mail shows nothing but its main viewer windows,
# has nothing selected and nothing queued. Retries briefly because a
# just-sent message can linger for a moment.
check_mail_windows() {
  local deadline=$((SECONDS + 10))
  while :; do
    read_mail_state && return 0
    ((SECONDS < deadline)) || return 1
    sleep 1
  done
}

# Mail delivers to Mailpit asynchronously; stopping Mailpit first would strand
# messages in the Outbox. Succeeds only when a fresh read shows the Outbox
# empty before the timeout; an unreadable Mail counts as not empty.
wait_for_outbox_empty() {
  local timeout=$1 deadline
  deadline=$((SECONDS + timeout))
  while :; do
    read_mail_state >/dev/null 2>&1 || true
    [[ $MAIL_OUTBOX_COUNT == 0 ]] && return 0
    ((SECONDS < deadline)) || return 1
    sleep 1
  done
}

final_mail_report() {
  local outbox_unconfirmed=$1
  printf '\nMail state after this run:\n' >&2
  if [[ $outbox_unconfirmed == true ]]; then
    printf '  WARNING: could not confirm that Mail'"'"'s Outbox is empty (Outbox count: %s), so a test message may be stuck there.\n' "${MAIL_OUTBOX_COUNT:-unknown}" >&2
    if mailpit_alive; then
      printf '  Mailpit is left running so Mail can still deliver it. If Mail offers to send with another server, never accept: delete the message from the Outbox.\n' >&2
    else
      printf '  Mailpit is no longer running, so Mail cannot deliver it. Remove the stuck message from Mail'"'"'s Outbox yourself, and never pick another server if Mail offers one.\n' >&2
    fi
  fi
  if ! mail_is_running; then
    printf '  Mail is not running; nothing else was checked.\n' >&2
    return
  fi
  if read_mail_state; then
    printf '  clean: no compose windows, Outbox empty, nothing selected.\n' >&2
    return
  fi
  printf '  Before the next run:\n' >&2
  printf '  - %s\n' "${PREFLIGHT_REASONS[@]}" >&2
}

# Reads accounts, SMTP servers and rules (read-only) and validates them, along
# with the system proxy settings and, when e2e-b's alias is in use, the alias.
check_accounts() {
  local report_file="$workdir/logs/preflight.txt"
  PREFLIGHT_REASONS=()
  mail_is_running || {
    PREFLIGHT_REASONS=("Mail is not running")
    return 1
  }
  if ! run_bounded 60 /usr/bin/osascript "$E2E_RESOURCES/preflight.applescript" >"$report_file" 2>"$workdir/logs/preflight.stderr"; then
    PREFLIGHT_REASONS=("account preflight failed: $(tail -n 1 "$workdir/logs/preflight.stderr")")
    return 1
  fi
  if has_nul_byte "$report_file"; then
    PREFLIGHT_REASONS=("account preflight output contains a NUL byte")
    return 1
  fi
  local accounts_ok=true
  validate_accounts <"$report_file" || accounts_ok=false
  check_proxies || accounts_ok=false
  if [[ $SMTP_ALIAS_REFERENCED == true ]] && ! check_smtp_alias; then
    accounts_ok=false
  fi
  [[ $accounts_ok == true ]]
}

# Mail honours system proxies. A SOCKS proxy resolves names on the proxy side
# (bypassing /etc/hosts) and could carry even 127.0.0.1 traffic elsewhere, so
# every proxy kind must be off. Keys scutil leaves out are off; any value but
# 0, or output that is not scutil's dictionary, refuses.
readonly PROXY_ENABLE_KEYS=(SOCKSEnable HTTPEnable HTTPSEnable ProxyAutoConfigEnable ProxyAutoDiscoveryEnable)

read_proxy_settings() {
  run_bounded 10 /usr/sbin/scutil --proxy
}

check_proxies() {
  local output key value
  if ! output=$(read_proxy_settings); then
    PREFLIGHT_REASONS+=("could not read the system proxy settings (scutil --proxy)")
    return 1
  fi
  if [[ $(head -n 1 <<<"$output") != "<dictionary> {" || $(tail -n 1 <<<"$output") != "}" ]]; then
    PREFLIGHT_REASONS+=("could not parse the system proxy settings: $(head -n 1 <<<"$output")")
    return 1
  fi
  local proxy_reasons=()
  for key in "${PROXY_ENABLE_KEYS[@]}"; do
    value=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//p" <<<"$output")
    [[ -z $value || $value == 0 ]] && continue
    proxy_reasons+=("system proxy setting $key is \"$(paste -sd, - <<<"$value")\"; turn every proxy off (System Settings -> Network -> Details -> Proxies)")
  done
  ((${#proxy_reasons[@]} == 0)) && return 0
  PREFLIGHT_REASONS+=("${proxy_reasons[@]}")
  return 1
}

# e2e-b's SMTP host is an /etc/hosts alias. Mail sends to whatever it
# resolves to, so it is accepted only while it resolves to this machine and
# nothing else:
#   - /etc/hosts holds exactly two lines for it, "127.0.0.1 <alias>" and
#     "::1 <alias>". With only the IPv4 line, macOS answers A locally but
#     sends the AAAA query to DNS, so an outside AAAA answer would reach
#     Mail (and Happy Eyeballs prefers IPv6).
#   - The system resolver, the authoritative gate since it is what Mail
#     uses, answers exactly 127.0.0.1 and ::1.
#   - Nothing listens on [::1]:1025 (Mailpit binds 127.0.0.1 only), so a
#     connection over IPv6 is refused and Mail falls back to 127.0.0.1.
#   - dig, an extra check of /etc/resolv.conf's servers only (not
#     /etc/resolver/*, scoped or VPN DNS, DoH or Private Relay), gets no
#     answer. Only exit 0 with no records, or exit 9 (no server reachable),
#     counts as no answer; any other exit refuses.
# Appends to PREFLIGHT_REASONS and fails on anything unexpected.
resolve_host_system() {
  run_bounded 10 /usr/bin/dscacheutil -q host -a name "$1"
}

resolve_alias_system() {
  resolve_host_system "$SMTP_B_ALIAS"
}

# dig_name NAME TYPE: prints dig's +short output and returns dig's status.
dig_name() {
  run_bounded 10 dig +short +time=2 +tries=1 "$1" "$2"
}

dig_alias() {
  dig_name "$SMTP_B_ALIAS" "$1"
}

# Prints "listening", "refused" or "unknown:<reason>" for [::1]:PORT.
probe_ipv6_loopback() {
  # shellcheck disable=SC2016 # Perl code, not shell
  run_bounded 10 perl -MSocket=:all -e '
    my $port = shift @ARGV;
    socket(my $s, AF_INET6, SOCK_STREAM, 0) or do { print "unknown:socket: $!\n"; exit 0 };
    my $address = pack_sockaddr_in6($port, inet_pton(AF_INET6, "::1"));
    if (connect($s, $address)) { print "listening\n" }
    elsif ($!{ECONNREFUSED}) { print "refused\n" }
    else { print "unknown:connect: $!\n" }
  ' -- "$1" || printf 'unknown:probe failed\n'
}

# Sets RESOLVED_IPV4 and RESOLVED_IPV6 (sorted, unique, one per line) from
# dscacheutil output.
parse_resolver_addresses() {
  RESOLVED_IPV4=$(sed -n 's/^ip_address:[[:space:]]*//p' <<<"$1" | LC_ALL=C sort -u)
  RESOLVED_IPV6=$(sed -n 's/^ipv6_address:[[:space:]]*//p' <<<"$1" | LC_ALL=C sort -u)
}

check_smtp_alias() {
  local hosts_lines resolver_output line address names
  local alias_reasons=()

  if [[ ! -r $HOSTS_FILE ]]; then
    alias_reasons+=("cannot read $HOSTS_FILE")
  else
    hosts_lines=""
    while IFS= read -r line || [[ -n $line ]]; do
      line=${line%%#*}
      read -r address names <<<"$line" || true
      [[ -z $address ]] && continue
      local -a name_list=()
      read -r -a name_list <<<"$names"
      local candidate
      for candidate in "${name_list[@]}"; do
        if [[ ${candidate,,} == "$SMTP_B_ALIAS" ]]; then
          hosts_lines+="$address ${name_list[*]}"$'\n'
          break
        fi
      done
    done <"$HOSTS_FILE"
    hosts_lines=$(sed '/^$/d' <<<"$hosts_lines" | LC_ALL=C sort)
    local wanted_hosts_lines
    wanted_hosts_lines=$(printf '127.0.0.1 %s\n::1 %s\n' "$SMTP_B_ALIAS" "$SMTP_B_ALIAS" | LC_ALL=C sort)
    if [[ $hosts_lines != "$wanted_hosts_lines" ]]; then
      alias_reasons+=("$HOSTS_FILE must map $SMTP_B_ALIAS with exactly two lines, \"127.0.0.1 $SMTP_B_ALIAS\" and \"::1 $SMTP_B_ALIAS\"; found [$(paste -sd'|' - <<<"$hosts_lines")] (see README.md)")
    fi
  fi

  if ! resolver_output=$(resolve_alias_system); then
    alias_reasons+=("the system resolver could not be queried for $SMTP_B_ALIAS")
  else
    parse_resolver_addresses "$resolver_output"
    if [[ $RESOLVED_IPV4 != 127.0.0.1 ]]; then
      alias_reasons+=("the system resolver gives $SMTP_B_ALIAS IPv4 [$(paste -sd, - <<<"$RESOLVED_IPV4")]; it must be exactly 127.0.0.1")
    fi
    if [[ $RESOLVED_IPV6 != ::1 ]]; then
      alias_reasons+=("the system resolver gives $SMTP_B_ALIAS IPv6 [$(paste -sd, - <<<"$RESOLVED_IPV6")]; it must be exactly ::1")
    fi
  fi

  local ipv6_listener
  ipv6_listener=$(probe_ipv6_loopback "$SMTP_PORT")
  if [[ $ipv6_listener != refused ]]; then
    alias_reasons+=("[::1]:${SMTP_PORT} is \"$ipv6_listener\", not refused; Mail would try it first for $SMTP_B_ALIAS, and only a refused connection is known to fall back to Mailpit on 127.0.0.1")
  fi

  local record_type dns_output dns_status
  for record_type in A AAAA; do
    dns_status=0
    dns_output=$(dig_alias "$record_type" 2>&1) || dns_status=$?
    case $dns_status in
      0)
        dns_output=$(sed '/^$/d; /^;/d' <<<"$dns_output")
        [[ -z $dns_output ]] ||
          alias_reasons+=("DNS ($record_type) answers for $SMTP_B_ALIAS ($(paste -sd, - <<<"$dns_output")); it must come only from $HOSTS_FILE")
        ;;
      9) ;;
      *) alias_reasons+=("dig $record_type $SMTP_B_ALIAS failed (exit $dns_status), so DNS could not be checked") ;;
    esac
  done

  ((${#alias_reasons[@]} == 0)) && return 0
  PREFLIGHT_REASONS+=("${alias_reasons[@]}")
  return 1
}

run_preflight() {
  mail_is_running || die "Mail is not running; start Mail first (the preflight must not launch it)"
  log "e2e: reading Mail accounts, SMTP servers, rules and windows (read-only AppleScript)"
  if ! check_accounts; then
    log "e2e: refusing to run:"
    printf '  - %s\n' "${PREFLIGHT_REASONS[@]}" >&2
    exit 2
  fi
  if ! check_mail_windows; then
    log "e2e: refusing to run:"
    printf '  - %s\n' "${PREFLIGHT_REASONS[@]}" >&2
    exit 2
  fi
  log "e2e: accounts ok ($ACCOUNT_A ready; $ACCOUNT_B ready: $ACCOUNT_B_READY); no enabled rules or outside SMTP servers; no compose windows, empty Outbox, nothing selected"
}

# ---------------------------------------------------------------------------
# Assertions against Mailpit

FAILURES=()
MESSAGE_IDS=()

fail_check() {
  FAILURES+=("$*")
}

message_ids_for_subject() {
  "${CURL[@]}" -fsS --max-time 5 "$API/messages?limit=500" |
    jq -r --arg subject "$SUBJECT" '.messages[]? | select(.Subject == $subject) | .ID'
}

wait_for_messages() {
  local timeout=$1 deadline
  deadline=$((SECONDS + timeout))
  MESSAGE_IDS=()
  while ((SECONDS <= deadline)); do
    mapfile -t MESSAGE_IDS < <(message_ids_for_subject)
    ((${#MESSAGE_IDS[@]} > 0)) && break
    sleep 0.5
  done
  if ((${#MESSAGE_IDS[@]} > 0)); then
    sleep "$settle_seconds"
    mapfile -t MESSAGE_IDS < <(message_ids_for_subject)
  fi
}

sorted_lines() {
  if (($# > 0)); then printf '%s\n' "$@" | LC_ALL=C sort -u; fi
}

# display_name_matches EXPECTED ACTUAL: exact, except for one Apple Mail
# quirk. For a display name holding both an RFC 5322 special and a
# non-ASCII character (e.g. `Bäcker, Anna`), Mail puts the quoted-string's
# quotes inside the RFC 2047 encoded-word, so it decodes as `"Bäcker, Anna"`.
# Only then is the expected name wrapped in exactly one pair of quotes also
# accepted.
display_name_matches() {
  local expected=$1 actual=$2
  [[ $actual == "$expected" ]] && return 0
  [[ $actual == "\"$expected\"" ]] || return 1
  local LC_ALL=C
  local specials_re='[]()<>:;@\\,."[]'
  [[ $expected =~ $specials_re ]] || return 1
  [[ -n $(printf '%s' "$expected" | tr -d '\000-\177') ]]
}

# Compares one recipient field (To or Cc) of a message: same address set, and
# the display name for every expected "address|Name" entry.
check_recipients() {
  local field=$1 detail=$2
  shift 2
  local expected_entries=("$@") expected_addresses=() entry actual_lines actual_addresses
  for entry in "${expected_entries[@]}"; do
    expected_addresses+=("$(printf '%s' "${entry%%|*}" | tr '[:upper:]' '[:lower:]')")
  done
  actual_lines=$(jq -r --arg f "$field" '.[$f][]? | "\(.Address | ascii_downcase)|\(.Name)"' "$detail")
  actual_addresses=$(printf '%s\n' "$actual_lines" | sed '/^$/d' | cut -d'|' -f1 | LC_ALL=C sort -u)
  if [[ "$actual_addresses" != "$(sorted_lines "${expected_addresses[@]}")" ]]; then
    fail_check "$field addresses: expected [$(sorted_lines "${expected_addresses[@]}" | paste -sd, -)] got [$(printf '%s' "$actual_lines" | paste -sd, -)]"
    return
  fi
  for entry in "${expected_entries[@]}"; do
    [[ $entry == *"|"* ]] || continue
    local want_address want_name
    want_address=$(printf '%s' "${entry%%|*}" | tr '[:upper:]' '[:lower:]')
    want_name=${entry#*|}
    local actual_line actual_name name_found=false
    while IFS= read -r actual_line; do
      [[ ${actual_line%%|*} == "$want_address" ]] || continue
      actual_name=${actual_line#*|}
      display_name_matches "$want_name" "$actual_name" && name_found=true
    done <<<"$actual_lines"
    [[ $name_found == true ]] ||
      fail_check "$field display name for $want_address: expected \"$want_name\" got \"$(grep -F "$want_address|" <<<"$actual_lines" | cut -d'|' -f2-)\""
  done
}

# Mailpit prepends its own trace headers to the stored message, ending with its
# Received line, and adds a Bcc header there for envelope-only recipients.
# Only the headers after that Received line are what Mail put on the wire.
sender_headers() {
  local all_headers
  all_headers=$(unfolded_headers "$1")
  if ! grep -q '^Received: .*(Mailpit) with SMTP' <<<"$all_headers"; then
    return 1
  fi
  awk 'found { print } /^Received: .*\(Mailpit\) with SMTP/ { found = 1 }' <<<"$all_headers"
}

# Mail sends a body set through its scripting dictionary as a quotation
# (FB11734014): every text/plain line prefixed with "> " and the HTML part
# wrapped in <blockquote type="cite">. A body that merely contains the marker
# would pass the text check, so the quoting is checked on its own. Lines the
# fixture's own body starts with "> " are allowed through.
readonly CITE_BLOCKQUOTE_RE='<blockquote[^>]*type=["'"'"']?cite'
readonly QUOTED_LINE_RE='^>( |$)'

fixture_quoted_lines() {
  awk 'in_body && /^> / { sub(/\r$/, ""); print } /^\r?$/ { in_body = 1 }' "$FIXTURE"
}

check_quoting() {
  local text=${1//$'\r'/} html=$2 quoted_lines fixture_lines line unexpected=()
  quoted_lines=$(grep -E "$QUOTED_LINE_RE" <<<"$text" || true)
  if [[ $EXPECT_QUOTED == true ]]; then
    grep -F -- "$BODY_MARKER" <<<"$quoted_lines" >/dev/null ||
      fail_check "text body is not quoted: no line starting with \"> \" holds the marker (has Apple fixed FB11734014? then update $NAME)"
    if grep -F -- "$BODY_MARKER" <<<"$text" | grep -vE "$QUOTED_LINE_RE" >/dev/null; then
      fail_check "text body has the marker on a line that is not quoted"
    fi
    if [[ -n $html ]] && ! grep -iE "$CITE_BLOCKQUOTE_RE" <<<"$html" >/dev/null; then
      fail_check "HTML part does not wrap the body in <blockquote type=\"cite\"> (has Apple fixed FB11734014? then update $NAME)"
    fi
    return
  fi
  fixture_lines=$(fixture_quoted_lines)
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    grep -xF -- "$line" <<<"$fixture_lines" >/dev/null || unexpected+=("$line")
  done <<<"$quoted_lines"
  ((${#unexpected[@]} == 0)) ||
    fail_check "text body is quoted (Mail bug FB11734014): ${#unexpected[@]} line(s) start with \"> \" that the fixture does not have, the first: \"${unexpected[0]:0:80}\""
  if grep -iE "$CITE_BLOCKQUOTE_RE" <<<"$html" >/dev/null && ! grep -iE "$CITE_BLOCKQUOTE_RE" "$FIXTURE" >/dev/null; then
    fail_check "HTML part wraps the body in <blockquote type=\"cite\"> (Mail bug FB11734014)"
  fi
}

check_message() {
  local id=$1 detail="$workdir/messages/$1.json" raw="$workdir/messages/$1.eml" headers
  if ! "${CURL[@]}" -fsS --max-time 10 "$API/message/$id" >"$detail" || ! jq -e '.ID' "$detail" >/dev/null 2>&1; then
    fail_check "could not fetch message $id from Mailpit"
    return
  fi
  if ! "${CURL[@]}" -fsS --max-time 10 "$API/message/$id/raw" >"$raw" || [[ ! -s $raw ]]; then
    fail_check "could not fetch the raw source of message $id from Mailpit"
    return
  fi
  if ! headers=$(sender_headers "$raw"); then
    fail_check "raw source of message $id has no Mailpit Received line, so the sender's headers cannot be isolated"
    return
  fi

  local from_address from_name
  from_address=$(jq -r '.From.Address // "" | ascii_downcase' "$detail")
  from_name=$(jq -r '.From.Name // ""' "$detail")
  [[ $from_address == "${EXPECT_FROM_ADDR,,}" ]] ||
    fail_check "From address: expected $EXPECT_FROM_ADDR got ${from_address:-none}"
  if [[ -n $EXPECT_FROM_NAME ]] && ! display_name_matches "$EXPECT_FROM_NAME" "$from_name"; then
    fail_check "From display name: expected \"$EXPECT_FROM_NAME\" got \"$from_name\""
  fi

  check_recipients To "$detail" "${EXPECT_TO[@]}"
  check_recipients Cc "$detail" "${EXPECT_CC[@]}"

  grep -qiE '^Resent-' <<<"$headers" &&
    fail_check "wire headers include $(grep -iE '^Resent-' <<<"$headers" | cut -d: -f1 | paste -sd, -)"
  grep -qiE '^Bcc[[:blank:]]*:' <<<"$headers" &&
    fail_check "wire headers include a Bcc header: $(grep -iE '^Bcc[[:blank:]]*:' <<<"$headers")"

  local body_text body_html
  if ! body_text=$(jq -r '.Text // ""' "$detail") || ! body_html=$(jq -r '.HTML // ""' "$detail"); then
    fail_check "could not read the text or HTML body of message $id"
  else
    if [[ -n $EXPECT_TEXT ]] && ! grep -qF -- "$EXPECT_TEXT" <<<"$body_text"; then
      fail_check "text body does not contain \"$EXPECT_TEXT\""
    fi
    if [[ -n $EXPECT_HTML ]] && ! grep -qF -- "$EXPECT_HTML" <<<"$body_html"; then
      fail_check "HTML part missing or does not contain \"$EXPECT_HTML\""
    fi
    check_quoting "$body_text" "$body_html"
  fi

  local actual_attachments entry want_name want_size want_sha found name size sha
  actual_attachments=$(jq -r '((.Attachments // []) + (.Inline // []))[] | "\(.FileName)|\(.Size)|\(.Checksums.SHA256 // "")"' "$detail")
  local actual_count
  actual_count=$(printf '%s' "$actual_attachments" | grep -c . || true)
  if ((actual_count != ${#EXPECT_ATTACH[@]})); then
    fail_check "attachments: expected ${#EXPECT_ATTACH[@]} got $actual_count [$(printf '%s' "$actual_attachments" | cut -d'|' -f1,2 | paste -sd, -)]"
  fi
  for entry in "${EXPECT_ATTACH[@]}"; do
    IFS='|' read -r want_name want_size want_sha <<<"$entry"
    found=false
    while IFS='|' read -r name size sha; do
      [[ -z $name$size ]] && continue
      if [[ $name == "$want_name" && $size == "$want_size" && $sha == "$want_sha" ]]; then
        found=true
      fi
    done <<<"$actual_attachments"
    [[ $found == true ]] ||
      fail_check "no attachment named $want_name with size $want_size and sha256 ${want_sha:0:12}...: got [$(printf '%s' "$actual_attachments" | awk -F'|' '{printf "%s%s (%s bytes, sha256 %.12s...)", (NR > 1 ? ", " : ""), $1, $2, $3}')]"
  done
}

check_delivery() {
  local timeout=$1 id
  FAILURES=()
  wait_for_messages "$timeout"
  if ((${#MESSAGE_IDS[@]} == 0)); then
    fail_check "no message with subject \"$SUBJECT\" arrived within ${timeout}s"
    return 1
  fi
  if [[ $ALLOW_MULTIPLE == false ]] && ((${#MESSAGE_IDS[@]} != 1)); then
    fail_check "expected 1 message, got ${#MESSAGE_IDS[@]}"
  fi
  for id in "${MESSAGE_IDS[@]}"; do
    check_message "$id"
  done

  local actual_bcc
  actual_bcc=$(for id in "${MESSAGE_IDS[@]}"; do
    jq -r '.Bcc[]?.Address | ascii_downcase' "$workdir/messages/$id.json" 2>/dev/null || true
  done | LC_ALL=C sort -u)
  local expected_bcc=()
  local entry
  for entry in "${EXPECT_BCC[@]}"; do
    expected_bcc+=("$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')")
  done
  [[ "$actual_bcc" == "$(sorted_lines "${expected_bcc[@]}")" ]] ||
    fail_check "Bcc (envelope-only) recipients: expected [$(sorted_lines "${expected_bcc[@]}" | paste -sd, -)] got [$(printf '%s' "$actual_bcc" | paste -sd, -)]"

  ((${#FAILURES[@]} == 0))
}

# ---------------------------------------------------------------------------
# Modes

cmd_list() {
  local name
  printf '%-30s %s\n' SCENARIO DESCRIPTION
  for name in "${SCENARIOS[@]}"; do
    define_scenario "$name"
    printf '%-30s %s\n' "$name" "$DESCRIPTION"
  done
}

cmd_check_only() {
  prepare_binary
  log "e2e: validating ${#selected[@]} scenario(s) (sandboxed dry runs)"
  validate_all_scenarios || die "no scenario passes the guards"
  start_mailpit
  log "e2e: check-only passed"
}

cmd_serve() {
  start_mailpit
  log "e2e: Mailpit is serving SMTP ${MAILPIT_HOST}:${SMTP_PORT}, POP3 ${MAILPIT_HOST}:${POP3_PORT} for e2e-a and ${MAILPIT_HOST}:${POP3_B_PORT} for e2e-b (password ${POP3_PASSWORD}), web UI http://${MAILPIT_HOST}:${HTTP_PORT}/"
  log "e2e: Ctrl-C to stop"
  wait "$mailpit_pid"
}

declare -A RESULT
declare -A RESULT_REASONS

record() {
  local name=$1 status=$2
  shift 2
  RESULT[$name]=$status
  RESULT_REASONS[$name]=$(if (($# > 0)); then printf '%s\n' "$@"; fi)
  log "$status $name"
  if (($# > 0)); then printf '      - %s\n' "$@" >&2; fi
}

# Results: PASS; FAIL; REFUSED (a guard refused the scenario before Mail was
# touched); ABORTED (a pre-scenario check stopped the run); SKIP (could not
# run, e.g. no e2e-b account). The run succeeds only if every selected
# scenario passed, or with --allow-refused, passed or was REFUSED.
run_succeeded() {
  local name status
  for name in "${selected[@]}"; do
    status=${RESULT[$name]:-NOT-RUN}
    [[ $status == PASS ]] && continue
    [[ $status == REFUSED && $allow_refused == true ]] && continue
    return 1
  done
  return 0
}

print_summary() {
  local name reason status
  local -A totals=()
  printf '\n%-30s %s\n' SCENARIO RESULT
  for name in "${selected[@]}"; do
    status=${RESULT[$name]:-NOT-RUN}
    totals[$status]=$((${totals[$status]:-0} + 1))
    printf '%-30s %s\n' "$name" "$status"
    if [[ -n ${RESULT_REASONS[$name]:-} ]]; then
      while IFS= read -r reason; do
        printf '      - %s\n' "$reason"
      done <<<"${RESULT_REASONS[$name]}"
    fi
  done
  printf '\n%s passed, %s failed, %s refused by guards, %s aborted, %s skipped, %s not run\n' \
    "${totals[PASS]:-0}" "${totals[FAIL]:-0}" "${totals[REFUSED]:-0}" "${totals[ABORTED]:-0}" "${totals[SKIP]:-0}" "${totals[NOT-RUN]:-0}"
  if run_succeeded; then
    if [[ $allow_refused == true && ${totals[REFUSED]:-0} -gt 0 ]]; then
      printf 'RESULT: success (every scenario passed or was refused by a guard; --allow-refused)\n\n'
    else
      printf 'RESULT: success (every selected scenario passed)\n\n'
    fi
    return 0
  fi
  printf 'RESULT: FAILURE (not every selected scenario passed%s)\n\n' "$([[ $allow_refused == true ]] || printf '; pass --allow-refused to accept guard refusals')"
  return 1
}

# Checked before every scenario; any failure aborts the rest of the run.
# The Mailpit and binary checks come first and never touch Mail.
live_precheck() {
  mailpit_alive || {
    PREFLIGHT_REASONS=("Mailpit (pid ${mailpit_pid:-none}) is no longer running or answering")
    return 1
  }
  binary_unchanged || {
    PREFLIGHT_REASONS=("the binary under test changed since it was checked")
    return 1
  }
  mail_is_running || {
    PREFLIGHT_REASONS=("Mail is no longer running")
    return 1
  }
  check_accounts || return 1
  check_mail_windows
}

needs_missing_account_b() {
  [[ ${SCENARIO_SENDER[$1]:-} == "$ACCOUNT_B" && $ACCOUNT_B_READY != true ]]
}

fixture_unchanged() {
  local name=$1 checked
  checked=$(checked_fixture "$name")
  [[ -f $checked && -n ${FIXTURE_SHA256[$name]:-} && $(sha256sum "$checked" | cut -d' ' -f1) == "${FIXTURE_SHA256[$name]}" ]]
}

draft_already_delivered() {
  mapfile -t MESSAGE_IDS < <(message_ids_for_subject)
  ((${#MESSAGE_IDS[@]} > 0))
}

run_live_scenario() {
  local name=$1 args=() status=0 reasons=()
  define_scenario "$name"
  if needs_missing_account_b "$name"; then
    record "$name" SKIP "needs the $ACCOUNT_B Mail account"
    return
  fi
  if ! fixture_unchanged "$name"; then
    record "$name" SKIP "the checked fixture changed or is missing; not sending it"
    return
  fi
  binary_args args
  log "e2e: running $name"
  # From here on Mail may hold a message of ours, so cleanup drains its
  # Outbox before stopping Mailpit. A refusal before this point must not.
  mail_touched=true
  run_bounded 120 env -u SENDMAIL_SEND -u SENDMAIL_NO_UI -u SENDMAIL_DRY_RUN "$SENDMAIL_BIN" "${args[@]}" <"$(checked_fixture "$name")" \
    >"$workdir/logs/$name.stdout" 2>"$workdir/logs/$name.stderr" || status=$?
  if ((status != 0)); then
    reasons+=("binary exited $status: $(tail -n 1 "$workdir/logs/$name.stderr")")
    if [[ $DELIVERY == draft-later ]]; then
      record "$name" FAIL "${reasons[@]}"
      return
    fi
  fi

  if [[ $DELIVERY == draft-later ]]; then
    log "e2e: waiting ${draft_wait}s before sending the draft by hand"
    sleep "$draft_wait"
    if draft_already_delivered; then
      record "$name" FAIL "the draft was delivered without --send"
      return
    fi
    if ! run_bounded 30 /usr/bin/osascript "$E2E_RESOURCES/send-compose-window.applescript" "$SUBJECT" \
      >"$workdir/logs/$name.send-later.log" 2>&1; then
      record "$name" FAIL "could not send the draft window: $(tail -n 1 "$workdir/logs/$name.send-later.log")"
      return
    fi
  fi

  if check_delivery "$delivery_timeout"; then
    if ((${#reasons[@]} > 0)); then
      record "$name" FAIL "${reasons[@]}"
    else
      record "$name" PASS
    fi
  else
    record "$name" FAIL "${reasons[@]}" "${FAILURES[@]}"
  fi
  sleep 2
}

cmd_live() {
  prepare_binary
  log "e2e: validating fixtures and guards before touching Mail"
  validate_all_scenarios || die "no scenario passes the guards; nothing was sent"
  start_mailpit
  run_preflight
  local name aborted=""
  for name in "${selected[@]}"; do
    if [[ -n ${REFUSED[$name]:-} ]]; then
      local refusal_reasons=()
      mapfile -t refusal_reasons <<<"${REFUSED[$name]}"
      record "$name" REFUSED "refused by guard:" "${refusal_reasons[@]}"
      continue
    fi
    if [[ -n $aborted ]]; then
      record "$name" ABORTED "run aborted: $aborted"
      continue
    fi
    if ! live_precheck; then
      aborted=$(printf '%s; ' "${PREFLIGHT_REASONS[@]}")
      record "$name" ABORTED "run aborted: $aborted"
      continue
    fi
    run_live_scenario "$name"
  done
  print_summary
}


# ---------------------------------------------------------------------------
# Self-test: drives the assertions with messages injected straight into
# Mailpit over SMTP (no Mail.app), once as Mail should send them and once per
# deliberate defect, and checks the guards, the dry-run checks, the sandbox
# and the preflight parsers.

SELF_TEST_MISMATCHES=0
SELF_TEST_CASES=0

self_test_expect() {
  local wanted=$1 label=$2 actual=$3
  shift 3
  SELF_TEST_CASES=$((SELF_TEST_CASES + 1))
  if [[ $wanted == "$actual" ]]; then
    printf '  ok   %-58s %s\n' "$label" "$actual"
  else
    printf '  BAD  %-58s expected %s, got %s\n' "$label" "$wanted" "$actual"
    SELF_TEST_MISMATCHES=$((SELF_TEST_MISMATCHES + 1))
  fi
  if (($# > 0)); then printf '         reason: %s\n' "$@"; fi
}

# refusal_outcome WANTED_REASON REASON...: "refused" when WANTED_REASON is
# empty or a substring of some REASON, so a case can prove that the guard it
# targets fired rather than an unrelated one.
refusal_outcome() {
  local wanted_reason=$1 reason
  shift
  if [[ -z $wanted_reason ]]; then
    printf 'refused\n'
    return
  fi
  for reason in "$@"; do
    if [[ $reason == *"$wanted_reason"* ]]; then
      printf 'refused\n'
      return
    fi
  done
  printf 'refused without "%s"\n' "$wanted_reason"
}

# expect_outcome WANTED LABEL WORD_IF_TRUE WORD_IF_FALSE COMMAND...
expect_outcome() {
  local wanted=$1 label=$2 true_word=$3 false_word=$4
  shift 4
  if "$@"; then
    self_test_expect "$wanted" "$label" "$true_word"
  else
    self_test_expect "$wanted" "$label" "$false_word"
  fi
}

cli_from_header() {
  local i from_address="" from_name=""
  for ((i = 0; i < ${#SEND_ARGS[@]}; i++)); do
    case ${SEND_ARGS[i]} in
      -f) from_address=${SEND_ARGS[i + 1]:-} ;;
      -F) from_name=${SEND_ARGS[i + 1]:-} ;;
    esac
  done
  [[ -n $from_address ]] || return 0
  if [[ -n $from_name ]]; then
    printf 'From: "%s" <%s>\n' "$from_name" "$from_address"
  else
    printf 'From: %s\n' "$from_address"
  fi
}

# Writes the message as Mail should put it on the wire: the fixture minus its
# Bcc header, with From taken from -f/-F when they are given and the
# attachment carrying the exact name Mail should send.
write_wire_message() {
  local attachment_name=""
  ((${#EXPECT_ATTACH[@]} > 0)) && attachment_name=${EXPECT_ATTACH[0]%%|*}
  awk -v from_override="$(cli_from_header)" -v attachment_name="$attachment_name" '
    BEGIN { in_headers = 1 }
    in_headers && /^\r?$/ { in_headers = 0 }
    in_headers && /^[Bb][Cc][Cc]:/ { skipping = 1; next }
    in_headers && skipping && /^[ \t]/ { next }
    in_headers && from_override != "" && /^[Ff][Rr][Oo][Mm]:/ { skipping = 0; print from_override; next }
    !in_headers && attachment_name != "" && /^Content-Disposition: attachment/ {
      print "Content-Disposition: attachment; filename=\"" attachment_name "\""; next
    }
    { skipping = 0; print }
  ' "$FIXTURE" >"$1"
}

# Rewrites the wire file's body the way Mail sends a --no-ui message: a
# multipart/alternative whose text part is the fixture body with every line
# quoted and whose HTML part wraps it in <blockquote type="cite">, or with
# cite=no, does not.
quote_wire_body() {
  local wire=$1 cite=$2 html_body
  html_body="<p>${BODY_MARKER}</p>"
  [[ $cite == yes ]] && html_body="<blockquote type=\"cite\">${html_body}</blockquote>"
  {
    awk '/^\r?$/ { exit } !/^(MIME-Version|Content-Type|Content-Transfer-Encoding):/ { print }' "$wire"
    printf 'MIME-Version: 1.0\nContent-Type: multipart/alternative; boundary="cite-b"\n\n--cite-b\nContent-Type: text/plain; charset=utf-8\n\n'
    awk 'in_body { print "> " $0 } /^\r?$/ { in_body = 1 }' "$wire"
    printf -- '--cite-b\nContent-Type: text/html; charset=utf-8\n\n<html><body>%s</body></html>\n--cite-b--\n' "$html_body"
  } >"$wire.quoted"
  mv "$wire.quoted" "$wire"
}

inject() {
  local file=$1 mail_from=$2
  shift 2
  local rcpt_args=() rcpt
  for rcpt in "$@"; do
    rcpt_args+=(--mail-rcpt "$rcpt")
  done
  "${CURL[@]}" -fsS --max-time 10 "smtp://${MAILPIT_HOST}:${SMTP_PORT}" --mail-from "$mail_from" "${rcpt_args[@]}" -T "$file"
}

expected_envelope_recipients() {
  local entry
  for entry in "${EXPECT_TO[@]}" "${EXPECT_CC[@]}" "${EXPECT_BCC[@]}"; do
    printf '%s\n' "${entry%%|*}"
  done
}

other_account() {
  if [[ ${1,,} == "$ACCOUNT_A" ]]; then printf '%s\n' "$ACCOUNT_B"; else printf '%s\n' "$ACCOUNT_A"; fi
}

# Applies one named defect to the wire file and the envelope, then injects.
inject_variant() {
  local variant=$1 wire="$workdir/fixtures/${NAME}.${1}.wire.eml" mail_from=$EXPECT_FROM_ADDR copies=1
  local recipients=() rcpt
  mapfile -t recipients < <(expected_envelope_recipients)
  write_wire_message "$wire"
  if [[ $EXPECT_QUOTED == true ]]; then
    case $variant in
      body-unquoted) ;;
      html-cite-dropped) quote_wire_body "$wire" no ;;
      *) quote_wire_body "$wire" yes ;;
    esac
  fi

  case $variant in
    correct | body-unquoted | html-cite-dropped) ;;
    missing) return 0 ;;
    duplicate) copies=2 ;;
    resent-header) sed -i "1i Resent-From: ${EXPECT_FROM_ADDR}" "$wire" ;;
    wrong-from)
      mail_from=$(other_account "$EXPECT_FROM_ADDR")
      sed -i "/^From:/ s/${EXPECT_FROM_ADDR}/${mail_from}/" "$wire"
      ;;
    from-name-changed) sed -i "s/^From:.*/From: E2E Account A <${EXPECT_FROM_ADDR}>/" "$wire" ;;
    to-replaced)
      sed -i '/^To:/d' "$wire"
      sed -i '1i To: stray@example.test' "$wire"
      recipients+=(stray@example.test)
      ;;
    names-unquoted) sed -i '/^To:/ s/"//g' "$wire" ;;
    cc-dropped) sed -i '/^Cc:/d' "$wire" ;;
    names-dropped)
      local bare_to
      bare_to=$(printf '%s\n' "${EXPECT_TO[@]}" | cut -d'|' -f1 | paste -sd, - | sed 's/,/, /g')
      sed -i "s/^To:.*/To: ${bare_to}/" "$wire"
      ;;
    bcc-header-kept) cp "$FIXTURE" "$wire" ;;
    bcc-undelivered)
      local bcc_entry kept=()
      for rcpt in "${recipients[@]}"; do
        for bcc_entry in "${EXPECT_BCC[@]}"; do
          [[ $rcpt == "$bcc_entry" ]] && continue 2
        done
        kept+=("$rcpt")
      done
      recipients=("${kept[@]}")
      ((${#recipients[@]} > 0)) || recipients=(someone-else@example.test)
      ;;
    body-changed) sed -i "s/${BODY_MARKER}/changed body/g" "$wire" ;;
    body-quoted) sed -i "s/^${BODY_MARKER}\$/> &/" "$wire" ;;
    html-cite-wrapped) sed -i 's#<html><body>#&<blockquote type="cite">#; s#</body></html>#</blockquote>&#' "$wire" ;;
    html-dropped) sed -i 's#^Content-Type: text/html#Content-Type: text/plain#' "$wire" ;;
    attachment-corrupted)
      local flipped
      if [[ ${ATTACH_B64_FIRST_LINE:0:1} == A ]]; then flipped=B; else flipped=A; fi
      sed -i "s#^${ATTACH_B64_FIRST_LINE}\$#${flipped}${ATTACH_B64_FIRST_LINE:1}#" "$wire"
      ;;
    attachment-truncated) sed -i "\\#^${ATTACH_B64_FIRST_LINE}\$#d" "$wire" ;;
    attachment-renamed) sed -i 's/^Content-Disposition: attachment.*/Content-Disposition: attachment; filename="renamed.dat"/' "$wire" ;;
    attachment-name-prefix-dropped)
      local suffix_name=${EXPECT_ATTACH[0]%%|*}
      sed -i "s/^Content-Disposition: attachment.*/Content-Disposition: attachment; filename=\"x${suffix_name}\"/" "$wire"
      ;;
    attachment-dropped)
      awk '/^Content-Type: application\/octet-stream/ { exit } { print }' "$wire" >"$wire.tmp"
      printf -- '--mixed-b--\n' >>"$wire.tmp"
      mv "$wire.tmp" "$wire"
      ;;
    *) die "unknown self-test variant $variant" ;;
  esac

  local i
  for ((i = 0; i < copies; i++)); do
    inject "$wire" "$mail_from" "${recipients[@]}"
  done
}

variants_for_scenario() {
  printf '%s\n' correct missing resent-header wrong-from body-changed
  [[ $ALLOW_MULTIPLE == false ]] && printf '%s\n' duplicate
  [[ -n $EXPECT_FROM_NAME ]] && printf '%s\n' from-name-changed
  ((${#EXPECT_TO[@]} > 0)) && printf '%s\n' to-replaced
  ((${#EXPECT_CC[@]} > 0)) && printf '%s\n' cc-dropped
  [[ ${EXPECT_TO[*]} == *"|"* ]] && printf '%s\n' names-unquoted names-dropped
  ((${#EXPECT_BCC[@]} > 0)) && printf '%s\n' bcc-header-kept bcc-undelivered
  [[ -n $EXPECT_HTML ]] && printf '%s\n' html-dropped
  if [[ $EXPECT_QUOTED == true ]]; then
    printf '%s\n' body-unquoted html-cite-dropped
  else
    printf '%s\n' body-quoted
    [[ -n $EXPECT_HTML ]] && printf '%s\n' html-cite-wrapped
  fi
  ((${#EXPECT_ATTACH[@]} > 0)) && printf '%s\n' attachment-corrupted attachment-truncated attachment-renamed attachment-name-prefix-dropped attachment-dropped
  return 0
}

self_test_assertions() {
  local name variant expected actual
  settle_seconds=0.3
  for name in "${selected[@]}"; do
    define_scenario "$name"
    printf '%s\n' "$name"
    while read -r variant; do
      clear_mailpit
      inject_variant "$variant"
      if [[ $variant == correct ]]; then expected=PASS; else expected=FAIL; fi
      if check_delivery 2; then actual=PASS; else actual=FAIL; fi
      if [[ $actual == FAIL ]]; then
        self_test_expect "$expected" "$variant" "$actual" "${FAILURES[@]}"
      else
        self_test_expect "$expected" "$variant" "$actual"
      fi
    done < <(variants_for_scenario)
  done

  printf 'assertion plumbing (Mailpit fetch failures)\n'
  define_scenario plain-send
  clear_mailpit
  inject_variant correct
  local message_id
  message_id=$(message_ids_for_subject | sed -n '1p')
  check_with_failing_fetch() {
    local label=$1 failing_path=$2
    FAILURES=()
    # shellcheck disable=SC2329 # invoked through "${CURL[@]}"
    curl() {
      if [[ $* == *"$failing_path"* ]]; then return 22; fi
      command curl "$@"
    }
    check_message "$message_id"
    unset -f curl
    if ((${#FAILURES[@]} > 0)); then
      self_test_expect FAIL "$label" FAIL "${FAILURES[@]}"
    else
      self_test_expect FAIL "$label" PASS
    fi
  }
  check_with_failing_fetch "message JSON fetch fails" "/message/$message_id"
  check_with_failing_fetch "raw source fetch fails" "/message/$message_id/raw"

  printf 'a fixture body that quotes a line itself\n'
  local variant expected actual
  for variant in correct body-quoted; do
    define_scenario plain-send
    printf '> e2e quoted by the fixture %s\n' "$RUN_ID" >>"$FIXTURE"
    clear_mailpit
    inject_variant "$variant"
    if [[ $variant == correct ]]; then expected=PASS; else expected=FAIL; fi
    if check_delivery 2; then actual=PASS; else actual=FAIL; fi
    self_test_expect "$expected" "fixture's own \"> \" line, $variant" "$actual" "${FAILURES[@]}"
  done
}

run_guard_case() {
  local label=$1 wanted=$2
  GUARD_REASONS=()
  if guard_scenario; then
    self_test_expect "$wanted" "$label" accepted
  else
    self_test_expect "$wanted" "$label" refused "${GUARD_REASONS[@]}"
  fi
  define_scenario plain-send
}

set_fixture_header() {
  printf '%s\n' "$1" | sed -i '1r /dev/stdin' "$FIXTURE"
}

self_test_guards() {
  printf 'guards\n'
  local name
  for name in "${SCENARIOS[@]}"; do
    define_scenario "$name"
    GUARD_REASONS=()
    if guard_scenario; then
      self_test_expect accepted "$name fixture and argv" accepted
    else
      self_test_expect accepted "$name fixture and argv" refused "${GUARD_REASONS[@]}"
    fi
  done
  define_scenario plain-send

  sed -i 's/^Subject: .*/Subject: a reused subject/' "$FIXTURE"
  run_guard_case "Subject is not the unique run subject" refused

  sed -i 's/^To: .*/To: someone@gmail.com/' "$FIXTURE"
  run_guard_case "To at a real domain" refused

  sed -i 's/^To: .*/To : real@gmail.com/' "$FIXTURE"
  run_guard_case "To with space before the colon" refused

  sed -i 's/^To: .*/TO:real@gmail.com/' "$FIXTURE"
  run_guard_case "upper-case TO without a space" refused

  sed -i 's/^To: .*/To: "john doe"@gmail.com/' "$FIXTURE"
  run_guard_case "quoted local part at a real domain" refused

  sed -i 's/^To: .*/To: postmaster/' "$FIXTURE"
  run_guard_case "bare local name (postmaster)" refused

  sed -i 's/^To: .*/To: real@gmail.com@example.test/' "$FIXTURE"
  run_guard_case "real@gmail.com@example.test" refused

  sed -i 's/^To: .*/To: a@example.test.evil.com/' "$FIXTURE"
  run_guard_case "example.test as a prefix of a real domain" refused

  sed -i 's/^To: .*/To: Team: a@example.test, real@gmail.com;/' "$FIXTURE"
  run_guard_case "group with one real member" refused

  sed -i 's/^To: .*/To: a@example.test (comment) /' "$FIXTURE"
  run_guard_case "address with a comment" refused

  sed -i 's/^To: .*/To: a@example.test,/' "$FIXTURE"
  run_guard_case "trailing comma" refused

  set_fixture_header 'Cc: "x" <ok@example.test>, real@icloud.com'
  run_guard_case "Cc with one real address" refused

  set_fixture_header 'Bcc: hidden@example.org'
  run_guard_case "Bcc at example.org (not .test)" refused

  set_fixture_header 'Sender: real@gmail.com'
  run_guard_case "real Sender" refused

  set_fixture_header 'Sender: someone@example.test'
  run_guard_case "Sender at example.test but not an e2e account" refused

  set_fixture_header 'Reply-To: real@gmail.com'
  run_guard_case "real Reply-To" refused

  set_fixture_header 'Resent-To: a@example.test'
  run_guard_case "Resent-To (not on the header allowlist)" refused

  set_fixture_header 'X-Forward-To: real@gmail.com'
  run_guard_case "unknown header" refused

  set_fixture_header 'not a header line'
  run_guard_case "header line without a colon" refused

  set_fixture_header $'To: a@example.test,\n b@EXAMPLE.TEST,\n\tc@evil.example.com'
  run_guard_case "folded To header hiding a real address" refused

  sed -i 's/^To: .*/To: Team: a@example.test, "B, b" <b@example.test>;, c@example.test/' "$FIXTURE"
  run_guard_case "group of allowed members plus an address" accepted

  sed -i 's/^To: .*/To: =?UTF-8?B?w6l0w6k=?= <a@example.test>, Jürgen <j@example.test>/' "$FIXTURE"
  run_guard_case "encoded-word and 8-bit display names" accepted

  sed -i 's/^To: .*/to:a@EXAMPLE.test/' "$FIXTURE"
  run_guard_case "lower-case to without a space, upper-case domain" accepted

  sed -i 's/^From: .*/From: someone@example.net/' "$FIXTURE"
  run_guard_case "From not an e2e account" refused

  sed -i 's/^From: .*/From: e2e-a@example.test, e2e-b@example.test/' "$FIXTURE"
  run_guard_case "From with two mailboxes" refused

  sed -i '/^From:/d' "$FIXTURE"
  run_guard_case "no From header" refused

  set_fixture_header 'From: e2e-b@example.test'
  run_guard_case "two From headers" refused

  SEND_ARGS=(-t -f someone@example.net)
  run_guard_case "-f not an e2e account" refused

  SEND_ARGS=(-t -fsomeone@example.net)
  run_guard_case "attached -f not an e2e account" refused

  SEND_ARGS=(-tfreal@gmail.com)
  run_guard_case "-tfreal@gmail.com bundle" refused

  SEND_ARGS=(-t -f "$ACCOUNT_A" real@gmail.com)
  run_guard_case "positional real recipient" refused

  SEND_ARGS=(-t -f "$ACCOUNT_A" -- real@gmail.com)
  run_guard_case "-- real@gmail.com" refused

  SEND_ARGS=(-t -f "$ACCOUNT_A" -- -x@example.test)
  run_guard_case "-- then an allowed dash-leading address" accepted

  SEND_ARGS=(-t -f "$ACCOUNT_A" '"x y"@example.test')
  run_guard_case "positional quoted local part" refused

  SEND_ARGS=(-t -f "$ACCOUNT_A" -i)
  run_guard_case "unexpected flag -i" refused

  SEND_ARGS=(-t -f)
  run_guard_case "-f without a value" refused

  SEND_ARGS=(-tf "$ACCOUNT_B" -F "Anyone, Else")
  run_guard_case "-tf e2e-b with -F" accepted
}

self_test_dry_run() {
  printf 'binary dry-run checks (sandboxed)\n'

  run_dry_run_case() {
    local label=$1 wanted=$2 wanted_reason=${3-}
    GUARD_REASONS=()
    if dry_run_scenario; then
      self_test_expect "$wanted" "$label" accepted
    else
      self_test_expect "$wanted" "$label" "$(refusal_outcome "$wanted_reason" "${GUARD_REASONS[@]}")" "${GUARD_REASONS[@]}"
    fi
  }

  local name
  for name in plain-send plain-send-no-ui html-send draft-later-html-attachment draft-later-plain-attachment plain-attachment-send; do
    define_scenario "$name"
    run_dry_run_case "$name as defined" accepted
  done

  define_scenario html-send
  EXPECT_PATH=apple-events
  run_dry_run_case "HTML fixture expected on the Apple Event path" refused \
    "is not an allowed step"

  define_scenario plain-send
  EXPECT_PATH=apple-events
  run_dry_run_case "plain fixture without --no-ui expected on the Apple Event path" refused \
    "is not an allowed step"

  define_scenario plain-send-no-ui
  EXPECT_PATH=eml
  run_dry_run_case "--no-ui plain fixture expected on the .eml path" refused \
    "expected exactly one open_eml step"

  define_scenario plain-send-no-ui
  SEND_ARGS=(-t -f "$ACCOUNT_A")
  run_dry_run_case "Apple Event scenario run without --no-ui" refused \
    "is not an allowed step"

  define_scenario html-send
  SEND_ARGS+=(--no-ui)
  run_dry_run_case "HTML fixture with --no-ui (the binary must refuse it)" refused \
    "dry run exited 64"

  # Mail holds a message without a Subject for a confirmation the binary
  # cannot answer, so --send without one must stop before Mail is touched.
  define_scenario plain-send
  sed -i '/^Subject:/d' "$FIXTURE"
  run_dry_run_case "--send fixture without a Subject (the binary must refuse it)" refused \
    "dry run exited 65"

  define_scenario plain-send-no-ui
  sed -i 's/^Subject: .*/Subject: /' "$FIXTURE"
  run_dry_run_case "--no-ui --send fixture with an empty Subject (the binary must refuse it)" refused \
    "dry run exited 65"

  define_scenario html-send
  sed -i 's/^Subject: .*/Subject:  \t /' "$FIXTURE"
  run_dry_run_case "HTML --send fixture with a whitespace-only Subject (the binary must refuse it)" refused \
    "dry run exited 65"

  define_scenario draft-later-plain-attachment
  sed -i '/^Subject:/d' "$FIXTURE"
  run_dry_run_case "draft fixture without a Subject (still a draft)" accepted

  define_scenario draft-later-plain-attachment
  SEND_ARGS+=(--send)
  run_dry_run_case "plain draft that would press Send" refused \
    "plan differs from the draft template"

  define_scenario draft-later-html-attachment
  SEND_ARGS+=(--send)
  run_dry_run_case "HTML draft that would press Send" refused \
    "plan differs from the draft template"

  define_scenario plain-send-no-ui
  DELIVERY=draft-later
  SEND_ARGS+=(--send)
  run_dry_run_case "--no-ui draft that would be sent" refused \
    "do not match"

  define_scenario plain-send-no-ui
  SEND_ARGS=(-t --no-ui)
  sed -i '/^From:/d' "$FIXTURE"
  run_dry_run_case "--no-ui with no -f and no From (no sender set)" refused \
    "plain-text plan sets no sender"

  define_scenario plain-send
  SEND_ARGS=(-t)
  sed -i '/^From:/d' "$FIXTURE"
  run_dry_run_case "plain .eml with no -f and no From (no sender)" refused

  define_scenario plain-send
  sed -i '/^To:/d' "$FIXTURE"
  run_dry_run_case "fixture the binary rejects (no recipients)" refused

  define_scenario html-send
  sed -i 's/^To: .*/To: real@gmail.com/' "$FIXTURE"
  run_dry_run_case "HTML .eml with a real To (header guard on the .eml)" refused

  define_scenario plain-send
  sed -i 's/^To: .*/To: real@gmail.com/' "$FIXTURE"
  run_dry_run_case "plain .eml with a real To (header guard on the .eml)" refused

  define_scenario plain-send-no-ui
  sed -i 's/^To: .*/To: real@gmail.com/' "$FIXTURE"
  run_dry_run_case "--no-ui plan with a real recipient" refused \
    "adds recipient"
}

# Crafted scripts, built from the real templates and the --no-ui PlainPlan
# shape, prove each branch of the script analysis, including the bypasses a
# reviewer found against the earlier blocklist.
self_test_script_analysis() {
  printf 'dry-run script analysis (crafted scripts)\n'
  local crafted_root="$workdir/dry-run-tmp/crafted" temp_dir eml attachment
  DRY_RUN_TMP=$crafted_root
  temp_dir="$crafted_root/sendmail-1-01234567-89AB-CDEF-0123-456789ABCDEF"
  mkdir -p "$temp_dir"
  eml="$temp_dir/compose-1.eml"
  attachment="$temp_dir/att-01-a.bin"
  printf 'From: e2e-a@example.test\nTo: a@example.test\nSubject: x\n\nbody\n' >"$eml"
  printf 'data\n' >"$attachment"
  printf 'From: e2e-a@example.test\nTo: a@example.test\nSubject: x\n\nbody\n' >"$workdir/outside.eml"

  local html_send html_draft
  html_send=$(sed "s#\"<EML>\"#\"$eml\"#" "$TEMPLATES/eml-plan-send.jsonl.tmpl")
  html_draft=$(sed "s#\"<EML>\"#\"$eml\"#" "$TEMPLATES/eml-plan-draft.jsonl.tmpl")

  plain_plan() {
    local visible=$1 send_step=$2 sender_json=${3-'"e2e-a@example.test"'}
    local make_line=${4:-"{\"sender\":$sender_json,\"step\":\"make_message\",\"subject\":\"s\",\"visible\":$visible}"}
    printf '%s\n' \
      '{"activates":false,"step":"launch_mail","timeout_ms":10000}' \
      "$make_line" \
      '{"step":"set_content","text":"body"}' \
      '{"address":"a@example.test","kind":"to","name":"A","step":"add_recipient"}' \
      "{\"path\":\"$attachment\",\"step\":\"add_attachment\"}"
    [[ -z $send_step ]] || printf '{"step":"send"}\n'
  }

  # SCENARIO:draft runs a send scenario as a draft, for plain-send-no-ui,
  # the only scenario on the Apple Event path.
  run_analysis_case() {
    local label=$1 wanted=$2 scenario=${3%:draft} wanted_reason=${5-} script_file="$workdir/logs/crafted.out"
    define_scenario "$scenario"
    [[ $3 == *:draft ]] && DELIVERY=draft-later
    DRY_RUN_TMP=$crafted_root
    printf '%s\n' "$4" >"$script_file"
    GUARD_REASONS=()
    if analyze_dry_run_script "$script_file"; then
      self_test_expect "$wanted" "$label" accepted
    else
      self_test_expect "$wanted" "$label" "$(refusal_outcome "$wanted_reason" "${GUARD_REASONS[@]}")" "${GUARD_REASONS[@]}"
    fi
  }

  run_analysis_case "HTML send plan matching the template" accepted html-send "$html_send"
  run_analysis_case "HTML draft plan matching the template" accepted draft-later-html-attachment "$html_draft"
  run_analysis_case "plain send matching the .eml send template" accepted plain-send "$html_send"
  run_analysis_case "plain draft matching the .eml draft template" accepted draft-later-plain-attachment "$html_draft"
  run_analysis_case "plain send printing the Apple Event plan" refused plain-send "$(plain_plan false send)" \
    "expected exactly one open_eml step"
  run_analysis_case "--no-ui send printing the .eml plan" refused plain-send-no-ui "$html_send" \
    "is not an allowed step"
  run_analysis_case "--no-ui send plan" accepted plain-send-no-ui "$(plain_plan false send)"
  run_analysis_case "--no-ui draft plan" accepted plain-send-no-ui:draft "$(plain_plan true '')"
  run_analysis_case "--no-ui draft whose subject mentions send" accepted plain-send-no-ui:draft \
    "$(plain_plan true '' | sed 's/"subject":"s"/"subject":"please send"/')"

  local send_again_step full_guard
  send_again_step=$(grep -F '"fallback_title":"Send Again"' <<<"$html_send")
  full_guard='"guard":["frontmost","focused_window","main_window","standard_window","no_sheet"]'
  run_analysis_case "HTML send with a second Send Again press" refused html-send \
    "${html_send/"$send_again_step"/"$send_again_step"$'\n'"$send_again_step"}" \
    "plan differs from the send template"
  run_analysis_case "HTML draft with an extra Send press" refused draft-later-html-attachment \
    "$(sed '$i {"guard":[],"guard_timeout_ms":3000,"item":{"fallback_menu":"Message","fallback_title":"Send","shortcut":"shift-cmd-D"},"step":"press_menu_item","verify":["title_matches_subject"],"window":"compose"}' <<<"$html_draft")" \
    "plan differs from the draft template"
  run_analysis_case "HTML send that finds Send Again by title only" refused html-send \
    "${html_send/',"shortcut":"shift-cmd-D"},"step":"press_menu_item"'/'},"step":"press_menu_item"'}" \
    "plan differs from the send template"
  run_analysis_case "HTML send whose Send Again shortcut drops Shift" refused html-send \
    "${html_send/'"shortcut":"shift-cmd-D"},"step":"press_menu_item"'/'"shortcut":"cmd-D"},"step":"press_menu_item"'}" \
    "plan differs from the send template"
  run_analysis_case "HTML send without the Message > Send step" refused html-send \
    "$(grep -vF '"step":"press_until_window_closes"' <<<"$html_send")" \
    "plan differs from the send template"
  run_analysis_case "HTML send whose presses skip the key-window guard" refused html-send \
    "${html_send//"$full_guard"/'"guard":[]'}" \
    "plan differs from the send template"
  run_analysis_case "HTML send whose presses skip the window-contents check" refused html-send \
    "${html_send//'"verify":["title_matches_subject"]'/'"verify":[]'}" \
    "plan differs from the send template"
  run_analysis_case "HTML draft whose Send Again skips the window-contents check" refused draft-later-html-attachment \
    "${html_draft//',"verify":["title_matches_subject"]'/}" \
    "plan differs from the draft template"
  run_analysis_case "HTML send with unbounded Send presses" refused html-send \
    "${html_send/'"max_presses":3'/'"max_presses":1000'}" \
    "plan differs from the send template"
  run_analysis_case "HTML plan with two open_eml steps" refused html-send \
    "$(printf '{"activates":true,"path":"%s","step":"open_eml"}\n%s\n' "$eml" "$html_send")" \
    "expected exactly one open_eml step"
  run_analysis_case "HTML plan whose .eml path hides an escaped quote" refused html-send \
    "${html_send//\"$eml\"/\"$temp_dir/x\\\".eml\"}" \
    "expected exactly one open_eml step"
  run_analysis_case "HTML plan whose .eml is outside the dry run's temp dir" refused html-send \
    "${html_send//\"$eml\"/\"$workdir/outside.eml\"}" \
    "missing or outside this dry run's temp dir"
  run_analysis_case "HTML plan whose .eml was deleted" refused html-send \
    "${html_send//\"$eml\"/\"$temp_dir/gone.eml\"}" \
    "missing or outside this dry run's temp dir"
  run_analysis_case "HTML plan with no open_eml step" refused html-send \
    "$(grep -vF '"step":"open_eml"' <<<"$html_send")" \
    "expected exactly one open_eml step"

  run_analysis_case "--no-ui send with an extra Message > Send press step" refused plain-send-no-ui \
    "$(plain_plan false send; printf '%s\n' '{"guard":[],"guard_timeout_ms":3000,"item":{"fallback_menu":"Message","fallback_title":"Send","shortcut":"shift-cmd-D"},"step":"press_menu_item","verify":["title_matches_subject"],"window":"compose"}')" \
    "is not an allowed step"
  # The subject string hides a second sender behind escaped quotes; a naive
  # scan would take e2e-a for the sender while jq reads the real one.
  local escaped_make_line
  escaped_make_line='{"sender":"me@gmail.com","step":"make_message","subject":"x\",\"sender\":\"e2e-a@example.test","visible":true}'
  run_analysis_case "--no-ui draft hiding a sender behind an escaped quote" refused plain-send-no-ui:draft \
    "$(plain_plan true '' '' "$escaped_make_line")" \
    "is not exactly one e2e account"
  run_analysis_case "--no-ui recipient postmaster" refused plain-send-no-ui \
    "$(plain_plan false send | sed 's/"address":"a@example.test"/"address":"postmaster"/')" \
    "adds recipient \"postmaster\""
  run_analysis_case "--no-ui plan with a duplicated sender key" refused plain-send-no-ui \
    "$(plain_plan false send '"e2e-a@example.test","sender":"me@gmail.com"')" \
    "is not in canonical form"
  run_analysis_case "--no-ui plan with whitespace in a line" refused plain-send-no-ui \
    "$(plain_plan false send | sed 's/^{"step":"send"}$/{ "step":"send"}/')" \
    "is not in canonical form"
  run_analysis_case "--no-ui plan with a keystroke step" refused plain-send-no-ui \
    "$(plain_plan false send | sed 's/^{"step":"set_content","text":"body"}$/&\n{"key":"d","step":"keystroke"}/')" \
    "is not an allowed step"
  run_analysis_case "--no-ui recipient step with an extra key" refused plain-send-no-ui \
    "$(plain_plan false send | sed 's/"step":"add_recipient"}/"step":"add_recipient","via":"x"}/')" \
    "is not an allowed step"
  run_analysis_case "--no-ui --send plan that is visible" refused plain-send-no-ui "$(plain_plan true send)" \
    "expected visible false"
  run_analysis_case "--no-ui --send plan without a send step" refused plain-send-no-ui "$(plain_plan false '')" \
    "do not match"
  run_analysis_case "--no-ui draft plan with a send step" refused plain-send-no-ui:draft "$(plain_plan true send)" \
    "do not match"
  run_analysis_case "--no-ui draft plan that is invisible" refused plain-send-no-ui:draft "$(plain_plan false '')" \
    "expected visible true"
  run_analysis_case "--no-ui plan without a sender" refused plain-send-no-ui "$(plain_plan false send null)" \
    "plain-text plan sets no sender"
  run_analysis_case "--no-ui plan with a real sender" refused plain-send-no-ui \
    "$(plain_plan false send '"Me <me@gmail.com>"')" \
    "is not exactly one e2e account"
  run_analysis_case "--no-ui sender naming two addresses" refused plain-send-no-ui \
    "$(plain_plan false send '"e2e-a@example.test <me@gmail.com>"')" \
    "is not exactly one e2e account"
  run_analysis_case "--no-ui plan with an unterminated string" refused plain-send-no-ui \
    "$(plain_plan false send | sed 's/"subject":"s"/"subject":"s/')" \
    "is not valid JSON"
  run_analysis_case "recipient with a \\t escape (decoded to a real tab)" refused plain-send-no-ui \
    "$(plain_plan false send | sed 's/"address":"a@example.test"/"address":"a@example.test\\t"/')" \
    "adds recipient"
  run_analysis_case "recipient with a \\n escape (line break)" refused plain-send-no-ui \
    "$(plain_plan false send | sed 's/"address":"a@example.test"/"address":"a@example.test\\nreal@gmail.com"/')" \
    "adds recipient"
  run_analysis_case "subject with a \\t escape" accepted plain-send-no-ui \
    "$(plain_plan false send | sed 's/"subject":"s"/"subject":"a\\tb"/')"
  run_analysis_case "--no-ui plan attaching a file outside the temp dir" refused plain-send-no-ui \
    "$(plain_plan false send | sed "s#$attachment#$workdir/outside.eml#")" \
    "not a file in this dry run's temp dir"

  local nul_script="$workdir/logs/nul.out"
  {
    plain_plan false send | sed -n '1,2p'
    printf '{"step":"send"}\0\n'
    plain_plan false send | tail -n +3
  } >"$nul_script"
  define_scenario plain-send-no-ui
  DRY_RUN_TMP=$crafted_root
  GUARD_REASONS=()
  if analyze_dry_run_script "$nul_script"; then
    self_test_expect refused "plan containing a NUL byte" accepted
  else
    self_test_expect refused "plan containing a NUL byte" "$(refusal_outcome "contains a NUL byte" "${GUARD_REASONS[@]}")" "${GUARD_REASONS[@]}"
  fi
  printf 'From: e2e-a@example.test\nTo: a@example.test\0, real@gmail.com\nSubject: x\n\nbody\n' >"$eml"
  run_analysis_case "HTML .eml containing a NUL byte" refused html-send "$html_send"
}

self_test_temp_dirs() {
  printf 'dry-run temp dir handling\n'
  local parent="$workdir/dry-run-tmp/td-test" good_name=sendmail-42-01234567-89AB-CDEF-0123-456789ABCDEF

  expect_outcome yes "binary temp dir in its parent" yes no is_binary_temp_dir "$parent/$good_name" "$parent"
  for bad in "$parent/sendmail-42-01234567-89ab-cdef-0123-456789abcdef" "$parent/sendmail-x" "$parent/other-42-01234567-89AB-CDEF-0123-456789ABCDEF"; do
    if is_binary_temp_dir "$bad" "$parent"; then
      self_test_expect no "not a binary temp dir: $(basename "$bad")" yes
    else
      self_test_expect no "not a binary temp dir: $(basename "$bad")" no
    fi
  done
  if is_binary_temp_dir "$workdir/$good_name" "$parent"; then
    self_test_expect no "binary temp dir name under another parent" yes
  else
    self_test_expect no "binary temp dir name under another parent" no
  fi

  DRY_RUN_TMP=$parent
  mkdir -p "$parent"
  local decoy="$parent/sendmail-1-AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
  local named="$parent/sendmail-2-BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
  local unnamed="$parent/sendmail-3-CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
  local outside="$workdir/sendmail-4-DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
  local empty="$parent/sendmail-5-EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
  mkdir -p "$decoy"
  list_binary_temp_dirs "$parent" >"$parent.before"
  mkdir -p "$named" "$unnamed" "$outside" "$empty"
  printf 'data\n' >"$unnamed/att-01-x.bin"
  printf '{"path":"%s/att-01-a.bin","step":"add_attachment"}\n{"path":"%s/att-01-a.bin","step":"add_attachment"}\n' "$named" "$decoy" >"$parent.script"
  DRY_RUN_TEMP_DIRS=()
  collect_dry_run_temp_dirs "$parent.script" "$parent.before" 2>/dev/null
  DRY_RUN_TEMP_DIRS+=("$outside")
  remove_dry_run_temp_dirs
  local state
  state="decoy:$([[ -d $decoy ]] && echo kept || echo deleted) named:$([[ -d $named ]] && echo kept || echo deleted) unnamed:$([[ -d $unnamed ]] && echo kept || echo deleted) empty:$([[ -d $empty ]] && echo kept || echo deleted) outside:$([[ -d $outside ]] && echo kept || echo deleted)"
  self_test_expect "decoy:kept named:deleted unnamed:kept empty:deleted outside:kept" "only this dry run's named or empty new dirs are deleted" "$state"

  define_scenario html-send
  local next_tmp="$workdir/dry-run-tmp/${NAME}.$((DRY_RUN_COUNTER + 1))"
  local preexisting="$next_tmp/sendmail-9-EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
  mkdir -p "$preexisting"
  GUARD_REASONS=()
  dry_run_scenario >/dev/null 2>&1 || true
  state="preexisting:$([[ -d $preexisting ]] && echo kept || echo deleted) created:$(list_binary_temp_dirs "$next_tmp" | grep -cvxF "$preexisting" || true)"
  self_test_expect "preexisting:kept created:0" "real dry run removes only the dir it created" "$state"
}

# Each rule in dry-run.sb is checked three ways: it is present in the
# profile, a profile holding only that rule blocks its probe (so the rule
# itself works), and the full profile blocks the probe too. Deleting a rule
# from dry-run.sb therefore fails the self-test.
self_test_sandbox() {
  printf 'dry-run sandbox\n'
  local sandbox_temp="$workdir/sandbox-temp" curl_path finder_probe
  mkdir -p "$sandbox_temp"
  curl_path=$(realpath "$(command -v curl)")
  finder_probe='tell application "Finder" to get name of startup disk'
  local perl_path tiocsti_probe
  perl_path=$(realpath "$(command -v perl)")
  # TIOCSTI is _IOW('t', 114, char) = 0x80017472 on macOS.
  # shellcheck disable=SC2016 # Perl code, not shell
  tiocsti_probe='open(my $t, "<", "/dev/tty") or die "open /dev/tty: $!\n"; my $c = "x"; ioctl($t, 0x80017472, $c) or die "TIOCSTI: $!\n"; print "INJECTED\n"'

  if run_bounded 30 /usr/bin/osascript -e "$finder_probe" >"$workdir/logs/finder-control.log" 2>&1; then
    self_test_expect works "unsandboxed control: Apple Event to Finder" works "$(head -n 1 "$workdir/logs/finder-control.log")"
  else
    self_test_expect works "unsandboxed control: Apple Event to Finder" fails "$(tail -n 1 "$workdir/logs/finder-control.log")"
  fi
  if run_bounded 30 "${CURL[@]}" -fsS --max-time 5 "$API/info" >/dev/null 2>&1; then
    self_test_expect works "unsandboxed control: Mailpit API" works
  else
    self_test_expect works "unsandboxed control: Mailpit API" fails
  fi

  sandbox_probe() {
    local profile=$1 probe=$2 log_file=$3 victim status=0
    case $probe in
      appleevent)
        run_bounded 30 /usr/bin/sandbox-exec -f "$profile" -D BINARY=/usr/bin/osascript -D "TEMP_DIR=$sandbox_temp" \
          /usr/bin/osascript -e "$finder_probe" >"$log_file" 2>&1 || status=$?
        ;;
      exec)
        run_bounded 30 /usr/bin/sandbox-exec -f "$profile" -D "BINARY=$SENDMAIL_BIN" -D "TEMP_DIR=$sandbox_temp" \
          /usr/bin/true >"$log_file" 2>&1 || status=$?
        ;;
      network)
        run_bounded 30 /usr/bin/sandbox-exec -f "$profile" -D "BINARY=$curl_path" -D "TEMP_DIR=$sandbox_temp" \
          "$curl_path" -q --noproxy '*' -fsS --max-time 5 "$API/info" >"$log_file" 2>&1 || status=$?
        ;;
      unlink)
        touch "$sandbox_temp/unlink-probe"
        run_bounded 30 /usr/bin/sandbox-exec -f "$profile" -D BINARY=/bin/rm -D "TEMP_DIR=$sandbox_temp" \
          /bin/rm "$sandbox_temp/unlink-probe" >"$log_file" 2>&1 || true
        [[ -e $sandbox_temp/unlink-probe ]] || status=0
        [[ -e $sandbox_temp/unlink-probe ]] && status=1
        rm -f "$sandbox_temp/unlink-probe"
        ;;
      write)
        rm -f "$workdir/write-probe"
        run_bounded 30 /usr/bin/sandbox-exec -f "$profile" -D BINARY=/usr/bin/touch -D "TEMP_DIR=$sandbox_temp" \
          /usr/bin/touch "$workdir/write-probe" >"$log_file" 2>&1 || status=$?
        [[ -e $workdir/write-probe ]] && status=0
        rm -f "$workdir/write-probe"
        ;;
      signal)
        sleep 30 &
        victim=$!
        run_bounded 30 /usr/bin/sandbox-exec -f "$profile" -D BINARY=/bin/kill -D "TEMP_DIR=$sandbox_temp" \
          /bin/kill -TERM "$victim" >"$log_file" 2>&1 || true
        sleep 0.2
        if kill -0 "$victim" 2>/dev/null; then status=1; fi
        kill "$victim" 2>/dev/null || true
        wait "$victim" 2>/dev/null || true
        ;;
      mach)
        run_bounded 30 /usr/bin/sandbox-exec -f "$profile" -D BINARY=/usr/bin/osascript -D "TEMP_DIR=$sandbox_temp" \
          /usr/bin/osascript -e "$finder_probe" >"$log_file" 2>&1 || status=$?
        ;;
      fork)
        run_bounded 30 /usr/bin/sandbox-exec -f "$profile" -D BINARY=/bin/sh -D "TEMP_DIR=$sandbox_temp" \
          /bin/sh -c ': & wait; echo FORKED' >"$log_file" 2>&1 || status=$?
        grep -qx FORKED "$log_file" || status=1
        ;;
      tty)
        # Inside a private pty from script(1): TIOCSTI only reaches that pty.
        run_bounded 30 /usr/bin/script -q "$log_file" /usr/bin/sandbox-exec -f "$profile" -D "BINARY=$perl_path" -D "TEMP_DIR=$sandbox_temp" \
          "$perl_path" -e "$tiocsti_probe" </dev/null >/dev/null 2>&1 || status=$?
        grep -q INJECTED "$log_file" || status=1
        ;;
    esac
    return "$status"
  }

  if run_bounded 30 /usr/bin/script -q "$workdir/logs/tty-control.log" "$perl_path" -e "$tiocsti_probe" </dev/null >/dev/null 2>&1 &&
    grep -q INJECTED "$workdir/logs/tty-control.log"; then
    self_test_expect works "unsandboxed control: TIOCSTI into a private pty" works
  else
    self_test_expect works "unsandboxed control: TIOCSTI into a private pty" fails "$(tr -d '\r' <"$workdir/logs/tty-control.log" | tail -n 1)"
  fi
  if run_bounded 30 /usr/bin/script -q "$workdir/logs/fork-control.log" /bin/sh -c ': & wait; echo FORKED' </dev/null >/dev/null 2>&1 &&
    grep -q FORKED "$workdir/logs/fork-control.log"; then
    self_test_expect works "unsandboxed control: fork" works
  else
    self_test_expect works "unsandboxed control: fork" fails
  fi

  check_rule() {
    local rule=$1 probe=$2 wanted_error=$3 single_profile="$workdir/single-rule.sb" log_file="$workdir/logs/sandbox-$2.log"
    if grep -qxF "$rule" "$SANDBOX_PROFILE"; then
      self_test_expect present "$rule in dry-run.sb" present
    else
      self_test_expect present "$rule in dry-run.sb" missing
    fi
    {
      printf '(version 1)\n(allow default)\n%s\n' "$rule"
      [[ $rule == "(deny process-exec)" ]] && printf '(allow process-exec (literal (param "BINARY")))\n'
      [[ $rule == "(deny file-write*)" ]] && printf '(allow file-write* (subpath (param "TEMP_DIR")) (literal "/dev/null"))\n'
    } >"$single_profile"
    if sandbox_probe "$single_profile" "$probe" "$log_file"; then
      self_test_expect blocked "$rule alone blocks its probe" allowed
    elif [[ -n $wanted_error ]] && ! grep -qE "$wanted_error" "$log_file"; then
      self_test_expect blocked "$rule alone blocks its probe with $wanted_error" "blocked-differently" "$(tail -n 1 "$log_file")"
    else
      self_test_expect blocked "$rule alone blocks its probe" blocked "$(tail -n 1 "$log_file")"
    fi
    if sandbox_probe "$SANDBOX_PROFILE" "$probe" "$log_file.full"; then
      self_test_expect blocked "full profile blocks the $probe probe" allowed
    else
      self_test_expect blocked "full profile blocks the $probe probe" blocked
    fi
  }

  check_rule '(deny appleevent-send)' appleevent '\(-600\)'
  check_rule '(deny mach-lookup)' mach ''
  check_rule '(deny network*)' network ''
  check_rule '(deny process-exec)' exec ''
  check_rule '(deny file-write-unlink)' unlink ''
  check_rule '(deny file-write*)' write ''
  check_rule '(deny signal)' signal ''
  check_rule '(deny process-fork)' fork ''
  check_rule '(deny file-read* file-write* file-ioctl (regex #"^/dev/(tty|pty|ptmx)"))' tty ''
  local rule
  for rule in '(deny lsopen)' '(deny iokit-open)'; do
    if grep -qxF "$rule" "$SANDBOX_PROFILE"; then
      self_test_expect present "$rule in dry-run.sb (no probe)" present
    else
      self_test_expect present "$rule in dry-run.sb (no probe)" missing
    fi
  done

  rm -f "$sandbox_temp/inside-probe"
  if run_bounded 30 "${SANDBOX[@]}" -D BINARY=/usr/bin/touch -D "TEMP_DIR=$sandbox_temp" /usr/bin/touch "$sandbox_temp/inside-probe" 2>/dev/null &&
    [[ -e $sandbox_temp/inside-probe ]]; then
    self_test_expect allowed "full profile still allows writes in TEMP_DIR" allowed
  else
    self_test_expect allowed "full profile still allows writes in TEMP_DIR" blocked
  fi
}

# Starts Mailpits on spare ports to prove the start-up refusals and that a
# relay configured through MP_* variables is neither inherited nor missed.
# shellcheck disable=SC2030,SC2031 # port overrides are meant to stay in their subshells
self_test_mailpit() {
  printf 'Mailpit start-up and relay checks\n'
  local alt_smtp=21025 alt_pop3=21110 alt_http=28025 status

  if (mailpit_pid="" && mailpit_tag=busy && start_mailpit) >"$workdir/logs/busy.log" 2>&1; then
    self_test_expect refused "start with the ports already in use" accepted
  else
    self_test_expect refused "start with the ports already in use" refused "$(tail -n 1 "$workdir/logs/busy.log")"
  fi
  if (SMTP_PORT=$HTTP_PORT && check_mailpit_banners) >/dev/null 2>&1; then
    self_test_expect refused "SMTP banner from a non-SMTP port" accepted
  else
    self_test_expect refused "SMTP banner from a non-SMTP port" refused
  fi
  if (POP3_PORT=$SMTP_PORT && check_mailpit_banners) >/dev/null 2>&1; then
    self_test_expect refused "POP3 banner from the SMTP port" accepted
  else
    self_test_expect refused "POP3 banner from the SMTP port" refused
  fi
  if check_mailpit_banners; then
    self_test_expect accepted "banners of this run's Mailpit" accepted
  else
    self_test_expect accepted "banners of this run's Mailpit" refused "$MAILPIT_REASON"
  fi
  if check_pop3_login e2e-a wrong-password; then
    self_test_expect refused "POP3 login with a wrong password" accepted
  else
    self_test_expect refused "POP3 login with a wrong password" refused "$MAILPIT_REASON"
  fi
  if check_mailpit_not_relaying "$workdir/logs/mailpit.log"; then
    self_test_expect accepted "relay check on this run's Mailpit" accepted
  else
    self_test_expect accepted "relay check on this run's Mailpit" refused "$MAILPIT_REASON"
  fi
  if mailpit_alive; then
    self_test_expect alive "mailpit_alive for this run's Mailpit" alive
  else
    self_test_expect alive "mailpit_alive for this run's Mailpit" dead
  fi
  if (mailpit_pid=999999 && mailpit_alive); then
    self_test_expect dead "mailpit_alive for a pid that does not exist" alive
  else
    self_test_expect dead "mailpit_alive for a pid that does not exist" dead
  fi
  if (mailpit_pid=999999 && live_precheck) >/dev/null 2>&1; then
    self_test_expect refused "live_precheck with Mailpit gone (before any Mail check)" accepted
  else
    self_test_expect refused "live_precheck with Mailpit gone (before any Mail check)" refused
  fi

  # Sinks and controls are started under env -i too, with only the MP_*
  # variables each case needs, so nothing in the caller's environment can
  # make them forward anywhere.
  local relay_sink_smtp=31025 relay_sink_http=38025 forward_sink_smtp=32025 forward_sink_http=38026
  local relay_sink_pid forward_sink_pid
  env -i PATH="$PATH" HOME="$HOME" mailpit --database "$workdir/relay-sink.db" \
    --listen "${MAILPIT_HOST}:${relay_sink_http}" --smtp "${MAILPIT_HOST}:${relay_sink_smtp}" \
    --smtp-disable-rdns --disable-version-check >"$workdir/logs/relay-sink.log" 2>&1 &
  relay_sink_pid=$!
  env -i PATH="$PATH" HOME="$HOME" mailpit --database "$workdir/forward-sink.db" \
    --listen "${MAILPIT_HOST}:${forward_sink_http}" --smtp "${MAILPIT_HOST}:${forward_sink_smtp}" \
    --smtp-disable-rdns --disable-version-check >"$workdir/logs/forward-sink.log" 2>&1 &
  forward_sink_pid=$!

  # The caller's environment for the rest of this test: everything that
  # could make a Mailpit forward, relay, call out or use SpamAssassin.
  local hostile_environment=(
    MP_SMTP_FORWARD_TO=forward-probe@example.test
    MP_SMTP_FORWARD_HOST="$MAILPIT_HOST"
    MP_SMTP_FORWARD_PORT="$forward_sink_smtp"
    MP_SMTP_RELAY_HOST="$MAILPIT_HOST"
    MP_SMTP_RELAY_PORT="$relay_sink_smtp"
    MP_SMTP_RELAY_ALL=true
    MP_WEBHOOK_URL="http://${MAILPIT_HOST}:${forward_sink_http}/webhook"
    MP_ENABLE_SPAMASSASSIN="${MAILPIT_HOST}:1"
  )

  wait_for_api() {
    local port attempt
    for attempt in $(seq 1 50); do
      for port in "$@"; do
        "${CURL[@]}" -fsS --max-time 1 "http://${MAILPIT_HOST}:${port}/api/v1/info" >/dev/null 2>&1 || continue 2
      done
      return 0
    done
    return 1
  }
  count_at() {
    "${CURL[@]}" -fsS --max-time 5 "http://${MAILPIT_HOST}:$1/api/v1/messages" | jq -r '.total // -1'
  }
  wait_for_count() {
    local port=$1 wanted=$2 attempt count
    for attempt in $(seq 1 20); do
      count=$(count_at "$port")
      [[ $count == "$wanted" ]] && break
      sleep 0.25
    done
    printf '%s\n' "$count"
  }
  check_alt_mailpit() {
    HTTP_PORT=$alt_http
    API="http://${MAILPIT_HOST}:${alt_http}/api/v1"
    check_mailpit_not_relaying "$1" || {
      printf '%s\n' "$MAILPIT_REASON"
      return 1
    }
  }
  local probe_message="$workdir/relay-probe.eml"
  printf 'From: e2e-a@example.test\nTo: relay-probe@example.test\nSubject: relay probe\n\nbody\n' >"$probe_message"
  printf 'e2e-a:%s\n' "$POP3_PASSWORD" >"$workdir/control-pop3-auth"
  wait_for_api "$relay_sink_http" "$forward_sink_http" || true

  # Control: a Mailpit given only the relay variables, launched from the
  # hostile environment. It must fail the check and really relay, while the
  # forward variables in its caller's environment must not reach it.
  local relay_log="$workdir/logs/relay-control.log" relay_pid
  env "${hostile_environment[@]}" env -i PATH="$PATH" HOME="$HOME" \
    MP_SMTP_RELAY_HOST="$MAILPIT_HOST" MP_SMTP_RELAY_PORT="$relay_sink_smtp" MP_SMTP_RELAY_ALL=true \
    mailpit --database "$workdir/relay-control.db" \
    --listen "${MAILPIT_HOST}:${alt_http}" --smtp "${MAILPIT_HOST}:${alt_smtp}" \
    --pop3 "${MAILPIT_HOST}:${alt_pop3}" --pop3-auth-file "$workdir/control-pop3-auth" \
    --smtp-disable-rdns --disable-version-check >"$relay_log" 2>&1 &
  relay_pid=$!
  wait_for_api "$alt_http" || true
  if (check_alt_mailpit "$relay_log") >"$workdir/logs/relay-check.log" 2>&1; then
    self_test_expect refused "control: Mailpit given MP_SMTP_RELAY_* fails the relay check" accepted
  else
    self_test_expect refused "control: Mailpit given MP_SMTP_RELAY_* fails the relay check" refused "$(tail -n 1 "$workdir/logs/relay-check.log")"
  fi
  (SMTP_PORT=$alt_smtp && inject "$probe_message" e2e-a@example.test relay-probe@example.test) >/dev/null 2>&1 || true
  self_test_expect 1 "control: it really relays (messages at the relay sink)" "$(wait_for_count "$relay_sink_http" 1)"
  sleep 1
  self_test_expect 0 "control: caller's MP_SMTP_FORWARD_* not inherited (messages at the forward sink)" "$(count_at "$forward_sink_http")"
  kill "$relay_pid" 2>/dev/null || true
  wait "$relay_pid" 2>/dev/null || true
  "${CURL[@]}" -fsS --max-time 5 -X DELETE "http://${MAILPIT_HOST}:${relay_sink_http}/api/v1/messages" >/dev/null || true

  # Control: a Mailpit given only MP_ENABLE_SPAMASSASSIN must fail the check.
  local spam_log="$workdir/logs/spamassassin-control.log" spam_pid
  env -i PATH="$PATH" HOME="$HOME" MP_ENABLE_SPAMASSASSIN="${MAILPIT_HOST}:1" \
    mailpit --database "$workdir/spam-control.db" \
    --listen "${MAILPIT_HOST}:${alt_http}" --smtp "${MAILPIT_HOST}:${alt_smtp}" \
    --smtp-disable-rdns --disable-version-check >"$spam_log" 2>&1 &
  spam_pid=$!
  wait_for_api "$alt_http" || true
  if (check_alt_mailpit "$spam_log") >"$workdir/logs/spam-check.log" 2>&1; then
    self_test_expect refused "control: Mailpit given MP_ENABLE_SPAMASSASSIN fails the check" accepted
  else
    self_test_expect refused "control: Mailpit given MP_ENABLE_SPAMASSASSIN fails the check" refused "$(tail -n 1 "$workdir/logs/spam-check.log")"
  fi
  kill "$spam_pid" 2>/dev/null || true
  wait "$spam_pid" 2>/dev/null || true

  # Positive control for the forward sink: a Mailpit explicitly given
  # MP_SMTP_FORWARD_* must fail the check and really forward, so the 0 counts
  # elsewhere mean "not forwarded", not "sink broken".
  local forward_log="$workdir/logs/forward-control.log" forward_pid
  env -i PATH="$PATH" HOME="$HOME" MP_SMTP_FORWARD_TO=forward-probe@example.test \
    MP_SMTP_FORWARD_HOST="$MAILPIT_HOST" MP_SMTP_FORWARD_PORT="$forward_sink_smtp" \
    mailpit --database "$workdir/forward-control.db" \
    --listen "${MAILPIT_HOST}:${alt_http}" --smtp "${MAILPIT_HOST}:${alt_smtp}" \
    --smtp-disable-rdns --disable-version-check >"$forward_log" 2>&1 &
  forward_pid=$!
  wait_for_api "$alt_http" || true
  if (check_alt_mailpit "$forward_log") >"$workdir/logs/forward-check.log" 2>&1; then
    self_test_expect refused "control: Mailpit given MP_SMTP_FORWARD_* fails the check" accepted
  else
    self_test_expect refused "control: Mailpit given MP_SMTP_FORWARD_* fails the check" refused "$(tail -n 1 "$workdir/logs/forward-check.log")"
  fi
  (SMTP_PORT=$alt_smtp && inject "$probe_message" e2e-a@example.test relay-probe@example.test) >/dev/null 2>&1 || true
  self_test_expect 1 "control: it really forwards (messages at the forward sink)" "$(wait_for_count "$forward_sink_http" 1)"
  kill "$forward_pid" 2>/dev/null || true
  wait "$forward_pid" 2>/dev/null || true
  "${CURL[@]}" -fsS --max-time 5 -X DELETE "http://${MAILPIT_HOST}:${forward_sink_http}/api/v1/messages" >/dev/null || true

  # Under test: the harness's own start-up, launched from the hostile
  # environment, must come up clean and send nothing to either sink.
  status=0
  (
    export "${hostile_environment[@]}"
    SMTP_PORT=$alt_smtp
    POP3_PORT=$alt_pop3
    POP3_B_PORT=21111
    HTTP_PORT=$alt_http
    API="http://${MAILPIT_HOST}:${alt_http}/api/v1"
    forwarder_pid=""
    mailpit_pid=""
    mailpit_tag=relay-under-test
    trap 'stop_mailpit' EXIT
    start_mailpit
    inject "$probe_message" e2e-a@example.test relay-probe@example.test >/dev/null
    sleep 2
  ) >"$workdir/logs/relay-under-test.out" 2>&1 || status=$?
  if ((status == 0)); then
    self_test_expect started "harness start with MP_SMTP_RELAY/FORWARD, WEBHOOK, SPAMASSASSIN set" started "$(grep -F 'relay off' "$workdir/logs/relay-under-test.out" | tail -n 1)"
  else
    self_test_expect started "harness start with MP_SMTP_RELAY/FORWARD, WEBHOOK, SPAMASSASSIN set" "refused($status)" "$(tail -n 1 "$workdir/logs/relay-under-test.out")"
  fi
  self_test_expect 0 "harness-started Mailpit relayed nothing (relay sink)" "$(count_at "$relay_sink_http")"
  self_test_expect 0 "harness-started Mailpit forwarded nothing (forward sink)" "$(count_at "$forward_sink_http")"

  kill "$relay_sink_pid" "$forward_sink_pid" 2>/dev/null || true
  wait "$relay_sink_pid" "$forward_sink_pid" 2>/dev/null || true
}


# e2e-b's POP3 port is a socat forwarder started and stopped with Mailpit.
# shellcheck disable=SC2030,SC2031 # port overrides are meant to stay in their subshells
self_test_forwarder() {
  printf 'POP3 forwarder for e2e-b\n'
  expect_outcome mailpit "POP3 banner through ${POP3_B_PORT}" mailpit other check_pop3_banner "$POP3_B_PORT"
  expect_outcome ok "POP3 login as e2e-b through ${POP3_B_PORT}" ok refused check_pop3_login e2e-b "$POP3_PASSWORD" "$POP3_B_PORT"
  expect_outcome refused "POP3 login with a wrong password through ${POP3_B_PORT}" ok refused check_pop3_login e2e-b wrong-password "$POP3_B_PORT"
  local listeners
  local process_table forwarder_child lsof_output=""
  process_table=$(/bin/ps -Ao pid=,ppid=) || process_table=""
  forwarder_child=$(awk -v parent="$forwarder_pid" '$2 == parent { print $1 }' <<<"$process_table" | sed -n '1p')
  if [[ -n $forwarder_child ]]; then
    lsof_output=$(/usr/sbin/lsof -nP -a -p "$forwarder_child" -iTCP -sTCP:LISTEN 2>/dev/null) || lsof_output=""
  fi
  listeners=$(awk 'NR > 1 { print $9 }' <<<"$lsof_output" | sort -u | paste -sd, -)
  self_test_expect "${MAILPIT_HOST}:${POP3_B_PORT}" "forwarder listens on 127.0.0.1 only" "${listeners:-none}"
  expect_outcome alive "mailpit_alive needs the forwarder too (both up)" alive dead mailpit_alive
  if (forwarder_pid=999999 && mailpit_alive); then
    self_test_expect dead "mailpit_alive with the forwarder gone" alive
  else
    self_test_expect dead "mailpit_alive with the forwarder gone" dead
  fi

  local status=0
  (
    SMTP_PORT=21025
    POP3_PORT=21110
    POP3_B_PORT=21111
    HTTP_PORT=28025
    API="http://${MAILPIT_HOST}:${HTTP_PORT}/api/v1"
    mailpit_pid=""
    forwarder_pid=""
    mailpit_tag=forwarder-test
    start_mailpit
    check_pop3_banner 21111 || exit 3
    stop_mailpit
    sleep 0.5
    port_in_use 21111 && exit 4
    port_in_use 21110 && exit 5
    exit 0
  ) >"$workdir/logs/forwarder-start-stop.log" 2>&1 || status=$?
  case $status in
    0) self_test_expect stopped "start_mailpit starts the forwarder; stop_mailpit stops it and Mailpit" stopped ;;
    3) self_test_expect stopped "start_mailpit starts the forwarder; stop_mailpit stops it and Mailpit" "no-banner-on-21111" ;;
    4) self_test_expect stopped "start_mailpit starts the forwarder; stop_mailpit stops it and Mailpit" "21111-still-listening" ;;
    5) self_test_expect stopped "start_mailpit starts the forwarder; stop_mailpit stops it and Mailpit" "21110-still-listening" ;;
    *) self_test_expect stopped "start_mailpit starts the forwarder; stop_mailpit stops it and Mailpit" "failed($status)" "$(tail -n 1 "$workdir/logs/forwarder-start-stop.log")" ;;
  esac

  # This run's own forwarder already holds POP3_B_PORT.
  if (
    SMTP_PORT=21025 POP3_PORT=21110 HTTP_PORT=28025
    API="http://${MAILPIT_HOST}:28025/api/v1"
    mailpit_pid="" forwarder_pid="" mailpit_tag=forwarder-busy
    trap 'stop_mailpit' EXIT
    start_mailpit
  ) >"$workdir/logs/forwarder-busy.log" 2>&1; then
    self_test_expect refused "start with e2e-b's POP3 port already in use" accepted
  else
    self_test_expect refused "start with e2e-b's POP3 port already in use" refused "$(tail -n 1 "$workdir/logs/forwarder-busy.log")"
  fi
}

# The exit status: success only if every selected scenario passed (or, with
# --allow-refused, passed or was refused by a guard).
self_test_summary() {
  printf 'run summary and exit status\n'
  summary_case() {
    local label=$1 wanted=$2 allow=$3
    shift 3
    local status=0
    (
      allow_refused=$allow
      selected=()
      RESULT=()
      local entry
      for entry in "$@"; do
        selected+=("${entry%%=*}")
        RESULT[${entry%%=*}]=${entry#*=}
      done
      print_summary >/dev/null
    ) || status=$?
    if ((status == 0)); then
      self_test_expect "$wanted" "$label" success
    else
      self_test_expect "$wanted" "$label" failure
    fi
  }
  summary_case "all passed" success false plain-send=PASS html-send=PASS
  summary_case "one refused by a guard" failure false plain-send=PASS from-header-account-plain=REFUSED
  summary_case "one refused, --allow-refused" success true plain-send=PASS from-header-account-plain=REFUSED
  summary_case "one aborted, --allow-refused" failure true plain-send=PASS html-send=ABORTED
  summary_case "one skipped (no e2e-b)" failure true plain-send=PASS from-header-account-plain=SKIP
  summary_case "one failed" failure true plain-send=FAIL html-send=PASS
  summary_case "one never recorded" failure true plain-send=PASS html-send=

  # vm.sh's approval_pass_passed reads the summary with these patterns.
  local summary_text outcome=unreadable
  summary_text=$(
    allow_refused=false
    selected=(plain-send html-send)
    RESULT=([plain-send]=PASS [html-send]=PASS)
    print_summary
  )
  if grep -q '^RESULT: success' <<<"$summary_text" &&
    grep -Eq '^plain-send[[:space:]]+PASS([[:space:]]|$)' <<<"$summary_text" &&
    grep -Eq '^html-send[[:space:]]+PASS([[:space:]]|$)' <<<"$summary_text"; then
    outcome=readable
  fi
  self_test_expect readable "all passed: rows and RESULT line as vm.sh reads them" "$outcome"
  outcome=unreadable
  summary_text=$(
    allow_refused=false
    selected=(plain-send html-send)
    RESULT=([plain-send]=PASS [html-send]=FAIL)
    print_summary
  ) || true
  if grep -Eq '^html-send[[:space:]]+FAIL$' <<<"$summary_text" &&
    ! grep -Eq '^html-send[[:space:]]+PASS([[:space:]]|$)' <<<"$summary_text"; then
    outcome=readable
  fi
  self_test_expect readable "one failed: its row is not read as a PASS" "$outcome"
  outcome=unreadable
  summary_text=$(
    allow_refused=false
    selected=(plain-send plain-send-no-ui)
    RESULT=([plain-send]=FAIL [plain-send-no-ui]=PASS)
    print_summary
  ) || true
  if ! grep -Eq '^plain-send[[:space:]]+PASS([[:space:]]|$)' <<<"$summary_text" &&
    grep -Eq '^plain-send-no-ui[[:space:]]+PASS([[:space:]]|$)' <<<"$summary_text"; then
    outcome=readable
  fi
  self_test_expect readable "plain-send-no-ui's PASS is not read as plain-send's" "$outcome"
}

# Exercises run_supervised directly, with a `sleep` standing in for the
# harness as the watched parent, and a Mailpit on spare ports as the child.
# shellcheck disable=SC2030,SC2031 # port overrides are meant to stay in their subshells
self_test_watchdog() {
  printf 'Mailpit watchdog\n'
  local alt_smtp=21025 alt_http=28025 watchdog stand_in_parent case_name

  alt_api_up() {
    "${CURL[@]}" -fsS --max-time 1 "http://${MAILPIT_HOST}:${alt_http}/api/v1/info" >/dev/null 2>&1
  }
  wait_alt_api() {
    local wanted=$1 attempt
    for attempt in $(seq 1 60); do
      if alt_api_up; then [[ $wanted == up ]] && return 0; else [[ $wanted == down ]] && return 0; fi
      sleep 0.1
    done
    return 1
  }
  start_watched() {
    run_supervised "$1" env -i PATH="$PATH" HOME="$HOME" mailpit --database "$workdir/watchdog-$2.db" \
      --listen "${MAILPIT_HOST}:${alt_http}" --smtp "${MAILPIT_HOST}:${alt_smtp}" \
      --smtp-disable-rdns --disable-version-check >"$workdir/logs/watchdog-$2.log" 2>&1 &
    watchdog=$!
  }
  kill_orphans() {
    local pid
    while read -r pid; do
      [[ -n $pid ]] && kill "$pid" 2>/dev/null
    done < <(/bin/ps -Ao pid=,args= | grep -F "$workdir/watchdog-" | grep -v grep | awk '{print $1}')
    return 0
  }

  sleep 300 &
  stand_in_parent=$!
  start_watched "$stand_in_parent" term
  wait_alt_api up || true
  self_test_expect perl "\$! of the backgrounded run_supervised is the watchdog" "$(/bin/ps -o comm= -p "$watchdog" | sed 's#.*/##')"
  kill -TERM "$watchdog"
  wait "$watchdog" 2>/dev/null || true
  expect_outcome stopped "SIGTERM to the watchdog stops Mailpit" stopped running wait_alt_api down

  start_watched "$stand_in_parent" parent-killed
  wait_alt_api up || true
  kill -KILL "$stand_in_parent"
  wait "$stand_in_parent" 2>/dev/null || true
  expect_outcome stopped "watched parent SIGKILLed: watchdog stops Mailpit" stopped running wait_alt_api down
  wait "$watchdog" 2>/dev/null || true

  sleep 300 &
  stand_in_parent=$!
  start_watched "$stand_in_parent" detached
  wait_alt_api up || true
  kill -USR1 "$watchdog"
  sleep 0.5
  kill -KILL "$stand_in_parent"
  wait "$stand_in_parent" 2>/dev/null || true
  sleep 3
  expect_outcome survives "after SIGUSR1, Mailpit outlives its watched parent" survives stopped alt_api_up
  kill -TERM "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  expect_outcome stopped "a detached watchdog still stops Mailpit on SIGTERM" stopped running wait_alt_api down

  # SIGTERM as early as possible, possibly between the watchdog's fork and
  # its handler set-up: Mailpit must never be left running on its own.
  local orphans=0 delay
  sleep 300 &
  stand_in_parent=$!
  for delay in 0 0 0.005 0.01 0.02 0.05 0.1 0.2; do
    case_name="early-term-$delay-$RANDOM"
    start_watched "$stand_in_parent" "$case_name"
    sleep "$delay"
    kill -TERM "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    sleep 1.5
    local process_args
    process_args=$(/bin/ps -Ao args=) || process_args="ps failed: assume orphaned $workdir/watchdog-$case_name.db"
    if alt_api_up || awk -v needle="$workdir/watchdog-$case_name.db" 'index($0, needle) && !/grep|awk/ { found = 1 } END { exit !found }' <<<"$process_args"; then
      orphans=$((orphans + 1))
      kill_orphans
      wait_alt_api down || true
    fi
  done
  self_test_expect 0 "Mailpits orphaned by an early SIGTERM (8 tries)" "$orphans"
  kill "$stand_in_parent" 2>/dev/null || true
  wait "$stand_in_parent" 2>/dev/null || true
  kill_orphans
}

# A preflight that refuses (here: every Mail read times out) must fail fast
# and stop Mailpit: no Outbox drain, no stuck-message warning, no detached
# Mailpit. Runs the real start_mailpit, run_preflight and cleanup in a
# subshell with its own work dir, spare ports and stubbed Mail reads.
# shellcheck disable=SC2030,SC2031,SC2329 # subshell-local overrides and stubs
self_test_preflight_refusal() {
  printf 'preflight refusal (Mail reads stubbed)\n'
  local started elapsed status=0 output
  started=$SECONDS
  output=$(
    exec 2>&1
    workdir=$(realpath "$(mktemp -d "${TMPDIR:-/tmp}/apple-mail-sendmail-e2e-refusal.XXXXXX")")
    mkdir -p "$workdir/logs"
    keep_workdir=false
    mail_touched=false
    mailpit_pid=""
    mailpit_tag=refusal
    DRY_RUN_TEMP_DIRS=()
    SMTP_PORT=21025
    POP3_PORT=21110
    POP3_B_PORT=21111
    HTTP_PORT=28025
    API="http://${MAILPIT_HOST}:${HTTP_PORT}/api/v1"
    forwarder_pid=""
    mail_is_running() { return 0; }
    run_bounded() { return 124; }
    trap cleanup EXIT
    start_mailpit
    run_preflight
  ) || status=$?
  elapsed=$((SECONDS - started))
  printf '%s\n' "$output" >"$workdir/logs/preflight-refusal.log"
  self_test_expect 2 "refused preflight exit status" "$status"
  expect_outcome fast "refused preflight returns without the 60s drain (${elapsed}s)" fast slow test "$elapsed" -le 15
  if grep -q 'account preflight failed' <<<"$output"; then
    self_test_expect refused "refusal names the failed preflight" refused
  else
    self_test_expect refused "refusal names the failed preflight" other "$(tail -n 1 <<<"$output")"
  fi
  if grep -qE 'WARNING|left Mailpit running' <<<"$output"; then
    self_test_expect none "stuck-message warning or detached Mailpit" present "$(grep -E 'WARNING|left Mailpit running' <<<"$output" | sed -n '1p')"
  else
    self_test_expect none "stuck-message warning or detached Mailpit" none
  fi
  if "${CURL[@]}" -fsS --max-time 1 "http://${MAILPIT_HOST}:28025/api/v1/info" >/dev/null 2>&1; then
    self_test_expect stopped "Mailpit after the refusal" running
  else
    self_test_expect stopped "Mailpit after the refusal" stopped
  fi
}

self_test_live_helpers() {
  printf 'live-run helpers (no Mail)\n'
  define_scenario draft-later-plain-attachment
  clear_mailpit
  if draft_already_delivered; then
    self_test_expect no "draft not yet delivered" yes
  else
    self_test_expect no "draft not yet delivered" no
  fi
  inject_variant correct
  if draft_already_delivered; then
    self_test_expect yes "draft delivered without --send is detected" yes
  else
    self_test_expect yes "draft delivered without --send is detected" no
  fi

  local saved_ready=$ACCOUNT_B_READY
  SCENARIO_SENDER[__probe]=$ACCOUNT_B
  ACCOUNT_B_READY=false
  expect_outcome skip "e2e-b scenario without the e2e-b account" skip run needs_missing_account_b __probe
  ACCOUNT_B_READY=true
  expect_outcome run "e2e-b scenario with the e2e-b account" skip run needs_missing_account_b __probe
  SCENARIO_SENDER[__probe]=$ACCOUNT_A
  ACCOUNT_B_READY=false
  expect_outcome run "e2e-a scenario without the e2e-b account" skip run needs_missing_account_b __probe
  ACCOUNT_B_READY=$saved_ready
  unset 'SCENARIO_SENDER[__probe]'

  define_scenario plain-send
  cp "$FIXTURE" "$(checked_fixture __probe)"
  FIXTURE_SHA256[__probe]=$(sha256sum "$(checked_fixture __probe)" | cut -d' ' -f1)
  expect_outcome same "checked fixture unchanged" same changed fixture_unchanged __probe
  printf 'Bcc: x@example.test\n' >>"$(checked_fixture __probe)"
  expect_outcome changed "checked fixture edited after the check" same changed fixture_unchanged __probe
  rm -f "$(checked_fixture __probe)"
  unset 'FIXTURE_SHA256[__probe]'

  expect_outcome same "binary copy unchanged" same changed binary_unchanged
  local saved_binary=$SENDMAIL_BIN
  # shellcheck disable=SC2031 # the subshell in self_test_preflight_refusal has its own workdir
  SENDMAIL_BIN="$workdir/tampered-binary"
  cp "$saved_binary" "$SENDMAIL_BIN"
  chmod u+w "$SENDMAIL_BIN"
  printf 'x' >>"$SENDMAIL_BIN"
  expect_outcome changed "binary edited after the check" same changed binary_unchanged
  SENDMAIL_BIN=$saved_binary

  self_test_outbox_drain
}

# The Outbox drain and final report with Mail's state reads stubbed: no
# osascript runs here.
self_test_outbox_drain() {
  printf 'Outbox drain (Mail reads stubbed)\n'
  local saved_run_bounded saved_mail_is_running report
  saved_run_bounded=$(declare -f run_bounded)
  saved_mail_is_running=$(declare -f mail_is_running)
  # shellcheck disable=SC2329 # invoked by read_mail_state
  mail_is_running() { return 0; }

  # shellcheck disable=SC2329 # invoked by read_mail_state
  run_bounded() { return 124; }
  MAIL_OUTBOX_COUNT=0
  read_mail_state >/dev/null 2>&1 || true
  self_test_expect unknown "failed Mail read leaves no stale Outbox count" "$MAIL_OUTBOX_COUNT"
  expect_outcome not-empty "drain with Mail unreadable" empty not-empty wait_for_outbox_empty 2
  report=$(final_mail_report true 2>&1)
  if grep -q 'WARNING: could not confirm' <<<"$report" && grep -q 'Mailpit is left running' <<<"$report"; then
    self_test_expect warned "final report when the drain could not confirm" warned
  else
    self_test_expect warned "final report when the drain could not confirm" silent "$report"
  fi

  # shellcheck disable=SC2329 # invoked by read_mail_state
  run_bounded() { printf '0\n3\n0\n'; }
  expect_outcome not-empty "drain with 3 messages stuck in the Outbox" empty not-empty wait_for_outbox_empty 2

  # shellcheck disable=SC2329 # invoked by read_mail_state
  run_bounded() { printf '0\n0\n0\n'; }
  expect_outcome empty "drain with an empty Outbox" empty not-empty wait_for_outbox_empty 2

  eval "$saved_run_bounded"
  eval "$saved_mail_is_running"
}

# Cases are written tab-separated for readability and converted to the
# ASCII 31 separator the AppleScripts emit.
run_preflight_case() {
  local label=$1 wanted=$2 want_b=$3
  shift 3
  if validate_accounts < <(printf '%s\n' "$@" | tr '\t' '\037'); then
    self_test_expect "$wanted" "$label" accepted
    [[ -z $want_b ]] || self_test_expect "$want_b" "$label: e2e-b ready" "$ACCOUNT_B_READY"
  else
    self_test_expect "$wanted" "$label" refused "${PREFLIGHT_REASONS[@]}"
  fi
}

run_windows_case() {
  local label=$1 wanted=$2 report=$3
  if validate_mail_windows < <(printf '%s' "$report" | tr '\t' '\037'); then
    self_test_expect "$wanted" "$label" accepted
  else
    self_test_expect "$wanted" "$label" refused "${PREFLIGHT_REASONS[@]}"
  fi
}

self_test_preflight() {
  printf 'account, SMTP server and rule preflight parser\n'
  local good_a good_b good_smtp
  good_a=$'account\tE2E A\ttrue\te2e-a@example.test\t127.0.0.1\t1110\t127.0.0.1\t1025\tnever'
  good_b=$'account\tE2E B\ttrue\te2e-b@example.test\t127.0.0.1\t1111\te2e-b-smtp.test\t1025\t7'
  good_smtp=$'smtp\t127.0.0.1:e2e-a\ttrue\t127.0.0.1\t1025'

  run_preflight_case "both e2e accounts" accepted true "$good_a" "$good_b" "$good_smtp"
  run_preflight_case "only e2e-a" accepted false "$good_a"
  run_preflight_case "no accounts" refused "" ""
  run_preflight_case "only e2e-b" refused "" "$good_b"
  run_preflight_case "e2e-a on localhost instead of 127.0.0.1" refused "" \
    $'account\tE2E A\ttrue\te2e-a@example.test\tlocalhost\t1110\tlocalhost\t1025\tnever'
  run_preflight_case "e2e-a points at a real server" refused "" \
    $'account\tE2E A\ttrue\te2e-a@example.test\tpop.mail.example.net\t995\tsmtp.mail.example.net\t465\tnever'
  run_preflight_case "e2e-a with real SMTP" refused "" \
    $'account\tE2E A\ttrue\te2e-a@example.test\t127.0.0.1\t1110\tsmtp.gmail.com\t587\tnever'
  run_preflight_case "e2e-a with no SMTP server" refused "" \
    $'account\tE2E A\ttrue\te2e-a@example.test\t127.0.0.1\t1110\t\t\tnever'
  run_preflight_case "e2e-a disabled" refused "" \
    $'account\tE2E A\tfalse\te2e-a@example.test\t127.0.0.1\t1110\t127.0.0.1\t1025\tnever'
  run_preflight_case "e2e-a enabled = missing value" refused "" \
    $'account\tE2E A\tmissing value\te2e-a@example.test\t127.0.0.1\t1110\t127.0.0.1\t1025\tnever'
  run_preflight_case "e2e-a mixed with a real address" refused "" \
    $'account\tE2E A\ttrue\te2e-a@example.test,someone@example.net\t127.0.0.1\t1110\t127.0.0.1\t1025\tnever'
  run_preflight_case "e2e-a deletes POP copies right away" refused "" \
    $'account\tE2E A\ttrue\te2e-a@example.test\t127.0.0.1\t1110\t127.0.0.1\t1025\t0'
  run_preflight_case "e2e-a POP deletion unreadable" refused "" \
    $'account\tE2E A\ttrue\te2e-a@example.test\t127.0.0.1\t1110\t127.0.0.1\t1025\t'
  run_preflight_case "enabled real account alongside" refused "" "$good_a" \
    $'account\tiCloud\ttrue\tme@icloud.com\tp01-imap.mail.me.com\t993\tp01-smtp.mail.me.com\t587\t'
  run_preflight_case "real account with enabled = missing value" refused "" "$good_a" \
    $'account\tWork\tmissing value\tme@corp.example.com\t\t\t\t\t'
  run_preflight_case "real account with empty server fields" refused "" "$good_a" \
    $'account\tWork\ttrue\tme@corp.example.com\t\t\t\t\t'
  run_preflight_case "disabled real account alongside, with its SMTP server" refused "" "$good_a" \
    $'account\tiCloud\tfalse\tme@icloud.com\tp01-imap.mail.me.com\t993\tp01-smtp.mail.me.com\t587\t' \
    $'smtp\tp01-smtp.mail.me.com:me\tfalse\tp01-smtp.mail.me.com\t587'
  run_preflight_case "disabled account record with no SMTP server listed" accepted false "$good_a" \
    $'account\tOld\tfalse\told@corp.example.com\t\t\t\t\t'
  run_preflight_case "SMTP server on 127.0.0.1 at another port (local relay)" refused "" "$good_a" \
    $'smtp\t127.0.0.1:bridge\ttrue\t127.0.0.1\t2525'
  run_preflight_case "account with an empty name" refused "" "$good_a" \
    $'account\t\ttrue\tme@icloud.com\th\t1\th\t1\t'
  run_preflight_case "newline inside an account name" refused "" "$good_a" \
    $'account\tWork\nAccount\ttrue\tme@corp.example.com\th\t1\th\t1\t'
  run_preflight_case "record with too few fields" refused "" "$good_a" \
    $'account\tWork\ttrue\tme@corp.example.com'
  run_preflight_case "record with too many fields" refused "" "$good_a" \
    $'account\tWork\tfalse\tme@corp.example.com\th\t1\th\t1\t\textra'
  run_preflight_case "record of an unknown type" refused "" "$good_a" $'mailbox\tInbox\ttrue'
  run_preflight_case "record with no type" refused "" "$good_a" \
    $'Work\tfalse\tme@corp.example.com\th\t1\th\t1\tnever'
  run_preflight_case "whitespace-only line" refused "" "$good_a" '   '
  run_preflight_case "e2e-b misconfigured, e2e-a fine" refused "" "$good_a" \
    $'account\tE2E B\ttrue\te2e-b@example.test\t127.0.0.1\t110\t127.0.0.1\t1025\tnever'
  run_preflight_case "e2e-b on e2e-a's POP port 1110" refused "" "$good_a" \
    $'account\tE2E B\ttrue\te2e-b@example.test\t127.0.0.1\t1110\t127.0.0.1\t1025\tnever'
  run_preflight_case "e2e-a on e2e-b's POP port 1111" refused "" \
    $'account\tE2E A\ttrue\te2e-a@example.test\t127.0.0.1\t1111\t127.0.0.1\t1025\tnever'
  run_preflight_case "e2e-b on POP 1111 via localhost" refused "" "$good_a" \
    $'account\tE2E B\ttrue\te2e-b@example.test\tlocalhost\t1111\t127.0.0.1\t1025\tnever'
  run_preflight_case "disabled SMTP server pointing at Gmail" refused "" "$good_a" \
    $'smtp\tsmtp.gmail.com:me\tfalse\tsmtp.gmail.com\t587'
  run_preflight_case "SMTP server on localhost" refused "" "$good_a" \
    $'smtp\tlocal\ttrue\tlocalhost\t1025'
  run_preflight_case "SMTP server with an unreadable host" refused "" "$good_a" \
    $'smtp\t?\t?\t?\t?'
  run_preflight_case "disabled rule" accepted false "$good_a" $'rule\tNews From Apple\tfalse'
  run_preflight_case "enabled rule" refused "" "$good_a" $'rule\tNews From Apple\ttrue'
  run_preflight_case "rule with an unreadable state" refused "" "$good_a" $'rule\tSort\t?'
  run_preflight_case "rule record with too many fields" refused "" "$good_a" $'rule\tSort\tfalse\textra'

  if validate_accounts < <(printf '%s\n' "$good_a"); then
    self_test_expect refused "report without the ASCII 31 separator" accepted
  else
    self_test_expect refused "report without the ASCII 31 separator" refused "${PREFLIGHT_REASONS[@]}"
  fi

  printf 'Mail state parser (windows, Outbox, selection)\n'
  run_windows_case "nothing open, queued or selected" accepted $'0\n0\n0\n'
  run_windows_case "no trailing newline" accepted $'0\n0\n0'
  run_windows_case "a stale outgoing message (Mail keeps sent ones listed)" accepted $'1\n0\n0\n'
  run_windows_case "unreadable outgoing count with no window" accepted $'?\n0\n0\n'
  run_windows_case "outgoing message with its compose window open" refused $'1\n0\n0\n4242\tsubject\n'
  run_windows_case "a message in the Outbox" refused $'0\n2\n0\n'
  run_windows_case "a message selected in the viewer" refused $'0\n0\n1\n'
  run_windows_case "unreadable Outbox" refused $'0\n?\n0\n'
  run_windows_case "unreadable selection" refused $'0\n0\n?\n'
  run_windows_case "missing selection line" refused $'0\n0\n'
  run_windows_case "empty report" refused ''
  run_windows_case "non-numeric outgoing count (not checked)" accepted $'missing value\n0\n0\n'
  run_windows_case "non-numeric Outbox count" refused $'0\nmissing value\n0\n'
  run_windows_case "a compose window is open" refused $'0\n0\n0\n4242\tHello\n'
}

# Display names: exact, apart from Mail's quotes-inside-the-encoded-word
# quirk for names with a special and a non-ASCII character.
# shellcheck disable=SC2031 # the subshell in self_test_preflight_refusal has its own workdir
self_test_display_names() {
  printf 'display-name matching\n'
  name_case() {
    expect_outcome "$1" "$2" accepted rejected display_name_matches "$3" "$4"
  }
  name_case accepted "exact name" 'Bäcker, Anna' 'Bäcker, Anna'
  name_case accepted "Mail quirk: special + non-ASCII, one pair of quotes" 'Bäcker, Anna' '"Bäcker, Anna"'
  name_case rejected "wrong name" 'Bäcker, Anna' 'Backer, Anna'
  name_case rejected "wrong name inside quotes" 'Bäcker, Anna' '"Backer, Anna"'
  name_case rejected "two pairs of quotes" 'Bäcker, Anna' '""Bäcker, Anna""'
  name_case rejected "unbalanced quote" 'Bäcker, Anna' '"Bäcker, Anna'
  name_case rejected "ASCII name with a special, quoted" 'Doe, John' '"Doe, John"'
  name_case rejected "non-ASCII name without a special, quoted" 'Jürgen Müller' '"Jürgen Müller"'
  name_case rejected "empty actual name" 'Bäcker, Anna' ''

  printf 'display-name quirk on the wire (Mailpit)\n'
  define_scenario display-names-html
  local wire="$workdir/fixtures/mail-quirk.wire.eml" encoded recipients=()
  mapfile -t recipients < <(expected_envelope_recipients)
  quirk_wire_case() {
    local label=$1 wanted=$2 quoted_name=$3 actual
    encoded=$(printf '%s' "$quoted_name" | base64 | tr -d '\n')
    write_wire_message "$wire"
    sed -i "s/^From:.*/From: =?utf-8?B?${encoded}?= <${EXPECT_FROM_ADDR}>/" "$wire"
    clear_mailpit
    inject "$wire" "$EXPECT_FROM_ADDR" "${recipients[@]}"
    if check_delivery 2; then actual=PASS; else actual=FAIL; fi
    if [[ $actual == FAIL ]]; then
      self_test_expect "$wanted" "$label" "$actual" "${FAILURES[@]}"
    else
      self_test_expect "$wanted" "$label" "$actual"
    fi
  }
  quirk_wire_case "From: =?utf-8?B?\"Bäcker, Anna\"?= as Mail sends it" PASS '"Bäcker, Anna"'
  quirk_wire_case "From: =?utf-8?B?\"Backer, Anna\"?= (wrong name)" FAIL '"Backer, Anna"'
}

# Reproduces the pipefail/SIGPIPE class: a producer that prints the match on
# its first line and then a lot more. The old `producer | grep -q` shape
# reports some of those matches as failures (status 141); mail_is_running,
# which captures first, must find all of them, and must still treat a
# failing producer as "not running".
# shellcheck disable=SC2329 # process_list stubs are invoked by mail_is_running
self_test_pipefail() {
  printf 'pipefail and early-exit readers\n'
  local saved_process_list attempt fixed_hits=0 old_misses=0
  saved_process_list=$(declare -f process_list)
  process_list() {
    printf '%s\n' "$MAIL_APP_PROCESS"
    seq 1 200000
  }
  for attempt in $(seq 1 20); do
    mail_is_running && fixed_hits=$((fixed_hits + 1))
    (set -o pipefail && process_list | grep -qxF -- "$MAIL_APP_PROCESS") || old_misses=$((old_misses + 1))
  done
  self_test_expect 20 "mail_is_running finds a first-line match ahead of 200000 lines (20 tries)" "$fixed_hits"
  if ((old_misses > 0)); then
    self_test_expect reproduced "old 'producer | grep -q' shape misses matches under pipefail" reproduced "$old_misses of 20 tries reported no match"
  else
    self_test_expect reproduced "old 'producer | grep -q' shape misses matches under pipefail" "not-reproduced"
  fi
  process_list() {
    printf '%s\n' "$MAIL_APP_PROCESS"
    return 1
  }
  expect_outcome not-running "a failing ps counts as Mail not running, even with a match" running not-running mail_is_running
  eval "$saved_process_list"
}

# The e2e-b SMTP alias and the proxy check, with the resolver, DNS, the
# [::1] probe, scutil and /etc/hosts stubbed (the real /etc/hosts is never
# read or written here), then read-only positive controls with the real
# tools.
# shellcheck disable=SC2329,SC2031 # stubs are invoked by the checks; other self-tests' subshell overrides do not reach here
self_test_smtp_alias() {
  printf 'e2e-b SMTP alias (%s; resolver, DNS, [::1] probe and hosts file stubbed)\n' "$SMTP_B_ALIAS"
  local saved_functions saved_hosts_file=$HOSTS_FILE
  saved_functions=$(declare -f resolve_alias_system dig_alias probe_ipv6_loopback read_proxy_settings)
  local good_hosts good_resolver
  good_hosts=$'##\n# Host Database\n127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1             localhost\n127.0.0.1\te2e-b-smtp.test\n::1\te2e-b-smtp.test\n'
  good_resolver=$'name: e2e-b-smtp.test\nipv6_address: ::1\n\nname: e2e-b-smtp.test\nip_address: 127.0.0.1\n'

  # alias_case LABEL WANTED HOSTS RESOLVER [DIG_OUTPUT DIG_STATUS [IPV6_PROBE]]
  alias_case() {
    local label=$1 wanted=$2 hosts=$3 resolver=$4 dig_output=${5:-} dig_status=${6:-0} ipv6_probe=${7:-refused}
    HOSTS_FILE="$workdir/hosts-under-test"
    if [[ $hosts == UNREADABLE ]]; then
      HOSTS_FILE="$workdir/no-such-hosts-file"
    else
      printf '%s' "$hosts" >"$HOSTS_FILE"
    fi
    if [[ $resolver == FAIL ]]; then
      resolve_alias_system() { return 1; }
    else
      eval "resolve_alias_system() { printf '%s' $(printf '%q' "$resolver"); }"
    fi
    eval "dig_alias() { printf '%s' $(printf '%q' "$dig_output"); return $dig_status; }"
    eval "probe_ipv6_loopback() { printf '%s\n' $(printf '%q' "$ipv6_probe"); }"
    PREFLIGHT_REASONS=()
    if check_smtp_alias; then
      self_test_expect "$wanted" "$label" accepted
    else
      self_test_expect "$wanted" "$label" refused "${PREFLIGHT_REASONS[@]}"
    fi
  }

  alias_case "both hosts lines, resolver 127.0.0.1 + ::1, [::1]:1025 refused, no DNS answer" accepted "$good_hosts" "$good_resolver"
  alias_case "dig exit 9 (no DNS server reachable)" accepted "$good_hosts" "$good_resolver" $';; connection timed out; no servers could be reached\n' 9
  alias_case "dig exit 1 (usage error)" refused "$good_hosts" "$good_resolver" '' 1
  alias_case "dig exit 10 (internal error)" refused "$good_hosts" "$good_resolver" '' 10
  alias_case "dig exit 124 (timed out)" refused "$good_hosts" "$good_resolver" '' 124
  alias_case "dig exit 127 (dig missing)" refused "$good_hosts" "$good_resolver" '' 127
  alias_case "DNS answers for the alias" refused "$good_hosts" "$good_resolver" $'93.184.215.14\n' 0
  alias_case "DNS answers AAAA for the alias" refused "$good_hosts" "$good_resolver" $'2606:2800::1\n' 0
  alias_case "something listens on [::1]:1025" refused "$good_hosts" "$good_resolver" '' 0 listening
  alias_case "[::1]:1025 cannot be probed" refused "$good_hosts" "$good_resolver" '' 0 'unknown:connect: Network is unreachable'
  alias_case "resolver adds a second IPv4 address" refused "$good_hosts" "$good_resolver"$'\nname: e2e-b-smtp.test\nip_address: 10.0.0.5\n'
  alias_case "resolver adds an outside IPv6 address" refused "$good_hosts" "$good_resolver"$'\nname: e2e-b-smtp.test\nipv6_address: 2001:db8::5\n'
  alias_case "resolver gives no IPv6 answer" refused "$good_hosts" $'name: e2e-b-smtp.test\nip_address: 127.0.0.1\n'
  alias_case "resolver gives an outside IPv6 address instead of ::1" refused "$good_hosts" $'name: e2e-b-smtp.test\nip_address: 127.0.0.1\nipv6_address: 2001:db8::5\n'
  alias_case "resolver gives no answer" refused "$good_hosts" ''
  alias_case "resolver gives only a public address" refused "$good_hosts" $'name: e2e-b-smtp.test\nip_address: 93.184.215.14\n'
  alias_case "resolver cannot be queried" refused "$good_hosts" FAIL
  alias_case "no hosts lines" refused $'127.0.0.1\tlocalhost\n' "$good_resolver"
  alias_case "only the 127.0.0.1 hosts line" refused $'127.0.0.1\te2e-b-smtp.test\n' "$good_resolver"
  alias_case "only the ::1 hosts line" refused $'::1\te2e-b-smtp.test\n' "$good_resolver"
  alias_case "hosts lines commented out" refused $'#127.0.0.1\te2e-b-smtp.test\n#::1\te2e-b-smtp.test\n' "$good_resolver"
  alias_case "a third hosts line" refused "$good_hosts"$'127.0.0.2\te2e-b-smtp.test\n' "$good_resolver"
  alias_case "duplicate 127.0.0.1 hosts line" refused "$good_hosts"$'127.0.0.1\te2e-b-smtp.test\n' "$good_resolver"
  alias_case "hosts line for 127.0.0.2 instead of 127.0.0.1" refused $'127.0.0.2\te2e-b-smtp.test\n::1\te2e-b-smtp.test\n' "$good_resolver"
  alias_case "hosts line with extra names" refused $'127.0.0.1\te2e-b-smtp.test other.example\n::1\te2e-b-smtp.test\n' "$good_resolver"
  alias_case "hosts file unreadable" refused UNREADABLE "$good_resolver"
  alias_case "hosts lines with trailing comments, in the other order" accepted $'::1 e2e-b-smtp.test # e2e\n127.0.0.1\te2e-b-smtp.test # e2e\n' "$good_resolver"

  printf 'system proxy settings (scutil stubbed)\n'
  proxy_case() {
    local label=$1 wanted=$2 output=$3
    if [[ $output == FAIL ]]; then
      read_proxy_settings() { return 1; }
    else
      eval "read_proxy_settings() { printf '%s\n' $(printf '%q' "$output"); }"
    fi
    PREFLIGHT_REASONS=()
    if check_proxies; then
      self_test_expect "$wanted" "$label" accepted
    else
      self_test_expect "$wanted" "$label" refused "${PREFLIGHT_REASONS[@]}"
    fi
  }
  local clean_proxies key
  clean_proxies=$'<dictionary> {\n  ExceptionsList : <array> {\n    0 : *.local\n    1 : 169.254/16\n  }\n  FTPPassive : 1\n}'
  proxy_case "no proxies (keys absent)" accepted "$clean_proxies"
  proxy_case "every proxy key present and 0" accepted $'<dictionary> {\n  HTTPEnable : 0\n  HTTPSEnable : 0\n  ProxyAutoConfigEnable : 0\n  ProxyAutoDiscoveryEnable : 0\n  SOCKSEnable : 0\n}'
  for key in "${PROXY_ENABLE_KEYS[@]}"; do
    proxy_case "$key : 1" refused $'<dictionary> {\n  '"$key"$' : 1\n  FTPPassive : 1\n}'
  done
  proxy_case "SOCKSEnable with an unexpected value" refused $'<dictionary> {\n  SOCKSEnable : yes\n}'
  proxy_case "empty scutil output" refused ''
  proxy_case "output that is not scutil's dictionary" refused $'No proxies\n'
  proxy_case "truncated dictionary" refused $'<dictionary> {\n  SOCKSEnable : 0'
  proxy_case "scutil cannot be run" refused FAIL

  eval "$saved_functions"
  HOSTS_FILE=$saved_hosts_file

  printf 'positive controls with the real tools (read-only)\n'
  local localhost_output
  if localhost_output=$(resolve_host_system localhost); then
    parse_resolver_addresses "$localhost_output"
    self_test_expect "127.0.0.1 ::1" "dscacheutil parses both families for localhost" \
      "$(grep -qx 127.0.0.1 <<<"$RESOLVED_IPV4" && printf 127.0.0.1) $(grep -qx ::1 <<<"$RESOLVED_IPV6" && printf ::1)"
  else
    self_test_expect "127.0.0.1 ::1" "dscacheutil parses both families for localhost" "query-failed"
  fi
  local dig_status=0
  dig_name localhost A >/dev/null 2>&1 || dig_status=$?
  if [[ $dig_status == 0 || $dig_status == 9 ]]; then
    self_test_expect runs "dig runs (exit 0 or 9)" runs
  else
    self_test_expect runs "dig runs (exit 0 or 9)" "exit-$dig_status"
  fi
  local proxy_output
  if proxy_output=$(read_proxy_settings) && [[ $(head -n 1 <<<"$proxy_output") == "<dictionary> {" && $(tail -n 1 <<<"$proxy_output") == "}" ]]; then
    self_test_expect parsed "scutil --proxy output parses" parsed
  else
    self_test_expect parsed "scutil --proxy output parses" unparsed "$(head -n 1 <<<"$proxy_output")"
  fi
  self_test_expect refused "[::1]:${SMTP_PORT} probe (this run's Mailpit is on 127.0.0.1 only)" "$(probe_ipv6_loopback "$SMTP_PORT")"
  local ipv6_listener_pid
  socat 'TCP6-LISTEN:21026,bind=[::1],reuseaddr,fork' SYSTEM:true >/dev/null 2>&1 &
  ipv6_listener_pid=$!
  local attempt probe_result=""
  for attempt in $(seq 1 30); do
    probe_result=$(probe_ipv6_loopback 21026)
    [[ $probe_result == listening ]] && break
    sleep 0.1
  done
  self_test_expect listening "[::1] probe sees a real IPv6 listener" "$probe_result"
  kill "$ipv6_listener_pid" 2>/dev/null || true
  wait "$ipv6_listener_pid" 2>/dev/null || true

  printf 'e2e-b SMTP records\n'
  local good_a
  good_a=$'account\tE2E A\ttrue\te2e-a@example.test\t127.0.0.1\t1110\t127.0.0.1\t1025\tnever'
  run_preflight_case "B on the alias, with its SMTP record" accepted true "$good_a" \
    $'account\tE2E B\ttrue\te2e-b@example.test\t127.0.0.1\t1111\te2e-b-smtp.test\t1025\tnever' \
    $'smtp\te2e-b-smtp.test\ttrue\te2e-b-smtp.test\t1025' $'smtp\t127.0.0.1\ttrue\t127.0.0.1\t1025'
  self_test_expect true "alias reference noticed (so the resolver check runs)" "$SMTP_ALIAS_REFERENCED"
  run_preflight_case "A alone does not reference the alias" accepted false "$good_a"
  self_test_expect false "no alias reference without B" "$SMTP_ALIAS_REFERENCED"
  run_preflight_case "B sending through 127.0.0.1 directly" refused "" "$good_a" \
    $'account\tE2E B\ttrue\te2e-b@example.test\t127.0.0.1\t1111\t127.0.0.1\t1025\tnever'
  run_preflight_case "A sending through the alias" refused "" \
    $'account\tE2E A\ttrue\te2e-a@example.test\t127.0.0.1\t1110\te2e-b-smtp.test\t1025\tnever'
  run_preflight_case "alias SMTP record on port 1026" refused "" "$good_a" $'smtp\talias\ttrue\te2e-b-smtp.test\t1026'
  run_preflight_case "SMTP record on another .test host" refused "" "$good_a" $'smtp\tother\ttrue\tother-smtp.test\t1025'
  run_preflight_case "SMTP record on the alias in upper case" refused "" "$good_a" $'smtp\talias\ttrue\tE2E-B-SMTP.TEST\t1025'


  printf 'e2e-b SMTP alias inside check_accounts (Mail reads stubbed)\n'
  local saved_run_bounded saved_mail_is_running report
  saved_run_bounded=$(declare -f run_bounded)
  saved_mail_is_running=$(declare -f mail_is_running)
  saved_functions=$(declare -f resolve_alias_system dig_alias probe_ipv6_loopback read_proxy_settings)
  report=$(printf '%s\n' "$good_a" \
    $'account\tE2E B\ttrue\te2e-b@example.test\t127.0.0.1\t1111\te2e-b-smtp.test\t1025\tnever' \
    $'smtp\te2e-b-smtp.test\ttrue\te2e-b-smtp.test\t1025' | tr '\t' '\037')
  mail_is_running() { return 0; }
  eval "run_bounded() { printf '%s\n' $(printf '%q' "$report"); }"
  HOSTS_FILE="$workdir/hosts-under-test"
  printf '%s' "$good_hosts" >"$HOSTS_FILE"
  eval "resolve_alias_system() { printf '%s' $(printf '%q' "$good_resolver"); }"
  dig_alias() { return 0; }
  probe_ipv6_loopback() { printf 'refused\n'; }
  eval "read_proxy_settings() { printf '%s\n' $(printf '%q' "$clean_proxies"); }"
  expect_outcome accepted "check_accounts with a sound alias and no proxies" accepted refused check_accounts
  resolve_alias_system() { printf 'name: e2e-b-smtp.test\nip_address: 127.0.0.1\nipv6_address: ::1\nipv6_address: 2001:db8::5\n'; }
  expect_outcome refused "check_accounts when the alias also resolves outside" accepted refused check_accounts
  eval "resolve_alias_system() { printf '%s' $(printf '%q' "$good_resolver"); }"
  read_proxy_settings() { printf '<dictionary> {\n  SOCKSEnable : 1\n}\n'; }
  expect_outcome refused "check_accounts with a SOCKS proxy on" accepted refused check_accounts
  eval "$saved_run_bounded"
  eval "$saved_mail_is_running"
  eval "$saved_functions"
  HOSTS_FILE=$saved_hosts_file

  printf 'profile consistency\n'
  local profile="$E2E_RESOURCES/e2e-accounts.mobileconfig"
  self_test_expect "$SMTP_B_ALIAS" "profile: e2e-b SMTP host is SMTP_B_ALIAS" \
    "$(/usr/bin/plutil -extract PayloadContent.1.OutgoingMailServerHostName raw -o - "$profile" 2>/dev/null || printf unreadable)"
  self_test_expect "$MAILPIT_HOST" "profile: e2e-a SMTP host" \
    "$(/usr/bin/plutil -extract PayloadContent.0.OutgoingMailServerHostName raw -o - "$profile" 2>/dev/null || printf unreadable)"
  self_test_expect "$POP3_B_PORT" "profile: e2e-b POP port" \
    "$(/usr/bin/plutil -extract PayloadContent.1.IncomingMailServerPortNumber raw -o - "$profile" 2>/dev/null || printf unreadable)"
  self_test_expect "$SMTP_PORT $SMTP_PORT" "profile: both SMTP ports" \
    "$(/usr/bin/plutil -extract PayloadContent.0.OutgoingMailServerPortNumber raw -o - "$profile" 2>/dev/null) $(/usr/bin/plutil -extract PayloadContent.1.OutgoingMailServerPortNumber raw -o - "$profile" 2>/dev/null)"
}

cmd_self_test() {
  prepare_binary
  start_mailpit
  self_test_guards
  self_test_dry_run
  self_test_script_analysis
  self_test_temp_dirs
  self_test_sandbox
  self_test_mailpit
  self_test_forwarder
  self_test_watchdog
  self_test_summary
  self_test_preflight_refusal
  self_test_preflight
  self_test_smtp_alias
  self_test_pipefail
  self_test_display_names
  self_test_live_helpers
  self_test_assertions
  log "e2e: self-test ran $SELF_TEST_CASES cases, $SELF_TEST_MISMATCHES unexpected"
  if ((SELF_TEST_MISMATCHES > 0)); then
    log "e2e: self-test FAILED"
    exit 1
  fi
  log "e2e: self-test passed"
}

make_workdir
case $mode in
  list) cmd_list ;;
  check-only) cmd_check_only ;;
  self-test) cmd_self_test ;;
  serve) cmd_serve ;;
  live) cmd_live ;;
esac
