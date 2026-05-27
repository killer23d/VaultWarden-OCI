#!/usr/bin/env bash
# utilities/setup-crowdsec.sh — Installs and configures CrowdSec and the
# Cloudflare *Workers* bouncer (crowdsec-cloudflare-worker-bouncer) for
# VaultWarden-OCI.
#
# The legacy crowdsec-cloudflare-worker-bouncer is no longer actively supported by
# CrowdSec due to Cloudflare API rate-limit changes.  This script uses the
# recommended replacement: crowdsec-cloudflare-worker-bouncer, which leverages
# Cloudflare Workers + Workers KV storage for decision enforcement.
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

if [[ "${EUID}" -ne 0 ]]; then
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
for _lib in log.sh config.sh common.sh storage.sh; do
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
    COLOR_RED=$'\033[0;31m'
    COLOR_GREEN=$'\033[0;32m'
    # shellcheck disable=SC2034
    COLOR_YELLOW=$'\033[0;33m'
    # shellcheck disable=SC2034
    COLOR_CYAN=$'\033[0;36m'
    COLOR_RESET=$'\033[0m'
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

# Read a token from a flat secret file, rejecting placeholder values.
_cs_read_secret_file() {
    local path="$1"
    [[ -f "$path" && -r "$path" ]] || return 0
    local val
    IFS= read -r val < "$path" || true
    val="${val#${val%%[![:space:]]*}}"
    val="${val%${val##*[![:space:]]}}"
    if [[ -n "$val" && "$val" != CHANGE_ME* && "$val" != PLACEHOLDER* ]]; then
        printf '%s' "$val"
    fi
}

# ---------------------------------------------------------------------------
# Read the currently configured LAPI port from config.yaml.
# Prints the port number; defaults to 8080 if not found.
# ---------------------------------------------------------------------------
_cs_resolve_lapi_port() {
    grep -oP '(?<=listen_uri:\s{0,10}127\.0\.0\.1:)\d+' \
        /etc/crowdsec/config.yaml 2>/dev/null \
        | head -1 \
        || echo "8080"
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
# Rewrite all CrowdSec config files from old_port → new_port atomically.
# Files updated:
#   /etc/crowdsec/config.yaml
#   /etc/crowdsec/local_api_credentials.yaml
#   /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml   (if present)
#   /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml (if present)
# ---------------------------------------------------------------------------
_cs_fix_port_conflict() {
    local old_port="$1"
    local new_port="$2"

    log_info "Auto-fixing LAPI port conflict: ${old_port} → ${new_port}"

    local _f
    # config.yaml
    _f="/etc/crowdsec/config.yaml"
    if [[ -f "$_f" ]]; then
        sed -i "s|listen_uri: 127.0.0.1:${old_port}|listen_uri: 127.0.0.1:${new_port}|g" "$_f"
        log_info "  Updated ${_f}"
    fi

    # local_api_credentials.yaml
    _f="/etc/crowdsec/local_api_credentials.yaml"
    if [[ -f "$_f" ]]; then
        sed -i "s|url: http://127.0.0.1:${old_port}|url: http://127.0.0.1:${new_port}|g" "$_f"
        log_info "  Updated ${_f}"
    fi

    # firewall bouncer
    _f="/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"
    if [[ -f "$_f" ]]; then
        sed -i "s|api_url: http://127.0.0.1:${old_port}/|api_url: http://127.0.0.1:${new_port}/|g" "$_f"
        log_info "  Updated ${_f}"
    fi

    # cloudflare worker bouncer
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
# Emits actionable ERROR lines identifying what process owns a given port.
# Usage: _cs_diagnose_port 8080
# ---------------------------------------------------------------------------
_cs_diagnose_port() {
    local port="$1"
    local info=""

    # Try ss first (iproute2, always present on Ubuntu 20.04+)
    if command -v ss >/dev/null 2>&1; then
        info="$(ss -tlnp "sport = :${port}" 2>/dev/null | grep -v '^Netid' || true)"
    fi

    # Fall back to lsof if ss gave nothing useful
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
# On port conflict: finds a free port, rewrites all configs, retries once.
# Returns 0 if the service becomes active, 1 if irrecoverably failed.
# ---------------------------------------------------------------------------
_cs_start_service() {
    # Reset any previous failed state so systemctl start has a clean slate.
    systemctl reset-failed crowdsec 2>/dev/null || true

    if systemctl enable --now crowdsec 2>/dev/null; then
        local _i
        for _i in {1..5}; do
            if systemctl is-active --quiet crowdsec; then
                return 0
            fi
            sleep 1
        done
    fi

    # Service did not come up — check whether the configured LAPI port is taken.
    local _lapi_port
    _lapi_port="$(_cs_resolve_lapi_port)"

    if ss -tlnp 2>/dev/null | grep -q ":${_lapi_port}[[:space:]]"; then
        log_warn "Port ${_lapi_port} is occupied — attempting automatic port reassignment."
        _cs_diagnose_port "${_lapi_port}"

        local _new_port
        _new_port="$(_cs_find_free_port 8090)"
        _cs_fix_port_conflict "${_lapi_port}" "${_new_port}"

        # Retry the service after the port rewrite.
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

        # Still not up after port fix — emit full diagnostics and give up.
        log_error "CrowdSec service failed to start even after port reassignment to ${_new_port}."
    else
        log_error "CrowdSec service failed to start."
    fi

    # Emit systemctl status for all failure paths.
    log_error "systemctl status crowdsec:"
    systemctl status crowdsec --no-pager -l 2>&1 | head -30 | while IFS= read -r _l; do
        log_error "  ${_l}"
    done
    log_error "Full journal: sudo journalctl -xeu crowdsec --no-pager | tail -50"
    return 1
}

# ---------------------------------------------------------------------------
# Reset all CrowdSec components installed by a previous run.
# Called unconditionally when --force is active so every subsequent phase
# executes as on a first install.
#   1. Deletes LAPI bouncer registrations (best-effort, while LAPI may still be up).
#   2. Stops and disables all CrowdSec-related systemd services.
#   3. Removes bouncer config files that the upcoming phases will regenerate.
#   4. Clears the auto-generated LAPI key from .env so Phase 5 issues a fresh one.
#      User-supplied values (CF_WORKER_BOUNCER_TOKEN, CLOUDFLARE_ZONE_ID,
#      CF_ACCOUNT_ID) are left intact to avoid unnecessary re-prompting.
# ---------------------------------------------------------------------------
_cs_reset_components() {
    log_info "=== PHASE 0: Resetting installed CrowdSec components (--force) ==="

    # Delete LAPI bouncer registrations while CrowdSec may still be running.
    # These calls are best-effort; apt reinstall (Phase 1) resets the DB anyway.
    if command -v cscli >/dev/null 2>&1; then
        cscli bouncers delete cloudflare-worker-bouncer 2>/dev/null || true
        cscli bouncers delete firewall-bouncer          2>/dev/null || true
        log_info "Cleared existing LAPI bouncer registrations (best-effort)."
    fi

    # Stop and disable services.  Order: bouncers first, then the engine.
    local _svc
    for _svc in crowdsec-cloudflare-worker-bouncer crowdsec-firewall-bouncer crowdsec; do
        if systemctl is-active  --quiet "$_svc" 2>/dev/null || \
           systemctl is-enabled --quiet "$_svc" 2>/dev/null; then
            systemctl disable --now "$_svc" 2>/dev/null || true
            log_info "Stopped and disabled: ${_svc}"
        fi
    done

    # Remove bouncer config files that each phase will regenerate.
    rm -f /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml 2>/dev/null || true
    rm -f /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml            2>/dev/null || true

    # Clear the auto-generated LAPI bouncer key so Phase 5 issues a fresh one.
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
AUTONOMOUS_MODE=false  # use Cloudflare Workers autonomous mode (-S flag)
# When USE_LATEST=true the script queries live upstream for the current latest
# release.  By default the pinned versions below are used for reproducibility.
USE_LATEST=false
ADMIN_IP=""

# Dependency version pins — leave blank to resolve latest at runtime.
CROWDSEC_VERSION="${CROWDSEC_VERSION:-}"
CF_WORKER_BOUNCER_VERSION="${CF_WORKER_BOUNCER_VERSION:-}"

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
            cat <<'HELP'
usage: sudo ./utilities/setup-crowdsec.sh [OPTIONS]

  --auto               Non-interactive: never prompt.
  --dry-run            Print what would happen; make no changes.
  --force              Re-run all phases even if already applied.
  --use-latest         Override version pins and use the current live upstream
                       release of each component.  By default the pinned
                       versions in CROWDSEC_VERSION / CF_WORKER_BOUNCER_VERSION
                       are used for reproducibility.
  --autonomous         Deploy the Workers bouncer in autonomous mode (-S flag).
                       The Go process runs once to deploy Workers + KV into
                       Cloudflare, then exits — no persistent systemd daemon is
                       needed.  Decisions are synced by a Cloudflare scheduled
                       Worker every 5 minutes.
                       Default: daemon mode (systemd service runs continuously).
  --admin-ip IP|CIDR   Add this IP address or CIDR to the CrowdSec admin
                       allowlist (e.g. 203.0.113.42 or 203.0.113.0/24).
                       When omitted, the script auto-detects your SSH client IP
                       from SSH_CLIENT and prompts for confirmation in
                       interactive mode.

Environment variables (set in .env or exported before running):
  CLOUDFLARE_PROXY_ENABLED   Set to 'true' to enable the Cloudflare bouncer.
  CLOUDFLARE_ZONE_ID         Your Cloudflare Zone ID.
  CF_ACCOUNT_ID              Your Cloudflare Account ID.
  CF_WORKER_BOUNCER_TOKEN    Cloudflare API token for the Workers bouncer.
                             Required permissions:
                               Account › Workers KV Storage : Edit
                               Account › Workers Scripts    : Edit
                               Account › Account Settings   : Read
                               Account › Turnstile          : Edit
                               Account › D1                 : Edit
                               User    › User Details       : Read
                               Zone    › DNS                : Read
                               Zone    › Workers Routes     : Edit
                               Zone    › Zone               : Read
  CF_FREE_PLAN               Set to 'false' to disable the free-plan KV write
                             guard (only_include_decisions_from restriction).
                             Default: 'true' (guard enabled).
  CROWDSEC_VERSION           Pin a specific CrowdSec version (e.g. "1.6.3").
  CF_WORKER_BOUNCER_VERSION  Pin a specific Workers bouncer version (e.g. "v0.1.0").
HELP
            exit 0 ;;
        *)
            log_error "Unknown flag: $1"
            exit 1 ;;
    esac
done

if [[ "$AUTO_MODE" == "true" ]]; then
    log_info "Running in non-interactive (auto) mode."
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
    systemctl list-unit-files crowdsec-cloudflare-worker-bouncer.service 2>/dev/null \
        | grep -q 'crowdsec-cloudflare-worker-bouncer.service'
}

# ---------------------------------------------------------------------------
# Write the crowdsec-cloudflare-worker-bouncer systemd unit if:
#   - The binary exists at _CF_WORKER_BOUNCER_BIN
#   - The unit file is not already installed
#   - Daemon mode is in use (AUTONOMOUS_MODE != true)
# Safe to call on every run; idempotent.
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

# CrowdSec post-install currently invokes `cscli setup unattended`, which calls
# `systemctl show ...` and can fail on legacy multiline ExecStart payloads.
# Normalize older deployed vaultwarden-notify-failure units in-place before any
# apt/dpkg action so upgrades recover cleanly on already-deployed hosts.
_legacy_notify_unit="/etc/systemd/system/vaultwarden-notify-failure.service"
if [[ -f "$_legacy_notify_unit" ]] && grep -q "Review failed units with:" "$_legacy_notify_unit" 2>/dev/null; then
    log_warn "Detected legacy vaultwarden-notify-failure.service payload; normalizing for CrowdSec compatibility."
    sed -i 's/Review failed units with:\\n  systemctl --failed\\n/Run: systemctl --failed/g' "$_legacy_notify_unit" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
fi

if command -v cscli >/dev/null 2>&1 && [[ "$FORCE" != "true" ]]; then
    log_info "CrowdSec already installed — skipping base install."
elif [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would install crowdsec and crowdsec-firewall-bouncer-iptables"
else
    log_info "Adding CrowdSec repository..."
    curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash

    _cs_pkg="crowdsec"
    if [[ "$USE_LATEST" != "true" && -n "$CROWDSEC_VERSION" ]]; then
        _cs_pkg="crowdsec=${CROWDSEC_VERSION}"
        log_info "CrowdSec version pinned: ${CROWDSEC_VERSION}"
    else
        log_info "CrowdSec version: installing latest from packagecloud repository"
    fi

    log_info "Installing CrowdSec engine package first..."
    _fw_pkg="crowdsec-firewall-bouncer-iptables"
    if iptables -V 2>/dev/null | grep -q 'nf_tables'; then
        _fw_pkg="crowdsec-firewall-bouncer-nftables"
        log_info "nftables detected — installing crowdsec-firewall-bouncer-nftables."
    else
        log_info "iptables detected — installing crowdsec-firewall-bouncer-iptables."
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$_cs_pkg"
    log_info "Installing CrowdSec firewall bouncer package..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$_fw_pkg"
fi

# Start/restart CrowdSec regardless of whether it was freshly installed or
# already present.  _cs_start_service auto-resolves port conflicts and retries
# before giving up.
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
# Resolve the current LAPI port so generated configs stay in sync.
_LAPI_PORT="$(_cs_resolve_lapi_port)"

if [[ -f "$_FW_BOUNCER_CONFIG" ]] && [[ "$FORCE" != "true" ]]; then
    log_info "Firewall bouncer config already present — checking DOCKER-USER chain."
    # Ensure DOCKER-USER is in the chain list even if config pre-existed
    if ! grep -q 'DOCKER-USER' "$_FW_BOUNCER_CONFIG"; then
        log_info "Adding DOCKER-USER chain to existing firewall bouncer config..."
        sed -i '/iptables_chains:/,/^[^ ]/{/- INPUT/a\  - DOCKER-USER
}' "$_FW_BOUNCER_CONFIG" 2>/dev/null || true
        systemctl restart crowdsec-firewall-bouncer 2>/dev/null || true
        log_success "DOCKER-USER chain added to firewall bouncer config."
    else
        log_info "DOCKER-USER chain already present in firewall bouncer config."
    fi
elif [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would write firewall bouncer config with DOCKER-USER chain"
else
    # Register the firewall bouncer key in CrowdSec LAPI
    if ! cscli bouncers list 2>/dev/null | grep -q 'firewall-bouncer'; then
        log_info "Registering firewall bouncer in CrowdSec LAPI..."
        _fw_key="$(openssl rand -hex 32)"
        cscli bouncers add crowdsecurity/firewall-bouncer --key "$_fw_key" 2>/dev/null || true
    else
        _fw_key="$(grep 'api_key:' "$_FW_BOUNCER_CONFIG" 2>/dev/null | awk '{print $2}' | head -1 || true)"
    fi

    # Write config with DOCKER-USER chain included per official docs
    # Ref: https://docs.crowdsec.net/u/bouncers/firewall
    # "If you are using a dockerized application and allow remote connections
    #  to the exposed port, you need to add the DOCKER-USER chain."
    cat > "$_FW_BOUNCER_CONFIG" <<FWCONFIG
mode: iptables
update_frequency: 10s
log_mode: stdout
log_level: info
api_url: http://127.0.0.1:${_LAPI_PORT}/
api_key: ${_fw_key:-CHANGE_ME_FW_BOUNCER_KEY}

# Block community list + local decisions at the OS level (no quota cost).
# origins is intentionally empty — accept ALL decision sources including
# the CrowdSec community blocklist (CAPI).  The Workers bouncer separately
# uses only_include_decisions_from: ["cscli","crowdsec"] to stay within
# the Cloudflare free-plan KV write quota.
origins: []

# iptables chains: INPUT for host-level traffic; DOCKER-USER for traffic
# destined to Docker containers (Caddy/Vaultwarden).  Without DOCKER-USER,
# Docker bypasses INPUT and community-list bans do not reach containers.
# Ref: https://docs.crowdsec.net/u/bouncers/firewall#iptables_chains
iptables_chains:
  - INPUT
  - DOCKER-USER

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
    log_info "[DRY RUN] Would install crowdsec-cloudflare-worker-bouncer (apt → tarball → go source fallback)"
else
    # Register the bouncer API key in CrowdSec LAPI.
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
            log_info "Attempting apt install of crowdsec-cloudflare-worker-bouncer..."
            if DEBIAN_FRONTEND=noninteractive apt-get install -y crowdsec-cloudflare-worker-bouncer 2>/dev/null; then
                log_success "Installed crowdsec-cloudflare-worker-bouncer via apt."
                _installed_via_deb=true
            else
                log_warn "apt install failed — falling back to GitHub release tarball."
            fi
        fi

        if [[ "$_installed_via_deb" == "false" && -n "$_arch" ]]; then
            if [[ "$USE_LATEST" != "true" && -n "$CF_WORKER_BOUNCER_VERSION" ]]; then
                _gh_api="https://api.github.com/repos/crowdsecurity/cs-cloudflare-worker-bouncer/releases/tags/${CF_WORKER_BOUNCER_VERSION}"
                log_info "CF Workers bouncer version pinned: ${CF_WORKER_BOUNCER_VERSION}"
            else
                _gh_api="https://api.github.com/repos/crowdsecurity/cs-cloudflare-worker-bouncer/releases/latest"
                log_info "CF Workers bouncer version: resolving latest from GitHub"
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

        # Last resort: Go source build.
        if [[ -n "$_arch" && ! -x "$_CF_WORKER_BOUNCER_BIN" ]]; then
            if command -v go >/dev/null 2>&1; then
                log_info "Attempting Go source build for crowdsec-cloudflare-worker-bouncer..."
                if [[ "$USE_LATEST" != "true" && -n "$CF_WORKER_BOUNCER_VERSION" ]]; then
                    _go_pkg_ref="github.com/crowdsecurity/cs-cloudflare-worker-bouncer/cmd/crowdsec-cloudflare-worker-bouncer@${CF_WORKER_BOUNCER_VERSION}"
                else
                    _go_pkg_ref="github.com/crowdsecurity/cs-cloudflare-worker-bouncer/cmd/crowdsec-cloudflare-worker-bouncer@latest"
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
                log_warn "Install Go, then run:"
                log_warn "  GOBIN=/tmp/cs-cf-go go install github.com/crowdsecurity/cs-cloudflare-worker-bouncer/cmd/crowdsec-cloudflare-worker-bouncer@latest"
            fi
        fi

    else
        log_info "Cloudflare Workers bouncer binary already present at ${_CF_WORKER_BOUNCER_BIN}."
    fi

    # FIX: Ensure the systemd unit is written unconditionally after any install
    # path — including re-runs where the binary was installed in a prior
    # invocation (_CF_WORKER_BOUNCER_NEEDS_INSTALL=false).  Previously the unit
    # was only written inside the NEEDS_INSTALL block, causing Phase 8 to emit
    # "service unit not installed yet" on every subsequent run.
    _cs_ensure_cf_worker_unit "$_CF_WORKER_BOUNCER_BIN"
fi

# ---------------------------------------------------------------------------
# PHASE 3: CrowdSec hub collections
# ---------------------------------------------------------------------------
log_info "=== PHASE 3: CrowdSec hub collections ==="

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would install hub collections: crowdsecurity/linux, crowdsecurity/caddy, crowdsecurity/http-cve, Dominic-Wagner/vaultwarden"
else
    cscli collections install crowdsecurity/linux          || true
    cscli collections install crowdsecurity/caddy          || true
    cscli collections install crowdsecurity/http-cve       || true
    cscli collections install Dominic-Wagner/vaultwarden   || true
    log_success "Hub collections installed."
fi

# ---------------------------------------------------------------------------
# PHASE 4: Acquisition config
# ---------------------------------------------------------------------------
log_info "=== PHASE 4: Acquisition config ==="

_project_state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
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
            clear
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
            printf '%s!!! PRESS ENTER AFTER SAVING THE BOUNCER API KEY !!!%s\n' \
                "${COLOR_RED}" "${COLOR_RESET}"
            read -r
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
        _cf_zone_id="${CLOUDFLARE_ZONE_ID:-}"
        _cf_account_id="${CF_ACCOUNT_ID:-}"
        _CF_WORKER_TOKEN=""

        if [[ "$AUTO_MODE" == "true" ]]; then
            _cf_zone_id="${_cf_zone_id:-CHANGE_ME_CF_ZONE_ID}"
            _cf_account_id="${_cf_account_id:-CHANGE_ME_CF_ACCOUNT_ID}"
            _CF_WORKER_TOKEN="CHANGE_ME_CF_WORKER_BOUNCER_TOKEN"
            log_warn "Auto mode: Cloudflare values left as placeholders where missing."
            log_warn "Set CF_WORKER_BOUNCER_TOKEN in .env then re-run: sudo ./utilities/setup-crowdsec.sh --force"
        else
            # ------------------------------------------------------------------
            # Resolve the Worker API token.
            # Primary source: CF_WORKER_BOUNCER_TOKEN in .env.
            # One-time migration: if the token was stored as a flat secret file
            # from a previous install, read it and persist it to .env so this
            # and all future runs use a single source of truth.
            # ------------------------------------------------------------------
            _env_token="${CF_WORKER_BOUNCER_TOKEN:-}"
            if [[ -n "$_env_token" && "$_env_token" != CHANGE_ME* && "$_env_token" != PLACEHOLDER* ]]; then
                _CF_WORKER_TOKEN="$_env_token"
                log_success "CF_WORKER_BOUNCER_TOKEN already set in .env — skipping prompt."
            fi

            if [[ -z "$_CF_WORKER_TOKEN" ]]; then
                _mig_token=""
                _mig_src=""
                for _mig_path in \
                    "${_project_state_dir}/secrets/.docker_secrets/cf_worker_bouncer_token" \
                    "${PROJECT_ROOT}/secrets/.docker_secrets/cf_worker_bouncer_token"; do
                    _mig_token="$(_cs_read_secret_file "$_mig_path")"
                    if [[ -n "$_mig_token" ]]; then
                        _mig_src="$_mig_path"
                        break
                    fi
                done
                if [[ -n "$_mig_token" ]]; then
                    _CF_WORKER_TOKEN="$_mig_token"
                    _cs_set_env_var "CF_WORKER_BOUNCER_TOKEN" "$_CF_WORKER_TOKEN"
                    log_success "Migrated CF_WORKER_BOUNCER_TOKEN from ${_mig_src} to .env."
                fi
                unset _mig_token _mig_src _mig_path
            fi

            # ------------------------------------------------------------------
            # Only prompt for values that are genuinely missing.
            # Values already set in .env / environment are accepted as-is and
            # the corresponding prompts are skipped entirely.
            # ------------------------------------------------------------------
            if [[ -z "$_CF_WORKER_TOKEN" ]]; then
                log_info ""
                log_info "══════════════════════════════════════════════════════════"
                log_info " Cloudflare API token required by CrowdSec Workers bouncer"
                log_info "══════════════════════════════════════════════════════════"
                log_info " Required permissions:"
                log_info "   Account › Workers KV Storage : Edit"
                log_info "   Account › Workers Scripts    : Edit"
                log_info "   Account › Account Settings   : Read"
                log_info "   Account › Turnstile          : Edit"
                log_info "   Account › D1                 : Edit"
                log_info "   User    › User Details       : Read"
                log_info "   Zone    › DNS                : Read"
                log_info "   Zone    › Workers Routes     : Edit"
                log_info "   Zone    › Zone               : Read"
                log_info " Create at: https://dash.cloudflare.com/profile/api-tokens"
                log_info " (Use 'My Profile' → API Tokens, NOT Account API Tokens)"
                log_info "══════════════════════════════════════════════════════════"

                # Prompt for Zone ID only when not already set.
                if [[ -z "$_cf_zone_id" ]]; then
                    while [[ -z "$_cf_zone_id" ]]; do
                        read -r -p "Enter CLOUDFLARE_ZONE_ID: " _cf_zone_id
                        [[ -z "$_cf_zone_id" ]] && log_warn "CLOUDFLARE_ZONE_ID cannot be empty."
                    done
                else
                    log_info "CLOUDFLARE_ZONE_ID already set — skipping prompt."
                fi

                # Prompt for Account ID only when not already set.
                if [[ -z "$_cf_account_id" ]]; then
                    read -r -p "Enter CF_ACCOUNT_ID (optional, press Enter to skip): " _cf_account_id
                else
                    log_info "CF_ACCOUNT_ID already set — skipping prompt."
                fi

                while [[ -z "$_CF_WORKER_TOKEN" ]]; do
                    read -r -s -p "Enter Cloudflare Workers API token (input hidden): " _CF_WORKER_TOKEN
                    echo ""
                    if [[ -z "$_CF_WORKER_TOKEN" ]]; then
                        log_warn "Token cannot be empty. Press Ctrl+C to skip and configure later."
                    fi
                done
                log_success "Cloudflare Workers API token accepted."
                # Persist to .env so subsequent runs skip the prompt entirely.
                _cs_set_env_var "CF_WORKER_BOUNCER_TOKEN" "$_CF_WORKER_TOKEN"
                log_success "CF_WORKER_BOUNCER_TOKEN saved to .env."
            else
                # Token already resolved — still log if Zone/Account IDs are set.
                if [[ -n "$_cf_zone_id" ]]; then
                    log_info "CLOUDFLARE_ZONE_ID already set — skipping prompt."
                fi
                if [[ -n "$_cf_account_id" ]]; then
                    log_info "CF_ACCOUNT_ID already set — skipping prompt."
                fi
            fi

            _cs_set_env_var "CLOUDFLARE_ZONE_ID" "$_cf_zone_id"
            [[ -n "$_cf_account_id" ]] && _cs_set_env_var "CF_ACCOUNT_ID" "$_cf_account_id"
        fi

        # Determine free-plan KV write guard setting.
        _cf_free_plan="${CF_FREE_PLAN:-true}"
        if [[ "$_cf_free_plan" == "true" ]]; then
            _only_from_line="  only_include_decisions_from: [\"cscli\", \"crowdsec\"]"
            log_info "Free-plan KV guard enabled: restricting decisions to cscli + crowdsec engine."
            log_info "Set CF_FREE_PLAN=false in .env to disable this restriction."
        else
            _only_from_line="  only_include_decisions_from: []"
        fi

        mkdir -p /etc/crowdsec/bouncers
        sed \
            -e "s|TOKEN_CF_ZONE_ID|${_cf_zone_id}|g" \
            -e "s|TOKEN_CF_ACCOUNT_ID|${_cf_account_id:-CHANGE_ME_CF_ACCOUNT_ID}|g" \
            -e "s|TOKEN_CF_WORKER_BOUNCER_TOKEN|${_CF_WORKER_TOKEN}|g" \
            -e "s|CHANGE_ME_BOUNCER_KEY|${_CF_BOUNCER_KEY}|g" \
            -e "s|.*only_include_decisions_from:.*|${_only_from_line}|g" \
            "$_CF_WORKER_BOUNCER_CONFIG_SRC" \
            | tee "$_CF_WORKER_BOUNCER_CONFIG_DEST" >/dev/null
        chmod 600 "$_CF_WORKER_BOUNCER_CONFIG_DEST"
        log_success "Cloudflare Workers bouncer config written to ${_CF_WORKER_BOUNCER_CONFIG_DEST} (mode 600)."

        # FIX: Auto-generate the full Cloudflare config section from the token.
        # Capture stderr so failures produce actionable diagnostics instead of
        # silently swallowing the error.  Only rewrite lapi_key / chmod when the
        # -g call actually succeeds (exit code 0).
        if [[ -x "$_CF_WORKER_BOUNCER_BIN" && -n "$_CF_WORKER_TOKEN" && "$_CF_WORKER_TOKEN" != CHANGE_ME* ]]; then
            log_info "Auto-generating Cloudflare account/zone config from token..."
            _autocfg_err="$(
                "$_CF_WORKER_BOUNCER_BIN" \
                    -g "$_CF_WORKER_TOKEN" \
                    -o "$_CF_WORKER_BOUNCER_CONFIG_DEST" 2>&1 >/dev/null
            )" && _autocfg_ok=true || _autocfg_ok=false

            if [[ "$_autocfg_ok" == "true" ]]; then
                log_success "Auto-config generation succeeded."
                # Re-apply the lapi_key which the -g helper may overwrite.
                if [[ -n "$_CF_BOUNCER_KEY" ]]; then
                    sed -i "s|lapi_key:.*|lapi_key: ${_CF_BOUNCER_KEY}|" "$_CF_WORKER_BOUNCER_CONFIG_DEST" || true
                fi
                chmod 600 "$_CF_WORKER_BOUNCER_CONFIG_DEST"
            else
                log_warn "Auto-config generation failed — the config written in Phase 6 remains active."
                log_warn "Common causes: token lacks required permissions, or the binary does not support -g."
                if [[ -n "$_autocfg_err" ]]; then
                    log_warn "Error output from bouncer -g:"
                    while IFS= read -r _err_line; do
                        log_warn "  ${_err_line}"
                    done <<< "$_autocfg_err"
                fi
                log_warn "Review and correct: ${_CF_WORKER_BOUNCER_CONFIG_DEST}"
                log_warn "Required token permissions: Account › Workers KV Storage:Edit, Workers Scripts:Edit,"
                log_warn "  Account Settings:Read, Turnstile:Edit, D1:Edit; Zone › DNS:Read, Workers Routes:Edit, Zone:Read"
            fi
        fi

        if [[ "$AUTONOMOUS_MODE" == "true" ]]; then
            log_info "Deploying Workers + KV to Cloudflare in autonomous mode (-S)..."
            if "$_CF_WORKER_BOUNCER_BIN" \
                    -S \
                    -c "$_CF_WORKER_BOUNCER_CONFIG_DEST"; then
                log_success "Autonomous mode deployment complete."
                log_info "Worker route fail mode: manually set to 'Fail Open' in the Cloudflare dashboard"
                log_info "  Dashboard → Website → Worker Routes → Edit → Request limit failure mode → Fail open"
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
    # CrowdSec was already started (or failed with an error) in Phase 1.
    # Only reload here if it is currently active.
    if systemctl is-active --quiet crowdsec; then
        systemctl reload crowdsec 2>/dev/null || true
    fi
    systemctl enable --now crowdsec-firewall-bouncer || true

    _fw_ready=false
    for _i in {1..10}; do
        if systemctl is-active --quiet crowdsec-firewall-bouncer; then
            _fw_ready=true; break
        fi
        sleep 1
    done
    if [[ "$_fw_ready" == "true" ]]; then
        log_success "crowdsec-firewall-bouncer is active."
    else
        log_warn "crowdsec-firewall-bouncer did not report active within 10s — check: sudo journalctl -u crowdsec-firewall-bouncer"
    fi

    if [[ "$_CF_PROXY_ENABLED" != "true" ]]; then
        log_warn "Skipping crowdsec-cloudflare-worker-bouncer enable — CLOUDFLARE_PROXY_ENABLED is not 'true'."
    elif [[ "$AUTONOMOUS_MODE" == "true" ]]; then
        log_info "Autonomous mode active — Cloudflare Workers handle syncing; no persistent daemon needed."
    elif _cf_worker_bouncer_service_exists; then
        systemctl enable --now crowdsec-cloudflare-worker-bouncer || true
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
log_info ""
log_info "════════════════════════════════════════════════════════"
log_info " CrowdSec installation complete"
log_info "════════════════════════════════════════════════════════"
log_info "Next steps:"
log_info "  1. All Cloudflare credentials are stored in .env:"
log_info "       CLOUDFLARE_ZONE_ID, CF_ACCOUNT_ID, CF_WORKER_BOUNCER_TOKEN"
log_info "     To update any value, edit .env then re-run:"
log_info "       sudo ./utilities/setup-crowdsec.sh --force"
log_info "  Verify dual-bouncer setup:"
log_info "    sudo cscli bouncers list          # both bouncers registered"
log_info "    sudo iptables -L CROWDSEC_CHAIN -n | head  # host-level blocks"
log_info "    sudo iptables -L DOCKER-USER -n | head     # container blocks"
log_info "    sudo cscli decisions list --origin lists   # community list active"
if [[ "$AUTONOMOUS_MODE" == "true" ]]; then
    log_info "  2. Set worker route fail mode to 'Fail Open' in Cloudflare dashboard:"
    log_info "       Dashboard → Website → Worker Routes → Edit → Fail open"
    log_info "  3. Verify decisions are reaching Cloudflare KV (free plan: up to 1K/day):"
    log_info "       sudo cscli decisions list"
else
    log_info "  2. Set worker route fail mode to 'Fail Open' in Cloudflare dashboard:"
    log_info "       Dashboard → Website → Worker Routes → Edit → Fail open"
    log_info "  3. Verify CrowdSec metrics:"
    log_info "       sudo cscli metrics"
    log_info "  4. After updating the token in .env, restart the Workers bouncer:"
    log_info "       sudo ./utilities/setup-crowdsec.sh --force"
fi
log_info "════════════════════════════════════════════════════════"
