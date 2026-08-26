#!/usr/bin/env python3
from pathlib import Path
import re
root = Path(__file__).resolve().parents[2]

for p in (root / 'tests').glob('*.py'):
    s = p.read_text(encoding='utf-8')
    s = s.replace('resolve_latest_supported', 'resolve_latest')
    s = s.replace('Release4BlockerTests', 'EdgeBlockerTests')
    s = s.replace('Release3RuntimeTests', 'RuntimeContractTests')
    s = s.replace('test_v1_e_shortcut_exits_and_email_uses_n', 'test_e_shortcut_exits_and_email_uses_n')
    s = s.replace('test_doctor_json_has_phase3_stable_ids', 'test_doctor_json_has_stable_ids')
    s = s.replace('test_actual_baseline_manifest_to_phase7_transition_is_not_noop', 'test_actual_baseline_manifest_to_candidate_transition_is_not_noop')
    s = s.replace('vwctl-command-that-does-not-exist-phase3', 'vwctl-command-that-does-not-exist')
    p.write_text(s, encoding='utf-8')

# The setup/install --use-latest test no longer needs the unrelated local-source override.
p = root / 'tests/test_vwctl.py'
s = p.read_text(encoding='utf-8')
s = s.replace('                mock.patch.dict(os.environ, {update_appliance.SOURCE_OVERRIDE_ENV: "1"}, clear=False),\n', '')
p.write_text(s, encoding='utf-8')

# Source override remains guarded; update only the human wording asserted by its focused regression test.
p = root / 'tests/test_update_safety_regressions.py'
s = p.read_text(encoding='utf-8')
s = s.replace('test_source_override_requires_explicit_development_gate', 'test_source_override_requires_explicit_override_gate')
s = s.replace('"developer/testing-only"', '"explicit developer/test override"')
p.write_text(s, encoding='utf-8')

# Supported latest resolves edge addon refs remotely; identity should change when the resolved ref changes.
p = root / 'tests/test_update_workflow.py'
s = p.read_text(encoding='utf-8')
old = '''        class FakeLookup:\n            def latest_release(self, component: str) -> str:\n                return {\n                    "vaultwarden": "v1.40.0",\n                    "caddy": "v2.12.0",\n                    "caddy_dns_cloudflare": "v0.3.0",\n                }[component]\n\n            def latest_ref(self, component: str) -> str:\n                return {\n                    "caddy_cloudflare_ip": "a" * 40,\n                    "caddy_combine_ip_ranges": "v0.0.2",\n                    "caddy_ratelimit": "v0.2.0",\n                }[component]\n\n            def image_digest(self, repository: str, tag: str, architecture: str) -> str:\n                return digest({\n                    "vaultwarden/server": "1",\n                    "caddy": "2" if "builder" in tag else "3",\n                }[repository])\n\n        with tempfile.TemporaryDirectory() as directory:\n            root = Path(directory)\n            first = versions_text(CANDIDATE_VERSION)\n            (root / "versions.toml").write_text(first, encoding="utf-8")\n            one = update_versions.resolve_latest(root, machine="amd64", lookup=FakeLookup())\n            second = first.replace('caddy_ratelimit = "v0.1.0"', 'caddy_ratelimit = "v0.1.1"')\n            (root / "versions.toml").write_text(second, encoding="utf-8")\n            two = update_versions.resolve_latest(root, machine="amd64", lookup=FakeLookup())\n        self.assertNotEqual(one.project_version, two.project_version)\n        self.assertEqual(one.caddy_ratelimit, "v0.1.0")\n        self.assertEqual(two.caddy_ratelimit, "v0.1.1")'''
new = '''        class FakeLookup:\n            def __init__(self, ratelimit: str):\n                self.ratelimit = ratelimit\n\n            def latest_release(self, component: str) -> str:\n                return {\n                    "vaultwarden": "v1.40.0",\n                    "caddy": "v2.12.0",\n                    "caddy_dns_cloudflare": "v0.3.0",\n                }[component]\n\n            def latest_ref(self, component: str) -> str:\n                return {\n                    "caddy_cloudflare_ip": "a" * 40,\n                    "caddy_combine_ip_ranges": "v0.0.2",\n                    "caddy_ratelimit": self.ratelimit,\n                }[component]\n\n            def image_digest(self, repository: str, tag: str, architecture: str) -> str:\n                return digest({\n                    "vaultwarden/server": "1",\n                    "caddy": "2" if "builder" in tag else "3",\n                }[repository])\n\n        with tempfile.TemporaryDirectory() as directory:\n            root = Path(directory)\n            (root / "versions.toml").write_text(versions_text(CANDIDATE_VERSION), encoding="utf-8")\n            one = update_versions.resolve_latest(root, machine="amd64", lookup=FakeLookup("v0.2.0"))\n            two = update_versions.resolve_latest(root, machine="amd64", lookup=FakeLookup("v0.2.1"))\n        self.assertNotEqual(one.project_version, two.project_version)\n        self.assertEqual(one.caddy_ratelimit, "v0.2.0")\n        self.assertEqual(two.caddy_ratelimit, "v0.2.1")'''
if old not in s:
    raise SystemExit('latest identity test block not found')
s = s.replace(old, new)
p.write_text(s, encoding='utf-8')
