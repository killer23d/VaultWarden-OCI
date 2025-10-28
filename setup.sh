#!/usr/bin/env bash
# setup.sh - VaultWarden-OCI-Simplified Setup Script (Fixed Dependencies & SOPS Config)

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

    # Skip dependency installation (if already installed)
    sudo ./setup.sh --domain vault.example.com --email admin@example.com --skip-deps

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

# --- Dependency Installation Functions ---

install_docker() {
    log_info "Installing Docker CE and Docker Compose Plugin..."

    # Remove old Docker packages if they exist
    log_info "Removing old Docker packages..."
    apt-get remove -y docker docker-engine docker.io containerd runc docker-compose 2>/dev/null || true

    # Update package index
    apt-get update

    # Install prerequisites
    log_info "Installing Docker prerequisites..."
    apt-get install -y ca-certificates curl gnupg lsb-release software-properties-common

    # Add Docker's official GPG key
    log_info "Adding Docker repository..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Update package index with Docker repo
    apt-get update

    # Install Docker Engine, CLI, and Compose Plugin
    log_info "Installing Docker Engine and Compose Plugin..."
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Start and enable Docker
    systemctl start docker
    systemctl enable docker

    # Add current user to docker group (get actual user, not root)
    local real_user
    real_user=$(get_real_user)
    if [[ -n "$real_user" ]] && [[ "$real_user" != "root" ]]; then
        usermod -aG docker "$real_user"
    fi

    log_success "Docker CE and Docker Compose Plugin installed successfully"
}

install_sops() {
    log_info "Installing SOPS (Secrets OPerationS)..."

    local sops_version="3.8.1" # You can update this version as needed
    local arch
    arch=$(dpkg --print-architecture)
    local sops_binary=""

    case "$arch" in
        "amd64")
            sops_binary="sops-v${sops_version}.linux.amd64"
            ;;
        "arm64")
            sops_binary="sops-v${sops_version}.linux.arm64"
            ;;
        *)
            log_error "Unsupported architecture: $arch"
            log_info "Supported architectures: amd64, arm64"
            return 1
            ;;
    esac

    # Download SOPS
    log_info "Downloading SOPS for $arch architecture..."
    curl -fsSL "https://github.com/mozilla/sops/releases/download/v${sops_version}/${sops_binary}" -o "/tmp/${sops_binary}"

    # Install SOPS
    mv "/tmp/${sops_binary}" /usr/local/bin/sops
    chmod +x /usr/local/bin/sops

    # Verify installation
    if sops --version >/dev/null 2>&1; then
        log_success "SOPS v${sops_version} installed successfully"
    else
        log_error "SOPS installation verification failed"
        return 1
    fi
}

install_dependencies() {
    if [[ "$SKIP_DEPS" == "true" ]]; then
        log_info "Skipping dependency installation (--skip-deps specified)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install system dependencies"
        return 0
    fi

    log_info "Installing system dependencies..."

    # Update package lists
    log_info "Updating package lists..."
    apt-get update

    # Install basic dependencies (available in standard repos)
    log_info "Installing basic dependencies..."
    local basic_packages=(
        "age"           # Encryption tool
        "make"          # Build utility (for Makefile shortcuts)
        "nano"          # Text editor
        "rclone"        # Cloud sync tool
        "sqlite3"       # Database tool
        "argon2"        # Password hashing tool
        "jq"            # JSON processor
        "mailutils"     # Email utilities
        "ufw"           # Firewall
        "curl"          # HTTP client
        "wget"          # Download tool
        "unzip"         # Archive tool
        "git"           # Version control
        "gpg"           # GPG for docker key
    )

    if apt-get install -y "${basic_packages[@]}"; then
        log_success "Basic dependencies installed successfully"
    else
        log_error "Failed to install some basic dependencies"
        log_info "You may need to run: sudo apt-get update && sudo apt-get upgrade"
        return 1
    fi

    # Install Docker (requires special handling)
    if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
        install_docker || {
            log_error "Docker installation failed"
            return 1
        }
    else
        log_info "Docker already installed, verifying version..."
        docker --version
        docker compose version
    fi

    # Install SOPS (requires manual installation)
    if ! command -v sops >/dev/null 2>&1; then
        install_sops || {
            log_error "SOPS installation failed"
            return 1
        }
    else
        log_info "SOPS already installed: $(sops --version)"
    fi

    log_success "All dependencies installed successfully"
}

# --- Verification Functions ---
verify_dependencies() {
    log_info "Verifying installed dependencies..."

    local missing_deps=()
    local required_commands=(
        "docker"
        "age"
        "sops"
        "make" # Verify make is present
        "sqlite3"
        "curl"
        "jq"
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
        log_info "Run the script without --skip-deps to install them automatically"
        return 1
    fi

    log_success "All required dependencies are available"

    # Show versions for verification
    log_info "Dependency versions:"
    echo "  Docker: $(docker --version)"
    echo "  Docker Compose: $(docker compose version --short)"
    echo "  Age: $(age --version | head -1)"
    echo "  SOPS: $(sops --version)"
    echo "  Make: $(make --version | head -1)"
    echo "  SQLite: $(sqlite3 --version | cut -d' ' -f1)"
}

# --- Configuration Functions ---
setup_user_permissions() {
    log_info "Setting up user permissions..."

    local real_user
    real_user=$(get_real_user)
    local real_group
    real_group=$(id -g -n "$real_user" 2>/dev/null || echo "$real_user")

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would set up permissions for user: $real_user:$real_group"
        return 0
    fi

    # Ensure user is in docker group (this was already done in install_docker, but good to have here)
    if [[ -n "$real_user" ]] && [[ "$real_user" != "root" ]]; then
        usermod -aG docker "$real_user" || {
            log_warn "Failed to add $real_user to docker group (might be done already)"
        }
    fi

    # Set ownership of project directory
    chown -R "$real_user:$real_group" "$PROJECT_ROOT" || {
        log_warn "Failed to set ownership of project directory"
    }

    log_success "User permissions configured for $real_user"
}

setup_firewall() {
    log_info "Configuring UFW firewall..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would configure firewall rules"
        return 0
    fi

    if ! has_command ufw; then
        log_warn "UFW command not found, skipping firewall setup."
        return 0
    fi

    # Reset firewall to default state
    ufw --force reset >/dev/null 2>&1

    # Set default policies
    ufw default deny incoming
    ufw default allow outgoing

    # Allow SSH (current session)
    local ssh_port
    ssh_port=$(get_config_value "SSH_PORT" "22" 2>/dev/null || echo "22")
    ufw allow "$ssh_port/tcp" comment "SSH"

    # Allow HTTP and HTTPS (will be restricted to Cloudflare IPs later)
    ufw allow 80/tcp comment "HTTP"
    ufw allow 443/tcp comment "HTTPS"

    # Enable firewall
    ufw --force enable

    log_success "UFW firewall configured and enabled"
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

    # Create secrets directory structure
    ensure_dir "$keys_dir" 700

    # Check if keys already exist
    if [[ -f "$private_key" && -f "$public_key" ]] && [[ "$FORCE" != "true" ]]; then
        log_info "Age keys already exist, skipping generation"
        log_info "Use --force to regenerate keys (will invalidate existing secrets)"
        return 0
    fi

    # Generate Age key pair
    log_info "Generating new Age key pair..."
    age-keygen -o "$private_key"
    age-keygen -y "$private_key" > "$public_key"

    # Secure key files
    chmod 600 "$private_key"
    chmod 644 "$public_key"

    # Set ownership
    local real_user
    real_user=$(get_real_user)
    local real_group
    real_group=$(id -g -n "$real_user" 2>/dev/null || echo "$real_user")
    chown "$real_user:$real_group" "$private_key" "$public_key"

    log_success "Age encryption keys generated successfully"
    log_warn "CRITICAL: Backup the private key ($private_key) securely!"
}

# --- START SOPS CONFIG FIX ---
create_sops_config() {
    log_info "Creating SOPS configuration file (.sops.yaml)..."

    local sops_config_file="$PROJECT_ROOT/.sops.yaml"
    local public_key_file="$PROJECT_ROOT/secrets/keys/age-public-key.txt"
    local public_key=""

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create $sops_config_file"
        return 0
    fi

    if [[ ! -f "$public_key_file" ]]; then
        log_error "Age public key not found. Cannot create SOPS config."
        return 1
    fi

    public_key=$(cat "$public_key_file") || {
        log_error "Failed to read Age public key."
        return 1
    }

    if [[ -z "$public_key" ]]; then
        log_error "Age public key is empty."
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
  - path_regex: secrets/.*\.yaml$
    age: $public_key
EOF

    # Set permissions and ownership
    chmod 644 "$sops_config_file"
    local real_user
    real_user=$(get_real_user)
    local real_group
    real_group=$(id -g -n "$real_user" 2>/dev/null || echo "$real_user")
    chown "$real_user:$real_group" "$sops_config_file"

    log_success "SOPS configuration created: $sops_config_file"
}
# --- END SOPS CONFIG FIX ---

create_env_file() {
    log_info "Creating environment configuration file..."

    local env_file="$PROJECT_ROOT/.env"
    local env_example="$PROJECT_ROOT/.env.example"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create .env file with domain: $DOMAIN"
        return 0
    fi

    # Check if .env already exists
    if [[ -f "$env_file" ]] && [[ "$FORCE" != "true" ]]; then
        log_info ".env file already exists, skipping creation"
        log_info "Use --force to overwrite existing configuration"
        return 0
    fi

    # Copy from example if it exists
    if [[ -f "$env_example" ]]; then
        cp "$env_example" "$env_file"
        # Now update the domain and email
        sed -i "s/^DOMAIN=.*/DOMAIN=$DOMAIN/" "$env_file"
        sed -i "s/^ADMIN_EMAIL=.*/ADMIN_EMAIL=$ADMIN_EMAIL/" "$env_file"
        sed -i "s/^DDCLIENT_HOSTNAME=.*/DDCLIENT_HOSTNAME=$DOMAIN/" "$env_file"
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

# --- START FIX: Use PUID/PGID ---
# USER & PERMISSIONS
PUID=1000
PGID=1000
# --- END FIX ---

# HOST CONFIGURATION
SSH_PORT=22

# CLOUDFLARE & DYNAMIC DNS (REQUIRED)
CLOUDFLARE_ZONE_ID=CHANGE_ME
DDCLIENT_HOSTNAME=$DOMAIN

# BACKUP CONFIGURATION
DB_BACKUP_RETENTION_DAYS=14
FULL_BACKUP_RETENTION_DAYS=30
EMERGENCY_BACKUP_RETENTION_DAYS=90
BACKUP_ENCRYPTION=age
RCLONE_REMOTE_NAME=CHANGE_ME

# RESOURCE LIMITS
VAULTWARDEN_MEMORY_LIMIT=1g
CADDY_MEMORY_LIMIT=128m
FAIL2BAN_MEMORY_LIMIT=64m
DDCLIENT_MEMORY_LIMIT=64m

EOF
    fi

    # Add/Update version pins based on --use-latest flag
    if [[ "$USE_LATEST" == "true" ]]; then
        log_info "Configured for development mode (using 'latest' container versions)"
        # Comment out any existing version pins
        sed -i -e "/^VAULTWARDEN_VERSION=/s/^/#/" -e "/^CADDY_VERSION=/s/^/#/" -e "/^FAIL2BAN_VERSION=/s/^/#/" -e "/^DDCLIENT_VERSION=/s/^/#/" "$env_file"
    else
        log_info "Configured for production mode (pinning container versions)"
        # Set specific versions (update these as needed for new releases)
        local current_vw_version="1.31.0" # Updated version
        local current_caddy_version="2.8.4"
        local current_f2b_version="1.1.0"
        local current_ddc_version="3.11.2"

        # Use awk to robustly add or update lines
        local temp_env
        temp_env=$(mktemp)
        awk -v vw_ver="$current_vw_version" \
            -v caddy_ver="$current_caddy_version" \
            -v f2b_ver="$current_f2b_version" \
            -v ddc_ver="$current_ddc_version" '
            BEGIN {
                pins["VAULTWARDEN_VERSION"] = vw_ver
                pins["CADDY_VERSION"] = caddy_ver
                pins["FAIL2BAN_VERSION"] = f2b_ver
                pins["DDCLIENT_VERSION"] = ddc_ver
            }
            {
                matched = 0
                for (key in pins) {
                    if ($0 ~ "^#?" key "=") {
                        print key "=" pins[key]
                        delete pins[key]
                        matched = 1
                        next
                    }
                }
                if (!matched) {
                    print
                }
            }
            END {
                for (key in pins) {
                    print key "=" pins[key]
                }
            }
        ' "$env_file" > "$temp_env"
        mv "$temp_env" "$env_file"
    fi

    # Set correct PUID/PGID
    local real_user
    real_user=$(get_real_user)
    local real_uid
    real_uid=$(id -u "$real_user")
    local real_gid
    real_gid=$(id -g "$real_user")

    # --- START FIX: Use PUID/PGID to avoid collision with readonly shell vars ---
    sed -i "s/^PUID=.*/PUID=$real_uid/" "$env_file"
    sed -i "s/^PGID=.*/PGID=$real_gid/" "$env_file"
    # --- END FIX ---


    # Set secure permissions
    chmod 640 "$env_file" # Slightly more secure than 644

    # Set ownership
    local real_group
    real_group=$(id -g -n "$real_user" 2>/dev/null || echo "$real_user")
    chown "$real_user:$real_group" "$env_file"

    log_success "Environment configuration file created: $env_file"
}

setup_directories() {
    log_info "Creating project directories..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create project directories"
        return 0
    fi

    local real_user
    real_user=$(get_real_user)
    local real_group
    real_group=$(id -g -n "$real_user" 2>/dev/null || echo "$real_user")

    # Load state_dir from the .env file we *just* created
    # Use default value if .env loading fails (e.g., in dry run)
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
        "lib" # Ensure lib dir exists
    )
    local project_owner="$real_user:$real_group"

    for dir in "${project_dirs[@]}"; do
        ensure_dir "$PROJECT_ROOT/$dir" 750 "$project_owner" # 750 for slightly more security
    done
    ensure_dir "$PROJECT_ROOT/secrets" 700 "$project_owner" # secrets dir should be private
    ensure_dir "$PROJECT_ROOT/secrets/keys" 700 "$project_owner"


    # Create state directories
    # These must be owned by the PUID/PGID user for the containers to write to them
    log_info "Creating state directories in $state_dir..."
    ensure_dir "$state_dir" 755 "root:root" # Root dir
    ensure_dir "$state_dir/data" 700 "$project_owner" # Data dir MUST be owned by the user
    ensure_dir "$state_dir/logs" 755 "$project_owner" # Logs
    ensure_dir "$state_dir/caddy" 755 "$project_owner" # Caddy state
    ensure_dir "$state_dir/caddy/data" 755 "$project_owner"
    ensure_dir "$state_dir/caddy/config" 755 "$project_owner"
    ensure_dir "$state_dir/ddclient" 755 "$project_owner"
    ensure_dir "$state_dir/ddclient/cache" 755 "$project_owner"
    ensure_dir "$state_dir/logs/caddy" 755 "$project_owner"
    ensure_dir "$state_dir/logs/vaultwarden" 755 "$project_owner"
    ensure_dir "$state_dir/logs/fail2ban" 755 "$project_owner"


    log_success "Project directories created successfully"
}

create_secrets_template() {
    log_info "Creating secrets template..."

    local secrets_file="$PROJECT_ROOT/secrets/secrets.yaml"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create secrets template"
        return 0
    fi

    # Check if secrets file already exists
    if [[ -f "$secrets_file" ]] && [[ "$FORCE" != "true" ]]; then
        log_info "Secrets file already exists, skipping template creation"
        return 0
    fi

    # Generate random values
    local admin_token
    admin_token=$(generate_hex_string 32)
    local backup_pass
    backup_pass=$(generate_secure_string 32)

    # Create secrets template
    cat > "$secrets_file" << EOF
# VaultWarden-OCI-Simplified Encrypted Secrets
# Edit with: ./edit-secrets.sh or make edit-secrets

# VaultWarden Admin Authentication
admin_token: $admin_token
admin_basic_auth_hash: "CHANGE_ME_BCRYPT_HASH"

# Cloudflare API Tokens
ddclient_api_token: "CHANGE_ME_DNS_TOKEN"
fail2ban_api_token: "CHANGE_ME_FIREWALL_TOKEN"

# Optional: SMTP Configuration
smtp_password: "CHANGE_ME_SMTP_PASSWORD"

# Optional: Push Notifications
push_installation_id: ""
push_installation_key: ""

# Optional: Backup Security
backup_passphrase: $backup_pass
EOF

    # Set secure permissions
    chmod 600 "$secrets_file"

    # Set ownership
    local real_user
    real_user=$(get_real_user)
    local real_group
    real_group=$(id -g -n "$real_user" 2>/dev/null || echo "$real_user")
    chown "$real_user:$real_group" "$secrets_file"

    log_success "Secrets template created: $secrets_file"
    log_info "Encrypting secrets file..."

    # Encrypt the file now
    # --- START SOPS CONFIG FIX ---
    # Ensure SOPS config exists before trying to encrypt
    if [[ ! -f "$PROJECT_ROOT/.sops.yaml" ]]; then
        log_warn "SOPS config missing, attempting to create it..."
        create_sops_config || {
            log_error "Failed to create SOPS config. Cannot encrypt secrets."
            return 1
        }
    fi
    # --- END SOPS CONFIG FIX ---

    if sops --encrypt --in-place "$secrets_file"; then
        log_success "Secrets file encrypted successfully"
    else
        log_error "Failed to encrypt secrets file. Check Age key and SOPS config."
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

    # Set executable permissions on all shell scripts
    find "$PROJECT_ROOT" -name "*.sh" -type f -exec chmod +x {} \;
    # Ensure Makefile is readable
    [[ -f "$PROJECT_ROOT/Makefile" ]] && chmod 644 "$PROJECT_ROOT/Makefile"

    # Set ownership
    local real_user
    real_user=$(get_real_user)
    local real_group
    real_group=$(id -g -n "$real_user" 2>/dev/null || echo "$real_user")
    chown -R "$real_user:$real_group" "$PROJECT_ROOT"

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

    # Phase 1: Dependencies
    log_info "=== Phase 1: Installing Dependencies ==="
    install_dependencies || {
        log_error "Dependency installation failed"
        exit 1
    }

    # Verify dependencies (skip if skipping deps)
    if [[ "$SKIP_DEPS" != "true" ]]; then
        verify_dependencies || {
            log_error "Dependency verification failed"
            exit 1
        }
    fi

    # Phase 2: System Configuration
    log_info "=== Phase 2: System Configuration ==="
    setup_user_permissions
    setup_firewall

    # Phase 3: Project Setup
    log_info "=== Phase 3: Project Configuration ==="
    # Order matters: create_env_file reads .env.example, setup_directories reads .env
    create_env_file
    setup_directories
    generate_age_keys
    # --- START SOPS CONFIG FIX ---
    create_sops_config || {
        log_error "Failed to setup SOPS configuration"
        exit 1
    }
    # --- END SOPS CONFIG FIX ---
    create_secrets_template || {
        log_error "Failed to setup secrets template"
        exit 1
    }
    set_script_permissions

    # Phase 4: Final Steps
    log_info "=== Phase 4: Setup Completion ==="

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN completed successfully"
        log_info "Run without --dry-run to perform actual setup"
        exit 0
    fi

    log_success "Setup completed successfully!"
    echo ""
    echo "Next Steps:"
    echo "  1. Configure secrets: make edit-secrets"
    echo "  2. Update .env file: nano .env"
    echo "     - Set CLOUDFLARE_ZONE_ID"
    echo "     - Set RCLONE_REMOTE_NAME"
    echo "     - Configure other settings as needed"
    echo "  3. Start services: make up"
    echo "  4. Setup automation: sudo ./cron-setup.sh"
    echo "  5. Create emergency admin: make breakglass-create"
    echo "  6. Verify deployment: make health"
    echo ""
    echo "Your VaultWarden will be available at: https://$DOMAIN"
    echo ""
    log_warn "IMPORTANT:"
    echo "  - The Age private key is in secrets/keys/age-key.txt - backup it securely!"
    echo "  - Configure secrets before starting services"
    local real_user
    real_user=$(get_real_user)
    if [[ -n "$real_user" ]] && [[ "$real_user" != "root" ]]; then
        echo "  - You ($real_user) must log out and log back in for Docker group membership to apply"
    fi
    # --- START FIX: Add final message ---
    echo ""
    log_info "Run 'make' to see available commands for managing your instance."
    # --- END FIX ---
}

# --- Execution ---
main "$@"

