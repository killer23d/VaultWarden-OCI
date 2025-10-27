#!/usr/bin/env bash
# update-cloudflare-ips.sh - Fetches Cloudflare IPs, updates Caddy config,
# reconfigures the UFW firewall, and reloads Caddy.
# This script is designed to be idempotent and safe to run automatically.

set -euo pipefail

# --- Project Root Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# --- Source Libraries ---
# Must source common.sh *before* init, but init must be called
source "lib/common.sh"
init_common_lib "$0"
# docker lib needed for 'docker compose exec'
source "lib/docker.sh"

# --- Firewall Update Function ---
# This function resets and applies all firewall rules based on new IPs
update_firewall_rules() {
    local cf_ips_v4="$1"
    local cf_ips_v6="$2"

    if ! is_root; then
        log_error "Firewall updates require root privileges."
        log_info "Run this script with: sudo ./update-cloudflare-ips.sh"
        return 1
    fi

    if ! has_command ufw; then
        log_warn "UFW command not found, skipping firewall update."
        return 0 # Not a fatal error, just log and continue
    fi

    log_info "Resetting UFW to apply new rules..."
    ufw --force reset >/dev/null 2>&1 || {
        log_error "Failed to reset UFW"
        return 1
    }

    # Apply defaults
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1

    # --- P7 FIX: Smart SSH Port Detection ---
    # Allow SSH (CRITICAL)
    # Priority: 1. $SSH_PORT env var (from .env), 2. sshd_config, 3. default 22
    # Note: cron-setup.sh must load .env or this var must be in root's env
    local ssh_port="${SSH_PORT:-}"
    if [[ -z "$ssh_port" ]]; then
        # Grep for the 'Port' directive, ignore comments, get last value
        ssh_port=$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -1)
    fi
    # Default to 22 if still empty
    ssh_port="${ssh_port:-22}"

    ufw allow "$ssh_port/tcp" comment "SSH" >/dev/null 2>&1
    log_info "Firewall rule added: Allow SSH on port $ssh_port"
    # --- END P7 FIX ---

    # Add new Cloudflare IP rules
    local all_ips=()
    # Read IPs into an array
    while IFS= read -r ip; do [[ -n "$ip" ]] && all_ips+=("$ip"); done <<< "$cf_ips_v4"
    while IFS= read -r ip; do [[ -n "$ip" ]] && all_ips+=("$ip"); done <<< "$cf_ips_v6"

    if [[ ${#all_ips[@]} -eq 0 ]]; then
        log_error "No Cloudflare IPs found. Firewall will block web traffic."
        # Still enable firewall, but without web rules
    else
        log_info "Adding ${#all_ips[@]} Cloudflare IP rules to firewall..."
        for ip in "${all_ips[@]}"; do
            ufw allow from "$ip" to any port 80,443 proto tcp comment "Cloudflare" >/dev/null 2>&1
        done
        log_success "Firewall rules for Cloudflare IPs applied"
    fi

    # Enable UFW
    ufw --force enable >/dev/null 2>&1
    log_success "Firewall is now active and configured"
    return 0
}

# --- Caddy Config Update Function ---
update_caddy_config() {
    local cf_ips_v4="$1"
    local cf_ips_v6="$2"

    local temp_file="caddy/cloudflare-ips.caddy.new"
    local final_file="caddy/cloudflare-ips.caddy"
    local backup_file="caddy/cloudflare-ips.caddy.backup" # Backup file path

    # Create new config file content
    local file_content
    file_content=$(cat << EOF
# Cloudflare IP ranges (auto-updated $(date -uIs))
@cloudflare {
    # Cloudflare IPv4 ranges
    remote_ip $cf_ips_v4
    # Cloudflare IPv6 ranges
    remote_ip $cf_ips_v6
}
EOF
)

    # Write to temporary file
    if ! echo "$file_content" > "$temp_file"; then
        log_error "Failed to write new IP list to temporary file: $temp_file"
        return 1
    fi

    # Backup previous file
    if [[ -f "$final_file" ]]; then
        cp "$final_file" "$backup_file" || log_warn "Could not backup previous config file $final_file"
    fi

    # Set permissions/ownership based on existing file/backup
    if [[ -f "$backup_file" ]]; then
        chown --reference="$backup_file" "$temp_file" 2>/dev/null || true
        chmod --reference="$backup_file" "$temp_file" 2>/dev/null || true
    elif [[ -f "$final_file" ]]; then
        chown --reference="$final_file" "$temp_file" 2>/dev/null || true
        chmod --reference="$final_file" "$temp_file" 2>/dev/null || true
    else
        chmod 644 "$temp_file" 2>/dev/null || true
    fi

    # Atomic move
    if ! mv "$temp_file" "$final_file"; then
        log_error "Failed to move temporary file to final location: $final_file"
        rm -f "$temp_file" # Clean up temp file on failure
        return 1
    fi

    log_success "Successfully updated Caddy config: $final_file"
    return 0
}

# --- Caddy Reload Function ---
reload_caddy() {
    log_info "Reloading Caddy configuration..."

    if ! is_service_running "caddy"; then
        log_warn "Caddy service is not running. Skipping reload."
        return 0
    fi

    if docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile > /dev/null; then
        log_success "Caddy reloaded successfully."
        return 0
    else
        log_error "Failed to reload Caddy after IP update. Caddy might be using old IPs."

        # Restore backup on reload failure
        local final_file="caddy/cloudflare-ips.caddy"
        local backup_file="caddy/cloudflare-ips.caddy.backup"
        log_warn "Attempting to restore previous IP list from backup..."

        if [[ -f "$backup_file" ]]; then
            # --- FIX: Added exit 1 on failure to restore backup ---
            if ! mv "$backup_file" "$final_file"; then
                log_error "Failed to restore backup file $backup_file. Manual intervention required."
                exit 1 # Hard exit if restore mv fails
            fi
            log_info "Successfully restored previous IP list. Reloading Caddy again..."
            if docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile > /dev/null; then
                 log_success "Caddy reloaded successfully with restored IP list."
                 # Still return 1 to indicate initial failure, but it's recovered state
                 return 1
            else
                 log_error "Failed to reload Caddy even after restoring backup. Manual intervention required."
                 exit 1 # Hard exit if restore + reload fails
            fi
            # --- END FIX ---
        else
            log_error "No backup file found to restore. Manual intervention required."
            exit 1 # Hard exit if no backup found
        fi
        # This part should not be reached due to exit calls above
        return 1
    fi
}

# --- Main Execution ---
main() {
    log_info "Updating Cloudflare IP ranges for Firewall and Caddy..."

    # Load environment needed for docker compose
    # This will also load $SSH_PORT for the firewall function
    load_env_file || {
        log_error "Failed to load .env file. Cannot run docker compose."
        exit 1
    }

    # Ensure Docker is available
    require_docker || exit 1

    local cf_ips_v4 cf_ips_v6

    # --- P1 FIX: Fetch IPs *before* resetting firewall ---
    log_info "Fetching Cloudflare IP ranges..."
    if ! cf_ips_v4=$(curl -sL --fail --max-time 30 https://www.cloudflare.com/ips-v4); then
        log_error "Failed to fetch Cloudflare IPv4 ranges using curl. Aborting."
        return 1
    fi

    if ! cf_ips_v6=$(curl -sL --fail --max-time 30 https://www.cloudflare.com/ips-v6); then
        log_error "Failed to fetch Cloudflare IPv6 ranges using curl. Aborting."
        return 1
    fi

    # Validate IP ranges (basic check)
    if [[ $(echo "$cf_ips_v4" | wc -l) -lt 5 || $(echo "$cf_ips_v6" | wc -l) -lt 3 ]]; then
        log_error "Cloudflare IP ranges appear invalid (too few ranges fetched). Aborting."
        return 1
    fi
    log_success "IP ranges fetched and validated successfully."
    # --- END P1 FIX ---

    # Update Firewall (Now safe to reset as we have valid IPs)
    # Must be run as root. The cron job does this.
    if ! update_firewall_rules "$cf_ips_v4" "$cf_ips_v6"; then
        log_error "Firewall update failed. Aborting."
        # Don't proceed to Caddy update if firewall failed
        return 1
    fi

    # Update Caddy Config
    if ! update_caddy_config "$cf_ips_v4" "$cf_ips_v6"; then
        log_error "Caddy config update failed. Aborting."
        # Don't proceed to reload if update failed
        return 1
    fi

    # Reload Caddy
    if ! reload_caddy; then
        # reload_caddy function now handles exit on critical failure
        log_error "Caddy reload process encountered errors."
        return 1
    fi

    log_success "Cloudflare IPs updated, firewall configured, and Caddy reloaded."
    return 0
}

# --- Main Entry Point ---
# Handle errors and send email notifications ONLY on failure
if ! main "$@"; then
    log_error "Cloudflare IP update process failed."
    # Send email notification ONLY on failure
    send_notification_email "Cloudflare IP Update Failed" \
        "The automated process to update Cloudflare IP ranges and firewall rules failed on $(hostname -f 2>/dev/null || hostname). Caddy may not trust connections or the firewall may be misconfigured. Please check logs ($PROJECT_ROOT/logs/cron.log or similar) or run the script manually."
    exit 1
fi

exit 0

