#!/usr/bin/env bash
# Behavioral regressions for Cloudflare UFW reconciliation and its systemd sandbox.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

ROOT="$VW_TEST_REPO_ROOT"
UPDATER="$ROOT/utilities/maintenance-update-firewall.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_file_contains() {
    local file="$1" expected="$2"
    grep -Fq -- "$expected" "$file" || fail "$(basename "$file") lacks: $expected"
}

assert_no_call() {
    local expected="$1"
    ! grep -Fq -- "$expected" "$UFW_CALL_LOG" || fail "unexpected UFW call: $expected"
}

assert_call() {
    local expected="$1"
    grep -Fq -- "$expected" "$UFW_CALL_LOG" || fail "missing UFW call: $expected"
}

extract_func() {
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

mkdir -p "$TMP/bin"

cat > "$TMP/bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -euo pipefail
out=""
url=""
while (( $# > 0 )); do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
[[ -n "$out" && -n "$url" ]] || exit 2
case "$url" in
    *ips-v4) cat "${CF_IPV4_FILE:?}" > "$out" ;;
    *ips-v6) cat "${CF_IPV6_FILE:?}" > "$out" ;;
    *) exit 2 ;;
esac
EOF_CURL

cat > "$TMP/bin/ufw" <<'EOF_UFW'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${UFW_CALL_LOG:?}"

if [[ "${1:-}" == "status" && "${2:-}" == "numbered" ]]; then
    if (( ${UFW_NUMBERED_RC:-0} != 0 )); then
        printf '%s\n' "${UFW_NUMBERED_OUTPUT:-numbered status failed}" >&2
        exit "$UFW_NUMBERED_RC"
    fi
    cat "${UFW_NUMBERED_FILE:?}"
    exit 0
fi

if [[ "${1:-}" == "status" && $# -eq 1 ]]; then
    if (( ${UFW_STATUS_RC:-0} != 0 )); then
        printf '%s\n' "${UFW_STATUS_OUTPUT:-status failed}" >&2
        exit "$UFW_STATUS_RC"
    fi
    cat "${UFW_STATUS_FILE:?}"
    exit 0
fi

command_line=" $* "
if [[ "$command_line" == *" allow "* && "$command_line" == *" port 80 "* ]]; then
    if (( ${UFW_ALLOW80_RC:-0} != 0 )); then
        printf '%s\n' "${UFW_ALLOW80_OUTPUT:-port 80 failed}" >&2
        exit "$UFW_ALLOW80_RC"
    fi
    printf 'Rule added\n'
    exit 0
fi

if [[ "$command_line" == *" allow "* && "$command_line" == *" port 443 "* ]]; then
    if (( ${UFW_ALLOW443_RC:-0} != 0 )); then
        printf '%s\n' "${UFW_ALLOW443_OUTPUT:-port 443 failed}" >&2
        exit "$UFW_ALLOW443_RC"
    fi
    printf 'Rule added\n'
    exit 0
fi

if [[ "${1:-}" == "--force" && "${2:-}" == "delete" ]]; then
    rule="${3:-}"
    if [[ -n "${UFW_DELETE_FAIL_RULE:-}" && "$rule" == "$UFW_DELETE_FAIL_RULE" ]]; then
        printf '%s\n' "${UFW_DELETE_OUTPUT:-delete failed}" >&2
        exit "${UFW_DELETE_RC:-1}"
    fi
    printf 'Rule deleted\n'
    exit 0
fi

printf 'unexpected ufw invocation: %s\n' "$*" >&2
exit 2
EOF_UFW
chmod 0755 "$TMP/bin/curl" "$TMP/bin/ufw"

PROBE="$TMP/firewall-probe.bash"
cat > "$PROBE" <<'EOF_PROBE'
#!/usr/bin/env bash
set -euo pipefail
UPDATE_FIREWALL=true
DRY_RUN=false
CLOUDFLARE_PROXY_ENABLED=true
require_root(){ :; }
register_cleanup(){ :; }
retry_with_backoff(){ shift 2; "$@"; }
log_info(){ printf 'INFO: %s\n' "$*" >> "${LOG_FILE:?}"; }
log_warn(){ printf 'WARN: %s\n' "$*" >> "${LOG_FILE:?}"; }
log_error(){ printf 'ERROR: %s\n' "$*" >> "${LOG_FILE:?}"; }
log_success(){ printf 'SUCCESS: %s\n' "$*" >> "${LOG_FILE:?}"; }
log_debug(){ printf 'DEBUG: %s\n' "$*" >> "${LOG_FILE:?}"; }
EOF_PROBE
extract_func "$UPDATER" update_firewall_ranges >> "$PROBE"
cat >> "$PROBE" <<'EOF_PROBE'
set +e
update_firewall_ranges
rc=$?
set -e
exit "$rc"
EOF_PROBE
chmod 0755 "$PROBE"

reset_case() {
    local name="$1"
    CASE_DIR="$TMP/$name"
    mkdir -p "$CASE_DIR/tmp" "$CASE_DIR/state"
    CF_IPV4_FILE="$CASE_DIR/ips-v4"
    CF_IPV6_FILE="$CASE_DIR/ips-v6"
    UFW_STATUS_FILE="$CASE_DIR/status"
    UFW_NUMBERED_FILE="$CASE_DIR/status-numbered"
    UFW_CALL_LOG="$CASE_DIR/ufw-calls"
    LOG_FILE="$CASE_DIR/log"
    CASE_OUTPUT="$CASE_DIR/output"

    printf '203.0.113.0/24\n' > "$CF_IPV4_FILE"
    : > "$CF_IPV6_FILE"
    : > "$UFW_STATUS_FILE"
    : > "$UFW_NUMBERED_FILE"
    : > "$UFW_CALL_LOG"
    : > "$LOG_FILE"

    unset UFW_STATUS_RC UFW_STATUS_OUTPUT UFW_NUMBERED_RC UFW_NUMBERED_OUTPUT
    unset UFW_ALLOW80_RC UFW_ALLOW80_OUTPUT UFW_ALLOW443_RC UFW_ALLOW443_OUTPUT
    unset UFW_DELETE_FAIL_RULE UFW_DELETE_RC UFW_DELETE_OUTPUT

    export CASE_DIR CF_IPV4_FILE CF_IPV6_FILE UFW_STATUS_FILE UFW_NUMBERED_FILE
    export UFW_CALL_LOG LOG_FILE
}

run_case() {
    set +e
    PATH="$TMP/bin:$PATH" \
    TMPDIR="$CASE_DIR/tmp" \
    PROJECT_STATE_DIR="$CASE_DIR/state" \
    "$BASH" "$PROBE" > "$CASE_OUTPUT" 2>&1
    CASE_RC=$?
    set -e
}

write_ipv4_status() {
    local has_80="$1" has_443="$2"
    : > "$UFW_STATUS_FILE"
    if [[ "$has_80" == true ]]; then
        printf '80/tcp ALLOW IN 203.0.113.0/24\n' >> "$UFW_STATUS_FILE"
    fi
    if [[ "$has_443" == true ]]; then
        printf '443/tcp ALLOW IN 203.0.113.0/24\n' >> "$UFW_STATUS_FILE"
    fi
}

reset_case status-failure
export UFW_STATUS_RC=41 UFW_STATUS_OUTPUT='cannot open /run/ufw.lock: read-only file system'
run_case
[[ "$CASE_RC" -eq 41 ]] || fail "ufw status failure returned $CASE_RC instead of 41"
assert_file_contains "$LOG_FILE" 'cannot open /run/ufw.lock: read-only file system'

reset_case only-port-80
write_ipv4_status true false
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "port 80-only convergence failed with $CASE_RC"
assert_no_call 'port 80 comment'
assert_call 'port 443 comment CF-IPv4'

reset_case only-port-443
write_ipv4_status false true
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "port 443-only convergence failed with $CASE_RC"
assert_call 'port 80 comment CF-IPv4'
assert_no_call 'port 443 comment'

reset_case both-ports
write_ipv4_status true true
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "existing port rules failed with $CASE_RC"
assert_no_call ' allow '

reset_case port-80-failure
export UFW_ALLOW80_RC=42 UFW_ALLOW80_OUTPUT='simulated port 80 failure'
run_case
[[ "$CASE_RC" -eq 42 ]] || fail "port 80 failure returned $CASE_RC instead of 42"
assert_file_contains "$LOG_FILE" 'simulated port 80 failure'
assert_no_call 'port 443 comment'

reset_case port-443-failure
write_ipv4_status true false
export UFW_ALLOW443_RC=43 UFW_ALLOW443_OUTPUT='simulated port 443 failure'
run_case
[[ "$CASE_RC" -eq 43 ]] || fail "port 443 failure returned $CASE_RC instead of 43"
assert_file_contains "$LOG_FILE" 'simulated port 443 failure'

reset_case numbered-status-failure
write_ipv4_status true true
export UFW_NUMBERED_RC=44 UFW_NUMBERED_OUTPUT='cannot enumerate UFW rules'
run_case
[[ "$CASE_RC" -eq 44 ]] || fail "numbered status failure returned $CASE_RC instead of 44"
assert_file_contains "$LOG_FILE" 'cannot enumerate UFW rules'

reset_case delete-failure
write_ipv4_status true true
printf '[12] 80/tcp ALLOW IN 198.51.100.0/24 # CF-IPv4\n' > "$UFW_NUMBERED_FILE"
export UFW_DELETE_FAIL_RULE=12 UFW_DELETE_RC=45 UFW_DELETE_OUTPUT='simulated delete failure'
run_case
[[ "$CASE_RC" -eq 45 ]] || fail "delete failure returned $CASE_RC instead of 45"
assert_file_contains "$LOG_FILE" 'Failed to delete UFW rule 12'
assert_file_contains "$LOG_FILE" 'simulated delete failure'

reset_case descending-delete
write_ipv4_status true true
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 2] 80/tcp ALLOW IN 198.51.100.2/32 # CF-IPv4
[10] 80/tcp ALLOW IN 198.51.100.10/32 # CF-IPv4
[ 7] 80/tcp ALLOW IN 198.51.100.7/32 # CF-IPv4
EOF_RULES
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "descending deletion failed with $CASE_RC"
delete_order="$(grep '^--force delete ' "$UFW_CALL_LOG" || true)"
expected_order=$'--force delete 10\n--force delete 7\n--force delete 2'
[[ "$delete_order" == "$expected_order" ]] || fail "obsolete rules deleted in wrong order: $delete_order"

reset_case partial-retry
write_ipv4_status true false
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "first partial convergence failed with $CASE_RC"
write_ipv4_status true true
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "partial convergence retry failed with $CASE_RC"
[[ "$(grep -Fc 'port 443 comment CF-IPv4' "$UFW_CALL_LOG")" -eq 1 ]] \
    || fail "partial retry did not add port 443 exactly once"
assert_no_call 'port 80 comment'

reset_case ipv6-existing
: > "$CF_IPV4_FILE"
printf '2001:db8::/32\n' > "$CF_IPV6_FILE"
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
80/tcp (v6) ALLOW IN 2001:db8::/32
443/tcp (v6) ALLOW IN 2001:db8::/32
EOF_STATUS
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "existing IPv6 rules failed with $CASE_RC"
assert_no_call ' allow '

health_unit="$ROOT/systemd/vaultwarden-health.service"
maintenance_unit="$ROOT/systemd/vaultwarden-maintenance.service"
firewall_unit="$ROOT/systemd/vaultwarden-firewall-update.service"
dns_timer="$ROOT/systemd/vaultwarden-dns-update.timer"
firewall_timer="$ROOT/systemd/vaultwarden-firewall-update.timer"

for unit in "$health_unit" "$maintenance_unit" "$firewall_unit"; do
    assert_file_contains "$unit" 'ProtectSystem=strict'
    assert_file_contains "$unit" 'NoNewPrivileges=yes'
    assert_file_contains "$unit" 'PrivateTmp=yes'
    while IFS= read -r directive; do
        read -ra paths <<< "${directive#ReadWritePaths=}"
        for path in "${paths[@]}"; do
            path="${path#-}"
            case "$path" in
                /run|/etc|/var) fail "$(basename "$unit") grants broad write access to $path" ;;
            esac
        done
    done < <(grep '^ReadWritePaths=' "$unit")
done

! grep -Fq '/var/lib/crowdsec' "$health_unit" \
    || fail "vaultwarden-health.service grants stale CrowdSec write access"
! grep -Fq '/var/lib/crowdsec' "$maintenance_unit" \
    || fail "routine maintenance grants unused CrowdSec write access"
! grep -Eq '^ReadWritePaths=.*(/etc/ufw|/run/ufw\.lock|/run/xtables\.lock)' "$maintenance_unit" \
    || fail "routine maintenance grants firewall-only write access"
! grep -Fq 'ExecStartPre=+/usr/bin/touch /run/ufw.lock /run/xtables.lock' "$maintenance_unit" \
    || fail "routine maintenance prepares firewall-only locks"
! grep -Fq 'ExecStartPre=+/usr/bin/chown root:root /run/ufw.lock /run/xtables.lock' "$maintenance_unit" \
    || fail "routine maintenance changes firewall-only lock ownership"
! grep -Fq 'ExecStartPre=+/usr/bin/chmod 0600 /run/ufw.lock /run/xtables.lock' "$maintenance_unit" \
    || fail "routine maintenance changes firewall-only lock modes"
assert_file_contains "$maintenance_unit" 'ExecStart=/opt/vaultwarden-scripts/maintenance.sh run --email'
! grep -Fq -- '--comprehensive' "$maintenance_unit" \
    || fail "routine maintenance still invokes comprehensive mode"

assert_file_contains "$firewall_unit" 'ReadWritePaths=/etc/ufw /run/ufw.lock /run/xtables.lock'
assert_file_contains "$firewall_unit" 'ExecStartPre=+/usr/bin/touch /run/ufw.lock /run/xtables.lock'
assert_file_contains "$firewall_unit" 'ExecStartPre=+/usr/bin/chown root:root /run/ufw.lock /run/xtables.lock'
assert_file_contains "$firewall_unit" 'ExecStartPre=+/usr/bin/chmod 0600 /run/ufw.lock /run/xtables.lock'
assert_file_contains "$dns_timer" 'OnCalendar=*-*-* *:00:00'
assert_file_contains "$firewall_timer" 'OnCalendar=Sat *-*-* 04:00:00'

if command -v systemd-analyze >/dev/null 2>&1; then
    unit_dir="$TMP/systemd-units"
    mkdir -p "$unit_dir"
    cp "$health_unit" "$maintenance_unit" "$firewall_unit" "$unit_dir/"
    sed -i 's|^ExecStart=.*|ExecStart=/usr/bin/true|' "$unit_dir"/*.service
    cat > "$unit_dir/docker.service" <<'EOF_UNIT'
[Service]
Type=oneshot
ExecStart=/usr/bin/true
EOF_UNIT
    cat > "$unit_dir/vaultwarden-notify-failure@.service" <<'EOF_UNIT'
[Service]
Type=oneshot
ExecStart=/usr/bin/true
EOF_UNIT
    verify_output="$TMP/systemd-analyze.out"
    if ! SYSTEMD_UNIT_PATH="$unit_dir:" systemd-analyze verify \
        vaultwarden-health.service \
        vaultwarden-maintenance.service \
        vaultwarden-firewall-update.service > "$verify_output" 2>&1; then
        cat "$verify_output" >&2
        fail "systemd-analyze rejected the modified units"
    fi
else
    printf 'SKIP: systemd-analyze unavailable; static systemd path assertions passed\n'
fi

maintenance_runner="$ROOT/utilities/maintenance-run.sh"
maintenance_utils="$ROOT/lib/maintenance-utils.sh"
deep_db_maintenance="$ROOT/utilities/maintenance-db-maint.sh"

for function_name in optimize_database validate_system_health generate_maintenance_summary; do
    grep -Eq "^${function_name}\\(\\)" "$maintenance_utils" \
        || fail "maintenance library does not own ${function_name}"
    ! grep -Eq "^${function_name}\\(\\)" "$maintenance_runner" \
        || fail "maintenance runner duplicates canonical ${function_name}"
done
! grep -Eq '_SAVE_SCRIPT_DIR|_MAINT_SCRIPT_DIR' "$maintenance_runner" \
    || fail "maintenance runner retains stale SCRIPT_DIR save/restore state"
assert_file_contains "$maintenance_runner" 'source "$PROJECT_ROOT/lib/maintenance-utils.sh"'
assert_file_contains "$maintenance_runner" 'MAINTENANCE_SUMMARY_RESULT'
assert_file_contains "$maintenance_runner" 'MAINTENANCE_SUMMARY_STATE'
assert_file_contains "$maintenance_runner" 'exit "$maintenance_result"'
! grep -Fq 'local critical_failures=' "$maintenance_runner" \
    || fail "maintenance runner duplicates canonical result classification"

routine_function="$TMP/optimize-database.function"
extract_func "$maintenance_utils" optimize_database > "$routine_function"
for forbidden in 'backup-run.sh' 'docker compose' 'VACUUM' 'ANALYZE' 'wal_checkpoint(TRUNCATE)' 'integrity_check' 'trap '; do
    ! grep -Fq "$forbidden" "$routine_function" \
        || fail "routine database optimization contains deep-maintenance behavior: $forbidden"
done

routine_dir="$TMP/routine-db"
mkdir -p "$routine_dir/state/data" "$routine_dir/bin"
: > "$routine_dir/state/data/db.sqlite3"
cat > "$routine_dir/bin/sqlite3" <<'EOF_SQLITE'
#!/usr/bin/env bash
set -euo pipefail
sql="${*: -1}"
printf '%s\n' "$sql" >> "${SQLITE_CALL_LOG:?}"
case "$sql" in
    'PRAGMA page_count;') printf '120\n' ;;
    'PRAGMA freelist_count;') printf '7\n' ;;
    'PRAGMA page_size;') printf '4096\n' ;;
esac
EOF_SQLITE
chmod 0755 "$routine_dir/bin/sqlite3"
cat > "$routine_dir/probe.bash" <<'EOF_ROUTINE_PROBE'
#!/usr/bin/env bash
set -euo pipefail
OPTIMIZE_DATABASE=true
DRY_RUN=false
get_config_value(){ printf '%s\n' "${VW_TEST_STATE_DIR:?}"; }
log_info(){ :; }
log_warn(){ :; }
log_error(){ :; }
log_success(){ :; }
EOF_ROUTINE_PROBE
cat "$routine_function" >> "$routine_dir/probe.bash"
printf '\noptimize_database\n' >> "$routine_dir/probe.bash"
SQLITE_CALL_LOG="$routine_dir/sqlite.log" \
VW_TEST_STATE_DIR="$routine_dir/state" \
PATH="$routine_dir/bin:$PATH" \
    "$BASH" "$routine_dir/probe.bash" \
    || fail "routine online database maintenance failed"
assert_file_contains "$routine_dir/sqlite.log" 'PRAGMA optimize;'
assert_file_contains "$routine_dir/sqlite.log" 'PRAGMA wal_checkpoint(PASSIVE);'
assert_file_contains "$routine_dir/sqlite.log" 'PRAGMA page_count;'
assert_file_contains "$routine_dir/sqlite.log" 'PRAGMA freelist_count;'
assert_file_contains "$routine_dir/sqlite.log" 'PRAGMA page_size;'

for required in \
    'utilities/backup-run.sh" run db' \
    'docker compose stop vaultwarden' \
    'PRAGMA wal_checkpoint(TRUNCATE);' \
    'PRAGMA optimize;' \
    'VACUUM;'; do
    assert_file_contains "$deep_db_maintenance" "$required"
done

health_root="$TMP/health-root"
mkdir -p "$health_root/utilities"
cat > "$health_root/utilities/maintenance-health.sh" <<'EOF_HEALTH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "${HEALTH_ARGS_LOG:?}"
printf '%s\n' "${VAULTWARDEN_INTERNAL_HEALTH_CHECK:-}" > "${HEALTH_ENV_LOG:?}"
exit "${VW_TEST_HEALTH_RC:?}"
EOF_HEALTH
chmod 0755 "$health_root/utilities/maintenance-health.sh"
cat > "$TMP/health-probe.bash" <<'EOF_HEALTH_PROBE'
#!/usr/bin/env bash
set -euo pipefail
DRY_RUN=false
log_info(){ printf 'INFO: %s\n' "$*"; }
log_warn(){ printf 'WARN: %s\n' "$*"; }
log_error(){ printf 'ERROR: %s\n' "$*"; }
log_success(){ printf 'SUCCESS: %s\n' "$*"; }
EOF_HEALTH_PROBE
extract_func "$maintenance_utils" validate_system_health >> "$TMP/health-probe.bash"
printf '\nvalidate_system_health\n' >> "$TMP/health-probe.bash"

for health_rc in 0 1 75 2 3 4 9; do
    set +e
    PROJECT_ROOT="$health_root" \
    VW_TEST_HEALTH_RC="$health_rc" \
    HEALTH_ARGS_LOG="$TMP/health-${health_rc}.args" \
    HEALTH_ENV_LOG="$TMP/health-${health_rc}.env" \
        "$BASH" "$TMP/health-probe.bash" > "$TMP/health-${health_rc}.out" 2>&1
    actual_rc=$?
    set -e
    [[ "$actual_rc" -eq "$health_rc" ]] \
        || fail "quick health status $health_rc was changed to $actual_rc"
    [[ "$(cat "$TMP/health-${health_rc}.args")" == '--quiet --quick' ]] \
        || fail "maintenance health did not invoke quick quiet profile"
    [[ "$(cat "$TMP/health-${health_rc}.env")" == true ]] \
        || fail "maintenance health omitted internal health marker"
done
assert_file_contains "$TMP/health-1.out" 'passed with advisory warnings'
assert_file_contains "$TMP/health-75.out" 'skipped because another health execution was active'
for health_rc in 2 3 4; do
    assert_file_contains "$TMP/health-${health_rc}.out" "failed with status ${health_rc}"
done
assert_file_contains "$TMP/health-9.out" 'unexpected status 9'

cat > "$TMP/summary-probe.bash" <<'EOF_SUMMARY_PROBE'
#!/usr/bin/env bash
set -euo pipefail
CLEAN_LOGS=true
CLEAN_BACKUPS=true
CLEAN_DOCKER=true
OPTIMIZE_DATABASE=true
UPDATE_FIREWALL=false
UPDATE_DNS=false
TARGETED_MODE=false
EMAIL_NOTIFY=true
log_info(){ :; }
log_warn(){ :; }
send_notification_email(){
    printf '%s\n' "$1" > "${SUMMARY_SUBJECT_LOG:?}"
    printf '%s' "$2" > "${SUMMARY_BODY_LOG:?}"
}
EOF_SUMMARY_PROBE
extract_func "$maintenance_utils" _format_duration >> "$TMP/summary-probe.bash"
extract_func "$maintenance_utils" _health_summary_line >> "$TMP/summary-probe.bash"
extract_func "$maintenance_utils" generate_maintenance_summary >> "$TMP/summary-probe.bash"
cat >> "$TMP/summary-probe.bash" <<'EOF_SUMMARY_PROBE'
generate_maintenance_summary 0 0 0 0 1 1 "${VW_TEST_HEALTH_RC:?}" 5 "${VW_TEST_RECOVERY_RC:?}"
printf '%s\n' "${MAINTENANCE_SUMMARY_STATE:?}" > "${SUMMARY_STATE_LOG:?}"
exit "${MAINTENANCE_SUMMARY_RESULT:?}"
EOF_SUMMARY_PROBE

run_summary_case() {
    local name="$1" health_rc="$2" recovery_rc="$3" expected_rc="$4"
    set +e
    VW_TEST_HEALTH_RC="$health_rc" \
    VW_TEST_RECOVERY_RC="$recovery_rc" \
    SUMMARY_SUBJECT_LOG="$TMP/${name}.subject" \
    SUMMARY_BODY_LOG="$TMP/${name}.body" \
    SUMMARY_STATE_LOG="$TMP/${name}.state" \
        "$BASH" "$TMP/summary-probe.bash" > "$TMP/${name}.out" 2>&1
    actual_rc=$?
    set -e
    [[ "$actual_rc" -eq "$expected_rc" ]] \
        || fail "summary case $name returned $actual_rc instead of $expected_rc"
}

run_summary_case warning 1 0 0
assert_file_contains "$TMP/warning.out" 'Health validation: Passed with advisory warnings'
assert_file_contains "$TMP/warning.out" 'Overall Status: SUCCESS WITH WARNINGS'
assert_file_contains "$TMP/warning.subject" 'VaultWarden Maintenance: SUCCESS WITH WARNINGS'
assert_file_contains "$TMP/warning.body" 'Health validation: Passed with advisory warnings'
assert_file_contains "$TMP/warning.state" 'warnings'

run_summary_case skipped 75 0 0
assert_file_contains "$TMP/skipped.out" 'Health validation: Skipped (another health execution was active)'
assert_file_contains "$TMP/skipped.out" 'Overall Status: COMPLETED WITH SKIPS'
assert_file_contains "$TMP/skipped.subject" 'VaultWarden Maintenance: COMPLETED WITH SKIPS'
assert_file_contains "$TMP/skipped.state" 'skips'

for health_rc in 2 3 4 9; do
    run_summary_case "failed-${health_rc}" "$health_rc" 0 1
    assert_file_contains "$TMP/failed-${health_rc}.out" 'Health validation: Failed'
    assert_file_contains "$TMP/failed-${health_rc}.out" 'Overall Status: COMPLETED WITH ISSUES'
    assert_file_contains "$TMP/failed-${health_rc}.subject" 'VaultWarden Maintenance: ISSUES DETECTED'
    assert_file_contains "$TMP/failed-${health_rc}.state" 'issues'
done

run_summary_case recovery-failed 0 1 1
assert_file_contains "$TMP/recovery-failed.out" 'Recovery-kit fallback cleanup: Failed'
assert_file_contains "$TMP/recovery-failed.out" 'Overall Status: COMPLETED WITH ISSUES'
assert_file_contains "$TMP/recovery-failed.subject" 'VaultWarden Maintenance: ISSUES DETECTED'
assert_file_contains "$TMP/recovery-failed.body" 'Recovery-kit fallback cleanup: Failed'
assert_file_contains "$TMP/recovery-failed.state" 'issues'

run_summary_case multiple-failures 2 1 2

printf 'PASS: firewall updater, routine maintenance ownership, and systemd sandbox contracts\n'
