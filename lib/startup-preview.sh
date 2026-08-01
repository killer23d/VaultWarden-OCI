# shellcheck shell=bash

_show_dry_run_configuration_plan() {
  log_info "[DRY RUN] Selected configuration source: ${VW_CONFIG_SELECTED_ENV_SOURCE:-unknown}"
  log_info "[DRY RUN] Selected configuration file: ${VW_CONFIG_SELECTED_ENV_FILE:-unknown}"
  log_info "[DRY RUN] Domain: ${DOMAIN:-<unset>}"
  log_info "[DRY RUN] State directory: ${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}"
  if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then
    log_info "[DRY RUN] Data volume: ${DATA_VOLUME_DEVICE} -> ${DATA_VOLUME_MOUNT:-<unset>}"
  else
    log_info "[DRY RUN] Data volume: boot-only mode"
  fi
  log_info "[DRY RUN] Selected Age key path: ${SOPS_AGE_KEY_FILE:-<unset>}"
  log_info "[DRY RUN] Secrets source: ${SECRETS_FILE:-<unset>}"
}

_startup_dry_run_exact_metadata_ok() {
  local path="$1" expected_type="$2" owner="$3" group="$4" mode="$5"
  local actual_owner actual_group actual_mode

  [[ ! -L "$path" ]] || return 1
  case "$expected_type" in
    file) [[ -f "$path" ]] || return 1 ;;
    directory) [[ -d "$path" ]] || return 1 ;;
    *) return 1 ;;
  esac
  actual_owner="$(_common_stat_owner "$path")" || return 1
  actual_group="$(_common_stat_group "$path")" || return 1
  actual_mode="$(_common_stat_mode "$path")" || return 1
  [[ "$actual_owner:$actual_group" == "$owner:$group" && "$actual_mode" == "$mode" ]]
}

_report_dry_run_permission_state() {
  local state_dir="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}"
  local selected_env="${VW_CONFIG_SELECTED_ENV_FILE:-}"
  local drift_count=0 path
  local -a paths=(
    "${SOPS_AGE_KEY_FILE:-}"
    "${state_dir}/config"
    "${state_dir}/config/install.env"
    "${state_dir}/config/dr-manifest.env"
    "${state_dir}/secrets"
    "${state_dir}/secrets/secrets.yaml"
    "${PROJECT_ROOT}/.env"
    "${PROJECT_ROOT}/secrets"
    "${PROJECT_ROOT}/secrets/keys/age-key.txt"
    "${PROJECT_ROOT}/.sops.yaml"
    "${PROJECT_ROOT}/secrets/secrets.yaml"
    /run/vaultwarden-oci/managed-secrets
    /run/vaultwarden-oci/secrets
  )
  local -A seen=()

  log_info "[DRY RUN] Checking permission metadata without changing files..."

  if [[ -n "$selected_env" && ( -e "$selected_env" || -L "$selected_env" ) ]]; then
    seen["$selected_env"]=1
    if [[ "${VW_CONFIG_SELECTED_ENV_SOURCE:-}" == "installed" ]]; then
      if _startup_dry_run_exact_metadata_ok "$selected_env" file root root 600; then
        log_info "[DRY RUN] Permission metadata is correct: $selected_env (root:root 600)"
      else
        log_warn "[DRY RUN] Permission metadata would require repair: $selected_env (expected regular file root:root 600)"
        drift_count=$((drift_count + 1))
      fi
    elif assert_known_path_permissions "$selected_env"; then
      log_info "[DRY RUN] Permission metadata is correct: $selected_env"
    else
      log_warn "[DRY RUN] Permission metadata would require repair: $selected_env"
      drift_count=$((drift_count + 1))
    fi
  fi

  for path in "${paths[@]}"; do
    [[ -n "$path" ]] || continue
    [[ -z "${seen[$path]:-}" ]] || continue
    seen["$path"]=1
    if [[ ! -e "$path" && ! -L "$path" ]]; then
      log_info "[DRY RUN] Permission target is not present yet: $path"
      continue
    fi
    if assert_known_path_permissions "$path"; then
      log_info "[DRY RUN] Permission metadata is correct: $path"
    else
      log_warn "[DRY RUN] Permission metadata would require repair: $path"
      drift_count=$((drift_count + 1))
    fi
  done

  if [[ -d /run/vaultwarden-oci/secrets ]]; then
    while IFS= read -r -d '' path; do
      if assert_known_path_permissions "$path"; then
        log_info "[DRY RUN] Permission metadata is correct: $path"
      else
        log_warn "[DRY RUN] Permission metadata would require repair: $path"
        drift_count=$((drift_count + 1))
      fi
    done < <(find /run/vaultwarden-oci/secrets -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
  fi

  local caddy_ep="${PROJECT_ROOT}/caddy/entrypoint.sh"
  if [[ -f "$caddy_ep" ]]; then
    if [[ -x "$caddy_ep" ]]; then
      log_info "[DRY RUN] Execute permission is correct: $caddy_ep"
    else
      log_warn "[DRY RUN] Execute permission would require repair: $caddy_ep"
      drift_count=$((drift_count + 1))
    fi
  fi

  if (( drift_count > 0 )); then
    log_warn "[DRY RUN] Detected ${drift_count} repairable permission metadata issue(s); no repair was attempted."
    log_warn "[DRY RUN] Repair command: sudo ./utilities/repair-permissions.sh"
    _STARTUP_WARNINGS+=("Dry-run found permission metadata drift; run: sudo ./utilities/repair-permissions.sh")
  else
    log_success "[DRY RUN] Checked permission metadata is already correct."
  fi
  return 0
}

# Required commands are declared in _VW_DEFAULT_REQUIRED_COMMANDS (lib/defaults.sh).
# Add a new dependency there; no edit to this function is needed.
validate_prerequisites() {
  log_info "Validating prerequisites..."

  local missing_commands=()

  for cmd in "${_VW_DEFAULT_REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_commands+=("$cmd")
    fi
  done

  if [ ${#missing_commands[@]} -gt 0 ]; then
    log_error "Missing required commands: ${missing_commands[*]}"
    return 1
  fi

  if ! python3 -c "import yaml" 2>/dev/null; then
    log_error "python3-yaml (PyYAML) is not installed — required for secrets parsing"
    log_error "Install hint: pip install pyyaml  or  sudo apt install python3-yaml"
    return 1
  fi

  if ! check_docker_available; then
    log_error "Docker daemon is not running or not accessible"
    return 1
  fi

  if [ ! -f "docker-compose.yml" ]; then
    log_error "docker-compose.yml not found"
    return 1
  fi

  log_success "Prerequisites validated"
  return 0
}


# Ensure all PROJECT_STATE_DIR subdirectories required by Docker bind mounts
# exist on the host before `docker compose up`. Use absolute paths so
# separate-volume installs create directories on the data volume rather than
# under PROJECT_ROOT.
#
# prepare_log_directories() handles logs/ and backups/ with ownership logic;
# this function covers the remaining non-log subtrees.
