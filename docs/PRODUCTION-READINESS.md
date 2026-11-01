# Production readiness: read-only P0

Run this on the **explicitly selected installed appliance host**, not on an assumed historical acceptance VM. The host may be the current production appliance or a proposed replacement; make that distinction in the operator response. This file is an acceptance instrument, not a production service.

## One-shot invocation

On the selected Ubuntu host as `ubuntu` or another operator with passwordless `sudo -n`, copy and run this entire block:

```bash
(
set -Eeuo pipefail
umask 077
REPO="killer23d/VaultWarden-OCI"
BRANCH="audit/production-p0-readonly-inventory"
ROOT="$HOME/VaultWarden-OCI-p0"
if [ -e "$ROOT" ]; then
  echo "BLOCKED: $ROOT already exists; do not overwrite prior evidence"; exit 1
fi
sudo -n true || { echo "BLOCKED: passwordless sudo unavailable"; exit 1; }
git clone --quiet --depth 1 --branch "$BRANCH" "https://github.com/$REPO.git" "$ROOT"
cd "$ROOT"
git rev-parse HEAD
python3 -B -m unittest discover -s tests -p 'test_production_readiness_inventory.py'
sudo -n python3 -B -E tests/host-acceptance/production-readiness-inventory.py
)
```

**Pin before using this for a production decision:** the branch name above is only for initial source retrieval; compare the printed SHA with the reviewed PR's exact commit. If it differs, stop and verify the new diff. This gate never serves as authorization for production mutation.

The script reads installed release, protected storage markers, SOPS decryption into `/dev/null`, read-only `vwctl doctor/status/timers/dns status`, local encrypted artifact metadata and systemd result metadata. It writes only private evidence under the invoking operator's `~/vwoci-acceptance/production-p0-*`. No backup, restore, service enable/stop, Cloudflare write, SMTP send, host upgrade, or reboot is performed. DNS status is a live **read-only** API query, so it may be unavailable. Historical recovery timestamps are not fresh proof.

**Paste the printed summary only.** Do not paste `diagnostics.json`, raw configuration, journals, encrypted credential files, private Age identities, rclone credentials or recovery ZIP passphrases. The operator must independently attest: host role (current/replacement), OCI Console volume attachment identity, off-host encrypted recovery-kit/private Age identity custody, Worker Route Fail Open per invocation, and production DNS ownership. Any storage mismatch, incomplete or failed release validation is a stop, not a reason to repair automatically.

## Acceptance status and path selection

The archived rc.11 A/B/C real-host operational tests and rc.12 D1R/D2 fixes remain historical PASS. Full rc.12 live operation, an uninterrupted fresh rc.12 install, production update/restore, current offsite readback, release-specific coherent rollback, cutover and production monitoring are **NOT RUN**. Do not transfer the historical VM's result to production.

**P1:** after P0, determine whether the installed predecessor has an explicitly supported in-place application update to the exact release, or whether a new dedicated-volume host plus verified encrypted `.vwrec` recovery is required. Do not assume arbitrary old snapshots support direct update. The new-host route also requires original offline Age identity and root rclone configuration separately from the recovery archive.

**P2:** rehearse only release-delta security/restore/rollback boundaries not already proven, on an explicitly approved isolated host. No cloud, email, DNS, disk formatting or restore effect without its own authorization.

**P3:** require signed-off exact candidate and CI, dedicated disk and ownership proof, verified offsite recovery/readback and original recovery-kit custody, consistent SQLite, Cloudflare/Caddy/CrowdSec/admin protections, manually confirmed Worker Fail Open, four timers, notification readiness, downtime/RPO/RTO and coherent rollback authority. A critical missing prerequisite means NO-GO.

**P4/P5:** only after explicit operator GO, perform selected supported transition and controlled production DNS/traffic cutover, then prove actual outside-client authentication, security, first naturally scheduled backup with independent remote verification, and agreed observation period. Reboot is separately authorized; the Worker is intentionally unarmed following reboot.

Never claim a binary-only rollback restores persistent data or package state.
