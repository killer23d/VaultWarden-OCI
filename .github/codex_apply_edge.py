from __future__ import annotations

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def edit(path: str, old: str, new: str, *, count: int = 1) -> None:
    target = ROOT / path
    text = target.read_text(encoding="utf-8")
    found = text.count(old)
    if found < count:
        raise SystemExit(f"{path}: expected at least {count} occurrences, found {found}: {old[:80]!r}")
    target.write_text(text.replace(old, new, count), encoding="utf-8")


def regex_edit(path: str, pattern: str, replacement: str, *, count: int = 1) -> None:
    target = ROOT / path
    text = target.read_text(encoding="utf-8")
    changed, n = re.subn(pattern, replacement, text, count=count, flags=re.S)
    if n != count:
        raise SystemExit(f"{path}: expected {count} regex replacement(s), got {n}: {pattern[:100]!r}")
    target.write_text(changed, encoding="utf-8")


PINS = '''caddy_dns_cloudflare = "v0.2.4"\ncaddy_cloudflare_ip = "f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5"\ncaddy_combine_ip_ranges = "v0.0.1"\ncaddy_ratelimit = "v0.1.0"'''
edit("versions.toml", 'caddy_dns_cloudflare = "v0.2.4"', PINS)

# Keep test manifests coherent with the single production component schema.
for target in (ROOT / "tests/v2").glob("*.py"):
    text = target.read_text(encoding="utf-8")
    needle = 'caddy_dns_cloudflare = "v0.2.4"'
    if needle in text and 'caddy_cloudflare_ip = "f53b62' not in text:
        target.write_text(text.replace(needle, PINS), encoding="utf-8")

# versions manifest authority
edit(
    "vaultwarden_oci/cli.py",
    '    caddy_dns_cloudflare: str = ""\n',
    '    caddy_dns_cloudflare: str = ""\n    caddy_cloudflare_ip: str = ""\n    caddy_combine_ip_ranges: str = ""\n    caddy_ratelimit: str = ""\n',
)
edit(
    "vaultwarden_oci/cli.py",
    '    unknown = sorted(set(components) - {"vaultwarden", "caddy", "caddy_dns_cloudflare"})',
    '    unknown = sorted(set(components) - {"vaultwarden", "caddy", "caddy_dns_cloudflare", "caddy_cloudflare_ip", "caddy_combine_ip_ranges", "caddy_ratelimit"})',
)
edit(
    "vaultwarden_oci/cli.py",
    '        component("caddy_dns_cloudflare"),\n    )',
    '        component("caddy_dns_cloudflare"),\n        component("caddy_cloudflare_ip"),\n        component("caddy_combine_ip_ranges"),\n        component("caddy_ratelimit"),\n    )',
)
edit(
    "vaultwarden_oci/cli.py",
    '    "edge.cloudflare.cidrs",\n    "edge.cloudflare.iptables",',
    '    "edge.caddy.trusted_proxy",\n    "edge.caddy.health",\n    "edge.admin.protection",\n    "edge.cloudflare.cidrs",\n    "edge.cloudflare.iptables",',
)
edit(
    "vaultwarden_oci/cli.py",
    '        f"caddy {v.caddy}; caddy-dns/cloudflare {v.caddy_dns_cloudflare}"\n',
    '        f"caddy {v.caddy}; caddy-dns/cloudflare {v.caddy_dns_cloudflare}; "\n        f"trusted-proxy {v.caddy_cloudflare_ip}; combine-ip-ranges {v.caddy_combine_ip_ranges}; "\n        f"rate-limit {v.caddy_ratelimit}"\n',
)
edit(
    "vaultwarden_oci/cli.py",
    '        notification_row = notification.status_row()\n',
    '        notification_row = notification.status_row()\n        from . import edge\n        edge_checks = edge.doctor_checks()\n        for check in edge_checks:\n            print(f"{check.check_id}: {check.status} ({check.message})")\n',
)
edit(
    "vaultwarden_oci/cli.py",
    '        if notification_row["state"] == "failure" and overall in {"running", "stopped"}:\n            overall = "degraded"\n',
    '        if notification_row["state"] == "failure" and overall in {"running", "stopped"}:\n            overall = "degraded"\n        if any(check.status == "FAIL" for check in edge_checks) and overall in {"running", "stopped"}:\n            overall = "degraded"\n',
)

# Frozen version propagation.
edit(
    "vaultwarden_oci/update_versions.py",
    '    caddy_dns_cloudflare: str\n    vaultwarden_image: ImagePin\n',
    '    caddy_dns_cloudflare: str\n    caddy_cloudflare_ip: str\n    caddy_combine_ip_ranges: str\n    caddy_ratelimit: str\n    vaultwarden_image: ImagePin\n',
)
edit(
    "vaultwarden_oci/update_versions.py",
    '        plugin = self.caddy_dns_cloudflare.removeprefix("v")\n        return f"vaultwarden-oci/caddy:{self.caddy}-cloudflare-{plugin}"\n',
    '        return f"vaultwarden-oci/caddy:{self.caddy}-edge"\n',
)
edit(
    "vaultwarden_oci/update_versions.py",
    '                "caddy_dns_cloudflare": self.caddy_dns_cloudflare,\n',
    '                "caddy_dns_cloudflare": self.caddy_dns_cloudflare,\n                "caddy_cloudflare_ip": self.caddy_cloudflare_ip,\n                "caddy_combine_ip_ranges": self.caddy_combine_ip_ranges,\n                "caddy_ratelimit": self.caddy_ratelimit,\n',
)
edit(
    "vaultwarden_oci/update_versions.py",
    '    plugin: str,\n    digests: Mapping[str, str],\n',
    '    plugin: str,\n    trusted_proxy: str,\n    combine_ranges: str,\n    rate_limit: str,\n    digests: Mapping[str, str],\n',
)
edit(
    "vaultwarden_oci/update_versions.py",
    '        plugin,\n        ImagePin("vaultwarden",',
    '        plugin,\n        trusted_proxy,\n        combine_ranges,\n        rate_limit,\n        ImagePin("vaultwarden",',
)
edit(
    "vaultwarden_oci/update_versions.py",
    '        manifest.caddy_dns_cloudflare,\n        _image_digests(',
    '        manifest.caddy_dns_cloudflare,\n        manifest.caddy_cloudflare_ip,\n        manifest.caddy_combine_ip_ranges,\n        manifest.caddy_ratelimit,\n        _image_digests(',
)
edit(
    "vaultwarden_oci/update_versions.py",
    '    return _freeze("latest", arch, project, vaultwarden, caddy, plugin, digests)\n',
    '    return _freeze(\n        "latest", arch, project, vaultwarden, caddy, plugin,\n        base.caddy_cloudflare_ip, base.caddy_combine_ip_ranges, base.caddy_ratelimit, digests\n    )\n',
)
edit(
    "vaultwarden_oci/update_versions.py",
    '        f\'caddy_dns_cloudflare = "{frozen.caddy_dns_cloudflare}"\',\n',
    '        f\'caddy_dns_cloudflare = "{frozen.caddy_dns_cloudflare}"\',\n        f\'caddy_cloudflare_ip = "{frozen.caddy_cloudflare_ip}"\',\n        f\'caddy_combine_ip_ranges = "{frozen.caddy_combine_ip_ranges}"\',\n        f\'caddy_ratelimit = "{frozen.caddy_ratelimit}"\',\n',
)

# Secret source password remains SOPS/in-memory; only the derived hash reaches Caddy.
edit("vaultwarden_oci/secrets.py", 'import stat\n', 'import stat\nimport subprocess\n')
edit(
    "vaultwarden_oci/secrets.py",
    'TRANSIENT_ONLY = ("cloudflare_remediation_token", "email_api_token")\n',
    'TRANSIENT_ONLY = ("cloudflare_remediation_token", "email_api_token", "admin_basic_auth_password")\nDERIVED = ("admin_basic_auth_hash",)\n',
)
edit(
    "vaultwarden_oci/secrets.py",
    '        return (self.caddy if key == "cloudflare_api_token" else self.vaultwarden) / key\n',
    '        return (self.caddy if key in {"cloudflare_api_token", "admin_basic_auth_hash"} else self.vaultwarden) / key\n',
)
insert_after = '''def validate_cloudflare_token(value: str) -> str:\n    """Reject values that the pinned Caddy Cloudflare module would echo on error."""\n    if not (_CLOUDFLARE_NEW_TOKEN.fullmatch(value) or _CLOUDFLARE_LEGACY_TOKEN.fullmatch(value)):\n        raise SecretsError(\n            "decrypted Cloudflare token does not match the supported Cloudflare provider token format"\n        )\n    return value\n'''
addition = insert_after + '''\n\ndef admin_enabled(values: Mapping[str, str]) -> bool:\n    token = bool(values.get("vaultwarden_admin_token"))\n    password = bool(values.get("admin_basic_auth_password"))\n    if token != password:\n        raise SecretsError(\n            "Vaultwarden admin protection requires both vaultwarden_admin_token and admin_basic_auth_password in SOPS"\n        )\n    return token\n\n\ndef derive_admin_basic_auth_hash(password: str, caddy_image: str) -> str:\n    """Hash via exact-pinned Caddy; plaintext crosses stdin only, never argv/env/files."""\n    try:\n        completed = subprocess.run(\n            ["docker", "run", "--rm", "-i", "--entrypoint", "caddy", caddy_image, "hash-password", "--algorithm", "bcrypt"],\n            input=password + "\\n",\n            text=True,\n            capture_output=True,\n            check=False,\n        )\n    except OSError as exc:\n        raise SecretsError("cannot derive Caddy Basic Auth hash") from exc\n    if completed.returncode != 0:\n        raise SecretsError("Caddy Basic Auth hash derivation failed")\n    value = completed.stdout.strip()\n    if not value.startswith("$2") or any(char in value for char in "\\0\\r\\n"):\n        raise SecretsError("Caddy Basic Auth hash derivation returned an invalid hash")\n    return value\n'''
edit("vaultwarden_oci/secrets.py", insert_after, addition)
edit(
    "vaultwarden_oci/secrets.py",
    'def materialize(\n    values: Mapping[str, str],\n    *,\n    paths: SecretPaths = SecretPaths(),\n',
    'def materialize(\n    values: Mapping[str, str],\n    *,\n    derived: Mapping[str, str] | None = None,\n    paths: SecretPaths = SecretPaths(),\n',
)
edit(
    "vaultwarden_oci/secrets.py",
    '    missing = sorted(set(REQUIRED) - set(values))\n',
    '    enabled = admin_enabled(values)\n    derived_values = dict(derived or {})\n    if enabled and not derived_values.get("admin_basic_auth_hash"):\n        raise SecretsError("admin protection requires a derived Caddy Basic Auth hash")\n    if not enabled and derived_values.get("admin_basic_auth_hash"):\n        raise SecretsError("refusing an outer admin hash while Vaultwarden admin is disabled")\n    unknown_derived = sorted(set(derived_values) - set(DERIVED))\n    if unknown_derived:\n        raise SecretsError("unknown derived secret key(s): " + ", ".join(unknown_derived))\n    missing = sorted(set(REQUIRED) - set(values))\n',
)
edit(
    "vaultwarden_oci/secrets.py",
    '        for key in REQUIRED + OPTIONAL:\n            path = paths.file(key)\n',
    '        for key in REQUIRED + OPTIONAL:\n            path = paths.file(key)\n',
)
edit(
    "vaultwarden_oci/secrets.py",
    '            _write(path, _value(key, values[key]), uid, secret_gid)\n            written.append(path)\n    except Exception:\n',
    '            _write(path, _value(key, values[key]), uid, secret_gid)\n            written.append(path)\n        for key in DERIVED:\n            path = paths.file(key)\n            if key not in derived_values:\n                path.unlink(missing_ok=True)\n                continue\n            _write(path, _value(key, derived_values[key]), uid, caddy_gid)\n            written.append(path)\n    except Exception:\n',
)
edit(
    "vaultwarden_oci/secrets.py",
    '    for key in REQUIRED + OPTIONAL:\n',
    '    for key in REQUIRED + OPTIONAL + DERIVED:\n',
    count=1,
)

# Setup creates a distinct outer-gate source password in the encrypted document.
edit(
    "vaultwarden_oci/setup.py",
    '    admin_token = pysecrets.token_urlsafe(48)\n    plaintext = json.dumps({"vaultwarden_admin_token": admin_token}) + "\\n"\n',
    '    admin_token = pysecrets.token_urlsafe(48)\n    admin_basic_auth_password = pysecrets.token_urlsafe(32)\n    plaintext = json.dumps({\n        "vaultwarden_admin_token": admin_token,\n        "admin_basic_auth_password": admin_basic_auth_password,\n    }) + "\\n"\n',
)

# edge.py: delete duplicate Caddy static-CIDR renderer; add separated diagnostics.
regex_edit(
    "vaultwarden_oci/edge.py",
    r'\n\ndef caddy_trusted_proxy_block\(policy: CloudflarePolicy\) -> str:\n.*?\n\ndef _write_root_file',
    '\n\ndef _write_root_file',
)
edit(
    "vaultwarden_oci/edge.py",
    'FAIL_OPEN_CONFIRMATION = STATE_ROOT / "crowdsec-cloudflare-fail-open.json"\n',
    'FAIL_OPEN_CONFIRMATION = STATE_ROOT / "crowdsec-cloudflare-fail-open.json"\nCADDYFILE = Path("/run/vaultwarden-oci/transient/Caddyfile")\nCADDY_CONTAINER = "vaultwarden-oci-caddy"\nADMIN_TOKEN_FILE = Path("/run/vaultwarden-oci/secrets/vaultwarden/vaultwarden_admin_token")\nADMIN_HASH_FILE = Path("/run/vaultwarden-oci/secrets/caddy/admin_basic_auth_hash")\n',
)
marker = 'def doctor_checks(\n    *,\n    paths: EdgePaths = EdgePaths(),\n    runner: Runner = run_command,\n    now: int | None = None,\n) -> list[DoctorCheck]:\n    checks: list[DoctorCheck] = []\n'
replacement = marker + '''    try:\n        caddy_text = CADDYFILE.read_text(encoding="utf-8")\n    except (OSError, UnicodeError) as exc:\n        checks.append(DoctorCheck("edge.caddy.trusted_proxy", "FAIL", f"cannot inspect rendered Caddy trusted-proxy config: {exc}"))\n        checks.append(DoctorCheck("edge.admin.protection", "FAIL", "rendered Caddy admin policy is unavailable"))\n    else:\n        trusted = (\n            "trusted_proxies cloudflare" in caddy_text\n            and "client_ip_headers CF-Connecting-IP" in caddy_text\n            and "trusted_proxies static" not in caddy_text\n        )\n        checks.append(DoctorCheck(\n            "edge.caddy.trusted_proxy",\n            "PASS" if trusted else "FAIL",\n            "Caddy uses the Cloudflare trusted-proxy module and CF-Connecting-IP" if trusted\n            else "Caddy trusted-proxy module/CF-Connecting-IP configuration is missing or duplicated with static CIDRs",\n        ))\n        admin_disabled = "respond @admin 404" in caddy_text\n        admin_gated = "basic_auth" in caddy_text and "rate_limit" in caddy_text\n        if admin_disabled:\n            checks.append(DoctorCheck("edge.admin.protection", "PASS", "Vaultwarden admin route is disabled at Caddy"))\n        elif admin_gated and ADMIN_TOKEN_FILE.exists() and ADMIN_HASH_FILE.exists():\n            checks.append(DoctorCheck("edge.admin.protection", "PASS", "admin token capability, per-client rate limit, and outer Basic Auth gate are active"))\n        else:\n            checks.append(DoctorCheck("edge.admin.protection", "FAIL", "admin route is missing Vaultwarden token capability, rate limit, or outer Basic Auth gate"))\n\n    caddy_state = runner(["docker", "container", "inspect", "--format", "{{json .State}}", CADDY_CONTAINER])\n    healthy = False\n    if caddy_state.ok:\n        try:\n            state = json.loads(caddy_state.stdout)\n            healthy = isinstance(state, dict) and state.get("Status") == "running" and (\n                not isinstance(state.get("Health"), dict) or state["Health"].get("Status") == "healthy"\n            )\n        except (json.JSONDecodeError, TypeError, AttributeError):\n            healthy = False\n    checks.append(DoctorCheck(\n        "edge.caddy.health",\n        "PASS" if healthy else "FAIL",\n        "Caddy container is running and healthy" if healthy else "Caddy container is absent, stopped, or unhealthy",\n    ))\n'''
edit("vaultwarden_oci/edge.py", marker, replacement)

# runtime render/build: Caddy owns proxy trust; host CIDR policy remains a separate pre-start gate.
edit(
    "vaultwarden_oci/runtime.py",
    '    *,\n    cloudflare_policy: edge.CloudflarePolicy | None = None,\n) -> None:\n',
    '    *,\n    admin_enabled: bool = False,\n) -> None:\n',
)
edit(
    "vaultwarden_oci/runtime.py",
    '    caddy_command = (\n        \'export CLOUDFLARE_API_TOKEN="$(cat /run/caddy-secrets/cloudflare_api_token)"; \'\n        \'exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile\'\n    )\n',
    '    caddy_command = (\n        \'export CLOUDFLARE_API_TOKEN="$(cat /run/caddy-secrets/cloudflare_api_token)"; \'\n        \'if [ -s /run/caddy-secrets/admin_basic_auth_hash ]; then \'\n        \'export ADMIN_BASIC_AUTH_HASH="$(cat /run/caddy-secrets/admin_basic_auth_hash)"; fi; \'\n        \'exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile\'\n    )\n',
)
regex_edit(
    "vaultwarden_oci/runtime.py",
    r'    proxy_block = edge\.caddy_trusted_proxy_block\(cloudflare_policy\) if cloudflare_policy else ""\n    caddyfile = f\'\'\'.*?    dockerfile = f\'\'\'FROM \{frozen\.caddy_builder_image\.reference\} AS builder\nRUN xcaddy build --with github\.com/caddy-dns/cloudflare@\{frozen\.caddy_dns_cloudflare\}\nFROM \{frozen\.caddy_runtime_image\.reference\}\nCOPY --from=builder /usr/bin/caddy /usr/bin/caddy\n\'\'\'\n',
    '''    admin_route = f\'\'\' @admin path /admin*\n handle @admin {{\n  rate_limit {{\n   zone admin {{\n    key {{client_ip}}\n    events 5\n    window 5m\n   }}\n  }}\n  request_body {{\n   max_size 2MB\n  }}\n  basic_auth {{\n   admin {{env.ADMIN_BASIC_AUTH_HASH}}\n  }}\n  reverse_proxy vaultwarden:8080\n }}\n\'\'\' if admin_enabled else \'\'\' @admin path /admin*\n respond @admin 404\n\'\'\'\n    caddyfile = f\'\'\'{{\n email {{$ACME_EMAIL}}\n admin 127.0.0.1:2019\n persist_config off\n order rate_limit before basic_auth\n servers {{\n  trusted_proxies cloudflare\n  trusted_proxies_strict\n  client_ip_headers CF-Connecting-IP\n }}\n}}\n{{$VAULTWARDEN_DOMAIN}} {{\n tls {{\n  dns cloudflare {{env.CLOUDFLARE_API_TOKEN}}\n  resolvers 1.1.1.1 1.0.0.1\n }}\n log {{\n  output file /var/log/caddy/access.log {{\n   mode 0600\n   roll_size 10MiB\n   roll_keep 5\n   roll_keep_for 168h\n  }}\n  format json\n }}\n header {{\n  Strict-Transport-Security "max-age=31536000; includeSubDomains"\n  X-Content-Type-Options "nosniff"\n  Referrer-Policy "same-origin"\n  -Server\n }}\n encode zstd gzip\n{{admin_route}} @auth path /identity/connect/token* /api/accounts/prelogin*\n handle @auth {{\n  rate_limit {{\n   zone auth {{\n    key {{client_ip}}\n    events 10\n    window 1m\n   }}\n  }}\n  request_body {{\n   max_size 512KB\n  }}\n  reverse_proxy vaultwarden:8080\n }}\n handle {{\n  reverse_proxy vaultwarden:8080\n }}\n}}\n\'\'\'\n    dockerfile = f\'\'\'FROM {{frozen.caddy_builder_image.reference}} AS builder\nRUN xcaddy build \\\\n    --with github.com/caddy-dns/cloudflare@{{frozen.caddy_dns_cloudflare}} \\\\n    --with github.com/WeidiDeng/caddy-cloudflare-ip@{{frozen.caddy_cloudflare_ip}} \\\\n    --with github.com/fvbommel/caddy-combine-ip-ranges@{{frozen.caddy_combine_ip_ranges}} \\\\n    --with github.com/mholt/caddy-ratelimit@{{frozen.caddy_ratelimit}}\nFROM {{frozen.caddy_runtime_image.reference}}\nCOPY --from=builder /usr/bin/caddy /usr/bin/caddy\n\'\'\'\n''',
)
old_flow = '''        config = load_config(paths.config)\n        cloudflare_policy = None\n        if default_paths:\n            try:\n                cloudflare_policy = edge.refresh_origin_policy(runner=runner)\n            except edge.EdgeError as exc:\n                raise RuntimeErrorV2(str(exc)) from exc\n        render(config, versions_path, paths, cloudflare_policy=cloudflare_policy)\n        if not _compose(["config", "--quiet"], paths, runner).ok:\n            raise RuntimeErrorV2("rendered Compose validation failed")\n        values = secrets.load(\n            config.offline_recovery_recipient,\n            paths=paths.secret_paths(),\n            runner=runner,\n            uid=uid,\n        )\n        secrets.materialize(\n            values,\n            paths=paths.secret_paths(),\n            uid=uid,\n            gid=gid,\n            vaultwarden_gid=vaultwarden_gid,\n            caddy_gid=caddy_gid,\n        )\n'''
new_flow = '''        config = load_config(paths.config)\n        if default_paths:\n            try:\n                edge.refresh_origin_policy(runner=runner)\n            except edge.EdgeError as exc:\n                raise RuntimeErrorV2(str(exc)) from exc\n        values = secrets.load(\n            config.offline_recovery_recipient,\n            paths=paths.secret_paths(),\n            runner=runner,\n            uid=uid,\n        )\n        admin_enabled = secrets.admin_enabled(values)\n        derived: dict[str, str] = {}\n        if admin_enabled:\n            frozen = _pins(versions_path)\n            derived["admin_basic_auth_hash"] = secrets.derive_admin_basic_auth_hash(\n                values["admin_basic_auth_password"], frozen.caddy_runtime_image.reference\n            )\n        render(config, versions_path, paths, admin_enabled=admin_enabled)\n        if not _compose(["config", "--quiet"], paths, runner).ok:\n            raise RuntimeErrorV2("rendered Compose validation failed")\n        secrets.materialize(\n            values,\n            derived=derived,\n            paths=paths.secret_paths(),\n            uid=uid,\n            gid=gid,\n            vaultwarden_gid=vaultwarden_gid,\n            caddy_gid=caddy_gid,\n        )\n'''
edit("vaultwarden_oci/runtime.py", old_flow, new_flow)

# Update runtime-path checks for the derived Caddy hash when present.
edit(
    "vaultwarden_oci/runtime.py",
    '    secret_files = [secret_paths.file(key) for key in secrets.REQUIRED]\n',
    '    secret_files = [secret_paths.file(key) for key in secrets.REQUIRED]\n',
)

# Replace superseded edge test and add focused task-contract tests.
edge_test = ROOT / "tests/v2/test_edge.py"
text = edge_test.read_text(encoding="utf-8")
text = text.replace(
    '            runtime.render(config, versions, paths, cloudflare_policy=policy)\n\n            caddyfile = paths.caddyfile.read_text(encoding="utf-8")\n',
    '            runtime.render(config, versions, paths, admin_enabled=True)\n\n            caddyfile = paths.caddyfile.read_text(encoding="utf-8")\n',
)
text = text.replace(
    '            self.assertIn("trusted_proxies static", caddyfile)\n            self.assertIn("173.245.48.0/20", caddyfile)\n            self.assertIn("2400:cb00::/32", caddyfile)\n            self.assertIn("client_ip_headers CF-Connecting-IP", caddyfile)\n',
    '            self.assertIn("trusted_proxies cloudflare", caddyfile)\n            self.assertNotIn("trusted_proxies static", caddyfile)\n            self.assertNotIn("173.245.48.0/20", caddyfile)\n            self.assertNotIn("2400:cb00::/32", caddyfile)\n            self.assertIn("client_ip_headers CF-Connecting-IP", caddyfile)\n            self.assertIn("key {client_ip}", caddyfile)\n            self.assertIn("basic_auth", caddyfile)\n',
)
edge_test.write_text(text, encoding="utf-8")

runtime_test = ROOT / "tests/v2/test_runtime.py"
text = runtime_test.read_text(encoding="utf-8")
text = text.replace(
    '    "vaultwarden_admin_token": "admin-secret",\n}',
    '    "vaultwarden_admin_token": "admin-secret",\n    "admin_basic_auth_password": "outer-gate-secret",\n}',
)
text = text.replace(
    '        self.assertIn("github.com/caddy-dns/cloudflare@v0.2.4", dockerfile)\n',
    '        self.assertIn("github.com/caddy-dns/cloudflare@v0.2.4", dockerfile)\n        self.assertIn("github.com/WeidiDeng/caddy-cloudflare-ip@f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5", dockerfile)\n        self.assertIn("github.com/fvbommel/caddy-combine-ip-ranges@v0.0.1", dockerfile)\n        self.assertIn("github.com/mholt/caddy-ratelimit@v0.1.0", dockerfile)\n        self.assertIn("trusted_proxies cloudflare", caddyfile)\n        self.assertNotIn("trusted_proxies static", caddyfile)\n',
)
runtime_test.write_text(text, encoding="utf-8")

new_test = ROOT / "tests/v2/test_caddy_edge_admin.py"
new_test.write_text(r'''from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import edge, runtime, secrets

OFFLINE = "age1" + "q" * 58


def versions_text() -> str:
    return ''' + "'''" + r'''schema_version = 1
[vaultwarden_oci]
version = "0.1.0-dev.9"
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
''' + "'''" + r'''


class CaddyEdgeAdminContractTests(unittest.TestCase):
    def _render(self, admin_enabled: bool):
        root = Path(self.directory.name)
        versions = root / "versions.toml"
        versions.write_text(versions_text(), encoding="utf-8")
        paths = runtime.Paths(
            config=root / "config.toml", data=root / "data", caddy_data=root / "caddy/data",
            caddy_config=root / "caddy/config", caddy_log=root / "caddy/log", run=root / "run",
            transient=root / "run/transient", lock=root / "run/lock", secret_root=root / "run/secrets",
        )
        paths.transient.mkdir(parents=True)
        cfg = runtime.RuntimeConfig(
            domain="vault.example.net", acme_email="admin@example.net", offline_recovery_recipient=OFFLINE,
            signups_allowed=False, smtp_host="smtp.example.net", smtp_port=587, smtp_security="starttls",
            smtp_from_email="vaultwarden@example.net", smtp_from_name="Vaultwarden", smtp_timeout_seconds=15,
        )
        runtime.render(cfg, versions, paths, admin_enabled=admin_enabled)
        return paths

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.directory.cleanup()

    def test_build_has_exact_required_addons_and_proxy_module_not_static_cidrs(self):
        paths = self._render(True)
        dockerfile = paths.dockerfile.read_text(encoding="utf-8")
        caddyfile = paths.caddyfile.read_text(encoding="utf-8")
        for pin in (
            "github.com/caddy-dns/cloudflare@v0.2.4",
            "github.com/WeidiDeng/caddy-cloudflare-ip@f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5",
            "github.com/fvbommel/caddy-combine-ip-ranges@v0.0.1",
            "github.com/mholt/caddy-ratelimit@v0.1.0",
        ):
            self.assertIn(pin, dockerfile)
        self.assertIn("trusted_proxies cloudflare", caddyfile)
        self.assertIn("client_ip_headers CF-Connecting-IP", caddyfile)
        self.assertNotIn("trusted_proxies static", caddyfile)
        self.assertNotIn("173.245.48.0/20", caddyfile)

    def test_admin_and_auth_rate_limits_use_real_client_ip_and_outer_gate(self):
        caddyfile = self._render(True).caddyfile.read_text(encoding="utf-8")
        self.assertGreaterEqual(caddyfile.count("key {client_ip}"), 2)
        self.assertIn("@admin path /admin*", caddyfile)
        self.assertIn("basic_auth", caddyfile)
        self.assertIn("admin {env.ADMIN_BASIC_AUTH_HASH}", caddyfile)
        self.assertIn("/identity/connect/token*", caddyfile)
        self.assertIn("/api/accounts/prelogin*", caddyfile)
        self.assertNotIn("ADMIN_ALLOW_CIDR", caddyfile)

    def test_admin_disabled_is_closed_at_caddy(self):
        caddyfile = self._render(False).caddyfile.read_text(encoding="utf-8")
        self.assertIn("respond @admin 404", caddyfile)
        self.assertNotIn("ADMIN_BASIC_AUTH_HASH", caddyfile)

    def test_admin_source_secret_pairing_and_hash_boundary(self):
        with self.assertRaises(secrets.SecretsError):
            secrets.admin_enabled({"vaultwarden_admin_token": "token"})
        self.assertTrue(secrets.admin_enabled({
            "vaultwarden_admin_token": "token", "admin_basic_auth_password": "source-secret"
        }))
        completed = mock.Mock(returncode=0, stdout="$2a$14$hash\n", stderr="")
        with mock.patch("vaultwarden_oci.secrets.subprocess.run", return_value=completed) as run:
            value = secrets.derive_admin_basic_auth_hash("source-secret", "caddy:2.11.4@sha256:" + "a" * 64)
        self.assertEqual(value, "$2a$14$hash")
        argv = run.call_args.args[0]
        self.assertNotIn("source-secret", argv)
        self.assertNotIn("--plaintext", argv)
        self.assertEqual(run.call_args.kwargs["input"], "source-secret\n")

    def test_origin_firewall_implementation_remains_separate(self):
        self.assertTrue(callable(edge.refresh_origin_policy))
        self.assertEqual(edge.CHAIN, "VWOCI-CF-HTTPS")
        self.assertEqual(edge.GUARD_COMMENT, "vaultwarden-oci:cloudflare-guard")
        self.assertFalse(hasattr(edge, "caddy_trusted_proxy_block"))


if __name__ == "__main__":
    unittest.main()
''', encoding="utf-8")

# Docs: only current operator manuals; never reports.
security = ROOT / "docs/SECURITY.md"
if security.exists():
    text = security.read_text(encoding="utf-8")
    note = '''\n## Caddy, Cloudflare, and admin defense\n\nCaddy uses the exact-pinned Cloudflare trusted-proxy module with `CF-Connecting-IP` to establish the real visitor IP for access logs and per-client rate limits. The project does not render Cloudflare CIDRs into a second Caddy `trusted_proxies static` list.\n\nThis does not replace origin filtering. The project-owned Docker `DOCKER-USER` policy independently validates Cloudflare IPv4/IPv6 ranges, keeps a bounded last-known-good policy, and fails closed for published HTTPS when no safe policy exists. CrowdSec Cloudflare remediation remains a third, separate control plane.\n\nWhen Vaultwarden admin is enabled, SOPS must contain both `vaultwarden_admin_token` and `admin_basic_auth_password`. The source Basic Auth password is passed to exact-pinned Caddy `hash-password` over stdin; only the derived hash is materialized in volatile `/run` state for Caddy. `/admin*` is also rate-limited by Caddy using `{client_ip}`. Removing both admin secrets disables the admin route at Caddy.\n'''
    if "## Caddy, Cloudflare, and admin defense" not in text:
        security.write_text(text.rstrip() + "\n" + note, encoding="utf-8")

print("edge hardening patch applied")
