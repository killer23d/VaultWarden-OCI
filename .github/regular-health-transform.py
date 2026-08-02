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
    'HEALTH_LOCK_FD=""\nHEALTH_OPENED_LOCK_FD=""\nHEALTH_OPERATION_GUARD_ACQUIRED=false',
    'HEALTH_LOCK_FD=""\n'
    '# Consumed by the dynamically sourced lock-open helper.\n'
    '# shellcheck disable=SC2034\n'
    'HEALTH_OPENED_LOCK_FD=""\n'
    'HEALTH_OPERATION_GUARD_ACQUIRED=false',
    1,
)
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
