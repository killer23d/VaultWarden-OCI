#!/usr/bin/env bash
# utilities/env-edit.sh — Manage VaultWarden-OCI environment: sync, edit, and status.
#
# Subcommands:
#   sync   (default) Non-interactively propagate repo .env → install.env → vaultwarden.env.
#                    Safe for make up, make restart, setup-systemd.sh install.
#   edit             Open repo .env in ${EDITOR:-nano}, detect changes, run sync when saved.
#   status           Report env-file drift and storage state (non-destructive).
#
# Storage safety:
#   When DATA_VOLUME_DEVICE is set in repo .env, sync fails closed before writing
#   install.env unless the full storage contract is satisfied:
#     - PROJECT_STATE_DIR == DATA_VOLUME_MOUNT
#     - DATA_VOLUME_DEVICE exists as a block device
#     - DATA_VOLUME_MOUNT is mounted
#     - ${DATA_VOLUME_MOUNT}/.vw-data-volume sentinel exists
#   This prevents accidentally writing the config skeleton onto the boot disk when the
#   data volume is detached or its mount failed.
#
#   If .migrate-volume.state exists and the migration is incomplete, sync refuses to run
#   to avoid clobbering a storage migration in progress.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/log.sh"
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/defaults.sh"
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/config.sh"
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/storage.sh"
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/operations.sh"

ENV_DIR="${VW_SYNC_ETC_DIR:-/etc/vaultwarden}"
ENV_FILE="${ENV_DIR}/vaultwarden.env"
ENV_EDIT_GUARD_HELD=false

_env_edit_acquire_guard() {
  local label="$1" phase="$2"
  if [[ "$ENV_EDIT_GUARD_HELD" == "true" ]]; then
    operation_set_phase "$phase" "$label"
    return 0
  fi

  local policy="fail"
  if [[ ! -t 0 || ! -t 1 ]]; then
    policy="skip"
  fi
  operation_acquire \
    --id env-sync \
    --label "$label" \
    --specific-lock /run/lock/vaultwarden-env.lock \
    --non-interactive "$policy" || return $?
  ENV_EDIT_GUARD_HELD=true
  _env_edit_cleanup() {
    local rc=$?
    operation_release "$rc"
    return "$rc"
  }
  trap _env_edit_cleanup EXIT
  trap 'operation_release 130; exit 130' INT
  trap 'operation_release 143; exit 143' HUP TERM
  operation_set_phase "$phase" "$label"
}

show_help() {
  cat <<'EOF'
VaultWarden-OCI Environment Management

USAGE:
  sudo utilities/env-edit.sh [sync]     Sync repo .env → runtime env files (default)
  sudo utilities/env-edit.sh edit       Edit repo .env interactively; sync on change
       utilities/env-edit.sh status     Show env drift and storage state (read-only)

SUBCOMMANDS:
  sync    Copies repo .env to ${PROJECT_STATE_DIR}/config/install.env, applies
          root-runtime-only overrides, then installs /etc/vaultwarden/vaultwarden.env.
          Fails closed when DATA_VOLUME_DEVICE is configured but the volume is not
          mounted or the sentinel is missing.

  edit    Opens repo .env in ${EDITOR:-nano}. Detects whether the file was changed
          (sha256sum comparison) and runs sync only when a change is detected.
          Exits 0 and prints a "no changes" notice when the file is unchanged.

  status  Reports drift between repo .env and installed runtime env files for
          non-secret configuration keys. Checks storage mount state and whether
          a volume migration is in progress. Read-only; makes no changes.

ENVIRONMENT:
  EDITOR              Editor used by the edit subcommand (default: nano)
  VW_SYNC_ETC_DIR     Override /etc/vaultwarden (useful for testing)

SOURCE-OF-TRUTH CONTRACT:
  repo .env is the only operator-edited file.
  ${PROJECT_STATE_DIR}/config/install.env and /etc/vaultwarden/vaultwarden.env
  are generated runtime artifacts. Do not edit them directly.

  Runtime-only overrides (never written back to repo .env):
    SOPS_AGE_KEY_FILE=/etc/vaultwarden/age-key.txt        (always injected)
    RCLONE_CONFIG=/etc/vaultwarden/rclone.conf            (only when rclone.conf exists)
EOF
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_read_repo_env_value() {
  # Usage: _read_repo_env_value KEY FILE
  # Strips surrounding single/double quotes from the value.
  local key="$1" file="$2"
  awk -F= -v key="$key" -v sq="'" '$1 == key {
    value = substr($0, index($0, "=") + 1)
    gsub("^[\"" sq "]|[\"" sq "]$", "", value)
    found = value
  } END { if (found != "") print found }' "$file"
}

_atomic_install_env_copy() {
  # Usage: _atomic_install_env_copy SOURCE DEST
  # Atomically installs SOURCE as DEST with root:root 0600.
  local source_file="$1" dest_file="$2" dest_dir
  dest_dir="$(dirname "$dest_file")"

  local tmp
  tmp="$(mktemp -p "$dest_dir" "$(basename "$dest_file").XXXXXXXXXX")" || return 1
  if ! install -m 0600 -o root -g root "$source_file" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$dest_file"
}

_apply_runtime_env_overrides() {
  # Usage: _apply_runtime_env_overrides INSTALL_ENV_FILE
  # Writes runtime-only overrides into the generated install.env.
  # These values must NEVER be written back to repo .env.
  local install_env="$1"

  # Always canonical for root-operated SOPS/Age decryption.
  _set_env_var "SOPS_AGE_KEY_FILE" "/etc/vaultwarden/age-key.txt" "$install_env"

  # Canonical only when the installed root-owned rclone config exists.
  if [[ -f "${ENV_DIR}/rclone.conf" ]]; then
    _set_env_var "RCLONE_CONFIG" "${ENV_DIR}/rclone.conf" "$install_env"
  fi

  chown root:root "$install_env"
  chmod 0600 "$install_env"
}

_print_effective_email_sender() {
  local env_file="$1" name from deprecated
  name="$(_read_env_value SMTP_FROM_NAME "$env_file")"
  from="$(_read_env_value SMTP_FROM "$env_file")"
  deprecated="$(_read_env_value SMTP_FROM_EMAIL "$env_file")"

  if [[ -z "$from" && -n "$deprecated" ]]; then
    log_warn "SMTP_FROM is empty but deprecated SMTP_FROM_EMAIL is set; update repo .env to use SMTP_FROM."
  fi

  printf 'Effective email sender: %s <%s>\n' "${name:-}" "${from:-}"
}


# Known GUI/forking editors that often return before changes are saved unless a
# wait/no-fork flag is supplied. Keep in sync with utilities/secrets-edit.sh.
_FORKING_EDITORS=("gvim" "mvim" "code" "atom" "subl" "sublime_text" "gedit" "kate" "mousepad")

_check_editor_forks() {
  local -n _cmd_ref=$1
  local editor_str="${_cmd_ref[*]}"
  case "$editor_str" in
    *--wait*|*--nofork*|-f|*\ -f\ *|*\ -f|*--block*|*--foreground*) return 0 ;;
  esac

  local editor_bin
  editor_bin="$(basename "${_cmd_ref[0]}")"

  local forking
  for forking in "${_FORKING_EDITORS[@]}"; do
    if [[ "$editor_bin" == "$forking" ]]; then
      log_warn "EDITOR '$editor_bin' is known to fork and return immediately."
      log_warn "env-edit may sync before your changes are saved."
      case "$editor_bin" in
        code)      log_warn "Use:  EDITOR='code --wait' sudo utilities/env-edit.sh edit" ;;
        gvim|mvim) log_warn "Use:  EDITOR='gvim --nofork' sudo utilities/env-edit.sh edit" ;;
        atom)      log_warn "Use:  EDITOR='atom --wait' sudo utilities/env-edit.sh edit" ;;
        *)         log_warn "Pass a '--wait', '--nofork', or equivalent foreground flag to your editor." ;;
      esac
      log_warn "Proceeding anyway — verify your changes are saved before this script exits."
      return 0
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Storage safety preflight
# ---------------------------------------------------------------------------
# Reads DATA_VOLUME_DEVICE, DATA_VOLUME_MOUNT, PROJECT_STATE_DIR from repo .env,
# checks for in-progress migration, and (when a data volume is configured) validates
# the full storage contract via check_project_state_ready().
#
# Must be called before any install -d or file writes so that we never create
# ${DATA_VOLUME_MOUNT}/config on the boot disk if the volume is not mounted.
#
# Sets _PREFLIGHT_STATE_DIR in the caller's scope (name-ref not used for
# portability; caller reads the exported PROJECT_STATE_DIR after success).
# ---------------------------------------------------------------------------
_storage_preflight() {
  local repo_env="$1"

  local project_state_dir data_volume_device data_volume_mount

  project_state_dir="$(_read_repo_env_value PROJECT_STATE_DIR "$repo_env")"
  project_state_dir="${project_state_dir:-${_VW_DEFAULT_STATE_DIR}}"

  if [[ "$project_state_dir" != /* ]]; then
    log_error "PROJECT_STATE_DIR must be an absolute path: $project_state_dir"
    return 1
  fi

  data_volume_device="$(_read_repo_env_value DATA_VOLUME_DEVICE "$repo_env")"
  data_volume_mount="$(_read_repo_env_value DATA_VOLUME_MOUNT "$repo_env")"
  data_volume_mount="${data_volume_mount:-${_VW_DEFAULT_DATA_MOUNT}}"

  # ── Migration guard ────────────────────────────────────────────────────────
  # If a volume migration is in progress, refuse to sync to avoid clobbering
  # migration-in-progress writes (e.g. _update_install_env_after_storage or
  # _mv_step_update_env which update repo .env and install.env independently).
  local migrate_state="${PROJECT_ROOT}/.migrate-volume.state"
  if [[ -f "$migrate_state" && "${VW_ENV_EDIT_ALLOW_MIGRATION_SYNC:-false}" != "true" ]]; then
    local migration_complete
    migration_complete="$(grep '^MIGRATION_COMPLETE=' "$migrate_state" 2>/dev/null \
                          | cut -d= -f2- | tr -d '[:space:]' || true)"
    if [[ "$migration_complete" != "true" ]]; then
      log_error "A volume migration is in progress (.migrate-volume.state exists and is incomplete)."
      log_error "env-edit sync is blocked to prevent overwriting migration-in-progress state."
      log_error "Resume with: sudo utilities/setup-storage.sh --mode migrate resume"
      log_error "Abort with:  sudo utilities/setup-storage.sh --mode migrate abort"
      return 1
    fi
  fi

  # ── Separate-volume storage contract ──────────────────────────────────────
  # When DATA_VOLUME_DEVICE is set, all five checks in check_project_state_ready
  # must pass before we are allowed to create ${project_state_dir}/config or write
  # any file under it.  This is a read-only preflight — it does NOT create dirs.
  if [[ -n "$data_volume_device" ]]; then
    export PROJECT_STATE_DIR="$project_state_dir"
    export DATA_VOLUME_DEVICE="$data_volume_device"
    export DATA_VOLUME_MOUNT="$data_volume_mount"

    # check_project_state_ready (lib/storage.sh) validates:
    #   1. Path safety (no shell metacharacters)
    #   2. PROJECT_STATE_DIR == DATA_VOLUME_MOUNT
    #   3. DATA_VOLUME_DEVICE is a real block device
    #   4. DATA_VOLUME_MOUNT is mounted
    #   5. ${DATA_VOLUME_MOUNT}/.vw-data-volume sentinel exists
    check_project_state_ready || return 1
  fi

  # Export for use by the caller.
  export PROJECT_STATE_DIR="$project_state_dir"
  export DATA_VOLUME_DEVICE="${data_volume_device:-}"
  export DATA_VOLUME_MOUNT="${data_volume_mount}"
}

# ---------------------------------------------------------------------------
# sync subcommand — non-interactive; safe for make up / make restart / systemd
# ---------------------------------------------------------------------------
_cmd_sync() {
  require_root "env-edit sync must be run as root. Run: sudo ./utilities/env-edit.sh sync"

  local repo_env="${PROJECT_ROOT}/.env"
  if [[ ! -f "$repo_env" ]]; then
    log_error "Repository .env not found: $repo_env"
    return 1
  fi
  if [[ ! -r "$repo_env" ]]; then
    log_error "Repository .env is not readable: $repo_env"
    return 1
  fi

  _env_edit_acquire_guard "Environment sync" "sync" || return $?

  _storage_preflight "$repo_env" || return 1

  local config_dir="${PROJECT_STATE_DIR}/config"
  local install_env="${config_dir}/install.env"

  log_info "Syncing repository .env to installed runtime env files..."
  install -d -m 0700 -o root -g root "$config_dir"
  _atomic_install_env_copy "$repo_env" "$install_env"
  _apply_runtime_env_overrides "$install_env"

  install -d -m 0700 -o root -g root "$ENV_DIR"
  _atomic_install_env_copy "$install_env" "$ENV_FILE"

  log_success "Synced repo .env -> $install_env -> $ENV_FILE"
  log_info "Installed env files are generated runtime artifacts; edit repo .env only."
  _print_effective_email_sender "$install_env"
}

# ---------------------------------------------------------------------------
# edit subcommand — interactive; detects changes; syncs only when changed
# ---------------------------------------------------------------------------
_cmd_edit() {
  require_root "env-edit edit must be run as root. Run: sudo ./utilities/env-edit.sh edit"

  local repo_env="${PROJECT_ROOT}/.env"
  if [[ ! -f "$repo_env" ]]; then
    log_error "Repository .env not found: $repo_env"
    log_error "Run 'sudo make setup' to create the initial environment."
    return 1
  fi

  _env_edit_acquire_guard "Environment edit" "edit" || return $?

  local checksum_before checksum_after
  checksum_before="$(sha256sum "$repo_env" | cut -d' ' -f1)"

  local owner_uid group_gid
  owner_uid="$(stat -c '%u' "$repo_env")"
  group_gid="$(stat -c '%g' "$repo_env")"

  local -a EDITOR_CMD
  read -ra EDITOR_CMD <<< "${EDITOR:-nano}"
  if [[ ${#EDITOR_CMD[@]} -eq 0 ]]; then
    EDITOR_CMD=(nano)
  fi

  log_info "Opening repo .env with: ${EDITOR_CMD[*]}"
  _check_editor_forks EDITOR_CMD
  "${EDITOR_CMD[@]}" "$repo_env"

  if ! chown "${owner_uid}:${group_gid}" "$repo_env" 2>/dev/null; then
    log_warn "Could not restore repo .env ownership to ${owner_uid}:${group_gid}; please fix manually if needed."
  fi
  chmod 0600 "$repo_env"

  checksum_after="$(sha256sum "$repo_env" | cut -d' ' -f1)"

  if [[ "$checksum_before" == "$checksum_after" ]]; then
    log_info "No changes detected in repo .env — skipping sync."
    return 0
  fi

  log_info "Changes detected in repo .env — running sync..."
  _cmd_sync
}

# ---------------------------------------------------------------------------
# status subcommand — read-only; reports drift and storage state
# ---------------------------------------------------------------------------
_cmd_status() {
  local repo_env="${PROJECT_ROOT}/.env"
  printf '\n'
  printf '  %-22s %s\n' "Repo .env:" "${repo_env}"

  if [[ ! -f "$repo_env" ]]; then
    printf '  %-22s MISSING\n' "Repo .env:"
    return 0
  fi

  # Resolve paths from repo .env.
  local project_state_dir data_volume_device data_volume_mount
  project_state_dir="$(_read_repo_env_value PROJECT_STATE_DIR "$repo_env")"
  project_state_dir="${project_state_dir:-${_VW_DEFAULT_STATE_DIR}}"
  data_volume_device="$(_read_repo_env_value DATA_VOLUME_DEVICE "$repo_env")"
  data_volume_mount="$(_read_repo_env_value DATA_VOLUME_MOUNT "$repo_env")"
  data_volume_mount="${data_volume_mount:-${_VW_DEFAULT_DATA_MOUNT}}"

  local install_env="${project_state_dir}/config/install.env"
  local runtime_env="${VW_SYNC_ETC_DIR:-/etc/vaultwarden}/vaultwarden.env"

  printf '  %-22s %s\n' "Install env:"   "${install_env}"
  printf '  %-22s %s\n' "Runtime env:"   "${runtime_env}"
  printf '\n'

  # ── Storage state ──────────────────────────────────────────────────────────
  if [[ -z "$data_volume_device" ]]; then
    printf '  %-22s boot-only (DATA_VOLUME_DEVICE not set)\n' "Storage mode:"
  else
    printf '  %-22s separate-volume\n' "Storage mode:"
    printf '  %-22s %s\n' "  Device:" "$data_volume_device"
    printf '  %-22s %s\n' "  Mount:" "$data_volume_mount"

    if [[ -b "$data_volume_device" ]]; then
      printf '  %-22s present\n' "  Block device:"
    else
      printf '  %-22s MISSING (not a block device)\n' "  Block device:"
    fi

    if mountpoint -q "$data_volume_mount" 2>/dev/null; then
      printf '  %-22s mounted\n' "  Volume mount:"
    else
      printf '  %-22s NOT MOUNTED\n' "  Volume mount:"
    fi

    if [[ -f "${data_volume_mount}/.vw-data-volume" ]]; then
      printf '  %-22s present\n' "  Sentinel:"
    else
      printf '  %-22s MISSING\n' "  Sentinel:"
    fi

    if [[ "$project_state_dir" != "$data_volume_mount" ]]; then
      printf '  %-22s MISMATCH (PROJECT_STATE_DIR=%s, DATA_VOLUME_MOUNT=%s)\n' \
        "  Config consistency:" "$project_state_dir" "$data_volume_mount"
    else
      printf '  %-22s ok\n' "  Config consistency:"
    fi
  fi
  printf '\n'

  # ── Migration state ────────────────────────────────────────────────────────
  local migrate_state="${PROJECT_ROOT}/.migrate-volume.state"
  if [[ -f "$migrate_state" ]]; then
    local migration_complete
    migration_complete="$(grep '^MIGRATION_COMPLETE=' "$migrate_state" 2>/dev/null \
                          | cut -d= -f2- | tr -d '[:space:]' || true)"
    if [[ "$migration_complete" == "true" ]]; then
      printf '  %-22s complete\n' "Migration state:"
    else
      printf '  %-22s IN PROGRESS (incomplete — sync is blocked)\n' "Migration state:"
    fi
  else
    printf '  %-22s none\n' "Migration state:"
  fi
  printf '\n'

  # ── Env drift ─────────────────────────────────────────────────────────────
  local drift_keys=(
    PROJECT_STATE_DIR
    DATA_VOLUME_DEVICE
    DATA_VOLUME_MOUNT
    SMTP_FROM
    SMTP_FROM_NAME
    ALLOWED_SENDER_DOMAINS
    EMAIL_MODE
    SMTP_HOST
    SMTP_PORT
  )

  local -a drift_lines=()
  local key repo_val inst_val rt_val

  for key in "${drift_keys[@]}"; do
    repo_val="$(_read_repo_env_value "$key" "$repo_env" 2>/dev/null || true)"

    if [[ -f "$install_env" ]]; then
      inst_val="$(_read_repo_env_value "$key" "$install_env" 2>/dev/null || true)"
      if [[ "$repo_val" != "$inst_val" ]]; then
        drift_lines+=("  install.env:${key}: repo='${repo_val}' installed='${inst_val}'")
      fi
    fi

    if [[ -f "$runtime_env" ]]; then
      rt_val="$(_read_repo_env_value "$key" "$runtime_env" 2>/dev/null || true)"
      if [[ "$repo_val" != "$rt_val" ]] && \
         [[ "$key" != "SOPS_AGE_KEY_FILE" ]] && [[ "$key" != "RCLONE_CONFIG" ]]; then
        drift_lines+=("  vaultwarden.env:${key}: repo='${repo_val}' installed='${rt_val}'")
      fi
    fi
  done

  if [[ ${#drift_lines[@]} -eq 0 ]]; then
    printf '  %-22s none\n' "Env drift:"
  else
    printf '  %-22s WARNING (%d key(s) differ)\n' "Env drift:" "${#drift_lines[@]}"
    local line
    for line in "${drift_lines[@]}"; do
      printf '%s\n' "$line"
    done
    printf '  Run: sudo make sync-env  (or sudo make restart)\n'
  fi
  printf '\n'
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
  local subcommand="${1:-sync}"
  shift || true

  case "$subcommand" in
    sync)
      _cmd_sync "$@"
      ;;
    edit)
      _cmd_edit "$@"
      ;;
    status)
      _cmd_status "$@"
      ;;
    --help|-h)
      show_help
      return 0
      ;;
    --version|-V)
      print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"
      return 0
      ;;
    *)
      log_error "Unknown subcommand: $subcommand"
      log_error "Valid subcommands: sync | edit | status"
      show_help
      return 1
      ;;
  esac
}

main "$@"
