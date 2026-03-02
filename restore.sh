#!/usr/bin/env bash
# restore.sh - Enhanced VaultWarden-OCI restore script with safety checks
# Supports restoring database-only or full state backups

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/backup_utils.sh"
source "lib/crypto.sh"

# ---------------------------------------------------------------------------
# FIX #3 — Cleanup trap: remove plaintext /tmp files on any exit so that
# a SIGINT, SIGTERM, or set -e abort never leaves decrypted data on disk.
# setup_cleanup_trap() is exported by lib/common.sh.
# ---------------------------------------------------------------------------
_RESTORE_TEMP_FILES=()
_cleanup_temp_files() {
    local f
    for f in "${_RESTORE_TEMP_FILES[@]:-}"; do
        [[ -f "$f" ]] && rm -f "$f" && log_debug "Cleaned up temp file: $f"
    done
}
setup_cleanup_trap _cleanup_temp_files

# Configuration
BACKUP_FILE=""
TARGET_DIR=""
DRY_RUN=false
FORCE=false
LIST_ONLY=false

show_help() {
    cat << 'EOF'
VaultWarden-OCI Restore Script

USAGE:
    ./restore.sh [OPTIONS]

OPTIONS:
    --file FILE     Path to the backup file to restore (.age)
    --target DIR    Target directory for restore (default: read from .env or /var/lib/vaultwarden)
    --list          List available backups and exit
    --dry-run       Show what would be done without executing
    --force         Skip confirmation prompts and safety checks
    --help          Show this help

EXAMPLES:
    ./restore.sh --list
    ./restore.sh --file backups/db/db_backup_20240101_120000.sqlite3.age
    ./restore.sh --file backups/full/full_backup_20240101_120000.tar.gz.age --force
EOF
}

# Argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --file)     BACKUP_FILE="$2"; shift 2 ;;
        --target)   TARGET_DIR="$2"; shift 2 ;;
        --list)     LIST_ONLY=true; shift ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --force)    FORCE=true; shift ;;
        --help)     show_help; exit 0 ;;
        *)          log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

list_backups() {
    log_info "Available Database Backups:"
    if [[ -d "$PROJECT_ROOT/backups/db" ]]; then
        find "$PROJECT_ROOT/backups/db" -name "*.age" -type f -exec ls -lh {} \; | sort -r | head -n 10
    else
        echo "  None found."
    fi

    echo ""
    log_info "Available Full Backups:"
    if [[ -d "$PROJECT_ROOT/backups/full" ]]; then
        find "$PROJECT_ROOT/backups/full" -name "*.age" -type f -exec ls -lh {} \; | sort -r | head -n 10
    else
        echo "  None found."
    fi

    echo ""
    log_info "Available Emergency Backups:"
    if [[ -d "$PROJECT_ROOT/backups/emergency" ]]; then
        find "$PROJECT_ROOT/backups/emergency" -name "*.age" -type f -exec ls -lh {} \; | sort -r | head -n 10
    else
        echo "  None found."
    fi
}

get_target_dir() {
    if [[ -n "$TARGET_DIR" ]]; then
        echo "$TARGET_DIR"
    else
        get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden"
    fi
}

determine_backup_type() {
    local file="$1"
    local filename
    filename=$(basename "$file")

    if [[ -f "${file}.meta" ]]; then
        local type
        type=$(grep -m 1 "^type=" "${file}.meta" | cut -d= -f2)
        if [[ -n "$type" ]]; then
            echo "$type"
            return 0
        fi
    fi

    # Fallback to filename guessing
    if [[ "$filename" == *"db_backup"* || "$filename" == *".sqlite3.age" ]]; then
        echo "db"
    elif [[ "$filename" == *"full_backup"* || "$filename" == *".tar.gz.age" ]]; then
        echo "full"
    else
        log_error "Could not determine backup type for: $file"
        return 1
    fi
}

decrypt_backup() {
    local encrypted_file="$1"
    local decrypted_file="$2"

    # FIX #4 — Read AGE_KEY_FILE from .env (set by load_env_file in main())
    # with a fallback to the historical default path.  Consistent with how
    # every other configurable path in this file uses get_config_value.
    local age_key_file
    age_key_file=$(get_config_value "AGE_KEY_FILE" "secrets/keys/age-key.txt")

    if [[ ! -f "$age_key_file" ]]; then
        log_error "Age key file not found: $age_key_file"
        log_error "Set AGE_KEY_FILE in .env or place the key at secrets/keys/age-key.txt"
        return 1
    fi

    # Register decrypted output for cleanup trap before writing
    _RESTORE_TEMP_FILES+=("$decrypted_file")

    log_info "Decrypting backup file..."
    if age -d -i "$age_key_file" -o "$decrypted_file" "$encrypted_file"; then
        log_success "Backup decrypted successfully"
        return 0
    else
        log_error "Failed to decrypt backup. Verify the age key is correct."
        rm -f "$decrypted_file"
        return 1
    fi
}

restore_db() {
    local backup_file="$1"
    local state_dir="$2"

    local target_db="$state_dir/data/db.sqlite3"
    local temp_decrypted
    temp_decrypted=$(mktemp /tmp/vw_restore_db_XXXXXX.sqlite3)
    _RESTORE_TEMP_FILES+=("$temp_decrypted")

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would decrypt $backup_file and replace $target_db"
        return 0
    fi

    # 1. Decrypt
    if ! decrypt_backup "$backup_file" "$temp_decrypted"; then
        return 1
    fi

    # 2. Verify integrity via Docker (alpine+sqlite) — mirrors backup.sh fix
    #    (commit e1f1303). Avoids a hard dependency on a host sqlite3 binary;
    #    errors are surfaced (no 2>/dev/null suppression).
    log_info "Verifying database integrity (via alpine+sqlite container)..."
    local integrity_result
    integrity_result=$(
        docker run --rm \
            -v "${temp_decrypted}:/db.sqlite3" \
            alpine:latest \
            sh -c 'apk add -q sqlite && sqlite3 /db.sqlite3 "PRAGMA integrity_check;"'
    )
    if [[ "$integrity_result" != "ok" ]]; then
        log_error "Decrypted database failed integrity check! Aborting restore."
        log_error "SQLite output: ${integrity_result:-<empty>}"
        return 1
    fi
    log_success "Database integrity check passed"

    # 3. Create safety backup of current DB if it exists
    if [[ -f "$target_db" ]]; then
        local safety_backup="$state_dir/data/db.sqlite3.pre-restore-$(date +%Y%m%d-%H%M%S)"
        log_info "Creating safety backup of current database at $safety_backup"
        cp "$target_db" "$safety_backup"

        # Keep permissions of original
        local owner group perms
        owner=$(stat -c %U "$target_db" 2>/dev/null || echo "root")
        group=$(stat -c %G "$target_db" 2>/dev/null || echo "root")
        perms=$(stat -c %a "$target_db" 2>/dev/null || echo "644")
    else
        log_info "No existing database found. Creating new."
        # Use default permissions from .env or fallback
        local puid pgid
        puid=$(get_config_value "PUID" "1001")
        pgid=$(get_config_value "PGID" "1001")
        local owner="$puid"
        local group="$pgid"
        local perms="644"
    fi

    # 4. Replace database
    log_info "Restoring database..."

    # Make sure target directory exists
    mkdir -p "$(dirname "$target_db")"

    # Replace file
    cp "$temp_decrypted" "$target_db"

    # Set permissions
    chown "$owner:$group" "$target_db" 2>/dev/null || log_warn "Could not set ownership on $target_db"
    chmod "$perms" "$target_db" 2>/dev/null || log_warn "Could not set permissions on $target_db"

    # Clean up WAL/SHM files to prevent corruption with new DB
    rm -f "${target_db}-wal" "${target_db}-shm"

    log_success "Database restored successfully"
    return 0
}

restore_full() {
    local backup_file="$1"
    local state_dir="$2"

    local temp_decrypted
    temp_decrypted=$(mktemp /tmp/vw_restore_full_XXXXXX.tar.gz)
    _RESTORE_TEMP_FILES+=("$temp_decrypted")

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would decrypt $backup_file and extract to $state_dir and $PROJECT_ROOT"
        return 0
    fi

    # 1. Decrypt
    if ! decrypt_backup "$backup_file" "$temp_decrypted"; then
        return 1
    fi

    # 2. Verify archive integrity
    log_info "Verifying archive integrity..."
    if ! tar -tzf "$temp_decrypted" >/dev/null 2>&1; then
        log_error "Decrypted archive is invalid or corrupt! Aborting restore."
        return 1
    fi

    # FIX #5 — Path-traversal guard: scan every tar member and reject any
    # entry whose resolved absolute path falls outside the expected
    # STATE_DIR or PROJECT_ROOT prefixes before we write a single byte.
    log_info "Validating archive member paths..."
    local allowed_prefixes=("$state_dir" "$PROJECT_ROOT")
    local bad_entry=""
    while IFS= read -r member; do
        # Normalise: prepend / if not already absolute
        local abs_member="/${member#/}"
        local allowed=false
        local prefix
        for prefix in "${allowed_prefixes[@]}"; do
            if [[ "$abs_member" == "${prefix}"* ]]; then
                allowed=true
                break
            fi
        done
        if [[ "$allowed" == "false" ]]; then
            bad_entry="$member"
            break
        fi
    done < <(tar -tzf "$temp_decrypted")

    if [[ -n "$bad_entry" ]]; then
        log_error "Archive contains a path that escapes allowed directories: $bad_entry"
        log_error "Expected paths under: ${allowed_prefixes[*]}"
        log_error "Aborting restore — archive may be corrupt or tampered."
        return 1
    fi
    log_success "All archive paths validated"

    # 3. Create safety backup of current state
    log_info "Creating emergency full backup before restore..."
    if [[ -x "./backup.sh" ]]; then
        ./backup.sh --type emergency --quiet || log_warn "Failed to create emergency backup, proceeding anyway"
    else
        log_warn "Backup script not found, cannot create emergency pre-restore backup"
    fi

    # 4. Extract archive (safe: members were validated above)
    log_info "Extracting full backup... (this may take a moment)"
    if ! tar -xzf "$temp_decrypted" -C "/"; then
        log_error "Failed to extract backup archive"
        return 1
    fi

    log_success "Full state restored successfully"
    return 0
}

main() {
    require_root "$@"

    log_header "VaultWarden-OCI Restore Utility"

    if [[ "$LIST_ONLY" == "true" ]]; then
        list_backups
        exit 0
    fi

    if [[ -z "$BACKUP_FILE" ]]; then
        log_error "No backup file specified. Use --file to specify a backup."
        log_info "Use --list to see available backups."
        exit 1
    fi

    if [[ ! -f "$BACKUP_FILE" ]]; then
        log_error "Backup file not found: $BACKUP_FILE"
        exit 1
    fi

    if ! load_env_file; then
        log_error "Failed to load environment configuration"
        exit 1
    fi

    local target_dir
    target_dir=$(get_target_dir)

    local backup_type
    backup_type=$(determine_backup_type "$BACKUP_FILE") || exit 1

    log_info "Restore Configuration:"
    log_info "  Backup File: $BACKUP_FILE"
    log_info "  Backup Type: $backup_type"
    log_info "  Target Dir:  $target_dir"
    log_info "  Age Key:     $(get_config_value 'AGE_KEY_FILE' 'secrets/keys/age-key.txt')"

    # Warning & Confirmation
    if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" ]]; then
        echo ""
        log_warn "WARNING: This will overwrite current data!"
        log_warn "Services will be stopped during restoration."
        # FIX #1 — read -r -p: add -r to prevent backslash interpretation
        # (same fix applied to setup-secrets.sh in commit a9bd3db).
        read -r -p "Are you sure you want to proceed? (y/N) " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Restore cancelled."
            exit 0
        fi
    fi

    # Stop services if running
    local services_were_running=false
    if [[ "$DRY_RUN" == "false" ]]; then
        if docker compose ps | grep -q "Up"; then
            services_were_running=true
            log_info "Stopping services before restore..."
            docker compose stop
        fi
    fi

    # Perform restore
    local restore_success=false

    if [[ "$backup_type" == "db" ]]; then
        restore_db "$BACKUP_FILE" "$target_dir" && restore_success=true
    elif [[ "$backup_type" == "full" ]]; then
        restore_full "$BACKUP_FILE" "$target_dir" && restore_success=true
    else
        log_error "Unknown backup type: $backup_type"
    fi

    # Restart services if they were running
    if [[ "$DRY_RUN" == "false" && "$services_were_running" == "true" ]]; then
        log_info "Restarting services..."
        docker compose start

        # Verify health
        if [[ "$restore_success" == "true" ]]; then
            log_info "Waiting for services to initialize..."
            sleep 5
            if [[ -x "./health.sh" ]]; then
                ./health.sh --quiet || log_warn "Services started but health check reported issues"
            fi
        fi
    fi

    if [[ "$restore_success" == "true" ]]; then
        log_success "Restore completed successfully!"
        exit 0
    else
        log_error "Restore failed."
        exit 1
    fi
}

main "$@"
