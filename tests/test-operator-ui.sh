#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="$ROOT/lib/common.sh"
KEY_ROTATE="$ROOT/utilities/key-rotate.sh"
BACKUP="$ROOT/utilities/backup-run.sh"
CROWDSEC="$ROOT/utilities/setup-crowdsec.sh"
SETUP_SECRETS="$ROOT/utilities/setup-secrets.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local file="$1" text="$2" label="$3"
    grep -Fq -- "$text" "$file" || fail "$label"
}

# shellcheck source=../lib/log.sh
source "$ROOT/lib/log.sh"
# shellcheck source=../lib/common.sh
source "$COMMON"
init_common_lib "$0"

prompt_output="$(operator_confirm_yes_no "Proceed with operator test?" "no" 0 <<< "no" 2>&1 >/dev/null || true)"
[[ "$prompt_output" == *"Proceed with operator test? [yes/no] (default: no): "* ]] \
    || fail "yes/no helper prompt does not display the default"

if ! operator_confirm_yes_no "Use default yes?" "yes" 0 <<< "" 2>/dev/null; then
    fail "yes/no helper did not accept an explicit default yes on empty input"
fi

if operator_confirm_yes_no "Use default no?" "no" 0 <<< "" 2>/dev/null; then
    fail "yes/no helper accepted default no as yes"
fi

if operator_confirm_yes_no "Timeout must fail closed?" "yes" 1 < <(sleep 2) 2>/dev/null; then
    fail "yes/no helper timeout did not fail closed"
fi

assert_contains "$COMMON" 'operator_attention()' "operator_attention helper missing"
assert_contains "$COMMON" 'operator_confirm_yes_no()' "operator_confirm_yes_no helper missing"
assert_contains "$COMMON" 'operator_next_steps()' "operator_next_steps helper missing"

assert_contains "$KEY_ROTATE" 'operator_confirm_yes_no "Continue with Age key rotation?" "no" 30' \
    "key rotation does not use explicit default-no confirmation"
assert_contains "$KEY_ROTATE" 'while [[ "$saved" != "SAVED" ]]' \
    "key rotation final SAVED acknowledgement was not preserved"

assert_contains "$BACKUP" "This passphrase protects only the emergency backup capsule." \
    "emergency backup passphrase role wording missing"
assert_contains "$BACKUP" '_print_backup_run_summary "$actual_type" "$backup_file" "$verification_status" "$offsite_status"' \
    "backup final summary call missing"
assert_contains "$BACKUP" '[[ "$QUIET" == "true" ]] && return 0' \
    "backup summary is not quiet-aware"
assert_contains "$BACKUP" 'Offsite sync: ${offsite_status}' \
    "backup summary does not report offsite sync"
assert_contains "$BACKUP" 'if [[ "$RCLONE_SYNC" == "true" ]]; then' \
    "backup verification failure must only mark offsite skipped when rclone was requested"
assert_contains "$BACKUP" 'offsite_status="skipped because verification failed"' \
    "backup summary missing verification-failure offsite skip state"
assert_contains "$BACKUP" "Backup archive was created, but quick verification failed; do not treat it as verified." \
    "backup verification partial-success warning missing"
assert_contains "$BACKUP" 'backup_log_success "Backup completed successfully"' \
    "backup success completion message missing"

list_block="$(awk '/if \[\[ "\$LIST_ONLY" == "true" \]\]/,/exit 0/' "$BACKUP")"
if grep -Fq 'operator_next_steps' <<< "$list_block"; then
    fail "backup list or JSON path should not emit operator summary"
fi

verify_failure_block="$(awk '/if ! verify_backup_quick/,/else/' "$BACKUP")"
if ! grep -Fq 'if [[ "$RCLONE_SYNC" == "true" ]]; then' <<< "$verify_failure_block"; then
    fail "backup verification failure should not change offsite status when rclone was not requested"
fi
success_tail="$(awk '/_print_backup_run_summary "\$actual_type"/,/exit 0/' "$BACKUP")"
if ! grep -Fq 'if [[ "$verify_failed" == "true" ]]; then' <<< "$success_tail"; then
    fail "backup completion must branch on verification failure"
fi
if ! grep -Fq 'else' <<< "$success_tail" || ! grep -Fq 'backup_log_success "Backup completed successfully"' <<< "$success_tail"; then
    fail "backup success message should remain only on the verified success branch"
fi

assert_contains "$SETUP_SECRETS" "If you skip it, disaster recovery depends on the operational Age key or an exported recovery kit." \
    "offline recovery skip consequence wording missing"
assert_contains "$SETUP_SECRETS" "Offline recovery Age public key skipped; encrypted secrets will not have a separate offline recovery recipient." \
    "offline recovery skip warning missing"

assert_contains "$CROWDSEC" "Manual Cloudflare action required" \
    "CrowdSec final manual action block missing"
assert_contains "$CROWDSEC" "Failure mode: Fail open" \
    "CrowdSec fail-open manual action wording missing"


run_db_maintenance_health_failure_behavior_test() {
    local tmpdir harness output status safety_backup
    tmpdir="$(mktemp -d)"
    harness="$tmpdir/repo/utilities/maintenance-db-maint.sh"
    mkdir -p "$tmpdir/repo/utilities"
    ln -s "$ROOT/lib" "$tmpdir/repo/lib"
    cp "$ROOT/utilities/maintenance-db-maint.sh" "$harness"
    sed -i.bak 's/^main "\$@"$/: # test harness: do not auto-run main/' "$harness"
    rm -f "$harness.bak"

    mkdir -p "$tmpdir/project/utilities" "$tmpdir/state/data" "$tmpdir/backups/db" "$tmpdir/bin"
    printf 'SQLite format 3\000' > "$tmpdir/state/data/db.sqlite3"
    cat > "$tmpdir/project/utilities/backup-run.sh" <<'MOCK_BACKUP'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${BACKUP_DIR}/db"
printf 'safety backup\n' > "${BACKUP_DIR}/db/vaultwarden-db-test.age"
touch "${BACKUP_DIR}/db/vaultwarden-db-test.age"
printf 'mock backup created\n'
MOCK_BACKUP
    chmod +x "$tmpdir/project/utilities/backup-run.sh"

    cat > "$tmpdir/bin/docker" <<'MOCK_DOCKER'
#!/usr/bin/env bash
printf 'mock docker %s\n' "$*" >&2
exit 0
MOCK_DOCKER
    cat > "$tmpdir/bin/sqlite3" <<'MOCK_SQLITE3'
#!/usr/bin/env bash
case "$*" in
    *integrity_check*) printf 'ok\n' ;;
    *) : ;;
esac
exit 0
MOCK_SQLITE3
    chmod +x "$tmpdir/bin/docker" "$tmpdir/bin/sqlite3"

    output="$( (
        set +e
        # shellcheck source=/dev/null
        source "$harness"
        PROJECT_ROOT="$tmpdir/project"
        PROJECT_STATE_DIR="$tmpdir/state"
        BACKUP_DIR="$tmpdir/backups"
        DB_DEEP_FORCE=true
        DRY_RUN=false
        export PROJECT_ROOT PROJECT_STATE_DIR BACKUP_DIR DB_DEEP_FORCE DRY_RUN
        PATH="$tmpdir/bin:$PATH"
        is_root() { return 0; }
        require_commands() { return 0; }
        require_docker() { return 0; }
        is_service_running() { return 0; }
        _wait_wal_quiesce() { return 0; }
        wait_for_service_ready() { return 1; }
        set +e
        run_deep_db_maintenance
        printf '__STATUS__=%s\n' "$?"
    ) 2>&1)"
    status="$(awk -F= '/^__STATUS__=/{print $2}' <<< "$output" | tail -1)"
    output="$(grep -v '^__STATUS__=' <<< "$output")"

    safety_backup="$tmpdir/backups/db/vaultwarden-db-test.age"
    [[ "$status" == "1" ]] || fail "db-maint health-failure path returned $status instead of non-zero; output: $output"
    [[ "$output" == *"vaultwarden did not become healthy in time"* ]] \
        || fail "db-maint health-failure output missing failed health state"
    [[ "$output" == *"VaultWarden was restarted but did not pass the health check."* ]] \
        || fail "db-maint health-failure output missing operator warning"
    [[ "$output" != *"VaultWarden is back online"* ]] \
        || fail "db-maint health-failure output incorrectly reports VaultWarden back online"
    [[ "$output" != *"Deep database maintenance complete!"* ]] \
        || fail "db-maint health-failure output incorrectly reports maintenance complete"
    [[ -f "$safety_backup" ]] \
        || fail "db-maint health-failure path did not retain safety backup"

    rm -rf "$tmpdir"
}

run_db_maintenance_health_failure_behavior_test

# Verify F-01: Deep db maintenance success output must be inside wait_for_service_ready success branch.
wait_block="$(awk '/if wait_for_service_ready/,/fi/' "$ROOT/utilities/maintenance-db-maint.sh")"
then_part="$(awk '/if wait_for_service_ready/,/else/' <<< "$wait_block")"
else_part="$(awk '/else/,/fi/' <<< "$wait_block")"

if ! grep -q 'log_success "VaultWarden is back online"' <<< "$then_part"; then
    fail "db-maint success message 'VaultWarden is back online' is not inside the wait_for_service_ready then-block"
fi
if ! grep -q 'log_success "Deep database maintenance complete!"' <<< "$then_part"; then
    fail "db-maint success message 'Deep database maintenance complete!' is not inside the wait_for_service_ready then-block"
fi
if ! grep -q 'log_warn "VaultWarden was restarted but did not pass the health check."' <<< "$else_part"; then
    fail "db-maint warning message is not inside the wait_for_service_ready else-block"
fi

printf 'Operator UI tests passed.\n'
