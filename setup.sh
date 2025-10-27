#!/usr/bin/env bash
# setup.sh - Complete VaultWarden-OCI-NG system setup with library integration

set -euo pipefail

# --- Project Root Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# --- Source Libraries ---
source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh"

# --- Configuration ---
DOMAIN=""
ADMIN_EMAIL=""
AUTO_MODE=false
SKIP_DEPS=false
FORCE=false
# --- START PHASE 2 CHANGE ---
USE_LATEST=false # Default to pinning versions
# --- END PHASE 2 CHANGE ---

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden-OCI-NG Complete Setup

USAGE:
    sudo ./setup.sh [OPTIONS]

OPTIONS:
    --domain DOMAIN    Your domain (e.g., vault.example.com)
    --email EMAIL      Admin email address
    --auto            Automated setup with minimal prompts
    --skip-deps       Skip dependency installation
    --force           Overwrite existing configuration
    --use-latest      Skip pinning container versions in .env (use 'latest' tag by default)
    --help            Show this help

EXAMPLES:
    sudo ./setup.sh --domain vault.example.com --email admin@example.com --auto
    sudo ./setup.sh --domain vault.example.com --email admin@example.com
    sudo ./setup.sh --skip-deps             # Only configure, don't install packages
    sudo ./setup.sh --use-latest            # Setup without pinning versions (defaults to latest)

DESCRIPTION:
    Complete system setup including:
    - System dependencies (Docker, Age, SOPS, Rclone, Mailutils, Nano, Argon2)
    - Firewall configuration
    - Age encryption keys
    - Environment configuration (pins container versions by default)
    - Directory structure
    - Initial secrets template
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain) DOMAIN="$2"; shift 2 ;;
        --email) ADMIN_EMAIL="$2"; shift 2 ;;
        --auto) AUTO_MODE=true; shift ;;
        --skip-deps) SKIP_DEPS=true; shift ;;
        --force) FORCE=true; shift ;;
        # --- START PHASE 2 CHANGE ---
        --use-latest) USE_LATEST=true; shift ;;
        # --- END PHASE 2 CHANGE ---
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Validation ---
validate_setup_environment() {
    # Check if running as root using library function
    if ! is_root; then
        log_error "Setup requires root privileges"
        log_info "Run with: sudo ./setup.sh"
        return 1
    fi

    # Validate domain format using library function
    if [[ -n "$DOMAIN" ]] && ! validate_domain "$DOMAIN"; then
        log_error "Invalid domain format: $DOMAIN"
        return 1
    fi

    # Validate email format using library function
    if [[ -n "$ADMIN_EMAIL" ]] && ! validate_email "$ADMIN_EMAIL"; then
        log_error "Invalid email format: $ADMIN_EMAIL"
        return 1
    fi

    return 0
}

# --- Interactive Setup ---
interactive_setup() {
    log_info "Interactive VaultWarden-OCI-NG Setup"
    echo ""

    # Get domain
    while [[ -z "$DOMAIN" ]]; do
        read -p "Enter your domain (e.g., vault.example.com): " DOMAIN
        if ! validate_domain "$DOMAIN"; then
            log_error "Invalid domain format. Please try again."
            DOMAIN=""
        fi
    done

    # Get admin email
    while [[ -z "$ADMIN_EMAIL" ]]; do
        read -p "Enter admin email address: " ADMIN_EMAIL
        if ! validate_email "$ADMIN_EMAIL"; then
            log_error "Invalid email format. Please try again."
            ADMIN_EMAIL=""
        fi
    done

    echo ""
    log_info "Configuration Summary:"
    echo "  Domain: $DOMAIN"
    echo "  Admin Email: $ADMIN_EMAIL"
    # --- START PHASE 2 CHANGE ---
    if [[ "$USE_LATEST" == "true" ]]; then
        echo "  Container Versions: Default to 'latest' (not pinned in .env)"
    else
        echo "  Container Versions: Pinned in .env (recommended for production)"
    fi
    # --- END PHASE 2 CHANGE ---
    echo ""

    if [[ "$AUTO_MODE" != "true" ]]; then
        read -p "Continue with setup? (Y/n): " confirm_setup
        if [[ "$confirm_setup" =~ ^[Nn]$ ]]; then
            log_info "Setup cancelled"
            exit 0
        fi
    fi
}

# --- System Dependencies ---
install_dependencies() {
    if [[ "$SKIP_DEPS" == "true" ]]; then
        log_info "Skipping dependency installation (--skip-deps specified)"
        return 0
    fi

    log_info "Installing system dependencies..."

    # Update package lists
    log_info "Updating package lists..."
    apt update || {
        log_error "Failed to update package lists"
        return 1
    }

    # Required packages
    # --- P5 FIX: Added argon2 ---
    local packages=("docker.io" "docker-compose-plugin" "age" "sops" "ufw" "curl" "jq" "sqlite3" "gzip" "tar" "cron" "rclone" "mailutils" "nano" "argon2")
    local missing_packages=()

    # Check which packages are missing
    for package in "${packages[@]}"; do
        if ! dpkg -l "$package" >/dev/null 2>&1; then
            missing_packages+=("$package")
        fi
    done

    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        log_info "Installing missing packages: ${missing_packages[*]}"
        if ! apt install -y "${missing_packages[@]}"; then
            log_error "Failed to install some packages"
            return 1
        fi
        log_success "Dependencies installed successfully"
    else
        log_success "All required packages are already installed"
    fi

    # Enable and start services
    log_info "Configuring system services..."

    # Docker service
    systemctl enable docker || log_warn "Failed to enable Docker service"
    systemctl start docker || {
        log_error "Failed to start Docker service"
        return 1
    }

    # Cron service
    local cron_service="cron"
    if systemctl list-unit-files | grep -q "crond.service"; then
        cron_service="crond"
    fi

    systemctl enable "$cron_service" || log_warn "Failed to enable cron service"
    systemctl start "$cron_service" || log_warn "Failed to start cron service"

    # Add current user to docker group
    local real_user
    real_user=$(get_real_user)
    if [[ -n "$real_user" ]] && [[ "$real_user" != "root" ]]; then
        log_info "Adding user $real_user to docker group..."
        usermod -aG docker "$real_user" || log_warn "Failed to add user to docker group"
        log_info "Note: User $real_user needs to log out and back in for docker group to take effect"
    fi

    return 0
}

# --- Firewall Configuration ---
configure_firewall() {
    log_info "Configuring firewall..."

    # Check if ufw is available using library function
    if ! has_command ufw; then
        log_warn "UFW not available, skipping firewall configuration"
        return 0
    fi

    # Reset and configure UFW
    log_info "Configuring UFW firewall rules..."

    # Reset to defaults
    ufw --force reset >/dev/null 2>&1 || true

    # Default policies
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1

    # Allow SSH (Smart detection)
    local ssh_port="${SSH_PORT:-}"
    if [[ -z "$ssh_port" ]]; then
        ssh_port=$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -1)
    fi
    ssh_port="${ssh_port:-22}"

    ufw allow "$ssh_port/tcp" comment "SSH" >/dev/null 2>&1
    log_success "SSH access allowed on port $ssh_port"

    # Enable UFW
    ufw --force enable >/dev/null 2>&1
    log_success "Firewall configured and enabled with SSH access"

    log_info "Firewall status (web rules will be added next):"
    ufw status numbered | head -20

    return 0
}

# --- Directory Structure ---
setup_directories() {
    log_info "Setting up directory structure..."

    local real_user
    real_user=$(get_real_user)
    local state_dir="/var/lib/vaultwarden"

    local real_group
    real_group=$(id -g -n "$real_user") || real_group="$real_user"
    local owner="$real_user:$real_group"

    ensure_dir "$state_dir" 755 "$owner"
    ensure_dir "$state_dir/data" 700 "$owner"
    log_info "Data directory created with strict permissions (700)"

    ensure_dir "$state_dir/logs" 755 "$owner"
    ensure_dir "$state_dir/backups" 755 "$owner"
    ensure_dir "$state_dir/caddy" 755 "$owner"
    ensure_dir "$state_dir/caddy/data" 755 "$owner"
    ensure_dir "$state_dir/caddy/config" 755 "$owner"
    ensure_dir "$state_dir/ddclient" 755 "$owner"
    ensure_dir "$state_dir/ddclient/cache" 755 "$owner"

    ensure_dir "$state_dir/logs/caddy" 755 "$owner"
    ensure_dir "$state_dir/logs/vaultwarden" 755 "$owner"
    ensure_dir "$state_dir/logs/fail2ban" 755 "$owner"

    ensure_dir "$PROJECT_ROOT/secrets" 700 "$owner"
    ensure_dir "$PROJECT_ROOT/secrets/keys" 700 "$owner"
    ensure_dir "$PROJECT_ROOT/backups" 755 "$owner"
    ensure_dir "$PROJECT_ROOT/backups/db" 755 "$owner"
    ensure_dir "$PROJECT_ROOT/backups/full" 755 "$owner"
    ensure_dir "$PROJECT_ROOT/backups/emergency" 755 "$owner"
    ensure_dir "$PROJECT_ROOT/logs" 755 "$owner"

    log_success "Directory structure created with appropriate permissions"
    return 0
}

# --- Age Keys Setup ---
setup_age_keys() {
    log_info "Setting up Age encryption keys..."

    local private_key_file="$PROJECT_ROOT/secrets/keys/age-key.txt"
    local public_key_file="$PROJECT_ROOT/secrets/keys/age-public-key.txt"

    if check_age_key "$private_key_file"; then
        if [[ "$FORCE" == "true" ]]; then
            log_warn "Overwriting existing Age keys (--force specified)"
        else
            log_warn "Age keys already exist"
            read -p "Overwrite existing keys? This will make existing encrypted data inaccessible! (y/N): " overwrite_keys
            if [[ ! "$overwrite_keys" =~ ^[Yy]$ ]]; then
                log_info "Keeping existing Age keys"
                return 0
            fi
        fi
    fi

    if generate_age_keypair "$private_key_file" "$public_key_file"; then
        log_success "Age encryption keys generated"

        local real_user real_group
        real_user=$(get_real_user)
        real_group=$(id -g -n "$real_user") || real_group="$real_user"
        chown "$real_user:$real_group" "$private_key_file" "$public_key_file"

        echo ""
        log_info "Age public key (for reference):"
        cat "$public_key_file"
        echo ""
        log_warn "IMPORTANT: Backup your Age private key securely!"
        log_info "Private key location: $private_key_file"
    else
        log_error "Failed to generate Age keys"
        return 1
    fi

    return 0
}

# --- SOPS Configuration ---
setup_sops_config() {
    log_info "Setting up SOPS configuration..."

    local sops_config="$PROJECT_ROOT/.sops.yaml"
    local public_key_file="$PROJECT_ROOT/secrets/keys/age-public-key.txt"

    if [[ ! -f "$public_key_file" ]]; then
        log_error "Age public key not found: $public_key_file"
        return 1
    fi

    local public_key
    public_key=$(cat "$public_key_file")

    cat > "$sops_config" << EOF
creation_rules:
  - path_regex: secrets/.*\.yaml$
    age: '$public_key'
  - path_regex: secrets/.*\.yml$
    age: '$public_key'
EOF

    local real_user real_group
    real_user=$(get_real_user)
    real_group=$(id -g -n "$real_user") || real_group="$real_user"
    chown "$real_user:$real_group" "$sops_config"

    log_success "SOPS configuration created"
    return 0
}

# --- Environment Configuration ---
setup_environment() {
    log_info "Creating environment configuration..."

    local env_file="$PROJECT_ROOT/.env"
    local state_dir="/var/lib/vaultwarden"
    local real_user real_uid real_gid
    real_user=$(get_real_user)
    real_uid=$(id -u "$real_user")
    real_gid=$(id -g "$real_user")

    if [[ -f "$env_file" ]]; then
        if [[ "$FORCE" == "true" ]]; then
            log_warn "Overwriting existing .env file (--force specified)"
        else
            log_warn ".env file already exists"
            read -p "Overwrite existing configuration? (y/N): " overwrite_env
            if [[ ! "$overwrite_env" =~ ^[Nn]$ ]]; then
                log_info "Keeping existing .env file"
                # Still check if we need to add version pins if they are missing
            else
                # If overwriting, proceed to create new file below
                rm -f "$env_file" # Remove old file first
            fi
        fi
    fi

    # Write base configuration regardless of overwrite status initially
    cat > "$env_file" << EOF
# VaultWarden-OCI-NG Configuration
# Generated on $(date)

# ==========================================================
# CORE CONFIGURATION (REQUIRED)
# ==========================================================
DOMAIN=$DOMAIN
ADMIN_EMAIL=$ADMIN_EMAIL
COMPOSE_PROJECT_NAME=vaultwarden
PROJECT_STATE_DIR=$state_dir

# ==========================================================
# USER & PERMISSIONS (Auto-configured)
# ==========================================================
UID=$real_uid
GID=$real_gid

# ==========================================================
# HOST CONFIGURATION (Auto-detected or default)
# ==========================================================
SSH_PORT=22

# ==========================================================
# CONTAINER VERSIONS (Recommended for production stability)
# ==========================================================
# If commented/missing, docker-compose.yml defaults to 'latest' tag.
# Setup pins specific versions by default unless --use-latest is specified.

# ==========================================================
# SERVICE CONFIGURATION
# ==========================================================
VAULTWARDEN_DATA_FOLDER=$state_dir/data
VAULTWARDEN_LOG_LEVEL=info
CADDY_DATA_DIR=$state_dir/caddy
CADDY_CONFIG_DIR=./caddy
FAIL2BAN_CONFIG_DIR=./fail2ban
FAIL2BAN_LOG_LEVEL=INFO

# ==========================================================
# BACKUP CONFIGURATION
# ==========================================================
DB_BACKUP_RETENTION_DAYS=14
FULL_BACKUP_RETENTION_DAYS=30
EMERGENCY_BACKUP_RETENTION_DAYS=90
BACKUP_ENCRYPTION=age
RCLONE_REMOTE_NAME=CHANGE_ME

# ==========================================================
# NETWORK CONFIGURATION
# ==========================================================
DOCKER_NETWORK_NAME=vaultwarden_network

# ==========================================================
# CLOUDFLARE & DYNAMIC DNS (REQUIRED)
# ==========================================================
CLOUDFLARE_ZONE_ID=CHANGE_ME
DDCLIENT_HOSTNAME=$DOMAIN

# ==========================================================
# RESOURCE LIMITS (Optimized for OCI A1 Flex)
# ==========================================================
VAULTWARDEN_MEMORY_LIMIT=1g
CADDY_MEMORY_LIMIT=128m
FAIL2BAN_MEMORY_LIMIT=64m
DDCLIENT_MEMORY_LIMIT=64m

# ==========================================================
# OPTIONAL: SMTP CONFIGURATION
# ==========================================================
# SMTP_HOST=smtp.example.com
# SMTP_PORT=587
# SMTP_SECURITY=starttls
# SMTP_USERNAME=noreply@$DOMAIN
EOF

    # --- START PHASE 2 CHANGE ---
    # Add pinned versions unless --use-latest was specified
    if [[ "$USE_LATEST" != "true" ]]; then
        log_info "Pinning container versions in .env (recommended for production)"
        # Check if version section header exists, add if not
        if ! grep -q "# CONTAINER VERSIONS" "$env_file"; then
             # Insert header if missing
             sed -i '/# HOST CONFIGURATION/a \\n# ==========================================================\n# CONTAINER VERSIONS (Recommended for production stability)\n# ==========================================================\n# If commented/missing, docker-compose.yml defaults to '\''latest'\'' tag.\n# Setup pins specific versions by default unless --use-latest is specified.\n' "$env_file"
        fi
        # Add or update specific versions (use specific known-good versions here)
        # Use sed to replace or append these lines robustly
        local current_vw_version="1.30.5" # Example known good version
        local current_caddy_version="2.8.4"
        local current_f2b_version="1.1.0"
        local current_ddc_version="3.11.2"

        grep -q "^VAULTWARDEN_VERSION=" "$env_file" && sed -i "s/^VAULTWARDEN_VERSION=.*/VAULTWARDEN_VERSION=$current_vw_version/" "$env_file" || echo "VAULTWARDEN_VERSION=$current_vw_version" >> "$env_file"
        grep -q "^CADDY_VERSION=" "$env_file" && sed -i "s/^CADDY_VERSION=.*/CADDY_VERSION=$current_caddy_version/" "$env_file" || echo "CADDY_VERSION=$current_caddy_version" >> "$env_file"
        grep -q "^FAIL2BAN_VERSION=" "$env_file" && sed -i "s/^FAIL2BAN_VERSION=.*/FAIL2BAN_VERSION=$current_f2b_version/" "$env_file" || echo "FAIL2BAN_VERSION=$current_f2b_version" >> "$env_file"
        grep -q "^DDCLIENT_VERSION=" "$env_file" && sed -i "s/^DDCLIENT_VERSION=.*/DDCLIENT_VERSION=$current_ddc_version/" "$env_file" || echo "DDCLIENT_VERSION=$current_ddc_version" >> "$env_file"

    else
        log_info "Skipping version pinning in .env (--use-latest specified)"
        # Optionally remove existing version pins if force mode? For now, just don't add them.
    fi
    # --- END PHASE 2 CHANGE ---

    secure_file "$env_file" 600 || { log_error "Failed to set secure permissions on .env file"; return 1; }

    local real_group
    real_group=$(id -g -n "$real_user") || real_group="$real_user"
    chown "$real_user:$real_group" "$env_file"

    log_success "Environment configuration created/updated"
    return 0
}

# --- Initial Secrets ---
setup_initial_secrets() {
    log_info "Setting up initial secrets..."

    local secrets_file="$PROJECT_ROOT/secrets/secrets.yaml"

    if [[ -f "$secrets_file" ]]; then
        if [[ "$FORCE" == "true" ]]; then
            log_warn "Overwriting existing secrets (--force specified)"
        else
            log_warn "Secrets file already exists"
            log_info "Use ./edit-secrets.sh to modify secrets"
            return 0
        fi
    fi

    local admin_token backup_pass
    admin_token=$(generate_hex_string 32)
    backup_pass=$(generate_secure_string 32)

    cat > "$secrets_file" << EOF
# VaultWarden-OCI-NG Secrets
# Generated on $(date)
# Edit with: ./edit-secrets.sh

admin_token: $admin_token
admin_basic_auth_hash: CHANGE_ME_BCRYPT_HASH
smtp_password: CHANGE_ME_SMTP_PASSWORD
backup_passphrase: $backup_pass
push_installation_id: ""
push_installation_key: ""
ddclient_api_token: CHANGE_ME_DDCLIENT_API_TOKEN
fail2ban_api_token: CHANGE_ME_FAIL2BAN_API_TOKEN
EOF

    if sops_encrypt "$secrets_file"; then
        log_success "Initial secrets created and encrypted"

        secure_file "$secrets_file" 600 || { log_error "Failed to set secure permissions on secrets file"; return 1; }

        local real_user real_group
        real_user=$(get_real_user)
        real_group=$(id -g -n "$real_user") || real_group="$real_user"
        chown "$real_user:$real_group" "$secrets_file"

        log_warn "IMPORTANT: Update placeholder values in secrets:"
        log_info "  Run: ./edit-secrets.sh"
        log_info "  Update admin_basic_auth_hash, ddclient_api_token, fail2ban_api_token"
        log_info "  Configure smtp_password if using email"
    else
        log_error "Failed to encrypt secrets file"
        return 1
    fi

    return 0
}

# --- Docker Compose Validation ---
validate_docker_setup() {
    log_info "Validating Docker setup..."

    if ! check_docker_available; then
        log_error "Docker daemon not accessible"
        log_info "Try: sudo systemctl restart docker"
        return 1
    fi

    if ! check_compose_available; then
        log_error "Docker Compose not available"
        return 1
    fi

    if [[ -f "$PROJECT_ROOT/docker-compose.yml" ]]; then
        load_env_file "$PROJECT_ROOT/.env" || log_warn "Cannot load .env for validation"
        if validate_compose_file "$PROJECT_ROOT/docker-compose.yml"; then
            log_success "Docker Compose configuration is valid"
        else
            log_error "Docker Compose configuration is invalid"
            return 1
        fi
    else
        log_warn "docker-compose.yml not found (will be needed for startup)"
    fi

    return 0
}

# --- Script Permissions ---
setup_script_permissions() {
    log_info "Setting up script permissions..."

    local scripts=("startup.sh" "health.sh" "backup.sh" "restore.sh" "edit-secrets.sh"
                   "update.sh" "maintenance.sh" "cron-setup.sh" "update-cloudflare-ips.sh")
    local real_user real_group owner
    real_user=$(get_real_user)
    real_group=$(id -g -n "$real_user") || real_group="$real_user"
    owner="$real_user:$real_group"

    for script in "${scripts[@]}"; do
        if [[ -f "$PROJECT_ROOT/$script" ]]; then
            chmod +x "$PROJECT_ROOT/$script"
            chown "$owner" "$PROJECT_ROOT/$script"
            log_success "Made $script executable"
        else
            log_warn "Script not found: $script"
        fi
    done

    if [[ -d "$PROJECT_ROOT/lib" ]]; then
        chmod -R 644 "$PROJECT_ROOT/lib"/*.sh
        chmod +x "$PROJECT_ROOT/lib"
        chown -R "$owner" "$PROJECT_ROOT/lib"
        log_success "Library permissions set"
    fi

    return 0
}

# --- Final Validation ---
run_final_validation() {
    log_info "Running final validation..."

    local validation_errors=0

    local age_key_file="$PROJECT_ROOT/secrets/keys/age-key.txt"
    if [[ -f "$age_key_file" ]]; then
        local perms
        perms=$(stat -c "%a" "$age_key_file" 2>/dev/null)
        if [[ "$perms" == "600" ]]; then
             log_success "Age encryption key is accessible and secure"
        else
             log_error "Age encryption key permissions are incorrect (should be 600)"
             ((validation_errors++))
        fi
    else
        log_error "Age encryption key validation failed (file missing)"
        ((validation_errors++))
    fi

    if [[ -f ".sops.yaml" ]]; then
        log_success "SOPS configuration exists"
    else
        log_error "SOPS configuration missing"
        ((validation_errors++))
    fi

    if [[ -f ".env" ]]; then
        log_success "Environment configuration exists"
    else
        log_error "Environment configuration missing"
        ((validation_errors++))
    fi

    local secrets_file="secrets/secrets.yaml"
    if [[ -f "$secrets_file" ]] && is_sops_encrypted "$secrets_file"; then
        log_success "Encrypted secrets file exists"
    else
        log_error "Secrets file missing or not encrypted"
        ((validation_errors++))
    fi

    if test_connectivity; then
        log_success "Network connectivity available"
    else
        log_warn "Network connectivity issues detected"
    fi

    if [[ $validation_errors -eq 0 ]]; then
        log_success "All validation checks passed"
        return 0
    else
        log_error "$validation_errors validation errors found"
        return 1
    fi
}

# --- Main Execution ---
main() {
    log_header "VaultWarden-OCI-NG Complete Setup"

    validate_setup_environment || exit 1

    if [[ -z "$DOMAIN" || -z "$ADMIN_EMAIL" ]]; then
        if [[ "$AUTO_MODE" == "true" ]]; then
            log_error "Auto mode requires --domain and --email"
            exit 1
        fi
        interactive_setup
    fi

    load_env_file 2>/dev/null || log_info "No existing .env file found"

    echo ""
    log_info "Starting system setup..."

    install_dependencies || exit 1
    configure_firewall || exit 1
    setup_directories || exit 1
    setup_age_keys || exit 1
    setup_sops_config || exit 1
    setup_environment || exit 1 # Updated function call
    setup_initial_secrets || exit 1
    validate_docker_setup || exit 1
    setup_script_permissions || exit 1

    log_info "Populating firewall rules for Cloudflare..."
    if ./update-cloudflare-ips.sh; then
        log_success "Firewall rules for Cloudflare IPs applied"
    else
        log_error "Failed to apply Cloudflare IP firewall rules"
        log_warn "Your firewall may be blocking web traffic. Run './update-cloudflare-ips.sh' manually."
    fi

    echo ""
    log_info "Running final validation..."
    run_final_validation || {
        log_error "Setup completed with validation errors"
        exit 1
    }

    local real_user
    real_user=$(get_real_user)

    echo ""
    log_success "🎉 VaultWarden-OCI-NG setup completed successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Update secrets: ./edit-secrets.sh"
    echo "     • CRITICAL: Set admin_basic_auth_hash, ddclient_api_token, fail2ban_api_token"
    echo "  2. Review configuration: nano .env"
    echo "     • CRITICAL: Set CLOUDFLARE_ZONE_ID, RCLONE_REMOTE_NAME"
    echo "     • NOTE: Set SSH_PORT if you use a custom port"
    # --- START PHASE 2 CHANGE ---
    if [[ "$USE_LATEST" == "true" ]]; then
        echo "     • INFO: Container versions will default to 'latest'. Edit .env to pin specific versions for production."
    else
        echo "     • INFO: Container versions are pinned in .env. Edit to change versions or use 'latest'."
    fi
    # --- END PHASE 2 CHANGE ---
    echo "  3. Configure Rclone: rclone config (for the user '$real_user')"
    echo "  4. Start services: ./startup.sh"
    echo "  5. Setup automation: sudo ./cron-setup.sh"
    echo "  6. Run health check: ./health.sh --comprehensive"
    echo ""
    echo "Your VaultWarden will be available at: https://$DOMAIN"
    echo "Admin panel: https://$DOMAIN/admin (protected by basic auth)"
    echo ""
    log_warn "IMPORTANT: Ensure all 'CHANGE_ME' values are updated!"
    log_info "Setup completed on $(date)"
}

main "$@"
