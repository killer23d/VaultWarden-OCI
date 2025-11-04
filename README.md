# VaultWarden-OCI

**Production-Ready VaultWarden for Small Teams**

A streamlined, secure, and operationally excellent VaultWarden deployment optimized for teams of 10 or fewer users. Designed for cloud platforms like Oracle Cloud Infrastructure (OCI) with dynamic IPs, this project focuses on essential functionality, ease of maintenance, and robust security for reliable password management.

## 🎯 What Makes This Different

This is a **template-based, hardened deployment** designed specifically for small teams who want:

- **Set-and-forget reliability** with template-based maintenance and automated operations
- **Template-first approach** - all configuration files maintained as `.example` templates
- **Enhanced fail2ban** with optimized Cloudflare API integration and advanced filtering
- **Robust security** with comprehensive Cloudflare integration and encrypted secrets
- **Simple operations** with comprehensive automation and health monitoring
- **Emergency recovery** with break-glass admin access for critical situations
- **Quality of life improvements** with Makefile shortcuts and interactive tools
- **Clear documentation** focused on practical deployment and maintenance

### Key Features

- **Template-Based Configuration**: All config files generated from maintainable `.example` templates
- **Enhanced Security**: Optimized fail2ban with dual CF+UFW blocking, comprehensive filtering
- **Resource Management**: Container limits optimized for 6GB systems with balanced allocation
- **Core Scripts**: 11 essential scripts for complete lifecycle management
- **Unified Libraries**: Shared libraries (common, Docker, crypto, security) for consistent functionality
- **Dynamic DNS**: Automatic Cloudflare DNS record updates
- **Edge Security**: Cloudflare proxy with enhanced fail2ban integration for global IP blocking
- **Firewall Hardening**: UFW configured with Cloudflare IP validation and safe fallback
- **Encrypted Secrets**: Age + SOPS for industry-standard secrets management
- **Automated Operations**: Comprehensive cron jobs for backups, updates, and maintenance
- **Emergency Access**: Break-glass admin for OCI serial console recovery
- **Interactive Tools**: Makefile shortcuts and interactive backup/restore functionality

## ⚡ Quick Start (15 Minutes)

Deploy a secure VaultWarden instance:

```bash
# 1. Clone and prepare
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh

# 2. Run automated setup (uses template-based approach)
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto

# 3. Configure secrets (CRITICAL - set admin_basic_auth_hash and API tokens)
./edit-secrets.sh

# 4. Configure environment (.env file - set CLOUDFLARE_ZONE_ID, etc.)
nano .env

# 5. Start services
./startup.sh

# 6. Setup automation (recommended for set-and-forget operation)
sudo ./cron-setup.sh --install

# 7. Create break-glass admin for emergency access (RECOMMENDED)
./create-breakglass-admin.sh

# 8. Verify deployment
./health.sh
```

**🎉 Your VaultWarden is now operational at https://vault.yourdomain.com**

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
│   │   ├── cloudflare-apiv4.conf      # Advanced CF+UFW dual action
│   │   └── sendmail-whois.conf        # Email notification action
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
    └── security.sh                    # Security validation functions
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
 Host Firewall (UFW - Cloudflare IPs + SSH only)
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
│  │11 Scripts│  │4 Libraries   │        │ ── Encrypted Secrets (Age + SOPS)
│  │(Ops)     │  │(Common+Sec)  │        │
│  └──────────┘  └──────────────┘        │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│        Docker Application Stack         │
│  ┌──────┐  ┌───────────┐                │
│  │Caddy │→ │VaultWarden│                │
│  │(SSL) │  │(App)      │ ← 2GB Memory   │
│  └──────┘  └───────────┘   Limit        │
│      ↑        1GB Limit                 │
│  ┌────────┐                             │
│  │fail2ban│─────────────────────────────┤ Dual CF+UFW Actions
│  │(Sec)   │     512MB Limit             │ (Advanced filtering)
│  └────────┘                             │
└─────────────────────────────────────────┘
      ↓
┌─────────────────────────────────────────┐
│         Emergency Recovery Layer        │
│  ┌──────────────┐                       │
│  │Break-Glass   │ ← OCI Serial Console   │ ── Emergency Access Path
│  │Admin Account │   Access               │
│  └──────────────┘                       │
└─────────────────────────────────────────┘
```

## 🛠️ Core Scripts

### Essential Operations

| Script | Purpose | Key Features | Frequency |
|--------|---------|-------------|----------|
| `./setup.sh` | One-time system setup | Template-based config generation, UFW validation | Once |
| `./startup.sh` | Start/stop/restart services | Enhanced secret handling, race condition fixes | As needed |
| `./health.sh` | System health monitoring | Comprehensive diagnostics, JSON output | Automated |
| `./backup.sh` | Create encrypted backups | Atomic operations, integrity verification | Daily (automated) |
| `./restore.sh` | Restore from encrypted backups | Interactive selection, validation | Emergency |

### Configuration & Maintenance

| Script | Purpose | Key Features | Frequency |  
|--------|---------|-------------|----------|
| `./edit-secrets.sh` | Secure secrets management | Enhanced privacy, secure environment handling | Initial + changes |
| `./update.sh` | Update containers/system packages | Automated backup before updates | Weekly (automated) |
| `./maintenance.sh` | System cleanup and optimization | Safe database operations, comprehensive cleanup | Monthly (automated) |
| `./cron-setup.sh` | Configure automation | Secure privilege management, validation | Once |

### Emergency & Recovery

| Script | Purpose | Key Features | Frequency |
|--------|---------|-------------|----------|
| `./create-breakglass-admin.sh` | Emergency admin for serial console | OCI console access, secure creation | Once + as needed |
| `./db-maint.sh` | Database maintenance | Safe offline SQLite optimization | Monthly (automated) |
| `./update-dns.sh` | Manual DNS updates | Cloudflare API integration | As needed |

## 🔧 Enhanced Security Features

### Current Security Improvements

- **Enhanced Fail2Ban**: 
  - Dual Cloudflare + UFW blocking with idempotent operations
  - Advanced retry logic with exponential backoff
  - Comprehensive regex-based filtering (no external dependencies)
  - Rate limiting detection and response

- **Resource Management**:
  - Container memory limits optimized for 6GB systems
  - Balanced CPU allocation preventing monopolization
  - Memory reservations ensuring stable operation

- **Template Security**:
  - No hardcoded credentials in generated files
  - Consistent security configurations across deployments
  - Version control safe templates with validation

### Multi-Layer Security

- **Encrypted Secrets**: All sensitive data encrypted with Age and managed via SOPS
- **Cloudflare Integration**:
  - Traffic proxied through Cloudflare's edge network
  - **Dual blocking**: CF API + local UFW for comprehensive protection
  - Automatic IP list updates with safe firewall integration
- **Host Firewall**: UFW configured with Cloudflare IP validation and safe fallback
- **HTTPS Enforcement**: Automatic HTTPS via Caddy with Let's Encrypt
- **Security Headers**: Comprehensive security headers (HSTS, CSP, etc.)
- **Rate Limiting**: API and admin endpoint protection with forensic logging
- **Admin Protection**: Basic authentication with bcrypt hashing
- **Container Security**: Non-root execution, capability restrictions, resource constraints
- **Emergency Recovery**: Secure break-glass admin access

## 📦 Backup & Recovery

### Enhanced Backup Strategy

- **Atomic Operations**: Prevents corrupt backups during creation
- **Safe Database Operations**: WAL checkpoints for live snapshots
- **Conservative Space Management**: Disk space validation before operations
- **Daily**: Encrypted database backups (retention: 14 days)
- **Weekly**: Encrypted full system backups (retention: 30 days)  
- **Manual**: Emergency recovery kits (retention: 90 days)
- **Offsite**: Automatic rclone sync to configured remote storage
- **Verification**: Pre-encryption integrity checks and backup testing

### Backup Operations

```bash
# Create different types of backups
./backup.sh --type db          # Quick database backup
./backup.sh --type full        # Complete system backup
./backup.sh --type emergency   # Disaster recovery kit

# With offsite sync
./backup.sh --type db --rclone  # Backup with remote sync

# List and manage backups
./backup.sh --list             # Show all available backups
```

### Recovery Process

```bash
# Interactive restore (recommended)
./restore.sh

# Or restore specific backup file
./restore.sh --file /path/to/backup-file.age
```

## 🔧 Configuration

### Template-Based Configuration

1. **Initial Setup** (uses templates):
   ```bash
   # Setup copies and populates templates
   sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com
   ```

2. **Cloudflare Setup**:
   ```bash
   # Create two API tokens at https://dash.cloudflare.com/profile/api-tokens
   # Token 1: DNS (Zone:DNS:Edit + Zone:Zone:Read for your domain)
   # Token 2: Firewall (Zone:Firewall Services:Edit for your domain)
   ```

3. **Environment Configuration** (.env):
   ```bash
   # Generated from .env.example, then customize:
   nano .env
   # Set: CLOUDFLARE_ZONE_ID, RCLONE_REMOTE_NAME, etc.
   ```

4. **Secrets Configuration**:
   ```bash
   ./edit-secrets.sh
   # Set: admin_basic_auth_hash, caddy_cloudflare_dns_token, fail2ban_cloudflare_firewall_token
   # Generate bcrypt hash: docker run --rm -it ghcr.io/caddybuilds/caddy-cloudflare:latest caddy hash-password
   ```

5. **Emergency Access Setup** (Recommended):
   ```bash
   ./create-breakglass-admin.sh
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
./startup.sh --force-restart    # Apply changes
```

## 🆘 Troubleshooting

### Common Issues

**Service Won't Start**:
```bash
# Check service status
./health.sh

# View container logs  
docker compose logs vaultwarden

# Validate configuration
docker compose config

# Force restart with fresh configuration
./startup.sh --force-restart
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

## 🛡️ Security Best Practices

### During Initial Setup
- ✅ Use template-based setup: `./setup.sh` (not manual file editing)
- ✅ Configure break-glass admin: `./create-breakglass-admin.sh`
- ✅ Test OCI serial console access (verify it works)
- ✅ Create and test backup restoration: `./backup.sh --type emergency`
- ✅ Generate proper bcrypt hash for admin_basic_auth_hash
- ✅ Validate Cloudflare API tokens work correctly
- ✅ Run comprehensive health check: `./health.sh`

### Ongoing Operations  
- ✅ Monitor break-glass admin status regularly
- ✅ Keep template files updated and version controlled
- ✅ Test emergency procedures quarterly
- ✅ Monitor fail2ban effectiveness and API limits
- ✅ Verify UFW rules after any network changes
- ✅ Review container resource usage periodically

### Template Security
- 📝 Never commit actual .env or docker-compose.yml files
- 📝 Keep .example files as the authoritative source
- 📝 Use setup.sh for all configuration generation
- 📝 Validate templates before deployment: `docker compose config`
- 📝 Test template changes in non-production first

## 📄 License

MIT License - see LICENSE file for details.

---

**VaultWarden-OCI**: Template-based, secure, self-hosted password management made simple for small teams with enhanced fail2ban security, comprehensive resource management, and robust emergency recovery capabilities.
