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

_email_has_control() {
    local value="$1"
    [[ "$value" == *$'\r'* || "$value" == *$'\n'* || "$value" =~ [[:cntrl:]] ]]
}

_email_validate_header() {
    local name="$1" value="$2"
    if _email_has_control "$value"; then
        log_error "${name}: header value contains a control character"
        return 1
    fi
}

_email_validate_addr() {
    local name="$1" value="$2"
    if [[ -z "$value" ]]; then
        log_error "${name}: address is empty"
        return 1
    fi
    _email_validate_header "$name" "$value"
}

_email_tmpfile() {
    local prefix="$1"
    mktemp -p /dev/shm "${prefix}.XXXXXX" 2>/dev/null || mktemp -t "${prefix}.XXXXXX"
}

_email_rm() {
    rm -f "$@" 2>/dev/null || true
}

_email_curl_quote() {
    local value="$1"
    if _email_has_control "$value"; then
        return 1
    fi
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

_email_register_cleanup_file() {
    local file="$1"
    if declare -f register_cleanup >/dev/null 2>&1; then
        register_cleanup _email_rm "$file"
    fi
}

resolve_email_sender() {
    if [[ -n "${SMTP_FROM:-}" ]]; then
        printf '%s' "$SMTP_FROM"
        return 0
    fi
    if [[ -n "${SMTP_FROM_EMAIL:-}" ]]; then
        log_warn "SMTP_FROM_EMAIL is deprecated; set SMTP_FROM instead."
        printf '%s' "$SMTP_FROM_EMAIL"
        return 0
    fi
    log_error "SMTP_FROM is required; SMTP_FROM_EMAIL is only a deprecated compatibility alias."
    return 1
}

_email_sender_name() {
    local name="${SMTP_FROM_NAME:-VaultWarden}"
    _email_validate_header SMTP_FROM_NAME "$name" || return 1
    printf '%s' "$name"
}

_email_driver_lookup() {
    local provider="${1,,}" canonical=""
    canonical="${_EMAIL_PROVIDER_ALIASES[$provider]:-}"
    [[ -n "$canonical" && "$canonical" =~ ^[a-z_][a-z0-9_]*$ ]] || return 1
    printf '%s' "$canonical"
}

_email_api_token() {
    if [[ -n "${EMAIL_API_TOKEN:-}" ]]; then
        printf '%s' "$EMAIL_API_TOKEN"
    elif declare -f get_secret >/dev/null 2>&1; then
        get_secret email_api_token
    elif declare -f decrypt_secret >/dev/null 2>&1; then
        decrypt_secret email_api_token
    else
        log_error "HTTP email API requires EMAIL_API_TOKEN or a loaded secrets helper for email_api_token."
        return 1
    fi
}

_email_http_common() {
    local url="$1" cfg_kind="$2" payload="${3:-}" username="${4:-}"
    shift 4 || true
    local form_args=("$@")
    local token cfg body_file payload_file stderr_file code rc

    _ECURL_CODE=000
    _ECURL_BODY=""

    token=$(_email_api_token) || return 1
    if [[ -z "$token" || "$token" == PLACEHOLDER* || "$token" == NOT_USED_* ]]; then
        log_error "email_api_token is empty or a placeholder."
        return 1
    fi
    for value in "$url" "$token" "$username"; do
        if _email_has_control "$value"; then
            log_error "email HTTP helper: unsafe control character in input"
            return 1
        fi
    done

    body_file=$(_email_tmpfile vw-email-http-body) || return 1
    cfg=$(_email_tmpfile vw-email-http-cfg) || { rm -f "$body_file"; return 1; }
    chmod 600 "$body_file" "$cfg" 2>/dev/null || { rm -f "$body_file" "$cfg"; return 1; }
    _email_register_cleanup_file "$body_file"
    _email_register_cleanup_file "$cfg"

    case "$cfg_kind" in
        bearer)
            printf 'header = %s\n' "$(_email_curl_quote "Authorization: Bearer ${token}")" >"$cfg" \
                || { rm -f "$body_file" "$cfg"; return 1; }
            ;;
        basic)
            printf 'user = %s\n' "$(_email_curl_quote "${username}:${token}")" >"$cfg" \
                || { rm -f "$body_file" "$cfg"; return 1; }
            ;;
        header)
            printf 'header = %s\n' "$(_email_curl_quote "${username}: ${token}")" >"$cfg" \
                || { rm -f "$body_file" "$cfg"; return 1; }
            ;;
        *)
            log_error "email HTTP helper: unknown config kind '${cfg_kind}'"
            rm -f "$body_file" "$cfg"
            return 1
            ;;
    esac
    unset token

    local curl_args=(
        curl -sS
        --config "$cfg"
        --connect-timeout 10
        --max-time 30
        --retry 2
        --retry-delay 2
        --retry-all-errors
        -o "$body_file"
        -w '%{http_code}'
        -X POST "$url"
    )

    if [[ "$cfg_kind" == basic ]]; then
        curl_args+=("${form_args[@]}")
    else
        payload_file=$(_email_tmpfile vw-email-http-payload) || { rm -f "$body_file" "$cfg"; return 1; }
        chmod 600 "$payload_file" 2>/dev/null || { rm -f "$body_file" "$cfg" "$payload_file"; return 1; }
        _email_register_cleanup_file "$payload_file"
        printf '%s' "$payload" >"$payload_file" || { rm -f "$body_file" "$cfg" "$payload_file"; return 1; }
        curl_args+=(-H 'Content-Type: application/json' --data-binary "@${payload_file}")
    fi

    stderr_file=$(_email_tmpfile vw-email-http-stderr) || { rm -f "$body_file" "$cfg" "${payload_file:-}"; return 1; }
    chmod 600 "$stderr_file" 2>/dev/null || { rm -f "$body_file" "$cfg" "${payload_file:-}" "$stderr_file"; return 1; }
    _email_register_cleanup_file "$stderr_file"

    local errexit_set=0
    case $- in
        *e*) errexit_set=1; set +e ;;
    esac
    code=$("${curl_args[@]}" 2>"$stderr_file")
    rc=$?
    (( errexit_set )) && set -e
    if [[ -s "$stderr_file" ]]; then
        sed -E 's/(Authorization: Bearer )[[:graph:]]+/\1[REDACTED]/g' "$stderr_file" >&2 || true
    fi
    [[ -n "${payload_file:-}" ]] && rm -f "$payload_file"
    _ECURL_CODE="${code:-000}"
    _ECURL_BODY=$(head -c 300 "$body_file" 2>/dev/null | tr -d '\r\n')
    rm -f "$body_file" "$cfg" "$stderr_file"

    (( rc == 0 )) && [[ "$_ECURL_CODE" =~ ^2[0-9][0-9]$ ]]
}

_email_http_bearer_json() {
    _email_http_common "$1" bearer "$2" ""
}

_email_http_basic_form() {
    local url="$1" username="$2"
    shift 2
    _email_http_common "$url" basic "" "$username" "$@"
}

_email_http_custom_header_json() {
    _email_http_common "$1" header "$3" "$2"
}

_email_driver_mailersend() {
    local to="$1" subject="$2" body="$3" from name payload
    from=$(resolve_email_sender) || return 1
    name=$(_email_sender_name) || return 1
    payload=$(jq -n \
        --arg from_email "$from" \
        --arg from_name "$name" \
        --arg to "$to" \
        --arg subject "$subject" \
        --arg text "$body" \
        '{from:{email:$from_email,name:$from_name},to:[{email:$to}],subject:$subject,text:$text,settings:{track_clicks:false,track_opens:false}}') || return 1
    _email_http_bearer_json "https://api.mailersend.com/v1/email" "$payload" || {
        log_warn "MailerSend API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
        return 1
    }
}

_email_driver_sendgrid() {
    local to="$1" subject="$2" body="$3" from name payload
    from=$(resolve_email_sender) || return 1
    name=$(_email_sender_name) || return 1
    payload=$(jq -n \
        --arg from_email "$from" \
        --arg from_name "$name" \
        --arg to "$to" \
        --arg subject "$subject" \
        --arg text "$body" \
        '{personalizations:[{to:[{email:$to}]}],from:{email:$from_email,name:$from_name},subject:$subject,content:[{type:"text/plain",value:$text}],tracking_settings:{click_tracking:{enable:false},open_tracking:{enable:false},subscription_tracking:{enable:false}}}') || return 1
    _email_http_bearer_json "https://api.sendgrid.com/v3/mail/send" "$payload" || {
        log_warn "SendGrid API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
        return 1
    }
}

_email_driver_mailgun() {
    local to="$1" subject="$2" body="$3" from domain host
    from=$(resolve_email_sender) || return 1
    subject=${subject//$'\r'/}
    subject=${subject//$'\n'/ }
    domain="${MAILGUN_DOMAIN:-${from##*@}}"
    [[ "$domain" =~ ^[a-zA-Z0-9.-]+$ ]] || { log_error "Mailgun driver: invalid domain '${domain}'."; return 1; }
    case "${MAILGUN_REGION:-us}" in
        us) host=api.mailgun.net ;;
        eu) host=api.eu.mailgun.net ;;
        *) log_error "Mailgun driver: unrecognised MAILGUN_REGION='${MAILGUN_REGION:-}'. Valid: us eu"; return 1 ;;
    esac
    _email_http_basic_form "https://${host}/v3/${domain}/messages" api \
        -F "from=${SMTP_FROM_NAME:-VaultWarden} <${from}>" \
        -F "to=${to}" \
        -F "subject=${subject}" \
        -F "text=${body}" \
        -F "o:tracking=no" || {
            log_warn "Mailgun API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
            return 1
        }
}

_email_driver_postmark() {
    local to="$1" subject="$2" body="$3" from name payload
    from=$(resolve_email_sender) || return 1
    name=$(_email_sender_name) || return 1
    payload=$(jq -n \
        --arg from_name "$name" \
        --arg from_email "$from" \
        --arg to "$to" \
        --arg subject "$subject" \
        --arg text "$body" \
        '{From:($from_name+" <"+$from_email+">") ,To:$to,Subject:$subject,TextBody:$text,MessageStream:"outbound"}') || return 1
    _email_http_custom_header_json "https://api.postmarkapp.com/email" "X-Postmark-Server-Token" "$payload" || {
        log_warn "Postmark API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
        return 1
    }
    printf '%s' "$_ECURL_BODY" | jq -e '.ErrorCode == 0' >/dev/null 2>&1 || {
        log_warn "Postmark API ErrorCode was not 0: ${_ECURL_BODY}"
        return 1
    }
}

_email_driver_resend() {
    local to="$1" subject="$2" body="$3" from name payload
    from=$(resolve_email_sender) || return 1
    name=$(_email_sender_name) || return 1
    payload=$(jq -n \
        --arg from_name "$name" \
        --arg from_email "$from" \
        --arg to "$to" \
        --arg subject "$subject" \
        --arg text "$body" \
        '{from:($from_name+" <"+$from_email+">") ,to:[$to],subject:$subject,text:$text}') || return 1
    _email_http_bearer_json "https://api.resend.com/emails" "$payload" || {
        log_warn "Resend API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
        return 1
    }
}

_email_driver_cyberpersons() {
    local to="$1" subject="$2" body="$3" from name payload
    from=$(resolve_email_sender) || return 1
    name=$(_email_sender_name) || return 1
    payload=$(jq -n \
        --arg from_email "$from" \
        --arg from_name "$name" \
        --arg to "$to" \
        --arg subject "$subject" \
        --arg text "$body" \
        '{from:{email:$from_email,name:$from_name},to:[{email:$to}],subject:$subject,text:$text}') || return 1
    _email_http_bearer_json "https://platform.cyberpersons.com/email/v1/send" "$payload" || {
        log_warn "CyberPersons API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
        return 1
    }
}

_normalise_email_subject() {
    local subject="$1"
    [[ "$subject" != "[VaultWarden]"* ]] && subject="[VaultWarden] ${subject}"
    printf '%s\n' "$subject"
}

_rate_limit_file_for_subject() {
    local subject="$1" dir="$2"
    command -v sha256sum >/dev/null 2>&1 || return 1
    printf '%s/.vw_last_email_%s\n' "$dir" "$(printf '%s' "$subject" | sha256sum | cut -c1-16)"
}

_resolve_rate_limit_dir() {
    local candidates=(
        "${PROJECT_ROOT:-$(pwd)}/.rate-limit"
        "${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/vaultwarden/rate-limit"
        "/tmp/vaultwarden-rate-limit-${EUID:-$(id -u)}"
    )
    local dir
    for dir in "${candidates[@]}"; do
        mkdir -p "$dir" 2>/dev/null || true
        chmod 700 "$dir" 2>/dev/null || true
        if [[ -d "$dir" ]] && touch "${dir}/.write_test_$$" 2>/dev/null; then
            rm -f "${dir}/.write_test_$$" 2>/dev/null || true
            printf '%s\n' "$dir"
            return 0
        fi
    done
    log_debug "_resolve_rate_limit_dir: no writable candidate; rate-limiting disabled"
    return 1
}

_rate_limit_reset_message() {
    local last_file="$1" window_seconds="${EMAIL_RATE_WINDOW_SECONDS:-3600}"
    local last_time now reset_epoch remaining mins secs reset_at
    last_time=$(cat "$last_file" 2>/dev/null || printf '0')
    now=$(date +%s)
    reset_epoch=$((last_time + window_seconds))
    if (( reset_epoch > now )); then
        remaining=$((reset_epoch - now))
        mins=$((remaining / 60))
        secs=$((remaining % 60))
        reset_at=$(date -d "@${reset_epoch}" '+%H:%M:%S' 2>/dev/null \
            || date -r "$reset_epoch" '+%H:%M:%S' 2>/dev/null \
            || printf 'unknown time')
        printf 'resets in %dm %02ds (at %s)' "$mins" "$secs" "$reset_at"
    else
        printf 'window may have already reset — try sudo ./maintenance.sh test-email'
    fi
}

_rate_limit_check() {
    local subject="$1" rate_limit_dir="$2" last_email_file
    last_email_file=$(_rate_limit_file_for_subject "$subject" "$rate_limit_dir") || {
        printf '/dev/null\n'
        return 0
    }
    if [[ "$subject" != *CRITICAL* && -f "$last_email_file" ]]; then
        local last_time current_time window_seconds="${EMAIL_RATE_WINDOW_SECONDS:-3600}"
        last_time=$(cat "$last_email_file" 2>/dev/null || printf '0')
        current_time=$(date +%s)
        if (( current_time - last_time < window_seconds )); then
            log_warn "Email rate limit reached for: ${subject} — $(_rate_limit_reset_message "$last_email_file")"
            log_hint "To reset: clear_email_rate_limit \"${subject}\""
            return 1
        fi
    fi
    printf '%s\n' "$last_email_file"
}

_email_host() {
    hostname -f 2>/dev/null || hostname
}

_build_email_metadata_body() {
    local body="$1" host="$2" timestamp="$3" mode="$4" provider="$5" method="$6"
    [[ -n "$provider" ]] || provider="none"
    printf '%s\n\nEmail delivery metadata:\nHost:      %s\nTimestamp: %s\nMode:      %s\nProvider:  %s\nMethod:    %s' \
        "$body" "$host" "$timestamp" "$mode" "$provider" "$method"
}

_email_date() {
    LC_ALL=C date -R
}

_email_msgid() {
    printf '<%s.%s.%s@%s>' "$(date +%s)" "$$" "$RANDOM" "$(_email_host)"
}

_email_write_text_crlf() {
    sed 's/\r$//' | awk '{printf "%s\r\n", $0}'
}

_email_base64_wrap() {
    local file="$1"
    if base64 --help 2>&1 | grep -q -- '-w'; then
        base64 -w 76 "$file"
    else
        base64 <"$file" | fold -w 76
    fi
}

_build_plain_message() {
    local file="$1" from="$2" to="$3" subject="$4" body="$5" msgid="$6" name
    name=$(_email_sender_name) || return 1
    {
        printf 'From: %s <%s>\r\n' "$name" "$from"
        printf 'To: %s\r\n' "$to"
        printf 'Subject: %s\r\n' "$subject"
        printf 'Date: %s\r\n' "$(_email_date)"
        printf 'Message-ID: %s\r\n' "$msgid"
        printf 'MIME-Version: 1.0\r\n'
        printf 'Content-Type: text/plain; charset=UTF-8\r\n'
        printf 'Content-Transfer-Encoding: 8bit\r\n\r\n'
        printf '%s\n' "$body" | _email_write_text_crlf
    } >"$file"
}

_smtp_upload_sidecar() {
    local message_file="$1" from_address="$2" to_address="$3"
    local endpoint="${VW_SMTP_HOST_PORT:-127.0.0.1:587}" rc
    local curl_args=(
        curl -sS
        --connect-timeout 10
        --max-time 60
        --url "smtp://${endpoint}"
        --mail-from "$from_address"
        --mail-rcpt "$to_address"
        --upload-file "$message_file"
    )
    local errexit_set=0
    case $- in
        *e*) errexit_set=1; set +e ;;
    esac
    "${curl_args[@]}"
    rc=$?
    (( errexit_set )) && set -e
    if (( rc != 0 )); then
        log_warn "Postfix sidecar SMTP upload failed at ${endpoint} (curl exit ${rc})"
    fi
    return "$rc"
}

_smtp_password() {
    if [[ -n "${SMTP_PASSWORD:-}" ]]; then
        printf '%s' "$SMTP_PASSWORD"
    elif declare -f get_secret >/dev/null 2>&1; then
        get_secret smtp_password
    elif declare -f decrypt_secret >/dev/null 2>&1; then
        decrypt_secret smtp_password
    else
        log_error "Direct SMTP requires SMTP_PASSWORD or a loaded secrets helper that can resolve smtp_password."
        return 1
    fi
}

_smtp_upload_direct() {
    local message_file="$1" from_address="$2" to_address="$3"
    local host="${SMTP_HOST:-}" port="${SMTP_PORT:-587}" user="${SMTP_USERNAME:-}"
    local security="${SMTP_SECURITY:-}" smtp_url password cfg rc xtrace_set=0
    local tls_flags=()

    if [[ -z "$host" || -z "$port" || -z "$user" ]]; then
        log_error "Direct SMTP requires SMTP_HOST, SMTP_PORT, and SMTP_USERNAME."
        return 1
    fi
    for value in "$host" "$user"; do
        if _email_has_control "$value"; then
            log_error "Direct SMTP input contains CR, LF, or another control character."
            return 1
        fi
    done

    security="${security,,}"
    if [[ -z "$security" ]]; then
        if [[ "$port" == "465" ]]; then
            security=tls
        else
            security=starttls
        fi
    fi
    case "$security" in
        tls|ssl|on)
            smtp_url="smtps://${host}:${port}"
            ;;
        starttls)
            smtp_url="smtp://${host}:${port}"
            tls_flags=(--ssl-reqd)
            ;;
        none|plain|off)
            smtp_url="smtp://${host}:${port}"
            ;;
        *)
            log_error "Unknown SMTP_SECURITY='${SMTP_SECURITY:-}'. Valid: tls starttls none"
            return 1
            ;;
    esac

    case $- in
        *x*) xtrace_set=1; set +x ;;
    esac
    password=$(_smtp_password) || { (( xtrace_set )) && set -x; return 1; }
    if [[ -z "$password" || "$password" == PLACEHOLDER* || "$password" == NOT_USED_* ]]; then
        unset password
        (( xtrace_set )) && set -x
        log_error "smtp_password is empty or a placeholder."
        return 1
    fi
    if _email_has_control "$password"; then
        unset password
        (( xtrace_set )) && set -x
        log_error "smtp_password contains CR, LF, or another control character."
        return 1
    fi

    cfg=$(_email_tmpfile vw-smtp-cfg) || { unset password; (( xtrace_set )) && set -x; return 1; }
    chmod 600 "$cfg" || { rm -f "$cfg"; unset password; (( xtrace_set )) && set -x; return 1; }
    _email_register_cleanup_file "$cfg"
    printf 'user = %s\n' "$(_email_curl_quote "${user}:${password}")" >"$cfg" || {
        rm -f "$cfg"
        unset password
        (( xtrace_set )) && set -x
        return 1
    }
    unset password

    local curl_args=(
        curl -sS
        --config "$cfg"
        --connect-timeout 10
        --max-time 60
        "${tls_flags[@]}"
        --url "$smtp_url"
        --mail-from "$from_address"
        --mail-rcpt "$to_address"
        --upload-file "$message_file"
    )
    local curl_errexit_set=0
    case $- in
        *e*) curl_errexit_set=1; set +e ;;
    esac
    "${curl_args[@]}"
    rc=$?
    (( curl_errexit_set )) && set -e
    rm -f "$cfg"
    (( xtrace_set )) && set -x
    if (( rc != 0 )); then
        log_warn "Direct upstream SMTP upload failed via ${host}:${port} (curl exit ${rc})"
    fi
    return "$rc"
}

_smtp_fallback_chain() {
    local message_file="$1" from_address="$2" to_address="$3"
    if _smtp_upload_sidecar "$message_file" "$from_address" "$to_address"; then
        log_info "Email sent via Postfix sidecar SMTP"
        return 0
    fi
    log_warn "Postfix sidecar failed; attempting direct upstream SMTP. Direct fallback is intentionally attempted for any sidecar submission failure."
    if _smtp_upload_direct "$message_file" "$from_address" "$to_address"; then
        log_info "Email sent via direct upstream SMTP"
        return 0
    fi
    return 1
}

send_smtp_attachment() {
    local to="$1" subject="$2" body="$3" attachment_path="$4" attachment_name="$5"
    local from filename message_file boundary msgid rc sender_name metadata_body

    _email_validate_addr TO "$to" || return 1
    _email_validate_header Subject "$subject" || return 1
    _email_validate_header Attachment-Name "$attachment_name" || return 1
    from=$(resolve_email_sender) || return 1
    _email_validate_addr SMTP_FROM "$from" || return 1
    sender_name=$(_email_sender_name) || return 1
    if [[ -z "$attachment_path" || ! -f "$attachment_path" || ! -r "$attachment_path" ]]; then
        log_error "Attachment path must be a readable regular file."
        return 1
    fi

    filename=$(basename -- "$attachment_name")
    if [[ -z "$filename" || "$filename" == . || "$filename" == .. || "$filename" == *'"'* || "$filename" == *\\* ]]; then
        log_error "Invalid attachment filename."
        return 1
    fi
    _email_validate_header Attachment-Filename "$filename" || return 1

    message_file=$(_email_tmpfile vw-email-mime) || return 1
    chmod 600 "$message_file" || { rm -f "$message_file"; return 1; }
    _email_register_cleanup_file "$message_file"
    boundary="vw-$(date +%s)-$$-${RANDOM}"
    msgid=$(_email_msgid)
    metadata_body=$(_build_email_metadata_body \
        "$body" \
        "$(_email_host)" \
        "$(date -Iseconds)" \
        "${EMAIL_MODE:-smtp}" \
        "${EMAIL_PROVIDER:-smtp}" \
        "SMTP fallback chain")

    {
        printf 'From: %s <%s>\r\n' "$sender_name" "$from"
        printf 'To: %s\r\n' "$to"
        printf 'Subject: %s\r\n' "$subject"
        printf 'Date: %s\r\n' "$(_email_date)"
        printf 'Message-ID: %s\r\n' "$msgid"
        printf 'MIME-Version: 1.0\r\n'
        printf 'Content-Type: multipart/mixed; boundary="%s"\r\n\r\n' "$boundary"
        printf -- '--%s\r\n' "$boundary"
        printf 'Content-Type: text/plain; charset=UTF-8\r\n'
        printf 'Content-Transfer-Encoding: 8bit\r\n\r\n'
        printf '%s\n' "$metadata_body" | _email_write_text_crlf
        printf '\r\n--%s\r\n' "$boundary"
        printf 'Content-Type: application/octet-stream; name="%s"\r\n' "$filename"
        printf 'Content-Transfer-Encoding: base64\r\n'
        printf 'Content-Disposition: attachment; filename="%s"\r\n\r\n' "$filename"
        _email_base64_wrap "$attachment_path" | _email_write_text_crlf
        printf '\r\n--%s--\r\n' "$boundary"
    } >"$message_file" || { rm -f "$message_file"; return 1; }

    _smtp_fallback_chain "$message_file" "$from" "$to"
    rc=$?
    rm -f "$message_file"
    return "$rc"
}

send_email() {
    local to subject body att_path="${4:-}" att_name="${5:-}"
    if [[ $# -lt 3 ]]; then
        to="${ADMIN_EMAIL:-}"
        subject="${1:-}"
        body="${2:-}"
    else
        to="$1"
        subject="$2"
        body="$3"
    fi

    if [[ -n "$att_path" ]]; then
        send_smtp_attachment "$to" "$subject" "$body" "$att_path" "${att_name:-$(basename -- "$att_path")}"
        return $?
    fi

    _email_validate_addr TO "$to" || return 1
    subject=$(_normalise_email_subject "$subject")
    _email_validate_header Subject "$subject" || return 1

    local mode="${EMAIL_MODE:-auto}" provider="${EMAIL_PROVIDER:-mailersend}"
    local driver fn from message_file msgid metadata_body rate_dir rate_file rc=1
    local host timestamp
    case "$mode" in
        auto|api|smtp|direct|host) ;;
        *) log_error "Unknown EMAIL_MODE='${mode}'. Valid values: auto api smtp direct host"; return 1 ;;
    esac

    host=$(_email_host)
    timestamp=$(date -Iseconds)

    if rate_dir=$(_resolve_rate_limit_dir); then
        rate_file=$(_rate_limit_check "$subject" "$rate_dir") || return 0
    else
        rate_file=/dev/null
    fi

    if [[ "$mode" == auto || "$mode" == api ]]; then
        if driver=$(_email_driver_lookup "$provider"); then
            fn="_email_driver_${driver}"
            metadata_body=$(_build_email_metadata_body \
                "$body" "$host" "$timestamp" "$mode" "$provider" "HTTP API provider ${driver}")
            if declare -f "$fn" >/dev/null && "$fn" "$to" "$subject" "$metadata_body"; then
                [[ "$rate_file" != /dev/null ]] && date +%s >"$rate_file"
                log_info "Email sent via HTTP API provider ${driver}"
                return 0
            fi
            if [[ "$mode" == api ]]; then
                log_error "EMAIL_MODE=api: ${provider} API failed — no fallback configured"
                return 1
            fi
            log_warn "HTTP API provider ${provider} failed; continuing with SMTP fallback chain."
        else
            if [[ "$mode" == api ]]; then
                log_error "Unknown EMAIL_PROVIDER='${provider}' for EMAIL_MODE=api"
                return 1
            fi
            log_warn "Unknown EMAIL_PROVIDER='${provider}'; continuing with SMTP fallback chain."
        fi
    fi

    from=$(resolve_email_sender) || return 1
    _email_validate_addr SMTP_FROM "$from" || return 1
    _email_sender_name >/dev/null || return 1
    message_file=$(_email_tmpfile vw-email-plain) || return 1
    chmod 600 "$message_file" || { rm -f "$message_file"; return 1; }
    _email_register_cleanup_file "$message_file"
    msgid=$(_email_msgid)

    case "$mode" in
        auto|smtp)
            metadata_body=$(_build_email_metadata_body \
                "$body" "$host" "$timestamp" "$mode" "$provider" "SMTP fallback chain")
            ;;
        direct)
            metadata_body=$(_build_email_metadata_body \
                "$body" "$host" "$timestamp" "$mode" "$provider" "Direct upstream SMTP")
            ;;
        host)
            metadata_body=$(_build_email_metadata_body \
                "$body" "$host" "$timestamp" "$mode" "$provider" "Direct upstream SMTP (host alias)")
            ;;
        api)
            rc=1
            ;;
    esac

    _build_plain_message "$message_file" "$from" "$to" "$subject" "$metadata_body" "$msgid" || {
        rm -f "$message_file"
        return 1
    }

    case "$mode" in
        auto|smtp)
            _smtp_fallback_chain "$message_file" "$from" "$to"
            rc=$?
            ;;
        direct)
            _smtp_upload_direct "$message_file" "$from" "$to"
            rc=$?
            (( rc == 0 )) && log_info "Email sent via direct upstream SMTP"
            ;;
        host)
            log_warn "EMAIL_MODE=host is deprecated; behaving exactly as EMAIL_MODE=direct."
            _smtp_upload_direct "$message_file" "$from" "$to"
            rc=$?
            (( rc == 0 )) && log_info "Email sent via direct upstream SMTP"
            ;;
        api)
            rc=1
            ;;
    esac
    rm -f "$message_file"
    if (( rc == 0 )) && [[ "$rate_file" != /dev/null ]]; then
        date +%s >"$rate_file"
    fi
    return "$rc"
}

send_email_via_transport() {
    local transport="${1:-}" to="${2:-}" subject="${3:-}" body="${4:-}"
    local provider="${EMAIL_PROVIDER:-mailersend}" driver fn
    local from message_file msgid metadata_body rc=1
    local host timestamp

    case "$transport" in
        api|sidecar|direct) ;;
        *)
            log_error "Unsupported diagnostic email transport '${transport}'. Valid values: api sidecar direct"
            return 2
            ;;
    esac
    if [[ $# -ne 4 ]]; then
        log_error "send_email_via_transport requires TRANSPORT, TO, SUBJECT, and BODY."
        return 2
    fi

    _email_validate_addr TO "$to" || return 1
    subject=$(_normalise_email_subject "$subject")
    _email_validate_header Subject "$subject" || return 1
    host=$(_email_host)
    timestamp=$(date -Iseconds)

    if [[ "$transport" == api ]]; then
        if ! driver=$(_email_driver_lookup "$provider"); then
            log_error "Unknown EMAIL_PROVIDER='${provider}' for exact API diagnostic."
            return 1
        fi
        fn="_email_driver_${driver}"
        if ! declare -f "$fn" >/dev/null 2>&1; then
            log_error "EMAIL_PROVIDER='${provider}' resolves to unsupported API driver '${driver}'."
            return 1
        fi
        metadata_body=$(_build_email_metadata_body \
            "$body" "$host" "$timestamp" "diagnostic" "$provider" \
            "Exact HTTP API transport (${driver})")
        if "$fn" "$to" "$subject" "$metadata_body"; then
            log_info "Diagnostic email sent via exact HTTP API provider ${driver}"
            return 0
        fi
        log_error "Exact HTTP API diagnostic failed via ${driver}; no SMTP fallback was attempted."
        return 1
    fi

    from=$(resolve_email_sender) || return 1
    _email_validate_addr SMTP_FROM "$from" || return 1
    _email_sender_name >/dev/null || return 1
    message_file=$(_email_tmpfile vw-email-diagnostic) || return 1
    chmod 600 "$message_file" || { rm -f "$message_file"; return 1; }
    _email_register_cleanup_file "$message_file"
    msgid=$(_email_msgid)

    case "$transport" in
        sidecar)
            metadata_body=$(_build_email_metadata_body \
                "$body" "$host" "$timestamp" "diagnostic" "none" \
                "Exact Postfix sidecar SMTP transport")
            ;;
        direct)
            metadata_body=$(_build_email_metadata_body \
                "$body" "$host" "$timestamp" "diagnostic" "none" \
                "Exact direct upstream SMTP transport")
            ;;
    esac

    if ! _build_plain_message "$message_file" "$from" "$to" "$subject" "$metadata_body" "$msgid"; then
        rm -f "$message_file"
        return 1
    fi

    case "$transport" in
        sidecar)
            if _smtp_upload_sidecar "$message_file" "$from" "$to"; then
                rc=0
                log_info "Diagnostic email submitted to exact Postfix sidecar transport"
            else
                rc=$?
                log_error "Exact Postfix sidecar diagnostic failed; no direct SMTP fallback was attempted."
            fi
            ;;
        direct)
            if _smtp_upload_direct "$message_file" "$from" "$to"; then
                rc=0
                log_info "Diagnostic email sent via exact direct upstream SMTP transport"
            else
                rc=$?
                log_error "Exact direct SMTP diagnostic failed."
            fi
            ;;
    esac
    rm -f "$message_file"
    return "$rc"
}

send_notification_email() {
    send_email "$1" "$2"
}

clear_email_rate_limit() {
    local subject dir rate_file
    subject=$(_normalise_email_subject "$1")
    if ! dir=$(_resolve_rate_limit_dir); then
        log_warn "clear_email_rate_limit: no writable rate-limit directory found"
        return 1
    fi
    rate_file=$(_rate_limit_file_for_subject "$subject" "$dir") || {
        log_warn "clear_email_rate_limit: sha256sum unavailable; no rate-limit stamp removed"
        return 1
    }
    rm -f "$rate_file" 2>/dev/null || true
    log_info "Cleared email rate limit for: $subject"
}

export -f resolve_email_sender _email_driver_lookup _email_http_bearer_json _email_http_basic_form _email_http_custom_header_json
export -f _email_driver_mailgun _email_driver_sendgrid _email_driver_mailersend _email_driver_postmark _email_driver_resend _email_driver_cyberpersons
export -f _smtp_upload_sidecar _smtp_upload_direct send_smtp_attachment send_email send_email_via_transport send_notification_email clear_email_rate_limit
