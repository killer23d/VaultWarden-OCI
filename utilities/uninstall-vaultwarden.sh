#!/usr/bin/env bash
# utilities/uninstall-vaultwarden.sh — fully remove VaultWarden-OCI managed artifacts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_STATE_DIR="/var/lib/vaultwarden"
DEFAULT_DATA_MOUNT="/mnt/vw-data"
ENV_DIR="/etc/vaultwarden"
ENV_FILE="${ENV_DIR}/vaultwarden.env"
OPT_SCRIPTS_DIR="/opt/vaultwarden-scripts"
RUNTIME_DIR="/run/vaultwarden-oci"
UNIT_DIR="/etc/systemd/system"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-vaultwarden-oci}"

DRY_RUN=false
FORCE=false
ACK_RECOVERY_KIT=false
PROJECT_STATE_DIR=""
DATA_VOLUME_DEVICE=""
DATA_VOLUME_MOUNT=""
BACKUP_DIR=""
SOPS_AGE_KEY_FILE=""
REAL_USER="${SUDO_USER:-}"
declare -a ENV_FILES=()

TIMERS=(vaultwarden-maintenance.timer vaultwarden-db-backup.timer vaultwarden-full-backup.timer vaultwarden-health.timer vaultwarden-dns-update.timer vaultwarden-firewall-update.timer)
SERVICES=(vaultwarden-maintenance.service vaultwarden-db-backup.service vaultwarden-full-backup.service vaultwarden-health.service vaultwarden-dns-update.service vaultwarden-firewall-update.service vaultwarden-notify-failure.service vaultwarden-notify-failure@.service vaultwarden-iptables.service vaultwarden-startup.service)
CONTAINERS=(vaultwarden_app vaultwarden_caddy vaultwarden_postfix vaultwarden_init)
SECRETS=(admin_token admin_basic_auth_hash smtp_password push_installation_id push_installation_key caddy_cloudflare_dns_token)
# Current compose network names plus historical unsuffixed names.
NETWORKS=(vaultwarden_network vaultwarden_egress_network caddy_external_network postfix_relay_network vaultwarden_egress caddy_external postfix_relay)
LOCKS=(/run/lock/vaultwarden-setup.lock /run/lock/vaultwarden-backup.lock /run/lock/vaultwarden-operations.lock /run/lock/vaultwarden-dns-update.lock /run/lock/vaultwarden-firewall-update.lock /run/lock/vaultwarden-health.lock /run/lock/vaultwarden-restore.lock /run/lock/vaultwarden-startup.lock /run/lock/vaultwarden-email.lock /var/lock/vaultwarden-setup.lock)
HELPER_PACKAGES=(age haveged rclone python3-argon2 apache2-utils cron yq p7zip-full dnsutils unzip)
CROWDSEC_PACKAGES=(crowdsec-cloudflare-worker-bouncer crowdsec-firewall-bouncer-iptables crowdsec netfilter-persistent iptables-persistent ipset)

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
info() { log "INFO $*"; }
warn() { log "WARN $*" >&2; }
err() { log "ERROR $*" >&2; }
ok() { log "OK $*"; }

usage() {
    cat <<'USAGE'
VaultWarden-OCI Uninstall

USAGE:
    sudo bash ./utilities/uninstall-vaultwarden.sh run [OPTIONS]

OPTIONS:
    --dry-run                       Preview removals without changing the host
    --force                         Non-interactive destructive cleanup
    --i-have-saved-my-recovery-kit  Confirm Age/recovery material is saved elsewhere
    --version, -V                   Print the VaultWarden-OCI version and exit
    --help, -h                      Show this help
USAGE
}

print_version() {
    printf 'VaultWarden-OCI %s\n' "$(tr -d '[:space:]' < "${PROJECT_ROOT}/VERSION" 2>/dev/null || echo unknown)"
}

run() {
    if [[ "$DRY_RUN" == true ]]; then info "[DRY RUN] $*"; return 0; fi
    "$@"
}

read_env() {
    local key="$1" file="$2"
    [[ -r "$file" ]] || return 1
    awk -F= -v k="$key" '$0 !~ /^[[:space:]]*#/ && $1 == k {sub(/^[^=]*=/, ""); gsub(/^"|"$/, ""); print; exit}' "$file"
}

pick_env() {
    local key="$1" file val
    for file in "${ENV_FILES[@]}"; do
        val="$(read_env "$key" "$file" 2>/dev/null || true)"
        [[ -n "$val" ]] && { printf '%s\n' "$val"; return 0; }
    done
    return 1
}

add_env_file() {
    local file="$1" seen
    [[ -f "$file" ]] || return 0
    for seen in "${ENV_FILES[@]}"; do [[ "$seen" == "$file" ]] && return 0; done
    ENV_FILES+=("$file")
}

_absolutize_project_path() {
    local path="$1"
    [[ -n "$path" ]] || return 0
    if [[ "$path" == /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s\n' "${PROJECT_ROOT}/${path}"
    fi
}

resolve_context() {
    [[ -n "${REAL_USER:-}" && "$REAL_USER" != root ]] || REAL_USER="$(logname 2>/dev/null || true)"
    [[ -n "${REAL_USER:-}" ]] || REAL_USER="root"

    ENV_FILES=()
    add_env_file "${PROJECT_ROOT}/.env"
    add_env_file "$ENV_FILE"
    add_env_file "${PROJECT_ROOT}/config/install.env"
    add_env_file "${DEFAULT_STATE_DIR}/config/install.env"
    add_env_file "${DEFAULT_DATA_MOUNT}/config/install.env"

    local discovered_state
    discovered_state="$(pick_env PROJECT_STATE_DIR 2>/dev/null || true)"
    [[ -n "$discovered_state" ]] && add_env_file "${discovered_state}/config/install.env"

    PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-$(pick_env PROJECT_STATE_DIR 2>/dev/null || true)}"
    PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-$DEFAULT_STATE_DIR}"
    DATA_VOLUME_DEVICE="${DATA_VOLUME_DEVICE:-$(pick_env DATA_VOLUME_DEVICE 2>/dev/null || true)}"
    DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-$(pick_env DATA_VOLUME_MOUNT 2>/dev/null || true)}"
    DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-$DEFAULT_DATA_MOUNT}"
    BACKUP_DIR="${BACKUP_DIR:-$(pick_env BACKUP_DIR 2>/dev/null || true)}"
    BACKUP_DIR="${BACKUP_DIR:-${PROJECT_STATE_DIR}/backups}"
    SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$(pick_env SOPS_AGE_KEY_FILE 2>/dev/null || true)}"
    SOPS_AGE_KEY_FILE="$(_absolutize_project_path "$SOPS_AGE_KEY_FILE")"
    COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(pick_env COMPOSE_PROJECT_NAME 2>/dev/null || true)}"
    COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-vaultwarden-oci}"
}

safe_rm_rf() {
    local path="$1" real
    [[ -n "$path" && ( -e "$path" || -L "$path" ) ]] || return 0
    real="$(realpath -m -- "$path" 2>/dev/null || printf '%s' "$path")"
    case "$real" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/mnt|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var|/var/lib|/run/lock|/etc/systemd|/etc/systemd/system)
            warn "Refusing unsafe delete: $real"; return 1 ;;
    esac
    case "$real" in
        "$PROJECT_ROOT"|"$PROJECT_STATE_DIR"|"$DEFAULT_STATE_DIR"|"$DATA_VOLUME_MOUNT"|"$OPT_SCRIPTS_DIR"|"$ENV_DIR"|"$RUNTIME_DIR"|/etc/crowdsec|/var/lib/crowdsec|/var/log/crowdsec|/var/lib/docker|/var/lib/containerd|/etc/docker|*/VaultWarden-OCI|*/vaultwarden-oci|*/vaultwarden_backups|*/vaultwarden-backups|"$UNIT_DIR"/vaultwarden-*.service.d|"$UNIT_DIR"/vaultwarden-*.timer.d)
            ;;
        *) warn "Refusing unrecognised recursive delete target: $real"; return 1 ;;
    esac
    run rm -rf --one-file-system -- "$real"
    ok "Removed $real"
}

rm_file() { [[ -e "$1" || -L "$1" ]] && { run rm -f -- "$1"; ok "Removed $1"; } || true; }

confirm() {
    cat <<SUMMARY

VaultWarden-OCI uninstall target:
  project root : $PROJECT_ROOT
  state dir    : $PROJECT_STATE_DIR
  backup dir   : $BACKUP_DIR
  data device  : ${DATA_VOLUME_DEVICE:-<unset>}
  data mount   : $DATA_VOLUME_MOUNT
  compose name : $COMPOSE_PROJECT_NAME
SUMMARY
    if [[ "$DRY_RUN" == true ]]; then
        info "Dry-run only. Previewing removal steps without changing the host."
        return 0
    fi
    [[ $EUID -eq 0 ]] || { err "Run with sudo for live uninstall."; exit 1; }
    if [[ "$FORCE" == true ]]; then
        warn "--force active; skipping prompts."
        return 0
    fi
    local answer
    read -r -p "Type UNINSTALL to permanently delete VaultWarden-OCI from this host: " answer
    [[ "$answer" == UNINSTALL ]] || { info "Aborted."; exit 0; }
    if [[ "$ACK_RECOVERY_KIT" != true && ( -f /etc/vaultwarden/age-key.txt || -n "$SOPS_AGE_KEY_FILE" ) ]]; then
        read -r -p "Have you saved your recovery kit/Age key outside this host? (yes/no): " answer
        [[ "$answer" == yes ]] || { info "Aborted. Save your recovery material first."; exit 0; }
    fi
}

offer_backup() {
    [[ "$DRY_RUN" == true || "$FORCE" == true || ! -f "${PROJECT_ROOT}/backup.sh" ]] && return 0
    local answer
    read -r -p "Run one final encrypted full backup before deleting data? (yes/no): " answer
    [[ "$answer" == yes ]] || return 0
    bash "${PROJECT_ROOT}/backup.sh" run full || {
        warn "Final backup failed."
        read -r -p "Continue uninstall anyway? (yes/no): " answer
        [[ "$answer" == yes ]] || exit 1
    }
}

cleanup_systemd() {
    info "Removing VaultWarden-OCI systemd units..."
    command -v systemctl >/dev/null 2>&1 || return 0
    local unit
    for unit in "${TIMERS[@]}"; do run systemctl disable --now "$unit" 2>/dev/null || true; done
    for unit in "${SERVICES[@]}"; do [[ "$unit" == *'@.service' ]] || run systemctl disable --now "$unit" 2>/dev/null || true; done
    run systemctl reset-failed 'vaultwarden-notify-failure@*.service' 2>/dev/null || true
    for unit in "${TIMERS[@]}" "${SERVICES[@]}"; do rm_file "${UNIT_DIR}/${unit}"; safe_rm_rf "${UNIT_DIR}/${unit}.d" || true; done
    rm_file /etc/systemd/system/docker.service.d/10-vaultwarden-data-volume.conf
    rmdir /etc/systemd/system/docker.service.d 2>/dev/null || true
    run systemctl daemon-reload 2>/dev/null || true
}

cleanup_docker() {
    info "Removing Docker compose resources..."
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { warn "Docker unavailable; skipping Docker cleanup."; return 0; }
    [[ -f "${PROJECT_ROOT}/docker-compose.yml" ]] && (cd "$PROJECT_ROOT" && run docker compose --project-name "$COMPOSE_PROJECT_NAME" -f docker-compose.yml down --remove-orphans --volumes) || true
    local item ids=()
    mapfile -t ids < <(docker ps -aq --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" 2>/dev/null || true)
    ((${#ids[@]})) && run docker rm -f "${ids[@]}" 2>/dev/null || true
    for item in "${CONTAINERS[@]}"; do docker inspect "$item" >/dev/null 2>&1 && run docker rm -f "$item" 2>/dev/null || true; done
    for item in "${SECRETS[@]}"; do docker secret inspect "$item" >/dev/null 2>&1 && run docker secret rm "$item" 2>/dev/null || true; done
    mapfile -t ids < <(docker volume ls -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" 2>/dev/null || true)
    ((${#ids[@]})) && run docker volume rm "${ids[@]}" 2>/dev/null || true
    mapfile -t ids < <(docker network ls -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" 2>/dev/null || true)
    ((${#ids[@]})) && run docker network rm "${ids[@]}" 2>/dev/null || true
    for item in "${NETWORKS[@]}"; do docker network inspect "$item" >/dev/null 2>&1 && run docker network rm "$item" 2>/dev/null || true; done
}

cleanup_state_and_files() {
    info "Removing runtime, installed config, repository checkout, and state..."
    safe_rm_rf "$RUNTIME_DIR" || true
    local lock
    for lock in "${LOCKS[@]}"; do rm_file "$lock"; done
    safe_rm_rf "$OPT_SCRIPTS_DIR" || true
    safe_rm_rf "$ENV_DIR" || true
    rm_file /etc/vaultwarden/age-key.txt
    [[ -n "$SOPS_AGE_KEY_FILE" ]] && rm_file "$SOPS_AGE_KEY_FILE"
    safe_rm_rf "$PROJECT_ROOT" || true
    [[ "$PROJECT_STATE_DIR" != "$PROJECT_ROOT" ]] && safe_rm_rf "$PROJECT_STATE_DIR" || true
    [[ "$PROJECT_STATE_DIR" != "$DEFAULT_STATE_DIR" ]] && safe_rm_rf "$DEFAULT_STATE_DIR" || true
    if [[ -n "$DATA_VOLUME_DEVICE" || -f "${DATA_VOLUME_MOUNT}/.vw-data-volume" || -d "$DATA_VOLUME_MOUNT" ]]; then
        mountpoint -q "$DATA_VOLUME_MOUNT" 2>/dev/null && run umount "$DATA_VOLUME_MOUNT" 2>/dev/null || true
        if [[ -f /etc/fstab ]]; then
            local tmp
            tmp="$(mktemp /etc/fstab.vw-uninstall.XXXXXX)"
            awk -v mp="$DATA_VOLUME_MOUNT" '$2 != mp {print}' /etc/fstab > "$tmp" && run mv -f "$tmp" /etc/fstab || rm -f "$tmp"
        fi
        rmdir "$DATA_VOLUME_MOUNT" 2>/dev/null || true
    fi
}

cleanup_security_integrations() {
    info "Removing CrowdSec and legacy Fail2Ban artifacts..."
    if command -v cscli >/dev/null 2>&1; then
        run cscli bouncers delete cloudflare-worker-bouncer 2>/dev/null || true
        run cscli bouncers delete crowdsecurity/cloudflare-worker-bouncer 2>/dev/null || true
        run cscli bouncers delete firewall-bouncer 2>/dev/null || true
        run cscli bouncers delete crowdsecurity/firewall-bouncer 2>/dev/null || true
    fi
    command -v systemctl >/dev/null 2>&1 && for svc in crowdsec-cloudflare-worker-bouncer crowdsec-firewall-bouncer crowdsec; do run systemctl disable --now "$svc" 2>/dev/null || true; done
    rm_file /etc/systemd/system/crowdsec-cloudflare-worker-bouncer.service
    rm_file /usr/local/bin/crowdsec-cloudflare-worker-bouncer
    rm_file /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml
    rm_file /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
    command -v apt-get >/dev/null 2>&1 && run env DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge "${CROWDSEC_PACKAGES[@]}" 2>/dev/null || true
    rm_file /etc/apt/sources.list.d/crowdsec_crowdsec.list
    rm_file /etc/apt/sources.list.d/crowdsec_crowdsec.sources
    rm_file /etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg
    safe_rm_rf /etc/crowdsec || true
    safe_rm_rf /var/lib/crowdsec || true
    safe_rm_rf /var/log/crowdsec || true
    for f in /etc/fail2ban/jail.d/vaultwarden-oci.conf /etc/fail2ban/action.d/smtp.conf /etc/fail2ban/action.d/smtp_notify.py /etc/fail2ban/action.d/cloudflare-apiv4.conf /etc/fail2ban/action.d/cloudflare-apiv4-helpers.sh /etc/fail2ban/filter.d/vaultwarden-auth.conf /etc/fail2ban/filter.d/vaultwarden-admin.conf /etc/fail2ban/filter.d/vaultwarden-web-caddy.conf /etc/fail2ban/filter.d/vaultwarden-security.conf; do rm_file "$f"; done
}

cleanup_firewall_swap_packages() {
    info "Removing project firewall rules, swapfile, helper packages, and Docker if project-owned..."
    command -v ufw >/dev/null 2>&1 && { run ufw delete allow 80/tcp 2>/dev/null || true; run ufw delete allow 443/tcp 2>/dev/null || true; }
    if command -v iptables >/dev/null 2>&1; then
        for subnet in 172.20.0.0/16 172.21.0.0/16 172.22.0.0/16 172.23.0.0/16; do while iptables -D DOCKER-USER -s "$subnet" -j ACCEPT 2>/dev/null; do :; done; done
    fi
    swapon --show 2>/dev/null | grep -q '^/swapfile[[:space:]]' && run swapoff /swapfile 2>/dev/null || true
    rm_file /swapfile
    if [[ -f /etc/fstab ]]; then
        local tmp
        tmp="$(mktemp /etc/fstab.vw-swap.XXXXXX)"
        sed '/^\/swapfile[[:space:]]/d' /etc/fstab > "$tmp" && run mv -f "$tmp" /etc/fstab || rm -f "$tmp"
    fi
    rm_file /usr/local/bin/sops
    command -v apt-get >/dev/null 2>&1 && run env DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge "${HELPER_PACKAGES[@]}" 2>/dev/null || true
    if [[ -f /etc/apt/sources.list.d/docker.sources || -f /etc/apt/sources.list.d/docker.list ]]; then
        local unmanaged="" cname
        if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
            while IFS= read -r cname; do
                [[ -z "$cname" ]] && continue
                case "$cname" in vaultwarden_*|*vaultwarden-oci*) ;; *) unmanaged="${unmanaged}${cname} " ;; esac
            done < <(docker ps -a --format '{{.Names}}' 2>/dev/null || true)
        fi
        if [[ -n "$unmanaged" ]]; then
            warn "Leaving Docker installed because unrelated containers remain: $unmanaged"
        else
            command -v apt-get >/dev/null 2>&1 && run env DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
            rm_file /etc/apt/keyrings/docker.asc
            rm_file /etc/apt/keyrings/docker.gpg
            rm_file /etc/apt/sources.list.d/docker.sources
            rm_file /etc/apt/sources.list.d/docker.list
            safe_rm_rf /var/lib/docker || true
            safe_rm_rf /var/lib/containerd || true
            safe_rm_rf /etc/docker || true
        fi
    fi
    if [[ "$REAL_USER" != root ]] && id "$REAL_USER" >/dev/null 2>&1 && id -nG "$REAL_USER" 2>/dev/null | grep -qw docker; then run gpasswd -d "$REAL_USER" docker 2>/dev/null || true; fi
    getent group vaultwarden >/dev/null 2>&1 && run groupdel vaultwarden 2>/dev/null || true
}

main() {
    [[ $# -gt 0 ]] || { usage; exit 0; }
    case "$1" in run) shift ;; help|--help|-h) usage; exit 0 ;; --version|-V) print_version; exit 0 ;; *) err "Unknown subcommand: $1"; usage; exit 2 ;; esac
    while [[ $# -gt 0 ]]; do
        case "$1" in --dry-run) DRY_RUN=true ;; --force) FORCE=true ;; --i-have-saved-my-recovery-kit) ACK_RECOVERY_KIT=true ;; --version|-V) print_version; exit 0 ;; --help|-h) usage; exit 0 ;; *) err "Unknown option: $1"; exit 2 ;; esac
        shift
    done
    resolve_context
    confirm
    offer_backup
    cleanup_systemd
    cleanup_docker
    cleanup_state_and_files
    cleanup_security_integrations
    cleanup_firewall_swap_packages
    ok "Uninstall complete. Review cloud block-volume detachment separately if you used one."
}

main "$@"
