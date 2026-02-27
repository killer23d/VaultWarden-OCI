# VaultWarden-OCI

**Production-Ready VaultWarden for Small Teams**

A streamlined, secure, and operationally excellent VaultWarden deployment optimized for teams of 10 or fewer users. Designed for cloud platforms like Oracle Cloud Infrastructure (OCI) with dynamic IPs, this project focuses on essential functionality, ease of maintenance, and robust security for reliable password management.

## 🎯 What Makes This Different

This is a **template-based, hardened deployment** designed specifically for small teams who want:

- **Set-and-forget reliability** with template-based maintenance and automated operations
- **Template-first approach** - all configuration files maintained as `.example` templates
- **Cloudflare-only blocking** for web traffic (iptables removed from proxied services)
- **Robust security** with comprehensive Cloudflare integration and encrypted secrets
- **Simple operations** with comprehensive automation and health monitoring
- **Emergency recovery** with break-glass admin access and automatic rollback
- **Quality of life improvements** with Makefile shortcuts and interactive tools
- **Clear documentation** focused on practical deployment and maintenance

### Key Features

- **Template-Based Configuration**: All config files generated from maintainable `.example` templates
- **Enhanced Security**: Cloudflare-only blocking for web traffic, local iptables only for SSH
- **Resource Management**: Container limits optimized for 6GB systems with balanced allocation
- **Core Scripts**: 14 essential scripts for complete lifecycle management
- **Unified Libraries**: 5 shared libraries (common, Docker, crypto, security, backup_utils) for consistent functionality
- **Dynamic DNS**: Automatic Cloudflare DNS record updates
- **Edge Security**: Cloudflare proxy with Fail2ban integration for global IP blocking
- **Firewall Hardening**: UFW configured with Cloudflare IP restriction and safe fallback
- **Encrypted Secrets**: Age + SOPS for industry-standard secrets management
- **Automated Operations**: Comprehensive cron jobs for backups, updates, and maintenance
- **Emergency Access**: Break-glass admin for OCI serial console recovery
- **Interactive Tools**: Makefile shortcuts and interactive backup/restore functionality
- **Containerized Email**: Postfix sidecar for reliable email delivery without host dependencies
- **Self-Healing**: Health checks with auto-recovery for unhealthy containers
- **Dependency Version Pinning**: Optional version pins for SOPS and age at the top of `setup.sh`
- **Automatic Rollback**: `update.sh` automatically attempts rollback via `restore.sh` if a post-update health check fails

## ⚡ Quick Start (15 Minutes)

Deploy a secure VaultWarden instance:

```bash
# 1. Clone and prepare
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh

# 2. IMPORTANT: Cloudflare DNS staging (do this BEFORE running setup)
#    In your Cloudflare dashboard, ensure your DNS record is set to
#    DNS Only (Grey Cloud — NOT orange/proxied). Caddy must be able to
#    reach Let's Encrypt directly to provision its TLS certificate on
#    first boot. You can enable the proxy (orange cloud) after step 6.

# 3. Run automated setup (uses template-based approach)
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto

# 4. Log out and log back in
#    setup.sh adds your user to the docker group. You must start a fresh
#    session for that group membership to take effect before running any
#    docker or make commands.
exit
# Re-SSH into your instance, then cd back into the project directory:
cd VaultWarden-OCI

# 5. Configure secrets (CRITICAL - set admin_basic_auth_hash and API tokens)
./edit-secrets.sh

# 6. Configure environment (.env file - set CLOUDFLARE_ZONE_ID, etc.)
nano .env

# 7. Start services
./startup.sh
# Or use Makefile: make start

# 8. Switch Cloudflare record to Proxied (Orange Cloud) and set
#    SSL/TLS encryption mode to Full (Strict) in the Cloudflare dashboard.

# 9. Setup automation (recommended for set-and-forget operation)
sudo ./cron-setup.sh --install

# 10. Create break-glass admin for emergency access (RECOMMENDED)
./create-breakglass-admin.sh
# Or use Makefile: make breakglass-create

# 11. Verify deployment
./health.sh
# Or use Makefile: make health
```

**🎉 Your VaultWarden is now operational at https://vault.yourdomain.com**

## 📌 Dependency Version Pinning

By default `setup.sh` auto-resolves the latest release of each external tool (SOPS, age) from the GitHub API at install time. If you need reproducible, auditable deployments you can **pin specific versions** at the top of `setup.sh`:

```bash
# At the top of setup.sh — edit before running setup:
SOPS_VERSION="v3.9.4"   # pinned — always installs this exact version
AGE_VERSION=""           # blank  — auto-resolves latest at runtime
```

You can also override pins at runtime without editing the file:

```bash
SOPS_VERSION=v3.9.4 sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com
```

| Variable | Default | Example pin |
| :-- | :-- | :-- |
| `SOPS_VERSION` | `""` (latest) | `"v3.9.4"` |
| `AGE_VERSION` | `""` (latest) | `"v1.2.0"` |

> **Note:** `age` is installed via `apt` by default. `AGE_VERSION` only applies if installing age as a standalone binary instead.

## 🛠️ Template-Based Architecture

### Configuration Management

All configuration files are managed through templates for easier maintenance:

```
📁 Project Structure
├── docker-compose.yml.example          # Template for Docker Compose
├── docker-compose.override.yml.example # Template for email decoupling
├── .env.example                        # Template for environment variables
├── docker-compose.yml                  # Generated from template by setup.sh
├── .env                               # Generated from template by setup.sh
├── caddy/Caddyfile                    # Enhanced reverse proxy configuration
├── fail2ban/
│   ├── action.d/
│   │   ├── cloudflare-apiv4.conf      # Cloudflare API blocking action
│   │   └── smtp.conf                  # Email notification action
│   ├── filter.d/                      # Comprehensive filter configurations
│   │   ├── vaultwarden-auth.conf      # Authentication failure detection
│   │   ├── vaultwarden-admin.conf     # Admin panel protection
│   │   └── vaultwarden-web-caddy.conf # Web interface protection
│   └── jail.d/
│       └── vaultwarden-oci.conf       # Complete jail configuration
└── lib/
    ├── common.sh                      # Shared utility functions
    ├── crypto.sh                      # Encryption/decryption utilities
    ├── docker.sh                      # Docker management functions
    ├── security.sh                    # Security validation functions
    └── backup_utils.sh                # Backup-specific utilities
```

### Benefits of Template Approach

✅ **Single source of truth** - Edit templates, not generated files
✅ **No more hardcoded values** - Platform architecture issues eliminated
✅ **Easy maintenance** - Direct file editing with syntax highlighting
✅ **Testable configuration** - `docker compose config` works immediately
✅ **Version control friendly** - Clean diffs and proper file history
✅ **Consistent deployments** - Same templates produce identical configurations

## 🏗️ Architecture

### Simple, Secure Stack

```
 Cloudflare Edge (Proxy, WAF, DNS)
       ↑ ↓
 Host Firewall (UFW - Cloudflare IPs only for 80/443 + SSH only)
       ↑ ↓
┌─────────────────────────────────────────┐
│      Template Management Layer          │
│  ┌──────────────┐  ┌──────────────┐    │
│  │.example files│→ │Generated files│    │ ── Enhanced Setup Process
│  │(Templates)   │  │(.env, compose)│    │
│  └──────────────┘  └──────────────┘    │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│           Management Layer              │
│  ┌──────────┐  ┌──────────────┐        │
│  │14 Scripts│  │5 Libraries   │        │ ── Encrypted Secrets (Age + SOPS)
│  │(Ops)     │  │(Common+Utils)│        │
│  └──────────┘  └──────────────┘        │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│        Docker Application Stack         │
│  ┌──────┐  ┌───────────┐  ┌──────────┐ │
│  │Caddy │→ │VaultWarden│  │ Postfix  │ │
│  │(SSL) │  │(App)      │  │ (Email)  │ │
│  └──────┘  └───────────┘  └──────────┘ │
│   1GB Limit   2GB Limit                │
│  ┌────────┐                             │
│  │fail2ban│─────────────────────────────┤ Cloudflare-only for web
│  │(Sec)   │     1GB Limit               │ Local iptables only for SSH
│  └────────┘                             │
└─────────────────────────────────────────┘
      ↓
┌─────────────────────────────────────────┐
│         Emergency Recovery Layer        │
│  ┌──────────────┐  ┌─────────────────┐  │
│  │Break-Glass   │  │Auto-Rollback    │  │
│  │Admin Account │  │(update → restore│  │ ── Emergency Access & Recovery
│  │(OCI Console) │  │ on health fail) │  │
│  └──────────────┘  └─────────────────┘  │
└─────────────────────────────────────────┘
```

## 🛠️ Core Scripts

### Essential Operations

| Script | Purpose | Key Features | Frequency |
| :-- | :-- | :-- | :-- |
| `./setup.sh` | One-time system setup | Template-based config generation, UFW validation, **optional dependency version pinning** | Once |
| `./startup.sh` | Start/stop/restart services | **Secure secrets (umask 077)**, log perm fixes, sudo-aware health check | As needed |
| `./health.sh` | System health monitoring | **Auto-recovery (`--auto-recover`)**, sudo-aware backup verification | Automated |
| `./backup.sh` | Create encrypted backups | Atomic operations, integrity verification, full verification mode | Daily (automated) |
| `./restore.sh` | Restore from encrypted backups | Interactive selection, validation, **`--latest` flag for automated rollback** | Emergency |

### Configuration & Maintenance

| Script | Purpose | Key Features | Frequency |
| :-- | :-- | :-- | :-- |
| `./edit-secrets.sh` | Secure secrets management | Enhanced privacy, secure environment handling | Initial + changes |
| `./update.sh` | Update containers/system packages | Automated backup before updates, **configurable stabilization wait (`POST_UPDATE_WAIT_SECONDS`)**, **automatic rollback on health failure** | Weekly (automated) |
| `./maintenance.sh` | System cleanup, optimization, DNS update, and on-demand DB/email maintenance | Safe database operations, comprehensive cleanup, unified sub-commands | Monthly (automated) |
| `./cron-setup.sh` | Configure automation | Secure privilege management, validation | Once |

### Emergency & Recovery

| Script | Purpose | Key Features | Frequency |
| :-- | :-- | :-- | :-- |
| `./create-breakglass-admin.sh` | Emergency admin for serial console | OCI console access, secure creation | Once + as needed |
| `./maintenance.sh --db-maint` | Deep database maintenance | Safe offline SQLite VACUUM + WAL checkpoint | Monthly (automated) |
| `./maintenance.sh --update-dns` | Manual DNS updates | Cloudflare API integration | As needed |

### Email Testing

| Script | Purpose | Key Features | Frequency |
| :-- | :-- | :-- | :-- |
| `./maintenance.sh --test-email` | Test email configuration | Tests Postfix container, validates SMTP relay, end-to-end delivery check | Setup + troubleshooting |

## 🔄 Update & Rollback Behaviour

`update.sh` runs a fully phased, safe update cycle:

```
Phase 1: Pre-Update Preparation
  ├── Pre-update health check (non-fatal — fresh systems always show warnings)
  └── Create full backup  ← FATAL if this fails; update is aborted

Phase 2: Perform Updates
  ├── System packages (--system flag required)
  └── Container image pull

Phase 3: Post-Update Restart and Verification
  ├── Restart services (./startup.sh --force)
  ├── Wait POST_UPDATE_WAIT_SECONDS (default: 30, configurable)
  ├── Post-update health check
  └── On health failure → automatic rollback via ./restore.sh --latest --type full --force --no-backup

Phase 4: Summary
  └── Exit 0 (success) | 1 (critical failure) | 2 (health issues)
```

**Key behaviours:**
- If the container **pull fails**, services are left running on their old images and no restart is attempted — this is reported as "update unavailable", not "critical failure"
- If the post-update **health check fails**, rollback is attempted automatically before exiting
- `POST_UPDATE_WAIT_SECONDS` can be increased for slower OCI ARM instances: `POST_UPDATE_WAIT_SECONDS=60 ./update.sh`

## 🚀 Makefile Quick Reference

The Makefile provides convenient shortcuts for common operations:

### Service Management

```bash
make up              # Start all services
make down            # Stop all services
make restart         # Restart with enhanced startup script
make start           # Alias for up
make stop            # Alias for down
make status          # Show service status
```

### Monitoring & Health

```bash
make health          # Run health checks
make health-email    # Health check with email notification
make logs            # Show all service logs
make logs SERVICE=vaultwarden  # Show specific service logs
make logs-postfix    # Shortcut to view Postfix email logs
```

### Backup & Restore

```bash
make backup          # Create database backup (silent — no email)
make backup-full     # Create full system backup (emails on completion)
make backup-emergency # Create emergency recovery kit (emails on completion)
make list-backups    # List available backups
make restore         # Interactive restore
```

### Maintenance

```bash
make update          # Update container images
make update-system   # Update system and containers
make maintenance     # Run full maintenance (cleanup, Docker, DB, DNS, firewall)
make maintenance-full # Full maintenance with email notification
make update-dns      # Update Cloudflare DNS record to current IP
make db-maint        # Deep database maintenance (requires sudo)
```

### Security

```bash
make breakglass-create  # Create emergency admin
make breakglass-status  # Check emergency admin status
make breakglass-remove  # Remove emergency admin
```

### Development & Testing

```bash
make dev-setup       # Setup development environment
make test            # Run all tests (secrets + email + config)
make test-secrets    # Test secrets decryption
make test-email      # Test Postfix email configuration (verbose)
make test-config     # Validate Docker Compose configuration
make dry-run         # Preview all operations without executing
make fmt             # Validate all configuration files
make shell           # Open shell in container (default: vaultwarden)
make shell SERVICE=caddy # Open shell in specific container
```

## 🔧 Enhanced Security Features

### Script Hardening (Latest Revision)

All scripts in this project have been hardened with the following guarantees:

- **`set -euo pipefail`** throughout — unset variables and failing pipelines are fatal
- **`if`-guarded function calls** — functions return exit codes; `main()` decides the exit strategy; `set -e` never fires unexpectedly
- **`printf` for all summary output** — `echo -e` with `\n` sequences replaced everywhere to prevent backslash misinterpretation
- **`read -r`** on all interactive prompts — backslash sequences in user input are never silently consumed
- **`--force` flag contract** — all scripts call `./startup.sh --force` (the confirmed supported flag); the invalid `--force-restart` flag has been removed everywhere
- **Verified backup file resolution** — `restore.sh` sorts by modification time (`find -printf '%T@'`), not lexicographic filename order, to reliably find the newest backup regardless of filename format
- **Registered cleanup registry** — temp files and directories are tracked in a `CLEANUP_DIRS`/`CLEANUP_FILES` array and cleaned up via a single `trap … EXIT` handler, preventing silent trap overwrites
- **SIGKILL-safe backup lock** — `backup.sh` uses `flock` on a file descriptor instead of a `mkdir`-based lock; the kernel releases the lock automatically on any process exit, including SIGKILL and OOM kill

### Current Security Improvements

- **Cloudflare-Only Web Blocking**:
    - **CRITICAL**: All web-facing jails use Cloudflare API exclusively
    - iptables removed from proxied services (traffic comes from Cloudflare IPs, not attacker IPs)
    - Local iptables ONLY used for SSH (direct connection, not proxied)
    - Advanced retry logic with exponential backoff
    - Comprehensive regex-based filtering (no external dependencies)
    - Rate limiting detection and response
- **Cloudflare-Restricted UFW Rules**:
    - Ports 80 and 443 are restricted to Cloudflare's published IPv4 ranges at the UFW layer
    - SSH remains unrestricted (direct connection)
    - A hardcoded fallback IP list is used if the live Cloudflare fetch fails, so setup never requires network access to Cloudflare
- **Secure Startup & Secrets**:
    - `startup.sh` enforces `umask 077` during secrets generation (files created with 600 permissions)
    - Atomic file creation avoids race conditions
    - Log directories automatically created with correct PUID:PGID ownership
    - Health checks automatically escalate privileges (sudo) only when needed for backup verification
- **Resilient Health Monitoring**:
    - `health.sh` includes `--auto-recover` to restart unhealthy containers automatically
    - Robust backup verification uses `sudo` safely (interactive vs non-interactive detection)
    - Proper error handling for domain connectivity checks
- **Resource Management**:
    - Container memory limits optimized for 6GB systems
    - Balanced CPU allocation preventing monopolization
    - Memory reservations ensuring stable operation
- **Template Security**:
    - No hardcoded credentials in generated files
    - Consistent security configurations across deployments
    - Version control safe templates with validation
- **Containerized Email**:
    - Postfix sidecar eliminates host mail utility dependencies
    - Dedicated container for SMTP relay (port 587)
    - Consistent SMTP configuration across all services (scripts and fail2ban)
    - Enhanced reliability and troubleshooting via unified `--test-email` diagnostic

### Multi-Layer Security

- **Encrypted Secrets**: All sensitive data encrypted with Age and managed via SOPS
- **Cloudflare Integration**:
    - Traffic proxied through Cloudflare's edge network
    - **Cloudflare-only blocking for web**: All web-facing jails use CF API only (iptables ineffective due to proxy)
    - **Local iptables for SSH**: SSH jail uses iptables since it's direct connection
    - Automatic IP list updates with safe firewall integration
- **Host Firewall**: UFW configured with Cloudflare IP restriction — ports 80/443 accept traffic from Cloudflare ranges only
- **HTTPS Enforcement**: Automatic HTTPS via Caddy with Let's Encrypt
- **Security Headers**: Comprehensive security headers (HSTS, CSP, etc.)
- **Rate Limiting**: API and admin endpoint protection with forensic logging
- **Admin Protection**: Basic authentication with bcrypt hashing
- **Container Security**: Non-root execution, capability restrictions, resource constraints
- **Emergency Recovery**: Secure break-glass admin access + automatic rollback on failed updates

## 📦 Backup & Recovery

### Enhanced Backup Strategy

- **Atomic Operations**: Prevents corrupt backups during creation
- **Safe Database Operations**: WAL checkpoints for live snapshots
- **Full Verification Mode**: Optional end-to-end recoverability testing
- **Conservative Space Management**: Disk space validation before operations
- **SIGKILL-Safe Locking**: `flock`-based backup lock releases automatically on any process exit
- **Daily**: Encrypted database backups (retention: 14 days)
- **Weekly**: Encrypted full system backups (retention: 30 days)
- **Manual**: Emergency recovery kits (retention: 90 days)
- **Offsite**: Automatic rclone sync to configured remote storage
- **Verification**: Pre-encryption integrity checks and optional full verification

> **Restore requires your Age private key.** Full and database backups are
> encrypted with your Age key (`secrets/keys/age-key.txt`). Emergency backups
> include the key inside the archive. For full and db backup types, ensure
> you have a separate copy of `secrets/keys/age-key.txt` before restoring to
> a new server. See [BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md) for details.

### Backup Operations

```bash
# Create different types of backups
./backup.sh --type db          # Quick database backup
./backup.sh --type full        # Complete system backup
./backup.sh --type emergency   # Disaster recovery kit

# With full verification (recommended weekly)
./backup.sh --type full --full-verification

# With offsite sync
./backup.sh --type db --rclone  # Backup with remote sync

# List and manage backups
./backup.sh --list             # Show all available backups

# Using Makefile
make backup                    # Database backup (silent)
make backup-full              # Full system backup (emails on completion)
make backup-emergency         # Emergency kit (emails on completion)
make list-backups             # List backups
```

### Recovery Process

```bash
# Interactive restore (recommended)
./restore.sh

# Restore latest backup automatically (used by update.sh rollback)
./restore.sh --latest --force --no-backup

# Restore latest backup of a specific type
./restore.sh --latest --type full --force

# Restore a specific backup file
./restore.sh --file /path/to/backup-file.age

# Using Makefile
make restore                   # Interactive restore
```

#### restore.sh Exit Codes

| Code | Meaning |
| :-- | :-- |
| `0` | Restore completed successfully, all health checks passed |
| `1` | Restore failed or critical phase error |
| `2` | Restore completed but post-restore health check reported issues |

## 🔧 Configuration

### 1. Mandatory Pre-Flight Configuration

#### OCI VCN Security Lists (Restrict to Cloudflare IPs Only)

Oracle Cloud blocks all incoming traffic by default at the virtual network level.
Do **NOT** open ports 80/443 to `0.0.0.0/0`. Instead, restrict ingress to
Cloudflare's published IP ranges. This enforces the Cloudflare-only web
posture at the network layer — packets from non-Cloudflare sources are
dropped before they reach the VM.

1. Go to **Compute** → **Instances** → Click your instance.
2. Click the **Subnet** under "Primary VNIC" → **Default Security List**.
3. Add **Ingress Rules** for each Cloudflare IPv4 range below.
   - Protocol: `TCP`, Destination Ports: `80,443`
   - Source: one CIDR per rule (OCI does not support comma-separated CIDRs)

**Cloudflare IPv4 ranges** (verify current list at https://www.cloudflare.com/ips-v4):

```
173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22
```

4. Add one rule for **SSH**:
   - Source: your management IP (or `0.0.0.0/0` if dynamic), Protocol: `TCP`, Port: `22`

> **Why not UFW for this?** OCI VCN Security Lists drop packets at the hypervisor
> level before they reach the VM's network stack — this is a harder control than
> host-level UFW. UFW also restricts ports 80/443 to Cloudflare IPs (enforced by
> `setup.sh`), giving defence-in-depth, but the VCN layer is the primary barrier.

> **Keeping the list current:** Cloudflare rarely changes its IP ranges. Subscribe
> to https://www.cloudflare.com/ips/ for update notifications.

#### Cloudflare Staging (Grey Cloud First)
Because Caddy needs to provision a Let's Encrypt certificate during its very first boot, it must be able to solve the HTTP challenge.
- During initial setup, ensure your DNS record in Cloudflare is set to **DNS Only (Grey Cloud)**.
- *After* `make start` runs successfully and you can access your vault, you can switch the record to **Proxied (Orange Cloud)** and change your SSL/TLS encryption mode to **Full (Strict)**.

### 2. Template-Based Configuration

**Initial Setup** (uses templates):

```bash
# Setup copies and populates templates
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com
```

**Environment Configuration** (.env):

```bash
# Generated from .env.example, then customize:
nano .env
# Set: CLOUDFLARE_ZONE_ID, RCLONE_REMOTE_NAME, etc.
```

### 3. Secrets & API Tokens

**Cloudflare Setup**:
Create two API tokens at https://dash.cloudflare.com/profile/api-tokens
- **Token 1: DNS** (Zone:DNS:Edit + Zone:Zone:Read for your domain)
- **Token 2: Firewall** (Zone:Firewall Services:Edit for your domain)

**Secrets Configuration**:
```bash
# Securely edit secrets
./edit-secrets.sh
```
You must configure:
- `admin_basic_auth_hash` (Generate via: `docker run --rm -it ghcr.io/caddybuilds/caddy-cloudflare:latest caddy hash-password`)
- `caddy_cloudflare_dns_token` (Token 1 from above)
- `fail2ban_cloudflare_firewall_token` (Token 2 from above. **Mandatory** for edge blocking)

> **Fail2Ban Edge Token Wiring:** Because all web traffic arrives via the Cloudflare proxy, Fail2Ban cannot use local `iptables` to block attackers. It must push blocks directly to the Cloudflare Edge WAF. Supplying your `fail2ban_cloudflare_firewall_token` and `CLOUDFLARE_ZONE_ID` (in `.env`) automatically wires the `action.d/cloudflare-apiv4.conf` jail to drop malicious IPs globally.

### 4. Email Configuration

Email uses a containerized Postfix relay (no host mail dependencies).
Configure SMTP relay settings in `.env`:
```bash
nano .env
# Set: SMTP_HOST, SMTP_PORT, SMTP_USERNAME, ALLOWED_SENDER_DOMAINS, etc.
```

Set SMTP password in secrets:
```bash
./edit-secrets.sh
# Set: smtp_password
```

Test email functionality:
```bash
./maintenance.sh --test-email --verbose
# Or use Makefile: make test-email
```

### 5. Emergency Access Setup (Recommended)

```bash
./create-breakglass-admin.sh
# Or use: make breakglass-create
# Creates emergency admin account for OCI serial console access
```

### Template Maintenance

For ongoing maintenance, edit the template files:

```bash
# Edit templates (source of truth)
nano docker-compose.yml.example  # For Docker Compose changes
nano .env.example               # For new environment variables

# Apply template changes
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com

# Restart to apply changes
./startup.sh --force    # Apply changes
# Or use: make restart
```

## 🆘 Troubleshooting

### Common Issues

**Service Won't Start**:

```bash
# Check service status (uses enhanced health check)
./health.sh
# Or: make health

# View container logs
docker compose logs vaultwarden
# Or: make logs SERVICE=vaultwarden

# Validate configuration
docker compose config
# Or: make test-config

# Force restart with fresh configuration
./startup.sh --force
# Or: make restart
```

**Template Issues**:

```bash
# Validate templates
docker compose config

# Re-generate from templates
sudo ./setup.sh --force --domain your-domain.com --email your-email@domain.com

# Check for template syntax issues
cat docker-compose.yml.example | grep -n "platform:\|linux/arm64"
```

**Update Fails or Service Unhealthy After Update**:

```bash
# update.sh will attempt automatic rollback if post-update health fails.
# If manual rollback is needed:
./restore.sh --latest --type full --force --no-backup

# To increase stabilization wait time on slow instances:
POST_UPDATE_WAIT_SECONDS=60 ./update.sh

# Preview what would be updated without making changes:
./update.sh --dry-run --system
```

**Email Issues**:

```bash
# Run the built-in email diagnostic (tests Postfix container,
# fail2ban integration, host script config, and end-to-end delivery)
./maintenance.sh --test-email --verbose
# Or: make test-email

# Check Postfix container status and logs
docker compose ps postfix
docker compose logs postfix
# Or: make logs-postfix

# Verify Postfix SMTP port is responding
docker compose exec postfix nc -z localhost 587

# Check fail2ban can reach Postfix
docker compose exec fail2ban nc -zv postfix 587

# Send a test email to a specific recipient
./maintenance.sh --test-email --recipient you@example.com

# Debug steps if delivery fails:
#   1. Verify SMTP relay credentials in secrets (./edit-secrets.sh)
#   2. Verify ALLOWED_SENDER_DOMAINS in .env
#   3. Check Postfix relay configuration
#   4. Review Postfix logs: docker compose logs postfix | grep -i error

# Send test email from VaultWarden admin panel
# Navigate to: https://vault.yourdomain.com/admin → SMTP Settings → Send Test Email
```

**Fail2Ban Issues**:

```bash
# Check fail2ban status
docker compose exec fail2ban fail2ban-client status

# Check Cloudflare API connectivity
docker compose logs fail2ban | grep -i cloudflare

# Test API token
curl -X GET "https://api.cloudflare.com/client/v4/zones" \
     -H "Authorization: Bearer YOUR_TOKEN" \
     -H "Content-Type: application/json"

# Validate filter syntax
docker compose exec fail2ban fail2ban-regex /var/log/vaultwarden/vaultwarden.log /data/fail2ban/filter.d/vaultwarden-auth.conf

# NOTE: Web-facing jails (vaultwarden-auth, vaultwarden-admin, vaultwarden-web-*)
# use Cloudflare API ONLY - local iptables removed as traffic is proxied
```

### Emergency Recovery

#### SSH Access Lost (Most Common Emergency)

1. **Use break-glass admin via OCI Console**:
    - Access OCI Console → Compute → Instance → Console Connection
    - Login with break-glass admin credentials
    - Fix firewall: `sudo ufw allow 22/tcp`
    - Fix SSH: `sudo systemctl restart sshd`
    - **Security cleanup**: Delete Console Connection, rotate password
2. **If no break-glass admin configured**:
    - Use OCI boot volume attachment method
    - Create break-glass admin for future: `./create-breakglass-admin.sh`
    - Or use: `make breakglass-create`

## 🛡️ Security Best Practices

### During Initial Setup

- ✅ Use template-based setup: `./setup.sh` (not manual file editing)
- ✅ Pin dependency versions in `setup.sh` if you need reproducible deployments
- ✅ Log out and log back in after `setup.sh` to apply docker group membership
- ✅ Configure break-glass admin: `./create-breakglass-admin.sh` or `make breakglass-create`
- ✅ Test OCI serial console access (verify it works)
- ✅ Create and test backup restoration: `./backup.sh --type emergency`
- ✅ Generate proper bcrypt hash for admin_basic_auth_hash
- ✅ Validate Cloudflare API tokens work correctly
- ✅ Test email functionality: `make test-email`
- ✅ Run comprehensive health check: `./health.sh` or `make health`
- ✅ Verify OCI VCN Security Lists restrict ports 80/443 to Cloudflare IPs only

### Ongoing Operations

- ✅ Monitor break-glass admin status regularly
- ✅ Keep template files updated and version controlled
- ✅ Test emergency procedures quarterly
- ✅ Monitor fail2ban effectiveness and API limits
- ✅ Verify UFW rules after any network changes
- ✅ Review container resource usage periodically
- ✅ Test email notifications regularly: `make test-email`
- ✅ Understand Cloudflare-only blocking for web traffic (iptables removed)
- ✅ Review update.sh exit codes in cron output (0=success, 1=failure, 2=health issues)
- ✅ Periodically verify Cloudflare IP ranges: https://www.cloudflare.com/ips-v4

### Template Security

- 📝 Never commit actual .env or docker-compose.yml files
- 📝 Keep .example files as the authoritative source
- 📝 Use setup.sh for all configuration generation
- 📝 Validate templates before deployment: `docker compose config`
- 📝 Test template changes in non-production first

## 📚 Documentation

Comprehensive documentation is available in the `docs/` directory:

- **[DEPLOYMENT.md](docs/DEPLOYMENT.md)** - Detailed deployment guide
- **[CONFIGURATION.md](docs/CONFIGURATION.md)** - Complete configuration reference
- **[SECURITY.md](docs/SECURITY.md)** - Security hardening and best practices
- **[OPERATIONS.md](docs/OPERATIONS.md)** - Day-to-day operations guide
- **[BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md)** - Backup and recovery procedures
- **[SCRIPTS.md](docs/SCRIPTS.md)** - Script reference guide
- **[TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** - Common issues and solutions
- **[MIGRATION.md](docs/MIGRATION.md)** - Migration from other setups
- **[API.md](docs/API.md)** - API usage and integration
- **[ADVANCED-CUSTOMIZATION.md](docs/ADVANCED-CUSTOMIZATION.md)** - Advanced customization options

## 📄 License

MIT License - see LICENSE file for details.
