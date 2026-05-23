#!/usr/bin/env bash
# setup.sh - VaultWarden-OCI Setup Script

set -euo pipefail

# =============================================================================
# DEPENDENCY VERSION PINS
# To pin a specific version, set the variable. Leave blank ("") to auto-resolve
# the latest release at runtime via the GitHub API.
#
# Examples:
#   SOPS_VERSION="v3.9.4"   <- pinned
#   SOPS_VERSION=""         <- auto-resolve latest (default)
#
# You may also override any of these from the environment before running:
#   SOPS_VERSION=v3.9.4 sudo ./setup.sh --domain ...
# =============================================================================
SOPS_VERSION="${SOPS_VERSION:-}"   # e.g. "v3.9.4" — leave blank for latest
# =============================================================================

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

REQUIRED_LIBS=("lib/common.sh" "lib/crypto.sh" "lib/docker.sh" "lib/backup-utils.sh" "lib/secrets.sh" "lib/storage.sh")
for lib in "${REQUIRED_LIBS[@]}"; do
    if [[ ! -f "$lib" ]]; then
        echo "ERROR: Required library not found: $lib" >&2
        exit 1
    fi
done

source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"
source "lib/docker.sh"
source "lib/backup-utils.sh"
source "lib/secrets.sh"
source "lib/storage.sh"

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
# Storage mode variables (defaults; overridden by --data-device/--data-mount
# CLI flags or by DATA_VOLUME_DEVICE/DATA_VOLUME_MOUNT already set in the
# calling environment).
DATA_VOLUME_DEVICE="${DATA_VOLUME_DEVICE:-}"
DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-/mnt/vw-data}"
SETUP_LOCK_FILE=""

show_help() {
    cat << 'EOF'
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
  --use-latest        Override pinned container versions with 'latest' tags in .env.
  --skip-deps         Skip dependency installation (assumes already installed).
  --force             Overwrite existing .env, secrets, and docker-compose files.
                      WARNING: Also regenerates the Age encryption key. All
                      existing encrypted secrets become permanently unrecoverable
                      without a prior recovery kit export. Run
                      './utilities/secrets-export-recovery-kit.sh' BEFORE using
                      --force on a running installation. To confirm you understand,
                      set VW_FORCE_ACK=I_UNDERSTAND_LOSING_OLD_BACKUPS in the
                      environment (or answer 'yes' at the interactive prompt).
  --dry-run           Print what would happen without making any changes.
  --data-device DEV   Use DEV as the dedicated VaultWarden data volume.
                      The device is formatted (ext4, first run only) and
                      mounted at DATA_VOLUME_MOUNT. A Docker systemd drop-in
                      ensures the stack never starts without this mount.
                      Example: --data-device /dev/sdb
  --data-mount PATH   Mount point for the data volume (default: /mnt/vw-data).
                      Must match PROJECT_STATE_DIR when DATA_VOLUME_DEVICE is set.

GLOBAL OPTIONS:
  --help, -h          Show this help and exit.

EXAMPLES:
    # ── First-time setup ──────────────────────────────────────────
    sudo ./setup.sh install --domain vault.example.com --email admin@example.com
    sudo ./setup.sh install --domain vault.example.com --email admin@example.com --auto

    # ── Secrets configuration ─────────────────────────────────────
    ./setup.sh secrets                   # Interactive credential setup
    ./setup.sh secrets --auto            # Automated with generated passwords
    ./setup.sh secrets --force           # Reconfigure without prompting
    ./setup.sh secrets --skip-optional   # Skip push notification keys
    ./setup.sh secrets --export-recovery-kit

    # ── Systemd timer management ──────────────────────────────────
    sudo ./setup.sh systemd install      # Install and enable all timers
    sudo ./setup.sh systemd validate     # Detect split-brain vs /opt/
    sudo ./setup.sh systemd status       # Show timer status
    sudo ./setup.sh systemd remove       # Disable and remove all timers
    sudo ./setup.sh systemd install --dry-run

EOF
}

# ---------------------------------------------------------------------------
# Argument Parsing — subcommand-first dispatch
# Pre-scan for positional subcommands before consuming regular --flags.
# The explicit `install` subcommand intentionally falls through to the same
# full-setup option parser used by the legacy top-level --domain/--email form.
# ---------------------------------------------------------------------------
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
            # Skip remaining flag parsing — PHASE_ARGS carries everything
            set --   # clear $@ so the while loop below is a no-op
            ;;
        systemd)
            PHASE="systemd"
            shift
            # Pass all remaining args positionally — setup-systemd.sh
            # accepts install|remove|validate|status as positional sub-actions.
            PHASE_ARGS=("$@")
            set --
            ;;
        help|--help|-h)
            show_help; exit 0
            ;;
        --domain|--email|--auto|--use-latest|--skip-deps|--force|--dry-run|--data-device|--data-mount)
            # Legacy full-setup flag — fall through to the while loop below
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
# FORCE safety gate — must run before any validation so --dry-run --force
# can still preview without triggering the prompt.
# ---------------------------------------------------------------------------
if [[ "$FORCE" == "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
    if [[ "${VW_FORCE_ACK:-}" != "I_UNDERSTAND_LOSING_OLD_BACKUPS" ]]; then
        log_error "--force regenerates the Age key and permanently orphans all existing"
        log_error "encrypted backups unless you have first exported a recovery kit."
        log_error ""
        log_error "  Export your recovery kit FIRST: ./utilities/secrets-export-recovery-kit.sh"
        log_error ""
        log_error "If you have already done that, re-run with:"
        log_error "  VW_FORCE_ACK=I_UNDERSTAND_LOSING_OLD_BACKUPS sudo ./setup.sh --force ..."
        exit 2
    fi
    if [[ -t 0 ]]; then
        read -r -p "WARNING: This will rotate the Age key and can orphan old backups. Continue? [yes/NO] " _force_answer
        if [[ "$_force_answer" != "yes" ]]; then
            log_info "Aborting setup --force at operator request."
            exit 1
        fi
        unset _force_answer
    fi
fi

if [[ -z "$PHASE" ]] && { [[ -z "$DOMAIN" ]] || [[ -z "$ADMIN_EMAIL" ]]; }; then show_help; exit 1; fi
if [[ -z "$PHASE" ]] && ! validate_domain "$DOMAIN"; then log_error "Invalid domain format"; exit 1; fi
if [[ -z "$PHASE" ]] && ! validate_email "$ADMIN_EMAIL"; then log_error "Invalid email format"; exit 1; fi

# ---------------------------------------------------------------------------
# show_post_install_summary
# ---------------------------------------------------------------------------
show_post_install_summary() {
    local mode="${1:-interactive}"

    # Read Age key upfront — used by both Change 4 consolidated screen and Change 2 banner
    local age_pub_key="" age_key_content=""
    if [[ -f "secrets/keys/age-key.txt" ]]; then
        age_pub_key=$(get_age_public_key "secrets/keys/age-key.txt" 2>/dev/null || echo "MISSING")
        age_key_content=$(cat "secrets/keys/age-key.txt" 2>/dev/null || echo "ERROR: Could not read key file")
    fi

    # ── Change 4: Consolidated credential screen (AUTO_MODE only, shown first) ──
    if [[ "$mode" == "auto" ]]; then
        local _na="(not available — run setup-secrets.sh configure --export-recovery-kit to retrieve)"
        local vw_admin_plain="${_na}" caddy_admin_plain="${_na}" backup_pass_plain="${_na}"
        [[ -f "${VW_ADMIN_PLAIN_FILE:-}" ]] && [[ -s "${VW_ADMIN_PLAIN_FILE:-}" ]] && \
            vw_admin_plain=$(cat "${VW_ADMIN_PLAIN_FILE}")
        [[ -f "${CADDY_PLAIN_FILE:-}" ]] && [[ -s "${CADDY_PLAIN_FILE:-}" ]] && \
            caddy_admin_plain=$(cat "${CADDY_PLAIN_FILE}")
        [[ -f "${BACKUP_PLAIN_FILE:-}" ]] && [[ -s "${BACKUP_PLAIN_FILE:-}" ]] && \
            backup_pass_plain=$(cat "${BACKUP_PLAIN_FILE}")

        clear
        printf '%s' "${COLOR_RED}"
        cat << 'CRED_BANNER'
  ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !
  !                                                                 !
  !   CRITICAL: SAVE ALL OF THESE CREDENTIALS FOR DISASTER RECOVERY !
  !   They will NOT be shown again unless you export a recovery kit  !
  !                                                                 !
  ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !
CRED_BANNER
        printf '%s' "${COLOR_RESET}"

        printf '\n%s[1] SOPS AGE SECRET KEY%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
        printf '%s%s%s\n' "${COLOR_RED}${COLOR_GREEN}" "${age_key_content}" "${COLOR_RESET}"

        printf '\n%s[2] VAULTWARDEN ADMIN TOKEN (plaintext — hash stored in secrets)%s\n' \
            "${COLOR_CYAN}" "${COLOR_RESET}"
        printf '%s%s%s\n' "${COLOR_RED}${COLOR_GREEN}" "${vw_admin_plain}" "${COLOR_RESET}"

        printf '\n%s[3] CADDY ADMIN PASSWORD (plaintext — bcrypt hash stored in secrets)%s\n' \
            "${COLOR_CYAN}" "${COLOR_RESET}"
        printf '%s%s%s\n' "${COLOR_RED}${COLOR_GREEN}" "${caddy_admin_plain}" "${COLOR_RESET}"

        printf '\n%s[4] BACKUP PASSPHRASE%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
        printf '%s%s%s\n' "${COLOR_RED}${COLOR_GREEN}" "${backup_pass_plain}" "${COLOR_RESET}"

        printf '\n%s!!! PRESS ENTER ONLY AFTER SAVING ALL FOUR CREDENTIALS !!!%s\n' \
            "${COLOR_RED}" "${COLOR_RESET}"
        read -r
        clear
    fi

    [[ "$mode" == "interactive" ]] && clear

    printf '%s' "${COLOR_RED}"
    cat << "EOF"
    ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !
    !                                                             !
    !   CRITICAL: SAVE THIS INFORMATION FOR DISASTER RECOVERY     !
    !                                                             !
    ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !
EOF
    printf '%s' "${COLOR_RESET}"

    # ── Change 2: Age key — red-banner credential screen ──────────────────────
    if [[ -f "secrets/keys/age-key.txt" ]]; then
        clear
        printf '%s' "${COLOR_RED}"
        cat << 'AGE_BANNER'
  ╔══════════════════════════════════════════════════════════════════╗
  ║   🔑  CRITICAL: SOPS AGE SECRET KEY — SAVE THIS NOW            ║
  ║   This key decrypts ALL backups. Loss = permanent data loss.    ║
  ╚══════════════════════════════════════════════════════════════════╝
AGE_BANNER
        printf '%s' "${COLOR_RESET}"
        printf 'SOPS Age Public Key:  %s%s%s\n' "${COLOR_GREEN}" "${age_pub_key}" "${COLOR_RESET}"
        printf '%sSECRET KEY (production): %s/etc/vaultwarden/age-key.txt%s\n' \
            "${COLOR_YELLOW}" "${COLOR_GREEN}" "${COLOR_RESET}"
        printf '%sSECRET KEY (repo-local): %ssecrets/keys/age-key.txt%s\n' \
            "${COLOR_YELLOW}" "${COLOR_GREEN}" "${COLOR_RESET}"
        printf '%s%s%s\n' "${COLOR_RED}${COLOR_GREEN}" "${age_key_content}" "${COLOR_RESET}"
        printf '\n%sTo view again at any time:%s\n' "${COLOR_RED}" "${COLOR_RESET}"
        printf '  %ssudo cat /etc/vaultwarden/age-key.txt%s  %s(production — root-owned, mode 600)%s\n' \
            "${COLOR_GREEN}" "${COLOR_RESET}" "${COLOR_RED}" "${COLOR_RESET}"
        printf '  %scat secrets/keys/age-key.txt%s  %s(repo-local copy — intentional for local dev only)%s\n' \
            "${COLOR_GREEN}" "${COLOR_RESET}" "${COLOR_RED}" "${COLOR_RESET}"
        printf '\n%s!!! PRESS ENTER AFTER SAVING THE AGE KEY !!!%s\n' \
            "${COLOR_RED}" "${COLOR_RESET}"
        if [[ -t 0 ]] && [[ "$mode" != "auto" ]]; then
            read -r
        fi
    fi

    # Determine correct edit command based on actual .env ownership
    local env_owner
    env_owner=$(stat -c '%U' "$PROJECT_ROOT/.env" 2>/dev/null || echo "root")
    local env_edit_cmd="nano .env"
    [[ "$env_owner" == "root" ]] && env_edit_cmd="sudo nano .env"

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
        printf 'Set them BEFORE running %smake up%s:\n\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %ssudo ./utilities/setup-secrets.sh rotate caddy_cloudflare_dns_token%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %ssudo ./utilities/setup-secrets.sh rotate smtp_password%s         (if using SMTP)\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %ssudo ./utilities/setup-secrets.sh rotate email_api_token%s       (if using API-based email)\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %ssudo ./utilities/setup-secrets.sh rotate push_installation_id%s  (optional — mobile push)\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %ssudo ./utilities/setup-secrets.sh rotate push_installation_key%s (optional — mobile push)\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"

        printf '\n%s--- NEXT STEPS ---%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
        printf '1. Edit .env:           %s%s%s\n' "${COLOR_YELLOW}" "$env_edit_cmd" "${COLOR_RESET}"
        printf '   ► Set: CLOUDFLARE_ZONE_ID, SMTP_HOST, SMTP_PORT, SMTP_USERNAME\n'
        printf '   ► Verify: DOMAIN and ADMIN_EMAIL are correct\n'
        printf '2. Set external tokens: %s(use sudo ./utilities/setup-secrets.sh rotate commands above)%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '3. Setup CrowdSec:      %ssudo ./utilities/setup-crowdsec.sh%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '   ► This script now prompts for CLOUDFLARE_ZONE_ID, optional CF_ACCOUNT_ID, and crowdsec_cf_firewall_token\n'
        printf '4. Start services:      %smake up%s\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '5. Setup automation:    %ssudo ./setup.sh systemd install%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '6. Export recovery kit: %s./utilities/secrets-export-recovery-kit.sh%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '   %s(Run AFTER step 2 so all secrets are included in the kit)%s\n' \
            "${COLOR_RED}" "${COLOR_RESET}"
    else
        printf '\n%s--- EXTERNAL CONFIGURATION CHECKLIST ---%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
        printf '1. [ ] Domain Name:   %s%s%s\n' "${COLOR_GREEN}" "${CLEAN_DOMAIN:-Not Set}" "${COLOR_RESET}"
        printf '2. [ ] Admin Email:   %s%s%s\n' "${COLOR_GREEN}" "${ADMIN_EMAIL:-Not Set}" "${COLOR_RESET}"

        printf '\n%s--- NEXT STEPS ---%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
        printf '1. Edit .env:           %s%s%s\n' "${COLOR_YELLOW}" "$env_edit_cmd" "${COLOR_RESET}"
        printf '   ► Set: CLOUDFLARE_ZONE_ID, SMTP_HOST, SMTP_PORT, SMTP_USERNAME\n'
        printf '   ► Verify: DOMAIN and ADMIN_EMAIL are correct\n'
        printf '2. Configure secrets:   %s./setup.sh secrets%s\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '   ► You will be prompted for all credentials\n'
        printf '3. Setup CrowdSec:      %ssudo ./utilities/setup-crowdsec.sh%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '   ► You will be prompted for CLOUDFLARE_ZONE_ID, optional CF_ACCOUNT_ID, and crowdsec_cf_firewall_token\n'
        printf '4. Start services:      %smake up%s\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '5. Setup automation:    %ssudo ./setup.sh systemd install%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '6. Export recovery kit: %s./utilities/secrets-export-recovery-kit.sh%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '   %s(Run AFTER step 2 so all secrets are included in the kit)%s\n' \
            "${COLOR_RED}" "${COLOR_RESET}"
    fi

    if [[ "$mode" == "interactive" ]]; then
        printf '\n%s!!! PRESS ENTER TO CLEAR THIS SCREEN AND FINISH !!!%s\n' "${COLOR_RED}" "${COLOR_RESET}"
        read -r
        clear
    fi
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Verify all required utility scripts are present and executable.
# ---------------------------------------------------------------------------
_check_all_utilities() {
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

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
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

    SETUP_LOCK_FILE="/run/lock/vaultwarden-setup.lock"
    # Use automatic FD allocation instead of hardcoded FD for the lock.
    # /run/lock is the FHS-correct transient lock location; /var/lock
    #   is a legacy symlink that ProtectSystem=strict makes read-only in systemd units.
    # A trap removes the lock file on EXIT so a crash does not leave a stale lock.
    local SETUP_LOCK_FD
    exec {SETUP_LOCK_FD}>"$SETUP_LOCK_FILE"
    if ! flock -n "$SETUP_LOCK_FD"; then
        log_error "Another setup instance is already running (could not acquire lock)."
        log_error "Wait for it to complete, then retry."
        log_error "If the lock is stale, remove: ${SETUP_LOCK_FILE}"
        exit 1
    fi
    _setup_cleanup() {
        rm -f "$SETUP_LOCK_FILE" 2>/dev/null || true
        # Clean TMP_WORKDIR here because this trap overrides the startup trap.
        rm -rf "$TMP_WORKDIR" 2>/dev/null || true
    }
    trap _setup_cleanup EXIT HUP INT TERM

    _check_all_utilities

    if [[ -n "${SOPS_VERSION:-}" ]]; then
        log_info "SOPS version pinned: ${SOPS_VERSION}"
    else
        log_info "SOPS version: will resolve latest from GitHub at install time"
    fi

    # ── Build common flag arrays ────────────────────────────────────────────
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

    # ── 1. System dependencies, swap, disk checks ───────────────────────────
    log_info "=== Phase 1: System setup ==="
    "${SCRIPT_DIR}/utilities/setup-system.sh" \
        "${_auto[@]}" "${_skip_deps[@]}" "${_dry[@]}" "${_force[@]}" \
        "${_dev_flags[@]}" "${_sops_flags[@]}" \
        || { log_error "System setup failed"; exit 1; }

    # ── 2. Storage: data volume + directories ───────────────────────────────
    log_info "=== Phase 2: Storage setup ==="
    "${SCRIPT_DIR}/utilities/setup-storage.sh" --mode setup \
        "${_dry[@]}" "${_force[@]}" "${_dev_flags[@]}" \
        || { log_error "Storage setup failed"; exit 1; }

    # ── 3. Environment file (.env, docker-compose) ──────────────────────────
    log_info "=== Phase 3: Environment configuration ==="
    "${SCRIPT_DIR}/utilities/setup-env.sh" \
        --domain "$DOMAIN" --email "$ADMIN_EMAIL" \
        "${_use_latest[@]}" "${_dry[@]}" "${_force[@]}" "${_dev_flags[@]}" \
        || { log_error "Environment setup failed"; exit 1; }

    # ── 4. Secrets bootstrap (Age key + SOPS config + placeholder secrets) ──
    log_info "=== Phase 4: Secrets bootstrap ==="
    "${SCRIPT_DIR}/utilities/setup-secrets.sh" bootstrap \
        "${_dry[@]}" "${_force[@]}" \
        || { log_error "Secrets bootstrap failed"; exit 1; }

    # ── 5. Firewall (UFW rules) ──────────────────────────────────────────────
    log_info "=== Phase 5: Firewall (UFW) ==="
    "${SCRIPT_DIR}/utilities/setup-firewall.sh" --phase ufw \
        "${_auto[@]}" "${_dry[@]}" "${_force[@]}" \
        || log_warn "UFW firewall setup had a non-fatal issue — review output above"

    # ── iptables rules (best-effort, non-fatal) ──────────────────────────────
    if [[ -x "${SCRIPT_DIR}/utilities/setup-firewall.sh" ]]; then
        echo "INFO: Applying VaultWarden iptables rules..."
        if "${SCRIPT_DIR}/utilities/setup-firewall.sh" --phase iptables; then
            echo "OK: VaultWarden iptables rules applied"
        else
            echo "WARN: utilities/setup-firewall.sh --phase iptables did not complete successfully" >&2
            echo "WARN: Run it manually after setup, or enable systemd/vaultwarden-iptables.service" >&2
        fi
    fi

    # ── CrowdSec prompt ─────────────────────────────────────────────────────
    if [[ "$AUTO_MODE" != "true" ]] && [[ -t 0 ]]; then
        log_info ""
        log_info "════════════════════════════════════════════════"
        log_info " Next step: Configure CrowdSec Cloudflare bouncer"
        log_info "════════════════════════════════════════════════"
        log_info "CrowdSec has been installed. To activate the"
        log_info "Cloudflare IP ban bouncer, run:"
        log_info ""
        log_info "  sudo ./utilities/setup-crowdsec.sh"
        log_info ""
        log_info "Then add your Cloudflare API token:"
        log_info ""
        log_info "  sudo ./utilities/setup-secrets.sh rotate crowdsec_cf_firewall_token"
        log_info ""
        printf 'Press ENTER to continue with the post-install summary, or Ctrl-C to exit now...'
        read -r _cs_prompt_ack || true
        unset _cs_prompt_ack
    else
        log_info "Next step: sudo ./utilities/setup-crowdsec.sh"
        log_info "Then add your Cloudflare API token: sudo ./utilities/setup-secrets.sh rotate crowdsec_cf_firewall_token"
    fi

    # ── 6. Auto secrets (AUTO_MODE only) ────────────────────────────────────
    if [[ "$AUTO_MODE" == "true" ]]; then
        log_info "=== Auto Mode: Configuring secrets ==="
        # Export temp-file paths so setup-secrets.sh can write plaintext credentials
        # for the consolidated summary screen (Change 4).  TMP_WORKDIR is mode 700
        # (created with umask 077) so files written inside are root-only.
        export VW_ADMIN_PLAIN_FILE="${TMP_WORKDIR}/vw_admin_plain"
        export CADDY_PLAIN_FILE="${TMP_WORKDIR}/caddy_plain"
        export BACKUP_PLAIN_FILE="${TMP_WORKDIR}/backup_plain"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would create plaintext credential capture files in ${TMP_WORKDIR}"
        fi
        local secrets_args=(--auto --skip-optional --quiet-summary)
        [[ "$FORCE" == "true" ]] && secrets_args+=(--force)
        if ! "${SCRIPT_DIR}/utilities/setup-secrets.sh" configure "${secrets_args[@]}"; then
            log_warn "Secrets auto-configuration encountered issues — run './setup.sh secrets' after editing .env"
        fi
    fi

    if [[ "$AUTO_MODE" != "true" ]]; then
        read -r -p "Press Enter to view CRITICAL recovery information..."
        show_post_install_summary "interactive"
    else
        show_post_install_summary "auto"
    fi
    return 0
}

main "$@"
