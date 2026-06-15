#!/usr/bin/env bash
# lib/email.sh — Email delivery helpers for VaultWarden-OCI.

[[ -n "${VAULTWARDEN_EMAIL_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_EMAIL_LIB_LOADED=1

_VW_EMAIL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${VW_LOG_LIB_LOADED:-}" ]] || source "${_VW_EMAIL_LIB_DIR}/log.sh"
unset _VW_EMAIL_LIB_DIR

_ECURL_CODE=""
_ECURL_BODY=""

declare -Ar _EMAIL_PROVIDER_ALIASES=(
    [mailgun]=mailgun
    [mailersend]=mailersend
    [sendgrid]=sendgrid
    [postmark]=postmark
    [resend]=resend
    [cyberpersons]=cyberpersons
    [cyberperson]=cyberpersons
    [cyberpanel]=cyberpersons
)

_email_has_ctl() { [[ "$1" == *$'\r'* || "$1" == *$'\n'* || "$1" =~ [[:cntrl:]] ]]; }
_email_has_nul() { [[ "$1" == *$'\0'* ]]; }
_email_validate_header() { local n="$1" v="$2"; if _email_has_ctl "$v"; then log_error "${n}: header value contains a control character"; return 1; fi; }
_email_validate_addr() { local n="$1" v="$2"; [[ -n "$v" ]] || { log_error "${n}: address is empty"; return 1; }; _email_validate_header "$n" "$v"; }

resolve_email_sender() {
    if [[ -n "${SMTP_FROM:-}" ]]; then printf '%s' "$SMTP_FROM"; return 0; fi
    if [[ -n "${SMTP_FROM_EMAIL:-}" ]]; then
        log_warn "SMTP_FROM_EMAIL is deprecated; set SMTP_FROM instead."
        printf '%s' "$SMTP_FROM_EMAIL"; return 0
    fi
    log_error "SMTP_FROM is required; SMTP_FROM_EMAIL is only a deprecated compatibility alias."
    return 1
}

_email_tmpfile() { mktemp -p /dev/shm "$1.XXXXXX" 2>/dev/null || mktemp -t "$1.XXXXXX"; }
_email_rm() { rm -f "$@" 2>/dev/null || true; }
_email_curl_quote() { local s="$1"; [[ "$s" != *$'\n'* && "$s" != *$'\r'* && "$s" != *$'\0'* ]] || return 1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
_email_http_common() {
    local url="$1" cfg_kind="$2" payload="${3:-}" username="${4:-}"; shift 4 || true
    local form_args=("$@") tmp cfg code token="${EMAIL_API_TOKEN:-}"
    _ECURL_CODE=000; _ECURL_BODY=""
    [[ -n "$token" ]] || { log_error "EMAIL_API_TOKEN is empty"; return 1; }
    for v in "$url" "$token" "$username"; do _email_has_ctl "$v" || _email_has_nul "$v" && { log_error "email HTTP helper: unsafe control character in input"; return 1; }; done
    tmp=$(_email_tmpfile vw-email-http-body) || return 1; cfg=$(_email_tmpfile vw-email-http-cfg) || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" "$cfg" 2>/dev/null || { rm -f "$tmp" "$cfg"; return 1; }
    if declare -f register_cleanup >/dev/null 2>&1; then register_cleanup _email_rm "$tmp" "$cfg"; fi
    case "$cfg_kind" in
        bearer) printf 'header = %s\n' "$(_email_curl_quote "Authorization: Bearer ${token}")" >"$cfg" || return 1 ;;
        basic)  printf 'user = %s\n' "$(_email_curl_quote "${username}:${token}")" >"$cfg" || return 1 ;;
        header) local h="${username}"; _email_has_ctl "$h" && { rm -f "$tmp" "$cfg"; return 1; }; printf 'header = %s\n' "$(_email_curl_quote "${h}: ${token}")" >"$cfg" || return 1 ;;
    esac
    local args=(curl -sS --config "$cfg" --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 2 --retry-all-errors -o "$tmp" -w '%{http_code}' -X POST "$url")
    if [[ "$cfg_kind" == basic ]]; then args+=("${form_args[@]}"); else args+=(-H 'Content-Type: application/json' --data-binary "$payload"); fi
    code=$("${args[@]}" 2> >(sed -E 's/(Authorization: Bearer )[[:graph:]]+/\1[REDACTED]/g' >&2)) || code="000"
    _ECURL_CODE="$code"; _ECURL_BODY=$(head -c 300 "$tmp" 2>/dev/null | tr -d '\r\n')
    rm -f "$tmp" "$cfg"
    [[ "$code" =~ ^2[0-9][0-9]$ ]]
}
_email_http_bearer_json() { _email_http_common "$1" bearer "$2" ""; }
_email_http_basic_form() { local url="$1" user="$2"; shift 2; _email_http_common "$url" basic "" "$user" "$@"; }
_email_http_custom_header_json() { _email_http_common "$1" header "$3" "$2"; }

_email_driver_lookup() { local p="${1,,}" c=""; c="${_EMAIL_PROVIDER_ALIASES[$p]:-}"; [[ -n "$c" && "$c" =~ ^[a-z_][a-z0-9_]*$ ]] || return 1; printf '%s' "$c"; }
_email_sender_name() { local n="${SMTP_FROM_NAME:-VaultWarden}"; _email_validate_header SMTP_FROM_NAME "$n" || return 1; printf '%s' "$n"; }

_email_driver_mailersend() { local to="$1" subject="$2" body="$3" from name payload; from=$(resolve_email_sender) || return 1; name=$(_email_sender_name) || return 1; payload=$(jq -n --arg from_email "$from" --arg from_name "$name" --arg to "$to" --arg subject "$subject" --arg text "$body" '{from:{email:$from_email,name:$from_name},to:[{email:$to}],subject:$subject,text:$text,settings:{track_clicks:false,track_opens:false}}') || return 1; _email_http_bearer_json "https://api.mailersend.com/v1/email" "$payload" || { log_warn "MailerSend API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"; return 1; }; }
_email_driver_sendgrid() { local to="$1" subject="$2" body="$3" from name payload; from=$(resolve_email_sender) || return 1; name=$(_email_sender_name) || return 1; payload=$(jq -n --arg from_email "$from" --arg from_name "$name" --arg to "$to" --arg subject "$subject" --arg text "$body" '{personalizations:[{to:[{email:$to}]}],from:{email:$from_email,name:$from_name},subject:$subject,content:[{type:"text/plain",value:$text}],tracking_settings:{click_tracking:{enable:false},open_tracking:{enable:false},subscription_tracking:{enable:false}}}') || return 1; _email_http_bearer_json "https://api.sendgrid.com/v3/mail/send" "$payload" || { log_warn "SendGrid API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"; return 1; }; }
_email_driver_mailgun() { local to="$1" subject="$2" body="$3" from domain host; from=$(resolve_email_sender) || return 1; domain="${MAILGUN_DOMAIN:-${from##*@}}"; [[ "$domain" =~ ^[a-zA-Z0-9.-]+$ ]] || { log_error "Mailgun driver: invalid domain '${domain}'."; return 1; }; case "${MAILGUN_REGION:-us}" in us) host=api.mailgun.net;; eu) host=api.eu.mailgun.net;; *) log_error "Mailgun driver: unrecognised MAILGUN_REGION='${MAILGUN_REGION:-}'. Valid: us eu"; return 1;; esac; _email_http_basic_form "https://${host}/v3/${domain}/messages" api -F "from=${SMTP_FROM_NAME:-VaultWarden} <${from}>" -F "to=${to}" -F "subject=${subject//$'\n'/ }" -F "text=${body}" -F "o:tracking=no" || { log_warn "Mailgun API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"; return 1; }; }
_email_driver_postmark() { local to="$1" subject="$2" body="$3" from name payload; from=$(resolve_email_sender) || return 1; name=$(_email_sender_name) || return 1; payload=$(jq -n --arg from_name "$name" --arg from_email "$from" --arg to "$to" --arg subject "$subject" --arg text "$body" '{From:($from_name+" <"+$from_email+">") ,To:$to,Subject:$subject,TextBody:$text,MessageStream:"outbound"}') || return 1; _email_http_custom_header_json "https://api.postmarkapp.com/email" "X-Postmark-Server-Token" "$payload" || { log_warn "Postmark API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"; return 1; }; printf '%s' "$_ECURL_BODY" | jq -e '.ErrorCode == 0' >/dev/null 2>&1 || { log_warn "Postmark API ErrorCode was not 0: ${_ECURL_BODY}"; return 1; }; }
_email_driver_resend() { local to="$1" subject="$2" body="$3" from name payload; from=$(resolve_email_sender) || return 1; name=$(_email_sender_name) || return 1; payload=$(jq -n --arg from_name "$name" --arg from_email "$from" --arg to "$to" --arg subject "$subject" --arg text "$body" '{from:($from_name+" <"+$from_email+">") ,to:[$to],subject:$subject,text:$text}') || return 1; _email_http_bearer_json "https://api.resend.com/emails" "$payload" || { log_warn "Resend API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"; return 1; }; }
_email_driver_cyberpersons() { local to="$1" subject="$2" body="$3" from name payload; from=$(resolve_email_sender) || return 1; name=$(_email_sender_name) || return 1; payload=$(jq -n --arg from_email "$from" --arg from_name "$name" --arg to "$to" --arg subject "$subject" --arg text "$body" '{from:{email:$from_email,name:$from_name},to:[{email:$to}],subject:$subject,text:$text}') || return 1; _email_http_bearer_json "https://platform.cyberpersons.com/email/v1/send" "$payload" || { log_warn "CyberPersons API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"; return 1; }; }

_normalise_email_subject() { local subject="$1"; [[ "$subject" != "[VaultWarden]"* ]] && subject="[VaultWarden] ${subject}"; printf '%s\n' "$subject"; }
_resolve_rate_limit_dir() { local d="${PROJECT_ROOT:-/tmp}/.rate-limit"; mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null && { printf '%s\n' "$d"; return 0; }; printf '/tmp\n'; return 1; }
_rate_limit_reset_message() { printf 'try again later'; }
_rate_limit_check() { local subject="$1" dir="$2" f; command -v sha256sum >/dev/null || { printf '/dev/null\n'; return 0; }; f="$dir/.vw_last_email_$(printf '%s' "$subject" | sha256sum | cut -c1-16)"; if [[ "$subject" != *CRITICAL* && -f "$f" ]]; then local last now win="${EMAIL_RATE_WINDOW_SECONDS:-3600}"; last=$(cat "$f" 2>/dev/null || echo 0); now=$(date +%s); if (( now - last < win )); then log_warn "Email rate limit reached for: ${subject} — $(_rate_limit_reset_message "$f")"; return 1; fi; fi; printf '%s\n' "$f"; }

_build_email_metadata_body() { printf '%s\n\nEmail delivery metadata:\nHost:      %s\nTimestamp: %s\nMode:      %s\nProvider:  %s\nMethod:    SMTP fallback chain' "$1" "$2" "$3" "$4" "$5"; }
_email_date() { LC_ALL=C date -R; }
_email_msgid() { printf '<%s.%s@%s>' "$(date +%s)" "$$" "$(hostname -f 2>/dev/null || hostname)"; }
_email_write_text_crlf() { sed 's/\r$//' | awk '{printf "%s\r\n", $0}'; }

_build_plain_message() { local file="$1" from="$2" to="$3" subject="$4" body="$5" msgid="$6" name; name=$(_email_sender_name) || return 1; { printf 'From: %s <%s>\r\n' "$name" "$from"; printf 'To: %s\r\nSubject: %s\r\nDate: %s\r\nMessage-ID: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n' "$to" "$subject" "$(_email_date)" "$msgid"; printf '%s\n' "$body" | _email_write_text_crlf; } >"$file"; }

_smtp_upload_sidecar() { local file="$1" from="$2" to="$3" endpoint="${VW_SMTP_HOST_PORT:-127.0.0.1:587}" rc; curl -sS --connect-timeout 10 --max-time 60 --url "smtp://${endpoint}" --mail-from "$from" --mail-rcpt "$to" --upload-file "$file"; rc=$?; (( rc == 0 )) || log_warn "Postfix sidecar SMTP upload failed at ${endpoint} (curl exit ${rc})"; return "$rc"; }

_smtp_security_url() { local host="$1" port="$2" sec="${3,,}"; [[ -z "$sec" ]] && { [[ "$port" == 465 ]] && sec=tls || sec=starttls; }; case "$sec" in tls|ssl|on) printf 'smtps://%s:%s\n' "$host" "$port";; starttls) printf 'smtp://%s:%s --ssl-reqd\n' "$host" "$port";; none|plain|off) printf 'smtp://%s:%s\n' "$host" "$port";; *) return 1;; esac; }
_smtp_password() { if [[ -n "${SMTP_PASSWORD:-}" ]]; then printf '%s' "$SMTP_PASSWORD"; elif declare -f get_secret >/dev/null 2>&1; then get_secret smtp_password; elif declare -f decrypt_secret >/dev/null 2>&1; then decrypt_secret smtp_password; else log_error "Direct SMTP requires SMTP_PASSWORD or a loaded secrets helper that can resolve smtp_password."; return 1; fi; }
_smtp_upload_direct() { local file="$1" from="$2" to="$3" host="${SMTP_HOST:-}" port="${SMTP_PORT:-587}" user="${SMTP_USERNAME:-}" pass url_line url tls=() cfg rc xtrace_set=0; [[ -n "$host" && -n "$port" && -n "$user" ]] || { log_error "Direct SMTP requires SMTP_HOST, SMTP_PORT, and SMTP_USERNAME."; return 1; }; for v in "$host" "$user"; do _email_has_ctl "$v" || _email_has_nul "$v" && { log_error "Direct SMTP input contains CR, LF, or NUL."; return 1; }; done; url_line=$(_smtp_security_url "$host" "$port" "${SMTP_SECURITY:-}") || { log_error "Unknown SMTP_SECURITY='${SMTP_SECURITY:-}'. Valid: tls starttls none"; return 1; }; url=${url_line%% *}; [[ "$url_line" == *--ssl-reqd ]] && tls=(--ssl-reqd); case $- in *x*) xtrace_set=1; set +x;; esac; pass=$(_smtp_password) || { (( xtrace_set )) && set -x; return 1; }; [[ -n "$pass" && "$pass" != PLACEHOLDER* && "$pass" != NOT_USED_* ]] || { unset pass; (( xtrace_set )) && set -x; log_error "smtp_password is empty or a placeholder."; return 1; }; _email_has_ctl "$pass" || _email_has_nul "$pass" && { unset pass; (( xtrace_set )) && set -x; log_error "smtp_password contains CR, LF, or NUL."; return 1; }; cfg=$(_email_tmpfile vw-smtp-cfg) || { unset pass; (( xtrace_set )) && set -x; return 1; }; chmod 600 "$cfg" || { rm -f "$cfg"; unset pass; (( xtrace_set )) && set -x; return 1; }; printf 'user = %s\n' "$(_email_curl_quote "${user}:${pass}")" >"$cfg" || { rm -f "$cfg"; unset pass; (( xtrace_set )) && set -x; return 1; }; unset pass; curl -sS --config "$cfg" --connect-timeout 10 --max-time 60 "${tls[@]}" --url "$url" --mail-from "$from" --mail-rcpt "$to" --upload-file "$file"; rc=$?; rm -f "$cfg"; (( xtrace_set )) && set -x; (( rc == 0 )) || log_warn "Direct upstream SMTP upload failed via ${host}:${port} (curl exit ${rc})"; return "$rc"; }

_smtp_fallback_chain() { local file="$1" from="$2" to="$3"; if _smtp_upload_sidecar "$file" "$from" "$to"; then log_info "Email sent via Postfix sidecar SMTP"; return 0; fi; log_warn "Postfix sidecar failed; attempting direct upstream SMTP."; if _smtp_upload_direct "$file" "$from" "$to"; then log_info "Email sent via direct upstream SMTP"; return 0; fi; return 1; }

send_smtp_attachment() { local to="$1" subject="$2" body="$3" path="$4" aname="$5" from fname msg boundary msgid; _email_validate_addr TO "$to" || return 1; _email_validate_header Subject "$subject" || return 1; _email_validate_header Attachment-Name "$aname" || return 1; from=$(resolve_email_sender) || return 1; _email_validate_addr SMTP_FROM "$from" || return 1; _email_sender_name >/dev/null || return 1; [[ -n "$path" && -f "$path" && -r "$path" ]] || { log_error "Attachment path must be a readable regular file."; return 1; }; fname=$(basename -- "$aname"); [[ -n "$fname" && "$fname" != . && "$fname" != .. && "$fname" != *'"'* && "$fname" != *\\* ]] || { log_error "Invalid attachment filename."; return 1; }; _email_validate_header Attachment-Filename "$fname" || return 1; msg=$(_email_tmpfile vw-email-mime) || return 1; chmod 600 "$msg" || { rm -f "$msg"; return 1; }; register_cleanup _email_rm "$msg" 2>/dev/null || true; boundary="vw-$(date +%s)-$$-$RANDOM"; msgid=$(_email_msgid); { printf 'From: %s <%s>\r\n' "${SMTP_FROM_NAME:-VaultWarden}" "$from"; printf 'To: %s\r\nSubject: %s\r\nDate: %s\r\nMessage-ID: %s\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary="%s"\r\n\r\n' "$to" "$subject" "$(_email_date)" "$msgid" "$boundary"; printf -- '--%s\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n' "$boundary"; printf '%s\n' "$body" | _email_write_text_crlf; printf '\r\n--%s\r\nContent-Type: application/octet-stream; name="%s"\r\nContent-Transfer-Encoding: base64\r\nContent-Disposition: attachment; filename="%s"\r\n\r\n' "$boundary" "$fname" "$fname"; base64 -w 76 "$path" | _email_write_text_crlf; printf '\r\n--%s--\r\n' "$boundary"; } >"$msg" || { rm -f "$msg"; return 1; }; _smtp_fallback_chain "$msg" "$from" "$to"; local rc=$?; rm -f "$msg"; return "$rc"; }

send_email() { local to subject body att_path="${4:-}" att_name="${5:-}"; if [[ $# -lt 3 ]]; then to="${ADMIN_EMAIL:-}"; subject="${1:-}"; body="${2:-}"; else to="$1"; subject="$2"; body="$3"; fi; if [[ -n "$att_path" ]]; then send_smtp_attachment "$to" "$subject" "$body" "$att_path" "${att_name:-$(basename -- "$att_path")}"; return $?; fi; _email_validate_addr TO "$to" || return 1; subject=$(_normalise_email_subject "$subject"); _email_validate_header Subject "$subject" || return 1; local mode="${EMAIL_MODE:-auto}" provider="${EMAIL_PROVIDER:-mailersend}" driver fn from msg msgid rate_dir rate_file; case "$mode" in auto|api|smtp|direct|host) ;; *) log_error "Unknown EMAIL_MODE='${mode}'. Valid values: auto api smtp direct host"; return 1;; esac; rate_dir=$(_resolve_rate_limit_dir) || true; rate_file=$(_rate_limit_check "$subject" "$rate_dir") || return 0; if [[ "$mode" == auto || "$mode" == api ]]; then if driver=$(_email_driver_lookup "$provider"); then fn="_email_driver_${driver}"; if declare -f "$fn" >/dev/null && "$fn" "$to" "$subject" "$body"; then [[ "$rate_file" != /dev/null ]] && date +%s >"$rate_file"; log_info "Email sent via HTTP API provider ${driver}"; return 0; fi; [[ "$mode" == api ]] && { log_error "EMAIL_MODE=api: ${provider} API failed — no fallback configured"; return 1; }; log_warn "HTTP API provider ${provider} failed; continuing with SMTP fallback chain."; else [[ "$mode" == api ]] && { log_error "Unknown EMAIL_PROVIDER='${provider}' for EMAIL_MODE=api"; return 1; }; log_warn "Unknown EMAIL_PROVIDER='${provider}'; continuing with SMTP fallback chain."; fi; fi; from=$(resolve_email_sender) || return 1; _email_validate_addr SMTP_FROM "$from" || return 1; _email_sender_name >/dev/null || return 1; msg=$(_email_tmpfile vw-email-plain) || return 1; chmod 600 "$msg" || { rm -f "$msg"; return 1; }; register_cleanup _email_rm "$msg" 2>/dev/null || true; msgid=$(_email_msgid); local mbody; mbody=$(_build_email_metadata_body "$body" "$(hostname -f 2>/dev/null || hostname)" "$(date -Iseconds)" "$mode" "$provider"); _build_plain_message "$msg" "$from" "$to" "$subject" "$mbody" "$msgid" || { rm -f "$msg"; return 1; }; case "$mode" in auto|smtp) _smtp_fallback_chain "$msg" "$from" "$to";; direct) _smtp_upload_direct "$msg" "$from" "$to" && log_info "Email sent via direct upstream SMTP";; host) log_warn "EMAIL_MODE=host is deprecated; behaving exactly as EMAIL_MODE=direct."; _smtp_upload_direct "$msg" "$from" "$to" && log_info "Email sent via direct upstream SMTP";; api) return 1;; esac; local rc=$?; rm -f "$msg"; [[ $rc -eq 0 && "$rate_file" != /dev/null ]] && date +%s >"$rate_file"; return "$rc"; }

send_notification_email() { send_email "$1" "$2"; }
clear_email_rate_limit() { local subject="$(_normalise_email_subject "$1")" dir; dir=$(_resolve_rate_limit_dir) || true; rm -f "$dir/.vw_last_email_"* 2>/dev/null || true; log_info "Cleared email rate limit for: $subject"; }

export -f resolve_email_sender _email_driver_lookup _email_http_bearer_json _email_http_basic_form _email_http_custom_header_json
export -f _email_driver_mailgun _email_driver_sendgrid _email_driver_mailersend _email_driver_postmark _email_driver_resend _email_driver_cyberpersons
export -f _smtp_upload_sidecar _smtp_upload_direct send_smtp_attachment send_email send_notification_email clear_email_rate_limit
