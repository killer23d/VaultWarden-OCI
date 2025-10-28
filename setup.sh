#!/usr/bin/env bash
# setup.sh - VaultWarden-OCI-Simplified Setup Script

set -euo pipefail

# --- Project Root Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# --- Source Libraries ---
source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"

# --- Configuration Defaults ---
DOMAIN=""
ADMIN_EMAIL=""
AUTO_MODE=false
USE_LATEST=false
SKIP_DEPS=false
FORCE=false
DRY_RUN=false

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden-OCI-Simplified Setup Tool

USAGE:
    sudo ./setup.sh [OPTIONS]

REQUIRED OPTIONS:
    --domain DOMAIN      Your VaultWarden domain (e.g., vault.example.com)
    --email EMAIL        Administrator email address

SETUP OPTIONS:
    --auto               Automated setup with minimal prompts
    --use-latest         Use latest container versions (default: pinned versions)
    --skip-deps          Skip dependency installation (install manually first)
    --force              Overwrite existing configuration files
    --dry-run            Show what would be done without executing
    --help               Show this help information

EXAMPLES:
    # Interactive production setup (recommended)
    sudo ./setup.sh --domain vault.example.com --email admin@example.com

    # Automated production setup with pinned versions
    sudo ./setup.sh --domain vault.example.com --email admin@example.com --auto

    # Development setup with latest versions
    sudo ./setup.sh --domain vault-dev.example.com --email dev@example.com --auto --use-latest
EOF
}

# --- Argument Parsing ---
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

# --- Validation ---
if [[ -z "$DOMAIN" ]]; then
    log_error "Domain is required. Use --domain your-domain.com"
    show_help
    exit 1
fi
# Basic domain validation
if ! validate_domain "$DOMAIN"; then
    log_error "Invalid domain format: $DOMAIN"
    log_info "Should be like 'vault.example.com'"
    exit 1
fi


if [[ -z "$ADMIN_EMAIL" ]]; then
    log_error "Admin email is required. Use --email admin@example.com"
    show_help
    exit 1
fi
# Basic email validation
if ! validate_email "$ADMIN_EMAIL"; then
     log_error "Invalid email format: $ADMIN_EMAIL"
     exit 1
fi

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Enhanced: Check if user needs docker group activation
check_docker_group_activation_needed() {
    local real_user
    real_user=$(get_real_user)

    if [[ -z "$real_user" ]] || [[ "$real_user" == "root" ]]; then
        return 0  # No activation needed for root
    fi

    # Check if user is in docker group but group membership isn't active in current session
    if id "$real_user" | grep -q '\bdocker\b'; then
        log_debug "User $real_user is in docker group."

        # Test if docker access works (as this user)
        # Use timeout to prevent hanging if docker daemon is unresponsive
        if command timeout 5s sudo -u "$real_user" docker info >/dev/null 2>&1; then
            log_debug "Docker group access is active for $real_user."
            return 0
        else
            log_debug "Docker group membership exists but is not active in current session for $real_user."
            return 1 # Activation needed
        fi
    else
        log_debug "User $real_user is not in docker group yet."
        return 1 # Activation will be needed after adding
    fi
}

# Enhanced docker group setup with activation guidance
setup_docker_group_access() {
    local real_user
    real_user=$(get_real_user)

    if [[ -z "$real_user" ]] || [[ "$real_user" == "root" ]]; then
        log_info "Running as root, no docker group setup needed for root user."
        return 0
    fi

    log_info "Setting up Docker group access for user: $real_user"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would add $real_user to docker group if not already a member."
        return 0
    fi

    # Add user to docker group if not already a member
    if ! id "$real_user" | grep -q '\bdocker\b'; then
        log_info "Adding $real_user to docker group..."
        if usermod -aG docker "$real_user"; then
            log_success "Added $real_user to docker group."
            # Group membership won't be active until next login or `newgrp`
        else
            log_error "Failed to add $real_user to docker group. Check system logs."
            return 1
        fi
    else
        log_info "$real_user is already in docker group."
    fi

    # Test if group membership is active *now*
    if command timeout 5s sudo -u "$real_user" docker info >/dev/null 2>&1; then
        log_success "Docker group access is currently active for $real_user."
        return 0
    else
        log_warn "Docker group membership for $real_user may require activation."
        log_info "(This is normal if the user was just added to the group)."
        # Return 1 indicates activation might be needed later
        return 1
    fi
}

# --- Dependency Installation Functions ---

install_docker() {
    log_info "Installing Docker CE and Docker Compose Plugin..."

    log_debug "Attempting to remove old Docker packages..."
    apt-get remove -y docker docker-engine docker.io containerd runc docker-compose docker-compose-v2 2>/dev/null || true

    log_debug "Updating package index before prerequisite installation..."
    apt-get update -qq

    log_info "Installing Docker prerequisites..."
    if ! apt-get install -y ca-certificates curl gnupg lsb-release software-properties-common; then
        log_error "Failed to install Docker prerequisites."
        return 1
    fi

    log_info "Adding Docker's official GPG key..."
    install -m 0755 -d /etc/apt/keyrings
    if ! curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; then
         log_error "Failed to download or dearmor Docker GPG key."
         return 1
    fi
    chmod a+r /etc/apt/keyrings/docker.gpg

    log_info "Adding Docker repository..."
    local os_codename
    os_codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    if [[ -z "$os_codename" ]]; then
        log_error "Could not determine OS codename for Docker repository setup."
        return 1
    fi
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${os_codename} stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    log_info "Updating package index with Docker repository..."
    apt-get update -qq

    log_info "Installing Docker Engine and Compose Plugin..."
    if ! apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
         log_error "Failed to install Docker packages."
         log_info "Check repository configuration and network access."
         return 1
    fi

    log_info "Starting and enabling Docker service..."
    if ! systemctl start docker; then log_warn "Failed to start Docker service immediately."; fi
    if ! systemctl enable docker; then log_warn "Failed to enable Docker service."; fi
    sleep 2 # Give service a moment to start

    # Verify Docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker service installed but failed to start or is not accessible."
        log_info "Check Docker status: systemctl status docker"
        log_info "Check Docker logs: journalctl -u docker"
        return 1
    fi

    log_success "Docker CE and Docker Compose Plugin installed successfully."

    # Set up docker group access for the non-root user
    setup_docker_group_access
    # Return code from setup_docker_group_access indicates if activation is needed
    return $?
}

install_sops() {
    log_info "Installing SOPS (Secrets OPerationS)..."

    local sops_version="3.8.1" # Consider fetching latest version dynamically if needed
    local arch
    arch=$(dpkg --print-architecture)
    local sops_binary_url sops_binary_name

    case "$arch" in
        "amd64")
            sops_binary_name="sops-v${sops_version}.linux.amd64"
            ;;
        "arm64")
            sops_binary_name="sops-v${sops_version}.linux.arm64"
            ;;
        *)
            log_error "Unsupported architecture for SOPS binary download: $arch"
            log_info "Please install SOPS manually from: https://github.com/getsops/sops/releases"
            return 1
            ;;
    esac
    sops_binary_url="https://github.com/getsops/sops/releases/download/v${sops_version}/${sops_binary_name}"

    log_info "Downloading SOPS ($sops_binary_name) for $arch architecture..."
    local temp_sops_file="/tmp/${sops_binary_name}"
    if ! curl -fsSL "$sops_binary_url" -o "$temp_sops_file"; then
        log_error "Failed to download SOPS binary from $sops_binary_url"
        rm -f "$temp_sops_file"
        return 1
    fi

    log_info "Installing SOPS to /usr/local/bin/sops..."
    if ! install -m 0755 "$temp_sops_file" /usr/local/bin/sops; then
        log_error "Failed to install SOPS binary."
        rm -f "$temp_sops_file"
        return 1
    fi
    rm -f "$temp_sops_file"

    # Verify installation
    if sops --version >/dev/null 2>&1; then
        log_success "SOPS $(sops --version | head -n1) installed successfully."
    else
        log_error "SOPS installation verification failed. Check /usr/local/bin/sops."
        return 1
    fi
    return 0
}

install_dependencies() {
    if [[ "$SKIP_DEPS" == "true" ]]; then
        log_info "Skipping dependency installation (--skip-deps specified)."
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install system dependencies: age, make, nano, rclone, sqlite3, argon2, jq, mailutils, ufw, curl, wget, unzip, git, gpg, coreutils, Docker, SOPS."
        return 0
    fi

    log_info "Installing system dependencies..."

    log_info "Updating package lists..."
    # Use -qq for quieter update unless debugging
    local apt_update_opts=("-qq")
    [[ "${DEBUG:-false}" == "true" ]] && apt_update_opts=()
    if ! apt-get update "${apt_update_opts[@]}"; then
        log_error "Failed to update package lists. Check network and repository configuration."
        return 1
    fi

    log_info "Installing basic dependencies..."
    local basic_packages=(
        "age"           # Encryption tool
        "make"          # Build utility (for Makefile shortcuts)
        "nano"          # Text editor (Default for SOPS)
        "rclone"        # Cloud sync tool
        "sqlite3"       # Database tool
        "argon2"        # Password hashing tool
        "jq"            # JSON processor (CRITICAL for script fixes)
        "mailutils"     # Email utilities
        "ufw"           # Firewall
        "curl"          # HTTP client
        "wget"          # Download tool
        "unzip"         # Archive tool
        "git"           # Version control
        "gpg"           # GPG for docker key
        "coreutils"     # Provides numfmt used in backup_utils.sh, stat, etc.
    )

    # Use DEBIAN_FRONTEND=noninteractive to avoid prompts during install
    export DEBIAN_FRONTEND=noninteractive
    if apt-get install -y "${basic_packages[@]}"; then
        log_success "Basic dependencies installed successfully."
    else
        log_error "Failed to install some basic dependencies."
        log_info "You may need to manually install: ${basic_packages[*]}"
        return 1
    fi

    # Install Docker (requires special handling)
    local docker_activation_needed=false
    if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
        # install_docker returns 1 if activation might be needed
        install_docker || { [[ $? -eq 1 ]] && docker_activation_needed=true || { log_error "Docker installation failed critically."; return 1; } }
    else
        log_info "Docker already installed, verifying version..."
        docker --version
        docker compose version
        # Check docker group access even if already installed
        setup_docker_group_access || { [[ $? -eq 1 ]] && docker_activation_needed=true; }
    fi

    # Install SOPS (requires manual installation)
    if ! command -v sops >/dev/null 2>&1; then
        install_sops || {
            log_error "SOPS installation failed."
            return 1
        }
    else
        log_info "SOPS already installed: $(sops --version | head -n1)"
    fi

    log_success "All dependencies installed successfully."
    # Pass back whether docker activation is needed
    if [[ "$docker_activation_needed" == "true" ]]; then return 1; else return 0; fi
}

# --- Verification Functions ---
verify_dependencies() {
    log_info "Verifying installed dependencies..."

    local missing_deps=()
    local required_commands=(
        "docker"
        "age"
        "sops"
        "make"
        "nano" # Or check $EDITOR if set? Nano is default.
        "sqlite3"
        "curl"
        "jq"
        "numfmt"
        "rclone"
        "ufw"
        "mail" # Provided by mailutils
        "argon2"
    )

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done

    # Special check for Docker Compose Plugin
    if ! docker compose version >/dev/null 2>&1; then
        missing_deps+=("docker-compose-plugin")
    fi

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_info "Run the script without --skip-deps or install them manually."
        return 1
    fi

    log_success "All required dependencies are available."

    # Show versions for verification
    log_info "Dependency versions:"
    echo "  Docker: $(docker --version)"
    echo "  Docker Compose: $(docker compose version --short)"
    echo "  Age: $(age --version | head -1)"
    echo "  SOPS: $(sops --version | head -n1)"
    echo "  Make: $(make --version | head -1)"
    echo "  Nano: $(nano --version | head -1)"
    echo "  SQLite: $(sqlite3 --version | cut -d' ' -f1)"
    echo "  jq: $(jq --version)"
    return 0
}

# --- Configuration Functions ---
setup_user_permissions() {
    log_info "Setting up project directory ownership..."

    local real_user real_group owner
    real_user=$(get_real_user)
    real_group=$(id -g -n "$real_user" 2>/dev/null || echo "$real_user")
    owner="$real_user:$real_group"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would set ownership of $PROJECT_ROOT to $owner"
        return 0
    fi

    # Set ownership of project directory
    if chown -R "$owner" "$PROJECT_ROOT"; then
        log_success "Project directory ownership set to $owner."
    else
        log_warn "Failed to set ownership of project directory $PROJECT_ROOT."
        log_info "Ensure user $real_user exists and you have permissions."
        return 1
    fi
    return 0
}

# <<<--- THIS IS THE UPDATED FUNCTION --- >>>
setup_firewall() {
    log_info "Configuring UFW firewall (static setup)..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would configure firewall rules"
        return 0
    fi

    if ! has_command ufw; then
        log_warn "UFW command not found, skipping firewall setup."
        return 0
    fi

    # Reset firewall to default state
    log_info "Resetting UFW firewall..."
    ufw --force reset >/dev/null 2>&1

    # Set default policies
    log_info "Setting default firewall policies (deny incoming, allow outgoing)..."
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1

    # Allow SSH
    local ssh_port
    # Try getting from loaded env, fallback to checking config, fallback to 22
    ssh_port=$(get_config_value "SSH_PORT" "")
    if [[ -z "$ssh_port" ]]; then
        # Grep sshd_config, ignore comments, get last 'Port' value
        ssh_port=$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -1)
    fi
    ssh_port="${ssh_port:-22}" # Default to 22 if not found
    log_info "Allowing SSH traffic on port $ssh_port/tcp..."
    ufw allow "$ssh_port/tcp" comment "SSH" >/dev/null 2>&1

    # Allow HTTP and HTTPS from anywhere (Caddy will handle Cloudflare filtering)
    log_info "Allowing HTTP (port 80/tcp) and HTTPS (port 443/tcp) from ANY source..."
    log_info "(Caddy's 'forwarded' directive will handle Cloudflare IP filtering)"
    ufw allow 80/tcp comment "HTTP - Caddy handles CF filtering" >/dev/null 2>&1
    ufw allow 443/tcp comment "HTTPS - Caddy handles CF filtering" >/dev/null 2>&1

    # Enable firewall
    log_info "Enabling UFW firewall..."
    # Use 'yes' to automatically confirm enabling UFW
    if yes | ufw enable; then
        log_success "UFW firewall configured and enabled (static rules for web ports)."
        log_info "Current status (brief):"
        ufw status | head -n 5 # Show brief status
    else
        log_error "Failed to enable UFW firewall!"
        return 1
    fi
    return 0
}
# <<<--- END OF UPDATED FUNCTION --- >>>

generate_age_keys() {
    log_info "Generating Age encryption keys..."

    local keys_dir="$PROJECT_ROOT/secrets/keys"
    local private_key="$keys_dir/age-key.txt"
    local public_key="$keys_dir/age-public-key.txt"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would generate Age keys in $keys_dir"
        return 0
    fi

    # Create secrets directory structure first
    # Ensure owner is correct BEFORE creating keys
    local real_user real_group owner
    real_user=$(get_real_user)
    real_group=$(id -g -n "$real_user" 2>/dev/null || echo "$real_user")
    owner="$real_user:$real_group"
    ensure_dir "$PROJECT_ROOT/secrets" 700 "$owner"
    ensure_dir "$keys_dir" 700 "$owner"

    # Check if keys already exist
    if [[ -f "$private_key" && -f "$public_key" ]] && [[ "$FORCE" != "true" ]]; then
        log_info "Age keys already exist, skipping generation."
        log_info "Use --force to regenerate keys (will invalidate existing secrets/backups)."
        # Ensure ownership is correct even if skipped
        chown "$owner" "$private_key" "$public_key" 2>/dev/null || true
        return 0
    fi

    # Generate Age key pair
    log_info "Generating new Age key pair..."
    if ! age-keygen -o "$private_key"; then
        log_error "Failed to generate Age private key."
        return 1
    fi

    # Set secure permissions
    chmod 600 "$private_key"

    # Extract public key
    if ! age-keygen -y "$private_key" > "$public_key"; then
        log_error "Failed to extract Age public key."
        rm -f "$private_key" # Clean up private key if public key fails
        return 1
    fi
    chmod 644 "$public_key"

    # Set ownership
    chown "$owner" "$private_key" "$public_key" || log_warn "Could not set ownership on Age keys."

    log_success "Age encryption keys generated successfully."
    log_warn "CRITICAL: Backup the private key ($private_key) securely and separately!"
    return 0
}

create_sops_config() {
    log_info "Creating SOPS configuration file (.sops.yaml)..."

    local sops_config_file="$PROJECT_ROOT/.sops.yaml"
    local public_key_file="$PROJECT_ROOT/secrets/keys/age-public-key.txt"
    local public_key=""

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create $sops_config_file using public key from $public_key_file"
        return 0
    fi

    if [[ ! -f "$public_key_file" ]]; then
        log_error "Age public key not found: $public_key_file. Cannot create SOPS config."
        log_info "Try running key generation again."
        return 1
    fi

    public_key=$(cat "$public_key_file") || {
        log_error "Failed to read Age public key from $public_key_file."
        return 1
    }

    if [[ -z "$public_key" ]]; then
        log_error "Age public key file $public_key_file appears to be empty."
        return 1
    fi

    # Check if config already exists
    if [[ -f "$sops_config_file" ]] && [[ "$FORCE" != "true" ]]; then
        log_info "SOPS configuration file (.sops.yaml) already exists, skipping creation."
        return 0
    fi

    # Create .sops.yaml content
    log_info "Writing SOPS configuration to $sops_config_file..."
    cat > "$sops_config_file" << EOF
# SOPS configuration for VaultWarden-OCI-Simplified
# Automatically generated by setup.sh
creation_rules:
  - path_regex: secrets/secrets\.yaml$
    age: $public_key
EOF

    # Set permissions and ownership
    chmod 644 "$sops_config_file"
    local real_user real_group owner
    real_user=$(get_real_user)
    real_group=$(id -g -n "$real_user" 2>/dev/null || echo "$real_user")
    owner="$real_user:$real_group"
    chown "$owner" "$sops_config_file" || log_warn "Could not set ownership on .sops.yaml."

    log_success "SOPS configuration created: $sops_config_file"
    return 0
}

create_env_file() {
    log_info "Creating environment configuration file (.env)..."

    local env_file="$PROJECT_ROOT/.env"
    local env_example="$PROJECT_ROOT/.env.example"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create/update .env file with domain: $DOMAIN, email: $ADMIN_EMAIL"
        log_info "[DRY RUN] Version pinning based on --use-latest: $USE_LATEST"
        return 0
    fi

    # Check if .env already exists
    if [[ -f "$env_file" ]] && [[ "$FORCE" != "true" ]]; then
        log_info ".env file already exists, skipping creation. Use --force to overwrite."
        # Ensure basic required vars are present even if skipping
        if ! grep -q "^DOMAIN=" "$env_file"; then sed -i -e '$a\' -e "DOMAIN=$DOMAIN" "$env_file"; fi
        if ! grep -q "^ADMIN_EMAIL=" "$env_file"; then sed -i -e '$a\' -e "ADMIN_EMAIL=$ADMIN_EMAIL" "$env_file"; fi
        if ! grep -q "^DDCLIENT_HOSTNAME=" "$env_file"; then sed -i -e '$a\' -e "DDCLIENT_HOSTNAME=$DOMAIN" "$env_file"; fi
        return 0
    fi

    # Copy from example if it exists
    if [[ -f "$env_example" ]]; then
        log_info "Copying from .env.example..."
        cp "$env_example" "$env_file"
        # Update required fields robustly
        sed -i "s|^#*DOMAIN=.*|DOMAIN=$DOMAIN|" "$env_file"
        sed -i "s|^#*ADMIN_EMAIL=.*|ADMIN_EMAIL=$ADMIN_EMAIL|" "$env_file"
        sed -i "s|^#*DDCLIENT_HOSTNAME=.*|DDCLIENT_HOSTNAME=$DOMAIN|" "$env_file"
    else
        # Create minimal .env file (fallback)
        log_warn "No .env.example found, creating minimal .env file."
        cat > "$env_file" << EOF
# VaultWarden-OCI-Simplified Configuration
# Generated by setup.sh on $(date)

# CORE CONFIGURATION (REQUIRED)
DOMAIN=$DOMAIN
ADMIN_EMAIL=$ADMIN_EMAIL
COMPOSE_PROJECT_NAME=vaultwarden
PROJECT_STATE_DIR=/var/lib/vaultwarden

# USER & PERMISSIONS (Set PUID/PGID below)
PUID=1000
PGID=1000

# HOST CONFIGURATION
SSH_PORT=22

# CLOUDFLARE & DYNAMIC DNS (REQUIRED)
CLOUDFLARE_ZONE_ID=CHANGE_ME_YOUR_ZONE_ID_HERE
DDCLIENT_HOSTNAME=$DOMAIN

# BACKUP CONFIGURATION
DB_BACKUP_RETENTION_DAYS=14
FULL_BACKUP_RETENTION_DAYS=30
EMERGENCY_BACKUP_RETENTION_DAYS=90
BACKUP_ENCRYPTION=age
BACKUP_VERIFICATION_MODE=quick_check
RCLONE_REMOTE_NAME=CHANGE_ME_RCLONE_REMOTE_NAME

# RESOURCE LIMITS (Adjust as needed)
VAULTWARDEN_MEMORY_LIMIT=1g
CADDY_MEMORY_LIMIT=128m
FAIL2BAN_MEMORY_LIMIT=64m
DDCLIENT_MEMORY_LIMIT=64m
VAULTWARDEN_CPU_LIMIT=1.0
CADDY_CPU_LIMIT=0.5
FAIL2BAN_CPU_LIMIT=0.2
DDCLIENT_CPU_LIMIT=0.1
EOF
    fi

    # Add/Update version pins based on --use-latest flag
    if [[ "$USE_LATEST" == "true" ]]; then
        log_info "Configuring for development mode (using 'latest' container versions)..."
        # Comment out any existing version pins
        sed -i -e "/^VAULTWARDEN_VERSION=/s/^/#/" \
               -e "/^CADDY_VERSION=/s/^/#/" \
               -e "/^FAIL2BAN_VERSION=/s/^/#/" \
               -e "/^DDCLIENT_VERSION=/s/^/#/" "$env_file"
    else
        log_info "Configuring for production mode (pinning default container versions)..."
        # Set specific versions (update these defaults as needed for new stable releases)
        local default_vw_version="1.31.0" # Example stable version
        local default_caddy_version="2.8.4" # Example stable version
        local default_f2b_version="1.1.0"  # Example stable version
        local default_ddc_version="3.11.2" # Example stable version

        # Use awk to robustly add or update lines, preserving comments if possible
        local temp_env
        temp_env=$(mktemp)
        setup_cleanup_trap "rm -f '$temp_env'"
        awk -v vw_ver="$default_vw_version" \
            -v caddy_ver="$default_caddy_version" \
            -v f2b_ver="$default_f2b_version" \
            -v ddc_ver="$default_ddc_version" '
            BEGIN {
                pins["VAULTWARDEN_VERSION"] = vw_ver
                pins["CADDY_VERSION"] = caddy_ver
                pins["FAIL2BAN_VERSION"] = f2b_ver
                pins["DDCLIENT_VERSION"] = ddc_ver
                FS="="
            }
            {
                key = $1
                # Remove leading/trailing whitespace and comments from key
                gsub(/^[[:space:]]*#?[[:space:]]*/, "", key)
                gsub(/[[:space:]]*$/, "", key)

                if (key in pins) {
                    # Print uncommented, updated line
                    print key "=" pins[key]
                    # Mark as found
                    delete pins[key]
                } else {
                    # Print original line
                    print
                }
            }
            END {
                # Add any pins that were not found in the file
                for (key in pins) {
                    print key "=" pins[key]
                }
            }
        ' "$env_file" > "$temp_env"
        mv "$temp_env" "$env_file"
    fi

    # Set correct PUID/PGID based on the real user
    local real_user real_uid real_gid
    real_user=$(get_real_user)
    real_uid=$(id -u "$real_user")
    real_gid=$(id -g "$real_user")
    log_info "Setting PUID=$real_uid and PGID=$real_gid for user '$real_user' in .env..."
    # Robustly update or add PUID/PGID lines
    sed -i "s|^#*PUID=.*|PUID=$real_uid|" "$env_file"
    if ! grep -q "^PUID=" "$env_file"; then echo "PUID=$real_uid" >> "$env_file"; fi
    sed -i "s|^#*PGID=.*|PGID=$real_gid|" "$env_file"
    if ! grep -q "^PGID=" "$env_file"; then echo "PGID=$real_gid" >> "$env_file"; fi

    # Set secure permissions
    chmod 640 "$env_file" # Slightly more secure than 644

    # Set ownership
    local real_group owner
    real_group=$(id -g -n "$real_user" 2>/dev/null || echo "$real_user")
    owner="$real_user:$real_group"
    chown "$owner" "$env_file" || log_warn "Could not set ownership on .env file."

    log_success "Environment configuration file created/updated: $env_file"
    log_warn "Please review $env_file and set CHANGE_ME values (like CLOUDFLARE_ZONE_ID)."
    return 0
}

setup_directories() {
    log_info "Creating project and state directories..."

    local real_user real_group owner
    real_user=$(get_real_user)
    real_group=$(id -g -n "$real_user" 2>/dev/null || echo "$real_user")
    owner="$real_user:$real_group"

    # Load state_dir from the .env file
    # Use default value if .env loading fails
    load_env_file "$PROJECT_ROOT/.env" || log_warn "Could not load .env for directory setup, using default state dir."
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would ensure project directories exist with owner $owner."
        log_info "[DRY RUN] Would ensure state directories exist under $state_dir with owner $owner."
        return 0
    fi

    # Create project directories (owned by the user running the script)
    local project_dirs=(
        "secrets/keys" # Ensure keys dir exists first with correct perms
        "backups/db"
        "backups/full"
        "backups/emergency"
        "logs"
        "lib" # Should already exist, but ensure permissions
        "caddy" # Ensure caddy config dir exists
        "fail2ban/jail.d" # Ensure fail2ban dirs exist
        "fail2ban/filter.d"
        "fail2ban/action.d"
        "ddclient" # Ensure ddclient config dir exists
    )

    # Set permissions first on parent dirs
    ensure_dir "$PROJECT_ROOT/secrets" 700 "$owner"
    ensure_dir "$PROJECT_ROOT/backups" 750 "$owner"
    ensure_dir "$PROJECT_ROOT/fail2ban" 750 "$owner"

    for dir in "${project_dirs[@]}"; do
        # Use more specific permissions based on need
        local mode="750" # Default restricted mode
        if [[ "$dir" == "secrets/keys" ]]; then mode="700"; fi
        if [[ "$dir" == "logs" ]]; then mode="755"; fi # Logs might need broader read access sometimes
        ensure_dir "$PROJECT_ROOT/$dir" "$mode" "$owner" || return 1
    done

    # Create state directories (owned by the PUID/PGID user defined in .env)
    # Get PUID/PGID from .env for state dir ownership
    local puid pgid state_owner
    puid=$(get_config_value "PUID" "$(id -u "$real_user")")
    pgid=$(get_config_value "PGID" "$(id -g "$real_user")")
    state_owner="$puid:$pgid"
    log_info "Creating state directories under $state_dir (owned by $state_owner)..."

    # Ensure base state directory exists and is accessible
    # Base dir might need broader permissions initially if PUID doesn't exist yet?
    # Let's keep it root owned but group writable initially, maybe? Or just owned by state_owner.
    ensure_dir "$state_dir" 755 "$state_owner" || { log_warn "Could not create/set owner $state_owner for $state_dir. Using root."; state_owner="root:root"; ensure_dir "$state_dir" 755 "$state_owner"; }

    # Subdirectories owned by the container user (PUID:PGID)
    ensure_dir "$state_dir/data" 700 "$state_owner" || return 1
    ensure_dir "$state_dir/data/bwdata" 700 "$state_owner" || return 1 # Critical subdir
    ensure_dir "$state_dir/logs" 775 "$state_owner" || return 1 # Writable by group might be useful
    ensure_dir "$state_dir/caddy" 755 "$state_owner" || return 1
    ensure_dir "$state_dir/caddy/data" 755 "$state_owner" || return 1
    ensure_dir "$state_dir/caddy/config" 755 "$state_owner" || return 1
    ensure_dir "$state_dir/ddclient" 700 "$state_owner" || return 1
    ensure_dir "$state_dir/ddclient/cache" 700 "$state_owner" || return 1
    ensure_dir "$state_dir/logs/caddy" 775 "$state_owner" || return 1
    ensure_dir "$state_dir/logs/vaultwarden" 775 "$state_owner" || return 1
    ensure_dir "$state_dir/logs/fail2ban" 775 "$state_owner" || return 1

    log_success "Project and state directories created successfully."
    return 0
}

create_secrets_template() {
    log_info "Creating secrets template file (secrets/secrets.yaml)..."

    local secrets_file="$PROJECT_ROOT/secrets/secrets.yaml"
    local real_user real_group owner
    real_user=$(get_real_user)
    real_group=$(id -g -n "$real_user" 2>/dev/null || echo "$real_user")
    owner="$real_user:$real_group"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create secrets template at $secrets_file and encrypt it."
        return 0
    fi

    # Check if secrets file already exists
    if [[ -f "$secrets_file" ]] && [[ "$FORCE" != "true" ]]; then
        log_info "Secrets file already exists ($secrets_file), skipping template creation."
        log_info "Use --force to overwrite or './edit-secrets.sh' to modify."
        # Ensure ownership is correct even if skipped
        chown "$owner" "$secrets_file" 2>/dev/null || true
        return 0
    fi

    # Generate random values using crypto library
    local admin_token backup_pass
    admin_token=$(generate_hex_string 32)
    backup_pass=$(generate_secure_string 32)

    # Create secrets template content
    log_info "Generating template content..."
    cat > "$secrets_file" << EOF
# VaultWarden-OCI-Simplified Encrypted Secrets
# Edit this file securely using: ./edit-secrets.sh (or make edit-secrets)

# VaultWarden Admin Authentication (REQUIRED)
# Generate token with: openssl rand -hex 32
admin_token: $admin_token
# Generate bcrypt hash for basic auth (use option 2 in ./edit-secrets.sh or https://bcrypt-generator.com/)
admin_basic_auth_hash: "CHANGE_ME_BCRYPT_HASH_FOR_ADMIN_PANEL"

# Cloudflare API Tokens (REQUIRED)
# Create at https://dash.cloudflare.com/profile/api-tokens
# Permissions: Zone:DNS:Edit (for your domain)
ddclient_api_token: "CHANGE_ME_CLOUDFLARE_DNS_API_TOKEN"
# Permissions: Zone:Firewall Services:Edit (for your domain)
fail2ban_api_token: "CHANGE_ME_CLOUDFLARE_FIREWALL_API_TOKEN"

# Optional: SMTP Configuration (for email notifications)
# Set SMTP_* variables in .env as well if using this
smtp_password: "CHANGE_ME_YOUR_SMTP_PASSWORD_OR_APP_PASSWORD"

# Optional: Push Notifications (get from https://bitwarden.com/host)
push_installation_id: ""
push_installation_key: ""

# Optional: Backup Security (extra layer besides Age encryption)
backup_passphrase: $backup_pass
EOF

    # Set secure permissions and ownership
    chmod 600 "$secrets_file"
    chown "$owner" "$secrets_file" || log_warn "Could not set ownership on secrets template."

    log_success "Secrets template created: $secrets_file"
    log_info "Encrypting secrets file using SOPS and Age key..."

    # Ensure SOPS config exists first
    if [[ ! -f "$PROJECT_ROOT/.sops.yaml" ]]; then
        log_warn "SOPS config (.sops.yaml) missing, attempting to create it..."
        create_sops_config || {
            log_error "Failed to create SOPS config. Cannot encrypt secrets."
            # Consider removing the unencrypted template?
            # rm -f "$secrets_file"
            return 1
        }
    fi

    # Ensure Age key exists for SOPS
    if ! check_age_key "$PROJECT_ROOT/secrets/keys/age-key.txt"; then
         log_error "Age private key not found or inaccessible. Cannot encrypt secrets."
         # rm -f "$secrets_file"
         return 1
    fi

    # Encrypt the file using SOPS library function
    if sops_encrypt "$secrets_file"; then
        log_success "Secrets file encrypted successfully."
    else
        log_error "Failed to encrypt secrets file ($secrets_file)."
        log_info "Check SOPS configuration (.sops.yaml) and Age key permissions."
        # rm -f "$secrets_file" # Clean up unencrypted file on failure
        return 1
    fi

    log_warn "CRITICAL: Secrets file initialized with placeholders!"
    log_warn "Run './edit-secrets.sh' (or 'make edit-secrets') to set required values."
    return 0
}

set_script_permissions() {
    log_info "Setting script permissions..."

    local real_user real_group owner
    real_user=$(get_real_user)
    real_group=$(id -g -n "$real_user" 2>/dev/null || echo "$real_user")
    owner="$real_user:$real_group"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would set executable permissions on *.sh scripts and set owner to $owner."
        return 0
    fi

    # Set executable permissions on all shell scripts in project root
    find "$PROJECT_ROOT" -maxdepth 1 -name "*.sh" -type f -exec chmod u+x {} \;
    # Ensure Makefile is readable
    [[ -f "$PROJECT_ROOT/Makefile" ]] && chmod 644 "$PROJECT_ROOT/Makefile"

    # Set ownership of the entire project dir again at the end
    if chown -R "$owner" "$PROJECT_ROOT"; then
        log_success "Script permissions and project ownership configured."
    else
        log_warn "Failed to set final ownership on project directory $PROJECT_ROOT."
    fi
    return 0
}

# --- Main Setup Function ---
main() {
    log_header "VaultWarden-OCI-Simplified Setup"
    log_info "Domain: $DOMAIN"
    log_info "Admin Email: $ADMIN_EMAIL"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "*** DRY RUN MODE ENABLED - No changes will be made ***"
    fi

    # Store flag for docker activation needed
    local docker_activation_needed=false

    # Phase 1: Dependencies
    log_header "Phase 1: Installing Dependencies"
    # install_dependencies returns 1 if docker activation is needed
    install_dependencies || { [[ $? -eq 1 ]] && docker_activation_needed=true || { log_error "Dependency installation failed critically."; exit 1; } }

    # Verify dependencies (skip if skipping deps, but still useful)
    if [[ "$SKIP_DEPS" != "true" ]]; then
        verify_dependencies || {
            log_error "Dependency verification failed. Some required tools might be missing."
            # Don't exit here, allow user to fix manually if needed
        }
    fi

    # Phase 2: System Configuration
    log_header "Phase 2: System Configuration"
    # User permissions should be set before creating files/dirs owned by the user
    setup_user_permissions || exit 1 # Exit if basic ownership fails
    # Firewall setup relies on UFW being installed
    setup_firewall || exit 1 # Exit if firewall setup fails

    # Phase 3: Project Setup
    log_header "Phase 3: Project Configuration"
    # Create .env first as other steps might read from it
    create_env_file || exit 1
    # Create directories with correct ownership (reads PUID/PGID from .env)
    setup_directories || exit 1
    # Generate crypto keys
    generate_age_keys || exit 1
    # Create SOPS config using public key
    create_sops_config || exit 1
    # Create secrets template and encrypt it
    create_secrets_template || exit 1
    # Set final script permissions
    set_script_permissions || exit 1

    # Phase 4: Final Steps
    log_header "Phase 4: Setup Completion"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_success "DRY RUN completed successfully."
        log_info "Run without --dry-run to perform the actual setup."
        exit 0
    fi

    log_success "Setup completed successfully!"
    echo ""
    log_warn "--- CRITICAL NEXT STEPS ---"
    echo "  1. Review '.env' file: nano .env"
    echo "     - Set 'CLOUDFLARE_ZONE_ID' (REQUIRED)"
    echo "     - Set 'RCLONE_REMOTE_NAME' if using remote backups"
    echo "     - Adjust resource limits or other settings if needed"
    echo ""
    echo "  2. Configure REQUIRED secrets: ./edit-secrets.sh (or make edit-secrets)"
    echo "     - Set 'admin_basic_auth_hash' (use option 2)"
    echo "     - Set 'ddclient_api_token' (Cloudflare DNS token)"
    echo "     - Set 'fail2ban_api_token' (Cloudflare Firewall token)"
    echo "     - Set 'smtp_password' if using email notifications"
    echo ""

    if [[ "$docker_activation_needed" == "true" ]]; then
        log_warn "--- DOCKER GROUP ACTIVATION REQUIRED ---"
        local real_user=$(get_real_user)
        echo "  User '$real_user' needs to activate docker group membership."
        echo "  Choose ONE option:"
        echo "    A) Log out and log back in."
        echo "    B) Run: newgrp docker (only affects current shell)"
        echo ""
        echo "  After activating docker access, continue below."
        echo "------------------------------------------"
        echo ""
        echo "--- After .env, secrets, and docker activation ---"
    else
        echo "--- After configuring .env and secrets ---"
    fi
    echo "  3. Start services: ./startup.sh (or make up)"
    echo "  4. Setup automation (recommended): sudo ./cron-setup.sh"
    echo "  5. Create emergency admin (recommended): sudo ./create-breakglass-admin.sh create (or make breakglass-create)"
    echo "  6. Verify deployment: ./health.sh --comprehensive (or make health)"
    echo ""
    echo "Your VaultWarden instance should be available shortly at: https://$DOMAIN"
    echo ""
    log_warn "Remember to backup your Age private key (secrets/keys/age-key.txt) securely!"
    echo ""
    log_info "Run 'make' to see available management commands."
}

# --- Execution ---
main "$@"
