#!/usr/bin/env bash

# Focused structural coverage for helpers made obsolete by owner-bound locking.
# Owner-death and arbitrary-child behavior lives in case-operations.bash.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

ROOT="$VW_TEST_REPO_ROOT"
LOG_LIB="$ROOT/lib/log.sh"
CROWDSEC_WORKER_LIB="$ROOT/lib/crowdsec-worker.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

OPS="$ROOT/lib/operations.sh"
HEALTH="$ROOT/utilities/maintenance-health.sh"
health_run_lock_block="$(sed -n '/^_acquire_run_lock()/,/^_release_run_lock()/p' "$HEALTH")"
if grep -Fq -- '--specific-lock' <<< "$health_run_lock_block"; then
    fail "health repair must not pass the duplicate-run health path as an operation-specific lock"
fi
health_line="$(grep -n -m1 '_acquire_readonly_health_lock' <<< "$health_run_lock_block" \
    | cut -d: -f1 || true)"
global_line="$(grep -n -m1 'operation_acquire' <<< "$health_run_lock_block" \
    | cut -d: -f1 || true)"
[[ "$health_line" =~ ^[0-9]+$ && "$global_line" =~ ^[0-9]+$ && "$health_line" -lt "$global_line" ]] \
    || fail "health repair must acquire health coordination before the global operation guard"
grep -Fq '_operation_lock_holder()' "$OPS" \
    || fail "owner-bound operation holder was removed"
grep -Fq 'coproc VW_OPERATION_LOCK_HOLDER' "$OPS" \
    || fail "owner-bound operation holder startup was removed"
grep -Fq 'OPERATION_HOLDER_CONTROL_FD' "$OPS" \
    || fail "owner-bound operation holder control lifetime was removed"

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
    || fail "spinner must preserve read-health lock isolation"
grep -Fq 'eval "exec ${health_fd}>&-"' <<< "$spinner_block" \
    || fail "spinner child must close the read-health lock descriptor"

if grep -Fq '_crowdsec_worker_run_without_guard_fds' "$CROWDSEC_WORKER_LIB"; then
    fail "CrowdSec worker library retained obsolete operation descriptor isolation"
fi
grep -Fq 'if "$bouncer_bin" -S -c "$dest"; then' "$CROWDSEC_WORKER_LIB" \
    || fail "autonomous CrowdSec Workers deployment must run normally under owner-bound locking"

printf 'Owner-bound lock helper hygiene tests passed.\n'
