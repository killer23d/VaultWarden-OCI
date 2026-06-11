#!/usr/bin/env bash
# utilities/setup-crowdsec.sh — Install and configure CrowdSec, the host
# firewall bouncer, and the Cloudflare Workers bouncer for VaultWarden-OCI.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

_cf_worker_bouncer_release_arch() {
    case "$1" in
        amd64|x86_64) printf '%s\n' amd64 ;;
        arm64|aarch64) printf '%s\n' arm64 ;;
        *) return 1 ;;
    esac
}

if [[ "${VAULTWARDEN_TEST_ARCH_HELPERS:-}" == "1" ]]; then
    _cf_worker_bouncer_release_arch "${1:-}"
    exit $?
fi

if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
    printf 'VaultWarden-OCI %s\n' "$(tr -d '[:space:]' < "${PROJECT_ROOT}/VERSION" 2>/dev/null || echo unknown)"
    exit 0
fi

if [[ "${1:-}" != "--help" && "${1:-}" != "-h" && "${1:-}" != "help" && "$EUID" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -n "$0" "$@"
    fi
    printf 'ERROR: run as root (or install/configure sudo)\n' >&2
    exit 1
fi

_LIBS_LOADED=false
for _lib in log.sh config.sh common.sh storage.sh secrets.sh; do
    _lib_path="${PROJECT_ROOT}/lib/${_lib}"
    if [[ -f "$_lib_path" ]]; then
        # shellcheck disable=SC1090
        source "$_lib_path"
        [[ "$_lib" == common.sh ]] && _LIBS_LOADED=true
    fi
done
unset _lib _lib_path

if [[ "$_LIBS_LOADED" == true ]]; then
    set_log_prefix crowdsec
else
    log_info()    { printf '[INFO]    crowdsec %s\n' "$*"; }
    log_success() { printf '[SUCCESS] crowdsec %s\n' "$*"; }
    log_warn()    { printf '[WARN]    crowdsec %s\n' "$*" >&2; }
    log_error()   { printf '[ERROR]   crowdsec %s\n' "$*" >&2; }
    press_enter_to_continue() { read -r -p "${1:-Press Enter to continue...}" _ || true; }
    COLOR_RED=''
    COLOR_RESET=''
fi

if [[ -f "${PROJECT_ROOT}/.env" ]]; then
    if declare -F load_env_file >/dev/null 2>&1; then
        load_env_file "${PROJECT_ROOT}/.env" || true
    else
        # shellcheck disable=SC1091
        source "${PROJECT_ROOT}/.env" 2>/dev/null || true
    fi
fi

AUTO_MODE=false
DRY_RUN=false
FORCE=false
AUTONOMOUS_MODE=false
USE_LATEST=false
ADMIN_IP=""
CROWDSEC_VERSION="${CROWDSEC_VERSION:-}"
CF_WORKER_BOUNCER_VERSION="${CF_WORKER_BOUNCER_VERSION:-}"
FIREWALL_BOUNCER_VERSION="${FIREWALL_BOUNCER_VERSION:-}"

show_help() {
    cat <<'HELP'
VaultWarden-OCI CrowdSec Setup

USAGE:
    sudo utilities/setup-crowdsec.sh [OPTIONS]

OPTIONS:
    --auto               Never prompt for input.
    --dry-run            Print planned changes without modifying the host.
    --force              Reconcile and regenerate managed CrowdSec configuration.
    --use-latest         Ignore configured version pins for this run.
    --autonomous         Deploy the Workers bouncer in autonomous mode.
    --admin-ip IP|CIDR   Add a persistent CrowdSec parser allowlist entry.
    --help, -h           Show this help.
    --version, -V        Print the VaultWarden-OCI version.

ENVIRONMENT:
    CLOUDFLARE_PROXY_ENABLED
    CF_FREE_PLAN
    CROWDSEC_VERSION
    CF_WORKER_BOUNCER_VERSION
    FIREWALL_BOUNCER_VERSION
HELP
}

while (($#)); do
    case "$1" in
        --auto) AUTO_MODE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --force) FORCE=true; shift ;;
        --use-latest) USE_LATEST=true; shift ;;
        --autonomous) AUTONOMOUS_MODE=true; shift ;;
        --admin-ip)
            [[ -n "${2:-}" && "${2:-}" != --* ]] || { log_error '--admin-ip requires an IP or CIDR'; exit 1; }
            ADMIN_IP="$2"; shift 2 ;;
        --help|-h|help) show_help; exit 0 ;;
        --version|-V) printf 'VaultWarden-OCI %s\n' "$(tr -d '[:space:]' < "${PROJECT_ROOT}/VERSION" 2>/dev/null || echo unknown)"; exit 0 ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ "$USE_LATEST" == true ]]; then
    CROWDSEC_VERSION=""
    CF_WORKER_BOUNCER_VERSION=""
    FIREWALL_BOUNCER_VERSION=""
fi
[[ "$CROWDSEC_VERSION" == latest ]] && CROWDSEC_VERSION=""
[[ "$CF_WORKER_BOUNCER_VERSION" == latest ]] && CF_WORKER_BOUNCER_VERSION=""
[[ "$FIREWALL_BOUNCER_VERSION" == latest ]] && FIREWALL_BOUNCER_VERSION=""

run() {
    if [[ "$DRY_RUN" == true ]]; then
        printf '[DRY RUN]'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

_set_env_var() {
    local key="$1" value="$2" env_file="${PROJECT_ROOT}/.env" tmp
    [[ -f "$env_file" ]] || return 0
    tmp="$(mktemp "${env_file}.tmp.XXXXXX")"
    trap 'rm -f "$tmp"' RETURN
    awk -v key="$key" -v value="$value" '
        BEGIN { done=0 }
        $0 ~ "^" key "=" { print key "=" value; done=1; next }
        { print }
        END { if (!done) print key "=" value }
    ' "$env_file" > "$tmp"
    chmod --reference="$env_file" "$tmp" 2>/dev/null || chmod 600 "$tmp"
    mv "$tmp" "$env_file"
}

_lapi_port() {
    local port
    port="$(sed -nE 's/^[[:space:]]*listen_uri:[[:space:]]*127\.0\.0\.1:([0-9]+).*$/\1/p' /etc/crowdsec/config.yaml 2>/dev/null | head -1)"
    printf '%s\n' "${port:-8090}"
}

_rewrite_lapi_port() {
    local old="$1" new="$2" file
    for file in \
        /etc/crowdsec/config.yaml \
        /etc/crowdsec/local_api_credentials.yaml \
        /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml \
        /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml; do
        [[ -f "$file" ]] || continue
        sed -i \
            -e "s|127.0.0.1:${old}|127.0.0.1:${new}|g" \
            "$file"
    done
}

_wait_for_lapi() {
    local port="$1" i
    for i in {1..30}; do
        curl -fsS --max-time 2 "http://127.0.0.1:${port}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

_validate_cloudflare_id() {
    [[ "$1" =~ ^[0-9a-fA-F]{32}$ ]]
}

_validate_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] && [[ "$domain" != .* ]] && [[ "$domain" != *. ]] && [[ "$domain" == *.* ]]
}

_install_base_packages() {
    if command -v cscli >/dev/null 2>&1 && [[ "$FORCE" != true ]]; then
        log_info 'CrowdSec is already installed; retaining the engine package.'
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info '[DRY RUN] Would configure the official CrowdSec apt repository and install engine/bouncer packages.'
        return 0
    fi

    local repo_script cs_pkg fw_backend fw_pkg
    repo_script="$(mktemp /tmp/crowdsec-repository.XXXXXX.sh)"
    trap 'rm -f "$repo_script"' EXIT
    curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 30 \
        https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh \
        -o "$repo_script"
    head -1 "$repo_script" | grep -qE '^#!/(usr/)?bin/(env )?bash' || {
        log_error 'Downloaded CrowdSec repository bootstrap is not a shell script.'
        exit 1
    }
    bash "$repo_script"
    rm -f "$repo_script"
    trap - EXIT

    cs_pkg=crowdsec
    [[ -n "$CROWDSEC_VERSION" ]] && cs_pkg="crowdsec=${CROWDSEC_VERSION}"
    if iptables -V 2>/dev/null | grep -q nf_tables; then
        fw_backend=nftables
    else
        fw_backend=iptables
    fi
    fw_pkg="crowdsec-firewall-bouncer-${fw_backend}"
    [[ -n "$FIREWALL_BOUNCER_VERSION" ]] && fw_pkg+="=${FIREWALL_BOUNCER_VERSION}"

    DEBIAN_FRONTEND=noninteractive apt-get install -y "$cs_pkg" "$fw_pkg" ipset

    if grep -q 'listen_uri: 127.0.0.1:8080' /etc/crowdsec/config.yaml 2>/dev/null; then
        _rewrite_lapi_port 8080 8090
    fi

    systemctl daemon-reload
    systemctl enable --now crowdsec
}

_ensure_firewall_bouncer_key() {
    local config="$1" key
    key="$(sed -nE 's/^[[:space:]]*api_key:[[:space:]]*([^[:space:]]+).*$/\1/p' "$config" 2>/dev/null | head -1)"
    if [[ -z "$key" || "$key" == CHANGE_ME* ]] || ! cscli bouncers list 2>/dev/null | grep -q firewall-bouncer; then
        key="$(openssl rand -hex 32)"
        cscli bouncers delete crowdsecurity/firewall-bouncer >/dev/null 2>&1 || true
        cscli bouncers add crowdsecurity/firewall-bouncer --key "$key" >/dev/null
        sed -i "s|^[[:space:]]*api_key:.*|api_key: ${key}|" "$config"
    fi
    unset key
}

_configure_firewall_bouncer() {
    local config=/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml port mode hooks key
    port="$(_lapi_port)"
    mkdir -p /etc/crowdsec/bouncers

    if iptables -V 2>/dev/null | grep -q nf_tables; then
        mode=nftables
        hooks=$'nftables_hooks:\n  - input\n  - forward'
    else
        mode=iptables
        hooks=$'iptables_chains:\n  - INPUT\n  - DOCKER-USER'
    fi

    if [[ ! -f "$config" || "$FORCE" == true ]]; then
        key="$(openssl rand -hex 32)"
        if [[ "$DRY_RUN" != true ]]; then
            cscli bouncers delete crowdsecurity/firewall-bouncer >/dev/null 2>&1 || true
            cscli bouncers add crowdsecurity/firewall-bouncer --key "$key" >/dev/null
            cat > "$config" <<EOF_FW
mode: ${mode}
update_frequency: 10s
log_mode: stdout
log_level: info
api_url: http://127.0.0.1:${port}/
api_key: ${key}
origins: []
${hooks}
deny_action: DROP
disable_ipv6: false
EOF_FW
            chmod 600 "$config"
        fi
        unset key
    elif [[ "$DRY_RUN" != true ]]; then
        _ensure_firewall_bouncer_key "$config"
    fi
}

_install_cf_bouncer_binary() {
    local binary=/usr/local/bin/crowdsec-cloudflare-worker-bouncer pkg version arch api json url sha_url tmp expected actual found
    [[ -x "$binary" && "$FORCE" != true ]] && return 0
    [[ "$DRY_RUN" == true ]] && { log_info '[DRY RUN] Would install the Cloudflare Workers bouncer.'; return 0; }

    pkg=crowdsec-cloudflare-worker-bouncer
    [[ -n "$CF_WORKER_BOUNCER_VERSION" ]] && pkg+="=${CF_WORKER_BOUNCER_VERSION#v}"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"; then
        found="$(command -v crowdsec-cloudflare-worker-bouncer || true)"
        [[ -n "$found" && "$found" != "$binary" ]] && ln -sf "$found" "$binary"
        [[ -x "$binary" ]] && return 0
    fi

    arch="$(_cf_worker_bouncer_release_arch "$(dpkg --print-architecture 2>/dev/null || uname -m)")" || {
        log_error 'Unsupported architecture for Cloudflare Workers bouncer.'
        return 1
    }
    if [[ -n "$CF_WORKER_BOUNCER_VERSION" ]]; then
        version="v${CF_WORKER_BOUNCER_VERSION#v}"
        api="https://api.github.com/repos/crowdsecurity/cs-cloudflare-worker-bouncer/releases/tags/${version}"
    else
        api='https://api.github.com/repos/crowdsecurity/cs-cloudflare-worker-bouncer/releases/latest'
    fi
    json="$(curl -fsSL --proto '=https' --tlsv1.2 "$api")"
    url="$(grep -oP '"browser_download_url":\s*"\K[^"]+' <<< "$json" | grep "linux-${arch}" | grep '\.tgz$' | head -1 || true)"
    sha_url="$(grep -oP '"browser_download_url":\s*"\K[^"]+' <<< "$json" | grep "linux-${arch}" | grep '\.tgz\.sha256$' | head -1 || true)"
    [[ -n "$url" && -n "$sha_url" ]] || { log_error 'No verified release tarball pair was found.'; return 1; }

    tmp="$(mktemp -d /tmp/crowdsec-cf-bouncer.XXXXXX)"
    trap 'rm -rf "$tmp"' RETURN
    curl -fsSL --proto '=https' --tlsv1.2 "$url" -o "$tmp/bouncer.tgz"
    expected="$(curl -fsSL --proto '=https' --tlsv1.2 "$sha_url" | awk '{print $1}')"
    actual="$(sha256sum "$tmp/bouncer.tgz" | awk '{print $1}')"
    [[ -n "$expected" && "$actual" == "$expected" ]] || { log_error 'Cloudflare bouncer tarball SHA-256 verification failed.'; return 1; }
    tar -xzf "$tmp/bouncer.tgz" -C "$tmp"
    found="$(find "$tmp" -maxdepth 3 -type f -name crowdsec-cloudflare-worker-bouncer | head -1)"
    [[ -x "$found" ]] || { log_error 'Cloudflare bouncer binary was not found in the verified archive.'; return 1; }
    install -m 0755 -o root -g root "$found" "$binary"
}

_write_cf_bouncer_unit() {
    local unit=/etc/systemd/system/crowdsec-cloudflare-worker-bouncer.service
    [[ "$AUTONOMOUS_MODE" == true ]] && return 0
    [[ "$DRY_RUN" == true ]] && return 0
    cat > "$unit" <<'EOF_UNIT'
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
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
CapabilityBoundingSet=
AmbientCapabilities=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
EOF_UNIT
    chmod 644 "$unit"
    systemctl daemon-reload
}

_reconcile_collections() {
    local collection failures=0
    local -a required=(
        crowdsecurity/linux
        crowdsecurity/caddy
        crowdsecurity/iptables
        Dominic-Wagner/vaultwarden
    )
    local -a obsolete=(
        crowdsecurity/appsec-generic-rules
        crowdsecurity/appsec-virtual-patching
    )

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would install: ${required[*]}"
        log_info "[DRY RUN] Would remove inactive AppSec collections: ${obsolete[*]}"
        return 0
    fi

    cscli hub update || log_warn 'CrowdSec Hub update failed; using the local Hub index.'
    for collection in "${required[@]}"; do
        cscli collections install "$collection" || { log_error "Failed to install required collection: $collection"; failures=1; }
    done
    ((failures == 0)) || return 1

    for collection in "${obsolete[@]}"; do
        if cscli collections list 2>/dev/null | grep -Fq "$collection"; then
            cscli collections remove "$collection" --purge --force || log_warn "Could not remove inactive collection: $collection"
        fi
    done
}

_write_acquisition() {
    local src="${PROJECT_ROOT}/crowdsec/acquis.yaml" dest=/etc/crowdsec/acquis.d/vaultwarden.yaml state
    [[ -f "$src" ]] || { log_error "Missing acquisition template: $src"; return 1; }
    state="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR:-/var/lib/vaultwarden}}"
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would render $dest from $src"
        return 0
    fi
    mkdir -p /etc/crowdsec/acquis.d
    sed "s|TOKEN_PROJECT_STATE_DIR|${state}|g" "$src" > "$dest"
    chmod 640 "$dest"
}

_render_cf_bouncer_config() {
    local src="${PROJECT_ROOT}/crowdsec/crowdsec-cloudflare-worker-bouncer.yaml.example"
    local dest=/etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml
    local token zone account email domain route key port origins

    [[ -f "$src" ]] || { log_error "Missing Cloudflare bouncer template: $src"; return 1; }
    token="$(decrypt_secret cf_worker_bouncer_token)"
    zone="$(decrypt_secret cloudflare_zone_id)"
    account="$(decrypt_secret cf_account_id)"
    _validate_cloudflare_id "$zone" || { log_error 'cloudflare_zone_id must be 32 hexadecimal characters.'; return 1; }
    _validate_cloudflare_id "$account" || { log_error 'cf_account_id must be 32 hexadecimal characters.'; return 1; }
    [[ "$token" =~ ^[A-Za-z0-9_-]{20,}$ ]] || { log_error 'cf_worker_bouncer_token has an unexpected format.'; return 1; }

    domain="${DOMAIN_NAME:-${DOMAIN:-}}"
    domain="${domain#https://}"
    domain="${domain#http://}"
    domain="${domain%%/*}"
    _validate_domain "$domain" || { log_error "Invalid DOMAIN_NAME/DOMAIN host: $domain"; return 1; }
    route="${domain}/*"
    email="${CF_ACCOUNT_EMAIL:-CHANGE_ME_CF_ACCOUNT_EMAIL}"
    key="${CROWDSEC_CF_BOUNCER_API_KEY:-}"
    port="$(_lapi_port)"
    [[ -n "$key" ]] || { log_error 'CROWDSEC_CF_BOUNCER_API_KEY is empty.'; return 1; }
    if [[ "${CF_FREE_PLAN:-true}" == true ]]; then
        origins='  only_include_decisions_from: ["cscli", "crowdsec"]'
    else
        origins='  only_include_decisions_from: []'
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would render Cloudflare Workers bouncer config for $route"
    else
        mkdir -p /etc/crowdsec/bouncers
        sed \
            -e "s|%%CLOUDFLARE_ZONE_ID%%|${zone}|g" \
            -e "s|%%CF_ACCOUNT_ID%%|${account}|g" \
            -e "s|%%CF_WORKER_BOUNCER_TOKEN%%|${token}|g" \
            -e "s|%%CF_ACCOUNT_NAME%%|${email}|g" \
            -e "s|%%CROWDSEC_LAPI_KEY%%|${key}|g" \
            -e "s|%%WORKER_ROUTE%%|${route}|g" \
            -e "s|^[[:space:]]*only_include_decisions_from:.*|${origins}|" \
            -e "s|lapi_url: http://127\.0\.0\.1:[0-9]*/|lapi_url: http://127.0.0.1:${port}/|" \
            "$src" | grep -v '%%[A-Z_]*%%' > "$dest"
        chmod 600 "$dest"
    fi
    unset token zone account key
    cleanup_secrets_environment 2>/dev/null || true
}

_register_cf_bouncer() {
    local key existing
    existing="${CROWDSEC_CF_BOUNCER_API_KEY:-}"
    if [[ -n "$existing" && "$FORCE" != true ]] && cscli bouncers list 2>/dev/null | grep -q cloudflare-worker-bouncer; then
        return 0
    fi
    key="$(openssl rand -hex 32)"
    if [[ "$DRY_RUN" != true ]]; then
        cscli bouncers delete cloudflare-worker-bouncer >/dev/null 2>&1 || true
        cscli bouncers add cloudflare-worker-bouncer --key "$key" >/dev/null
        _set_env_var CROWDSEC_CF_BOUNCER_API_KEY "$key"
        CROWDSEC_CF_BOUNCER_API_KEY="$key"
    fi
    unset key
}

_apply_profiles() {
    local src="${PROJECT_ROOT}/crowdsec/profiles.yaml"
    [[ -f "$src" ]] || return 0
    run install -m 0644 -o root -g root "$src" /etc/crowdsec/profiles.yaml
}

_write_admin_allowlist() {
    local value="$ADMIN_IP" field file=/etc/crowdsec/parsers/s02-enrich/vaultwarden-admin-allowlist.yaml
    if [[ -z "$value" && -n "${SSH_CLIENT:-}" ]]; then
        value="${SSH_CLIENT%% *}"
    fi
    [[ -n "$value" ]] || { log_warn 'No admin IP was allowlisted.'; return 0; }
    [[ "$value" =~ ^[0-9a-fA-F:./]+$ ]] || { log_error "Invalid admin IP/CIDR: $value"; return 1; }
    [[ "$value" == */* ]] && field=cidr || field=ip
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would allowlist $value"
        return 0
    fi
    mkdir -p "$(dirname "$file")"
    cat > "$file" <<EOF_ALLOW
name: vaultwarden/admin-allowlist
description: VaultWarden administrator allowlist
whitelist:
  reason: VaultWarden administrator allowlist
  ${field}:
    - "${value}"
EOF_ALLOW
    chmod 640 "$file"
}

_start_services() {
    local port
    [[ "$DRY_RUN" == true ]] && { log_info '[DRY RUN] Would validate and start CrowdSec services.'; return 0; }
    if ! systemctl reload crowdsec 2>/dev/null && ! systemctl restart crowdsec; then
        log_error 'CrowdSec rejected the rendered configuration.'
        return 1
    fi
    port="$(_lapi_port)"
    _wait_for_lapi "$port" || { log_error "CrowdSec LAPI did not become ready on port $port."; return 1; }

    systemctl enable --now crowdsec-firewall-bouncer
    systemctl is-active --quiet crowdsec-firewall-bouncer || { log_error 'Firewall bouncer is not active.'; return 1; }

    if [[ "${CLOUDFLARE_PROXY_ENABLED:-false}" == true ]]; then
        if [[ "$AUTONOMOUS_MODE" == true ]]; then
            /usr/local/bin/crowdsec-cloudflare-worker-bouncer -S -c /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml
        else
            systemctl enable --now crowdsec-cloudflare-worker-bouncer
            systemctl is-active --quiet crowdsec-cloudflare-worker-bouncer || { log_error 'Cloudflare Workers bouncer is not active.'; return 1; }
        fi
    fi
}

log_info '=== CrowdSec base installation ==='
_install_base_packages
_configure_firewall_bouncer

log_info '=== CrowdSec collection policy ==='
_reconcile_collections

log_info '=== CrowdSec acquisition and profiles ==='
_write_acquisition
_apply_profiles

if [[ "${CLOUDFLARE_PROXY_ENABLED:-false}" == true ]]; then
    log_info '=== Cloudflare Workers bouncer ==='
    _install_cf_bouncer_binary
    _write_cf_bouncer_unit
    _register_cf_bouncer
    _render_cf_bouncer_config
else
    log_warn 'Cloudflare proxy integration is disabled; skipping the Workers bouncer.'
fi

log_info '=== CrowdSec administrator allowlist ==='
_write_admin_allowlist

log_info '=== CrowdSec service validation ==='
_start_services

log_success 'CrowdSec setup completed successfully.'
log_info "LAPI port: $(_lapi_port)"
log_info 'Verify with: sudo cscli metrics show acquisition parsers scenarios'
log_info 'Verify bouncers with: sudo cscli bouncers list'
