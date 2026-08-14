#!/usr/bin/env bash
# Consolidated operator UI regression suite.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

check_operator_ui_contracts() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
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
assert_contains "$BACKUP" 'Offsite sync: ${offsite_status}' \
    "backup summary does not report offsite sync"
assert_contains "$BACKUP" "Quick verification failed — backup is being discarded." \
    "backup verification discard warning missing"
assert_contains "$BACKUP" "Backup failed: quick verification did not complete successfully." \
    "backup verification failure summary missing"
assert_contains "$BACKUP" 'backup_log_success "Backup completed successfully"' \
    "backup success completion message missing"

list_block="$(awk '/if \[\[ "\$LIST_ONLY" == "true" \]\]/,/exit 0/' "$BACKUP")"
if grep -Fq 'operator_next_steps' <<< "$list_block"; then
    fail "backup list or JSON path should not emit operator summary"
fi

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
health_quick_block="$(awk '/^health-quick:/,/^health-report:/' "$ROOT/Makefile")"
grep -Fq './utilities/maintenance-health.sh --quick --quiet' <<<"$health_quick_block" \
    || fail 'make health-quick must pass the quick profile explicitly'
grep -Fq 'run_sudo_cmd "sudo make health-quick" make -C "${REPO_ROOT}" health-quick' "$ROOT/dashboard.sh" \
    || fail 'dashboard Quick Health Check must invoke make health-quick'
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
grep -Fq 'Email Operations' "$ROOT/dashboard.sh" || fail 'dashboard email operations submenu is missing'
grep -Fq 'Postfix Queue Operations' "$ROOT/dashboard.sh" || fail 'nested Postfix queue submenu is missing'
grep -Fq 'ACTIVE_MENU="email_operations"' "$ROOT/dashboard.sh" || fail 'identity menu must open the email operations submenu'
grep -Fq 'ACTIVE_MENU="email_queue"' "$ROOT/dashboard.sh" || fail 'email operations must open the nested queue submenu'
grep -Fq 'ACTIVE_MENU="identity"' "$ROOT/dashboard.sh" || fail 'email operations must return to identity'
grep -Fq 'ACTIVE_MENU="email_operations"' "$ROOT/dashboard.sh" || fail 'queue submenu must return to email operations'
grep -Fq 'make -C "${REPO_ROOT}" test-email "EMAIL_TEST_TRANSPORT=${transport}"' "$ROOT/dashboard.sh" \
    || fail 'dashboard email diagnostics must use the stable Make target'
for target in email-queue-summary email-queue email-queue-inspect email-queue-retry email-queue-delete email-queue-retry-all email-queue-logs email-queue-purge; do
    grep -Fq "make -C \"\${REPO_ROOT}\" ${target}" "$ROOT/dashboard.sh" \
        || fail "dashboard queue action must use stable Make target ${target}"
done
grep -Fq 'Delete a message' "$ROOT/dashboard.sh" || fail 'single delete must be visibly destructive'
grep -Fq 'Purge current queue snapshot' "$ROOT/dashboard.sh" || fail 'snapshot purge must be visibly destructive'
grep -Fq 'summary --quiet' "$ROOT/dashboard.sh" || fail 'live queue count must use centralized quiet summary'
! grep -Fq 'docker exec "${CONTAINER_POSTFIX}" mailq' "$ROOT/dashboard.sh" \
    || fail 'dashboard still duplicates human mailq parsing'
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
printf 'safety backup\n' > "${BACKUP_DIR}/db/db_backup_20990101_000000.sqlite3.age"
touch "${BACKUP_DIR}/db/db_backup_20990101_000000.sqlite3.age"
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

    safety_backup="$tmpdir/backups/db/db_backup_20990101_000000.sqlite3.age"
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

)

check_operator_ui_contracts
check_dashboard_process_snapshot_behavior() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d -t vw-dashboard-snapshot.XXXXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

fixture="$TMP/repo"
bin="$TMP/bin"
mkdir -p "$fixture" "$bin" "$TMP/counts" "$TMP/backups"
cp "$ROOT/dashboard.sh" "$ROOT/VERSION" "$fixture/"
ln -s "$ROOT/lib" "$fixture/lib"
sed -i 's/^main "$@"$/: # fixture: do not auto-run dashboard/' "$fixture/dashboard.sh"

cat > "$bin/docker" <<'MOCK_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

increment() {
    local file="$1" count=0
    [[ -f "$file" ]] && count="$(<"$file")"
    printf '%s\n' "$((count + 1))" > "$file"
}

scenario="${DASHBOARD_DOCKER_SCENARIO:-normal}"
case "${1:-}" in
    compose)
        [[ "$*" == 'compose --project-name vaultwarden-oci ps --all --format json' ]] || exit 97
        increment "${DASHBOARD_COMPOSE_COUNT_FILE:?}"
        case "$scenario" in
            normal)
                cat <<'JSON'
{"Service":"vaultwarden","Name":"vaultwarden_app","State":"running","Health":"healthy"}
{"Service":"caddy","Name":"vaultwarden_caddy","State":"running","Health":"starting"}
{"Service":"caddy","Name":"vaultwarden-oci-caddy-run-deadbeef","State":"exited","Health":""}
JSON
                ;;
            unknown)
                cat <<'JSON'
[
  {"Service":"vaultwarden","Name":"vaultwarden_app","State":"running","Health":"mystery"},
  {"Service":"caddy","Name":"vaultwarden_caddy","State":"mystery","Health":"healthy"},
  {"Service":"postfix","Name":"vaultwarden_postfix","State":"exited","Health":""}
]
JSON
                ;;
            error)
                exit 1
                ;;
            *) exit 96 ;;
        esac
        ;;
    inspect)
        increment "${DASHBOARD_INSPECT_COUNT_FILE:?}"
        printf '%s\n' "$*" >> "${DASHBOARD_INSPECT_ARGS_FILE:?}"
        shift
        [[ "${1:-}" == '--format' ]] || exit 95
        shift 2
        for container in "$@"; do
            case "$container" in
                vaultwarden_app|vaultwarden_caddy|vaultwarden_postfix)
                    printf '/%s|2026-08-05T18:00:00.000000000Z\n' "$container"
                    ;;
            esac
        done
        ;;
    ps)
        printf 'forbidden docker ps: %s\n' "$*" >> "${DASHBOARD_FORBIDDEN_FILE:?}"
        exit 94
        ;;
    *) exit 93 ;;
esac
MOCK_DOCKER

cat > "$bin/stat" <<'MOCK_STAT'
#!/usr/bin/env bash
set -euo pipefail
file="${@: -1}"
name="${file##*/}"
count_file="${DASHBOARD_STAT_COUNT_DIR:?}/$name"
count=0
[[ -f "$count_file" ]] && count="$(<"$count_file")"
printf '%s\n' "$((count + 1))" > "$count_file"
case "$name" in
    older.age)  printf '100\n' ;;
    middle.age) printf '200\n' ;;
    newest.age) printf '300\n' ;;
    *) exit 1 ;;
esac
MOCK_STAT
chmod +x "$bin/docker" "$bin/stat"

compose_count="$TMP/counts/compose"
inspect_count="$TMP/counts/inspect"
inspect_args="$TMP/counts/inspect-args"
forbidden="$TMP/counts/forbidden"
stat_counts="$TMP/counts/stat"
mkdir -p "$stat_counts"
: > "$compose_count"
: > "$inspect_count"
: > "$inspect_args"
: > "$forbidden"

export DASHBOARD_COMPOSE_COUNT_FILE="$compose_count"
export DASHBOARD_INSPECT_COUNT_FILE="$inspect_count"
export DASHBOARD_INSPECT_ARGS_FILE="$inspect_args"
export DASHBOARD_FORBIDDEN_FILE="$forbidden"
export DASHBOARD_STAT_COUNT_DIR="$stat_counts"
export PATH="$bin:$PATH"

# shellcheck source=/dev/null
source "$fixture/dashboard.sh"

printf '0\n' > "$compose_count"
printf '0\n' > "$inspect_count"
: > "$inspect_args"
DASHBOARD_DOCKER_SCENARIO=normal
export DASHBOARD_DOCKER_SCENARIO
_capture_dashboard_process_snapshot || fail 'normal dashboard snapshot failed'
[[ "$(<"$compose_count")" == 1 ]] || fail 'dashboard did not issue exactly one Compose query'
[[ "$(<"$inspect_count")" == 1 ]] || fail 'dashboard did not issue one batched inspect'
grep -Fq 'vaultwarden_app' "$inspect_args" || fail 'batched inspect omitted Vaultwarden'
grep -Fq 'vaultwarden_caddy' "$inspect_args" || fail 'batched inspect omitted canonical Caddy'
if grep -Fq 'vaultwarden-oci-caddy-run-deadbeef' "$inspect_args"; then
    fail 'batched inspect included a Compose one-off container'
fi
[[ "${DASHBOARD_SERVICE_CONTAINER[caddy]}" == vaultwarden_caddy ]] \
    || fail 'one-off Caddy row replaced the canonical container'
[[ "$(_container_status_plain vaultwarden)" == Running ]] || fail 'healthy Vaultwarden was not Running'
[[ "$(_container_status_plain caddy)" == Starting ]] || fail 'starting canonical Caddy health was not preserved'
[[ "$(_container_status_plain postfix)" == Missing ]] || fail 'missing Postfix was not truthful'
[[ "$(_container_uptime vaultwarden)" != unknown ]] || fail 'Vaultwarden uptime did not reuse batch inspection'
[[ "$(_container_uptime caddy)" != unknown ]] || fail 'Caddy uptime did not reuse batch inspection'
[[ ! -s "$forbidden" ]] || fail 'dashboard used per-container docker ps'

printf '0\n' > "$compose_count"
printf '0\n' > "$inspect_count"
: > "$inspect_args"
DASHBOARD_DOCKER_SCENARIO=unknown
export DASHBOARD_DOCKER_SCENARIO
_capture_dashboard_process_snapshot || fail 'unknown-state dashboard snapshot failed'
[[ "$(<"$compose_count")" == 1 ]] || fail 'unknown-state redraw repeated Compose queries'
[[ "$(<"$inspect_count")" == 1 ]] || fail 'unknown-state redraw did not batch running-container inspect'
[[ "$(_container_status_plain vaultwarden)" == 'Running (health unknown)' ]] \
    || fail 'unknown health was reported as healthy'
[[ "$(_container_status_plain caddy)" == 'Unknown (mystery)' ]] \
    || fail 'unknown Docker state was reported as stopped or healthy'
[[ "$(_container_status_plain postfix)" == Stopped ]] || fail 'stopped Postfix was not preserved'

printf '0\n' > "$compose_count"
printf '0\n' > "$inspect_count"
DASHBOARD_DOCKER_SCENARIO=error
export DASHBOARD_DOCKER_SCENARIO
if _capture_dashboard_process_snapshot; then
    fail 'Compose query error unexpectedly succeeded'
fi
[[ "$(<"$compose_count")" == 1 ]] || fail 'error redraw repeated Compose queries'
[[ "$(<"$inspect_count")" == 0 ]] || fail 'error redraw inspected containers'
[[ "$(_container_status_plain vaultwarden)" == Unknown ]] \
    || fail 'Compose error was reported as stopped or healthy'

touch "$TMP/backups/older.age" "$TMP/backups/middle.age" "$TMP/backups/newest.age"
BACKUP_DIR="$TMP/backups"
_capture_newest_backup
[[ "$NEWEST_BACKUP_PATH" == "$TMP/backups/newest.age" ]] || fail 'newest backup path was incorrect'
[[ "$NEWEST_BACKUP_MTIME" == 300 ]] || fail 'newest backup timestamp was incorrect'
for name in older.age middle.age newest.age; do
    [[ "$(<"$stat_counts/$name")" == 1 ]] || fail "backup candidate $name was statted more than once"
done
newest_output="$(_epoch_to_pt "$NEWEST_BACKUP_MTIME") ($(basename "$NEWEST_BACKUP_PATH"))"
[[ "$newest_output" == *'(newest.age)' ]] || fail 'newest backup output was incorrect'

grep -Fq 'read -r -t 60' "$ROOT/dashboard.sh" || fail 'dashboard refresh interval changed'
grep -Fq 'make -C "${REPO_ROOT}" restart' "$ROOT/dashboard.sh" || fail 'restart menu action changed'
grep -Fq 'make -C "${REPO_ROOT}" down' "$ROOT/dashboard.sh" || fail 'stop menu action changed'
grep -Fq 'make -C "${REPO_ROOT}" health-quick' "$ROOT/dashboard.sh" || fail 'health menu action changed'
grep -Fq 'make -C "${REPO_ROOT}" diagnose' "$ROOT/dashboard.sh" || fail 'diagnose menu action changed'

printf 'Dashboard process snapshot tests passed.\n'
)

check_dashboard_process_snapshot_behavior
check_operator_cli_argument_contracts() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

CLI_STATUS=0
CLI_OUTPUT=""

run_cli() {
    local script="$1"
    shift
    set +e
    CLI_OUTPUT="$(
        PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH" \
        HOME="$TMP/home" \
        DOCKER_PROJECT_LABEL=ci \
        bash "$ROOT/$script" "$@" 2>&1
    )"
    CLI_STATUS=$?
    set -e
}

expect_success_contains() {
    local script="$1" expected="$2"
    shift 2
    run_cli "$script" "$@"
    [[ "$CLI_STATUS" -eq 0 ]] || fail "$script $* exited $CLI_STATUS; output: $CLI_OUTPUT"
    [[ "$CLI_OUTPUT" == *"$expected"* ]] || fail "$script $* output missing '$expected': $CLI_OUTPUT"
}

expect_failure_contains() {
    local script="$1" expected="$2"
    shift 2
    run_cli "$script" "$@"
    [[ "$CLI_STATUS" -ne 0 ]] || fail "$script $* unexpectedly succeeded"
    [[ "$CLI_OUTPUT" == *"$expected"* ]] || fail "$script $* output missing '$expected': $CLI_OUTPUT"
}

expect_failure_contains utilities/setup-systemd.sh \
    "Exactly one action is required: install | remove | validate | status" \
    install status
expect_failure_contains restore.sh "Unknown option for 'list': --force" list --force
expect_failure_contains restore.sh "Unknown option for 'list': --no-backup" list --no-backup
expect_failure_contains restore.sh "Unknown option for 'list': --start-policy" list --start-policy manual
expect_failure_contains restore.sh "Unknown option for 'list': --no-rotate-age-key" list --no-rotate-age-key
expect_failure_contains startup.sh "Unknown option for 'stop': '--background'" stop --background
expect_failure_contains startup.sh "Unknown option for 'stop': '--skip-health'" stop --skip-health
expect_failure_contains startup.sh "Unknown option for 'stop': '--skip-pull'" stop --skip-pull
expect_failure_contains startup.sh "Unknown option for 'stop': '--force'" stop --force
expect_failure_contains startup.sh "Unknown option for 'stop': '--skip-egress-fix'" stop --skip-egress-fix
expect_failure_contains utilities/env-edit.sh "Unknown argument for 'sync': --bogus" sync --bogus
expect_failure_contains utilities/env-edit.sh "Unknown argument for 'edit': unexpected" edit unexpected
expect_failure_contains utilities/env-edit.sh "Unknown argument for 'status': --force" status --force
expect_failure_contains dashboard.sh "Unknown argument: --bogus" --bogus
expect_failure_contains dashboard.sh "Unknown argument: foo" foo
expect_success_contains utilities/operations-status.sh "VaultWarden-OCI Operation Status" --help
expect_success_contains utilities/operations-status.sh "VaultWarden-OCI " --version
expect_failure_contains utilities/operations-status.sh "Unknown argument: --bogus" --bogus
expect_success_contains backup.sh "VERIFY OPTIONS:" verify --help
expect_success_contains backup.sh "--type TYPE" verify --help
expect_success_contains backup.sh "--quiet" verify --help
expect_success_contains backup.sh "VaultWarden-OCI " verify --version
expect_success_contains restore.sh "VaultWarden-OCI " list --version
expect_success_contains startup.sh "VaultWarden-OCI " stop --version
expect_success_contains utilities/setup-systemd.sh "VaultWarden-OCI systemd Timer Installer" install --help
expect_success_contains utilities/env-edit.sh "VaultWarden-OCI Environment Management" status --help

expected_version="VaultWarden-OCI $(tr -d '[:space:]' < "$ROOT/VERSION")"
run_cli setup.sh install --version
[[ "$CLI_STATUS" -eq 0 && "$CLI_OUTPUT" == "$expected_version" ]] \
    || fail "setup.sh install --version did not print normal version output: $CLI_OUTPUT"
run_cli setup.sh install -V
[[ "$CLI_STATUS" -eq 0 && "$CLI_OUTPUT" == "$expected_version" ]] \
    || fail "setup.sh install -V did not print normal version output: $CLI_OUTPUT"

expect_failure_contains backup.sh "--keep requires a value" run --keep
expect_failure_contains backup.sh "--type requires a value" verify --type
expect_failure_contains restore.sh "--start-policy requires a value" interactive --start-policy
expect_failure_contains restore.sh "--file requires a value" interactive --file --force
expect_failure_contains utilities/secrets-view.sh "--editor requires an argument" --editor --help
expect_failure_contains utilities/setup-env.sh "--domain requires an argument" --domain --email admin@example.test
expect_failure_contains utilities/setup-system.sh "--data-device requires an argument" --data-device --force
expect_failure_contains utilities/setup-storage.sh "--data-device requires a value" setup --data-device --force
expect_failure_contains utilities/key-rotate.sh "--extra-recipient requires an Age public key" --extra-recipient --dry-run
expect_failure_contains utilities/maintenance-email.sh "--recipient requires an argument" --recipient --dry-run
expect_failure_contains utilities/maintenance-email.sh "--transport requires an argument" --transport --dry-run
expect_failure_contains utilities/maintenance-email.sh "Valid values: configured api sidecar direct all" --transport invalid --dry-run
expect_failure_contains recover.sh "Option --state-dir requires a value" --state-dir --key "$TMP/key.txt"

grep -Fq '### recover.sh' "$ROOT/docs/COMMAND-REFERENCE.md" \
    || fail 'COMMAND-REFERENCE must include recover.sh'
grep -Fq '### secrets-edit.sh' "$ROOT/docs/COMMAND-REFERENCE.md" \
    || fail 'COMMAND-REFERENCE must include public secrets-edit.sh utility'
! grep -Fq '### notify-failure.sh' "$ROOT/docs/COMMAND-REFERENCE.md" \
    || fail 'COMMAND-REFERENCE must not expose internal notify-failure.sh utility'
grep -Fq 'sudo ./setup.sh systemd install' "$ROOT/docs/COMMAND-REFERENCE.md" \
    || fail 'COMMAND-REFERENCE must include setup.sh systemd install example'
grep -Fq 'sudo ./setup.sh systemd validate' "$ROOT/docs/COMMAND-REFERENCE.md" \
    || fail 'COMMAND-REFERENCE must include setup.sh systemd validate example'

printf 'Operator CLI argument contract tests passed.\n'
)

check_operator_cli_argument_contracts
check_confirmation_prompt_format() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
MAINT_DB="$ROOT/utilities/maintenance-db-maint.sh"
TMP_PROMPT_PROSE=""
TMP_PROMPT_RUNTIME=""
cleanup_prompt_fixtures() {
    [[ -n "$TMP_PROMPT_PROSE" ]] && rm -f "$TMP_PROMPT_PROSE"
    [[ -n "$TMP_PROMPT_RUNTIME" ]] && rm -f "$TMP_PROMPT_RUNTIME"
    return 0
}
trap cleanup_prompt_fixtures EXIT

patterns=(
    "y""/N"
    "Y""/n"
    "[y""/n]"
    "[Y""/N]"
    "[Y""/n]"
    "[y""/N]"
)

confirmation_prompt_scan_targets() {
    find "$ROOT" -maxdepth 1 -type f -name "*.sh" -print
    find "$ROOT/utilities" -maxdepth 1 -type f -name "*.sh" -print
    find "$ROOT/lib" -maxdepth 1 -type f -name "*.sh" -print
}

scan_prompt_pattern() {
    local pattern="$1"
    local targets=()
    while IFS= read -r target; do
        targets+=("$target")
    done < <(confirmation_prompt_scan_targets)
    ((${#targets[@]} > 0)) || return 1
    grep -nF -I -- "$pattern" "${targets[@]}"
}

TMP_PROMPT_PROSE="$(mktemp "${TMPDIR:-/tmp}/operator-ui-prose.XXXXXX.md")"
printf 'Historical prose may mention Continue? [y/N] without being a runtime prompt.\n' > "$TMP_PROMPT_PROSE"
if scan_prompt_pattern "[y""/N]" | grep -Fq "$(basename "$TMP_PROMPT_PROSE")"; then
    echo "FAIL: prompt scan must not inspect reports prose" >&2
    exit 1
fi

TMP_PROMPT_RUNTIME="$(mktemp "$ROOT/utilities/operator-ui-runtime.XXXXXX.sh")"
printf 'read -r -p "Continue? [y/N] " answer\n' > "$TMP_PROMPT_RUNTIME"
if ! scan_prompt_pattern "[y""/N]" | grep -Fq "$(basename "$TMP_PROMPT_RUNTIME")"; then
    echo "FAIL: prompt scan must reject shorthand prompts in runtime shell surfaces" >&2
    exit 1
fi
rm -f "$TMP_PROMPT_RUNTIME"
TMP_PROMPT_RUNTIME=""

for pattern in "${patterns[@]}"; do
    set +e
    matches="$(scan_prompt_pattern "$pattern")"
    status=$?
    set -e
    if [[ $status -eq 0 ]]; then
        printf '%s\n' "$matches"
        echo "FAIL: active content contains shorthand confirmation prompt: $pattern" >&2
        exit 1
    fi
    if [[ $status -ne 1 ]]; then
        echo "FAIL: prompt shorthand scan failed for pattern: $pattern" >&2
        exit "$status"
    fi
done

grep -Fq 'Continue with deep database maintenance? [yes/no] (default: no): ' "$MAINT_DB" \
    || { echo "FAIL: deep maintenance prompt must disclose default: no" >&2; exit 1; }

if grep -Fq 'confirm="yes"' "$MAINT_DB"; then
    echo "FAIL: deep maintenance confirmation timeout must not default to yes" >&2
    exit 1
fi

grep -Fq 'Deep maintenance cancelled because confirmation was not received.' "$MAINT_DB" \
    || { echo "FAIL: deep maintenance timeout cancellation message missing" >&2; exit 1; }

echo "OK: confirmation prompts use full yes/no display text"

)

check_confirmation_prompt_format
check_restore_plan_summary_operator_ui() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
fail(){ echo "FAIL: $*" >&2; exit 1; }

_extract_func(){
  local file="$1" func="$2"
  awk -v f="$func" '
    $0 ~ "^" f "\\(\\)" {p=1}
    p {
      print
      opens=gsub(/\{/,"{"); closes=gsub(/\}/,"}")
      depth += opens - closes
      if (depth == 0) exit
    }' "$file"
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Operator UI closure: restore plan summary must not use fixed-width box borders or padded printf columns.
restore_plan_func="$(_extract_func "$ROOT/utilities/restore-run.sh" _print_restore_plan_summary)"
! grep -q '╔\|╠\|╚\|║' <<< "$restore_plan_func" || fail 'restore plan summary still uses fixed-width box drawing'
! grep -q '%-38s' <<< "$restore_plan_func" || fail 'restore plan summary still pads values to a fixed width'
grep -q 'operator_attention warn "Restore plan summary"' <<< "$restore_plan_func" || fail 'restore plan summary does not use operator attention block'

# Behavior: long backup names/paths are printed untruncated in plain summary lines.
cat > "$TMP/restore-plan-probe.sh" <<EOF_PROBE
set -euo pipefail
ROOT="$ROOT"
TMP="$TMP"
source "\$ROOT/lib/log.sh"
source "\$ROOT/lib/common.sh"
init_common_lib restore-plan-probe
RESTORE_TYPE=full
STATE_DIR="\$TMP/state-with-a-deliberately-long-path-component-that-must-not-be-truncated"
OPERATIONAL_SOPS_AGE_KEY_FILE="\$TMP/keys/live-operational-age-key-with-a-deliberately-long-name.txt"
NO_PRE_BACKUP=false
backup_encryption_mode=age-recipient
BACKUP_FILE="\$TMP/vaultwarden-full-backup-with-a-deliberately-long-name-that-would-overflow-the-old-box.tar.zst.age"
touch "\$BACKUP_FILE"
$restore_plan_func
_print_restore_plan_summary >"\$TMP/restore-plan.out" 2>&1
EOF_PROBE
bash "$TMP/restore-plan-probe.sh" || fail 'restore plan summary probe failed'
grep -q 'vaultwarden-full-backup-with-a-deliberately-long-name-that-would-overflow-the-old-box.tar.zst.age' "$TMP/restore-plan.out" || fail 'restore plan summary truncated or hid long backup name'
grep -q 'live-operational-age-key-with-a-deliberately-long-name.txt' "$TMP/restore-plan.out" || fail 'restore plan summary truncated or hid long key path'
! grep -q '╔\|╠\|╚\|║' "$TMP/restore-plan.out" || fail 'restore plan output still contains fixed-width box borders'

)

check_restore_plan_summary_operator_ui
check_maintenance_contention_operator_ui() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

log_info(){ :; }
source "$ROOT/lib/maintenance-utils.sh"

CLEAN_LOGS=false
CLEAN_BACKUPS=false
CLEAN_DOCKER=false
OPTIMIZE_DATABASE=false
TARGETED_MODE=true
UPDATE_FIREWALL=true
UPDATE_DNS=true
EMAIL_NOTIFY=true
subject_file="$TMP/summary-subject"
send_notification_email(){ printf '%s\n' "$1" > "$subject_file"; }

summary="$(generate_maintenance_summary 0 0 0 0 75 75 0)"
[[ "$summary" == *'Firewall update: Skipped (active operation)'* ]] \
    || fail "firewall contention was not rendered as skipped"
[[ "$summary" == *'DNS update: Skipped (active operation)'* ]] \
    || fail "DNS contention was not rendered as skipped"
[[ "$summary" != *'Firewall update: OK'* && "$summary" != *'Firewall update: Failed'* ]] \
    || fail "firewall contention was rendered as success or failure"
[[ "$summary" != *'DNS update: OK'* && "$summary" != *'DNS update: Failed'* ]] \
    || fail "DNS contention was rendered as success or failure"
[[ "$summary" == *'Overall Status: COMPLETED WITH SKIPS'* ]] \
    || fail "contention summary claimed full success"
[[ "$(<"$subject_file")" == 'VaultWarden Maintenance: COMPLETED WITH SKIPS' ]] \
    || fail "contention email summary claimed success"

summary="$(generate_maintenance_summary 0 0 0 0 42 0 0)"
[[ "$summary" == *'Firewall update: Failed'* && "$summary" == *'Overall Status: COMPLETED WITH ISSUES'* ]] \
    || fail "real firewall failure was not preserved in the summary"
[[ "$(<"$subject_file")" == 'VaultWarden Maintenance: ISSUES DETECTED' ]] \
    || fail "real firewall failure was misclassified in the email summary"

extract_func() {
    local file="$1" func="$2"
    awk -v f="$func" '
        $0 ~ "^" f "\\(\\)" {p=1}
        p {
            print
            opens=gsub(/\{/, "{")
            closes=gsub(/\}/, "}")
            depth += opens - closes
            if (depth == 0) exit
        }
    ' "$file"
}

stub_root="$TMP/stub-root"
mkdir -p "$stub_root/utilities"
cat > "$stub_root/utilities/maintenance-update-firewall.sh" <<'EOF_LEAF'
#!/usr/bin/env bash
exit "${FIREWALL_TEST_RC:-75}"
EOF_LEAF
cat > "$stub_root/utilities/maintenance-update-dns.sh" <<'EOF_LEAF'
#!/usr/bin/env bash
exit "${DNS_TEST_RC:-75}"
EOF_LEAF
chmod 700 "$stub_root/utilities/maintenance-update-firewall.sh" "$stub_root/utilities/maintenance-update-dns.sh"

main_probe="$TMP/maintenance-main-probe.sh"
cat > "$main_probe" <<EOF_PROBE
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$stub_root"
PROJECT_ROOT="$stub_root"
CLEAN_LOGS=false
CLEAN_BACKUPS=false
CLEAN_DOCKER=false
OPTIMIZE_DATABASE=false
UPDATE_FIREWALL=true
UPDATE_DNS=true
DRY_RUN=false
EMAIL_NOTIFY=false
COMPREHENSIVE=false
TARGETED_MODE=true
source "$ROOT/lib/maintenance-utils.sh"
require_root(){ :; }
operation_acquire(){ :; }
operation_release(){ :; }
operation_set_phase(){ :; }
perform_cleanup(){ :; }
load_project_environment(){ :; }
auto_fix_critical_permissions(){ :; }
require_project_state_ready(){ :; }
cleanup_logs(){ :; }
cleanup_backups(){ :; }
cleanup_expired_recovery_kits(){ :; }
cleanup_docker_system(){ :; }
optimize_database(){ :; }
validate_system_health(){ :; }
log_header(){ :; }
log_info(){ printf '%s\n' "\$*"; }
log_success(){ printf '%s\n' "\$*"; }
log_warn(){ printf '%s\n' "\$*" >&2; }
log_error(){ printf '%s\n' "\$*" >&2; }
$(extract_func "$ROOT/utilities/maintenance-run.sh" main)
main
EOF_PROBE
chmod 700 "$main_probe"

set +e
FIREWALL_TEST_RC=75 DNS_TEST_RC=75 "$BASH" "$main_probe" > "$TMP/clean-with-skips.out" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "clean aggregate contention run must exit 0, got $rc"
grep -Fq 'Overall Status: COMPLETED WITH SKIPS' "$TMP/clean-with-skips.out" \
    || fail "aggregate clean-with-skips output was not truthful"
grep -Fq 'Maintenance completed with skipped work' "$TMP/clean-with-skips.out" \
    || fail "aggregate completion message did not disclose skipped work"

set +e
FIREWALL_TEST_RC=42 DNS_TEST_RC=0 "$BASH" "$main_probe" > "$TMP/real-failure.out" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "real aggregate firewall failure must remain non-zero"
grep -Fq 'Firewall update: Failed' "$TMP/real-failure.out" \
    || fail "aggregate output did not retain real firewall failure"

printf 'PASS: maintenance contention status is truthful in operator output\n'

)

check_maintenance_contention_operator_ui

check_dashboard_configuration_behavior() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d -t vw-dashboard-config.XXXXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }

fixture="$TMP/repo"
installed="$TMP/installed.env"
state="$TMP/installed-state"
mkdir -p "$fixture" "$state/secrets"
cp "$ROOT/dashboard.sh" "$ROOT/VERSION" "$fixture/"
ln -s "$ROOT/lib" "$fixture/lib"
sed -i 's/^main "$@"$/: # fixture: do not auto-run dashboard/' "$fixture/dashboard.sh"
cat > "$fixture/.env" <<EOF_REPO
PROJECT_STATE_DIR=$TMP/repo-state
BACKUP_DIR=$TMP/repo-backups
TZ=UTC
RCLONE_REMOTE_NAME=repo-remote
EOF_REPO
cat > "$installed" <<EOF_INSTALLED
PROJECT_STATE_DIR=$state
BACKUP_DIR=$TMP/installed-backups
TZ=America/Vancouver
RCLONE_REMOTE_NAME=installed-remote
EOF_INSTALLED
chmod 0600 "$fixture/.env" "$installed"
printf 'encrypted fixture\n' > "$state/secrets/secrets.yaml"

output=$(env -u TZ -u RCLONE_REMOTE_NAME \
    VW_CONFIG_INSTALLED_ENV_FILE="$installed" DASHBOARD="$fixture/dashboard.sh" bash <<'PROBE'
set -euo pipefail
source "$DASHBOARD"
_load_dashboard_config
printf 'STATE=%s\nBACKUP=%s\nTZ=%s\nREMOTE=%s\nSECRETS=%s\n' \
    "$STATE_DIR" "$BACKUP_DIR" "$TZ_DISPLAY" "$RCLONE_REMOTE_NAME" "$SECRETS_FILE"
PROBE
) || fail 'dashboard canonical configuration load failed'

[[ "$output" == *"STATE=$state"* ]] || fail "dashboard selected repository state: $output"
[[ "$output" == *"BACKUP=$TMP/installed-backups"* ]] || fail "dashboard selected repository backup path: $output"
[[ "$output" == *'TZ=America/Vancouver'* ]] || fail "dashboard selected repository timezone: $output"
[[ "$output" == *'REMOTE=installed-remote'* ]] || fail "dashboard selected repository rclone remote: $output"
[[ "$output" == *"SECRETS=$state/secrets/secrets.yaml"* ]] || fail "dashboard selected the wrong secrets path: $output"
pass 'dashboard uses canonical installed configuration'

missing_repo="$TMP/missing-repo"
mkdir -p "$missing_repo"
cp "$ROOT/dashboard.sh" "$ROOT/VERSION" "$missing_repo/"
ln -s "$ROOT/lib" "$missing_repo/lib"
sed -i 's/^main "$@"$/: # fixture: do not auto-run dashboard/' "$missing_repo/dashboard.sh"
if env -u TZ -u RCLONE_REMOTE_NAME \
    VW_CONFIG_INSTALLED_ENV_FILE="$TMP/does-not-exist.env" DASHBOARD="$missing_repo/dashboard.sh" bash <<'PROBE'
set -euo pipefail
source "$DASHBOARD"
_load_dashboard_config
PROBE
then
    fail 'dashboard succeeded without a canonical environment'
fi
pass 'dashboard fails when canonical configuration cannot be loaded'
)

check_dashboard_configuration_behavior
