#!/usr/bin/env bash
# utilities/uninstall-vaultwarden.sh — Fully uninstall VaultWarden-OCI managed artifacts.
#
# Destructive by design. This script removes the Docker stack, systemd units,
# runtime secrets, installed configs, persistent state, CrowdSec integration,
# firewall rules, optional data-volume mount wiring, and project-installed
# helper packages where safe.

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

die() { log_error "$*"; exit 1; }
info()    { log_info "$@"; }
success() { log_success "$@"; }
warn()    { log_warn "$@"; }

_uninstall_err_trap() {
    local rc=$?
    log_error "${BASH_SOURCE[0]}: failed at line ${BASH_LINENO[0]} (exit ${rc})"
    exit "$rc"
}
trap _uninstall_err_trap ERR

I_HAVE_SAVED_RECOVERY_KIT=false
FORCE=false
DRY_RUN=false

show_help() {
    cat <<'EOH'
VaultWarden-OCI Uninstall

USAGE:
    sudo bash ./utilities/uninstall-vaultwarden.sh run [OPTIONS]

DESCRIPTION:
    Fully removes VaultWarden-OCI managed artifacts from this host:
      - Docker compose stack, managed containers, networks, volumes, and runtime secrets
      - systemd timers/services/drop-ins, /opt scripts, and /etc/vaultwarden
      - persistent VaultWarden state directory and optional data-volume fstab/mount wiring
      - CrowdSec services/packages/config/state, project firewall rules, swapfile
      - project-installed helper packages where safe

SUBCOMMANDS:
    run    Perform the idempotent uninstall
    help   Show this help

OPTIONS (used after 'run'):
    --i-have-saved-my-recovery-kit
        Confirm that all Age keys shown by this script have been saved outside
        this host. Required when any managed Age key exists, unless --force is used.

    --dry-run
        Show what would be removed without changing the system.

    --force
        Non-interactive destructive mode. Skips uninstall confirmation,
        backup prompt, and Age-key prompts. Intended only after recovery data
        has been verified outside this host.

    --version, -V
        Print the VaultWarden-OCI version and exit.

EXAMPLES:
    sudo bash ./utilities/uninstall-vaultwarden.sh run --dry-run
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

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0 run"

REAL_USER="${SUDO_USER:-${USER:-ubuntu}}"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6 || true)"
REAL_HOME="${REAL_HOME:-/home/$REAL_USER}"

PROJECT_DIR="${PROJECT_ROOT_FALLBACK}"
PROJECT_BASENAME="$(basename "$PROJECT_DIR")"

INSTALLED_ENV="/etc/vaultwarden/vaultwarden.env"
DEFAULT_STATE_DIR="${_VW_DEFAULT_STATE_DIR:-/var/lib/vaultwarden}"
DEFAULT_DATA_MOUNT="${_VW_DEFAULT_DATA_MOUNT:-/mnt/vw-data}"

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
    local repo_env="${PROJECT_DIR}/.env"
    [[ -f "$repo_env" ]] && printf '%s\n' "$repo_env"
    [[ -f "$INSTALLED_ENV" ]] && printf '%s\n' "$INSTALLED_ENV"

    local repo_state installed_state state
    repo_state="$(_read_env_value PROJECT_STATE_DIR "$repo_env")"
    installed_state="$(_read_env_value PROJECT_STATE_DIR "$INSTALLED_ENV")"
    for state in "$repo_state" "$installed_state" "$DEFAULT_STATE_DIR" "$DEFAULT_DATA_MOUNT"; do
        [[ -n "$state" && -f "$state/config/install.env" ]] && printf '%s\n' "$state/config/install.env"
    done
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

    while IFS= read -r env_file; do
        [[ -f "$env_file" ]] || continue
        if [[ -z "$PROJECT_STATE_DIR" ]]; then PROJECT_STATE_DIR="$(_read_env_value PROJECT_STATE_DIR "$env_file")"; fi
        if [[ -z "$DATA_VOLUME_MOUNT" ]]; then DATA_VOLUME_MOUNT="$(_read_env_value DATA_VOLUME_MOUNT "$env_file")"; fi
        if [[ -z "$DATA_VOLUME_DEVICE" ]]; then DATA_VOLUME_DEVICE="$(_read_env_value DATA_VOLUME_DEVICE "$env_file")"; fi
        if [[ -z "$SOPS_AGE_KEY_FILE_ENV" ]]; then SOPS_AGE_KEY_FILE_ENV="$(_read_env_value SOPS_AGE_KEY_FILE "$env_file")"; fi
        if [[ -z "$AGE_KEY_FILE_ENV" ]]; then AGE_KEY_FILE_ENV="$(_read_env_value AGE_KEY_FILE "$env_file")"; fi
        if [[ -z "$BACKUP_DIR" ]]; then BACKUP_DIR="$(_read_env_value BACKUP_DIR "$env_file")"; fi
    done < <(_env_candidates_for_bootstrap | _unique_lines)

    if [[ -z "$PROJECT_STATE_DIR" && -n "$DATA_VOLUME_MOUNT" ]]; then
        PROJECT_STATE_DIR="$DATA_VOLUME_MOUNT"
    fi
    PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-$DEFAULT_STATE_DIR}"
    DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-}"

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

    DOCKER_SENTINEL="${PROJECT_STATE_DIR}/.docker_installed_by_setup"
    DOCKER_SENTINEL_PRESENT=false
    if [[ -f "$DOCKER_SENTINEL" ]]; then
        DOCKER_SENTINEL_PRESENT=true
    fi
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
        read -r -p "Age public key: " typed
        [[ "$typed" == "$first_pub" ]] || die "Confirmation mismatch — uninstall aborted before destructive changes."
    else
        warn "Could not extract a public key automatically."
        read -r -p "Type DELETE-MY-KEYS to continue: " typed
        [[ "$typed" == "DELETE-MY-KEYS" ]] || die "Confirmation not given — uninstall aborted before destructive changes."
    fi
    success "Age-key preservation confirmed."
}

_run_if_exists() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1
}

disable_systemd_units() {
    info "Step 1: Disabling and removing VaultWarden systemd units..."

    local timers=(
        vaultwarden-maintenance.timer
        vaultwarden-db-backup.timer
        vaultwarden-full-backup.timer
        vaultwarden-health.timer
        vaultwarden-dns-update.timer
        vaultwarden-firewall-update.timer
    )
    local services=(
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
    local units=("${timers[@]}" "${services[@]}")
    local unit dest dropin

    if ! _run_if_exists systemctl; then
        warn "systemctl not found — skipping systemd cleanup."
        return 0
    fi

    for unit in "${timers[@]}" vaultwarden-startup.service; do
        if systemctl is-enabled "$unit" >/dev/null 2>&1 || systemctl is-active "$unit" >/dev/null 2>&1; then
            systemctl disable --now "$unit" 2>/dev/null \
                && success "Disabled: $unit" \
                || warn "Could not disable $unit (may already be inactive)."
        fi
    done

    for unit in "${services[@]}"; do
        [[ "$unit" == *"@"* ]] && continue
        systemctl stop "$unit" 2>/dev/null || true
    done

    for unit in "${units[@]}"; do
        dest="/etc/systemd/system/${unit}"
        if [[ -f "$dest" ]]; then
            rm -f "$dest" && success "Removed unit file: $dest"
        fi
        dropin="/etc/systemd/system/${unit}.d"
        if [[ -d "$dropin" ]]; then
            rm -rf "$dropin" && success "Removed unit drop-in dir: $dropin"
        fi
    done

    systemctl reset-failed 'vaultwarden-notify-failure@*.service' 2>/dev/null || true
    for unit in "${services[@]}"; do
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
            || warn "docker compose down had errors (containers may already be gone)."
    fi

    local patterns=(vaultwarden vaultwarden_app vaultwarden_caddy vaultwarden_postfix vaultwarden_init caddy postfix)
    local pattern cid
    for pattern in "${patterns[@]}"; do
        while IFS= read -r cid; do
            [[ -n "$cid" ]] || continue
            docker stop "$cid" 2>/dev/null || true
            docker rm -f "$cid" 2>/dev/null || true
            success "Removed container id: $cid"
        done < <(docker ps -aq --filter "name=${pattern}" 2>/dev/null || true)
    done

    local secret
    for secret in admin_token admin_basic_auth_hash smtp_password push_installation_id push_installation_key caddy_cloudflare_dns_token; do
        docker secret rm "$secret" >/dev/null 2>&1 || true
    done

    local project_name
    project_name="$(printf '%s' "$PROJECT_BASENAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"

    local vol
    while IFS= read -r vol; do
        [[ -n "$vol" ]] || continue
        docker volume rm "$vol" 2>/dev/null \
            && success "Removed Docker volume: $vol" \
            || warn "Could not remove Docker volume: $vol"
    done < <(docker volume ls -q 2>/dev/null | grep -E "^(${project_name}_|vaultwarden)" || true)

    local net
    local known_networks=(vaultwarden_network vaultwarden_egress caddy_external postfix_relay)
    for net in "${known_networks[@]}"; do
        docker network rm "$net" 2>/dev/null && success "Removed Docker network: $net" || true
    done
    while IFS= read -r net; do
        [[ -n "$net" ]] || continue
        docker network rm "$net" 2>/dev/null && success "Removed Docker network: $net" || true
    done < <(docker network ls --format '{{.Name}}' 2>/dev/null | grep -E "vaultwarden|${project_name}" || true)
    return 0
}

remove_runtime_artifacts() {
    info "Step 3: Removing runtime secrets, locks, and vaultwarden group..."

    _safe_rm_rf /run/vaultwarden-oci || true

    rm -f /var/lock/vaultwarden-setup.lock /run/lock/vaultwarden-setup.lock 2>/dev/null || true
    local lock
    for lock in \
        /run/lock/vaultwarden-backup.lock \
        /run/lock/vaultwarden-operations.lock \
        /run/lock/vaultwarden-dns-update.lock \
        /run/lock/vaultwarden-firewall-update.lock \
        /run/lock/vaultwarden-health.lock; do
        rm -f "$lock" 2>/dev/null || true
    done
    success "Removed VaultWarden runtime lock files."

    if getent group vaultwarden >/dev/null 2>&1; then
        groupdel vaultwarden 2>/dev/null \
            && success "Removed system group: vaultwarden" \
            || warn "Could not remove system group 'vaultwarden'. Remove manually if unused: sudo groupdel vaultwarden"
    fi
    return 0
}

remove_installed_files() {
    info "Step 4: Removing installed files and repository checkout..."

    _safe_rm_rf /opt/vaultwarden-scripts || true
    _safe_rm_rf /etc/vaultwarden || true

    cd /

    if [[ "$PROJECT_DIR" == */VaultWarden-OCI || "$PROJECT_BASENAME" == "VaultWarden-OCI" ]]; then
        _safe_rm_rf "$PROJECT_DIR" || true
    else
        warn "Project directory does not look like a VaultWarden-OCI checkout; leaving in place: $PROJECT_DIR"
    fi
    return 0
}

_remove_fstab_mount() {
    local mountpoint="$1"
    [[ -n "$mountpoint" && -f /etc/fstab ]] || return 0

    if ! awk -v mp="$mountpoint" '($2 == mp) { found=1 } END { exit(found ? 0 : 1) }' /etc/fstab; then
        info "No fstab entry found for mount point: $mountpoint"
        return 0
    fi

    local tmp
    tmp="$(mktemp /etc/fstab.vw-uninstall.XXXXXXXXXX)" || return 1
    if awk -v mp="$mountpoint" '$2 != mp { print }' /etc/fstab > "$tmp" && mv -f "$tmp" /etc/fstab; then
        success "Removed fstab entry for data volume: $mountpoint"
    else
        rm -f "$tmp" 2>/dev/null || true
        warn "Could not remove fstab entry for $mountpoint. Remove it manually."
    fi
    return 0
}

remove_state_and_mount() {
    info "Step 5: Removing persistent state and optional data-volume mount..."

    local sentinel="${PROJECT_STATE_DIR}/.vw-data-volume"
    if [[ -f "$sentinel" ]] && command -v chattr >/dev/null 2>&1; then
        chattr -i "$sentinel" 2>/dev/null || true
    fi

    if [[ -d "$PROJECT_STATE_DIR" ]]; then
        _safe_rm_rf "$PROJECT_STATE_DIR" && success "Removed state directory: $PROJECT_STATE_DIR"
    else
        info "State directory not found: $PROJECT_STATE_DIR"
    fi

    if [[ "$PROJECT_STATE_DIR" != "$DEFAULT_STATE_DIR" && -d "$DEFAULT_STATE_DIR" ]]; then
        _safe_rm_rf "$DEFAULT_STATE_DIR" && success "Removed boot-volume residual state: $DEFAULT_STATE_DIR"
    fi

    local unmount_target="${DATA_VOLUME_MOUNT:-}"
    if [[ -n "$unmount_target" && "$unmount_target" != "$DEFAULT_STATE_DIR" ]]; then
        if mountpoint -q "$unmount_target" 2>/dev/null; then
            info "Unmounting data volume at $unmount_target..."
            if umount "$unmount_target" 2>/dev/null; then
                success "Unmounted $unmount_target"
            elif umount -l "$unmount_target" 2>/dev/null; then
                success "Lazy-unmounted $unmount_target"
            else
                warn "Could not unmount $unmount_target. Run manually after checking open files."
            fi
        fi
        _remove_fstab_mount "$unmount_target"
        if [[ -d "$unmount_target" ]]; then
            rmdir "$unmount_target" 2>/dev/null \
                && success "Removed empty mountpoint directory: $unmount_target" \
                || warn "Mountpoint still exists/non-empty: $unmount_target"
        fi
    fi
    return 0
}

remove_sops_and_packages() {
    info "Step 6: Removing project-installed helper packages..."

    if [[ -f /usr/local/bin/sops ]]; then
        rm -f /usr/local/bin/sops && success "Removed /usr/local/bin/sops"
    fi

    if _run_if_exists systemctl && systemctl is-enabled haveged >/dev/null 2>&1; then
        systemctl disable --now haveged 2>/dev/null || true
    fi

    local pkgs=(
        age
        haveged
        rclone
        python3-argon2
        apache2-utils
        cron
        yq
        p7zip-full
        dnsutils
        unzip
    )
    local pkg
    for pkg in "${pkgs[@]}"; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge "$pkg" 2>/dev/null \
                && success "Removed package: $pkg" \
                || warn "Could not remove package: $pkg"
        fi
    done
    apt-get autoremove -y 2>/dev/null || true
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

    local pkgs=(
        crowdsec-cloudflare-worker-bouncer
        crowdsec-firewall-bouncer-iptables
        crowdsec
        netfilter-persistent
        iptables-persistent
        ipset
    )
    local pkg
    for pkg in "${pkgs[@]}"; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge "$pkg" 2>/dev/null \
                && success "Removed package: $pkg" \
                || warn "Could not remove package: $pkg"
        fi
    done

    rm -f /etc/apt/sources.list.d/crowdsec_crowdsec.list \
          /etc/apt/sources.list.d/crowdsec_crowdsec_crowdsec.list \
          /etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg \
          /etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.asc 2>/dev/null || true

    _safe_rm_rf /etc/crowdsec || true
    _safe_rm_rf /var/lib/crowdsec || true
    _safe_rm_rf /var/log/crowdsec || true

    apt-get update -qq 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    return 0
}

remove_firewall_rules() {
    info "Step 8: Removing UFW and iptables rules managed by VaultWarden-OCI..."

    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow 80/tcp 2>/dev/null || true
        ufw delete allow 443/tcp 2>/dev/null || true

        local rule_num
        for _ in {1..30}; do
            rule_num="$(ufw status numbered 2>/dev/null \
                | awk '/(^|[[:space:]])(80|443)\/tcp([[:space:]]|$)/ { gsub(/\[|\]/, "", $1); print $1; exit }')"
            [[ -n "$rule_num" ]] || break
            yes | ufw delete "$rule_num" 2>/dev/null || break
        done
        success "Removed UFW HTTP/HTTPS rules; SSH rules preserved."
    fi

    if command -v iptables >/dev/null 2>&1; then
        local subnets=(172.21.0.0/16 172.22.0.0/16 172.23.0.0/16)
        local subnet
        for subnet in "${subnets[@]}"; do
            while iptables -t nat -D POSTROUTING -s "$subnet" ! -o docker0 -j MASQUERADE 2>/dev/null; do
                success "Removed NAT MASQUERADE for $subnet"
            done
            if iptables -t filter -S DOCKER-USER >/dev/null 2>&1; then
                while iptables -t filter -D DOCKER-USER -s "$subnet" -j ACCEPT 2>/dev/null; do
                    success "Removed DOCKER-USER ACCEPT for $subnet"
                done
            fi
        done
    fi
    return 0
}

remove_swap_and_apt_sources() {
    info "Step 9: Removing swapfile and project-added apt source files..."

    if swapon --show 2>/dev/null | grep -q '^/swapfile[[:space:]]'; then
        swapoff /swapfile 2>/dev/null || warn "swapoff /swapfile failed"
    fi
    rm -f /swapfile 2>/dev/null && success "Removed /swapfile" || true

    if [[ -f /etc/fstab ]] && grep -q '^/swapfile[[:space:]]' /etc/fstab 2>/dev/null; then
        local tmp
        tmp="$(mktemp /etc/fstab.vw-swap.XXXXXXXXXX)" || return 1
        if sed '/^\/swapfile[[:space:]]/d' /etc/fstab > "$tmp" && mv -f "$tmp" /etc/fstab; then
            success "Removed /swapfile fstab entry"
        else
            rm -f "$tmp" 2>/dev/null || true
            warn "Could not remove /swapfile fstab entry"
        fi
    fi

    if grep -q '^vm\.swappiness' /etc/sysctl.conf 2>/dev/null; then
        sed -i '/^vm\.swappiness/d' /etc/sysctl.conf || true
        sysctl -q vm.swappiness=60 2>/dev/null || true
    fi

    rm -f /etc/apt/sources.list.d/ubuntu-universe.list 2>/dev/null || true
    apt-get update -qq 2>/dev/null || true
    return 0
}

_docker_has_unrelated_containers() {
    command -v docker >/dev/null 2>&1 || return 1
    local all unmanaged name cid
    all="$(docker ps -aq 2>/dev/null || true)"
    [[ -n "$all" ]] || return 1
    unmanaged="$(docker ps -aq 2>/dev/null \
        | while IFS= read -r cid; do
              name="$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||' || true)"
              case "$name" in
                  *vaultwarden*|*caddy*|*postfix*) ;;
                  *) printf '%s\n' "$name" ;;
              esac
          done)"
    [[ -n "$unmanaged" ]]
}

remove_docker_packages_if_safe() {
    info "Step 10: Removing Docker CE packages and runtime data if project-owned..."

    local docker_repo_present=false
    [[ -f /etc/apt/sources.list.d/docker.sources || -f /etc/apt/sources.list.d/docker.list ]] && docker_repo_present=true

    if [[ "$DOCKER_SENTINEL_PRESENT" != "true" && "$docker_repo_present" != "true" ]]; then
        warn "No Docker install marker/repo found. Leaving Docker packages in place."
        return 0
    fi

    if _docker_has_unrelated_containers; then
        warn "Unrelated Docker containers were detected. Leaving Docker packages and runtime data in place."
        warn "Remove Docker manually after verifying no other services depend on it."
        return 0
    fi

    if dpkg -s docker-ce >/dev/null 2>&1 || command -v docker >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin \
            docker-ce-rootless-extras 2>/dev/null \
            && success "Docker packages removed." \
            || warn "Docker package removal had non-fatal errors."
    fi

    rm -f /etc/apt/keyrings/docker.asc /etc/apt/keyrings/docker.gpg 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/docker.sources /etc/apt/sources.list.d/docker.list 2>/dev/null || true
    _safe_rm_rf /var/lib/docker || true
    _safe_rm_rf /var/lib/containerd || true
    _safe_rm_rf /etc/docker || true

    apt-get update -qq 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    return 0
}

remove_group_memberships() {
    info "Step 11: Removing group memberships created for VaultWarden-OCI..."

    if id "$REAL_USER" >/dev/null 2>&1 && id "$REAL_USER" 2>/dev/null | grep -q '\bdocker\b'; then
        gpasswd -d "$REAL_USER" docker 2>/dev/null \
            && success "Removed ${REAL_USER} from docker group." \
            || warn "Could not remove ${REAL_USER} from docker group."
    fi

    if getent group docker >/dev/null 2>&1; then
        local members
        members="$(getent group docker | cut -d: -f4)"
        if [[ -z "$members" ]]; then
            groupdel docker 2>/dev/null && success "Removed empty docker group." || true
        fi
    fi
    return 0
}

show_summary() {
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "   VaultWarden-OCI Full Uninstaller"
    echo "   Project dir       : ${PROJECT_DIR}"
    echo "   Project state dir : ${PROJECT_STATE_DIR}"
    echo "   Data mount        : ${DATA_VOLUME_MOUNT:-<unset>}"
    echo "   Running as        : $(whoami)  (real user: ${REAL_USER})"
    [[ "$DRY_RUN" == "true" ]] && echo "   Mode              : DRY RUN — no changes will be made"
    [[ "$FORCE" == "true" ]] && echo "   Mode              : FORCE — non-interactive destructive cleanup"
    echo "════════════════════════════════════════════════════════════"
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        warn "DRY RUN MODE — would remove:"
        _dry_run_line "systemd units/timers/drop-ins: vaultwarden-*.service, vaultwarden-*.timer, vaultwarden-startup.service"
        _dry_run_line "Docker compose stack, managed containers, networks, volumes, and compatible Docker secrets"
        _dry_run_line "runtime secrets and locks: /run/vaultwarden-oci, /run/lock/vaultwarden-*.lock"
        _dry_run_line "installed config and key dir: /etc/vaultwarden"
        _dry_run_line "installed scripts: /opt/vaultwarden-scripts"
        _dry_run_line "project checkout: ${PROJECT_DIR}"
        _dry_run_line "state directory: ${PROJECT_STATE_DIR}"
        _dry_run_line "boot-volume residual state: ${DEFAULT_STATE_DIR} when different from PROJECT_STATE_DIR"
        _dry_run_line "data-volume mount/fstab/mountpoint for: ${DATA_VOLUME_MOUNT:-<unset>}"
        _dry_run_line "Age key paths:"
        local key
        for key in "${MANAGED_AGE_KEY_PATHS[@]}"; do _dry_run_line "  ${key}"; done
        _dry_run_line "CrowdSec services/packages/config/state including Cloudflare and firewall bouncers"
        _dry_run_line "UFW 80/443 rules and VaultWarden iptables bridge rules"
        _dry_run_line "swapfile /swapfile and vm.swappiness entry"
        _dry_run_line "helper packages: age haveged rclone python3-argon2 apache2-utils cron yq p7zip-full dnsutils unzip"
        _dry_run_line "Docker packages/runtime data when project-owned and no unrelated containers exist"
        _dry_run_line "docker/vaultwarden group memberships where applicable"
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
    read -r -p "Run a final encrypted backup now? (yes/no): " answer
    if [[ "$answer" == "yes" ]]; then
        info "Running final full backup..."
        if bash "${PROJECT_DIR}/backup.sh" run full 2>&1; then
            success "Final backup completed. Review the output above for the backup location."
        else
            warn "Backup exited with errors. Review the output above."
            read -r -p "Continue with uninstall despite backup failure? (yes/no): " continue_anyway
            [[ "$continue_anyway" == "yes" ]] || { info "Aborted — nothing changed."; exit 0; }
        fi
    else
        warn "Skipping final backup."
    fi
    return 0
}

confirm_uninstall() {
    warn "This will PERMANENTLY DELETE VaultWarden-OCI data, secrets, containers, and configuration."
    warn "This action cannot be undone."
    echo ""

    if [[ "$FORCE" == "true" ]]; then
        warn "--force active — skipping interactive uninstall confirmation."
        return 0
    fi

    local confirm
    read -r -p "Type 'UNINSTALL' to confirm, or anything else to abort: " confirm
    [[ "$confirm" == "UNINSTALL" ]] || { info "Aborted — nothing changed."; exit 0; }
    return 0
}

main() {
    resolve_paths
    show_summary
    confirm_uninstall
    offer_final_backup
    _confirm_age_key_safety

    disable_systemd_units
    remove_docker_stack
    remove_runtime_artifacts
    remove_installed_files
    remove_state_and_mount
    remove_sops_and_packages
    remove_crowdsec
    remove_firewall_rules
    remove_swap_and_apt_sources
    remove_docker_packages_if_safe
    remove_group_memberships

    echo ""
    echo "════════════════════════════════════════════════════════════"
    success "Uninstall complete."
    info "Intentionally preserved:"
    info "  • SSH/UFW access rules not related to HTTP/HTTPS"
    info "  • Common admin tools not uniquely owned by this project: curl, wget, git, jq, sqlite3, ufw, gpg, rsync, python3, make, nano"
    info "  • /etc/ssh/sshd_config"
    info "Review any remaining OCI block volume attachment separately if you used a dedicated data volume."
    echo "════════════════════════════════════════════════════════════"
    echo ""
}

main "$@"
