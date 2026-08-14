#!/usr/bin/env bash
# Consolidated operations regression suite.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

check_operation_guard_contracts() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
OPS="$ROOT/lib/operations.sh"
BACKUP="$ROOT/utilities/backup-run.sh"
CROWDSEC="$ROOT/utilities/setup-crowdsec.sh"
CROWDSEC_APPLY="$ROOT/utilities/crowdsec-worker-apply.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

require() {
    grep -Eq -- "$1" "$2" || fail "$3"
}

reject() {
    ! grep -Eq -- "$1" "$2" || fail "$3"
}

tmpdir="$(mktemp -d)"
cleanup_pids=()
cleanup() {
    [[ -n "${holder_pid:-}" ]] && kill "$holder_pid" 2>/dev/null || true
    local pid
    for pid in "${cleanup_pids[@]}"; do
        [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
    done
    sleep 0.1
    for pid in "${cleanup_pids[@]}"; do
        [[ "$pid" =~ ^[0-9]+$ ]] && kill -KILL "$pid" 2>/dev/null || true
    done
    rm -rf "$tmpdir"
}
trap cleanup EXIT

if ! command -v flock >/dev/null 2>&1; then
    mock_bin="$tmpdir/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/flock" <<'EOF_FLOCK'
#!/usr/bin/env bash
set -euo pipefail

mode="lock"
contention_exit=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n) shift ;;
        -E) contention_exit="${2:-1}"; shift 2 ;;
        -u) mode="unlock"; shift ;;
        *) break ;;
    esac
done

fd="${1:-}"
[[ "$fd" =~ ^[0-9]+$ ]] || exit 2

path="$(lsof -p "$PPID" -a -d "$fd" 2>/dev/null | awk 'NR == 2 {print $NF}')"
[[ -n "$path" ]] || exit 2
lock_dir="${path}.test-flock"

if [[ "$mode" == "unlock" ]]; then
    rm -rf "$lock_dir"
    exit 0
fi

if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$PPID" > "$lock_dir/pid"
    exit 0
fi

owner=""
[[ -r "$lock_dir/pid" ]] && read -r owner < "$lock_dir/pid" || true
if [[ ! "$owner" =~ ^[0-9]+$ ]] || ! kill -0 "$owner" 2>/dev/null; then
    rm -rf "$lock_dir"
    if mkdir "$lock_dir" 2>/dev/null; then
        printf '%s\n' "$PPID" > "$lock_dir/pid"
        exit 0
    fi
fi

exit "$contention_exit"
EOF_FLOCK
    chmod +x "$mock_bin/flock"
    export PATH="$mock_bin:$PATH"
fi

state_dir="$tmpdir/state"
ops_lock="$tmpdir/vaultwarden-operations.lock"
specific_lock="$tmpdir/test-operation.lock"
ready_file="$tmpdir/ready"
holder_fifo="$tmpdir/holder.fifo"
mkfifo "$holder_fifo"

require 'VW_OPERATIONS_LOCK:=/run/lock/vaultwarden-operations\.lock' "$OPS" \
    "canonical global operations lock must be /run/lock/vaultwarden-operations.lock"
reject '\.locks/operations\.lock' "$ROOT/utilities/restore-run.sh" \
    "restore must not use checkout-local operations lock"

VW_OPERATIONS_STATE_DIR="$state_dir" \
VW_OPERATIONS_LOCK="$ops_lock" \
SPECIFIC_LOCK="$specific_lock" \
READY_FILE="$ready_file" \
HOLDER_FIFO="$holder_fifo" \
"${BASH}" -c '
    set -euo pipefail
    source "$0/lib/log.sh"
    source "$0/lib/common.sh"
    init_common_lib test-holder
    source "$0/lib/operations.sh"
    operation_acquire --id holder --label "Held operation" --specific-lock "$SPECIFIC_LOCK"
    operation_set_phase "1" "Holding test lock"
    : > "$READY_FILE"
    exec 9<> "$HOLDER_FIFO"
    while :; do
        read -r -t 1 _ <&9 || true
    done
' "$ROOT" &
holder_pid=$!

for _ in {1..50}; do
    [[ -f "$ready_file" ]] && break
    sleep 0.1
done
[[ -f "$ready_file" ]] || fail "holder operation did not acquire lock"

state_file="$state_dir/holder.state"
[[ -f "$state_file" ]] || fail "operation metadata was not written"
[[ "$(stat -c '%a' "$state_dir" 2>/dev/null || stat -f '%Lp' "$state_dir")" == "700" ]] \
    || fail "operation state directory must be 0700"
[[ "$(stat -c '%a' "$state_file" 2>/dev/null || stat -f '%Lp' "$state_file")" == "600" ]] \
    || fail "operation state file must be 0600"
require '^operation=holder$' "$state_file" "metadata missing operation id"
require '^label=Held operation$' "$state_file" "metadata missing label"
require '^state=running$' "$state_file" "metadata missing running state"
require '^phase=1$' "$state_file" "metadata missing phase"
require '^phase_name=Holding test lock$' "$state_file" "metadata missing phase name"
require '^pid_start=' "$state_file" "metadata must record pid start time for PID reuse checks"

set +e
VW_OPERATIONS_STATE_DIR="$state_dir" \
VW_OPERATIONS_LOCK="$ops_lock" \
VW_OPERATIONS_WAIT_LIMIT=0 \
"${BASH}" -c '
    set -euo pipefail
    source "$0/lib/log.sh"
    source "$0/lib/common.sh"
    init_common_lib test-contender
    source "$0/lib/operations.sh"
    operation_acquire --id contender --label "Contender" --non-interactive skip
' "$ROOT" </dev/null >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 75 ]] || fail "non-interactive contention should cleanly skip with exit 75, got $rc"

kill "$holder_pid"
wait "$holder_pid" 2>/dev/null || true
holder_pid=""

VW_OPERATIONS_STATE_DIR="$state_dir" \
VW_OPERATIONS_LOCK="$ops_lock" \
"${BASH}" -c '
    set -euo pipefail
    source "$0/lib/log.sh"
    source "$0/lib/common.sh"
    init_common_lib test-release
    source "$0/lib/operations.sh"
    operation_acquire --id released --label "Released test"
    operation_set_phase "2" "Reacquired after release"
    operation_release 0
' "$ROOT"

cat > "$state_dir/old.state" <<EOF_STATE
owner=VaultWarden-OCI
operation=old
label=Old interrupted operation
state=running
pid=999999
pid_start=1
started_epoch=1
phase=old
phase_name=Old metadata
lock_path=$ops_lock
token=old-token
EOF_STATE
chmod 600 "$state_dir/old.state"

VW_OPERATIONS_STATE_DIR="$state_dir" \
VW_OPERATIONS_LOCK="$ops_lock" \
"${BASH}" -c '
    set -euo pipefail
    source "$0/lib/log.sh"
    source "$0/lib/common.sh"
    init_common_lib test-stale-meta
    source "$0/lib/operations.sh"
    operation_acquire --id stale-ok --label "Stale metadata does not block"
    operation_release 0
' "$ROOT"

pkg_dir="$tmpdir/package"
mkdir -p "$pkg_dir/bin"
cat > "$pkg_dir/bin/ps" <<'EOF_PS'
#!/usr/bin/env bash
printf '  820 999-00:00:00 unattended-upgr\n'
EOF_PS
chmod +x "$pkg_dir/bin/ps"

SUCCESS_MARKER="$pkg_dir/success" \
PATH="$pkg_dir/bin:$PATH" \
VW_PACKAGE_WAIT_ATTEMPTS=12 \
VW_PACKAGE_WAIT_INTERVAL=0 \
"${BASH}" -c '
    set -euo pipefail
    source "$0/lib/operations.sh"
    operation_package_run bash -c '"'"'printf ran > "$1"'"'"' _ "$SUCCESS_MARKER"
' "$ROOT"
[[ "$(cat "$pkg_dir/success")" == "ran" ]] \
    || fail "unrelated unattended-upgr process-name presence must not block successful package operation"

LOCK_COUNT="$pkg_dir/lock-count" \
VW_PACKAGE_WAIT_ATTEMPTS=3 \
VW_PACKAGE_WAIT_INTERVAL=0 \
"${BASH}" -c '
    set -euo pipefail
    source "$0/lib/operations.sh"
    printf 0 > "$LOCK_COUNT"
    operation_package_run bash -c '"'"'
        count=$(<"$1")
        count=$((count + 1))
        printf "%s" "$count" > "$1"
        if (( count < 2 )); then
            printf "E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 123 (apt)\n" >&2
            exit 100
        fi
        exit 0
    '"'"' _ "$LOCK_COUNT"
' "$ROOT"
[[ "$(cat "$pkg_dir/lock-count")" == "2" ]] \
    || fail "confirmed package lock error must be retried until success"

set +e
LOCK_COUNT="$pkg_dir/bounded-count" \
VW_PACKAGE_WAIT_ATTEMPTS=2 \
VW_PACKAGE_WAIT_INTERVAL=0 \
"${BASH}" -c '
    set -euo pipefail
    source "$0/lib/operations.sh"
    printf 0 > "$LOCK_COUNT"
    operation_package_run bash -c '"'"'
        count=$(<"$1")
        count=$((count + 1))
        printf "%s" "$count" > "$1"
        printf "E: Unable to acquire the dpkg frontend lock (/var/lib/dpkg/lock-frontend), is another process using it?\n" >&2
        exit 100
    '"'"' _ "$LOCK_COUNT"
' "$ROOT" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 100 ]] || fail "bounded package lock retry should return final command status, got $rc"
[[ "$(cat "$pkg_dir/bounded-count")" == "2" ]] \
    || fail "package lock retry must stop at configured attempt limit"

set +e
NONLOCK_COUNT="$pkg_dir/nonlock-count" \
VW_PACKAGE_WAIT_ATTEMPTS=4 \
VW_PACKAGE_WAIT_INTERVAL=0 \
"${BASH}" -c '
    set -euo pipefail
    source "$0/lib/operations.sh"
    printf 0 > "$NONLOCK_COUNT"
    operation_package_run bash -c '"'"'
        count=$(<"$1")
        count=$((count + 1))
        printf "%s" "$count" > "$1"
        printf "E: Unable to locate package definitely-not-real\n" >&2
        exit 42
    '"'"' _ "$NONLOCK_COUNT"
' "$ROOT" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 42 ]] || fail "non-lock package failure should return immediately, got $rc"
[[ "$(cat "$pkg_dir/nonlock-count")" == "1" ]] \
    || fail "non-lock package failure must not be blindly retried"

require '_operation_verify_owner' "$OPS" "operation stop path must verify owner identity"
require 'pid_start' "$OPS" "operation owner verification must guard against PID reuse"
require 'Package manager activity is still active' "$OPS" "conflict UX must detect package-manager activity"
require 'will not automatically terminate apt/dpkg' "$OPS" "apt/dpkg must not be automatically terminated"
require 'was not terminated and no lock files were removed' "$OPS" \
    "package helper must document that apt/dpkg is never killed and lock files are not removed"
require 'operation_package_run' "$CROWDSEC" "CrowdSec apt/dpkg calls must use package-manager wait helper"
require 'operation_set_phase "0" "Resetting installed CrowdSec components"' "$CROWDSEC" \
    "CrowdSec force reset must record Phase 0 before destructive reset"
require 'operation_acquire' "$CROWDSEC" "CrowdSec setup must acquire an operation guard"
reject 'operation_run_without_guard_fds' "$OPS" \
    "operations library must not retain obsolete descriptor-closing wrappers"
require 'if ! _cs_run_external crowdsec -t' "$CROWDSEC" \
    "CrowdSec static validation must run normally under owner-bound operation locks"
require 'crowdsec-setup' "$CROWDSEC" "CrowdSec setup guard must use the crowdsec-setup operation id"
require 'source "\$\{PROJECT_ROOT\}/lib/operations\.sh"' "$CROWDSEC_APPLY" \
    "standalone CrowdSec Worker apply must source operation guards"
require 'operation_acquire' "$CROWDSEC_APPLY" \
    "standalone CrowdSec Worker apply must acquire an operation guard"
require '--id crowdsec-worker-apply' "$CROWDSEC_APPLY" \
    "standalone CrowdSec Worker apply must use its own operation id"
require '--label "CrowdSec Workers config apply"' "$CROWDSEC_APPLY" \
    "standalone CrowdSec Worker apply must expose a clear operation label"
require '--specific-lock /run/lock/vaultwarden-crowdsec-setup\.lock' "$CROWDSEC_APPLY" \
    "standalone CrowdSec Worker apply must coordinate with full CrowdSec setup"
require 'trap _crowdsec_worker_apply_cleanup EXIT' "$CROWDSEC_APPLY" \
    "standalone CrowdSec Worker apply must release on EXIT"
require 'operation_release "\$rc"' "$CROWDSEC_APPLY" \
    "standalone CrowdSec Worker apply EXIT cleanup must preserve status"
require 'operation_release 130; exit 130' "$CROWDSEC_APPLY" \
    "standalone CrowdSec Worker apply must release on INT"
require 'operation_release 143; exit 143' "$CROWDSEC_APPLY" \
    "standalone CrowdSec Worker apply must release on HUP/TERM"
require 'require_root "\$@"' "$CROWDSEC_APPLY" \
    "standalone CrowdSec Worker apply must preserve root-only mutation behavior"
reject '\$FORCE([^A-Za-z0-9_]|$)|--force|--skip-full-verification' "$BACKUP" \
    "backup must not retain removed force/full-verification compatibility state"
reject 'FORCE.*flock|flock.*FORCE|SKIP_OPS_LOCK|--skip-ops-lock' "$BACKUP" \
    "backup must not retain force/skip lock bypass logic"

for svc in "$ROOT"/systemd/vaultwarden-db-backup.service \
           "$ROOT"/systemd/vaultwarden-full-backup.service \
           "$ROOT"/systemd/vaultwarden-maintenance.service; do
    reject '/bin/bash -c .*flock|flock -n|--skip-ops-lock' "$svc" \
        "systemd unit must not duplicate flock wrapper or pass skip flag: $svc"
done

if [[ -r /proc/$$/stat && -z "${mock_bin:-}" ]]; then
    stale_file="$state_dir/crowdsec-setup.state"
    cat > "$stale_file" <<EOF_STATE
owner=VaultWarden-OCI
operation=crowdsec-setup
label=Old shadow operation
state=running
pid=999999
pid_start=1
started_epoch=1
phase=old
phase_name=Old metadata
lock_path=$ops_lock
token=old-token
EOF_STATE
    chmod 600 "$stale_file"

    live_ready="$tmpdir/live-ready"
    live_fifo="$tmpdir/live.fifo"
    mkfifo "$live_fifo"
    VW_OPERATIONS_STATE_DIR="$state_dir" \
    VW_OPERATIONS_LOCK="$ops_lock" \
    LIVE_READY="$live_ready" \
    LIVE_FIFO="$live_fifo" \
    "${BASH}" -c '
        set -euo pipefail
        source "$0/lib/log.sh"
        source "$0/lib/common.sh"
        init_common_lib live-holder
        source "$0/lib/operations.sh"
        operation_acquire --id backup --label "Live backup operation"
        operation_set_phase "3" "Actually holding the lock"
        : > "$LIVE_READY"
        exec 9<> "$LIVE_FIFO"
        while :; do
            read -r -t 1 _ <&9 || true
        done
    ' "$ROOT" &
    live_pid=$!
    cleanup_pids+=("$live_pid")
    for _ in {1..50}; do
        [[ -f "$live_ready" ]] && break
        sleep 0.1
    done
    [[ -f "$live_ready" ]] || fail "live operation did not acquire lock"

    set +e
    conflict_output="$(
        VW_OPERATIONS_STATE_DIR="$state_dir" \
        VW_OPERATIONS_LOCK="$ops_lock" \
        VW_OPERATIONS_WAIT_LIMIT=0 \
        "${BASH}" -c '
            set -euo pipefail
            source "$0/lib/log.sh"
            source "$0/lib/common.sh"
            init_common_lib stale-contender
            source "$0/lib/operations.sh"
            operation_acquire --id contender --label "Contender" --non-interactive skip
        ' "$ROOT" </dev/null 2>&1
    )"
    rc=$?
    set -e
    [[ "$rc" -eq 75 ]] || fail "stale shadow contention should skip with exit 75, got $rc"
    [[ "$conflict_output" == *"Live backup operation"* ]] \
        || fail "verified live operation should be reported when stale metadata also exists"
    [[ "$conflict_output" != *"Old shadow operation"* ]] \
        || fail "stale running metadata must not shadow the verified live operation"
    kill "$live_pid"
    wait "$live_pid" 2>/dev/null || true
    cleanup_pids=("${cleanup_pids[@]/$live_pid}")

    sleep 20 &
    reuse_pid=$!
    cleanup_pids+=("$reuse_pid")
    wrong_identity="${reuse_pid}:0"
    "${BASH}" -c '
        set -euo pipefail
        source "$0/lib/operations.sh"
        _operation_signal_identities TERM "$1"
    ' "$ROOT" "$wrong_identity"
    sleep 0.2
    kill -0 "$reuse_pid" 2>/dev/null \
        || fail "mismatched PID identity must not be signalled by numeric PID alone"
    correct_identity="$(
        "${BASH}" -c '
            set -euo pipefail
            source "$0/lib/operations.sh"
            _operation_pid_identity "$1"
        ' "$ROOT" "$reuse_pid"
    )" || fail "could not capture controlled PID identity"
    "${BASH}" -c '
        set -euo pipefail
        source "$0/lib/operations.sh"
        _operation_signal_identities TERM "$1"
    ' "$ROOT" "$correct_identity"
    for _ in {1..50}; do
        ! kill -0 "$reuse_pid" 2>/dev/null && break
        sleep 0.1
    done
    kill -0 "$reuse_pid" 2>/dev/null \
        && fail "matching PID identity should be signalled"
    wait "$reuse_pid" 2>/dev/null || true
    cleanup_pids=("${cleanup_pids[@]/$reuse_pid}")

    stop_ready="$tmpdir/stop-ready"
    stop_child_pid_file="$tmpdir/stop-child.pid"
    stop_fifo="$tmpdir/stop.fifo"
    mkfifo "$stop_fifo"
    VW_OPERATIONS_STATE_DIR="$state_dir" \
    VW_OPERATIONS_LOCK="$ops_lock" \
    STOP_READY="$stop_ready" \
    STOP_CHILD_PID_FILE="$stop_child_pid_file" \
    STOP_FIFO="$stop_fifo" \
    "${BASH}" -c '
        set -euo pipefail
        source "$0/lib/log.sh"
        source "$0/lib/common.sh"
        init_common_lib stop-holder
        source "$0/lib/operations.sh"
        operation_acquire --id stoptest --label "Stop test operation"
        "${BASH}" -c '"'"'
            stop_child_pid_file="$1"
            stop_ready="$2"
            stop_fifo="$3"
            trap "" TERM
            exec 9<> "$stop_fifo"
            printf "%s\n" "$$" > "$stop_child_pid_file"
            : > "$stop_ready"
            while :; do
                read -r -t 1 _ <&9 || true
            done
        '"'"' _ "$STOP_CHILD_PID_FILE" "$STOP_READY" "$STOP_FIFO" &
        wait "$!"
    ' "$ROOT" &
    stop_parent=$!
    cleanup_pids+=("$stop_parent")
    for _ in {1..50}; do
        [[ -s "$stop_child_pid_file" && -f "$stop_ready" ]] && break
        sleep 0.1
    done
    [[ -s "$stop_child_pid_file" && -f "$stop_ready" ]] || fail "stop test child did not start"
    stop_child="$(cat "$stop_child_pid_file")"
    cleanup_pids+=("$stop_child")
    stop_child_identity="$(
        "${BASH}" -c '
            set -euo pipefail
            source "$0/lib/operations.sh"
            _operation_pid_identity "$1"
        ' "$ROOT" "$stop_child"
    )" || fail "could not capture stop child identity"

    set +e
    VW_OPERATIONS_STATE_DIR="$state_dir" \
    VW_OPERATIONS_LOCK="$ops_lock" \
    VW_OPERATIONS_STOP_GRACE=1 \
    "${BASH}" -c '
        set -euo pipefail
        source "$0/lib/log.sh"
        source "$0/lib/common.sh"
        init_common_lib stop-request
        source "$0/lib/operations.sh"
        _operation_request_stop "$VW_OPERATIONS_STATE_DIR/stoptest.state"
    ' "$ROOT" >/dev/null 2>&1
    rc=$?
    set -e
    [[ "$rc" -ne 0 ]] || fail "graceful stop should fail when an operation child ignores TERM"
    "${BASH}" -c '
        set -euo pipefail
        source "$0/lib/operations.sh"
        _operation_identity_is_live "$1"
    ' "$ROOT" "$stop_child_identity" \
        || fail "graceful stop must leave TERM-ignoring child identity running"
    kill -0 "$stop_parent" 2>/dev/null || fail "graceful stop must leave wrapper running while child remains"

    set +e
    VW_OPERATIONS_STATE_DIR="$state_dir" \
    VW_OPERATIONS_LOCK="$ops_lock" \
    VW_OPERATIONS_WAIT_LIMIT=0 \
    "${BASH}" -c '
        set -euo pipefail
        source "$0/lib/log.sh"
        source "$0/lib/common.sh"
        init_common_lib stop-contender
        source "$0/lib/operations.sh"
        operation_acquire --id contender --label "Contender" --non-interactive skip
    ' "$ROOT" </dev/null >/dev/null 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 75 ]] || fail "contender must remain blocked after failed graceful stop, got $rc"

    printf 'KILL\n' | \
    VW_OPERATIONS_STATE_DIR="$state_dir" \
    VW_OPERATIONS_LOCK="$ops_lock" \
    VW_OPERATIONS_STOP_GRACE=1 \
    VW_OPERATIONS_FORCE_GRACE=1 \
    "${BASH}" -c '
        set -euo pipefail
        source "$0/lib/log.sh"
        source "$0/lib/common.sh"
        init_common_lib force-stop
        source "$0/lib/operations.sh"
        _operation_force_stop "$VW_OPERATIONS_STATE_DIR/stoptest.state"
    ' "$ROOT" >/dev/null 2>&1

    for _ in {1..30}; do
        if ! kill -0 "$stop_parent" 2>/dev/null && ! kill -0 "$stop_child" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done
    kill -0 "$stop_child" 2>/dev/null && fail "force stop did not terminate verified child"
    kill -0 "$stop_parent" 2>/dev/null && fail "force stop did not terminate verified wrapper"
    cleanup_pids=("${cleanup_pids[@]/$stop_parent}")
    cleanup_pids=("${cleanup_pids[@]/$stop_child}")

    VW_OPERATIONS_STATE_DIR="$state_dir" \
    VW_OPERATIONS_LOCK="$ops_lock" \
    "${BASH}" -c '
        set -euo pipefail
        source "$0/lib/log.sh"
        source "$0/lib/common.sh"
        init_common_lib post-force
        source "$0/lib/operations.sh"
        operation_acquire --id post-force --label "Post force acquire"
        operation_release 0
    ' "$ROOT"
fi

if find "$ROOT" \
    -path "$ROOT/.git" -prune -o \
    -path "$ROOT/tests" -prune -o \
    \( -name '*.sh' -o -name Makefile -o -path "$ROOT/systemd/*" -o -path "$ROOT/docs/*" \) \
    -type f -print0 \
  | xargs -0 grep -nE 'If .*lock.*stale|stale lock|remove the lock file|sudo rm -f /run/lock|--skip-ops-lock' >/tmp/vw-lock-guidance.$$; then
    cat /tmp/vw-lock-guidance.$$ >&2
    rm -f /tmp/vw-lock-guidance.$$
    fail "stale-lock removal guidance or public skip flag remains"
fi
rm -f /tmp/vw-lock-guidance.$$

printf 'PASS: operation guard contract\n'

)

check_operation_guard_contracts
check_dns_firewall_contention_contracts() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
DNS="$ROOT/utilities/maintenance-update-dns.sh"
FIREWALL="$ROOT/utilities/maintenance-update-firewall.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require() {
  grep -Eq -- "$1" "$2" || fail "$3"
}

reject() {
  ! grep -Eq -- "$1" "$2" || fail "$3"
}

_extract_func(){
  local file="$1" func="$2"
  awk -v f="$func" '
    $0 ~ "^" f "\\(\\)" {p=1}
    p {
      print
      opens=gsub(/\{/,"{"); closes=gsub(/\}/,"}")
      depth += opens - closes
      if (depth == 0) exit
    }' "$file"
}

_probe_leaf_acquire_rc() {
  local script="$1" acquire_rc="$2" expected="$3" label="$4"
  local tmp probe rc
  tmp="$(mktemp -d)"
  probe="$tmp/probe.sh"
  cat > "$probe" <<EOF_PROBE
set -euo pipefail
DRY_RUN=false
PROJECT_ROOT="$ROOT"
require_root(){ :; }
operation_acquire(){ return "$acquire_rc"; }
operation_release(){ :; }
operation_set_phase(){ :; }
perform_cleanup(){ :; }
_load_env(){ exit 91; }
auto_fix_critical_permissions(){ exit 92; }
update_dns_record(){ exit 93; }
update_firewall_ranges(){ exit 94; }
$(_extract_func "$script" main)
main
EOF_PROBE
  set +e
  bash "$probe" >/dev/null 2>&1
  rc=$?
  set -e
  rm -rf "$tmp"
  [[ "$rc" == "$expected" ]] || fail "$label exited $rc, expected $expected"
}

require '--id dns-update' "$DNS" "DNS updater must use its operation id"
require '--id firewall-update' "$FIREWALL" "firewall updater must use its operation id"
reject 'rc == 75.*exit 0|exit 0.*rc == 75' "$DNS" \
  "DNS updater must not mask operation contention as success"
reject 'rc == 75.*exit 0|exit 0.*rc == 75' "$FIREWALL" \
  "firewall updater must not mask operation contention as success"

_probe_leaf_acquire_rc "$DNS" 75 75 "DNS operation contention"
_probe_leaf_acquire_rc "$FIREWALL" 75 75 "firewall operation contention"
_probe_leaf_acquire_rc "$DNS" 42 42 "DNS operation acquire failure"
_probe_leaf_acquire_rc "$FIREWALL" 42 42 "firewall operation acquire failure"

printf 'PASS: DNS/firewall contention exit contracts\n'

)

check_dns_firewall_contention_contracts
check_operation_descriptor_and_owner_contracts() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
OPS="$ROOT/lib/operations.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$*"
}

require() {
    grep -Eq -- "$1" "$2" || fail "$3"
}

reject() {
    ! grep -Eq -- "$1" "$2" || fail "$3"
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "expected output to contain '$2'; got: $1"
}

assert_not_contains() {
    [[ "$1" != *"$2"* ]] || fail "expected output not to contain '$2'; got: $1"
}

require 'VW_OPERATIONS_PROMPT_TIMEOUT' "$OPS" "operation conflict prompts must have a timeout"
require 'global_lock_owned=' "$OPS" "operation state must record explicit global lock ownership"
require '_operation_state_global_owned' "$OPS" "global owner lookup must require explicit global ownership"
require 'holder_pid=' "$OPS" "operation state must record the owner-bound lock holder identity"
require '_operation_lock_holder' "$OPS" "operation locks must be owned by a narrow holder"
require '_operation_parse_proc_stat' "$OPS" "operation process identity must use the hardened proc-stat parser"
reject 'awk .*print \$22' "$OPS" "operation identity must not parse proc stat using naive whitespace fields"
reject 'VW_OPERATION_INHERITED_FD' "$OPS" "raw operation lock descriptors must not be inherited"
reject 'OPERATION_LOCK_FD' "$OPS" "the workload shell must not own the global operation lock descriptor"
reject 'OPERATION_SPECIFIC_LOCK_FD' "$OPS" "the workload shell must not own a specific operation lock descriptor"
reject 'operation_run_without_guard_fds' "$OPS" "descriptor-closing wrappers must be obsolete"
require 'LC_ALL=C "\$@"' "$OPS" "package helper must run wrapped command with deterministic C locale"
require 'add-apt-repository|apt-add-repository' "$OPS" "package child detection must include repository helpers"
require 'operation_package_run add-apt-repository -y universe' "$ROOT/utilities/setup-system.sh" \
    "add-apt-repository must be routed through operation_package_run"

tmpdir="$(mktemp -d)"
cleanup() {
    [[ -n "${child_pid:-}" ]] && kill "$child_pid" 2>/dev/null || true
    [[ -n "${owner_pid:-}" ]] && kill "$owner_pid" 2>/dev/null || true
    [[ -n "${owner_launcher_pid:-}" ]] && kill "$owner_launcher_pid" 2>/dev/null || true
    [[ -n "${lock_holder_pid:-}" ]] && kill "$lock_holder_pid" 2>/dev/null || true
    [[ -n "${nested_lock_holder_pid:-}" ]] && kill "$nested_lock_holder_pid" 2>/dev/null || true
    [[ -n "${holder_pid:-}" ]] && kill "$holder_pid" 2>/dev/null || true
    [[ -n "${nonglobal_pid:-}" ]] && kill "$nonglobal_pid" 2>/dev/null || true
    rm -rf "$tmpdir"
}
trap cleanup EXIT

lc_file="$tmpdir/lc-all"
LC_ALL=fr_FR.UTF-8 "$BASH" -c '
    set -euo pipefail
    source "$1"
    operation_package_run bash -c '"'"'printf "%s" "$LC_ALL" > "$1"'"'"' _ "$2"
' _ "$OPS" "$lc_file"
[[ "$(cat "$lc_file")" == "C" ]] || fail "operation_package_run did not force LC_ALL=C for child command"

proc_tail='S 42 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 12345'
for proc_name in \
    'name with spaces' \
    'name)with)paren' \
    'name with spaces)and)paren'; do
    parsed="$(
        "$BASH" -c '
            set -euo pipefail
            source "$1"
            _operation_parse_proc_stat "$2"
        ' _ "$OPS" "123 (${proc_name}) ${proc_tail}"
    )"
    [[ "$parsed" == $'S\t42\t12345' ]] \
        || fail "proc stat parser mishandled process name '${proc_name}': ${parsed}"
done
if "$BASH" -c '
    set -euo pipefail
    source "$1"
    _operation_parse_proc_stat "$2"
' _ "$OPS" "123 (zombie) ${proc_tail/S/Z}" >/dev/null 2>&1; then
    fail "proc stat parser accepted a zombie identity"
fi
if "$BASH" -c '
    set -euo pipefail
    source "$1"
    _operation_parse_proc_stat "malformed stat record"
' _ "$OPS" >/dev/null 2>&1; then
    fail "proc stat parser accepted malformed input"
fi

if [[ "$(uname -s)" != "Linux" || ! -r /proc/$$/stat ]] || ! command -v flock >/dev/null 2>&1; then
    pass "operation descriptor and ownership static checks; Linux flock/proc behavioral checks skipped on this host"
    exit 0
fi

state_dir="$tmpdir/state"
ops_lock="$tmpdir/vaultwarden-operations.lock"

run_ops_shell() {
    VW_OPERATIONS_STATE_DIR="$state_dir" \
    VW_OPERATIONS_LOCK="$ops_lock" \
    "$BASH" "$@"
}

pid_has_inode() {
    local pid="$1" expected="$2" fd actual
    for fd in "/proc/${pid}/fd/"*; do
        [[ -e "$fd" ]] || continue
        actual="$(stat -Lc '%d:%i' "$fd" 2>/dev/null || true)"
        [[ "$actual" == "$expected" ]] && return 0
    done
    return 1
}

infra_bin="$tmpdir/infra-bin"
mkdir -p "$infra_bin"
cat > "$infra_bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 64
EOF
chmod +x "$infra_bin/flock"
set +e
infra_output="$(
    PATH="$infra_bin:$PATH" run_ops_shell -c '
        set -euo pipefail
        source "$1/lib/log.sh"
        source "$1/lib/common.sh"
        init_common_lib acquisition-infra
        source "$1/lib/operations.sh"
        operation_acquire --id acquisition-infra --label "Acquisition infrastructure"
    ' _ "$ROOT" 2>&1
)"
infra_rc=$?
set -e
[[ "$infra_rc" -eq 1 ]] || fail "unexpected global flock failure must be an infrastructure error"
assert_contains "$infra_output" "Global operation flock failed unexpectedly with status 64"

specific_infra_bin="$tmpdir/specific-infra-bin"
specific_infra_count="$tmpdir/specific-infra-count"
mkdir -p "$specific_infra_bin"
cat > "$specific_infra_bin/flock" <<'EOF'
#!/usr/bin/env bash
count=0
[[ ! -f "$VW_TEST_FLOCK_COUNT" ]] || read -r count < "$VW_TEST_FLOCK_COUNT"
count=$((count + 1))
printf '%s\n' "$count" > "$VW_TEST_FLOCK_COUNT"
[[ "$count" -eq 1 ]] && exit 0
exit 64
EOF
chmod +x "$specific_infra_bin/flock"
set +e
specific_infra_output="$(
    VW_TEST_FLOCK_COUNT="$specific_infra_count" \
    PATH="$specific_infra_bin:$PATH" \
    run_ops_shell -c '
        set -euo pipefail
        source "$1/lib/log.sh"
        source "$1/lib/common.sh"
        init_common_lib specific-acquisition-infra
        source "$1/lib/operations.sh"
        operation_acquire \
            --id specific-acquisition-infra \
            --label "Specific acquisition infrastructure" \
            --specific-lock "$2"
    ' _ "$ROOT" "$tmpdir/specific-infra.lock" 2>&1
)"
specific_infra_rc=$?
set -e
[[ "$specific_infra_rc" -eq 1 ]] || fail "unexpected specific flock failure must be an infrastructure error"
assert_contains "$specific_infra_output" "Specific operation flock failed unexpectedly with status 64"
assert_not_contains "$specific_infra_output" "Another Specific acquisition infrastructure operation is already running"

set +e
malformed_ready_output="$(
    run_ops_shell -c '
        set -euo pipefail
        source "$1/lib/log.sh"
        source "$1/lib/common.sh"
        init_common_lib malformed-ready
        source "$1/lib/operations.sh"
        _operation_lock_holder() {
            printf "malformed\n"
            read -r _ || true
        }
        operation_acquire --id malformed-ready --label "Malformed readiness"
    ' _ "$ROOT" 2>&1
)"
malformed_ready_rc=$?
set -e
[[ "$malformed_ready_rc" -eq 1 ]] || fail "malformed holder readiness must be an infrastructure error"
assert_contains "$malformed_ready_output" "Operation lock holder returned a malformed readiness response."

owner_ready="$tmpdir/owner-death.ready"
child_ready="$tmpdir/arbitrary-child.ready"
child_pid_file="$tmpdir/arbitrary-child.pid"
specific_lock="$tmpdir/owner-death-specific.lock"
run_ops_shell -c '
    set -euo pipefail
    root="$1"; owner_ready="$2"; child_ready="$3"; child_pid_file="$4"; specific_lock="$5"
    source "$root/lib/log.sh"
    source "$root/lib/common.sh"
    init_common_lib owner-death
    source "$root/lib/operations.sh"
    operation_acquire \
        --id owner-death \
        --label "Owner death" \
        --specific-lock "$specific_lock"
    "$BASH" -c '"'"'
        set -euo pipefail
        child_ready="$1"; child_pid_file="$2"
        trap "" HUP TERM
        printf "%s\n" "$$" > "$child_pid_file"
        : > "$child_ready"
        while :; do sleep 1; done
    '"'"' _ "$child_ready" "$child_pid_file" &
    : > "$owner_ready"
    while :; do sleep 1; done
' _ "$ROOT" "$owner_ready" "$child_ready" "$child_pid_file" "$specific_lock" &
owner_launcher_pid=$!

for _ in {1..100}; do
    [[ -f "$owner_ready" && -f "$child_ready" && -s "$child_pid_file" ]] && break
    sleep 0.1
done
[[ -f "$owner_ready" && -f "$child_ready" && -s "$child_pid_file" ]] \
    || fail "owner-death regression did not reach ready state"
child_pid="$(cat "$child_pid_file")"
owner_state="$state_dir/owner-death.state"
owner_pid="$(awk -F= '$1 == "pid" { print $2; exit }' "$owner_state")"
[[ "$owner_pid" =~ ^[0-9]+$ ]] || fail "operation state did not record the owner PID"
lock_holder_pid="$(awk -F= '$1 == "holder_pid" { print $2; exit }' "$owner_state")"
[[ "$lock_holder_pid" =~ ^[0-9]+$ ]] || fail "operation state did not record a lock holder PID"
global_identity="$(stat -Lc '%d:%i' "$ops_lock")"
specific_identity="$(stat -Lc '%d:%i' "$specific_lock")"

kill -KILL "$owner_pid"
set +e
wait "$owner_launcher_pid" 2>/dev/null
set -e
owner_pid=""
owner_launcher_pid=""

for _ in {1..20}; do
    if ! kill -0 "$lock_holder_pid" 2>/dev/null; then
        break
    fi
    holder_state="$(ps -o stat= -p "$lock_holder_pid" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$holder_state" == Z* ]] && break
    sleep 0.1
done
kill -0 "$child_pid" 2>/dev/null || fail "owner SIGKILL terminated the arbitrary child"
pid_has_inode "$child_pid" "$global_identity" \
    && fail "arbitrary child retained the global operation lock inode"
pid_has_inode "$child_pid" "$specific_identity" \
    && fail "arbitrary child retained the operation-specific lock inode"
if kill -0 "$lock_holder_pid" 2>/dev/null; then
    holder_state="$(ps -o stat= -p "$lock_holder_pid" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$holder_state" == Z* ]] || fail "owner-bound lock holder survived owner death"
fi
lock_holder_pid=""

set +e
timeout 2 env \
    VW_OPERATIONS_STATE_DIR="$state_dir" \
    VW_OPERATIONS_LOCK="$ops_lock" \
    SPECIFIC_LOCK="$specific_lock" \
    "$BASH" -c '
        set -euo pipefail
        root="$1"
        source "$root/lib/log.sh"
        source "$root/lib/common.sh"
        init_common_lib owner-death-contender
        source "$root/lib/operations.sh"
        operation_acquire \
            --id owner-death-contender \
            --label "Owner death contender" \
            --specific-lock "$SPECIFIC_LOCK" \
            --non-interactive skip
        operation_release 0
    ' _ "$ROOT" </dev/null >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "contender did not acquire both locks within two seconds; rc=$rc"
[[ "$(stat -Lc '%d:%i' "$ops_lock")" == "$global_identity" ]] \
    || fail "global operation lock pathname was deleted or replaced"
[[ "$(stat -Lc '%d:%i' "$specific_lock")" == "$specific_identity" ]] \
    || fail "operation-specific lock pathname was deleted or replaced"
kill -0 "$child_pid" 2>/dev/null || fail "arbitrary child did not remain alive after contender acquisition"
kill "$child_pid" 2>/dev/null || true
wait "$child_pid" 2>/dev/null || true
child_pid=""

nested_ready="$tmpdir/nested.ready"
nested_stop="$tmpdir/nested.stop"
nested_phase_trigger="$tmpdir/nested-phase.trigger"
nested_phase_result="$tmpdir/nested-phase.result"
run_ops_shell -c '
    set -euo pipefail
    root="$1"; nested_ready="$2"; nested_stop="$3"
    nested_phase_trigger="$4"; nested_phase_result="$5"
    source "$root/lib/log.sh"
    source "$root/lib/common.sh"
    init_common_lib nested-parent
    source "$root/lib/operations.sh"
    operation_acquire --id nested-parent --label "Nested parent"
    "$BASH" -c '"'"'
        set -euo pipefail
        root="$1"; nested_ready="$2"
        source "$root/lib/log.sh"
        source "$root/lib/common.sh"
        init_common_lib nested-child
        source "$root/lib/operations.sh"
        operation_acquire --id nested-child --label "Nested child"
        operation_set_phase nested "Nested foreground operation"
        operation_release 0
        : > "$nested_ready"
    '"'"' _ "$root" "$nested_ready"
    phase_checked=false
    while [[ ! -f "$nested_stop" ]]; do
        if [[ "$phase_checked" == "false" && -f "$nested_phase_trigger" ]]; then
            set +e
            operation_set_phase after-holder-loss "Must fail closed"
            phase_rc=$?
            set -e
            printf "%s\n" "$phase_rc" > "$nested_phase_result"
            phase_checked=true
        fi
        sleep 0.1
    done
    operation_release 0
' _ "$ROOT" "$nested_ready" "$nested_stop" "$nested_phase_trigger" "$nested_phase_result" &
holder_pid=$!
for _ in {1..100}; do [[ -f "$nested_ready" ]] && break; sleep 0.1; done
[[ -f "$nested_ready" ]] || fail "valid nested foreground operation was rejected"

set +e
run_ops_shell -c '
    set -euo pipefail
    root="$1"
    source "$root/lib/log.sh"
    source "$root/lib/common.sh"
    init_common_lib nested-contender
    source "$root/lib/operations.sh"
    operation_acquire --id contender --label "Contender" --non-interactive skip
' _ "$ROOT" </dev/null >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 75 ]] || fail "valid nested operation released the parent global lock; contender rc=$rc"

set +e
forged_output="$(
    VW_OPERATIONS_STATE_DIR="$state_dir" \
    VW_OPERATIONS_LOCK="$ops_lock" \
    VW_OPERATION_PARENT_STATE="$state_dir/nested-parent.state" \
    VW_OPERATION_PARENT_TOKEN="forged-token" \
    VW_OPERATION_PARENT_ID="nested-parent" \
    run_ops_shell -c '
        set -euo pipefail
        root="$1"
        source "$root/lib/log.sh"
        source "$root/lib/common.sh"
        init_common_lib forged-nested
        source "$root/lib/operations.sh"
        operation_acquire --id forged-nested --label "Forged nested" --non-interactive skip
    ' _ "$ROOT" </dev/null 2>&1
)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "forged inherited operation metadata returned $rc instead of failing closed"
[[ "$forged_output" == *"Inherited operation ownership metadata could not be verified"* ]] \
    || fail "forged inherited operation metadata failure was not diagnosed"

nested_lock_holder_pid="$(
    awk -F= '$1 == "holder_pid" { print $2; exit }' "$state_dir/nested-parent.state"
)"
[[ "$nested_lock_holder_pid" =~ ^[0-9]+$ ]] || fail "nested parent holder identity is missing"
kill -KILL "$nested_lock_holder_pid"
for _ in {1..20}; do
    ! kill -0 "$nested_lock_holder_pid" 2>/dev/null && break
    sleep 0.1
done
nested_lock_holder_pid=""
: > "$nested_phase_trigger"
for _ in {1..50}; do [[ -s "$nested_phase_result" ]] && break; sleep 0.1; done
[[ -s "$nested_phase_result" ]] || fail "phase boundary did not report lock-infrastructure loss"
[[ "$(<"$nested_phase_result")" -ne 0 ]] \
    || fail "phase boundary succeeded after verified lock-infrastructure death"

: > "$nested_stop"
set +e
wait "$holder_pid"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "operation release succeeded after lock-infrastructure death"
holder_pid=""

owner_ready="$tmpdir/owner.ready"
owner_fifo="$tmpdir/owner.fifo"
mkfifo "$owner_fifo"
run_ops_shell -c '
    set -euo pipefail
    root="$1"; ready="$2"; fifo="$3"
    source "$root/lib/log.sh"
    source "$root/lib/common.sh"
    init_common_lib global-owner
    source "$root/lib/operations.sh"
    operation_acquire --id restore --label "Restore A"
    : > "$ready"
    exec 9<> "$fifo"
    while :; do read -r -t 1 _ <&9 || true; done
' _ "$ROOT" "$owner_ready" "$owner_fifo" &
holder_pid=$!
for _ in {1..100}; do [[ -f "$owner_ready" ]] && break; sleep 0.1; done
[[ -f "$owner_ready" ]] || fail "global owner did not start"

specific="$tmpdir/non-global.lock"
nonglobal_ready="$tmpdir/non-global.ready"
nonglobal_fifo="$tmpdir/non-global.fifo"
mkfifo "$nonglobal_fifo"
run_ops_shell -c '
    set -euo pipefail
    root="$1"; specific="$2"; ready="$3"; fifo="$4"
    source "$root/lib/log.sh"
    source "$root/lib/common.sh"
    init_common_lib nonglobal
    source "$root/lib/operations.sh"
    operation_acquire --id health-check --label "Non-global B" --no-global --specific-lock "$specific"
    : > "$ready"
    exec 9<> "$fifo"
    while :; do read -r -t 1 _ <&9 || true; done
' _ "$ROOT" "$specific" "$nonglobal_ready" "$nonglobal_fifo" &
nonglobal_pid=$!
for _ in {1..100}; do [[ -f "$nonglobal_ready" ]] && break; sleep 0.1; done
[[ -f "$nonglobal_ready" ]] || fail "non-global operation did not start"

set +e
owner_output="$(
    run_ops_shell -c '
        set -euo pipefail
        root="$1"
        source "$root/lib/log.sh"
        source "$root/lib/common.sh"
        init_common_lib owner-contender
        source "$root/lib/operations.sh"
        operation_acquire --id contender --label "Contender" --non-interactive skip
    ' _ "$ROOT" </dev/null 2>&1
)"
rc=$?
set -e
[[ "$rc" -eq 75 ]] || fail "global contender should skip with active owner, got $rc"
[[ "$owner_output" == *"Restore A"* ]] || fail "global contender did not attribute verified global owner"
[[ "$owner_output" != *"Non-global B"* ]] || fail "global contender incorrectly attributed non-global operation"

kill "$holder_pid" "$nonglobal_pid" 2>/dev/null || true
wait "$holder_pid" "$nonglobal_pid" 2>/dev/null || true
holder_pid=""
nonglobal_pid=""

same_state_dir="$tmpdir/same-state"
same_lock="$tmpdir/same-specific.lock"
same_ready="$tmpdir/same.ready"
same_fifo="$tmpdir/same.fifo"
mkfifo "$same_fifo"
VW_OPERATIONS_STATE_DIR="$same_state_dir" \
VW_OPERATIONS_LOCK="$tmpdir/same-global.lock" \
SPECIFIC_LOCK="$same_lock" \
READY="$same_ready" \
FIFO="$same_fifo" \
"$BASH" -c '
    set -euo pipefail
    root="$1"
    source "$root/lib/log.sh"
    source "$root/lib/common.sh"
    init_common_lib same-a
    source "$root/lib/operations.sh"
    operation_acquire --id same-id --label "Same ID A" --no-global --specific-lock "$SPECIFIC_LOCK"
    operation_set_phase "hold" "Holding same ID"
    : > "$READY"
    exec 9<> "$FIFO"
    while :; do read -r -t 1 _ <&9 || true; done
' _ "$ROOT" &
holder_pid=$!
for _ in {1..100}; do [[ -f "$same_ready" ]] && break; sleep 0.1; done
[[ -f "$same_ready" ]] || fail "same-ID holder did not start"
same_state="$same_state_dir/same-id.state"
before="$(cat "$same_state")"

set +e
VW_OPERATIONS_STATE_DIR="$same_state_dir" \
VW_OPERATIONS_LOCK="$tmpdir/same-global.lock" \
SPECIFIC_LOCK="$same_lock" \
"$BASH" -c '
    set -euo pipefail
    root="$1"
    source "$root/lib/log.sh"
    source "$root/lib/common.sh"
    init_common_lib same-b
    source "$root/lib/operations.sh"
    operation_acquire --id same-id --label "Same ID B" --no-global --specific-lock "$SPECIFIC_LOCK"
' _ "$ROOT" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "same-ID contender unexpectedly acquired duplicate specific lock"
after="$(cat "$same_state")"
[[ "$before" == "$after" ]] || fail "same-ID losing contender overwrote active owner state"

kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
holder_pid=""

pass "operation descriptor and ownership contracts"

)

check_operation_descriptor_and_owner_contracts
check_health_operation_contract() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
HEALTH="$ROOT/utilities/maintenance-health.sh"
CONFIG="$ROOT/lib/config.sh"
UNIT="$ROOT/systemd/vaultwarden-health.service"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require() {
  grep -Eq -- "$1" "$2" || fail "$3"
}

reject() {
  ! grep -Eq -- "$1" "$2" || fail "$3"
}

require '_acquire_health_lock' "$HEALTH" \
  "every health invocation must use its direct health-specific flock"
reject '--no-global' "$HEALTH" \
  "health locking must not use operation_acquire --no-global"
require '--id health-repair' "$HEALTH" \
  "health --fix must use the global health-repair operation"
reject '--specific-lock /run/lock/vaultwarden-health\.lock' "$HEALTH" \
  "health --fix must not delegate health-lock ownership to the operation guard"
require 'return "\$lock_rc"' "$HEALTH" \
  "health lock acquisition failures must preserve their real status"
require 'health --fix requires root' "$HEALTH" \
  "health repair mode must remain root-operated"
require 'return 4' "$HEALTH" \
  "health --fix guard infrastructure failures must be real failures"
reject 'maintenance-health\.sh must be run as root' "$CONFIG" \
  "config loading must not block documented non-root read-only health"
require '^SuccessExitStatus=0 1 75$' "$UNIT" \
  "health unit must treat warnings and contention as success, but not prerequisite failures"
reject '^SuccessExitStatus=.*(^| )3( |$)' "$UNIT" \
  "health prerequisite exit 3 must remain a real systemd failure"

printf 'PASS: health operation contract\n'

)

check_health_operation_contract
check_health_quick_profile_contract() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
HEALTH="$ROOT/utilities/maintenance-health.sh"
SECRETS="$ROOT/lib/secrets.sh"
TMP="$(mktemp -d -t vw-health-quick.XXXXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

extract_func() {
    local file="$1" func="$2"
    awk -v f="$func" '
        $0 ~ "^" f "\\(\\)" {p=1}
        p {
            print
            opens=gsub(/\{/, "{")
            closes=gsub(/\}/, "}")
            depth += opens - closes
            if (depth == 0) exit
        }
    ' "$file"
}

# The secrets library no longer mutates a caller-owned generic SCRIPT_DIR.
! grep -Eq '^[[:space:]]*SCRIPT_DIR=' "$SECRETS" \
    || fail 'lib/secrets.sh must not assign generic SCRIPT_DIR'
! grep -Fq '_SAVE_SCRIPT_DIR' "$HEALTH" \
    || fail 'health retained the obsolete SCRIPT_DIR save/restore workaround'
! grep -Fq '_health_json_escape' "$HEALTH" \
    || fail 'health retained its incomplete private JSON escape helper'
grep -Fq '$(_json_escape "$message")' "$HEALTH" \
    || fail 'health JSON must reuse the robust repository helper'

main_probe="$TMP/main-probe.bash"
cat > "$main_probe" <<'EOF_MAIN'
#!/usr/bin/env bash
set -uo pipefail
QUICK=false
COMPREHENSIVE=false
FIX_MODE=false
REPORT_MODE=false
QUIET=false
JSON_OUTPUT=false
failed="${TEST_FAILED:-0}"
warnings="${TEST_WARNINGS:-0}"
trace(){ printf '%s\n' "$1" >>"${TRACE_FILE:?}"; }
log_error(){ printf '%s\n' "$*" >&2; }
log_info(){ :; }
_health_show_help(){ :; }
_acquire_run_lock(){ trace acquire; return "${LOCK_RC:-0}"; }
_release_run_lock(){ return 0; }
_collect_quick_compose_snapshot(){ trace compose_snapshot; return "${SNAPSHOT_RC:-0}"; }
_check_quick_containers(){ trace quick_containers; }
_check_containers(){ trace containers; }
_check_ssl(){ trace ssl; }
_check_vaultwarden_alive(){ trace alive; }
_check_vaultwarden_server_info(){ trace server_info; }
_check_caddy_storage_permissions(){ trace caddy_permissions; }
_check_crowdsec(){ trace crowdsec; }
_check_crowdsec_email_notifications(){ trace crowdsec_email; }
_check_disk(){ trace disk; }
_check_memory(){ trace memory; }
_check_network(){ trace network; }
_check_smtp(){ trace smtp; }
_check_dns(){ trace dns; }
_check_quick_backups(){ trace quick_backups; }
_check_backups(){ trace backups; }
_check_config(){ trace config; }
_check_quick_postfix(){ trace quick_postfix; }
_check_notify_failures(){ trace notify_dead_letter; }
_check_container_resources(){ trace container_resources; }
_fix_unhealthy_containers(){ trace fix_containers; }
_incident_update_unhealthy(){ trace incident_update; }
_print_results_json(){ trace print_json; }
_print_results(){ trace print_results; }
_generate_report(){ trace report; }
_notify_failures(){ trace notify_failures; }
_notify_recovery(){ trace notify_recovery; }
EOF_MAIN
extract_func "$HEALTH" _health_parse_args >> "$main_probe"
extract_func "$HEALTH" _health_main >> "$main_probe"
cat >> "$main_probe" <<'EOF_MAIN'
_health_main "$@"
EOF_MAIN
chmod 0700 "$main_probe"

set +e
TRACE_FILE="$TMP/conflict.trace" "$BASH" "$main_probe" --quick --comprehensive >"$TMP/conflict.out" 2>&1
conflict_rc=$?
TRACE_FILE="$TMP/quick-report.trace" "$BASH" "$main_probe" --quick --report >"$TMP/quick-report.out" 2>&1
quick_report_rc=$?
set -e
[[ "$conflict_rc" -ne 0 ]] || fail 'conflicting quick/comprehensive profiles must fail'
grep -Fq 'health profiles conflict' "$TMP/conflict.out" \
    || fail 'profile conflict must be actionable'
[[ "$quick_report_rc" -ne 0 ]] \
    || fail 'quick report request must fail rather than generate a report'

quick_trace="$TMP/quick.trace"
set +e
TRACE_FILE="$quick_trace" "$BASH" "$main_probe" --quick
quick_rc=$?
set -e
[[ "$quick_rc" -eq 0 ]] || fail "clean quick profile must exit 0, got $quick_rc"
cat > "$TMP/quick.expected" <<'EOF_EXPECTED'
acquire
compose_snapshot
quick_containers
alive
server_info
disk
memory
quick_backups
quick_postfix
notify_dead_letter
print_results
EOF_EXPECTED
cmp -s "$quick_trace" "$TMP/quick.expected" \
    || { diff -u "$TMP/quick.expected" "$quick_trace" >&2 || true; fail 'quick profile called checks outside its local contract'; }

standard_trace="$TMP/standard.trace"
set +e
TRACE_FILE="$standard_trace" "$BASH" "$main_probe"
standard_rc=$?
set -e
[[ "$standard_rc" -eq 0 ]] || fail "clean standard profile must exit 0, got $standard_rc"
for required in containers ssl alive server_info caddy_permissions crowdsec crowdsec_email disk memory network smtp dns backups config notify_dead_letter incident_update notify_failures notify_recovery; do
    grep -Fxq "$required" "$standard_trace" || fail "standard profile lost check: $required"
done
for excluded in compose_snapshot quick_containers quick_backups quick_postfix; do
    ! grep -Fxq "$excluded" "$standard_trace" || fail "standard profile unexpectedly called quick-only helper: $excluded"
done

set +e
TRACE_FILE="$TMP/warn.trace" TEST_WARNINGS=1 "$BASH" "$main_probe" --quick
warn_rc=$?
TRACE_FILE="$TMP/prereq.trace" SNAPSHOT_RC=3 "$BASH" "$main_probe" --quick
prereq_rc=$?
TRACE_FILE="$TMP/skip.trace" LOCK_RC=75 "$BASH" "$main_probe" --quick
skip_rc=$?
set -e
[[ "$warn_rc" -eq 1 ]] || fail "advisory quick warning must remain exit 1, got $warn_rc"
[[ "$prereq_rc" -eq 3 ]] || fail "quick prerequisite failure must be exit 3, got $prereq_rc"
[[ "$skip_rc" -eq 75 ]] || fail "duplicate quick run must remain clean exit 75, got $skip_rc"
grep -Fq 'if $FIX_MODE && [[ $failed -gt 0 ]]; then' "$HEALTH" \
    || fail 'selected check failures must enter the shared bounded repair path'
grep -A3 -F 'if $FIX_MODE && [[ $failed -gt 0 ]]; then' "$HEALTH" | grep -Fq '_fix_unhealthy_containers' \
    || fail 'shared health repair path must call bounded container repair'
! grep -Fxq quick_containers "$TMP/prereq.trace" \
    || fail 'quick checks ran after the Compose prerequisite failed'

snapshot_probe="$TMP/snapshot-probe.bash"
cat > "$snapshot_probe" <<'EOF_SNAPSHOT'
#!/usr/bin/env bash
set -euo pipefail
HEALTH_TIMEOUT=10
QUICK_COMPOSE_SNAPSHOT=""
VW_SMTP_HOST=postfix
require_jq(){ return 0; }
log_error(){ printf '%s\n' "$*" >&2; }
log_info(){ :; }
_pass(){ printf 'pass:%s:%s\n' "$1" "$2" >>"${RESULTS:?}"; }
_warn(){ printf 'warn:%s:%s\n' "$1" "$2" >>"${RESULTS:?}"; }
_fail(){ printf 'fail:%s:%s\n' "$1" "$2" >>"${RESULTS:?}"; }
timeout(){ shift; "$@"; }
EOF_SNAPSHOT
extract_func "$HEALTH" _postfix_sidecar_configured >> "$snapshot_probe"
extract_func "$HEALTH" _collect_quick_compose_snapshot >> "$snapshot_probe"
extract_func "$HEALTH" _check_quick_containers >> "$snapshot_probe"
cat >> "$snapshot_probe" <<'EOF_SNAPSHOT'
_collect_quick_compose_snapshot
_check_quick_containers
EOF_SNAPSHOT
chmod 0700 "$snapshot_probe"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF_DOCKER'
#!/usr/bin/env bash
count=0
[[ -f "${DOCKER_COUNT:?}" ]] && count="$(cat "$DOCKER_COUNT")"
printf '%s\n' "$(( count + 1 ))" >"$DOCKER_COUNT"
printf '%s\n' "$*" >"${DOCKER_ARGS:?}"
printf '%s\n' "$PWD" >"${DOCKER_PWD:?}"
printf '%s\n' '[{"Name":"vaultwarden_app","Service":"vaultwarden","State":"running","Health":"healthy"},{"Name":"vaultwarden_caddy_run_1","Service":"caddy","State":"exited","Health":""},{"Name":"vaultwarden_caddy","Service":"caddy","State":"running","Health":"healthy"},{"Name":"vaultwarden_postfix","Service":"postfix","State":"exited","Health":""}]'
EOF_DOCKER
chmod 0700 "$TMP/bin/docker"
installed_runtime="$TMP/opt/vaultwarden-scripts"
mkdir -p "$installed_runtime"
(
    cd "$installed_runtime"
    PATH="$TMP/bin:$PATH" \
    DOCKER_COUNT="$TMP/docker.count" \
    DOCKER_ARGS="$TMP/docker.args" \
    DOCKER_PWD="$TMP/docker.pwd" \
    RESULTS="$TMP/snapshot.results" \
        "$BASH" "$snapshot_probe"
)
[[ "$(cat "$TMP/docker.count")" == 1 ]] \
    || fail 'quick profile must collect Docker Compose state exactly once'
[[ "$(cat "$TMP/docker.args")" == 'compose --project-name vaultwarden-oci ps --all --format json' ]] \
    || fail "quick Compose snapshot did not select the canonical project with --all: $(cat "$TMP/docker.args")"
[[ "$(cat "$TMP/docker.pwd")" == "$installed_runtime" ]] \
    || fail 'quick Compose snapshot did not run from the empty installed-runtime fixture'
[[ -z "$(find "$installed_runtime" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || fail 'installed-runtime snapshot fixture unexpectedly contained a Compose file'
[[ "$(grep -c '^pass:container:' "$TMP/snapshot.results")" -eq 2 ]] \
    || fail 'quick Compose snapshot did not select the running managed containers'
grep -Fq 'pass:container:vaultwarden_caddy:vaultwarden_caddy is running (health: healthy)' \
    "$TMP/snapshot.results" \
    || fail 'quick Compose snapshot selected a one-off container instead of the exact managed Caddy container'
! grep -Fq 'fail:container:vaultwarden_caddy:' "$TMP/snapshot.results" \
    || fail 'one-off Caddy state was attributed to the managed Caddy container'
grep -Fq 'fail:container:vaultwarden_postfix:Container not running: vaultwarden_postfix (state: exited)' \
    "$TMP/snapshot.results" \
    || fail 'quick Compose snapshot did not preserve stopped-container state'

repair_probe="$TMP/repair-probe.bash"
cat > "$repair_probe" <<'EOF_REPAIR'
#!/usr/bin/env bash
set -euo pipefail
ALERT_LOCK_DIR="${ALERT_LOCK_DIR:?}"
MAX_AUTO_RESTARTS=1
RESTART_COUNT_WINDOW_HOURS=6
check_order=(container:vaultwarden_app)
declare -A check_results=([container:vaultwarden_app]=fail)
log_info(){ :; }
log_warn(){ :; }
log_error(){ :; }
_warn(){ :; }
sleep(){ :; }
EOF_REPAIR
extract_func "$HEALTH" _fix_unhealthy_containers >> "$repair_probe"
cat >> "$repair_probe" <<'EOF_REPAIR'
_fix_unhealthy_containers
_fix_unhealthy_containers
EOF_REPAIR
cat > "$TMP/bin/docker" <<'EOF_REPAIR_DOCKER'
#!/usr/bin/env bash
count=0
[[ -f "${RESTART_COUNT:?}" ]] && count="$(cat "$RESTART_COUNT")"
printf '%s\n' "$(( count + 1 ))" >"$RESTART_COUNT"
exit 0
EOF_REPAIR_DOCKER
chmod 0700 "$TMP/bin/docker" "$repair_probe"
PATH="$TMP/bin:$PATH" ALERT_LOCK_DIR="$TMP/repair-state" RESTART_COUNT="$TMP/restart.count" \
    "$BASH" "$repair_probe"
[[ "$(cat "$TMP/restart.count")" == 1 ]] \
    || fail 'quick container repair must remain bounded by the restart limit'

printf 'PASS: quick health profile and exit contract\n'
)

check_health_quick_profile_contract
check_secrets_env_systemd_operation_guards() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require() {
  grep -Eq -- "$1" "$2" || fail "$3"
}

reject() {
  ! grep -Eq -- "$1" "$2" || fail "$3"
}

line_no() {
  grep -n -- "$1" "$2" | head -1 | cut -d: -f1
}

SETUP_SECRETS="$ROOT/utilities/setup-secrets.sh"
SECRETS_EDIT="$ROOT/utilities/secrets-edit.sh"
SECRETS_ROTATE="$ROOT/utilities/secrets-rotate.sh"
ENV_EDIT="$ROOT/utilities/env-edit.sh"
SETUP_ENV="$ROOT/utilities/setup-env.sh"
SETUP_SYSTEMD="$ROOT/utilities/setup-systemd.sh"
IPTABLES_UNIT="$ROOT/systemd/vaultwarden-iptables.service"

for file in "$SETUP_SECRETS" "$SECRETS_EDIT" "$SECRETS_ROTATE"; do
  require 'lib/operations\.sh|source "\$\{PROJECT_ROOT\}/lib/operations\.sh"' "$file" \
    "secrets mutator must source operation library: $file"
  require '--id secrets' "$file" "secrets mutator must use secrets operation id: $file"
  require '--specific-lock /run/lock/vaultwarden-secrets\.lock' "$file" \
    "secrets mutator must use secrets-specific lock: $file"
done

edit_guard_line="$(line_no 'operation_acquire' "$SECRETS_EDIT")"
edit_sops_line="$(line_no 'sops -d' "$SECRETS_EDIT")"
[[ -n "$edit_guard_line" && -n "$edit_sops_line" && "$edit_guard_line" -lt "$edit_sops_line" ]] \
  || fail "secrets-edit must acquire guard before decrypting"

rotate_guard_line="$(line_no 'operation_acquire' "$SECRETS_ROTATE")"
rotate_sops_line="$(line_no 'sops -d' "$SECRETS_ROTATE")"
[[ -n "$rotate_guard_line" && -n "$rotate_sops_line" && "$rotate_guard_line" -lt "$rotate_sops_line" ]] \
  || fail "secrets-rotate must acquire guard before decrypting"

require '_setup_secrets_should_guard' "$SETUP_SECRETS" \
  "setup-secrets must distinguish mutating and read-only breakglass actions"
require 'status\).*SHOW_STATUS' "$SETUP_SECRETS" \
  "setup-secrets breakglass status must remain a read-only action"

require '--id env-sync' "$ENV_EDIT" "env-edit mutating paths must use env-sync operation id"
require '--specific-lock /run/lock/vaultwarden-env\.lock' "$ENV_EDIT" \
  "env-edit sync/edit must use env-specific lock"
require '_cmd_status "\$@"' "$ENV_EDIT" "env-edit status must remain available"

require '--id env-sync' "$SETUP_ENV" "setup-env direct mutation must use env-sync operation id"
reject '--specific-lock /run/lock/vaultwarden-env\.lock' "$SETUP_ENV" \
  "setup-env parent must not hold env-specific lock before nested env-edit sync"
require 'utilities/env-edit\.sh" sync' "$SETUP_ENV" \
  "setup-env must keep nested env sync under inherited global lock"

require '--id systemd-install' "$SETUP_SYSTEMD" \
  "setup-systemd install/remove must use systemd-install operation id"
require '--specific-lock /run/lock/vaultwarden-systemd\.lock' "$SETUP_SYSTEMD" \
  "setup-systemd must use systemd-specific lock"
require 'utilities/setup-firewall\.sh' "$SETUP_SYSTEMD" \
  "setup-systemd must preserve structured setup-firewall utility path"
reject 'script" == "utilities/setup-firewall\.sh"' "$SETUP_SYSTEMD" \
  "setup-systemd must not flat-install setup-firewall.sh"

require '^ExecStart=/bin/bash /opt/vaultwarden-scripts/utilities/setup-firewall\.sh --phase iptables --auto$' "$IPTABLES_UNIT" \
  "iptables unit must invoke structured installed setup-firewall path with --auto"
reject '^SuccessExitStatus=.*75' "$IPTABLES_UNIT" \
  "iptables unit must not treat operation contention as successful boot reconciliation"
require '^ReadWritePaths=.*/run/lock' "$IPTABLES_UNIT" \
  "iptables unit must expose operation lock path"
require '^ReadWritePaths=.*/run/vaultwarden-oci' "$IPTABLES_UNIT" \
  "iptables unit must expose operation state path"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/opt/vaultwarden-scripts"
cp -R "$ROOT/lib" "$tmp/opt/vaultwarden-scripts/lib"
mkdir -p "$tmp/opt/vaultwarden-scripts/utilities"
cp "$ROOT/utilities/setup-firewall.sh" "$tmp/opt/vaultwarden-scripts/utilities/setup-firewall.sh"
if (( BASH_VERSINFO[0] >= 4 )); then
  "$BASH" "$tmp/opt/vaultwarden-scripts/utilities/setup-firewall.sh" --help >/dev/null
else
  printf 'SKIP: installed setup-firewall help smoke requires Bash 4+ for repo libraries\n'
fi

printf 'PASS: secrets/env/systemd operation guards\n'

)

check_secrets_env_systemd_operation_guards

check_operation_lock_file_preparation() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
OPS="$ROOT/lib/operations.sh"
TMP="$(mktemp -d -t vw-operation-lock-policy.XXXXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }
skip(){ printf 'SKIP: %s\n' "$*"; }

case_index=0
run_source_order_case() {
    local source_order="$1" group_state="$2" expected_group="$3"
    local case_dir mock_bin lock state chown_log mode owner output rc
    case_index=$((case_index + 1))
    case_dir="$TMP/source-order-$case_index"
    mock_bin="$case_dir/bin"
    lock="$case_dir/locks/test.lock"
    state="$case_dir/state"
    chown_log="$case_dir/chown.log"
    mkdir -p "$mock_bin"
    if [[ "$source_order" == normal && "$group_state" == available ]]; then
        mkdir -p "$(dirname "$lock")"
        : >"$lock"
        chmod 0600 "$lock"
    fi

    cat >"$mock_bin/getent" <<'EOF_GETENT'
#!/usr/bin/env bash
[[ "${VW_TEST_GROUP_STATE:?}" == available && "${1:-}" == group && "${2:-}" == vaultwarden ]]
EOF_GETENT
    cat >"$mock_bin/chown" <<'EOF_CHOWN'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${VW_TEST_CHOWN_LOG:?}"
EOF_CHOWN
    cat >"$mock_bin/chmod" <<EOF_CHMOD
#!/usr/bin/env bash
exec "$(command -v chmod)" "\$@"
EOF_CHMOD
    cat >"$mock_bin/flock" <<'EOF_FLOCK'
#!/usr/bin/env bash
exit 0
EOF_FLOCK
    chmod +x "$mock_bin"/*

    set +e
    output=$(PATH="$mock_bin:$PATH" \
        VW_TEST_GROUP_STATE="$group_state" \
        VW_TEST_CHOWN_LOG="$chown_log" \
        VW_OPERATIONS_STATE_DIR="$state" \
        VW_OPERATIONS_LOCK="$case_dir/global.lock" \
        VW_TEST_SOURCE_ORDER="$source_order" \
        VW_TEST_LOCK="$lock" \
        "$BASH" -c '
            set -euo pipefail
            root="$1"
            if [[ "$VW_TEST_SOURCE_ORDER" == normal ]]; then
                source "$root/lib/log.sh"
                source "$root/lib/common.sh"
                init_common_lib operation-lock-policy-test
            fi
            source "$root/lib/operations.sh"
            operation_acquire \
                --id "lock-policy-${VW_TEST_SOURCE_ORDER}-${VW_TEST_GROUP_STATE}" \
                --label "Lock policy" \
                --no-global \
                --specific-lock "$VW_TEST_LOCK"
            operation_release 0
        ' _ "$ROOT" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -eq 0 ]] || fail "$source_order/$group_state acquisition failed: $output"

    mode="$(stat -c '%a' "$lock" 2>/dev/null || stat -f '%Lp' "$lock")"
    [[ "$mode" == 660 ]] || fail "$source_order/$group_state lock mode is $mode, expected 660"
    owner="$(stat -c '%U:%G' "$lock" 2>/dev/null || stat -f '%Su:%Sg' "$lock")"
    if [[ "$owner" != "root:${expected_group}" ]]; then
        grep -Fq "root:${expected_group} $lock" "$chown_log" \
            || fail "$source_order/$group_state did not select root:${expected_group}: $(cat "$chown_log" 2>/dev/null || true)"
    fi
}

run_source_order_case standalone available vaultwarden
run_source_order_case normal available vaultwarden
run_source_order_case standalone unavailable root
run_source_order_case normal unavailable root
pass "standalone and normal source orders select the same 0660 ownership policy"

root_exec=()
if [[ "$(uname -s)" == Linux ]]; then
    if (( EUID == 0 )); then
        root_exec=("$BASH")
    elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        root_exec=(sudo -n "$BASH")
    fi
fi

if (( ${#root_exec[@]} > 0 )); then
    root_case_script="$TMP/root-lock-cases.bash"
    cat >"$root_case_script" <<'EOF_ROOT_CASES'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
case_root="$2"
ops="$root/lib/operations.sh"
mkdir -p "$case_root"

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

(
    getent(){ return 2; }
    source "$ops"
    lock="$case_root/group-unavailable.lock"
    : >"$lock"
    chmod 0600 "$lock"
    chown root:root "$lock"
    _operation_prepare_lock_file "$lock"
    actual="$(stat -c '%U:%G %a' "$lock")"
    [[ "$actual" == 'root:root 660' ]] \
        || fail "group-unavailable lock is '$actual', expected 'root:root 660'"
    printf 'PASS: root group-unavailable path applies actual root:root mode 0660\n'
)

(
    if ! getent group vaultwarden >/dev/null 2>&1; then
        printf 'SKIP: actual root:vaultwarden assertion (safe pre-existing vaultwarden group is unavailable)\n'
        exit 0
    fi
    source "$ops"
    lock="$case_root/group-available.lock"
    : >"$lock"
    chmod 0600 "$lock"
    chown root:root "$lock"
    _operation_prepare_lock_file "$lock"
    actual="$(stat -c '%U:%G %a' "$lock")"
    [[ "$actual" == 'root:vaultwarden 660' ]] \
        || fail "group-available lock is '$actual', expected 'root:vaultwarden 660'"
    printf 'PASS: safe pre-existing vaultwarden group applies actual root:vaultwarden mode 0660\n'
)

(
    getent(){ return 2; }
    source "$ops"
    lock="$case_root/chown-failure.lock"
    : >"$lock"
    chmod 0600 "$lock"
    real_chown="$(type -P chown)"
    "$real_chown" 65534:65534 "$lock"
    chown(){ return 1; }
    set +e
    output="$(_operation_prepare_lock_file "$lock" 2>&1)"
    rc=$?
    set -e
    [[ "$rc" -ne 0 ]] || fail "root-side chown failure unexpectedly succeeded"
    [[ "$output" == *"Cannot set operation lock ownership to root:root"* ]] \
        || fail "root-side chown failure omitted ownership diagnostic: $output"
    [[ "$output" == *"Fix: sudo chown root:root"* ]] \
        || fail "root-side chown failure omitted remediation: $output"
    printf 'PASS: root-side chown failure rejects lock preparation with actionable diagnostics\n'
)
EOF_ROOT_CASES
    chmod +x "$root_case_script"
    root_output="$TMP/root-cases.out"
    if ! "${root_exec[@]}" "$root_case_script" "$ROOT" "$TMP/root-cases" >"$root_output" 2>&1; then
        cat "$root_output" >&2
        fail "root-capable lock ownership cases failed"
    fi
    cat "$root_output"
    if (( EUID != 0 )); then
        sudo -n rm -rf "$TMP/root-cases"
    fi
else
    skip "root lock ownership/mode and root-side chown-failure cases require Linux root or passwordless sudo"
fi

nonroot_runner=()
nonroot_name=""
if (( EUID != 0 )); then
    nonroot_runner=("$BASH")
    nonroot_name="$(id -un)"
elif command -v runuser >/dev/null 2>&1 && id nobody >/dev/null 2>&1; then
    nonroot_runner=(runuser -u nobody -- "$BASH")
    nonroot_name=nobody
elif command -v sudo >/dev/null 2>&1 && id nobody >/dev/null 2>&1 \
    && sudo -n -u nobody true >/dev/null 2>&1; then
    nonroot_runner=(sudo -n -u nobody "$BASH")
    nonroot_name=nobody
fi

if (( ${#nonroot_runner[@]} > 0 )); then
    chmod 0755 "$TMP"
    nonroot_dir="$TMP/nonroot-case"
    mkdir -p "$nonroot_dir"
    if (( EUID == 0 )); then
        nonroot_group="$(id -gn "$nonroot_name")"
        chown "$nonroot_name:$nonroot_group" "$nonroot_dir"
        chmod 0700 "$nonroot_dir"
    fi
    nonroot_script="$TMP/nonroot-lock-case.bash"
    cat >"$nonroot_script" <<'EOF_NONROOT_CASE'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
case_dir="$2"
getent(){ return 2; }
source "$root/lib/operations.sh"
lock="$case_dir/nonroot.lock"
: >"$lock"
chmod 0600 "$lock"
set +e
output="$(_operation_prepare_lock_file "$lock" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { printf 'FAIL: non-root fallback returned %s: %s\n' "$rc" "$output" >&2; exit 1; }
mode="$(stat -c '%a' "$lock" 2>/dev/null || stat -f '%Lp' "$lock")"
[[ "$mode" == 660 ]] || { printf 'FAIL: non-root fallback mode is %s\n' "$mode" >&2; exit 1; }
[[ "$output" == *"without root privileges"* ]] \
    || { printf 'FAIL: non-root ownership warning missing: %s\n' "$output" >&2; exit 1; }
printf 'PASS: non-root lock preparation retains mode 0660 and actionable ownership warning\n'
EOF_NONROOT_CASE
    chmod 0755 "$nonroot_script"
    nonroot_output="$TMP/nonroot.out"
    if ! "${nonroot_runner[@]}" "$nonroot_script" "$ROOT" "$nonroot_dir" >"$nonroot_output" 2>&1; then
        cat "$nonroot_output" >&2
        fail "non-root lock preparation fallback case failed"
    fi
    cat "$nonroot_output"
else
    skip "non-root lock preparation warning case requires a non-root runner"
fi

diagnostic_dir="$TMP/not-a-directory"
: >"$diagnostic_dir"
set +e
diagnostic=$(VW_OPERATIONS_STATE_DIR="$TMP/diagnostic-state" \
    VW_OPERATIONS_LOCK="$TMP/diagnostic-global.lock" \
    VW_TEST_LOCK="$diagnostic_dir/test.lock" \
    "$BASH" -c '
        set -euo pipefail
        source "$1/lib/operations.sh"
        _operation_prepare_lock_file "$VW_TEST_LOCK"
    ' _ "$ROOT" 2>&1)
diagnostic_rc=$?
set -e
[[ "$diagnostic_rc" -ne 0 ]] || fail "standalone lock preparation unexpectedly succeeded for an invalid parent"
[[ "$diagnostic" == *"Cannot create operation lock directory"* ]] \
    || fail "standalone diagnostic is not actionable: $diagnostic"
[[ "$diagnostic" == *"Fix: sudo mkdir -p"* ]] \
    || fail "standalone diagnostic omitted remediation: $diagnostic"
pass "standalone preparation failures emit actionable diagnostics"

! grep -Fq '_ensure_lock_file' "$ROOT/lib/operations.sh" "$ROOT/lib/common.sh" \
    || fail "source-order lock helper remains"
! grep -Fq 'chmod 0600 "$lock_path"' "$OPS" \
    || fail "independent 0600 lock fallback remains"
pass "operations remains the canonical lock-file preparation owner"
)

check_operation_lock_file_preparation
