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
# 1. Add one case arm in _email_driver_lookup() below
# 2. Write one function:  _email_driver_YOURPROVIDER() { ... }
# 3. Set EMAIL_PROVIDER=YOURPROVIDER in .env
# No other files need changing.
#
# --- TOKEN RESOLUTION --------------------------------------------------------
# All drivers receive the token exclusively via the EMAIL_API_TOKEN env var,
# which is injected at call time by send_email() in lib/common.sh:
#
#   EMAIL_API_TOKEN="$(decrypt_secret email_api_token)" \
#       _email_driver_PROVIDER "$subject" "$body"
#
# The secrets file stores ONE key:  email_api_token
# Changing EMAIL_PROVIDER in .env is the only action required to switch
# providers. The token value in secrets.yaml does NOT need re-keying.
#
# --- PROVIDER NOTES ----------------------------------------------------------
# MailerSend  202 empty body (warnings may produce 202+JSON -- both = success)
# SendGrid    202 empty body; content[] must be array of {type,value} objects
# Mailgun     200 JSON; uses HTTP Basic Auth + form-data NOT JSON
#             Two API regions: US (api.mailgun.net) / EU (api.eu.mailgun.net)
#             Set MAILGUN_REGION=eu in .env for EU-hosted accounts.
# Postmark    200 JSON PascalCase; check ErrorCode in body, not just HTTP code
# Resend      200 JSON; from is composite string, to is string array
# host        Delegates to sendmail -t via the postfix sidecar container.
#             No API token required. Set EMAIL_MODE=host and EMAIL_PROVIDER=host
#             in .env to use this driver.
#
# --- FIX-M01 (2026-03-09) ----------------------------------------------------
# All drivers use ${SMTP_FROM:-${SMTP_FROM_EMAIL}} (SMTP_FROM_EMAIL deprecated;
# SMTP_FROM is canonical) for the sender address.
# Backward-compatibility for .env files still using the legacy SMTP_FROM= name.
# DEPRECATED: SMTP_FROM_EMAIL is the legacy name. The canonical variable is
# SMTP_FROM (standardised in .env.example). The SMTP_FROM_EMAIL fallback shim
# will be removed in a future release once all deployments have migrated.
#
# --- FIX-M03 (2026-03-09) ----------------------------------------------------
# All JSON-producing drivers (mailersend, sendgrid, postmark, resend) now
# JSON-escape SMTP_FROM_NAME, the from-address, and ADMIN_EMAIL before
# embedding them in payloads. Previously only subject and body were escaped.
# A display name containing a double-quote or backslash (e.g. Vault "Prod")
# produced malformed JSON and a 400/422 error from the provider.
# Escaped values stored in local fn/fe/ae (from_name/from_email/admin_email).
# Mailgun unaffected -- uses multipart/form-data; curl handles field encoding.
#
# --- FIX-B01 (2026-03-09) ----------------------------------------------------
# _email_driver_mailersend(): removed dead code after _email_bearer_post.
# _email_bearer_post() returns 0 for ALL 2xx codes (including 202), so the
# previous pattern:
#     _email_bearer_post ... && return 0
#     if [[ "${_ECURL_CODE}" == "202" ]]; then ... fi   # UNREACHABLE
# never reached the 202 branch. Fixed: restructured to if/else so that a
# successful call with a non-empty response body (202+warnings) is logged
# as a warning before returning 0, and any failure logs the HTTP code.
#
# --- FIX-B02 (2026-03-09) ----------------------------------------------------
# _email_driver_mailgun(): added MAILGUN_REGION=us|eu support.
# Mailgun operates two independent API fleets with different hostnames:
#   US (default): api.mailgun.net        -- accounts at mailgun.com
#   EU:           api.eu.mailgun.net     -- accounts at eu.mailgun.com
# EU-region accounts always received HTTP 404 from the hardcoded US endpoint.
# The 404 body ("Domain not found") is indistinguishable from a bad domain
# name, making the misconfiguration very difficult to diagnose from logs.
# Fix: read MAILGUN_REGION from .env; default 'us' is backward compatible.
# An unrecognised MAILGUN_REGION value is caught early with log_error.
#
# --- FIX EM-H1 (2026-03-10) --------------------------------------------------
# Pass EMAIL_API_TOKEN via curl --config @- (stdin pipe) instead of inline
# -H "Authorization: Bearer ..." to prevent token exposure in the process
# table (/proc/$$/cmdline) and in set -x / error traces on stderr.
# Applies to _email_bearer_post (Bearer) and _email_driver_postmark
# (X-Postmark-Server-Token). Mailgun --user also moved to config file.
#
# --- FIX EM-M1 (2026-03-10) --------------------------------------------------
# Added --retry-all-errors to all curl calls. curl's built-in --retry only
# fires on network-level failures; HTTP 5xx from the provider is treated as a
# successful curl invocation (exit 0) and was never retried. --retry-all-errors
# (curl >= 7.71) extends retry logic to cover those cases.
#
# --- FIX EM-M2 (2026-03-10) --------------------------------------------------
# _email_json_escape() now strips raw Unicode control characters U+0000-U+001F
# (other than \n \r \t which are encoded) via LC_ALL=C sed before the bash
# substitutions. Prevents JSON rejection on crash-log payloads containing BEL,
# FF, or other control characters.
#
# --- FIX EM-M3 (2026-03-10) --------------------------------------------------
# _email_driver_mailgun() validates the resolved domain against the strict
# regex ^[a-zA-Z0-9.-]+$ before embedding it in the API URL. A crafted
# SMTP_FROM_EMAIL containing path components or query strings would otherwise
# allow SSRF / URL path traversal.
#
# --- FIX EM-L1 (2026-04-06) --------------------------------------------------
# Replaced the associative-array/plain-array dual registry with a single
# case-based _email_driver_lookup(). This removes dual-maintenance risk,
# works reliably in subshells, and avoids silent lookup failures when a new
# provider is added in one place but not the other.
#
# --- FIX EM-L2 (2026-04-06) --------------------------------------------------
# Mailgun and Postmark curl config temp files are now created with
# install -m 600 /dev/null "$cfg" before secrets are written, matching the
# hardened pattern already used by _email_bearer_post(). This removes the
# mktemp -> chmod TOCTOU window.
#
# --- FIX EM-H2 (2026-04-08) --------------------------------------------------
# _email_bearer_post(): response body temp file 'tmp' was created with plain
# mktemp, relying on umask for its mode. On systems with a permissive umask
# (e.g. 0022) the file is world-readable (644), exposing raw API response
# bodies that may contain token echoes or user data. Fix: harden with
# install -m 600 /dev/null before writing, matching the existing pattern
# used for 'cfg' in this function and already applied in _email_driver_mailgun
# and _email_driver_postmark (FIX EM-L2).
#
# --- FIX EM-H3 (2026-04-08) --------------------------------------------------
# No _email_driver_postfix() function existed for EMAIL_MODE=host, despite
# being documented in comments and edit-secrets.sh help text.
# send_email() in lib/common.sh fell through to "no driver" and silently
# discarded all alerts. An admin who set EMAIL_MODE=host received zero
# notification that email delivery was broken.
# Fix: add _email_driver_postfix() that pipes a minimal RFC-2822 message to
# sendmail -t (provided by the postfix sidecar container). Add a 'host' case
# arm to _email_driver_lookup() so the driver is discovered normally.
# -----------------------------------------------------------------------------

# Prevent direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: lib/email.sh must be sourced, not executed directly"
    exit 1
fi

# Guard against multiple sourcing
[[ -n "${LIB_EMAIL_LOADED:-}" ]] && return 0
readonly LIB_EMAIL_LOADED=1

set -euo pipefail

# _email_driver_lookup PROVIDER
# Prints the driver function suffix for PROVIDER, or returns 1 if unknown.
# Implemented as a single case statement so it works consistently in both the
# current shell and child subshells without exported registry state.
_email_driver_lookup() {
    local provider="${1,,}"
    case "$provider" in
        mailersend|sendgrid|mailgun|postmark|resend)
            printf '%s' "$provider"
            return 0
            ;;
        # FIX EM-H3: host/postfix driver for EMAIL_MODE=host (postfix sidecar)
        host|postfix)
            printf '%s' "postfix"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# -- HELPER: JSON string escape -----------------------------------------------
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

# -- HELPER: shared Bearer-token POST -----------------------------------------
_email_bearer_post() {
    local url="$1" payload="$2"
    local tmp cfg code
    tmp=$(mktemp -t vw_email.XXXXXXXXXX)
    # FIX EM-H2: harden tmp with install -m 600 so the response body file is
    # never world-readable regardless of the process umask. Matches the
    # existing pattern used for cfg below and in Mailgun/Postmark drivers.
    if ! install -m 600 /dev/null "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        log_error "_email_bearer_post: failed to secure response temp file"
        return 1
    fi
    cfg=$(mktemp -t vw_ecfg.XXXXXXXXXX)
    if ! install -m 600 /dev/null "$cfg" 2>/dev/null; then
        rm -f "$tmp" "$cfg"
        log_error "_email_bearer_post: failed to secure curl config temp file"
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
        -d "$payload" 2>/dev/null)

    _ECURL_CODE="$code"
    _ECURL_BODY=$(head -c 300 "$tmp" 2>/dev/null | tr -d '\n')
    [[ "$code" =~ ^2 ]] && return 0 || return 1
}

# -- DRIVER: MailerSend -------------------------------------------------------
_email_driver_mailersend() {
    local subject="$1" body="$2"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
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

    if _email_bearer_post "https://api.mailersend.com/v1/email" "$payload"; then
        [[ -n "${_ECURL_BODY}" ]] && log_warn "MailerSend: queued with warnings: ${_ECURL_BODY}"
        return 0
    fi
    log_warn "MailerSend API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
    return 1
}

# -- DRIVER: SendGrid ---------------------------------------------------------
_email_driver_sendgrid() {
    local subject="$1" body="$2"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
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
_email_driver_mailgun() {
    local subject="$1" body="$2"
    subject="${subject//$'\r'/}"
    subject="${subject//$'\n'/}"
    body="${body//$'\r'/}"
    body="${body//$'\n'/ }"
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"

    local domain="${MAILGUN_DOMAIN:-}"
    [[ -z "$domain" ]] && domain="${_from_email##*@}"
    if [[ -z "$domain" ]]; then
        log_error "Mailgun driver: cannot determine domain. Set MAILGUN_DOMAIN in .env"
        return 1
    fi

    if [[ ! "$domain" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        log_error "Mailgun driver: invalid domain '${domain}' (failed hostname validation). Check MAILGUN_DOMAIN or SMTP_FROM."
        return 1
    fi

    local mg_region="${MAILGUN_REGION:-us}"
    local mg_api_host
    case "${mg_region,,}" in
        us)  mg_api_host="api.mailgun.net" ;;
        eu)  mg_api_host="api.eu.mailgun.net" ;;
        *)
            log_error "Mailgun driver: unrecognised MAILGUN_REGION='${mg_region}'. Valid values: us eu"
            return 1
            ;;
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
        -o "$tmp" \
        -w "%{http_code}" \
        -X POST "https://${mg_api_host}/v3/${domain}/messages" \
        -F "from=${SMTP_FROM_NAME:-VaultWarden} <${_from_email}>" \
        -F "to=${ADMIN_EMAIL}" \
        -F "subject=${subject}" \
        -F "text=${body}" \
        -F "o:tracking=no" 2>/dev/null)

    local resp; resp=$(head -c 300 "$tmp" 2>/dev/null | tr -d '\n')
    [[ "$code" =~ ^2 ]] && return 0
    log_warn "Mailgun API HTTP ${code} (region=${mg_region}, host=${mg_api_host}): ${resp}"
    return 1
}

# -- DRIVER: Postmark ---------------------------------------------------------
_email_driver_postmark() {
    local subject="$1" body="$2"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
    fn=$(_email_json_escape "${SMTP_FROM_NAME:-VaultWarden}")
    fe=$(_email_json_escape "${_from_email}")
    ae=$(_email_json_escape "${ADMIN_EMAIL}")

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

    code=$(curl -s \
        --config "$cfg" \
        --connect-timeout 10 \
        --max-time 20 \
        --retry 2 \
        --retry-delay 3 \
        --retry-all-errors \
        -o "$tmp" \
        -w "%{http_code}" \
        -X POST "https://api.postmarkapp.com/email" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

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
_email_driver_resend() {
    local subject="$1" body="$2"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
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

# -- DRIVER: host/postfix (EMAIL_MODE=host, postfix sidecar) ------------------
# FIX EM-H3: Implements the EMAIL_MODE=host driver that was documented but
# missing. Pipes a minimal RFC-2822 message to sendmail -t which is provided
# by the postfix sidecar container. No API token is required or read.
#
# Usage: set EMAIL_MODE=host and EMAIL_PROVIDER=host (or EMAIL_PROVIDER=postfix)
# in .env. sendmail must be on PATH (standard in the postfix sidecar image).
_email_driver_postfix() {
    local subject="$1" body="$2"
    local _from_email="${SMTP_FROM:-${SMTP_FROM_EMAIL:-}}"
    local from_name="${SMTP_FROM_NAME:-VaultWarden}"
    local to_addr="${ADMIN_EMAIL:-}"

    if [[ -z "$to_addr" ]]; then
        log_error "postfix driver: ADMIN_EMAIL is not set"
        return 1
    fi

    if ! command -v sendmail >/dev/null 2>&1; then
        log_error "postfix driver: sendmail not found in PATH — is the postfix sidecar running?"
        return 1
    fi

    # Pipe a minimal RFC-2822 message to sendmail -t.
    # sendmail -t reads recipients from To:/Cc:/Bcc: headers so no separate
    # envelope argument is needed. -oi prevents a line with a single '.' from
    # prematurely ending the message body.
    printf 'From: %s <%s>\nTo: %s\nSubject: %s\n\n%s\n' \
        "$from_name" "$_from_email" "$to_addr" "$subject" "$body" \
        | sendmail -t -oi
}

export -f _email_json_escape _email_bearer_post _email_driver_lookup
export -f _email_driver_mailersend _email_driver_sendgrid _email_driver_mailgun
export -f _email_driver_postmark _email_driver_resend _email_driver_postfix

log_debug "lib/email.sh loaded (drivers: mailersend sendgrid mailgun postmark resend host/postfix)"
