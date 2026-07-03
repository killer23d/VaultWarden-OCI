# Troubleshooting Guide — VaultWarden-OCI

Common diagnosis and recovery steps for the current root-operated VaultWarden-OCI model.

Related docs: [OPERATIONS.md](OPERATIONS.md) · [BACKUP-RESTORE.md](BACKUP-RESTORE.md) · [DISASTER-RECOVERY.md](DISASTER-RECOVERY.md) · [RESTORE-RUNTIME-PERMISSIONS.md](RESTORE-RUNTIME-PERMISSIONS.md)

---

## General Triage Flow

Start with the least destructive checks:

```bash
sudo ./maintenance.sh health
docker compose ps
docker compose logs --tail=100
sudo ./setup.sh systemd validate || true
```

Then narrow by symptom:

| Symptom | First command |
| :-- | :-- |
| Vault inaccessible | `sudo ./maintenance.sh health` |
| Cloudflare 525 | local SNI curl + Caddy logs |
| Backup failed | `sudo ./backup.sh list` and service journal |
| Restore failed | inspect backup metadata and key used |
| Secrets unavailable | `sudo make key-health` and SOPS decrypt check |
| Timer failed | `journalctl -u <unit> -n 100 --no-pager` |

---

## Services Will Not Start

Symptoms:

- containers exit immediately;
- `docker compose up` fails;
- `make up` or `startup.sh` exits non-zero.

Diagnosis:

```bash
sudo ./maintenance.sh health || true
docker compose config --quiet
docker compose ps
docker compose logs --tail=120
sudo ls -la /run/vaultwarden-oci/secrets/
```

Fixes:

```bash
sudo utilities/repair-permissions.sh
sudo ./startup.sh --force
sudo ./maintenance.sh health
```

If the compose template is invalid, fix `docker-compose.yml.example`, validate it, regenerate, and restart:

```bash
docker compose --env-file .env.example -f docker-compose.yml.example config --quiet
sudo ./setup.sh install --domain vault.example.com --email admin@example.com --force
sudo ./startup.sh --force
```

---

## Cloudflare 525 / Caddy TLS Failure After Restore

Symptoms:

- Cloudflare returns HTTP `525`;
- browser cannot complete HTTPS;
- local SNI HTTPS to `127.0.0.1` returns HTTP `000` or TLS internal error;
- Caddy logs mention permission errors for `/data/caddy`, `/config/caddy`, `/var/log/caddy`, certificate keys, storage locks, or autosave.

Diagnosis:

```bash
DOMAIN="vault.example.com"

curl -vk --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/alive" \
  -o /dev/null -w "local HTTPS /alive: HTTP %{http_code}\n"

curl -vk --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/api/config" \
  -o /dev/null -w "local HTTPS /api/config: HTTP %{http_code}\n"

sudo docker logs vaultwarden_caddy --tail=120 2>&1 \
  | grep -Ei 'permission|certificate|tls|handshake|error|warn|storage|autosave' || true

sudo utilities/repair-permissions.sh --check
```

Fix:

```bash
sudo utilities/repair-permissions.sh
sudo docker compose restart caddy
sudo ./maintenance.sh health
```

Expected health result:

```text
[pass] permissions:caddy-storage    Caddy storage/log permissions are correct
```

Cause: full/emergency archives are intentionally restored without trusting old archive owners/modes. After extraction, the runtime permission repair helper must normalize Caddy bind mounts to UID/GID `2000:2000`. See [RESTORE-RUNTIME-PERMISSIONS.md](RESTORE-RUNTIME-PERMISSIONS.md).

Do not use broad fixes such as `chmod -R 777` or `chown -R 2000:2000 ${PROJECT_STATE_DIR}`. They can expose root-operated secrets or break encrypted state.

---

## Caddy Certificate / DNS-01 Problems

Symptoms:

- certificate issuance fails;
- DNS-01 challenge errors;
- Caddy logs mention Cloudflare token or API failures.

Diagnosis:

```bash
docker compose logs caddy | grep -iE 'cloudflare|dns|challenge|certificate|error'
sudo ./utilities/secrets-list.sh
sudo ./maintenance.sh health
```

Fixes:

```bash
sudo ./edit-secrets.sh rotate caddy_cloudflare_dns_token
sudo ./edit-secrets.sh rotate cloudflare_zone_id
sudo docker compose restart caddy
sudo ./maintenance.sh health
```

Confirm Cloudflare SSL/TLS mode is **Full (Strict)** after the origin certificate is valid.

---

## Vaultwarden Container Crashes

Symptoms:

- Vaultwarden exits or restarts;
- web vault unavailable;
- database errors in logs.

Diagnosis:

```bash
docker compose logs vaultwarden --tail=120
sudo sqlite3 "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/data/db.sqlite3" 'PRAGMA integrity_check;'
docker stats --no-stream
```

Fixes:

```bash
sudo ./maintenance.sh db-maint
sudo ./maintenance.sh health
```

If database corruption is confirmed and cannot be repaired, restore the latest DB backup:

```bash
sudo ./restore.sh latest db
sudo ./maintenance.sh health
```

---

## Restore Fails

Symptoms:

- Age decrypt error;
- preflight refuses storage layout;
- restore stops before service start;
- services do not start after restore.

Diagnosis:

```bash
sudo ./restore.sh inspect --remote
cat /path/to/backup.age.meta
sha256sum -c /path/to/backup.age.sha256
sudo make key-health
```

Common causes and fixes:

| Cause | Fix |
| :-- | :-- |
| Wrong Age key | Use the key that encrypted the selected backup, supplied with `--key-file`, `RESTORE_AGE_KEY_FILE`, or recovery kit. |
| Block backup targeting boot storage | Attach/mount the data volume first, then rerun inspect. |
| Backup has only `.pre-restore-*` DBs | Choose a different full/emergency archive or restore a DB backup. |
| Caddy permissions drift after restore | Run `sudo utilities/repair-permissions.sh` and restart Caddy. |
| Operator does not want immediate service start | Use `--start-policy ask` or `--no-start`. |

Remember the tier model:

| Tier | Restore meaning |
| :-- | :-- |
| `db` | Quick database rollback; storage-layout independent. |
| `full` | Normal DR restore that needs the offline Age recipient's private key or the operational Age key that encrypted the backup. |
| `emergency` | Clone-grade sealed restore that may carry `/etc/vaultwarden` key/config material. |

> **Warning:** Emergency backups are clone-grade secrets-bearing artifacts. Treat them like a password-manager vault export and protect the passphrase or emergency recipient identity separately.

---

## Backup Creation Fails

Symptoms:

- backup command exits non-zero;
- SQLite integrity check fails;
- rclone upload fails;
- backup verification fails.

Diagnosis:

```bash
df -h "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
sudo make key-health
sudo ./backup.sh list
journalctl -u vaultwarden-db-backup.service -n 100 --no-pager
journalctl -u vaultwarden-full-backup.service -n 100 --no-pager
```

Fixes:

```bash
sudo ./maintenance.sh run --comprehensive
sudo ./maintenance.sh db-maint
sudo ./backup.sh run db
sudo ./backup.sh run full --full-verification
```

For rclone failures:

```bash
rclone lsd your_remote_name:
rclone config show your_remote_name
sudo ./backup.sh run db --rclone
```

---

## Backup Verification Fails With Missing Age Key

A backup cannot be considered verified if the decrypt probe cannot find the Age key.

Diagnosis:

```bash
sudo make key-path
sudo make key-health
sudo ./backup.sh verify
```

Fix:

```bash
# Restore the key from offline escrow or recovery kit, then:
sudo make key-health
sudo ./backup.sh verify
```

If the key is permanently lost, old backups encrypted to that key are unrecoverable. Generate a new key only after accepting that old backup set is lost.

---

## Secrets Decryption Failures

Symptoms:

- SOPS decrypt fails;
- secrets edit/list commands fail;
- startup cannot render runtime secrets.

Diagnosis:

```bash
sudo make key-health
sudo ./utilities/secrets-list.sh
sudo sops -d "${SECRETS_FILE:-${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/secrets/secrets.yaml}" >/dev/null
```

Fixes:

```bash
sudo utilities/repair-permissions.sh
sudo make key-health
sudo ./utilities/secrets-edit.sh
```

Do not render persistent secrets world-readable. The expected production contract is root-operated private state.

---

## Health Reports Placeholder Secrets

Symptoms:

- health reports `CHANGE_ME` values;
- Cloudflare, email, or push integration fails.

Fix:

```bash
sudo ./edit-secrets.sh rotate caddy_cloudflare_dns_token
sudo ./edit-secrets.sh rotate cf_worker_bouncer_token
sudo ./edit-secrets.sh rotate cloudflare_zone_id
sudo ./edit-secrets.sh rotate smtp_password
sudo make restart
sudo make health
```

---

## Email Not Sending

Diagnosis:

```bash
docker compose ps postfix
docker compose logs postfix --tail=100
sudo ./maintenance.sh test-email --verbose
```

Fixes:

```bash
nano .env
sudo ./edit-secrets.sh rotate smtp_password
sudo docker compose restart postfix vaultwarden
sudo ./maintenance.sh test-email --verbose
```

See [EMAIL.md](EMAIL.md) for provider-specific API/SMTP details.

---

## CrowdSec Not Blocking

Diagnosis:

```bash
sudo systemctl status crowdsec
sudo cscli decisions list
sudo cscli alerts list --since 24h
sudo cscli bouncers list
sudo journalctl -u crowdsec -n 100 --no-pager
```

Fixes:

```bash
sudo systemctl restart crowdsec
sudo ./edit-secrets.sh rotate cf_worker_bouncer_token
sudo ./maintenance.sh update-firewall
```

If your own IP is banned:

```bash
sudo cscli decisions delete --ip <your-ip>
```

---

## Systemd Timers Not Running

Diagnosis:

```bash
sudo ./setup.sh systemd status
sudo ./setup.sh systemd validate
systemctl list-timers --all | grep vaultwarden
journalctl -u vaultwarden-health.service -n 100 --no-pager
```

Fix:

```bash
sudo ./setup.sh systemd install
sudo ./setup.sh systemd validate
sudo make timers
```

After pulling repo updates that change scripts or units, reinstall systemd integration so `/opt` scripts and unit files match the repository.

---

## Storage / Block Volume Problems

Symptoms:

- restore preflight refuses to proceed;
- scripts warn about missing mountpoint or `.vw-data-volume` sentinel;
- data appears under boot storage unexpectedly.

Diagnosis:

```bash
sudo ./restore.sh inspect --remote
findmnt "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
lsblk -f
grep -E 'PROJECT_STATE_DIR|DATA_VOLUME' .env
```

Fix:

- Attach and mount the data volume before full/emergency restore.
- Confirm `PROJECT_STATE_DIR`, `DATA_VOLUME_MOUNT`, and `DATA_VOLUME_DEVICE` describe the intended storage model.
- Restore a `db` backup instead if you only need Vaultwarden database contents.

---

## Diagnostic Bundle

When opening an issue or reviewing a failure, collect:

```bash
sudo make diagnose > diagnose-report.txt
sudo ./maintenance.sh health --comprehensive --json > health-report.json
docker compose logs --tail=300 > service-logs.txt
sudo ./setup.sh systemd status > systemd-status.txt
sudo cscli decisions list >> systemd-status.txt || true
```

Sanitize secrets before sharing logs or configuration.
