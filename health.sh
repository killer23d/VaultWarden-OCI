#!/usr/bin/env bash
# health.sh - Enhanced health monitoring for VaultWarden-OCI with Caddy-Cloudflare
# UPDATED: Added caddy-cloudflare specific checks, removed ddclient references

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh"

# Configuration
COMPREHENSIVE=false
QUIET=false
JSON_OUTPUT=false
ALERT_THRESHOLD=80  # Percentage threshold for alerts
OUTPUT_FILE=""

show_help() {
    cat << 'EOF'
VaultWarden-OCI Health Monitor - Enhanced for Caddy-Cloudflare

USAGE:
    ./health.sh [OPTIONS]

OPTIONS:
    --comprehensive     Run comprehensive health checks
    --quiet            Suppress non-error output
    --json             Output results in JSON format
    --output FILE      Save results to file
    --alert-threshold N Set alert threshold percentage (default: 80)
    --help             Show this help

EXAMPLES:
    ./health.sh                     # Basic health check
    ./health.sh --comprehensive     # Full system health check
    ./health.sh --json --output health.json  # Save results as JSON

HEALTH CHECKS:
    Basic:
    - Container status and health
    - Service accessibility
    - Critical process monitoring

    Comprehensive:
    - Resource usage monitoring
    - Storage space analysis
    - Network connectivity tests
    - Configuration validation
    - Security status checks
    - Caddy-Cloudflare integration
    - Performance metrics
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --comprehensive) COMPREHENSIVE=true; shift ;;
        --quiet) QUIET=true; shift ;;
        --json) JSON_OUTPUT=true; shift ;;
        --output) OUTPUT_FILE="$2"; shift 2 ;;
        --alert-threshold) ALERT_THRESHOLD="$2"; shift 2 ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# Health check results storage
declare -A HEALTH_RESULTS
declare -A HEALTH_DETAILS
OVERALL_STATUS="healthy"
ISSUES_FOUND=()

# Logging functions that respect quiet mode
health_log_info() {
    [[ "$QUIET" == "true" ]] || log_info "$1"
}

health_log_success() {
    [[ "$QUIET" == "true" ]] || log_success "$1"
}

health_log_warn() {
    log_warn "$1"
    ISSUES_FOUND+=("WARNING: $1")
}

health_log_error() {
    log_error "$1"
    ISSUES_FOUND+=("ERROR: $1")
    OVERALL_STATUS="unhealthy"
}

# Basic health checks
check_container_status() {
    health_log_info "Checking container status..."
    
    local containers=("vaultwarden_app" "vaultwarden_caddy" "vaultwarden_fail2ban")
    local unhealthy_containers=()
    local stopped_containers=()
    
    for container in "${containers[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            local status
            status=$(docker inspect "$container" --format='{{.State.Health.Status}}' 2>/dev/null || echo "no-healthcheck")
            
            if [[ "$status" == "unhealthy" ]]; then
                unhealthy_containers+=("$container")
            elif [[ "$status" == "no-healthcheck" ]]; then
                # Check if container is running
                local state
                state=$(docker inspect "$container" --format='{{.State.Status}}' 2>/dev/null || echo "unknown")
                if [[ "$state" != "running" ]]; then
                    stopped_containers+=("$container")
                fi
            fi
        else
            stopped_containers+=("$container")
        fi
    done
    
    if [[ ${#stopped_containers[@]} -gt 0 ]]; then
        health_log_error "Stopped containers: ${stopped_containers[*]}"
        HEALTH_RESULTS["containers"]="failed"
        HEALTH_DETAILS["containers"]="Stopped: ${stopped_containers[*]}"
    elif [[ ${#unhealthy_containers[@]} -gt 0 ]]; then
        health_log_warn "Unhealthy containers: ${unhealthy_containers[*]}"
        HEALTH_RESULTS["containers"]="degraded"
        HEALTH_DETAILS["containers"]="Unhealthy: ${unhealthy_containers[*]}"
    else
        health_log_success "All containers are running and healthy"
        HEALTH_RESULTS["containers"]="healthy"
        HEALTH_DETAILS["containers"]="All containers operational"
    fi
}

check_service_accessibility() {
    health_log_info "Checking service accessibility..."
    
    # Load domain from .env
    local domain
    domain=$(get_config_value "DOMAIN" "")
    
    if [[ -z "$domain" ]]; then
        health_log_error "DOMAIN not configured in .env file"
        HEALTH_RESULTS["accessibility"]="failed"
        return 1
    fi
    
    # Test local VaultWarden access
    if curl -sf "http://localhost/alive" >/dev/null 2>&1; then
        health_log_success "VaultWarden local access: OK"
    else
        health_log_error "VaultWarden local access: FAILED"
        HEALTH_RESULTS["accessibility"]="failed"
        return 1
    fi
    
    # Test external web access
    local clean_domain
    clean_domain=$(echo "$domain" | sed 's|https\?://||; s|/.*$||')
    
    if curl -sf "https://$clean_domain" >/dev/null 2>&1; then
        health_log_success "External web access: OK"
        HEALTH_RESULTS["accessibility"]="healthy"
        HEALTH_DETAILS["accessibility"]="All services accessible"
    else
        health_log_warn "External web access: FAILED (DNS/SSL issue)"
        HEALTH_RESULTS["accessibility"]="degraded"
        HEALTH_DETAILS["accessibility"]="External access issues"
    fi
}

check_caddy_cloudflare_integration() {
    [[ "$COMPREHENSIVE" == "false" ]] && return 0
    
    health_log_info "Checking Caddy-Cloudflare integration..."
    
    local cf_issues=()
    
    # Check if Caddy is responding
    if ! docker compose exec caddy caddy version >/dev/null 2>&1; then
        cf_issues+=("Caddy not responding")
    fi
    
    # Check SSL certificates with DNS-01 challenge
    local cert_info
    cert_info=$(docker compose exec caddy caddy list-certificates 2>/dev/null || echo "")
    if [[ -n "$cert_info" ]]; then
        if echo "$cert_info" | grep -q "DNS challenge"; then
            health_log_success "DNS-01 ACME challenges active"
        else
            cf_issues+=("DNS-01 challenges not detected")
        fi
    else
        cf_issues+=("Cannot retrieve certificate information")
    fi
    
    # Check Cloudflare IP trust configuration
    local caddy_config
    caddy_config=$(docker compose exec caddy caddy config --json 2>/dev/null || echo "{}")
    if echo "$caddy_config" | jq -e '.apps.http.servers | to_entries[] | .value.trusted_proxies' >/dev/null 2>&1; then
        health_log_success "Cloudflare trusted proxies configured"
    else
        cf_issues+=("Cloudflare trusted proxies not configured")
    fi
    
    # Check API token file accessibility
    if docker compose exec caddy test -f /run/secrets/caddy_cloudflare_dns_token 2>/dev/null; then
        health_log_success "Cloudflare DNS API token accessible"
    else
        cf_issues+=("Cloudflare DNS API token not accessible")
    fi
    
    if [[ ${#cf_issues[@]} -gt 0 ]]; then
        health_log_warn "Caddy-Cloudflare issues: ${cf_issues[*]}"
        HEALTH_RESULTS["caddy_cloudflare"]="degraded"
        HEALTH_DETAILS["caddy_cloudflare"]="Issues: ${cf_issues[*]}"
    else
        health_log_success "Caddy-Cloudflare integration healthy"
        HEALTH_RESULTS["caddy_cloudflare"]="healthy"
        HEALTH_DETAILS["caddy_cloudflare"]="DNS-01 ACME and IP management active"
    fi
}

check_resource_usage() {
    [[ "$COMPREHENSIVE" == "false" ]] && return 0
    
    health_log_info "Checking resource usage..."
    
    # CPU usage
    local cpu_usage
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 | cut -d'u' -f1 2>/dev/null || echo "0")
    
    # Memory usage
    local mem_usage
    mem_usage=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100.0}' 2>/dev/null || echo "0")
    
    # Disk usage
    local disk_usage
    disk_usage=$(df "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}" 2>/dev/null | tail -1 | awk '{print $5}' | cut -d'%' -f1 || echo "0")
    
    local resource_issues=()
    
    if (( $(echo "$cpu_usage > $ALERT_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
        resource_issues+=("CPU: ${cpu_usage}%")
    fi
    
    if (( mem_usage > ALERT_THRESHOLD )); then
        resource_issues+=("Memory: ${mem_usage}%")
    fi
    
    if (( disk_usage > ALERT_THRESHOLD )); then
        resource_issues+=("Disk: ${disk_usage}%")
    fi
    
    if [[ ${#resource_issues[@]} -gt 0 ]]; then
        health_log_warn "High resource usage: ${resource_issues[*]}"
        HEALTH_RESULTS["resources"]="degraded"
        HEALTH_DETAILS["resources"]="High usage: ${resource_issues[*]}"
    else
        health_log_success "Resource usage within normal limits"
        HEALTH_RESULTS["resources"]="healthy"
        HEALTH_DETAILS["resources"]="CPU: ${cpu_usage}%, Memory: ${mem_usage}%, Disk: ${disk_usage}%"
    fi
}

check_storage_space() {
    [[ "$COMPREHENSIVE" == "false" ]] && return 0
    
    health_log_info "Checking storage space..."
    
    local state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    local total_size usage_percent
    
    if [[ -d "$state_dir" ]]; then
        read -r total_size usage_percent < <(df -h "$state_dir" 2>/dev/null | tail -1 | awk '{print $2, $5}' | tr -d '%' || echo "unknown 0")
        
        if (( usage_percent > ALERT_THRESHOLD )); then
            health_log_warn "Storage usage high: ${usage_percent}% of ${total_size}"
            HEALTH_RESULTS["storage"]="degraded"
            HEALTH_DETAILS["storage"]="${usage_percent}% used of ${total_size}"
        else
            health_log_success "Storage usage normal: ${usage_percent}% of ${total_size}"
            HEALTH_RESULTS["storage"]="healthy"
            HEALTH_DETAILS["storage"]="${usage_percent}% used of ${total_size}"
        fi
    else
        health_log_warn "Storage directory not found: $state_dir"
        HEALTH_RESULTS["storage"]="degraded"
        HEALTH_DETAILS["storage"]="Directory not found"
    fi
}

check_configuration() {
    [[ "$COMPREHENSIVE" == "false" ]] && return 0
    
    health_log_info "Checking configuration..."
    
    local config_issues=()
    
    # Check .env file
    if [[ ! -f ".env" ]]; then
        config_issues+=("Missing .env file")
    else
        # Check required variables
        local required_vars=("DOMAIN" "ADMIN_EMAIL" "CLOUDFLARE_ZONE_ID")
        for var in "${required_vars[@]}"; do
            if ! grep -q "^${var}=" .env; then
                config_issues+=("Missing $var in .env")
            fi
        done
    fi
    
    # Check secrets file
    if [[ ! -f "secrets/secrets.yaml" ]]; then
        config_issues+=("Missing secrets.yaml file")
    elif ! ./edit-secrets.sh --test >/dev/null 2>&1; then
        config_issues+=("Secrets decryption failed")
    else
        # Check for caddy-cloudflare specific secrets
        local decrypted_secrets
        decrypted_secrets=$(sops --decrypt --output-type json secrets/secrets.yaml 2>/dev/null || echo "{}")
        
        local required_secrets=("caddy_cloudflare_dns_token" "fail2ban_cloudflare_firewall_token" "admin_basic_auth_hash")
        for secret in "${required_secrets[@]}"; do
            local value
            value=$(echo "$decrypted_secrets" | jq -r --arg key "$secret" '.[$key] // ""')
            if [[ -z "$value" ]] || [[ "$value" == "null" ]] || [[ "$value" == CHANGE_ME* ]]; then
                config_issues+=("$secret not properly configured")
            fi
        done
    fi
    
    # Check Caddyfile syntax with caddy-cloudflare
    if ! timeout 10 docker run --rm \
        -v "$PWD/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
        --env DOMAIN="${DOMAIN:-vault.example.com}" \
        --env CLOUDFLARE_API_TOKEN="test-token" \
        ghcr.io/caddybuilds/caddy-cloudflare:latest \
        caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        config_issues+=("Caddy configuration syntax error")
    fi
    
    # Check Docker Compose syntax
    if ! docker compose config >/dev/null 2>&1; then
        config_issues+=("Docker Compose configuration error")
    fi
    
    if [[ ${#config_issues[@]} -gt 0 ]]; then
        health_log_error "Configuration issues: ${config_issues[*]}"
        HEALTH_RESULTS["configuration"]="failed"
        HEALTH_DETAILS["configuration"]="Issues: ${config_issues[*]}"
    else
        health_log_success "Configuration validation passed"
        HEALTH_RESULTS["configuration"]="healthy"
        HEALTH_DETAILS["configuration"]="All configurations valid"
    fi
}

check_security_status() {
    [[ "$COMPREHENSIVE" == "false" ]] && return 0
    
    health_log_info "Checking security status..."
    
    local security_issues=()
    
    # Check file permissions on secrets
    if [[ -d "secrets/.docker_secrets" ]]; then
        local bad_perms
        bad_perms=$(find secrets/.docker_secrets -type f ! -perm 600 2>/dev/null | wc -l)
        if (( bad_perms > 0 )); then
            security_issues+=("$bad_perms secret files with incorrect permissions")
        fi
    fi
    
    # Check if fail2ban is active
    if ! docker compose exec fail2ban fail2ban-client status >/dev/null 2>&1; then
        security_issues+=("fail2ban not responding")
    fi
    
    # Check SSL certificate validity
    local domain
    domain=$(get_config_value "DOMAIN" "")
    if [[ -n "$domain" ]]; then
        local clean_domain
        clean_domain=$(echo "$domain" | sed 's|https\?://||; s|/.*$||')
        
        if ! echo | openssl s_client -servername "$clean_domain" -connect "$clean_domain:443" 2>/dev/null | openssl x509 -checkend 604800 -noout >/dev/null 2>&1; then
            security_issues+=("SSL certificate expires within 7 days")
        fi
    fi
    
    # Check Age key permissions
    if [[ -f "secrets/keys/age-key.txt" ]]; then
        local age_perms
        age_perms=$(stat -c "%a" "secrets/keys/age-key.txt" 2>/dev/null || echo "000")
        if [[ "$age_perms" != "600" ]]; then
            security_issues+=("Age key has incorrect permissions: $age_perms")
        fi
    fi
    
    if [[ ${#security_issues[@]} -gt 0 ]]; then
        health_log_warn "Security issues found: ${security_issues[*]}"
        HEALTH_RESULTS["security"]="degraded"
        HEALTH_DETAILS["security"]="Issues: ${security_issues[*]}"
    else
        health_log_success "Security status good"
        HEALTH_RESULTS["security"]="healthy"
        HEALTH_DETAILS["security"]="All security checks passed"
    fi
}

check_network_connectivity() {
    [[ "$COMPREHENSIVE" == "false" ]] && return 0
    
    health_log_info "Checking network connectivity..."
    
    local network_issues=()
    
    # Test basic internet connectivity
    if ! test_connectivity "1.1.1.1" 5; then
        network_issues+=("No internet connectivity")
    fi
    
    # Test Cloudflare API connectivity
    if ! test_http "https://api.cloudflare.com/client/v4/zones" 10; then
        network_issues+=("Cannot reach Cloudflare API")
    fi
    
    # Test Docker network
    if ! docker network inspect vaultwarden_vaultwarden_network >/dev/null 2>&1; then
        network_issues+=("Docker network not found")
    fi
    
    if [[ ${#network_issues[@]} -gt 0 ]]; then
        health_log_warn "Network connectivity issues: ${network_issues[*]}"
        HEALTH_RESULTS["network"]="degraded"
        HEALTH_DETAILS["network"]="Issues: ${network_issues[*]}"
    else
        health_log_success "Network connectivity good"
        HEALTH_RESULTS["network"]="healthy"
        HEALTH_DETAILS["network"]="All network tests passed"
    fi
}

generate_report() {
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        generate_json_report
    else
        generate_text_report
    fi
}

generate_text_report() {
    local report=""
    report+="VaultWarden-OCI Health Report - Enhanced for Caddy-Cloudflare\n"
    report+="Generated: $(date)\n"
    report+="Overall Status: $OVERALL_STATUS\n\n"
    
    report+="Component Status:\n"
    for component in "${!HEALTH_RESULTS[@]}"; do
        local status="${HEALTH_RESULTS[$component]}"
        local details="${HEALTH_DETAILS[$component]:-}"
        
        case $status in
            "healthy") report+="  ✅ $component: $status" ;;
            "degraded") report+="  ⚠️  $component: $status" ;;
            "failed") report+="  ❌ $component: $status" ;;
        esac
        
        [[ -n "$details" ]] && report+=" - $details"
        report+="\n"
    done
    
    if [[ ${#ISSUES_FOUND[@]} -gt 0 ]]; then
        report+="\nIssues Found:\n"
        for issue in "${ISSUES_FOUND[@]}"; do
            report+="  • $issue\n"
        done
    fi
    
    if [[ -n "$OUTPUT_FILE" ]]; then
        echo -e "$report" > "$OUTPUT_FILE"
        health_log_info "Report saved to: $OUTPUT_FILE"
    else
        echo -e "$report"
    fi
}

generate_json_report() {
    local json_report="{
  \"timestamp\": \"$(date -Iseconds)\",
  \"overall_status\": \"$OVERALL_STATUS\",
  \"components\": {"
    
    local first=true
    for component in "${!HEALTH_RESULTS[@]}"; do
        [[ "$first" == "true" ]] && first=false || json_report+=","
        json_report+="
    \"$component\": {
      \"status\": \"${HEALTH_RESULTS[$component]}\",
      \"details\": \"${HEALTH_DETAILS[$component]:-}\""
        json_report+="
    }"
    done
    
    json_report+="
  },
  \"issues\": ["
    
    first=true
    for issue in "${ISSUES_FOUND[@]}"; do
        [[ "$first" == "true" ]] && first=false || json_report+=","
        json_report+="
    \"$issue\""
    done
    
    json_report+="
  ]
}"
    
    if [[ -n "$OUTPUT_FILE" ]]; then
        echo "$json_report" > "$OUTPUT_FILE"
        health_log_info "JSON report saved to: $OUTPUT_FILE"
    else
        echo "$json_report"
    fi
}

main() {
    health_log_info "VaultWarden-OCI Health Monitor - Enhanced for Caddy-Cloudflare"
    
    if [[ "$COMPREHENSIVE" == "true" ]]; then
        health_log_info "Running comprehensive health checks..."
    else
        health_log_info "Running basic health checks..."
    fi
    
    # Load environment if available
    load_env_file 2>/dev/null || true
    
    # Run health checks
    check_container_status
    check_service_accessibility
    check_caddy_cloudflare_integration
    check_resource_usage
    check_storage_space
    check_configuration
    check_security_status
    check_network_connectivity
    
    # Generate report
    generate_report
    
    # Exit with appropriate code
    if [[ "$OVERALL_STATUS" == "healthy" ]]; then
        [[ "$QUIET" == "false" ]] && health_log_success "All health checks passed"
        exit 0
    else
        [[ "$QUIET" == "false" ]] && health_log_error "Health check failures detected"
        exit 1
    fi
}

main "$@"
