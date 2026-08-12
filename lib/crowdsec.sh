#!/usr/bin/env bash
# lib/crowdsec.sh - Shared CrowdSec readiness and LAPI resolution helpers.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This library should be sourced, not executed directly" >&2
    exit 1
fi

[[ -n "${VW_CROWDSEC_LIB_LOADED:-}" ]] && return 0
readonly VW_CROWDSEC_LIB_LOADED=1

# Callers read this after crowdsec_worker_readiness returns.
# shellcheck disable=SC2034
CROWDSEC_READINESS_DETAIL=""

# The optional config path is supplied by setup/worker callers in other sourced files.
# shellcheck disable=SC2120
crowdsec_resolve_lapi_port() {
    local config_file="${1:-${VW_CROWDSEC_ETC_DIR:-/etc/crowdsec}/config.yaml}"
    local -a matches=()
    [[ -r "$config_file" ]] || return 1
    mapfile -t matches < <(
        sed -nE 's/^[[:space:]]*listen_uri:[[:space:]]*127\.0\.0\.1:([0-9]+)[[:space:]]*$/\1/p' "$config_file"
    )
    (( ${#matches[@]} == 1 )) || return 1
    [[ "${matches[0]}" =~ ^[0-9]+$ ]] || return 1
    (( matches[0] >= 1 && matches[0] <= 65535 )) || return 1
    printf '%s\n' "${matches[0]}"
}

_crowdsec_bouncers_list_raw() {
    if cscli bouncers list -o raw 2>/dev/null; then
        return 0
    fi
    if [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
        sudo -n cscli bouncers list -o raw 2>/dev/null
        return $?
    fi
    return 1
}

# This function communicates operator detail through CROWDSEC_READINESS_DETAIL.
# shellcheck disable=SC2034
crowdsec_worker_readiness() {
    CROWDSEC_READINESS_DETAIL=""

    if [[ "${CLOUDFLARE_PROXY_ENABLED:-false}" != "true" ]]; then
        CROWDSEC_READINESS_DETAIL="non-golden mode: CLOUDFLARE_PROXY_ENABLED is not true"
        return 10
    fi
    if [[ "${CF_AUTONOMOUS_MODE:-${AUTONOMOUS_MODE:-false}}" == "true" ]]; then
        CROWDSEC_READINESS_DETAIL="advanced non-golden mode: autonomous Worker deployment has no persistent bouncer service"
        return 10
    fi

    command -v systemctl >/dev/null 2>&1 || {
        CROWDSEC_READINESS_DETAIL="systemctl is unavailable"
        return 1
    }
    command -v cscli >/dev/null 2>&1 || {
        CROWDSEC_READINESS_DETAIL="cscli is unavailable"
        return 1
    }
    if ! systemctl cat crowdsec-cloudflare-worker-bouncer.service >/dev/null 2>&1; then
        CROWDSEC_READINESS_DETAIL="crowdsec-cloudflare-worker-bouncer.service is not installed"
        return 1
    fi
    if ! systemctl is-active --quiet crowdsec-cloudflare-worker-bouncer.service; then
        CROWDSEC_READINESS_DETAIL="crowdsec-cloudflare-worker-bouncer.service is not active"
        return 1
    fi

    local bouncers_output
    if ! bouncers_output="$(_crowdsec_bouncers_list_raw)"; then
        CROWDSEC_READINESS_DETAIL="cscli bouncers query failed"
        return 1
    fi
    if ! grep -Eq '(^|[[:space:]])cloudflare-worker-bouncer([[:space:]]|$)' <<< "$bouncers_output"; then
        CROWDSEC_READINESS_DETAIL="cloudflare-worker-bouncer is not registered in CrowdSec LAPI"
        return 1
    fi

    local lapi_port config_file
    config_file="${VW_CROWDSEC_ETC_DIR:-/etc/crowdsec}/bouncers/crowdsec-cloudflare-worker-bouncer.yaml"
    if ! lapi_port="$(crowdsec_resolve_lapi_port)"; then
        CROWDSEC_READINESS_DETAIL="CrowdSec LAPI listen_uri is missing or invalid"
        return 1
    fi
    if [[ ! -r "$config_file" ]]; then
        CROWDSEC_READINESS_DETAIL="Workers bouncer config is missing or unreadable: $config_file"
        return 1
    fi
    if grep -Fq 'STUB_KEY' "$config_file" \
        || ! grep -Eq "^[[:space:]]*lapi_url:[[:space:]]*['\"]?http://127\\.0\\.0\\.1:${lapi_port}/?['\"]?[[:space:]]*$" "$config_file"; then
        CROWDSEC_READINESS_DETAIL="Workers bouncer config does not target the active local CrowdSec LAPI"
        return 1
    fi

    CROWDSEC_READINESS_DETAIL="active, registered, and configured for local LAPI port ${lapi_port}"
    return 0
}
