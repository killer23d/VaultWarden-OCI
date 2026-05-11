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
./startup.sh stop

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

# Or via Makefile
make restart

# Safe restart with auto-rollback on health failure
make safe-restart
```

---

### Health Monitoring

#### Basic Health Check

```bash
./maintenance.sh health

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

#### Quick Health Check

```bash
# Fast sanity check — port up + container running (no deep tests)
make health-quick
```

#### Comprehensive Health Check

```bash
./maintenance.sh health --comprehensive

# Additional checks:
#  ✓ CPU and memory usage vs alert threshold
#  ✓ .env and secrets.yaml configuration validation
#  ✓ Fail2ban responding, Age key valid, SOPS config present
```

#### Health Check with Auto-Recovery

```bash
# Automatically restart unhealthy containers
./maintenance.sh health --fix

# Combined — comprehensive check + auto-recovery
./maintenance.sh health --comprehensive --fix

# Or via Makefile
make health AUTO_RECOVER=true
make health-quick   # comprehensive check
```

> **Note:** Supported flags: `--comprehensive` (runs additional checks), `--fix` (restarts unhealthy containers), `--report` (save report to file), and `--quiet` (suppresses non-error console output).

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
# All services — last 100 lines (default)
make logs

# Tail / follow all services
make logs FOLLOW=true
make logs-tail

# Specific service
docker compose logs vaultwarden --follow --tail=50
make logs SERVICE=vaultwarden

# Per-service shortcuts
make logs-vaultwarden   # VaultWarden application logs
make logs-caddy         # Caddy reverse-proxy logs
make logs-postfix       # Postfix email relay logs
make logs-fail2ban      # Fail2ban intrusion-prevention logs

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
| :-- | :-- | :-- |
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
./backup.sh run db
make backup        # defaults to TYPE=db if omitted
make backup TYPE=db
make db-backup     # alias

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
./backup.sh run full
make backup-full
make backup TYPE=full

# Includes: database, config files, Caddy certificates, logs
# Excludes: secrets (use backup.sh run emergency for those)
# Retention: 30 days
# Requires: zstd (installed by setup.sh)
```

#### Full Backup with End-to-End Verification

```bash
./backup.sh run full --full-verification

# Process: create → decrypt → extract → integrity check → verify files → cleanup
# Recommended: weekly (matches systemd timer default)
```

#### Emergency Recovery Kit

```bash
./backup.sh run emergency
make backup-emergency
make backup TYPE=emergency

# Includes everything, including secrets — full disaster recovery
# Retention: 90 days
```

### Remote Backups (rclone)

```bash
# Configure a remote first
rclone config
# Set RCLONE_REMOTE_NAME in .env

# Backup + sync to remote
./backup.sh run db --rclone
./backup.sh run full --rclone --email
```

Supported remotes: Google Drive, Amazon S3, Backblaze B2, Dropbox, OneDrive, and all other rclone-supported providers.

### Managing Backups

```bash
# List all backups
./backup.sh list
make list-backups

# Backup health summary — last run time, size, retention, count per type
make backup-status

# Interactive restore (recommended)
./restore.sh interactive
make restore

# Restore specific file
./restore.sh latest --file /path/to/backup.age

# Restore latest DB backup (interactive confirmation + key prompt)
make restore-db

# Restore from a remote (rclone) backup — interactive selection
make restore-remote
```

---

## ⬆️ Update Operations

### Updating Containers

```bash
# Update container images (respects version pins in .env)
./maintenance.sh update
make update

# Update containers + system packages
./maintenance.sh update --system
make update-system
```

> **`--system` scope:** `./maintenance.sh update --system` (alias `make update-system`) does three things in order:
> 1. Runs `apt-get upgrade` to update OS packages
> 2. Updates the Docker engine via apt
> 3. Pulls new container images and restarts affected services
>
> **Rollback scope:** `restore.sh` covers data and configuration only. OS packages and the Docker engine are **not** rolled back automatically — ensure you have an OCI instance snapshot or are prepared to re-run the upgrade if the system update causes issues.

### Version Management

**Production mode — pinned versions (default):**

```bash
# .env (set by setup.sh install --auto)
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
./backup.sh run emergency

# Pull and restart
docker compose pull vaultwarden
docker compose up -d vaultwarden

./maintenance.sh health
```

> **VaultWarden 1.30.0+ note:** Port 3012 (legacy WebSocket) was removed. All real-time sync now goes through the main HTTP port 80. The Caddyfile `/notifications/hub` block already routes to `vaultwarden:80`; no manual change is needed for upgrades.

---

## 🛠️ Maintenance Operations

### Routine Maintenance

```bash
# Full maintenance: cleanup + Docker prune + DB optimisation + DNS + firewall
./maintenance.sh run --comprehensive
make maintenance

# With email summary
./maintenance.sh run --comprehensive --email
make maintenance-full

# Dry run — preview without changes
./maintenance.sh run --comprehensive --dry-run
```

### Targeted Tasks

When called with only a targeted flag, routine cleanup is **skipped entirely**:

```bash
# Update Cloudflare IP ranges in UFW firewall
# (adds new rules BEFORE removing old ones — no race condition)
./maintenance.sh update-firewall        # Automated weekly via systemd (Saturday 4 AM)

# Check and update Cloudflare DNS A record
./maintenance.sh update-dns             # Automated hourly via systemd
make update-dns
```

### Deep Database Maintenance (On-Demand)

This **stops VaultWarden temporarily** and runs a full VACUUM cycle. Use it when the database is fragmented or unusually large.

```bash
# Interactive (prompts for confirmation)
sudo ./maintenance.sh db-maint
make db-maint

# Non-interactive (skip confirmation)
sudo ./maintenance.sh db-maint --force

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
./maintenance.sh test-email
make test-email

# Verbose diagnostics
./maintenance.sh test-email --verbose

# Override recipient
./maintenance.sh test-email --recipient admin@example.com

# Dry run (reports system state, does not send)
./maintenance.sh test-email --dry-run

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
./edit-secrets.sh edit
make edit-secrets

# View decrypted secrets without editing
./edit-secrets.sh view
make test-secrets

# Rotate secrets:
# 1. Edit
./edit-secrets.sh edit
# 2. Update admin_token, admin_basic_auth_hash, smtp_password, etc.
# 3. Restart to apply
./startup.sh --force
./maintenance.sh health
```

### Age Key Management

```bash
# Show current age public key and key file path/status
make key-show

# Check age key health (permissions, decodability, SOPS_AGE_KEY_FILE)
make key-health

# Rotate the age encryption key
# Generates a new key and updates all locations.
# WARNING: store the new key displayed at the end in a secure location.
sudo make key-rotate
```

> **Key rotation note:** After rotation, new backups will use the new key. Existing backups remain decryptable only with the old key. Export and store both keys offline before rotation.

### Break-Glass Admin Management

```bash
# Create emergency admin account
./create-breakglass-admin.sh create
make breakglass-create

# Check status
./create-breakglass-admin.sh list
make breakglass-status

# Generate new password
./create-breakglass-admin.sh create --force

# Remove when no longer needed
./create-breakglass-admin.sh revoke
make breakglass-remove
```

---

## ⚙️ Automated Operations (Systemd)

### Installing Systemd Timers

```bash
sudo ./setup.sh systemd install
make install-systemd
```

### Actual Schedule

| Schedule | Job |
| :-- | :-- |
| Mon–Sat 02:05 (+ 0–30 s jitter) | Comprehensive maintenance (Sunday skipped to avoid overlap with full backup) |
| Daily 04:00 (+ 0–30 s jitter) | Database backup with fast verification + rclone sync |
| Every 30 minutes | Health check with auto-recovery + email on failure |
| Saturday 4 AM | Cloudflare firewall IP range update |
| Sunday 3 AM | Weekly full backup with comprehensive verification + rclone sync |
| Every hour | DNS A record update via `maintenance.sh update-dns` |

> **Note:** Maintenance is intentionally skipped on Sunday to prevent overlap with the 3 AM full backup. `RandomizedDelaySec=30` on the database backup and maintenance timers spreads post-reboot catch-up bursts.

```bash
# View installed timers (next trigger + last run)
make timers
sudo ./setup.sh systemd status

# Validate installed units match current repo scripts
sudo ./setup.sh systemd validate
make systemd-validate

# Remove timers
sudo ./setup.sh systemd remove
make systemd-remove

# Re-run after pulling repo updates to keep /opt/ in sync
sudo ./setup.sh systemd install
```

> **Migration note:** The earlier `cron-setup.sh` has been replaced by the `setup.sh systemd` systemd integration. If you set up on a previous version, remove old cron entries (`sudo crontab -l`, delete the VaultWarden block with `sudo crontab -e`), then run `sudo ./setup.sh systemd install`.

### Failure Notifications

Every systemd service unit sets `OnFailure=vaultwarden-notify-failure.service`. That unit sends an email via Postfix. To confirm failure email delivery:

```bash
# Simulate a failure notification
systemctl start vaultwarden-notify-failure.service
```

### Email Notifications

All notifications use the containerised Postfix relay (`bokysan/docker-postfix`, port 587).

```bash
# Full diagnostic
./maintenance.sh test-email --verbose

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
./maintenance.sh run --comprehensive

# 4. Adjust resource limits if needed
# Edit docker-compose.yml.example then:
sudo ./setup.sh install --domain vault.example.com --email admin@example.com --force
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

# 6. Full diagnostic dump
make diagnose
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
./maintenance.sh run --comprehensive
```

### Email Not Working

```bash
# Full diagnostic
./maintenance.sh test-email --verbose

# Individual checks
docker compose ps postfix
docker compose logs postfix
grep SMTP .env
./edit-secrets.sh view    # View smtp_password and verify decryption
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
make key-health

# 3. Test backup manually
./backup.sh run db

# 4. Check systemd job output
journalctl -u vaultwarden-db-backup.service --no-pager

# 5. Manually test Age key round-trip
simple_verify_age_key
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
./backup.sh run emergency

# 4. Apply to production
sudo ./setup.sh install --domain vault.example.com --email admin@example.com --force

# 5. Re-apply Cloudflare firewall CIDRs (setup --force resets UFW rules)
./maintenance.sh update-firewall

# 6. Restart and verify
./startup.sh --force
./maintenance.sh health
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
- ✅ Test backup restoration (`./restore.sh interactive`)
- ✅ Review security logs
- ✅ Check for available updates
- ✅ Verify break-glass admin access

### Quarterly
- ✅ Test emergency procedures (break-glass admin)
- ✅ Update Cloudflare IP ranges (`./maintenance.sh update-firewall`) — also automated weekly via systemd
- ✅ Review and update documentation
- ✅ Audit user accounts and permissions
- ✅ Test complete system rebuild from backup
- ✅ Run `sudo ./setup.sh systemd validate` to detect any split-brain between `/opt/` and the current repo

### Annual
- ✅ Rotate all secrets (tokens, passwords)
- ✅ Rotate the Age encryption key (`sudo make key-rotate`) and store the new key offline
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
make restart            # Restart with enhanced startup script
make safe-restart       # Restart with auto-rollback on failure
make status             # Show service status

# Monitoring
make health                        # Basic health check
make health-quick                  # Fast sanity check (port + container only)
make health AUTO_RECOVER=true      # With auto-recovery
make health COMPREHENSIVE=true     # Comprehensive check
make health-email                  # Comprehensive + email
make logs                          # All service logs (last 100 lines)
make logs FOLLOW=true              # Follow / tail all service logs
make logs SERVICE=vaultwarden      # Specific service
make logs-tail                     # Tail all services with timestamps
make logs-vaultwarden              # Tail VaultWarden logs
make logs-caddy                    # Tail Caddy logs
make logs-postfix                  # Tail Postfix email logs
make logs-fail2ban                 # Tail Fail2ban logs
make monitor                       # Real-time log stream
make watch                         # Live status + quick health every 5 s
make diagnose                      # Full diagnostic dump (versions, key, disk, containers, logs)

# Backups
make backup              # Database backup (TYPE=db default)
make backup TYPE=full    # Full system backup
make backup TYPE=emergency # Emergency recovery kit
make backup-full         # Alias for TYPE=full
make backup-emergency    # Alias for TYPE=emergency
make db-backup           # Alias for TYPE=db
make backup-status       # Backup health summary (last run, size, retention, count)
make list-backups        # List available backups
make restore             # Interactive restore
make restore-db          # Restore latest DB backup
make restore-remote      # Restore from rclone remote (interactive)

# Updates & Maintenance
make update              # Update container images
make update-system       # Update system + containers
make maintenance         # Comprehensive maintenance
make maintenance-full    # Comprehensive + email notification
make db-maint            # Deep database maintenance (sudo)
make update-dns          # Update Cloudflare DNS record
make test-email          # Full email diagnostic
make lint                # Shellcheck all shell scripts
make prune               # Remove unused Docker resources

# Age Key Management
make key-show            # Show age public key and key file status
make key-health          # Check age key health (permissions, decodability)
sudo make key-rotate     # Rotate the age encryption key

# Security
make edit-secrets        # Edit encrypted secrets
make test-secrets        # Test secrets decryption
make breakglass-create   # Create emergency admin
make breakglass-status   # Check emergency admin status
make breakglass-remove   # Remove emergency admin

# Automation
make install-systemd     # Install systemd timer units
make systemd-status      # Show status of all vaultwarden systemd units
make systemd-validate    # Validate installed units match current repo scripts
make systemd-remove      # Remove all vaultwarden systemd timer units
make timers              # List timers (next trigger + last run + .env schedule)

# Uninstall
make uninstall-dry-run   # Preview what uninstall would remove
make uninstall           # Full uninstall (DESTRUCTIVE — interactive confirmation required)

# Development
make dev-setup           # Setup development environment
make test                # Run all tests (secrets, email, compose config)
make test-config         # Validate docker-compose config only
make fmt                 # Validate all config files
make dry-run             # Preview all operations without executing

# Configuration & Info
make config              # Show configuration summary (sensitive keys redacted)
make info                # System info + version + age key + disk usage
make version             # Container version info
make shell               # Shell in vaultwarden container
make shell SERVICE=caddy # Shell in specific container
```
