#!/usr/bin/env bash
# backup.sh - Simplified VaultWarden backup creation with enhanced verification
# MODIFIED: Re-architected all backup types to use a single, verified snapshot, fixing race conditions.
# MODIFIED: Corrected container-to-host pathing for database snapshots.

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
BACKUP_TYPE="db"
EMAIL_NOTIFY=false
RCLONE_SYNC=false
LIST_BACKUPS=false

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden-OCI-NG Backup Tool with Enhanced Verification

USAGE:
  ./backup.sh
  ./backup.sh --list

OPTIONS:
    --type TYPE      Backup type: db, full, or emergency (default: db)
    --rclone         Sync backup to rclone remote after creation
    --email          Send email notification on completion
    --help           Show this help
    --list           List available local backups

VERIFICATION:
    - All backup types use a single-snapshot method for atomic verification.
    - Uses BACKUP_VERIFICATION_MODE from .env (quick_check or integrity_check).
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --type)
            if [[ ${2-} == "" ]]; then
                log_error "Missing value for --type"
                exit 1
            fi
            BACKUP_TYPE="$2"
            shift 2
            ;;
        --email)  EMAIL_NOTIFY=true; shift ;;
        --rclone) RCLONE_SYNC=true; shift ;;
        --list)   LIST_BACKUPS=true; shift ;;
        --help)   show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Verification Functions ---
get_verification_mode() {
    local mode
    mode=$(get_config_value "BACKUP_VERIFICATION_MODE" "quick_check")
    case "$mode" in
        quick_check|integrity_check) echo "$mode" ;;
        *) echo "quick_check" ;;
    esac
}

verify_sqlite_integrity() {
    local db_file="$1"
    local verification_mode="${2:-quick_check}"

    if [[ ! -f "$db_file" ]]; then
        log_error "Database file not found for verification: $db_file"
        return 1
    fi

    log_info "Running SQLite $verification_mode and optimize on database..."
    local check_result

    case "$verification_mode" in
        quick_check)
            if ! check_result="$(sqlite3 "$db_file" "PRAGMA quick_check;" 2>/dev/null)"; then
                return 1
            fi
            ;;
        integrity_check)
            if ! check_result="$(sqlite3 "$db_file" "PRAGMA integrity_check;" 2>/dev/null)"; then
                return 1
            fi
            ;;
        *)
            log_error "Unknown verification mode: $verification_mode"
            return 1
            ;;
    esac

    sqlite3 "$db_file" "PRAGMA optimize;" >/dev/null 2>&1 || true

    if [[ "$check_result" == "ok" ]]; then
        log_success "SQLite $verification_mode passed"
        return 0
    else
        log_error "SQLite verification FAILED: ${check_result:-no output}"
        return 1
    fi
}

verify_encrypted_backup() {
    local encrypted_file="$1"
    local backup_type="$2"
    local verification_mode="${3:-}"

    if [[ -z "$verification_mode" ]]; then
        verification_mode=$(get_verification_mode)
    fi

    log_info "Verifying encrypted backup integrity..."

    local temp_dir
    temp_dir="$(mktemp -d)"
    setup_cleanup_trap "rm -rf '$temp_dir'"

    local temp_decrypted="$temp_dir/decrypted"
    if ! decrypt_file "$encrypted_file" "$temp_decrypted"; then
        log_error "CRITICAL: Backup cannot be decrypted!"
        return 1
    fi
    log_success "Backup decryption verification passed"

    case "$backup_type" in
        db)
            local temp_db="$temp_dir/db.sqlite3"
            if ! gunzip -c "$temp_decrypted" > "$temp_db" 2>/dev/null; then
                log_error "Failed to decompress database backup"
                return 1
            fi
            if verify_sqlite_integrity "$temp_db" "$verification_mode"; then
                log_success "Database backup integrity verified"
                return 0
            else
                log_error "Database backup integrity verification FAILED"
                return 1
            fi
            ;;
        full|emergency)
            if ! tar -tzf "$temp_decrypted" >/dev/null 2>&1; then
                log_error "Archive backup appears corrupted (tar test failed)"
                return 1
            fi
            log_success "Archive backup integrity verified"
            return 0
            ;;
        *)
            log_error "Unknown backup type for verification: $backup_type"
            return 1
            ;;
    esac
}

# --- CORRECTED: Database Backup Function ---
create_db_backup() {
    log_info "Creating database backup with single-snapshot verification..."

    local timestamp backup_dir encrypted_file state_dir db_file verification_mode is_running
    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="$PROJECT_ROOT/backups/db"
    encrypted_file="$backup_dir/vw-db-backup-$timestamp.sqlite3.gz.age"

    ensure_dir "$backup_dir" 755

    state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    db_file="$state_dir/data/bwdata/db.sqlite3"
    verification_mode="$(get_verification_mode)"

    if is_service_running "vaultwarden"; then
        is_running=true
    else
        is_running=false
    fi

    local temp_snapshot
    temp_snapshot="$(mktemp)"
    setup_cleanup_trap "rm -f '$temp_snapshot'"

    log_info "Creating and verifying a single, consistent database snapshot..."
    if [[ "$is_running" == true ]]; then
        local container_snapshot_path="/tmp/snapshot.db"
        setup_cleanup_trap "exec_in_service vaultwarden rm -f '$container_snapshot_path' 2>/dev/null || true"

        if ! exec_in_service vaultwarden sqlite3 "/data/bwdata/db.sqlite3" ".backup '$container_snapshot_path'"; then
            log_error "Failed to create database snapshot inside container"
            return 1
        fi
        if ! exec_in_service vaultwarden sqlite3 "$container_snapshot_path" "PRAGMA integrity_check;" | grep -qx "ok"; then
            log_error "Snapshot integrity check failed inside container, aborting backup"
            return 1
        fi
        if ! docker compose exec -T vaultwarden sh -c "cat '$container_snapshot_path'" > "$temp_snapshot"; then
            log_error "Failed to copy verified snapshot from container"
            return 1
        fi
    else
        if [[ -f "$db_file" ]]; then
            cp "$db_file" "$temp_snapshot"
        else
            log_error "Database file not found: $db_file"
            return 1
        fi
        if ! verify_sqlite_integrity "$temp_snapshot" "$verification_mode"; then
            log_error "Snapshot integrity check failed, aborting backup"
            return 1
        fi
    fi
    log_success "Snapshot created and integrity verified successfully."

    log_info "Compressing and encrypting the verified snapshot..."
    if ! gzip -c "$temp_snapshot" | encrypt_data > "$encrypted_file"; then
        log_error "Failed to compress and encrypt the snapshot"
        return 1
    fi

    secure_file "$encrypted_file" 600 || return 1

    if verify_encrypted_backup "$encrypted_file" "db" "$verification_mode"; then
        log_success "Database backup created and verified: $(basename "$encrypted_file")"
        echo "$encrypted_file"
        return 0
    else
        log_error "CRITICAL: Final backup verification FAILED!"
        rm -f "$encrypted_file"
        return 1
    fi
}

# --- CORRECTED: Full System Backup Function ---
create_full_backup() {
    log_info "Creating full system backup with single-snapshot verification..."

    local timestamp backup_dir encrypted_file state_dir db_file verification_mode is_running
    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="$PROJECT_ROOT/backups/full"
    encrypted_file="$backup_dir/vw-full-backup-$timestamp.tar.gz.age"

    ensure_dir "$backup_dir" 755

    state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    db_file="$state_dir/data/bwdata/db.sqlite3"
    verification_mode="$(get_verification_mode)"

    if is_service_running "vaultwarden"; then
        is_running=true
    else
        is_running=false
    fi

    local temp_dir
    temp_dir="$(mktemp -d)"
    setup_cleanup_trap "rm -rf '$temp_dir'"

    # --- SINGLE SNAPSHOT LOGIC ---
    local db_snapshot="$temp_dir/db.sqlite3.snapshot"
    log_info "Creating and verifying a single, consistent database snapshot..."
    if [[ "$is_running" == true ]]; then
        local container_snapshot_path="/tmp/snapshot.db"
        setup_cleanup_trap "exec_in_service vaultwarden rm -f '$container_snapshot_path' 2>/dev/null || true"

        if ! exec_in_service vaultwarden sqlite3 "/data/bwdata/db.sqlite3" ".backup '$container_snapshot_path'"; then
            log_warn "Failed to create live DB snapshot. Full backup may be inconsistent."
        elif ! exec_in_service vaultwarden sqlite3 "$container_snapshot_path" "PRAGMA integrity_check;" | grep -qx "ok"; then
            log_warn "Live DB snapshot failed integrity check. Full backup may be inconsistent."
        elif ! docker compose exec -T vaultwarden sh -c "cat '$container_snapshot_path'" > "$db_snapshot"; then
            log_warn "Failed to copy verified snapshot from container."
        else
            log_success "Verified database snapshot created for full backup."
        fi
    else
        if [[ -f "$db_file" ]]; then
            cp "$db_file" "$db_snapshot"
            if ! verify_sqlite_integrity "$db_snapshot" "$verification_mode"; then
                log_warn "Database integrity check failed, but continuing with full backup."
            fi
        else
            log_warn "DB file not found, backup will be incomplete."
        fi
    fi
    # --- END SINGLE SNAPSHOT LOGIC ---

    log_info "Gathering configuration files..."
    if [[ -f docker-compose.yml ]]; then
        cp docker-compose.yml "$temp_dir/"
    else
        log_warn "docker-compose.yml not found"
    fi
    if [[ -f .env ]]; then
        cp .env "$temp_dir/"
    else
        log_warn ".env not found"
    fi
    if [[ -d caddy ]]; then
        cp -r caddy "$temp_dir/"
    else
        log_warn "caddy/ directory not found"
    fi
    if [[ -d fail2ban ]]; then
        cp -r fail2ban "$temp_dir/"
    else
        log_warn "fail2ban/ directory not found"
    fi
    if [[ -d secrets ]]; then
        cp -r secrets "$temp_dir/"
    else
        log_warn "secrets/ directory not found"
    fi

    log_info "Copying data directory (excluding live database)..."
    if [[ -d "$state_dir/data" ]]; then
        mkdir -p "$temp_dir/data"
        if ! rsync -a --delete --exclude 'bwdata/db.sqlite3*' "$state_dir/data/" "$temp_dir/data/"; then
            cp -a "$state_dir/data/." "$temp_dir/data/" || true
        fi
        if [[ -f "$db_snapshot" ]]; then
            mkdir -p "$temp_dir/data/bwdata"
            mv "$db_snapshot" "$temp_dir/data/bwdata/db.sqlite3"
            log_info "Included verified database snapshot in full backup."
        fi
    else
        log_warn "State data directory not found: $state_dir/data"
    fi

    log_info "Creating and encrypting archive..."
    if ! tar -czf - -C "$temp_dir" . | encrypt_data > "$encrypted_file"; then
        log_error "Failed to create or encrypt archive"
        return 1
    fi

    secure_file "$encrypted_file" 600 || return 1

    if verify_encrypted_backup "$encrypted_file" "full"; then
        log_success "Full backup created and verified: $(basename "$encrypted_file")"
        echo "$encrypted_file"
        return 0
    else
        log_error "CRITICAL: Full backup verification FAILED!"
        rm -f "$encrypted_file"
        return 1
    fi
}

# --- CORRECTED: Emergency Kit Function ---
create_emergency_kit() {
    log_info "Creating emergency recovery kit with single-snapshot verification..."

    local timestamp backup_dir encrypted_file state_dir db_file verification_mode is_running
    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="$PROJECT_ROOT/backups/emergency"
    encrypted_file="$backup_dir/emergency-kit-$timestamp.tar.gz.age"

    ensure_dir "$backup_dir" 755

    state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    db_file="$state_dir/data/bwdata/db.sqlite3"
    verification_mode="$(get_verification_mode)"

    if is_service_running "vaultwarden"; then
        is_running=true
    else
        is_running=false
    fi

    local temp_dir
    temp_dir="$(mktemp -d)"
    setup_cleanup_trap "rm -rf '$temp_dir'"

    # --- SINGLE SNAPSHOT LOGIC ---
    local db_snapshot="$temp_dir/db.sqlite3.snapshot"
    log_info "Creating and verifying a single, consistent database snapshot for kit..."
    if [[ "$is_running" == true ]]; then
        local container_snapshot_path="/tmp/snapshot.db"
        setup_cleanup_trap "exec_in_service vaultwarden rm -f '$container_snapshot_path' 2>/dev/null || true"

        if ! exec_in_service vaultwarden sqlite3 "/data/bwdata/db.sqlite3" ".backup '$container_snapshot_path'"; then
            log_warn "Failed to create live DB snapshot for kit."
        elif ! exec_in_service vaultwarden sqlite3 "$container_snapshot_path" "PRAGMA integrity_check;" | grep -qx "ok"; then
            log_warn "Live DB snapshot failed integrity check for kit."
        elif ! docker compose exec -T vaultwarden sh -c "cat '$container_snapshot_path'" > "$db_snapshot"; then
            log_warn "Failed to copy verified snapshot from container for kit."
        else
            log_success "Verified database snapshot created for emergency kit."
        fi
    else
        if [[ -f "$db_file" ]]; then
            cp "$db_file" "$db_snapshot"
            if ! verify_sqlite_integrity "$db_snapshot" "$verification_mode"; then
                log_warn "Database integrity check failed for kit."
            fi
        else
            log_warn "DB file not found for kit."
        fi
    fi
    # --- END SINGLE SNAPSHOT LOGIC ---

    log_info "Gathering all project files for emergency kit..."
    if [[ -f docker-compose.yml ]]; then
        cp docker-compose.yml "$temp_dir/"
    else
        log_error "docker-compose.yml required"
        return 1
    fi
    if [[ -f .env ]]; then
        cp .env "$temp_dir/"
    else
        log_error ".env required"
        return 1
    fi
    if [[ -d caddy ]]; then
        cp -r caddy "$temp_dir/"
    else
        log_error "caddy/ required"
        return 1
    fi
    if [[ -d fail2ban ]]; then
        cp -r fail2ban "$temp_dir/"
    else
        log_warn "fail2ban/ not found"
    fi
    if [[ -d secrets ]]; then
        cp -r secrets "$temp_dir/"
    else
        log_error "secrets/ required"
        return 1
    fi

    log_info "Copying data directory for kit..."
    if [[ -d "$state_dir/data" ]]; then
        mkdir -p "$temp_dir/data"
        if ! rsync -a --delete --exclude 'bwdata/db.sqlite3*' "$state_dir/data/" "$temp_dir/data/"; then
            cp -a "$state_dir/data/." "$temp_dir/data/" || true
        fi
        if [[ -f "$db_snapshot" ]]; then
            mkdir -p "$temp_dir/data/bwdata"
            mv "$db_snapshot" "$temp_dir/data/bwdata/db.sqlite3"
            log_info "Included verified database snapshot in emergency kit."
        fi
    fi

    log_info "Creating and encrypting emergency kit archive..."
    if ! tar -czf - -C "$temp_dir" . | encrypt_data > "$encrypted_file"; then
        log_error "Failed to create or encrypt emergency kit"
        return 1
    fi

    secure_file "$encrypted_file" 600 || return 1

    if verify_encrypted_backup "$encrypted_file" "emergency"; then
        log_success "Emergency kit created and verified: $(basename "$encrypted_file")"
        echo "$encrypted_file"
        return 0
    else
        log_error "CRITICAL: Emergency kit verification FAILED!"
        rm -f "$encrypted_file"
        return 1
    fi
}

# --- Rclone Sync Function ---
rclone_sync_offsite() {
    local backup_file_path="$1"

    log_info "Starting offsite backup sync..."
    if ! has_command rclone; then
        log_error "rclone not found"
        return 1
    fi

    local remote_name
    remote_name="$(get_config_value "RCLONE_REMOTE_NAME" "")"
    if [[ -z "$remote_name" || "$remote_name" == "CHANGE_ME" ]]; then
        log_warn "RCLONE_REMOTE_NAME not configured. Skipping sync."
        return 0
    fi

    local remote_base_path backup_filename backup_type_dir remote_file_path
    remote_base_path="$remote_name:vaultwarden_backups"
    backup_filename="$(basename "$backup_file_path")"
    backup_type_dir="$(basename "$(dirname "$backup_file_path")")"
    remote_file_path="$remote_base_path/$backup_type_dir/$backup_filename"

    log_info "Syncing '$backup_filename' to remote: $remote_file_path"
    if ! rclone copyto "$backup_file_path" "$remote_file_path"; then
        log_error "Rclone sync failed"
        return 1
    fi
    log_success "Rclone sync completed"
    return 0
}

# --- Main Execution ---
main() {
    if [[ $LIST_BACKUPS == true ]]; then
        list_backups
        exit $?
    fi

    log_info "VaultWarden Enhanced Backup Tool with Verification"
    load_env_file || exit 1
    require_commands tar gzip age sqlite3 || exit 1

    local backup_file=""
    case "$BACKUP_TYPE" in
        db)        backup_file="$(create_db_backup)" ;;
        full)      backup_file="$(create_full_backup)" ;;
        emergency) backup_file="$(create_emergency_kit)" ;;
        *) log_error "Unknown backup type: $BACKUP_TYPE"; exit 1 ;;
    esac

    if [[ -z "$backup_file" ]]; then
        log_error "Backup creation or verification failed"
        if [[ $EMAIL_NOTIFY == true ]]; then
            send_notification_email "Backup FAILED: $BACKUP_TYPE" "Backup creation or verification failed."
        fi
        exit 1
    fi

    local sync_status="Skipped"
    if [[ $RCLONE_SYNC == true ]]; then
        if rclone_sync_offsite "$backup_file"; then
            sync_status="Success"
        else
            sync_status="Failed"
        fi
    fi

    log_success "Backup process completed!"
    local file_size
    file_size="$(du -h "$backup_file" | cut -f1)"
    printf "\nBackup Details:\n  Type: %s\n  File: %s\n  Size: %s\n  Verification: Passed\n  Rclone Sync: %s\n\n" \
        "$BACKUP_TYPE" "$backup_file" "$file_size" "$sync_status"

    if [[ $EMAIL_NOTIFY == true ]]; then
        log_info "Sending completion email..."
        send_notification_email "Backup Completed: $BACKUP_TYPE" "Backup job completed successfully.\nFile: $(basename "$backup_file")\nSize: $file_size\nSync: $sync_status"
    fi
}

main "$@"
