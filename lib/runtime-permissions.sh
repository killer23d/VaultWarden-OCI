#!/usr/bin/env bash
# lib/runtime-permissions.sh — Canonical runtime permission checks and repairs.
# shellcheck shell=bash

_vw_runtime_is_numeric_id() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

_vw_runtime_mode() {
    stat -c '%a' "$1" 2>/dev/null || printf 'unknown'
}

_vw_runtime_numeric_owner() {
    stat -c '%u:%g' "$1" 2>/dev/null || printf 'unknown'
}

_vw_runtime_report() {
    local level="$1" label="$2" path="$3" expected="$4" actual="$5" action="$6"
    printf '%s %s\n  path: %s\n  expected: %s\n  actual: %s\n  %s\n' \
        "$level" "$label" "$path" "$expected" "$actual" "$action"
}

_vw_runtime_apply_known_path() {
    local operation="$1" path="$2" label="$3" required="${4:-false}"
    local owner group mode expected actual
    local actual_owner actual_group actual_mode preserve_owner=false

    if [[ ! -e "$path" ]]; then
        if [[ "$required" == "true" ]]; then
            _vw_runtime_report ERROR "$label" "$path" "required managed path" "missing" \
                "fix: sudo utilities/repair-permissions.sh"
            return 1
        fi
        return 0
    fi

    owner="$(expected_owner_for_path "$path")" || return 0
    group="$(expected_group_for_path "$path")" || return 0
    mode="$(expected_mode_for_path "$path")" || return 0
    actual_owner="$(_common_stat_owner "$path")"
    actual_group="$(_common_stat_group "$path")"
    actual_mode="$(_common_stat_mode "$path")"
    if [[ -z "$actual_owner" || -z "$actual_group" || -z "$actual_mode" ]]; then
        _vw_runtime_report ERROR "$label" "$path" "known ownership and mode" "inspection failed" \
            "action: inspection failed"
        return 1
    fi

    # Repository authoring paths are operator-owned. A root system
    # service may have no reliable non-root identity, so preserve the
    # observed owner/group instead of inventing root:root.
    if _is_operator_permission_path "$path" && [[ "$owner" == "root" ]]; then
        owner="$actual_owner"
        group="$actual_group"
        preserve_owner=true
    fi

    expected="owner ${owner}:${group}, mode ${mode}"
    [[ "$preserve_owner" == "true" ]] \
        && expected="existing owner ${owner}:${group}, mode ${mode}"
    actual="owner ${actual_owner}:${actual_group}, mode ${actual_mode}"

    if [[ "${actual_owner}:${actual_group}" == "${owner}:${group}" && "$actual_mode" == "$mode" ]]; then
        _vw_runtime_report OK "$label" "$path" "$expected" "$actual" "action: none"
        return 0
    fi

    if [[ "$operation" == "check" ]]; then
        _vw_runtime_report ERROR "$label" "$path" "$expected" "$actual" \
            "fix: sudo utilities/repair-permissions.sh"
        return 1
    fi

    if [[ "$preserve_owner" != "true" && "${actual_owner}:${actual_group}" != "${owner}:${group}" ]]; then
        chown "${owner}:${group}" "$path" || {
            _vw_runtime_report ERROR "$label" "$path" "$expected" "$actual" "action: chown failed"
            return 1
        }
    fi
    if [[ "$actual_mode" != "$mode" ]]; then
        chmod "$mode" "$path" || {
            _vw_runtime_report ERROR "$label" "$path" "$expected" "$actual" "action: chmod failed"
            return 1
        }
    fi

    actual_owner="$(_common_stat_owner "$path")"
    actual_group="$(_common_stat_group "$path")"
    actual_mode="$(_common_stat_mode "$path")"
    if [[ "${actual_owner}:${actual_group}" != "${owner}:${group}" || "$actual_mode" != "$mode" ]]; then
        actual="owner ${actual_owner}:${actual_group}, mode ${actual_mode}"
        _vw_runtime_report ERROR "$label" "$path" "$expected" "$actual" "action: verification failed"
        return 1
    fi

    actual="owner ${actual_owner}:${actual_group}, mode ${actual_mode}"
    _vw_runtime_report FIXED "$label" "$path" "$expected" "$actual" "action: corrected and verified"
}

_vw_runtime_state_root() {
    local operation="$1" path="$2"
    local expected="directory mode 750" actual

    if [[ "$operation" == "repair" && ! -d "$path" ]]; then
        mkdir -p -- "$path" || {
            _vw_runtime_report ERROR "runtime state root" "$path" "$expected" "missing" "action: mkdir failed"
            return 1
        }
    fi
    if [[ ! -d "$path" || -L "$path" ]]; then
        _vw_runtime_report ERROR "runtime state root" "$path" "$expected" "missing or unsafe" \
            "fix: sudo utilities/repair-permissions.sh"
        return 1
    fi

    actual="mode $(_vw_runtime_mode "$path")"
    if [[ "$(_vw_runtime_mode "$path")" == "750" ]]; then
        _vw_runtime_report OK "runtime state root" "$path" "$expected" "$actual" "action: none"
        return 0
    fi
    if [[ "$operation" == "check" ]]; then
        _vw_runtime_report ERROR "runtime state root" "$path" "$expected" "$actual" \
            "fix: sudo utilities/repair-permissions.sh"
        return 1
    fi
    chmod 750 "$path" || {
        _vw_runtime_report ERROR "runtime state root" "$path" "$expected" "$actual" "action: chmod failed"
        return 1
    }
    [[ "$(_vw_runtime_mode "$path")" == "750" ]] || {
        _vw_runtime_report ERROR "runtime state root" "$path" "$expected" "mode $(_vw_runtime_mode "$path")" \
            "action: verification failed"
        return 1
    }
    _vw_runtime_report FIXED "runtime state root" "$path" "$expected" "mode 750" "action: corrected and verified"
}

# Return 0 when drift exists, 1 when the tree is clean, and 2 when the tree
# cannot be inspected completely.
_vw_runtime_tree_has_drift() {
    local path="$1" owner="$2" group="$3" dir_mode="$4" file_mode="$5"
    local match

    [[ "$(_vw_runtime_numeric_owner "$path")" == "${owner}:${group}" ]] || return 0
    [[ "$(_vw_runtime_mode "$path")" == "$dir_mode" ]] || return 0

    match="$(find "$path" -type d \( ! -uid "$owner" -o ! -gid "$group" -o ! -perm "$dir_mode" \) -print -quit)" \
        || return 2
    [[ -z "$match" ]] || return 0

    match="$(find "$path" -type f \( ! -uid "$owner" -o ! -gid "$group" -o ! -perm "$file_mode" \) -print -quit)" \
        || return 2
    [[ -z "$match" ]] || return 0

    return 1
}

_vw_runtime_manage_tree() {
    local operation="$1" path="$2" owner="$3" group="$4" dir_mode="$5" file_mode="$6" label="$7"
    local expected="owner ${owner}:${group}, directories ${dir_mode}, files ${file_mode}"
    local actual drift_rc=0

    if [[ "$operation" == "repair" && ! -d "$path" ]]; then
        mkdir -p -- "$path" || {
            _vw_runtime_report ERROR "$label" "$path" "$expected" "missing" "action: mkdir failed"
            return 1
        }
    fi
    if [[ ! -d "$path" || -L "$path" ]]; then
        _vw_runtime_report ERROR "$label" "$path" "$expected" "missing or unsafe" \
            "fix: sudo utilities/repair-permissions.sh"
        return 1
    fi

    actual="owner $(_vw_runtime_numeric_owner "$path"), mode $(_vw_runtime_mode "$path")"
    _vw_runtime_tree_has_drift "$path" "$owner" "$group" "$dir_mode" "$file_mode" || drift_rc=$?
    if (( drift_rc == 1 )); then
        _vw_runtime_report OK "$label" "$path" "$expected" "$actual" "action: none"
        return 0
    fi
    if (( drift_rc == 2 )); then
        _vw_runtime_report ERROR "$label" "$path" "$expected" "$actual" "action: inspection failed"
        return 1
    fi
    if [[ "$operation" == "check" ]]; then
        _vw_runtime_report ERROR "$label" "$path" "$expected" "$actual" \
            "fix: sudo utilities/repair-permissions.sh"
        return 1
    fi

    chown -R "${owner}:${group}" "$path" || {
        _vw_runtime_report ERROR "$label" "$path" "$expected" "$actual" "action: chown failed"
        return 1
    }
    find "$path" -type d -exec chmod "$dir_mode" {} + || {
        _vw_runtime_report ERROR "$label" "$path" "$expected" "$actual" "action: directory chmod failed"
        return 1
    }
    find "$path" -type f -exec chmod "$file_mode" {} + || {
        _vw_runtime_report ERROR "$label" "$path" "$expected" "$actual" "action: file chmod failed"
        return 1
    }

    drift_rc=0
    _vw_runtime_tree_has_drift "$path" "$owner" "$group" "$dir_mode" "$file_mode" || drift_rc=$?
    if (( drift_rc != 1 )); then
        actual="owner $(_vw_runtime_numeric_owner "$path"), mode $(_vw_runtime_mode "$path")"
        if (( drift_rc == 2 )); then
            _vw_runtime_report ERROR "$label" "$path" "$expected" "$actual" "action: verification inspection failed"
        else
            _vw_runtime_report ERROR "$label" "$path" "$expected" "$actual" "action: verification failed"
        fi
        return 1
    fi

    _vw_runtime_report FIXED "$label" "$path" "$expected" \
        "owner $(_vw_runtime_numeric_owner "$path"), mode $(_vw_runtime_mode "$path")" \
        "action: corrected and verified"
}

_vw_runtime_manage_file() {
    local operation="$1" path="$2" owner="$3" group="$4" mode="$5" label="$6"
    local expected="owner ${owner}:${group}, mode ${mode}" actual

    if [[ "$operation" == "repair" && ! -e "$path" ]]; then
        touch -- "$path" || {
            _vw_runtime_report ERROR "$label" "$path" "$expected" "missing" "action: touch failed"
            return 1
        }
    fi
    if [[ ! -f "$path" || -L "$path" ]]; then
        _vw_runtime_report ERROR "$label" "$path" "$expected" "missing or unsafe" \
            "fix: sudo utilities/repair-permissions.sh"
        return 1
    fi

    actual="owner $(_vw_runtime_numeric_owner "$path"), mode $(_vw_runtime_mode "$path")"
    if [[ "$(_vw_runtime_numeric_owner "$path")" == "${owner}:${group}" && "$(_vw_runtime_mode "$path")" == "$mode" ]]; then
        _vw_runtime_report OK "$label" "$path" "$expected" "$actual" "action: none"
        return 0
    fi
    if [[ "$operation" == "check" ]]; then
        _vw_runtime_report ERROR "$label" "$path" "$expected" "$actual" \
            "fix: sudo utilities/repair-permissions.sh"
        return 1
    fi

    chown "${owner}:${group}" "$path" || {
        _vw_runtime_report ERROR "$label" "$path" "$expected" "$actual" "action: chown failed"
        return 1
    }
    chmod "$mode" "$path" || {
        _vw_runtime_report ERROR "$label" "$path" "$expected" "$actual" "action: chmod failed"
        return 1
    }
    if [[ "$(_vw_runtime_numeric_owner "$path")" != "${owner}:${group}" || "$(_vw_runtime_mode "$path")" != "$mode" ]]; then
        _vw_runtime_report ERROR "$label" "$path" "$expected" \
            "owner $(_vw_runtime_numeric_owner "$path"), mode $(_vw_runtime_mode "$path")" \
            "action: verification failed"
        return 1
    fi
    _vw_runtime_report FIXED "$label" "$path" "$expected" \
        "owner ${owner}:${group}, mode ${mode}" "action: corrected and verified"
}

manage_runtime_state_permissions() {
    local operation="$1"
    local state_dir="${2:-${PROJECT_STATE_DIR:-/var/lib/vaultwarden}}"
    local puid="${3:-${PUID:-}}" pgid="${4:-${PGID:-}}"
    local project_root="${5:-${PROJECT_ROOT:-}}"
    local caddy_uid="${CADDY_UID:-2000}" caddy_gid="${CADDY_GID:-2000}"
    local backup_dir status=0 path required

    [[ "$operation" == "check" || "$operation" == "repair" ]] || {
        log_error "Unknown runtime permission operation: $operation"
        return 2
    }
    if (( EUID != 0 )); then
        log_error "Runtime permission check and repair require root for complete inspection."
        return 1
    fi
    if [[ -z "$puid" ]]; then
        puid="$(get_config_value "PUID" "" 2>/dev/null || true)"
    fi
    if [[ -z "$pgid" ]]; then
        pgid="$(get_config_value "PGID" "" 2>/dev/null || true)"
    fi
    if ! _vw_runtime_is_numeric_id "$puid" || ! _vw_runtime_is_numeric_id "$pgid"; then
        log_error "Runtime permission ownership requires numeric PUID:PGID."
        return 1
    fi

    backup_dir="${BACKUP_DIR:-$(get_config_value "BACKUP_DIR" "$state_dir/backups" 2>/dev/null || printf '%s/backups' "$state_dir")}"
    if [[ "$backup_dir" != /* ]]; then
        log_error "Runtime backup path must be absolute: $backup_dir"
        return 1
    fi

    _vw_runtime_state_root "$operation" "$state_dir" || return 1

    if [[ "$operation" == "repair" ]]; then
        install -d -m 700 -o root -g root "$state_dir/config" "$state_dir/secrets" || {
            log_error "Failed to create private runtime configuration directories."
            status=1
        }
    fi

    for path in \
        /etc/vaultwarden \
        /etc/vaultwarden/age-key.txt \
        /etc/vaultwarden/vaultwarden.env \
        /etc/vaultwarden/rclone.conf \
        "$state_dir/config" \
        "$state_dir/config/install.env" \
        "$state_dir/config/dr-manifest.env" \
        "$state_dir/secrets" \
        "$state_dir/secrets/secrets.yaml" \
        /run/vaultwarden-oci/managed-secrets \
        /run/vaultwarden-oci/secrets; do
        required=false
        case "$path" in
            "$state_dir/config"|"$state_dir/secrets") required=true ;;
        esac
        _vw_runtime_apply_known_path "$operation" "$path" "known configuration or secret path" "$required" || status=1
    done
    if [[ -d /run/vaultwarden-oci/secrets ]]; then
        while IFS= read -r -d '' path; do
            _vw_runtime_apply_known_path "$operation" "$path" "runtime Docker secret" || status=1
        done < <(find /run/vaultwarden-oci/secrets -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
    fi
    if [[ -n "$project_root" ]]; then
        for path in \
            "$project_root/.env" \
            "$project_root/.sops.yaml" \
            "$project_root/secrets" \
            "$project_root/secrets/secrets.yaml"; do
            _vw_runtime_apply_known_path "$operation" "$path" "repository configuration path" || status=1
        done
    fi

    _vw_runtime_manage_tree "$operation" "$state_dir/data" "$puid" "$pgid" 750 640 "Vaultwarden state" || status=1
    _vw_runtime_manage_tree "$operation" "$state_dir/logs/vaultwarden" "$puid" "$pgid" 750 640 "Vaultwarden logs" || status=1
    _vw_runtime_manage_tree "$operation" "$state_dir/logs/postfix" "$puid" "$pgid" 750 640 "Postfix logs" || status=1
    _vw_runtime_manage_tree "$operation" "$backup_dir" "$puid" "$pgid" 750 640 "Backup state" || status=1
    if [[ -d "$backup_dir" && ! -L "$backup_dir" ]]; then
        for path in db full emergency; do
            if [[ -L "$backup_dir/$path" ]]; then
                _vw_runtime_report ERROR "Backup ${path} state" "$backup_dir/$path" \
                    "directory owner ${puid}:${pgid}, mode 750" "unsafe symlink" \
                    "fix: replace the symlink with a real directory"
                status=1
            elif [[ "$operation" == "repair" ]]; then
                install -d -m 750 -o "$puid" -g "$pgid" "$backup_dir/$path" || {
                    _vw_runtime_report ERROR "Backup ${path} state" "$backup_dir/$path" \
                        "directory owner ${puid}:${pgid}, mode 750" "creation failed" \
                        "action: directory preparation failed"
                    status=1
                }
            elif [[ ! -d "$backup_dir/$path" ]]; then
                _vw_runtime_report ERROR "Backup ${path} state" "$backup_dir/$path" \
                    "required directory owner ${puid}:${pgid}, mode 750" "missing" \
                    "fix: sudo utilities/repair-permissions.sh"
                status=1
            fi
        done
    fi

    _vw_runtime_manage_tree "$operation" "$state_dir/caddy/data" "$caddy_uid" "$caddy_gid" 750 640 "Caddy runtime data" || status=1
    _vw_runtime_manage_tree "$operation" "$state_dir/caddy/config" "$caddy_uid" "$caddy_gid" 750 640 "Caddy runtime config" || status=1
    _vw_runtime_manage_tree "$operation" "$state_dir/logs/caddy" "$caddy_uid" "$caddy_gid" 750 640 "Caddy logs" || status=1
    _vw_runtime_manage_file "$operation" "$state_dir/logs/caddy/access.log" "$caddy_uid" "$caddy_gid" 640 "Caddy access log" || status=1
    _vw_runtime_manage_file "$operation" "$state_dir/logs/caddy/security.log" "$caddy_uid" "$caddy_gid" 640 "Caddy security log" || status=1

    return "$status"
}

check_runtime_state_permissions() {
    manage_runtime_state_permissions check "$@"
}

repair_runtime_state_permissions() {
    manage_runtime_state_permissions repair "$@"
}
