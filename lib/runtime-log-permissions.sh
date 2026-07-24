#!/usr/bin/env bash
# lib/runtime-log-permissions.sh — Canonical runtime log permission contract.
# VWOCI-PRR-PATCH-03

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "Error: This library should be sourced, not executed directly" >&2
  exit 1
fi

# enforce_runtime_log_permissions ROOT PUID PGID [DRY_RUN]
# Directories: 0750. Regular files: 0640. Symlinks are not followed.
enforce_runtime_log_permissions() {
  local root="$1" puid="$2" pgid="$3" dry_run="${4:-false}"
  [[ -n "$root" && "$root" == /* ]] || {
    log_error "Runtime log path must be absolute: ${root:-<empty>}"
    return 1
  }
  [[ "$puid" =~ ^[0-9]+$ && "$pgid" =~ ^[0-9]+$ ]] || {
    log_error "Runtime log ownership must use numeric PUID:PGID."
    return 1
  }
  if [[ "$dry_run" == "true" ]]; then
    log_info "[DRY RUN] Would enforce log directories 0750 and regular files 0640 under: $root"
    log_info "[DRY RUN] Would set log ownership to ${puid}:${pgid}"
    return 0
  fi
  [[ -d "$root" && ! -L "$root" ]] || {
    log_error "Runtime log root is missing or unsafe: $root"
    return 1
  }

  _maybe_sudo find "$root" -type d -exec chown "${puid}:${pgid}" -- {} + || {
    log_error "Failed to set runtime log directory ownership under: $root"
    return 1
  }
  _maybe_sudo find "$root" -type d -exec chmod 0750 -- {} + || {
    log_error "Failed to set runtime log directory modes under: $root"
    return 1
  }
  _maybe_sudo find "$root" -type f -exec chown "${puid}:${pgid}" -- {} + || {
    log_error "Failed to set runtime log file ownership under: $root"
    return 1
  }
  _maybe_sudo find "$root" -type f -exec chmod 0640 -- {} + || {
    log_error "Failed to set runtime log file modes under: $root"
    return 1
  }
  return 0
}
