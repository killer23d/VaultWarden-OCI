# Operations Guide — VaultWarden-OCI

This guide covers day-to-day management, maintenance, monitoring, and troubleshooting for VaultWarden-OCI with Cloudflare-only web traffic, Age-encrypted backups, containerised Postfix email, and automated operations via systemd timers.

---

## 🔄 Daily Operations

### Service Management

#### Starting Services

```bash
# Full initialisation startup (recommended)
./startup.sh

# Or via Makefile
make start   # alias: make up

# What it does:
#  - Decrypts SOPS secrets once and writes Docker secret files
#  - Prepares log and state directories with correct ownership
#  - Starts all containers (docker compose up -d)
#  - Updates Cloudflare DNS A record
#  - Runs post-startup health check
```

#### Stopping Services

```bash
# Graceful shutdown via startup.sh
./startup.sh --down

# Or via Makefile
make stop   # alias: make down

# Or directly
docker compose down

# Emergency stop
docker compose kill
```

#### Restarting Services

```bash
# Enhanced restart (preferred)
./startup.sh --force

# --force-restart is a legacy alias for --force
./startup.sh --force-restart

# Or via Makefile
make restart

# Safe restart with auto-rollback on health failure
make safe-restart
```

---

### Health Monitoring

#### Basic Health Check

```bash
./health.sh

# Or via Makefile
make health

# Basic checks (always run):
#  ✓ All containers running (vaultwarden, caddy, fail2ban, postfix)
#  ✓ VaultWarden accessible on localhost:8080
#  ✓ External web access via Cloudflare (soft warning if down)
#  ✓ Disk space (warn >70%, critical >80%)
#  ✓ SSL certificate expiration
#  ✓ Database size and growth rate
#  ✓ Backup age and decryptability (missing Age key = hard failure)
#  ✓ Email notification configuration
```

#### Comprehensive Health Check

```bash
./health.sh --comprehensive

# Additional checks:
#  ✓ CPU and memory usage vs alert threshold
#  ✓ .env and secrets.yaml configuration validation
#  ✓ Fail2ban responding, Age key valid, SOPS config present
```

#### Health Check with Auto-Recovery

```bash
# Automatically restart unhealthy containers
./health.sh --auto-recover

# Combined — comprehensive check + auto-recovery + email alert
./health.sh --comprehensive --auto-recover --email

# Or via Makefile
make health AUTO_RECOVER=true
make health-email   # comprehensive + email
```

> **Note:** Supported flags: `--comprehensive` (runs additional checks), `--auto-recover` (restarts unhealthy containers), and `--quiet` (suppresses non-error console output).

#### Container-Specific Status

```bash
# Show all container states
docker compose ps

# Resource usage snapshot
docker stats --no-stream

# Health status of a specific container
docker inspect $(docker compose ps -q vaultwarden) | jq '.[0].State.Health'
```

---

### Log Management

#### Viewing Logs

```bash
# All services (follow)
docker compose logs --follow
make logs

# Specific service
docker compose logs vaultwarden --follow --tail=50
make logs SERVICE=vaultwarden

# Postfix email logs shortcut
make logs-postfix

# With timestamps
docker compose logs --follow --timestamps
```

#### Log Analysis

```bash
# Authentication failures (Caddy JSON logs)
grep "401" /var/lib/vaultwarden/logs/caddy/auth_attempts.log | jq

# Admin panel access
cat /var/lib/vaultwarden/logs/caddy/admin_access.log | jq

# Fail2ban bans
grep "block\|ban" /var/lib/vaultwarden/logs/fail2ban/fail2ban.log

# VaultWarden errors
grep "ERROR" /var/lib/vaultwarden/logs/vaultwarden/vaultwarden.log

# Rate limit events
grep "429" /var/lib/vaultwarden/logs/caddy/access.log | jq
```

> **Note:** The paths above use the default state directory `/var/lib/vaultwarden`. If you customised `PROJECT_STATE_DIR` in `.env`, replace `/var/lib/vaultwarden` with that value in the commands above.

#### Systemd Job Logs

```bash
# View output from any automated job
journalctl -u vaultwarden-health.service
journalctl -u vaultwarden-db-backup.service
journalctl -u vaultwarden-full-backup.service
journalctl -u vaultwarden-maintenance.service
journalctl -u vaultwarden-dns-update.service
journalctl -u vaultwarden-firewall-update.service

# Follow the most recent run of any service
journalctl -fu vaultwarden-health.service

# Show last N lines
journalctl -u vaultwarden-db-backup.service -n 50 --no-pager
```

#### Log Retention (Caddy)

| Log | Max Size | Retention |
|---|---|---|
| Main access | 1 GB | 30 days |
| Admin access | 750 MB | 90 days |
| Auth attempts | 750 MB | 90 days |
| Security | 500 MB | 180 days |

```bash
# Check log directory sizes
du -sh /var/lib/vaultwarden/logs/*
```

---

## 💾 Backup Operations

> **`sudo` note:** Direct `backup.sh` calls require `sudo` in production (needs write access to `${PROJECT_STATE_DIR}`). Makefile targets (`make backup`, `make backup-full`, etc.) and systemd jobs handle this automatically.

### Creating Backups

#### Database Backup (Quick — Daily)

```bash
./backup.sh --type db
make backup   # same
make db-backup

# Features:
#  - WAL checkpoint verified for completion before snapshot
#  - Atomic SQLite snapshot via .backup API (consistent under concurrent writes)
#  - PRAGMA integrity_check on the snapshot copy
#  - Age encryption
#  - Age key presence verified (hard failure if key absent)
#  - 14-day retention (age derived from filename timestamp, not ctime)
```

#### Full System Backup

```bash
./backup.sh --type full
make backup-full

# Includes: database, config files, Caddy certificates, logs
# Excludes: secrets (use --type emergency for those)
# Retention: 30 days
# Requires: zstd (installed by setup.sh)
```

#### Full Backup with End-to-End Verification

```bash
./backup.sh --type full --full-verification

# Process: create → decrypt → extract → integrity check → verify files → cleanup
# Recommended: weekly (matches systemd timer default)
```

#### Emergency Recovery Kit

```bash
./backup.sh --type emergency
make backup-emergency

# Includes everything, including secrets — full disaster recovery
# Retention: 90 days
```

### Remote Backups (rclone)

```bash
# Configure a remote first
rclone config
# Set RCLONE_REMOTE_NAME in .env

# Backup + sync to remote
./backup.sh --type db --rclone
./backup.sh --type full --rclone --email
```

Supported remotes: Google Drive, Amazon S3, Backblaze B2, Dropbox, OneDrive, and all other rclone-supported providers.

### Managing Backups

```bash
# List all backups
./backup.sh --list
make list-backups

# Interactive restore (recommended)
./restore.sh
make restore

# Restore specific file
./restore.sh --file /path/to/backup.age

# Restore latest DB backup (non-interactive)
make restore-db
```

---

## ⬆️ Update Operations

### Updating Containers

```bash
# Update container images (respects version pins in .env)
./update.sh
make update

# Update containers + system packages
./update.sh --system
make update-system
```

### Version Management

**Production mode — pinned versions (default):**

```bash
# .env (set by setup.sh --auto)
VAULTWARDEN_VERSION=1.35.4
CADDY_VERSION=2.11.1
FAIL2BAN_VERSION=1.1.0-r3
POSTFIX_VERSION=4.3.0
```

**Development mode — latest versions:**

Comment out version pins in `.env` to allow `docker compose pull` to fetch `latest` tags.

### Manual Version Upgrade

```bash
# Edit .env
nano .env
# e.g. VAULTWARDEN_VERSION=1.35.4

# Create emergency backup first
./backup.sh --type emergency

# Pull and restart
docker compose pull vaultwarden
docker compose up -d vaultwarden

./health.sh
```

> **VaultWarden 1.30.0+ note:** Port 3012 (legacy WebSocket) was removed. All real-time sync now goes through the main HTTP port 80. The Caddyfile `/notifications/hub` block already routes to `vaultwarden:80`; no manual change is needed for upgrades.

---

## 🛠️ Maintenance Operations

### Routine Maintenance

```bash
# Full maintenance: cleanup + Docker prune + DB optimisation + DNS + firewall
./maintenance.sh --comprehensive
make maintenance

# With email summary
./maintenance.sh --comprehensive --email
make maintenance-full

# Dry run — preview without changes
./maintenance.sh --comprehensive --dry-run
```

### Targeted Tasks

When called with only a targeted flag, routine cleanup is **skipped entirely**:

```bash
# Update Cloudflare IP ranges in UFW firewall
# (adds new rules BEFORE removing old ones — no race condition)
./maintenance.sh --update-firewall        # Automated weekly via systemd (Saturday 4 AM)

# Check and update Cloudflare DNS A record
./maintenance.sh --update-dns             # Automated hourly via systemd
make update-dns
```

### Deep Database Maintenance (On-Demand)

This **stops VaultWarden temporarily** and runs a full VACUUM cycle. Use it when the database is fragmented or unusually large.

```bash
# Interactive (prompts for confirmation)
sudo ./maintenance.sh --db-maint
make db-maint

# Non-interactive (skip confirmation)
sudo ./maintenance.sh --db-maint --force

# Steps performed:
#  1. Pre-maintenance encrypted backup
#  2. Stop VaultWarden container
#  3. PRAGMA integrity_check
#  4. PRAGMA wal_checkpoint(TRUNCATE)
#  5. PRAGMA optimize + ANALYZE
#  6. VACUUM
#  7. Post-VACUUM integrity check
#  8. Restart VaultWarden and wait for health
#  9. Report size delta (before → after)
#  Note: Automated lightweight optimisation runs monthly via systemd
```

### Email Diagnostics (On-Demand)

```bash
# Run full email diagnostic suite
./maintenance.sh --test-email
make test-email

# Verbose diagnostics
./maintenance.sh --test-email --verbose

# Override recipient
./maintenance.sh --test-email --recipient admin@example.com

# Dry run (reports system state, does not send)
./maintenance.sh --test-email --dry-run

# Tests performed:
#  1. Postfix container running and port 587 responding
#  2. Fail2ban can reach postfix SMTP
#  3. Host script send_notification_email() available
#  4. End-to-end test email sent
```

---

## 🔒 Security Operations

### Fail2ban Management

```bash
# Overall status
docker compose exec fail2ban fail2ban-client status

# Specific jail
docker compose exec fail2ban fail2ban-client status vaultwarden-auth

# Manual ban / unban
docker compose exec fail2ban fail2ban-client set vaultwarden-auth banip   1.2.3.4
docker compose exec fail2ban fail2ban-client set vaultwarden-auth unbanip 1.2.3.4

# Check Cloudflare ban actions
docker compose logs fail2ban | grep "cloudflare-apiv4"
```

### Secrets Management

```bash
# Edit secrets interactively
./edit-secrets.sh
make edit-secrets

# View decrypted secrets without editing
./edit-secrets.sh --view
make test-secrets

# Rotate secrets:
# 1. Edit
./edit-secrets.sh
# 2. Update admin_token, admin_basic_auth_hash, smtp_password, etc.
# 3. Restart to apply
./startup.sh --force
./health.sh
```

### Break-Glass Admin Management

```bash
# Create emergency admin account
./create-breakglass-admin.sh --create
make breakglass-create

# Check status
./create-breakglass-admin.sh --status
make breakglass-status

# Generate new password
./create-breakglass-admin.sh --password

# Remove when no longer needed
./create-breakglass-admin.sh --remove
make breakglass-remove
```

---

## ⚙️ Automated Operations (Systemd)

### Installing Systemd Timers

```bash
sudo ./systemd-setup.sh --install
make cron-install
```

### Actual Schedule

| Schedule | Job |
|---|---|
| Daily 2 AM (Mon–Sat) | Comprehensive maintenance (Sunday skipped to avoid overlap with full backup) |
| Mon–Sat 4 AM (+ 0–60 s jitter) | Database backup with fast verification + rclone sync |
| Every 30 minutes | Health check with auto-recovery + email on failure |
| Saturday 4 AM | Cloudflare firewall IP range update |
| Sunday 3 AM | Weekly full backup with comprehensive verification + rclone sync |
| Every hour | DNS A record update via `maintenance.sh --update-dns` |

> **Note:** Maintenance is intentionally skipped on Sunday to prevent overlap with the 3 AM full backup. `RandomizedDelaySec=60` on the database backup timer spreads post-reboot catch-up bursts.

```bash
# View installed timers
sudo ./systemd-setup.sh --list
make cron-list

# Validate security and detect split-brain (stale /opt/ scripts)
sudo ./systemd-setup.sh --validate

# Remove timers
sudo ./systemd-setup.sh --remove
make cron-remove

# Re-run after pulling repo updates to keep /opt/ in sync
sudo ./systemd-setup.sh --install
```

> **Migration note:** The earlier `cron-setup.sh` has been replaced by `systemd-setup.sh`. If you set up on a previous version, remove old cron entries (`sudo crontab -l`, delete the VaultWarden block with `sudo crontab -e`), then run `sudo ./systemd-setup.sh --install`.

### Failure Notifications

Every systemd service unit sets `OnFailure=vaultwarden-notify-failure@%n.service`. That template unit sends an email via Postfix. To confirm failure email delivery:

```bash
# Simulate a failure notification
systemctl start vaultwarden-notify-failure@vaultwarden-db-backup.service
```

### Email Notifications

All notifications use the containerised Postfix relay (`bokysan/docker-postfix`, port 587).

```bash
# Full diagnostic
./maintenance.sh --test-email --verbose

# Check Postfix logs
docker compose logs postfix

# Check Postfix port
docker compose exec postfix nc -z localhost 587
```

---

## 📊 Resource Monitoring

### Container Resource Usage

```bash
# Real-time
docker stats

# Snapshot
docker stats --no-stream

# Configured resource limits:
# VaultWarden: 512 MB memory, 30% CPU
# Caddy:       512 MB memory, 25% CPU
# Fail2ban:    512 MB memory, 15% CPU
# Postfix:     256 MB memory, 10% CPU
```

### System Resource Usage

```bash
free -h                                  # Memory
df -h                                    # Disk
du -sh /var/lib/vaultwarden/*            # State directory breakdown
```

> **Note:** Replace `/var/lib/vaultwarden` with your `PROJECT_STATE_DIR` value from `.env` if customised.

### Performance Optimisation

```bash
# 1. Review log sizes
du -sh /var/lib/vaultwarden/logs/*

# 2. Review backup storage
ls -lh /var/lib/vaultwarden/backups/

# 3. Run maintenance
./maintenance.sh --comprehensive

# 4. Adjust resource limits if needed
# Edit docker-compose.yml.example then:
sudo ./setup.sh --force --domain vault.example.com --email admin@example.com
```

---

## 🔧 Troubleshooting Operations

### Service Won't Start

```bash
# 1. Validate compose config
docker compose config

# 2. Check secrets exist
ls -la secrets/.docker_secrets/

# 3. View startup errors
docker compose up

# 4. Per-container logs
docker compose logs vaultwarden
docker compose logs caddy
docker compose logs fail2ban
docker compose logs postfix

# 5. Force restart
./startup.sh --force
```

### High Resource Usage

```bash
# 1. Identify heavy container
docker stats --no-stream

# 2. Check container logs
docker compose logs <container> --tail=100

# 3. Check log file growth
du -sh /var/lib/vaultwarden/logs/*

# 4. Run maintenance
./maintenance.sh --comprehensive
```

### Email Not Working

```bash
# Full diagnostic
./maintenance.sh --test-email --verbose

# Individual checks
docker compose ps postfix
docker compose logs postfix
grep SMTP .env
./edit-secrets.sh --view    # View smtp_password and verify decryption
```

### Fail2ban Not Blocking

```bash
# 1. Check status
docker compose exec fail2ban fail2ban-client status
docker compose exec fail2ban fail2ban-client status vaultwarden-auth

# 2. Test filter regex
docker compose exec fail2ban fail2ban-regex \
  /var/log/vaultwarden/vaultwarden.log \
  /data/fail2ban/filter.d/vaultwarden-auth.conf

# 3. Verify Cloudflare API token
docker compose exec fail2ban env | grep CF_
docker compose logs fail2ban | grep -i cloudflare

# 4. Check for \r\n line endings in Caddy JSON log volume (OCI NFS mounts)
file /var/lib/vaultwarden/logs/caddy/auth_attempts.log
# If CRLF is reported, verify fail2ban filter.d failregex patterns end with \r?$
```

### Backup Issues

```bash
# 1. Check disk space
df -h

# 2. Check Age key
ls -la secrets/keys/age-key.txt

# 3. Test backup manually
./backup.sh --type db

# 4. Check systemd job output
journalctl -u vaultwarden-db-backup.service --no-pager

# 5. Manually test Age key round-trip
source lib/simple_key_resilience.sh && simple_verify_age_key
```

---

## 📋 Template Maintenance

```bash
# 1. Edit templates
nano docker-compose.yml.example
nano .env.example

# 2. Validate syntax
docker compose -f docker-compose.yml.example config

# 3. Backup before applying
./backup.sh --type emergency

# 4. Apply to production
sudo ./setup.sh --force --domain vault.example.com --email admin@example.com

# 5. Re-apply Cloudflare firewall CIDRs (setup --force resets UFW rules)
./maintenance.sh --update-firewall

# 6. Restart and verify
./startup.sh --force
./health.sh
```

**Template best practices:**
- ✅ Edit `.example` files — never directly edit generated files
- ✅ Validate templates before applying
- ✅ Test in non-production first
- ✅ Create a backup before major changes
- ✅ Document customisations in template comments

---

## 📅 Operational Checklists

### Daily
- ✅ Check automated backup success (`journalctl -u vaultwarden-db-backup.service` or email notification)
- ✅ Review health check results
- ✅ Glance at fail2ban for unusual ban activity

### Weekly
- ✅ Review full backup with verification results (`journalctl -u vaultwarden-full-backup.service`)
- ✅ Check container update results
- ✅ Review authentication failure patterns
- ✅ Verify email notifications working
- ✅ Check disk space usage

### Monthly
- ✅ Review comprehensive maintenance results
- ✅ Test backup restoration (`./restore.sh`)
- ✅ Review security logs
- ✅ Check for available updates
- ✅ Verify break-glass admin access

### Quarterly
- ✅ Test emergency procedures (break-glass admin)
- ✅ Update Cloudflare IP ranges (`./maintenance.sh --update-firewall`) — also automated weekly via systemd
- ✅ Review and update documentation
- ✅ Audit user accounts and permissions
- ✅ Test complete system rebuild from backup
- ✅ Run `sudo ./systemd-setup.sh --validate` to detect any split-brain between `/opt/` and the current repo

### Annual
- ✅ Rotate all secrets (tokens, passwords)
- ✅ Review and update security policies
- ✅ Audit complete system configuration
- ✅ Update to latest stable container versions
- ✅ Review backup retention policies

---

## 📖 Makefile Quick Reference

```bash
# Service Management
make start              # Start all services (alias: make up)
make stop               # Stop all services (alias: make down)
make restart            # Restart with enhanced script
make safe-restart       # Restart with auto-rollback on failure
make status             # Show service status

# Monitoring
make health                        # Basic health check
make health AUTO_RECOVER=true      # With auto-recovery
make health COMPREHENSIVE=true     # Comprehensive check
make health-email                  # Comprehensive + email
make logs                          # All service logs
make logs SERVICE=vaultwarden      # Specific service
make logs-postfix                  # Postfix email logs
make monitor                       # Real-time log stream
make watch                         # Live status + health

# Backups
make backup              # Database backup
make backup-full         # Full system backup
make backup-emergency    # Emergency recovery kit
make list-backups        # List available backups
make restore             # Interactive restore
make restore-db          # Restore latest DB backup

# Updates & Maintenance
make update              # Update container images
make update-system       # Update system + containers
make maintenance         # Comprehensive maintenance
make maintenance-full    # Comprehensive + email notification
make db-maint            # Deep database maintenance (sudo)
make update-dns          # Update Cloudflare DNS record
make test-email          # Full email diagnostic

# Security
make edit-secrets        # Edit encrypted secrets
make test-secrets        # Test secrets decryption
make breakglass-create   # Create emergency admin
make breakglass-status   # Check emergency admin status
make breakglass-remove   # Remove emergency admin

# Automation
make cron-install        # Install systemd timers (delegates to systemd-setup.sh)
make cron-list           # List scheduled timers
make cron-remove         # Remove timers

# Configuration & Info
make config              # Show configuration summary
make test-config         # Validate docker-compose config
make fmt                 # Validate all config files
make info                # System info + service status
make version             # Container version info
make dry-run             # Preview all operations
make shell               # Shell in vaultwarden container
make shell SERVICE=caddy # Shell in specific container
```
