#!/usr/bin/env bash
# test-email-simple.sh - Simple email testing for msmtpd integration
# Author: VaultWarden-OCI Team
# Purpose: Validate email functionality after mailutil -> msmtpd migration

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
Simple Email Testing for msmtpd Integration

USAGE:
    ./test-email-simple.sh [OPTIONS]

OPTIONS:
    --recipient EMAIL    Test email recipient (default: ADMIN_EMAIL from .env)
    --verbose           Show detailed output
    --dry-run           Show what would be tested without sending emails
    --help              Show this help

TESTS:
    1. msmtpd Container Status
    2. fail2ban Integration
    3. Host Script Email Functionality
    4. End-to-End Email Test

This script validates the migration from mailutils to msmtpd sidecar container.
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

test_msmtpd_container() {
    log_info "Testing msmtpd container status..."

    # Check if container is running
    if docker compose ps vaultwarden_msmtpd >/dev/null 2>&1; then
        log_success "✅ msmtpd container is running"
        verbose_log "Container status: $(docker compose ps vaultwarden_msmtpd --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}')"
    else
        log_error "❌ msmtpd container is not running"
        log_info "Starting msmtpd container..."
        if docker compose up -d msmtpd; then
            sleep 5  # Wait for startup
            log_success "✅ msmtpd container started successfully"
        else
            log_error "❌ Failed to start msmtpd container"
            return 1
        fi
    fi

    # Check container health
    local health_status
    health_status=$(docker compose exec -T vaultwarden_msmtpd nc -z localhost 1025 >/dev/null 2>&1 && echo "healthy" || echo "unhealthy")
    
    if [[ "$health_status" == "healthy" ]]; then
        log_success "✅ msmtpd health check passed (port 1025 responding)"
    else
        log_error "❌ msmtpd health check failed (port 1025 not responding)"
        return 1
    fi

    # Check logs for errors
    local recent_logs
    recent_logs=$(docker compose logs --tail 10 vaultwarden_msmtpd 2>/dev/null | grep -i error || true)
    if [[ -n "$recent_logs" ]]; then
        log_warn "⚠️  Found recent errors in msmtpd logs:"
        echo "$recent_logs" | while read -r line; do
            log_warn "    $line"
        done
    else
        verbose_log "No recent errors found in msmtpd logs"
    fi

    return 0
}

test_fail2ban_integration() {
    log_info "Testing fail2ban integration..."

    # Check if fail2ban container is running
    if ! docker compose ps vaultwarden_fail2ban >/dev/null 2>&1; then
        log_error "❌ fail2ban container is not running"
        return 1
    fi

    # Check fail2ban status
    if docker compose exec -T vaultwarden_fail2ban fail2ban-client status >/dev/null 2>&1; then
        log_success "✅ fail2ban is responding"
        verbose_log "fail2ban jails: $(docker compose exec -T vaultwarden_fail2ban fail2ban-client status | grep "Jail list" || echo "Status check passed")"
    else
        log_error "❌ fail2ban is not responding"
        return 1
    fi

    # Check if fail2ban can reach msmtpd
    if docker compose exec -T vaultwarden_fail2ban nc -z msmtpd 1025 >/dev/null 2>&1; then
        log_success "✅ fail2ban can reach msmtpd container"
    else
        log_error "❌ fail2ban cannot reach msmtpd container"
        return 1
    fi

    # Check if smtp action exists
    if docker compose exec -T vaultwarden_fail2ban test -f /data/fail2ban/action.d/smtp.conf; then
        log_success "✅ SMTP action configuration found"
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
        log_info "🔍 [DRY RUN] Email would be sent via msmtpd container"
        return 0
    fi

    if [[ -z "$TEST_RECIPIENT" ]]; then
        log_error "❌ No test recipient specified"
        return 1
    fi

    local test_subject="VaultWarden Email Migration Test - $(date)"
    local test_body="🎉 Email Migration Successful!

This test email confirms that your VaultWarden-OCI deployment has successfully migrated from mailutils to msmtpd.

MIGRATION DETAILS:
- Date: $(date -Iseconds)
- Host: $(hostname -f 2>/dev/null || hostname)
- Email Backend: msmtpd sidecar container
- Configuration: VaultWarden-OCI Enhanced

BENEFITS OF THIS MIGRATION:
✅ Eliminated host mailutils dependency
✅ Improved email reliability
✅ Better resource management (32MB container)
✅ Enhanced security with containerized email
✅ Maintained all existing SOPS/Age secret workflows

If you received this email, the migration was completely successful!

Regards,
VaultWarden-OCI Email System"

    log_info "📧 Sending test email to: $TEST_RECIPIENT"
    
    if send_notification_email "$test_subject" "$test_body"; then
        log_success "✅ Test email sent successfully!"
        log_info "📬 Please check $TEST_RECIPIENT for the test message"
        log_info "🔍 Check msmtpd logs: docker compose logs vaultwarden_msmtpd"
    else
        log_error "❌ Failed to send test email"
        log_info "🔍 Debug steps:"
        log_info "   1. Check msmtpd logs: docker compose logs vaultwarden_msmtpd"
        log_info "   2. Check fail2ban logs: docker compose logs vaultwarden_fail2ban"
        log_info "   3. Verify SMTP credentials in secrets"
        return 1
    fi

    return 0
}

main() {
    log_header "VaultWarden Email Migration Test - msmtpd Integration"
    
    # Load environment early
    if ! load_env_file; then
        log_error "Failed to load environment configuration"
        exit 1
    fi

    local test_results=()
    local test_names=("msmtpd Container" "fail2ban Integration" "Host Script Email" "End-to-End Email")
    
    # Run all tests
    test_msmtpd_container && test_results+=(0) || test_results+=(1)
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
        log_success "✅ Your VaultWarden-OCI deployment has successfully migrated to msmtpd"
        log_info ""
        log_info "NEXT STEPS:"
        log_info "1. Monitor email functionality over the next few days"
        log_info "2. Check fail2ban email notifications are working"
        log_info "3. Verify backup/health script emails are delivered"
        log_info "4. Consider removing any remaining mailutils packages from host"
        exit 0
    else
        log_error "❌ Some email migration tests failed: ${failed_tests[*]}"
        log_info ""
        log_info "TROUBLESHOOTING:"
        log_info "1. Check container logs: docker compose logs vaultwarden_msmtpd"
        log_info "2. Verify SMTP configuration in .env file"
        log_info "3. Check secrets: ./edit-secrets.sh --test"
        log_info "4. Review fail2ban configuration files"
        exit 1
    fi
}

main "$@"
