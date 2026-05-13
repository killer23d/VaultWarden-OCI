#!/usr/bin/env bash
# utilities/migrate-volume.sh — VaultWarden-OCI volume migration utility
# Migrates PROJECT_STATE_DIR between block devices or directories, including
# boot-volume-to-dedicated-volume and volume-to-volume migrations.
# Safe to interrupt; resumes from the last completed step.
#
# USAGE: sudo utilities/migrate-volume.sh <subcommand> [OPTIONS]
# Run with --help for full usage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"   # ← one level up from utilities/
cd "${PROJECT_ROOT}"

# ── Minimal ERR handler (replaced with full version after libs load) ──────────
_mv_on_err() {
    echo "ERROR: Unexpected error at line ${2:-?} (exit ${1:-?}). Migration halted." >&2
    echo "Resume with: sudo utilities/migrate-volume.sh resume" >&2
    echo "Abort with:  sudo utilities/migrate-volume.sh abort"  >&2
}

trap '_mv_on_err $? $LINENO' ERR

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
[[ -f "${PROJECT_ROOT}/.env" ]] && load_env_file "${PROJECT_ROOT}/.env"  # provided by lib/common.sh
export DRY_RUN=false                      # set immediately; overridden by arg parsing
                                          # intentionally unprefixed: exported to lib functions
                                          # (lib/storage.sh, lib/docker.sh) which read DRY_RUN directly

# ── Constants ─────────────────────────────────────────────────────────────────
readonly _MV_VERSION="1.2.0"
_MV_SCRIPT_NAME="$(basename "$0")"
readonly _MV_SCRIPT_NAME
_MV_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly _MV_TIMESTAMP
readonly _MV_LOCK_FILE="/run/lock/vaultwarden-migrate.lock"
readonly _MV_LOG_MAX_BYTES=$(( 10 * 1024 * 1024 ))   # 10 MiB — rotate beyond this
readonly _MV_VERIFY_TOLERANCE_PCT=1                    # allow ≤1% size delta post-rsync

# State file lives in PROJECT_ROOT (not PROJECT_STATE_DIR — state dir may change)
readonly _MV_STATE_FILE="${PROJECT_ROOT}/.migrate-volume.state"

# rsync exclude list — paths that must not be copied to the target
# NOTE: secrets/, .sops.yaml, and the Age key are under PROJECT_ROOT, not
# PROJECT_STATE_DIR. They are never encountered by rsync and must NOT appear here.
readonly -a _MV_RSYNC_EXCLUDES=(
    "lost+found/"       # ext4 fsck directory — permission errors on some kernels
    ".vw-data-volume"   # sentinel written by setup_data_volume(); never overwrite target's
    "*.sock"            # dead runtime sockets confuse service startup diagnostics
    "*.pid"             # PID files are always stale after stack stop
)

# Systemd drop-in units whose ReadWritePaths= must be updated after migration.
# KEEP IN SYNC with _VW_DROPIN_UNITS in setup.sh.
readonly -a _MV_DROPIN_UNITS=(
    "vaultwarden-startup.service"
    "vaultwarden-backup.service"
    "vaultwarden-maintenance.service"
    "vaultwarden-restore.service"
)

# ── Elapsed-time helper ───────────────────────────────────────────────────────
_MV_START_TIME="${SECONDS}"   # bash built-in — seconds since shell started

_mv_elapsed() {
    local elapsed=$(( SECONDS - _MV_START_TIME ))
    printf '%dm%02ds' $(( elapsed / 60 )) $(( elapsed % 60 ))
}

# ── Lock helpers ──────────────────────────────────────────────────────────────
_MV_LOCK_FD=""

_mv_acquire_lock() {
    local lock_fd
    # Allocate an unused file descriptor dynamically
    exec {lock_fd}>"${_MV_LOCK_FILE}"
    flock -n "${lock_fd}" || {
        log_error "Another migration is already running (lock held: ${_MV_LOCK_FILE})."
        log_error "Run: sudo utilities/migrate-volume.sh status"
        exit 1
    }
    # Export fd number so _mv_release_lock can close it
    _MV_LOCK_FD="${lock_fd}"
}

_mv_release_lock() {
    [[ -n "${_MV_LOCK_FD:-}" ]] && {
        flock -u "${_MV_LOCK_FD}"
        eval "exec ${_MV_LOCK_FD}>&-"
        _MV_LOCK_FD=""
    }
}

# ── Cleanup trap and ERR handler ──────────────────────────────────────────────
_mv_cleanup() {
    # Called on EXIT. Releases lock. Prints elapsed time.
    _mv_release_lock
    _mv_log info "Elapsed: $(_mv_elapsed)"
}

# ── Root check ────────────────────────────────────────────────────────────────
_mv_require_root() {
    [[ "${EUID}" -eq 0 ]] || {
        log_error "This script must be run as root: sudo utilities/migrate-volume.sh $*"
        exit 1
    }
}

# ── Logging ───────────────────────────────────────────────────────────────────
_MV_LOG_FILE=""

_mv_log() {
    # Passthrough to lib/common.sh log functions AND write to log file.
    # Usage: _mv_log <level> <message>
    # level: info | warn | error | success
    local level="$1"; shift
    local msg="$*"
    "log_${level}" "${msg}"                                    # stdout via lib/common.sh
    printf '[%s] [%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "${level^^}" \
        "${msg}" >> "${_MV_LOG_FILE:-/tmp/migrate-volume.log}"
}

# ── Full ERR handler (redefines the minimal version set before libs loaded) ───
_mv_on_err() {
    local rc="$1" lineno="$2"
    _mv_log error "Unexpected error at line ${lineno} (exit ${rc}). Migration halted."
    _mv_log error "Resume with: sudo utilities/migrate-volume.sh resume"
    _mv_log error "Abort with:  sudo utilities/migrate-volume.sh abort"
    # Do NOT call _mv_cleanup here — EXIT trap fires after ERR trap.
}

_mv_open_log() {
    # Determine log file path (--log-file overrides default).
    # Log directory is always PROJECT_ROOT/logs — never PROJECT_STATE_DIR/logs.
    # PROJECT_STATE_DIR is the migration source and may be renamed or deleted mid-run
    # (step 6 rename_source / step 6a delete_source). Using PROJECT_ROOT keeps the log
    # file alive for the full duration of the migration, including --delete-source runs.
    if [[ -z "${_MV_LOG_FILE:-}" ]]; then
        local log_dir="${PROJECT_ROOT}/logs"
        mkdir -p "${log_dir}" 2>/dev/null || log_dir="/tmp"
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

    # Create the log file (touch; actual writes go through _mv_log).
    [[ "${DRY_RUN}" == "true" ]] || touch "${_MV_LOG_FILE}"

    _mv_log info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    _mv_log info "  migrate-volume.sh v${_MV_VERSION} — $(date '+%Y-%m-%d %H:%M:%S %Z')"
    _mv_log info "  Log file: ${_MV_LOG_FILE}"
    _mv_log info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── State file helpers ────────────────────────────────────────────────────────
_mv_state_write() {
    # Usage: _mv_state_write KEY [VALUE]
    # VALUE defaults to "true". Atomic write via temp file.
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
    # Prints value or empty string if not found.
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

# ── FIX #1: lsblk partition helper ───────────────────────────────────────────
# Returns 0 (true) if the given device path is a partition rather than a whole
# disk. A partition has a non-empty PKNAME (parent kernel name) in lsblk output.
_mv_lsblk_is_partition() {
    local dev="$1"
    local pkname
    pkname="$(lsblk -no PKNAME "${dev}" 2>/dev/null || true)"
    [[ -n "${pkname}" ]]
}

# ── Interactive block device selector ────────────────────────────────────────
_mv_select_device() {
    # Presents a numbered list of block devices (disks AND partitions) using lsblk.
    # Tags each row: [boot] for the root device, [part] for partition entries.
    # Populates _MV_DEVICE with the selected device path.
    # Skips if --device was already provided, subcommand is not 'run',
    # or --target was already provided (dir-to-dir migration needs no device).

    [[ -n "${_MV_DEVICE:-}" ]] && return 0
    [[ "${_MV_SUBCOMMAND}" == "run" ]] || return 0
    [[ -n "${_MV_TARGET:-}" ]] && return 0   # dir-to-dir migration; no device needed

    log_info "Detecting block devices using lsblk..."
    printf '\n'

    # FIX #1: include partitions by dropping the -d (disk-only) flag.
    # Cloud providers commonly present attached volumes as /dev/sdb1 (a partition)
    # rather than the whole-disk /dev/sdb. Without partitions in the list a junior
    # operator would see no selectable target and receive no hint why.
    # Output: NAME SIZE MOUNTPOINT  (tab-separated, no header)
    local -a dev_names dev_sizes dev_mounts dev_tags
    local name size mount _rest

    while IFS=$'\t' read -r name size mount _rest; do
        [[ -z "${name}" ]] && continue
        dev_names+=( "/dev/${name}" )
        dev_sizes+=( "${size}" )
        dev_mounts+=( "${mount}" )
    done < <(lsblk -o NAME,SIZE,MOUNTPOINT -rn 2>/dev/null)

    if (( ${#dev_names[@]} == 0 )); then
        log_error "No block devices found via lsblk. Ensure the target disk is attached."
        return 1
    fi

    # Determine root device (the physical disk backing the / mountpoint)
    local root_source root_dev
    root_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    root_dev="$(lsblk -no PKNAME "${root_source}" 2>/dev/null \
        || lsblk -no NAME "${root_source}" 2>/dev/null \
        || true)"
    # Only prefix /dev/ if detection succeeded; otherwise leave empty
    [[ -n "${root_dev}" ]] && root_dev="/dev/${root_dev}"

    # Build tag string for each device
    local i tag
    for (( i=0; i<${#dev_names[@]}; i++ )); do
        tag=""
        if [[ "${dev_mounts[$i]}" == "/" ]] \
                || [[ -n "${root_dev}" && "${root_dev}" == "${dev_names[$i]}" ]]; then
            tag="[boot]"
        elif _mv_lsblk_is_partition "${dev_names[$i]}"; then
            tag="[part]"
        fi
        dev_tags+=( "${tag}" )
    done

    local mount_display
    for (( i=0; i<${#dev_names[@]}; i++ )); do
        mount_display="${dev_mounts[$i]:-  -}"
        printf '  %d) %-14s  size: %-8s  mount: %-20s  %s\n' \
            $(( i + 1 )) \
            "${dev_names[$i]}" \
            "${dev_sizes[$i]}" \
            "${mount_display}" \
            "${dev_tags[$i]}"
    done

    printf '\n'
    printf '  NOTE: Cloud providers often attach volumes as partitions (e.g. /dev/sdb1\n'
    printf '        tagged [part]) rather than whole disks. Both are listed above.\n'
    printf '        Select the partition your data volume will occupy, not the raw disk.\n'
    printf '\n'
    log_warn "Select TARGET device for migration (DO NOT choose [boot]):"

    local choice
    while true; do
        read -r -p "  Device number [1-${#dev_names[@]}]: " choice
        if [[ "${choice}" =~ ^[0-9]+$ ]] \
                && (( choice >= 1 && choice <= ${#dev_names[@]} )); then
            _MV_DEVICE="${dev_names[$(( choice - 1 ))]}"
            # Guard against boot device selection (by mountpoint or by root device identity)
            if [[ "${dev_mounts[$(( choice - 1 ))]}" == "/" ]] \
                    || [[ -n "${root_dev}" && "${root_dev}" == "${_MV_DEVICE}" ]]; then
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
    # Prompts for the target mount point when --target is not provided.
    # Uses /mnt/vw-data as the default (matching DATA_VOLUME_MOUNT in .env.example).
    # Skips if _MV_TARGET is already set (--target was passed on CLI).

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
# Printed in main() after interactive prompts but before _mv_run_pipeline.
# Gives the operator one final chance to review what the pipeline will do
# and confirm — critical since the very next step stops Docker and may format a disk.
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

    # In --yes mode do not prompt; log the summary and continue.
    if [[ "${_MV_YES:-false}" == "true" ]]; then
        _mv_log info "Non-interactive mode (--yes): proceeding without confirmation."
        return 0
    fi

    _mv_confirm "Confirm the above and start migration."
}

# ── Private helper: disk space check ─────────────────────────────────────────
_mv_check_disk_space() {
    # Usage: _mv_check_disk_space <source_path> <target_path>
    # Fails if target does not have (source_bytes * 1.10) free.
    local source="$1" target="$2"
    local src_bytes avail_bytes required_bytes

    src_bytes="$(du -sb "${source}/" | awk '{print $1}')"
    avail_bytes="$(df -B1 --output=avail "${target}" | tail -1 | tr -d ' ')"
    required_bytes=$(( src_bytes + src_bytes / 10 ))   # source + 10% headroom

    _mv_log info "Disk space check:"
    _mv_log info "  Source size  : $(numfmt --to=iec-i --suffix=B "${src_bytes}")"
    _mv_log info "  Required     : $(numfmt --to=iec-i --suffix=B "${required_bytes}") (source + 10%)"
    _mv_log info "  Target avail : $(numfmt --to=iec-i --suffix=B "${avail_bytes}")"

    if (( avail_bytes < required_bytes )); then
        _mv_log error "Insufficient space on target."
        _mv_log error "  Need : $(numfmt --to=iec-i --suffix=B "${required_bytes}")"
        _mv_log error "  Have : $(numfmt --to=iec-i --suffix=B "${avail_bytes}")"
        return 1
    fi

    _mv_log success "Disk space OK."
}

# ── Private helper: stale backup check ───────────────────────────────────────
_mv_check_stale_backup() {
    # Warns (does not block) if the newest backup is older than 24 hours.
    local backup_base_dir newest newest_ts now_ts age_hours

    backup_base_dir="${BACKUP_DIR:-${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/backups}"

    # Find the most recently modified backup archive across all backup types.
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
    # Usage: _mv_set_env_var <key> <value>
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
        # Escape characters that are special in the sed replacement field
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

# ── FIX #3: fstab warning helper ─────────────────────────────────────────────
# Scans /etc/fstab for entries referencing either the old source path or the new
# target path and emits a prominent warning for each match found.
# Called after abort rollback so the operator is reminded to verify/clean up
# any stale fstab entries that could auto-mount the old volume at boot.
_mv_warn_fstab_entries() {
    local search_path="$1" label="$2"
    [[ -f /etc/fstab ]] || return 0

    local -a matches
    while IFS= read -r line; do
        # Skip blank lines and comments
        [[ -z "${line}" || "${line}" == '#'* ]] && continue
        if [[ "${line}" == *"${search_path}"* ]]; then
            matches+=( "${line}" )
        fi
    done < /etc/fstab

    if (( ${#matches[@]} > 0 )); then
        _mv_log warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        _mv_log warn "  WARNING: /etc/fstab contains ${#matches[@]} entry/entries referencing ${label}:"
        local m
        for m in "${matches[@]}"; do
            _mv_log warn "    ${m}"
        done
        _mv_log warn "  These entries may auto-mount the old volume at boot and shadow"
        _mv_log warn "  the restored path. Verify /etc/fstab manually and remove or"
        _mv_log warn "  update any stale entries:"
        _mv_log warn "    sudo nano /etc/fstab"
        _mv_log warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi
}

# ── Usage / help ──────────────────────────────────────────────────────────────
_mv_usage() {
cat << 'EOF'
VaultWarden-OCI Volume Migration Utility

USAGE:
  sudo utilities/migrate-volume.sh <subcommand> [OPTIONS]

SUBCOMMANDS:
  run      Execute the full migration pipeline (default)
  resume   Resume a previously interrupted migration
  status   Show current migration state
  abort    Roll back an in-progress migration
  verify   Re-run byte-count verification only (non-destructive)

OPTIONS (run / resume):
  --source  <path>   Source directory  (default: current PROJECT_STATE_DIR from .env)
  --target  <path>   Destination mount point  (prompted interactively if omitted)
  --device  <dev>    Block device for new volume (e.g. /dev/sdb or /dev/sdb1)
                     Prompted interactively via lsblk if omitted.
                     Omit entirely for directory-to-directory migration.
  --skip-stack-stop  Do not stop the Docker stack before migrating.
                     Requires explicit runtime confirmation. Use with caution.
                     Cannot be combined with --yes (non-interactive mode).
  --delete-source    Delete renamed source after successful verification.
                     Always requires typing a confirmation token interactively.
  --dry-run          Print all actions without executing them.
  --force            Skip the pre-migration backup confirmation prompt.
  --yes              Answer yes to all confirmations (except --delete-source).
                     Requires --target when used (non-interactive mode).
                     Cannot be combined with --skip-stack-stop.
  --log-file <path>  Override default log file path.
  --help             Show this help and exit.

EXAMPLES:
  # Interactive (prompts for device and mount point)
  sudo utilities/migrate-volume.sh run

  # Non-interactive: boot volume → dedicated data volume
  sudo utilities/migrate-volume.sh run \
    --source /var/lib/vaultwarden \
    --target /mnt/vw-data \
    --device /dev/sdb \
    --yes

  # Directory-to-directory (no device, no format step)
  sudo utilities/migrate-volume.sh run \
    --source /var/lib/vaultwarden \
    --target /mnt/vw-data2

  # Dry run first
  sudo utilities/migrate-volume.sh run \
    --source /var/lib/vaultwarden \
    --target /mnt/vw-data \
    --device /dev/sdb \
    --dry-run

  # Resume after interruption
  sudo utilities/migrate-volume.sh resume

  # Check status
  sudo utilities/migrate-volume.sh status

  # Abort and roll back
  sudo utilities/migrate-volume.sh abort
EOF
}

# ── Argument parser ───────────────────────────────────────────────────────────
_mv_parse_args() {
    # Defaults
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
            # --target is required only in non-interactive (--yes) mode.
            # If running interactively, _mv_prompt_target will collect it after arg parsing.
            if [[ "${_MV_YES:-false}" == "true" && -z "${_MV_TARGET}" ]]; then
                log_error "--target is required when using --yes (non-interactive mode)."
                exit 1
            fi
            # --skip-stack-stop in --yes mode is ambiguous and unsafe.
            # The live-container guard in _mv_step_validate uses _mv_confirm_by_typing,
            # which is always interactive — but only fires if containers happen to be
            # running at check time. In --yes mode there is no operator present to catch
            # a race where containers start between the check and rsync, making the guard
            # ineffective. Require interactive mode whenever --skip-stack-stop is used.
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
}

# ── Pipeline step 0: Pre-flight validation ────────────────────────────────────
_mv_step_validate() {
    _mv_log info "── validate ──────────────────────────────────────────────────────"

    # 1. Required commands
    require_commands rsync flock findmnt lsblk df du awk sed mktemp numfmt

    # 2. Source exists and is a directory
    [[ -d "${_MV_SOURCE}" ]] || {
        _mv_log error "Source path does not exist or is not a directory: ${_MV_SOURCE}"
        return 1
    }

    # 3. Target is not the same canonical path as source
    local canon_src canon_tgt
    canon_src="$(realpath -m "${_MV_SOURCE}")"
    canon_tgt="$(realpath -m "${_MV_TARGET}")"
    [[ "${canon_src}" != "${canon_tgt}" ]] || {
        _mv_log error "Source and target are the same path: ${canon_src}"
        return 1
    }

    # 4. Target is not a subdirectory of source (rsync infinite loop guard)
    [[ "${canon_tgt}" != "${canon_src}/"* ]] || {
        _mv_log error "Target '${canon_tgt}' is a subdirectory of source '${canon_src}'."
        _mv_log error "This would cause an rsync infinite loop. Aborted."
        return 1
    }

    # 5. Guard against --target being accidentally set to a raw device path.
    # dir-to-dir mode skips _mv_select_device when --target is provided, so passing
    # --target /dev/sdb (without --device) would hand a block device path to rsync
    # and silently overwrite it. Catch this early.
    if [[ "${_MV_TARGET}" == /dev/* && -z "${_MV_DEVICE}" ]]; then
        _mv_log error "--target looks like a block device path: ${_MV_TARGET}"
        _mv_log error "To migrate to a block device use --device ${_MV_TARGET} with a directory --target."
        _mv_log error "Example: --device ${_MV_TARGET} --target /mnt/vw-data"
        return 1
    fi

    # 6. Source is not being written to by a running rsync
    if find /proc/*/fd -lname "${_MV_SOURCE}/*" -print0 2>/dev/null \
            | xargs -r -0 ls -l 2>/dev/null \
            | grep -q rsync; then
        _mv_log error "rsync appears to be actively writing to ${_MV_SOURCE}."
        _mv_log error "Wait for it to finish before migrating."
        return 1
    fi

    # 7. If --device given: validate device node
    if [[ -n "${_MV_DEVICE}" ]]; then
        [[ -b "${_MV_DEVICE}" ]] || {
            _mv_log error "Device is not a block device: ${_MV_DEVICE}"
            return 1
        }
        # Ensure device is not already mounted elsewhere (other than the target)
        local dev_mount
        dev_mount="$(findmnt -n -o TARGET --source "${_MV_DEVICE}" 2>/dev/null || true)"
        if [[ -n "${dev_mount}" && "${dev_mount}" != "${_MV_TARGET}" ]]; then
            _mv_log error "Device ${_MV_DEVICE} is already mounted at: ${dev_mount}"
            _mv_log error "Unmount it first or omit --device if the target is already mounted."
            return 1
        fi
    fi

    # 8. Disk space check
    # Ensure target directory exists for df to work
    mkdir -p "${_MV_TARGET}" 2>/dev/null || true
    _mv_check_disk_space "${_MV_SOURCE}" "${_MV_TARGET}"

    # 9. Stale backup warning (non-blocking)
    _mv_check_stale_backup

    # 10. --skip-stack-stop with live containers: require explicit confirmation
    if [[ "${_MV_SKIP_STACK_STOP}" == "true" ]]; then
        local running_containers
        # FIX #6: use --status / --quiet flags instead of JSON grep so the count
        # is format-agnostic across all Docker Compose v2 releases.
        running_containers="$(docker compose ps --status running --quiet 2>/dev/null \
            | wc -l | tr -d ' ' || echo 0)"
        if (( running_containers > 0 )); then
            _mv_log warn "WARNING: ${running_containers} VaultWarden container(s) are currently running."
            _mv_log warn "Migrating a live stack risks SQLite WAL corruption."
            _mv_log warn "Data integrity cannot be guaranteed if the database is actively written."
            _mv_confirm_by_typing \
                "You are about to migrate a LIVE stack." \
                "LIVE"
        fi
    fi

    # 11. Confirm .env is readable and PROJECT_STATE_DIR key is present
    [[ -f "${PROJECT_ROOT}/.env" ]] || {
        _mv_log error ".env not found at: ${PROJECT_ROOT}/.env"
        return 1
    }
    grep -q "^PROJECT_STATE_DIR=" "${PROJECT_ROOT}/.env" 2>/dev/null || {
        _mv_log error "PROJECT_STATE_DIR key not found in .env"
        return 1
    }

    # 12. Confirm docker-compose.yml exists in PROJECT_ROOT
    [[ -f "${PROJECT_ROOT}/docker-compose.yml" ]] || {
        _mv_log error "docker-compose.yml not found at: ${PROJECT_ROOT}/docker-compose.yml"
        return 1
    }

    # Write migration metadata to state file
    if [[ "${DRY_RUN}" != "true" ]]; then
        _mv_state_write MV_SOURCE          "${_MV_SOURCE}"
        _mv_state_write MV_TARGET          "${_MV_TARGET}"
        _mv_state_write MV_DEVICE          "${_MV_DEVICE:-none}"
        _mv_state_write MV_START_TS        "$(date +%s)"
        _mv_state_write MV_LOG_FILE        "${_MV_LOG_FILE}"
        _mv_state_write MV_SKIP_STACK_STOP "${_MV_SKIP_STACK_STOP}"
        _mv_state_write MV_DELETE_SOURCE   "${_MV_DELETE_SOURCE}"
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
        return 0
    fi

    _mv_log info "Container state before stop:"
    docker compose ps 2>/dev/null || true

    if [[ "${DRY_RUN}" == "true" ]]; then
        _mv_log info "[DRY RUN] would: stop VaultWarden stack (stop_services)"
        return 0
    fi

    stop_services   # from lib/docker.sh

    _mv_log info "Container state after stop:"
    docker compose ps 2>/dev/null || true
    _mv_log success "Stack stopped."
}

# ── Pipeline step 3: Format and mount target volume ───────────────────────────
_mv_step_format() {
    _mv_log info "── format ────────────────────────────────────────────────────────"

    if [[ -z "${_MV_DEVICE}" ]]; then
        _mv_log info "No --device supplied — skipping format step (directory-to-directory migration)."
        return 0
    fi

    # Check if already formatted and mounted at target
    if mountpoint -q "${_MV_TARGET}" 2>/dev/null; then
        _mv_log info "Target ${_MV_TARGET} is already a mounted filesystem — skipping format."
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        _mv_log info "[DRY RUN] would: setup_data_volume (format and mount ${_MV_DEVICE} at ${_MV_TARGET})"
        return 0
    fi

    # setup_data_volume reads from env vars
    DATA_VOLUME_DEVICE="${_MV_DEVICE}"
    DATA_VOLUME_MOUNT="${_MV_TARGET}"
    export DATA_VOLUME_DEVICE DATA_VOLUME_MOUNT

    setup_data_volume   # from lib/storage.sh
    _mv_log success "Target volume formatted and mounted: ${_MV_DEVICE} → ${_MV_TARGET}"
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

    # Append exclude entries
    local excl
    for excl in "${_MV_RSYNC_EXCLUDES[@]}"; do
        rsync_flags+=("--exclude=${excl}")
    done

    # Add --dry-run when requested
    [[ "${DRY_RUN}" == "true" ]] && rsync_flags+=(--dry-run)

    # Ensure target directory exists
    if [[ "${DRY_RUN}" != "true" ]]; then
        mkdir -p "${_MV_TARGET}"
    else
        _mv_log info "[DRY RUN] would: mkdir -p ${_MV_TARGET}"
    fi

    _mv_log info "Running rsync: ${_MV_SOURCE%/}/ → ${_MV_TARGET}"
    _mv_log info "Flags: ${rsync_flags[*]}"

    # The trailing slash on source tells rsync to copy contents, not the directory itself
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

    _mv_log info "Source size : $(numfmt --to=iec-i --suffix=B "${src_bytes}")"
    _mv_log info "Target size : $(numfmt --to=iec-i --suffix=B "${tgt_bytes}")"

    if (( src_bytes == 0 )); then
        _mv_log warn "Source reports 0 bytes — skipping percentage check."
        return 0
    fi

    # Compute absolute delta as a percentage of source, scaled by 100 for precision.
    # Using pct_x100 (basis points) avoids integer truncation that would make a
    # 0.5% delta appear as 0% and silently pass the 1% tolerance check.
    delta=$(( tgt_bytes > src_bytes ? tgt_bytes - src_bytes : src_bytes - tgt_bytes ))
    pct_x100=$(( delta * 10000 / src_bytes ))

    _mv_log info "Delta: $(numfmt --to=iec-i --suffix=B "${delta}") ($(( pct_x100 / 100 )).$(( pct_x100 % 100 ))%)"

    if (( pct_x100 > _MV_VERIFY_TOLERANCE_PCT * 100 )); then
        _mv_log error "Byte-count delta exceeds tolerance (${_MV_VERIFY_TOLERANCE_PCT}%)."
        _mv_log error "Investigate before proceeding. Resume with: sudo utilities/migrate-volume.sh resume"
        return 1
    fi

    _mv_log success "Verification passed (delta ≤ ${_MV_VERIFY_TOLERANCE_PCT}%)."
}

# ── Pipeline step 6: Rename source ───────────────────────────────────────────
_mv_step_rename_source() {
    _mv_log info "── rename_source ─────────────────────────────────────────────────"

    local renamed="${_MV_SOURCE}.pre-migration.${_MV_TIMESTAMP}"

    # If source is a mount point, skip rename
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

    # Locate the most recently modified renamed source directory.
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

    # FIX #4: require only the basename as the confirmation token, not the full
    # path. The full path is displayed for verification, but typing a long
    # /var/lib/… string character-perfect is error-prone and discourages the use
    # of this safety gate. The basename (e.g. "vaultwarden.pre-migration.20260512_210134")
    # is unique, unambiguous, and short enough to transcribe accurately.
    local confirm_token
    confirm_token="$(basename "${renamed}")"

    _mv_log warn "About to permanently delete:"
    _mv_log warn "  Full path : ${renamed}"
    _mv_log warn "  To confirm, type the directory name shown below."

    _mv_confirm_by_typing \
        "Permanently delete '${renamed}'." \
        "${confirm_token}"

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

    # Create timestamped .env backup before any changes
    if [[ "${DRY_RUN}" != "true" ]]; then
        cp "${env_file}" "${env_file}.pre-migration.${_MV_TIMESTAMP}"
        chmod 0600 "${env_file}.pre-migration.${_MV_TIMESTAMP}"
        _mv_log info ".env backup created: ${env_file}.pre-migration.${_MV_TIMESTAMP}"
    else
        _mv_log info "[DRY RUN] would: cp ${env_file} ${env_file}.pre-migration.${_MV_TIMESTAMP}"
    fi

    # Update PROJECT_STATE_DIR (always)
    _mv_set_env_var PROJECT_STATE_DIR "${_MV_TARGET}"

    # Update DATA_VOLUME_MOUNT and DATA_VOLUME_DEVICE when --device was supplied
    if [[ -n "${_MV_DEVICE}" ]]; then
        _mv_set_env_var DATA_VOLUME_MOUNT  "${_MV_TARGET}"
        _mv_set_env_var DATA_VOLUME_DEVICE "${_MV_DEVICE}"
    fi

    # FIX #5: Handle all three BACKUP_DIR cases explicitly.
    #
    # Case A — default path under old state dir → auto-update to new default.
    # Case B — custom / non-empty path that differs from both old and new defaults
    #           → warn and require explicit confirmation before continuing.
    #           The operator must verify the path is valid on the new volume.
    # Case C — key is absent or empty → runtime default resolves via the updated
    #           PROJECT_STATE_DIR, but the operator should verify backup.sh
    #           behaviour to ensure backups land on the new volume.
    local current_backup_dir
    current_backup_dir="$(grep "^BACKUP_DIR=" "${env_file}" 2>/dev/null | cut -d= -f2- || true)"

    if [[ "${current_backup_dir}" == "${old_state_dir}/backups" ]]; then
        # Case A: auto-update
        _mv_set_env_var BACKUP_DIR "${_MV_TARGET}/backups"

    elif [[ -n "${current_backup_dir}" \
            && "${current_backup_dir}" != "${_MV_TARGET}/backups" ]]; then
        # Case B: custom path — warn prominently and require acknowledgement
        _mv_log warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        _mv_log warn "  BACKUP_DIR is set to a custom path and was NOT auto-updated:"
        _mv_log warn "    ${current_backup_dir}"
        _mv_log warn "  This path may still reference the old volume. Verify it points"
        _mv_log warn "  to the correct location on the new volume before continuing."
        _mv_log warn "  To update manually: nano ${env_file}"
        _mv_log warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        # _mv_confirm respects --yes; the warning above is always logged regardless.
        _mv_confirm "Acknowledge: BACKUP_DIR was NOT auto-updated. Continue anyway?"

    else
        # Case C: key is absent or empty
        _mv_log warn "BACKUP_DIR is not set in .env."
        _mv_log warn "The runtime default will resolve relative to the updated PROJECT_STATE_DIR."
        _mv_log warn "Verify that backup.sh writes to the new volume after migration:"
        _mv_log warn "  sudo ./backup.sh full && ls -lh ${_MV_TARGET}/backups/"
    fi

    _mv_log success ".env updated for new state directory: ${_MV_TARGET}"
}

# ── Pipeline step 8: Update systemd drop-in paths ────────────────────────────
_mv_step_update_dropin() {
    _mv_log info "── update_dropin ─────────────────────────────────────────────────"

    local old_path="${_MV_SOURCE}"
    local new_path="${_MV_TARGET}"
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
        # Escape characters that are special in sed's pattern and replacement fields.
        # Delimiter is |, so | must be escaped; & means "matched text" in replacement.
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

# ── Pipeline step 8a: Install Docker mount guard ──────────────────────────────
# mount_guard runs BEFORE step 9 (start) so the systemd unit that ensures the
# block volume is mounted before Docker starts is installed prior to the first
# post-migration stack startup. On a cold boot after migration the volume would
# not be guaranteed mounted before Docker started if this ran after start_services.
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
        # Do not return 1 here — let the health check determine the outcome
    else
        _mv_log success "Stack started."
    fi
}

# ── Pipeline step 10: Health check ───────────────────────────────────────────
_mv_step_healthcheck() {
    _mv_log info "── healthcheck ───────────────────────────────────────────────────"

    if [[ "${DRY_RUN}" == "true" ]]; then
        _mv_log info "[DRY RUN] would: poll 'docker compose ps --status running' for healthy state (up to 120s)"
        _mv_state_write MIGRATION_COMPLETE "true"
        _mv_print_checklist
        return 0
    fi

    local max_wait=120
    local poll_interval=10
    local elapsed=0
    local healthy=false

    while (( elapsed < max_wait )); do
        # FIX #6: use --status / --quiet instead of JSON grep so the count is
        # format-agnostic across all Docker Compose v2 releases.
        # --quiet emits one container ID per line regardless of output format.
        local running_count total_count
        running_count="$(docker compose ps --status running --quiet 2>/dev/null \
            | wc -l | tr -d ' ' || echo 0)"
        total_count="$(docker compose ps --quiet 2>/dev/null \
            | wc -l | tr -d ' ' || echo 0)"

        if (( total_count > 0 && running_count == total_count )); then
            healthy=true
            break
        fi

        _mv_log info "Waiting for containers to become healthy (${elapsed}s / ${max_wait}s)..."
        sleep "${poll_interval}"
        elapsed=$(( elapsed + poll_interval ))
    done

    if [[ "${healthy}" == "true" ]]; then
        _mv_state_write MIGRATION_COMPLETE "true"
        _mv_log success "All containers are running. Migration complete."
        _mv_print_checklist
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
    printf '  8. Check /etc/fstab for any stale entries referencing the old path:\n'
    printf '       grep -n '\''%s'\'' /etc/fstab\n' "${_MV_SOURCE}"
    printf '     Remove or update any entries that no longer apply.\n'
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

    # Step-by-step status table
    local -a steps=(
        "STEP_VALIDATE_DONE:Validate pre-flight"
        "STEP_BACKUP_DONE:Backup confirmation"
        "STEP_STOP_DONE:Stop stack"
        "STEP_FORMAT_DONE:Format/mount volume"
        "STEP_RSYNC_DONE:rsync transfer"
        "STEP_VERIFY_DONE:Verify byte count"
        "STEP_SOURCE_RENAMED_DONE:Rename source"
        "STEP_SOURCE_DELET