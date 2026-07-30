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
source "$PROJECT_ROOT/lib/validate.sh"
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
TEST_TRANSPORT="configured"
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
    --transport VALUE   Transport to test: configured, api, sidecar, direct, or all
                        (default: configured)
    --verbose           Show detailed diagnostic output
    --dry-run           Preview without sending
    --help, -h          Show this help
    --version, -V       Print the VaultWarden-OCI version and exit

EXIT CODES:
    0 — all email tests passed
    1 — one or more tests failed
    2 — invalid command-line usage
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

_validate_transport() {
    case "$TEST_TRANSPORT" in
        configured|api|sidecar|direct|all) return 0 ;;
        *)
            log_error "Invalid email test transport '${TEST_TRANSPORT}'."
            log_error "Valid values: configured api sidecar direct all"
            return 2
            ;;
    esac
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

_preflight_common_email() {
    local transport="$1" from
    log_info "Checking common email configuration for ${transport}..."
    if [[ -z "$TEST_RECIPIENT" ]]; then
        TEST_RECIPIENT=$(get_config_value "ADMIN_EMAIL" "")
        if [[ -z "$TEST_RECIPIENT" ]]; then
            log_error "❌ No email recipient configured (ADMIN_EMAIL not set)"
            return 1
        fi
    fi
    if ! validate_email "$TEST_RECIPIENT"; then
        log_error "❌ Invalid email recipient: $TEST_RECIPIENT"
        return 1
    fi
    log_success "✅ Email recipient configured: $TEST_RECIPIENT"

    from=$(resolve_email_sender) || return 1
    if ! validate_email "$from"; then
        log_error "❌ Invalid SMTP_FROM sender address: $from"
        return 1
    fi
    _email_sender_name >/dev/null || return 1
    log_success "✅ Email sender configured: $from"

    if [[ "$transport" == configured ]]; then
        if declare -f send_notification_email >/dev/null 2>&1; then
            log_success "✅ send_notification_email function available"
        else
            log_error "❌ send_notification_email function not available"
            return 1
        fi
    elif declare -f send_email_via_transport >/dev/null 2>&1; then
        log_success "✅ Exact-transport email function available"
    else
        log_error "❌ send_email_via_transport function not available"
        return 1
    fi
}

_preflight_api() {
    local provider="${EMAIL_PROVIDER:-mailersend}" driver fn
    if ! driver=$(_email_driver_lookup "$provider"); then
        log_error "❌ Unknown EMAIL_PROVIDER='${provider}' for API diagnostic"
        return 1
    fi
    fn="_email_driver_${driver}"
    if ! declare -f "$fn" >/dev/null 2>&1; then
        log_error "❌ EMAIL_PROVIDER='${provider}' resolves to unsupported driver '${driver}'"
        return 1
    fi
    log_success "✅ API provider configured: ${provider} (${driver})"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "🔍 [DRY RUN] API token presence will be verified only during a real send; its value is never displayed"
    fi
}

_preflight_sidecar() {
    local sender_domains
    sender_domains=$(get_config_value "ALLOWED_SENDER_DOMAINS" "")
    if [[ -n "$sender_domains" ]]; then
        log_success "✅ Allowed sender domains configured: $sender_domains"
    else
        log_warn "⚠️  ALLOWED_SENDER_DOMAINS not set (Postfix may reject email)"
    fi
    test_postfix_container
}

_preflight_direct() {
    local host="${SMTP_HOST:-}" port="${SMTP_PORT:-587}" user="${SMTP_USERNAME:-}"
    local security="${SMTP_SECURITY:-}"
    if [[ -z "$host" || -z "$port" || -z "$user" ]]; then
        log_error "❌ Direct SMTP requires SMTP_HOST, SMTP_PORT, and SMTP_USERNAME"
        return 1
    fi
    if _email_has_control "$host" || _email_has_control "$user"; then
        log_error "❌ Direct SMTP host and username must not contain control characters"
        return 1
    fi
    if ! validate_port "$port"; then
        log_error "❌ SMTP_PORT must be an integer from 1 to 65535"
        return 1
    fi
    case "${security,,}" in
        ""|tls|ssl|on|starttls|none|plain|off) ;;
        *)
            log_error "❌ Unknown SMTP_SECURITY='${security}'. Valid: tls starttls none"
            return 1
            ;;
    esac
    log_success "✅ Direct SMTP endpoint configured: ${host}:${port}"
    log_success "✅ Direct SMTP username configured"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "🔍 [DRY RUN] smtp_password presence will be verified only during a real send; its value is never displayed"
    fi
}

_preflight_configured() {
    local mode="${EMAIL_MODE:-auto}" provider="${EMAIL_PROVIDER:-mailersend}"
    local api_configured=true
    case "$mode" in
        api)
            _preflight_api || return 1
            ;;
        direct|host)
            _preflight_direct || return 1
            ;;
        smtp)
            if ! _preflight_sidecar; then
                log_warn "Configured smtp route can still exercise its direct-SMTP fallback"
                _preflight_direct || return 1
            fi
            ;;
        auto)
            if ! _email_driver_lookup "$provider" >/dev/null; then
                log_warn "Configured auto route has unknown EMAIL_PROVIDER='${provider}'; SMTP fallback remains eligible"
                api_configured=false
            fi
            if ! _preflight_sidecar; then
                if [[ "$api_configured" == true ]]; then
                    log_warn "Configured auto route can still use its API or direct-SMTP fallback"
                else
                    log_warn "Configured auto route must rely on direct SMTP because its API provider and sidecar are unavailable"
                    _preflight_direct || return 1
                fi
            fi
            ;;
        *)
            log_error "❌ Unknown EMAIL_MODE='${mode}'. Valid: auto api smtp direct host"
            return 1
            ;;
    esac
    log_info "Configured production route: EMAIL_MODE=${mode}"
}

_preflight_transport() {
    local transport="$1"
    _preflight_common_email "$transport" || return 1
    case "$transport" in
        configured) _preflight_configured ;;
        api)        _preflight_api ;;
        sidecar)    _preflight_sidecar ;;
        direct)     _preflight_direct ;;
    esac
}

_run_transport_test() {
    local transport="$1" timestamp test_subject test_body

    log_info "Testing email transport: ${transport}"
    if ! _preflight_transport "$transport"; then
        log_error "${transport}: failed (preflight)"
        return 1
    fi

    log_info "Recipient: $TEST_RECIPIENT"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "🔍 [DRY RUN] Would test transport '${transport}'"
        log_info "🔍 [DRY RUN] No email will be sent"
        log_success "${transport}: dry-run validated"
        return 0
    fi

    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    test_subject="VaultWarden Email Test - ${transport} - ${timestamp} - $$-${RANDOM}"
    test_body="VaultWarden email transport diagnostic
Transport: ${transport}
Sent: $(date -Iseconds)
Host: $(hostname -f 2>/dev/null || hostname)

This diagnostic requested the '${transport}' transport."

    log_info "📧 Sending ${transport} test email to: $TEST_RECIPIENT"
    if [[ "$transport" == configured ]]; then
        if send_notification_email "$test_subject" "$test_body"; then
            log_success "${transport}: passed"
            return 0
        fi
    elif send_email_via_transport "$transport" "$TEST_RECIPIENT" "$test_subject" "$test_body"; then
        log_success "${transport}: passed"
        return 0
    fi

    log_error "${transport}: failed"
    if [[ "$transport" == sidecar ]]; then
        log_info "🔍 Inspect acceptance, queue, and relay status: docker compose logs postfix; docker exec vaultwarden_postfix mailq"
    else
        log_info "🔍 Review the configuration and provider logs for '${transport}'"
    fi
    return 1
}

run_email_diagnostics() {
    log_header "VaultWarden Email Diagnostic"
    local transports=("$TEST_TRANSPORT")
    local passed=0 failed=0 transport
    local failed_transports=()

    if [[ "$TEST_TRANSPORT" == all ]]; then
        transports=(api sidecar direct)
    fi
    log_info "Selected transports: ${transports[*]}"
    log_info "CrowdSec status is supplemental and does not determine email transport results"
    if ! test_crowdsec_integration; then
        log_warn "Supplemental CrowdSec status could not be collected"
    fi

    for transport in "${transports[@]}"; do
        if _run_transport_test "$transport"; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
            failed_transports+=("$transport")
        fi
    done

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY-RUN SUMMARY: ${passed}/${#transports[@]} transport validations passed; ${failed} failed"
    else
        log_info "SUMMARY: ${passed}/${#transports[@]} transport tests passed; ${failed} failed"
    fi
    if (( failed > 0 )); then
        log_error "Failed transports: ${failed_transports[*]}"
        return 1
    fi
    return 0
}

[[ "${1:-}" == "test-email" ]] && shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --recipient) _require_cli_value "$1" "${2-}"; TEST_RECIPIENT="$2"; shift 2 ;;
        --transport) _require_cli_value "$1" "${2-}"; TEST_TRANSPORT="${2,,}"; shift 2 ;;
        --verbose)   VERBOSE=true;        shift   ;;
        --dry-run)   DRY_RUN=true;        shift   ;;
        --help|-h|help) show_help; exit 0 ;;
        --version|-V) print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"; exit 0 ;;
        *) log_error "Unknown option for 'test-email': $1"; show_help; exit 2 ;;
    esac
done
_validate_transport || exit $?
require_root "$@"
: "${VERBOSE}"

main() {
    _load_env
    local rc=0
    run_email_diagnostics || rc=$?
    exit "$rc"
}

main "$@"
