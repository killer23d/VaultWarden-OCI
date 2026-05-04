#!/usr/bin/env bash
# lib/storage.sh — Storage-mode helpers for VaultWarden-OCI
#
# Supports two storage modes:
#   Boot-only:       DATA_VOLUME_DEVICE= (blank)  — default, no extra action
#   Separate-volume: DATA_VOLUME_DEVICE=/dev/sdX   — data volume must be mounted
#
# Source this library after lib/common.sh in every operational script:
#   setup.sh  startup.sh  backup.sh  restore.sh  maintenance.sh
#
# Public API:
#   require_project_state_ready  — guard called early in every script; fails
#                                  closed if the expected data volume is absent.
#   setup_data_volume            — provisions the volume (setup.sh only).
#   install_docker_mount_guard   — installs/removes Docker systemd drop-in
#                                  (setup.sh only).

[[ -n "${VAULTWARDEN_STORAGE_LIB_LOADED:-}" ]] && return 0
set -euo pipefail
readonly VAULTWARDEN_STORAGE_LIB_LOADED=1

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

    if [[ -n "$device" && ! "$device" =~ ^/dev/[a-zA-Z0-9/]+$ ]]; then
        log_error "DATA_VOLUME_DEVICE contains disallowed characters: $device"
        log_error "Allowed pattern: /dev/<alphanumeric and / only>"
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

    # ── Boot-only mode ────────────────────────────────────────────────────
    if [[ -z "$data_device" ]]; then
        mkdir -p "$state_dir" 2>/dev/null || {
            log_error "require_project_state_ready: cannot create PROJECT_STATE_DIR: $state_dir"
            return 1
        }
        return 0
    fi

    # ── Separate-volume mode ──────────────────────────────────────────────

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

    # Ensure PROJECT_STATE_DIR exists (idempotent).
    mkdir -p "$state_dir" 2>/dev/null || {
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
        if mountpoint -q "$mount_point" 2>/dev/null \
            || grep -qF "$device" /proc/mounts 2>/dev/null; then
            log_error "Refusing to format $device — it is currently mounted."
            log_error "Unmount it first, then re-run setup: sudo umount $mount_point"
            return 1
        fi
        log_info "No filesystem found on $device — formatting as ext4..."
        log_warn "ALL DATA ON $device WILL BE ERASED. This is expected on first run."
        local mkfs_out
        mkfs_out=$(mkfs.ext4 -F -L vw-data "$device" 2>&1) || {
            log_error "mkfs.ext4 failed for $device: $mkfs_out"
            return 1
        }
        log_success "Formatted $device as ext4 (label: vw-data)"
    elif [[ "$fs_type" == "ext4" ]]; then
        log_info "Existing ext4 filesystem on $device — skipping format (idempotent)"
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
        printf 'UUID=%s\t%s\text4\tnoatime,nofail,x-systemd.device-timeout=30s\t0\t2\n' \
            "$dev_uuid" "$mount_point" >> /etc/fstab \
            || { log_error "Failed to append to /etc/fstab"; return 1; }
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

    # 6. Sentinel file (idempotent, read-only).
    local sentinel="$mount_point/.vw-data-volume"
    if [[ ! -f "$sentinel" ]]; then
        printf 'VaultWarden-OCI data volume\nDevice: %s\nMounted: %s\nCreated: %s\n' \
            "$device" "$mount_point" "$(date -Iseconds)" > "$sentinel" \
            || { log_error "Failed to write sentinel: $sentinel"; return 1; }
        chmod 444 "$sentinel"
        log_success "Sentinel written: $sentinel"
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

    # ── Cleanup path (reverting to boot-only mode) ────────────────────────
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

    # ── Install path ──────────────────────────────────────────────────────
    local mount_point="${DATA_VOLUME_MOUNT:-/mnt/vw-data}"
    _storage_validate_paths "" "$mount_point" || return 1

    mkdir -p "$drop_in_dir" \
        || { log_error "Cannot create systemd drop-in dir: $drop_in_dir"; return 1; }

    # Idempotency: skip if the file already encodes the current mount point.
    if [[ -f "$drop_in_file" ]] \
        && grep -qF "RequiresMountsFor=$mount_point" "$drop_in_file" 2>/dev/null; then
        log_info "Docker mount guard already installed for $mount_point (idempotent)"
        return 0
    fi

    # Write drop-in (overwrites stale entry if mount point changed).
    {
        printf '# Managed by VaultWarden-OCI setup.sh — do not edit by hand.\n'
        printf '# Ensures Docker never starts before the data volume is mounted.\n'
        printf '[Unit]\n'
        printf 'RequiresMountsFor=%s\n' "$mount_point"
    } > "$drop_in_file" \
        || { log_error "Failed to write Docker mount guard: $drop_in_file"; return 1; }

    chmod 644 "$drop_in_file"
    _storage_daemon_reload
    log_success "Docker mount guard installed: $drop_in_file"
    return 0
}
