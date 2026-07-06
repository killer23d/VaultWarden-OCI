#!/usr/bin/env bash
# utilities/pre-production-drill.sh — Runs a non-destructive pre-production rehearsal for VaultWarden-OCI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
init_common_lib "$0"
source "$SCRIPT_DIR/lib/email.sh"
DOCKER_PROJECT_LABEL="${DOCKER_PROJECT_LABEL:-label=com.docker.compose.project=vaultwarden-oci}"
source "$SCRIPT_DIR/lib/docker.sh"
source "$SCRIPT_DIR/lib/backup-utils.sh"
source "$SCRIPT_DIR/lib/crypto.sh"
source "$SCRIPT_DIR/lib/storage.sh"

SKIP_EMAIL=false
SKIP_RESTORE=false

show_help() {
    cat <<'EOF'
VaultWarden-OCI Pre-Production Drill

USAGE:
    sudo ./utilities/pre-production-drill.sh [OPTIONS]

DESCRIPTION:
    Non-destructive pre-production check of critical operational paths.
    No production state is modified. Validates secrets, backups, email
    delivery, and Compose restart preflight before go-live.

OPTIONS:
    --skip-email    Skip email delivery test (if MTA not configured yet)
    --skip-restore  Skip restore path drill (decrypt + integrity check)
    --help, -h      Show this help
    --version, -V   Print the VaultWarden-OCI version and exit

EXIT CODES:
    0  All non-skipped steps passed
    1  One or more steps failed

EXAMPLES:
    sudo ./utilities/pre-production-drill.sh
    sudo ./utilities/pre-production-drill.sh --skip-email
    sudo ./utilities/pre-production-drill.sh --skip-email --skip-restore
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-email)   SKIP_EMAIL=true;   shift ;;
        --skip-restore) SKIP_RESTORE=true; shift ;;
        --help|-h) show_help; exit 0 ;;
        --version|-V) print_project_version "VaultWarden-OCI" "$SCRIPT_DIR"; exit 0 ;;
        help)      show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

_STEPS_TOTAL=0
_STEPS_PASSED=0
_STEPS_FAILED=0
_STEPS_SKIPPED=0
declare -a _FAILED_STEPS=()

_step_pass() {
    log_success "  ✓ $1"
    (( _STEPS_PASSED++ )) || true
    (( _STEPS_TOTAL++  )) || true
}

_step_fail() {
    log_error "  ✗ $1${2:+: $2}"
    _FAILED_STEPS+=("$1")
    (( _STEPS_FAILED++ )) || true
    (( _STEPS_TOTAL++  )) || true
}

_step_skip() {
    log_info  "  — $1 (skipped${2:+: $2})"
    (( _STEPS_SKIPPED++ )) || true
    (( _STEPS_TOTAL++   )) || true
}

_step_header() {
    printf '\n'
    log_info "━━━ $1 ━━━"
}

DRILL_TMPDIR=""
_DRILL_START=$(date +%s)


drill_environment() {
    _step_header "Environment"

    if load_env_file 2>/dev/null; then
        _step_pass "env-load: .env loaded successfully"
    else
        _step_fail "env-load" ".env missing or has insecure permissions — abort"
        return 1
    fi

    local required_vars=(DOMAIN ADMIN_EMAIL PROJECT_STATE_DIR)
    local missing=()
    for v in "${required_vars[@]}"; do
        [[ -z "${!v:-}" ]] && missing+=("$v")
    done
    if (( ${#missing[@]} > 0 )); then
        _step_fail "env-required-vars" "missing: ${missing[*]}"
    else
        _step_pass "env-required-vars: DOMAIN=${DOMAIN}, PROJECT_STATE_DIR=${PROJECT_STATE_DIR}"
    fi

    if require_project_state_ready 2>/dev/null; then
        _step_pass "storage-ready: PROJECT_STATE_DIR is mounted and accessible"
    else
        _step_fail "storage-ready" "PROJECT_STATE_DIR not ready — check volume mount"
    fi
}

drill_secrets() {
    _step_header "Secrets & Encryption Keys"

    # resolve_age_key_path() inside check_age_key_health reads AGE_KEY_FILE, not
    # SOPS_AGE_KEY_FILE — use AGE_KEY_FILE so the env prefix is honoured.
    local key_file="${AGE_KEY_FILE:-${SOPS_AGE_KEY_FILE:-/etc/vaultwarden/age-key.txt}}"

    if [[ ! -f "$key_file" ]]; then
        _step_fail "age-key-exists" "not found at $key_file"
        return
    fi
    _step_pass "age-key-exists: $key_file"

    local perms
    perms=$(stat -c '%a' "$key_file" 2>/dev/null || stat -f '%OLp' "$key_file" 2>/dev/null || echo "???")
    if [[ "$perms" == "600" ]]; then
        _step_pass "age-key-perms: mode 600"
    else
        _step_fail "age-key-perms" "mode is ${perms}, expected 600 — run: chmod 600 $key_file"
    fi

    if AGE_KEY_FILE="$key_file" check_age_key_health 2>/dev/null; then
        _step_pass "age-key-health: key is valid and readable"
    else
        _step_fail "age-key-health" "key health check failed — run: make key-health"
    fi

    local secrets_file="${SECRETS_FILE:-${SCRIPT_DIR}/secrets/secrets.yaml}"
    if [[ ! -f "$secrets_file" ]]; then
        _step_fail "secrets-file" "secrets file not found: ${secrets_file} — run: sudo ./setup.sh secrets"
        return
    fi

    local sops_out
    if sops_out=$(SOPS_AGE_KEY_FILE="$key_file" sops -d "$secrets_file" 2>&1); then
        local secret_count
        secret_count=$(printf '%s\n' "$sops_out" | grep -c '^\s*[a-zA-Z_].*:' || true)
        _step_pass "secrets-decrypt: ${secret_count} secret(s) decrypted successfully"
    else
        _step_fail "secrets-decrypt" "SOPS decryption failed — check key and secrets.yaml"
    fi
    unset sops_out
}

drill_backup_dryrun() {
    _step_header "Backup Dry-Run"

    if ! has_command age; then
        _step_fail "backup-deps-age" "age not installed — run: apt install age"
        return
    fi
    _step_pass "backup-deps: age present"

    log_info "  Running: backup-run.sh run db --dry-run ..."
    local dry_out
    if dry_out=$(bash "$SCRIPT_DIR/utilities/backup-run.sh" run db --dry-run 2>&1); then
        _step_pass "backup-db-dryrun: completed without error"
    else
        _step_fail "backup-db-dryrun" "exited non-zero — output: $(printf '%s' "$dry_out" | tail -3)"
    fi

    if dry_out=$(bash "$SCRIPT_DIR/utilities/backup-run.sh" run full --dry-run 2>&1); then
        _step_pass "backup-full-dryrun: completed without error"
    else
        _step_fail "backup-full-dryrun" "exited non-zero — output: $(printf '%s' "$dry_out" | tail -3)"
    fi
    unset dry_out
}

drill_backup_verify() {
    _step_header "Backup Verification (latest backup)"

    log_info "  Running canonical full verification (decrypt + integrity check)..."
    local verify_out
    if verify_out="$(bash "$SCRIPT_DIR/utilities/backup-run.sh" verify 2>&1)"; then
        local target_line
        target_line="$(printf '%s\n' "$verify_out" | grep -m1 'Target:' || true)"
        _step_pass "backup-verify: full verification passed${target_line:+ — ${target_line}}"
    else
        _step_fail "backup-verify" "verification failed — tail: $(printf '%s\n' "$verify_out" | tail -5 | tr '\n' '; ')"
    fi
}

drill_restore_path() {
    if [[ "$SKIP_RESTORE" == true ]]; then
        _step_skip "restore-path" "--skip-restore passed"
        return
    fi

    _step_header "Restore Path (decrypt + integrity, no data written)"

    local base_dir
    base_dir="$(get_config_value "BACKUP_DIR" \
        "$(vw_default_backup_dir 2>/dev/null || echo "${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}/backups")")"

    local db_backup=""
    local db_dir="$base_dir/db"
    if [[ -d "$db_dir" ]]; then
        db_backup=$(find "$db_dir" -name "*.age" -type f 2>/dev/null \
            | sort | tail -1 || true)
    fi

    if [[ -z "${db_backup:-}" ]]; then
        _step_fail "restore-path-db" "no db backup found — run a backup first or pass --skip-restore"
        return
    fi

    local key_file="${SOPS_AGE_KEY_FILE:-/etc/vaultwarden/age-key.txt}"
    log_info "  Decrypting latest DB backup to /dev/shm for integrity check..."
    log_info "  Source: $(basename "$db_backup")"

    local restore_tmp
    restore_tmp=$(mktemp -d -p /dev/shm 2>/dev/null || mktemp -d -t vw_drill.XXXXXXXXXX)
    local dec_db="$restore_tmp/drill_db.sqlite3"
    register_cleanup rm -rf "$restore_tmp"

    if age -d -i "$key_file" -o "$dec_db" "$db_backup" 2>/dev/null; then
        _step_pass "restore-decrypt: DB backup decrypted to /dev/shm (no disk write)"
    else
        _step_fail "restore-decrypt" "age decryption failed — wrong key or corrupt archive"
        rm -rf "$restore_tmp"
        return
    fi

    if has_command sqlite3; then
        local ic_result
        ic_result=$(sqlite3 "$dec_db" "PRAGMA integrity_check;" 2>&1 || true)
        if [[ "$ic_result" == "ok" ]]; then
            _step_pass "restore-integrity: SQLite PRAGMA integrity_check passed"
        else
            _step_fail "restore-integrity" "integrity_check returned: ${ic_result}"
        fi

        local schema_ver
        schema_ver=$(sqlite3 "$dec_db" "PRAGMA user_version;" 2>/dev/null || echo "unknown")
        _step_pass "restore-schema: user_version=${schema_ver}"
    else
        _step_fail "restore-sqlite-check" "sqlite3 not installed — install sqlite3 or pass --skip-restore"
    fi

    rm -rf "$restore_tmp"
}

drill_email() {
    if [[ "$SKIP_EMAIL" == true ]]; then
        _step_skip "email" "--skip-email passed"
        return
    fi

    _step_header "Email Delivery"

    local admin_email="${ADMIN_EMAIL:-}"
    if [[ -z "$admin_email" ]]; then
        _step_fail "email-config" "ADMIN_EMAIL not set in .env"
        return
    fi

    log_info "  Sending drill notification to $admin_email ..."
    local subject
    subject="[VaultWarden Drill] Pre-production test — $(date '+%Y-%m-%d %H:%M')"
    local body
    body="$(printf 'This is an automated pre-production drill notification.\n\nHost: %s\nDomain: %s\nTimestamp: %s\n\nIf you received this, email delivery is working correctly.\n' \
        "$(hostname -f 2>/dev/null || hostname)" \
        "${DOMAIN:-unknown}" \
        "$(date -Iseconds)")"

    if send_notification_email "$subject" "$body" 2>/dev/null; then
        _step_pass "email-delivery: notification sent to $admin_email"
        log_info "  ↳ Check your inbox to confirm receipt."
    else
        _step_fail "email-delivery" "send_notification_email returned non-zero — check email config"
    fi
}

drill_stack_restart_sequence() {
    _step_header "Compose restart preflight (non-destructive)"

    log_info "  Verifying 'docker compose config' is valid..."
    if docker compose config --quiet 2>/dev/null; then
        _step_pass "compose-config: docker-compose.yml is syntactically valid"
    else
        _step_fail "compose-config" "docker compose config reported errors"
        return
    fi

    log_info "  Checking all expected services are defined in compose file..."
    # init-permissions has restart:"no" so it won't be running, but it must be
    # defined. The 'docker compose config --services' output lists all defined
    # services regardless of restart policy.
    local expected_services=(vaultwarden caddy postfix init-permissions)
    local defined_services
    defined_services=$(docker compose config --services 2>/dev/null || true)
    for svc in "${expected_services[@]}"; do
        if printf '%s\n' "$defined_services" | grep -qx "$svc"; then
            _step_pass "compose-service-$svc: defined in compose file"
        else
            _step_fail "compose-service-$svc" "not found in docker-compose.yml"
        fi
    done
}

drill_full_backup_restore_smoketest() {
    _step_header "Full Backup Restore Smoke-Test (decrypt + manifest, non-destructive)"

    local base_dir
    base_dir="$(get_config_value "BACKUP_DIR" \
        "$(vw_default_backup_dir 2>/dev/null || echo "${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}/backups")")"

    local full_dir="$base_dir/full"
    if [[ ! -d "$full_dir" ]]; then
        _step_fail "restore-smoketest" "no full backup directory found at $full_dir — run a full backup or pass --skip-restore"
        return
    fi

    local backup_file
    backup_file=$(find "$full_dir" -name "*.age" -type f 2>/dev/null \
        | sort | tail -1 || true)

    if [[ -z "${backup_file:-}" ]]; then
        _step_fail "restore-smoketest" "no .age files found in $full_dir — run a full backup or pass --skip-restore"
        return
    fi
    _step_pass "restore-smoketest-found: $(basename "$backup_file")"

    local key_file="${SOPS_AGE_KEY_FILE:-/etc/vaultwarden/age-key.txt}"
    local tmpdir
    tmpdir=$(mktemp -d)
    register_cleanup rm -rf "$tmpdir"

    log_info "  Decrypting + listing manifest (no actual restore)..."
    # Use --use-compress-program to match verify_backup_full() exactly; -I flag
    # is GNU-only and conflicts with -z (gzip). zstd -d -T0 decompresses multi-threaded.
    if age -d -i "$key_file" "$backup_file" 2>/dev/null \
        | tar --use-compress-program='zstd -d -T0' -t > "$tmpdir/manifest.txt" 2>&1; then
        _step_pass "restore-smoketest-decrypt: archive decrypted and manifest extracted"
    else
        _step_fail "restore-smoketest-decrypt" "failed to decrypt or list archive contents"
        rm -rf "$tmpdir"
        return
    fi

    local missing_files=()
    # Use -F (fixed-string) so the dot in filenames is not treated as a regex wildcard.
    if ! grep -qF 'docker-compose.yml' "$tmpdir/manifest.txt" 2>/dev/null; then
        missing_files+=("docker-compose.yml")
    fi
    if ! grep -qF '.env.example' "$tmpdir/manifest.txt" 2>/dev/null; then
        missing_files+=(".env.example")
    fi

    if (( ${#missing_files[@]} == 0 )); then
        local file_count
        file_count=$(wc -l < "$tmpdir/manifest.txt")
        _step_pass "restore-smoketest-manifest: ${file_count} files; docker-compose.yml and .env.example present"
    else
        _step_fail "restore-smoketest-manifest" "missing expected files: ${missing_files[*]}"
    fi

    rm -rf "$tmpdir"

    log_info "  NOTE: Full restore was NOT performed — this is a decrypt + manifest"
    log_info "  check only. For a full restore test, use: ./restore.sh latest --dry-run"
}

_print_drill_summary() {
    local end_epoch elapsed mins secs duration
    end_epoch=$(date +%s)
    elapsed=$(( end_epoch - _DRILL_START ))
    mins=$(( elapsed / 60 ))
    secs=$(( elapsed % 60 ))
    if (( mins > 0 )); then
        duration="${mins}m ${secs}s"
    else
        duration="${secs}s"
    fi

    printf '\n'
    log_header "Pre-Production Drill Summary"
    printf '  %s%-10s%s %d / %d steps (%s elapsed)\n' \
        "${COLOR_GREEN}" "Passed:" "${COLOR_RESET}" "$_STEPS_PASSED" "$_STEPS_TOTAL" "$duration"
    if (( _STEPS_SKIPPED > 0 )); then
        printf '  %s%-10s%s %d\n' "${COLOR_YELLOW}" "Skipped:" "${COLOR_RESET}" "$_STEPS_SKIPPED"
    fi

    if (( _STEPS_FAILED > 0 )); then
        printf '\n  %s%-10s%s %d\n\n' "${COLOR_BOLD_RED}" "FAILED:" "${COLOR_RESET}" "$_STEPS_FAILED"
        printf '  %sFailed steps:%s\n' "${COLOR_BOLD_RED}" "${COLOR_RESET}"
        local step
        for step in "${_FAILED_STEPS[@]}"; do
            printf '    %s• %s%s\n' "${COLOR_RED}" "$step" "${COLOR_RESET}"
        done
        printf '\n'
        log_error "Drill FAILED — resolve the issues above before go-live."
        log_info  "Re-run after fixing: sudo ./utilities/pre-production-drill.sh"
    else
        printf '\n'
        if (( _STEPS_SKIPPED > 0 )); then
            log_success "Drill PASSED — all non-skipped steps passed."
        else
            log_success "Drill PASSED — all steps passed."
        fi
        log_info    "Next step: sudo ./utilities/smoke-test.sh (live stack check)"
    fi
}

_handle_signal() {
    local rc="$1"
    trap - EXIT HUP INT TERM
    perform_cleanup
    exit "$rc"
}

main() {
    _DRILL_START=$(date +%s)
    require_root
    trap 'perform_cleanup' EXIT
    trap '_handle_signal 129' HUP
    trap '_handle_signal 130' INT
    trap '_handle_signal 143' TERM

    DRILL_TMPDIR=$(mktemp -d -p /dev/shm 2>/dev/null || mktemp -d -t vw_drill_main.XXXXXXXXXX)
    register_cleanup rm -rf "$DRILL_TMPDIR"

    log_header "VaultWarden-OCI Pre-Production Drill"
    log_info "Mode: non-destructive (no production state modified)"
    log_info "Host: $(hostname -f 2>/dev/null || hostname)"
    log_info "Time: $(date -Iseconds)"

    drill_environment        || true
    drill_secrets            || true
    drill_backup_dryrun      || true
    drill_backup_verify      || true
    drill_restore_path       || true
    drill_full_backup_restore_smoketest || true
    drill_email              || true
    drill_stack_restart_sequence || true

    _print_drill_summary

    (( _STEPS_FAILED == 0 ))
}

main "$@"
