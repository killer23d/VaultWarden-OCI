#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPS="$ROOT/lib/operations.sh"
BACKUP="$ROOT/utilities/backup-run.sh"
CROWDSEC="$ROOT/utilities/setup-crowdsec.sh"

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

require 'VW_OPERATIONS_LOCK:=/run/lock/vaultwarden-operations\.lock' "$OPS" \
    "canonical global operations lock must be /run/lock/vaultwarden-operations.lock"
reject '\.locks/operations\.lock' "$ROOT/utilities/restore-run.sh" \
    "restore must not use checkout-local operations lock"

VW_OPERATIONS_STATE_DIR="$state_dir" \
VW_OPERATIONS_LOCK="$ops_lock" \
SPECIFIC_LOCK="$specific_lock" \
READY_FILE="$ready_file" \
"${BASH}" -c '
    set -euo pipefail
    source "$0/lib/log.sh"
    source "$0/lib/common.sh"
    init_common_lib test-holder
    source "$0/lib/operations.sh"
    operation_acquire --id holder --label "Held operation" --specific-lock "$SPECIFIC_LOCK"
    operation_set_phase "1" "Holding test lock"
    : > "$READY_FILE"
    sleep 20
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
    VW_OPERATIONS_STATE_DIR="$state_dir" \
    VW_OPERATIONS_LOCK="$ops_lock" \
    LIVE_READY="$live_ready" \
    "${BASH}" -c '
        set -euo pipefail
        source "$0/lib/log.sh"
        source "$0/lib/common.sh"
        init_common_lib live-holder
        source "$0/lib/operations.sh"
        operation_acquire --id backup --label "Live backup operation"
        operation_set_phase "3" "Actually holding the lock"
        : > "$LIVE_READY"
        sleep 20
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
    VW_OPERATIONS_STATE_DIR="$state_dir" \
    VW_OPERATIONS_LOCK="$ops_lock" \
    CHILD_READY="$child_ready" \
    CHILD_PID_FILE="$child_pid_file" \
    "${BASH}" -c '
        set -euo pipefail
        source "$0/lib/log.sh"
        source "$0/lib/common.sh"
        init_common_lib orphan-parent
        source "$0/lib/operations.sh"
        operation_acquire --id orphan --label "Orphan child lock"
        operation_set_phase "4" "Child inherited lock"
        "${BASH}" -c '"'"'trap "" TERM; printf "%s\n" "$$" > "$CHILD_PID_FILE"; : > "$CHILD_READY"; sleep 20'"'"' &
        for _ in {1..50}; do
            [[ -f "$CHILD_READY" ]] && break
            sleep 0.1
        done
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
    wait "$orphan_child" 2>/dev/null || true
    cleanup_pids=("${cleanup_pids[@]/$orphan_child}")

    stop_ready="$tmpdir/stop-ready"
    stop_child_pid_file="$tmpdir/stop-child.pid"
    VW_OPERATIONS_STATE_DIR="$state_dir" \
    VW_OPERATIONS_LOCK="$ops_lock" \
    STOP_READY="$stop_ready" \
    STOP_CHILD_PID_FILE="$stop_child_pid_file" \
    "${BASH}" -c '
        set -euo pipefail
        source "$0/lib/log.sh"
        source "$0/lib/common.sh"
        init_common_lib stop-holder
        source "$0/lib/operations.sh"
        operation_acquire --id stoptest --label "Stop test operation"
        "${BASH}" -c '"'"'trap "" TERM; printf "%s\n" "$$" > "$STOP_CHILD_PID_FILE"; : > "$STOP_READY"; sleep 20'"'"' &
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
    kill -0 "$stop_child" 2>/dev/null || fail "graceful stop must leave TERM-ignoring child running"
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

if rg -n --glob '*.sh' --glob '!tests/**' --glob 'Makefile' --glob 'systemd/**' --glob 'docs/**' \
    'If .*lock.*stale|stale lock|remove the lock file|sudo rm -f /run/lock|--skip-ops-lock' "$ROOT" >/tmp/vw-lock-guidance.$$; then
    cat /tmp/vw-lock-guidance.$$ >&2
    rm -f /tmp/vw-lock-guidance.$$
    fail "stale-lock removal guidance or public skip flag remains"
fi
rm -f /tmp/vw-lock-guidance.$$

printf 'PASS: operation guard contract\n'
