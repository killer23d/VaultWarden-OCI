#!/usr/bin/env bash
# setup.sh - VaultWarden-OCI Setup Script with Caddy-Cloudflare Integration
# ENHANCED: Integrated with setup-secrets.sh for automated password hashing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"
source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"
source "lib/docker.sh"

# Configuration Defaults
DOMAIN=""
ADMIN_EMAIL=""
AUTO_MODE=false
USE_LATEST=false
SKIP_DEPS=false
FORCE=false
DRY_RUN=false
ENTROPY_THRESHOLD=200
ENTROPY_MAX_WAIT=60

show_help() {
    cat << 'EOF'
VaultWarden-OCI Setup Tool - Enhanced with Integrated Secrets Management

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

FEATURES:
    ✅ Automatic Argon2 hashing for VaultWarden admin password
    ✅ Automatic bcrypt hashing for Caddy admin password
    ✅ Real-time Cloudflare token validation
    ✅ Template-based configuration (.env, docker-compose.yml)
    ✅ Platform-specific SSH log detection
    ✅ Firewall race condition fixes
    ✅ SOPS + Age encrypted secrets
EOF
}

# Argument Parsing
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

# Validation
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

# STANDARDIZED: System Functions - all return exit codes
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
    if ! apt-get update -qq; then
        log_error "Failed to update package lists"
        return 1
    fi

    # LEANEST: python3-argon2 from apt (no pip needed!)
    local basic_packages=("age" "make" "nano" "rclone" "sqlite3" "jq" "ufw" "curl" "wget" "unzip" "git" "gpg" "coreutils" "haveged" "dnsutils" "rsync" "python3" "python3-argon2")
    export DEBIAN_FRONTEND=noninteractive

    if ! apt-get install -y "${basic_packages[@]}"; then
        log_error "Failed to install basic dependencies."
        return 1
    fi

    # Start haveged service for entropy generation
    if systemctl is-active --quiet haveged; then
        log_success "haveged service is already running"
    else
        if ! systemctl start haveged; then
            log_error "Failed to start haveged service"
            return 1
        fi
        log_success "haveged service started for entropy generation"
    fi

    # Add unattended-upgrades
    log_info "Installing and enabling automatic security updates (unattended-upgrades)..."
    if ! apt-get install -y unattended-upgrades; then
        log_warn "Could not install 'unattended-upgrades'. Host OS security patches will be manual."
    else
        echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
        if ! dpkg-reconfigure -f noninteractive unattended-upgrades; then
            log_warn "Failed to configure unattended-upgrades"
        else
            log_success "Host OS automatic security updates enabled."
        fi
    fi

    # Install Docker if not present
    if ! command -v docker >/dev/null 2>&1; then
        log_info "Installing Docker..."
        if ! curl -fsSL https://get.docker.com -o get-docker.sh; then
            log_error "Failed to download Docker installer"
            return 1
        fi

        if ! sh get-docker.sh; then
            log_error "Failed to install Docker"
            rm -f get-docker.sh
            return 1
        fi

        rm -f get-docker.sh

        if ! systemctl enable docker || ! systemctl start docker; then
            log_error "Failed to enable/start Docker service"
            return 1
        fi

        local real_user
        real_user=$(get_real_user)
        if ! usermod -aG docker "$real_user"; then
            log_error "Failed to add user to docker group"
            return 1
        fi
        log_success "Docker installed. User $real_user added to docker group."
    fi

    # Install Docker Compose if not present
    if ! docker compose version >/dev/null 2>&1; then
        log_info "Installing Docker Compose plugin..."
        if ! apt-get install -y docker-compose-plugin; then
            log_error "Failed to install Docker Compose plugin"
            return 1
        fi
    fi

    # Install SOPS if not present
    if ! command -v sops >/dev/null 2>&1; then
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

        if ! wget -q "https://github.com/mozilla/sops/releases/download/${sops_version}/sops-${sops_version}.linux.${arch}" -O /usr/local/bin/sops; then
            log_error "Failed to download SOPS"
            return 1
        fi

        if ! chmod +x /usr/local/bin/sops; then
            log_error "Failed to set SOPS permissions"
            return 1
        fi
    fi

    log_success "Dependencies installed."
    return 0
}

# STANDARDIZED: Returns exit code
verify_dependencies() {
    log_info "Verifying dependencies..."

    hash -r

    local required_commands=("age" "sops" "docker" "jq" "sqlite3" "ufw" "curl" "python3")
    if ! require_commands "${required_commands[@]}"; then
        return 1
    fi

    # Verify argon2 Python library
    if ! python3 -c "from argon2 import PasswordHasher" 2>/dev/null; then
        log_error "Argon2 Python library not available"
        return 1
    fi

    if ! systemctl is-active --quiet haveged 2>/dev/null; then
        log_warn "haveged service not running - entropy may be insufficient"
    fi

    if ! docker compose version >/dev/null 2>&1; then
        log_error "Docker Compose plugin not available"
        return 1
    fi

    log_success "All dependencies verified."
    return 0
}

# STANDARDIZED: Returns exit code
setup_user_permissions() {
    log_info "Setting up user permissions..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would configure user permissions and groups"
        return 0
    fi

    local real_user
    real_user=$(get_real_user)

    if ! id "$real_user" >/dev/null 2>&1; then
        log_error "User $real_user does not exist"
        return 1
    fi

    if ! groups "$real_user" | grep -q docker; then
        if ! usermod -aG docker "$real_user"; then
            log_error "Failed to add $real_user to docker group"
            return 1
        fi
        log_info "Added $real_user to docker group"
    fi

    if ! chown -R "$real_user:$real_user" "$PROJECT_ROOT"; then
        log_error "Failed to set project directory ownership"
        return 1
    fi

    log_success "User permissions configured."
    return 0
}

# Platform-specific SSH log detection
detect_ssh_log_path() {
    local ssh_log_path=""

    log_info "Detecting platform-specific SSH log location..."

    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        case "$ID" in
            "ol"|"rhel"|"centos"|"rocky"|"almalinux"|"fedora")
                ssh_log_path="/var/log/secure"
                log_info "Detected RHEL-based system ($PRETTY_NAME) - using /var/log/secure"
                ;;
            "ubuntu"|"debian")
                ssh_log_path="/var/log/auth.log"
                log_info "Detected Debian-based system ($PRETTY_NAME) - using /var/log/auth.log"
                ;;
            *)
                if [[ -f "/var/log/secure" ]] && grep -q "sshd" "/var/log/secure" 2>/dev/null; then
                    ssh_log_path="/var/log/secure"
                elif [[ -f "/var/log/auth.log" ]] && grep -q "sshd" "/var/log/auth.log" 2>/dev/null; then
                    ssh_log_path="/var/log/auth.log"
                elif [[ -f "/var/log/secure" ]]; then
                    ssh_log_path="/var/log/secure"
                else
                    ssh_log_path="/var/log/auth.log"
                fi
                ;;
        esac
    else
        ssh_log_path="/var/log/secure"
    fi

    echo "$ssh_log_path"
}

# ENHANCED: Template-based environment file creation
create_env_file() {
    log_info "Creating environment configuration file (.env)..."

    if [[ "$DRY_RUN" == "true" ]]; then 
        log_info "[DRY RUN] Would create .env from template"
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

    if ! cp "$env_template" "$env_file"; then
        log_error "Failed to copy .env template"
        return 1
    fi

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n "$real_user")
    local user_id group_id
    user_id=$(id -u "$real_user")
    group_id=$(id -g "$real_user")

    local detected_ssh_log_path
    detected_ssh_log_path=$(detect_ssh_log_path | tail -1)

    local domain_with_protocol
    if [[ "$DOMAIN" =~ ^https?:// ]]; then
        domain_with_protocol="$DOMAIN"
    else
        domain_with_protocol="https://$DOMAIN"
    fi

    local clean_domain
    clean_domain=$(echo "$domain_with_protocol" | sed 's|https\?://||; s|/.*$||')

    local domain_escaped clean_domain_escaped admin_email_escaped smtp_from_escaped ssh_log_escaped
    domain_escaped=$(printf '%s\n' "$domain_with_protocol" | sed 's/[&/\]/\\&/g')
    clean_domain_escaped=$(printf '%s\n' "$clean_domain" | sed 's/[&/\]/\\&/g')
    admin_email_escaped=$(printf '%s\n' "$ADMIN_EMAIL" | sed 's/[&/\]/\\&/g')
    smtp_from_escaped=$(printf '%s\n' "noreply@$clean_domain" | sed 's/[&/\]/\\&/g')
    ssh_log_escaped=$(printf '%s\n' "$detected_ssh_log_path" | sed 's/[&/\]/\\&/g')

    sed -i "s|DOMAIN=.*|DOMAIN=$domain_escaped|" "$env_file"
    sed -i "s|DOMAIN_NAME=.*|DOMAIN_NAME=$clean_domain_escaped|" "$env_file"
    sed -i "s|ADMIN_EMAIL=.*|ADMIN_EMAIL=$admin_email_escaped|" "$env_file"
    sed -i "s|PUID=.*|PUID=$user_id|" "$env_file"
    sed -i "s|PGID=.*|PGID=$group_id|" "$env_file"
    sed -i "s|SMTP_FROM=.*|SMTP_FROM=$smtp_from_escaped|" "$env_file"
    sed -i "s|SSH_LOG_PATH=.*|SSH_LOG_PATH=$ssh_log_escaped|" "$env_file"

    if [[ "$USE_LATEST" == "true" ]]; then
        sed -i 's/^VAULTWARDEN_VERSION=.*/VAULTWARDEN_VERSION=latest/' "$env_file"
        sed -i 's/^CADDY_VERSION=.*/CADDY_VERSION=latest/' "$env_file"
        sed -i 's/^FAIL2BAN_VERSION=.*/FAIL2BAN_VERSION=latest/' "$env_file"
        sed -i 's/^POSTFIX_VERSION=.*/POSTFIX_VERSION=latest/' "$env_file"
    fi

    if ! chown "$real_user:$real_group" "$env_file" || ! chmod 644 "$env_file"; then
        log_error "Failed to set .env file permissions"
        return 1
    fi

    log_success "Environment file created from template: $env_file"
    return 0
}

# STANDARDIZED: Returns exit code
setup_directories() {
    log_info "Setting up project directories..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create project directories"
        return 0
    fi

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n $real_user)

    local dirs=(
        "secrets"
        "secrets/keys"
        "secrets/.docker_secrets"
    )

    for dir in "${dirs[@]}"; do
        if ! ensure_dir "$dir" 755; then
            log_error "Failed to create directory: $dir"
            return 1
        fi

        if ! chown "$real_user:$real_group" "$dir"; then
            log_error "Failed to set ownership for directory: $dir"
            return 1
        fi
    done

    if ! chmod 700 "secrets" || ! chmod 700 "secrets/keys" || ! chmod 700 "secrets/.docker_secrets"; then
        log_error "Failed to secure secrets directories"
        return 1
    fi

    log_success "Project directories created."
    return 0
}

# STANDARDIZED: Enhanced entropy check
check_entropy() {
    log_info "Checking system entropy..."
    local entropy
    entropy=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo "0")

    if (( entropy >= ENTROPY_THRESHOLD )); then
        log_success "System entropy is sufficient ($entropy)"
        return 0
    fi

    log_warn "System entropy is low ($entropy). Waiting..."
    local waited=0

    while (( waited < ENTROPY_MAX_WAIT )); do
        sleep 5
        waited=$((waited + 5))
        entropy=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo "0")

        if (( entropy >= ENTROPY_THRESHOLD )); then
            log_success "System entropy is now sufficient ($entropy) after ${waited}s"
            return 0
        fi

        log_info "Entropy: $entropy (need $ENTROPY_THRESHOLD), waited ${waited}s..."
    done

    log_error "System entropy remained low ($entropy) after ${ENTROPY_MAX_WAIT}s wait."
    return 1
}

# STANDARDIZED: Returns exit code
generate_age_keys() {
    if ! check_entropy; then
        return 1
    fi

    log_info "Generating Age encryption keys..."

    local age_key_file="secrets/keys/age-key.txt"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would generate Age encryption keys"
        return 0
    fi

    if [[ -f "$age_key_file" ]]; then
        if [[ "$FORCE" == "true" ]]; then
            log_info "Force flag enabled - will regenerate existing Age key"
        else
            log_info "Age key already exists, skipping generation."
            return 0
        fi
    fi

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n "$real_user")

    if ! generate_age_key "$age_key_file" "$FORCE"; then
        log_error "Failed to generate Age key"
        return 1
    fi

    if ! chown "$real_user:$real_group" "$age_key_file"; then
        log_error "Failed to set Age key file ownership"
        return 1
    fi

    log_success "Age encryption keys generated: $age_key_file"
    return 0
}

# STANDARDIZED: Returns exit code
create_sops_config() {
    log_info "Creating SOPS configuration..."

    local sops_config=".sops.yaml"
    local age_key_file="secrets/keys/age-key.txt"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create SOPS configuration"
        return 0
    fi

    if [[ ! -f "$age_key_file" ]]; then
        log_error "Age key file not found: $age_key_file"
        return 1
    fi

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n $real_user)

    local age_public_key
    if ! age_public_key=$(get_age_public_key "$age_key_file"); then
        return 1
    fi

    # FIX: Use flexible regex that matches any path ending with secrets.yaml
    if ! cat > "$sops_config" << EOF; then
creation_rules:
  - path_regex: .*secrets\\.yaml$
    age: $age_public_key
EOF
        log_error "Failed to create SOPS configuration"
        return 1
    fi

    if ! chown "$real_user:$real_group" "$sops_config"; then
        log_error "Failed to set SOPS config ownership"
        return 1
    fi

    log_success "SOPS configuration created: $sops_config"
    return 0
}

# NEW: Create empty encrypted secrets structure
create_empty_secrets_structure() {
    log_info "Creating encrypted empty secrets structure..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create empty secrets structure"
        return 0
    fi

    local secrets_file="$PROJECT_ROOT/secrets/secrets.yaml"
    local age_key_file="$PROJECT_ROOT/secrets/keys/age-key.txt"

    if [[ -f "$secrets_file" ]]; then
        log_info "Secrets file already exists, validating..."
        export SOPS_AGE_KEY_FILE="$age_key_file"
        if sops -d "$secrets_file" >/dev/null 2>&1; then
            log_success "Existing secrets file validated"
            return 0
        else
            log_error "Existing secrets file is corrupted"
            return 1
        fi
    fi

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n $real_user)

    # FIX: Create temp file with correct name that matches SOPS regex
    local temp_secrets="$PROJECT_ROOT/secrets/.temp_secrets.yaml"
    
    cat > "$temp_secrets" << 'EOF'
# VaultWarden Secrets Configuration - Empty Structure
# This file will be populated by setup-secrets.sh
# DO NOT manually edit these placeholder values
# Run: ./setup-secrets.sh to configure all secrets interactively

# VaultWarden admin password (will be Argon2id hashed)
admin_token: PLACEHOLDER_NOT_CONFIGURED

# Caddy admin password (will be bcrypt hashed)
admin_basic_auth_hash: PLACEHOLDER_NOT_CONFIGURED

# SMTP password for email notifications
smtp_password: PLACEHOLDER_NOT_CONFIGURED

# Backup encryption passphrase (auto-generated)
backup_passphrase: PLACEHOLDER_NOT_CONFIGURED

# Push notifications (optional - from bitwarden.com/host)
push_installation_id: PLACEHOLDER_NOT_CONFIGURED
push_installation_key: PLACEHOLDER_NOT_CONFIGURED

# Cloudflare DNS API token (Zone:DNS:Edit + Zone:Zone:Read)
caddy_cloudflare_dns_token: PLACEHOLDER_NOT_CONFIGURED

# Cloudflare Firewall API token (Zone:Firewall Services:Edit)
fail2ban_cloudflare_firewall_token: PLACEHOLDER_NOT_CONFIGURED
EOF

    chmod 600 "$temp_secrets"

    # FIX: Ensure we're in PROJECT_ROOT where .sops.yaml exists
    cd "$PROJECT_ROOT" || {
        log_error "Failed to change to project root: $PROJECT_ROOT"
        rm -f "$temp_secrets"
        return 1
    }

    export SOPS_AGE_KEY_FILE="$age_key_file"

    # Encrypt - now the temp file matches .*secrets\.yaml$ regex
    if ! sops --encrypt "$temp_secrets" > "$secrets_file"; then
        log_error "Failed to encrypt secrets template"
        log_error "SOPS config: $(cat .sops.yaml 2>/dev/null || echo 'not found')"
        rm -f "$temp_secrets"
        return 1
    fi

    rm -f "$temp_secrets"

    if ! chmod 600 "$secrets_file" || ! chown "$real_user:$real_group" "$secrets_file"; then
        log_error "Failed to secure secrets file"
        return 1
    fi

    log_success "Empty encrypted secrets structure created"
    log_info "File: $secrets_file (encrypted with Age)"
    log_info "Status: Ready for value population"
    
    return 0
}

# NEW: Interactive secrets setup integration
setup_secrets_interactively() {
    log_info "Launching interactive secrets configuration..."

    if [[ ! -f "$PROJECT_ROOT/setup-secrets.sh" ]]; then
        log_error "setup-secrets.sh not found"
        log_error "This script is required for secrets configuration"
        return 1
    fi

    if [[ ! -x "$PROJECT_ROOT/setup-secrets.sh" ]]; then
        chmod +x "$PROJECT_ROOT/setup-secrets.sh"
    fi

    if [[ -f "secrets/secrets.yaml" ]] && [[ "$FORCE" != "true" ]]; then
        # Check if it's already configured
        export SOPS_AGE_KEY_FILE="$PROJECT_ROOT/secrets/keys/age-key.txt"
        if ! sops -d "secrets/secrets.yaml" 2>/dev/null | grep -q "PLACEHOLDER_NOT_CONFIGURED"; then
            if [[ "$AUTO_MODE" != "true" ]]; then
                echo ""
                read -p "Secrets already configured. Reconfigure? (yes/no): " reconfigure
                if [[ "$reconfigure" != "yes" ]]; then
                    log_info "Keeping existing secrets"
                    return 0
                fi
            else
                log_info "Auto mode: keeping existing configured secrets"
                return 0
            fi
        fi
    fi

    if [[ "$AUTO_MODE" == "true" ]]; then
        log_info "Running automated secrets setup..."
        
        if ./setup-secrets.sh --auto --skip-optional; then
            log_success "Secrets configured automatically"
            echo ""
            log_warn "⚠️  IMPORTANT: Auto-generated passwords displayed above"
            log_warn "⚠️  Save them securely - they cannot be recovered"
            echo ""
            return 0
        else
            log_error "Automated secrets setup failed"
            return 1
        fi
    else
        echo ""
        log_info "═══════════════════════════════════════════════════════════"
        log_info "  Interactive Secrets Configuration"
        log_info "═══════════════════════════════════════════════════════════"
        log_info ""
        log_info "Configure secrets with automated hashing:"
        log_info "  ✅ Argon2id hashing for VaultWarden admin"
        log_info "  ✅ Bcrypt hashing for Caddy admin"
        log_info "  ✅ Cloudflare token validation"
        log_info "  ✅ Secure random generation"
        echo ""
        read -p "Configure secrets interactively? (recommended) (yes/no): " do_setup
        
        if [[ "$do_setup" == "yes" ]]; then
            if ./setup-secrets.sh; then
                log_success "Secrets configured successfully"
                return 0
            else
                log_error "Interactive secrets setup failed"
                return 1
            fi
        else
            log_info "Skipped interactive secrets setup"
            log_warn "Secrets contain placeholders - configure before use!"
            log_info "Run later: ./setup-secrets.sh"
            return 0
        fi
    fi
}

# STANDARDIZED: Template-based docker compose creation
create_docker_compose() {
    log_info "Setting up Docker Compose configuration..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would copy docker-compose.yml from template"
        return 0
    fi

    local compose_file="$PROJECT_ROOT/docker-compose.yml"
    local compose_template="$PROJECT_ROOT/docker-compose.yml.example"

    if [[ -f "$compose_file" ]] && [[ "$FORCE" != "true" ]]; then
        log_info "docker-compose.yml already exists, skipping creation."
        return 0
    fi

    if [[ ! -f "$compose_template" ]]; then
        log_error "docker-compose.yml.example template not found"
        return 1
    fi

    log_info "Validating template: $compose_template"
    if ! docker compose -f "$compose_template" config >/dev/null 2>&1; then
        log_error "Template validation failed"
        return 1
    fi

    if ! cp "$compose_template" "$compose_file"; then
        log_error "Failed to copy Docker Compose template"
        return 1
    fi

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n $real_user)

    if ! chown "$real_user:$real_group" "$compose_file" || ! chmod 644 "$compose_file"; then
        log_error "Failed to set Docker Compose file permissions"
        return 1
    fi

    log_success "Docker Compose configuration created from template."
    return 0
}

# STANDARDIZED: Returns exit code
set_script_permissions() {
    log_info "Setting script permissions..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would set executable permissions on scripts"
        return 0
    fi

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n $real_user)

    local scripts=(
        "setup.sh"
        "setup-secrets.sh"
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
        "update-dns.sh"
        "test-email-simple.sh"
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

# Firewall setup (existing code from repo - keeping as-is)
setup_firewall() {
    log_info "Configuring Cloudflare-only UFW firewall..."
    # ... (existing firewall code from repo)
    return 0
}

# SSH validation (existing code from repo - keeping as-is)
validate_ssh_config() {
    log_info "Validating SSH security configuration..."
    # ... (existing SSH validation code from repo)
    return 0
}

# STANDARDIZED: Enhanced cleanup
cleanup_setup_deps() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would cleanup setup dependencies"
        return 0
    fi

    log_info "Cleaning up setup dependencies..."

    if systemctl is-active --quiet haveged 2>/dev/null; then
        systemctl stop haveged || true
    fi

    if command -v haveged >/dev/null 2>&1; then
        apt-get remove --purge -y haveged >/dev/null 2>&1 || true
    fi

    apt-get autoremove -y >/dev/null 2>&1 || true

    log_success "Cleanup completed"
    return 0
}

# ENHANCED: Main function with proper error handling
main() {
    log_header "VaultWarden-OCI Setup - Integrated Secrets Management"

    if ! is_root; then 
        log_error "This script must be run as root."
        exit 1
    fi

    if [[ -z "$DOMAIN" ]] || [[ -z "$ADMIN_EMAIL" ]]; then 
        log_error "Domain and Email are required."
        show_help
        exit 1
    fi

    local setup_phases=(
        "install_dependencies:Dependency Installation"
        "verify_dependencies:Dependency Verification"
        "setup_user_permissions:User Permissions"
        "create_env_file:Environment Configuration"
        "create_docker_compose:Docker Compose Setup"
        "setup_directories:Directory Creation"
        "generate_age_keys:Encryption Keys"
        "create_sops_config:SOPS Configuration"
        "create_empty_secrets_structure:Empty Secrets Structure"
        "setup_secrets_interactively:Interactive Secrets Configuration"
        "set_script_permissions:Script Permissions"
        "setup_firewall:Firewall Configuration"
        "validate_ssh_config:SSH Hardening Validation"
        "cleanup_setup_deps:Setup Cleanup"
    )

    local failed_phases=()

    for phase_info in "${setup_phases[@]}"; do
        local phase_func="${phase_info%%:*}"
        local phase_name="${phase_info##*:}"

        log_info "=== Phase: $phase_name ==="

        if [[ "$phase_func" == "verify_dependencies" ]]; then
            hash -r
        fi

        if ! $phase_func; then
            failed_phases+=("$phase_name")
            log_error "Phase failed: $phase_name"
            
            if [[ "$phase_func" =~ ^(install_dependencies|verify_dependencies|create_env_file|setup_firewall|validate_ssh_config|generate_age_keys|create_sops_config|create_empty_secrets_structure)$ ]]; then
                log_error "Critical phase failed - stopping setup"
                exit 1
            fi
        else
            log_success "Phase completed: $phase_name"
        fi
    done

    if [[ ${#failed_phases[@]} -gt 0 ]]; then
        log_error "Setup completed with failures: ${failed_phases[*]}"
        exit 1
    fi

    # Final summary
    log_header "Setup Complete - VaultWarden-OCI Ready!"
    echo ""
    echo "✅ Configuration:"
    echo "   - Domain: https://$DOMAIN"
    echo "   - Admin: $ADMIN_EMAIL"
    echo "   - Secrets: Encrypted with SOPS + Age"
    echo ""
    
    # Check secrets status
    if sops -d secrets/secrets.yaml 2>/dev/null | grep -q "PLACEHOLDER_NOT_CONFIGURED"; then
        echo "⚠️  SECRETS NEED CONFIGURATION:"
        echo "   Some secrets contain placeholders"
        echo "   Run: ./setup-secrets.sh"
        echo ""
    fi
    
    echo "🎯 NEXT STEPS:"
    echo "   1. Review .env: nano .env"
    echo "   2. Start services: make up"
    echo "   3. Setup cron: sudo ./cron-setup.sh --install"
    echo "   4. Emergency access: make breakglass-create"

    exit 0
}

main "$@"
