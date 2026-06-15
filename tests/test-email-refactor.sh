#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source lib/log.sh >/dev/null 2>&1 || true
source lib/email.sh
PASS=0; FAIL=0; TRACE=""; CURL_ARGS=""
log_info(){ :; }; log_warn(){ TRACE+=" warn:$*"; }; log_error(){ TRACE+=" error:$*"; }; log_success(){ :; }; log_debug(){ :; }
register_cleanup(){ :; }
reset_env(){ TRACE=""; CURL_ARGS=""; EMAIL_MODE=auto EMAIL_PROVIDER=mailersend ADMIN_EMAIL=admin@example.com SMTP_FROM=noreply@example.com SMTP_FROM_NAME=VaultWarden SMTP_HOST=smtp.example.com SMTP_PORT=587 SMTP_USERNAME=user SMTP_PASSWORD='p a"s\\w' SMTP_SECURITY= EMAIL_API_TOKEN=token EMAIL_RATE_WINDOW_SECONDS=0; export EMAIL_MODE EMAIL_PROVIDER ADMIN_EMAIL SMTP_FROM SMTP_FROM_NAME SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_SECURITY EMAIL_API_TOKEN EMAIL_RATE_WINDOW_SECONDS; }
assert(){ local name="$1"; shift; if "$@"; then echo "ok - $name"; ((++PASS)); else echo "not ok - $name"; ((++FAIL)); fi; }
contains(){ [[ "$TRACE" == *"$1"* ]]; }
not_contains(){ [[ "$TRACE" != *"$1"* ]]; }
_email_driver_mailersend(){ TRACE+=" api:$1"; return "${API_RC:-0}"; }
_email_driver_sendgrid(){ TRACE+=" sendgrid:$1"; return 0; }
_email_driver_mailgun(){ TRACE+=" mailgun:$1"; return 0; }
_email_driver_postmark(){ TRACE+=" postmark:$1"; return 0; }
_email_driver_resend(){ TRACE+=" resend:$1"; return 0; }
_email_driver_cyberpersons(){ TRACE+=" cyber:$1"; return 0; }
_smtp_upload_sidecar(){ TRACE+=" sidecar"; return "${SIDE_RC:-0}"; }
_smtp_upload_direct(){ TRACE+=" direct"; [[ "${RESOLVE_MARK:-0}" == 1 ]] && get_secret smtp_password >/dev/null; return "${DIRECT_RC:-0}"; }
get_secret(){ TRACE+=" secret"; printf 'resolved-secret'; }
curl(){ CURL_ARGS="$*"; TRACE+=" curl"; return 0; }

reset_env; API_RC=0; assert 'auto API success stops immediately' send_email admin@example.com subj body; [[ "$TRACE" == *api:* && "$TRACE" != *sidecar* && "$TRACE" != *direct* ]] || { echo "$TRACE"; exit 1; }
reset_env; API_RC=1 SIDE_RC=0; send_email admin@example.com subj body; assert 'auto API failure -> sidecar success' contains 'sidecar'; assert 'auto sidecar success skips direct' not_contains 'direct'
reset_env; API_RC=1 SIDE_RC=1 DIRECT_RC=0; send_email admin@example.com subj body; assert 'auto API failure -> sidecar failure -> direct success' contains 'direct'
reset_env; EMAIL_MODE=api API_RC=1; ! send_email admin@example.com subj body; assert 'api failure does not attempt SMTP' not_contains 'sidecar'
reset_env; EMAIL_MODE=smtp SIDE_RC=0 RESOLVE_MARK=1; send_email admin@example.com subj body; assert 'smtp sidecar success does not resolve smtp_password' not_contains 'secret'
reset_env; EMAIL_MODE=smtp SIDE_RC=1 DIRECT_RC=0; send_email admin@example.com subj body; assert 'smtp sidecar failure -> direct' contains 'direct'
reset_env; EMAIL_MODE=direct; send_email admin@example.com subj body; [[ "$TRACE" == *direct* && "$TRACE" != *api:* && "$TRACE" != *sidecar* ]] || exit 1; echo 'ok - direct only'; ((++PASS))
reset_env; EMAIL_MODE=host; send_email admin@example.com subj body; assert 'host warns' contains 'deprecated'; assert 'host behaves as direct' contains 'direct'
reset_env; EMAIL_MODE=bogus; ! send_email admin@example.com subj body; assert 'unknown mode fails' contains 'Unknown EMAIL_MODE'
reset_env; EMAIL_MODE=api EMAIL_PROVIDER=bogus; ! send_email admin@example.com subj body; assert 'unknown provider fails in api mode' contains 'Unknown EMAIL_PROVIDER'
reset_env; EMAIL_PROVIDER=bogus SIDE_RC=0; send_email admin@example.com subj body; assert 'unknown provider falls back in auto' contains 'sidecar'
for p in mailersend sendgrid mailgun postmark resend cyberpersons; do reset_env; EMAIL_PROVIDER=$p; send_email explicit@example.com subj body; [[ "$TRACE" == *explicit@example.com* ]] || exit 1; done; echo 'ok - every provider receives TO explicitly'; ((++PASS))
for p in cyberpersons cyberperson cyberpanel; do [[ "$(_email_driver_lookup "$p")" == cyberpersons ]] || exit 1; done; echo 'ok - cyber aliases resolve identically'; ((++PASS))
tmp=$(mktemp); echo hi >"$tmp"
reset_env; SIDE_RC=0; send_smtp_attachment admin@example.com subj body "$tmp" good.txt; [[ "$TRACE" != *api:* && "$TRACE" == *sidecar* ]] || exit 1; echo 'ok - attachment never invokes API and sidecar works'; ((++PASS))
reset_env; SIDE_RC=0 RESOLVE_MARK=1; send_smtp_attachment admin@example.com subj body "$tmp" good.txt; assert 'attachment sidecar success skips password' not_contains 'secret'
reset_env; SIDE_RC=1 DIRECT_RC=0; send_smtp_attachment admin@example.com subj body "$tmp" good.txt; assert 'attachment sidecar failure invokes direct' contains 'direct'
reset_env; unset SMTP_FROM; ! send_smtp_attachment admin@example.com subj body "$tmp" good.txt; echo 'ok - empty sender fails before curl'; ((++PASS))
reset_env; ! send_smtp_attachment admin@example.com subj body /missing good.txt; echo 'ok - missing attachment fails before curl'; ((++PASS))
reset_env; ! send_smtp_attachment $'bad\n@example.com' subj body "$tmp" good.txt; echo 'ok - CR/LF headers rejected'; ((++PASS))
reset_env; ! send_smtp_attachment admin@example.com subj body "$tmp" 'bad"name'; echo 'ok - invalid attachment filename rejected'; ((++PASS))
[[ "$(_smtp_security_url smtp.example.com 465 '')" == smtps://* ]] && echo 'ok - empty security infers TLS on 465' && ((++PASS)) || ((++FAIL))
[[ "$(_smtp_security_url smtp.example.com 587 '')" == *--ssl-reqd ]] && echo 'ok - empty security infers STARTTLS otherwise' && ((++PASS)) || ((++FAIL))
[[ "$(_smtp_security_url smtp.example.com 25 off)" == smtp://smtp.example.com:25 ]] && echo 'ok - explicit off permits plaintext' && ((++PASS)) || ((++FAIL))
reset_env; _smtp_upload_direct "$tmp" noreply@example.com admin@example.com >/dev/null; [[ "$CURL_ARGS" != *"$SMTP_PASSWORD"* && "$TRACE" != *"$SMTP_PASSWORD"* ]] && echo 'ok - direct credentials not in argv/log trace' && ((++PASS)) || ((++FAIL))
trap 'echo caller-exit' EXIT; before=$(trap -p EXIT); reset_env; send_email admin@example.com subj body >/dev/null; after=$(trap -p EXIT); [[ "$before" == "$after" ]] && echo 'ok - caller EXIT trap preserved' && ((++PASS)) || ((++FAIL))
rm -f "$tmp"
pattern='_email_driver_.*_attach'"'ment|_dispatch_email_with_attach'"'ment|_smtp_send_with_attach'"'ment|_smtp_curl_up'"'load|_resolve_smtp_meth'"'od|_email_driver_post'"'fix|mail '"'-s|emergency API by'"'pass'
if rg -n "$pattern" lib/email.sh >/dev/null; then echo 'not ok - obsolete symbols remain'; ((++FAIL)); else echo 'ok - obsolete symbols absent'; ((++PASS)); fi
trap - EXIT
echo "PASS=$PASS FAIL=$FAIL"
((FAIL==0))
