#!/usr/bin/env bash
# backup.sh - VaultWarden-OCI backup (atomic DB snapshot, relative-path archive, age encryption)
# archive_format=relative: archives use paths relative to / so restores can stage safely.
#
# Fix: global TMPDIR_BACKUP created in main() with EXIT/INT/TERM trap so all
# decrypted/intermediate artifacts are purged on any exit, including SIGINT
# mid-function (previously each function had its own mktemp with manual rm -rf,
# leaving plaintext snapshots on disk if the process was killed between steps).

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
# Configuration
# ---------------------------------------------------------------------------
BACKUP_TYPE="auto"   # auto | db | full | emergency
DRY_RUN=false
KEEP_DAYS=14
QUIET=false
FORCE=false
LOCK_FD=200

show_help() {
    cat << 'EOF'
VaultWarden-OCI Backup Script

USAGE:
    sudo ./backup.sh [OPTIONS]

OPTIONS:
    --type TYPE     auto (default) | db | full | emergency
    --dry-run       Show what would be done without executing
    --keep N        Retention period in days (default: 14)
    --quiet         Suppress non-error output
    --force         Ignore locks and force backup
    --help          Show this help

EXAMPLES:
    sudo ./backup.sh                   # Auto mode
    sudo ./backup.sh --type db         # Database-only backup
    sudo ./backup.sh --type full       # Full state backup
    sudo ./backup.sh --keep 30         # Keep 30 days of backups
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --type)    BACKUP_TYPE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true;    shift ;;
        --keep)    KEEP_DAYS="$2";  shift 2 ;;
        --quiet)   QUIET=true;      shift ;;
        --force)   FORCE=true;      shift ;;
        --help)    show_help; exit 0 ;;
        *)         log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

b_log_info()    { [[ "$QUIET" == "true" ]] || log_info "$*";    }
b_log_success() { [[ "$QUIET" == "true" ]] || log_success "$*"; }
b_log_warn()    { [[ "$QUIET" == "true" ]] || log_warn "$*";    }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

get_backup_dir() {
    local type="$1"
    local dir="$PROJECT_ROOT/backups/$type"
    ensure_dir "$dir" 750 "$(get_real_user)"
    echo "$dir"
}

get_age_public_key() {
    local age_key_file
    age_key_file="$(get_config_value "SOPS_AGE_KEY_FILE" "secrets/keys/age-key.txt")"
    if [[ ! -f "$age_key_file" ]]; then
        log_error "Age key file not found: $age_key_file"
        return 1
    fi
    local pub_key
    pub_key=$(grep -m 1 "public key: " "$age_key_file" | cut -d: -f2 | tr -d ' ')
    if [[ -z "$pub_key" ]]; then
        log_error "Could not extract public key from $age_key_file"
        return 1
    fi
    echo "$pub_key"
}

auto_determine_backup_type() {
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    local db_file="$state_dir/data/db.sqlite3"

    if [[ ! -f "$db_file" ]]; then
        b_log_info "Database not found — defaulting to full backup"
        echo "full"; return 0
    fi

    local db_mtime current_time age_hours
    db_mtime=$(stat -c %Y "$db_file" 2>/dev/null || stat -f %m "$db_file" 2>/dev/null || echo "0")
    current_time=$(date +%s)
    age_hours=$(( (current_time - db_mtime) / 3600 ))

    local full_backup_dir last_full full_age_days=999
    full_backup_dir=$(get_backup_dir "full")
    last_full=$(find "$full_backup_dir" -name "*.age" -type f 2>/dev/null | sort | tail -1 || true)
    if [[ -n "$last_full" ]]; then
        local full_mtime
        full_mtime=$(stat -c %Y "$last_full" 2>/dev/null || stat -f %m "$last_full" 2>/dev/null || echo "0")
        full_age_days=$(( (current_time - full_mtime) / 86400 ))
    fi

    if (( age_hours < 24 )) && (( full_age_days < 7 )); then
        echo "db"
    else
        echo "full"
    fi
}

# ---------------------------------------------------------------------------
# SQLite integrity check via docker (no host sqlite3 dependency)
# ---------------------------------------------------------------------------
verify_sqlite_docker() {
    local dbfile="$1"
    b_log_info "Verifying SQLite integrity (docker alpine+sqlite)..."
    if docker run --rm -v "${dbfile}:/db.sqlite3" alpine:latest \
        sh -c 'apk add -q sqlite >/dev/null 2>&1 && sqlite3 /db.sqlite3 "PRAGMA integrity_check;"' \
        | grep -qx "ok"; then
        b_log_success "SQLite integrity check passed"
        return 0
    else
        log_error "SQLite integrity check FAILED"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# DB snapshot via docker (no host sqlite3 dependency, handles WAL safely)
# ---------------------------------------------------------------------------
create_db_snapshot_docker() {
    local state_dir="$1"
    local dest="$2"
    docker run --rm --user root \
        -v "${state_dir}/data:/data" \
        -v "$(dirname "$dest"):/snapshot" \
        alpine:latest \
        sh -c 'apk add -q sqlite >/dev/null 2>&1 && sqlite3 /data/db.sqlite3 ".backup /snapshot/'"$(basename "$dest")"'"'
}

# ---------------------------------------------------------------------------
# Database-only backup
# ---------------------------------------------------------------------------
perform_db_backup() {
    local target_dir="$1"
    local timestamp="$2"
    local age_pub_key="$3"
    local shared_tmpdir="$4"    # provided by main(); covered by global EXIT/INT/TERM trap
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")

    b_log_info "Performing database backup..."

    if [[ "$DRY_RUN" == "true" ]]; then
        b_log_info "[DRY RUN] Would backup DB → $target_dir/db_backup_$timestamp.sqlite3.age"
        return 0
    fi

    local db_file="$state_dir/data/db.sqlite3"
    [[ -f "$db_file" ]] || { log_error "Database not found: $db_file"; return 1; }

    local snap="$shared_tmpdir/db.sqlite3"

    b_log_info "Creating atomic DB snapshot..."
    if ! create_db_snapshot_docker "$state_dir" "$snap"; then
        b_log_warn "Docker snapshot failed — falling back to cp (services should be stopped)"
        cp "$db_file" "$snap"
    fi

    verify_sqlite_docker "$snap" || return 1

    b_log_info "Encrypting DB snapshot..."
    local enc="$target_dir/db_backup_$timestamp.sqlite3.age"
    if ! age -r "$age_pub_key" -o "$enc" "$snap"; then
        log_error "Encryption failed"
        return 1
    fi
    secure_file "$enc" 600

    [[ -s "$enc" ]] || { log_error "Encrypted output is empty"; rm -f "$enc"; return 1; }

    cat > "${enc}.meta" <<MEOF
type=db
timestamp=$timestamp
original_size=$(stat -c%s "$db_file" 2>/dev/null || stat -f%z "$db_file" 2>/dev/null || echo 0)
archive_format=relative
version=2
MEOF

    b_log_success "DB backup: $(basename "$enc")"
    echo "$enc"
}

# ---------------------------------------------------------------------------
# Full / emergency backup  (RELATIVE-PATH archive)
# ---------------------------------------------------------------------------
perform_full_backup() {
    local target_dir="$1"
    local timestamp="$2"
    local age_pub_key="$3"
    local backup_label="${4:-full}"   # full | emergency
    local shared_tmpdir="$5"          # provided by main(); covered by global EXIT/INT/TERM trap
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")

    b_log_info "Performing ${backup_label} backup (relative-path archive)..."

    if [[ "$DRY_RUN" == "true" ]]; then
        b_log_info "[DRY RUN] Would create ${backup_label} backup → $target_dir/${backup_label}_backup_$timestamp.tar.gz.age"
        return 0
    fi

    require_commands tar || return 1

    local snap_dir="$shared_tmpdir/stage"
    local snap_db="$snap_dir/${state_dir#/}/data/db.sqlite3"
    local temp_tar="$shared_tmpdir/${backup_label}_backup_$timestamp.tar.gz"

    mkdir -p "$(dirname "$snap_db")"

    # -----------------------------------------------------------------------
    # 1. Atomic DB snapshot → staging tree
    # -----------------------------------------------------------------------
    local db_file="$state_dir/data/db.sqlite3"
    local db_snapshot_ok=false

    if [[ -f "$db_file" ]]; then
        b_log_info "Creating atomic DB snapshot..."
        if create_db_snapshot_docker "$state_dir" "$snap_db" 2>/dev/null; then
            db_snapshot_ok=true
        else
            b_log_warn "Docker snapshot failed — will use live DB file in archive"
        fi
    fi

    # -----------------------------------------------------------------------
    # 2. Build relative-path tar with -C /
    #    All members will be  var/lib/vaultwarden/...  and  opt/vaultwarden/...
    #    (or wherever PROJECT_ROOT / STATE_DIR live) — never /absolute paths.
    # -----------------------------------------------------------------------
    b_log_info "Archiving state (relative paths, safe for staged restore)..."

    local tar_excludes=(
        "--exclude=${PROJECT_ROOT#/}/backups"
        "--exclude=${PROJECT_ROOT#/}/logs"
        "--exclude=${state_dir#/}/logs"
        "--exclude=*.sock"
        "--exclude=*.lock"
    )

    local tar_sources=()

    # Always include project root
    tar_sources+=("${PROJECT_ROOT#/}")

    # Include state dir, but if we have a clean snapshot:
    #   - exclude the live DB + WAL/SHM from the archive
    #   - we'll merge the snapshot files in next
    if [[ "$db_snapshot_ok" == "true" ]]; then
        tar_excludes+=(
            "--exclude=${state_dir#/}/data/db.sqlite3"
            "--exclude=${state_dir#/}/data/db.sqlite3-wal"
            "--exclude=${state_dir#/}/data/db.sqlite3-shm"
        )
        tar_sources+=("${state_dir#/}")
    else
        tar_sources+=("${state_dir#/}")
    fi

    # -----------------------------------------------------------------------
    # 3. Create the compressed archive from /  (relative paths)
    # -----------------------------------------------------------------------
    local tar_exit=0
    tar -czf "$temp_tar" \
        -C / \
        "${tar_excludes[@]}" \
        "${tar_sources[@]}" 2>/dev/null || tar_exit=$?

    # tar exits 1 for harmless warnings (file changed); only >1 is a real error
    if (( tar_exit > 1 )); then
        log_error "tar failed with exit code $tar_exit"
        return 1
    fi

    # -----------------------------------------------------------------------
    # 4. Inject the clean DB snapshot into the archive
    #    We must work with an uncompressed copy to use tar --append,
    #    then recompress.
    # -----------------------------------------------------------------------
    if [[ "$db_snapshot_ok" == "true" ]]; then
        b_log_info "Injecting clean DB snapshot into archive..."
        local temp_tar_raw="$shared_tmpdir/${backup_label}_backup_$timestamp.tar"

        # Decompress → append → recompress
        if gunzip -c "$temp_tar" > "$temp_tar_raw" \
            && tar -rf "$temp_tar_raw" -C "$snap_dir" "${state_dir#/}/data/db.sqlite3" \
            && gzip -9 -c "$temp_tar_raw" > "${temp_tar}.new"
        then
            mv "${temp_tar}.new" "$temp_tar"
            rm -f "$temp_tar_raw"
            b_log_success "Clean DB snapshot injected"
        else
            b_log_warn "DB snapshot injection failed — archive will use live DB copy"
            rm -f "$temp_tar_raw" "${temp_tar}.new" 2>/dev/null || true
            # Rebuild without snapshot exclusion
            tar_excludes=(
                "--exclude=${PROJECT_ROOT#/}/backups"
                "--exclude=${PROJECT_ROOT#/}/logs"
                "--exclude=${state_dir#/}/logs"
                "--exclude=*.sock"
                "--exclude=*.lock"
            )
            tar_exit=0
            tar -czf "$temp_tar" -C / "${tar_excludes[@]}" "${tar_sources[@]}" 2>/dev/null || tar_exit=$?
            (( tar_exit <= 1 )) || { log_error "Rebuild tar failed"; return 1; }
        fi
    fi

    # -----------------------------------------------------------------------
    # 5. Encrypt
    # -----------------------------------------------------------------------
    b_log_info "Encrypting ${backup_label} archive..."
    local enc="$target_dir/${backup_label}_backup_$timestamp.tar.gz.age"

    if ! age -r "$age_pub_key" -o "$enc" "$temp_tar"; then
        log_error "Encryption failed"
        return 1
    fi
    secure_file "$enc" 600

    [[ -s "$enc" ]] || { log_error "Encrypted output is empty"; rm -f "$enc"; return 1; }

    cat > "${enc}.meta" <<MEOF
type=${backup_label}
timestamp=$timestamp
archive_format=relative
version=2
MEOF

    b_log_success "${backup_label^} backup: $(basename "$enc")"
    echo "$enc"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    require_root "$@"

    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    local LOCK_FILE="${state_dir}/.locks/backup.lock"

    # Global tmpdir — all decrypted/intermediate artifacts land here.
    # Trap ensures cleanup on any exit (normal, SIGINT, SIGTERM, ERR via set -e).
    local TMPDIR_BACKUP
    TMPDIR_BACKUP="$(mktemp -d)"
    cleanup() { rm -rf "$TMPDIR_BACKUP" 2>/dev/null || true; }
    trap cleanup EXIT HUP INT TERM

    # flock-based lock — kernel releases on any exit, no stale locks
    if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" ]]; then
        mkdir -p "${state_dir}/.locks" 2>/dev/null || true
        eval "exec ${LOCK_FD}>\"$LOCK_FILE\""
        if ! flock -n $LOCK_FD; then
            log_error "Another backup is already running (could not acquire lock)."
            log_info  "Wait for it to finish or use --force if you are certain it is stuck."
            exit 1
        fi
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_header "VaultWarden-OCI Backup [DRY RUN]"
    else
        log_header "VaultWarden-OCI Backup"
    fi

    load_env_file || { log_error "Failed to load .env"; exit 1; }

    local age_pub_key
    age_pub_key=$(get_age_public_key) || exit 1

    local actual_type="$BACKUP_TYPE"
    if [[ "$BACKUP_TYPE" == "auto" ]]; then
        actual_type=$(auto_determine_backup_type)
        b_log_info "Auto-selected backup type: $actual_type"
    fi

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_dir
    backup_dir=$(get_backup_dir "$actual_type")

    local backup_success=false
    case "$actual_type" in
        db)
            perform_db_backup "$backup_dir" "$timestamp" "$age_pub_key" "$TMPDIR_BACKUP" && backup_success=true
            ;;
        full|emergency)
            perform_full_backup "$backup_dir" "$timestamp" "$age_pub_key" "$actual_type" "$TMPDIR_BACKUP" && backup_success=true
            ;;
        *)
            log_error "Invalid backup type: $actual_type"; exit 1 ;;
    esac

    if [[ "$backup_success" == "true" && "$DRY_RUN" == "false" ]]; then
        b_log_info "Cleaning up old backups (retention: $KEEP_DAYS days)..."
        cleanup_old_backups "$backup_dir" "$actual_type" "$KEEP_DAYS" || \
            b_log_warn "Failed to clean up some old backups"
        b_log_success "Backup completed successfully"
        exit 0
    elif [[ "$DRY_RUN" == "true" ]]; then
        b_log_success "Dry run completed"
        exit 0
    else
        log_error "Backup failed"
        exit 1
    fi
}

main "$@"
