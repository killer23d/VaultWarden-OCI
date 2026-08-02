from pathlib import Path
import textwrap

def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)

def replace_region(text: str, start: str, end: str, replacement: str, label: str) -> str:
    start_count = text.count(start)
    end_count = text.count(end)
    if start_count != 1 or end_count != 1:
        raise SystemExit(
            f"{label}: expected one start/end marker, found {start_count}/{end_count}"
        )
    begin = text.index(start)
    finish = text.index(end, begin)
    return text[:begin] + replacement.rstrip() + text[finish:]

health_path = Path('utilities/maintenance-health.sh')
health = health_path.read_text()

health = replace_once(
    health,
    'local HEALTH_LOCK_FD=""\nlocal HEALTH_OPENED_LOCK_FD=""\nlocal HEALTH_OPERATION_GUARD_ACQUIRED=false\n',
    'local HEALTH_LOCK_FD=""\nlocal HEALTH_OPENED_LOCK_FD=""\nlocal HEALTH_HOST_LOCK_FD=""\nlocal HEALTH_OPERATION_GUARD_ACQUIRED=false\n',
    'health descriptor declarations',
)

health = replace_once(
    health,
    '\n_health_stat_mode_uid_gid_nlink() {\n',
    '''\n_health_host_gate_path() {\n    # flock(2) is advisory: locking this stable root-owned directory inode\n    # does not block ordinary /run/lock file creation or access. It provides\n    # one host-wide health domain without a shared writable file, lock group,\n    # installer precreation, daemon, or registry.\n    printf '%s\\n' '/run/lock'\n}\n\n_health_stat_mode_uid_gid_nlink() {\n''',
    'host gate path insertion',
)

host_helpers = textwrap.dedent(r'''
_health_release_host_lock() {
    local release_rc=0 fd="${HEALTH_HOST_LOCK_FD:-}"
    if [[ -n "$fd" ]]; then
        flock -u "$fd" 2>/dev/null || release_rc=$?
        _health_close_lock_fd "$fd" || release_rc=$?
    fi
    HEALTH_HOST_LOCK_FD=""
    return "$release_rc"
}

_health_acquire_host_lock() {
    local gate_path fd fd_path flock_rc owner_pid="$BASHPID"
    gate_path="$(_health_host_gate_path)"
    HEALTH_HOST_LOCK_FD=""

    if [[ ! -d "$gate_path" || -L "$gate_path" ]] \
        || ! _health_lock_ancestry_is_trusted "$gate_path"; then
        log_error "Host-wide health coordination gate is unsafe: $gate_path"
        return 3
    fi
    if ! { exec {fd}<"$gate_path"; } 2>/dev/null; then
        log_error "Cannot open host-wide health coordination gate: $gate_path"
        return 3
    fi

    fd_path="$(_health_lock_fd_path "$fd" "$owner_pid")"
    if [[ ! -d "$fd_path" ]] \
        || ! _health_open_lock_matches_target "$gate_path" "$fd"; then
        _health_close_lock_fd "$fd" || true
        log_error "Host-wide health coordination gate changed while being opened: $gate_path"
        return 3
    fi

    if flock -n -E 75 "$fd" 2>/dev/null; then
        flock_rc=0
    else
        flock_rc=$?
    fi
    case "$flock_rc" in
        0) ;;
        75)
            _health_close_lock_fd "$fd" || true
            log_warn "Another VaultWarden health check is already running on this host; skipping this duplicate run."
            return 75
            ;;
        *)
            _health_close_lock_fd "$fd" || true
            log_error "Host-wide health coordination flock failed with status ${flock_rc}: $gate_path"
            return 3
            ;;
    esac

    if [[ ! -d "$fd_path" ]] \
        || ! _health_open_lock_matches_target "$gate_path" "$fd" \
        || ! _health_lock_ancestry_is_trusted "$gate_path"; then
        flock -u "$fd" 2>/dev/null || true
        _health_close_lock_fd "$fd" || true
        log_error "Host-wide health coordination gate changed after acquisition: $gate_path"
        return 3
    fi
    HEALTH_HOST_LOCK_FD="$fd"
}

''').lstrip('\n')
health = replace_once(
    health,
    '_health_secure_open_helper() {\n',
    host_helpers + '_health_secure_open_helper() {\n',
    'host gate helper insertion',
)

release_function = textwrap.dedent(r'''
_release_readonly_health_lock() {
    local release_rc=0 host_release_rc opened_fd="${HEALTH_OPENED_LOCK_FD:-}"
    if [[ -n "${HEALTH_LOCK_FD:-}" ]]; then
        flock -u "$HEALTH_LOCK_FD" 2>/dev/null || release_rc=$?
        _health_close_lock_fd "$HEALTH_LOCK_FD" || release_rc=$?
    fi
    if [[ -n "$opened_fd" && "$opened_fd" != "${HEALTH_LOCK_FD:-}" ]]; then
        _health_close_lock_fd "$opened_fd" || release_rc=$?
    fi
    HEALTH_LOCK_FD=""
    HEALTH_OPENED_LOCK_FD=""

    if _health_release_host_lock; then
        :
    else
        host_release_rc=$?
        (( release_rc == 0 )) && release_rc="$host_release_rc"
    fi
    return "$release_rc"
}
''').lstrip('\n')
health = replace_region(
    health,
    '_release_readonly_health_lock() {',
    '\n\n_acquire_readonly_health_lock() {',
    release_function,
    'health release function',
)

acquire_function = textwrap.dedent(r'''
_acquire_readonly_health_lock() {
    local lock_path fd flock_rc host_rc
    lock_path="$(_health_readonly_lock_path)"

    if _health_acquire_host_lock; then
        :
    else
        host_rc=$?
        return "$host_rc"
    fi

    if ! _health_prepare_lock_file "$lock_path"; then
        _health_release_host_lock || true
        return 3
    fi
    if ! _health_open_lock_file "$lock_path"; then
        _health_release_host_lock || true
        return 3
    fi
    fd="$HEALTH_OPENED_LOCK_FD"

    if flock -n -E 75 "$fd" 2>/dev/null; then
        flock_rc=0
    else
        flock_rc=$?
    fi
    case "$flock_rc" in
        0) ;;
        75)
            _health_close_lock_fd "$fd" || true
            HEALTH_OPENED_LOCK_FD=""
            _health_release_host_lock || true
            log_warn "Another VaultWarden health check is already running for this local identity; skipping this duplicate run."
            return 75
            ;;
        *)
            _health_close_lock_fd "$fd" || true
            HEALTH_OPENED_LOCK_FD=""
            _health_release_host_lock || true
            log_error "Health coordination flock failed with status ${flock_rc}: $lock_path"
            return 3
            ;;
    esac

    if ! _health_open_lock_matches_target "$lock_path" "$fd" \
        || ! _health_lock_path_is_trusted "$lock_path" 1; then
        flock -u "$fd" 2>/dev/null || true
        _health_close_lock_fd "$fd" || true
        HEALTH_OPENED_LOCK_FD=""
        _health_release_host_lock || true
        log_error "Health coordination lock changed after acquisition: $lock_path"
        return 3
    fi
    HEALTH_LOCK_FD="$fd"
    HEALTH_OPENED_LOCK_FD=""
}
''').lstrip('\n')
health = replace_region(
    health,
    '_acquire_readonly_health_lock() {',
    '\n\n_acquire_run_lock() {',
    acquire_function,
    'health acquisition function',
)
health_path.write_text(health)

log_path = Path('lib/log.sh')
log_text = log_path.read_text()
old_spinner = '''    local health_fd="${HEALTH_LOCK_FD:-}"\n    (\n        # The read-only health lock remains parent-owned. Keep this UI helper\n        # from extending that secondary lock if the health process is killed.\n        if [[ "$health_fd" =~ ^[0-9]+$ ]] && (( health_fd > 2 )); then\n            { eval "exec ${health_fd}>&-"; } 2>/dev/null || true\n        fi\n        unset HEALTH_LOCK_FD\n'''
new_spinner = '''    local health_fd="${HEALTH_LOCK_FD:-}"\n    local health_host_fd="${HEALTH_HOST_LOCK_FD:-}"\n    (\n        # Health coordination remains parent-owned. Keep this UI helper from\n        # extending either the host-wide gate or the local regular-file lock.\n        local inherited_health_fd\n        for inherited_health_fd in "$health_host_fd" "$health_fd"; do\n            if [[ "$inherited_health_fd" =~ ^[0-9]+$ ]] && (( inherited_health_fd > 2 )); then\n                { eval "exec ${inherited_health_fd}>&-"; } 2>/dev/null || true\n            fi\n        done\n        unset HEALTH_HOST_LOCK_FD HEALTH_LOCK_FD\n'''
log_text = replace_once(log_text, old_spinner, new_spinner, 'spinner health descriptors')
log_path.write_text(log_text)

test_path = Path('tests/suites/operations/case-health-alerts.bash')
test_text = test_path.read_text()
test_text = replace_once(
    test_text,
    '    [[ -n "${signal_pid:-}" ]] && kill -KILL "$signal_pid" 2>/dev/null || true\n',
    '    [[ -n "${signal_pid:-}" ]] && kill -KILL "$signal_pid" 2>/dev/null || true\n    [[ -n "${cross_identity_pid:-}" ]] && kill -KILL "$cross_identity_pid" 2>/dev/null || true\n',
    'cross-identity cleanup',
)
test_text = replace_once(
    test_text,
    '    source "$LOCK_BLOCK"\n    set +e\n    _acquire_readonly_health_lock\n    rc=$?\n    set -e\n    printf \'%s\\n\' "$rc" > "$CAPTURE_STATUS_FILE"\n',
    '    source "$LOCK_BLOCK"\n    # This regression targets the local secure-open window itself. The\n    # host-wide gate has independent process-level coverage below.\n    _health_acquire_host_lock(){ return 0; }\n    set +e\n    _acquire_readonly_health_lock\n    rc=$?\n    set -e\n    printf \'%s\\n\' "$rc" > "$CAPTURE_STATUS_FILE"\n',
    'capture-race host gate isolation',
)

overlap_start = 'FIX_MODE=false\noverlap_lock="$lock_dir/overlap.lock"\n'
overlap_end = '\n\nreal_lock="$lock_dir/real-global.lock"\n'
overlap_replacement = textwrap.dedent(r'''
FIX_MODE=false
overlap_lock="$lock_dir/overlap.lock"
VW_HEALTH_LOCK_FILE="$overlap_lock"
_acquire_run_lock || fail "parent read-only health acquisition failed"
probe_health() {
    local mode="$1" marker="$2" path="$3"
    FIX_MODE="$mode"
    HEALTH_HOST_LOCK_FD=""
    HEALTH_LOCK_FD=""
    # Consumed by the dynamically sourced lock-open helper.
    # shellcheck disable=SC2034
    HEALTH_OPENED_LOCK_FD=""
    HEALTH_OPERATION_GUARD_ACQUIRED=false
    VW_HEALTH_LOCK_FILE="$path"
    operation_acquire(){ : > "$marker"; return 0; }
    operation_set_phase(){ return 0; }
    operation_release(){ return 0; }
    _acquire_run_lock
}
set +e
(probe_health false "$TMP/readonly-global-called" "$lock_dir/readonly-other.lock")
readonly_rc=$?
(probe_health true "$TMP/repair-global-called" "$lock_dir/repair-other.lock")
repair_rc=$?
set -e
[[ "$readonly_rc" -eq 75 && "$repair_rc" -eq 75 ]] \
    || fail "host-wide read-only holder did not exclude duplicate/repair runs on other local paths"
[[ ! -e "$TMP/readonly-global-called" && ! -e "$TMP/repair-global-called" ]] \
    || fail "repair attempted the operation guard before host-wide health contention cleared"
_release_run_lock 0 || fail "parent read-only health release failed"

FIX_MODE=true
TRACE=""
VW_HEALTH_LOCK_FILE="$overlap_lock"
_acquire_run_lock || fail "parent health repair acquisition failed"
set +e
(probe_health false "$TMP/fix-readonly-global-called" "$lock_dir/fix-readonly-other.lock")
fix_readonly_rc=$?
(probe_health true "$TMP/fix-repair-global-called" "$lock_dir/fix-repair-other.lock")
fix_repair_rc=$?
set -e
[[ "$fix_readonly_rc" -eq 75 && "$fix_repair_rc" -eq 75 ]] \
    || fail "host-wide repair holder did not exclude read-only/repair runs on other local paths"
_release_run_lock 0 || fail "parent repair release failed"
pass "host-wide health gate serializes every read and repair combination across local paths"

if (( EUID != 0 )) && [[ "$HAS_ROOT" == true ]]; then
    cross_holder="$TMP/cross-identity-holder.bash"
    cross_probe="$TMP/cross-identity-probe.bash"
    cat > "$cross_holder" <<'EOF_CROSS_HOLDER'
#!/usr/bin/env bash
set -euo pipefail
run() {
    local FIX_MODE="$HOLDER_FIX_MODE"
    log_error(){ :; }
    log_warn(){ :; }
    log_info(){ :; }
    operation_acquire(){ return 0; }
    operation_set_phase(){ return 0; }
    operation_release(){ return 0; }
    source "$LOCK_BLOCK"
    unset VW_HEALTH_LOCK_FILE XDG_RUNTIME_DIR TMPDIR
    _acquire_run_lock
    : > "$READY_FILE"
    while [[ ! -e "$RELEASE_FILE" ]]; do sleep 0.02; done
    _release_run_lock 0
}
run
EOF_CROSS_HOLDER
    cat > "$cross_probe" <<'EOF_CROSS_PROBE'
#!/usr/bin/env bash
set -euo pipefail
run() {
    local FIX_MODE=false rc
    log_error(){ :; }
    log_warn(){ :; }
    log_info(){ :; }
    operation_acquire(){ return 0; }
    operation_set_phase(){ return 0; }
    operation_release(){ return 0; }
    source "$LOCK_BLOCK"
    unset VW_HEALTH_LOCK_FILE TMPDIR
    XDG_RUNTIME_DIR="$PROBE_XDG"
    set +e
    _acquire_run_lock
    rc=$?
    set -e
    if (( rc == 0 )); then
        : > "$CHECKS_MARKER"
        _release_run_lock 0
    fi
    exit "$rc"
}
run
EOF_CROSS_PROBE
    chmod 0755 "$cross_holder" "$cross_probe"

    root_default_existed=false
    if sudo -n -- test -e /run/lock/vaultwarden-health.lock; then
        root_default_existed=true
    fi

    for cross_spec in readonly:false repair:true; do
        cross_label="${cross_spec%%:*}"
        cross_fix="${cross_spec##*:}"
        cross_ready="$TMP/cross-${cross_label}.ready"
        cross_release="$TMP/cross-${cross_label}.release"
        cross_checks="$TMP/cross-${cross_label}.checks"
        cross_xdg="$TMP/cross-${cross_label}-xdg"
        mkdir -m 0700 "$cross_xdg"

        sudo -n -- env -u VW_HEALTH_LOCK_FILE -u XDG_RUNTIME_DIR -u TMPDIR \
            LOCK_BLOCK="$LOCK_BLOCK" HOLDER_FIX_MODE="$cross_fix" \
            READY_FILE="$cross_ready" RELEASE_FILE="$cross_release" \
            "$BASH" "$cross_holder" &
        cross_identity_pid=$!
        wait_for_file "$cross_ready"

        set +e
        env -u VW_HEALTH_LOCK_FILE -u TMPDIR \
            LOCK_BLOCK="$LOCK_BLOCK" PROBE_XDG="$cross_xdg" \
            CHECKS_MARKER="$cross_checks" "$BASH" "$cross_probe"
        cross_rc=$?
        set -e
        [[ "$cross_rc" -eq 75 && ! -e "$cross_checks" \
            && ! -e "$cross_xdg/vaultwarden-health.lock" ]] \
            || fail "non-root read-only health overlapped root ${cross_label} or reached local checks (rc=$cross_rc)"

        : > "$cross_release"
        wait "$cross_identity_pid" || fail "root ${cross_label} holder failed"
        cross_identity_pid=""

        env -u VW_HEALTH_LOCK_FILE -u TMPDIR \
            LOCK_BLOCK="$LOCK_BLOCK" PROBE_XDG="$cross_xdg" \
            CHECKS_MARKER="$cross_checks" "$BASH" "$cross_probe" \
            || fail "non-root health did not acquire after root ${cross_label} released"
        [[ -e "$cross_checks" ]] \
            || fail "post-release non-root health did not reach its check boundary"
    done

    if [[ "$root_default_existed" == false ]]; then
        sudo -n -- rm -f -- /run/lock/vaultwarden-health.lock
    fi
    pass "root read-only and repair runs exclude non-root default-path health before checks"
else
    printf 'SKIP: cross-EUID health serialization requires a non-root runner with passwordless sudo.\n'
fi
''').lstrip('\n')
test_text = replace_region(
    test_text,
    overlap_start,
    overlap_end,
    overlap_replacement,
    'overlap and cross-identity regressions',
)

descriptor_start = 'FIX_MODE=false\nparent_lock="$lock_dir/parent-descriptor.lock"\n'
descriptor_end = '\n\nsignal_lock="$lock_dir/signal.lock"\n'
descriptor_replacement = textwrap.dedent(r'''
FIX_MODE=false
parent_lock="$lock_dir/parent-descriptor.lock"
subshell_lock="$lock_dir/subshell-descriptor.lock"
VW_HEALTH_LOCK_FILE="$parent_lock"
_acquire_run_lock || fail "parent descriptor-reuse setup failed"
parent_host_fd="$HEALTH_HOST_LOCK_FD"
parent_health_fd="$HEALTH_LOCK_FD"
_release_run_lock 0 || fail "parent descriptor-reuse release failed"
(
    HEALTH_HOST_LOCK_FD=""
    HEALTH_LOCK_FD=""
    # Consumed by the dynamically sourced lock-open helper.
    # shellcheck disable=SC2034
    HEALTH_OPENED_LOCK_FD=""
    VW_HEALTH_LOCK_FILE="$subshell_lock"
    _acquire_readonly_health_lock || fail "subshell health acquisition failed after descriptor reuse"
    [[ "$HEALTH_HOST_LOCK_FD" == "$parent_host_fd" \
        && "$HEALTH_LOCK_FD" == "$parent_health_fd" ]] \
        || fail "subshell did not reuse the expected host/local descriptor pair"
    _release_readonly_health_lock || fail "subshell descriptor-reuse release failed"
)
pass "host and local health descriptor validation follows the current subshell owner"
''').lstrip('\n')
test_text = replace_region(
    test_text,
    descriptor_start,
    descriptor_end,
    descriptor_replacement,
    'descriptor reuse regression',
)
test_path.write_text(test_text)

hygiene_path = Path('tests/suites/operations/case-lock-fd-hygiene.bash')
hygiene = hygiene_path.read_text()
old_hygiene = textwrap.dedent(r'''
grep -Fq 'local health_fd="${HEALTH_LOCK_FD:-}"' <<< "$spinner_block" \
    || fail "spinner must preserve read-health lock isolation"
grep -Fq 'eval "exec ${health_fd}>&-"' <<< "$spinner_block" \
    || fail "spinner child must close the read-health lock descriptor"
''').lstrip('\n')
new_hygiene = textwrap.dedent(r'''
grep -Fq 'local health_fd="${HEALTH_LOCK_FD:-}"' <<< "$spinner_block" \
    || fail "spinner must preserve local read-health lock isolation"
grep -Fq 'local health_host_fd="${HEALTH_HOST_LOCK_FD:-}"' <<< "$spinner_block" \
    || fail "spinner must preserve host-wide health gate isolation"
grep -Fq 'for inherited_health_fd in "$health_host_fd" "$health_fd"' <<< "$spinner_block" \
    || fail "spinner child must enumerate both health descriptors"
grep -Fq 'exec ${inherited_health_fd}>&-' <<< "$spinner_block" \
    || fail "spinner child must close both health descriptors"
grep -Fq 'unset HEALTH_HOST_LOCK_FD HEALTH_LOCK_FD' <<< "$spinner_block" \
    || fail "spinner child must clear both inherited health descriptor variables"
''').lstrip('\n')
hygiene = replace_once(
    hygiene,
    old_hygiene,
    new_hygiene,
    'spinner descriptor hygiene assertions',
)
hygiene_path.write_text(hygiene)

unit_path = Path('systemd/vaultwarden-health.service')
unit = unit_path.read_text()
unit = replace_once(
    unit,
    '# maintenance.sh health owns duplicate-run protection. With --fix, it also uses\n# the shared operation guard and exits cleanly if another operation is active.\n',
    '# maintenance.sh health first takes a host-wide advisory gate on the stable\n# /run/lock directory inode, then its root/XDG/TMP regular-file lock. With\n# --fix, it also uses the shared operation guard and exits cleanly if another\n# operation is active. Advisory directory locking does not block normal files.\n',
    'systemd health coordination comment',
)
unit = replace_once(
    unit,
    '# that directory for owner/holder state. Root health uses the regular lock file\n# /run/lock/vaultwarden-health.lock; documented non-root diagnostics preserve\n# their XDG_RUNTIME_DIR or per-EUID TMP fallback paths.\n',
    '# that directory for owner/holder state. Every health invocation shares the\n# host-wide /run/lock directory-inode gate. Root health then uses the regular\n# /run/lock/vaultwarden-health.lock file; non-root diagnostics retain their\n# XDG_RUNTIME_DIR or per-EUID TMP regular-file paths as a local second layer.\n',
    'systemd runtime lock comment',
)
unit_path.write_text(unit)
