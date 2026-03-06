#!/usr/bin/env bash
# restore.sh - VaultWarden-OCI safe restore
#
# Supports both archive formats:
#   version=2 / archive_format=relative  →  staged restore (atomic, safe)
#   version=1 (legacy absolute paths)    →  direct -C / extraction (backward compat)
#
# Safety features:
#   - require_root enforced via lib/common.sh (--list is exempt)
#   - All decrypted artifacts in mktemp dir + EXIT/INT/TERM trap
#   - Host sqlite3 for integrity checks (FIX-R06: Docker dependency removed)
#   - tar member validation blocks path traversal before extraction
#     (FIX-R01: now applied to BOTH legacy v1 AND current v2 paths)
#   - Staged full restore: extract → validate → atomic mv (all-or-nothing)
#   - PROJECT_ROOT config files (.env, docker-compose.yml, caddy/, fail2ban/)
#     restored from archive after STATE_DIR promotion; secrets/ and *.sh
#     scripts are intentionally excluded
#   - Pre-restore emergency snapshot before any destructive operation
#   - AGE_KEY_FILE read from .env (SOPS_AGE_KEY_FILE) with safe default
#   - .sha256 sidecar verified before decryption (FIX-R05)
#   - flock mutex prevents concurrent restore races (FIX-R03)
#   - .pre-restore-* artefacts pruned to keep last 3 (FIX-R08)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# Shared operations lock (update.sh/maintenance.sh/restore.sh)
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

show_help() {
    cat << 'EOF'
VaultWarden-OCI Restore Script

USAGE:
    sudo ./restore.sh [OPTIONS]

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

EXAMPLES:
    ./restore.sh --list
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

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_find_latest_backup() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    # Use portable stat instead of GNU-specific -printf '%T@'
    find "$dir" -name "*.age" -type f | while IFS= read -r f; do
        printf '%s %s\n' \
            "$(stat -c%Y "$f" 2>/dev/null || stat -f%m "$f" 2>/dev/null || echo 0)" \
            "$f"
    done | sort -n | tail -1 | cut -d' ' -f2-
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

# Block archives containing ../  traversal sequences.
# NOTE: This function also rejects absolute paths (/). For the legacy v1
# restore path, use check_traversal_only() below, which only checks for
# ../ sequences (v1 archives intentionally use absolute paths).
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

# FIX-R01 helper: Traversal-only check for legacy v1 absolute-path archives.
# v1 archives use absolute paths by design, so we only reject ../ sequences.
check_traversal_only() {
    local tarfile="$1"
    local bad_members
    bad_members=$(tar -tzf "$tarfile" 2>/dev/null \
        | grep -E '(^|/)\.\.(/|$)' || true)
    if [[ -n "$bad_members" ]]; then
        log_error "Archive contains path traversal sequences (../). Refusing to extract."
        log_error "Suspicious paths:"
        echo "$bad_members" | head -10 >&2
        return 1
    fi
    return 0
}

# FIX-R06: Replace verify_sqlite_docker() with verify_sqlite() using the
# host sqlite3 binary. sqlite3 is installed by setup.sh's basic_packages
# array. Spinning up an alpine:latest container with --user root to run a
# one-line SQL command is an unnecessary supply-chain risk and Docker dep.
verify_sqlite() {
    local dbfile="$1"
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
        ./backup.sh --type emergency --quiet || log_warn "Pre-restore snapshot failed (continuing)"
    else
        log_warn "backup.sh not executable — skipping pre-restore snapshot"
    fi
}

# FIX-R08: Prune .pre-restore-* artefacts created by restore_db / restore_full.
# Each restore renames the current db file or state directory to a timestamped
# .pre-restore-<ts> path. Without pruning these accumulate indefinitely and
# will eventually exhaust disk space on a 40 GiB OCI boot volume.
#
# Keeps the $keep_count most recent artefacts; removes the rest.
# Sort order is lexicographic on the timestamp suffix (YYYYmmdd-HHMMSS), which
# equals chronological order without needing stat.
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

    # FIX-R06: Use host sqlite3 instead of Docker alpine container.
    if [[ "$SKIP_VERIFICATION" != "true" ]]; then
        verify_sqlite "$dec_db" || return 1
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

        # FIX-R01: Path traversal check on the legacy path.
        # This branch previously had NO traversal validation at all, making it
        # the most dangerous case: a tampered .age file (decryptable with the
        # correct Age key) could embed ../../etc/cron.d/backdoor entries that
        # extract directly to / as root.
        #
        # We use check_traversal_only() here, NOT tar_validate_members():
        # v1 archives intentionally use absolute paths, so rejecting all
        # absolute paths would always fail. We only block ../ sequences.
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
    tar -xzf "$dec_tar" -C "$staging" --no-same-owner --no-same-permissions --delay-directory-restore

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

        # Config directories (caddy, fail2ban, nginx — excludes secrets/)
        # Preserve a timestamped backup of any existing directory before applying
        # restored content, so local customizations are recoverable.
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

    # FIX-R04: --list does not require root. It only reads local backup file
    # metadata (find + ls on the backups/ tree). Requiring root prevented
    # non-privileged operators from inspecting what backups are available
    # before deciding whether a restore is needed.
    if [[ "$LIST_ONLY" == "true" ]]; then
        list_backups
        exit 0
    fi

    require_root "$@"

    # Shared operations mutex to prevent overlap with update/maintenance jobs.
    ensure_dir "$VW_LOCK_DIR" 700 "$(get_real_user)" || {
        log_error "Failed to initialize operations lock directory: $VW_LOCK_DIR"
        exit 1
    }

    exec 9>"$VW_OPERATIONS_LOCK"
    if ! flock -n 9; then
        log_error "Another update/restore/maintenance operation is already running."
        log_error "Lock file: $VW_OPERATIONS_LOCK"
        exit 1
    fi

    # FIX-R03: Prevent concurrent restore runs.
    # A race between two simultaneous restores — or a restore racing with a
    # running backup — can corrupt the atomic state-dir swap in restore_full():
    # if both runs reach the mv step concurrently the .pre-restore-<ts> swap
    # may clobber itself, leaving the vault in an unrecoverable split state.
    local RESTORE_LOCK_FILE="/var/lock/vaultwarden-restore.lock"
    local RESTORE_LOCK_FD=203
    eval "exec ${RESTORE_LOCK_FD}>\"$RESTORE_LOCK_FILE\""
    if ! flock -n $RESTORE_LOCK_FD; then
        log_error "Another restore is already running (could not acquire lock)."
        log_error "Wait for it to complete, then retry."
        log_error "If the lock is stale, remove: ${RESTORE_LOCK_FILE}"
        exit 1
    fi

    # Load environment
    load_env_file || { log_error "Failed to load .env"; exit 1; }

    local STATE_DIR AGE_KEY_FILE PUID PGID
    STATE_DIR="$(get_config_value    "PROJECT_STATE_DIR"   "/var/lib/vaultwarden")"
    AGE_KEY_FILE="$(get_config_value "SOPS_AGE_KEY_FILE"   "secrets/keys/age-key.txt")"

    # FIX-R07: Make missing PUID/PGID a hard error rather than silently
    # defaulting to 1001. On a fresh restore target UID 1001 may belong to
    # a different user or be unallocated. Containers running as the wrong UID
    # cannot write to the restored data directory and fail with misleading
    # permission errors that are not immediately obvious as a restore problem.
    PUID="$(get_config_value "PUID" "")"
    PGID="$(get_config_value "PGID" "")"

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

    # FIX-R05: Verify .sha256 sidecar before attempting decryption.
    # backup.sh writes a .sha256 file alongside every .age archive. Checking
    # it here detects bitrot and accidental or deliberate tampering without
    # consuming the Age key — fast, key-less, defence-in-depth.
    # Warn-only (not hard-fail) when the sidecar is absent for backward
    # compatibility with v1 backups that pre-date sidecar generation.
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

    # FIX-R09: Register cleanup() BEFORE mktemp so that any set -e exit
    # between mktemp and the original trap registration cannot leave a
    # decrypted archive in /tmp. The null-guard on TMPDIR_RESTORE ensures
    # the handler is a no-op if mktemp itself fails.
    local TMPDIR_RESTORE=""
    cleanup() { [[ -n "$TMPDIR_RESTORE" ]] && rm -rf "$TMPDIR_RESTORE" 2>/dev/null || true; }
    trap cleanup EXIT HUP INT TERM

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

    create_pre_restore_snapshot

    # Stop services
    if [[ "$DRY_RUN" != "true" ]]; then
        if docker compose ps --status running --services 2>/dev/null | grep -q .; then
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

    # FIX-R08: Prune old .pre-restore-* artefacts after a successful restore.
    # Each restore run creates a dated rollback copy; without pruning these
    # accumulate indefinitely. Keep the 3 most recent for safety.
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

    # FIX-R02: Use docker compose up -d instead of docker compose start.
    # docker compose start only resumes ALREADY-CREATED containers.
    # On a fresh disaster-recovery server no containers have ever been
    # created, so start exits silently, the vault is completely down, and
    # the restore incorrectly reports success. docker compose up -d
    # --remove-orphans creates containers if they do not exist AND starts
    # them if they are stopped — correct in both scenarios.
    if [[ "$DRY_RUN" != "true" ]]; then
        log_info "Starting services..."
        if ! docker compose up -d --remove-orphans; then
            log_error "Failed to start services after restore."
            log_error "Investigate with: docker compose logs --tail=50"
            exit 1
        fi

        # Wait for services to initialize with retry loop for cold-start DR
        log_info "Waiting for services to initialize (up to 60s on cold start)..."
        local max_wait=60 waited=0
        while (( waited < max_wait )); do
            sleep 5; (( waited += 5 ))
            if docker inspect vaultwarden_app --format '{{.State.Status}} {{.State.Health.Status}}' 2>/dev/null | grep -qE 'running (healthy|$)'; then
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
