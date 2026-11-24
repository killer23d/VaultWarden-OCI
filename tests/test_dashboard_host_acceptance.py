"""Isolated safety checks for the console witness; never live-host evidence."""
from __future__ import annotations

import importlib.util
import hashlib
import io
import json
import os
import pwd
import subprocess
import sys
import tempfile
import unittest
from contextlib import ExitStack, contextmanager, redirect_stdout
from pathlib import Path
from unittest import mock

from vaultwarden_oci import install, update_versions

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("console_witness", ROOT / "tests/host-acceptance/dashboard-console.py")
assert spec and spec.loader
console = importlib.util.module_from_spec(spec)
spec.loader.exec_module(console)


@contextmanager
def isolated_install(*, frozen=False):
    """Real installer comparison logic with all paths in one disposable directory."""
    with tempfile.TemporaryDirectory() as directory, ExitStack() as patches:
        root = Path(directory)
        selected = root / "releases" / install.load_versions(ROOT / "versions.toml").version
        selected.mkdir(parents=True)
        install._copy_release_tree(ROOT, selected)
        if frozen:
            (selected / "versions.toml").write_text(update_versions.frozen_versions_toml(
                update_versions.resolve_pinned(ROOT, machine="aarch64")), encoding="utf-8")
        install._make_release_immutable(selected)
        current, launcher = root / "current", root / "vwctl"
        current.symlink_to(Path("releases") / selected.name)
        launcher.symlink_to(current / "vwctl")
        units = root / "units"
        units.mkdir()
        for unit in install.SYSTEMD_UNITS:
            target = units / unit
            target.write_bytes((selected / "systemd" / unit).read_bytes())
            target.chmod(0o644)
        for name, value in (("CURRENT_LINK", current), ("VWCTL_LINK", launcher),
                            ("RELEASES_DIR", root / "releases"), ("SYSTEMD_DIR", units)):
            patches.enter_context(mock.patch.object(install, name, value))
        # Ubuntu CI runs unprivileged. Root-specific ownership is checked below;
        # fixture file owners must stay with the test user, without any chown.
        patches.enter_context(mock.patch.object(console, "require_root_ownership"))
        try:
            yield root, selected
        finally:
            install._remove_release_staging(selected)


class DashboardHostAcceptanceTests(unittest.TestCase):
    def test_malformed_scope_stops_before_host_source_or_process_access(self):
        output = io.StringIO()
        with mock.patch.object(console, "native_host") as host, mock.patch.object(console, "terminal") as terminal, redirect_stdout(output):
            code = console.main(["--expected-host", "host", "--expected-sha", "moving-branch", "--source", "/tmp/source"])
        self.assertEqual(code, 2)
        self.assertEqual(json.loads(output.getvalue())["verdict"], "HOLD")
        host.assert_not_called()
        terminal.assert_not_called()

    def test_failed_empty_git_status_is_never_a_clean_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".git").mkdir()
            (root / ".git/index").write_bytes(b"fixture")
            replies = [subprocess.CompletedProcess([], 0, "a" * 40 + "\n"), subprocess.CompletedProcess([], 1, "")]
            with mock.patch.object(console, "read_command", side_effect=replies), self.assertRaises(console.Hold):
                console.verified_source(root, "a" * 40, pwd.getpwuid(os.getuid()))

    def test_clean_index_cannot_hide_changed_tracked_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".git").mkdir()
            (root / ".git/index").write_bytes(b"fixture")
            (root / "vwctl").write_bytes(b"changed")
            replies = [
                subprocess.CompletedProcess([], 0, "a" * 40 + "\n"),
                subprocess.CompletedProcess([], 0, ""),
                subprocess.CompletedProcess([], 0, "100644 blob " + "b" * 40 + "\tvwctl\0"),
            ]
            with mock.patch.object(console, "read_command", side_effect=replies), self.assertRaisesRegex(console.Hold, "tracked source bytes"):
                console.verified_source(root, "a" * 40, pwd.getpwuid(os.getuid()))

    def test_ignored_bytecode_is_refused_before_project_imports(self):
        for relative in ("__pycache__/__init__.cpython-313.pyc", "untracked.pyc"):
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / ".git").mkdir()
                (root / ".git/index").write_bytes(b"fixture")
                package = root / "vaultwarden_oci"
                package.mkdir()
                content = b"# reviewed package\n"
                (package / "__init__.py").write_bytes(content)
                unverified = package / relative
                unverified.parent.mkdir(parents=True, exist_ok=True)
                unverified.write_bytes(b"unverified bytecode")
                digest = hashlib.sha1(b"blob " + str(len(content)).encode("ascii") + b"\0" + content).hexdigest()
                replies = [
                    subprocess.CompletedProcess([], 0, "a" * 40 + "\n"),
                    subprocess.CompletedProcess([], 0, ""),
                    subprocess.CompletedProcess([], 0, f"100644 blob {digest}\tvaultwarden_oci/__init__.py\0"),
                ]
                with mock.patch.object(console, "read_command", side_effect=replies), self.assertRaisesRegex(console.Hold, "bytecode or cache"):
                    console.verified_source(root, "a" * 40, pwd.getpwuid(os.getuid()))

    def test_exact_and_canonical_arm64_manifest_compare_without_changing_installation(self):
        for frozen in (False, True):
            with self.subTest(frozen=frozen), isolated_install(frozen=frozen) as (root, selected):
                before = console.snapshot([selected, install.CURRENT_LINK, install.VWCTL_LINK, install.SYSTEMD_DIR])
                actual, kind, _ = console.verify_installation(ROOT, install, update_versions, temporary_base=root)
                self.assertEqual(actual, selected)
                self.assertEqual(kind, "canonical_arm64_frozen_manifest" if frozen else "exact_source_manifest")
                self.assertEqual(console.snapshot([selected, install.CURRENT_LINK, install.VWCTL_LINK, install.SYSTEMD_DIR]), before)

    def test_noncanonical_current_symlink_is_refused(self):
        for absolute in (True, False):
            with self.subTest(absolute=absolute), isolated_install() as (root, selected):
                install.CURRENT_LINK.unlink()
                install.CURRENT_LINK.symlink_to(selected if absolute else Path("releases") / "wrong")
                with self.assertRaises(install.InstallError):
                    console.verify_installation(ROOT, install, update_versions, temporary_base=root)

    def test_installed_file_drift_fails_before_console_execution(self):
        with isolated_install() as (root, selected):
            target = selected / "vaultwarden_oci/dashboard.py"
            target.chmod(0o644)
            target.write_bytes(target.read_bytes() + b"\n# changed fixture\n")
            target.chmod(0o444)
            with self.assertRaisesRegex(console.Hold, "immutable content"):
                console.verify_installation(ROOT, install, update_versions, temporary_base=root)

    def test_nonroot_installed_owner_is_refused(self):
        path = mock.Mock()
        path.lstat.return_value = mock.Mock(st_uid=1000, st_gid=0)
        with self.assertRaisesRegex(console.Hold, "root:root"):
            console.require_root_ownership([path])

    def test_only_exit_and_default_no_inputs_are_scheduled(self):
        cases = console.smoke_cases(Path("/installed/vwctl"), Path("/installed/release"))
        self.assertEqual(len(cases), 6)
        self.assertEqual([row[2] for row in cases], [b"q\n", b"q\n", b"b\n", b"\n", b"\n", b"\n"])
        self.assertEqual([row[1][1:] for row in cases[2:]],
                         [["guide"], ["guide", "restore"], ["guide", "offsite"], ["guide", "recovery-kit"]])

    def test_menu_exit_requires_complete_outcome_and_exact_version(self):
        name, _, _, markers = console.smoke_cases(Path("/installed/vwctl"), Path("/installed/0.1.0-rc.18"))[0]
        valid = "\n".join((markers[0], "Outcome: ATTENTION", *markers[2:]))
        console.require_terminal_result(name, 0, valid, markers)
        for invalid in (valid.replace("ATTENTION", "INCOMPLETE VERIFICATION"),
                        valid.replace("0.1.0-rc.18", "unknown"),
                        valid + "\nOutcome: OPERATIONAL",
                        valid.replace("Outcome: ATTENTION", "Outcome: unexpected")):
            with self.subTest(output=invalid), self.assertRaises(console.Hold):
                console.require_terminal_result(name, 0, invalid, markers)

    def test_no_color_smoke_refuses_escape_sequences(self):
        with self.assertRaisesRegex(console.Hold, "escape sequence"):
            console.require_terminal_result("guide_selector_back", 0, "\x1b[32mAvailable guided operations", ("Available guided operations",))

    def test_real_pty_supplies_only_blank_default_no(self):
        program = "import sys; assert sys.stdin.isatty() and sys.stdout.isatty(); answer=input('Continue? [y/N]: '); assert answer == ''; print('CANCELLED')"
        code, output = console.terminal([sys.executable, "-B", "-I", "-c", program], b"\n", timeout=5)
        self.assertEqual(code, 0)
        self.assertIn("CANCELLED", output)

    def test_timeout_reaps_own_process_without_returning_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            pidfile = Path(directory) / "pid"
            program = "import os, pathlib, sys, time; pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(60)"
            with self.assertRaisesRegex(console.Hold, "timed out"):
                console.terminal([sys.executable, "-B", "-I", "-c", program, str(pidfile)], b"", timeout=1)
            if pidfile.exists():
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(pidfile.read_text()), 0)


if __name__ == "__main__":
    unittest.main()
