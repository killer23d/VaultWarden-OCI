#!/usr/bin/env bash
# lib/runtime-permissions.sh — Runtime state permission repair helpers.
# shellcheck shell=bash

_vw_runtime_is_numeric_id() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

_vw_repair_tree_permissions() {
    local path="$1" owner="$2" group="$3" dir_mode="$4" file_mode="$5" label="$6"
    [[ -d "$path" ]] || return 0

    local status=0
    if ! chown -R "${owner}:${group}" "$path" 2>/dev/null; then
        log_warn "Could not recursively set ownership for ${label}: ${path} -> ${owner}:${group}"
        status=1
    fi
    if ! find "$path" -type d -exec chmod "$dir_mode" {} + 2>/dev/null; then
        log_warn "Could not normalize directory modes for ${label}: ${path} -> ${dir_mode}"
        status=1
    fi
    if ! find "$path" -type f -exec chmod "$file_mode" {} + 2>/dev/null; then
        log_warn "Could not normalize file modes for ${label}: ${path} -> ${file_mode}"
        status=1
    fi
    return "$status"
}

repair_runtime_state_permissions() {
    local state_dir puid pgid caddy_uid caddy_gid status
    local _vw_path _vw_secret_path init_sentinel
    state_dir="${1:-${PROJECT_STATE_DIR:-/var/lib/vaultwarden}}"
    puid="${2:-${PUID:-}}"
    pgid="${3:-${PGID:-}}"
    caddy_uid="${CADDY_UID:-2000}"
    caddy_gid="${CADDY_GID:-2000}"
    status=0

    if [[ $EUID -ne 0 ]]; then
        log_warn "Runtime permission repair requires root; skipped."
        return 1
    fi

    [[ -d "$state_dir" ]] || {
        log_warn "Runtime permission repair skipped: PROJECT_STATE_DIR does not exist: $state_dir"
        return 1
    }

    if [[ -z "$puid" ]]; then
        puid="$(get_config_value "PUID" "" 2>/dev/null || true)"
    fi
    if [[ -z "$pgid" ]]; then
        pgid="$(get_config_value "PGID" "" 2>/dev/null || true)"
    fi

    log_info "Repairing runtime state permissions under: $state_dir"

    # Root-operated private config/secrets contract.
    install -d -m 700 -o root -g root "$state_dir/config" "$state_dir/secrets" 2>/dev/null || status=1
    for _vw_path in \
        /etc/vaultwarden \
        /etc/vaultwarden/age-key.txt \
        /etc/vaultwarden/vaultwarden.env \
        /etc/vaultwarden/rclone.conf \
        "$state_dir/config" \
        "$state_dir/config/install.env" \
        "$state_dir/config/dr-manifest.env" \
        "$state_dir/secrets" \
        "$state_dir/secrets/secrets.yaml" \
        /run/vaultwarden-oci/secrets; do
        [[ -e "$_vw_path" ]] && fix_known_path_permissions "$_vw_path"
    done

    if [[ -d /run/vaultwarden-oci/secrets ]]; then
        while IFS= read -r -d '' _vw_secret_path; do
            fix_known_path_permissions "$_vw_secret_path"
        done < <(find /run/vaultwarden-oci/secrets -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
    fi

    # Vaultwarden app data runs under PUID:PGID.
    if _vw_runtime_is_numeric_id "$puid" && _vw_runtime_is_numeric_id "$pgid"; then
        _vw_repair_tree_permissions "$state_dir/data" "$puid" "$pgid" 750 640 "Vaultwarden app data" || status=1
        install -d -m 750 -o "$puid" -g "$pgid" "$state_dir/logs/vaultwarden" 2>/dev/null || status=1
        _vw_repair_tree_permissions "$state_dir/logs/vaultwarden" "$puid" "$pgid" 750 640 "Vaultwarden logs" || status=1
    else
        log_warn "PUID/PGID not numeric; skipped Vaultwarden app-data ownership repair."
    fi

    # Caddy runs as UID/GID 2000 and needs writable bind mounts for /data,
    # /config, and /var/log/caddy. Include mount roots themselves.
    install -d -m 750 -o "$caddy_uid" -g "$caddy_gid" \
        "$state_dir/caddy/data" \
        "$state_dir/caddy/data/caddy" \
        "$state_dir/caddy/data/caddy/certificates" \
        "$state_dir/caddy/data/caddy/locks" \
        "$state_dir/caddy/data/caddy/ocsp" \
        "$state_dir/caddy/config" \
        "$state_dir/caddy/config/caddy" \
        "$state_dir/logs/caddy" 2>/dev/null || status=1

    touch "$state_dir/logs/caddy/access.log" "$state_dir/logs/caddy/security.log" 2>/dev/null || status=1
    _vw_repair_tree_permissions "$state_dir/caddy/data" "$caddy_uid" "$caddy_gid" 750 640 "Caddy runtime data" || status=1
    _vw_repair_tree_permissions "$state_dir/caddy/config" "$caddy_uid" "$caddy_gid" 750 640 "Caddy runtime config" || status=1
    _vw_repair_tree_permissions "$state_dir/logs/caddy" "$caddy_uid" "$caddy_gid" 750 640 "Caddy logs" || status=1

    # A restored sentinel can cause init-permissions to skip a scan after DR.
    init_sentinel="$state_dir/data/.permissions-initialized"
    if [[ -e "$init_sentinel" ]]; then
        if rm -f "$init_sentinel" 2>/dev/null; then
            log_info "Removed restored init-permissions sentinel: $init_sentinel"
        else
            log_warn "Could not remove restored init-permissions sentinel: $init_sentinel"
            status=1
        fi
    fi

    return "$status"
}
