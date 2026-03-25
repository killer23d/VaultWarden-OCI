#!/usr/bin/env bash
# restore.sh - VaultWarden-OCI safe restore

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

VW_LOCK_DIR="${PROJECT_ROOT}/.locks"
VW_OPERATIONS_LOCK="${VW_LOCK_DIR}/operations.lock"

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
RESTORE_ENV=true
RESTORE_SNAPSHOT_HARD_FAIL="${RESTORE_SNAPSHOT_HARD_FAIL:-true}"

show_help() {
    cat << 'EOF'
VaultWarden-OCI Restore Script

USAGE:
    sudo ./restore.sh [OPTIONS]

    When run without --file or --latest, an interactive numbered menu is
    presented showing all available backups grouped by type (db / full /
    emergency), sorted newest-first.  Enter the number of the backup you
    want to restore and confirm the plan before the restore begins.

OPTIONS:
    --list                  List available backups and exit (no root required)
    --file FILE             Restore a specific backup file (.age)
    --type TYPE             db | full | emergency (helps resolve --latest)
    --latest                Use newest backup (optionally filtered by --type)
    --no-backup             Skip pre-restore emergency snapshot
    --skip-verification     Skip integrity check (not recommended)
    --skip-env              Do not restore archived .env over current .env
    --dry-run               Show what would happen without making changes
    --force                 Skip confirmation prompts
    --help                  Show this help

ENVIRONMENT:
    RESTORE_SNAPSHOT_HARD_FAIL=false   Demote snapshot failure to a warning
                                       (default: true = hard-fail)

EXAMPLES:
    sudo ./restore.sh                  # interactive numbered menu (default)
    ./restore.sh --list                # list backups only (no root needed)
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
        --skip-env)           RESTORE_ENV=false;      shift ;;
        --dry-run)            DRY_RUN=true;           shift ;;
        --force)              FORCE=true;             shift ;;
        --help)               show_help; exit 0 ;;
        *)                    log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

TMPDIR_RESTORE=""
cleanup() { [[ -n "$TMPDIR_RESTORE" ]] && rm -rf "$TMPDIR_RESTORE" 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_find_latest_backup() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1

    local best_mtime=0
    local best_file=""
    local f mtime

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        mtime=$(stat -c%Y "$f" 2>/dev/null \
             || stat -f%m "$f" 2>/dev/null \
             || echo 0)
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
        if (( mtime > best_mtime )); then
            best_mtime=$mtime
            best_file="$f"
        fi
    done < <(find "$dir" -name "*.age" -type f 2>/dev/null)

    if [[ -n "$best_file" ]]; then
        echo "$best_file"
        return 0
    fi
    return 1
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

_INTERACTIVE_FILES=()
_INTERACTIVE_TYPES=()

list_all_backups_interactive() {
    _INTERACTIVE_FILES=()
    _INTERACTIVE_TYPES=()

    local types=("db" "full" "emergency")
    local global_index=0
    local any_found=false

    for t in "${types[@]}"; do
        local dir="$PROJECT_ROOT/backups/$t"
        [[ -d "$dir" ]] || continue

        # Collect .age files for this type, newest-first by modification time
        local -a type_files=()
        while IFS= read -r f; do
            type_files+=("$f")
        done < <(
            find "$dir" -name "*.age" -type f -print0 2>/dev/null \
            | xargs -0 -r stat --printf '%Y\t%n\n' 2>/dev/null \
            | sort -rn \
            | cut -f2
        )

        # Fallback for macOS / systems where GNU stat --printf is unavailable
        if [[ ${#type_files[@]} -eq 0 ]]; then
            while IFS= read -r f; do
                type_files+=("$f")
            done < <(find "$dir" -name "*.age" -type f 2>/dev/null | sort -r)
        fi

        [[ ${#type_files[@]} -eq 0 ]] && continue
        any_found=true

        # Section header
        echo ""
        printf '  ── %s backups ──\n' "${t^^}"

        for f in "${type_files[@]}"; do
            (( global_index++ ))
            _INTERACTIVE_FILES+=("$f")
            _INTERACTIVE_TYPES+=("$t")

            local size
            size=$(du -sh "$f" 2>/dev/null | cut -f1)
            size="${size:-?}"

            local mtime_str
            mtime_str=$(stat -c '%y' "$f" 2>/dev/null \
                     || stat -f '%Sm' "$f" 2>/dev/null \
                     || echo "unknown")
            mtime_str="${mtime_str:0:19}"

            printf '  [%3d]  %-10s  %6s  %s  %s\n' \
                "$global_index" \
                "($t)" \
                "$size" \
                "$mtime_str" \
                "$(basename "$f")"
        done
    done

    echo ""

    if [[ "$any_found" == "false" ]]; then
        log_error "No backup files found under $PROJECT_ROOT/backups/"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# select_backup_interactive
# ---------------------------------------------------------------------------
select_backup_interactive() {
    log_info "No backup specified — listing available backups:"

    list_all_backups_interactive || return 1

    local total="${#_INTERACTIVE_FILES[@]}"

    local choice
    while true; do
        read -r -p "  Enter number to restore (1-${total}), or q to quit: " choice

        [[ "$choice" == "q" || "$choice" == "Q" ]] && {
            log_info "Restore cancelled."
            exit 0
        }

        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            log_error "Invalid input '${choice}': please enter a number between 1 and ${total}."
            continue
        fi
        if (( choice < 1 || choice > total )); then
            log_error "Out of range: please enter a number between 1 and ${total}."
            continue
        fi
        break
    done

    BACKUP_FILE="${_INTERACTIVE_FILES[$(( choice - 1 ))]}"
    RESTORE_TYPE="${_INTERACTIVE_TYPES[$(( choice - 1 ))]}"

    echo ""
    log_info "Selected backup:"
    log_info "  File: $(basename "$BACKUP_FILE")"
    log_info "  Type: $RESTORE_TYPE"
    log_info "  Path: $BACKUP_FILE"
    echo ""
}

# ---------------------------------------------------------------------------
# select_backup_file (kept for direct --type-scoped selection, unchanged)
# ---------------------------------------------------------------------------
select_backup_file() {
    local dir="$1"
    [[ -d "$dir" ]] || { log_error "Backup directory not found: $dir"; return 1; }

    local -a files=()
    while IFS= read -r f; do
        files+=("$f")
    done < <(find "$dir" -name "*.age" -type f 2>/dev/null | sort -r)

    if [[ ${#files[@]} -eq 0 ]]; then
        log_error "No backup files found in: $dir"
        return 1
    fi

    echo "Available backups:"
    local i
    for (( i=0; i<${#files[@]}; i++ )); do
        local size
        size=$(du -sh "${files[$i]}" 2>/dev/null | cut -f1)
        printf '  [%d] %s (%s)\n' "$(( i + 1 ))" "$(basename "${files[$i]}")" "${size:-?}"
    done

    local choice
    while true; do
        read -r -p "Enter number (1-${#files[@]}): " choice
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            log_error "Invalid input '${choice}': please enter a number between 1 and ${#files[@]}."
            continue
        fi
        if (( choice < 1 || choice > ${#files[@]} )); then
            log_error "Out of range: please enter a number between 1 and ${#files[@]}."
            continue
        fi
        break
    done

    BACKUP_FILE="${files[$(( choice - 1 ))]}"
    log_info "Selected: $(basename "$BACKUP_FILE")"
}

# ---------------------------------------------------------------------------
# resolve_backup_file
#
# Priority:
#   1. --latest flag           → automatic selection (unchanged)
#   2. --file FILE             → direct path (unchanged)
#   3. (neither)               → interactive numbered menu (NEW)
# ---------------------------------------------------------------------------
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
                [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
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

    # -----------------------------------------------------------------------
    # Neither --file nor --latest was supplied: present interactive menu.
    # This is the normal human-operator path.
    # -----------------------------------------------------------------------
    select_backup_interactive || return 1
    return 0
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

_tar_filter_for_file() {
    local f="$1"
    case "$f" in
        *.tar.zst|*.zst) echo "-I zstd" ;;
        *.tar.gz|*.tgz)  echo "-z"      ;;
        *.tar.bz2|*.tbz) echo "-j"      ;;
        *.tar.xz)        echo "-J"      ;;
        *)               echo ""        ;;
    esac
}

tar_validate_members() {
    local tarfile="$1"
    local filter
    filter="$(_tar_filter_for_file "$tarfile")"
    local members
    # shellcheck disable=SC2086
    members="$(tar $filter -tf "$tarfile")" || {
        log_error "Cannot list archive members"
        return 1
    }
    if echo "$members" | grep -qE '(^/|(^|/)\.\.(\/|$))'; then
        log_error "Archive contains unsafe paths (absolute or traversal). Refusing to extract."
        log_error "If this is a legacy backup (version=1), it will be extracted via fallback."
        return 1
    fi
    return 0
}

check_traversal_only() {
    local tarfile="$1"
    local filter
    filter="$(_tar_filter_for_file "$tarfile")"
    local bad_members
    # shellcheck disable=SC2086
    bad_members=$(tar $filter -tf "$tarfile" 2>/dev/null \
        | grep -E '(^|/)\.\.(\/|$)' || true)
    if [[ -n "$bad_members" ]]; then
        log_error "Archive contains path traversal sequences (../). Refusing to extract."
        log_error "Suspicious paths:"
        echo "$bad_members" | head -10 >&2
        return 1
    fi
    return 0
}

verify_sqlite() {
    local dbfile="$1"
    log_info "Checkpointing WAL before integrity check..."
    sqlite3 "$dbfile" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true

    log_info "Verifying SQLite integrity (host sqlite3)..."
    local result
    result=$(sqlite3 "$dbfile" "PRAGMA integrity_check;" 2>&1) || {
        log_error "SQLite integrity check error: ${result}"
        return 1
    }
    if [[ "$result" != "ok" ]]; then
        log_error "SQLite integrity check FAILED: ${result}"
        return 1
    fi
    log_success "SQLite integrity check passed"
    return 0
}

purge_wal_shm() {
    local db="$1"
    rm -f "${db}-wal" "${db}-shm" 2>/dev/null || true
}

create_pre_restore_snapshot() {
    [[ "$NO_PRE_BACKUP" == "true" ]] && { log_info "Skipping pre-restore snapshot (--no-backup)"; return 0; }
    [[ "$DRY_RUN"       == "true" ]] && { log_info "[DRY RUN] Would run: ./backup.sh --type emergency"; return 0; }
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    local db_path="$state_dir/data/db.sqlite3"
    if [[ -f "$db_path" ]] && command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$db_path" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
    fi
    if [[ -x "./backup.sh" ]]; then
        log_info "Creating pre-restore emergency snapshot..."
        if ! ./backup.sh --type emergency --quiet; then
            if [[ "${RESTORE_SNAPSHOT_HARD_FAIL}" == "true" ]]; then
                log_error "Pre-restore snapshot FAILED (hard-fail)."
                log_error "Use --no-backup or set RESTORE_SNAPSHOT_HARD_FAIL=false to skip."
                return 1
            else
                log_warn "Pre-restore snapshot failed (continuing — RESTORE_SNAPSHOT_HARD_FAIL=false)"
            fi
        fi
    else
        local msg="backup.sh not executable — cannot create pre-restore snapshot"
        if [[ "${RESTORE_SNAPSHOT_HARD_FAIL}" == "true" ]]; then
            log_error "$msg"
            log_error "Use --no-backup or set RESTORE_SNAPSHOT_HARD_FAIL=false to skip."
            return 1
        else
            log_warn "$msg (continuing — RESTORE_SNAPSHOT_HARD_FAIL=false)"
        fi
    fi
}

cleanup_pre_restore_artefacts() {
    local base_path="$1"
    local keep_count="${2:-3}"
    local base_dir base_name
    base_dir="$(dirname  "$base_path")"
    base_name="$(basename "$base_path")"

    local artefacts=()
    while IFS= read -r -d '' f; do
        artefacts+=("$f")
    done < <(find "$base_dir" -maxdepth 1 \
        -name "${base_name}.pre-restore-*" \
        -print0 2>/dev/null \
        | sort -z)

    local total="${#artefacts[@]}"
    if (( total <= keep_count )); then
        return 0
    fi

    local to_remove=$(( total - keep_count ))
    log_info "Pruning ${to_remove} old pre-restore artefact(s) (keeping ${keep_count} most recent)..."
    for (( i=0; i<to_remove; i++ )); do
        rm -rf "${artefacts[$i]}"
        log_info "  Removed: $(basename "${artefacts[$i]}")"
    done
    return 0
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
        verify_sqlite "$dec_db" || return 1
    fi

    local db_dir="$state_dir/data"
    local db_path="$db_dir/db.sqlite3"
    mkdir -p "$db_dir"

    local ts
    ts="$(date +%Y%m%d-%H%M%S)"

    local rollback_path=""
    if [[ -f "$db_path" ]]; then
        rollback_path="${db_path}.rollback-${ts}"
        log_info "Creating rollback copy: $(basename "$rollback_path")..."
        cp -a "$db_path" "$rollback_path" || {
            log_error "Failed to create rollback copy of live database — aborting restore."
            return 1
        }
        log_info "Saving current DB as pre-restore copy (${db_path}.pre-restore-${ts})..."
        cp -a "$db_path" "${db_path}.pre-restore-${ts}"
    fi

    log_info "Restoring database..."
    if ! cp -f "$dec_db" "$db_path"; then
        log_error "cp to live DB path failed — rolling back from: $(basename "${rollback_path:-none}")"
        if [[ -n "$rollback_path" && -f "$rollback_path" ]]; then
            if cp -a "$rollback_path" "$db_path"; then
                log_warn "Rollback successful — live database restored to pre-restore state."
            else
                log_error "CRITICAL: Rollback copy failed. Live DB may be missing."
                log_error "Manual recovery: cp '${rollback_path}' '${db_path}'"
            fi
        fi
        return 1
    fi

    [[ -n "$rollback_path" ]] && rm -f "$rollback_path" 2>/dev/null || true

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
    local archive_format="$7"

    local inner_name
    inner_name="${backup_file%.age}"
    case "$inner_name" in
        *.tar.zst|*.tar.gz|*.tar.bz2|*.tar.xz|*.tgz|*.tbz) : ;;
        *) inner_name="${inner_name}.tar.gz" ;;
    esac
    local dec_tar="$tmpdir/$(basename "$inner_name")"

    local tar_filter
    tar_filter="$(_tar_filter_for_file "$dec_tar")"

    log_info "Decrypting archive..."
    age -d -i "$age_key_file" -o "$dec_tar" "$backup_file" || {
        log_error "Decryption failed — verify the age key is correct."
        return 1
    }

    if [[ "$SKIP_VERIFICATION" != "true" ]]; then
        log_info "Verifying archive structure..."
        # shellcheck disable=SC2086
        tar $tar_filter -tf "$dec_tar" >/dev/null || { log_error "Archive is corrupt or invalid"; return 1; }
    fi

    if [[ "$archive_format" == "absolute" ]]; then
        log_warn "Legacy archive format detected (version=1, absolute paths)."
        log_warn "Extracting directly to / — no staging available for this format."

        if [[ "$SKIP_VERIFICATION" != "true" ]]; then
            log_info "Validating archive members (path traversal check — legacy format)..."
            check_traversal_only "$dec_tar" || {
                log_error "Refusing to extract legacy archive containing path traversal sequences."
                log_error "Use --skip-verification only if you generated this archive yourself"
                log_error "and can guarantee its integrity."
                return 1
            }
            log_success "Archive traversal check passed (legacy format)."
        else
            log_warn "--skip-verification set: path traversal check BYPASSED on legacy archive."
            log_warn "Only use --skip-verification if you generated this archive yourself."
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would run: tar $tar_filter -xf <archive> -C /"
            return 0
        fi

        # shellcheck disable=SC2086
        tar $tar_filter -xf "$dec_tar" -C / \
            --no-same-owner --no-same-permissions --delay-directory-restore

        if [[ -d "$state_dir" ]]; then
            log_info "Fixing ownership on restored state directory (${puid}:${pgid})..."
            chown -R "${puid}:${pgid}" "$state_dir/data" 2>/dev/null || \
                log_warn "Could not set ownership on $state_dir/data (chown -R failed)"
        fi

        purge_wal_shm "$state_dir/data/db.sqlite3" || true
        log_success "Legacy archive restored."
        return 0
    fi

    if [[ "$SKIP_VERIFICATION" != "true" ]]; then
        log_info "Validating archive members (path traversal check)..."
        tar_validate_members "$dec_tar" || return 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would stage-extract archive, validate, then atomic mv into place."
        return 0
    fi

    local staging="$tmpdir/stage"
    mkdir -p "$staging"
    log_info "Extracting archive to staging directory..."
    # shellcheck disable=SC2086
    tar $tar_filter -xf "$dec_tar" -C "$staging" \
        --no-same-owner --no-same-permissions --delay-directory-restore

    local rel_state="${state_dir#/}"
    if [[ ! -d "$staging/$rel_state" ]]; then
        log_error "Staging validation failed: expected directory not found: $staging/$rel_state"
        log_error "Archive members:"
        # shellcheck disable=SC2086
        tar $tar_filter -tf "$dec_tar" | head -20 >&2 || true
        return 1
    fi

    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    if [[ -d "$state_dir" ]]; then
        log_info "Renaming current state dir to ${state_dir}.pre-restore-${ts}..."
        mv "$state_dir" "${state_dir}.pre-restore-${ts}"
    fi

    log_info "Promoting staged restore to live path..."
    mv "$staging/$rel_state" "$state_dir"

    chown -R "${puid}:${pgid}" "$state_dir/data" 2>/dev/null || \
        log_warn "Could not set ownership on $state_dir/data"
    purge_wal_shm "$state_dir/data/db.sqlite3" || true

    local rel_project="${PROJECT_ROOT#/}"
    if [[ -d "$staging/$rel_project" ]]; then
        log_info "Restoring project config files from archive..."

        local config_files=(
            docker-compose.yml
            docker-compose.override.yml
            .env.example
        )
        [[ "$RESTORE_ENV" == "true" ]] && config_files=(.env "${config_files[@]}")
        for f in "${config_files[@]}"; do
            local src="$staging/$rel_project/$f"
            if [[ -f "$src" ]]; then
                if [[ "$f" == ".env" ]] && [[ -f "$PROJECT_ROOT/.env" ]]; then
                    cp -f "$PROJECT_ROOT/.env" "$PROJECT_ROOT/.env.pre-restore-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
                fi
                cp -f "$src" "$PROJECT_ROOT/$f"
                log_info "  Restored: $f"
            fi
        done

        local config_dirs=(caddy fail2ban nginx)
        for d in "${config_dirs[@]}"; do
            local src_dir="$staging/$rel_project/$d"
            local dst_dir="$PROJECT_ROOT/$d"
            if [[ -d "$src_dir" ]]; then
                if [[ -d "$dst_dir" ]]; then
                    cp -a "$dst_dir" "${dst_dir}.pre-restore-${ts}"
                    log_info "  Backed up existing $d/ to ${d}.pre-restore-${ts}/"
                fi
                mkdir -p "$dst_dir"
                cp -a "$src_dir/." "$dst_dir/"
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
    log_header "VaultWarden-OCI Restore Utility"

    if [[ "$LIST_ONLY" == "true" ]]; then
        list_backups
        exit 0
    fi

    require_root "$@"

    ensure_dir "$VW_LOCK_DIR" 700 "$(get_real_user)" || {
        log_error "Failed to initialize operations lock directory: $VW_LOCK_DIR"
        exit 1
    }

    exec 200>"$VW_OPERATIONS_LOCK"
    if ! flock -n 200; then
        log_error "Another update/restore/maintenance/backup operation is already running."
        log_error "Lock file: $VW_OPERATIONS_LOCK"
        exit 1
    fi

    local RESTORE_LOCK_FILE="/var/lock/vaultwarden-restore.lock"
    local RESTORE_LOCK_FD=203
    eval "exec ${RESTORE_LOCK_FD}>\"$RESTORE_LOCK_FILE\""
    if ! flock -n $RESTORE_LOCK_FD; then
        log_error "Another restore is already running (could not acquire lock)."
        log_error "Wait for it to complete, then retry."
        log_error "If the lock is stale, remove: ${RESTORE_LOCK_FILE}"
        exit 1
    fi

    load_env_file || { log_error "Failed to load .env"; exit 1; }

    local STATE_DIR="$(get_config_value    "PROJECT_STATE_DIR"   "/var/lib/vaultwarden")"
    local AGE_KEY_FILE="$(get_config_value "SOPS_AGE_KEY_FILE"   "secrets/keys/age-key.txt")"
    local PUID="$(get_config_value "PUID" "")"
    local PGID="$(get_config_value "PGID" "")"

    if [[ -z "$PUID" || -z "$PGID" ]]; then
        log_error "PUID and PGID must be set in .env before restoring."
        log_error "These must match the UID/GID that owns the VaultWarden data files."
        log_error "Find the correct values with: id <your-username>"
        log_error "Then add PUID=<uid> and PGID=<gid> to your .env file."
        exit 1
    fi

    [[ -f "$AGE_KEY_FILE" ]] || { log_error "Age key not found: $AGE_KEY_FILE"; exit 1; }

    resolve_backup_file || exit 1
    [[ -f "$BACKUP_FILE" ]] || { log_error "Backup file not found: $BACKUP_FILE"; exit 1; }

    local sha256_sidecar="${BACKUP_FILE}.sha256"
    if [[ -f "$sha256_sidecar" && "$SKIP_VERIFICATION" != "true" ]]; then
        log_info "Verifying backup checksum before decryption..."
        local expected_sum actual_sum
        expected_sum=$(cat "$sha256_sidecar")
        actual_sum=$(sha256sum "$BACKUP_FILE" | awk '{print $1}')
        if [[ "$expected_sum" != "$actual_sum" ]]; then
            log_error "Checksum MISMATCH — backup file may be corrupted or tampered."
            log_error "  Expected: $expected_sum"
            log_error "  Actual:   $actual_sum"
            log_error "Do not restore from this file. Locate an earlier backup."
            exit 1
        fi
        log_success "Backup checksum verified: $(basename "$BACKUP_FILE")"
    elif [[ -f "$sha256_sidecar" && "$SKIP_VERIFICATION" == "true" ]]; then
        log_warn "--skip-verification: SHA-256 sidecar check bypassed."
        log_warn "Proceeding to Age decryption — AEAD will still verify authenticity."
    else
        log_warn "No .sha256 sidecar found — skipping pre-decryption checksum check."
        log_warn "(Backups created before v2 did not generate sidecar files.)"
    fi

    local meta_file="${BACKUP_FILE}.meta"
    local archive_version archive_format

    archive_version="$(read_meta_field "$meta_file" "version" "")"
    archive_format="$( read_meta_field "$meta_file" "archive_format" "")"

    if [[ -z "$archive_format" ]]; then
        if [[ "$BACKUP_FILE" == *.tar.zst.age || "$BACKUP_FILE" == *.zst.age ]]; then
            archive_format="relative"
            log_info "archive_format not in .meta; inferred 'relative' from .zst extension."
        elif [[ "$archive_version" == "2" ]]; then
            archive_format="relative"
            log_info "archive_format not in .meta; defaulting to 'relative' (version=2)."
        elif [[ "$archive_version" == "1" ]]; then
            archive_format="absolute"
            log_info "archive_format not in .meta; defaulting to 'absolute' (version=1 legacy)."
        else
            archive_format="relative"
            log_warn "archive_format and version absent from .meta; defaulting to 'relative'."
            log_warn "If this is a v1 (absolute-path) archive, add --type and re-check the .meta file."
        fi
    fi

    [[ -z "$archive_version" ]] && archive_version="unknown"

    log_info "Restore plan:"
    log_info "  File:           $BACKUP_FILE"
    log_info "  Type:           $RESTORE_TYPE"
    log_info "  Archive ver:    $archive_version (format: $archive_format)"
    log_info "  State dir:      $STATE_DIR"
    log_info "  Age key:        $AGE_KEY_FILE"

    if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" ]]; then
        echo ""
        log_warn  "WARNING: This will overwrite current data."
        log_warn  "Services will be stopped during the restore."
        echo ""
        read -r -p "Type 'yes' to proceed: " confirm
        [[ "$confirm" == "yes" ]] || { log_info "Restore cancelled."; exit 0; }
    fi

    local old_umask
    old_umask=$(umask)
    umask 077
    local tmp_parent
    tmp_parent="$(dirname "$STATE_DIR")"
    TMPDIR_RESTORE="$(mktemp -d -p "$tmp_parent" vw_restore.XXXXXXXXXX)" || {
        log_error "Failed to create secure temporary directory"
        exit 1
    }
    umask "$old_umask"

    create_pre_restore_snapshot || exit 1

    if [[ "$DRY_RUN" != "true" ]]; then
        if docker compose ps --status running --services 2>/dev/null | grep -q .; then
            log_info "Stopping services..."
            docker compose stop
        fi
    fi

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

    if [[ "$DRY_RUN" != "true" ]]; then
        case "$RESTORE_TYPE" in
            db)
                cleanup_pre_restore_artefacts "${STATE_DIR}/data/db.sqlite3" 3 || true
                ;;
            full|emergency)
                cleanup_pre_restore_artefacts "$STATE_DIR" 3 || true
                ;;
        esac
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        log_info "Starting services..."
        if ! docker compose up -d --remove-orphans; then
            log_error "Failed to start services after restore."
            log_error "Investigate with: docker compose logs --tail=50"
            exit 1
        fi

        log_info "Waiting for services to initialize (up to 60s on cold start)..."
        local max_wait=60 waited=0
        while (( waited < max_wait )); do
            sleep 5; (( waited += 5 ))
            if docker inspect vaultwarden_app --format '{{.State.Status}} {{.State.Health.Status}}' 2>/dev/null | grep -qE $'running (healthy|$)'; then
                break
            fi
        done

        if [[ -x "./health.sh" ]]; then
            log_info "Running post-restore health check..."
            ./health.sh --quiet || {
                log_warn "Health check reported issues after restore."
                log_warn "Investigate with: docker compose logs --tail=50"
            }
        fi
    fi

    log_success "Restore complete."
}

main "$@"
