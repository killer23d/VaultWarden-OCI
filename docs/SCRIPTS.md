# Script Reference Guide - VaultWarden-OCI-Simplified

This comprehensive reference covers all scripts in VaultWarden-OCI-Simplified, their usage patterns, options, and integration possibilities for small team deployments.

## Complete Script Inventory

### All Scripts Overview

| Script | Purpose | Makefile Shortcut | Frequency | Requires Root | Lines |
|--------|---------|-------------------|-----------|---------------|-------|
| [`setup.sh`](#setupsh) | Initial system setup and configuration | N/A | Once | Yes | ~650 |
| [`startup.sh`](#startupsh) | Service lifecycle management | `make up/down/restart` | As needed | No | ~270 |
| [`health.sh`](#healthsh) | System monitoring and auto-repair | `make health` | Automated (6h) | No | ~350 |
| [`backup.sh`](#backupsh) | Backup creation and management | `make backup-*` | Daily (auto) | No | ~780 |
| [`restore.sh`](#restoresh) | System restoration from backups | `make restore` | Emergency | No | ~540 |
| [`edit-secrets.sh`](#edit-secretssh) | Encrypted secrets management | `make edit-secrets` | As needed | No | ~320 |
| [`update.sh`](#updatesh) | System and container updates with version management | `make update-*` | Weekly (auto) | Partial | ~430 |
| [`maintenance.sh`](#maintenancesh) | System cleanup and optimization | `make maint-*` | Monthly (auto) | Yes | ~580 |
| [`cron-setup.sh`](#cron-setupsh) | Automation configuration | N/A | Once | Yes | ~420 |
| [`update-cloudflare-ips.sh`](#update-cloudflare-ipssh) | Firewall IP management | `make update-ips` | Weekly (auto) | Yes | ~270 |
| [`db-maint.sh`](#db-maintsh) | Database optimization | `make db-maint` | Quarterly (auto) | Yes | ~230 |
| [`create-breakglass-admin.sh`](#create-breakglass-adminsh) | Emergency admin for serial console | `make breakglass-*` | As needed | Yes | ~450 |

### Library Scripts (lib/ directory)

| Library | Purpose | Functions Provided |
|---------|---------|-------------------|
| [`lib/common.sh`](#libcommonsh) | Shared utilities and logging | Logging, validation, environment handling |
| [`lib/docker.sh`](#libdockersh) | Docker/container management | Service management, health checks |
| [`lib/crypto.sh`](#libcryptosh) | Encryption and key management | Age encryption, SOPS operations |

## Quality of Life Improvements

### Makefile Integration

All major operations now have convenient Makefile shortcuts:

```bash
# System Management
make up                 # ./startup.sh
make down               # ./startup.sh --down  
make restart            # ./startup.sh --force-restart
make status             # Complete system overview
make health             # ./health.sh --comprehensive

# Backup Operations
make backup-db          # ./backup.sh --type db
make backup-full        # ./backup.sh --type full
make backup-emergency   # ./backup.sh --type emergency
make list-backups       # ./backup.sh --list
make restore            # ./restore.sh --interactive

# Version Management
make pins               # ./update.sh --show-pins
make check-updates      # ./update.sh --type containers --check-only
make update-containers  # ./update.sh --type containers --backup
make pin SERVICE=... VERSION=...    # ./update.sh --pin ...
make unpin SERVICE=...              # ./update.sh --unpin ...

# Maintenance
make maint-standard     # sudo ./maintenance.sh --type standard --force
make maint-deep         # sudo ./maintenance.sh --type deep --force
make db-maint           # sudo ./db-maint.sh --force

# Emergency Access
make breakglass-create    # sudo ./create-breakglass-admin.sh create
make breakglass-status    # sudo ./create-breakglass-admin.sh status
make breakglass-password  # sudo ./create-breakglass-admin.sh password
```

### Interactive Features

- **Interactive Restore**: `make restore` provides a numbered menu of available backups
- **Backup Listing**: Enhanced `./backup.sh --list` shows backups with timestamps, sizes, and IDs
- **Configuration Validation**: `make config-check` validates Docker Compose syntax
- **Remote Backup Setup**: `make configure-rclone` guides through cloud storage configuration

## Core Management Scripts

### setup.sh

**Purpose**: Complete system setup from fresh installation to production-ready deployment.

#### Synopsis
```bash
sudo ./setup.sh [OPTIONS]
```

#### Options
```bash
--domain DOMAIN     Your domain (e.g., vault.example.com)
--email EMAIL       Admin email address
--auto             Automated setup with minimal prompts
--use-latest       Skip version pinning, use latest images by default
--skip-deps        Skip dependency installation
--force            Overwrite existing configuration
--dry-run          Show what would be done without executing
--help             Show help information
```

#### Examples
```bash
# Interactive setup
sudo ./setup.sh

# Automated production setup (pinned versions)
sudo ./setup.sh --domain vault.example.com --email admin@example.com --auto

# Development setup (latest versions)
sudo ./setup.sh --domain vault-dev.example.com --email dev@example.com --use-latest
```

### startup.sh

**Purpose**: Service lifecycle management with comprehensive container orchestration.

#### Synopsis
```bash
./startup.sh [OPTIONS]
# Or use Makefile shortcuts:
make up            # Start services
make down          # Stop services  
make restart       # Force restart all services
```

#### Options
```bash
--help             Show help information
--force-restart    Stop and recreate all containers (required after secrets changes)
--dry-run         Show what would be done without executing
--skip-health     Skip post-startup health check
--down            Stop and remove all containers
--pull            Pull latest images before starting
--no-logs         Don't show container logs after startup
```

#### Examples
```bash
# Normal startup (start stopped services)
make up
# Or: ./startup.sh

# Force restart after configuration changes (REQUIRED after edit-secrets.sh)
make restart
# Or: ./startup.sh --force-restart

# Stop all services
make down
# Or: ./startup.sh --down
```

### health.sh

**Purpose**: Comprehensive system health monitoring with automated repair capabilities.

#### Synopsis
```bash
./health.sh [OPTIONS]
# Or use Makefile shortcut:
make health        # Run comprehensive health check
```

#### Options
```bash
--comprehensive    Run extended health checks
--auto-heal       Automatically attempt to fix issues
--email-alert     Send email notification if errors are found
--quiet           Only show warnings and errors
--json            Output results in JSON format
--check TYPE      Run specific check type only
--help            Show help information
```

#### Examples
```bash
# Comprehensive health check (recommended)
make health
# Or: ./health.sh --comprehensive

# Automated monitoring with repair and alerting
./health.sh --comprehensive --auto-heal --email-alert

# JSON output for monitoring systems
./health.sh --comprehensive --json
```

### backup.sh

**Purpose**: Comprehensive backup creation with encryption and verification. **Enhanced with improved listing and interactive features**.

#### Synopsis
```bash
./backup.sh [OPTIONS]
# Or use Makefile shortcuts:
make backup-db          # Database backup
make backup-full        # Full system backup
make backup-emergency   # Emergency recovery kit
make list-backups       # List all available backups
```

#### New Features
- **Improved Listing**: `--list` option shows backups with timestamps, sizes, and sequential IDs
- **Enhanced Parsing**: Fixed backup filename parsing and timestamp handling
- **Better Error Handling**: Robust fallback logic for rsync operations

#### Options
```bash
--type TYPE       Backup type: db, full, or emergency (default: db)
--rclone         Sync backup to rclone remote after creation
--email          Send email notification on completion (success or failure)
--retention DAYS Override default retention period
--compression    Compression level (1-9, default: 6)
--verify         Extra verification steps (default: enabled)
--list           List available local backups (db, full, emergency)
--help           Show help information
```

#### Examples
```bash
# Quick database backup
make backup-db
# Or: ./backup.sh

# Full system backup with cloud sync
make backup-full
# Or: ./backup.sh --type full --rclone

# List all available backups with details
make list-backups
# Or: ./backup.sh --list

# Emergency recovery kit with notification
./backup.sh --type emergency --email
```

### restore.sh

**Purpose**: System restoration from encrypted backups with comprehensive safety validation. **Enhanced with interactive selection**.

#### Synopsis
```bash
./restore.sh [OPTIONS] [BACKUP_FILE]
# Or use Makefile shortcut:
make restore       # Interactive backup selection
```

#### New Features
- **Interactive Mode**: Select backups from a numbered menu
- **Enhanced Listing**: Shows available backups with timestamps and types
- **Improved Validation**: Better error handling and prerequisites checking

#### Options
```bash
BACKUP_FILE      Path to the encrypted backup file (.age) to restore
--interactive    Show a list of backups and prompt for selection (default if no file given)
--type TYPE      Restore type: auto, db, full, emergency (default: auto if file given)
--force          Skip confirmation prompts (use with extreme caution!)
--dry-run        Show what would be done without executing
--help           Show this help
```

#### Examples
```bash
# Interactive restoration with backup selection
make restore
# Or: ./restore.sh --interactive

# Restore specific backup file
./restore.sh backups/db/vw-db-backup-20241025-020000.sqlite3.gz.age

# Preview restoration without executing
./restore.sh --dry-run backups/full/vw-full-backup-20241020-010000.tar.gz.age
```

### edit-secrets.sh

**Purpose**: Secure management of encrypted secrets using SOPS and Age.

#### Synopsis
```bash
./edit-secrets.sh [OPTIONS]
# Or use Makefile shortcut:
make edit-secrets
```

#### Examples
```bash
# Interactive secrets management (recommended)
make edit-secrets
# Or: ./edit-secrets.sh

# Test secrets accessibility without editing
./edit-secrets.sh --test
```

### update.sh

**Purpose**: System and container updates with version management capabilities. **Enhanced with check-only options**.

#### Synopsis
```bash
./update.sh [OPTIONS]
# Or use Makefile shortcuts:
make check-updates      # Check for container updates (no changes)
make check-system-updates # Check for system updates (no changes)
make update-containers  # Update containers with automatic backup
make pins              # Show currently pinned versions
make pin SERVICE=... VERSION=...    # Pin service to specific version
make unpin SERVICE=...              # Remove version pin (use latest)
```

#### New Features
- **Check-only modes**: Review available updates without applying changes
- **Enhanced version management**: Improved pin/unpin functionality
- **Makefile integration**: Convenient shortcuts for all operations

#### Options
```bash
--type TYPE         Update type: containers, system, all (required)
--check-only       Check for available updates without applying
--service SERVICE   Update specific service only (containers mode)
--auto-reboot      Automatically reboot if required (system mode)
--backup          Create backup before updates (recommended)
--rollback        Rollback last update if possible
--pin SERVICE VER  Pin service to specific version
--unpin SERVICE    Remove version pin (use latest)
--show-pins       Show currently pinned versions
--help             Show help information
```

#### Examples
```bash
# Check for available updates (no changes made)
make check-updates
# Or: ./update.sh --type containers --check-only

# Update containers with automatic backup
make update-containers
# Or: ./update.sh --type containers --backup

# Version management
make pin SERVICE=vaultwarden VERSION=1.31.0
make unpin SERVICE=caddy
make pins

# Check for system updates
make check-system-updates
# Or: sudo ./update.sh --type system --check-only
```

### maintenance.sh

**Purpose**: System cleanup and optimization for long-term health and performance.

#### Synopsis
```bash
sudo ./maintenance.sh [OPTIONS]
# Or use Makefile shortcuts:
make maint-standard     # Standard cleanup
make maint-deep         # Deep system cleanup
```

#### Examples
```bash
# Standard monthly maintenance
make maint-standard
# Or: sudo ./maintenance.sh --type standard --force

# Deep system cleanup
make maint-deep
# Or: sudo ./maintenance.sh --type deep --force
```

### create-breakglass-admin.sh

**Purpose**: Interactive creation of emergency admin account for OCI serial console access when SSH is unavailable.

#### Synopsis
```bash
sudo ./create-breakglass-admin.sh [COMMAND] [OPTIONS]
# Or use Makefile shortcuts:
make breakglass-create     # Create/update break-glass admin
make breakglass-status     # Check status
make breakglass-password   # Set password
```

#### Commands and Options
```bash
create           Create break-glass admin user (default, interactive)
interactive      Same as create (interactive prompts)
password         Set password for existing break-glass admin
status           Show current break-glass admin status
--force          Skip interactive confirmations for existing users
--help           Show help information
```

#### Examples
```bash
# Interactive break-glass admin creation (recommended)
make breakglass-create
# Or: sudo ./create-breakglass-admin.sh create

# Check status of break-glass accounts
make breakglass-status
# Or: sudo ./create-breakglass-admin.sh status

# Set password for existing break-glass admin
make breakglass-password
# Or: sudo ./create-breakglass-admin.sh password
```

## Version Management

### Simple Version Control with Makefile Integration

Version management is handled through `.env` file configuration and `update.sh` commands, now with convenient Makefile shortcuts:

#### Check Current Versions
```bash
# View pinned versions
make pins
# Or: ./update.sh --show-pins

# View running container versions
docker compose ps --format "table {{.Service}}	{{.Image}}"

# Check for available updates (no changes made)
make check-updates
# Or: ./update.sh --type containers --check-only
```

#### Pin Specific Versions
```bash
# Pin to specific versions for stability
make pin SERVICE=vaultwarden VERSION=1.31.0
make pin SERVICE=caddy VERSION=2.8.5

# Apply changes
make restart
```

#### Use Latest Versions
```bash
# Switch to latest for testing/development
make unpin SERVICE=vaultwarden
make unpin SERVICE=caddy

# Apply changes
make restart
```

#### Container Version Management Best Practices

**When using latest tags** (e.g., in development or for emergency patches):
- Always run `docker compose pull` before `make restart` to ensure you are using the newest image layer and not a stale local one
- After any update (`make update-containers` or manual version changes), verify the running versions with `docker compose ps --format 'table {{.Service}}	{{.Image}}'`

## Integration Patterns

### Health-Based Automation
```bash
# Conditional operations based on health status
if make health > /dev/null 2>&1; then
    make update-containers
else
    ./health.sh --auto-heal
fi
```

### Version-Aware Updates
```bash
# Safe production update workflow
make backup-full
make pin SERVICE=vaultwarden VERSION=1.31.0
make update-containers
make health
```

### Emergency Recovery Workflow
```bash
# Complete emergency procedures
make breakglass-status
make backup-emergency
# Use OCI serial console if SSH fails
```

## Daily Operations

### For Single Admin (<10 Users)

#### Daily Tasks (2 minutes with Makefile)
```bash
# Quick system overview
make status

# Automated health check if needed
make health
```

#### Weekly Tasks (10 minutes with Makefile)
```bash
# Check for available updates
make check-updates

# Review security logs
make logs SERVICE=fail2ban | tail -20

# Verify emergency access
make breakglass-status
```

#### Monthly Tasks (15 minutes with Makefile)
```bash
# System maintenance
make maint-standard

# Create emergency backup
make backup-emergency

# Review and update versions if needed
make check-updates
# If updates available, consider pinning new stable versions
```

#### Emergency Procedures (30 seconds with Makefile)
```bash
# Quick service restart
make restart

# Emergency backup
make backup-emergency

# System recovery from backup
make restore

# Break-glass admin access (via OCI serial console)
# Use credentials from: make breakglass-status
```

## Configuration Management

### New Makefile Features

#### Configuration Validation
```bash
# Validate Docker Compose configuration syntax
make config-check
```

#### Remote Backup Configuration
```bash
# Interactive rclone setup
make configure-rclone
```

#### System Status Overview
```bash
# Comprehensive system status
make status
# Shows: services, resources, versions, recent backups, fail2ban status
```

## Library Scripts

### lib/common.sh

**Purpose**: Shared utilities, logging, and environment handling for all scripts.

#### Key Functions
- **Logging**: `log_info`, `log_warn`, `log_error`, `log_success`, `log_debug`
- **Environment**: `load_env_file`, `get_config_value`, `require_config`
- **Validation**: `require_commands`, `has_command`, `is_root`
- **File Operations**: `ensure_dir`, `secure_file`, `backup_file`

### lib/docker.sh  

**Purpose**: Docker and container management functionality.

#### Key Functions
- **Container Management**: `is_service_running`, `get_service_health`, `restart_service`
- **Docker Compose**: `compose_up`, `compose_down`, `compose_restart`
- **Health Checks**: `wait_for_healthy`, `check_docker_daemon`

### lib/crypto.sh

**Purpose**: Encryption, key management, and cryptographic operations.

#### Key Functions
- **Age Encryption**: `encrypt_file`, `decrypt_file`, `check_age_key`
- **SOPS Operations**: `encrypt_with_sops`, `decrypt_with_sops`, `sops_edit`
- **Key Management**: `validate_age_key`, `generate_age_keypair`

---

**Note**: This script reference reflects the latest quality of life improvements with Makefile integration, interactive features, and enhanced backup/restore functionality. All scripts are designed to work together seamlessly while maintaining the "set-and-forget" operational philosophy optimized for small team deployments.
