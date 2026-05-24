#!/usr/bin/env bash
# lib/validate.sh — Pure input-validation functions for VaultWarden-OCI.
# Provides:
#   validate_email, validate_domain, validate_port, validate_ip, validate_url
# All functions are pure: they accept one argument, apply a constraint, and
# return 0 (valid) or 1 (invalid). No side effects, no I/O, no logging.
# Dependencies: none (intentional — keeps this file unit-testable in isolation)
# Sourced by: lib/common.sh (facade)

[[ -n "${VW_VALIDATE_LIB_LOADED:-}" ]] && return 0
readonly VW_VALIDATE_LIB_LOADED=1

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
