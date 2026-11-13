# P8V layered-origin independent observations and next consent boundary

**Status: SOURCE REVIEW / READ-ONLY IMPLEMENTATION. NOT installed rc.13, NOT a canary approval.**

This addendum accompanies the P8V planning draft. It does not change any previously
accepted P8M-P8T facts or consume a one-shot acceptance marker. The acceptance host
remains `vaultwarden-oci-7-vnic` on Ubuntu 26.04 ARM64; its currently installed
release is immutable rc.12. Never use the original VM, original recovered data,
`bw.lazymocha.com` or `bw-backup:bw-backup` for a canary.

## Independent, source-pinned read-only code

- `tests/host-acceptance/production-p8v-oci-layered-readonly.py` is a GET/list
  allowlist for the **normal OCI Cloud Shell Service Network**. Its unit-tested
  rule parser treats a null destination port range as **all** ports, expands
  ranges for effective TCP22/80/443 exposures, checks unexpected public
  protocols/ports, verifies private-subnet-only SSH, checks attached NSGs and
  subnet security-list union, and compares the dedicated-list rule shape with
  the historical detached VCN default list. Public 443 is transport only.
- The scanner separately asks OCI for IPv6 assignments and explicit VCN/subnet
  IPv6 allocations. An empty byte stream or missing fields cannot prove IPv4-only
  operation. Even positive scoped proof does not establish every other
  compartment or future route; external acceptance must repeat fresh.
- `tests/host-acceptance/production-p8v-host-layered-readonly.py` validates
  clean candidate source, OS/arch, installed rc.12 versus source rc.13,
  private P8P checkpoint hashes and P8S summary, dedicated ext4 and custody
  metadata, stopped product units/timers, listeners, Docker containers,
  effective IPv4/IPv6 `DOCKER-USER` structure, bridge ownership and selected
  offline test modules. No SQLite query, SOPS decryption, live refresh, Docker
  startup, package install, restore, reboot or remote publication.
- Each gate prints **sanitized categories only**. Phase A stores a mode-0600
  JSON under `~/vwoci-acceptance/p8v-oci-*.json`; Phase B stores a mode-0600
  JSON under `/home/ubuntu/vwoci-acceptance/p8v-host-readonly-*/summary.json`.
  Do not share the previous private P8T rollback record, OCIDs, IPs, SSH keys,
  SOPS material, checkpoint hash mappings or debug logs.
- `HOLD/1` is expected until independently authorized packet-path and isolation
  proof. `BLOCKED/2` means a confirmed incompatible rule or host state was
  observed. A CLI/data/IPv6 gap is `PENDING`, never a PASS.
- Executing the scanners is allowed only after reviewing the **exact published
  PR head SHA** in the two copy-paste commands. They must clone to new local
  directories, verify clean branch+commit, and require no sudo password.

## Gate matrix (design-time; no new operator execution implied)

| Gate | Evidence | Classification |
| --- | --- | --- |
| P8T private SSH correction / isolated subnet | Operator-reported post-change authenticated private SSH and OCI GET closeout; PR #417 integrated into the primary release branch | PASS (historical only) |
| Original strict P8T Cloudflare-only OCI 443 gate | Globally sourced OCI TCP443 retained | BLOCKED/2 (historical, immutable) |
| rc.13 source candidate | PR #415 remains draft; candidate source has no installed-host proof | PENDING |
| P8V-A current OCI union / public 80 / private 22 / public 443 | Implemented offline; operator GET/list not yet run | NOT RUN |
| P8V-B stopped-host continuity / firewall structure | Implemented offline; owner-private host witness not yet run | NOT RUN |
| IPv4-only public deployment | Requires structurally complete OCI IPv6 assignment/allocation inventory; old zero-byte stdout is not proof | PENDING |
| Direct-origin NAT/FORWARD/userland-proxy packet denial | Requires separately authorized external witness | NOT RUN |
| Worker DNS/routes/custom domain / isolated test FQDN | Worker Routes GET historically returned 403; no permission broadening | HOLD |
| Blank test data and test-only backup target | Identity and destructive-scope isolation not verified | HOLD |
| TLS / login / admin / SMTP / timers / backup / reboot | No permitted canary | NOT RUN |
| Production install and cutover | No production GO | NOT RUN |

## Separate operator-consent runbook (NO APPLY COMMANDS AUTHORIZED)

These are *plans*, not commands for the read-only batches. Each mutating stage
requires a new explicit operator approval with the exact instance, test FQDN,
expected diff, rollback method, timeout and last safe checkpoint. Never bundle
these stages into the two read-only one-shots.

1. **Review-only external identity attestation.** Select a distinct test FQDN,
   verify DNS A/AAAA/CNAME, wildcard records, Cloudflare Worker Routes and
   Custom Domains on the actual zone and account; use dashboard screenshots
   or second-person witnessed readback if Worker Routes READ is 403. Do not
   enlarge the production token. Prove original production VM is isolated.
2. **Test-only storage and credentials.** Independently verify blank isolated
   dataset, unique recovery encryption context, and a separate offsite remote
   plus prefix. Forbid any write/prune/sync to `bw-backup:bw-backup`; confirm
   test identity and retention paths without listing recovered secrets.
3. **Rollback and console readiness.** Require a tested serial-console fallback,
   existing private management access, owner-private rollback artifact and
   explicit quarantine actions. Never automatically restore the default OCI
   list: it would re-open public SSH22. Document a safer network rollback
   before each provider action.
4. **Optional isolated rc.13 installation (new explicit approval).** Review
   immutable release pin/digests and supported rc.12 -> rc.13 transition;
   stage offline, validate backup and source-only tests, and request separate
   approval before installing any packages, modifying firewall or starting
   Caddy/Vaultwarden. Quarantine immediately if startup guard is not first.
5. **External packet-path canary (new explicit approval).** With blank data and
   approved FQDN only, attempt from a non-Cloudflare network to direct-origin
   IPv4:443 and Docker NAT/FORWARD/userland-proxy paths, including alternate
   Docker bind mechanisms. The expected result is DENY; any successful direct
   origin path is **BLOCKED**. Separately confirm a real proxied Cloudflare
   request succeeds. Collect packet counters and source/destination attestations
   privately without publishing infrastructure identifiers.
6. **Fail-closed transition (new explicit approval).** Exercise interrupted
   policy refresh, missing/malformed API/legacy feeds, expired LKG, Docker
   daemon restart and reboot persistence on disposable blank state with
   emergency console access. An unguarded interval or access bypass means
   immediately stop/quarantine and do not authorize progression.
7. **Functional canary (separately authorized).** Only after packet denial,
   complete test TLS, login/admin/rate limiting, Worker/CrowdSec, approved
   test SMTP, test-only encrypted backup+readback, and timer boundaries in
   separate stages. Reboot/restore/prune/production hostname cutover each
   require their own go-ahead. No rc.13 production GO on CI success alone.

## Next operator action

Review the draft feature PR(s), run GitHub CI (including Ubuntu 26.04 ARM64),
then execute only the two clean-SHA-pinned read-only commands provided in the
handoff response. Record sanitized exit labels and private paths; do not paste
raw provider or host evidence. Reconcile any PENDING/BLOCKED item in a new
reviewed branch before considering a live canary.