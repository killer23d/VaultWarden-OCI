#!/usr/bin/env python3
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]

# Restore edge.py from the known-good branch state before the scanner-fix edit,
# then apply only the intended release-neutral User-Agent change.
old = subprocess.run(
    ["git", "show", "763a019980c16fddbe3a1d789a718357062b6f28:vaultwarden_oci/edge.py"],
    cwd=root,
    check=True,
    text=True,
    stdout=subprocess.PIPE,
).stdout
old = old.replace('"User-Agent": "VaultWarden-OCI/2 crowdsec-cloudflare"', '"User-Agent": "VaultWarden-OCI crowdsec-cloudflare"')
(root / "vaultwarden_oci/edge.py").write_text(old, encoding="utf-8")

replacements = {
    "vaultwarden_oci/recovery_ux.py": [
        ("# is the proven V1-compatible secure transport.", "# is the proven secure password transport."),
    ],
    "vaultwarden_oci/dashboard.py": [
        ("Thin V1-inspired day-2 interface; mutations are delegated to vwctl.", "Thin day-2 interface; mutations are delegated to vwctl."),
    ],
    "vaultwarden_oci/sevenzip_secure.py": [
        ("Secure 7-Zip password transport carried forward from the proven V1 path.", "Secure 7-Zip password transport for recovery-kit operations."),
    ],
}
for relative, pairs in replacements.items():
    path = root / relative
    text = path.read_text(encoding="utf-8")
    for old_value, new_value in pairs:
        if old_value not in text:
            raise SystemExit(f"expected text not found in {relative}: {old_value}")
        text = text.replace(old_value, new_value)
    path.write_text(text, encoding="utf-8")

(root / ".github/pull_request_template.md").write_text(
    """## Pull request checklist

- [ ] Change is within the current product contract and does not add legacy compatibility, a second dashboard backend, Postfix/queue, arbitrary provider endpoints, or speculative plugin/framework architecture.
- [ ] `python3 -m compileall -q vaultwarden_oci tests` passes.
- [ ] `python3 -m unittest discover -s tests -p 'test_*.py' -v` passes.
- [ ] Changed Bash glue passes `bash -n`.
- [ ] `vwctl --help` remains the command reference; workflow docs/tests were updated for command behavior changes.
- [ ] Provider metadata changes were checked against current official provider documentation and kept in `email-providers.toml` unless a genuinely new transport capability required Python.
- [ ] Immutable release-content changes include a new `[vaultwarden_oci].version` in `versions.toml`.
- [ ] Secret handling, stable doctor IDs/JSON, recovery format, Cloudflare fail-closed behavior, and systemd ownership were reviewed where relevant.
- [ ] Disposable Ubuntu 24.04 host acceptance was run for available `amd64`/`arm64` environments, or exact NOT RUN items are recorded in the PR/release evidence.
""",
    encoding="utf-8",
)
