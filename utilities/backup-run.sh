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
source "$SCRIPT_DIR/lib/operations.sh"
source "$SCRIPT_DIR/lib/email.sh"
DOCKER_PROJECT_LABEL="${DOCKER_PROJECT_LABEL:-label=com.docker.compose.project=vaultwarden-oci}"
source "$SCRIPT_DIR/lib/docker.sh"
source "$SCRIPT_DIR/lib/backup-utils.sh"
source "$SCRIPT_DIR/lib/crypto.sh"
source "$SCRIPT_DIR/lib/storage.sh"  # provides require_project_state_ready()

BACKUP_TYPE="auto"    # Backup mode: auto, db, full, or emergency.
DRY_RUN=false
KEEP_DAYS=""
QUIET=false
FORCE=false
EMAIL_NOTIFY=false   # Set by --email; send_notification_email() runs on completion.
LIST_ONLY=false      # Set by the list subcommand; prints backups and exits without root.
RCLONE_SYNC=false    # Set by --rclone; syncs the encrypted backup after creation.
FULL_VERIFY=false    # Set by --full-verification; decrypts and integrity-checks before sync.
JSON_OUTPUT=false

show_help() {
    cat << 'EOF'
VaultWarden-OCI Backup Script

USAGE:
    sudo ./backup.sh <subcommand> [options]
    ./backup.sh list                                    # No root required

SUBCOMMANDS:
    run [TYPE]        Create a backup  (TYPE: auto | db | full | emergency)
                      db: encrypted SQLite snapshot only; storage-layout independent
                      full: normal DR backup; excludes /etc/vaultwarden/age-key.txt
                      emergency: clone-grade sealed capsule; can include /etc/vaultwarden
                      key/config material and must use an independent emergency
                      passphrase or EMERGENCY_BACKUP_AGE_RECIPIENT
    list [--json]     List existing backups (no root required; JSON optional)
    verify [--type TYPE] [--quiet]
                      Verify the most recent backup's integrity
    rotate            Apply retention policy and prune old backups
    sync               Copy all retained local backups to rclone by type
    manifest           Print the exact full/emergency archive exclusions

RUN OPTIONS (used after 'run'):
    --keep N                 Override configured retention for this run
    --quiet                  Suppress non-error output
    --force                  Compatibility flag; does not bypass operation guards
    --email                  Send email notification on completion/failure
    --rclone                 Sync encrypted backup to rclone remote after creation
    --full-verification      End-to-end decrypt + integrity check before sync (fatal on failure)
    --skip-full-verification Fast checksum only — explicit default
    --dry-run                Show what would be done without executing

SYNC / ROTATE OPTIONS:
    --keep N                 Override configured retention for every backup type
    --quiet                  Suppress non-error output
    --dry-run                Preview copy or pruning operations

VERIFY OPTIONS:
    --type TYPE              Backup type to verify: auto | db | full | emergency
    --quiet                  Suppress non-error output

GLOBAL SUBCOMMAND:
    help                     Show this help

GLOBAL OPTIONS:
    --help, -h               Show this help and exit
    --version, -V            Print the VaultWarden-OCI version and exit

EXAMPLES:
    sudo ./backup.sh run                # Auto-mode backup (db or full based on schedule)
    sudo ./backup.sh run db             # Database-only backup
    sudo ./backup.sh run full           # Full state backup
    sudo ./backup.sh run emergency      # Clone-grade sealed capsule; prompts for emergency passphrase unless EMERGENCY_BACKUP_AGE_RECIPIENT is set
    sudo ./backup.sh run db --keep 30             # Keep 30 days of backups
    ./backup.sh list                              # List existing backups (no sudo)
    ./backup.sh list --json                       # Machine-readable backup inventory
    sudo ./backup.sh verify                       # Verify the latest backup
    sudo ./backup.sh verify --type db --quiet     # Verify latest DB backup quietly
    sudo ./backup.sh rotate --keep 30             # Prune backups older than 30 days
    sudo ./backup.sh sync                         # Upload db/full/emergency backups
EOF
}

_require_cli_value() {
    local opt="$1" value="${2-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        log_error "$opt requires a value."
        show_help
        exit 2
    fi
}

_SUBCMD=""
if [[ $# -eq 0 ]]; then
    show_help; exit 0
fi

case "$1" in
    run|list|verify|rotate|sync|manifest)
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
        log_error "Valid subcommands: run [TYPE] | list | verify | rotate | sync | manifest"
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
                --keep)                   _require_cli_value "$1" "${2-}"; KEEP_DAYS="$2"; shift 2 ;;
                --quiet)                  QUIET=true;        shift ;;
                --force)                  FORCE=true;        shift ;;
                --email)                  EMAIL_NOTIFY=true; shift ;;
                --rclone)                 RCLONE_SYNC=true;  shift ;;
                --full-verification)      FULL_VERIFY=true;  shift ;;
                --skip-full-verification) FULL_VERIFY=false; shift ;;
                --dry-run)                DRY_RUN=true;      shift ;;
                --help|-h)                show_help; exit 0 ;;
                --version|-V)             print_project_version "VaultWarden-OCI" "$SCRIPT_DIR"; exit 0 ;;
                *) log_error "Unknown option for run: $1"; show_help; exit 2 ;;
            esac
        done
        ;;
    list)
        LIST_ONLY=true
        while [[ $# -gt 0 ]]; do
            case $1 in
                --json) JSON_OUTPUT=true; shift ;;
                --help|-h) show_help; exit 0 ;;
                --version|-V) print_project_version "VaultWarden-OCI" "$SCRIPT_DIR"; exit 0 ;;
                *) log_error "Unknown option for list: $1"; show_help; exit 2 ;;
            esac
        done
        ;;
    verify)
        FULL_VERIFY=true
        while [[ $# -gt 0 ]]; do
            case $1 in
                --type) _require_cli_value "$1" "${2-}"; BACKUP_TYPE="$2"; shift 2 ;;
                --quiet) QUIET=true; shift ;;
                --help|-h) show_help; exit 0 ;;
                --version|-V) print_project_version "VaultWarden-OCI" "$SCRIPT_DIR"; exit 0 ;;
                *) log_error "Unknown option for verify: $1"; show_help; exit 2 ;;
            esac
        done
        ;;
    rotate)
        LIST_ONLY=false
        while [[ $# -gt 0 ]]; do
            case $1 in
                --keep)  _require_cli_value "$1" "${2-}"; KEEP_DAYS="$2"; shift 2 ;;
                --quiet) QUIET=true;     shift ;;
                --dry-run) DRY_RUN=true; shift ;;
                --help|-h) show_help; exit 0 ;;
                --version|-V) print_project_version "VaultWarden-OCI" "$SCRIPT_DIR"; exit 0 ;;
                *) log_error "Unknown option for rotate: $1"; show_help; exit 2 ;;
            esac
        done
        ;;
    sync)
        while [[ $# -gt 0 ]]; do
            case $1 in
                --keep)  _require_cli_value "$1" "${2-}"; KEEP_DAYS="$2"; shift 2 ;;
                --quiet) QUIET=true; shift ;;
                --dry-run) DRY_RUN=true; shift ;;
                --help|-h) show_help; exit 0 ;;
                --version|-V) print_project_version "VaultWarden-OCI" "$SCRIPT_DIR"; exit 0 ;;
                *) log_error "Unknown option for sync: $1"; show_help; exit 2 ;;
            esac
        done
        ;;
    manifest)
        if [[ $# -gt 0 ]]; then
            log_error "manifest does not accept arguments."
            show_help
            exit 2
        fi
        ;;
esac

if [[ "$_SUBCMD" == "run" || "$_SUBCMD" == "rotate" || "$_SUBCMD" == "sync" ]]; then
    if [[ -n "$KEEP_DAYS" ]] && \
       { [[ ! "$KEEP_DAYS" =~ ^[0-9]+$ ]] || (( 10#$KEEP_DAYS < 1 )); }; then
        log_error "Invalid --keep value: '${KEEP_DAYS}' — must be a positive integer (e.g. 14)"
        exit 2
    fi
fi

case "$BACKUP_TYPE" in
    auto|db|full|emergency) ;;
    *) log_error "Invalid backup type: ${BACKUP_TYPE} (expected auto, db, full, or emergency)"; exit 2 ;;
esac

backup_log_info()    { [[ "$QUIET" == "true" ]] || log_info "$*" >&2;    }
backup_log_success() { [[ "$QUIET" == "true" ]] || log_success "$*" >&2; }
backup_log_warn()    { [[ "$QUIET" == "true" ]] || log_warn "$*" >&2;    }
backup_require_root() {
    if (( EUID != 0 )); then
        log_error "backup ${_SUBCMD} requires root. Run: sudo ./backup.sh ${_SUBCMD}"
        exit 1
    fi
}

CONTROL_WORKSPACE=""
CONTROL_WORKSPACE_ID=""
PAYLOAD_WORKSPACE=""
PAYLOAD_WORKSPACE_ID=""
PENDING_BACKUP_CANDIDATE=""
PENDING_BACKUP_FINAL=""

_workspace_identity() {
    stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null
}

_remove_owned_workspace() {
    local path="$1" expected_id="$2" label="$3" current_id=""
    [[ -n "$path" && -n "$expected_id" ]] || return 0
    if [[ -d "$path" && ! -L "$path" ]]; then
        current_id="$(_workspace_identity "$path" 2>/dev/null || true)"
    fi
    [[ "$current_id" == "$expected_id" ]] || {
        log_error "Refusing to clean unverified or replaced ${label} workspace: $path" >&2
        return 1
    }
    rm -rf -- "$path"
}

_create_owned_workspace() {
    local path_name="$1" id_name="$2" parent="$3" prefix="$4" fallback="${5:-false}"
    local path="" old_umask
    [[ -z "${!path_name:-}" && -z "${!id_name:-}" ]] || {
        log_error "Backup workspace output is already populated: ${!path_name:-unset}" >&2
        return 1
    }

    old_umask=$(umask); umask 077
    if [[ -d "$parent" && ! -L "$parent" ]]; then
        path="$(mktemp -d "${parent%/}/${prefix}.XXXXXXXXXX" 2>/dev/null || true)"
    fi
    [[ -n "$path" || "$fallback" != "true" ]] || path="$(mktemp -d -t "${prefix}.XXXXXXXXXX" 2>/dev/null || true)"
    umask "$old_umask"

    [[ -n "$path" && -d "$path" && ! -L "$path" ]] || {
        log_error "Failed to create secure backup workspace on: $parent" >&2
        return 1
    }
    chmod 0700 "$path" && printf -v "$id_name" '%s' "$(_workspace_identity "$path")" || {
        rm -rf -- "$path" 2>/dev/null || true
        return 1
    }
    printf -v "$path_name" '%s' "$path"
}

_cleanup_unpublished_backup() {
    [[ -n "$PENDING_BACKUP_CANDIDATE" ]] || return 0
    local candidate="$PENDING_BACKUP_CANDIDATE"
    _discard_backup_cohort "$candidate" 2>/dev/null || true
    if [[ -n "$PENDING_BACKUP_FINAL" && ! -e "$PENDING_BACKUP_FINAL" ]]; then
        rm -f -- "${PENDING_BACKUP_FINAL}.meta" "${PENDING_BACKUP_FINAL}.sha256" \
            "${PENDING_BACKUP_FINAL}.sha256.hmac" 2>/dev/null || true
    fi
    PENDING_BACKUP_CANDIDATE=""
    PENDING_BACKUP_FINAL=""
}

cleanup() {
    local rc="${1:-$?}"
    _db_snapshot_restart_if_needed
    _cleanup_unpublished_backup
    operation_release "$rc" 2>/dev/null || true
    _remove_owned_workspace "$PAYLOAD_WORKSPACE" "$PAYLOAD_WORKSPACE_ID" payload || true
    _remove_owned_workspace "$CONTROL_WORKSPACE" "$CONTROL_WORKSPACE_ID" control || true
    PAYLOAD_WORKSPACE=""; PAYLOAD_WORKSPACE_ID=""
    CONTROL_WORKSPACE=""; CONTROL_WORKSPACE_ID=""
    return "$rc"
}

_backup_signal_exit() {
    local rc="$1"
    trap - ERR EXIT; trap '' HUP INT TERM
    cleanup "$rc"
    exit "$rc"
}
_acquire_backup_guard() {
    [[ "$DRY_RUN" == "true" ]] && return 0
    operation_acquire \
        --id backup \
        --label "Backup" \
        --specific-lock /run/lock/vaultwarden-backup.lock \
        --non-interactive skip || exit $?
}


_resolve_age_key() {
    resolve_age_key_path
}

_default_backup_dir() { vw_default_backup_dir; }

get_backup_dir() {
    local type="$1" state_dir="${2:-}"
    local configured_base canonical_base expected_dir canonical_dir
    configured_base="$(get_config_value "BACKUP_DIR" "$(_default_backup_dir)")"
    if [[ "$type" == full || "$type" == emergency ]]; then
        [[ -n "$state_dir" ]] || {
            log_error "PROJECT_STATE_DIR is required to validate ${type} backup storage." >&2
            return 1
        }
        _require_safe_backup_source_layout \
            "$configured_base" "$SCRIPT_DIR" "$state_dir" canonical_base || return 1
    else
        canonical_base="$(realpath -m -- "$configured_base" 2>/dev/null)" || {
            log_error "Cannot canonicalize configured BACKUP_DIR: $configured_base" >&2
            return 1
        }
    fi
    expected_dir="$canonical_base/$type"
    canonical_dir="$(realpath -m -- "$expected_dir" 2>/dev/null)" || {
        log_error "Cannot canonicalize backup type directory: $expected_dir" >&2
        return 1
    }
    [[ "$canonical_dir" == "$canonical_base"/* ]] || {
        log_error "Backup type directory resolves outside configured BACKUP_DIR: $canonical_dir" >&2
        log_error "Configured BACKUP_DIR resolves to: $canonical_base" >&2
        return 1
    }
    [[ "$canonical_dir" == "$expected_dir" ]] || {
        log_error "Backup type directory must not be redirected: $expected_dir" >&2
        log_error "Resolved backup type directory: $canonical_dir" >&2
        return 1
    }
    ensure_dir "$canonical_dir" 750 "$(get_real_user)" || return 1
    printf '%s
' "$canonical_dir"
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

_archive_member_path() {
    local path="$1"
    path="$(realpath -m -- "$path" 2>/dev/null)" || return 1
    printf '%s\n' "${path#/}"
}

# Print the exact full/emergency tar exclusions, one archive-member pattern per line.
backup_archive_exclusions() {
    local project_root="$1" state_dir="$2" backup_base="$3" age_key_file="${4:-}"
    local project_member state_member state_parent_member state_parent_prefix state_basename backup_member age_key_member=""
    project_member="$(_archive_member_path "$project_root")"
    state_member="$(_archive_member_path "$state_dir")"
    state_parent_member="$(_archive_member_path "$(dirname "$state_dir")")"
    state_parent_prefix="${state_parent_member:+${state_parent_member}/}"
    state_basename="$(basename "$state_dir")"
    backup_member="$(_archive_member_path "$backup_base")"
    [[ -n "$age_key_file" ]] && age_key_member="$(_archive_member_path "$age_key_file")"

    {
        printf '%s\n' \
            "${project_member}/.git" \
            "${project_member}/backups" \
            "${project_member}/logs" \
            "${project_member}/.rate-limit" \
            "${project_member}/recovery-kit-*.txt" \
            "${project_member}/vaultwarden-recovery-kit-*.txt" \
            "${project_member}/vaultwarden-recovery-*.txt" \
            "${project_member}/vaultwarden-setup-credentials-*.txt" \
            "${project_member}/important-documents-*.zip" \
            "${project_member}/.vaultwarden-setup-credentials*" \
            "${project_member}/.vaultwarden-recovery-kit*" \
            "${project_member}/.pre-restore-*" \
            "${project_member}/*/.pre-restore-*" \
            "${project_member}/.env.pre-restore-*" \
            "${project_member}/secrets/keys/age-key.txt" \
            "${state_member}/backups" \
            "${state_member}/logs" \
            "${state_member}/data/db.sqlite3" \
            "${state_member}/data/db.sqlite3-wal" \
            "${state_member}/data/db.sqlite3-shm" \
            "${state_member}/secrets/keys/age-key.txt" \
            "${state_member}/.pre-restore-*" \
            "${state_member}/*/.pre-restore-*" \
            "${state_member}.pre-restore-*" \
            "${state_member}/.vaultwarden-restore-payload.*" \
            "${state_parent_prefix}.${state_basename}.restore-payload.*" \
            "${state_member}.restore-workspace.*" \
            "${state_member}.restore-staged.*" \
            "$backup_member" \
            "${backup_member}/.vaultwarden-backup.*" \
            "dev/shm/.vaultwarden-emergency.*" \
            "run/vaultwarden-oci/secrets" \
            "run/vaultwarden-oci/secrets/*" \
            "*.sock" "*.lock" "*.tmp" "*.age.tmp"
        if [[ -n "$age_key_member" ]] && {
            [[ "$age_key_member" == "$project_member"/* ]] ||
            [[ "$age_key_member" == "$state_member"/* ]];
        }; then
            printf '%s\n' "$age_key_member"
        fi
    } | awk 'NF && !seen[$0]++'
}

_require_safe_backup_source_layout() {
    local raw_backup_base="$1" raw_project_root="$2" raw_state_dir="$3"
    local backup_out_name="${4:-}" project_out_name="${5:-}" state_out_name="${6:-}"
    local resolved_backup resolved_project resolved_state resolved_source label index
    local -a labels=("project root" "project state directory")

    command -v realpath >/dev/null 2>&1 || {
        log_error "Cannot validate BACKUP_DIR path relationships: realpath is unavailable." >&2
        return 1
    }
    resolved_backup="$(realpath -m -- "$raw_backup_base" 2>/dev/null)" || {
        log_error "Cannot canonicalize configured BACKUP_DIR: $raw_backup_base" >&2
        return 1
    }
    resolved_project="$(realpath -m -- "$raw_project_root" 2>/dev/null)" || {
        log_error "Cannot canonicalize backup project root: $raw_project_root" >&2
        return 1
    }
    resolved_state="$(realpath -m -- "$raw_state_dir" 2>/dev/null)" || {
        log_error "Cannot canonicalize backup project state directory: $raw_state_dir" >&2
        return 1
    }

    local -a sources=("$resolved_project" "$resolved_state")
    for index in "${!sources[@]}"; do
        label="${labels[$index]}"
        resolved_source="${sources[$index]}"
        if [[ "$resolved_source" == "$resolved_backup" ||
              "$resolved_source" == "$resolved_backup"/* ]]; then
            log_error "Unsafe BACKUP_DIR layout: '$resolved_backup' is equal to or an ancestor of the ${label} '$resolved_source'." >&2
            log_error "Refusing to continue because the shared tar exclusion would omit the entire ${label}." >&2
            log_error "Choose BACKUP_DIR below an archive source (for example '${resolved_source}/backups') or on a separate path that is not its ancestor." >&2
            return 1
        fi
    done

    [[ -z "$backup_out_name" ]] || printf -v "$backup_out_name" '%s' "$resolved_backup"
    [[ -z "$project_out_name" ]] || printf -v "$project_out_name" '%s' "$resolved_project"
    [[ -z "$state_out_name" ]] || printf -v "$state_out_name" '%s' "$resolved_state"
}

_backup_estimated_source_mb() {
    local project_root="$1" state_dir="$2" backup_base="$3" payload_workspace="${4:-}"
    local state_parent state_basename
    state_parent="$(dirname "$state_dir")"
    state_parent="${state_parent%/}"
    state_basename="$(basename "$state_dir")"
    local -a roots=("$project_root")
    if [[ "$state_dir" != "$project_root" && "$state_dir" != "$project_root"/* ]]; then
        [[ "$project_root" == "$state_dir"/* ]] && roots=("$state_dir") || roots+=("$state_dir")
    fi
    local -a du_args=(-sm --apparent-size)
    local path
    for path in \
        "$backup_base" "$payload_workspace" "$project_root/.git" "$project_root/logs" \
        "$state_dir/backups" "$state_dir/logs" \
        "$state_dir/.vaultwarden-restore-payload.*" \
        "$state_parent/.${state_basename}.restore-payload.*" \
        "${state_dir}.restore-workspace.*" \
        "${state_dir}.restore-staged.*"; do
        [[ -n "$path" ]] && du_args+=("--exclude=$path")
    done
    du "${du_args[@]}" -- "${roots[@]}" 2>/dev/null | awk '{total += $1} END {print total + 0}'
}

_preflight_backup_payload_capacity() {
    local state_dir="$1" backup_base="$2" type="$3"
    local project_root="${4:-$SCRIPT_DIR}" payload_workspace="${5:-$PAYLOAD_WORKSPACE}"
    local target_dir="${6:-$backup_base}"
    local db_bytes db_mb source_mb required_mb
    db_bytes="$(_stat_file_size "$state_dir/data/db.sqlite3" 2>/dev/null || echo 0)"
    [[ "$db_bytes" =~ ^[0-9]+$ ]] || db_bytes=0
    db_mb=$(( (db_bytes + 1048575) / 1048576 ))

    if [[ "$type" == db ]]; then
        check_backup_disk_space "$backup_base" "$((db_mb * 2 + 16))" "database backup payload staging"
        return
    fi
    [[ "$type" == full || "$type" == emergency ]] || {
        log_error "Unknown backup type for capacity preflight: $type" >&2
        return 1
    }
    source_mb="$(_backup_estimated_source_mb "$project_root" "$state_dir" "$backup_base" "$payload_workspace")" || {
        log_error "Cannot estimate backup source size with GNU du." >&2
        return 1
    }
    [[ "$source_mb" =~ ^[0-9]+$ ]] || return 1

    if [[ "$type" == full ]]; then
        local payload_identity target_identity
        payload_identity="$(_workspace_identity "$payload_workspace" 2>/dev/null)" || {
            log_error "Cannot identify full backup payload filesystem: $payload_workspace" >&2
            return 1
        }
        target_identity="$(_workspace_identity "$target_dir" 2>/dev/null)" || {
            log_error "Cannot identify full backup target filesystem: $target_dir" >&2
            return 1
        }
        if [[ "${payload_identity%%:*}" == "${target_identity%%:*}" ]]; then
            required_mb=$((source_mb * 2 + db_mb * 3 + 64))
            check_backup_disk_space "$payload_workspace" "$required_mb" \
                "full backup archive, encryption, and payload staging" || return 1
        else
            check_backup_disk_space "$payload_workspace" "$((source_mb + db_mb * 2 + 32))" \
                "full backup archive and payload staging" || return 1
            check_backup_disk_space "$target_dir" "$((source_mb + db_mb + 32))" \
                "encrypted full backup output" || return 1
        fi
        return 0
    fi

    local shm_type etc_mb=0 file bytes
    shm_type="$(stat -f -c '%T' /dev/shm 2>/dev/null || true)"
    [[ "$shm_type" == tmpfs ]] || {
        log_error "Emergency backup requires tmpfs staging at /dev/shm; detected: ${shm_type:-unavailable}." >&2
        log_error "Refusing to place an unencrypted secret-bearing emergency archive on persistent disk." >&2
        return 1
    }
    for file in /etc/vaultwarden/age-key.txt /etc/vaultwarden/vaultwarden.env /etc/vaultwarden/rclone.conf; do
        [[ -f "$file" ]] || continue
        bytes="$(_stat_file_size "$file" 2>/dev/null || echo 0)"
        [[ "$bytes" =~ ^[0-9]+$ ]] && etc_mb=$((etc_mb + (bytes + 1048575) / 1048576))
    done
    check_backup_disk_space /dev/shm "$((source_mb + db_mb * 2 + etc_mb + 64))" \
        "secret-bearing emergency tmpfs payload staging" || {
        log_error "Emergency backup did not start. Increase /dev/shm or reduce the archive inputs." >&2
        return 1
    }
    check_backup_disk_space "$target_dir" "$((source_mb + db_mb + etc_mb + 32))" "encrypted emergency backup output"
}
_discard_backup_cohort() {
    local enc_file="$1"
    rm -f -- "$enc_file" "${enc_file}.meta" "${enc_file}.sha256" "${enc_file}.sha256.hmac"
}

_require_absent_backup_cohorts() {
    local archive suffix
    for archive in "$@"; do
        for suffix in "" .meta .sha256 .sha256.hmac; do
            [[ ! -e "${archive}${suffix}" && ! -L "${archive}${suffix}" ]] || {
                log_error "Backup cohort member already exists: ${archive}${suffix}" >&2
                return 1
            }
        done
    done
}

_validate_created_backup_cohort() {
    local archive="$1" expected_type="$2" file mode parsed suffix
    local -a files=()
    while IFS= read -r suffix; do
        files+=("${archive}${suffix}")
    done < <(backup_required_cohort_suffixes)
    if [[ "${REQUIRE_AUTHENTICATED_INTEGRITY:-false}" != "true" && -e "${archive}.sha256.hmac" ]]; then
        files+=("${archive}.sha256.hmac")
    fi
    for file in "${files[@]}"; do
        mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null || true)"
        [[ -f "$file" && ! -L "$file" && -s "$file" && "$mode" == 600 ]] || {
            log_error "Backup candidate member is invalid or not mode 600: $file" >&2
            return 1
        }
    done
    verify_file_integrity "$archive" || return 1
    parsed="$(awk -F= '
        $1=="backup_type"{t++;tv=$2} $1=="archive_format"{f++;fv=$2}
        $1=="version"{v++;vv=$2} $1=="encryption_mode"{m++;mv=$2}
        END{printf "%d|%s|%d|%s|%d|%s|%d|%s",t,tv,f,fv,v,vv,m,mv}' "${archive}.meta")"
    local tc type fc format vc version mc encryption
    IFS='|' read -r tc type fc format vc version mc encryption <<< "$parsed"
    [[ "$tc:$type:$fc:$format:$vc:$version:$mc" == "1:$expected_type:1:relative:1:2:1" ]] || {
        log_error "Backup metadata is incomplete or incompatible: ${archive}.meta" >&2
        return 1
    }
    if [[ "$expected_type" == emergency ]]; then
        _validate_emergency_restore_metadata "$archive"
    else
        [[ "$encryption" == age-recipient ]] || { log_error "Unsupported backup encryption mode: $encryption" >&2; return 1; }
    fi
}
_publish_backup_candidate() {
    local candidate="$1" final="$2" suffix
    [[ -f "$candidate" && -s "$candidate" ]] || { log_error "Backup candidate is missing: $candidate" >&2; return 1; }
    _require_absent_backup_cohorts "$final" || return 1
    PENDING_BACKUP_FINAL="$final"
    for suffix in .meta .sha256 .sha256.hmac; do
        [[ ! -e "${candidate}${suffix}" ]] || mv -- "${candidate}${suffix}" "${final}${suffix}" || return 1
    done
    mv -- "$candidate" "$final" || return 1
    PENDING_BACKUP_CANDIDATE=""
    PENDING_BACKUP_FINAL=""
}
_verify_encrypted_archive_stream() {
    local enc_file="$1" backup_type="$2" encryption_mode="$3" age_key_file="$4"
    [[ -n "$CONTROL_WORKSPACE" && -d "$CONTROL_WORKSPACE" ]] || {
        log_error "Archive verification control workspace is unavailable" >&2
        return 1
    }

    local inner_name="${enc_file%.candidate}" decompressor
    inner_name="${inner_name%.age}"
    case "$inner_name" in
        *.tar.zst|*.zst) decompressor='zstd -d -T0' ;;
        *.tar.bz2|*.bz2) decompressor='bzip2 -d' ;;
        *.tar.xz|*.xz)   decompressor='xz -d' ;;
        *.tar.gz|*.tgz)  decompressor='gzip -d' ;;
        *.tar.lz4|*.lz4) decompressor='lz4 -d' ;;
        *)
            log_error "Full verification cannot identify the archive format: $(basename "$inner_name")" >&2
            return 1
            ;;
    esac

    local -a age_cmd=(age -d)
    if [[ "$backup_type" == "emergency" && "$encryption_mode" == "age-passphrase" ]]; then
        :
    elif [[ "$backup_type" == "emergency" && "$encryption_mode" == "age-recipient" ]]; then
        local emergency_identity
        emergency_identity="$(get_config_value "EMERGENCY_BACKUP_AGE_IDENTITY_FILE" "${EMERGENCY_BACKUP_AGE_IDENTITY_FILE:-}")"
        [[ -n "$emergency_identity" && -r "$emergency_identity" ]] || {
            log_error "Full verification requires readable EMERGENCY_BACKUP_AGE_IDENTITY_FILE for this archive." >&2
            return 1
        }
        age_cmd+=(-i "$emergency_identity")
    else
        [[ -n "$age_key_file" && -r "$age_key_file" ]] || {
            log_error "Full verification requires a readable operational Age identity: ${age_key_file:-unset}" >&2
            return 1
        }
        age_cmd+=(-i "$age_key_file")
    fi
    age_cmd+=("$enc_file")

    local age_error="$CONTROL_WORKSPACE/archive-age.err"
    local tar_error="$CONTROL_WORKSPACE/archive-tar.err"
    : > "$age_error"
    : > "$tar_error"
    local -a pipeline_status=()
    set -o pipefail
    if "${age_cmd[@]}" 2>"$age_error" \
        | tar --use-compress-program="$decompressor" -tf - >/dev/null 2>"$tar_error"; then
        pipeline_status=("${PIPESTATUS[@]}")
    else
        pipeline_status=("${PIPESTATUS[@]}")
    fi

    local age_rc="${pipeline_status[0]:-125}" tar_rc="${pipeline_status[1]:-125}"
    if (( age_rc != 0 )); then
        log_error "Full verification FAILED: age decryption exited ${age_rc}." >&2
        [[ -s "$age_error" ]] && log_error "  age: $(head -c 2048 "$age_error")" >&2
    fi
    if (( tar_rc != 0 )); then
        log_error "Full verification FAILED: archive listing exited ${tar_rc}." >&2
        [[ -s "$tar_error" ]] && log_error "  archive: $(head -c 2048 "$tar_error")" >&2
    fi
    (( age_rc == 0 && tar_rc == 0 ))
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
  if [[ "$backup_label" == "full" ]] && printf '%s\n' "$members" | grep -Eq \
    '(^|/)(recovery-kit-[^/]*\.txt|vaultwarden-recovery-kit-[^/]*\.txt|vaultwarden-recovery-[^/]*\.txt|vaultwarden-setup-credentials-[^/]*\.txt|important-documents-[^/]*\.zip|\.vaultwarden-(setup-credentials|recovery-kit)[^/]*)$'; then
    log_error "Backup validation failed: full archive contains a setup/recovery artifact or staging file." >&2
    printf '%s\n' "$members" | grep -E \
      '(^|/)(recovery-kit-[^/]*\.txt|vaultwarden-recovery-kit-[^/]*\.txt|vaultwarden-recovery-[^/]*\.txt|vaultwarden-setup-credentials-[^/]*\.txt|important-documents-[^/]*\.zip|\.vaultwarden-(setup-credentials|recovery-kit)[^/]*)$' \
      | sed 's/^/  forbidden member: /' >&2
    rm -f "$temp_tar"
    return 1
  fi
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

_vaultwarden_container_running() {
    local service="$1"
    docker compose ps --services --filter status=running 2>/dev/null | grep -qx "$service"
}

DB_SNAPSHOT_RESTART_SERVICE=""
DB_SNAPSHOT_STOPPED_CONTAINER=false
DB_SNAPSHOT_RESTARTED=false
_db_snapshot_restart_if_needed() {
    if [[ "${DB_SNAPSHOT_STOPPED_CONTAINER:-false}" == "true" && "${DB_SNAPSHOT_RESTARTED:-false}" != "true" ]]; then
        DB_SNAPSHOT_RESTARTED=true
        backup_log_info "Restarting ${DB_SNAPSHOT_RESTART_SERVICE} after offline DB snapshot..."
        docker compose start "$DB_SNAPSHOT_RESTART_SERVICE" >/dev/null 2>&1 || \
            backup_log_warn "Failed to restart ${DB_SNAPSHOT_RESTART_SERVICE} — restart manually"
    fi
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

create_consistent_db_snapshot() {
    local state_dir="$1" dest="$2" mode_label="$3"
    local db_file="${state_dir}/data/db.sqlite3"
    DB_SNAPSHOT_METHOD=""
    [[ -f "$db_file" ]] || { log_error "Database not found: $db_file" >&2; return 1; }
    mkdir -p "$(dirname "$dest")"
    rm -f "$dest" 2>/dev/null || true

    backup_log_info "Creating ${mode_label} DB snapshot with SQLite Online Backup API..."
    if create_db_snapshot_host "$state_dir" "$dest" 2>/dev/null && verify_sqlite "$dest"; then
        DB_SNAPSHOT_METHOD="sqlite-online-backup"
        backup_log_info "DB snapshot method: ${DB_SNAPSHOT_METHOD}"
        return 0
    fi

    backup_log_warn "SQLite Online Backup API failed — attempting safe offline fallback"
    rm -f "$dest" 2>/dev/null || true
    local vw_container_name
    vw_container_name="$(get_config_value "COMPOSE_SERVICE_NAME" "vaultwarden")"
    DB_SNAPSHOT_RESTART_SERVICE="$vw_container_name"
    DB_SNAPSHOT_STOPPED_CONTAINER=false
    DB_SNAPSHOT_RESTARTED=false

    if _vaultwarden_container_running "$vw_container_name"; then
        DB_SNAPSHOT_STOPPED_CONTAINER=true
        backup_log_warn "Stopping $vw_container_name before offline DB snapshot..."
        docker compose stop "$vw_container_name" >/dev/null || true
        if ! wait_for_container_stopped "$vw_container_name" 30; then
            log_error "Cannot safely copy db.sqlite3: container did not reach stopped state." >&2
            _db_snapshot_restart_if_needed
            return 1
        fi
    fi

    local wal_result
    wal_result=$(sqlite3 "$db_file" "PRAGMA wal_checkpoint(TRUNCATE);" 2>&1) || {
        log_error "WAL checkpoint failed; refusing to produce an inconsistent DB snapshot: $wal_result" >&2
        _db_snapshot_restart_if_needed
        return 1
    }
    if [[ -n "$wal_result" ]] && ! awk -F'|' '$2!=0 || $3!=0 {exit 1}' <<<"$wal_result"; then
        log_error "WAL checkpoint incomplete — unincorporated pages remain (result: $wal_result)" >&2
        _db_snapshot_restart_if_needed
        return 1
    fi
    cp -f "$db_file" "$dest"
    [[ -s "$dest" ]] || { log_error "Offline DB snapshot copy is empty or missing" >&2; _db_snapshot_restart_if_needed; return 1; }
    verify_sqlite "$dest" || { _db_snapshot_restart_if_needed; return 1; }
    DB_SNAPSHOT_METHOD="offline-checkpoint-copy"
    backup_log_info "DB snapshot method: ${DB_SNAPSHOT_METHOD}"
    _db_snapshot_restart_if_needed
    return 0
}

_validate_emergency_restore_metadata() {
    local archive_or_meta="$1"
    local mode_out_name="${2:-}"
    local meta_file="$archive_or_meta"
    [[ "$meta_file" == *.meta ]] || meta_file="${archive_or_meta}.meta"

    if [[ ! -e "$meta_file" ]]; then
        log_error "[backup] Emergency restore metadata is missing: $(basename "$meta_file")." >&2
        return 1
    fi
    if [[ ! -f "$meta_file" ]]; then
        log_error "[backup] Emergency restore metadata is not a regular file: $meta_file" >&2
        return 1
    fi
    if [[ ! -s "$meta_file" ]]; then
        log_error "[backup] Emergency restore metadata is empty: $(basename "$meta_file")." >&2
        return 1
    fi

    local mode_count mode
    mode_count="$(awk -F= '$1=="encryption_mode"{count++} END{print count+0}' "$meta_file" 2>/dev/null)" || {
        log_error "[backup] Emergency restore metadata could not be read: $meta_file" >&2
        return 1
    }
    if [[ "$mode_count" == "0" ]]; then
        log_error "[backup] Emergency restore metadata is missing encryption_mode: $(basename "$meta_file")." >&2
        return 1
    fi
    if [[ "$mode_count" != "1" ]]; then
        log_error "[backup] Emergency restore metadata has multiple encryption_mode entries: $(basename "$meta_file")." >&2
        return 1
    fi

    mode="$(awk -F= '$1=="encryption_mode"{print substr($0,index($0,"=")+1); exit}' "$meta_file" 2>/dev/null)" || {
        log_error "[backup] Emergency restore metadata could not be read: $meta_file" >&2
        return 1
    }
    case "$mode" in
        age-passphrase|age-recipient)
            ;;
        "")
            log_error "[backup] Emergency restore metadata has an empty encryption_mode: $(basename "$meta_file")." >&2
            return 1
            ;;
        *)
            log_error "[backup] Emergency restore metadata has unsupported encryption_mode '$mode': $(basename "$meta_file")." >&2
            return 1
            ;;
    esac

    if [[ -n "$mode_out_name" ]]; then
        printf -v "$mode_out_name" '%s' "$mode"
    fi
    return 0
}

verify_backup_full() {
    local enc_file="$1"
    local backup_type="$2"
    local payload_workspace="${3:-}"

    backup_log_info "Running full verification (decrypt + integrity check)..."

    if [[ -f "${enc_file}.sha256" ]]; then
        verify_file_integrity "$enc_file" || return 1
    elif [[ "${REQUIRE_AUTHENTICATED_INTEGRITY:-false}" == "true" ]]; then
        log_error "Full verification FAILED: required integrity sidecar is missing for $enc_file" >&2
        return 1
    else
        backup_log_warn "No SHA256 sidecar found — authenticated file check skipped"
    fi

    local encryption_mode=""
    if [[ "$backup_type" == "emergency" ]]; then
        if ! _validate_emergency_restore_metadata "$enc_file" encryption_mode; then
            log_error "Full verification FAILED: emergency restore-critical metadata is unusable." >&2
            return 1
        fi
    else
        encryption_mode="$(awk -F= '$1=="encryption_mode"{print $2; exit}' "${enc_file}.meta" 2>/dev/null || true)"
    fi

    local age_key_file=""
    if [[ "$backup_type" != "emergency" ]]; then
        age_key_file=$(_resolve_age_key) || {
            log_error "Age key file not found: $age_key_file" >&2
            return 1
        }
    fi

    case "$backup_type" in
        db)
            [[ -n "$payload_workspace" && -d "$payload_workspace" && ! -L "$payload_workspace" ]] || {
                log_error "DB full verification requires a verified payload workspace on BACKUP_DIR." >&2
                return 1
            }
            local dec_out="$payload_workspace/verify-db.sqlite3" encrypted_mb
            encrypted_mb="$(_file_size_mb "$enc_file")"
            check_backup_disk_space "$payload_workspace" "$((encrypted_mb + 16))" \
                "DB verification output" || return 1
            local age_error="$CONTROL_WORKSPACE/db-age.err" age_rc=0
            : > "$age_error"
            age -d -i "$age_key_file" -o "$dec_out" "$enc_file" 2>"$age_error" || age_rc=$?
            if (( age_rc != 0 )); then
                rm -f "$dec_out"
                log_error "Full verification FAILED: DB decryption exited ${age_rc}." >&2
                [[ -s "$age_error" ]] && log_error "  age: $(head -c 2048 "$age_error")" >&2
                return 1
            fi
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
            rm -f "$dec_out"
            ;;
        full|emergency)
            backup_log_info "Streaming decryption into archive listing validation..."
            _verify_encrypted_archive_stream "$enc_file" "$backup_type" "$encryption_mode" "$age_key_file" || return 1
            local size
            size=$(stat -c%s "$enc_file" 2>/dev/null || stat -f%z "$enc_file" 2>/dev/null || echo 0)
            if (( size < 10240 )); then
                log_error "Full verification FAILED: encrypted archive suspiciously small (${size} bytes)" >&2
                return 1
            fi
            ;;
    esac

    backup_log_info "Full verification passed: $(basename "$enc_file")"
    return 0
}

verify_backup_quick() {
    local enc_file="$1"
    local age_key_file="$2"
    local backup_type="${3:-}"
    local _quick_verify_hash_skipped=false
    local _quick_verify_decrypt_skipped=false

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

    if [[ "$backup_type" == "emergency" ]]; then
        local encryption_mode="" emergency_identity
        if ! _validate_emergency_restore_metadata "$enc_file" encryption_mode; then
            log_error "Quick verify FAILED: emergency restore-critical metadata is unusable." >&2
            return 1
        fi
        emergency_identity="$(get_config_value "EMERGENCY_BACKUP_AGE_IDENTITY_FILE" "${EMERGENCY_BACKUP_AGE_IDENTITY_FILE:-}")"

        case "$encryption_mode" in
            age-passphrase)
                if [[ -t 0 ]]; then
                    backup_log_info "Emergency backup is passphrase-sealed; enter the emergency passphrase for decrypt probe..."
                    if ! age -d -o /dev/null "$enc_file"; then
                        log_error "Quick verify FAILED: could not decrypt passphrase-sealed emergency backup." >&2
                        return 1
                    fi
                    backup_log_info "Emergency passphrase decrypt probe passed"
                else
                    backup_log_warn "Emergency backup is passphrase-sealed; decrypt probe skipped because no TTY is available."
                    _quick_verify_decrypt_skipped=true
                fi
                ;;
            age-recipient)
                if [[ -n "$emergency_identity" && -r "$emergency_identity" ]]; then
                    if ! age -d -i "$emergency_identity" -o /dev/null "$enc_file" 2>/dev/null; then
                        log_error "Quick verify FAILED: emergency recipient decrypt probe failed for $(basename "$enc_file")" >&2
                        return 1
                    fi
                    backup_log_info "Emergency recipient decrypt probe passed"
                else
                    backup_log_warn "Emergency backup uses a separate recipient; decrypt probe skipped because EMERGENCY_BACKUP_AGE_IDENTITY_FILE is not configured/readable."
                    _quick_verify_decrypt_skipped=true
                fi
                ;;
            *)
                log_error "Quick verify FAILED: emergency encryption mode validation returned an unexpected value." >&2
                return 1
                ;;
        esac
    else
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
    fi

    if [[ "$_quick_verify_decrypt_skipped" == "true" ]]; then
        if [[ "$_quick_verify_hash_skipped" == "true" ]]; then
            backup_log_warn "Quick verification completed with limited checks: no SHA256 sidecar and emergency decrypt probe skipped."
        else
            backup_log_info "Quick verification passed for emergency backup integrity sidecars; decrypt probe skipped by design."
        fi
    elif [[ "$_quick_verify_hash_skipped" == "true" ]]; then
        backup_log_info "Quick verification passed (decrypt probe only; no .sha256 sidecar): $(basename "$enc_file")"
    else
        backup_log_info "Quick verification passed (SHA256 + decrypt probe): $(basename "$enc_file")"
    fi

    return 0
}

_verify_remote_cohort_member() {
    local -n _rclone_args="$1"
    local remote_member="$2" label="${3:-remote backup member}"
    local out err_file="${CONTROL_WORKSPACE}/rclone-size-verify.$$.err" bytes=""
    : > "$err_file"
    if ! out=$(rclone size "${_rclone_args[@]}" "$remote_member" 2>"$err_file"); then
        log_error "[backup] Remote verification FAILED for ${label}: ${remote_member}" >&2
        [[ ! -s "$err_file" ]] || log_error "[backup] rclone: $(head -5 "$err_file")" >&2
        return 1
    fi
    bytes=$(printf '%s
' "$out" | awk 'tolower($0) ~ /^total size:/ { gsub(/[^0-9]/, "", $3); print $3+0; exit }')
    [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]] || {
        log_error "[backup] Remote verification FAILED for ${label}: ${remote_member} is missing or empty." >&2
        return 1
    }
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

    if [[ "$backup_type" == "emergency" ]] && ! _validate_emergency_restore_metadata "$enc_file"; then
        log_error "[backup] Emergency offsite delivery is incomplete: restore-critical metadata is missing, unusable, or not delivered." >&2
        return 3
    fi

    local suffix local_member
    local -a required_suffixes=() upload_suffixes=()
    mapfile -t required_suffixes < <(backup_required_cohort_suffixes)
    upload_suffixes=("${required_suffixes[@]}")
    if [[ "${REQUIRE_AUTHENTICATED_INTEGRITY:-false}" != "true" && -s "${enc_file}.sha256.hmac" ]]; then
        upload_suffixes+=(".sha256.hmac")
    fi
    for suffix in "${required_suffixes[@]}"; do
        local_member="${enc_file}${suffix}"
        [[ -f "$local_member" && ! -L "$local_member" && -s "$local_member" ]] || {
            log_error "[backup] Offsite sync refused incomplete local cohort: $(basename "$local_member") is missing or empty." >&2
            return 1
        }
    done

    backup_log_info "Syncing authenticated backup cohort to rclone remote: ${remote_path}/"
    backup_log_info "Pre-flight check: testing connectivity to rclone remote '${remote_name}'..."
    if ! rclone lsd "${rclone_config_arg[@]}" "${remote_name}:" --contimeout 10s --timeout 30s &>/dev/null; then
        log_error "Pre-flight check FAILED: cannot reach rclone remote '${remote_name}'. Aborting offsite sync." >&2
        log_error "Verify credentials and network, then retry: rclone lsd ${remote_name}:" >&2
        return 1
    fi

    local rclone_stderr_tmp="${CONTROL_WORKSPACE}/rclone_stderr.tmp"
    for suffix in "${upload_suffixes[@]}"; do
        local_member="${enc_file}${suffix}"
        local upload_rc=0
        rclone copy "${rclone_config_arg[@]}" "$local_member" "$remote_path/" --checksum \
            2>"${rclone_stderr_tmp}" || upload_rc=$?
        if (( upload_rc != 0 )); then
            if [[ "$backup_type" == "emergency" && "$suffix" == ".meta" ]]; then
                log_error "[backup] Emergency restore metadata upload FAILED: $(basename "$local_member") (exit ${upload_rc}) — remote emergency recovery point is incomplete." >&2
                return 3
            fi
            log_error "[backup] Required cohort upload FAILED: $(basename "$local_member") (exit ${upload_rc}) — remote recovery point is incomplete." >&2
            return 1
        fi
    done

    for suffix in "${required_suffixes[@]}"; do
        _verify_remote_cohort_member rclone_config_arg \
            "${remote_path}/$(basename "${enc_file}${suffix}")" \
            "$(basename "${enc_file}${suffix}")" || return 1
    done

    backup_log_info "Offsite sync complete → ${remote_path}/$(basename "$enc_file") (complete required cohort)"
    return 0
}

# _resolve_rclone_config_arg NAMEREF_ARRAY
#
# Resolves, validates, and canonicalises the rclone config path, then populates
# the caller's array (passed by nameref) with the --config argument pair.
# NAMEREF_ARRAY is the caller's variable name without a leading dollar sign.
# Returns 1 and logs an error when resolution or validation fails.
# Requires Bash 5.0+ (the production baseline is Ubuntu 24.04 LTS Noble).
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
        retention=$(backup_retention_days_for_type "$t" "${KEEP_DAYS:-}") || return 1
        if [[ "$DRY_RUN" == "true" ]]; then
            backup_log_info "[DRY RUN] Would apply ${retention}-day local retention to ${t} backups before upload."
        fi
        cleanup_old_backups "$local_dir" "$t" "$retention" || return 1

        if ! find "$local_dir" -maxdepth 1 -name '*.age' -type f -print -quit | grep -q .; then
            backup_log_info "No retained ${t} backups to upload."
            continue
        fi

        local retained_archive suffix
        while IFS= read -r -d '' retained_archive; do
            if [[ "$t" == "emergency" ]] && ! _validate_emergency_restore_metadata "$retained_archive"; then
                log_error "[backup] Retained emergency backup is not restore-usable: $(basename "$retained_archive")"
                log_error "[backup] This emergency recovery point is not safe to report as offsite complete."
                return 1
            fi
            while IFS= read -r suffix; do
                [[ -f "${retained_archive}${suffix}" && ! -L "${retained_archive}${suffix}" && -s "${retained_archive}${suffix}" ]] || {
                    log_error "[backup] Retained ${t} backup has an incomplete required cohort: $(basename "${retained_archive}${suffix}")"
                    return 1
                }
            done < <(backup_required_cohort_suffixes)
        done < <(find "$local_dir" -maxdepth 1 -name '*.age' -type f -print0)

        backup_log_info "Copying retained ${t} backups to ${remote_name}:${remote_base}/${t}/"
        rclone copy "${rclone_config_arg[@]}" "$local_dir/" \
            "${remote_name}:${remote_base}/${t}/" \
            --include '*.age' \
            --include '*.age.sha256' \
            --include '*.age.sha256.hmac' \
            --include '*.age.meta' \
            --checksum "${dry_run_arg[@]}" || return 1

        if [[ "$DRY_RUN" != "true" ]]; then
            while IFS= read -r -d '' retained_archive; do
                while IFS= read -r suffix; do
                    _verify_remote_cohort_member rclone_config_arg \
                        "${remote_name}:${remote_base}/${t}/$(basename "${retained_archive}${suffix}")" \
                        "$(basename "${retained_archive}${suffix}")" || return 1
                done < <(backup_required_cohort_suffixes)
            done < <(find "$local_dir" -maxdepth 1 -name '*.age' -type f -print0)
        fi
        (( ++copied_types )) || true
    done

    _prune_remote_backups || return 1
    backup_log_success "Rclone backup copy complete (${copied_types} backup type(s))."
}

# _prune_remote_backups [OVERRIDE_TYPE]
#
# Prunes backup files on the configured rclone remote that are older than the
# canonical per-type retention period. A failed inventory listing is distinct
# from an empty inventory: no files are deleted for that type and the function
# returns nonzero so the caller cannot report remote retention as successful.
# A missing type directory (rclone exit 3) is an expected empty tier. When
# OVERRIDE_TYPE is set, KEEP_DAYS applies only to that tier; otherwise it applies
# to every tier for the sync/rotate command contract.
_prune_remote_backups() {
    local override_type="${1:-}"

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
        local retention_days retention_override=""
        if [[ -z "$override_type" || "$t" == "$override_type" ]]; then
            retention_override="${KEEP_DAYS:-}"
        fi
        retention_days=$(backup_retention_days_for_type "$t" "$retention_override") || return 1

        local remote_listing="" list_rc=0 list_error_file
        if [[ -n "${CONTROL_WORKSPACE:-}" && -d "$CONTROL_WORKSPACE" ]]; then
            list_error_file="${CONTROL_WORKSPACE}/rclone-lsf-${t}.err"
            : > "$list_error_file"
        else
            list_error_file=$(mktemp -t vw-rclone-lsf.XXXXXXXXXX) || {
                log_error "[remote] Could not create a temporary file for listing ${remote_path}/. No ${t} files were deleted."
                _prune_failed=true
                continue
            }
        fi

        if remote_listing=$(rclone lsf "${rclone_config_arg[@]}" "${remote_path}/" \
                --files-only --include "*.age" \
                --contimeout 15s --timeout 60s 2>"$list_error_file"); then
            list_rc=0
        else
            list_rc=$?
        fi

        if (( list_rc == 3 )); then
            backup_log_info "[remote] No ${t} backup directory exists yet at ${remote_path}/ — nothing to prune."
            rm -f "$list_error_file"
            continue
        fi

        if (( list_rc != 0 )); then
            local list_error=""
            list_error=$(head -5 "$list_error_file" 2>/dev/null || true)
            log_error "[remote] Failed to list ${remote_path}/ (rclone exit ${list_rc}). No ${t} files were deleted."
            [[ -n "$list_error" ]] && log_error "[remote] rclone lsf: ${list_error}"
            log_error "[remote] Check rclone configuration/connectivity and retry: sudo ./backup.sh rotate"
            rm -f "$list_error_file"
            _prune_failed=true
            continue
        fi
        rm -f "$list_error_file"

        local -a remote_files=()
        if [[ -n "$remote_listing" ]]; then
            mapfile -t remote_files <<< "$remote_listing"
        fi

        if [[ ${#remote_files[@]} -eq 0 ]]; then
            backup_log_info "[remote] No ${t} backup archives found on remote — nothing to prune."
            continue
        fi

        local _newest_remote_file=""
        if _newest_remote_file=$(_backup_newest_timestamped_archive "${remote_files[@]}"); then
            backup_log_info "[remote] Preserving newest ${t} backup on remote: ${_newest_remote_file}"
        else
            backup_log_warn "[remote] No ${t} remote archive has a parseable YYYYMMDD-HHMMSS timestamp — skipping primary deletion."
            continue
        fi

        local _deleted_remote=0
        local _type_prune_failed=false
        local _file
        for _file in "${remote_files[@]}"; do
            local _age_days
            _age_days=$(_backup_filename_age_days "$_file")
            if [[ -z "$_age_days" ]]; then
                backup_log_warn "[remote] $(basename "$_file") has no filename timestamp — skipping remote deletion."
                continue
            fi
            if [[ "$_file" == "$_newest_remote_file" ]]; then
                if (( _age_days > retention_days )); then
                    backup_log_info "[remote] Preserving newest ${t} backup despite age (${_age_days}d > ${retention_days}d): ${_file}"
                fi
                continue
            fi
            if (( _age_days > retention_days )); then
                if [[ "$DRY_RUN" == "true" ]]; then
                    backup_log_info "[DRY RUN] Would delete remote: ${remote_path}/${_file} (${_age_days}d > ${retention_days}d)"
                    (( ++_deleted_remote )) || true
                    continue
                fi
                local _del_exit=0
                rclone deletefile "${rclone_config_arg[@]}" "${remote_path}/${_file}" \
                    --contimeout 15s --timeout 60s 2>/dev/null || _del_exit=$?
                if (( _del_exit != 0 )); then
                    log_warn "[rotate] Failed to delete remote file: ${remote_path}/${_file}" >&2
                    _prune_failed=true
                    _type_prune_failed=true
                else
                    backup_log_info "[remote] Deleted: ${_file} (${_age_days}d > ${retention_days}d)"
                    (( ++_deleted_remote )) || true
                    # Remove associated sidecar files only after the primary was deleted.
                    local _ext
                    for _ext in .sha256 .sha256.hmac .meta; do
                        rclone deletefile "${rclone_config_arg[@]}" \
                            "${remote_path}/${_file}${_ext}" \
                            --contimeout 15s --timeout 60s 2>/dev/null || true
                    done
                fi
            fi
        done

        if [[ "$_type_prune_failed" == "true" ]]; then
            if (( _deleted_remote > 0 )); then
                log_error "[remote] Pruned ${_deleted_remote} old ${t} backup(s) from ${remote_path}/, but one or more primary deletions failed."
            else
                log_error "[remote] One or more old ${t} backups could not be pruned from ${remote_path}/."
            fi
        elif (( _deleted_remote > 0 )); then
            if [[ "$DRY_RUN" == "true" ]]; then
                backup_log_info "[DRY RUN] Would prune ${_deleted_remote} old ${t} backup(s) from ${remote_path}/"
                continue
            fi
            backup_log_success "[remote] Pruned ${_deleted_remote} old ${t} backup(s) from ${remote_path}/"
        else
            backup_log_info "[remote] No old ${t} backups to prune on remote."
        fi
    done

    if [[ "$_prune_failed" == "true" ]]; then
        log_error "[rotate] Remote retention did not complete — check the errors above."
        return 1
    fi
    return 0
}

perform_db_backup() {
    local target_dir="$1" timestamp="$2" age_pub_key="$3" payload_workspace="$4"
    local candidate_out_name="$5" final_out_name="$6"
    local state_dir backup_base final_archive candidate_path
    state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    backup_base="$(dirname "$target_dir")"
    final_archive="$target_dir/db_backup_$timestamp.sqlite3.age"
    candidate_path="$target_dir/.$(basename "$final_archive").candidate"

    backup_log_info "Performing database backup..."
    printf -v "$final_out_name" '%s' "$final_archive"
    if [[ "$DRY_RUN" == "true" ]]; then
        backup_log_info "[DRY RUN] Would backup DB → $final_archive"
        return 0
    fi

    _require_absent_backup_cohorts "$candidate_path" "$final_archive" || return 1
    _preflight_backup_payload_capacity "$state_dir" "$backup_base" db || return 1
    PENDING_BACKUP_CANDIDATE="$candidate_path"

    local snap="$payload_workspace/db.sqlite3"
    create_consistent_db_snapshot "$state_dir" "$snap" "db backup" || return 1
    local db_snapshot_method="$DB_SNAPSHOT_METHOD"

    backup_log_info "Encrypting DB snapshot to a hidden candidate..."
    age -r "$age_pub_key" -o "$candidate_path" "$snap" 2>/dev/null || {
        log_error "Encryption failed (check disk space: df -h $target_dir; verify Age key: make key-health)" >&2
        return 1
    }
    secure_file "$candidate_path" 600
    rm -f -- "$snap" || return 1
    [[ ! -e "$snap" ]] || { log_error "Plaintext DB snapshot still exists after encryption: $snap" >&2; return 1; }

    write_file_integrity "$candidate_path" || {
        log_error "Failed to write backup integrity sidecars for candidate." >&2
        return 1
    }

    local db_file="$state_dir/data/db.sqlite3" orig_size
    orig_size="$(_stat_file_size "$db_file" 2>/dev/null || echo 0)"
    create_backup_metadata "$candidate_path" db \
        "$(printf 'original_size=%s\narchive_format=relative\nversion=2\ndb_snapshot_method=%s\nencryption_mode=age-recipient\nemergency_contains_key_material=false' "$orig_size" "$db_snapshot_method")" || {
        log_error "Failed to write backup candidate metadata." >&2
        return 1
    }
    _validate_created_backup_cohort "$candidate_path" db || {
        log_error "Created DB backup candidate failed sidecar or metadata validation." >&2
        return 1
    }

    printf -v "$candidate_out_name" '%s' "$candidate_path"
    backup_log_info "DB backup candidate ready: $(basename "$candidate_path")"
}

perform_full_backup() {
    local target_dir="$1"
    local timestamp="$2"
    local age_pub_key="$3"
    local backup_label="${4:-full}"
    local payload_workspace="$5"
    local age_key_file="${6:-}"
    local candidate_out_name="$7" final_out_name="$8"
    local configured_state_dir raw_backup_base
    configured_state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    raw_backup_base="$(dirname "$target_dir")"

    local canonical_backup_base canonical_project_root canonical_state_dir
    _require_safe_backup_source_layout \
        "$raw_backup_base" "$SCRIPT_DIR" "$configured_state_dir" \
        canonical_backup_base canonical_project_root canonical_state_dir || return 1

    local backup_base="$canonical_backup_base"
    local project_root="$canonical_project_root"
    local state_dir="$canonical_state_dir"
    local expected_target="$backup_base/$backup_label"
    target_dir="$(realpath -m -- "$target_dir" 2>/dev/null)" || {
        log_error "Cannot canonicalize backup target directory: $target_dir" >&2
        return 1
    }
    [[ "$target_dir" == "$backup_base"/* ]] || {
        log_error "Backup type directory resolves outside configured BACKUP_DIR: $target_dir" >&2
        log_error "Configured BACKUP_DIR resolves to: $backup_base" >&2
        return 1
    }
    [[ "$target_dir" == "$expected_target" ]] || {
        log_error "Backup type directory must not be redirected: $expected_target" >&2
        log_error "Resolved backup type directory: $target_dir" >&2
        return 1
    }
    if [[ -n "$payload_workspace" ]]; then
        payload_workspace="$(realpath -m -- "$payload_workspace" 2>/dev/null)" || {
            log_error "Cannot canonicalize backup payload workspace: $payload_workspace" >&2
            return 1
        }
    fi

    local backup_label_title
    backup_label_title="$(printf '%s' "${backup_label:0:1}" | tr '[:lower:]' '[:upper:]')${backup_label:1}"

    local final_archive="$target_dir/${backup_label}_backup_$timestamp.tar.zst.age"
    local candidate_path
    candidate_path="$target_dir/.$(basename "$final_archive").candidate"
    printf -v "$final_out_name" '%s' "$final_archive"

    backup_log_info "Performing ${backup_label} backup (relative-path archive)..."

    if [[ "$DRY_RUN" == "true" ]]; then
        backup_log_info "[DRY RUN] Would create ${backup_label} backup → $final_archive"
        return 0
    fi

    require_commands tar || return 1
    require_commands zstd || return 1

    _require_absent_backup_cohorts "$candidate_path" "$final_archive" || return 1
    _preflight_backup_payload_capacity \
        "$state_dir" "$backup_base" "$backup_label" "$project_root" "$payload_workspace" "$target_dir" || return 1
    PENDING_BACKUP_CANDIDATE="$candidate_path"

    local snap_dir="$payload_workspace/stage"
    local snap_payload_dir="$payload_workspace/db-snapshot-payload"
    local snap_payload_name="__vaultwarden_verified_db_snapshot.sqlite3"
    local snap_payload_regex="__vaultwarden_verified_db_snapshot\\.sqlite3"
    local snap_db="$snap_payload_dir/$snap_payload_name"
    local db_archive_member="${state_dir#/}/data/db.sqlite3"
    local temp_tar="$payload_workspace/${backup_label}_backup_$timestamp.tar.zst"

    mkdir -p "$snap_payload_dir"

    local db_file="$state_dir/data/db.sqlite3"
    [[ -f "$db_file" ]] || { log_error "Database not found: $db_file" >&2; return 1; }
    create_consistent_db_snapshot "$state_dir" "$snap_db" "${backup_label} backup" || return 1
    local db_snapshot_method="$DB_SNAPSHOT_METHOD"
    verify_sqlite "$snap_db" || return 1

    backup_log_info "Archiving state (relative paths, safe for staged restore)..."

    local -a effective_excludes=()
    mapfile -t effective_excludes < <(
        backup_archive_exclusions "$project_root" "$state_dir" "$backup_base" "$age_key_file"
    )
    local -a tar_excludes=()
    local excl
    for excl in "${effective_excludes[@]}"; do
        tar_excludes+=("--exclude=${excl}")
    done

    local tar_sources=()

    tar_sources+=("${project_root#/}")

    tar_sources+=("${state_dir#/}")

    local encryption_mode="age-recipient"
    local emergency_contains_key_material=false
    if [[ "$backup_label" == "emergency" ]]; then
        emergency_contains_key_material=true
        mkdir -p "$snap_dir/etc/vaultwarden" "$snap_dir/METADATA"
        chmod 700 "$snap_dir/etc/vaultwarden"
        local etc_file
        for etc_file in /etc/vaultwarden/age-key.txt /etc/vaultwarden/vaultwarden.env /etc/vaultwarden/rclone.conf; do
            if [[ -f "$etc_file" ]]; then
                install -m 600 "$etc_file" "$snap_dir/etc/vaultwarden/$(basename "$etc_file")"
            fi
        done
        cat > "$snap_dir/METADATA/emergency-permissions.txt" <<'EOF'
/etc/vaultwarden root:root 0700
/etc/vaultwarden/age-key.txt root:root 0600
/etc/vaultwarden/vaultwarden.env root:root 0600
/etc/vaultwarden/rclone.conf root:root 0600
EOF
        tar_sources+=(-C "$snap_dir" "etc/vaultwarden" "METADATA/emergency-permissions.txt")
    fi

    local -a tar_cmd_args=(
        --use-compress-program='zstd --no-progress -T0 -3'
        -cf "$temp_tar"
        -C /
        "${tar_excludes[@]}"
        "${tar_sources[@]}"
    )
    [[ -s "$snap_db" ]] || { log_error "Verified staged DB snapshot is missing; refusing raw live DB fallback" >&2; return 1; }
    backup_log_info "Injecting verified DB snapshot at ${db_archive_member}..."
    tar_cmd_args+=(
        "--transform=s#^${snap_payload_regex}\$#${db_archive_member}#"
        -C "$snap_payload_dir"
        "$snap_payload_name"
    )

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

    _validate_full_archive_payload "$temp_tar" "$state_dir" "$project_root" "$backup_label" || return 1

    backup_log_info "Encrypting ${backup_label} archive to a hidden candidate..."

    if [[ "$backup_label" == "emergency" ]]; then
        local emergency_recipient
        emergency_recipient="$(get_config_value "EMERGENCY_BACKUP_AGE_RECIPIENT" "${EMERGENCY_BACKUP_AGE_RECIPIENT:-}")"
        if [[ -n "$emergency_recipient" ]]; then
            encryption_mode="age-recipient"
            if [[ "$emergency_recipient" == "$age_pub_key" ]]; then
                log_error "Emergency backup includes key material and cannot be encrypted only to the operational Age recipient." >&2
                rm -f "$candidate_path"
                return 1
            fi
            age -r "$emergency_recipient" -o "$candidate_path" "$temp_tar" 2>/dev/null || {
                log_error "Emergency encryption failed with EMERGENCY_BACKUP_AGE_RECIPIENT." >&2
                rm -f "$candidate_path"; return 1
            }
        else
            if [[ ! -t 0 ]]; then
                log_error "Emergency backup includes key material and requires either a TTY passphrase prompt or EMERGENCY_BACKUP_AGE_RECIPIENT." >&2
                rm -f "$candidate_path"
                return 1
            fi
            encryption_mode="age-passphrase"
            if [[ "$QUIET" != "true" ]]; then
                operator_attention warn "Emergency backup passphrase" \
                    "This passphrase protects only the emergency backup capsule." \
                    "It is not the live operational Age key or a Vaultwarden account password."
            fi
            age -p -o "$candidate_path" "$temp_tar" || {
                log_error "Emergency passphrase encryption failed." >&2
                rm -f "$candidate_path"; return 1
            }
        fi
    elif ! age -r "$age_pub_key" -o "$candidate_path" "$temp_tar" 2>/dev/null; then
        log_error "Encryption failed (check disk space: df -h $(dirname "$candidate_path"); verify Age key: make key-health)" >&2
        rm -f "$candidate_path"
        return 1
    fi
    secure_file "$candidate_path" 600

    if ! rm -f -- "$temp_tar"; then
        log_error "Encrypted backup was created, but its plaintext staging archive could not be removed." >&2
        _discard_backup_cohort "$candidate_path"
        return 1
    fi
    [[ ! -e "$temp_tar" ]] || {
        log_error "Plaintext backup archive still exists after encryption: $temp_tar" >&2
        _discard_backup_cohort "$candidate_path"
        return 1
    }

    write_file_integrity "$candidate_path" || {
        log_error "Failed to write backup integrity sidecars for candidate: $candidate_path" >&2
        rm -f "$candidate_path" "${candidate_path}.sha256" "${candidate_path}.sha256.hmac"
        return 1
    }

    [[ -s "$candidate_path" ]] || { log_error "Encrypted output is empty" >&2; rm -f "$candidate_path" "${candidate_path}.sha256" "${candidate_path}.sha256.hmac"; return 1; }

    local data_volume_mount data_volume_device state_dir_is_mountpoint storage_mode
    data_volume_mount="$(get_config_value "DATA_VOLUME_MOUNT" "")"
    data_volume_device="$(get_config_value "DATA_VOLUME_DEVICE" "")"
    state_dir_is_mountpoint=false; mountpoint -q "$state_dir" 2>/dev/null && state_dir_is_mountpoint=true
    storage_mode="$(_backup_storage_mode "$state_dir" "$data_volume_mount" "$data_volume_device")"
    if ! create_backup_metadata "$candidate_path" "$backup_label" \
            "$(printf 'project_state_dir=%s\nstorage_mode=%s\ndata_volume_mount=%s\ndata_volume_device=%s\nstate_dir_is_mountpoint=%s\nrepo_root=%s\narchive_format=relative\nversion=2\ndb_snapshot_method=%s\nencryption_mode=%s\nemergency_contains_key_material=%s' "$state_dir" "$storage_mode" "$data_volume_mount" "$data_volume_device" "$state_dir_is_mountpoint" "$project_root" "$db_snapshot_method" "$encryption_mode" "$emergency_contains_key_material")"; then
        log_error "Failed to write backup metadata: ${candidate_path}.meta" >&2
        _discard_backup_cohort "$candidate_path"
        return 1
    fi

    if ! _validate_created_backup_cohort "$candidate_path" "$backup_label"; then
        log_error "Created ${backup_label} backup cohort failed sidecar or metadata validation." >&2
        _discard_backup_cohort "$candidate_path"
        return 1
    fi

    printf -v "$candidate_out_name" '%s' "$candidate_path"
    backup_log_info "${backup_label_title} backup candidate ready: $(basename "$candidate_path")"
    return 0
}

# print_backup_manifest — Show the exact full/emergency archive exclusions.
print_backup_manifest() {
    local configured_state_dir configured_backup_base age_key_file=""
    configured_state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    configured_backup_base="$(get_config_value "BACKUP_DIR" "$(_default_backup_dir)")"
    age_key_file="$(_resolve_age_key 2>/dev/null || true)"

    local canonical_backup_base canonical_project_root canonical_state_dir
    _require_safe_backup_source_layout \
        "$configured_backup_base" "$SCRIPT_DIR" "$configured_state_dir" \
        canonical_backup_base canonical_project_root canonical_state_dir || return 1

    echo "=== Full Backup Contents ==="
    echo "Included: $canonical_project_root + $canonical_state_dir"
    echo "Effective tar exclusions:"
    backup_archive_exclusions \
        "$canonical_project_root" "$canonical_state_dir" "$canonical_backup_base" "$age_key_file" \
        | sed 's/^/  - /'
    echo "Emergency note: independently sealed emergency archives may add staged /etc/vaultwarden key/config material."
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

_print_backup_run_summary() {
    local backup_type="$1" backup_file="$2" verification_status="$3" offsite_status="$4"
    [[ "$QUIET" == "true" ]] && return 0
    operator_next_steps "Backup summary" \
        "Type: ${backup_type}" \
        "Local backup: ${backup_file}" \
        "Verification: ${verification_status}" \
        "Offsite sync: ${offsite_status}" >&2
}

main() {
    trap cleanup EXIT
    trap '_backup_signal_exit 130' INT
    trap '_backup_signal_exit 129' HUP
    trap '_backup_signal_exit 143' TERM

    if [[ "$_SUBCMD" != "list" ]]; then
        backup_require_root
    fi

    if [[ "$LIST_ONLY" == "true" ]]; then
        if ! load_env_file; then
            log_error "Failed to load project environment for backup inventory."
            exit 1
        fi
        local list_base_dir
        list_base_dir="$(get_config_value "BACKUP_DIR" "$(_default_backup_dir)")"
        if [[ -d "$list_base_dir" && ! -r "$list_base_dir" ]]; then
            log_error "Backup archive directory is not readable by $(id -un): $list_base_dir"
            exit 1
        fi
        list_backups "$list_base_dir" "$JSON_OUTPUT" || true
        exit 0
    fi

    if [[ "$_SUBCMD" == "manifest" ]]; then
        load_env_file || { log_error "Failed to load canonical project environment for backup manifest."; exit 1; }
        print_backup_manifest
        exit 0
    fi

    if [[ "$_SUBCMD" == "verify" ]]; then
        require_root "$@"
        auto_fix_critical_permissions "$PROJECT_ROOT"
        _check_backup_deps
        _create_owned_workspace CONTROL_WORKSPACE CONTROL_WORKSPACE_ID /dev/shm vw-backup-control true || exit 1

        log_header "VaultWarden-OCI Backup Verify"
        load_env_file || { log_error "Failed to load .env"; exit 1; }
        auto_fix_critical_permissions "$PROJECT_ROOT"
        require_project_state_ready || exit 1
        _load_integrity_hmac_key || exit 1

        local age_key_file
        age_key_file=$(_resolve_age_key) || {
            log_error "Age key file not found at: ${age_key_file:-/etc/vaultwarden/age-key.txt}"
            log_error "Restore the operational Age key at /etc/vaultwarden/age-key.txt, then re-run the backup."
            exit 1
        }

        local base_dir
        base_dir="$(get_config_value "BACKUP_DIR" "$(_default_backup_dir)")"
        base_dir="$(realpath -m -- "$base_dir" 2>/dev/null)" || {
            log_error "Cannot canonicalize configured BACKUP_DIR: $base_dir"
            exit 1
        }

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

        if [[ "$enc_type" == "db" ]]; then
            _create_owned_workspace PAYLOAD_WORKSPACE PAYLOAD_WORKSPACE_ID "$base_dir" .vaultwarden-backup || exit 1
        fi

        if ! verify_backup_full "$latest_file" "$enc_type" "$PAYLOAD_WORKSPACE"; then
            log_error "Verification FAILED: $(basename "$latest_file")"
            exit 1
        fi

        backup_log_success "Verification passed: $(basename "$latest_file")"
        exit 0
    fi

    if [[ "$_SUBCMD" == "sync" ]]; then
        require_root "$@"
        auto_fix_critical_permissions "$PROJECT_ROOT"
        _acquire_backup_guard
        operation_set_phase "sync" "Syncing retained backups"
        local sync_dry_label=""
        [[ "$DRY_RUN" == "true" ]] && sync_dry_label=" [DRY RUN]"
        log_header "VaultWarden-OCI Rclone Backup Copy${sync_dry_label}"
        load_env_file || { log_error "Failed to load .env"; exit 1; }
        auto_fix_critical_permissions "$PROJECT_ROOT"
        _create_owned_workspace CONTROL_WORKSPACE CONTROL_WORKSPACE_ID /dev/shm vw-backup-control true || exit 1

        sync_all_backups_to_rclone || exit 1
        exit 0
    fi

    if [[ "$_SUBCMD" == "rotate" ]]; then
        require_root "$@"
        auto_fix_critical_permissions "$PROJECT_ROOT"
        _acquire_backup_guard
        operation_set_phase "rotate" "Rotating retained backups"

        local rotate_dry_label=""
        [[ "$DRY_RUN" == "true" ]] && rotate_dry_label=" [DRY RUN]"
        log_header "VaultWarden-OCI Backup Rotation${rotate_dry_label}"
        load_env_file || { log_error "Failed to load .env"; exit 1; }
        auto_fix_critical_permissions "$PROJECT_ROOT"
        _create_owned_workspace CONTROL_WORKSPACE CONTROL_WORKSPACE_ID /dev/shm vw-backup-control true || exit 1

        local base_dir
        base_dir="$(get_config_value "BACKUP_DIR" "$(_default_backup_dir)")"

        local rotate_failed=false
        for t in db full emergency; do
            local type_dir="$base_dir/$t"
            [[ -d "$type_dir" ]] || continue
            local retention_days
            retention_days=$(backup_retention_days_for_type "$t" "${KEEP_DAYS:-}") || exit 1

            cleanup_old_backups "$type_dir" "$t" "$retention_days" || rotate_failed=true
        done

        if [[ "$rotate_failed" == "true" ]]; then
            log_error "One or more local rotation steps encountered errors — check above for details."
            exit 1
        fi

        local rotate_suffix=""
        if [[ "$DRY_RUN" == "true" ]]; then
            rotate_suffix=" (dry run)"
            backup_log_success "Local retention preview completed${rotate_suffix}."
        else
            backup_log_success "Local retention completed."
        fi

        if ! _prune_remote_backups; then
            log_error "[rotate] Local retention completed, but remote retention failed."
            log_error "[rotate] Review the remote errors above and rerun: sudo ./backup.sh rotate"
            exit 1
        fi

        backup_log_success "Rotation complete${rotate_suffix}."
        exit 0
    fi


    _check_backup_deps

    [[ "$FORCE" == "true" ]] && backup_log_warn "--force does not bypass active VaultWarden operation guards."
    _acquire_backup_guard
    operation_set_phase "run" "Creating ${BACKUP_TYPE} backup"
    _create_owned_workspace CONTROL_WORKSPACE CONTROL_WORKSPACE_ID /dev/shm vw-backup-control true || exit 1

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
        log_error "Restore the operational Age key at /etc/vaultwarden/age-key.txt, then re-run the backup."
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
    backup_dir=$(get_backup_dir "$actual_type" "$state_dir")

    if [[ "$DRY_RUN" == "false" ]]; then
        local backup_base
        backup_base="$(dirname "$backup_dir")"
        if [[ "$actual_type" == "emergency" ]]; then
            _create_owned_workspace PAYLOAD_WORKSPACE PAYLOAD_WORKSPACE_ID /dev/shm .vaultwarden-emergency || exit 1
        else
            _create_owned_workspace PAYLOAD_WORKSPACE PAYLOAD_WORKSPACE_ID "$backup_base" .vaultwarden-backup || exit 1
        fi
    fi

    local backup_file="" candidate_file="" final_file=""
    local backup_success=false
    case "$actual_type" in
        db)
            perform_db_backup "$backup_dir" "$timestamp" "$age_pub_key" "$PAYLOAD_WORKSPACE" \
                candidate_file final_file && backup_success=true
            ;;
        full|emergency)
            perform_full_backup "$backup_dir" "$timestamp" "$age_pub_key" "$actual_type" \
                "$PAYLOAD_WORKSPACE" "$age_key_file" candidate_file final_file && backup_success=true
            ;;
        *)
            log_error "Invalid backup type: $actual_type"; exit 1 ;;
    esac

    backup_file="$final_file"
    if [[ "$backup_success" == "true" && "$DRY_RUN" == "false" ]]; then
        [[ -n "$candidate_file" && -f "$candidate_file" && "$final_file" == *.age ]] || {
            log_error "Backup candidate or final path is invalid."
            exit 1
        }
    fi

    if [[ "$backup_success" == "true" && "$DRY_RUN" == "false" ]]; then

        local verify_failed=false
        local rclone_failed=false
        local verification_status="not run"
        local offsite_status="not requested"

        if [[ "$FULL_VERIFY" == "true" ]]; then
            if ! verify_backup_full "$candidate_file" "$actual_type" "$PAYLOAD_WORKSPACE"; then
                log_error "Backup verification failed — discarding corrupt archive."
                _discard_backup_cohort "$candidate_file"
                exit 1
            fi
            verification_status="full verification passed"
        else
            if ! verify_backup_quick "$candidate_file" "$age_key_file" "$actual_type"; then
                verify_failed=true
                verification_status="quick verification FAILED"
                log_error "Quick verification failed — backup is being discarded."
                if [[ "$EMAIL_NOTIFY" == "true" ]]; then
                    local warn_subj="[VaultWarden] WARNING: Backup verify FAILED: $actual_type ($timestamp)"
                    local warn_body
                    warn_body="$(printf 'Backup type:  %s\nTimestamp:    %s\nFile:         %s\nHost:         %s\n\nQuick verification (SHA256 + decrypt probe) FAILED.\nThe encrypted archive and sidecars were discarded and are not eligible for restore.\nOlder backups were preserved; retention and offsite sync were skipped.\n' \
                        "$actual_type" "$timestamp" \
                        "$(basename "${candidate_file:-unknown}")" \
                        "$(hostname -f 2>/dev/null || hostname)")"
                    send_notification_email "$warn_subj" "$warn_body" 2>/dev/null || true
                fi
                if [[ "$RCLONE_SYNC" == "true" ]]; then
                    log_error "Skipping offsite sync due to verification failure."
                    offsite_status="skipped because verification failed"
                fi
                _print_backup_run_summary "$actual_type" "$candidate_file" "$verification_status" "$offsite_status"
                log_error "Discarding unpublished candidate and sidecars:"
                log_error "  $candidate_file"
                _discard_backup_cohort "$candidate_file"
                log_error "Backup failed: quick verification did not complete successfully."
                exit 1
            else
                verification_status="quick verification passed"
            fi
        fi

        if ! _publish_backup_candidate "$candidate_file" "$final_file"; then
            log_error "Backup candidate passed verification but could not be published."
            exit 1
        fi
        backup_file="$final_file"

        if [[ "$RCLONE_SYNC" == "true" ]]; then
            local _sync_rc=0
            sync_to_rclone "$backup_file" "$actual_type" || _sync_rc=$?
            if (( _sync_rc == 3 )); then
                rclone_failed=true
                offsite_status="FAILED: emergency restore metadata missing or unusable; local backup is safe"
                if [[ "$EMAIL_NOTIFY" == "true" ]]; then
                    local subj="[VaultWarden] Emergency offsite delivery INCOMPLETE: $actual_type ($timestamp)"
                    local bdy
                    bdy="$(printf 'Backup type:  %s\nTimestamp:    %s\nFile:         %s\nHost:         %s\n\nEmergency primary upload may have succeeded, but restore-critical .meta validation or delivery failed.\nThe local emergency backup is intact. Do not treat the remote primary as a complete recovery point until matching restore-usable metadata is present.\n' \
                        "$actual_type" "$timestamp" \
                        "$(basename "${backup_file:-unknown}")" \
                        "$(hostname -f 2>/dev/null || hostname)")"
                    send_notification_email "$subj" "$bdy" 2>/dev/null || true
                fi
                log_error "Emergency offsite delivery incomplete — restore-critical metadata is missing, unusable, or not delivered. Local backup is safe."
                _print_backup_run_summary "$actual_type" "$backup_file" "$verification_status" "$offsite_status"
                exit 2
            elif (( _sync_rc != 0 )); then
                rclone_failed=true
                offsite_status="failed; local backup is safe"
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
                _print_backup_run_summary "$actual_type" "$backup_file" "$verification_status" "$offsite_status"
                exit 2
            else
                offsite_status="synced"
            fi
        fi

        _log_backup_size "$backup_file"

        local retention_days
        retention_days=$(backup_retention_days_for_type "$actual_type" "${KEEP_DAYS:-}") || exit 1
        backup_log_info "Cleaning up old backups (retention: $retention_days days)..."
        cleanup_old_backups "$backup_dir" "$actual_type" "$retention_days" || \
            backup_log_warn "Failed to clean up some old backups"

        if [[ "$RCLONE_SYNC" == "true" && "$rclone_failed" == "false" ]]; then
            if ! _prune_remote_backups "$actual_type"; then
                rclone_failed=true
                offsite_status="backup synced; remote retention FAILED"
                log_error "Remote retention failed after the backup upload. Local and uploaded backup copies are safe."
            fi
        fi

        if [[ "$EMAIL_NOTIFY" == "true" ]]; then
            local rclone_status="$offsite_status"

            local verify_status
            if [[ "$FULL_VERIFY" == "true" ]]; then
                verify_status="full (passed)"
            elif [[ "$verify_failed" == "true" ]]; then
                verify_status="quick (FAILED — see warning email)"
            else
                verify_status="quick (passed)"
            fi

            local subject="[VaultWarden] Backup completed: $actual_type ($timestamp)"
            if [[ "$rclone_failed" == "true" ]]; then
                subject="[VaultWarden] Backup remote retention FAILED: $actual_type ($timestamp)"
            fi
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

        _print_backup_run_summary "$actual_type" "$backup_file" "$verification_status" "$offsite_status"
        if [[ "$rclone_failed" == "true" ]]; then
            log_error "Backup completed locally, but requested remote retention failed."
            exit 2
        elif [[ "$verify_failed" == "true" ]]; then
            log_warn "Backup archive was created, but quick verification failed; do not treat it as verified."
            log_warn "Manual inspection required before using this backup for disaster recovery."
        else
            backup_log_success "Backup completed successfully"
        fi
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
