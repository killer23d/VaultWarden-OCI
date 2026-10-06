from __future__ import annotations

import json
import unittest
from contextlib import nullcontext
from unittest import mock

from vaultwarden_oci import dns_publication


TOKEN = "cfut_" + "a" * 40
DOMAIN = "vault.example.com"
ZONE = "zone-id"
RECORD_ID = "record-id"
OLD_IP = "192.0.2.10"
PUBLIC_IP = "203.0.113.42"


def api_payload(result: object) -> bytes:
    return json.dumps({"success": True, "errors": [], "result": result}).encode("utf-8")


def record(ip: str = OLD_IP, *, proxied: bool = True) -> dict[str, object]:
    return {
        "id": RECORD_ID,
        "name": DOMAIN,
        "type": "A",
        "content": ip,
        "proxied": proxied,
        "ttl": 1,
    }


class PublicIPv4Tests(unittest.TestCase):
    def test_discovery_uses_bounded_fallbacks_and_validates_global_ipv4(self) -> None:
        calls: list[str] = []

        def fetcher(url: str, maximum: int) -> str:
            calls.append(url)
            self.assertEqual(maximum, dns_publication._MAX_RESPONSE_BYTES)
            if "cloudflare" in url:
                return "fl=1\nip=127.0.0.1\n"
            if "amazonaws" in url:
                return "not-an-ip\n"
            return "8.8.8.8\n"

        self.assertEqual(dns_publication.discover_public_ipv4(fetcher=fetcher), "8.8.8.8")
        self.assertEqual(calls, list(dns_publication._PUBLIC_IPV4_ENDPOINTS))

    def test_discovery_fails_when_no_provider_returns_global_ipv4(self) -> None:
        with self.assertRaisesRegex(dns_publication.DNSError, "cannot determine"):
            dns_publication.discover_public_ipv4(
                fetcher=lambda _url, _maximum: "192.168.1.2\n"
            )


class CloudflareRecordTests(unittest.TestCase):
    def requester_for(
        self,
        a_records: list[dict[str, object]],
        *,
        aaaa_records: list[dict[str, object]] | None = None,
    ):
        def requester(request, maximum: int) -> bytes:
            self.assertEqual(maximum, dns_publication._MAX_RESPONSE_BYTES)
            self.assertEqual(request.get_header("Authorization"), f"Bearer {TOKEN}")
            if "type=AAAA" in request.full_url:
                return api_payload(aaaa_records or [])
            if "type=A" in request.full_url:
                return api_payload(a_records)
            raise AssertionError(request.full_url)

        return requester

    def test_inspect_requires_exactly_one_a_record(self) -> None:
        with self.assertRaisesRegex(dns_publication.DNSError, "exactly one"):
            dns_publication.inspect_state(
                domain=DOMAIN,
                public_ipv4=PUBLIC_IP,
                token=TOKEN,
                zone_id=ZONE,
                requester=self.requester_for([]),
            )

        with self.assertRaisesRegex(dns_publication.DNSError, "exactly one"):
            dns_publication.inspect_state(
                domain=DOMAIN,
                public_ipv4=PUBLIC_IP,
                token=TOKEN,
                zone_id=ZONE,
                requester=self.requester_for([record(), record("8.8.4.4")]),
            )

    def test_inspect_rejects_explicit_aaaa(self) -> None:
        with self.assertRaisesRegex(dns_publication.DNSError, "AAAA"):
            dns_publication.inspect_state(
                domain=DOMAIN,
                public_ipv4=PUBLIC_IP,
                token=TOKEN,
                zone_id=ZONE,
                requester=self.requester_for(
                    [record()],
                    aaaa_records=[{"id": "v6"}],
                ),
            )

    def test_inspect_reports_proxy_and_sync_state_without_mutation(self) -> None:
        state = dns_publication.inspect_state(
            domain=DOMAIN,
            public_ipv4=PUBLIC_IP,
            token=TOKEN,
            zone_id=ZONE,
            requester=self.requester_for([record(PUBLIC_IP)]),
        )
        self.assertTrue(state.proxied)
        self.assertTrue(state.in_sync)
        self.assertEqual(state.record_id, RECORD_ID)


class UpdateTests(unittest.TestCase):
    def test_update_patches_only_content_and_verifies_authoritative_readback(self) -> None:
        requests = []
        a_get_count = 0

        def requester(request, maximum: int) -> bytes:
            nonlocal a_get_count
            requests.append(request)
            self.assertEqual(maximum, dns_publication._MAX_RESPONSE_BYTES)
            self.assertEqual(request.get_header("Authorization"), f"Bearer {TOKEN}")
            self.assertNotIn(TOKEN.encode(), request.data or b"")

            if request.method == "GET" and "type=AAAA" in request.full_url:
                return api_payload([])
            if request.method == "GET" and "type=A" in request.full_url:
                a_get_count += 1
                return api_payload([record(OLD_IP if a_get_count == 1 else PUBLIC_IP)])
            if request.method == "PATCH":
                self.assertEqual(
                    json.loads((request.data or b"{}").decode("utf-8")),
                    {"content": PUBLIC_IP},
                )
                return api_payload(record(PUBLIC_IP))
            raise AssertionError((request.method, request.full_url))

        with (
            mock.patch.object(
                dns_publication,
                "_context",
                return_value=(DOMAIN, PUBLIC_IP, TOKEN, ZONE),
            ),
            mock.patch.object(
                dns_publication.cli,
                "mutation_lock",
                return_value=nullcontext(),
            ),
        ):
            result = dns_publication.update(requester=requester)

        self.assertTrue(result.changed)
        self.assertTrue(result.applied)
        self.assertTrue(result.after.in_sync)
        self.assertEqual(
            [request.method for request in requests],
            ["GET", "GET", "PATCH", "GET", "GET"],
        )

    def test_dry_run_never_mutates_cloudflare(self) -> None:
        methods: list[str] = []

        def requester(request, _maximum: int) -> bytes:
            methods.append(request.method)
            if "type=AAAA" in request.full_url:
                return api_payload([])
            if "type=A" in request.full_url:
                return api_payload([record()])
            raise AssertionError("dry-run issued mutation")

        with (
            mock.patch.object(
                dns_publication,
                "_context",
                return_value=(DOMAIN, PUBLIC_IP, TOKEN, ZONE),
            ),
            mock.patch.object(
                dns_publication.cli,
                "mutation_lock",
                return_value=nullcontext(),
            ),
        ):
            result = dns_publication.update(dry_run=True, requester=requester)

        self.assertTrue(result.changed)
        self.assertFalse(result.applied)
        self.assertEqual(methods, ["GET", "GET"])

    def test_dns_only_record_fails_closed_instead_of_changing_proxy_state(self) -> None:
        methods: list[str] = []

        def requester(request, _maximum: int) -> bytes:
            methods.append(request.method)
            if "type=AAAA" in request.full_url:
                return api_payload([])
            if "type=A" in request.full_url:
                return api_payload([record(proxied=False)])
            raise AssertionError("unexpected mutation")

        with (
            mock.patch.object(
                dns_publication,
                "_context",
                return_value=(DOMAIN, PUBLIC_IP, TOKEN, ZONE),
            ),
            mock.patch.object(
                dns_publication.cli,
                "mutation_lock",
                return_value=nullcontext(),
            ),
        ):
            with self.assertRaisesRegex(dns_publication.DNSError, "DNS-only"):
                dns_publication.update(requester=requester)

        self.assertEqual(methods, ["GET", "GET"])

    def test_context_keeps_cloudflare_token_inside_python_owner(self) -> None:
        config = mock.Mock(domain=DOMAIN, offline_recovery_recipient="age1" + "a" * 58)
        with (
            mock.patch.object(dns_publication.os, "geteuid", return_value=0),
            mock.patch.object(dns_publication.runtime, "load_config", return_value=config),
            mock.patch.object(
                dns_publication.secrets,
                "load",
                return_value={"cloudflare_api_token": TOKEN},
            ),
            mock.patch.object(
                dns_publication.edge,
                "resolve_cloudflare_zone",
                return_value=("account", ZONE),
            ) as resolve,
        ):
            context = dns_publication._context(
                fetcher=lambda _url, _maximum: "8.8.8.8\n"
            )

        self.assertEqual(context, (DOMAIN, "8.8.8.8", TOKEN, ZONE))
        resolve.assert_called_once_with(DOMAIN, TOKEN)


if __name__ == "__main__":
    unittest.main()
