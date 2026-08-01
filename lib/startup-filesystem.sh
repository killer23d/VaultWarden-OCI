# shellcheck shell=bash

prepare_directories() {
  local project_state_dir="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}"

  local required_dirs=(
    "${project_state_dir}/data"
    "${project_state_dir}/caddy/data"
    "${project_state_dir}/caddy/config"
  )

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would create state directories: ${required_dirs[*]}"
    return 0
  fi

  log_info "Preparing required state directories under ${project_state_dir}..."

  local dir
  for dir in "${required_dirs[@]}"; do
    if ! _maybe_sudo mkdir -p "$dir"; then
      log_warn "Could not create directory: $dir (init container will retry)"
    fi
  done

  log_success "State directories prepared"
  return 0
}

prepare_log_directories() {
  local project_state_dir="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}"
  local logs_root="${project_state_dir}/logs"
  local puid pgid service owner group path bad
  puid="$(get_config_value "PUID" "${_VW_DEFAULT_PUID}")"
  pgid="$(get_config_value "PGID" "${_VW_DEFAULT_PGID}")"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would create missing runtime log directories and files only."
    log_info "[DRY RUN] Existing log metadata would be validated without repair."
    return 0
  fi

  log_info "Preparing missing runtime log paths and validating existing metadata..."
  if [[ ! -d "$logs_root" ]]; then
    install -d -m 0750 -o "$puid" -g "$pgid" "$logs_root" || {
      log_error "Failed to create runtime log root: $logs_root"
      return 1
    }
  fi

  for service in "${_VW_DEFAULT_LOG_SERVICES[@]}"; do
    path="${logs_root}/${service}"
    owner="$puid"
    group="$pgid"
    if [[ "$service" == "caddy" ]]; then
      owner=2000
      group=2000
    fi
    if [[ ! -d "$path" ]]; then
      install -d -m 0750 -o "$owner" -g "$group" "$path" || {
        log_error "Failed to create runtime log directory: $path"
        return 1
      }
    fi

    bad="$(find "$path" -type d \( ! -uid "$owner" -o ! -gid "$group" -o ! -perm 0750 \) -print -quit 2>/dev/null || true)"
    if [[ -n "$bad" ]]; then
      log_error "Unsafe runtime log directory metadata: $bad"
      log_error "Expected owner ${owner}:${group} and mode 0750."
      log_error "Run: ${STARTUP_PERMISSION_REPAIR_COMMAND}"
      log_error "Or run: ${STARTUP_REPAIR_COMMAND}"
      return 1
    fi
    bad="$(find "$path" -type f \( ! -uid "$owner" -o ! -gid "$group" -o ! -perm 0640 \) -print -quit 2>/dev/null || true)"
    if [[ -n "$bad" ]]; then
      log_error "Unsafe runtime log file metadata: $bad"
      log_error "Expected owner ${owner}:${group} and mode 0640."
      log_error "Run: ${STARTUP_PERMISSION_REPAIR_COMMAND}"
      log_error "Or run: ${STARTUP_REPAIR_COMMAND}"
      return 1
    fi
  done

  local caddy_log
  for caddy_log in "${logs_root}/caddy/access.log" "${logs_root}/caddy/security.log"; do
    if [[ ! -e "$caddy_log" ]]; then
      install -m 0640 -o 2000 -g 2000 /dev/null "$caddy_log" || {
        log_error "Failed to create required Caddy log file: $caddy_log"
        return 1
      }
    fi
  done

  local backup_dir
  backup_dir="$(get_config_value "BACKUP_DIR" "${project_state_dir}/backups")"
  mkdir -p -- "$backup_dir" || {
    log_error "Could not create backup directory: $backup_dir"
    return 1
  }
  log_success "Runtime log paths are present with validated metadata."
  return 0
}

# Run check_age_key_health() in validation-only mode before any SOPS,
# filesystem repair, or later startup mutation so a corrupt, missing,
# wrong-permissions, or wrong-owner Age key fails closed without being changed.
#
check_age_key_health_preflight() {
  local configured_key="${SOPS_AGE_KEY_FILE:-}"

  if [[ -z "$configured_key" ]]; then
    log_error "No Age key identity was selected by the runtime configuration."
    log_error "Set SOPS_AGE_KEY_FILE in the selected environment and retry."
    return 1
  fi

  if check_age_key_health "$configured_key" --no-repair 2>/dev/null; then
    log_info "Validated selected Age key identity: ${configured_key}"
    return 0
  fi

  local repo_local_key="${SCRIPT_DIR}/secrets/keys/age-key.txt"

  log_error "Age key health check FAILED for configured path: ${configured_key}"
  log_error ""
  log_error "Startup will not invoke SOPS or perform later service/network mutations."
  log_error "Correct this selected identity, then run: sudo make key-health"
  if [[ -f "$repo_local_key" && "$configured_key" != "$repo_local_key" ]]; then
    log_warn "A repository-local key exists at ${repo_local_key}, but it will not replace the rejected configured key."
    log_warn "Repository key use is limited to explicit bootstrap/development mode:"
    log_warn "  sudo VW_CONFIG_AGE_KEY_MODE=repository ./startup.sh"
  fi
  return 1
}

# #38 — prepare_docker_secrets() skips all SOPS/filesystem operations under
# --dry-run. Previously only _startup_pull_images and _startup_start_services
# were gated; this function still ran full SOPS decryption and secret-file
# writes even in dry-run mode, which could fail on machines without a
# configured Age key and misrepresented what "dry-run" means.
#
# Under --dry-run we log the two operations that would occur so the operator
# sees the full plan, then return 0 without touching the filesystem or
# invoking SOPS/age.
prepare_docker_secrets() {
  log_info "Preparing Docker secrets from SOPS..."

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would run: check_age_key_health_preflight (verify selected Age key)"
    log_info "[DRY RUN] Would run: export_docker_secrets ${DOCKER_SECRETS_DIR} (SOPS decrypt -> secret files)"
    return 0
  fi

  check_age_key_health_preflight || return 1
  schema_validate || return 1
  validate_required_secrets "$SECRETS_FILE" || return 1
  export_docker_secrets "$DOCKER_SECRETS_DIR" || return 1
  log_success "Docker secrets prepared"
  return 0
}


validate_critical_permissions() {
  local repair_script="${PROJECT_ROOT}/utilities/repair-permissions.sh"
  local caddy_entrypoint="${PROJECT_ROOT}/caddy/entrypoint.sh"

  [[ -x "$repair_script" ]] || {
    log_error "Permission checker is missing or not executable: $repair_script"
    return 1
  }
  if ! "$repair_script" --check; then
    log_error "Unsafe permission drift detected; ordinary startup will not repair it."
    log_error "Run: ${STARTUP_PERMISSION_REPAIR_COMMAND}"
    log_error "Or run: ${STARTUP_REPAIR_COMMAND}"
    return 1
  fi
  if [[ -f "$caddy_entrypoint" && ! -x "$caddy_entrypoint" ]]; then
    log_error "Caddy entrypoint is not executable: $caddy_entrypoint"
    log_error "Run: ${STARTUP_PERMISSION_REPAIR_COMMAND}"
    log_error "Or run: ${STARTUP_REPAIR_COMMAND}"
    return 1
  fi
  log_success "Critical permission metadata validated without changes."
}

repair_critical_permissions() {
  local repair_script="${PROJECT_ROOT}/utilities/repair-permissions.sh"
  [[ -x "$repair_script" ]] || {
    log_error "Permission repair script is missing or not executable: $repair_script"
    return 1
  }
  log_info "Repairing supported runtime permission drift..."
  "$repair_script" || {
    log_error "Critical permission repair failed."
    return 1
  }
  "$repair_script" --check || {
    log_error "Critical permission post-repair validation failed."
    return 1
  }
  log_success "Supported runtime permissions reconciled and verified."
}
