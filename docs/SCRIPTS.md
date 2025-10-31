# Script Reference Guide - VaultWarden-OCI

This comprehensive reference covers all scripts in VaultWarden-OCI, their usage patterns, options, and integration possibilities for small team deployments with template-based architecture and enhanced operations.

## Complete Script Inventory

### All Scripts Overview

| Script | Purpose | Frequency | Requires Root | Key Features |
|--------|---------|-----------|---------------|--------------|
| [`setup.sh`](#setupsh) | Template-based system setup and configuration | Once | Yes | Template generation, enhanced UFW warnings |
| [`startup.sh`](#startupsh) | Service lifecycle management | As needed | No | Race condition fixes, better health checks |
| [`health.sh`](#healthsh) | System monitoring and auto-repair | Automated (6h) | No | Comprehensive diagnostics, auto-healing |
| [`backup.sh`](#backupsh) | Enhanced backup creation with atomic operations | Daily (auto) | No | Atomic ops, enhanced listing, WAL checkpoints |
| [`restore.sh`](#restoresh) | Interactive system restoration from backups | Emergency | No | Interactive selection, enhanced validation |
| [`edit-secrets.sh`](#edit-secretssh) | Encrypted secrets management with Age/SOPS | As needed | No | Age encryption, SOPS integration, key rotation |
| [`update.sh`](#updatesh) | System and container updates | Weekly (auto) | Partial | Enhanced update management, rollback support |
| [`maintenance.sh`](#maintenancesh) | System cleanup and optimization | Monthly (auto) | Yes | Log rotation, Docker cleanup, retention management |
| [`cron-setup.sh`](#cron-setupsh) | Automation configuration | Once | Yes | Comprehensive scheduling, health monitoring |
| [`update-cloudflare-ips.sh`](#update-cloudflare-ipssh) | Enhanced firewall IP management | Weekly (auto) | Yes | Improved error handling, fallback warnings |
| [`db-maint.sh`](#db-maintsh) | Database optimization | Quarterly (auto) | Yes | SQLite optimization, integrity checks |
| [`create-breakglass-admin.sh`](#create-breakglass-adminsh) | Emergency admin for OCI serial console | As needed | Yes | Break-glass admin lifecycle, password management |

### Library Scripts (lib/ directory)

| Library | Purpose | Functions Provided |
|---------|---------|-------------------|
| [`lib/common.sh`](#libcommonsh) | Shared utilities and logging | Logging, validation, environment handling |
| [`lib/docker.sh`](#libdockersh) | Docker/container management | Service management, health checks |
| [`lib/crypto.sh`](#libcryptosh) | Encryption and key management | Age encryption, SOPS operations |

## Enhanced Features Overview

### Template-Based Operations
- **setup.sh**: Generates configuration from `.example` templates
- **All scripts**: Support template-based validation and maintenance
- **Consistent deployment**: Same templates produce identical configurations

### Atomic Operations
- **backup.sh**: Atomic backup creation prevents corruption
- **restore.sh**: Atomic restore operations with pre-restore backups
- **Enhanced reliability**: WAL checkpoints for live database snapshots

### Enhanced Security
- **fail2ban integration**: Rate limiting (max 30 API calls/minute)
- **UFW improvements**: Clear warnings and fallback configurations
- **Break-glass admin**: Emergency access via OCI serial console

## Core Management Scripts

### setup.sh

**Purpose**: Complete template-based system setup from fresh installation to production-ready deployment.

#### Synopsis
```bash
sudo ./setup.sh [OPTIONS]
```

#### Enhanced Options
```bash
--domain DOMAIN     Your domain (e.g., vault.example.com)
--email EMAIL       Admin email address
--auto             Automated setup with template generation and minimal prompts
--use-latest       Skip version pinning, use latest images (development mode)
--skip-deps        Skip dependency installation
--force            Overwrite existing configuration and regenerate templates
--dry-run          Show what would be done without executing
--help             Show help information
```

#### Template-Based Examples
```bash
# Interactive setup with template generation
sudo ./setup.sh

# Automated production setup with pinned versions from templates
sudo ./setup.sh --domain vault.example.com --email admin@example.com --auto

# Development setup with latest versions
sudo ./setup.sh --domain vault-dev.example.com --email dev@example.com --use-latest

# Force regenerate templates and configuration
sudo ./setup.sh --force --domain vault.example.com --email admin@example.com
```

### startup.sh

**Purpose**: Enhanced service lifecycle management with comprehensive container orchestration and race condition fixes.

#### Synopsis
```bash
./startup.sh [OPTIONS]
```

#### Enhanced Options
```bash
--help             Show help information
--force-restart    Stop and recreate all containers (required after secrets/template changes)
--dry-run         Show what would be done without executing
--skip-health     Skip post-startup health check
--down            Stop and remove all containers
--pull            Pull latest images before starting
--no-logs         Don't show container logs after startup
```

#### Enhanced Examples
```bash
# Normal startup with race condition fixes
./startup.sh

# Force restart after configuration/template changes (REQUIRED after template updates)
./startup.sh --force-restart

# Stop all services
./startup.sh --down

# Startup with latest images (useful after version changes)
./startup.sh --pull
```

### health.sh

**Purpose**: Comprehensive system health monitoring with automated repair capabilities and enhanced diagnostics.

#### Synopsis
```bash
./health.sh [OPTIONS]
```

#### Enhanced Options
```bash
--comprehensive    Run extended health checks including template validation
--auto-heal       Automatically attempt to fix issues
--email-alert     Send email notification if errors are found
--quiet           Only show warnings and errors
--json            Output results in JSON format for monitoring systems
--check TYPE      Run specific check type only
--help            Show help information
```

#### Enhanced Examples
```bash
# Comprehensive health check with template validation (recommended)
./health.sh --comprehensive

# Automated monitoring with repair and alerting
./health.sh --comprehensive --auto-heal --email-alert

# JSON output for monitoring systems
./health.sh --comprehensive --json

# Quick health check for automation
./health.sh --quiet
```

### backup.sh

**Purpose**: Enhanced backup creation with atomic operations, WAL checkpoints, and improved reliability.

#### Synopsis
```bash
./backup.sh [OPTIONS]
```

#### Enhanced Features
- **Atomic Operations**: Prevents corrupt backups during creation
- **WAL Checkpoints**: Improved database consistency for live snapshots
- **Enhanced Listing**: Shows backups with timestamps, sizes, and sequential IDs
- **Better Disk Space Management**: More conservative space checks
- **Improved Error Handling**: Robust fallback logic for operations

#### Enhanced Options
```bash
--type TYPE       Backup type: db, full, or emergency (default: db)
--rclone         Sync backup to rclone remote after creation
--email          Send email notification on completion (success or failure)
--retention DAYS Override default retention period
--compression    Compression level (1-9, default: 6)
--verify         Extra verification steps (default: enabled)
--list           List available local backups with enhanced details
--help           Show help information
```

#### Enhanced Examples
```bash
# Quick database backup with atomic operations
./backup.sh

# Full system backup with cloud sync
./backup.sh --type full --rclone

# List all available backups with enhanced details
./backup.sh --list
# Output shows: ID, Type, Date, Time, Size, Filename in table format

# Emergency recovery kit with notification
./backup.sh --type emergency --email
```

### restore.sh

**Purpose**: Interactive system restoration from encrypted backups with comprehensive safety validation and enhanced user experience.

#### Synopsis
```bash
./restore.sh [OPTIONS] [BACKUP_FILE]
```

#### Enhanced Features
- **Interactive Mode**: Select backups from a numbered menu with detailed information
- **Enhanced Validation**: Better error handling and prerequisites checking
- **Automatic Pre-Restore Backup**: Creates backup before restoration
- **Template Integration**: Properly handles template files in emergency kits

#### Enhanced Options
```bash
BACKUP_FILE      Path to the encrypted backup file (.age) to restore
--interactive    Show enhanced list of backups and prompt for selection (default if no file given)
--type TYPE      Restore type: auto, db, full, emergency (default: auto if file given)
--force          Skip confirmation prompts (use with extreme caution!)
--dry-run        Show what would be done without executing
--help           Show this help
```

#### Enhanced Examples
```bash
# Interactive restoration with enhanced backup selection
./restore.sh --interactive
# Shows table with ID, Type, Date, Time, Size, Filename

# Restore specific backup file
./restore.sh backups/db/vw-db-backup-20241025-020000.sqlite3.gz.age

# Preview restoration without executing
./restore.sh --dry-run backups/full/vw-full-backup-20241020-010000.tar.gz.age
```

### edit-secrets.sh

**Purpose**: Secure management of encrypted secrets using SOPS and Age with enhanced key management.

#### Synopsis
```bash
./edit-secrets.sh [OPTIONS]
```

#### Enhanced Options
```bash
--test           Test secrets accessibility without editing
--show           Show decrypted secrets (use with caution)
--rotate-keys    Rotate Age encryption keys (advanced operation)
--help           Show help information
```

#### Enhanced Examples
```bash
# Interactive secrets management (recommended)
./edit-secrets.sh

# Test secrets accessibility without editing
./edit-secrets.sh --test

# Rotate Age encryption keys (quarterly recommended)
./edit-secrets.sh --rotate-keys
```

### update.sh

**Purpose**: System and container updates with enhanced management and rollback capabilities.

#### Synopsis
```bash
./update.sh [OPTIONS]
```

#### Enhanced Options
```bash
--type TYPE         Update type: containers, system, all (required)
--check-only       Check for available updates without applying
--service SERVICE   Update specific service only (containers mode)
--auto-reboot      Automatically reboot if required (system mode)
--backup          Create backup before updates (recommended)
--rollback        Rollback last update if possible
--help             Show help information
```

#### Enhanced Examples
```bash
# Check for available updates (no changes made)
./update.sh --type containers --check-only

# Update containers with automatic backup
./update.sh --type containers --backup

# Update specific service only
./update.sh --type containers --service vaultwarden --backup

# Check for system updates
sudo ./update.sh --type system --check-only
```

## Emergency Recovery Workflow
```bash
# Complete emergency procedures
./create-breakglass-admin.sh status
./backup.sh --type emergency --rclone
# Use OCI serial console if SSH fails
# Login with break-glass admin credentials
```

## Best Practices

### Script Usage Best Practices

1. **Template-First Approach**: Always edit `.example` files and regenerate configuration
2. **Atomic Operations**: Rely on enhanced atomic backup and restore operations
3. **Interactive Tools**: Use enhanced interactive features for reliability
4. **Health Monitoring**: Use comprehensive health checks with auto-healing
5. **Emergency Preparedness**: Maintain break-glass admin access and test regularly

### Security Best Practices

1. **Regular Health Checks**: Use `./health.sh --comprehensive` for security validation
2. **Break-Glass Testing**: Annually verify break-glass admin access (status check)
3. **Template Validation**: Always run `docker compose config` after changes
4. **Key Rotation**: Quarterly rotation of Age encryption keys
5. **Enhanced Monitoring**: Leverage enhanced fail2ban logging and rate limiting

### Operational Best Practices

1. **Automated Operations**: Rely on cron-setup.sh for consistency
2. **Template-Based Maintenance**: Use setup.sh for all configuration changes
3. **Atomic Backups**: Trust enhanced backup operations for reliability
4. **Interactive Recovery**: Use enhanced restore features for safety
5. **Comprehensive Monitoring**: Enable health checks with auto-healing

---

**Note**: This script reference reflects the latest enhancements with template-based architecture, atomic operations, enhanced fail2ban security, and comprehensive emergency access capabilities. All scripts are designed to work together seamlessly while maintaining the "set-and-forget" operational philosophy optimized for small team deployments.
