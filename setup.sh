#!/usr/bin/env bash
# setup.sh — Public setup coordinator. Full dry-runs are strictly read-only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
CORE="${SCRIPT_DIR}/setup-main.sh"
cd "$PROJECT_ROOT"

[[ -f "$CORE" && ! -L "$CORE" ]] || {
  printf 'ERROR: setup implementation is missing or unsafe: %s\n' "$CORE" >&2
  exit 1
}

case "${1:-}" in
  secrets|systemd|help|--help|-h|--version|-V)
    exec bash "$CORE" "$@"
    ;;
esac

# Preserve metadata/help behavior regardless of argument position (for example,
# `setup.sh install --version`) without requiring root or entering an operation.
for arg in "$@"; do
  case "$arg" in
    --version|-V) exec bash "$CORE" --version ;;
    --help|-h) exec bash "$CORE" --help ;;
  esac
done

FULL_DRY_RUN=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && FULL_DRY_RUN=true
done

SOPS_DEFAULT_VERSION="v3.13.2"
SOPS_VERSION_ENV_SET=false
if [[ -n "${SOPS_VERSION+x}" && -n "${SOPS_VERSION:-}" ]]; then
  SOPS_VERSION_ENV_SET=true
fi
SOPS_VERSION="${SOPS_VERSION:-$SOPS_DEFAULT_VERSION}"

source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/validate.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/common.sh"
init_common_lib "$0"
source "${SCRIPT_DIR}/lib/operations.sh"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/defaults.sh"

_setup_parse_full_args() {
  DOMAIN=""; ADMIN_EMAIL=""; AUTO_MODE=false; SKIP_DEPS=false
  FORCE=false; USE_LATEST=false; DATA_VOLUME_DEVICE=""
  DATA_VOLUME_MOUNT="${_VW_DEFAULT_DATA_MOUNT}"
  local -a args=("$@")
  [[ "${args[0]:-}" == "install" ]] && args=("${args[@]:1}")
  set -- "${args[@]}"
  while (( $# > 0 )); do
    case "$1" in
      --domain) [[ $# -ge 2 ]] || return 2; DOMAIN="$2"; shift 2 ;;
      --email) [[ $# -ge 2 ]] || return 2; ADMIN_EMAIL="$2"; shift 2 ;;
      --auto) AUTO_MODE=true; shift ;;
      --skip-deps) SKIP_DEPS=true; shift ;;
      --force) FORCE=true; shift ;;
      --use-latest) USE_LATEST=true; shift ;;
      --data-device) [[ $# -ge 2 ]] || return 2; DATA_VOLUME_DEVICE="$2"; shift 2 ;;
      --data-mount) [[ $# -ge 2 ]] || return 2; DATA_VOLUME_MOUNT="$2"; shift 2 ;;
      --dry-run) shift ;;
      *) log_error "Unknown full-setup option: $1"; return 2 ;;
    esac
  done
  [[ -n "$DOMAIN" ]] || { log_error "--domain is required for full setup."; return 2; }
  [[ -n "$ADMIN_EMAIL" ]] || { log_error "--email is required for full setup."; return 2; }
  validate_domain "$DOMAIN" || return 2
  validate_email "$ADMIN_EMAIL" || return 2
}

_setup_require_phase() {
  [[ -x "$1" ]] || { log_error "Required setup phase is missing or not executable: $1"; return 1; }
}

_setup_full_dry_run() {
  (( EUID == 0 )) || { log_error "Must run as root."; return 1; }
  _setup_parse_full_args "$@" || return $?

  local system="${SCRIPT_DIR}/utilities/setup-system.sh"
  local storage="${SCRIPT_DIR}/utilities/setup-storage.sh"
  local env_setup="${SCRIPT_DIR}/utilities/setup-env.sh"
  local secrets="${SCRIPT_DIR}/utilities/setup-secrets.sh"
  local firewall="${SCRIPT_DIR}/utilities/setup-firewall.sh"
  local phase
  for phase in "$system" "$storage" "$env_setup" "$secrets" "$firewall"; do
    _setup_require_phase "$phase" || return 1
  done
  bash -n "$secrets" || { log_error "Secrets setup script failed syntax validation."; return 1; }

  local -a common=(--dry-run) auto=() skip=() force=() latest=() device=() _sops_flags=()
  [[ "$AUTO_MODE" == true ]] && auto=(--auto)
  [[ "$SKIP_DEPS" == true ]] && skip=(--skip-deps)
  [[ "$FORCE" == true ]] && force=(--force)
  [[ "$USE_LATEST" == true ]] && latest=(--use-latest)
  [[ "$SOPS_VERSION_ENV_SET" == "true" ]] && _sops_flags=(--sops-version "$SOPS_VERSION")
  [[ -n "$DATA_VOLUME_DEVICE" ]] && device+=(--data-device "$DATA_VOLUME_DEVICE")
  device+=(--data-mount "$DATA_VOLUME_MOUNT")

  log_header "VaultWarden-OCI Setup - Read-only Preview"
  log_info "[DRY RUN] Operation locks and operation state will not be acquired or created."
  "$system" "${auto[@]}" "${skip[@]}" "${latest[@]}" "${common[@]}" "${force[@]}" "${device[@]}" "${_sops_flags[@]}"
  "$storage" setup "${auto[@]}" "${common[@]}" "${force[@]}" "${device[@]}"
  "$env_setup" --domain "$DOMAIN" --email "$ADMIN_EMAIL" "${latest[@]}" "${common[@]}" "${force[@]}" "${device[@]}"
  local force_text=""
  [[ "$FORCE" == true ]] && force_text=" --force"
  log_info "[DRY RUN] Would run: ${secrets} bootstrap --dry-run${force_text}"
  "$firewall" --phase ufw "${auto[@]}" "${common[@]}" "${force[@]}"
  "$firewall" --phase iptables "${auto[@]}" "${common[@]}" "${force[@]}"
  if [[ "$AUTO_MODE" == true ]]; then
    log_info "[DRY RUN] Would run: ${secrets} configure --auto --skip-optional --quiet-summary --dry-run"
  else
    log_info "[DRY RUN] Would preview interactive secrets configuration without creating credential files."
  fi
  log_info "[DRY RUN] Would acquire the pinned Compose image set for first startup."
  log_info "[DRY RUN] Future image refreshes use: sudo ./utilities/maintenance-update.sh --images"
  log_success "Full setup dry-run completed without acquiring operation locks or creating state."
}

_setup_ensure_group() {
  getent group vaultwarden >/dev/null 2>&1 && return 0
  command -v groupadd >/dev/null 2>&1 || { log_error "Cannot create required shared lock group 'vaultwarden': groupadd is unavailable."; return 1; }
  groupadd --system vaultwarden || { log_error "Cannot create required shared lock group 'vaultwarden'."; return 1; }
  log_success "Created shared lock group: vaultwarden"
}

_setup_acquire_initial_images() {
  local image
  local -a images=()
  mapfile -t images < <(docker compose config --images 2>/dev/null | awk 'NF && !seen[$0]++')
  (( ${#images[@]} > 0 )) || { log_error "Could not resolve the Compose image set after environment setup."; return 1; }
  log_info "Acquiring the pinned Compose image set for first startup..."
  for image in "${images[@]}"; do
    if [[ "$image" == "vaultwarden-oci-caddy" ]]; then
      docker compose build --pull caddy || { log_error "Failed to build the pinned custom Caddy image."; return 1; }
    else
      pull_image_with_retry "$image" || { log_error "Failed to acquire required image: $image"; return 1; }
    fi
  done
  log_success "Initial pinned container image set is available locally."
  log_info "Future image refreshes use: sudo ./utilities/maintenance-update.sh --images"
}

if [[ "$FULL_DRY_RUN" == true ]]; then
  _setup_full_dry_run "$@"
  exit $?
fi

(( EUID == 0 )) || { log_error "Must run as root."; exit 1; }
_setup_ensure_group
operation_acquire --id setup --label "Setup" || exit $?
trap 'rc=$?; operation_release "$rc"; exit "$rc"' EXIT
trap 'operation_release 130; exit 130' INT
trap 'operation_release 143; exit 143' HUP TERM

if [[ "$SOPS_VERSION_ENV_SET" == "true" ]]; then
  env SOPS_VERSION="$SOPS_VERSION" bash "$CORE" "$@"
else
  bash "$CORE" "$@"
fi
operation_set_phase "images" "Acquiring initial pinned images"
_setup_acquire_initial_images
log_success "Setup and initial pinned image acquisition completed."
log_info "Next step: sudo make up"
