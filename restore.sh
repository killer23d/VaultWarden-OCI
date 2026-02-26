#!/usr/bin/env bash
# restore.sh - VaultWarden backup restoration with enhanced safety

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh"
source "lib/backup_utils.sh"

# Safe cleanup registry — mirrors the pattern from backup.sh.
CLEANUP_DIRS=()
CLEANUP_FILES=()
register_cleanup_dir()  { CLEANUP_DIRS+=("$1"); }
register_cleanup_file() { CLEANUP_FILES+=("$1"); }

# FIX [ISSUE 1]: Use the "${arr[@]+"${arr[@]}"}" expansion for both arrays so
# that an empty array never triggers "unbound variable" under set -u on bash 3.2.
perform_cleanup() {
    local f
    for f in "${CLEANUP_FILES[@]+"${CLEANUP_FILES[@]}"}"; do
        rm -f "$f" 2>/dev/null || true
    done
    local i
    # FIX [ISSUE 1]: Guard added here — was previously missing for CLEANUP_DIRS.
    local _ndirs="${#CLEANUP_DIRS[@]}"
    if (( _ndirs > 0 )); then
        for (( i=_ndirs-1; i>=0; i-- )); do
            rm -rf "${CLEANUP_DIRS[$i]}" 2>/dev/null || true
        done
    fi
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
USE_LATEST=false

show_help() {
    cat << 'EOF'
VaultWarden-OCI Restore Script with Safety Checks

USAGE:
    ./restore.sh [OPTIONS]

OPTIONS:
    --file FILE             Specific backup file to restore
    --type TYPE             Backup type to restore (db, full, emergency)
    --latest                Restore the most recent backup (by modification
                            time) across all types; use with --type to
                            restrict to a specific type
    --force                 Skip confirmation prompts
    --no-backup             Skip creating restore point backup
    --skip-verification     Skip backup integrity verification
    --dry-run               Show what would be restored without executing
    --help                  Show this help

EXAMPLES:
    ./restore.sh                                    # Interactive restore
    ./restore.sh --type db                          # Restore latest database backup
    ./restore.sh --latest --force --no-backup       # Auto-restore newest backup (used by update.sh rollback)
    ./restore.sh --latest --type full --force       # Auto-restore newest full backup
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

EXIT CODES:
    0  - Restore completed successfully, all health checks passed
    1  - Restore failed or critical phase error
    2  - Restore completed but post-restore health check reported issues
EOF
}

# Argument Parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --file)              BACKUP_FILE="$2"; shift 2 ;;
        --type)              RESTORE_TYPE="$2"; shift 2 ;;
        --latest)            USE_LATEST=true; INTERACTIVE=false; shift ;;
        --force)             FORCE_RESTORE=true; INTERACTIVE=false; shift ;;
        --no-backup)         CREATE_RESTORE_BACKUP=false; shift ;;
        --skip-verification) SKIP_VERIFICATION=true; shift ;;
        --dry-run)           DRY_RUN=true; shift ;;
        --help)              show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# _find_latest_backup DIR
# Returns the most recent .age file in DIR by modification time.
# Uses find -printf '%T@ %p\n' | sort -n so result is correct regardless
# of filename date format, unlike lexicographic 'sort | tail -1'.
# ---------------------------------------------------------------------------
_find_latest_backup() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    find "$dir" -name "*.age" -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -n \
        | tail -1 \
        | cut -d' ' -f2-
}

# ---------------------------------------------------------------------------
# select_backup_interactively
# ---------------------------------------------------------------------------
select_backup_interactively() {
    if [[ "$INTERACTIVE" != "true" ]]; then
        return 0
    fi

    echo -e "${COLOR_YELLOW}PRE-RESTORE CHECKLIST:${COLOR_RESET}"
    echo -e "Ensure you have the following available:"
    echo -e "- The 'age-key.txt' file (from your backup)"
    echo -e "- The 'secrets.yaml' file (if restoring full config)"
    echo -e "- Your Cloudflare API Tokens (if rebuilding server)"
    echo ""

    log_info "Available backups for restoration:"
    echo ""

    if ! list_backups; then
        log_error "No backups found for restoration"
        return 1
    fi

    echo ""
    read -r -p "Enter the full filename of the backup to restore (or 'quit' to exit): " selected_file

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
        read -r -p "Continue with restore? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            log_info "Restore cancelled by user"
            exit 0
        fi
    fi

    return 0
}

# ---------------------------------------------------------------------------
# resolve_backup_file
# ---------------------------------------------------------------------------
resolve_backup_file() {
    # Case 1: --latest flag — find most recent backup by mtime
    if [[ "$USE_LATEST" == "true" ]]; then
        if [[ -n "$RESTORE_TYPE" ]]; then
            local backup_dir="$PROJECT_ROOT/backups/$RESTORE_TYPE"
            BACKUP_FILE=$(_find_latest_backup "$backup_dir")
            if [[ -z "$BACKUP_FILE" ]]; then
                log_error "No backups found for type: $RESTORE_TYPE"
                return 1
            fi
        else
            local candidate latest_time=0
            local backup_types=("db" "full" "emergency")
            for btype in "${backup_types[@]}"; do
                candidate=$(_find_latest_backup "$PROJECT_ROOT/backups/$btype" 2>/dev/null || true)
                if [[ -n "$candidate" ]]; then
                    local mtime
                    mtime=$(stat -c%Y "$candidate" 2>/dev/null || stat -f%m "$candidate" 2>/dev/null || echo "0")
                    if (( mtime > latest_time )); then
                        latest_time="$mtime"
                        BACKUP_FILE="$candidate"
                        RESTORE_TYPE="$btype"
                    fi
                fi
            done
            if [[ -z "$BACKUP_FILE" ]]; then
                log_error "No backups found in any backup directory"
                return 1
            fi
        fi
        log_info "Using latest backup (by mtime): $(basename "$BACKUP_FILE") [type: $RESTORE_TYPE]"
        return 0
    fi

    # Case 2: --file FILE
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
        return 0
    fi

    # Case 3: --type TYPE without --file
    if [[ -n "$RESTORE_TYPE" ]]; then
        local backup_dir="$PROJECT_ROOT/backups/$RESTORE_TYPE"
        if [[ ! -d "$backup_dir" ]]; then
            log_error "No backups found for type: $RESTORE_TYPE"
            return 1
        fi

        BACKUP_FILE=$(_find_latest_backup "$backup_dir")
        if [[ -z "$BACKUP_FILE" ]]; then
            log_error "No backup files found in: $backup_dir"
            return 1
        fi

        log_info "Using latest $RESTORE_TYPE backup: $(basename "$BACKUP_FILE")"
        return 0
    fi

    # Case 4: interactive
    if ! select_backup_interactively; then
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# create_restore_point_backup
# ---------------------------------------------------------------------------
create_restore_point_backup() {
    if [[ "$CREATE_RESTORE_BACKUP" != "true" ]]; then
        log_info "Skipping restore point backup (--no-backup specified)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create restore point backup (type: emergency)"
        return 0
    fi

    log_info "Creating restore point backup for safety..."

    if ./backup.sh --type emergency; then
        log_success "Restore point backup completed"
        return 0
    else
        log_error "Restore point backup failed"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# prepare_services_for_restore
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# purge_wal_files DB_DIR
# FIX [WAL BUG]: Deletes orphaned SQLite WAL and SHM sidecar files from
# DB_DIR before the restored database is placed there.  If these files are
# left on disk, SQLite's WAL recovery logic replays the (newer, incompatible)
# transactions from the running system into the older restored database the
# moment Vaultwarden opens it, causing instant structural corruption
# ("database disk image is malformed").  Deleting them is always safe
# because the container is stopped before this function is called —
# there is no in-progress writer that could own a valid WAL.
# ---------------------------------------------------------------------------
purge_wal_files() {
    local db_dir="$1"
    local wal_file="$db_dir/db.sqlite3-wal"
    local shm_file="$db_dir/db.sqlite3-shm"
    local purged=false

    if [[ -f "$wal_file" ]]; then
        log_info "Removing orphaned WAL file to prevent SQLite replay corruption: $(basename "$wal_file")"
        rm -f "$wal_file"
        purged=true
    fi
    if [[ -f "$shm_file" ]]; then
        log_info "Removing orphaned SHM file: $(basename "$shm_file")"
        rm -f "$shm_file"
        purged=true
    fi

    if [[ "$purged" == "true" ]]; then
        log_success "SQLite WAL/SHM files purged — restored DB will start clean"
    else
        log_info "No orphaned SQLite WAL/SHM files found"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# restore_database
# Decrypt → verify → purge WAL → swap. Live DB is never touched until
# both checks pass AND orphaned WAL files are removed.
# FIX [ISSUE 4]:  chown now uses PUID:PGID from the environment so the
#                 Vaultwarden container can actually read the restored file.
#                 get_real_user() returns $SUDO_USER (the human admin), not the
#                 service account the container runs as.
# FIX [ISSUE 11]: Uses pre-computed RESTORE_TS for safety-copy filename.
# FIX [WAL BUG]:  Calls purge_wal_files() before swapping in restored DB.
# ---------------------------------------------------------------------------
restore_database() {
    if [[ "$RESTORE_TYPE" != "db" ]]; then
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would restore database from: $(basename "$BACKUP_FILE")"
        log_info "[DRY RUN] Would purge orphaned WAL/SHM files from data directory"
        return 0
    fi

    log_info "Restoring database from: $(basename "$BACKUP_FILE")"

    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")

    local db_dir="$state_dir/data"
    local db_path="$db_dir/db.sqlite3"

    if ! ensure_dir "$db_dir" 700; then
        log_error "Failed to create database directory"
        return 1
    fi

    local temp_dir
    temp_dir=$(mktemp -d)
    register_cleanup_dir "$temp_dir"
    local temp_db="$temp_dir/db.sqlite3"

    log_info "Decrypting and decompressing backup (live DB untouched until verified)..."
    if ! age -d -i "$SOPS_AGE_KEY_FILE" "$BACKUP_FILE" | gzip -d > "$temp_db"; then
        log_error "Failed to decrypt/decompress database backup. Live database is untouched."
        return 1
    fi

    log_info "Verifying integrity of decrypted database..."
    if ! sqlite3 "$temp_db" "PRAGMA integrity_check;" | grep -qx "ok"; then
        log_error "Decrypted database failed integrity check. Live database is untouched."
        return 1
    fi

    # FIX [WAL BUG]: Both checks passed — purge orphaned WAL/SHM files BEFORE
    # swapping in the restored DB so SQLite starts with a clean slate.
    if ! purge_wal_files "$db_dir"; then
        log_error "Failed to purge WAL/SHM files — aborting to prevent corruption"
        return 1
    fi

    # Safe to swap
    if [[ -f "$db_path" ]]; then
        # FIX [ISSUE 11]: Use pre-computed RESTORE_TS (set in main) for all safety copies.
        local backup_db="$db_path.pre-restore-${RESTORE_TS}"
        if ! mv "$db_path" "$backup_db"; then
            log_error "Failed to move existing database to safety"
            return 1
        fi
        log_info "Existing database preserved at: $(basename "$backup_db")"
    fi

    if ! cp "$temp_db" "$db_path"; then
        log_error "Failed to copy restored database into place"
        return 1
    fi

    # FIX [ISSUE 4]: Use PUID:PGID from the loaded environment so the container
    # service account (not the admin's login account) owns the restored file.
    local db_uid="${PUID:-1001}"
    local db_gid="${PGID:-1001}"

    if ! chown "${db_uid}:${db_gid}" "$db_path" || ! chmod 644 "$db_path"; then
        log_error "Failed to set database permissions (uid=${db_uid} gid=${db_gid})"
        return 1
    fi

    log_success "Database restored successfully (owner: ${db_uid}:${db_gid})"
    return 0
}

# ---------------------------------------------------------------------------
# restore_archive
# FIX [ISSUE 4]:  data directory chown uses PUID:PGID, not get_real_user().
# FIX [ISSUE 11]: All safety-copy filenames use pre-computed RESTORE_TS.
# FIX [WAL BUG]:  Calls purge_wal_files() after restoring the data directory
#                 so that any WAL files bundled inside a full/emergency archive
#                 (which are themselves stale relative to the restored DB state)
#                 are also removed before Vaultwarden starts.
# ---------------------------------------------------------------------------
restore_archive() {
    if [[ "$RESTORE_TYPE" != "full" && "$RESTORE_TYPE" != "emergency" ]]; then
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would restore $RESTORE_TYPE archive from: $(basename "$BACKUP_FILE")"
        log_info "[DRY RUN] Would purge orphaned WAL/SHM files from restored data directory"
        return 0
    fi

    log_info "Restoring $RESTORE_TYPE archive from: $(basename "$BACKUP_FILE")"

    local temp_dir
    temp_dir=$(mktemp -d)
    register_cleanup_dir "$temp_dir"

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
                # FIX [ISSUE 11]: Use pre-computed RESTORE_TS — no per-file date call.
                local backup_config="$PROJECT_ROOT/$config_file.pre-restore-${RESTORE_TS}"
                mv "$PROJECT_ROOT/$config_file" "$backup_config" || log_warn "Failed to backup existing $config_file"
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
                # FIX [ISSUE 11]: Pre-computed timestamp.
                local backup_cdir="$PROJECT_ROOT/$config_dir.pre-restore-${RESTORE_TS}"
                mv "$PROJECT_ROOT/$config_dir" "$backup_cdir" || log_warn "Failed to backup existing $config_dir"
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
            # FIX [ISSUE 11]: Pre-computed timestamp.
            local backup_data="$state_dir/data.pre-restore-${RESTORE_TS}"
            mv "$state_dir/data" "$backup_data" || log_warn "Failed to backup existing data directory"
        fi

        if ! ensure_dir "$(dirname "$state_dir/data")" 755; then
            log_error "Failed to create parent directory for data"
            return 1
        fi

        if ! cp -r "$temp_dir/data" "$state_dir/"; then
            log_error "Failed to restore data directory"
            return 1
        fi

        # FIX [WAL BUG]: Purge any WAL/SHM files that were bundled inside the
        # archive or that remained in the restored data directory.  The backup
        # was created while the container was stopped (clean checkpoint), so
        # any WAL file in the archive is already fully committed to the main DB
        # file and does not need to be replayed again.
        if ! purge_wal_files "$state_dir/data"; then
            log_error "Failed to purge WAL/SHM files from restored data directory"
            return 1
        fi

        # FIX [ISSUE 4]: Use PUID:PGID so the container service account owns the data.
        local db_uid="${PUID:-1001}"
        local db_gid="${PGID:-1001}"

        if ! chown -R "${db_uid}:${db_gid}" "$state_dir/data"; then
            log_error "Failed to set data directory ownership (uid=${db_uid} gid=${db_gid})"
            return 1
        fi

        log_success "Data directory restored successfully (owner: ${db_uid}:${db_gid})"
    fi

    # Restore secrets (emergency only)
    if [[ "$RESTORE_TYPE" == "emergency" ]] && [[ -d "$temp_dir/secrets" ]]; then
        log_info "Restoring secrets (emergency restore)..."

        if [[ -d "$PROJECT_ROOT/secrets" ]]; then
            # FIX [ISSUE 11]: Pre-computed timestamp.
            local backup_secrets="$PROJECT_ROOT/secrets.pre-restore-${RESTORE_TS}"
            mv "$PROJECT_ROOT/secrets" "$backup_secrets" || log_warn "Failed to backup existing secrets"
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

# ---------------------------------------------------------------------------
# start_services_after_restore
# Calls startup.sh --force (the correct, documented flag after FIX [ISSUE 2]).
# ---------------------------------------------------------------------------
start_services_after_restore() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would start services after restoration"
        return 0
    fi

    log_info "Starting services after restoration..."

    if ./startup.sh --force; then
        log_success "Services started successfully after restore"
        return 0
    else
        log_error "Failed to start services after restore"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# validate_restore_health
# ---------------------------------------------------------------------------
validate_restore_health() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would validate system health after restoration"
        return 0
    fi

    log_info "Validating system health after restoration..."

    local max_attempts=10
    local interval=5
    local attempt=1

    while (( attempt <= max_attempts )); do
        log_info "Health check attempt $attempt/$max_attempts (waiting ${interval}s)..."
        sleep "$interval"

        if ./health.sh --quiet; then
            log_success "Post-restore health validation passed (attempt $attempt)"
            return 0
        fi

        (( attempt++ )) || true
    done

    log_error "Post-restore health validation failed after $max_attempts attempts"
    return 1
}

# ---------------------------------------------------------------------------
# generate_restore_summary
# ---------------------------------------------------------------------------
generate_restore_summary() {
    local backup_verification="$1"
    local restore_backup="$2"
    local services_stop="$3"
    local restore_operation="$4"
    local services_start="$5"
    local health_validation="$6"

    log_info "Generating restore summary..."

    local summary
    summary=$(printf "VaultWarden Restore Summary - %s\n" "$(date)")
    summary+=$(printf "\nRestore Details:\n")
    summary+=$(printf "  Backup File: %s\n" "$(basename "$BACKUP_FILE")")
    summary+=$(printf "  Restore Type: %s\n" "$RESTORE_TYPE")
    summary+=$(printf "\nRestore Results:\n")

    if [[ "$SKIP_VERIFICATION" == "true" ]]; then
        summary+=$(printf "  ⏭️  Backup verification: Skipped\n")
    elif [[ "$backup_verification" == "0" ]]; then
        summary+=$(printf "  ✅ Backup verification: Passed\n")
    else
        summary+=$(printf "  ❌ Backup verification: Failed\n")
    fi

    if [[ "$CREATE_RESTORE_BACKUP" == "true" ]]; then
        if [[ "$restore_backup" == "0" ]]; then
            summary+=$(printf "  ✅ Restore point backup: Created successfully\n")
        else
            summary+=$(printf "  ❌ Restore point backup: Failed\n")
        fi
    else
        summary+=$(printf "  ⏭️  Restore point backup: Skipped\n")
    fi

    if [[ "$services_stop" == "0" ]]; then
        summary+=$(printf "  ✅ Service stop: Completed successfully\n")
    else
        summary+=$(printf "  ❌ Service stop: Failed\n")
    fi

    if [[ "$restore_operation" == "0" ]]; then
        summary+=$(printf "  ✅ Data restoration: Completed successfully\n")
    else
        summary+=$(printf "  ❌ Data restoration: Failed\n")
    fi

    if [[ "$services_start" == "0" ]]; then
        summary+=$(printf "  ✅ Service restart: Completed successfully\n")
    else
        summary+=$(printf "  ❌ Service restart: Failed\n")
    fi

    if [[ "$health_validation" == "0" ]]; then
        summary+=$(printf "  ✅ Health validation: Passed\n")
    else
        summary+=$(printf "  ❌ Health validation: Issues detected\n")
    fi

    if [[ "$restore_operation" == "0" && "$services_start" == "0" && "$health_validation" == "0" ]]; then
        summary+=$(printf "\n🎉 Overall Status: RESTORE SUCCESSFUL\n")
        summary+=$(printf "\nNext Steps:\n")
        summary+=$(printf "  • Monitor services for stability\n")
        summary+=$(printf "  • Verify data integrity\n")
        summary+=$(printf "  • Update any changed configurations\n")
    else
        summary+=$(printf "\n⚠️  Overall Status: RESTORE COMPLETED WITH ISSUES\n")
        summary+=$(printf "\nImmediate Actions Required:\n")
        summary+=$(printf "  • Check service logs: make logs\n")
        summary+=$(printf "  • Run health check: ./health.sh --comprehensive\n")
        summary+=$(printf "  • Consider manual rollback if issues persist\n")
    fi

    printf "%s\n" "$summary"
    return 0
}

# ---------------------------------------------------------------------------
# main
# FIX [ISSUE 11]: RESTORE_TS computed once here and exported for all functions.
# ---------------------------------------------------------------------------
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

    # FIX [ISSUE 11]: Single timestamp for ALL pre-restore safety copies in this run.
    RESTORE_TS="$(date +%Y%m%d-%H%M%S)"
    export RESTORE_TS

    # Track restoration results (1 = not yet run / failed, 0 = success)
    local backup_verification_result=1
    local restore_backup_result=1
    local services_stop_result=1
    local restore_operation_result=1
    local services_start_result=1
    local health_validation_result=1

    # -----------------------------------------------------------------------
    # Phase 1: Preparation and validation
    # -----------------------------------------------------------------------
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

    # -----------------------------------------------------------------------
    # Phase 2: Service preparation
    # -----------------------------------------------------------------------
    log_info "=== Phase 2: Service Preparation ==="

    if prepare_services_for_restore; then
        services_stop_result=0
    else
        log_error "Failed to prepare services for restore"
        exit 1
    fi

    # -----------------------------------------------------------------------
    # Phase 3: Data restoration
    # -----------------------------------------------------------------------
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
        # Don't exit — attempt to bring services back up
    fi

    # -----------------------------------------------------------------------
    # Phase 4: Service restart and validation
    # -----------------------------------------------------------------------
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

    # -----------------------------------------------------------------------
    # Phase 5: Summary and results
    # -----------------------------------------------------------------------
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
        log_warn "Restore completed but health check shows issues (exit 2)"
        exit 2
    else
        log_error "Restore completed with critical failures"
        exit 1
    fi
}

main "$@"
