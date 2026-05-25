#!/usr/bin/env bash
# lib/email.sh — Email delivery subsystem for VaultWarden-OCI
#
# Provides multi-provider outbound email: HTTP API drivers (MailerSend,
# SendGrid, Mailgun, Postmark, Resend, CyberPersons), SMTP relay,
# Postfix sidecar, and host MTA fallback.
#
# Depends on: lib/log.sh (auto-loaded if not already present),
#             lib/common.sh (has_command, retry_with_backoff).
# Must be sourced AFTER lib/common.sh.

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


_email_bearer_post() {
    local url="$1" payload="$2"
    local tmp cfg code
    tmp=$(mktemp -t vw_email.XXXXXXXXXX)
    # Harden tmp with install -m 600 so the response body file is
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

# _email_driver_lookup PROVIDER
# Prints the driver function suffix for PROVIDER, or returns 1 if unknown.
# Implemented as a single case statement so it works consistently in both the
# current shell and child subshells without exported registry state.
_email_driver_lookup() {
    local provider="${1,,}"
    case "$provider" in
        mailersend|sendgrid|mailgun|postmark|resend|cyberpersons)
            printf '%s' "$provider"
            return 0
            ;;
        host|postfix)
            printf '%s' "postfix"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}


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


_email_driver_cyberpersons() {
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


# DRIVER: host/postfix (EMAIL_MODE=host, postfix sidecar)
# Implements the EMAIL_MODE=host driver. Pipes a minimal RFC-2822 message to
# sendmail -t which is provided by the postfix sidecar container. No API token
# is required or read.
#
# Usage: set EMAIL_MODE=host and EMAIL_PROVIDER=host (or EMAIL_PROVIDER=postfix)
# in .env. sendmail must be on PATH (standard in the postfix sidecar image).
_email_driver_postfix() {
    local subject="$1" body="$2"
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
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


_rate_limit_check() {
    local subject="$1"
    local rate_limit_dir="$2"
    local last_email_file

    # sha256sum is required to construct the stamp file path.  If it is absent
    # (minimal Alpine/OCI base images), skip rate-limiting rather than aborting.
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
        if (( current_time - last_time < 3600 )); then
            log_debug "Email rate limited for non-critical notification: $subject"
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
    local to="$1"
    local subject="$2"
    local body="$3"

    [[ -z "$to" ]] && { log_error "_smtp_send: recipient (to) is empty"; return 1; }

    local _smtp_from_addr="${SMTP_FROM_EMAIL:-${SMTP_FROM:-${SMTP_USERNAME:-}}}"
    local _smtp_from_name="${SMTP_FROM_NAME:-VaultWarden}"

    local date_str
    date_str=$(date -u '+%a, %d %b %Y %H:%M:%S +0000')

    # Write the RFC-5322 message to a temp file rather than capturing in $()
    # so that the terminating \r\n blank line is preserved — command substitution
    # strips trailing newlines, which corrupts the MIME body boundary.
    local _msg_file
    _msg_file=$(mktemp -t vw_smtp.XXXXXXXXXX) || {
        log_error "_smtp_send: failed to create SMTP message temp file"
        return 1
    }
    chmod 600 "$_msg_file"
    # shellcheck disable=SC2064  # intentional: expand _msg_file now to capture the value
    trap "rm -f '${_msg_file}' 2>/dev/null; trap - RETURN" RETURN

    {
        printf 'From: "%s" <%s>\r\n' "$_smtp_from_name" "$_smtp_from_addr"
        printf 'To: %s\r\n'          "$to"
        printf 'Subject: %s\r\n'     "$subject"
        printf 'Date: %s\r\n'        "$date_str"
        printf 'MIME-Version: 1.0\r\n'
        printf 'Content-Type: text/plain; charset=UTF-8\r\n'
        printf 'Content-Transfer-Encoding: 7bit\r\n'
        printf '\r\n'
        while IFS= read -r line; do
            printf '%s\r\n' "$line"
        done <<< "$body"
        printf '\r\n'
    } > "$_msg_file" || {
        log_error "_smtp_send: failed to write SMTP message to temp file"
        return 1
    }

    # Path A: SMTP_PASSWORD present → direct external relay
    # This branch must stay in sync with _resolve_smtp_method returning
    # "smtp (direct relay)".
    if [[ -n "${SMTP_PASSWORD:-}" ]]; then
        [[ -z "${SMTP_HOST:-}"     ]] && { log_error "_smtp_send: SMTP_HOST is not set";     return 1; }
        [[ -z "${SMTP_USERNAME:-}" ]] && { log_error "_smtp_send: SMTP_USERNAME is not set"; return 1; }

        local smtp_port="${SMTP_PORT:-587}"
        local smtp_security="${SMTP_SECURITY:-}"
        local smtp_url
        local smtp_tls_flags=()

        [[ -z "$smtp_security" ]] && { [[ "$smtp_port" == "465" ]] && smtp_security="tls" || smtp_security="starttls"; }

        case "${smtp_security,,}" in
            tls|ssl)    smtp_url="smtps://${SMTP_HOST}:${smtp_port}" ;;
            starttls)   smtp_url="smtp://${SMTP_HOST}:${smtp_port}"; smtp_tls_flags=(--ssl-reqd) ;;
            none|plain) smtp_url="smtp://${SMTP_HOST}:${smtp_port}" ;;
            *)
                log_error "_smtp_send: Unknown SMTP_SECURITY='${smtp_security}'. Valid: tls starttls none"
                return 1
                ;;
        esac

        curl -s \
            --connect-timeout 15 \
            --max-time 30 \
            --retry 2 \
            --retry-delay 5 \
            "${smtp_tls_flags[@]}" \
            --url "$smtp_url" \
            --mail-from "$_smtp_from_addr" \
            --mail-rcpt "$to" \
            --user "${SMTP_USERNAME}:${SMTP_PASSWORD}" \
            --upload-file "$_msg_file"
        return $?
    fi

    # Path B: No SMTP_PASSWORD → Postfix sidecar (normal production path)
    # This branch must stay in sync with _resolve_smtp_method returning
    # "smtp (postfix sidecar)".
    local _sidecar_addr="${VW_SMTP_HOST_PORT:-127.0.0.1:587}"
    local _sidecar_host _sidecar_port
    _sidecar_host="${_sidecar_addr%:*}"
    _sidecar_port="${_sidecar_addr##*:}"

    log_debug "_smtp_send: no SMTP_PASSWORD — routing through Postfix sidecar at ${_sidecar_addr}"

    # Fast sidecar liveness probe to avoid long curl timeouts when postfix
    # is down/unbound on localhost.
    if command -v nc >/dev/null 2>&1; then
        if ! nc -z -w 2 "$_sidecar_host" "$_sidecar_port" >/dev/null 2>&1; then
            log_warn "_smtp_send: Postfix sidecar unreachable at ${_sidecar_addr} (probe failed) — skipping SMTP attempt"
            return 1
        fi
    elif ! (echo >/dev/tcp/"$_sidecar_host"/"$_sidecar_port") >/dev/null 2>&1; then
        log_warn "_smtp_send: Postfix sidecar unreachable at ${_sidecar_addr} (probe failed) — skipping SMTP attempt"
        return 1
    fi

    curl -s \
        --connect-timeout 5 \
        --max-time 15 \
        --retry 1 \
        --retry-delay 2 \
        --url "smtp://${_sidecar_host}:${_sidecar_port}" \
        --mail-from "$_smtp_from_addr" \
        --mail-rcpt "$to" \
        --upload-file "$_msg_file"
    local _rc=$?
    if [[ $_rc -ne 0 ]]; then
        log_warn "_smtp_send: Postfix sidecar at ${_sidecar_addr} returned curl exit ${_rc}. Is the container running and port 127.0.0.1:587 bound?"
    fi
    return $_rc
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

    # Capture shared metadata values once — avoids repeated subshell forks
    # and guarantees a consistent timestamp across all delivery-path bodies.
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
            log_info  "Valid providers: mailersend sendgrid mailgun postmark resend cyberpersons smtp host"
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
                date +%s > "$stamp_file" 2>/dev/null || true
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
            date +%s > "$stamp_file" 2>/dev/null || true
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
                date +%s > "$stamp_file" 2>/dev/null || true
                return 0
            fi
            host_mta_failed=true
        else
            host_mta_failed=true
        fi
        if [[ "$mode" == "host" ]]; then
            log_error "EMAIL_MODE=host: host MTA failed or not available — no fallback configured"
            return 1
        fi
    fi

    if [[ "$mode" == "auto" && "$host_mta_failed" == "true" && -n "$api_token" && -n "$api_driver_fn" ]]; then
        log_error "SMTP/host MTA delivery unavailable — attempting emergency API bypass (${provider})"

        local emergency_body
        emergency_body="$(_build_email_metadata_body \
            "$base_body" "$host_fqdn" "$ts" "$mode" "$provider" \
            "api emergency bypass (${provider})")"
        emergency_body="${emergency_body}

⚠ Delivery note: Sent via emergency API bypass after SMTP/host MTA failure."

        if EMAIL_API_TOKEN="$api_token" "$api_driver_fn" "$subject" "$emergency_body"; then
            log_success "Emergency API bypass succeeded via ${provider}: ${subject}"
            date +%s > "$stamp_file" 2>/dev/null || true
            return 0
        fi
        log_error "Emergency API bypass failed via ${provider}"
    elif [[ "$mode" == "auto" && "$host_mta_failed" == "true" ]]; then
        log_error "Emergency API bypass skipped: EMAIL_API_TOKEN not resolved for provider '${provider}' — run: ./utilities/secrets-rotate.sh email_api_token"
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
    # sha256sum required for stamp path construction; skip silently if absent.
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


export -f _email_json_escape _email_bearer_post _email_driver_lookup
export -f _email_driver_mailersend _email_driver_sendgrid _email_driver_mailgun
export -f _email_driver_postmark _email_driver_resend _email_driver_postfix
export -f _email_driver_cyberpersons
export -f _normalise_email_subject _resolve_rate_limit_dir _rate_limit_check
export -f _resolve_smtp_method _build_email_metadata_body
export -f _smtp_send send_email send_notification_email clear_email_rate_limit
