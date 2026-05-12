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
readonly _MV_VERSION="1.0.0"
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
    if [[ -z "${_MV_LOG_FILE:-}" ]]; then
        local log_dir
        # Use current PROJECT_STATE_DIR (pre-migration value) for the log directory.
        log_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/logs"
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
  --source  <path>   Source directory  (default: current PROJECT_STATE_DIR)
  --target  <path>   Destination directory or mount point  [required for run]
  --device  <dev>    Block device for new volume (e.g. /dev/sdb)
                     Omit if target is already mounted.
  --skip-stack-stop  Do not stop the Docker stack before migrating.
                     Requires explicit runtime confirmation. Use with caution.
  --delete-source    Delete renamed source after successful verification.
                     Always requires typing the path to confirm.
  --dry-run          Print all actions without executing them.
  --force            Skip the pre-migration backup confirmation prompt.
  --yes              Answer yes to all confirmations (except --delete-source).
  --log-file <path>  Override default log file path.
  --help             Show this help and exit.

EXAMPLES:
  # Boot volume → dedicated data volume
  sudo utilities/migrate-volume.sh run \
    --source /var/lib/vaultwarden \
    --target /mnt/vw-data \
    --device /dev/sdb

  # One data volume → another (already mounted)
  sudo utilities/migrate-volume.sh run \
    --source /mnt/vw-data \
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
            [[ -n "${_MV_TARGET}" ]] || {
                log_error "--target is required for the 'run' subcommand."
                exit 1
            }
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

    # 5. Source is not being written to by a running rsync
    if find /proc/*/fd -lname "${_MV_SOURCE}/*" -print0 2>/dev/null \
            | xargs -r -0 ls -l 2>/dev/null \
            | grep -q rsync; then
        _mv_log error "rsync appears to be actively writing to ${_MV_SOURCE}."
        _mv_log error "Wait for it to finish before migrating."
        return 1
    fi

    # 6. If --device given: validate device node
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

    # 7. Disk space check
    # Ensure target directory exists for df to work
    mkdir -p "${_MV_TARGET}" 2>/dev/null || true
    _mv_check_disk_space "${_MV_SOURCE}" "${_MV_TARGET}"

    # 8. Stale backup warning (non-blocking)
    _mv_check_stale_backup

    # 9. --skip-stack-stop with live containers: require explicit confirmation
    if [[ "${_MV_SKIP_STACK_STOP}" == "true" ]]; then
        local running_containers
        running_containers="$(docker compose ps --format json 2>/dev/null \
            | grep -c '"State":"running"' || true)"
        if (( running_containers > 0 )); then
            _mv_log warn "WARNING: ${running_containers} VaultWarden container(s) are currently running."
            _mv_log warn "Migrating a live stack risks SQLite WAL corruption."
            _mv_log warn "Data integrity cannot be guaranteed if the database is actively written."
            _mv_confirm_by_typing \
                "You are about to migrate a LIVE stack." \
                "LIVE"
        fi
    fi

    # 10. Confirm .env is readable and PROJECT_STATE_DIR key is present
    [[ -f "${PROJECT_ROOT}/.env" ]] || {
        _mv_log error ".env not found at: ${PROJECT_ROOT}/.env"
        return 1
    }
    grep -q "^PROJECT_STATE_DIR=" "${PROJECT_ROOT}/.env" 2>/dev/null || {
        _mv_log error "PROJECT_STATE_DIR key not found in .env"
        return 1
    }

    # 11. Confirm docker-compose.yml exists in PROJECT_ROOT
    [[ -f "${PROJECT_ROOT}/docker-compose.yml" ]] || {
        _mv_log error "docker-compose.yml not found at: ${PROJECT_ROOT}/docker-compose.yml"
        return 1
    }

    # Write migration metadata to state file
    if [[ "${DRY_RUN}" != "true" ]]; then
        _mv_state_write MV_SOURCE        "${_MV_SOURCE}"
        _mv_state_write MV_TARGET        "${_MV_TARGET}"
        _mv_state_write MV_DEVICE        "${_MV_DEVICE:-none}"
        _mv_state_write MV_START_TS      "$(date +%s)"
        _mv_state_write MV_LOG_FILE      "${_MV_LOG_FILE}"
        _mv_state_write MV_SKIP_STACK_STOP "${_MV_SKIP_STACK_STOP}"
        _mv_state_write MV_DELETE_SOURCE  "${_MV_DELETE_SOURCE}"
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
    docker compose ps --format json 2>/dev/null || true

    if [[ "${DRY_RUN}" == "true" ]]; then
        _mv_log info "[DRY RUN] would: stop VaultWarden stack (stop_services)"
        return 0
    fi

    stop_services   # from lib/docker.sh

    _mv_log info "Container state after stop:"
    docker compose ps --format json 2>/dev/null || true
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

    local renamed
    # Use a glob array and find the most recently modified matching directory.
    local candidate newest_ts=0 candidate_ts cand_renamed=""
    for candidate in "${_MV_SOURCE}.pre-migration."*/; do
        [[ -d "${candidate}" ]] || continue
        candidate_ts="$(stat -c '%Y' "${candidate}" 2>/dev/null || echo 0)"
        if (( candidate_ts > newest_ts )); then
            newest_ts="${candidate_ts}"
            cand_renamed="${candidate%/}"
        fi
    done
    renamed="${cand_renamed}"

    if [[ -z "${renamed}" || ! -d "${renamed}" ]]; then
        _mv_log warn "Renamed source not found — nothing to delete."
        return 0
    fi

    _mv_confirm_by_typing \
        "You are about to permanently delete: ${renamed}" \
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

    # Update BACKUP_DIR only if it was set to the default under the old state dir
    local current_backup_dir
    current_backup_dir="$(grep "^BACKUP_DIR=" "${env_file}" 2>/dev/null | cut -d= -f2- || true)"
    if [[ "${current_backup_dir}" == "${old_state_dir}/backups" ]]; then
        _mv_set_env_var BACKUP_DIR "${_MV_TARGET}/backups"
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
        _mv_log info "[DRY RUN] would: poll docker compose ps for healthy state (up to 120s)"
        _mv_state_write MIGRATION_COMPLETE "true"
        _mv_print_checklist
        return 0
    fi

    local max_wait=120
    local poll_interval=10
    local elapsed=0
    local healthy=false

    while (( elapsed < max_wait )); do
        local ps_out running_count
        ps_out="$(docker compose ps --format json 2>/dev/null || true)"
        # Count containers with State == running
        running_count="$(printf '%s' "${ps_out}" | grep -c '"State":"running"' || true)"
        local total_count
        total_count="$(printf '%s' "${ps_out}" | grep -c '"State":' || true)"

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
    printf '  6. After a satisfying reboot test, remove the renamed source:\n'
    printf '       sudo rm -rf '\''%s'\''\n' "${renamed_src}"
    printf '  7. (If you added custom services to docker-compose.yml with hardcoded\n'
    printf '     paths) Verify: docker compose config | grep '\''%s'\''\n' "${_MV_SOURCE}"
    printf '     Any remaining references must be updated manually.\n'
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
        "STEP_MOUNT_GUARD_DONE:Docker mount guard"
        "STEP_FORMAT_DONE:Format/mount volume"
        "STEP_RSYNC_DONE:rsync transfer"
        "STEP_VERIFY_DONE:Verify byte count"
        "STEP_SOURCE_RENAMED_DONE:Rename source"
        "STEP_SOURCE_DELETED_DONE:Delete source"
        "STEP_ENV_UPDATED_DONE:Update .env"
        "STEP_DROPIN_UPDATED_DONE:Update systemd drop-ins"
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
        log_warn "  sudo utilities/migrate-volume.sh resume"
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

    # ── Step 10 reverse: stop stack (started on new volume) ──────────────────
    if _mv_state_has STEP_START_DONE; then
        log_info "Rollback: stopping stack..."
        stop_services || log_warn "stop_services failed — continuing rollback."
    fi

    # ── Step 8 reverse: restore .env from backup ──────────────────────────────
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
        else
            log_warn ".env backup not found — manual restoration required."
            log_warn "Keys changed: PROJECT_STATE_DIR, DATA_VOLUME_MOUNT, DATA_VOLUME_DEVICE, BACKUP_DIR"
        fi
    fi

    # ── Step 6 reverse: restore renamed source ────────────────────────────────
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

    # ── Step 8 reverse: reload systemd after .env is back ─────────────────────
    if _mv_state_has STEP_DROPIN_UPDATED_DONE; then
        log_warn "systemd drop-ins were updated. To restore them, re-run:"
        log_warn "  sudo ./setup.sh systemd"
        systemctl daemon-reload || true
    fi

    # ── Step 9 reverse: restart stack from restored source ────────────────────
    log_info "Rollback: attempting to start stack from restored source..."
    load_env_file "${PROJECT_ROOT}/.env"
    start_services || log_warn "start_services failed — check manually: docker compose up -d"

    # ── Clear state file ──────────────────────────────────────────────────────
    _mv_state_clear
    log_success "State file cleared."
    log_warn "Review the rollback above carefully. Some steps may require manual intervention."
    log_warn "Check: docker compose ps"
}

# ── Pipeline orchestrator ─────────────────────────────────────────────────────
_mv_run_step() {
    # Usage: _mv_run_step <TOKEN> <function>
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
            log_error "No state file found. Cannot resume. Run: sudo utilities/migrate-volume.sh run ..."
            exit 1
        }
        # Restore source/target/device from state file
        _MV_SOURCE="$(_mv_state_read MV_SOURCE)"
        _MV_TARGET="$(_mv_state_read MV_TARGET)"
        _MV_DEVICE="$(_mv_state_read MV_DEVICE)"
        [[ "${_MV_DEVICE}" == "none" ]] && _MV_DEVICE=""
        _MV_SKIP_STACK_STOP="$(_mv_state_read MV_SKIP_STACK_STOP)"
        _MV_DELETE_SOURCE="$(_mv_state_read MV_DELETE_SOURCE)"
        log_info "Resuming migration: ${_MV_SOURCE} → ${_MV_TARGET}"
    fi

    # ── Execute pipeline steps in order ───────────────────────────────────────
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

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    _mv_require_root "$@"
    _mv_parse_args "$@"
    _mv_open_log

    # Register EXIT trap after log file is opened so elapsed time is always printed
    trap '_mv_cleanup' EXIT

    _mv_acquire_lock

    case "${_MV_SUBCOMMAND}" in
        run)     _mv_run_pipeline ;;
        resume)  _mv_run_pipeline --resume ;;
        status)  _mv_print_status ;;
        abort)   _mv_do_abort ;;
        verify)  _mv_step_verify ;;
        *)       _mv_usage; exit 1 ;;
    esac
}

main "$@"
