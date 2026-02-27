#!/usr/bin/env bash
# setup.sh - VaultWarden-OCI Setup Script (SECURITY HARDENED)

set -euo pipefail
set +x

# =============================================================================
# DEPENDENCY VERSION PINS
# To pin a specific version, set the variable. Leave blank ("") to auto-resolve
# the latest release at runtime via the GitHub API.
#
# Examples:
#   SOPS_VERSION="v3.9.4"   <- pinned
#   SOPS_VERSION=""          <- auto-resolve latest (default)
#
# You may also override any of these from the environment before running:
#   SOPS_VERSION=v3.9.4 sudo ./setup.sh --domain ...
# =============================================================================
SOPS_VERSION="${SOPS_VERSION:-}"   # e.g. "v3.9.4" — leave blank for latest
AGE_VERSION="${AGE_VERSION:-}"     # e.g. "v1.2.0" — leave blank for latest (only used if installing age as binary instead of apt)
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

REQUIRED_LIBS=("lib/common.sh" "lib/crypto.sh" "lib/docker.sh" "lib/security.sh" "lib/backup_utils.sh" "lib/secrets.sh")
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

DOMAIN=""
ADMIN_EMAIL=""
AUTO_MODE=false
USE_LATEST=false
SKIP_DEPS=false
FORCE=false
DRY_RUN=false
ENTROPY_THRESHOLD=200
ENTROPY_MAX_WAIT=60
CLEAN_DOMAIN=""

show_help() {
    cat << 'EOF'
VaultWarden-OCI Setup Tool - Security Hardened Edition
USAGE: sudo ./setup.sh --domain DOMAIN --email EMAIL [OPTIONS]
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain) DOMAIN="$2"; shift 2 ;;
        --email) ADMIN_EMAIL="$2"; shift 2 ;;
        --auto) AUTO_MODE=true; shift ;;
        --use-latest) USE_LATEST=true; shift ;;
        --skip-deps) SKIP_DEPS=true; shift ;;
        --force) FORCE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

validate_domain_secure() {
    local domain="$1"
    if [[ ${#domain} -gt 253 ]]; then return 1; fi
    if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then return 1; fi
    return 0
}

validate_email_secure() {
    local email="$1"
    if [[ ${#email} -gt 254 ]]; then return 1; fi
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then return 1; fi
    return 0
}

if [[ -z "$DOMAIN" ]] || [[ -z "$ADMIN_EMAIL" ]]; then show_help; exit 1; fi
if ! validate_domain_secure "$DOMAIN"; then log_error "Invalid domain format"; exit 1; fi
if ! validate_email_secure "$ADMIN_EMAIL"; then log_error "Invalid email format"; exit 1; fi

# FIX [BUG-05]: Use jq (already a required dep) instead of grep|cut to parse
# the GitHub API response. Add semver pattern validation so that malformed API
# responses (HTML error pages, empty strings, truncated JSON) produce a clear
# error with a version-pin hint rather than silently constructing an invalid
# download URL and installing a corrupt binary to /usr/local/bin/sops.
#
# Resolve a GitHub latest release tag. Usage: resolve_github_latest OWNER/REPO
# Returns the tag string (e.g. "v3.9.4") or exits 1 on failure.
resolve_github_latest() {
    local repo="$1"
    local tag

    tag=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
        | jq -r '.tag_name // empty')

    # Validate the result looks like a semver tag before using it to
    # construct a download URL. Malformed API responses produce empty
    # string or HTML, both of which fail this guard.
    if [[ -z "$tag" ]] || [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9] ]]; then
        log_error "Could not resolve a valid release tag for ${repo}."
        log_error "Set SOPS_VERSION=vX.Y.Z at the top of setup.sh to bypass."
        return 1
    fi

    echo "$tag"
}

# FIX [BUG-04]: Replace curl|sh Docker install with the direct apt-repo method.
# The convenience script (get.docker.com) is executed as root without any
# integrity check, and does not support Ubuntu 24.10 (Oracular). This function:
#   - Adds Docker's official GPG key (fingerprint from docs.docker.com).
#   - Pins the apt source to 'noble' (24.04 LTS), which is the correct
#     repository for Ubuntu 24.10 — Docker does not publish an 'oracular' repo,
#     but noble packages are ABI-compatible and work correctly on 24.10.
#   - Installs docker-ce, docker-ce-cli, containerd.io, and the Compose plugin
#     as explicit, auditable apt packages.
install_docker_apt() {
    log_info "Installing Docker via official apt repository (noble codename)..."

    # Add Docker's official GPG key
    # Fingerprint: 9DC8 5822 9FC7 DD38 854A  E2D8 8D81 803C 0EBF CD88
    # Verify at: https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg || return 1
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Use 'noble' (24.04 LTS) codename for Ubuntu 24.10 — Docker does not
    # publish a 24.10 (oracular) repository; noble packages run correctly
    # on 24.10 (same ABI, tested upstream).
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu noble stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq || return 1
    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin || return 1

    systemctl enable --now docker || return 1
    usermod -aG docker "$(get_real_user)" || return 1
    log_success "Docker installed via apt repository"
    return 0
}

install_dependencies() {
    if [[ "$SKIP_DEPS" == "true" ]]; then return 0; fi
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would install dependencies"; return 0; fi

    log_info "Installing system dependencies..."

    local basic_packages=("age" "make" "nano" "rclone" "sqlite3" "jq" "ufw" "curl" "wget" "unzip" "git" "gpg" "coreutils" "haveged" "dnsutils" "rsync" "python3" "python3-argon2" "apache2-utils" "cron")
    local missing_packages=()
    for pkg in "${basic_packages[@]}"; do
        ! dpkg -s "$pkg" >/dev/null 2>&1 && missing_packages+=("$pkg")
    done

    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        apt-get update -qq || return 1
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y "${missing_packages[@]}" || return 1
    fi

    if ! systemctl is-active --quiet haveged; then
        systemctl enable haveged 2>/dev/null || true
        systemctl start haveged || log_warn "Failed to start haveged"
    fi

    # FIX [BUG-04]: Use apt-repo installation instead of curl|sh.
    if ! command -v docker >/dev/null 2>&1; then
        install_docker_apt || return 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        apt-get install -y docker-compose-plugin || return 1
    fi

    if ! command -v sops >/dev/null 2>&1; then
        local arch; arch=$(dpkg --print-architecture)
        [[ "$arch" == "armhf" ]] && arch="arm"

        # Use pinned version if set at top of script, otherwise resolve latest.
        local sops_ver="${SOPS_VERSION:-}"
        if [[ -z "$sops_ver" ]]; then
            log_info "SOPS_VERSION not pinned — resolving latest from GitHub..."
            sops_ver=$(resolve_github_latest "getsops/sops") || return 1
        fi
        log_info "Installing SOPS ${sops_ver}..."
        wget -q "https://github.com/getsops/sops/releases/download/${sops_ver}/sops-${sops_ver}.linux.${arch}" \
            -O /usr/local/bin/sops || return 1
        chmod +x /usr/local/bin/sops || return 1
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
    groups "$real_user" | grep -q docker || usermod -aG docker "$real_user" || return 1

    # Scope chown to non-secrets paths to avoid clobbering future key permissions.
    # secrets/ is handled explicitly by setup_directories and generate_age_keys.
    find "$PROJECT_ROOT" -maxdepth 1 \
        ! -name 'secrets' \
        ! -path "$PROJECT_ROOT" \
        -exec chown -R "$real_user:$(id -g -n "$real_user")" {} \; 2>/dev/null || true

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
        if grep -qF "DOMAIN=$DOMAIN" "$env_file" && grep -qF "ADMIN_EMAIL=$ADMIN_EMAIL" "$env_file"; then
            return 0
        fi
    fi

    cp "$env_template" "$env_file" || return 1

    local real_user; real_user=$(get_real_user)
    local user_id; user_id=$(id -u "$real_user")
    local group_id; group_id=$(id -g "$real_user")
    local detected_ssh_log_path; detected_ssh_log_path=$(detect_ssh_log_path 2>/dev/null)

    local domain_with_protocol
    [[ "$DOMAIN" =~ ^https?:// ]] && domain_with_protocol="$DOMAIN" || domain_with_protocol="https://$DOMAIN"

    local clean_domain; clean_domain=$(echo "$domain_with_protocol" | sed -E 's|https?://||; s|/.*$||')
    CLEAN_DOMAIN="$clean_domain"

    local temp_env="$TMP_WORKDIR/env.tmp"
    awk -v domain="$domain_with_protocol" -v name="$clean_domain" -v email="$ADMIN_EMAIL" \
        -v uid="$user_id" -v gid="$group_id" -v smtp_from="noreply@$clean_domain" -v ssh_log="$detected_ssh_log_path" \
        '{
            sub(/^DOMAIN=.*/, "DOMAIN=" domain);
            sub(/^DOMAIN_NAME=.*/, "DOMAIN_NAME=" name);
            sub(/^ADMIN_EMAIL=.*/, "ADMIN_EMAIL=" email);
            sub(/^PUID=.*/, "PUID=" uid);
            sub(/^PGID=.*/, "PGID=" gid);
            sub(/^SMTP_FROM=.*/, "SMTP_FROM=" smtp_from);
            sub(/^SSH_LOG_PATH=.*/, "SSH_LOG_PATH=" ssh_log);
            print;
        }' "$env_file" > "$temp_env"

    mv "$temp_env" "$env_file" || return 1

    if [[ "$USE_LATEST" == "true" ]]; then
        awk '{
            sub(/^VAULTWARDEN_VERSION=.*/, "VAULTWARDEN_VERSION=latest");
            sub(/^CADDY_VERSION=.*/, "CADDY_VERSION=latest");
            sub(/^FAIL2BAN_VERSION=.*/, "FAIL2BAN_VERSION=latest");
            sub(/^POSTFIX_VERSION=.*/, "POSTFIX_VERSION=latest");
            print;
        }' "$env_file" > "$temp_env"
        mv "$temp_env" "$env_file" || return 1
    fi

    chown "$real_user:$(id -g -n "$real_user")" "$env_file" || return 1
    chmod 600 "$env_file" || return 1
    return 0
}

setup_directories() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would setup directories"; return 0; fi

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n "$real_user")

    local dirs=("secrets" "secrets/keys" "secrets/.docker_secrets" "backups")
    for dir in "${dirs[@]}"; do
        ensure_dir "$dir" 755 || return 1
        chown "$real_user:$real_group" "$dir" || return 1
    done

    chmod 700 "secrets" "secrets/keys" "secrets/.docker_secrets" 2>/dev/null || true
    chmod 755 "backups" 2>/dev/null || true

    local puid; puid=$(id -u "$real_user")
    local pgid; pgid=$(id -g "$real_user")
    local project_state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"

    if ! sudo mkdir -p "${project_state_dir}"/{data,logs/{vaultwarden,caddy,fail2ban,postfix},caddy/{data,config},fail2ban}; then
        return 1
    fi

    sudo chown -R "${puid}:${pgid}" "$project_state_dir" || return 1
    sudo chmod -R 755 "$project_state_dir" || return 1
    return 0
}

check_entropy() {
    local entropy; entropy=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo "0")
    (( entropy >= ENTROPY_THRESHOLD )) && return 0

    local waited=0
    while (( waited < ENTROPY_MAX_WAIT )); do
        sleep 5
        waited=$((waited + 5))
        entropy=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo "0")
        (( entropy >= ENTROPY_THRESHOLD )) && return 0
    done
    return 1
}

generate_age_keys() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would generate Age keys"; return 0; fi

    check_entropy || return 1
    local age_key_file="secrets/keys/age-key.txt"
    if [[ -f "$age_key_file" ]] && [[ "$FORCE" != "true" ]]; then
        check_age_key "$age_key_file" 2>/dev/null && return 0
    fi

    local real_user; real_user=$(get_real_user)
    generate_age_key "$age_key_file" "$FORCE" || return 1
    chown "$real_user:$(id -g -n "$real_user")" "$age_key_file" || return 1
    chmod 600 "$age_key_file" || return 1
    return 0
}

create_sops_config() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would create SOPS config"; return 0; fi

    local sops_config=".sops.yaml"
    local age_key_file="secrets/keys/age-key.txt"
    if [[ -f "$sops_config" ]] && [[ "$FORCE" != "true" ]]; then
        grep -q "creation_rules:" "$sops_config" && grep -q "age:" "$sops_config" && return 0
    fi

    local age_public_key; age_public_key=$(get_age_public_key "$age_key_file") || return 1
    cat > "$sops_config" << EOF
creation_rules:
  - path_regex: .*\\.yaml$
    age: $age_public_key
EOF
    chown "$(get_real_user):$(id -g -n "$(get_real_user)")" "$sops_config" || return 1
    return 0
}

create_empty_secrets_structure() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would create secrets structure"; return 0; fi

    local secrets_file="$PROJECT_ROOT/secrets/secrets.yaml"
    local age_key_file="$PROJECT_ROOT/secrets/keys/age-key.txt"

    if [[ -f "$secrets_file" ]] && [[ "$FORCE" != "true" ]]; then
        export SOPS_AGE_KEY_FILE="$age_key_file"
        if sops -d "$secrets_file" >/dev/null 2>&1; then
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
backup_passphrase: PLACEHOLDER_NOT_CONFIGURED
push_installation_id: PLACEHOLDER_NOT_CONFIGURED
push_installation_key: PLACEHOLDER_NOT_CONFIGURED
caddy_cloudflare_dns_token: PLACEHOLDER_NOT_CONFIGURED
fail2ban_cloudflare_firewall_token: PLACEHOLDER_NOT_CONFIGURED
EOF
    chmod 600 "$temp_secrets"
    export SOPS_AGE_KEY_FILE="$age_key_file"
    sops --encrypt --output "$secrets_file" "$temp_secrets" || return 1
    chmod 600 "$secrets_file" || return 1
    chown "$(get_real_user):$(id -g -n "$(get_real_user)")" "$secrets_file" || return 1
    return 0
}

setup_secrets_interactively() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would configure secrets interactively"; return 0; fi

    chmod +x "$PROJECT_ROOT/setup-secrets.sh" 2>/dev/null || true
    local secrets_configured=false
    if [[ -f "secrets/secrets.yaml" ]]; then
        export SOPS_AGE_KEY_FILE="$PROJECT_ROOT/secrets/keys/age-key.txt"
        if sops -d "secrets/secrets.yaml" 2>/dev/null | grep -q "PLACEHOLDER_NOT_CONFIGURED"; then
            secrets_configured=false
        else
            secrets_configured=true
        fi
    fi

    if [[ "$secrets_configured" == "true" && "$FORCE" != "true" ]]; then
        [[ "$AUTO_MODE" == "true" ]] && return 0
        read -r -p "Secrets already configured. Reconfigure? (yes/no): " reconfigure
        [[ "$reconfigure" != "yes" ]] && return 0
    fi

    if [[ "$AUTO_MODE" == "true" ]]; then
        ./setup-secrets.sh --auto --skip-optional || return 1
        return 0
    else
        read -r -p "Configure secrets interactively? (yes/no): " do_setup
        [[ "$do_setup" == "yes" ]] && ./setup-secrets.sh || return 0
    fi
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
    chmod 644 "$compose_file" || return 1
    return 0
}

set_script_permissions() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would set script permissions"; return 0; fi

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n "$real_user")

    local scripts=("setup.sh" "setup-secrets.sh" "edit-secrets.sh" "health.sh" "update.sh" "backup.sh" "restore.sh" "startup.sh" "maintenance.sh" "cron-setup.sh" "create-breakglass-admin.sh" "db-maint.sh" "update-dns.sh" "test-email-simple.sh")
    for script in "${scripts[@]}"; do
        if [[ -f "$script" ]]; then
            chmod +x "$script"
            chown "$real_user:$real_group" "$script" 2>/dev/null || true
        fi
    done

    if [[ -d "lib" ]]; then
        find "lib" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
        find "lib" -name "*.sh" -exec chown "$real_user:$real_group" {} \; 2>/dev/null || true
    fi
    return 0
}

# FIX [BUG-07]: Restrict UFW web ports to Cloudflare IP ranges only.
# The previous implementation opened ports 80 and 443 to 0.0.0.0/0, which
# silently violated the Cloudflare-only security posture described in the README:
# any attacker who knew the server IP could bypass Cloudflare entirely and hit
# Caddy directly, including brute-forcing the admin endpoint without Fail2Ban's
# Cloudflare API blocks having any effect.
#
# This function restricts ingress on 80/443 to Cloudflare's published IPv4 ranges.
# A hardcoded fallback list is used if the live fetch fails, so setup is never
# network-gated on Cloudflare availability.
# SSH remains unrestricted because it is a direct (non-proxied) connection.
setup_firewall() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would configure firewall"; return 0; fi

    local ssh_port
    ssh_port=$(awk '/^Port/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)
    ssh_port=${ssh_port:-22}

    # Cloudflare IPv4 ranges — hardcoded fallback list.
    # Canonical source: https://www.cloudflare.com/ips-v4
    # Last verified: 2025. Run maintenance.sh to refresh if needed.
    local cf_ips_fallback=(
        "173.245.48.0/20"
        "103.21.244.0/22"
        "103.22.200.0/22"
        "103.31.4.0/22"
        "141.101.64.0/18"
        "108.162.192.0/18"
        "190.93.240.0/20"
        "188.114.96.0/20"
        "197.234.240.0/22"
        "198.41.128.0/17"
        "162.158.0.0/15"
        "104.16.0.0/13"
        "104.24.0.0/14"
        "172.64.0.0/13"
        "131.0.72.0/22"
    )

    # Attempt live fetch; fall back to hardcoded list on any failure.
    local cf_ips=()
    local fetched
    if fetched=$(curl -fsSL --max-time 10 https://www.cloudflare.com/ips-v4 2>/dev/null) \
       && [[ -n "$fetched" ]]; then
        mapfile -t cf_ips <<< "$fetched"
        log_info "Cloudflare IP list fetched live (${#cf_ips[@]} ranges)"
    else
        cf_ips=("${cf_ips_fallback[@]}")
        log_warn "Could not fetch live Cloudflare IPs — using hardcoded fallback list"
    fi

    # Idempotency: skip firewall configuration only if ALL required rules are
    # already present and active (SSH + at least one Cloudflare-scoped rule).
    if ufw status | grep -q "Status: active" && \
       ufw status | grep -q "${ssh_port}/tcp" && \
       ufw status | grep -qF "173.245.48.0/20"; then
        log_success "Firewall already configured and active (Cloudflare-scoped)"
        return 0
    fi

    # SSH: direct connection, not proxied — allow from any source.
    ufw allow "${ssh_port}/tcp"

    # Web ports: Cloudflare-only.
    local cidr
    for cidr in "${cf_ips[@]}"; do
        [[ -z "$cidr" ]] && continue
        ufw allow from "$cidr" to any port 80  proto tcp
        ufw allow from "$cidr" to any port 443 proto tcp
    done

    ufw status | grep -q "Status: active" || echo "y" | ufw enable
    log_success "Firewall configured: SSH open, web ports restricted to Cloudflare IPs"
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
    if ! "$phase_func"; then
        exit_code=$?
        log_error "Phase failed: $phase_name (exit code: $exit_code)"
        [[ "$phase_critical" == "true" ]] && return 1 || return 2
    else
        log_success "Phase completed: $phase_name"
        return 0
    fi
}

show_post_install_summary() {
    local mode="${1:-interactive}"
    [[ "$mode" == "interactive" ]] && clear

    # FIX [BUG-10]: Replace echo -e with printf. The README states echo -e was
    # removed everywhere in favour of printf; this was the one remaining violation.
    printf '%s' "${COLOR_RED}"
    cat << "EOF"
    ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !
    !                                                             !
    !   CRITICAL: SAVE THIS INFORMATION FOR DISASTER RECOVERY     !
    !                                                             !
    ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !
EOF
    printf '%s' "${COLOR_RESET}"

    local age_pub_key=""
    if [[ -f "secrets/keys/age-key.txt" ]]; then
        age_pub_key=$(grep "public key" "secrets/keys/age-key.txt" | cut -d: -f2 | tr -d ' ' || echo "MISSING")
        printf 'SOPS Age Public Key:      %s%s%s\n' "${COLOR_GREEN}" "${age_pub_key}" "${COLOR_RESET}"
        printf 'SOPS Age Private Key:     %sCat secrets/keys/age-key.txt to view (BACKUP THIS FILE!)%s\n' "${COLOR_RED}" "${COLOR_RESET}"
    fi

    printf '\n%s--- EXTERNAL CONFIGURATION CHECKLIST (Verify You Have These) ---%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
    printf '1. [ ] Domain Name:          %s%s%s\n' "${COLOR_GREEN}" "${DOMAIN:-Not Set}" "${COLOR_RESET}"
    printf '2. [ ] Admin Email:          %s%s%s\n' "${COLOR_GREEN}" "${ADMIN_EMAIL:-Not Set}" "${COLOR_RESET}"
    printf '\n%s--- NEXT STEPS ---%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
    printf '1. Run %s./edit-secrets.sh%s to input external secrets.\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
    printf '2. Run %smake up%s to start the application.\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
    printf '3. Run %ssudo ./cron-setup.sh --install%s to setup automation.\n' "${COLOR_YELLOW}" "${COLOR_RESET}"

    if [[ "$mode" == "interactive" ]]; then
        printf '\n%s!!! PRESS ENTER TO CLEAR THIS SCREEN AND FINISH !!!%s\n' "${COLOR_RED}" "${COLOR_RESET}"
        read -r
        clear
    fi
}

main() {
    log_header "VaultWarden-OCI Setup - Security Hardened Edition"
    if ! is_root; then log_error "Must run as root."; exit 1; fi

    # Log version pin status for transparency
    if [[ -n "${SOPS_VERSION:-}" ]]; then
        log_info "SOPS version pinned: ${SOPS_VERSION}"
    else
        log_info "SOPS version: will resolve latest from GitHub at install time"
    fi

    local setup_phases=(
        "install_dependencies:Dependency Installation:true"
        "verify_dependencies:Dependency Verification:true"
        "setup_user_permissions:User Permissions:false"
        "create_env_file:Environment Configuration:true"
        "create_docker_compose:Docker Compose Setup:true"
        "setup_directories:Directory Creation:true"
        "generate_age_keys:Encryption Keys:true"
        "create_sops_config:SOPS Configuration:true"
        "create_empty_secrets_structure:Empty Secrets Structure:true"
        "setup_secrets_interactively:Secrets Configuration:false"
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

    if [[ "$AUTO_MODE" != "true" ]]; then
        read -r -p "Press Enter to view CRITICAL recovery information..."
        show_post_install_summary "interactive"
    else
        show_post_install_summary "auto"
    fi
    exit 0
}

main "$@"
