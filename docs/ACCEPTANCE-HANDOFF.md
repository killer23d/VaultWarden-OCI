# ARM64 release acceptance handoff

This is the **current, sanitized operator handoff** for the Ubuntu 26.04 ARM64 Oracle Cloud release acceptance completed on October 30–31, 2026. Read this before the chronological [full acceptance runbook](PRODUCTION-ACCEPTANCE-UBUNTU2604.md) and the historical [host-specific scripts](../tests/host-acceptance/README.md). Earlier dated statements such as "NOT RUN" or "draft PR" describe the state *at that time*, not the final accepted result.

**Scope and authority:** This is evidence of a release-candidate source and disposable-host exercise, **not authorization for a production deployment**. The durable product invariants remain [Project boundary](PROJECT-BOUNDARY.md) and [Decisions](DECISIONS.md). The current installer/update/recovery commands are documented in [Install](INSTALL.md), [Operations](OPERATIONS.md), [Recovery](RECOVERY.md), and [Host acceptance](HOST-ACCEPTANCE.md).

## 1. Source and integration provenance

- Original frozen production-design/source baseline: release `0.1.0-rc.11`, commit `e0f961c9093e98139e4f57bc94c49c9b79bbc386`. An earlier development/gate audit branch is *historical evidence only*.
- [PR #374](https://github.com/killer23d/VaultWarden-OCI/pull/374): archived the original 23 numbered host-gate scripts, this acceptance runbook and the safety README. Merged at `3053c79e7d4c2a0f03456b9ee0a360282f54b5c0`.
- [PR #373](https://github.com/killer23d/VaultWarden-OCI/pull/373): corrected SOPS same-filesystem atomic publication, added a secure encrypted recovery-kit ZIP **explicit file-path** choice, regression tests and new gate scripts `24`–`26`. Final tested PR source `14157d32eb6e9be616b73acb4de132b3be0bf16b`; merged at `8154fe33600b0bae3f0793aa876c3eee2fe7306c`.
- [PR #375](https://github.com/killer23d/VaultWarden-OCI/pull/375): reconciled the chronological runbook with D1 interrupted, D1R PASS, D2 PASS and explicitly unexecuted production cutover. Merged at `9b2104c61ce8e942c19e8458fb47048a11677b9c`.
- At the start of this handoff cleanup, the protected release branch was `9b2104c61ce8e942c19e8458fb47048a11677b9c`, and `versions.toml` selected `0.1.0-rc.12`. **Re-read the actual current branch/commit before making decisions:** handoff documentation changes can advance its HEAD. All nine jobs passed on the post-merge branch, in addition to the final corrective PR's nine push and nine PR jobs.
- The corrections are **implemented in product owners**, not acceptance-only patches: `vaultwarden_oci/setup.py` publishes the SHA-verified SOPS binary from a staged file on the target filesystem before its atomic replacement; `vaultwarden_oci/recovery_ux.py` supports selecting and securely staging an AES-256 encrypted ZIP at an explicit absolute path. Permanent regressions protect these changes.

## 2. Actually observed gate results

| Gate | Host and observed scope | Final classification |
| --- | --- | --- |
| A0–A2/A2R | Disposable Ubuntu 26.04 ARM64 fresh host; stable separate volume selected, root-device refusal and setup dry-run, initial EXDEV SOPS error on frozen rc.11, then safe same-volume continuation with a temporary-filesystem workaround | **PASS after A2R**; original A2 interruption documented |
| A3 | Independent **read-only** streaming/checksum of known Box encrypted recovery object from configured root rclone remote | **PASS** |
| A4 | Correct off-host Age identity used to verify genuine encrypted remote recovery ciphertext without changing live data | **PASS** |
| A5 | Encrypted kit chooser plus forced cancellation *before* destructive real Box restore; no data promotion | **PASS** |
| A6 | Authorized disposable-host real restore of known `.vwrec`; SQLite integrity, state/keys/storage checked; services left stopped | **PASS** |
| B0 | Cloudflare-only Docker HTTPS-origin ingress and split CrowdSec host INPUT/Worker security ownership | **PASS** |
| B1 | Dev hostname, manual current Worker Route **Fail Open** attestation, secured Vaultwarden/Caddy start, real Box backup uploaded and re-downloaded with checksum, four original timers, zero doctor failures | **PASS** |
| B2 | Natural **unchanged** 03:15 calendar backup timer; actual trigger **2026-10-31 03:23:17 UTC**, successful local recovery verification and Box readback, retention **0/0** | **PASS** |
| C1 | Genuine cold reboot (changed kernel boot ID), preserved config/SOPS/Age, SQLite, mounted disk, app and all four timers; **manual new-invocation** Worker Fail Open verification; real HTTPS operational and authenticated TLS SMTP transports accepted | **PASS**; inbox receipt not independently proved |
| D1 | Different freshly provisioned Ubuntu 26.04 ARM64 host, blank 50 GiB non-boot disk; real rc.12 setup dry-run; first install formatted/mounted disk but terminated before immutable release/SOPS publication | **INTERRUPTED — NOT PASS**; cause of original interruption **unknown** |
| D1R | Same fresh-image host; independent dual storage markers, existing mounted ext4, no competing package mutation, supported `--accept-existing-filesystem` without formatting; real `/run` vs `/usr/local/bin` SOPS publication, pinned hash, immutable rc.12, secrets/Age, root-only modes, native recovery-path regressions | **PASS** |
| D2 | Same rc.12 host; original AES-256 encrypted recovery-kit ZIP from an **explicit absolute path outside the default chooser**, product option 4, hidden passphrase, exact Age recipient matching and private temporary-file cleanup | **PASS**; no vault restore performed |
| Production deployment / cutover and rollback GO-NO-GO | Real production host, DNS, maintenance window, old/new state, client verification and rollback | **NOT RUN — operator decision required** |

**Original D1 versus D1R distinction matters.** During D1R, an `apt-get` child was seen in Linux stopped state `T+`. A verified, one-time `SIGCONT` allowed the **existing** installer to finish. The source of that stop signal was not established. Do not mislabel the *first* D1 attempt as a product crash caused by `apt-get`, nor claim an uninterrupted blank-host installation. The idempotent same-volume continuation **passed** and did not format a second time.

## 3. Evidence and machine boundaries

- Original rc.11 acceptance VM: `vaultwarden-oci-5-vnic`. Its source release remained frozen for A/B/C tests. Historical evidence root: `/home/ubuntu/vwoci-acceptance`; B1 `gate-b1-dev-operating-20261030T232046Z`; C1 `gate-c1-dev-reboot-20261031T055324Z`; B2 `gate-b2-natural-timer-20261031T060722Z`. A3–A6 evidence paths are in the chronological runbook.
- Corrected rc.12 installer VM: `vaultwarden-oci-6-vnic`, with a **different** dedicated 50 GiB volume (full by-id/serial proof is in the runbook). The first attempt: `/home/ubuntu/vwoci-rc12-acceptance/clean-install-20261031T063818Z`; successful continuation: `/home/ubuntu/vwoci-rc12-acceptance/resume-d1-20261031T070041Z`.
- The actual D2 operator transcript reported PASS for product option 4, AES-256 ZIP verification, public recipient match and volatile plaintext cleanup. The temporary encrypted ZIP copy on the test VM was removed by the operator's successful wrapper. This **does not independently prove** custody of the original ZIP/passphrase remains off-host.
- The acceptance scripts `tests/host-acceptance/01`–`26` are **host-specific historical instruments**. Some format disks, restore state, update DNS, publish Box objects, send real email or reboot. Do not run blindly on production, edit their pinned host checks to force PASS, or incorporate them in production timers.
- Private logs, operational/offline Age private material, ZIP passphrases, decrypted SOPS, rclone secrets, SMTP credentials, and Cloudflare tokens are **not** in this repository. Keep diagnostic output private until sanitized. Share concise summaries, commit IDs, checks, and hashes only.

## 4. Acceptance methodology to preserve

1. **Pin** the precise reviewed source commit, OS/architecture and installed release; check branch cleanliness/lineage and exact change scope.
2. **Prove identity** before mutating: whole device, independent OCI attachment/serial/size, boot ancestry, dedicated mount UUID, host-side and on-volume markers, verified offline **public** recipient. Never infer the target from a reused `/dev/sdX` name.
3. **Classify first**, preserve evidence: distinct `PASS`, `FAIL/BLOCKED`, `PENDING`, `NOT RUN`. A stalled or stopped process is not successful completion. Test harness errors and product defects are different categories.
4. **Fail closed**: no boot-disk fallback; no second format after a partial first-run; no unapproved restore, live DNS change, rclone write/prune, service enable, package removal or reboot. Recheck storage authority and installer state before any supported resumption.
5. **Use three proof layers**: focused regression tests, bounded real integrations, disposable ARM64 real-host gates. Ubuntu 26.04 ARM64 real-host evidence does **not** prove AMD64 real-host behavior; AMD64 coverage here is code/CI only.
6. **Keep security owners separate**: Cloudflare-only Docker origin filter, nftables CrowdSec host INPUT rules, CrowdSec Cloudflare Worker local-source remediation. Each **new Worker invocation** needs manual Cloudflare Route **Fail Open** inspection and fresh confirmation. The Worker is deliberately boot-disabled.
7. **Protect recovery**: local and remotely re-downloaded/checksummed `.vwrec`; operational versus offline Age; AES-256 ZIP versus `.vwrec`; final explicit `RESTORE` for any live promotion; recovery-aware rollback after potential persistent-state mutation.
8. **Verify original systemd scheduling**: real natural trigger, corresponding service journal and remote readback—not timer enabled state or a manually triggered backup.
9. **No fake success**: do not hardcode PASS, reset/redact exceptions as success, weaken verification checks or automatically retry an unsafe destructive step. No private log exports.
10. **Review integration**: record source SHA, exact PR diff and CI outcomes; ensure merged release-branch HEAD contains actual runtime changes. Historical test VM state is **not** altered by merging code.

## 4A. Follow-up accepted rc.12 inventory and next cryptographic gate (2026-11-01 UTC)

On `vaultwarden-oci-6-vnic`, the operator used merged release commit `2787243c93df024745260fa4e31a208796478edc`, which includes the corrected source-harness and bounded Box ciphertext readback from PR #380. **30 focused Python tests PASS; live P1 completed with final exit 0 (pre-restore classification PENDING)**. Direct Box `.vwrec` ciphertext readback (358680 bytes) matched historical A3/A4 SHA-256 `ee2b43a859ca85fb64ce20af67a3c862a2c2946ebf11df1e9fb95f880e235060`. Root Box remote exists and works for this read; source ciphertext access is no longer conjectural. Original dedicated disk, 52 release-owned files, 12 installed units, offsite 0/0 safety, dormant services/timers, Docker and NTP are verified. Existing `cloudflare_api_token` remains invalid/missing and CrowdSec/7zz is not deployed. **No real restore, original offline private Age identity verification, recovered SQLite, live security, production cutover or backup timer was run.**

Next **P2**: non-promoting encrypted archive proof using the product's secure chooser for an original off-host private Age identity/ZIP; never paste it in a transcript. Pin accepted source, prove unchanged host/disks/services, read and hash exact original ciphertext to swap-free root-private `/run` tmpfs, decrypt/validate manifest and recovered SOPS/SQLite, inspect restore target capacity/recovered retention policy without mutation, then clean temporary plaintext. The original ZIP is **not currently present** at the historical VM pathname and `7zz` may be missing: never silently install dependencies or substitute the operational Age key. P2 is an acceptance instrument, not a product update; production cutover GO remains separate and NOT RUN.

## 5. Unproven boundaries and next gate

**Completed:** original frozen rc.11 A/B/C operational/recovery/reboot gates, corrected rc.12 installer cross-filesystem and encrypted-kit-path feature gates, and merging all reviewed source, tests and evidence.

**Not proved:** unattended *first-pass* rc.12 installation end-to-end (the first attempt was interrupted); a full live rc.12 Caddy/CrowdSec/Box/timer/reboot operation (the corresponding successful real-host baseline used rc.11); production source deployment and subsequent access/monitoring; production rollback readiness/cutover; whether the real recipient received the test emails; real off-host custody of the original private kit; real-host AMD64. Do not convert these to PASS by inheritance.

**Next agent: read-only production planning before any mutation.**

1. Identify **actual intended production host and current serving release**, old host if migrating, DNS authority, downtime window, release source (pinned merged commit/release artifact), storage identity, current offsite backup status and available tested recovery identities. Do not assume either disposable test VM is production.
2. Compare *two candidate deployment routes*: supported in-place `vwctl update` from a verified supported predecessor **versus** fresh dedicated-volume setup followed by a verified `.vwrec` restore. Use existing `docs/OPERATIONS.md` and `docs/RECOVERY.md` contracts; do not switch the current symlink manually or use the candidate git tree as the update authority.
3. Produce a zero-mutation inventory/evidence bundle and an explicit **production GO/NO-GO checklist**: encrypted snapshot and independent offsite readback, verified offline identity and kit custody, SQLite/manifest validation, capacity and storage guards, exact candidate/version, Worker Fail Open, IPv4/IPv6/DNS authority, Caddy/Cloudflare/host firewall, CrowdSec ownership, `/admin` protections, SMTP/operational mail, four timers, health/doctor, rollback trigger and return path. Define acceptable interruption and recovery windows with the operator; never invent numbers.
4. On a separate disposable target, run **only unproven release-delta and rollback readiness checks** needed to choose the safe production path; don't rerun accepted rc.11 B2/C1 or rc.12 D1R/D2 simply to fill a checklist. A live rc.12 smoke/rollback drill requires its own approved dev endpoint and independent authorization of any mail, cloud backup, DNS or restore action.
5. Prepare an operator-reviewable sequence for production preflight, service freeze, confirmed encrypted backup, staged install/update/restore, credentials/worker/firewall gates, controlled DNS cutover, outside-client validation, first genuine backup/alert checks, and coherent rollback. No actual production mutation without the operator's explicit GO for that specific environment and operation.
6. Use the current repository and PR conventions. Correct defects in the smallest existing owner with regression tests/docs and a reviewable PR. Distinguish product fixes from acceptance-only evidence. A merged branch or passing CI alone does **not** authorize production cutover.

**Next production stage classification: NOT RUN.** Do not claim production success or choose the final target without verified operator-specific details.
