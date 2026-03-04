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
#   - Adds Docker's official GPG key and PROGRAMMATICALLY verifies the
#     fingerprint before trusting it (FIX-S03).
#   - Pins the apt source to 'noble' (24.04 LTS), which is the correct
#     repository for Ubuntu 24.10 — Docker does not publish an 'oracular' repo,
#     but noble packages are ABI-compatible and work correctly on 24.10.
#   - Installs docker-ce, docker-ce-cli, containerd.io, and the Compose plugin
#     as explicit, auditable apt packages.
install_docker_apt() {
    log_info "Installing Docker via official apt repository (noble codename)..."

    install -m 0755 -d /etc/apt/keyrings

    # FIX-S03: Download Docker's GPG key to a temp file and verify its
    # fingerprint programmatically before importing it into the apt keyring.
    # A fingerprint that exists only in a comment is not a security control.
    # Official fingerprint source: https://docs.docker.com/engine/install/ubuntu/
    local docker_gpg_tmp="$TMP_WORKDIR/docker.gpg.asc"
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$docker_gpg_tmp" || {
        log_error "Failed to download Docker GPG key"
        return 1
    }

    local expected_fpr="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
    local actual_fpr
    actual_fpr=$(gpg --with-colons --import-options show-only \
        --import "$docker_gpg_tmp" 2>/dev/null \
        | awk -F: '/^fpr/{print $10}' | head -1)

    if [[ -z "$actual_fpr" ]]; then
        log_error "Could not extract fingerprint from Docker GPG key — gpg parsing failed."
        log_error "Verify manually: gpg --with-colons --import-options show-only --import ${docker_gpg_tmp}"
        return 1
    fi

    if [[ "$actual_fpr" != "$expected_fpr" ]]; then
        log_error "Docker GPG fingerprint MISMATCH — refusing to add repository."
        log_error "  Expected: $expected_fpr"
        log_error "  Actual:   $actual_fpr"
        log_error "This may indicate a supply chain attack or DNS/MITM compromise."
        log_error "Verify at: https://docs.docker.com/engine/install/ubuntu/"
        return 1
    fi

    log_success "Docker GPG key fingerprint verified: $actual_fpr"
    gpg --dearmor < "$docker_gpg_tmp" > /etc/apt/keyrings/docker.gpg || return 1
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

# FIX [C-05]: Preflight disk-space check before any phase runs.
# Requires at least MIN_FREE_KB kilobytes free on the filesystem containing
# PROJECT_ROOT. Failing early avoids mid-run partial state (half-written .env,
# incomplete secrets structure, etc.).
check_disk_space() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would check disk space"; return 0; fi

    local min_free_kb=$((2 * 1024 * 1024))   # 2 GiB in KiB
    local available_kb
    available_kb=$(df -k "$PROJECT_ROOT" | awk 'NR==2 {print $4}')

    if (( available_kb < min_free_kb )); then
        log_error "Insufficient disk space. Required: 2 GiB, Available: $(( available_kb / 1024 )) MiB on $PROJECT_ROOT"
        return 1
    fi
    log_info "Disk space OK: $(( available_kb / 1024 )) MiB available"
    return 0
}

# FIX [C-06]: Create a 1 GiB swapfile when no swap is currently active.
# OCI A1 Flex instances ship with zero swap; under memory pressure Docker will
# OOM-kill containers. A swapfile provides breathing room without a persistent
# volume resize. vm.swappiness=10 keeps swap as a last resort.
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

    # Persist across reboots
    if ! grep -q "^${swapfile}" /etc/fstab 2>/dev/null; then
        echo "${swapfile} none swap sw 0 0" >> /etc/fstab
    fi

    # Keep swap as a last resort (default 60 is too aggressive for server use)
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

    # FIX-S06: Ensure the Ubuntu 'universe' repository is enabled before
    # attempting to install python3-argon2, which lives in universe and is
    # absent from Ubuntu 24.04 minimal's default sources. Without this,
    # apt-get fails with 'E: Unable to locate package python3-argon2' and
    # the entire setup phase aborts.
    # FIX [NEW-S01]: Check both legacy .list and DEB822 .sources formats
    if ! grep -qE '^deb[[:space:]].*universe' \
            /etc/apt/sources.list \
            /etc/apt/sources.list.d/*.list 2>/dev/null && \
       ! grep -qE '^Components:.*\buniverse\b' \
            /etc/apt/sources.list.d/*.sources 2>/dev/null; then
        log_info "Enabling Ubuntu 'universe' repository (required for python3-argon2)..."
        if command -v add-apt-repository >/dev/null 2>&1; then
            add-apt-repository -y universe 2>/dev/null || {
                log_warn "add-apt-repository failed — adding universe source manually"
                # FIX [HIGH-NEW-02]: Correct URL and ARM64 hostname
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
            # FIX [HIGH-NEW-02]: Same correction for no add-apt-repository path
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

        # FIX [C-08]: Validate any caller-supplied SOPS_VERSION against the
        # semver pattern before using it to construct a download URL. This
        # prevents path traversal or shell injection via an env override such as
        #   SOPS_VERSION="../../etc/passwd" sudo ./setup.sh ...
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

        # FIX-S01: Download the SOPS binary and the official checksums file,
        # then verify the SHA-256 hash before installing. The previous code
        # piped directly to /usr/local/bin/sops with no integrity check —
        # a MITM or compromised CDN could serve a backdoored binary that gets
        # installed as root and used to decrypt all secrets.
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

    # FIX [New Issue #1]: Only skip re-write when DOMAIN, ADMIN_EMAIL, *and*
    # the USE_LATEST state all match the existing .env. Previously the early
    # return fired on domain+email match alone, so --use-latest on a re-run
    # was silently ignored and container versions were never updated.
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
            # Non-latest mode: no version field should be 'latest'
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

    # FIX [BUG-06]: Remove redundant sudo — setup.sh requires root (is_root
    # guard in main()), so sudo inside a root process is a no-op at best and
    # misleading at worst. Direct calls are clearer and avoid a sudo fork.
    if ! mkdir -p "${project_state_dir}"/{data,logs/{vaultwarden,caddy,fail2ban,postfix},caddy/{data,config},fail2ban}; then
        return 1
    fi

    chown -R "${puid}:${pgid}" "$project_state_dir" || return 1

    # FIX-S02: Replace chmod -R 755 with restrictive permissions.
    # 755 sets world-execute on every subdirectory under /var/lib/vaultwarden,
    # making the entire path traversable by any local user — including any
    # future service account, Docker socket escape, or concurrent SSH session.
    # 750 (directories) and 640 (files) restrict access to owner + group only.
    find "${project_state_dir}" -type d -exec chmod 750 {} \; 2>/dev/null || return 1
    find "${project_state_dir}" -type f -exec chmod 640 {} \; 2>/dev/null || true

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

    if [[ -f "$age_key_file" ]]; then
        if [[ "$FORCE" != "true" ]]; then
            # Normal non-force path: skip if existing key is valid.
            if check_age_key "$age_key_file" 2>/dev/null; then
                return 0
            # FIX [LOW-NEW-02]: Warn operator about corrupt key before regeneration
            else
                log_warn "Existing Age key file is present but INVALID/CORRUPT."
                log_warn "It will be replaced. If any usable encrypted data was created"
                log_warn "with a previous key version, it cannot be recovered after this."
                log_warn "If in doubt, abort (Ctrl-C) and inspect: $age_key_file"
                # Proceed to key regeneration - no confirmation required since key unusable
            fi
        else
            # FIX-S07: --force on an existing, valid Age key permanently
            # invalidates all existing encrypted secrets — secrets.yaml,
            # any exported recovery kits, and all backup passphrases encrypted
            # to the old key become unrecoverable without a prior recovery kit.
            #
            # In --auto mode: hard fail. Automated scripts must not silently
            # rotate the master encryption key.
            # In interactive mode: require the operator to type 'ROTATE KEY'
            # to confirm they understand the consequences.
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

    # FIX [C-07]: Always re-derive the public key from the key file so that a
    # regenerated key (e.g. after --force) is reflected in .sops.yaml.
    # The previous guard returned early when .sops.yaml already existed and
    # contained 'age:', leaving a stale public key embedded in the config.
    # We still skip if the key file hasn't changed (idempotent non-force run),
    # but we verify by re-reading the live public key rather than trusting a
    # cached string.
    local age_public_key; age_public_key=$(get_age_public_key "$age_key_file") || return 1

    if [[ -f "$sops_config" ]] && [[ "$FORCE" != "true" ]]; then
        # Check that the embedded key matches the current key file exactly.
        if grep -qF "$age_public_key" "$sops_config"; then
            # Validate the config is actually usable before trusting it.
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

# Phase 2-B: setup_secrets_interactively() removed.
# Previously phase 10; replaced by the post-phase block in main().
# Rationale:
#   - In the old model, secrets ran as phase 10 of 14, before the user ever
#     saw the final summary or had a chance to review .env. This meant
#     CLOUDFLARE_ZONE_ID was not set yet, silently disabling CF token
#     validation in lib/secrets.sh:validate_cloudflare_token().
#   - The inverted-pipe logic (sops -d | grep) could silently set
#     secrets_configured=true when sops failed, causing --auto to return 0
#     without ever calling setup-secrets.sh.
#   - See main() post-phase block below for the replacement logic.

create_docker_compose() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would create docker-compose.yml"; return 0; fi

    local compose_file="$PROJECT_ROOT/docker-compose.yml"
    local compose_template="$PROJECT_ROOT/docker-compose.yml.example"

    if [[ -f "$compose_file" ]] && [[ "$FORCE" != "true" ]]; then
        docker compose -f "$compose_file" config >/dev/null 2>&1 && return 0
    fi

    cp "$compose_template" "$compose_file" || return 1
    chown "$(get_real_user):$(id -g -n "$(get_real_user)")" "$compose_file" || return 1
    # FIX [SEC-03]: 644 exposes port/volume/image data to all local users.
    # 640 restricts read access to the owner's group only.
    chmod 640 "$compose_file" || return 1
    return 0
}

set_script_permissions() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would set script permissions"; return 0; fi

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n "$real_user")

    # FIX [BUG-09]: Removed three deleted scripts (db-maint.sh, update-dns.sh,
    # test-email-simple.sh) that no longer exist in the repository. The loop
    # uses [[ -f ]] guards so missing entries are silently skipped, but keeping
    # deleted names here is misleading and would cause confusion during audits.
    local scripts=("setup.sh" "setup-secrets.sh" "edit-secrets.sh" "health.sh" "update.sh" "backup.sh" "restore.sh" "startup.sh" "maintenance.sh" "cron-setup.sh" "create-breakglass-admin.sh")
    for script in "${scripts[@]}"; do
        if [[ -f "$script" ]]; then
            chmod +x "$script"
            chown "$real_user:$real_group" "$script" 2>/dev/null || true
        fi
    done

    # FIX [New Issue #2]: Do NOT grant +x to lib/*.sh. Library files are
    # intended to be sourced (. lib/foo.sh), never executed directly. Making
    # them executable invites accidental direct invocation which causes partial
    # execution and confusing errors (missing init_common_lib context, etc.).
    if [[ -d "lib" ]]; then
        find "lib" -name "*.sh" -exec chown "$real_user:$real_group" {} \; 2>/dev/null || true
        find "lib" -name "*.sh" -exec chmod 644 {} \; 2>/dev/null || true
    fi
    return 0
}

setup_firewall() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would configure firewall"; return 0; fi

    # FIX-S05: Use 'sshd -T' to resolve the effective SSH configuration,
    # including all Include directives and sshd_config.d/ drop-in files.
    # Ubuntu 24.04 minimal uses sshd_config.d/50-cloud-init.conf for
    # non-standard ports; awk on sshd_config alone silently misses these.
    # If the real SSH port is not opened in UFW, the next reboot or
    # 'ufw reload' locks the operator out of the server.
    local ssh_port
    ssh_port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    if [[ -z "$ssh_port" ]]; then
        ssh_port=$(awk '/^Port[[:space:]]/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)
    fi
    ssh_port=${ssh_port:-22}
    log_info "Detected SSH port: ${ssh_port}"

    # Idempotency: only skip if ALL three required rules are already present and active.
    # Checking SSH port here is critical — returning early without it would lock the admin out.
    if ufw status | grep -q "Status: active" && \
       ufw status | grep -q "80/tcp" && \
       ufw status | grep -q "443/tcp" && \
       ufw status | grep -q "${ssh_port}/tcp"; then
        log_success "Firewall already configured and active"
        return 0
    fi

    ufw allow "${ssh_port}/tcp"
    ufw allow 80/tcp
    ufw allow 443/tcp

    ufw status | grep -q "Status: active" || echo "y" | ufw enable
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

# Phase 1-C: Mode-aware post-install summary.
#
# auto mode     — lists what was auto-generated, the exact
#                 ./edit-secrets.sh --rotate commands for every CHANGE_ME field,
#                 and an ordered next-steps checklist.
# interactive   — clean checklist directing the user to edit .env FIRST (so
#                 CLOUDFLARE_ZONE_ID is set before secrets run), then run
#                 ./setup-secrets.sh.
#
# This is the ONLY completion screen shown. setup-secrets.sh's own banner is
# suppressed via --quiet-summary when called from the post-phase block below.
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
        age_pub_key=$(grep "public key" "secrets/keys/age-key.txt" | cut -d: -f2 | tr -d ' ' || echo "MISSING")
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
        printf '  %s./edit-secrets.sh --rotate smtp_password%s         (if using email notifications)\n' \
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
        printf '4. Setup automation:    %ssudo ./cron-setup.sh --install%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '5. Export recovery kit: %s./edit-secrets.sh --export-recovery-kit%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '   %s(Run AFTER step 2 so all secrets are included in the kit)%s\n' \
            "${COLOR_RED}" "${COLOR_RESET}"
    else
        # Interactive mode — secrets not yet configured.
        # Direct the user to edit .env BEFORE running setup-secrets.sh so that
        # CLOUDFLARE_ZONE_ID is present when validate_cloudflare_token() runs.
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
        printf '4. Setup automation:    %ssudo ./cron-setup.sh --install%s\n' \
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

    # FIX-S04: Prevent concurrent setup.sh invocations.
    # A race between two simultaneous runs can permanently corrupt the
    # Age key + SOPS config pair: if both runs pass the [[ -f age_key_file ]]
    # guard and both call generate_age_key(), the second run can overwrite
    # the key file while the first has already used the original public key
    # to encrypt secrets.yaml — leaving them permanently mismatched and
    # unrecoverable without the recovery kit.
    local SETUP_LOCK_FILE="/var/lock/vaultwarden-setup.lock"
    local SETUP_LOCK_FD=202
    eval "exec ${SETUP_LOCK_FD}>\"$SETUP_LOCK_FILE\""
    if ! flock -n $SETUP_LOCK_FD; then
        log_error "Another setup instance is already running (could not acquire lock)."
        log_error "Wait for it to complete, then retry."
        log_error "If the lock is stale, remove: ${SETUP_LOCK_FILE}"
        exit 1
    fi

    # Log version pin status for transparency
    if [[ -n "${SOPS_VERSION:-}" ]]; then
        log_info "SOPS version pinned: ${SOPS_VERSION}"
    else
        log_info "SOPS version: will resolve latest from GitHub at install time"
    fi

    # Phase 2-A: setup_secrets_interactively removed from this array.
    # Secrets are handled in the post-phase block below, after all infra is
    # ready and the user has had a chance to set CLOUDFLARE_ZONE_ID in .env.
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

    # --- Phase 2-A: Post-phase secrets configuration ---
    #
    # AUTO MODE: Run setup-secrets.sh non-interactively now that all infra
    # phases are complete. Calling it here (rather than as a phase) ensures:
    #   1. .env exists and has been written with DOMAIN/EMAIL, so
    #      validate_cloudflare_token() in lib/secrets.sh can read
    #      CLOUDFLARE_ZONE_ID if the user pre-populated it.
    #   2. The Age key and SOPS config are already in place.
    #   3. --quiet-summary suppresses setup-secrets.sh's own completion
    #      banner; show_post_install_summary() below is the single
    #      consolidated output screen.
    #   4. --auto keeps all external credentials (CF tokens, SMTP password,
    #      push keys) as CHANGE_ME placeholders — truly non-interactive.
    #      The summary screen lists exact ./edit-secrets.sh --rotate commands
    #      to fill them in before running make up.
    #
    # INTERACTIVE MODE: Do NOT call setup-secrets.sh here. The summary screen
    # directs the user to edit .env first (step 1), then run ./setup-secrets.sh
    # themselves (step 2). This ordering lets CF token validation work correctly.
    if [[ "$AUTO_MODE" == "true" ]]; then
        log_info "=== Auto Mode: Configuring secrets ==="
        chmod +x "$PROJECT_ROOT/setup-secrets.sh" 2>/dev/null || true
        local secrets_args=(--auto --skip-optional --quiet-summary)
        [[ "$FORCE" == "true" ]] && secrets_args+=(--force)
        if ! ./setup-secrets.sh "${secrets_args[@]}"; then
            log_warn "Secrets auto-configuration encountered issues — run ./setup-secrets.sh after editing .env"
        fi
    fi

    # Single consolidated summary screen (both modes).
    if [[ "$AUTO_MODE" != "true" ]]; then
        read -r -p "Press Enter to view CRITICAL recovery information..."
        show_post_install_summary "interactive"
    else
        show_post_install_summary "auto"
    fi
    exit 0
}

main "$@"
