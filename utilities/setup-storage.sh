#!/usr/bin/env bash
# utilities/setup-storage.sh — Configures and migrates VaultWarden-OCI storage.
# shellcheck disable=SC1091

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"   # one level up from utilities/
cd "${PROJECT_ROOT}"

REQUIRED_LIBS=(lib/log.sh lib/config.sh lib/common.sh lib/operations.sh lib/storage.sh lib/docker.sh lib/backup-utils.sh lib/migrate.sh)
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
source "${PROJECT_ROOT}/lib/operations.sh"
source "${PROJECT_ROOT}/lib/storage.sh"
DOCKER_PROJECT_LABEL="${DOCKER_PROJECT_LABEL:-label=com.docker.compose.project=vaultwarden-oci}"
source "${PROJECT_ROOT}/lib/docker.sh"
source "${PROJECT_ROOT}/lib/backup-utils.sh"
source "${PROJECT_ROOT}/lib/migrate.sh"

export DRY_RUN=false   # overridden by arg parsing; exported for lib functions

_SS_MODE="setup"
_SS_DATA_DEVICE="${DATA_VOLUME_DEVICE:-}"
_SS_DATA_MOUNT="${DATA_VOLUME_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}"
_SS_DATA_DEVICE_PROVIDED=false
_SS_DATA_MOUNT_PROVIDED=false
_SS_AUTO=false
_SS_FORCE=false
TMP_WORKDIR=""
declare -a _SS_MODE_ARGS=()
declare -a _SS_MIGRATE_ARGS=()

_ss_on_err() {
    log_error "Unexpected error at line ${2:-?} (exit ${1:-?})."
}
trap '_ss_on_err $? $LINENO' ERR

_ss_cleanup() {
    rm -rf "${TMP_WORKDIR:-}"
}
trap '_ss_cleanup' EXIT

_ss_load_runtime_environment() {
    local installed_env="${VW_CONFIG_INSTALLED_ENV_FILE:-/etc/vaultwarden/vaultwarden.env}"
    if [[ -f "${PROJECT_ROOT}/.env" || -f "${installed_env}" || -f "${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}/config/install.env" ]]; then
        load_project_environment || {
            # setup-storage also supports first-run bootstrapping before runtime env exists.
            if [[ -f "${PROJECT_ROOT}/.env" ]]; then
                load_env_file "${PROJECT_ROOT}/.env" || true
            fi
        }
    fi

    if [[ "${_SS_DATA_DEVICE_PROVIDED}" != "true" ]]; then
        _SS_DATA_DEVICE="${DATA_VOLUME_DEVICE:-${_SS_DATA_DEVICE:-}}"
    fi
    if [[ "${_SS_DATA_MOUNT_PROVIDED}" != "true" ]]; then
        _SS_DATA_MOUNT="${DATA_VOLUME_MOUNT:-${_SS_DATA_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}}"
    fi
}

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

    local authoring_dirs=("secrets" "secrets/keys" "config")
    for dir in "${authoring_dirs[@]}"; do
        ensure_dir "$dir" 700 || return 1
        chown "$real_user:$real_group" "$dir" || return 1
    done

    local puid; puid=$(id -u "$real_user")
    local pgid; pgid=$(id -g "$real_user")
    local project_state_dir="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}"

    install -d -m 0700 -o root -g root "${project_state_dir}/config" "${project_state_dir}/secrets" || return 1
    [[ -e "${project_state_dir}/config/install.env" ]] && fix_known_path_permissions "${project_state_dir}/config/install.env"
    [[ -e "${project_state_dir}/secrets/secrets.yaml" ]] && fix_known_path_permissions "${project_state_dir}/secrets/secrets.yaml"

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

    # Only normalize non-sensitive mutable data trees.  Never broad-chmod
    # ${project_state_dir}/config or ${project_state_dir}/secrets; those are
    # root-operated state and have stricter central permissions.
    for _dir in data logs backups; do
        if [[ -d "${project_state_dir}/${_dir}" ]]; then
            find "${project_state_dir}/${_dir}" -type d -exec chmod 750 {} + 2>/dev/null || return 1
            find "${project_state_dir}/${_dir}" -type f -exec chmod 640 {} + 2>/dev/null || true
        fi
    done

    ensure_caddy_log_permissions "${project_state_dir}/logs/caddy" || return 1

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


_update_install_env_after_storage() {
    [[ "${DRY_RUN}" == "true" ]] && return 0

    local env_file="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}/config/install.env"
    if [[ ! -f "$env_file" ]]; then
        log_warn "Persistent install.env not found; skipping storage identity update: $env_file"
        return 0
    fi

    if [[ -z "${DATA_VOLUME_DEVICE:-}" ]]; then
        log_info "Boot-volume mode detected; preserving existing PROJECT_STATE_DIR in install.env"
        return 0
    fi

    if ! mountpoint -q "${DATA_VOLUME_MOUNT}"; then
        log_warn "Data volume mount is not active; skipping storage identity update: ${DATA_VOLUME_MOUNT}"
        return 0
    fi

    local source_dev uuid device_path
    if ! source_dev="$(findmnt -n -o SOURCE --target "${DATA_VOLUME_MOUNT}" 2>/dev/null)" || [[ -z "$source_dev" ]]; then
        log_warn "Could not resolve mounted source for ${DATA_VOLUME_MOUNT}; skipping storage identity update"
        return 0
    fi

    uuid="$(blkid -s UUID -o value "$source_dev" 2>/dev/null || true)"
    device_path="$source_dev"
    [[ -n "$uuid" && -e "/dev/disk/by-uuid/$uuid" ]] && device_path="/dev/disk/by-uuid/$uuid"

    _set_env_var PROJECT_STATE_DIR "${DATA_VOLUME_MOUNT}" "$env_file"
    _set_env_var DATA_VOLUME_MOUNT "${DATA_VOLUME_MOUNT}" "$env_file"
    _set_env_var DATA_VOLUME_DEVICE "$device_path" "$env_file"

    # Installed/root-operated runtime config always uses the canonical root-owned Age key.
    # Do not preserve repo-local/operator key paths into persistent install.env.
    _set_env_var SOPS_AGE_KEY_FILE "/etc/vaultwarden/age-key.txt" "$env_file"
}

_mode_setup() {
    log_info "Mode: setup — provisioning data volume and directories"

    export DATA_VOLUME_DEVICE="${_SS_DATA_DEVICE}"
    export DATA_VOLUME_MOUNT="${_SS_DATA_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}"
    if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then
        export PROJECT_STATE_DIR="${DATA_VOLUME_MOUNT}"
    fi

    setup_data_volume || return 1
    if [[ -z "${DATA_VOLUME_DEVICE:-}" ]]; then
        log_info "To use block storage, re-run with --data-device /dev/disk/by-id/... or set DATA_VOLUME_DEVICE in install.env/.env."
    fi
    # Install a Docker systemd drop-in that delays Docker start until the
    # data volume is mounted. No-op when DATA_VOLUME_DEVICE is unset.
    install_docker_mount_guard || log_warn "Docker mount guard setup had a non-fatal issue"
    setup_directories || return 1
    _update_install_env_after_storage || return 1

    log_success "Storage setup complete."
}

_ss_storage_help_text() {
    cat <<EOF

Storage setup choices
---------------------
Boot-volume mode stores persistent VaultWarden state under PROJECT_STATE_DIR
(currently: ${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}).

Block-storage mode uses a dedicated attached volume, normally mounted at
DATA_VOLUME_MOUNT (currently: ${_SS_DATA_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}).

If you intend to restore or migrate from attached block storage, choose
"Configure attached block storage" and provide the attached block device path.

This assistant will not auto-pick a disk and will not silently format a disk.
Any provisioning, adoption, formatting gates, fstab updates, mount guards, and
sentinel checks are handled later by the existing setup_data_volume safeguards.
EOF
}

_ss_show_block_devices() {
    log_info "Read-only block device summary:"
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -dpno NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL 2>/dev/null || \
            log_warn "Unable to list block devices with lsblk."
    else
        log_warn "lsblk not found; cannot show block device summary."
    fi
}

_ss_prompt_block_storage() {
    local device mount_point

    _ss_show_block_devices
    while true; do
        if ! read -r -t 300 -p "Enter attached block device path (for example /dev/disk/by-id/...): " device; then
            printf '\n' >&2
            log_error "No block device path received within 5 minutes. Storage setup was not changed."
            exit 1
        fi
        if [[ -z "${device}" ]]; then
            log_error "Block device path cannot be empty."
            continue
        fi
        if [[ ! -e "${device}" ]]; then
            log_error "Path does not exist: ${device}"
            continue
        fi
        if [[ ! -b "${device}" ]]; then
            log_error "Path is not a block device: ${device}"
            continue
        fi
        break
    done

    read -r -t 300 -p "Enter data volume mount point [${_SS_DATA_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}]: " mount_point || mount_point=""
    _SS_DATA_DEVICE="${device}"
    _SS_DATA_MOUNT="${mount_point:-${_SS_DATA_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}}"
    log_info "Attached block storage selected; setup_data_volume will validate and provision using existing safeguards."
}

_ss_should_run_storage_assistant() {
    [[ "${_SS_MODE}" == "setup" ]] || return 1
    [[ -t 0 ]] || return 1
    [[ "${DRY_RUN}" != "true" ]] || return 1
    [[ "${_SS_AUTO}" != "true" ]] || return 1
    [[ -z "${DATA_VOLUME_DEVICE:-}" ]] || return 1
    [[ -z "${_SS_DATA_DEVICE:-}" ]] || return 1
    [[ "${_SS_DATA_DEVICE_PROVIDED}" != "true" ]] || return 1
    return 0
}

_ss_storage_assistant() {
    local choice

    _ss_storage_help_text
    while true; do
        cat <<'EOF'

Choose storage setup mode:
  1) Continue with boot-volume mode
  2) Configure attached block storage
  3) Show storage help
  4) Exit without changes
EOF
        read -r -t 300 -p "Selection [1-4]: " choice || choice="4"
        case "${choice}" in
            1)
                log_info "Operator selected boot-volume mode; DATA_VOLUME_DEVICE remains unset."
                return 0
                ;;
            2)
                _ss_prompt_block_storage
                return 0
                ;;
            3)
                show_help
                _ss_storage_help_text
                ;;
            4)
                log_info "Storage setup cancelled by operator."
                exit 0
                ;;
            *)
                log_error "Invalid selection. Choose 1, 2, 3, or 4."
                ;;
        esac
    done
}

_ss_check_known_path() {
    local path="$1" label="${2:-$1}"
    if [[ ! -e "$path" ]]; then
        log_warn "Missing: ${label} (${path})"
        return 1
    fi
    if ! assert_known_path_permissions "$path"; then
        local owner group mode actual
        owner="$(expected_owner_for_path "$path" 2>/dev/null || printf '?')"
        group="$(expected_group_for_path "$path" 2>/dev/null || printf '?')"
        mode="$(expected_mode_for_path "$path" 2>/dev/null || printf '?')"
        actual="$(_common_stat_owner "$path"):$(_common_stat_group "$path") $(_common_stat_mode "$path")"
        log_warn "Permission drift: ${label} (${path}) actual=${actual} expected=${owner}:${group} ${mode}"
        return 1
    fi
    log_success "OK: ${label} (${path})"
}

_ss_check_mode_owner() {
    local path="$1" type="$2" owner="$3" group="$4" mode="$5"
    if [[ "$type" == "dir" && ! -d "$path" ]] || [[ "$type" == "file" && ! -f "$path" ]]; then
        log_warn "Missing ${type}: ${path}"
        return 1
    fi
    local actual_owner actual_group actual_mode
    actual_owner="$(_common_stat_owner "$path")"
    actual_group="$(_common_stat_group "$path")"
    actual_mode="$(_common_stat_mode "$path")"
    if [[ "${actual_owner}:${actual_group}" != "${owner}:${group}" || "${actual_mode}" != "$mode" ]]; then
        log_warn "Permission drift: ${path} actual=${actual_owner}:${actual_group} ${actual_mode} expected=${owner}:${group} ${mode}"
        return 1
    fi
    log_success "OK: ${path}"
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

    _ss_check_known_path "${project_state_dir}/config" "persistent config dir" || (( errors++ )) || true
    _ss_check_known_path "${project_state_dir}/secrets" "persistent secrets dir" || (( errors++ )) || true
    if [[ -e "${project_state_dir}/config/install.env" ]]; then _ss_check_known_path "${project_state_dir}/config/install.env" "install.env" || (( errors++ )) || true; fi
    if [[ -e "${project_state_dir}/config/dr-manifest.env" ]]; then _ss_check_known_path "${project_state_dir}/config/dr-manifest.env" "dr-manifest.env" || (( errors++ )) || true; fi
    if [[ -e "${project_state_dir}/secrets/secrets.yaml" ]]; then _ss_check_known_path "${project_state_dir}/secrets/secrets.yaml" "persistent secrets.yaml" || (( errors++ )) || true; fi

    _ss_check_mode_owner "${project_state_dir}/logs/caddy" dir root root 755 || (( errors++ )) || true
    _ss_check_mode_owner "${project_state_dir}/logs/caddy/access.log" file root root 644 || (( errors++ )) || true
    _ss_check_mode_owner "${project_state_dir}/logs/caddy/security.log" file root root 644 || (( errors++ )) || true

    if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then
        [[ "${PROJECT_STATE_DIR:-}" == "${DATA_VOLUME_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}" ]] || { log_warn "PROJECT_STATE_DIR/DATA_VOLUME_MOUNT mismatch"; (( errors++ )) || true; }
        mountpoint -q "${DATA_VOLUME_MOUNT}" 2>/dev/null || { log_warn "Data volume is not mounted: ${DATA_VOLUME_MOUNT}"; (( errors++ )) || true; }
        [[ -f "${DATA_VOLUME_MOUNT}/.vw-data-volume" ]] || { log_warn "Missing data-volume sentinel: ${DATA_VOLUME_MOUNT}/.vw-data-volume"; (( errors++ )) || true; }
    fi

    if (( errors == 0 )); then
        log_success "Storage verification passed"
        return 0
    fi
    log_error "Storage verification failed: ${errors} issue(s) found"
    return 1
}

show_help() {
cat << 'EOF' | sed "s|@DEFAULT_DATA_MOUNT@|${_VW_DEFAULT_DATA_MOUNT}|g"
VaultWarden-OCI Storage Setup and Migration

USAGE:
    sudo utilities/setup-storage.sh setup [OPTIONS]
    sudo utilities/setup-storage.sh verify [OPTIONS]
    sudo utilities/setup-storage.sh migrate <subcommand> [OPTIONS]
    sudo utilities/setup-storage.sh [--mode setup|migrate|verify] [OPTIONS]  # compatibility

DESCRIPTION:
    Configures persistent storage directories, optional data-volume
    provisioning, and interactive data migration. Called automatically by
    setup.sh phase 4. Safe to re-run (idempotent) in setup and verify modes.
    When setup-storage is run interactively with no --data-device or
    DATA_VOLUME_DEVICE, setup mode asks whether to continue boot-volume mode or
    configure block storage. --auto suppresses the prompt and keeps boot-volume
    behavior when no DATA_VOLUME_DEVICE is set.

MODES:
    setup    Create and configure storage directories (default)
    migrate  Migrate from boot volume to data volume (interactive)
    verify   Re-check layout and permissions only (no changes, safe for cron)

OPTIONS:
    --mode MODE           Compatibility alias for setup|migrate|verify
    --data-device DEV     Block device for data volume (e.g. /dev/disk/by-id/...)
    --data-mount PATH     Mount point for data volume (default: @DEFAULT_DATA_MOUNT@)
    --auto                Non-interactive mode; suppresses the storage assistant and
                          keeps boot-volume behavior when no DATA_VOLUME_DEVICE is set
    --dry-run             Preview actions without executing
    --force               Skip confirmations
    --help, -h            Show this help
    --version, -V         Print the VaultWarden-OCI version and exit

EXAMPLES:
    # Interactive setup: asks whether to use boot-volume or block storage
    sudo utilities/setup-storage.sh setup

    # Non-interactive boot-only setup (no separate data volume)
    sudo utilities/setup-storage.sh setup --auto

    # Setup with a dedicated data volume
    sudo utilities/setup-storage.sh setup \
      --data-device /dev/disk/by-id/your-volume \
      --data-mount @DEFAULT_DATA_MOUNT@

    # Dry run setup
    sudo utilities/setup-storage.sh setup --dry-run

    # Verify current layout (safe for cron)
    sudo utilities/setup-storage.sh verify

    # Interactive migration
    sudo utilities/setup-storage.sh migrate run
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

_parse_outer_args() {
    local -a remaining=()
    local mode_seen=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            setup|verify|migrate)
                if [[ "$mode_seen" == "true" && "${_SS_MODE}" == "migrate" ]]; then
                    remaining+=("$1")
                    shift
                    continue
                fi
                if [[ "$mode_seen" == "true" || ${#remaining[@]} -gt 0 ]]; then
                    log_error "Exactly one setup-storage mode is allowed: setup | verify | migrate"
                    show_help
                    exit 2
                fi
                _SS_MODE="$1"
                mode_seen=true
                shift
                ;;
            --mode)
                _require_cli_value "$1" "${2-}"
                if [[ "$mode_seen" == "true" || ${#remaining[@]} -gt 0 ]]; then
                    log_error "Exactly one setup-storage mode is allowed: setup | verify | migrate"
                    show_help
                    exit 2
                fi
                _SS_MODE="$2"
                mode_seen=true
                shift 2
                ;;
            --help|-h)
                # When --mode migrate has already been parsed, forward --help
                # to the migrate sub-parser so _mv_usage is shown, not show_help.
                if [[ "${_SS_MODE}" == "migrate" ]]; then
                    remaining+=("$1")
                else
                    show_help
                    exit 0
                fi
                shift
                ;;
            --version|-V)
                print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"
                exit 0
                ;;
            help)
                show_help
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
            show_help
            exit 1
            ;;
    esac

    _SS_MODE_ARGS=("${remaining[@]+"${remaining[@]}"}")
    [[ "${_SS_MODE}" == "migrate" ]] && _SS_MIGRATE_ARGS=("${_SS_MODE_ARGS[@]+"${_SS_MODE_ARGS[@]}"}")
    return 0
}

_parse_setup_args() {
    set -- "${_SS_MODE_ARGS[@]+"${_SS_MODE_ARGS[@]}"}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --data-device)
                _require_cli_value "$1" "${2-}"
                _SS_DATA_DEVICE="$2"
                _SS_DATA_DEVICE_PROVIDED=true
                shift 2
                ;;
            --data-mount)
                _require_cli_value "$1" "${2-}"
                _SS_DATA_MOUNT="$2"
                _SS_DATA_MOUNT_PROVIDED=true
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
            --version|-V)
                print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

main() {
    _parse_outer_args "$@"

    if [[ "${_SS_MODE}" == "migrate" ]]; then
        local _ss_migrate_arg
        for _ss_migrate_arg in "${_SS_MIGRATE_ARGS[@]+"${_SS_MIGRATE_ARGS[@]}"}"; do
            case "$_ss_migrate_arg" in
                help|--help|-h|--version|-V)
                    case "$_ss_migrate_arg" in
                        help|--help|-h)
                            _mv_usage
                            ;;
                        --version|-V)
                            print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"
                            ;;
                    esac
                    exit $?
                    ;;
            esac
        done
    fi

    _ss_load_runtime_environment

    if [[ "${_SS_MODE}" == "migrate" ]]; then
        _mv_parse_args "${_SS_MIGRATE_ARGS[@]+"${_SS_MIGRATE_ARGS[@]}"}"
    else
        _parse_setup_args
    fi

    (( EUID == 0 )) || {
        log_error "This script must be run as root: sudo utilities/setup-storage.sh $*"
        exit 1
    }

    if [[ "$DRY_RUN" != "true" ]]; then
        case "${_SS_MODE}" in
            setup)
                operation_acquire --id storage-setup --label "Storage setup" || exit $?
                operation_set_phase "setup" "Storage setup"
                ;;
            migrate)
                operation_acquire --id storage-migration --label "Storage migration" || exit $?
                operation_set_phase "migrate" "Storage migration"
                ;;
        esac
        trap 'rc=$?; operation_release "$rc"; _ss_cleanup; exit "$rc"' EXIT
        trap 'operation_release 130; _ss_cleanup; exit 130' INT
        trap 'operation_release 143; _ss_cleanup; exit 143' HUP TERM
    fi

    TMP_WORKDIR="$(mktemp -d -p "${PROJECT_ROOT}" vw_storage_tmp.XXXXXXXXXX)"

    if _ss_should_run_storage_assistant; then
        _ss_storage_assistant
    fi

    case "${_SS_MODE}" in
        setup)   _mode_setup   ;;
        verify)  _mode_verify  ;;
        migrate)
            _mv_resolve_args
            migrate_mode_main
            ;;
        *)
            log_error "Unknown mode: ${_SS_MODE}"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
