#!/usr/bin/env bash
# utilities/backup-run.sh — Creates, verifies, and optionally syncs VaultWarden backups.
# shellcheck disable=SC1091,SC2317

set -euo pipefail

# SCRIPT_DIR must resolve to PROJECT_ROOT so inherited $SCRIPT_DIR/lib/ and
# $SCRIPT_DIR/secrets/ references from backup.sh still work.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
init_common_lib "$0"
source "$SCRIPT_DIR/lib/email.sh"
DOCKER_PROJECT_LABEL="${DOCKER_PROJECT_LABEL:-label=com.docker.compose.project=vaultwarden-oci}"
source "$SCRIPT_DIR/lib/docker.sh"
source "$SCRIPT_DIR/lib/backup-utils.sh"
source "$SCRIPT_DIR/lib/crypto.sh"
source "$SCRIPT_DIR/lib/storage.sh"  # provides require_project_state_ready()
load_project_environment || exit 1

BACKUP_TYPE="auto"    # Backup mode: auto, db, full, or emergency.
DRY_RUN=false
KEEP_DAYS=14
KEEP_DAYS_EXPLICIT=false
QUIET=false
FORCE=false
EMAIL_NOTIFY=false   # Set by --email; send_notification_email() runs on completion.
LIST_ONLY=false      # Set by the list subcommand; prints backups and exits without root.
RCLONE_SYNC=false    # Set by --rclone; syncs the encrypted backup after creation.
FULL_VERIFY=false    # Set by --full-verification; decrypts and integrity-checks before sync.
LOCK_FD=""   # Assigned by exec {LOCK_FD}>file (Bash 4.1+ automatic FD allocation).
SKIP_OPS_LOCK=false  # Set by --skip-ops-lock; caller (maintenance-run) already holds OPS_LOCK.
JSON_OUTPUT=false

show_help() {
    cat << 'EOF'
VaultWarden-OCI Backup Script

USAGE:
    sudo ./backup.sh <subcommand> [options]
    ./backup.sh list                                    # No root required

SUBCOMMANDS:
    run [TYPE]        Create a backup  (TYPE: auto | db | full | emergency)
    list [--json]     List existing backups (no root required; JSON optional)
    verify            Verify the most recent backup's integrity
    rotate            Apply retention policy and prune old backups
    sync               Copy all retained local backups to rclone by type

RUN OPTIONS (used after 'run'):
    --keep N                 Override configured retention for this run
    --quiet                  Suppress non-error output
    --force                  Ignore locks and force backup
    --email                  Send email notification on completion/failure
    --rclone                 Sync encrypted backup to rclone remote after creation
    --full-verification      End-to-end decrypt + integrity check before sync (fatal on failure)
    --skip-full-verification Fast checksum only — explicit default
    --dry-run                Show what would be done without executing

SYNC / ROTATE OPTIONS:
    --keep N                 Override configured retention for every backup type
    --quiet                  Suppress non-error output
    --dry-run                Preview copy or pruning operations

GLOBAL SUBCOMMAND:
    help                     Show this help

GLOBAL OPTIONS:
    --version, -V            Print the VaultWarden-OCI version and exit

EXAMPLES:
    sudo ./backup.sh run                # Auto-mode backup (db or full based on schedule)
    sudo ./backup.sh run db             # Database-only backup
    sudo ./backup.sh run full           # Full state backup
    sudo ./backup.sh run db --keep 30             # Keep 30 days of backups
    ./backup.sh list                              # List existing backups (no sudo)
    ./backup.sh list --json                       # Machine-readable backup inventory
    sudo ./backup.sh verify                       # Verify the latest backup
    sudo ./backup.sh rotate --keep 30             # Prune backups older than 30 days
    sudo ./backup.sh sync                         # Upload db/full/emergency backups
EOF
}

_SUBCMD=""
if [[ $# -eq 0 ]]; then
    show_help; exit 0
fi

case "$1" in
    run|list|verify|rotate|sync)
        _SUBCMD="$1"
        shift
        ;;
    help|--help|-h)
        show_help; exit 0
        ;;
    --version|-V)
        print_project_version "VaultWarden-OCI" "$SCRIPT_DIR"; exit 0
        ;;
    *)
        log_error "Unknown subcommand: '$1'"
        log_error "Valid subcommands: run [TYPE] | list | verify | rotate | sync"
        log_error "Run './backup.sh help' for usage."
        exit 1
        ;;
esac

case "$_SUBCMD" in
    run)
        if [[ $# -gt 0 && "$1" != --* ]]; then
            BACKUP_TYPE="$1"; shift
        fi
        while [[ $# -gt 0 ]]; do
            case $1 in
                --keep)                   KEEP_DAYS="$2"; KEEP_DAYS_EXPLICIT=true; shift 2 ;;
                --quiet)                  QUIET=true;        shift ;;
                --force)                  FORCE=true;        shift ;;
                --email)                  EMAIL_NOTIFY=true; shift ;;
                --rclone)                 RCLONE_SYNC=true;  shift ;;
                --full-verification)      FULL_VERIFY=true;  shift ;;
                --skip-full-verification) FULL_VERIFY=false; shift ;;
                --dry-run)                DRY_RUN=true;      shift ;;
                --skip-ops-lock)          SKIP_OPS_LOCK=true; shift ;;
                *) log_error "Unknown option for run: $1"; show_help; exit 2 ;;
            esac
        done
        ;;
    list)
        LIST_ONLY=true
        while [[ $# -gt 0 ]]; do
            case $1 in
                --json) JSON_OUTPUT=true; shift ;;
                *) log_error "Unknown option for list: $1"; show_help; exit 2 ;;
            esac
        done
        ;;
    verify)
        FULL_VERIFY=true
        while [[ $# -gt 0 ]]; do
            case $1 in
                --type) BACKUP_TYPE="$2"; shift 2 ;;
                --quiet) QUIET=true; shift ;;
                *) log_error "Unknown option for verify: $1"; show_help; exit 2 ;;
            esac
        done
        ;;
    rotate)
        LIST_ONLY=false
        while [[ $# -gt 0 ]]; do
            case $1 in
                --keep)  KEEP_DAYS="$2"; KEEP_DAYS_EXPLICIT=true; shift 2 ;;
                --quiet) QUIET=true;     shift ;;
                --dry-run) DRY_RUN=true; shift ;;
                *) log_error "Unknown option for rotate: $1"; show_help; exit 2 ;;
            esac
        done
        ;;
    sync)
        while [[ $# -gt 0 ]]; do
            case $1 in
                --keep)  KEEP_DAYS="$2"; KEEP_DAYS_EXPLICIT=true; shift 2 ;;
                --quiet) QUIET=true; shift ;;
                --dry-run) DRY_RUN=true; shift ;;
                *) log_error "Unknown option for sync: $1"; show_help; exit 2 ;;
            esac
        done
        ;;
    "")
        show_help; exit 0
        ;;
esac

if [[ "$_SUBCMD" == "run" || "$_SUBCMD" == "rotate" || "$_SUBCMD" == "sync" ]]; then
    if ! [[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] || ! (( KEEP_DAYS >= 1 )); then
        log_error "Invalid --keep value: '${KEEP_DAYS}' — must be a positive integer (e.g. 14)"
        exit 2
    fi
fi

backup_log_info()    { [[ "$QUIET" == "true" ]] || log_info "$*" >&2;    }
backup_log_success() { [[ "$QUIET" == "true" ]] || log_success "$*" >&2; }
backup_log_warn()    { [[ "$QUIET" == "true" ]] || log_warn "$*" >&2;    }
backup_require_root() {
    if (( EUID != 0 )); then
        log_error "backup ${_SUBCMD} requires root. Run: sudo ./backup.sh ${_SUBCMD}"
        exit 1
    fi
}

TMPDIR_BACKUP=""
LOCK_FILE=""
cleanup() {
    if [[ -n "$TMPDIR_BACKUP" ]]; then rm -rf "$TMPDIR_BACKUP" 2>/dev/null; fi
    if [[ -n "${LOCK_FILE:-}" ]]; then rm -f "$LOCK_FILE" 2>/dev/null; fi
}


_resolve_age_key() {
    local candidates=(
        "${SOPS_AGE_KEY_FILE:-}"
        "/etc/vaultwarden/age-key.txt"
        "$SCRIPT_DIR/secrets/keys/age-key.txt"
    )
    for candidate in "${candidates[@]}"; do
        [[ -z "$candidate" ]] && continue
        [[ "$candidate" != /* && ! -f "$candidate" ]] && continue
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
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

_default_backup_dir() { vw_default_backup_dir; }

get_backup_dir() {
    local type="$1"
    local base_dir
    base_dir="$(get_config_value "BACKUP_DIR" "$(_default_backup_dir)")"
    local dir="$base_dir/$type"
    ensure_dir "$dir" 750 "$(get_real_user)"
    echo "$dir"
}

_retention_days_for_type() {
    local backup_type="$1"
    if [[ "$KEEP_DAYS_EXPLICIT" == "true" ]]; then
        printf '%s\n' "$KEEP_DAYS"
        return 0
    fi

    local specific_key=""
    case "$backup_type" in
        db)        specific_key="BACKUP_RETENTION_DB_DAYS" ;;
        full)      specific_key="BACKUP_RETENTION_FULL_DAYS" ;;
        emergency) specific_key="BACKUP_RETENTION_EMERGENCY_DAYS" ;;
        *) log_error "Unknown backup type for retention: $backup_type"; return 1 ;;
    esac

    local retention
    retention=$(get_config_value "$specific_key" "")
    [[ -n "$retention" ]] || retention=$(get_config_value "BACKUP_RETENTION_DAYS" "$KEEP_DAYS")
    if ! [[ "$retention" =~ ^[0-9]+$ ]] || (( retention < 1 )); then
        log_error "Invalid retention value for ${backup_type}: '${retention}'"
        return 1
    fi
    printf '%s\n' "$retention"
}

_load_integrity_hmac_key() {
    local raw_value=""
    local pipeline_rc=0

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        backup_log_warn "[DRY RUN] Backup integrity HMAC key is unavailable; no files will be written."
        return 0
    fi

    if raw_value="$(
        SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE" \
            sops -d "$SECRETS_FILE" \
            | yq -r '.file_integrity_hmac_key // ""'
    )"; then
        pipeline_rc=0
    else
        pipeline_rc=$?
    fi

    if [[ $pipeline_rc -ne 0 || -z "$raw_value" || "$raw_value" == CHANGE_ME* ]]; then
        unset FILE_INTEGRITY_HMAC_KEY

        if [[ "${REQUIRE_AUTHENTICATED_INTEGRITY:-false}" == "true" ]]; then
            log_error "Authenticated backup integrity is required, but file_integrity_hmac_key is unavailable."
            log_error "Run: ./edit-secrets.sh rotate file_integrity_hmac_key"
            return 1
        fi

        backup_log_warn "Backup integrity HMAC key is unavailable; legacy SHA-256-only mode remains active."
        return 0
    fi

    FILE_INTEGRITY_HMAC_KEY="$raw_value"
    export FILE_INTEGRITY_HMAC_KEY
}



auto_determine_backup_type() {
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    local db_file="$state_dir/data/db.sqlite3"

    if [[ ! -f "$db_file" ]]; then
        backup_log_info "Database not found — defaulting to full backup"
        echo "full"; return 0
    fi

    local db_mtime current_time age_hours
    db_mtime=$(stat -c %Y "$db_file" 2>/dev/null || stat -f %m "$db_file" 2>/dev/null || echo "0")
    current_time=$(date +%s)
    age_hours=$(( (current_time - db_mtime) / 3600 ))

    local full_backup_dir last_full full_age_days=999
    local auto_base_dir
    auto_base_dir="$(get_config_value "BACKUP_DIR" "$(_default_backup_dir)")"
    full_backup_dir="$auto_base_dir/full"
    local _stat_cmd=()
    if stat --version 2>/dev/null | grep -q GNU; then
        _stat_cmd=(stat -c '%Y')
    else
        _stat_cmd=(stat -f '%m')
    fi
    last_full=$(find "$full_backup_dir" -name "*.age" -type f 2>/dev/null \
                | while IFS= read -r _f; do
                    printf '%s %s\n' "$("${_stat_cmd[@]}" "$_f" 2>/dev/null || echo 0)" "$_f"
                  done \
                | sort -n | tail -1 | cut -d' ' -f2- || true)
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
    backup_log_info "Verifying SQLite integrity (host sqlite3)..."
    local result
    result=$(sqlite3 "$dbfile" "PRAGMA integrity_check;" 2>&1) || {
        log_error "SQLite integrity check error: ${result}" >&2
        return 1
    }
    if [[ "$result" != "ok" ]]; then
        log_error "SQLite integrity check FAILED: ${result}" >&2
        return 1
    fi
    backup_log_info "SQLite integrity check passed"
    return 0
}

_backup_storage_mode() {
    local state_dir="$1" data_mount="${2:-}" data_device="${3:-}"
    if [[ "$state_dir" == "/var/lib/vaultwarden" ]]; then
        if mountpoint -q "$state_dir" 2>/dev/null || [[ -f "$state_dir/.vw-data-volume" ]]; then echo "block"; else echo "boot"; fi
    elif [[ -n "$data_mount" && "$state_dir" == "$data_mount" ]] || [[ -n "$data_device" ]] || [[ "$state_dir" == /mnt/* ]]; then
        echo "block"
    else
        echo "unknown"
    fi
}

_validate_full_archive_payload() {
    local temp_tar="$1" state_dir="$2" script_dir="$3" backup_label="$4"
    local expected_db="${state_dir#/}/data/db.sqlite3"
    local live_db="${state_dir}/data/db.sqlite3"
    local members
    members="$(tar --use-compress-program='zstd -d -T0' -tf "$temp_tar" 2>/dev/null || tar -tf "$temp_tar" 2>/dev/null)" || {
        log_error "Backup validation failed: cannot list tar members." >&2
        rm -f "$temp_tar"
        return 1
    }
    members="$(printf '%s\n' "$members" | sed 's#^\./##')"
    if [[ -f "$live_db" ]]; then
        local count
        count="$(printf '%s\n' "$members" | grep -Fxc "$expected_db" || true)"
        if [[ "$count" != "1" ]]; then
            log_error "Backup validation failed before encryption/upload: live DB is missing from ${backup_label} archive." >&2
            log_error "  PROJECT_STATE_DIR: $state_dir" >&2
            log_error "  SCRIPT_DIR: $script_dir" >&2
            log_error "  Expected DB member path: $expected_db" >&2
            log_error "  First 30 tar members:" >&2
            printf '%s\n' "$members" | head -30 | sed 's/^/    /' >&2
            rm -f "$temp_tar"
            return 1
        fi
    fi
    if ! printf '%s\n' "$members" | grep -Eq "^${script_dir#/}/?$"; then
        backup_log_warn "Backup validation warning: project config root ${script_dir#/}/ was not visible in archive member list."
    fi
    if printf '%s\n' "$members" | grep -Eq '(^|/)\.pre-restore-[^/]*/data/db\.sqlite3$'; then
        backup_log_warn "Backup validation: ignored pre-restore snapshot DBs; they do not satisfy live DB validation."
    fi
    return 0
}

create_db_snapshot_host() {
    local state_dir="$1"
    local dest="$2"
    local db_file="${state_dir}/data/db.sqlite3"
    [[ -f "$db_file" ]] || { log_error "Database not found: $db_file" >&2; return 1; }
    sqlite3 "$db_file" "$(printf '.backup %s' "$dest")" || {
        log_error "sqlite3 .backup failed for: $db_file (check disk space: df -h $(dirname "$dest"); check DB lock: fuser $db_file)" >&2
        return 1
    }
    return 0
}

wait_for_container_stopped() {
    local service="$1"
    local max_wait="${2:-30}"
    local elapsed=0

    backup_log_info "Waiting for container '$service' to reach stopped state (max ${max_wait}s)..."

    local status=""
    while (( elapsed < max_wait )); do
        status=$(docker inspect --format '{{.State.Status}}' \
                     "$(docker compose ps -q "$service" 2>/dev/null || true)" 2>/dev/null \
                 || docker ps --filter "name=${service}" --format '{{.Status}}' 2>/dev/null \
                 || echo "unknown")

        case "$status" in
            exited|dead|"")
                backup_log_info "Container '$service' is stopped (status: ${status:-exited})"
                return 0
                ;;
            removing|paused)
                backup_log_warn "Container '$service' in unexpected state: $status"
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

    backup_log_info "Running full verification (decrypt + integrity check)..."

    if [[ -f "${enc_file}.sha256" ]]; then
        verify_file_integrity "$enc_file" || return 1
    elif [[ "${REQUIRE_AUTHENTICATED_INTEGRITY:-false}" == "true" ]]; then
        log_error "Full verification FAILED: required integrity sidecar is missing for $enc_file" >&2
        return 1
    else
        backup_log_warn "No SHA256 sidecar found — authenticated file check skipped"
    fi

    local age_key_file
    age_key_file=$(_resolve_age_key) || {
        log_error "Age key file not found: $age_key_file" >&2
        return 1
    }

    local dec_out
    dec_out="$shared_tmpdir/verify_$(basename "$enc_file" .age)"

    if ! age -d -i "$age_key_file" -o "$dec_out" "$enc_file"; then
        log_error "Full verification FAILED: could not decrypt $enc_file" >&2
        return 1
    fi

    case "$backup_type" in
        db)
            verify_sqlite "$dec_out" || return 1

            local live_db_path
            live_db_path="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")/data/db.sqlite3"
            if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$live_db_path" ]]; then
                local backup_schema live_schema
                backup_schema=$(sqlite3 "$dec_out" "PRAGMA user_version;" 2>/dev/null || echo "")
                live_schema=$(sqlite3 "$live_db_path" "PRAGMA user_version;" 2>/dev/null || echo "")
                if [[ -n "$backup_schema" && -n "$live_schema" ]]; then
                    if [[ "$backup_schema" != "$live_schema" ]]; then
                        log_warn "[backup] Schema version mismatch: backup=${backup_schema} live=${live_schema}" >&2
                        log_warn "[backup] This backup may not be directly restorable to the running Vaultwarden version." >&2
                        log_warn "[backup] Restore to a matching Vaultwarden version or run migrations after restore." >&2
                    else
                        backup_log_info "Schema version matches live DB (user_version=${live_schema})"
                    fi
                fi
            fi
            ;;
        full|emergency)
            backup_log_info "Verifying archive structure..."
            local _decomp_prog
            case "$dec_out" in
                *.tar.zst|*.zst)  _decomp_prog='zstd -d -T0' ;;
                *.tar.bz2|*.bz2)  _decomp_prog='bzip2 -d' ;;
                *.tar.xz|*.xz)    _decomp_prog='xz -d' ;;
                *.tar.gz|*.tgz)   _decomp_prog='gzip -d' ;;
                *.tar.lz4|*.lz4)  _decomp_prog='lz4 -d' ;;
                *)
                    log_error "verify_backup_full: unrecognised archive extension for: $(basename "$dec_out")"
                    log_error "Add the format to the decompressor case in verify_backup_full()."
                    return 1
                    ;;
            esac
            if ! tar --use-compress-program="$_decomp_prog" -tf "$dec_out" >/dev/null 2>&1; then
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

    backup_log_info "Full verification passed: $(basename "$enc_file")"
    rm -f "$dec_out"
    return 0
}

verify_backup_quick() {
    local enc_file="$1"
    local age_key_file="$2"
    local _quick_verify_hash_skipped=false

    backup_log_info "Running quick verification (SHA256 + decrypt probe)..."

    [[ -s "$enc_file" ]] || { log_error "Quick verify FAILED: encrypted file is empty" >&2; return 1; }

    local sha256_file="${enc_file}.sha256"
    if [[ -f "$sha256_file" ]]; then
        verify_file_integrity "$enc_file" || return 1
        backup_log_info "Integrity sidecar matches"
    else
        backup_log_warn "No SHA256 sidecar found — hash check skipped"
        _quick_verify_hash_skipped=true
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
    backup_log_info "Decrypt probe passed"

    if [[ "$_quick_verify_hash_skipped" == "true" ]]; then
        backup_log_info "Quick verification passed (no .sha256 sidecar — hash check skipped): $(basename "$enc_file")"
    else
        backup_log_info "Quick verification passed (SHA256 + decrypt probe): $(basename "$enc_file")"
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

    local -a rclone_config_arg=()
    _resolve_rclone_config_arg rclone_config_arg || return 1
    backup_log_info "Using validated rclone config: ${rclone_config_arg[1]}"

    local remote_base_path
    remote_base_path="$(get_config_value "RCLONE_REMOTE_PATH" "vaultwarden_backups")"
    remote_base_path="${remote_base_path#/}"
    remote_base_path="${remote_base_path%/}"

    local remote_path="${remote_name}:${remote_base_path}/${backup_type}"
    backup_log_info "Syncing backup to rclone remote: ${remote_path}/"
    backup_log_info "Pre-flight check: testing connectivity to rclone remote '${remote_name}'..."
    if ! rclone lsd "${rclone_config_arg[@]}" "${remote_name}:" --contimeout 10s --timeout 30s &>/dev/null; then
        log_error "Pre-flight check FAILED: cannot reach rclone remote '${remote_name}'. Aborting offsite sync." >&2
        log_error "Verify credentials and network, then retry: rclone lsd ${remote_name}:" >&2
        if declare -f send_notification_email &>/dev/null; then
            send_notification_email \
                "[VaultWarden] BACKUP ABORTED: rclone remote unreachable" \
                "$(printf 'Pre-flight connectivity check failed for remote: %s\nHost: %s\n\nVerify rclone credentials and network connectivity, then re-run the backup.\n' \
                    "${remote_name}" "$(hostname -f 2>/dev/null || hostname)")" \
                2>/dev/null || true
        fi
        return 1
    fi
    backup_log_info "Pre-flight check passed: rclone remote '${remote_name}' is reachable."

    local rclone_stderr_tmp="${TMPDIR_BACKUP}/rclone_stderr.tmp"

    local rclone_exit=0
    rclone copy "${rclone_config_arg[@]}" "$enc_file" "$remote_path/" --checksum 2>"${rclone_stderr_tmp}" || rclone_exit=$?
    if (( rclone_exit != 0 )); then
        local rclone_err
        rclone_err=$(head -20 "${rclone_stderr_tmp}" 2>/dev/null || true)
        log_error "[backup] rclone upload FAILED (exit ${rclone_exit}). The backup was NOT delivered to remote storage." >&2
        log_error "[backup] rclone error output: ${rclone_err}" >&2
        return 1
    fi

    local meta_file="${enc_file}.meta"
    local _sidecar_warn=false
    local _sidecar_fail=0
    if [[ -f "$meta_file" ]]; then
        local _meta_exit=0
        rclone copy "${rclone_config_arg[@]}" "$meta_file" "$remote_path/" --checksum \
            2>"${rclone_stderr_tmp}" || _meta_exit=$?
        if (( _meta_exit != 0 )); then
            log_warn "[backup] Sidecar upload FAILED: $(basename "$meta_file") (exit ${_meta_exit}) — integrity metadata missing from remote." >&2
            _sidecar_warn=true
            (( _sidecar_fail++ )) || true
        fi
    fi

    local sha256_file="${enc_file}.sha256"
    if [[ -f "$sha256_file" ]]; then
        local _sha256_exit=0
        rclone copy "${rclone_config_arg[@]}" "$sha256_file" "$remote_path/" --checksum \
            2>"${rclone_stderr_tmp}" || _sha256_exit=$?
        if (( _sha256_exit != 0 )); then
            log_warn "[backup] Sidecar upload FAILED: $(basename "$sha256_file") (exit ${_sha256_exit}) — checksum file missing from remote." >&2
            _sidecar_warn=true
            (( _sidecar_fail++ )) || true
        fi
    fi

    local hmac_file="${enc_file}.sha256.hmac"
    if [[ -f "$hmac_file" ]]; then
        local _hmac_exit=0
        rclone copy "${rclone_config_arg[@]}" "$hmac_file" "$remote_path/" --checksum \
            2>"${rclone_stderr_tmp}" || _hmac_exit=$?
        if (( _hmac_exit != 0 )); then
            log_warn "[backup] Sidecar upload FAILED: $(basename "$hmac_file") (exit ${_hmac_exit}) — authenticated integrity metadata missing from remote." >&2
            _sidecar_warn=true
            (( _sidecar_fail++ )) || true
        fi
    fi

    if [[ "$_sidecar_warn" == "true" ]]; then
        log_warn "[backup] One or more sidecar files could not be uploaded to ${remote_path}/." >&2
        log_warn "[backup] The primary backup archive was delivered. Remote integrity checks will" >&2
        log_warn "[backup] fall back to size-only verification until sidecars are re-uploaded." >&2
    fi

    local remote_file_path
    remote_file_path="${remote_path}/$(basename "$enc_file")"
    local rclone_size_out rclone_size_err_tmp="${TMPDIR_BACKUP}/rclone_size_stderr.tmp"
    local remote_size_bytes=0
    local remote_size_human=""

    if rclone_size_out=$(rclone size "${rclone_config_arg[@]}" "$remote_file_path" \
                             2>"$rclone_size_err_tmp"); then

        remote_size_bytes=$(printf '%s\n' "$rclone_size_out" \
            | awk 'tolower($0) ~ /^total size:/ { gsub(/[^0-9]/, "", $3); print $3+0; exit }')
        remote_size_bytes="${remote_size_bytes:-0}"

        remote_size_human=$(printf '%s\n' "$rclone_size_out" \
            | awk 'tolower($0) ~ /^total size:/ { for(i=4;i<=NF;i++) printf "%s ", $i; exit }' \
            | sed 's/[[:space:]]*$//')
    else
        local rclone_size_err
        rclone_size_err=$(cat "$rclone_size_err_tmp" 2>/dev/null || true)
        log_error "[backup] rclone size query failed for: ${remote_file_path}" >&2
        [[ -n "$rclone_size_err" ]] && log_error "[backup] rclone size error: ${rclone_size_err}" >&2
    fi

    if [[ -z "$remote_size_bytes" || "$remote_size_bytes" -eq 0 ]]; then
        log_error "[backup] Remote size verification FAILED: ${remote_file_path} reported zero bytes or is unreachable." >&2
        log_error "[backup] The upload may have silently failed. Treat this backup as NOT offsite." >&2
        return 1
    fi

    backup_log_info "Remote size verified: ${remote_file_path} — ${remote_size_bytes} bytes ${remote_size_human}"

    if [[ "$_sidecar_warn" == "true" ]]; then
        log_warn "[backup] Offsite sync completed with partial sidecar failures (${_sidecar_fail} file(s))"
        return 2
    fi

    backup_log_info "Offsite sync complete → ${remote_file_path}"

}

# _resolve_rclone_config_arg NAMEREF_ARRAY
#
# Resolves, validates, and canonicalises the rclone config path, then populates
# the caller's array (passed by nameref) with the --config argument pair.
# NAMEREF_ARRAY is the caller's variable name without a leading dollar sign.
# Returns 1 and logs an error when resolution or validation fails.
# Requires Bash 5.0+ (the project baseline is Ubuntu 22.04 LTS).
_resolve_rclone_config_arg() {
    local -n _rca_out="$1"
    local cfg
    cfg=$(get_config_value "RCLONE_CONFIG" "") || cfg=""
    if [[ -z "$cfg" ]]; then
        cfg=$(_resolve_rclone_config) || {
            log_error "_resolve_rclone_config_arg: no rclone config file found"
            return 1
        }
    fi
    validate_rclone_config_path "$cfg" || return 1
    cfg=$(realpath -e "$cfg") || return 1
    _rca_out=(--config "$cfg")
}

sync_all_backups_to_rclone() {
    if ! command -v rclone >/dev/null 2>&1; then
        log_error "rclone not installed — offsite backup cannot proceed."
        return 1
    fi

    local remote_name
    remote_name=$(get_config_value "RCLONE_REMOTE_NAME" "")
    if [[ -z "$remote_name" || "$remote_name" == "CHANGE_ME_RCLONE_REMOTE" ]]; then
        log_error "RCLONE_REMOTE_NAME is not configured in .env."
        return 1
    fi

    local -a rclone_config_arg=()
    _resolve_rclone_config_arg rclone_config_arg || return 1

    backup_log_info "Testing connectivity to rclone remote '${remote_name}'..."
    rclone lsd "${rclone_config_arg[@]}" "${remote_name}:" --contimeout 10s --timeout 30s >/dev/null || {
        log_error "Cannot reach rclone remote '${remote_name}'."
        return 1
    }

    local base_dir remote_base
    base_dir=$(get_config_value "BACKUP_DIR" "$(_default_backup_dir)")
    remote_base=$(get_config_value "RCLONE_REMOTE_PATH" "vaultwarden_backups")
    remote_base="${remote_base#/}"
    remote_base="${remote_base%/}"

    local -a dry_run_arg=()
    [[ "$DRY_RUN" == "true" ]] && dry_run_arg=(--dry-run)

    local copied_types=0
    local t local_dir retention
    for t in db full emergency; do
        local_dir="${base_dir}/${t}"
        [[ -d "$local_dir" ]] || continue
        retention=$(_retention_days_for_type "$t") || return 1
        if [[ "$DRY_RUN" == "true" ]]; then
            backup_log_info "[DRY RUN] Would apply ${retention}-day local retention to ${t} backups before upload."
        else
            cleanup_old_backups "$local_dir" "$t" "$retention" || return 1
        fi

        if ! find "$local_dir" -maxdepth 1 -name '*.age' -type f -print -quit | grep -q .; then
            backup_log_info "No retained ${t} backups to upload."
            continue
        fi

        backup_log_info "Copying retained ${t} backups to ${remote_name}:${remote_base}/${t}/"
        rclone copy "${rclone_config_arg[@]}" "$local_dir/" \
            "${remote_name}:${remote_base}/${t}/" \
            --include '*.age' \
            --include '*.age.sha256' \
            --include '*.age.sha256.hmac' \
            --include '*.age.meta' \
            --checksum "${dry_run_arg[@]}" || return 1
        (( ++copied_types )) || true
    done

    _prune_remote_backups || return 1
    backup_log_success "Rclone backup copy complete (${copied_types} backup type(s))."
}

# _prune_remote_backups
#
# Prunes backup files on the configured rclone remote that are older than
# the per-type retention period. Retention days are read via
# _retention_days_for_type() for each backup type, mirroring the local
# cleanup_old_backups() policy on the remote store.
#
# Non-fatal: logs a warning and returns 1 on partial failure so that a single
# unreachable remote does not abort an otherwise successful backup run.
_prune_remote_backups() {
    if ! command -v rclone >/dev/null 2>&1; then
        backup_log_info "rclone not installed — skipping remote retention pruning."
        return 0
    fi

    local remote_name
    remote_name="$(get_config_value "RCLONE_REMOTE_NAME" "")"
    if [[ -z "$remote_name" || "$remote_name" == "CHANGE_ME_RCLONE_REMOTE" ]]; then
        backup_log_info "RCLONE_REMOTE_NAME not configured — skipping remote retention pruning."
        return 0
    fi

    local -a rclone_config_arg=()
    _resolve_rclone_config_arg rclone_config_arg || return 1

    local remote_base_path
    remote_base_path="$(get_config_value "RCLONE_REMOTE_PATH" "vaultwarden_backups")"
    remote_base_path="${remote_base_path#/}"
    remote_base_path="${remote_base_path%/}"

    local _prune_failed=false

    for t in db full emergency; do
        local remote_path="${remote_name}:${remote_base_path}/${t}"
        local retention_days
        retention_days=$(_retention_days_for_type "$t") || return 1

        local -a remote_files=()
        mapfile -t remote_files < <(
            rclone lsf "${rclone_config_arg[@]}" "${remote_path}/" \
                --files-only --include "*.age" \
                --contimeout 15s --timeout 60s 2>/dev/null || true
        )

        if [[ ${#remote_files[@]} -eq 0 ]]; then
            backup_log_info "[remote] No ${t} backup archives found on remote — nothing to prune."
            continue
        fi

        # Always preserve at least the most recent backup, regardless of age.
        if [[ ${#remote_files[@]} -le 1 ]]; then
            backup_log_info "[remote] Only 1 ${t} backup on remote — preserving it regardless of age."
            continue
        fi

        local _deleted_remote=0
        local _file
        for _file in "${remote_files[@]}"; do
            local _age_days
            _age_days=$(_backup_filename_age_days "$_file")
            if [[ -z "$_age_days" ]]; then
                backup_log_warn "[remote] $(basename "$_file") has no filename timestamp — skipping remote deletion."
                continue
            fi
            if (( _age_days > retention_days )); then
                if [[ "$DRY_RUN" == "true" ]]; then
                    backup_log_info "[DRY RUN] Would delete remote: ${remote_path}/${_file} (${_age_days}d > ${retention_days}d)"
                    continue
                fi
                local _del_exit=0
                rclone deletefile "${rclone_config_arg[@]}" "${remote_path}/${_file}" \
                    --contimeout 15s --timeout 60s 2>/dev/null || _del_exit=$?
                if (( _del_exit != 0 )); then
                    log_warn "[rotate] Failed to delete remote file: ${remote_path}/${_file}" >&2
                    _prune_failed=true
                else
                    backup_log_info "[remote] Deleted: ${_file} (${_age_days}d > ${retention_days}d)"
                    (( ++_deleted_remote )) || true
                    # Remove associated sidecar files; ignore errors (may not exist).
                    local _ext
                    for _ext in .sha256 .sha256.hmac .meta; do
                        rclone deletefile "${rclone_config_arg[@]}" \
                            "${remote_path}/${_file}${_ext}" \
                            --contimeout 15s --timeout 60s 2>/dev/null || true
                    done
                fi
            fi
        done

        if (( _deleted_remote > 0 )); then
            backup_log_success "[remote] Pruned ${_deleted_remote} old ${t} backup(s) from ${remote_path}/"
        else
            backup_log_info "[remote] No old ${t} backups to prune on remote."
        fi
    done

    if [[ "$_prune_failed" == "true" ]]; then
        log_warn "[rotate] Some remote pruning steps encountered errors — check above for details." >&2
        return 1
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

    backup_log_info "Performing database backup..."

    if [[ "$DRY_RUN" == "true" ]]; then
        backup_log_info "[DRY RUN] Would backup DB → $target_dir/db_backup_$timestamp.sqlite3.age"
        return 0
    fi

    local db_file="$state_dir/data/db.sqlite3"
    [[ -f "$db_file" ]] || { log_error "Database not found: $db_file" >&2; return 1; }

    local snap="$shared_tmpdir/db.sqlite3"

    backup_log_info "Creating atomic DB snapshot (sqlite3 .backup)..."
    if ! create_db_snapshot_host "$state_dir" "$snap"; then
        backup_log_warn "Host sqlite3 snapshot failed — attempting offline fallback with WAL checkpoint"

        local vw_container_name
        vw_container_name="$(get_config_value "COMPOSE_SERVICE_NAME" "vaultwarden")"
        local container_was_running=false

        if docker compose ps --services --filter status=running 2>/dev/null \
                | grep -qx "$vw_container_name"; then
            container_was_running=true
            backup_log_warn "Stopping $vw_container_name before fallback copy..."
            docker compose stop "$vw_container_name" 2>/dev/null || true

            if ! wait_for_container_stopped "$vw_container_name" 30; then
                log_error "Cannot safely copy db.sqlite3: container did not reach stopped state." >&2
                log_error "Fix sqlite3 .backup or stop the container manually, then retry." >&2
                return 1
            fi
        fi

        local wal_result
        wal_result=$(sqlite3 "$db_file" "PRAGMA wal_checkpoint(TRUNCATE);" 2>&1) || {
            backup_log_warn "WAL checkpoint command failed — copy may be missing recent transactions"
            backup_log_warn "For guaranteed consistency, stop VaultWarden before backup or fix sqlite3 .backup"
        }
        if [[ -n "$wal_result" ]]; then
            if ! echo "$wal_result" | awk -F'|' '$2!=0 || $3!=0 {exit 1}'; then
                log_error "WAL checkpoint incomplete — unincorporated pages remain (result: $wal_result)" >&2
                log_error "Aborting fallback copy to avoid backing up an inconsistent database." >&2
                log_error "Stop VaultWarden fully, then retry, or fix sqlite3 .backup." >&2
                return 1
            fi
            backup_log_info "WAL checkpoint succeeded (result: $wal_result)"
        fi

        if command -v lsof >/dev/null 2>&1; then
            local open_procs
            open_procs=$(lsof "$db_file" 2>/dev/null | grep -vc "^COMMAND")
            if (( open_procs > 0 )); then
                log_error "lsof reports $open_procs process(es) still have $db_file open." >&2
                log_error "Cannot safely copy WAL database. Stop all processes first, then retry." >&2
                return 1
            fi
            backup_log_info "lsof check passed: no open handles on $db_file"
        else
            backup_log_warn "lsof not available — cannot verify file handles before WAL fallback copy"
        fi

        cp "$db_file" "$snap"

        if [[ "$container_was_running" == "true" ]]; then
            backup_log_info "Restarting $vw_container_name after fallback copy..."
            docker compose start "$vw_container_name" 2>/dev/null || \
                backup_log_warn "Failed to restart $vw_container_name — restart manually"
        fi

        if [[ ! -s "$snap" ]]; then
            log_error "Fallback snapshot copy failed or produced empty file" >&2
            return 1
        fi
    fi

    verify_sqlite "$snap" || return 1

    backup_log_info "Encrypting DB snapshot..."
    local enc="$target_dir/db_backup_$timestamp.sqlite3.age"
    local enc_tmp="${enc}.tmp"
    if ! age -r "$age_pub_key" -o "$enc_tmp" "$snap" 2>/dev/null; then
        log_error "Encryption failed (check disk space: df -h $(dirname "$enc"); verify Age key: make key-health)" >&2
        rm -f "$enc_tmp"
        return 1
    fi
    mv "$enc_tmp" "$enc"
    secure_file "$enc" 600

    rm -f "$snap" 2>/dev/null || true

    write_file_integrity "$enc" || {
        log_error "Failed to write backup integrity sidecars for: $enc" >&2
        rm -f "$enc" "${enc}.sha256" "${enc}.sha256.hmac"
        return 1
    }

    [[ -s "$enc" ]] || { log_error "Encrypted output is empty" >&2; rm -f "$enc" "${enc}.sha256" "${enc}.sha256.hmac"; return 1; }

    local orig_size
    orig_size=$(stat -c%s "$db_file" 2>/dev/null || stat -f%z "$db_file" 2>/dev/null || echo 0)
    if ! create_backup_metadata "$enc" "db" \
            "$(printf 'original_size=%s\narchive_format=relative\nversion=2' "$orig_size")"; then
        log_error "Failed to write backup metadata: ${enc}.meta" >&2
        return 1
    fi

    backup_log_info "DB backup: $(basename "$enc")"
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

    backup_log_info "Performing ${backup_label} backup (relative-path archive)..."

    if [[ "$DRY_RUN" == "true" ]]; then
        backup_log_info "[DRY RUN] Would create ${backup_label} backup → $target_dir/${backup_label}_backup_$timestamp.tar.zst.age"
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
        backup_log_info "Creating atomic DB snapshot (sqlite3 .backup)..."
        if create_db_snapshot_host "$state_dir" "$snap_db" 2>/dev/null; then
            db_snapshot_ok=true
        else
            backup_log_warn "Host sqlite3 snapshot failed — will use live DB file in archive"
        fi
    fi

    backup_log_info "Archiving state (relative paths, safe for staged restore)..."

    # Canonical backup exclusion list — single source of truth.
    # Keep in sync with print_backup_manifest() below and docs/BACKUP-RESTORE.md.
    local -a _BACKUP_EXCLUDES=(
        ".git"
        "backups"
        "logs"
        ".rate-limit"
        "secrets"
        "*.sock"
        "*.lock"
        "*.tmp"
        "*.age.tmp"
        ".pre-restore-*"
        "*/.pre-restore-*"
    )
    local -a tar_excludes=()
    local excl
    for excl in "${_BACKUP_EXCLUDES[@]}"; do
        case "$excl" in
            \*.*)
                tar_excludes+=("--exclude=${excl}")
                ;;
            *)
                tar_excludes+=("--exclude=${SCRIPT_DIR#/}/${excl}")
                # Also exclude the same paths under state_dir where applicable
                [[ "$excl" == "backups" || "$excl" == "logs" ]] && \
                    tar_excludes+=("--exclude=${state_dir#/}/${excl}")
                ;;
        esac
    done
    tar_excludes+=(
        "--exclude=${state_dir#/}/.pre-restore-*"
        "--exclude=${state_dir#/}/*/.pre-restore-*"
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

    local -a tar_cmd_args=(
        --use-compress-program='zstd --no-progress -T0 -3'
        -cf "$temp_tar"
        -C /
        "${tar_excludes[@]}"
        "${tar_sources[@]}"
    )
    if [[ "$db_snapshot_ok" == "true" ]]; then
        if [[ ! -f "$snap_db" ]]; then
            backup_log_warn "DB snapshot not found at: $snap_db — falling back to live DB"
            db_snapshot_ok=false
        else
            backup_log_info "Including clean DB snapshot in initial archive pass..."
            tar_cmd_args+=(-C "$snap_dir" "${state_dir#/}/data/db.sqlite3")
        fi
    fi

    local tar_exit=0
    tar "${tar_cmd_args[@]}" 2>/dev/null || tar_exit=$?

    if (( tar_exit == 1 )); then
        log_warn "perform_full_backup: tar reported exit 1 (file changed during archival)." \
                 "This is normally benign — DB snapshot was used instead of live db.sqlite3."
    elif (( tar_exit > 1 )); then
        log_error "tar failed with exit code $tar_exit" >&2
        return 1
    fi

    if [[ ! -s "$temp_tar" ]]; then
        log_error "tar produced an empty archive — aborting backup" >&2
        return 1
    fi

    _validate_full_archive_payload "$temp_tar" "$state_dir" "$SCRIPT_DIR" "$backup_label" || return 1

    backup_log_info "Encrypting ${backup_label} archive..."
    local enc="$target_dir/${backup_label}_backup_$timestamp.tar.zst.age"
    local enc_tmp="${enc}.tmp"

    if ! age -r "$age_pub_key" -o "$enc_tmp" "$temp_tar" 2>/dev/null; then
        log_error "Encryption failed (check disk space: df -h $(dirname "$enc"); verify Age key: make key-health)" >&2
        rm -f "$enc_tmp"
        return 1
    fi
    mv "$enc_tmp" "$enc"
    secure_file "$enc" 600

    write_file_integrity "$enc" || {
        log_error "Failed to write backup integrity sidecars for: $enc" >&2
        rm -f "$enc" "${enc}.sha256" "${enc}.sha256.hmac"
        return 1
    }

    [[ -s "$enc" ]] || { log_error "Encrypted output is empty" >&2; rm -f "$enc" "${enc}.sha256" "${enc}.sha256.hmac"; return 1; }

    local data_volume_mount data_volume_device state_dir_is_mountpoint storage_mode
    data_volume_mount="$(get_config_value "DATA_VOLUME_MOUNT" "")"
    data_volume_device="$(get_config_value "DATA_VOLUME_DEVICE" "")"
    state_dir_is_mountpoint=false; mountpoint -q "$state_dir" 2>/dev/null && state_dir_is_mountpoint=true
    storage_mode="$(_backup_storage_mode "$state_dir" "$data_volume_mount" "$data_volume_device")"
    if ! create_backup_metadata "$enc" "$backup_label" \
            "$(printf 'project_state_dir=%s\nstorage_mode=%s\ndata_volume_mount=%s\ndata_volume_device=%s\nstate_dir_is_mountpoint=%s\nrepo_root=%s\narchive_format=relative\nversion=2' "$state_dir" "$storage_mode" "$data_volume_mount" "$data_volume_device" "$state_dir_is_mountpoint" "$SCRIPT_DIR")"; then
        log_error "Failed to write backup metadata: ${enc}.meta" >&2
        return 1
    fi

    backup_log_info "${backup_label_title} backup: $(basename "$enc")"
    echo "$enc"
}

# print_backup_manifest — Show what is included/excluded in a full/emergency backup.
# Called by `make backup-manifest`.
print_backup_manifest() {
    local -a _BACKUP_EXCLUDES=(
        ".git"
        "backups"
        "logs"
        ".rate-limit"
        "secrets"
        "*.sock"
        "*.lock"
        "*.tmp"
        "*.age.tmp"
        ".pre-restore-*"
        "*/.pre-restore-*"
    )
    echo "=== Full Backup Contents ==="
    echo "Included: Project root + state directory"
    echo "Excluded:"
    local excl
    for excl in "${_BACKUP_EXCLUDES[@]}"; do
        echo "  - $excl"
    done
}

_check_backup_deps() {
    local -a hard=(age tar)
    local -a soft=(age-keygen sqlite3 zstd rclone)
    local missing_hard=() missing_soft=()
    for c in "${hard[@]}"; do command -v "$c" >/dev/null 2>&1 || missing_hard+=("$c"); done
    for c in "${soft[@]}"; do command -v "$c" >/dev/null 2>&1 || missing_soft+=("$c"); done
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        missing_hard+=(sha256sum)
    fi
    if [[ ${#missing_hard[@]} -gt 0 ]]; then
        log_error "backup.sh: required tools missing: ${missing_hard[*]}"
        log_error "  Install with: apt-get install -y age coreutils tar"
        exit 1
    fi
    if [[ ${#missing_soft[@]} -gt 0 ]]; then
        log_warn "backup.sh: optional tools missing (some features disabled): ${missing_soft[*]}"
        if [[ " ${missing_soft[*]} " =~ " age-keygen " ]]; then
            log_warn "  age-keygen is missing — post-restore key rotation in restore.sh will fail."
            log_warn "  It is part of the 'age' package: apt-get install -y age"
        fi
    fi
}


_log_backup_size() {
    local backup_file="$1"
    if [[ ! -f "$backup_file" ]]; then
        backup_log_warn "Backup file not found for size check: $backup_file"
        return 0
    fi
    local size_bytes size_human
    size_bytes=$(stat -c '%s' "$backup_file" 2>/dev/null || stat -f '%z' "$backup_file" 2>/dev/null || echo 0)
    size_human="$(_format_bytes_human "$size_bytes")"
    backup_log_success "Backup created: $(basename "$backup_file") (${size_human})"
    if [[ "$size_bytes" =~ ^[0-9]+$ ]] && (( size_bytes < 4096 )); then
        backup_log_warn "Backup file is unusually small (${size_human}) — verify integrity: sudo ./backup.sh verify"
    fi
}

main() {
    trap cleanup EXIT HUP INT TERM ERR

    if [[ "$_SUBCMD" != "list" ]]; then
        backup_require_root
    fi

    if [[ "$LIST_ONLY" == "true" ]]; then
        load_env_file 2>/dev/null || true
        local list_base_dir
        list_base_dir="$(get_config_value "BACKUP_DIR" "$(_default_backup_dir)")"
        if [[ -d "$list_base_dir" && ! -r "$list_base_dir" ]]; then
            log_error "Backup archive directory is not readable by $(id -un): $list_base_dir"
            exit 1
        fi
        list_backups "$list_base_dir" "$JSON_OUTPUT" || true
        exit 0
    fi

    if [[ "$_SUBCMD" == "verify" ]]; then
        require_root "$@"
        auto_fix_critical_permissions "$PROJECT_ROOT"
        _check_backup_deps

        local old_umask
        old_umask=$(umask)
        umask 077
        TMPDIR_BACKUP="$(mktemp -d -p /dev/shm 2>/dev/null || mktemp -d -t vw_verify.XXXXXXXXXX)" || {
            log_error "Failed to create secure temporary directory"
            exit 1
        }
        umask "$old_umask"

        log_header "VaultWarden-OCI Backup Verify"
        load_env_file || { log_error "Failed to load .env"; exit 1; }
        auto_fix_critical_permissions "$PROJECT_ROOT"
        require_project_state_ready || exit 1
        _load_integrity_hmac_key || exit 1

        local age_key_file
        age_key_file=$(_resolve_age_key) || {
            log_error "Age key file not found at: ${age_key_file:-/etc/vaultwarden/age-key.txt}"
            log_error "Set SOPS_AGE_KEY_FILE in .env, or place the key at /etc/vaultwarden/age-key.txt"
            exit 1
        }

        local base_dir
        base_dir="$(get_config_value "BACKUP_DIR" "$(_default_backup_dir)")"

        local search_types=()
        if [[ "$BACKUP_TYPE" != "auto" ]]; then
            search_types=("$BACKUP_TYPE")
        else
            search_types=(db full emergency)
        fi

        local latest_file="" latest_mtime=0
        for t in "${search_types[@]}"; do
            local type_dir="$base_dir/$t"
            [[ -d "$type_dir" ]] || continue
            while IFS= read -r -d '' f; do
                local f_mtime
                f_mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
                if (( f_mtime > latest_mtime )); then
                    latest_mtime=$f_mtime
                    latest_file="$f"
                fi
            done < <(find "$type_dir" -maxdepth 1 -name "*.age" -type f -print0 2>/dev/null)
        done

        if [[ -z "$latest_file" ]]; then
            log_error "No backups found to verify."
            exit 1
        fi

        local enc_type
        enc_type="$(basename "$(dirname "$latest_file")")"

        backup_log_info "Target: $(basename "$latest_file")  [type: $enc_type]"

        if ! verify_backup_full "$latest_file" "$enc_type" "$TMPDIR_BACKUP"; then
            log_error "Verification FAILED: $(basename "$latest_file")"
            exit 1
        fi

        backup_log_success "Verification passed: $(basename "$latest_file")"
        exit 0
    fi

    if [[ "$_SUBCMD" == "sync" ]]; then
        require_root "$@"
        auto_fix_critical_permissions "$PROJECT_ROOT"
        local sync_dry_label=""
        [[ "$DRY_RUN" == "true" ]] && sync_dry_label=" [DRY RUN]"
        log_header "VaultWarden-OCI Rclone Backup Copy${sync_dry_label}"
        load_env_file || { log_error "Failed to load .env"; exit 1; }
        auto_fix_critical_permissions "$PROJECT_ROOT"

        local old_umask
        old_umask=$(umask)
        umask 077
        TMPDIR_BACKUP="$(mktemp -d -p /dev/shm 2>/dev/null || mktemp -d -t vw_sync.XXXXXXXXXX)" || {
            log_error "Failed to create secure temporary directory"
            exit 1
        }
        umask "$old_umask"

        sync_all_backups_to_rclone || exit 1
        exit 0
    fi

    if [[ "$_SUBCMD" == "rotate" ]]; then
        require_root "$@"
        auto_fix_critical_permissions "$PROJECT_ROOT"

        local rotate_dry_label=""
        [[ "$DRY_RUN" == "true" ]] && rotate_dry_label=" [DRY RUN]"
        log_header "VaultWarden-OCI Backup Rotation${rotate_dry_label}"
        load_env_file || { log_error "Failed to load .env"; exit 1; }
        auto_fix_critical_permissions "$PROJECT_ROOT"

        local base_dir
        base_dir="$(get_config_value "BACKUP_DIR" "$(_default_backup_dir)")"

        local rotate_failed=false
        for t in db full emergency; do
            local type_dir="$base_dir/$t"
            [[ -d "$type_dir" ]] || continue
            local retention_days
            retention_days=$(_retention_days_for_type "$t") || exit 1

            if [[ "$DRY_RUN" == "true" ]]; then
                local would_prune=0
                while IFS= read -r -d '' f; do
                    backup_log_info "[DRY RUN] Would remove: $(basename "$f") (and sidecars)"
                    (( ++would_prune )) || true
                done < <(find "$type_dir" -maxdepth 1 -name "*.age" -type f \
                             -mtime +"$retention_days" -print0 2>/dev/null)
                if (( would_prune == 0 )); then
                    backup_log_info "[DRY RUN] No $t backups older than $retention_days days — nothing to prune."
                fi
            else
                cleanup_old_backups "$type_dir" "$t" "$retention_days" || rotate_failed=true
            fi
        done

        if [[ "$rotate_failed" == "true" ]]; then
            log_error "One or more rotation steps encountered errors — check above for details."
            exit 1
        fi

        # Prune remote backups to match the local retention policy.
        _prune_remote_backups || {
            log_warn "[rotate] Remote retention pruning reported errors — local rotation was successful."
        }

        local rotate_suffix=""
        [[ "$DRY_RUN" == "true" ]] && rotate_suffix=" (dry run)"
        backup_log_success "Rotation complete${rotate_suffix}."
        exit 0
    fi


    _check_backup_deps

    LOCK_FILE="/run/lock/vaultwarden-backup.lock"
    local OPS_LOCK="/run/lock/vaultwarden-operations.lock"

    if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" ]]; then
        if [[ "$SKIP_OPS_LOCK" != "true" ]]; then
            _ensure_lock_file "$OPS_LOCK"
            exec {OPS_LOCK_FD}>"$OPS_LOCK"
            if ! flock -n "$OPS_LOCK_FD"; then
                log_error "Another operation (maintenance/restore) is already running. Aborting."
                log_info  "Wait for it to finish or use --force to override."
                exit 1
            fi
        fi

        _ensure_lock_file "$LOCK_FILE"
        exec {LOCK_FD}>"$LOCK_FILE"
        if ! flock -n "$LOCK_FD"; then
            log_error "Another backup is already running (could not acquire lock)."
            log_info  "Wait for it to finish or use --force if you are certain it is stuck."
            log_error "If the lock is stale, remove: ${LOCK_FILE}"
            exit 1
        fi
    fi

    local old_umask
    old_umask=$(umask)
    umask 077
    TMPDIR_BACKUP="$(mktemp -d -p /dev/shm 2>/dev/null || mktemp -d -t vw_backup.XXXXXXXXXX)" || {
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
    auto_fix_critical_permissions "$PROJECT_ROOT"
    require_project_state_ready || exit 1
    _load_integrity_hmac_key || exit 1

    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")

    local age_key_file
    age_key_file=$(_resolve_age_key) || {
        log_error "Age key file not found at: ${age_key_file:-/etc/vaultwarden/age-key.txt}"
        log_error "Set SOPS_AGE_KEY_FILE in .env, or place the key at /etc/vaultwarden/age-key.txt"
        exit 1
    }

    if [[ "$DRY_RUN" != "true" ]]; then
        SOPS_AGE_KEY_FILE="$age_key_file" check_age_key_health || {
            log_error "Age key health check failed — aborting backup to avoid encrypting with a bad key."
            log_error "Run './maintenance.sh health --comprehensive' for diagnostics."
            exit 1
        }
    fi

    local age_pub_key
    age_pub_key=$(get_age_public_key "$age_key_file") || {
        log_error "Could not read Age public key from $age_key_file"
        exit 1
    }

    local actual_type="$BACKUP_TYPE"
    if [[ "$BACKUP_TYPE" == "auto" ]]; then
        actual_type=$(auto_determine_backup_type)
        backup_log_info "Auto-selected backup type: $actual_type"
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

    if [[ "$backup_success" == "true" ]]; then
        [[ "$backup_file" == *.age && -f "$backup_file" ]] || {
            log_error "backup_file is invalid or missing: ${backup_file:-empty}"
            exit 1
        }
    fi

    if [[ "$backup_success" == "true" && "$DRY_RUN" == "false" ]]; then

        local verify_failed=false
        local rclone_failed=false

        if [[ "$FULL_VERIFY" == "true" ]]; then
            if ! verify_backup_full "$backup_file" "$actual_type" "$TMPDIR_BACKUP"; then
                log_error "Backup verification failed — discarding corrupt archive."
                rm -f "$backup_file" "${backup_file}.meta" "${backup_file}.sha256" "${backup_file}.sha256.hmac"
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
            local _sync_rc=0
            sync_to_rclone "$backup_file" "$actual_type" || _sync_rc=$?
            if (( _sync_rc == 2 )); then
                log_warn "Offsite sync completed with partial sidecar failures — primary backup was delivered."
            elif (( _sync_rc != 0 )); then
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
                exit 2
            fi
        fi

        _log_backup_size "$backup_file"

        local retention_days
        retention_days=$(_retention_days_for_type "$actual_type") || exit 1
        backup_log_info "Cleaning up old backups (retention: $retention_days days)..."
        cleanup_old_backups "$backup_dir" "$actual_type" "$retention_days" || \
            backup_log_warn "Failed to clean up some old backups"

        # Prune remote backups to mirror local retention policy
        if [[ "$RCLONE_SYNC" == "true" && "$rclone_failed" == "false" ]]; then
            _prune_remote_backups || \
                backup_log_warn "Failed to prune some remote backups"
        fi

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
                backup_log_warn "Email notification failed (backup still succeeded)"
        fi

        backup_log_success "Backup completed successfully"
        exit 0
    elif [[ "$DRY_RUN" == "true" ]]; then
        backup_log_success "Dry run completed"
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
