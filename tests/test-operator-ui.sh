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
assert_contains "$BACKUP" "Quick verification failed — backup is being discarded." \
    "backup verification discard warning missing"
assert_contains "$BACKUP" 'rm -f "$backup_file" "${backup_file}.meta" "${backup_file}.sha256" "${backup_file}.sha256.hmac"' \
    "backup verification failure does not discard archive and sidecars"
assert_contains "$BACKUP" "Backup failed: quick verification did not complete successfully." \
    "backup verification failure summary missing"
assert_contains "$BACKUP" 'backup_log_success "Backup completed successfully"' \
    "backup success completion message missing"

list_block="$(awk '/if \[\[ "\$LIST_ONLY" == "true" \]\]/,/exit 0/' "$BACKUP")"
if grep -Fq 'operator_next_steps' <<< "$list_block"; then
    fail "backup list or JSON path should not emit operator summary"
fi

verify_failure_block="$(awk '/if ! verify_backup_quick/,/exit 1/' "$BACKUP")"
if ! grep -Fq 'if [[ "$RCLONE_SYNC" == "true" ]]; then' <<< "$verify_failure_block"; then
    fail "backup verification failure should not change offsite status when rclone was not requested"
fi
grep -Fq 'exit 1' <<< "$verify_failure_block" || fail "backup quick-verification failure must exit non-zero before retention"
! grep -Fq 'cleanup_old_backups' <<< "$verify_failure_block" || fail "backup quick-verification failure must not run local retention before exit"
quick_fail_line="$(grep -n 'Backup failed: quick verification did not complete successfully.' "$BACKUP" | cut -d: -f1 | head -1)"
retention_line="$(grep -n 'cleanup_old_backups "$backup_dir"' "$BACKUP" | cut -d: -f1 | head -1)"
success_line="$(grep -n 'backup_log_success "Backup completed successfully"' "$BACKUP" | cut -d: -f1 | head -1)"
[[ -n "$quick_fail_line" && -n "$retention_line" && -n "$success_line" ]] || fail "backup verification ordering markers missing"
(( quick_fail_line < retention_line )) || fail "quick verification failure must be handled before retention"
(( quick_fail_line < success_line )) || fail "quick verification failure must be handled before success line"

assert_contains "$SETUP_SECRETS" "If you skip it, disaster recovery depends on the operational Age key or an exported recovery kit." \
    "offline recovery skip consequence wording missing"
assert_contains "$SETUP_SECRETS" "Offline recovery Age public key skipped; encrypted secrets will not have a separate offline recovery recipient." \
    "offline recovery skip warning missing"

assert_contains "$CROWDSEC" "Manual Cloudflare action required" \
    "CrowdSec final manual action block missing"
assert_contains "$CROWDSEC" "Failure mode: Fail open" \
    "CrowdSec fail-open manual action wording missing"

grep -Fq 'Config placeholders:' "$ROOT/dashboard.sh" || fail 'dashboard must label placeholder scan truthfully'
grep -Fq 'Configured (not probed)' "$ROOT/dashboard.sh" || fail 'dashboard rclone status must not claim Ready without probing'
grep -Fq 'No VaultWarden timers listed' "$ROOT/dashboard.sh" || fail 'dashboard timer empty state must distinguish successful empty query'
grep -Fq 'queue_str="${YLW}Unknown${NC}"' "$ROOT/dashboard.sh" || fail 'dashboard email queue failure state must be Unknown'
grep -Fq '0 queued' "$ROOT/dashboard.sh" || fail 'dashboard email queue empty state must say queued, not Healthy'
grep -Fq 'DB Snapshot Backup' "$ROOT/dashboard.sh" || fail 'dashboard DB backup label must not say incremental'
grep -Fq 'Backup Inventory' "$ROOT/dashboard.sh" || fail 'dashboard backup list label must not say health'
grep -Fq 'Create + Sync New DB Backup' "$ROOT/dashboard.sh" || fail 'dashboard rclone create/sync label missing'
grep -Fq 'Create + Fully Verify + Sync DB Backup' "$ROOT/dashboard.sh" || fail 'dashboard verified DB sync label missing'
! grep -Fq 'Last result' "$ROOT/dashboard.sh" || fail 'dashboard must not infer Last result from sidecars'
! grep -Fq '_last_backup_result' "$ROOT/dashboard.sh" || fail 'dashboard weak backup result helper should be deleted'
! grep -Fq 'Recent Auth Fails' "$ROOT/dashboard.sh" || fail 'dashboard broad auth failure counter should be removed'
! grep -Fq 'Start/Restart Stack     (safe)' "$ROOT/dashboard.sh" || fail 'dashboard ordinary restart must not be labeled safe'
! grep -Fq 'validate_ip' "$ROOT/dashboard.sh" || fail 'dashboard unban should let cscli validate address forms through make unban'
grep -Fq 'make -C "${REPO_ROOT}" unban "IP=${ip_to_unban}"' "$ROOT/dashboard.sh" || fail 'dashboard unban must route through make unban'
printf 'Dashboard truthfulness tests passed.\n'

SMOKE="$ROOT/utilities/smoke-test.sh"
grep -Fq 'source "$SCRIPT_DIR/lib/defaults.sh"' "$SMOKE" || fail 'smoke test must source canonical defaults'
grep -Fq 'local services=("${_VW_DEFAULT_CRITICAL_SERVICES[@]}")' "$SMOKE" || fail 'smoke test must use canonical critical service list'
grep -Fq 'status=$(_http_status "${base}/alive")' "$SMOKE" || fail 'smoke test must probe /alive'
! grep -Fq '/api/alive' "$SMOKE" || fail 'smoke test must not probe /api/alive'
grep -Fq '"${SCRIPT_DIR}/utilities/setup-systemd.sh" validate' "$SMOKE" || fail 'smoke test must call canonical systemd validator'
! grep -Fq 'check_startup_unit()' "$SMOKE" || fail 'smoke test should not duplicate startup unit validation'
! grep -Fq 'check_startup_service()' "$SMOKE" || fail 'smoke test should not require startup oneshot to be active'
grep -Fq 'none)' "$SMOKE" || fail 'smoke test must handle health=none explicitly'
grep -Fq '_check_fail "container-$svc" "running but no healthcheck status reported"' "$SMOKE" || fail 'critical container health=none must fail'
grep -Fq 'cscli decisions list -o raw' "$SMOKE" || fail 'CrowdSec readiness must perform cscli/LAPI query'
grep -Fq 'cscli decisions query failed' "$SMOKE" || fail 'CrowdSec query failure must not become PASS'
grep -Fq 'NOT READY — one or more checks were not completed.' "$SMOKE" || fail 'smoke skipped checks must produce NOT READY'
grep -Fq '(( _FAIL == 0 && _SKIP == 0 ))' "$SMOKE" || fail 'smoke zero exit must require no FAIL and no SKIP'
! grep -Fq 'local services=(vaultwarden caddy postfix)' "$SMOKE" || fail 'Postfix must not be hard-coded as critical readiness container'
printf 'Smoke readiness tests passed.\n'

DRILL="$ROOT/utilities/pre-production-drill.sh"
grep -Fq 'Compose restart preflight' "$DRILL" || fail 'drill must label compose check as preflight'
! grep -Fq 'Stack Restart Sequence' "$DRILL" || fail 'drill must not claim restart sequence rehearsal'
grep -Fq 'backup-run.sh" verify' "$DRILL" || fail 'drill must delegate latest backup verification to canonical verifier'
! grep -Fq 'backup-found:' "$DRILL" || fail 'drill must not preselect and name a different latest backup'
grep -Fq 'no db backup found — run a backup first or pass --skip-restore' "$DRILL" || fail 'missing DB restore backup must fail unless explicitly skipped'
grep -Fq 'sqlite3 not installed — install sqlite3 or pass --skip-restore' "$DRILL" || fail 'missing sqlite3 restore prerequisite must fail unless explicitly skipped'
grep -Fq 'no full backup directory found' "$DRILL" || fail 'missing full restore artifact must be checked'
grep -Fq 'all non-skipped steps passed' "$DRILL" || fail 'drill summary must be truthful when explicit skips exist'
grep -Fq "trap '_handle_signal 130' INT" "$DRILL" || fail 'drill INT handler must exit 130'
grep -Fq "trap '_handle_signal 143' TERM" "$DRILL" || fail 'drill TERM handler must exit 143'
printf 'Drill truthfulness tests passed.\n'


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
