#!/usr/bin/env bash
# lib/storage.sh — Public storage-library entrypoint.
#
# The original storage implementation lives in storage-core.sh. Keep the Caddy
# log ownership contract here so startup, repair, Compose, and health checks all
# use the runtime UID/GID expected by the Caddy container.

[[ -n "${VAULTWARDEN_STORAGE_FACADE_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_STORAGE_FACADE_LOADED=1

_VW_STORAGE_FACADE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/storage-core.sh
source "${_VW_STORAGE_FACADE_DIR}/storage-core.sh"
unset _VW_STORAGE_FACADE_DIR

# Ensure the host bind mount used as /var/log/caddy is writable by the Caddy
# process. Compose runs Caddy as UID/GID 2000 by default, and the health check
# enforces directory mode 0750 plus file mode 0640.
ensure_caddy_log_permissions() {
    local caddy_log_dir="${1:-}"
    local caddy_uid="${CADDY_UID:-2000}"
    local caddy_gid="${CADDY_GID:-2000}"

    if [[ -z "$caddy_log_dir" ]]; then
        log_error "ensure_caddy_log_permissions: caddy_log_dir argument is empty."
        return 1
    fi
    if [[ "$caddy_log_dir" != /* ]]; then
        log_error "ensure_caddy_log_permissions: caddy_log_dir must be an absolute path, got: '$caddy_log_dir'"
        return 1
    fi
    if [[ ! "$caddy_uid" =~ ^[0-9]+$ || ! "$caddy_gid" =~ ^[0-9]+$ ]]; then
        log_error "ensure_caddy_log_permissions: CADDY_UID and CADDY_GID must be numeric (got ${caddy_uid}:${caddy_gid})."
        return 1
    fi
    if ! declare -F _maybe_sudo >/dev/null 2>&1; then
        log_error "ensure_caddy_log_permissions requires lib/common.sh to be sourced first"
        return 1
    fi

    local access_log="${caddy_log_dir}/access.log"
    local security_log="${caddy_log_dir}/security.log"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY RUN] Would enforce ${caddy_uid}:${caddy_gid} 750/640 permissions for ${caddy_log_dir}"
        return 0
    fi

    _maybe_sudo mkdir -p -- "$caddy_log_dir" || return 1

    local log_file
    for log_file in "$access_log" "$security_log"; do
        if [[ -e "$log_file" && ! -f "$log_file" ]]; then
            log_error "ensure_caddy_log_permissions: expected a regular file: $log_file"
            return 1
        fi
        if [[ ! -e "$log_file" ]]; then
            _maybe_sudo touch -- "$log_file" || return 1
        fi
    done

    local changed=false owner mode
    owner="$(stat -c '%u:%g' "$caddy_log_dir" 2>/dev/null || printf '')"
    mode="$(stat -c '%a' "$caddy_log_dir" 2>/dev/null || printf '')"
    if [[ "$owner" != "${caddy_uid}:${caddy_gid}" ]]; then
        _maybe_sudo chown "${caddy_uid}:${caddy_gid}" -- "$caddy_log_dir" || return 1
        changed=true
    fi
    if [[ "$mode" != "750" ]]; then
        _maybe_sudo chmod 750 -- "$caddy_log_dir" || return 1
        changed=true
    fi

    for log_file in "$access_log" "$security_log"; do
        owner="$(stat -c '%u:%g' "$log_file" 2>/dev/null || printf '')"
        mode="$(stat -c '%a' "$log_file" 2>/dev/null || printf '')"
        if [[ "$owner" != "${caddy_uid}:${caddy_gid}" ]]; then
            _maybe_sudo chown "${caddy_uid}:${caddy_gid}" -- "$log_file" || return 1
            changed=true
        fi
        if [[ "$mode" != "640" ]]; then
            _maybe_sudo chmod 640 -- "$log_file" || return 1
            changed=true
        fi
    done

    if [[ "$changed" == "true" ]]; then
        log_success "Caddy log permissions remediated (${caddy_log_dir}; ${caddy_uid}:${caddy_gid} 750/640)"
    else
        log_success "Caddy log permissions already correct (${caddy_log_dir}; ${caddy_uid}:${caddy_gid} 750/640)"
    fi
}
