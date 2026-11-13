# P8T — isolated OCI private SSH remediation closeout

**Recorded 2026-11-13. Operator evidence; not a product release, public canary, or production GO.**
Selected disposable host: `vaultwarden-oci-7-vnic`, Ubuntu 26.04 ARM64; OCI region `us-sanjose-1`. This document appends a later, authorized, **mutating OCI security-list correction** to the older, immutable P8T read-only audit. Do **not** rerun historical recovery gates P8M–P8S or change the original restored VM, real database, recovery kits, DNS, Workers, or Box remote.

## Historical contract vs accepted correction

The original P8T provider contract fails when globally reachable OCI TCP443 is not restricted to official Cloudflare CIDRs. Its `BLOCKED/2` result is **immutable**, even though a separately proposed layered-origin architecture deliberately allows OCI TCP443 as transport and enforces Cloudflare-only reachability through the application's fail-closed **host** `DOCKER-USER` policy. The operator does not approve manually maintained Cloudflare CIDRs in OCI. P8V/rc.13 must prove host-origin packet filtering before any public canary. This SSH remediation does **not** validate the layered origin model.

The final historical P8T host closeout ran from the exact P8T source, preserving P8S continuity and a stopped host: 45 P8T + 22 P8S synthetic regressions PASS, both IPv4/IPv6 installed host firewall structures PASS (cached 15 IPv4 and 7 IPv6 Cloudflare ranges at that time), zero local TCP80/443 listeners, **host HOLD/0**. The authoritative independent OCI audit subsequently observed public TCP80=0, public TCP443=1, globally accessible SSH22=1, zero attached NSGs, and one attached **shared VCN default** security list. This global SSH finding required a separate narrowly approved correction, not a P8T-policy relabel.

## Authorized disposable-subnet change and post-change proof

Using OCI Cloud Shell Private Network Access in the **selected VM's subnet** and existing nondefault SSH identity `~/vaultwarden-oci-7.key` (private; never commit or paste), operator verified exact OCI target, private IPv4 route, previously trusted public SSH host key, authenticated `ubuntu` login, Linux hostname, and remote `SSH_CONNECTION` source/destination. Private SSH pre-change proof **PASS/0**.

Using the **normal OCI Service Network** (OCI API available), the reviewed one-time P8T guarded operator script required typed approval `APPLY-P8T-PRIVATE-SSH`. Its production provider preflight required exactly one selected VM VNIC, isolated subnet consumer, existing one global SSH22 and one global HTTPS443, no public HTTP80/unapproved protocol/public IPv6, no attached NSG, and a fresh 30-minute authenticated private SSH proof. A valid root-compartment identifier uses `ocid1.tenancy...`; OCI may represent an unrestricted TCP source-port range as `null`, which is not a restrictive port range. Earlier validation failures for those cases were corrected and independently tested; neither earlier attempt reached any OCI mutation.

The operator approved the change. OCI reported **`P8T OCI SSH: APPLIED`**: a *new dedicated security list* containing the original four ingress and one egress rules was attached as the sole list for the disposable subnet, changing only the **source of TCP22** from `0.0.0.0/0` to the selected private subnet CIDR and retaining global TCP443 and path-MTU ICMP. The original VCN default list was **left unchanged and detached from this subnet**; no NSG was added. Owner-only rollback evidence is stored on the operator's Cloud Shell as `~/vwoci-acceptance/p8t-ssh-private-rollback.json`, mode 0600; never publish its contents.

After the OCI update, in Cloud Shell **Private Network Access**, the operator obtained **`P8T SSH: PASS/0 - authenticated private SSH AFTER subnet change`**, with pinned server host key, correct `ubuntu` identity, private route and remote peer. In normal OCI Service Network a **separate GET-only provider readback** returned **`P8T OCI READBACK: PASS/0 - independent provider verification`**: sole dedicated list attachment, shared default list still identified, no NSG, SSH22 restricted to the VM private subnet, public TCP80 absent and TCP443 retained, same egress/ICMP, and authenticated private SSH evidence recorded. This provider readback is authoritative for *configured OCI allow rules*, not a public external packet-path denial test.

## P8T private SSH closeout matrix

| Invariant | Evidence / outcome |
|---|---|
| Disposable VM and target identity | Single selected VNIC/subnet, unchanged source pins — PASS |
| Old shared VCN default security list | Left intact, detached only from selected subnet — PASS |
| New dedicated subnet list | Only list attached, zero NSGs — PASS |
| Public TCP22 / private management TCP22 | Global source removed from attached rules; approved private subnet source only — PASS |
| Private SSH login after rule change | Existing key, trusted host, correct user, correct route and peer — PASS |
| Public TCP80 / TCP443 | No HTTP80 allow; public HTTPS443 retained intentionally — PASS for OCI transport configuration only |
| Other ingress / original egress / path-MTU ICMP | No other rule changes in independent GET comparison — PASS |
| Standalone independently authored rule comparison | Synthetic tests in `tests/test_production_p8t_private_ssh_policy.py` — source regression, not a new live provider PASS |
| Original strict OCI-only Cloudflare 443 contract | **Historical BLOCKED/2**, deliberately unchanged |
| Installed rc.13, independent direct-origin packet denial | NOT RUN — P8V gate |
| OCI public IPv6 absence | PENDING independent provider assignment evidence; do not infer from empty CLI output |
| Test FQDN and Worker routes/custom domains | PENDING; existing Workers routes GET returned HTTP403 |
| Separate blank test dataset/remote, test-only SMTP, live canary | HOLD / NOT RUN |
| Production deployment / hostname / DNS cutover | **NO-GO** |

## Recoverability and operator boundary

The owner-only rollback record permits a separately **authorized** conditional revert to the *original VCN default security-list association*. That revert **reopens globally sourced SSH22** under the original policy, so it is an emergency recovery measure only; never run it routinely after PASS. Retain existing off-host key custody, Cloud Shell Private Network definition, and OCI console recovery path. A new Cloud Shell session may require selecting the private-network definition again; private mode previously lacked OCI API egress, so use normal OCI Service Network for independent provider GETs and private mode for SSH. Do **not** broaden the shared default list or introduce static Cloudflare IP maintenance in OCI.

The live one-time, operator-local guarded apply script remains deployment-specific and is **not** installed on the appliance or made a general product mutation command. Repository source `tests/host-acceptance/production-p8t-private-ssh-policy.py` is a **pure offline comparison** of separately obtained OCI data, not permission to rerun the change or a replacement for independent provider GET and SSH authentication.

## Source and P8V handoff

- Original strict P8T and provider audits: merged PR [#414](https://github.com/killer23d/VaultWarden-OCI/pull/414) and [historical impact discussion](P8T-SECURITY-LIST-IMPACT.md).
- Operator acceptance comment in [PR #414](https://github.com/killer23d/VaultWarden-OCI/pull/414#issuecomment-6866617953): exact live P8T SSH apply, private SSH functional PASS, independent OCI GET-only readback PASS. Source of the results is the operator's sanitized outputs; no private OCI/SSH identifiers are checked into git.
- Draft rc.13 implementation [PR #415](https://github.com/killer23d/VaultWarden-OCI/pull/415) and stacked independent P8V acceptance [PR #416](https://github.com/killer23d/VaultWarden-OCI/pull/416) were not merged, deployed, or approved for canary by this closeout.

**Next acceptance task:** P8V independent OCI layered transport and source-pinned stopped-host proof, followed by explicit separate approval for any isolated rc.13 install, live packet-path canary, test hostname/data/remote, SMTP, timer, reboot, or rollback. Preserve historical outcomes and do not replay passed P8T private-SSH or destructive P8M–P8S gates.
