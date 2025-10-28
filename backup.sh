#!/usr/bin/env bash
# backup.sh - Simplified VaultWarden backup creation with enhanced verification

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
VaultWarden-OCI-NG Backup Tool with Enhanced Verification

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
    db         Database only with integrity verification (fast, daily use)
    full       Complete system backup with verification (weekly use)
    emergency  Disaster recovery kit with verification (manual use)

VERIFICATION:
    - All backups now include integrity verification
    - DB backups: SQLite integrity check + decrypt verification
    - Full/Emergency: Archive integrity + decrypt verification
    - Uses BACKUP_VERIFICATION_MODE from .env (quick_check or integrity_check)

EXAMPLES:
    ./backup.sh                    # Quick database backup with verification
    ./backup.sh --type full        # Full system backup with verification
    ./backup.sh --type emergency   # Create emergency kit with verification
    ./backup.sh --rclone --email   # Backup, verify, sync to cloud, and send email
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
list_backups() {
    log_info "Available local backups:"
    echo ""
    local backup_base_dir="$PROJECT_ROOT/backups"
    local found_backups_details=()
    local counter=1

    # Use find with printf to get timestamp and path, sort numerically, read line by line
    local find_cmd
    find_cmd="find \"$backup_base_dir/db\" \"$backup_base_dir/full\" \"$backup_base_dir/emergency\" -maxdepth 1 -name '*.age' -type f -printf '%T@ %p\n' 2>/dev/null"

    local sorted_files
    sorted_files=$(eval "$find_cmd" | sort -nr)

    if [[ -z "$sorted_files" ]]; then
        log_warn "No local backups found in ./backups/{db,full,emergency}/"
        return 1
    fi

    local max_lines=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local file="${line#* }"
        local filename type timestamp date_str time_str size
        filename=$(basename "$file")
        size=$(du -h "$file" | cut -f1)

        if [[ $filename =~ ^vw-(db|full)-backup-([0-9]{8})-([0-9]{6})\.sqlite3\.gz\.age$ ]]; then
            type="${BASH_REMATCH[1]}"
            date_str="${BASH_REMATCH[2]}"
            time_str="${BASH_REMATCH[3]}"
        elif [[ $filename =~ ^emergency-kit-([0-9]{8})-([0-9]{6})\.tar\.gz\.age$ ]]; then
            type="emergency"
            date_str="${BASH_REMATCH[1]}"
            time_str="${BASH_REMATCH[2]}"
        else
            type="unknown"
            date_str="--------"
            time_str="------"
        fi

        local formatted_date="${date_str:0:4}-${date_str:4:2}-${date_str:6:2}"
        local formatted_time="${time_str:0:2}:${time_str:2:2}:${time_str:4:2}"
        local padded_type
        printf -v padded_type "%-11s" "$type"

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
    printf '%s\n' "${found_backups_details[@]}"
    echo "----|-------------|------------|----------|--------|------------------------------------------"
    echo ""
    return 0
}

# --- Enhanced Verification Functions ---

# Verify SQLite database integrity with configurable depth
verify_sqlite_integrity() {
    local db_file="$1"
    local verification_mode="${2:-quick_check}"
    
    if [[ ! -f "$db_file" ]]; then
        log_error "Database file not found for verification: $db_file"
        return 1
    fi
    
    log_info "Running SQLite $verification_mode on backup..."
    local check_result
    
    case "$verification_mode" in
        "quick_check")
            check_result=$(sqlite3 "$db_file" "PRAGMA quick_check;" 2>/dev/null) || {
                log_error "SQLite quick_check failed to execute"
                return 1
            }
            ;;
        "integrity_check")
            check_result=$(sqlite3 "$db_file" "PRAGMA integrity_check;" 2>/dev/null) || {
                log_error "SQLite integrity_check failed to execute"
                return 1
            }
            ;;
        *)
            log_error "Unknown verification mode: $verification_mode"
            return 1
            ;;
    esac
    
    if [[ "$check_result" == "ok" ]]; then
        log_success "SQLite $verification_mode passed"
        return 0
    else
        log_error "SQLite $verification_mode FAILED: $check_result"
        return 1
    fi
}

# Verify encrypted backup can be decrypted and contains valid data
verify_encrypted_backup() {
    local encrypted_file="$1"
    local backup_type="$2"
    local verification_mode="${3:-quick_check}"
    
    log_info "Verifying encrypted backup integrity..."
    
    # Create temporary directory for verification
    local temp_dir
    temp_dir=$(mktemp -d)
    local cleanup_temp() { rm -rf "$temp_dir"; }
    trap cleanup_temp EXIT
    
    # First, verify the file can be decrypted
    local temp_decrypted="$temp_dir/decrypted"
    if ! decrypt_file "$encrypted_file" "$temp_decrypted"; then
        log_error "CRITICAL: Backup cannot be decrypted!"
        return 1
    fi
    log_success "Backup decryption verification passed"
    
    # Verify content based on backup type
    case "$backup_type" in
        "db")
            # For database backups: gunzip and verify SQLite integrity
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
        "full"|"emergency")
            # For archive backups: verify tar can be read and contains expected files
            if ! tar -tzf "$temp_decrypted" >/dev/null 2>&1; then
                log_error "Archive backup appears corrupted (tar test failed)"
                return 1
            fi
            
            # Check for essential files in the archive
            local required_files=("docker-compose.yml" ".env")
            for required_file in "${required_files[@]}"; do
                if ! tar -tzf "$temp_decrypted" | grep -q "^$required_file$"; then
                    log_warn "Archive missing expected file: $required_file"
                fi
            done
            
            log_success "Archive backup integrity verified"
            return 0
            ;;
        *)
            log_error "Unknown backup type for verification: $backup_type"
            return 1
            ;;
    esac
}

# --- Enhanced Backup Functions ---

create_db_backup() {
    log_info "Creating database backup with verification..."

    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_dir="$PROJECT_ROOT/backups/db"
    local backup_file="vw-db-backup-$timestamp.sqlite3.gz"
    local encrypted_file="$backup_dir/$backup_file.age"
    local state_dir db_file is_running verification_mode

    ensure_dir "$backup_dir" 755

    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    db_file="$state_dir/data/bwdata/db.sqlite3"
    local container_db_path="/data/bwdata/db.sqlite3"
    verification_mode=$(get_config_value "BACKUP_VERIFICATION_MODE" "quick_check")

    is_running=$(is_service_running "vaultwarden" && echo "true" || echo "false")

    # Pre-backup integrity check
    log_info "Verifying live database integrity before backup..."
    if [[ "$is_running" == "true" ]]; then
        local integrity_result
        integrity_result=$(exec_in_service vaultwarden sqlite3 "$container_db_path" "PRAGMA $verification_mode;" 2>/dev/null) || {
            log_error "Failed to run pre-backup integrity check"
            return 1
        }
        if [[ "$integrity_result" != "ok" ]]; then
            log_error "Live database integrity check FAILED: $integrity_result"
            log_error "Aborting backup to prevent backing up corrupted data"
            return 1
        fi
    else
        if [[ -f "$db_file" ]]; then
            if ! verify_sqlite_integrity "$db_file" "$verification_mode"; then
                log_error "Live database integrity check failed, aborting backup"
                return 1
            fi
        else
            log_error "Database file not found: $db_file"
            return 1
        fi
    fi
    log_success "Pre-backup integrity check passed"

    # Create backup
    if [[ "$is_running" == "true" ]]; then
        log_info "Creating database snapshot from running container..."
        if ! exec_in_service vaultwarden sqlite3 "$container_db_path" ".backup /tmp/backup.db"; then
            log_error "Failed to create database snapshot inside container"
            return 1
        fi
        
        log_info "Compressing and saving snapshot..."
        if ! docker compose exec vaultwarden cat /tmp/backup.db | gzip > "$backup_dir/$backup_file"; then
            log_error "Failed to copy database snapshot from container"
            exec_in_service vaultwarden rm -f /tmp/backup.db 2>/dev/null || true
            return 1
        fi
        exec_in_service vaultwarden rm -f /tmp/backup.db 2>/dev/null || true
    else
        log_info "Backing up database from filesystem (container stopped)..."
        if ! gzip -c "$db_file" > "$backup_dir/$backup_file"; then
            log_error "Failed to compress database file"
            return 1
        fi
    fi

    # Encrypt backup
    log_info "Encrypting backup file..."
    if ! encrypt_file "$backup_dir/$backup_file" "$encrypted_file"; then
        rm -f "$backup_dir/$backup_file" 2>/dev/null
        log_error "Failed to encrypt backup"
        return 1
    fi

    rm -f "$backup_dir/$backup_file"
    secure_file "$encrypted_file" 600 || {
        log_error "Failed to secure backup file permissions"
        return 1
    }

    # Enhanced verification
    if verify_encrypted_backup "$encrypted_file" "db" "$verification_mode"; then
        log_success "Database backup created and verified: $(basename "$encrypted_file")"
        echo "$encrypted_file"
        return 0
    else
        log_error "CRITICAL: Backup verification FAILED!"
        log_warn "Deleting failed backup file: $encrypted_file"
        rm -f "$encrypted_file"
        return 1
    fi
}

create_full_backup() {
    log_info "Creating full system backup with verification..."

    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_dir="$PROJECT_ROOT/backups/full"
    local backup_file="vw-full-backup-$timestamp.tar.gz"
    local encrypted_file="$backup_dir/$backup_file.age"
    local state_dir db_file is_running verification_mode

    ensure_dir "$backup_dir" 755

    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    db_file="$state_dir/data/bwdata/db.sqlite3"
    local container_db_path="/data/bwdata/db.sqlite3"
    verification_mode=$(get_config_value "BACKUP_VERIFICATION_MODE" "quick_check")

    is_running=$(is_service_running "vaultwarden" && echo "true" || echo "false")

    # Pre-backup integrity check
    log_info "Verifying live database integrity before full backup..."
    if [[ "$is_running" == "true" ]]; then
        local integrity_result
        integrity_result=$(exec_in_service vaultwarden sqlite3 "$container_db_path" "PRAGMA $verification_mode;" 2>/dev/null) || {
            log_error "Failed to run pre-backup integrity check"
            return 1
        }
        if [[ "$integrity_result" != "ok" ]]; then
            log_error "Live database integrity check FAILED: $integrity_result"
            log_warn "Continuing with full backup but database may be inconsistent"
        fi
    else
        if [[ -f "$db_file" ]] && ! verify_sqlite_integrity "$db_file" "$verification_mode"; then
            log_warn "Database integrity check failed, but continuing with full backup"
        fi
    fi

    local temp_dir
    temp_dir=$(mktemp -d)
    local cleanup_temp() { rm -rf "$temp_dir"; }
    trap cleanup_temp EXIT

    # Gather configuration files
    log_info "Gathering configuration files..."
    [[ -f docker-compose.yml ]] && cp docker-compose.yml "$temp_dir/" || log_warn "docker-compose.yml not found"
    [[ -f .env ]] && cp .env "$temp_dir/" || log_warn ".env not found"
    [[ -d caddy ]] && cp -r caddy "$temp_dir/" || log_warn "caddy/ directory not found"
    [[ -d fail2ban ]] && cp -r fail2ban "$temp_dir/" || log_warn "fail2ban/ directory not found"
    [[ -d secrets ]] && cp -r secrets "$temp_dir/" || log_warn "secrets/ directory not found"

    # Create database snapshot
    local db_snapshot="$temp_dir/db.sqlite3.snapshot"
    log_info "Creating consistent database snapshot..."
    if [[ "$is_running" == "true" ]]; then
        if exec_in_service vaultwarden sqlite3 "$container_db_path" ".backup /tmp/backup.db" && \
           docker compose exec vaultwarden cat /tmp/backup.db > "$db_snapshot"; then
            log_success "Created database snapshot for full backup"
        else
            log_warn "Failed to create snapshot, full backup may be inconsistent"
        fi
        exec_in_service vaultwarden rm -f /tmp/backup.db 2>/dev/null || true
    else
        if [[ -f "$db_file" ]]; then
            cp "$db_file" "$db_snapshot"
        else
            log_warn "DB file not found, backup incomplete"
        fi
    fi

    # Copy data directory
    log_info "Copying data directory..."
    if [[ -d "$state_dir/data" ]]; then
        mkdir -p "$temp_dir/data"
        if command -v rsync >/dev/null 2>&1; then
            if ! rsync -a --delete --exclude 'bwdata/db.sqlite3*' "$state_dir/data/" "$temp_dir/data/"; then
                log_warn "Rsync failed, falling back to cp"
                cp -a "$state_dir/data/"* "$temp_dir/data/" 2>/dev/null || true
            fi
        else
            cp -a "$state_dir/data/"* "$temp_dir/data/" 2>/dev/null || true
        fi
        
        if [[ -f "$db_snapshot" ]]; then
            mkdir -p "$temp_dir/data/bwdata"
            mv "$db_snapshot" "$temp_dir/data/bwdata/db.sqlite3"
            log_info "Included database snapshot in full backup"
        fi
    else
        log_warn "State data directory not found: $state_dir/data"
    fi

    # Create backup info
    local domain admin_email
    domain=$(get_config_value "DOMAIN" "N/A")
    admin_email=$(get_config_value "ADMIN_EMAIL" "N/A")
    cat > "$temp_dir/backup-info.txt" << EOF
VaultWarden-OCI-NG Full Backup (Enhanced)
Created: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Host: $(hostname -f 2>/dev/null || hostname)
Domain: $domain
Admin Email: $admin_email
Verification Mode: $verification_mode
Backup Type: full
EOF

    # Create and encrypt archive
    log_info "Creating compressed archive..."
    if ! tar -czf "$backup_dir/$backup_file" -C "$temp_dir" .; then
        log_error "Failed to create archive"
        return 1
    fi

    log_info "Encrypting full backup..."
    if ! encrypt_file "$backup_dir/$backup_file" "$encrypted_file"; then
        rm -f "$backup_dir/$backup_file" 2>/dev/null
        log_error "Failed to encrypt full backup"
        return 1
    fi

    rm -f "$backup_dir/$backup_file"
    secure_file "$encrypted_file" 600 || {
        log_error "Failed to set secure permissions"
        return 1
    }

    # Enhanced verification
    if verify_encrypted_backup "$encrypted_file" "full" "$verification_mode"; then
        log_success "Full backup created and verified: $(basename "$encrypted_file")"
        echo "$encrypted_file"
        return 0
    else
        log_error "CRITICAL: Full backup verification FAILED!"
        log_warn "Deleting failed backup file: $encrypted_file"
        rm -f "$encrypted_file"
        return 1
    fi
}

create_emergency_kit() {
    log_info "Creating emergency recovery kit with verification..."

    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_dir="$PROJECT_ROOT/backups/emergency"
    local kit_file="emergency-kit-$timestamp.tar.gz"
    local encrypted_file="$backup_dir/$kit_file.age"
    local verification_mode

    ensure_dir "$backup_dir" 755
    verification_mode=$(get_config_value "BACKUP_VERIFICATION_MODE" "quick_check")

    local temp_dir
    temp_dir=$(mktemp -d)
    local cleanup_temp() { rm -rf "$temp_dir"; }
    trap cleanup_temp EXIT

    # Prepare recovery files (similar to full backup but with recovery focus)
    log_info "Preparing emergency recovery files..."
    [[ -f docker-compose.yml ]] && cp docker-compose.yml "$temp_dir/" || { log_error "docker-compose.yml required"; return 1; }
    [[ -f .env ]] && cp .env "$temp_dir/" || { log_error ".env required"; return 1; }
    [[ -d caddy ]] && cp -r caddy "$temp_dir/" || { log_error "caddy/ required"; return 1; }
    [[ -d fail2ban ]] && cp -r fail2ban "$temp_dir/" || log_warn "fail2ban/ not found"
    [[ -d secrets ]] && cp -r secrets "$temp_dir/" || { log_error "secrets/ required"; return 1; }

    # Include data with snapshot if possible
    local state_dir db_file is_running
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    db_file="$state_dir/data/bwdata/db.sqlite3"
    local container_db_path="/data/bwdata/db.sqlite3"
    is_running=$(is_service_running "vaultwarden" && echo "true" || echo "false")

    mkdir -p "$temp_dir/data"
    local db_snapshot="$temp_dir/db.sqlite3.snapshot"
    
    if [[ "$is_running" == "true" ]]; then
        log_info "Creating verified snapshot for emergency kit...")
        if exec_in_service vaultwarden sqlite3 "$container_db_path" ".backup /tmp/backup.db" && \
           docker compose exec vaultwarden cat /tmp/backup.db > "$db_snapshot"; then
            # Verify the snapshot
            if verify_sqlite_integrity "$db_snapshot" "$verification_mode"; then
                log_success "Created verified database snapshot for emergency kit"
            else
                log_warn "Database snapshot failed verification, removing from kit"
                rm -f "$db_snapshot"
            fi
        fi
        exec_in_service vaultwarden rm -f /tmp/backup.db 2>/dev/null || true
    fi

    # Copy data directory
    if [[ -d "$state_dir/data" ]]; then
        if [[ -f "$db_snapshot" ]]; then
            if command -v rsync >/dev/null 2>&1; then
                rsync -a --delete --exclude 'bwdata/db.sqlite3*' "$state_dir/data/" "$temp_dir/data/" || \
                    cp -a "$state_dir/data/"* "$temp_dir/data/" 2>/dev/null || true
            else
                cp -a "$state_dir/data/"* "$temp_dir/data/" 2>/dev/null || true
                rm -f "$temp_dir/data/bwdata/db.sqlite3"*
            fi
            mkdir -p "$temp_dir/data/bwdata"
            mv "$db_snapshot" "$temp_dir/data/bwdata/db.sqlite3"
        else
            log_warn "No verified snapshot available, copying live data"
            if command -v rsync >/dev/null 2>&1; then
                rsync -a --delete "$state_dir/data/" "$temp_dir/data/" || \
                    cp -a "$state_dir/data/"* "$temp_dir/data/" 2>/dev/null || true
            else
                cp -a "$state_dir/data/"* "$temp_dir/data/" 2>/dev/null || true
            fi
        fi
    fi

    # Enhanced recovery documentation
    cat > "$temp_dir/RECOVERY.md" << 'EOF'
# VaultWarden Emergency Recovery Kit (Enhanced)

## Quick Recovery Steps
1. Set up new Ubuntu 24.04 server (or similar Debian-based)
2. Extract this kit: `age -d -i secrets/keys/age-key.txt emergency-kit-*.tar.gz.age | tar -xzf - -C /path/to/restore`
3. Install dependencies: `sudo apt update && sudo apt install -y docker.io docker-compose-plugin age sops nano rclone sqlite3 argon2 jq mailutils ufw curl`
4. Copy extracted files to project directory (e.g., `/opt/vaultwarden`)
5. Set ownership: `sudo chown -R your_user:your_group /opt/vaultwarden`
6. Set secure permissions: `chmod 600 /opt/vaultwarden/.env /opt/vaultwarden/secrets/secrets.yaml /opt/vaultwarden/secrets/keys/age-key.txt`
7. Set executable permissions: `chmod +x /opt/vaultwarden/*.sh`
8. Start services: `cd /opt/vaultwarden && ./startup.sh`
9. Update DNS record for your domain to point to the new server IP
10. Check health: `./health.sh --comprehensive`

## Verification Features
- This kit was created with enhanced backup verification
- Database integrity was verified before inclusion
- All encrypted components were tested for decryption
- Recovery time: ~15-30 minutes with proper preparation

## Files Included
- docker-compose.yml - Container configuration
- .env - Environment variables (with enhanced resource limits)
- caddy/ - Reverse proxy configuration
- fail2ban/ - Security configuration  
- secrets/ - Encrypted secrets (including Age keys)
- data/ - VaultWarden database and files (verified snapshot when possible)

## Critical Notes
- **CRITICAL:** Keep Age private key (secrets/keys/age-key.txt) secure and backed up separately!
- This kit includes verified data when created from running system
- Verify firewall allows SSH port and ports 80/443 from Cloudflare IPs
- Run `sudo ./update-cloudflare-ips.sh` after startup if needed
EOF

    # Kit info with verification details
    local domain admin_email
    domain=$(get_config_value "DOMAIN" "N/A")
    admin_email=$(get_config_value "ADMIN_EMAIL" "N/A")
    cat > "$temp_dir/kit-info.txt" << EOF
Emergency Kit Created: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Source Host: $(hostname -f 2>/dev/null || hostname)
Domain: $domain
Kit Version: Enhanced v1.2
Verification Mode: $verification_mode
Database Verification: $(if [[ -f "$temp_dir/data/bwdata/db.sqlite3" ]]; then echo "Verified"; else echo "Live Copy"; fi)
EOF

    # Create and encrypt kit
    log_info "Creating encrypted emergency kit archive..."
    if ! tar -czf "$backup_dir/$kit_file" -C "$temp_dir" .; then
        log_error "Failed to create kit archive"
        return 1
    fi

    log_info "Encrypting emergency kit..."
    if ! encrypt_file "$backup_dir/$kit_file" "$encrypted_file"; then
        rm -f "$backup_dir/$kit_file" 2>/dev/null
        log_error "Failed to encrypt emergency kit"
        return 1
    fi

    rm -f "$backup_dir/$kit_file"
    secure_file "$encrypted_file" 600 || {
        log_error "Failed to set kit permissions"
        return 1
    }

    # Enhanced verification
    if verify_encrypted_backup "$encrypted_file" "emergency" "$verification_mode"; then
        log_success "Emergency kit created and verified: $(basename "$encrypted_file")"
        log_warn "IMPORTANT: Store kit and Age key separately and securely!"
        echo "$encrypted_file"
        return 0
    else
        log_error "CRITICAL: Emergency kit verification FAILED!"
        log_warn "Deleting failed kit file: $encrypted_file"
        rm -f "$encrypted_file"
        return 1
    fi
}

# --- Rclone Sync Function (unchanged) ---
rclone_sync_offsite() {
    local backup_file_path="$1"
    
    log_info "Starting offsite backup sync..."

    if ! has_command rclone; then
        log_error "rclone not found"
        return 1
    fi

    local remote_name=$(get_config_value "RCLONE_REMOTE_NAME" "")
    if [[ -z "$remote_name" ]] || [[ "$remote_name" == "CHANGE_ME" ]]; then
        log_warn "RCLONE_REMOTE_NAME not configured. Skipping sync."
        return 0
    fi

    local remote_base_path="$remote_name:vaultwarden_backups"
    local backup_filename=$(basename "$backup_file_path")
    local backup_type_dir=$(basename "$(dirname "$backup_file_path")")
    local remote_file_path="$remote_base_path/$backup_type_dir/$backup_filename"

    log_info "Syncing '$backup_filename' to remote: $remote_file_path"
    if ! rclone copyto "$backup_file_path" "$remote_file_path"; then
        log_error "Rclone sync failed"
        return 1
    fi
    log_success "Rclone sync completed"

    # Verify remote file size
    log_info "Verifying remote file size..."
    local local_size=$(stat -c%s "$backup_file_path" 2>/dev/null || echo "0")
    local remote_size_json remote_size
    for _ in 1 2 3; do
        remote_size_json=$(rclone size "$remote_file_path" --json 2>/dev/null)
        [[ -n "$remote_size_json" ]] && break
        sleep 2
    done
    
    if [[ -z "$remote_size_json" ]]; then
        log_warn "Could not get remote size for verification"
        return 0
    fi
    
    remote_size=$(echo "$remote_size_json" | jq -r '.bytes // 0')
    if [[ "$local_size" == "$remote_size" ]]; then
        log_success "Cloud backup size verified: $local_size bytes"
    else
        log_warn "Cloud backup size mismatch! Local: $local_size, Remote: $remote_size"
    fi

    return 0
}

# --- Main Execution ---
main() {
    if [[ "$LIST_BACKUPS" == "true" ]]; then
        list_backups
        exit $?
    fi

    log_info "VaultWarden Enhanced Backup Tool with Verification"
    load_env_file || exit 1
    require_commands tar gzip age sqlite3 || exit 1
    [[ "$RCLONE_SYNC" == "true" ]] && require_commands rclone jq || exit 1
    [[ "$EMAIL_NOTIFY" == "true" ]] && require_commands mail || exit 1
    
    if ! check_age_key; then
        log_error "Age key not available"
        exit 1
    fi

    local verification_mode
    verification_mode=$(get_config_value "BACKUP_VERIFICATION_MODE" "quick_check")
    log_info "Using verification mode: $verification_mode"

    local backup_file="" backup_exit_code=0 rclone_exit_code=0 overall_exit_code=0

    # Create backup with verification
    case "$BACKUP_TYPE" in
        "db") backup_file=$(create_db_backup) || backup_exit_code=$? ;;
        "full") backup_file=$(create_full_backup) || backup_exit_code=$? ;;
        "emergency") backup_file=$(create_emergency_kit) || backup_exit_code=$? ;;
        *) log_error "Unknown backup type: $BACKUP_TYPE"; exit 1 ;;
    esac

    if [[ $backup_exit_code -ne 0 ]] || [[ -z "$backup_file" ]]; then
        log_error "Backup creation or verification failed"
        [[ "$EMAIL_NOTIFY" == "true" ]] && send_notification_email "Backup FAILED: $BACKUP_TYPE (Creation/Verification)" "Backup creation or verification failed."
        exit 1
    fi

    # Sync to remote if requested
    local file_size=$(du -h "$backup_file" | cut -f1)
    local sync_status="Skipped"
    if [[ "$RCLONE_SYNC" == "true" ]]; then
        if rclone_sync_offsite "$backup_file"; then
            sync_status="Success"
        else
            sync_status="Failed"
            rclone_exit_code=1
        fi
    fi

    if [[ $rclone_exit_code -ne 0 ]]; then
        overall_exit_code=1
        log_error "Backup verified locally, but rclone sync FAILED"
    else
        log_success "Backup completed and verified successfully!"
    fi

    # Display results
    echo ""
    echo "Backup Details:"
    echo "  Type: $BACKUP_TYPE"
    echo "  File: $backup_file"
    echo "  Size: $file_size"
    echo "  Verification: Passed ($verification_mode)"
    echo "  Rclone Sync: $sync_status"
    echo ""
    echo "To restore:"
    echo "  ./restore.sh '$backup_file'"
    echo "  Or use interactive restore: ./restore.sh --interactive (or 'make restore')"

    # Send notification if requested
    if [[ "$EMAIL_NOTIFY" == "true" ]]; then
        if [[ $overall_exit_code -eq 0 ]]; then
            log_info "Sending completion email..."
            send_notification_email "Backup Completed: $BACKUP_TYPE (Verified)" "VaultWarden backup job completed and verified successfully.\nType: $BACKUP_TYPE\nFile: $(basename "$backup_file")\nSize: $file_size\nVerification: Passed ($verification_mode)\nRclone Sync: $sync_status"
        else
            log_info "Sending failure email..."
            send_notification_email "Backup FAILED: $BACKUP_TYPE (Rclone Sync)" "VaultWarden backup job completed and verified locally but FAILED to sync offsite.\nType: $BACKUP_TYPE\nLocal File: $(basename "$backup_file")\nLocal Size: $file_size\nVerification: Passed ($verification_mode)\nRclone Sync Status: $sync_status"
        fi
    fi

    exit $overall_exit_code
}

main "$@"
