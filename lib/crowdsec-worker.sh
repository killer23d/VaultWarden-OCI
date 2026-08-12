#!/usr/bin/env bash
# lib/crowdsec-worker.sh - Narrow Cloudflare Workers bouncer config apply helper.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This library should be sourced, not executed directly" >&2
    exit 1
fi

[[ -n "${VW_CROWDSEC_WORKER_LIB_LOADED:-}" ]] && return 0
readonly VW_CROWDSEC_WORKER_LIB_LOADED=1

_CW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${VW_LOG_LIB_LOADED:-}" ]] || source "${_CW_LIB_DIR}/log.sh"
[[ -n "${VW_CONFIG_LIB_LOADED:-}" ]] || source "${_CW_LIB_DIR}/config.sh"
[[ -n "${VAULTWARDEN_COMMON_LIB_LOADED:-}" ]] || source "${_CW_LIB_DIR}/common.sh"
[[ -n "${VAULTWARDEN_STORAGE_LIB_LOADED:-}" ]] || source "${_CW_LIB_DIR}/storage.sh"
declare -F decrypt_secret >/dev/null 2>&1 || source "${_CW_LIB_DIR}/secrets.sh"
[[ -n "${VW_CROWDSEC_LIB_LOADED:-}" ]] || source "${_CW_LIB_DIR}/crowdsec.sh"
unset _CW_LIB_DIR

crowdsec_worker_service_exists() {
    [[ -f "/etc/systemd/system/crowdsec-cloudflare-worker-bouncer.service" ]] || \
    [[ -f "/lib/systemd/system/crowdsec-cloudflare-worker-bouncer.service" ]]
}

_crowdsec_worker_resolve_lapi_port() {
    crowdsec_resolve_lapi_port "${VW_CROWDSEC_ETC_DIR:-/etc/crowdsec}/config.yaml"
}

_crowdsec_worker_value_is_active() {
    local key="$1"
    local value="$2"
    if [[ -z "$value" || "$value" == PLACEHOLDER* || "$value" == CHANGE_ME* || "$value" == NOT_USED* || "$value" == "null" ]]; then
        log_error "${key} is not configured."
        log_error "Run: sudo ./edit-secrets.sh rotate ${key}"
        return 1
    fi
    return 0
}

crowdsec_worker_apply_config() {
    local require_service=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --require-service) require_service=true; shift ;;
            --allow-missing-service) require_service=false; shift ;;
            *)
                log_error "crowdsec_worker_apply_config: unknown option '$1'"
                return 2
                ;;
        esac
    done

    if declare -F is_root >/dev/null 2>&1; then
        if ! is_root; then
            log_error "crowdsec_worker_apply_config must be run as root."
            log_error "Retry: sudo ./utilities/crowdsec-worker-apply.sh"
            return 1
        fi
    elif [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        log_error "crowdsec_worker_apply_config must be run as root."
        log_error "Retry: sudo ./utilities/crowdsec-worker-apply.sh"
        return 1
    fi

    if ! declare -F load_project_environment >/dev/null 2>&1; then
        log_error "Canonical runtime environment loader is unavailable."
        return 1
    fi
    load_project_environment || return 1
    [[ -z "${DATA_VOLUME_DEVICE:-}" ]] || require_project_state_ready || return 1

    local project_root="${PROJECT_ROOT:-$(pwd)}"
    local src="${CROWDSEC_WORKER_CONFIG_SRC:-${project_root}/crowdsec/crowdsec-cloudflare-worker-bouncer.yaml.example}"
    local dest="${CROWDSEC_WORKER_CONFIG_DEST:-/etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml}"
    local dest_dir
    dest_dir="$(dirname "$dest")"

    if [[ "${CLOUDFLARE_PROXY_ENABLED:-false}" != "true" ]]; then
        log_warn "Skipping Cloudflare Workers bouncer config apply — CLOUDFLARE_PROXY_ENABLED is not 'true'."
        return 0
    fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY RUN] Would render and apply ${dest} from ${src}"
        return 0
    fi
    if [[ ! -f "$src" ]]; then
        log_error "Cloudflare Workers bouncer template not found: $src"
        return 1
    fi

    local cf_worker_bouncer_token cloudflare_zone_id cf_account_id
    cf_worker_bouncer_token=$(decrypt_secret "cf_worker_bouncer_token") || {
        log_error "Failed to read cf_worker_bouncer_token from secrets."
        log_error "Run: sudo ./edit-secrets.sh rotate cf_worker_bouncer_token"
        return 1
    }
    _crowdsec_worker_value_is_active "cf_worker_bouncer_token" "$cf_worker_bouncer_token" || return 1

    cloudflare_zone_id=$(decrypt_secret "cloudflare_zone_id") || {
        log_error "Failed to read cloudflare_zone_id from secrets."
        log_error "Run: sudo ./edit-secrets.sh rotate cloudflare_zone_id"
        return 1
    }
    _crowdsec_worker_value_is_active "cloudflare_zone_id" "$cloudflare_zone_id" || return 1

    cf_account_id=$(decrypt_secret "cf_account_id") || {
        log_error "Failed to read cf_account_id from secrets."
        log_error "Run: sudo ./edit-secrets.sh rotate cf_account_id"
        return 1
    }
    _crowdsec_worker_value_is_active "cf_account_id" "$cf_account_id" || return 1
    cleanup_secrets_environment

    local lapi_key="${CROWDSEC_CF_BOUNCER_API_KEY:-${_CF_BOUNCER_KEY:-}}"
    if [[ -z "$lapi_key" || "$lapi_key" == CHANGE_ME* || "$lapi_key" == PLACEHOLDER* ]]; then
        log_error "CROWDSEC_CF_BOUNCER_API_KEY is not configured in .env."
        log_error "Run: sudo ./utilities/setup-crowdsec.sh --force"
        return 1
    fi

    local domain_name="${DOMAIN_NAME:-}"
    if [[ -z "$domain_name" && -n "${DOMAIN:-}" ]]; then
        domain_name="${DOMAIN#https://}"
        domain_name="${domain_name#http://}"
        domain_name="${domain_name%%/*}"
        log_info "DOMAIN_NAME not set — derived from DOMAIN: ${domain_name}"
    fi
    if [[ -z "$domain_name" ]]; then
        log_error "Neither DOMAIN_NAME nor DOMAIN is set in .env — cannot derive routes_to_protect."
        log_error "Set DOMAIN_NAME=yourdomain.com in .env and retry: sudo ./utilities/crowdsec-worker-apply.sh"
        return 1
    fi

    local only_from_line
    if [[ "${CF_FREE_PLAN:-true}" == "true" ]]; then
        only_from_line='  only_include_decisions_from: ["cscli", "crowdsec"]'
        log_info "Free-plan KV guard enabled: restricting decisions to cscli + crowdsec engine."
        log_info "Set CF_FREE_PLAN=false in .env to disable this restriction."
    else
        only_from_line='  only_include_decisions_from: []'
    fi

    install -d -m 0750 -o root -g root "$dest_dir" || {
        log_error "Failed to create CrowdSec bouncer config directory: $dest_dir"
        return 1
    }

    local tmp_config
    tmp_config=$(mktemp "${dest}.tmp.XXXXXXXX") || {
        log_error "Failed to create protected temporary config near $dest"
        return 1
    }
    chmod 0600 "$tmp_config" || { rm -f "$tmp_config"; return 1; }
    chown root:root "$tmp_config" || { rm -f "$tmp_config"; return 1; }

    local lapi_port worker_route account_email bouncer_bin render_rc=0
    lapi_port="$(_crowdsec_worker_resolve_lapi_port)" || {
        rm -f "$tmp_config"
        log_error "CrowdSec LAPI listen_uri is missing or invalid; fix /etc/crowdsec/config.yaml before applying the Worker config."
        return 1
    }
    worker_route="${domain_name}/*"
    account_email="${CF_ACCOUNT_EMAIL:-CHANGE_ME_CF_ACCOUNT_EMAIL}"
    bouncer_bin="${_CF_WORKER_BOUNCER_BIN:-/usr/local/bin/crowdsec-cloudflare-worker-bouncer}"

    CF_WORKER_BOUNCER_TOKEN="$cf_worker_bouncer_token" \
    CLOUDFLARE_ZONE_ID_VALUE="$cloudflare_zone_id" \
    CF_ACCOUNT_ID_VALUE="$cf_account_id" \
    CROWDSEC_LAPI_KEY_VALUE="$lapi_key" \
    CF_ACCOUNT_NAME_VALUE="$account_email" \
    WORKER_ROUTE_VALUE="$worker_route" \
    ONLY_INCLUDE_DECISIONS_FROM_LINE="$only_from_line" \
    LAPI_PORT_VALUE="$lapi_port" \
        python3 - "$src" "$tmp_config" <<'PYEOF' || render_rc=$?
import os
import re
import sys

try:
    import yaml
except Exception as exc:
    print(f"PyYAML is required to validate rendered CrowdSec Workers config: {exc}", file=sys.stderr)
    sys.exit(1)

src, dest = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as handle:
    rendered = handle.read()

replacements = {
    "%%CLOUDFLARE_ZONE_ID%%": os.environ["CLOUDFLARE_ZONE_ID_VALUE"],
    "%%CF_ACCOUNT_ID%%": os.environ["CF_ACCOUNT_ID_VALUE"],
    "%%CF_WORKER_BOUNCER_TOKEN%%": os.environ["CF_WORKER_BOUNCER_TOKEN"],
    "%%CROWDSEC_LAPI_KEY%%": os.environ["CROWDSEC_LAPI_KEY_VALUE"],
    "%%CF_ACCOUNT_NAME%%": os.environ["CF_ACCOUNT_NAME_VALUE"],
    "%%WORKER_ROUTE%%": os.environ["WORKER_ROUTE_VALUE"],
}
for token, value in replacements.items():
    rendered = rendered.replace(token, value)

rendered = re.sub(
    r"(?m)^[ \t]*only_include_decisions_from:.*$",
    os.environ["ONLY_INCLUDE_DECISIONS_FROM_LINE"],
    rendered,
)
rendered = re.sub(
    r"lapi_url: http://127\.0\.0\.1:[0-9]*/",
    f"lapi_url: http://127.0.0.1:{os.environ['LAPI_PORT_VALUE']}/",
    rendered,
)

unresolved = sorted(set(re.findall(r"%%[^%]+%%", rendered)))
if unresolved:
    print("unresolved template variables: " + ", ".join(unresolved), file=sys.stderr)
    sys.exit(1)

try:
    yaml.safe_load(rendered)
except yaml.YAMLError as exc:
    print(f"rendered YAML is invalid: {exc}", file=sys.stderr)
    sys.exit(1)

with open(dest, "w", encoding="utf-8") as handle:
    handle.write(rendered)
PYEOF

    if [[ "$render_rc" -ne 0 ]]; then
        rm -f "$tmp_config"
        log_error "Failed to render or validate CrowdSec Workers bouncer config."
        return 1
    fi

    chmod 0600 "$tmp_config" || { rm -f "$tmp_config"; return 1; }
    chown root:root "$tmp_config" || { rm -f "$tmp_config"; return 1; }
    if ! mv -f "$tmp_config" "$dest"; then
        rm -f "$tmp_config"
        log_error "Failed to promote CrowdSec Workers bouncer config to $dest"
        return 1
    fi
    chmod 0600 "$dest" || return 1
    chown root:root "$dest" || return 1
    log_success "Cloudflare Workers bouncer config written to ${dest} (root:root 0600)."
    log_info "NOTE: The -g auto-config flag is not used — it fails on multi-zone accounts."
    log_info "Config is fully built from secrets.yaml values (zone_id, account_id, token)."

    if [[ "${AUTONOMOUS_MODE:-${CF_AUTONOMOUS_MODE:-false}}" == "true" ]]; then
        if [[ ! -x "$bouncer_bin" ]]; then
            log_error "Autonomous mode requested, but bouncer binary is not executable: $bouncer_bin"
            return 1
        fi
        log_info "Deploying Workers + KV to Cloudflare in autonomous mode (-S)..."
        if "$bouncer_bin" -S -c "$dest"; then
            log_success "Autonomous mode deployment complete."
            log_info "Worker route fail mode: manually set to 'Fail Open' in the Cloudflare dashboard"
            return 0
        fi
        log_error "Autonomous mode deployment failed."
        return 1
    fi

    if crowdsec_worker_service_exists; then
        systemctl enable crowdsec-cloudflare-worker-bouncer >/dev/null 2>&1 || true
        systemctl reset-failed crowdsec-cloudflare-worker-bouncer 2>/dev/null || true
        if ! systemctl restart crowdsec-cloudflare-worker-bouncer; then
            log_error "Failed to restart crowdsec-cloudflare-worker-bouncer."
            log_error "Retry: sudo ./utilities/crowdsec-worker-apply.sh"
            return 1
        fi

        local _
        for _ in {1..10}; do
            if systemctl is-active --quiet crowdsec-cloudflare-worker-bouncer; then
                log_success "crowdsec-cloudflare-worker-bouncer is active."
                return 0
            fi
            sleep 1
        done
        log_error "crowdsec-cloudflare-worker-bouncer did not report active after restart."
        log_error "Retry: sudo ./utilities/crowdsec-worker-apply.sh"
        return 1
    fi

    if [[ "$require_service" == "true" ]]; then
        log_error "crowdsec-cloudflare-worker-bouncer.service unit not found."
        log_error "Retry setup before applying rotated credentials: sudo ./utilities/setup-crowdsec.sh --force"
        return 1
    fi

    log_warn "crowdsec-cloudflare-worker-bouncer.service unit not found; config rendered but service restart skipped."
    log_warn "Once the binary is installed, run: sudo systemctl enable --now crowdsec-cloudflare-worker-bouncer"
    return 0
}
