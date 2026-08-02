#!/usr/bin/env bash

# Focused structural coverage for helpers made obsolete by owner-bound locking.
# Owner-death and arbitrary-child behavior lives in case-operations.bash.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

ROOT="$VW_TEST_REPO_ROOT"
LOG_LIB="$ROOT/lib/log.sh"
OPS_LIB="$ROOT/lib/operations.sh"
HEALTH="$ROOT/utilities/maintenance-health.sh"
SYSTEMD_SETUP="$ROOT/utilities/setup-systemd.sh"
CROWDSEC_WORKER_LIB="$ROOT/lib/crowdsec-worker.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

spinner_block="$(sed -n '/^spinner_start()/,/^spinner_stop()/p' "$LOG_LIB")"
for variable in \
    OPERATION_SPECIFIC_LOCK_FD \
    OPERATION_LOCK_FD \
    VW_OPERATION_INHERITED_FD; do
    if grep -Fq "$variable" "$LOG_LIB"; then
        fail "logging library must not know repository lock variable ${variable}"
    fi
done
grep -Fq 'local health_fd="${HEALTH_LOCK_FD:-}"' <<< "$spinner_block" \
    || fail "spinner must preserve health lock isolation"
grep -Fq 'eval "exec ${health_fd}>&-"' <<< "$spinner_block" \
    || fail "spinner child must close the health lock descriptor"

if grep -Fq '_crowdsec_worker_run_without_guard_fds' "$CROWDSEC_WORKER_LIB"; then
    fail "CrowdSec worker library retained obsolete operation descriptor isolation"
fi
grep -Fq 'if "$bouncer_bin" -S -c "$dest"; then' "$CROWDSEC_WORKER_LIB" \
    || fail "autonomous CrowdSec Workers deployment must run normally under owner-bound locking"

grep -Fq '_operation_prepare_lock_file "$VW_OPERATIONS_LOCK"' "$OPS_LIB" \
    || fail "operations library must prepare the global mutation lock at runtime"
grep -Fq '_operation_prepare_lock_file "$specific_lock"' "$OPS_LIB" \
    || fail "operations library must prepare operation-specific mutation locks at runtime"
if grep -Fq "Run 'sudo utilities/setup-systemd.sh install' to create the group" "$OPS_LIB"; then
    fail "operations library must not claim the installer creates the optional lock group"
fi

for obsolete in \
    '_ensure_runtime_lock_files' \
    '_ensure_lock_group' \
    '_resolve_service_identity' \
    '_install_service_identity_dropin' \
    'groupadd --system' \
    'usermod -aG'; do
    if grep -Fq "$obsolete" "$SYSTEMD_SETUP"; then
        fail "systemd installer still manages shared lock identity: ${obsolete}"
    fi
done
if grep -Eq 'chown .*vaultwarden.*lock|chmod 0?660 .*lock' "$SYSTEMD_SETUP"; then
    fail "systemd installer still changes operation lock ownership or mode"
fi

grep -Fq 'operation_acquire \' "$HEALTH" \
    || fail "health --fix must acquire the existing operation guard"
if grep -A5 -F 'operation_acquire \' "$HEALTH" | grep -Fq -- '--specific-lock'; then
    fail "health --fix must not delegate its health lock to the operation guard"
fi
grep -Fq 'if _acquire_health_lock; then' "$HEALTH" \
    || fail "every health invocation must acquire its own health lock first"
grep -Fq '(set -o noclobber; : >"$lock_path")' "$HEALTH" \
    || fail "health lock creation must not truncate an existing path"
grep -Fq 'if [[ "$owner_uid" != "$EUID" ]]' "$HEALTH" \
    || fail "health locking must reject files owned by another execution identity"
grep -Fq 'flock -n -E 75 "$fd"' "$HEALTH" \
    || fail "health lock acquisition must distinguish contention from flock failure"
grep -Fq '[[ -L "$lock_path" || ( -e "$lock_path" && ! -f "$lock_path" ) ]]' "$HEALTH" \
    || fail "health lock preparation must reject symlinks and non-regular targets"
grep -Fq "trap '_release_run_lock 130; exit 130' INT" "$HEALTH" \
    || fail "health INT cleanup must release locks and terminate"
grep -Fq "trap '_release_run_lock 143; exit 143' HUP TERM" "$HEALTH" \
    || fail "health HUP/TERM cleanup must release locks and terminate"

TMP="$(mktemp -d)"
cleanup() {
    [[ -n "${holder_pid:-}" ]] && kill "$holder_pid" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

HELPERS="$TMP/health-lock-helpers.bash"
{
    cat <<'EOF_HELPER'
HEALTH_LOCK_FD=""
HEALTH_OPERATION_GUARD_HELD=false
FIX_MODE=false
log_error() { printf 'ERROR %s\n' "$*" >&2; }
log_warn() { printf 'WARN %s\n' "$*" >&2; }
operation_acquire() { return 0; }
operation_set_phase() { return 0; }
operation_release() { return 0; }
EOF_HELPER
    sed -n '/^_health_lock_path()/,/^local ALERT_LOCK_DIR=/p' "$HEALTH" | sed '$d'
} > "$HELPERS"

LOCK="$TMP/health.lock"
READY="$TMP/holder.ready"
VW_HEALTH_LOCK_FILE="$LOCK" READY="$READY" bash -c '
    set -euo pipefail
    source "$1"
    _acquire_run_lock
    trap "_release_run_lock" EXIT
    trap "_release_run_lock 143; exit 143" TERM
    : > "$READY"
    while :; do sleep 1; done
' _ "$HELPERS" &
holder_pid=$!
for _ in {1..50}; do
    [[ -f "$READY" ]] && break
    sleep 0.1
done
[[ -f "$READY" ]] || fail "health lock holder did not start"

set +e
VW_HEALTH_LOCK_FILE="$LOCK" bash -c '
    set -euo pipefail
    source "$1"
    _acquire_run_lock
' _ "$HELPERS" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 75 ]] || fail "two health commands on one path must not overlap; got $rc"

kill -TERM "$holder_pid"
set +e
wait "$holder_pid"
rc=$?
set -e
holder_pid=""
[[ "$rc" -eq 143 ]] || fail "terminated health holder must preserve TERM status; got $rc"
VW_HEALTH_LOCK_FILE="$LOCK" bash -c '
    set -euo pipefail
    source "$1"
    _acquire_run_lock
    _release_run_lock 0
' _ "$HELPERS" || fail "health lock was not released after termination"

set +e
VW_HEALTH_LOCK_FILE="$TMP/fix-contention.lock" bash -c '
    set -euo pipefail
    source "$1"
    FIX_MODE=true
    operation_acquire() { return 75; }
    _acquire_run_lock
' _ "$HELPERS" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 75 ]] || fail "global mutation contention must remain exit 75; got $rc"
VW_HEALTH_LOCK_FILE="$TMP/fix-contention.lock" bash -c '
    set -euo pipefail
    source "$1"
    _acquire_health_lock
    _release_health_lock
' _ "$HELPERS" || fail "global contention did not release the health lock"

set +e
VW_HEALTH_LOCK_FILE="$TMP/fix-infra.lock" bash -c '
    set -euo pipefail
    source "$1"
    FIX_MODE=true
    operation_acquire() { return 64; }
    _acquire_run_lock
' _ "$HELPERS" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 4 ]] || fail "global guard infrastructure failure must remain exit 4; got $rc"
VW_HEALTH_LOCK_FILE="$TMP/fix-infra.lock" bash -c '
    set -euo pipefail
    source "$1"
    _acquire_health_lock
    _release_health_lock
' _ "$HELPERS" || fail "global infrastructure failure did not release the health lock"

mkdir -p "$TMP/foreign-owner"
real_stat="$(command -v stat)"
cat > "$TMP/foreign-owner/stat" <<EOF_STAT
#!/usr/bin/env bash
if [[ "\${1:-}" == "-c" && "\${2:-}" == "%u" ]]; then
    printf '%s\n' "$(( EUID + 1 ))"
    exit 0
fi
exec "$real_stat" "\$@"
EOF_STAT
chmod 0755 "$TMP/foreign-owner/stat"
: > "$TMP/foreign-owner.lock"
set +e
PATH="$TMP/foreign-owner:$PATH" VW_HEALTH_LOCK_FILE="$TMP/foreign-owner.lock" bash -c '
    set -euo pipefail
    source "$1"
    _acquire_run_lock
' _ "$HELPERS" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 3 ]] || fail "foreign-owned read-only health lock must be infrastructure exit 3; got $rc"
set +e
PATH="$TMP/foreign-owner:$PATH" VW_HEALTH_LOCK_FILE="$TMP/foreign-owner.lock" bash -c '
    set -euo pipefail
    source "$1"
    FIX_MODE=true
    _acquire_run_lock
' _ "$HELPERS" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 4 ]] || fail "foreign-owned health --fix lock must be infrastructure exit 4; got $rc"

mkdir -p "$TMP/bad-flock"
cat > "$TMP/bad-flock/flock" <<'EOF_FLOCK'
#!/usr/bin/env bash
exit 64
EOF_FLOCK
chmod 0755 "$TMP/bad-flock/flock"
set +e
PATH="$TMP/bad-flock:$PATH" VW_HEALTH_LOCK_FILE="$TMP/flock-infra.lock" bash -c '
    set -euo pipefail
    source "$1"
    _acquire_run_lock
' _ "$HELPERS" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 3 ]] || fail "read-only health flock infrastructure failure must remain exit 3; got $rc"

set +e
PATH="$TMP/bad-flock:$PATH" VW_HEALTH_LOCK_FILE="$TMP/fix-flock-infra.lock" bash -c '
    set -euo pipefail
    source "$1"
    FIX_MODE=true
    _acquire_run_lock
' _ "$HELPERS" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 4 ]] || fail "health --fix flock infrastructure failure must be exit 4; got $rc"

ln -s "$TMP/target" "$TMP/symlink.lock"
set +e
VW_HEALTH_LOCK_FILE="$TMP/symlink.lock" bash -c '
    set -euo pipefail
    source "$1"
    _acquire_health_lock
' _ "$HELPERS" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 3 ]] || fail "health lock symlink must fail as infrastructure; got $rc"

VW_HEALTH_LOCK_FILE="$TMP/normal-failure.lock" bash -c '
    set -euo pipefail
    source "$1"
    _acquire_run_lock
    _release_run_lock 2 || rc=$?
    [[ "${rc:-0}" -eq 2 ]]
' _ "$HELPERS" || fail "normal failure cleanup did not preserve status"
VW_HEALTH_LOCK_FILE="$TMP/normal-failure.lock" bash -c '
    set -euo pipefail
    source "$1"
    _acquire_health_lock
    _release_health_lock
' _ "$HELPERS" || fail "normal failure cleanup did not release the health lock"

printf 'Owner-bound lock helper hygiene tests passed.\n'
