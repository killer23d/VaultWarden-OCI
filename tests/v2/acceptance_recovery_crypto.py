#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import tempfile
from pathlib import Path

from vaultwarden_oci import recovery, secrets
from vaultwarden_oci.cli import CommandResult, run_command

VALUES = {
    "cloudflare_api_token": "A" * 40,
    "smtp_username": "mailer@example.net",
    "smtp_password": "smtp-secret",
    "vaultwarden_admin_token": "admin-secret",
    "cloudflare_remediation_token": "B" * 40,
}


def ok(argv, stdout="", stderr="", code=0):
    return CommandResult(tuple(argv), "success" if code == 0 else "nonzero", code, stdout, stderr)


class AcceptanceRunner:
    def __call__(self, argv, *, env=None, cwd=None):
        call = tuple(argv)
        if call[:2] == ("docker", "version"):
            return ok(argv, "28.0\n")
        if call[:3] == ("docker", "container", "inspect"):
            return ok(argv, stderr="Error: No such object", code=1)
        return run_command(argv, env=env, cwd=cwd)


def recipient(identity: Path) -> str:
    return subprocess.check_output(["age-keygen", "-y", str(identity)], text=True).strip()


def config_text(offline: str) -> str:
    return f'''schema_version = 1
[site]
domain = "vault.example.net"
acme_email = "admin@example.net"
[secrets]
offline_recovery_recipient = "{offline}"
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


def create_sops_document(plain: Path, encrypted: Path, operational: str, offline: str) -> None:
    plain.write_text(json.dumps(VALUES), encoding="utf-8")
    os.chmod(plain, 0o600)
    try:
        subprocess.run(
            [
                "sops",
                "--encrypt",
                "--age",
                f"{operational},{offline}",
                "--input-type",
                "json",
                "--output-type",
                "yaml",
                "--output",
                str(encrypted),
                str(plain),
            ],
            check=True,
            text=True,
            capture_output=True,
        )
    finally:
        plain.unlink(missing_ok=True)
    os.chmod(encrypted, 0o600)


def decrypt_with(identity: Path, encrypted: Path) -> dict[str, object]:
    env = os.environ.copy()
    env["SOPS_AGE_KEY_FILE"] = str(identity)
    completed = subprocess.run(
        ["sops", "--decrypt", "--output-type", "json", str(encrypted)],
        check=True,
        text=True,
        capture_output=True,
        env=env,
    )
    return json.loads(completed.stdout)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="vwrec-crypto-acceptance-") as directory:
        root = Path(directory)
        host = root / "host"
        offline_dir = root / "offline"
        offline_dir.mkdir()
        host.mkdir()

        offline_key = offline_dir / "recovery.age"
        operational_key = host / "etc/age-key.txt"
        operational_key.parent.mkdir(parents=True)
        subprocess.run(["age-keygen", "-o", str(offline_key)], check=True, capture_output=True, text=True)
        subprocess.run(["age-keygen", "-o", str(operational_key)], check=True, capture_output=True, text=True)
        os.chmod(offline_key, 0o600)
        os.chmod(operational_key, 0o600)
        offline_recipient = recipient(offline_key)
        old_operational_recipient = recipient(operational_key)
        if offline_recipient == old_operational_recipient:
            raise AssertionError("offline and operational recipients unexpectedly match")

        paths = recovery.RecoveryPaths(
            backups=host / "backups",
            state_file=host / "state/recovery.json",
            config=host / "etc/config.toml",
            encrypted_secrets=host / "etc/secrets.sops.yaml",
            operational_age_key=operational_key,
            data=host / "data",
            caddy_data=host / "caddy/data",
            caddy_config=host / "caddy/config",
            lock=host / "run/lock",
        )
        paths.config.write_text(config_text(offline_recipient), encoding="utf-8")
        os.chmod(paths.config, 0o600)
        create_sops_document(
            root / "plain-secrets.json",
            paths.encrypted_secrets,
            old_operational_recipient,
            offline_recipient,
        )
        paths.data.mkdir(parents=True)
        database = sqlite3.connect(paths.data / "db.sqlite3")
        database.execute("create table proof (value text)")
        database.execute("insert into proof values ('recoverable')")
        database.commit()
        database.close()
        (paths.data / "attachments").mkdir()
        (paths.data / "attachments/proof.txt").write_text("attachment", encoding="utf-8")
        paths.caddy_data.mkdir(parents=True)
        paths.caddy_config.mkdir(parents=True)
        (paths.caddy_data / "proof").write_text("caddy-data", encoding="utf-8")
        (paths.caddy_config / "proof").write_text("caddy-config", encoding="utf-8")
        paths.backups.mkdir(parents=True)
        paths.lock.parent.mkdir(parents=True)

        runner = AcceptanceRunner()
        verified = recovery.create_recovery(
            offline_recipient,
            paths=paths,
            runner=runner,
        )
        if not verified.artifact.is_file():
            raise AssertionError("verified recovery artifact missing")

        # Replacement-host condition: installer has created the path, but the old
        # server-local operational identity is unavailable.
        operational_key.write_text("", encoding="utf-8")
        os.chmod(operational_key, 0o600)
        recovery.restore_recovery(
            verified.artifact,
            offline_key,
            paths=paths,
            runner=runner,
        )

        new_operational_recipient = recipient(operational_key)
        if new_operational_recipient in {offline_recipient, old_operational_recipient}:
            raise AssertionError("restore did not establish a distinct replacement operational identity")
        recorded = secrets.encrypted_recipients(paths.encrypted_secrets)
        if recorded != {offline_recipient, new_operational_recipient}:
            raise AssertionError(f"unexpected restored SOPS recipients: {recorded}")
        if decrypt_with(offline_key, paths.encrypted_secrets) != VALUES:
            raise AssertionError("offline identity cannot decrypt restored SOPS document")
        if decrypt_with(operational_key, paths.encrypted_secrets) != VALUES:
            raise AssertionError("replacement operational identity cannot decrypt restored SOPS document")

        database = sqlite3.connect(paths.data / "db.sqlite3")
        row = database.execute("select value from proof").fetchone()
        database.close()
        if row != ("recoverable",):
            raise AssertionError(f"restored SQLite proof mismatch: {row}")

        offline_private = offline_key.read_bytes()
        for candidate in host.rglob("*"):
            if candidate.is_file() and candidate != verified.artifact:
                if offline_private in candidate.read_bytes():
                    raise AssertionError(f"offline private recovery material persisted on host: {candidate}")

    print("PASS: real Age/SOPS fresh-host recovery and rekey acceptance")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())