"""Static release-gate validation for the operator's clean ARM64 installation script."""
from __future__ import annotations

import ast
import subprocess
import unittest
from pathlib import Path


GATE = Path(__file__).resolve().parents[1] / "tests" / "host-acceptance" / "24-rc12-clean-install-ubuntu2604-arm64.sh"


class Rc12CleanInstallGateTests(unittest.TestCase):
    def test_shell_syntax_is_valid(self) -> None:
        result = subprocess.run(["bash", "-n", str(GATE)], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_real_kit_acceptance_uses_hidden_passphrase_and_no_restore(self) -> None:
        path = GATE.with_name("25-rc12-real-encrypted-kit-path.py")
        source = path.read_text(encoding="utf-8")
        ast.parse(source, filename=str(path))
        self.assertIn("recovery_ux.acquire_offline_identity(", source)
        self.assertIn('side_effect=["4", str(source)]', source)
        self.assertIn("offline-identity-*", source)
        self.assertNotIn("vwctl restore", source)
        self.assertNotIn("getpass.getpass(", source)  # product UX owns hidden passphrase entry

    def test_installer_gate_does_not_start_services_or_cloud_writes(self) -> None:
        text = GATE.read_text(encoding="utf-8")
        self.assertIn("storage.reject_boot_related", text)
        self.assertIn('TMPDIR=/run', text)
        self.assertIn("--confirm-format --auto", text)
        self.assertIn("--auto --dry-run", text)
        self.assertIn('diff --quiet "$PIN" HEAD', text)
        self.assertNotIn("vwctl dns update", text)
        self.assertNotIn("vwctl crowdsec remediation-start", text)
        self.assertNotIn("vwctl backup", text)
        self.assertNotIn("systemctl enable --now", text)
        self.assertNotIn("systemctl reboot", text)


if __name__ == "__main__":
    unittest.main()
