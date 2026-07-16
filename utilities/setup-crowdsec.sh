#!/usr/bin/env bash
# utilities/setup-crowdsec.sh — Installs and configures CrowdSec and the
# Cloudflare *Workers* bouncer (crowdsec-cloudflare-worker-bouncer) for
# VaultWarden-OCI.
#
# Free-plan note:
#   KV writes are capped at 1 K/day on the Cloudflare free plan, so the
#   initial blocklist population is truncated.  Subsequent incremental syncs
#   continue normally.  This script automatically restricts decisions to
#   locally generated ones (cscli + crowdsec engine) so the KV budget is not
#   wasted on community blocklist churn.  Set CF_FREE_PLAN=false in .env to
#   disable this guard.
#
# Usage:
#   sudo ./utilities/setup-crowdsec.sh [OPTIONS]
#
# See --help for all options.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_cf_worker_bouncer_release_arch() {
    local arch="$1"
    case "$arch" in
        amd64|x86_64)
            printf '%s\n' "amd64"
            ;;
        arm64|aarch64)
            printf '%s\n' "arm64"
            ;;
        *)
            return 1
            ;;
    esac
}

if [[ "${VAULTWARDEN_TEST_ARCH_HELPERS:-}" == "1" ]]; then
    _cf_worker_bouncer_release_arch "${1:-}"
    exit $?
fi

if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
    printf 'VaultWarden-OCI %s\n' "$(tr -d '[:space:]' < "${PROJECT_ROOT}/VERSION" 2>/dev/null || echo unknown)"
    exit 0
fi

if [[ "${1:-}" != "--help" && "${1:-}" != "-h" && "${1:-}" != "help" && "${EUID}" -ne 0 ]]; then
    echo "ERROR: setup-crowdsec requires root. Run: sudo ./utilities/setup-crowdsec.sh $*" >&2
    exit 1
fi

cd "${PROJECT_ROOT}"

# ---------------------------------------------------------------------------
# Library loading
# ---------------------------------------------------------------------------
_LIBS_LOADED=false
for _lib in log.sh config.sh common.sh operations.sh storage.sh secrets.sh crowdsec-worker.sh; do
    _lib_path="${PROJECT_ROOT}/lib/${_lib}"
    if [[ -f "$_lib_path" ]]; then
        # shellcheck disable=SC1090
        source "$_lib_path"
        [[ "$_lib" == "common.sh" ]] && _LIBS_LOADED=true
    fi
done
unset _lib _lib_path

if [[ "$_LIBS_LOADED" == "true" ]]; then
    set_log_prefix "crowdsec"
else
    log_info()    { printf '[INFO]    crowdsec %s\n'    "$*"; }
    log_success() { printf '[SUCCESS] crowdsec %s\n'    "$*"; }
    log_warn()    { printf '[WARN]    crowdsec %s\n'    "$*" >&2; }
    log_error()   { printf '[ERROR]   crowdsec %s\n'    "$*" >&2; }
fi

# Provide COLOR_* fallbacks for standalone runs without lib/common.sh.
if [[ "$_LIBS_LOADED" != "true" ]]; then
    COLOR_RED=''
    COLOR_RESET=''
fi

# ---------------------------------------------------------------------------
# Load .env
# ---------------------------------------------------------------------------
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
    if declare -f load_env_file >/dev/null 2>&1; then
        load_env_file "${PROJECT_ROOT}/.env" || true
    else
        # shellcheck disable=SC1091
        source "${PROJECT_ROOT}/.env" 2>/dev/null || true
    fi
fi

if declare -f resolve_secrets_file >/dev/null 2>&1; then
    resolve_secrets_file
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Preserve the setup-specific missing-.env contract while using the canonical
# atomic writer for an existing repository environment.
_cs_set_env_var() {
    local key="$1" value="$2"
    local env_file="${PROJECT_ROOT}/.env"
    [[ -f "$env_file" ]] || return 0
    if ! declare -F _set_env_var >/dev/null 2>&1; then
        log_error "Required configuration helper is unavailable: _set_env_var (lib/config.sh)"
        return 1
    fi
    _set_env_var "$key" "$value" "$env_file"
}

# Remove a KEY= line from .env using an atomic temp-file + mv.
# Used by _cs_reset_components to clear auto-generated keys before a --force run.
_cs_clear_env_var() {
    local key="$1"
    local env_file="${PROJECT_ROOT}/.env"
    [[ -f "$env_file" ]] || return 0
    local tmp_file
    tmp_file="$(dirname "$env_file")/.env.tmp.$$"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_file'" RETURN
    sed "/^${key}=/d" "$env_file" > "$tmp_file"
    chmod --reference="$env_file" "$tmp_file" 2>/dev/null || true
    mv "$tmp_file" "$env_file"
}


# ---------------------------------------------------------------------------
# Installed LAPI-port cohort transaction helpers.
# ---------------------------------------------------------------------------
_CS_LAPI_COHORT_ROOT="${VW_CROWDSEC_ETC_DIR:-/etc/crowdsec}"
_CS_LAPI_COHORT_PATHS=(
    "${_CS_LAPI_COHORT_ROOT}/config.yaml"
    "${_CS_LAPI_COHORT_ROOT}/local_api_credentials.yaml"
    "${_CS_LAPI_COHORT_ROOT}/bouncers/crowdsec-firewall-bouncer.yaml"
    "${_CS_LAPI_COHORT_ROOT}/bouncers/crowdsec-cloudflare-worker-bouncer.yaml"
)
_CS_LAPI_COHORT_COMMITTED=true
_CS_LAPI_COHORT_ROLLBACK_DONE=false
_CS_LAPI_COHORT_ORIGINAL_PORT=""
_CS_LAPI_COHORT_ORIGINALLY_COHERENT=false
_CS_LAPI_COHORT_TMPDIR=""
_CS_LAPI_COHORT_PREPARED_DESTS=()
_CS_LAPI_COHORT_STAGED=()
_CS_LAPI_COHORT_PREPARED_BACKUPS=()
_CS_LAPI_COHORT_PREPARED_MODES=()
_CS_LAPI_COHORT_PREPARED_UIDS=()
_CS_LAPI_COHORT_PREPARED_GIDS=()
_CS_LAPI_COHORT_PROMOTED=()
_CS_LAPI_COHORT_BACKUPS=()
_CS_LAPI_COHORT_MODES=()
_CS_LAPI_COHORT_UIDS=()
_CS_LAPI_COHORT_GIDS=()

_cs_resolve_lapi_port() {
    grep -oP '(?<=listen_uri:\s{0,10}127\.0\.0\.1:)\d+' \
        "${_CS_LAPI_COHORT_ROOT}/config.yaml" 2>/dev/null \
        | head -1 \
        || echo "8090"
}

# ---------------------------------------------------------------------------
# Find the lowest unused TCP port >= base_port on 127.0.0.1.
# Prints the free port number.
# ---------------------------------------------------------------------------
_cs_find_free_port() {
    local base_port="${1:-8090}"
    local port="$base_port"
    while ss -tlnp 2>/dev/null | grep -q ":${port}[[:space:]]"; do
        (( port++ ))
        if (( port > 65000 )); then
            echo "8090"   # safety fallback — should never happen
            return
        fi
    done
    echo "$port"
}

_cs_lapi_member_port() {
    local file="$1" member_path="${2:-$1}" field_pattern=""
    case "$member_path" in
        */config.yaml) field_pattern='listen_uri' ;;
        */local_api_credentials.yaml) field_pattern='url' ;;
        */crowdsec-firewall-bouncer.yaml) field_pattern='api_url' ;;
        */crowdsec-cloudflare-worker-bouncer.yaml)
            if grep -Eq '^[[:space:]]*lapi_url:' "$file"; then
                field_pattern='lapi_url'
            else
                field_pattern='api_url'
            fi
            ;;
        *) return 1 ;;
    esac
    local -a matches=()
    mapfile -t matches < <(
        grep -E "^[[:space:]]*${field_pattern}:[[:space:]]*['\"]?http://127\\.0\\.0\\.1:[0-9]+/?['\"]?[[:space:]]*$|^[[:space:]]*${field_pattern}:[[:space:]]*127\\.0\\.0\\.1:[0-9]+[[:space:]]*$" "$file" 2>/dev/null
    )
    (( ${#matches[@]} == 1 )) || return 1
    sed -E 's#.*127\.0\.0\.1:([0-9]+).*#\1#' <<< "${matches[0]}"
}

_cs_validate_lapi_port_cohort() {
    local selected_port="$1" file member_port found=false
    [[ "$selected_port" =~ ^[0-9]+$ ]] && (( selected_port >= 1 && selected_port <= 65535 )) || return 1
    for file in "${_CS_LAPI_COHORT_PATHS[@]}"; do
        [[ -f "$file" ]] || continue
        found=true
        member_port="$(_cs_lapi_member_port "$file")" || return 1
        [[ "$member_port" == "$selected_port" ]] || return 1
    done
    [[ "$found" == "true" ]]
}

_cs_stage_lapi_member() {
    local source_file="$1" staged_file="$2" selected_port="$3"
    cp -p "$source_file" "$staged_file" || return 1
    case "$source_file" in
        */config.yaml)
            sed -E -i "s#^([[:space:]]*listen_uri:[[:space:]]*127\\.0\\.0\\.1:)[0-9]+#\\1${selected_port}#" "$staged_file"
            ;;
        */local_api_credentials.yaml)
            sed -E -i "s#^([[:space:]]*url:[[:space:]]*['\"]?http://127\\.0\\.0\\.1:)[0-9]+#\\1${selected_port}#" "$staged_file"
            ;;
        */crowdsec-firewall-bouncer.yaml)
            sed -E -i "s#^([[:space:]]*api_url:[[:space:]]*['\"]?http://127\\.0\\.0\\.1:)[0-9]+#\\1${selected_port}#" "$staged_file"
            ;;
        */crowdsec-cloudflare-worker-bouncer.yaml)
            sed -E -i \
                -e "s#^([[:space:]]*lapi_url:[[:space:]]*['\"]?http://127\\.0\\.0\\.1:)[0-9]+#\\1${selected_port}#" \
                -e "s#^([[:space:]]*api_url:[[:space:]]*['\"]?http://127\\.0\\.0\\.1:)[0-9]+#\\1${selected_port}#" \
                "$staged_file"
            ;;
        *) return 1 ;;
    esac
    [[ "$(_cs_lapi_member_port "$staged_file" "$source_file")" == "$selected_port" ]]
}

_cs_lapi_cohort_cleanup() {
    [[ -n "${_CS_LAPI_COHORT_TMPDIR:-}" ]] && rm -rf "$_CS_LAPI_COHORT_TMPDIR"
    _CS_LAPI_COHORT_TMPDIR=""
}

_cs_lapi_cohort_rollback() {
    [[ "$_CS_LAPI_COHORT_COMMITTED" == "true" ]] && return 0
    [[ "$_CS_LAPI_COHORT_ROLLBACK_DONE" == "true" ]] && return 0
    _CS_LAPI_COHORT_ROLLBACK_DONE=true
    local failed=false i dest backup mode uid gid
    for (( i=${#_CS_LAPI_COHORT_PROMOTED[@]} - 1; i >= 0; i-- )); do
        dest="${_CS_LAPI_COHORT_PROMOTED[$i]}"
        backup="${_CS_LAPI_COHORT_BACKUPS[$i]}"
        mode="${_CS_LAPI_COHORT_MODES[$i]}"
        uid="${_CS_LAPI_COHORT_UIDS[$i]}"
        gid="${_CS_LAPI_COHORT_GIDS[$i]}"
        if ! install -m "$mode" -o "$uid" -g "$gid" "$backup" "$dest"; then
            log_error "Failed to restore CrowdSec LAPI cohort member: $dest"
            failed=true
        elif ! cmp -s "$backup" "$dest"; then
            log_error "Restored CrowdSec LAPI cohort member did not match its protected backup: $dest"
            failed=true
        fi
    done
    if [[ "$failed" == "false" && "$_CS_LAPI_COHORT_ORIGINALLY_COHERENT" == "true" ]]; then
        if ! _cs_validate_lapi_port_cohort "$_CS_LAPI_COHORT_ORIGINAL_PORT"; then
            log_error "Restored CrowdSec LAPI port cohort is not coherent on its previous port."
            failed=true
        fi
    fi
    [[ "$failed" == "false" ]] && log_warn "Restored the previous CrowdSec LAPI port cohort."
    [[ "$failed" == "false" ]]
}

_cs_lapi_cohort_fail() {
    local rc="${1:-1}" rollback_rc=0
    _cs_lapi_cohort_rollback || rollback_rc=$?
    _cs_lapi_cohort_cleanup
    (( rollback_rc == 0 )) || log_error "CrowdSec LAPI cohort rollback was incomplete."
    return "$rc"
}

_cs_reconcile_lapi_port_cohort() {
    local selected_port="$1" file staged backup mode uid gid prepared_count=0 promoted_count=0 i
    if [[ ! "$selected_port" =~ ^[0-9]+$ ]]         || (( selected_port < 1 || selected_port > 65535 )); then
        log_error "Invalid selected CrowdSec LAPI port: $selected_port"
        return 1
    fi

    _CS_LAPI_COHORT_COMMITTED=false
    _CS_LAPI_COHORT_ROLLBACK_DONE=false
    _CS_LAPI_COHORT_ORIGINAL_PORT="$(_cs_resolve_lapi_port)"
    _CS_LAPI_COHORT_ORIGINALLY_COHERENT=false
    _cs_validate_lapi_port_cohort "$_CS_LAPI_COHORT_ORIGINAL_PORT" \
        && _CS_LAPI_COHORT_ORIGINALLY_COHERENT=true
    _CS_LAPI_COHORT_PREPARED_DESTS=()
    _CS_LAPI_COHORT_STAGED=()
    _CS_LAPI_COHORT_PREPARED_BACKUPS=()
    _CS_LAPI_COHORT_PREPARED_MODES=()
    _CS_LAPI_COHORT_PREPARED_UIDS=()
    _CS_LAPI_COHORT_PREPARED_GIDS=()
    _CS_LAPI_COHORT_PROMOTED=()
    _CS_LAPI_COHORT_BACKUPS=()
    _CS_LAPI_COHORT_MODES=()
    _CS_LAPI_COHORT_UIDS=()
    _CS_LAPI_COHORT_GIDS=()
    _CS_LAPI_COHORT_TMPDIR="$(mktemp -d -p /dev/shm vw-crowdsec-lapi.XXXXXXXX 2>/dev/null \
        || mktemp -d -t vw-crowdsec-lapi.XXXXXXXX)" || return 1
    chmod 0700 "$_CS_LAPI_COHORT_TMPDIR" || { _cs_lapi_cohort_cleanup; return 1; }

    for file in "${_CS_LAPI_COHORT_PATHS[@]}"; do
        [[ -f "$file" ]] || continue
        staged="${_CS_LAPI_COHORT_TMPDIR}/staged.${prepared_count}"
        backup="${_CS_LAPI_COHORT_TMPDIR}/backup.${prepared_count}"
        cp -p "$file" "$backup" || { _cs_lapi_cohort_fail 1; return 1; }
        chmod 0600 "$backup" || { _cs_lapi_cohort_fail 1; return 1; }
        _cs_stage_lapi_member "$file" "$staged" "$selected_port" \
            || { log_error "Failed to stage/validate CrowdSec LAPI cohort member: $file"; _cs_lapi_cohort_fail 1; return 1; }
        mode="$(stat -c '%a' "$file")" || { _cs_lapi_cohort_fail 1; return 1; }
        uid="$(stat -c '%u' "$file")" || { _cs_lapi_cohort_fail 1; return 1; }
        gid="$(stat -c '%g' "$file")" || { _cs_lapi_cohort_fail 1; return 1; }
        _CS_LAPI_COHORT_PREPARED_DESTS+=("$file")
        _CS_LAPI_COHORT_STAGED+=("$staged")
        _CS_LAPI_COHORT_PREPARED_BACKUPS+=("$backup")
        _CS_LAPI_COHORT_PREPARED_MODES+=("$mode")
        _CS_LAPI_COHORT_PREPARED_UIDS+=("$uid")
        _CS_LAPI_COHORT_PREPARED_GIDS+=("$gid")
        (( prepared_count++ )) || true
    done

    for (( i=0; i<prepared_count; i++ )); do
        file="${_CS_LAPI_COHORT_PREPARED_DESTS[$i]}"
        staged="${_CS_LAPI_COHORT_STAGED[$i]}"
        backup="${_CS_LAPI_COHORT_PREPARED_BACKUPS[$i]}"
        mode="${_CS_LAPI_COHORT_PREPARED_MODES[$i]}"
        uid="${_CS_LAPI_COHORT_PREPARED_UIDS[$i]}"
        gid="${_CS_LAPI_COHORT_PREPARED_GIDS[$i]}"
        _CS_LAPI_COHORT_PROMOTED+=("$file")
        _CS_LAPI_COHORT_BACKUPS+=("$backup")
        _CS_LAPI_COHORT_MODES+=("$mode")
        _CS_LAPI_COHORT_UIDS+=("$uid")
        _CS_LAPI_COHORT_GIDS+=("$gid")
        install -m "$mode" -o "$uid" -g "$gid" "$staged" "$file" \
            || { _cs_lapi_cohort_fail 1; return 1; }
        (( promoted_count++ )) || true
        if [[ "${VW_TEST_CROWDSEC_SIGNAL_AFTER_PORT_PROMOTION:-}" == "$promoted_count" ]]; then
            kill -TERM "$BASHPID"
        fi
    done

    if ! _cs_validate_lapi_port_cohort "$selected_port"; then
        log_error "Promoted CrowdSec LAPI cohort does not agree on port ${selected_port}."
        _cs_lapi_cohort_fail 1
        return 1
    fi
    _CS_LAPI_COHORT_COMMITTED=true
    _cs_lapi_cohort_cleanup
    log_success "Existing CrowdSec LAPI port cohort converged on ${selected_port}."
}

_cs_ensure_lapi_port_cohort() {
    local selected_port="$1"
    if _cs_validate_lapi_port_cohort "$selected_port"; then
        return 0
    fi
    log_warn "Detected a mixed or invalid CrowdSec LAPI port cohort; reconciling on ${selected_port}."
    _cs_reconcile_lapi_port_cohort "$selected_port"
}

_cs_fix_port_conflict() {
    local old_port="$1" new_port="$2"
    log_info "Auto-fixing LAPI port conflict: ${old_port} -> ${new_port}"
    _cs_reconcile_lapi_port_cohort "$new_port" || return 1
    log_success "LAPI port rewritten to ${new_port} across the existing config cohort."
}

# ---------------------------------------------------------------------------
# Port-conflict diagnostic helper
# ---------------------------------------------------------------------------
_cs_diagnose_port() {
    local port="$1"
    local info=""

    if command -v ss >/dev/null 2>&1; then
        info="$(ss -tlnp "sport = :${port}" 2>/dev/null | grep -v '^Netid' || true)"
    fi

    if [[ -z "$info" ]] && command -v lsof >/dev/null 2>&1; then
        info="$(lsof -i :"${port}" -sTCP:LISTEN -n -P 2>/dev/null || true)"
    fi

    if [[ -n "$info" ]]; then
        log_error "Port ${port} is held by:"
        while IFS= read -r line; do
            log_error "  ${line}"
        done <<< "$info"
    else
        log_error "Could not identify what holds port ${port} — run: sudo ss -tlnp | grep ${port}"
    fi
}

# ---------------------------------------------------------------------------
# Attempt to start CrowdSec, with automatic port-conflict resolution.
# ---------------------------------------------------------------------------
_cs_start_service() {
    systemctl reset-failed crowdsec 2>/dev/null || true

    local _lapi_port
    _lapi_port="$(_cs_resolve_lapi_port)"

    if ss -tlnp 2>/dev/null | grep -q ":${_lapi_port}[[:space:]]"; then
        log_warn "Pre-flight: port ${_lapi_port} is already in use before CrowdSec start."
        _cs_diagnose_port "${_lapi_port}"
        local _new_port
        _new_port="$(_cs_find_free_port 8090)"
        _cs_fix_port_conflict "${_lapi_port}" "${_new_port}" || return 1
        _lapi_port="$_new_port"
        log_info "Pre-flight port reassignment complete: LAPI will use ${_lapi_port}."
    fi
    # --- END PRE-FLIGHT -------------------------------------------------------

    if systemctl enable --now crowdsec 2>/dev/null; then
        local _i
        for _i in {1..5}; do
            if systemctl is-active --quiet crowdsec; then
                return 0
            fi
            sleep 1
        done
    fi

    if ss -tlnp 2>/dev/null | grep -q ":${_lapi_port}[[:space:]]"; then
        log_warn "Post-start: port ${_lapi_port} is occupied — attempting reassignment."
        _cs_diagnose_port "${_lapi_port}"

        local _new_port
        _new_port="$(_cs_find_free_port 8090)"
        _cs_fix_port_conflict "${_lapi_port}" "${_new_port}" || return 1

        systemctl reset-failed crowdsec 2>/dev/null || true
        if systemctl enable --now crowdsec 2>/dev/null; then
            local _j
            for _j in {1..8}; do
                if systemctl is-active --quiet crowdsec; then
                    log_success "CrowdSec started successfully on port ${_new_port}."
                    return 0
                fi
                sleep 1
            done
        fi

        log_error "CrowdSec service failed to start even after port reassignment to ${_new_port}."
    else
        log_error "CrowdSec service failed to start (no port conflict detected — check journalctl)."
    fi

    log_error "systemctl status crowdsec:"
    systemctl status crowdsec --no-pager -l 2>&1 | head -30 | while IFS= read -r _l; do
        log_error "  ${_l}"
    done
    log_error "Full journal: sudo journalctl -xeu crowdsec --no-pager | tail -50"
    return 1
}

# ---------------------------------------------------------------------------
# Reset all CrowdSec components installed by a previous run.
# ---------------------------------------------------------------------------
_cs_reset_components() {
    operation_set_phase "0" "Resetting installed CrowdSec components" 2>/dev/null || true
    log_info "=== PHASE 0: Resetting installed CrowdSec components (--force) ==="

    # If the CF bouncer package is in a broken dpkg half-configured state,
    # purge it now so apt doesn't abort on the next install attempt.
    if dpkg -l crowdsec-cloudflare-worker-bouncer 2>/dev/null | grep -qE '^(iF|iU|hF)'; then
        log_info "Detected broken dpkg state for crowdsec-cloudflare-worker-bouncer — purging."
        operation_package_run env DEBIAN_FRONTEND=noninteractive dpkg --purge --force-remove-reinstreq \
            crowdsec-cloudflare-worker-bouncer || true
        log_info "Purge complete — package will be re-installed cleanly."
    fi

    if command -v cscli >/dev/null 2>&1; then
        cscli bouncers delete cloudflare-worker-bouncer 2>/dev/null || true
        cscli bouncers delete firewall-bouncer          2>/dev/null || true
        log_info "Cleared existing LAPI bouncer registrations (best-effort)."
    fi

    local _svc
    for _svc in crowdsec-cloudflare-worker-bouncer crowdsec-firewall-bouncer crowdsec; do
        if systemctl is-active  --quiet "$_svc" 2>/dev/null || \
           systemctl is-enabled --quiet "$_svc" 2>/dev/null; then
            systemctl disable --now "$_svc" 2>/dev/null || true
            log_info "Stopped and disabled: ${_svc}"
        fi
    done

    rm -f /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml 2>/dev/null || true
    rm -f /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml           2>/dev/null || true
    log_info "Removed bouncer config files — Phase 1b will generate fresh API keys."

    _cs_clear_env_var "CROWDSEC_CF_BOUNCER_API_KEY"
    log_info "Cleared auto-generated LAPI key from .env (will be regenerated in Phase 5)."

    log_success "Phase 0 complete — all components reset for fresh installation."
}

_cs_ensure_fw_bouncer_key() {
    local _cfg="$1"

    if [[ "$FORCE" == "true" ]]; then
        log_info "Force mode: regenerating firewall bouncer API key..."
        local _fresh_key
        _fresh_key="$(openssl rand -hex 32)"
        cscli bouncers delete crowdsecurity/firewall-bouncer 2>/dev/null || true
        if ! cscli bouncers add crowdsecurity/firewall-bouncer --key "$_fresh_key" >/dev/null 2>&1; then
            log_error "Failed to register the regenerated firewall bouncer key in CrowdSec LAPI."
            return 1
        fi
        sed -i "s|^api_key:.*|api_key: ${_fresh_key}|" "$_cfg"
        _CS_FW_BOUNCER_KEY_GENERATED="$_fresh_key"
        log_success "Firewall bouncer key regenerated and written to config."
        return 0
    fi

    if ! cscli bouncers list 2>/dev/null | grep -q 'firewall-bouncer'; then
        local _existing_key
        _existing_key="$(grep 'api_key:' "$_cfg" 2>/dev/null | awk '{print $2}' | head -1 || true)"
        if [[ -n "$_existing_key" && "$_existing_key" != "CHANGE_ME"* ]]; then
            log_info "Firewall bouncer not found in LAPI — re-registering with existing config key..."
            if ! cscli bouncers add crowdsecurity/firewall-bouncer --key "$_existing_key" >/dev/null 2>&1; then
                log_warn "Existing key rejected by LAPI (likely revoked) — generating a fresh key..."
                _existing_key="$(openssl rand -hex 32)"
                cscli bouncers delete crowdsecurity/firewall-bouncer 2>/dev/null || true
                if ! cscli bouncers add crowdsecurity/firewall-bouncer --key "$_existing_key" >/dev/null 2>&1; then
                    log_error "Failed to register a fresh firewall bouncer key in CrowdSec LAPI."
                    return 1
                fi
                sed -i "s|^api_key:.*|api_key: ${_existing_key}|" "$_cfg"
                _CS_FW_BOUNCER_KEY_GENERATED="$_existing_key"
                log_success "Fresh firewall bouncer key generated and written to config."
            else
                log_success "Firewall bouncer re-registered in LAPI."
            fi
        else
            log_warn "Firewall bouncer not in LAPI and config key is missing/placeholder — generating fresh key."
            local _new_key
            _new_key="$(openssl rand -hex 32)"
            cscli bouncers delete crowdsecurity/firewall-bouncer 2>/dev/null || true
            if ! cscli bouncers add crowdsecurity/firewall-bouncer --key "$_new_key" >/dev/null 2>&1; then
                log_error "Failed to register a fresh firewall bouncer key in CrowdSec LAPI."
                return 1
            fi
            sed -i "s|^api_key:.*|api_key: ${_new_key}|" "$_cfg"
            _CS_FW_BOUNCER_KEY_GENERATED="$_new_key"
            log_success "Fresh firewall bouncer key generated and written to config."
        fi
    fi
}

# ---------------------------------------------------------------------------
# Optional CrowdSec email notification transaction.
#
# Only the marked plugin file and marked profiles.yaml.local block are owned by
# this project. Operator metadata on profiles.yaml.local is retained; the
# project-owned plugin file is normalized to root:root 0640, matching the setup
# script's generated /etc/crowdsec configuration convention.
# ---------------------------------------------------------------------------
_CS_EMAIL_PLUGIN_MARKER="# Managed by VaultWarden-OCI: CrowdSec email notification"
_CS_EMAIL_PROFILE_BEGIN="# BEGIN VaultWarden-OCI CrowdSec email notifications"
_CS_EMAIL_PROFILE_END="# END VaultWarden-OCI CrowdSec email notifications"
_CS_EMAIL_ENV_FILE="${VW_CROWDSEC_EMAIL_ENV_FILE:-${PROJECT_ROOT}/.env}"

_cs_email_paths() {
    _CS_EMAIL_PLUGIN_PATH="${_CS_LAPI_COHORT_ROOT}/notifications/vaultwarden-email.yaml"
    _CS_EMAIL_PROFILES_PATH="${_CS_LAPI_COHORT_ROOT}/profiles.yaml.local"
}

_cs_email_read_env_setting() {
    local key="$1" default_value="$2" result_var="$3"
    local exact_count related_count raw value

    [[ -f "$_CS_EMAIL_ENV_FILE" && -r "$_CS_EMAIL_ENV_FILE" ]] || {
        log_error "CrowdSec email configuration is missing or unreadable: $_CS_EMAIL_ENV_FILE"
        return 1
    }

    read -r exact_count related_count < <(
        awk -v key="$key" '
            /^[[:space:]]*#/ { next }
            {
                trimmed=$0
                sub(/^[[:space:]]*/, "", trimmed)
                if (trimmed ~ ("^" key "[[:space:]]*=")) related++
                if ($0 ~ ("^" key "=")) exact++
            }
            END { print exact + 0, related + 0 }
        ' "$_CS_EMAIL_ENV_FILE"
    ) || return 1

    if (( exact_count > 1 || related_count != exact_count )); then
        log_error "Malformed or duplicate ${key} entry in $_CS_EMAIL_ENV_FILE"
        return 1
    fi
    if (( exact_count == 0 )); then
        printf -v "$result_var" '%s' "$default_value"
        return 0
    fi

    raw="$(awk -v key="$key" '
        index($0, key "=") == 1 {
            print substr($0, length(key) + 2)
            exit
        }
    ' "$_CS_EMAIL_ENV_FILE")" || return 1
    value="$raw"
    if (( ${#value} >= 2 )); then
        if [[ "$value" == \"*\" && "$value" == *\" ]] \
            || [[ "$value" == \'*\' && "$value" == *\' ]]; then
            value="${value:1:${#value}-2}"
        fi
    fi
    printf -v "$result_var" '%s' "$value"
}

_cs_reload_email_environment() {
    local notifications admin_email smtp_from allowed_sender_domains
    _cs_email_read_env_setting CROWDSEC_EMAIL_NOTIFICATIONS false notifications || return 1
    _cs_email_read_env_setting ADMIN_EMAIL "" admin_email || return 1
    _cs_email_read_env_setting SMTP_FROM "" smtp_from || return 1
    _cs_email_read_env_setting ALLOWED_SENDER_DOMAINS "" allowed_sender_domains || return 1

    notifications="${notifications,,}"
    case "$notifications" in
        true|false) ;;
        *)
            log_error "CROWDSEC_EMAIL_NOTIFICATIONS must be exactly true or false in $_CS_EMAIL_ENV_FILE"
            return 1
            ;;
    esac

    CROWDSEC_EMAIL_NOTIFICATIONS="$notifications"
    ADMIN_EMAIL="$admin_email"
    SMTP_FROM="$smtp_from"
    ALLOWED_SENDER_DOMAINS="$allowed_sender_domains"
    export CROWDSEC_EMAIL_NOTIFICATIONS ADMIN_EMAIL SMTP_FROM ALLOWED_SENDER_DOMAINS
}

_cs_yaml_single_quote() {
    local value="$1"
    value="${value//\'/\'\'}"
    printf "'%s'" "$value"
}

_cs_email_address_is_safe() {
    local value="${1:-}"
    [[ -n "$value" && ${#value} -le 254 ]] \
        && [[ "$value" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] \
        && [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* ]] \
        && [[ "$value" != *[[:cntrl:]]* ]]
}

_cs_email_domain_is_valid() {
    local domain="${1:-}" label
    local -a labels=()

    domain="${domain,,}"
    [[ -n "$domain" && ${#domain} -le 253 ]] || return 1
    [[ "$domain" != *[[:space:]]* && "$domain" != *[[:cntrl:]]* ]] || return 1
    [[ "$domain" =~ ^[a-z0-9.-]+$ ]] || return 1
    [[ "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || return 1

    IFS='.' read -r -a labels <<< "$domain"
    (( ${#labels[@]} > 0 )) || return 1
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
    done
}

_cs_email_sender_domain_is_allowed() {
    local sender="${1:-}" allowed="${2:-}"
    local sender_domain candidate
    local matched=false
    local -a domains=()

    _cs_email_address_is_safe "$sender" || return 1
    [[ -n "$allowed" && "$allowed" != *[![:print:]]* ]] || return 1

    sender_domain="${sender##*@}"
    sender_domain="${sender_domain,,}"
    _cs_email_domain_is_valid "$sender_domain" || return 1

    read -r -a domains <<< "$allowed"
    (( ${#domains[@]} > 0 )) || return 1

    for candidate in "${domains[@]}"; do
        [[ -n "$candidate" ]] || return 1
        candidate="${candidate,,}"
        _cs_email_domain_is_valid "$candidate" || return 1
        [[ "$candidate" == "$sender_domain" ]] && matched=true
    done

    [[ "$matched" == true ]]
}

_cs_email_validate_unique_plugin_definition() {
    local notifications_dir="${_CS_LAPI_COHORT_ROOT}/notifications"
    local managed_plugin_path file matches
    managed_plugin_path="${_CS_EMAIL_PLUGIN_PATH:-${notifications_dir}/vaultwarden-email.yaml}"
    [[ -d "$notifications_dir" ]] || return 0

    if ! command -v yq >/dev/null 2>&1; then
        log_error "Cannot inspect CrowdSec notification YAML: required yq v4 command is unavailable."
        return 1
    fi
    if [[ ! -r "$notifications_dir" || ! -x "$notifications_dir" ]]; then
        log_error "Cannot inspect CrowdSec notification directory: $notifications_dir"
        return 1
    fi

    while IFS= read -r -d '' file; do
        [[ "$file" == "$managed_plugin_path" ]] && continue
        if [[ ! -f "$file" || ! -r "$file" ]]; then
            log_error "Cannot inspect CrowdSec notification file for duplicate names: $file"
            return 1
        fi
        if ! matches="$(yq eval-all -r \
            'select(tag == "!!map" and .name == "vaultwarden_email") | .name' \
            "$file" 2>/dev/null)"; then
            log_error "Malformed or unreadable CrowdSec notification YAML: $file"
            return 1
        fi
        if grep -Fxq 'vaultwarden_email' <<< "$matches"; then
            log_error "Duplicate CrowdSec notification name 'vaultwarden_email' found in operator file: $file"
            return 1
        fi
    done < <(find "$notifications_dir" -maxdepth 1 \
        \( -type f -o -type l \) \( -name '*.yaml' -o -name '*.yml' \) -print0)
}

_cs_email_profile_has_unmanaged_reference() {
    local file="$1" parse_file="$1" stripped_file="" references=""
    local rc=0

    if [[ "$file" == "${_CS_LAPI_COHORT_ROOT}/profiles.yaml.local" ]]; then
        stripped_file="$(mktemp "${TMPDIR:-/tmp}/vw-crowdsec-profile.XXXXXXXX")" || return 2
        if ! _cs_email_strip_profile_block "$file" "$stripped_file"; then
            rm -f -- "$stripped_file"
            return 2
        fi
        parse_file="$stripped_file"
    fi

    references="$(yq eval-all -r '
        select(tag == "!!map") |
        (.notifications // []) |
        select(tag == "!!seq") |
        .[] |
        select(tag == "!!str" and . == "vaultwarden_email")
    ' "$parse_file" 2>/dev/null)" || rc=$?
    [[ -z "$stripped_file" ]] || rm -f -- "$stripped_file"
    (( rc == 0 )) || return 2

    grep -Fxq 'vaultwarden_email' <<< "$references"
}

_cs_email_validate_unique_profile_reference() {
    local file rc

    if ! command -v yq >/dev/null 2>&1; then
        log_error "Cannot inspect CrowdSec profile YAML: required yq v4 command is unavailable."
        return 1
    fi

    for file in \
        "${_CS_LAPI_COHORT_ROOT}/profiles.yaml" \
        "${_CS_LAPI_COHORT_ROOT}/profiles.yaml.local"; do
        [[ -e "$file" || -L "$file" ]] || continue
        if [[ ! -f "$file" || ! -r "$file" ]]; then
            log_error "Cannot inspect CrowdSec profile file for duplicate notification references: $file"
            return 1
        fi

        rc=0
        _cs_email_profile_has_unmanaged_reference "$file" || rc=$?
        case "$rc" in
            0)
                log_error "Unmanaged CrowdSec profile already references 'vaultwarden_email': $file"
                return 1
                ;;
            1) ;;
            *)
                log_error "Malformed or unreadable CrowdSec profile YAML: $file"
                return 1
                ;;
        esac
    done
}

_cs_email_ensure_dir() {
    local path="$1"
    [[ -d "$path" ]] && return 0
    install -d -m 750 -o root -g root "$path"
}

_cs_email_file_metadata() {
    local path="$1" default_mode="${2:-640}"
    if [[ -e "$path" ]]; then
        printf '%s %s %s\n' \
            "$(stat -c '%a' "$path")" "$(stat -c '%u' "$path")" "$(stat -c '%g' "$path")"
    else
        printf '%s 0 0\n' "$default_mode"
    fi
}

_cs_email_write_plugin_stage() {
    local output="$1"
    local template="${PROJECT_ROOT}/crowdsec/vaultwarden-email.yaml.template"
    local sender receiver line

    if [[ ! -r "$template" ]]; then
        log_error "CrowdSec email template is missing or unreadable: $template"
        return 1
    fi
    if ! grep -Fq '__SMTP_FROM__' "$template" \
        || ! grep -Fq '__ADMIN_EMAIL__' "$template"; then
        log_error "CrowdSec email template is missing required address placeholders: $template"
        return 1
    fi

    sender="$(_cs_yaml_single_quote "$SMTP_FROM")"
    receiver="$(_cs_yaml_single_quote "$ADMIN_EMAIL")"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//__SMTP_FROM__/"$sender"}"
        line="${line//__ADMIN_EMAIL__/"$receiver"}"
        printf '%s\n' "$line"
    done < "$template" > "$output"

    if grep -Eq '__SMTP_FROM__|__ADMIN_EMAIL__' "$output"; then
        log_error "CrowdSec email template rendering left unresolved placeholders."
        return 1
    fi
}

_cs_email_strip_profile_block() {
    local input="$1" output="$2"
    awk -v begin="$_CS_EMAIL_PROFILE_BEGIN" -v end="$_CS_EMAIL_PROFILE_END" '
        $0 == begin {
            if (inside || seen) exit 42
            inside=1; seen=1; next
        }
        $0 == end {
            if (!inside) exit 43
            inside=0; next
        }
        !inside { print }
        END { if (inside) exit 44 }
    ' "$input" > "$output"
}

_cs_email_append_profile_block() {
    local output="$1"
    cat >> "$output" <<EOF_EMAIL_PROFILE
${_CS_EMAIL_PROFILE_BEGIN}
---
name: vaultwarden_email_notifications
filters:
  - Alert.Remediation == true && Alert.GetScope() == "Ip"
notifications:
  - vaultwarden_email
on_success: continue
${_CS_EMAIL_PROFILE_END}
EOF_EMAIL_PROFILE
}

_cs_email_validate_stages() {
    local plugin="$1" profiles="$2" enabled="$3"
    if [[ "$enabled" == "true" ]]; then
        grep -Fxq "$_CS_EMAIL_PLUGIN_MARKER" "$plugin" || return 1
        grep -Fxq 'smtp_host: 127.0.0.1' "$plugin" || return 1
        grep -Fxq 'smtp_port: 587' "$plugin" || return 1
        grep -Fxq 'auth_type: none' "$plugin" || return 1
        grep -Fxq 'encryption_type: none' "$plugin" || return 1
        if grep -Eiq 'smtp_password|smtp_username|email_api_token|authorization|api[_-]?token' "$plugin"; then
            return 1
        fi
        [[ "$(grep -Fxc "$_CS_EMAIL_PROFILE_BEGIN" "$profiles")" == "1" ]] || return 1
        [[ "$(grep -Fxc "$_CS_EMAIL_PROFILE_END" "$profiles")" == "1" ]] || return 1
        grep -Fxq 'on_success: continue' "$profiles" || return 1
    else
        ! grep -Fq "$_CS_EMAIL_PROFILE_BEGIN" "$profiles" || return 1
        ! grep -Fq "$_CS_EMAIL_PROFILE_END" "$profiles" || return 1
    fi
}

_cs_email_promote_stage() {
    local stage="$1" destination="$2" metadata="$3" mode uid gid
    read -r mode uid gid <<< "$metadata"
    chmod "$mode" "$stage" || return 1
    chown "$uid:$gid" "$stage" || return 1
    mv -fT -- "$stage" "$destination"
}

_cs_email_restore_path() {
    local destination="$1" backup="$2" existed="$3" metadata="$4" restore_stage
    if [[ "$existed" == "true" ]]; then
        [[ -f "$backup" ]] || return 1
        restore_stage="$(mktemp "$(dirname "$destination")/.vw-email-restore.XXXXXXXX")" || return 1
        cp "$backup" "$restore_stage" || { rm -f "$restore_stage"; return 1; }
        _cs_email_promote_stage "$restore_stage" "$destination" "$metadata" || {
            rm -f "$restore_stage"
            return 1
        }
    else
        rm -f "$destination" || return 1
    fi
}

_cs_email_path_matches_backup() {
    local destination="$1" backup="$2" existed="$3" metadata="$4" mode uid gid
    if [[ "$existed" != "true" ]]; then
        [[ ! -e "$destination" ]]
        return
    fi
    [[ -f "$destination" && -f "$backup" ]] || return 1
    cmp -s "$backup" "$destination" || return 1
    read -r mode uid gid <<< "$metadata"
    [[ "$(stat -c '%a' "$destination")" == "$mode" ]] \
        && [[ "$(stat -c '%u' "$destination")" == "$uid" ]] \
        && [[ "$(stat -c '%g' "$destination")" == "$gid" ]]
}

_cs_run_without_operation_guard_fds() (
    unset VW_CROWDSEC_EMAIL_COMMIT_MARKER VW_CROWDSEC_EMAIL_COMMIT_TOKEN
    if declare -f operation_run_without_guard_fds >/dev/null 2>&1; then
        operation_run_without_guard_fds "$@"
    else
        exec "$@"
    fi
)

_cs_validate_crowdsec_config() {
    local context="${1:-managed configuration}"
    if ! command -v crowdsec >/dev/null 2>&1; then
        log_error "CrowdSec static validation failed for ${context}: 'crowdsec' command is unavailable."
        return 1
    fi
    if ! _cs_run_without_operation_guard_fds crowdsec -t; then
        log_error "CrowdSec static validation failed for ${context}: crowdsec -t"
        return 1
    fi
}

_cs_email_test_hook() {
    local point="$1" marker="${VW_TEST_CROWDSEC_EMAIL_HOOK_MARKER:-}"
    if [[ "${VW_TEST_CROWDSEC_EMAIL_PAUSE_POINT:-}" == "$point" ]]; then
        [[ -z "$marker" ]] || : > "$marker"
        [[ -n "${VW_TEST_CROWDSEC_EMAIL_HOOK_FIFO:-}" ]] || return 1
        IFS= read -r _ < "$VW_TEST_CROWDSEC_EMAIL_HOOK_FIFO"
    fi
    if [[ "${VW_TEST_CROWDSEC_EMAIL_SIGNAL_POINT:-}" == "$point" ]]; then
        [[ -z "$marker" ]] || : > "$marker"
        kill -s "${VW_TEST_CROWDSEC_EMAIL_SIGNAL:-TERM}" "$BASHPID"
        sleep 1
    fi
}

_cs_reconcile_email_notifications() (
    set -euo pipefail
    _cs_email_paths
    local enabled="${CROWDSEC_EMAIL_NOTIFICATIONS:-false}"
    enabled="${enabled,,}"
    [[ "$enabled" == "true" ]] || enabled=false

    local transaction_active=false transaction_committed=false rollback_done=false
    local transaction_changed=false rollback_failed=false success_ready=false
    local workdir="" plugin_stage="" profiles_stage="" empty_input=""
    local plugin_existed=false profiles_existed=false
    local plugin_original_metadata="" plugin_target_metadata="640 0 0" profiles_metadata=""
    local plugin_backup_ref="" profiles_backup_ref=""
    local plugin_backup_fd="" profiles_backup_fd=""

    # shellcheck disable=SC2317,SC2329  # scoped helper invoked by transaction control flow
    _cs_email_cleanup_paths() {
        local failed=false
        if [[ -n "$plugin_stage" ]] && ! rm -f -- "$plugin_stage"; then failed=true; fi
        if [[ -n "$profiles_stage" ]] && ! rm -f -- "$profiles_stage"; then failed=true; fi
        if [[ -n "$workdir" ]] && ! rm -rf -- "$workdir"; then failed=true; fi
        [[ "$failed" == false ]]
    }

    # shellcheck disable=SC2317,SC2329  # scoped helper invoked by transaction control flow
    _cs_email_open_backup_fds() {
        if [[ "$plugin_existed" == true ]]; then
            exec {plugin_backup_fd}<"${workdir}/plugin.backup" || return 1
            plugin_backup_ref="/proc/${BASHPID}/fd/${plugin_backup_fd}"
        fi
        if [[ "$profiles_existed" == true ]]; then
            if ! exec {profiles_backup_fd}<"${workdir}/profiles.backup"; then
                if [[ -n "$plugin_backup_fd" ]]; then exec {plugin_backup_fd}<&-; fi
                plugin_backup_fd=""
                plugin_backup_ref=""
                return 1
            fi
            profiles_backup_ref="/proc/${BASHPID}/fd/${profiles_backup_fd}"
        fi
    }

    # shellcheck disable=SC2317,SC2329  # scoped helper invoked by transaction control flow
    _cs_email_close_backup_fds() {
        if [[ -n "$plugin_backup_fd" ]]; then
            exec {plugin_backup_fd}<&- || true
            plugin_backup_fd=""
        fi
        if [[ -n "$profiles_backup_fd" ]]; then
            exec {profiles_backup_fd}<&- || true
            profiles_backup_fd=""
        fi
    }

    # shellcheck disable=SC2317,SC2329  # scoped helper invoked by transaction control flow
    _cs_email_write_commit_marker() {
        local marker="${VW_CROWDSEC_EMAIL_COMMIT_MARKER:-}"
        local token="${VW_CROWDSEC_EMAIL_COMMIT_TOKEN:-}"
        local marker_dir env_dir marker_base env_base stage
        [[ -n "$marker" ]] || return 0

        if [[ "${VW_OPERATION_PARENT_ID:-}" != "crowdsec-email-control" ]]; then
            log_error "Refusing CrowdSec email commit marker outside the control operation."
            return 1
        fi
        if [[ ! "$token" =~ ^[A-Za-z0-9._-]{1,128}$ ]]; then
            log_error "CrowdSec email commit marker token is invalid."
            return 1
        fi
        marker_dir="$(dirname -- "$marker")"
        env_dir="$(dirname -- "$_CS_EMAIL_ENV_FILE")"
        marker_base="$(basename -- "$marker")"
        env_base="$(basename -- "$_CS_EMAIL_ENV_FILE")"
        if [[ "$marker_dir" != "$env_dir" || "$marker_base" != "${env_base}.backup."*.committed ]]; then
            log_error "CrowdSec email commit marker path is outside the .env transaction namespace."
            return 1
        fi
        if [[ -e "$marker" || -L "$marker" ]]; then
            log_error "CrowdSec email commit marker already exists: $marker"
            return 1
        fi
        stage="$(mktemp "${marker}.tmp.XXXXXXXX")" || return 1
        if ! printf '%s\n' "$token" >"$stage" \
            || ! chmod 0600 "$stage" \
            || ! mv -fT -- "$stage" "$marker"; then
            rm -f -- "$stage"
            log_error "Could not publish the CrowdSec email transaction commit marker."
            return 1
        fi
    }

    # shellcheck disable=SC2317,SC2329  # invoked from the scoped EXIT cleanup
    _cs_email_rollback_transaction() {
        [[ "$transaction_active" == true && "$transaction_committed" == false ]] || return 0
        if [[ "$rollback_done" == true ]]; then
            [[ "$rollback_failed" == false ]]
            return
        fi
        rollback_done=true
        transaction_active=false
        local failed=false plugin_backup profiles_backup
        plugin_backup="${plugin_backup_ref:-${workdir}/plugin.backup}"
        profiles_backup="${profiles_backup_ref:-${workdir}/profiles.backup}"

        if ! _cs_email_restore_path "$_CS_EMAIL_PLUGIN_PATH" "$plugin_backup" \
            "$plugin_existed" "$plugin_original_metadata"; then
            log_error "Failed to restore previous CrowdSec email plugin file."
            failed=true
        elif ! _cs_email_path_matches_backup "$_CS_EMAIL_PLUGIN_PATH" "$plugin_backup" \
            "$plugin_existed" "$plugin_original_metadata"; then
            log_error "Restored CrowdSec email plugin file did not match its protected state."
            failed=true
        fi
        if ! _cs_email_restore_path "$_CS_EMAIL_PROFILES_PATH" "$profiles_backup" \
            "$profiles_existed" "$profiles_metadata"; then
            log_error "Failed to restore previous CrowdSec profiles.yaml.local file."
            failed=true
        elif ! _cs_email_path_matches_backup "$_CS_EMAIL_PROFILES_PATH" "$profiles_backup" \
            "$profiles_existed" "$profiles_metadata"; then
            log_error "Restored CrowdSec profiles.yaml.local file did not match its protected state."
            failed=true
        fi
        if [[ "$transaction_changed" == true ]] \
            && ! _cs_run_without_operation_guard_fds systemctl restart crowdsec >/dev/null 2>&1; then
            log_error "CrowdSec restart after rollback failed; inspect: sudo systemctl status crowdsec"
            failed=true
        fi
        if [[ "$failed" == false ]]; then
            log_warn "Restored the previous CrowdSec email notification files."
        else
            log_error "CrowdSec email notification rollback was incomplete."
            rollback_failed=true
        fi
        [[ "$failed" == false ]]
    }

    # shellcheck disable=SC2317,SC2329  # scoped helper invoked by transaction control flow
    _cs_email_log_success() {
        if [[ "$enabled" == true ]]; then
            log_success "CrowdSec email notifications enabled through 127.0.0.1:587."
            log_info "Delivery testing remains explicit: sudo cscli notifications test vaultwarden_email"
        else
            log_info "CrowdSec email notifications disabled; managed notification files removed when present."
        fi
    }

    # shellcheck disable=SC2317,SC2329  # invoked by the scoped EXIT trap
    _cs_email_transaction_exit() {
        local final_rc="$1" rollback_rc=0 cleanup_rc=0 marker_rc=0 open_rc=0
        trap - EXIT
        trap '' INT HUP TERM

        if (( final_rc == 0 )) && [[ "$success_ready" == true ]]; then
            if [[ "$transaction_active" == true ]]; then
                _cs_email_open_backup_fds || open_rc=$?
                if (( open_rc == 0 )); then
                    _cs_email_cleanup_paths || cleanup_rc=$?
                fi
                if (( open_rc == 0 && cleanup_rc == 0 )); then
                    _cs_email_write_commit_marker || marker_rc=$?
                fi
                if (( open_rc == 0 && cleanup_rc == 0 && marker_rc == 0 )); then
                    transaction_committed=true
                    transaction_active=false
                    _cs_email_close_backup_fds
                    _cs_email_log_success || true
                    exit 0
                fi

                (( open_rc == 0 )) || log_error "Could not protect CrowdSec email backups for transaction finalization."
                (( cleanup_rc == 0 )) || log_error "CrowdSec email transaction cleanup failed before commit."
                (( marker_rc == 0 )) || log_error "CrowdSec email transaction could not be committed to its caller."
                _cs_email_rollback_transaction || rollback_rc=$?
                _cs_email_cleanup_paths || cleanup_rc=$?
                _cs_email_close_backup_fds
                if (( rollback_rc != 0 || cleanup_rc != 0 )); then
                    log_error "CrowdSec email transaction cleanup was incomplete."
                fi
                exit 1
            fi

            if ! _cs_email_write_commit_marker; then
                exit 1
            fi
            exit 0
        fi

        if [[ "$transaction_active" == true && "$transaction_committed" == false ]]; then
            _cs_email_rollback_transaction || rollback_rc=$?
            (( final_rc != 0 )) || final_rc=1
        fi
        _cs_email_cleanup_paths || cleanup_rc=$?
        _cs_email_close_backup_fds
        if (( rollback_rc != 0 || cleanup_rc != 0 )); then
            log_error "CrowdSec email transaction cleanup was incomplete."
            (( final_rc != 0 )) || final_rc=1
        fi
        exit "$final_rc"
    }

    trap '_cs_email_transaction_exit "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 129' HUP
    trap 'exit 143' TERM

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would reconcile CrowdSec email notifications: ${enabled}"
        success_ready=true
        return 0
    fi

    if [[ -f "$_CS_EMAIL_PLUGIN_PATH" ]] \
        && ! grep -Fxq "$_CS_EMAIL_PLUGIN_MARKER" "$_CS_EMAIL_PLUGIN_PATH"; then
        log_error "Refusing to overwrite unmarked operator file: $_CS_EMAIL_PLUGIN_PATH"
        return 1
    fi
    if [[ "$enabled" == "true" && ( -z "${ADMIN_EMAIL:-}" || -z "${SMTP_FROM:-}" ) ]]; then
        log_error "CROWDSEC_EMAIL_NOTIFICATIONS=true requires ADMIN_EMAIL and SMTP_FROM."
        return 1
    fi
    if [[ "$enabled" == "true" ]] \
        && { ! _cs_email_address_is_safe "$ADMIN_EMAIL" || ! _cs_email_address_is_safe "$SMTP_FROM"; }; then
        log_error "ADMIN_EMAIL and SMTP_FROM must be bounded, single-line email addresses for CrowdSec notifications."
        return 1
    fi
    if [[ "$enabled" == "true" ]] \
        && ! _cs_email_sender_domain_is_allowed "$SMTP_FROM" "${ALLOWED_SENDER_DOMAINS:-}"; then
        log_error "SMTP_FROM domain '${SMTP_FROM##*@}' must exactly match one space-separated ALLOWED_SENDER_DOMAINS entry."
        return 1
    fi
    if [[ "$enabled" == "true" ]]; then
        _cs_email_validate_unique_plugin_definition || return 1
        _cs_email_validate_unique_profile_reference || return 1
    fi
    if [[ "$enabled" == "false" && ! -e "$_CS_EMAIL_PLUGIN_PATH" ]] \
        && { [[ ! -f "$_CS_EMAIL_PROFILES_PATH" ]] \
            || { ! grep -Fq "$_CS_EMAIL_PROFILE_BEGIN" "$_CS_EMAIL_PROFILES_PATH" \
                && ! grep -Fq "$_CS_EMAIL_PROFILE_END" "$_CS_EMAIL_PROFILES_PATH"; }; }; then
        log_info "CrowdSec email notifications disabled; no managed notification files are present."
        success_ready=true
        return 0
    fi

    local managed_state_present=false
    if [[ -e "$_CS_EMAIL_PLUGIN_PATH" ]] \
        || { [[ -f "$_CS_EMAIL_PROFILES_PATH" ]] \
            && { grep -Fq "$_CS_EMAIL_PROFILE_BEGIN" "$_CS_EMAIL_PROFILES_PATH" \
                || grep -Fq "$_CS_EMAIL_PROFILE_END" "$_CS_EMAIL_PROFILES_PATH"; }; }; then
        managed_state_present=true
    fi

    if [[ "$enabled" == "true" && "$managed_state_present" == "false" ]]; then
        if ! _cs_validate_crowdsec_config \
            "existing configuration before VaultWarden-OCI email installation"; then
            log_error "CrowdSec configuration is already invalid before VaultWarden-OCI managed email files are installed."
            log_error "Inspect operator-owned files under ${_CS_LAPI_COHORT_ROOT}/notifications and CrowdSec profile files, then rerun setup."
            return 1
        fi
    fi

    _cs_email_ensure_dir "$(dirname "$_CS_EMAIL_PROFILES_PATH")" || return 1
    _cs_email_ensure_dir "$(dirname "$_CS_EMAIL_PLUGIN_PATH")" || return 1

    workdir="$(mktemp -d "${_CS_LAPI_COHORT_ROOT}/.vw-email-transaction.XXXXXXXX")" || return 1
    chmod 0700 "$workdir" || return 1
    plugin_stage="$(mktemp "$(dirname "$_CS_EMAIL_PLUGIN_PATH")/.vw-email-plugin.XXXXXXXX")" || return 1
    profiles_stage="$(mktemp "$(dirname "$_CS_EMAIL_PROFILES_PATH")/.vw-email-profiles.XXXXXXXX")" || return 1
    empty_input="${workdir}/empty"
    : > "$empty_input"

    if [[ -e "$_CS_EMAIL_PLUGIN_PATH" ]]; then
        plugin_existed=true
        cp -p -- "$_CS_EMAIL_PLUGIN_PATH" "${workdir}/plugin.backup" || return 1
    fi
    if [[ -e "$_CS_EMAIL_PROFILES_PATH" ]]; then
        profiles_existed=true
        cp -p -- "$_CS_EMAIL_PROFILES_PATH" "${workdir}/profiles.backup" || return 1
    fi
    plugin_original_metadata="$(_cs_email_file_metadata "$_CS_EMAIL_PLUGIN_PATH" 640)" || return 1
    profiles_metadata="$(_cs_email_file_metadata "$_CS_EMAIL_PROFILES_PATH" 640)" || return 1

    if ! _cs_email_strip_profile_block \
        "$([[ "$profiles_existed" == true ]] && printf '%s' "$_CS_EMAIL_PROFILES_PATH" || printf '%s' "$empty_input")" \
        "$profiles_stage"; then
        log_error "Refusing malformed or duplicate VaultWarden-OCI block in $_CS_EMAIL_PROFILES_PATH"
        return 1
    fi

    if [[ "$enabled" == true ]]; then
        _cs_email_write_plugin_stage "$plugin_stage" || return 1
        _cs_email_append_profile_block "$profiles_stage"
    else
        : > "$plugin_stage"
    fi

    if ! _cs_email_validate_stages "$plugin_stage" "$profiles_stage" "$enabled"; then
        log_error "CrowdSec email notification staged-file validation failed."
        return 1
    fi

    transaction_active=true
    if [[ "$enabled" == true ]]; then
        _cs_email_promote_stage "$plugin_stage" "$_CS_EMAIL_PLUGIN_PATH" "$plugin_target_metadata" || return 1
    else
        rm -f -- "$plugin_stage" || return 1
        plugin_stage=""
        [[ "$plugin_existed" == false ]] || rm -f -- "$_CS_EMAIL_PLUGIN_PATH" || return 1
    fi
    transaction_changed=true
    _cs_email_test_hook after-plugin

    if [[ -s "$profiles_stage" ]]; then
        _cs_email_promote_stage "$profiles_stage" "$_CS_EMAIL_PROFILES_PATH" "$profiles_metadata" || return 1
    else
        rm -f -- "$profiles_stage" || return 1
        profiles_stage=""
        [[ "$profiles_existed" == false ]] || rm -f -- "$_CS_EMAIL_PROFILES_PATH" || return 1
    fi
    _cs_email_test_hook after-profile
    _cs_email_test_hook before-validate

    if ! _cs_validate_crowdsec_config "managed CrowdSec email configuration"; then
        log_error "CrowdSec email notification reconciliation failed at: crowdsec -t"
        return 1
    fi
    _cs_email_test_hook after-validate
    _cs_email_test_hook before-restart

    if ! _cs_run_without_operation_guard_fds systemctl restart crowdsec; then
        log_error "CrowdSec restart failed: systemctl restart crowdsec"
        return 1
    fi
    _cs_email_test_hook after-restart

    success_ready=true
    return 0
)

# ---------------------------------------------------------------------------
# CLI flags
# ---------------------------------------------------------------------------
AUTO_MODE=false
DRY_RUN=false
FORCE=false
EMAIL_ONLY=false
AUTONOMOUS_MODE=false
USE_LATEST=false
ADMIN_IP=""
_CS_FW_BOUNCER_KEY_GENERATED=""
CROWDSEC_VERSION="${CROWDSEC_VERSION:-}"
CF_WORKER_BOUNCER_VERSION="${CF_WORKER_BOUNCER_VERSION:-}"

show_help() {
    cat <<'HELP'
VaultWarden-OCI CrowdSec Setup

USAGE:
    sudo utilities/setup-crowdsec.sh [OPTIONS]

DESCRIPTION:
    Installs and configures CrowdSec with the Cloudflare Workers bouncer
    for VaultWarden-OCI intrusion detection and edge-level banning.
    Requires CLOUDFLARE_PROXY_ENABLED=true for the Cloudflare bouncer phase.

OPTIONS:
    --auto               Non-interactive: never prompt.
    --reconcile-email    Reconcile only the managed email notification files.
    --dry-run            Print what would happen without changing files.
    --force              Re-run all phases even if already applied.
    --use-latest         Override version pins and use the current live upstream
                         release of each component.
    --autonomous         Deploy the Workers bouncer in autonomous mode (-S flag).
    --admin-ip IP|CIDR   Add this IP address or CIDR to the CrowdSec admin
                         allowlist.
    --help, -h           Show this help.
    --version, -V        Print the VaultWarden-OCI version and exit.

ENVIRONMENT:
    CLOUDFLARE_PROXY_ENABLED   Set to 'true' to enable the Cloudflare bouncer.
    CF_FREE_PLAN               Set to 'false' to disable the free-plan KV write
                               guard. Default: 'true'.
    CROWDSEC_VERSION           Pin a specific CrowdSec version.
    CF_WORKER_BOUNCER_VERSION  Pin a specific Workers bouncer version.
    CROWDSEC_EMAIL_NOTIFICATIONS
                               Optional security-event email through the
                               existing 127.0.0.1:587 Postfix relay. Default: false.

    Cloudflare credentials (in encrypted secrets, not .env):
        sudo ./edit-secrets.sh rotate cf_worker_bouncer_token
        sudo ./edit-secrets.sh rotate cloudflare_zone_id
        sudo ./edit-secrets.sh rotate cf_account_id

EXAMPLES:
    sudo utilities/setup-crowdsec.sh
    sudo utilities/setup-crowdsec.sh --dry-run
    sudo utilities/setup-crowdsec.sh --force
    sudo utilities/setup-crowdsec.sh --reconcile-email
HELP
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)        AUTO_MODE=true; shift ;;
        --reconcile-email) EMAIL_ONLY=true; AUTO_MODE=true; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --force)       FORCE=true; shift ;;
        --use-latest)  USE_LATEST=true; shift ;;
        --autonomous)  AUTONOMOUS_MODE=true; shift ;;
        --admin-ip)
            if [[ -z "${2-}" || "${2}" == --* ]]; then
                log_error "--admin-ip requires a value (e.g. --admin-ip 203.0.113.42 or --admin-ip 203.0.113.0/24)"
                exit 1
            fi
            ADMIN_IP="$2"; shift 2 ;;
        --help|-h)
            show_help
            exit 0 ;;
        --version|-V)
            print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"
            exit 0 ;;
        help)
            show_help
            exit 0 ;;
        *)
            log_error "Unknown flag: $1"
            exit 1 ;;
    esac
done

if [[ "$AUTO_MODE" == "true" ]]; then
    log_info "Running in non-interactive (auto) mode."
fi

if [[ "$USE_LATEST" == "true" ]]; then
    CROWDSEC_VERSION=""
    CF_WORKER_BOUNCER_VERSION=""
    FIREWALL_BOUNCER_VERSION=""
    log_info "Version pins cleared by --use-latest; all components will use current upstream releases."
fi

[[ "${CROWDSEC_VERSION:-}"          == "latest" ]] && CROWDSEC_VERSION=""
[[ "${CF_WORKER_BOUNCER_VERSION:-}" == "latest" ]] && CF_WORKER_BOUNCER_VERSION=""
[[ "${FIREWALL_BOUNCER_VERSION:-}"  == "latest" ]] && FIREWALL_BOUNCER_VERSION=""

_cs_previous_state=""
_cs_previous_phase=""
_cs_previous_phase_name=""
_cs_state_file="${VW_OPERATIONS_STATE_DIR:-/run/vaultwarden-oci/operations}/crowdsec-setup.state"
if declare -f _operation_state_get >/dev/null 2>&1 && [[ -r "$_cs_state_file" ]]; then
    _cs_previous_state="$(_operation_state_get "$_cs_state_file" state 2>/dev/null || true)"
    _cs_previous_phase="$(_operation_state_get "$_cs_state_file" phase 2>/dev/null || true)"
    _cs_previous_phase_name="$(_operation_state_get "$_cs_state_file" phase_name 2>/dev/null || true)"
fi

if [[ "$DRY_RUN" != "true" ]] && declare -f operation_acquire >/dev/null 2>&1; then
    operation_acquire \
        --id crowdsec-setup \
        --label "CrowdSec setup" \
        --specific-lock /run/lock/vaultwarden-crowdsec-setup.lock \
        --non-interactive wait || exit $?
    _cs_operation_cleanup() {
        local rc=$?
        local rollback_rc=0
        if [[ "$_CS_LAPI_COHORT_COMMITTED" != "true" ]]; then
            _cs_lapi_cohort_rollback || rollback_rc=$?
            _cs_lapi_cohort_cleanup
            if (( rc == 0 && rollback_rc != 0 )); then rc=1; fi
        fi
        operation_release "$rc"
        return "$rc"
    }
    trap _cs_operation_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 129' HUP
    trap 'exit 143' TERM
fi

# Email rendering inputs must be resolved after the operation guard is held.
if [[ "$DRY_RUN" != "true" ]]; then
    _cs_reload_email_environment || exit 1
fi

if [[ "$EMAIL_ONLY" == "true" ]]; then
    operation_set_phase "email" "CrowdSec email notifications" 2>/dev/null || true
    if _cs_reconcile_email_notifications; then
        exit 0
    else
        _cs_email_rc=$?
        exit "$_cs_email_rc"
    fi
fi

if [[ "$FORCE" == "true" && -n "$_cs_previous_state" && "$_cs_previous_state" != "complete" ]]; then
    log_warn "Previous CrowdSec setup did not complete."
    if [[ -n "$_cs_previous_phase$_cs_previous_phase_name" ]]; then
        log_warn "Last recorded phase: ${_cs_previous_phase:-?}${_cs_previous_phase_name:+ - }${_cs_previous_phase_name}"
    fi
    log_warn "A normal re-run can inspect and reconcile the existing installation."
    log_warn "Recommended: sudo ./utilities/setup-crowdsec.sh --use-latest"
    log_warn "--force will reset CrowdSec state again."
    if [[ ! -t 0 ]]; then
        log_error "Refusing non-interactive --force after an incomplete CrowdSec setup record."
        exit 1
    fi
    if ! operator_confirm_yes_no "Continue with force reset?" "no" 300; then
        log_info "CrowdSec force reset cancelled."
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# Execution wrapper
# ---------------------------------------------------------------------------
_cs_run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] $*"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# Service-existence guards
# ---------------------------------------------------------------------------
_cf_worker_bouncer_service_exists() {
    [[ -f "/etc/systemd/system/crowdsec-cloudflare-worker-bouncer.service" ]] || \
    [[ -f "/lib/systemd/system/crowdsec-cloudflare-worker-bouncer.service" ]]
}

# ---------------------------------------------------------------------------
# Write the crowdsec-cloudflare-worker-bouncer systemd unit if needed.
# ---------------------------------------------------------------------------
_cs_ensure_cf_worker_unit() {
    local bin_path="${1:-/usr/local/bin/crowdsec-cloudflare-worker-bouncer}"
    if [[ -x "$bin_path" ]] && ! _cf_worker_bouncer_service_exists && [[ "$AUTONOMOUS_MODE" != "true" ]]; then
        log_info "Writing crowdsec-cloudflare-worker-bouncer systemd unit..."
        cat >/etc/systemd/system/crowdsec-cloudflare-worker-bouncer.service <<'UNIT'
[Unit]
Description=CrowdSec Cloudflare Workers Bouncer
After=network-online.target crowdsec.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/crowdsec-cloudflare-worker-bouncer -c /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml
Restart=on-failure
RestartSec=5
User=root
Group=root

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload || true
        log_success "Installed crowdsec-cloudflare-worker-bouncer systemd unit."
    fi
}

# ---------------------------------------------------------------------------
# PHASE 0: Reset installed components when --force is active.
# ---------------------------------------------------------------------------
if [[ "$FORCE" == "true" ]]; then
    _cs_reset_components
fi

# ---------------------------------------------------------------------------
# PHASE 1: CrowdSec base installation
# ---------------------------------------------------------------------------
operation_set_phase "1" "CrowdSec base installation" 2>/dev/null || true
log_info "=== PHASE 1: CrowdSec base installation ==="

_legacy_notify_unit="/etc/systemd/system/vaultwarden-notify-failure.service"
if [[ -f "$_legacy_notify_unit" ]] && grep -q "Review failed units with:" "$_legacy_notify_unit" 2>/dev/null; then
    log_warn "Detected legacy vaultwarden-notify-failure.service payload; normalizing for CrowdSec compatibility."
    sed -i 's/Review failed units with:\\n  systemctl --failed\\n/Run: systemctl --failed/g' "$_legacy_notify_unit" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
fi

if command -v cscli >/dev/null 2>&1 && [[ "$FORCE" != "true" ]]; then
    log_info "CrowdSec already installed — skipping base install."
elif [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would install crowdsec, crowdsec-firewall-bouncer-iptables, and ipset"
else
    log_info "Adding CrowdSec repository..."
    _repo_script="$(mktemp -p /tmp cs-repo-setup.XXXXXX.sh)"
    # shellcheck disable=SC2064
    trap "rm -f '$_repo_script'" RETURN
    if ! curl -fsSL --connect-timeout 15 --max-time 30 \
            https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh \
            -o "$_repo_script"; then
        log_error "Failed to download CrowdSec repository setup script."
        rm -f "$_repo_script"
        return 1
    fi
    # Verify the script came from the expected source and is a shell script
    if ! head -1 "$_repo_script" | grep -qE '^#!/(usr/)?bin/(env )?bash'; then
        log_error "Downloaded repository script does not appear to be a valid shell script — aborting."
        rm -f "$_repo_script"
        return 1
    fi
    operation_package_run bash "$_repo_script"
    rm -f "$_repo_script"

    _cs_pkg="crowdsec"
    if [[ -n "$CROWDSEC_VERSION" ]]; then
        _cs_pkg="crowdsec=${CROWDSEC_VERSION}"
        log_info "CrowdSec version pinned: ${CROWDSEC_VERSION}"
    else
        log_info "CrowdSec version: installing latest from packagecloud repository"
    fi

    log_info "Installing CrowdSec engine package first..."
    _fw_base="crowdsec-firewall-bouncer"
    if iptables -V 2>/dev/null | grep -q 'nf_tables'; then
        _fw_suffix="nftables"
        log_info "nftables detected — installing crowdsec-firewall-bouncer-nftables."
    else
        _fw_suffix="iptables"
        log_info "iptables detected — installing crowdsec-firewall-bouncer-iptables."
    fi

    if [[ -n "${FIREWALL_BOUNCER_VERSION:-}" ]]; then
        _fw_pkg="${_fw_base}-${_fw_suffix}=${FIREWALL_BOUNCER_VERSION}"
        log_info "Firewall bouncer version pinned: ${FIREWALL_BOUNCER_VERSION}"
    else
        _fw_pkg="${_fw_base}-${_fw_suffix}"
        log_info "Firewall bouncer version: installing latest from packagecloud repository"
    fi

    operation_package_run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$_cs_pkg"
    log_info "Installing CrowdSec firewall bouncer package..."
    operation_package_run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$_fw_pkg"
    log_info "Installing ipset (required by crowdsec-firewall-bouncer iptables backend)..."
    operation_package_run env DEBIAN_FRONTEND=noninteractive apt-get install -y ipset

    # --- CRITICAL: rewrite upstream default port (8080) to 8090 immediately
    # after package install, before the service is ever started. This prevents
    # CrowdSec from racing Caddy for port 8080 on first boot.
    if grep -q 'listen_uri: 127.0.0.1:8080' "${_CS_LAPI_COHORT_ROOT}/config.yaml" 2>/dev/null; then
        log_info "Rewriting upstream default LAPI port 8080 -> 8090 in config.yaml..."
        _cs_fix_port_conflict "8080" "8090" || exit 1
        log_success "LAPI port pre-assigned to 8090 — Caddy owns 8080."
    fi
fi

if [[ "$DRY_RUN" != "true" ]]; then
    _selected_lapi_port="$(_cs_resolve_lapi_port)"
    _cs_ensure_lapi_port_cohort "$_selected_lapi_port" || {
        log_error "CrowdSec LAPI port cohort reconciliation failed. Required services were not started."
        exit 1
    }
    if systemctl is-active --quiet crowdsec; then
        log_info "CrowdSec service already active — reloading configuration."
        if ! systemctl reload crowdsec 2>/dev/null \
            && ! systemctl restart crowdsec 2>/dev/null; then
            log_error "CrowdSec configuration reload/restart failed."
            exit 1
        fi
    elif ! _cs_start_service; then
        log_error "Cannot continue with a stopped CrowdSec service."
        log_error "Resolve the issue above, then re-run: sudo ./utilities/setup-crowdsec.sh"
        exit 1
    fi
    systemctl is-active --quiet crowdsec || {
        log_error "CrowdSec engine is not active after setup."
        exit 1
    }
    log_success "CrowdSec service enabled and running."
fi

# ---------------------------------------------------------------------------
# PHASE 1b: Firewall bouncer config (DOCKER-USER chain + key registration)
# ---------------------------------------------------------------------------
operation_set_phase "1b" "Firewall bouncer config" 2>/dev/null || true
log_info "=== PHASE 1b: Firewall bouncer config ==="

_FW_BOUNCER_CONFIG="/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"
_LAPI_PORT="$(_cs_resolve_lapi_port)"

if [[ "$DRY_RUN" != "true" ]]; then
    if ! command -v ipset >/dev/null 2>&1; then
        log_warn "ipset not found — installing now (required by crowdsec-firewall-bouncer iptables backend)."
        if operation_package_run env DEBIAN_FRONTEND=noninteractive apt-get install -y ipset; then
            log_success "ipset installed successfully."
        else
            log_error "Failed to install ipset; refusing setup without the required firewall bouncer dependency."
            exit 1
        fi
    fi
fi

if [[ -f "$_FW_BOUNCER_CONFIG" ]]; then
    log_info "Firewall bouncer config already present — checking registration."

    # DOCKER-USER chain is only relevant for iptables mode.
    # On nftables the chain concept does not apply; skip silently.
    _fw_current_mode="$(grep '^mode:' "$_FW_BOUNCER_CONFIG" 2>/dev/null | awk '{print $2}' | head -1 || echo 'iptables')"
    if [[ "$_fw_current_mode" == "iptables" ]]; then
        if ! grep -q 'DOCKER-USER' "$_FW_BOUNCER_CONFIG"; then
            log_info "Adding DOCKER-USER chain to existing iptables firewall bouncer config..."
            sed -i '/iptables_chains:/,/^[^ ]/{/- INPUT/a\  - DOCKER-USER
}' "$_FW_BOUNCER_CONFIG" 2>/dev/null || true
            systemctl restart crowdsec-firewall-bouncer 2>/dev/null || true
            log_success "DOCKER-USER chain added to firewall bouncer config."
        else
            log_info "DOCKER-USER chain already present in firewall bouncer config."
        fi
    else
        log_info "nftables mode detected — DOCKER-USER chain not applicable, skipping."
    fi

    # Always verify the key is valid and registered in the LAPI.
    # This covers: plain re-runs, post-partial-failure runs, and --force runs.
    if [[ "$DRY_RUN" != "true" ]]; then
        _cs_ensure_fw_bouncer_key "$_FW_BOUNCER_CONFIG" || exit 1
    fi

elif [[ ! -f "$_FW_BOUNCER_CONFIG" ]] && [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would write firewall bouncer config with DOCKER-USER chain"
else
    # Fresh install path — config file does not exist yet.
    # If LAPI has a stale bouncer registration but the local config is missing,
    # generate a fresh key instead of trying to read from a non-existent file.
    if ! cscli bouncers list 2>/dev/null | grep -q 'firewall-bouncer' \
        || [[ ! -f "$_FW_BOUNCER_CONFIG" ]]; then
        log_info "Registering firewall bouncer in CrowdSec LAPI..."
        _fw_key="$(openssl rand -hex 32)"
        cscli bouncers delete crowdsecurity/firewall-bouncer 2>/dev/null || true
        cscli bouncers delete firewall-bouncer 2>/dev/null || true
        if ! cscli bouncers add crowdsecurity/firewall-bouncer --key "$_fw_key" >/dev/null 2>&1; then
            log_error "Failed to register the firewall bouncer key in CrowdSec LAPI."
            exit 1
        fi
    else
        _fw_key="$(grep 'api_key:' "$_FW_BOUNCER_CONFIG" 2>/dev/null | awk '{print $2}' | head -1 || true)"
    fi

    if [[ -z "${_fw_key:-}" ]]; then
        log_warn "Firewall bouncer key could not be recovered — generating a fresh key."
        _fw_key="$(openssl rand -hex 32)"
        cscli bouncers delete crowdsecurity/firewall-bouncer 2>/dev/null || true
        cscli bouncers delete firewall-bouncer 2>/dev/null || true
        if ! cscli bouncers add crowdsecurity/firewall-bouncer --key "$_fw_key" >/dev/null 2>&1; then
            log_error "Failed to register the replacement firewall bouncer key in CrowdSec LAPI."
            exit 1
        fi
    fi

    # Detect whether iptables is using the nf_tables backend on Ubuntu 24.04 Noble.
    if iptables -V 2>/dev/null | grep -q 'nf_tables'; then
        _fw_mode="nftables"
        _fw_chains_block="nftables_hooks:
  - input
  - forward"
    else
        _fw_mode="iptables"
        _fw_chains_block="iptables_chains:
  - INPUT
  - DOCKER-USER"
    fi

    install -d -m 750 -o root -g root "$(dirname "$_FW_BOUNCER_CONFIG")"

    cat > "$_FW_BOUNCER_CONFIG" <<FWCONFIG
mode: ${_fw_mode}
update_frequency: 10s
log_mode: stdout
log_level: info
api_url: http://127.0.0.1:${_LAPI_PORT}/
api_key: ${_fw_key}

origins: []

${_fw_chains_block}

deny_action: DROP
disable_ipv6: false
FWCONFIG
    chmod 600 "$_FW_BOUNCER_CONFIG"
    log_success "Firewall bouncer config written: ${_FW_BOUNCER_CONFIG}"

    # Ensure the key written above is actually registered — handles the edge
    # case where cscli bouncers add silently failed above.
    if [[ "$DRY_RUN" != "true" ]]; then
        _cs_ensure_fw_bouncer_key "$_FW_BOUNCER_CONFIG" || exit 1
    fi
fi

# ---------------------------------------------------------------------------
# PHASE 2: Cloudflare Workers bouncer installation
# ---------------------------------------------------------------------------
operation_set_phase "2" "Cloudflare Workers bouncer installation" 2>/dev/null || true
log_info "=== PHASE 2: Cloudflare Workers bouncer installation ==="

_CF_PROXY_ENABLED="${CLOUDFLARE_PROXY_ENABLED:-false}"
_CF_WORKER_BOUNCER_BIN="/usr/local/bin/crowdsec-cloudflare-worker-bouncer"
_CF_WORKER_BOUNCER_NEEDS_INSTALL=false

if [[ "$_CF_PROXY_ENABLED" != "true" ]]; then
    log_warn "Skipping crowdsec-cloudflare-worker-bouncer setup — CLOUDFLARE_PROXY_ENABLED is not 'true'."
    log_warn "Set CLOUDFLARE_PROXY_ENABLED=true in .env and re-run this script to enable the Cloudflare Workers bouncer."
elif [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would install crowdsec-cloudflare-worker-bouncer (apt -> tarball -> go source fallback)"
else
    if ! cscli bouncers list 2>/dev/null | grep -q 'cloudflare-worker-bouncer' || [[ "$FORCE" == "true" ]]; then
        log_info "Updating CrowdSec hub..."
        cscli hub update || true
        log_info "Cloudflare Workers bouncer registration will be reconciled with its configured key in Phase 5."
    else
        log_info "CrowdSec Cloudflare Workers bouncer already registered — skipping."
    fi

    if [[ ! -x "$_CF_WORKER_BOUNCER_BIN" ]] || [[ "$FORCE" == "true" ]]; then
        _CF_WORKER_BOUNCER_NEEDS_INSTALL=true
    fi

    if [[ "$_CF_WORKER_BOUNCER_NEEDS_INSTALL" == "true" ]]; then
        log_info "Cloudflare Workers bouncer binary not found — attempting installation..."

        _installed_via_deb=false

        # Pre-create a minimal stub config so the package postinst script does
        # not abort trying to open a non-existent config file. Phase 6 overwrites
        # this with the real values.
        if [[ ! -f /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml ]]; then
            mkdir -p /etc/crowdsec/bouncers
            cat > /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml <<'STUB'
crowdsec_config:
  lapi_url: "http://127.0.0.1:8090/"
  lapi_key: "STUB_KEY"
update_frequency: "10s"
log_mode: "stdout"
STUB
            chmod 600 /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml
            log_info "Wrote stub CF bouncer config to satisfy dpkg postinst."
        fi

        log_info "Attempting apt install of crowdsec-cloudflare-worker-bouncer..."
        if operation_package_run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
            -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold \
            crowdsec-cloudflare-worker-bouncer; then
            log_success "Installed crowdsec-cloudflare-worker-bouncer via apt."
            _installed_via_deb=true
            _apt_bin="$(command -v crowdsec-cloudflare-worker-bouncer 2>/dev/null || true)"
            if [[ -n "$_apt_bin" && "$_apt_bin" != "$_CF_WORKER_BOUNCER_BIN" ]]; then
                ln -sf "$_apt_bin" "$_CF_WORKER_BOUNCER_BIN"
                log_info "Symlinked ${_apt_bin} -> ${_CF_WORKER_BOUNCER_BIN} for path consistency."
            fi
        else
            log_warn "apt install failed — falling back to GitHub release tarball."
        fi

        if [[ "$_installed_via_deb" == "false" && ! -x "$_CF_WORKER_BOUNCER_BIN" ]]; then
            _host_arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
            if ! _arch="$(_cf_worker_bouncer_release_arch "$_host_arch")"; then
                log_warn "No GitHub release tarball mapping for architecture '${_host_arch}' — skipping tarball fallback."
                _arch=""
            fi
        fi

        if [[ "$_installed_via_deb" == "false" && -n "${_arch:-}" && ! -x "$_CF_WORKER_BOUNCER_BIN" ]]; then
            if [[ -z "$CF_WORKER_BOUNCER_VERSION" ]]; then
                _gh_api="https://api.github.com/repos/crowdsecurity/cs-cloudflare-worker-bouncer/releases/latest"
                log_info "CF Workers bouncer version: fetching latest from GitHub."
            else
                _ver="${CF_WORKER_BOUNCER_VERSION#v}"   # strip leading 'v' if present
                _gh_api="https://api.github.com/repos/crowdsecurity/cs-cloudflare-worker-bouncer/releases/tags/v${_ver}"
                log_info "CF Workers bouncer version pinned: v${_ver}"
            fi

            _release_json="$(curl -fsSL "$_gh_api" 2>/dev/null)" || {
                log_warn "Failed to query GitHub releases for cs-cloudflare-worker-bouncer."
                _release_json=""
            }

            if [[ -n "$_release_json" ]]; then
                _download_url="$(printf '%s' "$_release_json" | \
                    grep -oP '"browser_download_url":\s*"\K[^"]+' | \
                    grep "linux-${_arch}" | \
                    grep '\.tgz$' | \
                    grep -v '\.sha256' | \
                    head -1 || true)"
                _sha256_url="$(printf '%s' "$_release_json" | \
                    grep -oP '"browser_download_url":\s*"\K[^"]+' | \
                    grep "linux-${_arch}" | \
                    grep '\.tgz\.sha256$' | \
                    head -1 || true)"

                if [[ -n "$_download_url" ]]; then
                    _tmpdir="$(mktemp -d -p /tmp cs-cf-worker.XXXXXX)"
                    _tmptar="${_tmpdir}/bouncer.tgz"

                    log_info "Downloading: $_download_url"
                    if curl -fsSL "$_download_url" -o "$_tmptar"; then
                        if [[ -n "$_sha256_url" ]]; then
                            _expected_sha="$(curl -fsSL "$_sha256_url" 2>/dev/null | awk '{print $1}' || true)"
                            _actual_sha="$(sha256sum "$_tmptar" | awk '{print $1}')"
                            if [[ -n "$_expected_sha" && "$_actual_sha" != "$_expected_sha" ]]; then
                                log_error "SHA256 mismatch — aborting tarball install."
                                rm -rf "$_tmpdir"
                                _tmpdir=""
                            fi
                        fi

                        if [[ -n "$_tmpdir" && -f "$_tmptar" ]]; then
                            tar xzf "$_tmptar" -C "$_tmpdir"
                            rm -f "$_tmptar"

                            _install_sh="$(find "$_tmpdir" -maxdepth 2 -name 'install.sh' | head -1 || true)"

                            if [[ -n "$_install_sh" && -f "$_install_sh" ]]; then
                                _install_dir="$(dirname "$_install_sh")"
                                log_info "Running bundled installer from: $_install_dir"
                                if (cd "$_install_dir" && bash install.sh); then
                                    log_success "Installed cs-cloudflare-worker-bouncer via tarball install.sh."
                                else
                                    log_warn "Bundled install.sh failed — attempting manual binary extraction."
                                    _bin_path="$(find "$_tmpdir" -maxdepth 3 -type f \
                                        -name 'crowdsec-cloudflare-worker-bouncer' \
                                        ! -name '*.sh' | head -1 || true)"
                                    if [[ -x "$_bin_path" ]]; then
                                        install -m 755 -o root -g root "$_bin_path" "$_CF_WORKER_BOUNCER_BIN"
                                        log_success "Copied binary to ${_CF_WORKER_BOUNCER_BIN} (manual fallback)."
                                    fi
                                fi
                            else
                                log_warn "No install.sh found in tarball — extracting binary directly."
                                _bin_path="$(find "$_tmpdir" -maxdepth 3 -type f \
                                    -name 'crowdsec-cloudflare-worker-bouncer' \
                                    ! -name '*.sh' | head -1 || true)"
                                if [[ -x "$_bin_path" ]]; then
                                    install -m 755 -o root -g root "$_bin_path" "$_CF_WORKER_BOUNCER_BIN"
                                    log_success "Copied binary to ${_CF_WORKER_BOUNCER_BIN}."
                                fi
                            fi
                        fi

                        [[ -n "${_tmpdir:-}" ]] && rm -rf "$_tmpdir"
                    else
                        log_warn "Failed to download tarball from GitHub."
                        rm -rf "$_tmpdir"
                    fi
                else
                    log_warn "No linux-${_arch} tarball asset found in latest GitHub release."
                fi
            fi
        fi

        if [[ "$_installed_via_deb" == "false" && ! -x "$_CF_WORKER_BOUNCER_BIN" ]]; then
            if command -v go >/dev/null 2>&1; then
                log_info "Attempting Go source build for crowdsec-cloudflare-worker-bouncer..."
                if [[ -z "$CF_WORKER_BOUNCER_VERSION" ]]; then
                    _go_pkg_ref="github.com/crowdsecurity/cs-cloudflare-worker-bouncer/cmd/crowdsec-cloudflare-worker-bouncer@latest"
                else
                    _ver="${CF_WORKER_BOUNCER_VERSION#v}"
                    _go_pkg_ref="github.com/crowdsecurity/cs-cloudflare-worker-bouncer/cmd/crowdsec-cloudflare-worker-bouncer@v${_ver}"
                fi
                _tmpgobin="$(mktemp -d -p /tmp cs-cf-worker-go.XXXXXX)"
                if GOBIN="$_tmpgobin" go install "$_go_pkg_ref" 2>/dev/null; then
                    if [[ -x "$_tmpgobin/crowdsec-cloudflare-worker-bouncer" ]]; then
                        install -m 755 -o root -g root \
                            "$_tmpgobin/crowdsec-cloudflare-worker-bouncer" \
                            "$_CF_WORKER_BOUNCER_BIN"
                        log_success "Built and installed crowdsec-cloudflare-worker-bouncer from source."
                    fi
                else
                    log_warn "Go source build failed for crowdsec-cloudflare-worker-bouncer."
                fi
                rm -rf "$_tmpgobin"
            else
                log_warn "Go toolchain not installed; cannot build from source."
            fi
        fi

    else
        log_info "Cloudflare Workers bouncer binary already present at ${_CF_WORKER_BOUNCER_BIN}."
    fi

    _cs_ensure_cf_worker_unit "$_CF_WORKER_BOUNCER_BIN"
fi

# ---------------------------------------------------------------------------
# PHASE 3: CrowdSec hub collections
# ---------------------------------------------------------------------------
operation_set_phase "3" "CrowdSec hub collections" 2>/dev/null || true
log_info "=== PHASE 3: CrowdSec hub collections ==="

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would install hub collections: crowdsecurity/caddy, crowdsecurity/linux, crowdsecurity/iptables, Dominic-Wagner/vaultwarden"
else
    # Keep top-level collections aligned with the log sources this project
    # actually configures. Dependencies are resolved by CrowdSec Hub metadata;
    # do not install AppSec collections unless a real AppSec listener and
    # request-forwarding path are added.
    cscli collections install crowdsecurity/caddy        || true
    cscli collections install crowdsecurity/linux        || true
    cscli collections install crowdsecurity/iptables     || true
    cscli collections install Dominic-Wagner/vaultwarden || true

    # Earlier Beta builds installed AppSec collections without an AppSec listener.
    # Remove only those inactive top-level AppSec collections; dependency cleanup
    # remains CrowdSec's responsibility and operator-owned custom collections are
    # left untouched.
    cscli collections remove crowdsecurity/appsec-generic-rules --force    >/dev/null 2>&1 || true
    cscli collections remove crowdsecurity/appsec-virtual-patching --force >/dev/null 2>&1 || true
    log_success "Hub collections installed."
fi

# ---------------------------------------------------------------------------
# PHASE 4: Acquisition config
# ---------------------------------------------------------------------------
operation_set_phase "4" "Acquisition config" 2>/dev/null || true
log_info "=== PHASE 4: Acquisition config ==="

_project_state_dir="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}"
_acquis_dest="/etc/crowdsec/acquis.d/vaultwarden.yaml"
_acquis_src="${PROJECT_ROOT}/crowdsec/acquis.yaml"

if [[ -f "$_acquis_src" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would write ${_acquis_dest} from ${_acquis_src}"
    else
        mkdir -p /etc/crowdsec/acquis.d
        sed "s|TOKEN_PROJECT_STATE_DIR|${_project_state_dir}|g" \
            "$_acquis_src" \
            | tee "$_acquis_dest" >/dev/null
        log_success "Acquisition config written to ${_acquis_dest}"
    fi
else
    log_warn "crowdsec/acquis.yaml not found in ${PROJECT_ROOT} — skipping acquis config."
fi

# ---------------------------------------------------------------------------
# PHASE 5: Bouncer API key
# ---------------------------------------------------------------------------
operation_set_phase "5" "Bouncer API key" 2>/dev/null || true
log_info "=== PHASE 5: Bouncer API key ==="

_CF_BOUNCER_KEY=""
_CF_BOUNCER_ENV_KEY="CROWDSEC_CF_BOUNCER_API_KEY"

if [[ "$_CF_PROXY_ENABLED" != "true" ]]; then
    log_warn "Skipping bouncer API key generation — CLOUDFLARE_PROXY_ENABLED is not 'true'."
elif [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would generate and register a bouncer API key, write to .env as ${_CF_BOUNCER_ENV_KEY}"
    _CF_BOUNCER_KEY="DRY_RUN_PLACEHOLDER"
else
    _existing_key="${CROWDSEC_CF_BOUNCER_API_KEY:-}"
    if [[ -n "$_existing_key" ]] && cscli bouncers list 2>/dev/null | grep -q 'cloudflare-worker-bouncer' && [[ "$FORCE" != "true" ]]; then
        log_info "Bouncer API key already present in .env — skipping key generation."
        _CF_BOUNCER_KEY="$_existing_key"
    else
        log_info "Generating new bouncer API key..."
        _new_key="$(openssl rand -hex 32)"
        cscli bouncers delete cloudflare-worker-bouncer 2>/dev/null || true
        if ! cscli bouncers add cloudflare-worker-bouncer --key "$_new_key" >/dev/null 2>&1; then
            log_error "Failed to register the Cloudflare Workers bouncer key in CrowdSec LAPI."
            log_error "No new Worker bouncer key was written to .env. Resolve LAPI access and re-run setup."
            exit 1
        fi
        _CF_BOUNCER_KEY="$_new_key"
        _cs_set_env_var "$_CF_BOUNCER_ENV_KEY" "$_CF_BOUNCER_KEY"
        log_success "Bouncer API key generated and registered. Written to .env as ${_CF_BOUNCER_ENV_KEY}."

        if [[ -t 0 ]]; then
            printf '%s' "${COLOR_RED}"
            cat << 'BOUNCER_BANNER'
  ╔══════════════════════════════════════════════════════════════════════╗
  ║        🔑  CROWDSEC API KEYS GENERATED — SAVE THESE NOW           ║
  ╚══════════════════════════════════════════════════════════════════════╝
BOUNCER_BANNER
            printf '%s' "${COLOR_RESET}"
            printf '\n'
            if [[ -n "$_CS_FW_BOUNCER_KEY_GENERATED" ]]; then
                printf '  Firewall bouncer key (written to crowdsec-firewall-bouncer.yaml):\n'
                printf '  %s%s%s\n\n' \
                    "${COLOR_RED}" "${_CS_FW_BOUNCER_KEY_GENERATED}" "${COLOR_RESET}"
            fi
            printf '  Cloudflare Workers bouncer key (stored in .env as CROWDSEC_CF_BOUNCER_API_KEY):\n'
            printf '  %s%s%s\n\n' \
                "${COLOR_RED}" "${_CF_BOUNCER_KEY}" "${COLOR_RESET}"
            press_enter_to_continue " Press [Enter] after saving all keys above..."
            clear
        fi
    fi
fi

# ---------------------------------------------------------------------------
# PHASE 6: Cloudflare Workers bouncer config
# ---------------------------------------------------------------------------
operation_set_phase "6" "Cloudflare Workers bouncer config" 2>/dev/null || true
log_info "=== PHASE 6: Cloudflare Workers bouncer config ==="

_CF_WORKER_BOUNCER_CONFIG_SRC="${PROJECT_ROOT}/crowdsec/crowdsec-cloudflare-worker-bouncer.yaml.example"
_CF_WORKER_BOUNCER_CONFIG_DEST="/etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml"

if [[ -f "$_CF_WORKER_BOUNCER_CONFIG_SRC" ]]; then
    if [[ "$_CF_PROXY_ENABLED" != "true" ]]; then
        log_warn "Skipping Cloudflare Workers bouncer config write — CLOUDFLARE_PROXY_ENABLED is not 'true'."
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            _worker_route="${DOMAIN_NAME:-<domain>}/*"
        else
            _domain_name="${DOMAIN_NAME:-}"
            if [[ -z "$_domain_name" && -n "${DOMAIN:-}" ]]; then
                _domain_name="${DOMAIN#https://}"
                _domain_name="${_domain_name#http://}"
                _domain_name="${_domain_name%%/*}"
                log_info "DOMAIN_NAME not set — derived from DOMAIN: ${_domain_name}"
            fi
            if [[ -z "$_domain_name" ]]; then
                log_error "Neither DOMAIN_NAME nor DOMAIN is set in .env — cannot derive routes_to_protect."
                log_error "Set DOMAIN_NAME=yourdomain.com in .env and re-run."
                exit 1
            fi
            _worker_route="${_domain_name}/*"
        fi

        CROWDSEC_CF_BOUNCER_API_KEY="${_CF_BOUNCER_KEY:-${CROWDSEC_CF_BOUNCER_API_KEY:-}}" \
            crowdsec_worker_apply_config --allow-missing-service || {
                log_error "Failed to render/apply Cloudflare Workers bouncer config."
                log_error "Retry only this phase with: sudo ./utilities/crowdsec-worker-apply.sh"
                exit 1
            }
        fi
else
    log_warn "crowdsec-cloudflare-worker-bouncer.yaml.example not found in ${PROJECT_ROOT}/crowdsec — skipping bouncer config write."
    log_warn "Expected: ${_CF_WORKER_BOUNCER_CONFIG_SRC}"
fi

# ---------------------------------------------------------------------------
# PHASE 7: CrowdSec profiles
# ---------------------------------------------------------------------------
operation_set_phase "7" "CrowdSec profiles" 2>/dev/null || true
log_info "=== PHASE 7: CrowdSec profiles ==="

_PROFILES_SRC="${PROJECT_ROOT}/crowdsec/profiles.yaml"

if [[ -f "$_PROFILES_SRC" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would copy ${_PROFILES_SRC} to /etc/crowdsec/profiles.yaml"
    else
        cp "$_PROFILES_SRC" /etc/crowdsec/profiles.yaml
        log_success "profiles.yaml applied to /etc/crowdsec/profiles.yaml"
    fi
else
    log_info "No custom crowdsec/profiles.yaml found — using CrowdSec defaults."
fi

# Full setup may update .env in earlier phases; resolve email inputs again while
# the same operation guard remains held immediately before reconciliation.
if [[ "$DRY_RUN" != "true" ]]; then
    _cs_reload_email_environment || exit 1
fi
if _cs_reconcile_email_notifications; then
    :
else
    _cs_email_rc=$?
    log_error "CrowdSec email notification reconciliation failed."
    exit "$_cs_email_rc"
fi

_cs_wait_for_lapi() {
    local port="${1:-8090}"
    local max_wait=30
    local i=0
    log_info "Waiting for CrowdSec LAPI to be ready on port ${port}..."
    while (( i < max_wait )); do
        if curl -sf --max-time 2 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
            log_success "LAPI is ready on port ${port}."
            return 0
        fi
        sleep 1
        (( i++ )) || true
    done
    log_warn "LAPI did not respond within ${max_wait}s on port ${port} — bouncer may fail to start."
    return 1
}

_cs_wait_for_required_service() {
    local service="$1" attempts="${2:-15}" i
    for (( i=0; i<attempts; i++ )); do
        systemctl is-active --quiet "$service" && return 0
        sleep 1
    done
    return 1
}

_cs_activate_required_services() {
    local lapi_port
    systemctl is-active --quiet crowdsec || {
        log_error "CrowdSec engine is not active; required enforcement services were not started."
        return 1
    }
    lapi_port="$(_cs_resolve_lapi_port)"
    if ! _cs_wait_for_lapi "$lapi_port"; then
        log_error "CrowdSec LAPI is not ready on ${lapi_port}; refusing to start required bouncers."
        return 1
    fi

    systemctl reset-failed crowdsec-firewall-bouncer 2>/dev/null || true
    if ! systemctl enable --now crowdsec-firewall-bouncer; then
        log_error "Failed to enable/start required crowdsec-firewall-bouncer."
        return 1
    fi
    if ! _cs_wait_for_required_service crowdsec-firewall-bouncer 15; then
        log_error "Required crowdsec-firewall-bouncer did not become active."
        local fw_journal
        fw_journal="$(journalctl -u crowdsec-firewall-bouncer --no-pager -n 15 2>/dev/null || true)"
        if [[ -n "$fw_journal" ]]; then
            log_error "Last crowdsec-firewall-bouncer journal entries:"
            while IFS= read -r fw_line; do log_error "  ${fw_line}"; done <<< "$fw_journal"
        fi
        return 1
    fi
    log_success "crowdsec-firewall-bouncer is active."

    if [[ "$_CF_PROXY_ENABLED" != "true" ]]; then
        log_warn "Skipping crowdsec-cloudflare-worker-bouncer enable — CLOUDFLARE_PROXY_ENABLED is not 'true'."
        return 0
    fi
    if [[ "$AUTONOMOUS_MODE" == "true" ]]; then
        log_info "Autonomous mode active — Cloudflare Workers handle syncing; no persistent daemon needed."
        return 0
    fi
    if ! _cf_worker_bouncer_service_exists; then
        log_error "Required crowdsec-cloudflare-worker-bouncer.service unit is not installed."
        return 1
    fi
    systemctl reset-failed crowdsec-cloudflare-worker-bouncer 2>/dev/null || true
    if ! systemctl enable --now crowdsec-cloudflare-worker-bouncer; then
        log_error "crowdsec-cloudflare-worker-bouncer failed to enable/start; required edge enforcement is inactive."
        return 1
    fi
    if ! _cs_wait_for_required_service crowdsec-cloudflare-worker-bouncer 15; then
        log_error "Required crowdsec-cloudflare-worker-bouncer did not become active."
        return 1
    fi
    log_success "crowdsec-cloudflare-worker-bouncer enabled and started."
}

# ---------------------------------------------------------------------------
# PHASE 8: Enable and start services
# ---------------------------------------------------------------------------
operation_set_phase "8" "Enable and start services" 2>/dev/null || true
log_info "=== PHASE 8: Enable and start services ==="

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would reload crowdsec and enable crowdsec-firewall-bouncer"
    if [[ "$AUTONOMOUS_MODE" != "true" ]]; then
        log_info "[DRY RUN] Would enable crowdsec-cloudflare-worker-bouncer (daemon mode)"
    else
        log_info "[DRY RUN] Autonomous mode — no persistent service to enable"
    fi
else
    if systemctl is-active --quiet crowdsec; then
        if ! systemctl reload crowdsec 2>/dev/null \
            && ! systemctl restart crowdsec 2>/dev/null; then
            log_error "CrowdSec engine reload/restart failed before bouncer activation."
            exit 1
        fi
    fi
    _cs_activate_required_services || exit 1
    log_success "Services enabled."
fi

# ---------------------------------------------------------------------------
# PHASE 9: Admin IP allowlist
# ---------------------------------------------------------------------------
operation_set_phase "9" "Admin IP allowlist" 2>/dev/null || true
log_info "=== PHASE 9: Admin IP allowlist ==="

_cs_whitelist_dir="/etc/crowdsec/parsers/s02-enrich"
_cs_whitelist_file="${_cs_whitelist_dir}/vaultwarden-admin-allowlist.yaml"
_cs_resolved_ip="$ADMIN_IP"

if [[ -z "$_cs_resolved_ip" ]]; then
    _cs_ssh_src="${SSH_CLIENT:-}"
    if [[ -n "$_cs_ssh_src" ]]; then
        _cs_ssh_ip="${_cs_ssh_src%% *}"
        if [[ "$AUTO_MODE" == "true" ]]; then
            log_info "Auto-detected admin IP from SSH session: ${_cs_ssh_ip}"
            _cs_resolved_ip="$_cs_ssh_ip"
        else
            _cs_prompt_reply=""
            if ! read -r -t 300 -p "Add SSH client IP (${_cs_ssh_ip}) to CrowdSec allowlist? [Enter=yes, type CIDR to use instead, 'skip' to skip]: " \
                _cs_prompt_reply; then
                printf '\n' >&2
                log_warn "No admin IP received within 5 minutes. Skipping optional admin allowlist."
                log_warn "Configure it later with: sudo ./utilities/setup-crowdsec.sh --admin-ip YOUR_IP"
                _cs_prompt_reply="skip"
            fi
            case "${_cs_prompt_reply,,}" in
                ""|yes)  _cs_resolved_ip="$_cs_ssh_ip" ;;
                skip|no) _cs_resolved_ip="" ;;
                *)       _cs_resolved_ip="$_cs_prompt_reply" ;;
            esac
        fi
    elif [[ "$AUTO_MODE" != "true" ]]; then
        _cs_prompt_reply=""
        if ! read -r -t 300 -p "Enter admin IP or CIDR to allowlist in CrowdSec (or press Enter to skip): " \
            _cs_prompt_reply; then
            printf '\n' >&2
            log_warn "No admin IP received within 5 minutes. Skipping optional admin allowlist."
            log_warn "Configure it later with: sudo ./utilities/setup-crowdsec.sh --admin-ip YOUR_IP"
            _cs_prompt_reply=""
        fi
        _cs_resolved_ip="$_cs_prompt_reply"
    fi
fi

if [[ -z "$_cs_resolved_ip" ]]; then
    log_warn "No admin IP provided — CrowdSec admin allowlist not configured."
    log_warn "Re-run with --admin-ip YOUR_IP to add an allowlist entry at any time."
else
    if [[ ! "$_cs_resolved_ip" =~ ^[0-9a-fA-F:./]+$ ]]; then
        log_warn "Ignoring admin IP '${_cs_resolved_ip}': unexpected characters detected."
        log_warn "Provide a plain IPv4/IPv6 address or CIDR (e.g. 203.0.113.42 or 203.0.113.0/24)."
    else
        if [[ "$_cs_resolved_ip" == */* ]]; then
            _cs_yaml_field="cidr"
        else
            _cs_yaml_field="ip"
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would write CrowdSec allowlist to ${_cs_whitelist_file}"
            log_info "[DRY RUN] Would allowlist (${_cs_yaml_field}): ${_cs_resolved_ip}"
        else
            mkdir -p "$_cs_whitelist_dir"
            cat > "$_cs_whitelist_file" <<CSYAML
name: crowdsecurity/whitelists
description: "Admin ${_cs_yaml_field} allowlisted by VaultWarden setup-crowdsec.sh"
whitelist:
  reason: "VaultWarden admin allowlist"
  ${_cs_yaml_field}:
    - "${_cs_resolved_ip}"
CSYAML
            chmod 640 "$_cs_whitelist_file"
            log_success "CrowdSec allowlist written: ${_cs_whitelist_file}"
            log_success "Allowlisted (${_cs_yaml_field}): ${_cs_resolved_ip}"

            if systemctl is-active crowdsec >/dev/null 2>&1; then
                systemctl reload crowdsec 2>/dev/null \
                    || systemctl restart crowdsec 2>/dev/null \
                    || log_warn "CrowdSec reload failed — restart manually: sudo systemctl restart crowdsec"
                log_success "CrowdSec reloaded — allowlist is active."
            else
                log_info "CrowdSec is not running — allowlist will take effect on next start."
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
_lapi_port_summary="$(_cs_resolve_lapi_port)"
log_info ""
log_info "════════════════════════════════════════════════════════"
log_info " CrowdSec setup complete"
log_info "════════════════════════════════════════════════════════"
log_info ""
log_info "── SERVICE STATUS ──────────────────────────────────────"
log_info "  Check all CrowdSec services:"
log_info "    sudo systemctl status crowdsec crowdsec-firewall-bouncer \\"
log_info "      crowdsec-cloudflare-worker-bouncer --no-pager -l"
log_info ""
log_info "  Tail live logs:"
log_info "    sudo journalctl -fu crowdsec"
log_info "    sudo journalctl -fu crowdsec-firewall-bouncer"
log_info "    sudo journalctl -fu crowdsec-cloudflare-worker-bouncer"
log_info ""
log_info "── CROWDSEC ENGINE ─────────────────────────────────────"
log_info "  LAPI port : ${_lapi_port_summary}"
log_info ""
log_info "  Registered bouncers (both should appear):"
log_info "    sudo cscli bouncers list"
log_info ""
log_info "  Active bans and alerts:"
log_info "    sudo cscli decisions list"
log_info "    sudo cscli alerts list"
log_info ""
log_info "  Installed collections and parsers:"
log_info "    sudo cscli collections list"
log_info "    sudo cscli parsers list"
log_info ""
log_info "  Engine metrics (scenarios triggered, parsed lines, etc.):"
log_info "    sudo cscli metrics"
log_info ""
log_info "── FIREWALL BOUNCER ────────────────────────────────────"
log_info "  Host-level blocks (INPUT chain):"
log_info "    sudo iptables -L INPUT -n --line-numbers | grep -i crowdsec"
log_info ""
log_info "  Container blocks (DOCKER-USER chain):"
log_info "    sudo iptables -L DOCKER-USER -n --line-numbers | grep -i crowdsec"
log_info ""
log_info "  ipset ban lists (populated by firewall bouncer):"
log_info "    sudo ipset list | grep -E '^(Name|crowdsec)'"
log_info ""
if [[ "$_CF_PROXY_ENABLED" == "true" ]]; then
    log_info "── CLOUDFLARE WORKERS BOUNCER ──────────────────────────"
    if [[ "$AUTONOMOUS_MODE" == "true" ]]; then
        log_info "  Deployed in autonomous mode — no persistent daemon."
        log_info "  The Cloudflare Worker runs at the edge; decisions sync via KV."
    else
        log_info "  Daemon sync status:"
        log_info "    sudo systemctl status crowdsec-cloudflare-worker-bouncer --no-pager"
        log_info "    sudo journalctl -u crowdsec-cloudflare-worker-bouncer -n 50 --no-pager"
    fi
    log_info ""
    log_info "  Decisions pushed to Cloudflare KV (free plan: up to 1 K writes/day):"
    log_info "    sudo cscli decisions list"
    log_info "    # Active bans appear in: Cloudflare dashboard -> Workers & Pages"
    log_info "    # -> KV -> crowdsec-* namespace"
    log_info ""
    log_info "  IMPORTANT — set Worker route fail mode to 'Fail Open':"
    log_info "    Cloudflare dashboard -> Websites -> <your domain>"
    log_info "    -> Workers Routes -> Edit -> Failure mode: Fail open"
    log_info "    (prevents outage if the Worker errors)"
    log_info ""
    log_info "  Verify the Worker is deployed and routing correctly:"
    log_info "    Cloudflare dashboard -> Workers & Pages -> crowdsec-cloudflare-worker"
    log_info "    -> Triggers -> confirm route: ${_worker_route:-<domain>/*}"
    log_info ""
fi
log_info "── ROTATING CLOUDFLARE CREDENTIALS ────────────────────"
log_info "  Credentials live in secrets (not .env)."
log_info "  To rotate any value and re-apply:"
log_info "    sudo ./edit-secrets.sh rotate cf_worker_bouncer_token"
log_info "    sudo ./edit-secrets.sh rotate cloudflare_zone_id"
log_info "    sudo ./edit-secrets.sh rotate cf_account_id"
log_info "    sudo ./utilities/crowdsec-worker-apply.sh"
log_info ""
if [[ "$_CF_PROXY_ENABLED" == "true" ]]; then
    if declare -f operator_next_steps >/dev/null 2>&1; then
        operator_next_steps "Manual Cloudflare action required" \
            "Set Worker route failure mode to Fail open." \
            "Cloudflare dashboard -> Websites -> <your domain> -> Workers Routes -> Edit -> Failure mode: Fail open" \
            "Verify Worker route: ${_worker_route:-<domain>/*}"
    else
        log_info "Manual Cloudflare action required:"
        log_info "  Set Worker route failure mode to Fail open."
        log_info "  Cloudflare dashboard -> Websites -> <your domain> -> Workers Routes -> Edit -> Failure mode: Fail open"
        log_info "  Verify Worker route: ${_worker_route:-<domain>/*}"
        log_info ""
    fi
fi
log_info "════════════════════════════════════════════════════════"
