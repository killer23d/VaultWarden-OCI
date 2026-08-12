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

_crowdsec_bouncer_inspect_json() {
    if cscli bouncers inspect cloudflare-worker-bouncer -o json 2>/dev/null; then
        return 0
    fi
    if [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
        sudo -n cscli bouncers inspect cloudflare-worker-bouncer -o json 2>/dev/null
        return $?
    fi
    return 1
}

_crowdsec_bouncer_state() {
    local inspect_json
    command -v python3 >/dev/null 2>&1 || {
        printf 'parser-unavailable\n'
        return 0
    }
    if ! inspect_json="$(_crowdsec_bouncer_inspect_json)"; then
        printf 'inspect-failed\n'
        return 0
    fi

    BOUNCER_JSON="$inspect_json" python3 - <<'PY'
import datetime
import json
import os
import re

try:
    data = json.loads(os.environ["BOUNCER_JSON"])
except (KeyError, json.JSONDecodeError):
    print("malformed")
    raise SystemExit(0)

if data.get("name") != "cloudflare-worker-bouncer":
    print("wrong-name")
    raise SystemExit(0)
if data.get("revoked") is not False:
    print("revoked")
    raise SystemExit(0)

last_pull = data.get("last_pull")
if not isinstance(last_pull, str) or not last_pull:
    print("never-pulled")
    raise SystemExit(0)

normalized = re.sub(r"(\.\d{6})\d+(?=(?:Z|[+-]\d\d:\d\d)$)", r"\1", last_pull)
if normalized.endswith("Z"):
    normalized = normalized[:-1] + "+00:00"
try:
    pulled_at = datetime.datetime.fromisoformat(normalized)
except ValueError:
    print("malformed-pull")
    raise SystemExit(0)
if pulled_at.tzinfo is None:
    print("malformed-pull")
    raise SystemExit(0)

age = int((datetime.datetime.now(datetime.timezone.utc) - pulled_at).total_seconds())
if age < -60:
    print(f"future\t{age}\t{last_pull}")
elif age > 120:
    print(f"stale\t{age}\t{last_pull}")
else:
    print(f"ok\t{max(age, 0)}\t{last_pull}")
PY
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

    local bouncer_state state pull_age last_pull
    bouncer_state="$(_crowdsec_bouncer_state)"
    IFS=$'\t' read -r state pull_age last_pull <<< "$bouncer_state"
    case "$state" in
        ok)
            ;;
        inspect-failed|wrong-name)
            CROWDSEC_READINESS_DETAIL="cloudflare-worker-bouncer is not registered in CrowdSec LAPI or cannot be inspected"
            return 1
            ;;
        revoked)
            CROWDSEC_READINESS_DETAIL="cloudflare-worker-bouncer registration is revoked/invalid"
            return 1
            ;;
        never-pulled)
            CROWDSEC_READINESS_DETAIL="cloudflare-worker-bouncer has not completed a successful CrowdSec LAPI pull"
            return 1
            ;;
        stale)
            CROWDSEC_READINESS_DETAIL="cloudflare-worker-bouncer last CrowdSec LAPI pull is stale (${pull_age}s old; last pull: ${last_pull})"
            return 1
            ;;
        future)
            CROWDSEC_READINESS_DETAIL="cloudflare-worker-bouncer Last API Pull is in the future; check host clock (${last_pull})"
            return 1
            ;;
        parser-unavailable)
            CROWDSEC_READINESS_DETAIL="python3 is unavailable to validate structured CrowdSec bouncer state"
            return 1
            ;;
        *)
            CROWDSEC_READINESS_DETAIL="CrowdSec returned malformed structured state for cloudflare-worker-bouncer"
            return 1
            ;;
    esac

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

    CROWDSEC_READINESS_DETAIL="active, valid, pulled from LAPI ${pull_age}s ago, and configured for local LAPI port ${lapi_port}"
    return 0
}

crowdsec_worker_wait_ready() {
    local timeout="${1:-30}" elapsed=0 readiness_rc=1 last_detail=""
    [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || {
        CROWDSEC_READINESS_DETAIL="invalid CrowdSec readiness timeout: ${timeout}"
        return 1
    }

    while (( elapsed <= timeout )); do
        readiness_rc=0
        crowdsec_worker_readiness || readiness_rc=$?
        case "$readiness_rc" in
            0|10) return "$readiness_rc" ;;
        esac
        last_detail="$CROWDSEC_READINESS_DETAIL"
        (( elapsed >= timeout )) && break
        sleep 1
        (( elapsed++ )) || true
    done

    CROWDSEC_READINESS_DETAIL="${last_detail}; timed out after ${timeout}s waiting for a valid recent LAPI pull"
    return 1
}
