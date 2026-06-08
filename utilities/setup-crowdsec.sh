#!/usr/bin/env bash
# utilities/setup-crowdsec.sh — Installs and configures CrowdSec and the
# Cloudflare *Workers* bouncer (crowdsec-cloudflare-worker-bouncer) for
# VaultWarden-OCI.
#
# Free-plan note:
#   KV writes are capped at 1 K/day on the Cloudflare free plan, so the
#   initial blocklist population is truncated.  Subsequent incremental syncs
#   continue normally.  This script automatically restricts decisions to
#   locally generated ones (cscli + crowdsec engine) so the KV budget is not
#   wasted on community blocklist churn.  Set CF_FREE_PLAN=false in .env to
#   disable this guard.
#
# Usage:
#   sudo ./utilities/setup-crowdsec.sh [OPTIONS]
#
# See --help for all options.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
    printf 'VaultWarden-OCI %s\n' "$(tr -d '[:space:]' < "${PROJECT_ROOT}/VERSION" 2>/dev/null || echo unknown)"
    exit 0
fi

if [[ "${1:-}" != "--help" && "${1:-}" != "-h" && "${1:-}" != "help" && "${EUID}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -n "$0" "$@"
    fi
    echo "ERROR: run as root (or install/configure sudo)" >&2
    exit 1
fi

cd "${PROJECT_ROOT}"

# ---------------------------------------------------------------------------
# Library loading
# ---------------------------------------------------------------------------
_LIBS_LOADED=false
for _lib in log.sh config.sh common.sh storage.sh secrets.sh; do
    _lib_path="${PROJECT_ROOT}/lib/${_lib}"
    if [[ -f "$_lib_path" ]]; then
        # shellcheck disable=SC1090
        source "$_lib_path"
        [[ "$_lib" == "common.sh" ]] && _LIBS_LOADED=true
    fi
done
unset _lib _lib_path

if [[ "$_LIBS_LOADED" == "true" ]]; then
    set_log_prefix "crowdsec"
else
    log_info()    { printf '[INFO]    crowdsec %s\n'    "$*"; }
    log_success() { printf '[SUCCESS] crowdsec %s\n'    "$*"; }
    log_warn()    { printf '[WARN]    crowdsec %s\n'    "$*" >&2; }
    log_error()   { printf '[ERROR]   crowdsec %s\n'    "$*" >&2; }
fi

# Provide COLOR_* fallbacks for standalone runs without lib/common.sh.
if [[ "$_LIBS_LOADED" != "true" ]]; then
    COLOR_RED=''
    COLOR_GREEN=''
    # shellcheck disable=SC2034
    COLOR_YELLOW=''
    # shellcheck disable=SC2034
    COLOR_CYAN=''
    COLOR_RESET=''
fi

# ---------------------------------------------------------------------------
# Load .env
# ---------------------------------------------------------------------------
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
    if declare -f load_env_file >/dev/null 2>&1; then
        load_env_file "${PROJECT_ROOT}/.env" || true
    else
        # shellcheck disable=SC1091
        source "${PROJECT_ROOT}/.env" 2>/dev/null || true
    fi
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write or update a KEY=VALUE line in .env using an atomic temp-file + mv.
_cs_set_env_var() {
    local key="$1" value="$2"
    local env_file="${PROJECT_ROOT}/.env"
    [[ -f "$env_file" ]] || return 0
    local escaped_value
    escaped_value="${value//\\/\\\\}"
    escaped_value="${escaped_value//&/\\&}"
    escaped_value="${escaped_value//|/\\|}"
    local tmp_file
    tmp_file="$(dirname "$env_file")/.env.tmp.$$"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_file'" RETURN
    if grep -q "^${key}=" "$env_file" 2>/dev/null; then
        sed "s|^${key}=.*|${key}=${escaped_value}|" "$env_file" > "$tmp_file"
    else
        cp "$env_file" "$tmp_file"
        printf '%s=%s\n' "$key" "$value" >> "$tmp_file"
    fi
    chmod --reference="$env_file" "$tmp_file" 2>/dev/null || true
    mv "$tmp_file" "$env_file"
}

# Remove a KEY= line from .env using an atomic temp-file + mv.
# Used by _cs_reset_components to clear auto-generated keys before a --force run.
_cs_clear_env_var() {
    local key="$1"
    local env_file="${PROJECT_ROOT}/.env"
    [[ -f "$env_file" ]] || return 0
    local tmp_file
    tmp_file="$(dirname "$env_file")/.env.tmp.$$"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_file'" RETURN
    sed "/^${key}=/d" "$env_file" > "$tmp_file"
    chmod --reference="$env_file" "$tmp_file" 2>/dev/null || true
    mv "$tmp_file" "$env_file"
}


# ---------------------------------------------------------------------------
# Read the currently configured LAPI port from config.yaml.
# Prints the port number; defaults to 8080 if not found.
# ---------------------------------------------------------------------------
_cs_resolve_lapi_port() {
    grep -oP '(?<=listen_uri:\s{0,10}127\.0\.0\.1:)\d+' \
        /etc/crowdsec/config.yaml 2>/dev/null \
        | head -1 \
        || echo "8090"
}

# ---------------------------------------------------------------------------
# Find the lowest unused TCP port >= base_port on 127.0.0.1.
# Prints the free port number.
# ---------------------------------------------------------------------------
_cs_find_free_port() {
    local base_port="${1:-8090}"
    local port="$base_port"
    while ss -tlnp 2>/dev/null | grep -q ":${port}[[:space:]]"; do
        (( port++ ))
        if (( port > 65000 )); then
            echo "8090"   # safety fallback — should never happen
            return
        fi
    done
    echo "$port"
}

# ---------------------------------------------------------------------------
# Rewrite all CrowdSec config files from old_port -> new_port atomically.
# ---------------------------------------------------------------------------
_cs_fix_port_conflict() {
    local old_port="$1"
    local new_port="$2"

    log_info "Auto-fixing LAPI port conflict: ${old_port} -> ${new_port}"

    local _f
    _f="/etc/crowdsec/config.yaml"
    if [[ -f "$_f" ]]; then
        sed -i "s|listen_uri: 127.0.0.1:${old_port}|listen_uri: 127.0.0.1:${new_port}|g" "$_f"
        log_info "  Updated ${_f}"
    fi

    _f="/etc/crowdsec/local_api_credentials.yaml"
    if [[ -f "$_f" ]]; then
        sed -i "s|url: http://127.0.0.1:${old_port}|url: http://127.0.0.1:${new_port}|g" "$_f"
        log_info "  Updated ${_f}"
    fi

    _f="/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"
    if [[ -f "$_f" ]]; then
        sed -i "s|api_url: http://127.0.0.1:${old_port}/|api_url: http://127.0.0.1:${new_port}/|g" "$_f"
        log_info "  Updated ${_f}"
    fi

    _f="/etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml"
    if [[ -f "$_f" ]]; then
        sed -i \
            -e "s|lapi_url: http://127.0.0.1:${old_port}|lapi_url: http://127.0.0.1:${new_port}|g" \
            -e "s|api_url: http://127.0.0.1:${old_port}/|api_url: http://127.0.0.1:${new_port}/|g" \
            "$_f"
        log_info "  Updated ${_f}"
    fi

    systemctl daemon-reload 2>/dev/null || true
    log_success "LAPI port rewritten to ${new_port} across all config files."
}

# ---------------------------------------------------------------------------
# Port-conflict diagnostic helper
# ---------------------------------------------------------------------------
_cs_diagnose_port() {
    local port="$1"
    local info=""

    if command -v ss >/dev/null 2>&1; then
        info="$(ss -tlnp "sport = :${port}" 2>/dev/null | grep -v '^Netid' || true)"
    fi

    if [[ -z "$info" ]] && command -v lsof >/dev/null 2>&1; then
        info="$(lsof -i :"${port}" -sTCP:LISTEN -n -P 2>/dev/null || true)"
    fi

    if [[ -n "$info" ]]; then
        log_error "Port ${port} is held by:"
        while IFS= read -r line; do
            log_error "  ${line}"
        done <<< "$info"
    else
        log_error "Could not identify what holds port ${port} — run: sudo ss -tlnp | grep ${port}"
    fi
}

# ---------------------------------------------------------------------------
# Attempt to start CrowdSec, with automatic port-conflict resolution.
# ---------------------------------------------------------------------------
_cs_start_service() {
    systemctl reset-failed crowdsec 2>/dev/null || true

    local _lapi_port
    _lapi_port="$(_cs_resolve_lapi_port)"

    if ss -tlnp 2>/dev/null | grep -q ":${_lapi_port}[[:space:]]"; then
        log_warn "Pre-flight: port ${_lapi_port} is already in use before CrowdSec start."
        _cs_diagnose_port "${_lapi_port}"
        local _new_port
        _new_port="$(_cs_find_free_port 8090)"
        _cs_fix_port_conflict "${_lapi_port}" "${_new_port}"
        _lapi_port="$_new_port"
        log_info "Pre-flight port reassignment complete: LAPI will use ${_lapi_port}."
    fi
    # --- END PRE-FLIGHT -------------------------------------------------------

    if systemctl enable --now crowdsec 2>/dev/null; then
        local _i
        for _i in {1..5}; do
            if systemctl is-active --quiet crowdsec; then
                return 0
            fi
            sleep 1
        done
    fi

    if ss -tlnp 2>/dev/null | grep -q ":${_lapi_port}[[:space:]]"; then
        log_warn "Post-start: port ${_lapi_port} is occupied — attempting reassignment."
        _cs_diagnose_port "${_lapi_port}"

        local _new_port
        _new_port="$(_cs_find_free_port 8090)"
        _cs_fix_port_conflict "${_lapi_port}" "${_new_port}"

        systemctl reset-failed crowdsec 2>/dev/null || true
        if systemctl enable --now crowdsec 2>/dev/null; then
            local _j
            for _j in {1..8}; do
                if systemctl is-active --quiet crowdsec; then
                    log_success "CrowdSec started successfully on port ${_new_port}."
                    return 0
                fi
                sleep 1
            done
        fi

        log_error "CrowdSec service failed to start even after port reassignment to ${_new_port}."
    else
        log_error "CrowdSec service failed to start (no port conflict detected — check journalctl)."
    fi

    log_error "systemctl status crowdsec:"
    systemctl status crowdsec --no-pager -l 2>&1 | head -30 | while IFS= read -r _l; do
        log_error "  ${_l}"
    done
    log_error "Full journal: sudo journalctl -xeu crowdsec --no-pager | tail -50"
    return 1
}

# ---------------------------------------------------------------------------
# Reset all CrowdSec components installed by a previous run.
# ---------------------------------------------------------------------------
_cs_reset_components() {
    log_info "=== PHASE 0: Resetting installed CrowdSec components (--force) ==="

    # If the CF bouncer package is in a broken dpkg half-configured state,
    # purge it now so apt doesn't abort on the next install attempt.
    if dpkg -l crowdsec-cloudflare-worker-bouncer 2>/dev/null | grep -qE '^(iF|iU|hF)'; then
        log_info "Detected broken dpkg state for crowdsec-cloudflare-worker-bouncer — purging."
        DEBIAN_FRONTEND=noninteractive dpkg --purge --force-remove-reinstreq \
            crowdsec-cloudflare-worker-bouncer 2>/dev/null || true
        log_info "Purge complete — package will be re-installed cleanly."
    fi

    if command -v cscli >/dev/null 2>&1; then
        cscli bouncers delete cloudflare-worker-bouncer 2>/dev/null || true
        cscli bouncers delete firewall-bouncer          2>/dev/null || true
        log_info "Cleared existing LAPI bouncer registrations (best-effort)."
    fi

    local _svc
    for _svc in crowdsec-cloudflare-worker-bouncer crowdsec-firewall-bouncer crowdsec; do
        if systemctl is-active  --quiet "$_svc" 2>/dev/null || \
           systemctl is-enabled --quiet "$_svc" 2>/dev/null; then
            systemctl disable --now "$_svc" 2>/dev/null || true
            log_info "Stopped and disabled: ${_svc}"
        fi
    done

    rm -f /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml 2>/dev/null || true
    rm -f /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml           2>/dev/null || true
    log_info "Removed bouncer config files — Phase 1b will generate fresh API keys."

    _cs_clear_env_var "CROWDSEC_CF_BOUNCER_API_KEY"
    log_info "Cleared auto-generated LAPI key from .env (will be regenerated in Phase 5)."

    log_success "Phase 0 complete — all components reset for fresh installation."
}

# ---------------------------------------------------------------------------
# CLI flags
# ---------------------------------------------------------------------------
AUTO_MODE=false
DRY_RUN=false
FORCE=false
AUTONOMOUS_MODE=false
USE_LATEST=false
ADMIN_IP=""

CROWDSEC_VERSION="${CROWDSEC_VERSION:-}"
CF_WORKER_BOUNCER_VERSION="${CF_WORKER_BOUNCER_VERSION:-}"

show_help() {
    cat <<'HELP'
VaultWarden-OCI CrowdSec Setup

USAGE:
    sudo utilities/setup-crowdsec.sh [OPTIONS]

DESCRIPTION:
    Installs and configures CrowdSec with the Cloudflare Workers bouncer
    for VaultWarden-OCI intrusion detection and edge-level banning.
    Requires CLOUDFLARE_PROXY_ENABLED=true for the Cloudflare bouncer phase.

OPTIONS:
    --auto               Non-interactive: never prompt.
    --dry-run            Print what would happen without changing files.
    --force              Re-run all phases even if already applied.
    --use-latest         Override version pins and use the current live upstream
                         release of each component.
    --autonomous         Deploy the Workers bouncer in autonomous mode (-S flag).
    --admin-ip IP|CIDR   Add this IP address or CIDR to the CrowdSec admin
                         allowlist.
    --help, -h           Show this help.
    --version, -V        Print the VaultWarden-OCI version and exit.

ENVIRONMENT:
    CLOUDFLARE_PROXY_ENABLED   Set to 'true' to enable the Cloudflare bouncer.
    CF_FREE_PLAN               Set to 'false' to disable the free-plan KV write
                               guard. Default: 'true'.
    CROWDSEC_VERSION           Pin a specific CrowdSec version.
    CF_WORKER_BOUNCER_VERSION  Pin a specific Workers bouncer version.

    Cloudflare credentials (in encrypted secrets, not .env):
        sudo ./edit-secrets.sh rotate cf_worker_bouncer_token
        sudo ./edit-secrets.sh rotate cloudflare_zone_id
        sudo ./edit-secrets.sh rotate cf_account_id

EXAMPLES:
    sudo utilities/setup-crowdsec.sh
    sudo utilities/setup-crowdsec.sh --dry-run
    sudo utilities/setup-crowdsec.sh --force
HELP
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)        AUTO_MODE=true; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --force)       FORCE=true; shift ;;
        --use-latest)  USE_LATEST=true; shift ;;
        --autonomous)  AUTONOMOUS_MODE=true; shift ;;
        --admin-ip)
            if [[ -z "${2-}" || "${2}" == --* ]]; then
                log_error "--admin-ip requires a value (e.g. --admin-ip 203.0.113.42 or --admin-ip 203.0.113.0/24)"
                exit 1
            fi
            ADMIN_IP="$2"; shift 2 ;;
        --help|-h)
            show_help
            exit 0 ;;
        --version|-V)
            print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"
            exit 0 ;;
        help)
            show_help
            exit 0 ;;
        *)
            log_error "Unknown flag: $1"
            exit 1 ;;
    esac
done

if [[ "$AUTO_MODE" == "true" ]]; then
    log_info "Running in non-interactive (auto) mode."
fi

if [[ "$USE_LATEST" == "true" ]]; then
    CROWDSEC_VERSION=""
    CF_WORKER_BOUNCER_VERSION=""
    log_info "Version pins cleared by --use-latest; all components will use current upstream releases."
fi

# ---------------------------------------------------------------------------
# Execution wrapper
# ---------------------------------------------------------------------------
_cs_run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] $*"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# Service-existence guards
# ---------------------------------------------------------------------------
_cf_worker_bouncer_service_exists() {
    [[ -f "/etc/systemd/system/crowdsec-cloudflare-worker-bouncer.service" ]] || \
    [[ -f "/lib/systemd/system/crowdsec-cloudflare-worker-bouncer.service" ]]
}

# ---------------------------------------------------------------------------
# Write the crowdsec-cloudflare-worker-bouncer systemd unit if needed.
# ---------------------------------------------------------------------------
_cs_ensure_cf_worker_unit() {
    local bin_path="${1:-/usr/local/bin/crowdsec-cloudflare-worker-bouncer}"
    if [[ -x "$bin_path" ]] && ! _cf_worker_bouncer_service_exists && [[ "$AUTONOMOUS_MODE" != "true" ]]; then
        log_info "Writing crowdsec-cloudflare-worker-bouncer systemd unit..."
        cat >/etc/systemd/system/crowdsec-cloudflare-worker-bouncer.service <<'UNIT'
[Unit]
Description=CrowdSec Cloudflare Workers Bouncer
After=network-online.target crowdsec.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/crowdsec-cloudflare-worker-bouncer -c /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml
Restart=on-failure
RestartSec=5
User=root
Group=root

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload || true
        log_success "Installed crowdsec-cloudflare-worker-bouncer systemd unit."
    fi
}

# ---------------------------------------------------------------------------
# PHASE 0: Reset installed components when --force is active.
# ---------------------------------------------------------------------------
if [[ "$FORCE" == "true" ]]; then
    _cs_reset_components
fi

# ---------------------------------------------------------------------------
# PHASE 1: CrowdSec base installation
# ---------------------------------------------------------------------------
log_info "=== PHASE 1: CrowdSec base installation ==="

_legacy_notify_unit="/etc/systemd/system/vaultwarden-notify-failure.service"
if [[ -f "$_legacy_notify_unit" ]] && grep -q "Review failed units with:" "$_legacy_notify_unit" 2>/dev/null; then
    log_warn "Detected legacy vaultwarden-notify-failure.service payload; normalizing for CrowdSec compatibility."
    sed -i 's/Review failed units with:\\n  systemctl --failed\\n/Run: systemctl --failed/g' "$_legacy_notify_unit" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
fi

if command -v cscli >/dev/null 2>&1 && [[ "$FORCE" != "true" ]]; then
    log_info "CrowdSec already installed — skipping base install."
elif [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would install crowdsec, crowdsec-firewall-bouncer-iptables, and ipset"
else
    log_info "Adding CrowdSec repository..."
    _repo_script="$(mktemp -p /tmp cs-repo-setup.XXXXXX.sh)"
    # shellcheck disable=SC2064
    trap "rm -f '$_repo_script'" RETURN
    if ! curl -fsSL --connect-timeout 15 --max-time 30 \
            https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh \
            -o "$_repo_script"; then
        log_error "Failed to download CrowdSec repository setup script."
        rm -f "$_repo_script"
        return 1
    fi
    # Verify the script came from the expected source and is a shell script
    if ! head -1 "$_repo_script" | grep -qE '^#!/(usr/)?bin/(env )?bash'; then
        log_error "Downloaded repository script does not appear to be a valid shell script — aborting."
        rm -f "$_repo_script"
        return 1
    fi
    bash "$_repo_script"
    rm -f "$_repo_script"

    _cs_pkg="crowdsec"
    if [[ -n "$CROWDSEC_VERSION" ]]; then
        _cs_pkg="crowdsec=${CROWDSEC_VERSION}"
        log_info "CrowdSec version pinned: ${CROWDSEC_VERSION}"
    else
        log_info "CrowdSec version: installing latest from packagecloud repository"
    fi

    log_info "Installing CrowdSec engine package first..."
    _fw_base="crowdsec-firewall-bouncer"
    if iptables -V 2>/dev/null | grep -q 'nf_tables'; then
        _fw_suffix="nftables"
        log_info "nftables detected — installing crowdsec-firewall-bouncer-nftables."
    else
        _fw_suffix="iptables"
        log_info "iptables detected — installing crowdsec-firewall-bouncer-iptables."
    fi

    if [[ -n "${FIREWALL_BOUNCER_VERSION:-}" ]]; then
        _fw_pkg="${_fw_base}-${_fw_suffix}=${FIREWALL_BOUNCER_VERSION}"
        log_info "Firewall bouncer version pinned: ${FIREWALL_BOUNCER_VERSION}"
    else
        _fw_pkg="${_fw_base}-${_fw_suffix}"
        log_info "Firewall bouncer version: installing latest from packagecloud repository"
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -y "$_cs_pkg"
    log_info "Installing CrowdSec firewall bouncer package..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$_fw_pkg"
    log_info "Installing ipset (required by crowdsec-firewall-bouncer iptables backend)..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y ipset

    # --- CRITICAL: rewrite upstream default port (8080) to 8090 immediately
    # after package install, before the service is ever started. This prevents
    # CrowdSec from racing Caddy for port 8080 on first boot.
    if grep -q 'listen_uri: 127.0.0.1:8080' /etc/crowdsec/config.yaml 2>/dev/null; then
        log_info "Rewriting upstream default LAPI port 8080 -> 8090 in config.yaml..."
        _cs_fix_port_conflict "8080" "8090"
        log_success "LAPI port pre-assigned to 8090 — Caddy owns 8080."
    fi
fi

if [[ "$DRY_RUN" != "true" ]]; then
    if systemctl is-active --quiet crowdsec; then
        log_info "CrowdSec service already active — reloading configuration."
        systemctl reload crowdsec 2>/dev/null || systemctl restart crowdsec 2>/dev/null || true
    elif ! _cs_start_service; then
        log_error "Cannot continue with a stopped CrowdSec service."
        log_error "Resolve the issue above, then re-run: sudo ./utilities/setup-crowdsec.sh"
        exit 1
    fi
    log_success "CrowdSec service enabled and running."
fi

# ---------------------------------------------------------------------------
# PHASE 1b: Firewall bouncer config (DOCKER-USER chain)
# ---------------------------------------------------------------------------
log_info "=== PHASE 1b: Firewall bouncer config ==="

_FW_BOUNCER_CONFIG="/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"
_LAPI_PORT="$(_cs_resolve_lapi_port)"

if [[ "$DRY_RUN" != "true" ]]; then
    if ! command -v ipset >/dev/null 2>&1; then
        log_warn "ipset not found — installing now (required by crowdsec-firewall-bouncer iptables backend)."
        DEBIAN_FRONTEND=noninteractive apt-get install -y ipset \
            && log_success "ipset installed successfully." \
            || log_error "Failed to install ipset — crowdsec-firewall-bouncer may not start."
    fi
fi

if [[ -f "$_FW_BOUNCER_CONFIG" ]]; then
    log_info "Firewall bouncer config already present — checking DOCKER-USER chain."
    if ! grep -q 'DOCKER-USER' "$_FW_BOUNCER_CONFIG"; then
        log_info "Adding DOCKER-USER chain to existing firewall bouncer config..."
        sed -i '/iptables_chains:/,/^[^ ]/{/- INPUT/a\  - DOCKER-USER
}' "$_FW_BOUNCER_CONFIG" 2>/dev/null || true
        systemctl restart crowdsec-firewall-bouncer 2>/dev/null || true
        log_success "DOCKER-USER chain added to firewall bouncer config."
    else
        log_info "DOCKER-USER chain already present in firewall bouncer config."

    # --force wiped the LAPI in Phase 0 so the existing key is now stale.
    # Regenerate unconditionally when --force is active.
    if [[ "$FORCE" == "true" ]]; then
        log_info "Force mode: regenerating firewall bouncer API key..."
        _fw_fresh_key="$(openssl rand -hex 32)"
        cscli bouncers delete crowdsecurity/firewall-bouncer 2>/dev/null || true
        cscli bouncers add crowdsecurity/firewall-bouncer --key "$_fw_fresh_key" 2>/dev/null || true
        sed -i "s|^api_key:.*|api_key: ${_fw_fresh_key}|" "$_FW_BOUNCER_CONFIG"
        log_success "Firewall bouncer key regenerated and written to config."
    fi
    fi

    if ! cscli bouncers list 2>/dev/null | grep -q 'firewall-bouncer'; then
        _fw_existing_key="$(grep 'api_key:' "$_FW_BOUNCER_CONFIG" 2>/dev/null | awk '{print $2}' | head -1 || true)"
        if [[ -n "$_fw_existing_key" && "$_fw_existing_key" != "CHANGE_ME"* ]]; then
            log_info "Firewall bouncer not found in LAPI — re-registering with existing config key..."
            # Attempt re-register; if it fails the key is revoked — generate a fresh one.
            if ! cscli bouncers add crowdsecurity/firewall-bouncer --key "$_fw_existing_key" 2>/dev/null; then
                log_warn "Existing key rejected by LAPI (likely revoked) — generating a fresh key..."
                _fw_existing_key="$(openssl rand -hex 32)"
                cscli bouncers delete crowdsecurity/firewall-bouncer 2>/dev/null || true
                cscli bouncers add crowdsecurity/firewall-bouncer --key "$_fw_existing_key" 2>/dev/null || true
                sed -i "s|^api_key:.*|api_key: ${_fw_existing_key}|" "$_FW_BOUNCER_CONFIG"
                log_success "Fresh firewall bouncer key generated and written to config."
            else
                log_success "Firewall bouncer re-registered in LAPI."
            fi
        else
            log_warn "Firewall bouncer not in LAPI and config key is missing/placeholder."
            log_warn "Run: sudo ./utilities/setup-crowdsec.sh --force  to regenerate a valid key."
        fi
    fi
elif [[ ! -f "$_FW_BOUNCER_CONFIG" ]] && [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would write firewall bouncer config with DOCKER-USER chain"
else
    if ! cscli bouncers list 2>/dev/null | grep -q 'firewall-bouncer'; then
        log_info "Registering firewall bouncer in CrowdSec LAPI..."
        _fw_key="$(openssl rand -hex 32)"
        cscli bouncers add crowdsecurity/firewall-bouncer --key "$_fw_key" 2>/dev/null || true
    else
        _fw_key="$(grep 'api_key:' "$_FW_BOUNCER_CONFIG" 2>/dev/null | awk '{print $2}' | head -1 || true)"
    fi

    # Detect whether iptables is using the nf_tables backend (Ubuntu 22.04+/Noble)
    if iptables -V 2>/dev/null | grep -q 'nf_tables'; then
        _fw_mode="nftables"
        _fw_chains_block="nftables_hooks:
  - input
  - forward"
    else
        _fw_mode="iptables"
        _fw_chains_block="iptables_chains:
  - INPUT
  - DOCKER-USER"
    fi

    cat > "$_FW_BOUNCER_CONFIG" <<FWCONFIG
mode: ${_fw_mode}
update_frequency: 10s
log_mode: stdout
log_level: info
api_url: http://127.0.0.1:${_LAPI_PORT}/
api_key: ${_fw_key:-CHANGE_ME_FW_BOUNCER_KEY}

origins: []

${_fw_chains_block}

deny_action: DROP
disable_ipv6: false
FWCONFIG
    chmod 600 "$_FW_BOUNCER_CONFIG"
    log_success "Firewall bouncer config written: ${_FW_BOUNCER_CONFIG}"
fi

# ---------------------------------------------------------------------------
# PHASE 2: Cloudflare Workers bouncer installation
# ---------------------------------------------------------------------------
log_info "=== PHASE 2: Cloudflare Workers bouncer installation ==="

_CF_PROXY_ENABLED="${CLOUDFLARE_PROXY_ENABLED:-false}"
_CF_WORKER_BOUNCER_BIN="/usr/local/bin/crowdsec-cloudflare-worker-bouncer"
_CF_WORKER_BOUNCER_NEEDS_INSTALL=false

if [[ "$_CF_PROXY_ENABLED" != "true" ]]; then
    log_warn "Skipping crowdsec-cloudflare-worker-bouncer setup — CLOUDFLARE_PROXY_ENABLED is not 'true'."
    log_warn "Set CLOUDFLARE_PROXY_ENABLED=true in .env and re-run this script to enable the Cloudflare Workers bouncer."
elif [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would install crowdsec-cloudflare-worker-bouncer (apt -> tarball -> go source fallback)"
else
    if ! cscli bouncers list 2>/dev/null | grep -q 'cloudflare-worker-bouncer' || [[ "$FORCE" == "true" ]]; then
        log_info "Updating CrowdSec hub..."
        cscli hub update || true
        log_info "Registering Cloudflare Workers bouncer in CrowdSec LAPI..."
        cscli bouncers add crowdsecurity/cloudflare-worker-bouncer >/dev/null 2>&1 || true
    else
        log_info "CrowdSec Cloudflare Workers bouncer already registered — skipping."
    fi

    if [[ ! -x "$_CF_WORKER_BOUNCER_BIN" ]] || [[ "$FORCE" == "true" ]]; then
        _CF_WORKER_BOUNCER_NEEDS_INSTALL=true
    fi

    if [[ "$_CF_WORKER_BOUNCER_NEEDS_INSTALL" == "true" ]]; then
        log_info "Cloudflare Workers bouncer binary not found — attempting installation..."

        _arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
        case "$_arch" in
            arm64|aarch64) _arch="arm64" ;;
            amd64|x86_64)  _arch="amd64" ;;
            *)
                log_warn "Unsupported architecture: $_arch — skipping Workers bouncer install"
                _arch=""
                ;;
        esac

        _installed_via_deb=false

        if [[ -n "$_arch" ]]; then
            # Pre-create a minimal stub config so the package postinst script
            # does not abort trying to open a non-existent config file.
            # Phase 6 will overwrite this with the real values.
            if [[ ! -f /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml ]]; then
                mkdir -p /etc/crowdsec/bouncers
                cat > /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml <<'STUB'
crowdsec_config:
  lapi_url: "http://127.0.0.1:8090/"
  lapi_key: "STUB_KEY"
update_frequency: "10s"
log_mode: "stdout"
STUB
                chmod 600 /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml
                log_info "Wrote stub CF bouncer config to satisfy dpkg postinst."
            fi
            log_info "Attempting apt install of crowdsec-cloudflare-worker-bouncer..."
            if DEBIAN_FRONTEND=noninteractive apt-get install -y crowdsec-cloudflare-worker-bouncer 2>/dev/null; then
                log_success "Installed crowdsec-cloudflare-worker-bouncer via apt."
                _installed_via_deb=true
                _apt_bin="$(command -v crowdsec-cloudflare-worker-bouncer 2>/dev/null || true)"
                if [[ -n "$_apt_bin" && "$_apt_bin" != "$_CF_WORKER_BOUNCER_BIN" ]]; then
                    ln -sf "$_apt_bin" "$_CF_WORKER_BOUNCER_BIN"
                    log_info "Symlinked ${_apt_bin} -> ${_CF_WORKER_BOUNCER_BIN} for path consistency."
                fi
            else
                log_warn "apt install failed — falling back to GitHub release tarball."
            fi
        fi

        if [[ "$_installed_via_deb" == "false" && -n "$_arch" ]]; then
            if [[ -z "$CF_WORKER_BOUNCER_VERSION" ]]; then
                _gh_api="https://api.github.com/repos/crowdsecurity/cs-cloudflare-worker-bouncer/releases/latest"
                log_info "CF Workers bouncer version: fetching latest from GitHub."
            else
                _ver="${CF_WORKER_BOUNCER_VERSION#v}"   # strip leading 'v' if present
                _gh_api="https://api.github.com/repos/crowdsecurity/cs-cloudflare-worker-bouncer/releases/tags/v${_ver}"
                log_info "CF Workers bouncer version pinned: v${_ver}"
            fi

            _release_json="$(curl -fsSL "$_gh_api" 2>/dev/null)" || {
                log_warn "Failed to query GitHub releases for cs-cloudflare-worker-bouncer."
                _release_json=""
            }

            if [[ -n "$_release_json" ]]; then
                _download_url="$(printf '%s' "$_release_json" | \
                    grep -oP '"browser_download_url":\s*"\K[^"]+' | \
                    grep "linux-${_arch}" | \
                    grep '\.tgz$' | \
                    grep -v '\.sha256' | \
                    head -1 || true)"
                _sha256_url="$(printf '%s' "$_release_json" | \
                    grep -oP '"browser_download_url":\s*"\K[^"]+' | \
                    grep "linux-${_arch}" | \
                    grep '\.tgz\.sha256$' | \
                    head -1 || true)"

                if [[ -n "$_download_url" ]]; then
                    _tmpdir="$(mktemp -d -p /tmp cs-cf-worker.XXXXXX)"
                    _tmptar="${_tmpdir}/bouncer.tgz"

                    log_info "Downloading: $_download_url"
                    if curl -fsSL "$_download_url" -o "$_tmptar"; then
                        if [[ -n "$_sha256_url" ]]; then
                            _expected_sha="$(curl -fsSL "$_sha256_url" 2>/dev/null | awk '{print $1}' || true)"
                            _actual_sha="$(sha256sum "$_tmptar" | awk '{print $1}')"
                            if [[ -n "$_expected_sha" && "$_actual_sha" != "$_expected_sha" ]]; then
                                log_error "SHA256 mismatch — aborting tarball install."
                                rm -rf "$_tmpdir"
                                _tmpdir=""
                            fi
                        fi

                        if [[ -n "$_tmpdir" && -f "$_tmptar" ]]; then
                            tar xzf "$_tmptar" -C "$_tmpdir"
                            rm -f "$_tmptar"

                            _install_sh="$(find "$_tmpdir" -maxdepth 2 -name 'install.sh' | head -1 || true)"

                            if [[ -n "$_install_sh" && -f "$_install_sh" ]]; then
                                _install_dir="$(dirname "$_install_sh")"
                                log_info "Running bundled installer from: $_install_dir"
                                if (cd "$_install_dir" && bash install.sh); then
                                    log_success "Installed cs-cloudflare-worker-bouncer via tarball install.sh."
                                else
                                    log_warn "Bundled install.sh failed — attempting manual binary extraction."
                                    _bin_path="$(find "$_tmpdir" -maxdepth 3 -type f \
                                        -name 'crowdsec-cloudflare-worker-bouncer' \
                                        ! -name '*.sh' | head -1 || true)"
                                    if [[ -x "$_bin_path" ]]; then
                                        install -m 755 -o root -g root "$_bin_path" "$_CF_WORKER_BOUNCER_BIN"
                                        log_success "Copied binary to ${_CF_WORKER_BOUNCER_BIN} (manual fallback)."
                                    fi
                                fi
                            else
                                log_warn "No install.sh found in tarball — extracting binary directly."
                                _bin_path="$(find "$_tmpdir" -maxdepth 3 -type f \
                                    -name 'crowdsec-cloudflare-worker-bouncer' \
                                    ! -name '*.sh' | head -1 || true)"
                                if [[ -x "$_bin_path" ]]; then
                                    install -m 755 -o root -g root "$_bin_path" "$_CF_WORKER_BOUNCER_BIN"
                                    log_success "Copied binary to ${_CF_WORKER_BOUNCER_BIN}."
                                fi
                            fi
                        fi

                        [[ -n "${_tmpdir:-}" ]] && rm -rf "$_tmpdir"
                    else
                        log_warn "Failed to download tarball from GitHub."
                        rm -rf "$_tmpdir"
                    fi
                else
                    log_warn "No linux-${_arch} tarball asset found in latest GitHub release."
                fi
            fi
        fi

        if [[ "$_installed_via_deb" == "false" && -n "$_arch" && ! -x "$_CF_WORKER_BOUNCER_BIN" ]]; then
            if command -v go >/dev/null 2>&1; then
                log_info "Attempting Go source build for crowdsec-cloudflare-worker-bouncer..."
                if [[ -z "$CF_WORKER_BOUNCER_VERSION" ]]; then
                    _go_pkg_ref="github.com/crowdsecurity/cs-cloudflare-worker-bouncer/cmd/crowdsec-cloudflare-worker-bouncer@latest"
                else
                    _ver="${CF_WORKER_BOUNCER_VERSION#v}"
                    _go_pkg_ref="github.com/crowdsecurity/cs-cloudflare-worker-bouncer/cmd/crowdsec-cloudflare-worker-bouncer@v${_ver}"
                fi
                _tmpgobin="$(mktemp -d -p /tmp cs-cf-worker-go.XXXXXX)"
                if GOBIN="$_tmpgobin" go install "$_go_pkg_ref" 2>/dev/null; then
                    if [[ -x "$_tmpgobin/crowdsec-cloudflare-worker-bouncer" ]]; then
                        install -m 755 -o root -g root \
                            "$_tmpgobin/crowdsec-cloudflare-worker-bouncer" \
                            "$_CF_WORKER_BOUNCER_BIN"
                        log_success "Built and installed crowdsec-cloudflare-worker-bouncer from source."
                    fi
                else
                    log_warn "Go source build failed for crowdsec-cloudflare-worker-bouncer."
                fi
                rm -rf "$_tmpgobin"
            else
                log_warn "Go toolchain not installed; cannot build from source."
            fi
        fi

    else
        log_info "Cloudflare Workers bouncer binary already present at ${_CF_WORKER_BOUNCER_BIN}."
    fi

    _cs_ensure_cf_worker_unit "$_CF_WORKER_BOUNCER_BIN"
fi

# ---------------------------------------------------------------------------
# PHASE 3: CrowdSec hub collections
# ---------------------------------------------------------------------------
log_info "=== PHASE 3: CrowdSec hub collections ==="

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would install hub collections: crowdsecurity/linux, crowdsecurity/caddy, crowdsecurity/http-cve, Dominic-Wagner/vaultwarden"
else
    cscli collections install crowdsecurity/linux                   || true
    cscli collections install crowdsecurity/caddy                   || true
    cscli collections install crowdsecurity/http-cve                || true
    cscli collections install crowdsecurity/base-http-scenarios     || true
    cscli collections install crowdsecurity/appsec-generic-rules    || true
    cscli collections install crowdsecurity/appsec-virtual-patching || true
    cscli collections install crowdsecurity/whitelist-good-actors   || true
    cscli collections install crowdsecurity/iptables                || true
    cscli collections install Dominic-Wagner/vaultwarden            || true
    log_success "Hub collections installed."
fi

# ---------------------------------------------------------------------------
# PHASE 4: Acquisition config
# ---------------------------------------------------------------------------
log_info "=== PHASE 4: Acquisition config ==="

_project_state_dir="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}"
_acquis_dest="/etc/crowdsec/acquis.d/vaultwarden.yaml"
_acquis_src="${PROJECT_ROOT}/crowdsec/acquis.yaml"

if [[ -f "$_acquis_src" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would write ${_acquis_dest} from ${_acquis_src}"
    else
        mkdir -p /etc/crowdsec/acquis.d
        sed "s|TOKEN_PROJECT_STATE_DIR|${_project_state_dir}|g" \
            "$_acquis_src" \
            | tee "$_acquis_dest" >/dev/null
        log_success "Acquisition config written to ${_acquis_dest}"
    fi
else
    log_warn "crowdsec/acquis.yaml not found in ${PROJECT_ROOT} — skipping acquis config."
fi

# ---------------------------------------------------------------------------
# PHASE 5: Bouncer API key
# ---------------------------------------------------------------------------
log_info "=== PHASE 5: Bouncer API key ==="

_CF_BOUNCER_KEY=""
_CF_BOUNCER_ENV_KEY="CROWDSEC_CF_BOUNCER_API_KEY"

if [[ "$_CF_PROXY_ENABLED" != "true" ]]; then
    log_warn "Skipping bouncer API key generation — CLOUDFLARE_PROXY_ENABLED is not 'true'."
elif [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would generate and register a bouncer API key, write to .env as ${_CF_BOUNCER_ENV_KEY}"
    _CF_BOUNCER_KEY="DRY_RUN_PLACEHOLDER"
else
    _existing_key="${CROWDSEC_CF_BOUNCER_API_KEY:-}"
    if [[ -n "$_existing_key" ]] && cscli bouncers list 2>/dev/null | grep -q 'cloudflare-worker-bouncer' && [[ "$FORCE" != "true" ]]; then
        log_info "Bouncer API key already present in .env — skipping key generation."
        _CF_BOUNCER_KEY="$_existing_key"
    else
        log_info "Generating new bouncer API key..."
        _new_key="$(openssl rand -hex 32)"
        cscli bouncers delete cloudflare-worker-bouncer 2>/dev/null || true
        cscli bouncers add cloudflare-worker-bouncer --key "$_new_key" 2>/dev/null || {
            log_warn "cscli bouncers add failed — CrowdSec LAPI may not be running yet. Key stored in .env for later."
        }
        _CF_BOUNCER_KEY="$_new_key"
        _cs_set_env_var "$_CF_BOUNCER_ENV_KEY" "$_CF_BOUNCER_KEY"
        log_success "Bouncer API key generated and registered. Written to .env as ${_CF_BOUNCER_ENV_KEY}."

        if [[ -t 0 ]]; then
            printf '%s' "${COLOR_RED}"
            cat << 'BOUNCER_BANNER'
  ╔══════════════════════════════════════════════════════════════════╗
  ║   🔑  CROWDSEC CLOUDFLARE WORKERS BOUNCER API KEY — SAVE THIS  ║
  ║   This key is stored in .env as CROWDSEC_CF_BOUNCER_API_KEY    ║
  ╚══════════════════════════════════════════════════════════════════╝
BOUNCER_BANNER
            printf '%s' "${COLOR_RESET}"
            printf '\n  Bouncer API key: %s%s%s\n\n' \
                "${COLOR_RED}${COLOR_GREEN}" "${_CF_BOUNCER_KEY}" "${COLOR_RESET}"
            press_enter_to_continue " Press [Enter] after saving the bouncer API key..."
            clear
        fi
    fi
fi

# ---------------------------------------------------------------------------
# PHASE 6: Cloudflare Workers bouncer config
# ---------------------------------------------------------------------------
log_info "=== PHASE 6: Cloudflare Workers bouncer config ==="

_CF_WORKER_BOUNCER_CONFIG_SRC="${PROJECT_ROOT}/crowdsec/crowdsec-cloudflare-worker-bouncer.yaml.example"
_CF_WORKER_BOUNCER_CONFIG_DEST="/etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml"

if [[ -f "$_CF_WORKER_BOUNCER_CONFIG_SRC" ]]; then
    if [[ "$_CF_PROXY_ENABLED" != "true" ]]; then
        log_warn "Skipping Cloudflare Workers bouncer config write — CLOUDFLARE_PROXY_ENABLED is not 'true'."
    elif [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would write ${_CF_WORKER_BOUNCER_CONFIG_DEST} from ${_CF_WORKER_BOUNCER_CONFIG_SRC}"
    else
        cf_worker_bouncer_token=""
        cloudflare_zone_id=""
        cf_account_id=""
        if [[ "$AUTO_MODE" == "true" ]]; then
            cf_worker_bouncer_token="CHANGE_ME_CF_WORKER_BOUNCER_TOKEN"
            cloudflare_zone_id="CHANGE_ME_CLOUDFLARE_ZONE_ID"
            cf_account_id="CHANGE_ME_CF_ACCOUNT_ID"
            log_warn "Auto mode: Cloudflare values left as placeholders where missing."
            log_warn "Set CrowdSec Cloudflare secrets with: sudo ./edit-secrets.sh rotate <field>"
        else
            log_debug "setup-crowdsec Phase 6: SECRETS_FILE resolved to: ${SECRETS_FILE:-<unset>}"
            cf_worker_bouncer_token=$(decrypt_secret "cf_worker_bouncer_token") || {
                log_error "Failed to read cf_worker_bouncer_token from secrets."
                log_error "Run: sudo ./edit-secrets.sh rotate cf_worker_bouncer_token"
                exit 1
            }
            if [[ -z "$cf_worker_bouncer_token" || "$cf_worker_bouncer_token" == PLACEHOLDER* || "$cf_worker_bouncer_token" == CHANGE_ME* ]]; then
                log_error "cf_worker_bouncer_token is not configured."
                log_error "Run: sudo ./edit-secrets.sh rotate cf_worker_bouncer_token"
                exit 1
            fi
            cloudflare_zone_id=$(decrypt_secret "cloudflare_zone_id") || {
                log_error "Failed to read cloudflare_zone_id from secrets."
                log_error "Run: sudo ./edit-secrets.sh rotate cloudflare_zone_id"
                exit 1
            }
            if [[ -z "$cloudflare_zone_id" || "$cloudflare_zone_id" == PLACEHOLDER* || "$cloudflare_zone_id" == CHANGE_ME* ]]; then
                log_error "cloudflare_zone_id is not configured."
                log_error "Run: sudo ./edit-secrets.sh rotate cloudflare_zone_id"
                exit 1
            fi
            cf_account_id=$(decrypt_secret "cf_account_id") || {
                log_error "Failed to read cf_account_id from secrets."
                log_error "Run: sudo ./edit-secrets.sh rotate cf_account_id"
                exit 1
            }
            if [[ -z "$cf_account_id" || "$cf_account_id" == PLACEHOLDER* || "$cf_account_id" == CHANGE_ME* ]]; then
                log_error "cf_account_id is not configured."
                log_error "Run: sudo ./edit-secrets.sh rotate cf_account_id"
                exit 1
            fi
            cleanup_secrets_environment
        fi

        _cf_free_plan="${CF_FREE_PLAN:-true}"
        if [[ "$_cf_free_plan" == "true" ]]; then
            _only_from_line="  only_include_decisions_from: [\"cscli\", \"crowdsec\"]"
            log_info "Free-plan KV guard enabled: restricting decisions to cscli + crowdsec engine."
            log_info "Set CF_FREE_PLAN=false in .env to disable this restriction."
        else
            _only_from_line="  only_include_decisions_from: []"
        fi

        # Resolve the account email for the account_name field.
        # Falls back to a placeholder if not set in .env.
        _cf_account_email="${CF_ACCOUNT_EMAIL:-CHANGE_ME_CF_ACCOUNT_EMAIL}"

        mkdir -p /etc/crowdsec/bouncers

        _domain_name="${DOMAIN_NAME:-}"
        if [[ -z "$_domain_name" && -n "${DOMAIN:-}" ]]; then
            _domain_name="${DOMAIN#https://}"
            _domain_name="${_domain_name#http://}"
            _domain_name="${_domain_name%%/*}"
            log_info "DOMAIN_NAME not set — derived from DOMAIN: ${_domain_name}"
        fi
        if [[ -z "$_domain_name" ]]; then
            log_error "Neither DOMAIN_NAME nor DOMAIN is set in .env — cannot derive routes_to_protect."
            log_error "Set DOMAIN_NAME=yourdomain.com in .env and re-run."
            exit 1
        fi
        _worker_route="${_domain_name}/*"

        # NOTE on the only_include_decisions_from sed pattern:
        # We match only lines where the YAML key itself starts the line
        # (optional leading whitespace, then the key name).  This prevents
        # comment lines that merely *mention* the key from being replaced,
        # which previously produced a duplicate YAML key that broke the
        # bouncer config parser and the dpkg post-install script.
        sed \
            -e "s|%%CLOUDFLARE_ZONE_ID%%|${cloudflare_zone_id}|g" \
            -e "s|%%CF_ACCOUNT_ID%%|${cf_account_id:-CHANGE_ME_CF_ACCOUNT_ID}|g" \
            -e "s|%%CF_WORKER_BOUNCER_TOKEN%%|${cf_worker_bouncer_token}|g" \
            -e "s|%%CF_ACCOUNT_NAME%%|${_cf_account_email}|g" \
            -e "s|%%CROWDSEC_LAPI_KEY%%|${_CF_BOUNCER_KEY}|g" \
            -e "s|%%WORKER_ROUTE%%|${_worker_route}|g" \
            -e "s|^[[:space:]]*only_include_decisions_from:.*|${_only_from_line}|g" \
            -e "s|lapi_url: http://127\.0\.0\.1:[0-9]*/|lapi_url: http://127.0.0.1:${_LAPI_PORT}/|g" \
            "$_CF_WORKER_BOUNCER_CONFIG_SRC" \
            | grep -v '%%[A-Z_]*%%' \
            | tee "$_CF_WORKER_BOUNCER_CONFIG_DEST" >/dev/null
        chmod 600 "$_CF_WORKER_BOUNCER_CONFIG_DEST"
        log_success "Cloudflare Workers bouncer config written to ${_CF_WORKER_BOUNCER_CONFIG_DEST} (mode 600)."
        log_info "NOTE: The -g auto-config flag is not used — it fails on multi-zone accounts."
        log_info "Config is fully built from secrets.yaml values (zone_id, account_id, token)."

        if [[ "$AUTONOMOUS_MODE" == "true" ]]; then
            log_info "Deploying Workers + KV to Cloudflare in autonomous mode (-S)..."
            if "$_CF_WORKER_BOUNCER_BIN" \
                    -S \
                    -c "$_CF_WORKER_BOUNCER_CONFIG_DEST"; then
                log_success "Autonomous mode deployment complete."
                log_info "Worker route fail mode: manually set to 'Fail Open' in the Cloudflare dashboard"
            else
                log_warn "Autonomous mode deployment reported an error — check config and token permissions."
            fi
        elif _cf_worker_bouncer_service_exists; then
            systemctl enable crowdsec-cloudflare-worker-bouncer || true
            systemctl reset-failed crowdsec-cloudflare-worker-bouncer 2>/dev/null || true
            systemctl restart crowdsec-cloudflare-worker-bouncer || true

            _cf_worker_bouncer_ready=false
            for _i in {1..10}; do
                if systemctl is-active --quiet crowdsec-cloudflare-worker-bouncer; then
                    _cf_worker_bouncer_ready=true
                    break
                fi
                sleep 1
            done

            if [[ "$_cf_worker_bouncer_ready" == "true" ]]; then
                log_success "crowdsec-cloudflare-worker-bouncer is active."
            else
                log_warn "crowdsec-cloudflare-worker-bouncer did not report active within 10s; continuing setup."
            fi
        else
            log_warn "crowdsec-cloudflare-worker-bouncer.service unit not found after install attempt — check logs above."
            log_warn "Once the binary is installed, run: sudo systemctl enable --now crowdsec-cloudflare-worker-bouncer"
        fi
    fi
else
    log_warn "crowdsec-cloudflare-worker-bouncer.yaml.example not found in ${PROJECT_ROOT}/crowdsec — skipping bouncer config write."
    log_warn "Expected: ${_CF_WORKER_BOUNCER_CONFIG_SRC}"
fi

# ---------------------------------------------------------------------------
# PHASE 7: CrowdSec profiles
# ---------------------------------------------------------------------------
log_info "=== PHASE 7: CrowdSec profiles ==="

_PROFILES_SRC="${PROJECT_ROOT}/crowdsec/profiles.yaml"

if [[ -f "$_PROFILES_SRC" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would copy ${_PROFILES_SRC} to /etc/crowdsec/profiles.yaml"
    else
        cp "$_PROFILES_SRC" /etc/crowdsec/profiles.yaml
        log_success "profiles.yaml applied to /etc/crowdsec/profiles.yaml"
    fi
else
    log_info "No custom crowdsec/profiles.yaml found — using CrowdSec defaults."
fi

_cs_wait_for_lapi() {
    local port="${1:-8090}"
    local max_wait=30
    local i=0
    log_info "Waiting for CrowdSec LAPI to be ready on port ${port}..."
    while (( i < max_wait )); do
        if curl -sf --max-time 2 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
            log_success "LAPI is ready on port ${port}."
            return 0
        fi
        sleep 1
        (( i++ ))
    done
    log_warn "LAPI did not respond within ${max_wait}s on port ${port} — bouncer may fail to start."
    return 1
}

# ---------------------------------------------------------------------------
# PHASE 8: Enable and start services
# ---------------------------------------------------------------------------
log_info "=== PHASE 8: Enable and start services ==="

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would reload crowdsec and enable crowdsec-firewall-bouncer"
    if [[ "$AUTONOMOUS_MODE" != "true" ]]; then
        log_info "[DRY RUN] Would enable crowdsec-cloudflare-worker-bouncer (daemon mode)"
    else
        log_info "[DRY RUN] Autonomous mode — no persistent service to enable"
    fi
else
    if systemctl is-active --quiet crowdsec; then
        systemctl reload crowdsec 2>/dev/null || true
    fi

    # Wait for LAPI to accept connections before starting the bouncer.
    # The bouncer exits immediately (and systemd marks it failed) if LAPI
    # isn't ready when it first tries to authenticate.
    _lapi_port_phase8="$(_cs_resolve_lapi_port)"
    _cs_wait_for_lapi "$_lapi_port_phase8" || true

    systemctl reset-failed crowdsec-firewall-bouncer 2>/dev/null || true
    systemctl enable --now crowdsec-firewall-bouncer || true

    _fw_ready=false
    for _i in {1..15}; do
        if systemctl is-active --quiet crowdsec-firewall-bouncer; then
            _fw_ready=true; break
        fi
        sleep 1
    done
    if [[ "$_fw_ready" == "true" ]]; then
        log_success "crowdsec-firewall-bouncer is active."
    else
        log_warn "crowdsec-firewall-bouncer did not report active within 15s — check: sudo journalctl -u crowdsec-firewall-bouncer"
        _fw_journal="$(journalctl -u crowdsec-firewall-bouncer --no-pager -n 15 2>/dev/null || true)"
        if [[ -n "$_fw_journal" ]]; then
            log_warn "Last crowdsec-firewall-bouncer journal entries:"
            while IFS= read -r _fw_line; do
                log_warn "  ${_fw_line}"
            done <<< "$_fw_journal"
        fi
    fi

    if [[ "$_CF_PROXY_ENABLED" != "true" ]]; then
        log_warn "Skipping crowdsec-cloudflare-worker-bouncer enable — CLOUDFLARE_PROXY_ENABLED is not 'true'."
    elif [[ "$AUTONOMOUS_MODE" == "true" ]]; then
        log_info "Autonomous mode active — Cloudflare Workers handle syncing; no persistent daemon needed."
    elif _cf_worker_bouncer_service_exists; then
        systemctl enable --now crowdsec-cloudflare-worker-bouncer \
            || log_error "crowdsec-cloudflare-worker-bouncer failed to start — enforcement is INACTIVE. Run: journalctl -u crowdsec-cloudflare-worker-bouncer -n 30"
        log_success "crowdsec-cloudflare-worker-bouncer enabled and started."
    else
        log_warn "Skipping crowdsec-cloudflare-worker-bouncer enable — service unit not installed yet."
    fi
    log_success "Services enabled."
fi

# ---------------------------------------------------------------------------
# PHASE 9: Admin IP allowlist
# ---------------------------------------------------------------------------
log_info "=== PHASE 9: Admin IP allowlist ==="

_cs_whitelist_dir="/etc/crowdsec/parsers/s02-enrich"
_cs_whitelist_file="${_cs_whitelist_dir}/vaultwarden-admin-allowlist.yaml"
_cs_resolved_ip="$ADMIN_IP"

if [[ -z "$_cs_resolved_ip" ]]; then
    _cs_ssh_src="${SSH_CLIENT:-}"
    if [[ -n "$_cs_ssh_src" ]]; then
        _cs_ssh_ip="${_cs_ssh_src%% *}"
        if [[ "$AUTO_MODE" == "true" ]]; then
            log_info "Auto-detected admin IP from SSH session: ${_cs_ssh_ip}"
            _cs_resolved_ip="$_cs_ssh_ip"
        else
            _cs_prompt_reply=""
            read -r -p "Add SSH client IP (${_cs_ssh_ip}) to CrowdSec allowlist? [Enter=yes, type CIDR to use instead, 'skip' to skip]: " \
                _cs_prompt_reply || true
            case "${_cs_prompt_reply,,}" in
                ""|yes)  _cs_resolved_ip="$_cs_ssh_ip" ;;
                skip|no) _cs_resolved_ip="" ;;
                *)       _cs_resolved_ip="$_cs_prompt_reply" ;;
            esac
        fi
    elif [[ "$AUTO_MODE" != "true" ]]; then
        _cs_prompt_reply=""
        read -r -p "Enter admin IP or CIDR to allowlist in CrowdSec (or press Enter to skip): " \
            _cs_prompt_reply || true
        _cs_resolved_ip="$_cs_prompt_reply"
    fi
fi

if [[ -z "$_cs_resolved_ip" ]]; then
    log_warn "No admin IP provided — CrowdSec admin allowlist not configured."
    log_warn "Re-run with --admin-ip YOUR_IP to add an allowlist entry at any time."
else
    if [[ ! "$_cs_resolved_ip" =~ ^[0-9a-fA-F:./]+$ ]]; then
        log_warn "Ignoring admin IP '${_cs_resolved_ip}': unexpected characters detected."
        log_warn "Provide a plain IPv4/IPv6 address or CIDR (e.g. 203.0.113.42 or 203.0.113.0/24)."
    else
        if [[ "$_cs_resolved_ip" == */* ]]; then
            _cs_yaml_field="cidr"
        else
            _cs_yaml_field="ip"
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would write CrowdSec allowlist to ${_cs_whitelist_file}"
            log_info "[DRY RUN] Would allowlist (${_cs_yaml_field}): ${_cs_resolved_ip}"
        else
            mkdir -p "$_cs_whitelist_dir"
            cat > "$_cs_whitelist_file" <<CSYAML
name: crowdsecurity/whitelists
description: "Admin ${_cs_yaml_field} allowlisted by VaultWarden setup-crowdsec.sh"
whitelist:
  reason: "VaultWarden admin allowlist"
  ${_cs_yaml_field}:
    - "${_cs_resolved_ip}"
CSYAML
            chmod 640 "$_cs_whitelist_file"
            log_success "CrowdSec allowlist written: ${_cs_whitelist_file}"
            log_success "Allowlisted (${_cs_yaml_field}): ${_cs_resolved_ip}"

            if systemctl is-active crowdsec >/dev/null 2>&1; then
                systemctl reload crowdsec 2>/dev/null \
                    || systemctl restart crowdsec 2>/dev/null \
                    || log_warn "CrowdSec reload failed — restart manually: sudo systemctl restart crowdsec"
                log_success "CrowdSec reloaded — allowlist is active."
            else
                log_info "CrowdSec is not running — allowlist will take effect on next start."
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
_lapi_port_summary="$(_cs_resolve_lapi_port)"
log_info ""
log_info "════════════════════════════════════════════════════════"
log_info " CrowdSec setup complete"
log_info "════════════════════════════════════════════════════════"
log_info ""
log_info "── SERVICE STATUS ──────────────────────────────────────"
log_info "  Check all CrowdSec services:"
log_info "    sudo systemctl status crowdsec crowdsec-firewall-bouncer \\"
log_info "      crowdsec-cloudflare-worker-bouncer --no-pager -l"
log_info ""
log_info "  Tail live logs:"
log_info "    sudo journalctl -fu crowdsec"
log_info "    sudo journalctl -fu crowdsec-firewall-bouncer"
log_info "    sudo journalctl -fu crowdsec-cloudflare-worker-bouncer"
log_info ""
log_info "── CROWDSEC ENGINE ─────────────────────────────────────"
log_info "  LAPI port : ${_lapi_port_summary}"
log_info ""
log_info "  Registered bouncers (both should appear):"
log_info "    sudo cscli bouncers list"
log_info ""
log_info "  Active bans and alerts:"
log_info "    sudo cscli decisions list"
log_info "    sudo cscli alerts list"
log_info ""
log_info "  Installed collections and parsers:"
log_info "    sudo cscli collections list"
log_info "    sudo cscli parsers list"
log_info ""
log_info "  Engine metrics (scenarios triggered, parsed lines, etc.):"
log_info "    sudo cscli metrics"
log_info ""
log_info "── FIREWALL BOUNCER ────────────────────────────────────"
log_info "  Host-level blocks (INPUT chain):"
log_info "    sudo iptables -L INPUT -n --line-numbers | grep -i crowdsec"
log_info ""
log_info "  Container blocks (DOCKER-USER chain):"
log_info "    sudo iptables -L DOCKER-USER -n --line-numbers | grep -i crowdsec"
log_info ""
log_info "  ipset ban lists (populated by firewall bouncer):"
log_info "    sudo ipset list | grep -E '^(Name|crowdsec)'"
log_info ""
if [[ "$_CF_PROXY_ENABLED" == "true" ]]; then
    log_info "── CLOUDFLARE WORKERS BOUNCER ──────────────────────────"
    if [[ "$AUTONOMOUS_MODE" == "true" ]]; then
        log_info "  Deployed in autonomous mode — no persistent daemon."
        log_info "  The Cloudflare Worker runs at the edge; decisions sync via KV."
    else
        log_info "  Daemon sync status:"
        log_info "    sudo systemctl status crowdsec-cloudflare-worker-bouncer --no-pager"
        log_info "    sudo journalctl -u crowdsec-cloudflare-worker-bouncer -n 50 --no-pager"
    fi
    log_info ""
    log_info "  Decisions pushed to Cloudflare KV (free plan: up to 1 K writes/day):"
    log_info "    sudo cscli decisions list"
    log_info "    # Active bans appear in: Cloudflare dashboard -> Workers & Pages"
    log_info "    # -> KV -> crowdsec-* namespace"
    log_info ""
    log_info "  IMPORTANT — set Worker route fail mode to 'Fail Open':"
    log_info "    Cloudflare dashboard -> Websites -> <your domain>"
    log_info "    -> Workers Routes -> Edit -> Failure mode: Fail open"
    log_info "    (prevents outage if the Worker errors)"
    log_info ""
    log_info "  Verify the Worker is deployed and routing correctly:"
    log_info "    Cloudflare dashboard -> Workers & Pages -> crowdsec-cloudflare-worker"
    log_info "    -> Triggers -> confirm route: ${_worker_route:-<domain>/*}"
    log_info ""
fi
log_info "── ROTATING CLOUDFLARE CREDENTIALS ────────────────────"
log_info "  Credentials live in secrets (not .env)."
log_info "  To rotate any value and re-apply:"
log_info "    sudo ./edit-secrets.sh rotate cf_worker_bouncer_token"
log_info "    sudo ./edit-secrets.sh rotate cloudflare_zone_id"
log_info "    sudo ./edit-secrets.sh rotate cf_account_id"
log_info "    sudo ./utilities/setup-crowdsec.sh --force"
log_info ""
log_info "════════════════════════════════════════════════════════"
