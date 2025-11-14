#!/usr/bin/env bash
# test-email-simple.sh - Simple email testing for bokysan/docker-postfix integration
# Author: VaultWarden-OCI Team
# Purpose: Validate email functionality after msmtpd -> postfix migration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"

# Configuration
TEST_RECIPIENT="${ADMIN_EMAIL:-}"
VERBOSE=false
DRY_RUN=false

show_help() {
    cat << 'EOF'
Simple Email Testing for bokysan/docker-postfix Integration

USAGE:
    ./test-email-simple.sh [OPTIONS]

OPTIONS:
    --recipient EMAIL    Test email recipient (default: ADMIN_EMAIL from .env)
    --verbose           Show detailed output
    --dry-run           Show what would be tested without sending emails
    --help              Show this help

TESTS:
    1. postfix Container Status
    2. fail2ban Integration
    3. Host Script Email Functionality
    4. End-to-End Email Test

This script validates the migration from msmtpd to bokysan/docker-postfix.
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --recipient) TEST_RECIPIENT="$2"; shift 2 ;;
        --verbose) VERBOSE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# Enhanced logging for verbose mode
verbose_log() {
    [[ "$VERBOSE" == "true" ]] && log_info "$1"
}

test_postfix_container() {
    log_info "Testing postfix container status..."

    # Check if container is running (use service name)
    if docker compose ps postfix >/dev/null 2>&1; then
        log_success "✅ postfix container is running"
        verbose_log "Container status: $(docker compose ps postfix --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}')"
    else
        log_error "❌ postfix container is not running"
        log_info "Starting postfix container..."
        if docker compose up -d postfix; then
            sleep 15  # Wait for startup (postfix needs time to initialize)
            log_success "✅ postfix container started successfully"
        else
            log_error "❌ Failed to start postfix container"
            return 1
        fi
    fi

    # Check container health
    local health_status
    health_status=$(docker compose exec -T postfix nc -z localhost 587 >/dev/null 2>&1 && echo "healthy" || echo "unhealthy")
    
    if [[ "$health_status" == "healthy" ]]; then
        log_success "✅ postfix health check passed (port 587 responding)"
    else
        log_error "❌ postfix health check failed (port 587 not responding)"
        log_info "🔍 Check logs: docker compose logs postfix"
        return 1
    fi

    # Check postfix status
    if docker compose exec -T postfix postfix status >/dev/null 2>&1; then
        log_success "✅ postfix service is active"
        verbose_log "$(docker compose exec -T postfix postfix status)"
    else
        log_warn "⚠️  Could not verify postfix service status"
    fi

    # Check logs for errors (use service name)
    local recent_logs
    recent_logs=$(docker compose logs --tail 20 postfix 2>/dev/null | grep -i "error\|fatal" | grep -v "warning" || true)
    if [[ -n "$recent_logs" ]]; then
        log_warn "⚠️  Found recent errors in postfix logs:"
        echo "$recent_logs" | while read -r line; do
            log_warn "    $line"
        done
    else
        verbose_log "No critical errors found in postfix logs"
    fi

    return 0
}

test_fail2ban_integration() {
    log_info "Testing fail2ban integration..."

    # Check if fail2ban container is running (use service name)
    if ! docker compose ps fail2ban >/dev/null 2>&1; then
        log_error "❌ fail2ban container is not running"
        log_info "💡 Start it with: docker compose up -d fail2ban"
        return 1
    fi

    # Check fail2ban status
    if docker compose exec -T fail2ban fail2ban-client status >/dev/null 2>&1; then
        log_success "✅ fail2ban is responding"
        verbose_log "fail2ban jails: $(docker compose exec -T fail2ban fail2ban-client status | grep "Jail list" || echo "Status check passed")"
    else
        log_error "❌ fail2ban is not responding"
        return 1
    fi

    # Check if fail2ban can reach postfix (use Docker network name)
    if docker compose exec -T fail2ban nc -z postfix 587 >/dev/null 2>&1; then
        log_success "✅ fail2ban can reach postfix container"
    else
        log_error "❌ fail2ban cannot reach postfix container"
        return 1
    fi

    # Check if smtp action exists
    if docker compose exec -T fail2ban test -f /data/fail2ban/action.d/smtp.conf; then
        log_success "✅ SMTP action configuration found"
        
        # Verify it references postfix (not msmtpd)
        if docker compose exec -T fail2ban grep -q "postfix" /data/fail2ban/action.d/smtp.conf; then
            log_success "✅ SMTP action correctly configured for postfix"
        else
            log_warn "⚠️  SMTP action may still reference old msmtpd configuration"
        fi
    else
        log_error "❌ SMTP action configuration missing"
        return 1
    fi

    return 0
}

test_host_script_email() {
    log_info "Testing host script email functionality..."

    # Load environment
    if ! load_env_file; then
        log_error "❌ Failed to load .env file"
        return 1
    fi

    # Check ADMIN_EMAIL configuration
    if [[ -z "$TEST_RECIPIENT" ]]; then
        TEST_RECIPIENT=$(get_config_value "ADMIN_EMAIL" "")
        if [[ -z "$TEST_RECIPIENT" ]]; then
            log_error "❌ No email recipient configured (ADMIN_EMAIL not set)"
            return 1
        fi
    fi

    log_success "✅ Email recipient configured: $TEST_RECIPIENT"

    # Check ALLOWED_SENDER_DOMAINS configuration
    local sender_domains
    sender_domains=$(get_config_value "ALLOWED_SENDER_DOMAINS" "")
    if [[ -n "$sender_domains" ]]; then
        log_success "✅ Allowed sender domains configured: $sender_domains"
    else
        log_warn "⚠️  ALLOWED_SENDER_DOMAINS not set (postfix may reject emails)"
    fi

    # Test email function availability
    if declare -f send_notification_email >/dev/null 2>&1; then
        log_success "✅ send_notification_email function available"
    else
        log_error "❌ send_notification_email function not available"
        return 1
    fi

    return 0
}

test_end_to_end_email() {
    log_info "Testing end-to-end email functionality..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "🔍 [DRY RUN] Would send test email to: $TEST_RECIPIENT"
        log_info "🔍 [DRY RUN] Email would be sent via postfix container (port 587)"
        return 0
    fi

    if [[ -z "$TEST_RECIPIENT" ]]; then
        log_error "❌ No test recipient specified"
        return 1
    fi

    local test_subject="VaultWarden Email Migration Test - postfix - $(date)"
    local test_body="🎉 Email Migration Successful - Now using bokysan/docker-postfix!

This test email confirms that your VaultWarden-OCI deployment has successfully migrated from msmtpd to bokysan/docker-postfix.

MIGRATION DETAILS:
- Date: $(date -Iseconds)
- Host: $(hostname -f 2>/dev/null || hostname)
- Email Backend: bokysan/docker-postfix container
- SMTP Port: 587 (standard submission port)
- Configuration: VaultWarden-OCI Enhanced

BENEFITS OF THIS MIGRATION:
✅ Full-featured Postfix server with relay support
✅ Better email compatibility and deliverability
✅ Enhanced logging and debugging capabilities
✅ Support for TLS encryption and authentication
✅ Configurable message size limits
✅ Production-ready SMTP relay solution
✅ Maintained all existing SOPS/Age secret workflows

POSTFIX FEATURES:
- Multi-architecture support (amd64, arm64, arm/v7)
- DKIM signing support (optional)
- Comprehensive configuration options
- Active maintenance and updates
- Proven reliability in production

If you received this email, the migration was completely successful!

Regards,
VaultWarden-OCI Email System (powered by bokysan/docker-postfix)"

    log_info "📧 Sending test email to: $TEST_RECIPIENT"
    
    if send_notification_email "$test_subject" "$test_body"; then
        log_success "✅ Test email sent successfully!"
        log_info "📬 Please check $TEST_RECIPIENT for the test message"
        log_info "🔍 Check postfix logs: docker compose logs postfix"
    else
        log_error "❌ Failed to send test email"
        log_info "🔍 Debug steps:"
        log_info "   1. Check postfix logs: docker compose logs postfix"
        log_info "   2. Check fail2ban logs: docker compose logs fail2ban"
        log_info "   3. Verify SMTP credentials in secrets"
        log_info "   4. Verify ALLOWED_SENDER_DOMAINS in .env"
        log_info "   5. Check postfix relay configuration"
        log_info "   6. Check postfix container permissions: docker compose logs postfix | grep -i permission"
        return 1
    fi

    return 0
}

main() {
    log_header "VaultWarden Email Migration Test - bokysan/docker-postfix Integration"
    
    # Load environment early
    if ! load_env_file; then
        log_error "Failed to load environment configuration"
        exit 1
    fi

    local test_results=()
    local test_names=("postfix Container" "fail2ban Integration" "Host Script Email" "End-to-End Email")
    
    # Run all tests
    test_postfix_container && test_results+=(0) || test_results+=(1)
    test_fail2ban_integration && test_results+=(0) || test_results+=(1)
    test_host_script_email && test_results+=(0) || test_results+=(1)
    test_end_to_end_email && test_results+=(0) || test_results+=(1)
    
    # Calculate results
    local total_tests=${#test_results[@]}
    local passed_tests=0
    local failed_tests=()
    
    for i in "${!test_results[@]}"; do
        if [[ ${test_results[i]} -eq 0 ]]; then
            ((passed_tests++))
        else
            failed_tests+=("${test_names[i]}")
        fi
    done
    
    echo ""
    log_info "============================================"
    log_info "TEST RESULTS: $passed_tests/$total_tests tests passed"
    log_info "============================================"
    
    if [[ $passed_tests -eq $total_tests ]]; then
        log_success "🎉 ALL EMAIL MIGRATION TESTS PASSED!"
        log_success "✅ Your VaultWarden-OCI deployment has successfully migrated to bokysan/docker-postfix"
        log_info ""
        log_info "NEXT STEPS:"
        log_info "1. Monitor email functionality over the next few days"
        log_info "2. Check fail2ban email notifications are working"
        log_info "3. Verify backup/health script emails are delivered"
        log_info "4. Review postfix logs for any warnings or errors"
        log_info "5. Consider configuring DKIM for better deliverability (optional)"
        exit 0
    else
        log_error "❌ Some email migration tests failed: ${failed_tests[*]}"
        log_info ""
        log_info "TROUBLESHOOTING:"
        log_info "1. Check container logs: docker compose logs postfix"
        log_info "2. Verify SMTP configuration in .env file"
        log_info "3. Check secrets: ./edit-secrets.sh --test"
        log_info "4. Verify ALLOWED_SENDER_DOMAINS matches your email domains"
        log_info "5. Review postfix relay configuration"
        log_info "6. Check network connectivity between containers"
        log_info "7. Ensure postfix has proper permissions (check for Permission denied errors)"
        exit 1
    fi
}

main "$@"
