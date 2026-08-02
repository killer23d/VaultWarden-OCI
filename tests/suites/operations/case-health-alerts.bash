#!/usr/bin/env bash
# Health alert state-transition regression tests.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR/../../..

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

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


check_health_run_lock_contracts() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
HEALTH="$ROOT/utilities/maintenance-health.sh"
TMP="$(mktemp -d -t vw-health-run-lock.XXXXXXXXXX)"

as_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        sudo -n -- "$@"
    fi
}

cleanup() {
    [[ -n "${capture_pid_one:-}" ]] && kill -KILL "$capture_pid_one" 2>/dev/null || true
    [[ -n "${capture_pid_two:-}" ]] && kill -KILL "$capture_pid_two" 2>/dev/null || true
    [[ -n "${capture_signal_helper_pid:-}" ]] && kill -KILL "$capture_signal_helper_pid" 2>/dev/null || true
    [[ -n "${signal_pid:-}" ]] && kill -KILL "$signal_pid" 2>/dev/null || true
    [[ -n "${mutator_pid:-}" ]] && kill -KILL "$mutator_pid" 2>/dev/null || true
    rm -rf -- "$TMP"
}
trap cleanup EXIT

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }
log_error(){ printf 'error:%s\n' "$*" >> "$TMP/log"; }
log_warn(){ printf 'warn:%s\n' "$*" >> "$TMP/log"; }
log_info(){ :; }
wait_for_file() {
    local path="$1" attempt
    for (( attempt = 0; attempt < 300; attempt++ )); do
        [[ -e "$path" ]] && return 0
        sleep 0.02
    done
    fail "timed out waiting for $path"
}
lock_metadata() {
    _health_stat_mode_uid_gid_nlink "$1"
}

HAS_ROOT=true
if (( EUID != 0 )); then
    if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; then
        HAS_ROOT=false
    fi
fi

LOCK_BLOCK="$TMP/health-lock-block.bash"
awk '
    /^local HEALTH_LOCK_FD=""$/ {copy=1}
    copy && /^local ALERT_LOCK_DIR=/ {exit}
    copy {print}
' "$HEALTH" > "$LOCK_BLOCK"
[[ -s "$LOCK_BLOCK" ]] || fail "could not extract health run-lock block"

FIX_MODE=false
# shellcheck disable=SC1090
source "$LOCK_BLOCK"

explicit_dir="$TMP/explicit"
mkdir -m 0700 "$explicit_dir"
VW_HEALTH_LOCK_FILE="$explicit_dir/custom-health.lock"
[[ "$(_health_readonly_lock_path)" == "$VW_HEALTH_LOCK_FILE" ]] \
    || fail "VW_HEALTH_LOCK_FILE override was not preserved"
unset VW_HEALTH_LOCK_FILE

if (( EUID != 0 )); then
    xdg_dir="$TMP/xdg-runtime"
    fallback_dir="$TMP/fallback"
    mkdir -m 0700 "$xdg_dir" "$fallback_dir"
    # Consumed by the dynamically sourced lock-path resolver.
    # shellcheck disable=SC2034
    XDG_RUNTIME_DIR="$xdg_dir"
    TMPDIR="$fallback_dir"
    [[ "$(_health_readonly_lock_path)" == "$xdg_dir/vaultwarden-health.lock" ]] \
        || fail "non-root XDG runtime lock path changed"
    unset XDG_RUNTIME_DIR
    [[ "$(_health_readonly_lock_path)" == "$fallback_dir/vaultwarden-health-${EUID}.lock" ]] \
        || fail "non-root TMP fallback lock path changed"
    unset TMPDIR
else
    printf 'SKIP: XDG/TMP path resolution requires a non-root runner.\n'
fi

if [[ "$HAS_ROOT" == true ]]; then
    root_default="$(as_root env LOCK_BLOCK="$LOCK_BLOCK" "$BASH" -c '
        run() {
            local FIX_MODE=false
            log_error(){ :; }
            log_warn(){ :; }
            log_info(){ :; }
            unset VW_HEALTH_LOCK_FILE XDG_RUNTIME_DIR TMPDIR
            source "$LOCK_BLOCK"
            _health_readonly_lock_path
        }
        run
    ')"
    [[ "$root_default" == /run/lock/vaultwarden-health.lock ]] \
        || fail "root health lock path changed to $root_default"
else
    printf 'SKIP: root path resolution requires root or passwordless sudo.\n'
fi
pass "health lock resolution preserves override, root, XDG, and TMP contracts"

lock_dir="$TMP/locks"
mkdir -m 0700 "$lock_dir"
lock_path="$lock_dir/health.lock"
VW_HEALTH_LOCK_FILE="$lock_path"
_acquire_readonly_health_lock || fail "initial regular-file health acquisition failed"
[[ -f "$lock_path" && ! -L "$lock_path" ]] \
    || fail "health coordination target is not a regular non-symlink file"
IFS=: read -r mode owner _group links <<< "$(lock_metadata "$lock_path")"
[[ "$mode" == 600 && "$owner" == "$EUID" && "$links" == 1 ]] \
    || fail "health lock metadata was ${mode}:${owner}:${links}, expected 600:${EUID}:1"
first_identity="$(_health_path_identity "$lock_path")"
[[ -n "$HEALTH_LOCK_FD" ]] || fail "health coordination did not retain its descriptor"
_release_readonly_health_lock || fail "initial health coordination release failed"
_acquire_readonly_health_lock || fail "second regular-file health acquisition failed"
[[ "$(_health_path_identity "$lock_path")" == "$first_identity" ]] \
    || fail "health coordination replaced the existing lock inode"
_release_readonly_health_lock || fail "second health coordination release failed"
pass "health coordination uses one restrictive regular file without replacing its inode"

normalizable="$lock_dir/normalizable.lock"
: > "$normalizable"
chmod 0644 "$normalizable"
normalizable_identity="$(_health_path_identity "$normalizable")"
VW_HEALTH_LOCK_FILE="$normalizable"
_acquire_readonly_health_lock || fail "existing current-user lock could not be normalized"
IFS=: read -r mode owner _group links <<< "$(lock_metadata "$normalizable")"
[[ "$mode" == 600 && "$owner" == "$EUID" && "$links" == 1 \
    && "$(_health_path_identity "$normalizable")" == "$normalizable_identity" ]] \
    || fail "existing health lock metadata/inode normalization was not in-place"
_release_readonly_health_lock || fail "normalized health lock release failed"
pass "existing regular lock metadata is restricted without unlinking the inode"

hardlink_lock="$lock_dir/hardlink.lock"
: > "$hardlink_lock"
chmod 0600 "$hardlink_lock"
ln -- "$hardlink_lock" "$lock_dir/hardlink-alias"
VW_HEALTH_LOCK_FILE="$hardlink_lock"
set +e
_acquire_readonly_health_lock
rc=$?
set -e
[[ "$rc" -eq 3 && -z "$HEALTH_LOCK_FD" ]] \
    || fail "multi-link health lock returned $rc or leaked a descriptor"
rm -f -- "$lock_dir/hardlink-alias" "$hardlink_lock"
pass "health coordination rejects multiply linked regular files"

attacker_dir="$TMP/attacker-dir"
attacker_file="$TMP/attacker-file"
mkdir -m 0700 "$attacker_dir"
: > "$attacker_file"
chmod 0600 "$attacker_file"

for kind in symlink-file symlink-dir directory fifo device; do
    target="$lock_dir/unsafe-$kind"
    case "$kind" in
        symlink-file) ln -s -- "$attacker_file" "$target" ;;
        symlink-dir) ln -s -- "$attacker_dir" "$target" ;;
        directory) mkdir -m 0700 "$target" ;;
        fifo) mkfifo "$target" ;;
        device) target=/dev/null ;;
    esac
    VW_HEALTH_LOCK_FILE="$target"
    set +e
    _acquire_readonly_health_lock
    rc=$?
    set -e
    [[ "$rc" -eq 3 && -z "$HEALTH_LOCK_FD" ]] \
        || fail "$kind health target returned $rc or leaked a descriptor"
done
[[ -z "$(find "$attacker_dir" -mindepth 1 -print -quit)" ]] \
    || fail "rejected symlink-to-directory target received state"
pass "health coordination rejects symlinks and every tested non-regular target"

race_lock="$lock_dir/race.lock"
mkdir -p "$TMP/mockbin"
cat > "$TMP/mockbin/mv" <<'EOF_MV'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MV_TRACE"
destination="${@: -1}"
if [[ "$destination" == "$RACE_LOCK" && ! -e "$RACE_MARKER" ]]; then
    /usr/bin/ln -s -- "$ATTACKER_DIR" "$destination"
    : > "$RACE_MARKER"
fi
exec /usr/bin/mv "$@"
EOF_MV
chmod 0755 "$TMP/mockbin/mv"
set +e
PATH="$TMP/mockbin:$PATH" MV_TRACE="$TMP/mv-trace" RACE_LOCK="$race_lock" \
    RACE_MARKER="$TMP/race-marker" ATTACKER_DIR="$attacker_dir" \
    VW_HEALTH_LOCK_FILE="$race_lock" _acquire_readonly_health_lock
race_rc=$?
set -e
[[ "$race_rc" -eq 3 && -L "$race_lock" && -e "$TMP/race-marker" \
    && -z "$HEALTH_LOCK_FD" ]] \
    || fail "destination symlink creation race was not rejected safely"
grep -Eq -- '(^| )-T( |$)' "$TMP/mv-trace" \
    || fail "health lock publication did not use no-target-directory semantics"
grep -Eq -- '(^| )-n( |$)' "$TMP/mv-trace" \
    || fail "health lock publication did not use no-clobber semantics"
[[ -z "$(find "$attacker_dir" -mindepth 1 -print -quit)" ]] \
    || fail "creation race placed an inode beneath the attacker-controlled directory"
rm -f -- "$race_lock"
pass "atomic health lock publication never follows a raced symlink-to-directory"

unsafe_parent="$TMP/unsafe-parent"
mkdir -m 0777 "$unsafe_parent"
VW_HEALTH_LOCK_FILE="$unsafe_parent/health.lock"
set +e
_acquire_readonly_health_lock
rc=$?
set -e
[[ "$rc" -eq 3 && ! -e "$unsafe_parent/health.lock" && -z "$HEALTH_LOCK_FD" ]] \
    || fail "health coordination accepted a writable current-user ancestor"
pass "health coordination validates the complete lock-directory ancestry"

if [[ -d "/proc/$$/fd" ]]; then
    replacement_lock="$lock_dir/replacement.lock"
    : > "$replacement_lock"
    chmod 0600 "$replacement_lock"
    original_identity_definition="$(declare -f _health_path_identity)"
    _health_path_identity_real() {
        local target="$1"
        stat -Lc '%d:%i' -- "$target" 2>/dev/null \
            || stat -f '%d:%i' -- "$target" 2>/dev/null
    }
    _health_path_identity() {
        local target="$1" identity
        identity="$(_health_path_identity_real "$target")" || return 1
        if [[ "$target" == /proc/*/fd/* && ! -e "$TMP/swap-done" ]]; then
            mv -- "$replacement_lock" "${replacement_lock}.opened"
            : > "$replacement_lock"
            chmod 0600 -- "$replacement_lock"
            : > "$TMP/swap-done"
        fi
        printf '%s\n' "$identity"
    }
    VW_HEALTH_LOCK_FILE="$replacement_lock"
    set +e
    _acquire_readonly_health_lock
    rc=$?
    set -e
    eval "$original_identity_definition"
    unset -f _health_path_identity_real
    [[ "$rc" -eq 3 && -e "$TMP/swap-done" && -z "$HEALTH_LOCK_FD" ]] \
        || fail "health lock replacement was not detected safely"
    pass "health coordination verifies the opened descriptor against the intended regular file"
else
    printf 'SKIP: descriptor replacement test requires /proc.\n'
fi

if [[ -d "/proc/$$/fd" ]]; then
    capture_lock="$lock_dir/capture-race.lock"
    : > "$capture_lock"
    chmod 0600 "$capture_lock"
    capture_bin="$TMP/capture-bin"
    capture_ready="$TMP/capture-ready"
    capture_release="$TMP/capture-release"
    capture_holder_release="$TMP/capture-holder-release"
    mkdir -p "$capture_bin" "$capture_ready"
    cat > "$capture_bin/chmod" <<'EOF_CAPTURE_CHMOD'
#!/usr/bin/env bash
set -euo pipefail
last_arg="${!#}"
if [[ "$last_arg" == /proc/*/fd/* ]]; then
    : > "$CAPTURE_READY_DIR/$CAPTURE_WORKER_ID"
    while [[ ! -e "$CAPTURE_RELEASE_FILE" ]]; do sleep 0.01; done
fi
exec /usr/bin/chmod "$@"
EOF_CAPTURE_CHMOD
    chmod 0755 "$capture_bin/chmod"
    capture_worker="$TMP/capture-worker.bash"
    cat > "$capture_worker" <<'EOF_CAPTURE_WORKER'
#!/usr/bin/env bash
set -euo pipefail
run() {
    local FIX_MODE=false
    log_error(){ :; }
    log_warn(){ :; }
    log_info(){ :; }
    source "$LOCK_BLOCK"
    set +e
    _acquire_readonly_health_lock
    rc=$?
    set -e
    printf '%s\n' "$rc" > "$CAPTURE_STATUS_FILE"
    if (( rc == 0 )); then
        while [[ ! -e "$CAPTURE_HOLDER_RELEASE_FILE" ]]; do sleep 0.01; done
        _release_readonly_health_lock
    fi
}
run
EOF_CAPTURE_WORKER
    chmod 0755 "$capture_worker"

    PATH="$capture_bin:$PATH" LOCK_BLOCK="$LOCK_BLOCK" VW_HEALTH_LOCK_FILE="$capture_lock" \
        CAPTURE_READY_DIR="$capture_ready" CAPTURE_RELEASE_FILE="$capture_release" \
        CAPTURE_HOLDER_RELEASE_FILE="$capture_holder_release" CAPTURE_WORKER_ID=one \
        CAPTURE_STATUS_FILE="$TMP/capture-one.status" "$BASH" "$capture_worker" &
    capture_pid_one=$!
    PATH="$capture_bin:$PATH" LOCK_BLOCK="$LOCK_BLOCK" VW_HEALTH_LOCK_FILE="$capture_lock" \
        CAPTURE_READY_DIR="$capture_ready" CAPTURE_RELEASE_FILE="$capture_release" \
        CAPTURE_HOLDER_RELEASE_FILE="$capture_holder_release" CAPTURE_WORKER_ID=two \
        CAPTURE_STATUS_FILE="$TMP/capture-two.status" "$BASH" "$capture_worker" &
    capture_pid_two=$!
    wait_for_file "$capture_ready/one"
    wait_for_file "$capture_ready/two"
    : > "$capture_release"
    wait_for_file "$TMP/capture-one.status"
    wait_for_file "$TMP/capture-two.status"
    mapfile -t capture_statuses < <(
        printf '%s\n' "$(cat "$TMP/capture-one.status")" "$(cat "$TMP/capture-two.status")" | sort -n
    )
    [[ "${capture_statuses[*]}" == "0 75" ]] \
        || fail "simultaneous pre-flock openers returned '${capture_statuses[*]}' instead of one success and one contention"
    : > "$capture_holder_release"
    wait "$capture_pid_one" || fail "first capture-race worker failed"
    wait "$capture_pid_two" || fail "second capture-race worker failed"
    capture_pid_one=""
    capture_pid_two=""
    IFS=: read -r mode owner _group links <<< "$(lock_metadata "$capture_lock")"
    [[ "$mode" == 600 && "$owner" == "$EUID" && "$links" == 1 ]] \
        || fail "capture-race lock metadata was ${mode}:${owner}:${links} after both workers"
    VW_HEALTH_LOCK_FILE="$capture_lock"
    _acquire_readonly_health_lock || fail "health lock was not reusable after simultaneous pre-flock preparation"
    _release_readonly_health_lock || fail "post-capture-race release failed"
    pass "simultaneous pre-flock preparation yields one success and one exit 75"

    capture_signal_bin="$TMP/capture-signal-bin"
    mkdir -p "$capture_signal_bin"
    cat > "$capture_signal_bin/chmod" <<'EOF_SIGNAL_CHMOD'
#!/usr/bin/env bash
set -euo pipefail
last_arg="${!#}"
if [[ "$last_arg" == /proc/*/fd/* ]]; then
    : > "$CAPTURE_READY_FILE"
    while [[ ! -e "$CAPTURE_RELEASE_FILE" ]]; do sleep 0.01; done
fi
exec /usr/bin/chmod "$@"
EOF_SIGNAL_CHMOD
    chmod 0755 "$capture_signal_bin/chmod"
    capture_signal_worker="$TMP/capture-signal-worker.bash"
    cat > "$capture_signal_worker" <<'EOF_SIGNAL_WORKER'
#!/usr/bin/env bash
set -euo pipefail
run() {
    local FIX_MODE=false
    log_error(){ :; }
    log_warn(){ :; }
    log_info(){ :; }
    operation_acquire(){ return 0; }
    operation_set_phase(){ return 0; }
    operation_release(){ return 0; }
    source "$LOCK_BLOCK"
    trap '_health_exit_cleanup' EXIT
    trap '_health_signal_cleanup 129' HUP
    trap '_health_signal_cleanup 130' INT
    trap '_health_signal_cleanup 143' TERM
    printf '%s\n' "$$" > "$CAPTURE_PID_FILE"
    _acquire_readonly_health_lock
    exit 98
}
run
EOF_SIGNAL_WORKER
    chmod 0755 "$capture_signal_worker"

    for capture_signal_spec in HUP:129 INT:130 TERM:143; do
        capture_signal_name="${capture_signal_spec%%:*}"
        capture_expected_rc="${capture_signal_spec##*:}"
        capture_signal_lock="$lock_dir/capture-${capture_signal_name,,}.lock"
        capture_ready_file="$TMP/capture-${capture_signal_name}.ready"
        capture_release_file="$TMP/capture-${capture_signal_name}.release"
        capture_pid_file="$TMP/capture-${capture_signal_name}.pid"
        : > "$capture_signal_lock"
        chmod 0600 "$capture_signal_lock"
        (
            wait_for_file "$capture_ready_file"
            wait_for_file "$capture_pid_file"
            kill -s "$capture_signal_name" "$(cat "$capture_pid_file")"
            : > "$capture_release_file"
        ) &
        capture_signal_helper_pid=$!
        set +e
        PATH="$capture_signal_bin:$PATH" LOCK_BLOCK="$LOCK_BLOCK" \
            VW_HEALTH_LOCK_FILE="$capture_signal_lock" \
            CAPTURE_READY_FILE="$capture_ready_file" CAPTURE_RELEASE_FILE="$capture_release_file" \
            CAPTURE_PID_FILE="$capture_pid_file" "$BASH" "$capture_signal_worker"
        capture_signal_rc=$?
        set -e
        wait "$capture_signal_helper_pid" || fail "$capture_signal_name capture helper failed"
        capture_signal_helper_pid=""
        [[ "$capture_signal_rc" -eq "$capture_expected_rc" ]] \
            || fail "$capture_signal_name during capture returned $capture_signal_rc instead of $capture_expected_rc"
        IFS=: read -r mode owner _group links <<< "$(lock_metadata "$capture_signal_lock")"
        [[ "$mode" == 600 && "$owner" == "$EUID" && "$links" == 1 ]] \
            || fail "$capture_signal_name left capture lock metadata ${mode}:${owner}:${links}"
        HEALTH_LOCK_FD=""
        HEALTH_OPENED_LOCK_FD=""
        FIX_MODE=false
        VW_HEALTH_LOCK_FILE="$capture_signal_lock"
        _acquire_readonly_health_lock \
            || fail "health lock was not reusable after $capture_signal_name during capture"
        _release_readonly_health_lock || fail "post-$capture_signal_name capture release failed"
    done
    pass "HUP, INT, and TERM during capture leave the health lock reusable"

    capture_kill_lock="$lock_dir/capture-kill.lock"
    capture_kill_ready="$TMP/capture-KILL.ready"
    capture_kill_release="$TMP/capture-KILL.release"
    capture_kill_pid_file="$TMP/capture-KILL.pid"
    : > "$capture_kill_lock"
    chmod 0600 "$capture_kill_lock"
    (
        wait_for_file "$capture_kill_ready"
        wait_for_file "$capture_kill_pid_file"
        kill -KILL "$(cat "$capture_kill_pid_file")"
        : > "$capture_kill_release"
    ) &
    capture_signal_helper_pid=$!
    set +e
    PATH="$capture_signal_bin:$PATH" LOCK_BLOCK="$LOCK_BLOCK" \
        VW_HEALTH_LOCK_FILE="$capture_kill_lock" \
        CAPTURE_READY_FILE="$capture_kill_ready" CAPTURE_RELEASE_FILE="$capture_kill_release" \
        CAPTURE_PID_FILE="$capture_kill_pid_file" "$BASH" "$capture_signal_worker"
    capture_kill_rc=$?
    set -e
    wait "$capture_signal_helper_pid" || fail "KILL capture helper failed"
    capture_signal_helper_pid=""
    [[ "$capture_kill_rc" -eq 137 ]] \
        || fail "KILL during capture returned $capture_kill_rc instead of 137"
    IFS=: read -r mode owner _group links <<< "$(lock_metadata "$capture_kill_lock")"
    [[ "$mode" == 600 && "$owner" == "$EUID" && "$links" == 1 ]] \
        || fail "KILL left capture lock metadata ${mode}:${owner}:${links}"
    HEALTH_LOCK_FD=""
    HEALTH_OPENED_LOCK_FD=""
    FIX_MODE=false
    VW_HEALTH_LOCK_FILE="$capture_kill_lock"
    _acquire_readonly_health_lock || fail "health lock was not reusable after abrupt capture death"
    _release_readonly_health_lock || fail "post-KILL capture release failed"
    pass "abrupt process death during capture cannot poison the public lock inode"
else
    printf 'SKIP: pre-flock capture regressions require the supported Linux /proc runtime.\n'
fi

TRACE=""
OP_ACQUIRE_RC=0
operation_acquire() {
    [[ -n "$HEALTH_LOCK_FD" ]] || fail "global guard was attempted before health coordination"
    local arg
    for arg in "$@"; do
        [[ "$arg" != --specific-lock ]] || fail "health lock was passed as an operation-specific lock"
    done
    TRACE+=$'health-before-global\n'
    return "$OP_ACQUIRE_RC"
}
operation_set_phase(){ TRACE+=$'phase\n'; return 0; }
operation_release(){ TRACE+="operation-release:$1"$'\n'; return 0; }

fix_lock="$lock_dir/fix.lock"
FIX_MODE=true
VW_HEALTH_LOCK_FILE="$fix_lock"
_acquire_run_lock || fail "health repair run-lock acquisition failed"
[[ "$TRACE" == $'health-before-global\nphase\n' ]] \
    || fail "health repair acquisition sequence was $TRACE"
[[ "$HEALTH_OPERATION_GUARD_ACQUIRED" == true && -n "$HEALTH_LOCK_FD" ]] \
    || fail "health repair did not retain both resources"
_release_run_lock 0 || fail "health repair release failed"
[[ "$TRACE" == *"operation-release:0"* && -z "$HEALTH_LOCK_FD" ]] \
    || fail "health repair did not release both resources"
pass "health repair acquires its resolved regular-file lock before the global guard"

for guarded_rc in 75 64; do
    TRACE=""
    OP_ACQUIRE_RC="$guarded_rc"
    guard_lock="$lock_dir/guard-$guarded_rc.lock"
    VW_HEALTH_LOCK_FILE="$guard_lock"
    set +e
    _acquire_run_lock
    rc=$?
    set -e
    expected=4
    (( guarded_rc == 75 )) && expected=75
    [[ "$rc" -eq "$expected" && -z "$HEALTH_LOCK_FD" \
        && "$HEALTH_OPERATION_GUARD_ACQUIRED" == false ]] \
        || fail "global result $guarded_rc became rc=$rc or retained health coordination"
done
pass "global contention stays 75 while infrastructure failure stays non-75"
OP_ACQUIRE_RC=0

FIX_MODE=false
overlap_lock="$lock_dir/overlap.lock"
VW_HEALTH_LOCK_FILE="$overlap_lock"
_acquire_run_lock || fail "parent read-only health acquisition failed"
probe_health() {
    local mode="$1" marker="$2"
    FIX_MODE="$mode"
    HEALTH_LOCK_FD=""
    # Consumed by the dynamically sourced lock-open helper.
    # shellcheck disable=SC2034
    HEALTH_OPENED_LOCK_FD=""
    HEALTH_OPERATION_GUARD_ACQUIRED=false
    operation_acquire(){ : > "$marker"; return 0; }
    operation_set_phase(){ return 0; }
    operation_release(){ return 0; }
    _acquire_run_lock
}
set +e
(probe_health false "$TMP/readonly-global-called")
readonly_rc=$?
(probe_health true "$TMP/repair-global-called")
repair_rc=$?
set -e
[[ "$readonly_rc" -eq 75 && "$repair_rc" -eq 75 ]] \
    || fail "read-only holder did not exclude same-path duplicate/repair runs"
[[ ! -e "$TMP/readonly-global-called" && ! -e "$TMP/repair-global-called" ]] \
    || fail "repair attempted the global guard before health contention cleared"
_release_run_lock 0 || fail "parent read-only health release failed"

FIX_MODE=true
TRACE=""
VW_HEALTH_LOCK_FILE="$overlap_lock"
_acquire_run_lock || fail "parent health repair acquisition failed"
set +e
(probe_health false "$TMP/fix-readonly-global-called")
fix_readonly_rc=$?
(probe_health true "$TMP/fix-repair-global-called")
fix_repair_rc=$?
set -e
[[ "$fix_readonly_rc" -eq 75 && "$fix_repair_rc" -eq 75 ]] \
    || fail "repair holder did not exclude same-path read-only/second repair runs"
_release_run_lock 0 || fail "parent repair release failed"
pass "same resolved health path serializes every read and repair combination"

real_lock="$lock_dir/real-global.lock"
real_ops_state="$TMP/real-operations-state"
real_ops_lock="$TMP/real-operations.lock"
mutator_ready="$TMP/mutator-ready"
mutator_release="$TMP/mutator-release"
mkfifo "$mutator_release"
mutator_holder="$TMP/mutator-holder.bash"
cat > "$mutator_holder" <<'EOF_MUTATOR'
#!/usr/bin/env bash
set -euo pipefail
source "$ROOT/lib/operations.sh"
operation_acquire --id competing-mutator --label "Competing mutator" --non-interactive skip
: > "$READY_FILE"
read -r _ < "$RELEASE_FIFO"
operation_release 0
EOF_MUTATOR
chmod 0755 "$mutator_holder"
ROOT="$ROOT" VW_OPERATIONS_STATE_DIR="$real_ops_state" VW_OPERATIONS_LOCK="$real_ops_lock" \
    READY_FILE="$mutator_ready" RELEASE_FIFO="$mutator_release" \
    "$BASH" "$mutator_holder" >"$TMP/mutator.out" 2>"$TMP/mutator.err" &
mutator_pid=$!
wait_for_file "$mutator_ready"

real_probe="$TMP/real-health-repair-probe.bash"
cat > "$real_probe" <<'EOF_REAL_PROBE'
#!/usr/bin/env bash
set -euo pipefail
source "$ROOT/lib/operations.sh"
run() {
    local FIX_MODE=true
    log_error(){ :; }
    log_warn(){ :; }
    log_info(){ :; }
    source "$LOCK_BLOCK"
    set +e
    _acquire_run_lock
    rc=$?
    set -e
    [[ -z "$HEALTH_LOCK_FD" && "$HEALTH_OPERATION_GUARD_ACQUIRED" == false ]] || exit 97
    exit "$rc"
}
run
EOF_REAL_PROBE
chmod 0755 "$real_probe"
set +e
ROOT="$ROOT" LOCK_BLOCK="$LOCK_BLOCK" VW_HEALTH_LOCK_FILE="$real_lock" \
    VW_OPERATIONS_STATE_DIR="$real_ops_state" VW_OPERATIONS_LOCK="$real_ops_lock" \
    "$BASH" "$real_probe" >"$TMP/real-probe.out" 2>"$TMP/real-probe.err"
real_probe_rc=$?
set -e
[[ "$real_probe_rc" -eq 75 ]] \
    || fail "real global mutator contention returned $real_probe_rc instead of 75"
FIX_MODE=false
VW_HEALTH_LOCK_FILE="$real_lock"
HEALTH_LOCK_FD=""
# Consumed by the dynamically sourced lock-open helper.
# shellcheck disable=SC2034
HEALTH_OPENED_LOCK_FD=""
HEALTH_OPERATION_GUARD_ACQUIRED=false
_acquire_run_lock || fail "health coordination was not released after real global contention"
_release_run_lock 0 || fail "post-global-contention health release failed"
printf 'release\n' > "$mutator_release"
wait "$mutator_pid" || fail "real mutator holder failed"
mutator_pid=""
pass "a real global mutator blocks health repair without retaining its health lock"

FIX_MODE=false
parent_lock="$lock_dir/parent-descriptor.lock"
subshell_lock="$lock_dir/subshell-descriptor.lock"
VW_HEALTH_LOCK_FILE="$parent_lock"
_acquire_run_lock || fail "parent descriptor-reuse setup failed"
parent_health_fd="$HEALTH_LOCK_FD"
(
    eval "exec ${parent_health_fd}>&-"
    HEALTH_LOCK_FD=""
    # Consumed by the dynamically sourced lock-open helper.
    # shellcheck disable=SC2034
    HEALTH_OPENED_LOCK_FD=""
    VW_HEALTH_LOCK_FILE="$subshell_lock"
    _acquire_readonly_health_lock || fail "subshell health acquisition failed after descriptor reuse"
    [[ "$HEALTH_LOCK_FD" == "$parent_health_fd" ]] \
        || fail "subshell did not reuse expected descriptor $parent_health_fd"
    _release_readonly_health_lock || fail "subshell descriptor-reuse release failed"
)
_release_run_lock 0 || fail "parent descriptor-reuse release failed"
pass "health descriptor validation follows the current subshell owner"

signal_lock="$lock_dir/signal.lock"
SIGNAL_SCRIPT="$TMP/signal-holder.bash"
cat > "$SIGNAL_SCRIPT" <<'EOF_SIGNAL'
#!/usr/bin/env bash
set -euo pipefail
run() {
    local FIX_MODE=false
    log_error(){ :; }
    log_warn(){ :; }
    log_info(){ :; }
    operation_acquire(){ return 0; }
    operation_set_phase(){ return 0; }
    operation_release(){ return 0; }
    source "$LOCK_BLOCK"
    trap '_health_exit_cleanup' EXIT
    trap '_health_signal_cleanup 129' HUP
    trap '_health_signal_cleanup 130' INT
    trap '_health_signal_cleanup 143' TERM
    _acquire_run_lock
    : > "$READY_FILE"
    while :; do sleep 1; done
}
run
EOF_SIGNAL
chmod 0755 "$SIGNAL_SCRIPT"
LOCK_BLOCK="$LOCK_BLOCK" VW_HEALTH_LOCK_FILE="$signal_lock" \
    READY_FILE="$TMP/signal-ready" "$BASH" "$SIGNAL_SCRIPT" &
signal_pid=$!
wait_for_file "$TMP/signal-ready"
kill -TERM "$signal_pid"
set +e
wait "$signal_pid"
signal_rc=$?
set -e
signal_pid=""
[[ "$signal_rc" -eq 143 ]] || fail "TERM cleanup returned $signal_rc instead of 143"
# Consumed by dynamically sourced lock helpers.
# shellcheck disable=SC2034
FIX_MODE=false
# Consumed by dynamically sourced lock helpers.
# shellcheck disable=SC2034
VW_HEALTH_LOCK_FILE="$signal_lock"
_acquire_run_lock || fail "health coordination was not reusable after TERM cleanup"
_release_run_lock 0 || fail "post-signal release failed"
grep -Fq "trap '_health_signal_cleanup 129' HUP" "$HEALTH" || fail "HUP cleanup trap is missing"
grep -Fq "trap '_health_signal_cleanup 130' INT" "$HEALTH" || fail "INT cleanup trap is missing"
grep -Fq "trap '_health_signal_cleanup 143' TERM" "$HEALTH" || fail "TERM cleanup trap is missing"
pass "health coordination is released on EXIT, HUP, INT, and TERM paths"
)

check_health_run_lock_contracts
