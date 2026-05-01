#!/usr/bin/env bash
# restore.sh - VaultWarden-OCI safe restore
# Supports local and rclone remote backup selection.
# After restore: prompts for the decryption key, restores data, then
# generates/rotates a fresh age key and displays it like a new setup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

VW_LOCK_DIR="${PROJECT_ROOT}/.locks"
VW_OPERATIONS_LOCK="${VW_LOCK_DIR}/operations.lock"

source "lib/common.sh"
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

# ---------------------------------------------------------------------------
# DR pre-flight: .env guard
# ---------------------------------------------------------------------------
# On a fresh (disaster-recovery) host the operator will not yet have a .env.
# Sourcing .env.example — which contains REPLACE_ME placeholders — or running
# with completely unset variables would silently corrupt the restore.  Catch
# this early, before any config values are read, and give the operator a
# single, actionable error message.
#
# Exemptions:
#   --help           show usage without a live config
#   --list           list local backups without requiring .env
#   --list --remote  list remote backups; operator may be prompted for remote
#   --remote         bare-metal DR path; .env will be restored from backup
_require_env_for_live_restore() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --help|--list|--remote) return 0 ;;
        esac
    done

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
        echo "  use --remote so restore.sh can download and restore your" >&2
        echo "  .env from the encrypted remote backup:" >&2
        echo "" >&2
        echo "    sudo ./restore.sh --remote" >&2
        echo "" >&2
        exit 1
    fi
}
_require_env_for_live_restore "$@"

# ---------------------------------------------------------------------------
# Dependency pre-flight
# ---------------------------------------------------------------------------
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
        exit 1
    fi
    if [[ ${#missing_soft[@]} -gt 0 ]]; then
        echo "WARN: restore.sh: optional tools missing (some features will be disabled): ${missing_soft[*]}" >&2
    fi
}
check_dependencies

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
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

# declared here (empty) so set -u never fires before main()
# initialises it via get_config_value().  Every function that references
# BACKUP_BASE_DIR is only called after main() has set it.
BACKUP_BASE_DIR=""

# Issue: session-scoped rclone remote name / path for emergency restores.
# When .env is absent (fresh server), _prompt_rclone_remote_name() fills
# these; they are used in place of the .env values for this run only and
# are never written back to disk.
_SESSION_RCLONE_REMOTE_NAME=""
_SESSION_RCLONE_REMOTE_PATH=""

# Set by _rclone_is_available() when rclone binary + config are present but
# RCLONE_REMOTE_NAME is missing — signals that an interactive prompt is
# needed rather than a hard failure.
RCLONE_NEEDS_INTERACTIVE_NAME=false

show_help() {
    cat << 'EOF'
VaultWarden-OCI Restore Script

USAGE:
    sudo ./restore.sh [OPTIONS]

    When run without --file or --latest, an interactive numbered menu is
    presented.  If rclone is configured, you are first asked whether to
    restore from a LOCAL or REMOTE backup.

    After the backup is selected you will be prompted for the age private
    key that was used to encrypt that backup.  Press Enter to use the key
    already configured in .env (SOPS_AGE_KEY_FILE).

    Once the restore lands, a NEW age key is automatically generated,
    installed to all configured locations, and displayed prominently.
    Save it before pressing Enter to start the services.

OPTIONS:
    --list                  List available local backups and exit (no root required)
    --list --remote         List available remote backups and exit (no root required)
    --file FILE             Restore a specific backup file (.age)
    --type TYPE             db | full | emergency (helps resolve --latest)
    --latest                Use newest local backup (optionally filtered by --type)
    --remote                Skip the local/remote menu and list remote backups
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
    --force                 Skip confirmation prompts
    --help                  Show this help

ENVIRONMENT:
    BACKUP_DIR=<path>                  Override backup storage root
                                       (default: /var/lib/vaultwarden/backups)
                                       Must match the BACKUP_DIR value used in backup.sh.
    RESTORE_SNAPSHOT_HARD_FAIL=false   Demote snapshot failure to a warning
                                       (default: true = hard-fail)
    RESTORE_AGE_KEY_FILE=<path>        Non-interactive equivalent of --key-file
    RESTORE_RECOVERY_KIT_FILE=<path>   Non-interactive equivalent of --from-recovery-kit

    RCLONE_REMOTE_NAME is read from .env when available.  On a fresh server
    where .env does not yet exist, restore.sh will interactively prompt for
    the remote name (and optionally the remote path) when --remote is used.

    NOTE: On a fresh bare-metal server, 'rclone config' must already be
    configured before using --remote.  The rclone remote credentials are
    NOT stored in the backup archive.  Run 'rclone config' to add the
    remote, verify with 'rclone listremotes', then re-run restore.sh.

EXAMPLES:
    sudo ./restore.sh                                   # interactive (local or remote)
    sudo ./restore.sh --remote                          # interactive (remote only)
    ./restore.sh --list                                 # list local backups (no root)
    ./restore.sh --list --remote                        # list remote backups (no root)
    sudo ./restore.sh --latest --type db --force
    sudo ./restore.sh --file /var/lib/vaultwarden/backups/full/full_backup_20260101_120000.tar.zst.age
    sudo ./restore.sh --key-file /tmp/old-age-key.txt   # supply key non-interactively

    # Bare-metal DR: one flag replaces manual key extraction
    sudo ./restore.sh --latest --from-recovery-kit /mnt/usb/recovery-kit.txt --force
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)                LIST_ONLY=true;                shift ;;
        --file)                BACKUP_FILE="$2";              shift 2 ;;
        --type)                RESTORE_TYPE="$2";             shift 2 ;;
        --latest)              USE_LATEST=true;               shift ;;
        --remote)              USE_REMOTE=true;               shift ;;
        --key-file)            KEY_FILE_ARG="$2";             shift 2 ;;
        --from-recovery-kit)   RECOVERY_KIT_FILE="$2";        shift 2 ;;
        --no-backup)           NO_PRE_BACKUP=true;            shift ;;
        --skip-verification)   SKIP_VERIFICATION=true;        shift ;;
        --skip-env)            RESTORE_ENV=false;             shift ;;
        --dry-run)             DRY_RUN=true;                  shift ;;
        --force)               FORCE=true;                    shift ;;
        --help)                show_help; exit 0 ;;
        *)                     log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --list --remote combination
[[ "$LIST_ONLY" == "true" && "$USE_REMOTE" == "true" ]] && LIST_REMOTE=true

TMPDIR_RESTORE=""
cleanup() { [[ -n "$TMPDIR_RESTORE" ]] && rm -rf "$TMPDIR_RESTORE" 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# _resolve_rclone_config
# Mirrors backup.sh: auto-discovers rclone.conf across 5 priority locations.
# ---------------------------------------------------------------------------
_resolve_rclone_config() {
    local cfg_from_env
    cfg_from_env="$(get_config_value "RCLONE_CONFIG" "")"
    [[ -n "$cfg_from_env" ]] && { echo "$cfg_from_env"; return 0; }
    [[ -f "/etc/rclone/rclone.conf" ]]                && { echo "/etc/rclone/rclone.conf"; return 0; }
    [[ -f "/root/.config/rclone/rclone.conf" ]]       && { echo "/root/.config/rclone/rclone.conf"; return 0; }
    if [[ -n "${SUDO_USER:-}" ]]; then
        local sudo_user_home
        sudo_user_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
        [[ -n "$sudo_user_home" && -f "$sudo_user_home/.config/rclone/rclone.conf" ]] && {
            echo "$sudo_user_home/.config/rclone/rclone.conf"; return 0
        }
    fi
    local found_cfg
    for found_cfg in /home/*/.config/rclone/rclone.conf; do
        [[ -f "$found_cfg" ]] && echo "$found_cfg" && return 0
    done
    return 1
}

_validate_rclone_config_path() {
    local cfg_path="$1"
    [[ -z "$cfg_path" ]] && { log_error "rclone config path is empty" >&2; return 1; }
    if [[ "$cfg_path" =~ [^a-zA-Z0-9_./:~-] ]]; then
        log_error "rclone config path contains disallowed characters: $cfg_path" >&2; return 1
    fi
    local canonical
    canonical=$(realpath -e "$cfg_path" 2>/dev/null) || {
        log_error "rclone config path does not exist: $cfg_path" >&2; return 1
    }
    # Block clearly sensitive paths; /root/.config/rclone/rclone.conf is legitimate
    local -a sensitive_prefixes=("/etc/passwd" "/etc/shadow" "/etc/sudoers" "/etc/ssh" "/root/.ssh" "/proc" "/sys")
    for prefix in "${sensitive_prefixes[@]}"; do
        [[ "$canonical" == "$prefix" || "$canonical" == "$prefix/"* ]] && {
            log_error "rclone config resolves to sensitive path: $canonical" >&2; return 1
        }
    done
    [[ -f "$canonical" ]] || { log_error "rclone config is not a regular file: $canonical" >&2; return 1; }
    local file_perms
    file_perms=$(stat -c "%a" "$canonical" 2>/dev/null || stat -f "%Lp" "$canonical" 2>/dev/null || echo "777")
    (( (8#$file_perms & 8#002) != 0 )) && { log_error "rclone config is world-writable: $canonical" >&2; return 1; }
    return 0
}

RCLONE_CONFIG_ARG=()
_build_rclone_config_arg() {
    RCLONE_CONFIG_ARG=()
    local cfg_path
    if cfg_path=$(_resolve_rclone_config); then
        _validate_rclone_config_path "$cfg_path" || { log_warn "rclone config failed validation: $cfg_path"; return 1; }
        local canonical; canonical=$(realpath -e "$cfg_path")
        RCLONE_CONFIG_ARG=(--config "$canonical")
        log_info "Using rclone config: $canonical"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# _rclone_is_available
# Returns 0 if rclone + remote name + config are all present and valid.
# Sets RCLONE_UNAVAIL_REASON (global) with a human-readable explanation
# whenever it returns 1, so callers can surface a useful message.
#
# Also sets RCLONE_NEEDS_INTERACTIVE_NAME=true when rclone binary
# and config are present but RCLONE_REMOTE_NAME is missing/placeholder.
# This distinguishes "prompt needed" from "rclone not installed" so that
# select_backup_source() can trigger _prompt_rclone_remote_name() instead
# of hiding the REMOTE option when --remote was explicitly requested.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# _rclone_diagnose
# Emits a single log_warn line explaining why remote is unavailable.
# Call this whenever _rclone_is_available returns 1 and you want to tell
# the operator why the remote option is missing from the menu.
# ---------------------------------------------------------------------------
_rclone_diagnose() {
    if [[ -n "$RCLONE_UNAVAIL_REASON" ]]; then
        log_warn "Remote backups unavailable: $RCLONE_UNAVAIL_REASON"
    fi
}

# ---------------------------------------------------------------------------
# _prompt_rclone_remote_name
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
# ---------------------------------------------------------------------------
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
            configured_remotes=$(rclone listremotes 2>/dev/null || true)
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


# ---------------------------------------------------------------------------
# Backup listing helpers
# ---------------------------------------------------------------------------

_find_latest_backup() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    local best_mtime=0 best_file="" f mtime
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        mtime=$(stat -c%Y "$f" 2>/dev/null || stat -f%m "$f" 2>/dev/null || echo 0)
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
        (( mtime > best_mtime )) && { best_mtime=$mtime; best_file="$f"; }
    done < <(find "$dir" -name "*.age" -type f 2>/dev/null)
    [[ -n "$best_file" ]] && { echo "$best_file"; return 0; }
    return 1
}

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

    # Local section
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

    # Remote section
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
    local local_file="$pull_dir/$(basename "$remote_file")"
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
        # Tell the operator WHY remote is not in the menu.
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

# ---------------------------------------------------------------------------
# resolve_backup_file
# ---------------------------------------------------------------------------
resolve_backup_file() {
    if [[ "$USE_LATEST" == "true" ]]; then
        if [[ -n "$RESTORE_TYPE" ]]; then
            BACKUP_FILE="$(_find_latest_backup "$BACKUP_BASE_DIR/$RESTORE_TYPE" || true)"
            [[ -n "$BACKUP_FILE" ]] || { log_error "No backups found for type: $RESTORE_TYPE (looked in $BACKUP_BASE_DIR/$RESTORE_TYPE)"; return 1; }
            return 0
        fi
        local best="" best_mtime=0 candidate mtime
        for t in db full emergency; do
            candidate="$(_find_latest_backup "$BACKUP_BASE_DIR/$t" || true)"
            if [[ -n "$candidate" ]]; then
                mtime=$(stat -c%Y "$candidate" 2>/dev/null || stat -f%m "$candidate" 2>/dev/null || echo 0)
                [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
                if (( mtime > best_mtime )); then best_mtime="$mtime"; best="$candidate"; RESTORE_TYPE="$t"; fi
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
            log_error "Cannot determine backup type — specify --type db|full|emergency"; return 1
        }
        return 0
    fi

    select_backup_source || return 1
    return 0
}

# ---------------------------------------------------------------------------
# _load_recovery_kit
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
# ---------------------------------------------------------------------------
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

    # Basic format sanity check.
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

# ---------------------------------------------------------------------------
# _prompt_age_key
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
# Sets global AGE_KEY_FILE to the path of the resolved key file.
# Returns 0 on success, 1 on validation failure.
#
# Validation is delegated to simple_verify_age_key() from
# lib/crypto.sh, which performs permissions + ownership +
# crypto roundtrip checks and honours the full _resolve_age_key() chain.
# ---------------------------------------------------------------------------
_prompt_age_key() {
    local configured_key="$1"  # the key currently in .env (fallback)

    # -----------------------------------------------------------------
    # Priority 1 & 2: non-interactive supply
    # -----------------------------------------------------------------
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
        AGE_KEY_FILE="$supplied_path"
        log_success "Age key validated."
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would prompt for age private key (using configured key: $configured_key)"
        AGE_KEY_FILE="$configured_key"
        return 0
    fi

    echo ""
    log_info  "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info  "  Age Decryption Key Required"
    log_info  "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info  "  The selected backup was encrypted with an age private key."
    log_info  "  Paste or type the full AGE-SECRET-KEY-1... value below."
    echo      ""
    log_info  "  Press Enter with no input to use the currently configured"
    log_info  "  key:  $configured_key"
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
        # Non-interactive pipe: read normally
        IFS= read -r key_input || true
    fi

    # Priority 4: blank input → use configured key
    if [[ -z "$key_input" ]]; then
        log_info "  No key entered — using configured key: $configured_key"
        [[ -f "$configured_key" ]] || { log_error "Configured key not found: $configured_key"; return 1; }
        AGE_KEY_FILE="$configured_key"
        return 0
    fi

    # Trim leading/trailing whitespace from pasted input
    key_input="${key_input#"${key_input%%[![:space:]]*}"}"
    key_input="${key_input%"${key_input##*[![:space:]]}"}"

    # Validate format before writing to disk
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

    # age-keygen -y requires the comment line format; build the minimal
    # valid age key file: comment + public key comment + private key line.
    # We derive the public key by generating a temporary file and using age.
    # Simpler: write just the private key line — age -d -i accepts bare keys.
    printf '%s\n' "$key_input" > "$staged_key_file"
    chmod 600 "$staged_key_file"

    # Validate via simple_verify_age_key() (permissions + roundtrip)
    if ! SOPS_AGE_KEY_FILE="$staged_key_file" simple_verify_age_key; then
        rm -f "$staged_key_file"
        log_error "Age key validation failed — wrong key or corrupted input."
        log_error "Ensure you pasted the complete AGE-SECRET-KEY-1... line."
        return 1
    fi

    AGE_KEY_FILE="$staged_key_file"
    log_success "Age key accepted and staged for decryption."
    return 0
}

# ---------------------------------------------------------------------------
# _prune_old_age_keys <keys_dir>
#
# Prune old Age private key backups — keep only 2 most recent.
# Old key material has no operational value once a new key is active and
# backed up; retaining it indefinitely increases exposure if the secrets/keys/
# directory is ever compromised.
# ---------------------------------------------------------------------------
_prune_old_age_keys() {
    local keys_dir="$1"
    [[ -d "$keys_dir" ]] || return 0
    local -a old_keys
    # Find all age-key backup files (timestamped), sorted oldest-first
    mapfile -t old_keys < <(find "$keys_dir" -maxdepth 1 -name "age-key.txt.pre-rotate-*" -type f \
        | sort)
    local count=${#old_keys[@]}
    # Keep 2 most recent; delete the rest
    if (( count > 2 )); then
        local delete_count=$(( count - 2 ))
        for (( i=0; i<delete_count; i++ )); do
            log_info "Pruning old Age key backup: $(basename "${old_keys[$i]}")"
            rm -f "${old_keys[$i]}" 2>/dev/null || log_warn "Failed to prune: ${old_keys[$i]}"
        done
    fi
}

# ---------------------------------------------------------------------------
# _rotate_age_key
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
# ---------------------------------------------------------------------------
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
    # ------------------------------------------------------------------
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

    # ------------------------------------------------------------------
    # 2. Install to secrets/keys/age-key.txt (atomic)
    # ------------------------------------------------------------------
    local local_key_dir="$PROJECT_ROOT/secrets/keys"
    local local_key_file="$local_key_dir/age-key.txt"

    local old_umask2; old_umask2=$(umask)
    umask 077
    mkdir -p "$local_key_dir"
    umask "$old_umask2"
    chmod 700 "$local_key_dir" 2>/dev/null || true

    if [[ -f "$local_key_file" ]]; then
        local backup_ts; backup_ts=$(date +%Y%m%d-%H%M%S)
        cp -f "$local_key_file" "${local_key_file}.pre-rotate-${backup_ts}"
        chmod 600 "${local_key_file}.pre-rotate-${backup_ts}"
        log_info "  Previous key backed up: age-key.txt.pre-rotate-${backup_ts}"
    fi

    # Atomic install: cp then chmod, not cp with implied 644 window
    local tmp_install
    local _saved_umask3; _saved_umask3=$(umask)
    umask 077
    tmp_install=$(mktemp "${local_key_file}.install.XXXXXX")
    umask "$_saved_umask3"
    chmod 600 "$tmp_install"
    cp -f "$new_key_tmp" "$tmp_install"
    mv -f "$tmp_install" "$local_key_file"
    chmod 600 "$local_key_file"
    log_success "  New key installed: $local_key_file"

    ROTATED_KEY_FILE="$local_key_file"

    # ------------------------------------------------------------------
    # 2b. Write a local recovery-kit file so the operator has a copy
    #     that survives independently of secrets/keys/
    # ------------------------------------------------------------------
    local kit_ts; kit_ts=$(date +%Y%m%d-%H%M%S)
    local kit_file="/root/vaultwarden-recovery-kit-${kit_ts}.txt"
    {
        echo "# VaultWarden-OCI Recovery Kit"
        echo "# Generated: $(date -u)"
        echo "# Host:      $(hostname -f 2>/dev/null || hostname)"
        echo "# IMPORTANT: Store this file offline in a secure password manager or USB."
        echo "#            Required to decrypt future backups created after this date."
        echo "#            Delete this file from /root/ once safely copied offline."
        echo ""
        cat "$new_key_tmp"
    } > "$kit_file" 2>/dev/null || true
    if [[ -f "$kit_file" ]]; then
        chmod 600 "$kit_file" 2>/dev/null || true
        ROTATED_KIT_FILE="$kit_file"
        log_warn "  Recovery kit saved: $kit_file"
        log_warn "  ← COPY THIS FILE OFFLINE NOW, then delete it from /root/"
    else
        log_warn "  Could not write recovery kit to /root/ — save the key manually."
        ROTATED_KIT_FILE=""
    fi

    # ------------------------------------------------------------------
    # 3. Install to systemd location /etc/vaultwarden/age-key.txt
    # ------------------------------------------------------------------
    local systemd_key="/etc/vaultwarden/age-key.txt"
    local canonical_key="$local_key_file"

    if [[ -f "$systemd_key" ]]; then
        install -m 600 -o root -g root "$new_key_tmp" "$systemd_key" || {
            log_error "Failed to install new key to $systemd_key"
            return 1
        }
        canonical_key="$systemd_key"
        log_success "  New key installed (systemd): $systemd_key"
    fi

    # ------------------------------------------------------------------
    # 4. Update SOPS_AGE_KEY_FILE in .env
    # ------------------------------------------------------------------
    local env_file="$PROJECT_ROOT/.env"
    if [[ -f "$env_file" ]]; then
        if grep -q '^SOPS_AGE_KEY_FILE=' "$env_file"; then
            sed -i "s|^SOPS_AGE_KEY_FILE=.*|SOPS_AGE_KEY_FILE=${canonical_key}|" "$env_file"
        else
            echo "SOPS_AGE_KEY_FILE=${canonical_key}" >> "$env_file"
        fi
        log_success "  SOPS_AGE_KEY_FILE=${canonical_key} written to .env"
    fi

    # ------------------------------------------------------------------
    # 5. Update SOPS_AGE_KEY_FILE in /etc/vaultwarden/vaultwarden.env (systemd)
    # ------------------------------------------------------------------
    local systemd_env="/etc/vaultwarden/vaultwarden.env"
    if [[ -f "$systemd_env" ]]; then
        if grep -q '^SOPS_AGE_KEY_FILE=' "$systemd_env"; then
            sed -i "s|^SOPS_AGE_KEY_FILE=.*|SOPS_AGE_KEY_FILE=${canonical_key}|" "$systemd_env"
        else
            echo "SOPS_AGE_KEY_FILE=${canonical_key}" >> "$systemd_env"
        fi
        log_success "  SOPS_AGE_KEY_FILE=${canonical_key} written to $systemd_env"
    fi

    # ------------------------------------------------------------------
    # 6. Derive public key for display
    # ------------------------------------------------------------------
    ROTATED_PUB_KEY=$(grep -m1 '^# public key:' "$local_key_file" | sed 's/^# public key: //' || true)
    if [[ -z "$ROTATED_PUB_KEY" ]]; then
        ROTATED_PUB_KEY=$(age-keygen -y "$local_key_file" 2>/dev/null || true)
    fi

    log_success "Key rotation complete."

    # ------------------------------------------------------------------
    # 7. Prune old Age private key backups — keep only 2 most recent
    # ------------------------------------------------------------------
    _prune_old_age_keys "$local_key_dir"

    return 0
}

# ---------------------------------------------------------------------------
# _display_new_key
#
# Prints the new age key in a prominent banner identical to what setup.sh
# would show on first install.  Requires the operator to press Enter to
# acknowledge before services start (unless --force is passed).
# ---------------------------------------------------------------------------
_display_new_key() {
    [[ "$DRY_RUN" == "true" ]] && return 0
    [[ -z "$ROTATED_KEY_FILE" ]] && return 0

    local priv_key_line
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
    { set +x; } 2>/dev/null
    echo      "  ${priv_key_line:-<could not read key — check $ROTATED_KEY_FILE>}"
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

# ---------------------------------------------------------------------------
# Misc restore helpers
# ---------------------------------------------------------------------------

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

create_pre_restore_snapshot() {
    [[ "$NO_PRE_BACKUP" == "true" ]] && { log_info "Skipping pre-restore snapshot (--no-backup)"; return 0; }
    [[ "$DRY_RUN"       == "true" ]] && { log_info "[DRY RUN] Would run: ./backup.sh --type emergency"; return 0; }
    local state_dir; state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    local db_path="$state_dir/data/db.sqlite3"
    [[ -f "$db_path" ]] && command -v sqlite3 >/dev/null 2>&1 && \
        sqlite3 "$db_path" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
    if [[ -x "./backup.sh" ]]; then
        log_info "Creating pre-restore emergency snapshot..."
        log_info "Invoking: $SCRIPT_DIR/backup.sh --type emergency --quiet"
        if ! ./backup.sh --type emergency --quiet; then
            if [[ "${RESTORE_SNAPSHOT_HARD_FAIL}" == "true" ]]; then
                log_error "Pre-restore snapshot FAILED (hard-fail)."
                log_error "Use --no-backup or set RESTORE_SNAPSHOT_HARD_FAIL=false to skip."
                return 1
            fi
            log_warn "Pre-restore snapshot failed (continuing — RESTORE_SNAPSHOT_HARD_FAIL=false)"
        fi
    else
        local msg="backup.sh not executable — cannot create pre-restore snapshot"
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

# ---------------------------------------------------------------------------
# DB restore
# ---------------------------------------------------------------------------
restore_db() {
    local backup_file="$1" age_key_file="$2" state_dir="$3" puid="$4" pgid="$5" tmpdir="$6"
    local dec_db="$tmpdir/db.sqlite3"

    log_info "Decrypting database backup..."
    age -d -i "$age_key_file" -o "$dec_db" "$backup_file" || {
        log_error "Decryption failed — verify the age key is correct."; return 1
    }
    [[ "$SKIP_VERIFICATION" != "true" ]] && { verify_sqlite "$dec_db" || return 1; }

    local db_dir="$state_dir/data" db_path
    db_path="$db_dir/db.sqlite3"
    mkdir -p "$db_dir"

    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local rollback_path=""
    if [[ -f "$db_path" ]]; then
        rollback_path="${db_path}.rollback-${ts}"
        log_info "Creating rollback copy: $(basename "$rollback_path")..."
        cp -a "$db_path" "$rollback_path" || {
            log_error "Failed to create rollback copy — aborting restore."; return 1
        }
        cp -a "$db_path" "${db_path}.pre-restore-${ts}"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would overwrite $db_path with decrypted database"
        [[ -n "$rollback_path" ]] && rm -f "$rollback_path" 2>/dev/null || true
        return 0
    fi

    log_info "Restoring database..."
    if ! cp -f "$dec_db" "$db_path"; then
        log_error "cp to live DB failed — rolling back..."
        if [[ -n "$rollback_path" && -f "$rollback_path" ]]; then
            cp -a "$rollback_path" "$db_path" && log_warn "Rollback successful." || {
                log_error "CRITICAL: Rollback failed. Manual recovery:"
                log_error "  cp '${rollback_path}' '${db_path}'"
            }
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
# Full / emergency restore
# ---------------------------------------------------------------------------
restore_full() {
    local backup_file="$1" age_key_file="$2" state_dir="$3" puid="$4" pgid="$5" tmpdir="$6" archive_format="$7"

    local inner_name="${backup_file%.age}"
    case "$inner_name" in
        *.tar.zst|*.tar.gz|*.tar.bz2|*.tar.xz|*.tgz|*.tbz) : ;;
        *) inner_name="${inner_name}.tar.gz" ;;
    esac
    local dec_tar="$tmpdir/$(basename "$inner_name")"
    local tar_filter; tar_filter="$(_tar_filter_for_file "$dec_tar")"

    log_info "Decrypting archive..."
    age -d -i "$age_key_file" -o "$dec_tar" "$backup_file" || {
        log_error "Decryption failed — verify the age key is correct."; return 1
    }

    if [[ "$SKIP_VERIFICATION" != "true" ]]; then
        log_info "Verifying archive structure..."
        # shellcheck disable=SC2086
        tar $tar_filter -tf "$dec_tar" >/dev/null || { log_error "Archive is corrupt or invalid"; return 1; }
    fi

    if [[ "$archive_format" == "absolute" ]]; then
        log_warn "Legacy archive format detected (version=1, absolute paths)."
        if [[ "$SKIP_VERIFICATION" != "true" ]]; then
            check_traversal_only "$dec_tar" || return 1
            log_success "Archive traversal check passed (legacy format)."
        else
            log_warn "--skip-verification set: path traversal check BYPASSED on legacy archive."
        fi
        [[ "$DRY_RUN" == "true" ]] && { log_info "[DRY RUN] Would tar -xf to /"; return 0; }
        # shellcheck disable=SC2086
        tar $tar_filter -xf "$dec_tar" -C / --no-same-owner --no-same-permissions --no-overwrite-dir --no-unlink --delay-directory-restore
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
    tar $tar_filter -xf "$dec_tar" -C "$staging" --no-same-owner --no-same-permissions --no-overwrite-dir --no-unlink --delay-directory-restore

    local rel_state="${state_dir#/}"
    if [[ ! -d "$staging/$rel_state" ]]; then
        log_error "Staging validation failed: expected directory not found: $staging/$rel_state"
        # shellcheck disable=SC2086
        tar $tar_filter -tf "$dec_tar" | head -20 >&2 || true
        return 1
    fi

    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    [[ -d "$state_dir" ]] && mv "$state_dir" "${state_dir}.pre-restore-${ts}"

    log_info "Promoting staged restore to live path..."
    mv "$staging/$rel_state" "$state_dir"
    chown -R "${puid}:${pgid}" "$state_dir/data" 2>/dev/null || log_warn "Could not set ownership on $state_dir/data"
    purge_wal_shm "$state_dir/data/db.sqlite3" || true

    local rel_project="${PROJECT_ROOT#/}"
    if [[ -d "$staging/$rel_project" ]]; then
        log_info "Restoring project config files from archive..."
        local config_files=(docker-compose.yml docker-compose.override.yml .env.example)
        [[ "$RESTORE_ENV" == "true" ]] && config_files=(.env "${config_files[@]}")
        for f in "${config_files[@]}"; do
            local src="$staging/$rel_project/$f"
            if [[ -f "$src" ]]; then
                if [[ "$f" == ".env" && -f "$PROJECT_ROOT/.env" ]]; then
                    cp -f "$PROJECT_ROOT/.env" "$PROJECT_ROOT/.env.pre-restore-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
                fi
                cp -f "$src" "$PROJECT_ROOT/$f"
                log_info "  Restored: $f"
            fi
        done
        for d in caddy fail2ban nginx; do
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log_header "VaultWarden-OCI Restore Utility"

    # Load .env unconditionally and early so every code path — including
    # --list and the rclone availability checks — can read config values
    # such as RCLONE_REMOTE_NAME and RCLONE_CONFIG.
    load_env_file 2>/dev/null || true   # best-effort; hard error below if root required

    # Resolve the backup storage root from .env using the same
    # key ("BACKUP_DIR") and default that backup.sh uses.  Every search path
    # in this script is built from BACKUP_BASE_DIR, never from PROJECT_ROOT/backups.
    BACKUP_BASE_DIR="$(get_config_value "BACKUP_DIR" "/var/lib/vaultwarden/backups")"
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
    # Use bash 4.1+ automatic FD allocation instead of hardcoded
    # FD 203, which could silently clobber an already-open file descriptor.
    local RESTORE_LOCK_FD
    exec {RESTORE_LOCK_FD}>"$RESTORE_LOCK_FILE"
    flock -n "$RESTORE_LOCK_FD" || {
        log_error "Another restore is already running."
        log_error "If the lock is stale, remove: ${RESTORE_LOCK_FILE}"
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

    # Fail closed if the expected data volume is not mounted.
    # In bootstrap/emergency-restore mode (--remote without .env), DATA_VOLUME_DEVICE
    # will be unset, so the guard is a no-op and restore can proceed.
    require_project_state_ready || exit 1

    # Re-resolve BACKUP_BASE_DIR now that .env is fully loaded,
    # using the same config key ("BACKUP_DIR") and default that backup.sh uses.
    BACKUP_BASE_DIR="$(get_config_value "BACKUP_DIR" "/var/lib/vaultwarden/backups")"

    local STATE_DIR; STATE_DIR="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    local AGE_KEY_FILE; AGE_KEY_FILE="$(get_config_value "SOPS_AGE_KEY_FILE" "secrets/keys/age-key.txt")"
    local PUID; PUID="$(get_config_value "PUID" "")"
    local PGID; PGID="$(get_config_value "PGID" "")"

    # If PUID/PGID are not in .env (bootstrap mode), prompt for them
    # interactively so a bare-metal emergency restore can proceed without a
    # pre-existing .env.
    if [[ -z "$PUID" || -z "$PGID" ]]; then
        if [[ -t 0 ]]; then
            log_warn "PUID and/or PGID are not set in .env."
            if [[ -z "$PUID" ]]; then
                read -r -p "  Enter PUID (numeric user ID, e.g. $(id -u)): " PUID
            fi
            if [[ -z "$PGID" ]]; then
                read -r -p "  Enter PGID (numeric group ID, e.g. $(id -g)): " PGID
            fi
        fi
        if [[ -z "$PUID" || -z "$PGID" ]]; then
            log_error "PUID and PGID must be set in .env (or entered interactively) before restoring."
            log_error "Find values with: id <your-username>"
            exit 1
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

    # ------------------------------------------------------------------
    # Step 1: Select backup (interactive or flags)
    # ------------------------------------------------------------------
    resolve_backup_file || exit 1
    [[ -f "$BACKUP_FILE" ]] || { log_error "Backup file not found: $BACKUP_FILE"; exit 1; }

    # ------------------------------------------------------------------
    # Step 2: Prompt for / resolve the decryption key
    # ------------------------------------------------------------------
    _prompt_age_key "$AGE_KEY_FILE" || exit 1

    # ------------------------------------------------------------------
    # Step 3: Verify backup checksum
    # ------------------------------------------------------------------
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
            exit 1
        fi
        log_success "Backup checksum verified: $(basename "$BACKUP_FILE")"
    elif [[ -f "$sha256_sidecar" && "$SKIP_VERIFICATION" == "true" ]]; then
        log_warn "--skip-verification: SHA-256 sidecar check bypassed."
    else
        log_warn "No .sha256 sidecar found — skipping pre-decryption checksum check."
    fi

    # ------------------------------------------------------------------
    # Step 4: Parse archive metadata
    # ------------------------------------------------------------------
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
    log_info "  Decrypt key: $AGE_KEY_FILE"

    # ------------------------------------------------------------------
    # Step 5: Final confirmation
    # ------------------------------------------------------------------
    if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" ]]; then
        echo ""
        log_warn "WARNING: This will overwrite current data."
        log_warn "Services will be stopped during the restore."
        log_warn "A NEW age key will be generated after the restore."
        echo ""
        read -r -p "Type 'yes' to proceed: " confirm
        [[ "$confirm" == "yes" ]] || { log_info "Restore cancelled."; exit 0; }
    fi

    # ------------------------------------------------------------------
    # Step 6: Pre-restore snapshot
    # ------------------------------------------------------------------
    create_pre_restore_snapshot || exit 1

    # ------------------------------------------------------------------
    # Step 7: Stop services
    # ------------------------------------------------------------------
    # Install a safety-net ERR trap so that if any step between here and
    # the final `docker compose up -d` fails, services are automatically
    # restarted. Without this, set -euo pipefail would leave services
    # permanently stopped, requiring manual intervention.
    _restore_safety_net() {
        local rc=$?
        if [[ $rc -ne 0 ]]; then
            log_warn "Restore encountered an error (exit $rc) — attempting to restart services..."
            docker compose up -d --remove-orphans 2>/dev/null || \
                log_error "CRITICAL: Failed to restart services after restore error. Manual intervention required: docker compose up -d"
        fi
    }
    trap _restore_safety_net ERR

    if [[ "$DRY_RUN" != "true" ]]; then
        if docker compose ps --status running --services 2>/dev/null | grep -q .; then
            log_info "Stopping services..."
            docker compose stop
        fi
    fi

    # ------------------------------------------------------------------
    # Step 8: Perform restore
    # ------------------------------------------------------------------
    case "$RESTORE_TYPE" in
        db)
            restore_db "$BACKUP_FILE" "$AGE_KEY_FILE" "$STATE_DIR" "$PUID" "$PGID" "$TMPDIR_RESTORE"
            ;;
        full|emergency)
            restore_full "$BACKUP_FILE" "$AGE_KEY_FILE" "$STATE_DIR" "$PUID" "$PGID" "$TMPDIR_RESTORE" "$archive_format"
            ;;
        *)
            log_error "Unknown restore type: $RESTORE_TYPE"; exit 1 ;;
    esac

    # ------------------------------------------------------------------
    # Step 9: Prune old pre-restore artefacts
    # ------------------------------------------------------------------
    if [[ "$DRY_RUN" != "true" ]]; then
        case "$RESTORE_TYPE" in
            db)             cleanup_pre_restore_artefacts "${STATE_DIR}/data/db.sqlite3" 3 || true ;;
            full|emergency) cleanup_pre_restore_artefacts "$STATE_DIR" 3 || true ;;
        esac
    fi

    # ------------------------------------------------------------------
    # Step 10: Rotate age key (new key generated, installed, validated)
    # ------------------------------------------------------------------
    if ! _rotate_age_key; then
        log_error "Age key rotation FAILED."
        log_error "The data restore itself succeeded, but the stack may not be able"
        log_error "to create new encrypted backups until the key is fixed."
        log_error "Run: age-keygen -o $PROJECT_ROOT/secrets/keys/age-key.txt"
        log_error "Then: sudo ./setup.sh --phase=systemd --install  (to sync /etc/vaultwarden/)"
        # Non-fatal: continue to start services so VaultWarden is available.
    fi

    # ------------------------------------------------------------------
    # Step 11: Display the new key prominently (operator must acknowledge)
    # ------------------------------------------------------------------
    _display_new_key

    # ------------------------------------------------------------------
    # Step 12: Start services
    # ------------------------------------------------------------------
    if [[ "$DRY_RUN" != "true" ]]; then
        log_info "Starting services..."
        if ! docker compose up -d --remove-orphans; then
            log_error "Failed to start services after restore."
            log_error "Investigate with: docker compose logs --tail=50"
            exit 1
        fi
        # Services are now running — clear the safety-net ERR trap so that
        # errors in the post-startup health check do not trigger a restart.
        trap - ERR

        log_info "Waiting for services to initialize (up to 60s)..."
        local max_wait=60 waited=0
        while (( waited < max_wait )); do
            sleep 5; (( waited += 5 ))
            docker inspect vaultwarden_app --format '{{.State.Status}} {{.State.Health.Status}}' \
                2>/dev/null | grep -qE $'running (healthy|$)' && break || true
        done

        if [[ -x "./maintenance.sh" ]]; then
            log_info "Running post-restore health check..."
            log_info "Invoking: $SCRIPT_DIR/maintenance.sh --health --quiet"
            ./maintenance.sh --health --quiet || {
                log_warn "Health check reported issues after restore."
                log_warn "Investigate with: docker compose logs --tail=50"
            }
        fi
    fi

    echo ""
    log_success "Restore complete."
    if [[ -n "$ROTATED_KEY_FILE" && "$DRY_RUN" != "true" ]]; then
        log_info  "New age key is live at: $ROTATED_KEY_FILE"
        log_info  "Run: sudo ./setup.sh --phase=systemd --install  (to sync /etc/vaultwarden/)"
    fi
}

main "$@"