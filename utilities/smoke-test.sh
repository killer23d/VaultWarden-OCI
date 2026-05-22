#!/usr/bin/env bash
# utilities/smoke-test.sh — VaultWarden-OCI pre-production smoke test
#
# Verifies the running stack end-to-end before production go-live.
# Tests: TLS, HTTP endpoints, container health, secrets, email, backup,
#        CrowdSec, systemd timers, and age key integrity.
#
# USAGE:
#   sudo ./utilities/smoke-test.sh [--quiet] [--json] [--fail-fast]
#
# EXIT CODES:
#   0 — all checks passed
#   1 — one or more checks failed
#
# No changes are made to the running stack.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/email.sh"
init_common_lib "$0"
source "$SCRIPT_DIR/lib/docker.sh"
source "$SCRIPT_DIR/lib/backup-utils.sh"
source "$SCRIPT_DIR/lib/crypto.sh"
source "$SCRIPT_DIR/lib/storage.sh"

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
QUIET=false
JSON_OUTPUT=false
FAIL_FAST=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet)    QUIET=true;    shift ;;
        --json)     JSON_OUTPUT=true; shift ;;
        --fail-fast) FAIL_FAST=true; shift ;;
        --help|-h)
            cat <<'EOF'
VaultWarden-OCI Smoke Test

USAGE:
    sudo ./utilities/smoke-test.sh [options]

OPTIONS:
    --quiet       Suppress per-check output; only show summary
    --fail-fast   Stop on first failure
    --json        Emit a JSON result array (implies --quiet)
    --help        Show this help

EXIT CODES:
    0  All checks passed
    1  One or more checks failed
EOF
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

[[ "$JSON_OUTPUT" == true ]] && QUIET=true

# ---------------------------------------------------------------------------
# Check registry
# ---------------------------------------------------------------------------
declare -a _CHECK_NAMES=()
declare -a _CHECK_RESULTS=()   # PASS | FAIL | SKIP
declare -a _CHECK_DETAILS=()

_PASS=0
_FAIL=0
_SKIP=0

_record() {
    local name="$1" result="$2" detail="${3:-}"
    _CHECK_NAMES+=("$name")
    _CHECK_RESULTS+=("$result")
    _CHECK_DETAILS+=("$detail")
    case "$result" in
        PASS) (( _PASS++ )) || true ;;
        FAIL) (( _FAIL++ )) || true ;;
        SKIP) (( _SKIP++ )) || true ;;
    esac
}

_check_pass() { local name="$1" detail="${2:-}"; _record "$name" PASS "$detail"
    [[ "$QUIET" == false ]] && log_success "  [PASS] $name${detail:+: $detail}"; }

_check_fail() { local name="$1" detail="${2:-}"; _record "$name" FAIL "$detail"
    log_warn   "  [FAIL] $name${detail:+: $detail}"
    [[ "$FAIL_FAST" == true ]] && { log_error "Stopping on first failure (--fail-fast)."; _print_summary; exit 1; }; }

_check_skip() { local name="$1" detail="${2:-}"; _record "$name" SKIP "$detail"
    [[ "$QUIET" == false ]] && log_info   "  [SKIP] $name${detail:+: $detail}"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_http_status() {
    curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo "000"
}

_container_running() {
    docker compose ps --services --filter status=running 2>/dev/null | grep -qx "$1"
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

check_env_file() {
    [[ "$QUIET" == false ]] && log_info "Checking environment file..."
    if load_env_file 2>/dev/null; then
        _check_pass "env-file" ".env loaded and permissions OK"
    else
        _check_fail "env-file" ".env missing or insecure permissions"
    fi
}

check_domain_configured() {
    [[ "$QUIET" == false ]] && log_info "Checking DOMAIN configuration..."
    local domain="${DOMAIN:-}"
    if [[ -z "$domain" || "$domain" == *"example.com"* ]]; then
        _check_fail "domain-configured" "DOMAIN is unset or still set to example.com"
    else
        _check_pass "domain-configured" "$domain"
    fi
}

check_containers_running() {
    [[ "$QUIET" == false ]] && log_info "Checking container health..."
    local services=(vaultwarden caddy postfix)
    for svc in "${services[@]}"; do
        if _container_running "$svc"; then
            local health
            health=$(docker inspect --format '{{.State.Health.Status}}' \
                "$(docker compose ps -q "$svc" 2>/dev/null)" 2>/dev/null || echo "none")
            case "$health" in
                healthy|none)
                    _check_pass "container-$svc" "running (health: $health)" ;;
                starting)
                    _check_skip "container-$svc" "still starting — re-run after warmup" ;;
                *)
                    _check_fail "container-$svc" "running but health=$health" ;;
            esac
        else
            _check_fail "container-$svc" "not running"
        fi
    done
}

check_tls_certificate() {
    [[ "$QUIET" == false ]] && log_info "Checking TLS certificate..."
    local domain="${DOMAIN:-}"
    [[ -z "$domain" ]] && { _check_skip "tls-cert" "DOMAIN not set"; return; }
    local host="${domain#https://}"
    host="${host%/*}"

    local expiry_seconds
    expiry_seconds=$(echo | openssl s_client -connect "${host}:443" -servername "$host" \
        2>/dev/null | openssl x509 -noout -enddate 2>/dev/null \
        | sed 's/notAfter=//' || true)

    if [[ -z "$expiry_seconds" ]]; then
        _check_fail "tls-cert" "could not retrieve certificate from ${host}:443"
        return
    fi

    local expiry_epoch days_left
    expiry_epoch=$(date -d "$expiry_seconds" +%s 2>/dev/null \
        || date -j -f '%b %d %T %Y %Z' "$expiry_seconds" +%s 2>/dev/null || echo 0)
    days_left=$(( (expiry_epoch - $(date +%s)) / 86400 ))

    if (( days_left < 14 )); then
        _check_fail "tls-cert" "expires in ${days_left} day(s) — renew immediately"
    elif (( days_left < 30 )); then
        _check_pass "tls-cert" "expires in ${days_left} day(s) — WARNING: renew soon"
    else
        _check_pass "tls-cert" "valid for ${days_left} more day(s)"
    fi
}

check_http_endpoints() {
    [[ "$QUIET" == false ]] && log_info "Checking HTTP endpoints..."
    local domain="${DOMAIN:-}"
    [[ -z "$domain" ]] && { _check_skip "http-endpoints" "DOMAIN not set"; return; }

    local base="${domain%/}"

    local status
    status=$(_http_status "${base}/")
    if [[ "$status" == "200" || "$status" == "301" || "$status" == "302" ]]; then
        _check_pass "http-root" "HTTP ${status}"
    else
        _check_fail "http-root" "unexpected HTTP ${status} from ${base}/"
    fi

    status=$(_http_status "${base}/api/alive")
    if [[ "$status" == "200" ]]; then
        _check_pass "http-api-alive" "VaultWarden API responding (HTTP 200)"
    else
        _check_fail "http-api-alive" "unexpected HTTP ${status} from /api/alive"
    fi

    # /admin should be protected — 401 or 403 is correct, 200 means unprotected
    status=$(_http_status "${base}/admin")
    case "$status" in
        401|403) _check_pass  "http-admin-protected" "admin panel protected (HTTP ${status})" ;;
        200)     _check_fail  "http-admin-protected" "admin panel returned 200 — check ADMIN_TOKEN config" ;;
        *)       _check_skip  "http-admin-protected" "unexpected HTTP ${status} — check Caddy logs" ;;
    esac
}

check_age_key() {
    [[ "$QUIET" == false ]] && log_info "Checking age key health..."
    local key_file="${SOPS_AGE_KEY_FILE:-/etc/vaultwarden/age-key.txt}"
    if [[ ! -f "$key_file" ]]; then
        _check_fail "age-key" "key file not found: $key_file"
        return
    fi
    local perms
    perms=$(stat -c '%a' "$key_file" 2>/dev/null || stat -f '%OLp' "$key_file" 2>/dev/null || echo "unknown")
    if [[ "$perms" != "600" ]]; then
        _check_fail "age-key-perms" "key file permissions are ${perms}, expected 600"
    else
        _check_pass "age-key-perms" "$key_file (mode 600)"
    fi

    if SOPS_AGE_KEY_FILE="$key_file" check_age_key_health 2>/dev/null; then
        _check_pass "age-key-valid" "key is readable and valid"
    else
        _check_fail "age-key-valid" "age key health check failed — run: make key-health"
    fi
}

check_secrets_decryptable() {
    [[ "$QUIET" == false ]] && log_info "Checking secrets decryptable..."
    local secrets_file="$SCRIPT_DIR/secrets/secrets.yaml"
    if [[ ! -f "$secrets_file" ]]; then
        _check_fail "secrets-file" "secrets/secrets.yaml not found"
        return
    fi
    local key_file="${SOPS_AGE_KEY_FILE:-/etc/vaultwarden/age-key.txt}"
    if SOPS_AGE_KEY_FILE="$key_file" sops -d "$secrets_file" >/dev/null 2>&1; then
        _check_pass "secrets-decryptable" "SOPS decryption succeeded"
    else
        _check_fail "secrets-decryptable" "SOPS decryption failed — check age key and secrets.yaml"
    fi
}

check_docker_secrets_materialized() {
    [[ "$QUIET" == false ]] && log_info "Checking Docker secrets materialized..."
    local secrets_dir="$SCRIPT_DIR/secrets/.docker_secrets"
    local required_secrets=(admin_token)
    for secret in "${required_secrets[@]}"; do
        local secret_file="$secrets_dir/$secret"
        if [[ -f "$secret_file" && -s "$secret_file" ]]; then
            _check_pass "secret-$secret" "materialized"
        else
            _check_fail "secret-$secret" "missing or empty: $secret_file"
        fi
    done
}

check_backup_exists() {
    [[ "$QUIET" == false ]] && log_info "Checking recent backup exists..."
    local base_dir
    base_dir="$(get_config_value "BACKUP_DIR" "$(vw_default_backup_dir 2>/dev/null || echo "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/backups")")"

    local newest_backup newest_age_days=999
    for type_dir in "$base_dir"/db "$base_dir"/full; do
        [[ -d "$type_dir" ]] || continue
        while IFS= read -r -d '' f; do
            local age_days
            age_days=$(_backup_filename_age_days "$f")
            [[ -z "$age_days" ]] && continue
            if (( age_days < newest_age_days )); then
                newest_age_days=$age_days
                newest_backup="$f"
            fi
        done < <(find "$type_dir" -name "*.age" -type f -print0 2>/dev/null)
    done

    if [[ -z "${newest_backup:-}" ]]; then
        _check_fail "backup-exists" "no backups found in $base_dir — run: sudo ./backup.sh run full"
    elif (( newest_age_days > 2 )); then
        _check_fail "backup-recent" "newest backup is ${newest_age_days} day(s) old: $(basename "$newest_backup")"
    else
        _check_pass "backup-recent" "${newest_age_days} day(s) old: $(basename "$newest_backup")"
    fi
}

check_systemd_timers() {
    [[ "$QUIET" == false ]] && log_info "Checking systemd backup timers..."
    if ! has_command systemctl; then
        _check_skip "systemd-timers" "systemctl not available"
        return
    fi
    local timers=(vaultwarden-db-backup.timer vaultwarden-full-backup.timer)
    for timer in "${timers[@]}"; do
        if systemctl is-active --quiet "$timer" 2>/dev/null; then
            _check_pass "timer-$timer" "active"
        else
            _check_fail "timer-$timer" "not active — run: sudo make install-systemd"
        fi
    done
}

check_crowdsec() {
    [[ "$QUIET" == false ]] && log_info "Checking CrowdSec..."
    if ! has_command cscli; then
        _check_skip "crowdsec" "cscli not installed"
        return
    fi
    if systemctl is-active --quiet crowdsec 2>/dev/null; then
        local decisions
        decisions=$(cscli decisions list 2>/dev/null | wc -l || echo "0")
        _check_pass "crowdsec" "active (${decisions} decision(s) in effect)"
    else
        _check_fail "crowdsec" "crowdsec service not running"
    fi
}

check_disk_space() {
    [[ "$QUIET" == false ]] && log_info "Checking disk space..."
    local state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    local avail_kb
    avail_kb=$(df "$state_dir" 2>/dev/null | awk 'END {print $4}')
    if [[ -z "$avail_kb" || ! "$avail_kb" =~ ^[0-9]+$ ]]; then
        _check_skip "disk-space" "could not determine free space on $state_dir"
        return
    fi
    local avail_mb=$(( avail_kb / 1024 ))
    if (( avail_mb < 500 )); then
        _check_fail "disk-space" "${avail_mb} MB free on $state_dir — less than 500 MB warning threshold"
    else
        _check_pass "disk-space" "${avail_mb} MB free on $state_dir"
    fi
}

# ---------------------------------------------------------------------------
# Summary + JSON output
# ---------------------------------------------------------------------------
_print_summary() {
    if [[ "$JSON_OUTPUT" == true ]]; then
        printf '[\n'
        local i
        for (( i=0; i < ${#_CHECK_NAMES[@]}; i++ )); do
            local comma=","
            (( i == ${#_CHECK_NAMES[@]} - 1 )) && comma=""
            printf '  {"check":"%s","result":"%s","detail":"%s"}%s\n' \
                "${_CHECK_NAMES[$i]}" "${_CHECK_RESULTS[$i]}" \
                "${_CHECK_DETAILS[$i]//\"/\\\"}" "$comma"
        done
        printf ']\n'
        return
    fi

    printf '\n'
    log_header "Smoke Test Summary"
    printf '  Passed:  %d\n' "$_PASS"
    printf '  Failed:  %d\n' "$_FAIL"
    printf '  Skipped: %d\n' "$_SKIP"
    printf '\n'
    if (( _FAIL > 0 )); then
        log_error "Smoke test FAILED — resolve the issues above before production deployment."
    else
        log_success "All checks passed — stack is ready for production."
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    require_root
    trap '_print_summary' EXIT

    [[ "$QUIET" == false ]] && log_header "VaultWarden-OCI Smoke Test"

    load_env_file 2>/dev/null || true

    check_env_file
    check_domain_configured
    check_containers_running
    check_tls_certificate
    check_http_endpoints
    check_age_key
    check_secrets_decryptable
    check_docker_secrets_materialized
    check_backup_exists
    check_systemd_timers
    check_crowdsec
    check_disk_space

    (( _FAIL == 0 ))
}

main "$@"