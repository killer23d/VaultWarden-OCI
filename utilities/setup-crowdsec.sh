#!/usr/bin/env bash
# utilities/setup-crowdsec.sh — Installs and configures CrowdSec and its bouncers for VaultWarden-OCI.

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

_LIBS_LOADED=false
if [[ -f "${PROJECT_ROOT}/lib/log.sh" ]]; then
    # shellcheck source=../lib/log.sh
    source "${PROJECT_ROOT}/lib/log.sh"
fi
if [[ -f "${PROJECT_ROOT}/lib/config.sh" ]]; then
    # shellcheck source=../lib/config.sh
    source "${PROJECT_ROOT}/lib/config.sh"
fi
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
    # Fall back to minimal logging when lib/common.sh is unavailable.
    log_info()    { printf '[INFO]    crowdsec %s\n'    "$*"; }
    log_success() { printf '[SUCCESS] crowdsec %s\n'    "$*"; }
    log_warn()    { printf '[WARN]    crowdsec %s\n'    "$*" >&2; }
    log_error()   { printf '[ERROR]   crowdsec %s\n'    "$*" >&2; }
fi

# Provide COLOR_* fallbacks for standalone runs without lib/common.sh.
if [[ "$_LIBS_LOADED" != "true" ]]; then
    COLOR_RED=$'\033[0;31m'
    COLOR_GREEN=$'\033[0;32m'
    # shellcheck disable=SC2034  # COLOR_YELLOW/COLOR_CYAN may be used by sourcing scripts or future expansions
    COLOR_YELLOW=$'\033[0;33m'
    # shellcheck disable=SC2034
    COLOR_CYAN=$'\033[0;36m'
    COLOR_RESET=$'\033[0m'
fi

if [[ -f "${PROJECT_ROOT}/.env" ]]; then
    if declare -f load_env_file >/dev/null 2>&1; then
        load_env_file "${PROJECT_ROOT}/.env" || true
    else
        # shellcheck disable=SC1091
        source "${PROJECT_ROOT}/.env" 2>/dev/null || true
    fi
fi

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

# Read a token from a flat secret file and reject placeholder values.
_cs_read_secret_file() {
    local path="$1"
    [[ -f "$path" ]] || return 0
    [[ -r "$path" ]] || return 0
    local val
    # Read only the first line and preserve the token except for surrounding whitespace.
    IFS= read -r val < "$path" || true
    val="${val#${val%%[![:space:]]*}}"
    val="${val%${val##*[![:space:]]}}"
    if [[ -n "$val" && "$val" != CHANGE_ME* && "$val" != PLACEHOLDER* ]]; then
        printf '%s' "$val"
    fi
}

AUTO_MODE=false
DRY_RUN=false
FORCE=false
# When USE_LATEST=true the script queries live upstream for the current latest
# release of each component. By default (USE_LATEST=false) the pinned versions
# below are used, which is safer for a "set-and-forget" deployment.
USE_LATEST=false
# IP or CIDR to add to the CrowdSec admin allowlist.
# Auto-detected from the SSH session when not provided via --admin-ip.
ADMIN_IP=""

# ---------------------------------------------------------------------------
# Dependency version pins.
# Set a version string (e.g. "1.6.3") to install that exact release.
# Leave blank ("") to let the package manager / GitHub API select the latest
# stable.  When USE_LATEST=true these pins are ignored entirely.
#
# Examples:
#   CROWDSEC_VERSION="1.6.3"
#   CF_BOUNCER_VERSION="v0.0.14"
# ---------------------------------------------------------------------------
CROWDSEC_VERSION="${CROWDSEC_VERSION:-}"
CF_BOUNCER_VERSION="${CF_BOUNCER_VERSION:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)        AUTO_MODE=true; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --force)       FORCE=true; shift ;;
        --use-latest)  USE_LATEST=true; shift ;;
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
                       release of each component (crowdsec, cloudflare-bouncer).
                       By default the pinned versions in CROWDSEC_VERSION /
                       CF_BOUNCER_VERSION are used for reproducibility.
  --admin-ip IP|CIDR   Add this IP address or CIDR to the CrowdSec admin
                       allowlist (e.g. 203.0.113.42 or 203.0.113.0/24).
                       When omitted, the script auto-detects your SSH client IP
                       from the environment (SSH_CLIENT) and prompts for
                       confirmation in interactive mode.
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

_cs_run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] $*"
    else
        "$@"
    fi
}

_cf_bouncer_service_exists() {
    systemctl list-unit-files crowdsec-cloudflare-bouncer.service 2>/dev/null \
        | grep -q 'crowdsec-cloudflare-bouncer.service'
}

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
        # Use the pinned version when one is configured and --use-latest is not set.
        _cs_pkg="crowdsec"
        if [[ "$USE_LATEST" != "true" && -n "$CROWDSEC_VERSION" ]]; then
            _cs_pkg="crowdsec=${CROWDSEC_VERSION}"
            log_info "CrowdSec version pinned: ${CROWDSEC_VERSION}"
        else
            log_info "CrowdSec version: installing latest from packagecloud repository"
        fi
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            "$_cs_pkg" \
            crowdsec-firewall-bouncer-iptables
    fi
fi

if [[ "$DRY_RUN" != "true" ]]; then
    systemctl enable --now crowdsec || true
    log_success "CrowdSec service enabled and started."
fi

log_info "=== PHASE 2: Cloudflare bouncer installation ==="

_CF_PROXY_ENABLED="${CLOUDFLARE_PROXY_ENABLED:-false}"
_CF_BOUNCER_BIN="/usr/local/bin/crowdsec-cloudflare-bouncer"
_CF_BOUNCER_NEEDS_INSTALL=false

if [[ "$_CF_PROXY_ENABLED" != "true" ]]; then
    log_warn "Skipping crowdsec-cloudflare-bouncer setup — CLOUDFLARE_PROXY_ENABLED is not 'true'."
    log_warn "Set CLOUDFLARE_PROXY_ENABLED=true in .env and re-run this script to enable the Cloudflare bouncer."
elif [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would install crowdsec-cloudflare-bouncer (deb → tarball → go source fallback)"
else
    # Register the bouncer API key in CrowdSec LAPI.
    if ! cscli bouncers list 2>/dev/null | grep -q 'cloudflare-bouncer' || [[ "$FORCE" == "true" ]]; then
        log_info "Updating CrowdSec hub..."
        cscli hub update || true
        log_info "Registering Cloudflare bouncer in CrowdSec LAPI..."
        cscli bouncers add crowdsecurity/cloudflare-bouncer 2>/dev/null || true
    else
        log_info "CrowdSec Cloudflare bouncer already registered — skipping."
    fi

    # Determine whether the binary must be installed.
    if [[ ! -x "$_CF_BOUNCER_BIN" ]] || [[ "$FORCE" == "true" ]]; then
        _CF_BOUNCER_NEEDS_INSTALL=true
    fi

    if [[ "$_CF_BOUNCER_NEEDS_INSTALL" == "true" ]]; then
        log_info "Cloudflare bouncer binary not found — attempting installation..."

        # Normalize the architecture name used by package assets.
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

        # Try packagecloud apt/deb first.
        # The CrowdSec repo is already added earlier, and the package installs
        # both the binary and the systemd unit in one step.
        if [[ -n "$_arch" ]]; then
            log_info "Attempting apt install of crowdsec-cloudflare-bouncer..."
            if DEBIAN_FRONTEND=noninteractive apt-get install -y crowdsec-cloudflare-bouncer 2>/dev/null; then
                log_success "Installed crowdsec-cloudflare-bouncer via apt."
                _installed_via_deb=true
            else
                log_warn "apt install failed — falling back to GitHub release tarball."
            fi
        fi

        # Fall back to the latest GitHub release tarball.
        # The tarball ships install.sh and helper scripts that must run from the
        # extracted directory because they rely on relative paths.
        if [[ "$_installed_via_deb" == "false" ]] && [[ -n "$_arch" ]]; then
            # Resolve the GitHub API URL: use a pinned tag when configured and
            # --use-latest is not active; otherwise query releases/latest.
            if [[ "$USE_LATEST" != "true" && -n "$CF_BOUNCER_VERSION" ]]; then
                _gh_api="https://api.github.com/repos/crowdsecurity/cs-cloudflare-bouncer/releases/tags/${CF_BOUNCER_VERSION}"
                log_info "CF bouncer version pinned: ${CF_BOUNCER_VERSION}"
            else
                _gh_api="https://api.github.com/repos/crowdsecurity/cs-cloudflare-bouncer/releases/latest"
                log_info "CF bouncer version: resolving latest from GitHub"
            fi
            _release_json="$(curl -fsSL "$_gh_api" 2>/dev/null)" || {
                log_warn "Failed to query GitHub releases for cs-cloudflare-bouncer."
                _release_json=""
            }

            if [[ -n "$_release_json" ]]; then
                # Asset filenames use hyphens, such as crowdsec-cloudflare-bouncer-linux-arm64.tgz.
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

                        # Verify the tarball when a SHA256 asset is available.
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

                            # Locate install.sh anywhere in the extracted tree.
                            _install_sh="$(find "$_tmpdir" -maxdepth 2 -name 'install.sh' | head -1 || true)"

                            if [[ -n "$_install_sh" && -f "$_install_sh" ]]; then
                                _install_dir="$(dirname "$_install_sh")"
                                log_info "Running bundled installer from: $_install_dir"
                                # cd into the extracted directory because install.sh uses
                                # relative paths such as ./scripts/_bouncer.sh.
                                if (cd "$_install_dir" && bash install.sh); then
                                    log_success "Installed cs-cloudflare-bouncer via tarball install.sh."
                                else
                                    log_warn "Bundled install.sh failed — will attempt manual binary extraction."
                                    # Fall back to copying the binary manually and writing a unit file.
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

        # Use a Go source build as the last resort.
        if [[ -n "$_arch" ]] && [[ ! -x "$_CF_BOUNCER_BIN" ]]; then
            if command -v go >/dev/null 2>&1; then
                log_info "Attempting Go source build for crowdsec-cloudflare-bouncer..."
                # Respect the version pin: use a specific tag when set and
                # --use-latest is not active, otherwise fall back to @latest.
                if [[ "$USE_LATEST" != "true" && -n "$CF_BOUNCER_VERSION" ]]; then
                    _go_pkg_ref="github.com/crowdsecurity/cs-cloudflare-bouncer/cmd/crowdsec-cloudflare-bouncer@${CF_BOUNCER_VERSION}"
                else
                    _go_pkg_ref="github.com/crowdsecurity/cs-cloudflare-bouncer/cmd/crowdsec-cloudflare-bouncer@latest"
                fi
                _tmpgobin="$(mktemp -d -p /tmp cs-cf-go.XXXXXX)"
                if GOBIN="$_tmpgobin" go install "$_go_pkg_ref" 2>/dev/null; then
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

        # Write the systemd unit when a binary exists but no unit was installed.
        # This covers the Go-build path and tarballs that skip install.sh.
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

log_info "=== PHASE 5: Bouncer API key ==="

_CF_BOUNCER_KEY=""
_CF_BOUNCER_ENV_KEY="CROWDSEC_CF_BOUNCER_API_KEY"

if [[ "$_CF_PROXY_ENABLED" != "true" ]]; then
    log_warn "Skipping bouncer API key generation — CLOUDFLARE_PROXY_ENABLED is not 'true'."
elif [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would generate and register a bouncer API key, write to .env as ${_CF_BOUNCER_ENV_KEY}"
    _CF_BOUNCER_KEY="DRY_RUN_PLACEHOLDER"
else
    # Reuse the key from .env when it is already present and registered.
    _existing_key="${CROWDSEC_CF_BOUNCER_API_KEY:-}"
    if [[ -n "$_existing_key" ]] && cscli bouncers list 2>/dev/null | grep -q 'cloudflare-bouncer' && [[ "$FORCE" != "true" ]]; then
        log_info "Bouncer API key already present in .env — skipping key generation."
        _CF_BOUNCER_KEY="$_existing_key"
    else
        log_info "Generating new bouncer API key..."
        _new_key="$(openssl rand -hex 32)"
        # Remove any stale registration first so the re-add stays idempotent.
        cscli bouncers delete cloudflare-bouncer 2>/dev/null || true
        cscli bouncers add cloudflare-bouncer --key "$_new_key" 2>/dev/null || {
            log_warn "cscli bouncers add failed — CrowdSec LAPI may not be running yet. Key stored in .env for later."
        }
        _CF_BOUNCER_KEY="$_new_key"
        _cs_set_env_var "$_CF_BOUNCER_ENV_KEY" "$_CF_BOUNCER_KEY"
        log_success "Bouncer API key generated and registered. Written to .env as ${_CF_BOUNCER_ENV_KEY}."
        # Display the newly generated key in a high-visibility credential banner.
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

log_info "=== PHASE 6: Cloudflare bouncer config ==="

_CF_BOUNCER_CONFIG_SRC="${PROJECT_ROOT}/crowdsec/crowdsec-cloudflare-bouncer.yaml.example"
_CF_BOUNCER_CONFIG_DEST="/etc/crowdsec/bouncers/crowdsec-cloudflare-bouncer.yaml"

if [[ -f "$_CF_BOUNCER_CONFIG_SRC" ]]; then
    if [[ "$_CF_PROXY_ENABLED" != "true" ]]; then
        log_warn "Skipping Cloudflare bouncer config write — CLOUDFLARE_PROXY_ENABLED is not 'true'."
    elif [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would write ${_CF_BOUNCER_CONFIG_DEST} from ${_CF_BOUNCER_CONFIG_SRC}"
    else
        _cf_zone_id="${CLOUDFLARE_ZONE_ID:-}"
        _cf_account_id="${CF_ACCOUNT_ID:-}"
        _CF_FIREWALL_TOKEN=""

        if [[ "$AUTO_MODE" == "true" ]]; then
            # In auto mode, use available values or write placeholders and never prompt.
            _cf_zone_id="${_cf_zone_id:-CHANGE_ME_CF_ZONE_ID}"
            _cf_account_id="${_cf_account_id:-CHANGE_ME_CF_ACCOUNT_ID}"
            _CF_FIREWALL_TOKEN="CHANGE_ME_CROWDSEC_CF_FIREWALL_TOKEN"
            log_warn "Auto mode: Cloudflare values left as placeholders where missing."
            log_warn "Set later in .env / sudo utilities/setup-secrets.sh rotate crowdsec_cf_firewall_token"
        else
            # In interactive mode, resolve the token before prompting.
            # Priority order, highest to lowest:
            #   1. CROWDSEC_CF_FIREWALL_TOKEN in the environment or .env.
            #   2. The PROJECT_STATE_DIR Docker secret file written by setup-secrets.sh.
            #   3. The PROJECT_ROOT Docker secret file for legacy or repo-local use.
            #   4. An interactive prompt.

            _env_token="${CROWDSEC_CF_FIREWALL_TOKEN:-}"
            if [[ -n "$_env_token" && "$_env_token" != CHANGE_ME* && "$_env_token" != PLACEHOLDER* ]]; then
                _CF_FIREWALL_TOKEN="$_env_token"
                log_success "crowdsec_cf_firewall_token found in environment / .env — skipping prompt."
            fi

            if [[ -z "$_CF_FIREWALL_TOKEN" ]]; then
                _state_secret="${_project_state_dir}/secrets/.docker_secrets/crowdsec_cf_firewall_token"
                _CF_FIREWALL_TOKEN="$(_cs_read_secret_file "$_state_secret")"
                if [[ -n "$_CF_FIREWALL_TOKEN" ]]; then
                    log_success "crowdsec_cf_firewall_token found at ${_state_secret} — skipping prompt."
                fi
            fi

            if [[ -z "$_CF_FIREWALL_TOKEN" ]]; then
                _repo_secret="${PROJECT_ROOT}/secrets/.docker_secrets/crowdsec_cf_firewall_token"
                _CF_FIREWALL_TOKEN="$(_cs_read_secret_file "$_repo_secret")"
                if [[ -n "$_CF_FIREWALL_TOKEN" ]]; then
                    log_success "crowdsec_cf_firewall_token found at ${_repo_secret} — skipping prompt."
                fi
            fi

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

        # Persist the canonical flat secret file so later runs stay prompt-free.
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
            log_warn "crowdsec-cloudflare-bouncer.service unit not found after install attempt — check logs above."
            log_warn "Once the binary is installed, run: sudo systemctl enable --now crowdsec-cloudflare-bouncer"
        fi
    fi
else
    log_warn "crowdsec-cloudflare-bouncer.yaml.example not found in ${PROJECT_ROOT}/crowdsec — skipping bouncer config write."
fi

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

log_info "=== PHASE 8: Enable and start services ==="

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would reload crowdsec and enable crowdsec-firewall-bouncer and crowdsec-cloudflare-bouncer"
else
    systemctl reload crowdsec                        || true
    systemctl enable --now crowdsec-firewall-bouncer || true
    # Only enable the Cloudflare bouncer when its unit exists and CF proxying is enabled.
    if [[ "$_CF_PROXY_ENABLED" != "true" ]]; then
        log_warn "Skipping crowdsec-cloudflare-bouncer enable — CLOUDFLARE_PROXY_ENABLED is not 'true'."
    elif _cf_bouncer_service_exists; then
        systemctl enable --now crowdsec-cloudflare-bouncer || true
        log_success "crowdsec-cloudflare-bouncer enabled and started."
    else
        log_warn "Skipping crowdsec-cloudflare-bouncer enable — service unit not installed yet."
    fi
    log_success "Services enabled."
fi

log_info "=== PHASE 9: Admin IP allowlist ==="

# The CrowdSec allowlist YAML parser file persists across hub updates and
# CrowdSec reinstalls, making it more durable than cscli decisions entries
# (which can be flushed). A separate file under s02-enrich ensures the admin
# IP is never blocked regardless of which detection rules are active.
_cs_whitelist_dir="/etc/crowdsec/parsers/s02-enrich"
_cs_whitelist_file="${_cs_whitelist_dir}/vaultwarden-admin-allowlist.yaml"
_cs_resolved_ip="$ADMIN_IP"

if [[ -z "$_cs_resolved_ip" ]]; then
    # SSH_CLIENT is injected by sshd as "client_ip client_port server_port".
    # It may not survive sudo depending on the env_keep configuration.
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
    # Validate: accept only characters valid in an IPv4/IPv6 address or CIDR.
    if [[ ! "$_cs_resolved_ip" =~ ^[0-9a-fA-F:./]+$ ]]; then
        log_warn "Ignoring admin IP '${_cs_resolved_ip}': unexpected characters detected."
        log_warn "Provide a plain IPv4/IPv6 address or CIDR (e.g. 203.0.113.42 or 203.0.113.0/24)."
    else
        # Choose the YAML key based on whether the value includes a prefix length.
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
            # The parser name must match a known CrowdSec hub whitelist entry so
            # the engine recognises it; crowdsecurity/whitelists is the standard one.
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

            # Reload CrowdSec so the new parser whitelist takes effect immediately.
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
