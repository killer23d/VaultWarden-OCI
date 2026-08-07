#!/usr/bin/env bash
# Health alert state-transition regression tests.
set -euo pipefail
MODE="${VW_TEST_CASE_MODE:-all}"
case "$MODE" in core|locking|all) ;; *) printf 'FAIL: unknown VW_TEST_CASE_MODE for case-health-alerts.bash: %s\n' "$MODE" >&2; exit 2 ;; esac
# shellcheck source-path=SCRIPTDIR/../../..

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

check_health_alerts_core() (
set -euo pipefail

check_health_recovery_notification_contracts() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
HEALTH="$ROOT/utilities/maintenance-health.sh"
# shellcheck source=lib/health-alerts.sh
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
    HEALTH_ALERT_STATE_LOCK_FD=""
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

_release_recovery_cooldown_locked() {
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
if _notify_recovery; then
    fail "delivery state for another incident must fail closed"
fi
(( ACQUIRE_COUNT == 0 && SEND_COUNT == 0 )) \
    || fail "delivery state for another incident must suppress new delivery"
_recovery_delivery_state_load || fail "older delivered marker was not preserved"
[[ "$RECOVERY_DELIVERY_INCIDENT_ID" == "vw-older-incident" ]] \
    || fail "older delivered marker was overwritten"
[[ -e "$ACTIVE_INCIDENT_FILE" ]] || fail "different active incident was moved"

reset_fixture
_recovery_delivery_state_write delivered vw-already-closed "$(date +%s)"
_notify_recovery || fail "absent active incident with delivered state should complete closure cleanup"
(( SEND_COUNT == 0 )) || fail "already-closed incident cleanup must not send email"
[[ ! -e "$RECOVERY_DELIVERY_STATE_FILE" ]] || fail "already-closed incident cleanup retained delivered state"

reset_fixture
write_valid_incident
_send_notification() {
    (( SEND_COUNT += 1 )) || true
    cat > "$ACTIVE_INCIDENT_FILE" <<'INCIDENT'
meta	incident_id	vw-newer-incident
meta	started_at	2026-07-20T02:00:00+00:00
meta	last_unhealthy_at	2026-07-20T02:05:00+00:00
meta	hostname	vaultwarden-test
check	container:vaultwarden_app	fail	A newer failure was observed
INCIDENT
    chmod 0600 "$ACTIVE_INCIDENT_FILE"
    return 0
}
if _notify_recovery > "$TMP/identity-change.out" 2>&1; then
    fail "closure must fail when active incident identity changes after delivery"
fi
(( SEND_COUNT == 1 )) || fail "identity-change closure test did not attempt exactly one recovery email"
grep -Fq $'meta\tincident_id\tvw-newer-incident' "$ACTIVE_INCIDENT_FILE" \
    || fail "identity-change closure moved the newer active incident"
_recovery_delivery_state_load || fail "identity-change closure did not retain delivered state"
[[ "$RECOVERY_DELIVERY_PHASE" == "delivered" \
    && "$RECOVERY_DELIVERY_INCIDENT_ID" == "vw-test-incident" ]] \
    || fail "identity-change closure retained the wrong delivery marker"
[[ "$TRACE" == *"active state now belongs to incident 'vw-newer-incident'"* ]] \
    || fail "identity-change closure did not emit an actionable warning"
_send_notification() {
    (( SEND_COUNT += 1 )) || true
    CAPTURED_SUBJECT="$1"
    CAPTURED_BODY="$2"
    return 0
}

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
touch "$TMP/lock-target"
ln -s "$TMP/lock-target" "$TMP/recovery-delivery.lock"
if _notify_recovery; then
    fail "working recovery lock symlink must fail closed"
fi
(( SEND_COUNT == 0 )) || fail "working recovery lock symlink must not send email"

reset_fixture
write_valid_incident
ln -s "$TMP/missing-lock-target" "$TMP/recovery-delivery.lock"
if _notify_recovery; then
    fail "dangling recovery lock symlink must fail closed"
fi
(( SEND_COUNT == 0 )) || fail "dangling recovery lock symlink must not send email"

reset_fixture
write_valid_incident
mkdir -p "$TMP/recovery-delivery.lock"
if _notify_recovery; then
    fail "recovery lock directory must fail closed"
fi
(( SEND_COUNT == 0 )) || fail "recovery lock directory must not send email"

reset_fixture
write_valid_incident
: > "$TMP/recovery-delivery.lock"
chmod 0644 "$TMP/recovery-delivery.lock"
if _notify_recovery; then
    fail "wrong-mode recovery lock must fail closed"
fi
(( SEND_COUNT == 0 )) || fail "wrong-mode recovery lock must not send email"

reset_fixture
write_valid_incident
mkdir -p "$TMP/bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 64' > "$TMP/bin/flock"
chmod 0755 "$TMP/bin/flock"
if PATH="$TMP/bin:$PATH" _notify_recovery > "$TMP/flock-error.out" 2>&1; then
    fail "operational flock failure must return nonzero"
fi
(( SEND_COUNT == 0 )) || fail "operational flock failure must not send email"
[[ -e "$ACTIVE_INCIDENT_FILE" ]] || fail "operational flock failure moved the active incident"
[[ ! -e "$RECOVERY_DELIVERY_STATE_FILE" ]] || fail "operational flock failure wrote recovery delivery state"
[[ ! -e "$ALERT_LOCK_DIR/recovery.cooldown" ]] || fail "operational flock failure wrote recovery cooldown state"
[[ -z "${HEALTH_ALERT_STATE_LOCK_FD:-}" ]] || fail "operational flock failure leaked the opened descriptor"
[[ "$TRACE" == *"flock failed for '${TMP}/recovery-delivery.lock' with status 64"* ]] \
    || fail "operational flock failure was misreported as contention"

reset_fixture
ALERT_LOCK_DIR="$TMP/unsafe-alerts"
ACTIVE_INCIDENT_FILE="$ALERT_LOCK_DIR/active-incident.state"
RECOVERY_DELIVERY_STATE_FILE="$ALERT_LOCK_DIR/recovery-delivery.state"
mkdir -p "$ALERT_LOCK_DIR"
chmod 0770 "$ALERT_LOCK_DIR"
write_valid_incident
if _notify_recovery > "$TMP/unsafe-dir.out" 2>&1; then
    fail "group-writable alert-state directory must fail closed"
fi
(( SEND_COUNT == 0 )) || fail "unsafe alert-state directory must not send email"
[[ -e "$ACTIVE_INCIDENT_FILE" ]] || fail "unsafe alert-state directory test moved the incident"
[[ "$TRACE" == *"has unsafe mode"* ]] \
    || fail "unsafe alert-state directory did not emit remediation guidance"

if [[ -d "/proc/$$/fd" ]]; then
    reset_fixture
    write_valid_incident
    : > "$TMP/recovery-delivery.lock"
    chmod 0600 "$TMP/recovery-delivery.lock"
    mkdir -p "$TMP/bin"
    real_stat="$(command -v stat)"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        'last_arg="${!#}"' \
        'if [[ "${1:-}" == "-Lc" && "$last_arg" == "$LOCK_PATH" && ! -e "$SWAP_MARKER" ]]; then' \
        '    mv -- "$LOCK_PATH" "${LOCK_PATH}.opened"' \
        '    : > "$LOCK_PATH"' \
        '    chmod 0600 "$LOCK_PATH"' \
        '    : > "$SWAP_MARKER"' \
        'fi' \
        'exec "$REAL_STAT" "$@"' > "$TMP/bin/stat"
    chmod 0755 "$TMP/bin/stat"
    if REAL_STAT="$real_stat" LOCK_PATH="$TMP/recovery-delivery.lock" \
        SWAP_MARKER="$TMP/lock-swapped" PATH="$TMP/bin:$PATH" \
        _notify_recovery > "$TMP/lock-swap.out" 2>&1; then
        fail "lock path replacement between open and verification must fail closed"
    fi
    [[ -e "$TMP/lock-swapped" ]] || fail "lock identity replacement seam did not run"
    (( SEND_COUNT == 0 )) || fail "lock identity replacement must not send email"
    [[ -e "$ACTIVE_INCIDENT_FILE" && ! -e "$RECOVERY_DELIVERY_STATE_FILE" ]] \
        || fail "lock identity replacement mutated incident or delivery state"
    [[ -z "${HEALTH_ALERT_STATE_LOCK_FD:-}" ]] \
        || fail "lock identity replacement leaked the opened descriptor"
else
    printf 'SKIP: /proc descriptor identity replacement test requires the supported Linux runtime.\n'
fi

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
# shellcheck source=lib/health-alerts.sh
source "$ROOT/lib/health-alerts.sh"
ALERT_LOCK_DIR="$TMP/real"
ACTIVE_INCIDENT_FILE="$ALERT_LOCK_DIR/active-incident.state"
RECOVERY_DELIVERY_STATE_FILE="$ALERT_LOCK_DIR/recovery-delivery.state"
ALERT_RECOVERY_TTL=86400
ALERT_RECOVERY_PENDING_TTL=30
passed=27
warnings=0
failed=0
HEALTH_ALERT_STATE_LOCK_FD=""
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
chmod 0700 "$ALERT_LOCK_DIR"
printf 'not-an-epoch\n' > "$ALERT_LOCK_DIR/malformed.cooldown"
chmod 0600 "$ALERT_LOCK_DIR/malformed.cooldown"
malformed_before="$(cksum < "$ALERT_LOCK_DIR/malformed.cooldown")"
if _acquire_alert_lock malformed 30; then
    fail "malformed cooldown state must suppress instead of being overwritten"
fi
[[ "$(cksum < "$ALERT_LOCK_DIR/malformed.cooldown")" == "$malformed_before" ]] \
    || fail "malformed cooldown state was modified"

printf 'meta\tincident_id\tvw-invalid\nmeta\tstarted_at\t2026-07-20T01:00:00+00:00\ncheck\tcontainer\tpass\tbad\n' > "$ACTIVE_INCIDENT_FILE"
chmod 0600 "$ACTIVE_INCIDENT_FILE"
! _incident_load "$ACTIVE_INCIDENT_FILE" || fail "invalid persisted status must be rejected"

printf 'meta\tincident_id\tvw-dup\nmeta\tincident_id\tvw-dup-two\nmeta\tstarted_at\t2026-07-20T01:00:00+00:00\ncheck\tcontainer\tfail\tbad\n' > "$ACTIVE_INCIDENT_FILE"
chmod 0600 "$ACTIVE_INCIDENT_FILE"
! _incident_load "$ACTIVE_INCIDENT_FILE" || fail "duplicate incident id must be rejected"

printf 'meta\tincident_id\tvw-missing\ncheck\tcontainer\tfail\tbad\n' > "$ACTIVE_INCIDENT_FILE"
chmod 0600 "$ACTIVE_INCIDENT_FILE"
! _incident_load "$ACTIVE_INCIDENT_FILE" || fail "missing started_at must be rejected"

printf 'meta\tincident_id\tvw-missing-last\nmeta\tstarted_at\t2026-07-20T01:00:00+00:00\nmeta\thostname\tvaultwarden-test\ncheck\tcontainer\tfail\tbad\n' > "$ACTIVE_INCIDENT_FILE"
chmod 0600 "$ACTIVE_INCIDENT_FILE"
! _incident_load "$ACTIVE_INCIDENT_FILE" || fail "missing last_unhealthy_at must be rejected"

printf 'meta\tincident_id\tvw-missing-host\nmeta\tstarted_at\t2026-07-20T01:00:00+00:00\nmeta\tlast_unhealthy_at\t2026-07-20T01:05:00+00:00\ncheck\tcontainer\tfail\tbad\n' > "$ACTIVE_INCIDENT_FILE"
chmod 0600 "$ACTIVE_INCIDENT_FILE"
! _incident_load "$ACTIVE_INCIDENT_FILE" || fail "missing hostname must be rejected"

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

printf 'meta\tincident_id\tvw-ascii-only\nmeta\tstarted_at\t2026-07-20T01:00:00+00:00\nmeta\tlast_unhealthy_at\t2026-07-20T01:05:00+00:00\nmeta\thostname\tvaultwarden-test\ncheck\tcontainer\tfail\tbad\n' > "$ACTIVE_INCIDENT_FILE"
chmod 0600 "$ACTIVE_INCIDENT_FILE"
LC_ALL=C _incident_load "$ACTIVE_INCIDENT_FILE" || fail "ASCII incident id must load under LC_ALL=C"
printf 'meta\tincident_id\tvw-é\nmeta\tstarted_at\t2026-07-20T01:00:00+00:00\nmeta\tlast_unhealthy_at\t2026-07-20T01:05:00+00:00\nmeta\thostname\tvaultwarden-test\ncheck\tcontainer\tfail\tbad\n' > "$ACTIVE_INCIDENT_FILE"
chmod 0600 "$ACTIVE_INCIDENT_FILE"
! LC_ALL=C.UTF-8 _incident_load "$ACTIVE_INCIDENT_FILE" \
    || fail "non-ASCII incident id must be rejected regardless of locale"

printf 'meta\tincident_id\tvw-nul-inspection\nmeta\tstarted_at\t2026-07-20T01:00:00+00:00\nmeta\tlast_unhealthy_at\t2026-07-20T01:05:00+00:00\nmeta\thostname\tvaultwarden-test\ncheck\tcontainer\tfail\tbad\n' > "$ACTIVE_INCIDENT_FILE"
chmod 0600 "$ACTIVE_INCIDENT_FILE"
(
    _state_file_has_nul() { return 2; }
    ! _incident_load "$ACTIVE_INCIDENT_FILE" \
        || fail "incident parser treated NUL inspection failure as clean state"
)

printf 'v1\tpending\tvw-nul-inspection\t1\n' > "$RECOVERY_DELIVERY_STATE_FILE"
chmod 0600 "$RECOVERY_DELIVERY_STATE_FILE"
(
    _state_file_has_nul() { return 2; }
    ! _recovery_delivery_state_load \
        || fail "delivery parser treated NUL inspection failure as clean state"
)
rm -f -- "$RECOVERY_DELIVERY_STATE_FILE"

ACTIVE_INCIDENT_ID='vw-real-parser-recovery'
ACTIVE_INCIDENT_STARTED_AT='2026-07-20T01:00:00+00:00'
ACTIVE_INCIDENT_LAST_UNHEALTHY_AT='2026-07-20T01:05:00+00:00'
ACTIVE_INCIDENT_HOSTNAME='vaultwarden-test'
incident_check_order=('container:vaultwarden_app' 'backup:age')
incident_statuses['container:vaultwarden_app']='fail'
incident_details['container:vaultwarden_app']='Container was not running'
incident_statuses['backup:age']='warn'
incident_details['backup:age']='Latest backup was stale'
_health_alert_state_lock_acquire "$(_health_alert_state_lock_path)" bounded \
    || fail "real incident writer test could not acquire state lock"
_incident_write_locked || fail "real incident writer should succeed"
_health_alert_state_lock_release
_incident_reset_loaded_state
_incident_load "$ACTIVE_INCIDENT_FILE" || fail "real incident writer output must round-trip"

printf 'broken-cooldown\n' > "$ALERT_LOCK_DIR/recovery.cooldown"
chmod 0600 "$ALERT_LOCK_DIR/recovery.cooldown"
recovery_cooldown_before="$(cksum < "$ALERT_LOCK_DIR/recovery.cooldown")"
if _notify_recovery; then
    fail "malformed recovery cooldown must fail closed"
fi
[[ "$(cksum < "$ALERT_LOCK_DIR/recovery.cooldown")" == "$recovery_cooldown_before" ]] \
    || fail "malformed recovery cooldown was overwritten"
[[ -e "$ACTIVE_INCIDENT_FILE" && ! -e "$RECOVERY_DELIVERY_STATE_FILE" ]] \
    || fail "malformed recovery cooldown mutated incident or delivery state"
rm -f -- "$ALERT_LOCK_DIR/recovery.cooldown"

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

assert_file_size() {
    local path="$1" expected="$2" actual_size

    actual_size="$(LC_ALL=C wc -c < "$path" | tr -d '[:space:]')"
    [[ "$actual_size" == "$expected" ]] \
        || fail "$(basename "$path") is ${actual_size} bytes, expected ${expected}"
}

check_boundary_files_for_locale() {
    local locale_name="$1" label="$2"

    cp "$ascii_limit_file" "$ACTIVE_INCIDENT_FILE"
    LC_ALL="$locale_name" _incident_load "$ACTIVE_INCIDENT_FILE" \
        || fail "exactly-at-limit ASCII incident must load under ${label}"
    cp "$ascii_over_file" "$ACTIVE_INCIDENT_FILE"
    if LC_ALL="$locale_name" _incident_load "$ACTIVE_INCIDENT_FILE"; then
        fail "one-byte-over-limit ASCII incident must be rejected under ${label}"
    fi

    cp "$utf8_limit_file" "$ACTIVE_INCIDENT_FILE"
    LC_ALL="$locale_name" _incident_load "$ACTIVE_INCIDENT_FILE" \
        || fail "exactly-at-limit UTF-8 incident must load under ${label}"
    cp "$utf8_over_file" "$ACTIVE_INCIDENT_FILE"
    if LC_ALL="$locale_name" _incident_load "$ACTIVE_INCIDENT_FILE"; then
        fail "one-byte-over-limit UTF-8 incident must be rejected under ${label}"
    fi
}

ascii_limit_file="$TMP/ascii-limit-incident.state"
ascii_over_file="$TMP/ascii-over-incident.state"
utf8_limit_file="$TMP/utf8-limit-incident.state"
utf8_over_file="$TMP/utf8-over-incident.state"
build_incident_file_of_size "$ascii_limit_file" 'vw-size-limit' 16384 ascii
build_incident_file_of_size "$ascii_over_file" 'vw-size-over' 16385 ascii
build_incident_file_of_size "$utf8_limit_file" 'vw-utf8-limit' 16384 utf8
build_incident_file_of_size "$utf8_over_file" 'vw-utf8-over' 16385 utf8
assert_file_size "$ascii_limit_file" 16384
assert_file_size "$ascii_over_file" 16385
assert_file_size "$utf8_limit_file" 16384
assert_file_size "$utf8_over_file" 16385
LC_ALL=C grep -q "$(printf '\303\251')" "$utf8_limit_file" \
    || fail "UTF-8 boundary fixture does not contain a real multibyte sequence"
[[ "$(LC_ALL=C tail -c 1 "$ascii_limit_file" | od -An -tu1 | tr -d '[:space:]')" == "10" ]] \
    || fail "ASCII boundary fixture does not end in exactly one canonical newline"
[[ "$(LC_ALL=C tail -c 1 "$ascii_over_file" | od -An -tu1 | tr -d '[:space:]')" == "10" ]] \
    || fail "ASCII over-limit fixture does not end in exactly one canonical newline"
[[ "$(LC_ALL=C tail -c 1 "$utf8_limit_file" | od -An -tu1 | tr -d '[:space:]')" == "10" ]] \
    || fail "UTF-8 boundary fixture does not end in exactly one canonical newline"
[[ "$(LC_ALL=C tail -c 1 "$utf8_over_file" | od -An -tu1 | tr -d '[:space:]')" == "10" ]] \
    || fail "UTF-8 over-limit fixture does not end in exactly one canonical newline"

check_boundary_files_for_locale C 'LC_ALL=C'
if locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -qx 'c\.utf-8'; then
    check_boundary_files_for_locale C.UTF-8 'LC_ALL=C.UTF-8'
else
    printf 'SKIP: C.UTF-8 locale unavailable; UTF-8 locale boundary replay is covered by Ubuntu CI.\n'
fi

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
chmod 0700 "$TMP/alerts"
wait_for_nonempty_file() {
    local path="$1" attempts="$2" delay="$3" attempt

    for (( attempt = 1; attempt <= attempts; attempt++ )); do
        [[ -s "$path" ]] && return 0
        sleep "$delay"
    done
    printf 'FAIL: timed out waiting for nonempty file: %s\n' "$path" >&2
    [[ -e "$TMP/first.err" ]] && sed -n '1,120p' "$TMP/first.err" >&2
    [[ -e "$TMP/second.err" ]] && sed -n '1,120p' "$TMP/second.err" >&2
    return 1
}

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
# shellcheck source=lib/health-alerts.sh
source "$ROOT/lib/health-alerts.sh"
ALERT_LOCK_DIR="$TMP/alerts"
ACTIVE_INCIDENT_FILE="$ALERT_LOCK_DIR/active-incident.state"
RECOVERY_DELIVERY_STATE_FILE="$ALERT_LOCK_DIR/recovery-delivery.state"
ALERT_RECOVERY_TTL=86400
ALERT_RECOVERY_PENDING_TTL=30
failed=0
warnings=0
passed=1
HEALTH_ALERT_STATE_LOCK_FD=""
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

run_one 2> "$TMP/first.err" &
first_pid=$!
wait_for_nonempty_file "$TMP/entered-send" 500 0.01
run_one 2> "$TMP/second.err" &
second_pid=$!
wait "$second_pid" || { printf 'FAIL: concurrent losing worker failed\n' >&2; exit 1; }
printf 'release\n' > "$TMP/release-send"
wait "$first_pid" || { printf 'FAIL: concurrent winning worker failed\n' >&2; exit 1; }
[[ "$(wc -l < "$TMP/sends")" -eq 1 ]] || { printf 'FAIL: concurrent recovery attempts did not send exactly once\n' >&2; exit 1; }
[[ ! -e "$TMP/alerts/active-incident.state" ]] || { printf 'FAIL: concurrent recovery did not close the active incident\n' >&2; exit 1; }
printf 'PASS: concurrent health recovery attempts send once\n'
)

check_health_recovery_concurrency_contract

check_unhealthy_update_recovery_race_contract() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ALERT_LOCK_DIR="$TMP/alerts"
mkdir -p "$ALERT_LOCK_DIR"
chmod 0700 "$ALERT_LOCK_DIR"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    [[ -e "$TMP/recovery.err" ]] && sed -n '1,160p' "$TMP/recovery.err" >&2
    [[ -e "$TMP/unhealthy.err" ]] && sed -n '1,160p' "$TMP/unhealthy.err" >&2
    exit 1
}

wait_for_nonempty_file() {
    local path="$1" attempts="$2" delay="$3" attempt

    for (( attempt = 1; attempt <= attempts; attempt++ )); do
        [[ -s "$path" ]] && return 0
        sleep "$delay"
    done
    fail "timed out waiting for nonempty file: ${path}"
}

cat > "$ALERT_LOCK_DIR/active-incident.state" <<'INCIDENT'
meta	incident_id	vw-race-incident-a
meta	started_at	2026-07-20T01:00:00+00:00
meta	last_unhealthy_at	2026-07-20T01:05:00+00:00
meta	hostname	vaultwarden-test
check	container:vaultwarden_app	fail	Incident A failure
INCIDENT
chmod 0600 "$ALERT_LOCK_DIR/active-incident.state"
mkfifo "$TMP/release-send"
: > "$TMP/sends"

recovery_worker() (
    source "$ROOT/lib/health-alerts.sh"
    ALERT_LOCK_DIR="$TMP/alerts"
    ACTIVE_INCIDENT_FILE="$ALERT_LOCK_DIR/active-incident.state"
    RECOVERY_DELIVERY_STATE_FILE="$ALERT_LOCK_DIR/recovery-delivery.state"
    ALERT_RECOVERY_TTL=86400
    ALERT_RECOVERY_PENDING_TTL=30
    ALERT_STATE_LOCK_WAIT_SECONDS=5
    failed=0
    warnings=0
    passed=20
    HEALTH_ALERT_STATE_LOCK_FD=""
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
    log_debug() { :; }
    log_info() { printf '%s\n' "$*" >> "$TMP/recovery.info"; }
    log_warn() { printf '%s\n' "$*" >> "$TMP/recovery.warn"; }
    _send_notification() {
        printf 'vw-race-incident-a\n' >> "$TMP/sends"
        printf 'entered\n' > "$TMP/recovery-entered-send"
        read -r _ < "$TMP/release-send"
    }
    _notify_recovery
)

unhealthy_worker() (
    source "$ROOT/lib/health-alerts.sh"
    ALERT_LOCK_DIR="$TMP/alerts"
    ACTIVE_INCIDENT_FILE="$ALERT_LOCK_DIR/active-incident.state"
    RECOVERY_DELIVERY_STATE_FILE="$ALERT_LOCK_DIR/recovery-delivery.state"
    ALERT_STATE_LOCK_WAIT_SECONDS=5
    failed=1
    warnings=0
    passed=19
    HEALTH_ALERT_STATE_LOCK_FD=""
    ACTIVE_INCIDENT_AVAILABLE=false
    ACTIVE_INCIDENT_ID=""
    ACTIVE_INCIDENT_STARTED_AT=""
    ACTIVE_INCIDENT_LAST_UNHEALTHY_AT=""
    ACTIVE_INCIDENT_HOSTNAME=""
    declare -A check_results=(["container:vaultwarden_app"]="fail")
    declare -A check_messages=(["container:vaultwarden_app"]="Incident B failure")
    declare -a check_order=("container:vaultwarden_app")
    declare -A incident_statuses=()
    declare -A incident_details=()
    declare -a incident_check_order=()
    log_debug() { :; }
    log_info() { :; }
    log_warn() { printf '%s\n' "$*" >> "$TMP/unhealthy.warn"; }
    printf 'ready\n' > "$TMP/unhealthy-ready"
    _incident_update_unhealthy
)

recovery_worker 2> "$TMP/recovery.err" &
recovery_pid=$!
wait_for_nonempty_file "$TMP/recovery-entered-send" 500 0.01
unhealthy_worker 2> "$TMP/unhealthy.err" &
unhealthy_pid=$!
wait_for_nonempty_file "$TMP/unhealthy-ready" 500 0.01

grep -Fq $'meta\tincident_id\tvw-race-incident-a' "$ALERT_LOCK_DIR/active-incident.state" \
    || fail "unhealthy worker mutated active state while recovery held the transition lock"
[[ ! -e "$ALERT_LOCK_DIR/active-incident.state.recovered" ]] \
    || fail "incident evidence moved before recovery was released"

printf 'release\n' > "$TMP/release-send"
wait "$recovery_pid" || fail "recovery worker failed"
wait "$unhealthy_pid" || fail "bounded-wait unhealthy worker failed after recovery released the lock"

[[ "$(wc -l < "$TMP/sends" | tr -d '[:space:]')" == "1" ]] \
    || fail "race attempted more than one recovery email"
grep -Fq $'meta\tincident_id\tvw-' "$ALERT_LOCK_DIR/active-incident.state" \
    || fail "new unhealthy observation did not create a new active incident"
! grep -Fq $'meta\tincident_id\tvw-race-incident-a' "$ALERT_LOCK_DIR/active-incident.state" \
    || fail "new unhealthy observation reused closed incident A"
grep -Fq $'check\tcontainer:vaultwarden_app\tfail\tIncident B failure' "$ALERT_LOCK_DIR/active-incident.state" \
    || fail "incident B observation was not retained"
[[ ! -e "$ALERT_LOCK_DIR/active-incident.state.recovered" ]] \
    || fail "bounded recovered evidence incorrectly contains incident B"
[[ ! -e "$ALERT_LOCK_DIR/recovery-delivery.state" ]] \
    || fail "normal race completion retained a recovery delivery marker"

source "$ROOT/lib/health-alerts.sh"
HEALTH_ALERT_STATE_LOCK_FD=""
log_warn() { :; }
_health_alert_state_lock_acquire "$(_health_alert_state_lock_path)" nonblocking \
    || fail "state lock was not reusable after both race workers completed"
_health_alert_state_lock_release

active_before_timeout="$(cksum < "$ALERT_LOCK_DIR/active-incident.state")"
mkfifo "$TMP/release-timeout-holder"
(
    source "$ROOT/lib/health-alerts.sh"
    HEALTH_ALERT_STATE_LOCK_FD=""
    log_warn() { printf '%s\n' "$*" >> "$TMP/timeout-holder.warn"; }
    _health_alert_state_lock_acquire "$(_health_alert_state_lock_path)" nonblocking \
        || exit 1
    printf 'held\n' > "$TMP/timeout-lock-held"
    read -r _ < "$TMP/release-timeout-holder"
    _health_alert_state_lock_release
) 2> "$TMP/timeout-holder.err" &
timeout_holder_pid=$!
wait_for_nonempty_file "$TMP/timeout-lock-held" 500 0.01
(
    source "$ROOT/lib/health-alerts.sh"
    ALERT_STATE_LOCK_WAIT_SECONDS=0.05
    failed=1
    warnings=0
    passed=19
    HEALTH_ALERT_STATE_LOCK_FD=""
    ACTIVE_INCIDENT_AVAILABLE=false
    ACTIVE_INCIDENT_ID=""
    ACTIVE_INCIDENT_STARTED_AT=""
    ACTIVE_INCIDENT_LAST_UNHEALTHY_AT=""
    ACTIVE_INCIDENT_HOSTNAME=""
    declare -A check_results=(["container:vaultwarden_app"]="fail")
    declare -A check_messages=(["container:vaultwarden_app"]="Timed-out observation")
    declare -a check_order=("container:vaultwarden_app")
    declare -A incident_statuses=()
    declare -A incident_details=()
    declare -a incident_check_order=()
    log_debug() { :; }
    log_info() { :; }
    log_warn() { printf '%s\n' "$*" >> "$TMP/timeout-worker.warn"; }
    timeout_rc=0
    _incident_update_unhealthy || timeout_rc=$?
    printf '%s\n' "$timeout_rc" > "$TMP/timeout-worker.status"
) 2> "$TMP/timeout-worker.err" &
timeout_worker_pid=$!
wait_for_nonempty_file "$TMP/timeout-worker.status" 500 0.01
wait "$timeout_worker_pid" || fail "unhealthy timeout worker exited unexpectedly"
[[ "$(tr -d '[:space:]' < "$TMP/timeout-worker.status")" != "0" ]] \
    || fail "unhealthy update reported success after bounded lock timeout"
[[ "$(cksum < "$ALERT_LOCK_DIR/active-incident.state")" == "$active_before_timeout" ]] \
    || fail "unhealthy update mutated active state without owning the lock"
grep -Fq "timed out waiting" "$TMP/timeout-worker.warn" \
    || fail "bounded unhealthy lock timeout did not emit an actionable warning"
printf 'release\n' > "$TMP/release-timeout-holder"
wait "$timeout_holder_pid" || fail "timeout lock holder failed"

printf 'PASS: unhealthy update waits for recovery closure and preserves the new incident\n'
)

check_unhealthy_update_recovery_race_contract
)

check_health_locking_contracts() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
LOG_LIB="$ROOT/lib/log.sh"
HEALTH="$ROOT/utilities/maintenance-health.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

spinner_block="$(sed -n '/^spinner_start()/,/^spinner_stop()/p' "$LOG_LIB")"
for variable in \
    OPERATION_SPECIFIC_LOCK_FD \
    OPERATION_LOCK_FD \
    VW_OPERATION_INHERITED_FD; do
    if grep -Fq "$variable" "$LOG_LIB"; then
        fail "logging library must not know repository lock variable ${variable}"
    fi
done
grep -Fq 'local health_fd="${HEALTH_LOCK_FD:-}"' <<< "$spinner_block" \
    || fail "spinner must preserve health lock isolation"
grep -Fq 'eval "exec ${health_fd}>&-"' <<< "$spinner_block" \
    || fail "spinner child must close the health lock descriptor"

grep -Fq 'operation_acquire \' "$HEALTH" \
    || fail "health --fix must acquire the existing operation guard"
if grep -A5 -F 'operation_acquire \' "$HEALTH" | grep -Fq -- '--specific-lock'; then
    fail "health --fix must not delegate its health lock to the operation guard"
fi
grep -Fq 'if _acquire_health_lock; then' "$HEALTH" \
    || fail "every health invocation must acquire its own health lock first"
grep -Fq '(set -o noclobber; : >"$lock_path")' "$HEALTH" \
    || fail "health lock creation must not truncate an existing path"
grep -Fq 'if [[ "$owner_uid" != "$EUID" ]]' "$HEALTH" \
    || fail "health locking must reject files owned by another execution identity"
grep -Fq 'flock -n -E 75 "$fd"' "$HEALTH" \
    || fail "health lock acquisition must distinguish contention from flock failure"
grep -Fq '[[ -L "$lock_path" || ( -e "$lock_path" && ! -f "$lock_path" ) ]]' "$HEALTH" \
    || fail "health lock preparation must reject symlinks and non-regular targets"
grep -Fq "trap '_release_run_lock 130; exit 130' INT" "$HEALTH" \
    || fail "health INT cleanup must release locks and terminate"
grep -Fq "trap '_release_run_lock 143; exit 143' HUP TERM" "$HEALTH" \
    || fail "health HUP/TERM cleanup must release locks and terminate"

TMP="$(mktemp -d)"
cleanup() {
    [[ -n "${holder_pid:-}" ]] && kill "$holder_pid" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

HELPERS="$TMP/health-lock-helpers.bash"
{
    cat <<'EOF_HELPER'
HEALTH_LOCK_FD=""
HEALTH_OPERATION_GUARD_HELD=false
FIX_MODE=false
log_error() { printf 'ERROR %s\n' "$*" >&2; }
log_warn() { printf 'WARN %s\n' "$*" >&2; }
operation_acquire() { return 0; }
operation_set_phase() { return 0; }
operation_release() { return 0; }
EOF_HELPER
    sed -n '/^_health_lock_path()/,/^local ALERT_LOCK_DIR=/p' "$HEALTH" | sed '$d'
} > "$HELPERS"

LOCK="$TMP/health.lock"
READY="$TMP/holder.ready"
VW_HEALTH_LOCK_FILE="$LOCK" READY="$READY" bash -c '
    set -euo pipefail
    source "$1"
    _acquire_run_lock
    trap "_release_run_lock" EXIT
    trap "_release_run_lock 143; exit 143" TERM
    : > "$READY"
    while :; do sleep 1; done
' _ "$HELPERS" &
holder_pid=$!
for _ in {1..50}; do
    [[ -f "$READY" ]] && break
    sleep 0.1
done
[[ -f "$READY" ]] || fail "health lock holder did not start"

set +e
VW_HEALTH_LOCK_FILE="$LOCK" bash -c '
    set -euo pipefail
    source "$1"
    _acquire_run_lock
' _ "$HELPERS" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 75 ]] || fail "two health commands on one path must not overlap; got $rc"

kill -TERM "$holder_pid"
set +e
wait "$holder_pid"
rc=$?
set -e
holder_pid=""
[[ "$rc" -eq 143 ]] || fail "terminated health holder must preserve TERM status; got $rc"
VW_HEALTH_LOCK_FILE="$LOCK" bash -c '
    set -euo pipefail
    source "$1"
    _acquire_run_lock
    _release_run_lock 0
' _ "$HELPERS" || fail "health lock was not released after termination"

set +e
VW_HEALTH_LOCK_FILE="$TMP/fix-contention.lock" bash -c '
    set -euo pipefail
    source "$1"
    FIX_MODE=true
    operation_acquire() { return 75; }
    _acquire_run_lock
' _ "$HELPERS" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 75 ]] || fail "global mutation contention must remain exit 75; got $rc"
VW_HEALTH_LOCK_FILE="$TMP/fix-contention.lock" bash -c '
    set -euo pipefail
    source "$1"
    _acquire_health_lock
    _release_health_lock
' _ "$HELPERS" || fail "global contention did not release the health lock"

set +e
VW_HEALTH_LOCK_FILE="$TMP/fix-infra.lock" bash -c '
    set -euo pipefail
    source "$1"
    FIX_MODE=true
    operation_acquire() { return 64; }
    _acquire_run_lock
' _ "$HELPERS" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 4 ]] || fail "global guard infrastructure failure must remain exit 4; got $rc"
VW_HEALTH_LOCK_FILE="$TMP/fix-infra.lock" bash -c '
    set -euo pipefail
    source "$1"
    _acquire_health_lock
    _release_health_lock
' _ "$HELPERS" || fail "global infrastructure failure did not release the health lock"

mkdir -p "$TMP/foreign-owner"
real_stat="$(command -v stat)"
cat > "$TMP/foreign-owner/stat" <<EOF_STAT
#!/usr/bin/env bash
if [[ "\${1:-}" == "-c" && "\${2:-}" == "%u" ]]; then
    printf '%s\n' "$(( EUID + 1 ))"
    exit 0
fi
exec "$real_stat" "\$@"
EOF_STAT
chmod 0755 "$TMP/foreign-owner/stat"
: > "$TMP/foreign-owner.lock"
set +e
PATH="$TMP/foreign-owner:$PATH" VW_HEALTH_LOCK_FILE="$TMP/foreign-owner.lock" bash -c '
    set -euo pipefail
    source "$1"
    _acquire_run_lock
' _ "$HELPERS" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 3 ]] || fail "foreign-owned read-only health lock must be infrastructure exit 3; got $rc"
set +e
PATH="$TMP/foreign-owner:$PATH" VW_HEALTH_LOCK_FILE="$TMP/foreign-owner.lock" bash -c '
    set -euo pipefail
    source "$1"
    FIX_MODE=true
    _acquire_run_lock
' _ "$HELPERS" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 4 ]] || fail "foreign-owned health --fix lock must be infrastructure exit 4; got $rc"

mkdir -p "$TMP/bad-flock"
cat > "$TMP/bad-flock/flock" <<'EOF_FLOCK'
#!/usr/bin/env bash
exit 64
EOF_FLOCK
chmod 0755 "$TMP/bad-flock/flock"
set +e
PATH="$TMP/bad-flock:$PATH" VW_HEALTH_LOCK_FILE="$TMP/flock-infra.lock" bash -c '
    set -euo pipefail
    source "$1"
    _acquire_run_lock
' _ "$HELPERS" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 3 ]] || fail "read-only health flock infrastructure failure must remain exit 3; got $rc"

set +e
PATH="$TMP/bad-flock:$PATH" VW_HEALTH_LOCK_FILE="$TMP/fix-flock-infra.lock" bash -c '
    set -euo pipefail
    source "$1"
    FIX_MODE=true
    _acquire_run_lock
' _ "$HELPERS" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 4 ]] || fail "health --fix flock infrastructure failure must be exit 4; got $rc"

ln -s "$TMP/target" "$TMP/symlink.lock"
set +e
VW_HEALTH_LOCK_FILE="$TMP/symlink.lock" bash -c '
    set -euo pipefail
    source "$1"
    _acquire_health_lock
' _ "$HELPERS" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 3 ]] || fail "health lock symlink must fail as infrastructure; got $rc"

VW_HEALTH_LOCK_FILE="$TMP/normal-failure.lock" bash -c '
    set -euo pipefail
    source "$1"
    _acquire_run_lock
    _release_run_lock 2 || rc=$?
    [[ "${rc:-0}" -eq 2 ]]
' _ "$HELPERS" || fail "normal failure cleanup did not preserve status"
VW_HEALTH_LOCK_FILE="$TMP/normal-failure.lock" bash -c '
    set -euo pipefail
    source "$1"
    _acquire_health_lock
    _release_health_lock
' _ "$HELPERS" || fail "normal failure cleanup did not release the health lock"

printf 'Health locking and descriptor isolation tests passed.\n'
)

case "$MODE" in
    core) check_health_alerts_core ;;
    locking) check_health_locking_contracts ;;
    all)
        check_health_alerts_core
        check_health_locking_contracts
        ;;
esac
