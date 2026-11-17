# P8U layered-origin candidate: rc.13 (not installed or accepted)

## Scope and prior results

This release branch proposes version 0.1.0-rc.13. It is **not** the immutable installed 0.1.0-rc.12 appliance and authorizes no live operations. P8S stopped-host HOLD and P8T / P8T-L OCI provider BLOCKED remain historical evidence exactly as observed. In the independently inspected OCI VCN default security list, **public IPv4 TCP 80 and 443 are allowed**. Shared-list use outside inspected compartments and provider IPv6 inventory were not conclusively proven. No OCI, Cloudflare, VM-service, data or backup mutation occurred in these tests.

Local P8U1 on the disposable Ubuntu 26.04 ARM64 appliance reported no listener on TCP 80 or 443, and valid 24-hour-old Cloudflare LKG: 15 IPv4 ranges, seven IPv6 ranges. Each effective DOCKER-USER family had one origin-policy jump, all expected allow rules, a final DROP, and no terminal bypass rules preceding the jump. No temporary guard remained, which is normal after successful installation. This is **structural evidence only**; packet-path, reboot/Docker restart, Cloudflare DNS and Worker routing, OCI policy correction and live canary are not proven.

## Required operator-selected architecture

* OCI public TCP 80: **must not be allowed** on any applicable VNIC NSG or subnet security-list union.
* OCI TCP 443: publicly reachable transport is permissible **only** after independent current host-origin enforcement and direct-origin bypass checks PASS. Do not treat a public OCI 443 rule alone as a security control.
* OCI SSH: preserve approved restricted source rules. Do not edit shared default security lists without a separately reviewed blast radius and approval.
* Host firewall: dynamically retrieve official Cloudflare IPv4 and IPv6 CIDRs, enforce the original-direction published HTTPS Docker packet path, require default DROP and correct rule ordering, and prevent Docker bridge or host-published-port bypass.
* No static Cloudflare CIDR list is to be maintained inside OCI security lists or NSGs. Do not add Cloudflare Tunnel or Authenticated Origin Pulls without separate authorization.
* Caddy: preserve Cloudflare trusted proxies, DNS-01 HTTPS, rate limits and admin restrictions. No public TCP 80 listener is part of the current design.
* Preserve historical hostname, Box remote, recovered secrets, SQLite, dedicated ext4 data disk, and one-shot acceptance evidence. Never use recovered data for public canaries.

## Product changes proposed in rc.13

The product edge policy now prefers the official public GET https://api.cloudflare.com/client/v4/ips and validates one complete dual-stack result, using the same public canonical CIDR, duplicates, overlaps and reserved/private address checks as the old policy. A bounded, strictly validated fallback may fetch both official legacy text endpoints; no third-party mirrors or partial-family policy are allowed. The existing 72-hour last-known-good expiry and fail-closed Docker guard sequencing are preserved, as are pinned container digests.

New tests exercise malformed JSON, false success, missing and incomplete IPv4/IPv6 families, CIDR duplication, overlap, private/reserved ranges, overflow, API vs legacy fallback, expiry, and missing acceptable policy. The synthetic CrowdSec unit-test state markers are redirected into temporary fixtures instead of the installed appliance. ARM64 Caddy/Vaultwarden rendering fixtures are now tested explicitly, without accidentally applying AMD64 expected digests to native ARM64 test runs.

## Gate decisions (never infer a pass)

**BLOCKED:** any observed public OCI TCP 80 allow rule; any confirmed direct-origin bypass; a host source policy missing, incorrectly ordered, stale beyond its permitted age or not verified; or an unexpected live listener/service. Confirmed unsafe IPv6 exposure is also BLOCKED.

**HOLD:** any missing OCI/IPv6/NSG/security-list inventory, independent Worker route/domain or DNS proof, original-production-instance and serial-console isolation, separate test FQDN, blank dataset, test-only offsite destination, verified reboot/restart packet path, or required CI/ARM64 release validation. A structurally correct firewall alone does not authorize a live canary.

**Eligible for separate canary approval (not automatic GO):** the public-HTTP-80 rule is corrected and independently re-audited; complete dual-stack current official policy and LKG expiry are proven; a source-pinned rc.13 candidate passes full CI including native ARM64; host firewall filtering and Docker/caddy exposure survive controlled refresh, service restart, and reboot without bypass; DNS/Worker and original-host separation are independently proved; and an isolated blank dataset plus test-only backup are available. A distinct live-canary authorization is still mandatory.

## Execution boundary

This document and the regression tests do not run OCI writes, service start/restart, DNS/Worker mutation, Box operations, SMTP, timers, reboot or production cutover. Such steps require explicit additional consent. The next disposable-host batch must be source-pinned and confined to read-only diagnostics and synthetic tests until the remaining gates are satisfied.
