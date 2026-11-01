# Production readiness: read-only P0

Run this on the **explicitly selected installed appliance host**, not on an assumed historical acceptance VM. The host may be the current production appliance or a proposed replacement; make that distinction in the operator response. This file is an acceptance instrument, not a production service.

## New VM / replacement host: P0 preflight (no installed appliance)

A clean recovery VM has no `/opt/vaultwarden-oci/current`, so the **installed-host** P0 tool below must not be used as its first gate. Use the separate `tests/host-acceptance/production-new-host-preflight.py` instead. It supports the fresh Ubuntu 26.04 ARM64 path, uses the release-owned storage ancestry logic to list non-boot data-volume candidates, and refuses to approve a device without independent OCI Console confirmation. Run it with `sudo -n python3 -B -E` only after checking out **the exact reviewed PR head SHA**, not an unfrozen branch tip.

P0 does not download a remote backup or create an installer state. The subsequent approved route is the documented [lost-server recovery](RECOVERY.md#lost-server-disaster-recovery): install exact `0.1.0-rc.12` with the **existing original offline public Age recipient**, verify the selected encrypted `.vwrec` from its full rclone object path or a securely transferred local copy, restore through supported `vwctl restore` with an explicit final `RESTORE` confirmation, then inspect the recovered config/backup retention and secure the isolated runtime before considering DNS. Root rclone config and credentials are NOT in the recovery archive. Do not create a replacement offline identity for material already encrypted to the original recipient.

This fresh VM is a **disposable test/replacement candidate**, not automatically the currently serving production appliance. A successful new-host exercise cannot substitute for production-host inventory, approved cutover, and coherent rollback. Keep the existing production DNS and remote recovery objects unchanged.

## Installed appliance: one-shot invocation

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

## Interpreting a pre-start rc.12 host inventory

A host installed successfully but not yet operated may legitimately have **no backup directory, no encrypted `.vwrec`, no recovery verification state, inactive services and inactive timers**. These are `NOT RUN` or `PENDING` evidence gaps, not proof the underlying ext4 volume is damaged. An existing *symlinked*, unreadable, or wrong-filesystem backup path remains a blocker.

A systemd backup service with `Result=success` but **no timer `LastTriggerUSec`** has not proved a scheduled backup. Even when a timer trigger exists, matching service journal, validated local encrypted artifact and independent remote readback are needed before claiming real scheduled-backup acceptance.

The P0 script runs a non-disclosing SOPS decryption into `/dev/null` to prove **cryptographic** access. It then separately invokes the installed secret validator in memory to test required credential presence, Cloudflare token formats and the required remediation credential. These results can differ: a decryptable file may still contain incomplete first-run credentials. Share only the script's field-name/boolean status, never the raw decrypted JSON or exception text. Do not edit credentials or enable the appliance until a separate authorized gate.

For the disposable `vaultwarden-oci-6-vnic` VM, D1R and D2 are accepted only within their historical scopes. Full rc.12 runtime/security/offsite/scheduled-backup acceptance still requires isolated endpoint planning, correct private offline Age identity custody, a verified representative remote `.vwrec`, and individual approval for any actual restore, Cloudflare, mail or backup effect. P0 itself must not perform any of those.

## Initial observed P0 on disposable rc.12 host (2026-11-01 UTC)

The operator executed the **earlier** P0 script at commit `d2051b6dbe85778414f9fee45923421fbe6735e5` on `vaultwarden-oci-6-vnic` at **2026-11-01T06:34:54Z**. The 9 focused `test_production_*.py` checks passed. This is the **existing rc.12 disposable acceptance VM**, not an independently selected production host.

- **PASS**: Ubuntu 26.04 Resolute ARM64, native Python 3.14.4; installed immutable `0.1.0-rc.12`; launcher; dedicated ext4 volume UUID `75ceee68-0fff-4f74-b629-4e22b3b99c20`, stable by-id, separate root device and matching dual storage markers; approximately 46 GiB available; root-private config/SOPS/operational Age metadata; real SOPS ciphertext decryption to `/dev/null`; no update guard or reboot request.
- **Stopped/unproven**: Vaultwarden target inactive/disabled, all four timers not accepted, no recorded local or remote verified recovery, offsite publishing not configured, retention 0/0. No DNS update, remote readback, SMTP, real restore, application start, timer firing or reboot was performed.
- **Doctor FAIL**: `secrets.decrypt`, Cloudflare origin CIDR/firewall, and four CrowdSec checks; warnings for local/offsite/rclone recovery. The direct SOPS check proved only cryptographic decryption, **not** required secret values or provider token format. First-run credentials may be incomplete, but that cause was **not established** by this first P0 output.
- **Initial P0 classification limitations corrected in this PR**: the initial script reported `BLOCKED` for an unreadable *or absent* backup directory without distinguishing them; the exact directory state is still unknown until the revised read-only inspection runs. It also marked backup.service `PASS` from systemd `Result=success` although `LastTriggerUSec` was empty. **No successful scheduled backup was observed.** The revised script classifies those evidence boundaries truthfully.
- **Final first-run result: `BLOCKED` for progressing to live deployment.** OCI Console attachment ownership, offline recovery-kit/private identity, current Worker invocation Fail Open, actual DNS authority and the production deployment topology were not independently attested.

Next run: use the corrected, pinned installed-appliance P0 script to classify missing/unsafe local backup path and secret schema without printing secrets. Then seek separate operator approval for isolated rc.12 recovery/security tests; do not re-run historical D1R/D2 or make a production mutation on this evidence alone.

## Follow-up P0 acceptance on disposable rc.12 (2026-11-01 UTC)

The operator reran corrected P0 from merged commit `816eeda8f280594027b6c468c1ba0f7a043cd726` on `vaultwarden-oci-6-vnic`, **2026-11-01T06:40:45Z**. All **12 focused tests passed**. Independent evidence: exact rc.12 release, original dedicated ext4 UUID/dual markers, 46 GiB available, root-protected config/SOPS/operational Age and successful **ciphertext** decryption. The previously ambiguous local-backup failure was correctly classified **NOT RUN: directory absent**, and the backup service's idle `Result=success` was correctly classified **NOT RUN: no timer trigger**. No application service or timer was activated.

The exact blocker is now `secrets.decrypt`: a required `cloudflare_api_token` value is missing or invalid in the *current fresh-install SOPS document*. This is a **semantic credential/configuration error**, not proof that SOPS/Age cryptography is broken. Current Cloudflare/CrowdSec checks cannot be passed until those services/credentials are set up and live acceptance occurs. **Do not insert live production tokens solely to silence pre-restore doctor checks**; a verified recovery can replace the target's config/secrets, after which isolated configuration and security must be validated again. Do not treat it as a runtime regression without further proof.

Recovery state remains **no local .vwrec, no offsite publishing configured**, with positive original off-host recovery-kit custody and current Box access **not independently attested on this host**. Full rc.12 live operational acceptance and actual production cutover remain NOT RUN.

## Gate P1 — Source/custody preflight before any recovery mutation

Use the separate source-owned `tests/host-acceptance/production-recovery-source-preflight.py` **only on disposable `vaultwarden-oci-6-vnic`** after pinning the approved Git commit. It verifies the still-stopped immutable rc.12 selection, original stable OCI data disk UUID/by-id and dual markers, absence of application/timer activation, zero configured offsite publication/pruning, matching historical/off-host **public** Age recipient and SOPS custody, root's *rclone remote names* and metadata presence of the prior encrypted recovery-kit ZIP.

By default P1 is strictly **local and read-only** apart from creating a private summary under `~/vwoci-acceptance`. Without an explicit opt-in, it does not contact Box; seeing `bw-backup:` in `rclone listremotes` does not establish Box connectivity or valid credentials. The **optional** `--verify-box-readback` flag initiates one bounded, full ciphertext-only read from the precise historical `.vwrec` object and compares SHA-256 against independent A3/A4 evidence. This can refresh root's local rclone OAuth token/config and will contact Box, but cannot alter the Box object or persist decrypted/archive contents. It is never enabled implicitly and is skipped if host identity/isolation has a blocker. This flag **does not** decrypt the ZIP, ask for a passphrase, stage a private Age identity, validate the `.vwrec` manifest or SQLite, restore, start services, edit credentials, modify Cloudflare DNS/Worker, send email or enable timers. Those cryptographic, runtime and mutation gates remain separately authorized.

**Known historical candidate only:** the previous rc.11 A3/A4 gate proved `bw-backup:bw-backup/recovery-20261029T223200Z-1d319a79.vwrec` with SHA-256 `ee2b43a859ca85fb64ce20af67a3c862a2c2946ebf11df1e9fb95f880e235060`. The rc.12 D1R recipient has the same **public recipient fingerprint** as that A4 verification: `7d08721bcc02bbef7dae1f07bfde244852560c69d0b72f8dc0fcba0da30c6773`. These are *historical custody and checksum evidence*, not assurance that the file still exists or that an rc.12 restore has been performed. The actual encrypted `.vwrec` and AES-256 credential recovery-kit ZIP are different artifacts. If the root rclone remote is missing, choose a trusted workstation download and protected transfer or separately authorize secure root rclone configuration; do not paste its credentials into a log or chat.

The preferred **disposable-host rehearsal** uses the already installed rc.12 immutable release, not a fresh install or an invented rc.11→rc.12 update. Following separate authorization, independently verify the remote ciphertext and matching offline Age identity, inspect restore plan and guard current production DNS/remote retention, then use the supported explicit or guided `vwctl restore` with final typed `RESTORE` only after approval. Complete isolated service/security/notification/backup gates after a successful real restore. A backup from another version is not automatically proven compatible merely because its public recipient matches: require the product's manifest/schema/SQLite validation before promotion.

## Observed P1 and expanded one-shot coverage (2026-11-01 UTC)

The operator ran P1 at pinned merged commit `8e3cf57c0238640cf426d736c2f25c26c04dd515` on `vaultwarden-oci-6-vnic`, **2026-11-01T06:46:50Z**. All **5 source/custody unit tests passed**. Real-host result: **PENDING** (exit 0)—original rc.12 release, independent data-volume identity, disabled app/DNS/timers, no update guard, offline **public** recipient fingerprint and safe backup retention 0/0 all **PASS**. Root's `bw-backup:` rclone remote was **not configured** on this VM, and the encrypted recovery-kit ZIP was **absent** from the previously accepted temporary VM path. Box availability/current SHA, matching **offline private** Age identity, ZIP passphrase custody, archive verification and restore remain **NOT RUN**. Do not mistake missing files at a historical temporary path for loss of the off-host recovery kit.

**Expanded P1 acceptance gate:** the same existing `production-recovery-source-preflight.py` now continues into a broader host survey *even when Box/kit prerequisites are absent*. The new sections classify exact byte-level installed-release versus reviewed source content and immutable modes, installed systemd unit drift, dedicated disk capacity, Ubuntu/Python contract, parsed non-secret config and in-memory secret-schema readiness, database/backup metadata without decryption, sanitized product doctor check IDs, Docker/Compose daemon and appliance-container presence **only when Docker is already active** (to avoid socket-triggered startup), prerequisite binaries and `dpkg --audit`, CrowdSec/Worker unit states, non-disclosing TCP 80/443 listener state, NTP and reboot markers. Read-only tests cannot prove actual app/login/Cloudflare/CrowdSec packet behavior, backup integrity, SMTP delivery or rollback. `PASS` for tooling or file presence **does not mean** a live security, recovery or mail operation passed.

**Run as one pinned checkout:** clone the repository's current release branch at the exact reviewed merge commit, run `python3 -B -m unittest discover -s tests -p 'test_production_recovery_source_preflight.py'`, then `sudo -n python3 -B -E tests/host-acceptance/production-recovery-source-preflight.py`. Paste **only the sanitized summary**; keep all original acceptance logs, credentials and recovery key/kit off chat. The run writes one private local summary and never mutates appliance, storage or cloud state.

**Subsequent recovery lane:** the encrypted `.vwrec` can be transferred from a trusted workstation or the separate rc.11 test host as **ciphertext only**, or root's Box rclone remote can be securely configured under separate authorization. The independent file SHA-256 and cryptographic/manifest/SQLite verification must precede any typed `RESTORE`. Keep the original remote object immutable, and after any real approved restore audit recovered retention and Cloudflare/DNS/SMTP configuration *before* starting services/timers. A missing `cloudflare_api_token` in the current pre-restore SOPS payload may be resolved by approved recovery or by explicit isolated test credentials; do not reuse production credentials to make P1 show green.

## Report crash from first expanded P1 and corrected retry

The operator executed broad P1 from merged commit `3f051aeb3c2785e02172201bb2ec6e4397c50303` on `vaultwarden-oci-6-vnic`. All **23 focused Python tests passed** and source/checkout cleanliness passed. **The live host survey crashed** in the Docker container inventory branch, before producing a summary: the local `rows` report accumulator was overwritten by `code, rows = run_readonly(["docker", "ps", ...])`. The resulting `AttributeError: 'str' object has no attribute 'append'` was a **test-harness scoping defect** and does **not** prove a Vaultwarden runtime failure or live acceptance. The real Docker daemon was already active when the branch was entered; the P1 result for that run remains **INCOMPLETE/NOT CLASSIFIED**. The operator then reported separately configuring root's Box rclone remote; its current name and connectivity were not yet verified by any completed summary.

The corrective PR renames the report accumulator and the Docker command output, adds a regression that prevents the report buffer from being rebound, and adds bounded subprocess hash tests. A rerun should use the exact merged corrective source, keep the existing immutable rc.12 release/dedicated volume untouched, and verify that the full sanitized report is emitted.

**Optional Box ciphertext SHA-256 readback:** explicit `--verify-box-readback` on that same P1 command will (only after local isolation checks) use root's configured `bw-backup:` remote to read `bw-backup:bw-backup/recovery-20261029T223200Z-1d319a79.vwrec`, stream no more than **4 GiB** with a **10-minute maximum**, and compare SHA-256 with `ee2b43a859ca85fb64ce20af67a3c862a2c2946ebf11df1e9fb95f880e235060`. The stream is discarded, not saved on the server; rclone stderr and credentials are not printed. This requires the operator to deliberately run the flagged command because it contacts Box and may refresh the root rclone OAuth token **on this VM**. A failed fetch or timeout is `PENDING`; a mismatched checksum is `BLOCKED`; a verified exact match is `PASS` for **ciphertext integrity only**, not successful restore, manifest parsing, private offline identity or full application readiness. No rclone upload or deletion, cloud DNS, service start, ZIP decryption or restore occurs.

## Acceptance status and path selection

The archived rc.11 A/B/C real-host operational tests and rc.12 D1R/D2 fixes remain historical PASS. Full rc.12 live operation, an uninterrupted fresh rc.12 install, production update/restore, current offsite readback, release-specific coherent rollback, cutover and production monitoring are **NOT RUN**. Do not transfer the historical VM's result to production.

**P1:** after P0, determine whether the installed predecessor has an explicitly supported in-place application update to the exact release, or whether a new dedicated-volume host plus verified encrypted `.vwrec` recovery is required. Do not assume arbitrary old snapshots support direct update. The new-host route also requires original offline Age identity and root rclone configuration separately from the recovery archive.

**P2:** rehearse only release-delta security/restore/rollback boundaries not already proven, on an explicitly approved isolated host. No cloud, email, DNS, disk formatting or restore effect without its own authorization.

**P3:** require signed-off exact candidate and CI, dedicated disk and ownership proof, verified offsite recovery/readback and original recovery-kit custody, consistent SQLite, Cloudflare/Caddy/CrowdSec/admin protections, manually confirmed Worker Fail Open, four timers, notification readiness, downtime/RPO/RTO and coherent rollback authority. A critical missing prerequisite means NO-GO.

**P4/P5:** only after explicit operator GO, perform selected supported transition and controlled production DNS/traffic cutover, then prove actual outside-client authentication, security, first naturally scheduled backup with independent remote verification, and agreed observation period. Reboot is separately authorized; the Worker is intentionally unarmed following reboot.

Never claim a binary-only rollback restores persistent data or package state.
