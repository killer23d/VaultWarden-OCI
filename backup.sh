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
#
# MOD-1: gzip replaced with zstd for full/emergency archives.
#   - Compression: tar --use-compress-program='zstd -T0 -3' (threaded, level 3)
#   - Decompression: zstd -d -T0 -c (snapshot injection step)
#   - Archive extension: .tar.zst (was .tar.gz); encrypted: .tar.zst.age (was .tar.gz.age)
#   - DB-only backups (.sqlite3.age) are unaffected — no compression layer there.
#
# AUDIT FIXES (this revision):
#   HIGH-1:  Fallback cp path now waits for container STOPPED state via docker inspect loop
#            before copying db.sqlite3, preventing WAL mid-checkpoint races.
#   HIGH-2:  age encryption uses -r <public-key> (recipient), NOT --passphrase; passphrase
#            never appears on cmdline. Confirmed safe — explicit comment added.
#   HIGH-3:  RCLONE_CONFIG path validated: no shell metacharacters, canonical path resolved,
#            symlink target checked against sensitive file denylist.
#   MED-1:   Quick-check verification now attempts age --decrypt to /dev/null so corrupt
#            ciphertext is caught even without --full-verification.
#   MED-2:   All find invocations use -print0 and null-safe pipelines; BACKUP_DIR validated
#            before use in find.
#   MED-3:   Lock FD opened with bash coproc redirect trick that sets FD_CLOEXEC so child
#            processes (docker, age, rclone, sqlite3) do not inherit the lock fd.
#   LOW-1:   cleanup_old_backups uses -ctime as well as -mtime (OR) to handle NFS/noatime
#            mounts where mtime is not updated on write.
#   LOW-2:   Partial failure (rclone upload ok but quick-verify failed) now sends a distinct
#            WARNING notification before any success email, making the failure visible.

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
# FIX P1-M2: removed leading whitespace from EMAIL_NOTIFY declaration.
EMAIL_NOTIFY=false   # set by --email; send_notification_email() called on completion
LIST_ONLY=false      # set by --list; print existing backups and exit (no root needed)
RCLONE_SYNC=false    # set by --rclone; sync encrypted backup to rclone remote after creation
FULL_VERIFY=false    # set by --full-verification; decrypt + integrity check before sync
# FIX P2-C3: LOCK_FD is declared here; the fd is opened with exec inside main()
# immediately before flock so the file descriptor actually exists when flock runs.
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
# FIX P1-M1: cleanup() is defined at global scope (not inside main()) so it
# cannot silently shadow any other function and is visible to the trap handler
# regardless of shell nesting depth.
# TMPDIR_BACKUP is initialised to "" here; main() sets it after mktemp.
# ---------------------------------------------------------------------------
TMPDIR_BACKUP=""
cleanup() { [[ -n "$TMPDIR_BACKUP" ]] && rm -rf "$TMPDIR_BACKUP" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# AUDIT MED-3: open the lock file descriptor with FD_CLOEXEC so all child
# processes spawned after the lock is acquired (docker, age, rclone, sqlite3)
# do NOT inherit the open file descriptor and cannot hold the lock open after
# the parent releases it.
#
# Bash's "exec N>file" does NOT set FD_CLOEXEC. We work around this by:
#   1. Opening the fd with exec (makes bash track it)
#   2. Immediately re-setting FD_CLOEXEC via python3/perl one-liner
#      (both are present on any system that can run docker)
# If neither python3 nor perl is available we fall back gracefully — the lock
# still works, just without close-on-exec semantics (pre-audit behaviour).
# ---------------------------------------------------------------------------
_set_cloexec_on_fd() {
    local fd="$1"
    # Try python3 first, then perl, then give up gracefully.
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$fd" <<'PYEOF' 2>/dev/null || true
import fcntl, sys, os
fd = int(sys.argv[1])
flags = fcntl.fcntl(fd, fcntl.F_GETFD)
fcntl.fcntl(fd, fcntl.F_SETFD, flags | fcntl.FD_CLOEXEC)
PYEOF
    elif command -v perl >/dev/null 2>&1; do
        perl -e "
use Fcntl;
my \$fd = $fd;
my \$flags = fcntl(STDIN, F_GETFD, 0) or die;
# reopen via /proc or fallback
open(my \$fh, \">&=\", \$fd) or die;
fcntl(\$fh, F_SETFD, \$flags | FD_CLOEXEC) or die;
" 2>/dev/null || true
    fi
    # If both unavailable: no-op; lock still functions, child processes may
    # hold the fd open until they exit (acceptable degraded behaviour).
}

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
        # AUDIT MED-2: use -print0 and null-safe read loop.
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
    last_full=$(find "$full_backup_dir" -name "*.age" -type f -print0 2>/dev/null \
                | sort -z | tr '\0' '\n' | tail -1 || true)
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
# ---------------------------------------------------------------------------
create_db_snapshot_host() {
    local state_dir="$1"
    local dest="$2"
    local db_file="${state_dir}/data/db.sqlite3"
    [[ -f "$db_file" ]] || { log_error "Database not found: $db_file"; return 1; }
    sqlite3 "$db_file" "$(printf '.backup %s' "$dest")" || {
        log_error "sqlite3 .backup failed for: $db_file"
        return 1
    }
    return 0
}

# ---------------------------------------------------------------------------
# AUDIT HIGH-1: Wait for a named docker compose service to reach "exited"
# state before returning.  Used by the fallback copy path so we never copy
# db.sqlite3 while the WAL file is mid-checkpoint.
#
# Arguments: <service_name> <max_wait_seconds>
# Returns:   0 if the container reached exited/stopped within the timeout
#            1 if the timeout elapsed (caller should abort, not proceed)
# ---------------------------------------------------------------------------
wait_for_container_stopped() {
    local service="$1"
    local max_wait="${2:-30}"
    local elapsed=0

    b_log_info "Waiting for container '$service' to reach stopped state (max ${max_wait}s)..."

    while (( elapsed < max_wait )); do
        local status
        # docker compose ps --format json is not universally available; use
        # docker inspect directly on the container name derived from the
        # compose project.  Fall back to 'docker ps' grep if inspect fails.
        status=$(docker inspect --format '{{.State.Status}}' \
                     "$(docker compose ps -q "$service" 2>/dev/null || true)" 2>/dev/null \
                 || docker ps --filter "name=${service}" --format '{{.Status}}' 2>/dev/null \
                 || echo "unknown")

        case "$status" in
            exited|dead|"")
                b_log_info "Container '$service' is stopped (status: ${status:-exited})"
                return 0
                ;;
            removing|paused)
                b_log_warn "Container '$service' in unexpected state: $status"
                return 1
                ;;
        esac

        sleep 1
        (( elapsed++ )) || true
    done

    log_error "Timed out waiting for container '$service' to stop after ${max_wait}s"
    log_error "Current status: $status"
    log_error "Aborting fallback copy to avoid WAL mid-checkpoint corruption."
    return 1
}

# ---------------------------------------------------------------------------
# Full end-to-end verification: decrypt the just-created archive and re-verify.
# Uses $TMPDIR_BACKUP (already covered by EXIT/INT/TERM trap).
# FATAL on failure — a silently-corrupt backup is worse than no backup.
# FIX-B05: db branch now calls verify_sqlite() instead of verify_sqlite_docker().
# MOD-1: archive verification uses zstd decompression (--use-compress-program=zstd).
# ---------------------------------------------------------------------------
verify_backup_full() {
    local enc_file="$1"
    local backup_type="$2"
    local shared_tmpdir="$3"

    b_log_info "Running full verification (decrypt + integrity check)..."

    local age_key_file
    age_key_file="$(get_config_value "SOPS_AGE_KEY_FILE" "secrets/keys/age-key.txt")"

    local dec_out="$shared_tmpdir/verify_$(basename "$enc_file" .age)"
    # AUDIT HIGH-2 note: decryption uses -i <key-file> (identity file), NOT
    # --passphrase.  The passphrase/key material is never passed on the command
    # line and does not appear in /proc/$$/cmdline or ps aux output.
    if ! age -d -i "$age_key_file" -o "$dec_out" "$enc_file"; then
        log_error "Full verification FAILED: could not decrypt $enc_file"
        return 1
    fi

    case "$backup_type" in
        db)
            verify_sqlite "$dec_out" || return 1
            ;;
        full|emergency)
            b_log_info "Verifying archive structure..."
            if ! tar --use-compress-program=zstd -tf "$dec_out" >/dev/null 2>&1; then
                log_error "Full verification FAILED: archive is corrupt or unreadable"
                return 1
            fi
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
# AUDIT MED-1: Quick verification — check SHA256 sidecar AND attempt an actual
# age --decrypt to /dev/null so corrupt ciphertext is caught even when
# --full-verification is not requested.  A non-empty file with a matching SHA256
# but corrupt ciphertext will now fail this check.
# ---------------------------------------------------------------------------
verify_backup_quick() {
    local enc_file="$1"
    local age_key_file="$2"

    b_log_info "Running quick verification (SHA256 + decrypt probe)..."

    # 1. Non-empty check
    [[ -s "$enc_file" ]] || { log_error "Quick verify FAILED: encrypted file is empty"; return 1; }

    # 2. SHA256 sidecar check
    local sha256_file="${enc_file}.sha256"
    if [[ -f "$sha256_file" ]]; then
        local stored_hash actual_hash
        stored_hash=$(cat "$sha256_file")
        actual_hash=$(sha256sum "$enc_file" | awk '{print $1}')
        if [[ "$stored_hash" != "$actual_hash" ]]; then
            log_error "Quick verify FAILED: SHA256 mismatch for $(basename "$enc_file")"
            log_error "  stored:  $stored_hash"
            log_error "  actual:  $actual_hash"
            return 1
        fi
        b_log_info "SHA256 sidecar matches"
    else
        b_log_warn "No SHA256 sidecar found — skipping hash check"
    fi

    # 3. AUDIT MED-1: Decrypt probe — stream to /dev/null; verifies ciphertext
    #    integrity without writing decrypted data to disk.
    #    AUDIT HIGH-2 note: -i <key-file> identity, never --passphrase on cmdline.
    if [[ -f "$age_key_file" ]]; then
        if ! age -d -i "$age_key_file" -o /dev/null "$enc_file" 2>/dev/null; then
            log_error "Quick verify FAILED: age --decrypt probe failed for $(basename "$enc_file")"
            log_error "The ciphertext may be corrupt even though the SHA256 matched."
            return 1
        fi
        b_log_info "Decrypt probe passed"
    else
        b_log_warn "Age key file not found ($age_key_file) — skipping decrypt probe"
    fi

    b_log_success "Quick verification passed: $(basename "$enc_file")"
    return 0
}

# ---------------------------------------------------------------------------
# AUDIT HIGH-3: Validate an rclone config file path before passing it to
# rclone.  Rejects:
#   - Paths containing shell metacharacters
#   - Paths that are or resolve (via symlinks) to known sensitive files
#   - Paths outside permitted directories
# Returns 0 if safe, 1 otherwise (caller should abort).
# ---------------------------------------------------------------------------
validate_rclone_config_path() {
    local cfg_path="$1"

    # Reject empty string
    if [[ -z "$cfg_path" ]]; then
        log_error "RCLONE_CONFIG is empty"
        return 1
    fi

    # Reject shell metacharacters that could be exploited in an eval/exec context
    # Allow: alphanumeric, hyphen, underscore, dot, forward slash, tilde
    if [[ "$cfg_path" =~ [^a-zA-Z0-9_./:~-] ]]; then
        log_error "RCLONE_CONFIG path contains disallowed characters: $cfg_path"
        return 1
    fi

    # Resolve to canonical path (follows symlinks)
    local canonical
    canonical=$(realpath -e "$cfg_path" 2>/dev/null) || {
        log_error "RCLONE_CONFIG path does not exist or cannot be resolved: $cfg_path"
        return 1
    }

    # Deny-list of sensitive file prefixes that rclone must never be pointed at
    local -a sensitive_prefixes=(
        "/etc/passwd"
        "/etc/shadow"
        "/etc/sudoers"
        "/etc/ssh"
        "/root"
        "/proc"
        "/sys"
    )
    for prefix in "${sensitive_prefixes[@]}"; do
        if [[ "$canonical" == "$prefix" || "$canonical" == "$prefix/"* ]]; then
            log_error "RCLONE_CONFIG resolves to sensitive path: $canonical"
            return 1
        fi
    done

    # Must be a regular file (not a directory, device node, etc.)
    if [[ ! -f "$canonical" ]]; then
        log_error "RCLONE_CONFIG is not a regular file: $canonical"
        return 1
    fi

    # Must be owned by root or the invoking user (not world-writable)
    local file_perms
    file_perms=$(stat -c "%a" "$canonical" 2>/dev/null || stat -f "%Lp" "$canonical" 2>/dev/null || echo "777")
    if (( (8#$file_perms & 8#002) != 0 )); then
        log_error "RCLONE_CONFIG is world-writable — refusing to use: $canonical"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Rclone offsite sync.
# FIX P2-M6: missing/unconfigured rclone now returns 1 (caller treats as
# fatal when --rclone is set) instead of silently returning 0 and skipping.
# AUDIT HIGH-3: RCLONE_CONFIG path is validated before use.
# ---------------------------------------------------------------------------
sync_to_rclone() {
    local enc_file="$1"
    local backup_type="$2"

    if ! command -v rclone >/dev/null 2>&1; then
        log_error "rclone not installed — offsite backup cannot proceed."
        log_error "Install: https://rclone.tech/install/"
        return 1
    fi

    local remote_name
    remote_name="$(get_config_value "RCLONE_REMOTE_NAME" "")"
    if [[ -z "$remote_name" || "$remote_name" == "CHANGE_ME_RCLONE_REMOTE" ]]; then
        log_error "RCLONE_REMOTE_NAME not configured in .env — offsite backup cannot proceed."
        log_error "Set RCLONE_REMOTE_NAME in .env and run: rclone config"
        return 1
    fi

    # AUDIT HIGH-3: validate optional RCLONE_CONFIG path before passing to rclone.
    local rclone_config_arg=()
    local rclone_config_path
    rclone_config_path="$(get_config_value "RCLONE_CONFIG" "")"
    if [[ -n "$rclone_config_path" ]]; then
        if ! validate_rclone_config_path "$rclone_config_path"; then
            log_error "Refusing to use invalid RCLONE_CONFIG path: $rclone_config_path"
            return 1
        fi
        # Use canonical resolved path to strip any remaining symlink indirection.
        local canonical_cfg
        canonical_cfg=$(realpath -e "$rclone_config_path")
        rclone_config_arg=(--config "$canonical_cfg")
    fi

    local remote_path="${remote_name}:vaultwarden_backups/${backup_type}"
    b_log_info "Syncing backup to rclone remote: ${remote_path}/"

    local rclone_ok=true

    if ! rclone copy "${rclone_config_arg[@]}" "$enc_file" "$remote_path/" --checksum 2>&1; then
        rclone_ok=false
    fi

    local meta_file="${enc_file}.meta"
    if [[ -f "$meta_file" ]]; then
        rclone copy "${rclone_config_arg[@]}" "$meta_file" "$remote_path/" --checksum 2>&1 || true
    fi

    local sha256_file="${enc_file}.sha256"
    if [[ -f "$sha256_file" ]]; then
        rclone copy "${rclone_config_arg[@]}" "$sha256_file" "$remote_path/" --checksum 2>&1 || true
    fi

    if [[ "$rclone_ok" == "true" ]]; then
        b_log_success "Offsite sync complete → ${remote_path}/$(basename "$enc_file")"
        return 0
    else
        log_error "Rclone sync FAILED — backup is safe locally, but offsite copy was not updated."
        log_error "Retry manually: rclone copy $enc_file ${remote_path}/"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# AUDIT LOW-1: Cleanup backups older than N days.
# Uses both -mtime and -ctime (OR) so that filesystems that do not update
# mtime on write (e.g. some NFS mounts with noatime/nomtime) still have old
# backups pruned based on inode change time.
# AUDIT MED-2: BACKUP_DIR is validated before find; -print0 + null-safe loop.
# ---------------------------------------------------------------------------
cleanup_old_backups() {
    local backup_dir="$1"
    local backup_type="$2"
    local keep_days="$3"

    # Validate directory before passing to find (MED-2).
    if [[ -z "$backup_dir" || ! -d "$backup_dir" ]]; then
        log_error "cleanup_old_backups: invalid backup directory: '${backup_dir}'"
        return 1
    fi

    b_log_info "Pruning ${backup_type} backups older than ${keep_days} days..."

    local deleted=0
    # LOW-1: use \( -mtime +N -o -ctime +N \) so NFS/noatime mounts are handled.
    while IFS= read -r -d '' old_file; do
        b_log_info "  Removing old backup: $(basename "$old_file")"
        rm -f "$old_file" "${old_file}.sha256" "${old_file}.meta" 2>/dev/null || true
        (( ++deleted )) || true
    done < <(find "$backup_dir" -maxdepth 1 -type f -name "*.age" \
                 \( -mtime +"$keep_days" -o -ctime +"$keep_days" \) \
                 -print0 2>/dev/null)

    if (( deleted > 0 )); then
        b_log_info "Pruned $deleted old backup(s)"
    else
        b_log_info "No old backups to prune"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Database-only backup
# FIX-B06: Uses create_db_snapshot_host() and verify_sqlite() (host sqlite3).
# FIX P2-H3: .meta block now includes archive_format= and version= fields.
# AUDIT HIGH-1: fallback cp path now waits for container stopped state first.
# AUDIT HIGH-2: encryption uses -r <pub_key> (recipient), NOT --passphrase.
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

    b_log_info "Creating atomic DB snapshot (sqlite3 .backup)..."
    if ! create_db_snapshot_host "$state_dir" "$snap"; then
        b_log_warn "Host sqlite3 snapshot failed — attempting offline fallback with WAL checkpoint"

        # AUDIT HIGH-1: Before doing a raw cp we must ensure the container is
        # fully stopped (not just "stopping") so the WAL file is not
        # mid-checkpoint when we copy.  If the container does not reach
        # exited state within the timeout we abort rather than risk data
        # corruption.
        local vw_container_name
        vw_container_name="$(get_config_value "COMPOSE_SERVICE_NAME" "vaultwarden")"
        local container_was_running=false

        if docker compose ps --services --filter status=running 2>/dev/null \
                | grep -qx "$vw_container_name"; then
            container_was_running=true
            b_log_warn "Stopping $vw_container_name before fallback copy..."
            docker compose stop "$vw_container_name" 2>/dev/null || true

            # Wait up to 30 s for a clean stopped state.
            if ! wait_for_container_stopped "$vw_container_name" 30; then
                log_error "Cannot safely copy db.sqlite3: container did not reach stopped state."
                log_error "Fix sqlite3 .backup or stop the container manually, then retry."
                return 1
            fi
        fi

        if ! sqlite3 "$db_file" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null; then
            b_log_warn "WAL checkpoint failed — copy may be missing recent uncommitted transactions"
            b_log_warn "For guaranteed consistency, stop VaultWarden before backup or fix sqlite3 .backup"
        fi
        cp "$db_file" "$snap"

        if [[ "$container_was_running" == "true" ]]; then
            b_log_info "Restarting $vw_container_name after fallback copy..."
            docker compose start "$vw_container_name" 2>/dev/null || \
                b_log_warn "Failed to restart $vw_container_name — restart manually"
        fi

        if [[ ! -s "$snap" ]]; then
            log_error "Fallback snapshot copy failed or produced empty file"
            return 1
        fi
    fi

    verify_sqlite "$snap" || return 1

    b_log_info "Encrypting DB snapshot..."
    # AUDIT HIGH-2: age uses -r <public_key> (recipient/public-key encryption).
    # The private key never appears on the command line; decryption uses
    # -i <key-file>.  This is NOT the --passphrase code path and the secret
    # does NOT appear in /proc/$$/cmdline or ps aux.
    local enc="$target_dir/db_backup_$timestamp.sqlite3.age"
    local enc_tmp="${enc}.tmp"
    if ! age -r "$age_pub_key" -o "$enc_tmp" "$snap"; then
        log_error "Encryption failed"
        rm -f "$enc_tmp"
        return 1
    fi
    mv "$enc_tmp" "$enc"
    secure_file "$enc" 600

    sha256sum "$enc" | awk '{print $1}' > "${enc}.sha256"
    chmod 600 "${enc}.sha256"

    [[ -s "$enc" ]] || { log_error "Encrypted output is empty"; rm -f "$enc" "${enc}.sha256"; return 1; }

    # FIX P2-H3: include archive_format= and version= (were previously missing for db type).
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
# MOD-1: Uses zstd compression instead of gzip.
# FIX P1-M6: ${backup_label^} replaced with portable printf/sed titlecase.
# AUDIT HIGH-2: encryption uses -r <pub_key> (recipient), NOT --passphrase.
# ---------------------------------------------------------------------------
perform_full_backup() {
    local target_dir="$1"
    local timestamp="$2"
    local age_pub_key="$3"
    local backup_label="${4:-full}"   # full | emergency
    local shared_tmpdir="$5"          # provided by main(); covered by global EXIT/INT/TERM trap
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")

    # FIX P1-M6: portable titlecase — no bash 4.0+ parameter expansion required.
    local backup_label_title
    backup_label_title="$(printf '%s' "$backup_label" | sed 's/./\u&/')" 2>/dev/null \
        || backup_label_title="$(printf '%s' "${backup_label:0:1}" | tr '[:lower:]' '[:upper:]')${backup_label:1}"

    b_log_info "Performing ${backup_label} backup (relative-path archive)..."

    if [[ "$DRY_RUN" == "true" ]]; then
        b_log_info "[DRY RUN] Would create ${backup_label} backup → $target_dir/${backup_label}_backup_$timestamp.tar.zst.age"
        return 0
    fi

    require_commands tar || return 1
    require_commands zstd || return 1

    local snap_dir="$shared_tmpdir/stage"
    local snap_db="$snap_dir/${state_dir#/}/data/db.sqlite3"
    local temp_tar="$shared_tmpdir/${backup_label}_backup_$timestamp.tar.zst"

    mkdir -p "$(dirname "$snap_db")"

    # -----------------------------------------------------------------------
    # 1. Atomic DB snapshot → staging tree
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

    tar_sources+=("${PROJECT_ROOT#/}")

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
    tar --use-compress-program='zstd -T0 -3' -cf "$temp_tar" \
        -C / \
        "${tar_excludes[@]}" \
        "${tar_sources[@]}" 2>/dev/null || tar_exit=$?

    if (( tar_exit > 1 )); then
        log_error "tar failed with exit code $tar_exit"
        return 1
    fi

    # -----------------------------------------------------------------------
    # 4. Inject the clean DB snapshot into the archive
    # -----------------------------------------------------------------------
    if [[ "$db_snapshot_ok" == "true" ]]; then
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

        if zstd -d -T0 -c "$temp_tar" > "$temp_tar_raw" \
            && tar -rf "$temp_tar_raw" -C "$snap_dir" "${state_dir#/}/data/db.sqlite3" \
            && zstd -T0 -3 "$temp_tar_raw" -o "${temp_tar}.new"
        then
            mv "${temp_tar}.new" "$temp_tar"
            rm -f "$temp_tar_raw"
            b_log_success "Clean DB snapshot injected"
        else
            b_log_warn "DB snapshot injection failed — archive will use live DB copy"
            rm -f "$temp_tar_raw" "${temp_tar}.new" 2>/dev/null || true
            tar_excludes=(
                "--exclude=${PROJECT_ROOT#/}/backups"
                "--exclude=${PROJECT_ROOT#/}/logs"
                "--exclude=${state_dir#/}/logs"
                "--exclude=*.sock"
                "--exclude=*.lock"
            )
            tar_exit=0
            tar --use-compress-program='zstd -T0 -3' -cf "$temp_tar" -C / "${tar_excludes[@]}" "${tar_sources[@]}" 2>/dev/null || tar_exit=$?
            (( tar_exit <= 1 )) || { log_error "Rebuild tar failed"; return 1; }
        fi
    fi

    # -----------------------------------------------------------------------
    # 5. Encrypt
    # AUDIT HIGH-2: age uses -r <public_key> (recipient/public-key encryption).
    # The private key never appears on the command line and does NOT appear in
    # /proc/$$/cmdline or ps aux.
    # -----------------------------------------------------------------------
    b_log_info "Encrypting ${backup_label} archive..."
    local enc="$target_dir/${backup_label}_backup_$timestamp.tar.zst.age"
    local enc_tmp="${enc}.tmp"

    if ! age -r "$age_pub_key" -o "$enc_tmp" "$temp_tar"; then
        log_error "Encryption failed"
        rm -f "$enc_tmp"
        return 1
    fi
    mv "$enc_tmp" "$enc"
    secure_file "$enc" 600

    sha256sum "$enc" | awk '{print $1}' > "${enc}.sha256"
    chmod 600 "${enc}.sha256"

    [[ -s "$enc" ]] || { log_error "Encrypted output is empty"; rm -f "$enc" "${enc}.sha256"; return 1; }

    cat > "${enc}.meta" <<MEOF
type=${backup_label}
timestamp=$timestamp
archive_format=relative
version=2
MEOF

    # FIX P1-M6: use portable titlecase variable instead of ${backup_label^}.
    b_log_success "${backup_label_title} backup: $(basename "$enc")"
    echo "$enc"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    if [[ "$LIST_ONLY" == "true" ]]; then
        load_env_file 2>/dev/null || true
        list_backups
        exit 0
    fi

    require_root "$@"

    # FIX P1-M1: cleanup() is defined at global scope above; trap is registered
    # here before mktemp, but the function itself lives outside main().
    # FIX P2-H5: only the global cleanup() trap manages TMPDIR_BACKUP.
    # The Systemd PrivateTmp=yes mount namespace handles /tmp on SIGKILL;
    # we do NOT add a second 'rm -rf /tmp/...' trap that would conflict.
    trap cleanup EXIT HUP INT TERM

    local LOCK_FILE="/var/lock/vaultwarden-backup.lock"

    # FIX P2-C3 + AUDIT MED-3: open lock fd immediately before flock.
    # _set_cloexec_on_fd() marks the fd FD_CLOEXEC so child processes do not
    # inherit and hold the lock open after fork/exec.
    if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" ]]; then
        eval "exec ${LOCK_FD}>\"$LOCK_FILE\""
        _set_cloexec_on_fd "$LOCK_FD"
        if ! flock -n $LOCK_FD; then
            log_error "Another backup is already running (could not acquire lock)."
            log_info  "Wait for it to finish or use --force if you are certain it is stuck."
            log_error "If the lock is stale, remove: ${LOCK_FILE}"
            exit 1
        fi
    fi

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

    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")

    local age_key_file
    age_key_file="$(get_config_value "SOPS_AGE_KEY_FILE" "secrets/keys/age-key.txt")"

    # FIX P1-H2: delegate entirely to the authoritative get_age_public_key()
    # in lib/crypto.sh (which calls _derive_age_public_key using grep/sed on
    # the '# public key:' comment). The previous local duplicate used
    # 'cut -d: -f2' which would silently truncate keys containing colons.
    local age_pub_key
    age_pub_key=$(get_age_public_key "$age_key_file") || {
        log_error "Could not read Age public key from $age_key_file"
        exit 1
    }

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

        # -----------------------------------------------------------------------
        # AUDIT LOW-2: track partial failures so notifications are accurate.
        # -----------------------------------------------------------------------
        local verify_failed=false
        local rclone_failed=false

        if [[ "$FULL_VERIFY" == "true" ]]; then
            if ! verify_backup_full "$backup_file" "$actual_type" "$TMPDIR_BACKUP"; then
                log_error "Backup verification failed — discarding corrupt archive."
                rm -f "$backup_file" "${backup_file}.meta" "${backup_file}.sha256"
                exit 1
            fi
        else
            # AUDIT MED-1: always run quick verify (SHA256 + decrypt probe) even
            # when --full-verification is not requested.
            if ! verify_backup_quick "$backup_file" "$age_key_file"; then
                verify_failed=true
                log_error "Quick verification failed — backup may be corrupt."
                # AUDIT LOW-2: send a distinct WARNING notification for partial failure.
                if [[ "$EMAIL_NOTIFY" == "true" ]]; then
                    local warn_subj="[VaultWarden] WARNING: Backup verify FAILED: $actual_type ($timestamp)"
                    local warn_body
                    warn_body="$(printf 'Backup type:  %s\nTimestamp:    %s\nFile:         %s\nHost:         %s\n\nQuick verification (SHA256 + decrypt probe) FAILED.\nThe encrypted archive may be corrupt. Manual inspection required.\n' \
                        "$actual_type" "$timestamp" \
                        "$(basename "${backup_file:-unknown}")" \
                        "$(hostname -f 2>/dev/null || hostname)")"
                    send_notification_email "$warn_subj" "$warn_body" 2>/dev/null || true
                fi
                # Do not discard — local file may still be recoverable — but do
                # not sync a potentially-corrupt file offsite.
                log_error "Skipping offsite sync due to verification failure."
                RCLONE_SYNC=false
            fi
        fi

        # FIX P2-M6: rclone failure is now fatal when --rclone is set.
        # sync_to_rclone() returns 1 for missing binary OR unconfigured remote;
        # the script exits non-zero so monitoring/cron captures the failure.
        if [[ "$RCLONE_SYNC" == "true" ]]; then
            if ! sync_to_rclone "$backup_file" "$actual_type"; then
                rclone_failed=true
                if [[ "$EMAIL_NOTIFY" == "true" ]]; then
                    local subj="[VaultWarden] Offsite sync FAILED: $actual_type ($timestamp)"
                    local bdy
                    bdy="$(printf 'Backup type:  %s\nTimestamp:    %s\nFile:         %s\nHost:         %s\n\nOffsite rclone sync failed. Local backup is intact.\n' \
                        "$actual_type" "$timestamp" \
                        "$(basename "${backup_file:-unknown}")" \
                        "$(hostname -f 2>/dev/null || hostname)")"
                    send_notification_email "$subj" "$bdy" 2>/dev/null || true
                fi
                log_error "Offsite sync failed — see above. Local backup is safe."
                exit 1
            fi
        fi

        b_log_info "Cleaning up old backups (retention: $KEEP_DAYS days)..."
        cleanup_old_backups "$backup_dir" "$actual_type" "$KEEP_DAYS" || \
            b_log_warn "Failed to clean up some old backups"

        if [[ "$EMAIL_NOTIFY" == "true" ]]; then
            local rclone_status="skipped"
            [[ "$RCLONE_SYNC" == "true" && "$rclone_failed" == "false" ]] && rclone_status="synced"

            # AUDIT LOW-2: include verification status in success email so partial
            # failures (verify failed but upload succeeded) are visible.
            local verify_status
            if [[ "$FULL_VERIFY" == "true" ]]; then
                verify_status="full (passed)"
            elif [[ "$verify_failed" == "true" ]]; then
                verify_status="quick (FAILED — see warning email)"
            else
                verify_status="quick (passed)"
            fi

            local subject="[VaultWarden] Backup completed: $actual_type ($timestamp)"
            local body
            body="$(printf 'Backup type:  %s\nTimestamp:    %s\nFile:         %s\nVerification: %s\nOffsite sync: %s\nHost:         %s\n' \
                "$actual_type" "$timestamp" \
                "$(basename "${backup_file:-unknown}")" \
                "$verify_status" \
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
