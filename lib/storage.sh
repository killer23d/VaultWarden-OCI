#!/usr/bin/env bash
# lib/storage.sh — Storage and mount-guard helpers for VaultWarden-OCI.
#
# Provides:
#   Validation : require_project_state_ready
#   Provision  : setup_data_volume, install_docker_mount_guard
#   Paths      : vw_default_backup_dir
#
# Depends on / Load order:
#   lib/log.sh is auto-loaded if it has not already been sourced.
#   lib/common.sh should be sourced before this file for is_root,
#   get_real_user, and get_config_value.
#
# Canonical caller source block:
#   source "${LIB_DIR}/log.sh"
#   source "${LIB_DIR}/common.sh"
#   source "${LIB_DIR}/storage.sh"

[[ -n "${VAULTWARDEN_STORAGE_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_STORAGE_LIB_LOADED=1

# Do NOT set -euo pipefail here — callers own their shell options.
# Entry-point scripts apply these options via init_common_lib(); this library
# is always sourced after that call.

# Self-load log.sh if not already loaded — allows this lib to be sourced
# directly without going through common.sh or a caller that pre-loads log.sh.
_VW_STORAGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${VW_LOG_LIB_LOADED:-}" ]]          || source "${_VW_STORAGE_LIB_DIR}/log.sh"
[[ -n "${VAULTWARDEN_DEFAULTS_LOADED:-}" ]] || source "${_VW_STORAGE_LIB_DIR}/defaults.sh"
unset _VW_STORAGE_LIB_DIR

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
# _storage_device_has_data_signatures
#
# Internal helper. Uses wipefs to detect any on-disk signatures that blkid
# does not report as a named filesystem type (e.g. LVM PV, RAID superblocks,
# swap areas, orphaned partition tables, previous MBR bootloaders).
#
# blkid only reports TYPE when it recognises a complete, valid filesystem
# header. wipefs reports *any* magic-number match regardless of validity.
# A device with wiped or corrupted filesystem headers can therefore appear
# blank to blkid while still carrying data fingerprints visible to wipefs.
#
# Arguments:
#   $1 — block device path (already validated)
#
# Outputs (stdout): one line per signature found, in wipefs --parsable format.
# Returns 0 if wipefs is available and ran successfully; 1 otherwise.
# Callers must treat a non-zero return as "unknown" and err on the side of
# caution.
# ---------------------------------------------------------------------------
_storage_device_has_data_signatures() {
    local device="$1"
    if ! command -v wipefs >/dev/null 2>&1; then
        log_warn "wipefs not found — cannot perform deep signature scan of $device."
        log_warn "Install util-linux to enable this safety check."
        return 1
    fi
    # --no-act: read-only scan; --all: include all offset types; --parsable:
    # machine-readable output for reliable empty-check via wc -l.
    wipefs --no-act --all --parsable "$device" 2>/dev/null
}

# ---------------------------------------------------------------------------
# _storage_confirm_existing_fs
#
# Internal helper. Called when blkid reports an existing ext4/xfs filesystem
# on the target device. Presents the operator with the device details and
# requires explicit confirmation before setup proceeds to mount and use the
# device as the VaultWarden data volume.
#
# Confirmation is accepted in two ways:
#   Non-interactive / CI: DATA_VOLUME_EXISTING_FS_OK=true in the environment.
#   Interactive (TTY):    Operator types the exact word YES at the prompt.
#                         Anything else (including 'yes', 'y', Enter) aborts.
#
# If stdin is not a terminal and DATA_VOLUME_EXISTING_FS_OK is not set,
# the function fails with a clear message so the caller can abort safely
# rather than hanging indefinitely waiting for input.
#
# Arguments:
#   $1 — device path (already validated)
#   $2 — detected filesystem type (ext4 or xfs)
#
# Returns 0 if confirmation is obtained; 1 if the operator declines or the
# environment does not permit safe confirmation.
# ---------------------------------------------------------------------------
_storage_confirm_existing_fs() {
    local device="$1"
    local fs_type="$2"
    local existing_fs_ok

    case "${DATA_VOLUME_EXISTING_FS_OK:-false,,}" in
        true|1|yes) existing_fs_ok="true"  ;;
        *)          existing_fs_ok="false" ;;
    esac

    # Gather device metadata for the warning message.
    local dev_uuid dev_label dev_gib
    dev_uuid=$(blkid  -o value -s UUID  "$device" 2>/dev/null || true)
    dev_label=$(blkid -o value -s LABEL "$device" 2>/dev/null || true)
    local _dev_bytes
    _dev_bytes=$(lsblk --nodeps --noheadings --bytes --output SIZE "$device" 2>/dev/null \
                 | tr -d '[:space:]') || true
    if [[ "$_dev_bytes" =~ ^[0-9]+$ && "$_dev_bytes" -gt 0 ]]; then
        dev_gib="$(( _dev_bytes / 1073741824 )) GiB"
    else
        dev_gib="(size unknown)"
    fi

    log_warn  "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_warn  "  EXISTING DATA DETECTED"
    log_warn  "  Device   : $device"
    log_warn  "  FS type  : $fs_type"
    log_warn  "  UUID     : ${dev_uuid:-(none)}"
    log_warn  "  Label    : ${dev_label:-(none)}"
    log_warn  "  Size     : $dev_gib"
    log_warn  "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_warn  "Setup will mount this device and use it as the VaultWarden data"
    log_warn  "volume WITHOUT reformatting. Existing data will be preserved, but"
    log_warn  "if this is the wrong device your data could be exposed or corrupted."
    log_warn  "Verify this is the correct disk before continuing."
    log_warn  "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ "$existing_fs_ok" == "true" ]]; then
        log_warn "DATA_VOLUME_EXISTING_FS_OK=true — proceeding without interactive prompt."
        return 0
    fi

    # Non-interactive path: stdin is not a terminal. Hanging here would be
    # worse than failing, so abort with a clear remediation message.
    if [[ ! -t 0 ]]; then
        log_error "Stdin is not a terminal. Cannot prompt for confirmation."
        log_error "To proceed non-interactively, set the following and re-run setup:"
        log_error "  export DATA_VOLUME_EXISTING_FS_OK=true"
        log_error "Only set this flag if you have verified $device is the correct disk."
        return 1
    fi

    # Interactive prompt. Only the exact word YES (uppercase) is accepted.
    local answer
    printf '\n' >&2
    printf 'Type YES (uppercase) to confirm this is the correct device and continue: ' >&2
    read -r answer
    printf '\n' >&2

    if [[ "$answer" == "YES" ]]; then
        log_info "Operator confirmed: proceeding with existing $fs_type filesystem on $device."
        return 0
    fi

    log_error "Confirmation not received (got: '${answer}'). Aborting."
    log_error "Re-run setup when you have verified the correct device is set in DATA_VOLUME_DEVICE."
    return 1
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
check_project_state_ready() {
    local state_dir="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}"
    local data_device="${DATA_VOLUME_DEVICE:-}"
    local data_mount="${DATA_VOLUME_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}"

    if [[ -z "$data_device" ]]; then
        if [[ -d "$state_dir" ]]; then
            [[ -r "$state_dir" && -x "$state_dir" ]] || {
                log_error "check_project_state_ready: PROJECT_STATE_DIR is not accessible by $(id -un): $state_dir"
                log_error "Run setup once as root: sudo ./setup.sh install --domain <your-domain> --email <your-email> (or ask an administrator to fix ownership)."
                return 1
            }
            return 0
        fi
        if is_root; then
            return 0
        fi
        log_error "check_project_state_ready: PROJECT_STATE_DIR does not exist: $state_dir"
        log_error "Run the root setup step first: sudo ./setup.sh install --domain <your-domain> --email <your-email>"
        return 1
    fi

    _storage_validate_paths "$data_device" "$data_mount" || return 1

    if [[ "$state_dir" != "$data_mount" ]]; then
        log_error "Storage configuration mismatch:"
        log_error "  PROJECT_STATE_DIR='$state_dir'"
        log_error "  DATA_VOLUME_MOUNT='$data_mount'"
        log_error "When DATA_VOLUME_DEVICE is set, PROJECT_STATE_DIR MUST equal DATA_VOLUME_MOUNT."
        log_error "Fix: set PROJECT_STATE_DIR=$data_mount in .env"
        return 1
    fi

    if [[ ! -b "$data_device" ]]; then
        log_error "DATA_VOLUME_DEVICE is not a block device: $data_device"
        log_error "Check .env or verify that the data disk is attached to this instance."
        return 1
    fi

    if ! mountpoint -q "$data_mount" 2>/dev/null; then
        log_error "Expected data volume is NOT mounted: $data_mount"
        log_error "Refusing to continue — writing VaultWarden data onto the boot volume"
        log_error "would silently corrupt your persistent state."
        log_error "Remediation: sudo mount $data_mount"
        return 1
    fi

    if [[ ! -f "$data_mount/.vw-data-volume" ]]; then
        log_error "Data volume sentinel missing: $data_mount/.vw-data-volume"
        log_error "The filesystem at $data_mount cannot be positively identified as the VaultWarden data volume."
        log_error "Remediation (only if this IS the correct data disk): sudo touch $data_mount/.vw-data-volume"
        return 1
    fi

    [[ -d "$state_dir" ]] || { log_error "check_project_state_ready: PROJECT_STATE_DIR missing: $state_dir"; return 1; }
    [[ -r "$state_dir" && -x "$state_dir" ]] || {
        log_error "check_project_state_ready: PROJECT_STATE_DIR is not accessible by $(id -un): $state_dir"
        return 1
    }
    return 0
}

ensure_project_state_ready() {
    is_root || { log_error "ensure_project_state_ready: must be run as root"; return 1; }
    local state_dir="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}"
    check_project_state_ready || return 1
    local _real_user
    _real_user="$(get_real_user)"
    install -d -m 750 "$state_dir" 2>/dev/null || {
        log_error "ensure_project_state_ready: cannot create PROJECT_STATE_DIR: $state_dir"
        return 1
    }
    if [[ -n "$_real_user" && "$_real_user" != "root" ]]; then
        chown "$_real_user" "$state_dir" 2>/dev/null || \
            log_warn "ensure_project_state_ready: could not set owner of $state_dir to $_real_user"
    fi
    return 0
}

require_project_state_ready() {
    ensure_project_state_ready
}

# ---------------------------------------------------------------------------
# setup_data_volume
#
# Provisions the dedicated data volume when DATA_VOLUME_DEVICE is set.
# Idempotent: every step checks current on-disk state before acting.
# Called only by setup.sh. Requires root.
#
# DESTRUCTIVE OPERATION POLICY — formatting a block device:
#   Formatting is permitted ONLY when ALL of the following are true:
#     a) blkid reports no recognised filesystem on the device.
#     b) wipefs reports no data signatures of any kind (LVM, RAID, swap, …).
#     c) DATA_VOLUME_FORCE_FORMAT=true is set in the environment.
#   If (a) and (b) are true but (c) is absent the function aborts with a
#   clear error and the remediation command needed to proceed. This prevents
#   silent data loss when an operator accidentally points DATA_VOLUME_DEVICE
#   at a device that was previously wiped or never formatted.
#
# EXISTING FILESYSTEM POLICY — adopting an already-formatted device:
#   When blkid reports an existing ext4 or xfs filesystem the device is NOT
#   reformatted. Instead the operator is shown the device details (UUID, label,
#   size) and must explicitly confirm before setup proceeds. Confirmation is:
#     Non-interactive / CI: DATA_VOLUME_EXISTING_FS_OK=true in the environment.
#     Interactive (TTY):    Operator types the exact word YES at the prompt.
#   This prevents silently adopting the wrong disk (e.g. the boot volume).
#
# Steps performed (each skipped if already complete):
#   1. Validates device path safety and block-device existence.
#   2. Detects filesystem type via blkid.
#      a. Recognised ext4/xfs  → warn + confirm, then proceed without format.
#      b. Other known type     → refuse; operator must intervene.
#      c. No filesystem found  → run wipefs deep scan, then require
#                                DATA_VOLUME_FORCE_FORMAT=true before
#                                running mkfs.ext4 (without -F so mkfs
#                                can apply its own safety checks).
#   3. Creates the mount point directory.
#   4. Adds a UUID-based fstab entry (fs-type matches detected filesystem)
#      and runs daemon-reload.
#   5. Mounts the volume if not already mounted.
#   6. Writes a read-only sentinel file that identifies the volume.
#
# Environment variables consumed:
#   DATA_VOLUME_DEVICE          — block device to provision (required)
#   DATA_VOLUME_MOUNT           — mount point (default: _VW_DEFAULT_DATA_MOUNT)
#   DRY_RUN                     — if true, preview every step without executing
#   DATA_VOLUME_FORCE_FORMAT    — must be "true" to permit mkfs on an
#                                 unformatted/signature-free device
#   DATA_VOLUME_EXISTING_FS_OK  — set "true" to skip interactive confirmation
#                                 when adopting an existing filesystem (CI/automation)
# ---------------------------------------------------------------------------
setup_data_volume() {
    local device="${DATA_VOLUME_DEVICE:-}"
    local mount_point="${DATA_VOLUME_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}"
    local dry_run="${DRY_RUN:-false}"
    local force_format="${DATA_VOLUME_FORCE_FORMAT:-false}"

    case "${dry_run,,}" in
        true|1|yes)    dry_run="true"  ;;
        false|0|no|"") dry_run="false" ;;
        *)
            log_warn "DRY_RUN='${DRY_RUN:-}' is not recognised (valid: true/false) — treating as false (live run)"
            dry_run="false"
            ;;
    esac

    case "${force_format,,}" in
        true|1|yes)    force_format="true"  ;;
        false|0|no|"") force_format="false" ;;
        *)
            log_warn "DATA_VOLUME_FORCE_FORMAT='${DATA_VOLUME_FORCE_FORMAT:-}' is not recognised — treating as false"
            force_format="false"
            ;;
    esac

    if [[ -z "$device" ]]; then
        log_info "DATA_VOLUME_DEVICE not set — skipping data volume provisioning (boot-only mode)"
        return 0
    fi

    _storage_validate_paths "$device" "$mount_point" || return 1

    if [[ ! -b "$device" ]]; then
        log_error "DATA_VOLUME_DEVICE is not a block device: $device"
        return 1
    fi

    local fs_type
    fs_type=$(blkid -o value -s TYPE "$device" 2>/dev/null || true)

    if [[ -n "$fs_type" ]]; then
        if [[ "$fs_type" == "ext4" || "$fs_type" == "xfs" ]]; then
            if [[ "$dry_run" == "true" ]]; then
                log_info "[DRY RUN] Existing $fs_type filesystem detected on $device."
                log_info "[DRY RUN] Would require confirmation (DATA_VOLUME_EXISTING_FS_OK=true or interactive YES) before proceeding."
            else
                # Require explicit operator confirmation before adopting an
                # existing filesystem. This prevents silently mounting the
                # wrong disk (e.g. the boot volume) as the data volume.
                _storage_confirm_existing_fs "$device" "$fs_type" || return 1
            fi
        else
            log_error "Unexpected filesystem '$fs_type' on $device. Refusing to overwrite."
            log_error "Only ext4 and xfs volumes are managed by this script."
            log_error "To use a different device, update DATA_VOLUME_DEVICE in .env and re-run setup."
            return 1
        fi
    else
        if [[ "$dry_run" == "true" ]]; then
            log_info "[DRY RUN] No filesystem detected on $device — would run wipefs deep scan."
            if [[ "$force_format" == "true" ]]; then
                log_info "[DRY RUN] DATA_VOLUME_FORCE_FORMAT=true — would format $device as ext4 if scan is clean."
            else
                log_info "[DRY RUN] DATA_VOLUME_FORCE_FORMAT is not set — would abort (set it to permit format)."
            fi
        else
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
            log_info "Device size: $(( _dev_bytes / 1073741824 )) GiB."

            # IMPORTANT: declare local first, then assign, so the exit code
            # of the subshell is captured in wipefs_rc rather than always
            # receiving the exit code of the 'local' builtin (which is always 0).
            local wipefs_out
            local wipefs_rc
            wipefs_out=$(_storage_device_has_data_signatures "$device")
            wipefs_rc=$?

            if (( wipefs_rc != 0 )); then
                if [[ "$force_format" != "true" ]]; then
                    log_error "Cannot perform a deep signature scan of $device (wipefs unavailable or failed)."
                    log_error "Refusing to format without confirmation to avoid accidental data loss."
                    log_error "If you are certain $device is blank and safe to format, re-run setup with:"
                    log_error "  sudo env DATA_VOLUME_FORCE_FORMAT=true utilities/setup-storage.sh setup --data-device $device"
                    log_error "For migrate mode, use: --force-format"
                    log_error "This authorization must be explicit — it is never inferred from any other option."
                    return 1
                fi
                log_warn "wipefs scan skipped (tool unavailable). Proceeding because DATA_VOLUME_FORCE_FORMAT=true."
            else
                local sig_count
                sig_count=$(printf '%s\n' "$wipefs_out" \
                            | grep -v '^#' \
                            | grep -c '[^[:space:]]' 2>/dev/null || true)

                if (( sig_count > 0 )); then
                    log_warn "wipefs detected ${sig_count} data signature(s) on $device:"
                    printf '%s\n' "$wipefs_out" | grep -v '^#' | while IFS= read -r _sig_line; do
                        [[ -n "$_sig_line" ]] && log_warn "  $_sig_line"
                    done
                    if [[ "$force_format" != "true" ]]; then
                        log_error "Refusing to format $device — existing data signatures were found."
                        log_error "This device may contain data (LVM PV, RAID member, swap, prior filesystem, …)."
                        log_error "Review the signatures above with:"
                        log_error "  sudo wipefs --all $device"
                        log_error "If you are certain the device is safe to erase, re-run setup with:"
                        log_error "  sudo env DATA_VOLUME_FORCE_FORMAT=true utilities/setup-storage.sh setup --data-device $device"
                        log_error "For migrate mode, use: --force-format"
                        log_error "This authorization must be explicit — it is never inferred from any other option."
                        return 1
                    fi
                    log_warn "DATA_VOLUME_FORCE_FORMAT=true — proceeding despite detected signatures."
                    log_warn "ALL DATA ON $device WILL BE ERASED."
                else
                    if [[ "$force_format" != "true" ]]; then
                        log_error "No filesystem or data signatures found on $device."
                        log_error "To format this device as ext4 and use it as the VaultWarden data volume,"
                        log_error "re-run setup with:"
                        log_error "  sudo env DATA_VOLUME_FORCE_FORMAT=true utilities/setup-storage.sh setup --data-device $device"
                        log_error "For migrate mode, use: --force-format"
                        log_error "This authorization must be explicit — it is never inferred from any other option."
                        log_error "This safeguard prevents accidental data loss when a device that was"
                        log_error "previously wiped appears blank to blkid."
                        return 1
                    fi
                    log_warn "No data signatures detected on $device. Proceeding with format (DATA_VOLUME_FORCE_FORMAT=true)."
                    log_warn "ALL DATA ON $device WILL BE ERASED."
                fi
            fi

            log_info "Formatting $device as ext4 (label: vw-data)..."
            local mkfs_out
            mkfs_out=$(mkfs.ext4 -L vw-data "$device" 2>&1) || {
                log_error "mkfs.ext4 failed for $device:"
                printf '%s\n' "$mkfs_out" | while IFS= read -r _line; do
                    log_error "  $_line"
                done
                return 1
            }
            log_success "Formatted $device as ext4 (label: vw-data)"
            fs_type="ext4"
        fi
    fi

    if [[ "$dry_run" == "true" ]]; then
        [[ -d "$mount_point" ]] \
            && log_info "[DRY RUN] Mount point $mount_point already exists." \
            || log_info "[DRY RUN] Would create mount point: $mount_point"
    else
        [[ -d "$mount_point" ]] || mkdir -p "$mount_point" \
            || { log_error "Cannot create mount point: $mount_point"; return 1; }
        chmod 755 "$mount_point"
    fi

    # ------------------------------------------------------------------
    # Step 4: fstab entry (UUID-based, idempotent).
    #   noatime                      — suppress atime writes; reduces I/O on SQLite data files.
    #   nofail                       — boot proceeds if the volume is absent (avoids
    #                                  emergency-mode boot on temporary disk detachment).
    #   x-systemd.device-timeout=30s — bounds how long systemd waits for the block device;
    #                                  prevents indefinite boot stalls on OCI instances where
    #                                  the volume attachment may race the kernel.
    #
    # The fs-type written to fstab is derived from the detected filesystem so
    # that an existing xfs volume is not incorrectly recorded as ext4.
    # ------------------------------------------------------------------
    local dev_uuid
    dev_uuid=$(blkid -o value -s UUID "$device" 2>/dev/null || true)
    [[ -n "$dev_uuid" ]] \
        || { log_error "Cannot determine UUID for $device — cannot write a safe fstab entry"; return 1; }

    local fstab_fs_type="${fs_type:-ext4}"

    local _uuid_in_fstab=false _mp_matches=false _old_mp=""
    if grep -qF "UUID=$dev_uuid" /etc/fstab 2>/dev/null; then
        _uuid_in_fstab=true
        if grep "UUID=$dev_uuid" /etc/fstab | grep -qF "$mount_point"; then
            _mp_matches=true
        else
            _old_mp=$(grep "UUID=$dev_uuid" /etc/fstab | awk '{print $2}' | head -1 || true)
        fi
    fi

    if [[ "$_uuid_in_fstab" == "true" && "$_mp_matches" == "true" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            log_info "[DRY RUN] fstab entry for UUID=$dev_uuid at $mount_point already correct (idempotent)."
        else
            log_info "fstab entry already present for UUID=$dev_uuid at $mount_point (idempotent)"
        fi
    else
        if [[ "$dry_run" == "true" ]]; then
            if [[ "$_uuid_in_fstab" == "true" ]]; then
                log_info "[DRY RUN] Would replace stale fstab entry (UUID=$dev_uuid, old mount: '${_old_mp}') with $mount_point."
            else
                log_info "[DRY RUN] Would add fstab entry: UUID=$dev_uuid  $mount_point  $fstab_fs_type  noatime,nofail,x-systemd.device-timeout=30s  0 2"
            fi
        else
            # Write to a temp file on the same filesystem, then atomically replace
            # /etc/fstab. This avoids leaving a truncated fstab behind if the
            # process is killed mid-write.
            local fstab_tmp
            fstab_tmp=$(mktemp /etc/fstab.vw-XXXXXX) \
                || { log_error "Cannot create fstab temp file"; return 1; }
            chmod 644 "$fstab_tmp"
            if ! cp /etc/fstab "$fstab_tmp"; then
                rm -f "$fstab_tmp"
                log_error "Cannot copy /etc/fstab to temp file"
                return 1
            fi
            if [[ "$_uuid_in_fstab" == "true" ]]; then
                # UUID exists but points to the wrong mount point — remove the stale
                # entry before appending the corrected one. grep -v writes all lines
                # that do NOT match; the result is the old fstab minus the stale line.
                local fstab_tmp2
                fstab_tmp2=$(mktemp /etc/fstab.vw-XXXXXX) \
                    || { rm -f "$fstab_tmp"; log_error "Cannot create second fstab temp file"; return 1; }
                chmod 644 "$fstab_tmp2"
                grep -vF "UUID=$dev_uuid" "$fstab_tmp" > "$fstab_tmp2" \
                    || { rm -f "$fstab_tmp" "$fstab_tmp2"; log_error "Failed to filter stale fstab entry"; return 1; }
                mv -- "$fstab_tmp2" "$fstab_tmp" \
                    || { rm -f "$fstab_tmp" "$fstab_tmp2"; log_error "Failed to stage filtered fstab"; return 1; }
                log_warn "fstab: stale entry for UUID=$dev_uuid pointed to '${_old_mp}' — replacing with '$mount_point'."
            fi
            printf 'UUID=%s\t%s\t%s\tnoatime,nofail,x-systemd.device-timeout=30s\t0\t2\n' \
                "$dev_uuid" "$mount_point" "$fstab_fs_type" >> "$fstab_tmp" \
                || { rm -f "$fstab_tmp"; log_error "Failed to append new entry to fstab temp file"; return 1; }
            if ! mv -- "$fstab_tmp" /etc/fstab; then
                rm -f "$fstab_tmp"
                log_error "Failed to atomically replace /etc/fstab"
                return 1
            fi
            if [[ "$_uuid_in_fstab" == "true" ]]; then
                log_success "fstab entry updated (UUID=$dev_uuid, type=$fstab_fs_type, mount: $mount_point)"
            else
                log_success "fstab entry added (UUID=$dev_uuid, type=$fstab_fs_type, mount: $mount_point)"
            fi
            _storage_daemon_reload
        fi
    fi

    # ------------------------------------------------------------------
    # Step 5: Mount the volume if not already mounted.
    # ------------------------------------------------------------------
    if mountpoint -q "$mount_point" 2>/dev/null; then
        if [[ "$dry_run" == "true" ]]; then
            log_info "[DRY RUN] $mount_point is already mounted (idempotent)."
        else
            log_info "$mount_point already mounted (idempotent)"
        fi
    else
        if [[ "$dry_run" == "true" ]]; then
            log_info "[DRY RUN] Would mount $device at $mount_point."
        else
            mount "$mount_point" || {
                local _fstab_hint
                _fstab_hint="$(blkid -o value -s UUID "$device" 2>/dev/null || true)"
                log_error "Could not mount $mount_point. This usually means /etc/fstab is"
                log_error "missing an entry for this device or uses a different mount point."
                log_error "To diagnose:"
                if [[ -n "${_fstab_hint}" ]]; then
                    log_error "  grep '${_fstab_hint}' /etc/fstab"
                else
                    log_error "  grep '$device' /etc/fstab"
                fi
                log_error "Verify the second column (mount point) matches '$mount_point'."
                log_error "If the entry is missing, run: sudo utilities/setup-storage.sh setup"
                return 1
            }
            log_success "Mounted $device at $mount_point"
        fi
    fi

    # ------------------------------------------------------------------
    # Step 6: Sentinel file (idempotent, read-only, immutable where supported).
    #   The sentinel is the only positive proof that a given mountpoint IS the
    #   VaultWarden data volume. Making it immutable with chattr +i protects it
    #   from accidental rm -rf on the mount root while preserving the guard in
    #   require_project_state_ready. The uninstaller runs chattr -i before wipe.
    # ------------------------------------------------------------------
    local sentinel="$mount_point/.vw-data-volume"
    if [[ "$dry_run" == "true" ]]; then
        [[ -f "$sentinel" ]] \
            && log_info "[DRY RUN] Sentinel already present (idempotent): $sentinel" \
            || log_info "[DRY RUN] Would write sentinel: $sentinel"
    else
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
    fi

    if [[ "$dry_run" == "true" ]]; then
        log_info "[DRY RUN] Data volume provisioning preview complete: $device → $mount_point"
    else
        log_success "Data volume ready: $device → $mount_point"
    fi
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
        true|1|yes)    dry_run="true"  ;;
        false|0|no|"") dry_run="false" ;;
        *)
            log_warn "DRY_RUN='${DRY_RUN:-}' is not recognised (valid: true/false) — treating as false (live run)"
            dry_run="false"
            ;;
    esac

    if [[ -z "${DATA_VOLUME_DEVICE:-}" ]]; then
        if [[ -f "$drop_in_file" ]]; then
            if [[ "$dry_run" == "true" ]]; then
                log_info "[DRY RUN] DATA_VOLUME_DEVICE cleared — would remove stale Docker mount guard: $drop_in_file"
            else
                log_info "DATA_VOLUME_DEVICE cleared — removing stale Docker mount guard"
                rm -f "$drop_in_file" \
                    || { log_error "Failed to remove Docker mount guard: $drop_in_file"; return 1; }
                _storage_daemon_reload
            fi
        else
            log_info "DATA_VOLUME_DEVICE not set — Docker mount guard not needed"
        fi
        return 0
    fi

    local mount_point="${DATA_VOLUME_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}"
    _storage_validate_paths "" "$mount_point" || return 1

    if [[ "$dry_run" == "true" ]]; then
        log_info "[DRY RUN] Would install Docker mount guard for: $mount_point"
        return 0
    fi

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
        state_dir="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}"
    fi
    printf '%s/backups' "$state_dir"
}
