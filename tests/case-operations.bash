#!/usr/bin/env bash
# Consolidated operations regression suite.
set -euo pipefail

check_operation_guard_contracts() (
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
case "${1:-}" in
    -n) shift ;;
    -u) mode="unlock"; shift ;;
esac

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

exit 1
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
require '--force does not bypass active VaultWarden operation guards' "$BACKUP" \
    "backup --force must not bypass operation guards"
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

    child_ready="$tmpdir/child-ready"
    child_pid_file="$tmpdir/child.pid"
    child_marker="$tmpdir/child-contender-entered"
    child_fifo="$tmpdir/child.fifo"
    mkfifo "$child_fifo"
    VW_OPERATIONS_STATE_DIR="$state_dir" \
    VW_OPERATIONS_LOCK="$ops_lock" \
    CHILD_READY="$child_ready" \
    CHILD_PID_FILE="$child_pid_file" \
    CHILD_FIFO="$child_fifo" \
    "${BASH}" -c '
        set -euo pipefail
        source "$0/lib/log.sh"
        source "$0/lib/common.sh"
        init_common_lib orphan-parent
        source "$0/lib/operations.sh"
        operation_acquire --id orphan --label "Orphan child lock"
        operation_set_phase "4" "Child inherited lock"
        "${BASH}" -c '"'"'
            child_pid_file="$1"
            child_ready="$2"
            child_fifo="$3"
            trap "" HUP
            exec 9<> "$child_fifo"
            printf "%s\n" "$$" > "$child_pid_file"
            : > "$child_ready"
            while :; do
                read -r -t 1 _ <&9 || true
            done
        '"'"' _ "$CHILD_PID_FILE" "$CHILD_READY" "$CHILD_FIFO" &
        for _ in {1..100}; do
            [[ -s "$CHILD_PID_FILE" && -f "$CHILD_READY" ]] && break
            sleep 0.1
        done
        [[ -s "$CHILD_PID_FILE" && -f "$CHILD_READY" ]] || exit 1
        kill -KILL "$$"
    ' "$ROOT" >/dev/null 2>&1 &
    orphan_parent=$!
    wait "$orphan_parent" 2>/dev/null || true
    for _ in {1..50}; do
        [[ -s "$child_pid_file" ]] && break
        sleep 0.1
    done
    [[ -s "$child_pid_file" ]] || fail "inherited-lock child did not start"
    orphan_child="$(cat "$child_pid_file")"
    cleanup_pids+=("$orphan_child")

    set +e
    orphan_output="$(
        VW_OPERATIONS_STATE_DIR="$state_dir" \
        VW_OPERATIONS_LOCK="$ops_lock" \
        VW_OPERATIONS_WAIT_LIMIT=0 \
        CHILD_MARKER="$child_marker" \
        "${BASH}" -c '
            set -euo pipefail
            source "$0/lib/log.sh"
            source "$0/lib/common.sh"
            init_common_lib orphan-contender
            source "$0/lib/operations.sh"
            operation_acquire --id contender --label "Contender" --non-interactive skip
            : > "$CHILD_MARKER"
        ' "$ROOT" </dev/null 2>&1
    )"
    rc=$?
    set -e
    [[ "$rc" -eq 75 ]] || fail "inherited child lock should block contender with exit 75, got $rc"
    [[ ! -f "$child_marker" ]] || fail "contender entered while inherited-lock child still held the lock"
    [[ "$orphan_output" == *"owning operation metadata could not be verified"* ]] \
        || fail "dead parent with inherited child lock must be reported as unverified metadata"
    [[ "$orphan_output" != *"Orphan child lock"* ]] \
        || fail "dead parent metadata must not be reported as the verified active owner"
    kill "$orphan_child" 2>/dev/null || true
    for _ in {1..50}; do
        ! kill -0 "$orphan_child" 2>/dev/null && break
        sleep 0.1
    done
    if kill -0 "$orphan_child" 2>/dev/null; then
        child_state="$(ps -o stat= -p "$orphan_child" 2>/dev/null | tr -d '[:space:]' || true)"
        [[ "$child_state" == Z* ]] \
            || fail "inherited-lock child did not stop during cleanup"
    fi
    cleanup_pids=("${cleanup_pids[@]/$orphan_child}")

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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

require 'VW_OPERATIONS_PROMPT_TIMEOUT' "$OPS" "operation conflict prompts must have a timeout"
require 'global_lock_owned=' "$OPS" "operation state must record explicit global lock ownership"
require '_operation_state_global_owned' "$OPS" "global owner lookup must require explicit global ownership"
reject 'flock -u "\$OPERATION_LOCK_FD"' "$OPS" "global operation release must not explicitly LOCK_UN inherited fd"
require 'last inherited descriptor closes' "$OPS" "global release must document descriptor lifetime semantics"
require 'LC_ALL=C "\$@"' "$OPS" "package helper must run wrapped command with deterministic C locale"
require 'add-apt-repository|apt-add-repository' "$OPS" "package child detection must include repository helpers"
require 'operation_package_run add-apt-repository -y universe' "$ROOT/utilities/setup-system.sh" \
    "add-apt-repository must be routed through operation_package_run"

tmpdir="$(mktemp -d)"
cleanup() {
    [[ -n "${child_pid:-}" ]] && kill "$child_pid" 2>/dev/null || true
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

ready="$tmpdir/child.ready"
stop="$tmpdir/child.stop"
pid_file="$tmpdir/child.pid"
run_ops_shell -c '
    set -euo pipefail
    root="$1"; ready="$2"; stop="$3"; pid_file="$4"
    source "$root/lib/log.sh"
    source "$root/lib/common.sh"
    init_common_lib inherited-parent
    source "$root/lib/operations.sh"
    operation_acquire --id inherited-parent --label "Inherited parent"
    "$BASH" -c '"'"'
        set -euo pipefail
        root="$1"; ready="$2"; stop="$3"; pid_file="$4"
        source "$root/lib/log.sh"
        source "$root/lib/common.sh"
        init_common_lib inherited-child
        source "$root/lib/operations.sh"
        operation_acquire --id inherited-child --label "Inherited child"
        printf "%s\n" "$$" > "$pid_file"
        : > "$ready"
        while [[ ! -f "$stop" ]]; do sleep 0.1; done
        operation_release 0
    '"'"' _ "$root" "$ready" "$stop" "$pid_file" &
    for _ in {1..100}; do
        [[ -f "$ready" ]] && break
        sleep 0.1
    done
    [[ -f "$ready" ]] || exit 1
    operation_release 0
' _ "$ROOT" "$ready" "$stop" "$pid_file"

for _ in {1..100}; do
    [[ -s "$pid_file" ]] && break
    sleep 0.1
done
[[ -s "$pid_file" ]] || fail "inherited child did not start"
child_pid="$(cat "$pid_file")"

set +e
run_ops_shell -c '
    set -euo pipefail
    root="$1"
    source "$root/lib/log.sh"
    source "$root/lib/common.sh"
    init_common_lib inherited-contender
    source "$root/lib/operations.sh"
    operation_acquire --id contender --label "Contender" --non-interactive skip
' _ "$ROOT" </dev/null >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 75 ]] || fail "inherited child must retain global lock after parent release; contender rc=$rc"

: > "$stop"
for _ in {1..100}; do
    ! kill -0 "$child_pid" 2>/dev/null && break
    sleep 0.1
done
if kill -0 "$child_pid" 2>/dev/null; then
    child_state="$(ps -o stat= -p "$child_pid" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$child_state" == Z* ]] || fail "inherited child did not exit"
fi
child_pid=""

run_ops_shell -c '
    set -euo pipefail
    root="$1"
    source "$root/lib/log.sh"
    source "$root/lib/common.sh"
    init_common_lib inherited-post
    source "$root/lib/operations.sh"
    operation_acquire --id post-inherited --label "Post inherited"
    operation_release 0
' _ "$ROOT"

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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

require '_acquire_readonly_health_lock' "$HEALTH" \
  "read-only health must use direct health-specific flock"
reject '--no-global' "$HEALTH" \
  "read-only health must not use operation_acquire --no-global"
require '--id health-repair' "$HEALTH" \
  "health --fix must use the global health-repair operation"
require 'return "\$lock_rc"' "$HEALTH" \
  "health lock acquisition failures must preserve their real status"
require 'health --fix requires root' "$HEALTH" \
  "health repair mode must remain root-operated"
require 'return 4' "$HEALTH" \
  "health --fix guard infrastructure failures must be real failures"
reject 'maintenance-health\.sh must be run as root' "$CONFIG" \
  "config loading must not block documented non-root read-only health"
require '^SuccessExitStatus=0 1 3 75$' "$UNIT" \
  "health unit must treat expected contention 75 as success, but not all failures"

printf 'PASS: health operation contract\n'

)

check_health_operation_contract
check_secrets_env_systemd_operation_guards() (
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
require '^SuccessExitStatus=0 75$' "$IPTABLES_UNIT" \
  "iptables unit must treat expected contention as success"
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
