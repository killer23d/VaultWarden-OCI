from __future__ import annotations

import json
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import admin, runtime, secrets
from vaultwarden_oci.cli import CommandResult, DoctorCheck

OFFLINE = "age1" + "q" * 58
OPERATIONAL = "age1" + "p" * 58
ADMIN_PHC = "$argon2id$v=19$m=65540,t=3,p=4$c2FsdA$YWJjZA"
VALUES = {
    "cloudflare_api_token": "A" * 40,
    "smtp_username": "mailer@example.net",
    "smtp_password": "smtp=$secret#raw",
    "vaultwarden_admin_token": "admin-secret",
    "admin_basic_auth_password": "outer-gate-secret",
}


def result(argv, stdout="", stderr="", code=0):
    return CommandResult(tuple(argv), "success" if code == 0 else "nonzero", code, stdout, stderr)


def config_text() -> str:
    return f'''schema_version = 1
[site]
domain = "vault.example.net"
acme_email = "admin@example.net"
[secrets]
offline_recovery_recipient = "{OFFLINE}"
[vaultwarden]
signups_allowed = false
[smtp]
host = "smtp.example.net"
port = 587
security = "starttls"
from_email = "vaultwarden@example.net"
from_name = "Vaultwarden"
timeout_seconds = 15
'''


def versions_text() -> str:
    return '''schema_version = 1
[vaultwarden_oci]
version = "0.1.0-dev.7"
[components]
vaultwarden = "1.37.1"
caddy = "2.11.4"
caddy_dns_cloudflare = "v0.2.4"
caddy_cloudflare_ip = "f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5"
caddy_combine_ip_ranges = "v0.0.1"
caddy_ratelimit = "v0.1.0"
[image_digests.vaultwarden]
amd64 = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
arm64 = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
[image_digests.caddy_builder]
amd64 = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
arm64 = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
[image_digests.caddy_runtime]
amd64 = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
arm64 = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
'''


def temp_paths(root: Path) -> runtime.Paths:
    return runtime.Paths(
        config=root / "config.toml",
        data=root / "data",
        caddy_data=root / "caddy-data",
        caddy_config=root / "caddy-config",
        run=root / "run",
        transient=root / "run/transient",
        lock=root / "run/lock",
        secret_root=root / "run/secrets",
    )


class RuntimeContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self._admin_hash = mock.patch.object(
            secrets, "derive_admin_basic_auth_hash", return_value="$2a$14$test-admin-hash"
        )
        self._vaultwarden_admin_hash = mock.patch.object(
            admin, "derive_vaultwarden_admin_phc", return_value=ADMIN_PHC
        )
        self._admin_hash.start()
        self._vaultwarden_admin_hash.start()

    def tearDown(self) -> None:
        self._vaultwarden_admin_hash.stop()
        self._admin_hash.stop()

    def test_config_to_runtime_rendering_validation_and_scope(self) -> None:
        import tomllib

        cfg = runtime.parse_config(tomllib.loads(config_text()))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = temp_paths(root)
            paths.transient.mkdir(parents=True)
            versions = root / "versions.toml"
            versions.write_text(versions_text(), encoding="utf-8")
            runtime.render(cfg, versions, paths)
            compose = paths.compose.read_text(encoding="utf-8")
            caddyfile = paths.caddyfile.read_text(encoding="utf-8")
            dockerfile = paths.dockerfile.read_text(encoding="utf-8")

        self.assertIn(
            "vaultwarden/server:1.37.1@sha256:" + "a" * 64,
            compose,
        )
        self.assertIn(
            "FROM caddy:2.11.4-builder-alpine@sha256:" + "c" * 64,
            dockerfile,
        )
        self.assertIn(
            "FROM caddy:2.11.4-alpine@sha256:" + "e" * 64,
            dockerfile,
        )
        self.assertIn("github.com/caddy-dns/cloudflare@v0.2.4", dockerfile)
        self.assertIn("github.com/WeidiDeng/caddy-cloudflare-ip@f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5", dockerfile)
        self.assertIn("github.com/fvbommel/caddy-combine-ip-ranges@v0.0.1", dockerfile)
        self.assertIn("github.com/mholt/caddy-ratelimit@v0.1.0", dockerfile)
        self.assertIn("trusted_proxies cloudflare", caddyfile)
        self.assertNotIn("trusted_proxies static", caddyfile)
        self.assertNotIn("ARG CADDY_VERSION", dockerfile)
        self.assertNotIn("CADDY_VERSION:", compose)
        self.assertIn(f'user: "{runtime.VAULTWARDEN_UID}:{runtime.VAULTWARDEN_GID}"', compose)
        self.assertIn(f'user: "{runtime.CADDY_UID}:{runtime.CADDY_GID}"', compose)
        self.assertIn("cap_drop: [ALL]", compose)
        self.assertIn("cap_add: [NET_BIND_SERVICE]", compose)
        self.assertIn("read_only: true", compose)
        self.assertIn("no-new-privileges:true", compose)
        self.assertIn('ports: ["443:443/tcp"]', compose)
        self.assertIn("http://127.0.0.1:2019/config/", compose)
        self.assertNotIn("caddy\", \"validate", compose)
        self.assertIn("dns cloudflare {env.CLOUDFLARE_API_TOKEN}", caddyfile)
        self.assertIn("admin 127.0.0.1:2019", caddyfile)
        self.assertIn("persist_config off", caddyfile)
        self.assertNotIn("crowdsec", compose.lower())
        self.assertNotIn("postfix", compose.lower())
        self.assertNotIn("rclone", compose.lower())
        for value in VALUES.values():
            self.assertNotIn(value, compose)
            self.assertNotIn(value, caddyfile)

        invalid = tomllib.loads(config_text())
        invalid["smtp"]["password"] = "plaintext-forbidden"
        with self.assertRaisesRegex(runtime.RuntimeConfigError, "unknown smtp"):
            runtime.parse_config(invalid)

    def test_sops_age_boundary_materialization_and_non_leakage(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sp = secrets.SecretPaths(
                encrypted=root / "secrets.sops.yaml",
                age_key=root / "age-key.txt",
                root=root / "run",
                vaultwarden=root / "run/vaultwarden",
                caddy=root / "run/caddy",
            )
            sp.age_key.write_text("AGE-SECRET-KEY-TEST\n", encoding="utf-8")
            os.chmod(sp.age_key, 0o600)
            sp.encrypted.write_text(
                f'''sops:
  age:
    - recipient: {OPERATIONAL}
    - recipient: {OFFLINE}
''',
                encoding="utf-8",
            )
            os.chmod(sp.encrypted, 0o600)
            calls = []

            def runner(argv, *, env=None, cwd=None):
                calls.append((tuple(argv), dict(env or {})))
                if argv[0] == "age-keygen":
                    return result(argv, OPERATIONAL + "\n")
                if argv[0] == "sops":
                    return result(argv, json.dumps(VALUES))
                raise AssertionError(argv)

            loaded = secrets.load(OFFLINE, paths=sp, runner=runner, uid=os.geteuid())
            self.assertEqual(loaded, VALUES)
            self.assertEqual(calls[0][0], ("age-keygen", "-y", str(sp.age_key)))
            self.assertEqual(
                calls[1][0],
                ("sops", "--decrypt", "--output-type", "json", str(sp.encrypted)),
            )
            self.assertEqual(calls[1][1]["SOPS_AGE_KEY_FILE"], str(sp.age_key))
            argv_text = " ".join(item for call, _ in calls for item in call)
            for value in VALUES.values():
                self.assertNotIn(value, argv_text)

            secrets.materialize(
                loaded,
                derived={"admin_basic_auth_hash": "$2a$14$test-admin-hash"},
                paths=sp,
                uid=os.geteuid(),
                gid=os.getegid(),
                vaultwarden_gid=os.getegid(),
                caddy_gid=os.getegid(),
            )
            for key in secrets.REQUIRED + secrets.OPTIONAL:
                path = sp.file(key)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o440)
            secrets.cleanup(sp)
            self.assertFalse(any(sp.file(key).exists() for key in secrets.REQUIRED + secrets.OPTIONAL))

    def test_malformed_cloudflare_token_is_rejected_without_echoing_value(self) -> None:
        malformed = "malformed-cloudflare-secret"
        payload = dict(VALUES, cloudflare_api_token=malformed)

        def runner(argv, *, env=None, cwd=None):
            return result(argv, json.dumps(payload))

        with self.assertRaises(secrets.SecretsError) as caught:
            secrets.decrypt(runner=runner)
        self.assertNotIn(malformed, str(caught.exception))
        self.assertIn("Cloudflare provider token format", str(caught.exception))

    def test_failed_sops_does_not_echo_plaintext(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sp = secrets.SecretPaths(
                encrypted=root / "sops.yaml",
                age_key=root / "key",
                root=root / "run",
                vaultwarden=root / "run/vaultwarden",
                caddy=root / "run/caddy",
            )

            def bad(argv, *, env=None, cwd=None):
                return result(argv, stderr="provider leaked super-secret", code=1)

            with self.assertRaises(secrets.SecretsError) as caught:
                secrets.decrypt(paths=sp, runner=bad)
            self.assertNotIn("super-secret", str(caught.exception))

    def test_failed_compose_start_cleans_materialized_plaintext(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = temp_paths(root)
            paths.run.mkdir(parents=True)
            paths.config.write_text(config_text(), encoding="utf-8")
            versions = root / "versions.toml"
            versions.write_text(versions_text(), encoding="utf-8")
            calls = []

            def runner(argv, *, env=None, cwd=None):
                call = tuple(argv)
                calls.append(call)
                if call[:2] == ("docker", "version"):
                    return result(argv, "28.4.0\n")
                if call[:3] == ("docker", "compose", "version"):
                    return result(argv, "2.39.1\n")
                if call[:4] == ("docker", "compose", "up", "--help"):
                    return result(argv, "--wait --wait-timeout\n")
                if call[:3] == ("docker", "compose", "-f") and "config" in call:
                    return result(argv)
                if call[:3] == ("docker", "compose", "-f") and "up" in call:
                    return result(argv, stderr="container start failed", code=1)
                if call[:3] == ("docker", "compose", "-f") and "down" in call:
                    return result(argv)
                raise AssertionError(argv)

            with mock.patch.object(secrets, "load", return_value=VALUES):
                with self.assertRaises(runtime.RuntimeOperationError) as caught:
                    runtime.lifecycle("start", paths=paths, versions_path=versions, runner=runner)
            for value in VALUES.values():
                self.assertNotIn(value, str(caught.exception))
            self.assertFalse(
                any(paths.secret_paths().file(key).exists() for key in secrets.REQUIRED + secrets.OPTIONAL)
            )
            self.assertTrue(any("down" in call for call in calls))

    def test_lifecycle_status_distinguishes_clean_stop_from_crash(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = temp_paths(root)
            paths.run.mkdir(parents=True)
            paths.config.write_text(config_text(), encoding="utf-8")
            versions = root / "versions.toml"
            versions.write_text(versions_text(), encoding="utf-8")
            calls = []
            states = {
                runtime.NAMES["vaultwarden"]: {
                    "Status": "running",
                    "Health": {"Status": "healthy"},
                },
                runtime.NAMES["caddy"]: {
                    "Status": "running",
                    "Health": {"Status": "healthy"},
                },
            }

            def runner(argv, *, env=None, cwd=None):
                call = tuple(argv)
                calls.append(call)
                if call[:2] == ("docker", "version"):
                    return result(argv, "28.4.0\n")
                if call[:3] == ("docker", "compose", "version"):
                    return result(argv, "2.39.1\n")
                if call[:4] == ("docker", "compose", "up", "--help"):
                    return result(argv, "--wait --wait-timeout\n")
                if call[:3] == ("docker", "compose", "-f"):
                    return result(argv)
                if call[:4] == ("docker", "container", "inspect", "--format"):
                    return result(argv, json.dumps(states[call[-1]]))
                if call[:3] == ("docker", "container", "inspect"):
                    return result(argv)
                if call[:2] in {("docker", "stop"), ("docker", "rm")}:
                    return result(argv)
                raise AssertionError(argv)

            with mock.patch.object(secrets, "load", return_value=VALUES), mock.patch.object(
                secrets, "materialize"
            ) as materialize:
                runtime.lifecycle("start", paths=paths, versions_path=versions, runner=runner)
                materialize.assert_called_once()
            materialized = materialize.call_args.args[0]
            self.assertEqual(materialized["vaultwarden_admin_token"], ADMIN_PHC)
            self.assertEqual(VALUES["vaultwarden_admin_token"], "admin-secret")
            self.assertTrue(any("config" in call and "--quiet" in call for call in calls))
            self.assertTrue(any("up" in call and "--wait" in call for call in calls))

            compose = paths.compose.read_text(encoding="utf-8")
            dockerfile = paths.dockerfile.read_text(encoding="utf-8")
            self.assertIn("vaultwarden/server:1.37.1@sha256:" + "a" * 64, compose)
            self.assertIn("caddy:2.11.4-builder-alpine@sha256:" + "c" * 64, dockerfile)

            with mock.patch.object(secrets, "load", return_value=VALUES), mock.patch.object(
                secrets, "materialize"
            ):
                runtime.lifecycle("restart", paths=paths, versions_path=versions, runner=runner)
            self.assertTrue(any("--force-recreate" in call for call in calls))
            self.assertIn(
                "vaultwarden/server:1.37.1@sha256:" + "a" * 64,
                paths.compose.read_text(encoding="utf-8"),
            )
            self.assertIn(
                "caddy:2.11.4-alpine@sha256:" + "e" * 64,
                paths.dockerfile.read_text(encoding="utf-8"),
            )

            overall, rows = runtime.status(runner=runner)
            self.assertEqual(overall, "running")
            self.assertEqual(len(rows), 2)

            states[runtime.NAMES["vaultwarden"]] = {"Status": "exited", "ExitCode": 1}
            states[runtime.NAMES["caddy"]] = {"Status": "dead", "ExitCode": 1}
            crashed, _ = runtime.status(runner=runner)
            self.assertEqual(crashed, "degraded")

            with mock.patch.object(secrets, "cleanup") as cleanup:
                runtime.lifecycle("stop", paths=paths, versions_path=versions, runner=runner)
                cleanup.assert_called_once()
            self.assertTrue(any(call[:2] == ("docker", "rm") for call in calls))

            def absent_runner(argv, *, env=None, cwd=None):
                call = tuple(argv)
                if call[:2] == ("docker", "version"):
                    return result(argv, "28.4.0\n")
                if call[:4] == ("docker", "container", "inspect", "--format"):
                    return result(argv, stderr="Error: No such object: container", code=1)
                raise AssertionError(argv)

            stopped, stopped_rows = runtime.status(runner=absent_runner)
            self.assertEqual(stopped, "stopped")
            self.assertTrue(all(row["state"] == "absent" for row in stopped_rows))

            def inspect_error_runner(argv, *, env=None, cwd=None):
                call = tuple(argv)
                if call[:2] == ("docker", "version"):
                    return result(argv, "28.4.0\n")
                if call[:4] == ("docker", "container", "inspect", "--format"):
                    return result(argv, stderr="permission denied", code=1)
                raise AssertionError(argv)

            uncertain, uncertain_rows = runtime.status(runner=inspect_error_runner)
            self.assertEqual(uncertain, "degraded")
            self.assertTrue(all(row["state"] == "unknown" for row in uncertain_rows))

    def test_stop_inspection_error_is_not_reported_as_success(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = temp_paths(root)
            paths.run.mkdir(parents=True)

            def runner(argv, *, env=None, cwd=None):
                call = tuple(argv)
                if call[:2] == ("docker", "version"):
                    return result(argv, "28.4.0\n")
                if call[:3] == ("docker", "container", "inspect"):
                    return result(argv, stderr="permission denied", code=1)
                raise AssertionError(argv)

            with mock.patch.object(secrets, "cleanup") as cleanup:
                with self.assertRaisesRegex(runtime.RuntimeOperationError, "stop state unknown"):
                    runtime.lifecycle("stop", paths=paths, runner=runner)
                cleanup.assert_not_called()

    def test_doctor_runtime_paths_reports_real_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = temp_paths(root)
            uid, gid = os.geteuid(), os.getegid()
            paths.run.mkdir(mode=0o700)
            paths.transient.mkdir(mode=0o700)
            paths.secret_root.mkdir(mode=0o700)
            paths.lock.touch(mode=0o600)

            before = runtime.runtime_paths_check(
                paths,
                uid=uid,
                gid=gid,
                vaultwarden_uid=uid,
                vaultwarden_gid=gid,
                caddy_uid=uid,
                caddy_gid=gid,
                check_service_identities=False,
            )
            self.assertEqual(before.status, "SKIP")

            runtime.ensure_paths(
                paths,
                uid=uid,
                gid=gid,
                vaultwarden_uid=uid,
                vaultwarden_gid=gid,
                caddy_uid=uid,
                caddy_gid=gid,
            )
            valid = runtime.runtime_paths_check(
                paths,
                uid=uid,
                gid=gid,
                vaultwarden_uid=uid,
                vaultwarden_gid=gid,
                caddy_uid=uid,
                caddy_gid=gid,
                check_service_identities=False,
            )
            self.assertEqual(valid.status, "PASS")

            os.chmod(paths.data, 0o755)
            drifted = runtime.runtime_paths_check(
                paths,
                uid=uid,
                gid=gid,
                vaultwarden_uid=uid,
                vaultwarden_gid=gid,
                caddy_uid=uid,
                caddy_gid=gid,
                check_service_identities=False,
            )
            self.assertEqual(drifted.status, "FAIL")

    def test_doctor_keeps_custody_and_decrypt_results_distinct(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = temp_paths(root)
            paths.config.write_text(config_text(), encoding="utf-8")

            def runner(argv, *, env=None, cwd=None):
                call = tuple(argv)
                if call[:2] == ("docker", "version"):
                    return result(argv, "28.4.0\n")
                if call[:3] == ("docker", "compose", "version"):
                    return result(argv, "2.39.1\n")
                if call[:4] == ("docker", "compose", "up", "--help"):
                    return result(argv, "--wait --wait-timeout\n")
                raise AssertionError(argv)

            with mock.patch.object(
                runtime,
                "runtime_paths_check",
                return_value=DoctorCheck("runtime.paths", "PASS", "test fixture"),
            ), mock.patch.object(secrets, "validate_custody"), mock.patch.object(
                secrets,
                "decrypt",
                side_effect=secrets.SecretsError("SOPS decryption failed (exit 1)"),
            ):
                checks = runtime.doctor_checks(
                    config_path=paths.config,
                    paths=paths,
                    runner=runner,
                )

            ids = [check.check_id for check in checks]
            self.assertEqual(len(ids), len(set(ids)))
            by_id = {check.check_id: check.status for check in checks}
            self.assertEqual(by_id["secrets.custody"], "PASS")
            self.assertEqual(by_id["secrets.decrypt"], "FAIL")

    def test_doctor_secret_messages_are_release_neutral(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = temp_paths(root)
            paths.config.write_text(config_text(), encoding="utf-8")

            def runner(argv, *, env=None, cwd=None):
                return result(argv, "--wait --wait-timeout\n")

            healthy = dict(VALUES, cloudflare_remediation_token="R" * 40)
            with mock.patch.object(secrets, "validate_custody"), mock.patch.object(
                secrets, "decrypt", return_value=healthy
            ):
                checks = runtime.doctor_checks(config_path=paths.config, paths=paths, runner=runner)
            decrypt = next(check for check in checks if check.check_id == "secrets.decrypt")
            self.assertEqual(decrypt.status, "PASS")
            self.assertEqual(decrypt.message, "required appliance secrets decrypt")

            with mock.patch.object(secrets, "validate_custody"), mock.patch.object(
                secrets, "decrypt", return_value=VALUES
            ):
                checks = runtime.doctor_checks(config_path=paths.config, paths=paths, runner=runner)
            decrypt = next(check for check in checks if check.check_id == "secrets.decrypt")
            self.assertEqual(decrypt.status, "FAIL")
            self.assertEqual(decrypt.message, "required cloudflare_remediation_token is missing")

if __name__ == "__main__":
    unittest.main()