#!/usr/bin/env bash
# update-cloudflare-ips.sh - Simplified Cloudflare IP updater for Caddy only
# Focuses on reliability over complex UFW management

set -euo pipefail

# --- Project Root Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# --- Source Libraries ---
source "lib/common.sh"
init_common_lib "$0"
# Source docker lib for docker compose commands (needed for reload)
source "lib/docker.sh"

# --- Configuration ---
readonly CLOUDFLARE_IPS_URL_V4="https://www.cloudflare.com/ips-v4"
readonly CLOUDFLARE_IPS_URL_V6="https://www.cloudflare.com/ips-v6"
readonly CADDY_IPS_FILE="caddy/cloudflare-ips.caddy"
readonly TEMP_IPS_FILE="/tmp/cloudflare-ips.tmp.$$" # Use PID for uniqueness
FORCE=false
DRY_RUN=false

# --- Help ---
show_help() {
    cat << 'EOF'
Cloudflare IP Updater for VaultWarden-OCI-NG (Simplified)

USAGE:
    ./update-cloudflare-ips.sh [OPTIONS]

OPTIONS:
    --force      Force update even if IPs haven't changed
    --dry-run    Show what would be done without making changes
    --help       Show this help

DESCRIPTION:
    Updates Cloudflare IP ranges for Caddy reverse proxy configuration.

    This simplified version focuses on:
    - Updating caddy/cloudflare-ips.caddy with current Cloudflare IPs
    - Reloading Caddy configuration
    - Reliable, low-risk operation

    UFW firewall should be configured once during setup to allow ports 80/443.
    Caddy's forwarded directive provides the security filtering.

    Should be run periodically via cron to keep IP ranges current.

EXAMPLES:
    ./update-cloudflare-ips.sh           # Update IP ranges
    ./update-cloudflare-ips.sh --force   # Force update
    ./update-cloudflare-ips.sh --dry-run # Preview changes
EOF
}

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --force) FORCE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Functions ---

# Fetch Cloudflare IP ranges
fetch_cloudflare_ips() {
    log_info "Fetching current Cloudflare IP ranges..."
    local ipv4_ranges ipv6_ranges

    if ! ipv4_ranges=$(curl -sfL --connect-timeout 10 --max-time 30 "$CLOUDFLARE_IPS_URL_V4"); then
        log_error "Failed to fetch Cloudflare IPv4 ranges from $CLOUDFLARE_IPS_URL_V4"
        return 1
    fi

    if ! ipv6_ranges=$(curl -sfL --connect-timeout 10 --max-time 30 "$CLOUDFLARE_IPS_URL_V6"); then
        log_error "Failed to fetch Cloudflare IPv6 ranges from $CLOUDFLARE_IPS_URL_V6"
        return 1
    fi

    # Validate and combine ranges
    {
        echo "# IPv4 ranges"
        # Ensure only valid CIDR notation lines are included
        echo "$ipv4_ranges" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' | sort -V
        echo ""
        echo "# IPv6 ranges"
         # Ensure only valid CIDR notation lines are included
        echo "$ipv6_ranges" | grep -E '^[0-9a-fA-F:]+/[0-9]+$' | sort
    } > "$TEMP_IPS_FILE" || { log_error "Failed to write to temp file $TEMP_IPS_FILE"; return 1; }

    local ipv4_count ipv6_count
    ipv4_count=$(grep -cE '^[0-9]+\.' "$TEMP_IPS_FILE" || echo 0)
    ipv6_count=$(grep -cE '^[0-9a-fA-F:]+' "$TEMP_IPS_FILE" || echo 0)

    # Basic sanity check on counts
    if [[ $ipv4_count -lt 8 ]] || [[ $ipv6_count -lt 3 ]]; then
        log_error "Received too few IP ranges (IPv4: $ipv4_count, IPv6: $ipv6_count). Aborting update as data seems incorrect."
        log_debug "Expected at least 8 IPv4 and 3 IPv6 ranges from Cloudflare."
        return 1
    fi

    log_success "Fetched $ipv4_count IPv4 and $ipv6_count IPv6 Cloudflare ranges"
    return 0
}

# Check if IP ranges have changed
ips_have_changed() {
    if [[ ! -f "$CADDY_IPS_FILE" ]]; then
        log_debug "Caddy IP file '$CADDY_IPS_FILE' doesn't exist, treating as changed."
        return 0  # File doesn't exist, definitely changed
    fi

    # Extract current IPs from Caddy file for comparison (only the IP ranges)
    local current_ips new_ips
    # Extract only the IP/CIDR parts, ignoring comments and directives
    current_ips=$(grep -oE '[0-9a-fA-F.:/]+' "$CADDY_IPS_FILE" | grep -E '(\.|:)' | sort || echo "")
    new_ips=$(grep -oE '^[0-9a-fA-F.:/]+$' "$TEMP_IPS_FILE" | grep -E '(\.|:)' | sort) # Match whole line

    if [[ "$current_ips" != "$new_ips" ]]; then
        log_debug "IP ranges comparison shows changes."
        return 0  # Changed
    else
        log_debug "IP ranges comparison shows no changes."
        return 1  # Not changed
    fi
}

# Update Caddy configuration file
update_caddy_config() {
    log_info "Updating Caddy IP configuration file: $CADDY_IPS_FILE"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would update Caddy configuration file $CADDY_IPS_FILE"
        log_info "[DRY RUN] New IP ranges would be:"
        cat "$TEMP_IPS_FILE"
        return 0
    fi

    local temp_caddy_file="$CADDY_IPS_FILE.new.$$"
    # Create Caddy configuration format
    cat > "$temp_caddy_file" << EOF
# Cloudflare IP ranges for request filtering
# Updated automatically by update-cloudflare-ips.sh. Do not edit manually.
# Last updated: $(date -uIs)

@cloudflare {
    # Cloudflare IPv4 ranges - Updated automatically
EOF

    # Add IPv4 ranges
    grep -E '^[0-9]+\.' "$TEMP_IPS_FILE" | while IFS= read -r ip; do
        echo "    remote_ip $ip" >> "$temp_caddy_file"
    done

    cat >> "$temp_caddy_file" << EOF

    # Cloudflare IPv6 ranges - Updated automatically
EOF

    # Add IPv6 ranges
    grep -E '^[0-9a-fA-F:]+' "$TEMP_IPS_FILE" | while IFS= read -r ip; do
        echo "    remote_ip $ip" >> "$temp_caddy_file"
    done

    echo "}" >> "$temp_caddy_file"

    # Set permissions/ownership based on existing file if possible
    if [[ -f "$CADDY_IPS_FILE" ]]; then
        chown --reference="$CADDY_IPS_FILE" "$temp_caddy_file" 2>/dev/null || true
        chmod --reference="$CADDY_IPS_FILE" "$temp_caddy_file" 2>/dev/null || true
    else
        # Ensure caddy directory exists if file doesn't
        mkdir -p "$(dirname "$CADDY_IPS_FILE")"
        chmod 644 "$temp_caddy_file" 2>/dev/null || true
        # Attempt to set ownership based on parent dir if possible
        chown --reference="$(dirname "$CADDY_IPS_FILE")" "$temp_caddy_file" 2>/dev/null || true
    fi

    # Atomic move
    if mv "$temp_caddy_file" "$CADDY_IPS_FILE"; then
        log_success "Updated Caddy configuration file: $CADDY_IPS_FILE"
        return 0
    else
        log_error "Failed to move temporary file '$temp_caddy_file' to final location '$CADDY_IPS_FILE'"
        rm -f "$temp_caddy_file" # Clean up temp file on failure
        return 1
    fi
}

# Validate Caddy configuration using docker exec
validate_caddy_config() {
    log_info "Validating Caddy configuration..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would validate Caddy configuration using 'docker compose exec'"
        return 0
    fi

    # Check Docker availability first
    if ! require_docker; then
        log_warn "Docker not available, cannot validate Caddy config."
        return 1 # Treat as failure if we can't check
    fi

    # Check if Caddy container exists and is running
    if docker compose ps caddy --format json 2>/dev/null | jq -r '.State // "not_found"' 2>/dev/null | grep -q running; then
        log_debug "Validating configuration via running Caddy container..."
        # Use -T to avoid TTY allocation issues in cron
        if docker compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
            log_success "Caddy configuration validation passed."
            return 0
        else
            log_error "Caddy configuration validation FAILED. Check Caddy logs or manually run:"
            log_error "  docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile"
            return 1
        fi
    else
        # If container isn't running, we can't validate live, but the syntax should be okay
        # Proceed cautiously
        log_warn "Caddy container is not running. Cannot perform live validation."
        log_info "Assuming configuration syntax is okay based on generation."
        return 0
    fi
}

# Reload Caddy configuration using docker exec
reload_caddy() {
    log_info "Reloading Caddy configuration..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would reload Caddy configuration via 'docker compose exec caddy caddy reload'"
        return 0
    fi

    # Check Docker availability
    if ! require_docker; then
        log_error "Docker not available, cannot reload Caddy."
        return 1
    fi

    # Check if Caddy service is running
    if ! is_service_running "caddy"; then
        log_warn "Caddy service is not running. Configuration file updated, but reload skipped."
        # Not a failure of the update script itself if Caddy is stopped.
        return 0
    fi

    # Attempt reload using docker compose exec
    log_info "Attempting graceful Caddy reload..."
    # Use -T to avoid TTY issues
    if docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        log_success "Caddy configuration reloaded gracefully."
        return 0
    else
        log_warn "Graceful reload failed. Check Caddy logs for detailed errors:"
        log_warn "  docker compose logs caddy | tail -n 50"
        log_info "Attempting container restart as fallback..."
        if docker compose restart caddy >/dev/null 2>&1; then
            log_success "Caddy container restarted successfully."
            sleep 5 # Allow a moment for Caddy to start
            # Maybe add a quick health check here?
            return 0
        else
            log_error "Failed to restart Caddy container after failed reload."
            log_error "Manual intervention required to apply new Caddy configuration."
            return 1
        fi
    fi
}

# Cleanup function for temporary file
cleanup() {
    log_debug "Cleaning up temporary file: $TEMP_IPS_FILE"
    rm -f "$TEMP_IPS_FILE"
}

# --- Main Execution ---
main() {
    log_header "Cloudflare IP Updater for VaultWarden-OCI-NG (Simplified Caddy-Only)"

    # Setup cleanup trap to remove temp file on exit/error
    trap cleanup EXIT INT TERM HUP

    # Check prerequisites
    require_commands curl grep sort mv || exit 1

    # Fetch current IP ranges
    if ! fetch_cloudflare_ips; then
        # Error already logged by function
        exit 1
    fi

    # Check if update is needed (or forced)
    if ! ips_have_changed && [[ "$FORCE" != "true" ]]; then
        log_success "Cloudflare IP ranges have not changed. No update needed."
        # Successfully determined no update needed
        exit 0
    fi

    if [[ "$FORCE" == "true" ]]; then
        log_info "Forcing update (--force specified)."
    else
        log_info "Cloudflare IP ranges have changed. Proceeding with update..."
    fi

    # Create backup of current config (if it exists)
    local backup_file="${CADDY_IPS_FILE}.backup.$(date +%s)"
    if [[ -f "$CADDY_IPS_FILE" && "$DRY_RUN" != "true" ]]; then
        if cp "$CADDY_IPS_FILE" "$backup_file"; then
            log_debug "Created backup of current Caddy IP list: $backup_file"
        else
            log_warn "Could not create backup of current Caddy IP list."
        fi
    fi

    # Update Caddy configuration file
    if ! update_caddy_config; then
        log_error "Failed to update Caddy configuration file. Aborting."
        # Attempt to restore backup if it exists
        if [[ -f "$backup_file" ]]; then
            log_info "Attempting to restore backup: $backup_file"
            cp "$backup_file" "$CADDY_IPS_FILE" 2>/dev/null || log_warn "Failed to restore backup."
        fi
        exit 1
    fi

    # Validate the new configuration *before* reloading Caddy
    if ! validate_caddy_config; then
        log_error "New Caddy configuration is invalid. Update aborted."
        # Restore backup
        if [[ -f "$backup_file" && "$DRY_RUN" != "true" ]]; then
            log_info "Restoring previous Caddy IP list from backup: $backup_file"
            if cp "$backup_file" "$CADDY_IPS_FILE"; then
                 log_success "Backup restored successfully."
            else
                 log_error "CRITICAL: Failed to restore backup after validation error. Manual fix required for $CADDY_IPS_FILE."
                 # Exiting here might be dangerous if Caddy tries to reload a bad config later.
                 # Maybe force a Caddy restart with the restored (hopefully good) config?
            fi
        else
            log_error "CRITICAL: Validation failed and no backup found. Manual fix required for $CADDY_IPS_FILE."
        fi
        exit 1
    fi

    # Reload Caddy only if validation passed
    local reload_status=0
    reload_caddy || reload_status=$? # Capture exit status of reload

    # Final Summary
    echo ""
    log_header "Update Summary"
    local ipv4_count ipv6_count
    ipv4_count=$(grep -cE '^[0-9]+\.' "$TEMP_IPS_FILE")
    ipv6_count=$(grep -cE '^[0-9a-fA-F:]+' "$TEMP_IPS_FILE")
    log_info "IP ranges fetched: IPv4=$ipv4_count, IPv6=$ipv6_count"
    log_success "Caddy config file updated: $CADDY_IPS_FILE"

    if [[ $reload_status -eq 0 ]]; then
        log_success "Caddy configuration reloaded/restarted successfully."
        log_info "Status: Update applied and active."
        exit 0
    else
        log_error "Caddy reload/restart FAILED."
        log_error "Status: Caddy config file updated, but changes are NOT active."
        log_error "Manual Caddy restart required: docker compose restart caddy"
        exit 1 # Exit with error code if reload failed
    fi
}

# --- Script Entry Point ---
main "$@"

