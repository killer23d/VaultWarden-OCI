#!/usr/bin/env bash
# update-cloudflare-ips.sh - Update Cloudflare IP ranges for Caddy and fail2ban

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"

FORCE_UPDATE=false
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force) FORCE_UPDATE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) 
            echo "Usage: $0 [--force] [--dry-run]"
            echo "  --force    Update even if IPs haven't changed"
            echo "  --dry-run  Show what would be done without executing"
            exit 0 ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

update_cloudflare_ips() {
    log_info "Updating Cloudflare IP ranges..."
    
    local caddy_ips_file="caddy/cloudflare-ips.caddy"
    local temp_file=$(mktemp)
    local current_date
    current_date=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
    
    # Fetch current Cloudflare IP ranges
    local ipv4_ranges ipv6_ranges
    
    log_info "Fetching Cloudflare IPv4 ranges..."
    if ! ipv4_ranges=$(curl -s --fail https://www.cloudflare.com/ips-v4); then
        log_error "Failed to fetch IPv4 ranges"
        rm -f "$temp_file"
        return 1
    fi
    
    log_info "Fetching Cloudflare IPv6 ranges..."
    if ! ipv6_ranges=$(curl -s --fail https://www.cloudflare.com/ips-v6); then
        log_error "Failed to fetch IPv6 ranges"
        rm -f "$temp_file"
        return 1
    fi
    
    # Generate new file content
    cat > "$temp_file" << EOF
# Cloudflare IP ranges for request filtering  
# Updated automatically by update-cloudflare-ips.sh. Do not edit manually.
# Last updated: $current_date

# Cloudflare IPv4 ranges - Updated automatically
EOF
    
    # Add IPv4 ranges
    echo "$ipv4_ranges" | while read -r ip; do
        [[ -n "$ip" ]] && echo "remote_ip $ip" >> "$temp_file"
    done
    
    echo "" >> "$temp_file"
    echo "# Cloudflare IPv6 ranges - Updated automatically" >> "$temp_file"
    
    # Add IPv6 ranges
    echo "$ipv6_ranges" | while read -r ip; do
        [[ -n "$ip" ]] && echo "remote_ip $ip" >> "$temp_file"
    done
    
    # Check if file changed or force update
    if [[ "$FORCE_UPDATE" == "true" ]] || ! cmp -s "$temp_file" "$caddy_ips_file" 2>/dev/null; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would update $caddy_ips_file"
            log_info "New content preview:"
            head -n 15 "$temp_file"
        else
            mv "$temp_file" "$caddy_ips_file"
            log_success "Updated Cloudflare IP ranges in $caddy_ips_file"
            
            # Reload Caddy if running
            if docker compose ps caddy --format json 2>/dev/null | jq -e '.State == "running"' >/dev/null 2>&1; then
                log_info "Reloading Caddy configuration..."
                if docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile; then
                    log_success "Caddy configuration reloaded"
                else
                    log_warn "Failed to reload Caddy - may need manual restart"
                fi
            else
                log_info "Caddy not running - configuration will be used on next startup"
            fi
        fi
    else
        log_info "Cloudflare IP ranges are already up to date"
    fi
    
    rm -f "$temp_file"
}

main() {
    log_info "Cloudflare IP Range Updater"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi
    
    # Check if required commands exist
    if ! has_command curl; then
        log_error "curl is required but not installed"
        exit 1
    fi
    
    if ! has_command jq; then
        log_warn "jq not found - Caddy reload detection disabled"
    fi
    
    update_cloudflare_ips
    
    log_success "Cloudflare IP update completed"
}

main "$@"
