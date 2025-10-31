#!/usr/bin/env bash
# setup.sh - VaultWarden-OCI Setup Script with Caddy-Cloudflare Integration
# UPDATED: Now uses template-based approach instead of heredoc file generation

set -euo pipefail

# --- Project Root Resolution & Library Sourcing ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"
source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"
source "lib/docker.sh"

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
VaultWarden-OCI Setup Tool - Enhanced for Caddy-Cloudflare

USAGE:
    sudo ./setup.sh

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

NOTES:
    - This setup configures caddy-cloudflare for DNS-01 ACME challenges
    - Separate Cloudflare API tokens needed for DNS and Firewall operations
    - VaultWarden admin uses Argon2 hash, Caddy basic_auth uses bcrypt
    - Installs 'unattended-upgrades' for automatic host OS security patches.
    - Uses template files (.example) for easier maintenance
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

if ! validate_domain "$DOMAIN"; then
    log_error "Invalid domain format: $DOMAIN"
    exit 1
fi

if ! validate_email "$ADMIN_EMAIL"; then
    log_error "Invalid email format: $ADMIN_EMAIL"
    exit 1
fi

# --- System Functions ---

install_dependencies() {
    if [[ "$SKIP_DEPS" == "true" ]]; then
        log_info "Skipping dependency installation (--skip-deps specified)."
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info " Would install system dependencies"
        return 0
    fi

    log_info "Installing system dependencies..."
    apt-get update -qq

    local basic_packages=("age" "make" "nano" "rclone" "sqlite3" "jq" "mailutils" "ufw" "curl" "wget" "unzip" "git" "gpg" "coreutils" "bc")
    export DEBIAN_FRONTEND=noninteractive
    
    if ! apt-get install -y "${basic_packages[@]}"; then
        log_error "Failed to install basic dependencies."
        return 1
    fi

    # --- Add unattended-upgrades ---
    log_info "Installing and enabling automatic security updates (unattended-upgrades)..."
    if ! apt-get install -y unattended-upgrades; then
        log_warn "Could not install 'unattended-upgrades'. Host OS security patches will be manual."
    else
        # Reconfigure to enable security updates automatically
        echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
        dpkg-reconfigure -f noninteractive unattended-upgrades
        log_success "Host OS automatic security updates enabled."
    fi

    # Install Docker if not present
    if ! has_command docker; then
        log_info "Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        systemctl enable docker
        systemctl start docker
        
        # Add user to docker group
        local real_user
        real_user=$(get_real_user)
        usermod -aG docker "$real_user"
        log_success "Docker installed. User $real_user added to docker group."
    fi

    # Install Docker Compose if not present
    if ! docker compose version >/dev/null 2>&1; then
        log_info "Installing Docker Compose plugin..."
        apt-get install -y docker-compose-plugin
    fi

    # Install SOPS if not present
    if ! has_command sops; then
        log_info "Installing SOPS..."
        local sops_version="v3.8.1"
        local arch
        arch=$(dpkg --print-architecture)
        case "$arch" in
            amd64) arch="amd64" ;;
            arm64) arch="arm64" ;;
            armhf) arch="arm" ;;
            *) log_error "Unsupported architecture: $arch"; return 1 ;;
        esac
        
        wget -q "https://github.com/mozilla/sops/releases/download/${sops_version}/sops-${sops_version}.linux.${arch}" -O /usr/local/bin/sops
        chmod +x /usr/local/bin/sops
    fi

    log_success "Dependencies installed."
    return 0
}

verify_dependencies() {
    log_info "Verifying dependencies..."
    
    local required_commands=("age" "sops" "docker" "jq" "sqlite3" "ufw" "curl")
    if ! require_commands "${required_commands[@]}"; then
        return 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        log_error "Docker Compose plugin not available"
        return 1
    fi

    log_success "All dependencies verified."
    return 0
}

setup_user_permissions() {
    log_info "Setting up user permissions..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info " Would configure user permissions and groups"
        return 0
    fi

    local real_user
    real_user=$(get_real_user)
    
    # Ensure user is in docker group
    if ! groups "$real_user" | grep -q docker; then
        usermod -aG docker "$real_user"
        log_info "Added $real_user to docker group"
    fi

    # Set proper ownership for project directory
    chown -R "$real_user:$real_user" "$PROJECT_ROOT"
    
    log_success "User permissions configured."
    return 0
}

# Enhanced firewall setup with better error handling
setup_firewall() {
    log_info "Configuring Cloudflare-only UFW firewall..."
    
    ufw --force reset >/dev/null
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    
    # SSH on custom port
    local ssh_port="${SSH_PORT:-2222}"
    ufw allow "$ssh_port/tcp" comment "SSH-Custom" >/dev/null
    
    # Fetch current Cloudflare IP ranges dynamically
    log_info "Fetching current Cloudflare IP ranges..."
    local cf_ipv4_file="/tmp/cf_ipv4_ranges.txt"
    local cf_ipv6_file="/tmp/cf_ipv6_ranges.txt"
    
    if curl -sf --max-time 10 "https://www.cloudflare.com/ips-v4" -o "$cf_ipv4_file" && \
       curl -sf --max-time 10 "https://www.cloudflare.com/ips-v6" -o "$cf_ipv6_file"; then
        
        # Apply IPv4 ranges
        while IFS= read -r range; do
            if [[ -n "$range" ]]; then
                ufw allow from "$range" to any port 80,443 comment "CF-IPv4" >/dev/null
            fi
        done < "$cf_ipv4_file"
        
        # Apply IPv6 ranges  
        while IFS= read -r range; do
            if [[ -n "$range" ]]; then
                ufw allow from "$range" to any port 80,443 comment "CF-IPv6" >/dev/null
            fi
        done < "$cf_ipv6_file"
        
        rm -f "$cf_ipv4_file" "$cf_ipv6_file"
        log_success "Applied Cloudflare IP ranges successfully"
        
    else
        log_error "⚠️  CRITICAL WARNING: Failed to fetch Cloudflare IP ranges from API"
        log_error "    This means your firewall will block ALL web traffic!"
        log_error "    Your server may become inaccessible after firewall activation."
        echo ""
        echo "OPTIONS:"
        echo "  1. Check internet connectivity and try again"
        echo "  2. Use manual Cloudflare IP ranges (see documentation)"
        echo "  3. Skip firewall setup (NOT recommended for production)"
        echo ""
        
        if [[ "$AUTO_MODE" != "true" ]]; then
            read -p "Continue anyway? [y/N]: " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "Setup aborted by user. Fix connectivity and re-run."
                exit 1
            fi
        fi
        
        log_warn "Proceeding with basic firewall (SSH only) - web access will be blocked"
        log_warn "You MUST manually configure Cloudflare IP ranges after setup"
    fi
    
    echo "y" | ufw enable >/dev/null
    log_success "Firewall configured and enabled"
}

# Template-based environment file creation
create_env_file() {
    log_info "Creating environment configuration file (.env)..."
    
    if [[ "$DRY_RUN" == "true" ]]; then 
        log_info " Would create .env from template"
        return 0
    fi
    
    local env_file="$PROJECT_ROOT/.env"
    local env_template="$PROJECT_ROOT/.env.example"
    
    if [[ -f "$env_file" ]] && [[ "$FORCE" != "true" ]]; then
        log_info ".env file already exists, skipping creation."
        return 0
    fi
    
    if [[ ! -f "$env_template" ]]; then
        log_error ".env.example template not found"
        return 1
    fi
    
    # Copy template
    cp "$env_template" "$env_file"
    
    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n $real_user)
    
    # Populate template values using sed
    sed -i "s/DOMAIN=.*/DOMAIN=$DOMAIN/" "$env_file"
    sed -i "s/ADMIN_EMAIL=.*/ADMIN_EMAIL=$ADMIN_EMAIL/" "$env_file" 
    sed -i "s/PUID=.*/PUID=$(id -u $real_user)/" "$env_file"
    sed -i "s/PGID=.*/PGID=$(id -g $real_user)/" "$env_file"
    
    # Update SMTP_FROM with actual domain
    sed -i "s/SMTP_FROM=.*/SMTP_FROM=noreply@$DOMAIN/" "$env_file"
    
    # Set version pins if not using latest
    if [[ "$USE_LATEST" != "true" ]]; then
        sed -i 's/#\(VAULTWARDEN_VERSION=.*\)/\1/' "$env_file"
        sed -i 's/#\(CADDY_VERSION=.*\)/\1/' "$env_file"
        sed -i 's/#\(FAIL2BAN_VERSION=.*\)/\1/' "$env_file"
        log_info "Enabled pinned container versions for production stability"
    else
        log_info "Using latest container versions (development mode)"
    fi
    
    chown "$real_user:$real_group" "$env_file"
    chmod 644 "$env_file"
    
    log_success "Environment file created from template: $env_file"
    
    # Show what needs manual configuration
    log_warn "MANUAL CONFIGURATION REQUIRED:"
    log_info "  1. Edit .env and set CLOUDFLARE_ZONE_ID"
    log_info "  2. Configure SMTP settings if using email notifications"
    log_info "  3. Update RCLONE_REMOTE_NAME if using offsite backups"
    
    return 0
}

setup_directories() {
    log_info "Setting up project directories..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info " Would create project directories"
        return 0
    fi

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n $real_user)
    
    # Core directories
    local dirs=(
        "secrets/keys"
        "secrets/.docker_secrets"
        "caddy"
        "fail2ban/jail.d"
        "fail2ban/filter.d"
        "fail2ban/action.d"
        "backups"
        "logs"
    )

    for dir in "${dirs[@]}"; do
        ensure_dir "$dir" 755
        chown "$real_user:$real_group" "$dir"
    done

    # Secure secrets directories
    chmod 700 "secrets"
    chmod 700 "secrets/keys"
    chmod 700 "secrets/.docker_secrets"

    log_success "Project directories created."
    return 0
}

generate_age_keys() {
    log_info "Generating Age encryption keys..."
    
    local age_key_file="secrets/keys/age-key.txt"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info " Would generate Age encryption keys"
        return 0
    fi

    if [[ -f "$age_key_file" ]] && [[ "$FORCE" != "true" ]]; then
        log_info "Age key already exists, skipping generation."
        return 0
    fi
    
    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n $real_user)

    age-keygen -o "$age_key_file"
    chmod 600 "$age_key_file"
    chown "$real_user:$real_group" "$age_key_file"
    
    log_success "Age encryption keys generated: $age_key_file"
    return 0
}

create_sops_config() {
    log_info "Creating SOPS configuration..."
    
    local sops_config=".sops.yaml"
    local age_key_file="secrets/keys/age-key.txt"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info " Would create SOPS configuration"
        return 0
    fi

    if [[ ! -f "$age_key_file" ]]; then
        log_error "Age key file not found: $age_key_file"
        return 1
    fi
    
    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n $real_user)

    local age_public_key
    age_public_key=$(age-keygen -y "$age_key_file")

    cat > "$sops_config" << EOF
creation_rules:
  - path_regex: secrets/secrets\.yaml$
    age: $age_public_key
EOF

    chown "$real_user:$real_group" "$sops_config"
    
    log_success "SOPS configuration created: $sops_config"
    return 0
}

create_secrets_template() {
    log_info "Creating secrets template..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info " Would create encrypted secrets template"
        return 0
    fi

    local secrets_file="secrets/secrets.yaml"
    local age_key_file="secrets/keys/age-key.txt"

    if [[ -f "$secrets_file" ]] && [[ "$FORCE" != "true" ]]; then
        log_info "Secrets file already exists, skipping creation."
        return 0
    fi
    
    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n $real_user)

    # Generate secure defaults
    local admin_token backup_pass
    admin_token=$(generate_secure_string 32)
    backup_pass=$(generate_secure_string 32)

    # Create unencrypted template
    cat > "$secrets_file" << EOF
# VaultWarden Secrets Configuration - Enhanced for Caddy-Cloudflare
# IMPORTANT: VaultWarden admin uses Argon2, Caddy basic_auth uses bcrypt

# VaultWarden admin token (plain text - will be hashed to Argon2 by VaultWarden)
admin_token: $admin_token

# Caddy basic_auth hash for /admin endpoint (bcrypt format)
# Generate with: docker run --rm -it ghcr.io/caddybuilds/caddy-cloudflare:latest caddy hash-password
admin_basic_auth_hash: CHANGE_ME_BCRYPT_HASH

# SMTP password for email notifications
smtp_password: CHANGE_ME_SMTP_PASSWORD

# Backup encryption passphrase
backup_passphrase: $backup_pass

# Push notifications (optional - get from bitwarden.com/host)
push_installation_id: CHANGE_ME_OR_LEAVE_EMPTY
push_installation_key: CHANGE_ME_OR_LEAVE_EMPTY

# Cloudflare DNS API token for caddy-cloudflare (DNS-01 ACME challenges)
# Permissions: Zone:DNS:Edit + Zone:Zone:Read
caddy_cloudflare_dns_token: CHANGE_ME_DNS_TOKEN

# Cloudflare Firewall API token for fail2ban IP blocking
# Permissions: Zone:Firewall Services:Edit  
fail2ban_cloudflare_firewall_token: CHANGE_ME_FIREWALL_TOKEN
EOF

    # Encrypt with SOPS
    export SOPS_AGE_KEY_FILE="$PROJECT_ROOT/$age_key_file"
    
    if sops --input-type yaml --encrypt --in-place "$secrets_file"; then
        log_success "Secrets template encrypted successfully"
        secure_file "$secrets_file" 600
        chown "$real_user:$real_group" "$secrets_file"
    else
        log_error "Failed to encrypt secrets file"
        return 1
    fi

    log_warn "IMPORTANT: Update the placeholder values:"
    log_info "  1. Run: ./edit-secrets.sh"
    log_info "  2. Generate bcrypt hash for admin_basic_auth_hash"
    log_info "  3. Add Cloudflare DNS API token"
    log_info "  4. Add Cloudflare Firewall API token"
    log_info "  5. Configure SMTP password if using email"

    return 0
}

# Template-based docker compose creation
create_docker_compose() {
    log_info "Setting up Docker Compose configuration..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info " Would copy and validate docker-compose.yml from template"
        return 0
    fi
    
    local compose_file="$PROJECT_ROOT/docker-compose.yml"
    local compose_template="$PROJECT_ROOT/docker-compose.yml.example"
    
    if [[ -f "$compose_file" ]] && [[ "$FORCE" != "true" ]]; then
        log_info "docker-compose.yml already exists, skipping creation."
        # Still validate existing file
        if docker compose config >/dev/null 2>&1; then
            log_success "Existing docker-compose.yml validated successfully"
        else
            log_warn "Existing docker-compose.yml has validation issues"
        fi
        return 0
    fi
    
    if [[ ! -f "$compose_template" ]]; then
        log_error "docker-compose.yml.example template not found"
        return 1
    fi
    
    # Copy template
    cp "$compose_template" "$compose_file"
    
    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n $real_user)
    
    chown "$real_user:$real_group" "$compose_file"
    chmod 644 "$compose_file"
    
    # Validate the compose file
    if docker compose config >/dev/null 2>&1; then
        log_success "Docker Compose configuration created and validated"
    else
        log_error "Docker Compose configuration has validation errors"
        log_info "Check syntax with: docker compose config"
        return 1
    fi
    
    return 0
}

set_script_permissions() {
    log_info "Setting script permissions..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info " Would set executable permissions on scripts"
        return 0
    fi
    
    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n $real_user)

    local scripts=(
        "setup.sh"
        "edit-secrets.sh"
        "health.sh"
        "update.sh"
        "backup.sh"
        "restore.sh"
        "startup.sh"
        "maintenance.sh"
        "cron-setup.sh"
        "create-breakglass-admin.sh"
        "db-maint.sh"
    )

    for script in "${scripts[@]}"; do
        if [[ -f "$script" ]]; then
            chmod +x "$script"
            chown "$real_user:$real_group" "$script"
        fi
    done
    
    find "lib" -name "*.sh" -exec chmod +x {} \;
    find "lib" -name "*.sh" -exec chown "$real_user:$real_group" {} \;

    log_success "Script permissions set."
    return 0
}

# --- Main Execution ---
main() {
    log_header "VaultWarden-OCI Setup - Template-Based Configuration"
    
    if [[ -z "$DOMAIN" ]] || [[ -z "$ADMIN_EMAIL" ]]; then 
        log_error "Domain and Email are required."
        show_help
        exit 1
    fi

    # --- PHASE 1: PRE-FLIGHT CHECKS ---
    log_info "=== Phase 1: Pre-flight System Checks ==="
    if ! is_root; then 
        log_error "This script must be run as root."
        exit 1
    fi
    log_success "Pre-flight checks passed."

    # --- PHASE 2: DEPENDENCY INSTALLATION ---
    log_info "=== Phase 2: Installing Dependencies ==="
    if ! install_dependencies; then
        log_error "Dependency installation failed. Please review errors and re-run."
        exit 1
    fi
    if ! verify_dependencies; then
        log_error "Dependency verification failed."
        exit 1
    fi
    log_success "All dependencies installed and verified."

    # --- PHASE 3: CONFIGURATION GENERATION ---
    log_info "=== Phase 3: Generating Project Configuration ==="
    
    # Fixed: Removed create_caddy_config call since Caddyfile stays as static file
    # Fixed: Updated function call order for template-based approach
    if ! setup_user_permissions; then
        log_error "Failed to setup user permissions"
        exit 1
    fi
    
    if ! create_env_file; then
        log_error "Failed to create .env file"
        exit 1
    fi
    
    if ! create_docker_compose; then
        log_error "Failed to setup docker-compose.yml"
        exit 1
    fi
    
    if ! setup_directories; then
        log_error "Failed to create directories"
        exit 1
    fi
    
    if ! generate_age_keys; then
        log_error "Failed to generate encryption keys"
        exit 1
    fi
    
    if ! create_sops_config; then
        log_error "Failed to create SOPS configuration"
        exit 1
    fi
    
    if ! create_secrets_template; then
        log_error "Failed to create secrets template"
        exit 1
    fi
    
    if ! set_script_permissions; then
        log_error "Failed to set script permissions"
        exit 1
    fi
    
    log_success "Project configuration generated successfully."

    # --- PHASE 4: SYSTEM STATE ACTIVATION ---
    log_info "=== Phase 4: Activating System State ==="
    if ! setup_firewall; then
        log_error "Firewall setup failed. The system is NOT secured."
        exit 1
    fi
    log_success "System state activated successfully."

    # --- FINAL SUMMARY ---
    log_header "Setup Complete - Template-Based Configuration"
    echo "Your VaultWarden instance is configured with:"
    echo ""
    echo "✅ Template-Based Configuration:"
    echo "   - docker-compose.yml copied from docker-compose.yml.example"  
    echo "   - .env file populated from .env.example template"
    echo "   - Easy maintenance via template files"
    echo ""
    echo "✅ Caddy-Cloudflare Integration:"
    echo "   - DNS-01 ACME challenges for SSL certificates"  
    echo "   - Automatic Cloudflare IP range management"
    echo "   - Separate DNS and Firewall API tokens"
    echo ""
    echo "✅ Security Features:"
    echo "   - VaultWarden admin: Argon2 hash (auto-generated)"
    echo "   - Caddy basic_auth: bcrypt hash (needs setup)"
    echo "   - SOPS + Age encrypted secrets"
    echo "   - UFW firewall configured"
    echo "   - Host OS automatic security updates enabled (unattended-upgrades)"
    echo ""
    echo "✅ Performance:"
    echo "   - CPU limits tuned for 1 OCPU (0.8 total limit, 0.2 headroom)"
    echo ""
    echo "⚠️  REQUIRED NEXT STEPS:"
    echo "   1. Configure secrets: ./edit-secrets.sh"
    echo "      - Generate bcrypt hash for admin_basic_auth_hash"
    echo "      - Add Cloudflare DNS API token"
    echo "      - Add Cloudflare Firewall API token"
    echo "   2. Update .env file: nano .env"
    echo "      - Set CLOUDFLARE_ZONE_ID"
    echo "   3. Start services: make up"
    echo "   4. Setup automation: sudo ./cron-setup.sh --install"
    echo "   5. Create emergency access: make breakglass-create"
    echo ""
    echo "📚 Important Notes:"
    echo "   - VaultWarden admin token: Plain text -> Argon2 (automatic)"
    echo "   - Caddy basic_auth: Must use bcrypt hash from 'caddy hash-password'"
    echo "   - DNS token: Zone:DNS:Edit + Zone:Zone:Read permissions"
    echo "   - Firewall token: Zone:Firewall Services:Edit permissions"
    echo "   - Template files (.example) are your source of truth for maintenance"
    echo ""
    echo "🔐 Security: Your secrets are encrypted with Age + SOPS"
    echo "🌐 Domain: https://$DOMAIN"
    echo "📧 Admin: $ADMIN_EMAIL"
}

main "$@"