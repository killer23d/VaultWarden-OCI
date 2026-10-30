# Ubuntu 26.04 ARM64 production acceptance — operator runbook

This audit is pinned to the reviewed `v2` source commit `e0f961c9093e98139e4f57bc94c49c9b79bbc386` and release `0.1.0-rc.11`. The new branch is an **audit harness**, not a new appliance release. Nothing here authorizes production DNS changes, destructive restores, disk formatting, retention changes, or a production deployment.

## Execution sequence and current classification

| Stage | Host | Mutability | Current result |
|---|---|---|---|
| 01. Read-only inventory, identity, runtime and automation inspection | Ubuntu 26.04 ARM64 acceptance host | Read-only to appliance; creates evidence under user home | NOT RUN until operator executes |
| A. Independent fresh-host disaster recovery | Separate disposable Ubuntu 26.04 ARM64 with a separately provisioned data volume | Initially read-only; later restore is destructive and separately authorized | NOT RUN |
| B. Observe a real unattended backup timer activation and verified cloud readback | Installed acceptance host | Existing timer operation only; writes a normal backup and remote object | NOT RUN |
| C. Cold reboot, service/security and notification observation | Disposable acceptance host | Deliberate reboot and message delivery, separately approved | NOT RUN |
| D. Cutover/rollback documentation and GO/NO-GO | Production design only | No changes to production DNS or host | NOT RUN |

Ubuntu 26.04 ARM64 is supported in the code, but previously documented real OCI 26.04 host acceptance is NOT RUN. Do not interpret CI or older Ubuntu 24.04 acceptance as proof of this new combination.

## First command

Run the one-shot checkout and audit command provided in the operator conversation, from the intended Ubuntu 26.04 ARM64 machine. Use the normal SSH login account with passwordless `sudo -n`. The script refuses the wrong OS or architecture, wrong source branch/baseline, an unclean checkout, and unexpected changes to release-owned paths.

It does not use `setup.sh`, `vwctl backup`, `vwctl restore`, `vwctl dns update`, `rclone sync`, or `systemctl start`. It never reads or prints Age private identities, SOPS plaintext, rclone configuration, or Cloudflare tokens. Its JSON files and command error files are private operator evidence, not chat attachments.

Evidence directory: `~/vwoci-acceptance/phase1-readonly-<UTC timestamp>/`; start by posting only **summary.txt**, without revealing any private identities, tokens, or unredacted logs. The command may return nonzero for an expected blocked/incomplete gate; that must not be called a pass.

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
