"""P8Q read-only postboot failure classifier and privacy regression tests."""
from __future__ import annotations

import importlib.util
import io
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from contextlib import redirect_stdout
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance/production-p8q-postboot-readonly-diagnostic.py"
SPEC = importlib.util.spec_from_file_location("p8q_readonly_diagnostic", SCRIPT)
assert SPEC and SPEC.loader
p8q = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(p8q)


class P8QTests(unittest.TestCase):
    def test_reviewed_import_is_exact_prior_source_only(self):
        self.assertEqual(p8q.HOST, "vaultwarden-oci-7-vnic")
        self.assertEqual(len(p8q.PRIOR_SHA), 40)
        self.assertEqual(p8q.PRIOR_SCRIPT.name,
                         "production-p8p-batched-reboot-persistence-newvm.py")
        self.assertTrue(str(p8q.PRIOR_SCRIPT).startswith("/home/ubuntu/"))

    def test_invalid_commit_never_executes_git(self):
        with mock.patch.object(p8q.subprocess, "run") as cmd:
            for value in ("invalid", "a" * 39, "A" * 40):
                self.assertFalse(p8q.git_clean(Path("/tmp"), "branch", value))
            cmd.assert_not_called()

    def test_missing_previous_checkout_rejected(self):
        self.assertFalse(p8q.git_clean(Path("/does-not-exist-p8q"), p8q.PRIOR_BRANCH,
                                        p8q.PRIOR_SHA))

    def test_report_safe_allowlisted_states(self):
        with tempfile.TemporaryDirectory() as d:
            report = p8q.Report(Path(d))
            self.assertTrue(report.check("safe.positive", lambda: True))
            self.assertFalse(report.check("safe.failure", lambda: False))
            self.assertFalse(report.check("safe.pending", lambda: "PENDING"))
            self.assertEqual(report.states, {
                "safe.positive": "PASS",
                "safe.failure": "BLOCKED",
                "safe.pending": "PENDING",
            })

    def test_report_catches_private_exceptions_without_echo(self):
        with tempfile.TemporaryDirectory() as d:
            report = p8q.Report(Path(d))
            def secret():
                raise RuntimeError("SECRET-DO-NOT-EMIT")
            self.assertFalse(report.check("secrets.custody", secret))
            output = io.StringIO()
            with redirect_stdout(output):
                self.assertEqual(report.finish(), 2)
            self.assertIn("BLOCKED", output.getvalue())
            self.assertNotIn("SECRET", output.getvalue())
            self.assertNotIn("SECRET", (Path(d) / "summary.txt").read_text())

    def test_report_skips_dependent_checks(self):
        with tempfile.TemporaryDirectory() as d:
            report = p8q.Report(Path(d))
            report.record("source.checked", "BLOCKED")
            target = mock.Mock()
            self.assertFalse(report.check("protected.database", target,
                                          needs=("source.checked",)))
            target.assert_not_called()
            self.assertEqual(report.states["protected.database"], "NOT RUN")

    def test_report_private_summary_and_readonly_verdict(self):
        with tempfile.TemporaryDirectory() as d:
            report = p8q.Report(Path(d))
            report.record("checked.safe", "PASS")
            report.record("other.pending", "PENDING")
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(report.finish(), 0)
            content = (Path(d) / "summary.txt").read_text()
            self.assertEqual((Path(d) / "summary.txt").stat().st_mode & 0o777, 0o600)
            self.assertIn("READONLY", content)
            self.assertNotIn("PRODUCTION GO", content)

    def test_report_rejects_duplicate_secret_bearing_keys(self):
        with tempfile.TemporaryDirectory() as d:
            report = p8q.Report(Path(d))
            report.record("safe.check", "PASS")
            for key, state in (("safe.check", "PASS"), ("unsafe Key", "PASS"),
                               ("unsafe\nkey", "PASS"), ("good.name", "KEY")):
                with self.assertRaises(p8q.Blocked):
                    report.record(key, state)

    def test_app_units_must_be_off(self):
        units = tuple("vaultwarden-oci-unit" + str(i) + ".service" for i in range(11))
        units += ("vaultwarden-oci-notify@.service",)
        install = SimpleNamespace(SYSTEMD_UNITS=units)
        p8p = SimpleNamespace(systemd_state=lambda _: {
            "LoadState": "loaded", "ActiveState": "inactive", "UnitFileState": "disabled"
        })
        self.assertTrue(p8q.stopped_app_units(p8p, install))
        p8p.systemd_state = lambda _: {
            "LoadState": "loaded", "ActiveState": "active", "UnitFileState": "enabled"
        }
        self.assertFalse(p8q.stopped_app_units(p8p, install))

    def test_notification_template_must_have_no_instance(self):
        safe = [
            (0, ""),
            (0, "vaultwarden-oci-notify@.service static\n"),
        ]
        p8p = SimpleNamespace(run=mock.Mock(side_effect=safe))
        self.assertTrue(p8q.notify_template_off(p8p))
        bad = [
            (0, "vaultwarden-oci-notify@bad.service loaded active running\n"),
            (0, "vaultwarden-oci-notify@.service static\n"),
        ]
        p8p.run = mock.Mock(side_effect=bad)
        self.assertFalse(p8q.notify_template_off(p8p))

    def test_listener_443_is_never_accepted(self):
        p8p = SimpleNamespace(run=lambda _: (0, "LISTEN 0 128 127.0.0.1:22 0.0.0.0:*\n"))
        self.assertTrue(p8q.listeners_closed(p8p))
        p8p.run = lambda _: (0, "LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n")
        self.assertFalse(p8q.listeners_closed(p8p))
        p8p.run = lambda _: (None, "")
        self.assertFalse(p8q.listeners_closed(p8p))

    def test_container_inventory_fails_when_container_retained(self):
        p8p = SimpleNamespace(run=lambda *a, **k: (0, "unexpected-id\n"))
        self.assertFalse(p8q.containers_absent(p8p))
        p8p.run = lambda *a, **k: (None, "")
        self.assertFalse(p8q.containers_absent(p8p))

    def test_security_unit_distinguishes_engine_and_worker(self):
        states = {
            "crowdsec.service": {
                "LoadState": "loaded", "ActiveState": "active",
                "UnitFileState": "enabled",
            },
            "crowdsec-cloudflare-worker-bouncer.service": {
                "LoadState": "loaded", "ActiveState": "inactive",
                "UnitFileState": "disabled",
            },
        }
        p8p = SimpleNamespace(systemd_state=lambda name: states[name])
        self.assertTrue(p8q.security_unit(p8p, "crowdsec.service",
                                           active="active", enablement="enabled"))
        self.assertTrue(p8q.security_unit(p8p, "crowdsec-cloudflare-worker-bouncer.service",
                                           active="inactive", enablement="disabled"))
        self.assertFalse(p8q.security_unit(p8p, "crowdsec.service",
                                            active="inactive", enablement="disabled"))

    def test_root_custody_contract_never_prints_sops_values(self):
        holder = SimpleNamespace(
            validate_custody=mock.Mock(return_value=None),
            validate_encrypted=mock.Mock(return_value={"cloudflare_remediation_token": "PRIVATE"}),
            admin_enabled=lambda values: True,
        )
        config = SimpleNamespace(offline_recovery_recipient="age1fakepublic")
        self.assertTrue(p8q.secured_secrets(holder, config))
        holder.validate_custody.assert_called_once_with("age1fakepublic")
        holder.validate_encrypted.assert_called_once()

    def test_strict_config_fails_on_modified_offsite(self):
        from hashlib import sha256
        pub = "age1-public"
        p8p = SimpleNamespace(
            DOMAIN="example.test", EMAIL="admin@example.test",
            REMOTE="remote:expected", RECIPIENT_SHA=sha256(pub.encode()).hexdigest(),
            sha_bytes=lambda raw: sha256(raw).hexdigest()
        )
        cfg = SimpleNamespace(
            domain="example.test", acme_email="admin@example.test",
            offline_recovery_recipient=pub, offsite_remote="remote:expected",
            local_retention_days=0, remote_retention_days=0,
            smtp_accept_invalid_certs=False, smtp_accept_invalid_hostnames=False,
        )
        self.assertTrue(p8q.config_ok(p8p, cfg))
        cfg.offsite_remote = "remote:unknown"
        self.assertFalse(p8q.config_ok(p8p, cfg))
        cfg.offsite_remote = "remote:expected"
        cfg.local_retention_days = 10
        self.assertFalse(p8q.config_ok(p8p, cfg))

    def test_doctor_security_failures_classified_without_raw_messages(self):
        mandatory = {"host.os", "host.architecture", "storage.dedicated",
                     "secrets.custody", "secrets.decrypt"}
        foundation = {"edge.cloudflare.cidrs", "edge.cloudflare.iptables",
                      "crowdsec.engine", "crowdsec.hub", "crowdsec.firewall"}
        ids = sorted(mandatory | foundation | {"crowdsec.cloudflare", "runtime.paths"})
        ids += ["check.other" + str(i) for i in range(27 - len(ids))]
        statuses = dict.fromkeys(ids, "PASS")
        statuses["edge.cloudflare.iptables"] = "FAIL"
        statuses["crowdsec.cloudflare"] = "FAIL"
        statuses["runtime.paths"] = "FAIL"
        helper = SimpleNamespace(
            diagnose_doctor=lambda *a, **k: ("valid", statuses, "contains-private"),
            product_doctor_ids=lambda: tuple(ids),
        )
        prior = SimpleNamespace(MANDATORY=mandatory, FOUNDATION=tuple(foundation))
        with tempfile.TemporaryDirectory() as d:
            report = p8q.Report(Path(d))
            parsed = p8q.private_doctor(prior, helper, Path(d), report)
            self.assertEqual(parsed, statuses)
            self.assertEqual(report.states["doctor.27-id-schema"], "PASS")
            self.assertEqual(report.states["doctor.edge.cloudflare.iptables"], "PENDING")
            self.assertEqual(report.states["doctor.crowdsec.cloudflare"], "PASS")
            self.assertEqual(report.states["doctor.runtime.paths"], "PENDING")
            self.assertNotIn("contains-private", str(report.rows))

    def test_doctor_mandatory_failure_is_blocked(self):
        mandatory = {"host.os", "host.architecture", "storage.dedicated",
                     "secrets.custody", "secrets.decrypt"}
        foundation = {"edge.cloudflare.cidrs", "edge.cloudflare.iptables",
                      "crowdsec.engine", "crowdsec.hub", "crowdsec.firewall"}
        ids = sorted(mandatory | foundation | {"crowdsec.cloudflare", "runtime.paths"})
        ids += ["check.other" + str(i) for i in range(27 - len(ids))]
        statuses = dict.fromkeys(ids, "PASS")
        statuses["host.os"] = "FAIL"
        statuses["crowdsec.cloudflare"] = "FAIL"
        helper = SimpleNamespace(
            diagnose_doctor=lambda *a, **k: ("valid", statuses, ""),
            product_doctor_ids=lambda: tuple(ids),
        )
        prior = SimpleNamespace(MANDATORY=mandatory, FOUNDATION=tuple(foundation))
        with tempfile.TemporaryDirectory() as d:
            report = p8q.Report(Path(d))
            p8q.private_doctor(prior, helper, Path(d), report)
            self.assertEqual(report.states["doctor.host.os"], "BLOCKED")

    def test_wrong_invocation_never_imports_original_gate(self):
        with mock.patch.object(p8q, "checked_helper") as read_gate:
            with mock.patch.object(p8q.sys, "argv", [str(SCRIPT), "--expected-commit", "invalid"]):
                with redirect_stdout(io.StringIO()):
                    self.assertEqual(p8q.main(), 2)
            read_gate.assert_not_called()

    def test_no_mutating_commands_in_diagnostic_script(self):
        src = SCRIPT.read_text()
        for forbidden in (
            '["/usr/bin/systemctl", "reboot"]',
            '"edge", "refresh"',
            '"crowdsec", "setup"',
            '"dns", "update"',
            '"remediation-start"',
            '"backup", "--remote"',
            "restore_recovery(",
            "rclone copy",
            "rclone delete",
            '["/usr/bin/docker", "run"',
        ):
            self.assertNotIn(forbidden, src)


if __name__ == "__main__":
    unittest.main()
