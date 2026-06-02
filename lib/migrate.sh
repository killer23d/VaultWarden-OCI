#!/usr/bin/env bash
# lib/migrate.sh — VaultWarden-OCI migration pipeline.
# Sourced by setup-storage.sh; not invoked directly.
[[ -n "${_MV_MIGRATE_LIB_LOADED:-}" ]] && return 0
readonly _MV_MIGRATE_LIB_LOADED=1

# ── Readonly globals ──────────────────────────────────────────────────────────
_MV_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly _MV_TIMESTAMP
readonly _MV_LOCK_FILE="/run/lock/vaultwarden-migrate.lock"
readonly _MV_LOG_MAX_BYTES=$(( 10 * 1024 * 1024 ))   # 10 MiB — rotate beyond this
readonly _MV_VERIFY_TOLERANCE_PCT=1                    # allow ≤1% size delta post-rsync

# Keep the state file in PROJECT_ROOT because PROJECT_STATE_DIR may change during migration.
readonly _MV_STATE_FILE="${PROJECT_ROOT}/.migrate-volume.state"

# Exclude paths that must not be copied to the target.
readonly -a _MV_RSYNC_EXCLUDES=(
    "lost+found/"       # ext4 fsck directory — permission errors on some kernels
    ".vw-data-volume"   # sentinel written by setup_data_volume(); never overwrite target's
    "*.sock"            # dead runtime sockets confuse service startup diagnostics
    "*.pid"             # PID files are always stale after stack stop
    "*.sqlite3-wal"     # SQLite WAL — a non-empty WAL after stack stop indicates a hot DB
    "*.sqlite3-shm"     # SQLite shared-memory file — always accompanies the WAL
)

# Systemd drop-in units whose ReadWritePaths= must be updated after migration.
# Keep this list in sync with _VW_DROPIN_UNITS in setup.sh.
readonly -a _MV_DROPIN_UNITS=(
    "vaultwarden-startup.service"
    "vaultwarden-backup.service"
    "vaultwarden-maintenance.service"
    "vaultwarden-restore.service"
)

# ── Mutable globals ───────────────────────────────────────────────────────────
_MV_SUBCOMMAND="run"
_MV_SOURCE=""
_MV_TARGET=""
_MV_DEVICE=""
_MV_DIRECTION="boot-to-block"   # migration direction; override with --direction
_MV_CURRENT_STEP=""             # tracks active pipeline step for error messages
_MV_SKIP_STACK_STOP=false
_MV_DELETE_SOURCE=false
_MV_FORCE=false
_MV_YES=false
_MV_LOG_FILE=""
_MV_BACKUP_DIR_CUSTOM_WARNING=""
# Mutable copy of the original run timestamp; updated from state on resume.
_MV_RUN_TIMESTAMP="${_MV_TIMESTAMP}"

_MV_START_TIME="${SECONDS}"   # bash built-in — seconds since shell started

_MV_LOCK_FD=""

# ── Utility helpers ───────────────────────────────────────────────────────────
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

_mv_acquire_lock() {
    local lock_fd
    mkdir -p "$(dirname "${_MV_LOCK_FILE}")"
    : >> "${_MV_LOCK_FILE}"
    chmod 0600 "${_MV_LOCK_FILE}"
    exec {lock_fd}>"${_MV_LOCK_FILE}"
    flock -n "${lock_fd}" || {
        log_error "Another migration is already running (lock held: ${_MV_LOCK_FILE})."
        log_error "Run: sudo utilities/setup-storage.sh --mode migrate status"
        log_error "If you are sure no migration is active, remove the lock file and retry:"
        log_error "  sudo rm -f ${_MV_LOCK_FILE}"
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

_mv_cleanup() {
    _mv_release_lock
    _mv_log info "Elapsed: $(_mv_elapsed)"
}

_mv_require_root() {
    [[ "${EUID}" -eq 0 ]] || {
        log_error "This script must be run as root: sudo utilities/setup-storage.sh --mode migrate $*"
        exit 1
    }
}

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

_mv_on_err() {
    local rc="$1" lineno="$2"
    local _step_ctx=""
    [[ -n "${_MV_CURRENT_STEP:-}" ]] && _step_ctx=" during [${_MV_CURRENT_STEP}] step"
    _mv_log error "Unexpected error${_step_ctx} at line ${lineno} (exit ${rc}). Migration halted."
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

_mv_warn_fstab_entries() {
    # Scans /etc/fstab for entries that reference _MV_SOURCE (the old data
    # path). These could auto-mount the old location at boot and shadow the
    # new mount point. Entries for _MV_TARGET are intentionally excluded: the
    # target's fstab entry is the correct, required entry after a block-device
    # migration and must NOT be removed.
    [[ -f /etc/fstab ]] || return 0
    [[ -n "${_MV_SOURCE:-}" ]] || return 0

    local line found=false
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]]  && continue
        if [[ "${line}" == *"${_MV_SOURCE}"* ]]; then
            if [[ "${found}" == "false" ]]; then
                _mv_log warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                _mv_log warn "  ⚠  FSTAB WARNING: /etc/fstab still references the old source path"
                found=true
            fi
            _mv_log warn "    ${line}"
        fi
    done < /etc/fstab

    if [[ "${found}" == "true" ]]; then
        _mv_log warn "  These entries may auto-mount the old source location at boot."
        _mv_log warn "  Review them and remove any that are no longer needed. Example:"
        local _esc_src="${_MV_SOURCE//\\/\\\\}"
        _esc_src="${_esc_src//./\\.}"
        _esc_src="${_esc_src//|/\\|}"
        _mv_log warn "    sed -i '\\|${_esc_src}|d' /etc/fstab"
        _mv_log warn "  (Verify the resulting fstab is correct before rebooting.)"
        _mv_log warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi
}

# ── Sentinel-mount probe ─────────────────────────────────────────────────────
_mv_find_sentinel_mount() {
    # Scans all active mount points for a VaultWarden data-volume sentinel
    # (.vw-data-volume). Prints the unique sentinel mount path, or an empty
    # string if zero or more than one sentinel volume is found (ambiguous).
    local mnt found="" count=0
    while IFS= read -r mnt; do
        [[ -z "${mnt}" ]] && continue
        [[ "${mnt}" == "/" ]] && continue
        [[ -f "${mnt}/.vw-data-volume" ]] || continue
        (( count++ )) || true
        found="${mnt}"
    done < <(findmnt -rn -o TARGET 2>/dev/null)
    (( count == 1 )) && printf '%s' "${found}" || printf ''
}

# ── Interactive block device selector ────────────────────────────────────────
_mv_select_device() {
    # Presents a numbered list of block devices and partitions using lsblk.
    # For boot-to-block: marks boot devices [boot] and warns against selecting them.
    # For block-to-boot: shows only volumes bearing the VaultWarden sentinel,
    #   labelled [vaultwarden-data]; auto-populates _MV_SOURCE after selection.
    # Skips if --device was already provided, or subcommand is not 'run'.
    # For boot-to-block only: also skips when --target is set (dir-to-dir mode).

    [[ -n "${_MV_DEVICE:-}" ]] && return 0
    [[ "${_MV_SUBCOMMAND}" == "run" ]] || return 0
    # dir-to-dir migration needs no device, but block-to-boot always needs one.
    [[ -n "${_MV_TARGET:-}" && "${_MV_DIRECTION}" == "boot-to-block" ]] && return 0

    log_info "Detecting block devices using lsblk..."
    printf '\n'

    local -a dev_names dev_sizes dev_mounts dev_types
    local name size mount type

    while IFS=' ' read -r name size mount type; do
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

    # Build the filtered display list.
    # block-to-boot: only volumes with a VaultWarden sentinel (.vw-data-volume).
    # boot-to-block: all devices (existing behaviour).
    local -a display_indices=()
    local _di
    for (( _di=0; _di<${#dev_names[@]}; _di++ )); do
        if [[ "${_MV_DIRECTION}" == "block-to-boot" ]]; then
            local _mnt="${dev_mounts[$_di]:-}"
            [[ -n "${_mnt}" && "${_mnt}" != "-" \
               && -f "${_mnt}/.vw-data-volume" ]] \
                && display_indices+=( "$_di" )
        else
            display_indices+=( "$_di" )
        fi
    done

    if (( ${#display_indices[@]} == 0 )); then
        if [[ "${_MV_DIRECTION}" == "block-to-boot" ]]; then
            log_error "No VaultWarden data volumes found (no mounted volume with .vw-data-volume sentinel)."
            log_error "Ensure the block data volume is mounted and was provisioned by setup.sh."
            log_error "As a workaround, specify the device explicitly: --device /dev/sda"
        else
            log_error "No block devices found via lsblk. Ensure the target disk is attached."
        fi
        return 1
    fi

    local _idx tags mount_display sentinel_tag
    local _dn=0
    local -a display_map=()
    for _idx in "${display_indices[@]}"; do
        tags=""
        sentinel_tag=""
        if [[ "${dev_mounts[$_idx]}" == "/" ]] \
                || { [[ -n "${root_dev}" ]] \
                     && [[ "${#dev_names[$_idx]}" -ge "${#root_dev}" ]] \
                     && [[ "${dev_names[$_idx]:0:${#root_dev}}" == "${root_dev}" ]]; } \
                || [[ -n "${root_source}" && "${root_source}" == "${dev_names[$_idx]}" ]]; then
            tags="${tags} [boot]"
        fi
        if [[ "${dev_types[$_idx]}" == "part" ]]; then
            tags="${tags} [part]"
        fi
        local _mnt_check="${dev_mounts[$_idx]:-}"
        if [[ -n "${_mnt_check}" && "${_mnt_check}" != "-" \
                && -f "${_mnt_check}/.vw-data-volume" ]]; then
            sentinel_tag=" [vaultwarden-data]"
        fi

        mount_display="${dev_mounts[$_idx]:-  -}"
        printf '  %d) %-14s  size: %-8s  mount: %-20s%s%s\n' \
            $(( _dn + 1 )) \
            "${dev_names[$_idx]}" \
            "${dev_sizes[$_idx]}" \
            "${mount_display}" \
            "${tags}" \
            "${sentinel_tag}"
        display_map+=( "$_idx" )
        (( _dn++ )) || true
    done

    printf '\n'
    if [[ "${_MV_DIRECTION}" == "block-to-boot" ]]; then
        printf '  Note: Only volumes with a VaultWarden data sentinel are shown above.\n'
        printf '  Select the volume containing the data you want to move back to the boot disk.\n'
        printf '\n'
        log_warn "Select SOURCE block device to migrate FROM (the data volume to vacate):"
    else
        printf '  Note: Cloud providers often attach volumes as a partition (e.g. /dev/sdb1)\n'
        printf '  rather than the whole disk (/dev/sdb). Both are listed above — select\n'
        printf '  whichever device path your cloud provider assigned to the new volume.\n'
        printf '\n'
        log_warn "Select TARGET block device for migration (DO NOT choose [boot]):"
    fi

    local choice
    while true; do
        read -r -p "  Device number [1-${#display_map[@]}]: " choice
        if [[ "${choice}" =~ ^[0-9]+$ ]] \
                && (( choice >= 1 && choice <= ${#display_map[@]} )); then
            local _real_idx="${display_map[$(( choice - 1 ))]}"
            _MV_DEVICE="${dev_names[${_real_idx}]}"
            # Guard: prevent selecting the boot device in boot-to-block mode.
            if [[ "${_MV_DIRECTION}" != "block-to-boot" ]]; then
                if [[ "${dev_mounts[${_real_idx}]}" == "/" ]] \
                        || { [[ -n "${root_dev}" ]] \
                             && [[ "${#_MV_DEVICE}" -ge "${#root_dev}" ]] \
                             && [[ "${_MV_DEVICE:0:${#root_dev}}" == "${root_dev}" ]]; } \
                        || [[ -n "${root_source}" && "${root_source}" == "${_MV_DEVICE}" ]]; then
                    log_error "You selected the boot device. Aborting to prevent data loss."
                    exit 1
                fi
            fi
            # block-to-boot: auto-populate _MV_SOURCE from the device's current mount.
            if [[ "${_MV_DIRECTION}" == "block-to-boot" && -z "${_MV_SOURCE:-}" ]]; then
                _MV_SOURCE="${dev_mounts[${_real_idx}]}"
                log_info "Source (block volume mount): ${_MV_SOURCE}"
            fi
            break
        fi
        log_warn "Invalid selection. Enter a number between 1 and ${#display_map[@]}."
    done

    printf '\n'
    if [[ "${_MV_DIRECTION}" == "block-to-boot" ]]; then
        log_info "Selected source device: ${_MV_DEVICE} (mounted at ${_MV_SOURCE:-unknown})"
    else
        log_info "Selected target device: ${_MV_DEVICE}"
    fi
}

_mv_prompt_target() {
    [[ -n "${_MV_TARGET:-}" ]] && return 0
    [[ "${_MV_SUBCOMMAND}" == "run" ]] || return 0

    local default_mount reply
    if [[ "${_MV_DIRECTION}" == "block-to-boot" ]]; then
        default_mount="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}"
    else
        default_mount="${DATA_VOLUME_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}"
    fi

    printf '\n'
    read -r -p "  Enter target path [${default_mount}]: " reply
    _MV_TARGET="${reply:-${default_mount}}"
    _MV_TARGET="$(realpath -m "${_MV_TARGET}")"
    log_info "Using target path: ${_MV_TARGET}"
    printf '\n'
}

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

_mv_check_stale_backup() {
    local backup_base_dir newest newest_ts now_ts age_hours

    backup_base_dir="${BACKUP_DIR:-${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}/backups}"

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

_mv_set_env_var() {
    local key="$1" value="$2"
    local env_file="${PROJECT_ROOT}/.env"
    local tmp escaped_value

    if [[ "${DRY_RUN}" == "true" ]]; then
        _mv_log info "[DRY RUN] would: set: ${key}=${value}"
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
  --target  <path>   Destination path  (prompted interactively if omitted)
  --device  <dev>    Block device (e.g. /dev/sdb)
                     Prompted interactively via lsblk if omitted.
                     Omit entirely for directory-to-directory migration.
  --direction <dir>  Migration direction (default: boot-to-block):
                     boot-to-block  — move data from boot volume to a dedicated
                                      block device (forward migration).
                     block-to-boot  — reverse: move data from block device back
                                      to the boot volume (e.g. before detaching
                                      the disk for maintenance or replacement).
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

  # Reverse migration: move data from block volume back to boot volume
  sudo utilities/setup-storage.sh --mode migrate run \
    --direction block-to-boot \
    --target /var/lib/vaultwarden \
    --device /dev/sdb

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

    if [[ $# -gt 0 && "${1}" != --* ]]; then
        _MV_SUBCOMMAND="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source)
                _MV_SOURCE="$(realpath -m "$2")"
                shift 2
                ;;
            --target)
                _MV_TARGET="$(realpath -m "$2")"
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
            --direction)
                case "$2" in
                    boot-to-block|block-to-boot)
                        _MV_DIRECTION="$2"
                        ;;
                    *)
                        log_error "Unknown --direction value: '$2'"
                        log_error "Valid values: boot-to-block (default) | block-to-boot"
                        exit 1
                        ;;
                esac
                shift 2
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

    if [[ -z "${_MV_SOURCE}" ]]; then
        if [[ "${_MV_DIRECTION}" == "block-to-boot" ]]; then
            # For block-to-boot, source is the block volume mount point.
            # If --device was supplied without --source, auto-detect the current mount.
            if [[ -n "${_MV_DEVICE}" ]]; then
                local _detected_src
                _detected_src="$(findmnt -n -o TARGET --source "${_MV_DEVICE}" 2>/dev/null || true)"
                [[ -n "${_detected_src}" ]] && _MV_SOURCE="${_detected_src}"
            fi
            # If still unresolved, _mv_select_device will populate _MV_SOURCE interactively.
        else
            _MV_SOURCE="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}"
        fi
    fi

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
            ;;
        *)
            log_error "Unknown subcommand: ${_MV_SUBCOMMAND}"
            _mv_usage
            exit 1
            ;;
    esac

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

    # block-to-boot: source must be a mounted VaultWarden data volume.
    if [[ "${_MV_DIRECTION}" == "block-to-boot" ]]; then
        if ! mountpoint -q "${_MV_SOURCE}" 2>/dev/null; then
            _mv_log error "block-to-boot: '${_MV_SOURCE}' is not a mounted filesystem."
            _mv_log error "Ensure the block data volume is mounted before running this migration."
            _mv_log error "  sudo mount ${_MV_SOURCE}"
            return 1
        fi
        if [[ ! -f "${_MV_SOURCE}/.vw-data-volume" ]]; then
            _mv_log error "block-to-boot: VaultWarden data-volume sentinel missing at:"
            _mv_log error "  ${_MV_SOURCE}/.vw-data-volume"
            _mv_log error "The source volume cannot be positively identified as a VaultWarden"
            _mv_log error "data volume. If this IS the correct volume, create the sentinel:"
            _mv_log error "  sudo touch ${_MV_SOURCE}/.vw-data-volume"
            return 1
        fi
    fi

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

    if pgrep -x rsync >/dev/null 2>&1 \
            && find /proc/*/fd -lname "${_MV_SOURCE}/*" -print0 2>/dev/null \
               | grep -qzl ''; then
        _mv_log error "An rsync process has open file descriptors in ${_MV_SOURCE}."
        _mv_log error "Wait for it to finish before migrating."
        return 1
    fi

    if [[ -n "${_MV_DEVICE}" ]]; then
        [[ -b "${_MV_DEVICE}" ]] || {
            _mv_log error "'${_MV_DEVICE}' is not a valid block device."
            _mv_log error "Verify the device is attached: lsblk | grep ${_MV_DEVICE##*/}"
            _mv_log error "If the device path looks wrong, this may be a script bug — please"
            _mv_log error "report it. As a workaround, pass the device explicitly: --device /dev/sda"
            return 1
        }
        local dev_mount
        dev_mount="$(findmnt -n -o TARGET --source "${_MV_DEVICE}" 2>/dev/null || true)"
        # For boot-to-block: the target device must not already be mounted elsewhere.
        # For block-to-boot: the device is the source mount — being mounted is expected.
        if [[ "${_MV_DIRECTION}" == "boot-to-block" ]]; then
            if [[ -n "${dev_mount}" && "${dev_mount}" != "${_MV_TARGET}" ]]; then
                _mv_log error "Device ${_MV_DEVICE} is already mounted at: ${dev_mount}"
                _mv_log error "Unmount it first or omit --device if the target is already mounted."
                return 1
            fi
        fi
    fi

    # Disk-space check: for block-to-boot and dir-to-dir, run now.
    # For boot-to-block with a new device, defer until after format and mount.
    if [[ "${_MV_DIRECTION}" == "block-to-boot" ]] || [[ -z "${_MV_DEVICE}" ]]; then
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
            if [[ "${DRY_RUN}" == "true" ]]; then
                _mv_log info "[DRY RUN] would: require interactive 'LIVE' confirmation (live stack detected)"
            else
                _mv_log warn "WARNING: ${running_containers} VaultWarden container(s) are currently running."
                _mv_log warn "Migrating a live stack risks SQLite WAL corruption."
                _mv_log warn "Data integrity cannot be guaranteed if the database is actively written."
                _mv_confirm_by_typing \
                    "You are about to migrate a LIVE stack." \
                    "LIVE"
            fi
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
        _mv_state_write MV_DIRECTION        "${_MV_DIRECTION}"
        _mv_state_write MV_START_TS         "$(date +%s)"
        _mv_state_write MV_LOG_FILE         "${_MV_LOG_FILE}"
        _mv_state_write MV_SKIP_STACK_STOP  "${_MV_SKIP_STACK_STOP}"
        _mv_state_write MV_DELETE_SOURCE    "${_MV_DELETE_SOURCE}"
    fi

    _mv_log success "Pre-flight validation passed."
}

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

_mv_step_format() {
    _mv_log info "── format ────────────────────────────────────────────────────────"

    if [[ "${_MV_DIRECTION}" == "block-to-boot" ]]; then
        _mv_log info "block-to-boot migration: no format step required — skipping."
        return 0
    fi

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

    local rsync_rc=0
    rsync "${rsync_flags[@]}" "${_MV_SOURCE%/}/" "${_MV_TARGET}" || rsync_rc=$?

    if (( rsync_rc == 23 )); then
        # Exit code 23 means "some files/attrs were not transferred" (partial
        # transfer). This is expected when --delete-excluded tries to remove the
        # immutable .vw-data-volume sentinel on the target: the kernel returns
        # EPERM and rsync records the failure. The sentinel is intentionally
        # left in place — this is safe and the transfer is otherwise complete.
        _mv_log warn "rsync exited with code 23 (partial transfer). The data-volume"
        _mv_log warn "marker file (.vw-data-volume) is protected and cannot be removed —"
        _mv_log warn "this is expected and safe. Continuing."
    elif (( rsync_rc != 0 )); then
        _mv_log error "rsync failed with exit code ${rsync_rc}. Investigate the output above."
        _mv_log error "Resume the migration once resolved: sudo utilities/setup-storage.sh --mode migrate resume"
        return 1
    fi

    _mv_log success "rsync transfer complete."
}

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
    # Pass the same excludes used during transfer so intentionally excluded
    # files (WAL, PID, sock) do not generate false-positive >f mismatches.
    local -a _chk_flags=(--archive --checksum --dry-run --itemize-changes)
    local _chk_excl
    for _chk_excl in "${_MV_RSYNC_EXCLUDES[@]}"; do
        _chk_flags+=("--exclude=${_chk_excl}")
    done
    _chk_out="$(rsync "${_chk_flags[@]}" \
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

_mv_step_rename_source() {
    _mv_log info "── rename_source ──────────────────────────────────────────────────"

    local renamed="${_MV_SOURCE}.pre-migration.${_MV_RUN_TIMESTAMP}"

    if mountpoint -q "${_MV_SOURCE}" 2>/dev/null; then
        if [[ "${_MV_DIRECTION}" == "block-to-boot" ]]; then
            # Source is the block volume mount root — renaming it is not possible.
            # Best practice: skip rename and emit a clear warning instead.
            _mv_log warn "Source '${_MV_SOURCE}' is the block volume mount root — rename skipped."
            _mv_log warn "After verifying the migration and rebooting, you can safely unmount"
            _mv_log warn "and detach the data disk:"
            _mv_log warn "  sudo umount ${_MV_SOURCE}"
        else
            _mv_log warn "Source ${_MV_SOURCE} is a mount point — rename not meaningful."
            _mv_log warn "After verifying the migration, unmount and detach the old volume manually."
        fi
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        _mv_log info "[DRY RUN] would: mv ${_MV_SOURCE} ${renamed}"
    else
        mv "${_MV_SOURCE}" "${renamed}"
        _mv_log success "Source renamed: ${_MV_SOURCE} → ${renamed}"
    fi
}

_mv_step_delete_source() {
    _mv_log info "── delete_source ─────────────────────────────────────────────────"

    local _nullglob_was_off=false
    shopt -q nullglob || _nullglob_was_off=true
    shopt -s nullglob

    local candidate newest_ts=0 candidate_ts cand_renamed=""
    for candidate in "${_MV_SOURCE}.pre-migration."*/; do
        [[ -d "${candidate}" ]] || continue
        candidate_ts="$(stat -c '%Y' "${candidate}" 2>/dev/null || echo 0)"
        if (( candidate_ts > newest_ts )); then
            newest_ts="${candidate_ts}"
            cand_renamed="${candidate%/}"
        fi
    done

    [[ "${_nullglob_was_off}" == "true" ]] && shopt -u nullglob

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

_mv_prune_env_backups() {
    # Prune older .env.pre-migration.* backups — keep only the newest one.
    local env_file="${PROJECT_ROOT}/.env"
    local _env_cand _env_newest _env_newest_ts=0 _env_cand_ts
    local -a _env_all_cands=()
    _env_newest="${env_file}.pre-migration.${_MV_RUN_TIMESTAMP}"
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
}

_mv_step_update_env() {
    _mv_log info "── update_env ────────────────────────────────────────────────────"

    local env_file="${PROJECT_ROOT}/.env"
    local old_state_dir="${_MV_SOURCE}"

    if [[ "${DRY_RUN}" != "true" ]]; then
        cp "${env_file}" "${env_file}.pre-migration.${_MV_RUN_TIMESTAMP}"
        chmod 0600 "${env_file}.pre-migration.${_MV_RUN_TIMESTAMP}"
        _mv_log info ".env backup created: ${env_file}.pre-migration.${_MV_RUN_TIMESTAMP}"
        _mv_prune_env_backups
    else
        _mv_log info "[DRY RUN] would: cp ${env_file} ${env_file}.pre-migration.${_MV_RUN_TIMESTAMP}"
    fi

    _mv_set_env_var PROJECT_STATE_DIR "${_MV_TARGET}"

    if [[ "${_MV_DIRECTION}" == "block-to-boot" ]]; then
        # Transitioning back to boot-only mode: clear the block device binding.
        _mv_set_env_var DATA_VOLUME_MOUNT  "${_MV_TARGET}"
        _mv_set_env_var DATA_VOLUME_DEVICE ""
    elif [[ -n "${_MV_DEVICE}" ]]; then
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

_mv_apply_dropin_paths() {
    # Usage: _mv_apply_dropin_paths <old_path> <new_path>
    # Updates the ReadWritePaths= path in each unit's 10-state-dir.conf drop-in.
    # Returns the count of drop-ins that were missing (caller can decide whether
    # to auto-install).
    local old_path="$1" new_path="$2"
    local unit drop_in tmp updated_any=false
    local missing_count=0

    for unit in "${_MV_DROPIN_UNITS[@]}"; do
        drop_in="/etc/systemd/system/${unit}.d/10-state-dir.conf"
        if [[ ! -f "${drop_in}" ]]; then
            _mv_log info "Drop-in not yet installed (will be created by installer): ${drop_in}"
            (( missing_count++ )) || true
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

    return "${missing_count}"
}

_mv_step_update_dropin() {
    _mv_log info "── update_dropin ─────────────────────────────────────────────────"

    local _missing_count=0
    _mv_apply_dropin_paths "${_MV_SOURCE}" "${_MV_TARGET}" || _missing_count=$?

    if (( _missing_count > 0 )); then
        # Some or all drop-ins were absent — they have not been installed yet.
        # Run setup-systemd.sh install to create them for the new target path.
        if [[ "${DRY_RUN}" == "true" ]]; then
            _mv_log info "[DRY RUN] would: run utilities/setup-systemd.sh install to create missing drop-ins"
        else
            _mv_log info "${_missing_count} drop-in(s) were missing — running" \
                "utilities/setup-systemd.sh install to create them..."
            if "${PROJECT_ROOT}/utilities/setup-systemd.sh" install; then
                _mv_log success "Systemd drop-ins installed for new data path: ${_MV_TARGET}"
            else
                _mv_log warn "utilities/setup-systemd.sh install did not complete successfully."
                _mv_log warn "Run manually after migration: sudo ./setup.sh systemd install"
            fi
        fi
    fi
}

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

_mv_step_healthcheck() {
    _mv_log info "── healthcheck ───────────────────────────────────────────────────"

    if [[ "${DRY_RUN}" == "true" ]]; then
        _mv_log info "[DRY RUN] would: poll 'docker compose ps --status running --quiet' for healthy state (up to 120s)"
        _mv_log info "[DRY RUN] would: write MIGRATION_COMPLETE=true to state file"
        _mv_print_checklist
        return 0
    fi

    _mv_log info "Waiting for vaultwarden container to become healthy (up to 120s)..."
    local _dw_rc=0
    docker_wait_healthy vaultwarden_app 120 10 || _dw_rc=$?

    if (( _dw_rc == 0 )); then
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
        _mv_log error "Health check timed out or container exited (docker_wait_healthy returned ${_dw_rc})."
        _mv_log error "Current container state:"
        docker compose ps 2>/dev/null || true
        _mv_log error "Recent logs:"
        docker compose logs --tail=50 2>/dev/null || true
        _mv_log error "MIGRATION_COMPLETE not written. Investigate and resume or abort."
        return 1
    fi
}

_mv_print_checklist() {
    local renamed_src="${_MV_SOURCE}.pre-migration.<original-run-timestamp>"
    if [[ "${DRY_RUN}" != "true" ]]; then
        renamed_src="${_MV_SOURCE}.pre-migration.${_MV_RUN_TIMESTAMP}"
    fi
    printf '\n'
    printf '═══════════════════════════════════════════════════════════════\n'
    printf '  Post-Migration Checklist\n'
    printf '═══════════════════════════════════════════════════════════════\n'
    printf '  1. Log in to VaultWarden and verify your vault data is intact.\n'
    printf '  2. Run: docker compose ps  — confirm all services are '\''healthy'\''.\n'
    printf '  3. Run: systemctl status vaultwarden-startup  — confirm unit loads cleanly.\n'
    printf '  4. Run: sudo ./setup.sh systemd install\n'
    printf '     This installs systemd service drop-ins for the new data path\n'
    printf '     so automated backups, health checks, and maintenance can write\n'
    printf '     to the new volume under ProtectSystem=strict.\n'
    printf '  5. Test a scheduled backup: sudo ./backup.sh run full\n'
    printf '  6. Verify backup path uses new volume: check BACKUP_DIR in .env\n'
    printf '     If BACKUP_DIR was a custom path it was NOT auto-updated — verify manually.\n'
    printf '  7. After a satisfying reboot test, remove the renamed source:\n'
    printf '       sudo rm -rf '\''%s'\''\n' "${renamed_src}"
    printf '  8. (If you added custom services to docker-compose.yml with hardcoded\n'
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
    printf '  .env backup:   %s.pre-migration.%s\n' "${PROJECT_ROOT}/.env" "${_MV_RUN_TIMESTAMP}"
    printf '═══════════════════════════════════════════════════════════════\n'
    printf '\n'
}

_mv_print_status() {
    if [[ ! -f "${_MV_STATE_FILE}" ]]; then
        log_info "No migration in progress or previously recorded."
        return 0
    fi

    local src tgt device direction start_ts complete

    src="$(_mv_state_read MV_SOURCE)"
    tgt="$(_mv_state_read MV_TARGET)"
    device="$(_mv_state_read MV_DEVICE)"
    direction="$(_mv_state_read MV_DIRECTION)"
    start_ts="$(_mv_state_read MV_START_TS)"
    complete="$(_mv_state_read MIGRATION_COMPLETE)"

    printf '\n'
    printf '  Migration State\n'
    printf '  ───────────────────────────────────────────────\n'
    printf '  %-20s %s\n' "Direction:" "${direction:-boot-to-block}"
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

        local _abort_nullglob_off=false
        shopt -q nullglob || _abort_nullglob_off=true
        shopt -s nullglob

        for src_cand in "${src}.pre-migration."*/; do
            [[ -d "${src_cand}" ]] || continue
            src_cand_ts="$(stat -c '%Y' "${src_cand}" 2>/dev/null || echo 0)"
            if (( src_cand_ts > src_newest_ts )); then
                src_newest_ts="${src_cand_ts}"
                renamed="${src_cand%/}"
            fi
        done

        [[ "${_abort_nullglob_off}" == "true" ]] && shopt -u nullglob

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

_mv_run_step() {
    local token="$1" fn="$2"
    if _mv_state_has "${token}"; then
        _mv_log info "Skipping (already done): ${fn#_mv_step_}"
        return 0
    fi
    _MV_CURRENT_STEP="${fn#_mv_step_}"
    "${fn}"
    _MV_CURRENT_STEP=""
    [[ "${DRY_RUN}" == "true" ]] || _mv_state_write "${token}"
}

_mv_run_pipeline() {
    local resuming=false
    [[ "${1:-}" == "--resume" ]] && resuming=true

    if [[ "${resuming}" == "true" ]]; then
        [[ -f "${_MV_STATE_FILE}" ]] || {
            log_error "No state file found. Cannot resume."
            log_error "Run: sudo utilities/setup-storage.sh --mode migrate run ..."
            exit 1
        }
        _MV_SOURCE="$(_mv_state_read MV_SOURCE)"
        _MV_TARGET="$(_mv_state_read MV_TARGET)"
        _MV_DEVICE="$(_mv_state_read MV_DEVICE)"
        [[ "${_MV_DEVICE}" == "none" ]] && _MV_DEVICE=""
        _MV_SKIP_STACK_STOP="$(_mv_state_read MV_SKIP_STACK_STOP)"
        _MV_DELETE_SOURCE="$(_mv_state_read MV_DELETE_SOURCE)"
        # Always restore direction from state — never require the operator to re-specify.
        # Default to boot-to-block for backwards compatibility with pre-direction state files.
        local _saved_direction
        _saved_direction="$(_mv_state_read MV_DIRECTION)"
        _MV_DIRECTION="${_saved_direction:-boot-to-block}"
        log_info "Resuming migration: ${_MV_SOURCE} → ${_MV_TARGET} (direction: ${_MV_DIRECTION})"

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
            if [[ "${_MV_DIRECTION}" == "boot-to-block" ]]; then
                # Target mount is absent. Check whether there is a sentinel-bearing volume
                # that could be the correct (or corrected) target.
                local _sentinel_mount
                _sentinel_mount="$(_mv_find_sentinel_mount)"
                if [[ -n "${_sentinel_mount}" && "${_sentinel_mount}" != "${_MV_TARGET}" ]]; then
                    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    log_warn "  The target path recorded in the state file (${_MV_TARGET})"
                    log_warn "  is not mounted, but a VaultWarden data volume was found at:"
                    log_warn "    ${_sentinel_mount}"
                    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    local _fix_reply
                    read -r -p "  Update the state file to use '${_sentinel_mount}' and continue? [y/N] " _fix_reply
                    if [[ "${_fix_reply}" =~ ^[Yy]$ ]]; then
                        local _old_target="${_MV_TARGET}"
                        _MV_TARGET="${_sentinel_mount}"
                        _mv_state_write MV_TARGET "${_MV_TARGET}"
                        log_info "State file updated: MV_TARGET=${_MV_TARGET} (was: ${_old_target})"
                        log_info "Continuing resume with corrected target path."
                    else
                        log_error "Resume aborted. To fix the target path manually:"
                        log_error "  sudo sed -i 's|MV_TARGET=${_MV_TARGET}|MV_TARGET=/correct/path|' \\"
                        log_error "    ${_MV_STATE_FILE}"
                        log_error "  sudo utilities/setup-storage.sh --mode migrate resume"
                        _resume_ok=false
                    fi
                else
                    log_error "Resume: target mount point is not mounted: ${_MV_TARGET}"
                    log_error "Remount it first, then re-run resume:"
                    log_error "  sudo mount ${_MV_TARGET}"
                    log_error "To fix a stale path in the state file manually:"
                    log_error "  sudo sed -i 's|MV_TARGET=${_MV_TARGET}|MV_TARGET=/correct/path|' \\"
                    log_error "    ${_MV_STATE_FILE}"
                    log_error "  sudo utilities/setup-storage.sh --mode migrate resume"
                    _resume_ok=false
                fi
            elif [[ "${_MV_DIRECTION}" == "block-to-boot" ]]; then
                # block-to-boot: target is a directory on the boot disk, not a mountpoint.
                # A missing or empty target directory at resume time means rsync never
                # completed — this is recoverable. A non-empty target means rsync ran
                # at least partially and we can safely continue.
                if [[ ! -d "${_MV_TARGET}" ]]; then
                    log_warn "Resume (block-to-boot): target directory does not exist: ${_MV_TARGET}"
                    log_warn "It will be created when rsync runs. This is safe to continue."
                else
                    local _tgt_count
                    _tgt_count="$(find "${_MV_TARGET}" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
                    log_info "Resume (block-to-boot): target directory exists with ${_tgt_count} item(s) — continuing."
                fi
            fi
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

    local -a _pipeline_steps=(
        "STEP_VALIDATE_DONE:_mv_step_validate"
        "STEP_BACKUP_DONE:_mv_step_backup_prompt"
        "STEP_STOP_DONE:_mv_step_stop"
        "STEP_FORMAT_DONE:_mv_step_format"
        "STEP_RSYNC_DONE:_mv_step_rsync"
        "STEP_VERIFY_DONE:_mv_step_verify"
        "STEP_SOURCE_RENAMED_DONE:_mv_step_rename_source"
        "STEP_SOURCE_DELETED_DONE:_mv_step_delete_source"
        "STEP_ENV_UPDATED_DONE:_mv_step_update_env"
        "STEP_DROPIN_UPDATED_DONE:_mv_step_update_dropin"
        "STEP_MOUNT_GUARD_DONE:_mv_step_mount_guard"
        "STEP_START_DONE:_mv_step_start"
        "STEP_HEALTHCHECK_DONE:_mv_step_healthcheck"
    )

    local _step _token _fn
    for _step in "${_pipeline_steps[@]}"; do
        _token="${_step%%:*}"
        _fn="${_step##*:}"
        case "${_token}" in
            STEP_SOURCE_DELETED_DONE)
                [[ "${_MV_DELETE_SOURCE}" == "true" ]] || continue
                ;;
        esac
        _mv_run_step "${_token}" "${_fn}"
    done
}

migrate_mode_main() {
    _MV_START_TIME="${SECONDS}"

    _mv_require_root "$@"
    _mv_parse_args "$@"

    # On resume, restore the original run's log file path and run timestamp
    # from state before opening the log, so resume output appends to the same
    # log file and .env backup filenames match the original run.
    if [[ "${_MV_SUBCOMMAND}" == "resume" && -f "${_MV_STATE_FILE}" ]]; then
        local _saved_log _saved_ts
        _saved_log="$(_mv_state_read MV_LOG_FILE)"
        _saved_ts="$(_mv_state_read MV_START_TS)"
        [[ -n "${_saved_log}" ]] && _MV_LOG_FILE="${_saved_log}"
        [[ -n "${_saved_ts}" ]] && _MV_RUN_TIMESTAMP="$(date -d "@${_saved_ts}" +%Y%m%d_%H%M%S 2>/dev/null || echo "${_MV_RUN_TIMESTAMP}")"
    fi

    _mv_open_log

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
