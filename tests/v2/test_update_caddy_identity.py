from __future__ import annotations

import unittest

from vaultwarden_oci import update_versions


def digest(char: str) -> str:
    return "sha256:" + char * 64


def frozen(*, addon: str, builder: str = "b", runtime: str = "c") -> update_versions.FrozenVersions:
    return update_versions.FrozenVersions(
        "pinned",
        "amd64",
        "2.0.0",
        "1.40.0",
        "2.12.0",
        "v0.3.0",
        update_versions.ImagePin("vaultwarden", "vaultwarden/server", "1.40.0", digest("a")),
        update_versions.ImagePin("caddy_builder", "caddy", "2.12.0-builder-alpine", digest(builder)),
        update_versions.ImagePin("caddy_runtime", "caddy", "2.12.0-alpine", digest(runtime)),
        caddy_cloudflare_ip="d" * 40,
        caddy_combine_ip_ranges="v0.0.2",
        caddy_ratelimit=addon,
    )


class CaddyImageIdentityTests(unittest.TestCase):
    def test_same_caddy_version_different_addon_ref_uses_different_local_image(self) -> None:
        one = frozen(addon="v0.2.0")
        two = frozen(addon="v0.2.1")
        self.assertNotEqual(one.caddy_image, two.caddy_image)
        self.assertTrue(one.caddy_image.startswith("vaultwarden-oci/caddy:2.12.0-edge-"))

    def test_base_image_digest_change_also_changes_local_image_identity(self) -> None:
        one = frozen(addon="v0.2.0", builder="b", runtime="c")
        two = frozen(addon="v0.2.0", builder="e", runtime="f")
        self.assertNotEqual(one.caddy_image, two.caddy_image)

    def test_identical_snapshot_is_deterministic(self) -> None:
        self.assertEqual(frozen(addon="v0.2.0").caddy_image, frozen(addon="v0.2.0").caddy_image)


if __name__ == "__main__":
    unittest.main()
