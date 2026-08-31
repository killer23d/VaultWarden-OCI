from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from vaultwarden_oci import update_versions


def _digest(char: str) -> str:
    return "sha256:" + char * 64


def _versions(version: str = "0.1.0-dev.17") -> str:
    return f'''schema_version = 1

[vaultwarden_oci]
version = "{version}"

[components]
vaultwarden = "1.37.1"
caddy = "2.11.4"
caddy_dns_cloudflare = "v0.2.4"
caddy_cloudflare_ip = "f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5"
caddy_combine_ip_ranges = "v0.0.1"
caddy_ratelimit = "v0.1.0"
'''


class _Lookup:
    def latest_release(self, component: str) -> str:
        return {
            "vaultwarden": "v1.37.2",
            "caddy": "v2.11.4",
            "caddy_dns_cloudflare": "v0.2.4",
        }[component]

    def latest_ref(self, component: str) -> str:
        return {
            "caddy_cloudflare_ip": "f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5",
            "caddy_combine_ip_ranges": "v0.0.1",
            "caddy_ratelimit": "v0.1.0",
        }[component]

    def image_digest(self, repository: str, tag: str, architecture: str) -> str:
        del architecture
        if repository == "vaultwarden/server":
            return _digest("a")
        if "builder" in tag:
            return _digest("b")
        return _digest("c")


class LatestSourceIdentityTests(unittest.TestCase):
    def _source(self, root: Path) -> None:
        (root / "versions.toml").write_text(_versions(), encoding="utf-8")
        (root / "vwctl").write_text("#!/usr/bin/env python3\nprint('one')\n", encoding="utf-8")
        (root / "vwctl").chmod(0o755)
        package = root / "vaultwarden_oci"
        package.mkdir()
        (package / "sample.py").write_text("VALUE = 1\n", encoding="utf-8")

    def test_latest_identity_changes_with_release_source_bytes_but_not_bytecode_cache(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._source(root)
            lookup = _Lookup()

            first = update_versions.resolve_latest(root, machine="amd64", lookup=lookup)

            cache = root / "vaultwarden_oci/__pycache__"
            cache.mkdir()
            (cache / "sample.cpython-312.pyc").write_bytes(b"runtime bytecode")
            with_cache = update_versions.resolve_latest(root, machine="amd64", lookup=lookup)
            self.assertEqual(first.project_version, with_cache.project_version)

            (root / "vaultwarden_oci/sample.py").write_text("VALUE = 2\n", encoding="utf-8")
            changed = update_versions.resolve_latest(root, machine="amd64", lookup=lookup)
            self.assertNotEqual(first.project_version, changed.project_version)

    def test_frozen_source_rekeys_to_same_source_aware_latest_identity_without_network(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._source(root)
            resolved = update_versions.resolve_latest(root, machine="amd64", lookup=_Lookup())
            (root / "versions.toml").write_text(
                update_versions.frozen_versions_toml(resolved),
                encoding="utf-8",
            )

            rekeyed = update_versions.rekey_latest_frozen_source(
                root,
                root / "versions.toml",
                machine="amd64",
            )
            self.assertEqual(resolved.project_version, rekeyed.project_version)
            self.assertEqual(resolved.vaultwarden_image.digest, rekeyed.vaultwarden_image.digest)
            self.assertEqual(resolved.caddy_runtime_image.digest, rekeyed.caddy_runtime_image.digest)


if __name__ == "__main__":
    unittest.main()
