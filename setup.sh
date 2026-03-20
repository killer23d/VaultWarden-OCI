#!/usr/bin/env bash
# setup.sh - VaultWarden-OCI Setup Script

set -euo pipefail
set +x

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

OPTIONS:
  --auto          Non-interactive install. Auto-generates passwords/passphrases;
                  external credentials (CF tokens, SMTP) remain as CHANGE_ME
                  placeholders — the post-install summary lists exact commands
                  to rotate them. Does NOT imply --use-latest.
  --use-latest    Override pinned container versions with 'latest' tags in .env.
  --skip-deps     Skip dependency installation (assumes already installed).
  --force         Overwrite existing .env, secrets, and docker-compose files.
                  WARNING: Also regenerates the Age encryption key. All
                  existing encrypted secrets become permanently unrecoverable
                  without a prior recovery kit export. Run
                  './edit-secrets.sh --export-recovery-kit' BEFORE using
                  --force on a running installation.
  --dry-run       Print what would happen without making any changes.
  --help          Show this help and exit.
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

if [[ -z "$DOMAIN" ]] || [[ -z "$ADMIN_EMAIL" ]]; then show_help; exit 1; fi
if ! validate_domain_secure "$DOMAIN"; then log_error "Invalid domain format"; exit 1; fi
if ! validate_email_secure "$ADMIN_EMAIL"; then log_error "Invalid email format"; exit 1; fi

resolve_github_latest() {
    local repo="$1"
    local tag

    tag=$(curl -fsSL --max-time 30 "https://api.github.com/repos/${repo}/releases/latest" \
        | jq -r '.tag_name // empty')

    if [[ -z "$tag" ]] || [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9] ]]; then
        log_error "Could not resolve a valid release tag for ${repo}."
        log_error "Set SOPS_VERSION=vX.Y.Z at the top of setup.sh to bypass."
        return 1
    fi

    echo "$tag"
}

install_docker() {
    # Skip if Docker is already functional
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
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
    groups "$real_user" | grep -q docker || usermod -aG docker "$real_user" || return 1

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
            # Latest mode: all version fields must already be 'latest'
            if grep -qE '^VAULTWARDEN_VERSION=latest' "$env_file" && \
               grep -qE '^CADDY_VERSION=latest'       "$env_file" && \
               grep -qE '^FAIL2BAN_VERSION=latest'    "$env_file" && \
               grep -qE '^POSTFIX_VERSION=latest'     "$env_file"; then
                latest_matches=true
            fi
        else
            if ! grep -qE '^(VAULTWARDEN|CADDY|FAIL2BAN|POSTFIX)_VERSION=latest' "$env_file"; then
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

    local temp_env
    temp_env=$(mktemp -p "$(dirname "$env_file")" .env.tmp.XXXXXXXXXX) || return 1

    AWK_DOMAIN="$domain_with_protocol" \
    AWK_NAME="$clean_domain" \
    AWK_EMAIL="$ADMIN_EMAIL" \
    AWK_UID="$user_id" \
    AWK_GID="$group_id" \
    AWK_SMTP_FROM="noreply@$clean_domain" \
    AWK_SSH_LOG="$detected_ssh_log_path" \
    awk '
        {
            sub(/^DOMAIN=.*/, "DOMAIN=" ENVIRON["AWK_DOMAIN"]);
            sub(/^DOMAIN_NAME=.*/, "DOMAIN_NAME=" ENVIRON["AWK_NAME"]);
            sub(/^ADMIN_EMAIL=.*/, "ADMIN_EMAIL=" ENVIRON["AWK_EMAIL"]);
            sub(/^PUID=.*/, "PUID=" ENVIRON["AWK_UID"]);
            sub(/^PGID=.*/, "PGID=" ENVIRON["AWK_GID"]);
            sub(/^SMTP_FROM=.*/, "SMTP_FROM=" ENVIRON["AWK_SMTP_FROM"]);
            sub(/^SSH_LOG_PATH=.*/, "SSH_LOG_PATH=" ENVIRON["AWK_SSH_LOG"]);
            print;
        }' "$env_file" > "$temp_env"

    mv "$temp_env" "$env_file" || return 1

    if [[ "$USE_LATEST" == "true" ]]; then
        temp_env=$(mktemp -p "$(dirname "$env_file")" .env.tmp.XXXXXXXXXX) || return 1
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

    local secrets_dirs=("secrets" "secrets/keys" "secrets/.docker_secrets")
    for dir in "${secrets_dirs[@]}"; do
        ensure_dir "$dir" 700 || return 1
        chown "$real_user:$real_group" "$dir" || return 1
    done

    ensure_dir "backups" 755 || return 1
    chown "$real_user:$real_group" "backups" || return 1

    local puid; puid=$(id -u "$real_user")
    local pgid; pgid=$(id -g "$real_user")
    local project_state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"

    if ! mkdir -p "${project_state_dir}"/{data,logs/{vaultwarden,caddy,fail2ban,postfix},caddy/{data,config},fail2ban}; then
        return 1
    fi

    chown -R "${puid}:${pgid}" "$project_state_dir" || return 1

    find "${project_state_dir}" -type d -exec chmod 750 {} \; 2>/dev/null || return 1
    find "${project_state_dir}" -type f -exec chmod 640 {} \; 2>/dev/null || true

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
                    log_error "Run './edit-secrets.sh --export-recovery-kit' first, then"
                    log_error "retry with --force WITHOUT --auto to confirm interactively."
                    return 1
                else
                    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    log_warn "  WARNING: --force will REGENERATE the Age encryption key."
                    log_warn "  ALL existing encrypted secrets will become permanently"
                    log_warn "  unrecoverable without a prior recovery kit export."
                    log_warn "  Run './edit-secrets.sh --export-recovery-kit' FIRST."
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
fail2ban_cloudflare_firewall_token: PLACEHOLDER_NOT_CONFIGURED
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

set_script_permissions() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would set script permissions"; return 0; fi

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n "$real_user")
    local scripts=("setup.sh" "setup-secrets.sh" "edit-secrets.sh" "health.sh" "update.sh" "backup.sh" "restore.sh" "startup.sh" "maintenance.sh" "create-breakglass-admin.sh")
    for script in "${scripts[@]}"; do
        if [[ -f "$script" ]]; then
            chmod +x "$script"
            chown "$real_user:$real_group" "$script" 2>/dev/null || true
        fi
    done

    if [[ -d "lib" ]]; then
        find "lib" -name "*.sh" -exec chown "$real_user:$real_group" {} \; 2>/dev/null || true
        find "lib" -name "*.sh" -exec chmod 644 {} \; 2>/dev/null || true
    fi
    return 0
}

setup_firewall() {
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

    if ufw status | grep -q "Status: active" && \
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

    ufw status | grep -q "Status: active" || ufw --force enable
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

    # FIX [BUG-10]: printf throughout; no echo -e.
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
        printf 'SOPS Age Public Key:  %s%s%s\n' "${COLOR_GREEN}" "${age_pub_key}" "${COLOR_RESET}"
        printf 'SOPS Age Private Key: %sCat secrets/keys/age-key.txt to view  (BACKUP THIS FILE!)%s\n' \
            "${COLOR_RED}" "${COLOR_RESET}"
    fi

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
        printf '  %s./edit-secrets.sh --rotate caddy_cloudflare_dns_token%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %s./edit-secrets.sh --rotate fail2ban_cloudflare_firewall_token%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %s./edit-secrets.sh --rotate smtp_password%s         (if using SMTP/email notifications)\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %s./edit-secrets.sh --rotate email_api_token%s       (if using API-based email, e.g. MAILERSEND_API_TOKEN)\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %s./edit-secrets.sh --rotate push_installation_id%s  (optional — mobile push)\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %s./edit-secrets.sh --rotate push_installation_key%s (optional — mobile push)\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"

        printf '\n%s--- NEXT STEPS ---%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
        printf '1. Edit .env:           %snano .env%s\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '   ► Set: CLOUDFLARE_ZONE_ID, SMTP_HOST, SMTP_PORT, SMTP_USERNAME\n'
        printf '   ► Verify: DOMAIN and ADMIN_EMAIL are correct\n'
        printf '2. Set external tokens: %s(use ./edit-secrets.sh --rotate commands above)%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '3. Start services:      %smake up%s\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '4. Setup automation:    %ssudo ./systemd-setup.sh --install%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '5. Export recovery kit: %s./edit-secrets.sh --export-recovery-kit%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '   %s(Run AFTER step 2 so all secrets are included in the kit)%s\n' \
            "${COLOR_RED}" "${COLOR_RESET}"
    else
        printf '\n%s--- EXTERNAL CONFIGURATION CHECKLIST ---%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
        printf '1. [ ] Domain Name:   %s%s%s\n' "${COLOR_GREEN}" "${DOMAIN:-Not Set}" "${COLOR_RESET}"
        printf '2. [ ] Admin Email:   %s%s%s\n' "${COLOR_GREEN}" "${ADMIN_EMAIL:-Not Set}" "${COLOR_RESET}"

        printf '\n%s--- NEXT STEPS ---%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
        printf '1. Edit .env:           %snano .env%s\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '   ► Set: CLOUDFLARE_ZONE_ID, SMTP_HOST, SMTP_PORT, SMTP_USERNAME\n'
        printf '   ► Verify: DOMAIN and ADMIN_EMAIL are correct\n'
        printf '2. Configure secrets:   %s./setup-secrets.sh%s\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '   ► You will be prompted for all credentials\n'
        printf '3. Start services:      %smake up%s\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '4. Setup automation:    %ssudo ./systemd-setup.sh --install%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '5. Export recovery kit: %s./edit-secrets.sh --export-recovery-kit%s\n' \
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

main() {
    log_header "VaultWarden-OCI Setup - Security Hardened Edition"
    if ! is_root; then log_error "Must run as root."; exit 1; fi
    
    local SETUP_LOCK_FILE="/var/lock/vaultwarden-setup.lock"
    local SETUP_LOCK_FD=202
    exec 202>"$SETUP_LOCK_FILE"
    if ! flock -n $SETUP_LOCK_FD; then
        log_error "Another setup instance is already running (could not acquire lock)."
        log_error "Wait for it to complete, then retry."
        log_error "If the lock is stale, remove: ${SETUP_LOCK_FILE}"
        exit 1
    fi

    if [[ -n "${SOPS_VERSION:-}" ]]; then
        log_info "SOPS version pinned: ${SOPS_VERSION}"
    else
        log_info "SOPS version: will resolve latest from GitHub at install time"
    fi

    local setup_phases=(
        "check_disk_space:Disk Space Preflight:true"
        "create_swapfile:Swap Configuration:false"
        "install_dependencies:Dependency Installation:true"
        "verify_dependencies:Dependency Verification:true"
        "setup_user_permissions:User Permissions:false"
        "create_env_file:Environment Configuration:true"
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

    if [[ "$AUTO_MODE" == "true" ]]; then
        log_info "=== Auto Mode: Configuring secrets ==="
        chmod +x "$PROJECT_ROOT/setup-secrets.sh" 2>/dev/null || true
        local secrets_args=(--auto --skip-optional --quiet-summary)
        [[ "$FORCE" == "true" ]] && secrets_args+=(--force)
        if ! ./setup-secrets.sh "${secrets_args[@]}"; then
            log_warn "Secrets auto-configuration encountered issues — run ./setup-secrets.sh after editing .env"
        fi
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
