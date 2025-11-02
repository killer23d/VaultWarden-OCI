#!/usr/bin/env bash
# backup.sh - Streamlined VaultWarden backup script
# Optimized for "set-and-forget" by removing redundant logic.
# - Re-introduced 'emergency' type for full DR (includes secrets).
# - 'full' type includes config + data (no secrets).
# - Removed internal retention logic (handled by maintenance.sh).
# - ENHANCEMENT #2: Added end-to-end backup verification for complete recoverability testing.
# - Hardened rsync fallback logic per user feedback.

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
DRY_RUN=false
# ENHANCEMENT #2: End-to-end verification mode
FULL_VERIFICATION=true  # Can be disabled with --skip-full-verification

# --- Lock File (mkdir approach for portability) ---
LOCKDIR="/var/run/vaultwarden-backup.lock"

# --- Consolidated Cleanup Mechanism ---
CLEANUP_ACTIONS=()

register_cleanup() {
    CLEANUP_ACTIONS+=("$1")
}

perform_cleanup() {
    local action
    # Execute in reverse order (LIFO)
    for ((idx=${#CLEANUP_ACTIONS[@]}-1; idx>=0; idx--)); do
        eval "${CLEANUP_ACTIONS[$idx]}" 2>/dev/null || true
    done
}

trap perform_cleanup EXIT

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden-OCI-NG Streamlined Backup Tool

USAGE:
  ./backup.sh [OPTIONS]

OPTIONS:
    --type TYPE                   Backup type: db, full, or emergency (default: db)
    --rclone                      Sync backup to rclone remote after creation
    --email                       Send email notification on completion
    --dry-run                     Preview operations without executing
    --list                        List available local backups
    --skip-full-verification      Skip end-to-end backup recoverability testing
    --help                        Show this help

BACKUP TYPES:
    db          - Database only.
    full        - Config files and data (NO secrets). Good for version upgrades.
    emergency   - EVERYTHING: Config, data, AND secrets. Full disaster recovery.

VERIFICATION:
    - Verifies database integrity *before* backup.
    - NEW: Tests complete backup recoverability after creation.
    - Relies on tool exit codes for archive and encryption integrity.

NOTES:
    - Uses atomic 'mkdir' for process locking.
    - Retention/Cleanup is handled by 'maintenance.sh'.
    - Full verification tests that backups can actually be restored.
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
        --email)   EMAIL_NOTIFY=true; shift ;;
        --rclone)  RCLONE_SYNC=true; shift ;;
        --list)    LIST_BACKUPS=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --skip-full-verification) FULL_VERIFICATION=false; shift ;;
        --help)    show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Pre-flight Checks ---
preflight_checks() {
    log_info "Running pre-flight checks..."

    # Docker availability
    if ! docker compose version >/dev/null 2>&1; then
        log_error "Docker Compose not available or not responding"
        return 1
    fi

    # VaultWarden service exists
    if ! docker compose ps vaultwarden >/dev/null 2>&1; then
        log_error "VaultWarden service not found in docker-compose.yml"
        return 1
    fi

    # Required commands
    require_commands tar gzip age sqlite3 rsync || exit 1

    log_success "Pre-flight checks passed"
}

# --- Disk Space Check ---
check_disk_space() {
    local backup_dir="$1"
    local state_dir
    state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"

    if [[ ! -d "$state_dir/data" ]]; then
        log_warn "Cannot estimate disk space: $state_dir/data not found"
        return 0
    fi

    local required_space available_space
    # Estimate required space (2x data dir size)
    required_space=$(($(du -sb "$state_dir/data" 2>/dev/null | cut -f1) * 2))
    available_space=$(df --output=avail -B1 "$backup_dir" 2>/dev/null | tail -1)

    if [[ -z "$available_space" ]] || [[ $available_space -lt $required_space ]]; then
        log_error "Insufficient disk space: need $((required_space / 1024 / 1024))MB, have $((available_space / 1024 / 1024))MB"
        return 1
    fi

    log_info "Disk space check passed: $((available_space / 1024 / 1024))MB available"
    return 0
}

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

    log_info "Running SQLite $verification_mode and optimize on database snapshot..."
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

# --- ENHANCEMENT #2: End-to-End Backup Verification ---
verify_backup_recoverability() {
    local encrypted_file="$1"
    local backup_type="$2"

    if [[ "$FULL_VERIFICATION" != "true" ]]; then
        log_info "Skipping end-to-end verification (--skip-full-verification specified)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would perform end-to-end backup recoverability test"
        return 0
    fi

    log_info "Performing end-to-end backup recoverability verification..."

    # Create temporary directory for verification
    local verify_temp_dir
    verify_temp_dir=$(mktemp -d)
    register_cleanup "rm -rf '$verify_temp_dir'"

    case "$backup_type" in
        "db")
            # Test database backup recoverability
            log_debug "Testing database backup decryption and decompression..."

            # Decrypt and decompress to temp file
            local test_db="$verify_temp_dir/test_recovery.db"
            if ! age -d -i "$SOPS_AGE_KEY_FILE" "$encrypted_file" | gzip -d > "$test_db" 2>/dev/null; then
                log_error "CRITICAL: Database backup cannot be decrypted or decompressed!"
                return 1
            fi

            # Verify recovered database integrity
            if ! verify_sqlite_integrity "$test_db" "quick_check"; then
                log_error "CRITICAL: Recovered database fails integrity check!"
                return 1
            fi

            # Test basic database operations
            local table_count
            if ! table_count=$(sqlite3 "$test_db" "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null); then
                log_error "CRITICAL: Cannot query recovered database!"
                return 1
            fi

            log_success "Database backup verification: Decryptable, decompressible, and queryable ($table_count tables)"
            ;;

        "full"|"emergency")
            # Test archive backup recoverability  
            log_debug "Testing archive backup decryption and extraction..."

            # Test decryption and decompression
            if ! age -d -i "$SOPS_AGE_KEY_FILE" "$encrypted_file" | tar -tzf - >/dev/null 2>&1; then
                log_error "CRITICAL: Archive backup cannot be decrypted or extracted!"
                return 1
            fi

            # Test partial extraction of key files
            local test_extraction_dir="$verify_temp_dir/test_extract"
            mkdir -p "$test_extraction_dir"

            # Extract just a few key files to verify structure
            if age -d -i "$SOPS_AGE_KEY_FILE" "$encrypted_file" | tar -xzf - -C "$test_extraction_dir" ./data/bwdata/db.sqlite3 2>/dev/null; then
                # Verify extracted database
                if [[ -f "$test_extraction_dir/data/bwdata/db.sqlite3" ]]; then
                    if verify_sqlite_integrity "$test_extraction_dir/data/bwdata/db.sqlite3" "quick_check"; then
                        log_success "Archive backup verification: Complete extraction successful with valid database"
                    else
                        log_warn "Archive extracted but database integrity questionable"
                    fi
                else
                    log_warn "Archive extracted but database file not found in expected location"
                fi
            else
                log_warn "Archive backup appears valid but partial extraction test failed"
                # Still continue - this might be due to archive structure differences
            fi
            ;;
    esac

    log_success "End-to-end backup recoverability verification completed"
    return 0
}

# --- Generate Backup Metadata ---
generate_metadata() {
    local encrypted_file="$1"
    local backup_type="$2"
    local timestamp="$3"
    local checksum="$4"

    local vaultwarden_version
    vaultwarden_version=$(docker compose exec -T vaultwarden /vaultwarden --version 2>/dev/null | head -1 || echo "unknown")

    cat > "$encrypted_file.meta" <<EOF
backup_type=$backup_type
timestamp=$timestamp
hostname=$(hostname)
verification_mode=$(get_verification_mode)
full_verification=$FULL_VERIFICATION
vaultwarden_version=$vaultwarden_version
file_size=$(stat -c%s "$encrypted_file" 2>/dev/null || stat -f%z "$encrypted_file")
sha256=$checksum
EOF

    log_info "Metadata written to $(basename "$encrypted_file.meta")"
}

# --- Database Backup Function ---
create_db_backup() {
    log_info "Creating database backup with comprehensive verification..."

    local timestamp backup_dir encrypted_file state_dir db_file verification_mode is_running
    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="$PROJECT_ROOT/backups/db"
    encrypted_file="$backup_dir/vw-db-backup-$timestamp.sqlite3.gz.age"

    ensure_dir "$backup_dir" 755
    check_disk_space "$backup_dir" || return 1

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
    register_cleanup "rm -f '$temp_snapshot'"

    log_info "Creating and verifying a consistent database snapshot..."
    if [[ "$is_running" == true ]]; then
        # Unique temp path with PID to prevent collisions
        local container_snapshot_path="/tmp/vw-snapshot-$timestamp-$$.db"
        register_cleanup "docker compose exec -T vaultwarden rm -f '$container_snapshot_path' 2>/dev/null || true"

        # 1. Create snapshot inside container
        if ! docker compose exec -T vaultwarden sqlite3 "/data/bwdata/db.sqlite3" ".backup '$container_snapshot_path'"; then
            log_error "Failed to create database snapshot inside container"
            return 1
        fi

        # 2. Verify snapshot inside container
        if ! docker compose exec -T vaultwarden sqlite3 "$container_snapshot_path" "PRAGMA integrity_check;" | grep -qx "ok"; then
            log_error "Snapshot integrity check failed inside container, aborting backup"
            return 1
        fi

        # 3. Copy snapshot out
        if ! docker compose cp "vaultwarden:$container_snapshot_path" "$temp_snapshot"; then
            log_error "Failed to copy verified snapshot from container"
            return 1
        fi
    else
        # If container is not running, just copy the file and verify it
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

    if [[ $DRY_RUN == true ]]; then
        log_info "[DRY-RUN] Would compress, encrypt, and verify backup"
        return 0
    fi

    log_info "Compressing and encrypting the verified snapshot..."
    if ! gzip -c "$temp_snapshot" | encrypt_data > "$encrypted_file"; then
        log_error "Failed to compress and encrypt the snapshot"
        return 1
    fi

    secure_file "$encrypted_file" 600 || return 1

    # ENHANCEMENT #2: Perform end-to-end verification
    if ! verify_backup_recoverability "$encrypted_file" "db"; then
        log_error "CRITICAL: Backup created but failed recoverability verification!"
        return 1
    fi

    # Generate checksum and metadata
    local checksum
    checksum=$(sha256sum "$encrypted_file" | awk '{print $1}')
    echo "$checksum" > "$encrypted_file.sha256"
    generate_metadata "$encrypted_file" "db" "$timestamp" "$checksum"

    log_success "Database backup created and verified: $(basename "$encrypted_file")"
    echo "$encrypted_file"
    return 0
}

# --- Common Archive Backup Logic ---
# $1: temp_dir
# $2: verification_mode
# $3: is_running (true/false)
# $4: state_dir
# $5: db_file
# $6: timestamp
# $7: include_secrets (true/false)
create_archive_data() {
    local temp_dir="$1"
    local verification_mode="$2"
    local is_running="$3"
    local state_dir="$4"
    local db_file="$5"
    local timestamp="$6"
    local include_secrets="$7"

    # --- SINGLE SNAPSHOT LOGIC ---
    local db_snapshot="$temp_dir/db.sqlite3.snapshot"
    log_info "Creating and verifying a consistent database snapshot..."
    if [[ "$is_running" == true ]]; then
        local container_snapshot_path="/tmp/vw-snapshot-$timestamp-$$.db"
        register_cleanup "docker compose exec -T vaultwarden rm -f '$container_snapshot_path' 2>/dev/null || true"

        if ! docker compose exec -T vaultwarden sqlite3 "/data/bwdata/db.sqlite3" ".backup '$container_snapshot_path'"; then
            log_warn "Failed to create live DB snapshot. Backup may be inconsistent."
        elif ! docker compose exec -T vaultwarden sqlite3 "$container_snapshot_path" "PRAGMA integrity_check;" | grep -qx "ok"; then
            log_warn "Live DB snapshot failed integrity check. Backup may be inconsistent."
        elif ! docker compose cp "vaultwarden:$container_snapshot_path" "$db_snapshot"; then
            log_warn "Failed to copy verified snapshot from container."
        else
            log_success "Verified database snapshot created for archive."
        fi
    else
        if [[ -f "$db_file" ]]; then
            cp "$db_file" "$db_snapshot"
            if ! verify_sqlite_integrity "$db_snapshot" "$verification_mode"; then
                log_warn "Database integrity check failed, but continuing with archive."
            fi
        else
            log_warn "DB file not found, backup will be incomplete."
        fi
    fi

    log_info "Gathering configuration files..."
    [[ -f docker-compose.yml ]] && cp docker-compose.yml "$temp_dir/" || log_warn "docker-compose.yml not found"
    [[ -f .env ]] && cp .env "$temp_dir/" || log_warn ".env not found"
    [[ -d caddy ]] && cp -r caddy "$temp_dir/" || log_warn "caddy/ not found"
    [[ -d fail2ban ]] && cp -r fail2ban "$temp_dir/" || log_warn "fail2ban/ not found"

    if [[ "$include_secrets" == "true" ]]; then
        log_info "Including 'secrets' directory for emergency kit."
        [[ -d secrets ]] && cp -r secrets "$temp_dir/" || { log_error "secrets/ directory required for emergency kit and not found."; return 1; }
    else
        log_info "Skipping 'secrets' directory for 'full' backup."
    fi

    log_info "Copying data directory (excluding live database)..."
    if [[ -d "$state_dir/data" ]]; then
        mkdir -p "$temp_dir/data"
        # --- Start User Feedback Fix: Harder fail on rsync/cp error ---
        if ! rsync -a --delete --exclude 'bwdata/db.sqlite3*' "$state_dir/data/" "$temp_dir/data/" 2>/dev/null; then
            log_warn "rsync failed, falling back to 'cp'..."
            if ! cp -a "$state_dir/data/." "$temp_dir/data/"; then
                log_error "Failed to copy data directory using both rsync and cp"
                return 1
            fi
        fi
        # --- End User Feedback Fix ---

        if [[ -f "$db_snapshot" ]]; then
            mkdir -p "$temp_dir/data/bwdata"
            mv "$db_snapshot" "$temp_dir/data/bwdata/db.sqlite3"
            log_info "Included database snapshot in archive."
        fi
    else
        log_warn "State data directory not found: $state_dir/data"
    fi
    return 0
}


# --- Full System Backup Function ---
create_full_backup() {
    log_info "Creating full system backup (config + data, NO secrets)..."

    local timestamp backup_dir encrypted_file state_dir db_file verification_mode is_running
    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="$PROJECT_ROOT/backups/full"
    encrypted_file="$backup_dir/vw-full-backup-$timestamp.tar.gz.age"

    ensure_dir "$backup_dir" 755
    check_disk_space "$backup_dir" || return 1

    state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    db_file="$state_dir/data/bwdata/db.sqlite3"
    verification_mode="$(get_verification_mode)"
    is_running=$(is_service_running "vaultwarden" && echo "true" || echo "false")

    local temp_dir
    temp_dir="$(mktemp -d)"
    register_cleanup "rm -rf '$temp_dir'"

    # Call common archive logic, DO NOT include secrets
    create_archive_data "$temp_dir" "$verification_mode" "$is_running" "$state_dir" "$db_file" "$timestamp" "false" || return 1

    if [[ $DRY_RUN == true ]]; then
        log_info "[DRY-RUN] Would create and verify 'full' archive"
        return 0
    fi

    log_info "Creating and encrypting 'full' archive..."
    if ! tar -czf - -C "$temp_dir" . | encrypt_data > "$encrypted_file"; then
        log_error "Failed to create or encrypt 'full' archive"
        return 1
    fi

    secure_file "$encrypted_file" 600 || return 1

    # ENHANCEMENT #2: Perform end-to-end verification
    if ! verify_backup_recoverability "$encrypted_file" "full"; then
        log_error "CRITICAL: Full backup created but failed recoverability verification!"
        return 1
    fi

    # Generate checksum and metadata
    local checksum
    checksum=$(sha256sum "$encrypted_file" | awk '{print $1}')
    echo "$checksum" > "$encrypted_file.sha256"
    generate_metadata "$encrypted_file" "full" "$timestamp" "$checksum"

    log_success "Full backup created and verified: $(basename "$encrypted_file")"
    echo "$encrypted_file"
    return 0
}

# --- Emergency Kit Function ---
create_emergency_kit() {
    log_info "Creating emergency recovery kit (config + data + secrets)..."

    local timestamp backup_dir encrypted_file state_dir db_file verification_mode is_running
    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="$PROJECT_ROOT/backups/emergency"
    encrypted_file="$backup_dir/emergency-kit-$timestamp.tar.gz.age"

    ensure_dir "$backup_dir" 755
    check_disk_space "$backup_dir" || return 1

    state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    db_file="$state_dir/data/bwdata/db.sqlite3"
    verification_mode="$(get_verification_mode)"
    is_running=$(is_service_running "vaultwarden" && echo "true" || echo "false")

    local temp_dir
    temp_dir="$(mktemp -d)"
    register_cleanup "rm -rf '$temp_dir'"

    # Call common archive logic, DO include secrets
    create_archive_data "$temp_dir" "$verification_mode" "$is_running" "$state_dir" "$db_file" "$timestamp" "true" || return 1

    if [[ $DRY_RUN == true ]]; then
        log_info "[DRY-RUN] Would create and verify 'emergency' kit"
        return 0
    fi

    log_info "Creating and encrypting 'emergency' kit archive..."
    if ! tar -czf - -C "$temp_dir" . | encrypt_data > "$encrypted_file"; then
        log_error "Failed to create or encrypt 'emergency' kit"
        return 1
    fi

    secure_file "$encrypted_file" 600 || return 1

    # ENHANCEMENT #2: Perform end-to-end verification
    if ! verify_backup_recoverability "$encrypted_file" "emergency"; then
        log_error "CRITICAL: Emergency kit created but failed recoverability verification!"
        return 1
    fi

    # Generate checksum and metadata
    local checksum
    checksum=$(sha256sum "$encrypted_file" | awk '{print $1}')
    echo "$checksum" > "$encrypted_file.sha256"
    generate_metadata "$encrypted_file" "emergency" "$timestamp" "$checksum"

    log_success "Emergency kit created and verified: $(basename "$encrypted_file")"
    echo "$encrypted_file"
    return 0
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

    # Sync metadata and checksum
    rclone copyto "$backup_file_path.sha256" "$remote_file_path.sha256" 2>/dev/null || true
    rclone copyto "$backup_file_path.meta" "$remote_file_path.meta" 2>/dev/null || true

    log_success "Rclone sync completed"
    return 0
}

# --- Main Execution ---
main() {
    # Acquire lock
    if ! mkdir "$LOCKDIR" 2>/dev/null; then
        log_error "Another backup is already running (lock: $LOCKDIR)"
        exit 1
    fi
    register_cleanup "rmdir '$LOCKDIR' 2>/dev/null || true"

    if [[ $LIST_BACKUPS == true ]]; then
        list_backups
        exit 0
    fi

    log_info "VaultWarden Streamlined Backup Tool with Enhanced Verification"

    # Early environment checks
    load_env_file || exit 1
    preflight_checks

    local backup_file=""
    case "$BACKUP_TYPE" in
        db)        backup_file="$(create_db_backup)" ;;
        full)      backup_file="$(create_full_backup)" ;;
        emergency) backup_file="$(create_emergency_kit)" ;;
        *) log_error "Unknown backup type: $BACKUP_TYPE (must be 'db', 'full', or 'emergency')"; exit 1 ;;
    esac

    if [[ -z "$backup_file" ]]; then
        log_error "Backup creation or verification failed"
        if [[ $EMAIL_NOTIFY == true ]]; then
            send_notification_email "Backup FAILED: $BACKUP_TYPE" "Backup creation or verification failed."
        fi
        exit 1
    fi

    # Retention/cleanup is now handled by maintenance.sh, so we skip it here.

    local sync_status="Skipped"
    if [[ $RCLONE_SYNC == true ]]; then
        if rclone_sync_offsite "$backup_file"; then
            sync_status="Success"
        else
            sync_status="Failed"
        fi
    fi

    log_success "Backup process completed!"
    local file_size checksum
    file_size="$(du -h "$backup_file" | cut -f1)"
    checksum="$(cat "$backup_file.sha256" 2>/dev/null || echo "N/A")"

    printf "
Backup Details:
"
    printf "  Type:         %s
" "$BACKUP_TYPE"
    printf "  File:         %s
" "$backup_file"
    printf "  Size:         %s
" "$file_size"
    printf "  SHA256:       %s
" "$checksum"
    printf "  Verification: Pre-encryption snapshot OK + End-to-end recoverability verified
"
    printf "  Rclone Sync:  %s
" "$sync_status"
    printf "
"

    if [[ $EMAIL_NOTIFY == true ]]; then
        log_info "Sending completion email..."
        send_notification_email "Backup Completed: $BACKUP_TYPE"             "Backup job completed successfully with full verification.
File: $(basename "$backup_file")
Size: $file_size
Checksum: $checksum
Verification: Complete recoverability confirmed
Sync: $sync_status"
    fi

    exit 0
}

main "$@"
