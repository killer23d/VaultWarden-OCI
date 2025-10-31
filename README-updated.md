# VaultWarden-OCI

**Production-Ready VaultWarden for Small Teams**

A streamlined, secure, and operationally excellent VaultWarden deployment optimized for teams of 10 or fewer users. Designed for cloud platforms like Oracle Cloud Infrastructure (OCI) with dynamic IPs, this project focuses on essential functionality, ease of maintenance, and robust security for reliable password management.

## 🎯 What Makes This Different

This is a **template-based, hardened deployment** designed specifically for small teams who want:

- **Set-and-forget reliability** with template-based maintenance and automated operations
- **Template-first approach** - all configuration files maintained as `.example` templates
- **Enhanced fail2ban** with rate limiting and Cloudflare API integration
- **Robust security** with optimized Cloudflare integration and encrypted secrets
- **Simple operations** with comprehensive automation and health monitoring
- **Emergency recovery** with break-glass admin access for critical situations
- **Quality of life improvements** with Makefile shortcuts and interactive tools
- **Clear documentation** focused on practical deployment and maintenance

### Key Features

- **Template-Based Configuration**: All config files generated from maintainable `.example` templates
- **Enhanced Security**: Optimized fail2ban with rate limiting, improved UFW setup
- **Minimalist Footprint**: ~20 files, modular design with shared libraries
- **Core Scripts**: 11 essential scripts for complete lifecycle management
- **Unified Libraries**: 3 focused libraries (common, Docker, crypto) for shared functionality
- **Dynamic DNS**: Automatic Cloudflare DNS record updates
- **Edge Security**: Cloudflare proxy with enhanced fail2ban integration for IP blocking
- **Firewall Hardening**: UFW configured with Cloudflare IP validation and fallback warnings
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

All configuration files are now managed through templates for easier maintenance:

```
📁 Project Structure
├── docker-compose.yml.example     # Template for Docker Compose
├── .env.example                   # Template for environment variables
├── docker-compose.yml             # Generated from template by setup.sh
├── .env                          # Generated from template by setup.sh
├── caddy/Caddyfile               # Static configuration file
└── fail2ban/
    ├── action.d/
    │   └── cloudflare-optimized.conf  # Enhanced action with rate limiting
    ├── filter.d/                 # Static filter configurations
    └── jail.d/                   # Static jail configurations
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
│  ┌──────────┐  ┌──────────┐             │
│  │11 Scripts│  │3 Libraries│             │ ── Encrypted Secrets (Age + SOPS)
│  │(Ops)     │  │(Common)   │             │
│  └──────────┘  └──────────┘             │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│        Docker Application Stack         │
│  ┌──────┐  ┌───────────┐                │
│  │Caddy │→ │VaultWarden│                │
│  │(SSL) │  │(App)      │                │
│  └──────┘  └───────────┘                │
│      ↑                                  │
│  ┌────────┐                             │
│  │fail2ban│─────────────────────────────┤ Enhanced Cloudflare API
│  │(Sec+)  │     (Rate Limited)          │ (Rate limiting, error handling)
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
| `./setup.sh` | One-time system setup | **NEW**: Template-based config generation, enhanced UFW warnings | Once |
| `./startup.sh` | Start/stop/restart services | **IMPROVED**: Race condition fixes, better health checks | As needed |
| `./health.sh` | System health monitoring | Auto-repair, comprehensive diagnostics | Automated |
| `./backup.sh` | Create encrypted backups | **ENHANCED**: Atomic operations, better error handling | Daily (automated) |
| `./restore.sh` | Restore from encrypted backups | Interactive selection, validation | Emergency |

### Configuration & Maintenance

| Script | Purpose | Key Features | Frequency |  
|--------|---------|-------------|----------|
| `./edit-secrets.sh` | Secure secrets management | Age + SOPS encryption | Initial + changes |
| `./update.sh` | Update containers/system packages | Automated backup before updates | Weekly (automated) |
| `./maintenance.sh` | System cleanup and optimization | Log rotation, cleanup | Monthly (automated) |
| `./cron-setup.sh` | Configure automation | Comprehensive scheduling | Once |

### Emergency & Recovery

| Script | Purpose | Key Features | Frequency |
|--------|---------|-------------|----------|
| `./create-breakglass-admin.sh` | Emergency admin for serial console | OCI console access | Once + as needed |
| `./db-maint.sh` | Database maintenance | SQLite optimization | Monthly (automated) |
| `./update-dns.sh` | Manual DNS updates | Cloudflare API integration | As needed |

## 🔧 Enhanced Security Features

### New Security Improvements

- **Enhanced fail2ban**: 
  - Rate limiting (max 30 API calls/minute)
  - Comprehensive error handling and logging
  - Graceful failure recovery
  - No more API abuse or hanging requests

- **Improved UFW Setup**:
  - Clear warnings when Cloudflare API fails
  - Fallback firewall configuration
  - Interactive prompts for failure scenarios

- **Template Security**:
  - No hardcoded credentials in generated files
  - Consistent security configurations
  - Version control safe templates

### Multi-Layer Security

- **Encrypted Secrets**: All sensitive data encrypted with Age and managed via SOPS
- **Cloudflare Integration**:
  - Traffic proxied through Cloudflare's edge network
  - **Enhanced fail2ban** blocks malicious IPs via Cloudflare API with rate limiting
  - Automatic IP list updates with firewall integration
- **Host Firewall**: UFW configured with proper Cloudflare IP validation
- **HTTPS Enforcement**: Automatic HTTPS via Caddy with Let's Encrypt
- **Security Headers**: Comprehensive security headers (HSTS, CSP, etc.)
- **Rate Limiting**: API and admin endpoint protection
- **Admin Protection**: Basic authentication with bcrypt hashing
- **Container Security**: Non-root execution and resource constraints
- **Emergency Recovery**: Secure break-glass admin access

## 📦 Backup & Recovery

### Enhanced Backup Strategy

- **Atomic Operations**: **NEW** - Prevents corrupt backups during creation
- **Better Disk Space Management**: **NEW** - More conservative space checks
- **Improved Database Consistency**: **NEW** - WAL checkpoints for live snapshots
- **Daily**: Encrypted database backups (retention: 14 days)
- **Weekly**: Encrypted full system backups (retention: 30 days)  
- **Manual**: Emergency recovery kits (retention: 90 days)
- **Offsite**: Automatic rclone sync to configured remote storage
- **Verification**: Pre-encryption integrity checks

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

**Fail2ban Issues**:
```bash
# Check fail2ban status
docker compose exec fail2ban fail2ban-client status

# Check Cloudflare API connectivity
docker compose logs fail2ban | grep -i cloudflare

# Test API token
curl -X GET "https://api.cloudflare.com/client/v4/zones" \
     -H "Authorization: Bearer YOUR_TOKEN" \
     -H "Content-Type: application/json"
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

### Ongoing Operations  
- ✅ Monitor break-glass admin status regularly
- ✅ Keep template files updated and version controlled
- ✅ Test emergency procedures quarterly
- ✅ Monitor fail2ban for API rate limiting issues
- ✅ Verify UFW rules after any network changes

### Template Security
- 📝 Never commit actual .env or docker-compose.yml files
- 📝 Keep .example files as the authoritative source
- 📝 Use setup.sh for all configuration generation
- 📝 Validate templates before deployment: `docker compose config`
- 📝 Test template changes in non-production first

## 📄 License

MIT License - see LICENSE file for details.

---

**VaultWarden-OCI**: Template-based, secure, self-hosted password management made simple for small teams with enhanced fail2ban security, improved error handling, and comprehensive emergency recovery capabilities.