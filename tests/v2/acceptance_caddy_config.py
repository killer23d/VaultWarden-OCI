from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

from vaultwarden_oci import runtime

OFFLINE = "age1" + "q" * 58
ROOT = Path(__file__).resolve().parents[2]


def run(argv: list[str], *, env: dict[str, str] | None = None) -> None:
    completed = subprocess.run(argv, check=False, text=True, capture_output=True, env=env)
    if completed.returncode:
        raise SystemExit(
            f"command failed ({completed.returncode}): {' '.join(argv)}\n"
            + completed.stdout + completed.stderr
        )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="vwoci-caddy-validate-") as directory:
        root = Path(directory)
        paths = runtime.Paths(
            config=root / "config.toml",
            data=root / "data",
            caddy_data=root / "caddy/data",
            caddy_config=root / "caddy/config",
            caddy_log=root / "caddy/log",
            run=root / "run",
            transient=root / "run/transient",
            lock=root / "run/lock",
            secret_root=root / "run/secrets",
        )
        paths.transient.mkdir(parents=True)
        config = runtime.RuntimeConfig(
            domain="vault.example.net",
            acme_email="admin@example.net",
            offline_recovery_recipient=OFFLINE,
            signups_allowed=False,
            smtp_host="smtp.example.net",
            smtp_port=587,
            smtp_security="starttls",
            smtp_from_email="vaultwarden@example.net",
            smtp_from_name="Vaultwarden",
            smtp_timeout_seconds=15,
        )
        runtime.render(config, ROOT / "versions.toml", paths, admin_enabled=True)
        image = "vwoci-caddy-config-validation:local"
        run(["docker", "build", "-f", str(paths.dockerfile), "-t", image, str(root)])
        env_args = [
            "-e", "ACME_EMAIL=admin@example.net",
            "-e", "VAULTWARDEN_DOMAIN=vault.example.net",
            "-e", "CLOUDFLARE_API_TOKEN=" + "A" * 40,
            "-e", "ADMIN_BASIC_AUTH_HASH=$2a$14$abcdefghijklmnopqrstuvABCDEFGHIJKLMNOPQRSTUV123456789",
        ]
        run([
            "docker", "run", "--rm", *env_args,
            "-v", f"{paths.caddyfile}:/etc/caddy/Caddyfile:ro",
            "--entrypoint", "caddy", image,
            "validate", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile",
        ])
        modules = subprocess.run(
            ["docker", "run", "--rm", "--entrypoint", "caddy", image, "list-modules"],
            check=True, text=True, capture_output=True,
        ).stdout
        for module in ("dns.providers.cloudflare", "http.ip_sources.cloudflare", "http.handlers.rate_limit"):
            if module not in modules:
                raise SystemExit(f"required Caddy module missing: {module}")
        print("PASS: exact custom Caddy build and representative Caddyfile validated")


if __name__ == "__main__":
    main()
