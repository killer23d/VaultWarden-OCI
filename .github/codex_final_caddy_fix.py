from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace(path: str, old: str, new: str) -> None:
    target = ROOT / path
    text = target.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"{path}: replacement anchor not found")
    target.write_text(text.replace(old, new, 1), encoding="utf-8")


replace(
    "vaultwarden_oci/runtime.py",
    "  trusted_proxies cloudflare\n  trusted_proxies_strict\n",
    "  trusted_proxies cloudflare {\n   timeout 15s\n  }\n  trusted_proxies_strict\n",
)

replace(
    "tests/v2/test_caddy_edge_admin.py",
    '        self.assertIn("trusted_proxies cloudflare", caddyfile)\n        self.assertIn("client_ip_headers CF-Connecting-IP", caddyfile)\n',
    '        self.assertIn("trusted_proxies cloudflare {", caddyfile)\n        self.assertIn("timeout 15s", caddyfile)\n        self.assertIn("client_ip_headers CF-Connecting-IP", caddyfile)\n',
)

acceptance = '''from __future__ import annotations

import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from vaultwarden_oci import runtime

OFFLINE = "age1" + "q" * 58


def run(argv: list[str]) -> None:
    completed = subprocess.run(argv, check=False, text=True, capture_output=True)
    if completed.returncode:
        raise SystemExit(
            f"command failed ({completed.returncode}): {' '.join(argv)}\\n"
            + completed.stdout + completed.stderr
        )


def output(argv: list[str]) -> str:
    completed = subprocess.run(argv, check=False, text=True, capture_output=True)
    if completed.returncode:
        raise SystemExit(
            f"command failed ({completed.returncode}): {' '.join(argv)}\\n"
            + completed.stdout + completed.stderr
        )
    return completed.stdout


def wait_for_port(host: str, port: int) -> None:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=0.5):
                return
        except OSError:
            time.sleep(0.1)
    raise SystemExit(f"Caddy rate-limit smoke listener did not become ready on {host}:{port}")


def http_status(url: str) -> int:
    try:
        response = urllib.request.urlopen(url, timeout=5)
    except urllib.error.HTTPError as exc:
        try:
            return exc.code
        finally:
            exc.close()
    with response:
        return response.status


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
        modules = output(
            ["docker", "run", "--rm", "--entrypoint", "caddy", image, "list-modules"]
        )
        for module in (
            "dns.providers.cloudflare",
            "http.ip_sources.cloudflare",
            "http.ip_sources.combine",
            "http.handlers.rate_limit",
        ):
            if module not in modules:
                raise SystemExit(f"required Caddy module missing: {module}")

        smoke = root / "RateLimit.Caddyfile"
        smoke.write_text(
            ''' + '"""' + '''{
 auto_https off
 admin off
}
:8080 {
 route {
  rate_limit {
   zone smoke {
    key {client_ip}
    events 2
    window 10m
   }
  }
  respond "ok"
 }
}
''' + '"""' + ''',
            encoding="utf-8",
        )
        name = f"vwoci-caddy-rate-limit-{os.getpid()}"
        try:
            run([
                "docker", "run", "-d", "--name", name,
                "-p", "127.0.0.1::8080",
                "-v", f"{smoke}:/etc/caddy/Caddyfile:ro",
                "--entrypoint", "caddy", image,
                "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile",
            ])
            mapping = output(["docker", "port", name, "8080/tcp"]).strip()
            if not mapping.startswith("127.0.0.1:"):
                raise SystemExit(f"unexpected Caddy smoke port mapping: {mapping!r}")
            port = int(mapping.rsplit(":", 1)[1])
            wait_for_port("127.0.0.1", port)
            statuses = [http_status(f"http://127.0.0.1:{port}/") for _ in range(3)]
            if statuses != [200, 200, 429]:
                logs = output(["docker", "logs", name])
                raise SystemExit(
                    f"rate-limit smoke expected [200, 200, 429], got {statuses}\\n{logs}"
                )
        finally:
            subprocess.run(
                ["docker", "rm", "-f", name],
                check=False,
                text=True,
                capture_output=True,
            )

        print(
            "PASS: exact custom Caddy build, representative Caddyfile, module set, "
            "and rate-limit threshold validated"
        )


if __name__ == "__main__":
    main()
'''
(ROOT / "tests/v2/acceptance_caddy_config.py").write_text(acceptance, encoding="utf-8")

print("final Caddy audit fixes applied")
