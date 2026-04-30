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
