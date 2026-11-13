# P8V first independent read-only execution and follow-up

Status: **HOLD**, not a live-canary or production authorization. Historical
P8T strict OCI Cloudflare-source TCP443 **BLOCKED/2** remains unchanged.
No accepted P8M-P8S recovery markers or previously performed SSH policy edits
may be replayed. The disposable appliance is still immutable rc.12, not rc.13.

## Operator observations on 2026-11-13 (sanitized)

**OCI Cloud Shell**, first P8V-A source pin
`9420aa9d09ff3e7580e7c7b4e5c4cb0524f4e0ad`, returned `HOLD/1`,
`PENDING instance-identity-mismatch` and *did not reach* the additive ingress
union audit. The prior source treated the mutable OCI instance display name as
part of the same check as provider-returned instance ID; neither reason could
be distinguished by its output. This is **not** proof of either a wrong VM
or a correct VM. The original private report remains only in Cloud Shell at
`~/vwoci-acceptance/p8v-oci-20261113T231117Z-927.json`.

**ARM64 stopped host**, same source pin, returned `HOLD/1`, with PASS for
OS/architecture, immutable installed rc.12 / source-only rc.13 distinction,
protected historical recovery hashes, dedicated ext4 and encrypted custody,
and **46 bounded source tests**. The aggregate stopped-services/listeners,
dual-stack filter structure, and Docker bridge owner checks returned PENDING
without an exposed root cause. No service, listener, Docker bridge, firewall
or external packet-path PASS can be inferred from this PENDING. Its report is
`/home/ubuntu/vwoci-acceptance/p8v-host-readonly-20261113T231802Z-40807/summary.json`.
Neither previous report is rewritten.

The operator used the public Cloud Shell network to fetch GitHub; GitHub access
timed out on the OCI Service Network. Private SSH was performed only through
Cloud Shell Private Network Access using the private VM address. Future provider
reads may use the normal Service Network after an already pinned checkout
exists; a provider API failure must be reported as PENDING independently of
GitHub transport. Do not change network policies to work around these reads.

## Correction scope

The follow-up code checks provider-returned instance ID separately from its
display name and binds the selected instance and subnet to the owner-private,
mode-0600 P8T evidence file. It does **not** compare old security-list
attachments, since the accepted P8T SSH remediation deliberately changed them.
The checked-out branch must be clean and pinned to the reviewed PR head.
A mismatched selected instance/subnet or missing protected evidence remains
PENDING and prevents acceptance. No raw OCIDs/IPs are printed.

Once the target is verified, the auditor examines every attached VNIC,
subnet security-list and NSG ingress union, explicitly categorizing any
public HTTP80, public SSH22, unexpected ports, and public HTTPS443 transport.
Unavailable IPv6, private-IP or other-subnet supplementary reads remain
PENDING without silently suppressing the independently fetched ingress union.
External packet denial is still NOT RUN.

The ARM64 stopped-host batch now separates unit/timer states, template-unit
readback, TCP listeners, container inventory, bridge presence, and both-family
iptables chain checks. It reports finite source-authored reason codes instead
of generic `unverified`. A Docker bridge not instantiated on the stopped
host is PENDING, not proof of an unsafe active bridge and not a PASS.
An expired 72-hour Cloudflare cache must never authorize service startup;
a historical structural comparison against a stale cache remains PENDING.

## Evidence and gate matrix after first run

| Gate | Status |
| --- | --- |
| P8T accepted private-SSH dedicated-list closeout | PASS (historical) |
| Original strict P8T OCI public 443 result | BLOCKED/2 (historical) |
| P8V-A first OCI read-only attempt | HOLD/1: provider union NOT RUN |
| P8V-B installed release identity/recovery/storage | PASS (read-only) |
| P8V-B 46 bounded source tests | PASS (source only) |
| P8V-B unit/listener/filter/bridge details | PENDING |
| Follow-up corrected OCI/host source, independent re-run | NOT RUN |
| External packet path and Docker NAT/userland proxy witness | NOT RUN |
| Test FQDN, Worker routes, DNS, blank data and offsite isolation | HOLD |
| rc.13 installation/reboot/live canary/production | NOT RUN |

**Next action:** review new draft PR CI including native Ubuntu 26.04 ARM64,
then run only the two new source-pinned READ-ONLY batches and return the
sanitized rows plus exit statuses. Do not paste P8T rollback mappings, original
recovered data, passwords or private evidence JSON. Any firewall refresh,
network policy edit, DNS/Worker change, app start, backup/reboot or rollback
requires a *new explicit operator authorization* and its separate runbook.
