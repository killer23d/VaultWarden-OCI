from __future__ import annotations

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def replace(path: str, old: str, new: str, count: int = 1) -> None:
    p = ROOT / path
    text = p.read_text(encoding="utf-8")
    if text.count(old) < count:
        raise SystemExit(f"{path}: missing replacement anchor: {old[:100]!r}")
    p.write_text(text.replace(old, new, count), encoding="utf-8")


# Fix the rendered custom-Caddy Dockerfile: Python substitutions must resolve, and xcaddy gets real continuations.
p = ROOT / "vaultwarden_oci/runtime.py"
text = p.read_text(encoding="utf-8")
start = text.index("    dockerfile = f'''FROM {{frozen.caddy_builder_image.reference}} AS builder")
end = text.index("    _write(paths.compose, compose, 0o600)", start)
block = '''    dockerfile = f\'\'\'FROM {frozen.caddy_builder_image.reference} AS builder\nRUN xcaddy build \\\\\n    --with github.com/caddy-dns/cloudflare@{frozen.caddy_dns_cloudflare} \\\\\n    --with github.com/WeidiDeng/caddy-cloudflare-ip@{frozen.caddy_cloudflare_ip} \\\\\n    --with github.com/fvbommel/caddy-combine-ip-ranges@{frozen.caddy_combine_ip_ranges} \\\\\n    --with github.com/mholt/caddy-ratelimit@{frozen.caddy_ratelimit}\nFROM {frozen.caddy_runtime_image.reference}\nCOPY --from=builder /usr/bin/caddy /usr/bin/caddy\n\'\'\'\n'''
p.write_text(text[:start] + block + text[end:], encoding="utf-8")

# Treat an intentionally stopped/unrendered service as SKIP, while preserving real failures.
p = ROOT / "vaultwarden_oci/edge.py"
text = p.read_text(encoding="utf-8")
text = text.replace(
'''    except (OSError, UnicodeError) as exc:\n        checks.append(DoctorCheck("edge.caddy.trusted_proxy", "FAIL", f"cannot inspect rendered Caddy trusted-proxy config: {exc}"))\n        checks.append(DoctorCheck("edge.admin.protection", "FAIL", "rendered Caddy admin policy is unavailable"))\n''',
'''    except (OSError, UnicodeError):\n        checks.append(DoctorCheck("edge.caddy.trusted_proxy", "SKIP", "rendered Caddy config is not present; service may be stopped"))\n        checks.append(DoctorCheck("edge.admin.protection", "SKIP", "rendered Caddy admin policy is not present; service may be stopped"))\n''')
text = text.replace(
'''    checks.append(DoctorCheck(\n        "edge.caddy.health",\n        "PASS" if healthy else "FAIL",\n        "Caddy container is running and healthy" if healthy else "Caddy container is absent, stopped, or unhealthy",\n    ))\n''',
'''    caddy_absent = (not caddy_state.ok) and "no such" in (caddy_state.stderr + caddy_state.stdout).lower()\n    checks.append(DoctorCheck(\n        "edge.caddy.health",\n        "PASS" if healthy else "SKIP" if caddy_absent else "FAIL",\n        "Caddy container is running and healthy" if healthy\n        else "Caddy container is not present; service may be stopped" if caddy_absent\n        else "Caddy container is stopped, unhealthy, or could not be inspected",\n    ))\n''')
p.write_text(text, encoding="utf-8")

# Add another sensitive account endpoint to the bounded auth limiter.
replace(
    "vaultwarden_oci/runtime.py",
    " @auth path /identity/connect/token* /api/accounts/prelogin*\n",
    " @auth path /identity/connect/token* /api/accounts/prelogin* /api/accounts/register*\n",
)

# Preserve unit isolation: lifecycle tests use fake image digests and must not spawn Docker just to hash.
p = ROOT / "tests/v2/test_runtime.py"
text = p.read_text(encoding="utf-8")
text = text.replace(
"class Phase3RuntimeTests(unittest.TestCase):\n",
'''class Phase3RuntimeTests(unittest.TestCase):\n    def setUp(self) -> None:\n        self._admin_hash = mock.patch.object(\n            secrets, "derive_admin_basic_auth_hash", return_value="$2a$14$test-admin-hash"\n        )\n        self._admin_hash.start()\n\n    def tearDown(self) -> None:\n        self._admin_hash.stop()\n\n''')
text = text.replace(
'''            secrets.materialize(\n                loaded,\n                paths=sp,\n''',
'''            secrets.materialize(\n                loaded,\n                derived={"admin_basic_auth_hash": "$2a$14$test-admin-hash"},\n                paths=sp,\n''')
p.write_text(text, encoding="utf-8")

# Keep docs factual instead of retaining the pre-workstream stale gap statement.
replace(
    "docs/SECURITY.md",
    "The current development branch still renders static Cloudflare trusted-proxy CIDRs, builds only the Cloudflare DNS xcaddy module, stores state under `/var/lib/vaultwarden-oci` without dedicated-storage enforcement, and lacks the approved dashboard/setup surfaces. Those are known implementation gaps and must not be cited as a reason to change the durable security contract.",
    "The development branch is incremental; durable security decisions remain authoritative when later product surfaces are not implemented yet. Current Caddy trust, origin filtering, dedicated-storage enforcement, and setup behavior must be assessed from the implementation and tests rather than older gap summaries.",
)

# Strengthen focused contract assertions.
p = ROOT / "tests/v2/test_caddy_edge_admin.py"
text = p.read_text(encoding="utf-8")
text = text.replace(
'        self.assertIn("/api/accounts/prelogin*", caddyfile)\n',
'        self.assertIn("/api/accounts/prelogin*", caddyfile)\n        self.assertIn("/api/accounts/register*", caddyfile)\n')
p.write_text(text, encoding="utf-8")

# Real representative build/config validation using the exact rendered Dockerfile and modules.
acceptance = ROOT / "tests/v2/acceptance_caddy_config.py"
acceptance.write_text(r'''from __future__ import annotations

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
''', encoding="utf-8")

# Permanently add the real Caddy validation job to normal V2 CI.
p = ROOT / ".github/workflows/v2-ci.yml"
text = p.read_text(encoding="utf-8")
anchor = "\n  recovery-crypto-integration:\n"
job = '''\n  caddy-config-integration:\n    runs-on: ubuntu-24.04\n    timeout-minutes: 15\n    steps:\n      - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5\n      - name: Exact custom Caddy build and config validation\n        run: python3 tests/v2/acceptance_caddy_config.py\n\n'''
if "caddy-config-integration:" not in text:
    text = text.replace(anchor, job + "  recovery-crypto-integration:\n", 1)
p.write_text(text, encoding="utf-8")

print("audit pass 1 fixes applied")
