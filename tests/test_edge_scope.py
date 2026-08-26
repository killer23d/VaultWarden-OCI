from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import edge
from vaultwarden_oci.cli import CommandResult


def result(argv, code=0, stdout=""):
    return CommandResult(tuple(argv), "success" if code == 0 else "nonzero", code, stdout, "")


def edge_paths(root: Path) -> edge.EdgePaths:
    return edge.EdgePaths(
        lkg=root / "state/cloudflare.json",
        acquisition=root / "etc/crowdsec/acquis.d/vaultwarden-oci.yaml",
        bouncer_dropin=root / "systemd/bouncer.d/vaultwarden-oci.conf",
        remediation_config=root / "run/bouncer.yaml",
        caddy_log=root / "caddy/access.log",
        remediation_start_token=root / "run/start.token",
        fail_open_confirmation=root / "state/fail-open.json",
    )


class CrowdSecScopeTests(unittest.TestCase):
    def test_setup_disables_service_discovery_and_leaves_bouncer_boot_disabled(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = edge_paths(root)
            paths.acquisition.parent.mkdir(parents=True, mode=0o755)
            os.chmod(paths.acquisition.parent, 0o755)
            installer = root / "installer.sh"
            installer.write_text("exit 0\n", encoding="utf-8")
            calls: list[tuple[tuple[str, ...], dict[str, str]]] = []

            def runner(argv, *, env=None, cwd=None):
                calls.append((tuple(argv), dict(env or {})))
                return result(argv)

            with mock.patch.object(edge, "_download_installer", return_value=installer):
                edge.setup_crowdsec(paths=paths, runner=runner)

            argv_calls = [call for call, _ in calls]
            install_index = argv_calls.index(
                ("apt-get", "install", "-y", "crowdsec", "crowdsec-cloudflare-worker-bouncer")
            )
            self.assertEqual(calls[install_index][1].get("CROWDSEC_SETUP_UNATTENDED_DISABLE"), "1")
            self.assertIn(
                ("systemctl", "disable", "--now", edge.BOUNCER_SERVICE),
                argv_calls,
            )
            self.assertNotIn(
                ("systemctl", "enable", "--now", edge.BOUNCER_SERVICE),
                argv_calls,
            )
            self.assertIn(
                ("cscli", "collections", "install", "crowdsecurity/caddy"),
                argv_calls,
            )
            self.assertTrue(paths.acquisition.exists())
            self.assertEqual(paths.acquisition.parent.stat().st_mode & 0o777, 0o755)
            self.assertFalse(any("firewall-bouncer" in " ".join(call) for call in argv_calls))

    def test_setup_refuses_unexpected_acquisition_without_deleting_it(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = edge_paths(root)
            paths.acquisition.parent.mkdir(parents=True)
            unexpected = paths.acquisition.parent / "sshd.yaml"
            unexpected.write_text(
                "filenames:\n  - /var/log/auth.log\nlabels:\n  type: syslog\n",
                encoding="utf-8",
            )
            installer = root / "installer.sh"
            installer.write_text("exit 0\n", encoding="utf-8")

            def runner(argv, *, env=None, cwd=None):
                return result(argv)

            with mock.patch.object(edge, "_download_installer", return_value=installer):
                with self.assertRaisesRegex(edge.EdgeError, "unexpected CrowdSec acquisition"):
                    edge.setup_crowdsec(paths=paths, runner=runner)

            self.assertTrue(unexpected.exists())
            self.assertFalse(paths.acquisition.exists())


if __name__ == "__main__":
    unittest.main()
