#!/usr/bin/env bash
# utilities/uninstall-vaultwarden.sh — Fully uninstall VaultWarden-OCI managed artifacts.
#
# Destructive by design. This script removes the Docker stack, systemd units,
# runtime secrets, installed configs, persistent state, CrowdSec integration,
# firewall rules, optional data-volume mount wiring, and project-installed
# helper binaries where safe. Shared host tooling such as Docker is preserved.

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
    log_info()     { printf '[%s] [%s] INFO %s%s\n'     "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$(_vw_dry_prefix)" "$*"; }
    log_success()  { printf '[%s] [%s] OK %s%s\n'       "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$(_vw_dry_prefix)" "$*"; }
    log_warn()     { printf '[%s] [%s] WARN %s%s\n'     "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$(_vw_dry_prefix)" "$*" >&2; }
    log_error()    { printf '[%s] [%s] ERROR %s\n'      "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$*" >&2; }
    log_debug()    { printf '[%s] [%s] DEBUG %s\n'      "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$*"; }
    log_hint()     { printf '[%s] [%s] HINT → %s%s\n'   "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$(_vw_dry_prefix)" "$*"; }
    log_rollback() { printf '[%s] [%s] ROLLBACK %s\n'   "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$*" >&2; }
    log_dry_run()  { printf '[%s] [%s] [DRY RUN] %s\n'  "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$*"; }
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
    Fully removes VaultWarden-OCI managed stack artifacts from this host:
      - Docker compose stack, managed containers, networks, volumes, and runtime secrets
      - systemd timers/services/drop-ins, /opt scripts, and /etc/vaultwarden
      - persistent VaultWarden state directory and optional data-volume fstab/mount wiring
      - CrowdSec services/packages/config/state, project firewall rules, and swapfile
      - standalone helper binaries uniquely installed by this project where safe

    Docker itself, /var/lib/docker, the docker group, common admin packages, SSH
    configuration, and unrelated firewall rules are intentionally preserved.

SUBCOMMANDS:
    run    Perform the idempotent uninstall
    help   Show this help

OPTIONS (used after 'run'):
    --test-reset
        Remove the stack and generated local installation artifacts, but preserve
        the Git checkout so the same branch can be installed again immediately.
        This is intended for repeated production-host acceptance testing. It does
        not restore the VM to a pristine OCI image or uninstall shared host tooling.

    --i-have-saved-my-recovery-kit
        Confirm that all Age keys shown by this script have been saved outside
        this host. Required when any managed Age key exists, unless --force is used.

    --dry-run
        Show what would be removed without changing the system. Does not require root.

    --force
        DANGEROUS: non-interactive destructive mode. Skips uninstall confirmation,
        backup prompt, external backup-dir prompt, and Age-key prompts. This can
        permanently delete VaultWarden data and key material; use only after
        recovery data has been verified outside this host.

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

# /28 is the current compose contract. /16 entries are retained for cleanup of
# historical installs and the setup-firewall deterministic baseline.
MANAGED_IPV4_SUBNETS=(
    172.21.0.0/28
    172.22.0.0/28
    172.23.0.0/28
    172.21.0.0/16
    172.22.0.0/16
    172.23.0.0/16
)

CROWDSEC_PACKAGES=(
    crowdsec-cloudflare-worker-bouncer
    crowdsec-firewall-bouncer-iptables
    crowdsec-firewall-bouncer-nftables
    crowdsec
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

_env_candidates_for_bootstrap() {
    # Prefer persistent root-owned/runtime config over repo-local .env. This
    # intentionally avoids load_project_environment because stale/broken data
    # volume installs still need to be uninstallable.
    local repo_env="${PROJECT_DIR}/.env"
    local state mount candidate

    [[ -f "$INSTALLED_ENV" ]] && printf '%s\n' "$INSTALLED_ENV"

    for candidate in "$INSTALLED_ENV" "$repo_env"; do
        [[ -f "$candidate" ]] || continue
        state="$(_read_env_value PROJECT_STATE_DIR "$candidate")"
        mount="$(_read_env_value DATA_VOLUME_MOUNT "$candidate")"
        [[ -n "$state" && -f "$state/config/install.env" ]] && printf '%s\n' "$state/config/install.env"
        [[ -n "$mount" && -f "$mount/config/install.env" ]] && printf '%s\n' "$mount/config/install.env"
    done

    [[ -f "$DEFAULT_STATE_DIR/config/install.env" ]] && printf '%s\n' "$DEFAULT_STATE_DIR/config/install.env"
    [[ -f "$DEFAULT_DATA_MOUNT/config/install.env" ]] && printf '%s\n' "$DEFAULT_DATA_MOUNT/config/install.env"
    [[ -f "$repo_env" ]] && printf '%s\n' "$repo_env"
    return 0
}

_unique_lines() { awk 'NF && !seen[$0]++'; }

resolve_paths() {
    local env_file p
    PROJECT_STATE_DIR=""
    DATA_VOLUME_MOUNT=""
    DATA_VOLUME_DEVICE=""
    SOPS_AGE_KEY_FILE_ENV=""
    AGE_KEY_FILE_ENV=""
    BACKUP_DIR=""
    COMPOSE_PROJECT_NAME_ENV=""

    while IFS= read -r env_file; do
        [[ -f "$env_file" ]] || continue
        if [[ -z "$PROJECT_STATE_DIR" ]]; then PROJECT_STATE_DIR="$(_read_env_value PROJECT_STATE_DIR "$env_file")"; fi
        if [[ -z "$DATA_VOLUME_MOUNT" ]]; then DATA_VOLUME_MOUNT="$(_read_env_value DATA_VOLUME_MOUNT "$env_file")"; fi
        if [[ -z "$DATA_VOLUME_DEVICE" ]]; then DATA_VOLUME_DEVICE="$(_read_env_value DATA_VOLUME_DEVICE "$env_file")"; fi
        if [[ -z "$SOPS_AGE_KEY_FILE_ENV" ]]; then SOPS_AGE_KEY_FILE_ENV="$(_read_env_value SOPS_AGE_KEY_FILE "$env_file")"; fi
        if [[ -z "$AGE_KEY_FILE_ENV" ]]; then AGE_KEY_FILE_ENV="$(_read_env_value AGE_KEY_FILE "$env_file")"; fi
        if [[ -z "$BACKUP_DIR" ]]; then BACKUP_DIR="$(_read_env_value BACKUP_DIR "$env_file")"; fi
        if [[ -z "$COMPOSE_PROJECT_NAME_ENV" ]]; then COMPOSE_PROJECT_NAME_ENV="$(_read_env_value COMPOSE_PROJECT_NAME "$env_file")"; fi
    done < <(_env_candidates_for_bootstrap | _unique_lines)

    if [[ -z "$PROJECT_STATE_DIR" && -n "$DATA_VOLUME_MOUNT" ]]; then
        PROJECT_STATE_DIR="$DATA_VOLUME_MOUNT"
    fi
    PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-$DEFAULT_STATE_DIR}"
    DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-}"
    COMPOSE_PROJECT_NAME_ENV="${COMPOSE_PROJECT_NAME_ENV:-vaultwarden-oci}"
    BACKUP_DIR="${BACKUP_DIR:-${PROJECT_STATE_DIR}/backups}"
    STORAGE_MODE="boot-volume"
    DATA_MOUNT_MOUNTED=false
    DATA_MOUNT_SENTINEL=false

    if [[ -n "$DATA_VOLUME_DEVICE" ]]; then
        STORAGE_MODE="separate block-storage"
        [[ "$DATA_VOLUME_MOUNT" == /* ]] || warn "DATA_VOLUME_MOUNT is not absolute/safe: ${DATA_VOLUME_MOUNT:-<unset>}"
        if [[ -n "$DATA_VOLUME_MOUNT" && "$PROJECT_STATE_DIR" != "$DATA_VOLUME_MOUNT" ]]; then
            warn "Separate-volume config mismatch: PROJECT_STATE_DIR ($PROJECT_STATE_DIR) != DATA_VOLUME_MOUNT ($DATA_VOLUME_MOUNT). Conservatively using mount path for data-volume cleanup decisions."
        fi
        if [[ -n "$DATA_VOLUME_MOUNT" ]] && mountpoint -q "$DATA_VOLUME_MOUNT" 2>/dev/null; then DATA_MOUNT_MOUNTED=true; fi
        if [[ -n "$DATA_VOLUME_MOUNT" && -f "$DATA_VOLUME_MOUNT/.vw-data-volume" ]]; then DATA_MOUNT_SENTINEL=true; fi
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

    local tmp=()
    while IFS= read -r p; do
        tmp+=("$p")
    done < <(printf '%s\n' "${MANAGED_AGE_KEY_PATHS[@]}" | _unique_lines)
    MANAGED_AGE_KEY_PATHS=("${tmp[@]}")
    return 0
}

_dry_run_line() { echo "  - $*"; }

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
    if [[ -z "$pubkey" ]]; then
        pubkey="$(grep -E '^age1[a-z0-9]+' "$keyfile" 2>/dev/null | head -1 || true)"
    fi
    [[ -n "$pubkey" ]] || return 1
    printf '%s' "$pubkey"
}

_existing_age_keys() {
    local key
    for key in "${MANAGED_AGE_KEY_PATHS[@]}"; do
        [[ -f "$key" ]] && printf '%s\n' "$key"
    done | _unique_lines
    return 0
}

_show_age_keys() {
    local key pub
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        pub="$(_extract_age_public_key "$key" 2>/dev/null || true)"
        echo "  ${key}"
        echo "    public key: ${pub:-"(could not extract; inspect manually)"}"
    done < <(_existing_age_keys)
}

_confirm_age_key_safety() {
    local keys_present=false
    if [[ -n "$(_existing_age_keys)" ]]; then
        keys_present=true
    fi

    if [[ "$keys_present" != "true" ]]; then
        info "No managed Age key files found — no Age-key destruction guard needed."
        return 0
    fi

    if [[ "$FORCE" == "true" ]]; then
        warn "--force active — skipping Age-key checks. Managed Age keys will be deleted."
        _show_age_keys
        return 0
    fi

    if [[ "$I_HAVE_SAVED_RECOVERY_KIT" != "true" ]]; then
        echo ""
        echo "════════════════════════════════════════════════════════════"
        warn "ENCRYPTION KEY DESTRUCTION WARNING"
        warn "The following managed Age key file(s) exist and will be deleted:"
        _show_age_keys
        warn ""
        warn "Without the matching private key, existing Age-encrypted backups are unrecoverable."
        warn "Export or copy your recovery kit to a location outside this host, then re-run:"
        warn "  sudo bash $0 run --i-have-saved-my-recovery-kit"
        echo "════════════════════════════════════════════════════════════"
        echo ""
        die "Uninstall aborted — Age key preservation not confirmed. No changes made."
    fi

    echo ""
    echo "════════════════════════════════════════════════════════════"
    warn "FINAL CONFIRMATION — MANAGED AGE KEYS WILL BE DESTROYED"
    warn "Confirm that the following key(s) are saved outside this host:"
    _show_age_keys
    echo "════════════════════════════════════════════════════════════"
    echo ""

    local first_key first_pub typed
    first_key="$(_existing_age_keys | head -1)"
    first_pub="$(_extract_age_public_key "$first_key" 2>/dev/null || true)"
    if [[ -n "$first_pub" ]]; then
        warn "Type the first Age public key shown above to continue."
        read -r -t 300 -p "Age public key: " typed || typed=""
        [[ "$typed" == "$first_pub" ]] || die "Confirmation mismatch — uninstall aborted before destructive changes."
    else
        warn "Could not extract a public key automatically."
        read -r -t 300 -p "Type DELETE-MY-KEYS to continue: " typed || typed=""
        [[ "$typed" == "DELETE-MY-KEYS" ]] || die "Confirmation not given — uninstall aborted before destructive changes."
    fi
    success "Age-key preservation confirmed."
}

_run_if_exists() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1
}

_path_is_inside() {
    local child="$1" parent="$2"
    [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

_backup_dir_is_external_to_state() {
    [[ -n "${BACKUP_DIR:-}" ]] || return 1
    ! _path_is_inside "$BACKUP_DIR" "$PROJECT_STATE_DIR"
}

disable_systemd_units() {
    info "Step 1: Disabling and removing VaultWarden systemd units..."

    local unit dest dropin
    if ! _run_if_exists systemctl; then
        warn "systemctl not found — skipping systemd cleanup."
        return 0
    fi

    for unit in "${MANAGED_TIMERS[@]}" vaultwarden-startup.service; do
        if systemctl is-enabled "$unit" >/dev/null 2>&1 || systemctl is-active "$unit" >/dev/null 2>&1; then
            systemctl disable --now "$unit" 2>/dev/null \
                && success "Disabled: $unit" \
                || warn "Could not disable $unit (may already be inactive)."
        fi
    done

    for unit in "${MANAGED_SERVICES[@]}"; do
        [[ "$unit" == *"@"* ]] && continue
        systemctl stop "$unit" 2>/dev/null || true
    done

    for unit in "${MANAGED_TIMERS[@]}" "${MANAGED_SERVICES[@]}"; do
        dest="/etc/systemd/system/${unit}"
        if [[ -f "$dest" ]]; then
            rm -f "$dest" && success "Removed unit file: $dest"
        fi
        dropin="/etc/systemd/system/${unit}.d"
        if [[ -d "$dropin" ]]; then
            local managed_dropin
            for managed_dropin in 10-state-dir.conf 20-identity.conf 30-run-as-root.conf; do
                if [[ -f "$dropin/$managed_dropin" ]]; then
                    rm -f "$dropin/$managed_dropin" && success "Removed managed drop-in: $dropin/$managed_dropin"
                fi
            done
            rmdir "$dropin" 2>/dev/null || true
        fi
    done

    systemctl reset-failed 'vaultwarden-notify-failure@*.service' 2>/dev/null || true
    for unit in "${MANAGED_SERVICES[@]}"; do
        [[ "$unit" == *"@"* ]] && continue
        systemctl reset-failed "$unit" 2>/dev/null || true
    done

    local docker_dropin="/etc/systemd/system/docker.service.d/10-vaultwarden-data-volume.conf"
    if [[ -f "$docker_dropin" ]]; then
        rm -f "$docker_dropin" && success "Removed Docker mount-guard drop-in: $docker_dropin"
        rmdir /etc/systemd/system/docker.service.d 2>/dev/null || true
    fi

    systemctl daemon-reload 2>/dev/null || true
    return 0
}

remove_docker_stack() {
    info "Step 2: Removing Docker stack, containers, networks, and volumes..."

    if ! _run_if_exists docker; then
        warn "docker not found — skipping Docker runtime cleanup."
        return 0
    fi

    if [[ -f "${PROJECT_DIR}/docker-compose.yml" ]]; then
        docker compose -f "${PROJECT_DIR}/docker-compose.yml" down \
            --volumes --remove-orphans --timeout 30 2>/dev/null \
            && success "Docker Compose stack stopped and volumes removed." \
            || warn "docker compose down had errors; named and labelled cleanup will continue."
    fi

    local project_name="${COMPOSE_PROJECT_NAME_ENV:-vaultwarden-oci}"
    local name cid
    for name in "${MANAGED_CONTAINERS[@]}"; do
        cid="$(docker ps -aq --filter "name=^/${name}$" 2>/dev/null || true)"
        [[ -n "$cid" ]] || continue
        docker rm -f "$cid" 2>/dev/null && success "Removed managed container: $name" || warn "Could not remove container: $name"
    done

    while IFS= read -r cid; do
        [[ -n "$cid" ]] || continue
        docker rm -f "$cid" 2>/dev/null && success "Removed compose-labelled container: $cid" || true
    done < <(docker ps -aq --filter "label=com.docker.compose.project=${project_name}" 2>/dev/null || true)

    info "Skipping Docker Swarm secret deletion; current compose secrets are file-backed under /run/vaultwarden-oci/secrets."

    local vol
    while IFS= read -r vol; do
        [[ -n "$vol" ]] || continue
        docker volume rm "$vol" 2>/dev/null && success "Removed compose-labelled Docker volume: $vol" || warn "Could not remove Docker volume: $vol"
    done < <(docker volume ls -q --filter "label=com.docker.compose.project=${project_name}" 2>/dev/null || true)

    while IFS= read -r vol; do
        [[ -n "$vol" ]] || continue
        docker volume rm "$vol" 2>/dev/null && success "Removed safe-prefix Docker volume: $vol" || true
    done < <(docker volume ls -q 2>/dev/null | awk '/^vaultwarden-oci_/ {print}' || true)

    local net
    for net in "${MANAGED_NETWORKS[@]}"; do
        docker network rm "$net" 2>/dev/null && success "Removed Docker network: $net" || true
    done

    while IFS= read -r net; do
        [[ -n "$net" ]] || continue
        docker network rm "$net" 2>/dev/null && success "Removed compose-labelled Docker network: $net" || true
    done < <(
        docker network ls -q --filter "label=com.docker.compose.project=${project_name}" 2>/dev/null \
            | xargs -r docker network inspect --format '{{.Name}}' 2>/dev/null || true
    )
    return 0
}

_confirm_external_backup_delete() {
    [[ -n "${BACKUP_DIR:-}" ]] || return 1
    _path_is_inside "$BACKUP_DIR" "$PROJECT_STATE_DIR" && return 0
    warn "BACKUP_DIR is outside the managed state directory: $BACKUP_DIR"
    if [[ "$FORCE" == "true" ]]; then
        warn "--force active — external BACKUP_DIR will still be preserved by default. Remove manually if intended."
        return 1
    fi
    local answer
    read -r -t 300 -p "Delete external BACKUP_DIR '$BACKUP_DIR'? Type DELETE-BACKUPS to confirm, anything else to preserve: " answer || answer=""
    [[ "$answer" == "DELETE-BACKUPS" ]]
}

_remove_fstab_mount() {
    local mountpoint="$1" source="${2:-}"
    [[ -n "$mountpoint" && -f /etc/fstab ]] || return 0

    if ! awk -v mp="$mountpoint" -v src="$source" '($2 == mp) || (src != "" && $1 == src) { found=1 } END { exit(found ? 0 : 1) }' /etc/fstab; then
        info "No fstab entry found for mount point/source: $mountpoint ${source:-}"
        return 0
    fi

    local tmp
    tmp="$(mktemp /etc/fstab.vw-uninstall.XXXXXXXXXX)" || return 1
    if awk -v mp="$mountpoint" -v src="$source" '!(($2 == mp) || (src != "" && $1 == src)) { print }' /etc/fstab > "$tmp" \
        && mv -f "$tmp" /etc/fstab; then
        success "Removed fstab entry for data volume: $mountpoint"
    else
        rm -f "$tmp" 2>/dev/null || true
        warn "Could not remove fstab entry for $mountpoint. Remove it manually."
        return 1
    fi
    return 0
}

remove_state_and_mount() {
    info "Step 3: Removing persistent state and optional data-volume mount..."

    if [[ -z "$DATA_VOLUME_DEVICE" ]]; then
        if [[ -d "$PROJECT_STATE_DIR" ]]; then
            _safe_rm_rf "$PROJECT_STATE_DIR" && success "Removed boot-volume state directory: $PROJECT_STATE_DIR"
        else
            info "State directory not found: $PROJECT_STATE_DIR"
        fi
        if [[ -n "${BACKUP_DIR:-}" && -d "$BACKUP_DIR" ]] && ! _path_is_inside "$BACKUP_DIR" "$PROJECT_STATE_DIR"; then
            if _confirm_external_backup_delete; then
                _safe_rm_rf "$BACKUP_DIR" && success "Removed explicitly confirmed external backup directory: $BACKUP_DIR"
            else
                warn "Preserved external backup directory: $BACKUP_DIR"
            fi
        fi
        return 0
    fi

    [[ "$DATA_VOLUME_MOUNT" == /* ]] || die "Separate block-storage uninstall requires an absolute DATA_VOLUME_MOUNT; got '${DATA_VOLUME_MOUNT:-<unset>}'."
    if [[ "$PROJECT_STATE_DIR" != "$DATA_VOLUME_MOUNT" ]]; then
        warn "PROJECT_STATE_DIR does not match DATA_VOLUME_MOUNT; deleting only safely identified mounted data-volume contents."
    fi

    local mounted=false sentinel=false source=""
    mountpoint -q "$DATA_VOLUME_MOUNT" 2>/dev/null && mounted=true
    [[ -f "$DATA_VOLUME_MOUNT/.vw-data-volume" ]] && sentinel=true
    if [[ "$mounted" == "true" ]]; then
        source="$(findmnt -n -o SOURCE --target "$DATA_VOLUME_MOUNT" 2>/dev/null || true)"
    fi

    _remove_fstab_mount "$DATA_VOLUME_MOUNT" "$source"

    local docker_dropin="/etc/systemd/system/docker.service.d/10-vaultwarden-data-volume.conf"
    if [[ -f "$docker_dropin" ]]; then
        rm -f "$docker_dropin" && success "Removed Docker mount-guard drop-in: $docker_dropin"
        rmdir /etc/systemd/system/docker.service.d 2>/dev/null || true
    fi
    _run_if_exists systemctl && systemctl daemon-reload 2>/dev/null || true

    if [[ "$mounted" == "true" && "$sentinel" == "true" ]]; then
        if command -v chattr >/dev/null 2>&1; then
            chattr -i "$DATA_VOLUME_MOUNT/.vw-data-volume" 2>/dev/null || true
        fi
        # Delete contents of the managed filesystem, not the block device itself.
        find "$DATA_VOLUME_MOUNT" -mindepth 1 -maxdepth 1 -xdev -exec rm -rf --one-file-system -- {} +
        success "Removed project data from mounted data volume: $DATA_VOLUME_MOUNT"
    elif [[ "$mounted" == "true" ]]; then
        if [[ "$FORCE" == "true" ]]; then
            warn "Mounted data volume lacks .vw-data-volume sentinel; --force active, but contents are preserved for safety."
        fi
        die "Mounted $DATA_VOLUME_MOUNT lacks .vw-data-volume sentinel. Refusing to delete unknown mounted contents."
    else
        warn "$DATA_VOLUME_MOUNT is not mounted; refusing to recursively delete mountpoint contents."
        if [[ -d "$DATA_VOLUME_MOUNT" ]] && [[ -n "$(find "$DATA_VOLUME_MOUNT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
            die "Unmounted data mount path is non-empty. Refusing to report a complete uninstall: $DATA_VOLUME_MOUNT"
        fi
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
        rmdir "$DATA_VOLUME_MOUNT" 2>/dev/null \
            && success "Removed empty mountpoint directory: $DATA_VOLUME_MOUNT" \
            || die "Mountpoint still exists/non-empty after cleanup: $DATA_VOLUME_MOUNT"
    fi
    return 0
}

_repo_artifact_is_preserved_backup() {
    local path="$1"
    [[ -n "${BACKUP_DIR:-}" ]] || return 1
    [[ "$path" == "$BACKUP_DIR" ]] || return 1
    [[ -d "$BACKUP_DIR" ]] || return 1
    _backup_dir_is_external_to_state
}

remove_repo_local_install_artifacts() {
    [[ "$TEST_RESET" == "true" ]] || return 0
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
            warn "Preserving explicitly retained external BACKUP_DIR inside checkout: $path"
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
    done < <(
        find "$PROJECT_DIR" -mindepth 1 -maxdepth 1 -type d \
            \( -name '.restore-tmp*' -o -name '.backup-tmp*' \) -print 2>/dev/null || true
    )

    success "Git checkout preserved for immediate reinstall: $PROJECT_DIR"
}

remove_installed_files() {
    info "Step 5: Removing installed scripts and configuration..."

    _safe_rm_rf /opt/vaultwarden-scripts || true
    _safe_rm_rf /etc/vaultwarden || true

    if [[ "$TEST_RESET" == "true" ]]; then
        remove_repo_local_install_artifacts
    fi
    return 0
}

remove_project_checkout() {
    [[ "$TEST_RESET" == "true" ]] && return 0

    info "Step 11: Removing the project checkout after host cleanup..."
    cd /
    if [[ "$PROJECT_DIR" == */VaultWarden-OCI || "$PROJECT_BASENAME" == "VaultWarden-OCI" ]]; then
        if _backup_dir_is_external_to_state && _path_is_inside "$BACKUP_DIR" "$PROJECT_DIR" && [[ -d "$BACKUP_DIR" ]]; then
            warn "Preserving project checkout because external BACKUP_DIR is inside it: $BACKUP_DIR"
            warn "Move/delete the backup directory manually"
            warn "Then remove the checkout manually if desired: $PROJECT_DIR"
            return 0
        fi
        _safe_rm_rf "$PROJECT_DIR" || true
        success "Removed project checkout: $PROJECT_DIR"
    else
        warn "Project directory does not look like a VaultWarden-OCI checkout; leaving in place: $PROJECT_DIR"
    fi
    return 0
}

remove_sops_and_packages() {
    info "Step 6: Removing project-installed standalone helper binaries..."

    if [[ -f /usr/local/bin/sops ]]; then
        rm -f /usr/local/bin/sops && success "Removed /usr/local/bin/sops"
    else
        info "No standalone /usr/local/bin/sops found."
    fi

    warn "Leaving shared distro packages installed by default (cron, git, curl, jq, sqlite3, ufw, python3, etc.)."
    return 0
}

remove_crowdsec() {
    info "Step 7: Removing CrowdSec integration, packages, config, and state..."

    local svc
    for svc in crowdsec-cloudflare-worker-bouncer crowdsec-firewall-bouncer crowdsec; do
        if _run_if_exists systemctl; then
            systemctl disable --now "$svc" 2>/dev/null || true
            systemctl reset-failed "$svc" 2>/dev/null || true
        fi
    done

    rm -f /etc/systemd/system/crowdsec-cloudflare-worker-bouncer.service 2>/dev/null || true
    rm -f /usr/local/bin/crowdsec-cloudflare-worker-bouncer 2>/dev/null || true
    _run_if_exists systemctl && systemctl daemon-reload 2>/dev/null || true

    local pkg
    for pkg in "${CROWDSEC_PACKAGES[@]}"; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            operation_package_run env DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge "$pkg" \
                && success "Removed package: $pkg" \
                || die "Could not purge CrowdSec package: $pkg"
        fi
    done

    rm -f \
        /etc/apt/sources.list.d/crowdsec_crowdsec.list \
        /etc/apt/sources.list.d/crowdsec_crowdsec_crowdsec.list \
        /etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg \
        /etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.asc \
        2>/dev/null || true

    _safe_rm_rf /etc/crowdsec || true
    _safe_rm_rf /var/lib/crowdsec || true
    _safe_rm_rf /var/log/crowdsec || true

    operation_package_run apt-get update -qq || warn "apt-get update failed after CrowdSec repository removal."
    operation_package_run apt-get autoremove -y || warn "apt-get autoremove reported errors."
    return 0
}

_remove_all_managed_ufw_rules() {
    local rule_num removed=0 max_removals=500

    while true; do
        rule_num="$(
            ufw status numbered 2>/dev/null \
                | awk '/(^|[[:space:]])(80|443)\/tcp([[:space:]]|$)/ {
                    gsub(/\[|\]/, "", $1)
                    print $1
                    exit
                }'
        )"
        [[ -n "$rule_num" ]] || break

        if ! yes | ufw delete "$rule_num" >/dev/null 2>&1; then
            die "Could not delete UFW HTTP/HTTPS rule number $rule_num"
        fi
        removed=$((removed + 1))
        if (( removed >= max_removals )); then
            die "UFW cleanup exceeded ${max_removals} managed-rule deletions; refusing a possible infinite cleanup loop."
        fi
    done

    success "Removed all detected UFW HTTP/HTTPS rules (${removed} numbered rule(s)); SSH rules preserved."
}

remove_firewall_rules() {
    info "Step 8: Removing UFW and iptables rules managed by VaultWarden-OCI..."

    if command -v ufw >/dev/null 2>&1; then
        # Delete broad historical rules first, then exhaust every numbered
        # Cloudflare-specific 80/443 rule added by setup-firewall.sh.
        ufw delete allow 80/tcp 2>/dev/null || true
        ufw delete allow 443/tcp 2>/dev/null || true
        _remove_all_managed_ufw_rules
    fi

    if command -v iptables >/dev/null 2>&1; then
        local subnet
        for subnet in "${MANAGED_IPV4_SUBNETS[@]}"; do
            while iptables -t nat -D POSTROUTING -s "$subnet" ! -o docker0 -j MASQUERADE 2>/dev/null; do
                success "Removed NAT MASQUERADE for $subnet"
            done
            if iptables -t filter -S DOCKER-USER >/dev/null 2>&1; then
                while iptables -t filter -D DOCKER-USER -s "$subnet" -j ACCEPT 2>/dev/null; do
                    success "Removed DOCKER-USER ACCEPT for $subnet"
                done
            fi
        done

        if command -v netfilter-persistent >/dev/null 2>&1; then
            if netfilter-persistent save >/dev/null 2>&1; then
                success "Persisted cleaned netfilter ruleset."
            else
                die "Live VaultWarden iptables rules were removed, but netfilter-persistent save failed. Stale rules could return after reboot."
            fi
        fi
    fi
    return 0
}

remove_swap_and_apt_sources() {
    info "Step 9: Removing swapfile and project-added apt source files..."

    if swapon --show 2>/dev/null | grep -q '^/swapfile[[:space:]]'; then
        swapoff /swapfile 2>/dev/null || die "swapoff /swapfile failed"
    fi
    if [[ -e /swapfile ]]; then
        rm -f /swapfile && success "Removed /swapfile"
    fi

    if [[ -f /etc/fstab ]] && grep -q '^/swapfile[[:space:]]' /etc/fstab 2>/dev/null; then
        local tmp
        tmp="$(mktemp /etc/fstab.vw-swap.XXXXXXXXXX)" || return 1
        if sed '/^\/swapfile[[:space:]]/d' /etc/fstab > "$tmp" && mv -f "$tmp" /etc/fstab; then
            success "Removed /swapfile fstab entry"
        else
            rm -f "$tmp" 2>/dev/null || true
            die "Could not remove /swapfile fstab entry"
        fi
    fi

    if grep -q '^vm\.swappiness' /etc/sysctl.conf 2>/dev/null; then
        sed -i '/^vm\.swappiness/d' /etc/sysctl.conf || die "Could not remove vm.swappiness from /etc/sysctl.conf"
        sysctl -q vm.swappiness=60 2>/dev/null || true
    fi

    rm -f /etc/apt/sources.list.d/ubuntu-universe.list 2>/dev/null || true
    operation_package_run apt-get update -qq || warn "apt-get update failed after apt source cleanup."
    return 0
}

remove_group_memberships() {
    info "Step 10: Removing VaultWarden-specific group metadata..."

    if getent group vaultwarden >/dev/null 2>&1; then
        groupdel vaultwarden 2>/dev/null \
            && success "Removed system group: vaultwarden" \
            || die "Could not remove system group 'vaultwarden'; inspect processes or memberships still using it."
    fi

    warn "Leaving Docker packages, /var/lib/docker, docker group, and operator Docker membership unchanged."
    return 0
}

remove_runtime_artifacts() {
    info "Step 12: Removing runtime secrets and operation state..."

    # This runs only after the final operation phase is recorded. Do not unlink
    # /run/lock/vaultwarden-operations.lock or the uninstall-specific lock while
    # their flock FDs are held: unlinking a live lock path creates a second inode
    # and can split coordination. Empty /run/lock files are harmless, ephemeral,
    # and reusable by the next install.
    _safe_rm_rf /run/vaultwarden-oci || true

    success "Removed VaultWarden runtime secrets and operation state."
    info "Reusable empty coordination lock files under /run/lock are intentionally preserved."
}

_residual() {
    local message="$1"
    warn "RESIDUAL: $message"
    UNINSTALL_RESIDUALS=$((UNINSTALL_RESIDUALS + 1))
}

verify_uninstall_complete() {
    info "Step 13: Verifying managed stack artifacts are gone..."
    UNINSTALL_RESIDUALS=0

    local unit dropin path pkg subnet project_name="${COMPOSE_PROJECT_NAME_ENV:-vaultwarden-oci}"

    for unit in "${MANAGED_TIMERS[@]}" "${MANAGED_SERVICES[@]}"; do
        [[ ! -e "/etc/systemd/system/${unit}" ]] || _residual "/etc/systemd/system/${unit}"
        for dropin in 10-state-dir.conf 20-identity.conf 30-run-as-root.conf; do
            [[ ! -e "/etc/systemd/system/${unit}.d/${dropin}" ]] \
                || _residual "/etc/systemd/system/${unit}.d/${dropin}"
        done
    done
    [[ ! -e /etc/systemd/system/docker.service.d/10-vaultwarden-data-volume.conf ]] \
        || _residual "/etc/systemd/system/docker.service.d/10-vaultwarden-data-volume.conf"

    for path in \
        /opt/vaultwarden-scripts \
        /etc/vaultwarden \
        /run/vaultwarden-oci \
        /usr/local/bin/sops \
        /usr/local/bin/crowdsec-cloudflare-worker-bouncer \
        /etc/systemd/system/crowdsec-cloudflare-worker-bouncer.service \
        /etc/crowdsec \
        /var/lib/crowdsec \
        /var/log/crowdsec \
        /swapfile; do
        [[ ! -e "$path" ]] || _residual "$path"
    done

    if [[ -z "$DATA_VOLUME_DEVICE" ]]; then
        [[ ! -e "$PROJECT_STATE_DIR" ]] || _residual "managed state directory $PROJECT_STATE_DIR"
    else
        if mountpoint -q "$DATA_VOLUME_MOUNT" 2>/dev/null; then
            _residual "data volume still mounted at $DATA_VOLUME_MOUNT"
        fi
        if [[ -d "$DATA_VOLUME_MOUNT" ]] && [[ -n "$(find "$DATA_VOLUME_MOUNT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
            _residual "data mount path remains non-empty: $DATA_VOLUME_MOUNT"
        fi
        if [[ -f /etc/fstab ]] \
            && awk -v mp="$DATA_VOLUME_MOUNT" -v src="$DATA_VOLUME_DEVICE" '($2 == mp) || ($1 == src) { found=1 } END { exit(found ? 0 : 1) }' /etc/fstab; then
            _residual "fstab still references data volume mount/device"
        fi
    fi

    if [[ "$TEST_RESET" == "true" ]]; then
        [[ -d "$PROJECT_DIR/.git" ]] || _residual "test-reset checkout is not preserved as a Git checkout: $PROJECT_DIR"
        for path in \
            "$PROJECT_DIR/.env" \
            "$PROJECT_DIR/.sops.yaml" \
            "$PROJECT_DIR/docker-compose.yml" \
            "$PROJECT_DIR/docker-compose.override.yml" \
            "$PROJECT_DIR/docker-compose.override.dev.yml" \
            "$PROJECT_DIR/rclone.conf" \
            "$PROJECT_DIR/secrets" \
            "$PROJECT_DIR/logs" \
            "$PROJECT_DIR/data" \
            "$PROJECT_DIR/caddy/data" \
            "$PROJECT_DIR/caddy/config"; do
            [[ ! -e "$path" ]] || _residual "checkout-local install artifact $path"
        done
    elif [[ "$PROJECT_DIR" == */VaultWarden-OCI || "$PROJECT_BASENAME" == "VaultWarden-OCI" ]]; then
        if ! (_backup_dir_is_external_to_state && _path_is_inside "$BACKUP_DIR" "$PROJECT_DIR" && [[ -d "$BACKUP_DIR" ]]); then
            [[ ! -e "$PROJECT_DIR" ]] || _residual "project checkout $PROJECT_DIR"
        fi
    fi

    if _run_if_exists docker; then
        local name cid vol net
        for name in "${MANAGED_CONTAINERS[@]}"; do
            cid="$(docker ps -aq --filter "name=^/${name}$" 2>/dev/null || true)"
            [[ -z "$cid" ]] || _residual "managed Docker container $name"
        done
        cid="$(docker ps -aq --filter "label=com.docker.compose.project=${project_name}" 2>/dev/null || true)"
        [[ -z "$cid" ]] || _residual "compose-labelled container(s) for project ${project_name}"

        vol="$(docker volume ls -q --filter "label=com.docker.compose.project=${project_name}" 2>/dev/null || true)"
        [[ -z "$vol" ]] || _residual "compose-labelled Docker volume(s) for project ${project_name}"
        vol="$(docker volume ls -q 2>/dev/null | awk '/^vaultwarden-oci_/ {print}' || true)"
        [[ -z "$vol" ]] || _residual "safe-prefix VaultWarden Docker volume(s)"

        for net in "${MANAGED_NETWORKS[@]}"; do
            docker network inspect "$net" >/dev/null 2>&1 && _residual "managed Docker network $net"
        done
        net="$(
            docker network ls -q --filter "label=com.docker.compose.project=${project_name}" 2>/dev/null \
                | xargs -r docker network inspect --format '{{.Name}}' 2>/dev/null || true
        )"
        [[ -z "$net" ]] || _residual "compose-labelled Docker network(s) for project ${project_name}"
    fi

    for pkg in "${CROWDSEC_PACKAGES[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 && _residual "CrowdSec package $pkg"
    done

    if command -v ufw >/dev/null 2>&1; then
        if ufw status numbered 2>/dev/null \
            | awk '/(^|[[:space:]])(80|443)\/tcp([[:space:]]|$)/ { found=1 } END { exit(found ? 0 : 1) }'; then
            _residual "UFW still has HTTP/HTTPS rules"
        fi
    fi

    if command -v iptables >/dev/null 2>&1; then
        for subnet in "${MANAGED_IPV4_SUBNETS[@]}"; do
            if iptables -t nat -C POSTROUTING -s "$subnet" ! -o docker0 -j MASQUERADE 2>/dev/null; then
                _residual "live NAT MASQUERADE rule for $subnet"
            fi
            if iptables -t filter -S DOCKER-USER >/dev/null 2>&1 \
                && iptables -t filter -C DOCKER-USER -s "$subnet" -j ACCEPT 2>/dev/null; then
                _residual "live DOCKER-USER ACCEPT rule for $subnet"
            fi
        done
    fi

    if [[ -f /etc/iptables/rules.v4 ]]; then
        for subnet in "${MANAGED_IPV4_SUBNETS[@]}"; do
            if grep -F "$subnet" /etc/iptables/rules.v4 2>/dev/null \
                | grep -Eq 'MASQUERADE|DOCKER-USER'; then
                _residual "persisted netfilter rule for $subnet in /etc/iptables/rules.v4"
            fi
        done
    fi

    if [[ -f /etc/fstab ]] && grep -q '^/swapfile[[:space:]]' /etc/fstab 2>/dev/null; then
        _residual "/etc/fstab still references /swapfile"
    fi

    getent group vaultwarden >/dev/null 2>&1 && _residual "system group vaultwarden"

    if (( UNINSTALL_RESIDUALS > 0 )); then
        die "Uninstall incomplete — ${UNINSTALL_RESIDUALS} managed artifact(s) remain. Review RESIDUAL lines above."
    fi

    success "Residual verification passed: no managed stack artifacts remain."
}

show_summary() {
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "   VaultWarden-OCI Full Uninstaller"
    echo "   Project dir       : ${PROJECT_DIR}"
    echo "   Project state dir : ${PROJECT_STATE_DIR}"
    echo "   Storage mode      : ${STORAGE_MODE}"
    echo "   Data device       : ${DATA_VOLUME_DEVICE:-<unset>}"
    echo "   Data mount        : ${DATA_VOLUME_MOUNT:-<unset>}"
    if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then
        echo "   Mount status      : mounted=${DATA_MOUNT_MOUNTED} sentinel=${DATA_MOUNT_SENTINEL}"
    fi
    echo "   Running as        : $(whoami)  (real user: ${REAL_USER})"
    [[ "$TEST_RESET" == "true" ]] && echo "   Reset mode        : TEST RESET — preserve Git checkout; remove generated install artifacts"
    [[ "$DRY_RUN" == "true" ]] && echo "   Mode              : DRY RUN — no changes will be made"
    [[ "$FORCE" == "true" ]] && echo "   Mode              : FORCE — non-interactive destructive cleanup"
    echo "════════════════════════════════════════════════════════════"
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        warn "DRY RUN MODE — would remove:"
        _dry_run_line "systemd timers: ${MANAGED_TIMERS[*]}"
        _dry_run_line "systemd services: ${MANAGED_SERVICES[*]}"
        _dry_run_line "systemd managed drop-ins: 10-state-dir.conf 20-identity.conf 30-run-as-root.conf"
        _dry_run_line "Docker compose stack via docker-compose.yml; containers: ${MANAGED_CONTAINERS[*]}"
        _dry_run_line "Docker networks: ${MANAGED_NETWORKS[*]}; compose-labelled/safe-prefix volumes"
        _dry_run_line "runtime secrets/state: /run/vaultwarden-oci; inactive VaultWarden-specific locks"
        _dry_run_line "installed config and key dir: /etc/vaultwarden"
        _dry_run_line "installed scripts: /opt/vaultwarden-scripts"

        if [[ "$TEST_RESET" == "true" ]]; then
            _dry_run_line "preserve Git checkout: ${PROJECT_DIR}"
            _dry_run_line "remove generated checkout-local config/secrets/compose/runtime artifacts for a clean reinstall"
        else
            _dry_run_line "project checkout: ${PROJECT_DIR}"
        fi

        if [[ -z "${DATA_VOLUME_DEVICE:-}" ]]; then
            _dry_run_line "boot-volume managed state directory: ${PROJECT_STATE_DIR}"
            if [[ -n "${BACKUP_DIR:-}" && "${BACKUP_DIR}" != "${PROJECT_STATE_DIR}"/* && "${BACKUP_DIR}" != "${PROJECT_STATE_DIR}" ]]; then
                _dry_run_line "external BACKUP_DIR would be preserved unless explicitly confirmed: ${BACKUP_DIR}"
            fi
        else
            _dry_run_line "separate block-storage mode: device=${DATA_VOLUME_DEVICE} mount=${DATA_VOLUME_MOUNT:-<unset>} mounted=${DATA_MOUNT_MOUNTED} sentinel=${DATA_MOUNT_SENTINEL}"
            if [[ "${DATA_MOUNT_MOUNTED}" != "true" ]]; then
                _dry_run_line "unmounted mountpoint contents will NOT be recursively deleted"
            elif [[ "${DATA_MOUNT_SENTINEL}" != "true" ]]; then
                _dry_run_line "mounted volume lacks .vw-data-volume sentinel; contents will NOT be deleted"
            else
                _dry_run_line "mounted data-volume contents under ${DATA_VOLUME_MOUNT} would be removed (block device itself preserved)"
            fi
            _dry_run_line "fstab entry and Docker mount guard: /etc/systemd/system/docker.service.d/10-vaultwarden-data-volume.conf"
        fi

        _dry_run_line "Age key paths:"
        local key
        for key in "${MANAGED_AGE_KEY_PATHS[@]}"; do _dry_run_line "  ${key}"; done
        _dry_run_line "CrowdSec services/packages/config/state including Cloudflare and both firewall-bouncer backends"
        _dry_run_line "all UFW 80/443 rules and VaultWarden iptables /28 + historical /16 bridge rules"
        _dry_run_line "persist cleaned iptables rules with netfilter-persistent when installed"
        _dry_run_line "swapfile /swapfile and vm.swappiness entry"
        _dry_run_line "standalone helper binary: /usr/local/bin/sops when present"
        _dry_run_line "Docker packages/runtime data are preserved by default"
        _dry_run_line "vaultwarden group; docker group/memberships preserved"
        _dry_run_line "post-cleanup residual verification"
        echo ""
        info "DRY RUN complete — no changes made."
        exit 0
    fi
    return 0
}

offer_final_backup() {
    if [[ "$FORCE" == "true" ]]; then
        warn "--force active — skipping final backup prompt."
        return 0
    fi

    if [[ ! -f "${PROJECT_DIR}/backup.sh" ]]; then
        return 0
    fi

    echo ""
    echo "════════════════════════════════════════════════════════════"
    warn "PRE-DESTRUCTION BACKUP OFFER"
    warn "It is strongly recommended to take a final encrypted full backup."
    echo "════════════════════════════════════════════════════════════"
    echo ""

    local answer continue_anyway
    read -r -t 300 -p "Run a final encrypted backup now? [yes/no] (default: no): " answer || answer="no"
    if [[ "$answer" == "yes" ]]; then
        info "Running final full backup..."
        if bash "${PROJECT_DIR}/backup.sh" run full 2>&1; then
            success "Final backup completed. Review the output above for the backup location."
        else
            warn "Backup exited with errors. Review the output above."
            read -r -t 300 -p "Continue with uninstall despite backup failure? [yes/no] (default: no): " continue_anyway || continue_anyway="no"
            [[ "$continue_anyway" == "yes" ]] || { info "Aborted — nothing changed."; exit 0; }
        fi
    else
        warn "Skipping final backup."
    fi
    return 0
}

confirm_uninstall() {
    warn "This will PERMANENTLY DELETE VaultWarden-OCI data, secrets, containers, and configuration."
    if [[ "$TEST_RESET" == "true" ]]; then
        warn "Test-reset mode preserves the Git checkout but removes generated local install artifacts."
    else
        warn "The project checkout is also removed unless an external backup directory inside it must be preserved."
    fi
    warn "This action cannot be undone."
    echo ""

    if [[ "$FORCE" == "true" ]]; then
        warn "--force active — skipping interactive uninstall confirmation."
        return 0
    fi

    local confirm
    if ! read -r -t 300 -p "Type 'UNINSTALL' to confirm, or anything else to abort: " confirm; then
        printf '\n' >&2
        die "No confirmation received within 5 minutes. The uninstall was not performed."
    fi
    [[ "$confirm" == "UNINSTALL" ]] || { info "Aborted — nothing changed."; exit 0; }
    return 0
}

_finalize_successful_operation_guard() {
    # remove_runtime_artifacts already deleted the current operation state path.
    # Prevent operation_release from recreating /run/vaultwarden-oci on success,
    # then close the held FDs so flock is released by descriptor close.
    if [[ "$UNINSTALL_OPERATION_HELD" == "true" ]] && declare -f operation_release >/dev/null 2>&1; then
        OPERATION_OWNS_STATE=false
        OPERATION_STATE_FILE=""
        operation_release 0
        UNINSTALL_OPERATION_HELD=false
        unset VW_OPERATION_INHERITED_FD VW_OPERATION_PARENT_STATE VW_OPERATION_PARENT_TOKEN VW_OPERATION_PARENT_ID
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
    operation_set_phase "2" "Confirming uninstall" 2>/dev/null || true
    show_summary
    confirm_uninstall
    offer_final_backup
    _confirm_age_key_safety

    operation_set_phase "3" "Removing services and Docker stack" 2>/dev/null || true
    disable_systemd_units
    remove_docker_stack

    operation_set_phase "4" "Removing persistent and installed state" 2>/dev/null || true
    remove_state_and_mount
    remove_installed_files

    operation_set_phase "5" "Removing integrations and host mutations" 2>/dev/null || true
    remove_sops_and_packages
    remove_crowdsec
    remove_firewall_rules
    remove_swap_and_apt_sources
    remove_group_memberships
    remove_project_checkout

    operation_set_phase "6" "Final runtime cleanup and residual verification" 2>/dev/null || true
    remove_runtime_artifacts
    verify_uninstall_complete
    _finalize_successful_operation_guard

    echo ""
    echo "════════════════════════════════════════════════════════════"
    success "Uninstall complete."
    if [[ "$TEST_RESET" == "true" ]]; then
        info "Git checkout preserved for immediate clean reinstall: $PROJECT_DIR"
    fi
    info "Intentionally preserved shared host infrastructure:"
    info "  • Docker packages, /var/lib/docker, docker group, and operator Docker membership"
    info "  • SSH/UFW access rules not related to HTTP/HTTPS"
    info "  • Common admin tools not uniquely owned by this project: curl, wget, git, jq, sqlite3, ufw, gpg, rsync, python3, make, nano"
    info "  • /etc/ssh/sshd_config"
    info "The OCI block device itself remains attached; only managed mount wiring and verified project contents are removed."
    echo "════════════════════════════════════════════════════════════"
    echo ""
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
