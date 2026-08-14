#!/usr/bin/env bash
# utilities/smoke-test.sh — Verifies the VaultWarden-OCI stack before production go-live.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/defaults.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/schema.sh"
source "$SCRIPT_DIR/lib/common.sh"
init_common_lib "$0"
DOCKER_PROJECT_LABEL="${DOCKER_PROJECT_LABEL:-label=com.docker.compose.project=vaultwarden-oci}"
source "$SCRIPT_DIR/lib/docker.sh"
source "$SCRIPT_DIR/lib/backup-utils.sh"
source "$SCRIPT_DIR/lib/crypto.sh"
source "$SCRIPT_DIR/lib/storage.sh"
source "$SCRIPT_DIR/lib/crowdsec.sh"

QUIET=false
JSON_OUTPUT=false
FAIL_FAST=false

show_help() {
    cat <<'EOF'
VaultWarden-OCI Smoke Test

USAGE:
    sudo ./utilities/smoke-test.sh [OPTIONS]

DESCRIPTION:
    Verifies the VaultWarden-OCI stack is healthy before or after production
    go-live. Checks containers, TLS, HTTP endpoints, secrets, backups, and
    CrowdSec. Safe to run at any time on a live stack.

OPTIONS:
    --quiet       Suppress per-check output; only show summary
    --fail-fast   Stop on first failure
    --json        Emit a JSON result array (implies --quiet)
    --help, -h    Show this help
    --version, -V Print the VaultWarden-OCI version and exit

EXIT CODES:
    0  All checks passed
    1  One or more checks failed

EXAMPLES:
    sudo ./utilities/smoke-test.sh
    sudo ./utilities/smoke-test.sh --quiet
    sudo ./utilities/smoke-test.sh --json
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet)    QUIET=true;    shift ;;
        --json)     JSON_OUTPUT=true; shift ;;
        --fail-fast) FAIL_FAST=true; shift ;;
        --help|-h)  show_help; exit 0 ;;
        --version|-V) print_project_version "VaultWarden-OCI" "$SCRIPT_DIR"; exit 0 ;;
        help)       show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

[[ "$JSON_OUTPUT" == true ]] && QUIET=true

declare -a _CHECK_NAMES=()
declare -a _CHECK_RESULTS=() # PASS | FAIL | SKIP
declare -a _CHECK_DETAILS=()

_PASS=0
_FAIL=0
_SKIP=0
PROJECT_ENVIRONMENT_LOADED=false

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
    [[ "$QUIET" == false ]] && log_success "  [PASS] $name${detail:+: $detail}"
    return 0; }

_check_fail() { local name="$1" detail="${2:-}"; _record "$name" FAIL "$detail"
    log_warn   "  [FAIL] $name${detail:+: $detail}"
    # Clear the EXIT trap before printing so the summary appears exactly once.
    [[ "$FAIL_FAST" == true ]] && { trap - EXIT; log_error "Stopping on first failure (--fail-fast)."; _print_summary; exit 1; }
    return 0; }

_check_skip() { local name="$1" detail="${2:-}"; _record "$name" SKIP "$detail"
    [[ "$QUIET" == false ]] && log_info   "  [SKIP] $name${detail:+: $detail}"
    return 0; }

_http_status() {
    local status
    if ! status="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null)"; then
        printf '000\n'
        return 0
    fi
    printf '%s\n' "$status"
}

_container_running() {
    docker compose ps --services --filter status=running 2>/dev/null | grep -qx "$1"
}

_require_project_environment() {
    local check_name="$1"
    if [[ "$PROJECT_ENVIRONMENT_LOADED" != true ]]; then
        _check_skip "$check_name" "project environment unavailable"
        return 1
    fi
    return 0
}

load_smoke_test_environment() {
    [[ "$QUIET" == false ]] && log_info "Loading canonical project environment..."
    if load_project_environment; then
        PROJECT_ENVIRONMENT_LOADED=true
        _check_pass "project-environment" "canonical project environment loaded"
    else
        _check_fail "project-environment" \
            "load_project_environment failed; environment-dependent checks will be skipped"
    fi
}

check_domain_configured() {
    [[ "$QUIET" == false ]] && log_info "Checking DOMAIN configuration..."
    _require_project_environment "domain-configured" || return 0
    local domain="${DOMAIN:-}"
    if [[ -z "$domain" || "$domain" == *"example.com"* ]]; then
        _check_fail "domain-configured" "DOMAIN is unset or still set to example.com"
    elif [[ "$domain" != https://* ]]; then
        _check_fail "domain-configured" "normal production readiness requires an https:// DOMAIN"
    else
        _check_pass "domain-configured" "$domain"
    fi
}

check_compose_config() {
    [[ "$QUIET" == false ]] && log_info "Checking Docker Compose configuration..."
    if ! has_command docker; then
        _check_fail "compose-config" "Docker is unavailable"
        return
    fi
    if ! docker compose version >/dev/null 2>&1; then
        _check_fail "compose-config" "Docker Compose plugin is unavailable"
        return
    fi

    local compose_file="${SCRIPT_DIR}/docker-compose.yml"
    if [[ ! -f "$compose_file" ]]; then
        _check_fail "compose-config" "configuration not found: $compose_file"
    elif docker compose -f "$compose_file" config --quiet >/dev/null 2>&1; then
        _check_pass "compose-config" "docker-compose.yml is valid"
    else
        _check_fail "compose-config" \
            "docker compose -f docker-compose.yml config --quiet failed"
    fi
}

check_containers_running() {
    [[ "$QUIET" == false ]] && log_info "Checking container health..."
    if ! has_command docker; then
        _check_fail "container-readiness" "Docker is unavailable"
        return
    fi
    if ! docker compose version >/dev/null 2>&1; then
        _check_fail "container-readiness" "Docker Compose plugin is unavailable"
        return
    fi
    local services=("${_VW_DEFAULT_CRITICAL_SERVICES[@]}")
    for svc in "${services[@]}"; do
        if _container_running "$svc"; then
            local health
            health=$(docker inspect --format '{{.State.Health.Status}}' \
                "$(docker compose ps -q "$svc" 2>/dev/null)" 2>/dev/null || echo "none")
            case "$health" in
                healthy)
                    _check_pass "container-$svc" "running (health: $health)" ;;
                starting)
                    _check_skip "container-$svc" "still starting — re-run after warmup" ;;
                none)
                    _check_fail "container-$svc" "running but no healthcheck status reported" ;;
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
    _require_project_environment "tls-cert" || return 0
    local domain="${DOMAIN:-}"
    [[ -z "$domain" ]] && { _check_skip "tls-cert" "DOMAIN not set"; return; }
    if [[ "$domain" != https://* ]]; then
        _check_fail "tls-verified" "DOMAIN is not HTTPS"
        return
    fi
    if ! curl -sS --max-time 10 -o /dev/null "${domain%/}/" 2>/dev/null; then
        _check_fail "tls-verified" "certificate trust or hostname verification failed for ${domain%/}"
        return
    fi
    _check_pass "tls-verified" "certificate chain and hostname verified"

    local host="${domain#https://}"
    host="${host%%/*}"

    # expiry_date_str holds the raw notAfter date string (e.g. "Jun 15 12:00:00 2026 GMT")
    local expiry_date_str
    expiry_date_str=$(echo | openssl s_client -connect "${host}:443" -servername "$host" \
        2>/dev/null | openssl x509 -noout -enddate 2>/dev/null \
        | sed 's/notAfter=//' || true)

    if [[ -z "$expiry_date_str" ]]; then
        _check_fail "tls-cert" "could not retrieve certificate from ${host}:443"
        return
    fi

    local expiry_epoch days_left
    expiry_epoch=$(date -d "$expiry_date_str" +%s 2>/dev/null \
        || date -j -f '%b %d %T %Y %Z' "$expiry_date_str" +%s 2>/dev/null || echo 0)
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
    _require_project_environment "http-endpoints" || return 0
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

    status=$(_http_status "${base}/alive")
    if [[ "$status" == "200" ]]; then
        _check_pass "http-alive" "VaultWarden readiness responding (HTTP 200)"
    else
        _check_fail "http-alive" "unexpected HTTP ${status} from /alive"
    fi

    # /admin should be protected: 401 or 403 is correct, and 200 means it is unprotected.
    status=$(_http_status "${base}/admin")
    case "$status" in
        401|403) _check_pass  "http-admin-protected" "admin panel protected (HTTP ${status})" ;;
        200)     _check_fail  "http-admin-protected" "admin panel returned 200 — check ADMIN_TOKEN config" ;;
        *)       _check_skip  "http-admin-protected" "unexpected HTTP ${status} — check Caddy logs" ;;
    esac
}

check_age_key() {
    [[ "$QUIET" == false ]] && log_info "Checking age key health..."
    _require_project_environment "age-key" || return 0
    # check_age_key_health reads AGE_KEY_FILE, so pass it the key path resolved
    # by the canonical project environment.
    local key_file="/etc/vaultwarden/age-key.txt"
    if [[ ! -f "$key_file" ]]; then
        _check_fail "age-key" "key file not found: $key_file"
        return
    fi
    local perms
    perms=$(stat -c '%a' "$key_file" 2>/dev/null || echo "unknown")
    if [[ "$perms" != "600" ]]; then
        _check_fail "age-key-perms" "key file permissions are ${perms}, expected 600"
    else
        _check_pass "age-key-perms" "$key_file (mode 600)"
    fi

    if AGE_KEY_FILE="$key_file" check_age_key_health 2>/dev/null; then
        _check_pass "age-key-valid" "key is readable and valid"
    else
        _check_fail "age-key-valid" "age key health check failed — run: make key-health"
    fi
}

check_secrets_decryptable() {
    [[ "$QUIET" == false ]] && log_info "Checking secrets decryptable..."
    _require_project_environment "secrets-decryptable" || return 0
    local secrets_file="${SECRETS_FILE:-}"
    local key_file="/etc/vaultwarden/age-key.txt"
    if [[ ! -f "$secrets_file" ]]; then
        _check_fail "secrets-file" "secrets file not found: $secrets_file"
        return
    fi
    if [[ ! -f "$key_file" ]]; then
        _check_fail "secrets-key" "SOPS Age key not found: $key_file"
        return
    fi
    if SOPS_AGE_KEY_FILE="$key_file" sops -d "$secrets_file" >/dev/null 2>&1; then
        _check_pass "secrets-decryptable" "SOPS decryption succeeded: $secrets_file"
    else
        _check_fail "secrets-decryptable" \
            "SOPS decryption failed for $secrets_file using key $key_file"
    fi
}

check_docker_secrets_materialized() {
    [[ "$QUIET" == false ]] && log_info "Checking Docker secrets materialized..."
    local secrets_dir="${DOCKER_SECRETS_DIR:-/run/vaultwarden-oci/secrets}"
    local required_secrets=() key
    if ! schema_validate; then
        _check_fail "runtime-secret-inventory" "secrets schema validation failed"
        return
    fi
    while IFS= read -r key; do
        [[ "$(schema_apply_type_for_key "$key")" == "compose_restart" ]] || continue
        required_secrets+=("$key")
    done < <(schema_keys)

    if [[ ! -d "$secrets_dir" ]]; then
        if [[ -f /etc/systemd/system/vaultwarden-startup.service ]]; then
            _check_fail "runtime-secrets-dir" \
                "missing: $secrets_dir — run: sudo systemctl start vaultwarden-startup.service"
        else
            _check_fail "runtime-secrets-dir" \
                "missing: $secrets_dir — run: sudo ./setup.sh systemd install"
        fi
        return
    fi

    local dir_stat
    dir_stat=$(stat -c '%U:%G %a' "$secrets_dir" 2>/dev/null \
        || echo "unknown")
    if [[ "$dir_stat" == "root:root 700" ]]; then
        _check_pass "runtime-secrets-dir" "$secrets_dir (root:root mode 0700)"
    else
        _check_fail "runtime-secrets-dir" \
            "$secrets_dir has ${dir_stat}, expected root:root 700"
    fi

    for secret in "${required_secrets[@]}"; do
        local secret_file="$secrets_dir/$secret"
        if [[ ! -f "$secret_file" ]]; then
            _check_fail "secret-$secret" "missing: $secret_file"
            continue
        fi
        if [[ ! -s "$secret_file" ]]; then
            _check_fail "secret-$secret" "empty: $secret_file"
            continue
        fi

        local file_stat
        file_stat=$(stat -c '%U:%G %a' "$secret_file" 2>/dev/null \
            || echo "unknown")
        if [[ "$file_stat" == "root:root 444" ]]; then
            _check_pass "secret-$secret-permissions" \
                "$secret_file (root:root mode 0444)"
        else
            _check_fail "secret-$secret-permissions" \
                "$secret_file has ${file_stat}, expected root:root 444"
        fi

        # Detect CHANGE_ME placeholder values left in materialized secret files.
        if grep -qF 'CHANGE_ME' "$secret_file" 2>/dev/null; then
            _check_fail "secret-$secret-content" \
                "$secret_file contains CHANGE_ME — rotate with: ./edit-secrets.sh rotate $secret"
        else
            _check_pass "secret-$secret-content" "$secret_file is non-empty and has no CHANGE_ME placeholder"
        fi
    done
}

check_backup_exists() {
    [[ "$QUIET" == false ]] && log_info "Checking recent backup exists..."
    _require_project_environment "backup-recent" || return 0
    local base_dir
    base_dir="$(get_config_value "BACKUP_DIR" "$(vw_default_backup_dir 2>/dev/null || echo "${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}/backups")")"

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

check_systemd_automation() {
    [[ "$QUIET" == false ]] && log_info "Checking installed systemd automation..."
    if ! has_command systemctl; then
        _check_fail "systemd-automation" "systemctl not available"
        return
    fi
    if "${SCRIPT_DIR}/utilities/setup-systemd.sh" validate >/dev/null 2>&1; then
        _check_pass "systemd-automation" "setup-systemd validation passed"
    else
        _check_fail "systemd-automation" "run: sudo ./utilities/setup-systemd.sh validate"
    fi
}

check_crowdsec() {
    [[ "$QUIET" == false ]] && log_info "Checking CrowdSec..."
    _require_project_environment "crowdsec" || return 0
    if ! has_command cscli; then
        _check_fail "crowdsec" "cscli not installed"
        return
    fi
    if ! has_command systemctl; then
        _check_fail "crowdsec" "systemctl not available"
        return
    fi
    if ! systemctl is-active --quiet crowdsec 2>/dev/null; then
        _check_fail "crowdsec" "crowdsec service not running"
        return
    fi

    local decisions_output decisions
    if ! decisions_output="$(cscli decisions list -o raw 2>&1)"; then
        _check_fail "crowdsec" "cscli decisions query failed"
        return
    fi
    decisions="$(printf '%s\n' "$decisions_output" | tail -n +2 | grep -c . || true)"
    _check_pass "crowdsec" "active (${decisions} decision(s) in effect)"

    local readiness_rc=0
    crowdsec_worker_readiness || readiness_rc=$?
    case "$readiness_rc" in
        0)
            _check_pass "crowdsec-edge-bouncer" "$CROWDSEC_READINESS_DETAIL"
            ;;
        10)
            _check_skip "crowdsec-edge-bouncer" "$CROWDSEC_READINESS_DETAIL; not normal production readiness"
            ;;
        *)
            _check_fail "crowdsec-edge-bouncer" "$CROWDSEC_READINESS_DETAIL"
            ;;
    esac
}

check_disk_space() {
    [[ "$QUIET" == false ]] && log_info "Checking disk space..."
    _require_project_environment "disk-space" || return 0
    local state_dir="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}"
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
    elif (( _SKIP > 0 )); then
        log_error "NOT READY — one or more checks were not completed."
    else
        log_success "All checks passed — stack is ready for production."
    fi
}

main() {
    require_root
    trap '_print_summary' EXIT

    [[ "$QUIET" == false ]] && log_header "VaultWarden-OCI Smoke Test"

    load_smoke_test_environment
    check_domain_configured
    check_compose_config
    check_containers_running
    check_tls_certificate
    check_http_endpoints
    check_age_key
    check_secrets_decryptable
    check_docker_secrets_materialized
    check_backup_exists
    check_systemd_automation
    check_crowdsec
    check_disk_space

    (( _FAIL == 0 && _SKIP == 0 ))
}

main "$@"
