# Noble Host Acceptance and Same-Host DR

`utilities/noble-host-acceptance.sh` is a release/DR acceptance controller for a real Ubuntu 24.04 LTS Noble host. It complements the permanent Bash test inventory; it does not replace `./tests/run-tests.sh all` or reimplement backup, restore, uninstall, storage, systemd, smoke, or drill logic.

Use this workflow periodically on a disposable acceptance host or snapshot, not as a routine day-to-day health check. A full pass is intentionally destructive.

## Full-certification boundary

A full run proves the repository's supported Noble host path by orchestrating:

1. the canonical permanent Bash suites;
2. live health, email, pre-production drill, and smoke checks;
3. DB and full backups with rclone delivery, verification, sync, and remote inventory;
4. installed systemd validation and one foreground start of each managed recurring job;
5. Docker daemon restart followed by smoke testing;
6. an external application E2E hook before DR;
7. a real reboot, verified by Linux boot ID;
8. canonical `--test-reset` uninstall plus independent residual assertions;
9. full restore from rclone using an external recovery kit and `--start-policy manual`;
10. post-restore health, email, drill, and application E2E while recurring timers remain inactive;
11. durable custody of the newly rotated recovery kit on a non-root mounted recovery medium;
12. only then, activation and canonical validation of systemd automation;
13. smoke testing with active automation; and
14. fresh DB and fully verified full rclone recovery points encrypted to the new operational recipient.

`FULL ACCEPTANCE PASSED` is reachable only after the real-reboot, destructive-DR, rotated-recovery-custody, automation, and final-backup gates succeed.

## Checkpoint integrity

The controller stores root-only checkpoint state under `/var/tmp/vaultwarden-noble-acceptance` by default. The checkpoint contains no credential values. It binds a run to:

- the exact Git commit SHA;
- the host machine identity;
- the original and pre-reboot Linux boot IDs;
- the rclone remote name, config path, and config digest;
- the pre-DR recovery-kit path and digest;
- the application E2E hook path and digest;
- destructive/non-destructive mode;
- the reboot policy; and
- for destructive runs, the canonical project-state path.

`resume` fails if any bound input changes. The controller compares `/proc/sys/kernel/random/boot_id` with the saved pre-reboot value, so rerunning `resume` without rebooting cannot satisfy the reboot gate.

`--skip-reboot` exists only for controller development. A run started with it is permanently non-certifying and terminates at the `incomplete` phase. Re-running without the flag is rejected as checkpoint drift.

## Host/storage boundary

Destructive same-host DR intentionally supports **boot-volume project state only**.

The controller does not maintain a parallel storage detector. Before destructive work it sources the canonical uninstaller in dry-run mode, calls its `resolve` path, and applies the same `DATA_VOLUME_DEVICE` and `storage_ambiguous` checks used by destructive uninstall. This catches explicitly configured attached storage as well as incompletely described custom mounts, managed mount guards, and other ambiguous separate-volume evidence.

The production uninstaller correctly preserves separately attached data-volume contents. Therefore an attached-volume same-host reset is not a clean replacement-host simulation and is rejected. Test attached-volume DR on a fresh replacement host or with a disposable replacement block volume instead of weakening uninstall safety.

## Required external inputs

Before starting, prepare:

- a root-owned `0400` or `0600` pre-DR recovery kit outside all managed VaultWarden paths;
- a root-owned `0400` or `0600` rclone configuration outside all managed VaultWarden paths; and
- a root-owned executable application E2E hook that is not group- or world-writable.

The pre-DR recovery kit and rclone config must survive `utilities/uninstall-vaultwarden.sh run --test-reset`.

The E2E hook is executed as root. The controller rejects symlinks, non-root ownership, non-executable files, and group/world-writable hooks. Its path and digest are bound to the checkpoint.

## Application E2E contract

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

Create a unique canary such as `NOBLE-DR-CANARY-<run-id>` before DR and require the same canary after the rclone restore. This prevents a healthy but empty restored service from producing a false pass.

## Start a full run

```bash
sudo install -o root -g root -m 0600 /secure/recovery-kit.txt /root/vw-acceptance-recovery-kit.txt
sudo install -o root -g root -m 0600 /secure/rclone.conf /root/vw-acceptance-rclone.conf
sudo install -o root -g root -m 0700 /secure/vw-application-e2e.sh /root/vw-application-e2e.sh

sudo env VW_NOBLE_TEST_DESTRUCTIVE=YES \
  utilities/noble-host-acceptance.sh run \
  --destructive \
  --recovery-kit /root/vw-acceptance-recovery-kit.txt \
  --rclone-remote myremote \
  --rclone-config /root/vw-acceptance-rclone.conf \
  --application-e2e /root/vw-application-e2e.sh
```

The destructive path requires **both** `--destructive` and `VW_NOBLE_TEST_DESTRUCTIVE=YES`.

## Reboot checkpoint

At the reboot phase the controller saves the current boot ID, changes its checkpoint to `post-reboot`, and exits `75`. Reboot the host, verify the same checkout is present, then rerun exactly the same bound options:

```bash
sudo env VW_NOBLE_TEST_DESTRUCTIVE=YES \
  utilities/noble-host-acceptance.sh resume \
  --destructive \
  --recovery-kit /root/vw-acceptance-recovery-kit.txt \
  --rclone-remote myremote \
  --rclone-config /root/vw-acceptance-rclone.conf \
  --application-e2e /root/vw-application-e2e.sh
```

The resume fails unless the host boot ID changed and all checkpoint-bound inputs still match.

## Uninstall assertion

The controller delegates teardown to the canonical owner:

```bash
sudo utilities/uninstall-vaultwarden.sh run \
  --test-reset \
  --i-have-saved-my-recovery-kit \
  --force
```

Before uninstall, it resolves the boot-state scope again and requires the same project-state path recorded at run start. After uninstall returns success, the controller independently requires the original project-state path, `/etc/vaultwarden`, `/run/vaultwarden-oci`, generated checkout `.env`, and Compose-labelled project containers to be absent.

If uninstall or a residual assertion fails, stop. Do not manually delete the failed residual and continue the same certification run; fix the owning uninstall behavior and repeat from a known-good disposable snapshot.

## Restore and automation ordering

The full restore uses:

```text
--remote
--from-recovery-kit <pre-DR-kit>
--no-backup
--start-policy manual
--force
```

After restore the controller repairs permissions, starts the stack through `startup.sh`, and installs systemd automation with `--no-enable-now`. It verifies each managed timer is enabled for the next boot but inactive now. It then runs health, email, the pre-production drill, and the application E2E hook **before** recurring jobs are allowed to start.

Only after restored data and services pass those checks and new recovery custody is proven does the controller run `setup-systemd.sh install --enable-now`, canonical `setup-systemd.sh validate`, and the smoke test.

## Rotated recovery custody is mandatory

A successful canonical full restore rotates to a new operational Age key. Future backups therefore require the **new** recovery material; the pre-DR kit used to enter the drill is not sufficient custody for the recovery points created afterward.

At `recovery-custody` the controller stops until the newly generated recovery handoff is copied to durable off-host storage. Copy the new kit to a separate mounted recovery medium (for example a mounted removable or dedicated recovery filesystem) and resume with:

```bash
sudo env VW_NOBLE_TEST_DESTRUCTIVE=YES \
  utilities/noble-host-acceptance.sh resume \
  --destructive \
  --recovery-kit /root/vw-acceptance-recovery-kit.txt \
  --rclone-remote myremote \
  --rclone-config /root/vw-acceptance-rclone.conf \
  --application-e2e /root/vw-application-e2e.sh \
  --post-restore-recovery-kit /mnt/recovery/vaultwarden-recovery-kit-<timestamp>.txt
```

The supplied post-restore kit must:

- be a root-owned `0400`/`0600` regular file, not a symlink;
- be outside managed VaultWarden paths;
- reside on a mounted filesystem whose device differs from the root filesystem;
- be newer than the completed restore;
- contain the canonical recovery-kit completion marker and exactly one Age private identity; and
- have a digest different from the pre-DR recovery kit.

This is an enforceable custody gate, not proof of the wider durability policy of the chosen recovery medium. Retain the copied kit according to your normal off-host/offline recovery policy.

## Evidence to retain

For the release/commit being certified, retain:

- exact Git SHA and host inventory;
- controller checkpoint metadata and logs;
- pre- and post-DR smoke output;
- backup verification and rclone inventory output;
- pre-DR and post-restore application E2E logs;
- uninstall output and residual result;
- restore output;
- evidence of the newly rotated recovery-kit custody; and
- final DB/full rclone backup verification.

The PR/commit is not real-host certified until one full destructive run on a disposable supported Noble host completes with retained evidence. CI and mocked contract tests cannot substitute for that run.
