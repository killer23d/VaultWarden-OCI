# Noble Host Acceptance and Same-Host DR

`utilities/noble-host-acceptance.sh` is a release-acceptance controller for a real Ubuntu 24.04 LTS Noble host. It complements, rather than replaces, the permanent Bash test inventory.

## What it covers

A full run orchestrates the repository's existing owners for:

1. `./tests/run-tests.sh all`
2. live health and email delivery
3. the non-destructive pre-production drill
4. production smoke testing with no skipped checks
5. DB and full backups with rclone delivery
6. full-backup verification and remote inventory
7. managed systemd validation
8. one manual start of each managed recurring job
9. Docker daemon restart followed by smoke testing
10. an external application-level E2E hook before DR
11. a real host reboot checkpoint and post-reboot readiness checks
12. the canonical `--test-reset` uninstall path
13. explicit post-uninstall residual checks
14. a full restore from the rclone remote using an external recovery kit
15. permission repair, startup, systemd reinstall, smoke and email checks
16. the application-level E2E hook again after restore
17. fresh DB and full offsite backups after DR

The controller records logs and its current phase under `/var/tmp/vaultwarden-noble-acceptance` by default. It stores no recovery-kit content, rclone credentials, or application credentials there.

## Host boundary

The destructive same-host DR phase intentionally supports **boot-volume project state only**.

The canonical uninstaller preserves the contents of a positively identified attached data volume and only removes its host wiring. That is the correct production safety behavior. It also means an attached-volume same-host reset is not a clean replacement-host simulation: the restored stack could accidentally observe old state. The acceptance controller therefore fails closed when `DATA_VOLUME_DEVICE` or an attached `/mnt/vw-data` state layout is detected.

For attached-volume acceptance, use a fresh replacement host or a disposable replacement block volume and test that path separately. Do not weaken the uninstaller to erase a production data disk merely to simplify a test.

## Prerequisites

Run the workflow on a disposable acceptance host, or on a host whose destruction is explicitly approved. For clean-install certification, start with a fresh Noble VM/snapshot and complete the repository's normal golden-path installation first.

Before the destructive phase, prepare two files outside all VaultWarden-managed paths:

- a root-owned `0600`/`0400` recovery kit;
- a root-owned `0600`/`0400` rclone configuration.

Both files must survive `utilities/uninstall-vaultwarden.sh run --test-reset`.

The application E2E hook must be a root-owned executable file. It should use disposable test data and exit non-zero on any failed assertion.

## Application E2E contract

The hook is intentionally external because the repository does not own a browser/client automation framework. For full certification, the hook should prove at least:

- user login;
- vault item create/read/update/delete;
- organization membership or sharing;
- attachment upload/download;
- Send creation/readback/removal;
- logout/login persistence;
- supported client sync;
- WebSocket/live-update behavior where applicable;
- admin endpoint remains protected.

Create a unique canary such as `NOBLE-DR-CANARY-<run-id>` before DR and require the same canary after the rclone restore. This turns the post-restore application pass into evidence that the restored data is the intended recovery point rather than merely a healthy empty service.

## Full run

Example:

```bash
sudo install -o root -g root -m 0600 /secure/recovery-kit.txt /root/vw-acceptance-recovery-kit.txt
sudo install -o root -g root -m 0600 /secure/rclone.conf /root/vw-acceptance-rclone.conf

sudo env VW_NOBLE_TEST_DESTRUCTIVE=YES \
  utilities/noble-host-acceptance.sh run \
  --destructive \
  --recovery-kit /root/vw-acceptance-recovery-kit.txt \
  --rclone-remote myremote \
  --rclone-config /root/vw-acceptance-rclone.conf \
  --application-e2e /root/vw-application-e2e.sh
```

When the controller reaches the reboot checkpoint it exits with status `75` after saving `post-reboot`. Reboot the host yourself, verify that the original checkout is still present, then rerun the same options with `resume`:

```bash
sudo env VW_NOBLE_TEST_DESTRUCTIVE=YES \
  utilities/noble-host-acceptance.sh resume \
  --destructive \
  --recovery-kit /root/vw-acceptance-recovery-kit.txt \
  --rclone-remote myremote \
  --rclone-config /root/vw-acceptance-rclone.conf \
  --application-e2e /root/vw-application-e2e.sh
```

`--skip-reboot` exists only for controller development. A run that omits destructive DR or the physical reboot must not be treated as full production-host certification.

## Uninstall is part of the DR assertion

The controller does not implement teardown itself. It calls:

```bash
sudo utilities/uninstall-vaultwarden.sh run \
  --test-reset \
  --i-have-saved-my-recovery-kit \
  --force
```

The uninstaller remains responsible for its ownership checks, operation guard, systemd cleanup, Docker cleanup, runtime cleanup, firewall/CrowdSec cleanup, state removal, and residual verification. The controller adds a small independent postcondition check for `/etc/vaultwarden`, `/run/vaultwarden-oci`, boot-volume state, generated checkout `.env`, and Compose-labelled containers before allowing restore to begin.

If uninstall returns non-zero or any residual assertion fails, the DR run stops before restore. Do not manually delete the failed residuals and then mark the run as passed; fix the owning uninstall behavior and repeat the acceptance run from a known-good snapshot.

## Restore boundary

The restore phase uses the project's canonical full-restore path with:

- the rclone remote explicitly supplied to the process;
- the external recovery kit;
- `--start-policy manual`;
- `--force` only for non-interactive confirmation, not to bypass project safety guards.

After restore, the controller repairs known permissions, starts through `startup.sh`, reinstalls the managed systemd runtime, validates it, runs the smoke suite and email test, then requires the application E2E hook to pass again.

## Evidence to retain

For a release/commit being certified, retain:

- exact Git SHA;
- host OS/architecture and block-device inventory;
- controller logs;
- pre-DR and post-DR smoke output;
- backup verification and rclone inventory output;
- uninstall output and residual assertion result;
- restore output;
- application E2E logs before and after DR;
- post-DR backup verification.

A browser login alone is not sufficient evidence of disaster-recovery success.
