#!/usr/bin/env bash
# Health alert state-transition regression tests.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

check_health_recovery_notification_contracts() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
HEALTH="$ROOT/utilities/maintenance-health.sh"
# shellcheck source=../../../lib/health-alerts.sh
source "$ROOT/lib/health-alerts.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

reset_fixture() {
    command rm -f -- \
        "$TMP/active-incident.state" \
        "$TMP/active-incident.state.recovered" \
        "$TMP/recovery-delivery.state" \
        "$TMP/recovery-delivery.lock" \
        "$TMP/recovery.cooldown"
    ALERT_LOCK_DIR="$TMP"
    ACTIVE_INCIDENT_FILE="$TMP/active-incident.state"
    RECOVERY_DELIVERY_STATE_FILE="$TMP/recovery-delivery.state"
    ALERT_RECOVERY_TTL=86400
    ALERT_RECOVERY_PENDING_TTL=30
    passed=27
    warnings=0
    failed=0
    LOAD_COUNT=0
    ACQUIRE_COUNT=0
    SEND_COUNT=0
    RELEASE_COUNT=0
    INCIDENT_LOAD_RC=0
    ACQUIRE_RC=0
    SEND_RC=0
    TRACE=""
    CAPTURED_SUBJECT=""
    CAPTURED_BODY=""
    ACTIVE_INCIDENT_AVAILABLE=false
    ACTIVE_INCIDENT_ID=""
    ACTIVE_INCIDENT_STARTED_AT=""
    ACTIVE_INCIDENT_LAST_UNHEALTHY_AT=""
    ACTIVE_INCIDENT_HOSTNAME=""
    RECOVERY_DELIVERY_PHASE=""
    RECOVERY_DELIVERY_INCIDENT_ID=""
    RECOVERY_DELIVERY_UPDATED_AT=""
    incident_check_order=()
    declare -gA incident_statuses=()
    declare -gA incident_details=()
}

log_debug() { TRACE+="debug:$*"$'\n'; }
log_info()  { TRACE+="info:$*"$'\n'; }
log_warn()  { TRACE+="warn:$*"$'\n'; }

_incident_load() {
    (( LOAD_COUNT += 1 )) || true
    (( INCIDENT_LOAD_RC == 0 )) || return "$INCIDENT_LOAD_RC"
    ACTIVE_INCIDENT_ID="vw-test-incident"
    ACTIVE_INCIDENT_STARTED_AT="2026-07-20T01:00:00+00:00"
    ACTIVE_INCIDENT_LAST_UNHEALTHY_AT="2026-07-20T01:05:00+00:00"
    ACTIVE_INCIDENT_HOSTNAME="vaultwarden-test"
    incident_check_order=("container:vaultwarden_app")
    incident_statuses["container:vaultwarden_app"]="fail"
    incident_details["container:vaultwarden_app"]="Container was not running"
}

_acquire_alert_lock() {
    (( ACQUIRE_COUNT += 1 )) || true
    return "$ACQUIRE_RC"
}

_send_notification() {
    (( SEND_COUNT += 1 )) || true
    CAPTURED_SUBJECT="$1"
    CAPTURED_BODY="$2"
    return "$SEND_RC"
}

_release_recovery_lock() {
    (( RELEASE_COUNT += 1 )) || true
}

_incident_format_duration() {
    printf '5m (300s)'
}

reset_fixture
_notify_recovery
(( LOAD_COUNT == 0 )) || fail "clean steady state must not load incident state"
(( ACQUIRE_COUNT == 0 )) || fail "clean steady state must not acquire a recovery cooldown"
(( SEND_COUNT == 0 )) || fail "clean steady state must not send a recovery email"
[[ "$TRACE" == *"No active health incident"* ]] || fail "clean steady state should log a debug no-op"
[[ ! -e "$RECOVERY_DELIVERY_STATE_FILE" ]] || fail "clean steady state must not create delivery state"

reset_fixture
: > "$ACTIVE_INCIDENT_FILE"
INCIDENT_LOAD_RC=1
_notify_recovery
(( LOAD_COUNT == 1 )) || fail "existing incident state must be validated"
(( ACQUIRE_COUNT == 0 )) || fail "invalid incident state must not acquire a recovery cooldown"
(( SEND_COUNT == 0 )) || fail "invalid incident state must not send a recovery email"
[[ -e "$ACTIVE_INCIDENT_FILE" ]] || fail "invalid incident evidence must be preserved"
[[ ! -e "$RECOVERY_DELIVERY_STATE_FILE" ]] || fail "invalid incident must not create delivery state"
[[ "$TRACE" == *"unreadable or invalid"* ]] || fail "invalid incident state should be reported"

reset_fixture
: > "$ACTIVE_INCIDENT_FILE"
_notify_recovery
(( LOAD_COUNT == 1 )) || fail "valid recovery must load incident state"
(( ACQUIRE_COUNT == 1 )) || fail "valid recovery must acquire the recovery cooldown"
(( SEND_COUNT == 1 )) || fail "valid recovery must send exactly one email"
[[ "$CAPTURED_SUBJECT" == *"RECOVERED [Incident vw-test-incident]"* ]] \
    || fail "recovery subject must identify the incident"
[[ "$CAPTURED_BODY" == *"Previously unhealthy checks:"* \
    && "$CAPTURED_BODY" == *"container:vaultwarden_app [FAIL]"* ]] \
    || fail "recovery body must include prior unhealthy context"
[[ ! -e "$ACTIVE_INCIDENT_FILE" ]] || fail "delivered recovery must close the active incident"
[[ ! -e "$RECOVERY_DELIVERY_STATE_FILE" ]] || fail "normal closure must clear delivered state"

reset_fixture
failed=1
: > "$ACTIVE_INCIDENT_FILE"
_notify_recovery
(( LOAD_COUNT == 0 && ACQUIRE_COUNT == 0 && SEND_COUNT == 0 )) \
    || fail "an unhealthy run must never enter recovery notification handling"
[[ -e "$ACTIVE_INCIDENT_FILE" ]] || fail "an unhealthy run must preserve the active incident"

reset_fixture
: > "$ACTIVE_INCIDENT_FILE"
ACQUIRE_RC=1
_notify_recovery
(( ACQUIRE_COUNT == 1 && SEND_COUNT == 0 )) \
    || fail "recovery cooldown must suppress duplicate delivery"
[[ -e "$ACTIVE_INCIDENT_FILE" ]] || fail "cooldown suppression must preserve incident state"

reset_fixture
: > "$ACTIVE_INCIDENT_FILE"
SEND_RC=1
if _notify_recovery; then
    fail "failed recovery delivery must return non-zero"
fi
(( RELEASE_COUNT == 1 )) || fail "failed recovery delivery must release its cooldown"
[[ -e "$ACTIVE_INCIDENT_FILE" ]] || fail "failed recovery delivery must preserve incident state for retry"
[[ ! -e "$RECOVERY_DELIVERY_STATE_FILE" ]] || fail "failed recovery delivery must clear pending state"
SEND_RC=0
_notify_recovery || fail "recovery retry after failed delivery returned nonzero"
(( SEND_COUNT == 2 )) || fail "failed recovery delivery was not retryable"
[[ ! -e "$ACTIVE_INCIDENT_FILE" ]] || fail "successful retry did not close the active incident"

reset_fixture
: > "$ACTIVE_INCIDENT_FILE"
_recovery_delivery_state_write pending vw-test-incident "$(date +%s)"
_notify_recovery
(( ACQUIRE_COUNT == 0 && SEND_COUNT == 0 )) \
    || fail "recent pending lease must suppress a concurrent duplicate"
[[ -e "$ACTIVE_INCIDENT_FILE" ]] || fail "recent pending lease must preserve the active incident"

reset_fixture
: > "$ACTIVE_INCIDENT_FILE"
_recovery_delivery_state_write pending vw-test-incident \
    "$(( $(date +%s) - ALERT_RECOVERY_PENDING_TTL - 1 ))"
_notify_recovery || fail "stale pending lease retry returned nonzero"
(( RELEASE_COUNT == 1 && ACQUIRE_COUNT == 1 && SEND_COUNT == 1 )) \
    || fail "stale pending lease must permit one retry"
[[ "$TRACE" == *"Stale recovery delivery lease"* ]] \
    || fail "stale pending lease retry must be logged"

reset_fixture
: > "$ACTIVE_INCIDENT_FILE"
_recovery_delivery_state_write delivered vw-older-incident "$(date +%s)"
_notify_recovery || fail "new incident recovery returned nonzero with older delivery state"
(( ACQUIRE_COUNT == 1 && SEND_COUNT == 1 )) \
    || fail "delivery state for an older incident must not suppress the new incident"

reset_fixture
: > "$ACTIVE_INCIDENT_FILE"
printf 'broken\tstate\n' > "$RECOVERY_DELIVERY_STATE_FILE"
chmod 0600 "$RECOVERY_DELIVERY_STATE_FILE"
_notify_recovery
(( ACQUIRE_COUNT == 0 && SEND_COUNT == 0 )) \
    || fail "corrupt delivery state must fail closed before cooldown or email"
[[ -e "$RECOVERY_DELIVERY_STATE_FILE" && -e "$ACTIVE_INCIDENT_FILE" ]] \
    || fail "corrupt delivery state and incident evidence must be preserved"
[[ "$TRACE" == *"unreadable or invalid"* ]] \
    || fail "corrupt delivery state must produce an actionable warning"

reset_fixture
: > "$ACTIVE_INCIDENT_FILE"
recovered_file="${ACTIVE_INCIDENT_FILE}.recovered"
mv() {
    local arg
    local -a operands=()

    for arg in "$@"; do
        [[ "$arg" == -* ]] || operands+=("$arg")
    done
    if [[ "${operands[0]:-}" == "$ACTIVE_INCIDENT_FILE" \
       && "${operands[1]:-}" == "$recovered_file" ]]; then
        return 1
    fi
    command mv "$@"
}
_notify_recovery || fail "successful recovery returned nonzero when incident archival failed"
(( SEND_COUNT == 1 && ACQUIRE_COUNT == 1 )) \
    || fail "incident archival failure changed the first delivery count"
_recovery_delivery_state_load || fail "incident archival failure did not retain delivery state"
[[ "$RECOVERY_DELIVERY_PHASE" == "delivered" ]] \
    || fail "incident archival failure did not retain a delivered marker"
_notify_recovery || fail "delivered incident archival retry returned nonzero"
(( SEND_COUNT == 1 && ACQUIRE_COUNT == 1 )) \
    || fail "delivered incident archival retry sent a duplicate recovery email"
unset -f mv
_notify_recovery || fail "incident archival retry after filesystem recovery returned nonzero"
(( SEND_COUNT == 1 && ACQUIRE_COUNT == 1 )) \
    || fail "incident closure retry changed the delivery count"
[[ ! -e "$ACTIVE_INCIDENT_FILE" && ! -e "$RECOVERY_DELIVERY_STATE_FILE" ]] \
    || fail "incident closure retry did not close the incident and clear delivered state"

reset_fixture
: > "$ACTIVE_INCIDENT_FILE"
recovered_file="${ACTIVE_INCIDENT_FILE}.recovered"
rm() {
    local arg
    for arg in "$@"; do
        [[ "$arg" == "$recovered_file" ]] && return 1
    done
    command rm "$@"
}
_notify_recovery || fail "successful recovery returned nonzero when archive cleanup failed"
unset -f rm
(( SEND_COUNT == 1 )) || fail "cleanup failure changed the successful delivery count"
(( RELEASE_COUNT == 0 )) || fail "cleanup failure released a successful recovery cooldown"
[[ ! -e "$ACTIVE_INCIDENT_FILE" ]] || fail "cleanup failure left the incident active after successful delivery"
[[ -e "$recovered_file" ]] || fail "cleanup failure did not preserve bounded recovered incident evidence"
if stat -c '%a' "$recovered_file" >/dev/null 2>&1; then
    recovered_mode="$(stat -c '%a' "$recovered_file")"
else
    recovered_mode="$(stat -f '%Lp' "$recovered_file")"
fi
[[ "$recovered_mode" == "600" ]] || fail "recovered incident evidence mode is $recovered_mode instead of 600"
[[ "$TRACE" == *"Recovery notification sent"* ]] || fail "cleanup failure obscured successful delivery"
[[ "$TRACE" == *"active incident was closed"* && "$TRACE" == *"$recovered_file"* ]] \
    || fail "cleanup failure warning was not truthful or actionable"
_notify_recovery
(( SEND_COUNT == 1 && ACQUIRE_COUNT == 1 )) \
    || fail "closed incident cleanup failure permitted duplicate recovery delivery"
command rm -f "$recovered_file"

# Re-source the library in a nested scope to restore the real parser after the
# focused side-effect doubles above.
(
# shellcheck source=../../../lib/health-alerts.sh
source "$ROOT/lib/health-alerts.sh"
_acquire_alert_lock() {
    (( ACQUIRE_COUNT += 1 )) || true
    return "$ACQUIRE_RC"
}
_release_recovery_lock() { (( RELEASE_COUNT += 1 )) || true; }
_send_notification() {
    (( SEND_COUNT += 1 )) || true
    CAPTURED_SUBJECT="$1"
    CAPTURED_BODY="$2"
    return "$SEND_RC"
}

reset_fixture
cat > "$ACTIVE_INCIDENT_FILE" <<'INVALID_INCIDENT'
meta	incident_id	vw-invalid-parser
meta	started_at	2026-07-20T01:00:00+00:00
check	container:vaultwarden_app	pass	Invalid persisted status
INVALID_INCIDENT
chmod 0600 "$ACTIVE_INCIDENT_FILE"
_notify_recovery
(( ACQUIRE_COUNT == 0 )) || fail "real parser invalid state acquired a recovery cooldown"
(( SEND_COUNT == 0 )) || fail "real parser invalid state attempted delivery"
[[ -e "$ACTIVE_INCIDENT_FILE" ]] || fail "real parser invalid state was not preserved"

reset_fixture
printf 'meta\tincident_id\tvw-trailing-record\nmeta\tstarted_at\t2026-07-20T01:00:00+00:00\nunknown\tfield\tvalue' \
    > "$ACTIVE_INCIDENT_FILE"
chmod 0600 "$ACTIVE_INCIDENT_FILE"
_notify_recovery
(( ACQUIRE_COUNT == 0 && SEND_COUNT == 0 )) \
    || fail "unterminated trailing record bypassed strict incident parsing"
[[ -e "$ACTIVE_INCIDENT_FILE" ]] \
    || fail "malformed trailing incident evidence was not preserved"

reset_fixture
cat > "$ACTIVE_INCIDENT_FILE" <<'VALID_INCIDENT'
meta	incident_id	vw-real-parser-recovery
meta	started_at	2026-07-20T01:00:00+00:00
meta	last_unhealthy_at	2026-07-20T01:05:00+00:00
meta	hostname	vaultwarden-test
check	container:vaultwarden_app	fail	Container was not running
check	backup:age	warn	Latest backup was stale
VALID_INCIDENT
chmod 0600 "$ACTIVE_INCIDENT_FILE"
_notify_recovery || fail "real serialized incident recovery failed"
(( ACQUIRE_COUNT == 1 )) || fail "real serialized incident did not acquire recovery cooldown"
(( SEND_COUNT == 1 )) || fail "real serialized incident did not send exactly one recovery email"
[[ "$CAPTURED_SUBJECT" == *"RECOVERED [Incident vw-real-parser-recovery]"* ]] \
    || fail "real parser recovery subject omitted incident ID"
[[ "$CAPTURED_BODY" == *"container:vaultwarden_app [FAIL]: Container was not running"* \
    && "$CAPTURED_BODY" == *"backup:age [WARN]: Latest backup was stale"* ]] \
    || fail "real parser recovery body omitted persisted unhealthy checks"
[[ "$CAPTURED_BODY" == *"Duration:"* && "$CAPTURED_BODY" != *"Duration: unknown"* ]] \
    || fail "real parser recovery did not produce a valid duration"
[[ ! -e "$ACTIVE_INCIDENT_FILE" ]] || fail "real parser recovery retained active incident state"
[[ ! -e "${ACTIVE_INCIDENT_FILE}.recovered" ]] || fail "normal recovery retained recovered archive state"
)

! grep -Fq 'No preceding incident snapshot was available.' "$HEALTH" \
    || fail "generic no-incident recovery email path must not exist"

printf 'PASS: health recovery emails require a valid active incident\n'
)

check_health_recovery_notification_contracts

check_health_recovery_concurrency_contract() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/alerts"
cat > "$TMP/alerts/active-incident.state" <<'INCIDENT'
meta	incident_id	vw-concurrent-recovery
meta	started_at	2026-07-20T01:00:00+00:00
meta	last_unhealthy_at	2026-07-20T01:05:00+00:00
meta	hostname	vaultwarden-test
check	container:vaultwarden_app	fail	Container was not running
INCIDENT
chmod 0600 "$TMP/alerts/active-incident.state"

run_one() (
# shellcheck source=../../../lib/health-alerts.sh
source "$ROOT/lib/health-alerts.sh"
ALERT_LOCK_DIR="$TMP/alerts"
ACTIVE_INCIDENT_FILE="$ALERT_LOCK_DIR/active-incident.state"
RECOVERY_DELIVERY_STATE_FILE="$ALERT_LOCK_DIR/recovery-delivery.state"
ALERT_RECOVERY_TTL=86400
ALERT_RECOVERY_PENDING_TTL=30
failed=0
warnings=0
passed=1
ACTIVE_INCIDENT_AVAILABLE=false
ACTIVE_INCIDENT_ID=""
ACTIVE_INCIDENT_STARTED_AT=""
ACTIVE_INCIDENT_LAST_UNHEALTHY_AT=""
ACTIVE_INCIDENT_HOSTNAME=""
declare -A incident_statuses=()
declare -A incident_details=()
declare -a incident_check_order=()
log_debug() { :; }
log_info() { :; }
log_warn() { printf '%s\n' "$*" >> "$TMP/warnings"; }
_send_notification() {
    printf 'send\n' >> "$TMP/sends"
    sleep 0.2
}
_notify_recovery
)

run_one &
first_pid=$!
run_one &
second_pid=$!
wait_rc=0
wait "$first_pid" || wait_rc=1
wait "$second_pid" || wait_rc=1
(( wait_rc == 0 )) || {
    cat "$TMP/warnings" >&2 2>/dev/null || true
    printf 'FAIL: concurrent recovery worker failed\n' >&2
    exit 1
}
[[ "$(wc -l < "$TMP/sends")" -eq 1 ]] \
    || { printf 'FAIL: concurrent recovery attempts did not send exactly once\n' >&2; exit 1; }
[[ ! -e "$TMP/alerts/active-incident.state" ]] \
    || { printf 'FAIL: concurrent recovery did not close the active incident\n' >&2; exit 1; }
printf 'PASS: concurrent health recovery attempts send once\n'
)

check_health_recovery_concurrency_contract
