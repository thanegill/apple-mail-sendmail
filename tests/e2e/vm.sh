#!/usr/bin/env bash
# Runs e2e.sh in a throwaway Tart clone, so its Mail presses never reach the
# host's desktop.
set -euo pipefail

readonly PROGRAM=apple-mail-sendmail-e2e-vm
# Cirrus Labs images ship this account, with passwordless sudo.
readonly GUEST_USER=admin
readonly GUEST_PASSWORD=admin
readonly GUEST_HOME=/Users/admin
readonly GUEST_RUN_DIR=$GUEST_HOME/e2e-vm
readonly GUEST_SERVE_DIR=$GUEST_HOME/e2e-vm-serve
readonly GUEST_PATH=/usr/bin:/bin:/usr/sbin:/sbin
readonly GUEST_NIX_DAEMON=/nix/var/nix/profiles/default/bin/nix-daemon
readonly GUEST_NIX=/nix/var/nix/profiles/default/bin/nix
readonly NIX_DAEMON_WAIT_SECONDS=60
readonly NIX_COPY_ATTEMPTS=4
readonly NIX_DAEMON_DISCONNECTED='Nix daemon disconnected unexpectedly'
readonly GUEST_MOBILECONFIG=$GUEST_HOME/Desktop/e2e-accounts.mobileconfig
readonly PROFILE_IDENTIFIER=test.example.apple-mail-sendmail.e2e
# Must list every port the harness's --serve binds (SMTP, POP3 for e2e-a, the
# e2e-b POP3 forwarder, the API), or a leftover listener goes undetected.
readonly MAILPIT_SMTP_PORT=1025
readonly MAILPIT_PORTS=("$MAILPIT_SMTP_PORT" 1110 1111 8025)
readonly TCC_PREDICATE='subsystem == "com.apple.TCC"'
readonly TCC_SUMMARY_PATTERN='tart-guest-agent|osascript|apple-mail-sendmail|kTCCServiceAppleEvents|kTCCServiceAccessibility|kTCCServicePostEvent'
readonly NIX_UNINSTALL_DOCS=https://nix.dev/manual/nix/stable/installation/uninstall.html
# Together these exercise every grant a live run uses: Accessibility for the
# .eml path (plain and HTML) and Automation for Mail under --no-ui.
readonly APPROVAL_SCENARIOS=(plain-send plain-send-no-ui html-send)

harness_package=${E2E_VM_HARNESS:?E2E_VM_HARNESS must name the harness package}
harness_exe=${E2E_VM_HARNESS_EXE:?E2E_VM_HARNESS_EXE must name the harness executable}
harness_resources=${E2E_VM_RESOURCES:?E2E_VM_RESOURCES must name the harness resources directory}
mobileconfig=$harness_resources/e2e-accounts.mobileconfig
nix_installer=${E2E_VM_NIX_INSTALLER:?E2E_VM_NIX_INSTALLER must name the Nix install script}

golden=${E2E_VM_GOLDEN:-sendmail-e2e-golden}
base_image=${E2E_VM_BASE_IMAGE:-ghcr.io/cirruslabs/macos-golden-gate-base@sha256:4859ea9483a1f6e377301f23a5243798044266a373fc36635e9dcd045e09292f}
state_dir=${E2E_VM_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/apple-mail-sendmail-e2e-vm}
results_root=""
boot_timeout=""
mail_settle_seconds=15
setup_display=graphics
mode=run
harness_args=()

usage() {
  cat <<EOF
Usage: ${PROGRAM} [options] [--] [harness arguments ...]
       ${PROGRAM} --setup-golden [options]
       (from a checkout: nix run .#e2e-vm -- ...)

Runs the live end-to-end harness (nix run .#e2e) inside a disposable Tart
clone of a prepared "golden" macOS VM: clones the golden VM, boots the clone
headless, copies the harness's Nix closure into it, runs the harness there
through \`tart exec\` with the given arguments (plus --keep), copies the
harness's work directory and the guest's TCC log back, then stops and
deletes the clone. The clone is deleted however the run ends.

Wrapper options must come first; the first argument that is not one of them
(or everything after --) goes to the harness.

Which commands boot a VM:
  -- --help, -- -h, --list
                          Run the harness on this Mac, where they only print.
                          No VM is booted.
  --serve                 Refused: it only makes sense on this Mac.
  anything else           The harness first checks the arguments on this Mac
                          (its own parser, in --list mode, which only
                          prints); if they pass, a clone boots. That includes
                          --check-only and --self-test, which run in the VM.

Modes:
  (default)               Run the harness in a fresh clone of the golden VM.
  --setup-golden          Create the golden VM from the base image (or resume
                          preparing one this mode created), automate what can
                          be automated, then walk through the manual steps in
                          the VM's window.

Options:
  --vnc                   With --setup-golden: boot the golden VM with
                          Virtualization.framework's VNC server instead of a
                          window, so a VNC client (or vncdotool) can drive the
                          manual steps. Its input reaches the guest as
                          hardware input.
  --golden NAME           Golden VM name (default: ${golden}; env E2E_VM_GOLDEN)
  --base-image REF        Image the golden VM is cloned from by --setup-golden
                          (default: ${base_image})
  --results DIR           Where each run's results go
                          (default: ${state_dir}/results)
  --boot-timeout SECONDS  How long to wait for the guest agent after boot
                          (default: 300, or 900 for --setup-golden)
  --mail-settle SECONDS   Wait after launching Mail before the harness starts
                          (default: ${mail_settle_seconds})
  -h, --help              Show this help.

The SSH key, pinned host keys and golden-VM markers live in
${state_dir} (env E2E_VM_STATE_DIR).
EOF
}

die() {
  printf 'e2e-vm: %s\n' "$*" >&2
  exit 2
}

log() {
  printf 'e2e-vm: %s\n' "$*" >&2
}

require_value() {
  (($# >= 2)) || die "$1 needs a value"
}

while (($# > 0)); do
  case $1 in
    --setup-golden) mode=setup ;;
    --vnc) setup_display=vnc ;;
    --golden)
      require_value "$@"
      golden=$2
      shift
      ;;
    --base-image)
      require_value "$@"
      base_image=$2
      shift
      ;;
    --results)
      require_value "$@"
      results_root=$2
      shift
      ;;
    --boot-timeout)
      require_value "$@"
      boot_timeout=$2
      shift
      ;;
    --mail-settle)
      require_value "$@"
      mail_settle_seconds=$2
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      harness_args+=("$@")
      break
      ;;
    *)
      harness_args+=("$@")
      break
      ;;
  esac
  shift
done

[[ $golden =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "--golden must be a plain VM name"
[[ $mail_settle_seconds =~ ^[0-9]+$ ]] || die "--mail-settle must be a whole number of seconds"
if [[ -z $boot_timeout ]]; then
  if [[ $mode == setup ]]; then boot_timeout=900; else boot_timeout=300; fi
fi
[[ $boot_timeout =~ ^[0-9]+$ ]] || die "--boot-timeout must be a whole number of seconds"
if [[ $mode == setup ]] && ((${#harness_args[@]} > 0)); then
  die "--setup-golden takes no harness arguments (got: ${harness_args[*]})"
fi
if [[ $mode != setup && $setup_display == vnc ]]; then
  die "--vnc only applies to --setup-golden (runs boot headless)"
fi
results_root=${results_root:-$state_dir/results}
# NIX_SSHOPTS is split on whitespace, so no path that goes into it may hold any.
[[ $state_dir != *[[:space:]]* ]] || die "the state directory must not contain whitespace: $state_dir"

readonly ssh_key=$state_dir/ssh/id_ed25519
readonly known_hosts=$state_dir/known_hosts-$golden
readonly golden_marker=$state_dir/golden-$golden.marker
# Every clone of the golden VM boots from a copy of its disk, so they all
# present the host key that image lineage was given, from changing IP
# addresses. The alias pins that one key, whatever the address.
readonly host_key_alias=$golden

# ---------------------------------------------------------------------------
# Process control. Bash runs an INT or TERM trap only after the foreground
# child exits, so every step that can take long runs as a background job
# that the script waits for: `wait` returns as soon as a signal arrives, the
# trap runs, and cleanup ends the job. Background jobs of a non-interactive
# shell ignore SIGINT, so a Ctrl-C reaches only this script.

foreground_pid=""

run_interruptibly() {
  # Without the explicit <&0, a non-interactive bash gives a background job
  # /dev/null as stdin, so a caller's `run_interruptibly ... <file` would
  # silently send nothing.
  "$@" <&0 &
  foreground_pid=$!
  local status
  while true; do
    status=0
    wait "$foreground_pid" || status=$?
    # A trap that did not exit (the ones cleanup installs) only interrupted
    # the wait; the job is still running.
    kill -0 "$foreground_pid" 2>/dev/null || break
  done
  foreground_pid=""
  return "$status"
}

pause() {
  run_interruptibly sleep "$1"
}

# Returns 1 if the process is still running after the given seconds.
wait_for_exit() {
  local pid=$1 deadline=$((SECONDS + $2))
  while kill -0 "$pid" 2>/dev/null; do
    ((SECONDS < deadline)) || return 1
    sleep 0.2
  done
  wait "$pid" 2>/dev/null || true
}

end_foreground_job() {
  [[ -n $foreground_pid ]] || return 0
  kill -TERM "$foreground_pid" 2>/dev/null || true
  if ! wait_for_exit "$foreground_pid" 10; then
    kill -KILL "$foreground_pid" 2>/dev/null || true
    wait_for_exit "$foreground_pid" 5 || true
  fi
  foreground_pid=""
}

ignore_signals_during_cleanup() {
  trap 'log "still cleaning up (bounded); please wait"' INT TERM
}

# ---------------------------------------------------------------------------
# Tart

# Capture command output before parsing it, throughout: under pipefail,
# `producer | grep -q` fails (141) when grep exits on the first match and the
# producer dies of SIGPIPE, and `producer | reader || true` hides a failed
# producer.

local_vms_json() {
  tart list --source local --format json
}

# Fails with status 2 when tart cannot list VMs.
vm_field() {
  local name=$1 field=$2 vms_json
  vms_json=$(local_vms_json) || return 2
  jq -r --arg name "$name" --arg field "$field" '.[] | select(.Name == $name) | .[$field]' <<<"$vms_json"
}

vm_field_or_die() {
  local value status=0
  value=$(vm_field "$1" "$2") || status=$?
  ((status == 0)) || die "tart list failed, so the state of VM $1 is unknown"
  printf '%s\n' "$value"
}

vm_exists() {
  local found
  found=$(vm_field_or_die "$1" Name) || exit 2
  [[ -n $found ]]
}

vm_running() {
  local running
  running=$(vm_field_or_die "$1" Running) || exit 2
  [[ $running == true ]]
}

tart_run_pid=""

# Starts `tart run` in its own process group, so a Ctrl-C in this terminal
# reaches only this script, whose traps stop the VM in an orderly way. As a
# background job it would inherit SIGINT ignored, and SIGINT is how both
# `tart stop` and stop_vm ask it to stop.
start_vm() {
  local name=$1 display=$2 run_log=$3
  local run_args=(--no-audio)
  case $display in
    headless) run_args+=(--no-graphics) ;;
    vnc) run_args+=(--vnc-experimental) ;;
  esac
  log "booting $name ($display); tart's log: $run_log"
  perl -e '$SIG{INT} = "DEFAULT"; setpgrp(0, 0); exec @ARGV or die "exec $ARGV[0]: $!\n"' -- \
    tart run "${run_args[@]}" "$name" >"$run_log" 2>&1 &
  tart_run_pid=$!
}

vm_process_alive() {
  [[ -n $tart_run_pid ]] && kill -0 "$tart_run_pid" 2>/dev/null
}

# `tart stop` fails (for example "VM is not running" while tart's lock still
# names no pid) without stopping `tart run`, so fall back to signalling it
# directly: SIGINT makes it stop the VM, SIGKILL is the last resort.
stop_vm() {
  local name=$1 grace_seconds=$2
  if vm_process_alive; then
    if ! timeout --foreground $((grace_seconds + 15)) tart stop --timeout "$grace_seconds" "$name" >/dev/null 2>&1; then
      kill -INT "$tart_run_pid" 2>/dev/null || true
    fi
    if ! wait_for_exit "$tart_run_pid" 30; then
      log "tart run (pid $tart_run_pid) did not exit; killing it"
      kill -KILL "$tart_run_pid" 2>/dev/null || true
      wait_for_exit "$tart_run_pid" 10 || log "tart run (pid $tart_run_pid) survived SIGKILL"
    fi
  fi
  tart_run_pid=""
}

# The agent is a LaunchAgent, so it answers only once the auto-login GUI
# session is up; that is also what the Mail steps need.
wait_for_agent() {
  local name=$1 deadline=$((SECONDS + boot_timeout))
  log "waiting up to ${boot_timeout}s for the Tart guest agent in $name"
  until run_interruptibly timeout --foreground 20 tart exec "$name" /usr/bin/true >/dev/null 2>&1; do
    vm_process_alive || die "tart run exited while waiting for $name to boot"
    ((SECONDS < deadline)) ||
      die "the guest agent in $name did not answer within ${boot_timeout}s (if the VM shows a login screen, auto-login is off: log in as $GUEST_USER and rerun)"
    pause 5
  done
}

# ---------------------------------------------------------------------------
# SSH, used for file transfer and `nix copy`; never for anything that drives
# Mail, which must run in the GUI session through `tart exec`.

guest_ip=""
ssh_options=(
  -F none
  -i "$ssh_key"
  -o IdentitiesOnly=yes
  -o IdentityAgent=none
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o ServerAliveInterval=15
  -o "HostKeyAlias=$host_key_alias"
  -o "UserKnownHostsFile=$known_hosts"
  -o GlobalKnownHostsFile=/dev/null
  -o StrictHostKeyChecking=yes
  -o LogLevel=ERROR
)

# For short remote commands; anything that can take long goes through
# guest_ssh_long.
guest_ssh() {
  # shellcheck disable=SC2029 # callers build the remote command on the host on purpose
  ssh "${ssh_options[@]}" "$GUEST_USER@$guest_ip" "$@"
}

guest_ssh_long() {
  local seconds=$1
  shift
  run_interruptibly timeout --foreground "$seconds" \
    ssh "${ssh_options[@]}" "$GUEST_USER@$guest_ip" "$@"
}

ensure_ssh_key() {
  [[ -f $ssh_key ]] && return 0
  mkdir -p "$(dirname "$ssh_key")"
  chmod 700 "$(dirname "$ssh_key")"
  ssh-keygen -q -t ed25519 -N '' -C "$PROGRAM" -f "$ssh_key"
  log "created SSH key $ssh_key"
}

wait_for_ssh() {
  local name=$1 scratch=$2 deadline
  run_interruptibly tart ip --wait 120 "$name" >"$scratch/guest-ip" ||
    die "could not get the IP address of $name"
  guest_ip=$(<"$scratch/guest-ip")
  [[ $guest_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected IP address for $name: $guest_ip"
  deadline=$((SECONDS + 120))
  until guest_ssh_long 20 true </dev/null 2>/dev/null; do
    ((SECONDS < deadline)) || die "SSH to $GUEST_USER@$guest_ip did not answer within 120s"
    pause 3
  done
  log "$name is at $guest_ip"
}

# SSH can be up before launchd has the guest's nix-daemon ready, and a copy
# started then fails with "Nix daemon disconnected unexpectedly". The
# client's status comes back in-band; SSH failing counts as not ready yet.
wait_for_guest_nix_daemon() {
  local deadline=$((SECONDS + NIX_DAEMON_WAIT_SECONDS)) output=""
  while true; do
    output=$(guest_ssh "'$GUEST_NIX' --extra-experimental-features nix-command store info --store daemon 2>&1; echo \"nix-exit:\$?\"" </dev/null 2>&1) || true
    [[ $output =~ nix-exit:0$ ]] && return 0
    ((SECONDS < deadline)) ||
      die "the guest's nix-daemon did not answer within ${NIX_DAEMON_WAIT_SECONDS}s: $(tail -n 3 <<<"$output" | paste -sd'|' -)"
    pause 2
  done
}

# Paths built on the host are unsigned. The guest daemon accepts them only
# from a trusted user ($GUEST_USER, which setup adds to nix.conf) and, even
# then, only when the client passes --no-check-sigs. The guest may
# substitute what it can from its own caches instead of receiving it over
# SSH.
nix_copy_to_guest() {
  run_interruptibly env "NIX_SSHOPTS=${ssh_options[*]}" nix copy --no-check-sigs --substitute-on-destination \
    --to "ssh-ng://$GUEST_USER@$guest_ip?remote-program=$GUEST_NIX_DAEMON" "$@"
}

# Retries only the daemon-not-ready failure, a bounded number of times with
# a growing pause; any other failure stops at once.
copy_closure() {
  local attempt status copy_log
  wait_for_guest_nix_daemon
  copy_log=$(mktemp)
  for ((attempt = 1; ; attempt++)); do
    log "copying the harness closure into the guest (attempt $attempt of $NIX_COPY_ATTEMPTS)"
    status=0
    nix_copy_to_guest "$@" 2>"$copy_log" || status=$?
    cat "$copy_log" >&2
    if ((status == 0)); then
      rm -f "$copy_log"
      return 0
    fi
    if ((attempt < NIX_COPY_ATTEMPTS)) && grep -qF "$NIX_DAEMON_DISCONNECTED" "$copy_log"; then
      log "the guest's nix-daemon disconnected; retrying in $((attempt * 5))s"
      pause $((attempt * 5))
      wait_for_guest_nix_daemon
      continue
    fi
    rm -f "$copy_log"
    die "nix copy into the guest failed (exit $status, attempt $attempt of $NIX_COPY_ATTEMPTS)"
  done
}

# ---------------------------------------------------------------------------
# Harness arguments, checked on the host before any VM boots

# Follows the harness's own option parsing just far enough to tell which mode
# it would run in.
harness_mode() {
  local detected_mode=live skip_value=false arg
  for arg in "${harness_args[@]}"; do
    if [[ $skip_value == true ]]; then
      skip_value=false
      continue
    fi
    case $arg in
      -h | --help)
        echo help
        return 0
        ;;
      --check-only) detected_mode=check-only ;;
      --self-test) detected_mode=self-test ;;
      --serve) detected_mode=serve ;;
      --list) detected_mode=list ;;
      --binary | --draft-wait | --timeout) skip_value=true ;;
    esac
  done
  echo "$detected_mode"
}

# A --binary argument names a host path; the guest needs its closure and the
# resolved store path, because a ./result symlink does not exist there.
store_paths_to_copy=()

resolve_binary_argument() {
  local index next resolved
  for index in "${!harness_args[@]}"; do
    [[ ${harness_args[index]} == --binary ]] || continue
    next=$((index + 1))
    ((next < ${#harness_args[@]})) || die "--binary needs a path"
    resolved=$(realpath -e "${harness_args[next]}") ||
      die "--binary ${harness_args[next]} does not exist"
    [[ $resolved =~ ^(/nix/store/[^/]+)/ ]] ||
      die "--binary must resolve into /nix/store so it can be copied into the VM (got $resolved)"
    store_paths_to_copy+=("${BASH_REMATCH[1]}")
    harness_args[next]=$resolved
  done
}

# The harness's parser rejects unknown options, scenario names and malformed
# values in every mode; with --list last it then only prints the scenarios.
validate_harness_args() {
  local validation_dir status=0
  validation_dir=$(mktemp -d)
  TMPDIR=$validation_dir "$harness_exe" "${harness_args[@]}" --list \
    >/dev/null 2>"$validation_dir/stderr" || status=$?
  if ((status != 0)); then
    cat "$validation_dir/stderr" >&2
    rm -rf "$validation_dir"
    die "the harness rejected its arguments; no VM was started"
  fi
  rm -rf "$validation_dir"
}

# ---------------------------------------------------------------------------
# Running the harness in the guest

# Returns 0 if Mail runs in the guest, 1 if it does not. pgrep's own status
# comes back in-band, so a failed `tart exec` (whose status could be
# anything, 1 included) stops the script instead of reading as "not
# running".
mail_running_in_guest() {
  local name=$1 probe
  # shellcheck disable=SC2016 # expanded by the guest's shell
  probe=$(tart exec "$name" /bin/sh -c '/usr/bin/pgrep -x Mail >/dev/null; echo "pgrep-exit:$?"' 2>&1) ||
    die "could not check whether Mail runs in $name: $probe"
  case $probe in
    pgrep-exit:0) return 0 ;;
    pgrep-exit:1) return 1 ;;
    *) die "could not check whether Mail runs in $name: $probe" ;;
  esac
}

launch_mail() {
  local name=$1 deadline=$((SECONDS + 60))
  run_interruptibly tart exec "$name" /usr/bin/open -a Mail
  until mail_running_in_guest "$name"; do
    ((SECONDS < deadline)) || die "Mail did not start in $name"
    pause 2
  done
  log "Mail is running; letting it settle for ${mail_settle_seconds}s"
  pause "$mail_settle_seconds"
}

# Runs the harness through the guest agent, so it runs in the GUI session
# and TCC charges the agent's grants, with output streamed and saved.
# Callers run this where errexit is off, so failures are checked by hand.
run_harness_in_guest() {
  local name=$1 output_log=$2
  shift 2
  guest_ssh "rm -rf '$GUEST_RUN_DIR' && mkdir -p '$GUEST_RUN_DIR/tmp'" </dev/null ||
    die "could not prepare $GUEST_RUN_DIR in the guest"
  run_interruptibly tart exec "$name" /usr/bin/env \
    "HOME=$GUEST_HOME" "TMPDIR=$GUEST_RUN_DIR/tmp/" "PATH=$GUEST_PATH" LANG=en_US.UTF-8 \
    "$harness_exe" --keep "$@" > >(tee "$output_log") 2>&1
}

guest_time() {
  guest_ssh "date '+%Y-%m-%d %H:%M:%S'" </dev/null
}

summarize_tcc() {
  local tcc_log=$1 count
  count=$(grep -c 'AUTHREQ_' "$tcc_log" || true)
  log "TCC: $count AUTHREQ line(s) in $tcc_log; the first that name the agent, osascript, the binary or the Automation/Accessibility services:"
  grep 'AUTHREQ_' "$tcc_log" | grep -E "$TCC_SUMMARY_PATTERN" | cut -c1-400 | sed -n '1,20p' >&2 || true
}

collect_results() {
  local results=$1 since=$2
  if guest_ssh_long 300 "cd '$GUEST_RUN_DIR' && COPYFILE_DISABLE=1 tar -cf - tmp" \
    </dev/null >"$results/guest-work.tar"; then
    tar -C "$results" -xf "$results/guest-work.tar" && rm -f "$results/guest-work.tar"
  else
    log "could not copy the harness work directory back"
  fi
  guest_ssh_long 120 "sudo -n /usr/bin/log show --style syslog --start '$since' --predicate '$TCC_PREDICATE'" \
    </dev/null >"$results/tcc.log" 2>&1 ||
    log "could not read the guest's TCC log"
  guest_ssh_long 30 "cat /tmp/tart-guest-agent.log" </dev/null >"$results/tart-guest-agent.log" 2>&1 || true
  summarize_tcc "$results/tcc.log"
}

# ---------------------------------------------------------------------------
# Run mode

clone=""
clone_created=false
results=""
run_since=""
results_collected=false

cleanup_run() {
  local status=$?
  ignore_signals_during_cleanup
  end_foreground_job
  if [[ $results_collected == false && -n $guest_ip && -n $run_since ]] && vm_process_alive; then
    log "collecting what the run left in the guest"
    results_collected=true
    collect_results "$results" "$run_since" || true
  fi
  if [[ -n $clone ]]; then
    stop_vm "$clone" 5
    local listed_clone listing_status=0
    listed_clone=$(vm_field "$clone" Name) || listing_status=$?
    # When tart cannot list VMs, try the delete anyway rather than leak it.
    if [[ $clone_created == true ]] && { ((listing_status != 0)) || [[ -n $listed_clone ]]; }; then
      tart delete "$clone" ||
        log "could not delete $clone; delete it with: tart stop $clone; tart delete $clone"
    fi
  fi
  [[ -n $results ]] && log "results: $results"
  exit "$status"
}

report_stale_clones() {
  local stale vms_json
  vms_json=$(local_vms_json) || die "tart list failed"
  stale=$(jq -r --arg prefix "$golden-run-" '.[] | select(.Name | startswith($prefix)) | "  \(.Name) (\(.State))"' <<<"$vms_json")
  [[ -z $stale ]] && return 0
  log "clones left by earlier runs that were killed; stop a running one with tart stop NAME, then tart delete NAME:"
  printf '%s\n' "$stale" >&2
}

cmd_run() {
  case $(harness_mode) in
    help | list)
      exec "$harness_exe" "${harness_args[@]}"
      ;;
    serve)
      die "--serve runs Mailpit for setting up accounts on this Mac; run it with nix run .#e2e -- --serve"
      ;;
  esac
  store_paths_to_copy=("$harness_package")
  resolve_binary_argument
  validate_harness_args

  vm_exists "$golden" ||
    die "golden VM '$golden' not found; create it with: nix run .#e2e-vm -- --setup-golden"
  ! vm_running "$golden" || die "golden VM '$golden' is running; stop it first: tart stop $golden"
  [[ -f $ssh_key && -f $known_hosts ]] ||
    die "no SSH key or pinned host key for '$golden' in $state_dir; rerun --setup-golden"
  report_stale_clones

  local candidate
  candidate=$golden-run-$(date +%Y%m%d-%H%M%S)-$$
  ! vm_exists "$candidate" || die "a VM named $candidate already exists"
  clone=$candidate
  results=$results_root/$clone
  mkdir -p "$results"
  trap cleanup_run EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  log "cloning $golden to $clone"
  clone_created=true
  run_interruptibly tart clone "$golden" "$clone"
  start_vm "$clone" headless "$results/tart-run.log"
  wait_for_agent "$clone"
  wait_for_ssh "$clone" "$results"
  run_since=$(guest_time)
  copy_closure "${store_paths_to_copy[@]}"
  launch_mail "$clone"

  local status=0
  run_harness_in_guest "$clone" "$results/harness.log" "${harness_args[@]}" || status=$?
  log "harness exited with status $status"
  results_collected=true
  collect_results "$results" "$run_since"
  return "$status"
}

# ---------------------------------------------------------------------------
# Setup mode

setup_vm_running=false
tcc_stream_pid=""

marker_matches() {
  [[ -f $golden_marker ]] && grep -qxF "name=$golden" "$golden_marker"
}

write_marker() {
  mkdir -p "$state_dir"
  printf 'name=%s\nbase-image=%s\ncreated=%s\n' "$golden" "$base_image" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$golden_marker"
}

# A clean guest shutdown, so the golden disk is consistent; `tart stop`
# alone pulls the virtual power cord.
shutdown_golden() {
  if [[ -n $guest_ip ]]; then
    log "shutting down $golden"
    timeout --foreground 30 ssh "${ssh_options[@]}" "$GUEST_USER@$guest_ip" \
      'sudo -n /sbin/shutdown -h now' </dev/null || true
    wait_for_exit "$tart_run_pid" 180 || true
  fi
  stop_vm "$golden" 30
}

cleanup_setup() {
  local status=$?
  ignore_signals_during_cleanup
  end_foreground_job
  if [[ -n $tcc_stream_pid ]]; then
    kill "$tcc_stream_pid" 2>/dev/null || true
  fi
  if [[ -n $serve_ssh_pid ]]; then
    stop_setup_mailpit
  fi
  if [[ $setup_vm_running == true ]]; then
    shutdown_golden
  fi
  exit "$status"
}

install_authorized_key() {
  # shellcheck disable=SC2016 # expanded by the guest's shell
  run_interruptibly tart exec -i "$golden" /bin/sh -c '
    umask 077
    mkdir -p "$1/.ssh"
    IFS= read -r key
    touch "$1/.ssh/authorized_keys"
    grep -qxF "$key" "$1/.ssh/authorized_keys" || printf "%s\n" "$key" >>"$1/.ssh/authorized_keys"
  ' sh "$GUEST_HOME" <"$ssh_key.pub"
}

# Read over the agent's channel, which needs no host key, so SSH can then
# insist on this exact key.
pin_host_key() {
  local host_key
  if ! host_key=$(tart exec "$golden" /bin/cat /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null); then
    tart exec "$golden" /usr/bin/sudo -n /usr/bin/ssh-keygen -A >/dev/null
    host_key=$(tart exec "$golden" /bin/cat /etc/ssh/ssh_host_ed25519_key.pub)
  fi
  [[ $host_key =~ ^(ssh-ed25519\ [A-Za-z0-9+/=]+) ]] || die "unexpected SSH host key from $golden: $host_key"
  printf '%s %s\n' "$host_key_alias" "${BASH_REMATCH[1]}" >"$known_hosts"
  log "pinned $golden's SSH host key in $known_hosts"
}

configure_session() {
  local auto_login_user
  auto_login_user=$(guest_ssh 'defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true' </dev/null)
  if [[ $auto_login_user != "$GUEST_USER" ]]; then
    log "turning on auto-login for $GUEST_USER"
    guest_ssh "sudo -n sysadminctl -autologin set -userName '$GUEST_USER' -password '$GUEST_PASSWORD'" </dev/null
  fi
  guest_ssh 'sudo -n pmset -a sleep 0 displaysleep 0 disksleep 0' </dev/null
}

# Runs a yes/no test in the guest: 0 is yes, 1 is no, and anything else
# (SSH failing, a command erroring) stops the script rather than read as no.
guest_test() {
  local status=0
  guest_ssh "$1" </dev/null || status=$?
  ((status <= 1)) || die "could not run a check in the guest (exit $status): $1"
  return "$status"
}

# The installer cannot resume an interrupted install: it refuses to run over
# its own leftovers.
install_nix() {
  if guest_test "test -x '$GUEST_NIX_DAEMON'"; then
    log "Nix is already installed in $golden"
  elif guest_test 'test -e /nix/store || test -e /etc/bashrc.backup-before-nix || test -e /etc/zshrc.backup-before-nix || { test -f /etc/synthetic.conf && grep -q "^nix" /etc/synthetic.conf; }'; then
    die "an earlier Nix install in $golden did not finish. Either start over (the base image usually stays in Tart's cache): tart delete $golden && rm $golden_marker && nix run .#e2e-vm -- --setup-golden; or uninstall Nix in the guest following the macOS steps of $NIX_UNINSTALL_DOCS and rerun --setup-golden"
  else
    log "installing Nix in $golden"
    guest_ssh 'cat >/tmp/nix-install' <"$nix_installer"
    printf 'trusted-users = root %s\n' "$GUEST_USER" | guest_ssh 'cat >/tmp/nix-extra.conf'
    guest_ssh_long 1800 'sh /tmp/nix-install --daemon --yes --no-channel-add --nix-extra-conf-file /tmp/nix-extra.conf' </dev/null
    guest_ssh 'rm -f /tmp/nix-install /tmp/nix-extra.conf' </dev/null
  fi
  if ! guest_test "grep -Eq '^trusted-users = (.* )?$GUEST_USER( |\$)' /etc/nix/nix.conf"; then
    log "trusting $GUEST_USER in the guest's nix.conf"
    guest_ssh "printf 'trusted-users = root %s\\n' '$GUEST_USER' | sudo -n tee -a /etc/nix/nix.conf >/dev/null && sudo -n launchctl kickstart -k system/org.nixos.nix-daemon" </dev/null
  fi
}

# Not knowing counts as not installed: that path only checks for leftover
# accounts and opens the profile for approval again.
profile_installed() {
  local profiles_output
  if ! profiles_output=$(guest_ssh '/usr/bin/profiles show -type configuration 2>&1' </dev/null); then
    log "could not list the guest's configuration profiles ($profiles_output); treating the e2e profile as not installed"
    return 1
  fi
  grep -qF "$PROFILE_IDENTIFIER" <<<"$profiles_output"
}

stage_mobileconfig() {
  guest_ssh "cat >'$GUEST_MOBILECONFIG'" <"$mobileconfig"
  if profile_installed; then
    log "the e2e accounts profile is already installed"
    return 0
  fi
  # Opening it from the GUI session queues it for approval in System Settings.
  tart exec "$golden" /usr/bin/open "$GUEST_MOBILECONFIG" || true
}

# Runs as root in the guest (sent with `declare -f`, so POSIX sh only).
# Must parse the file exactly as the harness's check_smtp_alias does: from
# the first "#" is a comment, a line mentions the alias when any of its
# names equals it case-insensitively, and the only accepted mentions are
# "127.0.0.1 alias" and "::1 alias". Appends only what is missing; exits 3,
# editing nothing, on any other mention, which is left for a human.
ensure_hosts_lines() {
  hosts_alias=$1
  hosts_file=$2
  mentions=$(awk -v name="$hosts_alias" '
    { sub(/#.*/, "") }
    NF == 0 { next }
    {
      for (i = 2; i <= NF; i++) {
        if (tolower($i) == name) {
          line = $1
          for (j = 2; j <= NF; j++) line = line " " $j
          print line
          next
        }
      }
    }' "$hosts_file")
  mention_count=$(printf '%s\n' "$mentions" | grep -c .)
  ipv4_count=$(printf '%s\n' "$mentions" | grep -cxF "127.0.0.1 $hosts_alias")
  ipv6_count=$(printf '%s\n' "$mentions" | grep -cxF "::1 $hosts_alias")
  if [ "$ipv4_count" -gt 1 ] || [ "$ipv6_count" -gt 1 ] ||
    [ "$mention_count" -ne $((ipv4_count + ipv6_count)) ]; then
    printf '%s\n' "$mentions"
    return 3
  fi
  if [ "$ipv4_count" -eq 1 ] && [ "$ipv6_count" -eq 1 ]; then
    echo unchanged
    return 0
  fi
  if [ -s "$hosts_file" ] && [ "$(tail -c 1 "$hosts_file" | od -An -c | tr -d ' ')" != '\n' ]; then
    printf '\n' >>"$hosts_file"
  fi
  [ "$ipv4_count" -eq 1 ] || printf '127.0.0.1\t%s\n' "$hosts_alias" >>"$hosts_file"
  [ "$ipv6_count" -eq 1 ] || printf '::1\t%s\n' "$hosts_alias" >>"$hosts_file"
  echo added
}

# The two checks below duplicate the harness's own (probe_ipv6_loopback and
# check_proxies in e2e.sh, which cannot be called on their own) so that
# setup fails here rather than at the first approval pass. Keep them in
# step with the harness.

# Mailpit binds 127.0.0.1 only. Mail tries [::1] first for the alias, and
# only a refused connection is known to fall back to 127.0.0.1, so the
# probe passes on ECONNREFUSED alone. Runs with the closure's perl.
# shellcheck disable=SC2016 # Perl code, not shell
readonly IPV6_PROBE_PERL='
  my $port = shift @ARGV;
  socket(my $s, AF_INET6, SOCK_STREAM, 0) or do { print "unknown:socket: $!\n"; exit 0 };
  my $address = pack_sockaddr_in6($port, inet_pton(AF_INET6, "::1"));
  if (connect($s, $address)) { print "listening\n" }
  elsif ($!{ECONNREFUSED}) { print "refused\n" }
  else { print "unknown:connect: $!\n" }
'

perl_exe=""
perl_store_path=""

# The probe needs a perl in the guest; this wrapper's own comes from the Nix
# store, so setup copies its closure in with the harness's.
resolve_probe_perl() {
  perl_exe=$(realpath -e "$(command -v perl)") || die "perl is not on PATH"
  [[ $perl_exe =~ ^(/nix/store/[^/]+)/ ]] || die "perl must come from /nix/store (got $perl_exe)"
  perl_store_path=${BASH_REMATCH[1]}
}

check_guest_ipv6_smtp_port() {
  local result
  result=$(guest_ssh "'$perl_exe' -MSocket=:all - $MAILPIT_SMTP_PORT" <<<"$IPV6_PROBE_PERL") ||
    result="unknown:probe failed"
  [[ $result == refused ]] ||
    die "[::1]:$MAILPIT_SMTP_PORT in the guest is \"$result\", not refused; the harness refuses that (Mail would try it first for $smtp_b_alias). Stop whatever listens there and rerun --setup-golden"
}

# Mail honours system proxies, and a SOCKS proxy resolves names on the
# proxy side, bypassing /etc/hosts. Keys scutil leaves out are off; any
# value but 0, or output that is not scutil's dictionary, refuses.
readonly PROXY_ENABLE_KEYS=(SOCKSEnable HTTPEnable HTTPSEnable ProxyAutoConfigEnable ProxyAutoDiscoveryEnable)

check_guest_proxies() {
  local output key value proxy_reasons=()
  output=$(guest_ssh '/usr/sbin/scutil --proxy' </dev/null) ||
    die "could not read the guest's system proxy settings (scutil --proxy)"
  if [[ $(head -n 1 <<<"$output") != "<dictionary> {" || $(tail -n 1 <<<"$output") != "}" ]]; then
    die "could not parse the guest's system proxy settings: $(head -n 1 <<<"$output")"
  fi
  for key in "${PROXY_ENABLE_KEYS[@]}"; do
    value=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//p" <<<"$output")
    [[ -z $value || $value == 0 ]] && continue
    proxy_reasons+=("$key is \"$(paste -sd, - <<<"$value")\"")
  done
  ((${#proxy_reasons[@]} == 0)) && return 0
  die "the guest has a system proxy on (${proxy_reasons[*]}), which the harness refuses; in the VM turn every proxy off (System Settings -> Network -> Details -> Proxies) and rerun --setup-golden"
}

# The harness defines e2e-b's SMTP hostname once, in e2e.sh, and its
# profile and preflight follow it. Anything but exactly one plain
# `readonly SMTP_B_ALIAS=<hostname>` line there stops setup.
smtp_b_alias=""

read_smtp_b_alias() {
  local definitions hostname_re='[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+'
  definitions=$(grep -E '(^|[[:space:];])SMTP_B_ALIAS=' "$harness_resources/e2e.sh" || true)
  [[ $definitions =~ ^readonly\ SMTP_B_ALIAS=($hostname_re)$ ]] ||
    die "could not read exactly one plain 'readonly SMTP_B_ALIAS=<hostname>' line from $harness_resources/e2e.sh (found: ${definitions:-none})"
  smtp_b_alias=${BASH_REMATCH[1]}
}

# macOS 27 keeps one profile-managed SMTP account per host, so e2e-b's SMTP
# server is a hostname that the guest's /etc/hosts maps to the loopback
# addresses, IPv4 and IPv6 both, so neither lookup reaches real DNS.
ensure_smtp_b_alias() {
  local outcome status=0 addresses attempt remote_script resolver_output
  # shellcheck disable=SC2016 # "$@" belongs to the guest's sh
  remote_script="$(declare -f ensure_hosts_lines)"$'\n''ensure_hosts_lines "$@"'
  outcome=$(guest_ssh "sudo -n /bin/sh -s -- '$smtp_b_alias' /etc/hosts" <<<"$remote_script") || status=$?
  if ((status == 3)); then
    die "the guest's /etc/hosts already maps $smtp_b_alias some other way; leave exactly the two lines '127.0.0.1 $smtp_b_alias' and '::1 $smtp_b_alias' (or none) there, with no other names on them, and rerun --setup-golden. Found: $(paste -sd'|' - <<<"$outcome")"
  fi
  ((status == 0)) || die "could not update /etc/hosts in the guest: $outcome"
  if [[ $outcome == added ]]; then
    log "mapped $smtp_b_alias to 127.0.0.1 and ::1 in the guest's /etc/hosts"
    guest_ssh 'sudo -n dscacheutil -flushcache; sudo -n killall -HUP mDNSResponder' </dev/null || true
  fi
  for attempt in 1 2 3 4 5; do
    resolver_output=$(guest_ssh "dscacheutil -q host -a name '$smtp_b_alias'" </dev/null) ||
      die "could not query the guest's resolver for $smtp_b_alias: $resolver_output"
    addresses=$(grep -E '^(ip|ipv6)_address:' <<<"$resolver_output" | cut -d' ' -f2 |
      LC_ALL=C sort -u | paste -sd' ' -) || addresses=""
    [[ $addresses == '127.0.0.1 ::1' ]] && return 0
    ((attempt < 5)) && pause 1
  done
  die "$smtp_b_alias resolves to '${addresses:-nothing}' in the guest, not exactly 127.0.0.1 and ::1"
}

# `profiles remove` leaves the profile's mail accounts behind, and
# installing it again then fails with "already exists". The profile's POP
# rows carry its account description and the e2e-a or e2e-b username; its
# SMTP rows carry the description with an empty username. Read-only:
# deleting accounts is left to the human.
readonly LEFTOVER_ACCOUNTS_QUERY="SELECT IFNULL(ZACCOUNTDESCRIPTION, '(no description)') || ' (' || IFNULL(NULLIF(ZUSERNAME, ''), 'no username') || ')' FROM ZACCOUNT WHERE ZACCOUNTDESCRIPTION LIKE '%apple-mail-sendmail e2e%' OR ZUSERNAME IN ('e2e-a', 'e2e-b', 'e2e-a@example.test', 'e2e-b@example.test');"

refuse_leftover_accounts() {
  local leftovers status=0
  leftovers=$(guest_ssh "sqlite3 -readonly \"\$HOME/Library/Accounts/Accounts4.sqlite\" \"$LEFTOVER_ACCOUNTS_QUERY\"" \
    </dev/null 2>&1) || status=$?
  ((status == 0)) ||
    die "could not read the guest's mail accounts to check for leftovers from an earlier profile: $leftovers"
  [[ -z $leftovers ]] && return 0
  local leftover
  while IFS= read -r leftover; do
    printf '  %s\n' "$leftover" >&2
  done <<<"$leftovers"
  die "the guest still has e2e mail accounts from an earlier profile (listed above), so the profile would fail with \"already exists\". In the VM, delete each one in Mail -> Settings -> Accounts (select it, then the minus button), then rerun --setup-golden"
}

guest_agent_path() {
  # shellcheck disable=SC2016 # expanded by the guest's shell
  tart exec "$golden" /bin/sh -c 'realpath "$(ps -o comm= -p "$PPID")"' 2>/dev/null ||
    echo "(unknown; usually under /opt/homebrew/Cellar/tart-guest-agent)"
}

prompt() {
  local message=$1 answer
  read -r -p "$message" answer </dev/tty
  printf '%s' "$answer"
}

print_manual_steps() {
  cat >&2 <<EOF

==============================================================================
Manual steps, in the "$golden" VM window (the password is $GUEST_PASSWORD).
The harness's Mailpit is running in the guest until you finish step 6
(POP3 for E2E Account A on 127.0.0.1:1110, and for E2E Account B through
its forwarder on 127.0.0.1:1111), because macOS checks each account's POP
login when the profile is installed.

 1. System Settings -> General -> Device Management: open "apple-mail-sendmail
    e2e accounts" and click Install (it was copied to the Desktop as
    e2e-accounts.mobileconfig and opened; if it is not listed, double-click
    that file first).
 2. Open Mail (Finder -> Applications -> Mail). Dismiss its first-run
    sheets, then quit Mail (Cmd-Q) and open it again: the sheets leave an
    invisible window behind that the harness's window check refuses. If
    Mail asks you to add an account, step 1 did not take.
 3. Mail -> Settings -> Accounts: for E2E Account A and E2E Account B set
    "Remove copy from server after retrieving a message" to Never.
 4. Mail -> Settings -> Rules: untick every rule (including News From
    Apple).
 5. Mail -> Settings -> Accounts -> Server Settings -> Outgoing Mail
    Account -> Edit SMTP Server List: only 127.0.0.1 entries may remain.
 6. Close Settings and any other window but the main viewer, and click an
    empty mailbox in the sidebar so that no message is selected. Leave Mail
    running.
==============================================================================
EOF
}

print_automation_steps() {
  local agent_path=$1
  cat >&2 <<EOF

==============================================================================
Automation access. macOS shows the Automation prompt only when osascript
asks; the binary's own Apple Events (sent only with --no-ui) are denied
(-1743) without one. So this step asks with osascript, once for Mail and
once for System Events, and the grant then covers the binary too. In the VM:

 7. Each prompt must name "tart-guest-agent" (wants to control "Mail", then
    "System Events"): click Allow. If a prompt names anything else
    (apple-mail-sendmail, osascript, bash), click Don't Allow and report
    it: TCC is charging another process.

Accessibility needs no prompt: the Cirrus Labs image already grants it to
tart-guest-agent ($agent_path).
==============================================================================
EOF
}

# Mailpit must answer while the profile is installed, or macOS refuses the
# accounts ("Unable to verify account name or password"). Runs the harness's
# --serve over SSH; its own exit trap stops Mailpit's watchdog, which ignores
# SIGINT, with SIGTERM.
serve_ssh_pid=""

start_setup_mailpit() {
  local serve_log=$1 deadline
  log "starting the harness's Mailpit in the guest for the profile install; its log: $serve_log"
  # shellcheck disable=SC2029 # the remote command is built on the host on purpose
  ssh "${ssh_options[@]}" "$GUEST_USER@$guest_ip" \
    "mkdir -p '$GUEST_SERVE_DIR' && echo \$\$ >'$GUEST_SERVE_DIR/pid' && exec /usr/bin/env HOME='$GUEST_HOME' TMPDIR='$GUEST_SERVE_DIR/' PATH='$GUEST_PATH' LANG=en_US.UTF-8 '$harness_exe' --serve" \
    </dev/null >"$serve_log" 2>&1 &
  serve_ssh_pid=$!
  deadline=$((SECONDS + 60))
  until grep -q 'Mailpit is serving' "$serve_log" 2>/dev/null; do
    if ! kill -0 "$serve_ssh_pid" 2>/dev/null; then
      cat "$serve_log" >&2
      die "the harness's Mailpit did not start in the guest"
    fi
    ((SECONDS < deadline)) || die "the harness's Mailpit did not report serving within 60s (see $serve_log)"
    pause 1
  done
}

stop_setup_mailpit() {
  [[ -n $serve_ssh_pid ]] || return 0
  log "stopping the guest's setup Mailpit"
  # shellcheck disable=SC2029 # the remote command is built on the host on purpose
  timeout --foreground 30 ssh "${ssh_options[@]}" "$GUEST_USER@$guest_ip" \
    "kill -TERM \"\$(cat '$GUEST_SERVE_DIR/pid')\"" </dev/null || true
  if ! wait_for_exit "$serve_ssh_pid" 20; then
    log "the --serve session did not end; closing it"
    kill "$serve_ssh_pid" 2>/dev/null || true
    wait_for_exit "$serve_ssh_pid" 5 || true
  fi
  serve_ssh_pid=""
}

# Only osascript can raise the Automation prompt here: the binary lacks the
# hardened-runtime Apple Events entitlement, so tccd denies its events (-1743)
# without one. Do not replace this step with a harness scenario.
request_automation_access() {
  local target=$1 script=$2 output_log=$3 answer
  while true; do
    log "asking for Automation access to $target; click Allow in the VM"
    if run_interruptibly timeout --foreground 300 tart exec "$golden" /usr/bin/osascript -e "$script" \
      >"$output_log" 2>&1; then
      log "Automation access to $target works"
      return 0
    fi
    log "osascript could not control $target: $(tail -n 1 "$output_log")"
    log "if you clicked Don't Allow, switch tart-guest-agent on under System Settings -> Privacy & Security -> Automation -> $target"
    answer=$(prompt "Try again? [Y/n] ")
    [[ $answer == [nN]* ]] && return 1
  done
}

# Exit 0 alone is not enough: the summary must also say so, so a truncated or
# misread run never counts. The harness's self_test_summary checks its
# summary with these same patterns; change them together.
approval_pass_passed() {
  local harness_log=$1 status=$2 scenario
  ((status == 0)) || return 1
  grep -q '^RESULT: success' "$harness_log" || return 1
  for scenario in "${APPROVAL_SCENARIOS[@]}"; do
    grep -Eq "^${scenario}[[:space:]]+PASS([[:space:]]|\$)" "$harness_log" || return 1
  done
}

print_final_steps() {
  cat >&2 <<EOF

==============================================================================
Last steps, in the VM window:

 9. In Mail, close every window but the main viewer, check the Outbox is
    empty, and click an empty mailbox so no message is selected.
10. Quit Mail (Cmd-Q). Each run launches it again.

Then press Enter here; the VM shuts down and becomes the golden image.
==============================================================================
EOF
}

# Prints the pids listening on any of Mailpit's ports in the guest, space
# separated (nothing when none). lsof exits 1 when nothing matches, so its
# status is reported in-band; SSH failing, lsof failing any other way, or
# output that is not pids, stops setup instead of reading as "none".
guest_mailpit_listeners() {
  local port_args=() port output lsof_status pids
  for port in "${MAILPIT_PORTS[@]}"; do
    port_args+=("-iTCP:$port")
  done
  output=$(guest_ssh "/usr/sbin/lsof -nP -t -sTCP:LISTEN ${port_args[*]}; echo \"lsof-exit:\$?\"" </dev/null) ||
    die "could not list the listeners on Mailpit's ports in the guest: $output"
  [[ $output =~ lsof-exit:([0-9]+)$ ]] || die "unexpected lsof output from the guest: $output"
  lsof_status=${BASH_REMATCH[1]}
  ((lsof_status <= 1)) || die "lsof failed in the guest (exit $lsof_status): $output"
  pids=$(grep -v '^lsof-exit:' <<<"$output" | LC_ALL=C sort -un | paste -sd' ' -) || pids=""
  [[ -z $pids || $pids =~ ^[0-9]+( [0-9]+)*$ ]] || die "unexpected lsof output from the guest: $output"
  printf '%s\n' "$pids"
}

# The harness leaves its Mailpit running when it cannot confirm Mail's
# Outbox is empty, so that Mail can still deliver; a new pass cannot start
# while it holds the ports. Returns 1 if they stay taken.
clear_leftover_mailpit() {
  local listeners
  listeners=$(guest_mailpit_listeners) || exit 2
  [[ -z $listeners ]] && return 0
  log "a Mailpit (or its POP3 forwarder) from an earlier pass still holds some of ports ${MAILPIT_PORTS[*]} in the guest:"
  guest_ssh "ps -o pid=,command= -p '${listeners// /,}'" </dev/null >&2 || true
  cat >&2 <<EOF
The harness left it running because Mail's Outbox did not empty. In the VM,
open Mail's Outbox and delete anything stuck there (never pick another SMTP
server if Mail offers one), then stop this Mailpit to run the next pass.
EOF
  local answer
  answer=$(prompt "Stop it now (kill $listeners in the guest)? [y/N] ")
  [[ $answer == [yY]* ]] || return 1
  guest_ssh "kill $listeners" </dev/null || true
  pause 3
  listeners=$(guest_mailpit_listeners) || exit 2
  [[ -z $listeners ]] || {
    log "the ports are still taken (pids: $listeners)"
    return 1
  }
}

start_tcc_stream() {
  guest_ssh "sudo -n /usr/bin/log stream --style syslog --predicate '$TCC_PREDICATE'" \
    </dev/null >"$1" 2>&1 &
  tcc_stream_pid=$!
}

stop_tcc_stream() {
  [[ -n $tcc_stream_pid ]] || return 0
  pause 2
  kill "$tcc_stream_pid" 2>/dev/null || true
  wait "$tcc_stream_pid" 2>/dev/null || true
  tcc_stream_pid=""
}

run_approval_pass() {
  local setup_results=$1 stamp harness_log tcc_log status=0
  if ! clear_leftover_mailpit; then
    log "skipping this pass while Mailpit's ports are taken"
    return 1
  fi
  stamp=$(date +%H%M%S)
  harness_log=$setup_results/approval-$stamp-harness.log
  tcc_log=$setup_results/approval-$stamp-tcc.log
  start_tcc_stream "$tcc_log"
  run_harness_in_guest "$golden" "$harness_log" "${APPROVAL_SCENARIOS[@]}" || status=$?
  stop_tcc_stream
  summarize_tcc "$tcc_log"
  if approval_pass_passed "$harness_log" "$status"; then
    log "approval pass PASSED (harness exit status $status)"
    return 0
  fi
  log "approval pass did NOT pass (harness exit status $status; every one of ${APPROVAL_SCENARIOS[*]} must be PASS in its summary)"
  return 1
}

wait_for_mail_to_quit() {
  prompt "Press Enter when Mail has quit: " >/dev/null
  while mail_running_in_guest "$golden"; do
    prompt "Mail is still running in the VM. Quit it (Cmd-Q), then press Enter: " >/dev/null
  done
}

cmd_setup() {
  read_smtp_b_alias
  resolve_probe_perl
  local setup_results
  setup_results=$results_root/setup-$golden-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$setup_results"
  ensure_ssh_key

  trap cleanup_setup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if vm_exists "$golden"; then
    marker_matches ||
      die "a VM named '$golden' exists, but --setup-golden did not create it (no marker at $golden_marker), so it is left alone; pick another --golden name"
    ! vm_running "$golden" || die "$golden is running; stop it first: tart stop $golden"
    log "resuming setup of $golden, which --setup-golden created"
  else
    write_marker
    log "cloning $base_image to $golden (the first pull downloads about 32 GB and needs about 50 GB free)"
    run_interruptibly tart clone "$base_image" "$golden"
  fi

  start_vm "$golden" "$setup_display" "$setup_results/tart-run.log"
  if [[ $setup_display == vnc ]]; then
    log "VNC: Tart prints the vnc:// URL (with its password) to $setup_results/tart-run.log"
  fi
  setup_vm_running=true
  wait_for_agent "$golden"
  install_authorized_key
  pin_host_key
  wait_for_ssh "$golden" "$setup_results"
  configure_session
  install_nix
  copy_closure "$harness_package" "$perl_store_path"
  ensure_smtp_b_alias
  check_guest_ipv6_smtp_port
  check_guest_proxies
  profile_installed || refuse_leftover_accounts
  clear_leftover_mailpit || die "Mailpit's ports are taken in the guest; cannot start the setup Mailpit"
  start_setup_mailpit "$setup_results/serve.log"
  stage_mobileconfig

  print_manual_steps
  prompt "Press Enter when steps 1-6 are done: " >/dev/null
  stop_setup_mailpit

  print_automation_steps "$(guest_agent_path)"
  start_tcc_stream "$setup_results/automation-tcc.log"
  request_automation_access Mail 'tell application "Mail" to get name' \
    "$setup_results/automation-mail.log" || log "continuing without Automation access to Mail"
  request_automation_access "System Events" \
    'tell application "System Events" to get name of first process whose frontmost is true' \
    "$setup_results/automation-system-events.log" || log "continuing without Automation access to System Events"
  stop_tcc_stream
  summarize_tcc "$setup_results/automation-tcc.log"

  local answer
  while true; do
    answer=$(prompt "Press Enter to run the approval pass (${APPROVAL_SCENARIOS[*]}), or type skip: ")
    [[ $answer == skip ]] && break
    run_approval_pass "$setup_results" || true
    answer=$(prompt "Run it again? [y/N] ")
    [[ $answer == [yY]* ]] || break
  done

  print_final_steps
  wait_for_mail_to_quit
  guest_ssh "rm -rf '$GUEST_RUN_DIR' '$GUEST_SERVE_DIR'" </dev/null || true
  shutdown_golden
  setup_vm_running=false
  log "golden VM $golden is ready; setup logs: $setup_results"
  log "run the harness in a clone with: nix run .#e2e-vm"
}

command -v nix >/dev/null || die "nix is not on PATH (needed for nix copy)"
case $mode in
  run) cmd_run ;;
  setup) cmd_setup ;;
esac
