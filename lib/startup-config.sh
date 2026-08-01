# shellcheck shell=bash

warn_plaintext_secret_overrides() {
  local warned=false

  if [[ -n "${EMAIL_API_TOKEN:-}" ]]; then
    log_warn "EMAIL_API_TOKEN is set in the live environment. This overrides the SOPS-managed email_api_token secret and can cause split-brain configuration."
    warned=true
  fi

  if [[ -n "${SMTP_PASSWORD:-}" ]]; then
    log_warn "SMTP_PASSWORD is set in the live environment. This forces direct external SMTP auth and overrides the SOPS-managed smtp_password secret."
    warned=true
  fi

  if [[ "$warned" == "true" ]]; then
    log_warn "Best practice: keep EMAIL_API_TOKEN and SMTP_PASSWORD out of .env and manage them only through secrets.yaml / SOPS."
  fi
}

# Cross-check EMAIL_MODE against the required secret so operators get an
# actionable warning at startup instead of a silent failure on first email
# send. This remains a warning because email is not required for the stack to
# start.
#
# Valid modes are declared in _VW_DEFAULT_EMAIL_MODES (lib/defaults.sh).
# Add a new mode there; no edit to this function is needed.
check_email_config_consistency() {
  # VWOCI-PRR-PATCH-03: canonical modes are declared in lib/defaults.sh.
  local email_mode="${EMAIL_MODE:-auto}"
  local secrets_dir="$DOCKER_SECRETS_DIR"
  case "$email_mode" in
    api)
      local token_file="${secrets_dir}/email_api_token"
      if [[ ! -s "$token_file" ]]; then
        log_warn "EMAIL_MODE=api is set but '${token_file}' is absent or empty."
        log_warn "Email API delivery will fail until the token is populated."
        log_warn "Fix: ./utilities/secrets-rotate.sh email_api_token"
      fi
      ;;
    smtp|direct|host)
      local pw_file="${secrets_dir}/smtp_password"
      if [[ "$email_mode" == "host" ]]; then
        log_warn "EMAIL_MODE=host is a deprecated compatibility alias; use EMAIL_MODE=direct."
      fi
      if [[ ! -s "$pw_file" ]]; then
        log_warn "EMAIL_MODE=${email_mode} requires '${pw_file}', but it is absent or empty."
        log_warn "Direct SMTP authentication will fail on first send."
        log_warn "Fix: ./utilities/secrets-rotate.sh smtp_password"
      fi
      ;;
    auto)
      ;;
    *)
      local valid_modes
      valid_modes="$(IFS='|'; echo "${_VW_DEFAULT_EMAIL_MODES[*]}")"
      log_warn "EMAIL_MODE='${email_mode}' is not a recognised value (${valid_modes})."
      log_warn "Email delivery may fail."
      ;;
  esac
  return 0
}

warn_env_drift() {
  local repo_env="${PROJECT_ROOT}/.env"
  local installed_envs=(
    "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/config/install.env"
    "${VW_CONFIG_INSTALLED_ENV_FILE:-/etc/vaultwarden/vaultwarden.env}"
  )

  [[ -r "$repo_env" ]] || return 0

  local keys=(
    SMTP_FROM
    SMTP_FROM_NAME
    ALLOWED_SENDER_DOMAINS
    MAILGUN_DOMAIN
    EMAIL_MODE
    EMAIL_PROVIDER
    SMTP_HOST
    SMTP_PORT
    SMTP_SECURITY
  )

  local installed_env key repo_value installed_value drift_found=false
  for installed_env in "${installed_envs[@]}"; do
    [[ -r "$installed_env" ]] || continue
    for key in "${keys[@]}"; do
      repo_value="$(_read_env_value "$key" "$repo_env")"
      installed_value="$(_read_env_value "$key" "$installed_env")"
      if [[ "$repo_value" != "$installed_value" ]]; then
        if [[ "$drift_found" == "false" ]]; then
          log_warn "Repository .env differs from generated runtime env file(s) for non-secret email settings."
          log_warn "Run: sudo make sync-env, then sudo make restart"
          drift_found=true
        fi
        log_warn "  ${installed_env}: ${key}: repo='${repo_value}' installed='${installed_value}'"
      fi
    done
  done
}

validate_caddy_version_pin() {
  if [[ "${CADDY_VERSION:-}" == "latest" ]]; then
    log_error "CADDY_VERSION=latest is invalid for this stack's custom Caddy build."
    log_error "The Dockerfile uses caddy:\${CADDY_VERSION}-builder; caddy:latest-builder is not published."
    log_error "Fix .env and installed env files by setting: CADDY_VERSION=2.11.4"
    log_error "Then rerun setup-env or startup. Example: sudo sed -i 's/^CADDY_VERSION=.*/CADDY_VERSION=2.11.4/' .env"
    return 1
  fi
  return 0
}

load_environment() {
  log_info "Loading environment configuration..."

  if [[ -f ".env" && ! -r ".env" ]]; then
    log_error ".env is not readable by the current user ($(id -un))."
    log_error "Run startup through the root-operated path: sudo make up"
    return 1
  fi

  load_project_environment || return 1
  validate_caddy_version_pin || return 1
  warn_env_drift || true
  DOCKER_SECRETS_DIR="/run/vaultwarden-oci/secrets"
  export DOCKER_SECRETS_DIR
  log_success "Environment loaded"

  log_info "Note: changes to compose/.env values are applied to containers only when they are recreated."
}
