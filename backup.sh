#!/usr/bin/env bash
# backup.sh - VaultWarden-OCI backup (atomic DB snapshot, relative-path archive, age encryption)
# archive_format=relative: archives use paths relative to / so restores can stage safely.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
init_common_lib "$0"
source "$SCRIPT_DIR/lib/docker.sh"
source "$SCRIPT_DIR/lib/backup_utils.sh"
source "$SCRIPT_DIR/lib/crypto.sh"

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

LOCK_FD=9

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

if ! [[  "$KEEP_DAYS" =~ ^[0-9]+$ ]] || ! (( KEEP_DAYS >= 1 )); then
    log_error "Invalid --keep value: '${KEEP_DAYS}' — must be a positive integer (e.g. 14)"
    exit 1
fi

b_log_info()    { [[ "$QUIET" == "true" ]] || log_info "$*" >&2;    }
b_log_success() { [[ "$QUIET" == "true" ]] || log_success "$*" >&2; }
b_log_warn()    { [[ "$QUIET" == "true" ]] || log_warn "$*" >&2;    }

TMPDIR_BACKUP=""
cleanup() { [[ -n "$TMPDIR_BACKUP" ]] && rm -rf "$TMPDIR_BACKUP" 2>/dev/null || true; }

_set_cloexec_on_fd() {
    local fd="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$fd" <<'PYEOF' 2>/dev/null || true
import fcntl, sys, os
fd = int(sys.argv[1])
flags = fcntl.fcntl(fd, fcntl.F_GETFD)
fcntl.fcntl(fd, fcntl.F_SETFD, flags | fcntl.FD_CLOEXEC)
PYEOF
    elif command -v perl >/dev/null 2>&1; then
        perl -e "
use Fcntl;
my \$fd = $fd;
my \$flags = fcntl(STDIN, F_GETFD, 0) or die;
# reopen via /proc or fallback
open(my \$fh, \">&=\", \$fd) or die;
fcntl(\$fh, F_SETFD, \$flags | FD_CLOEXEC) or die;
" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# _resolve_age_key
#
# BUG-AK4 FIX: backup.sh previously called
#   get_config_value "SOPS_AGE_KEY_FILE" "$SCRIPT_DIR/secrets/keys/age-key.txt"
# in three separate places (main, verify_backup_full, verify_backup_quick).
# Under systemd with ProtectHome=yes the installed key lives at
# /etc/vaultwarden/age-key.txt and is set via SOPS_AGE_KEY_FILE in the
# EnvironmentFile.  However load_env_file() can overwrite SOPS_AGE_KEY_FILE
# with a stale relative value from the env file (written before the BUG-AK1
# fix), causing get_config_value() to fall back to the non-existent
# $SCRIPT_DIR/secrets/keys/age-key.txt path.
#
# Additionally verify_backup_full() re-called get_config_value() independently
# instead of reusing the already-resolved path from main().
#
# Fix: single _resolve_age_key() function (mirrors health.sh BUG-AK2/AK3 fix).
# Resolution order:
#   1. SOPS_AGE_KEY_FILE env var — only if absolute path, or relative and exists
#   2. /etc/vaultwarden/age-key.txt  (canonical systemd install path, BUG-AK1)
#   3. $SCRIPT_DIR/secrets/keys/age-key.txt  (local/dev fallback)
#
# Prints the resolved path to stdout; returns 0 if file exists, 1 if not.
# ---------------------------------------------------------------------------
_resolve_age_key() {
    local candidates=(
        "${SOPS_AGE_KEY_FILE:-}"
        "/etc/vaultwarden/age-key.txt"
        "$SCRIPT_DIR/secrets/keys/age-key.txt"
    )
    for candidate in "${candidates[@]}"; do
        [[ -z "$candidate" ]] && continue
        # Skip relative paths that don't exist — they come from a stale env
        # file and must not shadow the absolute fallbacks below them.
        [[ "$candidate" != /* && ! -f "$candidate" ]] && continue
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    # None found — return first non-empty absolute candidate for a useful error.
    for candidate in "${candidates[@]}"; do
        [[ -z "$candidate" ]] && continue
        if [[ "$candidate" == /* ]]; then
            echo "$candidate"
            return 1
        fi
    done
    echo "/etc/vaultwarden/age-key.txt"
    return 1
}

# ---------------------------------------------------------------------------
# _resolve_rclone_config
#
# When backup.sh is invoked as root (via sudo or a systemd service unit),
# rclone defaults to /root/.config/rclone/rclone.conf, which does not exist
# when the remote was configured by a non-root user (e.g. ubuntu).
#
# Resolution order (first existing readable file wins):
#   1. RCLONE_CONFIG env var / .env value  — explicit always takes priority
#   2. /etc/rclone/rclone.conf             — system-wide location (best practice)
#   3. /root/.config/rclone/rclone.conf   — root's own config (if present)
#   4. $SUDO_USER home                     — the invoking user when run via sudo
#   5. /home/*/.config/rclone/rclone.conf — single-user host heuristic
#
# Prints the resolved absolute path to stdout.
# Returns 0 on success, 1 when no config file is found.
# ---------------------------------------------------------------------------
_resolve_rclone_config() {
    local cfg_from_env
    cfg_from_env="$(get_config_value "RCLONE_CONFIG" "")"

    # Priority 1: explicit value from .env / environment
    if [[ -n "$cfg_from_env" ]]; then
        echo "$cfg_from_env"
        return 0
    fi

    # Priority 2: system-wide config (canonical location for root-run services)
    if [[ -f "/etc/rclone/rclone.conf" ]]; then
        echo "/etc/rclone/rclone.conf"
        return 0
    fi

    # Priority 3: root's own config
    if [[ -f "/root/.config/rclone/rclone.conf" ]]; then
        echo "/root/.config/rclone/rclone.conf"
        return 0
    fi

    # Priority 4: the user who called sudo (most common single-user case)
    if [[ -n "${SUDO_USER:-}" ]]; then
        local sudo_user_home
        sudo_user_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
        if [[ -n "$sudo_user_home" && -f "$sudo_user_home/.config/rclone/rclone.conf" ]]; then
            echo "$sudo_user_home/.config/rclone/rclone.conf"
            return 0
        fi
    fi

    # Priority 5: single non-root user heuristic (globbing — only safe on
    # single-user hosts; multi-user hosts should set RCLONE_CONFIG in .env)
    local found_cfg
    for found_cfg in /home/*/.config/rclone/rclone.conf; do
        [[ -f "$found_cfg" ]] && echo "$found_cfg" && return 0
    done

    return 1
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

get_backup_dir() {
    local type="$1"
    local base_dir
    base_dir="$(get_config_value "BACKUP_DIR" "/var/lib/vaultwarden/backups")"
    local dir="$base_dir/$type"
    ensure_dir "$dir" 750 "$(get_real_user)"
    echo "$dir"
}

list_backups() {
    local base_dir
    base_dir="$(get_config_value "BACKUP_DIR" "/var/lib/vaultwarden/backups")"
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

verify_sqlite() {
    local dbfile="$1"
    b_log_info "Verifying SQLite integrity (host sqlite3)..."
    local result
    result=$(sqlite3 "$dbfile" "PRAGMA integrity_check;" 2>&1) || {
        log_error "SQLite integrity check error: ${result}" >&2
        return 1
    }
    if [[ "$result" != "ok" ]]; then
        log_error "SQLite integrity check FAILED: ${result}" >&2
        return 1
    fi
    b_log_info "SQLite integrity check passed"
    return 0
}

create_db_snapshot_host() {
    local state_dir="$1"
    local dest="$2"
    local db_file="${state_dir}/data/db.sqlite3"
    [[ -f "$db_file" ]] || { log_error "Database not found: $db_file" >&2; return 1; }
    sqlite3 "$db_file" "$(printf '.backup %s' "$dest")" || {
        log_error "sqlite3 .backup failed for: $db_file" >&2
        return 1
    }
    return 0
}

wait_for_container_stopped() {
    local service="$1"
    local max_wait="${2:-30}"
    local elapsed=0

    b_log_info "Waiting for container '$service' to reach stopped state (max ${max_wait}s)..."

    while (( elapsed < max_wait )); do
        local status
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

    log_error "Timed out waiting for container '$service' to stop after ${max_wait}s" >&2
    log_error "Current status: $status" >&2
    log_error "Aborting fallback copy to avoid WAL mid-checkpoint corruption." >&2
    return 1
}

verify_backup_full() {
    local enc_file="$1"
    local backup_type="$2"
    local shared_tmpdir="$3"

    b_log_info "Running full verification (decrypt + integrity check)..."

    # BUG-AK4 FIX: use _resolve_age_key() instead of re-calling
    # get_config_value() independently, which could resolve a stale relative
    # SOPS_AGE_KEY_FILE from the env file and produce a non-existent path.
    local age_key_file
    age_key_file=$(_resolve_age_key) || {
        log_error "Age key file not found: $age_key_file" >&2
        return 1
    }

    local dec_out="$shared_tmpdir/verify_$(basename "$enc_file" .age)"

    if ! age -d -i "$age_key_file" -o "$dec_out" "$enc_file"; then
        log_error "Full verification FAILED: could not decrypt $enc_file" >&2
        return 1
    fi

    case "$backup_type" in
        db)
            verify_sqlite "$dec_out" || return 1
            ;;
        full|emergency)
            b_log_info "Verifying archive structure..."
            if ! tar --use-compress-program='zstd -d -T0' -tf "$dec_out" >/dev/null 2>&1; then
                log_error "Full verification FAILED: archive is corrupt or unreadable" >&2
                return 1
            fi
            local size
            size=$(stat -c%s "$dec_out" 2>/dev/null || stat -f%z "$dec_out" 2>/dev/null || echo 0)
            if (( size < 10240 )); then
                log_error "Full verification FAILED: archive suspiciously small (${size} bytes)" >&2
                return 1
            fi
            ;;
    esac

    b_log_info "Full verification passed: $(basename "$enc_file")"
    rm -f "$dec_out"
    return 0
}

verify_backup_quick() {
    local enc_file="$1"
    local age_key_file="$2"

    b_log_info "Running quick verification (SHA256 + decrypt probe)..."

    [[ -s "$enc_file" ]] || { log_error "Quick verify FAILED: encrypted file is empty" >&2; return 1; }

    local sha256_file="${enc_file}.sha256"
    if [[ -f "$sha256_file" ]]; then
        local stored_hash actual_hash
        stored_hash=$(cat "$sha256_file")
        actual_hash=$(sha256sum "$enc_file" | awk '{print $1}')
        if [[ "$stored_hash" != "$actual_hash" ]]; then
            log_error "Quick verify FAILED: SHA256 mismatch for $(basename "$enc_file")" >&2
            log_error "  stored:  $stored_hash" >&2
            log_error "  actual:  $actual_hash" >&2
            return 1
        fi
        b_log_info "SHA256 sidecar matches"
    else
        b_log_warn "No SHA256 sidecar found — skipping hash check"
    fi

    if [[ ! -f "$age_key_file" ]]; then
        log_error "Quick verify FAILED: Age key file not found ($age_key_file)" >&2
        log_error "Cannot perform decrypt probe — refusing to report verification success." >&2
        return 1
    fi

    if ! age -d -i "$age_key_file" -o /dev/null "$enc_file" 2>/dev/null; then
        log_error "Quick verify FAILED: age --decrypt probe failed for $(basename "$enc_file")" >&2
        log_error "The ciphertext may be corrupt even though the SHA256 matched." >&2
        return 1
    fi
    b_log_info "Decrypt probe passed"

    b_log_info "Quick verification passed: $(basename "$enc_file")"
    return 0
}

validate_rclone_config_path() {
    local cfg_path="$1"

    # Reject empty string
    if [[ -z "$cfg_path" ]]; then
        log_error "RCLONE_CONFIG is empty" >&2
        return 1
    fi

    if [[ "$cfg_path" =~ [^a-zA-Z0-9_./:~-] ]]; then
        log_error "RCLONE_CONFIG path contains disallowed characters: $cfg_path" >&2
        return 1
    fi

    local canonical
    canonical=$(realpath -e "$cfg_path" 2>/dev/null) || {
        log_error "RCLONE_CONFIG path does not exist or cannot be resolved: $cfg_path" >&2
        return 1
    }

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
            log_error "RCLONE_CONFIG resolves to sensitive path: $canonical" >&2
            return 1
        fi
    done

    if [[ ! -f "$canonical" ]]; then
        log_error "RCLONE_CONFIG is not a regular file: $canonical" >&2
        return 1
    fi
    local file_perms
    file_perms=$(stat -c "%a" "$canonical" 2>/dev/null || stat -f "%Lp" "$canonical" 2>/dev/null || echo "777")
    if (( (8#$file_perms & 8#002) != 0 )); then
        log_error "RCLONE_CONFIG is world-writable — refusing to use: $canonical" >&2
        return 1
    fi

    return 0
}

sync_to_rclone() {
    local enc_file="$1"
    local backup_type="$2"

    if ! command -v rclone >/dev/null 2>&1; then
        log_error "rclone not installed — offsite backup cannot proceed." >&2
        log_error "Install: https://rclone.tech/install/" >&2
        return 1
    fi

    local remote_name
    remote_name="$(get_config_value "RCLONE_REMOTE_NAME" "")"
    if [[ -z "$remote_name" || "$remote_name" == "CHANGE_ME_RCLONE_REMOTE" ]]; then
        log_error "RCLONE_REMOTE_NAME not configured in .env — offsite backup cannot proceed." >&2
        log_error "Set RCLONE_REMOTE_NAME in .env and run: rclone config" >&2
        return 1
    fi

    # ------------------------------------------------------------------
    # Resolve rclone config path.
    # When RCLONE_CONFIG is set in .env it is used directly (and validated).
    # When it is not set, _resolve_rclone_config() searches well-known
    # locations so that root/systemd invocations find the config that was
    # set up by a non-root user without requiring manual .env edits.
    # ------------------------------------------------------------------
    local rclone_config_arg=()
    local rclone_config_path
    rclone_config_path="$(get_config_value "RCLONE_CONFIG" "")"

    if [[ -n "$rclone_config_path" ]]; then
        # Explicit path from .env — validate it strictly.
        if ! validate_rclone_config_path "$rclone_config_path"; then
            log_error "Refusing to use invalid RCLONE_CONFIG path: $rclone_config_path" >&2
            return 1
        fi
        local canonical_cfg
        canonical_cfg=$(realpath -e "$rclone_config_path")
        rclone_config_arg=(--config "$canonical_cfg")
        b_log_info "Using rclone config (from .env): $canonical_cfg"
    else
        # Not set in .env — auto-discover across well-known locations.
        local discovered_cfg
        if discovered_cfg=$(_resolve_rclone_config); then
            if ! validate_rclone_config_path "$discovered_cfg"; then
                log_error "Auto-discovered rclone config failed validation: $discovered_cfg" >&2
                log_error "Set RCLONE_CONFIG=/path/to/rclone.conf in .env to override." >&2
                return 1
            fi
            local canonical_discovered
            canonical_discovered=$(realpath -e "$discovered_cfg")
            rclone_config_arg=(--config "$canonical_discovered")
            b_log_info "Using rclone config (auto-discovered): $canonical_discovered"
            b_log_info "Tip: set RCLONE_CONFIG=$canonical_discovered in .env to make this explicit."
        else
            log_error "No rclone config file found. rclone cannot authenticate." >&2
            log_error "Options:" >&2
            log_error "  1. Set RCLONE_CONFIG=/path/to/rclone.conf in .env" >&2
            log_error "  2. Copy config to /etc/rclone/rclone.conf (system-wide)" >&2
            log_error "  3. Run: rclone config  (as root, so /root/.config/rclone/rclone.conf is created)" >&2
            return 1
        fi
    fi

    # ------------------------------------------------------------------
    # Build remote destination path.
    # RCLONE_REMOTE_PATH in .env sets the subfolder inside the remote
    # (default: vaultwarden_backups).  The backup type (db/full/emergency)
    # is always appended so each type lands in its own subdirectory.
    # ------------------------------------------------------------------
    local remote_base_path
    remote_base_path="$(get_config_value "RCLONE_REMOTE_PATH" "vaultwarden_backups")"
    remote_base_path="${remote_base_path#/}"
    remote_base_path="${remote_base_path%/}"

    local remote_path="${remote_name}:${remote_base_path}/${backup_type}"
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
        b_log_info "Offsite sync complete → ${remote_path}/$(basename "$enc_file")"
        return 0
    else
        log_error "Rclone sync FAILED — backup is safe locally, but offsite copy was not updated." >&2
        log_error "Retry manually: rclone copy ${rclone_config_arg[*]} $enc_file ${remote_path}/" >&2
        return 1
    fi
}

cleanup_old_backups() {
    local backup_dir="$1"
    local backup_type="$2"
    local keep_days="$3"

    if [[ -z "$backup_dir" || ! -d "$backup_dir" ]]; then
        log_error "cleanup_old_backups: invalid backup directory: '${backup_dir}'" >&2
        return 1
    fi

    b_log_info "Pruning ${backup_type} backups older than ${keep_days} days..."

    local deleted=0

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

perform_db_backup() {
    local target_dir="$1"
    local timestamp="$2"
    local age_pub_key="$3"
    local shared_tmpdir="$4"
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")

    b_log_info "Performing database backup..."

    if [[ "$DRY_RUN" == "true" ]]; then
        b_log_info "[DRY RUN] Would backup DB → $target_dir/db_backup_$timestamp.sqlite3.age"
        return 0
    fi

    local db_file="$state_dir/data/db.sqlite3"
    [[ -f "$db_file" ]] || { log_error "Database not found: $db_file" >&2; return 1; }

    local snap="$shared_tmpdir/db.sqlite3"

    b_log_info "Creating atomic DB snapshot (sqlite3 .backup)..."
    if ! create_db_snapshot_host "$state_dir" "$snap"; then
        b_log_warn "Host sqlite3 snapshot failed — attempting offline fallback with WAL checkpoint"

        local vw_container_name
        vw_container_name="$(get_config_value "COMPOSE_SERVICE_NAME" "vaultwarden")"
        local container_was_running=false

        if docker compose ps --services --filter status=running 2>/dev/null \
                | grep -qx "$vw_container_name"; then
            container_was_running=true
            b_log_warn "Stopping $vw_container_name before fallback copy..."
            docker compose stop "$vw_container_name" 2>/dev/null || true

            if ! wait_for_container_stopped "$vw_container_name" 30; then
                log_error "Cannot safely copy db.sqlite3: container did not reach stopped state." >&2
                log_error "Fix sqlite3 .backup or stop the container manually, then retry." >&2
                return 1
            fi
        fi

        local wal_result
        wal_result=$(sqlite3 "$db_file" "PRAGMA wal_checkpoint(TRUNCATE);" 2>&1) || {
            b_log_warn "WAL checkpoint command failed — copy may be missing recent transactions"
            b_log_warn "For guaranteed consistency, stop VaultWarden before backup or fix sqlite3 .backup"
        }
        if [[ -n "$wal_result" ]]; then
            if ! echo "$wal_result" | awk -F'|' '$2!=0 || $3!=0 {exit 1}'; then
                log_error "WAL checkpoint incomplete — unincorporated pages remain (result: $wal_result)" >&2
                log_error "Aborting fallback copy to avoid backing up an inconsistent database." >&2
                log_error "Stop VaultWarden fully, then retry, or fix sqlite3 .backup." >&2
                return 1
            fi
            b_log_info "WAL checkpoint succeeded (result: $wal_result)"
        fi

        cp "$db_file" "$snap"

        if [[ "$container_was_running" == "true" ]]; then
            b_log_info "Restarting $vw_container_name after fallback copy..."
            docker compose start "$vw_container_name" 2>/dev/null || \
                b_log_warn "Failed to restart $vw_container_name — restart manually"
        fi

        if [[ ! -s "$snap" ]]; then
            log_error "Fallback snapshot copy failed or produced empty file" >&2
            return 1
        fi
    fi

    verify_sqlite "$snap" || return 1

    b_log_info "Encrypting DB snapshot..."
    local enc="$target_dir/db_backup_$timestamp.sqlite3.age"
    local enc_tmp="${enc}.tmp"
    # FIX: age writes ciphertext to -o file, not stdout.  Using "2>&1 >&2" inside
    # a command-substitution context ($(...)) erroneously redirects age's stderr
    # to the capture pipe, polluting $backup_file with error text and causing
    # verify_backup_quick to see a non-existent path.  Use 2>/dev/null instead:
    # age emits nothing useful on stderr for a successful "-o file" run, and the
    # if-branch below already emits a log_error on failure.
    if ! age -r "$age_pub_key" -o "$enc_tmp" "$snap" 2>/dev/null; then
        log_error "Encryption failed" >&2
        rm -f "$enc_tmp"
        return 1
    fi
    mv "$enc_tmp" "$enc"
    secure_file "$enc" 600

    sha256sum "$enc" | awk '{print $1}' > "${enc}.sha256"
    chmod 600 "${enc}.sha256"

    [[ -s "$enc" ]] || { log_error "Encrypted output is empty" >&2; rm -f "$enc" "${enc}.sha256"; return 1; }

    cat > "${enc}.meta" <<MEOF
type=db
timestamp=$timestamp
original_size=$(stat -c%s "$db_file" 2>/dev/null || stat -f%z "$db_file" 2>/dev/null || echo 0)
archive_format=relative
version=2
MEOF

    b_log_info "DB backup: $(basename "$enc")"
    echo "$enc"
}

perform_full_backup() {
    local target_dir="$1"
    local timestamp="$2"
    local age_pub_key="$3"
    local backup_label="${4:-full}"
    local shared_tmpdir="$5"
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")

    local backup_label_title
    backup_label_title="$(printf '%s' "${backup_label:0:1}" | tr '[:lower:]' '[:upper:]')${backup_label:1}"

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

    b_log_info "Archiving state (relative paths, safe for staged restore)..."

    local tar_excludes=(
        "--exclude=${SCRIPT_DIR#/}/backups"
        "--exclude=${SCRIPT_DIR#/}/logs"
        "--exclude=${state_dir#/}/logs"
        "--exclude=*.sock"
        "--exclude=*.lock"
    )

    local tar_sources=()

    tar_sources+=("${SCRIPT_DIR#/}")

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

    local tar_exit=0
    # BUG-FB1 FIX: '2>&1 >&2' inside a $() context leaks tar stderr into the
    # capture pipe that populates $backup_file in main(), producing a multi-line
    # garbage path that verify_backup_quick cannot stat.  Replace with
    # '2>/dev/null' — tar writes the archive to the explicit -f target, not
    # stdout, so suppressing stderr is safe here; exit code still propagates.
    tar --use-compress-program='zstd --no-progress -T0 -3' -cf "$temp_tar" \
        -C / \
        "${tar_excludes[@]}" \
        "${tar_sources[@]}" 2>/dev/null || tar_exit=$?

    if (( tar_exit > 1 )); then
        log_error "tar failed with exit code $tar_exit" >&2
        return 1
    fi

    # BUG-FB2 FIX: guard against a silently-empty archive before attempting
    # snapshot injection or encryption.  A zero-byte $temp_tar here means
    # tar/zstd failed without a detectable exit code (e.g. SIGPIPE on the
    # zstd compressor side).  Failing early produces a clear error rather than
    # an empty encrypted file that passes the filename check but fails verify.
    if [[ ! -s "$temp_tar" ]]; then
        log_error "tar produced an empty archive — aborting backup" >&2
        return 1
    fi

    if [[ "$db_snapshot_ok" == "true" ]]; then
        local compressed_size snap_size available_kb required_kb
        compressed_size=$(stat -c%s "$temp_tar" 2>/dev/null || echo 0)
        snap_size=$(stat -c%s "$snap_db" 2>/dev/null || echo 0)
        available_kb=$(df -k "$(dirname "$temp_tar")" | awk 'END{print $4}')
        if [[ -z "$available_kb" || "$available_kb" == "0" ]]; then
            b_log_warn "Could not determine available disk space — proceeding with caution"
            available_kb=0
        fi
        required_kb=$(( (compressed_size * 9 + snap_size) / 1024 + 1048576 ))

        if (( available_kb < required_kb )); then
            log_error "Insufficient space for safe DB snapshot injection in $(dirname "$temp_tar")" >&2
            log_error "  Need: ~$((required_kb / 1024)) MB" >&2
            log_error "  Free: $((available_kb / 1024)) MB" >&2
            log_error "Aborting full/emergency backup to avoid fallback to a live DB copy." >&2
            log_error "Free space or move TMPDIR to a larger filesystem, then retry." >&2
            return 1
        fi
    fi

    if [[ "$db_snapshot_ok" == "true" ]]; then
        b_log_info "Injecting clean DB snapshot into archive..."
        local temp_tar_raw="$shared_tmpdir/${backup_label}_backup_$timestamp.tar"

        # BUG-FB1 FIX: same root cause — all '2>&1 >&2' replaced with '2>/dev/null'.
        # zstd/tar write to explicit targets (-c to stdout captured by >, -f file,
        # -o file); their stderr is noise in the $() context and must not reach
        # the capture pipe.  Exit codes are still checked by the && chain and the
        # explicit '|| tar_exit=$?' below.
        if zstd --no-progress -d -T0 -c "$temp_tar" 2>/dev/null > "$temp_tar_raw" \
            && tar -rf "$temp_tar_raw" -C "$snap_dir" "${state_dir#/}/data/db.sqlite3" 2>/dev/null \
            && zstd --no-progress -T0 -3 "$temp_tar_raw" -o "${temp_tar}.new" 2>/dev/null
        then
            mv "${temp_tar}.new" "$temp_tar"
            rm -f "$temp_tar_raw"
            b_log_info "Clean DB snapshot injected"
        else
            b_log_warn "DB snapshot injection failed — archive will use live DB copy"
            rm -f "$temp_tar_raw" "${temp_tar}.new" 2>/dev/null || true
            tar_excludes=(
                "--exclude=${SCRIPT_DIR#/}/backups"
                "--exclude=${SCRIPT_DIR#/}/logs"
                "--exclude=${state_dir#/}/logs"
                "--exclude=*.sock"
                "--exclude=*.lock"
            )
            tar_exit=0
            tar --use-compress-program='zstd --no-progress -T0 -3' -cf "$temp_tar" -C / \
                "${tar_excludes[@]}" "${tar_sources[@]}" 2>/dev/null || tar_exit=$?
            (( tar_exit <= 1 )) || { log_error "Rebuild tar failed" >&2; return 1; }
            # Guard the fallback archive too.
            if [[ ! -s "$temp_tar" ]]; then
                log_error "Fallback tar also produced an empty archive — aborting" >&2
                return 1
            fi
        fi
    fi

    b_log_info "Encrypting ${backup_label} archive..."
    local enc="$target_dir/${backup_label}_backup_$timestamp.tar.zst.age"
    local enc_tmp="${enc}.tmp"

    # BUG-FB1 FIX: same root-cause as perform_db_backup — replace '2>&1 >&2'
    # with '2>/dev/null' so age's stderr cannot leak into the $() capture and
    # corrupt the $backup_file path returned by this function.  age writes the
    # ciphertext to -o enc_tmp, not stdout; suppressing stderr is correct.
    if ! age -r "$age_pub_key" -o "$enc_tmp" "$temp_tar" 2>/dev/null; then
        log_error "Encryption failed" >&2
        rm -f "$enc_tmp"
        return 1
    fi
    mv "$enc_tmp" "$enc"
    secure_file "$enc" 600

    sha256sum "$enc" | awk '{print $1}' > "${enc}.sha256"
    chmod 600 "${enc}.sha256"

    [[ -s "$enc" ]] || { log_error "Encrypted output is empty" >&2; rm -f "$enc" "${enc}.sha256"; return 1; }

    cat > "${enc}.meta" <<MEOF
type=${backup_label}
timestamp=$timestamp
archive_format=relative
version=2
MEOF

    b_log_info "${backup_label_title} backup: $(basename "$enc")"
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

    trap cleanup EXIT HUP INT TERM

    # /run/lock is the FHS-correct location for transient process lock files.
    # /var/lock is a legacy symlink to /run/lock on modern systemd systems,
    # but ProtectSystem=strict in systemd units makes /var/lock read-only while
    # /run/lock remains writable (it is a tmpfs mount).  Using /run/lock
    # directly avoids the read-only filesystem error when running under systemd.
    local LOCK_FILE="/run/lock/vaultwarden-backup.lock"

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

    # BUG-AK4 FIX: use _resolve_age_key() so SOPS_AGE_KEY_FILE env var is
    # only honoured when it is an absolute path or exists as a relative one.
    # A stale relative value from the env file (written before BUG-AK1 fix)
    # is skipped and the canonical /etc/vaultwarden/age-key.txt is tried next.
    local age_key_file
    age_key_file=$(_resolve_age_key) || {
        log_error "Age key file not found: $age_key_file"
        exit 1
    }

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

        local verify_failed=false
        local rclone_failed=false

        if [[ "$FULL_VERIFY" == "true" ]]; then
            if ! verify_backup_full "$backup_file" "$actual_type" "$TMPDIR_BACKUP"; then
                log_error "Backup verification failed — discarding corrupt archive."
                rm -f "$backup_file" "${backup_file}.meta" "${backup_file}.sha256"
                exit 1
            fi
        else
            if ! verify_backup_quick "$backup_file" "$age_key_file"; then
                verify_failed=true
                log_error "Quick verification failed — backup may be corrupt."
                if [[ "$EMAIL_NOTIFY" == "true" ]]; then
                    local warn_subj="[VaultWarden] WARNING: Backup verify FAILED: $actual_type ($timestamp)"
                    local warn_body
                    warn_body="$(printf 'Backup type:  %s\nTimestamp:    %s\nFile:         %s\nHost:         %s\n\nQuick verification (SHA256 + decrypt probe) FAILED.\nThe encrypted archive may be corrupt. Manual inspection required.\n' \
                        "$actual_type" "$timestamp" \
                        "$(basename "${backup_file:-unknown}")" \
                        "$(hostname -f 2>/dev/null || hostname)")"
                    send_notification_email "$warn_subj" "$warn_body" 2>/dev/null || true
                fi
                log_error "Skipping offsite sync due to verification failure."
                RCLONE_SYNC=false
            fi
        fi

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
