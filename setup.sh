#!/usr/bin/env bash

# setup.sh - VaultWarden-OCI Setup Script (SECURITY HARDENED)
# 

set -euo pipefail

# Disable debug traces that could leak secrets
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# =============================================================================
# SECURITY ENHANCEMENT: Secure Temporary Directory
# =============================================================================
# Create temporary directory with restrictive permissions BEFORE any operations
old_umask=$(umask)
umask 077  # Ensure 700 permissions for temp directory
TMP_WORKDIR=$(mktemp -d -t vw_setup.XXXXXXXXXX) || {
    echo "ERROR: Failed to create secure temporary directory" >&2
    exit 1
}
umask "$old_umask"  # Restore original umask
trap 'rm -rf "$TMP_WORKDIR"' EXIT

# =============================================================================
# Library Validation and Sourcing
# =============================================================================
REQUIRED_LIBS=(
    "lib/common.sh"
    "lib/crypto.sh"
    "lib/docker.sh"
    "lib/security.sh"
    "lib/backup_utils.sh"
    "lib/secrets.sh"
)

for lib in "${REQUIRED_LIBS[@]}"; do
    if [[ ! -f "$lib" ]]; then
        echo "ERROR: Required library not found: $lib" >&2
        echo "Please ensure all library files are present in the lib/ directory" >&2
        echo "" >&2
        echo "Expected libraries:" >&2
        printf " - %s\n" "${REQUIRED_LIBS[@]}" >&2
        exit 1
    fi
done

source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"
source "lib/docker.sh"

# =============================================================================
# Configuration Defaults
# =============================================================================
DOMAIN=""
ADMIN_EMAIL=""
AUTO_MODE=false
USE_LATEST=false
SKIP_DEPS=false
FORCE=false
DRY_RUN=false
ENTROPY_THRESHOLD=200
ENTROPY_MAX_WAIT=60

# Global variable to store clean domain for final summary
CLEAN_DOMAIN=""

# =============================================================================
# Help Function
# =============================================================================
show_help() {
    cat << 'EOF'
VaultWarden-OCI Setup Tool - Security Hardened Edition

USAGE:
    sudo ./setup.sh --domain DOMAIN --email EMAIL [OPTIONS]

REQUIRED OPTIONS:
    --domain DOMAIN      Your VaultWarden domain (e.g., vault.example.com)
    --email EMAIL        Administrator email address

SETUP OPTIONS:
    --auto               Automated setup with NO prompts (fully unattended)
    --use-latest         Use latest container versions (default: pinned versions)
    --skip-deps          Skip dependency installation (install manually first)
    --force              Overwrite existing configuration files
    --dry-run            Show what would be done without executing
    --help               Show this help information

SYSTEM REQUIREMENTS:
    Operating System:  Ubuntu 20.04+ or Debian 11+ (Debian-based only)
    Platform:          Tested on Oracle Cloud Infrastructure (OCI) A1 Flex
    Memory:            Minimum 6GB RAM
    Architecture:      AMD64 or ARM64

EXAMPLES:
    # Interactive production setup (recommended)
    sudo ./setup.sh --domain vault.example.com --email admin@example.com

    # Fully automated setup with pinned versions (NO prompts)
    sudo ./setup.sh --domain vault.example.com --email admin@example.com --auto

    # Re-run setup (idempotent - safe)
    sudo ./setup.sh --domain vault.example.com --email admin@example.com

SECURITY FEATURES:
    ✅ Command injection protection (awk-based substitution)
    ✅ Secure temporary file handling (umask 077, 10-char entropy)
    ✅ Strict input validation (regex + length limits)
    ✅ Sensitive data logging protection
    ✅ SOPS + Age encrypted secrets
    ✅ Enhanced error handling (critical vs non-critical)
    ✅ Idempotent - Safe to re-run multiple times
    ✅ Postfix email backend (Cloudflare rate limiting ready)

EOF
}

# =============================================================================
# Argument Parsing
# =============================================================================
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

# =============================================================================
# SECURITY ENHANCEMENT: Strict Input Validation
# =============================================================================
validate_domain_secure() {
    local domain="$1"
    
    # Length validation (max DNS name length is 253 characters)
    if [[ ${#domain} -gt 253 ]]; then
        log_error "Domain exceeds maximum length (253 characters)"
        return 1
    fi
    
    # Regex validation: alphanumeric, dots, hyphens only
    # Must start with alphanumeric, contain at least one dot, end with valid TLD
    if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]]; then
        log_error "Invalid domain format: $domain"
        log_info "Domain must contain only alphanumeric characters, dots, and hyphens"
        return 1
    fi
    
    return 0
}

validate_email_secure() {
    local email="$1"
    
    # Length validation (RFC 5321 max email length is 254 characters)
    if [[ ${#email} -gt 254 ]]; then
        log_error "Email exceeds maximum length (254 characters)"
        return 1
    fi
    
    # Regex validation: RFC 5322 compliant (reasonably strict)
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_error "Invalid email format: $email"
        return 1
    fi
    
    return 0
}

# =============================================================================
# Initial Validation
# =============================================================================
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

# Apply strict validation
if ! validate_domain_secure "$DOMAIN"; then
    exit 1
fi

if ! validate_email_secure "$ADMIN_EMAIL"; then
    exit 1
fi

# =============================================================================
# PHASE FUNCTIONS - All idempotent with state checking
# =============================================================================

# IDEMPOTENT: System Functions - all check state first
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

    # Check which packages are actually missing (idempotent check)
    local basic_packages=("age" "make" "nano" "rclone" "sqlite3" "jq" "ufw" "curl" "wget" "unzip" "git" "gpg" "coreutils" "haveged" "dnsutils" "rsync" "python3" "python3-argon2" "apache2-utils")
    local missing_packages=()

    for pkg in "${basic_packages[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing_packages+=("$pkg")
        fi
    done

    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        log_success "All dependencies already installed"
    else
        log_info "Installing missing packages: ${missing_packages[*]}"
        if ! apt-get update -qq; then
            log_error "Failed to update package lists"
            return 1
        fi

        export DEBIAN_FRONTEND=noninteractive
        if ! apt-get install -y "${missing_packages[@]}"; then
            log_error "Failed to install dependencies."
            return 1
        fi
    fi

    # Start haveged service for entropy generation (idempotent)
    if systemctl is-active --quiet haveged; then
        log_success "haveged service is already running"
    else
        if systemctl is-enabled --quiet haveged 2>/dev/null; then
            if ! systemctl start haveged; then
                log_error "Failed to start haveged service"
                return 1
            fi
            log_success "haveged service started"
        else
            if ! systemctl enable haveged || ! systemctl start haveged; then
                log_warn "Failed to enable/start haveged"
            else
                log_success "haveged service enabled and started"
            fi
        fi
    fi

    # Install unattended-upgrades (idempotent)
    if dpkg -s unattended-upgrades >/dev/null 2>&1; then
        log_success "Automatic security updates already configured"
    else
        log_info "Installing and enabling automatic security updates..."
        if apt-get install -y unattended-upgrades; then
            echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
            if dpkg-reconfigure -f noninteractive unattended-upgrades; then
                log_success "Host OS automatic security updates enabled."
            else
                log_warn "Failed to configure unattended-upgrades"
            fi
        else
            log_warn "Could not install 'unattended-upgrades'"
        fi
    fi

    # Install Docker if not present (idempotent)
    if command -v docker >/dev/null 2>&1; then
        log_success "Docker already installed"
    else
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
        log_warn "Note: User must logout/login or run 'newgrp docker' for group to take effect"
    fi

    # Install Docker Compose plugin (idempotent)
    if docker compose version >/dev/null 2>&1; then
        log_success "Docker Compose plugin already installed"
    else
        log_info "Installing Docker Compose plugin..."
        if ! apt-get install -y docker-compose-plugin; then
            log_error "Failed to install Docker Compose plugin"
            return 1
        fi
        log_success "Docker Compose plugin installed"
    fi

    # Install SOPS (idempotent)
    if command -v sops >/dev/null 2>&1; then
        log_success "SOPS already installed"
    else
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
        log_success "SOPS installed"
    fi

    log_success "Dependencies installed."
    return 0
}

# IDEMPOTENT: Verify dependencies
verify_dependencies() {
    log_info "Verifying dependencies..."
    hash -r

    local required_commands=("age" "sops" "docker" "jq" "sqlite3" "ufw" "curl" "python3" "htpasswd")
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

# IDEMPOTENT: User permissions
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

    # Add to docker group if not already (idempotent)
    if groups "$real_user" | grep -q docker; then
        log_success "User $real_user already in docker group"
    else
        if ! usermod -aG docker "$real_user"; then
            log_error "Failed to add $real_user to docker group"
            return 1
        fi
        log_info "Added $real_user to docker group"
        log_warn "Note: User must logout/login or run 'newgrp docker' for group to take effect"
    fi

    # Set ownership (idempotent)
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

# =============================================================================
# SECURITY FIX: Template-based environment file creation with AWK substitution
# =============================================================================
create_env_file() {
    log_info "Creating environment configuration file (.env)..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create .env from template"
        return 0
    fi

    local env_file="$PROJECT_ROOT/.env"
    local env_template="$PROJECT_ROOT/.env.example"

    # Check if already exists and valid (idempotent check)
    if [[ -f "$env_file" ]] && [[ "$FORCE" != "true" ]]; then
        if grep -q "^DOMAIN=$DOMAIN" "$env_file" && grep -q "^ADMIN_EMAIL=$ADMIN_EMAIL" "$env_file"; then
            log_success ".env file already exists with correct values"
            return 0
        else
            log_warn ".env exists but values differ, updating..."
        fi
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

    # Domain cleaning
    local domain_with_protocol
    if [[ "$DOMAIN" =~ ^https?:// ]]; then
        domain_with_protocol="$DOMAIN"
    else
        domain_with_protocol="https://$DOMAIN"
    fi

    local clean_domain
    clean_domain=$(echo "$domain_with_protocol" | sed 's|https\?://||; s|/.*$||')

    # Store clean_domain globally for final summary
    CLEAN_DOMAIN="$clean_domain"

    # =============================================================================
    # SECURITY FIX: Use AWK instead of SED to prevent command injection
    # =============================================================================
    # AWK safely handles variables without shell expansion risks
    
    local temp_env="$TMP_WORKDIR/env.tmp"
    
    awk -v domain="$domain_with_protocol" \
        -v name="$clean_domain" \
        -v email="$ADMIN_EMAIL" \
        -v uid="$user_id" \
        -v gid="$group_id" \
        -v smtp_from="noreply@$clean_domain" \
        -v ssh_log="$detected_ssh_log_path" \
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

    if ! mv "$temp_env" "$env_file"; then
        log_error "Failed to update .env file"
        return 1
    fi

    # Handle version pinning
    if [[ "$USE_LATEST" == "true" ]]; then
        awk '{
            sub(/^VAULTWARDEN_VERSION=.*/, "VAULTWARDEN_VERSION=latest");
            sub(/^CADDY_VERSION=.*/, "CADDY_VERSION=latest");
            sub(/^FAIL2BAN_VERSION=.*/, "FAIL2BAN_VERSION=latest");
            sub(/^POSTFIX_VERSION=.*/, "POSTFIX_VERSION=latest");
            print;
        }' "$env_file" > "$temp_env"
        
        if ! mv "$temp_env" "$env_file"; then
            log_error "Failed to update version settings"
            return 1
        fi
    fi

    # Set .env to 600 for security (owner read/write only)
    if ! chown "$real_user:$real_group" "$env_file" || ! chmod 600 "$env_file"; then
        log_error "Failed to set .env file permissions"
        return 1
    fi

    log_success "Environment file created securely: $env_file"
    log_info "Permissions: 600 (owner read/write only)"
    return 0
}

# IDEMPOTENT: Directory creation
setup_directories() {
    log_info "Setting up project directories..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create project directories"
        return 0
    fi

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n "$real_user")

    local dirs=(
        "secrets"
        "secrets/keys"
        "secrets/.docker_secrets"
    )

    for dir in "${dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            log_success "Directory already exists: $dir"
        else
            if ! ensure_dir "$dir" 755; then
                log_error "Failed to create directory: $dir"
                return 1
            fi
            log_info "Created directory: $dir"
        fi

        if ! chown "$real_user:$real_group" "$dir"; then
            log_error "Failed to set ownership for directory: $dir"
            return 1
        fi
    done

    # Secure permissions (idempotent)
    chmod 700 "secrets" "secrets/keys" "secrets/.docker_secrets" 2>/dev/null || true

    log_success "Project directories created."
    return 0
}

# IDEMPOTENT: Enhanced entropy check
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

# IDEMPOTENT: Age key generation
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

    # Check if valid key exists (idempotent check)
    if [[ -f "$age_key_file" ]]; then
        if check_age_key "$age_key_file" 2>/dev/null; then
            if [[ "$FORCE" == "true" ]]; then
                log_info "Force flag enabled - regenerating Age key"
            else
                log_success "Valid Age key already exists"
                return 0
            fi
        else
            log_warn "Existing Age key appears invalid - regenerating"
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

    # Explicitly set Age key to 600 permissions
    if ! chmod 600 "$age_key_file"; then
        log_error "Failed to set Age key file permissions"
        return 1
    fi

    log_success "Age encryption keys generated: $age_key_file"
    log_info "Permissions: 600 (owner read/write only)"
    return 0
}

# IDEMPOTENT: SOPS configuration
create_sops_config() {
    log_info "Creating SOPS configuration..."
    local sops_config=".sops.yaml"
    local age_key_file="secrets/keys/age-key.txt"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create SOPS configuration"
        return 0
    fi

    # Check if valid config exists (idempotent check)
    if [[ -f "$sops_config" ]] && [[ "$FORCE" != "true" ]]; then
        if grep -q "creation_rules:" "$sops_config" && grep -q "age:" "$sops_config"; then
            log_success "SOPS configuration already exists and appears valid"
            return 0
        else
            log_warn "Existing SOPS config appears invalid - recreating"
        fi
    fi

    if [[ ! -f "$age_key_file" ]]; then
        log_error "Age key file not found: $age_key_file"
        return 1
    fi

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n "$real_user")

    local age_public_key
    if ! age_public_key=$(get_age_public_key "$age_key_file"); then
        return 1
    fi

    if ! cat > "$sops_config" << EOF; then
creation_rules:
  - path_regex: .*\.yaml$
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

# =============================================================================
# SECURITY FIX: Create empty encrypted secrets structure with secure temp files
# =============================================================================
create_empty_secrets_structure() {
    log_info "Creating encrypted empty secrets structure..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create empty secrets structure"
        return 0
    fi

    local secrets_file="$PROJECT_ROOT/secrets/secrets.yaml"
    local age_key_file="$PROJECT_ROOT/secrets/keys/age-key.txt"

    # Check if valid secrets file exists (idempotent check)
    if [[ -f "$secrets_file" ]]; then
        log_info "Secrets file exists, validating..."
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
    local real_group; real_group=$(id -g -n "$real_user")

    # SECURITY FIX: Use secure temporary directory with high entropy
    local temp_secrets
    temp_secrets=$(mktemp -p "$TMP_WORKDIR" vwsecrets.XXXXXXXXXX.yaml) || {
        log_error "Failed to create temporary secrets file"
        return 1
    }

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

    cd "$PROJECT_ROOT" || {
        log_error "Failed to change to project root: $PROJECT_ROOT"
        return 1
    }

    export SOPS_AGE_KEY_FILE="$age_key_file"

    # Use explicit --output for clarity and atomicity
    if ! sops --encrypt --output "$secrets_file" "$temp_secrets"; then
        log_error "Failed to encrypt secrets template"
        return 1
    fi

    if ! chmod 600 "$secrets_file" || ! chown "$real_user:$real_group" "$secrets_file"; then
        log_error "Failed to secure secrets file"
        return 1
    fi

    log_success "Empty encrypted secrets structure created"
    log_info "File: $secrets_file (encrypted with Age)"
    log_info "Permissions: 600 (owner read/write only)"
    log_info "Status: Ready for value population"
    return 0
}

# IDEMPOTENT: Interactive secrets setup integration
setup_secrets_interactively() {
    log_info "Launching secrets configuration..."

    if [[ ! -f "$PROJECT_ROOT/setup-secrets.sh" ]]; then
        log_error "setup-secrets.sh not found"
        return 1
    fi

    if [[ ! -x "$PROJECT_ROOT/setup-secrets.sh" ]]; then
        chmod +x "$PROJECT_ROOT/setup-secrets.sh"
    fi

    # Check if secrets are already configured (idempotent check)
    local secrets_configured=false
    if [[ -f "secrets/secrets.yaml" ]]; then
        export SOPS_AGE_KEY_FILE="$PROJECT_ROOT/secrets/keys/age-key.txt"

        if sops -d "secrets/secrets.yaml" 2>/dev/null | grep -q "PLACEHOLDER_NOT_CONFIGURED"; then
            log_info "Secrets file exists but contains placeholders"
            secrets_configured=false
        else
            log_info "Secrets file exists and appears configured"
            secrets_configured=true
        fi
    fi

    # Handle based on mode and state
    if [[ "$secrets_configured" == "true" ]]; then
        # Secrets already configured
        if [[ "$FORCE" == "true" ]]; then
            log_info "Force flag enabled - reconfiguring secrets"
            # Fall through to configuration logic below
        elif [[ "$AUTO_MODE" == "true" ]]; then
            log_success "Auto mode: keeping existing configured secrets"
            return 0
        else
            # Interactive mode - ask user
            echo ""
            read -p "Secrets already configured. Reconfigure? (yes/no): " reconfigure
            if [[ "$reconfigure" != "yes" ]]; then
                log_success "Keeping existing secrets"
                return 0
            fi
            # Fall through to reconfigure
        fi
    fi

    # Configure secrets based on mode
    if [[ "$AUTO_MODE" == "true" ]]; then
        log_info "Running automated secrets setup (--auto mode)..."
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
        # Interactive mode
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

# IDEMPOTENT: Template-based docker compose creation
create_docker_compose() {
    log_info "Setting up Docker Compose configuration..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would copy docker-compose.yml from template"
        return 0
    fi

    local compose_file="$PROJECT_ROOT/docker-compose.yml"
    local compose_template="$PROJECT_ROOT/docker-compose.yml.example"

    # Check if exists and valid (idempotent check)
    if [[ -f "$compose_file" ]] && [[ "$FORCE" != "true" ]]; then
        if docker compose -f "$compose_file" config >/dev/null 2>&1; then
            log_success "docker-compose.yml already exists and is valid"
            return 0
        else
            log_warn "Existing docker-compose.yml appears invalid - recreating"
        fi
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
    local real_group; real_group=$(id -g -n "$real_user")

    if ! chown "$real_user:$real_group" "$compose_file" || ! chmod 644 "$compose_file"; then
        log_error "Failed to set Docker Compose file permissions"
        return 1
    fi

    log_success "Docker Compose configuration created from template."
    return 0
}

# IDEMPOTENT: Script permissions
set_script_permissions() {
    log_info "Setting script permissions..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would set executable permissions on scripts"
        return 0
    fi

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n "$real_user")

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
            if [[ -x "$script" ]]; then
                log_success "Script already executable: $script"
            else
                chmod +x "$script"
                log_info "Made executable: $script"
            fi
            chown "$real_user:$real_group" "$script" 2>/dev/null || true
        fi
    done

    if [[ -d "lib" ]]; then
        find "lib" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
        find "lib" -name "*.sh" -exec chown "$real_user:$real_group" {} \; 2>/dev/null || true
    fi

    log_success "Script permissions set."
    return 0
}

# IDEMPOTENT: Firewall setup
setup_firewall() {
    log_info "Configuring basic UFW firewall..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would configure firewall"
        return 0
    fi

    # Check if UFW is already configured (idempotent check)
    if ufw status | grep -q "Status: active"; then
        if ufw status | grep -q "80/tcp" && ufw status | grep -q "443/tcp"; then
            log_success "Firewall already configured and active"
            return 0
        fi
    fi

    # Allow SSH first (critical!)
    ufw allow OpenSSH || ufw allow 22/tcp

    # Allow HTTP/HTTPS
    ufw allow 80/tcp
    ufw allow 443/tcp

    # Enable if not already
    if ! ufw status | grep -q "Status: active"; then
        echo "y" | ufw enable
        log_success "UFW firewall enabled"
    else
        log_success "UFW firewall already active"
    fi

    return 0
}

# IDEMPOTENT: SSH validation
validate_ssh_config() {
    log_info "Validating SSH security configuration..."

    # Check SSH config (idempotent - only suggest, don't force change)
    if grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config 2>/dev/null; then
        log_warn "SSH root login is enabled - consider disabling"
        log_info "To disable: sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config && systemctl reload sshd"
    else
        log_success "SSH root login appropriately restricted"
    fi

    log_success "SSH configuration validation complete"
    return 0
}

# IDEMPOTENT: Enhanced cleanup
cleanup_setup_deps() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would cleanup setup dependencies"
        return 0
    fi

    log_info "Cleaning up setup dependencies..."

    # Only stop haveged if it's running (idempotent)
    if systemctl is-active --quiet haveged 2>/dev/null; then
        systemctl stop haveged || true
        log_info "Stopped haveged service"
    fi

    apt-get autoremove -y >/dev/null 2>&1 || true

    log_success "Cleanup completed"
    return 0
}

# =============================================================================
# ENHANCED ERROR HANDLING - Phase Execution
# =============================================================================
execute_phase() {
    local phase_func="$1"
    local phase_name="$2"
    local phase_critical="${3:-false}" # Default to non-critical

    log_info "=== Phase: $phase_name ==="

    # Hash refresh for command verification
    if [[ "$phase_func" == "verify_dependencies" ]]; then
        hash -r
    fi

    # Execute phase and capture exit code
    local exit_code=0
    if ! $phase_func; then
        exit_code=$?
        log_error "Phase failed: $phase_name (exit code: $exit_code)"

        # Critical phase failure stops execution
        if [[ "$phase_critical" == "true" ]]; then
            log_error "CRITICAL PHASE FAILED - Stopping setup"
            log_error "Cannot continue without: $phase_name"
            return 1
        else
            log_warn "Non-critical phase failed - continuing setup"
            return 2 # Non-critical failure code
        fi
    else
        log_success "Phase completed: $phase_name"
        return 0
    fi
}

# =============================================================================
# MAIN EXECUTION - ENHANCED WITH STANDARDIZED ERROR HANDLING
# =============================================================================
main() {
    log_header "VaultWarden-OCI Setup - Security Hardened Edition"

    if ! is_root; then
        log_error "This script must be run as root."
        log_info "Usage: sudo $0 --domain your-domain.com --email admin@email.com"
        exit 1
    fi

    if [[ -z "$DOMAIN" ]] || [[ -z "$ADMIN_EMAIL" ]]; then
        log_error "Domain and Email are required."
        show_help
        exit 1
    fi

    # Show mode
    if [[ "$AUTO_MODE" == "true" ]]; then
        log_info "Running in AUTOMATED mode (--auto) - no prompts"
    else
        log_info "Running in INTERACTIVE mode"
    fi

    # Define setup phases with criticality flags
    # Format: "function_name:display_name:is_critical"
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

    local failed_phases=()
    local warned_phases=()
    local phase_info

    # Execute all phases with standardized error handling
    for phase_info in "${setup_phases[@]}"; do
        IFS=':' read -r phase_func phase_name phase_critical <<< "$phase_info"
        
        local result=0
        execute_phase "$phase_func" "$phase_name" "$phase_critical" || result=$?

        case $result in
            0)
                # Success - continue
                ;;
            1)
                # Critical failure - stop immediately
                failed_phases+=("$phase_name [CRITICAL]")
                log_error "Critical phase failed - cannot continue"
                break
                ;;
            2)
                # Non-critical failure - warn and continue
                warned_phases+=("$phase_name")
                log_warn "Non-critical phase failed - setup continues"
                ;;
            *)
                # Unexpected error code
                failed_phases+=("$phase_name [UNKNOWN ERROR: $result]")
                if [[ "$phase_critical" == "true" ]]; then
                    log_error "Critical phase failed with unexpected error - cannot continue"
                    break
                fi
                ;;
        esac
    done

    # Report results
    echo ""
    log_header "Setup Complete - Results Summary"

    if [[ ${#failed_phases[@]} -gt 0 ]]; then
        log_error "Setup FAILED - Critical phases did not complete:"
        for phase in "${failed_phases[@]}"; do
            echo "  ❌ $phase"
        done
        echo ""
        log_error "VaultWarden setup incomplete - resolve errors and re-run"
        exit 1
    fi

    if [[ ${#warned_phases[@]} -gt 0 ]]; then
        log_warn "Setup completed with warnings:"
        for phase in "${warned_phases[@]}"; do
            echo "  ⚠️  $phase"
        done
        echo ""
    fi

    # Success summary
    log_header "VaultWarden-OCI Ready!"
    echo ""
    echo "✅ Configuration:"
    echo "   - Domain: https://$CLEAN_DOMAIN"
    echo "   - Admin: $ADMIN_EMAIL"
    echo "   - Secrets: Encrypted with SOPS + Age"
    echo "   - Mode: $([ "$AUTO_MODE" == "true" ] && echo "Automated" || echo "Interactive")"
    echo "   - Security: Hardened (command injection protected, secure temp files)"
    echo "   - Email: Postfix container (Cloudflare rate limiting ready)"
    echo ""

    # Check secrets status
    if [[ -f "secrets/secrets.yaml" ]]; then
        export SOPS_AGE_KEY_FILE="$PROJECT_ROOT/secrets/keys/age-key.txt"
        
        if sops -d secrets/secrets.yaml 2>/dev/null | grep -q "PLACEHOLDER_NOT_CONFIGURED"; then
            echo "⚠️  SECRETS NEED CONFIGURATION:"
            echo "   Some secrets contain placeholders"
            echo "   Run: ./setup-secrets.sh"
            echo ""
        else
            echo "✅ Secrets: Fully configured"
            echo ""
        fi
    fi

    echo "🎯 NEXT STEPS:"
    echo "   1. Review .env: nano .env"
    echo "   2. Configure secrets (if needed): ./setup-secrets.sh"
    echo "   3. Start services: make up"
    echo "   4. Setup automation: sudo ./cron-setup.sh --install"
    echo "   5. Emergency access: make breakglass-create"
    echo "   6. Test email: ./test-email-simple.sh"
    echo ""
    echo "💡 TIPS:"
    echo "   • This script is idempotent - safe to re-run"
    echo "   • User in docker group must logout/login or run: newgrp docker"
    echo "   • Access VaultWarden at: https://$CLEAN_DOMAIN"
    echo "   • Rate limiting: Configure Cloudflare WAF rules (see docs)"
    echo ""

    if [[ ${#warned_phases[@]} -gt 0 ]]; then
        echo "⚠️  WARNING: Some non-critical phases failed (see above)"
        echo "   Setup is functional but may need attention"
        echo ""
    fi

    exit 0
}

main "$@"
