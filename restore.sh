#!/usr/bin/env bash
# restore.sh - VaultWarden backup restoration with enhanced safety
#
# FIXES APPLIED (2026-02):
#   [ITEM 1]  CRITICAL  - Decrypt and verify the incoming backup BEFORE moving
#                         the live database.  The live DB is now only replaced
#                         after the new DB passes all integrity checks.
#   [ITEM 3]  CRITICAL  - Fixed DB restore destination path from
#                         $state_dir/data/bwdata/db.sqlite3  (wrong)
#                      to $state_dir/data/db.sqlite3          (correct, matches backup)
#   [ITEM 4]  CRITICAL  - Fixed restore-point backup call from
#                         ./backup.sh --type emergency --email=false  (breaks arg parser)
#                      to ./backup.sh --type emergency                (email off by default)
#   [ITEM 8]  MEDIUM    - Replaced bare `trap ... EXIT` in restore_archive() with
#                         the register_cleanup_dir() pattern so no prior EXIT trap
#                         is silently overwritten.
#   [ITEM 10] MINOR     - Replaced hard-coded sleep 45 in validate_restore_health()
#                         with a 10-attempt polling loop (5 s between attempts) that
#                         exits early the moment health.sh reports success.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh"
source "lib/backup_utils.sh"

# FIX [ITEM 8]: Mirror the safe cleanup registry from backup.sh so restore_archive
# can register temp dirs without overwriting any existing EXIT trap.
CLEANUP_DIRS=()
register_cleanup_dir() { CLEANUP_DIRS+=("$1"); }
perform_cleanup() {
    local i
    for (( i=${#CLEANUP_DIRS[@]}-1; i>=0; i-- )); do
        rm -rf "${CLEANUP_DIRS[$i]}" 2>/dev/null || true
    done
}
trap perform_cleanup EXIT

# Configuration
BACKUP_FILE=""
RESTORE_TYPE=""
FORCE_RESTORE=false
DRY_RUN=false
SKIP_VERIFICATION=false
INTERACTIVE=true
CREATE_RESTORE_BACKUP=true

show_help() {
    cat << 'EOF'
VaultWarden-OCI Restore Script with Safety Checks

USAGE:
    ./restore.sh [OPTIONS]

OPTIONS:
    --file FILE             Specific backup file to restore
    --type TYPE             Backup type to restore (db, full, emergency)
    --force                 Skip confirmation prompts
    --no-backup             Skip creating restore point backup
    --skip-verification     Skip backup integrity verification
    --dry-run               Show what would be restored without executing
    --help                  Show this help

EXAMPLES:
    ./restore.sh                                    # Interactive restore
    ./restore.sh --type db                          # Restore latest database backup
    ./restore.sh --file backup-20241101.tar.gz.age  # Restore specific file
    ./restore.sh --dry-run --type full              # Preview full system restore

SAFETY FEATURES:
    - Interactive backup selection with metadata display
    - Automatic restore point backup before restore
    - Backup integrity verification before restore
    - Service health checks after restore
    - Rollback capability if restore fails

RESTORE TYPES:
    db          - Database only (preserves configuration)
    full        - Configuration + data (NO secrets)
    emergency   - EVERYTHING including secrets
EOF
}

# Argument Parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --file)              BACKUP_FILE="$2"; shift 2 ;;
        --type)              RESTORE_TYPE="$2"; shift 2 ;;
        --force)             FORCE_RESTORE=true; INTERACTIVE=false; shift ;;
        --no-backup)         CREATE_RESTORE_BACKUP=false; shift ;;
        --skip-verification) SKIP_VERIFICATION=true; shift ;;
        --dry-run)           DRY_RUN=true; shift ;;
        --help)              show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# Interactive backup selection - returns exit code
select_backup_interactively() {
    if [[ "$INTERACTIVE" != "true" ]]; then
        return 0  # Skip if not interactive
    fi

    echo -e "${COLOR_YELLOW}PRE-RESTORE CHECKLIST:${COLOR_RESET}"
    echo -e "Ensure you have the following available:"
    echo -e "- The 'age-key.txt' file (from your backup)"
    echo -e "- The 'secrets.yaml' file (if restoring full config)"
    echo -e "- Your Cloudflare API Tokens (if rebuilding server)"
    echo -e ""

    log_info "Available backups for restoration:"
    echo ""

    if ! list_backups; then
        log_error "No backups found for restoration"
        return 1
    fi

    echo ""
    read -p "Enter the full filename of the backup to restore (or 'quit' to exit): " selected_file

    if [[ "$selected_file" == "quit" ]] || [[ -z "$selected_file" ]]; then
        log_info "Restore cancelled by user"
        exit 0
    fi

    local backup_found=false
    local backup_types=("db" "full" "emergency")

    for backup_type in "${backup_types[@]}"; do
        local backup_path="$PROJECT_ROOT/backups/$backup_type/$selected_file"
        if [[ -f "$backup_path" ]]; then
            BACKUP_FILE="$backup_path"
            RESTORE_TYPE="$backup_type"
            backup_found=true
            break
        fi
    done

    if [[ "$backup_found" != "true" ]]; then
        log_error "Backup file not found: $selected_file"
        return 1
    fi

    log_info "Selected backup: $(basename "$BACKUP_FILE")"
    log_info "Restore type: $RESTORE_TYPE"

    if [[ -f "$BACKUP_FILE.meta" ]]; then
        echo ""
        log_info "Backup metadata:"
        while IFS= read -r line; do
            [[ "$line" =~ ^[a-zA-Z_]+=.*$ ]] && echo "  $line"
        done < "$BACKUP_FILE.meta"
        echo ""
    fi

    if [[ "$FORCE_RESTORE" != "true" ]]; then
        read -p "Continue with restore? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            log_info "Restore cancelled by user"
            exit 0
        fi
    fi

    return 0
}

# Backup file resolution - returns exit code
resolve_backup_file() {
    if [[ -n "$BACKUP_FILE" ]]; then
        if [[ ! -f "$BACKUP_FILE" ]]; then
            log_error "Specified backup file not found: $BACKUP_FILE"
            return 1
        fi

        if [[ -z "$RESTORE_TYPE" ]]; then
            if   [[ "$BACKUP_FILE" =~ /db/        ]]; then RESTORE_TYPE="db"
            elif [[ "$BACKUP_FILE" =~ /full/      ]]; then RESTORE_TYPE="full"
            elif [[ "$BACKUP_FILE" =~ /emergency/ ]]; then RESTORE_TYPE="emergency"
            else
                log_error "Cannot determine backup type from file path: $BACKUP_FILE"
                return 1
            fi
        fi
    elif [[ -n "$RESTORE_TYPE" ]]; then
        local backup_dir="$PROJECT_ROOT/backups/$RESTORE_TYPE"
        if [[ ! -d "$backup_dir" ]]; then
            log_error "No backups found for type: $RESTORE_TYPE"
            return 1
        fi

        BACKUP_FILE=$(find "$backup_dir" -name "*.age" -type f | sort | tail -1)
        if [[ -z "$BACKUP_FILE" ]]; then
            log_error "No backup files found in: $backup_dir"
            return 1
        fi

        log_info "Using latest $RESTORE_TYPE backup: $(basename "$BACKUP_FILE")"
    else
        if ! select_backup_interactively; then
            return 1
        fi
    fi

    return 0
}

# Pre-restore backup creation - returns exit code
create_restore_point_backup() {
    if [[ "$CREATE_RESTORE_BACKUP" != "true" ]]; then
        log_info "Skipping restore point backup (--no-backup specified)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create restore point backup"
        return 0
    fi

    log_info "Creating restore point backup for safety..."

    # FIX [ITEM 4]: Pass only --type emergency.  The original code passed
    # --email=false which backup.sh does not understand (it expects --email as
    # a bare boolean flag), causing the restore-point backup to abort with
    # "Unknown option" and taking the entire restore with it.
    if ./backup.sh --type emergency; then
        log_success "Restore point backup completed"
        return 0
    else
        log_error "Restore point backup failed"
        return 1
    fi
}

# Service preparation for restore - returns exit code
prepare_services_for_restore() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would stop services for restoration"
        return 0
    fi

    log_info "Stopping services for restoration..."

    if stop_services; then
        log_success "Services stopped successfully"
        return 0
    else
        log_error "Failed to stop services"
        return 1
    fi
}

# Database restore - returns exit code
restore_database() {
    if [[ "$RESTORE_TYPE" != "db" ]]; then
        return 0  # Not a database restore
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would restore database from: $(basename "$BACKUP_FILE")"
        return 0
    fi

    log_info "Restoring database from: $(basename "$BACKUP_FILE")"

    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")

    # FIX [ITEM 3]: Correct destination path.
    # backup.sh sources the DB from  $state_dir/data/db.sqlite3
    # so we must restore it to the identical path, NOT data/bwdata/db.sqlite3.
    local db_dir="$state_dir/data"
    local db_path="$db_dir/db.sqlite3"

    if ! ensure_dir "$db_dir" 700; then
        log_error "Failed to create database directory"
        return 1
    fi

    # FIX [ITEM 1]: Decrypt and fully verify the incoming backup FIRST.
    # Only after both steps pass do we touch the live database.
    # This guarantees the live DB is never removed when decryption fails
    # (e.g. wrong key, corrupted archive, WAN issue).
    local temp_db
    temp_db=$(mktemp)

    log_info "Decrypting and decompressing backup (live DB untouched until verified)..."
    if ! age -d -i "$SOPS_AGE_KEY_FILE" "$BACKUP_FILE" | gzip -d > "$temp_db"; then
        log_error "Failed to decrypt/decompress database backup. Live database is untouched."
        rm -f "$temp_db"
        return 1
    fi

    log_info "Verifying integrity of decrypted database..."
    if ! sqlite3 "$temp_db" "PRAGMA integrity_check;" | grep -qx "ok"; then
        log_error "Decrypted database failed integrity check. Live database is untouched."
        rm -f "$temp_db"
        return 1
    fi

    # Both checks passed — now it is safe to swap the live database.
    if [[ -f "$db_path" ]]; then
        local backup_db="$db_path.pre-restore-$(date +%Y%m%d-%H%M%S)"
        if ! mv "$db_path" "$backup_db"; then
            log_error "Failed to move existing database to safety"
            rm -f "$temp_db"
            return 1
        fi
        log_info "Existing database preserved at: $(basename "$backup_db")"
    fi

    if ! mv "$temp_db" "$db_path"; then
        log_error "Failed to move restored database into place"
        rm -f "$temp_db"
        return 1
    fi

    # Set proper ownership and permissions
    local real_user real_group
    real_user=$(get_real_user)
    real_group=$(id -g -n "$real_user")

    if ! chown "$real_user:$real_group" "$db_path" || ! chmod 644 "$db_path"; then
        log_error "Failed to set database permissions"
        return 1
    fi

    log_success "Database restored successfully"
    return 0
}

# Full/Emergency archive restore - returns exit code
restore_archive() {
    if [[ "$RESTORE_TYPE" != "full" && "$RESTORE_TYPE" != "emergency" ]]; then
        return 0  # Not an archive restore
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would restore $RESTORE_TYPE archive from: $(basename "$BACKUP_FILE")"
        return 0
    fi

    log_info "Restoring $RESTORE_TYPE archive from: $(basename "$BACKUP_FILE")"

    local temp_dir
    temp_dir=$(mktemp -d)
    # FIX [ITEM 8]: Register with the global cleanup registry instead of
    # overwriting the EXIT trap, which would silently drop any trap set by
    # the sourced libraries or by main().
    register_cleanup_dir "$temp_dir"

    # Decrypt and extract archive
    if ! age -d -i "$SOPS_AGE_KEY_FILE" "$BACKUP_FILE" | tar -xzf - -C "$temp_dir"; then
        log_error "Failed to decrypt and extract archive"
        return 1
    fi

    # Restore configuration files
    log_info "Restoring configuration files..."
    local config_files=("docker-compose.yml" ".env")

    for config_file in "${config_files[@]}"; do
        if [[ -f "$temp_dir/$config_file" ]]; then
            if [[ -f "$PROJECT_ROOT/$config_file" ]]; then
                local backup_config="$PROJECT_ROOT/$config_file.pre-restore-$(date +%Y%m%d-%H%M%S)"
                if ! mv "$PROJECT_ROOT/$config_file" "$backup_config"; then
                    log_warn "Failed to backup existing $config_file"
                fi
            fi

            if ! cp "$temp_dir/$config_file" "$PROJECT_ROOT/"; then
                log_error "Failed to restore $config_file"
                return 1
            fi

            log_info "Restored: $config_file"
        fi
    done

    # Restore caddy and fail2ban configurations
    local config_dirs=("caddy" "fail2ban")

    for config_dir in "${config_dirs[@]}"; do
        if [[ -d "$temp_dir/$config_dir" ]]; then
            if [[ -d "$PROJECT_ROOT/$config_dir" ]]; then
                local backup_dir="$PROJECT_ROOT/$config_dir.pre-restore-$(date +%Y%m%d-%H%M%S)"
                if ! mv "$PROJECT_ROOT/$config_dir" "$backup_dir"; then
                    log_warn "Failed to backup existing $config_dir"
                fi
            fi

            if ! cp -r "$temp_dir/$config_dir" "$PROJECT_ROOT/"; then
                log_error "Failed to restore $config_dir"
                return 1
            fi

            log_info "Restored: $config_dir/"
        fi
    done

    # Restore data directory
    if [[ -d "$temp_dir/data" ]]; then
        log_info "Restoring data directory..."

        local state_dir
        state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")

        if [[ -d "$state_dir/data" ]]; then
            local backup_data="$state_dir/data.pre-restore-$(date +%Y%m%d-%H%M%S)"
            if ! mv "$state_dir/data" "$backup_data"; then
                log_warn "Failed to backup existing data directory"
            fi
        fi

        if ! ensure_dir "$(dirname "$state_dir/data")" 755; then
            log_error "Failed to create parent directory for data"
            return 1
        fi

        if ! cp -r "$temp_dir/data" "$state_dir/"; then
            log_error "Failed to restore data directory"
            return 1
        fi

        local real_user real_group
        real_user=$(get_real_user)
        real_group=$(id -g -n "$real_user")

        if ! chown -R "$real_user:$real_group" "$state_dir/data"; then
            log_error "Failed to set data directory ownership"
            return 1
        fi

        log_success "Data directory restored successfully"
    fi

    # Restore secrets (emergency restore only)
    if [[ "$RESTORE_TYPE" == "emergency" ]] && [[ -d "$temp_dir/secrets" ]]; then
        log_info "Restoring secrets (emergency restore)..."

        if [[ -d "$PROJECT_ROOT/secrets" ]]; then
            local backup_secrets="$PROJECT_ROOT/secrets.pre-restore-$(date +%Y%m%d-%H%M%S)"
            if ! mv "$PROJECT_ROOT/secrets" "$backup_secrets"; then
                log_warn "Failed to backup existing secrets"
            fi
        fi

        if ! cp -r "$temp_dir/secrets" "$PROJECT_ROOT/"; then
            log_error "Failed to restore secrets directory"
            return 1
        fi

        if ! chmod -R 700 "$PROJECT_ROOT/secrets"; then
            log_error "Failed to set secrets permissions"
            return 1
        fi

        log_success "Secrets restored successfully"
    fi

    log_success "$RESTORE_TYPE archive restored successfully"
    return 0
}

# Post-restore service startup - returns exit code
start_services_after_restore() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would start services after restoration"
        return 0
    fi

    log_info "Starting services after restoration..."

    if ./startup.sh --force-restart; then
        log_success "Services started successfully after restore"
        return 0
    else
        log_error "Failed to start services after restore"
        return 1
    fi
}

# Post-restore health validation - returns exit code
validate_restore_health() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would validate system health after restoration"
        return 0
    fi

    log_info "Validating system health after restoration..."

    # FIX [ITEM 10]: Replace the hard-coded sleep 45 with a polling retry loop.
    # Polls every 5 seconds for up to 10 attempts (50 s max) and exits as soon
    # as health.sh reports success, minimising unnecessary wait time.
    local max_attempts=10
    local interval=5
    local attempt=1

    while (( attempt <= max_attempts )); do
        log_info "Health check attempt $attempt/$max_attempts (waiting ${interval}s)..."
        sleep "$interval"

        if ./health.sh --comprehensive --quiet; then
            log_success "Post-restore health validation passed (attempt $attempt)"
            return 0
        fi

        (( attempt++ )) || true
    done

    log_error "Post-restore health validation failed after $max_attempts attempts"
    return 1
}

# Restore summary generation - returns exit code
generate_restore_summary() {
    local backup_verification="$1"
    local restore_backup="$2"
    local services_stop="$3"
    local restore_operation="$4"
    local services_start="$5"
    local health_validation="$6"

    log_info "Generating restore summary..."

    local summary="VaultWarden Restore Summary - $(date)\n"
    summary+="\nRestore Details:\n"
    summary+="  Backup File: $(basename "$BACKUP_FILE")\n"
    summary+="  Restore Type: $RESTORE_TYPE\n"
    summary+="\nRestore Results:\n"

    if [[ "$SKIP_VERIFICATION" == "true" ]]; then
        summary+="  ⏭️  Backup verification: Skipped\n"
    elif [[ "$backup_verification" == "0" ]]; then
        summary+="  ✅ Backup verification: Passed\n"
    else
        summary+="  ❌ Backup verification: Failed\n"
    fi

    if [[ "$CREATE_RESTORE_BACKUP" == "true" ]]; then
        if [[ "$restore_backup" == "0" ]]; then
            summary+="  ✅ Restore point backup: Created successfully\n"
        else
            summary+="  ❌ Restore point backup: Failed\n"
        fi
    else
        summary+="  ⏭️  Restore point backup: Skipped\n"
    fi

    if [[ "$services_stop" == "0" ]]; then
        summary+="  ✅ Service stop: Completed successfully\n"
    else
        summary+="  ❌ Service stop: Failed\n"
    fi

    if [[ "$restore_operation" == "0" ]]; then
        summary+="  ✅ Data restoration: Completed successfully\n"
    else
        summary+="  ❌ Data restoration: Failed\n"
    fi

    if [[ "$services_start" == "0" ]]; then
        summary+="  ✅ Service restart: Completed successfully\n"
    else
        summary+="  ❌ Service restart: Failed\n"
    fi

    if [[ "$health_validation" == "0" ]]; then
        summary+="  ✅ Health validation: Passed\n"
    else
        summary+="  ❌ Health validation: Issues detected\n"
    fi

    if [[ "$restore_operation" == "0" && "$services_start" == "0" && "$health_validation" == "0" ]]; then
        summary+="\n🎉 Overall Status: RESTORE SUCCESSFUL\n"
        summary+="\nNext Steps:\n"
        summary+="  • Monitor services for stability\n"
        summary+="  • Verify data integrity\n"
        summary+="  • Update any changed configurations\n"
    else
        summary+="\n⚠️  Overall Status: RESTORE COMPLETED WITH ISSUES\n"
        summary+="\nImmediate Actions Required:\n"
        summary+="  • Check service logs: make logs\n"
        summary+="  • Run health check: ./health.sh --comprehensive\n"
        summary+="  • Consider rollback if issues persist\n"
    fi

    echo -e "$summary"
    return 0
}

# Main function with proper error handling and exit strategy
main() {
    log_header "VaultWarden-OCI Restore Manager"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    if ! load_env_file; then
        log_error "Failed to load configuration"
        exit 1
    fi

    export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-"$PROJECT_ROOT/secrets/keys/age-key.txt"}"

    if [[ ! -f "$SOPS_AGE_KEY_FILE" ]]; then
        log_error "Age key file not found: $SOPS_AGE_KEY_FILE"
        log_info "Cannot decrypt backups without the Age key"
        exit 1
    fi

    # Track restoration results
    local backup_verification_result=1
    local restore_backup_result=1
    local services_stop_result=1
    local restore_operation_result=1
    local services_start_result=1
    local health_validation_result=1

    # Phase 1: Preparation and validation
    log_info "=== Phase 1: Restore Preparation ==="

    if ! resolve_backup_file; then
        exit 1
    fi

    if [[ "$SKIP_VERIFICATION" != "true" ]]; then
        if validate_backup_integrity "$BACKUP_FILE"; then
            backup_verification_result=0
        else
            log_error "Backup integrity validation failed - aborting restore"
            exit 1
        fi
    fi

    if create_restore_point_backup; then
        restore_backup_result=0
    else
        log_error "Failed to create restore point backup - aborting for safety"
        exit 1
    fi

    # Phase 2: Service preparation
    log_info "=== Phase 2: Service Preparation ==="

    if prepare_services_for_restore; then
        services_stop_result=0
    else
        log_error "Failed to prepare services for restore"
        exit 1
    fi

    # Phase 3: Data restoration
    log_info "=== Phase 3: Data Restoration ==="

    local restore_success=true

    if ! restore_database; then
        restore_success=false
    fi

    if ! restore_archive; then
        restore_success=false
    fi

    if [[ "$restore_success" == "true" ]]; then
        restore_operation_result=0
    else
        log_error "Data restoration failed"
        # Don't exit here - attempt to bring services back up
    fi

    # Phase 4: Service restart and validation
    log_info "=== Phase 4: Service Restart and Validation ==="

    if start_services_after_restore; then
        services_start_result=0
    else
        log_error "Failed to start services after restore"
    fi

    if [[ "$services_start_result" == "0" ]]; then
        if validate_restore_health; then
            health_validation_result=0
        else
            log_error "Post-restore health validation failed"
        fi
    fi

    # Phase 5: Summary and results
    log_info "=== Phase 5: Restore Summary ==="

    generate_restore_summary \
        "$backup_verification_result" \
        "$restore_backup_result" \
        "$services_stop_result" \
        "$restore_operation_result" \
        "$services_start_result" \
        "$health_validation_result"

    if [[ "$restore_operation_result" == "0" && "$services_start_result" == "0" && "$health_validation_result" == "0" ]]; then
        log_success "Restore completed successfully"
        exit 0
    elif [[ "$restore_operation_result" == "0" && "$services_start_result" == "0" ]]; then
        log_warn "Restore completed but health check shows issues"
        exit 2  # Warning exit code
    else
        log_error "Restore completed with critical failures"
        exit 1
    fi
}

main "$@"
