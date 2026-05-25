#!/usr/bin/env bash
# lib/validate.sh — Input validation functions for VaultWarden-OCI.
#
# Standalone; no dependencies on other lib files.
#
# Provides:
#   validate_email   — RFC 5321 length guard (254 chars) + regex format check
#   validate_domain  — RFC 1035 length guard (253 chars) + bare-IPv4 rejection
#   validate_port    — integer in range 1–65535
#   validate_ip      — dotted-quad IPv4 with per-octet bounds check
#   validate_url     — http/https URL with optional port and path

[[ -n "${VW_VALIDATE_LIB_LOADED:-}" ]] && return 0
readonly VW_VALIDATE_LIB_LOADED=1

# Self-load log.sh if not already loaded — validate functions are pure
# boolean exit-code validators and do not call log_* themselves. This
# guard exists only so validate.sh can be sourced in isolation (tests,
# tooling) without a caller that pre-loads log.sh.
_VW_VALIDATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${VW_LOG_LIB_LOADED:-}" ]] || source "${_VW_VALIDATE_LIB_DIR}/log.sh"
unset _VW_VALIDATE_LIB_DIR

validate_email() {
    local email="$1"
    # RFC 5321: maximum total length is 254 characters.
    [[ ${#email} -le 254 ]] || return 1
    [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

validate_domain() {
    local domain="$1"
    domain=$(printf '%s' "$domain" | sed 's|https\?://||; s|/.*$||')
    # RFC 1035: maximum total length is 253 characters.
    [[ ${#domain} -le 253 ]] || return 1
    # Bare IPv4 addresses are rejected: production deployments require a proper
    # domain name so that Caddy can obtain a TLS certificate via ACME/HTTPS.
    [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 1
    [[ "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

validate_ip() {
    local ip="$1"
    local -i octet
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        (( octet >= 0 && octet <= 255 )) || return 1
    done
    return 0
}

validate_url() {
    local url="$1"
    [[ "$url" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$ ]]
}

export -f validate_email validate_domain validate_port validate_ip validate_url
