#!/usr/bin/env python3
"""Static post-patch verifier for the bounded PRR-001..005 remediation."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
restore_text = (root / "utilities/restore-run.sh").read_text()
restore_match = re.search(r"(?ms)^_display_new_key\(\) \{.*?^\}", restore_text)
checks = {
    "setup protected handoff": "VWOCI-PRR-PATCH-01" in (root / "lib/setup-credentials.sh").read_text(),
    "required UFW failure": "Required UFW firewall configuration failed" in (root / "setup.sh").read_text(),
    "required auto-secrets failure": "Required automatic secrets configuration failed" in (root / "setup.sh").read_text(),
    "restore private key not printed": bool(restore_match and "priv_key_line" not in restore_match.group(0)),
    "recovery AES ZIP": "-mem=AES256" in (root / "lib/secrets.sh").read_text(),
    "no legacy tar.gpg implementation": "tar.gpg" not in (root / "lib/secrets.sh").read_text(),
    "full archive exclusions": "vaultwarden-setup-credentials-" in (root / "utilities/backup-run.sh").read_text(),
    "no recursive log 0755": not re.search(r"chmod\s+-R\s+755.*logs", (root / "startup.sh").read_text()),
    "direct email mode": "_VW_DEFAULT_EMAIL_MODES=( auto api smtp direct host )" in (root / "lib/defaults.sh").read_text(),
    "permanent tests registered": "case-production-readiness" in (root / "tests/run-tests.sh").read_text(),
}
failed = [name for name, ok in checks.items() if not ok]
for name, ok in checks.items():
    print(("PASS" if ok else "FAIL"), name)
if failed:
    raise SystemExit(1)
print("NOTE setup handoff has three generated groups because audited delta has no canonical backup_passphrase consumer; no HMAC key was relabeled.")
