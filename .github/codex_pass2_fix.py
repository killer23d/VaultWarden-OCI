from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace(path: str, old: str, new: str, count: int = 1) -> None:
    p = ROOT / path
    text = p.read_text(encoding="utf-8")
    if text.count(old) < count:
        raise SystemExit(f"{path}: replacement anchor not found")
    p.write_text(text.replace(old, new, count), encoding="utf-8")


replace(
    "vaultwarden_oci/update_versions.py",
'''    exact = {\n        "architecture": arch,\n        "vaultwarden": vaultwarden,\n        "caddy": caddy,\n        "caddy_dns_cloudflare": plugin,\n        "digests": digests,\n    }\n''',
'''    exact = {\n        "architecture": arch,\n        "vaultwarden": vaultwarden,\n        "caddy": caddy,\n        "caddy_dns_cloudflare": plugin,\n        "caddy_cloudflare_ip": base.caddy_cloudflare_ip,\n        "caddy_combine_ip_ranges": base.caddy_combine_ip_ranges,\n        "caddy_ratelimit": base.caddy_ratelimit,\n        "digests": digests,\n    }\n''',
)

p = ROOT / "tests/v2/test_update_phase7.py"
text = p.read_text(encoding="utf-8")
anchor = '''    def test_use_latest_requires_explicit_development_gate(self) -> None:\n'''
test = '''    def test_latest_snapshot_identity_includes_fixed_edge_addon_pins(self) -> None:\n        class FakeLookup:\n            def latest_release(self, component: str) -> str:\n                return {\n                    "vaultwarden": "v1.40.0",\n                    "caddy": "v2.12.0",\n                    "caddy_dns_cloudflare": "v0.3.0",\n                }[component]\n\n            def image_digest(self, repository: str, tag: str, architecture: str) -> str:\n                return digest({\n                    "vaultwarden/server": "1",\n                    "caddy": "2" if "builder" in tag else "3",\n                }[repository])\n\n        with tempfile.TemporaryDirectory() as directory:\n            root = Path(directory)\n            first = versions_text(PHASE7_VERSION)\n            (root / "versions.toml").write_text(first, encoding="utf-8")\n            with mock.patch.dict(os.environ, {update_versions.DEVELOPMENT_ENV: "1"}, clear=False):\n                one = update_versions.resolve_latest(root, machine="amd64", lookup=FakeLookup())\n            second = first.replace('caddy_ratelimit = "v0.1.0"', 'caddy_ratelimit = "v0.1.1"')\n            (root / "versions.toml").write_text(second, encoding="utf-8")\n            with mock.patch.dict(os.environ, {update_versions.DEVELOPMENT_ENV: "1"}, clear=False):\n                two = update_versions.resolve_latest(root, machine="amd64", lookup=FakeLookup())\n        self.assertNotEqual(one.project_version, two.project_version)\n        self.assertEqual(one.caddy_ratelimit, "v0.1.0")\n        self.assertEqual(two.caddy_ratelimit, "v0.1.1")\n\n'''
if anchor not in text:
    raise SystemExit("test_update_phase7.py: anchor missing")
p.write_text(text.replace(anchor, test + anchor, 1), encoding="utf-8")

print("pass-2 version fingerprint fix applied")
