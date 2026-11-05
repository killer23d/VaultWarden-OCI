# P8T — batched read-only external-isolation audit

**Baseline integration commit:** `2ea58845bc354d6c81e8a9ba5712a57b6ffdecb6`. **Host:** `vaultwarden-oci-7-vnic`, Ubuntu 26.04 ARM64. **Scope:** P8S-to-P8T read-only boundary, NOT a live canary and NOT production GO.

## Accepted predecessor (do not rerun)

P8S-A on 2026-11-05 UTC from reviewed source `08de314333303d5ff671f81497723580ff394cc6`: 22/22 P8S-A/B regression tests PASS; private `/home/ubuntu/vwoci-acceptance/p8s-a-readonly-20261105T214536Z-3811/summary.txt` ended HOLD/0. Exact original historical data/SQLite SHA/operational SOPS-Age/52 files/12 units, dedicated ext4, stopped services/containers and local Cloudflare/CrowdSec IPv4+IPv6 passed. Generated/volatile runtime paths PENDING; independent OCI/Cloudflare isolation PENDING; no external mutation occurred. Original P8P BLOCKED/2 and P8R REARMED/0 retain their meaning.

P8T checks this root-private P8S summary, its exact PASS/PENDING/NOT RUN rows and current kernel boot continuity. P8T **does not run P8S, P8P, P8R or their original markers**. It checks that application units are still dormant and there are no published HTTP/Docker listeners or retained containers.

## One batched read-only source gate

One candidate branch, one PR and one single operator command:

- Exact clean git SHA, correct hostname, Ubuntu 26.04 ARM64, passwordless sudo.
- Independent P8S archived HOLD and kernel boot continuity, no unexpected local startup.
- Oracle IMDSv2 instance/VNIC identity, with bounded requests to the fixed local metadata endpoint.
- Optional authoritative OCI CLI **GET/list** queries as unprivileged `ubuntu` using existing OCI config or instance-principal read permissions: primary VNIC, public IPv4, subnet, **every** subnet security-list ingress and attached NSG ingress (additive union), IPv6 assigned objects. No network configuration is ever written.
- Latest official Cloudflare IPv4/IPv6 CIDR read to compare OCI 443 ingress sources. Public HTTP 80 and unauthorized HTTPS 443 allowances on any NSG or security list are **BLOCKED**; unknown or inaccessible provider rule data is PENDING, never passed.
- Optional GET-only Cloudflare zone, complete DNS pages, zone Worker routes and account Worker custom domains via the immutable installed rc.12 Cloudflare token. A separately supplied candidate test FQDN is checked against wildcard/Worker overlap and the OCI VNIC public IPv4. Missing Worker custom-domain permissions, missing candidate hostname or incomplete origin identity remains PENDING. Original production hostname `bw.lazymocha.com` remains immutable and must not be used as candidate.
- OCI console recovery and original VM separation require independent operator/provider confirmation: PENDING. A disposable blank application dataset and **test-only** offsite remote are not yet proven: PENDING.

No additional packages, IAM permissions, CLI config, Cloudflare tokens, API records or rclone remotes are automatically created. If OCI CLI or Cloudflare API read permissions are unavailable, the gate records PENDING, NOT inferred PASS; grant *read-only* privileges separately if desired. The command does not print raw CIDRs, OCIDs, VNIC IPs, DNS targets, tokens, secrets, SQL, Cloudflare responses or private doctor logs.

**An independent test hostname must be supplied via `--test-fqdn` to assess its DNS and Worker overlap.** It may be left blank to gather the rest of the evidence in the same run. The script never provisions a hostname or changes records. It will not start any service even when the read-only checks pass.

## Status semantics

`HOLD/exit 0`: the read-only audit ran without a detected blocking security drift, but any PENDING requires independent proof before a live canary. `BLOCKED/exit 2`: a known overpermissive provider ingress, candidate DNS/Worker collision, protected P8S evidence/boot mismatch, unexpected local app activation, or other fail-closed condition. Never treat BLOCKED as authorization to rerun P8R, edit firewall manually or delete one-shot markers.

Private sanitized evidence: `/home/ubuntu/vwoci-acceptance/p8t-readonly-<UTC>-<PID>/summary.txt`, owner root, 0600. Only paste sanitized summary and `P8T_EXIT` to chat; don't send raw provider responses or credential values.

## Next after P8T

If OCI/Cloudflare facts are complete and independent test hostname, serial console, test-only app dataset and isolated remote are verified, open **one** separate bounded P8U canary PR that proves the installed product-owned startup sequence, then external TLS/auth/admin, controlled stop/rollback and later test-only SMTP/backup/timer behavior. The historical restored production SQLite and `bw-backup:bw-backup` must **never** become live test fixtures. Reboot persistence is still a separate historical HOLD; a successful local filter rearm does not change P8P.

P8T read-only acceptance, even with all observed provider checks passing, **never** grants production permission.


## First real P8T host attempt and consolidated OCI metadata correction (November 5, 2026 UTC)

The operator ran original PR #414 P8T exact source `790a44f9b5fc3554f809b656940d6569cf887b00` on the disposable `vaultwarden-oci-7-vnic`: **16/16 P8T unit tests PASS**, P8S immutable predecessor evidence and local stopped-host checks PASS, then **P8T BLOCKED/exit 2** at `oci.imdsv2`. The original private sanitized record is `/home/ubuntu/vwoci-acceptance/p8t-readonly-20261105T220835Z-4268/summary.txt`. The network-authoritative NSG/security-list and Cloudflare tests **did not run** and may not be labeled PASS. No services, provider records, firewall, original backup, or historical markers were mutated.

This is **not evidence of public ingress exposure**: original P8T grouped multiple IMDSv2 failures under an undifferentiated `oci.imdsv2` label. In particular, it required Oracle's instance `displayName` to equal the Linux hostname, even though Oracle defines `displayName` as a friendly instance name and `hostname` as a separate metadata property. We cannot determine from the sanitized original output whether that comparison or a metadata schema/OCID mismatch triggered the failure. The correction does not claim an observed root cause until the next real host run.

The corrected gate validates bounded instance and VNIC OCIDs independently of friendly names, rejects duplicated VNIC identifiers, accepts an independently matching metadata hostname/displayName as an **informational PASS**, and marks name mismatches or unsupported metadata shapes **PENDING** with fixed sanitized reason codes. Missing metadata never becomes an OCI or Cloudflare security PASS. An authoritative provider VNIC/NSG/security-list and original VM isolation review is still required. New regression fixtures derive the field roles from the Oracle IMDSv2 documented schema rather than the old test's assumptions.

Run **one** fresh clean pinned checkout after latest CI, with the entire focused P8T regression suite plus its read-only host audit. Preserve both previous failed P8T and P8S reports; do not edit or replay historical markers. Expected outcome remains `HOLD/0` with unproven external network, recovery console, independent FQDN, and isolated backup destination marked PENDING until verified. A genuine unexpected local service activation or authoritative OCI overpermissive ingress remains BLOCKED/2.


## Actual corrected P8T read-only HOLD / 0 (November 5, 2026 UTC)

The operator ran PR #414 candidate `d97c9e009d25f07902c2596b457de55b3cdcb5b0` from a new clean checkout on the **NEW disposable** Ubuntu 26.04 ARM64 `vaultwarden-oci-7-vnic`. **All 21 focused P8T tests passed.** Actual P8T returned **HOLD, exit 0**; root-private sanitized summary `/home/ubuntu/vwoci-acceptance/p8t-readonly-20261105T221801Z-4335/summary.txt`.

PASS: exact historical P8S HOLD on same kernel, local stopped host with no app/timers/containers/HTTP listeners, OCI IMDSv2 instance/VNIC identifier schema, and independent IMDS hostname correspondence. This confirms **local IMDS metadata only**, not provider NSG ingress. The first P8T `oci.imdsv2` BLOCKED attempt remains historical and is not retroactively relabeled.

PENDING: official current Cloudflare IPv4/IPv6 CIDR retrieval unavailable; authoritative OCI NSG+security-list network inventory unavailable; no separate test FQDN supplied; Cloudflare token-based zone/DNS/Worker API read unavailable; original VM/console separation needs independent verification; isolated blank app dataset and test-only backup destination not proven; public live TLS/Caddy/Worker, SMTP, backup/timers and rollback NOT RUN. The original `bw.lazymocha.com` and `bw-backup:bw-backup` remained untouched. The read-only script did not make any service/network/provider/remote changes.

These PENDING labels do **not** establish public exposure or failed Cloudflare authentication. The script originally collapses network fetch, local CLI/credential availability, and schema/authorization errors into broad PENDING labels. Before further operator turns, the same PR will add **fixed, non-sensitive phase/reason diagnostics** for Cloudflare CIDR GET, OCI CLI authentication/availability, and installed config/SOPS/Cloudflare API read stages. It will never print raw IPs, instance identifiers, tokens, HTTP bodies or decrypted secrets, and will never create an OCI credential or test hostname. The corrected source and one batched subsequent read-only run are to be reviewed through CI. **Production/live canary remains NO-GO.**


### Combined follow-up diagnostics (no new cloud permissions or live operations)

The existing PR now groups the read-only findings into **one** subsequent source/host verification. The corrected gate independently fetches official Cloudflare IPv4 and IPv6 lists; a failed family reports a fixed DNS, TLS, timeout, HTTP denial/rate-limit, malformed-response or unavailable reason, without printing endpoint bodies or connection metadata. Neither partial list nor old local accepted Cloudflare rules are silently promoted to *current external policy PASS*.

OCI CLI tool discovery is distinct from live Cloudflare range availability; a locally installed read-only CLI may inspect VNIC/subnet/NSG/security-list and IPv6 allocations **even if current Cloudflare CIDRs cannot be fetched**. Only after both official address families are confirmed can the full allowed-source comparison be rated PASS or BLOCKED; otherwise the rule comparison remains PENDING. Absent OCI CLI, credentials or provider permissions remain PENDING. This does **not** authorize installing OCI CLI or changing IAM from the appliance.

Cloudflare inspection now identifies the last completed safe stage (installed rc.12 release, module/config loading, SOPS/Age credential read, zone GET, DNS records GET, zone Worker routes GET, account Worker domains GET) plus a fixed non-sensitive failure category, without exposing token or response. Production config disagreement, actual OCI API VNIC mismatch, broad public ingress or test hostname collision are still BLOCKED. No mutation occurs.

The user supplied **no distinct test FQDN** for the accepted P8T run; that remains PENDING, not a scripted DNS creation. Console and original production-host separation require independent verification. A successful next read-only probe can still correctly return HOLD/0; neither green CI nor a HOLD report is live/public GO.
