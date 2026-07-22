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

write_valid_incident() {
    cat > "$ACTIVE_INCIDENT_FILE" <<'INCIDENT'
meta	incident_id	vw-test-incident
meta	started_at	2026-07-20T01:00:00+00:00
meta	last_unhealthy_at	2026-07-20T01:05:00+00:00
meta	hostname	vaultwarden-test
check	container:vaultwarden_app	fail	Container was not running
INCIDENT
    chmod 0600 "$ACTIVE_INCIDENT_FILE"
}

reset_fixture() {
    command rm -rf -- "$TMP"/*
    ALERT_LOCK_DIR="$TMP"
    ACTIVE_INCIDENT_FILE="$TMP/active-incident.state"
    RECOVERY_DELIVERY_STATE_FILE="$TMP/recovery-delivery.state"
    ALERT_RECOVERY_TTL=86400
    ALERT_RECOVERY_PENDING_TTL=30
    passed=27
    warnings=0
    failed=0
    ACQUIRE_COUNT=0
    SEND_COUNT=0
    RELEASE_COUNT=0
    TRACE=""
    CAPTURED_SUBJECT=""
    CAPTURED_BODY=""
    RECOVERY_LOCK_FD=""
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

_acquire_alert_lock() {
    (( ACQUIRE_COUNT += 1 )) || true
    return 0
}

_release_recovery_lock() {
    (( RELEASE_COUNT += 1 )) || true
    _state_remove_regular_file "${ALERT_LOCK_DIR}/recovery.cooldown" "Recovery cooldown state" || true
}

_send_notification() {
    (( SEND_COUNT += 1 )) || true
    CAPTURED_SUBJECT="$1"
    CAPTURED_BODY="$2"
    return 0
}

reset_fixture
_notify_recovery
(( ACQUIRE_COUNT == 0 )) || fail "clean steady state must not acquire a recovery cooldown"
(( SEND_COUNT == 0 )) || fail "clean steady state must not send a recovery email"
[[ "$TRACE" == *"No active health incident"* ]] || fail "clean steady state should log a debug no-op"
[[ ! -e "$RECOVERY_DELIVERY_STATE_FILE" ]] || fail "clean steady state must not create delivery state"

reset_fixture
ln -s "$TMP/missing-incident" "$ACTIVE_INCIDENT_FILE"
if _notify_recovery; then
    fail "dangling incident symlink must fail closed"
fi
(( SEND_COUNT == 0 )) || fail "dangling incident symlink must not send email"
[[ -L "$ACTIVE_INCIDENT_FILE" ]] || fail "dangling incident symlink evidence must be preserved"

reset_fixture
: > "$ACTIVE_INCIDENT_FILE"
if _notify_recovery; then
    fail "invalid incident state must fail closed"
fi
(( ACQUIRE_COUNT == 0 )) || fail "invalid incident state must not acquire a recovery cooldown"
(( SEND_COUNT == 0 )) || fail "invalid incident state must not send a recovery email"
[[ -e "$ACTIVE_INCIDENT_FILE" ]] || fail "invalid incident evidence must be preserved"
[[ ! -e "$RECOVERY_DELIVERY_STATE_FILE" ]] || fail "invalid incident must not create delivery state"
[[ "$TRACE" == *"unreadable or invalid"* ]] || fail "invalid incident state should be reported"

reset_fixture
write_valid_incident
_notify_recovery || fail "valid recovery must succeed"
(( ACQUIRE_COUNT == 1 )) || fail "valid recovery must acquire the recovery cooldown"
(( SEND_COUNT == 1 )) || fail "valid recovery must send exactly one email"
[[ "$CAPTURED_SUBJECT" == *"RECOVERED [Incident vw-test-incident]"* ]] || fail "recovery subject must identify the incident"
[[ "$CAPTURED_BODY" == *"Previously unhealthy checks:"* && "$CAPTURED_BODY" == *"container:vaultwarden_app [FAIL]"* ]] || fail "recovery body must include prior unhealthy context"
[[ ! -e "$ACTIVE_INCIDENT_FILE" ]] || fail "delivered recovery must close the active incident"
[[ ! -e "$RECOVERY_DELIVERY_STATE_FILE" ]] || fail "normal closure must clear delivered state"

reset_fixture
failed=1
write_valid_incident
_notify_recovery
(( ACQUIRE_COUNT == 0 && SEND_COUNT == 0 )) || fail "an unhealthy run must never enter recovery notification handling"
[[ -e "$ACTIVE_INCIDENT_FILE" ]] || fail "an unhealthy run must preserve the active incident"

reset_fixture
write_valid_incident
_send_notification() {
    (( SEND_COUNT += 1 )) || true
    CAPTURED_SUBJECT="$1"
    CAPTURED_BODY="$2"
    return 42
}
if _notify_recovery; then
    fail "failed recovery delivery must return non-zero"
fi
(( RELEASE_COUNT == 1 )) || fail "failed recovery delivery must release its cooldown"
[[ -e "$ACTIVE_INCIDENT_FILE" ]] || fail "failed recovery delivery must preserve incident state for retry"
[[ ! -e "$RECOVERY_DELIVERY_STATE_FILE" ]] || fail "failed recovery delivery must clear pending state"
_send_notification() {
    (( SEND_COUNT += 1 )) || true
    CAPTURED_SUBJECT="$1"
    CAPTURED_BODY="$2"
    return 0
}
_notify_recovery || fail "recovery retry after failed delivery returned nonzero"
(( SEND_COUNT == 2 )) || fail "failed recovery delivery was not retryable"

reset_fixture
write_valid_incident
_recovery_delivery_state_write pending vw-test-incident "$(date +%s)"
_notify_recovery || fail "recent pending lease should be a benign no-op"
(( ACQUIRE_COUNT == 0 && SEND_COUNT == 0 )) || fail "recent pending lease must suppress a concurrent duplicate"

reset_fixture
write_valid_incident
_recovery_delivery_state_write pending vw-test-incident "$(( $(date +%s) - ALERT_RECOVERY_PENDING_TTL - 1 ))"
_notify_recovery || fail "stale pending lease retry returned nonzero"
(( RELEASE_COUNT == 1 && ACQUIRE_COUNT == 1 && SEND_COUNT == 1 )) || fail "stale pending lease must permit one retry"
[[ "$TRACE" == *"Stale recovery delivery lease"* ]] || fail "stale pending lease retry must be logged"

reset_fixture
write_valid_incident
_recovery_delivery_state_write delivered vw-older-incident "$(date +%s)"
_notify_recovery || fail "delivery state for another incident must not block recovery"
(( ACQUIRE_COUNT == 1 && SEND_COUNT == 1 )) || fail "delivery state for an older incident must not suppress the new incident"

reset_fixture
write_valid_incident
printf 'broken\tstate\n' > "$RECOVERY_DELIVERY_STATE_FILE"
chmod 0600 "$RECOVERY_DELIVERY_STATE_FILE"
if _notify_recovery; then
    fail "corrupt delivery state must fail closed"
fi
(( ACQUIRE_COUNT == 0 && SEND_COUNT == 0 )) || fail "corrupt delivery state must fail closed before cooldown or email"
[[ -e "$RECOVERY_DELIVERY_STATE_FILE" && -e "$ACTIVE_INCIDENT_FILE" ]] || fail "corrupt delivery state and incident evidence must be preserved"

reset_fixture
write_valid_incident
ln -s "$TMP/delivery-target" "$RECOVERY_DELIVERY_STATE_FILE"
if _notify_recovery; then
    fail "delivery-state symlink must fail closed"
fi
(( SEND_COUNT == 0 )) || fail "delivery-state symlink must not send email"

reset_fixture
write_valid_incident
ln -s "$TMP/lock-target" "$TMP/recovery-delivery.lock"
if _notify_recovery; then
    fail "recovery lock symlink must fail closed"
fi
(( SEND_COUNT == 0 )) || fail "recovery lock symlink must not send email"

reset_fixture
write_valid_incident
mkdir -p "$TMP/recovery-delivery.lock"
if _notify_recovery; then
    fail "recovery lock directory must fail closed"
fi
(( SEND_COUNT == 0 )) || fail "recovery lock directory must not send email"

reset_fixture
write_valid_incident
recovered_file="${ACTIVE_INCIDENT_FILE}.recovered"
mkdir -p "$recovered_file"
if _notify_recovery; then
    fail "invalid recovered destination must keep the incident unresolved"
fi
(( SEND_COUNT == 1 && ACQUIRE_COUNT == 1 )) || fail "invalid recovered destination changed the initial delivery count"
_recovery_delivery_state_load || fail "invalid recovered destination must retain delivered state"
[[ "$RECOVERY_DELIVERY_PHASE" == "delivered" ]] || fail "invalid recovered destination must retain a delivered marker"
[[ -e "$ACTIVE_INCIDENT_FILE" && -d "$recovered_file" ]] || fail "invalid recovered destination must preserve evidence"

reset_fixture
write_valid_incident
recovered_file="${ACTIVE_INCIDENT_FILE}.recovered"
mv() {
    local arg
    local -a operands=()
    for arg in "$@"; do
        [[ "$arg" == -* ]] || operands+=("$arg")
    done
    if [[ "${operands[0]:-}" == "$ACTIVE_INCIDENT_FILE" && "${operands[1]:-}" == "$recovered_file" ]]; then
        return 1
    fi
    command mv "$@"
}
if _notify_recovery; then
    fail "incident archival failure must remain unresolved"
fi
(( SEND_COUNT == 1 )) || fail "incident archival failure changed the first delivery count"
_recovery_delivery_state_load || fail "incident archival failure must retain delivery state"
[[ "$RECOVERY_DELIVERY_PHASE" == "delivered" ]] || fail "incident archival failure must retain a delivered marker"
if _notify_recovery; then
    fail "delivered incident archival retry should remain unresolved until closure succeeds"
fi
(( SEND_COUNT == 1 )) || fail "delivered incident archival retry sent a duplicate recovery email"
unset -f mv
_notify_recovery || fail "incident archival retry after filesystem recovery returned nonzero"
(( SEND_COUNT == 1 )) || fail "incident closure retry changed the delivery count"
[[ ! -e "$ACTIVE_INCIDENT_FILE" && ! -e "$RECOVERY_DELIVERY_STATE_FILE" ]] || fail "incident closure retry did not close the incident and clear delivered state"

reset_fixture
write_valid_incident
recovered_file="${ACTIVE_INCIDENT_FILE}.recovered"
rm() {
    local arg
    for arg in "$@"; do
        [[ "$arg" == "$recovered_file" ]] && return 1
    done
    command rm "$@"
}
_notify_recovery || fail "cleanup failure should still report successful closure"
unset -f rm
(( SEND_COUNT == 1 )) || fail "cleanup failure changed the successful delivery count"
[[ ! -e "$ACTIVE_INCIDENT_FILE" ]] || fail "cleanup failure left the incident active"
[[ -e "$recovered_file" ]] || fail "cleanup failure must preserve bounded recovered evidence"
_notify_recovery || fail "cleanup failure follow-up should not duplicate recovery"
(( SEND_COUNT == 1 )) || fail "cleanup failure follow-up permitted duplicate delivery"

(
# shellcheck source=../../../lib/health-alerts.sh
source "$ROOT/lib/health-alerts.sh"
ALERT_LOCK_DIR="$TMP/real"
ACTIVE_INCIDENT_FILE="$ALERT_LOCK_DIR/active-incident.state"
RECOVERY_DELIVERY_STATE_FILE="$ALERT_LOCK_DIR/recovery-delivery.state"
ALERT_RECOVERY_TTL=86400
ALERT_RECOVERY_PENDING_TTL=30
passed=27
warnings=0
failed=0
RECOVERY_LOCK_FD=""
ACTIVE_INCIDENT_AVAILABLE=false
ACTIVE_INCIDENT_ID=""
ACTIVE_INCIDENT_STARTED_AT=""
ACTIVE_INCIDENT_LAST_UNHEALTHY_AT=""
ACTIVE_INCIDENT_HOSTNAME=""
RECOVERY_DELIVERY_PHASE=""
RECOVERY_DELIVERY_INCIDENT_ID=""
RECOVERY_DELIVERY_UPDATED_AT=""
declare -A incident_statuses=()
declare -A incident_details=()
declare -a incident_check_order=()
declare -A check_results=()
declare -A check_messages=()
declare -a check_order=()
log_debug() { :; }
log_info() { :; }
log_warn() { :; }
_send_notification() { return 0; }

mkdir -p "$ALERT_LOCK_DIR"
printf 'meta\tincident_id\tvw-invalid\nmeta\tstarted_at\t2026-07-20T01:00:00+00:00\ncheck\tcontainer\tpass\tbad\n' > "$ACTIVE_INCIDENT_FILE"
chmod 0600 "$ACTIVE_INCIDENT_FILE"
! _incident_load "$ACTIVE_INCIDENT_FILE" || fail "invalid persisted status must be rejected"

printf 'meta\tincident_id\tvw-dup\nmeta\tincident_id\tvw-dup-two\nmeta\tstarted_at\t2026-07-20T01:00:00+00:00\ncheck\tcontainer\tfail\tbad\n' > "$ACTIVE_INCIDENT_FILE"
chmod 0600 "$ACTIVE_INCIDENT_FILE"
! _incident_load "$ACTIVE_INCIDENT_FILE" || fail "duplicate incident id must be rejected"

printf 'meta\tincident_id\tvw-missing\ncheck\tcontainer\tfail\tbad\n' > "$ACTIVE_INCIDENT_FILE"
chmod 0600 "$ACTIVE_INCIDENT_FILE"
! _incident_load "$ACTIVE_INCIDENT_FILE" || fail "missing started_at must be rejected"

printf 'meta\tincident_id\tvw-tabs\nmeta\tstarted_at\t2026-07-20T01:00:00+00:00\ncheck\tcontainer\tfail\tbad\textra\n' > "$ACTIVE_INCIDENT_FILE"
chmod 0600 "$ACTIVE_INCIDENT_FILE"
! _incident_load "$ACTIVE_INCIDENT_FILE" || fail "extra fields must be rejected"

printf 'meta\tincident_id\tvw-trailing\nmeta\tstarted_at\t2026-07-20T01:00:00+00:00\nunknown\tfield\tvalue\n' > "$ACTIVE_INCIDENT_FILE"
chmod 0600 "$ACTIVE_INCIDENT_FILE"
! _incident_load "$ACTIVE_INCIDENT_FILE" || fail "unknown record types must be rejected"

printf 'meta\tincident_id\tvw-nonl\nmeta\tstarted_at\t2026-07-20T01:00:00+00:00\ncheck\tcontainer\tfail\tbad' > "$ACTIVE_INCIDENT_FILE"
chmod 0600 "$ACTIVE_INCIDENT_FILE"
! _incident_load "$ACTIVE_INCIDENT_FILE" || fail "unterminated final record must be rejected"

printf 'meta\tincident_id\tvw-nul\nmeta\tstarted_at\t2026-07-20T01:00:00+00:00\ncheck\tcontainer\tfail\tba\0d\n' > "$ACTIVE_INCIDENT_FILE"
chmod 0600 "$ACTIVE_INCIDENT_FILE"
! _incident_load "$ACTIVE_INCIDENT_FILE" || fail "embedded NUL bytes must be rejected"

ACTIVE_INCIDENT_ID='vw-real-parser-recovery'
ACTIVE_INCIDENT_STARTED_AT='2026-07-20T01:00:00+00:00'
ACTIVE_INCIDENT_LAST_UNHEALTHY_AT='2026-07-20T01:05:00+00:00'
ACTIVE_INCIDENT_HOSTNAME='vaultwarden-test'
incident_check_order=('container:vaultwarden_app' 'backup:age')
incident_statuses['container:vaultwarden_app']='fail'
incident_details['container:vaultwarden_app']='Container was not running'
incident_statuses['backup:age']='warn'
incident_details['backup:age']='Latest backup was stale'
_incident_write || fail "real incident writer should succeed"
_incident_reset_loaded_state
_incident_load "$ACTIVE_INCIDENT_FILE" || fail "real incident writer output must round-trip"

append_check_line_with_detail_bytes() {
    local path="$1" key="$2" detail_bytes="$3" encoding="$4"
    local pairs=0 odd=0 i fill

    printf 'check\t%s\tfail\t' "$key" >> "$path"
    if [[ "$encoding" == "ascii" ]]; then
        if (( detail_bytes > 0 )); then
            printf -v fill '%*s' "$detail_bytes" ''
            fill="${fill// /A}"
            printf '%s' "$fill" >> "$path"
        fi
    else
        pairs=$(( detail_bytes / 2 ))
        odd=$(( detail_bytes % 2 ))
        for (( i = 0; i < pairs; i++ )); do
            printf '\303\251' >> "$path"
        done
        if (( odd == 1 )); then
            printf 'A' >> "$path"
        fi
    fi
    printf '\n' >> "$path"
}

build_incident_file_of_size() {
    local path="$1" incident_id="$2" target_bytes="$3" encoding="$4"
    local idx=0 current_bytes remaining base_check_bytes min_line_bytes max_line_bytes
    local detail_one detail_two sum key

    printf 'meta\tincident_id\t%s\nmeta\tstarted_at\t2026-07-20T01:00:00+00:00\nmeta\tlast_unhealthy_at\t2026-07-20T01:05:00+00:00\nmeta\thostname\tvaultwarden-test\n' "$incident_id" > "$path"
    base_check_bytes="$(printf 'check\tk00000\tfail\t' | LC_ALL=C wc -c | tr -d '[:space:]')"
    min_line_bytes=$(( base_check_bytes + 1 ))
    max_line_bytes=$(( base_check_bytes + 1 + 512 ))

    while :; do
        current_bytes="$(LC_ALL=C wc -c < "$path" | tr -d '[:space:]')"
        remaining=$(( target_bytes - current_bytes ))
        if (( remaining == 0 )); then
            break
        fi
        (( remaining >= min_line_bytes )) || fail "cannot represent target incident size: ${target_bytes} bytes"

        key="k$(printf '%05d' "$idx")"
        idx=$(( idx + 1 ))

        if (( remaining <= max_line_bytes )); then
            append_check_line_with_detail_bytes "$path" "$key" "$(( remaining - min_line_bytes ))" "$encoding"
            break
        fi

        if (( remaining > 2 * max_line_bytes )); then
            append_check_line_with_detail_bytes "$path" "$key" 512 "$encoding"
            continue
        fi

        sum=$(( remaining - (2 * min_line_bytes) ))
        (( sum >= 0 && sum <= 1024 )) || fail "internal test size decomposition failed"
        if (( sum > 512 )); then
            detail_one=512
            detail_two=$(( sum - 512 ))
        else
            detail_one=$sum
            detail_two=0
        fi
        append_check_line_with_detail_bytes "$path" "$key" "$detail_one" "$encoding"
        key="k$(printf '%05d' "$idx")"
        idx=$(( idx + 1 ))
        append_check_line_with_detail_bytes "$path" "$key" "$detail_two" "$encoding"
        break
    done
}

ascii_limit_file="$TMP/ascii-limit-incident.state"
build_incident_file_of_size "$ascii_limit_file" 'vw-size' 16384 ascii
cp "$ascii_limit_file" "$ACTIVE_INCIDENT_FILE"
_incident_load "$ACTIVE_INCIDENT_FILE" || fail "exactly-at-limit ASCII incident must load"
printf 'A\n' >> "$ascii_limit_file"
cp "$ascii_limit_file" "$ACTIVE_INCIDENT_FILE"
! _incident_load "$ACTIVE_INCIDENT_FILE" || fail "one-byte-over-limit ASCII incident must be rejected"

utf8_limit_file="$TMP/utf8-limit-incident.state"
build_incident_file_of_size "$utf8_limit_file" 'vw-utf8' 16384 utf8
cp "$utf8_limit_file" "$ACTIVE_INCIDENT_FILE"
_incident_load "$ACTIVE_INCIDENT_FILE" || fail "exactly-at-limit UTF-8 incident must load"
printf '\303\251' >> "$utf8_limit_file"
cp "$utf8_limit_file" "$ACTIVE_INCIDENT_FILE"
! _incident_load "$ACTIVE_INCIDENT_FILE" || fail "one-byte-over-limit UTF-8 incident must be rejected"

printf 'v1\tpending\tvw-oversized\t%s\n' "$(printf '9%.0s' {1..600})" > "$RECOVERY_DELIVERY_STATE_FILE"
chmod 0600 "$RECOVERY_DELIVERY_STATE_FILE"
! _recovery_delivery_state_load || fail "oversized delivery state must be rejected"
)

! grep -Fq 'No preceding incident snapshot was available.' "$HEALTH" || fail "generic no-incident recovery email path must not exist"

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
mkfifo "$TMP/release-send"
touch "$TMP/sends"

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
RECOVERY_LOCK_FD=""
ACTIVE_INCIDENT_AVAILABLE=false
ACTIVE_INCIDENT_ID=""
ACTIVE_INCIDENT_STARTED_AT=""
ACTIVE_INCIDENT_LAST_UNHEALTHY_AT=""
ACTIVE_INCIDENT_HOSTNAME=""
declare -A incident_statuses=()
declare -A incident_details=()
declare -a incident_check_order=()
log_debug() { :; }
log_info() { printf '%s\n' "$*" >> "$TMP/info"; }
log_warn() { printf '%s\n' "$*" >> "$TMP/warnings"; }
_send_notification() {
    printf 'send\n' >> "$TMP/sends"
    printf 'entered\n' > "$TMP/entered-send"
    read -r _ < "$TMP/release-send"
    return 0
}
_notify_recovery
)

run_one &
first_pid=$!
while [[ ! -s "$TMP/entered-send" ]]; do :; done
run_one &
second_pid=$!
wait "$second_pid" || { printf 'FAIL: concurrent losing worker failed\n' >&2; exit 1; }
printf 'release\n' > "$TMP/release-send"
wait "$first_pid" || { printf 'FAIL: concurrent winning worker failed\n' >&2; exit 1; }
[[ "$(wc -l < "$TMP/sends")" -eq 1 ]] || { printf 'FAIL: concurrent recovery attempts did not send exactly once\n' >&2; exit 1; }
[[ ! -e "$TMP/alerts/active-incident.state" ]] || { printf 'FAIL: concurrent recovery did not close the active incident\n' >&2; exit 1; }
printf 'PASS: concurrent health recovery attempts send once\n'
)

check_health_recovery_concurrency_contract