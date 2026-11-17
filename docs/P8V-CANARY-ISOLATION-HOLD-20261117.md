# P8V canary hostname isolation HOLD — 2026-11-17

**Release status: HOLD.** This is a sanitized, operator-reported observation
about a *proposed* rc.13 canary test hostname, not authorization to change
Cloudflare, OCI, the original VM or the stopped rc.12 appliance.

## Operator response

| Check | Operator response | Meaning for canary acceptance |
| --- | --- | --- |
| Test FQDN | ACCEPT: vwoci-rc13-canary.lazymocha.com | Candidate selected by operator, not isolated or authorized for use |
| Zone ownership | CONFIRMED | Operator-reported; independent account/zone attestation still pending |
| Exact DNS record | PRESENT | Existing record must be positively identified and reviewed for ownership/target; **do not overwrite** |
| DNS wildcard | PRESENT | Wildcard coverage may affect the proposed canary; conflict-free DNS **not proven** |
| Worker Route overlap | PRESENT | Explicit route overlap reported; **canary isolation BLOCKED** pending route mapping |
| Worker Custom Domain overlap | PRESENT | Explicit Custom Domain overlap reported; **canary isolation BLOCKED** pending mapping |
| Production config unchanged | YES | Operator reports no production configuration change during investigation |
| Independent reviewer | AVAILABLE | Reviewer can be scheduled; independent attestation has **not** yet been received |

**Verdict:** the existing proposed hostname fails the no-overlap pre-canary
design gate by operator report. This is a **canary-scope BLOCKED/2 condition**,
not proof of a production security incident and not an assessment of whether
the current Cloudflare configuration is correctly intended for existing
services. Treat the DNS record and wildcard as conflicts requiring
attribution, not as permission to delete or change them.

Do **not** set the private P8V-C attestation's
`dns_no_wildcards`, `worker_routes_no_overlap`, or
`worker_custom_domains_no_overlap` flags to true on these observations.
After independent review, confirmed overlap should be recorded as false,
which the verifier already classifies BLOCKED. The reviewer being
*available* is not proof that an independent review occurred.

## Next safe decision

The operator and independent reviewer must choose a genuinely isolated
test name or produce independently witnessed mapping showing that a
separately approved test hostname cannot be intercepted by existing
wildcard DNS records, proxied records, Worker Routes, Custom Domains,
or the production hostname/original VM. Inspect Cloudflare Dashboard
read-only. The previous Worker Routes HTTP403 must **not** be handled by
expanding the operational API token. Do not edit or remove any production
DNS records or Worker routes merely to clear a gate.

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
though the live canary remains BLOCKED/HOLD. It is not an approval to
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
or avoid the production Worker. Cloudflare route matching has
wildcard/path-specific behavior; do not attempt to settle it by counting
records alone.

References (public docs, read-only):
- https://developers.cloudflare.com/dns/manage-dns-records/reference/wildcard-dns-records/
- https://developers.cloudflare.com/workers/configuration/routing/routes/
- https://developers.cloudflare.com/workers/configuration/routing/custom-domains/

**Conservative decision remains BLOCKED/HOLD** until the operator
and available *independent* reviewer verify all of the following
without changing any provider settings:

1. The exact canary DNS record's **effective target role** is
   `isolated-test-origin`, `production-origin`, `worker-owned`
   or `unknown`. Do not disclose the actual IP, record contents
   or account identifiers. A DNS record pointing to production is
   a blocker, not a test destination.
2. Every Worker Route that actually matches the canary **hostname and
   relevant paths** is identified as `test-only`, `production-shared`,
   `does-not-match-after-review` or `unknown`. Include login,
   admin, API and recovery paths in the review. Do not mark a route
   non-matching merely because its pattern looks broad or narrow.
3. For any matching Worker Custom Domain, determine whether it is
   `test-only-worker-origin`, `production-worker-origin`,
   `none-exact-match` or `unknown`. Do not assume a Worker Custom
   Domain forwards to the appliance's Caddy origin. Cloudflare's
   documented interaction between Routes and Custom Domains
   requires reviewing what the matched Worker actually does.
4. Confirm the original production hostname and original OCI VM
   are entirely separate from this test and their settings remain
   unchanged, and record the independent review's completion
   rather than just the reviewer's availability.

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
