#!/usr/bin/env bash
# setup.sh - VaultWarden-OCI-Simplified Setup Script
# Fixed: UFW interactive prompt issue and other improvements

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

if [[ -z "$ADMIN_EMAIL" ]]; then
    log_error "Admin email is required. Use --email admin@example.com"
    show_help
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
        if command timeout 5s sudo -u "$real_user" docker info >/dev/null 2>&1; then
            log_debug "Docker group access is active for $real_user."
            return 0
        else
            log_debug "Docker group membership exists but is not active in current session for $real_user."
            return 1
        fi
    else
        log_debug "User $real_user is not in docker group yet."
        return 1
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
        return 1
    fi
}

# --- Dependency Installation Functions ---

install_docker() {
    log_info "Installing Docker CE and Docker Compose Plugin..."

    apt-get remove -y docker docker-engine docker.io containerd runc docker-compose docker-compose-v2 2>/dev/null || true

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
         return 1
    fi

    log_info "Starting and enabling Docker service..."
    if ! systemctl start docker; then log_warn "Failed to start Docker service immediately."; fi
    if ! systemctl enable docker; then log_warn "Failed to enable Docker service."; fi
    sleep 2

    # Verify Docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker service installed but failed to start or is not accessible."
        return 1
    fi

    log_success "Docker CE and Docker Compose Plugin installed successfully."

    # Set up docker group access for the non-root user
    setup_docker_group_access
    return $?
}

install_sops() {
    log_info "Installing SOPS (Secrets OPerationS)..."

    local sops_version="3.8.1"
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
        log_error "SOPS installation verification failed."
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
        log_info "[DRY RUN] Would install system dependencies"
        return 0
    fi

    log_info "Installing system dependencies..."

    log_info "Updating package lists..."
    if ! apt-get update -qq; then
        log_error "Failed to update package lists."
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
        "coreutils"     # Provides numfmt used in backup_utils.sh
    )

    export DEBIAN_FRONTEND=noninteractive
    if apt-get install -y "${basic_packages[@]}"; then
        log_success "Basic dependencies installed successfully."
    else
        log_error "Failed to install some basic dependencies."
        return 1
    fi

    # Install Docker (requires special handling)
    local docker_activation_needed=false
    if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
        install_docker || { [[ $? -eq 1 ]] && docker_activation_needed=true || { log_error "Docker installation failed critically."; return 1; } }
    else
        log_info "Docker already installed, verifying version..."
        docker --version
        docker compose version
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
        "nano"
        "sqlite3"
        "curl"
        "jq"
        "numfmt"
        "rclone"
        "ufw"
        "mail"
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

    if chown -R "$owner" "$PROJECT_ROOT"; then
        log_success "Project directory ownership set to $owner."
    else
        log_warn "Failed to set ownership of project directory $PROJECT_ROOT."
        return 1
    fi
    return 0
}

# FIXED: UFW setup function that handles interactive prompt
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

    # Allow SSH FIRST before enabling firewall (critical!)
    local ssh_port
    ssh_port=$(get_config_value "SSH_PORT" "22" 2>/dev/null || echo "22")
    log_info "Allowing SSH traffic on port $ssh_port/tcp..."
    ufw allow "$ssh_port/tcp" comment "SSH" >/dev/null 2>&1

    # Allow HTTP and HTTPS from anywhere (Caddy will handle Cloudflare filtering)
    log_info "Allowing HTTP (port 80/tcp) and HTTPS (port 443/tcp) from ANY source..."
    log_info "(Caddy's 'forwarded' directive will handle Cloudflare IP filtering)"
    ufw allow 80/tcp comment "HTTP - Caddy handles CF filtering" >/dev/null 2>&1
    ufw allow 443/tcp comment "HTTPS - Caddy handles CF filtering" >/dev/null 2>&1

    # Enable firewall - FIXED: Use 'yes' to automatically answer the interactive prompt
    log_info "Enabling UFW firewall..."
    if echo "y" | ufw enable >/dev/null 2>&1; then
        log_success "UFW firewall configured and enabled (static rules)"
        log_info "Note: Cloudflare IP filtering is handled by Caddy's forwarded directive"
    else
        log_error "Failed to enable UFW firewall!"
        log_info "You may need to enable it manually: sudo ufw --force enable"
        return 1
    fi
}

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
        chown "$owner" "$private_key" "$public_key" 2>/dev/null || true
        return 0
    fi

    # Generate Age key pair
    log_info "Generating new Age key pair..."
    if ! age-keygen -o "$private_key"; then
        log_error "Failed to generate Age private key."
        return 1
    fi

    chmod 600 "$private_key"

    if ! age-keygen -y "$private_key" > "$public_key"; then
        log_error "Failed to extract Age public key."
        rm -f "$private_key"
        return 1
    fi
    chmod 644 "$public_key"

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
        return 0
    fi

    # Check if .env already exists
    if [[ -f "$env_file" ]] && [[ "$FORCE" != "true" ]]; then
        log_info ".env file already exists, skipping creation. Use --force to overwrite."
        return 0
    fi

    # Copy from example if it exists, otherwise create minimal version
    if [[ -f "$env_example" ]]; then
        cp "$env_example" "$env_file"
        sed -i "s|^#*DOMAIN=.*|DOMAIN=$DOMAIN|" "$env_file"
        sed -i "s|^#*ADMIN_EMAIL=.*|ADMIN_EMAIL=$ADMIN_EMAIL|" "$env_file"
        sed -i "s|^#*DDCLIENT_HOSTNAME=.*|DDCLIENT_HOSTNAME=$DOMAIN|" "$env_file"
    else
        # Create minimal .env file
        cat > "$env_file" << EOF
# VaultWarden-OCI-Simplified Configuration
# Generated by setup.sh on $(date)

DOMAIN=$DOMAIN
ADMIN_EMAIL=$ADMIN_EMAIL
COMPOSE_PROJECT_NAME=vaultwarden
PROJECT_STATE_DIR=/var/lib/vaultwarden

# Fixed: Use PUID/PGID to avoid bash variable collision
PUID=1000
PGID=1000

SSH_PORT=22
CLOUDFLARE_ZONE_ID=CHANGE_ME
DDCLIENT_HOSTNAME=$DOMAIN

DB_BACKUP_RETENTION_DAYS=14
FULL_BACKUP_RETENTION_DAYS=30
EMERGENCY_BACKUP_RETENTION_DAYS=90
BACKUP_ENCRYPTION=age
RCLONE_REMOTE_NAME=CHANGE_ME

VAULTWARDEN_MEMORY_LIMIT=1g
CADDY_MEMORY_LIMIT=128m
FAIL2BAN_MEMORY_LIMIT=64m
DDCLIENT_MEMORY_LIMIT=64m
EOF
    fi

    # Add version pins based on --use-latest flag
    if [[ "$USE_LATEST" == "true" ]]; then
        log_info "Configured for development mode (using 'latest' container versions)"
        sed -i -e "/^VAULTWARDEN_VERSION=/s/^/#/" -e "/^CADDY_VERSION=/s/^/#/" -e "/^FAIL2BAN_VERSION=/s/^/#/" -e "/^DDCLIENT_VERSION=/s/^/#/" "$env_file"
    else
        log_info "Configured for production mode (pinning container versions)"
        cat >> "$env_file" << EOF

# Container versions (pinned for stability)
VAULTWARDEN_VERSION=1.31.0
CADDY_VERSION=2.8.4
FAIL2BAN_VERSION=1.1.0
DDCLIENT_VERSION=3.11.2
EOF
    fi

    # Set correct PUID/PGID
    local real_user real_uid real_gid
    real_user=$(get_real_user)
    real_uid=$(id -u "$real_user")
    real_gid=$(id -g "$real_user")
    
    sed -i "s/^PUID=.*/PUID=$real_uid/" "$env_file"
    sed -i "s/^PGID=.*/PGID=$real_gid/" "$env_file"

    chmod 640 "$env_file"

    local real_group owner
    real_group=$(id -g -n "$real_user" 2>/dev/null || echo "$real_user")
    owner="$real_user:$real_group"
    chown "$owner" "$env_file" || log_warn "Could not set ownership on .env file."

    log_success "Environment configuration file created: $env_file"
    return 0
}

setup_directories() {
    log_info "Creating project and state directories..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create project directories"
        return 0
    fi

    local real_user real_group owner
    real_user=$(get_real_user)
    real_group=$(id -g -n "$real_user" 2>/dev/null || echo "$real_user")
    owner="$real_user:$real_group"

    load_env_file "$PROJECT_ROOT/.env" || log_warn "Could not load .env for directory setup"
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")

    # Create project directories
    local project_dirs=(
        "secrets"
        "secrets/keys"
        "backups"
        "backups/db"
        "backups/full"  
        "backups/emergency"
        "logs"
        "lib"
    )

    for dir in "${project_dirs[@]}"; do
        ensure_dir "$PROJECT_ROOT/$dir" 750 "$owner"
    done
    ensure_dir "$PROJECT_ROOT/secrets" 700 "$owner"
    ensure_dir "$PROJECT_ROOT/secrets/keys" 700 "$owner"

    # Create state directories
    log_info "Creating state directories in $state_dir..."
    ensure_dir "$state_dir" 755 "root:root"
    ensure_dir "$state_dir/data" 700 "$owner"
    ensure_dir "$state_dir/data/bwdata" 700 "$owner"  # Critical VaultWarden subdir
    ensure_dir "$state_dir/logs" 755 "$owner"
    ensure_dir "$state_dir/caddy" 755 "$owner"
    ensure_dir "$state_dir/caddy/data" 755 "$owner"
    ensure_dir "$state_dir/caddy/config" 755 "$owner"
    ensure_dir "$state_dir/ddclient" 755 "$owner"
    ensure_dir "$state_dir/ddclient/cache" 755 "$owner"
    ensure_dir "$state_dir/logs/caddy" 755 "$owner"
    ensure_dir "$state_dir/logs/vaultwarden" 755 "$owner"
    ensure_dir "$state_dir/logs/fail2ban" 755 "$owner"

    log_success "Project directories created successfully"
}

create_secrets_template() {
    log_info "Creating secrets template..."

    local secrets_file="$PROJECT_ROOT/secrets/secrets.yaml"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create secrets template"
        return 0
    fi

    if [[ -f "$secrets_file" ]] && [[ "$FORCE" != "true" ]]; then
        log_info "Secrets file already exists, skipping template creation"
        return 0
    fi

    local admin_token backup_pass
    admin_token=$(generate_hex_string 32)
    backup_pass=$(generate_secure_string 32)

    cat > "$secrets_file" << EOF
# VaultWarden-OCI-Simplified Encrypted Secrets
# Edit with: ./edit-secrets.sh or make edit-secrets

admin_token: $admin_token
admin_basic_auth_hash: "CHANGE_ME_BCRYPT_HASH"
ddclient_api_token: "CHANGE_ME_DNS_TOKEN"
fail2ban_api_token: "CHANGE_ME_FIREWALL_TOKEN"
smtp_password: "CHANGE_ME_SMTP_PASSWORD"
push_installation_id: ""
push_installation_key: ""
backup_passphrase: $backup_pass
EOF

    chmod 600 "$secrets_file"

    local real_user real_group owner
    real_user=$(get_real_user)
    real_group=$(id -g -n "$real_user" 2>/dev/null || echo "$real_user")
    owner="$real_user:$real_group"
    chown "$owner" "$secrets_file"

    log_success "Secrets template created: $secrets_file"
    log_info "Encrypting secrets file..."

    if [[ ! -f "$PROJECT_ROOT/.sops.yaml" ]]; then
        create_sops_config || {
            log_error "Failed to create SOPS config. Cannot encrypt secrets."
            return 1
        }
    fi

    if sops --encrypt --in-place "$secrets_file"; then
        log_success "Secrets file encrypted successfully"
    else
        log_error "Failed to encrypt secrets file"
        return 1
    fi

    log_warn "CRITICAL: Configure secrets with: make edit-secrets"
}

set_script_permissions() {
    log_info "Setting script permissions..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would set executable permissions on scripts"
        return 0
    fi

    find "$PROJECT_ROOT" -name "*.sh" -type f -exec chmod +x {} \;
    [[ -f "$PROJECT_ROOT/Makefile" ]] && chmod 644 "$PROJECT_ROOT/Makefile"

    local real_user real_group owner
    real_user=$(get_real_user)
    real_group=$(id -g -n "$real_user" 2>/dev/null || echo "$real_user")
    owner="$real_user:$real_group"
    chown -R "$owner" "$PROJECT_ROOT"

    log_success "Script permissions configured"
}

# --- Main Setup Function ---
main() {
    log_header "VaultWarden-OCI-Simplified Setup"
    log_info "Domain: $DOMAIN"
    log_info "Admin Email: $ADMIN_EMAIL"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    local docker_group_activation_needed=false

    log_info "=== Phase 1: Installing Dependencies ==="
    install_dependencies || {
        [[ $? -eq 1 ]] && docker_group_activation_needed=true || { log_error "Dependency installation failed"; exit 1; }
    }

    if [[ "$SKIP_DEPS" != "true" ]]; then
        verify_dependencies || {
            log_error "Dependency verification failed"
            exit 1
        }
    fi

    log_info "=== Phase 2: System Configuration ==="
    setup_user_permissions
    setup_firewall

    log_info "=== Phase 3: Project Configuration ==="
    create_env_file
    setup_directories
    generate_age_keys
    create_sops_config || {
        log_error "Failed to setup SOPS configuration"
        exit 1
    }
    create_secrets_template || {
        log_error "Failed to setup secrets template"
        exit 1
    }
    set_script_permissions

    log_info "=== Phase 4: Setup Completion ==="

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN completed successfully"
        exit 0
    fi

    log_success "Setup completed successfully!"
    echo ""
    echo "Next Steps:"
    echo "  1. Configure secrets: make edit-secrets"
    echo "  2. Update .env file: nano .env"
    echo "     - Set CLOUDFLARE_ZONE_ID"
    echo "     - Set RCLONE_REMOTE_NAME"
    
    if [[ "$docker_group_activation_needed" == "true" ]]; then
        echo ""
        log_warn "IMPORTANT - Docker Group Activation Required:"
        local real_user
        real_user=$(get_real_user)
        echo "  User $real_user needs to activate docker group membership:"
        echo "    Option A: Log out and log back in (recommended)"
        echo "    Option B: Run: newgrp docker"
        echo ""
        echo "  After activating docker access:"
    else
        echo ""
        echo "  After configuring secrets and .env:"
    fi
    
    echo "  3. Start services: make up"
    echo "  4. Setup automation: sudo ./cron-setup.sh"
    echo "  5. Create emergency admin: make breakglass-create"
    echo "  6. Verify deployment: make health"
    echo ""
    echo "Your VaultWarden will be available at: https://$DOMAIN"
    echo ""
    log_warn "CRITICAL: Backup the Age private key (secrets/keys/age-key.txt) securely!"
    echo ""
    log_info "Run 'make' to see available commands for managing your instance."
}

main "$@"
