#!/usr/bin/env bash
# lib/validate.sh — Input validation functions for VaultWarden-OCI.
#
# Standalone; no dependencies on other lib files.
#
# Provides:
#   validate_email           — RFC 5321 length guard + regex format check
#   validate_domain          — Full FQDN validation: rejects schemes, paths,
#                              ports, placeholders, bare IPs, and bad labels
#   _validate_domain_reason  — Returns a human-readable rejection reason
#                              (non-exported helper for callers that need
#                              actionable error messages, e.g. setup-env.sh)
#   validate_port            — integer in range 1–65535
#   validate_ip              — dotted-quad IPv4 with per-octet bounds check
#   validate_url             — http/https URL with optional port and path

[[ -n "${VW_VALIDATE_LIB_LOADED:-}" ]] && return 0
readonly VW_VALIDATE_LIB_LOADED=1

# Self-load log.sh if not already loaded — validate functions are pure
# boolean exit-code validators and do not call log_* themselves. This
# guard exists only so validate.sh can be sourced in isolation (tests,
# tooling) without a caller that pre-loads log.sh.
_VW_VALIDATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${VW_LOG_LIB_LOADED:-}" ]] || source "${_VW_VALIDATE_LIB_DIR}/log.sh"
unset _VW_VALIDATE_LIB_DIR

# ---------------------------------------------------------------------------
# validate_email — RFC 5321 compliant email format check
# ---------------------------------------------------------------------------
validate_email() {
    local email="$1"

    # RFC 5321 §4.5.3.1: maximum total length is 254 characters.
    [[ ${#email} -le 254 ]] || return 1

    local local_part domain
    case "$email" in
        *@*@*) return 1 ;;
        *@*)   ;;
        *)     return 1 ;;
    esac
    local_part="${email%%@*}"
    domain="${email#*@}"

    # RFC 5321 §4.5.3.1: local-part ≤ 64 octets.
    [[ ${#local_part} -le 64 ]] || return 1

    # RFC 5321 §4.5.3.1: domain ≤ 253 octets.
    [[ ${#domain} -le 253 ]] || return 1

    [[ "$local_part" =~ ^\. ]] && return 1
    [[ "$local_part" =~ \.$ ]] && return 1
    [[ "$local_part" =~ ^[a-zA-Z0-9._%+-]+$ ]] || return 1

    # Domain: must have at least one dot; accept subdomains (mail.sub.example.com);
    # accept long modern TLDs (e.g. .museum, .photography, .cloud).
    # Reject bare hostnames and leading/trailing hyphens per RFC 1035.
    [[ "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || return 1

    return 0
}

# ---------------------------------------------------------------------------
# _validate_domain_reason DOMAIN
#
# Returns (via stdout) a single human-readable sentence explaining why
# DOMAIN is invalid, or the empty string if it is valid.
#
# Intended for callers (e.g. setup-env.sh) that need actionable error
# output.  Not exported — internal use only.
# ---------------------------------------------------------------------------
_validate_domain_reason() {
    local raw="$1"

    # 1. Reject values that still carry a URL scheme.
    #    The DOMAIN variable must hold a bare hostname, not a URL.
    if [[ "$raw" =~ ^https?:// ]]; then
        printf 'DOMAIN must be a bare hostname without a scheme — '
        printf 'remove "%s" and pass only the hostname (e.g. vault.example.com).' \
            "${raw%%://*}://"
        return 0
    fi

    if [[ "$raw" == */* ]]; then
        printf 'DOMAIN must not contain a path — '
        printf 'use "%s" instead of "%s".' "${raw%%/*}" "$raw"
        return 0
    fi

    if [[ "$raw" =~ :[0-9]+$ ]]; then
        local host_only="${raw%:*}"
        printf 'DOMAIN must not include a port number — '
        printf 'use "%s" instead of "%s".' "$host_only" "$raw"
        return 0
    fi

    # 4. Reject known placeholder / example strings (case-insensitive).
    local lower
    lower=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        vault.example.com|example.com|your.domain.com|\
your-domain.com|yourdomain.com|hostname|change_me|changeme|\
"<domain>"|"your_domain")
            printf 'DOMAIN still contains a placeholder value ("%s") — ' "$raw"
            printf 'replace it with your real registered domain name.'
            return 0
            ;;
    esac

    # 5. Reject bare IPv4 addresses — Caddy ACME requires a real FQDN.
    if [[ "$raw" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf 'DOMAIN must be a DNS name, not an IP address ("%s") — ' "$raw"
        printf 'Caddy requires a real FQDN to obtain a TLS certificate via ACME.'
        return 0
    fi

    # 6. Reject localhost / loopback names.
    case "$lower" in
        localhost|localhost.localdomain)
            printf 'DOMAIN "%s" is a loopback name and cannot receive a public TLS certificate.' "$raw"
            return 0
            ;;
    esac

    # 7. RFC 1035: total length must not exceed 253 characters.
    if (( ${#raw} > 253 )); then
        printf 'DOMAIN is too long (%d chars) — RFC 1035 limits domain names to 253 characters.' \
            "${#raw}"
        return 0
    fi

    # 8. Must contain at least one dot (bare hostnames have no TLD).
    if [[ "$raw" != *.* ]]; then
        printf 'DOMAIN "%s" has no dot — a fully-qualified domain name is required (e.g. vault.example.com).' \
            "$raw"
        return 0
    fi

    # 9. Validate every DNS label individually.
    #    Rules per RFC 1035 §2.3.4 and RFC 1123 §2.1:
    #      - 1–63 characters per label
    #      - characters: [a-zA-Z0-9] and hyphens, but not leading/trailing hyphen
    #      - Punycode ACE prefix (xn--) is explicitly accepted
    local IFS_SAVE="$IFS"
    IFS='.'
    local label tld=''
    for label in $raw; do
        tld="$label"
        [[ -n "$label" ]] || {
            IFS="$IFS_SAVE"
            printf 'DOMAIN "%s" contains an empty label (consecutive dots or a trailing dot).' "$raw"
            return 0
        }
        (( ${#label} >= 1 && ${#label} <= 63 )) || {
            IFS="$IFS_SAVE"
            printf 'DNS label "%s" in "%s" is %d characters — labels must be 1–63 characters.' \
                "$label" "$raw" "${#label}"
            return 0
        }
        [[ "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || {
            IFS="$IFS_SAVE"
            printf 'DNS label "%s" in "%s" contains invalid characters or leading/trailing hyphens.' \
                "$label" "$raw"
            return 0
        }
    done
    IFS="$IFS_SAVE"

    # 10. TLD must be alphabetic and at least 2 characters (no all-numeric TLD).
    if [[ ! "$tld" =~ ^[a-zA-Z]{2,}$ ]]; then
        printf 'TLD "%s" in "%s" must be at least 2 alphabetic characters (e.g. .com, .org, .cloud).' \
            "$tld" "$raw"
        return 0
    fi

    printf ''
}

# ---------------------------------------------------------------------------
# validate_domain DOMAIN
#
# Returns 0 (success) when DOMAIN is a valid bare FQDN suitable for use
# with Caddy ACME TLS provisioning; 1 otherwise.
#
# Contract: pure boolean — no output, no log calls.  Callers that need a
# human-readable reason should call _validate_domain_reason() first.
# ---------------------------------------------------------------------------
validate_domain() {
    local reason
    reason="$(_validate_domain_reason "$1")"
    [[ -z "$reason" ]]
}

# ---------------------------------------------------------------------------
# validate_port PORT
# ---------------------------------------------------------------------------
validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

# ---------------------------------------------------------------------------
# validate_ip DOTTED_QUAD
# ---------------------------------------------------------------------------
validate_ip() {
    local ip="$1"
    local -i octet
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    # Limit the IFS change to this read so the caller's shell state is preserved.
    IFS='.' read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        (( octet >= 0 && octet <= 255 )) || return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
# validate_url URL
# ---------------------------------------------------------------------------
validate_url() {
    local url="$1"
    [[ "$url" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$ ]]
}

export -f validate_email validate_domain validate_port validate_ip validate_url
