# P8V: layered-origin security and production-acceptance work plan

**Status: planning only. NOT a passed gate or authorization to alter provider or VM state.**
**Target:** eventually the primary release branch; this PR is intentionally stacked on draft rc.13
`security/rc13-cloudflare-origin-layered` (PR #415) until rc.13 code is reviewed.
**Base candidate pin:** `816b644f651d154edb705f1995f53522a917c51f`.
**Installed on disposable ARM64 VM:** immutable `0.1.0-rc.12`, *not* rc.13.
**Appliance:** `vaultwarden-oci-7-vnic`, Ubuntu 26.04 ARM64;
OCI Cloud Shell region `us-sanjose-1`, user `freedom`.

## Authority, source integrity and scope

This document is a kickoff for Codex to implement read-only, source-pinned independent
acceptance gates. Do **not** execute OCI writes, app startup, firewall refresh,
`systemctl` mutations, Docker restart, reboot, DNS/Worker changes, rclone writes/prune,
SMTP, recovered database modification, production cutover, or rollback without
distinct explicit operator authorization. `vwctl edge refresh` is a MUTATING
operation (firewall and cache); source-only mocks are read-only, real invocation is not.

Never replay P8M–P8S destructive recovery gates, consume one-shot markers, publish
recovered data/credentials, use historical `bw.lazymocha.com` for a canary, or access
original offsite remote `bw-backup:bw-backup` for canary writes.
Preserve original VM, serial recovery and encrypted recovery kit custody.
Store only sanitized PASS/PENDING/BLOCKED/HOLD evidence in public-facing reports;
detailed private evidence must be root/owner-only and mode 0600, no raw OCIDs,
network IPs, credentials, tokens, SQLite, or decoded SOPS/Age contents in stdout.

The old P8T/P8T-L strict OCI-cloudflare-source gate is HISTORICAL and IMMUTABLE.
It declares public OCI TCP443 BLOCKED. The proposed P8V layered architecture
**intentionally permits TCP443 at OCI** when independent host enforcement is
current, verified and cannot be bypassed; do not reuse P8T's strict verdict
or weaken its code. **Public OCI TCP80 must be absent.**
The operator does not maintain Cloudflare IP ranges in OCI.
OCI external deployment is intended IPv4-only, but not proved purely by
zero-byte OCI CLI IPv6-list output. Preserve existing Docker internal IPv6
and both-family iptables safeguards; don't remove the latter to clear a gate.

## Latest operator evidence, with time-dependent findings

- PR #414 P8T read-only diagnostics were merged into the primary release branch at
  `c891999563d37c735331d8f781edbf5f0c1d0fa0`.
- Draft PR #415 versioned rc.13 API fallback at
  `816b644f651d154edb705f1995f53522a917c51f` has
  **9/9 passing pull-request CI jobs** (run `42301309410`).
  The earlier push CI was cancelled, not a product failure.
- Real P8U2 source-only tests on ARM64: **110/110 pass**, official rc.13
  Cloudflare API GET gave 15 IPv4 and 7 IPv6 ranges; installed rc.12
  firewall had both family-specific exact allowlists, final DROP, correct
  ordering and no TCP80/443 listeners. This is stopped-host STRUCTURAL proof,
  *not* an external packet denial proof and *not* installed rc.13 acceptance.
- Historical P8T-L OCI read-only provider check saw VCN default security list
  permit IPv4 TCP80 and TCP443, BLOCKED. P8U3 separately observed one public
  TCP80 and one public TCP443 rule; no overlap with SSH or each other.
- **Most recent P8U4-R (2026-11-06 ~22:32 UTC)** complete scoped OCI provider
  inventory showed only `security-list.ipv4.global-tcp443`, NOT TCP80;
  exact rule check `public80=0`, `public443=1`, `unknown=0`.
  Default VCN list identified, no other subnets in scanned compartments and
  no other VNIC in selected subnet; other compartments unverified.
- P8U5-R OCI Audit for Nov 6, 22:00–22:46 UTC showed one network-update event
  matching selected resources. The specific modified rule has not been proven;
  do not attribute a TCP80 removal without an event-specific read-only review.
  IPv6 CLI vnic/subnet inventory returned `exit0-zero-byte-stdout`; VNIC and
  subnet metadata did not expose IPv6 fields. This is PENDING, **not** proof
  of an assigned or unassigned public IPv6 address.
- Cloudflare Worker Routes API previously HTTP403; missing Worker Routes Read,
  no permission escalation, no independent test hostname supplied.
- Current rc.12 recovered data remains intact and intentionally dormant.
  No public canary has run under rc.13.

## Phase A — Current independent OCI transport preflight (READ-ONLY)

Build a new testable module and a Cloud Shell one-shot acceptance script
in `tests/host-acceptance` with an independent **P8V** contract:
1. Strictly source-pin this new branch/commit without importing the old
   P8T helper's hard-coded `BRANCH` assumption as a gate.
   Do not require `oci` CLI on the Ubuntu appliance.
2. Read selected disposable instance, its exact VNICs, subnet(s), attached
   security lists and all NSGs, their additive ingress union, public IPv4
   and public IPv6 assignments/routes when independently available.
   Classify TCP80 and TCP443 separately with source, protocol and port ranges;
   do not misclassify a public subset or combined-range rule.
3. Public TCP80 on any effective OCI attachment = BLOCKED. Public TCP443
   transport is **EXPECTED**, neither a PASS nor BLOCKED until the host-origin
   enforcement gate independently passes. Unknown effective rules = PENDING.
   Flag other unexpected public application ports or unapproved SSH access.
4. Preserve approved SSH + egress, check list/subnet sharing and VCN default
   without assuming other compartments were exhaustively queried.
5. Distinguish absent public IPv6 proof from an empty stdout string.
   For intentional external IPv4-only design, require independent non-IPv6
   association/assignment/routing evidence; missing evidence is PENDING,
   not a requirement to enable or rearchitect IPv6.
6. Build a review-only alternate dedicated security list / subnet association
   and rollback proposal **only if current effective OCI TCP80 is genuinely
   present**. Never edit a shared default list or apply silently.
7. Preserve historical results; time-stamp the new scoped observations
   and categorize provider GET/auth/schema/timeout failures safely.

## Phase B — One grouped ARM64 stopped-host candidate witness (READ-ONLY)

Develop a single new source-pinned acceptance batch that reads protected
recovery/storage/host state **without replaying destructive recovery gates**:
- Verify correct OS/architecture, installed rc.12 release pointer and
  no installed rc.13 yet (predeployment stage). Independently test rc.13
  source in an isolated checkout; do not label it installed.
- Compare immutable previously accepted P8M–P8S markers, recovered encrypted
  archive/SQLite metadata, dedicated ext4 device mapping, root-fallback denial,
  SOPS/Age configuration and off-host kit custody **without printing secrets**.
  Unknown evidence = PENDING rather than invented PASS.
- Verify Docker/systemd service ownership, existing stopped-state and
  zero listeners; inspect active timers without enabling them.
- On rc.13 candidate, exercise official JSON API dual-stack parser, bounded
  legacy fallback, 72-hour LKG expiration, fail-closed guards, startup
  ordering and Docker/Caddy publishing using mocks/offline and CI fixtures.
- Independently verify installed host `DOCKER-USER` current IPv4 and IPv6
  policy, ordering, exact allowed CIDRs, deny fallback and active bridge
  configuration without mutating firewall. No host packet-path PASS from
  structural data alone.
- Keep a private 0600 report. Group related unittest patterns in the same
  run; print only summary counts and sanitized categories. If any critical
  item unknown, final outcome HOLD.
- Do not run `edge.refresh_origin_policy()`, `vwctl start`,
  `docker compose up`, reboot, backup, SMTP or Worker mutation in this gate.

## Phase C — External independent packet-path proof (DESIGN; LIVE REQUIRES CONSENT)

Create an independently reviewed layered-origin acceptance witness that
cross-checks current OCI port policy with currently installed/applied host
filtering. A stopped Caddy, zero listeners or OCI security-list-only PASS
is **NOT** proof of direct-origin rejection. Design an isolated test service
with blank data; require explicit separate canary consent to activate.
Verify non-Cloudflare public IPv4 requests cannot access the application
through origin IP, Docker NAT and userland-proxy/bypass paths; Cloudflare
can reach the approved test FQDN. Validate stale/missing firewall, rule
replacement, daemon restart, reboot window and rollback fail-closed.
Do not enable service just to obtain a probe result in the read-only phase.
If IPv6 is provably not public, document external IPv4-only gate while
retaining internal Docker IPv6 controls.

## Phase D — Strictly separate test identity and datasets (READ-ONLY PROOF FIRST)

Require a distinct operator-approved test FQDN different from
`bw.lazymocha.com`. Inventory actual Cloudflare zone/DNS wildcard,
Worker route and custom-domain associations; absent Worker route READ
permission must remain PENDING with an independent dashboard proof path.
Do not expand existing operational token. Prove blank isolated dataset,
separate test-only remote/prefix that cannot overwrite/prune
`bw-backup:bw-backup`, original production VM identity separation,
console recovery path, private recovery kit custody and rollback capacity.

## Phase E — Integrated live canary (PLAN ONLY until explicit approval)

Single staged preflight → isolated startup → DNS-01/TLS → proxied
test-hostname connectivity → direct-origin denial → test-only client
login/admin/rate-limit → CrowdSec/Worker → approved test SMTP →
encrypted test-only remote backup and readback → timer scope check →
stop/quarantine/rollback. Reboot persistence is a separately authorized step.
On every incomplete or failed security branch, immediately quarantine/
stop the canary; do not continue public testing or touch recovered real data.

## Phase F — Gate matrix and publication

| Gate | Current demonstrated evidence | Verdict |
|---|---|---|
| Candidate code / CI | rc.13 PR #415 9/9 CI; 110/110 ARM64 source tests | PASS (code only) |
| Installed rc.13 release | rc.12 only on disposable VM | NOT RUN |
| Recovery / storage provenance | prior P8M–P8S accepted stopped-host evidence; no replay | HOLD (fresh P8V cross-check pending) |
| OCI HTTP80 / HTTPS443 | latest P8U4-R absent 80, public 443 transport allowed | HOLD (new layered contract pending) |
| Host source firewall | rc.12 installed dual-stack structural checks passed | HOLD (independent packet-path pending) |
| Public IPv6 absence | intended IPv4-only; OCI list returned zero-byte data | PENDING |
| DNS / Worker and isolated hostname | Worker API 403; no approved test hostname | HOLD |
| Separate blank data / test backup | not independently proven | HOLD |
| TLS / login / admin / CrowdSec / SMTP | no isolated live canary | NOT RUN |
| Reboot/restart fail-closed | no authorized public test | NOT RUN |
| Upgrade / rollback transition | rc.13 not installed | NOT RUN |
| Production cutover | original hostname/VM untouched | NOT RUN |

**No production GO while any critical gate remains HOLD/BLOCKED/PENDING/NOT RUN.**
Do not merge this documentation-only kickoff PR as proof of passing security.

## Required Codex deliverables

1. Actual new source files, tests, docs and a draft PR for this stacked
   acceptance branch; preserve release pins, history and prior rc.13 candidate.
2. Full GitHub CI run(s), including native Ubuntu 26.04 ARM64, plus focused
   regressions for malformed provider data, uncertainty and fail-closed paths.
3. Exactly two primary operator commands when ready: (a) read-only OCI
   Cloud Shell source-pinned grouped Phase A/C preflight and (b) read-only
   `ubuntu@vaultwarden-oci-7-vnic` source-pinned grouped Phase B/D preflight.
   Handle `freedom` shell's unset `USER` without altering the user's prompt
   environment; encapsulate strict flags in subshell/scripts.
4. A **separate**, conspicuous operator-consent apply/runbook for any OCI
   security-list correction, install, firewall refresh, startup, test-data
   provisioning, backup, reboot or production cutover. Never mix with the
   two read-only batches.
5. Exact reviewed candidate SHAs, private/report paths, sanitized outputs,
   clear PASS/PENDING/BLOCKED/HOLD matrix, rollback authority and next action.
6. Merge only through allowed repository method (merge commits, not squash);
   do not merge, deploy or delete branches prematurely.
