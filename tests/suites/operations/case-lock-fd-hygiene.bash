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

check_health_lock_directory_security() (
    set -euo pipefail
    local tmp block target link_path rc
    tmp="$(mktemp -d -t vw-health-dir-security.XXXXXXXXXX)"
    trap 'rm -rf -- "$tmp"' EXIT
    block="$tmp/health-lock-block.bash"
    awk '
        /^local HEALTH_LOCK_FD=""$/ {copy=1}
        copy && /^local ALERT_LOCK_DIR=/ {exit}
        copy {print}
    ' "$HEALTH" > "$block"
    [[ -s "$block" ]] || fail "could not extract health lock implementation"

    run_symlink_parent_case() {
        local FIX_MODE=false
        local HEALTH_LOCK_FD=""
        local HEALTH_OPENED_LOCK_FD=""
        local HEALTH_OPERATION_GUARD_ACQUIRED=false
        log_error(){ :; }
        log_warn(){ :; }
        log_info(){ :; }
        # shellcheck disable=SC1090
        source "$block"

        target="$tmp/attacker-target"
        link_path="$tmp/attacker-link"
        mkdir -m 0700 "$target"
        ln -s -- "$target" "$link_path"
        VW_HEALTH_LOCK_FILE="$link_path/new-directory/health.lock"
        set +e
        _acquire_readonly_health_lock
        rc=$?
        set -e
        [[ "$rc" -eq 3 && ! -e "$target/new-directory" && -z "$HEALTH_LOCK_FD" ]] \
            || fail "symlinked intermediate parent caused a filesystem side effect or lock leak"
    }
    run_symlink_parent_case

    if (( EUID == 0 )) || { command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; }; then
        local root_dir="$tmp/root-sticky" root_lock="$tmp/root-sticky/health.lock"
        if (( EUID == 0 )); then
            mkdir -m 1777 "$root_dir"
            chown root:root "$root_dir"
            env HEALTH_LOCK_BLOCK="$block" VW_HEALTH_LOCK_FILE="$root_lock" bash -c '
                set -euo pipefail
                run() {
                    local FIX_MODE=false
                    local HEALTH_LOCK_FD=""
                    local HEALTH_OPENED_LOCK_FD=""
                    local HEALTH_OPERATION_GUARD_ACQUIRED=false
                    log_error(){ :; }
                    log_warn(){ :; }
                    log_info(){ :; }
                    source "$HEALTH_LOCK_BLOCK"
                    _acquire_readonly_health_lock
                    [[ -n "$HEALTH_LOCK_FD" ]]
                    _release_readonly_health_lock
                    [[ -z "$HEALTH_LOCK_FD" ]]
                }
                run
            '
        else
            sudo -n mkdir -m 1777 "$root_dir"
            sudo -n chown root:root "$root_dir"
            sudo -n env HEALTH_LOCK_BLOCK="$block" VW_HEALTH_LOCK_FILE="$root_lock" bash -c '
                set -euo pipefail
                run() {
                    local FIX_MODE=false
                    local HEALTH_LOCK_FD=""
                    local HEALTH_OPENED_LOCK_FD=""
                    local HEALTH_OPERATION_GUARD_ACQUIRED=false
                    log_error(){ :; }
                    log_warn(){ :; }
                    log_info(){ :; }
                    source "$HEALTH_LOCK_BLOCK"
                    _acquire_readonly_health_lock
                    [[ -n "$HEALTH_LOCK_FD" ]]
                    _release_readonly_health_lock
                    [[ -z "$HEALTH_LOCK_FD" ]]
                }
                run
            '
            sudo -n rm -rf -- "$root_dir"
        fi
    else
        printf 'SKIP: root-owned sticky-directory health lock test requires root or passwordless sudo.\n'
    fi
}

check_health_lock_directory_security

printf 'Owner-bound lock helper hygiene tests passed.\n'
