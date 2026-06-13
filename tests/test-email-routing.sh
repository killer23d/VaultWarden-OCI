#!/usr/bin/env bash
# Focused offline regression tests for lib/email.sh routing and compatibility.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_TMP=$(mktemp -d -t vw-email-tests.XXXXXXXXXX)
trap 'rm -rf "$TEST_TMP"' EXIT HUP INT TERM

export PROJECT_ROOT="$TEST_TMP/project"
mkdir -p "$PROJECT_ROOT"
export ADMIN_EMAIL="admin@example.test"
export SMTP_FROM="sender@example.test"
export SMTP_FROM_NAME="VaultWarden Test"
export EMAIL_RATE_WINDOW_SECONDS=0

# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/../lib/log.sh"
# shellcheck source=lib/email.sh
source "${SCRIPT_DIR}/../lib/email.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

assert_contains() {
    local haystack="$1" needle="$2" label="$3"
    [[ "$haystack" == *"$needle"* ]] || fail "${label}: missing '${needle}' in '${haystack}'"
}

reset_transports() {
    : > "${TEST_TMP}/calls"
    API_RESULT=0 SMTP_RESULT=0 HOST_RESULT=0
    ATT_API_RESULT=0 ATT_SMTP_RESULT=0 ATT_HOST_RESULT=0
    export EMAIL_MODE=auto EMAIL_PROVIDER=smtp EMAIL_API_TOKEN="token-value"
}

_email_driver_mailersend() {
    printf 'api:%s:%s:%s\n' "$1" "$2" "$3" >> "${TEST_TMP}/calls"
    return "$API_RESULT"
}
_email_driver_mailersend_attachment() {
    printf 'api-att:%s:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" "$5" >> "${TEST_TMP}/calls"
    return "$ATT_API_RESULT"
}
_smtp_send() {
    printf 'smtp:%s:%s:%s\n' "$1" "$2" "$3" >> "${TEST_TMP}/calls"
    return "$SMTP_RESULT"
}
_host_send() {
    printf 'host:%s:%s:%s\n' "$1" "$2" "$3" >> "${TEST_TMP}/calls"
    return "$HOST_RESULT"
}
_smtp_send_with_attachment() {
    printf 'smtp-att:%s:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" "$5" >> "${TEST_TMP}/calls"
    return "$ATT_SMTP_RESULT"
}
_host_send_with_attachment() {
    printf 'host-att:%s:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" "$5" >> "${TEST_TMP}/calls"
    return "$ATT_HOST_RESULT"
}

test_public_compatibility() {
    reset_transports
    EMAIL_MODE=smtp EMAIL_PROVIDER=mailersend send_email "Subject A" "Body A" || fail "send_email SUBJECT BODY failed"
    assert_contains "$(cat "${TEST_TMP}/calls")" "smtp:admin@example.test" "legacy send_email recipient"

    reset_transports
    EMAIL_MODE=smtp send_email "user@example.test" "Subject B" "Body B" || fail "send_email TO SUBJECT BODY failed"
    assert_contains "$(cat "${TEST_TMP}/calls")" "smtp:user@example.test" "explicit send_email recipient"

    reset_transports
    EMAIL_MODE=smtp send_notification_email "Subject C" "Body C" || fail "send_notification_email SUBJECT BODY failed"
    assert_contains "$(cat "${TEST_TMP}/calls")" "smtp:admin@example.test" "legacy notification recipient"

    reset_transports
    EMAIL_MODE=smtp send_notification_email "notify@example.test" "Subject D" "Body D" || fail "send_notification_email TO SUBJECT BODY failed"
    assert_contains "$(cat "${TEST_TMP}/calls")" "smtp:notify@example.test" "explicit notification recipient"

    reset_transports
    _smtp_send "smtp@example.test" "Subject E" "Body E" || fail "_smtp_send compatibility failed"
    _dispatch_email_with_attachment "att@example.test" "Subject F" "Body F" "${TEST_TMP}/attachment.txt" "report.txt" || true
    pass "public compatibility wrappers"
}

test_driver_compatibility() {
    printf 'attachment' > "${TEST_TMP}/attachment.txt"
    _email_bearer_post() { printf '%s\n' "$2" > "${TEST_TMP}/payload"; return 0; }

    EMAIL_API_TOKEN=token _email_driver_resend "Legacy Subject" "Legacy Body" || fail "legacy normal driver failed"
    assert_contains "$(cat "${TEST_TMP}/payload")" '"to":      ["admin@example.test"]' "legacy normal driver ADMIN_EMAIL"

    EMAIL_API_TOKEN=token _email_driver_resend "driver@example.test" "New Subject" "New Body" || fail "new normal driver failed"
    assert_contains "$(cat "${TEST_TMP}/payload")" '"to":      ["driver@example.test"]' "new normal driver explicit TO"

    EMAIL_API_TOKEN=token _email_driver_resend_attachment "Legacy Att" "Body" "${TEST_TMP}/attachment.txt" "unsafe name.txt" || fail "legacy attachment driver failed"
    assert_contains "$(cat "${TEST_TMP}/payload")" '"to":      ["admin@example.test"]' "legacy attachment ADMIN_EMAIL"
    assert_contains "$(cat "${TEST_TMP}/payload")" '"filename": "unsafe_name.txt"' "safe attachment filename"

    EMAIL_API_TOKEN=token _email_driver_resend_attachment "driver-att@example.test" "New Att" "Body" "${TEST_TMP}/attachment.txt" "kit.zip" || fail "new attachment driver failed"
    assert_contains "$(cat "${TEST_TMP}/payload")" '"to":      ["driver-att@example.test"]' "new attachment explicit TO"
    pass "legacy exported driver signatures"
}

test_routing_matrix() {
    reset_transports
    EMAIL_MODE=auto EMAIL_PROVIDER=mailersend API_RESULT=0 send_email "api@example.test" "R1" "B" || fail "auto api success"
    [[ $(head -n 1 "${TEST_TMP}/calls" | cut -d: -f1) == "api" ]] || fail "auto api did not use API first"

    reset_transports
    EMAIL_MODE=auto EMAIL_PROVIDER=mailersend API_RESULT=1 SMTP_RESULT=0 send_email "api-fail@example.test" "R2" "B" || fail "auto API->SMTP fallback"
    [[ $(grep -E '^(api|smtp|host|api-att|smtp-att|host-att):' "${TEST_TMP}/calls" | cut -d: -f1 | paste -sd '>' -) == "api>smtp" ]] || fail "auto API->SMTP order wrong"

    reset_transports
    EMAIL_MODE=auto EMAIL_PROVIDER=mailersend API_RESULT=1 SMTP_RESULT=1 HOST_RESULT=0 send_email "host-fallback@example.test" "R3" "B" || fail "auto API->SMTP->host fallback"
    [[ $(grep -E '^(api|smtp|host|api-att|smtp-att|host-att):' "${TEST_TMP}/calls" | cut -d: -f1 | paste -sd '>' -) == "api>smtp>host" ]] || fail "auto API->SMTP->host order wrong"

    reset_transports
    EMAIL_MODE=auto EMAIL_PROVIDER=smtp SMTP_RESULT=1 HOST_RESULT=0 send_email "smtp-auto@example.test" "R4" "B" || fail "auto smtp->host fallback"
    [[ $(grep -E '^(api|smtp|host|api-att|smtp-att|host-att):' "${TEST_TMP}/calls" | cut -d: -f1 | paste -sd '>' -) == "smtp>host" ]] || fail "auto smtp order wrong"

    reset_transports
    EMAIL_MODE=auto EMAIL_PROVIDER=host HOST_RESULT=1 SMTP_RESULT=0 send_email "host-auto@example.test" "R5" "B" || fail "auto host->smtp fallback"
    [[ $(grep -E '^(api|smtp|host|api-att|smtp-att|host-att):' "${TEST_TMP}/calls" | cut -d: -f1 | paste -sd '>' -) == "host>smtp" ]] || fail "auto host order wrong"

    reset_transports
    EMAIL_MODE=api EMAIL_PROVIDER=mailersend API_RESULT=1 send_email "api-only@example.test" "R6" "B" >/dev/null 2>&1 && fail "api mode fell back"
    [[ $(head -n 1 "${TEST_TMP}/calls" | cut -d: -f1) == "api" ]] || fail "api-only attempted non-api"

    reset_transports
    EMAIL_MODE=api EMAIL_PROVIDER=smtp send_email "bad@example.test" "R7" "B" >/dev/null 2>&1 && fail "api smtp provider accepted"

    reset_transports
    EMAIL_MODE=smtp EMAIL_PROVIDER=mailersend send_email "smtp-only@example.test" "R8" "B" || fail "smtp mode failed"
    [[ $(head -n 1 "${TEST_TMP}/calls" | cut -d: -f1) == "smtp" ]] || fail "smtp mode redirected by provider"

    reset_transports
    EMAIL_MODE=host EMAIL_PROVIDER=mailersend HOST_RESULT=1 SMTP_RESULT=0 send_email "host-mode@example.test" "R9" "B" || fail "host mode fallback failed"
    [[ $(grep -E '^(api|smtp|host|api-att|smtp-att|host-att):' "${TEST_TMP}/calls" | cut -d: -f1 | paste -sd '>' -) == "host>smtp" ]] || fail "host mode order wrong"

    reset_transports
    EMAIL_MODE=bogus send_email "bad@example.test" "R10" "B" >/dev/null 2>&1 && fail "unknown EMAIL_MODE accepted"
    reset_transports
    EMAIL_MODE=auto EMAIL_PROVIDER=bogus send_email "bad@example.test" "R11" "B" >/dev/null 2>&1 && fail "unknown EMAIL_PROVIDER accepted"
    pass "ordinary routing matrix"
}

test_attachment_routing_and_mime() {
    printf 'hello attachment' > "${TEST_TMP}/attachment.txt"
    reset_transports
    EMAIL_MODE=auto EMAIL_PROVIDER=mailersend ATT_API_RESULT=0 _dispatch_email_with_attachment "to@example.test" "A1" "B" "${TEST_TMP}/attachment.txt" "kit.zip" || fail "attachment API success"
    [[ $(head -n 1 "${TEST_TMP}/calls" | cut -d: -f1) == "api-att" ]] || fail "attachment API not first"

    reset_transports
    EMAIL_MODE=auto EMAIL_PROVIDER=mailersend ATT_API_RESULT=1 ATT_SMTP_RESULT=1 ATT_HOST_RESULT=0 _dispatch_email_with_attachment "to@example.test" "A2" "B" "${TEST_TMP}/attachment.txt" "kit.zip" || fail "attachment fallback"
    [[ $(grep -E '^(api|smtp|host|api-att|smtp-att|host-att):' "${TEST_TMP}/calls" | cut -d: -f1 | paste -sd '>' -) == "api-att>smtp-att>host-att" ]] || fail "attachment fallback order wrong"

    reset_transports
    EMAIL_MODE=api EMAIL_PROVIDER=cyberpersons _dispatch_email_with_attachment "to@example.test" "A3" "B" "${TEST_TMP}/attachment.txt" "kit.zip" >/dev/null 2>&1 && fail "CyberPersons API attachment accepted"

    local msg="${TEST_TMP}/mime.eml"
    _email_build_attachment_message "to@example.test" "MIME" "Body text" "${TEST_TMP}/attachment.txt" "bad name.txt" "$msg" || fail "MIME build failed"
    local mime; mime=$(cat "$msg")
    for header in 'From:' 'To: to@example.test' 'Subject: [VaultWarden] MIME' 'Date:' 'Message-ID:' 'MIME-Version: 1.0' 'Content-Type: text/plain' 'Content-Disposition: attachment; filename="bad name.txt"' '--=====VW_'; do
        assert_contains "$mime" "$header" "MIME header ${header}"
    done
    local last_line; last_line=$(tail -n 1 "$msg" | tr -d '\r')
    [[ "$last_line" == --=====VW_*=====-- ]] || fail "MIME terminating boundary missing"
    pass "attachment routing and MIME structure"
}

test_security_cleanup_and_rate_limit() {
    local mock_bin="${TEST_TMP}/mock-bin" argv_log="${TEST_TMP}/argv" cfg_copy="${TEST_TMP}/config-copy" payload_copy="${TEST_TMP}/payload-copy"
    mkdir -p "$mock_bin"
    cat > "${mock_bin}/curl" <<EOF2
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$argv_log"
while [[ \$# -gt 0 ]]; do
    case \$1 in
        --config) cp "\$2" "$cfg_copy"; shift 2 ;;
        --data-binary) cp "\${2#@}" "$payload_copy"; shift 2 ;;
        --output) printf '{"ErrorCode":0}' > "\$2"; shift 2 ;;
        --write-out) shift 2 ;;
        *) shift ;;
    esac
done
printf '200'
exit "\${CURL_RC:-0}"
EOF2
    chmod 700 "${mock_bin}/curl"
    local old_path="$PATH"
    PATH="${mock_bin}:$PATH" EMAIL_API_TIMEOUT=3 _email_json_post "https://example.invalid" "Authorization" 'Bearer tok"with\\slash' '{"ok":true}' || fail "mock bearer post failed"
    PATH="$old_path"
    ! grep -Fq 'tok"with\slash' "$argv_log" || fail "API token leaked into argv"
    grep -Fq 'header = "Authorization: Bearer tok\"with\\\\slash"' "$cfg_copy" || fail "curl config escaping wrong"
    [[ $(cat "$payload_copy") == '{"ok":true}' ]] || fail "payload file mismatch"
    ! compgen -G '/dev/shm/vw-email-*' >/dev/null || fail "email temp files left in /dev/shm after success"

    _email_json_post "https://example.invalid" "Authorization" $'bad\nsecret' '{}' >/dev/null 2>&1 && fail "newline secret accepted"
    _email_json_post "https://example.invalid" "Authorization" $'bad\001secret' '{}' >/dev/null 2>&1 && fail "control character secret accepted"

    rm -rf "$PROJECT_ROOT/.rate-limit"
    reset_transports
    EMAIL_MODE=smtp SMTP_RESULT=0 EMAIL_RATE_WINDOW_SECONDS=3600 send_email "rate@example.test" "Rate Subject" "B" || fail "rate send failed"
    local stamp_hash stamp
    stamp_hash=$(printf '%s' '[VaultWarden] Rate Subject' | sha256sum | cut -c1-16)
    stamp="$PROJECT_ROOT/.rate-limit/.vw_last_email_${stamp_hash}"
    [[ -f "$stamp" ]] || fail "successful send did not write rate stamp"
    clear_email_rate_limit "Rate Subject"
    [[ ! -f "$stamp" ]] || fail "clear_email_rate_limit did not remove stamp"

    rm -rf "$PROJECT_ROOT/.rate-limit"
    reset_transports
    EMAIL_MODE=smtp SMTP_RESULT=1 send_email "rate@example.test" "Failed Subject" "B" >/dev/null 2>&1 && fail "failed send unexpectedly succeeded"
    ! find "$PROJECT_ROOT/.rate-limit" -type f -name '.vw_last_email_*' | grep -q . || fail "failed send wrote rate stamp"
    pass "security cleanup and rate limiting"
}

test_recovery_help_and_maintenance_recipient() {
    local output
    output=$(cd "${SCRIPT_DIR}/.." && ./utilities/secrets-export-recovery-kit.sh --help 2>&1) || fail "top-level recovery help failed"
    assert_contains "$output" 'export-recovery-kit [OPTIONS]' "recovery help"
    [[ "$output" != *'.env not found'* ]] || fail "recovery help emitted .env warning"

    output=$(cd "${SCRIPT_DIR}/.." && ./utilities/secrets-export-recovery-kit.sh export-recovery-kit --help 2>&1) || fail "subcommand recovery help failed"
    assert_contains "$output" 'export-recovery-kit [OPTIONS]' "recovery subcommand help"
    [[ "$output" != *'.env not found'* ]] || fail "recovery subcommand help emitted .env warning"

    # shellcheck disable=SC2016 # Static grep intentionally matches literal variable names.
    grep -Fq 'send_notification_email "$TEST_RECIPIENT" "$test_subject" "$test_body"' "${SCRIPT_DIR}/../utilities/maintenance-email.sh" \
        || fail "maintenance-email.sh does not pass TEST_RECIPIENT to send_notification_email"
    pass "recovery help and maintenance recipient"
}

printf 'attachment' > "${TEST_TMP}/attachment.txt"
test_public_compatibility
test_driver_compatibility
test_routing_matrix
test_attachment_routing_and_mime
test_security_cleanup_and_rate_limit
test_recovery_help_and_maintenance_recipient

printf 'Email routing regression tests passed.\n'
