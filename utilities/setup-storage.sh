#!/usr/bin/env bash
# utilities/setup-storage.sh — Configures and migrates VaultWarden-OCI storage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"   # one level up from utilities/
cd "${PROJECT_ROOT}"

REQUIRED_LIBS=(lib/log.sh lib/config.sh lib/common.sh lib/storage.sh lib/docker.sh lib/backup-utils.sh lib/migrate.sh)
for _lib in "${REQUIRED_LIBS[@]}"; do
    [[ -f "${PROJECT_ROOT}/${_lib}" ]] || {
        echo "ERROR: Required library not found: ${PROJECT_ROOT}/${_lib}" >&2
        exit 1
    }
done
source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/config.sh"
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"
source "${PROJECT_ROOT}/lib/storage.sh"
source "${PROJECT_ROOT}/lib/docker.sh"
source "${PROJECT_ROOT}/lib/backup-utils.sh"
source "${PROJECT_ROOT}/lib/migrate.sh"

[[ -f "${PROJECT_ROOT}/.env" ]] && load_env_file "${PROJECT_ROOT}/.env"
export DRY_RUN=false   # overridden by arg parsing; exported for lib functions

_SS_MODE="setup"
_SS_DATA_DEVICE=""
_SS_DATA_MOUNT="/mnt/vw-data"
_SS_AUTO=false
_SS_FORCE=false
TMP_WORKDIR=""
declare -a _SS_MIGRATE_ARGS=()

_ss_on_err() {
    log_error "Unexpected error at line ${2:-?} (exit ${1:-?})."
}
trap '_ss_on_err $? $LINENO' ERR

_ss_cleanup() {
    rm -rf "${TMP_WORKDIR:-}"
}
trap '_ss_cleanup' EXIT

readonly _MV_VERSION="1.1.0"
_MV_SCRIPT_NAME="utilities/setup-storage.sh"
readonly _MV_SCRIPT_NAME

setup_directories() {
    if [[ "${DRY_RUN}" == "true" ]]; then log_info "[DRY RUN] Would setup directories"; return 0; fi

    # If a separate data volume is configured, assert it is mounted and valid
    # before we create any subdirectories inside it. This prevents accidentally
    # writing the directory skeleton onto the boot volume if the mount failed.
    export DATA_VOLUME_DEVICE="${DATA_VOLUME_DEVICE:-}"
    export DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}"
    # Align PROJECT_STATE_DIR with the storage mode so the consistency check
    # inside require_project_state_ready passes. In boot-only mode this is a no-op.
    if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then
        export PROJECT_STATE_DIR="${DATA_VOLUME_MOUNT}"
    else
        export PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}"
    fi
    require_project_state_ready || return 1

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -gn "$real_user")

    local secrets_dirs=("secrets" "secrets/keys" "secrets/.docker_secrets")
    for dir in "${secrets_dirs[@]}"; do
        ensure_dir "$dir" 700 || return 1
        chown "$real_user:$real_group" "$dir" || return 1
    done

    local puid; puid=$(id -u "$real_user")
    local pgid; pgid=$(id -g "$real_user")
    local project_state_dir="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}"

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
        {
            [[ -d "${project_state_dir}/${_dir}" ]] && \
                chown -R "${puid}:${pgid}" "${project_state_dir}/${_dir}"
        } || return 1
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

_mode_setup() {
    log_info "Mode: setup — provisioning data volume and directories"

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

    local project_state_dir="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}"
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

_parse_outer_args() {
    local -a remaining=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                _SS_MODE="$2"
                shift 2
                ;;
            --help|-h)
                # When --mode migrate has already been parsed, forward --help
                # to the migrate sub-parser so _mv_usage is shown, not _ss_usage.
                if [[ "${_SS_MODE}" == "migrate" ]]; then
                    remaining+=("$1")
                else
                    _ss_usage
                    exit 0
                fi
                shift
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

    if [[ "${_SS_MODE}" == "migrate" ]]; then
        _SS_MIGRATE_ARGS=("${remaining[@]+"${remaining[@]}"}")
        return 0
    fi

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
        migrate) migrate_mode_main "${_SS_MIGRATE_ARGS[@]+"${_SS_MIGRATE_ARGS[@]}"}" ;;
        *)
            log_error "Unknown mode: ${_SS_MODE}"
            _ss_usage
            exit 1
            ;;
    esac
}

main "$@"
