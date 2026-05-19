#!/usr/bin/env bash
# utilities/setup-crowdsec.sh – Install and configure CrowdSec with
# iptables and Cloudflare bouncers for VaultWarden-OCI.
#
# Run automatically at the end of setup.sh, or standalone:
#   sudo ./utilities/setup-crowdsec.sh [--auto] [--dry-run]
#
# Secrets (CF zone ID, CF API token, bouncer API key) are NOT
# collected here. They are stored later by edit-secrets.sh.
# This script writes CROWDSEC_CF_BOUNCER_API_KEY to .env so
# edit-secrets.sh can consume it, and leaves CF token placeholders
# that the operator fills via edit-secrets.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Root check ──────────────────────────────────────────────────────────────
if [[ "${EUID}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -n "$0" "$@"
    fi
    echo "ERROR: run as root (or install/configure sudo)" >&2
    exit 1
fi

cd "${PROJECT_ROOT}"

# ── Source libs (guard — standalone safety) ──────────────────────────────────
_LIBS_LOADED=false
if [[ -f "${PROJECT_ROOT}/lib/common.sh" ]]; then
    # shellcheck source=../lib/common.sh
    source "${PROJECT_ROOT}/lib/common.sh"
    _LIBS_LOADED=true
fi
if [[ -f "${PROJECT_ROOT}/lib/storage.sh" ]]; then
    # shellcheck source=../lib/storage.sh
    source "${PROJECT_ROOT}/lib/storage.sh"
fi

if [[ "$_LIBS_LOADED" == "true" ]]; then
    set_log_prefix "crowdsec"
else
    # Fallback logging when lib/common.sh is not available
    log_info()    { printf '[INFO]    crowdsec %s\n'    "$*"; }
    log_success() { printf '[SUCCESS] crowdsec %s\n'    "$*"; }
    log_warn()    { printf '[WARN]    crowdsec %s\n'    "$*" >&2; }
    log_error()   { printf '[ERROR]   crowdsec %s\n'    "$*" >&2; }
fi

# ── Load .env ────────────────────────────────────────────────────────────────
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
    if declare -f load_env_file >/dev/null 2>&1; then
        load_env_file "${PROJECT_ROOT}/.env" || true
    else
        # shellcheck disable=SC1091
        source "${PROJECT_ROOT}/.env" 2>/dev/null || true
    fi
fi

# ── Helper: write or update a KEY=VALUE line in .env ─────────────────────────
_cs_set_env_var() {
    local key="$1" value="$2"
    local env_file="${PROJECT_ROOT}/.env"
    [[ -f "$env_file" ]] || return 0
    local escaped_value
    escaped_value="${value//\\/\\\\}"
    escaped_value="${escaped_value//&/\\&}"
    escaped_value="${escaped_value//|/\\|}"
    if grep -q "^${key}=" "$env_file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${escaped_value}|" "$env_file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$env_file"
    fi
}

# ── Flags ────────────────────────────────────────────────────────────────────
AUTO_MODE=false
DRY_RUN=false
FORCE=false

for _arg in "$@"; do
    case "$_arg" in
        --auto)     AUTO_MODE=true ;;
        --dry-run)  DRY_RUN=true ;;
        --force)    FORCE=true ;;
        --help|-h)
            cat <<'HELP'
usage: sudo ./utilities/setup-crowdsec.sh [--auto] [--dry-run] [--force]

  --auto      Non-interactive: never prompt.
  --dry-run   Print what would happen; make no changes.
  --force     Re-run all phases even if already applied.
HELP
            exit 0
            ;;
        *)
            log_error "Unknown flag: $_arg"
            exit 1
            ;;
    esac
done

if [[ "$AUTO_MODE" == "true" ]]; then
    log_info "Running in non-interactive (auto) mode."
fi

# ── Dry-run wrapper ───────────────────────────────────────────────────────────
_cs_run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] $*"
    else
        "$@"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — Install CrowdSec base + iptables bouncer
# ═══════════════════════════════════════════════════════════════════════════════
log_info "=== PHASE 1: CrowdSec base installation ==="

if command -v cscli >/dev/null 2>&1 && [[ "$FORCE" != "true" ]]; then
    log_info "CrowdSec already installed — skipping base install."
else
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install crowdsec and crowdsec-firewall-bouncer-iptables"
    else
        log_info "Adding CrowdSec repository..."
        curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
        log_info "Installing CrowdSec packages..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            crowdsec \
            crowdsec-firewall-bouncer-iptables
    fi
fi

if [[ "$DRY_RUN" != "true" ]]; then
    systemctl enable --now crowdsec || true
    log_success "CrowdSec service enabled and started."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 2 — Install Cloudflare bouncer via cscli
# ═══════════════════════════════════════════════════════════════════════════════
log_info "=== PHASE 2: Cloudflare bouncer installation ==="

_CF_BOUNCER_BIN="/usr/local/bin/crowdsec-cloudflare-bouncer"
_CF_BOUNCER_NEEDS_INSTALL=false

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would install crowdsecurity/cloudflare-bouncer via cscli"
else
    if ! cscli bouncers list 2>/dev/null | grep -q 'cloudflare-bouncer' || [[ "$FORCE" == "true" ]]; then
        log_info "Updating CrowdSec hub..."
        cscli hub update || true
        log_info "Registering Cloudflare bouncer in CrowdSec LAPI..."
        # cscli bouncers add <name> registers the bouncer's API key in the LAPI;
        # the actual binary is installed separately (apt or GitHub release fallback).
        cscli bouncers add crowdsecurity/cloudflare-bouncer 2>/dev/null || true
    else
        log_info "CrowdSec Cloudflare bouncer already registered — skipping."
    fi

    # Check whether the service binary exists; fall back to GitHub release if not.
    if [[ ! -x "$_CF_BOUNCER_BIN" ]] || [[ "$FORCE" == "true" ]]; then
        _CF_BOUNCER_NEEDS_INSTALL=true
    fi

    if [[ "$_CF_BOUNCER_NEEDS_INSTALL" == "true" ]]; then
        log_info "Cloudflare bouncer binary not found — attempting GitHub release download..."
        _arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
        case "$_arch" in
            arm64|aarch64) _arch="arm64" ;;
            amd64|x86_64)  _arch="amd64" ;;
            *)             log_warn "Unsupported architecture: $_arch — skipping CF bouncer binary download"; _arch="" ;;
        esac

        if [[ -n "$_arch" ]]; then
            _gh_api="https://api.github.com/repos/crowdsecurity/cs-cloudflare-bouncer/releases/latest"
            _release_json="$(curl -fsSL "$_gh_api" 2>/dev/null)" || {
                log_warn "Failed to query GitHub releases for cs-cloudflare-bouncer — skipping binary download."
                _release_json=""
            }

            if [[ -n "$_release_json" ]]; then
                _download_url="$(printf '%s' "$_release_json" | \
                    grep -oP '"browser_download_url":\s*"\K[^"]+' | \
                    grep "linux_${_arch}" | \
                    grep -v '\.sha256' | \
                    head -1 || true)"
                _sha256_url="$(printf '%s' "$_release_json" | \
                    grep -oP '"browser_download_url":\s*"\K[^"]+' | \
                    grep "linux_${_arch}\.sha256" | \
                    head -1 || true)"

                if [[ -n "$_download_url" ]]; then
                    _tmpbin="$(mktemp -p /tmp cs-cf-bouncer.XXXXXX)"
                    log_info "Downloading: $_download_url"
                    if curl -fsSL "$_download_url" -o "$_tmpbin"; then
                        if [[ -n "$_sha256_url" ]]; then
                            _expected_sha="$(curl -fsSL "$_sha256_url" 2>/dev/null | awk '{print $1}' || true)"
                            _actual_sha="$(sha256sum "$_tmpbin" | awk '{print $1}')"
                            if [[ -n "$_expected_sha" && "$_actual_sha" != "$_expected_sha" ]]; then
                                log_error "SHA256 mismatch for cs-cloudflare-bouncer binary — aborting binary install."
                                rm -f "$_tmpbin"
                            else
                                install -m 755 -o root -g root "$_tmpbin" "$_CF_BOUNCER_BIN"
                                rm -f "$_tmpbin"
                                log_success "Installed cs-cloudflare-bouncer binary to ${_CF_BOUNCER_BIN}"
                            fi
                        else
                            install -m 755 -o root -g root "$_tmpbin" "$_CF_BOUNCER_BIN"
                            rm -f "$_tmpbin"
                            log_success "Installed cs-cloudflare-bouncer binary to ${_CF_BOUNCER_BIN} (SHA256 not verified)"
                        fi
                    else
                        rm -f "$_tmpbin"
                        log_warn "Failed to download cs-cloudflare-bouncer binary — Cloudflare bouncer service will need manual installation."
                    fi
                else
                    log_warn "Could not find a linux_${_arch} asset in the GitHub release — skipping binary download."
                fi
            fi
        fi
    else
        log_info "Cloudflare bouncer binary already present at ${_CF_BOUNCER_BIN}."
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 3 — Install CrowdSec hub collections
# ═══════════════════════════════════════════════════════════════════════════════
log_info "=== PHASE 3: CrowdSec hub collections ==="

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would install hub collections: crowdsecurity/linux, crowdsecurity/caddy, crowdsecurity/http-cve, Dominic-Wagner/vaultwarden"
else
    cscli collections install crowdsecurity/linux     || true
    cscli collections install crowdsecurity/caddy     || true
    cscli collections install crowdsecurity/http-cve  || true
    cscli collections install Dominic-Wagner/vaultwarden || true
    log_success "Hub collections installed."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 4 — Write acquisition config
# ═══════════════════════════════════════════════════════════════════════════════
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

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 5 — Generate and register bouncer API key
# ═══════════════════════════════════════════════════════════════════════════════
log_info "=== PHASE 5: Bouncer API key ==="

_CF_BOUNCER_KEY=""
_CF_BOUNCER_ENV_KEY="CROWDSEC_CF_BOUNCER_API_KEY"

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would generate and register a bouncer API key, write to .env as ${_CF_BOUNCER_ENV_KEY}"
    _CF_BOUNCER_KEY="DRY_RUN_PLACEHOLDER"
else
    # Check if a key is already stored in .env
    _existing_key="${CROWDSEC_CF_BOUNCER_API_KEY:-}"
    if [[ -n "$_existing_key" ]] && cscli bouncers list 2>/dev/null | grep -q 'cloudflare-bouncer' && [[ "$FORCE" != "true" ]]; then
        log_info "Bouncer API key already present in .env — skipping key generation."
        _CF_BOUNCER_KEY="$_existing_key"
    else
        log_info "Generating new bouncer API key..."
        _new_key="$(openssl rand -hex 32)"
        # Remove stale registration if it exists (idempotent re-add)
        cscli bouncers delete cloudflare-bouncer 2>/dev/null || true
        cscli bouncers add cloudflare-bouncer --key "$_new_key" 2>/dev/null || {
            log_warn "cscli bouncers add failed — CrowdSec LAPI may not be running yet. Key stored in .env for later."
        }
        _CF_BOUNCER_KEY="$_new_key"
        _cs_set_env_var "$_CF_BOUNCER_ENV_KEY" "$_CF_BOUNCER_KEY"
        log_success "Bouncer API key generated and registered. Written to .env as ${_CF_BOUNCER_ENV_KEY}."
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 6 — Write Cloudflare bouncer config
# ═══════════════════════════════════════════════════════════════════════════════
log_info "=== PHASE 6: Cloudflare bouncer config ==="

_CF_BOUNCER_CONFIG_SRC="${PROJECT_ROOT}/crowdsec/crowdsec-cloudflare-bouncer.yaml.example"
_CF_BOUNCER_CONFIG_DEST="/etc/crowdsec/bouncers/crowdsec-cloudflare-bouncer.yaml"

if [[ -f "$_CF_BOUNCER_CONFIG_SRC" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would write ${_CF_BOUNCER_CONFIG_DEST} from ${_CF_BOUNCER_CONFIG_SRC}"
    else
        mkdir -p /etc/crowdsec/bouncers
        sed \
            -e "s|TOKEN_CF_ZONE_ID|${CLOUDFLARE_ZONE_ID:-CHANGE_ME_CF_ZONE_ID}|g" \
            -e "s|TOKEN_CF_ACCOUNT_ID|${CF_ACCOUNT_ID:-CHANGE_ME_CF_ACCOUNT_ID}|g" \
            -e "s|TOKEN_CROWDSEC_CF_FIREWALL_TOKEN|CHANGE_ME_CROWDSEC_CF_FIREWALL_TOKEN|g" \
            -e "s|CHANGE_ME_BOUNCER_KEY|${_CF_BOUNCER_KEY}|g" \
            "$_CF_BOUNCER_CONFIG_SRC" \
            | tee "$_CF_BOUNCER_CONFIG_DEST" >/dev/null
        chmod 600 "$_CF_BOUNCER_CONFIG_DEST"
        log_success "Cloudflare bouncer config written to ${_CF_BOUNCER_CONFIG_DEST} (mode 600)."
    fi
else
    log_warn "crowdsec-cloudflare-bouncer.yaml.example not found in ${PROJECT_ROOT}/crowdsec — skipping bouncer config write."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 7 — Apply profiles
# ═══════════════════════════════════════════════════════════════════════════════
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

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 8 — Enable and start services
# ═══════════════════════════════════════════════════════════════════════════════
log_info "=== PHASE 8: Enable and start services ==="

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would reload crowdsec and enable crowdsec-firewall-bouncer and crowdsec-cloudflare-bouncer"
else
    systemctl reload crowdsec                          || true
    systemctl enable --now crowdsec-firewall-bouncer   || true
    systemctl enable --now crowdsec-cloudflare-bouncer || true
    log_success "Services enabled."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Post-install notice
# ═══════════════════════════════════════════════════════════════════════════════
log_info ""
log_info "════════════════════════════════════════════════════════"
log_info " CrowdSec installation complete"
log_info "════════════════════════════════════════════════════════"
log_info "Next steps:"
log_info "  1. Set CLOUDFLARE_ZONE_ID (and optionally CF_ACCOUNT_ID) in .env"
log_info "  2. Run ./edit-secrets.sh to add the Cloudflare firewall API token"
log_info "     under the key: crowdsec_cf_firewall_token"
log_info "     (Permissions required: Zone:Firewall Services:Edit)"
log_info "  3. Verify CrowdSec metrics:"
log_info "       sudo cscli metrics"
log_info "  4. After setting tokens, restart the Cloudflare bouncer:"
log_info "       sudo systemctl restart crowdsec-cloudflare-bouncer"
log_info "════════════════════════════════════════════════════════"
