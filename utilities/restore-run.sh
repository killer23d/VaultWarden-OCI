#!/usr/bin/env bash
# utilities/restore-run.sh — Restores VaultWarden data from local or remote encrypted backups.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

VW_LOCK_DIR="${PROJECT_ROOT}/.locks"
VW_OPERATIONS_LOCK="${VW_LOCK_DIR}/operations.lock"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/config.sh"
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"
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
unset -f _source_lib

# Require a real .env before any live restore so a fresh host never restores
# with placeholder values from .env.example. Help and list modes stay exempt.
_require_env_for_live_restore() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            help|list) return 0 ;;
        esac
    done

    local has_interactive=false has_inspect=false has_remote=false
    for arg in "$@"; do
        [[ "$arg" == "interactive" ]] && has_interactive=true
        [[ "$arg" == "inspect" ]] && has_inspect=true
        [[ "$arg" == "--remote"    ]] && has_remote=true
    done
    [[ "$has_interactive" == "true" && "$has_remote" == "true" ]] && return 0
    [[ "$has_inspect" == "true" && "$has_remote" == "true" ]] && return 0

    if [[ ! -f "${PROJECT_ROOT}/.env" ]]; then
        echo "" >&2
        echo "ERROR: .env not found." >&2
        echo "" >&2
        echo "  On a fresh server, copy the example file and fill in your values:" >&2
        echo "" >&2
        echo "    cp .env.example .env" >&2
        echo "    nano .env   # set DOMAIN, CLOUDFLARE_*, PUID, PGID, etc." >&2
        echo "" >&2
        echo "  For a bare-metal disaster-recovery restore (no .env yet)," >&2
        echo "  use the interactive subcommand with --remote so restore.sh can" >&2
        echo "  download and restore your .env from the encrypted remote backup:" >&2
        echo "" >&2
        echo "    sudo ./restore.sh interactive --remote" >&2
        echo "" >&2
        exit 1
    fi
}

check_dependencies() {
    local -a hard=(docker age age-keygen sqlite3 sha256sum tar)
    local -a soft=(sops zstd rclone rsync)
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
                sha256sum) echo "  Hint [sha256sum]: apt install coreutils  (should be pre-installed)" >&2 ;;
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
            esac
        done
    fi
}
case "${1:-}" in
    latest|list|interactive|inspect) check_dependencies ;;
esac

BACKUP_FILE=""
RESTORE_TYPE=""
USE_LATEST=false
LIST_ONLY=false
LIST_REMOTE=false
DRY_RUN=false
FORCE=false
NO_PRE_BACKUP=false
SKIP_VERIFICATION=false
RESTORE_ENV=true
RESTORE_SNAPSHOT_HARD_FAIL="${RESTORE_SNAPSHOT_HARD_FAIL:-true}"
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

    After the backup is selected you will be prompted for the age private
    key that was used to encrypt that backup.  Press Enter to use the key
    already configured in .env (SOPS_AGE_KEY_FILE).

    Once the restore lands, the restored SOPS secrets are rekeyed to a NEW
    age key, installed to configured locations, and displayed prominently.
    Save it before pressing Enter to start the services.

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
    --no-backup             Skip pre-restore emergency snapshot
    --skip-verification     Skip integrity check (not recommended)
    --skip-env              Do not restore archived .env over current .env
    --dry-run               Show what would happen without making changes
    --inspect               Non-destructive inspect mode (same as inspect subcommand)
    --force                 Skip confirmation prompts

GLOBAL SUBCOMMAND:
    help                    Show this help

GLOBAL OPTIONS:
    --version, -V           Print the VaultWarden-OCI version and exit

ENVIRONMENT:
    BACKUP_DIR=<path>                  Override backup storage root
                                       (default: $PROJECT_STATE_DIR/backups)
    RESTORE_SNAPSHOT_HARD_FAIL=false   Demote snapshot failure to a warning
    RESTORE_AGE_KEY_FILE=<path>        Non-interactive equivalent of --key-file
    RESTORE_RECOVERY_KIT_FILE=<path>   Non-interactive equivalent of --from-recovery-kit
    RCLONE_REMOTE_NAME                 Read from .env when available

EXAMPLES:
    # ── QUICK START (most common) ────────────────────────────────
    sudo ./restore.sh latest             # Restore newest backup (interactive confirm)
    sudo ./restore.sh latest db          # Restore newest DB backup
    sudo ./restore.sh latest --force     # Restore newest backup, no confirm prompts
    ./restore.sh list                    # List local backups (no sudo)
    ./restore.sh list --remote           # List remote backups (no sudo)

    # ── INTERACTIVE MENU ─────────────────────────────────────────
    sudo ./restore.sh interactive                    # Select from local backups
    sudo ./restore.sh interactive --remote           # Select from remote backups

    # ── TARGETED RESTORE ──────────────────────────────────────────
    sudo ./restore.sh interactive --file "/var/lib/vaultwarden/backups/full/full_20260101.tar.zst.age"
    sudo ./restore.sh interactive --key-file /tmp/old-age-key.txt  # Supply key non-interactively

    # ── BARE-METAL DISASTER RECOVERY ──────────────────────────────
    sudo ./restore.sh latest --from-recovery-kit /mnt/usb/recovery-kit.txt --force
EOF
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        help|--help|-h) show_help; exit 0 ;;
        --version|-V) print_project_version "VaultWarden-OCI" "${PROJECT_ROOT}"; exit 0 ;;
    esac
fi

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

_require_env_for_live_restore "${_ORIGINAL_ARGS[@]}"

# Parse remaining options (apply to interactive mode, 'latest', or 'list')
while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)                BACKUP_FILE="$2";        shift 2 ;;
        --remote)              USE_REMOTE=true;          shift ;;
        --key-file)            KEY_FILE_ARG="$2";        shift 2 ;;
        --from-recovery-kit)   RECOVERY_KIT_FILE="$2";   shift 2 ;;
        --no-backup)           NO_PRE_BACKUP=true;       shift ;;
        --skip-verification)   SKIP_VERIFICATION=true;   shift ;;
        --skip-env)            RESTORE_ENV=false;        shift ;;
        --dry-run)             DRY_RUN=true;             shift ;;
        --inspect)             INSPECT_ONLY=true;        shift ;;
        --force)               FORCE=true;               shift ;;
        *)                     log_error "Unknown option: '$1'"; show_help; exit 1 ;;
    esac
done

# Handle the list + --remote combination.
[[ "$LIST_ONLY" == "true" && "$USE_REMOTE" == "true" ]] && LIST_REMOTE=true

TMPDIR_RESTORE=""
cleanup() {
    if [[ -n "$TMPDIR_RESTORE" ]]; then rm -rf "$TMPDIR_RESTORE" 2>/dev/null; fi
}
trap cleanup EXIT HUP INT TERM ERR

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
    _rclone_is_available && show_remote=true

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
            (( global_index++ ))
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
    log_info "Downloading remote backup: $(basename "$remote_file") ..."
    local pull_dir="$TMPDIR_RESTORE/remote_pull"
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

    local pulled_size
    pulled_size=$(stat -c%s "$local_file" 2>/dev/null || stat -f%z "$local_file" 2>/dev/null || echo 0)
    log_info "Downloaded $(basename "$local_file") ($(( pulled_size / 1024 )) KiB)"

    BACKUP_FILE="$local_file"
    RESTORE_TYPE="$btype"
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
            (( i++ ))
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

#
# Reads a plaintext recovery-kit file, extracts the Age private key line
# (AGE-SECRET-KEY-1...), writes it to a chmod-600 temp file inside
# TMPDIR_RESTORE, and sets KEY_FILE_ARG so the existing _prompt_age_key()
# priority chain picks it up non-interactively.
#
# The recovery-kit file is the plaintext document produced at setup time
# containing (at minimum) one line beginning with AGE-SECRET-KEY-1.
# Any line format is accepted — the function greps for the key line so
# surrounding prose, labels, or blank lines are all ignored.
#
# Priority: --from-recovery-kit > RESTORE_RECOVERY_KIT_FILE env var.
# Must be called after TMPDIR_RESTORE is initialised (i.e. inside main()).
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

    # --- Write to a secure temp file inside TMPDIR_RESTORE ---------------
    local kit_stage_dir="$TMPDIR_RESTORE/kit_stage"
    local old_umask; old_umask=$(umask)
    umask 077
    mkdir -p "$kit_stage_dir"
    umask "$old_umask"
    chmod 700 "$kit_stage_dir"

    local staged_key="$kit_stage_dir/recovery-kit-age-key.txt"
    local tmp_staged
    tmp_staged=$(mktemp "${staged_key}.XXXXXX")
    chmod 600 "$tmp_staged"
    printf '%s\n' "$age_key_line" > "$tmp_staged"
    mv -f "$tmp_staged" "$staged_key"
    chmod 600 "$staged_key"

    # --- Validate via simple_verify_age_key() (roundtrip check) ----------
    if ! SOPS_AGE_KEY_FILE="$staged_key" simple_verify_age_key; then
        rm -f "$staged_key"
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
# The key is written to a chmod-600 temp file inside TMPDIR_RESTORE so
# that cleanup() always wipes it — the private key never persists on disk
# beyond the lifetime of this process.
#
# Sets global RESTORE_DECRYPT_AGE_KEY_FILE to the path of the resolved key file.
# Returns 0 on success, 1 on validation failure.
#
# Validation is delegated to simple_verify_age_key() from
# lib/crypto.sh, which performs permissions + ownership +
# crypto roundtrip checks and honours the full _resolve_age_key() chain.
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
        # simple_verify_age_key() accepts an explicit path argument;
        # passing SOPS_AGE_KEY_FILE overrides _resolve_age_key() internals
        # so it validates exactly the file we were given.
        if ! SOPS_AGE_KEY_FILE="$supplied_path" simple_verify_age_key; then
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
    log_info  "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info  "  Age Decryption Key Required"
    log_info  "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info  "  The selected backup was encrypted with an age private key."
    log_info  "  For normal same-server restore, press Enter to use the currently configured key."
    log_info  "  Only paste an AGE-SECRET-KEY-1... value if this backup was encrypted"
    log_info  "  with a different old/offline key."
    echo      ""
    log_info  "  Currently configured key:  $configured_key"
    echo      ""
    log_warn  "  IMPORTANT: Do NOT press Ctrl-C here — if the key is wrong"
    log_warn  "  decryption will fail AFTER backup selection, not silently."
    log_info  "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo      ""

    local key_input=""
    if [[ -t 0 ]]; then
        # Interactive terminal: suppress echo with a 300s timeout.
        if ! IFS= read -r -s -t 300 -p "  Age private key (hidden): " key_input; then
            echo "" >&2
            log_error "Timed out waiting for AGE key input (300s). Re-run restore.sh to retry."
            exit 1
        fi
        echo ""   # newline after silent input
    else
        IFS= read -r key_input || true
    fi

    # Priority 4: blank input → use configured key
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
        log_error "Tip: paste the full private key line from your saved age-key.txt."
        return 1
    fi

    # Write to a secure temp file inside the already-chmod-700 TMPDIR_RESTORE
    local key_staging_dir="$TMPDIR_RESTORE/key_stage"
    mkdir -p "$key_staging_dir"
    chmod 700 "$key_staging_dir"

    local staged_key_file="$key_staging_dir/restore-age-key.txt"

    printf '%s\n' "$key_input" > "$staged_key_file"
    chmod 600 "$staged_key_file"

    if ! SOPS_AGE_KEY_FILE="$staged_key_file" simple_verify_age_key; then
        rm -f "$staged_key_file"
        log_error "Age key validation failed — wrong key or corrupted input."
        log_error "Ensure you pasted the complete AGE-SECRET-KEY-1... line."
        return 1
    fi

    RESTORE_DECRYPT_AGE_KEY_FILE="$staged_key_file"
    log_success "Age key accepted and staged for decryption."
    return 0
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
    # 1. Generate new key to a temp file inside TMPDIR_RESTORE (secure)
    local new_key_tmp="$TMPDIR_RESTORE/new-age-key.txt"

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
    local staged_dir="$TMPDIR_RESTORE/age-rotation-staged"
    local backup_dir="$TMPDIR_RESTORE/age-rotation-backups"
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
    local kit_ts; kit_ts=$(date +%Y%m%d-%H%M%S)
    local kit_file="/root/vaultwarden-recovery-kit-${kit_ts}.txt"
    if {
        echo "# VaultWarden-OCI Recovery Kit"
        echo "# Generated: $(date -u)"
        echo "# Host:      $(hostname -f 2>/dev/null || hostname)"
        echo "# IMPORTANT: Store this file offline in a secure password manager or USB."
        echo "#            Required to decrypt future backups created after this date."
        echo "#            Delete this file from /root/ once safely copied offline."
        echo ""
        cat "$new_key_tmp"
    } > "$kit_file" 2>/dev/null; then
        chmod 600 "$kit_file" 2>/dev/null || true
        ROTATED_KIT_FILE="$kit_file"
        log_warn "  Recovery kit saved: $kit_file"
        log_warn "  ← COPY THIS FILE OFFLINE NOW, then delete it from /root/"
    else
        log_warn "  Could not write recovery kit to /root/ — save the key manually."
        ROTATED_KIT_FILE=""
    fi

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
    [[ "$DRY_RUN" == "true" ]] && return 0
    [[ -z "$ROTATED_KEY_FILE" ]] && return 0

    local priv_key_line
    # Suppress xtrace BEFORE reading the private key so that debug mode
    # does not leak the key material to the terminal or systemd journal.
    { set +x; } 2>/dev/null
    priv_key_line=$(grep -m1 '^AGE-SECRET-KEY-1' "$ROTATED_KEY_FILE" 2>/dev/null || true)

    echo ""
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║       ⚠️  SAVE YOUR NEW AGE ENCRYPTION KEY  ⚠️         ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo ""
    log_warn  "  A NEW age key was generated as part of this restore."
    log_warn  "  All future backups will be encrypted with this new key."
    log_warn  "  You MUST save this key before pressing Enter."
    log_warn  "  Loss of this key = permanent loss of future backups."
    echo ""
    log_info  "  Private key (keep secret; required for decryption):"
    echo      ""
    echo      "  ${priv_key_line:-<could not read key — check $ROTATED_KEY_FILE>}"
    unset priv_key_line
    echo      ""
    log_info  "  Public key (safe to share; used for encryption):"
    echo      ""
    echo      "  ${ROTATED_PUB_KEY:-<could not derive public key>}"
    echo      ""
    log_info  "  Installed locations:"
    log_info  "    Primary:    $ROTATED_KEY_FILE"
    [[ -f "/etc/vaultwarden/age-key.txt" ]] && \
        log_info  "    systemd:    /etc/vaultwarden/age-key.txt"
    log_info  "    .env:       SOPS_AGE_KEY_FILE updated"
    [[ -f "/etc/vaultwarden/vaultwarden.env" ]] && \
        log_info  "    systemd env: /etc/vaultwarden/vaultwarden.env updated"
    echo ""
    log_warn  "  Recommended: copy the private key to a secure password manager or"
    log_warn  "  offline storage NOW.  Services are about to start."
    echo ""

    if [[ "$FORCE" != "true" ]]; then
        if [[ -n "${ROTATED_KIT_FILE:-}" ]]; then
            log_warn "  Recovery kit written to: $ROTATED_KIT_FILE"
            log_warn "  Copy it offline NOW, then delete it: rm -f '$ROTATED_KIT_FILE'"
            echo ""
        fi
        local _confirm=""
        while [[ "$_confirm" != "SAVED" ]]; do
            read -r -p "  Type SAVED (all caps) to confirm the key is recorded and start services: " _confirm
            if [[ "$_confirm" != "SAVED" ]]; then
                log_warn "  Please type exactly: SAVED"
            fi
        done
    fi
    echo ""
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

_tar_filter_for_file() {
    case "$1" in
        *.tar.zst|*.zst) echo "-I zstd" ;;
        *.tar.gz|*.tgz)  echo "-z"      ;;
        *.tar.bz2|*.tbz) echo "-j"      ;;
        *.tar.xz)        echo "-J"      ;;
        *)               echo ""        ;;
    esac
}

_require_command_for_path() {
    local cmd="$1" reason="$2" package="${3:-$1}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "$cmd is required for ${reason} but is not installed."
        log_error "Install on Ubuntu 22.04/24.04 with: sudo apt-get install -y ${package}"
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

_restore_age_no_identity_guidance() {
    log_error "The current configured Age key cannot decrypt this selected backup."
    log_error "The selected backup may have been encrypted with an older operational key or offline recovery key."
    log_error "The current live key and backup decrypt key may be different."
    log_error "Retry with:"
    log_error "  sudo ./restore.sh interactive --remote --key-file /path/to/old-age-key.txt"
    log_error "or:"
    log_error "  sudo ./restore.sh latest --from-recovery-kit /path/to/recovery-kit.txt --force"
}

_decrypt_restore_archive_for_preflight() {
    local backup_file="$1" age_key_file="$2" tmpdir="$3"
    local inner_name="${backup_file%.age}"
    case "$inner_name" in
        *.tar.zst|*.tar.gz|*.tar.bz2|*.tar.xz|*.tgz|*.tbz) : ;;
        *) inner_name="${inner_name}.tar.gz" ;;
    esac
    local dec_tar="$tmpdir/$(basename "$inner_name")"
    [[ -s "$dec_tar" ]] && { printf '%s\n' "$dec_tar"; return 0; }
    log_info "Decrypting archive for non-destructive preflight inspection..." >&2
    local age_err="$tmpdir/age-decrypt.err"
    if ! age -d -i "$age_key_file" -o "$dec_tar" "$backup_file" 2>"$age_err"; then
        if grep -qi 'no identity matched any of the recipients' "$age_err" 2>/dev/null; then
            _restore_age_no_identity_guidance
        else
            log_error "Decryption failed — verify the age key is correct."
            log_hint "Use --key-file /path/to/the/old-age-key.txt for the key that encrypted this backup."
            log_hint "If you exported a recovery kit, retry with --from-recovery-kit /path/to/recovery-kit.txt."
        fi
        return 1
    fi
    printf '%s\n' "$dec_tar"
}

_restore_inspect_archive_layout() {
    local dec_tar="$1" target_state="$2" archive_format="$3"
    local filter; filter="$(_tar_filter_for_file "$dec_tar")"
    RESTORE_PREFLIGHT_MEMBERS="$(tar $filter -tf "$dec_tar")" || return 1
    RESTORE_PREFLIGHT_FIRST30="$(printf '%s\n' "$RESTORE_PREFLIGHT_MEMBERS" | head -30)"
    local normalized_members
    normalized_members="$(printf '%s\n' "$RESTORE_PREFLIGHT_MEMBERS" | sed 's#^\./##')"
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
    local d
    for d in $(_restore_required_dirs); do
        if [[ ! -e "$state_dir/$d" ]]; then
            mkdir -p "$state_dir/$d" || return 1
            log_info "Created missing block-storage directory: $state_dir/$d"
        elif [[ ! -d "$state_dir/$d" ]]; then
            log_error "Required target path exists but is not a directory: $state_dir/$d"; return 1
        fi
    done
    touch "$state_dir/.vw-data-volume" || return 1
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
        printf '  %s\n' $RESTORE_PREFLIGHT_FIRST30
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
        return 1
    fi
    return 0
}

create_pre_restore_snapshot() {
    local operational_sops_age_key_file="${1:-${OPERATIONAL_SOPS_AGE_KEY_FILE:-}}"
    [[ "$NO_PRE_BACKUP" == "true" ]] && { log_info "Skipping pre-restore snapshot (--no-backup)"; return 0; }
    [[ "$DRY_RUN"       == "true" ]] && { log_info "[DRY RUN] Would run: utilities/backup-run.sh run emergency"; return 0; }
    local state_dir; state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    local db_path="$state_dir/data/db.sqlite3"
    _preflight_operational_sops_key_for_snapshot "$operational_sops_age_key_file" || return 1
    # Best-effort WAL checkpoint; swallow all failures intentionally.
    # shellcheck disable=SC2015
    [[ -f "$db_path" ]] && command -v sqlite3 >/dev/null 2>&1 && \
        sqlite3 "$db_path" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
    if [[ -x "${PROJECT_ROOT}/utilities/backup-run.sh" ]]; then
        log_info "Creating pre-restore emergency snapshot..."
        log_info "Invoking with live SOPS key: ${PROJECT_ROOT}/utilities/backup-run.sh run emergency --quiet"
        if ! SOPS_AGE_KEY_FILE="$operational_sops_age_key_file" "${PROJECT_ROOT}/utilities/backup-run.sh" run emergency --quiet; then
            if [[ "${RESTORE_SNAPSHOT_HARD_FAIL}" == "true" ]]; then
                log_error "Pre-restore snapshot FAILED (hard-fail)."
                log_error "Use --no-backup or set RESTORE_SNAPSHOT_HARD_FAIL=false to skip."
                return 1
            fi
            log_warn "Pre-restore snapshot failed (continuing — RESTORE_SNAPSHOT_HARD_FAIL=false)"
        fi
    else
        local msg="backup-run.sh not executable — cannot create pre-restore snapshot"
        if [[ "${RESTORE_SNAPSHOT_HARD_FAIL}" == "true" ]]; then
            log_error "$msg"
            log_error "Use --no-backup or set RESTORE_SNAPSHOT_HARD_FAIL=false to skip."
            return 1
        fi
        log_warn "$msg (continuing — RESTORE_SNAPSHOT_HARD_FAIL=false)"
    fi
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

    log_info "Decrypting database backup..."
    local age_err="$tmpdir/db-age-decrypt.err"
    age -d -i "$age_key_file" -o "$dec_db" "$backup_file" 2>"$age_err" || {
        if grep -qi 'no identity matched any of the recipients' "$age_err" 2>/dev/null; then
            _restore_age_no_identity_guidance
        else
            log_error "Decryption failed — verify the age key is correct."
            log_hint "Use --key-file /path/to/the/old-age-key.txt for the key that encrypted this backup."
            log_hint "If you exported a recovery kit, retry with --from-recovery-kit /path/to/recovery-kit.txt."
        fi
        return 1
    }
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
        local age_err="$tmpdir/age-decrypt.err"
        if ! age -d -i "$age_key_file" -o "$dec_tar" "$backup_file" 2>"$age_err"; then
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
        log_warn "Legacy archive format detected (version=1, absolute paths)."
        # Always run traversal check regardless of SKIP_VERIFICATION.
        # Path traversal can lead to arbitrary file overwrite — this check must
        # never be skipped, even with --skip-verification.
        check_traversal_only "$dec_tar" || return 1
        log_success "Archive traversal check passed (legacy format)."
        [[ "$DRY_RUN" == "true" ]] && { log_info "[DRY RUN] Would tar -xf to /"; return 0; }
        # shellcheck disable=SC2086
        tar $tar_filter -xf "$dec_tar" -C / --no-same-owner --no-same-permissions --no-overwrite-dir --delay-directory-restore
        # shellcheck disable=SC2015  # best-effort chown; intentionally swallows failure
        [[ -d "$state_dir" ]] && chown -R "${puid}:${pgid}" "$state_dir/data" 2>/dev/null || true
        purge_wal_shm "$state_dir/data/db.sqlite3" || true
        log_success "Legacy archive restored."
        return 0
    fi

    [[ "$SKIP_VERIFICATION" != "true" ]] && { tar_validate_members "$dec_tar" || return 1; }
    [[ "$DRY_RUN" == "true" ]] && { log_info "[DRY RUN] Would stage-extract and atomic-mv archive."; return 0; }

    local staging="$tmpdir/stage"
    mkdir -p "$staging"
    log_info "Extracting archive to staging directory..."
    # shellcheck disable=SC2086
    tar $tar_filter -xf "$dec_tar" -C "$staging" --no-same-owner --no-same-permissions --no-overwrite-dir --delay-directory-restore

    local source_root="${RESTORE_PREFLIGHT_SOURCE_ROOT:-$state_dir}"
    local rel_source="${source_root#/}"
    if [[ ! -d "$staging/$rel_source" ]]; then
        log_error "Staging validation failed: expected source directory not found: $staging/$rel_source"
        # shellcheck disable=SC2086
        tar $tar_filter -tf "$dec_tar" | head -20 >&2 || true
        return 1
    fi

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
            local _rollback_path _rollback_name _created_path
            log_error "Attempting rollback of payload paths already moved into: $_snap_dir"
            for _created_path in "${_created_payload_paths[@]}"; do
                if [[ -e "$_created_path" ]]; then
                    if rm -rf -- "$_created_path"; then
                        log_warn "Rollback removed newly-created restore path: $_created_path"
                    else
                        log_error "Rollback failed to remove newly-created restore path: $_created_path"
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
                    fi
                fi
            done
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
                    _rollback_payload_paths
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
                _rollback_payload_paths
                return 1
            fi
            log_info "  Promoted: $_payload_name/"
        done
        log_warn "Archive backups/, secrets/, and config/ under $state_dir were intentionally not promoted."
        unset -f _rollback_payload_paths
    else
        if [[ "$source_root" == "$state_dir" ]]; then
            # Boot-only same-layout mode: atomic directory swap (fast path).
            [[ -d "$state_dir" ]] && mv "$state_dir" "${state_dir}.pre-restore-${ts}"

            log_info "State payload restore phase: promoting staged state directory to live path..."
            mv "$staging/$rel_source" "$state_dir"
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
        touch "${_sentinel_dir}/.vw-data-volume" 2>/dev/null || \
            log_warn "Could not re-touch volume sentinel at ${_sentinel_dir}/.vw-data-volume"
    fi
    unset _sentinel_dir

    chown -R "${puid}:${pgid}" "$state_dir/data" 2>/dev/null || log_warn "Could not set ownership on $state_dir/data"
    purge_wal_shm "$state_dir/data/db.sqlite3" || true

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

    log_success "Full restore completed (staged, atomic)."
}

main() {
    log_header "VaultWarden-OCI Restore Utility"

    # Load .env unconditionally and early so every code path — including
    # list subcommand and the rclone availability checks — can read config values
    # such as RCLONE_REMOTE_NAME and RCLONE_CONFIG.
    load_env_file 2>/dev/null || true   # best-effort; hard error below if root required

    # Resolve the backup storage root from .env using the same
    # key ("BACKUP_DIR") and default that backup.sh uses.  Every search path
    # in this script is built from BACKUP_BASE_DIR, never from PROJECT_ROOT/backups.
    local _early_state_dir; _early_state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    BACKUP_BASE_DIR="$(get_config_value "BACKUP_DIR" "${_early_state_dir}/backups")"
    log_info "Backup storage root: $BACKUP_BASE_DIR"

    if [[ "$LIST_ONLY" == "true" ]]; then
        if [[ "$LIST_REMOTE" == "true" ]]; then
            # Remote listing: if RCLONE_REMOTE_NAME is missing, prompt for it
            # to support emergency listing without .env.
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
    auto_fix_critical_permissions "$PROJECT_ROOT"

    ensure_dir "$VW_LOCK_DIR" 700 "$(get_real_user)" || {
        log_error "Failed to initialize operations lock directory: $VW_LOCK_DIR"; exit 1
    }

    # Use bash 4.1+ automatic FD allocation instead of hardcoded
    # FD for the operations lock, preventing silent clobber of any open FD.
    local OPS_LOCK_FD
    exec {OPS_LOCK_FD}>"$VW_OPERATIONS_LOCK"
    flock -n "$OPS_LOCK_FD" || {
        log_error "Another update/restore/maintenance/backup operation is already running."
        log_error "Lock file: $VW_OPERATIONS_LOCK"
        exit 1
    }

    local RESTORE_LOCK_FILE="/run/lock/vaultwarden-restore.lock"
    _ensure_lock_file "$RESTORE_LOCK_FILE" || exit 1
    local RESTORE_LOCK_FD
    exec {RESTORE_LOCK_FD}>"$RESTORE_LOCK_FILE"
    flock -n "$RESTORE_LOCK_FD" || {
        log_error "Another restore is already running."
        log_error "Lock file: ${RESTORE_LOCK_FILE}"
        log_error "If you are certain no restore is active, remove it and retry:"
        log_error "  sudo rm -f ${RESTORE_LOCK_FILE}"
        exit 1
    }

    # Re-load .env strictly now that we are root (surfaces hard errors).
    # When USE_REMOTE=true and .env is absent (emergency restore on a fresh
    # server), treat the load failure as a warning rather than a hard exit —
    # the operator is about to restore .env from the backup.
    if ! load_env_file; then
        if [[ "$USE_REMOTE" == "true" ]] && [[ ! -f "${PROJECT_ROOT}/.env" ]]; then
            log_warn ".env not found — operating in bootstrap/emergency-restore mode."
            log_warn "PUID, PGID, and age key will be prompted if not set."
        else
            log_error "Failed to load .env"; exit 1
        fi
    fi
    auto_fix_critical_permissions "$PROJECT_ROOT"

    # Fail closed if a block/data volume is configured.  --force --remote may
    # skip this check only for boot-volume/bootstrap mode where no block device
    # is configured; it must never permit writes to an unmounted block-volume path.
    local _configured_data_device
    _configured_data_device="$(get_config_value "DATA_VOLUME_DEVICE" "")"
    if [[ "$INSPECT_ONLY" == "true" ]]; then
        log_warn "Inspect mode: skipping live project-state readiness enforcement; storage readiness will be reported by restore preflight."
    elif [[ "$FORCE" == "true" && "$USE_REMOTE" == "true" && -z "$_configured_data_device" ]]; then
        log_warn "Skipping project-state-ready check (--force --remote boot-volume/bootstrap mode)."
        log_warn "No DATA_VOLUME_DEVICE is configured; block-volume safety checks remain required when a data volume is configured."
    else
        require_project_state_ready || exit 1
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

    # Create the secure temp dir early so remote pull and key staging can use it.
    local old_umask; old_umask=$(umask)
    umask 077
    # Prefer /dev/shm (RAM-backed tmpfs) so decrypted material never touches disk.
    # Fall back to a mktemp in /tmp (or the OS default) when /dev/shm is absent or
    # not writable — this is the same pattern used by backup.sh.
    TMPDIR_RESTORE="$(mktemp -d -p /dev/shm vw_restore.XXXXXXXXXX 2>/dev/null || mktemp -d -t vw_restore.XXXXXXXXXX)" || {
        log_error "Failed to create secure temporary directory"; exit 1
    }
    umask "$old_umask"
    if [[ "$TMPDIR_RESTORE" != /dev/shm/* ]]; then
        log_warn "TMPDIR_RESTORE: /dev/shm unavailable — restore temp dir is disk-backed: $TMPDIR_RESTORE"
        log_warn "  Decrypted material will be on disk. Ensure full-disk encryption is active."
    fi

    # Load Age key from recovery kit if supplied (must be after TMPDIR_RESTORE is set).
    _load_recovery_kit || exit 1

    resolve_backup_file || exit 1
    [[ -f "$BACKUP_FILE" ]] || { log_error "Backup file not found: $BACKUP_FILE"; exit 1; }

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

    _prompt_age_key "$OPERATIONAL_SOPS_AGE_KEY_FILE" || exit 1
    
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

    log_info "Restore plan:"
    log_info "  File:        $BACKUP_FILE"
    log_info "  Type:        $RESTORE_TYPE"
    log_info "  Archive ver: $archive_version (format: $archive_format)"
    log_info "  State dir:   $STATE_DIR"
    log_info "  Decrypt key: $RESTORE_DECRYPT_AGE_KEY_FILE"

    _require_selected_archive_tools "$BACKUP_FILE" || exit 1
    if [[ "$RESTORE_TYPE" =~ ^(full|emergency)$ ]] && [[ -n "$(get_config_value "DATA_VOLUME_DEVICE" "")" ]]; then
        _require_command_for_path rsync "block-volume full/emergency restores" rsync || exit 1
    fi

    if [[ "$RESTORE_TYPE" =~ ^(full|emergency)$ ]]; then
        log_warn "Full/emergency restore replaces application state/config and may require the same expected storage class."
        local _preflight_tar
        _preflight_tar="$(_decrypt_restore_archive_for_preflight "$BACKUP_FILE" "$RESTORE_DECRYPT_AGE_KEY_FILE" "$TMPDIR_RESTORE")" || exit 1
        restore_full_preflight "$BACKUP_FILE" "$_preflight_tar" "$STATE_DIR" "$PUID" "$PGID" "$archive_format" "$archive_version" || exit 1
        if [[ "$INSPECT_ONLY" == "true" ]]; then
            log_success "Inspect mode complete — no services stopped, no files restored, no key rotation, no health check."
            exit 0
        fi
    elif [[ "$RESTORE_TYPE" == "db" ]]; then
        log_info "DB restore is storage-layout independent and is the safest path when only Vaultwarden data is needed."
        if [[ "$INSPECT_ONLY" == "true" ]]; then
            local _inspect_db="$TMPDIR_RESTORE/db-inspect.sqlite3" _db_err="$TMPDIR_RESTORE/db-age.err"
            if age -d -i "$RESTORE_DECRYPT_AGE_KEY_FILE" -o "$_inspect_db" "$BACKUP_FILE" 2>"$_db_err"; then
                if sqlite3 "$_inspect_db" 'PRAGMA integrity_check;' 2>/dev/null | grep -qx ok; then
                    log_success "Inspect mode: DB backup integrity check passed."
                else
                    log_warn "Inspect mode: DB backup decrypted, but sqlite integrity check did not return ok."
                fi
            elif grep -qi 'no identity matched any of the recipients' "$_db_err" 2>/dev/null; then
                _restore_age_no_identity_guidance; exit 1
            else
                log_error "Inspect mode: DB backup decryption failed."; exit 1
            fi
            log_success "Inspect mode complete — no services stopped, no files restored, no key rotation, no health check."
            exit 0
        fi
    fi

    if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" ]]; then
        echo ""
        log_warn "WARNING: This will overwrite current data."
        log_warn "Services will be stopped during the restore."
        log_warn "A NEW age key will be generated after the restore."
        echo ""
        read -r -p "Type 'yes' to proceed: " confirm
        [[ "$confirm" == "yes" ]] || { log_info "Restore cancelled."; exit 0; }
    fi

    if [[ "$RESTORE_TYPE" =~ ^(full|emergency)$ ]] && [[ "$DRY_RUN" != "true" ]]; then
        local _target_mode_for_prepare
        _target_mode_for_prepare="$(_detect_storage_mode "$STATE_DIR" "$(get_config_value "DATA_VOLUME_MOUNT" "")" "$(get_config_value "DATA_VOLUME_DEVICE" "")")"
        if [[ "$_target_mode_for_prepare" == "block" ]]; then
            log_info "Target preparation phase: verifying and repairing mounted block-storage directories..."
            _restore_prepare_block_target "$STATE_DIR" "$PUID" "$PGID" "$_preflight_tar" || exit 1
        fi
    fi

    create_pre_restore_snapshot "$OPERATIONAL_SOPS_AGE_KEY_FILE" || exit 1

    RESTORE_DESTRUCTIVE_PHASE_STARTED=false
    _RESTORE_SAFETY_NET_RUNNING=false
    _RESTORE_CLEANUP_DONE=false
    _restore_cleanup_once() {
        [[ "$_RESTORE_CLEANUP_DONE" == "true" ]] && return 0
        _RESTORE_CLEANUP_DONE=true
        cleanup
    }
    _restore_safety_net() {
        local rc=$?
        trap - ERR HUP INT TERM
        if [[ "${_RESTORE_SAFETY_NET_RUNNING:-false}" == "true" ]]; then
            exit "$rc"
        fi
        _RESTORE_SAFETY_NET_RUNNING=true
        [[ $rc -eq 130 ]] && log_warn "Restore interrupted by operator (Ctrl-C)."
        if [[ $rc -ne 0 ]]; then
            if [[ "${RESTORE_DESTRUCTIVE_PHASE_STARTED:-false}" == "true" ]]; then
                log_warn "Restore encountered an error (exit $rc) after destructive phase — attempting one service restart..."
                bash "${PROJECT_ROOT}/startup.sh" --skip-pull 2>/dev/null || \
                    log_error "CRITICAL: Failed to restart services after restore error. Manual intervention required: sudo ./startup.sh --skip-pull"
            else
                log_warn "Restore failed before destructive phase (exit $rc); services were not stopped and startup.sh will not be run."
            fi
        fi
        _restore_cleanup_once
        exit "$rc"
    }

    trap _restore_safety_net ERR HUP INT TERM
    if [[ "$DRY_RUN" != "true" ]]; then
        docker compose stop
        RESTORE_DESTRUCTIVE_PHASE_STARTED=true
    fi

    case "$RESTORE_TYPE" in
        db)
            restore_db "$BACKUP_FILE" "$RESTORE_DECRYPT_AGE_KEY_FILE" "$STATE_DIR" "$PUID" "$PGID" "$TMPDIR_RESTORE"
            ;;
        full|emergency)
            RESTORE_DESTRUCTIVE_PHASE_STARTED=true
            restore_full "$BACKUP_FILE" "$RESTORE_DECRYPT_AGE_KEY_FILE" "$STATE_DIR" "$PUID" "$PGID" "$TMPDIR_RESTORE" "$archive_format"
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
    # use the live operational key. Separate-volume full/emergency restores
    # intentionally do not promote secrets/, so the live operational key remains
    # the correct rekey source. Boot-only full/emergency restores replace the
    # whole state dir, so secrets.yaml may come from the selected archive and
    # may require the selected backup decrypt key.
    case "$RESTORE_TYPE" in
        db)
            RESTORE_REKEY_SOURCE_AGE_KEY_FILE="$OPERATIONAL_SOPS_AGE_KEY_FILE"
            ;;
        full|emergency)
            if mountpoint -q "$STATE_DIR" 2>/dev/null; then
                # Separate-volume mode: secrets/ is intentionally not promoted.
                # The live secrets.yaml remains encrypted with the operational key.
                RESTORE_REKEY_SOURCE_AGE_KEY_FILE="$OPERATIONAL_SOPS_AGE_KEY_FILE"
            else
                # Boot-only mode replaces the whole state dir, including secrets/.
                # The restored secrets.yaml may require the selected backup decrypt key.
                RESTORE_REKEY_SOURCE_AGE_KEY_FILE="$RESTORE_DECRYPT_AGE_KEY_FILE"
            fi
            ;;
        *) log_error "Unknown restore type for rekey source: $RESTORE_TYPE"; exit 1 ;;
    esac

    if ! _rotate_age_key; then
        log_error "Age key rotation FAILED."
        log_error "The data restore itself succeeded, but key rotation/rekey did not complete safely."
        log_error "Live key artifacts were rolled back where needed; refusing to start services automatically."
        exit 1
    fi

    _display_new_key

    if [[ "$DRY_RUN" != "true" ]]; then
        auto_fix_critical_permissions "$PROJECT_ROOT"
        log_info "Starting services..."
        if ! bash "${PROJECT_ROOT}/startup.sh" --skip-pull; then
            log_error "Failed to start services after restore."
            log_error "Investigate with: docker compose logs --tail=50"
            exit 1
        fi
        # Services are now running — clear the safety-net ERR trap so that
        # errors in the post-startup health check do not trigger a restart.
        trap - ERR

        log_info "Waiting for services to initialize (up to 60s)..."
        if docker_wait_healthy vaultwarden_app 60 5; then
            log_success "Service is healthy."
        else
            log_warn "Service did not reach healthy state within 60s — check logs."
        fi

        if [[ -x "${PROJECT_ROOT}/utilities/maintenance-health.sh" ]]; then
            log_info "Running post-restore health check..."
            log_info "Invoking: ${PROJECT_ROOT}/utilities/maintenance-health.sh"
            "${PROJECT_ROOT}/utilities/maintenance-health.sh" || {
                log_warn "Health check reported issues after restore."
                log_warn "Investigate with: docker compose logs --tail=50"
            }
        fi
    fi

    echo ""
    log_success "Restore complete."
    if [[ -n "$ROTATED_KEY_FILE" && "$DRY_RUN" != "true" ]]; then
        log_info  "New age key is live at: $ROTATED_KEY_FILE"
        log_info  "Run: sudo ./setup.sh systemd install  (to sync /etc/vaultwarden/)"
    fi
}

main "$@"
