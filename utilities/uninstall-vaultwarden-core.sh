#!/usr/bin/env bash
# utilities/uninstall-vaultwarden.sh — Remove VaultWarden-OCI managed artifacts.
#
# Small-team policy: remove artifacts with clear VaultWarden ownership and preserve
# shared or ambiguous host infrastructure. In particular, a separate block-storage
# filesystem is detached but never bulk-erased by this uninstaller.

set -euo pipefail

PROJECT_ROOT_FALLBACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${PROJECT_ROOT_FALLBACK}/lib/defaults.sh" ]]; then
    # shellcheck source=../lib/defaults.sh
    source "${PROJECT_ROOT_FALLBACK}/lib/defaults.sh"
fi

if [[ -f "${PROJECT_ROOT_FALLBACK}/lib/log.sh" ]]; then
    # shellcheck source=../lib/log.sh
    source "${PROJECT_ROOT_FALLBACK}/lib/log.sh"
    _VW_CALLING_SCRIPT="$(basename "${BASH_SOURCE[0]}")"
else
    _VW_SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
    _C_CYAN='' _C_GREEN='' _C_YELLOW='' _C_RED='' _C_BLUE='' _C_MAGENTA='' _C_BOLD='' _C_RESET=''
    _vw_ts() { [[ -t 1 ]] && date '+%H:%M:%S' || date '+%Y-%m-%dT%H:%M:%S%z'; }
    _vw_dry_prefix() { [[ "${DRY_RUN:-false}" == "true" ]] && printf '[DRY RUN] ' || true; }
    log_info()     { printf '[%s] [%s] INFO %s%s\n' "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$(_vw_dry_prefix)" "$*"; }
    log_success()  { printf '[%s] [%s] OK %s%s\n' "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$(_vw_dry_prefix)" "$*"; }
    log_warn()     { printf '[%s] [%s] WARN %s%s\n' "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$(_vw_dry_prefix)" "$*" >&2; }
    log_error()    { printf '[%s] [%s] ERROR %s\n' "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$*" >&2; }
    log_debug()    { printf '[%s] [%s] DEBUG %s\n' "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$*"; }
    log_hint()     { printf '[%s] [%s] HINT -> %s%s\n' "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$(_vw_dry_prefix)" "$*"; }
    log_rollback() { printf '[%s] [%s] ROLLBACK %s\n' "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$*" >&2; }
    log_dry_run()  { printf '[%s] [%s] [DRY RUN] %s\n' "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$*"; }
fi

if [[ -f "${PROJECT_ROOT_FALLBACK}/lib/common.sh" ]]; then
    # shellcheck source=../lib/common.sh
    source "${PROJECT_ROOT_FALLBACK}/lib/common.sh"
    init_common_lib "$0"
fi
if [[ -f "${PROJECT_ROOT_FALLBACK}/lib/operations.sh" ]]; then
    # shellcheck source=../lib/operations.sh
    source "${PROJECT_ROOT_FALLBACK}/lib/operations.sh"
fi

die()     { log_error "$*"; exit 1; }
info()    { log_info "$@"; }
success() { log_success "$@"; }
warn()    { log_warn "$@"; }

I_HAVE_SAVED_RECOVERY_KIT=false
FORCE=false
DRY_RUN=false
TEST_RESET=false
UNINSTALL_OPERATION_HELD=false
UNINSTALL_CONFIG_SOURCE=""
DATA_VOLUME_IDENTITY_VERIFIED=false

_uninstall_err_trap() {
    local rc=$?
    log_error "${BASH_SOURCE[0]}: failed at line ${BASH_LINENO[0]} (exit ${rc})"
    exit "$rc"
}
trap _uninstall_err_trap ERR

_release_uninstall_operation() {
    local rc="${1:-0}"
    [[ "$UNINSTALL_OPERATION_HELD" == "true" ]] || return 0
    if declare -f operation_release >/dev/null 2>&1; then
        operation_release "$rc" || true
    fi
    UNINSTALL_OPERATION_HELD=false
}

_uninstall_exit_trap() {
    local rc=$?
    trap - EXIT
    _release_uninstall_operation "$rc"
    exit "$rc"
}

show_help() {
    cat <<'EOH'
VaultWarden-OCI Uninstall

USAGE:
    sudo bash ./utilities/uninstall-vaultwarden.sh run [OPTIONS]

DESCRIPTION:
    Removes VaultWarden-OCI artifacts that can be positively attributed to this
    project while preserving shared or ambiguous host infrastructure:
      - Docker Compose stack objects carrying this project's Compose label
      - VaultWarden systemd timers/services/drop-ins and recovery cleanup jobs
      - /opt/vaultwarden-scripts, /etc/vaultwarden, runtime secrets/state
      - root-only credential/recovery handoffs after explicit recovery confirmation
      - boot-volume VaultWarden state, or separate-volume mount/fstab wiring
      - marked VaultWarden CrowdSec email integration
      - UFW rules carrying VaultWarden Cloudflare comments

    Separate block-storage contents are ALWAYS preserved. The volume is verified,
    detached from host boot wiring, and unmounted; the filesystem is not bulk-erased.

    Docker packages/data, CrowdSec engine/bouncers/config/state, OS identities,
    unmarked UFW/raw netfilter rules, ambiguous host settings, external backups,
    and common administrator tooling are intentionally preserved.

SUBCOMMANDS:
    run    Perform the idempotent uninstall
    help   Show this help

OPTIONS (used after 'run'):
    --test-reset
        Remove generated installation artifacts but preserve the Git checkout so
        the same branch can be installed again immediately. On a dedicated test VM,
        this also resets /swapfile, its fstab entry, the exact vm.swappiness=10
        line, and the setup fallback universe source.

    --i-have-saved-my-recovery-kit
        Explicitly confirm that managed Age keys and local credential/recovery
        handoffs may be deleted because recovery material exists outside this host.
        Required when such material exists, unless --force is used.

    --dry-run
        Show the cleanup scope without changing the system. Does not require root.

    --force
        DANGEROUS: non-interactive mode. Skips uninstall, backup, and recovery
        prompts. It never authorizes deletion of separate block-storage contents,
        external backups, shared CrowdSec state, or ambiguous host firewall rules.

    --version, -V
        Print the VaultWarden-OCI version and exit.

EXAMPLES:
    sudo bash ./utilities/uninstall-vaultwarden.sh run --dry-run
    sudo bash ./utilities/uninstall-vaultwarden.sh run --test-reset --dry-run
    sudo bash ./utilities/uninstall-vaultwarden.sh run --test-reset --i-have-saved-my-recovery-kit
    sudo bash ./utilities/uninstall-vaultwarden.sh run --i-have-saved-my-recovery-kit
    sudo bash ./utilities/uninstall-vaultwarden.sh run --force
EOH
}

if [[ $# -eq 0 ]]; then
    show_help
    exit 1
fi

case "$1" in
    run)
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --i-have-saved-my-recovery-kit) I_HAVE_SAVED_RECOVERY_KIT=true; shift ;;
                --test-reset) TEST_RESET=true; shift ;;
                --force) FORCE=true; I_HAVE_SAVED_RECOVERY_KIT=true; shift ;;
                --dry-run) DRY_RUN=true; shift ;;
                --version|-V)
                    if command -v print_project_version >/dev/null 2>&1; then
                        print_project_version "VaultWarden-OCI" "${PROJECT_ROOT_FALLBACK}"
                    else
                        printf 'VaultWarden-OCI %s\n' "$(tr -d '[:space:]' < "${PROJECT_ROOT_FALLBACK}/VERSION" 2>/dev/null || echo unknown)"
                    fi
                    exit 0
                    ;;
                *) log_error "Unknown option: '$1'"; show_help; exit 1 ;;
            esac
        done
        ;;
    help|--help|-h)
        show_help
        exit 0
        ;;
    --version|-V)
        if command -v print_project_version >/dev/null 2>&1; then
            print_project_version "VaultWarden-OCI" "${PROJECT_ROOT_FALLBACK}"
        else
            printf 'VaultWarden-OCI %s\n' "$(tr -d '[:space:]' < "${PROJECT_ROOT_FALLBACK}/VERSION" 2>/dev/null || echo unknown)"
        fi
        exit 0
        ;;
    *) log_error "Unknown subcommand: '$1'"; show_help; exit 1 ;;
esac

if [[ "$DRY_RUN" != "true" ]]; then
    [[ $EUID -eq 0 ]] || die "Live uninstall requires root: sudo bash $0 run (use run --dry-run for a non-mutating preview)"
fi

REAL_USER="${SUDO_USER:-${USER:-ubuntu}}"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6 || true)"
REAL_HOME="${REAL_HOME:-/home/$REAL_USER}"

PROJECT_DIR="${PROJECT_ROOT_FALLBACK}"
PROJECT_BASENAME="$(basename "$PROJECT_DIR")"

INSTALLED_ENV="/etc/vaultwarden/vaultwarden.env"
DEFAULT_STATE_DIR="${_VW_DEFAULT_STATE_DIR:-/var/lib/vaultwarden}"
DEFAULT_DATA_MOUNT="${_VW_DEFAULT_DATA_MOUNT:-/mnt/vw-data}"
FSTAB_FILE="${VW_UNINSTALL_FSTAB:-/etc/fstab}"
SYSCTL_CONF="${VW_UNINSTALL_SYSCTL_CONF:-/etc/sysctl.conf}"
SWAPFILE_PATH="${VW_UNINSTALL_SWAPFILE:-/swapfile}"
SOPS_BIN="${VW_UNINSTALL_SOPS_BIN:-/usr/local/bin/sops}"
SYSTEMD_SYSTEM_DIR="${VW_UNINSTALL_SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"
DOCKER_MOUNT_GUARD_DIR="${SYSTEMD_SYSTEM_DIR}/docker.service.d"
DOCKER_MOUNT_GUARD="${DOCKER_MOUNT_GUARD_DIR}/10-vaultwarden-data-volume.conf"
RUNTIME_DIR="${VW_UNINSTALL_RUNTIME_DIR:-/run/vaultwarden-oci}"
RECOVERY_HANDOFF_DIR="${VW_UNINSTALL_RECOVERY_HANDOFF_DIR:-/root/vaultwarden-recovery}"
APT_SOURCE_UNIVERSE="${VW_UNINSTALL_APT_SOURCE_UNIVERSE:-/etc/apt/sources.list.d/ubuntu-universe.list}"
OPT_SCRIPTS_DIR="${VW_UNINSTALL_OPT_SCRIPTS_DIR:-/opt/vaultwarden-scripts}"
ETC_VAULTWARDEN_DIR="${VW_UNINSTALL_ETC_VAULTWARDEN_DIR:-/etc/vaultwarden}"
CROWDSEC_ETC_DIR="${VW_UNINSTALL_CROWDSEC_ETC_DIR:-/etc/crowdsec}"
CROWDSEC_EMAIL_PLUGIN="${VW_UNINSTALL_CROWDSEC_EMAIL_PLUGIN:-${CROWDSEC_ETC_DIR}/notifications/vaultwarden-email.yaml}"
CROWDSEC_EMAIL_PROFILES="${VW_UNINSTALL_CROWDSEC_EMAIL_PROFILES:-${CROWDSEC_ETC_DIR}/profiles.yaml.local}"
CROWDSEC_EMAIL_PLUGIN_MARKER="# Managed by VaultWarden-OCI: CrowdSec email notification"
CROWDSEC_EMAIL_PROFILE_BEGIN="# BEGIN VaultWarden-OCI CrowdSec email notifications"
CROWDSEC_EMAIL_PROFILE_END="# END VaultWarden-OCI CrowdSec email notifications"

MANAGED_TIMERS=(
    vaultwarden-maintenance.timer
    vaultwarden-db-backup.timer
    vaultwarden-full-backup.timer
    vaultwarden-health.timer
    vaultwarden-dns-update.timer
    vaultwarden-firewall-update.timer
)

MANAGED_SERVICES=(
    vaultwarden-maintenance.service
    vaultwarden-db-backup.service
    vaultwarden-full-backup.service
    vaultwarden-health.service
    vaultwarden-dns-update.service
    vaultwarden-firewall-update.service
    vaultwarden-notify-failure.service
    vaultwarden-notify-failure@.service
    vaultwarden-iptables.service
    vaultwarden-startup.service
)

MANAGED_CONTAINERS=(
    vaultwarden_init
    vaultwarden_app
    vaultwarden_caddy
    vaultwarden_postfix
)

MANAGED_NETWORKS=(
    vaultwarden_network
    vaultwarden_egress_network
    caddy_external_network
    postfix_relay_network
)

_read_env_value() {
    local key="$1" file="$2"
    [[ -f "$file" ]] || return 0
    awk -F= -v key="$key" '
        $1 == key {
            value = substr($0, index($0, "=") + 1)
            gsub(/^["'"'"']|["'"'"']$/, "", value)
            found = value
        }
        END { if (found != "") print found }
    ' "$file" 2>/dev/null || true
}

_env_candidate_score() {
    local file="$1" score=0
    [[ -f "$file" ]] || { printf '%s\n' -1; return 0; }
    [[ -n "$(_read_env_value PROJECT_STATE_DIR "$file")" ]] && score=$((score + 2))
    [[ -n "$(_read_env_value DATA_VOLUME_MOUNT "$file")" ]] && score=$((score + 2))
    [[ -n "$(_read_env_value DATA_VOLUME_DEVICE "$file")" ]] && score=$((score + 4))
    [[ -n "$(_read_env_value BACKUP_DIR "$file")" ]] && score=$((score + 1))
    printf '%s\n' "$score"
}

_env_candidates_for_bootstrap() {
    # Use one coherent file rather than composing individual keys from unrelated
    # snapshots. Persistent runtime/install state is preferred over repo-local .env.
    local repo_env="${PROJECT_DIR}/.env"
    local state mount

    if [[ -f "$INSTALLED_ENV" ]]; then
        printf '%s\n' "$INSTALLED_ENV"
        state="$(_read_env_value PROJECT_STATE_DIR "$INSTALLED_ENV")"
        mount="$(_read_env_value DATA_VOLUME_MOUNT "$INSTALLED_ENV")"
        [[ -n "$state" && -f "$state/config/install.env" ]] && printf '%s\n' "$state/config/install.env"
        [[ -n "$mount" && "$mount" != "$state" && -f "$mount/config/install.env" ]] && printf '%s\n' "$mount/config/install.env"
    fi

    if [[ -f "$repo_env" ]]; then
        state="$(_read_env_value PROJECT_STATE_DIR "$repo_env")"
        mount="$(_read_env_value DATA_VOLUME_MOUNT "$repo_env")"
        [[ -n "$state" && -f "$state/config/install.env" ]] && printf '%s\n' "$state/config/install.env"
        [[ -n "$mount" && "$mount" != "$state" && -f "$mount/config/install.env" ]] && printf '%s\n' "$mount/config/install.env"
    fi

    [[ -f "$DEFAULT_STATE_DIR/config/install.env" ]] && printf '%s\n' "$DEFAULT_STATE_DIR/config/install.env"
    [[ "$DEFAULT_DATA_MOUNT" != "$DEFAULT_STATE_DIR" && -f "$DEFAULT_DATA_MOUNT/config/install.env" ]] \
        && printf '%s\n' "$DEFAULT_DATA_MOUNT/config/install.env"
    [[ -f "$repo_env" ]] && printf '%s\n' "$repo_env"
}

_unique_lines() { awk 'NF && !seen[$0]++'; }

_canonical_path() {
    local path="$1"
    [[ -n "$path" ]] || return 1
    if command -v realpath >/dev/null 2>&1; then
        realpath -m -- "$path" 2>/dev/null
    else
        readlink -m -- "$path" 2>/dev/null
    fi
}

_path_is_inside() {
    local child="$1" parent="$2" canonical_child canonical_parent
    canonical_child="$(_canonical_path "$child")" || return 1
    canonical_parent="$(_canonical_path "$parent")" || return 1
    [[ "$canonical_child" == "$canonical_parent" || "$canonical_child" == "$canonical_parent"/* ]]
}

_paths_equivalent() {
    local left="$1" right="$2" canonical_left canonical_right
    [[ "$left" == "$right" ]] && return 0
    canonical_left="$(_canonical_path "$left")" || return 1
    canonical_right="$(_canonical_path "$right")" || return 1
    [[ "$canonical_left" == "$canonical_right" ]]
}

_device_uuid_for_path() {
    local device="$1"
    [[ -n "$device" ]] || return 1
    command -v blkid >/dev/null 2>&1 || return 1
    blkid -o value -s UUID "$device" 2>/dev/null | head -1
}

_devices_equivalent() {
    local left="$1" right="$2" resolved_left="" resolved_right="" uuid_left="" uuid_right=""
    [[ -n "$left" && -n "$right" ]] || return 1
    [[ "$left" == "$right" ]] && return 0
    resolved_left="$(readlink -f -- "$left" 2>/dev/null || true)"
    resolved_right="$(readlink -f -- "$right" 2>/dev/null || true)"
    [[ -n "$resolved_left" && -n "$resolved_right" && "$resolved_left" == "$resolved_right" ]] && return 0
    uuid_left="$(_device_uuid_for_path "$left" 2>/dev/null || true)"
    uuid_right="$(_device_uuid_for_path "$right" 2>/dev/null || true)"
    [[ -n "$uuid_left" && "$uuid_left" == "$uuid_right" ]]
}

_sentinel_value() {
    local key="$1" file="$2"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    awk -F: -v key="$key" '
        $1 == key {
            value = substr($0, index($0, ":") + 1)
            sub(/^[[:space:]]+/, "", value)
            print value
            exit
        }
    ' "$file"
}

_inspect_data_volume_identity() {
    local sentinel="${DATA_VOLUME_MOUNT}/.vw-data-volume"
    local source="" configured_uuid="" source_uuid="" sentinel_device="" sentinel_mount="" sentinel_uuid=""
    local owner_uid="" owner_gid="" mode=""

    DATA_VOLUME_IDENTITY_VERIFIED=false
    [[ -n "${DATA_VOLUME_DEVICE:-}" && -n "${DATA_VOLUME_MOUNT:-}" ]] || return 1
    mountpoint -q "$DATA_VOLUME_MOUNT" 2>/dev/null || return 1
    [[ -f "$sentinel" && ! -L "$sentinel" ]] || return 1
    [[ "$(head -1 "$sentinel" 2>/dev/null || true)" == "VaultWarden-OCI data volume" ]] || {
        warn "Data-volume sentinel header is invalid: $sentinel"
        return 1
    }

    owner_uid="$(stat -c '%u' "$sentinel" 2>/dev/null || true)"
    owner_gid="$(stat -c '%g' "$sentinel" 2>/dev/null || true)"
    mode="$(stat -c '%a' "$sentinel" 2>/dev/null || true)"
    if [[ "$owner_uid" != "0" || "$owner_gid" != "0" || "$mode" != "444" ]]; then
        warn "Data-volume sentinel metadata has drifted (uid=${owner_uid:-?} gid=${owner_gid:-?} mode=${mode:-?}); continuing with device-identity verification."
    fi

    source="$(findmnt -n -o SOURCE --target "$DATA_VOLUME_MOUNT" 2>/dev/null || true)"
    [[ -n "$source" ]] || { warn "Cannot resolve mounted source for $DATA_VOLUME_MOUNT"; return 1; }
    _devices_equivalent "$DATA_VOLUME_DEVICE" "$source" || {
        warn "Mounted source does not match DATA_VOLUME_DEVICE: configured=$DATA_VOLUME_DEVICE mounted=$source"
        return 1
    }

    configured_uuid="$(_device_uuid_for_path "$DATA_VOLUME_DEVICE" 2>/dev/null || true)"
    source_uuid="$(_device_uuid_for_path "$source" 2>/dev/null || true)"
    if [[ -n "$configured_uuid" || -n "$source_uuid" ]]; then
        [[ -n "$configured_uuid" && "$configured_uuid" == "$source_uuid" ]] || {
            warn "Configured and mounted data-volume UUIDs do not match: configured=${configured_uuid:-<unknown>} mounted=${source_uuid:-<unknown>}"
            return 1
        }
    fi

    sentinel_mount="$(_sentinel_value Mounted "$sentinel" 2>/dev/null || true)"
    [[ -z "$sentinel_mount" ]] || _paths_equivalent "$sentinel_mount" "$DATA_VOLUME_MOUNT" || {
        warn "Data-volume sentinel mount does not match configured mount: sentinel=$sentinel_mount configured=$DATA_VOLUME_MOUNT"
        return 1
    }

    sentinel_device="$(_sentinel_value Device "$sentinel" 2>/dev/null || true)"
    if [[ -n "$sentinel_device" && ( -e "$sentinel_device" || -L "$sentinel_device" ) ]]; then
        _devices_equivalent "$sentinel_device" "$source" || {
            warn "Data-volume sentinel device does not match mounted source: sentinel=$sentinel_device mounted=$source"
            return 1
        }
    fi

    sentinel_uuid="$(_sentinel_value UUID "$sentinel" 2>/dev/null || true)"
    if [[ -n "$sentinel_uuid" && -n "$source_uuid" && "$sentinel_uuid" != "$source_uuid" ]]; then
        warn "Data-volume sentinel UUID does not match mounted source UUID."
        return 1
    fi

    DATA_VOLUME_IDENTITY_VERIFIED=true
    return 0
}

_state_dir_has_managed_evidence() {
    local state_dir="$1"
    [[ -n "$state_dir" && "$state_dir" == /* ]] || return 1
    _paths_equivalent "$state_dir" "$DEFAULT_STATE_DIR" && return 0
    [[ -f "$state_dir/config/install.env" \
       || -f "$state_dir/secrets/secrets.yaml" \
       || -f "$state_dir/data/db.sqlite3" \
       || -d "$state_dir/logs/vaultwarden" \
       || -d "$state_dir/caddy" ]]
}

resolve_paths() {
    local env_file="" p
    PROJECT_STATE_DIR=""
    DATA_VOLUME_MOUNT=""
    DATA_VOLUME_DEVICE=""
    SOPS_AGE_KEY_FILE_ENV=""
    AGE_KEY_FILE_ENV=""
    BACKUP_DIR=""
    COMPOSE_PROJECT_NAME_ENV=""
    UNINSTALL_CONFIG_SOURCE=""

    local best_score=-1 score
    while IFS= read -r env_file; do
        [[ -f "$env_file" ]] || continue
        score="$(_env_candidate_score "$env_file")"
        if (( score > best_score )); then
            best_score=$score
            UNINSTALL_CONFIG_SOURCE="$env_file"
        fi
    done < <(_env_candidates_for_bootstrap | _unique_lines)

    if [[ -n "$UNINSTALL_CONFIG_SOURCE" ]]; then
        PROJECT_STATE_DIR="$(_read_env_value PROJECT_STATE_DIR "$UNINSTALL_CONFIG_SOURCE")"
        DATA_VOLUME_MOUNT="$(_read_env_value DATA_VOLUME_MOUNT "$UNINSTALL_CONFIG_SOURCE")"
        DATA_VOLUME_DEVICE="$(_read_env_value DATA_VOLUME_DEVICE "$UNINSTALL_CONFIG_SOURCE")"
        SOPS_AGE_KEY_FILE_ENV="$(_read_env_value SOPS_AGE_KEY_FILE "$UNINSTALL_CONFIG_SOURCE")"
        AGE_KEY_FILE_ENV="$(_read_env_value AGE_KEY_FILE "$UNINSTALL_CONFIG_SOURCE")"
        BACKUP_DIR="$(_read_env_value BACKUP_DIR "$UNINSTALL_CONFIG_SOURCE")"
        COMPOSE_PROJECT_NAME_ENV="$(_read_env_value COMPOSE_PROJECT_NAME "$UNINSTALL_CONFIG_SOURCE")"
    fi

    [[ -n "$PROJECT_STATE_DIR" || -z "$DATA_VOLUME_MOUNT" ]] || PROJECT_STATE_DIR="$DATA_VOLUME_MOUNT"
    PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-$DEFAULT_STATE_DIR}"
    COMPOSE_PROJECT_NAME_ENV="${COMPOSE_PROJECT_NAME_ENV:-vaultwarden-oci}"
    BACKUP_DIR="${BACKUP_DIR:-${PROJECT_STATE_DIR}/backups}"

    # Recover a partial/stale environment safely when the configured state path
    # is actually a mounted VaultWarden data volume. This avoids ever treating a
    # sentinel-backed mount as recursively deletable boot-volume state.
    if [[ -z "$DATA_VOLUME_DEVICE" && "$PROJECT_STATE_DIR" == /* ]] \
        && mountpoint -q "$PROJECT_STATE_DIR" 2>/dev/null \
        && [[ -f "$PROJECT_STATE_DIR/.vw-data-volume" && ! -L "$PROJECT_STATE_DIR/.vw-data-volume" ]] \
        && [[ "$(head -1 "$PROJECT_STATE_DIR/.vw-data-volume" 2>/dev/null || true)" == "VaultWarden-OCI data volume" ]]; then
        DATA_VOLUME_MOUNT="$PROJECT_STATE_DIR"
        DATA_VOLUME_DEVICE="$(findmnt -n -o SOURCE --target "$PROJECT_STATE_DIR" 2>/dev/null || true)"
        [[ -n "$DATA_VOLUME_DEVICE" ]] \
            || die "Mounted VaultWarden data volume detected at $PROJECT_STATE_DIR, but its source device could not be resolved."
        warn "Recovered separate-volume identity from mounted VaultWarden sentinel because the selected environment omitted DATA_VOLUME_DEVICE."
    fi

    STORAGE_MODE="boot-volume"
    DATA_MOUNT_MOUNTED=false
    DATA_MOUNT_SENTINEL=false
    DATA_VOLUME_IDENTITY_VERIFIED=false

    if [[ -n "$DATA_VOLUME_DEVICE" ]]; then
        STORAGE_MODE="separate block-storage"
        [[ "$DATA_VOLUME_MOUNT" == /* ]] || warn "DATA_VOLUME_MOUNT is not absolute/safe: ${DATA_VOLUME_MOUNT:-<unset>}"
        if [[ -n "$DATA_VOLUME_MOUNT" ]] && ! _paths_equivalent "$PROJECT_STATE_DIR" "$DATA_VOLUME_MOUNT"; then
            warn "Separate-volume config mismatch: PROJECT_STATE_DIR ($PROJECT_STATE_DIR) != DATA_VOLUME_MOUNT ($DATA_VOLUME_MOUNT)."
        fi
        if [[ -n "$DATA_VOLUME_MOUNT" ]] && mountpoint -q "$DATA_VOLUME_MOUNT" 2>/dev/null; then DATA_MOUNT_MOUNTED=true; fi
        if [[ -n "$DATA_VOLUME_MOUNT" && -f "$DATA_VOLUME_MOUNT/.vw-data-volume" && ! -L "$DATA_VOLUME_MOUNT/.vw-data-volume" ]]; then DATA_MOUNT_SENTINEL=true; fi
        if [[ "$DATA_MOUNT_MOUNTED" == "true" && "$DATA_MOUNT_SENTINEL" == "true" ]]; then
            _inspect_data_volume_identity || true
        fi
    fi

    MANAGED_AGE_KEY_PATHS=()
    for p in \
        "$SOPS_AGE_KEY_FILE_ENV" \
        "$AGE_KEY_FILE_ENV" \
        "/etc/vaultwarden/age-key.txt" \
        "${PROJECT_DIR}/secrets/keys/age-key.txt"; do
        [[ -n "$p" ]] || continue
        [[ "$p" = /* ]] || p="${PROJECT_DIR}/${p}"
        MANAGED_AGE_KEY_PATHS+=("$p")
    done
    mapfile -t MANAGED_AGE_KEY_PATHS < <(printf '%s\n' "${MANAGED_AGE_KEY_PATHS[@]}" | _unique_lines)
}

_preflight_storage_detach_safety() {
    [[ -n "${DATA_VOLUME_DEVICE:-}" ]] || return 0
    [[ "$DATA_VOLUME_MOUNT" == /* ]] || die "Separate block-storage uninstall requires an absolute DATA_VOLUME_MOUNT; got '${DATA_VOLUME_MOUNT:-<unset>}'."
    _paths_equivalent "$PROJECT_STATE_DIR" "$DATA_VOLUME_MOUNT" \
        || die "Separate-volume uninstall requires PROJECT_STATE_DIR to equal DATA_VOLUME_MOUNT. Fix the persisted environment before continuing."

    if mountpoint -q "$DATA_VOLUME_MOUNT" 2>/dev/null; then
        [[ -f "$DATA_VOLUME_MOUNT/.vw-data-volume" && ! -L "$DATA_VOLUME_MOUNT/.vw-data-volume" ]] \
            || die "Mounted $DATA_VOLUME_MOUNT lacks a safe .vw-data-volume sentinel. Refusing to detach an unknown mounted filesystem."
        _inspect_data_volume_identity \
            || die "Could not verify that the filesystem mounted at $DATA_VOLUME_MOUNT is the configured VaultWarden data volume. No changes made."
    fi
}

_dry_run_line() { printf '  - %s\n' "$*"; }

_safe_rm_rf() {
    local target="$1"
    [[ -n "$target" ]] || return 0
    [[ "$target" == /* ]] || { warn "Refusing to remove non-absolute path: $target"; return 1; }
    case "$target" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/mnt|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var|/var/lib)
            warn "Refusing to remove unsafe broad path: $target"
            return 1
            ;;
    esac
    if [[ "$DRY_RUN" == "true" ]]; then
        info "Would remove: $target"
        return 0
    fi
    rm -rf --one-file-system "$target"
}

_extract_age_public_key() {
    local keyfile="$1" pubkey=""
    [[ -f "$keyfile" ]] || return 1
    pubkey="$(grep -E '^# public key:' "$keyfile" 2>/dev/null | sed 's/^# public key:[[:space:]]*//' | head -1 || true)"
    [[ -n "$pubkey" ]] || pubkey="$(grep -E '^age1[a-z0-9]+' "$keyfile" 2>/dev/null | head -1 || true)"
    [[ -n "$pubkey" ]] || return 1
    printf '%s' "$pubkey"
}

_age_key_will_be_deleted() {
    local key="$1"
    _path_is_inside "$key" "$ETC_VAULTWARDEN_DIR" && return 0
    if _path_is_inside "$key" "$PROJECT_DIR"; then
        # Test-reset removes repo-local secrets; normal uninstall removes the
        # checkout unless a preserved backup inside it requires source retention.
        [[ "$TEST_RESET" == "true" ]] && return 0
        if ! (_backup_dir_is_external_to_state 2>/dev/null \
            && _path_is_inside "$BACKUP_DIR" "$PROJECT_DIR" 2>/dev/null \
            && [[ -d "$BACKUP_DIR" ]]); then
            return 0
        fi
    fi
    if [[ -z "${DATA_VOLUME_DEVICE:-}" ]] && _path_is_inside "$key" "$PROJECT_STATE_DIR"; then
        return 0
    fi
    return 1
}

_existing_age_keys() {
    local key
    for key in "${MANAGED_AGE_KEY_PATHS[@]}"; do
        [[ -f "$key" ]] || continue
        _age_key_will_be_deleted "$key" && printf '%s\n' "$key"
    done | _unique_lines
}

_show_age_keys() {
    local key pub
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        pub="$(_extract_age_public_key "$key" 2>/dev/null || true)"
        printf '  %s\n' "$key"
        printf '    public key: %s\n' "${pub:-(could not extract; inspect manually)}"
    done < <(_existing_age_keys)
}

_existing_recovery_handoffs() {
    [[ -d "$RECOVERY_HANDOFF_DIR" && ! -L "$RECOVERY_HANDOFF_DIR" ]] || return 0
    find -P "$RECOVERY_HANDOFF_DIR" -mindepth 1 -maxdepth 1 \
        \( -type f -o -type l \) \
        \( -name 'vaultwarden-setup-credentials-*.txt' \
           -o -name '.vaultwarden-setup-credentials.*' \
           -o -name 'vaultwarden-age-key-rotation-*.txt' \
           -o -name '.vaultwarden-age-key-rotation.*' \
           -o -name 'vaultwarden-recovery-kit-*.txt' \
           -o -name '.important-documents.*.zip' \) \
        -print 2>/dev/null || true
}

_show_recovery_handoffs() {
    local path
    while IFS= read -r path; do
        [[ -n "$path" ]] && printf '  %s\n' "$path"
    done < <(_existing_recovery_handoffs)
}

_validate_recovery_handoff_cleanup_safety() {
    if [[ -L "$RECOVERY_HANDOFF_DIR" || ( -e "$RECOVERY_HANDOFF_DIR" && ! -d "$RECOVERY_HANDOFF_DIR" ) ]]; then
        die "Recovery handoff path is not a real directory; refusing cleanup: $RECOVERY_HANDOFF_DIR"
    fi

    local path metadata uid gid mode links
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        [[ -L "$path" ]] && continue
        [[ -f "$path" ]] || die "Managed recovery handoff is not a regular file: $path"
        metadata="$(stat -c '%u:%g:%a:%h' -- "$path" 2>/dev/null)" \
            || die "Could not inspect managed recovery handoff: $path"
        IFS=: read -r uid gid mode links <<< "$metadata"
        [[ "$uid" == "0" && "$gid" == "0" && "$mode" == "600" && "$links" == "1" ]] \
            || die "Managed recovery handoff has unsafe metadata (uid=$uid gid=$gid mode=$mode links=$links): $path"
    done < <(_existing_recovery_handoffs)
}

_confirm_age_key_safety() {
    local keys_present=false handoffs_present=false
    [[ -n "$(_existing_age_keys)" ]] && keys_present=true
    [[ -n "$(_existing_recovery_handoffs)" ]] && handoffs_present=true

    if [[ "$keys_present" != "true" && "$handoffs_present" != "true" ]]; then
        info "No managed Age keys or local credential/recovery handoffs found."
        return 0
    fi

    if [[ "$FORCE" == "true" ]]; then
        warn "--force active — managed local recovery material will be deleted without an interactive prompt."
        [[ "$keys_present" == "true" ]] && _show_age_keys
        [[ "$handoffs_present" == "true" ]] && _show_recovery_handoffs
        return 0
    fi

    if [[ "$I_HAVE_SAVED_RECOVERY_KIT" != "true" ]]; then
        printf '\n'
        warn "RECOVERY MATERIAL DESTRUCTION WARNING"
        [[ "$keys_present" == "true" ]] && { warn "Managed Age key file(s) that would be deleted:"; _show_age_keys; }
        [[ "$handoffs_present" == "true" ]] && { warn "Managed local credential/recovery handoff(s) that would be deleted:"; _show_recovery_handoffs; }
        warn "Save your recovery kit outside this host, then re-run with:"
        warn "  sudo bash $0 run --i-have-saved-my-recovery-kit"
        die "Uninstall aborted — recovery material preservation was not explicitly confirmed. No changes made."
    fi

    warn "Explicit --i-have-saved-my-recovery-kit acknowledgement received."
    [[ "$keys_present" == "true" ]] && _show_age_keys
    [[ "$handoffs_present" == "true" ]] && _show_recovery_handoffs
    success "Recovery-material preservation confirmed by explicit flag."
}

_run_if_exists() { command -v "$1" >/dev/null 2>&1; }

_existing_recovery_cleanup_units() {
    _run_if_exists systemctl || return 0
    systemctl list-units --all --no-legend --plain 'vaultwarden-recovery-cleanup-*' 2>/dev/null \
        | awk 'NF { print $1 }' || true
}

_existing_recovery_cleanup_at_jobs() {
    _run_if_exists atq || return 0
    _run_if_exists at || return 0
    local job_id body
    while read -r job_id _; do
        [[ "$job_id" =~ ^[0-9]+$ ]] || continue
        body="$(at -c "$job_id" 2>/dev/null || true)"
        if grep -Fq "${RECOVERY_HANDOFF_DIR}/" <<< "$body" \
            && grep -Eq 'vaultwarden-recovery-kit-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}\.txt' <<< "$body"; then
            printf '%s\n' "$job_id"
        fi
    done < <(atq 2>/dev/null || true)
}

_backup_dir_is_external_to_state() {
    [[ -n "${BACKUP_DIR:-}" ]] || return 1
    ! _path_is_inside "$BACKUP_DIR" "$PROJECT_STATE_DIR"
}

_backup_dir_will_be_removed() {
    [[ -n "${BACKUP_DIR:-}" ]] || return 1
    [[ -z "${DATA_VOLUME_DEVICE:-}" ]] || return 1
    _path_is_inside "$BACKUP_DIR" "$PROJECT_STATE_DIR"
}

disable_systemd_units() {
    info "Step 1: Removing VaultWarden systemd units and scheduled cleanup jobs..."
    local unit dest dropin managed_dropin

    if _run_if_exists systemctl; then
        for unit in "${MANAGED_TIMERS[@]}" vaultwarden-startup.service; do
            if systemctl is-enabled "$unit" >/dev/null 2>&1 || systemctl is-active "$unit" >/dev/null 2>&1; then
                systemctl disable --now "$unit" 2>/dev/null || warn "Could not disable $unit; continuing with file cleanup."
            fi
        done
        for unit in "${MANAGED_SERVICES[@]}"; do
            [[ "$unit" == *"@"* ]] && continue
            systemctl stop "$unit" 2>/dev/null || true
        done
        while IFS= read -r unit; do
            [[ -n "$unit" ]] || continue
            systemctl stop "$unit" 2>/dev/null || true
            systemctl reset-failed "$unit" 2>/dev/null || true
            success "Stopped transient recovery cleanup unit: $unit"
        done < <(_existing_recovery_cleanup_units)
    else
        warn "systemctl not found — unit files will still be removed."
    fi

    for unit in "${MANAGED_TIMERS[@]}" "${MANAGED_SERVICES[@]}"; do
        dest="${SYSTEMD_SYSTEM_DIR}/${unit}"
        [[ ! -f "$dest" ]] || { rm -f "$dest" && success "Removed unit file: $dest"; }
        dropin="${SYSTEMD_SYSTEM_DIR}/${unit}.d"
        if [[ -d "$dropin" ]]; then
            for managed_dropin in 10-state-dir.conf 20-identity.conf 30-run-as-root.conf; do
                [[ ! -f "$dropin/$managed_dropin" ]] || { rm -f "$dropin/$managed_dropin" && success "Removed managed drop-in: $dropin/$managed_dropin"; }
            done
            rmdir "$dropin" 2>/dev/null || true
        fi
    done

    if _run_if_exists systemctl; then
        systemctl reset-failed 'vaultwarden-notify-failure@*.service' 2>/dev/null || true
        for unit in "${MANAGED_SERVICES[@]}"; do
            [[ "$unit" == *"@"* ]] && continue
            systemctl reset-failed "$unit" 2>/dev/null || true
        done
        systemctl daemon-reload 2>/dev/null || true
    fi

    if _run_if_exists atrm; then
        while IFS= read -r unit; do
            [[ -n "$unit" ]] || continue
            atrm "$unit" 2>/dev/null \
                && success "Removed scheduled recovery cleanup at job: $unit" \
                || warn "Could not remove recovery cleanup at job: $unit"
        done < <(_existing_recovery_cleanup_at_jobs)
    fi
}

_docker_label_for_container() {
    docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$1" 2>/dev/null || true
}

_docker_label_for_volume() {
    docker volume inspect -f '{{ index .Labels "com.docker.compose.project" }}' "$1" 2>/dev/null || true
}

_docker_label_for_network() {
    docker network inspect -f '{{ index .Labels "com.docker.compose.project" }}' "$1" 2>/dev/null || true
}

remove_docker_stack() {
    info "Step 2: Removing Docker objects with positive VaultWarden Compose ownership..."
    if ! _run_if_exists docker; then
        warn "docker not found — skipping Docker runtime cleanup."
        return 0
    fi

    local project_name="${COMPOSE_PROJECT_NAME_ENV:-vaultwarden-oci}"
    if [[ -f "${PROJECT_DIR}/docker-compose.yml" ]]; then
        docker compose -f "${PROJECT_DIR}/docker-compose.yml" down --volumes --remove-orphans --timeout 30 2>/dev/null \
            && success "Docker Compose stack stopped." \
            || warn "docker compose down reported errors; labelled cleanup will continue."
    fi

    local id name label
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        docker rm -f "$id" 2>/dev/null \
            && success "Removed compose-labelled container: $id" \
            || warn "Could not remove compose-labelled container: $id"
    done < <(docker ps -aq --filter "label=com.docker.compose.project=${project_name}" 2>/dev/null || true)

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        docker volume rm "$id" 2>/dev/null \
            && success "Removed compose-labelled Docker volume: $id" \
            || warn "Could not remove compose-labelled Docker volume: $id"
    done < <(docker volume ls -q --filter "label=com.docker.compose.project=${project_name}" 2>/dev/null || true)

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        docker network rm "$id" 2>/dev/null \
            && success "Removed compose-labelled Docker network: $id" \
            || warn "Could not remove compose-labelled Docker network: $id"
    done < <(docker network ls -q --filter "label=com.docker.compose.project=${project_name}" 2>/dev/null || true)

    # Historical fixed names are only hints. Preserve any object whose Compose
    # project label no longer proves ownership.
    for name in "${MANAGED_CONTAINERS[@]}"; do
        id="$(docker ps -aq --filter "name=^/${name}$" 2>/dev/null | head -1 || true)"
        [[ -n "$id" ]] || continue
        label="$(_docker_label_for_container "$id")"
        if [[ "$label" == "$project_name" ]]; then
            docker rm -f "$id" 2>/dev/null || true
        else
            warn "Preserving unlabeled/foreign container with historical VaultWarden name: $name"
        fi
    done
    for name in "${MANAGED_NETWORKS[@]}"; do
        docker network inspect "$name" >/dev/null 2>&1 || continue
        label="$(_docker_label_for_network "$name")"
        if [[ "$label" == "$project_name" ]]; then
            docker network rm "$name" 2>/dev/null || true
        else
            warn "Preserving unlabeled/foreign network with historical VaultWarden name: $name"
        fi
    done
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        label="$(_docker_label_for_volume "$name")"
        if [[ "$label" == "$project_name" ]]; then
            docker volume rm "$name" 2>/dev/null || true
        else
            warn "Preserving unlabeled Docker volume with historical VaultWarden prefix: $name"
        fi
    done < <(docker volume ls -q 2>/dev/null | awk '/^vaultwarden-oci_/ {print}' || true)
}

_data_volume_uuid() {
    [[ -n "${DATA_VOLUME_DEVICE:-}" ]] || return 0
    _device_uuid_for_path "$DATA_VOLUME_DEVICE" 2>/dev/null || true
}

_fstab_mount_entry_count() {
    local mountpoint="$1"
    [[ -n "$mountpoint" && -f "$FSTAB_FILE" ]] || { printf '0\n'; return 0; }
    awk -v mp="$mountpoint" '
        /^[[:space:]]*($|#)/ { next }
        $2 == mp { count++ }
        END { print count + 0 }
    ' "$FSTAB_FILE"
}

_fstab_has_configured_volume_entry() {
    local mountpoint="$1" source="$2" uuid="${3:-}"
    [[ -f "$FSTAB_FILE" ]] || return 1
    awk -v mp="$mountpoint" -v src="$source" -v uuid="$uuid" '
        /^[[:space:]]*($|#)/ { next }
        $2 == mp && ((src != "" && $1 == src) || (uuid != "" && $1 == "UUID=" uuid)) { found=1 }
        END { exit(found ? 0 : 1) }
    ' "$FSTAB_FILE"
}

_fstab_has_configured_source_entry() {
    local source="$1" uuid="${2:-}"
    [[ -f "$FSTAB_FILE" ]] || return 1
    awk -v src="$source" -v uuid="$uuid" '
        /^[[:space:]]*($|#)/ { next }
        (src != "" && $1 == src) || (uuid != "" && $1 == "UUID=" uuid) { found=1 }
        END { exit(found ? 0 : 1) }
    ' "$FSTAB_FILE"
}

_remove_fstab_mount() {
    local mountpoint="$1" source="${2:-}" uuid="${3:-}"
    [[ -n "$mountpoint" && -f "$FSTAB_FILE" ]] || return 0

    local tmp count identity_available=false
    [[ -n "$source" && ( -e "$source" || -L "$source" ) ]] && identity_available=true
    [[ -n "$uuid" ]] && identity_available=true
    count="$(_fstab_mount_entry_count "$mountpoint")"

    if _fstab_has_configured_volume_entry "$mountpoint" "$source" "$uuid"; then
        tmp="$(mktemp "${FSTAB_FILE}.vw-uninstall.XXXXXXXXXX")" || return 1
        if awk -v mp="$mountpoint" -v src="$source" -v uuid="$uuid" '
            !(($2 == mp) && ((src != "" && $1 == src) || (uuid != "" && $1 == "UUID=" uuid))) { print }
        ' "$FSTAB_FILE" > "$tmp" && mv -f "$tmp" "$FSTAB_FILE"; then
            success "Removed positively identified fstab entry for configured data volume."
            return 0
        fi
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi

    if [[ "$identity_available" != "true" && "$count" == "1" ]]; then
        # Detached devices cannot be re-probed for UUID. A unique active fstab
        # entry at the configured mountpoint is a narrow and practical fallback.
        tmp="$(mktemp "${FSTAB_FILE}.vw-uninstall.XXXXXXXXXX")" || return 1
        if awk -v mp="$mountpoint" '!(($2 == mp) && $0 !~ /^[[:space:]]*#/) { print }' "$FSTAB_FILE" > "$tmp" \
            && mv -f "$tmp" "$FSTAB_FILE"; then
            warn "Data device is unavailable, so UUID identity could not be re-derived."
            success "Removed the single active fstab entry at configured mountpoint: $mountpoint"
            return 0
        fi
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi

    if [[ "$count" == "0" ]] && ! _fstab_has_configured_source_entry "$source" "$uuid"; then
        info "No fstab entry found for configured data volume."
        return 0
    fi

    warn "Preserving ambiguous fstab entry for $mountpoint."
    warn "Expected at most one mountpoint entry or a source/UUID match; found mountpoint count=$count."
    return 1
}

_remove_docker_mount_guard() {
    if [[ -f "$DOCKER_MOUNT_GUARD" ]]; then
        rm -f "$DOCKER_MOUNT_GUARD" && success "Removed Docker mount-guard drop-in: $DOCKER_MOUNT_GUARD"
        rmdir "$DOCKER_MOUNT_GUARD_DIR" 2>/dev/null || true
    fi
    _run_if_exists systemctl && systemctl daemon-reload 2>/dev/null || true
}

remove_state_and_mount() {
    info "Step 3: Removing managed state or detaching separate block storage..."

    if [[ -z "$DATA_VOLUME_DEVICE" ]]; then
        if mountpoint -q "$PROJECT_STATE_DIR" 2>/dev/null \
            || [[ -e "$PROJECT_STATE_DIR/.vw-data-volume" || -L "$PROJECT_STATE_DIR/.vw-data-volume" ]]; then
            die "PROJECT_STATE_DIR looks mount-backed, but no verified DATA_VOLUME_DEVICE is available. Refusing recursive boot-state deletion: $PROJECT_STATE_DIR"
        fi
        if [[ -d "$PROJECT_STATE_DIR" ]]; then
            _state_dir_has_managed_evidence "$PROJECT_STATE_DIR" \
                || die "Custom PROJECT_STATE_DIR lacks recognizable VaultWarden state evidence; refusing recursive deletion: $PROJECT_STATE_DIR"
            _safe_rm_rf "$PROJECT_STATE_DIR" && success "Removed boot-volume state directory: $PROJECT_STATE_DIR"
        else
            info "State directory not found: $PROJECT_STATE_DIR"
        fi
        if [[ -n "${BACKUP_DIR:-}" && -d "$BACKUP_DIR" ]] && ! _path_is_inside "$BACKUP_DIR" "$PROJECT_STATE_DIR"; then
            warn "Preserving external backup directory: $BACKUP_DIR"
        fi
        _remove_docker_mount_guard
        return 0
    fi

    [[ "$DATA_VOLUME_MOUNT" == /* ]] || die "Separate block-storage uninstall requires an absolute DATA_VOLUME_MOUNT; got '${DATA_VOLUME_MOUNT:-<unset>}'."
    _paths_equivalent "$PROJECT_STATE_DIR" "$DATA_VOLUME_MOUNT" \
        || die "PROJECT_STATE_DIR does not match DATA_VOLUME_MOUNT; refusing storage detach."

    local mounted=false source="" uuid="" sentinel="${DATA_VOLUME_MOUNT}/.vw-data-volume"
    mountpoint -q "$DATA_VOLUME_MOUNT" 2>/dev/null && mounted=true

    if [[ "$mounted" == "true" ]]; then
        _inspect_data_volume_identity \
            || die "Mounted data-volume identity verification failed. Refusing detach: $DATA_VOLUME_MOUNT"
        source="$(findmnt -n -o SOURCE --target "$DATA_VOLUME_MOUNT" 2>/dev/null || true)"
        uuid="$(_data_volume_uuid)"
        _remove_fstab_mount "$DATA_VOLUME_MOUNT" "$source" "$uuid" \
            || die "Could not safely remove the configured data-volume fstab entry."
        _remove_docker_mount_guard

        # The block-volume filesystem is a recovery boundary. Never bulk-delete it
        # from uninstall; only remove the project sentinel before detaching it.
        if command -v chattr >/dev/null 2>&1; then
            chattr -i "$sentinel" 2>/dev/null || true
        fi
        rm -f -- "$sentinel" || die "Could not remove VaultWarden data-volume sentinel: $sentinel"
        warn "Preserving all filesystem contents on separate data volume: $DATA_VOLUME_MOUNT"
        info "VaultWarden data may be deleted manually after inspecting the detached volume, if desired."
    else
        warn "$DATA_VOLUME_MOUNT is not mounted; filesystem contents will not be touched."
        if [[ -d "$DATA_VOLUME_MOUNT" ]] && [[ -n "$(find "$DATA_VOLUME_MOUNT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
            warn "Unrelated/local files exist under the unmounted host mountpoint; preserving them: $DATA_VOLUME_MOUNT"
        fi
        uuid="$(_data_volume_uuid)"
        _remove_fstab_mount "$DATA_VOLUME_MOUNT" "$DATA_VOLUME_DEVICE" "$uuid" \
            || die "Preserved ambiguous data-volume fstab entry. Review $FSTAB_FILE and rerun uninstall."
        _remove_docker_mount_guard
    fi

    if [[ "$mounted" == "true" ]]; then
        info "Unmounting data volume at $DATA_VOLUME_MOUNT..."
        if umount "$DATA_VOLUME_MOUNT" 2>/dev/null; then
            success "Unmounted $DATA_VOLUME_MOUNT"
        else
            warn "Normal unmount failed; attempting lazy unmount. Check for open files."
            umount -l "$DATA_VOLUME_MOUNT" 2>/dev/null \
                && success "Lazy-unmounted $DATA_VOLUME_MOUNT" \
                || die "Could not unmount $DATA_VOLUME_MOUNT. Inspect open files and unmount it manually."
        fi
    fi

    if [[ -d "$DATA_VOLUME_MOUNT" ]]; then
        if rmdir "$DATA_VOLUME_MOUNT" 2>/dev/null; then
            success "Removed empty host mountpoint directory: $DATA_VOLUME_MOUNT"
        else
            warn "Preserving non-empty host mountpoint directory and its unrelated/local files: $DATA_VOLUME_MOUNT"
        fi
    fi
}

_repo_artifact_is_preserved_backup() {
    local path="$1"
    [[ -n "${BACKUP_DIR:-}" && -d "$BACKUP_DIR" ]] || return 1
    _backup_dir_is_external_to_state || return 1
    _path_is_inside "$BACKUP_DIR" "$path"
}

remove_repo_local_install_artifacts() {
    local reason="${1:-test-reset}"
    [[ "$TEST_RESET" == "true" || "$reason" == "preserved-checkout" ]] || return 0
    info "Step 4: Resetting generated checkout-local installation artifacts..."

    local rel path
    local artifacts=(
        .env
        .sops.yaml
        docker-compose.yml
        docker-compose.override.yml
        docker-compose.override.dev.yml
        rclone.conf
        secrets
        backups
        logs
        data
        caddy/data
        caddy/config
    )

    for rel in "${artifacts[@]}"; do
        path="${PROJECT_DIR}/${rel}"
        if _repo_artifact_is_preserved_backup "$path"; then
            warn "Preserving generated parent containing external BACKUP_DIR: $path"
            continue
        fi
        [[ -e "$path" || -L "$path" ]] || continue
        _safe_rm_rf "$path"
        success "Removed checkout-local install artifact: $rel"
    done

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        _safe_rm_rf "$path"
        success "Removed checkout-local temporary workspace: $(basename "$path")"
    done < <(find "$PROJECT_DIR" -mindepth 1 -maxdepth 1 -type d \
        \( -name '.restore-tmp*' -o -name '.backup-tmp*' \) -print 2>/dev/null || true)

    success "Git checkout preserved for immediate reinstall: $PROJECT_DIR"
}

remove_installed_files() {
    info "Step 5: Removing installed VaultWarden scripts and configuration..."
    _safe_rm_rf "$OPT_SCRIPTS_DIR" || true
    _safe_rm_rf "$ETC_VAULTWARDEN_DIR" || true
    [[ "$TEST_RESET" != "true" ]] || remove_repo_local_install_artifacts
}

_remove_sensitive_handoff() {
    local target="$1" initial_metadata="" current_metadata="" dev inode uid gid mode links
    [[ -n "$target" && "$target" == "$RECOVERY_HANDOFF_DIR"/* ]] || return 1

    if [[ -L "$target" ]]; then
        rm -f -- "$target"
        return $?
    fi
    _path_is_inside "$target" "$RECOVERY_HANDOFF_DIR" || return 1
    [[ -e "$target" ]] || return 0
    [[ -f "$target" ]] || return 1

    initial_metadata="$(stat -c '%d:%i:%u:%g:%a:%h' -- "$target" 2>/dev/null)" || return 1
    IFS=: read -r dev inode uid gid mode links <<< "$initial_metadata"
    [[ "$uid" == "0" && "$gid" == "0" && "$mode" == "600" && "$links" == "1" ]] || return 1
    current_metadata="$(stat -c '%d:%i:%u:%g:%a:%h' -- "$target" 2>/dev/null)" || return 1
    [[ "$current_metadata" == "$initial_metadata" ]] || return 1

    # Best-effort overwrite. Physical erasure is not guaranteed on SSDs,
    # snapshots, journaling filesystems, or CoW storage.
    command -v shred >/dev/null 2>&1 && shred -fuz -- "$target" 2>/dev/null || true
    [[ ! -L "$target" ]] || return 1
    [[ ! -e "$target" ]] || rm -f -- "$target"
    [[ ! -e "$target" && ! -L "$target" ]]
}

remove_recovery_handoffs() {
    info "Step 5: Removing managed root-only credential/recovery handoffs..."
    local path removed=0
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        _remove_sensitive_handoff "$path" \
            || die "Could not safely remove managed recovery handoff: $path"
        removed=$((removed + 1))
        success "Removed managed recovery handoff: $(basename "$path")"
    done < <(_existing_recovery_handoffs)
    [[ ! -d "$RECOVERY_HANDOFF_DIR" ]] || rmdir "$RECOVERY_HANDOFF_DIR" 2>/dev/null || true
    (( removed > 0 )) || info "No managed root-only credential/recovery handoffs found."
}

remove_project_checkout() {
    [[ "$TEST_RESET" == "true" ]] && return 0
    info "Step 11: Removing the project checkout after host cleanup..."
    cd /
    if [[ "$PROJECT_DIR" == */VaultWarden-OCI || "$PROJECT_BASENAME" == "VaultWarden-OCI" ]]; then
        if _backup_dir_is_external_to_state && _path_is_inside "$BACKUP_DIR" "$PROJECT_DIR" && [[ -d "$BACKUP_DIR" ]]; then
            warn "Preserving project checkout because external BACKUP_DIR is inside it: $BACKUP_DIR"
            remove_repo_local_install_artifacts preserved-checkout
            warn "Generated local secrets/config were removed; source and the backup subtree remain."
            warn "Move the backup elsewhere, then remove the checkout manually if desired: $PROJECT_DIR"
            return 0
        fi
        if _safe_rm_rf "$PROJECT_DIR"; then
            success "Removed project checkout: $PROJECT_DIR"
        else
            warn "Could not remove project checkout completely: $PROJECT_DIR"
        fi
    else
        warn "Project directory does not look like a VaultWarden-OCI checkout; preserving it: $PROJECT_DIR"
    fi
}

remove_sops_and_packages() {
    info "Step 6: Preserving shared administrator tooling..."
    [[ ! -f "$SOPS_BIN" ]] \
        && info "No standalone SOPS binary found at $SOPS_BIN." \
        || warn "Preserving $SOPS_BIN; project ownership cannot be proven."
    warn "Preserving common distro/admin packages installed or reused by setup."
}

_strip_marked_crowdsec_profile_block() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    grep -Fxq "$CROWDSEC_EMAIL_PROFILE_BEGIN" "$file" || return 0

    local tmp rc=0
    tmp="$(mktemp "$(dirname "$file")/.vw-uninstall-crowdsec.XXXXXXXX")" || return 1
    awk -v begin="$CROWDSEC_EMAIL_PROFILE_BEGIN" -v end="$CROWDSEC_EMAIL_PROFILE_END" '
        $0 == begin {
            if (inside || seen) exit 42
            inside=1; seen=1; next
        }
        $0 == end {
            if (!inside) exit 43
            inside=0; next
        }
        !inside { print }
        END { if (inside) exit 44 }
    ' "$file" > "$tmp" || rc=$?
    if (( rc != 0 )); then
        rm -f "$tmp"
        warn "CrowdSec profiles file contains malformed VaultWarden markers; preserving it for manual review: $file"
        return 1
    fi

    chmod --reference="$file" "$tmp" 2>/dev/null || true
    chown --reference="$file" "$tmp" 2>/dev/null || true
    if [[ -z "$(grep -vE '^[[:space:]]*$' "$tmp" 2>/dev/null || true)" ]]; then
        rm -f "$tmp" "$file"
        success "Removed empty CrowdSec profiles override after stripping VaultWarden block: $file"
    else
        mv -f "$tmp" "$file"
        success "Removed marked VaultWarden CrowdSec email profile block: $file"
    fi
}

remove_crowdsec() {
    info "Step 7: Removing only positively marked VaultWarden CrowdSec integration..."

    if [[ -f "$CROWDSEC_EMAIL_PLUGIN" ]]; then
        if grep -Fxq "$CROWDSEC_EMAIL_PLUGIN_MARKER" "$CROWDSEC_EMAIL_PLUGIN"; then
            rm -f "$CROWDSEC_EMAIL_PLUGIN"
            success "Removed marked VaultWarden CrowdSec email plugin: $CROWDSEC_EMAIL_PLUGIN"
        else
            warn "Preserving unmarked CrowdSec notification file: $CROWDSEC_EMAIL_PLUGIN"
        fi
    fi
    _strip_marked_crowdsec_profile_block "$CROWDSEC_EMAIL_PROFILES" \
        || warn "Marked CrowdSec profile cleanup requires manual review."

    warn "Preserving CrowdSec engine, firewall/Cloudflare bouncers, packages, repository, config, state, and logs."
    warn "Setup can reuse a pre-existing CrowdSec installation, so uninstall cannot safely claim ownership of those shared assets."
}

_ufw_managed_rule_numbers() {
    command -v ufw >/dev/null 2>&1 || return 0
    ufw status numbered 2>/dev/null | awk '
        $0 ~ /#[[:space:]]*CF-IPv[46]([[:space:]-]|$)/ {
            line=$0
            sub(/^\[[[:space:]]*/, "", line)
            sub(/\].*$/, "", line)
            gsub(/[[:space:]]/, "", line)
            if (line ~ /^[0-9]+$/) print line
        }
    ' | sort -rn
}

_warn_unmarked_ufw_http_rules() {
    command -v ufw >/dev/null 2>&1 || return 0
    if ufw status numbered 2>/dev/null | awk '
        /(^|[[:space:]])(80|443)\/tcp([[:space:]]|$)/ && $0 !~ /#[[:space:]]*CF-IPv[46]([[:space:]-]|$)/ { found=1 }
        END { exit(found ? 0 : 1) }
    '; then
        warn "Preserving unmarked UFW HTTP/HTTPS rule(s); setup may have reused pre-existing rules."
    fi
}

_remove_managed_cloudflare_ufw_rules() {
    local rule_num removed=0
    while IFS= read -r rule_num; do
        [[ "$rule_num" =~ ^[0-9]+$ ]] || continue
        if ufw --force delete "$rule_num" >/dev/null 2>&1; then
            removed=$((removed + 1))
        fi
    done < <(_ufw_managed_rule_numbers)
    success "Removed ${removed} UFW rule(s) carrying VaultWarden Cloudflare comments."
}

remove_firewall_rules() {
    info "Step 8: Removing firewall rules with explicit VaultWarden ownership..."
    if command -v ufw >/dev/null 2>&1; then
        _warn_unmarked_ufw_http_rules
        _remove_managed_cloudflare_ufw_rules
    fi

    if command -v iptables >/dev/null 2>&1 || command -v ip6tables >/dev/null 2>&1; then
        warn "Preserving unmarked raw iptables/ip6tables rules. Setup historically reused identical existing rules, so ownership cannot be proven."
        warn "If this was a dedicated appliance and you want to inspect legacy rules, review POSTROUTING and DOCKER-USER manually after uninstall."
    fi
}

remove_swap_and_apt_sources() {
    info "Step 9: Handling test-reset host settings and preserving ambiguous normal-host settings..."

    if [[ "$TEST_RESET" == "true" ]]; then
        if swapon --show 2>/dev/null | awk -v swap="$SWAPFILE_PATH" '$1 == swap { found=1 } END { exit(found ? 0 : 1) }'; then
            swapoff "$SWAPFILE_PATH" 2>/dev/null || die "swapoff $SWAPFILE_PATH failed"
        fi
        [[ ! -e "$SWAPFILE_PATH" ]] || { rm -f "$SWAPFILE_PATH" && success "Removed $SWAPFILE_PATH for test-reset coverage"; }

        if [[ -f "$FSTAB_FILE" ]] && awk -v swap="$SWAPFILE_PATH" '$1 == swap { found=1 } END { exit(found ? 0 : 1) }' "$FSTAB_FILE"; then
            local tmp
            tmp="$(mktemp "${FSTAB_FILE}.vw-swap.XXXXXXXXXX")" || return 1
            awk -v swap="$SWAPFILE_PATH" '$1 != swap { print }' "$FSTAB_FILE" > "$tmp" && mv -f "$tmp" "$FSTAB_FILE" \
                || { rm -f "$tmp" 2>/dev/null || true; die "Could not remove $SWAPFILE_PATH fstab entry"; }
            success "Removed $SWAPFILE_PATH fstab entry"
        fi

        if [[ -f "$SYSCTL_CONF" ]] && grep -Fxq 'vm.swappiness=10' "$SYSCTL_CONF" 2>/dev/null; then
            local sysctl_tmp
            sysctl_tmp="$(mktemp "${SYSCTL_CONF}.vw-swappiness.XXXXXXXXXX")" || return 1
            awk '$0 != "vm.swappiness=10" { print }' "$SYSCTL_CONF" > "$sysctl_tmp" && mv -f "$sysctl_tmp" "$SYSCTL_CONF" \
                || { rm -f "$sysctl_tmp" 2>/dev/null || true; die "Could not remove test-reset swappiness line"; }
            success "Removed test-reset swappiness line: vm.swappiness=10"
        fi

        [[ ! -f "$APT_SOURCE_UNIVERSE" ]] || { rm -f "$APT_SOURCE_UNIVERSE" && success "Removed test-reset fallback universe source: $APT_SOURCE_UNIVERSE"; }
    else
        [[ ! -e "$SWAPFILE_PATH" ]] || warn "Preserving ambiguous existing $SWAPFILE_PATH."
        if [[ -f "$FSTAB_FILE" ]] && awk -v swap="$SWAPFILE_PATH" '$1 == swap { found=1 } END { exit(found ? 0 : 1) }' "$FSTAB_FILE"; then
            warn "Preserving ambiguous $SWAPFILE_PATH fstab entry."
        fi
        [[ ! -f "$SYSCTL_CONF" ]] || ! grep -Fxq 'vm.swappiness=10' "$SYSCTL_CONF" 2>/dev/null \
            || warn "Preserving ambiguous vm.swappiness=10 host setting."
        [[ ! -f "$APT_SOURCE_UNIVERSE" ]] || warn "Preserving ambiguous universe source file: $APT_SOURCE_UNIVERSE"
    fi
}

preserve_os_identity() {
    info "Step 10: Preserving OS users, groups, and memberships..."
    if getent group vaultwarden >/dev/null 2>&1; then
        warn "Preserving existing system group 'vaultwarden'; remove it manually only after confirming no other workload uses it."
    fi
    warn "Leaving Docker packages, /var/lib/docker, OS identities, and operator memberships unchanged."
}

remove_runtime_artifacts() {
    info "Step 12: Removing VaultWarden runtime secrets and operation state..."
    # Do not unlink live /run/lock paths while flock file descriptors are held.
    if _safe_rm_rf "$RUNTIME_DIR"; then
        success "Removed VaultWarden runtime secrets/state."
    else
        warn "Could not fully remove VaultWarden runtime secrets/state: $RUNTIME_DIR"
    fi
    info "Reusable coordination lock pathnames under /run/lock are intentionally preserved."
}

_residual() {
    warn "RESIDUAL: $1"
    UNINSTALL_RESIDUALS=$((UNINSTALL_RESIDUALS + 1))
}

verify_uninstall_complete() {
    info "Step 13: Verifying positively managed artifacts are gone..."
    UNINSTALL_RESIDUALS=0
    local unit dropin path project_name="${COMPOSE_PROJECT_NAME_ENV:-vaultwarden-oci}" id

    for unit in "${MANAGED_TIMERS[@]}" "${MANAGED_SERVICES[@]}"; do
        [[ ! -e "${SYSTEMD_SYSTEM_DIR}/${unit}" ]] || _residual "${SYSTEMD_SYSTEM_DIR}/${unit}"
        for dropin in 10-state-dir.conf 20-identity.conf 30-run-as-root.conf; do
            [[ ! -e "${SYSTEMD_SYSTEM_DIR}/${unit}.d/${dropin}" ]] || _residual "${SYSTEMD_SYSTEM_DIR}/${unit}.d/${dropin}"
        done
    done
    while IFS= read -r unit; do
        [[ -n "$unit" ]] && _residual "transient recovery cleanup unit $unit"
    done < <(_existing_recovery_cleanup_units)
    while IFS= read -r unit; do
        [[ -n "$unit" ]] && _residual "scheduled recovery cleanup at job $unit"
    done < <(_existing_recovery_cleanup_at_jobs)
    [[ ! -e "$DOCKER_MOUNT_GUARD" ]] || _residual "$DOCKER_MOUNT_GUARD"

    for path in "$OPT_SCRIPTS_DIR" "$ETC_VAULTWARDEN_DIR" "$RUNTIME_DIR"; do
        [[ ! -e "$path" ]] || _residual "$path"
    done

    if [[ -L "$RECOVERY_HANDOFF_DIR" || ( -e "$RECOVERY_HANDOFF_DIR" && ! -d "$RECOVERY_HANDOFF_DIR" ) ]]; then
        _residual "unsafe recovery handoff path $RECOVERY_HANDOFF_DIR"
    else
        while IFS= read -r path; do
            [[ -n "$path" ]] && _residual "managed root-only credential/recovery handoff $path"
        done < <(_existing_recovery_handoffs)
    fi

    if [[ -z "$DATA_VOLUME_DEVICE" ]]; then
        [[ ! -e "$PROJECT_STATE_DIR" ]] || _residual "managed state directory $PROJECT_STATE_DIR"
    else
        mountpoint -q "$DATA_VOLUME_MOUNT" 2>/dev/null && _residual "data volume still mounted at $DATA_VOLUME_MOUNT"
        if [[ -f "$FSTAB_FILE" ]] && awk -v mp="$DATA_VOLUME_MOUNT" '
            /^[[:space:]]*($|#)/ { next }
            $2 == mp { found=1 }
            END { exit(found ? 0 : 1) }
        ' "$FSTAB_FILE"; then
            _residual "fstab still references configured data-volume mountpoint"
        fi
    fi

    if [[ -f "$CROWDSEC_EMAIL_PLUGIN" ]] && grep -Fxq "$CROWDSEC_EMAIL_PLUGIN_MARKER" "$CROWDSEC_EMAIL_PLUGIN"; then
        _residual "marked VaultWarden CrowdSec email plugin $CROWDSEC_EMAIL_PLUGIN"
    fi
    if [[ -f "$CROWDSEC_EMAIL_PROFILES" ]] && grep -Fxq "$CROWDSEC_EMAIL_PROFILE_BEGIN" "$CROWDSEC_EMAIL_PROFILES"; then
        _residual "marked VaultWarden CrowdSec email profile block $CROWDSEC_EMAIL_PROFILES"
    fi

    if [[ "$TEST_RESET" == "true" ]]; then
        [[ ! -e "$SWAPFILE_PATH" ]] || _residual "$SWAPFILE_PATH"
        [[ -d "$PROJECT_DIR/.git" ]] || _residual "test-reset checkout is not preserved as a Git checkout: $PROJECT_DIR"
        for path in \
            "$PROJECT_DIR/.env" "$PROJECT_DIR/.sops.yaml" "$PROJECT_DIR/docker-compose.yml" \
            "$PROJECT_DIR/docker-compose.override.yml" "$PROJECT_DIR/docker-compose.override.dev.yml" \
            "$PROJECT_DIR/rclone.conf" "$PROJECT_DIR/secrets" "$PROJECT_DIR/logs" "$PROJECT_DIR/data" \
            "$PROJECT_DIR/caddy/data" "$PROJECT_DIR/caddy/config"; do
            [[ ! -e "$path" ]] || _residual "checkout-local install artifact $path"
        done
    elif [[ "$PROJECT_DIR" == */VaultWarden-OCI || "$PROJECT_BASENAME" == "VaultWarden-OCI" ]]; then
        if ! (_backup_dir_is_external_to_state && _path_is_inside "$BACKUP_DIR" "$PROJECT_DIR" && [[ -d "$BACKUP_DIR" ]]); then
            [[ ! -e "$PROJECT_DIR" ]] || _residual "project checkout $PROJECT_DIR"
        fi
    fi

    if _run_if_exists docker; then
        id="$(docker ps -aq --filter "label=com.docker.compose.project=${project_name}" 2>/dev/null || true)"
        [[ -z "$id" ]] || _residual "compose-labelled container(s) for project ${project_name}"
        id="$(docker volume ls -q --filter "label=com.docker.compose.project=${project_name}" 2>/dev/null || true)"
        [[ -z "$id" ]] || _residual "compose-labelled Docker volume(s) for project ${project_name}"
        id="$(docker network ls -q --filter "label=com.docker.compose.project=${project_name}" 2>/dev/null || true)"
        [[ -z "$id" ]] || _residual "compose-labelled Docker network(s) for project ${project_name}"
    fi

    if command -v ufw >/dev/null 2>&1 && [[ -n "$(_ufw_managed_rule_numbers)" ]]; then
        _residual "UFW still has rule(s) carrying VaultWarden Cloudflare comments"
    fi

    if [[ "$TEST_RESET" == "true" && -f "$FSTAB_FILE" ]] \
        && awk -v swap="$SWAPFILE_PATH" '$1 == swap { found=1 } END { exit(found ? 0 : 1) }' "$FSTAB_FILE"; then
        _residual "$FSTAB_FILE still references $SWAPFILE_PATH"
    fi

    (( UNINSTALL_RESIDUALS == 0 )) \
        || die "Uninstall incomplete — ${UNINSTALL_RESIDUALS} positively managed artifact(s) remain. Review RESIDUAL lines above."
    success "Residual verification passed: no positively managed stack artifacts remain."
}

show_summary() {
    printf '\n'
    printf '%s\n' '============================================================'
    printf '%s\n' '   VaultWarden-OCI Uninstaller'
    printf '   Project dir       : %s\n' "$PROJECT_DIR"
    printf '   Config source     : %s\n' "${UNINSTALL_CONFIG_SOURCE:-<defaults/no persisted env>}"
    printf '   Project state dir : %s\n' "$PROJECT_STATE_DIR"
    printf '   Storage mode      : %s\n' "$STORAGE_MODE"
    printf '   Data device       : %s\n' "${DATA_VOLUME_DEVICE:-<unset>}"
    printf '   Data mount        : %s\n' "${DATA_VOLUME_MOUNT:-<unset>}"
    if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then
        printf '   Mount status      : mounted=%s sentinel=%s identity=%s\n' "$DATA_MOUNT_MOUNTED" "$DATA_MOUNT_SENTINEL" "$DATA_VOLUME_IDENTITY_VERIFIED"
        printf '%s\n' '   Volume data       : PRESERVED (detach only)'
    fi
    printf '   Running as        : %s  (real user: %s)\n' "$(whoami)" "$REAL_USER"
    [[ "$TEST_RESET" == "true" ]] && printf '%s\n' '   Reset mode        : TEST RESET — preserve Git checkout'
    [[ "$DRY_RUN" == "true" ]] && printf '%s\n' '   Mode              : DRY RUN — no changes'
    [[ "$FORCE" == "true" ]] && printf '%s\n' '   Mode              : FORCE — non-interactive'
    printf '%s\n\n' '============================================================'

    [[ "$DRY_RUN" == "true" ]] || return 0

    warn "DRY RUN MODE — no changes will be made. Planned scope:"
    _dry_run_line "VaultWarden systemd units/drop-ins and recognized recovery cleanup jobs"
    _dry_run_line "Compose-labelled Docker objects for project ${COMPOSE_PROJECT_NAME_ENV}"
    _dry_run_line "installed project scripts/config: ${OPT_SCRIPTS_DIR}, ${ETC_VAULTWARDEN_DIR}"
    _dry_run_line "runtime secrets/state: ${RUNTIME_DIR}"
    _dry_run_line "managed recovery handoffs under ${RECOVERY_HANDOFF_DIR}"
    if [[ -z "${DATA_VOLUME_DEVICE:-}" ]]; then
        _dry_run_line "boot-volume managed state: ${PROJECT_STATE_DIR}"
        _backup_dir_will_be_removed && _dry_run_line "local BACKUP_DIR is inside state and would be removed: ${BACKUP_DIR}"
    else
        _dry_run_line "separate data-volume filesystem contents are preserved"
        _dry_run_line "verified sentinel/fstab/mount guard are removed and volume is unmounted"
    fi
    _dry_run_line "marked VaultWarden CrowdSec email integration only; shared CrowdSec is preserved"
    _dry_run_line "UFW rules with CF-IPv4/CF-IPv6 comments only; unmarked/raw netfilter rules are preserved"
    _dry_run_line "external BACKUP_DIR is always preserved"
    if [[ "$TEST_RESET" == "true" ]]; then
        _dry_run_line "test-reset checkout-local generated artifacts and dedicated-test-VM swap/tuning/source state"
        _dry_run_line "Git checkout preserved: ${PROJECT_DIR}"
    else
        _dry_run_line "project checkout: ${PROJECT_DIR} (unless it contains preserved external backups)"
    fi
    _dry_run_line "shared Docker/CrowdSec/SOPS/admin tooling and OS identities preserved"
    info "DRY RUN complete — no changes made."
    exit 0
}

offer_final_backup() {
    if [[ "$FORCE" == "true" ]]; then
        warn "--force active — skipping final backup prompt."
        return 0
    fi
    [[ -f "${PROJECT_DIR}/backup.sh" ]] || return 0

    printf '\n'
    warn "PRE-DESTRUCTION BACKUP OFFER"
    warn "A final encrypted backup is strongly recommended."

    local answer continue_anyway
    local -a backup_args=(run full)
    if _backup_dir_will_be_removed; then
        warn "BACKUP_DIR is inside boot-volume state that uninstall will delete: $BACKUP_DIR"
        warn "A local-only final backup would be deleted, so this backup requires verified off-host sync."
        backup_args+=(--rclone --full-verification)
        read -r -t 300 -p "Run final encrypted backup + verified off-host sync? [yes/no] (default: no): " answer || answer="no"
    else
        if [[ -n "${DATA_VOLUME_DEVICE:-}" ]] && _path_is_inside "$BACKUP_DIR" "$DATA_VOLUME_MOUNT"; then
            warn "BACKUP_DIR is on the separate data volume. It will be preserved but become detached after uninstall."
            warn "For disaster recovery, an off-host copy is still recommended."
        else
            info "BACKUP_DIR is outside the destructive boot-state scope and will be preserved: $BACKUP_DIR"
        fi
        read -r -t 300 -p "Run a final encrypted backup now? [yes/no] (default: no): " answer || answer="no"
    fi

    if [[ "$answer" == "yes" ]]; then
        info "Running final full backup..."
        if bash "${PROJECT_DIR}/backup.sh" "${backup_args[@]}" 2>&1; then
            success "Final backup completed."
        else
            warn "Backup/sync exited with errors. Review the output above."
            read -r -t 300 -p "Continue with uninstall despite backup failure? [yes/no] (default: no): " continue_anyway || continue_anyway="no"
            [[ "$continue_anyway" == "yes" ]] || { info "Aborted — no uninstall changes made."; exit 0; }
        fi
    else
        warn "Skipping final backup."
    fi
}

confirm_uninstall() {
    warn "This will permanently delete positively managed VaultWarden boot-state, secrets, local recovery handoffs, containers, and configuration."
    if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then
        warn "Separate data-volume filesystem contents will be preserved and the volume will only be detached/unmounted."
    fi
    [[ "$TEST_RESET" != "true" ]] || warn "Test-reset preserves the Git checkout but removes generated local install artifacts."
    [[ "$TEST_RESET" == "true" ]] || warn "The project checkout is removed unless it contains a preserved external backup directory."

    if [[ "$FORCE" == "true" ]]; then
        warn "--force active — skipping interactive uninstall confirmation."
        return 0
    fi

    local confirm
    if ! read -r -t 300 -p "Type 'UNINSTALL' to confirm, or anything else to abort: " confirm; then
        printf '\n' >&2
        die "No confirmation received within 5 minutes. The uninstall was not performed."
    fi
    [[ "$confirm" == "UNINSTALL" ]] || { info "Aborted — no changes made."; exit 0; }
}

_finalize_successful_operation_guard() {
    if [[ "$UNINSTALL_OPERATION_HELD" == "true" ]] && declare -f operation_release >/dev/null 2>&1; then
        # shellcheck disable=SC2034 # consumed by lib/operations.sh
        OPERATION_OWNS_STATE=false
        # shellcheck disable=SC2034 # consumed by lib/operations.sh
        OPERATION_STATE_FILE=""
        operation_release 0
        UNINSTALL_OPERATION_HELD=false
        unset VW_OPERATION_PARENT_STATE VW_OPERATION_PARENT_TOKEN VW_OPERATION_PARENT_ID
    fi
}

main() {
    if [[ "$DRY_RUN" != "true" ]] && declare -f operation_acquire >/dev/null 2>&1; then
        operation_acquire \
            --id uninstall \
            --label "Uninstall" \
            --specific-lock /run/lock/vaultwarden-uninstall.lock || exit $?
        UNINSTALL_OPERATION_HELD=true
        trap _uninstall_exit_trap EXIT
        trap 'exit 130' INT
        trap 'exit 143' HUP TERM
        operation_set_phase "1" "Resolving uninstall paths"
    fi

    resolve_paths
    if [[ "$DRY_RUN" != "true" ]]; then
        _preflight_storage_detach_safety
        _validate_recovery_handoff_cleanup_safety
    fi

    operation_set_phase "2" "Confirming recovery and uninstall" 2>/dev/null || true
    show_summary
    _confirm_age_key_safety
    confirm_uninstall
    offer_final_backup

    operation_set_phase "3" "Removing services and Docker stack" 2>/dev/null || true
    disable_systemd_units
    remove_docker_stack

    operation_set_phase "4" "Removing persistent and installed state" 2>/dev/null || true
    remove_state_and_mount
    remove_installed_files
    remove_recovery_handoffs

    operation_set_phase "5" "Removing owned integrations and host mutations" 2>/dev/null || true
    remove_sops_and_packages
    remove_crowdsec
    remove_firewall_rules
    remove_swap_and_apt_sources
    preserve_os_identity
    remove_project_checkout

    operation_set_phase "6" "Final runtime cleanup and residual verification" 2>/dev/null || true
    remove_runtime_artifacts
    verify_uninstall_complete
    _finalize_successful_operation_guard

    printf '\n%s\n' '============================================================'
    success "Uninstall complete."
    if [[ "$TEST_RESET" == "true" ]]; then
        info "Git checkout preserved for immediate clean reinstall: $PROJECT_DIR"
    fi
    if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then
        info "Separate data-volume filesystem contents were intentionally preserved and the volume was detached from boot wiring."
    fi
    info "Intentionally preserved shared/ambiguous host infrastructure:"
    info "  - Docker packages, /var/lib/docker, OS users/groups/memberships"
    info "  - CrowdSec engine, bouncers, packages, repository, config, state, and logs"
    info "  - unmarked UFW and raw iptables/ip6tables rules"
    info "  - external backup directories"
    info "  - shared SOPS and common administrator tools"
    info "  - ambiguous swap/sysctl/apt-source settings during normal uninstall"
    printf '%s\n\n' '============================================================'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
