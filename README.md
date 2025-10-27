# VaultWarden-OCI-Simplified

**Production-Ready VaultWarden for Small Teams**

A streamlined, secure, and operationally excellent VaultWarden deployment optimized for teams of 10 or fewer users. Designed for cloud platforms like Oracle Cloud Infrastructure (OCI) with dynamic IPs, this project focuses on essential functionality, ease of maintenance, and robust security for reliable password management.

## 🎯 What Makes This Different

This is a **significantly simplified and hardened version** designed specifically for small teams who want:

- **Set-and-forget reliability** without enterprise complexity
- **Essential functionality** with dynamic DNS updates and automated maintenance  
- **Robust security** with Cloudflare integration, encrypted secrets, and firewall hardening
- **Simple operations** with comprehensive automation and health monitoring
- **Emergency recovery** with break-glass admin access for critical situations
- **Flexible version management** for stability or latest features as needed
- **Quality of life improvements** with Makefile shortcuts and interactive tools
- **Clear documentation** focused on practical deployment and maintenance

### Key Features

- **Minimalist Footprint**: ~20 files, modular design with shared libraries
- **Core Scripts**: 11 essential scripts for complete lifecycle management
- **Unified Libraries**: 3 focused libraries (common, Docker, crypto) for shared functionality
- **Dynamic DNS**: Automatic Cloudflare DNS record updates via ddclient
- **Edge Security**: Cloudflare proxy with fail2ban integration for IP blocking at the edge
- **Firewall Hardening**: UFW configured to allow web traffic only from Cloudflare IPs
- **Encrypted Secrets**: Age + SOPS for industry-standard secrets management
- **Automated Operations**: Comprehensive cron jobs for backups, updates, and maintenance
- **Emergency Access**: Break-glass admin for OCI serial console recovery
- **Version Management**: Flexible container version pinning with easy latest/pinned switching
- **Interactive Tools**: Makefile shortcuts and interactive backup/restore functionality

## ⚡ Quick Start (15 Minutes)

Deploy a secure VaultWarden instance:

```bash
# 1. Clone and prepare
git clone https://github.com/killer23d/VaultWarden-OCI-Simplified.git
cd VaultWarden-OCI-Simplified
chmod +x *.sh

# 2. Run automated setup (installs dependencies, configures firewall, generates keys)
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto

# 3. Configure secrets (CRITICAL - set admin_basic_auth_hash and API tokens)
make edit-secrets

# 4. Configure environment (.env file - set CLOUDFLARE_ZONE_ID, etc.)
nano .env

# 5. Start services
make up

# 6. Setup automation (recommended for set-and-forget operation)
sudo ./cron-setup.sh

# 7. Create break-glass admin for emergency access (RECOMMENDED)
make breakglass-create

# 8. Verify deployment
make health
```

**🎉 Your VaultWarden is now operational at https://vault.yourdomain.com**

## 🛠️ Quality of Life Improvements

### Makefile Shortcuts

Common operations are now available as simple `make` commands:

```bash
# System Management
make up                 # Start all services
make down               # Stop all services
make restart            # Force restart all services
make status             # Complete system overview
make health             # Comprehensive health check

# Backup & Restore
make backup-db          # Quick database backup
make backup-full        # Complete system backup
make backup-emergency   # Disaster recovery kit
make list-backups       # Show all available backups
make restore            # Interactive backup selection and restore

# Version Management
make pins               # Show currently pinned versions
make check-updates      # Check for available updates (no changes)
make update-containers  # Update containers with automatic backup
make pin SERVICE=vaultwarden VERSION=1.31.0    # Pin specific version
make unpin SERVICE=caddy                       # Use latest version

# Monitoring & Maintenance
make logs SERVICE=caddy LINES=200              # Show recent logs
make logs-follow SERVICE=fail2ban              # Follow logs in real-time
make config-check                              # Validate configurations

# Emergency Access
make breakglass-status    # Check emergency admin status
make breakglass-create    # Setup emergency admin access
```

### Interactive Features

- **Interactive Restore**: `make restore` provides a menu of available backups
- **Backup Listing**: `make list-backups` shows all backups with timestamps and sizes
- **Configuration Validation**: `make config-check` verifies Docker Compose syntax
- **Remote Backup Setup**: `make configure-rclone` guides through cloud storage setup

## 🏗️ Architecture

### Simple, Secure Stack

```
 Cloudflare Edge (Proxy, WAF, DNS)
       ↑ ↓
 Host Firewall (UFW - Cloudflare IPs + SSH only)
       ↑ ↓
┌─────────────────────────────────────────┐
│           Management Layer              │
│  ┌──────────┐  ┌──────────┐             │
│  │11 Scripts│  │3 Libraries│             │ ── Encrypted Secrets (Age + SOPS)
│  │(Ops)     │  │(Common)   │             │
│  └──────────┘  └──────────┘             │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│        Docker Application Stack         │
│  ┌──────┐  ┌───────────┐  ┌──────────┐  │
│  │Caddy │→ │VaultWarden│  │ ddclient │──┤ Cloudflare API (DNS)
│  │(SSL) │  │(App)      │  │ (DNS)    │  │
│  └──────┘  └───────────┘  └──────────┘  │
│      ↑                                  │
│  ┌────────┐                             │
│  │fail2ban│─────────────────────────────┤ Cloudflare API (IP Ban)
│  │(Sec)   │                             │
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

| Script | Purpose | Makefile Shortcut | Frequency |
|--------|---------|-------------------|-----------|
| `./setup.sh` | One-time system setup and configuration | N/A | Once |
| `./startup.sh` | Start/stop/restart services | `make up/down/restart` | As needed |
| `./health.sh` | System health monitoring with auto-repair | `make health` | Automated |
| `./backup.sh` | Create encrypted backups | `make backup-*` | Daily (automated) |
| `./restore.sh` | Restore from encrypted backups | `make restore` | Emergency |

### Configuration & Maintenance

| Script | Purpose | Makefile Shortcut | Frequency |  
|--------|---------|-------------------|-----------|
| `./edit-secrets.sh` | Secure secrets management | `make edit-secrets` | Initial + changes |
| `./update.sh` | Update containers/system packages | `make update-*` | Weekly (automated) |
| `./maintenance.sh` | System cleanup and optimization | `make maint-*` | Monthly (automated) |
| `./cron-setup.sh` | Configure automation | N/A | Once |

### Emergency & Recovery

| Script | Purpose | Makefile Shortcut | Frequency |
|--------|---------|-------------------|-----------|
| `./create-breakglass-admin.sh` | Create emergency admin for serial console | `make breakglass-*` | Once + as needed |

### Examples

```bash
# Health monitoring with automatic fixes
make health

# Backup operations
make backup-db                    # Quick database backup
make backup-full                  # Full backup with cloud sync (if configured)
make backup-emergency             # Disaster recovery kit
make list-backups                 # Show all available backups

# Interactive restore
make restore                      # Select from available backups

# Container version management
make pin SERVICE=vaultwarden VERSION=1.31.0     # Pin VaultWarden to v1.31.0
make unpin SERVICE=vaultwarden                   # Use latest VaultWarden
make pins                                        # Show all current pins

# Updates and maintenance
make check-updates                # Check for available updates
make update-containers            # Update Docker images with backup
make maint-standard              # Standard system cleanup

# Emergency access management
make breakglass-create           # Setup emergency admin
make breakglass-status           # Check emergency access status

# System monitoring
make status                      # Complete system overview
make logs SERVICE=caddy          # Show service logs
make logs-follow SERVICE=fail2ban # Follow logs in real-time
```

## 🔄 Container Version Management

### Flexible Version Strategy

This project uses a **flexible version management approach** that provides both stability and agility:

- **Default Behavior**: Uses `latest` Docker image tags for maximum flexibility
- **Production Recommendation**: Pin specific versions in `.env` for stability
- **Easy Switching**: Simple commands to pin/unpin versions as needed
- **Quality of Life**: Makefile shortcuts for common version operations

### Version Management Commands

#### Pin Specific Versions
```bash
# Pin VaultWarden to a specific version
make pin SERVICE=vaultwarden VERSION=1.31.0

# Pin multiple services
make pin SERVICE=caddy VERSION=2.8.5
make pin SERVICE=fail2ban VERSION=1.1.1

# Apply changes
make restart
```

#### Use Latest Versions
```bash
# Switch VaultWarden to latest
make unpin SERVICE=vaultwarden

# Switch multiple services to latest
make unpin SERVICE=caddy
make unpin SERVICE=fail2ban

# Apply changes
make restart
```

#### Check Current Versions
```bash
# View pinned versions
make pins

# Check running container versions
docker compose ps --format "table {{.Service}}	{{.Image}}"

# Check for available updates (no changes made)
make check-updates
```

### Container Version Management Best Practices

**When using latest tags** (e.g., in development or for emergency patches):
- Always run `docker compose pull` before `make restart` to ensure you are using the newest image layer and not a stale local one
- After any update (`make update-containers` or manual version changes), verify the running versions with `docker compose ps --format 'table {{.Service}}	{{.Image}}'`

### Update Workflows

#### Safe Production Updates
```bash
# 1. Create backup before updates
make backup-full

# 2. Check for available updates
make check-updates

# 3. Pin to new tested version
make pin SERVICE=vaultwarden VERSION=1.31.0

# 4. Apply update (includes automatic backup)
make update-containers

# 5. Verify system health
make health
```

#### Emergency Security Updates
```bash
# 1. Quickly switch to latest (gets security patches)
make unpin SERVICE=vaultwarden

# 2. Apply update immediately
make update-containers

# 3. Verify and monitor
make health
```

## 🔒 Security Features

### Multi-Layer Security

- **Encrypted Secrets**: All sensitive data encrypted with Age and managed via SOPS
- **Cloudflare Integration**:
  - Traffic proxied through Cloudflare's edge network
  - fail2ban blocks malicious IPs via Cloudflare API (edge blocking for efficiency)
  - Automatic IP list updates with firewall integration
- **Host Firewall**: UFW configured to allow web traffic only from Cloudflare IPs
- **HTTPS Enforcement**: Automatic HTTPS via Caddy with Let's Encrypt
- **Security Headers**: Comprehensive security headers (HSTS prevents downgrade attacks, CSP mitigates XSS)
- **Rate Limiting**: API and admin endpoint protection
- **Admin Protection**: Basic authentication with bcrypt hashing
- **Container Security**: Non-root execution and resource constraints
- **Emergency Recovery**: Secure break-glass admin access for critical situations
- **Version Management**: Controlled updates with rollback capability

## 📦 Backup & Recovery

### Automated Backup Strategy

- **Daily**: Encrypted database backups (retention: 14 days)
- **Weekly**: Encrypted full system backups (retention: 30 days)  
- **Manual**: Emergency recovery kits (retention: 90 days)
- **Offsite**: Automatic rclone sync to configured remote storage
- **Verification**: All backups verified after encryption before retention

### Backup Operations

```bash
# Create different types of backups
make backup-db          # Quick database backup
make backup-full        # Complete system backup
make backup-emergency   # Disaster recovery kit

# List and manage backups
make list-backups       # Show all available backups with details
make restore            # Interactive backup selection and restore

# Configure remote backup storage
make configure-rclone   # Setup cloud storage integration
```

### Recovery Process

```bash
# Interactive restore (recommended)
make restore

# Or restore specific backup file
./restore.sh /path/to/backup-file.age
```

### Emergency Access Recovery

If SSH access is lost due to firewall or account issues:

```bash
# 1. Access OCI Console → Compute → Instance → Console Connection
# 2. Login with break-glass admin credentials
# 3. Fix firewall: sudo ufw allow 22/tcp
# 4. Fix SSH issues: sudo systemctl restart sshd
# 5. Regain normal SSH access
# 6. SECURITY: Delete Console Connection in OCI Console
# 7. SECURITY: Rotate break-glass password: sudo ./create-breakglass-admin.sh password
```

## 📊 Monitoring & Health

### Automated Health Monitoring

**health.sh** provides comprehensive system monitoring:

- **Container Health**: Service status, resource usage, restart counts
- **System Resources**: Memory, disk space, network connectivity  
- **Backup Status**: Recent backup verification and integrity
- **Security Status**: Firewall rules, secrets accessibility
- **Emergency Access**: Break-glass admin account status verification
- **Version Management**: Container version tracking and update detection
- **Auto-Healing**: Automatic service restart/recreation on failure

### Manual Operations

```bash
# Comprehensive health check with auto-repair
make health

# Quick system status overview
make status

# System monitoring
make logs SERVICE=vaultwarden LINES=200    # Show recent logs
make logs-follow SERVICE=fail2ban          # Follow logs real-time

# Configuration validation
make config-check                          # Validate Docker Compose syntax

# Check emergency access status
make breakglass-status

# Check version status and updates
make pins                                  # Show pinned versions
make check-updates                         # Check for available updates
```

## 🔧 Configuration

### Required Configuration

1. **Cloudflare Setup**:
   ```bash
   # Create two API tokens at https://dash.cloudflare.com/profile/api-tokens
   # Token 1: ddclient (Zone:DNS:Edit for your domain)
   # Token 2: fail2ban (Zone:Firewall Services:Edit for your domain)
   ```

2. **Environment Configuration** (.env):
   ```bash
   DOMAIN=vault.yourdomain.com
   ADMIN_EMAIL=admin@yourdomain.com
   CLOUDFLARE_ZONE_ID=your_zone_id_here
   RCLONE_REMOTE_NAME=your_remote_name
   ```

3. **Secrets Configuration**:
   ```bash
   make edit-secrets
   # Set: admin_basic_auth_hash, ddclient_api_token, fail2ban_api_token
   # Optional: smtp_password, push_installation_key
   ```

4. **Emergency Access Setup** (Recommended):
   ```bash
   make breakglass-create
   # Creates emergency admin account for OCI serial console access
   # Essential safety net for SSH lockout scenarios
   ```

5. **Version Management** (Production):
   ```bash
   # Pin to stable versions:
   make pin SERVICE=vaultwarden VERSION=1.30.5
   make pin SERVICE=caddy VERSION=2.8.4
   make pin SERVICE=fail2ban VERSION=1.1.0
   make pin SERVICE=ddclient VERSION=3.11.2
   ```

### Optional Enhancements

- **Remote Backups**: Use `make configure-rclone` to setup cloud storage
- **Resource Limits**: Adjust memory/CPU limits in .env
- **Development Mode**: Use `--use-latest` flag in setup.sh for development environments

## 🆘 Troubleshooting

### Common Issues

**Service Won't Start**:
```bash
# Check service status
make health

# View container logs  
make logs SERVICE=vaultwarden

# Force restart with fresh configuration
make restart
```

**Version Management Issues**:
```bash
# Check current versions
make pins
docker compose ps --format "table {{.Service}}	{{.Image}}"

# Reset to known good versions
make pin SERVICE=vaultwarden VERSION=1.30.5
make pin SERVICE=caddy VERSION=2.8.4
make restart
```

**Backup Issues**:
```bash
# List available backups
make list-backups

# Test configuration
make config-check

# Create emergency backup
make backup-emergency
```

### Emergency Recovery

#### SSH Access Lost (Most Common Emergency)
1. **Use break-glass admin via OCI Console**:
   - Access OCI Console → Compute → Instance → Console Connection
   - Login with break-glass admin credentials: `make breakglass-status` (shows username)
   - Fix firewall: `sudo ufw allow 22/tcp`
   - Fix SSH: `sudo systemctl restart sshd`
   - **Security cleanup**: Delete Console Connection, rotate password

2. **If no break-glass admin configured**:
   - Use OCI boot volume attachment method
   - Create break-glass admin for future: `make breakglass-create`

## 🛡️ Security Best Practices

### During Initial Setup
- ✅ Configure break-glass admin: `make breakglass-create`
- ✅ Test OCI serial console access (verify it works)
- ✅ Create and test backup restoration: `make backup-emergency` then `make restore`
- ✅ Document emergency access credentials securely
- ✅ Pin production versions: Use `make pin` commands

### Ongoing Operations  
- ✅ Monitor break-glass admin status: `make breakglass-status`
- ✅ Test emergency procedures quarterly (without disruption)
- ✅ Keep break-glass credentials updated and accessible
- ✅ Review and update container versions: `make check-updates` monthly

### Emergency Preparedness
- 📝 Keep offline copy of troubleshooting procedures
- 📝 Document break-glass admin credentials securely  
- 📝 Maintain current backup of encryption keys
- 📝 Test OCI serial console access annually
- 📝 Document current production versions: `make pins`

## 📄 License

MIT License - see LICENSE file for details.

---

**VaultWarden-OCI-Simplified**: Secure, reliable, self-hosted password management made simple for small teams and dynamic environments, with comprehensive emergency recovery capabilities, flexible version management, and quality of life improvements for effortless daily operations.
