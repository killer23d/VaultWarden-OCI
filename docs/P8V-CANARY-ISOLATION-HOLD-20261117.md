# P8V future-site laboratory routing HOLD — 2026-11-17

**Operator clarification, November 17:** both Cloudflare and the OCI host are
**non-production test infrastructure** for validating future production-site
deployments. Older hostnames, recovered application state and backup material
are protected *reference/test assets*, not an existing live production site.

**Current result: HOLD/PENDING on effective routing.** The presence of DNS
records, wildcards, Worker Routes and Custom Domains is not itself a failure
in a deliberately configured test environment. A verified unintended
destination, leaked reference test data or direct-origin bypass remains
BLOCKED/2. No changes or live rc.13 release are authorized.

## Operator response

| Check | Operator response | Meaning for canary acceptance |
| --- | --- | --- |
| Test FQDN | ACCEPT: vwoci-rc13-canary.lazymocha.com | Candidate selected by operator, not isolated or authorized for use |
| Zone ownership | CONFIRMED | Operator-reported; independent account/zone attestation still pending |
| Exact DNS record | PRESENT | Existing record must be positively identified and reviewed for ownership/target; **do not overwrite** |
| DNS wildcard | PRESENT | Wildcard coverage may affect the proposed canary; conflict-free DNS **not proven** |
| Worker Route overlap | PRESENT | Explicit route overlap reported; effective routing is not yet independently characterized |
| Worker Custom Domain overlap | PRESENT | Explicit Custom Domain overlap reported; effective Worker ownership is not yet independently characterized |
| Configuration unchanged | YES | The original response said `PRODUCTION CONFIG UNCHANGED`; the operator clarified that these resources are all non-production tests |
| Independent reviewer | AVAILABLE | Reviewer can be scheduled; independent attestation has **not** yet been received |

**Historical assessment, superseded by operator scope correction:** the
original no-overlap rule classified any observed overlap as BLOCKED/2 on the
assumption the Cloudflare account and OCI host served live production.
The correct current classification is **HOLD/PENDING** until we review what
actually runs and where requests go. Confirmed wrong-origin mapping or
bypass would still be BLOCKED for a future production-site rehearsal.

**Legacy attestation limitation:** the original P8V-C fields
`dns_no_wildcards`, `worker_routes_no_overlap` and
`worker_custom_domains_no_overlap` encode absence instead of
verified intended routing. They cannot approve an intentional test-only
mapping. Do not force their values to manufacture a PASS or recast a
verified test configuration as unsafe solely because a wildcard exists.
Keep protected prior reports unchanged. The independent reviewer is
AVAILABLE, but has not yet completed a review.

## Next safe decision

The operator and independent reviewer should trace the **effective test
request path** through exact DNS, wildcard precedence, matching Worker
Routes, Custom Domains and the selected test origin. A separate hostname
is needed only when safe test-only ownership cannot be demonstrated.
Keep the recovered reference VM, credentials, database and historical
Box destination isolated. Review the Cloudflare Dashboard read-only;
do not widen API-token scopes after the historical HTTP403 or alter
existing DNS/Workers just to change acceptance classifications.

A selected DNS name is only one dependency. The isolated blank test
dataset/database, dedicated storage, test-only backup credentials and
remote, console rollback/quarantine and independent external packet-path
proof remain PENDING / NOT RUN as separately documented.

## Historical evidence and Git integration boundary

- 2026-11-17 P8V-A scoped OCI read-only batch: 16 PASS, 12 PENDING,
  0 BLOCKED, 1 NOT RUN; provider transport HOLD/1.
- 2026-11-17 P8V-C source-only batch: 9 PASS, 30 PENDING,
  0 BLOCKED, 1 NOT RUN; HOLD/1.
- 2026-11-17 P8V-D public DNS proposal: 1 PASS, 7 PENDING,
  0 BLOCKED, 1 NOT RUN; HOLD/1, resolvers unavailable/incomplete.
- The newly reported real Dashboard overlaps are later operator evidence
  and **must not** retroactively relabel the P8V-D DNS scanner's output.
- Original P8T strict OCI-only Cloudflare-source TCP443 remains historical
  BLOCKED/2; P8V OCI public TCP443 is transport-only, never external origin
  packet-path proof.
- The currently installed appliance remains immutable rc.12; rc.13 is
  source only. Merging source/documentation to the v2 development branch
  must never activate a service, alter Cloudflare/OCI policies, refresh
  host firewall, touch recovered data, contact historical
  bw-backup:bw-backup, reboot or constitute a production GO.

This record may be integrated into v2 as development documentation even
though live canary acceptance remains HOLD. It is not an approval to
deploy or an independent reviewer sign-off.

## Next reviewed batch after primary-branch source merge

**Development integration verified, not a live acceptance:** The manually
squashed rc.13/P8V changeset was merged into the primary development Git
branch `v2` by PR #425 at
`3036e46d936e61b27f0b0b669bb5403f1f14ae9e`.
Both the 9/9 integration PR CI and 9/9 post-merge push CI completed
successfully, including native Ubuntu 26.04 ARM64. The original draft
feature branches are historical and can be removed manually. The installed
disposable machine remains immutable rc.12; no live rc.13 test has run.

### Exact DNS does not by itself imply a wildcard conflict

The operator's `PRESENT` observations are authoritative **as reported**,
but they are not a route-target inventory. Per Cloudflare DNS documentation,
an exact DNS record or delegation takes precedence over an applicable
wildcard at that hostname. A wildcard elsewhere in the zone is not
automatically an effective mapping for that exact hostname.

A Worker **Route** matches URL paths at the edge and can execute before
an origin request. A Worker **Custom Domain** matches one exact hostname
for all paths and treats the Worker as the origin; an overlapping Route
can run before that Worker and possibly forward to it. These combinations
can be intentional, but *PRESENT* alone does not prove the canary would
reach its own independent test origin, preserve intended security checks
or avoid unintended reference test Workers. Cloudflare route matching has
wildcard/path-specific behavior; do not attempt to settle it by counting
records alone.

References (public docs, read-only):
- https://developers.cloudflare.com/dns/manage-dns-records/reference/wildcard-dns-records/
- https://developers.cloudflare.com/workers/configuration/routing/routes/
- https://developers.cloudflare.com/workers/configuration/routing/custom-domains/

**Current routing assessment remains HOLD/PENDING** until the operator
and available *independent* reviewer verify all of the following
without changing any provider settings:

1. The exact canary DNS record's **effective target role** is
   `isolated-test-origin`, `other-reference-test-origin`, `worker-owned`
   or `unknown`. Do not disclose the actual IP, record contents
   or account identifiers. An unintended reference-state mapping is
   a blocker for an isolated blank-data test.
2. Every Worker Route that actually matches the canary **hostname and
   relevant paths** is identified as `test-only`, `other-lab-unintended`,
   `does-not-match-after-review` or `unknown`. Include login,
   admin, API and recovery paths in the review. Do not mark a route
   non-matching merely because its pattern looks broad or narrow.
3. For any matching Worker Custom Domain, determine whether it is
   `test-only-worker-origin`, `other-lab-unintended-worker-origin`,
   `none-exact-match` or `unknown`. Do not assume a Worker Custom
   Domain forwards to the appliance's Caddy origin. Cloudflare's
   documented interaction between Routes and Custom Domains
   requires reviewing what the matched Worker actually does.
4. Confirm the older reference hostname, recovered test VM, credentials,
   retained data and historical offsite backup remain separate from any
   new blank-data test instance. These are not live production. Record a
   completed independent review rather than mere reviewer availability.

The independently reviewed result may be that the *existing* candidate
can be kept with deliberate test-only routing, **or** that a genuinely
separate test hostname/zone is necessary. Neither result authorizes
creating, deleting, disabling, rewriting, or replacing DNS records,
Worker routes or custom domains in this read-only stage. The historical
Worker Routes API HTTP403 is not permission to widen the token.

### One grouped stopped-host freshness gate

After entering the appliance using the previously approved **private-only
SSH** route (Cloud Shell Private Network Access), run from
`ubuntu@vaultwarden-oci-7-vnic` on Ubuntu 26.04 ARM64. Do **not**
run from the Cloud Shell `freedom` prompt. This one-shot deliberately
groups stopped product units/timers, listeners, Docker container absence,
immutable rc.12 state, dedicated ext4/custody, checkpoint hashes,
dual-stack iptables structure and bounded offline source tests.
It **does not** refresh a stale LKG, create a Docker bridge, start the
appliance, read decrypted credentials, contact offsite backup or
modify network policies. If HTTPS GitHub clone cannot complete, stop
without changing egress rules and report the sanitized error.

```bash
(
set -Eeuo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0

REPO="killer23d/VaultWarden-OCI"
BRANCH="v2"
PIN="3036e46d936e61b27f0b0b669bb5403f1f14ae9e"
HOST="vaultwarden-oci-7-vnic"
WORK="$HOME/VaultWarden-OCI-p8v-readonly-${PIN:0:12}"

fail() {
    printf 'P8V_HOST_EXIT=2 BLOCKED: %s\n' "$1"
    exit 2
}

[ "$(id -un)" = ubuntu ] || fail "wrong operator account"
[ "$(hostname -s)" = "$HOST" ] || fail "unexpected host"
[ "$(uname -m)" = aarch64 ] || fail "ARM64 host required"
sudo -n true || fail "passwordless sudo unavailable"
[ ! -e "$WORK" ] && [ ! -L "$WORK" ] || fail "source checkout exists"
git clone --quiet --depth 1 --branch "$BRANCH" \
    "https://github.com/$REPO.git" "$WORK" ||
    fail "reviewed source clone unavailable"
cd "$WORK"
[ "$(git rev-parse HEAD)" = "$PIN" ] || fail "source SHA changed"
[ "$(git symbolic-ref --quiet --short HEAD)" = "$BRANCH" ] ||
    fail "source branch mismatch"
[ -z "$(git status --porcelain --untracked-files=all)" ] ||
    fail "source not clean"
echo "PASS: reviewed clean primary development source"

set +e
sudo -n /usr/bin/python3 -B \
    tests/host-acceptance/production-p8v-host-layered-readonly.py \
    --expected-sha "$PIN"
rc=$?
set -e
printf 'P8V_HOST_EXIT=%s\n' "$rc"
exit "$rc"
)
```

**Expected:** `HOLD/1` due to stale Cloudflare LKG,
uninstantiated Docker bridge and missing external packet-path witness,
even when stopped-state security/continuity is healthy. A confirmed
unexpected listener, running container, inconsistent recovery checkpoint
or improper `DOCKER-USER` structure is **BLOCKED/2** and must
not be silently repaired. Report sanitized console rows and the exit
status only; the full evidence remains privately mode 0600.

**Do not combine** the separate Cloudflare Dashboard attestation
with this host script or populate the previously blank P8V-C private
review file as signed/independent until a second person actually
reviews it. Backup identity, clean test filesystem, source-only
rc.13 vs installed rc.12 and external origin packet-path remain
distinct gates and no production GO is implied.


### November 17 ARM64 operator result — grouped, read-only, complete

The operator ran the exact clean `v2` development-branch source at
`3036e46d936e61b27f0b0b669bb5403f1f14ae9e` on the approved
Ubuntu 26.04 ARM64 test host. Result **8 PASS / 4 PENDING /
0 BLOCKED / 1 NOT RUN — HOLD/1**. All **52 bounded source tests passed**.

PASS: correct ARM64 identity and privilege, immutable installed rc.12 vs
source-only rc.13, recovery hashes, dedicated ext4 storage and secrets
custody, dormant product units and timers, absence of TCP 80/443
application listeners, empty Docker container inventory and offline
source regression tests.

PENDING: expired Cloudflare last-known-good cache (must not authorize a
future start), Docker bridge not instantiated while stopped, no
independent direct-origin NAT/FORWARD/userland-proxy packet witness, and
unverified test-only Cloudflare path/blank data/backup separation.

NOT RUN: rc.13 installation, live firewall refresh, Docker startup,
application traffic, reboot, production-site deployment, test-only
offsite writes or restore. This historical owner-private report stays
on the host; do not copy it to the public PR. Do not rerun identical
stopped-host checks solely to turn expected PENDING into PASS.

### Next one-pass Cloudflare test topology checklist

For the accepted candidate hostname, the operator and independent
reviewer must establish *effective target roles*, not eliminate all
intentional overlapping configuration:

| Item | Sanitized answer (no IPs, IDs, script contents or route expressions) |
| --- | --- |
| Exact DNS target | `intended-test-host` / `other-reference-test-host` / `worker-managed` / `unknown` |
| Applicable wildcard | `shadowed-by-exact` / `effective` / `none` / `unknown` |
| Matching Worker Routes | `intended-test-policy` / `other-test-unintended` / `no-match` / `unknown` |
| Worker Custom Domain | `intended-test-worker` / `other-test-unintended` / `no-exact-match` / `unknown` |
| Data isolation | `verified-blank-test` / `not-provisioned` / `shares-recovered-state` / `unknown` |
| Independent review | `completed` / `available-not-completed` |

Exact DNS takes priority over a matching wildcard, but this does not
establish which Worker executes. A Worker Route can intentionally run
before a Worker Custom Domain; each must be mapped to its intended
test-only role. A verified bypass or unintended recovered-state mapping
is BLOCKED; a missing observation remains PENDING.

A future production-ready release additionally requires an independently
isolated blank-data host, OCI public TCP22/80 denial, fail-closed dual-stack
Cloudflare-only origin protection through Docker NAT/FORWARD/userland-proxy,
correct cache-expiry/start/restart behavior, functional TLS/admin/SMTP/
CrowdSec, private SSH/serial rollback and test-only encrypted backup/restore.
These live or destructive tests need separate explicit consent.
