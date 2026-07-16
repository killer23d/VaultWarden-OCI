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
check_recovery_kit_attachment_passphrase_contract() (
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if grep -En '7z[[:space:]].*-p|zip[[:space:]].*(--password|-P)|ZIP_PASSWORD|vw-enc-pass|_pass_file' "$ROOT/lib/secrets.sh" >"$TMP/source.matches"; then
    cat "$TMP/source.matches" >&2
    fail 'recovery-kit attachment helper must not use secret-bearing archiver argv, environment handoff, or passphrase temp files'
fi
if grep -En 'openssl[[:space:]]+enc|aes-256-cbc|tar\.'"enc" "$ROOT/lib/secrets.sh" >"$TMP/source.matches"; then
    cat "$TMP/source.matches" >&2
    fail 'recovery-kit helper must not retain the obsolete encrypted-tar format'
fi
grep -Fq 'prompt_password_with_confirmation \' "$ROOT/lib/secrets.sh" \
    || fail 'attachment helper must use the existing password confirmation helper'
grep -Fq '"Passphrase to encrypt emailed attachment" 16' "$ROOT/lib/secrets.sh" \
    || fail 'attachment helper must enforce the 16-character minimum through the password helper'
grep -Fq "printf 'gpg'" "$ROOT/lib/secrets.sh" \
    || fail 'recovery-kit email dependency helper must select gpg'
grep -Fq -- '--passphrase-fd 3' "$ROOT/lib/secrets.sh" \
    || fail 'attachment helper must pass the secret to GnuPG through fd 3'
grep -Fq -- '--no-symkey-cache' "$ROOT/lib/secrets.sh" \
    || fail 'attachment helper must disable GnuPG symmetric passphrase caching'
grep -Fq -- '3<<<"$_enc_pass"' "$ROOT/lib/secrets.sh" \
    || fail 'attachment helper must feed the passphrase through fd 3'
grep -Fq 'set +x' "$ROOT/lib/secrets.sh" \
    || fail 'attachment helper must disable xtrace while the passphrase is live'
grep -Fq 'unset _enc_pass' "$ROOT/lib/secrets.sh" \
    || fail 'attachment helper must unset the passphrase promptly'
! grep -En -- '(^|[[:space:]])--passphrase([=[:space:]]|$)|--passphrase-file|RECOVERY_PASSWORD|passphrase-file' "$ROOT/lib/secrets.sh" >"$TMP/source.matches" \
    || { cat "$TMP/source.matches" >&2; fail 'attachment helper must not use argv, environment, or temp-file passphrase handoff'; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gpg" <<'MOCK_GPG'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_ARGV_FILE"
export -p > "$MOCK_ENV_FILE"
cat <&3 > "$MOCK_FD_FILE"
out=""
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--output" ]]; then
        out="$2"
        shift 2
        continue
    fi
    shift
done
cat > "$MOCK_STDIN_FILE"
cp "$MOCK_STDIN_FILE" "$out"
MOCK_GPG
chmod +x "$TMP/bin/gpg"

plaintext="$TMP/recovery-kit.txt"
printf 'test recovery kit\n' > "$plaintext"
sentinel='TEST_ATTACHMENT_SECRET_1234567890'

run_encrypt_with_prompt() {
    local prompt_body="$1" out_file="$2"
    (
        cd "$ROOT"
        PATH="$TMP/bin:$PATH"
        export PATH
        # shellcheck source=../lib/secrets.sh
        source "$ROOT/lib/secrets.sh"
        prompt_password_with_confirmation(){ eval "$prompt_body"; }
        MOCK_ARGV_FILE="$TMP/gpg.argv"
        MOCK_ENV_FILE="$TMP/gpg.env"
        MOCK_FD_FILE="$TMP/gpg.fd"
        MOCK_STDIN_FILE="$TMP/gpg.stdin"
        export MOCK_ARGV_FILE MOCK_ENV_FILE MOCK_FD_FILE MOCK_STDIN_FILE
        _encrypt_recovery_kit_attachment "$plaintext" "$out_file" gpg
    )
}

short_prompt='return 1'
if run_encrypt_with_prompt "$short_prompt" "$TMP/short.enc"; then
    fail 'short passphrase validation failure must reject before archive success'
fi
[[ ! -s "$TMP/short.enc" ]] || fail 'short passphrase rejection must not leave a successful archive'

mismatch_prompt='return 1'
if run_encrypt_with_prompt "$mismatch_prompt" "$TMP/mismatch.enc"; then
    fail 'confirmation mismatch validation failure must reject before archive success'
fi
[[ ! -s "$TMP/mismatch.enc" ]] || fail 'confirmation mismatch must not leave a successful archive'

exact16='1234567890abcdef'
run_encrypt_with_prompt "printf %s '$exact16'" "$TMP/exact.enc" \
    || fail 'matching 16-character passphrase should be accepted'
longer='1234567890abcdefghi'
run_encrypt_with_prompt "printf %s '$longer'" "$TMP/long.enc" \
    || fail 'matching longer passphrase should be accepted'

run_encrypt_with_prompt "printf %s '$sentinel'" "$TMP/sentinel.enc" \
    || fail 'sentinel encryption should succeed'
! grep -Fq "$sentinel" "$TMP/gpg.argv" \
    || fail 'GnuPG argv contains sentinel secret'
! grep -Fq "$sentinel" "$TMP/gpg.env" \
    || fail 'GnuPG environment contains sentinel secret'
grep -Fq "$sentinel" "$TMP/gpg.fd" \
    || fail 'GnuPG did not receive passphrase through fd capture'
tar -tf "$TMP/gpg.stdin" | grep -Fxq 'recovery-kit.txt' \
    || fail 'tar payload was not supplied on stdin to GnuPG'
require_gpg_arg() {
    local arg="$1"
    grep -Fxq -- "$arg" "$TMP/gpg.argv" || fail "GnuPG argv missing required option: $arg"
}
require_gpg_arg '--batch'
require_gpg_arg '--yes'
require_gpg_arg '--pinentry-mode'
require_gpg_arg 'loopback'
require_gpg_arg '--passphrase-fd'
require_gpg_arg '3'
require_gpg_arg '--no-symkey-cache'
require_gpg_arg '--symmetric'
require_gpg_arg '--output'
! grep -Eq -- '(^|[[:space:]])(--passphrase|--passphrase-file|--password|-P)([=[:space:]]|$)' "$TMP/gpg.argv" \
    || fail 'secret-bearing password argv appeared unexpectedly'

if command -v gpg >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
    smoke_dir="$TMP/smoke"
    mkdir -p "$smoke_dir/out" "$smoke_dir/gnupg"
    chmod 700 "$smoke_dir/gnupg"
    printf 'real archive sentinel content\n' > "$smoke_dir/recovery-kit.txt"
    (
        cd "$ROOT"
        GNUPGHOME="$smoke_dir/gnupg"
        export GNUPGHOME
        # shellcheck source=../lib/secrets.sh
        source "$ROOT/lib/secrets.sh"
        prompt_password_with_confirmation(){ printf '%s' 'NonProdTestPassphrase16'; }
        _encrypt_recovery_kit_attachment "$smoke_dir/recovery-kit.txt" "$smoke_dir/kit.tar.gpg" gpg
    )
    [[ -s "$smoke_dir/kit.tar.gpg" ]] || fail 'real GnuPG archive was not created'
    ! LC_ALL=C grep -aFq 'real archive sentinel content' "$smoke_dir/kit.tar.gpg" \
        || fail 'real GnuPG archive contains plaintext sentinel content'
    gpg_decrypt_with_fd() (
        local input_file="$1" output_file="$2" passphrase="$3"
        GNUPGHOME="$smoke_dir/gnupg"
        export GNUPGHOME
        gpg \
            --batch \
            --yes \
            --pinentry-mode loopback \
            --passphrase-fd 3 \
            --no-symkey-cache \
            --output "$output_file" \
            --decrypt "$input_file" \
            3<<<"$passphrase" >/dev/null 2>&1
    )
    gpg_decrypt_with_fd "$smoke_dir/kit.tar.gpg" "$smoke_dir/kit.tar" 'NonProdTestPassphrase16' \
        || fail 'real GnuPG archive did not decrypt with the correct passphrase'
    if gpg_decrypt_with_fd "$smoke_dir/kit.tar.gpg" "$smoke_dir/wrong.tar" 'WrongNonProdPassphrase16'; then
        fail 'real GnuPG archive decrypted with the wrong passphrase'
    fi
    tar -C "$smoke_dir/out" -xf "$smoke_dir/kit.tar"
    cmp "$smoke_dir/recovery-kit.txt" "$smoke_dir/out/recovery-kit.txt" \
        || fail 'real archive extracted content mismatch'
    tampered="$smoke_dir/kit.tampered.tar.gpg"
    cp "$smoke_dir/kit.tar.gpg" "$tampered"
    orig_byte=$(od -An -tx1 -j 16 -N1 "$tampered" | tr -d ' \n')
    new_byte=00
    [[ "$orig_byte" == "00" ]] && new_byte=ff
    printf '%b' "\\x${new_byte}" | dd of="$tampered" bs=1 seek=16 count=1 conv=notrunc >/dev/null 2>&1
    if gpg_decrypt_with_fd "$tampered" "$smoke_dir/tampered.tar" 'NonProdTestPassphrase16'; then
        fail 'tampered GnuPG archive decrypted successfully'
    fi
else
    printf 'Real GnuPG recovery-kit attachment smoke test skipped: gpg or tar unavailable.\n'
fi

printf 'Recovery-kit attachment passphrase contract tests passed.\n'
)

check_recovery_kit_attachment_passphrase_contract

check_recovery_notification_retry_contract() (
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

extract_func(){
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

HEALTH="$ROOT/utilities/maintenance-health.sh"
log_info(){ printf 'INFO: %s\n' "$*"; }
log_warn(){ printf 'WARN: %s\n' "$*"; }
eval "$(extract_func "$HEALTH" _ensure_alert_dir)"
eval "$(extract_func "$HEALTH" _acquire_alert_lock)"
eval "$(extract_func "$HEALTH" _release_recovery_lock)"
eval "$(extract_func "$HEALTH" _send_notification | sed '1s/^_send_notification()/_send_notification_production()/')"
eval "$(extract_func "$HEALTH" _notify_recovery)"

_email_available=false
ADMIN_EMAIL=admin@example.test
export ADMIN_EMAIL
unavailable_rc=0
_send_notification_production subject body >"$TMP/unavailable.out" 2>&1 || unavailable_rc=$?
[[ "$unavailable_rc" -ne 0 ]] \
    || fail "email-unavailable notification path reported successful delivery"

ALERT_LOCK_DIR="$TMP/alerts"
ACTIVE_INCIDENT_FILE="$ALERT_LOCK_DIR/active-incident.state"
ALERT_RECOVERY_TTL=86400
failed=0
warnings=0
passed=12
export ALERT_RECOVERY_TTL failed warnings passed
send_attempts=0
_send_notification(){
    send_attempts=$((send_attempts + 1))
    if (( send_attempts == 1 )); then return 42; fi
    return 0
}

first_rc=0
_notify_recovery >"$TMP/first.out" 2>&1 || first_rc=$?
[[ "$first_rc" -ne 0 ]] || fail "failed recovery delivery returned success"
[[ "$send_attempts" -eq 1 ]] || fail "failed recovery delivery was not attempted exactly once"
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
grep -Fq 'Recovery notification sent' "$TMP/second.out" \
    || fail "successful subsequent recovery delivery omitted sent wording"

printf 'Recovery notification failure remains truthful and retryable.\n'
)

check_recovery_notification_retry_contract

# Variables in this behavioral harness are consumed by dynamically extracted
# production functions.
# shellcheck disable=SC2034
check_health_incident_context() (
set -euo pipefail

ROOT="${VW_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log_info(){ :; }
log_warn(){ printf 'WARN: %s\n' "$*"; }
log_debug(){ :; }

extract_func(){
    local file="$1" func="$2"
    awk -v f="$func" '
      $0 ~ "^" f "\\(\\)" {p=1}
      p {
        print
        opens=gsub(/\{/ ,"{"); closes=gsub(/\}/,"}")
        depth += opens - closes
        if (depth == 0) exit
      }' "$file"
}

HEALTH="$ROOT/utilities/maintenance-health.sh"
eval "$(extract_func "$HEALTH" _ensure_alert_dir)"
eval "$(extract_func "$HEALTH" _acquire_alert_lock)"
eval "$(extract_func "$HEALTH" _release_alert_lock)"
eval "$(extract_func "$HEALTH" _release_recovery_lock)"
sed -n '/^_incident_sanitize()/,/^local -A check_results=/p' "$HEALTH" | sed '$d' > "$TMP/incident-functions.sh"
# shellcheck source=/dev/null
source "$TMP/incident-functions.sh"
eval "$(extract_func "$HEALTH" _notify_failures)"
eval "$(extract_func "$HEALTH" _notify_recovery)"

ALERT_LOCK_DIR="$TMP/alerts"
ACTIVE_INCIDENT_FILE="$ALERT_LOCK_DIR/active-incident.state"
ALERT_COOLDOWN_SECONDS=3600
ALERT_RECOVERY_TTL=86400
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
mode="$(stat -f '%Lp' "$ACTIVE_INCIDENT_FILE" 2>/dev/null || stat -c '%a' "$ACTIVE_INCIDENT_FILE")"
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
_release_recovery_lock
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
grep -Fq 'continuing without incident correlation' "$TMP/unwritable.out" \
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

! grep -Eq '^[[:space:]]*chown[[:space:]]' "$TMP/incident-functions.sh" \
    || fail "health incident code hardcodes alert-directory ownership changes"
! grep -Fq 'active-incident.state' "$ROOT/lib/common.sh" \
    || fail "incident state was added to central known-path permissions"
! grep -Fq 'active-incident.state' "$ROOT/lib/runtime-permissions.sh" \
    || fail "incident state was added to runtime permission repair"

printf 'Health incident context tests passed.\n'
)

check_health_incident_context
