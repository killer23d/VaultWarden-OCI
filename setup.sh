#!/usr/bin/env bash
# setup.sh - VaultWarden-OCI-Simplified Setup Script
# MODIFIED: Restructured into idempotent phases with transactional error handling.

set -euo pipefail

# --- Project Root Resolution & Library Sourcing ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"
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
    sudo./setup.sh

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
    sudo./setup.sh --domain vault.example.com --email admin@example.com

    # Automated production setup with pinned versions
    sudo./setup.sh --domain vault.example.com --email admin@example.com --auto
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
if]; then
    log_error "Domain is required. Use --domain your-domain.com"
    show_help
    exit 1
fi

if]; then
    log_error "Admin email is required. Use --email admin@example.com"
    show_help
    exit 1
fi

# --- Dependency Installation & System Functions ---
# (All helper functions like install_dependencies, setup_firewall, etc. are included here)

install_dependencies() {
    if]; then
        log_info "Skipping dependency installation (--skip-deps specified)."
        return 0
    fi
    if]; then
        log_info " Would install system dependencies"
        return 0
    fi

    log_info "Installing system dependencies..."
    apt-get update -qq
    local basic_packages=("age" "make" "nano" "rclone" "sqlite3" "jq" "mailutils" "ufw" "curl" "wget" "unzip" "git" "gpg" "coreutils")
    export DEBIAN_FRONTEND=noninteractive
    if! apt-get install -y "${basic_packages[@]}"; then
        log_error "Failed to install basic dependencies."
        return 1
    fi
    #... (Docker and SOPS installation logic would be here)
    log_success "Dependencies installed."
    return 0
}

verify_dependencies() {
    #... (Verification logic would be here)
    return 0
}

setup_user_permissions() {
    #... (Permission logic would be here)
    return 0
}

setup_firewall() {
    log_info "Configuring UFW firewall..."
    if]; then log_info " Would configure firewall rules"; return 0; fi
    if! has_command ufw; then log_warn "UFW command not found, skipping."; return 0; fi

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

    # --- TRANSACTIONAL VERIFICATION ---
    if! ufw status | grep -q -E "$ssh_port/tcp.*ALLOW"; then
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
    if]; then log_info " Would create/update.env file"; return 0; fi
    if [[ -f "$env_file" ]] &&]; then
        log_info ".env file already exists, skipping creation."
        return 0
    fi

    cp.env.example "$env_file"
    sed -i "s|^#*DOMAIN=.*|DOMAIN=$DOMAIN|" "$env_file"
    sed -i "s|^#*ADMIN_EMAIL=.*|ADMIN_EMAIL=$ADMIN_EMAIL|" "$env_file"
    
    local real_user real_uid real_gid
    real_user=$(get_real_user)
    real_uid=$(id -u "$real_user")
    real_gid=$(id -g "$real_user")
    sed -i "s/^PUID=.*/PUID=$real_uid/" "$env_file"
    sed -i "s/^PGID=.*/PGID=$real_gid/" "$env_file"

    #... (other sed replacements and ownership logic)
    log_success "Environment configuration file created: $env_file"
}

setup_directories() {
    #... (Directory creation logic)
    return 0
}

generate_age_keys() {
    #... (Key generation logic)
    return 0
}

create_sops_config() {
    #... (SOPS config creation logic)
    return 0
}

create_secrets_template() {
    #... (Secrets template creation logic)
    return 0
}

set_script_permissions() {
    #... (Script permission logic)
    return 0
}

# --- MODIFIED: Main Execution with Phased Logic ---
main() {
    log_header "VaultWarden-OCI-Simplified Setup"
    if]; then log_error "Domain and Email are required."; show_help; exit 1; fi

    # --- PHASE 1: PRE-FLIGHT CHECKS ---
    log_info "=== Phase 1: Pre-flight System Checks ==="
    if! is_root; then log_error "This script must be run as root."; exit 1; fi
    log_success "Pre-flight checks passed."

    # --- PHASE 2: DEPENDENCY INSTALLATION ---
    log_info "=== Phase 2: Installing Dependencies ==="
    if! install_dependencies; then
        log_error "Dependency installation failed. Please review errors and re-run."
        exit 1
    fi
    if! verify_dependencies; then
        log_error "Dependency verification failed."
        exit 1
    fi
    log_success "All dependencies installed and verified."

    # --- PHASE 3: CONFIGURATION GENERATION ---
    log_info "=== Phase 3: Generating Project Configuration ==="
    if! setup_user_permissions ||! create_env_file ||! setup_directories ||! generate_age_keys ||! create_sops_config ||! create_secrets_template ||! set_script_permissions; then
        log_error "Configuration generation failed. Please review errors and re-run."
        exit 1
    fi
    log_success "Project configuration generated successfully."

    # --- PHASE 4: SYSTEM STATE ACTIVATION ---
    log_info "=== Phase 4: Activating System State ==="
    if! setup_firewall; then
        log_error "Firewall setup failed. The system is NOT secured."
        exit 1
    fi
    log_success "System state activated successfully."

    # --- FINAL SUMMARY ---
    log_header "Setup Complete"
    # (Final instructions remain the same)
    echo "Next Steps:"
    echo "  1. Configure secrets: make edit-secrets"
    echo "  2. Update.env file: nano.env"
    echo "  3. Start services: make up"
}

main "$@"
