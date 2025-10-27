#!/usr/bin/env bash
# backup.sh - Simplified VaultWarden backup creation with library integration

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

# --- Configuration ---
BACKUP_TYPE="db"  # db, full, or emergency
EMAIL_NOTIFY=false
RCLONE_SYNC=false
LIST_BACKUPS=false

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden-OCI-NG Backup Tool

USAGE:
    ./backup.sh [OPTIONS]
    ./backup.sh --list

STANDARD BACKUP OPTIONS:
    --type TYPE      Backup type: db, full, or emergency (default: db)
    --rclone         Sync backup to rclone remote after creation
    --email          Send email notification on completion
    --help           Show this help

LISTING OPTIONS:
    --list           List available local backups (db, full, emergency)

BACKUP TYPES:
    db         Database only (fast, daily use)
    full       Complete system backup (weekly use)
    emergency  Disaster recovery kit (manual use)

EXAMPLES:
    ./backup.sh                    # Quick database backup
    ./backup.sh --type full        # Full system backup
    ./backup.sh --type emergency   # Create emergency kit
    ./backup.sh --rclone --email   # Backup, sync to cloud, and send email
    ./backup.sh --list             # List all local backups
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --type) BACKUP_TYPE="$2"; shift 2 ;;
        --email) EMAIL_NOTIFY=true; shift ;;
        --rclone) RCLONE_SYNC=true; shift ;;
        --list) LIST_BACKUPS=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- List Backups Function ---
# Function to list backups - also used by restore.sh (logic duplicated there)
list_backups() {
    log_info "Available local backups:"
    echo ""
    local backup_base_dir="$PROJECT_ROOT/backups"
    local found_backups_details=() # Store lines for later printing
    local counter=1

    # --- START FIX #2: NUL/newline mismatch ---
    # Use find with printf to get timestamp and path, sort numerically, read line by line
    local find_cmd
    find_cmd="find \"$backup_base_dir/db\" \"$backup_base_dir/full\" \"$backup_base_dir/emergency\" -maxdepth 1 -name '*.age' -type f -printf '%T@ %p\n' 2>/dev/null"

    local sorted_files
    sorted_files=$(eval "$find_cmd" | sort -nr)
    # --- END FIX #2 ---

    if [[ -z "$sorted_files" ]]; then
        log_warn "No local backups found in ./backups/{db,full,emergency}/"
        return 1
    fi

    local max_lines=0 # Count lines found
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue # Skip empty lines

        # Extract path (everything after the first space)
        local file="${line#* }"
        local filename type timestamp date_str time_str size
        filename=$(basename "$file")
        size=$(du -h "$file" | cut -f1)

        # --- START FIX #1: BASH_REMATCH check (Regex remains, indices were correct) ---
        if [[ $filename =~ ^vw-(db|full)-backup-([0-9]{8})-([0-9]{6})\.sqlite3\.gz\.age$ ]]; then
            type="${BASH_REMATCH[1]}"
            date_str="${BASH_REMATCH[2]}"
            time_str="${BASH_REMATCH[3]}"
        elif [[ $filename =~ ^emergency-kit-([0-9]{8})-([0-9]{6})\.tar\.gz\.age$ ]]; then
            type="emergency"
            date_str="${BASH_REMATCH[1]}"
            time_str="${BASH_REMATCH[2]}" # Corrected index was already applied
        else
            type="unknown"
            date_str="--------"
            time_str="------"
        fi
        # --- END FIX #1 ---

        local formatted_date="${date_str:0:4}-${date_str:4:2}-${date_str:6:2}"
        local formatted_time="${time_str:0:2}:${time_str:2:2}:${time_str:4:2}"
        local padded_type
        printf -v padded_type "%-11s" "$type"

        # Store formatted line
        found_backups_details+=("$(printf "%3d | %s | %s | %s | %6s | %s" "$counter" "$padded_type" "$formatted_date" "$formatted_time" "$size" "$filename")")
        ((counter++))
        ((max_lines++))
    done <<< "$sorted_files"

    if [[ $max_lines -eq 0 ]]; then
      log_warn "No local backups found matching expected patterns."
      return 1
    fi

    echo " ID | Type        | Date       | Time     | Size   | Filename"
    echo "----|-------------|------------|----------|--------|------------------------------------------"
    # Print stored lines
    printf '%s\n' "${found_backups_details[@]}"
    echo "----|-------------|------------|----------|--------|------------------------------------------"
    echo ""
    return 0
}


# --- Backup Functions ---

# Helper function to check live DB integrity
check_live_db_integrity() {
    local db_file="$1"
    local container_running=$2

    log_info "Verifying live database integrity before backup..."
    local integrity_check_cmd="sqlite3 \"$db_file\" \"PRAGMA integrity_check;\""
    local integrity_result=""

    if [[ "$container_running" == "true" ]]; then
        integrity_result=$(exec_in_service vaultwarden sh -c "$integrity_check_cmd" 2>/dev/null) || true
    else
        if [[ -f "$db_file" ]]; then
            integrity_result=$(eval "$integrity_check_cmd" 2>/dev/null) || true
        else
            log_error "Live database file not found: $db_file"
            return 1
        fi
    fi

    if [[ "$integrity_result" == "ok" ]]; then
        log_success "Live database integrity check passed."
        return 0
    else
        log_error "Live database integrity check FAILED: $integrity_result"
        log_error "Aborting backup to prevent backing up corrupted data."
        return 1
    fi
}


create_db_backup() {
    log_info "Creating database backup..."

    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_dir="$PROJECT_ROOT/backups/db"
    local backup_file="vw-db-backup-$timestamp.sqlite3.gz"
    local encrypted_file="$backup_dir/$backup_file.age"
    local state_dir db_file is_running

    ensure_dir "$backup_dir" 755

    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    db_file="$state_dir/data/bwdata/db.sqlite3"
    local container_db_path="/data/db.sqlite3"

    is_running=$(is_service_running "vaultwarden" && echo "true" || echo "false")

    if [[ "$is_running" == "true" ]]; then
         check_live_db_integrity "$container_db_path" "$is_running" || return 1
    else
         check_live_db_integrity "$db_file" "$is_running" || return 1
    fi

    if [[ "$is_running" == "true" ]]; then
        log_info "Creating database snapshot from running container..."
        if ! exec_in_service vaultwarden sqlite3 "$container_db_path" ".backup /tmp/backup.db"; then
            log_error "Failed to create database snapshot inside container"
            return 1
        fi
        log_info "Verifying database snapshot integrity..."
        local integrity_check
        integrity_check=$(exec_in_service vaultwarden sqlite3 /tmp/backup.db "PRAGMA integrity_check;" 2>/dev/null)
        if [[ "$integrity_check" != "ok" ]]; then
            log_error "Database snapshot integrity check failed: $integrity_check"
            exec_in_service vaultwarden rm -f /tmp/backup.db 2>/dev/null || true
            return 1
        fi
        log_success "Database snapshot integrity verified"
        log_info "Compressing and saving snapshot..."
        if ! docker compose exec vaultwarden cat /tmp/backup.db | gzip > "$backup_dir/$backup_file"; then
            log_error "Failed to copy database snapshot from container"
            exec_in_service vaultwarden rm -f /tmp/backup.db 2>/dev/null || true
            return 1
        fi
        exec_in_service vaultwarden rm -f /tmp/backup.db 2>/dev/null || true
    else
        log_info "Backing up database from filesystem (container stopped)..."
        if [[ ! -f "$db_file" ]]; then log_error "Database file not found: $db_file"; return 1; fi
        log_info "Compressing database file..."
        if ! gzip -c "$db_file" > "$backup_dir/$backup_file"; then log_error "Failed to compress database file"; return 1; fi
    fi

    log_info "Encrypting backup file..."
    if ! encrypt_file "$backup_dir/$backup_file" "$encrypted_file"; then
        rm -f "$backup_dir/$backup_file" 2>/dev/null
        log_error "Failed to encrypt backup"; return 1
    fi

    rm -f "$backup_dir/$backup_file"
    secure_file "$encrypted_file" 600 || { log_error "Failed to secure backup file permissions"; return 1; }

    log_success "Database backup created: $(basename "$encrypted_file")"

    log_info "Verifying encrypted backup..."
    if ! decrypt_file "$encrypted_file" "/dev/null"; then
        log_error "CRITICAL: Backup verification FAILED!"
        log_warn "Deleting corrupt backup file: $encrypted_file"
        rm -f "$encrypted_file"
        return 1
    fi
    log_success "Encrypted backup verified successfully."

    echo "$encrypted_file"
    return 0
}

create_full_backup() {
    log_info "Creating full system backup..."

    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_dir="$PROJECT_ROOT/backups/full"
    local backup_file="vw-full-backup-$timestamp.tar.gz"
    local encrypted_file="$backup_dir/$backup_file.age"
    local state_dir db_file is_running

    ensure_dir "$backup_dir" 755

    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    db_file="$state_dir/data/bwdata/db.sqlite3"
    local container_db_path="/data/db.sqlite3"

    is_running=$(is_service_running "vaultwarden" && echo "true" || echo "false")

    if [[ "$is_running" == "true" ]]; then
         check_live_db_integrity "$container_db_path" "$is_running" || return 1
    else
         check_live_db_integrity "$db_file" "$is_running" || return 1
    fi

    local temp_dir
    temp_dir=$(mktemp -d)
    setup_cleanup_trap "rm -rf '$temp_dir'"

    log_info "Gathering configuration files..."
    [[ -f docker-compose.yml ]] && cp docker-compose.yml "$temp_dir/" || log_warn "docker-compose.yml not found"
    [[ -f .env ]] && cp .env "$temp_dir/" || log_warn ".env not found"
    [[ -d caddy ]] && cp -r caddy "$temp_dir/" || log_warn "caddy/ directory not found"
    [[ -d fail2ban ]] && cp -r fail2ban "$temp_dir/" || log_warn "fail2ban/ directory not found"
    [[ -d secrets ]] && cp -r secrets "$temp_dir/" || log_warn "secrets/ directory not found"

    local db_snapshot="$temp_dir/db.sqlite3.snapshot"
    log_info "Creating consistent database snapshot..."
    if [[ "$is_running" == "true" ]]; then
        if ! exec_in_service vaultwarden sqlite3 "$container_db_path" ".backup /tmp/backup.db"; then log_error "Failed to create snapshot"; return 1; fi
        local integrity_check=$(exec_in_service vaultwarden sqlite3 /tmp/backup.db "PRAGMA integrity_check;" 2>/dev/null)
        if [[ "$integrity_check" != "ok" ]]; then log_error "Snapshot integrity check failed: $integrity_check"; exec_in_service vaultwarden rm -f /tmp/backup.db 2>/dev/null || true; return 1; fi
        log_success "Snapshot integrity verified"
        if ! docker compose exec vaultwarden cat /tmp/backup.db > "$db_snapshot"; then log_error "Failed to copy snapshot"; exec_in_service vaultwarden rm -f /tmp/backup.db 2>/dev/null || true; return 1; fi
        exec_in_service vaultwarden rm -f /tmp/backup.db 2>/dev/null || true
    else
        log_info "Container stopped, copying database file directly..."
        if [[ -f "$db_file" ]]; then
             local integrity_check=$(sqlite3 "$db_file" "PRAGMA integrity_check;" 2>/dev/null) || true
             if [[ "$integrity_check" != "ok" ]]; then log_error "DB integrity check failed: $integrity_check"; log_warn "Backup may contain corrupted data."; fi
             cp "$db_file" "$db_snapshot"
        else
            log_warn "DB file not found, backup incomplete."
        fi
    fi

    log_info "Copying data directory..."
    if [[ -d "$state_dir/data" ]]; then
        mkdir -p "$temp_dir/data"
        # --- START FIX #3: Fallback copy logic ---
        if command -v rsync >/dev/null 2>&1; then
             if ! rsync -a --delete --exclude 'bwdata/db.sqlite3*' "$state_dir/data/" "$temp_dir/data/"; then
                 log_warn "Rsync failed, falling back to cp"
                 cp -a "$state_dir/data/"* "$temp_dir/data/" 2>/dev/null || true
             fi
        else
             cp -a "$state_dir/data/"* "$temp_dir/data/" 2>/dev/null || true
        fi
        # --- END FIX #3 ---
        if [[ -f "$db_snapshot" ]]; then
            mkdir -p "$temp_dir/data/bwdata"
            mv "$db_snapshot" "$temp_dir/data/bwdata/db.sqlite3"
            log_info "Included safe database snapshot."
        else
             log_warn "No database snapshot available."
        fi
    else
        log_warn "State data directory not found: $state_dir/data"
    fi

    local domain admin_email
    domain=$(get_config_value "DOMAIN" "N/A"); admin_email=$(get_config_value "ADMIN_EMAIL" "N/A")
    cat > "$temp_dir/backup-info.txt" << EOF
VaultWarden-OCI-NG Full Backup
Created: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Host: $(hostname -f 2>/dev/null || hostname)
Domain: $domain
Admin Email: $admin_email
EOF

    log_info "Creating compressed archive..."
    if ! tar -czf "$backup_dir/$backup_file" -C "$temp_dir" .; then log_error "Failed archive creation"; return 1; fi

    log_info "Encrypting backup file..."
    if ! encrypt_file "$backup_dir/$backup_file" "$encrypted_file"; then rm -f "$backup_dir/$backup_file" 2>/dev/null; log_error "Failed encryption"; return 1; fi

    rm -f "$backup_dir/$backup_file"
    secure_file "$encrypted_file" 600 || { log_error "Failed permission setting"; return 1; }

    log_success "Full backup created: $(basename "$encrypted_file")"

    log_info "Verifying encrypted backup..."
    if ! decrypt_file "$encrypted_file" "/dev/null"; then
        log_error "CRITICAL: Backup verification FAILED!"; log_warn "Deleting corrupt backup file."; rm -f "$encrypted_file"; return 1
    fi
    log_success "Encrypted backup verified."

    echo "$encrypted_file"
    return 0
}

create_emergency_kit() {
    log_info "Creating emergency recovery kit..."
    # Similar logic to full backup, adjusted for kit structure

    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_dir="$PROJECT_ROOT/backups/emergency"
    local kit_file="emergency-kit-$timestamp.tar.gz"
    local encrypted_file="$backup_dir/$kit_file.age"
    local state_dir db_file is_running

    ensure_dir "$backup_dir" 755

    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    db_file="$state_dir/data/bwdata/db.sqlite3"
    local container_db_path="/data/db.sqlite3"

    local temp_dir
    temp_dir=$(mktemp -d)
    setup_cleanup_trap "rm -rf '$temp_dir'"

    log_info "Preparing recovery files..."
    [[ -f docker-compose.yml ]] && cp docker-compose.yml "$temp_dir/" || { log_error "docker-compose.yml required"; return 1; }
    [[ -f .env ]] && cp .env "$temp_dir/" || { log_error ".env required"; return 1; }
    [[ -d caddy ]] && cp -r caddy "$temp_dir/" || { log_error "caddy/ required"; return 1; }
    [[ -d fail2ban ]] && cp -r fail2ban "$temp_dir/" || log_warn "fail2ban/ not found"
    [[ -d secrets ]] && cp -r secrets "$temp_dir/" || { log_error "secrets/ required"; return 1; }

    mkdir -p "$temp_dir/data"
    local db_snapshot="$temp_dir/db.sqlite3.snapshot"
    is_running=$(is_service_running "vaultwarden" && echo "true" || echo "false")

    if [[ "$is_running" == "true" ]]; then
         log_info "Attempting consistent snapshot for kit..."
        if exec_in_service vaultwarden sqlite3 "$container_db_path" ".backup /tmp/backup.db" && \
           [[ "$(exec_in_service vaultwarden sqlite3 /tmp/backup.db "PRAGMA integrity_check;" 2>/dev/null)" == "ok" ]] && \
           docker compose exec vaultwarden cat /tmp/backup.db > "$db_snapshot"; then
            log_success "Created verified snapshot for kit."
        else
            log_warn "Failed snapshot, kit data might be inconsistent."
            [[ -f "$db_snapshot" ]] && rm -f "$db_snapshot"
        fi
        exec_in_service vaultwarden rm -f /tmp/backup.db 2>/dev/null || true
    fi

     log_info "Copying data contents for kit..."
    if [[ -d "$state_dir/data" ]]; then
        # --- START FIX #3: Fallback copy logic ---
        if [[ -f "$db_snapshot" ]]; then
             if command -v rsync >/dev/null 2>&1; then
                 if ! rsync -a --delete --exclude 'bwdata/db.sqlite3*' "$state_dir/data/" "$temp_dir/data/"; then
                      log_warn "Rsync failed, falling back to cp"
                      cp -a "$state_dir/data/"* "$temp_dir/data/" 2>/dev/null || true
                      rm -f "$temp_dir/data/bwdata/db.sqlite3"*
                 fi
             else
                 cp -a "$state_dir/data/"* "$temp_dir/data/" 2>/dev/null || true
                 rm -f "$temp_dir/data/bwdata/db.sqlite3"*
             fi
             mkdir -p "$temp_dir/data/bwdata"
             mv "$db_snapshot" "$temp_dir/data/bwdata/db.sqlite3"
        else
             log_warn "No snapshot, copying live data files."
              if command -v rsync >/dev/null 2>&1; then
                  if ! rsync -a --delete "$state_dir/data/" "$temp_dir/data/"; then
                       log_warn "Rsync failed, falling back to cp"
                       cp -a "$state_dir/data/"* "$temp_dir/data/" 2>/dev/null || true
                  fi
             else
                  cp -a "$state_dir/data/"* "$temp_dir/data/" 2>/dev/null || true
             fi
        fi
         # --- END FIX #3 ---
    else
        log_warn "State data directory not found. Kit incomplete."
    fi

    # Recovery documentation (Keep as is)
    cat > "$temp_dir/RECOVERY.md" << 'EOF'
# VaultWarden Emergency Recovery

## Quick Recovery Steps
1. Set up new Ubuntu 24.04 server (or similar Debian-based).
2. Extract this kit: `age -d -i secrets/keys/age-key.txt emergency-kit-*.tar.gz.age | tar -xzf - -C /path/to/restore`
3. Install dependencies: `sudo apt update && sudo apt install -y docker.io docker-compose-plugin age sops nano rclone sqlite3 argon2 jq mailutils ufw curl`
4. Copy extracted files to project directory (e.g., `/opt/vaultwarden`).
5. Set ownership: `sudo chown -R your_user:your_group /opt/vaultwarden` (Replace your_user:your_group).
6. Set secure permissions: `chmod 600 /opt/vaultwarden/.env /opt/vaultwarden/secrets/secrets.yaml /opt/vaultwarden/secrets/keys/age-key.txt`.
7. Set executable permissions: `chmod +x /opt/vaultwarden/*.sh`.
8. Start services: `cd /opt/vaultwarden && ./startup.sh`.
9. Update DNS record for your domain to point to the new server IP.
10. Check health: `./health.sh --comprehensive`.

## Files Included
- docker-compose.yml - Container configuration
- .env - Environment variables
- caddy/ - Reverse proxy configuration
- fail2ban/ - Security configuration
- secrets/ - Encrypted secrets (including Age keys)
- data/ - VaultWarden database and files (snapshot if possible)

## Important Notes
- **CRITICAL:** Keep Age private key (secrets/keys/age-key.txt) secure and backed up separately! Without it, this kit is useless.
- This kit restores the exact state at the time of creation.
- Verify firewall allows SSH port (check .env `SSH_PORT`) and ports 80/443 from Cloudflare IPs (run `sudo ./update-cloudflare-ips.sh` after startup if needed).

Recovery Time: ~15-30 minutes with proper preparation.
EOF

    local domain admin_email
    domain=$(get_config_value "DOMAIN" "N/A"); admin_email=$(get_config_value "ADMIN_EMAIL" "N/A")
    cat > "$temp_dir/kit-info.txt" << EOF
Emergency Kit Created: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Source Host: $(hostname -f 2>/dev/null || hostname)
Domain: $domain
Kit Version: Simplified v1.1
EOF

    log_info "Creating encrypted emergency kit archive..."
    if ! tar -czf "$backup_dir/$kit_file" -C "$temp_dir" .; then log_error "Failed kit archive"; return 1; fi

    log_info "Encrypting kit file..."
    if ! encrypt_file "$backup_dir/$kit_file" "$encrypted_file"; then rm -f "$backup_dir/$kit_file" 2>/dev/null; log_error "Failed kit encryption"; return 1; fi

    rm -f "$backup_dir/$kit_file"
    secure_file "$encrypted_file" 600 || { log_error "Failed kit permission setting"; return 1; }

    log_success "Emergency kit created: $(basename "$encrypted_file")"

    log_info "Verifying encrypted kit..."
    if ! decrypt_file "$encrypted_file" "/dev/null"; then
        log_error "CRITICAL: Kit verification FAILED!"; log_warn "Deleting corrupt kit file."; rm -f "$encrypted_file"; return 1
    fi
    log_success "Encrypted kit verified."

    log_warn "IMPORTANT: Store kit and Age key separately and securely!"
    echo "$encrypted_file"
    return 0
}

rclone_sync_offsite() {
    local backup_file_path="$1"
    # ... (rclone logic remains the same) ...
    log_info "Starting offsite backup sync..."

    if ! has_command rclone; then log_error "rclone not found."; return 1; fi

    local remote_name=$(get_config_value "RCLONE_REMOTE_NAME" "")
    if [[ -z "$remote_name" ]] || [[ "$remote_name" == "CHANGE_ME" ]]; then log_warn "RCLONE_REMOTE_NAME not configured. Skipping sync."; return 0; fi

    local remote_base_path="$remote_name:vaultwarden_backups"
    local backup_filename=$(basename "$backup_file_path")
    local backup_type_dir=$(basename "$(dirname "$backup_file_path")")
    local remote_file_path="$remote_base_path/$backup_type_dir/$backup_filename"

    log_info "Syncing '$backup_filename' to remote: $remote_file_path"
    if ! rclone copyto "$backup_file_path" "$remote_file_path"; then log_error "Rclone sync failed"; return 1; fi
    log_success "Rclone sync completed"

    log_info "Verifying remote file size..."
    local local_size=$(stat -c%s "$backup_file_path" 2>/dev/null || echo "0")
    local remote_size_json remote_size
    for _ in 1 2 3; do remote_size_json=$(rclone size "$remote_file_path" --json 2>/dev/null); [[ -n "$remote_size_json" ]] && break; sleep 2; done
    if [[ -z "$remote_size_json" ]]; then log_warn "Could not get remote size for verification."; return 0; fi
    remote_size=$(echo "$remote_size_json" | jq -r '.bytes // 0')
    if [[ "$local_size" == "$remote_size" ]]; then log_success "Cloud backup size verified: $local_size bytes"; else log_warn "Cloud backup size mismatch! Local: $local_size, Remote: $remote_size"; fi

    return 0
}


# --- Main Execution ---
main() {
    if [[ "$LIST_BACKUPS" == "true" ]]; then
        list_backups
        exit $?
    fi

    log_info "VaultWarden Backup Tool"
    load_env_file || exit 1
    require_commands tar gzip age sqlite3 || exit 1
    [[ "$RCLONE_SYNC" == "true" ]] && require_commands rclone jq || exit 1
    [[ "$EMAIL_NOTIFY" == "true" ]] && require_commands mail || exit 1
    if ! check_age_key; then log_error "Age key not available"; exit 1; fi

    local backup_file="" backup_exit_code=0 rclone_exit_code=0 overall_exit_code=0

    case "$BACKUP_TYPE" in
        "db") backup_file=$(create_db_backup) || backup_exit_code=$? ;;
        "full") backup_file=$(create_full_backup) || backup_exit_code=$? ;;
        "emergency") backup_file=$(create_emergency_kit) || backup_exit_code=$? ;;
        *) log_error "Unknown backup type: $BACKUP_TYPE"; exit 1 ;;
    esac

    if [[ $backup_exit_code -ne 0 ]] || [[ -z "$backup_file" ]]; then
        log_error "Local backup creation failed."
        [[ "$EMAIL_NOTIFY" == "true" ]] && send_notification_email "Backup FAILED: $BACKUP_TYPE (Local Creation)" "Local backup creation failed."
        exit 1
    fi

    local file_size=$(du -h "$backup_file" | cut -f1)
    local sync_status="Skipped"
    if [[ "$RCLONE_SYNC" == "true" ]]; then
        if rclone_sync_offsite "$backup_file"; then sync_status="Success"; else sync_status="Failed"; rclone_exit_code=1; fi
    fi

    if [[ $rclone_exit_code -ne 0 ]]; then overall_exit_code=1; log_error "Backup done locally, but rclone sync FAILED."; else log_success "Backup completed successfully!"; fi

    echo ""; echo "Backup Details:"; echo "  Type: $BACKUP_TYPE"; echo "  File: $backup_file"; echo "  Size: $file_size"; echo "  Rclone Sync: $sync_status"; echo "";
    echo "To restore:"; echo "  ./restore.sh '$backup_file'"; echo "  Or use interactive restore: ./restore.sh --interactive (or 'make restore')"

    if [[ "$EMAIL_NOTIFY" == "true" ]]; then
        if [[ $overall_exit_code -eq 0 ]]; then
            log_info "Sending completion email..."
            send_notification_email "Backup Completed: $BACKUP_TYPE" "VaultWarden backup job completed successfully.\nType: $BACKUP_TYPE\nFile: $(basename "$backup_file")\nSize: $file_size\nRclone Sync: $sync_status"
        else
            log_info "Sending failure email..."
            send_notification_email "Backup FAILED: $BACKUP_TYPE (Rclone Sync)" "VaultWarden backup job completed locally but FAILED to sync offsite.\nType: $BACKUP_TYPE\nLocal File: $(basename "$backup_file")\nLocal Size: $file_size\nRclone Sync Status: $sync_status"
        fi
    fi

    exit $overall_exit_code
}

main "$@"

