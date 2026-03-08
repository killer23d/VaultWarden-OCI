# Migration Guide — VaultWarden-OCI

Guide for migrating to VaultWarden-OCI from other VaultWarden deployments or password managers.

---

## 📋 Migration Overview

VaultWarden-OCI uses a template-based, production-ready configuration optimised for small teams. This guide covers:

- Migrating from an existing VaultWarden deployment
- Migrating from Bitwarden cloud
- Migrating from other password managers
- Platform-specific considerations (OCI / generic cloud)

---

## ✅ Pre-Migration Checklist

Before starting:

- ✅ **Backup source system** — create a complete backup of the current deployment
- ✅ **Export data** — export all vaults, organisations, and attachments
- ✅ **Document configuration** — note custom settings and integrations
- ✅ **Prepare target** — set up VaultWarden-OCI on the new server
- ✅ **Test environment** — verify the target works before migrating
- ✅ **Plan downtime** — schedule a maintenance window
- ✅ **Notify users** — inform the team of the migration timeline

---

## 🔄 Migrating from an Existing VaultWarden

### Method 1: Database Migration (Recommended)

**Prerequisites**
- Access to the source VaultWarden SQLite database
- Both systems on the same VaultWarden version (or source is older)

**Steps**

**1. Prepare the target system:**
```bash
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh

sudo ./setup.sh --domain vault.example.com --email admin@example.com
./edit-secrets.sh
nano .env
```

**2. Export the source database:**
```bash
# On source system — stop VaultWarden first
docker stop vaultwarden

cp /path/to/vaultwarden/data/db.sqlite3 db.sqlite3.backup
scp db.sqlite3.backup user@new-server:/tmp/
```

**3. Import on the target system:**
```bash
# Stop VaultWarden-OCI services
./startup.sh --down

# Copy database to correct location
sudo cp /tmp/db.sqlite3.backup /var/lib/vaultwarden/data/bwdata/db.sqlite3

# Fix permissions
sudo chown 1000:1000 /var/lib/vaultwarden/data/bwdata/db.sqlite3
sudo chmod 600  /var/lib/vaultwarden/data/bwdata/db.sqlite3

# Verify database integrity (uses host sqlite3 directly - no Docker required)
sudo sqlite3 /var/lib/vaultwarden/data/bwdata/db.sqlite3 'PRAGMA integrity_check;'

# Start services
./startup.sh
```

**4. Migrate attachments (if applicable):**
```bash
scp -r user@old-server:/path/to/vaultwarden/data/attachments /tmp/

sudo cp -r /tmp/attachments /var/lib/vaultwarden/data/
sudo chown -R 1000:1000 /var/lib/vaultwarden/data/attachments
```

**5. Verify migration:**
```bash
# Check admin panel
# Navigate to https://vault.example.com/admin

# Run health checks
./health.sh

# Verify all vaults are accessible
# Log in with existing credentials and inspect data
```

---

### Method 2: Export / Import (Alternative)

**Use when:**
- Direct database migration is not possible
- Version compatibility issues exist
- A clean fresh database is preferred

**Steps**

**1. Export from source:**
```bash
# Web vault: Login → Settings → Export Vault → JSON format

# Or via Bitwarden CLI
bw export --output vault-export.json --format json
```

**2. Set up target:**
```bash
sudo ./setup.sh --domain vault.example.com --email admin@example.com
./edit-secrets.sh
nano .env
./startup.sh
```

**3. Import to target:**
```bash
# Web vault: Login → Settings → Import Data → Select JSON → Upload

# Or via CLI
bw import bitwardenjson vault-export.json
```

> **Note:** Export/import may not preserve item history, trash items, some organisational metadata, or attachment filenames (manual re-upload may be required).

---

## ☁️ Migrating from Bitwarden Cloud

**1. Export from Bitwarden:**
```bash
# Web vault: Login → Settings → Export Vault → JSON format

# Or via CLI
bw login
bw unlock
bw export --output bitwarden-export.json --format json
```

**2. Set up VaultWarden-OCI:**
```bash
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
sudo ./setup.sh --domain vault.example.com --email admin@example.com
./edit-secrets.sh
nano .env
./startup.sh
```

**3. Import to VaultWarden:**
```bash
# Web vault: Login → Settings → Import Data
# Select "Bitwarden (json)" and upload bitwarden-export.json
```

**4. Migrate organisations (if applicable):**
```
For each organisation:
  1. Export from Bitwarden cloud as organisation owner
  2. Create organisation in VaultWarden
  3. Import organisation data
  4. Invite members
```

**5. Update client applications:**
```
# Desktop app, browser extension, mobile app:
Settings → Server URL → https://vault.example.com
```

---

## 🔑 Migrating from Other Password Managers

### From LastPass

```bash
# 1. Export
# LastPass web vault → More Options → Advanced → Export → Save as CSV

# 2. Import via web vault
# Settings → Import Data → LastPass (csv)
```

### From 1Password

```bash
# 1. Export: 1Password app → File → Export → 1Password Interchange Format (1pif)

# 2. Import via web vault
# Settings → Import Data → 1Password (1pif)
```

### From KeePass

```bash
# 1. Export: KeePass → File → Export → KeePass XML (2.x)

# 2. Import via web vault
# Settings → Import Data → KeePass 2 (xml)
```

---

## 🏗️ Platform-Specific Migration

### Migrating to Oracle Cloud Infrastructure (OCI)

**OCI-specific considerations:**

| Detail | Notes |
|---|---|
| SSH log path | `/var/log/secure` (not `/var/log/auth.log`) — auto-detected by `setup.sh` |
| Dynamic IPs | Automated Cloudflare DNS updates via `maintenance.sh --update-dns` (runs hourly via cron) |
| Break-glass admin | Essential for OCI Serial Console emergency access |
| Firewall | Pre-configured for Cloudflare-only web traffic |

```bash
# Standard setup auto-detects OCI / Oracle Linux
sudo ./setup.sh --domain vault.example.com --email admin@example.com --auto

# Create break-glass admin for emergency console access
./create-breakglass-admin.sh --create
```

### Migrating from a Generic Docker Compose Deployment

**Key differences in VaultWarden-OCI:**

| Feature | Generic Docker Compose | VaultWarden-OCI |
|---|---|---|
| Configuration | Manual | Template-based (`setup.sh`) |
| Resource limits | Manual / none | Pre-configured limits for 6 GB systems |
| Security | DIY | Dual Fail2ban (Host-networking) + Cloudflare-only firewall |
| Email | Manual SMTP | Containerised Postfix relay |
| Backups | Manual | Automated cron (Mon-Sat DB, Sunday full) |
| Encryption | None | Age-encrypted backups and secrets (SOPS) |

**Migration steps:**

```bash
# 1. Backup existing deployment
docker compose down
tar -czf vaultwarden-backup.tar.gz /path/to/vaultwarden

# 2. Copy to new server
scp vaultwarden-backup.tar.gz user@new-server:/tmp/

# 3. Set up VaultWarden-OCI
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
sudo ./setup.sh --domain vault.example.com --email admin@example.com
./edit-secrets.sh
nano .env

# 4. Migrate data
./startup.sh --down

cd /tmp
tar -xzf vaultwarden-backup.tar.gz

sudo cp -r /tmp/vaultwarden/data/* /var/lib/vaultwarden/data/
sudo chown -R 1000:1000 /var/lib/vaultwarden/data

# 5. Start and verify
cd /path/to/VaultWarden-OCI
./startup.sh
./health.sh
```

---

## 🏁 Post-Migration Tasks

### Verification Checklist

- ✅ **Login test** — verify users can log in with existing credentials
- ✅ **Data integrity** — check all vaults, items, and attachments
- ✅ **Organisations** — verify organisation access and permissions
- ✅ **2FA** — test two-factor authentication
- ✅ **Attachments** — verify file downloads work
- ✅ **Sends** — test Send functionality
- ✅ **Email** — test email notifications (`./maintenance.sh --test-email`)
- ✅ **Admin panel** — verify admin access works

### Security Hardening After Migration

```bash
# Generate new bcrypt hash for admin basic auth
docker run --rm -it ghcr.io/caddybuilds/caddy-cloudflare:latest caddy hash-password

# Update secrets
./edit-secrets.sh
# Set: admin_basic_auth_hash (and admin_token if desired)

# Restart services to apply
./startup.sh --force

# Verify health
./health.sh
```

### Set Up Automation

```bash
# Install cron jobs (daily backups, health checks, maintenance)
sudo ./cron-setup.sh --install

# Verify backups work
./backup.sh --type db
./backup.sh --list

# Test email
./maintenance.sh --test-email --verbose
```

### Update Client Applications

For each user, set the **Server URL** to `https://vault.example.com` in:

- Desktop application: **Settings → Account → Server URL**
- Browser extension: **Settings → Server URL**
- Mobile app: **Settings → Server URL**

---

## 🔙 Rollback Plan

If migration fails:

1. **Keep the old system running** during migration until fully verified
2. **Test the new system thoroughly** before decommissioning the old one
3. **Retain old system backups** for 30+ days
4. **Documented rollback:**

```bash
# Point DNS back to old server IP (update Cloudflare manually)
# Or trigger an immediate DNS update if old IP still valid:
./maintenance.sh --update-dns

# Notify users to switch back
# Restore old system from backup if needed
```

---

## 🔧 Troubleshooting Migration

### Database import fails

```bash
# Check database integrity (uses host sqlite3)
sudo sqlite3 /var/lib/vaultwarden/data/bwdata/db.sqlite3 'PRAGMA integrity_check;'

# Run deep maintenance if WAL corruption is suspected
sudo ./maintenance.sh --db-maint
```

### Attachments not accessible

```bash
# Check permissions
ls -la /var/lib/vaultwarden/data/attachments

# Fix permissions
sudo chown -R 1000:1000 /var/lib/vaultwarden/data/attachments
sudo chmod -R 755      /var/lib/vaultwarden/data/attachments
```

### Users can't log in

```bash
# Check secrets are decryptable
./edit-secrets.sh --test

# Verify VaultWarden is running
docker compose ps vaultwarden

# Check logs
docker compose logs vaultwarden | grep -i auth

# Test admin panel
curl -I https://vault.example.com/admin
```

### Email not working after migration

```bash
# Full email diagnostics
./maintenance.sh --test-email --verbose

# Check Postfix logs
docker compose logs postfix

# Verify SMTP settings
grep SMTP .env
./edit-secrets.sh  # Check smtp_password
```

---

## 💡 Migration Best Practices

1. **Test in staging first** — never migrate production directly
2. **Backup everything** — multiple backups before starting
3. **Document changes** — keep detailed migration notes
4. **Plan rollback** — have a working rollback plan ready
5. **Verify thoroughly** — test all functionality before going live
6. **Communicate clearly** — keep users informed throughout
7. **Schedule wisely** — migrate during low-usage periods
8. **Monitor closely** — watch logs and metrics after cutover

---

## 🆘 Support

For migration assistance:

1. Review the `/docs` directory for related guides
2. Search GitHub Issues for similar migrations
3. Open a new issue with:
   - Source system details
   - Migration method used
   - Error messages and logs
   - Steps already attempted
