# Noble Host Acceptance and Same-Host DR

`utilities/noble-host-acceptance.sh` is a release/DR acceptance controller for a real Ubuntu 24.04 LTS Noble host. It complements the permanent Bash test inventory; it does not replace `./tests/run-tests.sh all` or reimplement backup, restore, uninstall, storage, systemd, smoke, or drill logic.

Use this workflow periodically on a disposable acceptance host or snapshot, not as a routine day-to-day health check. A full pass is intentionally destructive and can perform real external DNS changes, so use a dedicated acceptance hostname/zone and credentials.

## Full-certification boundary

A full run proves the repository's supported Noble host path by orchestrating:

1. the canonical permanent Bash suites;
2. live health, email, pre-production drill, and smoke checks;
3. the external application E2E hook, which creates/records the DR canary;
4. an explicit DB backup plus a **new full backup created after the canary**, with that full backup's exact basename, archive SHA-256, authenticated cohort digest, and rclone location checkpoint-bound;
5. installed systemd validation and one foreground start of each managed recurring job, with the DNS updater protected by an explicit external-mutation gate;
6. Docker daemon restart followed by smoke testing;
7. a real reboot, verified by Linux boot ID;
8. canonical `--test-reset` uninstall plus independent residual assertions;
9. exact re-download of the checkpoint-bound full backup cohort from rclone and restore of that staged file using the external pre-DR recovery kit and `--start-policy manual`;
10. an immediate post-restore checkpoint **before** permission repair, startup, health, email, drill, or E2E validation, so a later validation failure cannot repeat a successful destructive restore;
11. post-restore health, email, drill, and application E2E while recurring timers remain inactive, including assertion of the same pre-DR canary;
12. durable custody of the newly rotated recovery kit on a non-root mounted recovery medium, with its Age identity proven to match the live rotated operational key and to differ from the pre-DR identity;
13. only then, activation and canonical validation of systemd automation, protected again by the DNS mutation scope gate;
14. fresh DB and fully verified full rclone recovery points encrypted to the new operational recipient; and
15. exact re-download of that final full backup and an `age` decrypt probe using the **copied post-restore recovery kit itself**.

`FULL ACCEPTANCE PASSED` is reachable only after the real-reboot, exact-source destructive DR, rotated-recovery-custody, external-mutation, automation, final-backup, and copied-kit remote-decrypt gates succeed.

## Checkpoint integrity

The controller stores root-only checkpoint state under `/var/tmp/vaultwarden-noble-acceptance` by default. The checkpoint contains no credential values. It binds a run to:

- the exact Git commit SHA;
- the host machine identity;
- the original and pre-reboot Linux boot IDs;
- the rclone remote name, subpath, config path, and config digest;
- the pre-DR recovery-kit path and digest;
- the application E2E hook path and digest;
- the explicitly acknowledged DNS mutation hostname;
- destructive/non-destructive mode and DNS-mutation consent;
- the reboot policy;
- for destructive runs, the canonical project-state path;
- the exact canary-inclusive DR source full-backup identity and digests; and
- after restore, the copied rotated recovery-kit path/digest and recipient binding.

`resume` fails if any bound operator input changes. The controller compares `/proc/sys/kernel/random/boot_id` with the saved pre-reboot value, so rerunning `resume` without rebooting cannot satisfy the reboot gate.

`--skip-reboot` exists only for controller development. A run started with it is permanently non-certifying and terminates at the `incomplete` phase. Re-running without the flag is rejected as checkpoint drift.

## Host/storage boundary

Destructive same-host DR intentionally supports **boot-volume project state only**.

The controller does not maintain a parallel storage detector. Before destructive work it sources the canonical uninstaller in dry-run mode, calls its `resolve` path, and applies the same `DATA_VOLUME_DEVICE` and `storage_ambiguous` checks used by destructive uninstall. This catches explicitly configured attached storage as well as incompletely described custom mounts, managed mount guards, and other ambiguous separate-volume evidence.

The production uninstaller correctly preserves separately attached data-volume contents. Therefore an attached-volume same-host reset is not a clean replacement-host simulation and is rejected. Test attached-volume DR on a fresh replacement host or with a disposable replacement block volume instead of weakening uninstall safety.

## Required external inputs

Before starting, prepare:

- a root-owned `0400` or `0600` pre-DR recovery kit outside all managed VaultWarden paths;
- a root-owned `0400` or `0600` rclone configuration outside all managed VaultWarden paths;
- the exact rclone subpath used for the acceptance backups;
- a root-owned executable application E2E hook that is not group- or world-writable; and
- a dedicated acceptance hostname/zone whose configured runtime `DOMAIN` you explicitly authorize the drill to mutate.

The pre-DR recovery kit and rclone config must survive `utilities/uninstall-vaultwarden.sh run --test-reset`.

The E2E hook is executed as root. The controller rejects symlinks, non-root ownership, non-executable files, and group/world-writable hooks. Its path and digest are bound to the checkpoint.

## External DNS mutation safety

`vaultwarden-dns-update.service` can issue a real Cloudflare update for the configured `DOMAIN`. A disposable VM is therefore **not** enough isolation if it carries production DNS credentials and the production hostname.

Full acceptance requires all of the following:

- `--dns-mutation-domain <dedicated-acceptance-hostname>`;
- `--allow-dns-mutation`;
- `VW_NOBLE_TEST_DNS_MUTATION=YES`; and
- immediately before the foreground DNS job and again before post-restore timer activation, the installed runtime `DOMAIN` must exactly equal the acknowledged hostname.

The controller deliberately does not guess whether a hostname is "production". The operator must use a dedicated acceptance hostname/zone and explicitly name the record that may be changed. If the restored runtime environment points at a different hostname, the run stops before DNS mutation/timer activation.

## Application E2E and exact DR source contract

The hook is external because this repository does not own a browser/client automation framework. It must exit non-zero on any failed assertion and should use disposable acceptance identities/data. At minimum prove:

- user login;
- vault item create/read/update/delete;
- organization membership/sharing;
- attachment upload/download;
- Send creation/readback/removal;
- logout/login persistence;
- supported client sync;
- WebSocket/live-update behavior where applicable; and
- admin endpoint protection.

On the pre-DR invocation, create/record a unique canary such as `NOBLE-DR-CANARY-<run-id>`. **Only after that hook succeeds** does the controller create the full DR source backup. It snapshots the full-backup inventory before/after that command and requires exactly one newly published full backup. That backup's exact basename, archive digest, cohort digest, creation time, and remote object identity are checkpointed.

After uninstall, the controller does not call `restore.sh latest`. It downloads the four required members of that exact remote cohort (`.age`, `.sha256`, `.sha256.hmac`, `.meta`) into the root-only acceptance state area, verifies the archive and cohort digests against the checkpoint, and calls canonical restore with `--file` on that staged full backup. The post-restore E2E invocation must find the same canary.

## Start a full run

```bash
sudo install -o root -g root -m 0600 /secure/recovery-kit.txt /root/vw-acceptance-recovery-kit.txt
sudo install -o root -g root -m 0600 /secure/rclone.conf /root/vw-acceptance-rclone.conf
sudo install -o root -g root -m 0700 /secure/vw-application-e2e.sh /root/vw-application-e2e.sh

sudo env \
  VW_NOBLE_TEST_DESTRUCTIVE=YES \
  VW_NOBLE_TEST_DNS_MUTATION=YES \
  utilities/noble-host-acceptance.sh run \
  --destructive \
  --recovery-kit /root/vw-acceptance-recovery-kit.txt \
  --rclone-remote myremote \
  --rclone-path vaultwarden_acceptance \
  --rclone-config /root/vw-acceptance-rclone.conf \
  --application-e2e /root/vw-application-e2e.sh \
  --dns-mutation-domain vw-acceptance.example.com \
  --allow-dns-mutation
```

The destructive path requires **both** `--destructive` and `VW_NOBLE_TEST_DESTRUCTIVE=YES`. External DNS mutation separately requires `--allow-dns-mutation` and `VW_NOBLE_TEST_DNS_MUTATION=YES`.

## Reboot checkpoint

At the reboot phase the controller saves the current boot ID, changes its checkpoint to `post-reboot`, and exits `75`. Reboot the host, verify the same checkout is present, then rerun exactly the same bound options and environment acknowledgements with `resume`.

The resume fails unless the host boot ID changed and all checkpoint-bound inputs still match.

## Restore checkpoint and resumability

The destructive restore sequence is:

1. exact checkpoint-bound remote cohort download and digest verification;
2. canonical `restore.sh interactive --file <staged-full-backup> --from-recovery-kit ... --no-backup --start-policy manual --force`;
3. record restore completion and the restored backup identity; and
4. **immediately checkpoint `post-restore-validation`**.

Only the next phase performs permission repair, startup, manual systemd installation, health, email, pre-production drill, and post-DR application E2E. If any of those checks fail, `resume` restarts `post-restore-validation`; it does not repeat the already successful restore or rotate the Age key again.

## Rotated recovery custody is mandatory

A successful canonical full restore rotates to a new operational Age key. Future backups therefore require the **new** recovery material; the pre-DR kit used to enter the drill is not sufficient custody for the recovery points created afterward.

At `recovery-custody` the controller stops until the newly generated recovery handoff is copied to durable off-host storage. Resume with the same bound options plus:

```text
--post-restore-recovery-kit /mnt/recovery/vaultwarden-recovery-kit-<timestamp>.txt
```

The supplied post-restore kit must:

- be a root-owned `0400`/`0600` regular file, not a symlink;
- be outside managed VaultWarden paths;
- reside on a mounted filesystem whose device differs from the root filesystem;
- be newer than the completed restore;
- contain the canonical recovery-kit completion marker and exactly one Age private identity;
- have a digest different from the pre-DR recovery kit;
- derive the **same Age recipient as the live `/etc/vaultwarden/age-key.txt`**; and
- derive a recipient different from the pre-DR recovery kit.

After automation is activated, the final full backup is created with full verification and rclone delivery. The controller binds that exact backup, re-downloads the exact encrypted archive from rclone, extracts the Age identity from the copied post-restore kit into a root-only temporary file, and performs an `age -d ... -o /dev/null` decrypt probe. A run cannot reach `FULL ACCEPTANCE PASSED` merely because the kit looks valid; the copied retained identity must actually decrypt the final offsite ciphertext.

## Evidence to retain

For the release/commit being certified, retain:

- exact Git SHA and host inventory;
- controller checkpoint metadata and logs;
- pre- and post-DR smoke output;
- pre-DR E2E/canary output;
- the exact bound DR source backup basename, archive SHA-256, cohort digest, and rclone location;
- uninstall output and residual result;
- exact-source restore output and the immediate post-restore checkpoint;
- post-restore E2E proof of the same canary;
- evidence that the copied rotated recovery kit's recipient matches the live rotated key;
- DNS mutation-scope checks for the dedicated acceptance hostname;
- final DB/full rclone backup verification; and
- the copied recovery kit's successful decrypt probe against the exact final offsite full backup.

The PR/commit is not real-host certified until one full destructive run on a disposable supported Noble host completes with retained evidence. CI and mocked contract tests cannot substitute for that run.
