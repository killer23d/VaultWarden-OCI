from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace(path: str, old: str, new: str) -> None:
    target = ROOT / path
    text = target.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"{path}: replacement anchor not found")
    target.write_text(text.replace(old, new, 1), encoding="utf-8")


replace(
    "vaultwarden_oci/edge.py",
    '''def doctor_checks(\n''',
    '''def _caddy_trust_configured(caddy_text: str) -> bool:\n    return (\n        "trusted_proxies cloudflare {" in caddy_text\n        and "timeout 15s" in caddy_text\n        and "trusted_proxies_strict" in caddy_text\n        and "client_ip_headers CF-Connecting-IP" in caddy_text\n        and "trusted_proxies static" not in caddy_text\n    )\n\n\ndef _caddy_admin_disabled(caddy_text: str) -> bool:\n    return "@admin path /admin*" in caddy_text and "respond @admin 404" in caddy_text\n\n\ndef _caddy_admin_protected(caddy_text: str) -> bool:\n    if "@admin path /admin*" not in caddy_text:\n        return False\n    start = caddy_text.find(" handle @admin {")\n    if start < 0:\n        return False\n    end = caddy_text.find(" @auth path", start)\n    if end < 0:\n        return False\n    admin_block = caddy_text[start:end]\n    return all(\n        marker in admin_block\n        for marker in (\n            "rate_limit {",\n            "zone admin {",\n            "key {client_ip}",\n            "basic_auth {",\n            "admin {env.ADMIN_BASIC_AUTH_HASH}",\n        )\n    )\n\n\ndef doctor_checks(\n''',
)

replace(
    "vaultwarden_oci/edge.py",
    '''        trusted = (\n            "trusted_proxies cloudflare" in caddy_text\n            and "client_ip_headers CF-Connecting-IP" in caddy_text\n            and "trusted_proxies static" not in caddy_text\n        )\n''',
    '''        trusted = _caddy_trust_configured(caddy_text)\n''',
)

replace(
    "vaultwarden_oci/edge.py",
    '''            "Caddy uses the Cloudflare trusted-proxy module and CF-Connecting-IP" if trusted\n            else "Caddy trusted-proxy module/CF-Connecting-IP configuration is missing or duplicated with static CIDRs",\n''',
    '''            "Caddy uses strict Cloudflare trusted proxies with a bounded refresh and CF-Connecting-IP" if trusted\n            else "Caddy trusted-proxy strictness/timeout/CF-Connecting-IP configuration is missing or duplicated with static CIDRs",\n''',
)

replace(
    "vaultwarden_oci/edge.py",
    '''        admin_disabled = "respond @admin 404" in caddy_text\n        admin_gated = "basic_auth" in caddy_text and "rate_limit" in caddy_text\n''',
    '''        admin_disabled = _caddy_admin_disabled(caddy_text)\n        admin_gated = _caddy_admin_protected(caddy_text)\n''',
)

replace(
    "tests/v2/test_caddy_edge_admin.py",
    '''        paths.transient.mkdir(parents=True)\n''',
    '''        paths.transient.mkdir(parents=True, exist_ok=True)\n''',
)

replace(
    "tests/v2/test_caddy_edge_admin.py",
    '''    def test_admin_disabled_is_closed_at_caddy(self):\n''',
    '''    def test_doctor_render_checks_reject_partial_trust_or_admin_drift(self):\n        caddyfile = self._render(True).caddyfile.read_text(encoding="utf-8")\n        self.assertTrue(edge._caddy_trust_configured(caddyfile))\n        self.assertFalse(edge._caddy_trust_configured(caddyfile.replace("trusted_proxies_strict\\n", "", 1)))\n        self.assertFalse(edge._caddy_trust_configured(caddyfile.replace("timeout 15s", "timeout 0s", 1)))\n        self.assertTrue(edge._caddy_admin_protected(caddyfile))\n        self.assertFalse(edge._caddy_admin_protected(caddyfile.replace("zone admin {", "zone drifted {", 1)))\n        self.assertFalse(\n            edge._caddy_admin_protected(\n                caddyfile.replace("admin {env.ADMIN_BASIC_AUTH_HASH}", "admin missing-hash-source", 1)\n            )\n        )\n        disabled = self._render(False).caddyfile.read_text(encoding="utf-8")\n        self.assertTrue(edge._caddy_admin_disabled(disabled))\n        self.assertFalse(edge._caddy_admin_protected(disabled))\n\n    def test_admin_disabled_is_closed_at_caddy(self):\n''',
)

print("doctor drift audit fix applied")
