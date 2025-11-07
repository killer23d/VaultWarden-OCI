# Scripts Reference - VaultWarden-OCI

Complete reference guide for all 12 management scripts and 5 utility libraries in VaultWarden-OCI.

## Core Management Scripts (12 Total)

### Essential Operations Scripts

#### 1. setup.sh
**Purpose**: One-time system initialization and configuration

**Usage**:
```bash
sudo ./setup.sh --domain vault.example.com --email admin@example.com [OPTIONS]
```

**Key Features**:
- Template-based configuration generation
- Platform-specific SSH log detection (OCI/Oracle Linux compatible)
- Enhanced UFW firewall with Cloudflare IP validation
- Automatic dependency installation
- Age encryption key generation
- SOPS configuration setup
- Enhanced security validation

**Options**:
- `--domain DOMAIN` - Your VaultWarden domain (required)
- `--email EMAIL` - Administrator email (required)
- `--auto` - Automated setup with minimal prompts
- `--use-latest` - Use latest container versions (default: pinned)
- `--skip-deps` - Skip dependency installation
- `--force` - Overwrite existing configuration files
- `--dry-run` - Show what would be done

**Example**:
```bash
sudo ./setup.sh --domain vault.example.com --email admin@example.com --auto
```

#### 2. startup.sh
**Purpose**: Start, stop, and restart VaultWarden services

**Usage**:
```bash
./startup.sh [OPTIONS]
```

**Key Features**:
- Enhanced secret handling with privacy protection
- Race condition fixes for service startup
- DNS record updates
- Comprehensive health checks
- Graceful service management

**Options**:
- `--force-restart` - Force restart all services
- `--down` - Stop all services
- `--skip-dns` - Skip DNS record updates
- `--dry-run` - Preview operations

**Example**:
```bash
./startup.sh --force-restart
```

**Makefile Shortcuts**:
```bash
make start     # Full initialization startup
make restart   # Restart with enhanced script
make stop      # Graceful shutdown
```

#### 3. health.sh
**Purpose**: System health monitoring and diagnostics

**Usage**:
```bash
./health.sh [OPTIONS]
```

**Key Features**:
- Service status checking
- Resource usage monitoring
- Configuration validation
- Connectivity testing
- Fail2ban status verification
- Email notification support
- JSON output option

**Options**:
- `--comprehensive` - Run all diagnostics
- `--email` - Send email notification
- `--quiet` - Minimal output (exit code only)
- `--json` - JSON formatted output

**Example**:
```bash
./health.sh --comprehensive --email
```

**Makefile Shortcuts**:
```bash
make health           # Basic health check
make health-email     # With email notification
```

#### 4. backup.sh
**Purpose**: Create encrypted backups with verification

**Usage**:
```bash
./backup.sh --type TYPE [OPTIONS]
```

**Key Features**:
- Atomic backup operations
- Safe database snapshots with WAL checkpoints
- Post-encryption checksum verification
- Optional full recoverability verification
- Three backup types: db, full, emergency
- Rclone offsite sync support
- Email notifications
- Comprehensive metadata generation

**Options**:
- `--type TYPE` - Backup type: db, full, or emergency (required)
- `--rclone` - Sync to rclone remote after creation
- `--email` - Send email notification
- `--full-verification` - Enable end-to-end verification test
- `--skip-full-verification` - Use fast checksum only (default)
- `--list` - List available backups
- `--dry-run` - Preview operations

**Backup Types**:
- `db` - Database only (fastest, daily recommended)
- `full` - Config files and data (NO secrets)
- `emergency` - Everything including secrets (disaster recovery)

**Examples**:
```bash
# Daily database backup (fast verification)
./backup.sh --type db

# Weekly full backup with complete verification
./backup.sh --type full --full-verification

# Emergency kit with offsite sync
./backup.sh --type emergency --rclone --email
```

**Makefile Shortcuts**:
```bash
make backup              # Database backup
make backup-full         # Full system backup
make backup-emergency    # Emergency recovery kit
make list-backups        # List available backups
```

#### 5. restore.sh
**Purpose**: Restore from encrypted backups

**Usage**:
```bash
./restore.sh [OPTIONS]
```

**Key Features**:
- Interactive backup selection
- Automatic decryption
- Database integrity verification
- Service management during restore
- Comprehensive validation

**Options**:
- `--file FILE` - Specific backup file to restore
- `--type TYPE` - Filter backups by type
- `--force` - Skip confirmation prompts
- `--dry-run` - Preview operations

**Example**:
```bash
# Interactive restore (recommended)
./restore.sh

# Restore specific file
./restore.sh --file /path/to/backup.age --force
```

**Makefile Shortcuts**:
```bash
make restore             # Interactive restore
```

### Configuration & Secrets Management

#### 6. edit-secrets.sh
**Purpose**: Secure secrets editing with enhanced privacy

**Usage**:
```bash
./edit-secrets.sh [OPTIONS]
```

**Key Features**:
- SOPS key path never exposed in process list
- Secure temporary file handling
- Automatic backup creation before editing
- Comprehensive validation after editing
- Editor security validation
- Privacy protection enhancements

**Options**:
- `--editor EDITOR` - Specify editor (default: nano)
- `--no-backup` - Skip backup creation
- `--no-validation` - Skip post-edit validation
- `--test` - Test secrets decryption without editing

**Example**:
```bash
./edit-secrets.sh
./edit-secrets.sh --editor vim
```

**Makefile Shortcuts**:
```bash
make edit-secrets        # Edit encrypted secrets
make test-secrets        # Test secrets decryption
```

### Update & Maintenance Scripts

#### 7. update.sh
**Purpose**: Update container images and system packages

**Usage**:
```bash
./update.sh [OPTIONS]
```

**Key Features**:
- Automatic backup before updates
- Container image updates
- System package updates
- Version pinning respect
- Email notifications

**Options**:
- `--system` - Update system packages too
- `--email` - Send email notification
- `--no-backup` - Skip pre-update backup
- `--dry-run` - Preview operations

**Example**:
```bash
./update.sh --system --email
```

**Makefile Shortcuts**:
```bash
make update              # Update containers only
make update-system       # Update system and containers
```

#### 8. maintenance.sh
**Purpose**: System cleanup and optimization

**Usage**:
```bash
./maintenance.sh [OPTIONS]
```

**Key Features**:
- Safe database maintenance (offline)
- Docker cleanup operations
- Log rotation and cleanup
- Backup pruning
- Enhanced firewall updates with race condition fixes
- Email notifications

**Options**:
- `--comprehensive` - Run all maintenance tasks
- `--no-logs` - Skip log cleanup
- `--no-backups` - Skip backup pruning
- `--no-database` - Skip database maintenance
- `--update-firewall` - Update Cloudflare firewall rules
- `--email` - Send email notification
- `--dry-run` - Preview operations

**Example**:
```bash
./maintenance.sh --comprehensive --email
./maintenance.sh --update-firewall
```

**Makefile Shortcuts**:
```bash
make maintenance         # Basic maintenance
make maintenance-full    # Comprehensive maintenance
```

#### 9. cron-setup.sh
**Purpose**: Configure automated task scheduling

**Usage**:
```bash
sudo ./cron-setup.sh [OPTIONS]
```

**Key Features**:
- Secure privilege management
- Automated backups
- Regular health checks
- Periodic updates
- Monthly maintenance
- Validation of cron jobs

**Options**:
- `--install` - Install cron jobs
- `--remove` - Remove cron jobs
- `--list` - List current cron jobs
- `--dry-run` - Preview operations

**Default Schedule**:
- Daily 2 AM: Database backup
- Daily 6 AM: Health check
- Weekly Sunday 3 AM: Full backup with verification
- Weekly Sunday 4 AM: Container updates
- Monthly 1st 5 AM: Comprehensive maintenance

**Example**:
```bash
sudo ./cron-setup.sh --install
```

**Makefile Shortcuts**:
```bash
make cron-install        # Install cron jobs
make cron-remove         # Remove cron jobs
make cron-list           # List cron jobs
```

### Emergency & Recovery Scripts

#### 10. create-breakglass-admin.sh
**Purpose**: Emergency admin account for OCI console access

**Usage**:
```bash
./create-breakglass-admin.sh [OPTIONS]
```

**Key Features**:
- Secure non-root user with sudo privileges
- SSH key authentication setup
- Password auth for OCI console only
- Comprehensive audit logging
- Security validation using centralized lib/security.sh

**Options**:
- `--create` - Create emergency admin account
- `--status` - Show break-glass admin status
- `--password` - Generate new password
- `--validate` - Validate security configuration
- `--remove` - Remove emergency admin account

**Example**:
```bash
./create-breakglass-admin.sh --create
```

**Makefile Shortcuts**:
```bash
make breakglass-create   # Create emergency admin
make breakglass-status   # Check status
make breakglass-remove   # Remove emergency admin
```

#### 11. db-maint.sh
**Purpose**: Database maintenance and optimization

**Usage**:
```bash
./db-maint.sh [OPTIONS]
```

**Key Features**:
- Safe offline database operations
- WAL checkpoint before maintenance
- Integrity checking before and after
- VACUUM operation for optimization
- Service management

**Options**:
- `--force` - Skip confirmation prompts
- `--dry-run` - Preview operations

**Example**:
```bash
./db-maint.sh
```

**Makefile Shortcuts**:
```bash
make db-maint            # Database maintenance
```

#### 12. update-dns.sh
**Purpose**: Manual DNS record updates

**Usage**:
```bash
./update-dns.sh [OPTIONS]
```

**Key Features**:
- Cloudflare API integration
- Current IP detection
- DNS record validation
- Error handling

**Options**:
- `--dry-run` - Preview operations

**Example**:
```bash
./update-dns.sh
```

**Makefile Shortcuts**:
```bash
make update-dns          # Update DNS record
```

### Testing & Validation Scripts

#### test-email-simple.sh
**Purpose**: Test email configuration

**Usage**:
```bash
./test-email-simple.sh [OPTIONS]
```

**Key Features**:
- Tests msmtpd container functionality
- Validates SMTP configuration
- Connection testing
- Detailed diagnostics

**Options**:
- `--verbose` - Detailed output
- `--to EMAIL` - Override recipient email

**Example**:
```bash
./test-email-simple.sh
./test-email-simple.sh --verbose --to test@example.com
```

## Utility Libraries (5 Total)

### lib/common.sh
**Purpose**: Core utility functions used by all scripts

**Key Functions**:
- `init_common_lib()` - Initialize library with script context
- `log_info()`, `log_success()`, `log_warn()`, `log_error()` - Logging functions
- `require_commands()` - Check for required commands
- `has_command()` - Check if command exists
- `get_config_value()` - Get configuration value from .env
- `load_env_file()` - Load environment variables
- `get_real_user()` - Get actual user (even when running as root)
- `ensure_dir()` - Create directory with permissions
- `safe_execute()` - Execute command with error handling
- `retry_with_backoff()` - Retry operation with exponential backoff
- `validate_domain()`, `validate_email()`, `validate_port()` - Input validation
- `send_notification_email()` - Send email notifications (prefers msmtpd)

**Usage Example**:
```bash
source "lib/common.sh"
init_common_lib "$0"
log_info "Starting operation..."
```

### lib/docker.sh
**Purpose**: Docker and Docker Compose operations

**Key Functions**:
- `require_docker()` - Verify Docker is available
- `is_service_running()` - Check if service is running
- `wait_for_service()` - Wait for service to be ready
- `stop_service()`, `start_service()` - Service management
- `get_container_status()` - Get detailed container status
- `docker_cleanup()` - Clean up Docker resources

**Usage Example**:
```bash
source "lib/docker.sh"
is_service_running "vaultwarden" && echo "Running"
```

### lib/crypto.sh
**Purpose**: Encryption, decryption, and key management

**Key Functions**:
- `generate_age_key()` - Generate Age encryption key
- `get_age_public_key()` - Extract Age public key
- `encrypt_data()` - Encrypt data with Age
- `decrypt_data()` - Decrypt Age-encrypted data
- `encrypt_sops_file()` - Encrypt file with SOPS
- `decrypt_sops_file()` - Decrypt SOPS file
- `generate_secure_string()` - Generate cryptographically secure random string
- `calculate_sha256()` - Calculate SHA256 checksum
- `secure_file()` - Set secure permissions on file

**Usage Example**:
```bash
source "lib/crypto.sh"
generate_age_key "secrets/keys/age-key.txt"
```

### lib/security.sh
**Purpose**: Centralized security validation and operations

**Key Functions**:
- `validate_file_permissions()` - Validate file permissions, owner, group
- `validate_directory_permissions()` - Recursive directory validation
- `create_secure_file()` - Atomic secure file creation
- `secure_cleanup()` - Multi-pass secure file deletion
- `validate_password_strength()` - Password strength validation
- `generate_secure_random()` - Cryptographically secure random generation
- `validate_system_security()` - Comprehensive system security check

**Usage Example**:
```bash
source "lib/security.sh"
validate_file_permissions "/path/to/file" "600" "user" "group"
```

### lib/backup_utils.sh (NEW)
**Purpose**: Backup-specific utility functions

**Key Functions**:
- `check_backup_disk_space()` - Validate available disk space
- `list_backups()` - List available backups with metadata
- `get_backup_metadata()` - Extract backup metadata
- `verify_backup_integrity()` - Verify backup file integrity
- `cleanup_old_backups()` - Remove old backups based on retention policy
- `format_backup_size()` - Human-readable size formatting

**Usage Example**:
```bash
source "lib/backup_utils.sh"
check_backup_disk_space "/path/to/backup/dir" 1000
```

## Script Design Patterns

### Standardized Error Handling
All scripts follow a standardized error handling pattern:

```bash
# Functions return exit codes
function_name() {
    # Operations
    return 0  # Success
    return 1  # Failure
}

# Main function collects status
main() {
    if ! function_name; then
        log_error "Operation failed"
        exit 1
    fi
    exit 0
}
```

### Cleanup Management
Scripts use trap-based cleanup:

```bash
CLEANUP_ACTIONS=()
register_cleanup() { CLEANUP_ACTIONS+=("$1"); }
perform_cleanup() {
    for ((idx=${#CLEANUP_ACTIONS[@]}-1; idx>=0; idx--)); do
        eval "${CLEANUP_ACTIONS[$idx]}" 2>/dev/null || true
    done
}
trap perform_cleanup EXIT
```

### Library Integration
All scripts follow consistent library integration:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh"
# ... other libraries as needed
```

## Best Practices

### Script Execution
1. **Always run from project root**: Scripts assume they are run from the project root directory
2. **Use sudo when required**: setup.sh, cron-setup.sh, create-breakglass-admin.sh need sudo
3. **Check help first**: All scripts support `--help` option
4. **Use dry-run**: Preview operations with `--dry-run` when available

### Makefile Usage
1. **Prefer Makefile shortcuts**: More convenient and consistent
2. **Use descriptive targets**: `make health` instead of remembering script options
3. **Check available targets**: Run `make help` to see all options

### Security Considerations
1. **Validate before production**: Always test in development first
2. **Review generated files**: Check docker-compose.yml and .env after setup
3. **Secure cleanup**: Scripts automatically clean up sensitive temporary files
4. **Audit logging**: All administrative actions are logged

### Operational Excellence
1. **Use automation**: Install cron jobs with `make cron-install`
2. **Monitor regularly**: Use `make health` for health checks
3. **Test backups**: Regularly test restore procedures
4. **Keep updated**: Run `make update` regularly for security patches

---

This scripts reference provides comprehensive documentation for all management scripts and utility libraries in VaultWarden-OCI, enabling efficient operation and maintenance of your VaultWarden deployment.
