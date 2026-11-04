# P8E — OCI network identity read-only evidence before isolated live testing

**Current state:** P8A was accepted **HOLD/exit 0** after 115 focused tests on the original ARM64 host. The initial real P8E run at commit `24a80819e810b3d4cb267daa4c9c8d3e80d8a2b6` ran **116 focused tests successfully** and verified original P8A, stopped rc.12, CrowSec/Cloudflare, SQLite, SOPS/Age and doctor controls. It then returned **BLOCKED/exit 2 during read-only OCI metadata**, with the original script suppressing the precise subcategory; no host, firewall, DNS, Cloudflare, OCI control-plane, or Box mutations occurred. Private sanitized summary: `~/vwoci-acceptance/p8e-network-identity-20261104T195447Z-7165/summary.txt`. The failure's actual cause is **not yet known**. This is not evidence of damaged rc.12 or a production GO.

The follow-up P8E source correction (same review branch, new exact commit) reports only allowlisted **metadata schema/identity categories and endpoint phases**, without raw values. Oracle separately documents instance `displayName` and `hostname`; a difference from the Linux guest name must now be **PENDING for authoritative Console mapping**, not automatically a hard local integrity failure. Malformed OCID/VNIC/IP, unexpected A1 shape, oversized/redirected response, and other actual metadata-contract defects still BLOCK. A metadata HTTP or transport outage remains PENDING with only a safe numeric status/phase, never a fallback to IMDSv1. **This correction has not yet been exercised on the real host; do not retroactively relabel the initial BLOCKED.**

## Actual corrective P8E acceptance — 2026-11-04 UTC

The operator ran the exact reviewed candidate `af1907a0faae118950f173300a5b9aaa4158701b` on the original disposable `vaultwarden-oci-6-vnic`. **120 focused acceptance tests passed**; the real-host read-only P8E returned **HOLD, exit 0**, as intended. P8A HOLD evidence and original P7/P7R source/state were unchanged; installed rc.12/storage/SQLite/SOPS, doctor, CrowdSec engine and host INPUT firewall, disabled Cloudflare Worker, inactive Vaultwarden/Caddy/DNS/four timers remained valid. OCI link-local IMDSv2 returned a structurally valid VM.Standard.A1.Flex instance with one VNIC and a matching instance display name/hostname. The sanitized instance fingerprint was `33e9dc43ee5f` and VNIC fingerprint `c29f9e2daf58`; **reported_public_IPv4=0 and IPv6_subnet_indications=0 do not certify absence of Internet exposure.** Root-private operator summary: `~/vwoci-acceptance/p8e-network-identity-20261104T200549Z-7493/summary.txt`.

The Python test transcript also emitted one `ResourceWarning` for a synthetic HTTPError 429 fixture; all 120 tests passed. A separate **test-only** cleanup change closes that fixture explicitly. It does not alter the production runtime, acceptance host or historical evidence and does not require repeating the original P8E acceptance.

**Classification:** Original initial P8E BLOCKED is retained as historical diagnostic; corrected real-host P8E **ACCEPTED READ-ONLY HOLD/exit 0**. External NSGs/subnet security lists, effective ingress and IPv4/IPv6 routing, Cloudflare proxied DNS/Worker Route isolation, offline kit custody and separate Box prefix remain PENDING. No live-start consent, cloud changes or production GO.

## What this gate provides

`tests/host-acceptance/production-p8-oci-network-identity.py` runs on the **same original host**, `vaultwarden-oci-6-vnic`, and only under `sudo -n` from the `ubuntu` login.

1. Require a clean checkout at the precise P8E PR commit, approved host and architecture.
2. Read the existing root-private accepted P8A HOLD summary, without editing P7/P8 evidence.
3. Recheck local immutable rc.12, protected SQLite/SOPS/Age, 27-check doctor, Cloudflare DOCKER-USER ingress, CrowdSec INPUT bouncer, disabled Worker, empty Docker inventory and stopped application/timers using the already reviewed P7 read-only inventory.
4. Query ONLY Oracle **IMDSv2** link-local `GET` endpoints at `http://169.254.169.254/opc/v2/instance/` and `.../vnics/` with `Authorization: Bearer Oracle`. No IMDSv1 fallback; no proxy, redirects, POST, provider write or hidden cloud credentials.
5. Check the VM's expected A1 Flex shape and structurally valid instance/VNIC OCIDs and private IPv4. Check both the IMDS display name and independent hostname against the Linux short name; if neither agrees, require an OCI Console mapping as PENDING without guessing identity. Print only 12-character SHA-256 fingerprints and VNIC counts. Public/private IP addresses, subnet CIDRs, OCIDs, SSH keys and raw IMDS JSON are never printed or retained.
6. Always classify effective OCI security rules, external IPv4/IPv6 routing, Cloudflare DNS/Worker Routes, external recovery custody and test-only Box destination as **PENDING** until independently proven. Metadata HTTP/unavailability and independent-name disagreement remain PENDING; fail-closed metadata-schema or security-integrity violations produce an allowlisted BLOCKED category (exit 2). Valid local identity yields **HOLD/exit 0**, not approval to start.

Oracle IMDS is VM-local evidence of identity, **not authoritative proof of effective NSG or subnet security-list policy**. An absent `publicIp` value in a VNIC response does **not** mean the VM lacks public IPv4. An IPv6 subnet indication does not prove a VNIC has a globally routable IPv6 address. An unavailable metadata endpoint remains PENDING, not an automatic failure or reason to enable legacy IMDS.

Evidence: a new root-private, sanitized `~/vwoci-acceptance/p8e-network-identity-*/summary.txt` only. The original P8A, P7 and P7R evidence and exclusive mutation markers must remain unchanged.

## Authoritative external evidence required after P8E

These are **view-only Console checks**. Do not edit security rules, DNS, Worker Routes, instance attachments or existing application state merely to complete this questionnaire.

**OCI Console:** Compute → Instances → `vaultwarden-oci-6-vnic` → Attached VNICs. Match the instance and each VNIC to the P8E fingerprints when performing the operator review. Inspect primary/secondary VNICs, any assigned public IPv4 and IPv6, the subnet and the **entire set** of assigned NSGs. For the subnet, inspect **all** associated security lists and both IPv4 and IPv6 ingress rules for published TCP/443. NSG rules and subnet security lists are additive: **any** matching allow rule can permit ingress. Confirm effective routing, not just an individual NSG. OCI serial-console recovery access remains mandatory before any later controlled live mutation.

**Cloudflare dashboard:** identify a proposed distinct **test-only** hostname, Cloudflare zone/DNS-01 challenge authority, proxied DNS routing and current Worker Routes. Check exact and wildcard Route overlaps, and whether existing production traffic can ever hit the test origin. Do not create or modify a Cloudflare Route or DNS record now. Any later Worker invocation requires a fresh Route **Fail Open** check, not a reuse of historical consent.

**Recovery and backup:** the original encrypted ZIP, matching offline private Age identity and separately held passphrase must be recoverable **off this VM**. Choose a genuinely separate test-only Box destination if a later approved remote backup rehearsal is planned; retention on the restored original remains 0/0 (no automatic age pruning). Do not copy private credentials or test into `bw-backup:bw-backup`.

## Architecture recommendation

Use a second disposable OCI ARM64 test VM with its own dedicated storage, public routing controls and distinct hostname to execute the later P8B supported first start, rather than reconfigure the original restored appliance and invalidate accepted continuity evidence. Read-only P8E on the original host can collect the VNIC identity needed for the OCI Console comparison, but it does not authorize provisioning a VM or copying a recovery authority.

Before P8B, prepare a separate branch and single consent-gated script that verifies approved target storage/config, secure Cloudflare-only origin guard **before** Docker publishes TCP/443, and has a bounded product-owned stop/rollback. Certificate issuance/DNS-01, DNS record change, Worker activation, SMTP, Box publication and reboot require their own explicit operator approvals. The shared `bw.lazymocha.com` hostname and original `bw-backup:bw-backup` are prohibited experimental endpoints.

References: Oracle [Getting Instance Metadata](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/gettingmetadata.htm), [Virtual Network Interface Cards](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/managingVNICs.htm), and [Security Rules](https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/securityrules.htm).

**Do not mistake a P8E HOLD with no BLOCKED rows as external isolation verified.** A live rc.12 start and production GO/NO-GO are still NOT RUN.
