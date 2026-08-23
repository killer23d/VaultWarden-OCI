from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace(path: str, old: str, new: str, count: int = 1) -> None:
    p = ROOT / path
    text = p.read_text(encoding="utf-8")
    found = text.count(old)
    if found < count:
        raise SystemExit(f"{path}: expected {count} occurrence(s), found {found}: {old!r}")
    p.write_text(text.replace(old, new, count), encoding="utf-8")


# Insert the pre-rendered admin route into the Caddyfile rather than escaping it literally.
replace(
    "vaultwarden_oci/runtime.py",
    "{{admin_route}} @auth path /identity/connect/token* /api/accounts/prelogin* /api/accounts/register*\n",
    "{admin_route} @auth path /identity/connect/token* /api/accounts/prelogin* /api/accounts/register*\n",
)

# Keep the stable doctor ID contract in the same order edge.doctor_checks emits rows.
replace(
    "vaultwarden_oci/cli.py",
    '    "edge.caddy.trusted_proxy",\n    "edge.caddy.health",\n    "edge.admin.protection",\n',
    '    "edge.caddy.trusted_proxy",\n    "edge.admin.protection",\n    "edge.caddy.health",\n',
)

# This test only validates the native dual-stack bridge; Caddy no longer receives a Cloudflare CIDR policy.
replace(
    "tests/v2/test_edge_blockers.py",
    "runtime.render(config, versions, paths, cloudflare_policy=policy)",
    "runtime.render(config, versions, paths)",
)

p = ROOT / "tests/v2/test_vwctl.py"
text = p.read_text(encoding="utf-8")
old = '''        update_versions.ImagePin("caddy_runtime", "caddy", "2.12.0-alpine", digest("c")),\n    )\n'''
new = '''        update_versions.ImagePin("caddy_runtime", "caddy", "2.12.0-alpine", digest("c")),\n        caddy_cloudflare_ip="f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5",\n        caddy_combine_ip_ranges="v0.0.1",\n        caddy_ratelimit="v0.1.0",\n    )\n'''
if old not in text:
    raise SystemExit("test_vwctl.py: latest_frozen constructor anchor missing")
text = text.replace(old, new, 1)
old = '''        from vaultwarden_oci import notification, recovery, runtime\n'''
new = '''        from vaultwarden_oci import edge, notification, recovery, runtime\n'''
if old not in text:
    raise SystemExit("test_vwctl.py: status import anchor missing")
text = text.replace(old, new, 1)
old = '''            mock.patch.object(notification, "status_row", return_value=notification_row),\n            redirect_stdout(output),\n'''
new = '''            mock.patch.object(notification, "status_row", return_value=notification_row),\n            mock.patch.object(edge, "doctor_checks", return_value=[]),\n            redirect_stdout(output),\n'''
if old not in text:
    raise SystemExit("test_vwctl.py: status mocks anchor missing")
text = text.replace(old, new, 1)
p.write_text(text, encoding="utf-8")

print("CI integration fixes applied")
