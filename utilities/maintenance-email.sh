#!/usr/bin/env bash
# utilities/maintenance-email.sh — Runs VaultWarden email diagnostics.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_SAVE_SCRIPT_DIR="$PROJECT_ROOT"
source "$PROJECT_ROOT/lib/log.sh"
source "$PROJECT_ROOT/lib/config.sh"
source "$PROJECT_ROOT/lib/common.sh"
init_common_lib "$0"
source "$PROJECT_ROOT/lib/email.sh"
source "$PROJECT_ROOT/lib/docker.sh"
source "$PROJECT_ROOT/lib/backup-utils.sh"
source "$PROJECT_ROOT/lib/crypto.sh"
_MAINT_SCRIPT_DIR="$PROJECT_ROOT"
source "$PROJECT_ROOT/lib/secrets.sh"
SCRIPT_DIR="$_MAINT_SCRIPT_DIR"
unset _MAINT_SCRIPT_DIR
source "$PROJECT_ROOT/lib/storage.sh"
source "$PROJECT_ROOT/lib/maintenance-utils.sh"

trap 'log_error "${BASH_SOURCE[0]}: failed at line ${LINENO} (exit $?)"; exit 1' ERR

# Configuration defaults.
# TEST_EMAIL is always true for this utility (it is the email test tool).
# Exported so subprocesses or sourcing scripts can detect the test mode.
export TEST_EMAIL=true
TEST_RECIPIENT=""
VERBOSE=false
DRY_RUN=false

show_help() {
    cat << 'EOF'
VaultWarden-OCI Email Diagnostics

USAGE:
    sudo ./maintenance.sh test-email [OPTIONS]
    sudo utilities/maintenance-email.sh [OPTIONS]

OPTIONS:
    --recipient EMAIL   Override default admin email recipient
    --verbose           Show detailed diagnostic output
    --dry-run           Preview without sending
    --help, -h          Show this help
    --version, -V       Print the VaultWarden-OCI version and exit

EXIT CODES:
    0 — all email tests passed
    1 — one or more tests failed
EOF
}

_require_cli_value() {
    local opt="$1" value="${2-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        log_error "$opt requires an argument"
        show_help
        exit 2
    fi
}

_load_env() {
    if load_env_file 2>/dev/null; then return 0; fi
    log_warn "No .env file found — relying on environment already set"
    return 0
}

test_postfix_container() {
    log_info "Testing postfix container status..."
    local postfix_running
    postfix_running=$(docker inspect vaultwarden_postfix --format '{{.State.Running}}' 2>/dev/null || echo "false")
    if [[ "$postfix_running" == "true" ]]; then
        log_success "✅ postfix container is running"
        verbose_log "Container status: $(docker compose ps postfix --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}')"
    else
        log_error "❌ postfix container is not running"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "🔍 [DRY RUN] Would start postfix container"
            return 1
        fi
        log_info "Starting postfix container..."
        if docker compose up -d postfix; then
            sleep 15
            log_success "✅ postfix container started successfully"
        else
            log_error "❌ Failed to start postfix container"
            return 1
        fi
    fi
    if docker compose exec -T postfix postfix status >/dev/null 2>&1; then
        log_success "✅ postfix health check passed (port 587 responding)"
        verbose_log "$(docker compose exec -T postfix postfix status 2>&1 || true)"
    else
        log_error "❌ postfix health check failed (postfix master not running)"
        log_info "🔍 Check logs: docker compose logs postfix"
        return 1
    fi
    local recent_logs
    recent_logs=$(docker compose logs --tail 20 postfix 2>/dev/null | grep -i "error\|fatal" | grep -v "warning" || true)
    if [[ -n "$recent_logs" ]]; then
        log_warn "⚠️  Found recent errors in postfix logs:"
        echo "$recent_logs" | while read -r line; do log_warn "    $line"; done
    else
        verbose_log "No critical errors found in postfix logs"
    fi
    return 0
}

test_crowdsec_integration() {
    log_info "Testing CrowdSec integration..."
    if systemctl is-active crowdsec >/dev/null 2>&1; then
        log_success "✅ CrowdSec is running"
    else
        log_warn "⚠ CrowdSec is not running"
        log_info "💡 Start it with: sudo systemctl start crowdsec"
        return 0
    fi
    if sudo -n cscli metrics >/dev/null 2>&1; then
        log_success "✅ CrowdSec LAPI is responding"
    else
        log_warn "⚠ CrowdSec LAPI metrics unavailable without non-interactive root access; skipping optional cscli check"
    fi
    if systemctl is-active crowdsec-cloudflare-worker-bouncer >/dev/null 2>&1; then
        log_success "✅ CrowdSec Cloudflare bouncer is running"
    else
        log_warn "⚠ CrowdSec Cloudflare bouncer is not running"
        log_info "💡 Start it with: sudo systemctl start crowdsec-cloudflare-worker-bouncer"
    fi
}

test_host_script_email() {
    log_info "Testing host script email configuration and route selection..."
    if [[ -z "$TEST_RECIPIENT" ]]; then
        TEST_RECIPIENT=$(get_config_value "ADMIN_EMAIL" "")
        if [[ -z "$TEST_RECIPIENT" ]]; then
            log_error "❌ No email recipient configured (ADMIN_EMAIL not set)"
            return 1
        fi
    fi
    log_success "✅ Email recipient configured: $TEST_RECIPIENT"
    local sender_domains
    sender_domains=$(get_config_value "ALLOWED_SENDER_DOMAINS" "")
    if [[ -n "$sender_domains" ]]; then
        log_success "✅ Allowed sender domains configured: $sender_domains"
    else
        log_warn "⚠️  ALLOWED_SENDER_DOMAINS not set (postfix may reject emails)"
    fi
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
        log_info "🔍 [DRY RUN] Route depends on EMAIL_MODE: auto API → Postfix sidecar → direct SMTP; smtp Postfix sidecar → direct SMTP; direct direct SMTP only"
        return 0
    fi
    if [[ -z "$TEST_RECIPIENT" ]]; then
        log_error "❌ No test recipient specified"
        return 1
    fi
    local test_subject; test_subject="VaultWarden Email Test - email route - $(date)"
    local test_body
    test_body="VaultWarden notification test
Sent: $(date -Iseconds)
Host: $(hostname -f 2>/dev/null || hostname)

If you received this message, email delivery is working correctly."
    log_info "📧 Sending test email to: $TEST_RECIPIENT"
    if send_notification_email "$test_subject" "$test_body"; then
        log_success "✅ Test email sent successfully!"
        log_info "📬 Please check $TEST_RECIPIENT for the test message"
        log_info "🔍 Check configured route logs: API provider, postfix sidecar, or direct upstream SMTP"
    else
        log_error "❌ Failed to send test email"
        log_info "🔍 Debug steps:"
        log_info "   1. Confirm EMAIL_MODE routing (auto/api/smtp/direct/host alias)"
        log_info "   2. Check API provider response or postfix logs: docker compose logs postfix"
        log_info "   3. Verify SMTP_FROM, SMTP_HOST, SMTP_PORT, SMTP_USERNAME, and smtp_password for Direct fallback"
        log_info "   4. Verify ALLOWED_SENDER_DOMAINS in .env for sidecar delivery"
        log_info "   5. Check CrowdSec logs: sudo journalctl -u crowdsec -n 50 --no-pager"
        return 1
    fi
    return 0
}

run_email_diagnostics() {
    log_header "VaultWarden Email Diagnostic"
    local test_results=()
    local test_names=("postfix Container" "CrowdSec Integration" "Host Script Email" "End-to-End Email")
    test_postfix_container    && test_results+=(0) || test_results+=(1)
    test_crowdsec_integration && test_results+=(0) || test_results+=(1)
    test_host_script_email    && test_results+=(0) || test_results+=(1)
    test_end_to_end_email     && test_results+=(0) || test_results+=(1)
    local total_tests=${#test_results[@]}
    local passed_tests=0
    local failed_tests=()
    for i in "${!test_results[@]}"; do
        if [[ ${test_results[i]} -eq 0 ]]; then
            passed_tests=$((passed_tests + 1))
        else
            failed_tests+=("${test_names[i]}")
    done
    echo ""
    log_info "============================================"
    log_info "TEST RESULTS: $passed_tests/$total_tests tests passed"
    log_info "============================================"
    if [[ $passed_tests -eq $total_tests ]]; then
        log_success "🎉 ALL EMAIL TESTS PASSED!"
        log_success "✅ Your VaultWarden-OCI email deployment route is functioning correctly"
        return 0
    else
        log_error "❌ Some email tests failed: ${failed_tests[*]}"
        return 1
    fi
}

[[ "${1:-}" == "test-email" ]] && shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --recipient) _require_cli_value "$1" "${2-}"; TEST_RECIPIENT="$2"; shift 2 ;;
        --verbose)   VERBOSE=true;        shift   ;;
        --dry-run)   DRY_RUN=true;        shift   ;;
        --help|-h|help) show_help; exit 0 ;;
        --version|-V) print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"; exit 0 ;;
        *) log_error "Unknown option for 'test-email': $1"; show_help; exit 1 ;;
    esac
done
require_root "$@"
: "${VERBOSE}"

main() {
    _load_env
    run_email_diagnostics
    exit $?
}

main "$@"
