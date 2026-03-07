#!/usr/bin/env bash
# backup.sh - VaultWarden-OCI backup (atomic DB snapshot, relative-path archive, age encryption)
# archive_format=relative: archives use paths relative to / so restores can stage safely.
#
# FIX-B03: global TMPDIR_BACKUP created in main() with cleanup() trap registered BEFORE mktemp
# so all decrypted/intermediate artifacts are purged on any exit, including SIGINT mid-function.
#
# FIX-B01/FIX-B02: Docker sqlite3 dependency removed. verify_sqlite_docker() and
# create_db_snapshot_docker() replaced with host sqlite3 equivalents:
#   - verify_sqlite()          uses host 'sqlite3 PRAGMA integrity_check'
#   - create_db_snapshot_host() uses host 'sqlite3 .backup' (SQLite Online Backup API)
# sqlite3 is installed by setup.sh's basic_packages array.

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
    EMAIL_NOTIFY=false   # set by --email; send_notification_email() called on completion
LIST_ONLY=false      # set by --list; print existing backups and exit (no root needed)
RCLONE_SYNC=false    # set by --rclone; sync encrypted backup to rclone remote after creation
FULL_VERIFY=false    # set by --full-verification; decrypt + integrity check before sync
LOCK_FD=200

show_help() {
    cat << 'EOF'
VaultWarden-OCI Backup Script

USAGE:
    sudo ./backup.sh [OPTIONS]

OPTIONS:
    --type TYPE              auto (default) | db | full | emergency
    --dry-run                Show what would be done without executing
    --keep N                 Retention period in days (default: 14)
    --quiet                  Suppress non-error output
    --force                  Ignore locks and force backup
    --email                  Send email notification on completion/failure
    --list                   List existing backups and exit (no root required)
    --rclone                 Sync encrypted backup to rclone remote after creation
    --full-verification      End-to-end decrypt + integrity check before sync (fatal on failure)
    --skip-full-verification Fast checksum only — explicit default
    --help                   Show this help

EXAMPLES:
    sudo ./backup.sh                                                    # Auto mode
    sudo ./backup.sh --type db                                          # Database-only backup
    sudo ./backup.sh --type full                                        # Full state backup
    sudo ./backup.sh --keep 30                                          # Keep 30 days of backups
    sudo ./backup.sh --type db --email                                  # DB backup with email notification
    ./backup.sh --list                                                  # List existing backups (no sudo)
    sudo ./backup.sh --type db --rclone --email                         # DB backup + offsite sync + email
    sudo ./backup.sh --type full --full-verification --rclone --email   # Full verified offsite backup
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --type)                   BACKUP_TYPE="$2"; shift 2 ;;
        --dry-run)                DRY_RUN=true;     shift ;;
        --keep)                   KEEP_DAYS="$2";   shift 2 ;;
        --quiet)                  QUIET=true;       shift ;;
        --force)                  FORCE=true;       shift ;;
        --email)                  EMAIL_NOTIFY=true; shift ;;
        --list)                   LIST_ONLY=true;   shift ;;
        --rclone)                 RCLONE_SYNC=true; shift ;;
        --full-verification)      FULL_VERIFY=true; shift ;;
        --skip-full-verification) FULL_VERIFY=false; shift ;;
        --help)                   show_help; exit 0 ;;
        *)                        log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

b_log_info()    { [[ "$QUIET" == "true" ]] || log_info "$*";    }
b_log_success() { [[ "$QUIET" == "true" ]] || log_success "$*"; }
b_log_warn()    { [[ "$QUIET" == "true" ]] || log_warn "$*";    }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# BUG-W fix: honour BACKUP_DIR from env/config; fall back to project-relative default.
get_backup_dir() {
    local type="$1"
    local base_dir
    base_dir="$(get_config_value "BACKUP_DIR" "$PROJECT_ROOT/backups")"
    local dir="$base_dir/$type"
    ensure_dir "$dir" 750 "$(get_real_user)"
    echo "$dir"
}

# List all *.age archives under BACKUP_DIR, grouped by type, with size and mtime.
list_backups() {
    local base_dir
    base_dir="$(get_config_value "BACKUP_DIR" "$PROJECT_ROOT/backups")"
    log_header "Existing Backups — $(date)"
    if [[ ! -d "$base_dir" ]]; then
        log_warn "Backup directory not found: $base_dir"
        return 0
    fi
    local found=0
    for type_dir in "$base_dir"/*/; do
        [[ -d "$type_dir" ]] || continue
        local type_name
        type_name="$(basename "$type_dir")"
        local files=()
        while IFS= read -r -d '' f; do
            files+=("$f")
        done < <(find "$type_dir" -maxdepth 1 -name "*.age" -type f -print0 2>/dev/null | sort -z)
        if (( ${#files[@]} > 0 )); then
            log_info "  [$type_name]"
            for f in "${files[@]}"; do
                local size mtime mtime_epoch
                size=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
                mtime_epoch=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
                mtime=$(date -d "@${mtime_epoch}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null \
                     || date -r "${mtime_epoch}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null \
                     || echo "?")
                log_info "    $(basename "$f")  ($size  $mtime)"
                (( ++found )) || true
            done
        fi
    done
    (( found > 0 )) || log_info "  No backups found."
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
# FIX-B01: SQLite integrity check using host sqlite3.
#
# Replaces verify_sqlite_docker() which ran 'apk add sqlite && sqlite3 PRAGMA'
# inside an alpine:latest container on every backup run. Problems with that:
#   - Requires pulling alpine:latest from Docker Hub (supply-chain risk)
#   - Read-write bind-mount over live VaultWarden data was unnecessarily broad
#   - Added 3-10s overhead per backup run due to container startup
#   - Created a root-owned container process with access to vault data
#
# sqlite3 is already installed on the host by setup.sh's basic_packages array.
# ---------------------------------------------------------------------------
verify_sqlite() {
    local dbfile="$1"
    b_log_info "Verifying SQLite integrity (host sqlite3)..."
    local result
    result=$(sqlite3 "$dbfile" "PRAGMA integrity_check;" 2>&1) || {
        log_error "SQLite integrity check error: ${result}"
        return 1
    }
    if [[ "$result" != "ok" ]]; then
        log_error "SQLite integrity check FAILED: ${result}"
        return 1
    fi
    b_log_success "SQLite integrity check passed"
    return 0
}

# ---------------------------------------------------------------------------
# FIX-B02: Atomic DB snapshot using host sqlite3 Online Backup API.
#
# Replaces create_db_snapshot_docker() which did:
#   docker run --rm --user root \
#       -v "${state_dir}/data:/data" \
#       -v "$(dirname "$dest"):/snapshot" \
#       alpine:latest sh -c 'apk add sqlite && sqlite3 /data/db.sqlite3 .backup ...'
#
# Problems with the Docker approach:
#   - Read-WRITE volume mount over the live data directory (only a read is needed)
#   - Pulls alpine:latest on every run unless cached (supply-chain risk + latency)
#   - Container overhead: 3-8 seconds of startup time on each backup
#   - Ran as root inside the container with direct access to vault data
#
# sqlite3 .backup uses the SQLite Online Backup API: creates an atomic,
# WAL-consistent point-in-time copy while VaultWarden is running, without
# blocking any writes. This is the same mechanism used by Litestream and
# litestream-based backup tools.
# ---------------------------------------------------------------------------
create_db_snapshot_host() {
    local state_dir="$1"
    local dest="$2"
    local db_file="${state_dir}/data/db.sqlite3"
    [[ -f "$db_file" ]] || { log_error "Database not found: $db_file"; return 1; }
    # Pass dest as a printf argument so any special characters (including single
    # quotes) in the path are treated as a plain string by sqlite3.
    sqlite3 "$db_file" "$(printf '.backup %s' "$dest")" || {
        log_error "sqlite3 .backup failed for: $db_file"
        return 1
    }
    return 0
}

# ---------------------------------------------------------------------------
# Full end-to-end verification: decrypt the just-created archive and re-verify.
# Uses $TMPDIR_BACKUP (already covered by EXIT/INT/TERM trap in main).
# FATAL on failure — a silently-corrupt backup is worse than no backup.
# FIX-B05: db branch now calls verify_sqlite() instead of verify_sqlite_docker().
# ---------------------------------------------------------------------------
verify_backup_full() {
    local enc_file="$1"
    local backup_type="$2"
    local shared_tmpdir="$3"

    b_log_info "Running full verification (decrypt + integrity check)..."

    local age_key_file
    age_key_file="$(get_config_value "SOPS_AGE_KEY_FILE" "secrets/keys/age-key.txt")"

    local dec_out="$shared_tmpdir/verify_$(basename "$enc_file" .age)"
    if ! age -d -i "$age_key_file" -o "$dec_out" "$enc_file"; then
        log_error "Full verification FAILED: could not decrypt $enc_file"
        return 1
    fi

    case "$backup_type" in
        db)
            # FIX-B05: host sqlite3 instead of Docker alpine container.
            verify_sqlite "$dec_out" || return 1
            ;;
        full|emergency)
            b_log_info "Verifying archive structure..."
            if ! tar -tzf "$dec_out" >/dev/null 2>&1; then
                log_error "Full verification FAILED: archive is corrupt or unreadable"
                return 1
            fi
            # Confirm the archive is non-trivially sized (>10 KB)
            local size
            size=$(stat -c%s "$dec_out" 2>/dev/null || stat -f%z "$dec_out" 2>/dev/null || echo 0)
            if (( size < 10240 )); then
                log_error "Full verification FAILED: archive suspiciously small (${size} bytes)"
                return 1
            fi
            ;;
    esac

    b_log_success "Full verification passed: $(basename "$enc_file")"
    rm -f "$dec_out"
    return 0
}

# ---------------------------------------------------------------------------
# Rclone offsite sync — NON-FATAL by design.
# Reads RCLONE_REMOTE_NAME from .env.
# Syncs only the specific backup file + its .meta and .sha256 sidecars.
# On failure: warns but does NOT mark the backup as failed (local copy is safe).
# ---------------------------------------------------------------------------
sync_to_rclone() {
    local enc_file="$1"
    local backup_type="$2"

    if ! command -v rclone >/dev/null 2>&1; then
        log_warn "rclone not installed — skipping offsite sync."
        log_warn "Install: https://rclone.tech/install/"
        return 1
    fi

    local remote_name
    remote_name="$(get_config_value "RCLONE_REMOTE_NAME" "")"
    if [[ -z "$remote_name" || "$remote_name" == "CHANGE_ME_RCLONE_REMOTE" ]]; then
        log_warn "RCLONE_REMOTE_NAME not configured in .env — skipping offsite sync."
        log_warn "Set RCLONE_REMOTE_NAME in .env and run: rclone config"
        return 1
    fi

    local remote_path="${remote_name}:vaultwarden_backups/${backup_type}"
    b_log_info "Syncing backup to rclone remote: ${remote_path}/"

    local rclone_ok=true

    # Copy the encrypted archive
    if ! rclone copy "$enc_file" "$remote_path/" --checksum 2>&1; then
        rclone_ok=false
    fi

    # Copy the .meta sidecar if it exists
    local meta_file="${enc_file}.meta"
    if [[ -f "$meta_file" ]]; then
        rclone copy "$meta_file" "$remote_path/" --checksum 2>&1 || true
    fi

    # Copy the .sha256 sidecar if it exists
    local sha256_file="${enc_file}.sha256"
    if [[ -f "$sha256_file" ]]; then
        rclone copy "$sha256_file" "$remote_path/" --checksum 2>&1 || true
    fi

    if [[ "$rclone_ok" == "true" ]]; then
        b_log_success "Offsite sync complete → ${remote_path}/$(basename "$enc_file")"
        return 0
    else
        log_warn "Rclone sync FAILED — backup is safe locally, but offsite copy was not updated."
        log_warn "Retry manually: rclone copy $enc_file ${remote_path}/"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Database-only backup
# FIX-B06: Uses create_db_snapshot_host() and verify_sqlite() (host sqlite3).
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

    # FIX-B06: Use host sqlite3 Online Backup API instead of Docker.
    b_log_info "Creating atomic DB snapshot (sqlite3 .backup)..."
    if ! create_db_snapshot_host "$state_dir" "$snap"; then
        # Fallback: checkpoint WAL then copy main DB file for best-effort consistency
        b_log_warn "Host sqlite3 snapshot failed — attempting offline fallback with WAL checkpoint"
        if ! sqlite3 "$db_file" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null; then
            b_log_warn "WAL checkpoint failed — copy may be missing recent uncommitted transactions"
            b_log_warn "For guaranteed consistency, stop VaultWarden before backup or fix sqlite3 .backup"
        fi
        cp "$db_file" "$snap"
        if [[ ! -s "$snap" ]]; then
            log_error "Fallback snapshot copy failed or produced empty file"
            return 1
        fi
    fi

    # FIX-B06: Use host sqlite3 integrity check instead of Docker.
    verify_sqlite "$snap" || return 1

    b_log_info "Encrypting DB snapshot..."
    # Atomic write: encrypt to .tmp then mv into place
    local enc="$target_dir/db_backup_$timestamp.sqlite3.age"
    local enc_tmp="${enc}.tmp"
    if ! age -r "$age_pub_key" -o "$enc_tmp" "$snap"; then
        log_error "Encryption failed"
        rm -f "$enc_tmp"
        return 1
    fi
    mv "$enc_tmp" "$enc"
    secure_file "$enc" 600

    # Generate SHA-256 checksum sidecar (verified by restore.sh before decryption)
    sha256sum "$enc" | awk '{print $1}' > "${enc}.sha256"
    chmod 600 "${enc}.sha256"

    [[ -s "$enc" ]] || { log_error "Encrypted output is empty"; rm -f "$enc" "${enc}.sha256"; return 1; }

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
# FIX-B07: Uses create_db_snapshot_host() (host sqlite3) instead of Docker.
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
    #    FIX-B07: Use host sqlite3 Online Backup API instead of Docker.
    # -----------------------------------------------------------------------
    local db_file="$state_dir/data/db.sqlite3"
    local db_snapshot_ok=false

    if [[ -f "$db_file" ]]; then
        b_log_info "Creating atomic DB snapshot (sqlite3 .backup)..."
        if create_db_snapshot_host "$state_dir" "$snap_db" 2>/dev/null; then
            db_snapshot_ok=true
        else
            b_log_warn "Host sqlite3 snapshot failed — will use live DB file in archive"
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
    #    MEDIUM-NEW-02: pre-flight disk space check to avoid exhausting TMPDIR
    # -----------------------------------------------------------------------
    if [[ "$db_snapshot_ok" == "true" ]]; then
        # Estimate required space before decompression:
        # - decompressed tar ~8–9x compressed
        # - plus new compressed copy
        # - plus snapshot DB
        # - plus 1 GiB safety margin
        local compressed_size snap_size available_kb required_kb
        compressed_size=$(stat -c%s "$temp_tar" 2>/dev/null || echo 0)
        snap_size=$(stat -c%s "$snap_db" 2>/dev/null || echo 0)
        available_kb=$(df -k "$(dirname "$temp_tar")" | awk 'NR==2{print $4}')
        if [[ -z "$available_kb" || "$available_kb" == "0" ]]; then
            log_warn "Could not determine available disk space — proceeding with caution"
            available_kb=0
        fi
        required_kb=$(( (compressed_size * 9 + snap_size) / 1024 + 1048576 ))

        if (( available_kb < required_kb )); then
            log_error "Insufficient space for safe DB snapshot injection in $(dirname "$temp_tar")"
            log_error "  Need: ~$((required_kb / 1024)) MB"
            log_error "  Free: $((available_kb / 1024)) MB"
            log_error "Aborting full/emergency backup to avoid fallback to a live DB copy."
            log_error "Free space or move TMPDIR to a larger filesystem, then retry."
            return 1
        fi
    fi

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
    # Atomic write: encrypt to .tmp then mv into place
    local enc="$target_dir/${backup_label}_backup_$timestamp.tar.gz.age"
    local enc_tmp="${enc}.tmp"

    if ! age -r "$age_pub_key" -o "$enc_tmp" "$temp_tar"; then
        log_error "Encryption failed"
        rm -f "$enc_tmp"
        return 1
    fi
    mv "$enc_tmp" "$enc"
    secure_file "$enc" 600

    # Generate SHA-256 checksum sidecar (verified by restore.sh before decryption)
    sha256sum "$enc" | awk '{print $1}' > "${enc}.sha256"
    chmod 600 "${enc}.sha256"

    [[ -s "$enc" ]] || { log_error "Encrypted output is empty"; rm -f "$enc" "${enc}.sha256"; return 1; }

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
    # --list does not require root; run before privilege check.
    if [[ "$LIST_ONLY" == "true" ]]; then
        load_env_file 2>/dev/null || true
        list_backups
        exit 0
    fi

    require_root "$@"

    # FIX-B03: Register cleanup() BEFORE mktemp so any set -e exit between
    # mktemp and the original trap registration cannot leave plaintext DB
    # snapshots or intermediate tar files in /tmp indefinitely.
    # The null-guard on TMPDIR_BACKUP ensures cleanup() is a no-op if
    # mktemp itself fails before the variable is assigned.
    local TMPDIR_BACKUP=""
    cleanup() { [[ -n "$TMPDIR_BACKUP" ]] && rm -rf "$TMPDIR_BACKUP" 2>/dev/null || true; }
    trap cleanup EXIT HUP INT TERM

    # FIX-B04: Move lock file to /var/lock/ (FHS-designated location).
    # The original path "${state_dir}/.locks/backup.lock" had two problems:
    #   1. state_dir was read before load_env_file, so it used the default
    #      "/var/lib/vaultwarden" even when .env overrides PROJECT_STATE_DIR.
    #   2. It required STATE_DIR to exist and be writable before the lock
    #      could be acquired — mkdir -p with wrong umask created it with
    #      potentially incorrect permissions on first run.
    # /var/lock is always available to root and has no STATE_DIR dependency.
    local LOCK_FILE="/var/lock/vaultwarden-backup.lock"

    # flock-based lock — kernel releases on any exit, no stale locks.
    if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" ]]; then
        eval "exec ${LOCK_FD}>\"$LOCK_FILE\""
        if ! flock -n $LOCK_FD; then
            log_error "Another backup is already running (could not acquire lock)."
            log_info  "Wait for it to finish or use --force if you are certain it is stuck."
            log_error "If the lock is stale, remove: ${LOCK_FILE}"
            exit 1
        fi
    fi

    # Create the secured temporary directory (now protected by trap above).
    local old_umask
    old_umask=$(umask)
    umask 077
    TMPDIR_BACKUP="$(mktemp -d -t vw_backup.XXXXXXXXXX)" || {
        log_error "Failed to create secure temporary directory"
        exit 1
    }
    umask "$old_umask"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_header "VaultWarden-OCI Backup [DRY RUN]"
    else
        log_header "VaultWarden-OCI Backup"
    fi

    load_env_file || { log_error "Failed to load .env"; exit 1; }

    # FIX-B04: Read state_dir AFTER load_env_file so that a PROJECT_STATE_DIR
    # override in .env is correctly picked up (previously read before load_env_file).
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")

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

    local backup_file=""
    local backup_success=false
    case "$actual_type" in
        db)
            backup_file=$(perform_db_backup "$backup_dir" "$timestamp" "$age_pub_key" "$TMPDIR_BACKUP") \
                && backup_success=true
            ;;
        full|emergency)
            backup_file=$(perform_full_backup "$backup_dir" "$timestamp" "$age_pub_key" "$actual_type" "$TMPDIR_BACKUP") \
                && backup_success=true
            ;;
        *)
            log_error "Invalid backup type: $actual_type"; exit 1 ;;
    esac

    if [[ "$backup_success" == "true" && "$DRY_RUN" == "false" ]]; then

        # Optional: full end-to-end verification (FATAL if enabled — a silently corrupt
        # backup is worse than a known-failed one; discard and exit immediately).
        if [[ "$FULL_VERIFY" == "true" ]]; then
            if ! verify_backup_full "$backup_file" "$actual_type" "$TMPDIR_BACKUP"; then
                log_error "Backup verification failed — discarding corrupt archive."
                rm -f "$backup_file" "${backup_file}.meta" "${backup_file}.sha256"
                exit 1
            fi
        fi

        # Optional: offsite rclone sync (NON-FATAL — local backup already succeeded).
        local rclone_failed=false
        if [[ "$RCLONE_SYNC" == "true" ]]; then
            sync_to_rclone "$backup_file" "$actual_type" || rclone_failed=true
        fi

        b_log_info "Cleaning up old backups (retention: $KEEP_DAYS days)..."
        cleanup_old_backups "$backup_dir" "$actual_type" "$KEEP_DAYS" || \
            b_log_warn "Failed to clean up some old backups"

        if [[ "$EMAIL_NOTIFY" == "true" ]]; then
            local rclone_status="skipped"
            [[ "$RCLONE_SYNC" == "true" && "$rclone_failed" == "false" ]] && rclone_status="synced"
            [[ "$RCLONE_SYNC" == "true" && "$rclone_failed" == "true"  ]] && rclone_status="FAILED"

            local subject="[VaultWarden] Backup completed: $actual_type ($timestamp)"
            local body
            body="$(printf 'Backup type:  %s\nTimestamp:    %s\nFile:         %s\nVerification: %s\nOffsite sync: %s\nHost:         %s\n' \
                "$actual_type" "$timestamp" \
                "$(basename "${backup_file:-unknown}")" \
                "$( [[ "$FULL_VERIFY" == "true" ]] && echo "full" || echo "checksum-only" )" \
                "$rclone_status" \
                "$(hostname -f 2>/dev/null || hostname)")"
            send_notification_email "$subject" "$body" 2>/dev/null || \
                b_log_warn "Email notification failed (backup still succeeded)"
        fi

        b_log_success "Backup completed successfully"
        exit 0
    elif [[ "$DRY_RUN" == "true" ]]; then
        b_log_success "Dry run completed"
        exit 0
    else
        if [[ "$EMAIL_NOTIFY" == "true" ]]; then
            local subject="[VaultWarden] Backup FAILED: $actual_type ($timestamp)"
            local body
            body="$(printf 'Backup type:  %s\nTimestamp:    %s\nHost:         %s\n\nCheck logs for details.\n' \
                "$actual_type" "$timestamp" \
                "$(hostname -f 2>/dev/null || hostname)")"
            send_notification_email "$subject" "$body" 2>/dev/null || true
        fi
        log_error "Backup failed"
        exit 1
    fi
}

main "$@"
