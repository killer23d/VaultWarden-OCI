#!/usr/bin/env bash
# utilities/setup-firewall.sh — Configures VaultWarden-OCI UFW and iptables rules.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/log.sh
source "${PROJECT_ROOT}/lib/log.sh"
# shellcheck source=../lib/config.sh
source "${PROJECT_ROOT}/lib/config.sh"
# shellcheck source=../lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"

_show_help() {
    cat <<'EOF'
utilities/setup-firewall.sh — VaultWarden-OCI firewall configuration

Configures UFW (with Cloudflare CIDR restrictions) and iptables NAT/DOCKER-USER
rules for the VaultWarden compose project. Safe to re-run (idempotent).

USAGE:
  sudo utilities/setup-firewall.sh [--phase ufw|iptables|all] [--auto] [--yes] [--dry-run]

FLAGS:
  --phase ufw|iptables|all   Phase to run (default: all)
  --auto                     Non-interactive mode (implies --yes)
  --yes                      Auto-confirm the netfilter-persistent install prompt
  --dry-run                  Preview actions without executing
  --force                    Skip confirmations
  --force-iptables           Continue iptables setup even when an active nftables
                             ruleset is detected. Use only when you have verified
                             that nftables will not override these iptables rules.
  --help, -h                 Show this help

NOTES:
  UFW rules must be applied AFTER Docker installation. Docker rewrites iptables
  chains during installation; rules set before Docker is installed are silently
  bypassed by Docker's DOCKER-USER chain.

  The systemd unit vaultwarden-iptables.service calls this script with
  --phase iptables to re-apply NAT rules after a Docker upgrade resets chains.
EOF
}

_require_cli_value() {
    local opt="$1" value="${2-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        log_error "Option '$opt' requires a value."
        _show_help
        exit 1
    fi
}

# Store iptables rollback state populated by _phase_iptables().
_ipt_backup_v4=""
_ipt_backup_v6=""

_ipt_cleanup() {
    local _rc=$?
    if [[ -n "$_ipt_backup_v4" && -f "$_ipt_backup_v4" ]]; then
        log_rollback "Restoring iptables rules from: $_ipt_backup_v4"
        iptables-restore < "$_ipt_backup_v4" 2>/dev/null || true
        rm -f "$_ipt_backup_v4"
    fi
    if [[ -n "$_ipt_backup_v6" && -f "$_ipt_backup_v6" ]]; then
        log_rollback "Restoring ip6tables rules from: $_ipt_backup_v6"
        ip6tables-restore < "$_ipt_backup_v6" 2>/dev/null || true
        rm -f "$_ipt_backup_v6"
    fi
    return $_rc
}

PHASE="all"
AUTO_MODE=false
DRY_RUN=false
FORCE=false
FORCE_IPTABLES=false
YES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase)           _require_cli_value "$1" "${2-}"; PHASE="$2"; shift 2 ;;
        --auto)            AUTO_MODE=true; YES=true; shift ;;
        --yes)             YES=true; shift ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --force)           FORCE=true; shift ;;
        --force-iptables)  FORCE_IPTABLES=true; shift ;;
        --help|-h)         _show_help; exit 0 ;;
        *)                 log_error "Unknown option: $1"; _show_help; exit 1 ;;
    esac
done

case "$PHASE" in
    ufw|iptables|all) ;;
    *) log_error "--phase must be ufw|iptables|all (got: '$PHASE')"; exit 1 ;;
esac

_phase_ufw() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry_run "Would configure UFW firewall with Cloudflare CIDR restrictions"
        log_dry_run "Would detect SSH port via sshd -T or /etc/ssh/sshd_config"
        log_dry_run "Would fetch Cloudflare IPv4/IPv6 CIDR lists"
        log_dry_run "Would allow SSH port, restrict 80/443 to Cloudflare CIDRs"
        log_dry_run "Would enable UFW if not already active"
        return 0
    fi

    local ssh_port
    ssh_port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    if [[ -z "$ssh_port" ]]; then
        ssh_port=$(awk '/^Port[[:space:]]/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)
    fi
    ssh_port=${ssh_port:-22}
    log_info "Detected SSH port: ${ssh_port}"

    local cf_ipv4_url="https://www.cloudflare.com/ips-v4"
    local cf_ipv6_url="https://www.cloudflare.com/ips-v6"
    local cf_cidr_cache="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/cf-cidrs.cache"
    local -a cf_cidrs=()
    local cf_fetch_failed=false

    log_info "Fetching Cloudflare CIDR lists for firewall restriction..."
    local ipv4_list ipv6_list
    ipv4_list=$(curl -fsSL --max-time 15 "$cf_ipv4_url" 2>/dev/null) || cf_fetch_failed=true
    ipv6_list=$(curl -fsSL --max-time 15 "$cf_ipv6_url" 2>/dev/null) || cf_fetch_failed=true

    if [[ "$cf_fetch_failed" == "false" ]] && \
       [[ -n "$ipv4_list" ]] && [[ -n "$ipv6_list" ]]; then
        local cidr
        while IFS= read -r cidr; do
            [[ -z "$cidr" || "$cidr" == \#* ]] && continue
            cf_cidrs+=("$cidr")
        done <<< "$ipv4_list"
        while IFS= read -r cidr; do
            [[ -z "$cidr" || "$cidr" == \#* ]] && continue
            cf_cidrs+=("$cidr")
        done <<< "$ipv6_list"
        log_info "Fetched ${#cf_cidrs[@]} Cloudflare CIDRs"
        # Persist a fresh cache so future fetch failures fall back to known-good data.
        mkdir -p "$(dirname "$cf_cidr_cache")" 2>/dev/null || true
        printf '%s\n' "${cf_cidrs[@]}" > "$cf_cidr_cache" 2>/dev/null || true
    else
        # Fetch failed — try the last-known-good cache before failing open.
        if [[ -s "$cf_cidr_cache" ]]; then
            log_warn "Could not fetch Cloudflare CIDR lists — using cached copy: $cf_cidr_cache"
            while IFS= read -r cidr; do
                [[ -z "$cidr" || "$cidr" == \#* ]] && continue
                cf_cidrs+=("$cidr")
            done < "$cf_cidr_cache"
            log_warn "SECURITY: Rules are based on cached CIDRs, which may be stale."
            log_warn "  Re-run this script when network access is restored to refresh the cache."
        else
            log_error "Could not fetch Cloudflare CIDR lists and no cache is available."
            log_error "SECURITY: Refusing to configure ports 80/443 without valid CIDR data."
            log_error "  Check internet connectivity, then re-run: sudo utilities/setup-firewall.sh"
            log_error "  To allow all IPs explicitly: ufw allow 80/tcp && ufw allow 443/tcp"
            return 1
        fi
    fi

    local ufw_active=false
    ufw status | grep -q "Status: active" && ufw_active=true

    # Skip full reconfiguration when UFW is already active with the required rules,
    # unless --force overrides the idempotency check.
    if [[ "$FORCE" != "true" ]] && \
       [[ "$ufw_active" == "true" ]] && \
       ufw status | grep -q "80/tcp" && \
       ufw status | grep -q "443/tcp" && \
       ufw status | grep -q "${ssh_port}/tcp"; then
        log_success "Firewall already configured and active"
        return 0
    fi

    ufw allow "${ssh_port}/tcp"

    # cf_cidrs is guaranteed non-empty here (the fetch+cache logic above
    # returns 1 if no CIDRs are available, preventing us from reaching this
    # point with an empty list).
    local cidr
    for cidr in "${cf_cidrs[@]}"; do
        ufw allow from "$cidr" to any port 80 proto tcp  2>/dev/null || true
        ufw allow from "$cidr" to any port 443 proto tcp 2>/dev/null || true
    done
    log_success "Firewall: ports 80/443 restricted to ${#cf_cidrs[@]} Cloudflare CIDRs"

    [[ "$ufw_active" == "false" ]] && ufw --force enable
    log_success "UFW firewall configured"
}

_phase_iptables() {
    if ! command -v docker >/dev/null 2>&1; then
        log_error "docker command not found"
        exit 1
    fi
    if ! command -v iptables >/dev/null 2>&1; then
        log_error "iptables command not found"
        exit 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        log_error "python3 command not found — required for subnet discovery from compose config"
        exit 1
    fi

    # Refuse to run alongside an active nftables ruleset unless the operator
    # has explicitly acknowledged the risk with --force-iptables.
    #
    # On systems using iptables-nft, nftables rules take precedence and can
    # silently override what iptables writes, leaving the host in an undefined
    # firewall state. Running both frameworks simultaneously is unsupported and
    # may cause container traffic to be blocked or the host to be inaccessible.
    if command -v nft >/dev/null 2>&1; then
        if nft list ruleset 2>/dev/null | grep -q .; then
            if [[ "$FORCE_IPTABLES" != "true" ]]; then
                log_error "nftables ruleset is active on this host."
                log_error "Running iptables alongside nftables may cause conflicting firewall"
                log_error "policies. nftables rules can silently override these iptables rules,"
                log_error "leaving container traffic blocked or SSH inaccessible."
                log_error "Options:"
                log_error "  1. Disable nftables first:  sudo systemctl stop nftables"
                log_error "  2. Use nftables for all rules (see docs/OPERATIONS.md)."
                log_error "  3. Override this check (RISK):  --force-iptables"
                exit 1
            fi
            log_warn "nftables ruleset is active on this host (--force-iptables acknowledged)."
            log_warn "Verify that nftables is not shadowing these iptables rules."
        fi
    fi

    # Verify SSH is reachable before touching iptables rules.
    # Adding MASQUERADE or FORWARD rules while accidentally blocking SSH could
    # lock the operator out of the host.
    #
    # Checks are attempted in order:
    #   1. An explicit ACCEPT rule for the SSH port.
    #   2. A blanket ACCEPT for all INPUT traffic.
    #   3. An INPUT chain default policy of ACCEPT.
    #   4. A listening SSH daemon with no INPUT DROP or REJECT rules.
    local _ssh_port="${SSH_PORT:-22}"
    local _ssh_ok=false
    if iptables -L INPUT -n 2>/dev/null | grep -qE "ACCEPT.*(tcp dpt:${_ssh_port}|state.*ESTABLISHED|multiport.*${_ssh_port})"; then
        _ssh_ok=true
    elif iptables -L INPUT -n 2>/dev/null | grep -qE "ACCEPT[[:space:]]+all[[:space:]]+--[[:space:]]+0\.0\.0\.0/0[[:space:]]+0\.0\.0\.0/0"; then
        _ssh_ok=true
    elif iptables -L INPUT 2>/dev/null | head -1 | grep -q "policy ACCEPT"; then
        _ssh_ok=true
    elif ss -tlnp 2>/dev/null | grep -q ":${_ssh_port}" && \
         ! iptables -L INPUT -n 2>/dev/null | grep -qE "^(DROP|REJECT)"; then
        _ssh_ok=true
    fi
    if [[ "$_ssh_ok" != "true" ]]; then
        log_warn "Could not confirm an SSH ACCEPT rule in the INPUT chain."
        log_warn "Proceeding, but verify SSH port ${_ssh_port} remains accessible after this script."
    fi

    # Save the current iptables rules before any modifications.
    # On ERR, INT, or TERM, automatically restore the saved rules so the host
    # is not left with a partial or broken iptables configuration.
    if [[ "$DRY_RUN" != "true" ]]; then
        _ipt_backup_v4="$(mktemp -p "${PROJECT_ROOT}" .iptables-backup.XXXXXX)"
        iptables-save > "$_ipt_backup_v4" 2>/dev/null || {
            log_warn "Could not save current iptables state — rollback on failure will not be available."
            rm -f "$_ipt_backup_v4"; _ipt_backup_v4=""
        }
        if command -v ip6tables-save >/dev/null 2>&1; then
            _ipt_backup_v6="$(mktemp -p "${PROJECT_ROOT}" .ip6tables-backup.XXXXXX)"
            ip6tables-save > "$_ipt_backup_v6" 2>/dev/null || {
                rm -f "$_ipt_backup_v6"; _ipt_backup_v6=""
            }
        fi
        trap '_ipt_cleanup' ERR INT TERM
        # On success, clean up backup files without performing a rollback.
        trap 'rm -f "${_ipt_backup_v4:-}" "${_ipt_backup_v6:-}"' EXIT
    fi

    local compose_file="${COMPOSE_FILE:-docker-compose.yml}"
    if [[ ! -f "${PROJECT_ROOT}/${compose_file}" ]]; then
        compose_file="docker-compose.yml.example"
    fi

    # Discover bridge network names from the Docker Compose JSON config.
    local -a NETWORK_NAMES=()
    set +e
    mapfile -t NETWORK_NAMES < <(
        docker compose -f "${PROJECT_ROOT}/${compose_file}" config --services >/dev/null 2>&1 &&
        docker compose -f "${PROJECT_ROOT}/${compose_file}" config --format json 2>/dev/null |
        python3 -c '
import json, sys
c = json.load(sys.stdin)
nets = c.get("networks", {})
for name, cfg in nets.items():
    if cfg.get("driver", "bridge") != "bridge":
        continue
    if cfg.get("internal", False) is True:
        continue
    if cfg.get("external", False) is True:
        continue
    print(name)
' 2>/dev/null
    )
    set -e

    # Fall back when JSON config discovery is unavailable or returns nothing.
    if [[ ${#NETWORK_NAMES[@]} -eq 0 ]]; then
        NETWORK_NAMES=(vaultwarden_egress caddy_external)
    fi

    local -a SUBNETS=()
    local net subnet full_name
    for net in "${NETWORK_NAMES[@]}"; do
        # Resolve the subnet directly from JSON to avoid fragile YAML awk parsing.
        subnet=$(docker compose -f "${PROJECT_ROOT}/${compose_file}" config --format json 2>/dev/null | \
            python3 -c "
import json, sys
c = json.load(sys.stdin)
nets = c.get('networks', {})
n = nets.get('${net}', {})
cfgs = n.get('ipam', {}).get('config', [])
print(cfgs[0]['subnet'] if cfgs else '')
" 2>/dev/null || true)

        # Fall back to inspecting the running network when no static subnet is pinned.
        if [[ -z "${subnet:-}" ]]; then
            full_name=$(docker compose -f "${PROJECT_ROOT}/${compose_file}" config --format json 2>/dev/null | \
                python3 -c "
import json, sys
c = json.load(sys.stdin)
nets = c.get('networks', {})
n = nets.get('${net}', {})
print(n.get('name', '${net}_network'))
" 2>/dev/null || true)
            [[ -n "${full_name:-}" ]] || full_name="${net}_network"
            subnet=$(docker network inspect -f '{{with index .IPAM.Config 0}}{{.Subnet}}{{end}}' \
                "${full_name}" 2>/dev/null || true)
        fi

        if [[ -n "${subnet:-}" ]]; then
            SUBNETS+=("${subnet}")
        fi
    done

    # Always include the pinned egress subnet as a deterministic baseline.
    SUBNETS+=("172.21.0.0/16")

    local -a UNIQUE_SUBNETS=()
    mapfile -t UNIQUE_SUBNETS < <(printf '%s\n' "${SUBNETS[@]}" | awk 'NF && !seen[$0]++')

    for subnet in "${UNIQUE_SUBNETS[@]}"; do
        if [[ "$DRY_RUN" == "true" ]]; then
            if iptables -t nat -C POSTROUTING -s "$subnet" ! -o docker0 -j MASQUERADE >/dev/null 2>&1; then
                log_info "OK: MASQUERADE already present for $subnet (IPv4)"
            else
                log_dry_run "Would add: MASQUERADE for $subnet (IPv4)"
            fi
            continue
        fi
        if iptables -t nat -C POSTROUTING -s "$subnet" ! -o docker0 -j MASQUERADE >/dev/null 2>&1; then
            log_info "OK: MASQUERADE already present for $subnet (IPv4)"
            continue
        fi
        iptables -t nat -A POSTROUTING -s "$subnet" ! -o docker0 -j MASQUERADE
        log_success "ADDED: MASQUERADE for $subnet (IPv4)"
    done

    # Mirror the IPv4 MASQUERADE rules in ip6tables when IPv6 is enabled.
    # Docker assigns IPv6 ULA subnets such as fd00::/8, and without ip6tables
    # MASQUERADE, IPv6 container traffic cannot reach the internet.
    # This is best-effort because some kernels do not provide ip6tables support.
    if command -v ip6tables >/dev/null 2>&1; then
        for subnet in "${UNIQUE_SUBNETS[@]}"; do
            # Skip IPv4-only CIDR notation because ip6tables only handles IPv6 prefixes.
            if [[ "$subnet" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ ]]; then
                continue
            fi
            if [[ "$DRY_RUN" == "true" ]]; then
                if ip6tables -t nat -C POSTROUTING -s "$subnet" ! -o docker0 -j MASQUERADE >/dev/null 2>&1; then
                    log_info "OK: MASQUERADE already present for $subnet (IPv6)"
                else
                    log_dry_run "Would add: MASQUERADE for $subnet (IPv6)"
                fi
                continue
            fi
            if ip6tables -t nat -C POSTROUTING -s "$subnet" ! -o docker0 -j MASQUERADE >/dev/null 2>&1; then
                log_info "OK: MASQUERADE already present for $subnet (IPv6)"
                continue
            fi
            ip6tables -t nat -A POSTROUTING -s "$subnet" ! -o docker0 -j MASQUERADE
            log_success "ADDED: MASQUERADE for $subnet (IPv6)"
        done
    else
        log_warn "ip6tables not found — IPv6 MASQUERADE rules not applied."
        log_warn "Container IPv6 traffic may not reach the internet."
    fi

    # Remove OCI's default FORWARD REJECT rule if it is present.
    # Fresh Oracle Cloud instances inject:
    #   -A FORWARD -j REJECT --reject-with icmp-host-prohibited
    # This blocks container forwarding until removed, and the while loop handles
    # the case where the rule appears more than once.
    if [[ "$DRY_RUN" == "true" ]]; then
        if iptables -C FORWARD -j REJECT --reject-with icmp-host-prohibited 2>/dev/null; then
            log_dry_run "Would remove: OCI default FORWARD REJECT rule"
        else
            log_info "OK: OCI FORWARD REJECT rule not present (nothing to remove)"
        fi
    else
        local count=0
        while iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited 2>/dev/null; do
            count=$((count + 1))
        done
        if [[ $count -gt 0 ]]; then
            log_success "REMOVED: OCI default FORWARD REJECT rule (x${count})"
        else
            log_info "OK: OCI FORWARD REJECT rule not present (nothing to remove)"
        fi
    fi

    # Accept only the three pinned VaultWarden Compose subnets in DOCKER-USER.
    # Using pinned subnets instead of all RFC1918 ranges prevents future Docker
    # projects on this host from inheriting unrestricted forwarding.
    # Subnets: 172.21.0.0/16 (vaultwarden_egress), 172.22.0.0/16 (caddy_external),
    #          172.23.0.0/16 (postfix_relay), all pinned in docker-compose.yml.example.
    # Keep this append-only and idempotent so repeated runs stay predictable.
    if iptables -t filter -S DOCKER-USER >/dev/null 2>&1; then
        local cidr
        for cidr in "172.21.0.0/16" "172.22.0.0/16" "172.23.0.0/16"; do
            if [[ "$DRY_RUN" == "true" ]]; then
                if iptables -t filter -C DOCKER-USER -s "$cidr" -j ACCEPT >/dev/null 2>&1; then
                    log_info "OK: DOCKER-USER ACCEPT already present for pinned subnet $cidr"
                else
                    log_dry_run "Would add: DOCKER-USER ACCEPT for pinned VaultWarden subnet $cidr"
                fi
                continue
            fi
            if ! iptables -t filter -C DOCKER-USER -s "$cidr" -j ACCEPT >/dev/null 2>&1; then
                iptables -t filter -A DOCKER-USER -s "$cidr" -j ACCEPT
                log_success "ADDED: DOCKER-USER ACCEPT for pinned VaultWarden subnet $cidr"
            else
                log_info "OK: DOCKER-USER ACCEPT already present for pinned subnet $cidr"
            fi
        done
    else
        log_warn "DOCKER-USER chain not available; skipping forward-policy remediation"
    fi

    # Persist iptables rules across reboots with netfilter-persistent.
    # Install it automatically with confirmation or --yes / --auto when absent.
    if [[ "$DRY_RUN" == "true" ]]; then
        if command -v netfilter-persistent >/dev/null 2>&1; then
            log_dry_run "Would run: netfilter-persistent save"
        else
            log_dry_run "Would install netfilter-persistent iptables-persistent and run: netfilter-persistent save"
        fi
        return 0
    fi

    if ! command -v netfilter-persistent >/dev/null 2>&1; then
        log_warn "netfilter-persistent not installed — rules will be lost on reboot."

        local _do_install=false
        if [[ "$YES" == "true" ]]; then
            _do_install=true
        else
            local _reply
            read -r -p "Install netfilter-persistent and iptables-persistent now? [y/N] " _reply
            [[ "${_reply,,}" == "y" || "${_reply,,}" == "yes" ]] && _do_install=true
        fi

        if [[ "$_do_install" == "true" ]]; then
            log_info "Installing netfilter-persistent iptables-persistent..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                netfilter-persistent iptables-persistent >/dev/null 2>&1 || {
                log_warn "apt-get install netfilter-persistent failed — rules will not persist across reboots."
                return 0
            }
            log_success "netfilter-persistent installed."
        else
            log_warn "Skipping netfilter-persistent install — iptables rules will NOT persist across reboots."
            log_warn "Install with: apt-get install -y netfilter-persistent iptables-persistent"
            return 0
        fi
    fi

    if ! netfilter-persistent save >/dev/null 2>&1; then
        log_error "netfilter-persistent save failed — rules may not survive reboot."
        exit 1
    fi
    log_success "Persisted iptables rules with netfilter-persistent"
}

main() {
    (( EUID == 0 )) || { log_error "Must run as root."; exit 1; }

    [[ "$AUTO_MODE" == "true" ]] && log_info "Running in non-interactive (auto) mode (--yes implied)."
    [[ "$AUTO_MODE" != "true" && "$YES" == "true" ]] && log_info "Auto-confirm (--yes) enabled."

    case "$PHASE" in
        ufw)      _phase_ufw ;;
        iptables) _phase_iptables ;;
        all)      _phase_ufw; _phase_iptables ;;
    esac
}

main
