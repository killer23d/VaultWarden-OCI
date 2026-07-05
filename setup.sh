#!/usr/bin/env bash
# setup.sh — Install and configure VaultWarden-OCI.
# shellcheck disable=SC1091

set -euo pipefail

# Set SOPS_VERSION to pin a specific release, or leave it blank to resolve the
# latest release from the GitHub API at runtime.
#
# Examples:
#   SOPS_VERSION="v3.9.4"
#   SOPS_VERSION=""
#
SOPS_VERSION="${SOPS_VERSION:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

old_umask=$(umask)
umask 077
TMP_WORKDIR=$(mktemp -d -t vw_setup.XXXXXXXXXX) || {
    echo "ERROR: Failed to create secure temporary directory" >&2
    exit 1
}
umask "$old_umask"
trap 'rm -rf "$TMP_WORKDIR"' EXIT
trap 'rm -rf "${TMP_WORKDIR:-}"; exit 130' INT
trap 'rm -rf "${TMP_WORKDIR:-}"; exit 143' TERM

REQUIRED_LIBS=("lib/log.sh" "lib/validate.sh" "lib/config.sh" "lib/common.sh" "lib/operations.sh" "lib/crypto.sh" "lib/docker.sh" "lib/backup-utils.sh" "lib/secrets.sh" "lib/storage.sh")
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
source "${SCRIPT_DIR}/lib/storage.sh"
source "${SCRIPT_DIR}/lib/defaults.sh"

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
CLEAN_DOMAIN=""
# Storage mode variables. Defaults are overridden by --data-device/--data-mount
# or by DATA_VOLUME_DEVICE/DATA_VOLUME_MOUNT already set in the environment.
DATA_VOLUME_DEVICE="${DATA_VOLUME_DEVICE:-}"
DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}"

show_help() {
    cat << 'EOF' | sed "s|@DEFAULT_DATA_MOUNT@|${_VW_DEFAULT_DATA_MOUNT}|g"
VaultWarden-OCI Setup Tool — Security Hardened Edition

USAGE:
    sudo ./setup.sh install --domain DOMAIN --email EMAIL [OPTIONS]  # Full setup
    sudo ./setup.sh --domain DOMAIN --email EMAIL [OPTIONS]          # Full setup (legacy)
    sudo ./setup.sh secrets [OPTIONS]                                # Secrets phase only
    sudo ./setup.sh systemd <install|remove|validate|status> [OPTIONS]  # Systemd phase

SUBCOMMANDS:
    install    Run the full setup workflow. This is the recommended explicit
               entry point; legacy top-level --domain/--email flags still work.
    secrets    Configure encrypted secrets (admin password, API tokens, SMTP, etc.)
               Run this after editing .env with your Cloudflare zone / email settings.
    systemd    Install, validate, or remove VaultWarden systemd timers.
               Sub-actions: install | remove | validate | status

FULL SETUP OPTIONS (used after install or with top-level --domain / --email):
  --auto              Non-interactive install. Auto-generates passwords/passphrases;
                      external credentials (CF tokens, SMTP) remain as CHANGE_ME
                      placeholders — the post-install summary lists exact commands
                      to rotate them. Does NOT imply --use-latest.
  --use-latest        Use live upstream container and CrowdSec versions in .env.
  --skip-deps         Skip dependency installation (assumes already installed).
  --force             Overwrite existing .env, secrets, and docker-compose files.
                      WARNING: Also regenerates the Age encryption key. All
                      existing encrypted secrets become permanently unrecoverable
                      without a prior recovery kit export. Run
                      'sudo ./utilities/secrets-export-recovery-kit.sh' BEFORE using
                      --force on a running installation. To confirm you understand,
                      set VW_FORCE_ACK=I_UNDERSTAND_LOSING_OLD_BACKUPS in the
                      environment (or answer 'yes' at the interactive prompt).
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

# `install` and legacy top-level --domain/--email use the same setup parser.
_require_cli_value() {
    local opt="$1" value="${2-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        log_error "Option '$opt' requires a value."
        show_help
        exit 1
    fi
}

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
        --domain|--email|--auto|--use-latest|--skip-deps|--force|--dry-run|--data-device|--data-mount)
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
        --data-device)  _require_cli_value "$1" "${2-}"; DATA_VOLUME_DEVICE="$2";   shift 2 ;;
        --data-mount)   _require_cli_value "$1" "${2-}"; DATA_VOLUME_MOUNT="$2";    shift 2 ;;
        --help|-h)      show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done


# ---------------------------------------------------------------------------
# _warn_force_destructive
#
# Prominent warning for `--force`, which rotates the Age key and makes old
# encrypted backups unrecoverable without a prior recovery kit.
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
        "${COLOR_BOLD_RED}" "⚠  DESTRUCTIVE: --force WILL ROTATE YOUR AGE KEY" "${COLOR_RESET}"
    printf "%s║  %-${inner_width}s  ║%s\n" \
        "${COLOR_BOLD_RED}" "All existing encrypted backups become unrecoverable" "${COLOR_RESET}"
    printf "%s║  %-${inner_width}s  ║%s\n" \
        "${COLOR_BOLD_RED}" "unless you export a recovery kit FIRST." "${COLOR_RESET}"
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
# FORCE safety gate.
# This must run before any validation so --dry-run --force can still preview
# without triggering the prompt.
if [[ "$FORCE" == "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
    if [[ "${VW_FORCE_ACK:-}" != "I_UNDERSTAND_LOSING_OLD_BACKUPS" ]]; then
        _warn_force_destructive
        log_hint "Export your recovery kit first: sudo ./utilities/secrets-export-recovery-kit.sh"
        log_hint "Then re-run with VW_FORCE_ACK=I_UNDERSTAND_LOSING_OLD_BACKUPS if automation is required."
        exit 2
    fi
    if [[ -t 0 ]]; then
        _warn_force_destructive
            if ! read -r -t 300 -p "Type YES to confirm you have exported a recovery kit: " _force_answer; then
                printf '\n' >&2
                log_error "No confirmation received within 5 minutes. The destructive setup --force operation was not performed."
                exit 1
            fi
        if [[ "$_force_answer" != "YES" ]]; then
            log_info "Aborting setup --force at operator request."
            exit 1
        fi
        unset _force_answer
    fi
fi

if [[ -z "$PHASE" ]] && { [[ -z "$DOMAIN" ]] || [[ -z "$ADMIN_EMAIL" ]]; }; then show_help; exit 1; fi
if [[ -z "$PHASE" ]] && ! validate_domain "$DOMAIN"; then log_error "Invalid domain format"; exit 1; fi
if [[ -z "$PHASE" ]] && ! validate_email "$ADMIN_EMAIL"; then log_error "Invalid email format"; exit 1; fi


show_post_install_summary() {
    local mode="${1:-interactive}"

    [[ -t 1 ]] && clear
    local age_pub_key="" age_key_content=""
    if [[ -f "secrets/keys/age-key.txt" ]]; then
        age_pub_key=$(get_age_public_key "secrets/keys/age-key.txt" 2>/dev/null || echo "MISSING")
        age_key_content=$(cat "secrets/keys/age-key.txt" 2>/dev/null || echo "ERROR: Could not read key file")
    fi
    
    printf '%s' "${COLOR_RED}"
    cat << 'CRED_BANNER'
  ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !
  !                                                                       !
  !   🚨 CRITICAL: SAVE ALL OF THESE CREDENTIALS FOR DISASTER RECOVERY 🚨  !
  !     They will NOT be shown again unless you export a recovery kit     !
  !                                                                       !
  ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !
CRED_BANNER
    printf '%s' "${COLOR_RESET}"

    local _na="(not configured yet — run sudo ./setup.sh secrets, then sudo ./utilities/secrets-export-recovery-kit.sh)"
    local vw_admin_plain="${_na}" caddy_admin_plain="${_na}" backup_pass_plain="${_na}"
    [[ -f "${VW_ADMIN_PLAIN_FILE:-}" ]] && [[ -s "${VW_ADMIN_PLAIN_FILE:-}" ]] && \
        vw_admin_plain=$(cat "${VW_ADMIN_PLAIN_FILE}")
    [[ -f "${CADDY_PLAIN_FILE:-}" ]] && [[ -s "${CADDY_PLAIN_FILE:-}" ]] && \
        caddy_admin_plain=$(cat "${CADDY_PLAIN_FILE}")
    [[ -f "${BACKUP_PLAIN_FILE:-}" ]] && [[ -s "${BACKUP_PLAIN_FILE:-}" ]] && \
        backup_pass_plain=$(cat "${BACKUP_PLAIN_FILE}")

    printf '\n%s[1] SOPS AGE SECRET KEY%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
    printf '    Public key:  %s%s%s\n' "${COLOR_GREEN}" "${age_pub_key}" "${COLOR_RESET}"
    printf '%s%s%s\n' "${COLOR_GREEN}" "${age_key_content}" "${COLOR_RESET}"

    printf '\n%s[2] VAULTWARDEN ADMIN TOKEN (plaintext — hash stored in secrets)%s\n' \
        "${COLOR_CYAN}" "${COLOR_RESET}"
    printf '%s%s%s\n' "${COLOR_RED}${COLOR_GREEN}" "${vw_admin_plain}" "${COLOR_RESET}"

    printf '\n%s[3] CADDY ADMIN PASSWORD (plaintext — bcrypt hash stored in secrets)%s\n' \
        "${COLOR_CYAN}" "${COLOR_RESET}"
    printf '%s%s%s\n' "${COLOR_RED}${COLOR_GREEN}" "${caddy_admin_plain}" "${COLOR_RESET}"

    printf '\n%s[4] BACKUP PASSPHRASE%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
    printf '%s%s%s\n' "${COLOR_RED}${COLOR_GREEN}" "${backup_pass_plain}" "${COLOR_RESET}"

    printf '\n%s!!! PRESS ENTER ONLY AFTER SAVING ALL CREDENTIALS !!!%s\n' \
        "${COLOR_RED}" "${COLOR_RESET}"
    press_enter_to_continue " Press [Enter] ONLY after saving all credentials above..."
    clear

    local env_owner
    env_owner=$(stat -c '%U' "$PROJECT_ROOT/.env" 2>/dev/null || echo "root")
    local env_edit_cmd="nano .env"
    [[ "$env_owner" == "root" ]] && env_edit_cmd="sudo nano .env"

    local _cf_cmds
    _cf_cmds="$(printf '   %ssudo ./edit-secrets.sh rotate cloudflare_zone_id%s\n   %ssudo ./edit-secrets.sh rotate cf_account_id%s\n   %ssudo ./edit-secrets.sh rotate cf_worker_bouncer_token%s' \
        "${COLOR_YELLOW}" "${COLOR_RESET}" \
        "${COLOR_YELLOW}" "${COLOR_RESET}" \
        "${COLOR_YELLOW}" "${COLOR_RESET}")"

    if [[ "$mode" == "auto" ]]; then
        printf '\n%s--- AUTO-GENERATED CREDENTIALS (scroll up and save plaintext passwords now) ---%s\n' \
            "${COLOR_CYAN}" "${COLOR_RESET}"
        printf '  %s✔%s VaultWarden admin token    : GENERATED (Argon2id hash stored in secrets)\n' \
            "${COLOR_GREEN}" "${COLOR_RESET}"
        printf '  %s✔%s Caddy admin password       : GENERATED (bcrypt hash stored in secrets)\n' \
            "${COLOR_GREEN}" "${COLOR_RESET}"
        printf '  %s✔%s Backup passphrase          : GENERATED (stored in secrets)\n' \
            "${COLOR_GREEN}" "${COLOR_RESET}"

        printf '\n%s--- CREDENTIALS REQUIRING MANUAL CONFIGURATION ---%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf 'These fields still contain CHANGE_ME placeholders.\n'
        printf 'Set them BEFORE running %ssudo make up%s:\n\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %ssudo ./edit-secrets.sh rotate caddy_cloudflare_dns_token%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %ssudo ./edit-secrets.sh rotate smtp_password%s         (if using SMTP)\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %ssudo ./edit-secrets.sh rotate email_api_token%s       (if using API-based email)\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %ssudo ./edit-secrets.sh rotate push_installation_id%s  (optional — mobile push)\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %ssudo ./edit-secrets.sh rotate push_installation_key%s (optional — mobile push)\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"

        printf '\n%s--- NEXT STEPS ---%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
        printf '1. Edit .env:           %s%s%s\n' "${COLOR_YELLOW}" "$env_edit_cmd" "${COLOR_RESET}"
        printf '   ► Set: SMTP_HOST, SMTP_PORT, SMTP_USERNAME in .env\n'
        printf '   ► Verify: DOMAIN and ADMIN_EMAIL are correct\n'
        printf '2. Set external tokens: %s(use sudo ./edit-secrets.sh rotate <field> commands above)%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '3. Inject CrowdSec CF secrets (BEFORE running setup-crowdsec.sh):\n'
        printf '%s\n' "$_cf_cmds"
        printf '4. Setup CrowdSec:      %ssudo ./utilities/setup-crowdsec.sh%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '   ► CrowdSec reads cloudflare_zone_id, cf_account_id, cf_worker_bouncer_token\n'
        printf '     from secrets.yaml — those three must be set (step 3) before running this.\n'
        printf '5. Start services:      %ssudo make up%s\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '6. Setup automation:    %ssudo ./setup.sh systemd install%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '7. Export recovery kit: %ssudo ./edit-secrets.sh export-recovery-kit%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '   %s(Run AFTER steps 2-3 so all secrets are included in the kit)%s\n' \
            "${COLOR_RED}" "${COLOR_RESET}"
    else
        printf '\n%s--- EXTERNAL CONFIGURATION CHECKLIST ---%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
        printf '1. [ ] Domain Name:   %s%s%s\n' "${COLOR_GREEN}" "${CLEAN_DOMAIN:-Not Set}" "${COLOR_RESET}"
        printf '2. [ ] Admin Email:   %s%s%s\n' "${COLOR_GREEN}" "${ADMIN_EMAIL:-Not Set}" "${COLOR_RESET}"

        printf '\n%s--- NEXT STEPS ---%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
        printf '1. Edit .env:           %s%s%s\n' "${COLOR_YELLOW}" "$env_edit_cmd" "${COLOR_RESET}"
        printf '   ► Set: SMTP_HOST, SMTP_PORT, SMTP_USERNAME in .env\n'
        printf '   ► Verify: DOMAIN and ADMIN_EMAIL are correct\n'
        printf '2. Configure secrets:   %ssudo ./setup.sh secrets%s\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '3. Inject CrowdSec CF secrets (BEFORE running setup-crowdsec.sh):\n'
        printf '%s\n' "$_cf_cmds"
        printf '4. Setup CrowdSec:      %ssudo ./utilities/setup-crowdsec.sh%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '   ► CrowdSec reads cloudflare_zone_id, cf_account_id, cf_worker_bouncer_token\n'
        printf '     from secrets.yaml — those three must be set (step 3) before running this.\n'
        printf '5. Start services:      %ssudo make up%s\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '6. Setup automation:    %ssudo ./setup.sh systemd install%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '7. Export recovery kit: %ssudo ./edit-secrets.sh export-recovery-kit%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '   %s(Run AFTER steps 2-3 so all secrets are included in the kit)%s\n' \
            "${COLOR_RED}" "${COLOR_RESET}"
    fi

    if [[ "$mode" == "interactive" ]]; then
        press_enter_to_continue " Press [Enter] to clear this screen and finish..."
        clear
    fi
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
    _setup_cleanup() {
        local rc=$?
        operation_release "$rc"
        # Clean TMP_WORKDIR here because this trap overrides the earlier trap.
        rm -rf "$TMP_WORKDIR" 2>/dev/null || true
        return "$rc"
    }
    trap _setup_cleanup EXIT
    trap 'operation_release 130; rm -rf "${TMP_WORKDIR:-}" 2>/dev/null || true; exit 130' INT
    trap 'operation_release 143; rm -rf "${TMP_WORKDIR:-}" 2>/dev/null || true; exit 143' HUP TERM

    _verify_required_utilities

    if [[ -n "${SOPS_VERSION:-}" ]]; then
        log_info "SOPS version pinned: ${SOPS_VERSION}"
    else
        log_info "SOPS version: will resolve latest from GitHub at install time"
    fi


    local _dry=() _force=() _auto=() _skip_deps=() _use_latest=()
    [[ "$DRY_RUN"   == "true" ]] && _dry=(--dry-run)
    [[ "$FORCE"     == "true" ]] && _force=(--force)
    [[ "$AUTO_MODE" == "true" ]] && _auto=(--auto)
    [[ "$SKIP_DEPS" == "true" ]] && _skip_deps=(--skip-deps)
    [[ "$USE_LATEST" == "true" ]] && _use_latest=(--use-latest)

    local _dev_flags=()
    [[ -n "$DATA_VOLUME_DEVICE" ]] && _dev_flags+=(--data-device "$DATA_VOLUME_DEVICE")
    _dev_flags+=(--data-mount "$DATA_VOLUME_MOUNT")

    local _sops_flags=()
    [[ -n "${SOPS_VERSION:-}" ]] && _sops_flags=(--sops-version "$SOPS_VERSION")

    operation_set_phase "1" "System setup"
    log_phase 1 6 "System setup"
    "${SCRIPT_DIR}/utilities/setup-system.sh" \
        "${_auto[@]}" "${_skip_deps[@]}" "${_dry[@]}" "${_force[@]}" \
        "${_dev_flags[@]}" "${_sops_flags[@]}" \
        || _phase_failed 1 "System setup"             "Check missing packages: sudo apt-get update && sudo apt-get install -y docker.io age sops"             "Re-run this phase: sudo ./utilities/setup-system.sh"             "If dependencies are already installed, re-run setup with --skip-deps"

    operation_set_phase "2" "Storage setup"
    log_phase 2 6 "Storage setup"
    "${SCRIPT_DIR}/utilities/setup-storage.sh" --mode setup \
        "${_auto[@]}" "${_dry[@]}" "${_force[@]}" "${_dev_flags[@]}" \
        || _phase_failed 2 "Storage setup"             "Verify data devices and mounts: lsblk && findmnt"             "Re-run this phase: sudo ./utilities/setup-storage.sh --mode setup"

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
    "${SCRIPT_DIR}/utilities/setup-firewall.sh" --phase ufw \
        "${_auto[@]}" "${_dry[@]}" "${_force[@]}" \
        || log_warn "UFW firewall setup had a non-fatal issue — review output above"

    # Apply iptables rules on a best-effort basis.
    if [[ -x "${SCRIPT_DIR}/utilities/setup-firewall.sh" ]]; then
        echo "INFO: Applying VaultWarden iptables rules..."
        if "${SCRIPT_DIR}/utilities/setup-firewall.sh" --phase iptables; then
            echo "OK: VaultWarden iptables rules applied"
        else
            echo "WARN: utilities/setup-firewall.sh --phase iptables did not complete successfully" >&2
            echo "WARN: Run it manually after setup, or enable systemd/vaultwarden-iptables.service" >&2
        fi
    fi

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
        log_info "  sudo ./utilities/setup-crowdsec.sh"
        log_info ""
        press_enter_to_continue " Press [Enter] to continue with the post-install summary, or Ctrl-C to exit now..."
        _cs_prompt_ack=""
        unset _cs_prompt_ack
    else
        log_info "Next step: inject CF secrets first, then run sudo ./utilities/setup-crowdsec.sh"
        log_info "  sudo ./edit-secrets.sh rotate cloudflare_zone_id"
        log_info "  sudo ./edit-secrets.sh rotate cf_account_id"
        log_info "  sudo ./edit-secrets.sh rotate cf_worker_bouncer_token"
        log_info "  sudo ./utilities/setup-crowdsec.sh"
    fi

    # Export temp-file paths unconditionally so setup-secrets.sh (in both auto
    # and interactive mode) can write plaintext credentials for the final summary.
    # TMP_WORKDIR is mode 700 (created with umask 077), so files are root-only.
    export VW_ADMIN_PLAIN_FILE="${TMP_WORKDIR}/vw_admin_plain"
    export CADDY_PLAIN_FILE="${TMP_WORKDIR}/caddy_plain"
    export BACKUP_PLAIN_FILE="${TMP_WORKDIR}/backup_plain"

    if [[ "$AUTO_MODE" == "true" ]]; then
        operation_set_phase "6" "Secrets configuration"
        log_phase 6 6 "Secrets configuration"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would create plaintext credential capture files in ${TMP_WORKDIR}"
        fi
        local secrets_args=(--auto --skip-optional --quiet-summary)
        [[ "$FORCE" == "true" ]] && secrets_args+=(--force)
        if ! "${SCRIPT_DIR}/utilities/setup-secrets.sh" configure "${secrets_args[@]}"; then
            log_warn "Secrets auto-configuration encountered issues — run 'sudo ./setup.sh secrets' after editing .env"
        fi
    elif [[ -t 0 ]] && [[ "$DRY_RUN" != "true" ]]; then
        # Interactive TTY: offer to run secrets configuration now so all four
        # credentials are captured and shown in the final summary.
        log_info ""
        log_info "Secrets can be configured now so all four credentials are shown in the final summary."
        local _secrets_ans
        read -r -t 300 -p "Run interactive secrets setup now? [yes/no] (default: yes): " _secrets_ans || _secrets_ans="no"
        if [[ -z "$_secrets_ans" || "$_secrets_ans" =~ ^[Yy] ]]; then
            if ! "${SCRIPT_DIR}/utilities/setup-secrets.sh" configure --quiet-summary; then
                log_warn "Secrets configuration encountered issues — run 'sudo ./setup.sh secrets' to retry"
            fi
        else
            log_info "Skipping secrets setup — items [2]–[4] will show placeholder text in the summary."
        fi
        unset _secrets_ans
    fi

    if [[ "$AUTO_MODE" == "true" ]]; then
        show_post_install_summary "auto"
    else
        operation_set_phase "6" "Secrets configuration"
        log_phase 6 6 "Secrets configuration"
        show_post_install_summary "interactive"
    fi
    return 0
}

main "$@"
