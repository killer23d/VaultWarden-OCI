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
#   require_project_state_ready  — guard that every script calls early; fails
#                                  closed if the expected data volume is absent.

[[ -n "${VAULTWARDEN_STORAGE_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_STORAGE_LIB_LOADED=1

# ---------------------------------------------------------------------------
# require_project_state_ready
#
# In boot-only mode (DATA_VOLUME_DEVICE blank): creates PROJECT_STATE_DIR if
# absent and returns 0.
#
# In separate-volume mode (DATA_VOLUME_DEVICE set):
#   1. Validates configuration consistency:
#      PROJECT_STATE_DIR must equal DATA_VOLUME_MOUNT.
#   2. Confirms DATA_VOLUME_DEVICE is a block device (catches typos).
#   3. Confirms DATA_VOLUME_MOUNT is currently mounted.
#   4. Confirms the sentinel file .vw-data-volume exists on the mount
#      (written by setup_data_volume(); prevents silently treating any
#       arbitrary mountpoint as the data volume).
#   5. Creates PROJECT_STATE_DIR if absent (idempotent).
#
# Returns 0 on success, 1 on any failure (all callers should exit on 1).
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

    # 1. Configuration consistency: PROJECT_STATE_DIR must equal DATA_VOLUME_MOUNT.
    if [[ "$state_dir" != "$data_mount" ]]; then
        log_error "Storage configuration mismatch:"
        log_error "  PROJECT_STATE_DIR='$state_dir'"
        log_error "  DATA_VOLUME_MOUNT='$data_mount'"
        log_error "When DATA_VOLUME_DEVICE is set, PROJECT_STATE_DIR MUST equal DATA_VOLUME_MOUNT."
        log_error "Fix .env: set PROJECT_STATE_DIR=$data_mount"
        return 1
    fi

    # 2. DATA_VOLUME_DEVICE must be a block device.
    if [[ ! -b "$data_device" ]]; then
        log_error "DATA_VOLUME_DEVICE is not a block device: $data_device"
        log_error "Check .env or verify that the data disk is attached to this instance."
        return 1
    fi

    # 3. DATA_VOLUME_MOUNT must currently be mounted.
    if ! mountpoint -q "$data_mount" 2>/dev/null; then
        log_error "Expected data volume is NOT mounted: $data_mount"
        log_error "Refusing to continue — writing VaultWarden data onto the boot volume"
        log_error "would silently corrupt your persistent state."
        log_error "Remediation:"
        log_error "  sudo mount $data_mount"
        log_error "  (or check /etc/fstab and: sudo systemctl daemon-reload)"
        return 1
    fi

    # 4. Sentinel file confirms mount identity (written by setup_data_volume).
    if [[ ! -f "$data_mount/.vw-data-volume" ]]; then
        log_error "Data volume sentinel missing: $data_mount/.vw-data-volume"
        log_error "The filesystem at $data_mount cannot be positively identified"
        log_error "as the VaultWarden data volume. Refusing to continue."
        log_error "Remediation (only if this IS the correct data disk):"
        log_error "  sudo touch $data_mount/.vw-data-volume"
        return 1
    fi

    # 5. Ensure PROJECT_STATE_DIR exists (idempotent).
    mkdir -p "$state_dir" 2>/dev/null || {
        log_error "require_project_state_ready: cannot create PROJECT_STATE_DIR: $state_dir"
        return 1
    }

    return 0
}

# ---------------------------------------------------------------------------
# setup_data_volume
# ---------------------------------------------------------------------------
# Provisions the dedicated data volume when DATA_VOLUME_DEVICE is set.
# Idempotent: safe to re-run. All decisions are based on current on-disk state.
# Called only by setup.sh. Requires root.
# ---------------------------------------------------------------------------
setup_data_volume() {
    # Guard: already loaded idempotency check at top of file is sufficient.
    # This function must only run when sourced from setup.sh (DRY_RUN is set there).
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

    # Validate device is a real block device and path is safe
    if [[ ! -b "$device" ]]; then
        log_error "DATA_VOLUME_DEVICE is not a block device: $device"
        return 1
    fi
    if [[ ! "$device" =~ ^/dev/[a-zA-Z0-9/]+$ ]]; then
        log_error "DATA_VOLUME_DEVICE contains disallowed characters: $device"
        return 1
    fi

    # Format only if blank (idempotent)
    local fs_type
    fs_type=$(blkid -o value -s TYPE "$device" 2>/dev/null || true)
    if [[ -z "$fs_type" ]]; then
        log_info "No filesystem found on $device — formatting as ext4..."
        log_warn "ALL DATA ON $device WILL BE ERASED. Expected on first run."
        mkfs.ext4 -F -L vw-data "$device" > /dev/null 2>&1 \
            || { log_error "mkfs.ext4 failed for $device"; return 1; }
        log_success "Formatted $device as ext4 (label: vw-data)"
    elif [[ "$fs_type" == "ext4" ]]; then
        log_info "Existing ext4 on $device — skipping format (idempotent)"
    else
        log_error "Unexpected filesystem '$fs_type' on $device. Refusing to overwrite."
        log_error "If intentional, set DATA_VOLUME_DEVICE= and manage the volume manually."
        return 1
    fi

    # Create mount point
    [[ -d "$mount_point" ]] || mkdir -p "$mount_point" \
        || { log_error "Cannot create mount point: $mount_point"; return 1; }
    chmod 755 "$mount_point"

    # fstab entry (UUID-based, idempotent)
    local dev_uuid
    dev_uuid=$(blkid -o value -s UUID "$device" 2>/dev/null || true)
    [[ -n "$dev_uuid" ]] \
        || { log_error "Cannot determine UUID for $device"; return 1; }

    if ! grep -qF "UUID=$dev_uuid" /etc/fstab 2>/dev/null; then
        printf 'UUID=%s\t%s\text4\tdefaults,nofail,x-systemd.after=local-fs.target\t0\t2\n' \
            "$dev_uuid" "$mount_point" >> /etc/fstab \
            || { log_error "Failed to append to /etc/fstab"; return 1; }
        log_success "fstab entry added (UUID=$dev_uuid)"
        systemctl daemon-reload 2>/dev/null || true
    else
        log_info "fstab entry already present for UUID=$dev_uuid (idempotent)"
    fi

    # Mount (idempotent)
    if mountpoint -q "$mount_point" 2>/dev/null; then
        log_info "$mount_point already mounted (idempotent)"
    else
        mount "$mount_point" \
            || { log_error "mount failed for $mount_point — check /etc/fstab"; return 1; }
        log_success "Mounted $device at $mount_point"
    fi

    # Sentinel file (idempotent)
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
# ---------------------------------------------------------------------------
# Installs/removes a Docker systemd drop-in enforcing RequiresMountsFor on
# DATA_VOLUME_MOUNT so Docker never starts without the data volume.
# Idempotent. Called only by setup.sh. Requires root.
# ---------------------------------------------------------------------------
install_docker_mount_guard() {
    local drop_in_dir="/etc/systemd/system/docker.service.d"
    local drop_in_file="$drop_in_dir/10-vaultwarden-data-volume.conf"
    local dry_run="${DRY_RUN:-false}"

    if [[ -z "${DATA_VOLUME_DEVICE:-}" ]]; then
        if [[ -f "$drop_in_file" ]]; then
            log_info "DATA_VOLUME_DEVICE cleared — removing stale Docker mount guard"
            rm -f "$drop_in_file"
            systemctl daemon-reload 2>/dev/null || true
        else
            log_info "DATA_VOLUME_DEVICE not set — Docker mount guard not needed"
        fi
        return 0
    fi

    if [[ "$dry_run" == "true" ]]; then
        log_info "[DRY RUN] Would install Docker mount guard for: ${DATA_VOLUME_MOUNT}"
        return 0
    fi

    local mount_point="${DATA_VOLUME_MOUNT:-/mnt/vw-data}"
    if [[ ! "$mount_point" =~ ^/[a-zA-Z0-9/_-]+$ ]]; then
        log_error "DATA_VOLUME_MOUNT contains disallowed characters: $mount_point"
        return 1
    fi

    mkdir -p "$drop_in_dir" \
        || { log_error "Cannot create drop-in dir: $drop_in_dir"; return 1; }

    if [[ -f "$drop_in_file" ]] \
        && grep -qF "RequiresMountsFor=$mount_point" "$drop_in_file" 2>/dev/null; then
        log_info "Docker mount guard already installed for $mount_point (idempotent)"
        return 0
    fi

    cat > "$drop_in_file" << DROPIN
# Managed by VaultWarden-OCI setup.sh — do not edit by hand.
# Requires the data volume to be mounted before Docker starts.
[Unit]
RequiresMountsFor=${mount_point}
DROPIN

    chmod 644 "$drop_in_file"
    systemctl daemon-reload 2>/dev/null || true
    log_success "Docker mount guard installed: $drop_in_file"
    return 0
}