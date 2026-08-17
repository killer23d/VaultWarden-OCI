# Noble Host Acceptance and Same-Host DR

`utilities/noble-host-acceptance.sh` is a release/DR acceptance controller for a real Ubuntu 24.04 LTS Noble host. It complements the permanent Bash test inventory; it does not replace `./tests/run-tests.sh all` or reimplement backup, restore, uninstall, storage, systemd, smoke, or drill logic.

Use this workflow periodically on a disposable acceptance host or snapshot, not as a routine day-to-day health check. A full pass is intentionally destructive and can perform real external DNS changes, so use a dedicated acceptance hostname/zone and credentials.

## Full-certification boundary

A full run proves the repository's supported Noble host path by orchestrating:

1. the canonical permanent Bash suites;
2. live health, email, pre-production drill, and smoke checks;
3. the external application E2E hook, which creates/records the DR canary;
4. an explicit DB backup plus a **new full backup created after the canary**, with that full backup's exact basename, archive SHA-256, authenticated cohort digest, and rclone location checkpoint-bound;
5. installed systemd validation and one proven foreground execution of each managed recurring job, rejecting operation-lock exit `75` skips, with the DNS updater protected by an explicit external-mutation gate;
6. Docker daemon restart followed by smoke testing;
7. a real reboot, verified by Linux boot ID;
8. canonical `--test-reset` uninstall plus independent residual assertions;
9. exact re-download of the checkpoint-bound full backup cohort from rclone and bootstrap restore of that staged local file using canonical `--remote --file`, the external pre-DR recovery kit, and `--start-policy manual`; `--remote` enables the supported missing-environment bootstrap path but does not replace the exact `--file` selection;
10. an immediate post-restore checkpoint **before** permission repair, startup, health, email, drill, or E2E validation, so a later validation failure cannot repeat a successful destructive restore;
11. post-restore health, email, drill, and application E2E while recurring timers remain non-running; the canonical manual install is verified and an exit-safe cleanup then leaves every managed recurring timer disabled even if validation fails, so an unexpected reboot cannot cross the custody gate, including assertion of the same pre-DR canary;
12. canonical export of a new **full recovery kit** after Age rotation, followed by an exact-digest copy of that exported kit to a non-root mounted recovery medium, with its Age identity proven to match the live rotated operational key and to differ from the pre-DR identity;
13. only then, activation and canonical validation of systemd automation, protected again by the DNS mutation scope gate;
14. fresh DB and fully verified full rclone recovery points encrypted to the new operational recipient; and
15. exact re-download of that final full backup and canonical read-only `restore.sh inspect` authentication/decrypt preflight using the **copied post-restore recovery kit itself**, proving both its backup-integrity HMAC and Age identity.

`FULL ACCEPTANCE PASSED` is reachable only after the real-reboot, exact-source destructive DR, rotated-recovery-custody, external-mutation, automation, final-backup, and copied-kit remote-decrypt gates succeed.

## Checkpoint integrity

The controller stores root-only checkpoint state under `/var/tmp/vaultwarden-noble-acceptance` by default. The checkpoint contains no credential values. If `VW_ACCEPTANCE_STATE_ROOT` is overridden for a destructive run, it must be an absolute dedicated directory path outside the canonical uninstall survival scope; the controller rejects a symlink, a top-level host directory, or any state root that the drill could remove or render inaccessible. The checkpoint binds a run to:

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
- after restore, the exact canonical full recovery-kit export digest plus the copied external kit path/digest and recipient binding.

`resume` fails if any bound operator input changes. The controller compares `/proc/sys/kernel/random/boot_id` with the saved pre-reboot value, so rerunning `resume` without rebooting cannot satisfy the reboot gate.

`--skip-reboot` exists only for controller development. A run started with it is permanently non-certifying and terminates at the `incomplete` phase. Re-running without the flag is rejected as checkpoint drift.

## Single-instance controller lock

Every `run` and `resume` invocation takes a non-blocking exclusive `flock` on `/run/lock/vaultwarden-noble-acceptance.lock` before parsing inputs or touching checkpoint state. A second root invocation fails closed instead of interleaving metadata, phase changes, logs, uninstall, or restore work. The lock is process-lifetime only: the intentional reboot checkpoint exits `75`, the kernel releases the lock, and the post-reboot `resume` must acquire it again. `status` remains read-only and does not take the destructive controller lock.

## Host/storage boundary

Destructive same-host DR intentionally supports **boot-volume project state only**.

The controller does not maintain a parallel storage detector. Before destructive work it sources the canonical uninstaller in dry-run mode, calls its `resolve` path, and applies the same `DATA_VOLUME_DEVICE` and `storage_ambiguous` checks used by destructive uninstall. This catches explicitly configured attached storage as well as incompletely described custom mounts, managed mount guards, and other ambiguous separate-volume evidence.

The production uninstaller correctly preserves separately attached data-volume contents. Therefore an attached-volume same-host reset is not a clean replacement-host simulation and is rejected. Test attached-volume DR on a fresh replacement host or with a disposable replacement block volume instead of weakening uninstall safety.

## Required external inputs

Before starting, prepare:

- a root-owned `0400` or `0600` pre-DR recovery kit outside the canonical destructive uninstall survival scope;
- a root-owned `0400` or `0600` rclone configuration outside that same survival scope;
- the exact rclone subpath used for the acceptance backups;
- a root-owned executable application E2E hook that is not group- or world-writable **and is outside that survival scope**; and
- a dedicated acceptance hostname/zone whose configured runtime `DOMAIN` you explicitly authorize the drill to mutate.

The pre-DR recovery kit, rclone config, application E2E hook, and acceptance checkpoint must all remain available after `utilities/uninstall-vaultwarden.sh run --test-reset`. For destructive runs the controller sources that canonical uninstaller with the test-reset policy, calls its `resolve`, and builds a conservative survival boundary from the resolved boot-volume `PROJECT_STATE_DIR`, `OPT_DIR`, `ETC_DIR`, `RUNTIME`, `RECOVERY_DIR`, checkout, any attached data mount, exact managed/test-reset files, and compose-labelled Docker volume mountpoints when Docker can be inspected. A candidate under a recursive removal/unmount root or equal to an exact managed file is rejected.

This validation runs once before destructive acceptance state is initialized and again immediately before uninstall, so later configuration drift cannot move an input into the deletion scope. In particular, a normal `/root/vaultwarden-recovery/vaultwarden-recovery-kit-*` handoff, a credential under a custom boot-volume state such as `/srv/vaultwarden`, an E2E hook under the managed `/opt/vaultwarden-scripts` tree, or a `VW_ACCEPTANCE_STATE_ROOT` beneath the resolved project state is intentionally rejected. Copy external dependencies to separate root-owned paths first.

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

Before any reboot/uninstall destructive transition, the controller re-downloads that exact bound remote source and runs canonical read-only `restore.sh inspect --remote --file ... --from-recovery-kit ...`. Canonical inspect loads the recovery kit's historical backup-integrity HMAC key, authenticates the `.sha256.hmac` cohort, decrypts the archive with its Age identity, and performs restore preflight without stopping services or modifying live state. A wrong, stale, or Age-only kit therefore fails while the original host is still intact.

After uninstall, the controller does not call `restore.sh latest`. It downloads the four required members of that exact remote cohort (`.age`, `.sha256`, `.sha256.hmac`, `.meta`) into the root-only acceptance state area, verifies the archive and cohort digests against the checkpoint, and calls canonical restore with `--remote --file` on that staged full backup. The explicit local `--file` remains authoritative; `--remote` is present only to enter canonical bare-metal/bootstrap mode after `--test-reset` removed the runtime environment. The post-restore E2E invocation must find the same canary.

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
2. canonical `restore.sh interactive --remote --file <staged-full-backup> --from-recovery-kit ... --start-policy manual --force`; the local file is still the exact restore source while `--remote` enables the supported missing-environment bootstrap path. The controller does not force `--no-backup`; canonical full restore already skips the snapshot on a genuinely fresh target with no live database and retains its normal snapshot policy otherwise;
3. record restore completion and the restored backup identity; and
4. **immediately checkpoint `post-restore-validation`**.

Only the next phase performs permission repair, startup, manual systemd installation, health, email, pre-production drill, and post-DR application E2E. The manual systemd step arms its EXIT cleanup before invoking the canonical installer, then proves the install produced enabled-but-inactive timers; the cleanup disables all managed recurring timers before the step can return on installer failure, validation failure, or success. This keeps the custody boundary reboot-safe: an unexpected reboot before `activate-automation` cannot start backup, maintenance, DNS, health, or firewall timers. If any of those checks fail, `resume` restarts `post-restore-validation`; it does not repeat the already successful restore or rotate the Age key again.

## Rotated recovery custody is mandatory

A successful canonical full restore rotates to a new operational Age key. Future backups therefore require the **new** recovery material; the pre-DR kit used to enter the drill is not sufficient custody for the recovery points created afterward.

After post-restore E2E succeeds, the controller enters `recovery-export` and invokes the canonical `utilities/secrets-export-recovery-kit.sh`. All managed recurring timers are still disabled at this point and remain disabled throughout export/copy/custody, including across an unexpected reboot. This is deliberately separate from the automatic `vaultwarden-age-key-rotation-<timestamp>.txt` handoff: that handoff contains the rotated Age identity only and ends with `END OF AGE KEY ROTATION HANDOFF`; it is **not** a full recovery kit and does not carry the backup-integrity HMAC required for authenticated restore.

When the canonical exporter asks whether to email an encrypted ZIP, answer **no** for this drill so the root-owned `vaultwarden-recovery-kit-<timestamp>-<id>.txt` remains temporarily under `/root/vaultwarden-recovery` for the custody copy. The controller checkpoints the exact exported full-kit digest, then enters `recovery-custody`. Copy that exact file to durable off-host storage and resume with the same bound options plus:

```text
--post-restore-recovery-kit /mnt/recovery/vaultwarden-recovery-kit-<timestamp>.txt
```

The supplied post-restore kit must:

- be a root-owned `0400`/`0600` regular file, not a symlink;
- be outside managed VaultWarden paths;
- reside on a mounted filesystem whose device differs from the root filesystem;
- be newer than the completed restore;
- contain the canonical recovery-kit completion marker, exactly one Age private identity, and a populated `Backup integrity HMAC key (auto-generated)` field;
- have a digest exactly equal to the canonical full recovery kit exported and checkpointed by this run;
- have a digest different from the pre-DR recovery kit;
- derive the **same Age recipient as the live `/etc/vaultwarden/age-key.txt`**; and
- derive a recipient different from the pre-DR recovery kit.

After automation is activated, the final full backup is created with full verification and rclone delivery. The controller binds that exact backup, re-downloads its authenticated cohort, and runs canonical read-only `restore.sh inspect --remote --file ... --from-recovery-kit ...` with the copied post-restore full kit. This validates the kit's HMAC against the final cohort and its Age identity against the ciphertext. Acceptance-owned key staging and the delegated restore TMPDIR fallback both use the repository's verified volatile sensitive-workspace abstraction rather than persistent `/var/tmp`.

## Evidence to retain

For the release/commit being certified, retain:

- exact Git SHA and host inventory;
- controller checkpoint metadata and logs;
- pre- and post-DR smoke output;
- pre-DR E2E/canary output;
- the exact bound DR source backup basename, archive SHA-256, cohort digest, and rclone location;
- the pre-DR external recovery kit's successful canonical authenticated inspect of that exact offsite source;
- uninstall output and residual result;
- exact-source restore output and the immediate post-restore checkpoint;
- post-restore E2E proof of the same canary;
- the canonical post-restore full recovery-kit export digest, proof that the external copy matches it exactly, and evidence that its recipient matches the live rotated key;
- DNS mutation-scope checks for the dedicated acceptance hostname;
- final DB/full rclone backup verification; and
- the copied full recovery kit's successful canonical authenticated inspect against the exact final offsite full backup.

The PR/commit is not real-host certified until one full destructive run on a disposable supported Noble host completes with retained evidence. CI and mocked contract tests cannot substitute for that run.
