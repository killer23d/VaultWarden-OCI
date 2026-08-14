#!/usr/bin/env bash
# setup.sh — Install and configure VaultWarden-OCI.
# shellcheck disable=SC1091

set -euo pipefail

# Set SOPS_VERSION to use a specific release. When unset or blank, setup uses
# the repository-pinned production default. Pass --use-latest only when an
# operator explicitly wants mutable upstream versions for this run.
#
# Examples:
#   SOPS_VERSION="v3.9.4"
#   SOPS_VERSION=""
#
SOPS_DEFAULT_VERSION="v3.13.3"
SOPS_VERSION_ENV_SET=false
if [[ -n "${SOPS_VERSION+x}" && -n "${SOPS_VERSION:-}" ]]; then
    SOPS_VERSION_ENV_SET=true
fi
SOPS_VERSION="${SOPS_VERSION:-$SOPS_DEFAULT_VERSION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

unset VW_ADMIN_PLAIN_FILE VW_ADMIN_HASH_FILE CADDY_PLAIN_FILE CADDY_HASH_FILE
unset TMP_WORKDIR
SETUP_OPERATION_GUARD_HELD=false

_setup_cleanup_warn() {
    local message="$1"
    if declare -F log_warn >/dev/null 2>&1; then
        log_warn "$message"
    else
        printf 'WARNING: %s\n' "$message" >&2
    fi
}

_setup_create_sensitive_workspace() {
    [[ -z "${TMP_WORKDIR:-}" ]] || return 0
    TMP_WORKDIR="$(create_sensitive_workspace setup)" || return 1
    export VW_ADMIN_PLAIN_FILE="${TMP_WORKDIR}/vw_admin_plain"
    export VW_ADMIN_HASH_FILE="${TMP_WORKDIR}/vw_admin_hash"
    export CADDY_PLAIN_FILE="${TMP_WORKDIR}/caddy_plain"
    export CADDY_HASH_FILE="${TMP_WORKDIR}/caddy_hash"
}

_setup_remove_sensitive_workspace() {
    local original_status="${1:-0}" cleanup_status=0
    local workspace="${TMP_WORKDIR:-}"

    { set +x; } 2>/dev/null
    if [[ -n "$workspace" ]]; then
        if remove_sensitive_workspace "$workspace"; then
            unset TMP_WORKDIR
            unset VW_ADMIN_PLAIN_FILE VW_ADMIN_HASH_FILE CADDY_PLAIN_FILE CADDY_HASH_FILE
        else
            cleanup_status=$?
            _setup_cleanup_warn "Failed to remove the setup sensitive workspace: $workspace"
        fi
    fi

    if (( original_status != 0 )); then
        return "$original_status"
    fi
    return "$cleanup_status"
}

_setup_finalize() {
    local original_status="$1" release_status=0 cleanup_status=0

    { set +x; } 2>/dev/null
    if [[ "${SETUP_OPERATION_GUARD_HELD:-false}" == "true" ]] &&
       declare -F operation_release >/dev/null 2>&1; then
        operation_release "$original_status" || release_status=$?
        SETUP_OPERATION_GUARD_HELD=false
    fi
    _setup_remove_sensitive_workspace "$original_status" || cleanup_status=$?

    if (( original_status != 0 )); then
        return "$original_status"
    fi
    (( cleanup_status == 0 )) || return "$cleanup_status"
    (( release_status == 0 )) || return "$release_status"
    return 0
}

_setup_on_exit() {
    local original_status="$1" final_status=0

    trap - EXIT INT HUP TERM
    _setup_finalize "$original_status" || final_status=$?
    exit "$final_status"
}

_setup_on_signal() {
    local signal_status="$1"

    trap - EXIT INT HUP TERM
    _setup_finalize "$signal_status" || true
    exit "$signal_status"
}

trap '_setup_on_exit $?' EXIT
trap '_setup_on_signal 129' HUP
trap '_setup_on_signal 130' INT
trap '_setup_on_signal 143' TERM

REQUIRED_LIBS=(
  "lib/log.sh"
  "lib/validate.sh"
  "lib/config.sh"
  "lib/common.sh"
  "lib/operations.sh"
  "lib/crypto.sh"
  "lib/docker.sh"
  "lib/backup-utils.sh"
  "lib/secrets.sh"
  "lib/setup-credentials.sh"
  "lib/defaults.sh"
  "lib/storage.sh"
)
for lib in "${REQUIRED_LIBS[@]}"; do
    if [[ ! -f "${SCRIPT_DIR}/${lib}" ]]; then
        echo "ERROR: Required library not found: ${SCRIPT_DIR}/${lib}" >&2
        exit 1
    fi
done

source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/validate.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/common.sh"
init_common_lib "$0"
source "${SCRIPT_DIR}/lib/operations.sh"
source "${SCRIPT_DIR}/lib/crypto.sh"
DOCKER_PROJECT_LABEL="${DOCKER_PROJECT_LABEL:-label=com.docker.compose.project=vaultwarden-oci}"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/backup-utils.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/setup-credentials.sh"
source "${SCRIPT_DIR}/lib/defaults.sh"
source "${SCRIPT_DIR}/lib/storage.sh"

DOMAIN=""
ADMIN_EMAIL=""
AUTO_MODE=false
USE_LATEST=false
SKIP_DEPS=false
FORCE=false
DRY_RUN=false
PHASE=""
PHASE_ARGS=()
export ENTROPY_THRESHOLD=200
export ENTROPY_MAX_WAIT=60
# Storage mode variables. Defaults are overridden by --data-device/--data-mount
# or by DATA_VOLUME_DEVICE/DATA_VOLUME_MOUNT already set in the environment.
DATA_VOLUME_DEVICE="${DATA_VOLUME_DEVICE:-}"
DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}"
DATA_VOLUME_DEVICE_EXPLICIT=false
DATA_VOLUME_MOUNT_EXPLICIT=false

show_help() {
    cat << 'EOF' | sed "s|@DEFAULT_DATA_MOUNT@|${_VW_DEFAULT_DATA_MOUNT}|g"
VaultWarden-OCI Setup Tool — Security Hardened Edition

USAGE:
    sudo ./setup.sh install --domain DOMAIN --email EMAIL [OPTIONS]  # Full setup
    sudo ./setup.sh secrets [OPTIONS]                                # Secrets phase only
    sudo ./setup.sh systemd <install|remove|validate|status> [OPTIONS]  # Systemd phase

SUBCOMMANDS:
    install    Run the full setup workflow.
    secrets    Configure encrypted secrets (admin password, API tokens, SMTP, etc.)
               Run this after editing .env with your Cloudflare zone / email settings.
    systemd    Install, validate, or remove VaultWarden systemd timers.
               Sub-actions: install | remove | validate | status

FULL SETUP OPTIONS (used after install):
  --auto              Non-interactive install. Auto-generates administrator passwords;
                      external credentials (CF tokens, SMTP) remain as CHANGE_ME
                      placeholders — the post-install summary lists exact commands
                      to rotate them. Does NOT imply --use-latest.
  --use-latest        Explicit override: use current live upstream component versions
                      for this run instead of the repository-pinned normal defaults.
                      Caddy remains pinned because xcaddy builds require a version tag.
  --skip-deps         Skip dependency installation (assumes already installed).
  --force             Overwrite existing .env, secrets, and docker-compose files.
                      The existing operational Age key is retained, but current
                      configuration and encrypted secrets may be replaced. Export
                      a recovery kit first so current credentials can be restored. Run
                      'sudo ./utilities/secrets-export-recovery-kit.sh' BEFORE using
                      --force on a running installation. To confirm you understand,
                      set VW_FORCE_ACK=I_UNDERSTAND_OVERWRITING_CURRENT_STATE in the
                      environment (or type YES at the interactive prompt).
  --dry-run           Print what would happen without making any changes.
  --data-device DEV   Use DEV as the dedicated VaultWarden data volume.
                      Existing ext4/xfs filesystems require explicit operator
                      confirmation. Blank devices are formatted only when
                      DATA_VOLUME_FORCE_FORMAT=true is set. A Docker systemd
                      drop-in ensures the stack never starts without this mount.
                      Example: --data-device /dev/disk/by-id/your-volume
  --data-mount PATH   Mount point for the data volume (default: @DEFAULT_DATA_MOUNT@).
                      Must match PROJECT_STATE_DIR when DATA_VOLUME_DEVICE is set.

GLOBAL OPTIONS:
  --help, -h          Show this help and exit.
  --version, -V       Print the VaultWarden-OCI version and exit.

EXAMPLES:
    # ── First-time setup ──────────────────────────────────────────
    sudo ./setup.sh install --domain vault.example.com --email admin@example.com
    sudo ./setup.sh install --domain vault.example.com --email admin@example.com --auto

    # ── Secrets configuration ─────────────────────────────────────
    sudo ./setup.sh secrets              # Interactive credential setup
    sudo ./setup.sh secrets --auto       # Automated with generated passwords
    sudo ./setup.sh secrets --force      # Reconfigure without prompting
    sudo ./setup.sh secrets --skip-optional   # Skip push notification keys
    sudo ./setup.sh secrets --export-recovery-kit

    # ── Systemd timer management ──────────────────────────────────
    sudo ./setup.sh systemd install      # Install and enable all timers
    sudo ./setup.sh systemd validate     # Detect split-brain vs /opt/
    sudo ./setup.sh systemd status       # Show timer status
    sudo ./setup.sh systemd remove       # Disable and remove all timers
    sudo ./setup.sh systemd install --dry-run

EOF
}

# Full setup is available only through the explicit `install` subcommand.
_require_cli_value() {
    local opt="$1" value="${2-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        log_error "Option '$opt' requires a value."
        show_help
        exit 1
    fi
}

if [[ $# -eq 0 ]]; then
    log_error "Full setup requires the 'install' subcommand."
    log_error "Use: sudo ./setup.sh install --domain DOMAIN --email EMAIL [OPTIONS]"
    show_help
    exit 1
fi

if [[ $# -gt 0 ]]; then
    case "$1" in
        install)
            shift
            ;;
        secrets)
            PHASE="secrets"
            shift
            PHASE_ARGS=("$@")
            set -- # Clear $@ so the while loop below is a no-op.
            ;;
        systemd)
            PHASE="systemd"
            shift
            PHASE_ARGS=("$@")
            set --
            ;;
        help|--help|-h)
            show_help; exit 0
            ;;
        --version|-V)
            printf 'VaultWarden-OCI %s\n' "$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo "unknown")"
            exit 0
            ;;
        --*)
            log_error "Full setup requires the 'install' subcommand."
            log_error "Use: sudo ./setup.sh install --domain DOMAIN --email EMAIL [OPTIONS]"
            exit 1
            ;;
        *)
            log_error "Unknown subcommand: '$1'"
            log_error "Valid subcommands: install | secrets | systemd"
            log_error "For full setup use: sudo ./setup.sh install --domain DOMAIN --email EMAIL [OPTIONS]"
            log_error "Run './setup.sh --help' for usage."
            show_help; exit 1
            ;;
    esac
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)       _require_cli_value "$1" "${2-}"; DOMAIN="$2";              shift 2 ;;
        --email)        _require_cli_value "$1" "${2-}"; ADMIN_EMAIL="$2";         shift 2 ;;
        --auto)         AUTO_MODE=true;            shift ;;
        --use-latest)   USE_LATEST=true;           shift ;;
        --skip-deps)    SKIP_DEPS=true;            shift ;;
        --force)        FORCE=true;                shift ;;
        --dry-run)      DRY_RUN=true;              shift ;;
        --data-device)  _require_cli_value "$1" "${2-}"; DATA_VOLUME_DEVICE="$2"; DATA_VOLUME_DEVICE_EXPLICIT=true; shift 2 ;;
        --data-mount)   _require_cli_value "$1" "${2-}"; DATA_VOLUME_MOUNT="$2"; DATA_VOLUME_MOUNT_EXPLICIT=true; shift 2 ;;
        --help|-h)      show_help; exit 0 ;;
        --version|-V)   printf 'VaultWarden-OCI %s\n' "$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo "unknown")"; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if [[ "$USE_LATEST" == "true" && "$SOPS_VERSION_ENV_SET" == "true" ]]; then
    log_error "--use-latest cannot be combined with SOPS_VERSION from the environment; choose one SOPS version source."
    exit 1
fi


# ---------------------------------------------------------------------------
# _warn_force_destructive
#
# Prominent warning for `--force`, which can replace current configuration and
# encrypted secrets while retaining the existing operational Age key.
# ---------------------------------------------------------------------------
_warn_force_destructive() {
    local term_cols box_width inner_width border

    if [[ -t 1 ]] && command -v tput &>/dev/null; then
        term_cols=$(tput cols 2>/dev/null || echo 0)
    else
        term_cols=0
    fi

    [[ "${term_cols}" =~ ^[0-9]+$ && "${term_cols}" -gt 0 ]] || term_cols=72

    (( term_cols < 64  )) && term_cols=64
    (( term_cols > 100 )) && term_cols=100

    box_width=$(( term_cols - 2 ))
    inner_width=$(( box_width - 4 ))

    border=$(printf '═%.0s' $(seq 1 "${box_width}"))

    printf '\n%s╔%s╗%s\n' "${COLOR_BOLD_RED}" "${border}" "${COLOR_RESET}"
    printf "%s║  %-${inner_width}s  ║%s\n" \
        "${COLOR_BOLD_RED}" "⚠  DESTRUCTIVE: --force MAY OVERWRITE CURRENT STATE" "${COLOR_RESET}"
    printf "%s║  %-${inner_width}s  ║%s\n" \
        "${COLOR_BOLD_RED}" "The existing operational Age key is retained." "${COLOR_RESET}"
    printf "%s║  %-${inner_width}s  ║%s\n" \
        "${COLOR_BOLD_RED}" "--force does NOT rotate the Age key." "${COLOR_RESET}"
    printf "%s║  %-${inner_width}s  ║%s\n" \
        "${COLOR_BOLD_RED}" "Export a recovery kit first for rollback/recovery." "${COLOR_RESET}"
    printf "%s║  %-${inner_width}s  ║%s\n" \
        "${COLOR_BOLD_RED}" "Run first: sudo ./utilities/secrets-export-recovery-kit.sh" "${COLOR_RESET}"
    printf '%s╚%s╝%s\n\n' "${COLOR_BOLD_RED}" "${border}" "${COLOR_RESET}"
}

_phase_failed() {
    local num="$1" label="$2"; shift 2
    log_error "Phase ${num} (${label}) failed"
    local hint
    for hint in "$@"; do
        log_hint "$hint"
    done
    exit 1
}

_confirm_force_acknowledgement() {
    local answer="" prompt_timeout=300

    [[ "$FORCE" == "true" && "$DRY_RUN" != "true" ]] || return 0

    case "${VW_FORCE_ACK:-}" in
        I_UNDERSTAND_OVERWRITING_CURRENT_STATE)
            return 0
            ;;
    esac

    _warn_force_destructive
    if [[ -t 0 ]]; then
        # Keep the production timeout fixed; the shorter value is available
        # only to the focused acknowledgement test hook below.
        if [[ "${VW_TEST_MODE:-false}" == "true" \
            && "${VW_SETUP_TEST_FORCE_ACK_ONLY:-false}" == "true" \
            && "${VW_SETUP_TEST_FORCE_ACK_TIMEOUT:-}" =~ ^[1-9][0-9]*$ ]]; then
            prompt_timeout="$VW_SETUP_TEST_FORCE_ACK_TIMEOUT"
        fi
        if ! IFS= read -r -t "$prompt_timeout" \
            -p "Type YES to confirm you have exported a recovery kit: " answer; then
            printf '\n' >&2
            log_error "No confirmation received within 5 minutes. The destructive setup --force operation was not performed."
            return 1
        fi
        if [[ "$answer" != "YES" ]]; then
            log_info "Aborting setup --force at operator request."
            return 1
        fi
        return 0
    fi

    log_hint "Export your recovery kit first: sudo ./utilities/secrets-export-recovery-kit.sh"
    log_hint "Non-interactive --force requires: VW_FORCE_ACK=I_UNDERSTAND_OVERWRITING_CURRENT_STATE"
    return 2
}

# FORCE safety gate.
# This must run before any validation so --dry-run --force can still preview
# without triggering the prompt.
_force_ack_rc=0
_confirm_force_acknowledgement || _force_ack_rc=$?
if [[ "${VW_TEST_MODE:-false}" == "true" \
    && "${VW_SETUP_TEST_FORCE_ACK_ONLY:-false}" == "true" ]]; then
    exit "$_force_ack_rc"
fi
(( _force_ack_rc == 0 )) || exit "$_force_ack_rc"
unset _force_ack_rc

if [[ -z "$PHASE" ]] && { [[ -z "$DOMAIN" ]] || [[ -z "$ADMIN_EMAIL" ]]; }; then show_help; exit 1; fi
if [[ -z "$PHASE" ]] && ! validate_domain "$DOMAIN"; then log_error "Invalid domain format"; exit 1; fi
if [[ -z "$PHASE" ]] && ! validate_email "$ADMIN_EMAIL"; then log_error "Invalid email format"; exit 1; fi


show_post_install_summary() {
  local mode="${1:-interactive}"
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "[DRY RUN] Would publish a root-only setup credential handoff after all required phases pass."
    return 0
  fi

  local age_key_file credential_file
  age_key_file="$(resolve_age_key_path 2>/dev/null)" || {
    log_error "Cannot publish setup credentials: operational Age identity is unavailable."
    return 1
  }

  local capture_count=0 capture_path
  for capture_path in \
    "${VW_ADMIN_PLAIN_FILE:-}" "${VW_ADMIN_HASH_FILE:-}" \
    "${CADDY_PLAIN_FILE:-}" "${CADDY_HASH_FILE:-}"; do
    [[ -n "$capture_path" && -s "$capture_path" ]] && capture_count=$((capture_count + 1))
  done
  if (( capture_count != 4 )); then
    if (( capture_count == 0 )) && [[ "${SETUP_SECRETS_PREEXISTED:-false}" == "true" ]]; then
      if ! _setup_remove_sensitive_workspace 0; then
        log_error "Sensitive temporary workspace cleanup failed; setup is not complete."
        return 1
      fi
      printf '\n'
      log_success "Setup completed without printing secret values."
      log_info "Existing secrets were retained; no new setup-credentials file was created."
      log_info "Export the separate full recovery kit later with: sudo ./edit-secrets.sh export-recovery-kit"
      return 0
    fi
    if [[ "$mode" == "auto" || $capture_count -ne 0 ]]; then
      log_error "Cannot publish setup credentials: generated plaintext/hash capture is incomplete."
      return 1
    fi
    if ! _setup_remove_sensitive_workspace 0; then
      log_error "Sensitive temporary workspace cleanup failed; setup is not complete."
      return 1
    fi
    printf '\n'
    log_success "Setup completed without printing secret values."
    log_info "No setup-credentials file was created because interactive secrets were not auto-generated."
    log_info "Export the separate full recovery kit later with: sudo ./edit-secrets.sh export-recovery-kit"
    return 0
  fi

  credential_file="$(publish_setup_credentials \
    "$age_key_file" "$VW_ADMIN_PLAIN_FILE" "$VW_ADMIN_HASH_FILE" \
    "$CADDY_PLAIN_FILE" "$CADDY_HASH_FILE")" || {
      log_error "Secure setup-credential publication failed; setup is not complete."
      return 1
    }

  if ! _setup_remove_sensitive_workspace 0; then
    log_error "Protected handoff was published, but sensitive temporary cleanup failed; setup is not complete."
    return 1
  fi
  printf '\n'
  printf '╭──────────────────────────────────────────────────────────────────────────────╮\n'
  printf '│  SETUP CREDENTIALS SAVED                                                     │\n'
  printf '├──────────────────────────────────────────────────────────────────────────────┤\n'
  local credential_dir credential_name
  credential_dir="${credential_file%/*}/"
  credential_name="${credential_file##*/}"
  printf '│  %-76s│\n' "$credential_dir"
  printf '│  %-76s│\n' "$credential_name"
  printf '│  Owner          root:root                                                    │\n'
  printf '│  Permissions    0600                                                         │\n'
  printf '│  Credentials    3                                                            │\n'
  printf '│                                                                              │\n'
  printf '│  ✓ SOPS Age identity                                                        │\n'
  printf '│  ✓ Vaultwarden admin password                                                │\n'
  printf '│  ✓ Caddy admin password                                                      │\n'
  printf '│                                                                              │\n'
  printf '│  No credential values were written to terminal output.                      │\n'
  printf '╰──────────────────────────────────────────────────────────────────────────────╯\n'
  printf '\n'
  log_info "Configure external provider secrets with: sudo ./edit-secrets.sh rotate FIELD"
  log_info "Start and validate with: sudo make up && sudo make health"
  log_warn "After copying the handoff offline, remove it explicitly: sudo rm -f '$credential_file'"
  return 0
}

_verify_required_utilities() {
    local utils=(
        "${SCRIPT_DIR}/utilities/setup-system.sh"
        "${SCRIPT_DIR}/utilities/setup-storage.sh"
        "${SCRIPT_DIR}/utilities/setup-env.sh"
        "${SCRIPT_DIR}/utilities/setup-secrets.sh"
        "${SCRIPT_DIR}/utilities/setup-firewall.sh"
        "${SCRIPT_DIR}/utilities/setup-systemd.sh"
        "${SCRIPT_DIR}/utilities/setup-crowdsec.sh"
        "${SCRIPT_DIR}/utilities/uninstall-vaultwarden.sh"
    )
    for u in "${utils[@]}"; do
        _require_script "$u"
    done
}


main() {
    log_header "VaultWarden-OCI Setup - Security Hardened Edition"

    if [[ -n "$PHASE" ]]; then
        case "$PHASE" in
            secrets)
                exec "${SCRIPT_DIR}/utilities/setup-secrets.sh" configure "${PHASE_ARGS[@]}"
                ;;
            systemd)
                exec "${SCRIPT_DIR}/utilities/setup-systemd.sh" "${PHASE_ARGS[@]}"
                ;;
        esac
    fi

    if ! is_root; then log_error "Must run as root."; exit 1; fi

    operation_acquire \
        --id setup \
        --label "Setup" \
        --specific-lock /run/lock/vaultwarden-setup.lock || exit $?
    SETUP_OPERATION_GUARD_HELD=true

    _verify_required_utilities

    if [[ "$USE_LATEST" == "true" ]]; then
        log_info "SOPS version: will resolve latest from GitHub because --use-latest was requested"
    elif [[ "$SOPS_VERSION_ENV_SET" == "true" ]]; then
        log_info "SOPS version requested: ${SOPS_VERSION}"
    else
        log_info "SOPS version pinned default: ${SOPS_VERSION}"
    fi

    local _dry=() _force=() _auto=() _skip_deps=() _use_latest=()
    [[ "$DRY_RUN"   == "true" ]] && _dry=(--dry-run)
    [[ "$FORCE"     == "true" ]] && _force=(--force)
    [[ "$AUTO_MODE" == "true" ]] && _auto=(--auto)
    [[ "$SKIP_DEPS" == "true" ]] && _skip_deps=(--skip-deps)
    [[ "$USE_LATEST" == "true" ]] && _use_latest=(--use-latest)

    local _dev_flags=()
    [[ "$DATA_VOLUME_DEVICE_EXPLICIT" == "true" ]] && _dev_flags+=(--data-device "$DATA_VOLUME_DEVICE")
    [[ "$DATA_VOLUME_MOUNT_EXPLICIT" == "true" ]] && _dev_flags+=(--data-mount "$DATA_VOLUME_MOUNT")

    local _sops_flags=()
    [[ "$SOPS_VERSION_ENV_SET" == "true" ]] && _sops_flags=(--sops-version "$SOPS_VERSION")

    operation_set_phase "1" "System setup"
    log_phase 1 6 "System setup"
    "${SCRIPT_DIR}/utilities/setup-system.sh" \
        "${_auto[@]}" "${_skip_deps[@]}" "${_use_latest[@]}" "${_dry[@]}" "${_force[@]}" \
        "${_dev_flags[@]}" "${_sops_flags[@]}" \
        || _phase_failed 1 "System setup"             "Check missing packages: sudo apt-get update && sudo apt-get install -y docker.io age sops 7zip python3-argon2 python3-bcrypt"             "Re-run this phase: sudo ./utilities/setup-system.sh"             "If dependencies are already installed, re-run setup with --skip-deps"

    operation_set_phase "2" "Storage setup"
    log_phase 2 6 "Storage setup"
    "${SCRIPT_DIR}/utilities/setup-storage.sh" setup \
        "${_auto[@]}" "${_dry[@]}" "${_force[@]}" "${_dev_flags[@]}" \
        || _phase_failed 2 "Storage setup"             "Verify data devices and mounts: lsblk && findmnt"             "Re-run this phase: sudo ./utilities/setup-storage.sh setup"

    operation_set_phase "3" "Environment configuration"
    log_phase 3 6 "Environment configuration"
    "${SCRIPT_DIR}/utilities/setup-env.sh" \
        --domain "$DOMAIN" --email "$ADMIN_EMAIL" \
        "${_use_latest[@]}" "${_dry[@]}" "${_force[@]}" "${_dev_flags[@]}" \
        || _phase_failed 3 "Environment configuration"             "Verify domain/email values and .env permissions."             "Re-run this phase: sudo ./utilities/setup-env.sh --domain ${DOMAIN} --email ${ADMIN_EMAIL}"

    operation_set_phase "4" "Secrets bootstrap"
    log_phase 4 6 "Secrets bootstrap"
    # Wait for sufficient kernel entropy before generating cryptographic keys (ux.md #34).
    wait_for_entropy "${ENTROPY_THRESHOLD:-200}" "${ENTROPY_MAX_WAIT:-60}" || true
    "${SCRIPT_DIR}/utilities/setup-secrets.sh" bootstrap \
        "${_dry[@]}" "${_force[@]}" \
        || _phase_failed 4 "Secrets bootstrap" \
            "Check the Age key and SOPS config: make key-health" \
            "Re-run this phase: sudo ./utilities/setup-secrets.sh bootstrap"

    operation_set_phase "5" "Firewall setup"
    log_phase 5 6 "Firewall setup"
    if ! "${SCRIPT_DIR}/utilities/setup-firewall.sh" --phase ufw \
      "${_auto[@]}" "${_dry[@]}" "${_force[@]}"; then
      _phase_failed 5 "Required UFW firewall configuration failed"
    fi

    if ! "${SCRIPT_DIR}/utilities/setup-firewall.sh" --phase iptables \
      "${_auto[@]}" "${_dry[@]}" "${_force[@]}"; then
      _phase_failed 5 "Required Docker/OCI firewall reconciliation failed" \
        "Check Docker's firewall backend and the FORWARD/DOCKER-USER chains." \
        "Re-run: sudo ./utilities/setup-firewall.sh --phase iptables --auto"
    fi

    local _crowdsec_setup_cmd="sudo ./utilities/setup-crowdsec.sh"
    [[ "$USE_LATEST" == "true" ]] && _crowdsec_setup_cmd+=" --use-latest"

    if [[ "$AUTO_MODE" != "true" ]] && [[ -t 0 ]]; then
        log_info ""
        log_info "════════════════════════════════════════════════"
        log_info " Next step: Configure CrowdSec Cloudflare bouncer"
        log_info "════════════════════════════════════════════════"
        log_info "Before running setup-crowdsec.sh, inject the CF secrets:"
        log_info ""
        log_info "  sudo ./edit-secrets.sh rotate cloudflare_zone_id"
        log_info "  sudo ./edit-secrets.sh rotate cf_account_id"
        log_info "  sudo ./edit-secrets.sh rotate cf_worker_bouncer_token"
        log_info ""
        log_info "Then run the CrowdSec setup:"
        log_info ""
        log_info "  ${_crowdsec_setup_cmd}"
        log_info ""
        press_enter_to_continue " Press [Enter] to continue with the post-install summary, or Ctrl-C to exit now..."
        _cs_prompt_ack=""
        unset _cs_prompt_ack
    else
        log_info "Next step: inject CF secrets first, then run sudo ./utilities/setup-crowdsec.sh"
        log_info "  sudo ./edit-secrets.sh rotate cloudflare_zone_id"
        log_info "  sudo ./edit-secrets.sh rotate cf_account_id"
        log_info "  sudo ./edit-secrets.sh rotate cf_worker_bouncer_token"
        log_info "  ${_crowdsec_setup_cmd}"
    fi

    export SETUP_SECRETS_PREEXISTED=false
    if secrets_file_exists && ensure_sops_env && check_placeholder_values >/dev/null 2>&1; then
      export SETUP_SECRETS_PREEXISTED=true
    fi

    if [[ "$AUTO_MODE" == "true" ]]; then
        operation_set_phase "6" "Secrets configuration"
        log_phase 6 6 "Secrets configuration"
        if [[ "$DRY_RUN" != "true" ]] &&
           { [[ "$FORCE" == "true" ]] || [[ "$SETUP_SECRETS_PREEXISTED" != "true" ]]; }; then
            if ! _setup_create_sensitive_workspace; then
                _phase_failed 6 "Unable to create the protected credential capture workspace"
            fi
        fi
        local secrets_args=(--auto --skip-optional --quiet-summary)
        [[ "$FORCE" == "true" ]] && secrets_args+=(--force)
        [[ "$DRY_RUN" == "true" ]] && secrets_args+=(--dry-run)
        if ! "${SCRIPT_DIR}/utilities/setup-secrets.sh" configure "${secrets_args[@]}"; then
          _phase_failed 6 "Required automatic secrets configuration failed"
        fi
    elif [[ -t 0 ]] && [[ "$DRY_RUN" != "true" ]]; then
        # Interactive setup does not auto-generate the administrator credentials,
        # so it does not need the protected automatic-capture workspace.
        log_info ""
        log_info "Secrets can be configured now. Automatic setup is required to create the protected generated-credential handoff."
        local _secrets_ans
        read -r -t 300 -p "Run interactive secrets setup now? [yes/no] (default: yes): " _secrets_ans || _secrets_ans="no"
        if [[ -z "$_secrets_ans" || "$_secrets_ans" =~ ^[Yy] ]]; then
            if ! "${SCRIPT_DIR}/utilities/setup-secrets.sh" configure --quiet-summary; then
                log_warn "Secrets configuration encountered issues — run 'sudo ./setup.sh secrets' to retry"
            fi
        else
            log_info "Skipping secrets setup — no setup credential handoff will be created unless automatic setup generates new credentials."
        fi
        unset _secrets_ans
    fi

    if [[ "$AUTO_MODE" == "true" ]]; then
        if ! show_post_install_summary "auto"; then
          _phase_failed 6 "Secure setup-credential handoff failed"
        fi
    else
        operation_set_phase "6" "Secrets configuration"
        log_phase 6 6 "Secrets configuration"
        if ! show_post_install_summary "interactive"; then
          _phase_failed 6 "Secure setup-credential handoff failed"
        fi
    fi
    return 0
}

main "$@"
