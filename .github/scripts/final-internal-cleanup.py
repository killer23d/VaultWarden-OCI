#!/usr/bin/env python3
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]

def read(path): return (root / path).read_text(encoding="utf-8")
def write(path, text): (root / path).write_text(text, encoding="utf-8")

# Installer: remove known pre-release compatibility aliases/target migration.
p = "vaultwarden_oci/install.py"
s = read(p)
s = re.sub(r'\nLEGACY_SYSTEMD_TARGET = """.*?"""\n', '\n', s, flags=re.S)
s = re.sub(r'\n# Backward-compatible internal aliases.*?_RELEASE_DIRS = RELEASE_DIRS\n', '\n', s, flags=re.S)
s = s.replace('_RELEASE_FILES', 'RELEASE_FILES').replace('_RELEASE_DIRS', 'RELEASE_DIRS')
s = re.sub(r'\n        if \(\n            unit == "vaultwarden-oci.target".*?            destination.unlink\(\)\n', '\n', s, flags=re.S)
s = s.replace("Phase 1's flock", "the global flock")
s = s.replace('help="development/testing only"', 'help="resolve supported upstreams once and freeze exact immutable values"')
s = s.replace('        require_development_target,\n', '')
s = s.replace('            require_development_target(root)\n', '')
s = s.replace('label = "frozen development" if args.use_latest else "pinned"', 'label = "latest-frozen" if args.use_latest else "pinned"')
write(p, s)

# One public exact-freeze --use-latest resolver; remove the hidden development-only variant.
p = "vaultwarden_oci/update_versions.py"
s = read(p)
s = s.replace('DEVELOPMENT_ENV = "VWOCI_DEVELOPMENT"\n', '')
s = re.sub(r'\n\ndef _require_development\(\) -> None:.*?\n\ndef _latest_snapshot\(', '\n\ndef _latest_snapshot(', s, flags=re.S)
s = re.sub(
    r'\n\ndef resolve_latest\(\n    source_root: Path,.*?\n\ndef resolve_latest_supported\(\n    source_root: Path,\n    \*,\n    machine: str \| None = None,\n    lookup: RemoteLookup \| None = None,\n\) -> FrozenVersions:\n    """Resolve every supported upstream boundary once for operator --use-latest\."""\n    return _latest_snapshot\(\n        source_root, machine=machine, lookup=lookup, include_all_addons=True\n    \)',
    '\n\ndef resolve_latest(\n    source_root: Path,\n    *,\n    machine: str | None = None,\n    lookup: RemoteLookup | None = None,\n) -> FrozenVersions:\n    """Resolve every supported upstream boundary once for explicit operator --use-latest."""\n    return _latest_snapshot(\n        source_root, machine=machine, lookup=lookup, include_all_addons=True\n    )',
    s,
    flags=re.S,
)
write(p, s)

# setup.py no longer needs to fake a development environment.
p = "vaultwarden_oci/setup.py"
s = read(p)
s = re.sub(
    r'    else:\n        old = os\.environ\.get\("VWOCI_DEVELOPMENT"\); os\.environ\["VWOCI_DEVELOPMENT"\] = "1"\n        try: frozen = resolve_latest\(source\)\n        finally:\n            if old is None: os\.environ\.pop\("VWOCI_DEVELOPMENT", None\)\n            else: os\.environ\["VWOCI_DEVELOPMENT"\] = old\n        with install\._frozen_source',
    '    else:\n        frozen = resolve_latest(source)\n        with install._frozen_source',
    s,
)
write(p, s)

# Remove setup_frontend monkey-patching of the former compatibility resolver.
p = "vaultwarden_oci/setup_frontend.py"
s = read(p)
s = s.replace(', update_versions', '')
s = re.sub(r'\n# setup\.py already freezes one snapshot.*?setup\.resolve_latest = update_versions\.resolve_latest_supported\n', '\n', s, flags=re.S)
write(p, s)

# Update the focused version tests to the one supported resolver.
p = "tests/test_update_workflow.py"
s = read(p)
s = re.sub(r'\n    def test_use_latest_requires_explicit_development_gate\(self\) -> None:.*?\n    def test_small_remote_lookup_boundary_normalizes_official_image_namespace', '\n    def test_small_remote_lookup_boundary_normalizes_official_image_namespace', s, flags=re.S)
s = re.sub(r'\n            with mock\.patch\.dict\(os\.environ, \{update_versions\.DEVELOPMENT_ENV: "1"\}, clear=False\):\n                (\w+) = update_versions\.resolve_latest', r'\n            \1 = update_versions.resolve_latest', s)
s = re.sub(r'\n            with mock\.patch\.dict\(os\.environ, \{update_versions\.DEVELOPMENT_ENV: "1"\}, clear=False\):\n                frozen = update_versions\.resolve_latest', '\n            frozen = update_versions.resolve_latest', s)
# Every fake used by resolve_latest now supplies exact addon refs too.
needle = '            def image_digest(self, repository: str, tag: str, architecture: str) -> str:'
addon = '            def latest_ref(self, component: str) -> str:\n                return {\n                    "caddy_cloudflare_ip": "a" * 40,\n                    "caddy_combine_ip_ranges": "v0.0.2",\n                    "caddy_ratelimit": "v0.2.0",\n                }[component]\n\n'
# Only inject into fake lookup classes before the remote-boundary test.
parts = s.split('    def test_small_remote_lookup_boundary_normalizes_official_image_namespace', 1)
parts[0] = parts[0].replace(needle, addon + needle)
s = '    def test_small_remote_lookup_boundary_normalizes_official_image_namespace'.join(parts)
write(p, s)

# Remove stage-era prose from current normal sources/tests; real version strings remain untouched.
for p in list((root / "vaultwarden_oci").glob("*.py")) + list((root / "tests").glob("*.py")):
    s = p.read_text(encoding="utf-8")
    s = re.sub(r'\bPhase\s+[0-9]+(?:[-–][0-9]+)?\b', 'pre-release implementation', s)
    s = s.replace('V2 beta', 'supported').replace('V2 ', '').replace(' V2', '')
    p.write_text(s, encoding="utf-8")

(root / ".github/scripts/final-internal-cleanup.py").unlink()
(root / ".github/workflows/final-internal-cleanup.yml").unlink()
