# Ubuntu 26.04 ARM64 production acceptance — operator runbook

This audit is pinned to the reviewed `v2` source commit `e0f961c9093e98139e4f57bc94c49c9b79bbc386` and release `0.1.0-rc.11`. The new branch is an **audit harness**, not a new appliance release. Nothing here authorizes production DNS changes, destructive restores, disk formatting, retention changes, or a production deployment.

## Execution sequence and current classification

| Stage | Host | Mutability | Current result |
|---|---|---|---|
| 01. Read-only inventory, identity, runtime and automation inspection | Ubuntu 26.04 ARM64 acceptance host | Read-only to appliance; creates evidence under user home | NOT RUN until operator executes |
| A0. Fresh-host disk inventory and root-disk refusal | New Ubuntu 26.04 ARM64 instance | Read-only; installer is invoked only with --dry-run and the root disk, which must be rejected | PASS (operator transcript 2026-10-30) |
| A1. Selected-by-id-volume setup dry-run | Same disposable Ubuntu 26.04 ARM64 instance | Read-only; synthetic public Age recipient used strictly for dry-run | PASS read-only checks and manual attachment confirmation; no format authorized yet |
| A2. Pinned release installation | Confirmed disposable OCI Ubuntu 26.04 ARM64 host, exact by-id block volume | Explicit typed per-volume erase consent is required; installs dependencies, source-pinned rc.11, initial SOPS but does not start or restore | NOT RUN |
| A. Independent fresh-host disaster recovery | Separate disposable Ubuntu 26.04 ARM64 with a separately provisioned data volume | Initially read-only; later restore is destructive and separately authorized | NOT RUN |
| B. Observe a real unattended backup timer activation and verified cloud readback | Installed acceptance host | Existing timer operation only; writes a normal backup and remote object | NOT RUN |
| C. Cold reboot, service/security and notification observation | Disposable acceptance host | Deliberate reboot and message delivery, separately approved | NOT RUN |
| D. Cutover/rollback documentation and GO/NO-GO | Production design only | No changes to production DNS or host | NOT RUN |

Ubuntu 26.04 ARM64 is supported in the code, but previously documented real OCI 26.04 host acceptance is NOT RUN. Do not interpret CI or older Ubuntu 24.04 acceptance as proof of this new combination.

## First command

Run the one-shot checkout and audit command provided in the operator conversation, from the intended Ubuntu 26.04 ARM64 machine. Use the normal SSH login account with passwordless `sudo -n`. The script refuses the wrong OS or architecture, wrong source branch/baseline, an unclean checkout, and unexpected changes to release-owned paths.

It does not use `setup.sh`, `vwctl backup`, `vwctl restore`, `vwctl dns update`, `rclone sync`, or `systemctl start`. It never reads or prints Age private identities, SOPS plaintext, rclone configuration, or Cloudflare tokens. Its JSON files and command error files are private operator evidence, not chat attachments.

Evidence directory: `~/vwoci-acceptance/phase1-readonly-<UTC timestamp>/`; start by posting only **summary.txt**, without revealing any private identities, tokens, or unredacted logs. The command may return nonzero for an expected blocked/incomplete gate; that must not be called a pass.

## Recorded operator evidence (2026-10-30)

The operator supplied transcript from OCI host `vaultwarden-oci-5-vnic` for Stage 01 and A0. The audit checkout was pinned to `24653224ce291bc2a43da2fc3cafb350ee2ccc3a` at Stage A0. The supplied output confirms Ubuntu 26.04 ARM64, native Python 3.14, passwordless sudo, absence of installed appliance paths and active/enabled appliance automation, a root device of `/dev/sdb1`, and one unmounted 50.00 GiB non-boot disk candidate `/dev/sda`, reachable through stable by-id `/dev/disk/by-id/scsi-36015f8fecf5e4f7ab864af5a651cc628`. The installer rejected the root device under `--dry-run` and left appliance paths absent. This supports **A0 PASS** as a non-mutating host preflight; it does not prove provider-side OCI block-volume ownership.

A0 evidence was reported at `~/vwoci-acceptance/gate-a0-fresh-host-20261030T195359Z`; the full evidence directory remains on the host and was not uploaded. No recovery data or credentials have been supplied. A1 and later gates remain **NOT RUN**; any action to format or adopt a disk remains **BLOCKED pending explicit operator verification and authorization**.

### A1 exact selected-volume dry-run

Run `tests/host-acceptance/03-selected-volume-dryrun.sh` using the by-id path and the independently recorded **expected exact size in bytes**, not the mutable `/dev/sda` spelling. The script verifies source purity, OS, absent appliance state, root-disk ancestry, disk type/size/unmounted status, absence of signatures/partition children, and that the existing installer accepts that exact by-id candidate under `--dry-run`. It also requires the installer to reject an intentionally nonexistent disk and checks that no disk metadata or appliance paths changed.

This stage deliberately passes a **syntactic test-only Age recipient** to `setup.sh --dry-run`. That fixture has no usable private key and **must never** be used for a real installation or recovery. The actual matching offline Age recipient must be derived from the independently held off-host identity **before any real installation**. This test does not exercise credential custody, Box access, restore, Cloudflare, or CrowdSec.

The script deliberately exits nonzero when its read-only tests have passed but OCI block-volume ownership remains unverified: this reports that the next destructive stage is still **BLOCKED**, rather than suggesting implicit formatting permission.


### A1 supplied operator results (2026-10-30)

The operator provided the `summary.txt` and `device-report.txt` contents for the A1 selected-volume dry run, repeated twice. Accepted facts: stable path `/dev/disk/by-id/scsi-36015f8fecf5e4f7ab864af5a651cc628` resolves to `/dev/sda`; the root source is `/dev/sdb1`; selected volume has exactly `53,687,091,200` bytes (50.00 GiB); no mounted filesystems, partition children or recognized signatures; and the installer accepted this exact target under `--dry-run` while refusing a nonexistent target. The device metadata and appliance paths remained unchanged. Read-only checks **PASS**; intentionally reported **BLOCKED** is retained for provider-side attachment ownership and explicit formatting authorization.

Next operator action is manual: inspect **Compute → Instances → the disposable instance → Storage → Attached block volumes** in OCI Console. Check that the intended **50 GiB** data volume is attached to this exact instance and is not a boot, production, shared, or otherwise valuable volume. Oracle documents an optional **Device path** field in attachment details; if present, compare it to the matching `/dev/oracleoci/*` symlink on the guest. Do not assume a SCSI `/dev/disk/by-id` identifier equals a volume OCID. A console-facing name/size alone without an unambiguous match should be treated as requiring further review. Do not run any `mkfs`, installer `--confirm-format`, or restore until the operator separately confirms volume ownership and explicitly authorizes the destruction of exactly that volume.

Independent off-host recovery prerequisites also remain untested: the existing offline Age private key must already be accessible off-host (or recoverable from the separately held password-protected recovery-kit ZIP), the matching **public recipient** must be known for setup, and Box credentials must be recoverable independently from the old instance. Never create a new offline identity for an old encrypted recovery point. Never transmit private Age keys, ZIP passphrases, rclone credentials, or Cloudflare tokens in chat.


### Manual OCI attachment confirmation and A2 controls (2026-10-30)

The operator explicitly confirmed the intended attached storage is correct. The guest output showed `/dev/disk/by-id/scsi-36015f8fecf5e4f7ab864af5a651cc628` -> `/dev/sda`, identical to OCI guest alias `/dev/oracleoci/oraclevdb`; `lsblk` reported 50 GiB, model `BlockVolume`, serial `6015f8fecf5e4f7ab864af5a651cc628`, and root is `/dev/sdb1`. These facts support **A1 PASS** and manual volume-ownership review. They do not authorize an erase until the operator provides a distinct final typed confirmation.

Next: `tests/host-acceptance/04-pinned-install-authorized.sh` is **a controlled destructive disposable-host installation stage**, not a recovery or DNS test. It runs only on the expected OCI guest and accepts no parameters. Before any formatting, it rechecks clean fresh-host state, identical immutable rc.11 source, native Ubuntu 26.04 ARM64, stable disk serial, exact capacity, OCI guest alias, unmounted/no-partition/no-signature status, and the product root-disk guard. It then requires:

- Existing `age1...` PUBLIC offline recipient, derived on a trusted separate workstation from the matching pre-existing private recovery identity; never generate a new key for this old recovery point. The separately held recovery-kit ZIP and passphrase and independent Box access remain operator responsibilities.
- A non-mutating real `setup.sh install --auto --dry-run` using the exact site arguments and public recipient. No `--use-latest`.
- A final typed `ERASE <exact-disk-serial>` acknowledgement **after** displaying the exact target. Disk identity/signatures are rechecked once more immediately before invoking the supported installer with `--confirm-format --auto`.

This install is expected to format the single data disk as ext4, install supported host dependencies and publish the rc.11 immutable release, generate a **new operational** Age identity, and initialize SOPS addressed to the **existing offline public** recipient. This is not a restoration and does not create a replacement offline private identity. Verification confirms `storage.verify()`, installed release hash parity, protected file ownership, recipient preservation, initial disabled offsite publication, retention=0 and disabled application/backup/DNS units. **No `vwctl dns update`, `systemctl enable --now`, `vwctl restore`, `vwctl start`, `vwctl backup`, Cloudflare Worker activation, or unattended backup invocation occurs.**

This stage is **BLOCKED** until the operator has both independent key custody and exact typed format consent. If setup fails after formatting begins, retain private logs and **do not blindly rerun `--confirm-format`**, since the appliance may be partially installed; review the point of interruption first. Even an A2 PASS leaves independent Box readback, offline Age decryption and a separately authorized real restore as **NOT RUN**.

Keep detailed install logs local under `~/vwoci-acceptance/gate-a2-install-<UTC timestamp>/`; share `summary.txt` and `post-install.txt` first. NEVER paste offline Age private identities, ZIP passphrases, OAuth or Cloudflare tokens.

## Gate A0 — next operator preflight

Once Stage 01 confirms the host is fresh and uninstalled, run `tests/host-acceptance/02-fresh-host-preflight.sh` on **that same host**. It inventories non-boot devices via the existing `vaultwarden_oci.storage.inventory()`, lists filesystem signatures with read-only `wipefs --noheadings --output TYPE`, and verifies that the actual `setup.sh install --auto --dry-run` refuses the boot/root device.

This test is **not installation authorization**, even when it prints candidate disks. The operator must review the output, validate the actual OCI block-volume attachment, and explicitly select a stable device path for subsequent dry-run and installation work. Do not set `--confirm-format` or `--accept-existing-filesystem` in Gate A0.

Evidence lives in `~/vwoci-acceptance/gate-a0-fresh-host-<UTC timestamp>/`. Share only `summary.txt` and `candidates.txt`. Keep raw stderr, filesystem inventories, and other local files private by default.

The Stage A0 script creates **no installed appliance**, does not mount or format any disk, and does not touch DNS, CrowdSec, Box, Age identities, or backups. All later stages remain NOT RUN.

## What this first step does and does not prove

- Compares the installed immutable release-owned tracked files against the precise approved base commit, not against potentially changed audit-branch files.
- Checks dedicated storage via the project's existing `storage.verify()` method, including identity and volume marker.
- Checks the persisted update-recovery guard exists/does not exist without opening it.
- Safely reads only selected backup config fields: whether offsite is configured, both retention day counts, and whether operational notifications are configured.
- Calls the supported read-only `vwctl doctor --json`, `status --json`, and `timers --json`; captures only whitelisted systemd properties, not unit environment values or journal bodies.
- Does **not** prove that a fresh-host recovery succeeds, a scheduled timer has actually fired, that Box stores decryptable archives, that notifications are delivered, or that services survive reboot. Those stay NOT RUN.

On a truly fresh and uninstalled host the read-only audit captures hardware/OS basics and reports runtime stages NOT RUN; the separate installation and recovery sequence will be prepared after evaluating its output. The acceptance host must never be assumed disposable merely because this script ran.

## Safety boundaries for subsequent stages

1. Keep production and disposable hosts clearly distinguished. Before any restore, gather a separate operator confirmation of exact host, disk, and recovery point. Never automate entry of the `RESTORE` confirmation.
2. Before installing a fresh host, independently select dedicated storage, check root-disk ancestry, and use the supported setup flow with separately held Age/recovery-kit custody. The audit script does not provision storage.
3. Use a staging hostname or isolated Cloudflare zone. Do not move the existing production record. Ensure recovery-host DDNS will not publish a test host address for the production hostname.
4. Observe the original `vaultwarden-oci-backup.timer`; never add a second remote timer or manually invoke `vwctl backup` and label it a timer activation.
5. Keep `local_retention_days = 0` and `remote_retention_days = 0` through recovery acceptance. Never run prune or destructive rclone sync.
6. On reboot testing the Cloudflare CrowdSec Worker may intentionally require re-arming with fresh Fail Open confirmation; document it accurately rather than automatically marking boot-time unarmed state as corruption.
7. Any `FAIL`, unexpected retention, guard, or conflicting DNS authority blocks mutation pending review.
8. No PR merge, version update, or deployment is automatic.

## Evidence handling

`summary.txt` is the first-review surface. Review all files for private host information before sharing; `*.stderr`, raw `doctor.json`, and `status.json` should remain local until specifically required. A successful read-only audit is only readiness to *plan* the next test, not a production GO decision.

## Preliminary implementation coverage (source audit)

| Area | Source evidence | Remaining real-host evidence | Risk/class |
|---|---|---|---|
| Ubuntu 26.04 ARM64 | Native Python 3.14 and supported release/architecture validation in `vaultwarden_oci/cli.py` | 26.04 OCI instance compatibility | Requires acceptance |
| Dedicated disk | `storage.verify()` with block identity/marker, guard and boot-device ancestry | New disk install, fail-closed missing-volume checks | Requires acceptance |
| Offline custody + recovery | `vaultwarden_oci/recovery.py`, `recovery_ux.py`; source docs distinguish recovery kit from `.vwrec` | Independent fresh-host readback, wrong-key/cancel, authorized real restore | Requires acceptance |
| Encrypted local/remote backups | `vaultwarden_oci/offsite.py` and recovery modules implement same-invocation publication | Real unattended scheduled job and Box checksum readback | Requires acceptance |
| Automation | Four supported timers; health service separately invokes DNS service; backup timer invokes `vwctl backup` | Timer activation and post-run service record | Requires acceptance |
| Reboot/security | `vaultwarden-oci.service` and supported CrowdSec/Cloudflare policy | Real reboot, firewall and Worker recovery | Requires acceptance |
| Notifications | Optional HTTPS provider distinct from Vaultwarden SMTP in `vaultwarden_oci/notification.py` | Delivered message and injected failure on disposable host | Requires acceptance |
| Production cutover | `docs/INSTALL.md`, `OPERATIONS.md`, `RECOVERY.md`, `SECURITY.md` | Approved checklist, rollback/incident runbook and operator signoff | Requires acceptance |

Historical rc.11/24.04 evidence reported in the task brief is useful context, not new 26.04 host evidence. No source defect has yet been reproduced; no appliance code change is proposed.

**Overall release decision: NO-GO pending A–D operator evidence.**
