#!/usr/bin/env bash
# Consolidated email regression suite.
set -euo pipefail

check_maintenance_email_root_contract() (
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
check_email_delivery_refactor_contracts() (
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

run_case() {
    local name="$1" script="$2" out rc
    set +e
    out=$(ROOT="$ROOT" bash -c "$script" 2>&1)
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

common_prelude='cd "$ROOT"; source lib/log.sh >/dev/null 2>&1 || true; source lib/email.sh; log_info(){ :; }; log_warn(){ TRACE+=" warn:$*"; }; log_error(){ TRACE+=" error:$*"; }; log_success(){ :; }; log_debug(){ :; }; log_hint(){ :; }; register_cleanup(){ CLEANUPS+=("$*"); }; reset_env(){ CLEANUPS=(); TRACE=""; CURL_ARGS=""; CAPTURED=""; EMAIL_MODE=auto EMAIL_PROVIDER=mailersend ADMIN_EMAIL=admin@example.com SMTP_FROM=noreply@example.com SMTP_FROM_NAME=VaultWarden SMTP_HOST=smtp.example.com SMTP_PORT=587 SMTP_USERNAME=user SMTP_PASSWORD="p a\"s\\w" SMTP_SECURITY= EMAIL_API_TOKEN=token EMAIL_RATE_WINDOW_SECONDS=0 PROJECT_ROOT="$ROOT"; export EMAIL_MODE EMAIL_PROVIDER ADMIN_EMAIL SMTP_FROM SMTP_FROM_NAME SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_SECURITY EMAIL_API_TOKEN EMAIL_RATE_WINDOW_SECONDS PROJECT_ROOT; }'

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
check_recovery_kit_attachment_passphrase_argv_contract() (
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if grep -En 'zip[[:space:]].*--password|7z[[:space:]].*-p\$\(|cat "\$_pass_file"|vw-enc-pass' "$ROOT/lib/secrets.sh" >/tmp/vw-recovery-argv.$$; then
    cat /tmp/vw-recovery-argv.$$ >&2
    rm -f /tmp/vw-recovery-argv.$$
    fail 'recovery-kit attachment helper must not construct secret-bearing archiver argv'
fi
rm -f /tmp/vw-recovery-argv.$$
grep -Fq '7z a -tzip -mem=ZipCrypto -mx=0 \' "$ROOT/lib/secrets.sh" \
    || fail '7z attachment path missing expected archive command'
grep -Fq -- '-p \' "$ROOT/lib/secrets.sh" \
    || fail '7z attachment path must use bare interactive -p switch'
grep -Fq 'zip -0 --encrypt \' "$ROOT/lib/secrets.sh" \
    || fail 'zip attachment path must use interactive --encrypt mode'

mkdir -p "$TMP/bin"
cat > "$TMP/bin/7z" <<'MOCK_7Z'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_ARGV_FILE"
touch "$6"
MOCK_7Z
cat > "$TMP/bin/zip" <<'MOCK_ZIP'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_ARGV_FILE"
touch "$3"
MOCK_ZIP
chmod +x "$TMP/bin/7z" "$TMP/bin/zip"

plaintext="$TMP/recovery-kit.txt"
printf 'test recovery kit\n' > "$plaintext"

(
    cd "$ROOT"
    PATH="$TMP/bin:$PATH"
    export PATH
    # shellcheck source=../lib/secrets.sh
    source "$ROOT/lib/secrets.sh"
    MOCK_ARGV_FILE="$TMP/7z.argv"
    export MOCK_ARGV_FILE
    _encrypt_recovery_kit_attachment "$plaintext" "$TMP/kit-7z.zip" 7z
)
! grep -Fq 'TEST_ATTACHMENT_SECRET' "$TMP/7z.argv" \
    || fail '7z argv contains sentinel secret'
grep -Fxq -- '-p' "$TMP/7z.argv" \
    || fail '7z argv did not include the bare interactive -p switch'
! grep -Eq '^-p.+' "$TMP/7z.argv" \
    || fail '7z argv used an inline password form'

(
    cd "$ROOT"
    PATH="$TMP/bin:$PATH"
    export PATH
    # shellcheck source=../lib/secrets.sh
    source "$ROOT/lib/secrets.sh"
    MOCK_ARGV_FILE="$TMP/zip.argv"
    export MOCK_ARGV_FILE
    _encrypt_recovery_kit_attachment "$plaintext" "$TMP/kit-zip.zip" zip
)
! grep -Fq 'TEST_ATTACHMENT_SECRET' "$TMP/zip.argv" \
    || fail 'zip argv contains sentinel secret'
grep -Fxq -- '--encrypt' "$TMP/zip.argv" \
    || fail 'zip argv did not include interactive --encrypt'
! grep -Fxq -- '--password' "$TMP/zip.argv" \
    || fail 'zip argv must not include --password'

printf 'Recovery-kit attachment argv secrecy tests passed.\n'
)

check_recovery_kit_attachment_passphrase_argv_contract
