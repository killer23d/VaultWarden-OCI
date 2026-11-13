"""Official dual-stack Cloudflare IP API acceptance and bounded fallback tests."""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from vaultwarden_oci import edge

V4 = ["173.245.48.0/20", "103.21.244.0/22"]
V6 = ["2400:cb00::/32"]


def response(v4=None, v6=None, *, success=True):
    return json.dumps({
        "success": success,
        "errors": [],
        "messages": [],
        "result": {
            "ipv4_cidrs": V4 if v4 is None else v4,
            "ipv6_cidrs": V6 if v6 is None else v6,
            "etag": "test",
        },
    })


class CloudflareApiPolicyTests(unittest.TestCase):
    def test_success_prefers_official_api_without_legacy_requests(self):
        seen = []

        def fetch(url, maximum):
            seen.append((url, maximum))
            self.assertEqual(url, edge.CLOUDFLARE_IPS_API_URL)
            return response()

        policy = edge.fetch_cloudflare_policy(now=2026, fetcher=fetch)
        self.assertEqual(policy.source, "current")
        self.assertEqual(len(policy.ipv4), 2)
        self.assertEqual(len(policy.ipv6), 1)
        self.assertEqual(seen, [(edge.CLOUDFLARE_IPS_API_URL, edge.MAX_RESPONSE_BYTES)])

    def test_invalid_api_falls_back_to_complete_official_legacy_pair(self):
        seen = []

        def fetch(url, maximum):
            seen.append(url)
            if url == edge.CLOUDFLARE_IPS_API_URL:
                return response(v6=[])
            if url == edge.CLOUDFLARE_IPV4_URL:
                return "\n".join(V4)
            if url == edge.CLOUDFLARE_IPV6_URL:
                return "\n".join(V6)
            self.fail("unexpected source")

        policy = edge.fetch_cloudflare_policy(now=2026, fetcher=fetch)
        self.assertEqual(len(policy.cidrs), 3)
        self.assertEqual(
            seen, [
                edge.CLOUDFLARE_IPS_API_URL,
                edge.CLOUDFLARE_IPV4_URL,
                edge.CLOUDFLARE_IPV6_URL,
            ],
        )

    def test_bad_api_payloads_cannot_pass_direct_validation(self):
        malformed = [
            "",
            "not-json",
            "[]",
            "{}",
            json.dumps({"success": False, "result": {
                "ipv4_cidrs": V4, "ipv6_cidrs": V6,
            }}),
            json.dumps({"success": True, "result": {}}),
            json.dumps({"success": True, "result": {
                "ipv4_cidrs": V4, "ipv6_cidrs": [],
            }}),
            response(v4=[V4[0], V4[0]]),
            response(v4=["10.0.0.0/8", V4[1]]),
            response(v4=["173.245.48.0/20", "173.245.48.0/21"]),
            response(v4=["173.245.48.1/20", V4[1]]),
            response(v4=["2400:cb00::/32", V4[1]]),
            response(v4=[True, V4[1]]),
            response(v4=[V4[0] + "\n" + V4[1]]),
            response(v6=[V4[0]]),
            response(v6=["fc00::/7"]),
            response(v6=["2400:cb00::/32", "2400:cb00::/48"]),
            response(v4=V4 * 40),
            response() + " " * edge.MAX_RESPONSE_BYTES,
        ]
        for payload in malformed:
            with self.subTest(payload=payload[:45]):
                with self.assertRaises(edge.EdgeError):
                    edge.parse_cloudflare_api_policy(payload, fetched_at=2026)

    def test_offline_legacy_403_uses_valid_lkg_and_rejects_expired(self):
        def api_only(url, maximum):
            if url == edge.CLOUDFLARE_IPS_API_URL:
                return response()
            self.fail("valid API must not contact legacy feeds")

        def offline(url, maximum):
            raise edge.EdgeError("HTTPS fetch failed")

        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / "ranges.json"
            current = edge.select_policy(path=cache, now=5000, fetcher=api_only)
            self.assertEqual(current.source, "current")
            offline_policy = edge.select_policy(path=cache, now=5001, fetcher=offline)
            self.assertEqual(offline_policy.source, "last-known-good")
            with self.assertRaisesRegex(edge.EdgeError, "no safe Cloudflare"):
                edge.select_policy(
                    path=cache,
                    now=5001 + edge.LKG_MAX_AGE_SECONDS,
                    fetcher=offline,
                )

    def test_bad_json_and_incomplete_legacy_never_publish_policy(self):
        requested = []

        def invalid(url, maximum):
            requested.append(url)
            if url == edge.CLOUDFLARE_IPS_API_URL:
                return response(v4=[V4[0], V4[0]])
            if url == edge.CLOUDFLARE_IPV4_URL:
                return "\n".join(V4)
            return "fc00::/7"

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "no-cache.json"
            with self.assertRaisesRegex(edge.EdgeError, "no safe Cloudflare"):
                edge.select_policy(path=path, now=100, fetcher=invalid)
            self.assertEqual(
                requested,
                [
                    edge.CLOUDFLARE_IPS_API_URL,
                    edge.CLOUDFLARE_IPV4_URL,
                    edge.CLOUDFLARE_IPV6_URL,
                ],
            )
            self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
