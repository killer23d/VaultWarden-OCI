#!/usr/bin/env bash
# Replacement functions for setup.sh
# These replace the heredoc-based file creation with template copying

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

# Remove the old caddy config creation since we're keeping existing approach
# The Caddyfile is already correctly maintained as a static file

# Updated main function section (replace the relevant part in main())
setup_configuration_files() {
    log_info "=== Phase 3: Generating Project Configuration ==="
    
    if ! setup_user_permissions; then
        log_error "Failed to setup user permissions"
        return 1
    fi
    
    if ! create_env_file; then
        log_error "Failed to create .env file"
        return 1
    fi
    
    if ! create_docker_compose; then
        log_error "Failed to setup docker-compose.yml"
        return 1
    fi
    
    if ! setup_directories; then
        log_error "Failed to create directories"
        return 1
    fi
    
    if ! generate_age_keys; then
        log_error "Failed to generate encryption keys"
        return 1
    fi
    
    if ! create_sops_config; then
        log_error "Failed to create SOPS configuration"
        return 1
    fi
    
    if ! create_secrets_template; then
        log_error "Failed to create secrets template"
        return 1
    fi
    
    # Note: create_caddy_config() removed since Caddyfile is maintained as static file
    
    if ! set_script_permissions; then
        log_error "Failed to set script permissions"
        return 1
    fi
    
    log_success "Project configuration generated successfully."
    return 0
}