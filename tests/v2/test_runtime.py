from __future__ import annotations

import json
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import runtime, secrets
from vaultwarden_oci.cli import CommandResult

OFFLINE = "age1" + "q" * 58
OPERATIONAL = "age1" + "p" * 58
VALUES = {
    "cloudflare_api_token": "cf=secret#raw",
    "smtp_username": "mailer@example.net",
    "smtp_password": "smtp=$secret#raw",
    "vaultwarden_admin_token": "admin-secret",
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


class Phase3RuntimeTests(unittest.TestCase):
    def test_config_to_runtime_rendering_validation_and_scope(self) -> None:
        import tomllib
        cfg = runtime.parse_config(tomllib.loads(config_text()))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = runtime.Paths(config=root / "config.toml", data=root / "data", caddy_data=root / "caddy-data", caddy_config=root / "caddy-config", run=root / "run", transient=root / "run/transient", lock=root / "run/lock", secret_root=root / "run/secrets")
            paths.transient.mkdir(parents=True)
            versions = root / "versions.toml"
            versions.write_text('''schema_version = 1
[vaultwarden_oci]
version = "0.1.0-dev"
[components]
vaultwarden = "1.37.1"
caddy = "2.11.4"
caddy_dns_cloudflare = "v0.2.4"
''', encoding="utf-8")
            runtime.render(cfg, versions, paths)
            compose = paths.compose.read_text(encoding="utf-8")
            caddyfile = paths.caddyfile.read_text(encoding="utf-8")
        self.assertIn('vaultwarden/server:1.37.1', compose)
        self.assertIn('CADDY_VERSION: "2.11.4"', compose)
        self.assertIn('cap_drop: [ALL]', compose)
        self.assertIn('cap_add: [NET_BIND_SERVICE]', compose)
        self.assertIn('read_only: true', compose)
        self.assertIn('no-new-privileges:true', compose)
        self.assertIn('ports: ["443:443/tcp"]', compose)
        self.assertIn('dns cloudflare {env.CLOUDFLARE_API_TOKEN}', caddyfile)
        self.assertNotIn('crowdsec', compose.lower())
        self.assertNotIn('postfix', compose.lower())
        self.assertNotIn('rclone', compose.lower())
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
            sp = secrets.SecretPaths(encrypted=root / "secrets.sops.yaml", age_key=root / "age-key.txt", root=root / "run", vaultwarden=root / "run/vaultwarden", caddy=root / "run/caddy")
            sp.age_key.write_text("AGE-SECRET-KEY-TEST\n", encoding="utf-8")
            os.chmod(sp.age_key, 0o600)
            sp.encrypted.write_text(f'''sops:
  age:
    - recipient: {OPERATIONAL}
    - recipient: {OFFLINE}
''', encoding="utf-8")
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
            self.assertEqual(calls[1][0], ("sops", "--decrypt", "--output-type", "json", str(sp.encrypted)))
            self.assertEqual(calls[1][1]["SOPS_AGE_KEY_FILE"], str(sp.age_key))
            argv_text = " ".join(item for call, _ in calls for item in call)
            for value in VALUES.values():
                self.assertNotIn(value, argv_text)
            secrets.materialize(loaded, paths=sp, uid=os.geteuid(), gid=os.getegid(), service_gid=os.getegid())
            for key in secrets.REQUIRED + secrets.OPTIONAL:
                path = sp.file(key)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o440)
            secrets.cleanup(sp)
            self.assertFalse(any(sp.file(key).exists() for key in secrets.REQUIRED + secrets.OPTIONAL))

    def test_failed_sops_and_failed_start_do_not_leave_or_echo_plaintext(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sp = secrets.SecretPaths(encrypted=root / "sops.yaml", age_key=root / "key", root=root / "run", vaultwarden=root / "run/vaultwarden", caddy=root / "run/caddy")
            def bad(argv, *, env=None, cwd=None):
                return result(argv, stderr="provider leaked super-secret", code=1)
            with self.assertRaises(secrets.SecretsError) as caught:
                secrets.decrypt(paths=sp, runner=bad)
            self.assertNotIn("super-secret", str(caught.exception))

    def test_representative_lifecycle_status_behavior(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = runtime.Paths(config=root / "config.toml", data=root / "data", caddy_data=root / "caddy-data", caddy_config=root / "caddy-config", run=root / "run", transient=root / "run/transient", lock=root / "run/lock", secret_root=root / "run/secrets")
            paths.run.mkdir(parents=True)
            paths.config.write_text(config_text(), encoding="utf-8")
            versions = root / "versions.toml"
            versions.write_text('''schema_version = 1
[vaultwarden_oci]
version = "0.1.0-dev"
[components]
vaultwarden = "1.37.1"
caddy = "2.11.4"
caddy_dns_cloudflare = "v0.2.4"
''', encoding="utf-8")
            calls = []
            states = {runtime.NAMES["vaultwarden"]: {"Status": "running", "Health": {"Status": "healthy"}}, runtime.NAMES["caddy"]: {"Status": "running", "Health": {"Status": "healthy"}}}
            def runner(argv, *, env=None, cwd=None):
                call = tuple(argv); calls.append(call)
                if call[:2] == ("docker", "version"): return result(argv, "28.4.0\n")
                if call[:3] == ("docker", "compose", "version"): return result(argv, "2.39.1\n")
                if call[:4] == ("docker", "compose", "up", "--help"): return result(argv, "--wait --wait-timeout\n")
                if call[:3] == ("docker", "compose", "-f"): return result(argv)
                if call[:4] == ("docker", "container", "inspect", "--format"): return result(argv, json.dumps(states[call[-1]]))
                if call[:3] == ("docker", "container", "inspect"): return result(argv)
                if call[:2] == ("docker", "stop"): return result(argv)
                raise AssertionError(argv)
            with mock.patch.object(secrets, "load", return_value=VALUES), mock.patch.object(secrets, "materialize") as materialize:
                runtime.lifecycle("start", paths=paths, versions_path=versions, runner=runner)
                materialize.assert_called_once()
            self.assertTrue(any("config" in call and "--quiet" in call for call in calls))
            self.assertTrue(any("up" in call and "--wait" in call for call in calls))
            overall, rows = runtime.status(runner=runner)
            self.assertEqual(overall, "running")
            self.assertEqual(len(rows), 2)
            with mock.patch.object(secrets, "cleanup") as cleanup:
                runtime.lifecycle("stop", paths=paths, versions_path=versions, runner=runner)
                cleanup.assert_called_once()


if __name__ == "__main__":
    unittest.main()
