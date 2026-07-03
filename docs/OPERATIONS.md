# Operations Guide — VaultWarden-OCI

This guide covers day-to-day operation for the current root-operated VaultWarden-OCI model: lifecycle commands, health checks, backups, restores, systemd automation, runtime permission repair, and troubleshooting entry points.

Related docs: [BACKUP-RESTORE.md](BACKUP-RESTORE.md) · [DISASTER-RECOVERY.md](DISASTER-RECOVERY.md) · [RESTORE-RUNTIME-PERMISSIONS.md](RESTORE-RUNTIME-PERMISSIONS.md) · [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

---

## Operating Model

Production lifecycle and maintenance commands are root-operated. Prefer the Makefile shortcuts or direct `sudo` commands shown here.

```bash
sudo make up
sudo make restart
sudo make health
sudo make backup
sudo make backup-full
sudo make backup-emergency
```

Operator-editable source files remain in the repository. Root-owned runtime state lives under `${PROJECT_STATE_DIR}`, `/etc/vaultwarden`, and `/run/vaultwarden-oci/secrets`.

---

## Service Lifecycle

### Start

```bash
sudo ./startup.sh
# or
sudo make up
```

Startup renders runtime secrets under `/run/vaultwarden-oci/secrets`, syncs environment state, prepares runtime directories, starts Docker Compose, updates DNS when configured, and runs health checks.

### Stop

```bash
sudo ./startup.sh stop
# or
sudo make down
```

### Restart

```bash
sudo ./startup.sh --force
# or
sudo make restart
```

Use `sudo make safe-restart` when you want the guarded restart flow with rollback of compose/runtime startup state on health failure.

### Status and logs

```bash
sudo make status
make logs SERVICE=vaultwarden
make logs-caddy
make logs-crowdsec
```

---

## Health Monitoring

Run the standard health check:

```bash
sudo ./maintenance.sh health
sudo make health
```

Run comprehensive diagnostics:

```bash
sudo ./maintenance.sh health --comprehensive
```

Health checks cover container status, HTTPS/Vaultwarden endpoints, CrowdSec, disk/memory/network, SMTP, DNS, backups, configuration, notification dead letters, and Caddy storage/log permissions.

A healthy restored host should include:

```text
[pass] permissions:caddy-storage    Caddy storage/log permissions are correct
```

If the Caddy storage check warns after a full or emergency restore, run:

```bash
sudo utilities/repair-permissions.sh
sudo docker compose restart caddy
sudo ./maintenance.sh health
```

---

## Backup Operations

VaultWarden-OCI has three deliberately different backup tiers:

| Tier | Use | Contents | Key handling |
| --- | --- | --- | --- |
| `db` | Quick database rollback | A single encrypted, integrity-checked SQLite snapshot (`.sqlite3.age`) | Encrypted to the operational Age recipient. |
| `full` | Normal fresh-VM disaster recovery | Project root, state directory, persistent config, encrypted SOPS `secrets.yaml`, sidecars/metadata, and a verified DB injected at `${PROJECT_STATE_DIR}/data/db.sqlite3` | Excludes `/etc/vaultwarden/age-key.txt`; restore requires the offline Age recipient's private key or the operational Age key that encrypted the backup. |
| `emergency` | Fastest clone-style recovery | Everything in `full`, plus staged persistent `/etc/vaultwarden` key/config material such as `age-key.txt`, `vaultwarden.env`, and `rclone.conf` when present | Protected independently with `age -p` passphrase mode or `EMERGENCY_BACKUP_AGE_RECIPIENT`; it is never encrypted only to the operational key it contains. |

> **Warning:** Emergency backups are clone-grade secrets-bearing artifacts. Treat them like a password-manager vault export. Because they can contain the operational Age private key, they must be sealed with an independent passphrase prompt or a separate DR recipient (`EMERGENCY_BACKUP_AGE_RECIPIENT`).

Create backups:

```bash
sudo ./backup.sh run db
sudo ./backup.sh run full
sudo ./backup.sh run emergency
```

With offsite sync and full verification:

```bash
sudo ./backup.sh run full --full-verification --rclone
sudo ./backup.sh run emergency --full-verification --rclone
sudo ./backup.sh sync
```

List and verify:

```bash
sudo ./backup.sh list
sudo ./backup.sh verify
sudo make backup-status
```

Retention defaults are `db` 14 days, `full` 30 days, and `emergency` 90 days. Override per run with `--keep N`.

---

## Restore Operations

Inspect first for full/emergency restores:

```bash
sudo ./restore.sh inspect --remote
```

Restore database only:

```bash
sudo ./restore.sh latest db
sudo ./maintenance.sh health
```

Restore full DR backup:

```bash
sudo ./restore.sh interactive --remote --key-file /path/to/offline-age-key.txt --start-policy ask
```

Restore emergency clone-grade capsule:

```bash
sudo ./restore.sh interactive --remote --start-policy ask
```

Start policy options:

| Option | Behavior |
| :-- | :-- |
| `--start-policy auto` or `--start` | Start services automatically after successful restore/migration. |
| `--start-policy ask` | Prompt before starting; interactive restores default to this. |
| `--start-policy manual` or `--no-start` | Do not start services; print the manual checklist. |

Manual post-restore checklist:

```bash
sudo utilities/repair-permissions.sh
sudo docker compose config --quiet
sudo ./startup.sh --skip-pull
sudo ./maintenance.sh health
sudo ./setup.sh systemd install
```

---

## Runtime Permission Repair

Use this after restore, storage migration, or any ownership drift:

```bash
sudo utilities/repair-permissions.sh
```

Non-mutating drift check:

```bash
sudo utilities/repair-permissions.sh --check
```

The repair helper is explicit and service-aware. It repairs root-operated config/secrets, Vaultwarden app data ownership, Caddy `2000:2000` runtime storage/log paths, and transient `/run` secret permissions. It intentionally avoids broad recursive chmod over the whole state root.

Do **not** use:

```bash
sudo chmod -R 777 "$PROJECT_STATE_DIR"
sudo chown -R 2000:2000 "$PROJECT_STATE_DIR"
```

Those commands can expose root-operated secrets or break the SOPS/root-operated contract.

---

## Maintenance Operations

Routine maintenance:

```bash
sudo ./maintenance.sh run --comprehensive
sudo make maintenance
```

Dry run:

```bash
sudo ./maintenance.sh run --comprehensive --dry-run
```

Targeted operations:

```bash
sudo ./maintenance.sh update-dns
sudo ./maintenance.sh update-firewall
sudo ./maintenance.sh db-maint
sudo ./maintenance.sh test-email --verbose
```

When called with a targeted flag, routine cleanup is skipped and only the targeted task runs.

---

## Update Operations

Container image update:

```bash
sudo ./maintenance.sh update --images
sudo make update
```

System package update:

```bash
sudo ./maintenance.sh update --system
sudo make update-system
```

Full update:

```bash
sudo ./maintenance.sh update --all
```

Rollback scope: `restore.sh` covers application data/config. OS packages, Docker engine, and provider-level changes are not rolled back automatically. Use a provider/VM snapshot before system-level updates when possible.

---

## Secrets and Age Key Operations

Edit or rotate individual secret values:

```bash
sudo ./utilities/secrets-edit.sh
sudo ./edit-secrets.sh rotate caddy_cloudflare_dns_token
sudo ./edit-secrets.sh rotate smtp_password
```

Inspect Age key health:

```bash
sudo make key-health
sudo make key-show
```

Rotate the operational Age/SOPS key:

```bash
sudo make key-rotate
```

After key rotation or restore, export and save a recovery kit:

```bash
sudo ./utilities/secrets-export-recovery-kit.sh
```

Existing backups remain decryptable only with the key that encrypted them. Keep old keys offline until their backup retention windows have expired.

---

## Systemd Automation

Install/update timers and services:

```bash
sudo ./setup.sh systemd install
sudo ./setup.sh systemd validate
sudo make timers
```

Remove timers:

```bash
sudo ./setup.sh systemd remove
```

The timer set covers health self-healing, DB backups, full backups, maintenance, DNS refresh, firewall refresh, locking, and failure notifications.

After pulling repo updates that affect scripts or units, re-run:

```bash
sudo ./setup.sh systemd install
sudo ./setup.sh systemd validate
```

---

## Logs and Diagnostics

Container logs:

```bash
docker compose logs --tail=100
make logs SERVICE=caddy
make logs SERVICE=vaultwarden
```

Systemd logs:

```bash
journalctl -u vaultwarden-health.service -n 100 --no-pager
journalctl -u vaultwarden-db-backup.service -n 100 --no-pager
journalctl -u vaultwarden-full-backup.service -n 100 --no-pager
journalctl -u vaultwarden-notify-failure.service -n 100 --no-pager
```

Diagnostic bundle:

```bash
sudo make diagnose > diagnose-report.txt
sudo ./maintenance.sh health --comprehensive --json > health-report.json
```

---

## Caddy / Cloudflare 525 After Restore

If Cloudflare returns HTTP `525` after a full or emergency restore, first check local origin TLS and Caddy storage permissions:

```bash
DOMAIN="vault.example.com"

curl -vk --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/alive" \
  -o /dev/null -w "local HTTPS /alive: HTTP %{http_code}\n"

sudo docker logs vaultwarden_caddy --tail=120 2>&1 \
  | grep -Ei 'permission|certificate|tls|handshake|error|warn|storage|autosave' || true

sudo utilities/repair-permissions.sh
sudo docker compose restart caddy
sudo ./maintenance.sh health
```

The most common post-restore cause is Caddy state/log paths restored with stale host ownership. The repair helper normalizes those paths to UID/GID `2000:2000` without weakening root-operated secrets.

---

## Template Maintenance

Edit templates, not generated live files:

```bash
nano docker-compose.yml.example
nano .env.example
docker compose --env-file .env.example -f docker-compose.yml.example config --quiet
sudo ./setup.sh install --domain vault.example.com --email admin@example.com --force
sudo ./maintenance.sh update-firewall
sudo ./startup.sh --force
sudo ./maintenance.sh health
```

Generated runtime files such as `${PROJECT_STATE_DIR}/config/install.env` and `/etc/vaultwarden/vaultwarden.env` are root-owned artifacts. Use `sudo utilities/env-edit.sh edit` or `sudo make edit-env` for environment changes.
