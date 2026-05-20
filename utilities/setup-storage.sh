#!/usr/bin/env bash
# utilities/setup-storage.sh — VaultWarden-OCI storage setup and migration
#
# USAGE:
#   sudo utilities/setup-storage.sh [--mode setup|migrate|verify] [OPTIONS]
#
# MODES:
#   setup    Create and configure storage directories (default)
#   migrate  Migrate from boot volume to data volume (interactive)
#   verify   Re-check layout and permissions only (no changes)
#
# FLAGS:
#   --mode MODE           Mode to run: setup|migrate|verify (default: setup)
#   --data-device DEV     Block device for data volume
#   --data-mount PATH     Mount point (default: /mnt/vw-data)
#   --auto                Non-interactive mode
#   --dry-run             Preview actions without executing
#   --force               Skip confirmations
#   --help, -h            Show this help
#
# MIGRATE MODE ADDITIONAL FLAGS (pass to --mode migrate):
#   <subcommand>          run|resume|abort|status|verify
#   --source  PATH        Source directory
#   --target  PATH        Destination mount point
#   --device  DEV         Block device for new volume
#   --skip-stack-stop     Do not stop the Docker stack before migrating
#   --delete-source       Delete renamed source after successful verification
#   --yes                 Answer yes to all confirmations (except --delete-source)
#   --log-file PATH       Override default log file path
#   --backup-dir PATH     Backup directory (checked for stale backups)
#
# DEPENDENCIES: rsync flock findmnt lsblk df du awk sed mktemp stat curl
#   All are standard on Debian/Ubuntu/RHEL/Alpine (GNU or BusyBox).
#   stat -c (GNU/BusyBox format flag) is not supported on macOS — this script
#   targets Linux hosts only.  df -Pk and awk are POSIX-portable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"   # one level up from utilities/
cd "${PROJECT_ROOT}"

# ── Library bootstrap ─────────────────────────────────────────────────────────
REQUIRED_LIBS=(lib/common.sh lib/storage.sh lib/docker.sh lib/backup-utils.sh)
for _lib in "${REQUIRED_LIBS[@]}"; do
    [[ -f "${PROJECT_ROOT}/${_lib}" ]] || {
        echo "ERROR: Required library not found: ${PROJECT_ROOT}/${_lib}" >&2
        exit 1
    }
done
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"
source "${PROJECT_ROOT}/lib/storage.sh"
source "${PROJECT_ROOT}/lib/docker.sh"
source "${PROJECT_ROOT}/lib/backup-utils.sh"

# ── Environment ───────────────────────────────────────────────────────────────
[[ -f "${PROJECT_ROOT}/.env" ]] && load_env_file "${PROJECT_ROOT}/.env"
export DRY_RUN=false   # overridden by arg parsing; exported for lib functions

# ── Script-level variables ────────────────────────────────────────────────────
_SS_MODE="setup"
_SS_DATA_DEVICE=""
_SS_DATA_MOUNT="/mnt/vw-data"
_SS_AUTO=false
_SS_FORCE=false
TMP_WORKDIR=""
declare -a _SS_MIGRATE_ARGS=()

# ── ERR handler (setup/verify modes) ─────────────────────────────────────────
_ss_on_err() {
    log_error "Unexpected error at line ${2:-?} (exit ${1:-?})."
}
trap '_ss_on_err $? $LINENO' ERR

# ── Cleanup trap ──────────────────────────────────────────────────────────────
_ss_cleanup() {
    rm -rf "${TMP_WORKDIR:-}"
}
trap '_ss_cleanup' EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# MIGRATE MODE — constants, helpers, and pipeline steps
# (Adapted from the former standalone migration utility — all _mv_* functions)
# ═══════════════════════════════════════════════════════════════════════════════

readonly _MV_VERSION="1.1.0"
_MV_SCRIPT_NAME="utilities/setup-storage.sh"
readonly _MV_SCRIPT_NAME
_MV_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly _MV_TIMESTAMP
readonly _MV_LOCK_FILE="/run/lock/vaultwarden-migrate.lock"
readonly _MV_LOG_MAX_BYTES=$(( 10 * 1024 * 1024 ))   # 10 MiB — rotate beyond this
readonly _MV_VERIFY_TOLERANCE_PCT=1                    # allow ≤1% size delta post-rsync

# State file lives in PROJECT_ROOT (not PROJECT_STATE_DIR — state dir may change)
readonly _MV_STATE_FILE="${PROJECT_ROOT}/.migrate-volume.state"

# rsync exclude list — paths that must not be copied to the target
readonly -a _MV_RSYNC_EXCLUDES=(
    "lost+found/"       # ext4 fsck directory — permission errors on some kernels
    ".vw-data-volume"   # sentinel written by setup_data_volume(); never overwrite target's
    "*.sock"            # dead runtime sockets confuse service startup diagnostics
    "*.pid"             # PID files are always stale after stack stop
    "*.sqlite3-wal"     # SQLite WAL — a non-empty WAL after stack stop indicates a hot DB
    "*.sqlite3-shm"     # SQLite shared-memory file — always accompanies the WAL
)

# Systemd drop-in units whose ReadWritePaths= must be updated after migration.
# KEEP IN SYNC with _VW_DROPIN_UNITS in setup.sh.
readonly -a _MV_DROPIN_UNITS=(
    "vaultwarden-startup.service"
    "vaultwarden-backup.service"
    "vaultwarden-maintenance.service"
    "vaultwarden-restore.service"
)

# ── Migrate mode runtime state (set by _mv_parse_args) ───────────────────────
_MV_SUBCOMMAND="run"
_MV_SOURCE=""
_MV_TARGET=""
_MV_DEVICE=""
_MV_SKIP_STACK_STOP=false
_MV_DELETE_SOURCE=false
_MV_FORCE=false
_MV_YES=false
_MV_LOG_FILE=""
_MV_BACKUP_DIR_CUSTOM_WARNING=""

# Elapsed-time helper
_MV_START_TIME="${SECONDS}"   # bash built-in — seconds since shell started

_mv_elapsed() {
    local elapsed=$(( SECONDS - _MV_START_TIME ))
    printf '%dm%02ds' $(( elapsed / 60 )) $(( elapsed % 60 ))
}

# Human-readable byte formatter (replaces numfmt — works on GNU/BusyBox)
_mv_fmt_bytes() {
    # Usage: _mv_fmt_bytes <bytes>
    # Prints a human-readable IEC byte count (e.g. "1.5 GiB").
    # Pure awk — no numfmt dependency; portable to GNU coreutils and BusyBox.
    awk -v n="$1" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " ")
        v = n; i = 1
        while (v >= 1024 && i < 5) { v /= 1024; i++ }
        printf "%.1f %s", v, u[i]
    }'
}

# ── Lock helpers ──────────────────────────────────────────────────────────────
_MV_LOCK_FD=""

_mv_acquire_lock() {
    local lock_fd
    exec {lock_fd}>"${_MV_LOCK_FILE}"
    flock -n "${lock_fd}" || {
        log_error "Another migration is already running (lock held: ${_MV_LOCK_FILE})."
        log_error "Run: sudo utilities/setup-storage.sh --mode migrate status"
        exit 1
    }
    _MV_LOCK_FD="${lock_fd}"
}

_mv_release_lock() {
    [[ -n "${_MV_LOCK_FD:-}" ]] && {
        flock -u "${_MV_LOCK_FD}"
        eval "exec ${_MV_LOCK_FD}>&-"
        _MV_LOCK_FD=""
    }
}

# ── Migrate cleanup (registered as EXIT trap inside _mode_migrate) ────────────
_mv_cleanup() {
    _mv_release_lock
    _mv_log info "Elapsed: $(_mv_elapsed)"
}

# ── Root check ────────────────────────────────────────────────────────────────
_mv_require_root() {
    [[ "${EUID}" -eq 0 ]] || {
        log_error "This script must be run as root: sudo utilities/setup-storage.sh --mode migrate $*"
        exit 1
    }
}

# ── Logging ───────────────────────────────────────────────────────────────────
_mv_log() {
    # Passthrough to lib/common.sh log functions AND write to log file.
    # Usage: _mv_log <level> <message>
    # level: info | warn | error | success
    local level="$1"; shift
    local msg="$*"
    "log_${level}" "${msg}"
    printf '[%s] [%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "${level^^}" \
        "${msg}" >> "${_MV_LOG_FILE:-${PROJECT_ROOT}/logs/migrate-volume.log}"
}

# ── Full ERR handler for migrate mode ────────────────────────────────────────
_mv_on_err() {
    local rc="$1" lineno="$2"
    _mv_log error "Unexpected error at line ${lineno} (exit ${rc}). Migration halted."
    _mv_log error "Resume with: sudo utilities/setup-storage.sh --mode migrate resume"
    _mv_log error "Abort with:  sudo utilities/setup-storage.sh --mode migrate abort"
    # Do NOT call _mv_cleanup here — EXIT trap fires after ERR trap.
}

_mv_open_log() {
    # Determine log file path (--log-file overrides default).
    # Keep logs under PROJECT_ROOT/logs, never PROJECT_STATE_DIR/logs.
    # PROJECT_STATE_DIR is the migration source and may be renamed or deleted mid-run
    # (step 6 rename_source / step 6a delete_source). Using PROJECT_ROOT keeps the log
    # file alive for the full duration of the migration, including --delete-source runs.
    if [[ -z "${_MV_LOG_FILE:-}" ]]; then
        local log_dir="${PROJECT_ROOT}/logs"
        mkdir -p "${log_dir}" 2>/dev/null || log_dir="${PROJECT_ROOT}"
        _MV_LOG_FILE="${log_dir}/migrate-volume-${_MV_TIMESTAMP}.log"
    fi

    # Log rotation: if any existing migrate-volume log exceeds _MV_LOG_MAX_BYTES,
    # rotate it before this run creates a fresh file.
    local existing_log
    for existing_log in "$(dirname "${_MV_LOG_FILE}")"/migrate-volume-*.log; do
        [[ -f "${existing_log}" ]] || continue
        local size
        size="$(stat -c '%s' "${existing_log}" 2>/dev/null || echo 0)"
        if (( size > _MV_LOG_MAX_BYTES )); then
            mv "${existing_log}" "${existing_log}.${_MV_TIMESTAMP}"
            log_info "Rotated log: ${existing_log} → ${existing_log}.${_MV_TIMESTAMP}"
        fi
    done

    [[ "${DRY_RUN}" == "true" ]] || touch "${_MV_LOG_FILE}"

    _mv_log info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    _mv_log info "  setup-storage.sh v${_MV_VERSION} (migrate mode) — $(date '+%Y-%m-%d %H:%M:%S %Z')"
    _mv_log info "  Log file: ${_MV_LOG_FILE}"
    _mv_log info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── State file helpers ────────────────────────────────────────────────────────
_mv_state_write() {
    # Usage: _mv_state_write KEY [VALUE]
    local key="$1" value="${2:-true}"
    local tmp
    tmp="$(mktemp "${_MV_STATE_FILE}.XXXXXX")"
    if [[ -f "${_MV_STATE_FILE}" ]]; then
        grep -v "^${key}=" "${_MV_STATE_FILE}" > "${tmp}" 2>/dev/null || true
    fi
    printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
    chmod 0600 "${tmp}"
    mv -f "${tmp}" "${_MV_STATE_FILE}"
}

_mv_state_read() {
    # Usage: _mv_state_read KEY
    [[ -f "${_MV_STATE_FILE}" ]] || return 0
    grep "^${1}=" "${_MV_STATE_FILE}" 2>/dev/null | cut -d= -f2- | tail -1
}

_mv_state_has() {
    # Usage: _mv_state_has KEY — returns 0 if key is present and non-empty
    local val
    val="$(_mv_state_read "$1")"
    [[ -n "${val}" ]]
}

_mv_state_clear() {
    rm -f "${_MV_STATE_FILE}"
}

# ── Interactive confirmation helpers ──────────────────────────────────────────
_mv_confirm() {
    # Usage: _mv_confirm "Prompt text"
    # Returns 0 if confirmed, exits 1 if declined.
    # Skipped when --yes is set.
    [[ "${_MV_YES:-false}" == "true" ]] && return 0
    local reply
    read -r -p "${1} [y/N] " reply
    [[ "${reply}" =~ ^[Yy]$ ]] || { log_error "Aborted by operator."; exit 1; }
}

_mv_confirm_by_typing() {
    # Usage: _mv_confirm_by_typing "Prompt" "expected string"
    # Always interactive — --yes does NOT bypass this.
    local prompt="$1" expected="$2" reply
    read -r -p "${prompt} Type exactly '${expected}' to confirm: " reply
    [[ "${reply}" == "${expected}" ]] || {
        log_error "Confirmation did not match. Aborted."
        exit 1
    }
}

# ── Private helper: fstab stale-entry warning ─────────────────────────────────
_mv_warn_fstab_entries() {
    # Scans /etc/fstab for any entry whose device or mount point references
    # _MV_SOURCE or _MV_TARGET, and emits a prominent, actionable warning.
    [[ -f /etc/fstab ]] || return 0

    local line found=false
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]]  && continue
        if [[ "${line}" == *"${_MV_SOURCE}"* || "${line}" == *"${_MV_TARGET}"* ]]; then
            if [[ "${found}" == "false" ]]; then
                _mv_log warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                _mv_log warn "  ⚠  FSTAB WARNING: /etc/fstab references migration paths"
                found=true
            fi
            _mv_log warn "    ${line}"
        fi
    done < /etc/fstab

    if [[ "${found}" == "true" ]]; then
        _mv_log warn "  These entries could auto-mount old volumes at boot and shadow ${_MV_TARGET}."
        _mv_log warn "  Review and remove stale lines. To delete each matching line, run:"
        if [[ -n "${_MV_SOURCE}" ]]; then
            local _esc_src="${_MV_SOURCE//\\/\\\\}"
            _esc_src="${_esc_src//./\\.}"
            _esc_src="${_esc_src//|/\\|}"
            _mv_log warn "    sed -i '\\|${_esc_src}|d' /etc/fstab"
        fi
        if [[ -n "${_MV_TARGET}" ]]; then
            local _esc_tgt="${_MV_TARGET//\\/\\\\}"
            _esc_tgt="${_esc_tgt//./\\.}"
            _esc_tgt="${_esc_tgt//|/\\|}"
            _mv_log warn "    sed -i '\\|${_esc_tgt}|d' /etc/fstab"
        fi
        _mv_log warn "  (Verify the resulting fstab is correct before rebooting.)"
        _mv_log warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi
}

# ── Private helper: expand ~ in path ─────────────────────────────────────────
_mv_expand_path() {
    local p="$1"
    if [[ "$p" == ~/* ]]; then
        p="${HOME}/${p:2}"
    elif [[ "$p" == "~" ]]; then
        p="${HOME}"
    fi
    printf '%s' "$p"
}

# ── Block device type helpers ─────────────────────────────────────────────────
_mv_lsblk_is_partition() {
    [[ "$1" == "part" ]]
}

# ── Interactive block device selector ────────────────────────────────────────
_mv_select_device() {
    # Presents a numbered list of block devices and partitions using lsblk.
    # Marks the boot/root device with [boot] and partition entries with [part].
    # Populates _MV_DEVICE with the selected device path.
    # Skips if --device was already provided, subcommand is not 'run',
    # or --target was already provided (dir-to-dir migration needs no device).

    [[ -n "${_MV_DEVICE:-}" ]] && return 0
    [[ "${_MV_SUBCOMMAND}" == "run" ]] || return 0
    [[ -n "${_MV_TARGET:-}" ]] && return 0   # dir-to-dir migration; no device needed

    log_info "Detecting block devices using lsblk..."
    printf '\n'

    local -a dev_names dev_sizes dev_mounts dev_types
    local name size mount type

    while IFS=$'\t' read -r name size mount type; do
        [[ -z "${name}" ]] && continue
        dev_names+=( "/dev/${name}" )
        dev_sizes+=( "${size}" )
        dev_mounts+=( "${mount}" )
        dev_types+=( "${type}" )
    done < <(lsblk -o NAME,SIZE,MOUNTPOINT,TYPE -rn 2>/dev/null)

    if (( ${#dev_names[@]} == 0 )); then
        log_error "No block devices found via lsblk. Ensure the target disk is attached."
        return 1
    fi

    local root_source root_dev
    root_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    root_dev="$(lsblk -no PKNAME "${root_source}" 2>/dev/null \
        || lsblk -no NAME "${root_source}" 2>/dev/null \
        || true)"
    [[ -n "${root_dev}" ]] && root_dev="/dev/${root_dev}"

    local i tags mount_display
    for (( i=0; i<${#dev_names[@]}; i++ )); do
        tags=""
        if [[ "${dev_mounts[$i]}" == "/" ]] \
                || { [[ -n "${root_dev}" ]] \
                     && [[ "${#dev_names[$i]}" -ge "${#root_dev}" ]] \
                     && [[ "${dev_names[$i]:0:${#root_dev}}" == "${root_dev}" ]]; } \
                || [[ -n "${root_source}" && "${root_source}" == "${dev_names[$i]}" ]]; then
            tags="${tags} [boot]"
        fi
        if _mv_lsblk_is_partition "${dev_types[$i]}"; then
            tags="${tags} [part]"
        fi

        mount_display="${dev_mounts[$i]:-  -}"
        printf '  %d) %-14s  size: %-8s  mount: %-20s%s\n' \
            $(( i + 1 )) \
            "${dev_names[$i]}" \
            "${dev_sizes[$i]}" \
            "${mount_display}" \
            "${tags}"
    done

    printf '\n'
    printf '  Note: Cloud providers often attach volumes as a partition (e.g. /dev/sdb1)\n'
    printf '  rather than the whole disk (/dev/sdb). Both are listed above — select\n'
    printf '  whichever device path your cloud provider assigned to the new volume.\n'
    printf '\n'
    log_warn "Select TARGET block device for migration (DO NOT choose [boot]):"

    local choice
    while true; do
        read -r -p "  Device number [1-${#dev_names[@]}]: " choice
        if [[ "${choice}" =~ ^[0-9]+$ ]] \
                && (( choice >= 1 && choice <= ${#dev_names[@]} )); then
            _MV_DEVICE="${dev_names[$(( choice - 1 ))]}"
            # Guard against boot device selection
            if [[ "${dev_mounts[$(( choice - 1 ))]}" == "/" ]] \
                    || { [[ -n "${root_dev}" ]] \
                         && [[ "${#_MV_DEVICE}" -ge "${#root_dev}" ]] \
                         && [[ "${_MV_DEVICE:0:${#root_dev}}" == "${root_dev}" ]]; } \
                    || [[ -n "${root_source}" && "${root_source}" == "${_MV_DEVICE}" ]]; then
                log_error "You selected the boot device. Aborting to prevent data loss."
                exit 1
            fi
            break
        fi
        log_warn "Invalid selection. Enter a number between 1 and ${#dev_names[@]}."
    done

    printf '\n'
    log_info "Selected target device: ${_MV_DEVICE}"
}

# ── Interactive mount point prompt ────────────────────────────────────────────
_mv_prompt_target() {
    [[ -n "${_MV_TARGET:-}" ]] && return 0
    [[ "${_MV_SUBCOMMAND}" == "run" ]] || return 0

    local default_mount="${DATA_VOLUME_MOUNT:-/mnt/vw-data}"
    local reply

    printf '\n'
    read -r -p "  Enter target mount point [${default_mount}]: " reply
    _MV_TARGET="${reply:-${default_mount}}"
    _MV_TARGET="$(realpath -m "${_MV_TARGET}")"
    log_info "Using mount point: ${_MV_TARGET}"
    printf '\n'
}

# ── Pre-flight summary box ────────────────────────────────────────────────────
_mv_print_preflight_summary() {
    local mode
    if [[ -n "${_MV_DEVICE}" ]]; then
        mode="block-device (format + rsync)"
    else
        mode="directory-to-directory (rsync only, no format)"
    fi

    printf '\n'
    printf '╔═══════════════════════════════════════════════════════════════╗\n'
    printf '║  Migration Pre-flight Summary                                 ║\n'
    printf '╠═══════════════════════════════════════════════════════════════╣\n'
    printf '  %-20s %s\n'  "Mode:"          "${mode}"
    printf '  %-20s %s\n'  "Source:"        "${_MV_SOURCE}"
    printf '  %-20s %s\n'  "Target:"        "${_MV_TARGET}"
    printf '  %-20s %s\n'  "Device:"        "${_MV_DEVICE:-(none — dir-to-dir)}"
    printf '  %-20s %s\n'  "Stack stop:"    "$( [[ "${_MV_SKIP_STACK_STOP}" == 'true' ]] && echo 'SKIPPED (--skip-stack-stop)' || echo 'yes' )"
    printf '  %-20s %s\n'  "Delete source:" "$( [[ "${_MV_DELETE_SOURCE}" == 'true' ]] && echo 'yes (will prompt)' || echo 'no' )"
    printf '  %-20s %s\n'  "Dry run:"       "${DRY_RUN}"
    printf '  %-20s %s\n'  "Log file:"      "${_MV_LOG_FILE}"
    printf '╚═══════════════════════════════════════════════════════════════╝\n'
    printf '\n'

    # Warn when dir-to-dir target already contains files
    if [[ -z "${_MV_DEVICE}" && -d "${_MV_TARGET}" ]]; then
        local _target_item_count
        _target_item_count="$(find "${_MV_TARGET}" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
        if (( _target_item_count > 0 )); then
            printf '  ⚠  WARNING: Target directory is non-empty (%s item(s)).\n' "${_target_item_count}"
            printf '     rsync --delete will REMOVE files in target that do not exist in source.\n'
            printf '     Run with --dry-run first to inspect changes before proceeding.\n'
            printf '\n'
        fi
    fi

    if [[ "${_MV_YES:-false}" == "true" ]]; then
        _mv_log info "Non-interactive mode (--yes): proceeding without confirmation."
        return 0
    fi

    _mv_confirm "Confirm the above and start migration."
}

# ── Private helper: disk space check ─────────────────────────────────────────
_mv_check_disk_space() {
    local source="$1" target="$2"
    local src_bytes avail_bytes required_bytes

    src_bytes="$(du -sb "${source}/" | awk '{print $1}')"
    avail_bytes="$(df -Pk "${target}" | awk 'NR==2 {print $4 * 1024}')"
    required_bytes=$(( src_bytes + src_bytes / 10 ))

    _mv_log info "Disk space check:"
    _mv_log info "  Source size  : $(_mv_fmt_bytes "${src_bytes}")"
    _mv_log info "  Required     : $(_mv_fmt_bytes "${required_bytes}") (source + 10%)"
    _mv_log info "  Target avail : $(_mv_fmt_bytes "${avail_bytes}")"

    if (( avail_bytes < required_bytes )); then
        _mv_log error "Insufficient space on target."
        _mv_log error "  Need : $(_mv_fmt_bytes "${required_bytes}")"
        _mv_log error "  Have : $(_mv_fmt_bytes "${avail_bytes}")"
        return 1
    fi

    _mv_log success "Disk space OK."
}

# ── Private helper: stale backup check ───────────────────────────────────────
_mv_check_stale_backup() {
    local backup_base_dir newest newest_ts now_ts age_hours

    backup_base_dir="${BACKUP_DIR:-${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/backups}"

    newest="$(find "${backup_base_dir}" -name "*.age" -type f -print0 2>/dev/null \
        | xargs -r -0 stat -c '%Y %n' 2>/dev/null \
        | sort -rn \
        | head -1 \
        | awk '{print $2}')" || newest=""

    if [[ -z "${newest}" ]]; then
        _mv_log warn "No backups found. Strongly consider running: sudo ./backup.sh full"
        return 0
    fi

    newest_ts="$(stat -c '%Y' "${newest}" 2>/dev/null || echo 0)"
    now_ts="$(date +%s)"
    age_hours=$(( (now_ts - newest_ts) / 3600 ))

    if (( age_hours > 24 )); then
        _mv_log warn "Newest backup is ${age_hours}h old: ${newest}"
        _mv_log warn "Consider running: sudo ./backup.sh full"
    else
        _mv_log info "Backup age OK: ${age_hours}h old — ${newest}"
    fi
}

# ── Private helper: atomic .env key update ───────────────────────────────────
_mv_set_env_var() {
    local key="$1" value="$2"
    local env_file="${PROJECT_ROOT}/.env"
    local tmp escaped_value

    if [[ "${DRY_RUN}" == "true" ]]; then
        _mv_log info "[DRY RUN] would set: ${key}=${value}"
        return 0
    fi

    tmp="$(mktemp "${env_file}.XXXXXX")"
    chmod 0600 "${tmp}"

    if grep -q "^${key}=" "${env_file}" 2>/dev/null; then
        escaped_value="${value//\\/\\\\}"
        escaped_value="${escaped_value//&/\\&}"
        escaped_value="${escaped_value//|/\\|}"
        sed "s|^${key}=.*|${key}=${escaped_value}|" "${env_file}" > "${tmp}"
    else
        cp "${env_file}" "${tmp}"
        printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
    fi

    mv -f "${tmp}" "${env_file}"
    _mv_log info ".env updated: ${key}=${value}"
}

# ── Migrate usage / help ──────────────────────────────────────────────────────
_mv_usage() {
cat << 'EOF'
VaultWarden-OCI Volume Migration (via setup-storage.sh --mode migrate)

USAGE:
  sudo utilities/setup-storage.sh --mode migrate <subcommand> [OPTIONS]

SUBCOMMANDS:
  run      Execute the full migration pipeline (default)
  resume   Resume a previously interrupted migration
  status   Show current migration state
  abort    Roll back an in-progress migration
  verify   Re-run byte-count verification only (non-destructive)

OPTIONS (run / resume):
  --source  <path>   Source directory  (default: current PROJECT_STATE_DIR from .env)
  --target  <path>   Destination mount point  (prompted interactively if omitted)
  --device  <dev>    Block device for new volume (e.g. /dev/sdb)
                     Prompted interactively via lsblk if omitted.
                     Omit entirely for directory-to-directory migration.
  --skip-stack-stop  Do not stop the Docker stack before migrating.
                     Requires explicit runtime confirmation. Use with caution.
                     Cannot be combined with --yes (non-interactive mode).
  --delete-source    Delete renamed source after successful verification.
                     Always requires typing the path to confirm.
  --dry-run          Print all actions without executing them.
  --force            Skip the pre-migration backup confirmation prompt.
  --yes              Answer yes to all confirmations (except --delete-source).
                     Requires --target when used (non-interactive mode).
                     Cannot be combined with --skip-stack-stop.
  --log-file <path>  Override default log file path.
  --help             Show this help and exit.

EXAMPLES:
  # Interactive (prompts for device and mount point)
  sudo utilities/setup-storage.sh --mode migrate run

  # Non-interactive: boot volume → dedicated data volume
  sudo utilities/setup-storage.sh --mode migrate run \
    --source /var/lib/vaultwarden \
    --target /mnt/vw-data \
    --device /dev/sdb \
    --yes

  # Directory-to-directory (no device, no format step)
  sudo utilities/setup-storage.sh --mode migrate run \
    --source /var/lib/vaultwarden \
    --target /mnt/vw-data2

  # Dry run first
  sudo utilities/setup-storage.sh --mode migrate run \
    --source /var/lib/vaultwarden \
    --target /mnt/vw-data \
    --device /dev/sdb \
    --dry-run

  # Resume after interruption
  sudo utilities/setup-storage.sh --mode migrate resume

  # Check status
  sudo utilities/setup-storage.sh --mode migrate status

  # Abort and roll back
  sudo utilities/setup-storage.sh --mode migrate abort
EOF
}

# ── Migrate argument parser ───────────────────────────────────────────────────
_mv_parse_args() {
    _MV_SUBCOMMAND="run"
    _MV_SOURCE=""
    _MV_TARGET=""
    _MV_DEVICE=""
    _MV_SKIP_STACK_STOP=false
    _MV_DELETE_SOURCE=false
    _MV_FORCE=false
    _MV_YES=false
    _MV_LOG_FILE=""

    # First positional arg is subcommand if it does not start with '--'
    if [[ $# -gt 0 && "${1}" != --* ]]; then
        _MV_SUBCOMMAND="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source)
                _MV_SOURCE="$(_mv_expand_path "$2")"
                shift 2
                ;;
            --target)
                _MV_TARGET="$(_mv_expand_path "$2")"
                shift 2
                ;;
            --device)
                _MV_DEVICE="$2"
                shift 2
                ;;
            --log-file)
                _MV_LOG_FILE="$2"
                shift 2
                ;;
            --skip-stack-stop)
                _MV_SKIP_STACK_STOP=true
                shift
                ;;
            --delete-source)
                _MV_DELETE_SOURCE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                _MV_FORCE=true
                shift
                ;;
            --yes)
                _MV_YES=true
                shift
                ;;
            --help|-h)
                _mv_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                _mv_usage
                exit 1
                ;;
        esac
    done

    # Default source to current PROJECT_STATE_DIR
    if [[ -z "${_MV_SOURCE}" ]]; then
        _MV_SOURCE="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    fi

    # Validate required args per subcommand
    case "${_MV_SUBCOMMAND}" in
        run)
            if [[ "${_MV_YES:-false}" == "true" && -z "${_MV_TARGET}" ]]; then
                log_error "--target is required when using --yes (non-interactive mode)."
                exit 1
            fi
            if [[ "${_MV_YES:-false}" == "true" && "${_MV_SKIP_STACK_STOP}" == "true" ]]; then
                log_error "--skip-stack-stop cannot be combined with --yes."
                log_error "Migrating a live stack requires an interactive operator to confirm."
                exit 1
            fi
            ;;
        resume|status|abort|verify)
            # No required args
            ;;
        *)
            log_error "Unknown subcommand: ${_MV_SUBCOMMAND}"
            _mv_usage
            exit 1
            ;;
    esac

    # Canonicalise paths
    _MV_SOURCE="$(realpath -m "${_MV_SOURCE}")"
    if [[ -n "${_MV_TARGET}" ]]; then
        _MV_TARGET="$(realpath -m "${_MV_TARGET}")"
    fi

    # Safe-character validation: reject paths with characters that could break
    # shell quoting, state-file parsing, or rsync invocations.
    local _mv_unsafe_re=$'[^a-zA-Z0-9/._-]'
    if [[ "${_MV_SOURCE}" =~ ${_mv_unsafe_re} ]]; then
        log_error "Source path contains unsafe characters: ${_MV_SOURCE}"
        log_error "Only alphanumeric characters and / . _ - are allowed."
        exit 1
    fi
    if [[ -n "${_MV_TARGET}" && "${_MV_TARGET}" =~ ${_mv_unsafe_re} ]]; then
        log_error "Target path contains unsafe characters: ${_MV_TARGET}"
        log_error "Only alphanumeric characters and / . _ - are allowed."
        exit 1
    fi
}

# ── Pipeline step 0: Pre-flight validation ────────────────────────────────────
_mv_step_validate() {
    _mv_log info "── validate ──────────────────────────────────────────────────────"

    require_commands rsync flock findmnt lsblk df du awk sed mktemp stat
    if [[ -n "${_MV_DEVICE}" ]]; then
        require_commands blkid mkfs.ext4
    fi

    [[ -d "${_MV_SOURCE}" ]] || {
        _mv_log error "Source path does not exist or is not a directory: ${_MV_SOURCE}"
        return 1
    }

    local canon_src canon_tgt
    canon_src="$(realpath -m "${_MV_SOURCE}")"
    canon_tgt="$(realpath -m "${_MV_TARGET}")"
    [[ "${canon_src}" != "${canon_tgt}" ]] || {
        _mv_log error "Source and target are the same path: ${canon_src}"
        return 1
    }

    [[ "${canon_tgt}" != "${canon_src}/"* ]] || {
        _mv_log error "Target '${canon_tgt}' is a subdirectory of source '${canon_src}'."
        _mv_log error "This would cause an rsync infinite loop. Aborted."
        return 1
    }

    if [[ "${_MV_TARGET}" == /dev/* && -z "${_MV_DEVICE}" ]]; then
        _mv_log error "--target looks like a block device path: ${_MV_TARGET}"
        _mv_log error "To migrate to a block device use --device ${_MV_TARGET} with a directory --target."
        _mv_log error "Example: --device ${_MV_TARGET} --target /mnt/vw-data"
        return 1
    fi

    if find /proc/*/fd -lname "${_MV_SOURCE}/*" -print0 2>/dev/null \
            | xargs -r -0 ls -l 2>/dev/null \
            | grep -q rsync; then
        _mv_log error "rsync appears to be actively writing to ${_MV_SOURCE}."
        _mv_log error "Wait for it to finish before migrating."
        return 1
    fi

    if [[ -n "${_MV_DEVICE}" ]]; then
        [[ -b "${_MV_DEVICE}" ]] || {
            _mv_log error "Device is not a block device: ${_MV_DEVICE}"
            return 1
        }
        local dev_mount
        dev_mount="$(findmnt -n -o TARGET --source "${_MV_DEVICE}" 2>/dev/null || true)"
        if [[ -n "${dev_mount}" && "${dev_mount}" != "${_MV_TARGET}" ]]; then
            _mv_log error "Device ${_MV_DEVICE} is already mounted at: ${dev_mount}"
            _mv_log error "Unmount it first or omit --device if the target is already mounted."
            return 1
        fi
    fi

    if [[ -z "${_MV_DEVICE}" ]]; then
        mkdir -p "${_MV_TARGET}" 2>/dev/null || true
        _mv_check_disk_space "${_MV_SOURCE}" "${_MV_TARGET}"
    else
        _mv_log info "Block-device migration: disk space check deferred until after format and mount."
    fi

    _mv_check_stale_backup

    if [[ "${_MV_SKIP_STACK_STOP}" == "true" ]]; then
        local running_containers
        running_containers="$(docker compose ps --status running --quiet 2>/dev/null \
            | wc -l | tr -d ' ' || true)"
        if (( running_containers > 0 )); then
            _mv_log warn "WARNING: ${running_containers} VaultWarden container(s) are currently running."
            _mv_log warn "Migrating a live stack risks SQLite WAL corruption."
            _mv_log warn "Data integrity cannot be guaranteed if the database is actively written."
            _mv_confirm_by_typing \
                "You are about to migrate a LIVE stack." \
                "LIVE"
        fi
    fi

    [[ -f "${PROJECT_ROOT}/.env" ]] || {
        _mv_log error ".env not found at: ${PROJECT_ROOT}/.env"
        return 1
    }
    grep -q "^PROJECT_STATE_DIR=" "${PROJECT_ROOT}/.env" 2>/dev/null || {
        _mv_log error "PROJECT_STATE_DIR key not found in .env"
        return 1
    }

    [[ -f "${PROJECT_ROOT}/docker-compose.yml" ]] || {
        _mv_log error "docker-compose.yml not found at: ${PROJECT_ROOT}/docker-compose.yml"
        return 1
    }

    if [[ "${DRY_RUN}" != "true" ]]; then
        _mv_state_write MV_SOURCE           "${_MV_SOURCE}"
        _mv_state_write MV_TARGET           "${_MV_TARGET}"
        _mv_state_write MV_DEVICE           "${_MV_DEVICE:-none}"
        _mv_state_write MV_START_TS         "$(date +%s)"
        _mv_state_write MV_LOG_FILE         "${_MV_LOG_FILE}"
        _mv_state_write MV_SKIP_STACK_STOP  "${_MV_SKIP_STACK_STOP}"
        _mv_state_write MV_DELETE_SOURCE    "${_MV_DELETE_SOURCE}"
    fi

    _mv_log success "Pre-flight validation passed."
}

# ── Pipeline step 1: Pre-migration backup prompt ──────────────────────────────
_mv_step_backup_prompt() {
    _mv_log info "── backup_prompt ─────────────────────────────────────────────────"

    if [[ "${_MV_FORCE}" == "true" ]]; then
        _mv_log info "Skipping backup prompt (--force)."
        return 0
    fi

    _mv_log warn "⚠  Before migrating, a current backup is strongly recommended."
    _mv_log warn "   Run: sudo ./backup.sh full"
    _mv_log warn "   Once complete, re-run this migration with --force to skip this prompt."

    _mv_confirm "Confirm you have a recent backup and wish to proceed."
}

# ── Pipeline step 2: Stop the stack ──────────────────────────────────────────
_mv_step_stop() {
    _mv_log info "── stop ──────────────────────────────────────────────────────────"

    if [[ "${_MV_SKIP_STACK_STOP}" == "true" ]]; then
        _mv_log warn "Skipping stack stop (--skip-stack-stop). Proceeding with live stack."
    else
        _mv_log info "Container state before stop:"
        docker compose ps --format json 2>/dev/null || true

        if [[ "${DRY_RUN}" == "true" ]]; then
            _mv_log info "[DRY RUN] would: stop VaultWarden stack (stop_services)"
            return 0
        fi

        stop_services   # from lib/docker.sh

        _mv_log info "Container state after stop:"
        docker compose ps --format json 2>/dev/null || true
        _mv_log success "Stack stopped."
    fi

    [[ "${DRY_RUN}" == "true" ]] && return 0
    local wal_files
    wal_files="$(find "${_MV_SOURCE}" -name "*.sqlite3-wal" -size +0c -type f 2>/dev/null || true)"
    if [[ -n "${wal_files}" ]]; then
        _mv_log warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        _mv_log warn "  ⚠  WAL WARNING: Non-empty SQLite WAL file(s) found after stack stop:"
        local _wal
        while IFS= read -r _wal; do
            _mv_log warn "    ${_wal}"
        done <<< "${wal_files}"
        _mv_log warn "  A non-empty WAL indicates the database was not cleanly checkpointed."
        _mv_log warn "  WAL/SHM files are excluded from rsync; copying without them may"
        _mv_log warn "  leave the target database in an inconsistent state."
        _mv_log warn "  Remediation before proceeding:"
        _mv_log warn "    sudo sqlite3 <path/to/db.sqlite3> 'PRAGMA wal_checkpoint(FULL);'"
        _mv_log warn "  Or run: sudo ./maintenance.sh db-maint"
        _mv_log warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        _mv_confirm "Non-empty WAL file(s) detected. Proceeding risks an inconsistent database migration. Confirm to continue."
    fi
}

# ── Pipeline step 3: Format and mount target volume ───────────────────────────
_mv_step_format() {
    _mv_log info "── format ────────────────────────────────────────────────────────"

    if [[ -z "${_MV_DEVICE}" ]]; then
        _mv_log info "No --device supplied — skipping format step (directory-to-directory migration)."
        return 0
    fi

    if mountpoint -q "${_MV_TARGET}" 2>/dev/null; then
        _mv_log info "Target ${_MV_TARGET} is already a mounted filesystem — skipping format."
        _mv_check_disk_space "${_MV_SOURCE}" "${_MV_TARGET}"
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        _mv_log info "[DRY RUN] would: setup_data_volume (format and mount ${_MV_DEVICE} at ${_MV_TARGET})"
        return 0
    fi

    DATA_VOLUME_DEVICE="${_MV_DEVICE}"
    DATA_VOLUME_MOUNT="${_MV_TARGET}"
    export DATA_VOLUME_DEVICE DATA_VOLUME_MOUNT

    setup_data_volume   # from lib/storage.sh
    _mv_log success "Target volume formatted and mounted: ${_MV_DEVICE} → ${_MV_TARGET}"

    _mv_check_disk_space "${_MV_SOURCE}" "${_MV_TARGET}"
}

# ── Pipeline step 4: rsync data transfer ─────────────────────────────────────
_mv_step_rsync() {
    _mv_log info "── rsync ─────────────────────────────────────────────────────────"

    local -a rsync_flags=(
        --archive
        --hard-links
        --acls
        --xattrs
        --sparse
        --one-file-system
        --delete
        --delete-excluded
        --human-readable
        --progress
        --stats
    )

    local excl
    for excl in "${_MV_RSYNC_EXCLUDES[@]}"; do
        rsync_flags+=("--exclude=${excl}")
    done

    [[ "${DRY_RUN}" == "true" ]] && rsync_flags+=(--dry-run)

    if [[ "${DRY_RUN}" != "true" ]]; then
        mkdir -p "${_MV_TARGET}"
    else
        _mv_log info "[DRY RUN] would: mkdir -p ${_MV_TARGET}"
    fi

    _mv_log info "Running rsync: ${_MV_SOURCE%/}/ → ${_MV_TARGET}"
    _mv_log info "Flags: ${rsync_flags[*]}"

    rsync "${rsync_flags[@]}" "${_MV_SOURCE%/}/" "${_MV_TARGET}"
    _mv_log success "rsync transfer complete."
}

# ── Pipeline step 5: Verify transfer ─────────────────────────────────────────
_mv_step_verify() {
    _mv_log info "── verify ────────────────────────────────────────────────────────"

    if [[ "${DRY_RUN}" == "true" ]]; then
        _mv_log info "[DRY RUN] would: compare du -sb ${_MV_SOURCE}/ and ${_MV_TARGET}/ byte counts"
        _mv_log info "[DRY RUN] would: fail if delta exceeds ${_MV_VERIFY_TOLERANCE_PCT}% tolerance"
        return 0
    fi

    local src_bytes tgt_bytes delta pct_x100

    src_bytes="$(du -sb "${_MV_SOURCE}/" | awk '{print $1}')"
    tgt_bytes="$(du -sb "${_MV_TARGET}/" | awk '{print $1}')"

    _mv_log info "Source size : $(_mv_fmt_bytes "${src_bytes}")"
    _mv_log info "Target size : $(_mv_fmt_bytes "${tgt_bytes}")"

    if (( src_bytes == 0 )); then
        _mv_log warn "Source reports 0 bytes — skipping percentage check."
        return 0
    fi

    # Compute absolute delta as a percentage of source, scaled by 100 for precision.
    delta=$(( tgt_bytes > src_bytes ? tgt_bytes - src_bytes : src_bytes - tgt_bytes ))
    pct_x100=$(( delta * 10000 / src_bytes ))

    _mv_log info "Delta: $(_mv_fmt_bytes "${delta}") ($(( pct_x100 / 100 )).$(( pct_x100 % 100 ))%)"

    if (( pct_x100 > _MV_VERIFY_TOLERANCE_PCT * 100 )); then
        _mv_log error "Byte-count delta exceeds tolerance (${_MV_VERIFY_TOLERANCE_PCT}%)."
        _mv_log error "Investigate before proceeding. Resume with: sudo utilities/setup-storage.sh --mode migrate resume"
        return 1
    fi

    _mv_log success "Byte-count verification passed (delta ≤ ${_MV_VERIFY_TOLERANCE_PCT}%)."

    # Content integrity check: rsync --checksum --dry-run reports any files whose
    # content differs between source and target.
    _mv_log info "Running content integrity check (rsync --checksum --dry-run)..."
    local _chk_out _chk_count
    _chk_out="$(rsync --archive --checksum --dry-run --itemize-changes \
        "${_MV_SOURCE%/}/" "${_MV_TARGET}" 2>/dev/null || true)"
    _chk_count="$(printf '%s\n' "${_chk_out}" | grep -c '^>f' || true)"

    if (( _chk_count > 0 )); then
        _mv_log error "Content integrity check FAILED: ${_chk_count} file(s) have checksum mismatches."
        _mv_log error "Files with content discrepancies:"
        printf '%s\n' "${_chk_out}" | grep '^>f' | cut -d' ' -f2- | \
            while IFS= read -r _f; do _mv_log error "  ${_f}"; done
        _mv_log error "Investigate before proceeding. Resume with: sudo utilities/setup-storage.sh --mode migrate resume"
        return 1
    fi

    _mv_log success "Content integrity check passed (all file checksums match)."
}

# ── Pipeline step 6: Rename source ───────────────────────────────────────────
_mv_step_rename_source() {
    _mv_log info "── rename_source ─────────────────────────────────────────────────"

    local renamed="${_MV_SOURCE}.pre-migration.${_MV_TIMESTAMP}"

    if mountpoint -q "${_MV_SOURCE}" 2>/dev/null; then
        _mv_log warn "Source ${_MV_SOURCE} is a mount point — rename not meaningful."
        _mv_log warn "After verifying the migration, unmount and detach the old volume manually."
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        _mv_log info "[DRY RUN] would: mv ${_MV_SOURCE} ${renamed}"
    else
        mv "${_MV_SOURCE}" "${renamed}"
        _mv_log success "Source renamed: ${_MV_SOURCE} → ${renamed}"
    fi
}

# ── Pipeline step 6a: Delete source (optional) ───────────────────────────────
_mv_step_delete_source() {
    _mv_log info "── delete_source ─────────────────────────────────────────────────"

    local candidate newest_ts=0 candidate_ts cand_renamed=""
    for candidate in "${_MV_SOURCE}.pre-migration."*/; do
        [[ -d "${candidate}" ]] || continue
        candidate_ts="$(stat -c '%Y' "${candidate}" 2>/dev/null || echo 0)"
        if (( candidate_ts > newest_ts )); then
            newest_ts="${candidate_ts}"
            cand_renamed="${candidate%/}"
        fi
    done
    local renamed="${cand_renamed}"

    if [[ -z "${renamed}" || ! -d "${renamed}" ]]; then
        _mv_log warn "Renamed source not found — nothing to delete."
        return 0
    fi

    _mv_log warn "You are about to permanently delete:"
    _mv_log warn "  ${renamed}"
    _mv_confirm_by_typing \
        "To confirm deletion, type the FULL PATH shown above." \
        "${renamed}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        _mv_log info "[DRY RUN] would: rm -rf ${renamed}"
    else
        rm -rf "${renamed}"
        _mv_log success "Source deleted: ${renamed}"
    fi
}

# ── Pipeline step 7: Update .env ─────────────────────────────────────────────
_mv_step_update_env() {
    _mv_log info "── update_env ────────────────────────────────────────────────────"

    local env_file="${PROJECT_ROOT}/.env"
    local old_state_dir="${_MV_SOURCE}"

    if [[ "${DRY_RUN}" != "true" ]]; then
        cp "${env_file}" "${env_file}.pre-migration.${_MV_TIMESTAMP}"
        chmod 0600 "${env_file}.pre-migration.${_MV_TIMESTAMP}"
        _mv_log info ".env backup created: ${env_file}.pre-migration.${_MV_TIMESTAMP}"

        # Prune older .env.pre-migration.* backups — keep only the one just created.
        local _env_cand _env_newest _env_newest_ts=0 _env_cand_ts
        local -a _env_all_cands=()
        _env_newest="${env_file}.pre-migration.${_MV_TIMESTAMP}"
        for _env_cand in "${PROJECT_ROOT}"/.env.pre-migration.*; do
            [[ -f "${_env_cand}" ]] || continue
            _env_all_cands+=( "${_env_cand}" )
            _env_cand_ts="$(stat -c '%Y' "${_env_cand}" 2>/dev/null || echo 0)"
            if (( _env_cand_ts > _env_newest_ts )); then
                _env_newest_ts="${_env_cand_ts}"
                _env_newest="${_env_cand}"
            fi
        done
        for _env_cand in "${_env_all_cands[@]+"${_env_all_cands[@]}"}"; do
            [[ "${_env_cand}" == "${_env_newest}" ]] && continue
            rm -f "${_env_cand}"
            _mv_log info "Removed stale .env backup: ${_env_cand}"
        done
    else
        _mv_log info "[DRY RUN] would: cp ${env_file} ${env_file}.pre-migration.${_MV_TIMESTAMP}"
    fi

    _mv_set_env_var PROJECT_STATE_DIR "${_MV_TARGET}"

    if [[ -n "${_MV_DEVICE}" ]]; then
        _mv_set_env_var DATA_VOLUME_MOUNT  "${_MV_TARGET}"
        _mv_set_env_var DATA_VOLUME_DEVICE "${_MV_DEVICE}"
    fi

    local current_backup_dir
    current_backup_dir="$(grep "^BACKUP_DIR=" "${env_file}" 2>/dev/null | cut -d= -f2- || true)"

    if [[ "${current_backup_dir}" == "${old_state_dir}/backups" ]]; then
        _mv_set_env_var BACKUP_DIR "${_MV_TARGET}/backups"
    elif [[ -z "${current_backup_dir}" ]]; then
        _mv_log warn "BACKUP_DIR is not set in .env."
        _mv_log warn "The runtime default will resolve via PROJECT_STATE_DIR, which has been updated to: ${_MV_TARGET}"
        _mv_log warn "Verify backup.sh behaviour post-migration to confirm backups land in the expected location."
    elif [[ "${current_backup_dir}" == "${_MV_TARGET}/backups" ]]; then
        _mv_log info "BACKUP_DIR already points to the new target — no update needed."
    else
        _mv_log warn "BACKUP_DIR is set to a custom path: ${current_backup_dir}"
        _mv_log warn "This path was NOT auto-updated. Verify it points to the correct location on the new volume."
        _mv_log warn "Update manually if needed: nano ${env_file}"
        if [[ "${_MV_YES:-false}" == "true" ]]; then
            _mv_log warn "Non-interactive mode (--yes): BACKUP_DIR confirmation bypassed. Verify manually post-migration."
            _MV_BACKUP_DIR_CUSTOM_WARNING="${current_backup_dir}"
        else
            _mv_confirm "Acknowledge: BACKUP_DIR (${current_backup_dir}) was not updated and requires manual verification."
        fi
    fi

    _mv_log success ".env updated for new state directory: ${_MV_TARGET}"
}

# ── Pipeline step 8: Update systemd drop-in paths ────────────────────────────
_mv_apply_dropin_paths() {
    # Usage: _mv_apply_dropin_paths <old_path> <new_path>
    local old_path="$1" new_path="$2"
    local unit drop_in tmp updated_any=false

    for unit in "${_MV_DROPIN_UNITS[@]}"; do
        drop_in="/etc/systemd/system/${unit}.d/vaultwarden-paths.conf"
        if [[ ! -f "${drop_in}" ]]; then
            _mv_log warn "Drop-in not found (skipping): ${drop_in}"
            continue
        fi

        if ! grep -qF "${old_path}" "${drop_in}" 2>/dev/null; then
            _mv_log info "No reference to old path in: ${drop_in} (idempotent)"
            continue
        fi

        if [[ "${DRY_RUN}" == "true" ]]; then
            _mv_log info "[DRY RUN] would: update ${drop_in}: ${old_path} → ${new_path}"
            continue
        fi

        tmp="$(mktemp "${drop_in}.XXXXXX")"
        local escaped_old escaped_new
        escaped_old="${old_path//\\/\\\\}"
        escaped_old="${escaped_old//|/\\|}"
        escaped_old="${escaped_old//./\\.}"
        escaped_new="${new_path//\\/\\\\}"
        escaped_new="${escaped_new//|/\\|}"
        escaped_new="${escaped_new//&/\\&}"
        sed "s|${escaped_old}|${escaped_new}|g" "${drop_in}" > "${tmp}"
        chmod 644 "${tmp}"
        mv -f "${tmp}" "${drop_in}"
        _mv_log info "Updated drop-in: ${drop_in}"
        updated_any=true
    done

    if [[ "${updated_any}" == "true" ]] && [[ "${DRY_RUN}" != "true" ]]; then
        systemctl daemon-reload 2>/dev/null \
            || _mv_log warn "systemctl daemon-reload failed — a reboot may be required."
        _mv_log success "Systemd drop-ins updated and daemon reloaded."
    fi
}

_mv_step_update_dropin() {
    _mv_log info "── update_dropin ─────────────────────────────────────────────────"
    _mv_apply_dropin_paths "${_MV_SOURCE}" "${_MV_TARGET}"
}

# ── Pipeline step 8a: Install Docker mount guard ──────────────────────────────
_mv_step_mount_guard() {
    _mv_log info "── mount_guard ───────────────────────────────────────────────────"

    if [[ -z "${_MV_DEVICE}" ]]; then
        _mv_log info "No --device supplied — skipping Docker mount guard installation."
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        _mv_log info "[DRY RUN] would: install_docker_mount_guard for ${_MV_TARGET}"
        return 0
    fi

    DATA_VOLUME_DEVICE="${_MV_DEVICE}"
    DATA_VOLUME_MOUNT="${_MV_TARGET}"
    export DATA_VOLUME_DEVICE DATA_VOLUME_MOUNT

    install_docker_mount_guard   # from lib/storage.sh
    _mv_log success "Docker mount guard installed."
}

# ── Pipeline step 9: Restart the stack ───────────────────────────────────────
_mv_step_start() {
    _mv_log info "── start ─────────────────────────────────────────────────────────"

    if [[ "${DRY_RUN}" == "true" ]]; then
        _mv_log info "[DRY RUN] would: start VaultWarden stack (start_services)"
        return 0
    fi

    if ! start_services; then   # from lib/docker.sh
        _mv_log error "start_services failed — health check will surface the failure explicitly."
    else
        _mv_log success "Stack started."
    fi
}

# ── Pipeline step 10: Health check ───────────────────────────────────────────
_mv_step_healthcheck() {
    _mv_log info "── healthcheck ───────────────────────────────────────────────────"

    if [[ "${DRY_RUN}" == "true" ]]; then
        _mv_log info "[DRY RUN] would: poll 'docker compose ps --status running --quiet' for healthy state (up to 120s)"
        _mv_log info "[DRY RUN] would: write MIGRATION_COMPLETE=true to state file"
        _mv_print_checklist
        return 0
    fi

    local max_wait=120
    local poll_interval=10
    local elapsed=0
    local healthy=false

    while (( elapsed < max_wait )); do
        local running_count total_count
        running_count="$(docker compose ps --status running --quiet 2>/dev/null | wc -l | tr -d ' ' || true)"
        total_count="$(docker compose ps --quiet 2>/dev/null | wc -l | tr -d ' ' || true)"

        if (( total_count > 0 && running_count == total_count )); then
            healthy=true
            break
        fi

        _mv_log info "Waiting for containers to become healthy (${elapsed}s / ${max_wait}s)..."
        sleep "${poll_interval}"
        elapsed=$(( elapsed + poll_interval ))
    done

    if [[ "${healthy}" == "true" ]]; then
        local _cid _rcount
        while IFS= read -r _cid; do
            [[ -z "${_cid}" ]] && continue
            _rcount="$(docker inspect --format '{{.RestartCount}}' "${_cid}" 2>/dev/null || echo 0)"
            if (( _rcount > 0 )); then
                _mv_log warn "Container ${_cid} has RestartCount=${_rcount} — may be crash-looping."
                _mv_log warn "  Check logs: docker logs ${_cid}"
            fi
        done < <(docker compose ps --quiet 2>/dev/null)

        local _rocket_port="${ROCKET_PORT:-8080}"
        local _http_healthy=false _http_try=0 _http_max=6
        _mv_log info "HTTP health probe: http://localhost:${_rocket_port}/alive (up to 60s)"
        while (( _http_try < _http_max )); do
            if curl -sf --max-time 5 "http://localhost:${_rocket_port}/alive" >/dev/null 2>&1; then
                _http_healthy=true
                break
            fi
            (( _http_try++ )) || true
            _mv_log info "  Waiting for HTTP health... (attempt ${_http_try}/${_http_max})"
            sleep 10
        done
        if [[ "${_http_healthy}" == "true" ]]; then
            _mv_log success "HTTP health probe passed: /alive responded successfully."
            _mv_state_write MIGRATION_COMPLETE "true"
            _mv_log success "All containers are running. Migration complete."
            _mv_warn_fstab_entries
            _mv_print_checklist
        else
            _mv_log error "HTTP health probe failed after $(( _http_try * 10 ))s."
            _mv_log error "Containers are running but /alive did not respond on port ${_rocket_port}."
            _mv_log error "Verify manually: curl -v http://localhost:${_rocket_port}/alive"
            _mv_log error "Check logs:      docker compose logs vaultwarden"
            _mv_log error "MIGRATION_COMPLETE not written. Fix the issue then resume or abort."
            return 1
        fi
    else
        _mv_log error "Health check timed out after ${max_wait}s."
        _mv_log error "Current container state:"
        docker compose ps 2>/dev/null || true
        _mv_log error "Recent logs:"
        docker compose logs --tail=50 2>/dev/null || true
        _mv_log error "MIGRATION_COMPLETE not written. Investigate and resume or abort."
        return 1
    fi
}

# ── Post-migration checklist ──────────────────────────────────────────────────
_mv_print_checklist() {
    local renamed_src="${_MV_SOURCE}.pre-migration.${_MV_TIMESTAMP}"
    printf '\n'
    printf '═══════════════════════════════════════════════════════════════\n'
    printf '  Post-Migration Checklist\n'
    printf '═══════════════════════════════════════════════════════════════\n'
    printf '  1. Log in to VaultWarden and verify your vault data is intact.\n'
    printf '  2. Run: docker compose ps  — confirm all services are '\''healthy'\''.\n'
    printf '  3. Run: systemctl status vaultwarden-startup  — confirm unit loads cleanly.\n'
    printf '  4. Test a scheduled backup: sudo ./backup.sh full\n'
    printf '  5. Verify backup path uses new volume: check BACKUP_DIR in .env\n'
    printf '     If BACKUP_DIR was a custom path it was NOT auto-updated — verify manually.\n'
    printf '  6. After a satisfying reboot test, remove the renamed source:\n'
    printf '       sudo rm -rf '\''%s'\''\n' "${renamed_src}"
    printf '  7. (If you added custom services to docker-compose.yml with hardcoded\n'
    printf '     paths) Verify: docker compose config | grep '\''%s'\''\n' "${_MV_SOURCE}"
    printf '     Any remaining references must be updated manually.\n'
    if [[ -n "${_MV_BACKUP_DIR_CUSTOM_WARNING:-}" ]]; then
        printf '  ─────────────────────────────────────────────────────────────────\n'
        printf '  ⚠  ACTION REQUIRED: --yes mode bypassed the BACKUP_DIR confirmation.\n'
        printf '     Custom BACKUP_DIR: %s\n' "${_MV_BACKUP_DIR_CUSTOM_WARNING}"
        printf '     This path was NOT auto-updated. Verify it points to the correct\n'
        printf '     location on the new volume and update .env if needed:\n'
        printf '       nano %s/.env\n' "${PROJECT_ROOT}"
    fi
    printf '═══════════════════════════════════════════════════════════════\n'
    printf '  Migration log: %s\n' "${_MV_LOG_FILE}"
    printf '  .env backup:   %s.pre-migration.%s\n' "${PROJECT_ROOT}/.env" "${_MV_TIMESTAMP}"
    printf '═══════════════════════════════════════════════════════════════\n'
    printf '\n'
}

# ── Status subcommand ─────────────────────────────────────────────────────────
_mv_print_status() {
    if [[ ! -f "${_MV_STATE_FILE}" ]]; then
        log_info "No migration in progress or previously recorded."
        return 0
    fi

    local src tgt device start_ts complete

    src="$(_mv_state_read MV_SOURCE)"
    tgt="$(_mv_state_read MV_TARGET)"
    device="$(_mv_state_read MV_DEVICE)"
    start_ts="$(_mv_state_read MV_START_TS)"
    complete="$(_mv_state_read MIGRATION_COMPLETE)"

    printf '\n'
    printf '  Migration State\n'
    printf '  ───────────────────────────────────────────────\n'
    printf '  %-20s %s\n' "Source:"   "${src:-unknown}"
    printf '  %-20s %s\n' "Target:"   "${tgt:-unknown}"
    printf '  %-20s %s\n' "Device:"   "${device:-none}"
    printf '  %-20s %s\n' "Started:"  \
        "$(date -d "@${start_ts}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "${start_ts}")"
    printf '  %-20s %s\n' "Complete:" "${complete:-no}"
    printf '  ───────────────────────────────────────────────\n'
    printf '\n'

    local -a steps=(
        "STEP_VALIDATE_DONE:Validate pre-flight"
        "STEP_BACKUP_DONE:Backup confirmation"
        "STEP_STOP_DONE:Stop stack"
        "STEP_FORMAT_DONE:Format/mount volume"
        "STEP_RSYNC_DONE:rsync transfer"
        "STEP_VERIFY_DONE:Verify byte count"
        "STEP_SOURCE_RENAMED_DONE:Rename source"
        "STEP_SOURCE_DELETED_DONE:Delete source"
        "STEP_ENV_UPDATED_DONE:Update .env"
        "STEP_DROPIN_UPDATED_DONE:Update systemd drop-ins"
        "STEP_MOUNT_GUARD_DONE:Docker mount guard"
        "STEP_START_DONE:Start stack"
        "STEP_HEALTHCHECK_DONE:Health check"
    )

    local step token label status_str
    for step in "${steps[@]}"; do
        token="${step%%:*}"
        label="${step##*:}"
        if _mv_state_has "${token}"; then
            status_str="✓ done"
        else
            status_str="  pending"
        fi
        printf '  %-14s  %s\n' "${status_str}" "${label}"
    done
    printf '\n'

    if [[ "${complete}" == "true" ]]; then
        log_success "Migration completed successfully."
    else
        log_warn "Migration is incomplete. Resume with:"
        log_warn "  sudo utilities/setup-storage.sh --mode migrate resume"
    fi
}

# ── Abort subcommand ──────────────────────────────────────────────────────────
_mv_do_abort() {
    if [[ ! -f "${_MV_STATE_FILE}" ]]; then
        log_info "No migration state found. Nothing to abort."
        return 0
    fi

    local src complete
    src="$(_mv_state_read MV_SOURCE)"
    complete="$(_mv_state_read MIGRATION_COMPLETE)"

    if [[ "${complete}" == "true" ]]; then
        log_warn "Migration is already marked COMPLETE."
        _mv_confirm "Abort a completed migration? This will attempt to restore the old state."
    fi

    log_warn "Aborting migration. Attempting rollback in reverse order..."

    if _mv_state_has STEP_FORMAT_DONE && ! _mv_state_has STEP_RSYNC_DONE; then
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_warn "  ⚠  DATA NOTICE: Block device was formatted but rsync did not complete."
        log_warn "     Device : $(_mv_state_read MV_DEVICE)"
        log_warn "     Mount  : $(_mv_state_read MV_TARGET)"
        log_warn "  The new volume is formatted but empty. Source data is intact."
        log_warn "  On retry, format will be skipped (mountpoint returns true)."
        log_warn "  rsync will run from the beginning — this is safe."
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi

    if _mv_state_has STEP_START_DONE; then
        log_info "Rollback: stopping stack..."
        stop_services || log_warn "stop_services failed — continuing rollback."
    fi

    if _mv_state_has STEP_ENV_UPDATED_DONE; then
        local env_backup env_cand env_newest_ts=0 env_cand_ts
        env_backup=""
        for env_cand in "${PROJECT_ROOT}"/.env.pre-migration.*; do
            [[ -f "${env_cand}" ]] || continue
            env_cand_ts="$(stat -c '%Y' "${env_cand}" 2>/dev/null || echo 0)"
            if (( env_cand_ts > env_newest_ts )); then
                env_newest_ts="${env_cand_ts}"
                env_backup="${env_cand}"
            fi
        done
        if [[ -n "${env_backup}" && -f "${env_backup}" ]]; then
            cp "${env_backup}" "${PROJECT_ROOT}/.env"
            chmod 0600 "${PROJECT_ROOT}/.env"
            log_success ".env restored from: ${env_backup}"
            load_env_file "${PROJECT_ROOT}/.env"
        else
            log_warn ".env backup not found — manual restoration required."
            log_warn "Keys changed: PROJECT_STATE_DIR, DATA_VOLUME_MOUNT, DATA_VOLUME_DEVICE, BACKUP_DIR"
        fi
    fi

    if _mv_state_has STEP_SOURCE_RENAMED_DONE; then
        local renamed src_cand src_newest_ts=0 src_cand_ts
        renamed=""
        for src_cand in "${src}.pre-migration."*/; do
            [[ -d "${src_cand}" ]] || continue
            src_cand_ts="$(stat -c '%Y' "${src_cand}" 2>/dev/null || echo 0)"
            if (( src_cand_ts > src_newest_ts )); then
                src_newest_ts="${src_cand_ts}"
                renamed="${src_cand%/}"
            fi
        done
        if [[ -n "${renamed}" && -d "${renamed}" ]]; then
            if [[ ! -e "${src}" ]]; then
                mv "${renamed}" "${src}"
                log_success "Source restored: ${renamed} → ${src}"
            else
                log_warn "Cannot restore: ${src} already exists."
                log_warn "Renamed source is at: ${renamed}"
            fi
        else
            log_warn "Renamed source not found — data on target is the only copy."
        fi
    fi

    if _mv_state_has STEP_DROPIN_UPDATED_DONE; then
        local _abort_src _abort_tgt
        _abort_src="$(_mv_state_read MV_SOURCE)"
        _abort_tgt="$(_mv_state_read MV_TARGET)"
        if [[ -n "${_abort_src}" && -n "${_abort_tgt}" ]]; then
            log_info "Rollback: reversing systemd drop-in paths (${_abort_tgt} → ${_abort_src})..."
            _mv_apply_dropin_paths "${_abort_tgt}" "${_abort_src}"
        else
            log_warn "State file missing MV_SOURCE/MV_TARGET — drop-ins not reversed."
            log_warn "To restore them manually, re-run: sudo ./setup.sh systemd"
            systemctl daemon-reload || true
        fi
    fi

    log_info "Rollback: attempting to start stack from restored source..."
    start_services || log_warn "start_services failed — check manually: docker compose up -d"

    _mv_warn_fstab_entries

    if _mv_state_has STEP_FORMAT_DONE; then
        local _abort_tgt
        _abort_tgt="$(_mv_state_read MV_TARGET)"
        if [[ -n "${_abort_tgt}" ]] && mountpoint -q "${_abort_tgt}" 2>/dev/null; then
            log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_warn "  ⚠  MOUNT: The new block volume remains mounted at: ${_abort_tgt}"
            log_warn "  On a true abort this may be unexpected."
            log_warn "  On retry, format will be skipped and rsync will run from scratch."
            log_warn "  To unmount: sudo umount ${_abort_tgt}"
            log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            local _umount_reply
            read -r -p "  Unmount ${_abort_tgt} now? [y/N] " _umount_reply
            if [[ "${_umount_reply}" =~ ^[Yy]$ ]]; then
                umount "${_abort_tgt}" \
                    && log_success "Unmounted ${_abort_tgt}." \
                    || log_warn "umount failed — unmount manually: sudo umount ${_abort_tgt}"
            else
                log_info "Leaving ${_abort_tgt} mounted. Unmount manually when ready."
            fi
        fi
    fi

    _mv_state_clear
    log_success "State file cleared."
    log_warn "Review the rollback above carefully. Some steps may require manual intervention."
    log_warn "Check: docker compose ps"
}

# ── Pipeline orchestrator ─────────────────────────────────────────────────────
_mv_run_step() {
    local token="$1" fn="$2"
    if _mv_state_has "${token}"; then
        _mv_log info "Skipping (already done): ${fn#_mv_step_}"
        return 0
    fi
    "${fn}"
    [[ "${DRY_RUN}" == "true" ]] || _mv_state_write "${token}"
}

_mv_run_pipeline() {
    local resuming=false
    [[ "${1:-}" == "--resume" ]] && resuming=true

    if [[ "${resuming}" == "true" ]]; then
        [[ -f "${_MV_STATE_FILE}" ]] || {
            log_error "No state file found. Cannot resume. Run: sudo utilities/setup-storage.sh --mode migrate run ..."
            exit 1
        }
        _MV_SOURCE="$(_mv_state_read MV_SOURCE)"
        _MV_TARGET="$(_mv_state_read MV_TARGET)"
        _MV_DEVICE="$(_mv_state_read MV_DEVICE)"
        [[ "${_MV_DEVICE}" == "none" ]] && _MV_DEVICE=""
        _MV_SKIP_STACK_STOP="$(_mv_state_read MV_SKIP_STACK_STOP)"
        _MV_DELETE_SOURCE="$(_mv_state_read MV_DELETE_SOURCE)"
        log_info "Resuming migration: ${_MV_SOURCE} → ${_MV_TARGET}"

        log_info "Re-validating prerequisites for resume..."
        local _resume_ok=true
        if [[ ! -d "${_MV_SOURCE}" ]]; then
            if _mv_state_has STEP_SOURCE_RENAMED_DONE; then
                log_info "Resume: source was renamed in step 6 — original path absence is expected."
            else
                log_error "Resume: source directory no longer exists: ${_MV_SOURCE}"
                _resume_ok=false
            fi
        fi
        if [[ -n "${_MV_DEVICE}" ]] && ! mountpoint -q "${_MV_TARGET}" 2>/dev/null; then
            log_error "Resume: target mount point is not mounted: ${_MV_TARGET}"
            log_error "Remount it first, then re-run resume."
            _resume_ok=false
        fi
        if [[ ! -f "${PROJECT_ROOT}/docker-compose.yml" ]]; then
            log_error "Resume: docker-compose.yml not found: ${PROJECT_ROOT}/docker-compose.yml"
            _resume_ok=false
        fi
        [[ "${_resume_ok}" == "true" ]] || {
            log_error "Resume validation failed. Fix the above issues and retry."
            return 1
        }
        log_info "Resume validation passed."
    fi

    _mv_run_step STEP_VALIDATE_DONE       _mv_step_validate
    _mv_run_step STEP_BACKUP_DONE         _mv_step_backup_prompt
    _mv_run_step STEP_STOP_DONE           _mv_step_stop
    _mv_run_step STEP_FORMAT_DONE         _mv_step_format
    _mv_run_step STEP_RSYNC_DONE          _mv_step_rsync
    _mv_run_step STEP_VERIFY_DONE         _mv_step_verify
    _mv_run_step STEP_SOURCE_RENAMED_DONE _mv_step_rename_source
    if [[ "${_MV_DELETE_SOURCE}" == "true" ]]; then
        _mv_run_step STEP_SOURCE_DELETED_DONE _mv_step_delete_source
    fi
    _mv_run_step STEP_ENV_UPDATED_DONE    _mv_step_update_env
    _mv_run_step STEP_DROPIN_UPDATED_DONE _mv_step_update_dropin
    _mv_run_step STEP_MOUNT_GUARD_DONE    _mv_step_mount_guard
    _mv_run_step STEP_START_DONE          _mv_step_start
    _mv_run_step STEP_HEALTHCHECK_DONE    _mv_step_healthcheck
}

# ═══════════════════════════════════════════════════════════════════════════════
# SETUP MODE — setup_directories (from setup.sh:800-923)
# ═══════════════════════════════════════════════════════════════════════════════

setup_directories() {
    if [[ "${DRY_RUN}" == "true" ]]; then log_info "[DRY RUN] Would setup directories"; return 0; fi

    # If a separate data volume is configured, assert it is mounted and valid
    # before we create any subdirectories inside it. This prevents accidentally
    # writing the directory skeleton onto the boot volume if the mount failed.
    export DATA_VOLUME_DEVICE="${DATA_VOLUME_DEVICE:-}"
    export DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-/mnt/vw-data}"
    # Align PROJECT_STATE_DIR with the storage mode so the consistency check
    # inside require_project_state_ready passes. In boot-only mode this is a no-op.
    if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then
        export PROJECT_STATE_DIR="${DATA_VOLUME_MOUNT}"
    else
        export PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    fi
    require_project_state_ready || return 1

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n "$real_user")

    local secrets_dirs=("secrets" "secrets/keys" "secrets/.docker_secrets")
    for dir in "${secrets_dirs[@]}"; do
        ensure_dir "$dir" 700 || return 1
        chown "$real_user:$real_group" "$dir" || return 1
    done

    local puid; puid=$(id -u "$real_user")
    local pgid; pgid=$(id -g "$real_user")
    local project_state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"

    # Create the backup directory tree that backup.sh and restore.sh require.
    local backup_base_dir="${BACKUP_DIR:-${project_state_dir}/backups}"
    if ! mkdir -p "${backup_base_dir}"/{db,full,emergency}; then
        log_error "Failed to create backup directories under ${backup_base_dir}"
        return 1
    fi
    chmod 750 "${backup_base_dir}" "${backup_base_dir}"/{db,full,emergency} || return 1
    chown -R "${puid}:${pgid}" "${backup_base_dir}" || return 1
    log_info "Backup directories created: ${backup_base_dir}/{db,full,emergency}"

    if ! mkdir -p "${project_state_dir}"/{data,logs/{vaultwarden,caddy,postfix},caddy/{data,config}}; then
        return 1
    fi

    for _dir in data logs caddy backups; do
    [[ -d "${project_state_dir}/${_dir}" ]] && \
        chown -R "${puid}:${pgid}" "${project_state_dir}/${_dir}" || return 1
    done

    find "${project_state_dir}" -type d -exec chmod 750 {} + 2>/dev/null || return 1
    find "${project_state_dir}" -type f -exec chmod 640 {} + 2>/dev/null || true

    # Caddy runs as root inside its container and writes
    # access logs to ${project_state_dir}/logs/caddy/access.log via a bind-mount.
    # The broad 'find chmod 750' above sets this directory to 750:
    #   owner=PUID  group=PGID  other=---
    # On OCI Compute, Docker maps container UID 0 to an unprivileged host UID
    # (userns-remap or equivalent hypervisor isolation). Container root is NOT
    # host root. Any chmod/chown attempted inside the container on this
    # bind-mount fails with EPERM. The definitive fix: set 755 here, running
    # as real host root (setup.sh is always invoked via 'sudo ./setup.sh').
    # 755 rationale: Caddy's container UID falls into 'other' (it is neither
    # PUID nor PGID). 'other' needs at least r-x (5) to enter the directory
    # and rw- (6) on the log file itself. 755 grants r-x to 'other', and
    # Caddy creates access.log with mode 0644 (rw-r--r--), satisfying both.
    chmod 755 "${project_state_dir}/logs/caddy" || return 1
    log_info "Set ${project_state_dir}/logs/caddy to 755 (Caddy runs as root in container)"

    # Caddy's TLS storage directories must be owned by root:root and
    # traversable (755) so Caddy can write certificate material during the
    # first ACME negotiation. 700 is rwx------: only the exact owning UID can
    # enter. The remapped container UID is not host root (0), so 700 blocks
    # traversal with EACCES. 755 grants r-x to all, which is sufficient for a
    # non-world-writable storage directory containing private keys (the keys
    # themselves are created by Caddy with mode 0600).
    local caddy_data_dir="${project_state_dir}/caddy/data"
    local caddy_config_dir="${project_state_dir}/caddy/config"

    mkdir -p \
        "${caddy_data_dir}/caddy/certificates" \
        "${caddy_data_dir}/caddy/locks" \
        "${caddy_data_dir}/caddy/ocsp"

    chown -R root:root "${caddy_data_dir}" "${caddy_config_dir}" || return 1
    find "${caddy_data_dir}" "${caddy_config_dir}" -type d -exec chmod 755 {} + || return 1
    find "${caddy_data_dir}" "${caddy_config_dir}" -type f -exec chmod 600 {} + 2>/dev/null || true

    log_info "Set ${caddy_data_dir} and ${caddy_config_dir} to root:root 755 (Caddy ACME storage)"
    log_info "Pre-created Caddy ACME subtree: certificates/ locks/ ocsp/"

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# MODE HANDLERS
# ═══════════════════════════════════════════════════════════════════════════════

_mode_setup() {
    log_info "Mode: setup — provisioning data volume and directories"

    # Propagate common flags into env vars that lib functions read
    export DATA_VOLUME_DEVICE="${_SS_DATA_DEVICE}"
    export DATA_VOLUME_MOUNT="${_SS_DATA_MOUNT}"

    setup_data_volume || return 1
    # Install a Docker systemd drop-in that delays Docker start until the
    # data volume is mounted. No-op when DATA_VOLUME_DEVICE is unset.
    install_docker_mount_guard || log_warn "Docker mount guard setup had a non-fatal issue"
    setup_directories || return 1

    log_success "Storage setup complete."
}

_mode_verify() {
    log_info "Verifying storage layout and permissions..."
    require_project_state_ready || return 1

    local project_state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    local errors=0
    for dir in data logs caddy backups; do
        if [[ ! -d "${project_state_dir}/${dir}" ]]; then
            log_warn "Missing directory: ${project_state_dir}/${dir}"
            (( errors++ )) || true
        else
            log_success "OK: ${project_state_dir}/${dir}"
        fi
    done
    (( errors == 0 )) && log_success "Storage verification passed" \
        || log_warn "Storage verification: ${errors} issue(s) found"
    return 0
}

_mode_migrate() {
    # Reset start time to when migrate mode actually begins
    _MV_START_TIME="${SECONDS}"

    _mv_require_root "${_SS_MIGRATE_ARGS[@]+"${_SS_MIGRATE_ARGS[@]}"}"
    _mv_parse_args "${_SS_MIGRATE_ARGS[@]+"${_SS_MIGRATE_ARGS[@]}"}"
    _mv_open_log

    # Override ERR and EXIT traps for migrate mode
    trap '_mv_on_err $? $LINENO' ERR
    trap '_ss_cleanup; _mv_cleanup' EXIT

    _mv_acquire_lock

    case "${_MV_SUBCOMMAND}" in
        run)
            _mv_select_device
            _mv_prompt_target
            _mv_print_preflight_summary
            _mv_run_pipeline
            ;;
        resume)
            _mv_run_pipeline --resume
            ;;
        status)
            _mv_print_status
            ;;
        abort)
            _mv_do_abort
            ;;
        verify)
            if [[ -f "${_MV_STATE_FILE}" ]]; then
                local _sv _tv
                _sv="$(_mv_state_read MV_SOURCE)"
                _tv="$(_mv_state_read MV_TARGET)"
                if [[ -n "${_sv}" && -n "${_tv}" ]]; then
                    _MV_SOURCE="${_sv}"
                    _MV_TARGET="${_tv}"
                    log_info "verify: using paths from state file — source=${_MV_SOURCE} target=${_MV_TARGET}"
                fi
                # After step 6 (rename_source) the original source path no longer
                # exists. Discover the renamed directory and use it for the
                # byte-count comparison so verify works after a complete migration.
                if _mv_state_has STEP_SOURCE_RENAMED_DONE && [[ ! -d "${_MV_SOURCE}" ]]; then
                    local _renamed_src="" _cand _cand_ts _newest_ts=0
                    for _cand in "${_MV_SOURCE}.pre-migration."*/; do
                        [[ -d "${_cand}" ]] || continue
                        _cand_ts="$(stat -c '%Y' "${_cand}" 2>/dev/null || echo 0)"
                        if (( _cand_ts > _newest_ts )); then
                            _newest_ts="${_cand_ts}"
                            _renamed_src="${_cand%/}"
                        fi
                    done
                    if [[ -n "${_renamed_src}" ]]; then
                        log_info "verify: source was renamed (step 6) — comparing renamed source: ${_renamed_src}"
                        _MV_SOURCE="${_renamed_src}"
                    else
                        log_error "verify: STEP_SOURCE_RENAMED_DONE is set but no renamed source found matching '${_MV_SOURCE}.pre-migration.*'"
                        log_error "The renamed source may have been deleted. Cannot run byte-count comparison."
                        exit 1
                    fi
                fi
            fi
            _mv_step_verify
            ;;
        *)
            _mv_usage
            exit 1
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════════
# USAGE
# ═══════════════════════════════════════════════════════════════════════════════

_ss_usage() {
cat << 'EOF'
VaultWarden-OCI Storage Setup and Migration

USAGE:
  sudo utilities/setup-storage.sh [--mode setup|migrate|verify] [OPTIONS]

MODES:
  setup    Create and configure storage directories (default)
  migrate  Migrate from boot volume to data volume (interactive)
  verify   Re-check layout and permissions only (no changes, safe for cron)

FLAGS (setup / verify):
  --mode MODE           Mode to run: setup|migrate|verify (default: setup)
  --data-device DEV     Block device for data volume (e.g. /dev/sdb)
  --data-mount PATH     Mount point for data volume (default: /mnt/vw-data)
  --auto                Non-interactive mode
  --dry-run             Preview actions without executing
  --force               Skip confirmations
  --help, -h            Show this help

MIGRATE MODE:
  sudo utilities/setup-storage.sh --mode migrate [subcommand] [OPTIONS]
  Run with --mode migrate --help for full migrate usage.

EXAMPLES:
  # Boot-only setup (no separate data volume)
  sudo utilities/setup-storage.sh

  # Setup with a dedicated data volume
  sudo utilities/setup-storage.sh \
    --data-device /dev/sdb \
    --data-mount /mnt/vw-data

  # Dry run setup
  sudo utilities/setup-storage.sh --dry-run

  # Verify current layout (safe for cron)
  sudo utilities/setup-storage.sh --mode verify

  # Interactive migration (prompts for device and mount point)
  sudo utilities/setup-storage.sh --mode migrate run

  # Non-interactive migration
  sudo utilities/setup-storage.sh --mode migrate run \
    --source /var/lib/vaultwarden \
    --target /mnt/vw-data \
    --device /dev/sdb \
    --yes

  # Check migration status
  sudo utilities/setup-storage.sh --mode migrate status
EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# ARGUMENT PARSER
# ═══════════════════════════════════════════════════════════════════════════════

_parse_outer_args() {
    # First pass: extract --mode and --help
    local -a remaining=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                _SS_MODE="$2"
                shift 2
                ;;
            --help|-h)
                _ss_usage
                exit 0
                ;;
            *)
                remaining+=("$1")
                shift
                ;;
        esac
    done

    case "${_SS_MODE}" in
        setup|verify|migrate) ;;
        *)
            log_error "Unknown mode: ${_SS_MODE}. Valid modes: setup|migrate|verify"
            _ss_usage
            exit 1
            ;;
    esac

    # For migrate mode: forward all remaining args to _mode_migrate
    if [[ "${_SS_MODE}" == "migrate" ]]; then
        _SS_MIGRATE_ARGS=("${remaining[@]+"${remaining[@]}"}")
        return 0
    fi

    # For setup / verify modes: parse remaining flags
    set -- "${remaining[@]+"${remaining[@]}"}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --data-device)
                _SS_DATA_DEVICE="$2"
                shift 2
                ;;
            --data-mount)
                _SS_DATA_MOUNT="$2"
                shift 2
                ;;
            --auto)
                _SS_AUTO=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                _SS_FORCE=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                _ss_usage
                exit 1
                ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    _parse_outer_args "$@"

    (( EUID == 0 )) || {
        log_error "This script must be run as root: sudo utilities/setup-storage.sh $*"
        exit 1
    }

    TMP_WORKDIR="$(mktemp -d -p "${PROJECT_ROOT}" vw_storage_tmp.XXXXXXXXXX)"

    case "${_SS_MODE}" in
        setup)   _mode_setup   ;;
        verify)  _mode_verify  ;;
        migrate) _mode_migrate ;;
        *)
            log_error "Unknown mode: ${_SS_MODE}"
            _ss_usage
            exit 1
            ;;
    esac
}

main "$@"
