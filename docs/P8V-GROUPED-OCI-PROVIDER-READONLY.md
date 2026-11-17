# P8V grouped OCI provider read-only acceptance (follow-up)

**No new operator result is implied by this document.** This is a separately
source-pinned, owner-private, GET-only evidence batch. It does not replace the
immutable P8T private SSH closeout or clear the **historical P8T strict
OCI-source TCP443 BLOCKED/2**. The intended P8V layering permits public
transport on TCP443 but requires separate effective host Cloudflare-only
filter and external packet-path witness. The VM still has installed rc.12.

## Current evidence (2026-11-13)

- P8V-A corrected main audit source `4bb4363b824ff7ae6ef601b0909d6ee6e0040c2c`
  ran in the authenticated OCI Service Network: HOLD/1, 7 PASS, 6 PENDING,
  0 BLOCKED. Protected instance ID, dedicated security list separation,
  private subnet SSH22, ICMP, other-VNIC and same-VCN subnet isolation passed.
  Globally sourced TCP443 was treated as *expected transport*, not host or
  production proof. The provider-friendly-name mismatch is a non-authoritative
  label issue, not proof of a different instance.
  Protected report:
  `~/vwoci-acceptance/p8v-oci-20261113T233148Z-1109.json`.
- The independent follow-up IPv6 probe returned
  `VNIC_IPV6: EMPTY_OR_OVERSIZED_RESPONSE` and
  `SUBNET_IPV6: EMPTY_OR_OVERSIZED_RESPONSE`. Its separate
  subnet/VCN `ipv6-cidr-blocks` checks both said
  `PRESENT_OR_UNVERIFIED`. The empty CLI stdout cannot establish either
  an empty IPv6 assignment set or actual IPv6 exposure. IPv6 remains PENDING.
- P8V-B on the stopped Ubuntu 26.04 ARM64 host reported HOLD/1,
  with PASS for identity, immutable rc.12/source rc.13 distinction, recovered
  material continuity, dedicated ext4/custody, dormant unit/timers, closed
  TCP listeners, no Docker containers, and 52 bounded source tests.
  The installed dual-stack firewall matched an **expired** last-known-good
  policy (PENDING), the Docker bridge is uninstantiated while stopped
  (PENDING), and no live canary, packet path, firewall refresh or backup
  mutation was performed. Root-private report:
  `/home/ubuntu/vwoci-acceptance/p8v-host-readonly-20261113T232846Z-40983/summary.json`.

## Batched evidence plan

The grouped OCI tool runs the previously reviewed *complete effective ingress
union* on all attached VNICs, security lists and NSGs, then independently reads:

1. Exact owner-private P8T target instance and its original subnet identities
   (not old security-list attachments, which accepted P8T deliberately changed).
2. Current instance attachments and public IPv4 field, absence/presence of
   additive VNIC NSGs and VNIC source/destination check.
3. VNIC GET `ipv6-addresses`, subnet GET `ipv6-cidr-blocks` and legacy
   singular field, and VCN GET `ipv6-cidr-blocks`, private prefixes and
   legacy IPv6 fields.
4. ListIpv6s with both VNIC and subnet filters, and separately authenticated
   **GET-only** OCI `raw-request` calls for both filters. Raw-response
   pagination, empty stdout, missing/null fields, non-200 status or provider
   errors never imply an empty IPv6 inventory.
5. VNIC-specific and subnet route-table GETs, including any IPv6 destinations.
   A route table with incomplete or unrecognized destination types cannot
   assert absence of IPv6 routes.
6. The public SSH22/HTTP80/unexpected-port denial categories and expected
   public 443 transport-only categories remain owned by the reviewed P8V
   ingress classifier.

The audit outputs **only source-owned status/reason codes**; no raw API body,
personal/network IDs or addresses, host credentials, SSH keys or tokens.
Private mode-0600 JSON is stored in
`~/vwoci-acceptance/p8v-provider-batch-<UTC>-<PID>.json`. Copy only the
sanitized terminal result and final exit code into review.

The tool is read-only: no OCI create/update/delete, no network access from
inside the appliance, no firewall refresh, no Docker startup, no package
install, no SSH policy change, no DNS/Worker change and no backup/reboot.
Only harmless checkout/evidence-file writes are permitted.

## Transport and expected outcome

For GitHub cloning use OCI Cloud Shell **Public Network**, where it has
worked. Use the already pinned checkout on the normal **Service Network**
for OCI authenticated GETs, if preferred; Cloud Shell Private Network Access
is only for approved private SSH. Do not re-clone on Service Network if GitHub
egress is unavailable. No network/IAM changes should be made to unblock an
audit. A `HOLD/1` result is expected because no external packet-path
canary has been authorized. `BLOCKED/2` requires stopping and independent
review; never relabel earlier strict P8T as PASS.

## Gate matrix (evidence classification)

| Gate | Status |
| --- | --- |
| Historical P8T private SSH remediation | PASS (historical only) |
| Historical P8T strict global-TCP443 OCI source policy | BLOCKED/2 (preserved) |
| P8V-A corrected OCI additive union | HOLD/1; reviewed controls PASS, IPv6 and packet path PENDING |
| P8V-B stopped-host identity/data/storage/units/listeners/tests | PASS for observed checks |
| P8V-B expired Cloudflare LKG / stopped Docker bridge | PENDING, no mutation |
| Grouped OCI provider evidence new source | NOT RUN until operator one-shot |
| Independent external origin packet-path denial including NAT/proxy | NOT RUN |
| Distinct DNS/Worker FQDN and isolated blank backup destination | HOLD |
| rc.13 live install, startup, backup, timers, SMTP, reboot, production | NOT RUN |

**Next operator action:** review the new draft PR, confirm exact full source
commit, run the single grouped read-only OCI batch, and share only its
sanitized status rows and `P8V_OCI_BATCH_EXIT`. Host P8V-B does not need to
be repeated merely to address OCI IPv6 inventory uncertainty. Mutating
canary stages need a separate consent request and explicit rollback/quarantine
runbook.

## Actual P8V-A provider batch on 2026-11-17 (sanitized; source-pinned)

The operator ran the reviewed grouped source
`358d64373bf79d335b575ec5308ad3821a14df60` as `freedom`
on the OCI Service Network. **HOLD/1, 16 PASS, 12 PENDING,
0 BLOCKED, 1 NOT RUN.** Owner-private report, retained unmodified:
`/home/freedom/vwoci-acceptance/p8v-provider-batch-20261117T212206Z-440.json`.
Native Ubuntu 26.04 ARM64 and all nine GitHub CI jobs on this precise source
passed. Neither CI nor read-only OCI transport is a production approval.

**Verified in the scoped provider inventory:** protected instance ID,
dedicated security-list shape relative to detached default, single private
SSH22 rule, path-MTU/private ICMP, sole subnet VNIC and no attached NSGs,
public IPv4 assignment, source/destination check enabled, no sharing of the
dedicated list within the scanned VCN, additive ingress union examined with
no classified unexpected public exposed ports. OCI public TCP443 remains
**PENDING expected transport only**, never Cloudflare-only proof.

**Meaningful independent IPv6 outcome:** normal OCI CLI VNIC/subnet
`network ipv6 list` returned empty stdout and therefore **PENDING**.
The independent authenticated, signed GET `ListIpv6s` queries for
both VNIC and subnet each returned an explicit empty JSON list and therefore
**PASS for zero assigned IPv6 objects in the scoped inventory at observation
time**. The inspected route table contained no IPv6 destinations.
VNIC Get's `ipv6-addresses`, subnet/VCN IPv6 prefix fields were
null/missing, so *configured prefix absence* remains **PENDING**.
The independent provider proof applies only to this VM/subnet at the
observation time. It does not prove tenancy-wide IPv6 absence, external
packet-path denial, or future state.

**Remaining categorized PENDING:** mutable OCI friendly-name drift (the
provider identity ID matches); broader compartments not enumerated; IPv6
null/missing API fields and blank CLI output; intentional public 443
transport; external packet path and effective runtime host defense not tested.
Do not reset, rename, weaken rules, change providers or repeat narrow
IPv6 requests merely to obtain a different status.

The accepted prior P8V-B ARM64 report remains
`/home/ubuntu/vwoci-acceptance/p8v-host-readonly-20261113T232846Z-40983/summary.json`:
eight stopped-host checks PASS, 52 bounded source tests PASS; expired
72-hour Cloudflare last-known-good cache, absent dormant Docker bridge
and unavailable external packet-path proof remain PENDING. Do not
refresh host policy, start services or instantiate the bridge during
read-only acceptance.

### Next grouped read-only readiness gate (planned, NOT RUN)

Combine independent review of the following in **one** stage rather than
another isolated network probe:

- Select an explicitly approved distinct test FQDN, verify no wildcard DNS,
  conflicting Cloudflare Worker routes/custom domains or existing production
  mapping. Cloudflare Worker Routes API historically returned HTTP403; use
  read-only Dashboard/manual signed attestation without widening the token.
- Independently prove blank isolated test-only database/dataset and backup
  destination and fail closed on any match with the original remote
  `bw-backup:bw-backup`, recovered SQLite or off-host recovery kit.
- Verify source/installed-release difference, no original-VM linkage, console
  fallback, preserved private SSH22 and evidence/rollback/quarantine capacity.
  Do not publish Caddy/Vaultwarden and do not contact the original VM.
- Produce source-pinned sanitized report and a separate operator **GO/NO-GO
  request**. An outcome of HOLD at this stage authorizes nothing.

### Separately authorized live test groups (ALL NOT RUN)

1. **Isolated rc.13 deployment and firewall fail-closed readiness** only
   after the test-only data/identity preflight and an explicit approval.
2. **External packet-path witness** from non-Cloudflare and Cloudflare
   sources across original destination TCP443, Docker NAT/forwarding and
   userland proxy, with immediate fail-closed stop/quarantine on bypass.
3. **Interrupted/expired policy transitions** (cache older than 72 hours,
   invalid API/legacy fallback, Docker restart and unexpected policy
   publication); rollback must preserve private SSH and block origin leaks.
4. **Functional TLS/login/admin/SMTP, encrypted backup, timers and reboot**
   as individually approved live gates, never as part of the previous
   read-only step. The original remote and hostname are never test targets.

Historical strict P8T global TCP443 source-policy **BLOCKED/2** remains
immutable. Product installation, production cutover and production GO are
still **NOT RUN**.

## Integration source status (2026-11-17)

The accepted P8V-A grouped report and one-shot pinned to the original
feature SHA remain **historical evidence**. If the reviewed feature
stack is consolidated into the `v2` development branch, future gate runs must use the exact
current `v2` SHA and clean branch; do not attempt to clone the old
feature branch after manual deletion. Source pin validation permits
either the historical feature branch or `v2`, with SHA verified.

The operator subsequently reported Cloudflare DNS wildcard, Worker
Route and Custom Domain overlaps for the proposed canary FQDN.
See [P8V canary isolation HOLD](P8V-CANARY-ISOLATION-HOLD-20261117.md).
This does not change P8V-A's provider transport evidence; test hostname
isolation remains blocked and production remains HOLD.
