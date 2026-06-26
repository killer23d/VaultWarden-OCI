#!/usr/bin/env bash
# utilities/sync-env.sh — Sync operator-edited repo .env into installed runtime env files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/log.sh"
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/config.sh"
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"

ENV_DIR="${VW_SYNC_ETC_DIR:-/etc/vaultwarden}"
ENV_FILE="${ENV_DIR}/vaultwarden.env"

show_help() {
  cat <<'EOF'
VaultWarden-OCI Environment Sync

USAGE:
  sudo utilities/sync-env.sh

DESCRIPTION:
  Copies the operator-edited repository .env to
  ${PROJECT_STATE_DIR}/config/install.env, applies root-runtime-only overrides,
  then installs /etc/vaultwarden/vaultwarden.env from that generated install.env.

  Edit repo .env only. Do not manually edit ${PROJECT_STATE_DIR}/config/install.env
  or /etc/vaultwarden/vaultwarden.env; they are generated runtime artifacts.

EOF
}

_read_repo_env_value() {
  local key="$1" file="$2"
  awk -F= -v key="$key" -v sq="'" '$1 == key {
    value = substr($0, index($0, "=") + 1)
    gsub("^[\"" sq "]|[\"" sq "]$", "", value)
    found = value
  } END { if (found != "") print found }' "$file"
}

_atomic_install_env_copy() {
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
  local install_env="$1"

  # Always canonical for root-operated SOPS/Age.
  _set_env_var "SOPS_AGE_KEY_FILE" "/etc/vaultwarden/age-key.txt" "$install_env"

  # Canonical only when the installed root-owned rclone config exists.
  # Never write this path back to repo .env.
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

main() {
  case "${1:-}" in
    --help|-h)
      show_help
      return 0
      ;;
    --version|-V)
      print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"
      return 0
      ;;
    "")
      ;;
    *)
      log_error "Unknown option: $1"
      show_help
      return 1
      ;;
  esac

  require_root "sync-env must be run as root. Run: sudo make sync-env"

  local repo_env="${PROJECT_ROOT}/.env"
  if [[ ! -f "$repo_env" ]]; then
    log_error "Repository .env not found: $repo_env"
    return 1
  fi
  if [[ ! -r "$repo_env" ]]; then
    log_error "Repository .env is not readable: $repo_env"
    return 1
  fi

  local project_state_dir
  project_state_dir="$(_read_repo_env_value PROJECT_STATE_DIR "$repo_env")"
  project_state_dir="${project_state_dir:-/var/lib/vaultwarden}"
  if [[ "$project_state_dir" != /* ]]; then
    log_error "PROJECT_STATE_DIR must be absolute: $project_state_dir"
    return 1
  fi

  local config_dir="${project_state_dir}/config"
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

main "$@"
