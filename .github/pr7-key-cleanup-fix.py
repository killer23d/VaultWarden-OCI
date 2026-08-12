from pathlib import Path

p = Path('utilities/key-rotate.sh')
t = p.read_text()
old = '''_key_rotate_cleanup() {
    local rc=$?
    local rollback_rc=0
    if [[ "$_KEY_ROTATE_COMMITTED" != "true" && "$_KEY_ROTATE_PROMOTION_STARTED" == "true" ]]; then
        _key_rotate_rollback_live_generation || rollback_rc=$?
        if (( rollback_rc != 0 )); then
            log_error "Rotation rollback is incomplete; recovery material is retained at: $backup_dir"
        fi
        if (( rc == 0 || rollback_rc != 0 )); then
            (( rc == 0 )) && rc=1
        fi
    fi
    operation_release "$rc"
    [[ -n "${workdir:-}" ]] && remove_sensitive_workspace "$workdir"
    return "$rc"
}
'''
new = '''_key_rotate_cleanup() {
    local rc=$?
    local rollback_rc=0 cleanup_rc=0
    if [[ "$_KEY_ROTATE_COMMITTED" != "true" && "$_KEY_ROTATE_PROMOTION_STARTED" == "true" ]]; then
        _key_rotate_rollback_live_generation || rollback_rc=$?
        if (( rollback_rc != 0 )); then
            log_error "Rotation rollback is incomplete; recovery material is retained at: $backup_dir"
        fi
        if (( rc == 0 || rollback_rc != 0 )); then
            (( rc == 0 )) && rc=1
        fi
    fi
    if [[ -n "${workdir:-}" ]]; then
        remove_sensitive_workspace "$workdir" || cleanup_rc=$?
        if (( cleanup_rc != 0 )); then
            log_error "Failed to remove the Age-key rotation sensitive workspace: $workdir"
            (( rc == 0 )) && rc="$cleanup_rc"
        fi
    fi
    operation_release "$rc"
    return "$rc"
}
'''
if t.count(old) != 1:
    raise SystemExit('key-rotation cleanup block not found exactly once')
p.write_text(t.replace(old, new, 1))

p = Path('tests/suites/security/case-secrets.bash')
t = p.read_text()
anchor = '''check_key_rotate_full_entrypoint_cleanup_contract() (
'''
behavior = r'''check_key_rotate_cleanup_failure_status() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
cd "$ROOT"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cleanup_source="$(sed -n '/^_key_rotate_cleanup() {$/,/^}$/p' utilities/key-rotate.sh)"
[[ -n "$cleanup_source" ]] || fail 'key-rotation cleanup helper could not be extracted'

KEY_ROTATE_CLEANUP_SOURCE="$cleanup_source" bash -s <<'KEY_ROTATE_CLEANUP_STATUS_TEST' \
  || fail 'key-rotation cleanup failure status regression failed'
set -euo pipefail
_KEY_ROTATE_COMMITTED=true
_KEY_ROTATE_PROMOTION_STARTED=true
workdir=/dev/shm/vw-age-rotate.cleanup-status
backup_dir=/root/unused
release_marker="$(mktemp)"
trap '/bin/rm -f -- "$release_marker"' EXIT
log_error(){ :; }
_key_rotate_rollback_live_generation(){ return 99; }
remove_sensitive_workspace(){ return 73; }
operation_release(){ printf '%s' "$1" > "$release_marker"; }
eval "$KEY_ROTATE_CLEANUP_SOURCE"
set +e
true
_key_rotate_cleanup
rc=$?
set -e
[[ "$rc" == 73 ]]
[[ "$(cat "$release_marker")" == 73 ]]

# Existing failure/signal status remains authoritative even if cleanup also fails.
set +e
false
_key_rotate_cleanup
rc=$?
set -e
[[ "$rc" == 1 ]]
[[ "$(cat "$release_marker")" == 1 ]]
KEY_ROTATE_CLEANUP_STATUS_TEST
)

'''
if t.count(anchor) != 1:
    raise SystemExit('key-rotation full-entrypoint anchor not found exactly once')
t = t.replace(anchor, behavior + anchor, 1)

call_anchor = '''check_key_rotate_full_entrypoint_cleanup_contract
'''
if t.count(call_anchor) < 1:
    raise SystemExit('key-rotation cleanup contract call not found')
t = t.replace(call_anchor, 'check_key_rotate_cleanup_failure_status\n' + call_anchor, 1)
p.write_text(t)
