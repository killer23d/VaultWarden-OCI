#!/usr/bin/env bash
# Socket-activated CrowdSec HTTP adapter. It deliberately contains no provider
# implementation: delivery is delegated to the repository's existing send_email().

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/config.sh"
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib crowdsec-notify-adapter
source "${PROJECT_ROOT}/lib/crypto.sh"
source "${PROJECT_ROOT}/lib/secrets.sh"
source "${PROJECT_ROOT}/lib/email.sh"

readonly MAX_REQUEST_LINE_BYTES=2048
readonly MAX_HEADER_LINE_BYTES=8192
readonly MAX_BODY_BYTES="${CROWDSEC_NOTIFY_MAX_BODY_BYTES:-262144}"
readonly FAILURE_SENTINEL_NAME="CROWDSEC_NOTIFY_FAILED"

# Standard output is the accepted socket. Keep it on fd 3 and route every normal
# log line to the journal through stderr so logs cannot corrupt the HTTP reply.
exec 3>&1
exec 1>&2

_http_reply() {
    local status="$1" reason="$2" body="${3:-}"
    local length=${#body}
    printf 'HTTP/1.1 %s %s\r\nConnection: close\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %s\r\n\r\n%s' \
        "$status" "$reason" "$length" "$body" >&3
}

_load_adapter_environment() {
    if load_project_environment 2>/dev/null; then
        return 0
    fi
    if load_env_file /etc/vaultwarden/vaultwarden.env 2>/dev/null; then
        resolve_secrets_file
        return 0
    fi
    log_error "CrowdSec notification adapter cannot load the VaultWarden runtime environment."
    return 1
}

_read_request() {
    local request_line header lower_header content_length="" transfer_encoding=""
    local content_length_count=0 header_count=0

    if ! IFS= read -r request_line; then
        return 1
    fi
    request_line="${request_line%$'\r'}"
    if (( ${#request_line} > MAX_REQUEST_LINE_BYTES )); then
        _http_reply 414 "URI Too Long" "request line too long"
        return 2
    fi
    case "$request_line" in
        'POST /notify HTTP/1.1'|'POST /notify HTTP/1.0') ;;
        'GET '*|'HEAD '*|'PUT '*|'DELETE '*|'PATCH '*)
            _http_reply 405 "Method Not Allowed" "POST required"
            return 2
            ;;
        *)
            _http_reply 404 "Not Found" "unknown endpoint"
            return 2
            ;;
    esac

    while IFS= read -r header; do
        header="${header%$'\r'}"
        [[ -n "$header" ]] || break
        (( header_count++ )) || true
        if (( header_count > 64 || ${#header} > MAX_HEADER_LINE_BYTES )); then
            _http_reply 431 "Request Header Fields Too Large" "headers exceed the accepted limit"
            return 2
        fi
        if [[ "$header" == *$'\n'* || "$header" == *$'\r'* ]]; then
            _http_reply 400 "Bad Request" "invalid header"
            return 2
        fi
        lower_header="${header,,}"
        case "$lower_header" in
            content-length:*)
                (( content_length_count++ )) || true
                if (( content_length_count > 1 )); then
                    _http_reply 400 "Bad Request" "duplicate Content-Length"
                    return 2
                fi
                content_length="${header#*:}"
                content_length="${content_length//[[:space:]]/}"
                ;;
            transfer-encoding:*)
                transfer_encoding="${header#*:}"
                transfer_encoding="${transfer_encoding,,}"
                transfer_encoding="${transfer_encoding//[[:space:]]/}"
                ;;
        esac
    done

    if [[ -n "$transfer_encoding" && "$transfer_encoding" != "identity" ]]; then
        _http_reply 400 "Bad Request" "chunked transfer encoding is not supported"
        return 2
    fi
    if [[ ! "$content_length" =~ ^[0-9]+$ ]]; then
        _http_reply 411 "Length Required" "Content-Length required"
        return 2
    fi
    if (( content_length < 2 || content_length > MAX_BODY_BYTES )); then
        _http_reply 413 "Payload Too Large" "invalid payload size"
        return 2
    fi

    REQUEST_BODY=""
    if ! IFS= read -r -N "$content_length" REQUEST_BODY; then
        _http_reply 400 "Bad Request" "incomplete request body"
        return 2
    fi
}

_format_alerts() {
    jq -er '
      if type != "array" or length == 0 then
        error("expected a non-empty alert array")
      else
        .[:10]
        | map(
            "Source: " + ((.source.value // .source.ip // .source.range // "unknown") | tostring) + "\n" +
            "Scenario: " + ((.scenario // "unknown") | tostring) + "\n" +
            "Machine ID: " + ((.machine_id // "unknown") | tostring) + "\n" +
            (((.decisions // [])[:5]
              | map(
                  "Decision type: " + ((.type // "unknown") | tostring) + "\n" +
                  "Decision duration: " + ((.duration // "unknown") | tostring)
                )
              | join("\n")) // "") + "\n---"
          )
        | join("\n")
      end
    ' <<<"$REQUEST_BODY"
}

_failure_state_dir() {
    local state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    printf '%s/.vw-health-alert\n' "$state_dir"
}

_write_failure_sentinel() {
    local state_dir path tmp
    state_dir="$(_failure_state_dir)"
    [[ "$state_dir" == /* && "$state_dir" != "/.vw-health-alert" ]] || return 1
    mkdir -p "$state_dir" || return 1
    chmod 0750 "$state_dir" 2>/dev/null || true
    path="${state_dir}/${FAILURE_SENTINEL_NAME}"
    tmp="$(mktemp "${state_dir}/.${FAILURE_SENTINEL_NAME}.XXXXXXXX")" || return 1
    printf 'time=%s\nmode=auto\nprovider=%s\n' \
        "$(date -Iseconds)" "${EMAIL_PROVIDER:-unset}" >"$tmp"
    chmod 0600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$path"
}

_clear_failure_sentinel() {
    local state_dir
    state_dir="$(_failure_state_dir)"
    [[ "$state_dir" == /* && "$state_dir" != "/.vw-health-alert" ]] || return 0
    rm -f "${state_dir}/${FAILURE_SENTINEL_NAME}" 2>/dev/null || true
}

main() {
    require_root "$@"
    command -v jq >/dev/null 2>&1 || {
        log_error "jq is required by the CrowdSec notification adapter."
        exec 3>&-
        return 1
    }
    [[ "$MAX_BODY_BYTES" =~ ^[1-9][0-9]*$ ]] || {
        log_error "CROWDSEC_NOTIFY_MAX_BODY_BYTES must be a positive integer."
        exec 3>&-
        return 1
    }

    local request_rc=0 body recipient subject
    _read_request || request_rc=$?
    case "$request_rc" in
        0) ;;
        2) return 0 ;;
        *) exec 3>&-; return 1 ;;
    esac

    if ! body="$(_format_alerts)"; then
        log_warn "CrowdSec notification adapter rejected malformed alert JSON."
        _http_reply 400 "Bad Request" "invalid CrowdSec alert payload"
        return 0
    fi

    _load_adapter_environment || {
        exec 3>&-
        return 1
    }
    recipient="${ADMIN_EMAIL:-}"
    if [[ -z "$recipient" ]]; then
        log_error "ADMIN_EMAIL is not configured for CrowdSec notifications."
        _write_failure_sentinel || true
        exec 3>&-
        return 1
    fi

    subject="${CROWDSEC_NOTIFICATION_SUBJECT:-CRITICAL: CrowdSec security event}"
    # Force the existing repository auto chain only for this call. Provider
    # drivers, SOPS secret lookup, Postfix submission and direct SMTP fallback
    # remain owned by lib/email.sh.
    if EMAIL_MODE=auto send_email "$recipient" "$subject" "$body"; then
        _clear_failure_sentinel
        _http_reply 204 "No Content"
        log_info "CrowdSec security event accepted by the existing email delivery chain."
        return 0
    fi

    _write_failure_sentinel || log_warn "Could not write CrowdSec notification failure sentinel."
    log_error "All CrowdSec email delivery routes failed. Closing without an HTTP response so CrowdSec retries the plugin call."
    # CrowdSec 1.7's HTTP plugin treats ordinary non-2xx responses as success.
    # Closing without a response produces a transport error, which activates the
    # notification broker's configured max_retry behavior.
    exec 3>&-
    return 1
}

main "$@"
