#!/usr/bin/env bash
# setup.sh - VaultWarden-OCI Setup Script with Caddy-Cloudflare Integration

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

    # --- START P3 FIX: Add unattended-upgrades ---
    log_info "Installing and enabling automatic security updates (unattended-upgrades)..."
    if ! apt-get install -y unattended-upgrades; then
        log_warn "Could not install 'unattended-upgrades'. Host OS security patches will be manual."
    else
        # Reconfigure to enable security updates automatically
        echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
        dpkg-reconfigure -f noninteractive unattended-upgrades
        log_success "Host OS automatic security updates enabled."
    fi
    # --- END P3 FIX ---

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

setup_firewall() {
    log_info "Configuring UFW firewall..."
    if [[ "$DRY_RUN" == "true" ]]; then 
        log_info " Would configure firewall rules"
        return 0
    fi
    
    if ! has_command ufw; then 
        log_warn "UFW command not found, skipping."
        return 0
    fi

    local ssh_port
    ssh_port=$(get_config_value "SSH_PORT" "22")
    if [[ -z "$ssh_port" ]]; then
        log_error "SSH_PORT is not defined. Aborting firewall setup to prevent lockout."
        return 1
    fi

    log_info "Applying firewall rules..."
    ufw --force reset >/dev/null
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow "$ssh_port/tcp" comment "SSH" >/dev/null

    # Verify SSH rule was added
    if ! ufw status | grep -q -E "$ssh_port/tcp.*ALLOW"; then
        log_error "CRITICAL: Failed to add SSH allow rule for port $ssh_port."
        log_error "Aborting firewall activation to prevent SSH lockout."
        return 1
    fi
    log_success "SSH allow rule for port $ssh_port verified."

    ufw allow 80/tcp comment "HTTP" >/dev/null
    ufw allow 443/tcp comment "HTTPS" >/dev/null

    log_info "Enabling UFW firewall..."
    if echo "y" | ufw enable >/dev/null; then
        log_success "Firewall configured and enabled successfully."
    else
        log_error "Failed to enable UFW. Please enable it manually: sudo ufw enable"
        return 1
    fi
}

create_env_file() {
    log_info "Creating environment configuration file (.env)..."
    local env_file="$PROJECT_ROOT/.env"
    
    if [[ "$DRY_RUN" == "true" ]]; then 
        log_info " Would create/update .env file"
        return 0
    fi
    
    if [[ -f "$env_file" ]] && [[ "$FORCE" != "true" ]]; then
        log_info ".env file already exists, skipping creation."
        return 0
    fi
    
    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n $real_user)

    # Create .env file with caddy-cloudflare configuration
    cat > "$env_file" << EOF
# VaultWarden-OCI Configuration - Enhanced for Caddy-Cloudflare
# Generated on $(date)

# === Core Configuration ===
DOMAIN=$DOMAIN
ADMIN_EMAIL=$ADMIN_EMAIL
TZ=UTC
COMPOSE_PROJECT_NAME=vaultwarden

# === User/Group Configuration ===
PUID=$(id -u $real_user)
PGID=$(id -g $real_user)

# === Project Paths ===
PROJECT_STATE_DIR=/var/lib/vaultwarden

# === Container Versions (Pin for production stability) ===
EOF

    if [[ "$USE_LATEST" == "true" ]]; then
        cat >> "$env_file" << EOF
# Using latest versions (development mode)
#VAULTWARDEN_VERSION=latest
#CADDY_VERSION=latest  
#FAIL2BAN_VERSION=latest
EOF
    else
        cat >> "$env_file" << EOF
# Pinned versions (production recommended)
VAULTWARDEN_VERSION=1.31.0
CADDY_VERSION=2.8.4
FAIL2BAN_VERSION=1.1.0
EOF
    fi

    cat >> "$env_file" << EOF

# === VaultWarden Configuration ===
SIGNUPS_ALLOWED=false
INVITATIONS_ALLOWED=true
EMERGENCY_ACCESS_ALLOWED=true
SENDS_ALLOWED=true
WEB_VAULT_ENABLED=true
WEBSOCKET_ENABLED=false
PUSH_ENABLED=false

# === SMTP Configuration (Optional) ===
SMTP_HOST=
SMTP_PORT=587
SMTP_SECURITY=starttls
SMTP_USERNAME=
SMTP_FROM=noreply@$DOMAIN
SMTP_FROM_NAME=VaultWarden

# === Cloudflare Configuration (REQUIRED) ===
CLOUDFLARE_ZONE_ID=your_zone_id_here

# === Resource Limits (Tuned for 1 OCPU, 6GB RAM OCI Flex) ===
VAULTWARDEN_CPU_LIMIT=0.7
VAULTWARDEN_MEMORY_LIMIT=1.5g
VAULTWARDEN_CPU_RESERVATION=0.2
VAULTWARDEN_MEMORY_RESERVATION=256m

CADDY_CPU_LIMIT=0.2
CADDY_MEMORY_LIMIT=256m
CADDY_CPU_RESERVATION=0.1
CADDY_MEMORY_RESERVATION=64m

FAIL2BAN_CPU_LIMIT=0.1
FAIL2BAN_MEMORY_LIMIT=128m
FAIL2BAN_CPU_RESERVATION=0.05
FAIL2BAN_MEMORY_RESERVATION=64m

# === Backup Configuration ===
DB_BACKUP_RETENTION_DAYS=14
FULL_BACKUP_RETENTION_DAYS=30
EMERGENCY_BACKUP_RETENTION_DAYS=90
BACKUP_VERIFICATION_MODE=quick_check
RCLONE_REMOTE_NAME=CHANGE_ME

# === SSH Configuration ===
SSH_PORT=22
EOF

    chown "$real_user:$real_group" "$env_file"
    chmod 644 "$env_file"
    
    log_success "Environment configuration file created: $env_file"
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

create_caddy_config() {
    log_info "Creating Caddy configuration..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info " Would create Caddy configuration files"
        return 0
    fi
    
    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n $real_user)

    # Create enhanced Caddyfile for caddy-cloudflare
    cat > "caddy/Caddyfile" << 'EOF'
# Enhanced Caddyfile for CaddyBuilds/caddy-cloudflare with automatic IP management
{
    # Global ACME DNS configuration
    # Caddy automatically uses the CLOUDFLARE_API_TOKEN_FILE env var
    # (set in docker-compose.yml) when this directive is present.
    acme_dns cloudflare
    
    # Global server configuration with automatic Cloudflare IP management
    servers {
        # Trust Cloudflare IPs automatically (updated by caddy-cloudflare-ip module)
        trusted_proxies cloudflare
        # Use the correct Cloudflare connecting IP header
        client_ip_headers Cf-Connecting-Ip X-Forwarded-For
    }
}

{$DOMAIN} {
    log {
        output file /logs/access.log {
            roll_size 10MB
            roll_keep 5
        }
        format json
    }

    # Enhanced security headers
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        Content-Security-Policy "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self' wss: https:; frame-src 'self'; object-src 'none'; base-uri 'self';"
        -Server
    }

    # Admin panel protection with bcrypt basic auth
    @admin path /admin*
    handle @admin {
        header {
            Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self' wss: https:; frame-src 'self'; object-src 'none'; base-uri 'self';"
        }
        
        basic_auth {
            admin {file /run/secrets/admin_basic_auth_hash}
        }

        reverse_proxy vaultwarden_app:80 {
            header_up X-Real-IP {http.request.header.Cf-Connecting-Ip}
            header_up X-Forwarded-For {http.request.header.Cf-Connecting-Ip}
        }
    }

    # Main application with enhanced IP handling
    handle {
        @malicious_ua header User-Agent *sqlmap* *nikto* *nmap* *acunetix*
        respond @malicious_ua 403

        # WebSocket support for live sync (uncomment if WEBSOCKET_ENABLED=true in .env)
        # reverse_proxy /notifications/hub* vaultwarden_app:3012

        reverse_proxy vaultwarden_app:80 {
            header_up X-Real-IP {http.request.header.Cf-Connecting-Ip}
            header_up X-Forwarded-For {http.request.header.Cf-Connecting-Ip}
        }
    }
}

# Redirect www subdomain
www.{$DOMAIN} {
    redir https://{$DOMAIN}{uri} 301
}

# Security catch-all
:80, :443 {
    respond "Not Found" 404
}
EOF

    chown "$real_user:$real_group" "caddy/Caddyfile"
    
    log_success "Caddy configuration created."
    return 0
}

create_docker_compose() {
    log_info "Creating Docker Compose configuration..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info " Would create docker-compose.yml"
        return 0
    fi
    
    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n $real_user)

    # Create enhanced docker-compose.yml with caddy-cloudflare
    cat > "docker-compose.yml" << 'EOF'
# VaultWarden-OCI Docker Compose - Enhanced with Caddy-Cloudflare
services:
  # VaultWarden Password Manager
  vaultwarden:
    image: vaultwarden/server:${VAULTWARDEN_VERSION:-latest}
    container_name: vaultwarden_app
    restart: unless-stopped
    user: "${PUID:-1000}:${PGID:-1000}"
    environment:
      DOMAIN: "https://${DOMAIN}"
      ROCKET_PORT: 80
      ROCKET_ADDRESS: 0.0.0.0
      ADMIN_TOKEN_FILE: "/run/secrets/admin_token"
      SMTP_HOST: "${SMTP_HOST:-}"
      SMTP_FROM: "${SMTP_FROM:-noreply@${DOMAIN}}"
      SMTP_FROM_NAME: "${SMTP_FROM_NAME:-VaultWarden}"
      SMTP_PORT: "${SMTP_PORT:-587}"
      SMTP_SECURITY: "${SMTP_SECURITY:-starttls}"
      SMTP_USERNAME: "${SMTP_USERNAME:-}"
      SMTP_PASSWORD_FILE: "/run/secrets/smtp_password"
      PUSH_ENABLED: "${PUSH_ENABLED:-false}"
      PUSH_INSTALLATION_ID_FILE: "/run/secrets/push_installation_id"
      PUSH_INSTALLATION_KEY_FILE: "/run/secrets/push_installation_key"
      SIGNUPS_ALLOWED: "${SIGNUPS_ALLOWED:-false}"
      INVITATIONS_ALLOWED: "${INVITATIONS_ALLOWED:-true}"
      EMERGENCY_ACCESS_ALLOWED: "${EMERGENCY_ACCESS_ALLOWED:-true}"
      SENDS_ALLOWED: "${SENDS_ALLOWED:-true}"
      WEB_VAULT_ENABLED: "${WEB_VAULT_ENABLED:-true}"
      DATABASE_MAX_CONNS: 10
      ROCKET_WORKERS: 10
      WEBSOCKET_ENABLED: "${WEBSOCKET_ENABLED:-false}"
      WEBSOCKET_ADDRESS: "0.0.0.0" 
      WEBSOCKET_PORT: 3012
      LOG_LEVEL: info
      EXTENDED_LOGGING: true
      LOG_FILE: "/data/vaultwarden.log"
      TZ: "${TZ:-UTC}"
    volumes:
      - "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/data:/data"
      - "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/logs/vaultwarden:/logs"
    secrets:
      - admin_token
      - smtp_password
      - push_installation_id
      - push_installation_key
    networks:
      - vaultwarden_network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/alive"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    deploy:
      resources:
        limits:
          cpus: '${VAULTWARDEN_CPU_LIMIT:-0.7}'
          memory: '${VAULTWARDEN_MEMORY_LIMIT:-1.5g}'
        reservations:
          cpus: '${VAULTWARDEN_CPU_RESERVATION:-0.2}'
          memory: '${VAULTWARDEN_MEMORY_RESERVATION:-256m}'

  # Caddy Reverse Proxy with Cloudflare Integration
  caddy:
    image: ghcr.io/caddybuilds/caddy-cloudflare:${CADDY_VERSION:-latest}
    container_name: vaultwarden_caddy
    restart: unless-stopped
    user: "${PUID:-1000}:${PGID:-1000}"
    environment:
      DOMAIN: "${DOMAIN}"
      EMAIL: "${ADMIN_EMAIL}"
      # Use file-based secret for DNS API token
      CLOUDFLARE_API_TOKEN_FILE: "/run/secrets/caddy_cloudflare_dns_token"
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - "./caddy/Caddyfile:/etc/caddy/Caddyfile:ro"
      - "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/caddy/data:/data"
      - "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/caddy/config:/config"
      - "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/logs/caddy:/logs"
    secrets:
      - admin_basic_auth_hash
      - caddy_cloudflare_dns_token
    networks:
      - vaultwarden_network
    depends_on:
      vaultwarden:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "caddy", "list-certificates"]
      interval: 1m
      timeout: 15s
      retries: 5
      start_period: 1m
    deploy:
      resources:
        limits:
          cpus: '${CADDY_CPU_LIMIT:-0.2}'
          memory: '${CADDY_MEMORY_LIMIT:-256m}'
        reservations:
          cpus: '${CADDY_CPU_RESERVATION:-0.1}'
          memory: '${CADDY_MEMORY_RESERVATION:-64m}'
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  # Fail2Ban Intrusion Prevention
  fail2ban:
    image: crazymax/fail2ban:${FAIL2BAN_VERSION:-latest}
    platform: linux/arm64
    container_name: vaultwarden_fail2ban
    restart: unless-stopped
    environment:
      F2B_LOG_LEVEL: INFO
      F2B_LOG_TARGET: /data/fail2ban.log
      TZ: "${TZ:-UTC}"
      CLOUDFLARE_ZONE_ID: "${CLOUDFLARE_ZONE_ID}"
    volumes:
      - "./fail2ban/jail.d:/etc/fail2ban/jail.d:ro"
      - "./fail2ban/filter.d:/etc/fail2ban/filter.d:ro"
      - "./fail2ban/action.d:/etc/fail2ban/action.d:ro"
      - "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/fail2ban:/data"
      - "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/logs/caddy:/var/log/caddy:ro"
      - "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/logs/fail2ban:/var/log"
    secrets:
      - fail2ban_cloudflare_firewall_token
    networks:
      - vaultwarden_network
    healthcheck:
      test: ["CMD", "fail2ban-client", "status"]
      interval: 1m
      timeout: 10s
      retries: 3
      start_period: 30s
    deploy:
      resources:
        limits:
          cpus: '${FAIL2BAN_CPU_LIMIT:-0.1}'
          memory: '${FAIL2BAN_MEMORY_LIMIT:-128m}'
        reservations:
          cpus: '${FAIL2BAN_CPU_RESERVATION:-0.05}'
          memory: '${FAIL2BAN_MEMORY_RESERVATION:-64m}'
    cap_add:
      - NET_ADMIN
      - NET_RAW

secrets:
  admin_token:
    file: ./secrets/.docker_secrets/admin_token
  admin_basic_auth_hash:
    file: ./secrets/.docker_secrets/admin_basic_auth_hash
  smtp_password:
    file: ./secrets/.docker_secrets/smtp_password
  push_installation_id:
    file: ./secrets/.docker_secrets/push_installation_id
  push_installation_key:
    file: ./secrets/.docker_secrets/push_installation_key
  caddy_cloudflare_dns_token:
    file: ./secrets/.docker_secrets/caddy_cloudflare_dns_token
  fail2ban_cloudflare_firewall_token:
    file: ./secrets/.docker_secrets/fail2ban_cloudflare_firewall_token

networks:
  vaultwarden_network:
    driver: bridge
    name: ${COMPOSE_PROJECT_NAME:-vaultwarden}_vaultwarden_network
    ipam:
      config:
        - subnet: 172.20.0.0/16
EOF

    chown "$real_user:$real_group" "docker-compose.yml"
    
    log_success "Docker Compose configuration created."
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
    log_header "VaultWarden-OCI Setup - Enhanced for Caddy-Cloudflare"
    
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
    if ! setup_user_permissions || ! create_env_file || ! setup_directories || ! generate_age_keys || ! create_sops_config || ! create_secrets_template || ! create_caddy_config || ! create_docker_compose || ! set_script_permissions; then
        log_error "Configuration generation failed. Please review errors and re-run."
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
    log_header "Setup Complete - Enhanced for Caddy-Cloudflare"
    echo "Your VaultWarden instance is configured with:"
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
    echo "   - CPU limits tuned for 1 OCPU (1.0 total limit)"
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
    echo ""
    echo "🔐 Security: Your secrets are encrypted with Age + SOPS"
    echo "🌐 Domain: https://$DOMAIN"
    echo "📧 Admin: $ADMIN_EMAIL"
}

main "$@"
