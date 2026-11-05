"""Verify official Cloudflare /ips behavior without weakening origin fail-close."""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import edge

V4 = ["173.245.48.0/20", "103.21.244.0/22"]
V6 = ["2400:cb00::/32"]


def api_record(*, ipv4=None, ipv6=None, success=True):
    return json.dumps({"success": success, "result": {
        "ipv4_cidrs": V4 if ipv4 is None else ipv4,
        "ipv6_cidrs": V6 if ipv6 is None else ipv6,
        "etag": "dummy"}})


class CloudflareIPAPIFallback(unittest.TestCase):
    def test_primary_official_api_is_used_without_legacy_downloads(self):
        seen = []
        def fetch(url, max_bytes):
            seen.append((url, max_bytes))
            if url != edge.CLOUDFLARE_IPS_API_URL:
                self.fail("legacy download should not run when API is valid")
            return api_record()
        policy = edge.fetch_cloudflare_policy(now=1000, fetcher=fetch)
        self.assertEqual(policy.source, "current")
        self.assertEqual(tuple(str(x) for x in policy.ipv4), tuple(sorted(V4)))
        self.assertEqual(tuple(str(x) for x in policy.ipv6), tuple(V6))
        self.assertEqual(seen, [(edge.CLOUDFLARE_IPS_API_URL, edge.MAX_RESPONSE_BYTES)])

    def test_403_on_primary_uses_only_both_official_legacy_addresses(self):
        calls = []
        def fetch(url, max_bytes):
            calls.append(url)
            if url == edge.CLOUDFLARE_IPS_API_URL:
                raise edge.EdgeError("public API HTTP 403")
            if url == edge.CLOUDFLARE_IPV4_URL:
                return "\n".join(V4)
            if url == edge.CLOUDFLARE_IPV6_URL:
                return "\n".join(V6)
            self.fail("non-official endpoint used")
        policy = edge.fetch_cloudflare_policy(now=1000, fetcher=fetch)
        self.assertEqual(policy.source, "current")
        self.assertEqual(calls, [edge.CLOUDFLARE_IPS_API_URL,
                                  edge.CLOUDFLARE_IPV4_URL, edge.CLOUDFLARE_IPV6_URL])

    def test_bad_api_payload_is_rejected_and_legacy_checked(self):
        for payload in (
            "{",
            "{}",
            api_record(success=False),
            api_record(ipv4=["10.0.0.0/8"]),
            api_record(ipv6=[]),
            api_record(ipv4=V4 + V4),
            api_record(ipv4=["173.245.48.1/20", "103.21.244.0/22"]),
            json.dumps({"success": True, "result": {"ipv4_cidrs": V4}}),
        ):
            with self.subTest(payload=payload[:40]):
                urls = []
                def fetch(url, max_bytes):
                    urls.append(url)
                    if url == edge.CLOUDFLARE_IPS_API_URL:
                        return payload
                    if url == edge.CLOUDFLARE_IPV4_URL:
                        return "\n".join(V4)
                    if url == edge.CLOUDFLARE_IPV6_URL:
                        return "\n".join(V6)
                    self.fail("non-official endpoint")
                value = edge.fetch_cloudflare_policy(now=1000, fetcher=fetch)
                self.assertEqual(value.source, "current")
                self.assertEqual(len(urls), 3)

    def test_unavailable_both_official_sources_preserves_bounded_lkg(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/"cloudflare-ranges.json"
            good=edge.validate_policy("\n".join(V4), "\n".join(V6),
                                      fetched_at=1000, source="current")
            edge.persist_lkg(good, path)
            calls=[]
            def offline(url, max_bytes):
                calls.append(url)
                raise edge.EdgeError("unavailable")
            current=edge.select_policy(path=path, now=1001, fetcher=offline)
            self.assertEqual(current.source, "last-known-good")
            self.assertEqual(calls, [edge.CLOUDFLARE_IPS_API_URL,
                                     edge.CLOUDFLARE_IPV4_URL])
            with self.assertRaises(edge.EdgeError):
                edge.select_policy(path=path, now=1001+edge.LKG_MAX_AGE_SECONDS,
                                   fetcher=offline)

    def test_malformed_api_and_legacy_keep_start_fail_closed(self):
        from vaultwarden_oci.cli import CommandResult
        seen=[]
        def runner(argv, **kwargs):
            seen.append(tuple(argv))
            if "-L" in argv and "DOCKER-USER" in argv:
                return CommandResult(tuple(argv), "success", 0, "", "")
            if "-C" in argv:
                return CommandResult(tuple(argv), "exit", 1, "", "")
            return CommandResult(tuple(argv), "success", 0, "", "")
        def bad(url, max_bytes):
            if url == edge.CLOUDFLARE_IPS_API_URL:
                return api_record(ipv4=["0.0.0.0/0"])
            raise edge.EdgeError("HTTP 403")
        with tempfile.TemporaryDirectory() as folder, self.assertRaises(edge.EdgeError):
            edge.refresh_origin_policy(path=Path(folder)/"no-lkg.json", now=1000,
                                       fetcher=bad, runner=runner)
        self.assertTrue(any(edge.GUARD_COMMENT in row and "-I" in row
                            for row in seen))
        self.assertFalse(any("-D" in row and edge.GUARD_COMMENT in row
                             for row in seen))
        self.assertFalse(any("-F" in row and edge.CHAIN in row for row in seen))


if __name__ == "__main__":
    unittest.main()
