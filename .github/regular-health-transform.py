#!/usr/bin/env python3
from pathlib import Path
import base64
import gzip
import re


def payload(source: str, name: str) -> str:
    match = re.search(rf"{name}: '([^']+)'", source)
    if not match:
        raise SystemExit(f"{name} payload not found")
    return gzip.decompress(base64.b64decode(match.group(1))).decode()


source = Path(".github/workflows/finalize-regular-health-lock.yml").read_text()

health_path = Path("utilities/maintenance-health.sh")
health = health_path.read_text()
start = health.index('local HEALTH_LOCK_FD=""')
end = health.index("local ALERT_LOCK_DIR=", start)
health_path.write_text(
    health[:start] + payload(source, "BLOCK_B64").rstrip() + "\n\n" + health[end:]
)

tests_path = Path("tests/suites/operations/case-health-alerts.bash")
tests = tests_path.read_text()
start = tests.index("check_health_run_lock_contracts() (")
call = tests.rindex("\ncheck_health_run_lock_contracts")
call_end = call + len("\ncheck_health_run_lock_contracts")
generated = payload(source, "TEST_B64").rstrip()
generated = generated.replace(
    '    XDG_RUNTIME_DIR="$xdg_dir"\n    TMPDIR="$fallback_dir"',
    '    # Consumed by the dynamically sourced lock-path resolver.\n'
    '    # shellcheck disable=SC2034\n'
    '    XDG_RUNTIME_DIR="$xdg_dir"\n'
    '    TMPDIR="$fallback_dir"',
    1,
)
generated = generated.replace(
    'HEALTH_OPENED_LOCK_FD=""',
    '# Consumed by the dynamically sourced lock-open helper.\n'
    '# shellcheck disable=SC2034\n'
    'HEALTH_OPENED_LOCK_FD=""',
)
old_replacement_test = '''if [[ -d "/proc/$$/fd" ]]; then
    replacement_lock="$lock_dir/replacement.lock"
    : > "$replacement_lock"
    chmod 0600 "$replacement_lock"
    real_stat="$(command -v stat)"
    cat > "$TMP/mockbin/stat" <<'EOF_STAT'
#!/usr/bin/env bash
set -euo pipefail
last_arg="${!#}"
if [[ "$last_arg" == /proc/*/fd/* ]]; then
    : > "$SWAP_ARMED"
elif [[ "$last_arg" == "$LOCK_PATH" && -e "$SWAP_ARMED" && ! -e "$SWAP_DONE" ]]; then
    /bin/mv -- "$LOCK_PATH" "${LOCK_PATH}.opened"
    : > "$LOCK_PATH"
    /bin/chmod 0600 -- "$LOCK_PATH"
    : > "$SWAP_DONE"
fi
exec "$REAL_STAT" "$@"
EOF_STAT
    chmod 0755 "$TMP/mockbin/stat"
    VW_HEALTH_LOCK_FILE="$replacement_lock"
    set +e
    REAL_STAT="$real_stat" LOCK_PATH="$replacement_lock" \\
        SWAP_ARMED="$TMP/swap-armed" SWAP_DONE="$TMP/swap-done" \\
        PATH="$TMP/mockbin:$PATH" _acquire_readonly_health_lock
    rc=$?
    set -e
    [[ "$rc" -eq 3 && -e "$TMP/swap-done" && -z "$HEALTH_LOCK_FD" ]] \\
        || fail "health lock replacement was not detected safely"
    pass "health coordination verifies the opened descriptor against the intended regular file"
else
    printf 'SKIP: descriptor replacement test requires /proc.\\n'
fi
'''
new_replacement_test = '''if [[ -d "/proc/$$/fd" ]]; then
    replacement_lock="$lock_dir/replacement.lock"
    : > "$replacement_lock"
    chmod 0600 "$replacement_lock"
    original_identity_definition="$(declare -f _health_path_identity)"
    _health_path_identity_real() {
        local target="$1"
        stat -Lc '%d:%i' -- "$target" 2>/dev/null \\
            || stat -f '%d:%i' -- "$target" 2>/dev/null
    }
    _health_path_identity() {
        local target="$1" identity
        identity="$(_health_path_identity_real "$target")" || return 1
        if [[ "$target" == /proc/*/fd/* && ! -e "$TMP/swap-done" ]]; then
            mv -- "$replacement_lock" "${replacement_lock}.opened"
            : > "$replacement_lock"
            chmod 0600 -- "$replacement_lock"
            : > "$TMP/swap-done"
        fi
        printf '%s\\n' "$identity"
    }
    VW_HEALTH_LOCK_FILE="$replacement_lock"
    set +e
    _acquire_readonly_health_lock
    rc=$?
    set -e
    eval "$original_identity_definition"
    unset -f _health_path_identity_real
    [[ "$rc" -eq 3 && -e "$TMP/swap-done" && -z "$HEALTH_LOCK_FD" ]] \\
        || fail "health lock replacement was not detected safely"
    pass "health coordination verifies the opened descriptor against the intended regular file"
else
    printf 'SKIP: descriptor replacement test requires /proc.\\n'
fi
'''
if generated.count(old_replacement_test) != 1:
    raise SystemExit("replacement test marker not found exactly once")
generated = generated.replace(old_replacement_test, new_replacement_test, 1)
tests_path.write_text(tests[:start] + generated + tests[call_end:])

service_path = Path("systemd/vaultwarden-health.service")
service = service_path.read_text()
old = """# RuntimeDirectory instructs systemd to pre-create /run/vaultwarden-oci/ as a
# root-owned runtime directory before ExecStart runs. The operation library uses
# that directory for owner/holder state. Health duplicate-run coordination locks
# the dedicated root-owned /run/lock/vaultwarden-health directory inode, so the
# installed root service and supported diagnostics share one host-global object.
"""
new = """# RuntimeDirectory instructs systemd to pre-create /run/vaultwarden-oci/ as a
# root-owned runtime directory before ExecStart runs. The operation library uses
# that directory for owner/holder state. Root health uses the regular lock file
# /run/lock/vaultwarden-health.lock; documented non-root diagnostics preserve
# their XDG_RUNTIME_DIR or per-EUID TMP fallback paths.
"""
if old not in service:
    raise SystemExit("health service comment marker not found")
service_path.write_text(service.replace(old, new, 1))
