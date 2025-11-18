#!/usr/bin/env bash
# setup.sh - VaultWarden-OCI Setup Script with Caddy-Cloudflare Integration
# FIXED: Firewall race condition - fetch Cloudflare IPs BEFORE resetting firewall
# FIXED: Added SSH hardening validation
# FIXED: Added Cloudflare token validation
# ENHANCED: Standardized error handling - functions return, main() decides exit strategy

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
VaultWarden-OCI Setup Tool - Enhanced for Caddy-Cloudflare + OCI Compatibility

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
    - Uses template files (.example) for easier maintenance
    - Installs 'unattended-upgrades' for automatic host OS security patches
    - Enhanced error handling with proper exit codes
    - Automatic SSH log path detection for OCI/Oracle Linux compatibility
    - SSH hardening validation for set-and-forget security
    - Cloudflare API token validation before stack deployment
EOF
}

# ENHANCED: Platform-specific SSH log detection for OCI compatibility
detect_ssh_log_path() {
    local ssh_log_path=""

    log_info "Detecting platform-specific SSH log location..."

    # Detect OS type from /etc/os-release
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
            "arch"|"manjaro")
                ssh_log_path="/var/log/auth.log"
                log_info "Detected Arch-based system ($PRETTY_NAME) - using /var/log/auth.log"
                ;;
            "opensuse"*|"sles")
                ssh_log_path="/var/log/messages"
                log_info "Detected SUSE-based system ($PRETTY_NAME) - using /var/log/messages"
                ;;
            *)
                log_warn "Unknown OS detected: $PRETTY_NAME ($ID)"
                # Default fallback - check which file exists and has SSH entries
                if [[ -f "/var/log/secure" ]] && grep -q "sshd" "/var/log/secure" 2>/dev/null; then
                    ssh_log_path="/var/log/secure"
                    log_info "Auto-detected SSH log path: /var/log/secure (found SSH entries)"
                elif [[ -f "/var/log/auth.log" ]] && grep -q "sshd" "/var/log/auth.log" 2>/dev/null; then
                    ssh_log_path="/var/log/auth.log"  
                    log_info "Auto-detected SSH log path: /var/log/auth.log (found SSH entries)"
                elif [[ -f "/var/log/secure" ]]; then
                    ssh_log_path="/var/log/secure"
                    log_info "Defaulting to /var/log/secure (file exists, no SSH entries yet)"
                elif [[ -f "/var/log/auth.log" ]]; then
                    ssh_log_path="/var/log/auth.log"
                    log_info "Defaulting to /var/log/auth.log (file exists, no SSH entries yet)"
                else
                    log_warn "No SSH log files found - defaulting to /var/log/secure for RHEL compatibility"
                    ssh_log_path="/var/log/secure"
                fi
                ;;
        esac
    else
        log_warn "Cannot detect OS (/etc/os-release missing) - defaulting to /var/log/secure"
        ssh_log_path="/var/log/secure"
    fi

    # Validate the detected path
    if [[ -f "$ssh_log_path" ]]; then
        if [[ -r "$ssh_log_path" ]]; then
            log_success "SSH log path validated: $ssh_log_path (readable)"
        else
            log_warn "SSH log path exists but not readable: $ssh_log_path"
            log_info "This is normal - Docker will handle permissions"
        fi
    else
        log_warn "SSH log path does not exist yet: $ssh_log_path"
        log_info "This is normal for new systems - file will be created by SSH daemon"
    fi

    echo "$ssh_log_path"
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

    # BEST PRACTICE FIX: Removed "mailutils" as it's no longer required by msmtpd
    local basic_packages=("age" "make" "nano" "rclone" "sqlite3" "jq" "ufw" "curl" "wget" "unzip" "git" "gpg" "coreutils" "haveged" "dnsutils")
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

    # BEST PRACTICE FIX: Clear the bash command cache to find newly installed commands
    hash -r

    local required_commands=("age" "sops" "docker" "jq" "sqlite3" "ufw" "curl")
    if ! require_commands "${required_commands[@]}"; then
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

    # Ensure user is in docker group
    if ! groups "$real_user" | grep -q docker; then
        if ! usermod -aG docker "$real_user"; then
            log_error "Failed to add $real_user to docker group"
            return 1
        fi
        log_info "Added $real_user to docker group"
    fi

    # Set proper ownership for project directory
    if ! chown -R "$real_user:$real_user" "$PROJECT_ROOT"; then
        log_error "Failed to set project directory ownership"
        return 1
    fi

    log_success "User permissions configured."
    return 0
}

# CRITICAL FIX: Firewall setup with race condition fix
setup_firewall() {
    log_info "Configuring Cloudflare-only UFW firewall..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would configure UFW firewall with Cloudflare IP ranges"
        return 0
    fi
    
    # Get SSH port FIRST
    local ssh_port
    ssh_port=$(get_config_value "SSH_PORT" "22")
    if ! validate_port "$ssh_port"; then
        log_error "Invalid SSH port: $ssh_port"
        return 1
    fi
    
    # CRITICAL FIX: Fetch Cloudflare IPs BEFORE resetting firewall
    log_info "Fetching current Cloudflare IP ranges..."
    local cf_ipv4_file="/tmp/cf_ipv4_ranges.txt"
    local cf_ipv6_file="/tmp/cf_ipv6_ranges.txt"

    # Fetch IPs first, fail early if network is broken
    if ! retry_with_backoff 3 2 curl -sf --max-time 10 "https://www.cloudflare.com/ips-v4" -o "$cf_ipv4_file" || \
       ! retry_with_backoff 3 2 curl -sf --max-time 10 "https://www.cloudflare.com/ips-v6" -o "$cf_ipv6_file"; then
        log_error "⚠️  CRITICAL: Failed to fetch Cloudflare IP ranges"
        log_error "Cannot configure firewall without Cloudflare IPs"
        log_error "Check internet connectivity and retry"
        rm -f "$cf_ipv4_file" "$cf_ipv6_file"
        return 1
    fi
    
    # Validate fetched data before proceeding
    if ! grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' "$cf_ipv4_file" >/dev/null; then
        log_error "Invalid IPv4 ranges received from Cloudflare API"
        rm -f "$cf_ipv4_file" "$cf_ipv6_file"
        return 1
    fi
    log_success "Cloudflare IP ranges fetched and validated"

    # CRITICAL FIX: Add SSH rule BEFORE reset to prevent lockout
    log_info "Pre-configuring SSH access to prevent lockout..."
    if ufw status | grep -q "Status: active"; then
        # UFW is already active - add SSH rule before reset
        if ! ufw allow "$ssh_port/tcp" comment "SSH-PreReset" >/dev/null 2>&1; then
            log_warn "Could not add pre-reset SSH rule (may already exist)"
        else
            log_success "SSH access protected before reset"
        fi
    fi

    # NOW it's safe to reset the firewall
    log_info "Resetting UFW firewall..."
    if ! ufw --force reset >/dev/null; then
        log_error "Failed to reset UFW firewall"
        rm -f "$cf_ipv4_file" "$cf_ipv6_file"
        return 1
    fi

    # IMMEDIATELY set defaults and re-add SSH
    if ! ufw default deny incoming >/dev/null || ! ufw default allow outgoing >/dev/null; then
        log_error "Failed to set UFW default policies"
        return 1
    fi

    # CRITICAL: Re-add SSH rule immediately after reset
    log_info "Re-adding SSH access rule..."
    if ! ufw allow "$ssh_port/tcp" comment "SSH" >/dev/null; then
        log_error "Failed to allow SSH port in UFW"
        return 1
    fi
    log_success "SSH access on port $ssh_port configured"

    # Continue with Cloudflare IP ranges...
    # Apply Cloudflare IPv4 ranges (data already validated)
    log_info "Applying Cloudflare IPv4 ranges..."
    while IFS= read -r range; do
        if [[ -n "$range" ]]; then
            # BEST PRACTICE FIX: Add 'proto tcp' to UFW command
            if ! ufw allow from "$range" to any port 80,443 proto tcp comment "CF-IPv4" >/dev/null; then
                log_warn "Failed to add IPv4 range: $range"
            fi
        fi
    done < "$cf_ipv4_file"
    log_success "Applied Cloudflare IPv4 ranges"

    # Apply Cloudflare IPv6 ranges
    log_info "Applying Cloudflare IPv6 ranges..."
    if grep -E '^[0-9a-fA-F:]+/[0-9]{1,3}$' "$cf_ipv6_file" >/dev/null; then
        while IFS= read -r range; do
            if [[ -n "$range" ]]; then
                # BEST PRACTICE FIX: Add 'proto tcp' to UFW command
                if ! ufw allow from "$range" to any port 80,443 proto tcp comment "CF-IPv6" >/dev/null; then
                    log_warn "Failed to add IPv6 range: $range"
                fi
            fi
        done < "$cf_ipv6_file"
        log_success "Applied Cloudflare IPv6 ranges"
    fi

    # Clean up temp files
    rm -f "$cf_ipv4_file" "$cf_ipv6_file"

    # Enable firewall (only after all rules are added)
    log_info "Enabling UFW firewall..."
    if ! echo "y" | ufw enable >/dev/null; then
        log_error "Failed to enable UFW firewall"
        return 1
    fi
    log_success "Firewall configured and enabled"
    log_info "SSH access maintained on port $ssh_port"
    return 0
}


# NEW: SSH hardening validation for set-and-forget security
validate_ssh_config() {
    log_info "Validating SSH security configuration..."
    
    local sshd_config="/etc/ssh/sshd_config"
    local warnings=0
    
    if [[ ! -f "$sshd_config" ]]; then
        log_error "SSH configuration file not found: $sshd_config"
        return 1
    fi
    
    # Check for password authentication
    if ! grep -qE "^PasswordAuthentication\s+no" "$sshd_config"; then
        log_error "⚠️  SSH Security: PasswordAuthentication is not explicitly disabled"
        log_error "Add to $sshd_config: PasswordAuthentication no"
        warnings=$((warnings + 1))
    else
        log_success "SSH password authentication disabled"
    fi
    
    # Check for root login
    if ! grep -qE "^PermitRootLogin\s+(no|prohibit-password)" "$sshd_config"; then
        log_warn "⚠️  SSH Security: PermitRootLogin should be 'no' or 'prohibit-password'"
        log_warn "Add to $sshd_config: PermitRootLogin prohibit-password"
        warnings=$((warnings + 1))
    else
        log_success "SSH root login properly configured"
    fi
    
    # Check for public key auth
    if ! grep -qE "^PubkeyAuthentication\s+yes" "$sshd_config"; then
        log_warn "⚠️  SSH Security: PubkeyAuthentication should be enabled"
        log_warn "Add to $sshd_config: PubkeyAuthentication yes"
        warnings=$((warnings + 1))
    else
        log_success "SSH public key authentication enabled"
    fi
    
    if [[ $warnings -gt 0 ]]; then
        log_error "SSH configuration has $warnings security issues"
        log_error "For set-and-forget operation, these MUST be fixed"
        echo ""
        if [[ "$AUTO_MODE" != "true" ]]; then
            read -p "Continue setup anyway? (yes/no): " confirm
            if [[ "$confirm" != "yes" ]]; then
                return 1
            fi
        else
            log_warn "Auto mode enabled - continuing despite SSH configuration issues"
        fi
    else
        log_success "SSH configuration is properly hardened"
    fi
    
    return 0
}

# NEW: Cloudflare API token validation
validate_cloudflare_tokens() {
    log_info "Validating Cloudflare API tokens..."
    
    local zone_id="$1"
    local dns_token_file="./secrets/.docker_secrets/caddy_cloudflare_dns_token"
    local firewall_token_file="./secrets/.docker_secrets/fail2ban_cloudflare_firewall_token"
    
    if [[ -z "$zone_id" ]]; then
        log_warn "CLOUDFLARE_ZONE_ID not set - skipping token validation"
        log_warn "You must set this in .env before starting services"
        return 0
    fi
    
    # Validate DNS token
    if [[ -f "$dns_token_file" ]]; then
        local dns_token
        dns_token=$(cat "$dns_token_file")
        
        if [[ -z "$dns_token" || "$dns_token" == "CHANGE_ME_DNS_TOKEN" ]]; then
            log_warn "Cloudflare DNS token not configured yet"
            log_warn "Configure it with: ./edit-secrets.sh"
            return 0
        fi
        
        log_info "Testing Cloudflare DNS token..."
        if ! curl -sf --max-time 10 \
            -H "Authorization: Bearer $dns_token" \
            "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?per_page=1" \
            | jq -e '.success == true' >/dev/null 2>&1; then
            log_error "Cloudflare DNS token validation failed"
            log_error "Token may be invalid or missing Zone:DNS:Edit permission"
            log_error "Generate token at: https://dash.cloudflare.com/profile/api-tokens"
            return 1
        fi
        log_success "Cloudflare DNS token validated"
    else
        log_warn "Cloudflare DNS token file not found - configure secrets first"
    fi
    
    # Validate Firewall token
    if [[ -f "$firewall_token_file" ]]; then
        local firewall_token
        firewall_token=$(cat "$firewall_token_file")
        
        if [[ -z "$firewall_token" || "$firewall_token" == "CHANGE_ME_FIREWALL_TOKEN" ]]; then
            log_warn "Cloudflare Firewall token not configured yet"
            log_warn "Configure it with: ./edit-secrets.sh"
            return 0
        fi
        
        log_info "Testing Cloudflare Firewall token..."
        if ! curl -sf --max-time 10 \
            -H "Authorization: Bearer $firewall_token" \
            "https://api.cloudflare.com/client/v4/zones/$zone_id/firewall/access_rules/rules?per_page=1" \
            | jq -e '.success == true' >/dev/null 2>&1; then
            log_error "Cloudflare Firewall token validation failed"
            log_error "Token may be invalid or missing Zone:Firewall Services:Edit permission"
            log_error "Generate token at: https://dash.cloudflare.com/profile/api-tokens"
            return 1
        fi
        log_success "Cloudflare Firewall token validated"
    else
        log_warn "Cloudflare Firewall token file not found - configure secrets first"
    fi
    
    return 0
}

# ENHANCED: Template-based environment file creation with SSH log detection - returns exit code
# ENHANCED: Template-based environment file creation with SSH log detection - returns exit code
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

    # Copy template
    if ! cp "$env_template" "$env_file"; then
        log_error "Failed to copy .env template"
        return 1
    fi

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n "$real_user")

    # Validate PUID/PGID values
    local user_id group_id
    user_id=$(id -u "$real_user")
    group_id=$(id -g "$real_user")

    # ENHANCED: Detect platform-specific SSH log path
    local detected_ssh_log_path
    detected_ssh_log_path=$(detect_ssh_log_path)

    # CRITICAL FIX: Validate all variables before sed operations
    if [[ -z "$DOMAIN" ]]; then
        log_error "DOMAIN variable is empty"
        return 1
    fi

    if [[ -z "$ADMIN_EMAIL" ]]; then
        log_error "ADMIN_EMAIL variable is empty"
        return 1
    fi

    if [[ -z "$user_id" ]] || [[ -z "$group_id" ]]; then
        log_error "Failed to get user/group IDs"
        return 1
    fi

    if [[ -z "$detected_ssh_log_path" ]]; then
        log_error "Failed to detect SSH log path"
        return 1
    fi

    # CRITICAL FIX: Escape special characters in variables for sed
    # This prevents sed errors with special characters like @, /, etc.
    local domain_escaped admin_email_escaped smtp_from_escaped ssh_log_escaped
    domain_escaped=$(printf '%s\n' "$DOMAIN" | sed 's/[&/\]/\\&/g')
    admin_email_escaped=$(printf '%s\n' "$ADMIN_EMAIL" | sed 's/[&/\]/\\&/g')
    smtp_from_escaped=$(printf '%s\n' "noreply@$DOMAIN" | sed 's/[&/\]/\\&/g')
    ssh_log_escaped=$(printf '%s\n' "$detected_ssh_log_path" | sed 's/[&/\]/\\&/g')

    # Populate template values using sed with escaped values
    # Use || true to prevent immediate exit on error, then check results
    local sed_errors=0
    
    sed -i "s|DOMAIN=.*|DOMAIN=$domain_escaped|" "$env_file" || ((sed_errors++))
    sed -i "s|ADMIN_EMAIL=.*|ADMIN_EMAIL=$admin_email_escaped|" "$env_file" || ((sed_errors++))
    sed -i "s|PUID=.*|PUID=$user_id|" "$env_file" || ((sed_errors++))
    sed -i "s|PGID=.*|PGID=$group_id|" "$env_file" || ((sed_errors++))
    sed -i "s|SMTP_FROM=.*|SMTP_FROM=$smtp_from_escaped|" "$env_file" || ((sed_errors++))
    sed -i "s|SSH_LOG_PATH=.*|SSH_LOG_PATH=$ssh_log_escaped|" "$env_file" || ((sed_errors++))

    if [[ $sed_errors -gt 0 ]]; then
        log_error "Failed to populate .env template values ($sed_errors errors)"
        log_error "Debug info:"
        log_error "  DOMAIN: $DOMAIN"
        log_error "  ADMIN_EMAIL: $ADMIN_EMAIL"
        log_error "  SSH_LOG_PATH: $detected_ssh_log_path"
        return 1
    fi

    # Set version pins if not using latest
    if [[ "$USE_LATEST" != "true" ]]; then
        if ! sed -i 's/#\(VAULTWARDEN_VERSION=.*\)/\1/' "$env_file" || \
           ! sed -i 's/#\(CADDY_VERSION=.*\)/\1/' "$env_file" || \
           ! sed -i 's/#\(FAIL2BAN_VERSION=.*\)/\1/' "$env_file"; then
            log_warn "Failed to enable pinned versions, continuing anyway"
        else
            log_info "Enabled pinned container versions for production stability"
        fi
    else
        log_info "Using latest container versions (development mode)"
    fi

    if ! chown "$real_user:$real_group" "$env_file" || ! chmod 644 "$env_file"; then
        log_error "Failed to set .env file permissions"
        return 1
    fi

    log_success "Environment file created from template: $env_file"
    log_success "SSH log path configured: $detected_ssh_log_path"

    # Show what needs manual configuration
    log_warn "MANUAL CONFIGURATION REQUIRED:"
    log_info "  1. Edit .env and set CLOUDFLARE_ZONE_ID"
    log_info "  2. Configure SMTP settings if using email notifications"
    log_info "  3. Update RCLONE_REMOTE_NAME if using offsite backups"

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

    if ! id "$real_user" >/dev/null 2>&1; then
        log_error "User $real_user does not exist"
        return 1
    fi

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
        if ! ensure_dir "$dir" 755; then
            log_error "Failed to create directory: $dir"
            return 1
        fi

        if ! chown "$real_user:$real_group" "$dir"; then
            log_error "Failed to set ownership for directory: $dir"
            return 1
        fi
    done

    # Secure secrets directories
    if ! chmod 700 "secrets" || ! chmod 700 "secrets/keys" || ! chmod 700 "secrets/.docker_secrets"; then
        log_error "Failed to secure secrets directories"
        return 1
    fi

    log_success "Project directories created."
    return 0
}

# STANDARDIZED: Enhanced entropy check - returns exit code
check_entropy() {
    log_info "Checking system entropy..."
    local entropy
    entropy=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo "0")

    if (( entropy >= ENTROPY_THRESHOLD )); then
        log_success "System entropy is sufficient ($entropy)"
        return 0
    fi

    log_warn "System entropy is low ($entropy). This is common on new VMs."

    # Wait up to ENTROPY_MAX_WAIT seconds for entropy to build up
    log_info "Waiting for entropy to increase (up to ${ENTROPY_MAX_WAIT}s)..."
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
    log_error "Key generation may be unsafe. Please reboot or wait longer."
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

    if [[ -f "$age_key_file" ]] && [[ "$FORCE" != "true" ]]; then
        log_info "Age key already exists, skipping generation."
        return 0
    fi

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n $real_user)

    if ! generate_age_key "$age_key_file" "$FORCE"; then
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

    if ! cat > "$sops_config" << EOF; then
creation_rules:
  - path_regex: secrets/secrets\\.yaml$
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

# STANDARDIZED: Returns exit code
create_secrets_template() {
    log_info "Creating secrets template..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create encrypted secrets template"
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
    if ! admin_token=$(generate_secure_string 32) || ! backup_pass=$(generate_secure_string 32); then
        log_error "Failed to generate secure strings"
        return 1
    fi

    # Create unencrypted template
    if ! cat > "$secrets_file" << EOF; then
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
        log_error "Failed to create secrets template"
        return 1
    fi

    # Encrypt with SOPS
    export SOPS_AGE_KEY_FILE="$PROJECT_ROOT/$age_key_file"

    if ! encrypt_sops_file "$secrets_file" "$age_key_file"; then
        log_error "Failed to encrypt secrets file"
        return 1
    fi

    if ! secure_file "$secrets_file" 600 || ! chown "$real_user:$real_group" "$secrets_file"; then
        log_error "Failed to secure secrets file"
        return 1
    fi

    log_success "Secrets template encrypted successfully"

    log_warn "IMPORTANT: Update the placeholder values:"
    log_info "  1. Run: ./edit-secrets.sh"
    log_info "  2. Generate bcrypt hash for admin_basic_auth_hash"
    log_info "  3. Add Cloudflare DNS API token"
    log_info "  4. Add Cloudflare Firewall API token"
    log_info "  5. Configure SMTP password if using email"

    return 0
}

# STANDARDIZED: Template-based docker compose creation - returns exit code
create_docker_compose() {
    log_info "Setting up Docker Compose configuration..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would copy and validate docker-compose.yml from template"
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

    # Validate template before copying
    log_info "Validating template: $compose_template"
    if ! safe_execute "Template validation" docker compose -f "$compose_template" config >/dev/null; then
        log_error "Template validation failed for $compose_template"
        log_info "Run 'docker compose -f $compose_template config' to debug."
        return 1
    fi
    log_success "Template validated successfully."

    # Copy template
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

    local failed_scripts=()

    for script in "${scripts[@]}"; do
        if [[ -f "$script" ]]; then
            if ! chmod +x "$script" || ! chown "$real_user:$real_group" "$script"; then
                failed_scripts+=("$script")
            fi
        fi
    done

    if ! find "lib" -name "*.sh" -exec chmod +x {} \; || \
       ! find "lib" -name "*.sh" -exec chown "$real_user:$real_group" {} \;; then
        log_error "Failed to set library script permissions"
        return 1
    fi

    if [[ ${#failed_scripts[@]} -gt 0 ]]; then
        log_error "Failed to set permissions for scripts: ${failed_scripts[*]}"
        return 1
    fi

    log_success "Script permissions set."
    return 0
}

# STANDARDIZED: Enhanced cleanup function - returns exit code
cleanup_setup_deps() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would remove haveged and cleanup"
        return 0
    fi

    log_info "Cleaning up setup dependencies..."

    # Stop haveged service
    if systemctl is-active --quiet haveged 2>/dev/null; then
        if ! systemctl stop haveged; then
            log_warn "Failed to stop haveged service"
        else
            log_success "haveged service stopped"
        fi
    fi

    # Remove haveged package
    if has_command haveged; then
        if apt-get remove --purge -y haveged >/dev/null 2>&1; then
            log_success "haveged package removed"
        else
            log_warn "Failed to remove haveged package - please remove manually"
        fi
    fi

    # Clean up package cache
    if apt-get autoremove -y >/dev/null 2>&1; then
        log_success "Package cleanup completed"
    else
        log_warn "Package autoremove failed - not critical"
    fi

    return 0
}

# ENHANCED: Main function with proper error handling and exit strategy
main() {
    log_header "VaultWarden-OCI Setup - Production Security Hardened"

    if [[ -z "$DOMAIN" ]] || [[ -z "$ADMIN_EMAIL" ]]; then 
        log_error "Domain and Email are required."
        show_help
        exit 1
    fi

    # Pre-flight checks
    log_info "=== Phase 1: Pre-flight System Checks ==="
    if ! is_root; then 
        log_error "This script must be run as root."
        exit 1
    fi
    log_success "Pre-flight checks passed."

    # Track setup phases and their success/failure
    local setup_phases=(
        "install_dependencies:Dependency Installation"
        "verify_dependencies:Dependency Verification"
        "setup_user_permissions:User Permissions"
        "create_env_file:Environment Configuration"
        "create_docker_compose:Docker Compose Setup"
        "setup_directories:Directory Creation"
        "generate_age_keys:Encryption Keys"
        "create_sops_config:SOPS Configuration"
        "create_secrets_template:Secrets Template"
        "set_script_permissions:Script Permissions"
        "setup_firewall:Firewall Configuration"
        "validate_ssh_config:SSH Hardening Validation"
        "cleanup_setup_deps:Setup Cleanup"
    )

    local failed_phases=()

    # Execute each phase and track results
    for phase_info in "${setup_phases[@]}"; do
        local phase_func="${phase_info%%:*}"
        local phase_name="${phase_info##*:}"

        log_info "=== Phase: $phase_name ==="

        # BEST PRACTICE FIX: Clear command path cache after installs
        if [[ "$phase_func" == "verify_dependencies" ]]; then
            log_debug "Clearing command path cache..."
            hash -r
        fi

        if ! $phase_func; then
            failed_phases+=("$phase_name")
            log_error "Phase failed: $phase_name"
            
            # BEST PRACTICE FIX: Halt on all critical failures
            if [[ "$phase_func" == "install_dependencies" || \
                  "$phase_func" == "verify_dependencies" || \
                  "$phase_func" == "create_env_file" || \
                  "$phase_func" == "setup_firewall" || \
                  "$phase_func" == "validate_ssh_config" || \
                  "$phase_func" == "generate_age_keys" || \
                  "$phase_func" == "create_sops_config" || \
                  "$phase_func" == "create_secrets_template" ]]; then
                log_error "Critical phase failed: $phase_name - stopping setup"
                log_error "Fix the issues and re-run setup"
                exit 1
            fi
        else
            log_success "Phase completed: $phase_name"
        fi
    done

    # Validate Cloudflare tokens if zone ID is configured
    local zone_id
    zone_id=$(get_config_value "CLOUDFLARE_ZONE_ID" "")
    if [[ -n "$zone_id" && "$zone_id" != "your_cloudflare_zone_id_here" ]]; then
        log_info "=== Phase: Cloudflare Token Validation ==="
        if ! validate_cloudflare_tokens "$zone_id"; then
            log_warn "Cloudflare token validation failed - configure tokens before starting services"
        fi
    fi

    # Final status determination
    if [[ ${#failed_phases[@]} -gt 0 ]]; then
        log_error "Setup completed with failures in the following phases:"
        for failed_phase in "${failed_phases[@]}"; do
            log_error "  - $failed_phase"
        done

        log_info "You may need to manually complete the failed phases and re-run setup."
        exit 1
    fi

    # Final success summary
    log_header "Setup Complete - Production Security Hardened"
    echo "Your VaultWarden instance is configured with:"
    echo ""
    echo "✅ Template-Based Configuration:"
    echo "   - docker-compose.yml copied from docker-compose.yml.example"  
    echo "   - .env file populated from .env.example template"
    echo "   - Easy maintenance via template files"
    echo ""
    echo "✅ Security Hardening:"
    echo "   - Firewall race condition fixed (fetch-before-reset)"
    echo "   - SSH hardening validation completed"
    echo "   - Cloudflare token validation ready"
    echo "   - Platform-specific SSH log detection"
    echo ""
    echo "✅ Caddy-Cloudflare Integration:"
    echo "   - DNS-01 ACME challenges for SSL certificates"  
    echo "   - Automatic Cloudflare IP range management"
    echo "   - Separate DNS and Firewall API tokens"
    echo ""
    echo "✅ Additional Features:"
    echo "   - SOPS + Age encrypted secrets"
    echo "   - UFW firewall configured with Cloudflare IP ranges"
    echo "   - Host OS automatic security updates enabled"
    echo "   - Secure (high-entropy) key generation"
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
    echo "🔐 Security: Your secrets are encrypted with Age + SOPS"
    echo "🌐 Domain: https://$DOMAIN"
    echo "📧 Admin: $ADMIN_EMAIL"
    echo "🔒 SSH: Hardening validation complete"

    exit 0
}

main "$@"
