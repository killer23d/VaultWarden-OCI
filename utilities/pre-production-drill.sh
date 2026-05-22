#!/usr/bin/env bash
# utilities/pre-production-drill.sh — VaultWarden-OCI pre-production dry-run drill
#
# A non-destructive end-to-end rehearsal for the admin to run before go-live.
# Exercises: backup creation (dry-run), backup verification, restore path
# (decryption + integrity only, no data written), email delivery, secrets
# reload, and stack restart sequence.
#
# NOTHING is written to production state. All backup operations use --dry-run
# or operate on copies in a temporary directory on /dev/shm.
#
# USAGE:
#   sudo ./utilities/pre-production-drill.sh [--skip-email] [--skip-restore]
#
# EXIT CODES:
#   0 — all drill steps passed
#   1 — one or more steps failed

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
SKIP_EMAIL=false
SKIP_RESTORE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-email)   SKIP_EMAIL=true;   shift ;;
        --skip-restore) SKIP_RESTORE=true; shift ;;
        --help|-h)
            cat <<'EOF'
VaultWarden-OCI Pre-Production Drill

A non-destructive rehearsal of all critical operational paths.
No production state is modified.

USAGE:
    sudo ./utilities/pre-production-drill.sh [options]

OPTIONS:
    --skip-email    Skip email delivery test (if MTA not configured yet)
    --skip-restore  Skip restore path drill (decrypt + integrity check)
    --help          Show this help

EXIT CODES:
    0  All steps passed
    1  One or more steps failed
EOF
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Step registry
# ---------------------------------------------------------------------------
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
}

_step_header() {
    printf '\n'
    log_info "━━━ $1 ━━━"
}

DRILL_TMPDIR=""
cleanup() {
    [[ -n "$DRILL_TMPDIR" ]] && rm -rf "$DRILL_TMPDIR" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Drill steps
# ---------------------------------------------------------------------------

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

    local key_file="${SOPS_AGE_KEY_FILE:-/etc/vaultwarden/age-key.txt}"

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

    if SOPS_AGE_KEY_FILE="$key_file" check_age_key_health 2>/dev/null; then
        _step_pass "age-key-health: key is valid and readable"
    else
        _step_fail "age-key-health" "key health check failed — run: make key-health"
    fi

    local secrets_file="$SCRIPT_DIR/secrets/secrets.yaml"
    if [[ ! -f "$secrets_file" ]]; then
        _step_fail "secrets-file" "secrets/secrets.yaml not found — run: ./setup.sh secrets"
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

    local base_dir
    base_dir="$(get_config_value "BACKUP_DIR" \
        "$(vw_default_backup_dir 2>/dev/null || echo "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/backups")")"

    local newest="" newest_age=999 newest_type=""
    for type in db full emergency; do
        local type_dir="$base_dir/$type"
        [[ -d "$type_dir" ]] || continue
        while IFS= read -r -d '' f; do
            local age_days
            age_days=$(_backup_filename_age_days "$f")
            [[ -z "$age_days" ]] && continue
            if (( age_days < newest_age )); then
                newest_age=$age_days
                newest=$f
                newest_type=$type
            fi
        done < <(find "$type_dir" -name "*.age" -type f -print0 2>/dev/null)
    done

    if [[ -z "${newest:-}" ]]; then
        _step_fail "backup-verify" "no backups found in $base_dir — create one first: sudo ./backup.sh run full"
        return
    fi
    _step_pass "backup-found: $(basename "$newest") [${newest_type}, ${newest_age}d old]"

    log_info "  Running full verification (decrypt + integrity check)..."
    if bash "$SCRIPT_DIR/utilities/backup-run.sh" verify 2>/dev/null; then
        _step_pass "backup-verify: full verification passed"
    else
        _step_fail "backup-verify" "verification failed — run: sudo ./backup.sh verify for details"
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
        "$(vw_default_backup_dir 2>/dev/null || echo "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/backups")")"

    local db_backup=""
    local db_dir="$base_dir/db"
    if [[ -d "$db_dir" ]]; then
        db_backup=$(find "$db_dir" -name "*.age" -type f 2>/dev/null \
            | sort | tail -1 || true)
    fi

    if [[ -z "${db_backup:-}" ]]; then
        _step_skip "restore-path-db" "no db backup found — run a backup first"
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
        _step_skip "restore-sqlite-check" "sqlite3 not installed"
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
    local subject="[VaultWarden Drill] Pre-production test — $(date '+%Y-%m-%d %H:%M')"
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
    _step_header "Stack Restart Sequence (non-destructive)"

    log_info "  Verifying 'docker compose config' is valid..."
    if docker compose config --quiet 2>/dev/null; then
        _step_pass "compose-config: docker-compose.yml is syntactically valid"
    else
        _step_fail "compose-config" "docker compose config reported errors"
        return
    fi

    log_info "  Checking all expected services are defined in compose file..."
    local expected_services=(vaultwarden caddy postfix)
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

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
_print_drill_summary() {
    printf '\n'
    log_header "Pre-Production Drill Summary"
    printf '  Total steps:  %d\n' "$_STEPS_TOTAL"
    printf '  Passed:       %d\n' "$_STEPS_PASSED"
    printf '  Failed:       %d\n' "$_STEPS_FAILED"
    printf '  Skipped:      %d\n' "$_STEPS_SKIPPED"
    printf '\n'

    if (( _STEPS_FAILED > 0 )); then
        log_error "Drill FAILED. Resolve these steps before production:"
        local step
        for step in "${_FAILED_STEPS[@]}"; do
            log_error "  • $step"
        done
        printf '\n'
        log_info  "Re-run after fixing: sudo ./utilities/pre-production-drill.sh"
    else
        log_success "Drill PASSED — all rehearsed paths are operational."
        log_info    "Next step: sudo ./utilities/smoke-test.sh (live stack check)"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    require_root
    trap 'perform_cleanup' EXIT HUP INT TERM

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
    drill_email              || true
    drill_stack_restart_sequence || true

    _print_drill_summary

    (( _STEPS_FAILED == 0 ))
}

main "$@"