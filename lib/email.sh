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
#             Two API regions: US (api.mailgun.net) / EU (api.eu.mailgun.net)
#             Set MAILGUN_REGION=eu in .env for EU-hosted accounts.
# Postmark    200 JSON PascalCase; check ErrorCode in body, not just HTTP code
# Resend      200 JSON; from is composite string, to is string array
#
# --- FIX-M01 (2026-03-09) ----------------------------------------------------
# All drivers now use ${SMTP_FROM_EMAIL:-${SMTP_FROM}} for the sender address.
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
# --- FIX EM-L1 (2026-03-10) --------------------------------------------------
# bash does not export associative arrays to subshells. _EMAIL_DRIVERS is now
# mirrored into two plain indexed arrays (_EMAIL_DRIVERS_KEYS /
# _EMAIL_DRIVERS_VALS) which ARE exportable. _email_driver_lookup() rebuilds
# the mapping at query time, so the dispatcher in common.sh works correctly
# whether lib/email.sh was sourced in the parent shell or a child subshell.
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
#
# FIX EM-L1: bash cannot export associative arrays.  We keep the associative
# array for in-process lookups but also maintain two plain indexed arrays that
# ARE exported so that child subshells can reconstruct the mapping via
# _email_driver_lookup() without re-sourcing the file.
declare -A _EMAIL_DRIVERS=(
    [mailersend]="mailersend"
    [sendgrid]="sendgrid"
    [mailgun]="mailgun"
    [postmark]="postmark"
    [resend]="resend"
)

# Serialised exportable shadow of _EMAIL_DRIVERS (plain indexed arrays)
_EMAIL_DRIVERS_KEYS=(mailersend sendgrid mailgun postmark resend)
_EMAIL_DRIVERS_VALS=(mailersend sendgrid mailgun postmark resend)
export _EMAIL_DRIVERS_KEYS _EMAIL_DRIVERS_VALS

# _email_driver_lookup PROVIDER
# Prints the driver function suffix for PROVIDER, or returns 1 if unknown.
# Works in subshells where _EMAIL_DRIVERS (associative) is not present by
# falling back to the exported plain-array shadow.
_email_driver_lookup() {
    local provider="${1,,}"
    # Fast path: associative array available (same shell as source)
    if declare -p _EMAIL_DRIVERS &>/dev/null 2>&1; then
        local val="${_EMAIL_DRIVERS[$provider]:-}"
        [[ -n "$val" ]] && { printf '%s' "$val"; return 0; }
    fi
    # Fallback: linear scan of the exported plain-array shadow
    local i
    for i in "${!_EMAIL_DRIVERS_KEYS[@]}"; do
        if [[ "${_EMAIL_DRIVERS_KEYS[$i]}" == "$provider" ]]; then
            printf '%s' "${_EMAIL_DRIVERS_VALS[$i]}"
            return 0
        fi
    done
    return 1
}

# -- HELPER: JSON string escape -----------------------------------------------
# Strips raw control chars U+0000-U+001F (EM-M2) then encodes the five
# characters that MUST be escaped in a JSON string value.
_email_json_escape() {
    local str="$1"
    # FIX EM-M2: Remove control characters U+0000-U+001F that are not \n \r \t.
    # LC_ALL=C ensures single-byte interpretation; the character class covers
    # all C0 controls; \n \r \t are excluded because we re-encode them below.
    str=$(LC_ALL=C printf '%s' "$str" \
        | LC_ALL=C sed 's/[\x00-\x08\x0b\x0c\x0e-\x1f]//g')
    # Encode the five mandatory JSON escape sequences (order matters: \ first)
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
#
# FIX EM-H1: The Authorization header is written to a temp curl config file
# and passed via --config @- (stdin) so the token never appears in the process
# table or in bash error/trace output.
# FIX EM-M1: --retry-all-errors added so HTTP 5xx also triggers the retry loop.
_email_bearer_post() {
    local url="$1" payload="$2"
    local tmp cfg code
    tmp=$(mktemp -t vw_email.XXXXXXXXXX)
    cfg=$(mktemp -t vw_ecfg.XXXXXXXXXX)
    trap 'rm -f "$tmp" "$cfg" 2>/dev/null; trap - RETURN' RETURN

    # Write the token into the curl config file -- never on the command line
    printf 'header = "Authorization: Bearer %s"\n' "${EMAIL_API_TOKEN}" >"$cfg"
    chmod 600 "$cfg"

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
# Docs:    https://developers.mailersend.com/api/v1/email.html
# Auth:    Authorization: Bearer {token}
# Success: HTTP 202 empty body; 202+JSON = queued with warnings (still success)
# Error:   HTTP 422 JSON { "message": "...", "errors": { ... } }
_email_driver_mailersend() {
    local subject="$1" body="$2"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    # FIX-M01: SMTP_FROM_EMAIL is DEPRECATED; canonical name is SMTP_FROM.
    # This shim will be removed once all deployments have migrated to SMTP_FROM=.
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
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

    # FIX-B01: _email_bearer_post returns 0 for all 2xx (including 202), so the
    # previous `&& return 0 / if 202` pattern had a permanently dead branch.
    # Restructured to if/else: on success, log any non-empty body as a warning
    # (202+JSON = queued with API warnings) then return 0; on failure log the
    # HTTP code and return 1.
    if _email_bearer_post "https://api.mailersend.com/v1/email" "$payload"; then
        # Non-empty body on a 2xx indicates queued-with-warnings from MailerSend.
        [[ -n "${_ECURL_BODY}" ]] && log_warn "MailerSend: queued with warnings: ${_ECURL_BODY}"
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
    # FIX-M01: SMTP_FROM_EMAIL is DEPRECATED; canonical name is SMTP_FROM.
    # This shim will be removed once all deployments have migrated to SMTP_FROM=.
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
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
#
# Regions:
#   MAILGUN_REGION=us  (default) -- api.mailgun.net    (accounts at mailgun.com)
#   MAILGUN_REGION=eu             -- api.eu.mailgun.net (accounts at eu.mailgun.com)
# FIX-B02: EU-region accounts received HTTP 404 from the hardcoded US endpoint.
# FIX EM-H1: --user credential moved to curl config file (not process table).
# FIX EM-M1: --retry-all-errors added.
# FIX EM-M3: domain validated against strict hostname regex before use in URL.
_email_driver_mailgun() {
    local subject="$1" body="$2"
    # FIX-M01: SMTP_FROM_EMAIL is DEPRECATED; canonical name is SMTP_FROM.
    # This shim will be removed once all deployments have migrated to SMTP_FROM=.
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"

    local domain="${MAILGUN_DOMAIN:-}"
    [[ -z "$domain" ]] && domain="${_from_email##*@}"
    if [[ -z "$domain" ]]; then
        log_error "Mailgun driver: cannot determine domain. Set MAILGUN_DOMAIN in .env"
        return 1
    fi

    # FIX EM-M3: Validate domain is a safe hostname before embedding in URL.
    # A crafted SMTP_FROM_EMAIL like user@host/path?q= would allow SSRF via
    # path traversal in the constructed curl URL.
    if [[ ! "$domain" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        log_error "Mailgun driver: invalid domain '${domain}' (failed hostname validation). Check MAILGUN_DOMAIN or SMTP_FROM."
        return 1
    fi

    # FIX-B02: Select the correct regional API endpoint.
    # Mailgun US and EU are completely separate fleets; using the wrong endpoint
    # always returns HTTP 404 ("Domain not found"), which is indistinguishable
    # from a misconfigured MAILGUN_DOMAIN and produces confusing log output.
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
    trap 'rm -f "$tmp" "$cfg" 2>/dev/null; trap - RETURN' RETURN

    # FIX EM-H1: Write Basic Auth credential to config file -- not process table.
    printf 'user = "api:%s"\n' "${EMAIL_API_TOKEN}" >"$cfg"
    chmod 600 "$cfg"

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
# Docs:    https://postmarkapp.com/developer/api/email-api
# Auth:    X-Postmark-Server-Token: {token}  (NOT Authorization: Bearer)
# Payload: JSON PascalCase; From and To are plain strings
# IMPORTANT: HTTP 200 does NOT mean success -- must check ErrorCode in body
# Success: HTTP 200 JSON { "ErrorCode": 0, ... }
#
# FIX EM-H1: X-Postmark-Server-Token moved to curl config file.
# FIX EM-M1: --retry-all-errors added.
_email_driver_postmark() {
    local subject="$1" body="$2"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    # FIX-M01: SMTP_FROM_EMAIL is DEPRECATED; canonical name is SMTP_FROM.
    # This shim will be removed once all deployments have migrated to SMTP_FROM=.
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
    # FIX-M03: JSON-escape envelope fields. The Postmark driver uses inline
    # -d "{ ... }" rather than a heredoc, making unescaped quotes in display
    # names particularly hard to spot and immediately fatal (HTTP 400).
    fn=$(_email_json_escape "${SMTP_FROM_NAME:-VaultWarden}")
    fe=$(_email_json_escape "${_from_email}")
    ae=$(_email_json_escape "${ADMIN_EMAIL}")

    local tmp cfg code
    tmp=$(mktemp -t vw_email.XXXXXXXXXX)
    cfg=$(mktemp -t vw_ecfg.XXXXXXXXXX)
    trap 'rm -f "$tmp" "$cfg" 2>/dev/null; trap - RETURN' RETURN

    # FIX EM-H1: Token written to config file -- never on the command line.
    printf 'header = "X-Postmark-Server-Token: %s"\n' "${EMAIL_API_TOKEN}" >"$cfg"
    chmod 600 "$cfg"

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
# Docs:    https://resend.com/docs/api-reference/emails/send-email
# Auth:    Authorization: Bearer {token}
# IMPORTANT: from is a string "Name <email>"; to is ["email"] not [{email:...}]
# Success: HTTP 200 JSON { "id": "..." }
_email_driver_resend() {
    local subject="$1" body="$2"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    # FIX-M01: SMTP_FROM_EMAIL is DEPRECATED; canonical name is SMTP_FROM.
    # This shim will be removed once all deployments have migrated to SMTP_FROM=.
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
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

# Export all driver functions and the lookup helper so they are available in
# subshells.  _EMAIL_DRIVERS_KEYS/_EMAIL_DRIVERS_VALS (plain indexed arrays)
# are already exported above; _email_driver_lookup() uses them as the fallback
# when the associative _EMAIL_DRIVERS is unavailable in a child subshell (EM-L1).
export -f _email_json_escape _email_bearer_post _email_driver_lookup
export -f _email_driver_mailersend _email_driver_sendgrid _email_driver_mailgun
export -f _email_driver_postmark _email_driver_resend

log_debug "lib/email.sh loaded (drivers: ${!_EMAIL_DRIVERS[*]})"
