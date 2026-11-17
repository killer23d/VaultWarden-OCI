# P8V-C grouped pre-canary read-only gate — rc.13

**Scope:** source-only and evidence-only preparation. No canary deployment, original VM interaction, Cloudflare token widening, OCI changes, DNS/Worker edits, rclone access, Docker, firewall publication, guest SSH, reboot or production authorization. Installed disposable host remains **rc.12**. Operator result is **HOLD** until separately approved live tests.

## Verified predecessor evidence (do not repeat unnecessarily)

- **2026-11-17 P8V-A OCI provider batch:** pinned executable `358d64373bf79d335b575ec5308ad3821a14df60`. Read-only operator output **16 PASS / 12 PENDING / 0 BLOCKED / 1 NOT RUN — HOLD/1**. Protected mode-0600 report in Cloud Shell: `~/vwoci-acceptance/p8v-provider-batch-20261117T212206Z-440.json`. Explicit empty JSON from signed VNIC/subnet ListIpv6s GET and no routed IPv6 destinations passed in their observed scope; null/missing IPv6 prefix fields and broader compartments remain PENDING. Original CLI empty stdout was **not** empty-JSON proof.
- **2026-11-13 P8V-B ARM64:** installed immutable rc.12, recovered state/storage continuity, all product units/timers stopped, no application listeners or containers passed. 52 bounded source tests passed. Expired Cloudflare last-known-good cache and dormant Docker bridge remain PENDING. Do not refresh them just to change the status.
- **P8T dedicated-list private SSH:** historically PASS. Original strict OCI-only Cloudflare 443 gate remains **BLOCKED/2**, not reinterpreted as PASS. Public TCP443 intentionally passes transport through OCI but is **not** independently proven Cloudflare-only.
- All nine GitHub CI jobs were successful on the earlier stacked heads #415–#422 when reviewed 2026-11-17, including native Ubuntu 26.04 ARM64. CI on *this* PR must be checked separately.

## P8V-C evidence model and guardrails

`tests/host-acceptance/production-p8v-precanary-readonly.py` is a non-root, Python 3.12+ source-and-attestation-only batch. It verifies the exact clean branch+SHA, source release version and immutable image-digest syntax, Caddy/TLS/IPv6 source template anchors, several offline negative-path test modules, and owner-private historical P8V-A report continuity. A second independent reviewer supplies current Cloudflare Dashboard/provider and management observations in a local mode-0600 attestation file. No provider or SSH requests are made by the gate itself.

An intentionally blank, owner-private template at `~/vwoci-acceptance/p8v-precanary-attestation.json` is created once and never overwritten. **Do not paste** filled attestation JSON, network IDs, FQDN, screenshots containing metadata, remote details or identifiers into chat, tickets or the PR. Populate locally only after independent verification. Keys are tri-state: `true` means both operator and independent reviewer actually observed it; `false` means a verified conflicting fact (**BLOCKED**); `null` means not yet inspected (**PENDING**). Never set a flag true just because the configuration is intended to be safe. A true manual flag is *attestation*, not external packet-path proof. A signed-in reviewer must verify the actual account, zone and planned FQDN; the script does not claim that it consulted the provider itself.

**Cloudflare:** use a separate approved test FQDN (not `bw.lazymocha.com`, any child of that name, or its parent), and verify correct zone ownership, all relevant DNS/wildcard/proxied record conflicts, Worker routes, custom domains, original production hostname/VM isolation, and Caddy source routing. A successful DNS lookup alone is not wildcard/Worker proof. The Worker Routes API previously returned HTTP403; **do not widen tokens**. The supported alternative is a current, second-person witnessed **read-only Cloudflare Dashboard** review, documented with method and UTC time in the private template. Unknown/unscanned items stay null.

**Blank data and independent backup:** select an *uncreated* prospective dedicated test-only data path on a separate storage filesystem, separate dataset/database and distinct test-only rclone alias/prefix. Verify actual future ownership/capacity, empty canary data, separate credentials/offline Age identity, independent backup write/prune/restore scope, and a remote/account configuration that could not silently resolve to the historical `bw-backup:bw-backup`. Lexical path checks are a guard, not proof of filesystem mount, symlink, backup backend, alias or credential separation. Do not set those flags true before independently verifying the backend identity and authorization; **no production Box remote contact**. Read-only source and manual plan verification cannot prove a not-yet-created data target is blank: leave that flag null until a separate authorized isolation stage makes genuine proof possible.

**Management fallback:** reconfirm exact disposable instance ID/subnet, current private SSH viability from PNA, protected host-key identity, working serial/console fallback, dedicated security-list invariants, owner-private rollback and explicit quarantine. Any rollback that automatically reattaches the original VCN default list is disallowed because it could reopen public SSH22. Keep the approved original VM and its data completely outside the candidate scope.

## Run this single read-only Cloud Shell stage

1. Switch Cloud Shell to **Public Network** to clone this exact reviewed PR branch into a **new directory**. After cloning, verify GitHub branch and commit before proceeding. The scanner itself does not need OCI CLI or OCI Service Network and does not use SSH.
2. The gate creates a private *blank* attestation if absent; it will report PENDING until an operator and independent reviewer have filled only verified facts. Re-run the **same** command after independent review if needed; it reuses the pre-existing template and never overwrites it.
3. The historical provider snapshot is read from its exact owner-private path. The P8V-A count/scope is verified without re-querying OCI; no need to repeat the P8V-B host run.
4. Share the **sanitized output only** and explicit exit label. Exit **1 = HOLD/PENDING**, exit **2 = BLOCKED**, and no exit 0 is possible during this pre-canary preparation. Expected output is **HOLD/1** even if all manual flags are true; external packet-path proof is NOT RUN.

Operator one-shot (fill in the **exact new PR HEAD** only after reviewing the PR and CI):

```bash
(
set -Eeuo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
REPO="killer23d/VaultWarden-OCI"
BRANCH="audit/rc13-p8v-precanary-grouped-readonly-20261117"
PIN="REPLACE_WITH_VERIFIED_NEW_PR_40_CHAR_SHA"
WORK="$HOME/VaultWarden-OCI-p8vc-${PIN:0:12}"
EVD="$HOME/vwoci-acceptance"
PRIOR="$EVD/p8v-provider-batch-20261117T212206Z-440.json"
ATTEST="$EVD/p8v-precanary-attestation.json"
case "$PIN" in (*[!0-9a-f]*|"") echo "P8VC_EXIT=2 bad-source-pin"; exit 2;; esac
[ "${#PIN}" -eq 40 ] || { echo "P8VC_EXIT=2 bad-source-pin"; exit 2; }
[ "$(id -un)" = freedom ] && [ "$(uname -s)" = Linux ] && [ "$(id -u)" -ne 0 ] || { echo "P8VC_EXIT=2 wrong-cloud-shell-context"; exit 2; }
[ ! -e "$WORK" ] && [ ! -L "$WORK" ] || { echo "P8VC_EXIT=2 checkout-exists"; exit 2; }
git clone --quiet --no-checkout --branch "$BRANCH" "https://github.com/$REPO.git" "$WORK" || { echo "P8VC_EXIT=1 git-clone-unavailable"; exit 1; }
git -C "$WORK" checkout --quiet "$PIN" || { echo "P8VC_EXIT=2 pin-not-in-branch"; exit 2; }
git -C "$WORK" switch --quiet "$BRANCH" || { echo "P8VC_EXIT=2 branch-not-active"; exit 2; }
[ "$(git -C "$WORK" rev-parse HEAD)" = "$PIN" ] && [ -z "$(git -C "$WORK" status --porcelain --untracked-files=all)" ] || { echo "P8VC_EXIT=2 source-not-clean"; exit 2; }
set +e
python3 -B "$WORK/tests/host-acceptance/production-p8v-precanary-readonly.py" \
    --expected-sha "$PIN" --provider-report "$PRIOR" --attestation "$ATTEST" --create-template
rc=$?
set -e
printf 'P8VC_EXIT=%s\n' "$rc"
exit "$rc"
)
```

The command intentionally does not ask for a password, cannot run a live release task and never accesses the historical backup remote. Run **once per reviewed SHA** with a fresh checkout path. If a filled template is already present, it is not rewritten. The only filesystem writes are the new source checkout and owner-private acceptance files.

## Source-policy remaining negative paths

Offline tests cover malformed/missing/duplicate/overlapping IP families, API-first fallback to both official legacy feeds, LKG expiry and cache publication, fail-closed guard sequencing, Docker hook structure. **#419 Docker `DOCKER-USER` ordering changes are on a parallel draft branch**, so passing tests on this P8V-C branch does not mean #419 is integrated. Before installing rc.13, explicitly reconcile #419 against #415 and run every combined test suite under both native OS versions. CI structural tests and an offline Docker integration fixture are **not** an external independent OCI origin packet-path witness.

## Consolidated matrix

| Gate | Status after implementing gate | External dependency |
| --- | --- | --- |
| Historical P8T private SSH and dedicated-list association | PASS (historical) | Repeat private SSH only if management connectivity has changed |
| Historical strict P8T public 443 OCI-source check | BLOCKED/2 (immutable history) | Layered-origin model requires independent host enforcement |
| P8V-A current target OCI union/assigned IPv6 GET | HOLD/1: 16 PASS, 12 PENDING, 1 NOT RUN | Scoped identity fields, unscanned compartments, external path |
| P8V-B stopped rc.12 host | PASS for dormant service/storage observations; overall HOLD | LKG stale, Docker bridge uninstantiated, no live packet proof |
| P8V-C source and manual isolation attestation | NOT RUN until operator executes new pin | Zone, Worker, blank data, test backup, management fallback |
| rc.13 combined source CI and #419 ordering integration | PENDING | Reconcile independent draft branch and run CI |
| Isolated rc.13 install and blank canary data | NOT RUN | New approval + independent separation proof |
| Non-Cloudflare direct-origin 443 / Docker NAT / userland-proxy / IPv6 | NOT RUN | Independent external packet-path witness |
| Interrupted policy, Docker restart, cache expiry, reboot persistence | NOT RUN | Explicit destructive/failure-path permission |
| TLS/admin, CrowdSec/Worker, SMTP, test-only encrypted backup, timers | NOT RUN | Authorized blank-data functional canary |
| Production deployment/cutover | HOLD | Separate production approval after all release gates |

## Consent-gated future canary stages — not executable here

1. **Pre-canary decision:** operator selects distinct canary FQDN, Cloudflare zone, future blank dataset and test-only backup target; owner and independent reviewer attest to conflict-free scope and effective management/serial rollback. A failed check means STOP/HOLD, not token/policy widening.
2. **Isolated install:** separate operator authorization before changing packages, configuring a blank canary database, publishing rc.13 firewall or starting containers. Keep original production hostname, state, VM, offsite destination and kit untouched. Confirm firewall guard before any Docker TCP443 publish.
3. **External security witness:** independent non-Cloudflare packets must be denied at IPv4 origin:443 through host input, NAT/FORWARD and userland proxy. Separately demonstrate Cloudflare-proxied HTTPS success, public SSH22 and HTTP80 unavailable and IPv6 fail closed when enabled. Any direct-origin success immediately **BLOCKED**, quarantine without restoring public SSH.
4. **Interrupted transitions:** separately authorize mocked/current policy failures, 72h expired cache, malformed API/legacy feed failures, Docker stop/restart, partial publication, rollback, retry and reboot. Capture both-family guard state. Any unintended accept interval = BLOCKED, stop and quarantine.
5. **Functional and recovery canary:** independently approve login/admin, Caddy TLS, Worker/CrowdSec, SMTP, **test-only** encrypted recovery publication/readback and natural timers. Destructive restore, prune, real remote writes, reboots and production hostname cutover each need their own scoped approval.

**Next operator decision:** review the new PR and exact SHA, run the one grouped P8V-C read-only Cloud Shell command, then provide sanitized statuses. For any Cloudflare Dashboard facts that are still unavailable, request operator-led private verification, not elevated API permissions. Production remains HOLD.

## Actual operator execution: 2026-11-17 P8V-C

The operator used **OCI Cloud Shell Public Network** with clean exact commit
`be0f166a38cdf5d3fb907fffb117805559b03d13`.
Result: **9 PASS / 30 PENDING / 0 BLOCKED / 1 NOT RUN — HOLD/1**
(`P8VC_EXIT=1`). Source/digests, Caddy template and grouped negative-path tests passed;
the historical protected provider report was reused and an owner-private blank
attestation template was created without changing any operational configuration.

Report (owner-private, do not publish):
`/home/freedom/vwoci-acceptance/p8v-precanary-20261117T214401Z-560.json`.
The latest CI on the above original source was **9/9 PASS** including native
Ubuntu 26.04 ARM64 ([run 44181932947](https://github.com/killer23d/VaultWarden-OCI/actions/runs/44181932947)).
These are historical observations, not certification of the new additional
P8V-D code or a fresh external-host witness.

### P8V-D Public Network DNS proposal survey (review-only)

The *proposed* hostname is `vwoci-rc13-canary.lazymocha.com`; it has not
been operator-approved, reserved or created. Use only GET requests to the
public Cloudflare 1.1.1.1 and Google DNS-over-HTTPS JSON resolvers to inspect
A, AAAA and CNAME DNS visibility for the candidate and an unrelated
random-looking name under the same zone (public wildcard clue), plus zone NS.
No API tokens, DNS writes or Cloudflare Dashboard login. Responses are bounded;
only sanitized categories are printed or written to a fresh mode-0600 report.
The script never edits the existing attestation or historical evidence.

**Boundary:** a recursive public resolver's empty/NXDOMAIN answer is *not*
proof of absent Cloudflare Dashboard records, Workers routes/custom domains,
account ownership, zone conflicts or production mapping. Even a six-query
PASS means **public DNS observation only** and leaves actual provider conflict
checks PENDING. Resolver failures, missing/empty body, partial answers, HTTP
errors and unrecognized DNS schema stay PENDING, never PASS. An observed DNS
answer requires manual review; do not automatically call it a blocker if it
may belong to an explicitly planned canary. The original hostname is never
the test target.

Verify the exact new PR source SHA in GitHub and run this **single**
copy/paste batch in Public Network (using a fresh checkout path):

```bash
(
set -Eeuo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
REPO="killer23d/VaultWarden-OCI"
BRANCH="audit/rc13-p8v-precanary-grouped-readonly-20261117"
PIN="REPLACE_WITH_VERIFIED_NEW_PR_40_CHAR_SHA"
ZONE="lazymocha.com"
PROPOSAL="vwoci-rc13-canary.lazymocha.com"
WORK="$HOME/VaultWarden-OCI-p8vd-${PIN:0:12}"
case "$PIN" in (*[!0-9a-f]*|"") echo "P8VD_EXIT=2 pin-invalid"; exit 2;; esac
[ "${#PIN}" -eq 40 ] || { echo "P8VD_EXIT=2 pin-invalid"; exit 2; }
[ "$(id -un)" = freedom ] && [ "$(id -u)" -ne 0 ] || { echo "P8VD_EXIT=2 wrong-user"; exit 2; }
[ ! -e "$WORK" ] && [ ! -L "$WORK" ] || { echo "P8VD_EXIT=2 checkout-exists"; exit 2; }
git clone --quiet --depth 1 --branch "$BRANCH" \
  "https://github.com/$REPO.git" "$WORK" || { echo "P8VD_EXIT=1 git-unavailable"; exit 1; }
cd "$WORK"
[ "$(git rev-parse HEAD)" = "$PIN" ] || { echo "P8VD_EXIT=2 source-mismatch"; exit 2; }
[ "$(git symbolic-ref --quiet --short HEAD)" = "$BRANCH" ] || { echo "P8VD_EXIT=2 branch-mismatch"; exit 2; }
[ -z "$(git status --porcelain --untracked-files=all)" ] || { echo "P8VD_EXIT=2 dirty-checkout"; exit 2; }
set +e
python3 -B tests/host-acceptance/production-p8v-dns-proposal-readonly.py \
  --expected-sha "$PIN" --zone "$ZONE" --test-fqdn "$PROPOSAL"
rc=$?
set -e
printf 'P8VD_EXIT=%s\n' "$rc"
exit "$rc"
)
```

Only a **HOLD/1** result is permissible if the proposal remains lexically
valid; a wrong/production hostname is BLOCKED/2. Never publish the private
JSON or raw DNS answer data. If Cloud Shell Public Network cannot reach
either DoH resolver, report PENDING; do not widen egress/IAM to force a PASS.

### Consolidated manual Dashboard review (next approval dependency)

With the correct Cloudflare **account and zone** open, a genuine reviewer
must inspect **DNS → Records** for the proposed canary name, apex/zone
wildcards, CNAME and proxied A/AAAA conflicts; then **Workers & Pages →
Workers Routes / Custom Domains** for every potentially overlapping
production or planned test route. The historical Worker Routes API HTTP403
is not grounds to broaden API token permissions. Review original production
hostname/VM separation and the expected Caddy TLS DNS-challenge source
contract. Never alter DNS, routes or custom domains during this check.

The owner-private existing file
`~/vwoci-acceptance/p8v-precanary-attestation.json` remains the only
manual attestation template. Populate only **actually reviewed** facts,
with an independent reviewer, accurate UTC observation time, and method
`dashboard-two-person` or `api-readonly-two-person`. Missing approval
or independent review means `null`, not `true`. Do not invent a second
reviewer or mark a not-yet-created blank dataset as verified.

For the **future** canary data and backup target, separately plan the
dedicated ext4 dataset/database, distinct independently authorized remote
alias and backend, new test-only credentials and off-host Age identity,
actual mount/capacity and rollback/retention constraints. Merely choosing
different strings does not establish physical or credential isolation.
Avoid even read-only contact with historical
`bw-backup:bw-backup` and never point tests at recovered live state.
These remain HOLD until independently verified and separately authorized.

The P8V-A 2026-11-17 provider union and P8V-B 2026-11-13 stopped-host
evidence remain preserved, not rerun merely because this public DNS
proposal runs. For private SSH and management fallback use the accepted
PNA administrator guide; never reopen public SSH by attaching the old
shared default OCI list. **No live canary authorization.**
