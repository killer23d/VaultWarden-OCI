#!/usr/bin/env bash
# utilities/setup-crowdsec.sh – Install and configure CrowdSec with
# iptables and Cloudflare bouncers for VaultWarden-OCI.
#
# Run automatically at the end of setup.sh, or standalone:
#   sudo ./utilities/setup-crowdsec.sh [--auto] [--dry-run]
#
# This script collects required Cloudflare values interactively
# (or writes placeholders in --auto mode), so CrowdSec can be fully
# configured before the VaultWarden stack is started.

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

# ── COLOR_* fallbacks for standalone runs (without lib/common.sh) ────────────
if [[ "$_LIBS_LOADED" != "true" ]]; then
    COLOR_RED=$'\033[0;31m'
    COLOR_GREEN=$'\033[0;32m'
    # shellcheck disable=SC2034  # COLOR_YELLOW/COLOR_CYAN may be used by sourcing scripts or future expansions
    COLOR_YELLOW=$'\033[0;33m'
    # shellcheck disable=SC2034
    COLOR_CYAN=$'\033[0;36m'
    COLOR_RESET=$'\033[0m'
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

# ── Helper: read a token from a flat secret file, reject placeholders ─────────
_cs_read_secret_file() {
    local path="$1"
    [[ -f "$path" ]] || return 0
    [[ -r "$path" ]] || return 0
    local val
    # Read first line only; preserve token content except surrounding whitespace.
    IFS= read -r val < "$path" || true
    val="${val#${val%%[![:space:]]*}}"
    val="${val%${val##*[![:space:]]}}"
    if [[ -n "$val" && "$val" != CHANGE_ME* && "$val" != PLACEHOLDER* ]]; then
        printf '%s' "$val"
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

# ── Helper: true if the crowdsec-cloudflare-bouncer service unit exists ───────
_cf_bouncer_service_exists() {
    systemctl list-unit-files crowdsec-cloudflare-bouncer.service 2>/dev/null \
        | grep -q 'crowdsec-cloudflare-bouncer.service'
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
# PHASE 2 — Install Cloudflare bouncer binary + systemd unit
# ═══════════════════════════════════════════════════════════════════════════════
log_info "=== PHASE 2: Cloudflare bouncer installation ==="

_CF_BOUNCER_BIN="/usr/local/bin/crowdsec-cloudflare-bouncer"
_CF_BOUNCER_NEEDS_INSTALL=false

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would install crowdsec-cloudflare-bouncer (deb → tarball → go source fallback)"
else
    # ── Register bouncer API key in CrowdSec LAPI ──────────────────────────
    if ! cscli bouncers list 2>/dev/null | grep -q 'cloudflare-bouncer' || [[ "$FORCE" == "true" ]]; then
        log_info "Updating CrowdSec hub..."
        cscli hub update || true
        log_info "Registering Cloudflare bouncer in CrowdSec LAPI..."
        cscli bouncers add crowdsecurity/cloudflare-bouncer 2>/dev/null || true
    else
        log_info "CrowdSec Cloudflare bouncer already registered — skipping."
    fi

    # ── Determine if binary install is needed ─────────────────────────────
    if [[ ! -x "$_CF_BOUNCER_BIN" ]] || [[ "$FORCE" == "true" ]]; then
        _CF_BOUNCER_NEEDS_INSTALL=true
    fi

    if [[ "$_CF_BOUNCER_NEEDS_INSTALL" == "true" ]]; then
        log_info "Cloudflare bouncer binary not found — attempting installation..."

        # ── Normalise architecture ─────────────────────────────────────────
        _arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
        case "$_arch" in
            arm64|aarch64) _arch="arm64" ;;
            amd64|x86_64)  _arch="amd64" ;;
            *)
                log_warn "Unsupported architecture: $_arch — skipping CF bouncer install"
                _arch=""
                ;;
        esac

        _installed_via_deb=false

        # ── Strategy 1: apt/deb from packagecloud (preferred) ─────────────
        # The packagecloud repo is already added by PHASE 1 (crowdsec install).
        # crowdsec-cloudflare-bouncer ships a proper arm64 deb that installs
        # the binary AND registers the systemd unit in one step.
        if [[ -n "$_arch" ]]; then
            log_info "Attempting apt install of crowdsec-cloudflare-bouncer..."
            if DEBIAN_FRONTEND=noninteractive apt-get install -y crowdsec-cloudflare-bouncer 2>/dev/null; then
                log_success "Installed crowdsec-cloudflare-bouncer via apt."
                _installed_via_deb=true
            else
                log_warn "apt install failed — falling back to GitHub release tarball."
            fi
        fi

        # ── Strategy 2: GitHub release tarball ────────────────────────────
        # The tarball ships its own install.sh + scripts/_bouncer.sh.
        # MUST be executed via (cd <dir> && bash install.sh) — install.sh
        # uses relative paths and will fail if called from any other CWD.
        if [[ "$_installed_via_deb" == "false" ]] && [[ -n "$_arch" ]]; then
            _gh_api="https://api.github.com/repos/crowdsecurity/cs-cloudflare-bouncer/releases/latest"
            _release_json="$(curl -fsSL "$_gh_api" 2>/dev/null)" || {
                log_warn "Failed to query GitHub releases for cs-cloudflare-bouncer."
                _release_json=""
            }

            if [[ -n "$_release_json" ]]; then
                # Asset filenames use hyphens: crowdsec-cloudflare-bouncer-linux-arm64.tgz
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
                    _tmpdir="$(mktemp -d -p /tmp cs-cf-bouncer.XXXXXX)"
                    _tmptar="${_tmpdir}/bouncer.tgz"

                    log_info "Downloading: $_download_url"
                    if curl -fsSL "$_download_url" -o "$_tmptar"; then

                        # ── Optional SHA256 verification ──────────────────
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

                            # Locate install.sh anywhere in the extracted tree
                            _install_sh="$(find "$_tmpdir" -maxdepth 2 -name 'install.sh' | head -1 || true)"

                            if [[ -n "$_install_sh" && -f "$_install_sh" ]]; then
                                _install_dir="$(dirname "$_install_sh")"
                                log_info "Running bundled installer from: $_install_dir"
                                # CRITICAL: cd into the directory — install.sh uses
                                # relative paths (./scripts/_bouncer.sh etc.)
                                if (cd "$_install_dir" && bash install.sh); then
                                    log_success "Installed cs-cloudflare-bouncer via tarball install.sh."
                                else
                                    log_warn "Bundled install.sh failed — will attempt manual binary extraction."
                                    # Fallback: copy binary manually + write unit file
                                    _bin_path="$(find "$_tmpdir" -maxdepth 3 -type f \
                                        -name 'crowdsec-cloudflare-bouncer' \
                                        ! -name '*.sh' | head -1 || true)"
                                    if [[ -x "$_bin_path" ]]; then
                                        install -m 755 -o root -g root "$_bin_path" "$_CF_BOUNCER_BIN"
                                        log_success "Copied binary to ${_CF_BOUNCER_BIN} (manual fallback)."
                                    fi
                                fi
                            else
                                log_warn "No install.sh found in tarball — extracting binary directly."
                                _bin_path="$(find "$_tmpdir" -maxdepth 3 -type f \
                                    -name 'crowdsec-cloudflare-bouncer' \
                                    ! -name '*.sh' | head -1 || true)"
                                if [[ -x "$_bin_path" ]]; then
                                    install -m 755 -o root -g root "$_bin_path" "$_CF_BOUNCER_BIN"
                                    log_success "Copied binary to ${_CF_BOUNCER_BIN}."
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

        # ── Strategy 3: Go source build (last resort) ─────────────────────
        if [[ -n "$_arch" ]] && [[ ! -x "$_CF_BOUNCER_BIN" ]]; then
            if command -v go >/dev/null 2>&1; then
                log_info "Attempting Go source build for crowdsec-cloudflare-bouncer..."
                _tmpgobin="$(mktemp -d -p /tmp cs-cf-go.XXXXXX)"
                if GOBIN="$_tmpgobin" go install \
                    github.com/crowdsecurity/cs-cloudflare-bouncer/cmd/crowdsec-cloudflare-bouncer@latest \
                    2>/dev/null; then
                    if [[ -x "$_tmpgobin/crowdsec-cloudflare-bouncer" ]]; then
                        install -m 755 -o root -g root \
                            "$_tmpgobin/crowdsec-cloudflare-bouncer" \
                            "$_CF_BOUNCER_BIN"
                        log_success "Built and installed crowdsec-cloudflare-bouncer from source."
                    fi
                else
                    log_warn "Go source build failed for crowdsec-cloudflare-bouncer."
                fi
                rm -rf "$_tmpgobin"
            else
                log_warn "Go toolchain not installed; cannot build from source."
                log_warn "Install Go, then run:"
                log_warn "  GOBIN=/tmp/cs-cf-go go install github.com/crowdsecurity/cs-cloudflare-bouncer/cmd/crowdsec-cloudflare-bouncer@latest"
            fi
        fi

        # ── Write systemd unit if binary exists but unit is missing ───────
        # This covers the Go-build path and any tarball that skips install.sh.
        if [[ -x "$_CF_BOUNCER_BIN" ]] && ! _cf_bouncer_service_exists; then
            log_info "Writing crowdsec-cloudflare-bouncer systemd unit..."
            cat >/etc/systemd/system/crowdsec-cloudflare-bouncer.service <<'UNIT'
[Unit]
Description=CrowdSec Cloudflare Bouncer
After=network-online.target crowdsec.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/crowdsec-cloudflare-bouncer -c /etc/crowdsec/bouncers/crowdsec-cloudflare-bouncer.yaml
Restart=on-failure
RestartSec=5
User=root
Group=root

[Install]
WantedBy=multi-user.target
UNIT
            systemctl daemon-reload || true
            log_success "Installed crowdsec-cloudflare-bouncer systemd unit."
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
        # Change 6: Display newly generated key with red-banner credential screen
        if [[ -t 0 ]]; then
            clear
            printf '%s' "${COLOR_RED}"
            cat << 'BOUNCER_BANNER'
  ╔══════════════════════════════════════════════════════════════════╗
  ║   🔑  CROWDSEC CLOUDFLARE BOUNCER API KEY — SAVE THIS NOW      ║
  ║   This key is stored in .env as CROWDSEC_CF_BOUNCER_API_KEY    ║
  ║   and in /etc/crowdsec/bouncers/crowdsec-cloudflare-bouncer.yaml║
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
        _cf_zone_id="${CLOUDFLARE_ZONE_ID:-}"
        _cf_account_id="${CF_ACCOUNT_ID:-}"
        _CF_FIREWALL_TOKEN=""

        if [[ "$AUTO_MODE" == "true" ]]; then
            # ───────────────────────────────────────────────────────────────
            # AUTO MODE: use env values or write placeholders; never prompt
            # ───────────────────────────────────────────────────────────────
            _cf_zone_id="${_cf_zone_id:-CHANGE_ME_CF_ZONE_ID}"
            _cf_account_id="${_cf_account_id:-CHANGE_ME_CF_ACCOUNT_ID}"
            _CF_FIREWALL_TOKEN="CHANGE_ME_CROWDSEC_CF_FIREWALL_TOKEN"
            log_warn "Auto mode: Cloudflare values left as placeholders where missing."
            log_warn "Set later in .env / sudo utilities/setup-secrets.sh rotate crowdsec_cf_firewall_token"
        else
            # ───────────────────────────────────────────────────────────────
            # INTERACTIVE MODE: resolve token from secrets before prompting
            # Priority order (highest → lowest):
            #   1. CROWDSEC_CF_FIREWALL_TOKEN set in environment / .env
            #   2. PROJECT_STATE_DIR docker secret file  (written by setup-secrets.sh)
            #   3. PROJECT_ROOT docker secret file       (legacy / dev path)
            #   4. Interactive prompt
            # ───────────────────────────────────────────────────────────────

            # 1. Env / .env
            _env_token="${CROWDSEC_CF_FIREWALL_TOKEN:-}"
            if [[ -n "$_env_token" && "$_env_token" != CHANGE_ME* && "$_env_token" != PLACEHOLDER* ]]; then
                _CF_FIREWALL_TOKEN="$_env_token"
                log_success "crowdsec_cf_firewall_token found in environment / .env — skipping prompt."
            fi

            # 2. PROJECT_STATE_DIR docker secret (canonical path written by setup-secrets.sh)
            if [[ -z "$_CF_FIREWALL_TOKEN" ]]; then
                _state_secret="${_project_state_dir}/secrets/.docker_secrets/crowdsec_cf_firewall_token"
                _CF_FIREWALL_TOKEN="$(_cs_read_secret_file "$_state_secret")"
                if [[ -n "$_CF_FIREWALL_TOKEN" ]]; then
                    log_success "crowdsec_cf_firewall_token found at ${_state_secret} — skipping prompt."
                fi
            fi

            # 3. PROJECT_ROOT docker secret (legacy / repo-local path)
            if [[ -z "$_CF_FIREWALL_TOKEN" ]]; then
                _repo_secret="${PROJECT_ROOT}/secrets/.docker_secrets/crowdsec_cf_firewall_token"
                _CF_FIREWALL_TOKEN="$(_cs_read_secret_file "$_repo_secret")"
                if [[ -n "$_CF_FIREWALL_TOKEN" ]]; then
                    log_success "crowdsec_cf_firewall_token found at ${_repo_secret} — skipping prompt."
                fi
            fi

            # 4. Interactive prompt — only when token was NOT resolved above
            if [[ -z "$_CF_FIREWALL_TOKEN" ]]; then
                log_info ""
                log_info "══════════════════════════════════════════════════════════"
                log_info " Cloudflare values required by CrowdSec bouncer"
                log_info "══════════════════════════════════════════════════════════"
                log_info " Required permissions: Zone:Firewall Services:Edit"
                log_info " Create at: https://dash.cloudflare.com/profile/api-tokens"
                log_info "══════════════════════════════════════════════════════════"

                while [[ -z "$_cf_zone_id" ]]; do
                    read -r -p "Enter CLOUDFLARE_ZONE_ID: " _cf_zone_id
                    [[ -z "$_cf_zone_id" ]] && log_warn "CLOUDFLARE_ZONE_ID cannot be empty."
                done
                if [[ -z "$_cf_account_id" ]]; then
                    read -r -p "Enter CF_ACCOUNT_ID (optional, press Enter to skip): " _cf_account_id
                fi

                while [[ -z "$_CF_FIREWALL_TOKEN" ]]; do
                    read -r -s -p "Enter Cloudflare Firewall API token (input hidden): " _CF_FIREWALL_TOKEN
                    echo ""
                    if [[ -z "$_CF_FIREWALL_TOKEN" ]]; then
                        log_warn "Token cannot be empty. Press Ctrl+C to skip and configure later."
                    fi
                done
                log_success "Cloudflare firewall token accepted."
            fi

            _cs_set_env_var "CLOUDFLARE_ZONE_ID" "$_cf_zone_id"
            [[ -n "$_cf_account_id" ]] && _cs_set_env_var "CF_ACCOUNT_ID" "$_cf_account_id"
        fi

        mkdir -p /etc/crowdsec/bouncers
        sed \
            -e "s|TOKEN_CF_ZONE_ID|${_cf_zone_id}|g" \
            -e "s|TOKEN_CF_ACCOUNT_ID|${_cf_account_id:-CHANGE_ME_CF_ACCOUNT_ID}|g" \
            -e "s|TOKEN_CROWDSEC_CF_FIREWALL_TOKEN|${_CF_FIREWALL_TOKEN}|g" \
            -e "s|CHANGE_ME_BOUNCER_KEY|${_CF_BOUNCER_KEY}|g" \
            "$_CF_BOUNCER_CONFIG_SRC" \
            | tee "$_CF_BOUNCER_CONFIG_DEST" >/dev/null
        chmod 600 "$_CF_BOUNCER_CONFIG_DEST"
        log_success "Cloudflare bouncer config written to ${_CF_BOUNCER_CONFIG_DEST} (mode 600)."

        # Persist/update the canonical flat secret file so re-runs are prompt-free.
        _cf_secret_dir="${_project_state_dir}/secrets/.docker_secrets"
        mkdir -p "$_cf_secret_dir"
        if [[ -n "$_CF_FIREWALL_TOKEN" && "$_CF_FIREWALL_TOKEN" != CHANGE_ME* && "$_CF_FIREWALL_TOKEN" != PLACEHOLDER* ]]; then
            if [[ ! -f "${_cf_secret_dir}/crowdsec_cf_firewall_token" ]] || ! cmp -s <(printf "%s\n" "$_CF_FIREWALL_TOKEN") "${_cf_secret_dir}/crowdsec_cf_firewall_token"; then
                printf "%s\n" "$_CF_FIREWALL_TOKEN" > "${_cf_secret_dir}/crowdsec_cf_firewall_token"
                chmod 444 "${_cf_secret_dir}/crowdsec_cf_firewall_token"
                log_success "Saved Cloudflare firewall token to ${_cf_secret_dir}/crowdsec_cf_firewall_token"
            fi
        fi

        if _cf_bouncer_service_exists; then
            systemctl enable crowdsec-cloudflare-bouncer || true
            systemctl reset-failed crowdsec-cloudflare-bouncer 2>/dev/null || true
            systemctl restart crowdsec-cloudflare-bouncer || true

            _cf_bouncer_ready=false
            for _i in {1..10}; do
                if systemctl is-active --quiet crowdsec-cloudflare-bouncer; then
                    _cf_bouncer_ready=true
                    break
                fi
                sleep 1
            done

            if [[ "$_cf_bouncer_ready" == "true" ]]; then
                log_success "crowdsec-cloudflare-bouncer is active."
            else
                log_warn "crowdsec-cloudflare-bouncer did not report active within 10s; continuing setup."
            fi
        else
            log_warn "crowdsec-cloudflare-bouncer.service unit not found — binary may need manual installation."
            log_warn "Once installed, run: sudo systemctl enable --now crowdsec-cloudflare-bouncer"
        fi
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
    systemctl reload crowdsec                        || true
    systemctl enable --now crowdsec-firewall-bouncer || true
    # Only enable the Cloudflare bouncer if its service unit is present.
    if _cf_bouncer_service_exists; then
        systemctl enable --now crowdsec-cloudflare-bouncer || true
    else
        log_warn "Skipping crowdsec-cloudflare-bouncer enable — service unit not installed yet."
    fi
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
log_info "  2. Cloudflare firewall token is stored at:"
log_info "       ${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/secrets/.docker_secrets/crowdsec_cf_firewall_token"
log_info "     Rotate manually by re-running this script if needed."
log_info "  3. Verify CrowdSec metrics:"
log_info "       sudo cscli metrics"
log_info "  4. After setting tokens, restart the Cloudflare bouncer:"
log_info "       sudo systemctl restart crowdsec-cloudflare-bouncer"
log_info "════════════════════════════════════════════════════════"
