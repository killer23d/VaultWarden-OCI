#!/usr/bin/env bash
# Storage helpers for boot-volume and separate-volume installs.
# Source after lib/common.sh in operational scripts so writes fail closed when
# the configured data volume is missing.

[[ -n "${VAULTWARDEN_STORAGE_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_STORAGE_LIB_LOADED=1

# Do NOT set -euo pipefail here — callers own their shell options.
# Entry-point scripts apply these options via init_common_lib(); this library
# is always sourced after that call.

# ---------------------------------------------------------------------------
# _storage_validate_paths
#
# Internal helper. Validates DATA_VOLUME_DEVICE and DATA_VOLUME_MOUNT contain
# only safe characters before they are used in shell commands or written to
# system files. Called by every public function that operates in
# separate-volume mode.
#
# Arguments:
#   $1 — device path   (DATA_VOLUME_DEVICE; pass "" to skip device check)
#   $2 — mount point   (DATA_VOLUME_MOUNT;  pass "" to skip mount check)
#
# Returns 0 if all checks pass; 1 with a log_error on first failure.
# ---------------------------------------------------------------------------
_storage_validate_paths() {
    local device="$1"
    local mount_point="$2"

    # Pattern: /dev/ followed by an alphanumeric character, then zero or more
    # alphanumerics, forward slashes, hyphens, or underscores, with no
    # consecutive slashes and no trailing slash.
    # Accepts: /dev/sdb  /dev/nvme0n1  /dev/disk/by-id/scsi-0abc123
    # Rejects: /dev/  /dev///sdb  /dev/sdb;rm -rf /
    if [[ -n "$device" ]] \
        && { [[ ! "$device" =~ ^/dev/[a-zA-Z0-9][a-zA-Z0-9/_-]*[a-zA-Z0-9]$|^/dev/[a-zA-Z0-9]$ ]] \
             || [[ "$device" == *//* ]]; }; then
        log_error "DATA_VOLUME_DEVICE contains disallowed characters or path structure: $device"
        log_error "Allowed pattern: /dev/<alphanumeric start and end; no consecutive slashes>"
        log_error "Examples: /dev/sdb  /dev/nvme0n1  /dev/disk/by-id/scsi-0abc"
        return 1
    fi

    if [[ -n "$mount_point" && ! "$mount_point" =~ ^/[a-zA-Z0-9/_-]+$ ]]; then
        log_error "DATA_VOLUME_MOUNT contains disallowed characters: $mount_point"
        log_error "Allowed pattern: /<alphanumeric, _, - and / only>"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# _storage_daemon_reload
#
# Internal helper. Runs 'systemctl daemon-reload' and logs a warning on
# failure rather than silently swallowing the error with '|| true'.
# Failure is non-fatal: the caller's unit change is written to disk; the
# in-memory unit graph will reflect it after the next reboot.
# ---------------------------------------------------------------------------
_storage_daemon_reload() {
    systemctl daemon-reload 2>/dev/null \
        || log_warn "systemctl daemon-reload failed — a reboot may be required to apply unit changes"
}

# ---------------------------------------------------------------------------
# require_project_state_ready
#
# Gate function called near the top of every operational script. Ensures the
# data storage layer is in the expected state before any work begins.
#
# Boot-only mode (DATA_VOLUME_DEVICE blank):
#   Creates PROJECT_STATE_DIR if absent, then returns 0.
#
# Separate-volume mode (DATA_VOLUME_DEVICE set):
#   Runs five ordered checks and fails closed on the first failure:
#   1. Path safety        — device and mount point contain only safe characters.
#   2. Config consistency — PROJECT_STATE_DIR must equal DATA_VOLUME_MOUNT.
#   3. Block device       — DATA_VOLUME_DEVICE must be a real block device.
#   4. Mounted            — DATA_VOLUME_MOUNT must be currently active.
#   5. Sentinel           — .vw-data-volume must exist on the mount (written by
#                           setup_data_volume; prevents treating any arbitrary
#                           mountpoint as the data volume).
#   Then creates PROJECT_STATE_DIR if absent (idempotent).
#
# Returns 0 on success, 1 on any failure. Callers should treat 1 as fatal.
# ---------------------------------------------------------------------------
require_project_state_ready() {
    local state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    local data_device="${DATA_VOLUME_DEVICE:-}"
    local data_mount="${DATA_VOLUME_MOUNT:-/mnt/vw-data}"

    # Boot-only mode
    if [[ -z "$data_device" ]]; then
        # Creating PROJECT_STATE_DIR may require root (e.g. under /var/lib).
        is_root || { log_error "require_project_state_ready: must be run as root"; return 1; }
        # install -d -m applies the mode atomically, bypassing umask and
        # avoiding the chmod-after-mkdir race window.
        install -d -m 750 "$state_dir" 2>/dev/null || {
            log_error "require_project_state_ready: cannot create PROJECT_STATE_DIR: $state_dir"
            return 1
        }
        return 0
    fi

    # Separate-volume mode

    # 1. Path safety.
    _storage_validate_paths "$data_device" "$data_mount" || return 1

    # 2. Configuration consistency: PROJECT_STATE_DIR must equal DATA_VOLUME_MOUNT.
    if [[ "$state_dir" != "$data_mount" ]]; then
        log_error "Storage configuration mismatch:"
        log_error "  PROJECT_STATE_DIR='$state_dir'"
        log_error "  DATA_VOLUME_MOUNT='$data_mount'"
        log_error "When DATA_VOLUME_DEVICE is set, PROJECT_STATE_DIR MUST equal DATA_VOLUME_MOUNT."
        log_error "Fix: set PROJECT_STATE_DIR=$data_mount in .env"
        return 1
    fi

    # 3. DATA_VOLUME_DEVICE must be a block device.
    if [[ ! -b "$data_device" ]]; then
        log_error "DATA_VOLUME_DEVICE is not a block device: $data_device"
        log_error "Check .env or verify that the data disk is attached to this instance."
        return 1
    fi

    # 4. DATA_VOLUME_MOUNT must currently be mounted.
    if ! mountpoint -q "$data_mount" 2>/dev/null; then
        log_error "Expected data volume is NOT mounted: $data_mount"
        log_error "Refusing to continue — writing VaultWarden data onto the boot volume"
        log_error "would silently corrupt your persistent state."
        log_error "Remediation:"
        log_error "  sudo mount $data_mount"
        log_error "  (or check /etc/fstab and: sudo systemctl daemon-reload)"
        return 1
    fi

    # 5. Sentinel file confirms mount identity (written by setup_data_volume).
    if [[ ! -f "$data_mount/.vw-data-volume" ]]; then
        log_error "Data volume sentinel missing: $data_mount/.vw-data-volume"
        log_error "The filesystem at $data_mount cannot be positively identified"
        log_error "as the VaultWarden data volume. Refusing to continue."
        log_error "Remediation (only if this IS the correct data disk):"
        log_error "  sudo touch $data_mount/.vw-data-volume"
        return 1
    fi

    is_root || { log_error "require_project_state_ready: must be run as root"; return 1; }
    install -d -m 750 "$state_dir" 2>/dev/null || {
        log_error "require_project_state_ready: cannot create PROJECT_STATE_DIR: $state_dir"
        return 1
    }

    return 0
}

# ---------------------------------------------------------------------------
# setup_data_volume
#
# Provisions the dedicated data volume when DATA_VOLUME_DEVICE is set.
# Idempotent: every step checks current on-disk state before acting.
# Called only by setup.sh. Requires root.
#
# Steps performed (each skipped if already complete):
#   1. Validates device path safety and block-device existence.
#   2. Formats the device as ext4 only if no filesystem is present.
#      Refuses to format if the device is currently mounted under any path.
#      Refuses to overwrite any non-ext4 filesystem.
#   3. Creates the mount point directory.
#   4. Adds a UUID-based fstab entry and runs daemon-reload.
#   5. Mounts the volume if not already mounted.
#   6. Writes a read-only sentinel file that identifies the volume.
# ---------------------------------------------------------------------------
setup_data_volume() {
    local device="${DATA_VOLUME_DEVICE:-}"
    local mount_point="${DATA_VOLUME_MOUNT:-/mnt/vw-data}"
    local dry_run="${DRY_RUN:-false}"

    case "${dry_run,,}" in
        true|1|yes)  dry_run="true" ;;
        false|0|no|"") dry_run="false" ;;
        *)
            log_warn "DRY_RUN='${DRY_RUN:-}' is not recognised (valid: true/false) — treating as false (live run)"
            dry_run="false"
            ;;
    esac

    if [[ -z "$device" ]]; then
        log_info "DATA_VOLUME_DEVICE not set — skipping data volume provisioning (boot-only mode)"
        return 0
    fi

    if [[ "$dry_run" == "true" ]]; then
        log_info "[DRY RUN] Would provision data volume: $device → $mount_point"
        return 0
    fi

    # 1. Path safety and block-device check.
    _storage_validate_paths "$device" "$mount_point" || return 1

    if [[ ! -b "$device" ]]; then
        log_error "DATA_VOLUME_DEVICE is not a block device: $device"
        return 1
    fi

    # 2. Format only if blank (idempotent).
    local fs_type
    fs_type=$(blkid -o value -s TYPE "$device" 2>/dev/null || true)

    if [[ -z "$fs_type" ]]; then
        # Refuse to format a device that is currently mounted under any path.
        # Use awk to extract the first field (device column) so that a device
        # path that is a prefix of another (e.g. /dev/sdb vs /dev/sdba) does
        # not produce a false match.
        if mountpoint -q "$mount_point" 2>/dev/null \
            || awk '{print $1}' /proc/mounts 2>/dev/null | grep -qxF "$device"; then
            log_error "Refusing to format $device — it is currently mounted."
            log_error "Unmount it first, then re-run setup: sudo umount $mount_point"
            return 1
        fi
        # Sanity-check device size before formatting.
        # Minimum: 1 GiB (1073741824 bytes). A smaller device almost certainly
        # means the wrong block device was specified in DATA_VOLUME_DEVICE.
        local _dev_bytes
        _dev_bytes=$(lsblk --nodeps --noheadings --bytes --output SIZE "$device" 2>/dev/null \
                     | tr -d '[:space:]') || true
        if [[ -z "$_dev_bytes" || ! "$_dev_bytes" =~ ^[0-9]+$ ]]; then
            log_error "Cannot determine size of $device (lsblk failed or returned non-numeric output)."
            log_error "Verify the device is attached and DATA_VOLUME_DEVICE is correct."
            return 1
        fi
        if (( _dev_bytes < 1073741824 )); then
            log_error "Device $device is too small: ${_dev_bytes} bytes (< 1 GiB minimum)."
            log_error "A device this small almost certainly means DATA_VOLUME_DEVICE is wrong."
            log_error "Verify the correct block device with: lsblk"
            return 1
        fi
        log_info "Device size: $(( _dev_bytes / 1073741824 )) GiB — proceeding with format."
        log_info "No filesystem found on $device — formatting as ext4..."
        log_warn "ALL DATA ON $device WILL BE ERASED. This is expected on first run."
        local mkfs_out
        mkfs_out=$(mkfs.ext4 -F -L vw-data "$device" 2>&1) || {
            log_error "mkfs.ext4 failed for $device: $mkfs_out"
            return 1
        }
        log_success "Formatted $device as ext4 (label: vw-data)"
    elif [[ "$fs_type" == "ext4" || "$fs_type" == "xfs" ]]; then
        log_info "Existing $fs_type filesystem on $device — skipping format (idempotent)"
    else
        log_error "Unexpected filesystem '$fs_type' on $device. Refusing to overwrite."
        log_error "To use a different device, update DATA_VOLUME_DEVICE in .env and re-run setup."
        return 1
    fi

    # 3. Create mount point (idempotent).
    [[ -d "$mount_point" ]] || mkdir -p "$mount_point" \
        || { log_error "Cannot create mount point: $mount_point"; return 1; }
    chmod 755 "$mount_point"

    # 4. fstab entry (UUID-based, idempotent).
    #    noatime                      — suppress atime writes; reduces I/O on SQLite data files.
    #    nofail                       — boot proceeds if the volume is absent (avoids
    #                                   emergency-mode boot on temporary disk detachment).
    #    x-systemd.device-timeout=30s — bounds how long systemd waits for the block device;
    #                                   prevents indefinite boot stalls on OCI instances where
    #                                   the volume attachment may race the kernel.
    local dev_uuid
    dev_uuid=$(blkid -o value -s UUID "$device" 2>/dev/null || true)
    [[ -n "$dev_uuid" ]] \
        || { log_error "Cannot determine UUID for $device — cannot write a safe fstab entry"; return 1; }

    if ! grep -qF "UUID=$dev_uuid" /etc/fstab 2>/dev/null; then
        # Write to a temp file on the same filesystem, validate it has content,
        # then atomically replace /etc/fstab. This avoids leaving a truncated
        # fstab behind if the process is killed mid-write.
        local fstab_tmp
        fstab_tmp=$(mktemp /etc/fstab.vw-XXXXXX) \
            || { log_error "Cannot create fstab temp file"; return 1; }
        chmod 644 "$fstab_tmp"
        if ! cp /etc/fstab "$fstab_tmp"; then
            rm -f "$fstab_tmp"
            log_error "Cannot copy /etc/fstab to temp file"
            return 1
        fi
        printf 'UUID=%s\t%s\text4\tnoatime,nofail,x-systemd.device-timeout=30s\t0\t2\n' \
            "$dev_uuid" "$mount_point" >> "$fstab_tmp" \
            || { rm -f "$fstab_tmp"; log_error "Failed to append new entry to fstab temp file"; return 1; }
        if ! mv -- "$fstab_tmp" /etc/fstab; then
            rm -f "$fstab_tmp"
            log_error "Failed to atomically replace /etc/fstab"
            return 1
        fi
        log_success "fstab entry added (UUID=$dev_uuid, mount: $mount_point)"
        _storage_daemon_reload
    else
        log_info "fstab entry already present for UUID=$dev_uuid (idempotent)"
    fi

    # 5. Mount (idempotent).
    if mountpoint -q "$mount_point" 2>/dev/null; then
        log_info "$mount_point already mounted (idempotent)"
    else
        mount "$mount_point" \
            || { log_error "mount failed for $mount_point — check /etc/fstab"; return 1; }
        log_success "Mounted $device at $mount_point"
    fi

    # 6. Sentinel file (idempotent, read-only, immutable where supported).
    #    The sentinel is the only positive proof that a given mountpoint IS the
    #    VaultWarden data volume. Making it immutable with chattr +i protects it
    #    from accidental rm -rf on the mount root while preserving the guard in
    #    require_project_state_ready. The uninstaller runs chattr -i before wipe.
    local sentinel="$mount_point/.vw-data-volume"
    if [[ ! -f "$sentinel" ]]; then
        # Write to a temp file first so a crash mid-write never leaves a
        # zero-byte or partial sentinel that would silently pass the guard check.
        local sentinel_tmp
        sentinel_tmp=$(mktemp "$mount_point/vw-data-volume-tmp.XXXXXX") \
            || { log_error "Failed to create temp file for sentinel: $mount_point"; return 1; }
        printf 'VaultWarden-OCI data volume\nDevice: %s\nMounted: %s\nCreated: %s\n' \
            "$device" "$mount_point" "$(date -Iseconds)" > "$sentinel_tmp" \
            || { rm -f "$sentinel_tmp"; log_error "Failed to write sentinel temp file"; return 1; }
        chmod 444 "$sentinel_tmp"
        if ! mv -- "$sentinel_tmp" "$sentinel"; then
            rm -f "$sentinel_tmp"
            log_error "Failed to move sentinel into place: $sentinel"
            return 1
        fi
        if command -v chattr >/dev/null 2>&1; then
            chattr +i "$sentinel" 2>/dev/null \
                || log_warn "chattr +i failed on sentinel — immutability not set (non-fatal; sentinel is still 444)"
        fi
        log_success "Sentinel written and protected: $sentinel"
    else
        log_info "Sentinel already present (idempotent): $sentinel"
    fi

    log_success "Data volume ready: $device → $mount_point"
    return 0
}

# ---------------------------------------------------------------------------
# install_docker_mount_guard
#
# Installs or removes a Docker systemd drop-in that adds:
#   RequiresMountsFor=<DATA_VOLUME_MOUNT>
# to docker.service, preventing Docker from starting before the data volume
# is mounted.
#
# Idempotent. Called only by setup.sh. Requires root.
#
# When DATA_VOLUME_DEVICE is blank: removes any existing drop-in (cleanup
# after a revert from separate-volume to boot-only mode).
# When DATA_VOLUME_DEVICE is set: installs or updates the drop-in.
# ---------------------------------------------------------------------------
install_docker_mount_guard() {
    local drop_in_dir="/etc/systemd/system/docker.service.d"
    local drop_in_file="$drop_in_dir/10-vaultwarden-data-volume.conf"
    local dry_run="${DRY_RUN:-false}"

    case "${dry_run,,}" in
        true|1|yes)  dry_run="true" ;;
        false|0|no|"") dry_run="false" ;;
        *)
            log_warn "DRY_RUN='${DRY_RUN:-}' is not recognised (valid: true/false) — treating as false (live run)"
            dry_run="false"
            ;;
    esac

    # Cleanup path (reverting to boot-only mode)
    if [[ -z "${DATA_VOLUME_DEVICE:-}" ]]; then
        if [[ -f "$drop_in_file" ]]; then
            log_info "DATA_VOLUME_DEVICE cleared — removing stale Docker mount guard"
            rm -f "$drop_in_file" \
                || { log_error "Failed to remove Docker mount guard: $drop_in_file"; return 1; }
            _storage_daemon_reload
        else
            log_info "DATA_VOLUME_DEVICE not set — Docker mount guard not needed"
        fi
        return 0
    fi

    if [[ "$dry_run" == "true" ]]; then
        log_info "[DRY RUN] Would install Docker mount guard for: ${DATA_VOLUME_MOUNT:-/mnt/vw-data}"
        return 0
    fi

    # Install path
    local mount_point="${DATA_VOLUME_MOUNT:-/mnt/vw-data}"
    _storage_validate_paths "" "$mount_point" || return 1

    mkdir -p "$drop_in_dir" \
        || { log_error "Cannot create systemd drop-in dir: $drop_in_dir"; return 1; }

    # Derive the systemd mount unit name from the mount path.
    # systemd-escape --path --suffix=mount converts e.g. /mnt/vw-data
    # to mnt-vw\x2ddata.mount — the canonical unit name systemd tracks.
    local mount_unit
    mount_unit=$(systemd-escape --path --suffix=mount "$mount_point" 2>/dev/null) || {
        log_error "systemd-escape failed for mount point: $mount_point"
        log_error "Ensure systemd-escape is available (package: systemd)"
        return 1
    }

    # Idempotency: skip only when BOTH directives encode the CURRENT mount unit.
    # A file that references an old mount unit (e.g. after the operator renamed
    # DATA_VOLUME_MOUNT) must be regenerated, so we match the exact unit name.
    if [[ -f "$drop_in_file" ]] \
        && grep -qF "RequiresMountsFor=$mount_point" "$drop_in_file" 2>/dev/null \
        && grep -qF "After=$mount_unit"              "$drop_in_file" 2>/dev/null; then
        log_info "Docker mount guard already up to date for $mount_point (idempotent)"
        return 0
    fi

    {
        printf '# Managed by VaultWarden-OCI setup.sh — do not edit by hand.\n'
        printf '# Ensures Docker never starts before the data volume is mounted.\n'
        printf '# Regenerate: sudo ./setup.sh systemd install\n'
        printf '[Unit]\n'
        printf 'After=%s\n'              "$mount_unit"
        printf 'RequiresMountsFor=%s\n'  "$mount_point"
    } > "$drop_in_file" \
        || { log_error "Failed to write Docker mount guard: $drop_in_file"; return 1; }

    chmod 644 "$drop_in_file"
    _storage_daemon_reload
    log_success "Docker mount guard installed: $drop_in_file"
    return 0
}

# ---------------------------------------------------------------------------
# vw_default_backup_dir
#
# Returns the default base directory for backups, derived from
# PROJECT_STATE_DIR. Keeps backups co-located with VaultWarden data
# regardless of storage mode (boot-only or separate-volume) without
# requiring the operator to explicitly set BACKUP_DIR.
#
# Callers use this value only when BACKUP_DIR is absent from .env; an
# explicit BACKUP_DIR always takes precedence.
# ---------------------------------------------------------------------------
vw_default_backup_dir() {
    local state_dir
    # get_config_value is provided by lib/common.sh. Fall back to the
    # compile-time default if the function is not yet available (e.g. when
    # storage.sh is sourced in isolation during unit tests).
    if declare -f get_config_value >/dev/null 2>&1; then
        state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    else
        state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    fi
    printf '%s/backups' "$state_dir"
}
