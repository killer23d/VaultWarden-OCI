# Troubleshooting Guide - VaultWarden-OCI

Common issues and solutions for VaultWarden-OCI deployment and operations.

## General Troubleshooting Approach

1. **Check service status**: `./maintenance.sh health` or `make health`
2. **Review logs**: `docker compose logs` or `make logs`
3. **Validate configuration**: `docker compose config` or `make test-config`
4. **Check resources**: `docker stats`
5. **Verify connectivity**: Test network, DNS, and firewall

## Service Issues

### Services Won't Start

**Symptoms**:
- Services fail to start
- Containers exit immediately
- Docker Compose errors

**Diagnosis**:
```bash
# Check service status
./maintenance.sh health
docker compose ps

# View logs
docker compose logs
make logs

# Validate configuration
docker compose config
make test-config
```

**Solutions**:
```bash
# Fix configuration and restart
./startup.sh --force
make restart

# If templates are invalid, validate first
docker compose -f docker-compose.yml.example config

# Regenerate from templates
sudo ./setup.sh install --domain vault.example.com --email admin@example.com --force
./startup.sh --force
```

### VaultWarden Container Crashes

**Symptoms**:
- VaultWarden container stops unexpectedly
- Database errors in logs
- Web vault inaccessible

**Diagnosis**:
```bash
# Check VaultWarden logs
docker compose logs vaultwarden | tail -100
make logs SERVICE=vaultwarden

# Check for database issues (uses host sqlite3)
sudo sqlite3 "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/data/db.sqlite3" 'PRAGMA integrity_check;'

# Check resource usage
docker stats $(docker compose ps -q vaultwarden)
```

**Solutions**:
```bash
# Deep database maintenance (stops VaultWarden temporarily)
sudo ./maintenance.sh db-maint
# or via Makefile:
make db-maint

# If database is corrupt, restore from backup
./restore.sh latest db
# or restore latest DB backup non-interactively:
make restore-db

# Check resource limits
docker inspect $(docker compose ps -q vaultwarden) | grep -A 10 Memory

# Increase limits if needed (edit template)
nano docker-compose.yml.example
sudo ./setup.sh install --domain vault.example.com --email admin@example.com --force
./startup.sh --force
```

### Caddy Certificate Issues

**Symptoms**:
- HTTPS not working
- Certificate errors
- DNS-01 challenge failures

**Diagnosis**:
```bash
# Check Caddy logs
docker compose logs caddy | grep -i error
make logs SERVICE=caddy

# Verify Cloudflare API token
./utilities/secrets-list.sh

# Check DNS resolution
dig +short vault.example.com

# Test Cloudflare DNS API token
curl -X GET "https://api.cloudflare.com/client/v4/zones" \
     -H "Authorization: Bearer YOUR_DNS_TOKEN"
```

**Solutions**:
```bash
# Verify Cloudflare DNS token in secrets
./utilities/secrets-edit.sh
# Ensure caddy_cloudflare_dns_token is set

# Restart Caddy to retry
docker compose restart caddy

# Force certificate renewal
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

### Caddy Exits with BCrypt Hash Error

**Symptoms**:
- Caddy container fails to start and exits immediately
- Error in logs: `ERROR: bcrypt cost N < minimum 10`
- Admin panel inaccessible after updating `admin_basic_auth_hash`

**Diagnosis**:
```bash
# Check Caddy entrypoint logs
docker compose logs caddy | tail -30

# Verify the cost factor of your current hash (factor is between the second and third $)
# Example hash: $2b$06$... means cost=6 (too low)
grep admin_basic_auth_hash "${SECRETS_FILE:-secrets/secrets.yaml}"   # encrypted; use utilities/secrets-edit.sh
./utilities/secrets-list.sh
```

**Solutions**:
```bash
# Generate a new compliant bcrypt hash (cost factor >=14 recommended)
# Use the Caddy image already in use to avoid version mismatch
docker run --rm -it ghcr.io/caddybuilds/caddy-cloudflare:latest caddy hash-password --cost 14

# Update the hash in secrets
./utilities/secrets-edit.sh
# Set admin_basic_auth_hash to the new hash string

# Restart Caddy
docker compose restart caddy
```

> **Note**: The minimum enforced cost factor is **10** (OWASP minimum). A cost of **14** is
> recommended for 2024+ hardware. The Caddy entrypoint validates this on every start.


### Startup Fails: `docker-compose.override.yml exists`

**Symptoms**:
- `make up` exits before containers start
- Error mentions development override is present

**Diagnosis**:
```bash
ls -l docker-compose.override.yml
make up
```

**Solutions**:
```bash
# Production hosts should not use dev override
mv docker-compose.override.yml docker-compose.override.yml.bak

# Start again
make up
```

---

### Startup Fails: User Not in Docker Group

**Symptoms**:
- `make up` returns `Cannot connect to the Docker daemon`
- `docker info` fails as non-root

**Diagnosis**:
```bash
id
docker info
```

**Solutions**:
```bash
sudo usermod -aG docker $USER
# log out and back in, then:
docker info
make up
```

---

### Health Check Reports Placeholder Secrets (`CHANGE_ME`)

**Symptoms**:
- `make health` reports missing/placeholder secrets
- Email/API/DNS integrations fail despite containers running

**Diagnosis**:
```bash
./utilities/secrets-list.sh
./maintenance.sh health
```

**Solutions**:
```bash
# Rotate each placeholder secret with real values
./utilities/secrets-rotate.sh caddy_cloudflare_dns_token
./utilities/secrets-rotate.sh smtp_password

# provider-specific token example
./utilities/secrets-rotate.sh email_api_token

make restart
make health
```

---

## Configuration Issues

### Template Validation Errors

**Symptoms**:
- `docker compose config` fails
- Syntax errors in generated files
- Services won't start due to config errors

**Diagnosis**:
```bash
# Validate template
docker compose -f docker-compose.yml.example config

# Validate compose template plus the example environment
docker compose --env-file .env.example -f docker-compose.yml.example config --quiet

# Validate current config
docker compose config
make test-config
```

**Solutions**:
```bash
# Fix template syntax
nano docker-compose.yml.example

# Validate after changes
docker compose -f docker-compose.yml.example config

# Regenerate from fixed template
sudo ./setup.sh install --domain vault.example.com --email admin@example.com --force
```

### Environment Variable Issues

**Symptoms**:
- Services missing configuration
- Incorrect behavior
- Connection failures

**Diagnosis**:
```bash
# Check .env file
cat .env | grep -v "^#"

# Verify critical variables are set
grep -E "DOMAIN|CLOUDFLARE_ZONE_ID|SMTP_HOST|ADMIN_EMAIL" .env

# Check if services are using environment
docker compose config | grep -A 5 environment
```

**Solutions**:
```bash
# Edit environment file
nano .env

# Or regenerate from template
cp .env.example .env
# Edit with correct values
nano .env

# Restart services to apply
./startup.sh --force
```

### Secrets Decryption Failures

**Symptoms**:
- Cannot edit secrets
- Services can't load secrets
- Age decryption errors

**Diagnosis**:
```bash
# Test secrets decryption
./utilities/secrets-list.sh
make test-secrets

# Verify Age key exists
ls -l secrets/keys/age-key.txt

# Check permissions
ls -la secrets/
```

**Solutions**:
```bash
# If Age key is missing, regenerate
sudo ./setup.sh install --domain vault.example.com --email admin@example.com --force

# Fix permissions
chmod 700 secrets/
chmod 600 secrets/keys/age-key.txt

# Test decryption manually (secrets are SOPS-encrypted; use sops -d)
sops -d "${SECRETS_FILE:-secrets/secrets.yaml}"
```

### Secrets Environment Leaking to Child Processes

**Symptoms**:
- `SOPS_AGE_KEY_FILE` remains set after running `./setup.sh`, `./utilities/secrets-edit.sh`, or `./setup.sh secrets`
- Docker or rclone subprocesses inherit the Age key file path (visible via `ps aux`)

**Diagnosis**:
```bash
# Check if SOPS env vars are exported into the current session
env | grep SOPS

# If called as a subprocess, confirm the calling script sources lib/secrets.sh
grep cleanup_secrets_environment setup.sh
```

**Solutions**:
```bash
# cleanup_secrets_environment() now actively unsets SOPS_AGE_KEY_FILE and SOPS_CONFIG.
# If you see these variables in child processes, ensure you are running the
# current version of the scripts.
git pull

# Manually unset if needed in the current session:
unset SOPS_AGE_KEY_FILE
unset SOPS_CONFIG

# Re-run the affected script
./utilities/secrets-edit.sh
```

## Network and Connectivity Issues

### Cannot Access Web Vault

**Symptoms**:
- HTTPS site unreachable
- Connection timeout
- DNS resolution failures

**Diagnosis**:
```bash
# Check if services are running
docker compose ps

# Test local connectivity (Caddy internal health endpoint)
curl -I http://localhost:8080/alive

# Check Caddy logs
docker compose logs caddy | grep -i error

# Verify DNS resolution
dig +short vault.example.com

# Check firewall
sudo ufw status
```

**Solutions**:
```bash
# Restart services
./startup.sh --force

# Update DNS if IP changed (targeted mode — no cleanup)
./maintenance.sh update-dns

# Verify Cloudflare proxy is enabled
# Check Cloudflare dashboard: DNS → Proxied (orange cloud)

# Update firewall if Cloudflare IPs changed
./maintenance.sh update-firewall
```

### Firewall Blocking Access

**Symptoms**:
- Connection refused
- Timeout errors
- Can't reach services

**Diagnosis**:
```bash
# Check UFW status
sudo ufw status numbered

# Check for Cloudflare rules
sudo ufw status | grep "CF-IPv"

# Test from external IP
curl -I https://vault.example.com
```

**Solutions**:
```bash
# Safely update Cloudflare IP ranges (adds new rules before removing old)
./maintenance.sh update-firewall

# If firewall is blocking everything, check UFW
sudo ufw status

# Emergency: temporarily disable UFW (NOT RECOMMENDED for production)
# sudo ufw disable
# Fix firewall rules, then:
# sudo ufw enable

# Schedule safe recurring firewall updates (Saturday 4 AM via systemd timer)
make install-systemd
```

### DNS Not Updating

**Symptoms**:
- Wrong IP in DNS
- Dynamic IP changed but DNS still old
- Cannot reach site after IP change

**Diagnosis**:
```bash
# Check current public IP
curl -s https://checkip.amazonaws.com

# Check DNS record
dig +short vault.example.com @1.1.1.1

# Compare IPs
echo "Public IP: $(curl -s https://checkip.amazonaws.com)"
echo "DNS IP:    $(dig +short vault.example.com @1.1.1.1 | head -1)"
```

**Solutions**:
```bash
# Manual DNS update (targeted mode — no routine cleanup)
./maintenance.sh update-dns

# Or via Makefile
make update-dns

# Verify Cloudflare API token works
curl -X GET "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID" \
     -H "Authorization: Bearer YOUR_DNS_TOKEN"

# Check CLOUDFLARE_ZONE_ID in .env
grep CLOUDFLARE_ZONE_ID .env
```

## Email Issues

> **For a comprehensive reference on email architecture, the three-tier provider
> chain (`EMAIL_MODE` / `EMAIL_PROVIDER`), and a full troubleshooting decision
> table, see [EMAIL.md](EMAIL.md).** The sections below cover the most common
> Postfix relay issues; EMAIL.md covers provider-specific failures, VaultWarden
> SMTP configuration, and the complete diagnostic flow.

### Email Not Sending (Postfix)

**Symptoms**:
- Email notifications not received
- SMTP errors in logs
- VaultWarden can't send email

**Diagnosis**:
```bash
# Check postfix container status
docker compose ps postfix
docker compose logs postfix
make logs-postfix                    # shortcut with timestamps

# Run full email diagnostic (4 tests)
./maintenance.sh test-email
# or via Makefile:
make test-email

# Verbose diagnostic output
./maintenance.sh test-email --verbose

# Preview without sending
./maintenance.sh test-email --dry-run

# Check postfix relay configuration
docker compose exec postfix postconf relayhost
docker compose exec postfix nc -z localhost 587
```

**Solutions**:
```bash
# Verify SMTP relay settings in .env
nano .env
# Check: SMTP_HOST, SMTP_PORT, SMTP_USERNAME, ALLOWED_SENDER_DOMAINS

# Verify SMTP password in secrets
./utilities/secrets-edit.sh
# Check: smtp_password

# Restart postfix
docker compose restart postfix

# Send test from VaultWarden admin panel
# Navigate to: https://vault.example.com/admin → SMTP Settings → Send Test Email
```

### SMTP Authentication Failures

**Symptoms**:
- Authentication failed errors
- 535 SMTP errors in logs
- Postfix can't connect to SMTP relay

**Diagnosis**:
```bash
# Check SMTP credentials
./utilities/secrets-list.sh

# View postfix logs for auth errors
docker compose logs postfix | grep -i "auth\|error\|fatal"

# Run verbose email diagnostic
./maintenance.sh test-email --verbose
```

**Solutions**:
```bash
# Update SMTP password
./utilities/secrets-edit.sh
# Set correct smtp_password

# Verify SMTP settings
nano .env
# Ensure SMTP_USERNAME matches your email
# Ensure SMTP_HOST and SMTP_PORT are correct

# For Gmail, create app-specific password
# https://myaccount.google.com/apppasswords

# Restart postfix and vaultwarden
docker compose restart postfix vaultwarden
```

## Backup and Restore Issues

### Backup Creation Fails

**Symptoms**:
- Backup script errors
- Insufficient disk space
- Encryption failures

**Diagnosis**:
```bash
# Check disk space
df -h ${PROJECT_STATE_DIR:-/var/lib/vaultwarden}

# Verify Age key
ls -l secrets/keys/age-key.txt

# Test backup with dry-run
./backup.sh run db --dry-run

# Check VaultWarden status
docker compose ps vaultwarden
```

**Solutions**:
```bash
# Free up disk space
./maintenance.sh run --comprehensive

# If Age key missing, regenerate
sudo ./setup.sh install --domain vault.example.com --email admin@example.com --force

# Retry backup
./backup.sh run db

# List existing backups
./backup.sh list
make list-backups
```

### Backup Verification Fails with Missing Age Key

**Symptoms**:
- Backup is created successfully but quick verification reports failure
- Error: `Age key not found — refusing to report verification success`
- Backup was previously silently marked verified despite missing key

**Diagnosis**:
```bash
# Check Age key existence
ls -l secrets/keys/age-key.txt

# Confirm the quick-verify actually tests decryption
./backup.sh list
```

**Explanation**: The `verify_backup_quick()` function previously returned **success (0)**
when the Age key file was absent, skipping the decrypt probe with only a warning and
marking the backup as verified. This was a fail-open bug. The function now **fails hard**
when the Age key cannot be found — a missing key means the backup cannot be verified
and must not be reported as recoverable.

**Solutions**:
```bash
# Restore or regenerate the Age key before attempting backup verification
ls -l secrets/keys/age-key.txt

# If key is missing: restore from your offline copy (recovery kit)
# If no offline copy exists, regenerate (WARNING: old backups become unrecoverable)
sudo ./setup.sh install --domain vault.example.com --email admin@example.com --force
```

### Backup Retention Not Cleaning Up Old Backups

**Symptoms**:
- Old backups accumulate past the configured retention period
- This is most common after restoring the project to a new host
- `./backup.sh list` shows backups with correct timestamps but `ctime = now`

**Explanation**: Backup age is now determined from the **filename-embedded timestamp**
(`YYYYMMDD-HHMMSS`), which is immutable across filesystem operations (`cp`, `mv`,
`chmod`, `chown`). On a fresh host restore, `ctime` is reset to now and would make
every backup appear 0 days old, preventing all cleanup. The filename timestamp
remains unchanged and is always the primary age source.

**Diagnosis**:
```bash
# List backups and confirm timestamp in filenames
./backup.sh list
# e.g. db-20240315-143022.age → created 15 March 2024

# Confirm retention setting
grep BACKUP_RETENTION .env
```

**Solutions**:
```bash
# No action needed if filenames contain YYYYMMDD-HHMMSS timestamps
# The retention logic will use the filename timestamp correctly

# If backups were created without a timestamp in the filename (pre-convention files),
# ctime fallback is used — rename those files manually or delete them
ls backups/db/ | grep -v '[0-9]\{8\}-[0-9]\{6\}'
```

### Restore Fails

**Symptoms**:
- Decryption errors
- Database corruption after restore
- Services won't start after restore

**Diagnosis**:
```bash
# Verify backup file integrity
sha256sum -c backup.age.sha256

# Test SOPS decryption against backup
sops -d "${SECRETS_FILE:-secrets/secrets.yaml}" > /dev/null

# Check backup metadata
cat backup.age.meta

# List all available backups
./backup.sh list
```

**Solutions**:
```bash
# Interactive restore (prompts for file selection)
./restore.sh interactive

# Restore latest DB backup directly
./restore.sh latest db
make restore-db

# Try older backup if current is corrupt
./restore.sh latest --file /path/to/older-backup.age

# After restore, verify services
./maintenance.sh health --comprehensive
```

### Offsite Backup Sync Fails

**Symptoms**:
- Rclone errors
- Connection timeouts
- Authentication failures

**Diagnosis**:
```bash
# Test rclone connectivity
rclone lsd your_remote_name:

# Check rclone config
rclone config show your_remote_name

# Verify remote name in .env
grep RCLONE_REMOTE_NAME .env
```

**Solutions**:
```bash
# Reconfigure rclone
rclone config

# Update remote name in .env
nano .env
# Set: RCLONE_REMOTE_NAME=your_remote_name

# Test with small file
echo "test" | rclone rcat your_remote_name:test.txt
rclone cat your_remote_name:test.txt

# Retry backup with rclone sync
./backup.sh run db --rclone
```

## Security Issues

### CrowdSec Not Blocking

**Symptoms**:
- Repeated failed login attempts
- IPs not being banned
- CrowdSec inactive

**Diagnosis**:
```bash
# Check CrowdSec status
sudo systemctl status crowdsec

# View active decisions
sudo cscli decisions list

# View recent alerts
sudo cscli alerts list --since 24h

# Check bouncer connectivity
sudo cscli bouncers list
```

**Solutions**:
```bash
# Restart CrowdSec
sudo systemctl restart crowdsec

# Verify Cloudflare firewall token
./utilities/secrets-edit.sh
# Check: cf_worker_bouncer_token (used by crowdsec-cloudflare-worker-bouncer)

# Test Cloudflare firewall token against the WAF Custom Rules endpoint
curl -X GET "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/rulesets/phases/http_request_firewall_custom/entrypoint" \
     -H "Authorization: Bearer YOUR_FIREWALL_TOKEN"

# Check acquis.yaml log paths
sudo cat /etc/crowdsec/acquis.yaml
```

### CrowdSec Not Parsing Caddy Logs

**Symptoms**:
- Auth failures visible in Caddy JSON logs
- No alerts triggered despite repeated failures

**Diagnosis**:
```bash
# Confirm log paths in acquis.yaml match actual file locations
sudo cscli metrics

# Check for parsing errors
sudo journalctl -u crowdsec -n 50
```

**Solutions**:
```bash
# Update acquis.yaml paths if needed
sudo nano /etc/crowdsec/acquis.yaml
sudo systemctl restart crowdsec
```

### Self-Lockout Recovery

If your IP is banned and you cannot access the vault:
```bash
# SSH to the server (vault bans do not affect SSH), then:
sudo cscli decisions delete --ip <your-ip>

# Optionally whitelist to prevent future bans
sudo cscli whitelists add myip <your-ip>
```

### Admin Panel Inaccessible

**Symptoms**:
- 401 Unauthorized errors
- Basic auth prompts repeatedly
- Cannot login to /admin

**Diagnosis**:
```bash
# Check Caddy basic auth configuration
docker compose logs caddy | grep admin

# Verify admin_basic_auth_hash in secrets
./utilities/secrets-list.sh
```

**Solutions**:
```bash
# Generate a new bcrypt hash (cost >=14 recommended; >=10 required)
docker run --rm -it ghcr.io/caddybuilds/caddy-cloudflare:latest caddy hash-password --cost 14

# Update secrets with new hash
./utilities/secrets-edit.sh
# Set: admin_basic_auth_hash (paste bcrypt hash)

# Restart Caddy to apply new hash
docker compose restart caddy

# Test admin access
curl -u "admin:your_password" https://vault.example.com/admin
```

### Break-Glass Admin Not Working

**Symptoms**:
- Cannot login via serial console, local console, or provider console
- SSH key authentication fails
- Emergency access unavailable

**Diagnosis**:
```bash
# Check break-glass admin status
sudo utilities/setup-secrets.sh breakglass status
make breakglass-status

# Verify user exists
sudo id vw-emergency

# Check SSH configuration
sudo cat /home/vw-emergency/.ssh/authorized_keys
```

**Solutions**:
```bash
# Remove and recreate break-glass admin
sudo utilities/setup-secrets.sh breakglass remove
sudo utilities/setup-secrets.sh breakglass create
# or:
make breakglass-remove
make breakglass-create

# Test via your provider serial console, local console, or OCI Console Connection
```

## Performance Issues

### High CPU Usage

**Symptoms**:
- System slow or unresponsive
- High CPU percentage in docker stats
- Services timing out

**Diagnosis**:
```bash
# Check container CPU usage
docker stats --no-stream

# Check for runaway processes
docker compose top

# Review resource limits
docker inspect $(docker compose ps -q vaultwarden) | grep -A 10 CPU
```

**Solutions**:
```bash
# Adjust CPU limits in template (defaults: VW 0.3, Caddy 0.25, Postfix 0.1)
nano docker-compose.yml.example
# Increase cpus value for affected container

# Regenerate and apply
sudo ./setup.sh install --domain vault.example.com --email admin@example.com --force
./startup.sh --force

# Run database maintenance if VaultWarden is CPU-heavy
sudo ./maintenance.sh db-maint
```

### High Memory Usage

**Symptoms**:
- Out of memory errors
- Containers being killed
- System swapping heavily

**Diagnosis**:
```bash
# Check memory usage
docker stats --no-stream

# Check for memory leaks
docker compose logs | grep -i "out of memory"

# Review memory limits
docker inspect $(docker compose ps -q vaultwarden) | grep -A 10 Memory
```

**Solutions**:
```bash
# Adjust memory limits in template
# Defaults: VaultWarden 512M, Caddy 512M, Postfix 256M
nano docker-compose.yml.example

# Regenerate and restart
sudo ./setup.sh install --domain vault.example.com --email admin@example.com --force
./startup.sh --force

# Run comprehensive maintenance to free resources
./maintenance.sh run --comprehensive
```

### Slow Database Performance

**Symptoms**:
- Slow web vault responses
- Database timeouts
- High database file size

**Diagnosis**:
```bash
# Check database size
du -h ${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/data/db.sqlite3

# Check database integrity (uses host sqlite3)
sudo sqlite3 "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/data/db.sqlite3" 'PRAGMA integrity_check;'

# Review VaultWarden logs
docker compose logs vaultwarden | grep -i slow
```

**Solutions**:
```bash
# Deep database maintenance: VACUUM + WAL checkpoint + optimize
sudo ./maintenance.sh db-maint
make db-maint

# Non-interactive (skip confirmation prompt)
sudo ./maintenance.sh db-maint --force

# Review and remove old items via admin panel:
# https://vault.example.com/admin → Users → Purge Trash / Sends

# Restart VaultWarden
docker compose restart vaultwarden
```

## Cron / Automation Issues

### Systemd Timers Not Running

**Symptoms**:
- Scheduled backups or maintenance not occurring
- Health alerts not being sent
- Timers absent from `systemctl list-timers`

**Diagnosis**:
```bash
# List installed VaultWarden systemd timers
sudo ./setup.sh systemd status
make systemd-status

# Validate security and dependencies
sudo ./setup.sh systemd validate

# Check timer logs via journald
journalctl -u vaultwarden-maintenance.service -n 50
journalctl -u vaultwarden-db-backup.service -n 100
journalctl -u vaultwarden-health.service -n 50

# Check systemd timer status
systemctl list-timers --all | grep vaultwarden
```

**Solutions**:
```bash
# (Re-)install systemd timers
sudo ./setup.sh systemd install
make install-systemd

# After pulling a repo update, re-install to sync /opt/ scripts
sudo ./setup.sh systemd install

# Check for split-brain (stale /opt/ scripts)
sudo ./setup.sh systemd validate
# Look for: ⚠️  SPLIT-BRAIN DETECTED warning

# Verify flock is installed
command -v flock || sudo apt install util-linux
```

> **Note**: Automation is managed via **systemd timers** (`setup.sh systemd`), not
> cron. There is no `cron-setup.sh` in the repository. Use `setup.sh systemd`
> for all scheduling operations. Timer logs are written to the systemd journal
> and are viewed with `journalctl`, not as flat log files.

## Getting Help

### Diagnostic Information to Collect

When reporting issues, include:

```bash
# Full diagnostic dump (versions, key status, disk, containers, last backup, recent logs)
make diagnose > diagnose-report.txt

# System information
./maintenance.sh health --comprehensive --json > health-report.json

# Service logs
docker compose logs > service-logs.txt

# Configuration (sanitized)
docker compose config > config.txt
cat .env | grep -v "PASSWORD\|TOKEN\|SECRET" > env-sanitized.txt

# Resource usage
docker stats --no-stream > resource-usage.txt

# Version information
make version > version-info.txt

# Systemd timer status
sudo ./setup.sh systemd status > timer-status.txt

# CrowdSec status
sudo cscli decisions list >> timer-status.txt
```

### Emergency Recovery

If all else fails:

```bash
# 1. Stop services
docker compose down

# 2. Create emergency backup (if possible)
./backup.sh run emergency

# 3. Restore from last known good backup
./restore.sh interactive

# 4. If complete failure, rebuild from emergency kit
# See BACKUP-RESTORE.md → Complete System Loss

# 5. Contact support with diagnostic information
```

---

This troubleshooting guide covers common issues and their solutions for VaultWarden-OCI. For issues not covered here, check the GitHub issues or create a new issue with the diagnostic information collected above.
