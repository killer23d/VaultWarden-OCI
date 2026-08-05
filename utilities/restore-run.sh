#!/usr/bin/env bash
# utilities/restore-run.sh — Restores VaultWarden data from local or remote encrypted backups.
# shellcheck disable=SC1091
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/config.sh"
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"
source "${PROJECT_ROOT}/lib/operations.sh"
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/setup-credentials.sh"
_source_lib() {
    local lib="$1"
    # shellcheck source=/dev/null
    if ! source "$lib" 2>/dev/null; then
        echo "ERROR: restore.sh: failed to load required library: $lib" >&2
        echo "       Ensure you are running from the project root directory." >&2
        exit 1
    fi
}
_source_lib "lib/docker.sh"
_source_lib "lib/backup-utils.sh"
_source_lib "lib/crypto.sh"
_source_lib "lib/storage.sh"
_source_lib "lib/runtime-permissions.sh"
unset -f _source_lib

check_dependencies() {
    local -a hard=(docker age age-keygen sqlite3 sha256sum tar)
    local -a soft=(sops zstd rclone)
    local missing_hard=() missing_soft=()
    for c in "${hard[@]}"; do command -v "$c" >/dev/null 2>&1 || missing_hard+=("$c"); done
    for c in "${soft[@]}"; do command -v "$c" >/dev/null 2>&1 || missing_soft+=("$c"); done
    if [[ ${#missing_hard[@]} -gt 0 ]]; then
        echo "ERROR: restore.sh: the following required tools are not installed: ${missing_hard[*]}" >&2
        echo "       Install with: apt-get install -y age sqlite3 coreutils tar" >&2
        echo "       age-keygen is part of the 'age' package on most distributions." >&2
        local _cmd
        for _cmd in "${missing_hard[@]}"; do
            case "$_cmd" in
                docker)    echo "  Hint [docker]:    apt install docker.io  OR  snap install docker" >&2 ;;
                age)       echo "  Hint [age]:       apt install age  OR  snap install age" >&2 ;;
                age-keygen) echo "  Hint [age-keygen]: installed with 'age' — apt install age" >&2 ;;
                sqlite3)   echo "  Hint [sqlite3]:   apt install sqlite3" >&2 ;;
                sha256sum) echo "  Hint [sha256sum]: apt install coreutils" >&2 ;;
                tar)       echo "  Hint [tar]:       apt install tar" >&2 ;;
                rsync)     echo "  Hint [rsync]:     apt install rsync" >&2 ;;
                zstd)      echo "  Hint [zstd]:      apt install zstd" >&2 ;;
            esac
        done
        exit 1
    fi
    if [[ ${#missing_soft[@]} -gt 0 ]]; then
        echo "WARN: restore.sh: optional tools missing (some features will be disabled): ${missing_soft[*]}" >&2
        local _cmd
        for _cmd in "${missing_soft[@]}"; do
            case "$_cmd" in
                rclone) echo "  Hint [rclone]: apt install rclone" >&2 ;;
                sops)   echo "  Hint [sops]: apt install sops  OR  snap install sops" >&2 ;;
                zstd)   echo "  Hint [zstd]: apt install zstd" >&2 ;;
            esac
        done
    fi
}
case "${1:-}" in
    latest|list|interactive|inspect) : ;;
esac

BACKUP_FILE=""
RESTORE_TYPE=""
USE_LATEST=false
LIST_ONLY=false
LIST_REMOTE=false
DRY_RUN=false
FORCE=false
NO_PRE_BACKUP=false
START_POLICY=""
ROTATE_AGE_KEY_POLICY=""
SKIP_VERIFICATION=false
RESTORE_ENV=true
RESTORE_SNAPSHOT_HARD_FAIL="${RESTORE_SNAPSHOT_HARD_FAIL:-true}"
RESTORE_SNAPSHOT_RESULT="not-run"
RESTORE_FULL_PROMOTION_COMMITTED=false
USE_REMOTE=false
KEY_FILE_ARG=""         # set by --key-file; path to age private key for this restore
RECOVERY_KIT_FILE=""    # set by --from-recovery-kit; path to plaintext recovery-kit file
INSPECT_ONLY=false
RESTORE_PREFLIGHT_SOURCE_ROOT=""

# Declare this here so set -u never fires before main() initialises it via
# get_config_value(). Every function that references BACKUP_BASE_DIR is called
# only after main() has set it.
BACKUP_BASE_DIR=""

# Session-scoped rclone remote name and path for emergency restores.
# When .env is absent on a fresh server, _prompt_rclone_remote_name() fills
# these values for this run only, and they are never written back to disk.
_SESSION_RCLONE_REMOTE_NAME=""
_SESSION_RCLONE_REMOTE_PATH=""

RCLONE_NEEDS_INTERACTIVE_NAME=false

show_help() {
    cat << 'EOF'
VaultWarden-OCI Restore Script

USAGE:
    sudo ./restore.sh <subcommand> [options]

SUBCOMMANDS:
    latest [TYPE]     Restore the newest local backup (TYPE: db | full | emergency)
    list              List available local backups (no root required)
    list --remote     List available remote backups (no root required)
    interactive       Interactive guided restore — shows a numbered backup menu.
    inspect           Non-destructive backup layout/storage preflight only.
                      If rclone is configured, you are first asked whether to
                      restore from a LOCAL or REMOTE backup.

    After the backup is selected you will be prompted for the Age private
    key that decrypts the selected backup. Press Enter to use the operational
    Age key already configured in .env (SOPS_AGE_KEY_FILE).

    Before overwrite, restore creates a pre-restore emergency snapshot unless
    --no-backup is used. If that snapshot is passphrase-sealed, its emergency
    passphrase prompt protects the safety snapshot of the current VM; it is not
    the decryption prompt for the selected DB/full backup.

    Once the restore lands, the restored SOPS secrets are rekeyed to a NEW
    operational Age key, installed to configured locations, and displayed
    prominently. Save the new key/recovery kit before considering future
    backups recoverable.

OPTIONS (used after a subcommand):
    --file FILE             Restore a specific backup file (.age)
    --remote                Skip the local/remote menu; restore from rclone remote
    --key-file FILE         Path to the age private key for decrypting this backup
                            (alternative to the interactive prompt)
    --from-recovery-kit FILE
                            Path to a plaintext recovery-kit file.  The Age
                            private key (AGE-SECRET-KEY-1...) is extracted
                            automatically and used for decryption — no manual
                            key entry required.  Intended for bare-metal DR
                            where the kit file is the only credential available.
    --no-backup             Skip pre-restore emergency snapshot. Use only when
                            current local state is disposable, such as a fresh
                            VM restoring a remote DB backup.
    --skip-verification     Skip integrity check (not recommended)
    --skip-env              Do not restore archived .env over current .env
    --dry-run               Show what would happen without making changes
    --inspect               Non-destructive inspect mode (same as inspect subcommand)
    --force                 Skip confirmation prompts
    --start-policy MODE     Service start policy after restore: auto | ask | manual
    --start                 Alias for --start-policy auto
    --no-start              Alias for --start-policy manual
    --rotate-age-key        Rotate Age key after restore (secure default)
    --no-rotate-age-key     Skip post-restore Age rotation after explicit operator choice

GLOBAL SUBCOMMAND:
    help                    Show this help

GLOBAL OPTIONS:
    --help, -h              Show this help and exit
    --version, -V           Print the VaultWarden-OCI version and exit

ENVIRONMENT:
    BACKUP_DIR=<path>                  Override backup storage root
                                       (default: $PROJECT_STATE_DIR/backups)
    RESTORE_SNAPSHOT_HARD_FAIL=false   Demote snapshot failure to a warning
    RESTORE_AGE_KEY_FILE=<path>        Non-interactive equivalent of --key-file
    RESTORE_RECOVERY_KIT_FILE=<path>   Non-interactive equivalent of --from-recovery-kit
    RCLONE_REMOTE_NAME                 Read from .env when available
    RESTORE_HEALTH_TIMEOUT=<seconds>    Service health wait timeout (30-600; default: 60)

EXAMPLES:
    # ── QUICK START (most common) ────────────────────────────────
    sudo ./restore.sh latest             # Restore newest backup (interactive confirm)
    sudo ./restore.sh latest db          # Restore newest DB backup
    sudo ./restore.sh latest --force     # Restore newest backup, no confirm prompts
    ./restore.sh list                    # List local backups (no sudo)
    ./restore.sh list --remote           # List remote backups (no sudo)

    # ── INTERACTIVE MENU ─────────────────────────────────────────
    sudo ./restore.sh interactive                    # Select from local backups
    sudo ./restore.sh interactive --remote --start-policy ask  # Remote restore; ask before service start

    # ── TARGETED RESTORE ──────────────────────────────────────────
    sudo ./restore.sh interactive --file "/var/lib/vaultwarden/backups/full/full_20260101.tar.zst.age"
    sudo ./restore.sh interactive --key-file /tmp/old-age-key.txt  # Supply key non-interactively

    # ── BARE-METAL DISASTER RECOVERY ──────────────────────────────
    sudo ./restore.sh inspect --remote
    sudo ./restore.sh interactive --remote --from-recovery-kit /mnt/usb/recovery-kit.txt --start-policy ask
    sudo ./restore.sh interactive --remote --no-backup  # Fresh disposable VM DB restore only
EOF
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        help|--help|-h) show_help; exit 0 ;;
        --version|-V) print_project_version "VaultWarden-OCI" "${PROJECT_ROOT}"; exit 0 ;;
    esac
fi

_require_cli_value() {
    local opt="$1" value="${2-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        log_error "$opt requires a value."
        show_help
        exit 2
    fi
}

_reject_restore_option() {
    local subcmd="$1" opt="$2"
    log_error "Unknown option for '${subcmd}': ${opt}"
    case "$subcmd" in
        list) log_error "Usage: ./restore.sh list [--remote]" ;;
        latest) log_error "Usage: sudo ./restore.sh latest [TYPE] [OPTIONS]" ;;
        interactive) log_error "Usage: sudo ./restore.sh interactive [OPTIONS]" ;;
        inspect) log_error "Usage: sudo ./restore.sh inspect [--remote] [--file FILE] [OPTIONS]" ;;
    esac
    show_help
    exit 2
}

_ORIGINAL_ARGS=("$@")

if [[ $# -eq 0 ]]; then
    show_help
    exit 1
fi

case "$1" in
    latest)
        shift
        USE_LATEST=true
        if [[ $# -gt 0 && "$1" != --* ]]; then
            RESTORE_TYPE="$1"; shift
        fi
        ;;
    list)
        shift
        LIST_ONLY=true
        [[ "${1:-}" == "--remote" ]] && { USE_REMOTE=true; shift; }
        ;;
    interactive)
        shift
        ;;
    inspect)
        shift
        INSPECT_ONLY=true
        ;;
    *)
        log_error "Unknown subcommand: '$1'"
        log_error "Valid subcommands: latest [TYPE] | list [--remote] | interactive | inspect"
        log_error "Run './restore.sh help' for usage."
        show_help
        exit 1
        ;;
esac

# Parse remaining options with subcommand-specific scope. Do not accept restore
# mutating flags for read-only inventory commands.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)             show_help; exit 0 ;;
        --version|-V)          print_project_version "VaultWarden-OCI" "${PROJECT_ROOT}"; exit 0 ;;
        --file)
            [[ "$LIST_ONLY" == "true" ]] && _reject_restore_option list "$1"
            _require_cli_value "$1" "${2-}"
            BACKUP_FILE="$2";        shift 2 ;;
        --remote)              USE_REMOTE=true;          shift ;;
        --key-file)
            [[ "$LIST_ONLY" == "true" ]] && _reject_restore_option list "$1"
            _require_cli_value "$1" "${2-}"
            KEY_FILE_ARG="$2";        shift 2 ;;
        --from-recovery-kit)
            [[ "$LIST_ONLY" == "true" ]] && _reject_restore_option list "$1"
            _require_cli_value "$1" "${2-}"
            RECOVERY_KIT_FILE="$2";   shift 2 ;;
        --no-backup)
            [[ "$LIST_ONLY" == "true" ]] && _reject_restore_option list "$1"
            [[ "$INSPECT_ONLY" == "true" ]] && _reject_restore_option inspect "$1"
            NO_PRE_BACKUP=true;       shift ;;
        --skip-verification)
            [[ "$LIST_ONLY" == "true" ]] && _reject_restore_option list "$1"
            SKIP_VERIFICATION=true;   shift ;;
        --skip-env)
            [[ "$LIST_ONLY" == "true" ]] && _reject_restore_option list "$1"
            [[ "$INSPECT_ONLY" == "true" ]] && _reject_restore_option inspect "$1"
            RESTORE_ENV=false;        shift ;;
        --dry-run)
            [[ "$LIST_ONLY" == "true" ]] && _reject_restore_option list "$1"
            [[ "$INSPECT_ONLY" == "true" ]] && _reject_restore_option inspect "$1"
            DRY_RUN=true;             shift ;;
        --inspect)
            [[ "$LIST_ONLY" == "true" ]] && _reject_restore_option list "$1"
            INSPECT_ONLY=true;        shift ;;
        --force)
            [[ "$LIST_ONLY" == "true" ]] && _reject_restore_option list "$1"
            [[ "$INSPECT_ONLY" == "true" ]] && _reject_restore_option inspect "$1"
            FORCE=true;               shift ;;
        --start-policy)
            [[ "$LIST_ONLY" == "true" ]] && _reject_restore_option list "$1"
            [[ "$INSPECT_ONLY" == "true" ]] && _reject_restore_option inspect "$1"
            if [[ $# -lt 2 || "${2:-}" == --* ]]; then
                log_error "--start-policy requires a value: auto | ask | manual"; show_help; exit 2
            fi
            START_POLICY="$2";        shift 2 ;;
        --start)
            [[ "$LIST_ONLY" == "true" ]] && _reject_restore_option list "$1"
            [[ "$INSPECT_ONLY" == "true" ]] && _reject_restore_option inspect "$1"
            START_POLICY="auto";      shift ;;
        --no-start)
            [[ "$LIST_ONLY" == "true" ]] && _reject_restore_option list "$1"
            [[ "$INSPECT_ONLY" == "true" ]] && _reject_restore_option inspect "$1"
            START_POLICY="manual";    shift ;;
        --rotate-age-key)
            [[ "$LIST_ONLY" == "true" ]] && _reject_restore_option list "$1"
            [[ "$INSPECT_ONLY" == "true" ]] && _reject_restore_option inspect "$1"
            ROTATE_AGE_KEY_POLICY="rotate"; shift ;;
        --no-rotate-age-key)
            [[ "$LIST_ONLY" == "true" ]] && _reject_restore_option list "$1"
            [[ "$INSPECT_ONLY" == "true" ]] && _reject_restore_option inspect "$1"
            ROTATE_AGE_KEY_POLICY="skip"; shift ;;
        *)                     _reject_restore_option "${_ORIGINAL_ARGS[0]}" "$1" ;;
    esac
done

if [[ "$INSPECT_ONLY" == "true" && "$LIST_ONLY" != "true" ]]; then
    [[ "$NO_PRE_BACKUP" == "true" ]] && _reject_restore_option inspect "--no-backup"
    [[ "$RESTORE_ENV" != "true" ]] && _reject_restore_option inspect "--skip-env"
    [[ "$DRY_RUN" == "true" ]] && _reject_restore_option inspect "--dry-run"
    [[ "$FORCE" == "true" ]] && _reject_restore_option inspect "--force"
    [[ -n "$START_POLICY" ]] && _reject_restore_option inspect "--start-policy"
    [[ -n "$ROTATE_AGE_KEY_POLICY" ]] && _reject_restore_option inspect "--rotate-age-key"
fi

case "$START_POLICY" in
    "" ) if [[ -t 0 ]]; then START_POLICY="ask"; else START_POLICY="auto"; fi ;;
    auto|ask|manual) ;;
    *) log_error "Invalid --start-policy: $START_POLICY (expected auto, ask, or manual)"; exit 1 ;;
esac
case "$ROTATE_AGE_KEY_POLICY" in
    ""|rotate|skip) ;;
    *) log_error "Invalid Age rotation policy: $ROTATE_AGE_KEY_POLICY"; exit 1 ;;
esac

# Handle the list + --remote combination.
[[ "$LIST_ONLY" == "true" && "$USE_REMOTE" == "true" ]] && LIST_REMOTE=true

CONTROL_WORKSPACE=""
CONTROL_WORKSPACE_ID=""
PAYLOAD_WORKSPACE=""
PAYLOAD_WORKSPACE_ID=""
PROMOTION_WORKSPACE=""
PROMOTION_WORKSPACE_ID=""
RESTORE_RETAIN_PAYLOAD=false
RESTORE_RETAIN_REASON=""
RESTORE_CLEANUP_DONE=false
RESTORE_EMERGENCY_STAGED_KEY_FILE=""
RESTORE_PREVENT_AUTOSTART=false
: "${RESTORE_PROMPT_TIMEOUT:=300}"
: "${RESTORE_SAVED_ACK_TIMEOUT:=300}"
: "${RESTORE_SAVED_ACK_ATTEMPTS:=3}"

_restore_workspace_identity() {
    stat -c '%d:%i:%u:%a' "$1" 2>/dev/null \
        || stat -f '%d:%i:%u:%Lp' "$1" 2>/dev/null
}

_restore_workspace_is_owned() {
    local path="$1" expected_id="$2" current_id=""
    [[ -n "$path" && -n "$expected_id" && -d "$path" && ! -L "$path" ]] || return 1
    current_id="$(_restore_workspace_identity "$path" 2>/dev/null || true)"
    [[ "$current_id" == "$expected_id" && "$current_id" == *":${EUID}:700" ]]
}

_restore_create_owned_workspace() {
    local path_name="$1" id_name="$2" parent="$3" prefix="$4" fallback="${5:-false}"
    local path="" identity="" old_umask
    [[ -z "${!path_name:-}" && -z "${!id_name:-}" ]] || {
        log_error "Restore workspace output is already populated: ${!path_name:-unset}"
        return 1
    }

    old_umask=$(umask); umask 077
    if [[ -d "$parent" && ! -L "$parent" ]]; then
        path="$(mktemp -d "${parent%/}/${prefix}.XXXXXXXXXX" 2>/dev/null || true)"
    fi
    [[ -n "$path" || "$fallback" != "true" ]] \
        || path="$(mktemp -d -t "${prefix}.XXXXXXXXXX" 2>/dev/null || true)"
    umask "$old_umask"

    [[ -n "$path" && -d "$path" && ! -L "$path" ]] || {
        log_error "Failed to create secure restore workspace on: $parent"
        return 1
    }
    identity="$(_restore_workspace_identity "$path" 2>/dev/null || true)"
    [[ "$identity" == *":${EUID}:700" ]] || {
        log_error "Restore workspace ownership or mode validation failed: $path"
        rmdir -- "$path" 2>/dev/null || true
        return 1
    }
    printf -v "$path_name" '%s' "$path"
    printf -v "$id_name" '%s' "$identity"
}

_restore_remove_owned_workspace() {
    local path="$1" expected_id="$2" label="$3"
    [[ -n "$path" && -n "$expected_id" ]] || return 0
    [[ ! -e "$path" && ! -L "$path" ]] && return 0
    _restore_workspace_is_owned "$path" "$expected_id" || {
        log_error "Refusing to clean unverified, replaced, or permission-mismatched ${label} workspace: $path"
        return 1
    }
    rm -rf -- "$path"
}

_restore_log_retained_workspace() {
    local path="$1" label="$2" reason="${3:-manual recovery}" owner mode
    owner="$(stat -c '%U:%G' "$path" 2>/dev/null || printf 'uid:%s' "$EUID")"
    mode="$(stat -c '%a' "$path" 2>/dev/null || printf 'unknown')"
    log_warn "Restore ${label} staging retained for ${reason}: $path"
    log_warn "Retained staging owner/mode: ${owner} ${mode} (expected mode 700)."
}

_restore_log_retained_payload() {
    _restore_log_retained_workspace "$PAYLOAD_WORKSPACE" payload "${1:-manual recovery}"
}

_restore_retain_payload_for_manual_recovery() {
    local reason="$1"
    _restore_workspace_is_owned "$PAYLOAD_WORKSPACE" "$PAYLOAD_WORKSPACE_ID" || {
        log_error "Cannot safely retain an unverified restore payload workspace: $PAYLOAD_WORKSPACE"
        return 1
    }
    RESTORE_RETAIN_PAYLOAD=true
    RESTORE_RETAIN_REASON="$reason"
}

cleanup() {
    local rc="${1:-$?}" final_rc cleanup_failed=false
    [[ "$RESTORE_CLEANUP_DONE" != "true" ]] || return "$rc"
    RESTORE_CLEANUP_DONE=true

    if [[ "$RESTORE_RETAIN_PAYLOAD" == "true" ]]; then
        _restore_log_retained_payload "${RESTORE_RETAIN_REASON:-manual recovery}"
    elif ! _restore_remove_owned_workspace "$PAYLOAD_WORKSPACE" "$PAYLOAD_WORKSPACE_ID" payload; then
        [[ -z "$PAYLOAD_WORKSPACE" ]] || _restore_log_retained_payload "manual inspection after cleanup refusal"
        cleanup_failed=true
    fi

    if ! _restore_remove_owned_workspace "$PROMOTION_WORKSPACE" "$PROMOTION_WORKSPACE_ID" promotion; then
        [[ -z "$PROMOTION_WORKSPACE" ]] || _restore_log_retained_workspace \
            "$PROMOTION_WORKSPACE" promotion "manual inspection after cleanup refusal"
        cleanup_failed=true
    fi

    if ! _restore_remove_owned_workspace "$CONTROL_WORKSPACE" "$CONTROL_WORKSPACE_ID" control; then
        [[ -z "$CONTROL_WORKSPACE" ]] || _restore_log_retained_workspace \
            "$CONTROL_WORKSPACE" control "manual inspection after cleanup refusal"
        cleanup_failed=true
    fi

    final_rc="$rc"
    [[ "$cleanup_failed" != "true" || "$rc" -ne 0 ]] || final_rc=1
    operation_release "$final_rc" 2>/dev/null || true

    PAYLOAD_WORKSPACE=""; PAYLOAD_WORKSPACE_ID=""
    PROMOTION_WORKSPACE=""; PROMOTION_WORKSPACE_ID=""
    CONTROL_WORKSPACE=""; CONTROL_WORKSPACE_ID=""
    return "$final_rc"
}

_restore_signal_exit() {
    local rc="$1"
    trap - EXIT ERR HUP INT TERM
    cleanup "$rc" || true
    exit "$rc"
}

_restore_exit_cleanup() {
    local rc="${1:-$?}" cleanup_rc=0
    trap - EXIT ERR HUP INT TERM
    cleanup "$rc" || cleanup_rc=$?
    if [[ "$rc" -eq 0 && "$cleanup_rc" -ne 0 ]]; then
        exit "$cleanup_rc"
    fi
    exit "$rc"
}

_restore_print_manual_start_checklist() {
    log_warn "Services may be stopped. Review state before starting."
    log_info "Manual start checklist:"
    log_info "  1. Verify .env"
    log_info "  2. Verify /etc/vaultwarden/*"
    log_info "  3. Verify mounted storage"
    log_info "  4. Verify Cloudflare/DNS and firewall state"
    log_info "  5. sudo ./startup.sh --skip-pull"
    log_info "  6. docker compose ps"
    log_info "  7. docker compose logs --tail=100"
    log_info "  8. sudo ./maintenance.sh health"
}

_restore_should_start_services() {
    case "$START_POLICY" in
        auto) return 0 ;;
        manual)
            _restore_print_manual_start_checklist
            return 1
            ;;
        ask)
            local answer
            read -r -t "$RESTORE_PROMPT_TIMEOUT" -p "Start VaultWarden services now? [yes/no] (default: no): " answer || answer="no"
            case "$answer" in
                y|Y|yes|YES) return 0 ;;
                *) _restore_print_manual_start_checklist; return 1 ;;
            esac
            ;;
    esac
}

_restore_should_rotate_age_key() {
    case "$ROTATE_AGE_KEY_POLICY" in
        rotate|"") ;;
        skip)
            log_warn "Skipping post-restore Age key rotation by explicit operator request."
            return 1
            ;;
    esac
    if [[ "$RESTORE_TYPE" == "emergency" && -t 0 && "$FORCE" != "true" && -z "$ROTATE_AGE_KEY_POLICY" ]]; then
        local answer
        # Legacy prompt text: Emergency capsule contains operational key material. Rotate Age key after restore? [yes/no] (default: yes):
        while true; do
            if ! read -r -t "$RESTORE_PROMPT_TIMEOUT" -p "Emergency capsule: Rotate Age key after restore? Type 'yes' to rotate (recommended) or 'no' to skip: " answer; then
                RESTORE_PREVENT_AUTOSTART=true
                log_error "No explicit Age key rotation decision was received before the prompt closed or timed out."
                log_error "Restore will stop for manual review; timeout/EOF is not treated as 'no'."
                _restore_print_manual_start_checklist
                return 2
            fi
            case "$answer" in
                yes|YES) return 0 ;;
                no|NO)   log_warn "Operator chose not to rotate Age key."; return 1 ;;
                *) log_warn "Type 'yes' or 'no' (no implicit default)." ;;
            esac
        done
    fi
    return 0
}
trap '_restore_exit_cleanup $?' EXIT
trap 'cleanup $?' ERR
trap '_restore_signal_exit 130' INT
trap '_restore_signal_exit 129' HUP
trap '_restore_signal_exit 143' TERM

# Mirrors backup.sh by auto-discovering rclone.conf across five priority locations.

RCLONE_CONFIG_ARG=()
_build_rclone_config_arg() {
    RCLONE_CONFIG_ARG=()
    local cfg_path
    if cfg_path=$(_resolve_rclone_config); then
        validate_rclone_config_path "$cfg_path" || { log_warn "rclone config failed validation: $cfg_path"; return 1; }
        local canonical; canonical=$(realpath -e "$cfg_path")
        RCLONE_CONFIG_ARG=(--config "$canonical")
        log_info "Using rclone config: $canonical"
        return 0
    fi
    return 1
}

# Returns 0 if rclone + remote name + config are all present and valid.
# Sets RCLONE_UNAVAIL_REASON (global) with a human-readable explanation
# whenever it returns 1, so callers can surface a useful message.
#
# Also sets RCLONE_NEEDS_INTERACTIVE_NAME=true when rclone binary
# and config are present but RCLONE_REMOTE_NAME is missing/placeholder.
# This distinguishes "prompt needed" from "rclone not installed" so that
# select_backup_source() can trigger _prompt_rclone_remote_name() instead
# of hiding the REMOTE option when --remote was explicitly requested.
RCLONE_UNAVAIL_REASON=""
_rclone_is_available() {
    RCLONE_UNAVAIL_REASON=""
    RCLONE_NEEDS_INTERACTIVE_NAME=false
    if ! command -v rclone >/dev/null 2>&1; then
        RCLONE_UNAVAIL_REASON="rclone binary not found (install rclone to enable remote backups)"
        return 1
    fi
    local remote_name
    # Resolve remote name from session variable first (set by
    # _prompt_rclone_remote_name() during an emergency restore), then fall
    # back to the .env value.
    remote_name="${_SESSION_RCLONE_REMOTE_NAME:-$(get_config_value "RCLONE_REMOTE_NAME" "")}"
    if [[ -z "$remote_name" || "$remote_name" == "CHANGE_ME_RCLONE_REMOTE" ]]; then
        RCLONE_UNAVAIL_REASON="RCLONE_REMOTE_NAME is not configured in .env (set it to your rclone remote name)"
        # Signal that an interactive prompt can resolve this rather than
        # treating it as a permanent hard failure.
        RCLONE_NEEDS_INTERACTIVE_NAME=true
        return 1
    fi
    if ! _resolve_rclone_config >/dev/null 2>&1; then
        RCLONE_UNAVAIL_REASON="rclone config file not found — set RCLONE_CONFIG in .env or run: rclone config"
        return 1
    fi
    return 0
}

# Emits a single log_warn line explaining why remote is unavailable.
# Call this whenever _rclone_is_available returns 1 and you want to tell
# the operator why the remote option is missing from the menu.
_rclone_diagnose() {
    if [[ -n "$RCLONE_UNAVAIL_REASON" ]]; then
        log_warn "Remote backups unavailable: $RCLONE_UNAVAIL_REASON"
    fi
}

#
# Interactively prompts the operator for the rclone remote name
# (and optionally the remote path) when RCLONE_REMOTE_NAME is not set in
# .env — typically during an emergency restore on a fresh server where .env
# does not yet exist.
#
# Sets _SESSION_RCLONE_REMOTE_NAME and _SESSION_RCLONE_REMOTE_PATH for use
# in this restore session only.  The values are NEVER written to .env; the
# operator's real .env will be restored from the backup itself.
#
# Returns 0 on success, 1 if the user quits or input is invalid on a
# non-interactive (pipe/CI) terminal.
_prompt_rclone_remote_name() {
    # Non-interactive guard: stdin must be a TTY for prompts to work.
    if [[ ! -t 0 ]]; then
        log_error "Cannot prompt for rclone remote name: stdin is not a TTY."
        log_error "Supply RCLONE_REMOTE_NAME in .env or pipe input is not supported for this prompt."
        return 1
    fi

    echo ""
    log_info "RCLONE_REMOTE_NAME is not set in .env (or .env does not exist)."
    log_info "This is normal when restoring to a fresh server."
    echo ""

    local remote_name=""
    while true; do
        read -r -p "  Enter rclone remote name (e.g. 'b2', 'gdrive', 's3'), or q to quit: " remote_name
        [[ "$remote_name" == "q" || "$remote_name" == "Q" ]] && {
            log_info "Restore cancelled."; return 1
        }
        # Validate: non-empty and only safe characters (alphanumeric, hyphen, underscore).
        # Dots are intentionally excluded: rclone remote names do not require them
        # and allowing dots could permit path-traversal sequences if the name is
        # ever embedded in a file path.
        if [[ -z "$remote_name" ]]; then
            log_error "Remote name cannot be empty."; continue
        fi
        if [[ "$remote_name" =~ [^a-zA-Z0-9_-] ]]; then
            log_error "Remote name contains invalid characters. Use only letters, digits, '_', or '-'."
            continue
        fi
        if command -v rclone >/dev/null 2>&1; then
            local configured_remotes
            local _rcfg_arg=()
            local _rcfg_path
            if _rcfg_path=$(_resolve_rclone_config 2>/dev/null); then
                _rcfg_arg=(--config "$_rcfg_path")
            fi
            configured_remotes=$(rclone "${_rcfg_arg[@]}" listremotes 2>/dev/null || true)
            if ! printf '%s\n' "$configured_remotes" | grep -qxF "${remote_name}:"; then
                log_error "Remote '${remote_name}' not found in rclone config."
                if [[ -n "$configured_remotes" ]]; then
                    log_warn "  Configured remotes: $(printf '%s' "$configured_remotes" | tr '\n' ' ')"
                    log_warn "  Run 'rclone config' to add the remote, then retry."
                else
                    log_warn "  No remotes configured. Run 'rclone config' to add one first."
                fi
                continue
            fi
        fi
        break
    done

    # Prompt for the remote path (subfolder), defaulting to vaultwarden_backups.
    local remote_path=""
    read -r -p "  Enter rclone remote path (subfolder, default: vaultwarden_backups): " remote_path
    if [[ -z "$remote_path" ]]; then
        remote_path="vaultwarden_backups"
    fi
    # Strip leading/trailing slashes for consistency.
    remote_path="${remote_path#/}"; remote_path="${remote_path%/}"
    # Validate: reject path-traversal sequences and unsafe characters.
    # Only alphanumeric, hyphen, underscore, dot, and forward-slash are allowed
    # (forward slash separates path segments; dot is safe inside segments).
    if [[ "$remote_path" =~ \.\. || "$remote_path" =~ [^a-zA-Z0-9_./-] ]]; then
        log_error "Remote path contains unsafe characters or '..' sequences. Using default: vaultwarden_backups"
        remote_path="vaultwarden_backups"
    fi

    # Store in session variables; never written to .env.
    _SESSION_RCLONE_REMOTE_NAME="$remote_name"
    _SESSION_RCLONE_REMOTE_PATH="$remote_path"

    log_info "Using rclone remote for this session: ${remote_name}:${remote_path}/"
    return 0
}


_find_latest_backup() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    local best_ts="" best_file="" f ts
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        # Extract YYYYMMDD_HHMMSS from the filename; skip files without it.
        ts=$(basename "$f" | grep -o '[0-9]\{8\}_[0-9]\{6\}' | head -1)
        [[ -n "$ts" ]] || continue
        [[ "$ts" > "$best_ts" ]] && { best_ts="$ts"; best_file="$f"; }
    done < <(find "$dir" -name "*.age" -type f 2>/dev/null)
    [[ -n "$best_file" ]] && { echo "$best_file"; return 0; }
    return 1
}

# shellcheck disable=SC2120  # $1 is an optional --remote flag; called without args when listing local only
list_backups() {
    # List local backups (always), then remote backups when rclone is available
    # or when --remote is explicitly requested.
    local show_remote=false
    [[ "${1:-}" == "--remote" ]] && show_remote=true

    if [[ "$show_remote" == "false" ]]; then
        # Local only
        local types=("db" "full" "emergency")
        for t in "${types[@]}"; do
            echo ""
            log_info "Available ${t} backups (${BACKUP_BASE_DIR}/${t}/):"
            if [[ -d "$BACKUP_BASE_DIR/$t" ]]; then
                find "$BACKUP_BASE_DIR/$t" -name "*.age" -type f \
                    -exec ls -lh {} \; 2>/dev/null | sort -r | head -n 20 || true
            else
                echo "  (none)"
            fi
        done
        return 0
    fi

    log_info "── LOCAL backups (${BACKUP_BASE_DIR}/) ──"
    local types=("db" "full" "emergency")
    for t in "${types[@]}"; do
        echo ""
        log_info "  Available local ${t} backups:"
        if [[ -d "$BACKUP_BASE_DIR/$t" ]]; then
            find "$BACKUP_BASE_DIR/$t" -name "*.age" -type f \
                -exec ls -lh {} \; 2>/dev/null | sort -r | head -n 20 || true
        else
            echo "    (none)"
        fi
    done

    echo ""
    if _rclone_is_available; then
        log_info "── REMOTE backups ──"
        _build_rclone_config_arg || {
            log_warn "Could not build rclone config argument — skipping remote listing."
            return 0
        }
        local remote_name; remote_name="${_SESSION_RCLONE_REMOTE_NAME:-$(get_config_value "RCLONE_REMOTE_NAME" "")}"
        local remote_base_path; remote_base_path="${_SESSION_RCLONE_REMOTE_PATH:-$(get_config_value "RCLONE_REMOTE_PATH" "vaultwarden_backups")}"
        remote_base_path="${remote_base_path#/}"; remote_base_path="${remote_base_path%/}"
        log_info "  Remote: ${remote_name}:${remote_base_path}/"
        for t in "${types[@]}"; do
            local remote_dir="${remote_name}:${remote_base_path}/${t}"
            echo ""
            log_info "  Available remote ${t} backups:"
            rclone lsf "${RCLONE_CONFIG_ARG[@]}" --include "*.age" --files-only \
                "$remote_dir" 2>/dev/null | sort -r | head -n 20 \
                | sed "s|^|    ${remote_dir}/|" || echo "    (none)"
        done
    fi
    return 0
}

list_remote_backups() {
    local remote_name remote_base_path
    remote_name="${_SESSION_RCLONE_REMOTE_NAME:-$(get_config_value "RCLONE_REMOTE_NAME" "")}"
    remote_base_path="${_SESSION_RCLONE_REMOTE_PATH:-$(get_config_value "RCLONE_REMOTE_PATH" "vaultwarden_backups")}"
    remote_base_path="${remote_base_path#/}"; remote_base_path="${remote_base_path%/}"

    _REMOTE_FILES=()
    _REMOTE_TYPES=()
    local global_index=0 any_found=false types=("db" "full" "emergency")

    for t in "${types[@]}"; do
        local remote_dir="${remote_name}:${remote_base_path}/${t}"
        local type_files=()
        local fname
        while IFS= read -r fname; do
            [[ -z "$fname" ]] && continue
            type_files+=("${remote_dir}/${fname}")
        done < <(
            rclone lsf "${RCLONE_CONFIG_ARG[@]}" --include "*.age" --files-only \
                "$remote_dir" 2>/dev/null | sort -r
        )
        [[ ${#type_files[@]} -eq 0 ]] && continue
        any_found=true
        echo ""
        printf '  ── %s backups (remote) ──\n' "${t^^}"
        for remote_file in "${type_files[@]}"; do
            (( ++global_index ))
            _REMOTE_FILES+=("$remote_file")
            _REMOTE_TYPES+=("$t")
            local size_str="?" date_str="unknown"
            local lsl_line
            lsl_line=$(rclone lsl "${RCLONE_CONFIG_ARG[@]}" "$remote_file" 2>/dev/null | head -1 || true)
            if [[ -n "$lsl_line" ]]; then
                local raw_bytes raw_date raw_time
                read -r raw_bytes raw_date raw_time _ <<< "$lsl_line" || true
                if [[ "$raw_bytes" =~ ^[0-9]+$ ]]; then
                    if   (( raw_bytes >= 1073741824 )); then size_str="$(( raw_bytes / 1073741824 ))G"
                    elif (( raw_bytes >= 1048576    )); then size_str="$(( raw_bytes / 1048576    ))M"
                    elif (( raw_bytes >= 1024       )); then size_str="$(( raw_bytes / 1024       ))K"
                    else size_str="${raw_bytes}B"; fi
                fi
                [[ -n "$raw_date" && -n "$raw_time" ]] && date_str="${raw_date} ${raw_time:0:8}"
            fi
            printf '  [%3d]  %-10s  %6s  %s  %s\n' \
                "$global_index" "($t)" "$size_str" "$date_str" "$(basename "$remote_file")"
        done
    done
    echo ""
    if [[ "$any_found" == "false" ]]; then
        log_warn "No remote backup files found under ${remote_name}:${remote_base_path}/"
        return 1
    fi
    return 0
}

pull_remote_backup() {
    local remote_file="$1" btype="$2"
    check_archive_dependencies "$remote_file" "$btype"
    local remote_bytes
    remote_bytes="$(rclone lsl "${RCLONE_CONFIG_ARG[@]}" "$remote_file" 2>/dev/null \
        | awk 'NR == 1 && $1 ~ /^[0-9]+$/ { print $1; exit }')"
    [[ "$remote_bytes" =~ ^[0-9]+$ ]] || {
        log_error "Cannot determine remote backup size before download: $remote_file"
        return 1
    }
    _restore_require_available_bytes "$PAYLOAD_WORKSPACE" \
        "$((remote_bytes * 2 + 64 * 1024 * 1024))" \
        "remote encrypted archive download and initial decryption staging" || return 1

    log_info "Downloading remote backup: $(basename "$remote_file") ..."
    local pull_dir="$PAYLOAD_WORKSPACE/remote_pull"
    mkdir -p "$pull_dir"; chmod 700 "$pull_dir"

    rclone copy "${RCLONE_CONFIG_ARG[@]}" "$remote_file" "$pull_dir/" --checksum 2>&1 || {
        log_error "Failed to download backup from remote: $remote_file"; return 1
    }
    local local_file
    local_file="$pull_dir/$(basename "$remote_file")"
    [[ -s "$local_file" ]] || { log_error "Downloaded file is empty or missing: $local_file"; return 1; }

    rclone copy "${RCLONE_CONFIG_ARG[@]}" "${remote_file}.sha256" "$pull_dir/" --checksum 2>/dev/null || true
    rclone copy "${RCLONE_CONFIG_ARG[@]}" "${remote_file}.meta"   "$pull_dir/" --checksum 2>/dev/null || true

    chmod 600 "$pull_dir"/*.age    2>/dev/null || true
    chmod 600 "$pull_dir"/*.sha256 2>/dev/null || true
    chmod 600 "$pull_dir"/*.meta   2>/dev/null || true

    if [[ "$btype" == "emergency" && ! -s "${local_file}.meta" ]]; then
        log_error "Remote emergency backup is incomplete: restore-critical metadata is missing for $(basename "$local_file")."
        log_error "The matching .meta file is required to select emergency passphrase versus Age-recipient decryption."
        return 1
    fi

    RESTORE_TYPE="$btype"
    local pulled_size
    pulled_size=$(stat -c%s "$local_file" 2>/dev/null || stat -f%z "$local_file" 2>/dev/null || echo 0)
    log_info "Downloaded $(basename "$local_file") ($(( pulled_size / 1024 )) KiB)"

    BACKUP_FILE="$local_file"
    echo ""
    log_info "Remote backup pulled to local staging:"
    log_info "  File: $(basename "$BACKUP_FILE")"
    log_info "  Type: $RESTORE_TYPE"
    log_info "  Path: $BACKUP_FILE"
    echo ""
}

select_backup_source() {
    if [[ "$USE_REMOTE" == "true" ]]; then
        # When --remote was explicitly requested but RCLONE_REMOTE_NAME
        # is missing (e.g. on a fresh server without .env), prompt for it instead
        # of hard-failing.  RCLONE_NEEDS_INTERACTIVE_NAME is set by
        # _rclone_is_available() to distinguish this case from "rclone not installed".
        if ! _rclone_is_available; then
            if [[ "$RCLONE_NEEDS_INTERACTIVE_NAME" == "true" ]]; then
                _prompt_rclone_remote_name || return 1
                # Re-check availability now that the session name is set.
                if ! _rclone_is_available; then
                    _rclone_diagnose
                    return 1
                fi
            else
                _rclone_diagnose
                return 1
            fi
        fi
        _select_remote_backup; return $?
    fi
    if ! _rclone_is_available; then
        _rclone_diagnose
        log_info "No backup specified — listing available local backups:"
        select_backup_interactive; return $?
    fi
    echo ""
    log_info "Where would you like to restore from?"
    printf '  [1]  LOCAL  — backups on this server (%s/)\n' "$BACKUP_BASE_DIR"
    # Use session remote name/path if available (set during interactive prompt).
    local remote_name remote_base_path
    remote_name="${_SESSION_RCLONE_REMOTE_NAME:-$(get_config_value "RCLONE_REMOTE_NAME" "")}"
    remote_base_path="${_SESSION_RCLONE_REMOTE_PATH:-$(get_config_value "RCLONE_REMOTE_PATH" "vaultwarden_backups")}"
    remote_base_path="${remote_base_path#/}"; remote_base_path="${remote_base_path%/}"
    printf '  [2]  REMOTE — %s:%s/\n' "$remote_name" "$remote_base_path"
    echo ""
    local source_choice
    while true; do
        read -r -p "  Enter 1 (local) or 2 (remote), or q to quit: " source_choice
        case "$source_choice" in
            1) select_backup_interactive; return $? ;;
            2) _select_remote_backup;     return $? ;;
            q|Q) log_info "Restore cancelled."; exit 0 ;;
            *) log_error "Invalid choice — enter 1, 2, or q." ;;
        esac
    done
}

_select_remote_backup() {
    log_info "Listing remote backups:"
    _build_rclone_config_arg || {
        log_error "Cannot access remote backups: no valid rclone config found."
        log_error "Options:"
        log_error "  1. Set RCLONE_CONFIG=/path/to/rclone.conf in .env"
        log_error "  2. Copy config to /etc/rclone/rclone.conf (system-wide)"
        log_error "  3. Run: rclone config"
        return 1
    }
    list_remote_backups || return 1
    local total="${#_REMOTE_FILES[@]}" choice
    while true; do
        read -r -p "  Enter number to restore (1-${total}), or q to quit: " choice
        [[ "$choice" == "q" || "$choice" == "Q" ]] && { log_info "Restore cancelled."; exit 0; }
        [[ "$choice" =~ ^[0-9]+$ ]] || { log_error "Invalid input: enter a number between 1 and ${total}."; continue; }
        (( choice >= 1 && choice <= total )) || { log_error "Out of range: enter a number between 1 and ${total}."; continue; }
        break
    done
    pull_remote_backup "${_REMOTE_FILES[$(( choice - 1 ))]}" "${_REMOTE_TYPES[$(( choice - 1 ))]}"
}

list_all_backups_interactive() {
    local types=("db" "full" "emergency")
    local any_found=false
    for t in "${types[@]}"; do
        local dir="$BACKUP_BASE_DIR/$t"
        [[ -d "$dir" ]] || continue
        local files=()
        while IFS= read -r f; do files+=("$f"); done \
            < <(find "$dir" -name "*.age" -type f 2>/dev/null | sort -r)
        [[ ${#files[@]} -eq 0 ]] && continue
        any_found=true
        echo ""
        printf '  ── %s backups ──\n' "${t^^}"
        local i=0
        for f in "${files[@]}"; do
            (( ++i ))
            local size_str="?"
            local sz; sz=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
            if [[ "$sz" =~ ^[0-9]+$ ]]; then
                if   (( sz >= 1073741824 )); then size_str="$(( sz / 1073741824 ))G"
                elif (( sz >= 1048576    )); then size_str="$(( sz / 1048576    ))M"
                elif (( sz >= 1024       )); then size_str="$(( sz / 1024       ))K"
                else size_str="${sz}B"; fi
            fi
            local mtime_str; mtime_str=$(stat -c "%y" "$f" 2>/dev/null | cut -c1-19 || \
                                         stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$f" 2>/dev/null || echo "unknown")
            printf '  [%3d]  %-10s  %6s  %s  %s\n' \
                "$i" "($t)" "$size_str" "$mtime_str" "$(basename "$f")"
            _LOCAL_FILES+=("$f")
            _LOCAL_TYPES+=("$t")
        done
    done
    [[ "$any_found" == "false" ]] && { log_warn "No local backup files found under $BACKUP_BASE_DIR/"; return 1; }
    return 0
}

_LOCAL_FILES=()
_LOCAL_TYPES=()

select_backup_interactive() {
    _LOCAL_FILES=()
    _LOCAL_TYPES=()
    # Print available backup listing before the selection prompt (ux.md #31).
    log_info "Available local backups:"
    if ! list_backups 2>/dev/null; then
        log_warn "No local backups found in ${BACKUP_BASE_DIR} — you may still enter a path manually."
    fi
    list_all_backups_interactive || return 1
    local total="${#_LOCAL_FILES[@]}" choice
    echo ""
    while true; do
        read -r -p "  Enter number to restore (1-${total}), or q to quit: " choice
        [[ "$choice" == "q" || "$choice" == "Q" ]] && { log_info "Restore cancelled."; exit 0; }
        [[ "$choice" =~ ^[0-9]+$ ]] || { log_error "Invalid input: enter a number between 1 and ${total}."; continue; }
        (( choice >= 1 && choice <= total )) || { log_error "Out of range: enter a number between 1 and ${total}."; continue; }
        break
    done
    BACKUP_FILE="${_LOCAL_FILES[$(( choice - 1 ))]}"
    RESTORE_TYPE="${_LOCAL_TYPES[$(( choice - 1 ))]}"
    log_info "Selected: $(basename "$BACKUP_FILE") (type: $RESTORE_TYPE)"
}

resolve_backup_file() {
    if [[ "$USE_LATEST" == "true" ]]; then
        if [[ -n "$RESTORE_TYPE" ]]; then
            BACKUP_FILE="$(_find_latest_backup "$BACKUP_BASE_DIR/$RESTORE_TYPE" || true)"
            [[ -n "$BACKUP_FILE" ]] || { log_error "No backups found for type: $RESTORE_TYPE (looked in $BACKUP_BASE_DIR/$RESTORE_TYPE)"; return 1; }
            return 0
        fi
        local best="" best_ts="" candidate ts
        for t in db full emergency; do
            candidate="$(_find_latest_backup "$BACKUP_BASE_DIR/$t" || true)"
            if [[ -n "$candidate" ]]; then
                ts=$(basename "$candidate" | grep -o '[0-9]\{8\}_[0-9]\{6\}' | head -1)
                [[ -n "$ts" ]] || continue
                if [[ "$ts" > "$best_ts" ]]; then best_ts="$ts"; best="$candidate"; RESTORE_TYPE="$t"; fi
            fi
        done
        [[ -n "$best" ]] || { log_error "No backups found in any backup directory under $BACKUP_BASE_DIR/"; return 1; }
        BACKUP_FILE="$best"; return 0
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
            log_error "Cannot determine backup type — use: restore.sh latest db|full|emergency"; return 1
        }
        return 0
    fi

    select_backup_source || return 1
    return 0
}

# Stages a raw Age private-key line in the normalized file format expected
# by check_age_key: public-key comment followed by the private identity.
_stage_restore_age_key_line() {
    local age_key_line="$1" staged_key="$2"
    local stage_dir raw_key normalized_key public_key old_umask

    [[ "$age_key_line" == AGE-SECRET-KEY-1* ]] || return 1
    stage_dir="$(dirname "$staged_key")"
    old_umask=$(umask); umask 077
    mkdir -p "$stage_dir" || { umask "$old_umask"; return 1; }
    raw_key=$(mktemp "$stage_dir/.raw-age-key.XXXXXX") \
        || { umask "$old_umask"; return 1; }
    normalized_key=$(mktemp "$stage_dir/.normalized-age-key.XXXXXX") \
        || { rm -f "$raw_key"; umask "$old_umask"; return 1; }
    umask "$old_umask"
    chmod 700 "$stage_dir" || { rm -f "$raw_key" "$normalized_key"; return 1; }
    chmod 600 "$raw_key" "$normalized_key" || { rm -f "$raw_key" "$normalized_key"; return 1; }

    printf '%s\n' "$age_key_line" > "$raw_key" || {
        rm -f "$raw_key" "$normalized_key"
        return 1
    }
    public_key=$(age-keygen -y "$raw_key" 2>/dev/null) || {
        rm -f "$raw_key" "$normalized_key"
        return 1
    }
    [[ "$public_key" =~ ^age1[a-z0-9]{58}$ ]] || {
        rm -f "$raw_key" "$normalized_key"
        return 1
    }
    printf '# public key: %s\n%s\n' "$public_key" "$age_key_line" > "$normalized_key" || {
        rm -f "$raw_key" "$normalized_key"
        return 1
    }
    rm -f "$raw_key"
    mv -f "$normalized_key" "$staged_key" || {
        rm -f "$normalized_key"
        return 1
    }
    chmod 600 "$staged_key" || { rm -f "$staged_key"; return 1; }

    if ! TMPDIR="$CONTROL_WORKSPACE" check_age_key "$staged_key"; then
        rm -f "$staged_key"
        return 1
    fi
}

#
# Reads a plaintext recovery-kit file, extracts the Age private key line
# (AGE-SECRET-KEY-1...), writes it to a chmod-600 temp file inside
# CONTROL_WORKSPACE, and sets KEY_FILE_ARG so the existing _prompt_age_key()
# priority chain picks it up non-interactively.
#
# The recovery-kit file is the plaintext document produced at setup time
# containing (at minimum) one line beginning with AGE-SECRET-KEY-1.
# Any line format is accepted — the function greps for the key line so
# surrounding prose, labels, or blank lines are all ignored.
#
# Priority: --from-recovery-kit > RESTORE_RECOVERY_KIT_FILE env var.
# Must be called after CONTROL_WORKSPACE is initialised (i.e. inside main()).
#
# Returns 0 on success, 1 on any validation failure.
_load_recovery_kit() {
    # Resolve the kit file path: CLI flag takes priority over env var.
    local kit_path="${RECOVERY_KIT_FILE:-${RESTORE_RECOVERY_KIT_FILE:-}}"
    [[ -z "$kit_path" ]] && return 0   # nothing to do

    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Loading Age key from recovery kit: $kit_path"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # --- Validate the file path ----------------------------------------
    [[ -f "$kit_path" ]] || {
        log_error "Recovery kit file not found: $kit_path"
        return 1
    }

    # Resolve to canonical path and reject symlinks pointing outside safe roots.
    local canonical_kit
    canonical_kit=$(realpath -e "$kit_path" 2>/dev/null) || {
        log_error "Cannot resolve recovery kit path: $kit_path"
        return 1
    }

    # Reject world-readable kit files — they should be owner-read-only.
    local kit_perms
    kit_perms=$(stat -c "%a" "$canonical_kit" 2>/dev/null || \
                stat -f "%Lp" "$canonical_kit" 2>/dev/null || echo "644")
    if (( (8#$kit_perms & 8#044) != 0 )); then
        log_warn "Recovery kit file has broad permissions (${kit_perms}): $canonical_kit"
        log_warn "Recommended: chmod 600 '$canonical_kit'"
        # Warn only — do not abort; operator may be reading from a mounted USB.
    fi

    # --- Extract the Age private key line --------------------------------
    local age_key_line
    age_key_line=$(grep -m1 '^AGE-SECRET-KEY-1' "$canonical_kit" 2>/dev/null || true)

    if [[ -z "$age_key_line" ]]; then
        log_error "No AGE-SECRET-KEY-1 line found in recovery kit: $canonical_kit"
        log_error "Ensure the file contains the private key line from your age-key.txt."
        return 1
    fi

    # Trim any trailing whitespace or carriage returns (Windows line endings).
    age_key_line="${age_key_line%"${age_key_line##*[![:space:]]}"}"
    age_key_line="${age_key_line//$'\r'/}"

    if [[ "$age_key_line" != AGE-SECRET-KEY-1* ]]; then
        log_error "Extracted key does not match expected AGE-SECRET-KEY-1 format."
        return 1
    fi

    # --- Normalize and validate inside the control workspace --------------
    local staged_key="$CONTROL_WORKSPACE/kit_stage/recovery-kit-age-key.txt"
    if ! _stage_restore_age_key_line "$age_key_line" "$staged_key"; then
        log_error "Age key from recovery kit failed validation."
        log_error "The key may be truncated, corrupted, or from a different installation."
        return 1
    fi

    # Wire into the existing key-resolution priority chain.
    KEY_FILE_ARG="$staged_key"
    log_success "Age key loaded from recovery kit and staged for decryption."
    log_info    "  Kit file:  $canonical_kit"
    log_info    "  Key prefix: ${age_key_line:0:24}..."
    return 0
}

#
# Resolves the age private key to use for decrypting this specific backup.
# Priority order (best-practice: restoring a backup may require an OLD key):
#
#   1. --key-file <path>             (CLI flag — most explicit)
#   2. RESTORE_AGE_KEY_FILE          (env var — scripted/CI pipelines)
#   3. --from-recovery-kit / RESTORE_RECOVERY_KIT_FILE
#                                    (handled by _load_recovery_kit() which
#                                     sets KEY_FILE_ARG before this function
#                                     is called — resolves via priority 1)
#   4. Interactive prompt             (operator pastes/types the key; no echo on TTY)
#   5. Press Enter blank              (fall back to the currently configured key)
#
# The key is written to a chmod-600 temp file inside CONTROL_WORKSPACE so
# that cleanup() always wipes it — the private key never persists on disk
# beyond the lifetime of this process.
#
# Sets global RESTORE_DECRYPT_AGE_KEY_FILE to the path of the resolved key file.
# Returns 0 on success, 1 on validation failure.
#
# Validation uses the non-mutating explicit-path Age key check. Any small
# round-trip diagnostic file is constrained to CONTROL_WORKSPACE.
_prompt_age_key() {
    local configured_key="$1"  # the key currently in .env (fallback)

    # Priority 1 & 2: non-interactive supply
    local supplied_path=""
    if [[ -n "$KEY_FILE_ARG" ]]; then
        supplied_path="$KEY_FILE_ARG"
        log_info "Age key supplied via --key-file (or --from-recovery-kit): $supplied_path"
    elif [[ -n "${RESTORE_AGE_KEY_FILE:-}" ]]; then
        supplied_path="$RESTORE_AGE_KEY_FILE"
        log_info "Age key supplied via RESTORE_AGE_KEY_FILE: $supplied_path"
    fi

    if [[ -n "$supplied_path" ]]; then
        [[ -f "$supplied_path" ]] || {
            log_error "Supplied age key file not found: $supplied_path"; return 1
        }
        if ! TMPDIR="$CONTROL_WORKSPACE" check_age_key "$supplied_path"; then
            log_error "Supplied age key failed validation: $supplied_path"
            return 1
        fi
        RESTORE_DECRYPT_AGE_KEY_FILE="$supplied_path"
        log_success "Age key validated."
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would prompt for age private key (using configured key: $configured_key)"
        RESTORE_DECRYPT_AGE_KEY_FILE="$configured_key"
        return 0
    fi

    echo ""
    # For normal same-server restore, press Enter to use the currently configured key.
    # Only paste an AGE-SECRET-KEY-1... value if this backup was encrypted with an older/offline key.
    log_info "── Age Key Required ──────────────────────────────────────────────"
    log_info "Configured key: $configured_key"
    log_info "• Enter = use configured key above (normal same-server restore)"
    log_info "• Paste AGE-SECRET-KEY-1... only if this backup used a different key"
    log_info "──────────────────────────────────────────────────────────────────"
    echo ""

    local key_input="" attempt
    for attempt in 1 2 3; do
        key_input=""
        if [[ -t 0 ]]; then
            _age_key_countdown &
            local _countdown_pid=$!
            IFS= read -r -s -t 300 -p "  Age private key (hidden): " key_input
            local _read_rc=$?
            kill "$_countdown_pid" 2>/dev/null || true
            wait "$_countdown_pid" 2>/dev/null || true
            printf '\r%80s\r' '' >&2
            echo ""
            if (( _read_rc != 0 )); then
                log_error "Timed out waiting for Age key (300s). Re-run restore.sh to retry."
                exit 1
            fi
        else
            key_input=""
        fi

        if [[ -z "$key_input" ]]; then
            log_info "  No key entered — using configured key: $configured_key"
            [[ -f "$configured_key" ]] || { log_error "Configured key not found: $configured_key"; return 1; }
            RESTORE_DECRYPT_AGE_KEY_FILE="$configured_key"
            return 0
        fi

        key_input="${key_input#"${key_input%%[![:space:]]*}"}"
        key_input="${key_input%"${key_input##*[![:space:]]}"}"

        if [[ "$key_input" != AGE-SECRET-KEY-1* ]]; then
            log_error "Input does not look like an age private key (must start with AGE-SECRET-KEY-1)."
        else
            local staged_key_file="$CONTROL_WORKSPACE/key_stage/restore-age-key.txt"
            if _stage_restore_age_key_line "$key_input" "$staged_key_file"; then
                RESTORE_DECRYPT_AGE_KEY_FILE="$staged_key_file"
                log_success "Age key accepted and staged for decryption."
                return 0
            fi
        fi

        if (( attempt < 3 )); then
            log_warn "Key validation failed (attempt ${attempt}/3). Press Enter for configured key"
            log_warn "or paste a different AGE-SECRET-KEY-1... key:"
        fi
    done

    log_error "3 failed key attempts. Re-run restore.sh to start over."
    exit 1


}

#
# Prune old Age private key backups — keep only 2 most recent.
# Old key material has no operational value once a new key is active and
# backed up; retaining it indefinitely increases exposure if the secrets/keys/
# directory is ever compromised.
_prune_old_age_keys() {
    local keys_dir="$1"
    [[ -d "$keys_dir" ]] || return 0
    local -a old_keys
    mapfile -t old_keys < <(find "$keys_dir" -maxdepth 1 -name "age-key.txt.pre-rotate-*" -type f \
        | sort)
    local count=${#old_keys[@]}
    if (( count > 2 )); then
        local delete_count=$(( count - 2 ))
        for (( i=0; i<delete_count; i++ )); do
            log_info "Pruning old Age key backup: $(basename "${old_keys[$i]}")"
            rm -f "${old_keys[$i]}" 2>/dev/null || log_warn "Failed to prune: ${old_keys[$i]}"
        done
    fi
}

#
# Generates a fresh age key pair and installs it to every configured location
# so the stack is immediately usable with the new key after the restore.
#
# Install locations (in order):
#   1. secrets/keys/age-key.txt  (project-local copy; required for all modes)
#   2. /etc/vaultwarden/age-key.txt  (systemd canonical; if it already exists)
#   3. SOPS_AGE_KEY_FILE in .env updated to the canonical path
#   4. SOPS_AGE_KEY_FILE in /etc/vaultwarden/vaultwarden.env (if present)
#
# Writes atomically: generates to a temp file, validates, then moves.
# Returns 0 on success, 1 on any failure.
# Sets ROTATED_KEY_FILE and ROTATED_PUB_KEY for display.
ROTATED_KEY_FILE=""
ROTATED_PUB_KEY=""
ROTATED_KIT_FILE=""

_rotate_age_key() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would generate a new age key pair and install to:"
        log_info "  $PROJECT_ROOT/secrets/keys/age-key.txt"
        [[ -f "/etc/vaultwarden/age-key.txt" ]] && \
            log_info "  /etc/vaultwarden/age-key.txt"
        log_info "  SOPS_AGE_KEY_FILE updated in .env"
        return 0
    fi

    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Rotating age encryption key post-restore..."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # ------------------------------------------------------------------
    # 1. Generate new key inside the small secure control workspace.
    local new_key_tmp="$CONTROL_WORKSPACE/new-age-key.txt"

    local _saved_umask; _saved_umask=$(umask)
    umask 077
    local _keygen_rc=0
    age-keygen -o "$new_key_tmp" 2>/dev/null || _keygen_rc=$?
    umask "$_saved_umask"

    if (( _keygen_rc != 0 )) || [[ ! -s "$new_key_tmp" ]]; then
        log_error "age-keygen failed (rc: ${_keygen_rc})"
        return 1
    fi
    chmod 600 "$new_key_tmp"

    # Validate the new key before installing anywhere.
    # simple_verify_age_key() performs permissions + ownership +
    # crypto roundtrip; SOPS_AGE_KEY_FILE is set inline so it resolves
    # to the temp path directly without running _resolve_age_key().
    if ! SOPS_AGE_KEY_FILE="$new_key_tmp" simple_verify_age_key; then
        log_error "Newly generated key failed validation — aborting key rotation."
        return 1
    fi

    _require_sops_for_rekey || return 1

    local secrets_file="${STATE_DIR}/secrets/secrets.yaml"
    local local_key_dir="$PROJECT_ROOT/secrets/keys"
    local local_key_file="$local_key_dir/age-key.txt"
    local systemd_key="/etc/vaultwarden/age-key.txt"
    local canonical_key="$systemd_key"
    local env_file="$PROJECT_ROOT/.env"
    local systemd_env="/etc/vaultwarden/vaultwarden.env"
    local install_env="${STATE_DIR}/config/install.env"
    local sops_policy_file="${PROJECT_ROOT}/.sops.yaml"
    local staged_dir="$CONTROL_WORKSPACE/age-rotation-staged"
    local backup_dir="$CONTROL_WORKSPACE/age-rotation-backups"
    local new_recipient="" offline_recipient="" policy_tmp="" cipher_tmp=""
    local staged_local_key="" staged_systemd_key="" staged_env="" staged_systemd_env="" staged_install_env=""
    local promoted_any=false rotation_committed=false

    _restore_rotation_backup() {
        local existed_file="$1" backup_file="$2" target_file="$3"
        if [[ -f "$existed_file" ]]; then
            cp -f "$backup_file" "$target_file" 2>/dev/null || rm -f "$target_file" 2>/dev/null || true
        else
            rm -f "$target_file" 2>/dev/null || true
        fi
    }

    _rollback_rotation() {
        [[ "$promoted_any" == "true" && "$rotation_committed" != "true" ]] || return 0
        log_warn "Rolling back post-restore Age/SOPS rotation artifacts..."
        _restore_rotation_backup "$backup_dir/secrets.exists" "$backup_dir/secrets.yaml" "$secrets_file"
        _restore_rotation_backup "$backup_dir/policy.exists" "$backup_dir/sops.yaml" "$sops_policy_file"
        _restore_rotation_backup "$backup_dir/systemd-key.exists" "$backup_dir/systemd-age-key.txt" "$systemd_key"
        _restore_rotation_backup "$backup_dir/local-key.exists" "$backup_dir/local-age-key.txt" "$local_key_file"
        _restore_rotation_backup "$backup_dir/repo-env.exists" "$backup_dir/repo.env" "$env_file"
        _restore_rotation_backup "$backup_dir/systemd-env.exists" "$backup_dir/vaultwarden.env" "$systemd_env"
        _restore_rotation_backup "$backup_dir/install-env.exists" "$backup_dir/install.env" "$install_env"
        auto_fix_critical_permissions "$PROJECT_ROOT" || true
    }

    _stage_env_with_key() {
        local source_file="$1" staged_file="$2" key_path="$3"
        [[ -f "$source_file" ]] || return 0
        awk -F= -v k="SOPS_AGE_KEY_FILE" -v v="$key_path" '
            BEGIN { done = 0 }
            $1 == k { print k "=" v; done = 1; next }
            { print }
            END { if (!done) print k "=" v }
        ' "$source_file" > "$staged_file" || return 1
        chmod --reference="$source_file" "$staged_file" 2>/dev/null || chmod 600 "$staged_file" || return 1
        chown --reference="$source_file" "$staged_file" 2>/dev/null || true
    }

    mkdir -p "$staged_dir" "$backup_dir" || { log_error "Failed to create key rotation staging directory."; return 1; }
    chmod 700 "$staged_dir" "$backup_dir" 2>/dev/null || true

    if [[ -f "$secrets_file" ]]; then
        new_recipient="$(age-keygen -y "$new_key_tmp" 2>/dev/null || true)"
        [[ "$new_recipient" =~ ^age1[a-z0-9]{58}$ ]] || {
            log_error "New age key did not produce a valid public recipient."
            return 1
        }
        if [[ -f "${STATE_DIR}/config/dr-manifest.env" ]]; then
            offline_recipient="$(grep -m1 '^OFFLINE_AGE_RECIPIENT=' "${STATE_DIR}/config/dr-manifest.env" | cut -d= -f2- | tr -d "\"'" || true)"
        fi
        if [[ -z "$offline_recipient" && -f "$sops_policy_file" ]]; then
            offline_recipient="$(grep -Eo 'age1[a-z0-9]{58}' "$sops_policy_file" | grep -vF "$new_recipient" | head -1 || true)"
        fi
        [[ -z "$offline_recipient" || "$offline_recipient" =~ ^age1[a-z0-9]{58}$ ]] || offline_recipient=""

        policy_tmp="$staged_dir/.sops.yaml"
        cipher_tmp="$staged_dir/secrets.yaml"
        cp -f "$secrets_file" "$cipher_tmp" || { log_error "Failed to stage restored secrets for rekey."; return 1; }
        chmod 600 "$cipher_tmp" 2>/dev/null || true
        {
            echo "creation_rules:"
            echo "  - path_regex: '.*\\.yaml$'"
            if [[ -n "$offline_recipient" ]]; then
                echo "    age: \"${new_recipient},${offline_recipient}\""
            else
                echo "    age: \"${new_recipient}\""
            fi
        } > "$policy_tmp" || { log_error "Failed to stage SOPS policy."; return 1; }
        chmod 600 "$policy_tmp" 2>/dev/null || true
        if [[ -z "${RESTORE_REKEY_SOURCE_AGE_KEY_FILE:-}" ]]; then
            log_error "Restore rekey source Age key was not resolved; refusing to update SOPS keys."
            return 1
        fi
        if ! SOPS_AGE_KEY_FILE="$RESTORE_REKEY_SOURCE_AGE_KEY_FILE" sops --config "$policy_tmp" updatekeys --yes "$cipher_tmp"; then
            log_error "SOPS rekey failed — live key paths were not changed."
            return 1
        fi
        if ! SOPS_AGE_KEY_FILE="$new_key_tmp" sops -d "$cipher_tmp" >/dev/null; then
            log_error "Rekey validation failed — live key paths were not changed."
            return 1
        fi
    else
        log_warn "  No restored secrets.yaml found at $secrets_file; rotating key paths only."
        policy_tmp=""
        cipher_tmp=""
    fi

    staged_local_key="$staged_dir/local-age-key.txt"
    staged_systemd_key="$staged_dir/systemd-age-key.txt"
    staged_env="$staged_dir/repo.env"
    staged_systemd_env="$staged_dir/vaultwarden.env"
    staged_install_env="$staged_dir/install.env"

    install -d -m 700 "$local_key_dir" || { log_error "Failed to prepare repo-local key directory."; return 1; }
    install -d -m 700 -o root -g root "$(dirname "$systemd_key")" || { log_error "Failed to prepare /etc/vaultwarden."; return 1; }
    install -m 600 "$new_key_tmp" "$staged_local_key" || { log_error "Failed to stage repo-local key."; return 1; }
    install -m 600 -o root -g root "$new_key_tmp" "$staged_systemd_key" || { log_error "Failed to stage root-operated key."; return 1; }
    _stage_env_with_key "$env_file" "$staged_env" "$canonical_key" || { log_error "Failed to stage repo .env update."; return 1; }
    _stage_env_with_key "$systemd_env" "$staged_systemd_env" "$canonical_key" || { log_error "Failed to stage /etc/vaultwarden/vaultwarden.env update."; return 1; }
    _stage_env_with_key "$install_env" "$staged_install_env" "$canonical_key" || { log_error "Failed to stage install.env update."; return 1; }

    [[ -f "$secrets_file" ]] && { cp -f "$secrets_file" "$backup_dir/secrets.yaml" || return 1; : > "$backup_dir/secrets.exists"; }
    [[ -f "$sops_policy_file" ]] && { cp -f "$sops_policy_file" "$backup_dir/sops.yaml" || return 1; : > "$backup_dir/policy.exists"; }
    [[ -f "$systemd_key" ]] && { cp -f "$systemd_key" "$backup_dir/systemd-age-key.txt" || return 1; : > "$backup_dir/systemd-key.exists"; }
    [[ -f "$local_key_file" ]] && { cp -f "$local_key_file" "$backup_dir/local-age-key.txt" || return 1; : > "$backup_dir/local-key.exists"; }
    [[ -f "$env_file" ]] && { cp -f "$env_file" "$backup_dir/repo.env" || return 1; : > "$backup_dir/repo-env.exists"; }
    [[ -f "$systemd_env" ]] && { cp -f "$systemd_env" "$backup_dir/vaultwarden.env" || return 1; : > "$backup_dir/systemd-env.exists"; }
    [[ -f "$install_env" ]] && { cp -f "$install_env" "$backup_dir/install.env" || return 1; : > "$backup_dir/install-env.exists"; }

    if [[ -f "$local_key_file" ]]; then
        local backup_ts; backup_ts=$(date +%Y%m%d-%H%M%S)
        if cp -f "$local_key_file" "${local_key_file}.pre-rotate-${backup_ts}"; then
            chmod 600 "${local_key_file}.pre-rotate-${backup_ts}" 2>/dev/null || true
            log_info "  Previous key backed up: age-key.txt.pre-rotate-${backup_ts}"
        else
            log_warn "  Could not create pre-rotate repo-local key backup; transactional rollback backup is still staged."
        fi
    fi

    if ! cp -f "$staged_local_key" "$local_key_file"; then _rollback_rotation; return 1; fi
    promoted_any=true
    chmod 600 "$local_key_file" 2>/dev/null || true
    if ! install -m 600 -o root -g root "$staged_systemd_key" "$systemd_key"; then _rollback_rotation; return 1; fi
    if [[ -f "$staged_env" ]] && ! cp -f "$staged_env" "$env_file"; then _rollback_rotation; return 1; fi
    if [[ -f "$staged_systemd_env" ]] && ! install -m 600 -o root -g root "$staged_systemd_env" "$systemd_env"; then _rollback_rotation; return 1; fi
    if [[ -f "$staged_install_env" ]] && ! install -m 600 -o root -g root "$staged_install_env" "$install_env"; then _rollback_rotation; return 1; fi
    if [[ -n "$cipher_tmp" ]] && ! install -m 600 -o root -g root "$cipher_tmp" "$secrets_file"; then _rollback_rotation; return 1; fi
    if [[ -n "$policy_tmp" ]] && ! install -m 644 "$policy_tmp" "$sops_policy_file"; then _rollback_rotation; return 1; fi
    if [[ -n "$cipher_tmp" ]] && ! SOPS_AGE_KEY_FILE="$systemd_key" sops -d "$secrets_file" >/dev/null; then
        log_error "Post-promotion SOPS validation failed."
        _rollback_rotation
        return 1
    fi
    rotation_committed=true
    log_success "  New key installed: $local_key_file"
    log_success "  New key installed: $systemd_key"
    [[ -f "$staged_env" ]] && log_success "  SOPS_AGE_KEY_FILE=${canonical_key} written to .env"
    [[ -f "$staged_systemd_env" ]] && log_success "  SOPS_AGE_KEY_FILE=${canonical_key} written to $systemd_env"
    [[ -f "$staged_install_env" ]] && log_success "  SOPS_AGE_KEY_FILE=${canonical_key} written to $install_env"
    [[ -n "$cipher_tmp" ]] && log_success "  Restored secrets rekeyed for the new operational key."

    ROTATED_KEY_FILE="$local_key_file"

    # Write a local recovery-kit file so the operator has a copy
    # that survives independently of secrets/keys/
    local kit_ts kit_file
    kit_ts="$(date -u +%Y%m%dT%H%M%SZ)"
    kit_file="$(publish_age_rotation_handoff "$new_key_tmp" "$new_recipient" "$kit_ts")" || {
      log_error "Could not publish the protected post-restore Age handoff."
      return 1
    }
    ROTATED_KIT_FILE="$kit_file"
    log_warn "Protected recovery handoff saved: $kit_file"
    log_warn "Copy it offline, verify it, then delete the host copy."

    # 6. Derive public key for display
    ROTATED_PUB_KEY=$(grep -m1 '^# public key:' "$local_key_file" | sed 's/^# public key: //' || true)
    if [[ -z "$ROTATED_PUB_KEY" ]]; then
        ROTATED_PUB_KEY=$(age-keygen -y "$local_key_file" 2>/dev/null || true)
    fi

    log_success "Key rotation complete."

    # 7. Prune old Age private key backups — keep only 2 most recent
    _prune_old_age_keys "$local_key_dir"

    return 0
}

# Prints the new age key in a prominent banner identical to what setup.sh
# would show on first install.  Requires the operator to press Enter to
# acknowledge before services start (unless --force is passed).
_display_new_key() {
  # VWOCI-PRR-PATCH-01: keep the existing acknowledgement/startup safety gate,
  # but hand off the private identity only through the protected root file.
  [[ "$DRY_RUN" == "true" ]] && return 0
  [[ -z "$ROTATED_KEY_FILE" ]] && return 0

  if [[ -z "${ROTATED_KIT_FILE:-}" || ! -s "$ROTATED_KIT_FILE" ]]; then
    RESTORE_PREVENT_AUTOSTART=true
    log_error "The rotated Age identity was not committed to a protected recovery handoff."
    log_error "Restore services will remain stopped for manual review."
    _restore_print_manual_start_checklist
    return 1
  fi

  echo ""
  echo " ╔══════════════════════════════════════════════════════════╗"
  echo " ║          NEW AGE KEY — PROTECTED HANDOFF SAVED          ║"
  echo " ╚══════════════════════════════════════════════════════════╝"
  echo ""
  log_warn "A new operational Age key was generated as part of this restore."
  log_warn "All future backups will use the new recipient."
  log_info "Protected handoff: $ROTATED_KIT_FILE"
  log_info "Owner/mode: root:root 0600"
  log_info "Public recipient: ${ROTATED_PUB_KEY:-unavailable}"
  log_info "Primary key path: $ROTATED_KEY_FILE"
  [[ -f "/etc/vaultwarden/age-key.txt" ]] && \
    log_info "systemd key path: /etc/vaultwarden/age-key.txt"
  log_info "No private key material was written to terminal output."
  log_warn "Copy the protected handoff offline, verify it, then delete the host copy."
  echo ""

  if [[ "$FORCE" != "true" ]]; then
    local _confirm="" _attempt=1
    while (( _attempt <= RESTORE_SAVED_ACK_ATTEMPTS )); do
      if ! read -r -t "${RESTORE_SAVED_ACK_TIMEOUT}" \
        -p " Type SAVED (all caps) after recording the protected handoff: " _confirm; then
        _restore_print_key_ack_abort_guidance
        return 1
      fi
      if [[ "$_confirm" == "SAVED" ]]; then
        echo ""
        return 0
      fi
      log_warn "Please type exactly: SAVED"
      _attempt=$(( _attempt + 1 ))
    done
    _restore_print_key_ack_abort_guidance
    return 1
  fi
  echo ""
  return 0
}

_restore_print_key_ack_abort_guidance() {
    RESTORE_PREVENT_AUTOSTART=true
    log_error "The new Age key was not acknowledged with SAVED."
    log_error "Restore/key work may already have completed, so services will remain stopped for manual review."
    log_info "New Age key path: ${ROTATED_KEY_FILE:-unknown}"
    if [[ -n "${ROTATED_KIT_FILE:-}" ]]; then
        log_info "Recovery kit path: ${ROTATED_KIT_FILE}"
    fi
    log_warn "Save and verify the new key before starting services."
    _restore_print_manual_start_checklist
}

read_meta_field() {
    local meta_file="$1" field="$2" default="${3:-}"
    if [[ -f "$meta_file" ]]; then
        local val; val=$(grep -m1 "^${field}=" "$meta_file" | cut -d= -f2- || true)
        echo "${val:-$default}"
    else
        echo "$default"
    fi
}

# Checks archive-specific restore tools once the selected backup path is known.
check_archive_dependencies() {
    local backup_file="$1" restore_type="${2:-${RESTORE_TYPE:-}}"
    local -a hard=()
    local missing_hard=()
    case "$backup_file" in
        *.tar.zst.age|*.zst.age|*.tar.zst) hard+=(zstd) ;;
    esac
    if [[ "${INSPECT_ONLY:-false}" != "true" ]]; then
        if [[ "${ROTATE_AGE_KEY_POLICY:-}" != "skip" ]]; then
            hard+=(sops)
        fi
        if [[ "$restore_type" =~ ^(full|emergency)$ ]] && _path_is_mountpoint "$STATE_DIR"; then
            hard+=(rsync)
        fi
    fi
    local _cmd
    for _cmd in "${hard[@]}"; do command -v "$_cmd" >/dev/null 2>&1 || missing_hard+=("$_cmd"); done
    if [[ ${#missing_hard[@]} -gt 0 ]]; then
        echo "ERROR: restore.sh: the following required tools are not installed: ${missing_hard[*]}" >&2
        for _cmd in "${missing_hard[@]}"; do
            case "$_cmd" in
                rsync) echo "  Hint [rsync]:     apt install rsync" >&2 ;;
                sops)  echo "  Hint [sops]:      apt install sops  OR  snap install sops" >&2 ;;
                zstd)  echo "  Hint [zstd]:      apt install zstd" >&2 ;;
            esac
        done
        exit 1
    fi
}

# Prints a compact restore plan before destructive confirmation.
_print_restore_plan_summary() {
    local backup_name backup_size enc_mode pre_backup
    backup_name="$(basename "${BACKUP_FILE:-unknown}")"
    backup_size="$(du -sh "${BACKUP_FILE:-}" 2>/dev/null | awk '{print $1}' || echo "unknown")"
    enc_mode="${backup_encryption_mode:-inferred age-recipient}"
    if [[ "${NO_PRE_BACKUP:-false}" == "true" ]]; then
        pre_backup="skipped (--no-backup)"
    else
        pre_backup="pre-restore emergency snapshot"
    fi

    operator_attention warn "Restore plan summary" \
        "Mode: ${RESTORE_TYPE:-unknown}" \
        "Backup: ${backup_name}" \
        "Size: ${backup_size}" \
        "Target directory: ${STATE_DIR:-unknown}" \
        "Docker: will be STOPPED" \
        "Pre-backup: ${pre_backup}" \
        "Backup decrypt key role: selected backup decrypt key" \
        "Live operational SOPS Age key: ${OPERATIONAL_SOPS_AGE_KEY_FILE:-unknown}"
    if [[ "${RESTORE_TYPE:-}" == "emergency" ]]; then
        printf '  - Emergency encryption mode: %s\n' "$enc_mode" >&2
    fi
}

# Emits a countdown while waiting for the interactive Age key prompt.
_age_key_countdown() {
    local secs=300
    while (( secs > 0 )); do
        sleep 60 || return
        (( secs -= 60 ))
        printf '\r  [Age key] %ds remaining — press Enter for default key  ' "$secs" >&2
    done
}

# Verifies the selected restore transaction is committed enough for one automatic safety restart.
_can_safe_restart() {
    local db="$STATE_DIR/data/db.sqlite3"

    case "${RESTORE_TYPE:-}" in
        db)
            ;;
        full|emergency)
            [[ "${RESTORE_FULL_PROMOTION_COMMITTED:-false}" == "true" ]] || return 1
            ;;
        *)
            return 1
            ;;
    esac

    [[ -f "$db" ]] || return 1
    sqlite3 "$db" "PRAGMA integrity_check;" 2>/dev/null | grep -qx ok
}

# Prints the always-on post-restore operator checklist.
_print_post_restore_summary() {
    local backup_name; backup_name="$(basename "${BACKUP_FILE:-unknown}")"
    log_info "─────────────────────────────────────────────────────────────"
    log_info "  Post-restore summary"
    log_info "─────────────────────────────────────────────────────────────"
    log_info "  Backup restored: $backup_name"
    log_info "  Restore type:    ${RESTORE_TYPE:-unknown}"
    if [[ -n "${ROTATED_KEY_FILE:-}" ]]; then
        log_info "  New Age key at:  $ROTATED_KEY_FILE"
        [[ -n "${ROTATED_KIT_FILE:-}" ]] && \
            log_warn "  Recovery kit:    $ROTATED_KIT_FILE  ← DELETE AFTER COPYING OFFLINE"
    fi
    log_info "  → Check health:  sudo ./maintenance.sh health"
    log_info "  → Check logs:    docker compose logs --tail=50"
    log_info "─────────────────────────────────────────────────────────────"
}

_complete_restore_after_health() {
    local health_rc="$1"
    local completion="clean"

    case "$health_rc" in
        0)
            log_success "Post-restore health verification passed."
            ;;
        1)
            log_warn "Post-restore health verification completed with warnings."
            completion="warnings"
            ;;
        2)
            log_error "Post-restore health verification found health failures."
            log_error "Restore artifacts are committed and remain in place; no rollback was attempted."
            log_error "Investigate with: sudo ./maintenance.sh health"
            log_error "Then inspect: docker compose logs --tail=100"
            _print_post_restore_summary
            return 2
            ;;
        3)
            log_error "Post-restore health checks could not run because a critical prerequisite or runtime condition failed."
            log_error "Restore artifacts are committed and remain in place; no rollback was attempted."
            log_error "Investigate with: sudo ./maintenance.sh health"
            log_error "Then inspect: docker compose logs --tail=100"
            _print_post_restore_summary
            return 3
            ;;
        4)
            log_error "Post-restore health verification failed because operation-guard infrastructure could not run."
            log_error "Restore artifacts are committed and remain in place; no rollback was attempted."
            log_error "Inspect active operations, then retry: sudo ./maintenance.sh health"
            log_error "Also inspect: docker compose logs --tail=100"
            _print_post_restore_summary
            return 4
            ;;
        75)
            log_warn "Post-restore health verification is unavailable because another health or repair operation is active."
            log_warn "Restore artifacts are committed and remain in place; health verification was skipped."
            log_warn "Retry after the active operation completes: sudo ./maintenance.sh health"
            _print_post_restore_summary
            return 75
            ;;
        *)
            log_error "Post-restore health verification returned unexpected status ${health_rc}."
            log_error "Restore artifacts are committed and remain in place; no rollback was attempted."
            log_error "Investigate with: sudo ./maintenance.sh health"
            _print_post_restore_summary
            return "$health_rc"
            ;;
    esac

    echo ""
    auto_fix_critical_permissions "$PROJECT_ROOT" || \
        log_warn "Final permission repair reported issues after health checks."
    _print_post_restore_summary
    if [[ "$completion" == "warnings" ]]; then
        log_warn "Restore completed with warnings."
    else
        log_success "Restore complete."
    fi
    if [[ -n "$ROTATED_KEY_FILE" && "$DRY_RUN" != "true" ]]; then
        log_info  "New age key is live at: $ROTATED_KEY_FILE"
        log_info  "Run: sudo ./setup.sh systemd install  (to sync /etc/vaultwarden/)"
    fi
    return 0
}

_tar_filter_for_file() {
    case "$1" in
        *.tar.zst|*.zst) echo "-I zstd" ;;
        *.tar.gz|*.tgz)  echo "-z"      ;;
        *.tar.bz2|*.tbz) echo "-j"      ;;
        *.tar.xz)        echo "-J"      ;;
        *)               echo ""        ;;
    esac
}

_tar_supports_option() {
    local option="$1"
    tar --help 2>&1 | grep -Fq -- "$option"
}

_tar_extract_archive() {
    local archive="$1" dest="$2" tar_filter="$3"
    local -a extract_opts=(-xf "$archive" -C "$dest" --no-same-owner --no-same-permissions)

    _tar_supports_option --no-overwrite-dir && extract_opts+=(--no-overwrite-dir)
    _tar_supports_option --delay-directory-restore && extract_opts+=(--delay-directory-restore)

    # shellcheck disable=SC2086
    tar $tar_filter "${extract_opts[@]}"
}

_require_command_for_path() {
    local cmd="$1" reason="$2" package="${3:-$1}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "$cmd is required for ${reason} but is not installed."
        log_error "Install on Ubuntu 24.04 LTS Noble with: sudo apt-get install -y ${package}"
        return 1
    fi
}

_require_selected_archive_tools() {
    local path="$1"
    case "$path" in
        *.tar.zst|*.zst|*.tar.zst.age|*.zst.age)
            _require_command_for_path zstd "restoring zstd-compressed archives" zstd || return 1
            ;;
    esac
}

_require_sops_for_rekey() {
    _require_command_for_path sops "post-restore SOPS key rotation/rekey" sops
}

_path_is_mountpoint() { mountpoint -q "$1" 2>/dev/null; }

_restore_payload_parent() {
    local state_dir="$1" canonical_state parent
    canonical_state="$(realpath -m -- "$state_dir" 2>/dev/null)" || {
        log_error "Cannot canonicalize restore target state path: $state_dir"
        return 1
    }
    if _path_is_mountpoint "$state_dir"; then
        parent="$canonical_state"
    else
        parent="$(dirname "$canonical_state")"
    fi
    [[ -d "$parent" && ! -L "$parent" && -w "$parent" ]] || {
        log_error "Restore payload target is not a writable real directory: $parent"
        return 1
    }
    printf '%s\n' "$parent"
}

_restore_create_control_workspace() {
    local parent="/dev/shm" fs_type
    fs_type="$(stat -f -c '%T' /dev/shm 2>/dev/null || true)"
    if [[ "$fs_type" != "tmpfs" ]]; then
        parent="${TMPDIR:-/tmp}"
        log_warn "/dev/shm tmpfs is unavailable; small restore control files will use: $parent"
    fi
    _restore_create_owned_workspace \
        CONTROL_WORKSPACE CONTROL_WORKSPACE_ID "$parent" vw-restore-control true || return 1
    if [[ "$CONTROL_WORKSPACE" != /dev/shm/* ]]; then
        log_warn "Restore control workspace is disk-backed: $CONTROL_WORKSPACE"
        log_warn "Only small key, diagnostic, and rekey-control files will use it."
    fi
}

_restore_create_payload_workspace() {
    local state_dir="$1" parent prefix configured_device
    configured_device="$(get_config_value "DATA_VOLUME_DEVICE" "")"
    if [[ -n "$configured_device" ]] && ! _path_is_mountpoint "$state_dir"; then
        log_error "Configured restore data volume is not mounted at: $state_dir"
        log_error "Refusing to place restore payload staging on the boot filesystem."
        return 1
    fi
    parent="$(_restore_payload_parent "$state_dir")" || return 1
    if _path_is_mountpoint "$state_dir"; then
        prefix=".vaultwarden-restore-payload"
    else
        prefix=".$(basename "$state_dir").restore-payload"
    fi
    _restore_create_owned_workspace \
        PAYLOAD_WORKSPACE PAYLOAD_WORKSPACE_ID "$parent" "$prefix" || return 1
    log_info "Restore payload staging filesystem: $PAYLOAD_WORKSPACE"
}

_restore_file_size_bytes() {
    stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null
}

_restore_require_available_bytes() {
    local target="$1" required="$2" purpose="$3" available
    [[ -d "$target" && ! -L "$target" ]] || {
        log_error "Cannot check restore capacity on an unverified target: $target"
        return 1
    }
    [[ "$required" =~ ^[0-9]+$ ]] || {
        log_error "Cannot determine required space for ${purpose}."
        return 1
    }
    available="$(df -PB1 "$target" 2>/dev/null | awk 'END { print $4 }')"
    [[ "$available" =~ ^[0-9]+$ ]] || {
        log_error "Cannot determine available target space for ${purpose}: $target"
        return 1
    }
    if (( available < required )); then
        log_error "Insufficient target space before service stop for ${purpose}."
        log_error "  Required: $required bytes"
        log_error "  Available: $available bytes"
        log_error "  Target: $target"
        log_error "Free target space, then retry. Services were not stopped."
        return 1
    fi
    log_info "Capacity preflight passed for ${purpose}: $required bytes required."
}

_restore_preflight_local_decrypt_capacity() {
    local backup_file="$1" archive_bytes
    archive_bytes="$(_restore_file_size_bytes "$backup_file" 2>/dev/null || true)"
    [[ "$archive_bytes" =~ ^[0-9]+$ ]] || {
        log_error "Cannot determine selected backup size: $backup_file"
        return 1
    }
    _restore_require_available_bytes "$PAYLOAD_WORKSPACE" \
        "$((archive_bytes + 64 * 1024 * 1024))" \
        "selected backup decryption staging"
}

_restore_archive_apparent_bytes() {
    local archive="$1" filter listing total
    filter="$(_tar_filter_for_file "$archive")"
    local -a filter_args=()
    [[ -n "$filter" ]] && read -r -a filter_args <<< "$filter"
    listing="$(LC_ALL=C tar "${filter_args[@]}" --numeric-owner -tvf "$archive")" || {
        log_error "Cannot measure validated restore archive members."
        return 1
    }
    # Round each member to a 4 KiB block and add another block for inode/
    # directory metadata. This deliberately overestimates small-file trees.
    total="$(awk '
        $1 ~ /^[-dlcbpsh]/ && $3 ~ /^[0-9]+$/ {
            blocks = int(($3 + 4095) / 4096) * 4096
            total += blocks + 4096
        }
        END { printf "%.0f\n", total + 0 }
    ' <<< "$listing")"
    [[ "$total" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$total"
}

_restore_preflight_archive_expansion_capacity() {
    local archive="$1" apparent_bytes
    apparent_bytes="$(_restore_archive_apparent_bytes "$archive")" || return 1
    _restore_require_available_bytes "$PAYLOAD_WORKSPACE" \
        "$((apparent_bytes * 2 + 64 * 1024 * 1024))" \
        "archive extraction and target-filesystem promotion"
}

_restore_preflight_db_commit_capacity() {
    local staged_db="$1" state_dir="$2" staged_bytes live_bytes=0
    staged_bytes="$(_restore_file_size_bytes "$staged_db" 2>/dev/null || true)"
    [[ "$staged_bytes" =~ ^[0-9]+$ ]] || return 1
    if [[ -f "$state_dir/data/db.sqlite3" ]]; then
        live_bytes="$(_restore_file_size_bytes "$state_dir/data/db.sqlite3" 2>/dev/null || printf '0')"
        [[ "$live_bytes" =~ ^[0-9]+$ ]] || live_bytes=0
    fi
    _restore_require_available_bytes "$PAYLOAD_WORKSPACE" \
        "$((staged_bytes + live_bytes + 64 * 1024 * 1024))" \
        "database atomic write and rollback copy"
}

_detect_storage_mode() {
    local root="${1:-}" data_mount="${2:-}" data_device="${3:-}"
    if [[ "$root" == "/var/lib/vaultwarden" ]]; then
        if [[ -f "$root/.vw-data-volume" ]] || _path_is_mountpoint "$root"; then echo "block"; else echo "boot"; fi
    elif [[ -n "$root" && ( "$root" == /mnt/* || "$root" == /media/* || "$root" == /srv/* ) ]]; then
        echo "block"
    elif [[ -n "$data_mount" && "$root" == "$data_mount" ]] || [[ -n "$data_device" ]]; then
        echo "block"
    elif [[ "$root" == *"/VaultWarden-OCI" ]]; then
        echo "repo-local"
    else
        echo "unknown"
    fi
}

_restore_required_dirs() { printf '%s\n' data caddy logs config secrets backups; }

_restore_ensure_volume_sentinel() {
    local mount_point="$1"
    local device="${2:-${DATA_VOLUME_DEVICE:-}}"
    local sentinel="$mount_point/.vw-data-volume"

    if [[ -f "$sentinel" ]]; then
        log_info "Data volume sentinel already present: $sentinel"
        return 0
    fi

    local sentinel_tmp
    sentinel_tmp="$(mktemp "$mount_point/vw-data-volume-tmp.XXXXXX")" || {
        log_error "Failed to create temp file for sentinel: $mount_point"
        return 1
    }

    if ! printf 'VaultWarden-OCI data volume\nDevice: %s\nMounted: %s\nCreated: %s\n' \
        "$device" "$mount_point" "$(date -Iseconds)" > "$sentinel_tmp"; then
        rm -f "$sentinel_tmp" 2>/dev/null || true
        log_error "Failed to write sentinel temp file"
        return 1
    fi

    chmod 444 "$sentinel_tmp" 2>/dev/null || true

    if ! mv -- "$sentinel_tmp" "$sentinel"; then
        rm -f "$sentinel_tmp" 2>/dev/null || true
        log_error "Failed to move sentinel into place: $sentinel"
        return 1
    fi

    if command -v chattr >/dev/null 2>&1; then
        chattr +i "$sentinel" 2>/dev/null \
            || log_warn "chattr +i failed on sentinel — immutability not set (non-fatal; sentinel is still 444)"
    fi

    log_success "Data volume sentinel written and protected: $sentinel"
    return 0
}

_restore_age_no_identity_guidance() {
    log_error "The current configured Age key cannot decrypt this selected backup."
    log_error "The selected backup may have been encrypted with an older operational key or offline recovery key."
    log_error "The current live key and backup decrypt key may be different."
    log_error "Retry with:"
    log_error "  sudo ./restore.sh interactive --remote --key-file /path/to/old-age-key.txt"
    log_error "or:"
    log_error "  sudo ./restore.sh latest --from-recovery-kit /path/to/recovery-kit.txt --force"
}

_restore_backup_encryption_mode() {
    read_meta_field "${BACKUP_FILE}.meta" "encryption_mode" ""
}

_age_decrypt_restore_backup() {
    local backup_file="$1" age_key_file="$2" output_file="$3" age_err="$4"
    local encryption_mode="${5:-}"

    if [[ "$RESTORE_TYPE" == "emergency" ]]; then
        case "$encryption_mode" in
            age-passphrase)
                age -d -o "$output_file" "$backup_file" 2>"$age_err"
                ;;
            age-recipient)
                if [[ -n "${EMERGENCY_BACKUP_AGE_IDENTITY_FILE:-}" ]]; then
                    age -d -i "$EMERGENCY_BACKUP_AGE_IDENTITY_FILE" -o "$output_file" "$backup_file" 2>"$age_err"
                else
                    age -d -i "$age_key_file" -o "$output_file" "$backup_file" 2>"$age_err"
                fi
                ;;
            "")
                log_error "Emergency backup encryption_mode is missing; refusing ambiguous decrypt dispatch."
                return 1
                ;;
            *)
                log_error "Unsupported emergency backup encryption_mode: '$encryption_mode'"
                return 1
                ;;
        esac
        return $?
    fi

    age -d -i "$age_key_file" -o "$output_file" "$backup_file" 2>"$age_err"
}

_decrypt_restore_archive_for_preflight() {
    local backup_file="$1" age_key_file="$2" payload_workspace="$3" control_workspace="$4"
    local inner_name="${backup_file%.age}"
    case "$inner_name" in
        *.tar.zst|*.tar.gz|*.tar.bz2|*.tar.xz|*.tgz|*.tbz) : ;;
        *) inner_name="${inner_name}.tar.gz" ;;
    esac
    local dec_tar
    dec_tar="$payload_workspace/$(basename "$inner_name")"
    [[ -s "$dec_tar" ]] && { printf '%s\n' "$dec_tar"; return 0; }
    log_info "Decrypting archive for non-destructive preflight inspection..." >&2
    local age_err="$control_workspace/age-decrypt.err"
    if ! _age_decrypt_restore_backup "$backup_file" "$age_key_file" "$dec_tar" "$age_err" "$(_restore_backup_encryption_mode)"; then
        if grep -qi 'no identity matched any of the recipients' "$age_err" 2>/dev/null; then
            _restore_age_no_identity_guidance
        else
            log_error "Decryption failed — verify the age key is correct."
            log_hint "Use --key-file /path/to/the/old-age-key.txt for the key that encrypted this backup."
            log_hint "If you exported a recovery kit, retry with --from-recovery-kit /path/to/recovery-kit.txt."
        fi
        return 1
    fi
    chmod 0600 "$dec_tar" || return 1
    printf '%s\n' "$dec_tar"
}

_stage_db_restore_for_preflight() {
    local backup_file="$1" age_key_file="$2" state_dir="$3"
    local dec_db="$PAYLOAD_WORKSPACE/db.sqlite3"
    local age_err="$CONTROL_WORKSPACE/db-age-decrypt.err"

    if [[ ! -s "$dec_db" ]]; then
        log_info "Decrypting database backup into target-filesystem staging..."
        if ! age -d -i "$age_key_file" -o "$dec_db" "$backup_file" 2>"$age_err"; then
            if grep -qi 'no identity matched any of the recipients' "$age_err" 2>/dev/null; then
                _restore_age_no_identity_guidance
            else
                log_error "Decryption failed — verify the age key is correct."
                log_hint "Use --key-file /path/to/the/old-age-key.txt for the key that encrypted this backup."
                log_hint "If you exported a recovery kit, retry with --from-recovery-kit /path/to/recovery-kit.txt."
            fi
            return 1
        fi
        chmod 0600 "$dec_db" || return 1
    fi
    [[ "$SKIP_VERIFICATION" == "true" ]] || verify_sqlite "$dec_db" || return 1
    local schema_count
    schema_count="$(sqlite3 "$dec_db" "SELECT count(*) FROM sqlite_master;" 2>/dev/null || echo 0)"
    if [[ "$schema_count" =~ ^[0-9]+$ ]] && (( schema_count == 0 )); then
        log_warn "Restored DB has an empty schema (0 objects in sqlite_master)."
        log_warn "Verify this is the intended backup — an empty Vaultwarden DB has no tables."
    fi
    _restore_preflight_db_commit_capacity "$dec_db" "$state_dir"
}

_restore_inspect_archive_layout() {
    local dec_tar="$1" archive_format="$3"
    local filter; filter="$(_tar_filter_for_file "$dec_tar")"
    local -a filter_args=()
    [[ -n "$filter" ]] && read -r -a filter_args <<< "$filter"
    RESTORE_PREFLIGHT_MEMBERS="$(tar "${filter_args[@]}" -tf "$dec_tar")" || return 1
    RESTORE_PREFLIGHT_FIRST30="$(printf '%s\n' "$RESTORE_PREFLIGHT_MEMBERS" | head -30)"
    local normalized_members
    # Normalize archive member names only for layout analysis.  Legacy v1
    # archives retain absolute member grammar, but the derived source root is
    # always reconstructed below with exactly one leading slash.
    normalized_members="$(printf '%s\n' "$RESTORE_PREFLIGHT_MEMBERS" | sed -e 's#^\./##' -e 's#^/*##')"
    mapfile -t RESTORE_PREFLIGHT_LIVE_DBS < <(printf '%s\n' "$normalized_members" | grep -E '(^|/)data/db\.sqlite3$' | grep -Ev '(^|/)\.pre-restore-[^/]*/data/db\.sqlite3$' || true)
    mapfile -t RESTORE_PREFLIGHT_SNAPSHOT_DBS < <(printf '%s\n' "$normalized_members" | grep -E '(^|/)\.pre-restore-[^/]*/data/db\.sqlite3$' || true)
    mapfile -t RESTORE_PREFLIGHT_CONFIGS < <(printf '%s\n' "$normalized_members" | grep -E '(^|/)config/install\.env$' || true)
    RESTORE_PREFLIGHT_SOURCE_ROOT=""
    RESTORE_PREFLIGHT_LIVE_DB=""
    if (( ${#RESTORE_PREFLIGHT_LIVE_DBS[@]} == 1 )); then
        RESTORE_PREFLIGHT_LIVE_DB="${RESTORE_PREFLIGHT_LIVE_DBS[0]}"
        RESTORE_PREFLIGHT_SOURCE_ROOT="/${RESTORE_PREFLIGHT_LIVE_DB%/data/db.sqlite3}"
    elif (( ${#RESTORE_PREFLIGHT_LIVE_DBS[@]} == 0 && ${#RESTORE_PREFLIGHT_CONFIGS[@]} > 0 )); then
        RESTORE_PREFLIGHT_SOURCE_ROOT="/${RESTORE_PREFLIGHT_CONFIGS[0]%/config/install.env}"
    elif (( ${#RESTORE_PREFLIGHT_LIVE_DBS[@]} == 0 && ${#RESTORE_PREFLIGHT_SNAPSHOT_DBS[@]} > 0 )); then
        local snap="${RESTORE_PREFLIGHT_SNAPSHOT_DBS[0]}"
        RESTORE_PREFLIGHT_SOURCE_ROOT="/${snap%%/.pre-restore-*}"
    fi
    RESTORE_PREFLIGHT_SOURCE_MODE="$(_detect_storage_mode "$RESTORE_PREFLIGHT_SOURCE_ROOT" "" "")"
    RESTORE_PREFLIGHT_SOURCE_MOUNT=""
    [[ "$RESTORE_PREFLIGHT_SOURCE_MODE" == "block" ]] && RESTORE_PREFLIGHT_SOURCE_MOUNT="$RESTORE_PREFLIGHT_SOURCE_ROOT"
    [[ "$archive_format" == "absolute" ]] && RESTORE_PREFLIGHT_SOURCE_MODE="unknown"
    return 0
}

_restore_prepare_block_target() {
    local state_dir="$1" puid="$2" pgid="$3" archive_path="${4:-}"
    local ok=true
    if [[ ! -d "$state_dir" ]]; then log_error "Target block mount path does not exist: $state_dir"; ok=false; fi
    if ! _path_is_mountpoint "$state_dir"; then
        log_error "Target block storage is configured but not mounted at: $state_dir"
        [[ -n "${DATA_VOLUME_DEVICE:-}" ]] && log_error "Configured DATA_VOLUME_DEVICE: ${DATA_VOLUME_DEVICE}"
        log_error "Suggested next action: sudo ./utilities/setup-storage.sh"
        command -v lsblk >/dev/null 2>&1 && { log_warn "Detected block devices:"; lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null | sed 's/^/  /' >&2 || true; }
        return 1
    fi
    [[ -w "$state_dir" ]] || { log_error "Target block mount is not writable by root: $state_dir"; ok=false; }
    if [[ -n "$archive_path" && -f "$archive_path" ]]; then
        local need avail
        need=$(stat -c '%s' "$archive_path" 2>/dev/null || echo 0)
        avail=$(df -PB1 "$state_dir" 2>/dev/null | awk 'NR==2 {print $4+0}')
        if [[ "$need" =~ ^[0-9]+$ && "$avail" =~ ^[0-9]+$ ]] && (( avail < need * 2 )); then
            log_error "Target block mount may not have enough free space (available ${avail} bytes, archive ${need} bytes)."
            ok=false
        fi
    fi
    [[ "$ok" == "true" ]] || return 1

    local write_probe
    write_probe="$(mktemp "$state_dir/.restore-write-probe.XXXXXX")" || {
        log_error "Target block mount is mounted but not writable by root: $state_dir"
        return 1
    }
    rm -f "$write_probe" 2>/dev/null || true

    local d
    for d in $(_restore_required_dirs); do
        if [[ ! -e "$state_dir/$d" ]]; then
            mkdir -p "$state_dir/$d" || return 1
            log_info "Created missing block-storage directory: $state_dir/$d"
        elif [[ ! -d "$state_dir/$d" ]]; then
            log_error "Required target path exists but is not a directory: $state_dir/$d"; return 1
        fi
    done
    _restore_ensure_volume_sentinel "$state_dir" "${DATA_VOLUME_DEVICE:-}" || return 1
    chown -R "${puid}:${pgid}" "$state_dir/data" "$state_dir/backups" 2>/dev/null || true
    chmod 700 "$state_dir/secrets" 2>/dev/null || true
    return 0
}

restore_full_preflight() {
    local backup_file="$1" dec_tar="$2" state_dir="$3" puid="$4" pgid="$5" archive_format="$6" archive_version="$7"
    _restore_inspect_archive_layout "$dec_tar" "$state_dir" "$archive_format" || { log_error "Cannot inspect archive members."; return 1; }
    local target_mount="${DATA_VOLUME_MOUNT:-$(get_config_value "DATA_VOLUME_MOUNT" "")}"
    local target_device="${DATA_VOLUME_DEVICE:-$(get_config_value "DATA_VOLUME_DEVICE" "")}"
    local state_is_mountpoint="no"; _path_is_mountpoint "$state_dir" && state_is_mountpoint="yes"
    local target_mode; target_mode="$(_detect_storage_mode "$state_dir" "$target_mount" "$target_device")"
    local live_db="${RESTORE_PREFLIGHT_LIVE_DB:-missing}"
    local verdict="Compatible"; local recommended="Continue with restore if this is the intended backup."
    local compatible=true
    if (( ${#RESTORE_PREFLIGHT_LIVE_DBS[@]} > 1 )); then
        compatible=false; verdict="Multiple live source DB roots detected; inspect archive manually."
        recommended="Choose another backup or inspect archive manually."
    elif [[ -z "$RESTORE_PREFLIGHT_LIVE_DB" ]]; then
        compatible=false; verdict="No live state DB found for full/emergency restore."
        recommended="Restore latest DB backup, choose another full/emergency backup, or inspect archive manually."
    elif [[ "$RESTORE_PREFLIGHT_SOURCE_MODE" == "block" && "$target_mode" == "boot" ]]; then
        compatible=false; verdict="Storage mismatch: backup appears to be from block storage, but this VM is currently targeting boot storage."
        recommended="Attach/mount/configure block storage first, or restore the latest DB backup if only Vaultwarden data is needed."
    elif [[ "$RESTORE_PREFLIGHT_SOURCE_MODE" == "repo-local" && "$FORCE" != "true" ]]; then
        compatible=false; verdict="Legacy repo-local source detected; explicit --force confirmation is required."
        recommended="Re-run with --force only after confirming this legacy archive is intended."
    fi
    if [[ "$target_mode" == "block" && "$compatible" == "true" ]]; then
        if ! _path_is_mountpoint "$state_dir"; then
            compatible=false; verdict="Target block/data volume is configured but not mounted at: $state_dir"; recommended="Run: sudo ./utilities/setup-storage.sh"
        elif [[ ! -w "$state_dir" ]]; then
            compatible=false; verdict="Target block/data volume is mounted but not writable by root: $state_dir"; recommended="Fix mount/permissions, then re-run inspect."
        else
            local missing_dirs=() d
            for d in $(_restore_required_dirs); do
                [[ -d "$state_dir/$d" ]] || missing_dirs+=("$d")
            done
            if (( ${#missing_dirs[@]} > 0 )); then
                recommended="After confirmation, restore will create missing mounted block-volume directories: ${missing_dirs[*]}"
            fi
        fi
    fi
    echo ""
    log_info "Restore preflight report (non-destructive):"
    echo "Backup source:"
    echo "  Selected file:      $backup_file"
    echo "  Type:               $RESTORE_TYPE"
    echo "  Archive format:     ${archive_format} v${archive_version}"
    echo "  Source state root:  ${RESTORE_PREFLIGHT_SOURCE_ROOT:-unknown}"
    echo "  Source storage:     ${RESTORE_PREFLIGHT_SOURCE_MODE:-unknown}"
    echo "  Source mount path:  ${RESTORE_PREFLIGHT_SOURCE_MOUNT:-unset}"
    echo "  Config paths:       ${RESTORE_PREFLIGHT_CONFIGS[*]:-missing}"
    echo "  Live DB:            ${live_db}"
    echo "  Snapshot DBs:       ${RESTORE_PREFLIGHT_SNAPSHOT_DBS[*]:-none}"
    echo ""
    echo "Current target:"
    echo "  PROJECT_STATE_DIR:  $state_dir"
    echo "  DATA_VOLUME_MOUNT:  ${target_mount:-unset}"
    echo "  DATA_VOLUME_DEVICE: ${target_device:-unset}"
    echo "  Is mountpoint:      $state_is_mountpoint"
    echo "  Target storage:     $target_mode"
    echo "  Required dirs:      $(_restore_required_dirs | paste -sd' ' -)"
    echo ""
    echo "Verdict:"
    echo "  $verdict"
    echo "  Recommended next action: $recommended"
    if [[ "$compatible" != "true" ]]; then
        echo ""
        echo "Archive members (first 30):"
        while IFS= read -r _member; do
            printf '  %s\n' "$_member"
        done <<< "$RESTORE_PREFLIGHT_FIRST30"
        return 1
    fi
    return 0
}

tar_validate_members() {
    local tarfile="$1" filter
    filter="$(_tar_filter_for_file "$tarfile")"
    local members
    # shellcheck disable=SC2086
    members="$(tar $filter -tf "$tarfile")" || { log_error "Cannot list archive members"; return 1; }
    # Catch absolute paths, classic ../ traversal, and ./.. relative traversal.
    echo "$members" | grep -qE '(^/|(^|/)\.\.(\/|$)|^\./\.\.)' && {
        log_error "Archive contains unsafe paths. Refusing to extract."; return 1
    }
    return 0
}

check_traversal_only() {
    local tarfile="$1" filter
    filter="$(_tar_filter_for_file "$tarfile")"
    local bad_members
    # shellcheck disable=SC2086
    bad_members=$(tar $filter -tf "$tarfile" 2>/dev/null | grep -E '(^|/)\.\.(\/|$)' || true)
    if [[ -n "$bad_members" ]]; then
        log_error "Archive contains path traversal sequences (../). Refusing to extract."
        echo "$bad_members" | head -10 >&2
        return 1
    fi
    return 0
}

verify_sqlite() {
    local dbfile="$1"
    log_info "Checkpointing WAL before integrity check..."
    sqlite3 "$dbfile" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
    log_info "Verifying SQLite integrity..."
    local result
    result=$(sqlite3 "$dbfile" "PRAGMA integrity_check;" 2>&1) || {
        log_error "SQLite integrity check error: ${result}"; return 1
    }
    [[ "$result" == "ok" ]] || { log_error "SQLite integrity check FAILED: ${result}"; return 1; }
    log_success "SQLite integrity check passed"
}

purge_wal_shm() { local db="$1"; rm -f "${db}-wal" "${db}-shm" 2>/dev/null || true; }

_preflight_operational_sops_key_for_snapshot() {
    local operational_key="$1" state_dir secrets_file
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    secrets_file="${SECRETS_FILE:-${state_dir}/secrets/secrets.yaml}"

    [[ -f "$secrets_file" && -f "$operational_key" ]] || return 0
    command -v sops >/dev/null 2>&1 || return 0

    if ! SOPS_AGE_KEY_FILE="$operational_key" sops -d "$secrets_file" >/dev/null 2>&1; then
        log_error "Pre-restore snapshot preflight failed: current secrets.yaml cannot be decrypted with the live SOPS key."
        log_error "  secrets.yaml: $secrets_file"
        log_error "  live SOPS key: $operational_key"
        log_error "  selected backup decrypt key: ${RESTORE_DECRYPT_AGE_KEY_FILE:-<not resolved>}"
        log_error "The selected backup key and current live SOPS key are separate."
        log_error "The pre-restore emergency snapshot must decrypt current live SOPS secrets before restore."
        log_error "Fix current SOPS decryptability, or intentionally skip the safety snapshot with --no-backup."
        log_error "Use --no-backup only when current local state is disposable (for example a fresh VM restoring a remote DB backup)."
        return 1
    fi
    return 0
}

create_pre_restore_snapshot() {
    local operational_sops_age_key_file="${1:-${OPERATIONAL_SOPS_AGE_KEY_FILE:-}}"
    local restore_type="${2:-${RESTORE_TYPE:-}}"
    RESTORE_SNAPSHOT_RESULT="failed"

    if [[ "$NO_PRE_BACKUP" == "true" ]]; then
        RESTORE_SNAPSHOT_RESULT="skipped"
        log_info "Skipping pre-restore snapshot (--no-backup)"
        return 0
    fi

    local state_dir; state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    local db_path="$state_dir/data/db.sqlite3"

    # Fresh full/emergency DR target: no live DB means no current generation to snapshot.
    if [[ "$restore_type" =~ ^(full|emergency)$ && ! -f "$db_path" ]]; then
        RESTORE_SNAPSHOT_RESULT="skipped"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] No current live DB found at $db_path — would skip pre-restore snapshot."
        else
            log_warn "No current live DB found at $db_path — fresh restore target; skipping pre-restore snapshot."
            log_warn "There is no current Vaultwarden database to preserve before restoring the selected archive."
        fi
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        RESTORE_SNAPSHOT_RESULT="skipped"
        log_info "[DRY RUN] Would run: utilities/backup-run.sh run emergency"
        return 0
    fi

    _preflight_operational_sops_key_for_snapshot "$operational_sops_age_key_file" || return 1
    # Best-effort WAL checkpoint; swallow all failures intentionally.
    # shellcheck disable=SC2015
    [[ -f "$db_path" ]] && command -v sqlite3 >/dev/null 2>&1 && \
        sqlite3 "$db_path" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true

    if [[ -x "${PROJECT_ROOT}/utilities/backup-run.sh" ]]; then
        log_info "Creating pre-restore emergency snapshot..."
        log_info "Invoking with live SOPS key: ${PROJECT_ROOT}/utilities/backup-run.sh run emergency --quiet"
        if SOPS_AGE_KEY_FILE="$operational_sops_age_key_file" "${PROJECT_ROOT}/utilities/backup-run.sh" run emergency --quiet; then
            RESTORE_SNAPSHOT_RESULT="created"
            return 0
        fi
        if [[ "${RESTORE_SNAPSHOT_HARD_FAIL}" == "true" ]]; then
            log_error "Pre-restore snapshot FAILED (hard-fail)."
            log_error "Use --no-backup only if current local state is disposable, or set RESTORE_SNAPSHOT_HARD_FAIL=false to continue."
            return 1
        fi
        RESTORE_SNAPSHOT_RESULT="soft-failed"
        log_warn "Pre-restore snapshot failed (continuing — RESTORE_SNAPSHOT_HARD_FAIL=false)"
        return 0
    fi

    local msg="backup-run.sh not executable — cannot create pre-restore snapshot"
    if [[ "${RESTORE_SNAPSHOT_HARD_FAIL}" == "true" ]]; then
        log_error "$msg"
        log_error "Use --no-backup only if current local state is disposable, or set RESTORE_SNAPSHOT_HARD_FAIL=false to continue."
        return 1
    fi
    RESTORE_SNAPSHOT_RESULT="soft-failed"
    log_warn "$msg (continuing — RESTORE_SNAPSHOT_HARD_FAIL=false)"
    return 0
}

_set_snapshot_operation_phase() {
    case "${RESTORE_SNAPSHOT_RESULT:-}" in
        created)
            operation_set_phase "snapshot" "Created pre-restore snapshot"
            ;;
        skipped)
            operation_set_phase "snapshot" "Pre-restore snapshot skipped"
            ;;
        soft-failed)
            operation_set_phase "snapshot" "Pre-restore snapshot soft-failed; continuing by policy"
            ;;
        *)
            log_error "Unexpected pre-restore snapshot result: ${RESTORE_SNAPSHOT_RESULT:-unset}"
            return 1
            ;;
    esac
}

cleanup_pre_restore_artefacts() {
    local base_path="$1" keep_count="${2:-3}"
    local base_dir base_name
    base_dir="$(dirname  "$base_path")"
    base_name="$(basename "$base_path")"
    local artefacts=()
    while IFS= read -r -d '' f; do artefacts+=("$f"); done \
        < <(find "$base_dir" -maxdepth 1 -name "${base_name}.pre-restore-*" -print0 2>/dev/null | sort -z)
    local total="${#artefacts[@]}"
    (( total <= keep_count )) && return 0
    local to_remove=$(( total - keep_count ))
    log_info "Pruning ${to_remove} old pre-restore artefact(s) (keeping ${keep_count} most recent)..."
    for (( i=0; i<to_remove; i++ )); do
        rm -rf "${artefacts[$i]}"
        log_info "  Removed: $(basename "${artefacts[$i]}")"
    done
}

restore_db() {
    local backup_file="$1" age_key_file="$2" state_dir="$3" puid="$4" pgid="$5" tmpdir="$6"
    local dec_db="$tmpdir/db.sqlite3"

    if [[ ! -s "$dec_db" ]]; then
        _stage_db_restore_for_preflight "$backup_file" "$age_key_file" "$state_dir" || return 1
    fi
    log_info "Using preflight-validated database payload from target-filesystem staging."
    [[ "$SKIP_VERIFICATION" != "true" ]] && { verify_sqlite "$dec_db" || return 1; }

    local db_dir="$state_dir/data" db_path
    db_path="$db_dir/db.sqlite3"
    mkdir -p "$db_dir"

    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local pre_restore_copy=""
    if [[ -f "$db_path" ]]; then
        pre_restore_copy="${db_path}.pre-restore-${ts}"
        log_info "Creating pre-restore copy: $(basename "$pre_restore_copy")..."
        cp -a "$db_path" "$pre_restore_copy" || {
            log_error "Failed to create pre-restore copy — aborting restore."; return 1
        }
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would overwrite $db_path with decrypted database"
        # shellcheck disable=SC2015  # intentional cleanup: swallow rm failure
        [[ -n "$pre_restore_copy" ]] && rm -f "$pre_restore_copy" 2>/dev/null || true
        return 0
    fi

    log_info "Restoring database..."
    if docker compose ps --status running 2>/dev/null | grep -q vaultwarden_app; then
        log_warn "vaultwarden_app container still running — attempting WAL checkpoint on live DB..."
        sqlite3 "$db_path" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || \
            log_warn "Live WAL checkpoint failed (non-fatal; continuing restore)."
    fi
    # Write to a temp file on the same filesystem as db_path, then
    # atomically rename. This avoids leaving db_path in a partial-write state
    # if the process is interrupted mid-copy.
    local db_tmp
    db_tmp="${db_path}.restore_$$_$(date +%s).tmp"
    if cp -f "$dec_db" "$db_tmp" && mv "$db_tmp" "$db_path"; then
        :
    else
        rm -f "$db_tmp" 2>/dev/null || true
        log_error "atomic write to live DB failed — rolling back..."
        if [[ -n "$pre_restore_copy" && -f "$pre_restore_copy" ]]; then
            if cp -a "$pre_restore_copy" "$db_path"; then
                log_warn "Rollback successful."
            else
                log_error "CRITICAL: Rollback failed. Manual recovery:"
                log_error "  cp '${pre_restore_copy}' '${db_path}'"
            fi
        fi
        return 1
    fi
    # shellcheck disable=SC2015  # intentional cleanup: swallow rm failure
    [[ -n "$pre_restore_copy" ]] && rm -f "$pre_restore_copy" 2>/dev/null || true

    purge_wal_shm "$db_path"
    chown "${puid}:${pgid}" "$db_path" 2>/dev/null || log_warn "Could not set ownership on $db_path"
    chmod 640 "$db_path" 2>/dev/null || true
    log_success "Database restored successfully."
}

_stage_emergency_private_key_in_control_workspace() {
    local extracted_root="$1" source_key
    source_key="$extracted_root/etc/vaultwarden/age-key.txt"
    [[ "$RESTORE_TYPE" == "emergency" && -e "$source_key" ]] || return 0
    [[ -f "$source_key" && ! -L "$source_key" ]] || {
        log_error "Emergency archive Age key member is not a regular file: $source_key"
        return 1
    }
    local staged_key="$CONTROL_WORKSPACE/emergency-capsule-age-key.txt"
    [[ ! -e "$staged_key" && ! -L "$staged_key" ]] || {
        log_error "Emergency Age key control path already exists: $staged_key"
        return 1
    }
    install -m 0600 "$source_key" "$staged_key" || return 1
    rm -f -- "$source_key" || {
        rm -f -- "$staged_key" 2>/dev/null || true
        log_error "Could not remove the emergency private key from payload staging."
        return 1
    }
    RESTORE_EMERGENCY_STAGED_KEY_FILE="$staged_key"
    log_info "Moved emergency private key from payload staging into the secure control workspace."
}

restore_full() {
    local backup_file="$1" age_key_file="$2" state_dir="$3" puid="$4" pgid="$5" tmpdir="$6" archive_format="$7"

    local inner_name="${backup_file%.age}"
    case "$inner_name" in
        *.tar.zst|*.tar.gz|*.tar.bz2|*.tar.xz|*.tgz|*.tbz) : ;;
        *) inner_name="${inner_name}.tar.gz" ;;
    esac
    local dec_tar
    dec_tar="$tmpdir/$(basename "$inner_name")"
    local tar_filter; tar_filter="$(_tar_filter_for_file "$dec_tar")"

    if [[ ! -s "$dec_tar" ]]; then
        log_info "Decrypting archive..."
        local age_err="$CONTROL_WORKSPACE/age-decrypt.err"
        if ! _age_decrypt_restore_backup "$backup_file" "$age_key_file" "$dec_tar" "$age_err" "$(_restore_backup_encryption_mode)"; then
            if grep -qi 'no identity matched any of the recipients' "$age_err" 2>/dev/null; then
                _restore_age_no_identity_guidance
            else
                log_error "Decryption failed — verify the age key is correct."
                log_hint "Use --key-file /path/to/the/old-age-key.txt for the key that encrypted this backup."
                log_hint "If you exported a recovery kit, retry with --from-recovery-kit /path/to/recovery-kit.txt."
            fi
            return 1
        fi
    fi

    if [[ "$SKIP_VERIFICATION" != "true" ]]; then
        log_info "Verifying archive structure..."
        # shellcheck disable=SC2086
        tar $tar_filter -tf "$dec_tar" >/dev/null || { log_error "Archive is corrupt or invalid"; return 1; }
    fi

    if [[ "$archive_format" == "absolute" ]]; then
        log_warn "Legacy archive format detected (version=1, absolute paths). Using staged extraction before live promotion."
        # Always run traversal check regardless of SKIP_VERIFICATION.
        # Legacy member grammar permits leading '/', so do not apply the relative-member validator here.
        check_traversal_only "$dec_tar" || return 1
        log_success "Archive traversal check passed (legacy format)."
    elif [[ "$SKIP_VERIFICATION" != "true" ]]; then
        tar_validate_members "$dec_tar" || return 1
    fi

    [[ "$DRY_RUN" == "true" ]] && { log_info "[DRY RUN] Would extract archive into secure staging and promote the selected state/config paths."; return 0; }

    local staging="$tmpdir/stage"
    mkdir -p "$staging"
    log_info "Extracting archive to staging directory..."
    if ! _tar_extract_archive "$dec_tar" "$staging" "$tar_filter"; then
        log_error "Archive extraction into restore staging failed; live state has not been promoted."
        return 1
    fi

    local source_root="${RESTORE_PREFLIGHT_SOURCE_ROOT:-$state_dir}"
    local rel_source="${source_root#/}"
    if [[ ! -d "$staging/$rel_source" ]]; then
        log_error "Staging validation failed: expected source directory not found: $staging/$rel_source"
        # shellcheck disable=SC2086
        tar $tar_filter -tf "$dec_tar" | head -20 >&2 || true
        return 1
    fi

    _stage_emergency_private_key_in_control_workspace "$staging" || return 1

    local ts; ts="$(date +%Y%m%d-%H%M%S)"

    if mountpoint -q "$state_dir" 2>/dev/null; then
        # Separate-volume mode: rsync is required — fail early before touching data.
        if ! command -v rsync >/dev/null 2>&1; then
            log_error "rsync is required for block-volume restores but is not installed."
            log_error "Install it first:  sudo apt-get install -y rsync"
            log_error "Then re-run the restore — no data has been moved."
            return 1
        fi
        # Separate-volume mode: state_dir is a live mountpoint — mv would fail
        # with "Device or resource busy".  Promote only application payload
        # directories that are safe to snapshot and replace.  Never move volume
        # or project metadata such as .vw-data-volume, .pre-restore-*,
        # lost+found, backups, secrets, or config during this destructive phase:
        # those paths keep the live project recoverable if promotion fails.
        local _snap_dir="${state_dir}/.pre-restore-${ts}"
        mkdir -p "$_snap_dir"
        log_info "Backing up replaceable payload paths to in-volume snapshot: $(basename "$_snap_dir") ..."

        local -a _restore_payload_allowlist=(data caddy logs)
        local -a _moved_payload_paths=()
        local -a _created_payload_paths=()
        local _payload_name _live_payload _staged_payload

        _rollback_payload_paths() {
            local _rollback_path _rollback_name _created_path rollback_failed=false
            log_error "Attempting rollback of payload paths already moved into: $_snap_dir"
            for _created_path in "${_created_payload_paths[@]}"; do
                if [[ -e "$_created_path" ]]; then
                    if rm -rf -- "$_created_path"; then
                        log_warn "Rollback removed newly-created restore path: $_created_path"
                    else
                        log_error "Rollback failed to remove newly-created restore path: $_created_path"
                        rollback_failed=true
                    fi
                fi
            done
            for _rollback_path in "${_moved_payload_paths[@]}"; do
                _rollback_name="$(basename "$_rollback_path")"
                if [[ -e "$_snap_dir/$_rollback_name" ]]; then
                    rm -rf -- "$_rollback_path" 2>/dev/null || true
                    if mv "$_snap_dir/$_rollback_name" "$_rollback_path"; then
                        log_warn "Rollback restored: $_rollback_path"
                    else
                        log_error "Rollback failed for $_rollback_path"
                        log_error "Manual recovery: mv '$_snap_dir/$_rollback_name' '$_rollback_path'"
                        rollback_failed=true
                    fi
                fi
            done
            [[ "$rollback_failed" != "true" ]]
        }

        for _payload_name in "${_restore_payload_allowlist[@]}"; do
            _live_payload="$state_dir/$_payload_name"
            _staged_payload="$staging/$rel_source/$_payload_name"

            if [[ ! -e "$_staged_payload" ]]; then
                log_info "  Skipping $_payload_name/ (not present in restored archive)"
                continue
            fi

            if [[ -e "$_live_payload" ]]; then
                log_info "  Snapshotting live $_payload_name/"
                if mv "$_live_payload" "$_snap_dir/"; then
                    _moved_payload_paths+=("$_live_payload")
                else
                    log_error "Failed to move $_live_payload into snapshot — aborting."
                    log_error "Protected paths were not touched: .vw-data-volume, lost+found, backups, secrets, config"
                    log_error "Partial snapshot at: $_snap_dir"
                    _rollback_payload_paths \
                        || _restore_retain_payload_for_manual_recovery "mounted-volume rollback" || true
                    return 1
                fi
            else
                _created_payload_paths+=("$_live_payload")
            fi
        done

        log_info "State payload restore phase: promoting allowlisted directories only (data, caddy, logs)."
        for _payload_name in "${_restore_payload_allowlist[@]}"; do
            _staged_payload="$staging/$rel_source/$_payload_name"
            [[ -e "$_staged_payload" ]] || continue
            if ! rsync -a --no-owner --no-group "$_staged_payload/" "$state_dir/$_payload_name/"; then
                log_error "rsync of staged $_payload_name/ to $state_dir failed."
                _rollback_payload_paths \
                    || _restore_retain_payload_for_manual_recovery "mounted-volume rollback" || true
                return 1
            fi
            log_info "  Promoted: $_payload_name/"
        done
        log_warn "Archive backups/, secrets/, and config/ under $state_dir were intentionally not promoted."
        unset -f _rollback_payload_paths
    else
        if [[ "$source_root" == "$state_dir" ]]; then
            # Boot-only same-layout mode: first materialize the selected staged
            # state beside STATE_DIR, then use only target-filesystem renames for
            # the destructive swap. The payload workspace is already on the
            # target filesystem, but it is not the final rename source.
            local old_state_snapshot="" target_staging promotion_marker
            _restore_create_owned_workspace \
                PROMOTION_WORKSPACE PROMOTION_WORKSPACE_ID \
                "$(dirname "$state_dir")" "$(basename "$state_dir").restore-workspace" || {
                log_error "Failed to create target-filesystem restore staging sibling for $state_dir."
                return 1
            }
            target_staging="$PROMOTION_WORKSPACE/state"

            log_info "Materializing staged state on the target filesystem before promotion..."
            if ! cp -a "$staging/$rel_source" "$target_staging"; then
                log_error "Failed to materialize staged state at $target_staging; live state has not been moved."
                return 1
            fi

            promotion_marker="$(mktemp "$target_staging/.restore-promotion.XXXXXXXX")" || {
                log_error "Failed to mark target-filesystem restore staging; live state has not been moved."
                return 1
            }
            promotion_marker="$(basename "$promotion_marker")"

            if [[ -d "$state_dir" ]]; then
                old_state_snapshot="${state_dir}.pre-restore-${ts}"
                if ! mv "$state_dir" "$old_state_snapshot"; then
                    log_error "Failed to move live state into pre-restore snapshot; promotion was not attempted."
                    return 1
                fi
            fi

            log_info "State payload restore phase: promoting target-filesystem staged state directory to live path..."
            if ! mv "$target_staging" "$state_dir"; then
                log_error "Failed to promote target-filesystem staged state into $state_dir."
                if [[ -e "$state_dir" ]]; then
                    if [[ -e "$state_dir/$promotion_marker" ]]; then
                        log_warn "Removing incomplete canonical state created by the failed promotion attempt: $state_dir"
                        if ! rm -rf "$state_dir"; then
                            log_error "CRITICAL: Failed to remove incomplete restore destination: $state_dir"
                            if [[ -n "$old_state_snapshot" && -e "$old_state_snapshot" ]]; then
                                log_error "Manual recovery after verifying the failed destination: rm -rf '$state_dir' && mv '$old_state_snapshot' '$state_dir'"
                            fi
                            _restore_retain_payload_for_manual_recovery "boot-volume promotion recovery" || true
                            return 1
                        fi
                    else
                        log_error "CRITICAL: Canonical state path appeared without this promotion marker: $state_dir"
                        if [[ -n "$old_state_snapshot" && -e "$old_state_snapshot" ]]; then
                            log_error "Manual recovery after inspecting '$state_dir': rm -rf '$state_dir' && mv '$old_state_snapshot' '$state_dir'"
                        fi
                        _restore_retain_payload_for_manual_recovery "boot-volume promotion recovery" || true
                        return 1
                    fi
                fi
                if [[ -n "$old_state_snapshot" && -e "$old_state_snapshot" ]]; then
                    if mv "$old_state_snapshot" "$state_dir"; then
                        log_warn "Restore promotion rollback succeeded: restored previous state to $state_dir."
                    else
                        log_error "CRITICAL: restore promotion rollback failed. Manual recovery: mv '$old_state_snapshot' '$state_dir'"
                        _restore_retain_payload_for_manual_recovery "boot-volume promotion rollback" || true
                    fi
                fi
                return 1
            fi
            if _restore_remove_owned_workspace \
                "$PROMOTION_WORKSPACE" "$PROMOTION_WORKSPACE_ID" promotion; then
                PROMOTION_WORKSPACE=""; PROMOTION_WORKSPACE_ID=""
            fi
            if ! rm -f "$state_dir/$promotion_marker"; then
                log_warn "Could not remove restore promotion marker: $state_dir/$promotion_marker"
            fi
        else
            # Cross-layout mode: never move arbitrary source-root contents into
            # the target. Promote only the same conservative state payload
            # allowlist used for mounted block volumes.
            mkdir -p "$state_dir"
            local -a _restore_payload_allowlist=(data caddy logs)
            local _payload_name _live_payload _staged_payload
            for _payload_name in "${_restore_payload_allowlist[@]}"; do
                _live_payload="$state_dir/$_payload_name"
                _staged_payload="$staging/$rel_source/$_payload_name"
                [[ -e "$_staged_payload" ]] || { log_info "  Skipping $_payload_name/ (not present in restored archive)"; continue; }
                [[ -e "$_live_payload" ]] && mv "$_live_payload" "${_live_payload}.pre-restore-${ts}"
                mkdir -p "$_live_payload"
                cp -a "$_staged_payload/." "$_live_payload/"
                log_info "  Promoted: $_payload_name/"
            done
            log_warn "Cross-layout restore did not promote backups/, secrets/, config/, .pre-restore-*, repo files, or scripts."
        fi
    fi

    if [[ "$RESTORE_TYPE" =~ ^(full|emergency)$ ]]; then
        log_info "Skipped runtime decrypted secrets (/run/vaultwarden-oci/secrets)."
        local _staged_secret="$staging/$rel_source/secrets/secrets.yaml"
        local _live_secret="${SECRETS_FILE:-$state_dir/secrets/secrets.yaml}"
        [[ "$_live_secret" != /* ]] && _live_secret="$PROJECT_ROOT/$_live_secret"
        if [[ -f "$_staged_secret" ]]; then
            install -d -m 700 "$(dirname "$_live_secret")"
            install -m 600 "$_staged_secret" "$_live_secret"
            chown root:root "$_live_secret" 2>/dev/null || true
            log_info "Promoted encrypted SOPS secrets: $_live_secret"
        elif [[ -f "$_live_secret" ]]; then
            chmod 600 "$_live_secret" 2>/dev/null || true
            chown root:root "$_live_secret" 2>/dev/null || true
            log_info "Promoted encrypted SOPS secrets: $_live_secret"
        else
            log_warn "Encrypted SOPS secrets not present in archive at $rel_source/secrets/secrets.yaml"
        fi
    fi

    # Ensure storage sentinel survives restores in separate-volume mode.
    # Primary path: DATA_VOLUME_MOUNT is populated (normal operation).
    # Fallback path: DATA_VOLUME_MOUNT was not exported (partial env load) but
    #   PROJECT_STATE_DIR is set and is itself a live mountpoint — in
    #   separate-volume mode these two variables always resolve to the same path,
    #   so the sentinel write is safe and correct.
    _sentinel_dir=""
    if [[ -n "${DATA_VOLUME_MOUNT:-}" ]] && mountpoint -q "${DATA_VOLUME_MOUNT}" 2>/dev/null; then
        _sentinel_dir="${DATA_VOLUME_MOUNT}"
    elif [[ -n "${state_dir:-}" ]] && mountpoint -q "${state_dir}" 2>/dev/null; then
        _sentinel_dir="${state_dir}"
    fi
    if [[ -n "$_sentinel_dir" ]]; then
        _restore_ensure_volume_sentinel "$_sentinel_dir" "${DATA_VOLUME_DEVICE:-}" || \
            log_warn "Could not ensure volume sentinel at ${_sentinel_dir}/.vw-data-volume"
    fi
    unset _sentinel_dir

    chown -R "${puid}:${pgid}" "$state_dir/data" 2>/dev/null || log_warn "Could not set ownership on $state_dir/data"
    purge_wal_shm "$state_dir/data/db.sqlite3" || true

    if [[ "$RESTORE_TYPE" == "emergency" && -d "$staging/etc/vaultwarden" ]]; then
        log_info "Installed emergency /etc/vaultwarden material"
        log_info "Emergency capsule restore phase: installing staged /etc/vaultwarden key/config material..."
        install -d -o root -g root -m 700 /etc/vaultwarden
        local _emergency_file
        for _emergency_file in age-key.txt vaultwarden.env rclone.conf; do
            local _emergency_source="$staging/etc/vaultwarden/$_emergency_file"
            if [[ "$_emergency_file" == "age-key.txt" && -n "$RESTORE_EMERGENCY_STAGED_KEY_FILE" ]]; then
                _emergency_source="$RESTORE_EMERGENCY_STAGED_KEY_FILE"
            fi
            if [[ -f "$_emergency_source" ]]; then
                install -o root -g root -m 600 "$_emergency_source" "/etc/vaultwarden/$_emergency_file"
                log_info "  Installed /etc/vaultwarden/$_emergency_file (0600)"
            fi
        done
    fi

    local rel_project="${PROJECT_ROOT#/}"

    # Predictive warning: if the archive does not contain project config files
    # (e.g. the user selected a 'db'-type backup expecting a 'full' restore),
    # warn before the config loop runs so the operator knows immediately.
    if [[ ! -d "$staging/$rel_project" ]]; then
        log_warn "Project config directory not found in archive ($rel_project) — .env and docker-compose.yml will NOT be restored from this archive."
        log_warn "If you expected config files, verify the archive type is 'full', not 'db'."
    fi

    if [[ -d "$staging/$rel_project" ]]; then
        log_info "Project config restore phase: restoring explicit config files from archive (scripts and secrets excluded)."
        local config_files=(docker-compose.yml docker-compose.override.yml .env.example)
        [[ "$RESTORE_ENV" == "true" ]] && config_files=(.env "${config_files[@]}")
        for f in "${config_files[@]}"; do
            local src="$staging/$rel_project/$f"
            if [[ -f "$src" ]]; then
                if [[ "$f" == ".env" && -f "$PROJECT_ROOT/.env" ]]; then
                    local _ts_env; _ts_env=$(date +%Y%m%d-%H%M%S)
                    local _old_umask_env; _old_umask_env=$(umask)
                    umask 077
                    if ! cp -f "$PROJECT_ROOT/.env" "$PROJECT_ROOT/.env.pre-restore-${_ts_env}" 2>/dev/null; then
                        log_warn "Could not create .env pre-restore backup — proceeding without it"
                    fi
                    umask "$_old_umask_env"
                fi
                cp -f "$src" "$PROJECT_ROOT/$f"
                log_info "  Restored: $f"
            fi
        done
        for d in caddy crowdsec nginx; do
            local src_dir="$staging/$rel_project/$d" dst_dir="$PROJECT_ROOT/$d"
            if [[ -d "$src_dir" ]]; then
                [[ -d "$dst_dir" ]] && cp -a "$dst_dir" "${dst_dir}.pre-restore-${ts}" && \
                    log_info "  Backed up existing $d/ to ${d}.pre-restore-${ts}/"
                mkdir -p "$dst_dir"
                cp -a "$src_dir/." "$dst_dir/"
                log_info "  Restored: $d/"
            fi
        done
        log_success "Project config files restored from archive."
        log_warn  "secrets/ and *.sh scripts were intentionally not restored."
    else
        log_warn "Project root not found in staging ($rel_project) — config files not restored."
    fi

    log_success "Full restore promotion completed from staging."
}

main() {
    log_header "VaultWarden-OCI Restore Utility"
    local config_status=0

    if [[ "$LIST_ONLY" == "true" ]]; then
        load_env_file || config_status=$?
        if (( config_status != 0 )); then
            if (( config_status == 2 )) && [[ "$LIST_REMOTE" == "true" ]]; then
                log_warn "No project environment found — using session-only remote recovery configuration."
            else
                log_error "Failed to load project environment for restore inventory."
                exit 1
            fi
        fi
        check_dependencies

        local _early_state_dir
        _early_state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
        BACKUP_BASE_DIR="$(get_config_value "BACKUP_DIR" "${_early_state_dir}/backups")"
        log_info "Backup storage root: $BACKUP_BASE_DIR"

        if [[ "$LIST_REMOTE" == "true" ]]; then
            if ! _rclone_is_available; then
                if [[ "$RCLONE_NEEDS_INTERACTIVE_NAME" == "true" ]]; then
                    _prompt_rclone_remote_name || exit 1
                    if ! _rclone_is_available; then
                        _rclone_diagnose; exit 1
                    fi
                else
                    _rclone_diagnose; exit 1
                fi
            fi
            _build_rclone_config_arg || exit 1
            list_remote_backups
        else
            list_backups
        fi
        exit 0
    fi

    require_root "$@"
    load_env_file || config_status=$?
    if (( config_status != 0 )); then
        if (( config_status == 2 )) \
            && [[ "$USE_REMOTE" == "true" ]] \
            && [[ "${_ORIGINAL_ARGS[0]}" == "interactive" || "${_ORIGINAL_ARGS[0]}" == "inspect" ]]; then
            log_warn "No project environment found — operating in bootstrap/emergency-restore mode."
            log_warn "PUID, PGID, and Age key will be prompted if not set."
        else
            log_error "Failed to load project environment."
            exit 1
        fi
    fi

    check_dependencies

    if [[ "$DRY_RUN" != "true" && "$INSPECT_ONLY" != "true" ]]; then
        operation_acquire \
            --id restore \
            --label "Restore" \
            --specific-lock /run/lock/vaultwarden-restore.lock || exit $?
        operation_set_phase "prepare" "Preparing restore"
    fi

    # Fail closed if a block/data volume is configured.  --force --remote may
    # skip this check only for boot-volume/bootstrap mode where no block device
    # is configured; it must never permit writes to an unmounted block-volume path.
    local _configured_data_device _state_ready_required=true
    _configured_data_device="$(get_config_value "DATA_VOLUME_DEVICE" "")"
    if [[ "$INSPECT_ONLY" == "true" ]]; then
        _state_ready_required=false
        if [[ -n "$_configured_data_device" ]]; then
            log_info "Inspect mode: validating configured data-volume ownership before staging."
            check_project_state_ready || exit 1
        else
            log_warn "Inspect mode: skipping live project-state readiness enforcement; storage readiness will be reported by restore preflight."
        fi
    elif [[ "$FORCE" == "true" && "$USE_REMOTE" == "true" && -z "$_configured_data_device" ]]; then
        _state_ready_required=false
        log_warn "Skipping project-state-ready check (--force --remote boot-volume/bootstrap mode)."
        log_warn "No DATA_VOLUME_DEVICE is configured; block-volume safety checks remain required when a data volume is configured."
    else
        check_project_state_ready || exit 1
    fi

    # Derive the fallback from PROJECT_STATE_DIR so separate-volume installs
    # that have not explicitly set BACKUP_DIR still resolve to the correct volume.
    local STATE_DIR; STATE_DIR="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    BACKUP_BASE_DIR="$(get_config_value "BACKUP_DIR" "${STATE_DIR}/backups")"
    local OPERATIONAL_SOPS_AGE_KEY_FILE; OPERATIONAL_SOPS_AGE_KEY_FILE="$(get_config_value "SOPS_AGE_KEY_FILE" "secrets/keys/age-key.txt")"
    RESTORE_DECRYPT_AGE_KEY_FILE=""
    RESTORE_REKEY_SOURCE_AGE_KEY_FILE=""
    local PUID PGID
    PUID="$(get_config_value "PUID" "")"
    PGID="$(get_config_value "PGID" "")"
    # Sanitise: strip carriage returns, surrounding whitespace, and inline
    # comments (e.g. "1000 # set by setup.sh") before any emptiness check.
    PUID="${PUID//$'\r'/}"; PUID="${PUID%%[[:space:]#]*}"; PUID="${PUID//[[:space:]]/}"
    PGID="${PGID//$'\r'/}"; PGID="${PGID%%[[:space:]#]*}"; PGID="${PGID//[[:space:]]/}"

    if [[ -z "$PUID" || -z "$PGID" ]]; then
        # Tier 2: sudo injects the real caller's numeric UID/GID directly.
        if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" \
              && "${SUDO_UID}" =~ ^[0-9]+$ \
              && "${SUDO_GID}" =~ ^[0-9]+$ ]]; then
            [[ -z "$PUID" ]] && { PUID="$SUDO_UID"; log_warn "PUID not set in .env — auto-detected via SUDO_UID: $PUID (user: ${SUDO_USER:-unknown})"; }
            [[ -z "$PGID" ]] && { PGID="$SUDO_GID"; log_warn "PGID not set in .env — auto-detected via SUDO_GID: $PGID (user: ${SUDO_USER:-unknown})"; }
        fi
    fi

    if [[ -z "$PUID" || -z "$PGID" ]]; then
        # Tier 3: named service user (non-sudo / scripted / CI pipelines).
        local _svc_user="${VAULTWARDEN_USER:-vaultwarden}"
        local _svc_puid _svc_pgid
        _svc_puid="$(id -u "$_svc_user" 2>/dev/null || true)"
        _svc_pgid="$(id -g "$_svc_user" 2>/dev/null || true)"
        if [[ "$_svc_puid" =~ ^[0-9]+$ && "$_svc_pgid" =~ ^[0-9]+$ ]]; then
            [[ -z "$PUID" ]] && { PUID="$_svc_puid"; log_warn "PUID not set in .env — auto-detected from service user '${_svc_user}': $PUID"; }
            [[ -z "$PGID" ]] && { PGID="$_svc_pgid"; log_warn "PGID not set in .env — auto-detected from service user '${_svc_user}': $PGID"; }
        fi
    fi
    # Validate that PUID and PGID are numeric and within valid UID/GID range.
    if ! [[ "$PUID" =~ ^[0-9]+$ ]] || (( PUID < 100 || PUID > 65534 )); then
        log_error "PUID must be a non-root numeric UID between 100 and 65534 (got: '$PUID')"
        log_error "Find your user UID with: id -u <your-username>"
        exit 1
    fi
    if ! [[ "$PGID" =~ ^[0-9]+$ ]] || (( PGID < 100 || PGID > 65534 )); then
        log_error "PGID must be a non-root numeric GID between 100 and 65534 (got: '$PGID')"
        log_error "Find your group GID with: id -g <your-username>"
        exit 1
    fi

    _restore_create_control_workspace || exit 1
    _restore_create_payload_workspace "$STATE_DIR" || exit 1

    # Recovery-kit and pasted private keys remain in the small control workspace.
    _load_recovery_kit || exit 1

    resolve_backup_file || exit 1
    [[ -f "$BACKUP_FILE" ]] || { log_error "Backup file not found: $BACKUP_FILE"; exit 1; }
    check_archive_dependencies "$BACKUP_FILE"
    _restore_preflight_local_decrypt_capacity "$BACKUP_FILE" || exit 1

    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Selected backup file:"
    log_info "    $(basename "$BACKUP_FILE")"
    log_info "    Path: $BACKUP_FILE"
    log_info "    Type: $RESTORE_TYPE"
    local _bkp_size
    _bkp_size=$(du -sh "$BACKUP_FILE" 2>/dev/null | cut -f1 || echo "unknown")
    log_info "    Size: $_bkp_size"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local sha256_sidecar="${BACKUP_FILE}.sha256"
    if [[ -f "$sha256_sidecar" && "$SKIP_VERIFICATION" != "true" ]]; then
        log_info "Verifying backup checksum before decryption..."
        local expected_sum actual_sum
        expected_sum=$(awk '{print $1}' "$sha256_sidecar")
        actual_sum=$(sha256sum "$BACKUP_FILE" | awk '{print $1}')
        if [[ "$expected_sum" != "$actual_sum" ]]; then
            log_error "Checksum MISMATCH — backup file may be corrupted or tampered."
            log_error "  Expected: $expected_sum"
            log_error "  Actual:   $actual_sum"
            log_error "  Try an older backup from the backup directory, or re-download from offsite storage."
            exit 1
        fi
        log_success "Backup checksum verified: $(basename "$BACKUP_FILE")"
    elif [[ -f "$sha256_sidecar" && "$SKIP_VERIFICATION" == "true" ]]; then
        log_warn "--skip-verification: SHA-256 sidecar check bypassed."
    else
        log_warn "No .sha256 sidecar found — skipping pre-decryption checksum check."
    fi

    local meta_file="${BACKUP_FILE}.meta"
    local archive_version; archive_version="$(read_meta_field "$meta_file" "version" "")"
    local archive_format;  archive_format="$(read_meta_field  "$meta_file" "archive_format" "")"
    local backup_encryption_mode; backup_encryption_mode="$(read_meta_field "$meta_file" "encryption_mode" "")"

    if [[ -z "$archive_format" ]]; then
        if   [[ "$BACKUP_FILE" == *.tar.zst.age || "$BACKUP_FILE" == *.zst.age ]]; then
            archive_format="relative"
            log_info "archive_format inferred 'relative' from .zst extension."
        elif [[ "$archive_version" == "2" ]]; then archive_format="relative"
        elif [[ "$archive_version" == "1" ]]; then archive_format="absolute"
        else
            archive_format="relative"
            log_warn "archive_format absent from .meta; defaulting to 'relative'."
        fi
    fi
    [[ -z "$archive_version" ]] && archive_version="unknown"

    if [[ "$RESTORE_TYPE" == "emergency" ]]; then
        if [[ ! -s "$meta_file" ]]; then
            log_error "Emergency restore requires a non-empty metadata sidecar: $meta_file"
            log_error "Cannot select passphrase versus Age-recipient decryption safely."
            exit 1
        fi
        case "$backup_encryption_mode" in
            age-passphrase|age-recipient)
                ;;
            "")
                log_error "Emergency backup metadata is missing encryption_mode; refusing ambiguous decrypt dispatch."
                exit 1
                ;;
            *)
                log_error "Unsupported emergency backup encryption_mode: '$backup_encryption_mode'"
                log_error "Supported emergency modes: age-passphrase, age-recipient"
                exit 1
                ;;
        esac
        log_info "Emergency backup encryption mode: ${backup_encryption_mode}"
        if [[ -n "${EMERGENCY_BACKUP_AGE_IDENTITY_FILE:-}" && ! -f "$EMERGENCY_BACKUP_AGE_IDENTITY_FILE" ]]; then
            log_error "EMERGENCY_BACKUP_AGE_IDENTITY_FILE is set but file not found: $EMERGENCY_BACKUP_AGE_IDENTITY_FILE"
            log_error "Fix the path in .env or unset it to use the standard key prompt."
            exit 1
        fi
        if [[ "$backup_encryption_mode" == "age-recipient" \
              && -z "$KEY_FILE_ARG" && -z "$RECOVERY_KIT_FILE" && -z "${RESTORE_AGE_KEY_FILE:-}" ]]; then
            log_warn "No explicit key supplied; will use configured key:"
            log_warn "  $OPERATIONAL_SOPS_AGE_KEY_FILE"
            log_warn "If this backup was encrypted with an older key, re-run with:"
            log_warn "  --key-file /path/to/old-key.txt"
            log_warn "  --from-recovery-kit /path/to/recovery-kit.txt"
        fi
    fi

    _print_restore_plan_summary

    if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" && "$INSPECT_ONLY" != "true" ]]; then
        operator_attention warn "Destructive restore confirmation" \
            "Current VaultWarden data will be overwritten." \
            "Services will be stopped during the restore." \
            "A NEW Age key will be generated after the restore."
        if [[ ! -t 0 ]]; then
            log_error "Cannot confirm restore: stdin is not a TTY. Re-run with --force for non-interactive restore."
            exit 1
        fi
        if ! operator_confirm_yes_no "Proceed with destructive restore?" "no" 300; then
            log_info "Restore cancelled."
            exit 0
        fi
    fi

    if [[ "$RESTORE_TYPE" == "emergency" && "$backup_encryption_mode" == "age-passphrase" ]]; then
        RESTORE_DECRYPT_AGE_KEY_FILE=""
        log_info "Emergency backup is passphrase-sealed; age will prompt for the emergency passphrase that decrypts the selected archive."
    else
        _prompt_age_key "$OPERATIONAL_SOPS_AGE_KEY_FILE" || exit 1
    fi

    _require_selected_archive_tools "$BACKUP_FILE" || exit 1

    if [[ "$RESTORE_TYPE" =~ ^(full|emergency)$ ]]; then
        log_warn "Full/emergency restore replaces application state/config and may require the same expected storage class."
        local _preflight_tar
        _preflight_tar="$(_decrypt_restore_archive_for_preflight \
            "$BACKUP_FILE" "$RESTORE_DECRYPT_AGE_KEY_FILE" \
            "$PAYLOAD_WORKSPACE" "$CONTROL_WORKSPACE")" || exit 1
        if [[ "$archive_format" == "absolute" ]]; then
            check_traversal_only "$_preflight_tar" || exit 1
        else
            tar_validate_members "$_preflight_tar" || exit 1
        fi
        restore_full_preflight "$BACKUP_FILE" "$_preflight_tar" "$STATE_DIR" "$PUID" "$PGID" "$archive_format" "$archive_version" || exit 1
        _restore_preflight_archive_expansion_capacity "$_preflight_tar" || exit 1
        if [[ "$INSPECT_ONLY" == "true" ]]; then
            log_success "Inspect mode complete — no services stopped, no files restored, no key rotation, no health check."
            exit 0
        fi
    elif [[ "$RESTORE_TYPE" == "db" ]]; then
        log_info "DB restore is storage-layout independent and is the safest path when only Vaultwarden data is needed."
        _stage_db_restore_for_preflight "$BACKUP_FILE" "$RESTORE_DECRYPT_AGE_KEY_FILE" "$STATE_DIR" || exit 1
        if [[ "$INSPECT_ONLY" == "true" ]]; then
            log_success "Inspect mode: DB backup integrity check passed."
            log_success "Inspect mode complete — no services stopped, no files restored, no key rotation, no health check."
            exit 0
        fi
    fi

    # All selected-archive, target-space, and structure checks have passed.
    # Only now may normal readiness repair or live permission mutation begin.
    if [[ "$_state_ready_required" == "true" ]]; then
        require_project_state_ready || exit 1
    fi
    auto_fix_critical_permissions "$PROJECT_ROOT"

    if [[ "$RESTORE_TYPE" =~ ^(full|emergency)$ ]] && [[ "$DRY_RUN" != "true" ]]; then
        local _target_mode_for_prepare
        _target_mode_for_prepare="$(_detect_storage_mode "$STATE_DIR" "$(get_config_value "DATA_VOLUME_MOUNT" "")" "$(get_config_value "DATA_VOLUME_DEVICE" "")")"
        if [[ "$_target_mode_for_prepare" == "block" ]]; then
            log_info "Target preparation phase: verifying and repairing mounted block-storage directories..."
            _restore_prepare_block_target "$STATE_DIR" "$PUID" "$PGID" "$_preflight_tar" || exit 1
        fi
    fi

    create_pre_restore_snapshot "$OPERATIONAL_SOPS_AGE_KEY_FILE" "$RESTORE_TYPE" || exit 1
    _set_snapshot_operation_phase || exit 1

    RESTORE_DESTRUCTIVE_PHASE_STARTED=false
    _RESTORE_SAFETY_NET_RUNNING=false
    _restore_cleanup_once() {
        cleanup "${1:-$?}" || true
    }
    _restore_safety_net() {
        local rc="${1:-$?}"
        trap - ERR HUP INT TERM
        if [[ "${_RESTORE_SAFETY_NET_RUNNING:-false}" == "true" ]]; then
            exit "$rc"
        fi
        _RESTORE_SAFETY_NET_RUNNING=true
        [[ $rc -eq 130 ]] && log_warn "Restore interrupted by operator (Ctrl-C)."
        if [[ $rc -ne 0 ]]; then
            if [[ "${RESTORE_DESTRUCTIVE_PHASE_STARTED:-false}" == "true" ]]; then
                if [[ "${RESTORE_PREVENT_AUTOSTART:-false}" == "true" ]]; then
                    log_error "Restore stopped after confirmation-channel loss or manual-review requirement."
                    log_error "Automatic service startup is disabled for this failure."
                    _restore_print_manual_start_checklist
                elif [[ "${START_POLICY:-auto}" == "auto" ]]; then
                    if _can_safe_restart; then
                        log_warn "Integrity check passed — attempting one service restart..."
                        bash "${PROJECT_ROOT}/startup.sh" --skip-pull 2>/dev/null || \
                            log_error "CRITICAL: Service restart failed. Manual: sudo ./startup.sh --skip-pull"
                    else
                        log_error "Restore state is not eligible for automatic safety restart."
                        log_error "DB restores require an integrity-valid live DB; full/emergency restores also require committed promotion and rekey state."
                        log_error "Refusing automatic restart. Investigate before starting services."
                        log_error "Manual start checklist:"
                        _restore_print_manual_start_checklist
                    fi
                else
                    log_warn "Restore encountered an error (exit $rc) after destructive phase. Services may be stopped. Review state before starting."
                    _restore_print_manual_start_checklist
                fi
            else
                log_warn "Restore failed before destructive phase (exit $rc); services were not stopped and startup.sh will not be run."
            fi
        fi
        _restore_cleanup_once "$rc"
        exit "$rc"
    }

    trap '_restore_safety_net $?' ERR
    trap '_restore_safety_net 129' HUP
    trap '_restore_safety_net 130' INT
    trap '_restore_safety_net 143' TERM
    if [[ "$DRY_RUN" != "true" ]]; then
        operation_set_phase "stop" "Stopping VaultWarden services"
        log_info "Stopping services (up to 30s grace period)..."
        if ! timeout 35 docker compose stop --timeout 30; then
            log_warn "docker compose stop did not complete cleanly within 35s — forcing..."
            docker compose kill 2>/dev/null || true
        fi
        RESTORE_DESTRUCTIVE_PHASE_STARTED=true
    fi

    case "$RESTORE_TYPE" in
        db)
            operation_set_phase "restore-db" "Restoring database backup"
            restore_db "$BACKUP_FILE" "$RESTORE_DECRYPT_AGE_KEY_FILE" "$STATE_DIR" "$PUID" "$PGID" "$PAYLOAD_WORKSPACE"
            ;;
        full|emergency)
            RESTORE_DESTRUCTIVE_PHASE_STARTED=true
            operation_set_phase "restore-full" "Restoring full application state"
            restore_full "$BACKUP_FILE" "$RESTORE_DECRYPT_AGE_KEY_FILE" "$STATE_DIR" "$PUID" "$PGID" "$PAYLOAD_WORKSPACE" "$archive_format"
            ;;
        *)
            log_error "Unknown restore type: $RESTORE_TYPE"; exit 1 ;;
    esac

    if [[ "$DRY_RUN" != "true" ]]; then
        # Number of pre-restore artefacts to keep — shared by both code paths
        # so the retention policy stays consistent regardless of storage mode.
        local _keep_artefacts=3
        case "$RESTORE_TYPE" in
            db)
                cleanup_pre_restore_artefacts "${STATE_DIR}/data/db.sqlite3" "$_keep_artefacts" || true
                ;;
            full|emergency)
                if mountpoint -q "$STATE_DIR" 2>/dev/null; then
                    # Separate-volume mode: pre-restore snapshots are
                    # .pre-restore-TIMESTAMP directories *inside* STATE_DIR
                    # (created by the mountpoint-aware path in restore_full).
                    # cleanup_pre_restore_artefacts expects sibling paths, so
                    # handle this case directly.
                    local -a _vol_snaps=()
                    mapfile -t _vol_snaps < <(
                        # sort is chronological here because snapshot names
                        # contain a YYYYMMDD_HHMMSS timestamp suffix, making
                        # alphabetical order equivalent to oldest-first.
                        find "$STATE_DIR" -maxdepth 1 -name '.pre-restore-*' -type d \
                             2>/dev/null | sort
                    )
                    local _snap_count="${#_vol_snaps[@]}"
                    if (( _snap_count > _keep_artefacts )); then
                        local _to_remove=$(( _snap_count - _keep_artefacts ))
                        local i
                        for (( i=0; i<_to_remove; i++ )); do
                            if rm -rf "${_vol_snaps[$i]}"; then
                                log_info "  Pruned in-volume snapshot: $(basename "${_vol_snaps[$i]}")"
                            else
                                log_warn "  Failed to prune: ${_vol_snaps[$i]}"
                            fi
                        done
                    fi
                else
                    # Boot-only mode: pre-restore snapshots are sibling
                    # directories of STATE_DIR (STATE_DIR.pre-restore-*).
                    cleanup_pre_restore_artefacts "$STATE_DIR" "$_keep_artefacts" || true
                fi
                ;;
        esac
    fi

    # Choose the key that can decrypt secrets.yaml at the moment post-restore
    # SOPS updatekeys/rekey runs. DB restores do not restore secrets.yaml, so
    # use the live operational key. Full/emergency restores promote the encrypted
    # SOPS secrets from the archive, so secrets.yaml may require the selected
    # backup decrypt key regardless of storage layout.
    case "$RESTORE_TYPE" in
        db)
            RESTORE_REKEY_SOURCE_AGE_KEY_FILE="$OPERATIONAL_SOPS_AGE_KEY_FILE"
            ;;
        full|emergency)
            if [[ "$RESTORE_TYPE" == "emergency" && "$backup_encryption_mode" == "age-passphrase" ]]; then
                # restore_full moves the capsule key into control staging before
                # promotion and installs it under /etc/vaultwarden when present.
                if [[ -f /etc/vaultwarden/age-key.txt ]]; then
                    RESTORE_REKEY_SOURCE_AGE_KEY_FILE="/etc/vaultwarden/age-key.txt"
                elif [[ -n "$RESTORE_EMERGENCY_STAGED_KEY_FILE" \
                        && -f "$RESTORE_EMERGENCY_STAGED_KEY_FILE" ]]; then
                    RESTORE_REKEY_SOURCE_AGE_KEY_FILE="$RESTORE_EMERGENCY_STAGED_KEY_FILE"
                else
                    log_error "Passphrase emergency restore: cannot locate installed Age key for rekey."
                    log_error "Emergency archive did not contain /etc/vaultwarden/age-key.txt."
                    log_error "This archive may be malformed or incomplete."
                    exit 1
                fi
            else
                RESTORE_REKEY_SOURCE_AGE_KEY_FILE="$RESTORE_DECRYPT_AGE_KEY_FILE"
            fi
            ;;
        *) log_error "Unknown restore type for rekey source: $RESTORE_TYPE"; exit 1 ;;
    esac

    local _rotate_decision_rc=0
    _restore_should_rotate_age_key
    _rotate_decision_rc=$?
    if (( _rotate_decision_rc == 0 )); then
        if ! _rotate_age_key; then
            log_error "Age key rotation FAILED."
            log_error "The data restore itself succeeded, but key rotation/rekey did not complete safely."
            log_error "Live key artifacts were rolled back where needed; refusing to start services automatically."
            RESTORE_PREVENT_AUTOSTART=true
            exit 1
        fi
        if ! _display_new_key; then
            exit 1
        fi
    elif (( _rotate_decision_rc == 1 )); then
        log_warn "Age key rotation was skipped; confirm this is intentional before starting services."
    else
        log_error "Restore requires manual review before services are started."
        exit 1
    fi

    if [[ "$DRY_RUN" != "true" && "$RESTORE_TYPE" =~ ^(full|emergency)$ ]]; then
        RESTORE_FULL_PROMOTION_COMMITTED=true
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        # Full/emergency archives are extracted with --no-same-owner and
        # promoted with --no-owner/--no-group for cross-host safety. Re-apply
        # the target host runtime permission contract before service startup.
        if [[ "$RESTORE_TYPE" =~ ^(full|emergency)$ ]]; then
            log_info "Post-restore phase: repairing runtime state permissions..."
            if ! repair_runtime_state_permissions "$STATE_DIR" "$PUID" "$PGID"; then
                log_warn "Post-restore runtime permission repair reported issues."
                log_warn "Manual remediation: sudo utilities/repair-permissions.sh"
            fi
        fi
        if ! _restore_should_start_services; then
            trap - ERR HUP INT TERM
            auto_fix_critical_permissions "$PROJECT_ROOT"
            _print_post_restore_summary
            log_success "Restore complete; services were not started."
            return 0
        fi
        log_info "Starting services..."
        if ! bash "${PROJECT_ROOT}/startup.sh" --skip-pull; then
            log_error "Failed to start services after restore."
            log_error "Investigate with: docker compose logs --tail=50"
            exit 1
        fi
        # Services have started from committed restore artifacts. The pre-commit
        # safety net must not restart them again because of health or signal exits.
        trap - ERR HUP INT TERM

        local _health_timeout
        _health_timeout="${RESTORE_HEALTH_TIMEOUT:-$(get_config_value "RESTORE_HEALTH_TIMEOUT" "60")}"
        [[ "$_health_timeout" =~ ^[0-9]+$ ]] || _health_timeout=60
        (( _health_timeout < 30 )) && _health_timeout=30
        (( _health_timeout > 600 )) && _health_timeout=600
        log_info "Waiting for services to initialize (up to ${_health_timeout}s)..."
        if docker_wait_healthy vaultwarden_app "$_health_timeout" 5; then
            log_success "Service is healthy."
        else
            log_warn "Service did not reach healthy state within ${_health_timeout}s — check logs."
        fi

        local health_rc=0
        if [[ -x "${PROJECT_ROOT}/utilities/maintenance-health.sh" ]]; then
            log_info "Running post-restore health check..."
            log_info "Invoking: ${PROJECT_ROOT}/utilities/maintenance-health.sh"
            "${PROJECT_ROOT}/utilities/maintenance-health.sh" || health_rc=$?
        else
            log_error "Post-restore health verification could not run: utilities/maintenance-health.sh is not executable."
            health_rc=3
        fi
        _complete_restore_after_health "$health_rc"
        return $?
    fi
}

main "$@"
