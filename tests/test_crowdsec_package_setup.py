from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import edge
from vaultwarden_oci.cli import CommandResult


def result(argv, *, code: int = 0, stdout: str = "", stderr: str = "") -> CommandResult:
    return CommandResult(
        tuple(argv),
        "success" if code == 0 else "nonzero",
        code,
        stdout,
        stderr,
    )


def test_paths(root: Path) -> edge.EdgePaths:
    acquisition = root / "etc/crowdsec/acquis.d/vaultwarden-oci.yaml"
    dropin = root / "systemd/bouncer.d/vaultwarden-oci.conf"
    acquisition.parent.mkdir(parents=True)
    dropin.parent.mkdir(parents=True)
    return edge.EdgePaths(
        lkg=root / "state/cloudflare.json",
        acquisition=acquisition,
        bouncer_dropin=dropin,
        remediation_config=root / "run/bouncer.yaml",
        caddy_log=root / "caddy/access.log",
        remediation_start_token=root / "run/start.token",
        fail_open_confirmation=root / "state/fail-open.json",
    )


class CrowdSecPackageSetupTests(unittest.TestCase):
    def test_package_services_are_suppressed_only_during_apt_install(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = test_paths(root)
            policy = root / "policy-rc.d"
            installer = root / "installer.sh"
            installer.write_text("exit 0\n", encoding="utf-8")
            calls: list[tuple[tuple[str, ...], dict[str, str] | None]] = []

            def runner(argv, *, env=None, cwd=None):
                call = tuple(argv)
                calls.append((call, dict(env) if env is not None else None))
                if call[:3] == ("apt-get", "install", "-y"):
                    self.assertTrue(policy.is_file())
                    self.assertEqual(policy.read_text(encoding="utf-8"), "#!/bin/sh\nexit 101\n")
                    self.assertEqual(policy.stat().st_mode & 0o777, 0o755)
                    self.assertIsNotNone(env)
                    self.assertEqual(env["DEBIAN_FRONTEND"], "noninteractive")
                    self.assertEqual(env["CROWDSEC_SETUP_UNATTENDED_DISABLE"], "1")
                if call[:4] == ("cscli", "-oraw", "bouncers", "add"):
                    return result(argv, stdout="firewall-lapi-key\n")
                if call[:4] == ("cscli", "config", "show", "-oraw"):
                    return result(argv, stdout="127.0.0.1:8080\n")
                return result(argv)

            with mock.patch.object(edge, "_download_installer", return_value=installer):
                edge.setup_crowdsec(paths=paths, runner=runner, policy_path=policy)

            self.assertFalse(policy.exists())
            commands = [call for call, _ in calls]
            install_index = next(i for i, call in enumerate(commands) if call[:3] == ("apt-get", "install", "-y"))
            disable_index = commands.index(("systemctl", "disable", "--now", edge.BOUNCER_SERVICE))
            self.assertLess(install_index, disable_index)
            self.assertIn(
                ("cscli", "-oraw", "bouncers", "add", edge.FIREWALL_BOUNCER_ID),
                commands,
            )
            self.assertTrue(paths.acquisition.is_file())
            self.assertTrue(paths.bouncer_dropin.is_file())

    def test_existing_host_policy_is_never_overwritten(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = test_paths(root)
            policy = root / "policy-rc.d"
            original = "#!/bin/sh\n# host-owned policy\nexit 0\n"
            policy.write_text(original, encoding="utf-8")
            os.chmod(policy, 0o755)
            installer = root / "installer.sh"
            installer.write_text("exit 0\n", encoding="utf-8")

            def runner(argv, *, env=None, cwd=None):
                return result(argv)

            with mock.patch.object(edge, "_download_installer", return_value=installer):
                with self.assertRaisesRegex(edge.EdgeError, "already exists"):
                    edge.setup_crowdsec(paths=paths, runner=runner, policy_path=policy)

            self.assertEqual(policy.read_text(encoding="utf-8"), original)
            self.assertEqual(policy.stat().st_mode & 0o777, 0o755)

    def test_apt_failure_reports_diagnostic_and_removes_temporary_policy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = test_paths(root)
            policy = root / "policy-rc.d"
            installer = root / "installer.sh"
            installer.write_text("exit 0\n", encoding="utf-8")
            calls: list[tuple[str, ...]] = []

            def runner(argv, *, env=None, cwd=None):
                call = tuple(argv)
                calls.append(call)
                if call[:3] == ("apt-get", "install", "-y"):
                    self.assertTrue(policy.exists())
                    return result(
                        argv,
                        code=100,
                        stderr=(
                            "Setting up crowdsec (1.7.8) ...\n"
                            "dpkg: error processing package crowdsec (--configure):\n"
                            " installed crowdsec package post-installation script subprocess returned error exit status 1\n"
                        ),
                    )
                return result(argv)

            with mock.patch.object(edge, "_download_installer", return_value=installer):
                with self.assertRaisesRegex(
                    edge.EdgeError,
                    r"CrowdSec package installation failed \(exit 100\).*dpkg: error processing package crowdsec",
                ):
                    edge.setup_crowdsec(paths=paths, runner=runner, policy_path=policy)

            self.assertFalse(policy.exists())
            self.assertFalse(any(call[:2] == ("systemctl", "disable") for call in calls))


if __name__ == "__main__":
    unittest.main()
