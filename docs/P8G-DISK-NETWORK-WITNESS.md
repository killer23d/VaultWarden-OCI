# P8G — read-only disk attachment and effective-network witness

**Actual P8G: NOT RUN.** This PR changes only acceptance scripts/tests/docs. It does not perform OCI Console provisioning, disk formatting, installation, restore, Cloudflare/DNS/Worker/SMTP/Box operations, service startup, or production cutover. The original restored `vaultwarden-oci-6-vnic` and all accepted P7–P8E evidence remain unchanged.

## Accepted starting evidence: NEW disposable host

On **2026-11-04**, the operator ran PR #394 at exact reviewed commit `6e7e84904f9044d55b26fe2118b5f2d32e3295cc` as `ubuntu` on **`vaultwarden-oci-7-vnic`**, not on the original restored VM. **118 focused production tests passed**; the real-host P8F returned **HOLD, exit 0**. Root-private accepted summary: `~/vwoci-acceptance/p8f-new-origin-20261104T204839Z-2178/summary.txt`.

P8F proved Ubuntu 26.04 ARM64 with native Python 3.14, clean pinned rc.12 source, **no installed appliance, no Docker state, no local TCP/80 or TCP/443 listener, one non-boot blank stable-by-id disk candidate**, NTP synchronization, one OCI A1 Flex instance and one VNIC with guest-name agreement. Safe-only OCI identity fingerprints: instance `0dccfd58cbbd`, VNIC `36862e16cc9f`. The **actual OCI block-volume attachment OCID and effective new-host network ingress are still PENDING**. No formatting or cloud control-plane action occurred.

The operator has separately attested access to a distinct test-only hostname with no overlapping wildcard Worker Route, the original offline encrypted recovery-kit/private Age key/passphrase, and an approved separate Box test prefix. Those statements describe **availability**, not permission to introduce secrets or start services on the new VM. They do not prove DNS-01 token authority or a fully isolated new VNIC.

## P8G safety contract

The exact pinned `tests/host-acceptance/production-p8g-storage-network-witness.py` runs only as `ubuntu` with passwordless `sudo -n` on **`vaultwarden-oci-7-vnic`**. It refuses the original VM by hostname and binds to the original accepted P8F root-private HOLD summary and its A1 Flex/VNIC identity fingerprints. It independently checks the current OS, release manifest and clean reviewed Git commit; absent appliance and Docker state, missing appliance units, and absence of any 80/443 listener. It executes only read-only product-owned root/boot ancestry checks, block-device inventory, `lsblk -n -o TYPE`, and `wipefs --noheadings --output TYPE` without erase flags. It requires **exactly one** non-boot whole disk with no mount, filesystem type, UUID, partitions or discovered signatures, and at least one real stable `/dev/disk/by-id` alias. A changed instance/VNIC identity, new listener, unexpected signature or missing original P8F proof causes BLOCKED.

OCI IMDS requests are limited to two fixed, bounded `http://169.254.169.254/opc/v2/` link-local GET endpoints; no proxy, redirect, legacy metadata, credential capture or OCI control-plane API. OCI metadata does **not** reveal authoritative subnet security lists, all NSGs, applied routing or the attached data-volume OCID.

The only outputs are in a **new** root-private `~/vwoci-acceptance/p8g-disk-network-witness-*/` directory:

- `summary.txt`: sanitized, safe to paste. It includes selected disk *alias fingerprint and capacity* without raw device paths or OCIDs, and rechecks the previous A1/VNIC identity.
- `disk-details.txt`: **PRIVATE; inspect locally only**, never paste into chat. It includes exact resolved block-device path, stable by-id aliases and bytes for a manual OCI Console comparison. It explicitly states that no attachment was approved and no formatting/install is authorized.

**Never treat `blank` as `approved to erase`**. A device can contain valuable unrecognized data or be connected to the wrong instance. Confirm the OCI attachment and its lifecycle independently in the console.

## Operator checks after the P8G command

In OCI Console, use **the NEW VM** `vaultwarden-oci-7-vnic` (not the original `-6-vnic`).

1. **Block volume ownership:** Compute → Instances → new VM → Attached Block Volumes. Identify the single intended disposable volume, exact OCI attachment/volume OCID, attachment type and its Console device path/size. On the *new VM*, privately view P8G `disk-details.txt` and compare **every detail** with the Console view, including boot-volume exclusion and whether the attachment is new/disposable and not shared/read-only. Do not share the raw OCID or disk alias in chat; use only the sanitized yes/no attestation below. If Console and guest identity disagree, STOP; never guess `/dev/sda` or use a printed /dev path as automatic formatting consent.
2. **Effective new-VNIC ingress:** Compute → Attached VNICs → the new VNIC, then review **all** attached NSGs and **all** subnet security lists, plus VCN route and public IPv4/IPv6 assignments. OCI combines NSG/security-list allow rules **additively**. An open `0.0.0.0/0` or `::/0` TCP/443 rule defeats an otherwise restricted NSG. Expected design: public TCP/80 from Internet **DENIED**; TCP/443 only **current official Cloudflare IPv4 CIDRs** (and IPv6 CIDRs only if IPv6 enabled), no other broad 443 allows; SSH limited to your administrative network. Do not modify shared/security lists attached to original or production hosts. A local closed 443 port is not an ingress-policy proof.
3. **Cloudflare ownership:** Distinct test hostname, zone permission for later DNS-01/ACME, proxied test-only record plan, and no exact/wildcard Worker Route overlap. Do not yet create a record, modify a Route, enable Worker remediation, or reuse the original `bw.lazymocha.com`.
4. **Recovery and backup:** Original recovery ZIP/private Age key/passphrase remain off the guest, and the separate Box test prefix is approved for a later, separately authorized test. Do not transfer secrets or write historical `bw-backup:bw-backup` objects.
5. **Console recovery:** Verify serial-console/console connection availability to the new VM before any future consented test involving a firewall, disk, systemd or reboot.

Official references: [OCI block volume attachment](https://docs.oracle.com/en-us/iaas/Content/Block/Tasks/attach-compute-volume-attachment.htm), [OCI Linux device paths](https://docs.oracle.com/en-us/iaas/Content/Block/Tasks/connectingtoavolume.htm), [OCI union of NSG and subnet security-list rules](https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/securityrules.htm), and [Cloudflare IP ranges](https://www.cloudflare.com/ips/). Do not hardcode CIDR lists inside acceptance tests; verify current ranges against the authoritative published list.

### Sanitized external attestation to accompany output

```text
P8G new VM = vaultwarden-oci-7-vnic
OCI block volume attachment matches PRIVATE P8G disk details: Yes / No / Unknown
Disk confirmed disposable, non-shared, safe to format LATER: Yes / No / Unknown
All new VNIC NSGs AND subnet security lists reviewed: Yes / No
New VM public IPv4: Yes / No / Unknown
New VM public IPv6: Yes / No / Unknown
Internet inbound TCP 80 effectively denied: Yes / No / Unknown
Internet inbound TCP 443 restricted to current Cloudflare CIDRs only: Yes / No / Unknown
NEW VM has functioning OCI serial-console access: Yes / No
Separate test hostname and DNS-01 permission reviewed: Yes / No
No test hostname Worker Route overlap: Yes / No / Unknown
Recovery kit/key/passphrase still OFF the VM: Yes / No
Separate Box test prefix still unused: Yes / No
```

A **HOLD/exit 0** from P8G proves only these *local* conditions and leaves all provider-side attestations PENDING. `BLOCKED/exit 2` is a hard stop; preserve evidence and do not attempt disk repair, formatting, app startup or repeat. The operator's Console answers will be evaluated separately. No external network isolation, disk ownership or data-destruction authorization may be inferred from a completed local script.

## Next stage after positive P8G and operator evidence

Prepare a separate new P8H reviewed **consent-gated install/restore** source branch. Before the *first* destructive operation, bind the exact approved by-id disk, OCI volume ownership, current boot lineage, expected release, original offline public Age recipient and unmodified test-only hostname. The install stage should require explicit disk-format wording and independently verify a backup/rollback and serial-console safety plan. A later separate live-first-start gate must prove product-owned Cloudflare ingress rules **before Docker publishes Caddy 443**, and must not affect shared DNS/Worker, production Box prefixes or real SMTP recipients without separate approvals.

P8F is accepted; P8G real-host, formatting/install, rc.12 live operation and production cutover remain **NOT RUN**.
