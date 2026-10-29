"""Temporary upstream pin discovery; only used on the isolated verification branch.

Never merge this probe file; the final v2 release uses its verified result.
"""
from __future__ import annotations

import base64
import json
from pathlib import Path
import unittest

from vaultwarden_oci.update_versions import RemoteLookup, resolve_latest


class TestLatestPinProbe(unittest.TestCase):
    def test_resolve_latest_for_both_supported_architectures(self):
        class CachedLookup(RemoteLookup):
            def __init__(self):
                super().__init__()
                self.releases = {}
                self.refs = {}
                self.images = {}

            def latest_release(self, component):
                if component not in self.releases:
                    self.releases[component] = super().latest_release(component)
                return self.releases[component]

            def latest_ref(self, component):
                if component not in self.refs:
                    self.refs[component] = super().latest_ref(component)
                return self.refs[component]

            def image_digest(self, repository, tag, architecture):
                key = (repository, tag, architecture)
                if key not in self.images:
                    self.images[key] = super().image_digest(repository, tag, architecture)
                return self.images[key]

        source = Path(__file__).resolve().parents[1]
        lookup = CachedLookup()
        arm = resolve_latest(source, machine="arm64", lookup=lookup)
        amd = resolve_latest(source, machine="amd64", lookup=lookup)

        components = (
            "vaultwarden",
            "caddy",
            "caddy_dns_cloudflare",
            "caddy_cloudflare_ip",
            "caddy_combine_ip_ranges",
            "caddy_ratelimit",
        )
        for name in components:
            self.assertEqual(getattr(arm, name), getattr(amd, name), name)

        images = ("vaultwarden_image", "caddy_builder_image", "caddy_runtime_image")
        for name in images:
            self.assertEqual(getattr(arm, name).tag, getattr(amd, name).tag, name)

        result = {
            "components": {key: getattr(arm, key) for key in components},
            "image_digests": {
                getattr(arm, key).name: {
                    "arm64": getattr(arm, key).digest,
                    "amd64": getattr(amd, key).digest,
                }
                for key in images
            },
            "image_tags": {getattr(arm, key).name: getattr(arm, key).tag for key in images},
            "source_version": "0.1.0-rc.10",
        }
        encoded = base64.b64encode(
            json.dumps(result, sort_keys=True, separators=(",", ":")).encode("ascii")
        ).decode("ascii")
        print("VWOCI_PIN_PROBE_B64=" + encoded, flush=True)


if __name__ == "__main__":
    unittest.main()
