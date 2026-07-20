#!/usr/bin/env bash
# Health alert state-transition regression tests.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

# The dynamically extracted production function consumes these fixture variables
# through eval, which static analysis cannot observe.
# shellcheck disable=SC2034
check_health_recovery_notification_contracts() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
HEALTH="$ROOT/utilities/maintenance-health.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

extract_func() {
    local file="$1" func="$2"
    awk -v f="$func" '
        $0 ~ "^" f "\\(\\)" {p=1}
        p {
            print
            opens=gsub(/\{/, "{"); closes=gsub(/\}/, "}")
            depth += opens - closes
            if (depth == 0) exit
        }' "$file"
}

eval "$(extract_func "$HEALTH" _notify_recovery)"

reset_fixture() {
    rm -f "$TMP/active-incident.state"
    ACTIVE_INCIDENT_FILE="$TMP/active-incident.state"
    ALERT_RECOVERY_TTL=86400
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
    ACTIVE_INCIDENT_ID=""
    ACTIVE_INCIDENT_STARTED_AT=""
    ACTIVE_INCIDENT_LAST_UNHEALTHY_AT=""
    ACTIVE_INCIDENT_HOSTNAME=""
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

reset_fixture
: > "$ACTIVE_INCIDENT_FILE"
INCIDENT_LOAD_RC=1
_notify_recovery
(( LOAD_COUNT == 1 )) || fail "existing incident state must be validated"
(( ACQUIRE_COUNT == 0 )) || fail "invalid incident state must not acquire a recovery cooldown"
(( SEND_COUNT == 0 )) || fail "invalid incident state must not send a recovery email"
[[ -e "$ACTIVE_INCIDENT_FILE" ]] || fail "invalid incident evidence must be preserved"
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

! grep -Fq 'No preceding incident snapshot was available.' "$HEALTH" \
    || fail "generic no-incident recovery email path must not exist"

printf 'PASS: health recovery emails require a valid active incident\n'
)

check_health_recovery_notification_contracts
