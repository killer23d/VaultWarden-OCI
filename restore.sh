#!/usr/bin/env bash
# restore.sh - VaultWarden-OCI safe restore
#
# Supports both archive formats:
#   version=2 / archive_format=relative  →  staged restore (atomic, safe)
#   version=1 (legacy absolute paths)    →  direct -C / extraction (backward compat)
#
# Safety features:
#   - require_root enforced via lib/common.sh
#   - All decrypted artifacts in mktemp dir + EXIT/INT/TERM trap
#   - Docker alpine+sqlite for integrity checks (no host sqlite3 dependency)
#   - tar member validation blocks path traversal before extraction
#   - Staged full restore: extract → validate → atomic mv (all-or-nothing)
#   - PROJECT_ROOT config files (.env, docker-compose.yml, caddy/, fail2ban/)
#     restored from archive after STATE_DIR promotion; secrets/ and *.sh
#     scripts are intentionally excluded
#   - Pre-restore emergency snapshot before any destructive operation
#   - AGE_KEY_FILE read from .env (SOPS_AGE_KEY_FILE) with safe default

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"       2>/dev/null || true
source "lib/backup_utils.sh" 2>/dev/null || true
source "lib/crypto.sh"       2>/dev/null || true

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BACKUP_FILE=""
RESTORE_TYPE=""
USE_LATEST=false
LIST_ONLY=false
DRY_RUN=false
FORCE=false
NO_PRE_BACKUP=false
SKIP_VERIFICATION=false

show_help() {
    cat << 'EOF'
VaultWarden-OCI Restore Script

USAGE:
    sudo ./restore.sh [OPTIONS]

OPTIONS:
    --list                  List available backups and exit
    --file FILE             Restore a specific backup file (.age)
    --type TYPE             db | full | emergency (helps resolve --latest)
    --latest                Use newest backup (optionally filtered by --type)
    --no-backup             Skip pre-restore emergency snapshot
    --skip-verification     Skip integrity check (not recommended)
    --dry-run               Show what would happen without making changes
    --force                 Skip confirmation prompts
    --help                  Show this help

EXAMPLES:
    sudo ./restore.sh --list
    sudo ./restore.sh --latest --type db --force
    sudo ./restore.sh --file backups/full/full_backup_20260101_120000.tar.gz.age
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)               LIST_ONLY=true;         shift ;;
        --file)               BACKUP_FILE="$2";       shift 2 ;;
        --type)               RESTORE_TYPE="$2";      shift 2 ;;
        --latest)             USE_LATEST=true;        shift ;;
        --no-backup)          NO_PRE_BACKUP=true;     shift ;;
        --skip-verification)  SKIP_VERIFICATION=true; shift ;;
        --dry-run)            DRY_RUN=true;           shift ;;
        --force)              FORCE=true;             shift ;;
        --help)               show_help; exit 0 ;;
        *)                    log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_find_latest_backup() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    find "$dir" -name "*.age" -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | tail -1 | cut -d' ' -f2-
}

list_backups() {
    local types=("db" "full" "emergency")
    for t in "${types[@]}"; do
        echo ""
        log_info "Available ${t} backups:"
        if [[ -d "$PROJECT_ROOT/backups/$t" ]]; then
            find "$PROJECT_ROOT/backups/$t" -name "*.age" -type f \
                -exec ls -lh {} \; 2>/dev/null | sort -r | head -n 20 || true
        else
            echo "  (none)"
        fi
    done
}

resolve_backup_file() {
    if [[ "$USE_LATEST" == "true" ]]; then
        if [[ -n "$RESTORE_TYPE" ]]; then
            BACKUP_FILE="$(_find_latest_backup "$PROJECT_ROOT/backups/$RESTORE_TYPE" || true)"
            [[ -n "$BACKUP_FILE" ]] || { log_error "No backups found for type: $RESTORE_TYPE"; return 1; }
            return 0
        fi
        local best="" best_mtime=0 candidate mtime
        for t in db full emergency; do
            candidate="$(_find_latest_backup "$PROJECT_ROOT/backups/$t" || true)"
            if [[ -n "$candidate" ]]; then
                mtime=$(stat -c%Y "$candidate" 2>/dev/null || stat -f%m "$candidate" 2>/dev/null || echo 0)
                if (( mtime > best_mtime )); then
                    best_mtime="$mtime"; best="$candidate"; RESTORE_TYPE="$t"
                fi
            fi
        done
        [[ -n "$best" ]] || { log_error "No backups found in any backup directory"; return 1; }
        BACKUP_FILE="$best"
        return 0
    fi

    if [[ -n "$BACKUP_FILE" ]]; then
        [[ -f "$BACKUP_FILE" ]] || { log_error "Backup file not found: $BACKUP_FILE"; return 1; }
        if [[ -z "$RESTORE_TYPE" ]]; then
            if   [[ "$BACKUP_FILE" == */db/* ]];        then RESTORE_TYPE="db"
            elif [[ "$BACKUP_FILE" == */full/* ]];      then RESTORE_TYPE="full"
            elif [[ "$BACKUP_FILE" == */emergency/* ]]; then RESTORE_TYPE="emergency"
            fi
        fi
        [[ -n "$RESTORE_TYPE" ]] || {
            log_error "Cannot determine backup type — specify --type db|full|emergency"
            return 1
        }
        return 0
    fi

    log_error "No backup specified. Use --file FILE or --latest."
    return 1
}

read_meta_field() {
    local meta_file="$1"
    local field="$2"
    local default="${3:-}"
    if [[ -f "$meta_file" ]]; then
        local val
        val=$(grep -m1 "^${field}=" "$meta_file" | cut -d= -f2- || true)
        echo "${val:-$default}"
    else
        echo "$default"
    fi
}

# Block archives containing absolute paths or ../ traversal
tar_validate_members() {
    local tarfile="$1"
    local members
    members="$(tar -tzf "$tarfile")" || {
        log_error "Cannot list archive members"
        return 1
    }
    if echo "$members" | grep -qE '(^/|(^|/)\.\.(/|$))'; then
        log_error "Archive contains unsafe paths (absolute or traversal). Refusing to extract."
        log_error "If this is a legacy backup (version=1), it will be extracted via fallback."
        return 1
    fi
    return 0
}

# Verify SQLite integrity via docker (no host sqlite3 dependency)
verify_sqlite_docker() {
    local dbfile="$1"
    log_info "Verifying SQLite integrity (docker alpine+sqlite)..."
    if docker run --rm -v "${dbfile}:/db.sqlite3" alpine:latest \
        sh -c 'apk add -q sqlite >/dev/null 2>&1 && sqlite3 /db.sqlite3 "PRAGMA integrity_check;"' \
        | grep -qx "ok"; then
        log_success "SQLite integrity check passed"
        return 0
    else
        log_error "SQLite integrity check FAILED"
        return 1
    fi
}

purge_wal_shm() {
    local db="$1"
    rm -f "${db}-wal" "${db}-shm" 2>/dev/null || true
}

create_pre_restore_snapshot() {
    [[ "$NO_PRE_BACKUP" == "true" ]] && { log_info "Skipping pre-restore snapshot (--no-backup)"; return 0; }
    [[ "$DRY_RUN"       == "true" ]] && { log_info "[DRY RUN] Would run: ./backup.sh --type emergency"; return 0; }
    if [[ -x "./backup.sh" ]]; then
        log_info "Creating pre-restore emergency snapshot..."
        ./backup.sh --type emergency --quiet || log_warn "Pre-restore snapshot failed (continuing)"
    else
        log_warn "backup.sh not executable — skipping pre-restore snapshot"
    fi
}

# ---------------------------------------------------------------------------
# DB restore
# ---------------------------------------------------------------------------
restore_db() {
    local backup_file="$1"
    local age_key_file="$2"
    local state_dir="$3"
    local puid="$4"
    local pgid="$5"
    local tmpdir="$6"

    local dec_db="$tmpdir/db.sqlite3"

    log_info "Decrypting database backup..."
    age -d -i "$age_key_file" -o "$dec_db" "$backup_file" || {
        log_error "Decryption failed — verify the age key is correct."
        return 1
    }

    if [[ "$SKIP_VERIFICATION" != "true" ]]; then
        verify_sqlite_docker "$dec_db" || return 1
    fi

    local db_dir="$state_dir/data"
    local db_path="$db_dir/db.sqlite3"
    mkdir -p "$db_dir"

    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    if [[ -f "$db_path" ]]; then
        log_info "Saving current DB as pre-restore copy (${db_path}.pre-restore-${ts})..."
        cp -a "$db_path" "${db_path}.pre-restore-${ts}"
    fi

    log_info "Restoring database..."
    cp -f "$dec_db" "$db_path"
    purge_wal_shm "$db_path"
    chown "${puid}:${pgid}" "$db_path" 2>/dev/null || log_warn "Could not set ownership on $db_path"
    chmod 640 "$db_path" 2>/dev/null || true

    log_success "Database restored successfully."
}

# ---------------------------------------------------------------------------
# Full / emergency restore — staged (version=2) or legacy (version=1)
# ---------------------------------------------------------------------------
restore_full() {
    local backup_file="$1"
    local age_key_file="$2"
    local state_dir="$3"
    local puid="$4"
    local pgid="$5"
    local tmpdir="$6"
    local archive_format="$7"   # "relative" | "absolute" (legacy)

    local dec_tar="$tmpdir/restore.tar.gz"

    log_info "Decrypting archive..."
    age -d -i "$age_key_file" -o "$dec_tar" "$backup_file" || {
        log_error "Decryption failed — verify the age key is correct."
        return 1
    }

    if [[ "$SKIP_VERIFICATION" != "true" ]]; then
        log_info "Verifying archive structure..."
        tar -tzf "$dec_tar" >/dev/null || { log_error "Archive is corrupt or invalid"; return 1; }
    fi

    if [[ "$archive_format" == "absolute" ]]; then
        # -------------------------------------------------------------------
        # LEGACY path: version=1 absolute-path archive → extract directly to /
        # -------------------------------------------------------------------
        log_warn "Legacy archive format detected (version=1, absolute paths)."
        log_warn "Extracting directly to / — no staging available for this format."

        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would run: tar -xzf <archive> -C /"
            return 0
        fi

        tar -xzf "$dec_tar" -C / --no-same-owner --no-same-permissions --delay-directory-restore
        purge_wal_shm "$state_dir/data/db.sqlite3" || true
        log_success "Legacy archive restored."
        return 0
    fi

    # -----------------------------------------------------------------------
    # CURRENT path: version=2 relative-path archive → staged restore
    # -----------------------------------------------------------------------
    if [[ "$SKIP_VERIFICATION" != "true" ]]; then
        log_info "Validating archive members (path traversal check)..."
        tar_validate_members "$dec_tar" || return 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would stage-extract archive, validate, then atomic mv into place."
        return 0
    fi

    # Stage extraction
    local staging="$tmpdir/stage"
    mkdir -p "$staging"
    log_info "Extracting archive to staging directory..."
    tar -xzf "$dec_tar" -C "$staging"

    # Validate expected paths exist in staging
    local rel_state="${state_dir#/}"
    if [[ ! -d "$staging/$rel_state" ]]; then
        log_error "Staging validation failed: expected directory not found: $staging/$rel_state"
        log_error "Archive members:"
        tar -tzf "$dec_tar" | head -20 >&2 || true
        return 1
    fi

    # Atomic swap: rename current state dir to .pre-restore-<ts>, mv staged dir in
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    if [[ -d "$state_dir" ]]; then
        log_info "Renaming current state dir to ${state_dir}.pre-restore-${ts}..."
        mv "$state_dir" "${state_dir}.pre-restore-${ts}"
    fi

    log_info "Promoting staged restore to live path..."
    mv "$staging/$rel_state" "$state_dir"

    # Fix ownership on restored data
    chown -R "${puid}:${pgid}" "$state_dir/data" 2>/dev/null || \
        log_warn "Could not set ownership on $state_dir/data"
    purge_wal_shm "$state_dir/data/db.sqlite3" || true

    # -----------------------------------------------------------------------
    # Restore PROJECT_ROOT config files from staging.
    #
    # Intentional exclusions:
    #   *.sh scripts  — may be running and are not data; operator should
    #                   update scripts manually if needed
    #   secrets/      — the live age key decrypted this archive; overwriting
    #                   it with an archived version would break access to all
    #                   backups made after that key was rotated
    # -----------------------------------------------------------------------
    local rel_project="${PROJECT_ROOT#/}"
    if [[ -d "$staging/$rel_project" ]]; then
        log_info "Restoring project config files from archive..."

        # Explicit config files (safe to replace while scripts are running)
        local config_files=(
            .env
            docker-compose.yml
            docker-compose.override.yml
            .env.example
        )
        for f in "${config_files[@]}"; do
            local src="$staging/$rel_project/$f"
            if [[ -f "$src" ]]; then
                cp -f "$src" "$PROJECT_ROOT/$f"
                log_info "  Restored: $f"
            fi
        done

        # Config directories (caddy, fail2ban, nginx — excludes secrets/)
        local config_dirs=(caddy fail2ban nginx)
        for d in "${config_dirs[@]}"; do
            local src_dir="$staging/$rel_project/$d"
            if [[ -d "$src_dir" ]]; then
                cp -rf "$src_dir" "$PROJECT_ROOT/"
                log_info "  Restored: $d/"
            fi
        done

        log_success "Project config files restored from archive."
        log_warn "secrets/ and *.sh scripts were intentionally not restored."
        log_warn "Restart services for any .env changes to take full effect."
    else
        log_warn "Project root not found in archive staging ($rel_project) — config files not restored."
        log_warn "This may be expected for archives created before PROJECT_ROOT was included."
    fi

    log_success "Full restore completed (staged, atomic)."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    require_root "$@"

    log_header "VaultWarden-OCI Restore Utility"

    if [[ "$LIST_ONLY" == "true" ]]; then
        list_backups
        exit 0
    fi

    # Load environment
    load_env_file || { log_error "Failed to load .env"; exit 1; }

    local STATE_DIR AGE_KEY_FILE PUID PGID
    STATE_DIR="$(get_config_value "PROJECT_STATE_DIR"   "/var/lib/vaultwarden")"
    AGE_KEY_FILE="$(get_config_value "SOPS_AGE_KEY_FILE" "secrets/keys/age-key.txt")"
    PUID="$(get_config_value "PUID" "1001")"
    PGID="$(get_config_value "PGID" "1001")"

    [[ -f "$AGE_KEY_FILE" ]] || { log_error "Age key not found: $AGE_KEY_FILE"; exit 1; }

    resolve_backup_file || exit 1
    [[ -f "$BACKUP_FILE" ]] || { log_error "Backup file not found: $BACKUP_FILE"; exit 1; }

    # Read .meta to determine archive format / version
    local meta_file="${BACKUP_FILE}.meta"
    local archive_version archive_format
    archive_version="$(read_meta_field "$meta_file" "version"       "1")"
    archive_format="$( read_meta_field "$meta_file" "archive_format" "absolute")"

    log_info "Restore plan:"
    log_info "  File:           $BACKUP_FILE"
    log_info "  Type:           $RESTORE_TYPE"
    log_info "  Archive ver:    $archive_version (format: $archive_format)"
    log_info "  State dir:      $STATE_DIR"
    log_info "  Age key:        $AGE_KEY_FILE"

    # Confirmation
    if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" ]]; then
        echo ""
        log_warn  "WARNING: This will overwrite current data."
        log_warn  "Services will be stopped during the restore."
        echo ""
        read -r -p "Type 'yes' to proceed: " confirm
        [[ "$confirm" == "yes" ]] || { log_info "Restore cancelled."; exit 0; }
    fi

    # mktemp staging area — cleanup on any exit
    local TMPDIR_RESTORE
    TMPDIR_RESTORE="$(mktemp -d)"
    cleanup() { rm -rf "$TMPDIR_RESTORE" 2>/dev/null || true; }
    trap cleanup EXIT HUP INT TERM

    create_pre_restore_snapshot

    # Stop services
    if [[ "$DRY_RUN" != "true" ]]; then
        if docker compose ps 2>/dev/null | grep -q "Up"; then
            log_info "Stopping services..."
            docker compose stop
        fi
    fi

    # Perform restore
    case "$RESTORE_TYPE" in
        db)
            restore_db \
                "$BACKUP_FILE" "$AGE_KEY_FILE" "$STATE_DIR" \
                "$PUID" "$PGID" "$TMPDIR_RESTORE"
            ;;
        full|emergency)
            restore_full \
                "$BACKUP_FILE" "$AGE_KEY_FILE" "$STATE_DIR" \
                "$PUID" "$PGID" "$TMPDIR_RESTORE" "$archive_format"
            ;;
        *)
            log_error "Unknown restore type: $RESTORE_TYPE"
            exit 1
            ;;
    esac

    # Restart services
    if [[ "$DRY_RUN" != "true" ]]; then
        log_info "Starting services..."
        docker compose start
        if [[ -x "./health.sh" ]]; then
            log_info "Running post-restore health check..."
            ./health.sh --quiet || log_warn "Health check reported issues after restore"
        fi
    fi

    log_success "Restore complete."
}

main "$@"
