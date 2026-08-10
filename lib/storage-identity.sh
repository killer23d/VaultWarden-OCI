#!/usr/bin/env bash
# Filesystem identity proof for dedicated VaultWarden data volumes.
# Loaded by lib/storage.sh after its core function definitions.

readonly VW_STORAGE_IDENTITY_FORMAT=1
readonly VW_STORAGE_IDENTITY_SIGNATURE="VaultWarden-OCI-data-volume"

_storage_identity_mount_facts() {
    local mount_point="$1" source uuid target

    [[ -d "$mount_point" && ! -L "$mount_point" ]] || {
        log_error "Data volume mount target is missing or is a symlink: $mount_point"
        return 1
    }
    mountpoint -q "$mount_point" 2>/dev/null || {
        log_error "Expected data volume is not mounted: $mount_point"
        return 1
    }

    source="$(findmnt -n -o SOURCE --target "$mount_point" 2>/dev/null || true)"
    target="$(findmnt -n -o TARGET --target "$mount_point" 2>/dev/null || true)"
    uuid="$(findmnt -n -o UUID --target "$mount_point" 2>/dev/null || true)"
    [[ -n "$uuid" ]] || uuid="$(blkid -s UUID -o value "$source" 2>/dev/null || true)"

    [[ -n "$source" && -n "$uuid" && "$target" == "$mount_point" ]] || {
        log_error "Cannot prove the filesystem mounted at $mount_point."
        log_error "Run: findmnt --target $mount_point"
        return 1
    }

    printf '%s\n%s\n%s\n' "$source" "$uuid" "$target"
}

_storage_identity_device_uuid() {
    local device="$1" uuid
    [[ -b "$device" ]] || {
        log_error "DATA_VOLUME_DEVICE is not a block device: $device"
        return 1
    }
    uuid="$(blkid -s UUID -o value "$device" 2>/dev/null || true)"
    [[ -n "$uuid" ]] || {
        log_error "Cannot determine filesystem UUID for configured data device: $device"
        return 1
    }
    printf '%s\n' "$uuid"
}

_storage_identity_field() {
    local marker="$1" key="$2"
    awk -F= -v wanted="$key" '
        $1 == wanted {
            if (++count > 1) exit 2
            print substr($0, index($0, "=") + 1)
        }
        END { if (count != 1) exit 1 }
    ' "$marker"
}

_storage_identity_read_mount_facts() {
    local mount_point="$1" facts
    facts="$(_storage_identity_mount_facts "$mount_point")" || return 1
    printf '%s\n' "$facts"
}

storage_validate_volume_identity() {
    local mount_point="${1:-${DATA_VOLUME_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}}"
    local device="${2:-${DATA_VOLUME_DEVICE:-}}"
    local marker="$mount_point/.vw-data-volume"
    local facts source mounted_uuid target device_uuid
    local signature format marker_uuid marker_target marker_device created_at operation
    local owner group mode links line_count

    _storage_validate_paths "$device" "$mount_point" || return 1
    [[ -n "$device" ]] || {
        log_error "Storage identity validation requires a configured data device."
        return 1
    }

    facts="$(_storage_identity_read_mount_facts "$mount_point")" || return 1
    source="$(sed -n '1p' <<< "$facts")"
    mounted_uuid="$(sed -n '2p' <<< "$facts")"
    target="$(sed -n '3p' <<< "$facts")"
    [[ -n "$source" && -n "$mounted_uuid" && "$target" == "$mount_point" ]] || return 1

    device_uuid="$(_storage_identity_device_uuid "$device")" || return 1
    if [[ "$device_uuid" != "$mounted_uuid" ]]; then
        log_error "Wrong filesystem mounted at $mount_point."
        log_error "  configured UUID: $device_uuid"
        log_error "  mounted UUID:    $mounted_uuid"
        return 1
    fi

    [[ -e "$marker" ]] || {
        log_error "Data volume identity marker is missing: $marker"
        log_error "Repair only after proving the disk: sudo utilities/setup-storage.sh setup --data-device $device"
        return 1
    }
    [[ ! -L "$marker" && -f "$marker" && -s "$marker" ]] || {
        log_error "Data volume identity marker is empty, non-regular, or a symlink: $marker"
        return 1
    }

    owner="$(stat -c '%u' "$marker" 2>/dev/null || true)"
    group="$(stat -c '%g' "$marker" 2>/dev/null || true)"
    mode="$(stat -c '%a' "$marker" 2>/dev/null || true)"
    links="$(stat -c '%h' "$marker" 2>/dev/null || true)"
    [[ "$owner" == 0 && "$group" == 0 && "$mode" == 444 && "$links" == 1 ]] || {
        log_error "Unsafe data volume identity marker ownership/mode/link count: $marker (uid=$owner gid=$group mode=$mode links=$links; expected root:root 444 links=1)"
        return 1
    }

    line_count="$(wc -l < "$marker" | tr -d '[:space:]')"
    [[ "$line_count" == 7 ]] || {
        log_error "Malformed data volume identity marker: $marker"
        return 1
    }

    signature="$(_storage_identity_field "$marker" SIGNATURE)" || { log_error "Malformed data volume identity marker signature."; return 1; }
    format="$(_storage_identity_field "$marker" FORMAT)" || { log_error "Malformed data volume identity marker format."; return 1; }
    marker_uuid="$(_storage_identity_field "$marker" FILESYSTEM_UUID)" || { log_error "Malformed data volume identity marker UUID."; return 1; }
    marker_target="$(_storage_identity_field "$marker" MOUNT_TARGET)" || { log_error "Malformed data volume identity marker target."; return 1; }
    marker_device="$(_storage_identity_field "$marker" DEVICE_CONTEXT)" || { log_error "Malformed data volume identity marker device context."; return 1; }
    created_at="$(_storage_identity_field "$marker" CREATED_AT)" || { log_error "Malformed data volume identity marker creation time."; return 1; }
    operation="$(_storage_identity_field "$marker" OPERATION)" || { log_error "Malformed data volume identity marker operation."; return 1; }

    [[ "$signature" == "$VW_STORAGE_IDENTITY_SIGNATURE" && "$format" == "$VW_STORAGE_IDENTITY_FORMAT" ]] || {
        log_error "Unrecognized data volume identity marker: $marker"
        return 1
    }
    [[ "$marker_uuid" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ && "$marker_uuid" == "$mounted_uuid" ]] || {
        log_error "Data volume identity marker does not match the mounted filesystem UUID."
        return 1
    }
    [[ "$marker_target" == "$mount_point" ]] || {
        log_error "Data volume identity marker was created for a different mount target: $marker_target"
        return 1
    }
    _storage_validate_paths "$marker_device" "$marker_target" || {
        log_error "Malformed data volume identity marker path metadata: $marker"
        return 1
    }
    [[ "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ && "$operation" =~ ^(setup|adopt|recover|migrate|repair)$ ]] || {
        log_error "Malformed data volume identity marker metadata: $marker"
        return 1
    }

    return 0
}

storage_write_volume_identity() {
    local mount_point="${1:-${DATA_VOLUME_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}}"
    local device="${2:-${DATA_VOLUME_DEVICE:-}}"
    local operation="${3:-setup}"
    local marker="$mount_point/.vw-data-volume" tmp
    local facts source mounted_uuid target device_uuid

    _storage_validate_paths "$device" "$mount_point" || return 1
    [[ "$operation" =~ ^(setup|adopt|recover|migrate|repair)$ ]] || {
        log_error "Invalid storage identity operation: $operation"
        return 1
    }

    facts="$(_storage_identity_read_mount_facts "$mount_point")" || return 1
    source="$(sed -n '1p' <<< "$facts")"
    mounted_uuid="$(sed -n '2p' <<< "$facts")"
    target="$(sed -n '3p' <<< "$facts")"
    [[ -n "$source" && -n "$mounted_uuid" && "$target" == "$mount_point" ]] || return 1

    device_uuid="$(_storage_identity_device_uuid "$device")" || return 1
    if [[ "$device_uuid" != "$mounted_uuid" ]]; then
        log_error "Refusing to write data volume identity: configured device UUID does not match the filesystem mounted at $mount_point."
        return 1
    fi

    if storage_validate_volume_identity "$mount_point" "$device" >/dev/null 2>&1; then
        log_info "Data volume identity already valid: $marker"
        return 0
    fi

    if [[ -e "$marker" || -L "$marker" ]]; then
        if [[ -L "$marker" || ! -f "$marker" ]]; then
            log_error "Refusing to replace non-regular or symlinked data volume identity marker: $marker"
            return 1
        fi
        local marker_links
        marker_links="$(stat -c '%h' "$marker" 2>/dev/null || true)"
        [[ "$marker_links" == 1 ]] || {
            log_error "Refusing to replace multiply-linked data volume identity marker: $marker (links=$marker_links)"
            return 1
        }
    fi

    if [[ -e "$marker" ]] && command -v chattr >/dev/null 2>&1; then
        chattr -i "$marker" 2>/dev/null || true
    fi

    tmp="$(mktemp "$mount_point/.vw-data-volume.tmp.XXXXXX")" || {
        log_error "Failed to create temporary data volume identity marker under $mount_point"
        return 1
    }
    if ! printf 'SIGNATURE=%s\nFORMAT=%s\nFILESYSTEM_UUID=%s\nMOUNT_TARGET=%s\nDEVICE_CONTEXT=%s\nCREATED_AT=%s\nOPERATION=%s\n' \
        "$VW_STORAGE_IDENTITY_SIGNATURE" "$VW_STORAGE_IDENTITY_FORMAT" "$mounted_uuid" "$mount_point" "$device" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$operation" > "$tmp"; then
        rm -f "$tmp"
        log_error "Failed to write data volume identity marker."
        return 1
    fi

    chmod 0444 "$tmp" || { rm -f "$tmp"; return 1; }
    chown root:root "$tmp" || {
        rm -f "$tmp"
        log_error "Failed to set root ownership on data volume identity marker."
        return 1
    }
    mv -f -- "$tmp" "$marker" || {
        rm -f "$tmp"
        log_error "Failed to atomically publish data volume identity marker."
        return 1
    }
    if command -v chattr >/dev/null 2>&1; then
        chattr +i "$marker" 2>/dev/null || log_warn "chattr +i failed on data volume identity marker; read-only ownership checks remain active."
    fi

    storage_validate_volume_identity "$mount_point" "$device" || {
        log_error "New data volume identity marker failed validation: $marker"
        return 1
    }
    log_success "Data volume identity recorded for filesystem UUID $mounted_uuid at $mount_point"
}
