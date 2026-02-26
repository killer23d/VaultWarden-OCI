#!/usr/bin/env bash
# backup.sh - Streamlined VaultWarden backup script with enhanced verification
#
# FIXES APPLIED (2026-02):
#   [ITEM 2]  CRITICAL  - Wrapped bare cp in create_archive_data with if/else so
#                         docker compose start always runs even on disk-full.
#   [ITEM 5]  HIGH      - Replaced internet-dependent alpine/apk add sqlite with
#                         the already-pulled vaultwarden image to avoid WAN dependency.
#   [ITEM 6]  HIGH      - Replaced eval-based cleanup handler with a safe indexed
#                         array of temp paths cleaned up with direct rm calls.
#   [ITEM 7]  HIGH      - Added DRY_RUN gate at the top of create_archive_data so
#                         --dry-run no longer stops/starts the real container.
#   [ITEM 9]  MEDIUM    - Moved LOCKDIR from /var/run (requires root) to /tmp.
#   [ITEM 11] MINOR     - Fixed unquoted nested command substitution in
#                         rclone_sync_offsite to handle paths with spaces.

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

# Load key resilience library
if [[ -f "lib/simple_key_resilience.sh" ]]; then
    source "lib/simple_key_resilience.sh"
else
    # Fallback stub if library missing during migration
    simple_verify_age_key() { log_debug "Key resilience lib missing, skipping check"; return 0; }
fi

# Configuration
BACKUP_TYPE="db"
EMAIL_NOTIFY=false
RCLONE_SYNC=false
LIST_BACKUPS=false
DRY_RUN=false
FULL_VERIFICATION=false

# FIX [ITEM 9]: Use /tmp instead of /var/run so non-root users can create the lock.
LOCKDIR="/tmp/vaultwarden-backup.lock"

# FIX [ITEM 6]: Safe cleanup - store paths to remove, never use eval.
# Each entry is a plain filesystem path; cleanup iterates in reverse and uses
# direct rm calls, eliminating the path-injection risk of eval.
CLEANUP_FILES=()
CLEANUP_DIRS=()

register_cleanup_file() { CLEANUP_FILES+=("$1"); }
register_cleanup_dir()  { CLEANUP_DIRS+=("$1");  }

perform_cleanup() {
    local i
    for (( i=${#CLEANUP_FILES[@]}-1; i>=0; i-- )); do
        rm -f  "${CLEANUP_FILES[$i]}" 2>/dev/null || true
    done
    for (( i=${#CLEANUP_DIRS[@]}-1;  i>=0; i-- )); do
        rm -rf "${CLEANUP_DIRS[$i]}"  2>/dev/null || true
    done
}
trap perform_cleanup EXIT

# Log overrides to stderr so stdout returns only filenames for scripting
log_info()    { echo -e "${COLOR_BLUE}[$(date +'%H:%M:%S')] [INFO]${COLOR_RESET} [backup] $*"    >&2; }
log_success() { echo -e "${COLOR_GREEN}[$(date +'%H:%M:%S')] [SUCCESS]${COLOR_RESET} [backup] $*" >&2; }
log_warn()    { echo -e "${COLOR_YELLOW}[$(date +'%H:%M:%S')] [WARN]${COLOR_RESET} [backup] $*"   >&2; }
log_error()   { echo -e "${COLOR_RED}[$(date +'%H:%M:%S')] [ERROR]${COLOR_RESET} [backup] $*"   >&2; }

show_help() {
    cat << 'EOF'
VaultWarden-OCI-NG Streamlined Backup Tool

USAGE:
  ./backup.sh [OPTIONS]

OPTIONS:
    --type TYPE                   Backup type: db, full, or emergency (default: db)
    --rclone                      Sync backup to rclone remote
    --email                       Send email notification
    --dry-run                     Preview operations
    --list                        List available backups
    --full-verification           Enable end-to-end recoverability test
    --help                        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type)              BACKUP_TYPE="$2"; shift 2 ;;
        --email)             EMAIL_NOTIFY=true; shift ;;
        --rclone)            RCLONE_SYNC=true; shift ;;
        --list)              LIST_BACKUPS=true; shift ;;
        --dry-run)           DRY_RUN=true; shift ;;
        --full-verification) FULL_VERIFICATION=true; shift ;;
        --help)              show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

preflight_checks() {
    log_info "Running pre-flight checks..."
    require_docker || return 1
    require_commands tar gzip age rsync || return 1

    export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}"
    if ! simple_verify_age_key; then
        log_error "CRITICAL: Age key verification failed. Backup aborted."
        return 1
    fi

    log_success "Pre-flight checks passed"
}

get_verification_mode() {
    local mode
    mode=$(get_config_value "BACKUP_VERIFICATION_MODE" "quick_check")
    echo "$mode"
}

# FIX [ITEM 5]: Use the already-pulled vaultwarden image instead of spinning up
# a fresh Alpine container that requires an internet download of sqlite on every
# run.  If VaultWarden is not running we fall back to a read-only one-shot
# container from the same image tag so no extra pull is ever needed.
verify_sqlite_integrity() {
    local db_file="$1"
    local verification_mode="${2:-quick_check}"

    log_info "Verifying database integrity ($verification_mode)..."

    local check_cmd
    case "$verification_mode" in
        quick_check)     check_cmd="PRAGMA quick_check;" ;;
        integrity_check) check_cmd="PRAGMA integrity_check;" ;;
        *)               check_cmd="PRAGMA quick_check;" ;;
    esac

    local dir_name file_name result
    dir_name=$(dirname  "$db_file")
    file_name=$(basename "$db_file")

    # Use the vaultwarden image (already present on disk) to avoid any WAN call.
    # docker compose run picks up the correct image tag from docker-compose.yml.
    result=$(docker compose run --rm -T \
        -v "${dir_name}:/check:ro" \
        --entrypoint sqlite3 \
        vaultwarden "/check/${file_name}" "${check_cmd}" 2>/dev/null) || true

    if [[ "$result" == "ok" ]]; then
        log_success "SQLite integrity check passed"
        return 0
    else
        log_error "SQLite verification FAILED: $result"
        return 1
    fi
}

verify_backup_recoverability() {
    local encrypted_file="$1" backup_type="$2"
    if [[ "$FULL_VERIFICATION" != "true" ]]; then return 0; fi
    [[ "$DRY_RUN" == "true" ]] && return 0

    log_info "Performing end-to-end recoverability verification..."

    local verify_temp_dir
    verify_temp_dir=$(mktemp -d)
    register_cleanup_dir "$verify_temp_dir"

    case "$backup_type" in
        "db")
            local test_db="$verify_temp_dir/test.db"
            age -d -i "$SOPS_AGE_KEY_FILE" "$encrypted_file" | gzip -d > "$test_db"
            verify_sqlite_integrity "$test_db" "quick_check" || return 1
            ;;
        "full"|"emergency")
            age -d -i "$SOPS_AGE_KEY_FILE" "$encrypted_file" | tar -xzf - -C "$verify_temp_dir"
            if [[ -f "$verify_temp_dir/data/db.sqlite3" ]]; then
                verify_sqlite_integrity "$verify_temp_dir/data/db.sqlite3" "quick_check"
            fi
            ;;
    esac
    log_success "End-to-end recoverability verified"
}

# Standardized metadata generation
generate_metadata() {
    local encrypted_file="$1" backup_type="$2" timestamp="$3" checksum="$4"
    local vw_version="unknown"
    if is_service_running "vaultwarden"; then
        vw_version=$(docker compose exec -T vaultwarden /vaultwarden --version 2>/dev/null | head -1 || echo "unknown")
    fi
    local file_size
    file_size=$(stat -c%s "$encrypted_file")

    cat > "$encrypted_file.meta" <<EOF
backup_type=$backup_type
timestamp=$timestamp
hostname=$(hostname)
verification_mode=$(get_verification_mode)
full_verification=$FULL_VERIFICATION
vaultwarden_version=$vw_version
file_size=$file_size
sha256=$checksum
EOF
}

create_db_backup() {
    log_info "Creating database backup..."
    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"
    local backup_dir="$PROJECT_ROOT/backups/db"
    local encrypted_file="$backup_dir/vw-db-backup-${timestamp}.sqlite3.gz.age"

    ensure_dir "$backup_dir" 755 || return 1
    check_backup_disk_space "$backup_dir" 500 || return 1

    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")

    local host_temp="${state_dir}/data/backup_temp_${timestamp}.sqlite3"
    local db_file="${state_dir}/data/db.sqlite3"
    register_cleanup_file "$host_temp"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would stop, copy DB, start, and encrypt"
        return 0
    fi

    if [[ ! -f "$db_file" ]]; then
        log_error "Database file not found: $db_file"
        return 1
    fi

    log_info "Creating consistent snapshot via Stop-Copy-Start strategy..."

    # --- Critical Section ---
    log_info "Stopping VaultWarden..."
    docker compose stop vaultwarden

    log_info "Copying database file..."
    # Container always restarts regardless of cp result (correctly handled here).
    if cp "$db_file" "$host_temp"; then
        log_info "Database copied successfully."
        docker compose start vaultwarden
    else
        log_error "Failed to copy database file!"
        docker compose start vaultwarden
        return 1
    fi
    # --- End Critical Section ---

    if [[ ! -f "$host_temp" ]]; then
        log_error "Snapshot file not found at expected host path: $host_temp"
        return 1
    fi

    verify_sqlite_integrity "$host_temp" "$(get_verification_mode)" || return 1

    # Encrypt to a temp file first; only move into final place on success so
    # no dangling corrupt artifact is left behind on a partial write.
    local encrypted_tmp="${encrypted_file}.tmp"
    register_cleanup_file "$encrypted_tmp"
    log_info "Compressing and encrypting..."
    if ! gzip -c "$host_temp" | encrypt_data > "$encrypted_tmp"; then
        log_error "Compression/encryption pipeline failed"
        return 1
    fi
    mv "$encrypted_tmp" "$encrypted_file"
    secure_file "$encrypted_file" 600

    local checksum
    checksum=$(calculate_sha256 "$encrypted_file")
    echo "$checksum" > "$encrypted_file.sha256"
    verify_backup_recoverability "$encrypted_file" "db"
    generate_metadata "$encrypted_file" "db" "$timestamp" "$checksum"

    log_success "Database backup created: $(basename "$encrypted_file")"
    echo "$encrypted_file"
}

create_archive_data() {
    local temp_dir="$1" include_secrets="$2"

    # FIX [ITEM 7]: Honour --dry-run BEFORE the Stop-Copy-Start so we never
    # actually stop a live container during a dry-run invocation.
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would assemble archive data (no container stop)"
        return 0
    fi

    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")

    # 1. Config files
    cp "$PROJECT_ROOT/docker-compose.yml" "$temp_dir/" 2>/dev/null || true
    cp "$PROJECT_ROOT/.env"               "$temp_dir/" 2>/dev/null || true
    [[ -d "$PROJECT_ROOT/caddy"    ]] && cp -r "$PROJECT_ROOT/caddy"    "$temp_dir/"
    [[ -d "$PROJECT_ROOT/fail2ban" ]] && cp -r "$PROJECT_ROOT/fail2ban" "$temp_dir/"

    # 2. Secrets (if emergency)
    if [[ "$include_secrets" == "true" ]]; then
        [[ -d "$PROJECT_ROOT/secrets" ]] && cp -r "$PROJECT_ROOT/secrets" "$temp_dir/"
    fi

    # 3. Data Directory (excluding live DB)
    mkdir -p "$temp_dir/data"
    if [[ -d "$state_dir/data" ]]; then
        rsync -a --delete \
            --exclude 'db.sqlite3*' \
            --exclude 'bwdata/db.sqlite3*' \
            "$state_dir/data/" "$temp_dir/data/"
    fi

    # 4. DB Snapshot (Stop-Copy-Start)
    # FIX [ITEM 2]: Wrap cp in an if/else so docker compose start ALWAYS runs
    # even when cp fails (e.g. disk full).  This mirrors the correct pattern
    # already present in create_db_backup().
    local db_file="${state_dir}/data/db.sqlite3"
    if [[ -f "$db_file" ]]; then
        log_info "Snapshotting database for archive (Stop-Copy-Start)..."
        docker compose stop vaultwarden

        if cp "$db_file" "$temp_dir/data/db.sqlite3"; then
            docker compose start vaultwarden
            if [[ -f "$temp_dir/data/db.sqlite3" ]]; then
                verify_sqlite_integrity "$temp_dir/data/db.sqlite3" "quick_check" \
                    || log_warn "Database integrity check failed, but continuing with archive."
            fi
        else
            docker compose start vaultwarden
            log_error "Failed to copy database for archive! (Disk full?)"
            return 1
        fi
    else
        log_warn "DB file not found, backup will be incomplete."
    fi
}

create_full_backup() {
    log_info "Creating full backup..."
    local type="${1:-full}"  # 'full' or 'emergency'
    local include_secrets="false"
    [[ "$type" == "emergency" ]] && include_secrets="true"

    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"
    local backup_dir="$PROJECT_ROOT/backups/$type"
    local encrypted_file="$backup_dir/${type}-backup-${timestamp}.tar.gz.age"

    ensure_dir "$backup_dir" 755 || return 1

    local temp_dir
    temp_dir=$(mktemp -d)
    register_cleanup_dir "$temp_dir"

    # create_archive_data now handles its own DRY_RUN gate internally.
    create_archive_data "$temp_dir" "$include_secrets" || return 1

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Archive staged at $temp_dir (not encrypted)"
        return 0
    fi

    local encrypted_tmp="${encrypted_file}.tmp"
    register_cleanup_file "$encrypted_tmp"
    if ! tar -czf - -C "$temp_dir" . | encrypt_data > "$encrypted_tmp"; then
        log_error "Archive encryption pipeline failed"
        return 1
    fi
    mv "$encrypted_tmp" "$encrypted_file"
    secure_file "$encrypted_file" 600

    local checksum
    checksum=$(calculate_sha256 "$encrypted_file")
    echo "$checksum" > "$encrypted_file.sha256"
    verify_backup_recoverability "$encrypted_file" "$type"
    generate_metadata "$encrypted_file" "$type" "$timestamp" "$checksum"

    log_success "$type backup created: $(basename "$encrypted_file")"
    echo "$encrypted_file"
}

rclone_sync_offsite() {
    local backup_file="$1"
    local remote_name
    remote_name=$(get_config_value "RCLONE_REMOTE_NAME" "")

    if [[ -z "$remote_name" || "$remote_name" == "CHANGE_ME"* ]]; then
        log_warn "Rclone remote not configured, skipping sync."
        return 0
    fi

    log_info "Syncing to remote: $remote_name"
    # FIX [ITEM 11]: Quote the nested command substitutions to handle paths
    # containing spaces correctly.
    local filename type_dir dest
    filename=$(basename "$backup_file")
    type_dir=$(basename "$(dirname "$backup_file")")
    dest="$remote_name:vaultwarden_backups/$type_dir/$filename"

    if rclone copyto "$backup_file" "$dest"; then
        rclone copyto "$backup_file.sha256" "$dest.sha256" 2>/dev/null || true
        rclone copyto "$backup_file.meta"   "$dest.meta"   2>/dev/null || true
        log_success "Rclone sync successful"
    else
        log_error "Rclone sync failed"
        return 1
    fi
}

main() {
    # FIX [ITEM 9]: Lock is now in /tmp so non-root users can create it.
    if ! mkdir "$LOCKDIR" 2>/dev/null; then
        log_error "Backup already running (lock: $LOCKDIR)"
        exit 1
    fi
    # Safe cleanup: rmdir only removes the directory if empty (it is).
    trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT

    if [[ $LIST_BACKUPS == true ]]; then list_backups; exit 0; fi

    load_env_file  || exit 1
    preflight_checks || exit 1

    local backup_file=""
    case "$BACKUP_TYPE" in
        db)        backup_file=$(create_db_backup) ;;
        full)      backup_file=$(create_full_backup "full") ;;
        emergency) backup_file=$(create_full_backup "emergency") ;;
        *) log_error "Unknown type: $BACKUP_TYPE"; exit 1 ;;
    esac

    if [[ -n "$backup_file" && "$RCLONE_SYNC" == "true" ]]; then
        rclone_sync_offsite "$backup_file"
    fi

    if [[ "$EMAIL_NOTIFY" == "true" && -n "$backup_file" ]]; then
        send_notification_email "Backup Success: $BACKUP_TYPE" "File: $(basename "$backup_file")"
    fi

    exit 0
}

main "$@"
