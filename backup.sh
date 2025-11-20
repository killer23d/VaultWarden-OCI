#!/usr/bin/env bash
# backup.sh - Streamlined VaultWarden backup script with enhanced verification
# ENHANCED: Email delivery uses lib/common.sh which prefers msmtpd sidecar if available
# All functions return exit codes, main() collects status and determines final exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# Source Libraries
source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh"
source "lib/backup_utils.sh"

# Configuration
BACKUP_TYPE="db"
EMAIL_NOTIFY=false
RCLONE_SYNC=false
LIST_BACKUPS=false
DRY_RUN=false
FULL_VERIFICATION=false  # Default to fast verification for daily runs

LOCKDIR="/var/run/vaultwarden-backup.lock"
CLEANUP_ACTIONS=()

register_cleanup() { CLEANUP_ACTIONS+=("$1"); }
perform_cleanup() { for ((idx=${#CLEANUP_ACTIONS[@]}-1; idx>=0; idx--)); do eval "${CLEANUP_ACTIONS[$idx]}" 2>/dev/null || true; done; }
trap perform_cleanup EXIT

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
    --full-verification           Enable comprehensive backup recoverability testing
    --help                        Show this help

BACKUP TYPES:
    db          - Database only
    full        - Config files and data (NO secrets)
    emergency   - EVERYTHING: Config, data, AND secrets

VERIFICATION LEVELS:
    Default: Post-encryption checksum verification (fast, reliable)
    --full-verification: Complete decrypt and extraction test (thorough, slower)

RECOMMENDED USAGE:
    Daily:   ./backup.sh --type db                    # Fast verification
    Weekly:  ./backup.sh --type full --full-verification  # Complete test
EOF
}

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
        --email) EMAIL_NOTIFY=true; shift ;;
        --rclone) RCLONE_SYNC=true; shift ;;
        --list) LIST_BACKUPS=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --skip-full-verification) FULL_VERIFICATION=false; shift ;;
        --full-verification) FULL_VERIFICATION=true; shift ;;  # NEW
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

preflight_checks() {
    log_info "Running pre-flight checks..."
    require_docker || return 1
    docker compose ps vaultwarden >/dev/null 2>&1 || { log_error "VaultWarden service not found in docker-compose.yml"; return 1; }
    require_commands tar gzip age sqlite3 rsync || return 1
    log_success "Pre-flight checks passed"
}

get_verification_mode() { local mode; mode=$(get_config_value "BACKUP_VERIFICATION_MODE" "quick_check"); case "$mode" in quick_check|integrity_check) echo "$mode" ;; *) echo "quick_check" ;; esac; }

verify_sqlite_integrity() {
    local db_file="$1" verification_mode="${2:-quick_check}"
    [[ ! -f "$db_file" ]] && { log_error "Database file not found for verification: $db_file"; return 1; }
    log_info "Running SQLite $verification_mode and optimize on database snapshot..."
    local check_result
    case "$verification_mode" in
        quick_check) check_result="$(sqlite3 "$db_file" "PRAGMA quick_check;" 2>/dev/null)" || return 1 ;;
        integrity_check) check_result="$(sqlite3 "$db_file" "PRAGMA integrity_check;" 2>/dev/null)" || return 1 ;;
        *) log_error "Unknown verification mode: $verification_mode"; return 1 ;;
    esac
    sqlite3 "$db_file" "PRAGMA optimize;" >/dev/null 2>&1 || log_warn "Failed to optimize database, but continuing"
    if [[ "$check_result" == "ok" ]]; then log_success "SQLite $verification_mode passed"; return 0; else log_error "SQLite verification FAILED: ${check_result:-no output}"; return 1; fi
}

verify_backup_recoverability() {
    local encrypted_file="$1" backup_type="$2"
    if [[ "$FULL_VERIFICATION" != "true" ]]; then
        log_info "Skipping end-to-end verification (using fast checksum)."
        return 0
    fi
    [[ "$DRY_RUN" == "true" ]] && { log_info "[DRY RUN] Would perform end-to-end backup recoverability test"; return 0; }
    log_info "Performing end-to-end backup recoverability verification..."
    local verify_temp_dir; verify_temp_dir=$(mktemp -d); register_cleanup "rm -rf '$verify_temp_dir'"
    case "$backup_type" in
        "db")
            local test_db="$verify_temp_dir/test_recovery.db"
            age -d -i "$SOPS_AGE_KEY_FILE" "$encrypted_file" | gzip -d > "$test_db" 2>/dev/null || { log_error "CRITICAL: Database backup cannot be decrypted or decompressed!"; return 1; }
            verify_sqlite_integrity "$test_db" "quick_check" || { log_error "CRITICAL: Recovered database fails integrity check!"; return 1; }
            local table_count; table_count=$(sqlite3 "$test_db" "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null) || { log_error "CRITICAL: Cannot query recovered database!"; return 1; }
            log_success "Database backup verification: Decryptable, decompressible, and queryable ($table_count tables)"
            ;;
        "full"|"emergency")
            age -d -i "$SOPS_AGE_KEY_FILE" "$encrypted_file" | tar -tzf - >/dev/null 2>&1 || { log_error "CRITICAL: Archive backup cannot be decrypted or extracted!"; return 1; }
            local test_extraction_dir="$verify_temp_dir/test_extract"; mkdir -p "$test_extraction_dir" || { log_error "Failed to create test extraction directory"; return 1; }
            if age -d -i "$SOPS_AGE_KEY_FILE" "$encrypted_file" | tar -xzf - -C "$test_extraction_dir" ./data/db.sqlite3 2>/dev/null; then
                if [[ -f "$test_extraction_dir/data/db.sqlite3" ]]; then
                    verify_sqlite_integrity "$test_extraction_dir/data/db.sqlite3" "quick_check" && log_success "Archive backup verification: Complete extraction successful with valid database" || { log_warn "Archive extracted but database integrity questionable"; return 1; }
                else log_warn "Archive extracted but database file not found in expected location"; return 1; fi
            else log_warn "Archive backup appears valid but partial extraction test failed"; fi
            ;;
    esac
    log_success "End-to-end backup recoverability verification completed"
}

verify_post_encryption_checksum() {
    local encrypted_file="$1"
    [[ ! -f "$encrypted_file" ]] && { log_error "Encrypted file not found for checksum verification: $encrypted_file"; return 1; }
    [[ ! -f "$encrypted_file.sha256" ]] && { log_error "Checksum file not found: $encrypted_file.sha256"; return 1; }
    log_info "Performing post-encryption checksum verification..."
    local expected_checksum actual_checksum; expected_checksum=$(cat "$encrypted_file.sha256" 2>/dev/null); [[ -z "$expected_checksum" ]] && { log_error "Empty or invalid checksum file"; return 1; }
    actual_checksum=$(calculate_sha256 "$encrypted_file") || { log_error "Failed to calculate actual checksum"; return 1; }
    if [[ "$actual_checksum" == "$expected_checksum" ]]; then log_success "Post-encryption checksum verification passed"; else log_error "CRITICAL: Post-encryption checksum verification FAILED!"; return 1; fi
}

generate_metadata() {
    local encrypted_file="$1" backup_type="$2" timestamp="$3" checksum="$4"
    local vaultwarden_version; vaultwarden_version=$(docker compose exec -T vaultwarden /vaultwarden --version 2>/dev/null | head -1 || echo "unknown")
    local file_size; file_size=$(stat -c%s "$encrypted_file" 2>/dev/null || stat -f%z "$encrypted_file" 2>/dev/null || echo "0")
    cat > "$encrypted_file.meta" <<EOF || { log_error "Failed to create metadata file"; return 1; }
backup_type=$backup_type
timestamp=$timestamp
hostname=$(hostname)
verification_mode=$(get_verification_mode)
full_verification=$FULL_VERIFICATION
vaultwarden_version=$vaultwarden_version
file_size=$file_size
sha256=$checksum
EOF
    log_info "Metadata written to $(basename "$encrypted_file.meta")"
}

create_db_backup() {
    log_info "Creating database backup with comprehensive verification..."
    local timestamp backup_dir encrypted_file state_dir db_file verification_mode is_running
    timestamp="$(date +%Y%m%d-%H%M%S)"; backup_dir="$PROJECT_ROOT/backups/db"; encrypted_file="$backup_dir/vw-db-backup-$timestamp.sqlite3.gz.age"
    ensure_dir "$backup_dir" 755 || return 1
    check_backup_disk_space "$backup_dir" 1000 || return 1
    state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"; db_file="$state_dir/data/db.sqlite3"; verification_mode="$(get_verification_mode)"
    is_running=$(is_service_running "vaultwarden" && echo "true" || echo "false")
    local temp_snapshot; temp_snapshot="$(mktemp)"; register_cleanup "rm -f '$temp_snapshot'"
    log_info "Creating and verifying a consistent database snapshot..."
    if [[ "$is_running" == true ]]; then
        local container_snapshot_path="/tmp/vw-snapshot-$timestamp-$$.db"; register_cleanup "docker compose exec -T vaultwarden rm -f '$container_snapshot_path' 2>/dev/null || true"
        docker compose exec -T vaultwarden sqlite3 "/data/db.sqlite3" ".backup '$container_snapshot_path'" || { log_error "Failed to create database snapshot inside container"; return 1; }
        docker compose exec -T vaultwarden sqlite3 "$container_snapshot_path" "PRAGMA integrity_check;" | grep -qx "ok" || { log_error "Snapshot integrity check failed inside container, aborting backup"; return 1; }
        docker compose cp "vaultwarden:$container_snapshot_path" "$temp_snapshot" || { log_error "Failed to copy verified snapshot from container"; return 1; }
    else
        if [[ -f "$db_file" ]]; then cp "$db_file" "$temp_snapshot" || { log_error "Failed to copy database file"; return 1; }
        else log_error "Database file not found: $db_file"; return 1; fi
        verify_sqlite_integrity "$temp_snapshot" "$verification_mode" || { log_error "Snapshot integrity check failed, aborting backup"; return 1; }
    fi
    log_success "Snapshot created and integrity verified successfully."
    if [[ $DRY_RUN == true ]]; then log_info "[DRY-RUN] Would compress, encrypt, and verify backup"; return 0; fi
    log_info "Compressing and encrypting the verified snapshot..."
    gzip -c "$temp_snapshot" | encrypt_data > "$encrypted_file" || { log_error "Failed to compress and encrypt the snapshot"; return 1; }
    secure_file "$encrypted_file" 600 || return 1
    local checksum; checksum=$(calculate_sha256 "$encrypted_file") || { log_error "Failed to calculate checksum"; return 1; }
    echo "$checksum" > "$encrypted_file.sha256"
    verify_post_encryption_checksum "$encrypted_file" || { log_error "CRITICAL: Backup created but failed post-encryption verification!"; return 1; }
    verify_backup_recoverability "$encrypted_file" "db" || { log_error "CRITICAL: Backup created but failed recoverability verification!"; return 1; }
    generate_metadata "$encrypted_file" "db" "$timestamp" "$checksum" || log_warn "Failed to create metadata, but backup is valid"
    log_success "Database backup created and verified: $(basename "$encrypted_file")"
    echo "$encrypted_file"
}

create_archive_data() {
    local temp_dir="$1" verification_mode="$2" is_running="$3" state_dir="$4" db_file="$5" timestamp="$6" include_secrets="$7"
    local db_snapshot="$temp_dir/db.sqlite3.snapshot"; log_info "Creating and verifying a consistent database snapshot..."
    if [[ "$is_running" == true ]]; then
        local container_snapshot_path="/tmp/vw-snapshot-$timestamp-$$.db"; register_cleanup "docker compose exec -T vaultwarden rm -f '$container_snapshot_path' 2>/dev/null || true"
        docker compose exec -T vaultwarden sqlite3 "/data/db.sqlite3" ".backup '$container_snapshot_path'" || log_warn "Failed to create live DB snapshot. Backup may be inconsistent."
        docker compose exec -T vaultwarden sqlite3 "$container_snapshot_path" "PRAGMA integrity_check;" | grep -qx "ok" || log_warn "Live DB snapshot failed integrity check. Backup may be inconsistent."
        docker compose cp "vaultwarden:$container_snapshot_path" "$db_snapshot" || log_warn "Failed to copy verified snapshot from container."
    else
        if [[ -f "$db_file" ]]; then cp "$db_file" "$db_snapshot" || { log_error "Failed to copy database file for archive"; return 1; }
             verify_sqlite_integrity "$db_snapshot" "$verification_mode" || log_warn "Database integrity check failed, but continuing with archive."
        else log_warn "DB file not found, backup will be incomplete."; fi
    fi
    log_info "Gathering configuration files..."
    [[ -f docker-compose.yml ]] && cp docker-compose.yml "$temp_dir/" || log_warn "docker-compose.yml not found"
    [[ -f .env ]] && cp .env "$temp_dir/" || log_warn ".env not found"
    [[ -d caddy ]] && cp -r caddy "$temp_dir/" || log_warn "caddy/ not found"
    [[ -d fail2ban ]] && cp -r fail2ban "$temp_dir/" || log_warn "fail2ban/ not found"
    if [[ "$include_secrets" == "true" ]]; then
        log_info "Including 'secrets' directory for emergency kit."
        if [[ -d secrets ]]; then cp -r secrets "$temp_dir/" || { log_error "Failed to copy secrets directory"; return 1; }
        else log_error "secrets/ directory required for emergency kit and not found."; return 1; fi
    else log_info "Skipping 'secrets' directory for 'full' backup."; fi
    log_info "Copying data directory (excluding live database)..."
    if [[ -d "$state_dir/data" ]]; then
        mkdir -p "$temp_dir/data" || { log_error "Failed to create data directory in temp location"; return 1; }
        rsync -a --delete --exclude 'bwdata/db.sqlite3*' "$state_dir/data/" "$temp_dir/data/" 2>/dev/null || { log_warn "rsync failed, falling back to 'cp'..."; cp -a "$state_dir/data/." "$temp_dir/data/" || { log_error "Failed to copy data directory"; return 1; }; }
        if [[ -f "$db_snapshot" ]]; then mkdir -p "$temp_dir/data/bwdata" && mv "$db_snapshot" "$temp_dir/data/db.sqlite3" || { log_error "Failed to include database snapshot in archive"; return 1; }; log_info "Included database snapshot in archive."; fi
    else log_warn "State data directory not found: $state_dir/data"; fi
}

create_full_backup() {
    log_info "Creating full system backup (config + data, NO secrets)..."
    local timestamp backup_dir encrypted_file state_dir db_file verification_mode is_running
    timestamp="$(date +%Y%m%d-%H%M%S)"; backup_dir="$PROJECT_ROOT/backups/full"; encrypted_file="$backup_dir/vw-full-backup-$timestamp.tar.gz.age"
    ensure_dir "$backup_dir" 755 || return 1
    check_backup_disk_space "$backup_dir" 2000 || return 1
    state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"; db_file="$state_dir/data/db.sqlite3"; verification_mode="$(get_verification_mode)"; is_running=$(is_service_running "vaultwarden" && echo "true" || echo "false")
    local temp_dir; temp_dir="$(mktemp -d)"; register_cleanup "rm -rf '$temp_dir'"
    create_archive_data "$temp_dir" "$verification_mode" "$is_running" "$state_dir" "$db_file" "$timestamp" "false" || return 1
    [[ $DRY_RUN == true ]] && { log_info "[DRY-RUN] Would create and verify 'full' archive"; return 0; }
    log_info "Creating and encrypting 'full' archive..."; tar -czf - -C "$temp_dir" . | encrypt_data > "$encrypted_file" || { log_error "Failed to create or encrypt 'full' archive"; return 1; }
    secure_file "$encrypted_file" 600 || return 1
    local checksum; checksum=$(calculate_sha256 "$encrypted_file") || { log_error "Failed to calculate checksum"; return 1; }
    echo "$checksum" > "$encrypted_file.sha256"
    verify_post_encryption_checksum "$encrypted_file" || { log_error "CRITICAL: Full backup created but failed post-encryption verification!"; return 1; }
    verify_backup_recoverability "$encrypted_file" "full" || { log_error "CRITICAL: Full backup created but failed recoverability verification!"; return 1; }
    generate_metadata "$encrypted_file" "full" "$timestamp" "$checksum" || log_warn "Failed to create metadata, but backup is valid"
    log_success "Full backup created and verified: $(basename "$encrypted_file")"
    echo "$encrypted_file"
}

create_emergency_kit() {
    log_info "Creating emergency recovery kit (config + data + secrets)..."
    local timestamp backup_dir encrypted_file state_dir db_file verification_mode is_running
    timestamp="$(date +%Y%m%d-%H%M%S)"; backup_dir="$PROJECT_ROOT/backups/emergency"; encrypted_file="$backup_dir/emergency-kit-$timestamp.tar.gz.age"
    ensure_dir "$backup_dir" 755 || return 1
    check_backup_disk_space "$backup_dir" 2000 || return 1
    state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"; db_file="$state_dir/data/db.sqlite3"; verification_mode="$(get_verification_mode)"; is_running=$(is_service_running "vaultwarden" && echo "true" || echo "false")
    local temp_dir; temp_dir="$(mktemp -d)"; register_cleanup "rm -rf '$temp_dir'"
    create_archive_data "$temp_dir" "$verification_mode" "$is_running" "$state_dir" "$db_file" "$timestamp" "true" || return 1
    [[ $DRY_RUN == true ]] && { log_info "[DRY-RUN] Would create and verify 'emergency' kit"; return 0; }
    log_info "Creating and encrypting 'emergency' kit archive..."; tar -czf - -C "$temp_dir" . | encrypt_data > "$encrypted_file" || { log_error "Failed to create or encrypt 'emergency' kit"; return 1; }
    secure_file "$encrypted_file" 600 || return 1
    local checksum; checksum=$(calculate_sha256 "$encrypted_file") || { log_error "Failed to calculate checksum"; return 1; }
    echo "$checksum" > "$encrypted_file.sha256"
    verify_post_encryption_checksum "$encrypted_file" || { log_error "CRITICAL: Emergency kit created but failed post-encryption verification!"; return 1; }
    verify_backup_recoverability "$encrypted_file" "emergency" || { log_error "CRITICAL: Emergency kit created but failed recoverability verification!"; return 1; }
    generate_metadata "$encrypted_file" "emergency" "$timestamp" "$checksum" || log_warn "Failed to create metadata, but backup is valid"
    log_success "Emergency kit created and verified: $(basename "$encrypted_file")"
    echo "$encrypted_file"
}

rclone_sync_offsite() {
    local backup_file_path="$1"
    log_info "Starting offsite backup sync..."
    has_command rclone || { log_error "rclone not found"; return 1; }
    local remote_name; remote_name="$(get_config_value "RCLONE_REMOTE_NAME" "")"
    if [[ -z "$remote_name" || "$remote_name" == "CHANGE_ME" ]]; then log_warn "RCLONE_REMOTE_NAME not configured. Skipping sync."; return 0; fi
    local remote_base_path backup_filename backup_type_dir remote_file_path
    remote_base_path="$remote_name:vaultwarden_backups"; backup_filename="$(basename "$backup_file_path")"; backup_type_dir="$(basename "$(dirname "$backup_file_path")")"; remote_file_path="$remote_base_path/$backup_type_dir/$backup_filename"
    log_info "Syncing '$backup_filename' to remote: $remote_file_path"
    rclone copyto "$backup_file_path" "$remote_file_path" || { log_error "Rclone sync failed"; return 1; }
    rclone copyto "$backup_file_path.sha256" "$remote_file_path.sha256" 2>/dev/null || true
    rclone copyto "$backup_file_path.meta" "$remote_file_path.meta" 2>/dev/null || true
    log_success "Rclone sync completed"
}

main() {
    if ! mkdir "$LOCKDIR" 2>/dev/null; then log_error "Another backup is already running (lock: $LOCKDIR)"; exit 1; fi
    register_cleanup "rmdir '$LOCKDIR' 2>/dev/null || true"
    if [[ $LIST_BACKUPS == true ]]; then list_backups && exit 0 || exit 1; fi
    log_info "VaultWarden Streamlined Backup Tool with Enhanced Verification"
    load_env_file || exit 1
    preflight_checks || exit 1
    local backup_file=""
    case "$BACKUP_TYPE" in db) backup_file="$(create_db_backup)" ;; full) backup_file="$(create_full_backup)" ;; emergency) backup_file="$(create_emergency_kit)" ;; *) log_error "Unknown backup type: $BACKUP_TYPE"; exit 1 ;; esac
    if [[ -z "$backup_file" ]]; then
        log_error "Backup creation or verification failed"
        [[ $EMAIL_NOTIFY == true ]] && send_notification_email "Backup FAILED: $BACKUP_TYPE" "Backup creation or verification failed."
        exit 1
    fi
    local sync_status="Skipped"; if [[ $RCLONE_SYNC == true ]]; then rclone_sync_offsite "$backup_file" && sync_status="Success" || sync_status="Failed"; fi
    log_success "Backup process completed!"
    local file_size checksum; file_size="$(du -h "$backup_file" | cut -f1)"; checksum="$(cat "$backup_file.sha256" 2>/dev/null || echo "N/A")"
    printf "\nBackup Details:\n  Type:         %s\n  File:         %s\n  Size:         %s\n  SHA256:       %s\n  Verification: Pre-snapshot OK + Post-encryption checksum OK + End-to-end verified (%s)\n  Rclone Sync:  %s\n\n" "$BACKUP_TYPE" "$backup_file" "$file_size" "$checksum" "$FULL_VERIFICATION" "$sync_status"
    if [[ $EMAIL_NOTIFY == true ]]; then
        log_info "Sending completion email..."
        send_notification_email "Backup Completed: $BACKUP_TYPE" "Backup job completed successfully with full verification.
File: $(basename "$backup_file")
Size: $file_size
Checksum: $checksum
Verification: Complete recoverability confirmed ($FULL_VERIFICATION) + post-encryption checksum verified
Sync: $sync_status"
    fi
    exit 0
}

main "$@"
