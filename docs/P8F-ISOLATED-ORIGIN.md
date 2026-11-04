# P8F — new disposable isolated-origin preflight

**Status: SOURCE CANDIDATE ONLY, actual new host NOT RUN.** This gate is read-only and does **not** authorize OCI provisioning, formatting, installing, restoring, DNS publication, Cloudflare Worker activation, mail, Box writes, scheduled timers, a live start, or production cutover.

## Historical acceptance and current operator attestations (2026-11-04 UTC)

- P7 cold reboot: **HOLD** because Docker's Cloudflare-only 443 rules did not survive the cold boot; the restored app stayed stopped.
- P7R product-owned after-boot firewall refresh: **REARMED** exactly once; do not replay.
- P8A on original `vaultwarden-oci-6-vnic`: **115 focused tests PASS, READ-ONLY HOLD/exit 0**; original storage/SQLite/SOPS and local CrowdSec/Cloudflare doctor gates intact. Separate review PR #392.
- P8E on the same host: corrected exact-pinned candidate `af1907a0faae118950f173300a5b9aaa4158701b`, **120 focused tests PASS, READ-ONLY HOLD/exit 0**. OCI IMDSv2 identified A1 Flex and one VNIC. The original P8E metadata BLOCKED remains a historical diagnostic; its corrected run is accepted. Separate review PR #393.
- Operator separately reviewed all original-host OCI NSGs/security lists and reported public IPv4 **yes**, IPv6 **no**, and inbound Internet TCP **80 allowed, 443 allowed**. Operator also attested that a distinct test hostname is available, no Cloudflare Worker wildcard Route overlaps it, the original off-host ZIP/private Age identity/separate passphrase are available, and a separate Box test prefix is approved. These are **declarations**, not independently verified control-plane evidence for a NEW host.

**Decision: do not start the existing restored host.** The original rc.12 config still targets shared `bw.lazymocha.com`, and its original data/acceptance evidence should not be rewritten for a live rehearsal. Existing OCI allow rules must not be treated as acceptable isolation on the fresh target. A new test-only OCI host is preferred.

## Operator-controlled disposable infrastructure plan

Use OCI Console, not this script, to prepare the independent target. Nothing here gives permission to modify existing production/common security lists or the original instance.

1. Provision a **separate** Oracle A1 Flex Ubuntu 26.04 ARM64 test VM, suggested short hostname **`vaultwarden-oci-7-vnic`**, under a clearly designated disposable instance. Ensure console/serial recovery access is functional. It must have its own boot device, VNIC, test routing and a separate, disposable data block volume. Do not attach, clone or modify the original restored volume as a shortcut.
2. Choose an isolated VCN/subnet or a subnet with **reviewed restrictive security lists**. OCI subnet security-list rules and VNIC NSGs are **additive**: placing a VNIC in a restrictive NSG cannot nullify a permissive subnet rule. Verify every effective IPv4/IPv6 ingress permission and route on the **new** VNIC, not merely an NSG's name. For the test origin: no world-open TCP/80; allow TCP/443 **only from Cloudflare's current published origin-facing CIDRs**, for IPv4 and IPv6 families actually enabled. Restrict SSH to the designated administrator source; ensure needed egress is explicitly authorized. Confirm there is no unexpected public IPv6 route or listener.
3. Keep the proposed **test-only hostname** separate from `bw.lazymocha.com`. Do **not** publish or modify test DNS records, create ACME DNS-01 TXT records, reuse a shared Cloudflare token, or activate a Worker Route yet. Verify Worker exact/wildcard Route overlap independently. Verify any later DNS API token is scoped to the test zone/record.
4. Attach a separately approved **blank** OCI data volume to the new VM. Do not format it. Identify the exact OCI attachment/volume OCID in Console and match it to the guest stable `/dev/disk/by-id` device, capacity and root/boot ancestry after the read-only P8F result. A volume's presence is not proof it may be erased.
5. Keep the **original offline recovery identity and encrypted kit off the guest**. The existing offsite backup destination `bw-backup:bw-backup` and historical .vwrec objects are not an experimental write target. The separately approved Box test prefix must later be recorded precisely before any test backup publication.

References: [Oracle instance metadata](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/gettingmetadata.htm), [Oracle security lists and NSGs](https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/securityrules.htm), [Cloudflare origin IP addresses](https://developers.cloudflare.com/fundamentals/concepts/cloudflare-ip-addresses/). **Cloudflare CIDR sets change**: compare to the current authoritative list when the test ingress is created, not to a hard-coded example or historical P7R rules.

## New-host P8F one-shot: read-only

Only on the independently provisioned **NEW** VM, log in as `ubuntu` with passwordless `sudo -n`. The candidate PR operator message supplies a shell block that clones **one exact PR HEAD**, runs `test_production_*.py` tests and invokes:

`sudo -n python3 -B -E tests/host-acceptance/production-p8f-isolated-origin-preflight.py --expected-commit <reviewed-sha> --expected-host vaultwarden-oci-7-vnic`

The script refuses any original/historical acceptance host (`vaultwarden-oci-6-vnic` included), an unexpected short hostname, wrong source branch/SHA, unclean checkout, wrong OS/architecture/Python, installed appliance paths/systemd units, preexisting Docker data, or a TCP 80/443 listener. It requires a native rc.12 manifest and inventories **only non-boot** block candidates using the product's read-only root-ancestry logic, `wipefs` listing mode, and by-id aliases. It never selects or prepares a disk. It queries only OCI **IMDSv2** instance and VNIC link-local GETs with `Authorization: Bearer Oracle`; no proxies, redirect, IMDSv1, cloud control-plane credentials or remote API writes. It prints only metadata fingerprints/counts, never raw OCIDs, IPs, SSH metadata, disk aliases or credentials.

Evidence: a new `~/vwoci-acceptance/p8f-new-origin-*/summary.txt`, root private, mode 0600. Paste **only sanitized summary plus `P8F_EXIT`**. Original P7/P8A/P8E evidence remains on the old VM.

| Result | Meaning |
|---|---|
| `HOLD`, exit 0 | Read-only source/host safety completed; missing disk, OCI metadata or external evidence remains PENDING. **No install/start authorization.** |
| `BLOCKED`, exit 2 | Wrong/already installed host; bad source/OS identity; invalid OCI metadata; live listener; unsafe disk inventory or other integrity regression. Investigate, preserve existing resources; no automatic repair. |
| `PENDING` on OCI NSGs/DNS | Expected. Guest metadata and local listeners cannot prove effective provider rules, public reachability, test DNS authority or Worker Route configuration. |

## After the operator returns P8F results

1. Independently confirm the **new VNIC and subnet**, all NSGs and security lists, IPv4/IPv6 routes, Internet TCP 80 **closed**, TCP 443 **Cloudflare-only**; verify a direct-origin non-Cloudflare request cannot reach port 443 after a later *separately approved* server start. Do not use a same-machine probe as proof of external source filtering.
2. Reconcile exact disposable data-volume OCID, by-id alias and size against guest inventory; independently confirm that it contains no valuable data. Choose a product-supported install/restore path (original offline Age recipient), then create a separate consent-gated P8G source branch for the **first** data-volume formatting and appliance setup.
3. Before any P8H *live* `vwctl start`, independently confirm the new test hostname's Cloudflare DNS/Worker route scope, container-origin firewall refresh-before-publish contract, certificate DNS-01 token/zone permissions, and stop/rollback plan. **Do not run Docker Compose directly** or assume the original host's P7R marker permits access.
4. Later gates: rc.12 live HTTPS/Caddy/admin/authentication, fresh Worker invocation-specific Route Fail Open, separately authorized SMTP, isolated test-prefix Box backup/readback, natural timers/reboot persistence, full rollback and production GO/NO-GO. No production DNS or shared Box prefix may be modified by a test.

**No actual fresh host, live rc.12, isolation-proof test or production cutover has been executed by this source PR.**
