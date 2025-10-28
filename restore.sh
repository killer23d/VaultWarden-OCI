#!/usr/bin/env bash
# restore.sh - Simplified VaultWarden restore with verification mode integration

set -euo pipefail

# --- Project Root Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# --- Source Libraries ---
source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh"
source "lib/backup_utils.sh"

# --- Configuration ---
RESTORE_TYPE="auto"  # auto, db, full, emergency
BACKUP_FILE=""
FORCE=false
DRY_RUN=false
INTERACTIVE_MODE=false

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden-OCI-NG Restore Tool

USAGE:
    ./restore.sh [OPTIONS] [BACKUP_FILE]
    ./restore.sh --interactive

OPTIONS:
    BACKUP_FILE      Path to the encrypted backup file (.age) to restore
    --interactive    Show a list of backups and prompt for selection (default if no file given)
    --type TYPE      Restore type: auto, db, full, emergency (default: auto if file given)
    --force          Skip confirmation prompts (use with extreme caution!)
    --dry-run        Show what would be done without executing
    --help           Show this help

RESTORE TYPES:
    auto        Detect backup type automatically from filename (requires BACKUP_FILE)
    db          Database restore only
    full        Full system restore (config + data)
    emergency   Emergency kit restoration (complete system replacement)

VERIFICATION:
    Uses BACKUP_VERIFICATION_MODE from .env:
      - quick_check       Fast structural check
      - integrity_check   Thorough full-page scan
    Default is quick_check when unset.

EXAMPLES:
    ./restore.sh backups/db/vw-db-backup-....age   # Restore specific file (auto-detect type)
    ./restore.sh --interactive                     # Select backup from a list
    make restore                                   # Alias for interactive restore
    ./restore.sh --type db db-backup.age           # Force database restore type
    ./restore.sh --force emergency-kit.age         # Force emergency restore without prompts
EOF
}

# --- Parse --interactive first to shape argv ---
for arg in "$@"; do
    if [[ "$arg" == "--interactive" ]]; then
        INTERACTIVE_MODE=true
        new_args=()
        for a in "$@"; do [[ "$a" != "--interactive" ]] && new_args+=("$a"); done
        set -- "${new_args[@]}"
        break
    fi
done

# --- Parse remaining options ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --type) RESTORE_TYPE="$2"; shift 2 ;;
        --force) FORCE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) show_help; exit 0 ;;
        --) shift; break ;;
        -*) log_error "Unknown option: $1"; show_help; exit 1 ;;
        *)  if [[ -z "$BACKUP_FILE" ]]; then BACKUP_FILE="$1"; else log_error "Multiple backup files specified."; show_help; exit 1; fi; shift ;;
    esac
done

# If no backup file provided, default to interactive mode
if [[ -z "$BACKUP_FILE" ]]; then
    INTERACTIVE_MODE=true
fi

# --- Interactive Selection (using lib/backup_utils.sh) ---
select_backup_interactive() {
    if ! list_backups; then  # Using function from lib/backup_utils.sh
        return 1
    fi
    local selection max_option
    max_option=$((${#BACKUP_LIST_DETAILS[@]}))
    while true; do
        read -p "Enter the ID number of the backup to restore (1-$max_option) or 'q' to quit: " selection
        if [[ "$selection" =~ ^[qQ]$ ]]; then log_info "Restore cancelled."; return 1; fi
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le "$max_option" ]]; then
            BACKUP_FILE="${BACKUP_LIST_DETAILS[$selection]}"
            log_success "Selected backup: $(basename "$BACKUP_FILE")"
            return 0
        else
            log_error "Invalid selection. Enter 1-$max_option or 'q'."
        fi
    done
}

# --- Validation ---
validate_environment() {
    require_commands age tar gzip chown sqlite3 || return 1
    require_docker || return 1
    if ! check_age_key; then log_error "Age key not available"; return 1; fi
    if [[ "$INTERACTIVE_MODE" == "false" ]]; then
        if [[ -z "$BACKUP_FILE" ]]; then log_error "No backup file specified"; return 1; fi
        if [[ ! -f "$BACKUP_FILE" ]]; then log_error "Backup file not found: $BACKUP_FILE"; return 1; fi
    fi
    return 0
}

# --- Auto-detect backup type ---
detect_backup_type() {
    if [[ -z "$BACKUP_FILE" || ! -f "$BACKUP_FILE" ]]; then log_error "Cannot detect type: Backup file missing."; return 1; fi
    local filename=$(basename "$BACKUP_FILE")

    case "$filename" in
        *emergency*|*kit*) echo "emergency" ;;
        *full*) echo "full" ;;
        *db*|*database*|*.sqlite3*) echo "db" ;;
        *)
            log_info "Attempting content auto-detection..."
            local temp_peek; temp_peek=$(mktemp)
            setup_cleanup_trap "rm -f '$temp_peek'"
            if decrypt_file "$BACKUP_FILE" "$temp_peek"; then
                if file "$temp_peek" | grep -q 'gzip compressed data'; then
                    echo "db"
                elif tar -tf "$temp_peek" > /dev/null 2>&1; then
                    if tar -tf "$temp_peek" | grep -qE "(RECOVERY\.md|kit-info\.txt)"; then echo "emergency"
                    elif tar -tf "$temp_peek" | grep -qE "(\.env|docker-compose\.yml)"; then echo "full"
                    else echo "full"; fi
                else
                    echo "db"
                fi
                rm -f "$temp_peek"
            else
                log_warn "Could not decrypt to detect type."
                rm -f "$temp_peek"; return 1
            fi
            ;;
    esac
}

# --- Confirmation ---
confirm_restore() {
    local restore_type="$1"
    if [[ -z "$BACKUP_FILE" || ! -f "$BACKUP_FILE" ]]; then log_error "Cannot confirm: Backup missing."; return 1; fi
    if [[ "$FORCE" == "true" || "$DRY_RUN" == "true" ]]; then return 0; fi

    echo ""
    log_warn "⚠️  DESTRUCTIVE OPERATION WARNING ⚠️"
    echo ""
    echo "Restore Details:"
    echo "  Type: $restore_type"
    echo "  File: $(basename "$BACKUP_FILE")"
    echo "  Path: $BACKUP_FILE"
    echo "  Size: $(du -h "$BACKUP_FILE" | cut -f1)"
    echo "  Date: $(date -r "$BACKUP_FILE" '+%Y-%m-%d %H:%M:%S %Z')"
    echo ""

    case "$restore_type" in
        "db") echo "This will replace the current database with data from the backup."; echo "⚠️ Data created after the backup date will be lost!";;
        "full") echo "This will replace config files and data with content from the backup."; echo "⚠️ Config/data created after the backup date will be lost!";;
        "emergency") echo "This performs a complete system replacement from the kit."; echo "⚠️ ALL current config/data will be lost!";;
    esac

    echo ""
    read -p "Are you absolutely sure? (type 'yes' to confirm): " confirmation
    if [[ "$confirmation" != "yes" ]]; then log_info "Restore cancelled."; exit 1; fi
    echo ""
    return 0
}

# --- Verification Helpers ---
get_verification_mode() {
    local mode
    mode=$(get_config_value "BACKUP_VERIFICATION_MODE" "quick_check")
    case "$mode" in
        quick_check|integrity_check) echo "$mode" ;;
        *) echo "quick_check" ;;
    esac
}

verify_restored_db() {
    local db_file="$1"
    local mode; mode=$(get_verification_mode)
    log_info "Verifying restored database with: $mode"
    local result
    case "$mode" in
        quick_check)     result=$(sqlite3 "$db_file" "PRAGMA quick_check;" 2>/dev/null || true) ;;
        integrity_check) result=$(sqlite3 "$db_file" "PRAGMA integrity_check;" 2>/dev/null || true) ;;
    esac
    if [[ "$result" == "ok" ]]; then
        log_success "Database $mode passed"
        return 0
    else
        log_error "Database $mode FAILED: ${result:-no output}"
        return 1
    fi
}

# --- Database Restore ---
restore_database() {
    log_info "Starting database restore from: $(basename "$BACKUP_FILE")"
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would restore database."; return 0; fi

    log_info "Stopping VaultWarden service..."
    stop_services "vaultwarden" || log_warn "VaultWarden may not have been running"
    sleep 3

    local state_dir db_file db_dir backup_db_file
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    db_dir="$state_dir/data/bwdata"; db_file="$db_dir/db.sqlite3"
    backup_db_file="$db_file.backup-$(date +%Y%m%d-%H%M%S)"

    if [[ -f "$db_file" ]]; then
        log_info "Backing up current database to $backup_db_file..."
        cp "$db_file" "$backup_db_file" || { log_error "Failed to back up current database"; start_services "vaultwarden"; return 1; }
    fi

    local real_user real_group owner; real_user=$(get_real_user); real_group=$(id -g -n "$real_user") || real_group="$real_user"; owner="$real_user:$real_group"
    ensure_dir "$db_dir" 700 "$owner"

    log_info "Restoring database from backup..."
    if decrypt_file "$BACKUP_FILE" | gunzip > "$db_file"; then
        log_success "DB file restored"
        chown "$owner" "$db_file" || log_warn "Failed to set ownership"
        secure_file "$db_file" 600 || { log_error "Failed to set DB permissions"; start_services "vaultwarden"; return 1; }

        # Use configured verification mode
        if verify_restored_db "$db_file"; then
            log_success "Post-restore verification passed"
        else
            log_error "Post-restore verification FAILED; attempting rollback"
            [[ -f "$backup_db_file" ]] && mv "$backup_db_file" "$db_file"
            start_services "vaultwarden"
            return 1
        fi

        log_info "Starting VaultWarden service..."
        if start_services "vaultwarden"; then
            log_success "Service started"
            if wait_for_service_ready "vaultwarden" 30; then
                log_success "DB restore complete"
                [[ -f "$backup_db_file" ]] && log_info "Previous DB retained at: $backup_db_file"
            else
                log_error "Service failed health check post-restore"
                return 1
            fi
        else
            log_error "Failed to start VaultWarden"
            return 1
        fi
    else
        log_error "Failed decryption/restore"
        [[ -f "$backup_db_file" ]] && mv "$backup_db_file" "$db_file"
        start_services "vaultwarden"
        return 1
    fi
    return 0
}

# --- Full System Restore ---
restore_full_system() {
    log_info "Starting full system restore from: $(basename "$BACKUP_FILE")"
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would restore full system."; return 0; fi

    local real_user real_group owner; real_user=$(get_real_user); real_group=$(id -g -n "$real_user") || real_group="$real_user"; owner="$real_user:$real_group"

    log_info "Stopping all services..."
    stop_services || log_warn "Services may not have been running"
    sleep 3

    local temp_dir; temp_dir=$(mktemp -d); setup_cleanup_trap "rm -rf '$temp_dir'"
    log_info "Decrypting backup archive..."
    if ! decrypt_file "$BACKUP_FILE" | tar -xzf - -C "$temp_dir"; then
        log_error "Failed to extract backup archive"
        start_services
        return 1
    fi

    local backup_suffix="pre-restore-$(date +%Y%m%d-%H%M%S)"
    log_info "Backing up current configuration..."
    [[ -f .env ]] && cp .env ".env.$backup_suffix" || true
    [[ -f docker-compose.yml ]] && cp docker-compose.yml "docker-compose.yml.$backup_suffix" || true
    [[ -d secrets ]] && cp -a secrets "secrets.$backup_suffix" || true
    [[ -d caddy ]] && cp -a caddy "caddy.$backup_suffix" || true
    [[ -d fail2ban ]] && cp -a fail2ban "fail2ban.$backup_suffix" || true

    log_info "Restoring configuration files..."
    rsync -a --delete "$temp_dir/" . || log_warn "Copy errors occurred"

    local state_dir; state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    if [[ -d "$temp_dir/data" ]]; then
        log_info "Restoring data directory to $state_dir/data..."
        ensure_dir "$state_dir" 755 "$owner"
        if [[ -d "$state_dir/data" ]]; then
            log_info "Backing up current data dir..."
            mv "$state_dir/data" "$state_dir/data.$backup_suffix" || { log_error "Failed to back up data dir"; start_services; return 1; }
        fi
        if [[ -d "./data" ]]; then
            mv "./data" "$state_dir/" || { log_error "Failed to move restored data"; start_services; return 1; }
        else
            log_warn "No data dir found in backup"
        fi
    else
        log_warn "No data dir in backup"
    fi

    log_info "Setting ownership/permissions..."
    chown -R "$owner" . || log_warn "Project ownership issue"
    [[ -d "$state_dir/data" ]] && chown -R "$owner" "$state_dir/data" || log_warn "Data ownership issue"
    [[ -f .env ]] && secure_file .env 600 || true
    [[ -f secrets/secrets.yaml ]] && secure_file secrets/secrets.yaml 600 || true
    [[ -f secrets/keys/age-key.txt ]] && secure_file secrets/keys/age-key.txt 600 || true
    [[ -d "$state_dir/data" ]] && chmod 700 "$state_dir/data" || true
    [[ -f "$state_dir/data/bwdata/db.sqlite3" ]] && secure_file "$state_dir/data/bwdata/db.sqlite3" 600 || true

    # Optional: verify DB if present
    if [[ -f "$state_dir/data/bwdata/db.sqlite3" ]]; then
        if verify_restored_db "$state_dir/data/bwdata/db.sqlite3"; then
            log_success "Database in full restore verified"
        else
            log_warn "Database verification failed after full restore"
        fi
    fi

    log_info "Starting services..."
    if start_services; then
        log_info "Waiting for services to become ready..."
        sleep 10
        local failed_services=()
        for service in vaultwarden caddy; do
            if ! wait_for_service_ready "$service" 45; then failed_services+=("$service"); fi
        done
        if [[ ${#failed_services[@]} -eq 0 ]]; then
            log_success "Full restore complete"
        else
            log_error "Service failures: ${failed_services[*]}. Backups saved with suffix: .$backup_suffix"
            return 1
        fi
    else
        log_error "Failed to start services. Backups saved with suffix: .$backup_suffix"
        return 1
    fi
    return 0
}

# --- Emergency Kit Restore ---
restore_emergency_kit() {
    log_info "Starting emergency kit restore from: $(basename "$BACKUP_FILE")"
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would restore emergency kit."; return 0; fi

    local real_user real_group owner; real_user=$(get_real_user); real_group=$(id -g -n "$real_user") || real_group="$real_user"; owner="$real_user:$real_group"
    local temp_dir; temp_dir=$(mktemp -d); setup_cleanup_trap "rm -rf '$temp_dir'"

    log_info "Decrypting kit..."
    if ! decrypt_file "$BACKUP_FILE" | tar -xzf - -C "$temp_dir"; then
        log_error "Failed to extract kit"
        return 1
    fi

    [[ -f "$temp_dir/RECOVERY.md" ]] && log_info "Recovery notes found. Saving as RECOVERY.md." && cp "$temp_dir/RECOVERY.md" .
    [[ -f "$temp_dir/kit-info.txt" ]] && log_info "Kit info:" && cat "$temp_dir/kit-info.txt"; echo ""

    log_info "Stopping all services..."
    stop_services || true
    sleep 3

    local backup_suffix="emergency-restore-backup-$(date +%Y%m%d-%H%M%S)"
    log_info "Creating emergency backup of current state: ./emergency-backups/$backup_suffix/"
    ensure_dir "emergency-backups/$backup_suffix" 755 "$owner"
    rsync -a --delete --exclude 'emergency-backups/' . "emergency-backups/$backup_suffix/" || log_warn "Could not fully back up current state"

    log_info "Restoring complete system from kit..."
    rsync -a --delete "$temp_dir/" . || log_warn "Copy errors occurred"

    local state_dir; state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    if [[ -d "./data" ]]; then
        log_info "Moving restored data to $state_dir/data..."
        ensure_dir "$state_dir" 755 "$owner"
        rm -rf "$state_dir/data" 2>/dev/null || true
        mv "./data" "$state_dir/" || { log_error "Failed to move restored data"; return 1; }
    else
        log_warn "No data dir in kit"
    fi

    log_info "Setting ownership/permissions..."
    chown -R "$owner" . || log_warn "Project ownership error"
    [[ -d "$state_dir/data" ]] && chown -R "$owner" "$state_dir/data" || log_warn "Data ownership error"
    [[ -f .env ]] && secure_file .env 600 || true
    [[ -f secrets/secrets.yaml ]] && secure_file secrets/secrets.yaml 600 || true
    [[ -f secrets/keys/age-key.txt ]] && secure_file secrets/keys/age-key.txt 600 || true
    [[ -d "$state_dir/data" ]] && chmod 700 "$state_dir/data" || true
    [[ -f "$state_dir/data/bwdata/db.sqlite3" ]] && secure_file "$state_dir/data/bwdata/db.sqlite3" 600 || true

    # Optional: verify DB if present
    if [[ -f "$state_dir/data/bwdata/db.sqlite3" ]]; then
        if verify_restored_db "$state_dir/data/bwdata/db.sqlite3"; then
            log_success "Database in emergency restore verified"
        else
            log_warn "Database verification failed after emergency restore"
        fi
    fi

    log_info "Starting restored services..."
    if start_services; then
        log_info "Waiting for services..."
        sleep 15
        local ready_services=0
        for service in vaultwarden caddy; do
            if wait_for_service_ready "$service" 60; then ((ready_services++)); fi
        done
        if [[ $ready_services -eq 2 ]]; then
            log_success "Emergency restore complete"
            echo ""
            log_info "Verify functionality & DNS."
        else
            log_error "Service failures post-restore. Backup at: ./emergency-backups/$backup_suffix/"
            return 1
        fi
    else
        log_error "Failed to start services. Backup at: ./emergency-backups/$backup_suffix/"
        return 1
    fi
    return 0
}

# --- Main ---
main() {
    log_info "VaultWarden Restore Tool"
    validate_environment || exit 1

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        if ! select_backup_interactive; then exit 1; fi
    elif [[ -z "$BACKUP_FILE" ]]; then
        log_error "No backup specified."
        show_help
        exit 1
    elif [[ ! -f "$BACKUP_FILE" ]]; then
        log_error "Backup file not found: $BACKUP_FILE"
        exit 1
    fi

    if [[ "$RESTORE_TYPE" == "auto" ]]; then
        RESTORE_TYPE=$(detect_backup_type) || exit 1
        log_info "Auto-detected backup type: $RESTORE_TYPE"
    fi

    confirm_restore "$RESTORE_TYPE" || exit 1

    load_env_file 2>/dev/null || log_warn "No .env file (may be restored)"

    case "$RESTORE_TYPE" in
        "db")        restore_database || exit 1 ;;
        "full")      restore_full_system || exit 1 ;;
        "emergency") restore_emergency_kit || exit 1 ;;
        *)           log_error "Invalid restore type: $RESTORE_TYPE"; exit 1 ;;
    esac

    load_env_file 2>/dev/null || true
    local domain; domain=$(get_config_value "DOMAIN" "your-domain")

    echo ""
    log_success "Restore operation completed successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Verify health: ./health.sh (or make health)"
    echo "  2. Test web access: https://$domain"
    echo "  3. Check admin panel"
    echo "  4. Create new backup: ./backup.sh (or make backup-full)"
}

# Declare the global associative array that lib/backup_utils.sh uses
declare -A BACKUP_LIST_DETAILS=()
main "$@"
