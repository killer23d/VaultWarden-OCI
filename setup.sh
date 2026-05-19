#!/usr/bin/env bash
# setup.sh - VaultWarden-OCI Setup Script

set -euo pipefail

# =============================================================================
# DEPENDENCY VERSION PINS
# To pin a specific version, set the variable. Leave blank ("") to auto-resolve
# the latest release at runtime via the GitHub API.
#
# Examples:
#   SOPS_VERSION="v3.9.4"   <- pinned
#   SOPS_VERSION=""         <- auto-resolve latest (default)
#
# You may also override any of these from the environment before running:
#   SOPS_VERSION=v3.9.4 sudo ./setup.sh --domain ...
# =============================================================================
SOPS_VERSION="${SOPS_VERSION:-}"   # e.g. "v3.9.4" — leave blank for latest
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

old_umask=$(umask)
umask 077
TMP_WORKDIR=$(mktemp -d -t vw_setup.XXXXXXXXXX) || {
    echo "ERROR: Failed to create secure temporary directory" >&2
    exit 1
}
umask "$old_umask"
trap 'rm -rf "$TMP_WORKDIR"' EXIT
trap 'rm -rf "${TMP_WORKDIR:-}"; exit 130' INT
trap 'rm -rf "${TMP_WORKDIR:-}"; exit 143' TERM

REQUIRED_LIBS=("lib/common.sh" "lib/crypto.sh" "lib/docker.sh" "lib/backup-utils.sh" "lib/secrets.sh" "lib/storage.sh")
for lib in "${REQUIRED_LIBS[@]}"; do
    if [[ ! -f "$lib" ]]; then
        echo "ERROR: Required library not found: $lib" >&2
        exit 1
    fi
done

source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"
source "lib/docker.sh"
source "lib/backup-utils.sh"
source "lib/secrets.sh"
source "lib/storage.sh"

# ---------------------------------------------------------------------------
# _set_env_var KEY VALUE FILE
# Add or replace a KEY=VALUE line in an env file.
# If the key already exists (with any value), it is replaced in-place.
# If it does not exist, it is appended.
# ---------------------------------------------------------------------------
_set_env_var() {
    local key="$1" value="$2" file="$3"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        # Escape characters that are special in the sed replacement field:
        #   \   → must be escaped first to avoid double-escaping
        #   &   → refers to the matched pattern in sed replacement
        #   |   → our chosen delimiter; must be literal in the replacement
        local escaped_value
        escaped_value="${value//\\/\\\\}"
        escaped_value="${escaped_value//&/\\&}"
        escaped_value="${escaped_value//|/\\|}"
        sed -i "s|^${key}=.*|${key}=${escaped_value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

# ---------------------------------------------------------------------------
# _read_env_value KEY FILE
# Read a KEY=VALUE from an env file, stripping surrounding double or single
# quotes.  Returns an empty string when the key is absent or the file does
# not exist.
# ---------------------------------------------------------------------------
_read_env_value() {
    local key="$1" file="$2"
    [[ -f "$file" ]] || return 0
    grep -E "^${key}=" "$file" 2>/dev/null \
        | tail -1 | cut -d= -f2- | tr -d "\"'" || true
}

# Canonical list of units that receive a ReadWritePaths drop-in in separate-
# volume mode. Used by both _install_rwpaths_dropin() and the cleanup block
# in remove_units(). Update this list whenever a new managed unit is added.
readonly -a _VW_DROPIN_UNITS=(
    vaultwarden-maintenance.service
    vaultwarden-db-backup.service
    vaultwarden-full-backup.service
    vaultwarden-health.service
    vaultwarden-dns-update.service
    vaultwarden-firewall-update.service
    vaultwarden-notify-failure.service
    vaultwarden-maintenance.timer
    vaultwarden-db-backup.timer
    vaultwarden-full-backup.timer
    vaultwarden-health.timer
    vaultwarden-dns-update.timer
    vaultwarden-firewall-update.timer
)

DOMAIN=""
ADMIN_EMAIL=""
AUTO_MODE=false
USE_LATEST=false
SKIP_DEPS=false
FORCE=false
DRY_RUN=false
PHASE=""
PHASE_ARGS=()
ENTROPY_THRESHOLD=200
ENTROPY_MAX_WAIT=60
CLEAN_DOMAIN=""
# Storage mode variables (defaults; overridden by --data-device/--data-mount
# CLI flags or by DATA_VOLUME_DEVICE/DATA_VOLUME_MOUNT already set in the
# calling environment).
DATA_VOLUME_DEVICE="${DATA_VOLUME_DEVICE:-}"
DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-/mnt/vw-data}"
SETUP_LOCK_FILE=""

show_help() {
    cat << 'EOF'
VaultWarden-OCI Setup Tool — Security Hardened Edition

USAGE:
    sudo ./setup.sh install --domain DOMAIN --email EMAIL [OPTIONS]  # Full setup
    sudo ./setup.sh --domain DOMAIN --email EMAIL [OPTIONS]          # Full setup (legacy)
    sudo ./setup.sh secrets [OPTIONS]                                # Secrets phase only
    sudo ./setup.sh systemd <install|remove|validate|status> [OPTIONS]  # Systemd phase

SUBCOMMANDS:
    install    Run the full setup workflow. This is the recommended explicit
               entry point; legacy top-level --domain/--email flags still work.
    secrets    Configure encrypted secrets (admin password, API tokens, SMTP, etc.)
               Run this after editing .env with your Cloudflare zone / email settings.
    systemd    Install, validate, or remove VaultWarden systemd timers.
               Sub-actions: install | remove | validate | status

FULL SETUP OPTIONS (used after install or with top-level --domain / --email):
  --auto              Non-interactive install. Auto-generates passwords/passphrases;
                      external credentials (CF tokens, SMTP) remain as CHANGE_ME
                      placeholders — the post-install summary lists exact commands
                      to rotate them. Does NOT imply --use-latest.
  --use-latest        Override pinned container versions with 'latest' tags in .env.
  --skip-deps         Skip dependency installation (assumes already installed).
  --force             Overwrite existing .env, secrets, and docker-compose files.
                      WARNING: Also regenerates the Age encryption key. All
                      existing encrypted secrets become permanently unrecoverable
                      without a prior recovery kit export. Run
                      './edit-secrets.sh export-recovery-kit' BEFORE using
                      --force on a running installation. To confirm you understand,
                      set VW_FORCE_ACK=I_UNDERSTAND_LOSING_OLD_BACKUPS in the
                      environment (or answer 'yes' at the interactive prompt).
  --dry-run           Print what would happen without making any changes.
  --data-device DEV   Use DEV as the dedicated VaultWarden data volume.
                      The device is formatted (ext4, first run only) and
                      mounted at DATA_VOLUME_MOUNT. A Docker systemd drop-in
                      ensures the stack never starts without this mount.
                      Example: --data-device /dev/sdb
  --data-mount PATH   Mount point for the data volume (default: /mnt/vw-data).
                      Must match PROJECT_STATE_DIR when DATA_VOLUME_DEVICE is set.

GLOBAL OPTIONS:
  --help, -h          Show this help and exit.

EXAMPLES:
    # ── First-time setup ──────────────────────────────────────────
    sudo ./setup.sh install --domain vault.example.com --email admin@example.com
    sudo ./setup.sh install --domain vault.example.com --email admin@example.com --auto

    # ── Secrets configuration ─────────────────────────────────────
    ./setup.sh secrets                   # Interactive credential setup
    ./setup.sh secrets --auto            # Automated with generated passwords
    ./setup.sh secrets --force           # Reconfigure without prompting
    ./setup.sh secrets --skip-optional   # Skip push notification keys
    ./setup.sh secrets --export-recovery-kit

    # ── Systemd timer management ──────────────────────────────────
    sudo ./setup.sh systemd install      # Install and enable all timers
    sudo ./setup.sh systemd validate     # Detect split-brain vs /opt/
    sudo ./setup.sh systemd status       # Show timer status
    sudo ./setup.sh systemd remove       # Disable and remove all timers
    sudo ./setup.sh systemd install --dry-run

EOF
}

# ---------------------------------------------------------------------------
# Argument Parsing — subcommand-first dispatch
# Pre-scan for positional subcommands before consuming regular --flags.
# The explicit `install` subcommand intentionally falls through to the same
# full-setup option parser used by the legacy top-level --domain/--email form.
# ---------------------------------------------------------------------------
_require_cli_value() {
    local opt="$1" value="${2-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        log_error "Option '$opt' requires a value."
        show_help
        exit 1
    fi
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        install)
            shift
            ;;
        secrets)
            PHASE="secrets"
            shift
            PHASE_ARGS=("$@")
            # Skip remaining flag parsing — PHASE_ARGS carries everything
            set --   # clear $@ so the while loop below is a no-op
            ;;
        systemd)
            PHASE="systemd"
            shift
            # Pass all remaining args positionally — run_phase_systemd
            # accepts install|remove|validate|status as positional sub-actions.
            PHASE_ARGS=("$@")
            set --
            ;;
        help|--help|-h)
            show_help; exit 0
            ;;
        --domain|--email|--auto|--use-latest|--skip-deps|--force|--dry-run|--data-device|--data-mount)
            # Legacy full-setup flag — fall through to the while loop below
            ;;
        *)
            log_error "Unknown subcommand: '$1'"
            log_error "Valid subcommands: install | secrets | systemd"
            log_error "For full setup use: sudo ./setup.sh install --domain DOMAIN --email EMAIL [OPTIONS]"
            log_error "Run './setup.sh --help' for usage."
            show_help; exit 1
            ;;
    esac
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)       _require_cli_value "$1" "${2-}"; DOMAIN="$2";              shift 2 ;;
        --email)        _require_cli_value "$1" "${2-}"; ADMIN_EMAIL="$2";         shift 2 ;;
        --auto)         AUTO_MODE=true;            shift ;;
        --use-latest)   USE_LATEST=true;           shift ;;
        --skip-deps)    SKIP_DEPS=true;            shift ;;
        --force)        FORCE=true;                shift ;;
        --dry-run)      DRY_RUN=true;              shift ;;
        --data-device)  _require_cli_value "$1" "${2-}"; DATA_VOLUME_DEVICE="$2";   shift 2 ;;
        --data-mount)   _require_cli_value "$1" "${2-}"; DATA_VOLUME_MOUNT="$2";    shift 2 ;;
        --help|-h)      show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# FORCE safety gate — must run before any validation so --dry-run --force
# can still preview without triggering the prompt.
# ---------------------------------------------------------------------------
if [[ "$FORCE" == "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
    if [[ "${VW_FORCE_ACK:-}" != "I_UNDERSTAND_LOSING_OLD_BACKUPS" ]]; then
        log_error "--force regenerates the Age key and permanently orphans all existing"
        log_error "encrypted backups unless you have first exported a recovery kit."
        log_error ""
        log_error "  Export your recovery kit FIRST: ./edit-secrets.sh export-recovery-kit"
        log_error ""
        log_error "If you have already done that, re-run with:"
        log_error "  VW_FORCE_ACK=I_UNDERSTAND_LOSING_OLD_BACKUPS sudo ./setup.sh --force ..."
        exit 2
    fi
    if [[ -t 0 ]]; then
        read -r -p "WARNING: This will rotate the Age key and can orphan old backups. Continue? [yes/NO] " _force_answer
        if [[ "$_force_answer" != "yes" ]]; then
            log_info "Aborting setup --force at operator request."
            exit 1
        fi
        unset _force_answer
    fi
fi

validate_domain_secure() {
    local domain="$1"
    if [[ ${#domain} -gt 253 ]]; then return 1; fi
    # Bare IPv4 addresses are rejected: production deployments require a proper
    # domain name so that Caddy can obtain a TLS certificate via ACME/HTTPS.
    if [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then return 1; fi
    if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then return 1; fi
    return 0
}

validate_email_secure() {
    local email="$1"
    if [[ ${#email} -gt 254 ]]; then return 1; fi
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then return 1; fi
    return 0
}

if [[ -z "$PHASE" ]] && { [[ -z "$DOMAIN" ]] || [[ -z "$ADMIN_EMAIL" ]]; }; then show_help; exit 1; fi
if [[ -z "$PHASE" ]] && ! validate_domain_secure "$DOMAIN"; then log_error "Invalid domain format"; exit 1; fi
if [[ -z "$PHASE" ]] && ! validate_email_secure "$ADMIN_EMAIL"; then log_error "Invalid email format"; exit 1; fi

resolve_github_latest() {
    local repo="$1"
    local tag

    # Use a temp file so curl errors are not silently swallowed by the pipe.
    local api_tmpfile
    api_tmpfile=$(mktemp -p "$TMP_WORKDIR" gh-latest.XXXXXXXXXX.json)

    if ! curl -fsSL --max-time 30 \
            "https://api.github.com/repos/${repo}/releases/latest" \
            -o "$api_tmpfile" 2>/dev/null; then
        log_error "Could not fetch release info for ${repo} from GitHub API."
        log_error "Set SOPS_VERSION=vX.Y.Z at the top of setup.sh to bypass."
        return 1
    fi

    tag=$(jq -r '.tag_name // empty' "$api_tmpfile")

    if [[ -z "$tag" ]] || [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9] ]]; then
        log_error "Could not resolve a valid release tag for ${repo}."
        log_error "Set SOPS_VERSION=vX.Y.Z at the top of setup.sh to bypass."
        return 1
    fi

    echo "$tag"
}

install_docker() {
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        log_info "setup" "Docker already installed: $(docker --version)"
        return 0
    fi

    local codename arch keyfile sources_file
    codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    arch=$(dpkg --print-architecture)
    keyfile="/etc/apt/keyrings/docker.asc"
    sources_file="/etc/apt/sources.list.d/docker.sources"

    log_info "setup" "Installing Docker via official apt repository (${codename} codename)..."

    install -m 0755 -d /etc/apt/keyrings

    rm -f /etc/apt/sources.list.d/docker.list
    rm -f /etc/apt/keyrings/docker.gpg

    if ! curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" -o "${keyfile}"; then
        log_error "setup" "Failed to download Docker GPG key"
        return 1
    fi
    chmod a+r "${keyfile}"

    local dearmored_key
    dearmored_key=$(mktemp -p "$TMP_WORKDIR" docker-key.XXXXXXXXXX.gpg)
    if ! gpg --dearmor < "${keyfile}" > "${dearmored_key}" 2>/dev/null; then
        log_error "setup" "Failed to dearmor Docker GPG key"
        rm -f "${dearmored_key}"
        return 1
    fi

    local got_fp
    got_fp=$(gpg --no-default-keyring \
        --keyring "gnupg-ring:${dearmored_key}" \
        --with-colons --fingerprint 2>/dev/null \
        | awk -F: '/^fpr/{print $10; exit}')
    rm -f "${dearmored_key}"

    local want_fp="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
    if [[ "${got_fp}" != "${want_fp}" ]]; then
        log_error "setup" "Docker GPG key fingerprint mismatch: got ${got_fp}, want ${want_fp}"
        return 1
    fi
    log_success "setup" "Docker GPG key fingerprint verified: ${want_fp}"

    cat > "${sources_file}" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${codename}
Components: stable
Architectures: ${arch}
Signed-By: ${keyfile}
EOF

    if ! apt-get update; then
        log_error "setup" "apt-get update failed after adding Docker repo"
        return 1
    fi

    if ! apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin; then
        log_error "setup" "Docker package installation failed"
        return 1
    fi

    systemctl enable --now docker
    log_success "setup" "Docker installed: $(docker --version)"
}

install_crowdsec() {    
    log_info "setup" "=== Installing CrowdSec (host service) ==="
    local _cs_state_dir
    if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then
        _cs_state_dir="${DATA_VOLUME_MOUNT:-/mnt/vw-data}"
    else
        _cs_state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    fi

    if ! command -v cscli >/dev/null 2>&1; then
        curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | sudo bash
        sudo apt-get install -y crowdsec crowdsec-firewall-bouncer-iptables
    else
        log_info "setup" "CrowdSec already installed, skipping base install."
    fi

    sudo systemctl enable --now crowdsec || true

    if ! sudo cscli bouncers list 2>/dev/null | grep -q 'cloudflare'; then
        sudo cscli hub update
        sudo cscli bouncers install crowdsecurity/cloudflare-bouncer || \
            log_warn "setup" "crowdsecurity/cloudflare-bouncer install failed — check 'sudo cscli hub list'"
    else
        log_info "setup" "CrowdSec Cloudflare bouncer already installed, skipping."
    fi

    sudo cscli collections install crowdsecurity/vaultwarden  || true
    sudo cscli collections install crowdsecurity/linux        || true
    sudo cscli collections install crowdsecurity/caddy        || true
    sudo cscli collections install crowdsecurity/http-cve     || true
    
    sudo mkdir -p /etc/crowdsec/acquis.d
    if [[ -f "${SCRIPT_DIR}/crowdsec/acquis.yaml" ]]; then
        sed "s|TOKEN_PROJECT_STATE_DIR|${_cs_state_dir}|g" \
            "${SCRIPT_DIR}/crowdsec/acquis.yaml" \
            | sudo tee /etc/crowdsec/acquis.d/vaultwarden.yaml >/dev/null
    else
        log_warn "setup" "crowdsec/acquis.yaml not found in ${SCRIPT_DIR} — skipping acquis config"
    fi

    local _cf_bouncer_key=""
    _cf_bouncer_key=$(sudo cscli bouncers add cloudflare-bouncer \
        --key "$(openssl rand -hex 32)" 2>/dev/null | grep -oP '(?<=key: )\S+' || \
        sudo cscli bouncers list 2>/dev/null | grep cloudflare-bouncer | awk '{print $NF}' || true)

    local _cf_token=""
    local _cf_secret_path="${_cs_state_dir}/secrets/.docker_secrets/fail2ban_cloudflare_firewall_token"
    if [[ -f "${_cf_secret_path}" ]]; then
        _cf_token=$(cat "${_cf_secret_path}")
    fi

    if [[ -f "${SCRIPT_DIR}/crowdsec/crowdsec-cloudflare-bouncer.yaml.example" ]]; then
        sed \
            -e "s|TOKEN_CF_ZONE_ID|${CLOUDFLARE_ZONE_ID:-CHANGE_ME_CF_ZONE_ID}|g" \
            -e "s|TOKEN_CF_ACCOUNT_ID|${CF_ACCOUNT_ID:-CHANGE_ME_CF_ACCOUNT_ID}|g" \
            -e "s|TOKEN_CF_FIREWALL_TOKEN|${_cf_token}|g" \
            -e "s|CHANGE_ME_BOUNCER_KEY|${_cf_bouncer_key}|g" \
            "${SCRIPT_DIR}/crowdsec/crowdsec-cloudflare-bouncer.yaml.example" \
            | sudo tee /etc/crowdsec/bouncers/crowdsec-cloudflare-bouncer.yaml >/dev/null
        sudo chmod 600 /etc/crowdsec/bouncers/crowdsec-cloudflare-bouncer.yaml
    else
        log_warn "setup" "crowdsec-cloudflare-bouncer.yaml.example not found — skipping bouncer config write"
    fi

    if [[ -f "${SCRIPT_DIR}/crowdsec/profiles.yaml" ]]; then
        sudo cp "${SCRIPT_DIR}/crowdsec/profiles.yaml" /etc/crowdsec/profiles.yaml
    fi

    sudo systemctl enable --now crowdsec
    sudo systemctl enable --now crowdsec-firewall-bouncer    || true
    sudo systemctl enable --now crowdsec-cloudflare-bouncer  || true

    log_success "setup" "CrowdSec installed and running."
    log_info "setup" "Verify with: sudo cscli metrics"
}

check_disk_space() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would check disk space"; return 0; fi

    local min_free_kb=$((2 * 1024 * 1024))   # 2 GiB in KiB
    local available_kb
    available_kb=$(df -k "$PROJECT_ROOT" | awk 'NR==2 {print $4}')

    if (( available_kb < min_free_kb )); then
        log_error "Insufficient disk space on $PROJECT_ROOT. Required: 2 GiB, Available: $(( available_kb / 1024 )) MiB"
        return 1
    fi
    log_info "Disk space OK on $PROJECT_ROOT: $(( available_kb / 1024 )) MiB available"

    local docker_root="/var/lib/docker"
    if [[ -d "$docker_root" ]]; then
        local docker_available_kb
        docker_available_kb=$(df -k "$docker_root" | awk 'NR==2 {print $4}')
        if (( docker_available_kb < min_free_kb )); then
            log_error "Insufficient disk space on $docker_root. Required: 2 GiB, Available: $(( docker_available_kb / 1024 )) MiB"
            return 1
        fi
        log_info "Disk space OK on $docker_root: $(( docker_available_kb / 1024 )) MiB available"
    else
        log_info "/var/lib/docker does not exist yet — skipping Docker data-root space check"
    fi

    # In separate-volume mode, check the data volume only if it is already
    # mounted (idempotent re-runs; first-run mounts happen in setup_data_volume).
    local dv_mount="${DATA_VOLUME_MOUNT:-}"
    if [[ -n "${DATA_VOLUME_DEVICE:-}" && -n "$dv_mount" ]] && \
       mountpoint -q "$dv_mount" 2>/dev/null; then
        local dv_available_kb
        dv_available_kb=$(df -k "$dv_mount" | awk 'NR==2 {print $4}')
        if (( dv_available_kb < min_free_kb )); then
            log_error "Insufficient disk space on data volume $dv_mount. Required: 2 GiB, Available: $(( dv_available_kb / 1024 )) MiB"
            return 1
        fi
        log_info "Disk space OK on $dv_mount (data volume): $(( dv_available_kb / 1024 )) MiB available"
    fi

    return 0
}

create_swapfile() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would create swapfile if needed"; return 0; fi

    if swapon --show | grep -q .; then
        log_info "Swap already active — skipping swapfile creation"
        return 0
    fi

    local swapfile="/swapfile"
    log_info "No swap detected — creating 1 GiB swapfile at ${swapfile}..."

    fallocate -l 1G "$swapfile" || dd if=/dev/zero of="$swapfile" bs=1M count=1024 status=none || return 1
    chmod 600 "$swapfile"
    mkswap "$swapfile" >/dev/null || return 1
    swapon "$swapfile" || return 1

    if ! grep -q "^${swapfile}" /etc/fstab 2>/dev/null; then
        echo "${swapfile} none swap sw 0 0" >> /etc/fstab
    fi

    sysctl -q vm.swappiness=10 || true
    if ! grep -q "^vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
        echo "vm.swappiness=10" >> /etc/sysctl.conf
    fi

    log_success "Swapfile created and activated (1 GiB)"
    return 0
}

install_dependencies() {
    if [[ "$SKIP_DEPS" == "true" ]]; then return 0; fi
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would install dependencies"; return 0; fi

    log_info "Installing system dependencies..."

    if ! grep -qE '^deb[[:space:]].*universe' \
            /etc/apt/sources.list \
            /etc/apt/sources.list.d/*.list 2>/dev/null && \
       ! grep -qE '^Components:.*\buniverse\b' \
            /etc/apt/sources.list.d/*.sources 2>/dev/null; then
        log_info "Enabling Ubuntu 'universe' repository (required for python3-argon2)..."
        if command -v add-apt-repository >/dev/null 2>&1; then
            add-apt-repository -y universe 2>/dev/null || {
                log_warn "add-apt-repository failed — adding universe source manually"
                local arch; arch=$(dpkg --print-architecture)
                local archive_url
                local codename
                codename=$(lsb_release -cs 2>/dev/null || echo "noble")
                if [[ "$arch" == "arm64" || "$arch" == "armhf" ]]; then
                    archive_url="http://ports.ubuntu.com/ubuntu-ports"
                else
                    archive_url="http://archive.ubuntu.com/ubuntu"
                fi
                echo "deb ${archive_url} ${codename} universe" \
                    > /etc/apt/sources.list.d/ubuntu-universe.list
                apt-get update -qq || return 1
            }
        else
            local arch; arch=$(dpkg --print-architecture)
            local archive_url
            local codename
            codename=$(lsb_release -cs 2>/dev/null || echo "noble")
            if [[ "$arch" == "arm64" || "$arch" == "armhf" ]]; then
                archive_url="http://ports.ubuntu.com/ubuntu-ports"
            else
                archive_url="http://archive.ubuntu.com/ubuntu"
            fi
            echo "deb ${archive_url} ${codename} universe" \
                > /etc/apt/sources.list.d/ubuntu-universe.list
            apt-get update -qq || return 1
        fi
        log_success "Universe repository enabled"
    fi

    local basic_packages=("age" "make" "nano" "rclone" "sqlite3" "jq" "ufw" "curl" "wget" "unzip" "git" "gpg" "coreutils" "haveged" "dnsutils" "rsync" "python3" "python3-argon2" "apache2-utils" "cron")
    # NOTE: haveged is a userspace entropy daemon included for compatibility with
    # kernels < 5.6 where /dev/random could block.  On Ubuntu 22.04/24.04 LTS
    # (kernel 5.15/6.8) it is a no-op overhead but harmless.  Kept to support
    # any operator who runs on an older kernel variant.
    local missing_packages=()
    for pkg in "${basic_packages[@]}"; do
        ! dpkg -s "$pkg" >/dev/null 2>&1 && missing_packages+=("$pkg")
    done

    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        apt-get update -qq || return 1
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}" || return 1
    fi

    if ! systemctl is-active --quiet haveged; then
        systemctl enable haveged 2>/dev/null || true
        systemctl start haveged || log_warn "Failed to start haveged"
    fi

    if ! command -v docker >/dev/null 2>&1; then
        install_docker || return 1
    fi

    install_crowdsec || return 1

    if ! docker compose version >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin || return 1
    fi

    if ! command -v sops >/dev/null 2>&1; then
        local arch; arch=$(dpkg --print-architecture)
        [[ "$arch" == "armhf" ]] && arch="arm"

        local sops_ver="${SOPS_VERSION:-}"
        if [[ -n "$sops_ver" ]]; then
            if [[ ! "$sops_ver" =~ ^v[0-9]+\.[0-9]+\.[0-9] ]]; then
                log_error "SOPS_VERSION '${sops_ver}' does not match expected format vX.Y.Z — aborting."
                return 1
            fi
            log_info "Using pinned SOPS version: ${sops_ver}"
        else
            log_info "SOPS_VERSION not pinned — resolving latest from GitHub..."
            sops_ver=$(resolve_github_latest "getsops/sops") || return 1
        fi

        log_info "Installing SOPS ${sops_ver} with checksum verification..."

        local sops_filename="sops-${sops_ver}.linux.${arch}"
        local base_url="https://github.com/getsops/sops/releases/download/${sops_ver}"
        local sops_bin="$TMP_WORKDIR/${sops_filename}"
        local sops_checksums="$TMP_WORKDIR/sops-${sops_ver}.checksums.txt"

        wget -q "${base_url}/${sops_filename}"               -O "$sops_bin"       || {
            log_error "Failed to download SOPS binary: ${base_url}/${sops_filename}"
            return 1
        }
        wget -q "${base_url}/sops-${sops_ver}.checksums.txt" -O "$sops_checksums" || {
            log_error "Failed to download SOPS checksums: ${base_url}/sops-${sops_ver}.checksums.txt"
            return 1
        }

        local expected actual
        expected=$(grep "${sops_filename}$" "$sops_checksums" | awk '{print $1}')
        actual=$(sha256sum "$sops_bin" | awk '{print $1}')

        if [[ -z "$expected" ]]; then
            log_error "Could not find checksum entry for '${sops_filename}' in checksums file."
            log_error "The checksums file may not include this architecture/version combination."
            log_error "Pin SOPS_VERSION=vX.Y.Z at the top of setup.sh and retry."
            return 1
        fi

        if [[ "$expected" != "$actual" ]]; then
            log_error "SOPS checksum MISMATCH — refusing to install."
            log_error "  Expected: $expected"
            log_error "  Actual:   $actual"
            log_error "This may indicate a compromised download, MITM, or corrupted file."
            log_error "Pin SOPS_VERSION=vX.Y.Z and retry. Releases: https://github.com/getsops/sops/releases"
            return 1
        fi

        log_success "SOPS checksum verified: $expected"
        install -m 755 "$sops_bin" /usr/local/bin/sops || return 1
    fi
    return 0
}

verify_dependencies() {
    hash -r
    local required_commands=("age" "sops" "docker" "jq" "sqlite3" "ufw" "curl" "python3" "htpasswd")
    require_commands "${required_commands[@]}" || return 1
    python3 -c "from argon2 import PasswordHasher" 2>/dev/null || return 1
    docker compose version >/dev/null 2>&1 || return 1
    return 0
}

setup_user_permissions() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would configure user permissions"; return 0; fi

    local real_user; real_user=$(get_real_user)
    id "$real_user" >/dev/null 2>&1 || return 1

    # Ensure the docker group exists before attempting usermod.
    # On OCI instances where Docker binaries are pre-installed but the daemon
    # has never been started, the package postinst may not have created the
    # group yet on some OCI images. This matches Docker's post-install guidance:
    # https://docs.docker.com/engine/install/linux-postinstall/
    if ! getent group docker >/dev/null 2>&1; then
        log_info "'docker' group not found — creating it now"
        groupadd --system docker || return 1
        log_success "Created system group 'docker'"
    fi

    if ! groups "$real_user" | grep -q '\bdocker\b'; then
        usermod -aG docker "$real_user" || return 1
        log_success "Added ${real_user} to the 'docker' group"
        log_info "Note: group membership takes effect on next login / new shell for ${real_user}"
    fi

    find "$PROJECT_ROOT" -maxdepth 1 \
        ! -name 'secrets' \
        ! -path "$PROJECT_ROOT" \
        -exec chown --no-dereference "$real_user:$(id -g -n "$real_user")" {} \; 2>/dev/null || true

    return 0
}

detect_ssh_log_path() {
    local ssh_log_path="/var/log/secure"
    local os_id

    if [[ -f /etc/os-release ]]; then
        os_id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr -d "'")
        case "$os_id" in
            ol|rhel|centos|rocky|almalinux|fedora) ssh_log_path="/var/log/secure" ;;
            ubuntu|debian) ssh_log_path="/var/log/auth.log" ;;
            *)
                if [[ -f "/var/log/secure" ]]; then ssh_log_path="/var/log/secure"
                else ssh_log_path="/var/log/auth.log"; fi ;;
        esac
    fi
    echo "$ssh_log_path"
}

create_env_file() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would create .env file"; return 0; fi

    local env_file="$PROJECT_ROOT/.env"
    local env_template="$PROJECT_ROOT/.env.example"

    if [[ -f "$env_file" ]] && [[ "$FORCE" != "true" ]]; then
        local domain_matches=false email_matches=false latest_matches=false
        grep -qF "DOMAIN=$DOMAIN" "$env_file"       && domain_matches=true
        grep -qF "ADMIN_EMAIL=$ADMIN_EMAIL" "$env_file" && email_matches=true

        if [[ "$USE_LATEST" == "true" ]]; then
            if grep -qE '^VAULTWARDEN_VERSION=latest' "$env_file" && \
               grep -qE '^CADDY_VERSION=latest'       "$env_file" && \
               grep -qE '^POSTFIX_VERSION=latest'     "$env_file" && \
               grep -qE '^BUSYBOX_VERSION=latest'     "$env_file"; then
                latest_matches=true
            fi
        else
            if ! grep -qE '^(VAULTWARDEN|CADDY|POSTFIX|BUSYBOX)_VERSION=latest' "$env_file"; then
                latest_matches=true
            fi
        fi

        if [[ "$domain_matches" == "true" ]] && \
           [[ "$email_matches" == "true" ]] && \
           [[ "$latest_matches" == "true" ]]; then
            return 0
        fi
    fi

    local prev_umask; prev_umask=$(umask)
    umask 077
    cp "$env_template" "$env_file" || { umask "$prev_umask"; return 1; }
    umask "$prev_umask"

    local real_user; real_user=$(get_real_user)
    local user_id; user_id=$(id -u "$real_user")
    local group_id; group_id=$(id -g "$real_user")
    local detected_ssh_log_path; detected_ssh_log_path=$(detect_ssh_log_path 2>/dev/null)

    local domain_with_protocol
    [[ "$DOMAIN" =~ ^https?:// ]] && domain_with_protocol="$DOMAIN" || domain_with_protocol="https://$DOMAIN"

    local clean_domain; clean_domain=$(echo "$domain_with_protocol" | sed -E 's|https?://||; s|/.*$||')
    CLEAN_DOMAIN="$clean_domain"

    local temp_env=""
    temp_env=$(mktemp -p "$(dirname "$env_file")" .env.tmp.XXXXXXXXXX) || return 1

    # Compute PROJECT_STATE_DIR value: when a data volume is configured it MUST
    # equal ; otherwise use the default boot-volume location.
    local awk_state_dir
    if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then
        awk_state_dir="${DATA_VOLUME_MOUNT:-/mnt/vw-data}"
    else
        awk_state_dir="/var/lib/vaultwarden"
    fi

    AWK_DOMAIN="$domain_with_protocol" \
    AWK_EMAIL="$ADMIN_EMAIL" \
    AWK_UID="$user_id" \
    AWK_GID="$group_id" \
    AWK_SMTP_FROM="noreply@$clean_domain" \
    AWK_ALLOWED_SENDER_DOMAINS="$clean_domain" \
    AWK_SSH_LOG="$detected_ssh_log_path" \
    AWK_DATA_DEVICE="${DATA_VOLUME_DEVICE:-}" \
    AWK_DATA_MOUNT="${DATA_VOLUME_MOUNT:-/mnt/vw-data}" \
    AWK_STATE_DIR="$awk_state_dir" \
    awk '
        {
            sub(/^DOMAIN=.*/, "DOMAIN=" ENVIRON["AWK_DOMAIN"]);
            sub(/^ADMIN_EMAIL=.*/, "ADMIN_EMAIL=" ENVIRON["AWK_EMAIL"]);
            sub(/^PUID=.*/, "PUID=" ENVIRON["AWK_UID"]);
            sub(/^PGID=.*/, "PGID=" ENVIRON["AWK_GID"]);
            sub(/^SMTP_FROM=.*/, "SMTP_FROM=" ENVIRON["AWK_SMTP_FROM"]);
            sub(/^ALLOWED_SENDER_DOMAINS=.*/, "ALLOWED_SENDER_DOMAINS=" ENVIRON["AWK_ALLOWED_SENDER_DOMAINS"]);
            sub(/^SSH_LOG_PATH=.*/, "SSH_LOG_PATH=" ENVIRON["AWK_SSH_LOG"]);
            sub(/^DATA_VOLUME_DEVICE=.*/, "DATA_VOLUME_DEVICE=" ENVIRON["AWK_DATA_DEVICE"]);
            sub(/^DATA_VOLUME_MOUNT=.*/, "DATA_VOLUME_MOUNT=" ENVIRON["AWK_DATA_MOUNT"]);
            sub(/^PROJECT_STATE_DIR=.*/, "PROJECT_STATE_DIR=" ENVIRON["AWK_STATE_DIR"]);
            print;
        }' "$env_file" > "$temp_env"

    mv "$temp_env" "$env_file" || { rm -f "$temp_env"; return 1; }

    if [[ "$USE_LATEST" == "true" ]]; then
        temp_env=$(mktemp -p "$(dirname "$env_file")" .env.tmp.XXXXXXXXXX) || return 1
        awk '{
            sub(/^VAULTWARDEN_VERSION=.*/, "VAULTWARDEN_VERSION=latest");
            sub(/^CADDY_VERSION=.*/, "CADDY_VERSION=latest");
            sub(/^POSTFIX_VERSION=.*/, "POSTFIX_VERSION=latest");
            sub(/^BUSYBOX_VERSION=.*/, "BUSYBOX_VERSION=latest");
            print;
        }' "$env_file" > "$temp_env"
        mv "$temp_env" "$env_file" || { rm -f "$temp_env"; return 1; }
    fi

    # Ensure the canonical production Age key path is written to .env so the
    # verification in generate_age_keys() always succeeds on a clean install.
    temp_env=$(mktemp -p "$(dirname "$env_file")" .env.tmp.XXXXXXXXXX) || return 1
    awk '{
        sub(/^SOPS_AGE_KEY_FILE=.*/, "SOPS_AGE_KEY_FILE=/etc/vaultwarden/age-key.txt");
        print;
    }' "$env_file" > "$temp_env"
    mv "$temp_env" "$env_file" || { rm -f "$temp_env"; return 1; }

    # In separate-volume mode, auto-populate BACKUP_DIR if it is currently
    # blank in .env.  This ensures backup.sh finds backups on the data volume
    # without the operator having to manually edit the file.  An explicit
    # BACKUP_DIR already set by the operator is left untouched.
    if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then
        local current_backup_dir
        current_backup_dir=$(_read_env_value "BACKUP_DIR" "$env_file")
        if [[ -z "$current_backup_dir" ]]; then
            _set_env_var "BACKUP_DIR" "${DATA_VOLUME_MOUNT:-/mnt/vw-data}/backups" "$env_file"
            log_info "Auto-set BACKUP_DIR=${DATA_VOLUME_MOUNT:-/mnt/vw-data}/backups in .env (separate-volume mode)"
        fi
    fi

    chown "$real_user:$(id -g -n "$real_user")" "$env_file" || return 1
    chmod 600 "$env_file" || return 1
    return 0
}

setup_directories() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would setup directories"; return 0; fi

    # If a separate data volume is configured, assert it is mounted and valid
    # before we create any subdirectories inside it. This prevents accidentally
    # writing the directory skeleton onto the boot volume if the mount failed.
    # Export the storage vars so require_project_state_ready can read them.
    export DATA_VOLUME_DEVICE="${DATA_VOLUME_DEVICE:-}"
    export DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-/mnt/vw-data}"
    # Align PROJECT_STATE_DIR with the storage mode so the consistency check
    # inside require_project_state_ready passes. In boot-only mode this is a no-op.
    if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then
        export PROJECT_STATE_DIR="${DATA_VOLUME_MOUNT}"
    else
        export PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    fi
    require_project_state_ready || return 1

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n "$real_user")

    local secrets_dirs=("secrets" "secrets/keys" "secrets/.docker_secrets")
    for dir in "${secrets_dirs[@]}"; do
        ensure_dir "$dir" 700 || return 1
        chown "$real_user:$real_group" "$dir" || return 1
    done

    local puid; puid=$(id -u "$real_user")
    local pgid; pgid=$(id -g "$real_user")
    local project_state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"

    # Create the backup directory tree that backup.sh and restore.sh require.
    # Derive the default from project_state_dir so that separate-volume installs
    # create backups on the data volume, consistent with what backup.sh produces
    # at runtime via _default_backup_dir().
    local backup_base_dir="${BACKUP_DIR:-${project_state_dir}/backups}"
    if ! mkdir -p "${backup_base_dir}"/{db,full,emergency}; then
        log_error "Failed to create backup directories under ${backup_base_dir}"
        return 1
    fi
    chmod 750 "${backup_base_dir}" "${backup_base_dir}"/{db,full,emergency} || return 1
    chown -R "${puid}:${pgid}" "${backup_base_dir}" || return 1
    log_info "Backup directories created: ${backup_base_dir}/{db,full,emergency}"

    if ! mkdir -p "${project_state_dir}"/{data,logs/{vaultwarden,caddy,postfix},caddy/{data,config}}; then
        return 1
    fi

    for _dir in data logs caddy backups; do
    [[ -d "${project_state_dir}/${_dir}" ]] && \
        chown -R "${puid}:${pgid}" "${project_state_dir}/${_dir}" || return 1
    done

    # Use {} + (batch exec) instead of {} \; (per-file exec) for performance.
    find "${project_state_dir}" -type d -exec chmod 750 {} + 2>/dev/null || return 1
    find "${project_state_dir}" -type f -exec chmod 640 {} + 2>/dev/null || true

    # Caddy runs as root inside its container and writes
    # access logs to ${project_state_dir}/logs/caddy/access.log via a bind-mount.
    #
    # The broad 'find chmod 750' above sets this directory to 750:
    #   owner=PUID  group=PGID  other=---
    #
    # On OCI Compute, Docker maps container UID 0 to an unprivileged host UID
    # (userns-remap or equivalent hypervisor isolation). Container root is NOT
    # host root. Any chmod/chown attempted inside the container on this
    # bind-mount fails with EPERM. Both the init container and caddy/entrypoint.sh
    # attempted 'chmod 755 /logs/caddy' — both fail silently on OCI.
    #
    # The definitive fix: set 755 here, running as real host root (setup.sh
    # is always invoked via 'sudo ./setup.sh'). This executes AFTER the broad
    # find chmod 750, overriding it for this specific directory.
    #
    # 755 rationale: Caddy's container UID falls into 'other' (it is neither
    # PUID nor PGID). 'other' needs at least r-x (5) to enter the directory
    # and rw- (6) on the log file itself. 755 grants r-x to 'other', and
    # Caddy creates access.log with mode 0644 (rw-r--r--), satisfying both.
    #
    chmod 755 "${project_state_dir}/logs/caddy" || return 1
    log_info "Set ${project_state_dir}/logs/caddy to 755 (Caddy runs as root in container)"

    # Caddy's TLS storage directories must be owned by
    # root:root and traversable (755) so Caddy can write certificate material
    # during the first ACME negotiation.
    #
    # Why root:root, not PUID:PGID:
    #   Caddy runs as UID 0 inside its container. On OCI Compute, userns-remap
    #   maps container UID 0 to an unprivileged host UID (e.g. 165536+), which
    #   is neither PUID nor PGID. The broad 'chown -R PUID:PGID' pass above
    #   would assign these directories to PUID, making them unreachable by the
    #   remapped container root. We do a second targeted chown pass here,
    #   running as real host root (setup.sh always runs under sudo), so the
    #   inodes end up owned by host UID 0 — the only identity the remapped
    #   container root maps to.
    #
    # Why 755, not 700:
    #   700 is rwx------: only the exact owning UID can enter. The remapped
    #   container UID is not host root (0), so 700 blocks traversal with
    #   EACCES. 755 grants r-x to all, which is sufficient for a
    #   non-world-writable storage directory containing private keys (the
    #   keys themselves are created by Caddy with mode 0600).
    #
    # Pre-creating certificates/, locks/, ocsp/:
    #   Caddy's ACME client attempts to mkdir these paths during the first TLS
    #   negotiation, often under concurrent request load. Pre-creating them
    #   here (owned by root:root, mode 755) eliminates the first-run race
    #   where two goroutines simultaneously attempt to mkdir the same path.
    local caddy_data_dir="${project_state_dir}/caddy/data"
    local caddy_config_dir="${project_state_dir}/caddy/config"

    mkdir -p \
        "${caddy_data_dir}/caddy/certificates" \
        "${caddy_data_dir}/caddy/locks" \
        "${caddy_data_dir}/caddy/ocsp"

    chown -R root:root "${caddy_data_dir}" "${caddy_config_dir}" || return 1
    find "${caddy_data_dir}" "${caddy_config_dir}" -type d -exec chmod 755 {} + || return 1
    find "${caddy_data_dir}" "${caddy_config_dir}" -type f -exec chmod 600 {} + 2>/dev/null || true

    log_info "Set ${caddy_data_dir} and ${caddy_config_dir} to root:root 755 (Caddy ACME storage)"
    log_info "Pre-created Caddy ACME subtree: certificates/ locks/ ocsp/"

    return 0
}

check_entropy() {
    local entropy; entropy=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo "0")
    (( entropy >= ENTROPY_THRESHOLD )) && return 0

    log_warn "Insufficient entropy (${entropy} bits, need ${ENTROPY_THRESHOLD}). Waiting for entropy pool to fill..."
    log_info  "Progress is shown below — do NOT abort. Install haveged to speed this up."

    local waited=0
    while (( waited < ENTROPY_MAX_WAIT )); do
        printf '  [entropy] Waiting' >&2
        local tick
        for (( tick = 0; tick < 5; tick++ )); do
            printf '.' >&2
            sleep 1
        done
        waited=$(( waited + 5 ))
        entropy=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo "0")
        printf ' %d bits (%ds/%ds)\n' "$entropy" "$waited" "$ENTROPY_MAX_WAIT" >&2
        (( entropy >= ENTROPY_THRESHOLD )) && return 0
    done

    log_error "Insufficient entropy after ${ENTROPY_MAX_WAIT}s (got ${entropy} bits, need ${ENTROPY_THRESHOLD}). Install haveged: sudo apt-get install -y haveged"
    return 1
}

generate_age_keys() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would generate Age keys"; return 0; fi

    check_entropy || return 1
    local age_key_file="secrets/keys/age-key.txt"

    if [[ -f "$age_key_file" ]]; then
        if [[ "$FORCE" != "true" ]]; then
            if check_age_key "$age_key_file" 2>/dev/null; then
                return 0
            else
                log_warn "Existing Age key file is present but INVALID/CORRUPT."
                log_warn "It will be replaced. If any usable encrypted data was created"
                log_warn "with a previous key version, it cannot be recovered after this."
                log_warn "If in doubt, abort (Ctrl-C) and inspect: $age_key_file"
            fi
        else
            if check_age_key "$age_key_file" 2>/dev/null; then
                if [[ "$AUTO_MODE" == "true" ]]; then
                    log_error "--force with --auto would regenerate the Age encryption key."
                    log_error "This permanently invalidates ALL existing encrypted secrets."
                    log_error "Run './edit-secrets.sh export-recovery-kit' first, then"
                    log_error "retry with --force WITHOUT --auto to confirm interactively."
                    return 1
                else
                    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    log_warn "  WARNING: --force will REGENERATE the Age encryption key."
                    log_warn "  ALL existing encrypted secrets will become permanently"
                    log_warn "  unrecoverable without a prior recovery kit export."
                    log_warn "  Run './edit-secrets.sh export-recovery-kit' FIRST."
                    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    printf '\nType %sROTATE KEY%s to confirm, or anything else to abort: ' \
                        "${COLOR_RED:-}" "${COLOR_RESET:-}"
                    local confirm
                    read -r confirm
                    if [[ "$confirm" != "ROTATE KEY" ]]; then
                        log_info "Key regeneration cancelled — existing key preserved."
                        return 1
                    fi
                fi
            fi
        fi
    fi

    local real_user; real_user=$(get_real_user)
    generate_age_key "$age_key_file" "$FORCE" || return 1
    chown "$real_user:$(id -g -n "$real_user")" "$age_key_file" || return 1
    chmod 600 "$age_key_file" || return 1

    # Wire: verify the freshly written key before create_sops_config() tries
    # to derive the public key from it.  simple_verify_age_key() resolves the
    # path internally (honouring SOPS_AGE_KEY_FILE / _resolve_age_key()), then
    # validates permissions, ownership, and runs a crypto roundtrip.  Catching
    # a corrupt or mis-permissioned key here prevents a confusing failure later
    # when sops --encrypt is first attempted.
    if ! SOPS_AGE_KEY_FILE="$age_key_file" simple_verify_age_key; then
        log_error "Age key verification failed immediately after generation — aborting."
        log_error "Key file: $age_key_file"
        log_error "Check disk space, filesystem errors, or re-run setup."
        return 1
    fi

    # ── Canonical production install ─────────────────────────────────────────
    # Install the key to the canonical root-owned path outside the repo tree.
    # Guard: if the canonical key already exists and FORCE != true, verify it
    # with check_age_key and skip re-install if healthy.
    local canonical_key="/etc/vaultwarden/age-key.txt"
    local do_install=true
    if [[ -f "$canonical_key" ]] && [[ "$FORCE" != "true" ]]; then
        if check_age_key "$canonical_key" 2>/dev/null; then
            log_info "Canonical Age key already present and healthy: $canonical_key"
            do_install=false
        else
            log_warn "Canonical Age key exists but is invalid — reinstalling: $canonical_key"
        fi
    fi

    if [[ "$do_install" == "true" ]]; then
        install -d -m 700 /etc/vaultwarden || {
            log_error "Failed to create /etc/vaultwarden directory."
            return 1
        }
        install -m 600 "$age_key_file" "$canonical_key" || {
            log_error "Failed to install Age key to $canonical_key."
            return 1
        }
        chown root:root /etc/vaultwarden "$canonical_key" || {
            log_error "Failed to set ownership on $canonical_key."
            return 1
        }
        log_success "Age key installed: $canonical_key (mode 600, root:root)"
    fi

    # ── Update .env atomically to the canonical path ─────────────────────────
    local env_file="$PROJECT_ROOT/.env"
    if [[ -f "$env_file" ]]; then
        local temp_env=""
        temp_env=$(mktemp -p "$(dirname "$env_file")" .env.tmp.XXXXXXXXXX) || return 1
        awk '{
            sub(/^SOPS_AGE_KEY_FILE=.*/, "SOPS_AGE_KEY_FILE=/etc/vaultwarden/age-key.txt");
            print;
        }' "$env_file" > "$temp_env"
        mv "$temp_env" "$env_file" || { rm -f "$temp_env"; return 1; }
        log_success "SOPS_AGE_KEY_FILE updated to $canonical_key in .env"
    fi

    # ── Verify .env now points to the canonical path ─────────────────────────
    local configured_path
    configured_path=$(grep '^SOPS_AGE_KEY_FILE=' "${env_file:-$PROJECT_ROOT/.env}" 2>/dev/null | cut -d= -f2)
    if [[ "$configured_path" != "$canonical_key" ]]; then
        log_error "After installation, .env SOPS_AGE_KEY_FILE still points to: ${configured_path:-<unset>}"
        log_error "Expected: $canonical_key"
        log_error "Update .env manually: SOPS_AGE_KEY_FILE=$canonical_key"
        return 1
    fi

    log_info "Production key: $canonical_key"
    log_info "Repo-local copy retained for local/dev use: $age_key_file"

    return 0
}

create_sops_config() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would create SOPS config"; return 0; fi

    local sops_config=".sops.yaml"
    local age_key_file="secrets/keys/age-key.txt"

    local age_public_key; age_public_key=$(get_age_public_key "$age_key_file") || return 1

    if [[ ! "$age_public_key" =~ ^age1[a-z0-9]{58}$ ]]; then
        log_error "Age public key has unexpected format: '${age_public_key}'"
        log_error "Expected format: age1<58 lowercase alphanumeric chars>"
        log_error "Regenerate the key with: rm secrets/keys/age-key.txt && ./setup.sh ..."
        return 1
    fi

    if [[ -f "$sops_config" ]] && [[ "$FORCE" != "true" ]]; then
        if grep -qF "$age_public_key" "$sops_config"; then
            if grep -q "creation_rules:" "$sops_config" && grep -q "age:" "$sops_config"; then
                log_info "SOPS config already up-to-date"
                return 0
            fi
        fi
        log_warn "SOPS config exists but public key has changed — rewriting .sops.yaml"
    fi

    cat > "$sops_config" << EOF
creation_rules:
  - path_regex: .*\.yaml$
    age: $age_public_key
EOF
    chmod 640 "$sops_config"
    chown "$(get_real_user):$(id -g -n "$(get_real_user)")" "$sops_config" || return 1
    return 0
}

create_empty_secrets_structure() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would create secrets structure"; return 0; fi

    local secrets_file="$PROJECT_ROOT/secrets/secrets.yaml"
    local age_key_file="$PROJECT_ROOT/secrets/keys/age-key.txt"

    if [[ -f "$secrets_file" ]] && [[ "$FORCE" != "true" ]]; then
        local decrypt_ok=false
        ( export SOPS_AGE_KEY_FILE="$age_key_file"; sops -d "$secrets_file" >/dev/null 2>&1 ) \
            && decrypt_ok=true
        if [[ "$decrypt_ok" == "true" ]]; then
            return 0
        else
            log_error "Existing secrets.yaml is unreadable with current key. Use --force to overwrite."
            return 1
        fi
    fi

    local temp_secrets; temp_secrets=$(mktemp -p "$TMP_WORKDIR" vwsecrets.XXXXXXXXXX.yaml) || return 1
    cat > "$temp_secrets" << 'EOF'
admin_token: PLACEHOLDER_NOT_CONFIGURED
admin_basic_auth_hash: PLACEHOLDER_NOT_CONFIGURED
smtp_password: PLACEHOLDER_NOT_CONFIGURED
email_api_token: PLACEHOLDER_NOT_CONFIGURED
backup_passphrase: PLACEHOLDER_NOT_CONFIGURED
push_installation_id: PLACEHOLDER_NOT_CONFIGURED
push_installation_key: PLACEHOLDER_NOT_CONFIGURED
caddy_cloudflare_dns_token: PLACEHOLDER_NOT_CONFIGURED
EOF
    chmod 600 "$temp_secrets"

    ( export SOPS_AGE_KEY_FILE="$age_key_file"; \
      sops --encrypt --output "$secrets_file" "$temp_secrets" ) || return 1

    chmod 600 "$secrets_file" || return 1
    chown "$(get_real_user):$(id -g -n "$(get_real_user)")" "$secrets_file" || return 1
    return 0
}

create_docker_compose() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would create docker-compose.yml"; return 0; fi

    local compose_file="$PROJECT_ROOT/docker-compose.yml"
    local compose_template="$PROJECT_ROOT/docker-compose.yml.example"

    if [[ -f "$compose_file" ]] && [[ "$FORCE" != "true" ]]; then
        docker compose -f "$compose_file" config >/dev/null 2>&1 && return 0
    fi

    cp "$compose_template" "$compose_file" || return 1
    chown "$(get_real_user):$(id -g -n "$(get_real_user)")" "$compose_file" || return 1
    chmod 640 "$compose_file" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# set_script_permissions
# ---------------------------------------------------------------------------
# Ensures every script that an admin might invoke after a fresh clone is
# executable without requiring a manual 'chmod +x' pass. Git does not
# preserve execute bits across clones on some systems/clients, so we set
# them here explicitly.
#
# Covers:
#   - Root-level *.sh scripts (operator-facing)
#   - caddy/entrypoint.sh  (run as container CMD; must be +x before 'make up')
#   - lib/*.sh             (sourced, not executed directly — kept 644)
# ---------------------------------------------------------------------------
set_script_permissions() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would set script permissions"; return 0; fi

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n "$real_user")

    # 1. Root-level operator scripts — chmod +x
    local root_scripts=(
        "setup.sh"
        "edit-secrets.sh"
        "backup.sh"
        "restore.sh"
        "startup.sh"
        "maintenance.sh"
    )
    for script in "${root_scripts[@]}"; do
        if [[ -f "$script" ]]; then
            chmod +x "$script"
            chown "$real_user:$real_group" "$script" 2>/dev/null || true
            log_success "Set +x: $script"
        fi
    done

    # 2. utilities/*.sh — executable admin helpers (moved from root)
    if [[ -d "utilities" ]]; then
        while IFS= read -r script; do
            chmod +x "$script"
            chown "$real_user:$real_group" "$script" 2>/dev/null || true
            log_success "Set +x: $script"
        done < <(find "utilities" -maxdepth 1 -name "*.sh")
    fi

    # 3. caddy/entrypoint.sh — must be executable before 'make up';
    #    Docker copies it into the image with its host permissions, so a
    #    missing +x bit causes 'permission denied' at container start.
    #    Use process substitution to avoid a pipe-subshell so log_success
    #    calls take effect in the current shell.
    if [[ -d "caddy" ]]; then
        while IFS= read -r script; do
            chmod +x "$script"
            chown "$real_user:$real_group" "$script" 2>/dev/null || true
            log_success "Set +x: $script"
        done < <(find "caddy" -maxdepth 1 -name "*.sh")
    fi

    # 4. lib/*.sh — sourced (not executed), keep 644 read-only for non-root
    if [[ -d "lib" ]]; then
        find "lib" -name "*.sh" -exec chown "$real_user:$real_group" {} + 2>/dev/null || true
        find "lib" -name "*.sh" -exec chmod 644 {} + 2>/dev/null || true
    fi

    return 0
}

setup_firewall() {
    # SECURITY: UFW rules must be applied AFTER Docker installation.
    # Docker rewrites iptables chains during installation; rules set before
    # Docker is installed are silently bypassed by Docker's DOCKER-USER chain.
    # This function is called after install_dependencies (which installs Docker),
    # ensuring the correct order of operations.
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would configure firewall"; return 0; fi

    local ssh_port
    ssh_port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    if [[ -z "$ssh_port" ]]; then
        ssh_port=$(awk '/^Port[[:space:]]/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)
    fi
    ssh_port=${ssh_port:-22}
    log_info "Detected SSH port: ${ssh_port}"

    local cf_ipv4_url="https://www.cloudflare.com/ips-v4"
    local cf_ipv6_url="https://www.cloudflare.com/ips-v6"
    local cf_cidrs=()
    local cf_fetch_failed=false

    log_info "Fetching Cloudflare CIDR lists for firewall restriction..."
    local ipv4_list ipv6_list
    ipv4_list=$(curl -fsSL --max-time 15 "$cf_ipv4_url" 2>/dev/null) || cf_fetch_failed=true
    ipv6_list=$(curl -fsSL --max-time 15 "$cf_ipv6_url" 2>/dev/null) || cf_fetch_failed=true

    if [[ "$cf_fetch_failed" == "false" ]] && \
       [[ -n "$ipv4_list" ]] && [[ -n "$ipv6_list" ]]; then
        while IFS= read -r cidr; do
            [[ -z "$cidr" || "$cidr" == \#* ]] && continue
            cf_cidrs+=("$cidr")
        done <<< "$ipv4_list"
        while IFS= read -r cidr; do
            [[ -z "$cidr" || "$cidr" == \#* ]] && continue
            cf_cidrs+=("$cidr")
        done <<< "$ipv6_list"
        log_info "Fetched ${#cf_cidrs[@]} Cloudflare CIDRs"
    else
        log_warn "Could not fetch Cloudflare CIDR lists — falling back to unrestricted allow rules."
        log_warn "SECURITY: Ports 80/443 will be open to all IPs. Restrict manually after setup:"
        log_warn "  See: https://www.cloudflare.com/ips-v4 and https://www.cloudflare.com/ips-v6"
    fi

    local ufw_active=false
    ufw status | grep -q "Status: active" && ufw_active=true

    if [[ "$ufw_active" == "true" ]] && \
       ufw status | grep -q "80/tcp" && \
       ufw status | grep -q "443/tcp" && \
       ufw status | grep -q "${ssh_port}/tcp"; then
        log_success "Firewall already configured and active"
        return 0
    fi

    ufw allow "${ssh_port}/tcp"

    if [[ ${#cf_cidrs[@]} -gt 0 ]]; then
        for cidr in "${cf_cidrs[@]}"; do
            ufw allow from "$cidr" to any port 80 proto tcp  2>/dev/null || true
            ufw allow from "$cidr" to any port 443 proto tcp 2>/dev/null || true
        done
        log_success "Firewall: ports 80/443 restricted to ${#cf_cidrs[@]} Cloudflare CIDRs"
    else
        # Fallback: unrestricted (already warned above)
        ufw allow 80/tcp
        ufw allow 443/tcp
    fi

    [[ "$ufw_active" == "false" ]] && ufw --force enable
    return 0
}

validate_ssh_config() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would validate SSH config"; return 0; fi

    if grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config 2>/dev/null; then
        log_warn "SSH root login is enabled - consider disabling"
    fi
    return 0
}

cleanup_setup_deps() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would cleanup dependencies"; return 0; fi

    apt-get autoremove -y >/dev/null 2>&1 || true
    return 0
}

execute_phase() {
    local phase_func="$1"
    local phase_name="$2"
    local phase_critical="${3:-false}"

    log_info "=== Phase: $phase_name ==="
    [[ "$phase_func" == "verify_dependencies" ]] && hash -r

    local exit_code=0
    "$phase_func" || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Phase failed: $phase_name (exit code: $exit_code)"
        [[ "$phase_critical" == "true" ]] && return 1 || return 2
    fi

    log_success "Phase completed: $phase_name"
    return 0
}

show_post_install_summary() {
    local mode="${1:-interactive}"
    [[ "$mode" == "interactive" ]] && clear

    printf '%s' "${COLOR_RED}"
    cat << "EOF"
    ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !
    !                                                             !
    !   CRITICAL: SAVE THIS INFORMATION FOR DISASTER RECOVERY     !
    !                                                             !
    ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !
EOF
    printf '%s' "${COLOR_RESET}"

    if [[ -f "secrets/keys/age-key.txt" ]]; then
        local age_pub_key
        age_pub_key=$(get_age_public_key "secrets/keys/age-key.txt" 2>/dev/null || echo "MISSING")
        local age_key_content
        age_key_content=$(cat "secrets/keys/age-key.txt" 2>/dev/null || echo "ERROR: Could not read key file")
        printf 'SOPS Age Public Key:  %s%s%s\n' "${COLOR_GREEN}" "${age_pub_key}" "${COLOR_RESET}"
        printf '\n%sSECRET KEY (BACKUP THIS FILE!):%s\n' "${COLOR_RED}" "${COLOR_RESET}"
        printf '%sSECRET KEY (production): %s/etc/vaultwarden/age-key.txt%s\n' "${COLOR_RED}" "${COLOR_GREEN}" "${COLOR_RESET}"
        printf '%sSECRET KEY (repo-local): %ssecrets/keys/age-key.txt%s\n' "${COLOR_RED}" "${COLOR_GREEN}" "${COLOR_RESET}"
        printf '%s%s%s\n' "${COLOR_GREEN}" "${age_key_content}" "${COLOR_RESET}"
        printf '\n%sTo view again at any time:%s\n' "${COLOR_RED}" "${COLOR_RESET}"
        printf '  %ssudo cat /etc/vaultwarden/age-key.txt%s  %s(production — root-owned, mode 600)%s\n' \
            "${COLOR_GREEN}" "${COLOR_RESET}" "${COLOR_RED}" "${COLOR_RESET}"
        printf '  %scat secrets/keys/age-key.txt%s  %s(repo-local copy — intentional for local dev only)%s\n' \
            "${COLOR_GREEN}" "${COLOR_RESET}" "${COLOR_RED}" "${COLOR_RESET}"
    fi

    # Determine correct edit command based on actual .env ownership
    local env_owner
    env_owner=$(stat -c '%U' "$PROJECT_ROOT/.env" 2>/dev/null || echo "root")
    local env_edit_cmd="nano .env"
    [[ "$env_owner" == "root" ]] && env_edit_cmd="sudo nano .env"

    if [[ "$mode" == "auto" ]]; then
        printf '\n%s--- AUTO-GENERATED CREDENTIALS (scroll up to save plaintext passwords) ---%s\n' \
            "${COLOR_CYAN}" "${COLOR_RESET}"
        printf '  %s✔%s VaultWarden admin token    : GENERATED (Argon2id hash stored in secrets)\n' \
            "${COLOR_GREEN}" "${COLOR_RESET}"
        printf '  %s✔%s Caddy admin password       : GENERATED (bcrypt hash stored in secrets)\n' \
            "${COLOR_GREEN}" "${COLOR_RESET}"
        printf '  %s✔%s Backup passphrase          : GENERATED (stored in secrets)\n' \
            "${COLOR_GREEN}" "${COLOR_RESET}"

        printf '\n%s--- CREDENTIALS REQUIRING MANUAL CONFIGURATION ---%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf 'These fields still contain CHANGE_ME placeholders.\n'
        printf 'Set them BEFORE running %smake up%s:\n\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %s./edit-secrets.sh rotate caddy_cloudflare_dns_token%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %s./edit-secrets.sh rotate smtp_password%s         (if using SMTP/email notifications)\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %s./edit-secrets.sh rotate email_api_token%s       (if using API-based email, e.g. MAILERSEND_API_TOKEN)\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %s./edit-secrets.sh rotate push_installation_id%s  (optional — mobile push)\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %s./edit-secrets.sh rotate push_installation_key%s (optional — mobile push)\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"

        printf '\n%s--- NEXT STEPS ---%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
        printf '1. Edit .env:           %s%s%s\n' "${COLOR_YELLOW}" "$env_edit_cmd" "${COLOR_RESET}"
        printf '   ► Set: CLOUDFLARE_ZONE_ID, SMTP_HOST, SMTP_PORT, SMTP_USERNAME\n'
        printf '   ► Verify: DOMAIN and ADMIN_EMAIL are correct\n'
        printf '2. Set external tokens: %s(use ./edit-secrets.sh rotate commands above)%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '3. Start services:      %smake up%s\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '4. Setup automation:    %ssudo ./setup.sh systemd install%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '5. Export recovery kit: %s./edit-secrets.sh export-recovery-kit%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '   %s(Run AFTER step 2 so all secrets are included in the kit)%s\n' \
            "${COLOR_RED}" "${COLOR_RESET}"
    else
        printf '\n%s--- EXTERNAL CONFIGURATION CHECKLIST ---%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
        printf '1. [ ] Domain Name:   %s%s%s\n' "${COLOR_GREEN}" "${CLEAN_DOMAIN:-Not Set}" "${COLOR_RESET}"
        printf '2. [ ] Admin Email:   %s%s%s\n' "${COLOR_GREEN}" "${ADMIN_EMAIL:-Not Set}" "${COLOR_RESET}"

        printf '\n%s--- NEXT STEPS ---%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
        printf '1. Edit .env:           %s%s%s\n' "${COLOR_YELLOW}" "$env_edit_cmd" "${COLOR_RESET}"
        printf '   ► Set: CLOUDFLARE_ZONE_ID, SMTP_HOST, SMTP_PORT, SMTP_USERNAME\n'
        printf '   ► Verify: DOMAIN and ADMIN_EMAIL are correct\n'
        printf '2. Configure secrets:   %s./setup.sh secrets%s\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '   ► You will be prompted for all credentials\n'
        printf '3. Start services:      %smake up%s\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '4. Setup automation:    %ssudo ./setup.sh systemd install%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '5. Export recovery kit: %s./edit-secrets.sh export-recovery-kit%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '   %s(Run AFTER step 2 so all secrets are included in the kit)%s\n' \
            "${COLOR_RED}" "${COLOR_RESET}"
    fi

    if [[ "$mode" == "interactive" ]]; then
        printf '\n%s!!! PRESS ENTER TO CLEAR THIS SCREEN AND FINISH !!!%s\n' "${COLOR_RED}" "${COLOR_RESET}"
        read -r
        clear
    fi
}

# ---------------------------------------------------------------------------
# run_phase_secrets
# ---------------------------------------------------------------------------
run_phase_secrets() {
# Require root: this phase writes into secrets/ and system key paths.
# The root check in main() runs AFTER the phase dispatch, so subcommand
# invocations (./setup.sh secrets) must guard themselves.
_require_root
local CLEANUP_ACTIONS=()
_ss_register_cleanup() { CLEANUP_ACTIONS+=("$1"); }

# Phase-local defaults (set -u safe): these flags are only parsed inside the
# secrets phase and may be unset when the caller does not pass explicit options.
# shellcheck disable=SC2034  # SKIP_VALIDATION is parsed and reserved; validation-skip logic is a noop placeholder
local SKIP_VALIDATION=false
local SKIP_OPTIONAL=false
local AUTO_FIX=true
local EXPORT_RECOVERY_KIT=false
local QUIET_SUMMARY=false
# Ensure cleanup trap can always iterate safely even when setup exits early.
declare -A _COLLECTED_SECRETS=()

# Replace eval with a named dispatch helper to eliminate the
# structural eval risk.  Each cleanup action is a string token whose first
# word is looked up in the dispatch table; unknown tokens are logged and
# skipped rather than executed as arbitrary shell code.
_ss_run_cleanup_action() {
    local action="$1"
    case "$action" in
        rm\ -f\ *)
            # Only allow "rm -f <single-path>" entries written by this script.
            local target="${action#rm -f }"
            if [[ -z "$target" || "$target" == *$'\n'* ]]; then
                return 0
            fi
            # Validate cleanup target resolves inside allowed directories before
            # rm -f to prevent glob expansion or path traversal from deleting
            # files outside /tmp or secrets/.
            local resolved
            resolved=$(realpath -m "$target" 2>/dev/null) || {
                log_warn "_run_cleanup_action: realpath failed for target — refusing rm: $target"
                return 1
            }
            local allowed_secrets="${PROJECT_ROOT:-/opt/vaultwarden-scripts}/secrets"
            if [[ "$resolved" != /tmp/* && "$resolved" != "$allowed_secrets"/* ]]; then
                log_warn "_run_cleanup_action: refusing rm on path outside allowed dirs: $resolved"
                return 1
            fi
            rm -f "$target" 2>/dev/null || true
            ;;
        *)
            log_warn "_ss_perform_cleanup: skipping unknown action: $action"
            ;;
    esac
}

_ss_perform_cleanup() {
    # Zero all collected secret values on any EXIT to prevent plaintext credentials in process memory.
    for key in "${!_COLLECTED_SECRETS[@]}"; do
        _COLLECTED_SECRETS["$key"]=""
    done
    unset _COLLECTED_SECRETS 2>/dev/null || true

    for ((idx=${#CLEANUP_ACTIONS[@]}-1; idx>=0; idx--)); do
        _ss_run_cleanup_action "${CLEANUP_ACTIONS[$idx]}"
    done
    cleanup_secrets_environment
}
trap '_ss_perform_cleanup' RETURN

_ss_show_help() {
    cat << 'HELP'
VaultWarden Interactive Secrets Setup (Idempotent - Security Hardened)

USAGE:
    ./setup.sh secrets [OPTIONS]

OPTIONS:
    --auto                  Auto-generate passwords; external credentials
                            (CF tokens, SMTP, push keys) are left as
                            CHANGE_ME placeholders for manual rotation.
    --skip-validation       Skip token/SMTP validation
    --skip-optional         Skip optional secrets (push notifications)
    --force                 Overwrite existing secrets without prompting
    --dry-run               Preview without executing
    --no-auto-fix           Don't auto-create missing prerequisites
    --export-recovery-kit   Offer recovery kit export after setup completes
    --quiet-summary         Suppress the completion banner, next-steps block,
                            and recovery-kit prompt. Used internally by
                            setup.sh so it can display a single consolidated
                            summary screen. Not intended for direct use.
    --help                  Show help

NOTES:
    --export-recovery-kit triggers the recovery-kit prompt that already
    appears after a successful setup run. To export a recovery kit
    independently (without running setup), use:
        ./edit-secrets.sh export-recovery-kit

    The intended standalone order is:
        1. sudo ./setup.sh --domain DOMAIN --email EMAIL
        2. nano .env           (set CLOUDFLARE_ZONE_ID, EMAIL_MODE, EMAIL_PROVIDER,
                                SMTP_HOST, etc.)
        3. ./setup.sh secrets  (prompted for all credentials)
        4. make up

FEATURES:
    ✅ Idempotent - Safe to re-run multiple times
    ✅ Auto-fixes missing prerequisites (Age keys, SOPS config)
    ✅ Validates existing secrets before reconfiguration
    ✅ Automatic Argon2id hashing (VaultWarden admin)
    ✅ Automatic bcrypt hashing (Caddy admin - htpasswd format)
    ✅ Cloudflare token validation
    ✅ Interactive prompts with confirmation
    ✅ Secure password generation (32-char minimum)
    ✅ Collects email API token OR smtp_password based on EMAIL_MODE

SECURITY ENHANCEMENTS:
    ✅ Caddy basic auth in htpasswd format (admin:\$2y\$14\$...)
    ✅ Hash validation before storage
    ✅ Secure temporary file handling
    ✅ Enhanced error messages

EXAMPLES:
    ./setup.sh secrets                        # Interactive setup
    ./setup.sh secrets --auto                 # Automated with generated passwords
    ./setup.sh secrets --force                # Reconfigure without prompting
    ./setup.sh secrets --skip-optional        # Skip push notifications
    ./setup.sh secrets --export-recovery-kit  # Prompt for kit after setup

SEE ALSO:
    ./edit-secrets.sh list                  # Show existing secret key names
    ./edit-secrets.sh rotate FIELD          # Rotate a single secret
    ./edit-secrets.sh                         # Interactive raw edit
    ./edit-secrets.sh export-recovery-kit   # Standalone recovery kit export
HELP
}

# shellcheck disable=SC2034  # SKIP_VALIDATION is a documented option; validation-skip logic is a future placeholder
while [[ $# -gt 0 ]]; do
    case $1 in
        --auto)                  AUTO_MODE=true;           shift ;;
        --skip-validation)       SKIP_VALIDATION=true;     shift ;;
        --skip-optional)         SKIP_OPTIONAL=true;       shift ;;
        --force)                 FORCE=true;               shift ;;
        --dry-run)               DRY_RUN=true;             shift ;;
        --no-auto-fix)           AUTO_FIX=false;           shift ;;
        --export-recovery-kit)   EXPORT_RECOVERY_KIT=true; shift ;;
        --quiet-summary)         QUIET_SUMMARY=true;       shift ;;
        --help)                  _ss_show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; _ss_show_help; exit 1 ;;
    esac
done

# Resolve the Age key path used by prerequisite checks in this phase.
# Prefer an explicitly exported SOPS_AGE_KEY_FILE, otherwise default to the
# repo-local key path produced during setup. Normalize relative paths to an
# absolute path so checks work consistently regardless of the current CWD.
local AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}"
if [[ "$AGE_KEY_FILE" != /* ]]; then
    AGE_KEY_FILE="$PROJECT_ROOT/$AGE_KEY_FILE"
fi

ensure_prerequisites() {
    log_info "Checking prerequisites..."

    local missing=()
    local can_fix=()

    if [[ ! -f "$AGE_KEY_FILE" ]]; then
        missing+=("Age encryption key")
        can_fix+=("age_key")
    elif ! check_age_key "$AGE_KEY_FILE" 2>/dev/null; then
        log_warn "Age key exists but appears invalid"
        missing+=("Valid Age encryption key")
        can_fix+=("age_key")
    fi

    if [[ ! -f ".sops.yaml" ]]; then
        missing+=("SOPS configuration")
        can_fix+=("sops_config")
    fi

    if [[ ! -d "secrets" ]]; then
        missing+=("Secrets directory")
        can_fix+=("directories")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing prerequisites:"
        for item in "${missing[@]}"; do log_warn "  - $item"; done

        if [[ "$AUTO_FIX" == "true" ]]; then
            log_info "Auto-fixing missing prerequisites..."
            fix_prerequisites "${can_fix[@]}"
        else
            log_error "Prerequisites missing. Run './setup.sh' first or use --auto-fix"
            return 1
        fi
    else
        log_success "All prerequisites present"
    fi

    return 0
}

fix_prerequisites() {
    local items=("$@")

    for item in "${items[@]}"; do
        case "$item" in
            age_key)
                log_info "Creating Age encryption key..."
                mkdir -p "$(dirname "$AGE_KEY_FILE")"
                if generate_age_key "$AGE_KEY_FILE" true; then
                    log_success "Age key created: $AGE_KEY_FILE"
                else
                    log_error "Failed to create Age key"
                    return 1
                fi
                ;;
            sops_config)
                log_info "Creating SOPS configuration..."
                local age_public_key
                if ! age_public_key=$(get_age_public_key "$AGE_KEY_FILE"); then
                    log_error "Failed to extract Age public key"
                    return 1
                fi
                # Validate the Age public key format before writing
                # .sops.yaml.  An empty or malformed key is accepted silently,
                # causing sops --encrypt to fail later with a confusing error.
                # Age public keys always begin with "age1" and consist of
                # lowercase bech32 characters (a-z0-9).
                if [[ -z "$age_public_key" ]] || \
                   ! [[ "$age_public_key" =~ ^age1[a-z0-9]{58}$ ]]; then
                    log_error "Age public key has an invalid format: '${age_public_key}'"
                    log_error "Expected format: age1<58 lowercase bech32 characters>"
                    log_error "Re-generate the Age key and retry."
                    return 1
                fi
                cat > .sops.yaml << SOPS_EOF
creation_rules:
  - path_regex: .*\.yaml$
    age: $age_public_key
SOPS_EOF
                chmod 640 .sops.yaml
                chown "$(get_real_user):$(id -g -n "$(get_real_user)")" .sops.yaml 2>/dev/null || true
                log_success "SOPS configuration created: .sops.yaml"
                ;;
            directories)
                log_info "Creating directory structure..."
                mkdir -p secrets/keys secrets/.docker_secrets
                chmod 700 secrets/keys secrets/.docker_secrets
                log_success "Directories created"
                ;;
        esac
    done

    return 0
}

secrets_are_configured() {
    if ! secrets_file_exists; then return 1; fi
    if ! ensure_sops_env;      then return 1; fi
    if ! check_placeholder_values 2>/dev/null; then
        return 1
    fi
    return 0
}

# _warn_tty: Writes timeout warnings to /dev/tty when available so that
# automated pipelines capturing stdout are not silently confused by the
# default-to-'no' decision. Suppresses output when --quiet-summary is active
# to prevent unexpected terminal output during silent sub-invocations.
_warn_tty() {
    local msg="$1"
    # When QUIET_SUMMARY is true this script is being called by setup.sh in a
    # non-interactive context; writing to /dev/tty would produce unexpected
    # output on the operator's terminal that setup.sh has not accounted for.
    if [[ "$QUIET_SUMMARY" == "true" ]]; then
        log_warn "$msg"
        return
    fi
    if [[ -w /dev/tty ]]; then
        echo "$msg" > /dev/tty
    else
        log_warn "$msg"
    fi
}

check_reconfiguration() {
    if ! secrets_are_configured; then
        log_info "No valid secrets found - configuration needed"
        return 0
    fi

    if [[ "$FORCE" == "true" ]]; then
        log_info "Force mode - reconfiguring secrets"
        # Do not write a backup when --dry-run is active.
        # An admin running --dry-run --force expects a preview only; writing a
        # real backup file is a side-effect they do not expect.
        [[ "$DRY_RUN" != "true" ]] && create_secrets_backup
        return 0
    fi

    log_info "Secrets already configured and valid"

    if [[ "$AUTO_MODE" == "true" ]]; then
        log_info "Auto mode - keeping existing secrets"
        return 1
    fi

    echo ""
    # Add -t 30 timeout to avoid hanging in non-interactive contexts;
    # route timeout warning to /dev/tty when available.
    local confirm
    if ! read -r -t 30 -p "Reconfigure secrets? (yes/no): " confirm; then
        _warn_tty "WARNING: No input received (30s timeout). Treating as 'no'."
        confirm="no"
    fi

    if [[ "$confirm" == "yes" ]]; then
        create_secrets_backup
        return 0
    fi

    return 1
}

ensure_argon2_available() {
    if check_argon2_support >/dev/null 2>&1; then return 0; fi

    # Gate on an import check first so we skip the pip install
    # entirely when argon2-cffi is already installed under a different path
    # (e.g. system package).  Only proceed to install if the module is genuinely
    # absent.  Use a pinned version range to prevent silent breaking upgrades and
    # add a PEP 668 (externally-managed-environment) fallback via --user.
    if python3 -c "import argon2" 2>/dev/null; then
        return 0
    fi

    log_warn "Argon2 not detected"

    if [[ "$AUTO_MODE" != "true" ]]; then
        # Add -t 30 timeout to avoid hanging in non-interactive contexts;
        # route timeout warning to /dev/tty when available.
        local install_it
        if ! read -r -t 30 -p "Install Python argon2-cffi? (yes/no): " install_it; then
            _warn_tty "WARNING: No input received (30s timeout). Treating as 'no'."
            install_it="no"
        fi
        if [[ "$install_it" == "yes" ]]; then
            # Pinned version range prevents silent breaking upgrades.
            # PEP 668 fallback: if the system Python is externally managed, try --user.
            if pip3 install --quiet "argon2-cffi>=21.3,<24" 2>/dev/null || \
               python3 -m pip install --quiet --user "argon2-cffi>=21.3,<24" 2>/dev/null; then
                return 0
            fi
        fi
    fi

    log_error "Argon2 required but not available"
    return 1
}

# ---------------------------------------------------------------------------
# yaml_escape VALUE
#
# Secret values must be YAML-safe.  Values containing : # [ {
# or leading whitespace produce malformed YAML when written with bare printf
# '%s'.  This helper wraps the value in YAML single-quote scalars and escapes
# any literal single-quote characters inside the value (YAML spec: '' → ').
# Output is ready for direct embedding in a YAML single-quoted scalar context.
# ---------------------------------------------------------------------------
yaml_escape() {
    local value="$1"
    # Replace every ' with '' (YAML single-quote escape), then wrap in '...'.
    local escaped="${value//\'/\'\'}"
    printf "'%s'" "$escaped"
}

# ---------------------------------------------------------------------------
# _read_dotenv_value KEY [FILE]
#
# Read a single KEY from .env (or FILE) without sourcing the whole file.
# Returns the value, or an empty string if the key is not found.
# ---------------------------------------------------------------------------
_read_dotenv_value() {
    local key="$1"
    local file="${2:-.env}"
    [[ -f "$file" ]] || { echo ""; return 0; }
    if [[ ! -r "$file" ]]; then
        log_warn "_read_dotenv_value: '${file}' is not readable by $(id -un) — returning empty for key '${key}'" >&2
        echo ""; return 0
    fi
    local val
    # Strip inline comments (one-or-more whitespace then #) and trailing whitespace.
    # Requiring at least one space before # deliberately preserves passwords that
    # contain '#' (e.g. "p@ss#1") while correctly stripping "VALUE  # comment".
    val=$(grep -E "^${key}=" "$file" | head -1 | sed "s/^${key}=//;s/[[:space:]]\+#.*$//;s/[[:space:]]*$//")
    echo "$val"
}

# ---------------------------------------------------------------------------
# Collect secrets
#
# SECRET_* env vars must NOT be exported during the collection
# phase because they are visible in /proc/$$/environ to all subprocesses.
# All secret values are stored exclusively in the local SECRETS associative
# array. write_secrets() reads directly from SECRETS[key].
#
# Both AUTO_MODE and interactive paths delegate to lib/secrets.sh:
#   - interactive  → collect_secret_field()        (prompts, hashes, validates)
#   - auto         → auto_generate_secret_field()  (generates, hashes, validates)
#
# In --auto mode, auto_generate_secret_field() intentionally emits CHANGE_ME
# placeholders for credentials that exist in external systems (CF tokens,
# SMTP password, push keys). These must be rotated manually with:
#   ./edit-secrets.sh rotate FIELD
# This is by design: --auto is truly non-interactive.
#
# All hashing logic (Argon2id, bcrypt) and format validation live exclusively
# in lib/secrets.sh. collect_secrets() is a thin orchestration layer.
#
# EMAIL COLLECTION:
#   The email tier is chosen by reading EMAIL_MODE from .env:
#     auto  — collect BOTH the API token (email_api_token) and smtp_password
#             (email driver will try API first, then SMTP as fallback)
#     api   — collect email_api_token only
#     smtp  — collect smtp_password only
#     host  — skip both (Postfix sidecar; no credential needed here)
#   A single canonical key "email_api_token" is used for ALL providers.
#   Changing EMAIL_PROVIDER in .env is the only action needed to switch;
#   the token value in secrets.yaml does not need re-keying.
# ---------------------------------------------------------------------------
collect_secrets() {
    _get_field() {
        local field="$1"
        if [[ "$AUTO_MODE" == "true" ]]; then
            auto_generate_secret_field "$field"
        else
            collect_secret_field "$field"
        fi
    }

    # --- VaultWarden admin password (Argon2id) -------------------------------
    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info " VaultWarden Admin Password"
    log_info "═══════════════════════════════════════════════════════════"
    log_info "This password will be hashed with Argon2id for VaultWarden"
    echo ""

    local vw_hash
    vw_hash=$(_get_field "admin_token") || { log_error "Failed to collect admin_token"; return 1; }
    _COLLECTED_SECRETS["admin_token"]="$vw_hash"

    # --- Caddy admin password (bcrypt / htpasswd) ----------------------------
    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info " Caddy Admin Panel Password"
    log_info "═══════════════════════════════════════════════════════════"
    log_info "This password will be hashed with bcrypt for Caddy basic auth"
    # shellcheck disable=SC2016  # single quotes intentional: showing literal bcrypt format
    log_info 'Format: htpasswd (admin:$2y$14$...)'
    echo ""

    local caddy_hash
    caddy_hash=$(_get_field "admin_basic_auth_hash") || { log_error "Failed to collect admin_basic_auth_hash"; return 1; }
    _COLLECTED_SECRETS["admin_basic_auth_hash"]="$caddy_hash"

    # --- Cloudflare DNS token ------------------------------------------------
    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info " Cloudflare DNS API Token"
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Required Permissions: Zone:DNS:Edit + Zone:Zone:Read"
    log_info "Create at: https://dash.cloudflare.com/profile/api-tokens"
    echo ""

    local cf_dns
    cf_dns=$(_get_field "caddy_cloudflare_dns_token") || { log_error "Failed to collect caddy_cloudflare_dns_token"; return 1; }
    _COLLECTED_SECRETS["caddy_cloudflare_dns_token"]="$cf_dns"

    if [ -f "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/secrets/.docker_secrets/fail2ban_cloudflare_firewall_token" ]; then
        _log_info "Cloudflare firewall token file found on disk — will be used by CrowdSec bouncer."
    else
        _log_warn "Cloudflare firewall token file not found — CrowdSec Cloudflare bouncer will need manual configuration."
    fi

    # --- Email credentials (API token + SMTP password) ----------------------
    #
    # Read EMAIL_MODE and EMAIL_PROVIDER from .env so we know which
    # credential(s) to collect.  Defaults: mode=auto, provider=mailersend.
    # ---------------------------------------------------------------------------
    local _email_mode _email_provider
    _email_mode=$(    _read_dotenv_value "EMAIL_MODE"     .env)
    _email_provider=$(   _read_dotenv_value "EMAIL_PROVIDER" .env)
    if [[ -z "$_email_mode" && -f ".env" && ! -r ".env" ]]; then
        log_warn "setup.sh secrets: .env is not readable by $(id -un); EMAIL_MODE/EMAIL_PROVIDER defaulting to 'auto'/'mailersend'."
        log_warn "Fix ownership: sudo chown $(id -un):$(id -gn) .env"
    fi
    _email_mode="${_email_mode:-auto}"
    _email_provider="${_email_provider:-mailersend}"

    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info " Email Notifications"
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Current .env settings:"
    log_info "  EMAIL_MODE     = $_email_mode"
    log_info "  EMAIL_PROVIDER = $_email_provider"
    echo ""
    log_info "Delivery tiers (controlled by EMAIL_MODE in .env):"
    log_info "  auto  — try API → SMTP → Postfix sidecar in order (recommended)"
    log_info "  api   — HTTP API only   (requires email_api_token in secrets)"
    log_info "  smtp  — SMTP relay only (requires smtp_password in secrets)"
    log_info "  host  — Postfix sidecar only (no token or SMTP password needed)"
    echo ""
    log_info "One token key (email_api_token) works for ALL providers."
    log_info "To switch providers: change EMAIL_PROVIDER in .env only."
    log_info "To rotate the token: ./edit-secrets.sh rotate email_api_token"
    echo ""

    # ----------- Tier 1: provider HTTP API token ----------------------------
    # Single canonical key "email_api_token" used for all providers.
    # No per-provider key derivation — switching EMAIL_PROVIDER in .env is
    # the only change needed; the token value in secrets.yaml stays the same.
    if [[ "$_email_mode" == "api" || "$_email_mode" == "auto" ]]; then
        log_info " Tier 1 — Email API Token (all providers)"
        log_info "  Secrets key  : email_api_token"
        log_info "  Active provider: $_email_provider (set EMAIL_PROVIDER in .env to change)"
        log_info "  Get token at : provider dashboard (MailerSend / SendGrid / Mailgun etc.)"
        echo ""

        local email_api_token
        if [[ "$AUTO_MODE" == "true" ]]; then
            email_api_token="CHANGE_ME_EMAIL_API_TOKEN"
            log_warn "[AUTO] email_api_token → placeholder; rotate with:"
            log_warn "  ./edit-secrets.sh rotate email_api_token"
        else
            local skip_api
            if ! read -r -t 30 -p "Enter email_api_token now? (yes/no): " skip_api; then
                _warn_tty "WARNING: No input received (30s timeout). Treating as 'no'."
                skip_api="no"
            fi
            if [[ "$skip_api" == "yes" ]]; then
                local _raw_token
                if ! read -r -s -t 120 -p "email_api_token: " _raw_token; then
                    _warn_tty "WARNING: No input received (120s timeout). Using placeholder."
                    _raw_token=""
                fi
                echo ""
                if [[ -n "$_raw_token" ]]; then
                    email_api_token="$_raw_token"
                    log_success "email_api_token stored"
                else
                    email_api_token="CHANGE_ME_EMAIL_API_TOKEN"
                    log_info "No value entered — using placeholder"
                fi
            else
                email_api_token="CHANGE_ME_EMAIL_API_TOKEN"
                log_info "API token skipped — rotate later with:"
                log_info "  ./edit-secrets.sh rotate email_api_token"
            fi
        fi
        _COLLECTED_SECRETS["email_api_token"]="$email_api_token"
    else
        _COLLECTED_SECRETS["email_api_token"]="NOT_USED_EMAIL_MODE=${_email_mode}"
    fi

    # ----------- Tier 2: SMTP relay password --------------------------------
    # Collected when EMAIL_MODE is 'smtp' or 'auto'.
    if [[ "$_email_mode" == "smtp" || "$_email_mode" == "auto" ]]; then
        echo ""
        log_info " Tier 2 — SMTP Relay Password"
        log_info "  Secrets key: smtp_password"
        log_info "  .env keys  : SMTP_HOST / SMTP_PORT / SMTP_USERNAME  (non-secret)"
        echo ""

        local smtp_pass
        if [[ "$AUTO_MODE" == "true" ]]; then
            smtp_pass=$(auto_generate_secret_field "smtp_password") || { log_error "Failed to generate smtp_password"; return 1; }
        else
            local enable_smtp
            if ! read -r -t 30 -p "Enter smtp_password now? (yes/no): " enable_smtp; then
                _warn_tty "WARNING: No input received (30s timeout). Treating as 'no'."
                enable_smtp="no"
            fi
            if [[ "$enable_smtp" == "yes" ]]; then
                smtp_pass=$(collect_secret_field "smtp_password") || { log_error "Failed to collect smtp_password"; return 1; }
                log_success "smtp_password configured"
            else
                smtp_pass="CHANGE_ME_SMTP_PASSWORD"
                log_info "SMTP password skipped — rotate later with:"
                log_info "  ./edit-secrets.sh rotate smtp_password"
            fi
        fi
        _COLLECTED_SECRETS["smtp_password"]="$smtp_pass"
    elif [[ "$_email_mode" == "host" ]]; then
        # Postfix sidecar: no SMTP relay password needed from secrets.
        _COLLECTED_SECRETS["smtp_password"]="NOT_USED_EMAIL_MODE=host"
        log_info "EMAIL_MODE=host: smtp_password not needed (Postfix sidecar handles delivery)"
    else
        # api-only mode: SMTP password not used, but store a clear placeholder
        # so the secrets file always has all expected keys.
        _COLLECTED_SECRETS["smtp_password"]="NOT_USED_EMAIL_MODE=${_email_mode}"
    fi

    # --- Backup passphrase (always auto-generated) --------------------------
    echo ""
    log_info "Generating backup encryption passphrase..."
    local backup_pass
    backup_pass=$(auto_generate_secret_field "backup_passphrase") || { log_error "Failed to generate backup_passphrase"; return 1; }
    _COLLECTED_SECRETS["backup_passphrase"]="$backup_pass"

    # --- Push notifications (optional) --------------------------------------
    if [[ "$SKIP_OPTIONAL" != "true" ]]; then
        echo ""
        log_info "═══════════════════════════════════════════════════════════"
        log_info " Push Notifications (Optional)"
        log_info "═══════════════════════════════════════════════════════════"
        log_info "Get credentials from: https://bitwarden.com/host"
        echo ""

        if [[ "$AUTO_MODE" == "true" ]]; then
            # auto_generate_secret_field emits CHANGE_ME placeholders for push
            # keys — correct behaviour for truly non-interactive mode.
            _COLLECTED_SECRETS["push_installation_id"]=$(auto_generate_secret_field "push_installation_id")
            _COLLECTED_SECRETS["push_installation_key"]=$(auto_generate_secret_field "push_installation_key")
        else
            # Add -t 30 timeout to avoid hanging in non-interactive contexts;
            # route timeout warning to /dev/tty when available.
            local do_push
            if ! read -r -t 30 -p "Configure push notifications? (yes/no): " do_push; then
                _warn_tty "WARNING: No input received (30s timeout). Treating as 'no'."
                do_push="no"
            fi
            if [[ "$do_push" == "yes" ]]; then
                _COLLECTED_SECRETS["push_installation_id"]=$(collect_secret_field "push_installation_id") || return 1
                _COLLECTED_SECRETS["push_installation_key"]=$(collect_secret_field "push_installation_key") || return 1
                log_success "Push notifications configured"
            else
                _COLLECTED_SECRETS["push_installation_id"]="CHANGE_ME_OR_LEAVE_EMPTY"
                _COLLECTED_SECRETS["push_installation_key"]="CHANGE_ME_OR_LEAVE_EMPTY"
                log_info "Push notifications skipped - configure later with: ./edit-secrets.sh rotate push_installation_id"
            fi
        fi
    else
        _COLLECTED_SECRETS["push_installation_id"]="CHANGE_ME_OR_LEAVE_EMPTY"
        _COLLECTED_SECRETS["push_installation_key"]="CHANGE_ME_OR_LEAVE_EMPTY"
    fi

    echo ""
    log_success "All secrets collected successfully"
    return 0
}

# ---------------------------------------------------------------------------
# export_docker_secrets
#
# Decrypt every canonical key from the SOPS-encrypted secrets/secrets.yaml
# and write a corresponding plain-text file under secrets/.docker_secrets/.
# Each file is created with mode 600 (enforced by write_secret_file()) and
# the directory is ensured at mode 700.
#
# This function must be called AFTER write_secrets() has moved the encrypted
# file to its final location.  It is the authoritative step that satisfies
# the `make up` pre-flight check:
#   test -s secrets/.docker_secrets/admin_token
#
# Security properties:
#   - SOPS env is set up and torn down within this function.
#   - decrypt_secret() suppresses xtrace and unsets the value after printf.
#   - write_secret_file() verifies non-empty write and sets chmod 600.
#   - Plaintext local variables are unset immediately after the write call.
# ---------------------------------------------------------------------------
export_docker_secrets() {
    local docker_secrets_dir="$PROJECT_ROOT/secrets/.docker_secrets"

    log_info "Exporting decrypted secrets to Docker secrets directory..."

    if ! mkdir -p "$docker_secrets_dir"; then
        log_error "export_docker_secrets: failed to create $docker_secrets_dir"
        return 1
    fi
    chmod 700 "$docker_secrets_dir"

    if ! ensure_sops_env; then
        log_error "export_docker_secrets: failed to set up SOPS environment"
        return 1
    fi

    # Canonical list of keys that must have corresponding flat files.
    # Keep in sync with validate_required_secrets() in lib/secrets.sh.
    local -a _keys=(
        admin_token
        admin_basic_auth_hash
        caddy_cloudflare_dns_token
        email_api_token
        smtp_password
        backup_passphrase
        push_installation_id
        push_installation_key
    )

    local _failed=0
    local _key _value

    for _key in "${_keys[@]}"; do
        # shellcheck disable=SC2153  # SECRETS_FILE is a global env var, not a typo of secrets_file
        _value=$(decrypt_secret "$_key" "$SECRETS_FILE") || {
            log_error "export_docker_secrets: failed to decrypt '$_key'"
            _failed=$(( _failed + 1 ))
            continue
        }

        if ! write_secret_file "${docker_secrets_dir}/${_key}" "$_value"; then
            log_error "export_docker_secrets: failed to write ${docker_secrets_dir}/${_key}"
            _failed=$(( _failed + 1 ))
        fi

        # Unset plaintext value immediately after the write.
        unset _value
    done
    unset _key

    cleanup_secrets_environment

    if [[ $_failed -gt 0 ]]; then
        log_error "export_docker_secrets: $_failed key(s) failed to export"
        return 1
    fi

    log_success "Docker secrets exported to: $docker_secrets_dir"
    return 0
}

# ---------------------------------------------------------------------------
# Write secrets (atomic)
# ---------------------------------------------------------------------------
write_secrets() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would write secrets to encrypted file"
        return 0
    fi

    log_info "Writing secrets to encrypted YAML file..."

    # Detect and report mkdir failure explicitly instead of
    # swallowing it with '2>/dev/null || true'.  A failed mkdir would cause
    # the subsequent mktemp -p to fail with an opaque "No such file or
    # directory" error that hides the true root cause.
    if ! mkdir -p "$PROJECT_ROOT/secrets"; then
        log_error "Failed to create secrets directory: $PROJECT_ROOT/secrets"
        log_error "Check permissions on $PROJECT_ROOT and retry."
        return 1
    fi

    local _saved_umask
    _saved_umask=$(umask)
    umask 077
    local temp_file
    temp_file=$(mktemp -p "$PROJECT_ROOT/secrets" vwsecrets.XXXXXXXXXX.yaml) || {
        umask "$_saved_umask"
        log_error "mktemp failed in $PROJECT_ROOT/secrets"
        return 1
    }
    umask "$_saved_umask"

    # shellcheck disable=SC2064  # intentional — $temp_file must expand NOW
    _ss_register_cleanup "rm -f '$temp_file'"

    # All secret values are passed through yaml_escape() which
    # wraps them in YAML single-quoted scalars and escapes internal
    # single-quotes.  This prevents values containing : # [ { or leading
    # whitespace from producing malformed YAML.
    {
        printf '# VaultWarden Secrets Configuration\n'
        printf '# Generated: %s\n' "$(date -Iseconds)"
        printf '# Encrypted with: SOPS + Age\n\n'
        printf '# VaultWarden admin password (Argon2id hash)\n'
        printf 'admin_token: %s\n\n'                       "$(yaml_escape "${_COLLECTED_SECRETS[admin_token]}")"
        # shellcheck disable=SC2016  # single quotes intentional: showing literal bcrypt format example
        printf '# Caddy admin password (htpasswd format: admin:$2y$14$...)\n'
        printf 'admin_basic_auth_hash: %s\n\n'             "$(yaml_escape "${_COLLECTED_SECRETS[admin_basic_auth_hash]}")"
        printf '# Email — Tier 1: HTTP API token (all providers)\n'
        printf '# Single key regardless of EMAIL_PROVIDER. Change EMAIL_PROVIDER in .env\n'
        printf '# to switch providers; no re-keying of this secret is required.\n'
        printf '# To rotate: ./edit-secrets.sh rotate email_api_token\n'
        printf 'email_api_token: %s\n\n'                   "$(yaml_escape "${_COLLECTED_SECRETS[email_api_token]:-}")"
        printf '# Email — Tier 2: SMTP relay password\n'
        printf '# Used when EMAIL_MODE=smtp or EMAIL_MODE=auto (fallback from API).\n'
        printf '# To rotate: ./edit-secrets.sh rotate smtp_password\n'
        printf 'smtp_password: %s\n\n'                     "$(yaml_escape "${_COLLECTED_SECRETS[smtp_password]}")"
        printf '# Backup encryption passphrase\n'
        printf 'backup_passphrase: %s\n\n'                 "$(yaml_escape "${_COLLECTED_SECRETS[backup_passphrase]}")"
        printf '# Push notifications (optional)\n'
        printf 'push_installation_id: %s\n'                "$(yaml_escape "${_COLLECTED_SECRETS[push_installation_id]}")"
        printf 'push_installation_key: %s\n\n'             "$(yaml_escape "${_COLLECTED_SECRETS[push_installation_key]}")"
        printf '# Cloudflare DNS API token (Zone:DNS:Edit + Zone:Zone:Read)\n'
        printf 'caddy_cloudflare_dns_token: %s\n'        "$(yaml_escape "${_COLLECTED_SECRETS[caddy_cloudflare_dns_token]}")"
    } > "$temp_file"

    # Clear the in-memory associative array immediately after writing, to
    # minimise the window in which plaintext values are live in the process.
    for key in "${!_COLLECTED_SECRETS[@]}"; do
        _COLLECTED_SECRETS["$key"]=""
    done
    unset _COLLECTED_SECRETS
    # Re-declare as empty so the EXIT trap does not error on an unbound variable.
    declare -A _COLLECTED_SECRETS

    if ! ensure_sops_env; then
        log_error "Failed to setup SOPS environment"
        return 1
    fi

    log_info "Encrypting secrets with SOPS + Age..."
    if ! sops --encrypt --in-place "$temp_file" 2>&1; then
        log_error "Failed to encrypt secrets file"
        return 1
    fi

    if ! mv "$temp_file" "$SECRETS_FILE"; then
        log_error "Failed to move encrypted secrets to final location"
        return 1
    fi

    if ! secure_secrets_file; then
        log_error "Failed to secure secrets file permissions"
        return 1
    fi

    log_success "Secrets encrypted and written to: $SECRETS_FILE"

    local docker_secrets_dir="$PROJECT_ROOT/secrets/.docker_secrets"
    if [[ ! -d "$docker_secrets_dir" ]]; then
        mkdir -p "$docker_secrets_dir"
        chmod 700 "$docker_secrets_dir"
        log_info "Created Docker secrets directory: $docker_secrets_dir"
    fi

    # Export decrypted flat files so that `make up` pre-flight checks pass.
    # This is the authoritative write of secrets/.docker_secrets/* and must
    # run every time write_secrets() succeeds.
    if ! export_docker_secrets; then
        log_error "Failed to export Docker secret files — run ./setup.sh secrets again"
        return 1
    fi

    return 0
}

_ss_main() {
    log_header "VaultWarden Secrets Setup (Security Hardened)"

    echo ""
    log_info "This script will configure all secrets for VaultWarden deployment"
    log_info "Secrets will be encrypted with SOPS + Age encryption"
    echo ""

    if ! require_commands sops age python3 jq htpasswd; then
        log_error "Missing required commands"
        log_info "Install htpasswd with: sudo apt-get install apache2-utils"
        return 1
    fi

    # Verify that the installed htpasswd binary supports bcrypt
    # (-B flag).  Some minimal apache2-utils builds ship without bcrypt support;
    # the failure would otherwise surface deep inside lib/secrets.sh with an
    # opaque error.  Run a quick smoke-test here and exit early with a clear
    # install hint if bcrypt is unavailable.
    if ! htpasswd -nbB _test_ _test123_ &>/dev/null; then
        log_error "htpasswd on this system does not support bcrypt (-B flag)"
        log_error "This is required for Caddy admin basic-auth hashing."
        log_info  "Fix: sudo apt-get install --reinstall apache2-utils"
        return 1
    fi

    if ! ensure_prerequisites;    then return 1; fi
    if ! ensure_argon2_available; then return 1; fi

    if ! check_reconfiguration; then
        log_info "Keeping existing secrets - no changes made"
        log_info "Tip: to rotate a single field run: ./edit-secrets.sh rotate FIELD"
        log_info "Tip: to export a recovery kit run:  ./edit-secrets.sh export-recovery-kit"
        return 0
    fi

    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info " Secrets Collection"
    log_info "═══════════════════════════════════════════════════════════"
    if ! collect_secrets; then
        log_error "Failed to collect secrets"
        return 1
    fi

    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info " Writing Encrypted Secrets"
    log_info "═══════════════════════════════════════════════════════════"
    if ! write_secrets; then
        log_error "Failed to write secrets"
        return 1
    fi

    # Scope the SECRET_* cleanup sweep to only the exact keys
    # defined and used by this script. A broader compgen -v SECRET_ prefix
    # sweep would unset any SECRET_* variable exported by a parent process
    # (e.g. SECRET_KEY from a CI system), which is destructive in shared-host
    # or CI environments.
    for _cleanup_key in \
        admin_token admin_basic_auth_hash \
        caddy_cloudflare_dns_token \
        email_api_token smtp_password backup_passphrase \
        push_installation_id push_installation_key; do
        unset "SECRET_${_cleanup_key}" 2>/dev/null || true
    done
    unset _cleanup_key

    # Gate the entire completion output on QUIET_SUMMARY.
    #
    # When called from setup.sh --auto with --quiet-summary:
    #   - The auto-generated plaintext passwords emitted by log_warn inside
    #     auto_generate_secret_field() (above) are already visible on screen.
    #   - setup.sh owns show_post_install_summary("auto"), which is the single
    #     consolidated screen listing what still needs to be done.
    #   - Suppressing this block also eliminates the offer_recovery_kit_export
    #     interactive prompt that would hang in a non-TTY context.
    #
    # When run standalone (--quiet-summary not passed):
    #   - Full completion banner and updated next-steps are displayed.
    #   - offer_recovery_kit_export prompt is shown as usual.
    if [[ "$QUIET_SUMMARY" != "true" ]]; then
        echo ""
        log_header "Secrets Setup Complete!"
        echo ""
        log_success "✅ Secrets encrypted and stored in: $SECRETS_FILE"
        log_success "✅ Caddy admin hash in htpasswd format: admin:\$2y\$14\$..."
        log_success "✅ VaultWarden admin hash in Argon2id format"
        log_success "✅ All secrets protected with Age encryption"
        log_success "✅ Docker secret files written to: secrets/.docker_secrets/"
        echo ""
        # Updated next-steps to reflect the new install order.
        # The user has already edited .env before running this script, so
        # step 1 is "Verify" not "Review/create".
        echo "📋 Next Steps:"
        echo "   1. Verify .env settings:      nano .env"
        echo "      ► Confirm: CLOUDFLARE_ZONE_ID, EMAIL_MODE, EMAIL_PROVIDER,"
        echo "                 SMTP_HOST, SMTP_PORT, SMTP_USERNAME"
        echo "   2. Start services:            make up"
        echo "   3. Setup automation:          sudo ./setup.sh systemd install"
        echo "   4. Export recovery kit:       ./edit-secrets.sh export-recovery-kit"
        echo "   5. Test health:               ./maintenance.sh health"
        echo "   6. To rotate a single field:  ./edit-secrets.sh rotate FIELD"
        echo "   7. To list secret keys:       ./edit-secrets.sh list"
        echo ""
        echo "📧 Email mode reference (set EMAIL_MODE in .env):"
        echo "   auto  — API → SMTP → Postfix fallback chain (recommended)"
        echo "   api   — HTTP API only  (set EMAIL_PROVIDER + rotate email_api_token)"
        echo "   smtp  — SMTP relay only (rotate smtp_password)"
        echo "   host  — Postfix sidecar only (no token or password needed in secrets)"
        echo ""
        log_warn "⚠️  If you used --auto mode, scroll up to save the generated passwords!"
        echo ""

        if [[ "$DRY_RUN" == "false" ]]; then
            offer_recovery_kit_export "$EXPORT_RECOVERY_KIT"
        fi
    fi

    return 0
}
    _ss_main "$@"
}

# ---------------------------------------------------------------------------
# run_phase_systemd
# ---------------------------------------------------------------------------
run_phase_systemd() {
local INSTALL=false
local REMOVE=false
local STATUS=false
local VALIDATE=false
local DRY_RUN=false

local _ORIG_ARGS=("$@")

local UNIT_SOURCE_DIR="$PROJECT_ROOT/systemd"
local UNIT_DEST_DIR="/etc/systemd/system"
local OPT_SCRIPTS_DIR="/opt/vaultwarden-scripts"
local ENV_DIR="/etc/vaultwarden"
local ENV_FILE="$ENV_DIR/vaultwarden.env"
local AGE_KEY_DEST="$ENV_DIR/age-key.txt"

local -a TIMERS=(
    vaultwarden-maintenance.timer
    vaultwarden-db-backup.timer
    vaultwarden-full-backup.timer
    vaultwarden-health.timer
    vaultwarden-dns-update.timer
    vaultwarden-firewall-update.timer
)

local -a SERVICES=(
    vaultwarden-maintenance.service
    vaultwarden-db-backup.service
    vaultwarden-full-backup.service
    vaultwarden-health.service
    vaultwarden-dns-update.service
    vaultwarden-firewall-update.service
    vaultwarden-notify-failure.service
    vaultwarden-iptables.service
)

_sd_show_help() {
    cat << 'EOF'
VaultWarden-OCI systemd Timer Installer

USAGE:
    sudo ./setup.sh systemd <action> [OPTIONS]
    sudo ./setup.sh systemd install    # Install and enable all timers
    sudo ./setup.sh systemd remove     # Disable and remove all timers
    sudo ./setup.sh systemd validate   # Verify installed state vs repo
    sudo ./setup.sh systemd status     # Show timer and service status

ACTIONS:
    install   Install and enable all systemd timer units
    remove    Disable and remove all systemd timer units
    validate  Verify installed state matches repo; detect split-brain
    status    Show timer and service status

OPTIONS:
    --dry-run     Print actions without executing
    --help        Show this help

WHAT install DOES:
    1. Copies maintenance.sh, backup.sh -> /opt/vaultwarden-scripts/
       (root:root 700; scripts are self-locating via BASH_SOURCE[0])
    2. Copies lib/ -> /opt/vaultwarden-scripts/lib/ (root:root 644)
       lib files are 644 (world-readable) so a non-root service User= can
       still source lib/common.sh if the unit is ever changed from root.
    3. Copies .env -> /etc/vaultwarden/vaultwarden.env (root:root 600)
       (skipped if the EnvironmentFile already exists; warns if content differs)
    4. Copies secrets/keys/age-key.txt -> /etc/vaultwarden/age-key.txt (root:root 600)
       and sets SOPS_AGE_KEY_FILE=/etc/vaultwarden/age-key.txt in the EnvironmentFile.
       This is required because systemd units run with ProtectHome=yes, which makes
       /home/ubuntu/ (and any symlinks into it) inaccessible to the service process.
       If the source file is absent but the key already exists at the destination,
       SOPS_AGE_KEY_FILE is still corrected to the absolute path.
    5. Copies systemd/*.{service,timer} -> /etc/systemd/system/
    6. systemctl daemon-reload
    7. systemctl enable --now for all 6 timers
    8. Verifies all managed timers are active and have a next trigger
    9. systemctl reset-failed for all managed services (clears stale failed status)

WHAT validate CHECKS:
    1. Scripts present and executable in /opt/vaultwarden-scripts/
    2. lib/ present; lib/*.sh files are readable (mode 644 recommended)
    3. All unit files present in /etc/systemd/system/
    4. All 6 timers enabled (systemctl is-enabled)
    5. EnvironmentFile /etc/vaultwarden/vaultwarden.env exists (mode 600)
    6. Age key /etc/vaultwarden/age-key.txt exists (mode 600)
    7. SOPS_AGE_KEY_FILE is set in the EnvironmentFile
    8. Installed scripts match repo source checksum (sha256 split-brain detection)
       Re-run install after any git pull to keep /opt/ in sync.

VIEWING LOGS:
    journalctl -u vaultwarden-health.service -n 50
    journalctl -u vaultwarden-db-backup.service -n 100
    systemctl list-timers --all | grep vaultwarden

MIGRATING FROM CRON:
    cron-setup.sh has been removed. To migrate:
    1. sudo ./setup.sh systemd install
    2. Remove old crontab entries: sudo crontab -e
    3. Verify timers: systemctl list-timers --all | grep vaultwarden
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        install)   INSTALL=true;   shift ;;
        remove)    REMOVE=true;    shift ;;
        validate)  VALIDATE=true;  shift ;;
        status)    STATUS=true;    shift ;;
        --dry-run) DRY_RUN=true;   shift ;;
        help|--help) _sd_show_help; exit 0 ;;
        *) log_error "Unknown sub-action: $1"; _sd_show_help; exit 1 ;;
    esac
done

_require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root."
        log_info  "Use: sudo $0 ${_ORIG_ARGS[*]}"
        exit 1
    fi
}

_run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] $*"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# _timer_has_next_trigger TIMER
# Returns success when TIMER has a next scheduled trigger.
# For calendar timers this is sourced from NextElapseUSecRealtime; "n/a"
# indicates no future activation is scheduled.
# ---------------------------------------------------------------------------
_timer_has_next_trigger() {
    local timer="$1"
    local next_elapse
    next_elapse="$(systemctl show "$timer" --property=NextElapseUSecRealtime --value 2>/dev/null || true)"
    [[ -n "$next_elapse" && "$next_elapse" != "n/a" ]]
}

# ---------------------------------------------------------------------------
# _count_healthy_managed_timers
# Returns the number of managed timers that are active and have a next trigger.
# ---------------------------------------------------------------------------
_count_healthy_managed_timers() {
    local healthy_count=0
    local timer
    for timer in "${TIMERS[@]}"; do
        if systemctl is-active --quiet "$timer" && _timer_has_next_trigger "$timer"; then
            ((healthy_count++))
        fi
    done
    printf '%s\n' "$healthy_count"
}

# ---------------------------------------------------------------------------
# _sha256 FILE
# Portable sha256 hash of a single file; prints only the hex digest.
# ---------------------------------------------------------------------------
_sha256() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# ---------------------------------------------------------------------------
# _install_rwpaths_dropin
# ---------------------------------------------------------------------------
# In separate-volume mode every managed unit needs a ReadWritePaths drop-in
# so that ProtectSystem=strict allows writes to DATA_VOLUME_MOUNT.  Without
# this drop-in, any write to DATA_VOLUME_MOUNT (backup files, health cooldown
# stamps, DB operations) is silently blocked by the kernel, causing runtime
# Permission denied errors that are hard to diagnose from the unit file alone.
#
# Boot-only mode (DATA_VOLUME_DEVICE empty): no-op.
# Dry-run mode: logs what would be written without touching the filesystem.
# ---------------------------------------------------------------------------
_install_rwpaths_dropin() {
    local data_device data_mount
    # Read from the installed EnvironmentFile when available so that
    # standalone 'systemd install' runs (without CLI flags) pick up
    # the correct value written by a previous full setup run.
    if [[ -f "$ENV_FILE" ]]; then
        data_device=$(_read_env_value "DATA_VOLUME_DEVICE" "$ENV_FILE")
        data_mount=$(_read_env_value "DATA_VOLUME_MOUNT"  "$ENV_FILE")
    fi
    # Fall back to script-scope variables (set via CLI flags or environment)
    [[ -z "$data_device" ]] && data_device="${DATA_VOLUME_DEVICE:-}"
    [[ -z "$data_mount"  ]] && data_mount="${DATA_VOLUME_MOUNT:-}"

    if [[ -z "$data_device" ]]; then
        log_info "Boot-only mode — skipping per-unit ReadWritePaths drop-ins."
        return 0
    fi

    if [[ -z "$data_mount" ]]; then
        log_warn "DATA_VOLUME_MOUNT is empty — cannot write ReadWritePaths drop-ins."
        return 1
    fi

    # Self-contained unit list — do NOT rely on SERVICES/TIMERS from the
    # enclosing run_phase_systemd() scope. Dynamic-scope inheritance only
    # works when called through the exact call chain that defines those
    # locals; any future caller outside that chain would silently iterate
    # zero units and install no drop-ins.
    local -a _DROPIN_UNITS=("${_VW_DROPIN_UNITS[@]}")

    log_info "Installing per-unit ReadWritePaths drop-ins for DATA_VOLUME_MOUNT=${data_mount} ..."
    local unit dropin_dir dropin_file _mount_unit
    _mount_unit=$(systemd-escape --path --suffix=mount "$data_mount" 2>/dev/null) || {
        log_error "systemd-escape failed for DATA_VOLUME_MOUNT=$data_mount"
        return 1
    }
    for unit in "${_DROPIN_UNITS[@]}"; do
        dropin_dir="${UNIT_DEST_DIR}/${unit}.d"
        dropin_file="${dropin_dir}/10-state-dir.conf"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would write ReadWritePaths drop-in: $dropin_file"
            continue
        fi
        mkdir -p "$dropin_dir" || { log_error "Cannot create drop-in dir: $dropin_dir"; return 1; }
        cat > "$dropin_file" << DROPIN
# Written by setup.sh systemd install — do not edit by hand.
# Regenerate: sudo ./setup.sh systemd install
#
# [Unit]  After=  — this unit waits for the data volume to be mounted before
#                   starting, even when triggered by a timer or dependency chain.
# [Service] ReadWritePaths= — grants write access to DATA_VOLUME_MOUNT under
#                             ProtectSystem=strict (without this, all writes to
#                             the data volume are silently denied by the kernel).
[Unit]
After=${_mount_unit}

[Service]
ReadWritePaths=${data_mount}
DROPIN
        chmod 644 "$dropin_file"
        log_success "Installed ReadWritePaths drop-in: $dropin_file"
    done
}

# ---------------------------------------------------------------------------
# install_units
# ---------------------------------------------------------------------------
install_units() {
    _require_root
    log_header "VaultWarden-OCI systemd Timer Installation"

    if [[ ! -d "$UNIT_SOURCE_DIR" ]]; then
        log_error "systemd unit directory not found: $UNIT_SOURCE_DIR"
        log_error "Run from the VaultWarden-OCI repository root."
        return 1
    fi

    # 1. Install scripts to /opt/vaultwarden-scripts/
    log_info "Installing scripts to $OPT_SCRIPTS_DIR ..."
    _run mkdir -p "$OPT_SCRIPTS_DIR"

    if [[ "$DRY_RUN" == "false" ]]; then
        cp -rP "$PROJECT_ROOT/lib" "$OPT_SCRIPTS_DIR/"

        # lib files are installed 644 root:root (not 640).
        #
        # Rationale: these files are sourced by maintenance.sh and backup.sh
        # at runtime. If the systemd unit's User= directive is
        # ever changed from root to a service account, a 640 root:root mode
        # causes every "source lib/common.sh" call to fail silently (bash
        # reports the permission error to stderr but continues, leaving all
        # lib functions undefined). 644 keeps the files non-writable by
        # everyone except root while still allowing any user to read them --
        # the same policy used for system libraries in /usr/lib.
        #
        # If your threat model requires stricter access (e.g. lib files
        # contain inline credentials), set User= to a dedicated group,
        # change these lines to chmod 640 and chown root:<service-group>,
        # and add the service account to that group. Document the choice.
        find "$OPT_SCRIPTS_DIR/lib" -type f -name '*.sh' -exec chmod 644 {} +
        find "$OPT_SCRIPTS_DIR/lib" -type f ! -name '*.sh' -exec chmod 640 {} +  2>/dev/null || true
        find "$OPT_SCRIPTS_DIR/lib" -type d -exec chmod 755 {} +
        chown -R root:root "$OPT_SCRIPTS_DIR/lib"
        log_success "Installed lib/ to $OPT_SCRIPTS_DIR/lib/ (*.sh: 644, other files: 640)"
    else
        log_info "[DRY RUN] Would copy lib/ -> $OPT_SCRIPTS_DIR/lib/ (*.sh: 644 root:root)"
    fi

    if [[ "$DRY_RUN" == "false" ]] && [[ ! -f "$OPT_SCRIPTS_DIR/lib/crypto.sh" ]]; then
        log_error "CRITICAL: lib/crypto.sh missing from repo -- installation aborted."
        log_error "Ensure lib/crypto.sh exists in: $PROJECT_ROOT/lib/"
        return 1
    fi

    local scripts_to_install=(maintenance.sh backup.sh utilities/setup-iptables.sh)
    for script in "${scripts_to_install[@]}"; do
        local src="$PROJECT_ROOT/$script"
        local dest_name; dest_name=$(basename "$script")
        if [[ ! -f "$src" ]]; then
            log_warn "Script not found, skipping: $src"
            continue
        fi
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would install: $OPT_SCRIPTS_DIR/$dest_name"
            continue
        fi
        install -m 700 -o root -g root "$src" "$OPT_SCRIPTS_DIR/$dest_name"
        log_success "Installed: $OPT_SCRIPTS_DIR/$dest_name"
    done
    if [[ "$DRY_RUN" == "false" ]]; then chown root:root "$OPT_SCRIPTS_DIR"; fi

    # 2. Create EnvironmentFile at /etc/vaultwarden/vaultwarden.env
    log_info "Setting up EnvironmentFile at $ENV_FILE ..."
    if [[ "$DRY_RUN" == "false" ]]; then
        # Use install -d to create the directory with the correct
        # mode atomically. The previous mkdir -p + chmod 700 two-step had a
        # TOCTOU race window between mkdir and chmod where a concurrent
        # non-root process could list $ENV_DIR before permissions were
        # restricted. install(1) creates the directory with the correct mode
        # and ownership in a single syscall, eliminating the window.
        install -d -m 700 -o root -g root "$ENV_DIR"
        if [[ ! -f "$ENV_FILE" ]]; then
            if [[ -f "$PROJECT_ROOT/.env" ]]; then
                cp "$PROJECT_ROOT/.env" "$ENV_FILE"
                chmod 600 "$ENV_FILE"
                chown root:root "$ENV_FILE"
                log_success "Copied .env -> $ENV_FILE"
            else
                log_warn ".env not found -- creating empty $ENV_FILE"
                log_warn "Populate $ENV_FILE with ADMIN_EMAIL, EMAIL_PROVIDER credentials, etc."
                touch "$ENV_FILE"
                chmod 600 "$ENV_FILE"
                chown root:root "$ENV_FILE"
            fi
        else
            # On re-install, perform a safe additive merge instead of a full
            # overwrite.
            #
            # Strategy:
            #   - Lines already present in the installed file are NEVER touched
            #     (live credentials, tokens, and operator overrides are preserved).
            #   - Keys present in repo .env but ABSENT from the installed file
            #     are APPENDED as a clearly-marked block.
            #   - If every key is already present (files may still differ in
            #     value), a checksum comparison is shown so the operator can
            #     review value drift intentionally.
            #
            # This eliminates the persistent DRIFT DETECTED warning on every
            # --install while keeping the installed file safe from blind overwrites.
            log_info "$ENV_FILE already exists -- checking for drift ..."
            if [[ -f "$PROJECT_ROOT/.env" ]]; then
                local repo_sum installed_sum
                repo_sum=$(_sha256 "$PROJECT_ROOT/.env")
                installed_sum=$(_sha256 "$ENV_FILE")
                if [[ "$repo_sum" == "$installed_sum" ]]; then
                    log_success "$ENV_FILE is identical to repo .env (checksums match)"
                else
                    # Collect keys from repo .env that are absent in the installed file.
                    local missing_keys=()
                    while IFS= read -r line; do
                        # Skip blanks and comments
                        [[ -z "$line" || "$line" == '#'* ]] && continue
                        local key="${line%%=*}"
                        [[ -z "$key" ]] && continue
                        if ! grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
                            missing_keys+=("$line")
                        fi
                    done < "$PROJECT_ROOT/.env"
                    if [[ "${#missing_keys[@]}" -gt 0 ]]; then
                        log_info "Merging ${#missing_keys[@]} new variable(s) from repo .env into $ENV_FILE ..."
                        {
                            printf '\n# --- Merged by setup.sh systemd on %s ---\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
                            for entry in "${missing_keys[@]}"; do
                                printf '%s\n' "$entry"
                            done
                        } >> "$ENV_FILE"
                        log_success "Merged new keys into $ENV_FILE -- review and set their values:"
                        for entry in "${missing_keys[@]}"; do
                            log_info "  + ${entry%%=*}"
                        done
                        log_info "Edit: sudo nano $ENV_FILE"
                    else
                        # Files differ in VALUE only (not in which keys are present).
                        # This is expected if the operator has customised values.
                        # Inform without alarming; show a diff command for review.
                        log_info "────────────────────────────────────────────────────────────────"
                        log_info "NOTE: $ENV_FILE has the same keys as repo .env but values differ."
                        log_info "  repo .env  sha256: $repo_sum"
                        log_info "  installed  sha256: $installed_sum"
                        log_info "This is normal if you have set live credentials or custom values."
                        log_info "To review:  diff $PROJECT_ROOT/.env $ENV_FILE"
                        log_info "────────────────────────────────────────────────────────────────"
                    fi
                fi
            else
                log_info "No repo .env found -- skipping drift check"
            fi
        fi
    else
        log_info "[DRY RUN] Would create/check $ENV_FILE from .env"
    fi

    # ------------------------------------------------------------------
    # 3. Install age key to /etc/vaultwarden/age-key.txt
    #    (ProtectHome=yes makes /home/ubuntu/ inaccessible to service processes)
    log_info "Installing age key to $AGE_KEY_DEST ..."
    local age_key_src="$PROJECT_ROOT/secrets/keys/age-key.txt"
    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ -f "$age_key_src" ]]; then
            log_info "[DRY RUN] Would copy $age_key_src -> $AGE_KEY_DEST (600 root:root)"
            log_info "[DRY RUN] Would set SOPS_AGE_KEY_FILE=$AGE_KEY_DEST in $ENV_FILE"
        else
            log_warn "[DRY RUN] Age key source not found: $age_key_src"
            if [[ -f "$AGE_KEY_DEST" ]]; then
                log_info "[DRY RUN] Key already at $AGE_KEY_DEST -- would correct SOPS_AGE_KEY_FILE"
            else
                log_warn "[DRY RUN] Set SOPS_AGE_KEY_FILE manually in $ENV_FILE after install."
            fi
        fi
    else
        if [[ -f "$age_key_src" ]]; then
            install -m 600 -o root -g root "$age_key_src" "$AGE_KEY_DEST"
            log_success "Installed age key: $AGE_KEY_DEST"
            # Ensure SOPS_AGE_KEY_FILE is set correctly in the EnvironmentFile
            _set_env_var "SOPS_AGE_KEY_FILE" "$AGE_KEY_DEST" "$ENV_FILE"
            log_success "SOPS_AGE_KEY_FILE=$AGE_KEY_DEST set in $ENV_FILE"
        else
            log_warn "Age key source not found: $age_key_src"
            # If the key already exists at the destination, correct SOPS_AGE_KEY_FILE to
            # the canonical absolute path. A stale relative
            # SOPS_AGE_KEY_FILE=secrets/keys/age-key.txt in the env file would otherwise
            # persist across subsequent --install runs, causing backup.sh to fail with
            # "Age key file not found: /opt/vaultwarden-scripts/secrets/keys/age-key.txt".
            if [[ -f "$AGE_KEY_DEST" ]]; then
                _set_env_var "SOPS_AGE_KEY_FILE" "$AGE_KEY_DEST" "$ENV_FILE"
                log_success "SOPS_AGE_KEY_FILE=$AGE_KEY_DEST corrected in $ENV_FILE"
                log_info "  Key already present at $AGE_KEY_DEST -- no copy needed."
            else
                log_warn "Backup and health services require SOPS_AGE_KEY_FILE to be set."
                log_warn "After placing your age-key.txt, run:"
                log_warn "  sudo install -m 600 -o root -g root /path/to/age-key.txt $AGE_KEY_DEST"
                log_warn "  sudo ./setup.sh systemd install"
            fi
        fi
    fi

    # 3b. Copy rclone config to /etc/vaultwarden/rclone.conf
    local rclone_dest="$ENV_DIR/rclone.conf"
    log_info "Setting up rclone config at $rclone_dest ..."

    # Check if RCLONE_CONFIG is already correctly set in the env file
    local existing_rclone_cfg=""
    if [[ -f "$ENV_FILE" ]]; then
        existing_rclone_cfg=$(grep "^RCLONE_CONFIG=" "$ENV_FILE" | head -1 | cut -d= -f2- || true)
    fi

    if [[ -n "$existing_rclone_cfg" && "$existing_rclone_cfg" == "$rclone_dest" && -f "$rclone_dest" ]]; then
        log_success "rclone config already at $rclone_dest (RCLONE_CONFIG in env is correct)"
    else
        # Resolve source: repo-local → sudo user → root → heuristic
        local rclone_src=""
        if [[ -f "$PROJECT_ROOT/rclone.conf" ]]; then
            rclone_src="$PROJECT_ROOT/rclone.conf"
        elif [[ -n "${SUDO_USER:-}" ]]; then
            local sudo_home
            sudo_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
            [[ -n "$sudo_home" && -f "$sudo_home/.config/rclone/rclone.conf" ]] \
                && rclone_src="$sudo_home/.config/rclone/rclone.conf"
        fi
        if [[ -z "$rclone_src" && -f "/root/.config/rclone/rclone.conf" ]]; then
            rclone_src="/root/.config/rclone/rclone.conf"
        fi
        if [[ -z "$rclone_src" ]]; then
            local found_cfg
            for found_cfg in /home/*/.config/rclone/rclone.conf; do
                [[ -f "$found_cfg" ]] && rclone_src="$found_cfg" && break
            done
        fi

        if [[ -n "$rclone_src" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY RUN] Would copy $rclone_src -> $rclone_dest (600 root:root)"
                log_info "[DRY RUN] Would set RCLONE_CONFIG=$rclone_dest in $ENV_FILE"
            else
                install -m 600 -o root -g root "$rclone_src" "$rclone_dest"
                _set_env_var "RCLONE_CONFIG" "$rclone_dest" "$ENV_FILE"
                log_success "Installed rclone config: $rclone_dest (source: $rclone_src)"
                log_success "RCLONE_CONFIG=$rclone_dest set in $ENV_FILE"
                if [[ "$rclone_src" != "$rclone_dest" ]]; then
                    log_info "ADMIN NOTE: if you re-run 'rclone config' interactively as a non-root"
                    log_info "  user, re-run --install to sync the updated token to $rclone_dest."
                fi
            fi
        else
            log_warn "No rclone.conf found — offsite backup (--rclone) will not work until"
            log_warn "rclone is configured. Steps:"
            log_warn "  1. Run: rclone config   (configure your remote)"
            log_warn "  2. Run: sudo ./setup.sh systemd install  (copies conf to $rclone_dest)"
            log_warn "  Or manually:"
            log_warn "    sudo install -m 600 -o root -g root ~/.config/rclone/rclone.conf $rclone_dest"
            log_warn "    echo RCLONE_CONFIG=$rclone_dest | sudo tee -a $ENV_FILE"
        fi
    fi

    # 4. Install systemd unit files
    log_info "Installing systemd unit files to $UNIT_DEST_DIR ..."
    local unit_ok=true
    for unit in "${SERVICES[@]}" "${TIMERS[@]}"; do
        local src="$UNIT_SOURCE_DIR/$unit"
        if [[ ! -f "$src" ]]; then
            log_warn "Unit file not found, skipping: $src"
            unit_ok=false
            continue
        fi
        _run cp "$src" "$UNIT_DEST_DIR/$unit"
        _run chmod 644 "$UNIT_DEST_DIR/$unit"
        log_success "Installed unit: $unit"
    done
    if [[ "$unit_ok" == "false" ]]; then
        log_warn "Some unit files were missing -- check the systemd/ directory."
    fi

    # 4b. Write per-unit ReadWritePaths drop-ins (separate-volume mode)
    _install_rwpaths_dropin

    log_info "Reloading systemd daemon ..."
    _run systemctl daemon-reload

    # Validate OnCalendar expressions before enabling timers.
    # An invalid expression causes systemctl enable --now to fail with a
    # cryptic 'Failed to start' error; surfacing it here with a clear
    # warning gives operators actionable information before activation.
    #
    # '^OnCalendar=' anchors the grep pattern so only directive lines are
    # matched (not comment lines), preventing systemd-analyze from
    # validating comment text and emitting false-positive warnings.
    if command -v systemd-analyze >/dev/null 2>&1; then
        for unit in "${UNIT_DEST_DIR}"/vaultwarden-*.timer; do
            [[ -f "$unit" ]] || continue
            # '^OnCalendar=' anchors to directive lines only.
            local cal_expr; cal_expr=$(grep -m1 '^OnCalendar=' "$unit" | cut -d= -f2-)
            if [[ -n "$cal_expr" ]]; then
                if ! systemd-analyze calendar "$cal_expr" >/dev/null 2>&1; then
                    log_warn "Timer $(basename "$unit") has an invalid OnCalendar expression '$cal_expr' — check the unit file"
                fi
            fi
        done
    fi

    log_info "Enabling and starting timers ..."
    for timer in "${TIMERS[@]}"; do
        _run systemctl enable --now "$timer"
        log_success "Enabled: $timer"
    done

    # Verify managed timers are healthy after enablement.
    # list-timers output can lag briefly right after daemon-reload/enable.
    # Check each managed timer state directly and allow a short settle period.
    # Healthy = timer unit is active AND has a next trigger scheduled.
    if [[ "$DRY_RUN" == "false" ]]; then
        log_info "Verifying timers are scheduled ..."
        local expected_count="${#TIMERS[@]}"
        local healthy_count=0
        local attempts=10
        local delay_seconds=1
        local i
        for (( i=1; i<=attempts; i++ )); do
            healthy_count=$(_count_healthy_managed_timers)
            if [[ "$healthy_count" -eq "$expected_count" ]]; then
                break
            fi
            sleep "$delay_seconds"
        done

        if [[ "$healthy_count" -eq "$expected_count" ]]; then
            log_success "All managed timers are healthy ($healthy_count/$expected_count)."
        else
            log_warn "────────────────────────────────────────────────────────────────"
            log_warn "WARNING: Not all managed timers are healthy after enablement"
            log_warn "         (healthy: $healthy_count/$expected_count)."
            log_warn "Possible causes:"
            log_warn "  - A timer unit has an invalid setting (e.g. bad OnCalendar)"
            log_warn "  - A timer is being stopped by a conflicting unit relationship"
            log_warn "  - A timer is active but has no next trigger (NEXT='-')"
            log_warn "  - systemd daemon has stale unit state (retry daemon-reload)"
            log_warn "Investigate with:"
            log_warn "  systemctl list-timers --all | grep vaultwarden"
            log_warn "  systemctl status ${TIMERS[0]}"
            log_warn "  journalctl -xe --unit vaultwarden-health.timer"
            log_warn "────────────────────────────────────────────────────────────────"
        fi
    else
        log_info "[DRY RUN] Would check: systemctl is-active + NextElapseUSecRealtime for all managed timers"
    fi

    # ------------------------------------------------------------------
    # 5. Clear stale failed status from previous runs
    # ------------------------------------------------------------------
    log_info "Clearing stale failed status from all managed services ..."
    for svc in "${SERVICES[@]}"; do
        [[ "$svc" == *"@"* ]] && continue  # skip template unit
        _run systemctl reset-failed "$svc" 2>/dev/null || true
    done
    log_success "Stale failed states cleared."

    log_success "Installation complete."
    log_info "Next steps:"
    log_info "  Verify:    systemctl list-timers --all | grep vaultwarden"
    log_info "  Validate:  sudo ./setup.sh systemd validate"
    log_info "  Test run:  sudo systemctl start vaultwarden-health.service"
    log_info "  View logs: journalctl -u vaultwarden-health.service -n 50"
    log_info "  Env file:  $ENV_FILE  (add EMAIL_PROVIDER credentials here)"
    log_info "  Age key:   $AGE_KEY_DEST  (copied from secrets/keys/age-key.txt)"
}

# ---------------------------------------------------------------------------
# remove_units
# ---------------------------------------------------------------------------
remove_units() {
    _require_root
    log_header "VaultWarden-OCI systemd Timer Removal"

    for timer in "${TIMERS[@]}"; do
        if systemctl is-enabled "$timer" &>/dev/null; then
            if _run systemctl disable --now "$timer"; then
                log_success "Disabled: $timer"
            else
                log_warn "Failed to disable $timer -- it may already be inactive or masked."
                log_warn "  Check: systemctl status $timer"
            fi
        fi
    done

        for unit in "${TIMERS[@]}" "${SERVICES[@]}"; do
            local dest="$UNIT_DEST_DIR/$unit"
            if [[ -f "$dest" ]]; then
            _run rm -f "$dest"
            log_success "Removed: $dest"
        fi
    done

    # Clean up per-unit ReadWritePaths drop-in directories written by
    # _install_rwpaths_dropin (separate-volume mode). Leaving stale .d/
    # directories behind causes spurious ReadWritePaths entries on
    # reinstall and makes 'systemctl cat <unit>' output misleading.
    # Safe in boot-only mode: the directories simply won't exist.
    local -a _DROPIN_UNITS=("${_VW_DROPIN_UNITS[@]}")
    for unit in "${_DROPIN_UNITS[@]}"; do
        local dropin_dir="$UNIT_DEST_DIR/${unit}.d"
        local dropin_file="$dropin_dir/10-state-dir.conf"
        if [[ -f "$dropin_file" ]]; then
            _run rm -f "$dropin_file"
            log_success "Removed ReadWritePaths drop-in: $dropin_file"
        fi
        # Remove the .d/ dir only if it is now empty (preserve any
        # drop-ins installed by other tools, e.g. Docker or the OS).
        if [[ -d "$dropin_dir" ]] && [[ -z "$(ls -A "$dropin_dir" 2>/dev/null)" ]]; then
            _run rmdir "$dropin_dir"
            log_success "Removed empty drop-in dir: $dropin_dir"
        fi
    done

    _run systemctl daemon-reload
    log_success "All timer units removed and daemon reloaded."
    log_info "Scripts remain in $OPT_SCRIPTS_DIR -- remove manually if desired."

    if [[ -f "$ENV_FILE" ]]; then
        log_warn "────────────────────────────────────────────────────────────────"
        log_warn "NOTICE: EnvironmentFile was NOT removed automatically:"
        log_warn "  $ENV_FILE"
        log_warn "This file may contain API tokens and SMTP credentials."
        log_warn "Review its contents and remove it manually once you have"
        log_warn "confirmed the credentials are no longer needed or have been"
        log_warn "migrated elsewhere:"
        log_warn "  sudo rm -f $ENV_FILE $AGE_KEY_DEST"
        log_warn "  sudo rmdir --ignore-fail-on-non-empty $ENV_DIR"
        log_warn "────────────────────────────────────────────────────────────────"
    fi
}

# ---------------------------------------------------------------------------
# validate_installation
# ---------------------------------------------------------------------------
validate_installation() {
    _require_root
    log_header "VaultWarden-OCI Installation Validation"
    local errors=0
    local warnings=0

    log_info "[1/8] Checking installed scripts ..."
    local scripts_to_check=(maintenance.sh backup.sh)
    for script in "${scripts_to_check[@]}"; do
        local installed="$OPT_SCRIPTS_DIR/$script"
        if [[ ! -f "$installed" ]]; then
            log_error "  MISSING:        $installed"
            (( errors++ )) || true
        elif [[ ! -x "$installed" ]]; then
            log_error "  NOT EXECUTABLE: $installed"
            (( errors++ )) || true
        else
            log_success "  OK:             $installed"
        fi
    done

    # Check lib/ presence AND file permissions.
    # lib/*.sh files must be at least world-readable (644) so that a
    # non-root service user (User= in the unit) can source them. Warn on
    # 600 or 640 modes.
    log_info "[2/8] Checking installed lib/ and file permissions ..."
    if [[ ! -d "$OPT_SCRIPTS_DIR/lib" ]]; then
        log_error "  MISSING: $OPT_SCRIPTS_DIR/lib/"
        (( errors++ )) || true
    else
        log_success "  OK: $OPT_SCRIPTS_DIR/lib/"
        # Check that every *.sh lib file is readable by others (mode ends in 4 or higher)
        local bad_perm_files=()
        while IFS= read -r -d '' libfile; do
            local fmode
            fmode=$(stat -c '%a' "$libfile" 2>/dev/null || stat -f '%Lp' "$libfile" 2>/dev/null || echo "000")
            # Extract the 'other' permission digit (last character of octal mode)
            local other_bit="${fmode: -1}"
            if (( other_bit < 4 )); then
                bad_perm_files+=("$libfile ($fmode)")
            fi
        done < <(find "$OPT_SCRIPTS_DIR/lib" -type f -name '*.sh' -print0 2>/dev/null)

        if [[ ${#bad_perm_files[@]} -gt 0 ]]; then
            log_warn "  PERM WARNING: The following lib/*.sh files are not world-readable."
            log_warn "  A non-root service User= will fail to source them silently:"
            for f in "${bad_perm_files[@]}"; do
                log_warn "    $f"
            done
            log_warn "  Fix: sudo find $OPT_SCRIPTS_DIR/lib -name '*.sh' -exec chmod 644 {} +"
            log_warn "  Or re-run: sudo ./setup.sh systemd install"
            (( warnings++ )) || true
        else
            log_success "  OK: all lib/*.sh files are world-readable (mode >= 644)"
        fi
    fi
    local critical_lib="$OPT_SCRIPTS_DIR/lib/crypto.sh"
    if [[ ! -f "$critical_lib" ]]; then
        log_error "  MISSING: $critical_lib"
        (( errors++ )) || true
    else
        log_success "  OK: $critical_lib"
    fi

    log_info "[3/8] Checking installed unit files ..."
    for unit in "${SERVICES[@]}" "${TIMERS[@]}"; do
        local dest="$UNIT_DEST_DIR/$unit"
        if [[ ! -f "$dest" ]]; then
            log_error "  MISSING: $dest"
            (( errors++ )) || true
        else
            log_success "  OK: $dest"
        fi
    done

    log_info "[4/8] Checking timer enablement ..."
    for timer in "${TIMERS[@]}"; do
        if systemctl is-enabled "$timer" &>/dev/null; then
            log_success "  ENABLED:     $timer"
        else
            log_error   "  NOT ENABLED: $timer"
            (( errors++ )) || true
        fi
    done

    log_info "[5/8] Checking EnvironmentFile ..."
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error "  MISSING: $ENV_FILE"
        log_error "  Run: sudo ./setup.sh systemd install  (or create it manually)"
        (( errors++ )) || true
    else
        local env_perms
        env_perms=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null || echo "unknown")
        if [[ "$env_perms" != "600" ]]; then
            log_warn "  PERMISSIONS: $ENV_FILE is mode $env_perms (expected 600)"
            log_warn "  Fix: sudo chmod 600 $ENV_FILE"
            (( warnings++ )) || true
        else
            log_success "  OK: $ENV_FILE (mode 600)"
        fi
    fi

    log_info "[6/8] Checking age key installation ..."
    if [[ ! -f "$AGE_KEY_DEST" ]]; then
        log_error "  MISSING: $AGE_KEY_DEST"
        log_error "  Backup/health services cannot encrypt/decrypt without this key."
        log_error "  Fix: sudo ./setup.sh systemd install  (requires secrets/keys/age-key.txt)"
        (( errors++ )) || true
    else
        local key_perms
        key_perms=$(stat -c '%a' "$AGE_KEY_DEST" 2>/dev/null || stat -f '%Lp' "$AGE_KEY_DEST" 2>/dev/null || echo "unknown")
        if [[ "$key_perms" != "600" ]]; then
            log_warn "  PERMISSIONS: $AGE_KEY_DEST is mode $key_perms (expected 600)"
            log_warn "  Fix: sudo chmod 600 $AGE_KEY_DEST"
            (( warnings++ )) || true
        else
            log_success "  OK: $AGE_KEY_DEST (mode 600)"
        fi
    fi
    if [[ -f "$ENV_FILE" ]]; then
        if grep -q "^SOPS_AGE_KEY_FILE=" "$ENV_FILE" 2>/dev/null; then
            local configured_path
            configured_path=$(grep "^SOPS_AGE_KEY_FILE=" "$ENV_FILE" | head -1 | cut -d= -f2-)
            if [[ "$configured_path" == "$AGE_KEY_DEST" ]]; then
                log_success "  SOPS_AGE_KEY_FILE=$AGE_KEY_DEST (correct)"
            else
                log_warn "  SOPS_AGE_KEY_FILE is set to '$configured_path' (expected $AGE_KEY_DEST)"
                log_warn "  Fix: sudo ./setup.sh systemd install"
                (( warnings++ )) || true
            fi
        else
            log_error "  SOPS_AGE_KEY_FILE not set in $ENV_FILE"
            log_error "  Fix: sudo ./setup.sh systemd install"
            (( errors++ )) || true
        fi
    fi

    log_info "[7/8] Checking for split-brain (sha256 repo vs installed) ..."
    for script in "${scripts_to_check[@]}"; do
        local repo_src="$PROJECT_ROOT/$script"
        local installed="$OPT_SCRIPTS_DIR/$script"
        if [[ ! -f "$repo_src" || ! -f "$installed" ]]; then
            continue
        fi

        local expected_sum actual_sum
        expected_sum=$(_sha256 "$repo_src")
        actual_sum=$(_sha256 "$installed")
        if [[ "$expected_sum" != "$actual_sum" ]]; then
            log_warn "  STALE: $installed does not match repo source"
            log_warn "         repo      sha256: $expected_sum"
            log_warn "         installed sha256: $actual_sum"
            log_warn "         Re-run: sudo ./setup.sh systemd install"
            (( warnings++ )) || true
        else
            log_success "  UP-TO-DATE: $script (sha256 match)"
        fi
    done

    # Verify timers are healthy.
    # 'systemctl is-enabled' only checks the symlink; it does NOT confirm
    # the timer unit is currently active in systemd nor that it has a future
    # trigger time.
    log_info "[8/8] Checking timers are scheduled (systemctl list-timers) ..."
    local expected_count="${#TIMERS[@]}"
    local healthy_count
    healthy_count=$(_count_healthy_managed_timers)
    if [[ "$healthy_count" -eq "$expected_count" ]]; then
        log_success "  All managed timers are healthy ($healthy_count/$expected_count)."
    else
        log_warn "  WARNING: Managed timers healthy: $healthy_count/$expected_count."
        log_warn "  One or more timers are enabled but unhealthy (inactive or NEXT='-') — check:"
        log_warn "    systemctl list-timers --all | grep vaultwarden"
        log_warn "    systemctl status vaultwarden-db-backup.timer"
        log_warn "    journalctl -xe --unit vaultwarden-health.timer"
        log_warn "  Try: sudo systemctl restart vaultwarden-db-backup.timer vaultwarden-health.timer"
        (( warnings++ )) || true
    fi

    echo ""
    if (( errors > 0 )); then
        log_error "Validation FAILED: ${errors} error(s), ${warnings} warning(s)."
        log_error "Run: sudo ./setup.sh systemd install to resolve errors."
        return 1
    elif (( warnings > 0 )); then
        log_warn  "Validation passed with ${warnings} warning(s) -- review output above."
        return 0
    else
        log_success "Validation PASSED: installation is consistent with repository."
        return 0
    fi
}

# ---------------------------------------------------------------------------
# show_status
# ---------------------------------------------------------------------------
show_status() {
    log_header "VaultWarden-OCI systemd Timer Status"
    echo ""
    systemctl list-timers --all 2>/dev/null | grep vaultwarden || log_info "No vaultwarden timers active."
    echo ""
    for svc in "${SERVICES[@]}"; do
        # Skip the template unit -- it has no standalone status
        [[ "$svc" == *"@"* ]] && continue
        log_info "--- $svc ---"
        { systemctl status "$svc" --no-pager -l 2>/dev/null | head -20; } || true
        echo ""
    done
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
_sd_main() {
    if [[ "$STATUS" == "true" ]]; then
        show_status
        exit 0
    fi

    if [[ "$VALIDATE" == "true" ]]; then
        validate_installation
        exit $?
    fi

    if [[ "$REMOVE" == "true" ]]; then
        remove_units
        exit 0
    fi

    if [[ "$INSTALL" == "true" ]]; then
        install_units
        exit 0
    fi

    log_info "No operation specified. Use --help for options."
    _sd_show_help
    exit 1
}
    _sd_main "$@"
}


main() {
    log_header "VaultWarden-OCI Setup - Security Hardened Edition"

    if [[ -n "$PHASE" ]]; then
        case "$PHASE" in
            secrets)
                run_phase_secrets "${PHASE_ARGS[@]}"
                return $?
                ;;
            systemd)
                run_phase_systemd "${PHASE_ARGS[@]}"
                return $?
                ;;
        esac
    fi

    if ! is_root; then log_error "Must run as root."; exit 1; fi

    SETUP_LOCK_FILE="/run/lock/vaultwarden-setup.lock"
    # Use automatic FD allocation instead of hardcoded FD for the lock.
    # /run/lock is the FHS-correct transient lock location; /var/lock
    #   is a legacy symlink that ProtectSystem=strict makes read-only in systemd units.
    # A trap removes the lock file on EXIT so a crash does not leave a stale lock.
    local SETUP_LOCK_FD
    exec {SETUP_LOCK_FD}>"$SETUP_LOCK_FILE"
    if ! flock -n "$SETUP_LOCK_FD"; then
        log_error "Another setup instance is already running (could not acquire lock)."
        log_error "Wait for it to complete, then retry."
        log_error "If the lock is stale, remove: ${SETUP_LOCK_FILE}"
        exit 1
    fi
    _setup_cleanup() {
        rm -f "$SETUP_LOCK_FILE" 2>/dev/null || true
        # Clean TMP_WORKDIR here because this trap overrides the startup trap.
        rm -rf "$TMP_WORKDIR" 2>/dev/null || true
    }
    trap _setup_cleanup EXIT HUP INT TERM

    if [[ -n "${SOPS_VERSION:-}" ]]; then
        log_info "SOPS version pinned: ${SOPS_VERSION}"
    else
        log_info "SOPS version: will resolve latest from GitHub at install time"
    fi

    local setup_phases=(
        "check_disk_space:Disk Space Preflight:true"
        "create_swapfile:Swap Configuration:false"
        "setup_data_volume:Data Volume Provisioning:true"
        "install_dependencies:Dependency Installation:true"
        "verify_dependencies:Dependency Verification:true"
        "setup_user_permissions:User Permissions:false"
        "create_env_file:Environment Configuration:true"
        "install_docker_mount_guard:Docker Mount Guard:false"
        "create_docker_compose:Docker Compose Setup:true"
        "setup_directories:Directory Creation:true"
        "generate_age_keys:Encryption Keys:true"
        "create_sops_config:SOPS Configuration:true"
        "create_empty_secrets_structure:Empty Secrets Structure:true"
        "set_script_permissions:Script Permissions:false"
        "setup_firewall:Firewall Configuration:false"
        "validate_ssh_config:SSH Hardening Validation:false"
        "cleanup_setup_deps:Setup Cleanup:false"
    )

    local failed_phases=() warned_phases=()
    for phase_info in "${setup_phases[@]}"; do
        IFS=':' read -r phase_func phase_name phase_critical <<< "$phase_info"
        local result=0
        execute_phase "$phase_func" "$phase_name" "$phase_critical" || result=$?
        case $result in
            0) ;;
            1) failed_phases+=("$phase_name [CRITICAL]"); break ;;
            2) warned_phases+=("$phase_name") ;;
            *) failed_phases+=("$phase_name [UNKNOWN ERROR: $result]"); [[ "$phase_critical" == "true" ]] && break ;;
        esac
    done

    if [[ ${#failed_phases[@]} -gt 0 ]]; then
        log_error "Setup FAILED - Critical phases did not complete"
        exit 1
    fi

    if [[ ${#warned_phases[@]} -gt 0 ]]; then
        log_warn "Non-critical phases had warnings: ${warned_phases[*]}"
        log_warn "Review the output above for details. These phases can be re-run manually."
    fi

    if [[ -x "${SCRIPT_DIR}/utilities/setup-iptables.sh" ]]; then
        echo "INFO: Applying VaultWarden iptables rules..."
        if "${SCRIPT_DIR}/utilities/setup-iptables.sh"; then
            echo "OK: VaultWarden iptables rules applied"
        else
            echo "WARN: utilities/setup-iptables.sh did not complete successfully" >&2
            echo "WARN: Run it manually after setup, or enable systemd/vaultwarden-iptables.service" >&2
        fi
    else
        echo "WARN: utilities/setup-iptables.sh not found or not executable" >&2
        echo "WARN: Run it manually after setup, or enable systemd/vaultwarden-iptables.service" >&2
    fi

    if [[ "$AUTO_MODE" == "true" ]]; then
        log_info "=== Auto Mode: Configuring secrets ==="
        local secrets_args=(--auto --skip-optional --quiet-summary)
        [[ "$FORCE" == "true" ]] && secrets_args+=(--force)
        if ! run_phase_secrets "${secrets_args[@]}"; then
            log_warn "Secrets auto-configuration encountered issues — run './setup.sh secrets' after editing .env"
        fi
    fi

    if [[ "$AUTO_MODE" != "true" ]]; then
        read -r -p "Press Enter to view CRITICAL recovery information..."
        show_post_install_summary "interactive"
    else
        show_post_install_summary "auto"
    fi
    return 0
}

main "$@"
