#!/usr/bin/env bash
# Consolidated email regression suite.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR/../../..

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

check_maintenance_email_root_contract() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
cd "$ROOT"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

script="utilities/maintenance-email.sh"

[[ -f "$script" ]] || fail "$script not found"

grep -Fq 'require_root "$@"' "$script" \
    || fail "maintenance email diagnostic must require root"

! grep -Fq 'refuse_root_for_user_command' "$script" \
    || fail "maintenance email diagnostic must not refuse root"

grep -Fq 'sudo ./maintenance.sh test-email' "$script" \
    || fail "dispatcher help must show sudo ./maintenance.sh test-email"

grep -Fq 'sudo utilities/maintenance-email.sh' "$script" \
    || fail "direct help must show sudo utilities/maintenance-email.sh"

pass "maintenance-email.sh is root-operated"

)

check_maintenance_email_root_contract
check_email_diagnostic_transport_contracts() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
DIAGNOSTIC="$ROOT/utilities/maintenance-email.sh"
EMAIL_LIB="$ROOT/lib/email.sh"
MAKEFILE="$ROOT/Makefile"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

extract_function() {
    local file="$1" function_name="$2"
    awk -v function_name="$function_name" '
        $0 ~ "^" function_name "[(][)]" { printing=1 }
        printing {
            print
            opens=gsub(/{/, "{")
            closes=gsub(/}/, "}")
            depth += opens - closes
            if (depth == 0) exit
        }
    ' "$file"
}

exact_source="$(extract_function "$EMAIL_LIB" send_email_via_transport)"
[[ -n "$exact_source" ]] || fail "could not isolate send_email_via_transport"
grep -Fq '_smtp_upload_sidecar "$message_file"' <<<"$exact_source" \
    || fail "exact sidecar diagnostic must call the sidecar uploader"
grep -Fq '_smtp_upload_direct "$message_file"' <<<"$exact_source" \
    || fail "exact direct diagnostic must call the direct uploader"
! grep -Fq '_smtp_fallback_chain' <<<"$exact_source" \
    || fail "exact diagnostic must not use the SMTP fallback chain"
! grep -Eq '^[[:space:]]*(export[[:space:]]+)?EMAIL_MODE=' "$DIAGNOSTIC" \
    || fail "diagnostic must not overwrite EMAIL_MODE"

grep -Fq 'transports=(api sidecar direct)' "$DIAGNOSTIC" \
    || fail "all must select exactly API, sidecar, and direct transports"
grep -Fq 'test_subject="VaultWarden Email Test - ${transport} - ${timestamp} - $$-${RANDOM}"' "$DIAGNOSTIC" \
    || fail "diagnostic subjects must identify the transport and include a unique timestamp suffix"
! grep -Eq '[(][(](passed|failed)[+][+][)][)]' "$DIAGNOSTIC" \
    || fail "diagnostic counters must be safe under set -e"
grep -Fq 'EMAIL_TEST_TRANSPORT ?= configured' "$MAKEFILE" \
    || fail "Make must default email diagnostics to the configured route"
grep -Fq 'override EMAIL_TEST_TRANSPORT := $(value EMAIL_TEST_TRANSPORT)' "$MAKEFILE" \
    || fail "Make must preserve EMAIL_TEST_TRANSPORT as a literal command-line value"
grep -Fq 'export EMAIL_TEST_TRANSPORT QUEUE_ID EMAIL_QUEUE_TAIL EMAIL_QUEUE_BODY' "$MAKEFILE" \
    || fail "Make must export documented email inputs to shell recipes"
grep -Fq './maintenance.sh test-email --transport "$${EMAIL_TEST_TRANSPORT}" --verbose' "$MAKEFILE" \
    || fail "Make must quote and forward EMAIL_TEST_TRANSPORT from the shell environment"
! grep -Fq './maintenance.sh test-email --transport "$(EMAIL_TEST_TRANSPORT)" --verbose' "$MAKEFILE" \
    || fail "Make must not expand EMAIL_TEST_TRANSPORT while constructing the recipe"

extract_function "$DIAGNOSTIC" run_email_diagnostics >"$TMP/run-email-diagnostics.bash"
cat >>"$TMP/run-email-diagnostics.bash" <<'HARNESS'
TEST_TRANSPORT=all
DRY_RUN=false
CALLS=()
log_header(){ :; }
log_info(){ printf '%s\n' "$*"; }
log_warn(){ :; }
log_error(){ printf '%s\n' "$*"; }
test_crowdsec_integration(){ return 0; }
_run_transport_test(){
    CALLS+=("$1")
    [[ "$1" != sidecar ]]
}
rc=0
run_email_diagnostics || rc=$?
printf 'RC=%s\n' "$rc"
printf 'CALLS=%s\n' "${CALLS[*]}"
HARNESS

aggregate_output="$(bash "$TMP/run-email-diagnostics.bash")"
[[ "$aggregate_output" == *"RC=1"* ]] \
    || fail "all must return nonzero when one exact transport fails"
[[ "$aggregate_output" == *"CALLS=api sidecar direct"* ]] \
    || fail "all must continue testing independently after a transport failure"
[[ "$aggregate_output" == *"SUMMARY: 2/3 transport tests passed; 1 failed"* ]] \
    || fail "aggregate summary must report individual failures"

extract_function "$DIAGNOSTIC" _run_transport_test >"$TMP/run-email-dry-run.bash"
cat >>"$TMP/run-email-dry-run.bash" <<'HARNESS'
DRY_RUN=true
TEST_RECIPIENT=admin@example.com
SENDS=0
log_info(){ printf '%s\n' "$*"; }
log_success(){ printf '%s\n' "$*"; }
log_error(){ printf '%s\n' "$*"; }
_preflight_transport(){ return 0; }
send_notification_email(){ SENDS=$((SENDS + 1)); }
send_email_via_transport(){ SENDS=$((SENDS + 1)); }
for transport in configured api sidecar direct; do
    _run_transport_test "$transport"
done
printf 'SENDS=%s\n' "$SENDS"
HARNESS

dry_run_output="$(bash "$TMP/run-email-dry-run.bash")"
[[ "$dry_run_output" == *"SENDS=0"* ]] \
    || fail "dry-run must not call configured or exact email send functions"
[[ "$dry_run_output" == *"configured: dry-run validated"* \
    && "$dry_run_output" == *"api: dry-run validated"* \
    && "$dry_run_output" == *"sidecar: dry-run validated"* \
    && "$dry_run_output" == *"direct: dry-run validated"* ]] \
    || fail "dry-run must report validation for every requested transport"
[[ "$dry_run_output" != *": passed"* ]] \
    || fail "dry-run must not report actual transport delivery"

cat >"$TMP/run-email-cli.bash" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
TEST_RECIPIENT=""
TEST_TRANSPORT="configured"
VERBOSE=false
DRY_RUN=false
PROJECT_ROOT=/tmp
log_error(){ :; }
show_help(){ :; }
print_project_version(){ :; }
require_root(){ :; }
HARNESS
extract_function "$DIAGNOSTIC" _require_cli_value >>"$TMP/run-email-cli.bash"
extract_function "$DIAGNOSTIC" _validate_transport >>"$TMP/run-email-cli.bash"
sed -n '/^\[\[ "${1:-}" == "test-email" \]\] && shift$/,/^: "${VERBOSE}"$/p' \
    "$DIAGNOSTIC" >>"$TMP/run-email-cli.bash"
assert_cli_rc() {
    local expected="$1" description="$2" rc=0
    shift 2
    set +e
    bash "$TMP/run-email-cli.bash" "$@" >"$TMP/cli.out" 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq "$expected" ]] \
        || fail "$description returned $rc instead of $expected"
}
assert_cli_rc 2 'unknown option' --unknown
assert_cli_rc 2 'missing option value' --recipient
assert_cli_rc 2 'invalid transport value' --transport invalid
assert_cli_rc 0 'valid diagnostic usage' --transport configured --dry-run

extract_function "$DIAGNOSTIC" _run_transport_test >"$TMP/run-email-result.bash"
cat >>"$TMP/run-email-result.bash" <<'HARNESS'
DRY_RUN=false
TEST_RECIPIENT=admin@example.com
SEND_RC=0
log_info(){ :; }
log_success(){ :; }
log_error(){ :; }
_preflight_transport(){ return 0; }
send_notification_email(){ return "$SEND_RC"; }
send_email_via_transport(){ return "$SEND_RC"; }
rc=0
_run_transport_test configured || rc=$?
printf 'SUCCESS_RC=%s\n' "$rc"
SEND_RC=1
rc=0
_run_transport_test configured || rc=$?
printf 'FAILURE_RC=%s\n' "$rc"
HARNESS
delivery_output="$(bash "$TMP/run-email-result.bash")"
[[ "$delivery_output" == *"SUCCESS_RC=0"* ]] \
    || fail 'successful mocked delivery did not return 0'
[[ "$delivery_output" == *"FAILURE_RC=1"* ]] \
    || fail 'failed mocked delivery did not return 1'
printf 'Email diagnostic transport contracts passed.\n'
)

check_email_diagnostic_transport_contracts
check_email_delivery_refactor_contracts() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
RATE_LIMIT_DIR="$(mktemp -d)"
trap 'rm -rf "$RATE_LIMIT_DIR"' EXIT
PASS=0
FAIL=0

run_case() {
    local name="$1" script="$2" out rc
    set +e
    out=$(ROOT="$ROOT" RATE_LIMIT_DIR="$RATE_LIMIT_DIR" bash -c "$script" 2>&1)
    rc=$?
    set -e
    if (( rc == 0 )); then
        echo "ok - $name"
        ((++PASS))
    else
        echo "not ok - $name"
        printf '%s\n' "$out"
        ((++FAIL))
    fi
}

common_prelude='cd "$ROOT"; source lib/log.sh >/dev/null 2>&1 || true; source lib/email.sh; _resolve_rate_limit_dir(){ mkdir -p "$RATE_LIMIT_DIR"; printf "%s\n" "$RATE_LIMIT_DIR"; }; log_info(){ :; }; log_warn(){ TRACE+=" warn:$*"; }; log_error(){ TRACE+=" error:$*"; }; log_success(){ :; }; log_debug(){ :; }; log_hint(){ :; }; register_cleanup(){ CLEANUPS+=("$*"); }; reset_env(){ CLEANUPS=(); TRACE=""; CURL_ARGS=""; CAPTURED=""; EMAIL_MODE=auto EMAIL_PROVIDER=mailersend ADMIN_EMAIL=admin@example.com SMTP_FROM=noreply@example.com SMTP_FROM_NAME=VaultWarden SMTP_HOST=smtp.example.com SMTP_PORT=587 SMTP_USERNAME=user SMTP_PASSWORD="p a\"s\\w" SMTP_SECURITY= EMAIL_API_TOKEN=token EMAIL_RATE_WINDOW_SECONDS=0 PROJECT_ROOT="$ROOT"; export EMAIL_MODE EMAIL_PROVIDER ADMIN_EMAIL SMTP_FROM SMTP_FROM_NAME SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_SECURITY EMAIL_API_TOKEN EMAIL_RATE_WINDOW_SECONDS PROJECT_ROOT; }'

routing_prelude="$common_prelude; _email_driver_mailersend(){ TRACE+=\" api:\$1\"; CAPTURED=\"\${3:-}\"; return \"\${API_RC:-0}\"; }; _email_driver_sendgrid(){ TRACE+=\" sendgrid:\$1\"; CAPTURED=\"\${3:-}\"; return 0; }; _email_driver_mailgun(){ TRACE+=\" mailgun:\$1\"; CAPTURED=\"\${3:-}\"; return 0; }; _email_driver_postmark(){ TRACE+=\" postmark:\$1\"; CAPTURED=\"\${3:-}\"; return 0; }; _email_driver_resend(){ TRACE+=\" resend:\$1\"; CAPTURED=\"\${3:-}\"; return 0; }; _email_driver_cyberpersons(){ TRACE+=\" cyber:\$1\"; CAPTURED=\"\${3:-}\"; return 0; }; _smtp_upload_sidecar(){ TRACE+=\" sidecar\"; CAPTURED=\$(cat \"\$1\" 2>/dev/null || true); return \"\${SIDE_RC:-0}\"; }; _smtp_upload_direct(){ TRACE+=\" direct\"; CAPTURED=\$(cat \"\$1\" 2>/dev/null || true); [[ \"\${RESOLVE_MARK:-0}\" == 1 ]] && get_secret smtp_password >/dev/null; return \"\${DIRECT_RC:-0}\"; }; get_secret(){ TRACE+=\" secret:\$1\"; printf resolved-secret; }; reset_env"

run_case 'auto API success stops immediately' "$routing_prelude; API_RC=0; send_email admin@example.com subj body; [[ \"\$TRACE\" == *api:* && \"\$TRACE\" != *sidecar* && \"\$TRACE\" != *direct* ]]"
run_case 'auto API failure -> sidecar success' "$routing_prelude; API_RC=1 SIDE_RC=0; send_email admin@example.com subj body; [[ \"\$TRACE\" == *sidecar* && \"\$TRACE\" != *direct* ]]"
run_case 'auto API failure -> sidecar failure -> direct success' "$routing_prelude; API_RC=1 SIDE_RC=1 DIRECT_RC=0; send_email admin@example.com subj body; [[ \"\$TRACE\" == *direct* ]]"
run_case 'api failure does not attempt SMTP' "$routing_prelude; EMAIL_MODE=api API_RC=1; ! send_email admin@example.com subj body; [[ \"\$TRACE\" != *sidecar* && \"\$TRACE\" != *direct* ]]"
run_case 'smtp sidecar success does not resolve smtp_password' "$routing_prelude; EMAIL_MODE=smtp SIDE_RC=0 RESOLVE_MARK=1; send_email admin@example.com subj body; [[ \"\$TRACE\" != *secret:smtp_password* ]]"
run_case 'smtp sidecar failure -> direct' "$routing_prelude; EMAIL_MODE=smtp SIDE_RC=1 DIRECT_RC=0; send_email admin@example.com subj body; [[ \"\$TRACE\" == *direct* ]]"
run_case 'direct does not probe API or sidecar' "$routing_prelude; EMAIL_MODE=direct; send_email admin@example.com subj body; [[ \"\$TRACE\" == *direct* && \"\$TRACE\" != *api:* && \"\$TRACE\" != *sidecar* ]]"
run_case 'host warns and behaves as direct' "$routing_prelude; EMAIL_MODE=host; send_email admin@example.com subj body; [[ \"\$TRACE\" == *deprecated* && \"\$TRACE\" == *direct* ]]"
run_case 'unknown mode fails' "$routing_prelude; EMAIL_MODE=bogus; ! send_email admin@example.com subj body; [[ \"\$TRACE\" == *Unknown* ]]"
run_case 'unknown provider fails in api mode' "$routing_prelude; EMAIL_MODE=api EMAIL_PROVIDER=bogus; ! send_email admin@example.com subj body; [[ \"\$TRACE\" == *Unknown* ]]"
run_case 'unknown provider falls back in auto' "$routing_prelude; EMAIL_PROVIDER=bogus SIDE_RC=0; send_email admin@example.com subj body; [[ \"\$TRACE\" == *sidecar* ]]"
run_case 'every provider receives TO explicitly' "$routing_prelude; for p in mailersend sendgrid mailgun postmark resend cyberpersons; do reset_env; EMAIL_PROVIDER=\$p; send_email explicit@example.com subj body; [[ \"\$TRACE\" == *explicit@example.com* ]]; done"
run_case 'cyber aliases resolve identically' "$routing_prelude; for p in cyberpersons cyberperson cyberpanel; do [[ \"\$(_email_driver_lookup \"\$p\")\" == cyberpersons ]]; done"
run_case 'API sends include delivery metadata' "$routing_prelude; EMAIL_PROVIDER=mailgun; send_email admin@example.com subj body; [[ \"\$CAPTURED\" == *'Email delivery metadata:'* && \"\$CAPTURED\" == *'Method:    HTTP API provider mailgun'* ]]"
run_case 'SMTP sends include delivery metadata' "$routing_prelude; EMAIL_MODE=smtp SIDE_RC=0; send_email admin@example.com subj body; [[ \"\$CAPTURED\" == *'Email delivery metadata:'* && \"\$CAPTURED\" == *'Method:    SMTP fallback chain'* ]]"
run_case 'direct sends include delivery metadata' "$routing_prelude; EMAIL_MODE=direct; send_email admin@example.com subj body; [[ \"\$CAPTURED\" == *'Email delivery metadata:'* && \"\$CAPTURED\" == *'Method:    Direct upstream SMTP'* ]]"
run_case 'exact API diagnostic does not use SMTP or mutate EMAIL_MODE' "$routing_prelude; EMAIL_MODE=smtp API_RC=0; send_email_via_transport api admin@example.com diagnostic body; [[ \"\$EMAIL_MODE\" == smtp && \"\$TRACE\" == *api:* && \"\$TRACE\" != *sidecar* && \"\$TRACE\" != *direct* && \"\$CAPTURED\" == *'Method:    Exact HTTP API transport (mailersend)'* ]]"
run_case 'exact API failure does not fall back' "$routing_prelude; API_RC=1; ! send_email_via_transport api admin@example.com diagnostic body; [[ \"\$TRACE\" == *api:* && \"\$TRACE\" != *sidecar* && \"\$TRACE\" != *direct* ]]"
run_case 'exact sidecar failure does not call direct and removes message file' "$routing_prelude; SIDE_RC=1 DIRECT_CALLED=0; _smtp_upload_sidecar(){ TRACE+=\" sidecar\"; MESSAGE_FILE=\"\$1\"; CAPTURED=\$(cat \"\$1\"); return 1; }; _smtp_upload_direct(){ DIRECT_CALLED=1; return 0; }; ! send_email_via_transport sidecar admin@example.com diagnostic body; [[ \"\$TRACE\" == *sidecar* && \"\$DIRECT_CALLED\" -eq 0 && ! -e \"\$MESSAGE_FILE\" && \"\$CAPTURED\" == *'Method:    Exact Postfix sidecar SMTP transport'* ]]"
run_case 'exact direct diagnostic does not call sidecar and removes message file' "$routing_prelude; _smtp_upload_direct(){ TRACE+=\" direct\"; MESSAGE_FILE=\"\$1\"; CAPTURED=\$(cat \"\$1\"); return 0; }; send_email_via_transport direct admin@example.com diagnostic body; [[ \"\$TRACE\" == *direct* && \"\$TRACE\" != *sidecar* && ! -e \"\$MESSAGE_FILE\" && \"\$CAPTURED\" == *'Method:    Exact direct upstream SMTP transport'* ]]"
run_case 'exact diagnostics bypass the production rate limiter' "$routing_prelude; _rate_limit_check(){ TRACE+=\" rate-limit\"; return 1; }; SIDE_RC=0; send_email_via_transport sidecar admin@example.com diagnostic body; [[ \"\$TRACE\" == *sidecar* && \"\$TRACE\" != *rate-limit* ]]"
run_case 'unsupported exact transport returns status 2 without sending' "$routing_prelude; rc=0 API_CALLED=0 SIDECAR_CALLED=0 DIRECT_CALLED=0; _email_driver_mailersend(){ API_CALLED=1; }; _smtp_upload_sidecar(){ SIDECAR_CALLED=1; }; _smtp_upload_direct(){ DIRECT_CALLED=1; }; send_email_via_transport bogus admin@example.com diagnostic body || rc=\$?; [[ \"\$rc\" -eq 2 && \"\$API_CALLED\" -eq 0 && \"\$SIDECAR_CALLED\" -eq 0 && \"\$DIRECT_CALLED\" -eq 0 ]]"

run_case 'direct SMTP implementation accepts normal values and infers STARTTLS' "$common_prelude; reset_env; unset EMAIL_API_TOKEN; curl(){ CURL_ARGS=\"\$*\"; return 0; }; _smtp_upload_direct /dev/null noreply@example.com admin@example.com; [[ \"\$CURL_ARGS\" == *--ssl-reqd* && \"\$CURL_ARGS\" != *\"\$SMTP_PASSWORD\"* ]]"
run_case 'direct SMTP implementation infers TLS on port 465' "$common_prelude; reset_env; SMTP_PORT=465; curl(){ CURL_ARGS=\"\$*\"; return 0; }; _smtp_upload_direct /dev/null noreply@example.com admin@example.com; [[ \"\$CURL_ARGS\" == *smtps://smtp.example.com:465* ]]"
run_case 'direct SMTP explicit off permits plaintext' "$common_prelude; reset_env; SMTP_SECURITY=off; curl(){ CURL_ARGS=\"\$*\"; return 0; }; _smtp_upload_direct /dev/null noreply@example.com admin@example.com; [[ \"\$CURL_ARGS\" == *smtp://smtp.example.com:587* && \"\$CURL_ARGS\" != *--ssl-reqd* ]]"
run_case 'direct SMTP resolves smtp_password lazily from get_secret' "$common_prelude; reset_env; unset SMTP_PASSWORD; get_secret(){ TRACE+=\" get_secret:\$1\"; printf secret-from-store; }; curl(){ CURL_ARGS=\"\$*\"; return 0; }; _smtp_upload_direct /dev/null noreply@example.com admin@example.com; [[ \"\$CURL_ARGS\" != *secret-from-store* ]]"
run_case 'direct SMTP credential file registered for cleanup' "$common_prelude; reset_env; curl(){ return 0; }; _smtp_upload_direct /dev/null noreply@example.com admin@example.com; [[ \"\${CLEANUPS[*]}\" == *vw-smtp-cfg* ]]"
run_case 'HTTP helper resolves email_api_token and keeps payload/token out of argv' "$common_prelude; reset_env; unset EMAIL_API_TOKEN; get_secret(){ printf api-secret; }; argfile=\$(mktemp); curl(){ printf '%s' \"\$*\" >\"\$argfile\"; local out=; while [[ \$# -gt 0 ]]; do [[ \$1 == -o ]] && { out=\$2; shift 2; continue; }; shift; done; printf \"{}\" >\"\$out\"; printf 200; }; _email_http_bearer_json https://api.example.test '{\"body\":\"secret email body\"}'; CURL_ARGS=\$(cat \"\$argfile\"); rm -f \"\$argfile\"; [[ \"\$CURL_ARGS\" != *api-secret* && \"\$CURL_ARGS\" != *secret\ email\ body* && \"\$CURL_ARGS\" == *@*vw-email-http-payload* ]]"

run_case 'attachment MIME uses real builder, CRLF, boundary, and base64' "$common_prelude; reset_env; tmp=\$(mktemp); printf hi >\"\$tmp\"; _smtp_upload_sidecar(){ CAPTURED=\$(cat \"\$1\"); TRACE+=\" sidecar\"; return 0; }; _smtp_upload_direct(){ TRACE+=\" direct\"; return 0; }; send_smtp_attachment admin@example.com subj body \"\$tmp\" good.txt; rm -f \"\$tmp\"; [[ \"\$TRACE\" == *sidecar* && \"\$TRACE\" != *direct* && \"\$CAPTURED\" == *\$'\r\nContent-Disposition: attachment; filename=\"good.txt\"\r\n'* && \"\$CAPTURED\" == *\$'aGk=\r\n'* && \"\$CAPTURED\" == *'Email delivery metadata:'* ]]"
run_case 'attachment sidecar failure invokes real fallback path' "$common_prelude; reset_env; tmp=\$(mktemp); echo hi >\"\$tmp\"; _smtp_upload_sidecar(){ TRACE+=\" sidecar\"; return 1; }; _smtp_upload_direct(){ TRACE+=\" direct\"; return 0; }; send_smtp_attachment admin@example.com subj body \"\$tmp\" good.txt; rm -f \"\$tmp\"; [[ \"\$TRACE\" == *sidecar* && \"\$TRACE\" == *direct* ]]"
run_case 'empty sender and missing attachment fail before curl' "$common_prelude; reset_env; curl(){ TRACE+=curl; return 0; }; unset SMTP_FROM; ! send_smtp_attachment admin@example.com subj body /missing good.txt; [[ \"\$TRACE\" != *curl* ]]"
run_case 'CR/LF header injection and invalid filename rejected' "$common_prelude; reset_env; tmp=\$(mktemp); echo hi >\"\$tmp\"; ! send_smtp_attachment \$'bad\n@example.com' subj body \"\$tmp\" good.txt; ! send_smtp_attachment admin@example.com subj body \"\$tmp\" 'bad\"name'; rm -f \"\$tmp\""
run_case 'clear_email_rate_limit removes only targeted subject' "$common_prelude; reset_env; dir=\$(_resolve_rate_limit_dir); s1=\$(_normalise_email_subject one); s2=\$(_normalise_email_subject two); f1=\$(_rate_limit_file_for_subject \"\$s1\" \"\$dir\"); f2=\$(_rate_limit_file_for_subject \"\$s2\" \"\$dir\"); date +%s >\"\$f1\"; date +%s >\"\$f2\"; clear_email_rate_limit one; [[ ! -e \"\$f1\" && -e \"\$f2\" ]]; rm -f \"\$f2\""
run_case 'caller EXIT trap preserved' "$common_prelude; reset_env; _smtp_upload_direct(){ return 0; }; trap 'echo caller-exit' EXIT; before=\$(trap -p EXIT); EMAIL_MODE=direct send_email admin@example.com subj body >/dev/null; after=\$(trap -p EXIT); trap - EXIT; [[ \"\$before\" == \"\$after\" ]]"
run_case 'obsolete symbols absent from email implementation' "cd \"$ROOT\"; pattern='_email_driver_.*_attach'\"'ment|_dispatch_email_with_attach'\"'ment|_smtp_send_with_attach'\"'ment|_smtp_curl_up'\"'load|_resolve_smtp_meth'\"'od|_email_driver_post'\"'fix|mail '\"'-s|emergency API by'\"'pass'; ! grep -En \"\$pattern\" lib/email.sh"

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))

)

check_email_delivery_refactor_contracts
check_recovery_kit_attachment_passphrase_contract() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

helper_source="$TMP/encrypt-helper.sh"
awk '
  /^_encrypt_recovery_kit_attachment[(][)]/ { in_helper=1 }
  in_helper { print }
  in_helper && /^}/ { exit }
' "$ROOT/lib/secrets.sh" >"$helper_source"
[[ -s "$helper_source" ]] || fail 'could not isolate attachment encryption helper'

transport_source="$TMP/stdin-helper.sh"
awk '
  /^_run_7zip_with_passphrase[(][)]/ { in_helper=1 }
  in_helper { print }
  in_helper && /^}/ { exit }
' "$ROOT/lib/secrets.sh" >"$transport_source"
[[ -s "$transport_source" ]] || fail 'could not isolate 7-Zip stdin helper'

grep -Fq 'prompt_password_with_confirmation' "$helper_source" \
    || fail 'attachment helper must use the existing password confirmation helper'
grep -Fq '"Passphrase to encrypt emailed AES-256 ZIP (independent from stored project credentials)" 16)' "$helper_source" \
    || fail 'attachment helper must enforce the 16-character minimum through the password helper'
grep -Fq '_run_7zip_with_passphrase "$passphrase"' "$helper_source" \
    || fail 'attachment helper must use the private 7-Zip password transport'
grep -Fq "printf '%s\\n%s\\n' \"\$passphrase\" \"\$passphrase\"" "$transport_source" \
    || fail 'archive creation must supply the confirmed passphrase twice on stdin'
grep -Fq "printf '%s\\n' \"\$passphrase\"" "$transport_source" \
    || fail 'archive read operations must supply one passphrase on stdin'
grep -Fq -- '-p?*)' "$transport_source" \
    || fail '7-Zip transport must reject inline password arguments'
! grep -Eq 'pty[.]fork|python3 -|3<<<|fd 3' "$transport_source" \
    || fail 'obsolete PTY bridge remains in the 7-Zip transport'
grep -Fq 'set +x' "$helper_source" \
    || fail 'attachment helper must disable xtrace while the passphrase is live'
grep -Fq 'unset passphrase' "$helper_source" \
    || fail 'attachment helper must unset the passphrase promptly'
# Static policy: reject password-like scalar variables attached to or passed
# immediately with an archiver password switch. A standalone literal -p next
# to an argument-array splice is allowed; the sentinel checks below prove that
# the actual passphrase never appears in argv or environment at runtime.
! awk '
  /-p|--password/ &&
  /\$[{]?(passphrase|password|secret|zip_password|recovery_password)([}]|[^A-Za-z0-9_])/ {
    print FILENAME ":" FNR ":" $0
    found=1
  }
  END { exit found ? 0 : 1 }
' "$helper_source" "$transport_source" >"$TMP/source.matches" \
    || { cat "$TMP/source.matches" >&2; fail 'attachment helper must not place a passphrase variable in archiver argv'; }
! grep -En -- 'ZIP_PASSWORD|RECOVERY_PASSWORD|passphrase[-_]file|_pass_file' "$helper_source" "$transport_source" >"$TMP/source.matches" \
    || { cat "$TMP/source.matches" >&2; fail 'attachment helper must not use environment or passphrase-file handoff'; }
! grep -En 'openssl[[:space:]]+enc|aes-256-cbc|tar[.]gpg|--symmetric|OpenPGP|GnuPG' "$helper_source" "$transport_source" >"$TMP/source.matches" \
    || { cat "$TMP/source.matches" >&2; fail 'obsolete encrypted-tar/GnuPG attachment contract remains'; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/7zz" <<'MOCK_7ZZ'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_ARGV_FILE:?}" "${MOCK_STDIN_FILE:?}" "${MOCK_ENV_FILE:?}"
printf '%s\n' "$@" >"$MOCK_ARGV_FILE"
export -p >"$MOCK_ENV_FILE"
cat >"$MOCK_STDIN_FILE"
case "${1:-}" in
  a|u)
    grep -Fxq -- '-p' "$MOCK_ARGV_FILE"
    mapfile -t lines <"$MOCK_STDIN_FILE"
    [[ "${#lines[@]}" -eq 2 && "${lines[0]}" == "${lines[1]}" ]]
    ;;
  t|x|e|l)
    ! grep -Fxq -- '-p' "$MOCK_ARGV_FILE"
    mapfile -t lines <"$MOCK_STDIN_FILE"
    [[ "${#lines[@]}" -eq 1 && "${lines[0]}" != 'WrongNonProdPassphrase16' ]]
    ;;
  *) exit 7 ;;
esac
MOCK_7ZZ
chmod +x "$TMP/bin/7zz"

sentinel='TEST_ATTACHMENT_SECRET_1234567890'
(
    cd "$ROOT"
    PATH="$TMP/bin:$PATH"
    export PATH
    # shellcheck source=../lib/secrets.sh
    source "$ROOT/lib/secrets.sh"
    export MOCK_ARGV_FILE="$TMP/add.argv"
    export MOCK_STDIN_FILE="$TMP/add.stdin"
    export MOCK_ENV_FILE="$TMP/add.env"
    _run_7zip_with_passphrase "$sentinel" 7zz \
        a -tzip -mem=AES256 -p -- out.zip recovery-kit.txt
)
! grep -Fq "$sentinel" "$TMP/add.argv" \
    || fail '7-Zip argv contains the sentinel passphrase'
! grep -Fq "$sentinel" "$TMP/add.env" \
    || fail '7-Zip environment contains the sentinel passphrase'
[[ "$(grep -Fxc "$sentinel" "$TMP/add.stdin")" -eq 2 ]] \
    || fail 'archive creation did not receive the confirmed passphrase twice'
grep -Fxq -- '-p' "$TMP/add.argv" \
    || fail 'archive creation must retain standalone -p to enable encryption'

(
    cd "$ROOT"
    PATH="$TMP/bin:$PATH"
    export PATH
    # shellcheck source=../lib/secrets.sh
    source "$ROOT/lib/secrets.sh"
    export MOCK_ARGV_FILE="$TMP/test.argv"
    export MOCK_STDIN_FILE="$TMP/test.stdin"
    export MOCK_ENV_FILE="$TMP/test.env"
    _run_7zip_with_passphrase "$sentinel" 7zz \
        t -bd -y -p -- out.zip
)
! grep -Fq "$sentinel" "$TMP/test.argv" \
    || fail '7-Zip test argv contains the sentinel passphrase'
! grep -Fq "$sentinel" "$TMP/test.env" \
    || fail '7-Zip test environment contains the sentinel passphrase'
[[ "$(grep -Fxc "$sentinel" "$TMP/test.stdin")" -eq 1 ]] \
    || fail 'archive test did not receive exactly one passphrase line'
! grep -Fxq -- '-p' "$TMP/test.argv" \
    || fail 'archive read operation must remove standalone -p for non-TTY stdin use'

if (
    cd "$ROOT"
    PATH="$TMP/bin:$PATH"
    export PATH
    # shellcheck source=../lib/secrets.sh
    source "$ROOT/lib/secrets.sh"
    export MOCK_ARGV_FILE="$TMP/wrong.argv"
    export MOCK_STDIN_FILE="$TMP/wrong.stdin"
    export MOCK_ENV_FILE="$TMP/wrong.env"
    _run_7zip_with_passphrase 'WrongNonProdPassphrase16' 7zz \
        t -bd -y -p -- out.zip
); then
    fail 'wrong synthetic passphrase must be rejected by the transport smoke test'
fi

cat > "$TMP/bin/7z" <<'MOCK_7Z'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  l)
    cat <<'LISTING'
Type = zip
Method = AES-256 Deflate
----------
Path = recovery-kit.txt
LISTING
    ;;
  t) exit 1 ;;
  *) exit 1 ;;
esac
MOCK_7Z
chmod +x "$TMP/bin/7z"

plaintext="$TMP/recovery-kit.txt"
printf 'test recovery kit\n' >"$plaintext"
transport_log="$TMP/transport.log"
run_encrypt_with_prompt() {
    local prompt_body="$1" out_file="$2"
    (
        cd "$ROOT"
        PATH="$TMP/bin:$PATH"
        export PATH
        # shellcheck source=../lib/secrets.sh
        source "$ROOT/lib/secrets.sh"
        prompt_password_with_confirmation(){ eval "$prompt_body"; }
        _run_7zip_with_passphrase() {
            local secret="$1"
            shift 2
            printf '%s\n' "$secret" >>"$transport_log"
            case " ${*} " in
              *' a '*) printf 'mock zip\n' >"$out_file"; return 0 ;;
              *' t '*) [[ "$secret" != 'VWOCI-DELIBERATELY-WRONG-PASSPHRASE' ]] ;;
              *) return 1 ;;
            esac
        }
        export transport_log out_file
        _encrypt_recovery_kit_attachment "$plaintext" "$out_file" 7z
    )
}

if run_encrypt_with_prompt 'return 1' "$TMP/short.zip"; then
    fail 'password-helper rejection must stop attachment creation'
fi
[[ ! -s "$TMP/short.zip" ]] || fail 'rejected passphrase must not leave a successful archive'

exact16='1234567890abcdef'
run_encrypt_with_prompt "printf %s '$exact16'" "$TMP/exact.zip" \
    || fail 'matching 16-character passphrase should be accepted'
longer='1234567890abcdefghi'
run_encrypt_with_prompt "printf %s '$longer'" "$TMP/long.zip" \
    || fail 'matching longer passphrase should be accepted'
grep -Fq "$exact16" "$transport_log" \
    || fail 'attachment helper did not pass the selected passphrase to the stdin transport'

real_tool=""
if command -v 7zz >/dev/null 2>&1; then
    real_tool=7zz
elif command -v 7z >/dev/null 2>&1; then
    real_tool=7z
fi
if [[ -n "$real_tool" ]]; then
    smoke_dir="$TMP/smoke"
    mkdir -p "$smoke_dir/out"
    printf 'real archive sentinel content\n' >"$smoke_dir/recovery-kit.txt"
    (
        cd "$ROOT"
        # shellcheck source=../lib/secrets.sh
        source "$ROOT/lib/secrets.sh"
        prompt_password_with_confirmation(){ printf '%s' 'NonProdTestPassphrase16'; }
        _encrypt_recovery_kit_attachment \
            "$smoke_dir/recovery-kit.txt" "$smoke_dir/kit.zip" "$real_tool"
        _run_7zip_with_passphrase 'NonProdTestPassphrase16' "$real_tool" \
            x -bd -y -p "-o$smoke_dir/out" -- "$smoke_dir/kit.zip" >/dev/null 2>&1
        if _run_7zip_with_passphrase 'WrongNonProdPassphrase16' "$real_tool" \
            t -bd -y -p -- "$smoke_dir/kit.zip" >/dev/null 2>&1; then
            exit 9
        fi
    ) || fail 'real AES-256 ZIP stdin smoke test failed'
    [[ -s "$smoke_dir/kit.zip" ]] || fail 'real AES-256 ZIP archive was not created'
    ! LC_ALL=C grep -aFq 'real archive sentinel content' "$smoke_dir/kit.zip" \
        || fail 'real AES-256 ZIP contains plaintext sentinel content'
    cmp "$smoke_dir/recovery-kit.txt" "$smoke_dir/out/recovery-kit.txt" \
        || fail 'real AES-256 ZIP extracted content mismatch'
else
    printf 'Real AES-256 ZIP stdin smoke test skipped: 7z/7zz unavailable.\n'
fi

printf 'Recovery-kit AES-256 ZIP passphrase contract tests passed.\n'
)

check_recovery_kit_attachment_passphrase_contract

check_health_alert_lock_mode_normalization() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

log_info(){ :; }
log_warn(){ :; }
log_error(){ :; }
log_debug(){ :; }

# shellcheck source=lib/health-alerts.sh
source "$ROOT/lib/health-alerts.sh"

ALERT_LOCK_DIR="$TMP/alerts"
install -d -m 0700 "$ALERT_LOCK_DIR"
HEALTH_ALERT_STATE_LOCK_FD=""

mkdir -p "$TMP/bin"
MOCK_CHMOD_LOG="$TMP/chmod.log"
MOCK_REAL_CHMOD="$(command -v chmod)"
export MOCK_CHMOD_LOG MOCK_REAL_CHMOD

cat > "$TMP/bin/chmod" <<'MOCK_CHMOD'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$MOCK_CHMOD_LOG"
[[ "${MOCK_CHMOD_FAIL:-0}" != "1" ]] || exit 1
exec "$MOCK_REAL_CHMOD" "$@"
MOCK_CHMOD
chmod 0755 "$TMP/bin/chmod"

PATH="$TMP/bin:$PATH"
export PATH

lock_path="$(_health_alert_state_lock_path)"
_health_alert_state_lock_prepare "$lock_path" \
    || fail "new health-alert lock was not prepared"
grep -Fxq "0600 -- $lock_path" "$MOCK_CHMOD_LOG" \
    || fail "new lock creation did not explicitly normalize mode 0600"

lock_mode="$(
    stat -c '%a' "$lock_path" 2>/dev/null \
        || stat -f '%Lp' "$lock_path"
)"
[[ "$lock_mode" == "600" ]] \
    || fail "normalized health-alert lock mode is not 0600"

rm -f -- "$lock_path"
: > "$MOCK_CHMOD_LOG"
export MOCK_CHMOD_FAIL=1
if _health_alert_state_lock_prepare "$lock_path" >/dev/null 2>&1; then
    fail "lock preparation succeeded when explicit mode normalization failed"
fi
[[ ! -e "$lock_path" ]] \
    || fail "failed lock-mode normalization left a newly created lock behind"

printf 'Health-alert lock mode normalization tests passed.\n'
)

check_health_alert_lock_mode_normalization

check_recovery_notification_retry_contract() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=lib/health-alerts.sh
source "$ROOT/lib/health-alerts.sh"
source "$ROOT/lib/email.sh"
log_info(){ printf 'INFO: %s\n' "$*"; }
log_warn(){ printf 'WARN: %s\n' "$*"; }

_email_available=false
ADMIN_EMAIL=admin@example.test
export ADMIN_EMAIL
unavailable_rc=0
_send_notification subject body >"$TMP/unavailable.out" 2>&1 || unavailable_rc=$?
[[ "$unavailable_rc" -ne 0 ]] \
    || fail "email-unavailable notification path reported successful delivery"

ALERT_LOCK_DIR="$TMP/alerts"
ACTIVE_INCIDENT_FILE="$ALERT_LOCK_DIR/active-incident.state"
RECOVERY_DELIVERY_STATE_FILE="$ALERT_LOCK_DIR/recovery-delivery.state"
ALERT_RECOVERY_TTL=86400
ALERT_RECOVERY_PENDING_TTL=30
HEALTH_ALERT_STATE_LOCK_FD=""
RECOVERY_DELIVERY_PHASE=""
RECOVERY_DELIVERY_INCIDENT_ID=""
RECOVERY_DELIVERY_UPDATED_AT=""
failed=0
warnings=0
passed=12
export ALERT_RECOVERY_TTL failed warnings passed
send_attempts=0
_email_available=true
send_email(){
    send_attempts=$((send_attempts + 1))
    if (( send_attempts == 1 )); then return 42; fi
    return 0
}

ACTIVE_INCIDENT_ID=""
ACTIVE_INCIDENT_STARTED_AT=""
ACTIVE_INCIDENT_LAST_UNHEALTHY_AT=""
ACTIVE_INCIDENT_HOSTNAME=""
declare -a incident_check_order=()
declare -A incident_statuses=()
declare -A incident_details=()

_incident_load(){
    ACTIVE_INCIDENT_ID="vw-test-recovery-retry"
    ACTIVE_INCIDENT_STARTED_AT="2026-07-20T01:00:00+00:00"
    ACTIVE_INCIDENT_LAST_UNHEALTHY_AT="2026-07-20T01:05:00+00:00"
    ACTIVE_INCIDENT_HOSTNAME="vaultwarden-test"
    incident_check_order=("smtp:sidecar")
    incident_statuses["smtp:sidecar"]="fail"
    incident_details["smtp:sidecar"]="Simulated recovery delivery failure"
}

_incident_format_duration(){
    printf '5m (300s)'
}

install -d -m 0700 "$ALERT_LOCK_DIR"
: > "$ACTIVE_INCIDENT_FILE"

first_rc=0
_notify_recovery >"$TMP/first.out" 2>&1 || first_rc=$?
[[ "$first_rc" -ne 0 ]] || fail "failed recovery delivery returned success"
[[ "$send_attempts" -eq 1 ]] || fail "failed recovery delivery was not attempted exactly once"
[[ -e "$ACTIVE_INCIDENT_FILE" ]] \
    || fail "failed recovery delivery removed active incident state"
[[ ! -e "$ALERT_LOCK_DIR/recovery.cooldown" ]] \
    || fail "failed recovery delivery retained recovery cooldown state"
! grep -Fq 'Recovery notification sent' "$TMP/first.out" \
    || fail "failed recovery delivery produced sent wording"
grep -Fq 'cooldown released for retry next health cycle' "$TMP/first.out" \
    || fail "failed recovery delivery did not report retryable cooldown release"

_notify_recovery >"$TMP/second.out" 2>&1 \
    || { cat "$TMP/second.out" >&2; fail "subsequent recovery notification attempt did not succeed"; }
[[ "$send_attempts" -eq 2 ]] \
    || fail "released recovery cooldown did not permit a subsequent delivery attempt"
[[ -e "$ALERT_LOCK_DIR/recovery.cooldown" ]] \
    || fail "successful recovery delivery did not retain its cooldown state"
[[ ! -e "$ACTIVE_INCIDENT_FILE" ]] \
    || fail "successful recovery delivery retained active incident state"
grep -Fq 'Recovery notification sent' "$TMP/second.out" \
    || fail "successful subsequent recovery delivery omitted sent wording"

printf 'Recovery notification failure remains truthful and retryable.\n'
)

check_recovery_notification_retry_contract

check_health_incident_context() (
set -euo pipefail

ROOT="${VW_TEST_ROOT:-$VW_TEST_REPO_ROOT}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log_info(){ :; }
log_warn(){ printf 'WARN: %s\n' "$*"; }
log_debug(){ :; }

# shellcheck source=lib/health-alerts.sh
source "$ROOT/lib/health-alerts.sh"

ALERT_LOCK_DIR="$TMP/alerts"
ACTIVE_INCIDENT_FILE="$ALERT_LOCK_DIR/active-incident.state"
RECOVERY_DELIVERY_STATE_FILE="$ALERT_LOCK_DIR/recovery-delivery.state"
ALERT_COOLDOWN_SECONDS=3600
ALERT_RECOVERY_TTL=86400
ALERT_RECOVERY_PENDING_TTL=30
HEALTH_ALERT_STATE_LOCK_FD=""
RECOVERY_DELIVERY_PHASE=""
RECOVERY_DELIVERY_INCIDENT_ID=""
RECOVERY_DELIVERY_UPDATED_AT=""
ACTIVE_INCIDENT_AVAILABLE=false
ACTIVE_INCIDENT_ID=""
ACTIVE_INCIDENT_STARTED_AT=""
ACTIVE_INCIDENT_LAST_UNHEALTHY_AT=""
ACTIVE_INCIDENT_HOSTNAME=""
declare -A check_results=(["docker:vaultwarden"]="fail")
declare -A check_messages=(["docker:vaultwarden"]=$'container stopped\npassword=topsecret')
declare -a check_order=("docker:vaultwarden")
declare -A incident_statuses=()
declare -A incident_details=()
declare -a incident_check_order=()
failed=1
warnings=0
passed=8

_incident_update_unhealthy || fail "first unhealthy run did not create incident state"
[[ -f "$ACTIVE_INCIDENT_FILE" ]] || fail "active incident file is missing"
mode="$(stat -c '%a' "$ACTIVE_INCIDENT_FILE" 2>/dev/null || stat -f '%Lp' "$ACTIVE_INCIDENT_FILE")"
[[ "$mode" == "600" ]] || fail "active incident mode is $mode instead of 600"
first_id="$ACTIVE_INCIDENT_ID"
first_start="$ACTIVE_INCIDENT_STARTED_AT"
[[ -n "$first_id" && -n "$first_start" ]] || fail "incident identity metadata is missing"
! grep -Fq 'topsecret' "$ACTIVE_INCIDENT_FILE" || fail "secret-like detail was persisted"
grep -Fq 'password=[REDACTED]' "$ACTIVE_INCIDENT_FILE" || fail "secret-like detail was not redacted"

check_results["docker:vaultwarden"]="warn"
check_messages["docker:vaultwarden"]="container is recovering"
failed=0
warnings=1
_incident_update_unhealthy || fail "subsequent unhealthy update failed"
[[ "$ACTIVE_INCIDENT_ID" == "$first_id" ]] || fail "incident ID changed during active incident"
[[ "$ACTIVE_INCIDENT_STARTED_AT" == "$first_start" ]] || fail "incident start changed during active incident"
grep -Fq $'check\tdocker:vaultwarden\twarn\tcontainer is recovering' "$ACTIVE_INCIDENT_FILE" \
    || fail "latest check status/detail was not persisted"

captured_subject=""
captured_body=""
_send_notification(){ captured_subject="$1"; captured_body="$2"; return 0; }
_notify_failures || fail "incident failure notification failed"
[[ "$captured_subject" == *"Incident ${first_id}"* ]] || fail "failure subject omitted incident ID"
[[ "$captured_body" == *"Incident: ${first_id}"* ]] || fail "failure body omitted incident ID"
printf '123\n' > "$ALERT_LOCK_DIR/unrelated-check.cooldown"

failed=0
warnings=0
passed=12
captured_subject=""
captured_body=""
_notify_recovery || fail "incident recovery notification failed"
[[ "$captured_subject" == *"RECOVERED [Incident ${first_id}]"* ]] || fail "recovery subject omitted incident ID"
[[ "$captured_body" == *"docker:vaultwarden [WARN]: container is recovering"* ]] \
    || fail "recovery body omitted preceding unhealthy check context"
[[ "$captured_body" == *"Duration:"* && "$captured_body" == *"Current totals:"* ]] \
    || fail "recovery body omitted duration or totals"
[[ ! -e "$ACTIVE_INCIDENT_FILE" ]] || fail "successful recovery retained active incident state"
[[ -e "$ALERT_LOCK_DIR/unrelated-check.cooldown" ]] || fail "successful recovery cleared a per-check cooldown"

check_results["docker:vaultwarden"]="fail"
check_messages["docker:vaultwarden"]="second incident"
failed=1
warnings=0
_incident_update_unhealthy || fail "could not create second incident"
second_id="$ACTIVE_INCIDENT_ID"
_release_recovery_cooldown
failed=0
warnings=0
_send_notification(){ return 22; }
if _notify_recovery > "$TMP/recovery-failed.out" 2>&1; then
    fail "failed recovery email returned success"
fi
[[ -e "$ACTIVE_INCIDENT_FILE" ]] || fail "failed recovery email removed incident state"
grep -Fq "$second_id" "$ACTIVE_INCIDENT_FILE" || fail "failed recovery retained the wrong incident"

blocked_parent="$TMP/not-a-directory"
printf 'x' > "$blocked_parent"
ALERT_LOCK_DIR="$blocked_parent"
ACTIVE_INCIDENT_FILE="$blocked_parent/active-incident.state"
ACTIVE_INCIDENT_AVAILABLE=false
failed=1
warnings=0
before_failed="$failed"
if _incident_update_unhealthy > "$TMP/unwritable.out" 2>&1; then
    fail "incident persistence unexpectedly succeeded with unavailable state path"
fi
[[ "$failed" == "$before_failed" ]] || fail "incident persistence changed health counters"
grep -Fq 'is not a real directory; health alert state tracking is disabled' "$TMP/unwritable.out" \
    || fail "unavailable incident state did not emit a bounded warning"

ALERT_LOCK_DIR="$TMP/bounded-alerts"
ACTIVE_INCIDENT_FILE="$ALERT_LOCK_DIR/active-incident.state"
ACTIVE_INCIDENT_AVAILABLE=false
ACTIVE_INCIDENT_ID=""
incident_statuses=()
incident_details=()
incident_check_order=()
long_detail="$(printf 'A%.0s' {1..2000})"$'\001\napi_token=verysecret'
check_messages["docker:vaultwarden"]="$long_detail"
_incident_update_unhealthy || fail "bounded incident write failed"
[[ "$(wc -c < "$ACTIVE_INCIDENT_FILE")" -le 16384 ]] || fail "incident state exceeded total size cap"
! grep -Fq 'verysecret' "$ACTIVE_INCIDENT_FILE" || fail "API token leaked into incident state"
detail_length="$(awk -F '\t' '$1=="check" {print length($4); exit}' "$ACTIVE_INCIDENT_FILE")"
[[ "$detail_length" -le 512 ]] || fail "incident detail exceeded per-check cap"

! grep -Eq '^[[:space:]]*chown[[:space:]]' "$ROOT/lib/health-alerts.sh" \
    || fail "health incident code hardcodes alert-directory ownership changes"
! grep -Fq 'active-incident.state' "$ROOT/lib/common.sh" \
    || fail "incident state was added to central known-path permissions"
! grep -Fq 'active-incident.state' "$ROOT/lib/runtime-permissions.sh" \
    || fail "incident state was added to runtime permission repair"

printf 'Health incident context tests passed.\n'
)

check_health_incident_context
