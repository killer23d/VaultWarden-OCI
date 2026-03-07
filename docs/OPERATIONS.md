# Operations Guide — VaultWarden-OCI

This guide covers the current day-to-day operating model for VaultWarden-OCI: service lifecycle management, health validation, backups, restores, updates, maintenance, secrets handling, and scheduled automation.

For first-time installation, use [DEPLOYMENT.md](DEPLOYMENT.md). For script flags and deeper implementation details, use [SCRIPTS.md](SCRIPTS.md).

---

## Operating principles

Treat the repository scripts as the supported control plane for the environment.

- Use `setup.sh` to generate or refresh deployment files from templates.
- Use `startup.sh` for normal start, stop, and restart workflows.
- Use `health.sh` after deployments, maintenance, or updates.
- Use `update.sh` instead of ad-hoc image pulls when changing running versions.
- Use `edit-secrets.sh` or `setup-secrets.sh` for credential changes.

---

## Service lifecycle

### Start services

```bash
./startup.sh
make start
```

Typical startup responsibilities include preparing runtime directories, materializing Docker secret files from encrypted sources, starting the Compose stack, refreshing dynamic DNS where needed, and running post-start validation.

### Stop services

```bash
./startup.sh --down
make stop

docker compose down
```

Use `docker compose kill` only for emergency intervention.

### Restart services

```bash
./startup.sh --force
make restart
```

Use a scripted restart after configuration or secret changes so the full startup validation path runs again.

---

## Health and monitoring

### Standard health check

```bash
./health.sh
make health
```

Use this as the default validation command after startup, updates, or operational changes.

### Comprehensive validation

```bash
./health.sh --comprehensive
```

Use the comprehensive mode when troubleshooting, after larger upgrades, or before calling a maintenance cycle complete.

### Auto-recovery mode

```bash
./health.sh --auto-recover
./health.sh --comprehensive --auto-recover --email
```

This mode is useful for unattended or scheduled validation when you want unhealthy services restarted automatically and optionally reported by email.

### Status and runtime inspection

```bash
docker compose ps
docker stats --no-stream
docker inspect vaultwarden_app | jq '.[0].State.Health'
```

Use direct Compose and Docker inspection when you need container-level detail beyond the project health summary.

---

## Logs and diagnostics

### View logs

```bash
docker compose logs --follow
make logs

docker compose logs vaultwarden --follow --tail=50
make logs SERVICE=vaultwarden

make logs-postfix
```

### Useful log paths and patterns

```bash
grep "401" ${PROJECT_STATE_DIR}/logs/caddy/auth_attempts.log | jq
cat ${PROJECT_STATE_DIR}/logs/caddy/admin_access.log | jq
grep "block\|ban" ${PROJECT_STATE_DIR}/logs/fail2ban/fail2ban.log
grep "ERROR" ${PROJECT_STATE_DIR}/logs/vaultwarden/vaultwarden.log
grep "429" ${PROJECT_STATE_DIR}/logs/caddy/access.log | jq
```

### Check log footprint

```bash
du -sh ${PROJECT_STATE_DIR}/logs/*
```

Log growth should be reviewed during routine maintenance and whenever disk usage rises unexpectedly.

---

## Backups and restores

### Backup types

```bash
./backup.sh --type db
./backup.sh --type full
./backup.sh --type emergency
```

- `db` is the normal fast database backup path.
- `full` captures the wider deployment state needed for broader recovery.
- `emergency` is the disaster-recovery tier and should be used before high-risk changes.

### Verification and remote sync

```bash
./backup.sh --type full --full-verification
./backup.sh --type db --rclone
./backup.sh --type full --rclone --email
```

Use `--full-verification` for higher-confidence validation and `--rclone` when offsite copy is part of your backup policy.

### Retention

Retention should be treated as configurable rather than hard-coded in operations documents.

- Use `--keep N` to override retention for a run.
- Review `KEEP_DAYS` in `.env` for the deployed default.

### List and restore

```bash
./backup.sh --list
make list-backups

./restore.sh
make restore

./restore.sh --file /path/to/backup.age
make restore-db
```

Use the interactive restore flow for normal recovery work. Use targeted or latest restore commands only when you are certain about the archive you need.

### Recovery material

Keep the Age key and exported recovery kit outside the server.

```bash
./edit-secrets.sh --export-recovery-kit
ls -l secrets/keys/age-key.txt
```

Without the decryption material, encrypted backups are not useful during a rebuild.

---

## Updates and rollback

### Standard updates

```bash
./update.sh
make update

./update.sh --system
make update-system
```

Use `./update.sh` as the normal update entry point because it wraps validation and recovery steps around the version change.

### Version management

The project supports both pinned-version and newer-image workflows, but production changes should still be applied through the scripted update path.

When version pins or image behavior need to change:

1. Review `.env`.
2. Create an emergency backup.
3. Apply the update with `update.sh`.
4. Re-run `health.sh`.

### Manual intervention path

```bash
nano .env
./backup.sh --type emergency
docker compose pull vaultwarden
docker compose up -d vaultwarden
./health.sh
```

Reserve this for exceptional cases where you are intentionally deviating from the normal update workflow.

---

## Maintenance tasks

### Comprehensive maintenance

```bash
./maintenance.sh --comprehensive
make maintenance

./maintenance.sh --comprehensive --email
make maintenance-full

./maintenance.sh --comprehensive --dry-run
```

This is the normal operator path for cleanup, checks, and routine housekeeping.

### Targeted maintenance

```bash
./maintenance.sh --update-dns
make update-dns

./maintenance.sh --update-firewall

./maintenance.sh --test-email
make test-email
```

Use targeted flags when you want a specific maintenance action without running the full comprehensive cycle.

### Database maintenance

```bash
sudo ./maintenance.sh --db-maint
sudo ./maintenance.sh --db-maint --force
make db-maint
```

Deep database maintenance temporarily stops VaultWarden, runs a fuller SQLite maintenance sequence, and should be scheduled during a quiet window.

---

## Security operations

### Fail2ban

```bash
docker compose exec fail2ban fail2ban-client status
docker compose exec fail2ban fail2ban-client status vaultwarden-auth

docker compose exec fail2ban fail2ban-client set vaultwarden-auth banip   1.2.3.4
docker compose exec fail2ban fail2ban-client set vaultwarden-auth unbanip 1.2.3.4

docker compose logs fail2ban | grep "cloudflare-apiv4"
```

### Secrets management

```bash
./edit-secrets.sh
make edit-secrets

./edit-secrets.sh --test
make test-secrets
```

A normal secret rotation workflow is:

1. Rotate or edit the secret.
2. Restart the stack with `./startup.sh --force`.
3. Re-run `./health.sh`.

### Break-glass admin

```bash
./create-breakglass-admin.sh --create
make breakglass-create

./create-breakglass-admin.sh --status
make breakglass-status

./create-breakglass-admin.sh --password
./create-breakglass-admin.sh --remove
make breakglass-remove
```

This account should exist as part of the recovery plan, not as an everyday administration path.

---

## Scheduled automation

### Install and validate cron jobs

```bash
sudo ./cron-setup.sh --install
make cron-install

sudo ./cron-setup.sh --list
make cron-list

sudo ./cron-setup.sh --validate

sudo ./cron-setup.sh --remove
make cron-remove
```

### Current schedule

| Schedule | Job |
|---|---|
| 2 AM Mon–Sat | Comprehensive maintenance |
| 3 AM Sunday | Full backup with verification and optional remote sync |
| 4 AM Mon–Sat | Database backup with optional remote sync |
| Every 30 minutes | Health check |
| Every hour | DNS update |
| Saturday 4 AM | Firewall rule update |

### Locking caveat

The project uses `/run/vaultwarden-locks/` for flock-protected jobs. Because `/run` is tmpfs-backed, the directory is cleared on reboot.

After a reboot, recreate or validate the lock setup:

```bash
sudo ./cron-setup.sh --install
# or
sudo ./cron-setup.sh --validate
```

To persist recreation automatically:

```bash
echo 'd /run/vaultwarden-locks 0700 root root -' | sudo tee /etc/tmpfiles.d/vaultwarden-locks.conf
sudo systemd-tmpfiles --create
```

---

## Configuration changes

### Preferred change flow

```bash
nano docker-compose.yml.example
nano .env.example

sudo ./setup.sh --force --domain vault.example.com --email admin@example.com
./startup.sh --force
./health.sh
```

Treat `.example` files as the source of truth. Avoid long-term drift by editing generated files directly and forgetting to back-port the change.

---

## Common troubleshooting paths

### Service will not start

```bash
docker compose config
ls -la secrets/.docker_secrets/
docker compose logs vaultwarden
docker compose logs caddy
docker compose logs fail2ban
docker compose logs postfix
./startup.sh --force
```

### High resource usage

```bash
docker stats --no-stream
du -sh ${PROJECT_STATE_DIR}/logs/*
./maintenance.sh --comprehensive
```

### Email problems

```bash
./maintenance.sh --test-email --verbose
docker compose ps postfix
docker compose logs postfix
grep SMTP .env
./edit-secrets.sh --test
```

### Backup problems

```bash
df -h
ls -la secrets/keys/age-key.txt
./backup.sh --type db
cat /var/log/vaultwarden-cron/backup.log
```

---

## Operational checklists

### Daily

- Check backup and health notifications.
- Review any unusual authentication or ban activity.
- Watch disk growth in logs and backups.

### Weekly

- Review the latest full backup result.
- Review update and maintenance results.
- Confirm email diagnostics and edge protection are healthy.

### Monthly

- Test a restore path.
- Review security and access posture.
- Validate recovery material and break-glass readiness.

### Quarterly

- Run a recovery drill.
- Review automation, firewall refresh, and documentation accuracy.
- Audit users, admins, and operational secrets.
