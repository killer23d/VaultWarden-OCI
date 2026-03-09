#!/usr/bin/env bash
# lib/email.sh - Email provider driver registry for VaultWarden-OCI
# shellcheck shell=bash
#
# --- DRIVER CONTRACT ---------------------------------------------------------
# Every driver function MUST:
#   - Be named:     _email_driver_PROVIDERNAME
#   - Accept:       $1=subject  $2=body (plain text)
#   - Return:       0 on accepted/queued, non-zero on failure
#   - NEVER log:    EMAIL_API_TOKEN or any password
#   - Log on fail:  truncated response body (<=300 chars) via log_warn
#   - Clean up:     temp files via local trap on RETURN
#
# --- HOW TO ADD A NEW PROVIDER -----------------------------------------------
# 1. Add one entry in _EMAIL_DRIVERS below (key = EMAIL_PROVIDER value)
# 2. Write one function:  _email_driver_YOURPROVIDER() { ... }
# 3. Set EMAIL_PROVIDER=YOURPROVIDER in .env
# No other files need changing.
#
# --- PROVIDER NOTES ----------------------------------------------------------
# MailerSend  202 empty body (warnings may produce 202+JSON -- both = success)
# SendGrid    202 empty body; content[] must be array of {type,value} objects
# Mailgun     200 JSON; uses HTTP Basic Auth + form-data NOT JSON
# Postmark    200 JSON PascalCase; check ErrorCode in body, not just HTTP code
# Resend      200 JSON; from is composite string, to is string array
#
# --- FIX-M01 (2026-03-09) ----------------------------------------------------
# All drivers now use ${SMTP_FROM_EMAIL:-${SMTP_FROM}} for the sender address.
# Backward-compatibility for .env files still using the legacy SMTP_FROM= name.
#
# --- FIX-M03 (2026-03-09) ----------------------------------------------------
# All JSON-producing drivers (mailersend, sendgrid, postmark, resend) now
# JSON-escape SMTP_FROM_NAME, the from-address, and ADMIN_EMAIL before
# embedding them in payloads. Previously only subject and body were escaped.
# A display name containing a double-quote or backslash (e.g. Vault "Prod")
# produced malformed JSON and a 400/422 error from the provider.
# Escaped values stored in local fn/fe/ae (from_name/from_email/admin_email).
# Mailgun unaffected -- uses multipart/form-data; curl handles field encoding.
# -----------------------------------------------------------------------------

# Prevent direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: lib/email.sh must be sourced, not executed directly"
    exit 1
fi

# Guard against multiple sourcing
[[ -n "${LIB_EMAIL_LOADED:-}" ]] && return 0
readonly LIB_EMAIL_LOADED=1

# -- DRIVER REGISTRY ----------------------------------------------------------
# Key   = value accepted in EMAIL_PROVIDER env var
# Value = suffix of the driver function (_email_driver_<value>)
# 'smtp' and 'host' are reserved -- handled in send_email() in common.sh
declare -A _EMAIL_DRIVERS=(
    [mailersend]="mailersend"
    [sendgrid]="sendgrid"
    [mailgun]="mailgun"
    [postmark]="postmark"
    [resend]="resend"
)

# -- HELPER: JSON string escape -----------------------------------------------
# Pure bash -- no sed, no external tools.
# Handles: backslash, double-quote, newline, carriage return, tab.
_email_json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    printf '%s' "$str"
}

# -- HELPER: shared Bearer-token POST -----------------------------------------
# Used by MailerSend, SendGrid, Resend.
# Sets _ECURL_CODE and _ECURL_BODY for callers to inspect.
# Returns 0 on HTTP 2xx, 1 otherwise.
_email_bearer_post() {
    local url="$1" payload="$2"
    local tmp code
    tmp=$(mktemp -t vw_email.XXXXXXXXXX)
    trap 'rm -f "$tmp" 2>/dev/null; trap - RETURN' RETURN

    code=$(curl -s \
        --connect-timeout 10 \
        --max-time 20 \
        --retry 2 \
        --retry-delay 3 \
        -o "$tmp" \
        -w "%{http_code}" \
        -X POST "$url" \
        -H "Authorization: Bearer ${EMAIL_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    _ECURL_CODE="$code"
    _ECURL_BODY=$(head -c 300 "$tmp" 2>/dev/null | tr -d '\n')
    [[ "$code" =~ ^2 ]] && return 0 || return 1
}

# -- DRIVER: MailerSend -------------------------------------------------------
# Docs:    https://developers.mailersend.com/api/v1/email.html
# Auth:    Authorization: Bearer {token}
# Success: HTTP 202 empty body; 202+JSON = queued with warnings (still success)
# Error:   HTTP 422 JSON { "message": "...", "errors": { ... } }
_email_driver_mailersend() {
    local subject="$1" body="$2"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM}}"
    # FIX-M03: JSON-escape envelope fields (fn=from_name, fe=from_email, ae=admin_email)
    fn=$(_email_json_escape "${SMTP_FROM_NAME:-VaultWarden}")
    fe=$(_email_json_escape "${_from_email}")
    ae=$(_email_json_escape "${ADMIN_EMAIL}")

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

    _email_bearer_post "https://api.mailersend.com/v1/email" "$payload" && return 0
    if [[ "${_ECURL_CODE}" == "202" ]]; then
        log_warn "MailerSend: queued with warnings: ${_ECURL_BODY}"
        return 0
    fi
    log_warn "MailerSend API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
    return 1
}

# -- DRIVER: SendGrid ---------------------------------------------------------
# Docs:    https://docs.sendgrid.com/api-reference/mail-send/mail-send
# Auth:    Authorization: Bearer {api_key}
# IMPORTANT: content MUST be [{"type":"text/plain","value":"..."}] not a string
# Success: HTTP 202 empty body
_email_driver_sendgrid() {
    local subject="$1" body="$2"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM}}"
    # FIX-M03: JSON-escape envelope fields
    fn=$(_email_json_escape "${SMTP_FROM_NAME:-VaultWarden}")
    fe=$(_email_json_escape "${_from_email}")
    ae=$(_email_json_escape "${ADMIN_EMAIL}")

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

# -- DRIVER: Mailgun ----------------------------------------------------------
# Docs:    https://documentation.mailgun.com/docs/mailgun/api-reference/
# Auth:    HTTP Basic Auth -- username "api", password = API key (NOT Bearer)
# Payload: multipart/form-data (-F flags) -- NOT JSON
# NOTE:    No JSON escaping needed; curl handles multipart field encoding.
# Success: HTTP 200 JSON { "id": "...", "message": "Queued. Thank you." }
_email_driver_mailgun() {
    local subject="$1" body="$2"
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM}}"

    local domain="${MAILGUN_DOMAIN:-}"
    [[ -z "$domain" ]] && domain="${_from_email##*@}"
    if [[ -z "$domain" ]]; then
        log_error "Mailgun driver: cannot determine domain. Set MAILGUN_DOMAIN in .env"
        return 1
    fi

    local tmp code
    tmp=$(mktemp -t vw_email.XXXXXXXXXX)
    trap 'rm -f "$tmp" 2>/dev/null; trap - RETURN' RETURN

    code=$(curl -s \
        --connect-timeout 10 \
        --max-time 20 \
        --retry 2 \
        --retry-delay 3 \
        -o "$tmp" \
        -w "%{http_code}" \
        -X POST "https://api.mailgun.net/v3/${domain}/messages" \
        --user "api:${EMAIL_API_TOKEN}" \
        -F "from=${SMTP_FROM_NAME:-VaultWarden} <${_from_email}>" \
        -F "to=${ADMIN_EMAIL}" \
        -F "subject=${subject}" \
        -F "text=${body}" \
        -F "o:tracking=no" 2>/dev/null)

    local resp; resp=$(head -c 300 "$tmp" 2>/dev/null | tr -d '\n')
    [[ "$code" =~ ^2 ]] && return 0
    log_warn "Mailgun API HTTP ${code}: ${resp}"
    return 1
}

# -- DRIVER: Postmark ---------------------------------------------------------
# Docs:    https://postmarkapp.com/developer/api/email-api
# Auth:    X-Postmark-Server-Token: {token}  (NOT Authorization: Bearer)
# Payload: JSON PascalCase; From and To are plain strings
# IMPORTANT: HTTP 200 does NOT mean success -- must check ErrorCode in body
# Success: HTTP 200 JSON { "ErrorCode": 0, ... }
_email_driver_postmark() {
    local subject="$1" body="$2"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM}}"
    # FIX-M03: JSON-escape envelope fields. The Postmark driver uses inline
    # -d "{ ... }" rather than a heredoc, making unescaped quotes in display
    # names particularly hard to spot and immediately fatal (HTTP 400).
    fn=$(_email_json_escape "${SMTP_FROM_NAME:-VaultWarden}")
    fe=$(_email_json_escape "${_from_email}")
    ae=$(_email_json_escape "${ADMIN_EMAIL}")

    local tmp code
    tmp=$(mktemp -t vw_email.XXXXXXXXXX)
    trap 'rm -f "$tmp" 2>/dev/null; trap - RETURN' RETURN

    code=$(curl -s \
        --connect-timeout 10 \
        --max-time 20 \
        --retry 2 \
        --retry-delay 3 \
        -o "$tmp" \
        -w "%{http_code}" \
        -X POST "https://api.postmarkapp.com/email" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "X-Postmark-Server-Token: ${EMAIL_API_TOKEN}" \
        -d "{
            \"From\":          \"${fn} <${fe}>\",
            \"To\":            \"${ae}\",
            \"Subject\":       \"${s}\",
            \"TextBody\":      \"${b}\",
            \"MessageStream\": \"outbound\"
        }" 2>/dev/null)

    local resp; resp=$(head -c 300 "$tmp" 2>/dev/null | tr -d '\n')
    if [[ ! "$code" =~ ^2 ]]; then
        log_warn "Postmark API HTTP ${code}: ${resp}"
        return 1
    fi
    if echo "$resp" | grep -q '"ErrorCode":0'; then
        return 0
    fi
    log_warn "Postmark API: HTTP 200 but ErrorCode != 0: ${resp}"
    return 1
}

# -- DRIVER: Resend -----------------------------------------------------------
# Docs:    https://resend.com/docs/api-reference/emails/send-email
# Auth:    Authorization: Bearer {token}
# IMPORTANT: from is a string "Name <email>"; to is ["email"] not [{email:...}]
# Success: HTTP 200 JSON { "id": "..." }
_email_driver_resend() {
    local subject="$1" body="$2"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM}}"
    # FIX-M03: JSON-escape envelope fields
    fn=$(_email_json_escape "${SMTP_FROM_NAME:-VaultWarden}")
    fe=$(_email_json_escape "${_from_email}")
    ae=$(_email_json_escape "${ADMIN_EMAIL}")

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

# Export all driver functions so they are available in subshells
export -f _email_json_escape _email_bearer_post
export -f _email_driver_mailersend _email_driver_sendgrid _email_driver_mailgun
export -f _email_driver_postmark _email_driver_resend

log_debug "lib/email.sh loaded (drivers: ${!_EMAIL_DRIVERS[*]})"
