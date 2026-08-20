from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import edge
from vaultwarden_oci.cli import CommandResult


def result(argv, code=0):
    return CommandResult(tuple(argv), "success" if code == 0 else "nonzero", code, "", "")


class CrowdSecScopeTests(unittest.TestCase):
    def test_setup_removes_detected_inputs_before_installing_caddy_only(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            acquis_dir = root / "etc/crowdsec/acquis.d"
            acquis_dir.mkdir(parents=True, mode=0o755)
            os.chmod(acquis_dir, 0o755)
            (acquis_dir / "sshd.yaml").write_text(
                "filenames:\n  - /var/log/auth.log\nlabels:\n  type: syslog\n",
                encoding="utf-8",
            )
            (acquis_dir / "linux.yml").write_text(
                "filenames:\n  - /var/log/syslog\nlabels:\n  type: syslog\n",
                encoding="utf-8",
            )
            paths = edge.EdgePaths(
                lkg=root / "state/cloudflare.json",
                acquisition=acquis_dir / "vaultwarden-oci.yaml",
                bouncer_dropin=root / "systemd/bouncer.d/vaultwarden-oci.conf",
                remediation_config=root / "run/bouncer.yaml",
                caddy_log=root / "caddy/access.log",
            )
            installer = root / "installer.sh"
            installer.write_text("exit 0\n", encoding="utf-8")
            calls: list[tuple[str, ...]] = []

            def runner(argv, *, env=None, cwd=None):
                calls.append(tuple(argv))
                return result(argv)

            with mock.patch.object(edge, "_download_installer", return_value=installer):
                edge.setup_crowdsec(paths=paths, runner=runner)

            self.assertFalse((acquis_dir / "sshd.yaml").exists())
            self.assertFalse((acquis_dir / "linux.yml").exists())
            self.assertTrue(paths.acquisition.exists())
            self.assertEqual(
                [entry.name for entry in acquis_dir.iterdir()],
                ["vaultwarden-oci.yaml"],
            )
            self.assertEqual(acquis_dir.stat().st_mode & 0o777, 0o755)

            reset = calls.index(("cscli", "collections", "remove", "--all"))
            install = calls.index(("cscli", "collections", "install", "crowdsecurity/caddy"))
            stop = calls.index(("systemctl", "stop", edge.CROWDSEC_SERVICE))
            self.assertLess(stop, reset)
            self.assertLess(reset, install)
            self.assertFalse(any("firewall-bouncer" in " ".join(call) for call in calls))


if __name__ == "__main__":
    unittest.main()
