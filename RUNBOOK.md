# VaultWarden-OCI — Ops Runbook

Quick reference for common production operations. Commands assume you are in the repository root on the supported Ubuntu 24.04 Noble host.

The normal production lifecycle is root-operated. Use the `sudo` forms shown here.

---

## First-Time Deployment

1. Configure Cloudflare and the provider firewall/security group/network firewall.
2. Run the supported first-install command:

   ```bash
   sudo ./setup.sh install \
     --domain <fqdn> \
     --email <admin-email> \
     --auto
   ```

3. Edit non-secret configuration and set external credentials:

   ```bash
   sudo make edit-env
   sudo ./edit-secrets.sh rotate caddy_cloudflare_dns_token
   sudo ./edit-secrets.sh rotate cloudflare_zone_id
   sudo ./edit-secrets.sh rotate cf_account_id
   sudo ./edit-secrets.sh rotate cf_worker_bouncer_token
   sudo ./edit-secrets.sh rotate smtp_password
   ```

4. Start and verify the live stack:

   ```bash
   sudo make up
   sudo make health
   sudo ./maintenance.sh test-email --verbose
   ```

5. When the host is ready for scheduled work, activate and validate systemd automation:

   ```bash
   sudo ./setup.sh systemd install --enable-now
   sudo ./setup.sh systemd validate
   sudo ./utilities/smoke-test.sh
   ```

6. Export recovery material:

   ```bash
   sudo ./utilities/secrets-export-recovery-kit.sh
   ```

7. After the CrowdSec Workers bouncer has deployed its route, set the Cloudflare Worker route request-limit failure mode to **Fail open** as described in [docs/CROWDSEC.md](docs/CROWDSEC.md).

A Docker-group re-login is not part of the production golden path. The production lifecycle uses root-operated commands.

---

## Daily Operations

| Task | Command |
|---|---|
| Start stack | `sudo make up` |
| Stop stack | `sudo make down` |
| Restart stack | `sudo make restart` |
| Safe restart | `sudo make safe-restart` |
| Service/status summary | `sudo make status` |
| Active/interrupted operation status | `sudo make operations` |
| Tail all logs | `sudo make logs-tail` |
| Vaultwarden logs | `sudo make logs-vaultwarden` |
| Caddy logs | `sudo make logs-caddy` |
| Postfix queue summary | `sudo make email-queue-summary` |
| List queued messages | `sudo make email-queue` |
| Postfix queue logs | `sudo make email-queue-logs` |
| Postfix logs | `sudo make logs-postfix` |
| CrowdSec logs | `sudo make logs-crowdsec` |

Targeted deletion and snapshot purge require the effective Postfix setting
`enable_long_queue_ids=yes`. If verification fails, set
`POSTFIX_ENABLE_LONG_QUEUE_IDS=yes`, run `sudo make up`, verify with `postconf`,
and retry. The utility then holds exact IDs and checks metadata as defence in
depth. Equivalent queue-list duplicates are counted once; conflicting identities
fail closed. Do not run direct Postfix administrative commands concurrently with
the utility.

When an SSH session drops during setup, backup, restore, update, storage migration, secrets work, or another guarded mutation, start with:

```bash
sudo make operations
```

Kernel lock state is authoritative. If the original operation is still active, inspect its phase and wait or use the guarded conflict flow when offered. The project does not automatically kill `apt` or `dpkg` work.

---

## Health and Production Readiness

| Task | Command |
|---|---|
| Full health check | `sudo make health` |
| Quick health check | `sudo make health-quick` |
| Test email | `sudo ./maintenance.sh test-email --verbose` |
| Age key health | `sudo make key-health` |
| Diagnostic dump | `sudo make diagnose` |
| Production smoke test | `sudo ./utilities/smoke-test.sh` |

The smoke test checks the canonical project environment, Docker/Compose, critical container health, TLS, `/alive`, admin protection, Age/SOPS state, materialized runtime secrets, backup recency, canonical systemd validation, CrowdSec, and disk space.

A smoke-test `SKIP` is **not** production ready. Exit `0` requires no failed and no skipped checks.

When the systemd automation check fails:

```bash
sudo ./setup.sh systemd validate
```

If validation reports stale installed scripts, libraries, or units, or unhealthy managed timers, activate the current repository state and revalidate:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

Do not use `systemctl start vaultwarden-startup.service` as a generic readiness repair. The smoke test delegates installed-runtime and timer readiness to the canonical systemd validator.

---

## Repository Updates and Installed Runtime

`git pull --ff-only origin main` updates the repository checkout from `main`. Existing systemd jobs execute root-owned copies under `/opt/vaultwarden-scripts`, so repository updates do not automatically activate new managed runtime code.

After pulling changes that affect managed scripts, libraries, or units:

```bash
git pull --ff-only origin main
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

`make update` is different: it updates container images through the maintenance update path. It is not a Git updater or a systemd runtime synchronizer.

---

## Backup and Restore

| Task | Command |
|---|---|
| Database snapshot backup | `sudo make backup` |
| Full disaster-recovery backup | `sudo make backup-full` |
| Emergency clone-grade backup | `sudo make backup-emergency` |
| List local backups | `sudo make list-backups` |
| Backup inventory | `sudo make backup-status` |
| Verify latest backup | `sudo ./backup.sh verify` |
| Sync retained backups to rclone | `sudo ./backup.sh sync` |
| Guided restore | `sudo make restore` |
| Restore from remote | `sudo make restore-remote` |
| Database-only restore | `sudo make restore-db` |
| Restore preflight | `sudo make restore-preflight` |

Backup tiers:

- `db` — quick encrypted SQLite rollback;
- `full` — normal disaster-recovery archive without the live operational Age private key;
- `emergency` — clone-grade secrets-bearing capsule, independently sealed.

Before full/emergency restore, inspect storage compatibility:

```bash
sudo ./restore.sh inspect --remote
```

For guided remote restore with an operator start gate:

```bash
sudo ./restore.sh interactive --remote --start-policy ask
```

A timeout or lost confirmation channel is not treated as an implicit yes/no success. Restore fails safe where acknowledgement is required and prints manual next steps.

See [docs/BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md) and [docs/DISASTER-RECOVERY.md](docs/DISASTER-RECOVERY.md).

---

## Secrets and Age Key Management

| Task | Command |
|---|---|
| Edit encrypted secrets | `sudo make edit-secrets` |
| Test SOPS decryption | `sudo make test-secrets` |
| Rotate one secret | `sudo ./edit-secrets.sh rotate <key>` |
| List secret key names | `sudo ./utilities/secrets-list.sh` |
| Show current Age public recipient/path | `sudo make key-show` |
| Check Age key health | `sudo make key-health` |
| Create manual offline Age key copy | `sudo make key-backup` |
| Generate password-manager escrow material | `sudo make key-escrow` |
| Rotate operational Age/SOPS key | `sudo make key-rotate` |
| Export recovery kit | `sudo ./utilities/secrets-export-recovery-kit.sh` |

Persistent SOPS ciphertext lives under `${PROJECT_STATE_DIR}/secrets/secrets.yaml`. The live operational Age key is `/etc/vaultwarden/age-key.txt`. Transient decoded Compose secret source files live only under `/run/vaultwarden-oci/secrets` and are recreated by startup.

After Age key rotation, retain recovery material for old backup generations until those backups are deliberately retired. See [docs/BOOTSTRAP_KEY_RECOVERY.md](docs/BOOTSTRAP_KEY_RECOVERY.md).

---

## Environment Configuration

Edit non-secret configuration through:

```bash
sudo make edit-env
```

Check environment paths and drift with:

```bash
utilities/env-edit.sh status
```

The environment flow is:

```text
repository .env
    -> env-edit sync
${PROJECT_STATE_DIR}/config/install.env
    -> systemd install
/etc/vaultwarden/vaultwarden.env
```

For runtime loading, `/etc/vaultwarden/vaultwarden.env` is preferred when installed, then persistent `install.env`, then repository `.env` as a bootstrap/legacy fallback.

Do not hand-edit installed runtime environment files as a normal configuration workflow.

---

## Maintenance

| Task | Command |
|---|---|
| Routine maintenance | `sudo make maintenance` |
| Comprehensive maintenance | `sudo make maintenance-full` |
| Database maintenance | `sudo make db-maint` |
| Database backup | `sudo make db-backup` |
| Check/repair known permissions | `sudo make fix-permissions` |
| Prune unused Docker resources | `sudo make prune` |
| Update container images | `sudo make update` |
| Update host packages | `sudo make update-system` |
| Update Cloudflare DNS | `sudo make update-dns` |

Expected operation contention from guarded DNS/firewall jobs is a clean skip using exit `75` where the service contract defines it. A real nonzero failure must still be treated as failure.

---

## Systemd Integration

The managed timer set is:

- `vaultwarden-maintenance.timer`;
- `vaultwarden-db-backup.timer`;
- `vaultwarden-full-backup.timer`;
- `vaultwarden-health.timer`;
- `vaultwarden-dns-update.timer`;
- `vaultwarden-firewall-update.timer`.

| Task | Command |
|---|---|
| Install/enable, start timers now | `sudo ./setup.sh systemd install --enable-now` |
| Install/enable without starting timers now | `sudo ./setup.sh systemd install --no-enable-now` |
| Validate installed runtime and timers | `sudo ./setup.sh systemd validate` |
| Show managed unit status | `sudo ./setup.sh systemd status` |
| Show scheduled timers | `sudo make timers` |
| Remove managed units | `sudo ./setup.sh systemd remove` |

Use `--no-enable-now` on a replacement/recovery host that is not yet ready for scheduled backup, maintenance, DNS, or firewall work. Activate with `--enable-now` only after storage, secrets, rclone, networking, and live service readiness are verified.

---

## CrowdSec Operations

CrowdSec runs as a host service. The firewall bouncer enforces CrowdSec decisions at the host firewall layer, while the Cloudflare Workers bouncer pushes the configured locally generated decisions to Workers KV for edge enforcement.

| Task | Command |
|---|---|
| CrowdSec engine status | `sudo systemctl status crowdsec` |
| Workers bouncer status | `sudo systemctl status crowdsec-cloudflare-worker-bouncer` |
| Firewall bouncer status | `sudo systemctl status crowdsec-firewall-bouncer` |
| Active decisions | `sudo cscli decisions list` |
| Recent alerts | `sudo cscli alerts list --since 24h` |
| Bouncer registration | `sudo cscli bouncers list` |
| CrowdSec status helper | `sudo make crowdsec-status` |
| Security report | `sudo make security-report` |
| Enable security-event email | `sudo ./utilities/crowdsec-email.sh enable` |
| Inspect email integration | `sudo ./utilities/crowdsec-email.sh status` |
| Test email plugin dispatch | `sudo ./utilities/crowdsec-email.sh test` |
| Disable security-event email | `sudo ./utilities/crowdsec-email.sh disable` |

The optional security-event email controller updates the environment and managed CrowdSec configuration through the established reconciliation path. Its test confirms plugin dispatch; confirm mailbox receipt separately.

To remove a ban:

```bash
sudo cscli decisions delete --ip <your-ip>
```

To configure a persistent admin allowlist entry:

```bash
sudo ./utilities/setup-crowdsec.sh --admin-ip <your-ip-or-cidr>
```

After rotating the Workers bouncer token or related Cloudflare IDs:

```bash
sudo ./edit-secrets.sh rotate cf_worker_bouncer_token
sudo ./utilities/crowdsec-worker-apply.sh
```

See [docs/CROWDSEC.md](docs/CROWDSEC.md).

---

## Break-Glass Admin

```bash
sudo make breakglass-create
# resolve the emergency admin task
sudo make breakglass-remove
```

Check status with:

```bash
sudo make breakglass-status
```

Remove the break-glass account after the incident.

---

## Same-VM Test Reset and Uninstall

Preview destructive work first:

```bash
sudo make uninstall-dry-run
sudo ./utilities/uninstall-vaultwarden.sh run --test-reset --dry-run
```

For repeated acceptance testing on the same VM while preserving the Git checkout:

```bash
sudo ./utilities/uninstall-vaultwarden.sh run \
  --test-reset \
  --i-have-saved-my-recovery-kit
```

`--test-reset` removes managed VaultWarden-OCI state, generated install artifacts, managed systemd integration, managed Docker resources, CrowdSec integration, and project firewall rules, while preserving the checkout and host-wide Docker/tooling state. It is a clean project-stack reset, not a pristine-image rebuild.

Normal full uninstall:

```bash
sudo ./utilities/uninstall-vaultwarden.sh run \
  --i-have-saved-my-recovery-kit
```

Use `--force` only for deliberately disposable test state after recovery material has been verified outside the host.

---

## Replacement-Host State-Volume Recovery

After attaching and mounting a recovered state volume, check out the exact commit recorded by the recovery manifest and run:

```bash
sudo ./recover.sh \
  --state-dir /mnt/vw-data \
  --key /secure/path/offline-age-key.txt
```

If another guarded operation is active, non-interactive recovery exits with status `75` before creating recovery artifacts. Run `sudo make operations`, wait for the active owner to finish, and retry.

`recover.sh` uses the offline private key in place, generates a new operational Age key, and commits the recovered ciphertext, key, SOPS policy, persistent environment, and DR manifest as one local recovery identity before startup.

After recovery, do not enable timers until the host is ready. Then run:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

See [docs/RECOVERY-CARD.md](docs/RECOVERY-CARD.md) and [docs/DISASTER-RECOVERY.md](docs/DISASTER-RECOVERY.md).
