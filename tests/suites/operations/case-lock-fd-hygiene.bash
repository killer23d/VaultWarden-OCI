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

for variable in \
    OPERATION_SPECIFIC_LOCK_FD \
    OPERATION_LOCK_FD \
    VW_OPERATION_INHERITED_FD \
    HEALTH_LOCK_FD; do
    if grep -Fq "$variable" "$LOG_LIB"; then
        fail "logging library must not know repository lock variable ${variable}"
    fi
done

# Presentation helpers must work without any health or operation lock state.
unset HEALTH_LOCK_FD OPERATION_SPECIFIC_LOCK_FD OPERATION_LOCK_FD VW_OPERATION_INHERITED_FD
# shellcheck source=../../../lib/log.sh
source "$LOG_LIB"
spinner_start "lock-independent spinner"
spinner_stop true

if grep -Fq '_crowdsec_worker_run_without_guard_fds' "$CROWDSEC_WORKER_LIB"; then
    fail "CrowdSec worker library retained obsolete operation descriptor isolation"
fi
grep -Fq 'if "$bouncer_bin" -S -c "$dest"; then' "$CROWDSEC_WORKER_LIB" \
    || fail "autonomous CrowdSec Workers deployment must run normally under owner-bound locking"

printf 'Owner-bound lock and logging independence tests passed.\n'
