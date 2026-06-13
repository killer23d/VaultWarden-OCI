#!/usr/bin/env bash
# lib/email.sh — Email delivery helpers for VaultWarden-OCI.
#
# Provides:
#   Drivers   : _email_driver_mailersend, _email_driver_sendgrid,
#               _email_driver_mailgun, _email_driver_postmark,
#               _email_driver_resend, _email_driver_cyberpersons,
#               _email_driver_postfix
#   Attachment: _email_driver_mailgun_attachment, _email_driver_sendgrid_attachment,
#               _email_driver_mailersend_attachment, _email_driver_postmark_attachment,
#               _email_driver_resend_attachment, _email_driver_cyberpersons_attachment,
#               _smtp_send_with_attachment, _dispatch_email_with_attachment
#   Transport : _email_bearer_post, _smtp_send, _smtp_curl_upload
#   Helpers   : _email_driver_lookup, _normalise_email_subject,
#               _resolve_rate_limit_dir, _rate_limit_check,
#               _resolve_smtp_method, _build_email_metadata_body
#   Public    : send_email, send_notification_email, clear_email_rate_limit
#
# Depends on / Load order:
#   lib/log.sh is auto-loaded if it has not already been sourced.
#   lib/common.sh should be sourced before this file.
#   jq, curl, base64 are guaranteed by setup.sh.
#
# Canonical caller source block:
#   source "${LIB_DIR}/log.sh"
#   source "${LIB_DIR}/common.sh"
#   source "${LIB_DIR}/email.sh"

[[ -n "${VAULTWARDEN_EMAIL_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_EMAIL_LIB_LOADED=1

_VW_EMAIL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${VW_LOG_LIB_LOADED:-}" ]] || source "${_VW_EMAIL_LIB_DIR}/log.sh"
unset _VW_EMAIL_LIB_DIR

_ECURL_CODE=""
_ECURL_BODY=""


# ---------------------------------------------------------------------------
# _email_bearer_post URL
#
# Reads JSON payload from stdin. Writes HTTP status to _ECURL_CODE and
# truncated response body to _ECURL_BODY. Returns 0 on 2xx.
# Token read from EMAIL_API_TOKEN env var, written to a mode-600 curl config
# so it never appears in process argv.
# ---------------------------------------------------------------------------
_email_bearer_post() {
    local url="$1"
    local tmp cfg code
    tmp=$(mktemp -t vw_email.XXXXXXXXXX)
    cfg=$(mktemp -t vw_ecfg.XXXXXXXXXX)
    if ! install -m 600 /dev/null "$tmp" 2>/dev/null || \
       ! install -m 600 /dev/null "$cfg" 2>/dev/null; then
        rm -f "$tmp" "$cfg"
        log_error "_email_bearer_post: failed to secure temp files"
        return 1
    fi
    trap 'rm -f "$tmp" "$cfg" 2>/dev/null; trap - RETURN' RETURN

    printf 'header = "Authorization: Bearer %s"\n' "${EMAIL_API_TOKEN}" >"$cfg"

    code=$(curl -s \
        --config "$cfg" \
        --connect-timeout 10 \
        --max-time 20 \
        --retry 2 \
        --retry-delay 3 \
        --retry-all-errors \
        -o "$tmp" \
        -w "%{http_code}" \
        -X POST "$url" \
        -H "Content-Type: application/json" \
        --data-binary @- 2>/dev/null)

    _ECURL_CODE="$code"
    _ECURL_BODY=$(head -c 300 "$tmp" 2>/dev/null | tr -d '\n')
    [[ "$code" =~ ^2 ]] && return 0 || return 1
}


# _email_driver_lookup PROVIDER
# Returns the canonical driver-function suffix, or 1 for unknown providers.
# Accepts all known aliases for CyberPanel/CyberPersons interchangeably.
_email_driver_lookup() {
    local provider="${1,,}"
    case "$provider" in
        mailersend|sendgrid|mailgun|postmark|resend)
            printf '%s' "$provider"; return 0 ;;
        # CyberPanel's transactional mail service is also marketed as
        # "CyberPersons" (platform.cyberpersons.com). Accept all three aliases.
        cyberpersons|cyberperson|cyberpanel)
            printf 'cyberpersons'; return 0 ;;
        host|postfix)
            printf 'postfix'; return 0 ;;
        *)
            return 1 ;;
    esac
}


# ---------------------------------------------------------------------------
# Plain-text API drivers  (SUBJECT BODY)
# All JSON is built with jq --arg for safe, injection-proof escaping.
# ---------------------------------------------------------------------------

_email_driver_mailersend() {
    local subject="$1" body="$2"
    local _from="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"

    local payload
    payload=$(jq -n \
        --arg from_email  "$_from" \
        --arg from_name   "${SMTP_FROM_NAME:-VaultWarden}" \
        --arg to          "${ADMIN_EMAIL}" \
        --arg subject     "$subject" \
        --arg text        "$body" \
        '{
            from:     { email: $from_email, name: $from_name },
            to:       [{ email: $to }],
            subject:  $subject,
            text:     $text,
            settings: { track_clicks: false, track_opens: false }
        }') || { log_error "MailerSend driver: jq failed"; return 1; }

    if printf '%s' "$payload" | _email_bearer_post "https://api.mailersend.com/v1/email"; then
        [[ -n "${_ECURL_BODY}" ]] && log_warn "MailerSend: queued with warnings: ${_ECURL_BODY}"
        return 0
    fi
    log_warn "MailerSend API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
    return 1
}


_email_driver_sendgrid() {
    local subject="$1" body="$2"
    local _from="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"

    local payload
    payload=$(jq -n \
        --arg from_email  "$_from" \
        --arg from_name   "${SMTP_FROM_NAME:-VaultWarden}" \
        --arg to          "${ADMIN_EMAIL}" \
        --arg subject     "$subject" \
        --arg text        "$body" \
        '{
            personalizations: [{ to: [{ email: $to }] }],
            from:    { email: $from_email, name: $from_name },
            subject: $subject,
            content: [{ type: "text/plain", value: $text }],
            tracking_settings: {
                click_tracking:        { enable: false },
                open_tracking:         { enable: false },
                subscription_tracking: { enable: false }
            }
        }') || { log_error "SendGrid driver: jq failed"; return 1; }

    printf '%s' "$payload" | _email_bearer_post "https://api.sendgrid.com/v3/mail/send" && return 0
    log_warn "SendGrid API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
    return 1
}


_email_driver_mailgun() {
    local subject="$1" body="$2"
    # Mailgun uses multipart/form-data; strip bare CRLFs that corrupt form fields.
    subject="${subject//$'\r'/}"; subject="${subject//$'\n'/}"
    body="${body//$'\r'/}";       body="${body//$'\n'/ }"
    local _from="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"

    local domain="${MAILGUN_DOMAIN:-}"
    [[ -z "$domain" ]] && domain="${_from##*@}"
    if [[ -z "$domain" ]]; then
        log_error "Mailgun driver: cannot determine domain. Set MAILGUN_DOMAIN in .env"
        return 1
    fi
    if [[ ! "$domain" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        log_error "Mailgun driver: invalid domain '${domain}'. Check MAILGUN_DOMAIN or SMTP_FROM."
        return 1
    fi

    local mg_api_host
    case "${MAILGUN_REGION:-us}" in
        us) mg_api_host="api.mailgun.net" ;;
        eu) mg_api_host="api.eu.mailgun.net" ;;
        *)  log_error "Mailgun driver: unrecognised MAILGUN_REGION='${MAILGUN_REGION:-}'. Valid: us eu"; return 1 ;;
    esac

    local tmp cfg code
    tmp=$(mktemp -t vw_email.XXXXXXXXXX)
    cfg=$(mktemp -t vw_ecfg.XXXXXXXXXX)
    if ! install -m 600 /dev/null "$cfg" 2>/dev/null; then
        rm -f "$tmp" "$cfg"
        log_error "Mailgun driver: failed to secure curl config temp file"
        return 1
    fi
    trap 'rm -f "$tmp" "$cfg" 2>/dev/null; trap - RETURN' RETURN
    printf 'user = "api:%s"\n' "${EMAIL_API_TOKEN}" >"$cfg"

    code=$(curl -s \
        --config "$cfg" \
        --connect-timeout 10 \
        --max-time 20 \
        --retry 2 \
        --retry-delay 3 \
        --retry-all-errors \
        -o "$tmp" -w "%{http_code}" \
        -X POST "https://${mg_api_host}/v3/${domain}/messages" \
        -F "from=${SMTP_FROM_NAME:-VaultWarden} <${_from}>" \
        -F "to=${ADMIN_EMAIL}" \
        -F "subject=${subject}" \
        -F "text=${body}" \
        -F "o:tracking=no" 2>/dev/null)

    local resp; resp=$(head -c 300 "$tmp" 2>/dev/null | tr -d '\n')
    [[ "$code" =~ ^2 ]] && return 0
    log_warn "Mailgun API HTTP ${code} (region=${MAILGUN_REGION:-us}, host=${mg_api_host}): ${resp}"
    return 1
}


_email_driver_postmark() {
    local subject="$1" body="$2"
    local _from="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"

    local payload
    payload=$(jq -n \
        --arg from_name "${SMTP_FROM_NAME:-VaultWarden}" \
        --arg from_email "$_from" \
        --arg to        "${ADMIN_EMAIL}" \
        --arg subject   "$subject" \
        --arg text      "$body" \
        '{
            From:          ($from_name + " <" + $from_email + ">"),
            To:            $to,
            Subject:       $subject,
            TextBody:      $text,
            MessageStream: "outbound"
        }') || { log_error "Postmark driver: jq failed"; return 1; }

    local tmp cfg code
    tmp=$(mktemp -t vw_email.XXXXXXXXXX)
    cfg=$(mktemp -t vw_ecfg.XXXXXXXXXX)
    if ! install -m 600 /dev/null "$cfg" 2>/dev/null; then
        rm -f "$tmp" "$cfg"
        log_error "Postmark driver: failed to secure curl config temp file"
        return 1
    fi
    trap 'rm -f "$tmp" "$cfg" 2>/dev/null; trap - RETURN' RETURN
    printf 'header = "X-Postmark-Server-Token: %s"\n' "${EMAIL_API_TOKEN}" >"$cfg"

    code=$(curl -s \
        --config "$cfg" \
        --connect-timeout 10 \
        --max-time 20 \
        --retry 2 \
        --retry-delay 3 \
        --retry-all-errors \
        -o "$tmp" -w "%{http_code}" \
        -X POST "https://api.postmarkapp.com/email" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        --data-binary "$payload" 2>/dev/null)

    local resp; resp=$(head -c 300 "$tmp" 2>/dev/null | tr -d '\n')
    if [[ ! "$code" =~ ^2 ]]; then
        log_warn "Postmark API HTTP ${code}: ${resp}"
        return 1
    fi
    # Postmark returns ErrorCode:0 on success even when HTTP 200.
    if printf '%s' "$resp" | jq -e '.ErrorCode == 0' >/dev/null 2>&1; then
        return 0
    fi
    log_warn "Postmark API: HTTP 200 but ErrorCode != 0: ${resp}"
    return 1
}


_email_driver_resend() {
    local subject="$1" body="$2"
    local _from="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"

    local payload
    payload=$(jq -n \
        --arg from_name  "${SMTP_FROM_NAME:-VaultWarden}" \
        --arg from_email "$_from" \
        --arg to         "${ADMIN_EMAIL}" \
        --arg subject    "$subject" \
        --arg text       "$body" \
        '{
            from:    ($from_name + " <" + $from_email + ">"),
            to:      [$to],
            subject: $subject,
            text:    $text
        }') || { log_error "Resend driver: jq failed"; return 1; }

    printf '%s' "$payload" | _email_bearer_post "https://api.resend.com/emails" && return 0
    log_warn "Resend API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
    return 1
}


# CyberPanel Email Delivery (platform.cyberpersons.com).
# EMAIL_PROVIDER accepts: cyberpersons | cyberperson | cyberpanel (all equivalent).
_email_driver_cyberpersons() {
    local subject="$1" body="$2"
    local _from="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"

    local payload
    payload=$(jq -n \
        --arg from_email "$_from" \
        --arg from_name  "${SMTP_FROM_NAME:-VaultWarden}" \
        --arg to         "${ADMIN_EMAIL}" \
        --arg subject    "$subject" \
        --arg text       "$body" \
        '{
            from:    { email: $from_email, name: $from_name },
            to:      [{ email: $to }],
            subject: $subject,
            text:    $text
        }') || { log_error "CyberPersons driver: jq failed"; return 1; }

    if printf '%s' "$payload" | _email_bearer_post "https://platform.cyberpersons.com/email/v1/send"; then
        [[ -n "${_ECURL_BODY}" ]] && log_debug "CyberPersons API response: ${_ECURL_BODY}"
        return 0
    fi
    log_warn "CyberPersons API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
    return 1
}


# ---------------------------------------------------------------------------
# _email_driver_cyberpersons_attachment SUBJECT BODY ATT_PATH ATT_NAME
#
# CyberPanel/CyberPersons does not document attachment support on their
# transactional API endpoint. Falls back to SMTP so recovery kits are still
# deliverable when the operator has SMTP credentials configured alongside
# the cyberpersons driver.
# ---------------------------------------------------------------------------
_email_driver_cyberpersons_attachment() {
    local subject="$1" body="$2" att_path="$3" att_name="$4"
    log_warn "CyberPersons/CyberPanel API does not support attachments — falling back to SMTP."
    _smtp_send_with_attachment "${ADMIN_EMAIL}" "$subject" "$body" "$att_path" "$att_name"
}


# DRIVER: host/postfix — pipes a minimal RFC-2822 message to sendmail -t.
# No API token required. EMAIL_MODE=host or EMAIL_PROVIDER=host|postfix.
# sendmail must be on PATH (standard in the postfix sidecar image).
_email_driver_postfix() {
    local subject="$1" body="$2"
    local _from="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
    local to_addr="${ADMIN_EMAIL:-}"

    [[ -z "$to_addr" ]] && { log_error "postfix driver: ADMIN_EMAIL is not set"; return 1; }
    command -v sendmail >/dev/null 2>&1 || {
        log_error "postfix driver: sendmail not found — is the postfix sidecar running?"
        return 1
    }

    printf 'From: %s <%s>\nTo: %s\nSubject: %s\n\n%s\n' \
        "${SMTP_FROM_NAME:-VaultWarden}" "$_from" "$to_addr" "$subject" "$body" \
        | sendmail -t -oi
}


# _normalise_email_subject SUBJECT
# Prepends "[VaultWarden]" prefix when absent. Single source of truth for
# both send_email() and clear_email_rate_limit() so rate-limit hashes match.
_normalise_email_subject() {
    local subject="$1"
    [[ "$subject" != "[VaultWarden]"* ]] && subject="[VaultWarden] ${subject}"
    printf '%s\n' "$subject"
}


# Resolves a writable rate-limit directory in priority order:
#   1. PROJECT_ROOT/.rate-limit  2. XDG_CACHE_HOME  3. /tmp fallback
_resolve_rate_limit_dir() {
    local candidates=(
        "${PROJECT_ROOT}/.rate-limit"
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
    printf '/tmp\n'
    return 1
}


_rate_limit_reset_message() {
    local last_file="$1" window_seconds="${EMAIL_RATE_WINDOW_SECONDS:-3600}"
    local last_time now reset_epoch remaining mins secs reset_at
    last_time=$(cat "$last_file" 2>/dev/null || printf '0')
    now=$(date +%s)
    reset_epoch=$(( last_time + window_seconds ))
    if (( reset_epoch > now )); then
        remaining=$(( reset_epoch - now )); mins=$(( remaining / 60 )); secs=$(( remaining % 60 ))
        reset_at=$(date -d "@${reset_epoch}" '+%H:%M:%S' 2>/dev/null \
               || date -r "$reset_epoch" '+%H:%M:%S' 2>/dev/null \
               || printf 'unknown time')
        printf 'resets in %dm %02ds (at %s)' "$mins" "$secs" "$reset_at"
    else
        printf 'window may have already reset — try ./maintenance.sh test-email'
    fi
}


_rate_limit_check() {
    local subject="$1" rate_limit_dir="$2"
    local last_email_file

    if ! command -v sha256sum >/dev/null 2>&1; then
        log_debug "_rate_limit_check: sha256sum not found — rate-limiting disabled"
        printf '/dev/null\n'
        return 0
    fi

    last_email_file="$rate_limit_dir/.vw_last_email_$(printf '%s' "$subject" | sha256sum | cut -c1-16)"

    if [[ "$subject" != *"CRITICAL"* ]] && [[ -f "$last_email_file" ]]; then
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
    return 0
}


# _resolve_smtp_method
# Returns transport label that must match the actual path taken by _smtp_send().
#   "smtp (direct relay)"    — SMTP_PASSWORD is set
#   "smtp (postfix sidecar)" — no SMTP_PASSWORD
_resolve_smtp_method() {
    if [[ -n "${SMTP_PASSWORD:-}" ]]; then
        printf 'smtp (direct relay)\n'
    else
        printf 'smtp (postfix sidecar)\n'
    fi
}


# _build_email_metadata_body BASE_BODY HOST_FQDN TIMESTAMP MODE PROVIDER METHOD
_build_email_metadata_body() {
    printf '%s\n\nEmail delivery metadata:\nHost:      %s\nTimestamp: %s\nMode:      %s\nProvider:  %s\nMethod:    %s' \
        "$1" "$2" "$3" "$4" "$5" "$6"
}


# ---------------------------------------------------------------------------
# _smtp_curl_upload MSG_FILE SMTP_FROM_ADDR RCPT_ADDR
#
# Shared SMTP curl transport used by both _smtp_send and _smtp_send_with_attachment.
# Path A (SMTP_PASSWORD set): direct relay with netrc auth on tmpfs.
# Path B (no SMTP_PASSWORD):  Postfix sidecar at VW_SMTP_HOST_PORT.
# ---------------------------------------------------------------------------
_smtp_curl_upload() {
    local msg_file="$1" from_addr="$2" rcpt_addr="$3"

    if [[ -n "${SMTP_PASSWORD:-}" ]]; then
        [[ -z "${SMTP_HOST:-}"     ]] && { log_error "_smtp_curl_upload: SMTP_HOST not set";     return 1; }
        [[ -z "${SMTP_USERNAME:-}" ]] && { log_error "_smtp_curl_upload: SMTP_USERNAME not set"; return 1; }

        local smtp_port="${SMTP_PORT:-587}"
        local smtp_security="${SMTP_SECURITY:-}"
        local smtp_url smtp_tls_flags=()

        [[ -z "$smtp_security" ]] && { [[ "$smtp_port" == "465" ]] && smtp_security="tls" || smtp_security="starttls"; }

        case "${smtp_security,,}" in
            tls|ssl)    smtp_url="smtps://${SMTP_HOST}:${smtp_port}" ;;
            starttls)   smtp_url="smtp://${SMTP_HOST}:${smtp_port}"; smtp_tls_flags=(--ssl-reqd) ;;
            none|plain) smtp_url="smtp://${SMTP_HOST}:${smtp_port}" ;;
            *)
                log_error "_smtp_curl_upload: unknown SMTP_SECURITY='${smtp_security}'. Valid: tls starttls none"
                return 1 ;;
        esac

        # Write credentials to tmpfs to keep them out of process argv.
        local netrc_file
        netrc_file=$(mktemp -p /dev/shm vw-smtp-netrc.XXXXXX 2>/dev/null || mktemp -t vw-smtp-netrc.XXXXXX)
        chmod 600 "$netrc_file"
        # shellcheck disable=SC2064
        trap "rm -f '${netrc_file}' 2>/dev/null" RETURN
        printf 'machine %s\nlogin %s\npassword %s\n' \
            "$SMTP_HOST" "$SMTP_USERNAME" "$SMTP_PASSWORD" >"$netrc_file"

        curl -s \
            --connect-timeout 15 \
            --max-time 60 \
            --retry 2 \
            --retry-delay 5 \
            "${smtp_tls_flags[@]}" \
            --url "$smtp_url" \
            --mail-from "$from_addr" \
            --mail-rcpt "$rcpt_addr" \
            --netrc-file "$netrc_file" \
            --upload-file "$msg_file"
        local _rc=$?
        rm -f "$netrc_file"
        return $_rc
    fi

    # Path B: Postfix sidecar (normal production path).
    local sidecar_addr="${VW_SMTP_HOST_PORT:-127.0.0.1:587}"
    local sidecar_host="${sidecar_addr%:*}" sidecar_port="${sidecar_addr##*:}"

    log_debug "_smtp_curl_upload: routing via Postfix sidecar at ${sidecar_addr}"

    # Fast liveness probe — avoids long curl timeout if postfix is down.
    if command -v nc >/dev/null 2>&1; then
        if ! nc -z -w 2 "$sidecar_host" "$sidecar_port" >/dev/null 2>&1; then
            log_warn "_smtp_curl_upload: Postfix sidecar unreachable at ${sidecar_addr}"
            return 1
        fi
    elif ! (echo >/dev/tcp/"$sidecar_host"/"$sidecar_port") >/dev/null 2>&1; then
        log_warn "_smtp_curl_upload: Postfix sidecar unreachable at ${sidecar_addr}"
        return 1
    fi

    curl -s \
        --connect-timeout 5 \
        --max-time 60 \
        --retry 1 \
        --retry-delay 2 \
        --url "smtp://${sidecar_host}:${sidecar_port}" \
        --mail-from "$from_addr" \
        --mail-rcpt "$rcpt_addr" \
        --upload-file "$msg_file"
    local _rc=$?
    [[ $_rc -ne 0 ]] && log_warn "_smtp_curl_upload: curl exit ${_rc} — is the postfix container running?"
    return $_rc
}


# _smtp_send <to> <subject> <body>
# Builds a plain text/plain RFC-5322 message and uploads it via _smtp_curl_upload.
_smtp_send() {
    local to="$1" subject="$2" body="$3"
    [[ -z "$to" ]] && { log_error "_smtp_send: recipient is empty"; return 1; }

    local from_addr="${SMTP_FROM_EMAIL:-${SMTP_FROM:-${SMTP_USERNAME:-}}}"
    local from_name="${SMTP_FROM_NAME:-VaultWarden}"
    local date_str; date_str=$(date -u '+%a, %d %b %Y %H:%M:%S +0000')

    local msg_file
    msg_file=$(mktemp -t vw_smtp.XXXXXXXXXX) || {
        log_error "_smtp_send: failed to create message temp file"
        return 1
    }
    install -m 600 /dev/null "$msg_file" 2>/dev/null || chmod 600 "$msg_file"
    # shellcheck disable=SC2064
    trap "rm -f '${msg_file}' 2>/dev/null; trap - RETURN" RETURN

    {
        printf 'From: "%s" <%s>\r\n' "$from_name" "$from_addr"
        printf 'To: %s\r\n'          "$to"
        printf 'Subject: %s\r\n'     "$subject"
        printf 'Date: %s\r\n'        "$date_str"
        printf 'MIME-Version: 1.0\r\n'
        printf 'Content-Type: text/plain; charset=UTF-8\r\n'
        printf 'Content-Transfer-Encoding: 7bit\r\n'
        printf '\r\n'
        while IFS= read -r line; do printf '%s\r\n' "$line"; done <<< "$body"
        printf '\r\n'
    } >"$msg_file" || { log_error "_smtp_send: failed to write message file"; return 1; }

    _smtp_curl_upload "$msg_file" "$from_addr" "$to"
}


# ---------------------------------------------------------------------------
# _smtp_send_with_attachment TO SUBJECT BODY ATT_PATH ATT_NAME
#
# Builds a multipart/mixed MIME message on tmpfs and uploads via _smtp_curl_upload.
# The attachment is base64-encoded (RFC 2045, 76-char fold) inline in the message
# file; no separate temp file for the encoded payload is needed.
# ---------------------------------------------------------------------------
_smtp_send_with_attachment() {
    local to="$1" subject="$2" body="$3" att_path="$4" att_name="$5"

    [[ -z "$to" ]]        && { log_error "_smtp_send_with_attachment: 'to' is empty";                 return 1; }
    [[ ! -f "$att_path" ]] && { log_error "_smtp_send_with_attachment: attachment not found: $att_path"; return 1; }

    local from_addr="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
    local from_name="${SMTP_FROM_NAME:-VaultWarden}"
    local date_str; date_str=$(date -u '+%a, %d %b %Y %H:%M:%S +0000')
    # Boundary derived from timestamp + sha256 to guarantee uniqueness.
    local boundary
    boundary="=====VW_$(date +%s%N 2>/dev/null | sha256sum 2>/dev/null | head -c 16 || openssl rand -hex 8)====="

    # Encode before opening the message file so failures abort cleanly.
    local att_b64
    if ! att_b64=$(base64 <"$att_path" 2>/dev/null); then
        log_error "_smtp_send_with_attachment: base64 encoding failed for: $att_path"
        return 1
    fi

    local msg_file
    msg_file=$(mktemp -p /dev/shm vw-mime.XXXXXX 2>/dev/null || mktemp -t vw-mime.XXXXXX) || {
        log_error "_smtp_send_with_attachment: failed to create MIME message temp file"
        return 1
    }
    install -m 600 /dev/null "$msg_file" 2>/dev/null || chmod 600 "$msg_file"
    # shellcheck disable=SC2064
    trap "rm -f '${msg_file}' 2>/dev/null; trap - RETURN" RETURN

    {
        printf 'From: "%s" <%s>\r\n'  "$from_name" "$from_addr"
        printf 'To: %s\r\n'           "$to"
        printf 'Subject: %s\r\n'      "$(_normalise_email_subject "$subject")"
        printf 'Date: %s\r\n'         "$date_str"
        printf 'MIME-Version: 1.0\r\n'
        printf 'Content-Type: multipart/mixed; boundary="%s"\r\n' "$boundary"
        printf '\r\n'
        printf -- '--%s\r\n'          "$boundary"
        printf 'Content-Type: text/plain; charset=UTF-8\r\n'
        printf 'Content-Transfer-Encoding: 7bit\r\n'
        printf '\r\n'
        while IFS= read -r _line; do printf '%s\r\n' "$_line"; done <<< "$body"
        printf '\r\n'
        printf -- '--%s\r\n'          "$boundary"
        printf 'Content-Type: application/octet-stream\r\n'
        printf 'Content-Transfer-Encoding: base64\r\n'
        printf 'Content-Disposition: attachment; filename="%s"\r\n' "$att_name"
        printf '\r\n'
        printf '%s' "$att_b64" | fold -w 76 | while IFS= read -r _b64line; do
            printf '%s\r\n' "$_b64line"
        done
        printf '\r\n'
        printf -- '--%s--\r\n'        "$boundary"
    } >"$msg_file" || { log_error "_smtp_send_with_attachment: failed to write MIME message"; return 1; }

    _smtp_curl_upload "$msg_file" "$from_addr" "$to"
}


# ---------------------------------------------------------------------------
# Attachment-capable API drivers  (SUBJECT BODY ATT_PATH ATT_NAME)
#
# All JSON built with jq --arg for safe escaping.
# Mailgun uses multipart/form-data natively — curl streams the file directly
# without requiring base64 encoding or shell variable injection.
# ---------------------------------------------------------------------------

_email_driver_mailgun_attachment() {
    local subject="$1" body="$2" att_path="$3" att_name="$4"
    subject="${subject//$'\r'/}"; subject="${subject//$'\n'/}"
    body="${body//$'\r'/}";       body="${body//$'\n'/ }"
    local _from="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"

    local domain="${MAILGUN_DOMAIN:-}"
    [[ -z "$domain" ]] && domain="${_from##*@}"
    if [[ -z "$domain" ]]; then
        log_error "Mailgun attachment driver: cannot determine domain. Set MAILGUN_DOMAIN in .env"
        return 1
    fi
    if [[ ! "$domain" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        log_error "Mailgun attachment driver: invalid domain '${domain}'"
        return 1
    fi

    local mg_api_host
    case "${MAILGUN_REGION:-us}" in
        us) mg_api_host="api.mailgun.net" ;;
        eu) mg_api_host="api.eu.mailgun.net" ;;
        *)  log_error "Mailgun attachment driver: unrecognised MAILGUN_REGION='${MAILGUN_REGION:-}'"; return 1 ;;
    esac

    local tmp cfg code
    tmp=$(mktemp -t vw_email.XXXXXXXXXX)
    cfg=$(mktemp -t vw_ecfg.XXXXXXXXXX)
    if ! install -m 600 /dev/null "$cfg" 2>/dev/null; then
        rm -f "$tmp" "$cfg"
        log_error "Mailgun attachment driver: failed to secure curl config temp file"
        return 1
    fi
    trap 'rm -f "$tmp" "$cfg" 2>/dev/null; trap - RETURN' RETURN
    printf 'user = "api:%s"\n' "${EMAIL_API_TOKEN}" >"$cfg"

    code=$(curl -s \
        --config "$cfg" \
        --connect-timeout 10 --max-time 60 \
        -o "$tmp" -w "%{http_code}" \
        -X POST "https://${mg_api_host}/v3/${domain}/messages" \
        -F "from=${SMTP_FROM_NAME:-VaultWarden} <${_from}>" \
        -F "to=${ADMIN_EMAIL}" \
        -F "subject=${subject}" \
        -F "text=${body}" \
        -F "o:tracking=no" \
        -F "attachment=@${att_path};filename=${att_name}" 2>/dev/null)

    local resp; resp=$(head -c 300 "$tmp" 2>/dev/null | tr -d '\n')
    [[ "$code" =~ ^2 ]] && return 0
    log_warn "Mailgun attachment API HTTP ${code}: ${resp}"
    return 1
}


_email_driver_sendgrid_attachment() {
    local subject="$1" body="$2" att_path="$3" att_name="$4"
    local _from="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"

    local att_b64
    if ! att_b64=$(base64 <"$att_path" | tr -d '\n' 2>/dev/null); then
        log_error "SendGrid attachment driver: base64 encoding failed"
        return 1
    fi

    local payload
    # SendGrid attachment schema requires: content (base64), type (MIME), filename, disposition.
    payload=$(jq -n \
        --arg from_email  "$_from" \
        --arg from_name   "${SMTP_FROM_NAME:-VaultWarden}" \
        --arg to          "${ADMIN_EMAIL}" \
        --arg subject     "$subject" \
        --arg text        "$body" \
        --arg att_b64     "$att_b64" \
        --arg att_name    "$att_name" \
        '{
            personalizations: [{ to: [{ email: $to }] }],
            from:    { email: $from_email, name: $from_name },
            subject: $subject,
            content: [{ type: "text/plain", value: $text }],
            attachments: [{
                content:     $att_b64,
                type:        "application/octet-stream",
                filename:    $att_name,
                disposition: "attachment"
            }],
            tracking_settings: {
                click_tracking:        { enable: false },
                open_tracking:         { enable: false },
                subscription_tracking: { enable: false }
            }
        }') || { log_error "SendGrid attachment driver: jq failed"; return 1; }

    printf '%s' "$payload" | _email_bearer_post "https://api.sendgrid.com/v3/mail/send" && return 0
    log_warn "SendGrid attachment API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
    return 1
}


_email_driver_mailersend_attachment() {
    local subject="$1" body="$2" att_path="$3" att_name="$4"
    local _from="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"

    local att_b64
    if ! att_b64=$(base64 <"$att_path" | tr -d '\n' 2>/dev/null); then
        log_error "MailerSend attachment driver: base64 encoding failed"
        return 1
    fi

    local payload
    # MailerSend auto-detects MIME type from filename; disposition field optional but explicit.
    payload=$(jq -n \
        --arg from_email "$_from" \
        --arg from_name  "${SMTP_FROM_NAME:-VaultWarden}" \
        --arg to         "${ADMIN_EMAIL}" \
        --arg subject    "$subject" \
        --arg text       "$body" \
        --arg att_b64    "$att_b64" \
        --arg att_name   "$att_name" \
        '{
            from:     { email: $from_email, name: $from_name },
            to:       [{ email: $to }],
            subject:  $subject,
            text:     $text,
            attachments: [{
                content:     $att_b64,
                filename:    $att_name,
                disposition: "attachment"
            }],
            settings: { track_clicks: false, track_opens: false }
        }') || { log_error "MailerSend attachment driver: jq failed"; return 1; }

    if printf '%s' "$payload" | _email_bearer_post "https://api.mailersend.com/v1/email"; then
        [[ -n "${_ECURL_BODY}" ]] && log_warn "MailerSend attachment: queued with warnings: ${_ECURL_BODY}"
        return 0
    fi
    log_warn "MailerSend attachment API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
    return 1
}


_email_driver_postmark_attachment() {
    local subject="$1" body="$2" att_path="$3" att_name="$4"
    local _from="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"

    local att_b64
    if ! att_b64=$(base64 <"$att_path" | tr -d '\n' 2>/dev/null); then
        log_error "Postmark attachment driver: base64 encoding failed"
        return 1
    fi

    local payload
    # Postmark requires Name, Content (base64), ContentType — all three are mandatory.
    payload=$(jq -n \
        --arg from_name  "${SMTP_FROM_NAME:-VaultWarden}" \
        --arg from_email "$_from" \
        --arg to         "${ADMIN_EMAIL}" \
        --arg subject    "$subject" \
        --arg text       "$body" \
        --arg att_b64    "$att_b64" \
        --arg att_name   "$att_name" \
        '{
            From:          ($from_name + " <" + $from_email + ">"),
            To:            $to,
            Subject:       $subject,
            TextBody:      $text,
            MessageStream: "outbound",
            Attachments: [{
                Name:        $att_name,
                Content:     $att_b64,
                ContentType: "application/octet-stream"
            }]
        }') || { log_error "Postmark attachment driver: jq failed"; return 1; }

    local tmp cfg code
    tmp=$(mktemp -t vw_email.XXXXXXXXXX)
    cfg=$(mktemp -t vw_ecfg.XXXXXXXXXX)
    if ! install -m 600 /dev/null "$cfg" 2>/dev/null; then
        rm -f "$tmp" "$cfg"
        log_error "Postmark attachment driver: failed to secure curl config temp file"
        return 1
    fi
    trap 'rm -f "$tmp" "$cfg" 2>/dev/null; trap - RETURN' RETURN
    printf 'header = "X-Postmark-Server-Token: %s"\n' "${EMAIL_API_TOKEN}" >"$cfg"

    code=$(curl -s \
        --config "$cfg" \
        --connect-timeout 10 --max-time 60 \
        -o "$tmp" -w "%{http_code}" \
        -X POST "https://api.postmarkapp.com/email" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        --data-binary "$payload" 2>/dev/null)

    local resp; resp=$(head -c 300 "$tmp" 2>/dev/null | tr -d '\n')
    if [[ ! "$code" =~ ^2 ]]; then
        log_warn "Postmark attachment API HTTP ${code}: ${resp}"
        return 1
    fi
    if printf '%s' "$resp" | jq -e '.ErrorCode == 0' >/dev/null 2>&1; then return 0; fi
    log_warn "Postmark attachment API: HTTP 200 but ErrorCode != 0: ${resp}"
    return 1
}


_email_driver_resend_attachment() {
    local subject="$1" body="$2" att_path="$3" att_name="$4"
    local _from="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"

    local att_b64
    if ! att_b64=$(base64 <"$att_path" | tr -d '\n' 2>/dev/null); then
        log_error "Resend attachment driver: base64 encoding failed"
        return 1
    fi

    local payload
    # Resend schema: filename (required), content (base64, required), contentType (optional).
    payload=$(jq -n \
        --arg from_name  "${SMTP_FROM_NAME:-VaultWarden}" \
        --arg from_email "$_from" \
        --arg to         "${ADMIN_EMAIL}" \
        --arg subject    "$subject" \
        --arg text       "$body" \
        --arg att_b64    "$att_b64" \
        --arg att_name   "$att_name" \
        '{
            from:    ($from_name + " <" + $from_email + ">"),
            to:      [$to],
            subject: $subject,
            text:    $text,
            attachments: [{
                filename:    $att_name,
                content:     $att_b64,
                contentType: "application/octet-stream"
            }]
        }') || { log_error "Resend attachment driver: jq failed"; return 1; }

    printf '%s' "$payload" | _email_bearer_post "https://api.resend.com/emails" && return 0
    log_warn "Resend attachment API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
    return 1
}


# ---------------------------------------------------------------------------
# _dispatch_email_with_attachment TO SUBJECT BODY ATT_PATH ATT_NAME
#
# Routes to the attachment-capable driver variant for the configured provider,
# falling back to SMTP (_smtp_send_with_attachment) on API failure or when
# no token is available. Does not apply rate-limiting.
# ---------------------------------------------------------------------------
_dispatch_email_with_attachment() {
    local to="$1" subject="$2" body="$3" att_path="$4" att_name="$5"

    [[ -z "$to" ]]         && { log_error "_dispatch_email_with_attachment: 'to' is empty";                  return 1; }
    [[ ! -f "$att_path" ]] && { log_error "_dispatch_email_with_attachment: attachment not found: $att_path"; return 1; }

    subject=$(_normalise_email_subject "$subject")

    local mode="${EMAIL_MODE:-auto}"
    local provider="${EMAIL_PROVIDER:-smtp}"
    # host MTA has no attachment support; treat it as SMTP.
    [[ "$provider" == "smtp" || "$provider" == "host" ]] && mode="smtp"

    local api_token="${EMAIL_API_TOKEN:-}"
    if [[ -z "$api_token" ]] && declare -f decrypt_secret &>/dev/null; then
        api_token="$(decrypt_secret email_api_token 2>/dev/null || true)"
    fi

    if [[ "$mode" == "auto" || "$mode" == "api" ]]; then
        local driver_suffix
        if driver_suffix=$(_email_driver_lookup "$provider" 2>/dev/null); then
            local att_fn="_email_driver_${driver_suffix}_attachment"
            if declare -f "$att_fn" &>/dev/null && [[ -n "$api_token" ]]; then
                if EMAIL_API_TOKEN="$api_token" "$att_fn" "$subject" "$body" "$att_path" "$att_name"; then
                    log_success "Attachment sent via ${provider} API to ${to}"
                    return 0
                fi
                log_warn "_dispatch_email_with_attachment: ${provider} driver failed — falling back to SMTP"
            elif [[ -z "$api_token" ]]; then
                log_warn "_dispatch_email_with_attachment: EMAIL_API_TOKEN empty for ${provider} — falling back to SMTP"
            fi
        fi
    fi

    if _smtp_send_with_attachment "$to" "$subject" "$body" "$att_path" "$att_name"; then
        log_success "Attachment sent via SMTP to ${to}"
        return 0
    fi

    log_error "_dispatch_email_with_attachment: all delivery paths failed (provider=${provider})"
    return 1
}


# ---------------------------------------------------------------------------
# send_email [TO] SUBJECT BODY [ATT_PATH [ATT_NAME]]
#
# TO defaults to ${ADMIN_EMAIL}.
# When ATT_PATH is a readable file, routes to _dispatch_email_with_attachment
# (bypasses rate-limit and auto-fallback loop; existing sends are unchanged).
# ATT_NAME defaults to basename of ATT_PATH.
#
# Normal delivery order: HTTP API → SMTP/Postfix sidecar → host MTA.
# Token resolution: EMAIL_API_TOKEN env var, then decrypt_secret email_api_token.
# ---------------------------------------------------------------------------
send_email() {
    local to subject body att_path att_name
    if [[ $# -ge 3 ]]; then
        to="$1"
        subject="${2:-VaultWarden Notification}"
        body="${3:-}"
        att_path="${4:-}"
        att_name="${5:-}"
    else
        to="${ADMIN_EMAIL:-}"
        subject="${1:-VaultWarden Notification}"
        body="${2:-}"
        att_path=""
        att_name=""
    fi

    # Attachment fast-path: bypass rate-limit and auto-fallback loop.
    if [[ -n "$att_path" ]] && [[ -f "$att_path" ]]; then
        [[ -z "$att_name" ]] && att_name="$(basename "$att_path")"
        _dispatch_email_with_attachment "$to" "$subject" "$body" "$att_path" "$att_name"
        return $?
    fi

    local mode="${EMAIL_MODE:-auto}"
    local provider="${EMAIL_PROVIDER:-smtp}"

    if [[ "$provider" == "smtp" ]]; then
        mode="smtp"
    elif [[ "$provider" == "host" ]]; then
        mode="host"
    fi

    case "$mode" in
        auto|api|smtp|host) ;;
        *)
            log_error "Unknown EMAIL_MODE='${mode}'. Valid values: auto api smtp host"
            return 1
            ;;
    esac

    subject=$(_normalise_email_subject "$subject")

    local rate_limit_dir
    rate_limit_dir=$(_resolve_rate_limit_dir) || {
        log_debug "send_email: rate-limit dir unavailable — rate-limiting disabled"
        rate_limit_dir=""
    }

    local stamp_file
    if ! stamp_file=$(_rate_limit_check "$subject" "$rate_limit_dir"); then
        return 0
    fi

    local host_fqdn ts
    host_fqdn="$(hostname -f 2>/dev/null || hostname)"
    ts="$(date -uIs)"

    local base_body="$body"
    local api_token=""
    local api_driver_fn=""

    if [[ "$mode" == "auto" || "$mode" == "api" ]]; then
        local driver_suffix
        if ! driver_suffix=$(_email_driver_lookup "$provider" 2>/dev/null); then
            log_error "Unknown EMAIL_PROVIDER='${provider}'"
            log_info  "Valid providers: mailersend sendgrid mailgun postmark resend cyberpersons cyberpanel smtp host"
            [[ "$mode" == "api" ]] && return 1
        else
            local driver_fn="_email_driver_${driver_suffix}"
            local _api_token="${EMAIL_API_TOKEN:-}"
            if [[ -z "$_api_token" ]] && declare -f decrypt_secret &>/dev/null; then
                _api_token="$(decrypt_secret email_api_token 2>/dev/null || true)"
            fi
            api_token="$_api_token"
            api_driver_fn="$driver_fn"

            local api_body
            api_body="$(_build_email_metadata_body \
                "$base_body" "$host_fqdn" "$ts" "$mode" "$provider" \
                "api (${provider})")"

            if [[ -z "$_api_token" ]]; then
                if [[ "$mode" == "api" ]]; then
                    log_error "EMAIL_MODE=api but EMAIL_API_TOKEN is empty — cannot send. Run: ./utilities/secrets-rotate.sh email_api_token"
                    return 1
                fi
                log_warn "EMAIL_PROVIDER=${provider} set but EMAIL_API_TOKEN is empty — falling back to SMTP. Run: ./utilities/secrets-rotate.sh email_api_token"
            elif EMAIL_API_TOKEN="$_api_token" "$driver_fn" "$subject" "$api_body"; then
                log_success "Email sent via ${provider} API: ${subject}"
                date +%s >"$stamp_file" 2>/dev/null || true
                return 0
            else
                if [[ "$mode" == "api" ]]; then
                    log_error "EMAIL_MODE=api: ${provider} API failed — no fallback configured"
                    return 1
                fi
                log_error "${provider} API failed — falling back to SMTP relay"
            fi
        fi
    fi

    if [[ "$mode" == "auto" || "$mode" == "smtp" ]]; then
        local smtp_method smtp_body
        smtp_method="$(_resolve_smtp_method)"
        smtp_body="$(_build_email_metadata_body \
            "$base_body" "$host_fqdn" "$ts" "$mode" "$provider" \
            "$smtp_method")"

        if _smtp_send "$to" "$subject" "$smtp_body"; then
            log_success "Email sent via SMTP relay (${SMTP_HOST:-unconfigured}:${SMTP_PORT:-587}): ${subject}"
            date +%s >"$stamp_file" 2>/dev/null || true
            return 0
        fi
        if [[ "$mode" == "smtp" ]]; then
            log_error "EMAIL_MODE=smtp: SMTP relay failed — no fallback configured"
            return 1
        fi
        log_warn "SMTP relay failed — falling back to host MTA"
    fi

    local host_mta_failed=false
    if [[ "$mode" == "auto" || "$mode" == "host" ]]; then
        local host_body
        host_body="$(_build_email_metadata_body \
            "$base_body" "$host_fqdn" "$ts" "$mode" "$provider" \
            "host mta (sendmail/postfix)")"

        if command -v mail &>/dev/null; then
            if printf '%s' "$host_body" | mail -s "$subject" "$to" 2>/dev/null; then
                log_success "Email sent via host MTA: ${subject}"
                date +%s >"$stamp_file" 2>/dev/null || true
                return 0
            fi
            host_mta_failed=true
        else
            host_mta_failed=true
        fi
        if [[ "$mode" == "host" ]]; then
            log_error "EMAIL_MODE=host: host MTA failed or unavailable — no fallback configured"
            return 1
        fi
    fi

    if [[ "$mode" == "auto" && "$host_mta_failed" == "true" && -n "$api_token" && -n "$api_driver_fn" ]]; then
        log_error "SMTP/host MTA unavailable — attempting emergency API bypass (${provider})"

        local emergency_body
        emergency_body="$(_build_email_metadata_body \
            "$base_body" "$host_fqdn" "$ts" "$mode" "$provider" \
            "api emergency bypass (${provider})")"
        emergency_body="${emergency_body}

⚠ Delivery note: Sent via emergency API bypass after SMTP/host MTA failure."

        if EMAIL_API_TOKEN="$api_token" "$api_driver_fn" "$subject" "$emergency_body"; then
            log_success "Emergency API bypass succeeded via ${provider}: ${subject}"
            date +%s >"$stamp_file" 2>/dev/null || true
            return 0
        fi
        log_error "Emergency API bypass failed via ${provider}"
    elif [[ "$mode" == "auto" && "$host_mta_failed" == "true" ]]; then
        log_error "Emergency API bypass skipped: EMAIL_API_TOKEN not resolved for '${provider}' — run: ./utilities/secrets-rotate.sh email_api_token"
    fi

    log_error "All email delivery methods failed (mode=${mode}, provider=${provider}, subject=${subject})"
    return 1
}


send_notification_email() {
    send_email "$1" "$2"
}


# clear_email_rate_limit SUBJECT
#
# Removes the rate-limit stamp for SUBJECT so the next send fires immediately.
# Call from health-check scripts when an alerting condition resolves, to ensure
# the next fault produces a fresh notification rather than waiting out the TTL.
# Subject is normalised via _normalise_email_subject so bare or prefixed forms match.
clear_email_rate_limit() {
    local subject="${1:-}"
    [[ -z "$subject" ]] && { log_warn "clear_email_rate_limit: subject is empty — nothing to clear"; return 0; }

    subject=$(_normalise_email_subject "$subject")

    local rate_limit_dir
    rate_limit_dir=$(_resolve_rate_limit_dir) || {
        log_debug "clear_email_rate_limit: rate-limit dir unavailable — nothing to clear"
        return 0
    }

    if ! command -v sha256sum >/dev/null 2>&1; then
        log_debug "clear_email_rate_limit: sha256sum not found — nothing to clear"
        return 0
    fi
    local stamp_file="$rate_limit_dir/.vw_last_email_$(printf '%s' "$subject" | sha256sum | cut -c1-16)"
    if [[ -f "$stamp_file" ]]; then
        rm -f "$stamp_file" 2>/dev/null || true
        log_debug "clear_email_rate_limit: cleared stamp for '${subject}'"
    else
        log_debug "clear_email_rate_limit: no stamp found for '${subject}'"
    fi
    return 0
}


export -f _email_bearer_post _email_driver_lookup
export -f _email_driver_mailersend _email_driver_sendgrid _email_driver_mailgun
export -f _email_driver_postmark _email_driver_resend _email_driver_postfix
export -f _email_driver_cyberpersons
export -f _email_driver_mailgun_attachment _email_driver_sendgrid_attachment
export -f _email_driver_mailersend_attachment _email_driver_postmark_attachment
export -f _email_driver_resend_attachment _email_driver_cyberpersons_attachment
export -f _smtp_curl_upload _smtp_send _smtp_send_with_attachment
export -f _dispatch_email_with_attachment
export -f _normalise_email_subject _resolve_rate_limit_dir _rate_limit_reset_message _rate_limit_check
export -f _resolve_smtp_method _build_email_metadata_body
export -f send_email send_notification_email clear_email_rate_limit
