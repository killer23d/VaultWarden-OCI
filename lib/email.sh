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
#   Transport : _email_bearer_post, _smtp_send
#   Helpers   : _email_json_escape, _email_driver_lookup,
#               _normalise_email_subject, _resolve_rate_limit_dir,
#               _rate_limit_check, _resolve_smtp_method,
#               _build_email_metadata_body
#   Dispatch  : _dispatch_email_with_attachment
#   Public    : send_email, send_notification_email, clear_email_rate_limit
#
# Depends on / Load order:
#   lib/log.sh is auto-loaded if it has not already been sourced.
#   lib/common.sh should be sourced before this file for shared utility helpers.
#
# Canonical caller source block:
#   source "${LIB_DIR}/log.sh"
#   source "${LIB_DIR}/common.sh"
#   source "${LIB_DIR}/email.sh"

[[ -n "${VAULTWARDEN_EMAIL_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_EMAIL_LIB_LOADED=1

# Self-load log.sh if not already loaded — allows this lib to be sourced
# directly without going through common.sh or a caller that pre-loads log.sh.
_VW_EMAIL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${VW_LOG_LIB_LOADED:-}" ]] || source "${_VW_EMAIL_LIB_DIR}/log.sh"
unset _VW_EMAIL_LIB_DIR

_ECURL_CODE=""
_ECURL_BODY=""


# Strips raw control chars U+0000-U+001F (EM-M2) then encodes the five
# characters that MUST be escaped in a JSON string value.
_email_json_escape() {
    local str="$1"
    str=$(LC_ALL=C printf '%s' "$str" \
        | LC_ALL=C sed 's/[\x00-\x08\x0b\x0c\x0e-\x1f]//g')
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    printf '%s' "$str"
}


_email_json_post() {
    local url="$1" header_name="$2" header_value="$3" payload="$4"
    local response_file config_file payload_file error_file

    if [[ "$header_name" == *$'\r'* || "$header_name" == *$'\n'* \
       || "$header_value" == *$'\r'* || "$header_value" == *$'\n'* ]]; then
        log_error "_email_json_post: invalid newline in HTTP header"
        return 1
    fi

    response_file=$(_email_make_temp_file vw-email-response) || return 1
    config_file=$(_email_make_temp_file vw-email-config) || { rm -f "$response_file"; return 1; }
    payload_file=$(_email_make_temp_file vw-email-payload) || { rm -f "$response_file" "$config_file"; return 1; }
    error_file=$(_email_make_temp_file vw-email-error) || {
        rm -f "$response_file" "$config_file" "$payload_file"
        return 1
    }

    local escaped_header
    escaped_header="${header_name}: ${header_value}"
    escaped_header="${escaped_header//\\/\\\\}"
    escaped_header="${escaped_header//\"/\\\"}"
    printf 'header = "%s"\n' "$escaped_header" > "$config_file"
    printf '%s' "$payload" > "$payload_file"

    local code="" rc=0
    code=$(curl --silent --show-error \
        --config "$config_file" \
        --connect-timeout 10 \
        --max-time "${EMAIL_API_TIMEOUT:-60}" \
        --output "$response_file" \
        --write-out '%{http_code}' \
        --request POST "$url" \
        --header 'Content-Type: application/json' \
        --data-binary "@${payload_file}" 2>"$error_file") || rc=$?

    if [[ $rc -ne 0 ]]; then
        _ECURL_CODE="curl:${rc}"
        _ECURL_BODY=$(head -c 400 "$error_file" 2>/dev/null | tr '\r\n' ' ' || true)
    else
        _ECURL_CODE="$code"
        _ECURL_BODY=$(head -c 400 "$response_file" 2>/dev/null | tr '\r\n' ' ' || true)
    fi

    rm -f "$response_file" "$config_file" "$payload_file" "$error_file"
    [[ $rc -eq 0 && "$code" =~ ^2 ]]
}

_email_bearer_post() {
    local url="$1" payload="$2"
    local token="${EMAIL_API_TOKEN:-}"
    if [[ -z "$token" ]]; then
        log_error "_email_bearer_post: EMAIL_API_TOKEN is empty"
        return 1
    fi
    _email_json_post "$url" "Authorization" "Bearer ${token}" "$payload"
}

# _email_driver_lookup PROVIDER
# Prints the driver function suffix for PROVIDER, or returns 1 if unknown.
# Implemented as a single case statement so it works consistently in both the
# current shell and child subshells without exported registry state.
# VW_EMAIL_ROUTING_V2: shared provider, validation, and attachment helpers.
_email_driver_lookup() {
    local provider="${1,,}"
    case "$provider" in
        mailersend|sendgrid|mailgun|postmark|resend|cyberpersons)
            printf '%s' "$provider"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

_email_resolve_api_token() {
    local token="${EMAIL_API_TOKEN:-}"
    if [[ -z "$token" ]] && declare -f decrypt_secret &>/dev/null; then
        token="$(decrypt_secret email_api_token 2>/dev/null || true)"
    fi
    printf '%s' "$token"
}

_email_validate_address_value() {
    local label="$1" value="$2"
    if [[ -z "$value" ]]; then
        log_error "${label} is empty"
        return 1
    fi
    if [[ "$value" == *$'\r'* || "$value" == *$'\n'* ]]; then
        log_error "${label} contains a prohibited newline"
        return 1
    fi
    return 0
}

_email_safe_attachment_name() {
    local name
    name=$(basename -- "${1:-attachment.bin}")
    name=$(printf '%s' "$name" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/_/g')
    [[ -n "$name" ]] || name="attachment.bin"
    printf '%s' "$name"
}

_email_base64_file() {
    local path="$1"
    [[ -f "$path" ]] || return 1
    (set -o pipefail; base64 < "$path" | tr -d '\r\n')
}

_email_attachment_content_type() {
    local name="${1,,}"
    case "$name" in
        *.zip) printf 'application/zip' ;;
        *.txt|*.log|*.csv) printf 'text/plain' ;;
        *.json) printf 'application/json' ;;
        *.pdf) printf 'application/pdf' ;;
        *) printf 'application/octet-stream' ;;
    esac
}

_email_mailgun_post() {
    local to="$1" subject="$2" body="$3"
    local att_path="${4:-}" att_name="${5:-}"
    local from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"

    _email_validate_address_value "recipient" "$to" || return 1
    _email_validate_address_value "sender" "$from_email" || return 1

    local domain="${MAILGUN_DOMAIN:-}"
    [[ -n "$domain" ]] || domain="${from_email##*@}"
    if [[ -z "$domain" || ! "$domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
        log_error "Mailgun driver: invalid or missing domain '${domain}'"
        return 1
    fi

    local region="${MAILGUN_REGION:-us}" api_host
    case "${region,,}" in
        us) api_host="api.mailgun.net" ;;
        eu) api_host="api.eu.mailgun.net" ;;
        *)
            log_error "Mailgun driver: unrecognised MAILGUN_REGION='${region}'. Valid values: us eu"
            return 1
            ;;
    esac

    if [[ -n "$att_path" && ! -f "$att_path" ]]; then
        log_error "Mailgun attachment driver: attachment not found: $att_path"
        return 1
    fi

    local api_token="${EMAIL_API_TOKEN:-}"
    if [[ -z "$api_token" ]]; then
        log_error "Mailgun driver: EMAIL_API_TOKEN is empty"
        return 1
    fi

    local response_file config_file error_file
    response_file=$(_email_make_temp_file vw-mailgun-response) || return 1
    config_file=$(_email_make_temp_file vw-mailgun-config) || { rm -f "$response_file"; return 1; }
    error_file=$(_email_make_temp_file vw-mailgun-error) || {
        rm -f "$response_file" "$config_file"
        return 1
    }

    local auth_value="api:${api_token}"
    if [[ "$auth_value" == *$'\r'* || "$auth_value" == *$'\n'* ]]; then
        rm -f "$response_file" "$config_file" "$error_file"
        log_error "Mailgun driver: API token contains a prohibited newline"
        return 1
    fi
    auth_value="${auth_value//\\/\\\\}"
    auth_value="${auth_value//\"/\\\"}"
    printf 'user = "%s"\n' "$auth_value" > "$config_file"
    unset auth_value

    subject="${subject//$'\r'/ }"
    subject="${subject//$'\n'/ }"

    local -a args=(
        --silent --show-error
        --config "$config_file"
        --connect-timeout 10
        --max-time "${EMAIL_API_TIMEOUT:-60}"
        --output "$response_file"
        --write-out '%{http_code}'
        --request POST "https://${api_host}/v3/${domain}/messages"
        --form-string "from=${SMTP_FROM_NAME:-VaultWarden} <${from_email}>"
        --form-string "to=${to}"
        --form-string "subject=${subject}"
        --form-string "text=${body}"
        --form-string "o:tracking=no"
    )

    if [[ -n "$att_path" ]]; then
        att_name=$(_email_safe_attachment_name "$att_name")
        local content_type
        content_type=$(_email_attachment_content_type "$att_name")
        args+=(--form "attachment=@${att_path};filename=${att_name};type=${content_type}")
    fi

    local code="" rc=0
    code=$(curl "${args[@]}" 2>"$error_file") || rc=$?
    local response
    if [[ $rc -ne 0 ]]; then
        response=$(head -c 400 "$error_file" 2>/dev/null | tr '\r\n' ' ' || true)
        log_warn "Mailgun transport failed (curl exit ${rc}, region=${region}, host=${api_host}): ${response:-no diagnostic returned}"
    else
        response=$(head -c 400 "$response_file" 2>/dev/null | tr '\r\n' ' ' || true)
        if [[ ! "$code" =~ ^2 ]]; then
            log_warn "Mailgun API HTTP ${code} (region=${region}, host=${api_host}): ${response}"
            rc=1
        fi
    fi

    rm -f "$response_file" "$config_file" "$error_file"
    return "$rc"
}


_email_driver_mailersend() {
    local to="$1" subject="$2" body="$3"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
    fn=$(_email_json_escape "${SMTP_FROM_NAME:-VaultWarden}")
    fe=$(_email_json_escape "$from_email")
    ae=$(_email_json_escape "$to")

    local payload
    payload=$(cat <<EOF
{
    "from": { "email": "${fe}", "name": "${fn}" },
    "to":   [ { "email": "${ae}" } ],
    "subject": "${s}",
    "text":    "${b}",
    "settings": { "track_clicks": false, "track_opens": false }
}
EOF
)

    if _email_bearer_post "https://api.mailersend.com/v1/email" "$payload"; then
        [[ -n "${_ECURL_BODY}" ]] && log_warn "MailerSend: queued with warnings: ${_ECURL_BODY}"
        return 0
    fi
    log_warn "MailerSend API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
    return 1
}


_email_driver_sendgrid() {
    local to="$1" subject="$2" body="$3"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
    fn=$(_email_json_escape "${SMTP_FROM_NAME:-VaultWarden}")
    fe=$(_email_json_escape "$from_email")
    ae=$(_email_json_escape "$to")

    local payload
    payload=$(cat <<EOF
{
    "personalizations": [ { "to": [ { "email": "${ae}" } ] } ],
    "from":    { "email": "${fe}", "name": "${fn}" },
    "subject": "${s}",
    "content": [ { "type": "text/plain", "value": "${b}" } ],
    "tracking_settings": {
        "click_tracking":        { "enable": false },
        "open_tracking":         { "enable": false },
        "subscription_tracking": { "enable": false }
    }
}
EOF
)

    _email_bearer_post "https://api.sendgrid.com/v3/mail/send" "$payload" && return 0
    log_warn "SendGrid API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
    return 1
}


_email_driver_mailgun() {
    local to="$1" subject="$2" body="$3"
    _email_mailgun_post "$to" "$subject" "$body"
}


_email_driver_postmark() {
    local to="$1" subject="$2" body="$3"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
    fn=$(_email_json_escape "${SMTP_FROM_NAME:-VaultWarden}")
    fe=$(_email_json_escape "$from_email")
    ae=$(_email_json_escape "$to")

    local payload
    payload=$(cat <<EOF
{
    "From":          "${fn} <${fe}>",
    "To":            "${ae}",
    "Subject":       "${s}",
    "TextBody":      "${b}",
    "MessageStream": "outbound"
}
EOF
)

    if ! _email_json_post "https://api.postmarkapp.com/email" \
            "X-Postmark-Server-Token" "${EMAIL_API_TOKEN}" "$payload"; then
        log_warn "Postmark API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
        return 1
    fi
    if grep -Eq '"ErrorCode"[[:space:]]*:[[:space:]]*0' <<< "${_ECURL_BODY}"; then
        return 0
    fi
    log_warn "Postmark API returned a non-zero ErrorCode: ${_ECURL_BODY}"
    return 1
}


_email_driver_resend() {
    local to="$1" subject="$2" body="$3"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
    fn=$(_email_json_escape "${SMTP_FROM_NAME:-VaultWarden}")
    fe=$(_email_json_escape "$from_email")
    ae=$(_email_json_escape "$to")

    local payload
    payload=$(cat <<EOF
{
    "from":    "${fn} <${fe}>",
    "to":      ["${ae}"],
    "subject": "${s}",
    "text":    "${b}"
}
EOF
)

    _email_bearer_post "https://api.resend.com/emails" "$payload" && return 0
    log_warn "Resend API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
    return 1
}


_email_driver_cyberpersons() {
    local to="$1" subject="$2" body="$3"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
    fn=$(_email_json_escape "${SMTP_FROM_NAME:-VaultWarden}")
    fe=$(_email_json_escape "$from_email")
    ae=$(_email_json_escape "$to")

    local payload
    payload=$(cat <<EOF
{
    "from": { "email": "${fe}", "name": "${fn}" },
    "to": [ { "email": "${ae}" } ],
    "subject": "${s}",
    "text": "${b}"
}
EOF
)

    if _email_bearer_post "https://platform.cyberpersons.com/email/v1/send" "$payload"; then
        [[ -n "${_ECURL_BODY}" ]] && log_debug "CyberPersons API response: ${_ECURL_BODY}"
        return 0
    fi
    log_warn "CyberPersons API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
    return 1
}


# ---------------------------------------------------------------------------
# _email_driver_cyberpersons_attachment TO SUBJECT BODY ATT_PATH ATT_NAME
#
# CyberPersons does not publish attachment support in their transactional email
# API documentation (platform.cyberpersons.com/email/v1/send). Falls back to
# _smtp_send_with_attachment so the encrypted kit is still deliverable when the
# operator has configured SMTP credentials alongside the CyberPersons driver.
# ---------------------------------------------------------------------------
_email_driver_cyberpersons_attachment() {
    local _to="$1" _subject="$2" _body="$3" _att_path="$4" _att_name="$5"
    log_error "CyberPersons API does not support attachments"
    return 1
}


# DRIVER: host/postfix (EMAIL_MODE=host, postfix sidecar)
# Implements the EMAIL_MODE=host driver. Pipes a minimal RFC-2822 message to
# sendmail -t which is provided by the postfix sidecar container. No API token
# is required or read.
#
# Usage: set EMAIL_MODE=host and EMAIL_PROVIDER=host (or EMAIL_PROVIDER=postfix)
# in .env. sendmail must be on PATH (standard in the postfix sidecar image).
_email_driver_postfix() {
    local to="$1" subject="$2" body="$3"
    _host_send "$to" "$subject" "$body"
}


# _normalise_email_subject SUBJECT
#
# Single source of truth for the [VaultWarden] subject prefix used by every
# email-related function.  Prepends the prefix when not already present and
# prints the normalised subject to stdout.
#
# Both send_email() and clear_email_rate_limit() call this helper so that the
# two functions always hash the same string when computing the rate-limit stamp
# file path.  If the prefix is ever changed it only needs updating here.
_normalise_email_subject() {
    local subject="$1"
    subject="${subject//$'\r'/ }"
    subject="${subject//$'\n'/ }"
    [[ "$subject" != "[VaultWarden]"* ]] && subject="[VaultWarden] ${subject}"
    printf '%s\n' "$subject"
}


# Tries candidate directories in priority order and returns the first one
# that is (or can be) created AND is writable by the current user:
#   1. PROJECT_ROOT/.rate-limit   — preferred
#   2. XDG_CACHE_HOME/vaultwarden/rate-limit
#   3. HOME/.cache/vaultwarden/rate-limit
#   4. /tmp/vaultwarden-rate-limit-<euid>  (last resort)
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

    log_debug "_resolve_rate_limit_dir: no writable candidate found; rate-limiting disabled for this run"
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
        reset_at=$(date -d "@${reset_epoch}" '+%H:%M:%S' 2>/dev/null || date -r "$reset_epoch" '+%H:%M:%S' 2>/dev/null || printf 'unknown time')
        printf 'resets in %dm %02ds (at %s)' "$mins" "$secs" "$reset_at"
    else
        printf 'window may have already reset — try ./maintenance.sh test-email'
    fi
}

_rate_limit_check() {
    local subject="$1"
    local rate_limit_dir="$2"
    local last_email_file

    if ! command -v sha256sum >/dev/null 2>&1; then
        log_debug "_rate_limit_check: sha256sum not found — rate-limiting disabled"
        printf '/dev/null\n'
        return 0
    fi

    last_email_file="$rate_limit_dir/.vw_last_email_$(printf '%s' "$subject" | sha256sum | cut -c1-16)"

    if [[ "$subject" != *"CRITICAL"* ]] && [[ -f "$last_email_file" ]]; then
        local last_time current_time
        last_time=$(cat "$last_email_file" 2>/dev/null || printf '0')
        current_time=$(date +%s)
        local window_seconds="${EMAIL_RATE_WINDOW_SECONDS:-3600}"
        if (( current_time - last_time < window_seconds )); then
            log_warn "Email rate limit reached for non-critical notification: ${subject} — $(_rate_limit_reset_message "$last_email_file")"
            log_hint "To reset manually for this subject: clear_email_rate_limit \"${subject}\""
            return 1
        fi
    fi

    printf '%s\n' "$last_email_file"
    return 0
}


# _resolve_smtp_method
#
# Single source of truth for the SMTP transport label used in delivery
# metadata and log lines.  Prints one of two values to stdout:
#
#   "smtp (direct relay)"    — SMTP_PASSWORD is set; _smtp_send() will
#                              authenticate directly to SMTP_HOST.
#   "smtp (postfix sidecar)" — No SMTP_PASSWORD; _smtp_send() will route
#                              through the Postfix sidecar at VW_SMTP_HOST_PORT
#                              (default 127.0.0.1:587).
#
# Both send_email() and _smtp_send() derive their label from this function
# so that the metadata footer and the actual transport path always agree,
# regardless of future changes to either caller.
_resolve_smtp_method() {
    if [[ -n "${SMTP_PASSWORD:-}" ]]; then
        printf 'smtp (direct relay)\n'
    else
        printf 'smtp (postfix sidecar)\n'
    fi
}


# _build_email_metadata_body BASE_BODY HOST_FQDN TIMESTAMP MODE PROVIDER METHOD
#
# Single source of truth for the "Email delivery metadata" footer appended to
# every outbound notification.  Accepts all fields as arguments so the caller
# controls what appears in each label without duplicating the template.
#
# Output is printed to stdout so callers capture it with $(...) or printf -v.
_build_email_metadata_body() {
    local base_body="$1"
    local host_fqdn="$2"
    local ts="$3"
    local mode="$4"
    local provider="$5"
    local method="$6"

    printf '%s\n\nEmail delivery metadata:\nHost:      %s\nTimestamp: %s\nMode:      %s\nProvider:  %s\nMethod:    %s' \
        "$base_body" \
        "$host_fqdn" \
        "$ts" \
        "$mode" \
        "$provider" \
        "$method"
}


# _smtp_send <to> <subject> <body>
#
# Path A: SMTP_PASSWORD present → direct external relay (dev/test override)
# Path B: no SMTP_PASSWORD → route through Postfix sidecar at 127.0.0.1:587
#
# The transport path selected here must always match the label returned by
# _resolve_smtp_method().  If a new transport path is ever added, update
# both functions together.
_smtp_send() {
    local to="$1" subject="$2" body="$3"
    local message_file rc=0
    message_file=$(_email_make_temp_file vw-smtp-message) || {
        log_error "_smtp_send: failed to create message file"
        return 1
    }
    if _email_build_text_message "$to" "$subject" "$body" "$message_file"; then
        _smtp_upload_message "$to" "$message_file" || rc=$?
    else
        rc=$?
    fi
    rm -f "$message_file"
    return "$rc"
}


# ---------------------------------------------------------------------------
# _smtp_send_with_attachment TO SUBJECT BODY ATTACHMENT_PATH ATTACHMENT_NAME
#
# Sends a MIME multipart/mixed email with a single binary attachment via the
# existing SMTP transport (direct relay or Postfix sidecar). Falls back to a
# text-only send_email() call if no SMTP credentials are configured.
#
# The message file is built on tmpfs at mode 600 and deleted via a RETURN trap.
# The attachment is base64-encoded inline (RFC 2045, 76-char fold) so no
# additional temp file is required for the encoded payload.
# ---------------------------------------------------------------------------
_smtp_send_with_attachment() {
    local to="$1" subject="$2" body="$3" att_path="$4" att_name="$5"
    local message_file rc=0
    message_file=$(_email_make_temp_file vw-smtp-attachment) || {
        log_error "_smtp_send_with_attachment: failed to create message file"
        return 1
    }
    if _email_build_attachment_message \
            "$to" "$subject" "$body" "$att_path" "$att_name" "$message_file"; then
        _smtp_upload_message "$to" "$message_file" || rc=$?
    else
        rc=$?
    fi
    rm -f "$message_file"
    return "$rc"
}

# VW_EMAIL_ROUTING_V2: shared RFC-5322/MIME and transport helpers.
_email_make_temp_file() {
    local prefix="${1:-vw-email}"
    local path
    path=$(mktemp -p /dev/shm "${prefix}.XXXXXX" 2>/dev/null \
        || mktemp -t "${prefix}.XXXXXX") || return 1
    if ! install -m 600 /dev/null "$path" 2>/dev/null; then
        chmod 600 "$path" 2>/dev/null || {
            rm -f "$path"
            return 1
        }
    fi
    printf '%s' "$path"
}

_email_message_id() {
    local host
    host=$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'localhost')
    host="${host//[^A-Za-z0-9.-]/-}"
    printf '<%s.%s.%s@%s>' "$(date +%s)" "$$" "${RANDOM:-0}" "$host"
}

_email_build_text_message() {
    local to="$1" subject="$2" body="$3" output_file="$4"
    local from_addr="${SMTP_FROM_EMAIL:-${SMTP_FROM:-${SMTP_USERNAME:-}}}"
    local from_name="${SMTP_FROM_NAME:-VaultWarden}"

    _email_validate_address_value "recipient" "$to" || return 1
    _email_validate_address_value "sender" "$from_addr" || return 1

    from_name="${from_name//$'\r'/ }"
    from_name="${from_name//$'\n'/ }"
    subject=$(_normalise_email_subject "$subject")

    {
        printf 'From: "%s" <%s>\r\n' "$from_name" "$from_addr"
        printf 'To: %s\r\n' "$to"
        printf 'Subject: %s\r\n' "$subject"
        printf 'Date: %s\r\n' "$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
        printf 'Message-ID: %s\r\n' "$(_email_message_id)"
        printf 'MIME-Version: 1.0\r\n'
        printf 'Content-Type: text/plain; charset=UTF-8\r\n'
        printf 'Content-Transfer-Encoding: 8bit\r\n'
        printf '\r\n'
        while IFS= read -r line; do
            printf '%s\r\n' "$line"
        done <<< "$body"
        printf '\r\n'
    } > "$output_file"
}

_email_build_attachment_message() {
    local to="$1" subject="$2" body="$3"
    local att_path="$4" att_name="$5" output_file="$6"
    local from_addr="${SMTP_FROM_EMAIL:-${SMTP_FROM:-${SMTP_USERNAME:-}}}"
    local from_name="${SMTP_FROM_NAME:-VaultWarden}"

    _email_validate_address_value "recipient" "$to" || return 1
    _email_validate_address_value "sender" "$from_addr" || return 1
    [[ -f "$att_path" ]] || {
        log_error "Attachment not found: $att_path"
        return 1
    }

    from_name="${from_name//$'\r'/ }"
    from_name="${from_name//$'\n'/ }"
    subject=$(_normalise_email_subject "$subject")
    att_name="$(basename -- "$att_name")"
    att_name="${att_name//$'\r'/_}"
    att_name="${att_name//$'\n'/_}"
    att_name="${att_name//\"/_}"

    local boundary content_type
    boundary="=====VW_$(openssl rand -hex 12 2>/dev/null || printf '%s%s' "$$" "$(date +%s)")====="
    content_type=$(_email_attachment_content_type "$att_name")

    {
        printf 'From: "%s" <%s>\r\n' "$from_name" "$from_addr"
        printf 'To: %s\r\n' "$to"
        printf 'Subject: %s\r\n' "$subject"
        printf 'Date: %s\r\n' "$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
        printf 'Message-ID: %s\r\n' "$(_email_message_id)"
        printf 'MIME-Version: 1.0\r\n'
        printf 'Content-Type: multipart/mixed; boundary="%s"\r\n' "$boundary"
        printf '\r\n'
        printf -- '--%s\r\n' "$boundary"
        printf 'Content-Type: text/plain; charset=UTF-8\r\n'
        printf 'Content-Transfer-Encoding: 8bit\r\n'
        printf '\r\n'
        while IFS= read -r line; do
            printf '%s\r\n' "$line"
        done <<< "$body"
        printf '\r\n'
        printf -- '--%s\r\n' "$boundary"
        printf 'Content-Type: %s; name="%s"\r\n' "$content_type" "$att_name"
        printf 'Content-Transfer-Encoding: base64\r\n'
        printf 'Content-Disposition: attachment; filename="%s"\r\n' "$att_name"
        printf '\r\n'
    } > "$output_file" || return 1

    if ! (set -o pipefail; base64 < "$att_path" | fold -w 76 \
        | while IFS= read -r line; do printf '%s\r\n' "$line"; done) >> "$output_file"; then
        log_error "Failed to base64-encode attachment: $att_path"
        return 1
    fi

    printf -- '--%s--\r\n' "$boundary" >> "$output_file"
}

_email_log_curl_failure() {
    local context="$1" rc="$2" err_file="$3"
    local detail=""
    detail=$(head -c 400 "$err_file" 2>/dev/null | tr '\r\n' ' ' || true)
    log_warn "${context} failed (curl exit ${rc}): ${detail:-no diagnostic returned}"
}

_smtp_upload_message() {
    local to="$1" message_file="$2"
    local from_addr="${SMTP_FROM_EMAIL:-${SMTP_FROM:-${SMTP_USERNAME:-}}}"

    _email_validate_address_value "recipient" "$to" || return 1
    _email_validate_address_value "sender" "$from_addr" || return 1
    [[ -s "$message_file" ]] || {
        log_error "SMTP message file is missing or empty: $message_file"
        return 1
    }

    local err_file
    err_file=$(_email_make_temp_file vw-smtp-error) || {
        log_error "Failed to create SMTP diagnostic file"
        return 1
    }

    if [[ -n "${SMTP_PASSWORD:-}" ]]; then
        if [[ -z "${SMTP_HOST:-}" || -z "${SMTP_USERNAME:-}" ]]; then
            rm -f "$err_file"
            log_error "Direct SMTP requires SMTP_HOST and SMTP_USERNAME"
            return 1
        fi

        local port="${SMTP_PORT:-587}"
        local security="${SMTP_SECURITY:-}"
        local url
        local -a tls_flags=()
        [[ -n "$security" ]] || { [[ "$port" == "465" ]] && security="tls" || security="starttls"; }

        case "${security,,}" in
            tls|ssl|on)
                url="smtps://${SMTP_HOST}:${port}"
                ;;
            starttls)
                url="smtp://${SMTP_HOST}:${port}"
                tls_flags=(--ssl-reqd)
                ;;
            none|plain|off)
                url="smtp://${SMTP_HOST}:${port}"
                ;;
            *)
                rm -f "$err_file"
                log_error "Unknown SMTP_SECURITY='${security}'. Valid: tls starttls none"
                return 1
                ;;
        esac

        # Store SMTP authentication in a protected curl config rather than
        # process arguments or .netrc. curl config quoting is supported by the
        # project's minimum platform and preserves spaces and special characters.
        local auth_config_file
        auth_config_file=$(_email_make_temp_file vw-smtp-auth) || {
            rm -f "$err_file"
            log_error "Failed to create SMTP authentication config"
            return 1
        }

        local auth_value="${SMTP_USERNAME}:${SMTP_PASSWORD}"
        if [[ "$auth_value" == *$'\r'* || "$auth_value" == *$'\n'* ]]; then
            rm -f "$auth_config_file" "$err_file"
            unset auth_value
            log_error "SMTP credentials contain a prohibited newline"
            return 1
        fi

        # Escape the value for curl's double-quoted config-file syntax.
        auth_value="${auth_value//\\/\\\\}"
        auth_value="${auth_value//\"/\\\"}"
        printf 'user = "%s"\n' "$auth_value" > "$auth_config_file"
        unset auth_value

        local rc=0
        curl --silent --show-error \
            --config "$auth_config_file" \
            --connect-timeout 15 \
            --max-time "${SMTP_TIMEOUT:-60}" \
            "${tls_flags[@]}" \
            --url "$url" \
            --mail-from "$from_addr" \
            --mail-rcpt "$to" \
            --upload-file "$message_file" 2>"$err_file" || rc=$?

        rm -f "$auth_config_file"

        if [[ $rc -ne 0 ]]; then
            _email_log_curl_failure \
                "Direct SMTP relay ${SMTP_HOST}:${port}" \
                "$rc" \
                "$err_file"
            rm -f "$err_file"
            return "$rc"
        fi

        rm -f "$err_file"
        return 0
    fi

    local sidecar_addr="${VW_SMTP_HOST_PORT:-127.0.0.1:587}"
    local sidecar_host="${sidecar_addr%:*}"
    local sidecar_port="${sidecar_addr##*:}"

    if command -v nc >/dev/null 2>&1; then
        if ! nc -z -w 2 "$sidecar_host" "$sidecar_port" >/dev/null 2>&1; then
            rm -f "$err_file"
            log_warn "Postfix sidecar unreachable at ${sidecar_addr}"
            return 1
        fi
    elif ! (echo >/dev/tcp/"$sidecar_host"/"$sidecar_port") >/dev/null 2>&1; then
        rm -f "$err_file"
        log_warn "Postfix sidecar unreachable at ${sidecar_addr}"
        return 1
    fi

    local rc=0
    curl --silent --show-error \
        --connect-timeout 5 \
        --max-time "${SMTP_TIMEOUT:-60}" \
        --url "smtp://${sidecar_host}:${sidecar_port}" \
        --mail-from "$from_addr" \
        --mail-rcpt "$to" \
        --upload-file "$message_file" 2>"$err_file" || rc=$?
    if [[ $rc -ne 0 ]]; then
        _email_log_curl_failure "Postfix sidecar ${sidecar_addr}" "$rc" "$err_file"
        rm -f "$err_file"
        return "$rc"
    fi
    rm -f "$err_file"
    return 0
}

_host_send() {
    local to="$1" subject="$2" body="$3"
    _email_validate_address_value "recipient" "$to" || return 1

    if command -v sendmail >/dev/null 2>&1; then
        local message_file rc=0
        message_file=$(_email_make_temp_file vw-host-mail) || return 1
        if _email_build_text_message "$to" "$subject" "$body" "$message_file"; then
            sendmail -t -oi < "$message_file" || rc=$?
        else
            rc=$?
        fi
        rm -f "$message_file"
        return "$rc"
    fi

    if command -v mail >/dev/null 2>&1; then
        printf '%s' "$body" | mail -s "$(_normalise_email_subject "$subject")" "$to"
        return $?
    fi

    log_warn "Host MTA unavailable: neither sendmail nor mail is installed"
    return 1
}

_host_send_with_attachment() {
    local to="$1" subject="$2" body="$3" att_path="$4" att_name="$5"
    if ! command -v sendmail >/dev/null 2>&1; then
        log_warn "Host attachment delivery unavailable: sendmail is not installed"
        return 1
    fi

    local message_file rc=0
    message_file=$(_email_make_temp_file vw-host-attachment) || return 1
    if _email_build_attachment_message \
            "$to" "$subject" "$body" "$att_path" "$att_name" "$message_file"; then
        sendmail -t -oi < "$message_file" || rc=$?
    else
        rc=$?
    fi
    rm -f "$message_file"
    return "$rc"
}


# ---------------------------------------------------------------------------
# Attachment variant drivers — one per API provider.
#
# Each attachment driver signature: TO SUBJECT BODY ATT_PATH ATT_NAME.
# The dispatcher-provided recipient is authoritative; drivers never read ADMIN_EMAIL.
#
# Mailgun: multipart/form-data — no base64 needed; curl streams the file
#   directly with the @-prefix syntax, which is safer than embedding binary
#   data inside shell variables and avoids the overhead of a full MIME builder.
#   This is a superior solution over the generic SMTP MIME approach for Mailgun.
# ---------------------------------------------------------------------------
_email_driver_mailgun_attachment() {
    local to="$1" subject="$2" body="$3" att_path="$4" att_name="$5"
    _email_mailgun_post "$to" "$subject" "$body" "$att_path" "$att_name"
}


_email_driver_sendgrid_attachment() {
    local to="$1" subject="$2" body="$3" att_path="$4" att_name="$5"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
    fn=$(_email_json_escape "${SMTP_FROM_NAME:-VaultWarden}")
    fe=$(_email_json_escape "$from_email")
    ae=$(_email_json_escape "$to")

    local att_b64 an content_type
    att_b64=$(_email_base64_file "$att_path") || {
        log_error "SendGrid attachment driver: base64 encoding failed"
        return 1
    }
    an=$(_email_json_escape "$(_email_safe_attachment_name "$att_name")")
    content_type=$(_email_json_escape "$(_email_attachment_content_type "$att_name")")

    local payload
    payload=$(cat <<EOF
{
    "personalizations": [ { "to": [ { "email": "${ae}" } ] } ],
    "from":    { "email": "${fe}", "name": "${fn}" },
    "subject": "${s}",
    "content": [ { "type": "text/plain", "value": "${b}" } ],
    "attachments": [ { "content": "${att_b64}", "filename": "${an}", "type": "${content_type}", "disposition": "attachment" } ],
    "tracking_settings": {
        "click_tracking":        { "enable": false },
        "open_tracking":         { "enable": false },
        "subscription_tracking": { "enable": false }
    }
}
EOF
)
    unset att_b64
    _email_bearer_post "https://api.sendgrid.com/v3/mail/send" "$payload" && return 0
    log_warn "SendGrid attachment API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
    return 1
}


_email_driver_mailersend_attachment() {
    local to="$1" subject="$2" body="$3" att_path="$4" att_name="$5"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
    fn=$(_email_json_escape "${SMTP_FROM_NAME:-VaultWarden}")
    fe=$(_email_json_escape "$from_email")
    ae=$(_email_json_escape "$to")

    local att_b64 an
    att_b64=$(_email_base64_file "$att_path") || {
        log_error "MailerSend attachment driver: base64 encoding failed"
        return 1
    }
    an=$(_email_json_escape "$(_email_safe_attachment_name "$att_name")")

    local payload
    payload=$(cat <<EOF
{
    "from": { "email": "${fe}", "name": "${fn}" },
    "to":   [ { "email": "${ae}" } ],
    "subject": "${s}",
    "text":    "${b}",
    "attachments": [ { "content": "${att_b64}", "filename": "${an}", "disposition": "attachment" } ],
    "settings": { "track_clicks": false, "track_opens": false }
}
EOF
)
    unset att_b64
    if _email_bearer_post "https://api.mailersend.com/v1/email" "$payload"; then
        [[ -n "${_ECURL_BODY}" ]] && log_warn "MailerSend attachment: queued with warnings: ${_ECURL_BODY}"
        return 0
    fi
    log_warn "MailerSend attachment API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
    return 1
}


_email_driver_postmark_attachment() {
    local to="$1" subject="$2" body="$3" att_path="$4" att_name="$5"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
    fn=$(_email_json_escape "${SMTP_FROM_NAME:-VaultWarden}")
    fe=$(_email_json_escape "$from_email")
    ae=$(_email_json_escape "$to")

    local att_b64 an content_type
    att_b64=$(_email_base64_file "$att_path") || {
        log_error "Postmark attachment driver: base64 encoding failed"
        return 1
    }
    an=$(_email_json_escape "$(_email_safe_attachment_name "$att_name")")
    content_type=$(_email_json_escape "$(_email_attachment_content_type "$att_name")")

    local payload
    payload=$(cat <<EOF
{
    "From":          "${fn} <${fe}>",
    "To":            "${ae}",
    "Subject":       "${s}",
    "TextBody":      "${b}",
    "MessageStream": "outbound",
    "Attachments": [ { "Name": "${an}", "Content": "${att_b64}", "ContentType": "${content_type}" } ]
}
EOF
)
    unset att_b64

    if ! _email_json_post "https://api.postmarkapp.com/email" \
            "X-Postmark-Server-Token" "${EMAIL_API_TOKEN}" "$payload"; then
        log_warn "Postmark attachment API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
        return 1
    fi
    if grep -Eq '"ErrorCode"[[:space:]]*:[[:space:]]*0' <<< "${_ECURL_BODY}"; then
        return 0
    fi
    log_warn "Postmark attachment API returned a non-zero ErrorCode: ${_ECURL_BODY}"
    return 1
}


_email_driver_resend_attachment() {
    local to="$1" subject="$2" body="$3" att_path="$4" att_name="$5"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
    fn=$(_email_json_escape "${SMTP_FROM_NAME:-VaultWarden}")
    fe=$(_email_json_escape "$from_email")
    ae=$(_email_json_escape "$to")

    local att_b64 an
    att_b64=$(_email_base64_file "$att_path") || {
        log_error "Resend attachment driver: base64 encoding failed"
        return 1
    }
    an=$(_email_json_escape "$(_email_safe_attachment_name "$att_name")")

    local payload
    payload=$(cat <<EOF
{
    "from":    "${fn} <${fe}>",
    "to":      ["${ae}"],
    "subject": "${s}",
    "text":    "${b}",
    "attachments": [ { "filename": "${an}", "content": "${att_b64}" } ]
}
EOF
)
    unset att_b64
    _email_bearer_post "https://api.resend.com/emails" "$payload" && return 0
    log_warn "Resend attachment API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
    return 1
}


# ---------------------------------------------------------------------------
# _dispatch_email_with_attachment TO SUBJECT BODY ATT_PATH ATT_NAME
#
# Mirrors the provider-selection logic of send_email() but routes to the
# attachment-capable variant of each driver. SMTP is always available as the
# final fallback via _smtp_send_with_attachment().
#
# Does NOT apply rate-limiting (attachment sends are explicit one-shot actions,
# not automated notifications).
# ---------------------------------------------------------------------------
_dispatch_email_with_attachment() {
    local to="$1" subject="$2" body="$3" att_path="$4" att_name="$5"

    _email_validate_address_value "recipient" "$to" || return 1
    [[ -f "$att_path" ]] || {
        log_error "_dispatch_email_with_attachment: attachment not found: $att_path"
        return 1
    }

    subject=$(_normalise_email_subject "$subject")

    local mode="${EMAIL_MODE:-auto}"
    local provider="${EMAIL_PROVIDER:-smtp}"
    mode="${mode,,}"
    provider="${provider,,}"

    case "$provider" in
        smtp) mode="smtp" ;;
        host|postfix) mode="host" ;;
    esac

    case "$mode" in
        auto|api|smtp|host) ;;
        *)
            log_error "Unknown EMAIL_MODE='${mode}'. Valid values: auto api smtp host"
            return 1
            ;;
    esac

    if [[ "$mode" == "api" || "$mode" == "auto" ]]; then
        local driver_suffix=""
        if ! driver_suffix=$(_email_driver_lookup "$provider" 2>/dev/null); then
            if [[ "$mode" == "api" ]]; then
                log_error "EMAIL_MODE=api requires an API provider; got EMAIL_PROVIDER='${provider}'"
                return 1
            fi
            if [[ "$provider" != "smtp" && "$provider" != "host" && "$provider" != "postfix" ]]; then
                log_error "Unknown EMAIL_PROVIDER='${provider}'"
                return 1
            fi
        else
            local api_token
            api_token=$(_email_resolve_api_token)
            if [[ -z "$api_token" ]]; then
                if [[ "$mode" == "api" ]]; then
                    log_error "EMAIL_MODE=api but EMAIL_API_TOKEN is empty"
                    return 1
                fi
                log_warn "EMAIL_API_TOKEN is empty for ${provider}; falling back to SMTP"
            elif [[ "$provider" == "cyberpersons" ]]; then
                if [[ "$mode" == "api" ]]; then
                    log_error "CyberPersons API does not support attachment delivery"
                    return 1
                fi
                log_warn "CyberPersons API does not support attachments; falling back to SMTP"
            else
                local att_fn="_email_driver_${driver_suffix}_attachment"
                if ! declare -f "$att_fn" &>/dev/null; then
                    if [[ "$mode" == "api" ]]; then
                        log_error "No attachment driver is implemented for ${provider}"
                        return 1
                    fi
                    log_warn "No attachment driver for ${provider}; falling back to SMTP"
                elif EMAIL_API_TOKEN="$api_token" \
                        "$att_fn" "$to" "$subject" "$body" "$att_path" "$att_name"; then
                    log_success "Encrypted attachment sent via ${provider} API to ${to}"
                    return 0
                elif [[ "$mode" == "api" ]]; then
                    log_error "EMAIL_MODE=api: ${provider} attachment API failed — no fallback configured"
                    return 1
                else
                    log_warn "${provider} attachment driver failed — falling back to SMTP"
                fi
            fi
        fi
    fi

    if [[ "$mode" == "host" ]]; then
        if _host_send_with_attachment "$to" "$subject" "$body" "$att_path" "$att_name"; then
            log_success "Encrypted attachment sent via host MTA to ${to}"
            return 0
        fi
        log_warn "Host MTA attachment delivery failed — falling back to SMTP"
    fi

    if [[ "$mode" == "auto" || "$mode" == "smtp" || "$mode" == "host" ]]; then
        if _smtp_send_with_attachment "$to" "$subject" "$body" "$att_path" "$att_name"; then
            log_success "Encrypted attachment sent via SMTP to ${to}"
            return 0
        fi
        [[ "$mode" == "smtp" ]] && {
            log_error "EMAIL_MODE=smtp: SMTP attachment delivery failed"
            return 1
        }
    fi

    if [[ "$mode" == "auto" ]]; then
        log_warn "SMTP attachment delivery failed — trying host MTA"
        if _host_send_with_attachment "$to" "$subject" "$body" "$att_path" "$att_name"; then
            log_success "Encrypted attachment sent via host MTA to ${to}"
            return 0
        fi
    fi

    log_error "All attachment delivery paths failed (mode=${mode}, provider=${provider})"
    return 1
}


# send_email [TO] SUBJECT BODY
#
# TO is optional; defaults to ${ADMIN_EMAIL}.
# Tries providers in order: HTTP API → SMTP/Postfix sidecar → host MTA.
#
# Token resolution for HTTP API providers:
#   The canonical secrets key is 'email_api_token'. This matches what
#   ./utilities/secrets-rotate.sh email_api_token writes into secrets.yaml.
#   Resolution order:
#     1. EMAIL_API_TOKEN env var (direct override, e.g. set in shell)
#     2. decrypt_secret email_api_token  (from secrets.yaml via SOPS/age)
send_email() {
    local to subject body
    if [[ $# -ge 3 ]]; then
        to="$1"
        subject="${2:-VaultWarden Notification}"
        body="${3:-}"
    else
        to="${ADMIN_EMAIL:-}"
        subject="${1:-VaultWarden Notification}"
        body="${2:-}"
    fi

    _email_validate_address_value "recipient" "$to" || return 1

    local mode="${EMAIL_MODE:-auto}"
    local provider="${EMAIL_PROVIDER:-smtp}"
    mode="${mode,,}"
    provider="${provider,,}"

    case "$provider" in
        smtp) mode="smtp" ;;
        host|postfix) mode="host" ;;
    esac

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

    if [[ "$mode" == "api" || "$mode" == "auto" ]]; then
        local driver_suffix=""
        if ! driver_suffix=$(_email_driver_lookup "$provider" 2>/dev/null); then
            if [[ "$mode" == "api" ]]; then
                log_error "EMAIL_MODE=api requires an API provider; got EMAIL_PROVIDER='${provider}'"
                return 1
            fi
            if [[ "$provider" != "smtp" && "$provider" != "host" && "$provider" != "postfix" ]]; then
                log_error "Unknown EMAIL_PROVIDER='${provider}'"
                return 1
            fi
        else
            local api_token api_body driver_fn
            api_token=$(_email_resolve_api_token)
            api_body=$(_build_email_metadata_body \
                "$body" "$host_fqdn" "$ts" "$mode" "$provider" "api (${provider})")
            driver_fn="_email_driver_${driver_suffix}"

            if [[ -z "$api_token" ]]; then
                if [[ "$mode" == "api" ]]; then
                    log_error "EMAIL_MODE=api but EMAIL_API_TOKEN is empty"
                    return 1
                fi
                log_warn "EMAIL_API_TOKEN is empty for ${provider}; falling back to SMTP"
            elif EMAIL_API_TOKEN="$api_token" "$driver_fn" "$to" "$subject" "$api_body"; then
                log_success "Email sent via ${provider} API: ${subject}"
                [[ -n "$stamp_file" ]] && date +%s > "$stamp_file" 2>/dev/null || true
                return 0
            elif [[ "$mode" == "api" ]]; then
                log_error "EMAIL_MODE=api: ${provider} API failed — no fallback configured"
                return 1
            else
                log_warn "${provider} API failed — falling back to SMTP"
            fi
        fi
    fi

    if [[ "$mode" == "host" ]]; then
        local host_body
        host_body=$(_build_email_metadata_body \
            "$body" "$host_fqdn" "$ts" "$mode" "$provider" "host mta")
        if _host_send "$to" "$subject" "$host_body"; then
            log_success "Email sent via host MTA: ${subject}"
            [[ -n "$stamp_file" ]] && date +%s > "$stamp_file" 2>/dev/null || true
            return 0
        fi
        log_warn "Host MTA failed — falling back to SMTP"
    fi

    if [[ "$mode" == "auto" || "$mode" == "smtp" || "$mode" == "host" ]]; then
        local smtp_method smtp_body
        smtp_method=$(_resolve_smtp_method)
        smtp_body=$(_build_email_metadata_body \
            "$body" "$host_fqdn" "$ts" "$mode" "$provider" "$smtp_method")
        if _smtp_send "$to" "$subject" "$smtp_body"; then
            log_success "Email sent via SMTP (${SMTP_HOST:-${VW_SMTP_HOST_PORT:-127.0.0.1:587}}): ${subject}"
            [[ -n "$stamp_file" ]] && date +%s > "$stamp_file" 2>/dev/null || true
            return 0
        fi
        if [[ "$mode" == "smtp" ]]; then
            log_error "EMAIL_MODE=smtp: SMTP relay failed — no fallback configured"
            return 1
        fi
    fi

    if [[ "$mode" == "auto" ]]; then
        local host_body
        host_body=$(_build_email_metadata_body \
            "$body" "$host_fqdn" "$ts" "$mode" "$provider" "host mta")
        log_warn "SMTP relay failed — falling back to host MTA"
        if _host_send "$to" "$subject" "$host_body"; then
            log_success "Email sent via host MTA: ${subject}"
            [[ -n "$stamp_file" ]] && date +%s > "$stamp_file" 2>/dev/null || true
            return 0
        fi
    fi

    log_error "All email delivery methods failed (mode=${mode}, provider=${provider}, subject=${subject})"
    return 1
}


send_notification_email() {
    send_email "$1" "$2"
}


# clear_email_rate_limit SUBJECT
#
# Removes the rate-limit stamp file for SUBJECT so that the *next* call to
# send_email() for this subject fires immediately, regardless of how recently
# the previous alert was sent.
#
# Call this from health-check or monitoring scripts when a previously-alerting
# condition returns to a healthy state.  This ensures that if the same
# condition flaps, the recovery → next-fault cycle always produces a fresh
# notification rather than waiting out the 1-hour TTL.
#
# Usage:
#   clear_email_rate_limit "Health check failed"   # matches send_email subject
#
# The subject is normalised via _normalise_email_subject() — the same helper
# used by send_email() — so callers may pass the bare subject or the prefixed
# form interchangeably and the stamp file path always matches.
clear_email_rate_limit() {
    local subject="${1:-}"
    [[ -z "$subject" ]] && { log_warn "clear_email_rate_limit: subject is empty — nothing to clear"; return 0; }

    subject=$(_normalise_email_subject "$subject")

    local rate_limit_dir
    rate_limit_dir=$(_resolve_rate_limit_dir) || {
        log_debug "clear_email_rate_limit: rate-limit dir unavailable — nothing to clear"
        return 0
    }

    local stamp_file
    if ! command -v sha256sum >/dev/null 2>&1; then
        log_debug "clear_email_rate_limit: sha256sum not found — rate-limiting disabled, nothing to clear"
        return 0
    fi
    stamp_file="$rate_limit_dir/.vw_last_email_$(printf '%s' "$subject" | sha256sum | cut -c1-16)"
    if [[ -f "$stamp_file" ]]; then
        rm -f "$stamp_file" 2>/dev/null || true
        log_debug "clear_email_rate_limit: cleared stamp for '${subject}'"
    else
        log_debug "clear_email_rate_limit: no stamp found for '${subject}' — nothing to clear"
    fi

    return 0
}


export -f _email_json_escape _email_json_post _email_bearer_post _email_driver_lookup
export -f _email_resolve_api_token _email_validate_address_value
export -f _email_safe_attachment_name _email_base64_file _email_attachment_content_type _email_mailgun_post
export -f _email_driver_mailersend _email_driver_sendgrid _email_driver_mailgun
export -f _email_driver_postmark _email_driver_resend _email_driver_postfix
export -f _email_driver_cyberpersons
export -f _email_driver_mailgun_attachment _email_driver_sendgrid_attachment
export -f _email_driver_mailersend_attachment _email_driver_postmark_attachment
export -f _email_driver_resend_attachment _email_driver_cyberpersons_attachment
export -f _email_make_temp_file _email_message_id
export -f _email_build_text_message _email_build_attachment_message
export -f _email_log_curl_failure _smtp_upload_message _host_send _host_send_with_attachment
export -f _smtp_send_with_attachment _dispatch_email_with_attachment
export -f _normalise_email_subject _resolve_rate_limit_dir _rate_limit_reset_message _rate_limit_check
export -f _resolve_smtp_method _build_email_metadata_body
export -f _smtp_send send_email send_notification_email clear_email_rate_limit
