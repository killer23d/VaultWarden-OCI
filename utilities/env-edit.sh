#!/usr/bin/env bash
# utilities/env-edit.sh — Edit and sync operator-edited repo .env into installed runtime env files.

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
VaultWarden-OCI Environment Manager

USAGE:
  sudo utilities/env-edit.sh sync
  sudo utilities/env-edit.sh edit
  sudo utilities/env-edit.sh status

DESCRIPTION:
  sync copies the operator-edited repository .env to
  ${PROJECT_STATE_DIR}/config/install.env, applies root-runtime-only overrides,
  then installs /etc/vaultwarden/vaultwarden.env from that generated install.env.

  Edit repo .env only. Do not manually edit ${PROJECT_STATE_DIR}/config/install.env
  or /etc/vaultwarden/vaultwarden.env; they are generated runtime artifacts.

EOF
}

repo_env_path() {
  printf '%s/.env\n' "$PROJECT_ROOT"
}

_prepare_repo_env() {
  local repo_env
  repo_env="$(repo_env_path)"
  if [[ ! -f "$repo_env" ]]; then
    log_error "Repository .env not found: $repo_env"
    return 1
  fi
  if [[ ! -r "$repo_env" ]]; then
    log_error "Repository .env is not readable: $repo_env"
    return 1
  fi
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

sync_env() {
  require_root "env sync must be run as root. Run: sudo make sync-env"

  local repo_env="${PROJECT_ROOT}/.env"
  _prepare_repo_env || return 1

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

edit_env() {
  require_root "env edit must be run as root. Run: sudo make edit-env"
  _prepare_repo_env || return 1
  local repo_env before after editor
  repo_env="$(repo_env_path)"
  before="$(sha256sum "$repo_env" | awk '{print $1}')"
  editor="${EDITOR:-nano}"
  "$editor" "$repo_env"
  after="$(sha256sum "$repo_env" | awk '{print $1}')"
  if [[ "$before" == "$after" ]]; then
    log_info "No changes detected in repo .env; generated env files were not rewritten."
    return 0
  fi
  chmod 0600 "$repo_env" || true
  log_info "Changes detected in repo .env; syncing generated runtime env files..."
  sync_env
}

status_env() {
  _prepare_repo_env || return 1
  local repo_env project_state_dir install_env
  repo_env="$(repo_env_path)"
  project_state_dir="$(_read_repo_env_value PROJECT_STATE_DIR "$repo_env")"
  project_state_dir="${project_state_dir:-/var/lib/vaultwarden}"
  install_env="${project_state_dir}/config/install.env"
  printf 'repo .env: %s\n' "$repo_env"
  printf 'install.env: %s (%s)\n' "$install_env" "$([[ -f "$install_env" ]] && echo present || echo missing)"
  printf 'systemd env: %s (%s)\n' "$ENV_FILE" "$([[ -f "$ENV_FILE" ]] && echo present || echo missing)"
}

main() {
  case "${1:-sync}" in
    sync) sync_env ;;
    edit) edit_env ;;
    status) status_env ;;
    --help|-h|help) show_help ;;
    --version|-V) print_project_version "VaultWarden-OCI" "$PROJECT_ROOT" ;;
    *)
      log_error "Unknown mode: $1"
      show_help
      return 1
      ;;
  esac
}

main "$@"
