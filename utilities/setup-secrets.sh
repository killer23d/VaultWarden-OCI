#!/usr/bin/env bash
# utilities/setup-secrets.sh — VaultWarden-OCI secrets management
#
# USAGE:
#   sudo utilities/setup-secrets.sh SUBCOMMAND [OPTIONS]
#
# SUBCOMMANDS:
#   bootstrap           Bootstrap Age key, SOPS config, and placeholder secrets
#   configure           Full interactive/auto secrets setup
#   rotate [KEY]        Rotate one or all credentials
#   export-recovery-kit Export encrypted recovery kit
#   breakglass [FLAGS]  Emergency break-glass admin account management
#
# Run: setup-secrets.sh SUBCOMMAND --help  for subcommand-specific help.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

old_umask=$(umask)
umask 077
TMP_WORKDIR=$(mktemp -d -p "${PROJECT_ROOT}" vw_secrets_tmp.XXXXXXXXXX) || {
    echo "ERROR: Failed to create secure temporary directory" >&2
    exit 1
}
umask "$old_umask"
trap 'rm -rf "${TMP_WORKDIR:-}"' EXIT
trap 'rm -rf "${TMP_WORKDIR:-}"; exit 130' INT
trap 'rm -rf "${TMP_WORKDIR:-}"; exit 143' TERM

for _lib in "lib/log.sh" "lib/config.sh" "lib/common.sh" "lib/email.sh" "lib/crypto.sh" "lib/secrets.sh"; do
    if [[ ! -f "${PROJECT_ROOT}/${_lib}" ]]; then
        echo "ERROR: Required library not found: ${PROJECT_ROOT}/${_lib}" >&2
        exit 1
    fi
done
unset _lib

source "lib/log.sh"
source "lib/config.sh"
source "lib/common.sh"
init_common_lib "$0"
source "lib/email.sh"
source "lib/crypto.sh"
source "lib/secrets.sh"

# ---------------------------------------------------------------------------
# _show_help — top-level usage
# ---------------------------------------------------------------------------
_show_help() {
    cat << 'EOF'
VaultWarden-OCI Secrets Management

USAGE:
    sudo utilities/setup-secrets.sh SUBCOMMAND [OPTIONS]

SUBCOMMANDS:
    bootstrap           Bootstrap Age key, SOPS config, and placeholder secrets
                        (called automatically by setup.sh install phase)
    configure           Full interactive/auto secrets setup (replaces setup.sh secrets)
    rotate [KEY]        Rotate one or all credentials (delegates to utilities/secrets-edit.sh)
    export-recovery-kit Export encrypted recovery kit (delegates to utilities/secrets-edit.sh)
    breakglass [FLAGS]  Emergency break-glass admin account management

Run: setup-secrets.sh SUBCOMMAND --help  for subcommand-specific help.

EXAMPLES:
    sudo utilities/setup-secrets.sh bootstrap
    sudo utilities/setup-secrets.sh configure
    sudo utilities/setup-secrets.sh configure --auto
    sudo utilities/setup-secrets.sh rotate email_api_token
    sudo utilities/setup-secrets.sh export-recovery-kit
    sudo utilities/setup-secrets.sh breakglass create
    sudo utilities/setup-secrets.sh breakglass status
EOF
}

# ---------------------------------------------------------------------------
# _cmd_configure — full interactive/auto secrets setup
# (was run_phase_secrets in setup.sh)
# ---------------------------------------------------------------------------
_cmd_configure() {
    local CLEANUP_ACTIONS=()
    _ss_register_cleanup() { CLEANUP_ACTIONS+=("$1"); }

    local SKIP_VALIDATION=false
    local SKIP_OPTIONAL=false
    local AUTO_FIX=true
    local EXPORT_RECOVERY_KIT=false
    local QUIET_SUMMARY=false
    local AUTO_MODE=false
    local FORCE=false
    local DRY_RUN=false
    declare -A _COLLECTED_SECRETS=()

    _ss_run_cleanup_action() {
        local action="$1"
        case "$action" in
            rm\ -f\ *)
                local target="${action#rm -f }"
                if [[ -z "$target" || "$target" == *$'\n'* ]]; then
                    return 0
                fi
                local resolved
                resolved=$(realpath -m "$target" 2>/dev/null) || {
                    log_warn "_run_cleanup_action: realpath failed for target — refusing rm: $target"
                    return 1
                }
                local allowed_secrets="${PROJECT_ROOT:-/opt/vaultwarden-scripts}/secrets"
                if [[ "$resolved" != /tmp/* && "$resolved" != "$allowed_secrets"/* ]]; then
                    log_warn "_run_cleanup_action: refusing rm on path outside allowed dirs: $resolved"
                    return 1
                fi
                rm -f "$target" 2>/dev/null || true
                ;;
            *)
                log_warn "_ss_perform_cleanup: skipping unknown action: $action"
                ;;
        esac
    }

    _ss_perform_cleanup() {
        for key in "${!_COLLECTED_SECRETS[@]}"; do
            _COLLECTED_SECRETS["$key"]=""
        done
        unset _COLLECTED_SECRETS 2>/dev/null || true

        for (( idx=${#CLEANUP_ACTIONS[@]}-1; idx>=0; idx-- )); do
            _ss_run_cleanup_action "${CLEANUP_ACTIONS[$idx]}"
        done
        cleanup_secrets_environment
    }
    trap '_ss_perform_cleanup' RETURN

    _ss_show_help() {
        cat << 'HELP'
VaultWarden Interactive Secrets Setup (Idempotent - Security Hardened)

USAGE:
    sudo utilities/setup-secrets.sh configure [OPTIONS]

OPTIONS:
    --auto                  Auto-generate passwords; external credentials
                            (CF tokens, SMTP, push keys) are left as
                            CHANGE_ME placeholders for manual rotation.
    --skip-validation       Skip token/SMTP validation
    --skip-optional         Skip optional secrets (push notifications)
    --force                 Overwrite existing secrets without prompting
    --dry-run               Preview without executing
    --no-auto-fix           Don't auto-create missing prerequisites
    --export-recovery-kit   Offer recovery kit export after setup completes
    --quiet-summary         Suppress the completion banner, next-steps block,
                            and recovery-kit prompt. Used internally by
                            setup.sh so it can display a single consolidated
                            summary screen. Not intended for direct use.
    --help                  Show help

NOTES:
    --export-recovery-kit triggers the recovery-kit prompt that already
    appears after a successful setup run. To export a recovery kit
    independently (without running setup), use:
        sudo utilities/setup-secrets.sh export-recovery-kit

    The intended standalone order is:
        1. sudo ./setup.sh --domain DOMAIN --email EMAIL
        2. nano .env           (set CLOUDFLARE_ZONE_ID, EMAIL_MODE, EMAIL_PROVIDER,
                                SMTP_HOST, etc.)
        3. sudo utilities/setup-secrets.sh configure
        4. make up

FEATURES:
    ✅ Idempotent - Safe to re-run multiple times
    ✅ Auto-fixes missing prerequisites (Age keys, SOPS config)
    ✅ Validates existing secrets before reconfiguration
    ✅ Automatic Argon2id hashing (VaultWarden admin)
    ✅ Automatic bcrypt hashing (Caddy admin - htpasswd format)
    ✅ Cloudflare token validation
    ✅ Interactive prompts with confirmation
    ✅ Secure password generation (32-char minimum)
    ✅ Collects email API token OR smtp_password based on EMAIL_MODE

EXAMPLES:
    sudo utilities/setup-secrets.sh configure                        # Interactive setup
    sudo utilities/setup-secrets.sh configure --auto                 # Automated with generated passwords
    sudo utilities/setup-secrets.sh configure --force                # Reconfigure without prompting
    sudo utilities/setup-secrets.sh configure --skip-optional        # Skip push notifications
    sudo utilities/setup-secrets.sh configure --export-recovery-kit  # Prompt for kit after setup

SEE ALSO:
    sudo utilities/setup-secrets.sh rotate list     # Show existing secret key names
    sudo utilities/setup-secrets.sh rotate FIELD    # Rotate a single secret
    sudo utilities/setup-secrets.sh export-recovery-kit
HELP
    }

    # shellcheck disable=SC2034  # SKIP_VALIDATION is a documented option; validation-skip logic is a future placeholder
    while [[ $# -gt 0 ]]; do
        case $1 in
            --auto)                  AUTO_MODE=true;           shift ;;
            --skip-validation)       SKIP_VALIDATION=true;     shift ;;
            --skip-optional)         SKIP_OPTIONAL=true;       shift ;;
            --force)                 FORCE=true;               shift ;;
            --dry-run)               DRY_RUN=true;             shift ;;
            --no-auto-fix)           AUTO_FIX=false;           shift ;;
            --export-recovery-kit)   EXPORT_RECOVERY_KIT=true; shift ;;
            --quiet-summary)         QUIET_SUMMARY=true;       shift ;;
            --help)                  _ss_show_help; return 0 ;;
            *) log_error "Unknown option: $1"; _ss_show_help; return 1 ;;
        esac
    done

    local AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}"
    if [[ "$AGE_KEY_FILE" != /* ]]; then
        AGE_KEY_FILE="$PROJECT_ROOT/$AGE_KEY_FILE"
    fi

    ensure_prerequisites() {
        log_info "Checking prerequisites..."

        local missing=()
        local can_fix=()

        if [[ ! -f "$AGE_KEY_FILE" ]]; then
            missing+=("Age encryption key")
            can_fix+=("age_key")
        elif ! check_age_key "$AGE_KEY_FILE" 2>/dev/null; then
            log_warn "Age key exists but appears invalid"
            missing+=("Valid Age encryption key")
            can_fix+=("age_key")
        fi

        if [[ ! -f ".sops.yaml" ]]; then
            missing+=("SOPS configuration")
            can_fix+=("sops_config")
        fi

        if [[ ! -d "secrets" ]]; then
            missing+=("Secrets directory")
            can_fix+=("directories")
        fi

        if [[ ${#missing[@]} -gt 0 ]]; then
            log_warn "Missing prerequisites:"
            for item in "${missing[@]}"; do log_warn "  - $item"; done

            if [[ "$AUTO_FIX" == "true" ]]; then
                log_info "Auto-fixing missing prerequisites..."
                fix_prerequisites "${can_fix[@]}"
            else
                log_error "Prerequisites missing. Run './setup.sh' first or remove --no-auto-fix"
                return 1
            fi
        else
            log_success "All prerequisites present"
        fi

        return 0
    }

    fix_prerequisites() {
        local items=("$@")

        for item in "${items[@]}"; do
            case "$item" in
                age_key)
                    log_info "Creating Age encryption key..."
                    mkdir -p "$(dirname "$AGE_KEY_FILE")"
                    if generate_age_key "$AGE_KEY_FILE" true; then
                        log_success "Age key created: $AGE_KEY_FILE"
                    else
                        log_error "Failed to create Age key"
                        return 1
                    fi
                    ;;
                sops_config)
                    log_info "Creating SOPS configuration..."
                    local age_public_key
                    if ! age_public_key=$(get_age_public_key "$AGE_KEY_FILE"); then
                        log_error "Failed to extract Age public key"
                        return 1
                    fi
                    if [[ -z "$age_public_key" ]] || \
                       ! [[ "$age_public_key" =~ ^age1[a-z0-9]{58}$ ]]; then
                        log_error "Age public key has an invalid format: '${age_public_key}'"
                        log_error "Expected format: age1<58 lowercase bech32 characters>"
                        log_error "Re-generate the Age key and retry."
                        return 1
                    fi
                    cat > .sops.yaml << SOPS_EOF
creation_rules:
  - path_regex: .*\.yaml$
    age: $age_public_key
SOPS_EOF
                    chmod 640 .sops.yaml
                    chown "$(get_real_user):$(id -g -n "$(get_real_user)")" .sops.yaml 2>/dev/null || true
                    log_success "SOPS configuration created: .sops.yaml"
                    ;;
                directories)
                    log_info "Creating directory structure..."
                    mkdir -p secrets/keys secrets/.docker_secrets
                    chmod 700 secrets/keys secrets/.docker_secrets
                    log_success "Directories created"
                    ;;
            esac
        done

        return 0
    }

    secrets_are_configured() {
        if ! secrets_file_exists; then return 1; fi
        if ! ensure_sops_env;      then return 1; fi
        if ! check_placeholder_values 2>/dev/null; then
            return 1
        fi
        return 0
    }

    # _warn_tty: Writes timeout warnings to /dev/tty when available so that
    # automated pipelines capturing stdout are not silently confused by the
    # default-to-'no' decision.
    _warn_tty() {
        local msg="$1"
        if [[ "$QUIET_SUMMARY" == "true" ]]; then
            log_warn "$msg"
            return
        fi
        if [[ -w /dev/tty ]]; then
            echo "$msg" > /dev/tty
        else
            log_warn "$msg"
        fi
    }

    check_reconfiguration() {
        if ! secrets_are_configured; then
            log_info "No valid secrets found - configuration needed"
            return 0
        fi

        if [[ "$FORCE" == "true" ]]; then
            log_info "Force mode - reconfiguring secrets"
            [[ "$DRY_RUN" != "true" ]] && create_secrets_backup
            return 0
        fi

        log_info "Secrets already configured and valid"

        if [[ "$AUTO_MODE" == "true" ]]; then
            log_info "Auto mode - keeping existing secrets"
            return 1
        fi

        echo ""
        local confirm
        if ! read -r -t 30 -p "Reconfigure secrets? (yes/no): " confirm; then
            _warn_tty "WARNING: No input received (30s timeout). Treating as 'no'."
            confirm="no"
        fi

        if [[ "$confirm" == "yes" ]]; then
            create_secrets_backup
            return 0
        fi

        return 1
    }

    ensure_argon2_available() {
        if check_argon2_support >/dev/null 2>&1; then return 0; fi

        if python3 -c "import argon2" 2>/dev/null; then
            return 0
        fi

        log_warn "Argon2 not detected"

        if [[ "$AUTO_MODE" != "true" ]]; then
            local install_it
            if ! read -r -t 30 -p "Install Python argon2-cffi? (yes/no): " install_it; then
                _warn_tty "WARNING: No input received (30s timeout). Treating as 'no'."
                install_it="no"
            fi
            if [[ "$install_it" == "yes" ]]; then
                if pip3 install --quiet "argon2-cffi>=21.3,<24" 2>/dev/null || \
                   python3 -m pip install --quiet --user "argon2-cffi>=21.3,<24" 2>/dev/null; then
                    return 0
                fi
            fi
        fi

        log_error "Argon2 required but not available"
        return 1
    }

    # ---------------------------------------------------------------------------
    # yaml_escape VALUE
    # ---------------------------------------------------------------------------
    # NOTE: Consolidation with yaml_scalar() in utilities/secrets-rotate.sh was
    # intentionally rejected because they have genuinely different semantics.
    # yaml_escape() produces single-quoted scalars and only escapes embedded single
    # quotes. It is used here to write a fresh YAML file where values are known.
    # By contrast, yaml_scalar() handles complex control characters requiring
    # double-quoted escape sequences when replacing values in an existing file.
    yaml_escape() {
        local value="$1"
        local escaped="${value//\'/\'\'}"
        printf "'%s'" "$escaped"
    }

    # ---------------------------------------------------------------------------
    # _read_dotenv_value KEY [FILE]
    # Strips inline comments (one-or-more whitespace then #) and trailing
    # whitespace. Different from lib/common.sh _read_env_value which is simpler.
    # ---------------------------------------------------------------------------
    _read_dotenv_value() {
        local key="$1"
        local file="${2:-.env}"
        [[ -f "$file" ]] || { echo ""; return 0; }
        if [[ ! -r "$file" ]]; then
            log_warn "_read_dotenv_value: '${file}' is not readable by $(id -un) — returning empty for key '${key}'" >&2
            echo ""; return 0
        fi
        local val
        val=$(grep -E "^${key}=" "$file" | head -1 | sed "s/^${key}=//;s/[[:space:]]\+#.*$//;s/[[:space:]]*$//")
        echo "$val"
    }

    # ---------------------------------------------------------------------------
    # collect_secrets
    # ---------------------------------------------------------------------------
    collect_secrets() {
        _get_field() {
            local field="$1"
            if [[ "$AUTO_MODE" == "true" ]]; then
                auto_generate_secret_field "$field"
            else
                collect_secret_field "$field"
            fi
        }

        echo ""
        log_info "═══════════════════════════════════════════════════════════"
        log_info " VaultWarden Admin Password"
        log_info "═══════════════════════════════════════════════════════════"
        log_info "This password will be hashed with Argon2id for VaultWarden"
        echo ""

        local vw_hash
        if [[ "$QUIET_SUMMARY" == "true" ]] && [[ "$AUTO_MODE" == "true" ]]; then
            # Capture plaintext before hashing so setup.sh can display all four
            # credentials together in the consolidated summary screen (Change 4).
            # Using inline generation instead of auto_generate_secret_field to
            # avoid the individual /dev/tty banners that QUIET_SUMMARY suppresses.
            local vw_plain
            vw_plain=$(generate_secure_string 32) || { log_error "Failed to generate admin_token"; return 1; }
            vw_hash=$(generate_argon2_hash "$vw_plain") || { log_error "Failed to hash admin_token"; return 1; }
            if [[ -n "${VW_ADMIN_PLAIN_FILE:-}" ]]; then
                if [[ "$DRY_RUN" == "true" ]]; then
                    log_info "[DRY RUN] Would write VaultWarden admin plaintext to ${VW_ADMIN_PLAIN_FILE}"
                else
                    local _umask_vw
                    _umask_vw=$(umask)
                    umask 077
                    printf '%s' "$vw_plain" > "${VW_ADMIN_PLAIN_FILE}"
                    umask "$_umask_vw"
                fi
            fi
        else
            vw_hash=$(_get_field "admin_token") || { log_error "Failed to collect admin_token"; return 1; }
        fi
        _COLLECTED_SECRETS["admin_token"]="$vw_hash"

        echo ""
        log_info "═══════════════════════════════════════════════════════════"
        log_info " Caddy Admin Panel Password"
        log_info "═══════════════════════════════════════════════════════════"
        log_info "This password will be hashed with bcrypt for Caddy basic auth"
        # shellcheck disable=SC2016  # single quotes intentional: showing literal bcrypt format
        log_info 'Format: htpasswd (admin:$2y$14$...)'
        echo ""

        local caddy_hash
        if [[ "$QUIET_SUMMARY" == "true" ]] && [[ "$AUTO_MODE" == "true" ]]; then
            # Capture plaintext before hashing for consolidated summary (Change 4).
            local caddy_plain
            caddy_plain=$(generate_secure_string 32) || { log_error "Failed to generate admin_basic_auth_hash"; return 1; }
            local _raw_caddy_hash
            _raw_caddy_hash=$(generate_bcrypt_hash "$caddy_plain") || { log_error "Failed to hash admin_basic_auth_hash"; return 1; }
            if ! _bcrypt_format_ok "$_raw_caddy_hash"; then
                log_error "Generated bcrypt hash has invalid format: $_raw_caddy_hash"
                return 1
            fi
            caddy_hash="admin ${_raw_caddy_hash}"
            if [[ -n "${CADDY_PLAIN_FILE:-}" ]]; then
                if [[ "$DRY_RUN" == "true" ]]; then
                    log_info "[DRY RUN] Would write Caddy admin plaintext to ${CADDY_PLAIN_FILE}"
                else
                    local _umask_caddy
                    _umask_caddy=$(umask)
                    umask 077
                    printf '%s' "$caddy_plain" > "${CADDY_PLAIN_FILE}"
                    umask "$_umask_caddy"
                fi
            fi
        else
            caddy_hash=$(_get_field "admin_basic_auth_hash") || { log_error "Failed to collect admin_basic_auth_hash"; return 1; }
        fi
        _COLLECTED_SECRETS["admin_basic_auth_hash"]="$caddy_hash"

        echo ""
        log_info "═══════════════════════════════════════════════════════════"
        log_info " Cloudflare DNS API Token"
        log_info "═══════════════════════════════════════════════════════════"
        log_info "Required Permissions: Zone:DNS:Edit + Zone:Zone:Read"
        log_info "Create at: https://dash.cloudflare.com/profile/api-tokens"
        echo ""

        local cf_dns
        cf_dns=$(_get_field "caddy_cloudflare_dns_token") || { log_error "Failed to collect caddy_cloudflare_dns_token"; return 1; }
        _COLLECTED_SECRETS["caddy_cloudflare_dns_token"]="$cf_dns"

        if [ -f "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/secrets/.docker_secrets/crowdsec_cf_firewall_token" ]; then
            log_info "Cloudflare firewall token file found on disk — will be used by CrowdSec bouncer."
        else
            log_warn "Cloudflare firewall token file not found yet — run sudo ./utilities/setup-crowdsec.sh (it prompts for the token)."
        fi

        local _email_mode _email_provider
        _email_mode=$(    _read_dotenv_value "EMAIL_MODE"     .env)
        _email_provider=$(   _read_dotenv_value "EMAIL_PROVIDER" .env)
        if [[ -z "$_email_mode" && -f ".env" && ! -r ".env" ]]; then
            log_warn "setup-secrets.sh configure: .env is not readable by $(id -un); EMAIL_MODE/EMAIL_PROVIDER defaulting to 'auto'/'mailersend'."
            log_warn "Fix ownership: sudo chown $(id -un):$(id -gn) .env"
        fi
        _email_mode="${_email_mode:-auto}"
        _email_provider="${_email_provider:-mailersend}"

        echo ""
        log_info "═══════════════════════════════════════════════════════════"
        log_info " Email Notifications"
        log_info "═══════════════════════════════════════════════════════════"
        log_info "Current .env settings:"
        log_info "  EMAIL_MODE     = $_email_mode"
        log_info "  EMAIL_PROVIDER = $_email_provider"
        echo ""
        log_info "Delivery tiers (controlled by EMAIL_MODE in .env):"
        log_info "  auto  — try API → SMTP → Postfix sidecar in order (recommended)"
        log_info "  api   — HTTP API only   (requires email_api_token in secrets)"
        log_info "  smtp  — SMTP relay only (requires smtp_password in secrets)"
        log_info "  host  — Postfix sidecar only (no token or SMTP password needed)"
        echo ""
        log_info "One token key (email_api_token) works for ALL providers."
        log_info "To switch providers: change EMAIL_PROVIDER in .env only."
        log_info "To rotate the token: sudo utilities/setup-secrets.sh rotate email_api_token"
        echo ""

        if [[ "$_email_mode" == "api" || "$_email_mode" == "auto" ]]; then
            log_info " Tier 1 — Email API Token (all providers)"
            log_info "  Secrets key  : email_api_token"
            log_info "  Active provider: $_email_provider (set EMAIL_PROVIDER in .env to change)"
            log_info "  Get token at : provider dashboard (MailerSend / SendGrid / Mailgun etc.)"
            echo ""

            local email_api_token
            if [[ "$AUTO_MODE" == "true" ]]; then
                email_api_token="CHANGE_ME_EMAIL_API_TOKEN"
                log_warn "[AUTO] email_api_token → placeholder; rotate with:"
                log_warn "  sudo utilities/setup-secrets.sh rotate email_api_token"
            else
                local skip_api
                if ! read -r -t 30 -p "Enter email_api_token now? (yes/no): " skip_api; then
                    _warn_tty "WARNING: No input received (30s timeout). Treating as 'no'."
                    skip_api="no"
                fi
                if [[ "$skip_api" == "yes" ]]; then
                    local _raw_token
                    if ! read -r -s -t 120 -p "email_api_token: " _raw_token; then
                        _warn_tty "WARNING: No input received (120s timeout). Using placeholder."
                        _raw_token=""
                    fi
                    echo ""
                    if [[ -n "$_raw_token" ]]; then
                        email_api_token="$_raw_token"
                        log_success "email_api_token stored"
                    else
                        email_api_token="CHANGE_ME_EMAIL_API_TOKEN"
                        log_info "No value entered — using placeholder"
                    fi
                else
                    email_api_token="CHANGE_ME_EMAIL_API_TOKEN"
                    log_info "API token skipped — rotate later with:"
                    log_info "  sudo utilities/setup-secrets.sh rotate email_api_token"
                fi
            fi
            _COLLECTED_SECRETS["email_api_token"]="$email_api_token"
        else
            _COLLECTED_SECRETS["email_api_token"]="NOT_USED_EMAIL_MODE=${_email_mode}"
        fi

        if [[ "$_email_mode" == "smtp" || "$_email_mode" == "auto" ]]; then
            echo ""
            log_info " Tier 2 — SMTP Relay Password"
            log_info "  Secrets key: smtp_password"
            log_info "  .env keys  : SMTP_HOST / SMTP_PORT / SMTP_USERNAME  (non-secret)"
            echo ""

            local smtp_pass
            if [[ "$AUTO_MODE" == "true" ]]; then
                smtp_pass=$(auto_generate_secret_field "smtp_password") || { log_error "Failed to generate smtp_password"; return 1; }
            else
                local enable_smtp
                if ! read -r -t 30 -p "Enter smtp_password now? (yes/no): " enable_smtp; then
                    _warn_tty "WARNING: No input received (30s timeout). Treating as 'no'."
                    enable_smtp="no"
                fi
                if [[ "$enable_smtp" == "yes" ]]; then
                    smtp_pass=$(collect_secret_field "smtp_password") || { log_error "Failed to collect smtp_password"; return 1; }
                    log_success "smtp_password configured"
                else
                    smtp_pass="CHANGE_ME_SMTP_PASSWORD"
                    log_info "SMTP password skipped — rotate later with:"
                    log_info "  sudo utilities/setup-secrets.sh rotate smtp_password"
                fi
            fi
            _COLLECTED_SECRETS["smtp_password"]="$smtp_pass"
        elif [[ "$_email_mode" == "host" ]]; then
            _COLLECTED_SECRETS["smtp_password"]="NOT_USED_EMAIL_MODE=host"
            log_info "EMAIL_MODE=host: smtp_password not needed (Postfix sidecar handles delivery)"
        else
            _COLLECTED_SECRETS["smtp_password"]="NOT_USED_EMAIL_MODE=${_email_mode}"
        fi

        echo ""
        log_info "Generating backup encryption passphrase..."
        local backup_pass
        backup_pass=$(auto_generate_secret_field "backup_passphrase") || { log_error "Failed to generate backup_passphrase"; return 1; }
        _COLLECTED_SECRETS["backup_passphrase"]="$backup_pass"

        # Write plaintext to temp file for consolidated summary screen (Change 4).
        if [[ -n "${BACKUP_PLAIN_FILE:-}" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY RUN] Would write backup passphrase plaintext to ${BACKUP_PLAIN_FILE}"
            else
                local _umask_bp
                _umask_bp=$(umask)
                umask 077
                printf '%s' "$backup_pass" > "${BACKUP_PLAIN_FILE}"
                umask "$_umask_bp"
            fi
        fi

        # Change 3: Show backup passphrase with red-banner credential screen when
        # not suppressed (i.e., standalone interactive run without --quiet-summary).
        if [[ "$QUIET_SUMMARY" != "true" ]] && [[ -t 0 ]]; then
            clear
            printf '%s' "${COLOR_RED}"
            cat << 'BACKUP_BANNER'
  ╔══════════════════════════════════════════════════════════════════╗
  ║   🔑  BACKUP ENCRYPTION PASSPHRASE — SAVE THIS NOW             ║
  ║   Required to decrypt all backups. Cannot be recovered.        ║
  ╚══════════════════════════════════════════════════════════════════╝
BACKUP_BANNER
            printf '%s' "${COLOR_RESET}"
            printf '\n  Passphrase: %s%s%s\n\n' \
                "${COLOR_RED}${COLOR_GREEN}" "${backup_pass}" "${COLOR_RESET}"
            printf '%s!!! PRESS ENTER AFTER SAVING THE BACKUP PASSPHRASE !!!%s\n' \
                "${COLOR_RED}" "${COLOR_RESET}"
            read -r
        fi

        if [[ "$SKIP_OPTIONAL" != "true" ]]; then
            echo ""
            log_info "═══════════════════════════════════════════════════════════"
            log_info " Push Notifications (Optional)"
            log_info "═══════════════════════════════════════════════════════════"
            log_info "Get credentials from: https://bitwarden.com/host"
            echo ""

            if [[ "$AUTO_MODE" == "true" ]]; then
                _COLLECTED_SECRETS["push_installation_id"]=$(auto_generate_secret_field "push_installation_id")
                _COLLECTED_SECRETS["push_installation_key"]=$(auto_generate_secret_field "push_installation_key")
            else
                local do_push
                if ! read -r -t 30 -p "Configure push notifications? (yes/no): " do_push; then
                    _warn_tty "WARNING: No input received (30s timeout). Treating as 'no'."
                    do_push="no"
                fi
                if [[ "$do_push" == "yes" ]]; then
                    _COLLECTED_SECRETS["push_installation_id"]=$(collect_secret_field "push_installation_id") || return 1
                    _COLLECTED_SECRETS["push_installation_key"]=$(collect_secret_field "push_installation_key") || return 1
                    log_success "Push notifications configured"
                else
                    _COLLECTED_SECRETS["push_installation_id"]="CHANGE_ME_OR_LEAVE_EMPTY"
                    _COLLECTED_SECRETS["push_installation_key"]="CHANGE_ME_OR_LEAVE_EMPTY"
                    log_info "Push notifications skipped - configure later with: sudo utilities/setup-secrets.sh rotate push_installation_id"
                fi
            fi
        else
            _COLLECTED_SECRETS["push_installation_id"]="CHANGE_ME_OR_LEAVE_EMPTY"
            _COLLECTED_SECRETS["push_installation_key"]="CHANGE_ME_OR_LEAVE_EMPTY"
        fi

        echo ""
        log_success "All secrets collected successfully"
        return 0
    }

    # ---------------------------------------------------------------------------
    # export_docker_secrets is provided by lib/secrets.sh (sourced above).
    # Call it with the docker secrets directory as the first argument.
    # ---------------------------------------------------------------------------

    # ---------------------------------------------------------------------------
    # write_secrets — YAML assembly, SOPS encryption, atomic mv
    # ---------------------------------------------------------------------------
    write_secrets() {
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would write secrets to encrypted file"
            return 0
        fi

        log_info "Writing secrets to encrypted YAML file..."

        if ! mkdir -p "$PROJECT_ROOT/secrets"; then
            log_error "Failed to create secrets directory: $PROJECT_ROOT/secrets"
            log_error "Check permissions on $PROJECT_ROOT and retry."
            return 1
        fi

        local _saved_umask
        _saved_umask=$(umask)
        umask 077
        local temp_file
        temp_file=$(mktemp -p "$PROJECT_ROOT/secrets" vwsecrets.XXXXXXXXXX.yaml) || {
            umask "$_saved_umask"
            log_error "mktemp failed in $PROJECT_ROOT/secrets"
            return 1
        }
        umask "$_saved_umask"

        # shellcheck disable=SC2064  # intentional — $temp_file must expand NOW
        _ss_register_cleanup "rm -f ${temp_file}"

        {
            printf '# VaultWarden Secrets Configuration\n'
            printf '# Generated: %s\n' "$(date -Iseconds)"
            printf '# Encrypted with: SOPS + Age\n\n'
            printf '# VaultWarden admin password (Argon2id hash)\n'
            printf 'admin_token: %s\n\n'                       "$(yaml_escape "${_COLLECTED_SECRETS[admin_token]}")"
            # shellcheck disable=SC2016  # single quotes intentional: showing literal bcrypt format example
            printf '# Caddy admin password (htpasswd format: admin:$2y$14$...)\n'
            printf 'admin_basic_auth_hash: %s\n\n'             "$(yaml_escape "${_COLLECTED_SECRETS[admin_basic_auth_hash]}")"
            printf '# Email — Tier 1: HTTP API token (all providers)\n'
            printf '# Single key regardless of EMAIL_PROVIDER. Change EMAIL_PROVIDER in .env\n'
            printf '# to switch providers; no re-keying of this secret is required.\n'
            printf '# To rotate: sudo utilities/setup-secrets.sh rotate email_api_token\n'
            printf 'email_api_token: %s\n\n'                   "$(yaml_escape "${_COLLECTED_SECRETS[email_api_token]:-}")"
            printf '# Email — Tier 2: SMTP relay password\n'
            printf '# Used when EMAIL_MODE=smtp or EMAIL_MODE=auto (fallback from API).\n'
            printf '# To rotate: sudo utilities/setup-secrets.sh rotate smtp_password\n'
            printf 'smtp_password: %s\n\n'                     "$(yaml_escape "${_COLLECTED_SECRETS[smtp_password]}")"
            printf '# Backup encryption passphrase\n'
            printf 'backup_passphrase: %s\n\n'                 "$(yaml_escape "${_COLLECTED_SECRETS[backup_passphrase]}")"
            printf '# Push notifications (optional)\n'
            printf 'push_installation_id: %s\n'                "$(yaml_escape "${_COLLECTED_SECRETS[push_installation_id]}")"
            printf 'push_installation_key: %s\n\n'             "$(yaml_escape "${_COLLECTED_SECRETS[push_installation_key]}")"
            printf '# Cloudflare DNS API token (Zone:DNS:Edit + Zone:Zone:Read)\n'
            printf 'caddy_cloudflare_dns_token: %s\n'          "$(yaml_escape "${_COLLECTED_SECRETS[caddy_cloudflare_dns_token]}")"
        } > "$temp_file"

        for key in "${!_COLLECTED_SECRETS[@]}"; do
            _COLLECTED_SECRETS["$key"]=""
        done
        unset _COLLECTED_SECRETS
        declare -A _COLLECTED_SECRETS

        if ! ensure_sops_env; then
            log_error "Failed to setup SOPS environment"
            return 1
        fi

        log_info "Encrypting secrets with SOPS + Age..."
        if ! sops --encrypt --in-place "$temp_file" 2>&1; then
            log_error "Failed to encrypt secrets file"
            return 1
        fi

        if ! mv "$temp_file" "$SECRETS_FILE"; then
            log_error "Failed to move encrypted secrets to final location"
            return 1
        fi

        if ! secure_secrets_file; then
            log_error "Failed to secure secrets file permissions"
            return 1
        fi

        log_success "Secrets encrypted and written to: $SECRETS_FILE"

        local docker_secrets_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/secrets/.docker_secrets"
        if [[ ! -d "$docker_secrets_dir" ]]; then
            mkdir -p "$docker_secrets_dir"
            chmod 700 "$docker_secrets_dir"
            log_info "Created Docker secrets directory: $docker_secrets_dir"
        fi

        # crowdsec_cf_firewall_token intentionally remains a flat file only (not in SOPS YAML)
        # because it is rotated independently and consumed directly by CrowdSec tooling.
        if ! export_docker_secrets "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/secrets/.docker_secrets"; then
            log_error "Failed to export Docker secret files — run sudo utilities/setup-secrets.sh configure again"
            return 1
        fi

        return 0
    }

    _ss_main() {
        log_header "VaultWarden Secrets Setup (Security Hardened)"

        echo ""
        log_info "This script will configure all secrets for VaultWarden deployment"
        log_info "Secrets will be encrypted with SOPS + Age encryption"
        echo ""

        if ! require_commands sops age python3 jq htpasswd; then
            log_error "Missing required commands"
            log_info "Install htpasswd with: sudo apt-get install apache2-utils"
            return 1
        fi

        if ! htpasswd -nbB _test_ _test123_ &>/dev/null; then
            log_error "htpasswd on this system does not support bcrypt (-B flag)"
            log_error "This is required for Caddy admin basic-auth hashing."
            log_info  "Fix: sudo apt-get install --reinstall apache2-utils"
            return 1
        fi

        if ! ensure_prerequisites;    then return 1; fi
        if ! ensure_argon2_available; then return 1; fi

        if ! check_reconfiguration; then
            log_info "Keeping existing secrets - no changes made"
            log_info "Tip: to rotate a single field run: sudo utilities/setup-secrets.sh rotate FIELD"
            log_info "Tip: to export a recovery kit run:  sudo utilities/setup-secrets.sh export-recovery-kit"
            return 0
        fi

        echo ""
        log_info "═══════════════════════════════════════════════════════════"
        log_info " Secrets Collection"
        log_info "═══════════════════════════════════════════════════════════"
        if ! collect_secrets; then
            log_error "Failed to collect secrets"
            return 1
        fi

        echo ""
        log_info "═══════════════════════════════════════════════════════════"
        log_info " Writing Encrypted Secrets"
        log_info "═══════════════════════════════════════════════════════════"
        if ! write_secrets; then
            log_error "Failed to write secrets"
            return 1
        fi

        for _cleanup_key in \
            admin_token admin_basic_auth_hash \
            caddy_cloudflare_dns_token \
            email_api_token smtp_password backup_passphrase \
            push_installation_id push_installation_key; do
            unset "SECRET_${_cleanup_key}" 2>/dev/null || true
        done
        unset _cleanup_key

        if [[ "$QUIET_SUMMARY" != "true" ]]; then
            echo ""
            log_header "Secrets Setup Complete!"
            echo ""
            log_success "✅ Secrets encrypted and stored in: $SECRETS_FILE"
            log_success "✅ Caddy admin hash in htpasswd format: admin:\$2y\$14\$..."
            log_success "✅ VaultWarden admin hash in Argon2id format"
            log_success "✅ All secrets protected with Age encryption"
            log_success "✅ Docker secret files written to: secrets/.docker_secrets/"
            echo ""
            echo "📋 Next Steps:"
            echo "   1. Verify .env settings:      nano .env"
            echo "      ► Confirm: CLOUDFLARE_ZONE_ID, EMAIL_MODE, EMAIL_PROVIDER,"
            echo "                 SMTP_HOST, SMTP_PORT, SMTP_USERNAME"
            echo "   2. Start services:            make up"
            echo "   3. Setup automation:          sudo ./setup.sh systemd install"
            echo "   4. Export recovery kit:       sudo utilities/setup-secrets.sh export-recovery-kit"
            echo "   5. Test health:               ./maintenance.sh health"
            echo "   6. To rotate a single field:  sudo utilities/setup-secrets.sh rotate FIELD"
            echo "   7. To list secret keys:       sudo utilities/setup-secrets.sh rotate list"
            echo ""
            echo "📧 Email mode reference (set EMAIL_MODE in .env):"
            echo "   auto  — API → SMTP → Postfix fallback chain (recommended)"
            echo "   api   — HTTP API only  (set EMAIL_PROVIDER + rotate email_api_token)"
            echo "   smtp  — SMTP relay only (rotate smtp_password)"
            echo "   host  — Postfix sidecar only (no token or password needed in secrets)"
            echo ""
            log_warn "⚠️  If you used --auto mode, scroll up to save the generated passwords!"
            echo ""

            if [[ "$DRY_RUN" == "false" ]]; then
                offer_recovery_kit_export "$EXPORT_RECOVERY_KIT"
            fi
        fi

        return 0
    }
    _ss_main "$@"
}

# ---------------------------------------------------------------------------
# _cmd_rotate — thin wrapper to utilities/secrets-rotate.sh
# ---------------------------------------------------------------------------
_cmd_rotate() {
    local key="${1:-}"
    local edit_sh="${PROJECT_ROOT}/utilities/secrets-edit.sh"
    _require_script "$edit_sh"
    if [[ -n "$key" ]]; then
        exec "$edit_sh" rotate "$key"
    else
        exec "$edit_sh" rotate
    fi
}

# ---------------------------------------------------------------------------
# _cmd_export_recovery_kit — thin wrapper to utilities/secrets-export-recovery-kit.sh
# ---------------------------------------------------------------------------
_cmd_export_recovery_kit() {
    local edit_sh="${PROJECT_ROOT}/utilities/secrets-edit.sh"
    _require_script "$edit_sh"
    exec "$edit_sh" export-recovery-kit
}

# ---------------------------------------------------------------------------
# _cmd_breakglass — emergency break-glass admin account management
# (merged from the former standalone break-glass utility)
# ---------------------------------------------------------------------------
_cmd_breakglass() {
    # Local state variables
    local BREAKGLASS_USER="vw-emergency"
    local CREATE_USER=false
    local REMOVE_USER=false
    local RESET_PASSWORD=false
    local SHOW_STATUS=false
    local VALIDATE_ONLY=false
    local DRY_RUN=false
    local FORCE=false

    local BREAKGLASS_MAX_AGE_HOURS="${BREAKGLASS_MAX_AGE_HOURS:-72}"
    local BREAKGLASS_AUTO_EXPIRY_HOURS="${BREAKGLASS_AUTO_EXPIRY_HOURS:-2}"

    # Read SSH_PORT from environment, then fall back to .env.
    local SSH_PORT="${SSH_PORT:-}"
    if [[ -z "$SSH_PORT" ]] && [[ -f "${PROJECT_ROOT}/.env" ]]; then
        SSH_PORT=$(grep -m1 -E '^[[:space:]]*SSH_PORT[[:space:]]*=' "${PROJECT_ROOT}/.env" \
            | sed 's/^[^=]*=[[:space:]]*//' | tr -d '"'"'" | tr -d '[:space:]') || true
    fi
    SSH_PORT="${SSH_PORT:-22}"

    _bg_show_help() {
        cat << 'EOF'
VaultWarden-OCI Break-Glass Admin Manager — Emergency Access

USAGE:
    sudo utilities/setup-secrets.sh breakglass <subcommand> [options]

SUBCOMMANDS:
    create          Create break-glass admin account (targeted sudo)
    remove          Remove break-glass admin account
    reset-password  Reset break-glass admin password
    status          Show break-glass admin status
    validate        Validate script security only (no operations)

GLOBAL OPTIONS:
    --user USERNAME  Specify username (default: vw-emergency)
    --force          Force operations without confirmation
    --dry-run        Show what would be done without executing
    --help, -h       Show this help

ENVIRONMENT:
    BREAKGLASS_MAX_AGE_HOURS     Hours before status warns account is too old (default: 72)
    BREAKGLASS_AUTO_EXPIRY_HOURS Hours after creation before the account is auto-removed
                                 (default: 2). Scheduler priority:
                                   1. `at` + atd running
                                   2. `at` present (tries on-demand activation)
                                   3. systemd-run transient timer (survives reboots)
                                   4. background sleep subshell (lost on reboot)
                                 Set to 0 to disable auto-expiry entirely.

EXAMPLES:
    sudo utilities/setup-secrets.sh breakglass create         # Create emergency admin
    sudo utilities/setup-secrets.sh breakglass status         # Check status
    sudo utilities/setup-secrets.sh breakglass validate       # Validate script security
    sudo utilities/setup-secrets.sh breakglass reset-password # Reset password
    sudo utilities/setup-secrets.sh breakglass remove         # Remove account
    sudo utilities/setup-secrets.sh breakglass remove --force # Remove without confirmation

BREAK-GLASS ADMIN PURPOSE:
    Emergency access when SSH is broken or firewall blocks access.
    This account has targeted sudo access (docker, systemctl, journalctl, reboot).
    Access via OCI Console Connection (serial console).

SECURITY NOTES:
    • Uses strong random password (32+ characters)
    • Account is granted targeted sudo via /etc/sudoers.d/vw-emergency
    • Allowed commands: docker, systemctl, journalctl, reboot
    • Password displayed only once during creation
    • Account is automatically removed after BREAKGLASS_AUTO_EXPIRY_HOURS (default: 2h)
    • Account can be disabled/removed manually with 'remove'
    • Script validates its own security before operations

EOF
    }

    # ---------------------------------------------------------------------------
    # validate_script_security()
    # ---------------------------------------------------------------------------
    validate_script_security() {
        local strict="${1:-false}"
        local script_path="$0"

        log_info "Validating script security..."

        if ! script_path=$(readlink -f "$script_path"); then
            log_error "Failed to resolve script path"
            return 1
        fi

        local perms
        if perms=$(stat -c '%a' "$script_path" 2>/dev/null); then
            local perm_int
            perm_int=$(( 8#$perms ))
            if (( perm_int & 8#002 )); then
                log_error "SECURITY: Script is world-writable — hard-failing to prevent code injection"
                log_error "Script: $script_path  (current mode: $perms)"
                log_error "Fix with: sudo chmod o-w '$script_path'"
                return 1
            fi
            if (( perm_int & 8#020 )); then
                log_error "SECURITY: Script is group-writable — hard-failing to prevent code injection"
                log_error "Script: $script_path  (current mode: $perms)"
                log_error "Fix with: sudo chmod g-w '$script_path'"
                return 1
            fi
        else
            log_error "Failed to stat script for permission check: $script_path"
            return 1
        fi

        if ! validate_file_permissions "$script_path" "700" "root" "root"; then
            if [[ "$strict" == "true" ]]; then
                log_error "SECURITY: Script failed validation - privilege escalation risk"
                log_error "Expected: root:root ownership with 700 permissions"
                log_error "Current script: $script_path"

                if ls -la "$script_path"; then
                    log_info "^ Current permissions shown above"
                fi

                log_error "Fix with: sudo chown root:root '$script_path' && sudo chmod 700 '$script_path'"
                return 1
            else
                log_warn "Script not owned by root:root — consider: sudo chown root:root $(realpath "$script_path") && sudo chmod 700 $(realpath "$script_path")"
            fi
        fi

        local expected_dir="/opt/vaultwarden-scripts"
        if [[ "$script_path" == "$expected_dir"/* ]]; then
            log_success "Script location validated (secure cron location)"
        elif [[ "$script_path" == */VaultWarden-OCI/* ]]; then
            log_info "Script location: Development/project directory"
        else
            log_warn "Script in unexpected location: $script_path"
        fi

        local security_lib="$PROJECT_ROOT/lib/crypto.sh"
        if [[ ! -f "$security_lib" ]]; then
            log_error "SECURITY: Required security library not found: $security_lib"
            return 1
        fi

        if ! validate_file_permissions "$security_lib" "644" "root" "root"; then
            log_warn "Security library permissions could be improved"
            log_info "Consider: sudo chown root:root '$security_lib' && sudo chmod 644 '$security_lib'"
        fi

        log_success "Script security validation passed"
        return 0
    }

    check_user_exists() {
        id "$BREAKGLASS_USER" >/dev/null 2>&1
    }

    # ---------------------------------------------------------------------------
    # create_sudoers_config()
    # ---------------------------------------------------------------------------
    create_sudoers_config() {
        local sudoers_file="/etc/sudoers.d/vw-emergency"

        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would write targeted sudoers: $sudoers_file"
            return 0
        fi

        local tmp_sudoers
        tmp_sudoers=$(mktemp -t vw_sudoers.XXXXXXXXXX)
        trap 'rm -f "$tmp_sudoers" 2>/dev/null; trap - RETURN' RETURN

        cat >"$tmp_sudoers" <<EOF
# VaultWarden emergency break-glass account — least-privilege sudo
# Generated by setup-secrets.sh breakglass on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Remove this file when the break-glass account is decommissioned.
${BREAKGLASS_USER} ALL=(root) NOPASSWD: /usr/bin/docker, /bin/systemctl, /usr/bin/journalctl, /sbin/reboot
EOF

        if ! visudo -c -f "$tmp_sudoers" >/dev/null 2>&1; then
            log_error "Generated sudoers content failed visudo validation — not installed"
            return 1
        fi

        if ! install -m 0440 -o root -g root "$tmp_sudoers" "$sudoers_file"; then
            log_error "Failed to install sudoers file: $sudoers_file"
            return 1
        fi

        log_success "Targeted sudoers installed: $sudoers_file"
        return 0
    }

    # ---------------------------------------------------------------------------
    # _notify_breakglass_event()
    # ---------------------------------------------------------------------------
    _notify_breakglass_event() {
        local event="$1"
        local detail="${2:-}"
        local severity="${3:-INFO}"

        local subject="Breakglass Admin ${event}: ${BREAKGLASS_USER}"
        [[ "$severity" == "CRITICAL" ]] && subject="CRITICAL ${subject}"

        local body
        body=$(printf 'Breakglass admin event\n\nEvent:   %s\nUser:    %s\nHost:    %s\nTime:    %s\n' \
            "$event" "$BREAKGLASS_USER" "$(hostname -f 2>/dev/null || hostname)" "$(date -uIs)")
        [[ -n "$detail" ]] && body+=$(printf '\nDetail:  %s' "$detail")

        if ! send_notification_email "$subject" "$body" 2>/dev/null; then
            log_warn "Breakglass event notification delivery failed (non-fatal)"
        fi
        logger -t vaultwarden-breakglass \
            "EVENT=${event} USER=${BREAKGLASS_USER} HOST=$(hostname -f 2>/dev/null || hostname) TIME=$(date -uIs)" \
            2>/dev/null || true
    }

    # ---------------------------------------------------------------------------
    # schedule_auto_cleanup()
    # ---------------------------------------------------------------------------
    schedule_auto_cleanup() {
        local expiry_hours="$BREAKGLASS_AUTO_EXPIRY_HOURS"
        local bg_user="$BREAKGLASS_USER"

        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would schedule auto-cleanup in ${expiry_hours}h"
            return 0
        fi

        if (( expiry_hours == 0 )); then
            log_warn "Auto-expiry disabled (BREAKGLASS_AUTO_EXPIRY_HOURS=0) — remember to run 'breakglass remove' manually"
            return 0
        fi

        local script_abs
        script_abs=$(readlink -f "$0")
        local cleanup_cmd="${script_abs} breakglass remove --user ${bg_user} --force"
        local expiry_epoch=$(( $(date +%s) + expiry_hours * 3600 ))
        local expiry_human
        expiry_human=$(date -d "@${expiry_epoch}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
            || date -r "${expiry_epoch}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
            || date -u -d "${expiry_hours} hours" '+%Y-%m-%d %H:%M UTC' 2>/dev/null \
            || echo "in ${expiry_hours} hour(s)")

        if command -v at >/dev/null 2>&1 && systemctl is-active --quiet atd 2>/dev/null; then
            if echo "${cleanup_cmd}" | at now + "${expiry_hours}" hours 2>/dev/null; then
                log_success "Auto-cleanup scheduled via 'at' at ${expiry_human}"
                return 0
            else
                log_warn "'at' scheduling failed — trying next tier"
            fi
        elif command -v at >/dev/null 2>&1; then
            if echo "${cleanup_cmd}" | at now + "${expiry_hours}" hours 2>/dev/null; then
                log_success "Auto-cleanup scheduled via 'at' at ${expiry_human}"
                return 0
            else
                log_warn "'at' available but scheduling failed — trying next tier"
            fi
        fi

        if command -v systemd-run >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
            if systemd-run \
                    --on-active="${expiry_hours}h" \
                    --unit="vw-breakglass-cleanup" \
                    --description="VaultWarden breakglass auto-cleanup for ${bg_user}" \
                    -- bash -c "${cleanup_cmd}" 2>/dev/null; then
                log_success "Auto-cleanup scheduled via systemd transient timer at ${expiry_human} (reboot-safe)"
                return 0
            else
                log_warn "systemd-run scheduling failed — falling back to background sleep"
            fi
        fi

        local sleep_seconds=$(( expiry_hours * 3600 ))
        log_error "WARNING: All reliable schedulers (at, systemd-run) are unavailable."
        log_error "  Auto-expiry cannot be guaranteed across a reboot on this system."
        log_error "  The breakglass account would persist indefinitely if the host reboots."
        log_warn  "  To proceed anyway (NOT reboot-safe), re-run with --force."
        log_warn  "  Mandatory: run 'sudo $0 breakglass remove' manually when done."
        if [[ "${FORCE}" != "true" ]]; then
            log_error "Aborting: pass --force to use the unreliable background-subshell fallback."
            return 1
        fi
        setsid bash -c "sleep ${sleep_seconds} && ${cleanup_cmd}" \
            </dev/null >/dev/null 2>&1 &
        disown
        log_warn "Fallback auto-cleanup background job started (NOT reboot-safe) — target: ${expiry_human}"
        return 0
    }

    # ---------------------------------------------------------------------------
    # create_breakglass_user()
    # ---------------------------------------------------------------------------
    create_breakglass_user() {
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would create break-glass admin user: $BREAKGLASS_USER"
            return 0
        fi

        log_info "Creating break-glass admin user: $BREAKGLASS_USER"

        if check_user_exists; then
            if [[ "$FORCE" != "true" ]]; then
                log_error "User already exists: $BREAKGLASS_USER"
                log_info "Use --force to recreate or 'reset-password' to change password"
                return 1
            else
                log_warn "User exists, recreating with --force"
                if ! remove_breakglass_user; then
                    log_error "Failed to remove existing user for recreation"
                    return 1
                fi
            fi
        fi

        local password
        if ! password=$(generate_secure_random 32); then
            log_error "Failed to generate secure password"
            return 1
        fi

        if ! useradd -m -s /bin/bash -c "VaultWarden Emergency Admin" "$BREAKGLASS_USER"; then
            log_error "Failed to create user: $BREAKGLASS_USER"
            return 1
        fi

        if ! chpasswd <<< "${BREAKGLASS_USER}:${password}"; then
            log_error "Failed to set user password"
            userdel -r "$BREAKGLASS_USER" 2>/dev/null || true
            return 1
        fi

        if ! create_sudoers_config; then
            log_error "Failed to install sudoers configuration"
            userdel -r "$BREAKGLASS_USER" 2>/dev/null || true
            return 1
        fi

        log_success "Break-glass admin created with targeted sudo access"

        local instructions_file="/home/$BREAKGLASS_USER/EMERGENCY_ACCESS_INSTRUCTIONS.txt"
        local instructions_content
        instructions_content=$(cat << EOF
VaultWarden Emergency Access Instructions
========================================
This account has targeted emergency access for VaultWarden recovery.

ACCESS VIA OCI CONSOLE:
1. Log into Oracle Cloud Infrastructure (OCI)
2. Navigate to: Compute → Instances → Your Instance
3. Click "Console Connection"
4. Login with these credentials:
   Username: $BREAKGLASS_USER
   Password: [write in your emergency physical vault or password manager — shown once at creation]

ALLOWED OPERATIONS:
- sudo /usr/bin/docker
- sudo /bin/systemctl
- sudo /usr/bin/journalctl
- sudo /sbin/reboot

COMMON EMERGENCY COMMANDS:
# Fix SSH lockout
sudo /bin/systemctl restart sshd

# Check system status
sudo /usr/bin/docker compose ps
sudo /usr/bin/journalctl -u docker --since "1 hour ago"

# Restart services
sudo /usr/bin/docker compose restart

SECURITY NOTES:
- This account does NOT have unrestricted root access
- Use only for genuine emergencies
- Account auto-expires after ${BREAKGLASS_AUTO_EXPIRY_HOURS} hour(s)
- Remove manually if needed: sudo utilities/setup-secrets.sh breakglass remove
- Password is 32+ characters for maximum security

Created: $(date)
Project: $PROJECT_ROOT
EOF
)

        if ! create_secure_file "$instructions_file" "$instructions_content" "600" "$BREAKGLASS_USER" "$BREAKGLASS_USER"; then
            log_warn "Failed to create instructions file securely"
        fi

        log_success "Break-glass admin created successfully"

        _notify_breakglass_event "CREATED" "User $BREAKGLASS_USER created with targeted sudoers (/etc/sudoers.d/vw-emergency)" "INFO"

        local expiry_epoch=$(( $(date +%s) + BREAKGLASS_AUTO_EXPIRY_HOURS * 3600 ))
        local expiry_human
        expiry_human=$(date -d "@${expiry_epoch}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
            || date -r "${expiry_epoch}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
            || echo "in ${BREAKGLASS_AUTO_EXPIRY_HOURS} hour(s)")

        clear
        printf '%b\n' "${COLOR_RED}"
        cat << "EOF"
  _    _  ___  ____  _   _  _  _  ____  _ 
 ( \/\/ )/ __)(_  _)( )_( )( \/ )(__  )(_)
  )    (( (__  _)(_  ) _ (  )  (  _)(_  _ 
 (__/\__)\___)(____)(( (_) (_)(_/\_)(____)((_)
EOF
        printf '%b\n' "${COLOR_RESET}"

        printf '%b\n' "${COLOR_YELLOW}EMERGENCY ACCESS CREDENTIALS CREATED${COLOR_RESET}"
        printf 'These credentials allow access via the OCI Serial Console if SSH fails.\n'
        printf 'Write these down physically and store them securely.\n\n'

        printf '%b\n' "Username:  ${COLOR_GREEN}${BREAKGLASS_USER}${COLOR_RESET}"
        printf '%b\n' "Password:  ${COLOR_GREEN}${password}${COLOR_RESET}"
        if (( BREAKGLASS_AUTO_EXPIRY_HOURS > 0 )); then
            printf '%b\n' "Expiry:    ${COLOR_YELLOW}${expiry_human} (auto-cleanup in ${BREAKGLASS_AUTO_EXPIRY_HOURS}h)${COLOR_RESET}"
        else
            printf '%b\n' "Expiry:    ${COLOR_CYAN}None — auto-expiry disabled. Remove manually with: sudo $0 breakglass remove${COLOR_RESET}"
        fi

        printf '\nTo test this:\n'
        printf '1. Go to Oracle Cloud Console > Compute > Instance > Console Connection\n'
        printf '2. Launch Cloud Shell connection\n'
        printf '3. Press ENTER to see login prompt\n'
        printf '4. Login with the credentials above\n'

        printf '%b\n' "\n${COLOR_RED}SECURITY NOTE: 'clear' does not erase terminal scrollback history.${COLOR_RESET}"
        printf 'If this session is recorded (tmux, script, SSH audit log, cloud serial\n'
        printf 'console), the credentials above may be visible in the scrollback buffer.\n'
        printf 'Close the terminal or disconnect the session after noting them.\n'
        printf '%b\n' "\n${COLOR_RED}Press ENTER to clear visible screen and finish...${COLOR_RESET}"
        read -r
        clear

        schedule_auto_cleanup

        return 0
    }

    # ---------------------------------------------------------------------------
    # remove_breakglass_user()
    # ---------------------------------------------------------------------------
    remove_breakglass_user() {
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would remove break-glass user: $BREAKGLASS_USER"
            return 0
        fi

        log_info "Removing break-glass admin user: $BREAKGLASS_USER"

        if ! check_user_exists; then
            log_info "User does not exist: $BREAKGLASS_USER"
            return 0
        fi

        if [[ "$FORCE" != "true" ]]; then
            echo ""
            log_warn "This will permanently remove the break-glass admin account."
            log_warn "You will lose emergency console access capability."
            echo ""
            read -r -p "Continue with removal? (yes/no): " confirm
            if [[ "$confirm" != "yes" ]]; then
                log_info "Removal cancelled by user"
                return 0
            fi
        fi

        local sudoers_file="/etc/sudoers.d/vw-emergency"
        if [[ -f "$sudoers_file" ]]; then
            if rm -f "$sudoers_file"; then
                log_info "Removed targeted sudoers: $sudoers_file"
            else
                log_warn "Failed to remove sudoers file: $sudoers_file — manual removal required"
            fi
        fi

        if systemctl is-active --quiet vw-breakglass-cleanup.timer 2>/dev/null; then
            systemctl stop vw-breakglass-cleanup.timer 2>/dev/null || true
            log_info "Stopped pending systemd transient cleanup timer (vw-breakglass-cleanup)"
        fi

        if groups "$BREAKGLASS_USER" 2>/dev/null | grep -qw "sudo"; then
            if command -v gpasswd >/dev/null 2>&1; then
                if gpasswd -d "$BREAKGLASS_USER" sudo 2>/dev/null; then
                    log_info "Removed $BREAKGLASS_USER from sudo group via gpasswd (legacy cleanup)"
                else
                    log_warn "gpasswd -d reported an error removing $BREAKGLASS_USER from sudo group"
                fi
            elif command -v deluser >/dev/null 2>&1; then
                if deluser "$BREAKGLASS_USER" sudo 2>/dev/null; then
                    log_info "Removed $BREAKGLASS_USER from sudo group via deluser (legacy cleanup)"
                else
                    log_warn "deluser reported an error removing $BREAKGLASS_USER from sudo group"
                fi
            else
                log_warn "Could not remove $BREAKGLASS_USER from sudo group automatically."
                log_warn "Manual remediation: edit /etc/group and remove '$BREAKGLASS_USER' from the sudo line."
            fi
        fi

        if userdel -r "$BREAKGLASS_USER" 2>/dev/null; then
            log_success "User removed: $BREAKGLASS_USER"
        else
            log_warn "User removal may have had issues (user might not have had home directory)"
        fi

        log_success "Break-glass admin removal completed"
        _notify_breakglass_event "REMOVED" "User $BREAKGLASS_USER and sudoers file /etc/sudoers.d/vw-emergency removed" "INFO"
        return 0
    }

    # ---------------------------------------------------------------------------
    # reset_breakglass_password()
    # ---------------------------------------------------------------------------
    reset_breakglass_password() {
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would reset password for: $BREAKGLASS_USER"
            return 0
        fi

        log_info "Resetting break-glass admin password: $BREAKGLASS_USER"

        if ! check_user_exists; then
            log_error "User does not exist: $BREAKGLASS_USER"
            log_info "Use 'create' to create the break-glass admin first"
            return 1
        fi

        local password
        if ! password=$(generate_secure_random 32); then
            log_error "Failed to generate secure password"
            return 1
        fi

        if ! chpasswd <<< "${BREAKGLASS_USER}:${password}"; then
            log_error "Failed to reset user password"
            return 1
        fi

        log_success "Break-glass admin password reset successfully"
        echo ""
        echo "🔑 NEW EMERGENCY ACCESS CREDENTIALS"
        echo "=================================="
        echo "Username: $BREAKGLASS_USER"
        echo "Password: $password"
        echo ""
        echo "⚠️  SECURITY WARNING:"
        echo "• These credentials are displayed ONLY ONCE"
        echo "• Store them securely (password manager, encrypted note)"
        echo "• Old credentials are now invalid"

        _notify_breakglass_event "PASSWORD_RESET" "Password for $BREAKGLASS_USER was reset" "INFO"
        return 0
    }

    # ---------------------------------------------------------------------------
    # _check_breakglass_account_age()
    # ---------------------------------------------------------------------------
    _check_breakglass_account_age() {
        local home_dir="$1"
        local instructions_file="$home_dir/EMERGENCY_ACCESS_INSTRUCTIONS.txt"
        local creation_epoch=""

        if [[ -f "$instructions_file" ]]; then
            creation_epoch=$(stat -c '%Y' "$instructions_file" 2>/dev/null) || true
        fi

        if [[ -z "$creation_epoch" ]] && [[ -d "$home_dir" ]]; then
            creation_epoch=$(stat -c '%Y' "$home_dir" 2>/dev/null) || true
        fi

        if [[ -z "$creation_epoch" ]]; then
            log_warn "Cannot determine account creation time — skipping age check"
            return 0
        fi

        local now_epoch
        now_epoch=$(date +%s)
        local age_seconds=$(( now_epoch - creation_epoch ))
        local age_hours=$(( age_seconds / 3600 ))
        local threshold_seconds=$(( BREAKGLASS_MAX_AGE_HOURS * 3600 ))

        if (( age_seconds > threshold_seconds )); then
            echo "  Account age: ⚠️  ${age_hours}h (threshold: ${BREAKGLASS_MAX_AGE_HOURS}h) — consider removing with 'remove'"
            log_warn "Break-glass account has been active for ${age_hours} hours (limit: ${BREAKGLASS_MAX_AGE_HOURS}h)."
            log_warn "Remove it when no longer needed: sudo $0 breakglass remove"
        else
            echo "  Account age: ✅ ${age_hours}h (threshold: ${BREAKGLASS_MAX_AGE_HOURS}h)"
        fi
    }

    # ---------------------------------------------------------------------------
    # show_breakglass_status()
    # ---------------------------------------------------------------------------
    show_breakglass_status() {
        log_info "Break-glass admin status:"
        echo ""

        if check_user_exists; then
            echo "  Status: ✅ Active"
            echo "  Username: $BREAKGLASS_USER"

            local user_info
            if user_info=$(getent passwd "$BREAKGLASS_USER"); then
                local home_dir
                home_dir=$(echo "$user_info" | cut -d: -f6)
                echo "  Home directory: $home_dir"

                local instructions_file="$home_dir/EMERGENCY_ACCESS_INSTRUCTIONS.txt"
                if [[ -f "$instructions_file" ]]; then
                    if validate_file_permissions "$instructions_file" "600" "$BREAKGLASS_USER" "$BREAKGLASS_USER"; then
                        echo "  Instructions: ✅ Available and secure"
                    else
                        echo "  Instructions: ⚠️  Available but permissions need fixing"
                    fi
                else
                    echo "  Instructions: ❌ Missing"
                fi

                _check_breakglass_account_age "$home_dir"
            fi

            local sudoers_file="/etc/sudoers.d/vw-emergency"
            if [[ -f "$sudoers_file" ]] && grep -q "^${BREAKGLASS_USER} " "$sudoers_file" 2>/dev/null; then
                echo "  Sudo access: ✅ Configured (targeted /etc/sudoers.d/vw-emergency)"
            elif groups "$BREAKGLASS_USER" 2>/dev/null | grep -q -w "sudo"; then
                echo "  Sudo access: ⚠️  Member of 'sudo' group (legacy full-root configuration)"
            else
                echo "  Sudo access: ❌ NOT configured"
            fi

            if passwd -S "$BREAKGLASS_USER" 2>/dev/null | grep -q " P "; then
                echo "  Account: ✅ Password set"
            else
                echo "  Account: ⚠️  No password or locked"
            fi

            if systemctl is-active --quiet vw-breakglass-cleanup.timer 2>/dev/null; then
                local timer_left
                timer_left=$(systemctl show vw-breakglass-cleanup.timer -p NextElapseUSecRealtime 2>/dev/null | cut -d= -f2 || echo "unknown")
                echo "  Auto-cleanup timer: ✅ Pending via systemd (vw-breakglass-cleanup) [next: ${timer_left}]"
            else
                echo "  Auto-cleanup timer: ℹ️  Not active via systemd (may be scheduled via 'at')"
            fi

        else
            echo "  Status: ❌ Not created"
            echo "  Username: $BREAKGLASS_USER (would be created)"
        fi

        echo ""
        log_info "OCI Console Access:"
        echo "  • Log into Oracle Cloud Infrastructure (OCI)"
        echo "  • Navigate to: Compute → Instances → Your Instance"
        echo "  • Click 'Console Connection'"
        echo "  • Use credentials above to access via serial console"

        echo ""
        log_info "Security Status:"
        if validate_script_security "false"; then
            echo "  • Script security: ✅ Validated"
        else
            echo "  • Script security: ❌ Validation failed"
            return 1
        fi

        return 0
    }

    # ---------------------------------------------------------------------------
    # _restart_after_disable()
    # ---------------------------------------------------------------------------
    _restart_after_disable() {
        local service="${1:-vaultwarden}"

        log_info "Restarting $service to re-apply original token..."
        if docker compose restart "$service"; then
            log_success "$service restarted successfully — breakglass token deactivated"
            return 0
        fi

        local _rc=$?
        log_error "CRITICAL: 'docker compose restart $service' failed (exit ${_rc})."
        log_error "CRITICAL: The breakglass admin token is still ACTIVE."
        log_error "Manual remediation required:"
        log_error "  1. Investigate: docker compose logs $service"
        log_error "  2. Fix the underlying issue (port conflict, OOM, config error)"
        log_error "  3. Re-run: docker compose restart $service"
        log_error "  4. Confirm: sudo utilities/setup-secrets.sh breakglass status"

        _notify_breakglass_event \
            "DISABLE_FAILED" \
            "docker compose restart ${service} exited with code ${_rc}. Breakglass token is still ACTIVE." \
            "CRITICAL"

        return $_rc
    }

    # ---------------------------------------------------------------------------
    # Argument Parsing — subcommand-first dispatch
    # ---------------------------------------------------------------------------
    if [[ $# -eq 0 ]]; then
        _bg_show_help
        return 0
    fi

    case "$1" in
        create)         CREATE_USER=true;    shift ;;
        remove)         REMOVE_USER=true;    shift ;;
        reset-password) RESET_PASSWORD=true; shift ;;
        status)         SHOW_STATUS=true;    shift ;;
        validate)       VALIDATE_ONLY=true;  shift ;;
        help|--help|-h) _bg_show_help; return 0 ;;
        *)
            log_error "Unknown subcommand: $1  (expected: create | remove | reset-password | status | validate)"
            _bg_show_help; return 1
            ;;
    esac

    while [[ $# -gt 0 ]]; do
        case $1 in
            --user)    BREAKGLASS_USER="$2"; shift 2 ;;
            --force)   FORCE=true;           shift ;;
            --dry-run) DRY_RUN=true;         shift ;;
            --help|-h) _bg_show_help; return 0 ;;
            *) log_error "Unknown option: $1"; _bg_show_help; return 1 ;;
        esac
    done

    if [[ "$CREATE_USER" == "true" && "$REMOVE_USER" == "true" ]]; then
        log_error "Cannot create and remove at the same time"
        return 1
    fi

    # ---------------------------------------------------------------------------
    # Main breakglass logic
    # ---------------------------------------------------------------------------
    log_header "VaultWarden-OCI Break-Glass Admin Manager"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    local _security_strict="false"
    [[ "$VALIDATE_ONLY" == "true" ]] && _security_strict="true"

    if ! validate_script_security "$_security_strict"; then
        log_error "Script security validation failed - refusing to proceed"
        log_info "This is a security requirement to prevent privilege escalation"
        return 1
    fi

    if [[ "$VALIDATE_ONLY" == "true" ]]; then
        log_success "Script security validation completed successfully"
        return 0
    fi

    if [[ ! "$BREAKGLASS_USER" =~ ^[a-z][-a-z0-9]*$ ]]; then
        log_error "Invalid username format: $BREAKGLASS_USER"
        log_info "Username must start with lowercase letter and contain only lowercase letters, numbers, and hyphens"
        return 1
    fi

    if [[ "$SHOW_STATUS" == "true" ]]; then
        show_breakglass_status
        return $?
    fi

    local _BG_LOCK_FILE="/run/lock/vaultwarden-breakglass.lock"
    local _BG_LOCK_FD
    exec {_BG_LOCK_FD}>"$_BG_LOCK_FILE"
    trap 'rm -f "${_BG_LOCK_FILE:-}"' RETURN
    if ! flock -n "$_BG_LOCK_FD"; then
        log_error "Another breakglass operation is already running."
        log_error "If the lock is stale, remove: ${_BG_LOCK_FILE}"
        return 1
    fi

    if [[ "$REMOVE_USER" == "true" ]]; then
        if remove_breakglass_user; then
            log_success "Break-glass admin removal completed successfully"
            return 0
        else
            log_error "Break-glass admin removal failed"
            return 1
        fi
    fi

    if [[ "$RESET_PASSWORD" == "true" ]]; then
        if reset_breakglass_password; then
            log_success "Break-glass admin password reset completed successfully"
            return 0
        else
            log_error "Break-glass admin password reset failed"
            return 1
        fi
    fi

    if [[ "$CREATE_USER" == "true" ]]; then
        if create_breakglass_user; then
            log_success "Break-glass admin creation completed successfully"

            echo ""
            log_info "🎯 Next Steps:"
            echo "  1. Store the credentials securely"
            echo "  2. Test OCI Console Connection access"
            echo "  3. Validate script security: sudo utilities/setup-secrets.sh breakglass validate"
            echo "  4. Account will auto-expire in ${BREAKGLASS_AUTO_EXPIRY_HOURS}h; remove sooner if done: sudo utilities/setup-secrets.sh breakglass remove"

            return 0
        else
            log_error "Break-glass admin creation failed"
            return 1
        fi
    fi

    log_error "No valid operation specified"
    _bg_show_help
    return 1
}

# ---------------------------------------------------------------------------
# _cmd_bootstrap — age key, SOPS config, and empty secrets structure
# Called by setup.sh install phase (before credential collection).
# Does NOT prompt for credentials. Run setup-secrets.sh configure to
# fill in actual credentials after editing .env.
# ---------------------------------------------------------------------------
_cmd_bootstrap() {
    local DRY_RUN=false
    local FORCE=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run) DRY_RUN=true; shift ;;
            --force)   FORCE=true;   shift ;;
            --help|-h)
                cat << 'EOF'
utilities/setup-secrets.sh bootstrap — Secrets infrastructure bootstrap

Creates the Age encryption key, SOPS configuration, and a placeholder
encrypted secrets.yaml. Does NOT prompt for credentials.

Run 'setup-secrets.sh configure' (or 'setup.sh secrets') to fill in
actual credentials after editing .env.

FLAGS:
    --dry-run   Preview actions without executing
    --force     Overwrite existing key/config (DANGEROUS: orphans existing secrets)
    --help      Show this help
EOF
                return 0 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    local age_key_file="${PROJECT_ROOT}/secrets/keys/age-key.txt"
    local sops_config="${PROJECT_ROOT}/.sops.yaml"
    local secrets_file="${PROJECT_ROOT}/secrets/secrets.yaml"
    local canonical_key="/etc/vaultwarden/age-key.txt"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would bootstrap: Age key, SOPS config, placeholder secrets"
        return 0
    fi

    # ── 1. Directory structure ───────────────────────────────────────────────
    mkdir -p "${PROJECT_ROOT}/secrets/keys" "${PROJECT_ROOT}/secrets/.docker_secrets" || return 1
    chmod 700 "${PROJECT_ROOT}/secrets/keys" "${PROJECT_ROOT}/secrets/.docker_secrets" || return 1

    # ── 2. Age key ────────────────────────────────────────────────────────────
    if [[ -f "$age_key_file" ]] && [[ "$FORCE" != "true" ]]; then
        if check_age_key "$age_key_file" 2>/dev/null; then
            log_info "Age key already present and valid: $age_key_file (skipping)"
        else
            log_warn "Age key exists but is invalid — regenerating"
            generate_age_key "$age_key_file" true || return 1
        fi
    else
        [[ "$FORCE" == "true" && -f "$age_key_file" ]] && \
            log_warn "bootstrap --force: regenerating Age key (existing encrypted data will be inaccessible)"
        local real_user; real_user=$(get_real_user)
        generate_age_key "$age_key_file" "$FORCE" || return 1
        chown "${real_user}:$(id -g -n "$real_user")" "$age_key_file" || return 1
        chmod 600 "$age_key_file" || return 1
        log_success "Age key created: $age_key_file"
    fi

    # Verify the key immediately after generation/validation
    if ! SOPS_AGE_KEY_FILE="$age_key_file" simple_verify_age_key; then
        log_error "Age key verification failed — aborting bootstrap"
        return 1
    fi

    # ── 3. Canonical install (/etc/vaultwarden/age-key.txt) ──────────────────
    local do_install=true
    if [[ -f "$canonical_key" ]] && [[ "$FORCE" != "true" ]]; then
        if check_age_key "$canonical_key" 2>/dev/null; then
            log_info "Canonical Age key already present and healthy: $canonical_key"
            do_install=false
        else
            log_warn "Canonical Age key invalid — reinstalling: $canonical_key"
        fi
    fi
    if [[ "$do_install" == "true" ]]; then
        local service_user service_group
        service_user="${SERVICE_USER:-${BACKUP_USER:-$(get_real_user)}}"
        service_group=$(id -gn "$service_user" 2>/dev/null || echo "$service_user")
        install -d -m 700 /etc/vaultwarden || return 1
        install -m 600 "$age_key_file" "$canonical_key" || return 1
        chown "${service_user}:${service_group}" "$canonical_key" || return 1
        chmod 600 "$canonical_key" || return 1
        log_success "Age key installed: $canonical_key (mode 600, ${service_user}:${service_group})"
    fi

    # ── 4. Update .env to canonical key path ─────────────────────────────────
    local env_file="${PROJECT_ROOT}/.env"
    if [[ -f "$env_file" ]]; then
        local temp_env
        temp_env=$(mktemp -p "$(dirname "$env_file")" .env.tmp.XXXXXXXXXX) || return 1
        awk '{
            sub(/^SOPS_AGE_KEY_FILE=.*/, "SOPS_AGE_KEY_FILE=/etc/vaultwarden/age-key.txt");
            print;
        }' "$env_file" > "$temp_env"
        mv "$temp_env" "$env_file" || { rm -f "$temp_env"; return 1; }
        log_success "SOPS_AGE_KEY_FILE set to $canonical_key in .env"
    fi

    # ── 5. SOPS config (.sops.yaml) ──────────────────────────────────────────
    local age_public_key
    age_public_key=$(get_age_public_key "$age_key_file") || return 1
    if [[ -z "$age_public_key" ]] || ! [[ "$age_public_key" =~ ^age1[a-z0-9]{58}$ ]]; then
        log_error "Age public key has unexpected format: '${age_public_key}'"
        return 1
    fi
    if [[ -f "$sops_config" ]] && [[ "$FORCE" != "true" ]]; then
        if grep -qF "$age_public_key" "$sops_config" 2>/dev/null \
           && grep -q "creation_rules:" "$sops_config" 2>/dev/null; then
            log_info "SOPS config already up-to-date (skipping)"
        else
            log_warn "SOPS config exists but public key differs — rewriting"
            _write_sops_config "$age_public_key" "$sops_config" || return 1
        fi
    else
        _write_sops_config "$age_public_key" "$sops_config" || return 1
    fi

    # ── 6. Empty encrypted secrets structure ─────────────────────────────────
    if [[ -f "$secrets_file" ]] && [[ "$FORCE" != "true" ]]; then
        local decrypt_ok=false
        ( export SOPS_AGE_KEY_FILE="$age_key_file"; \
          sops -d "$secrets_file" >/dev/null 2>&1 ) && decrypt_ok=true
        if [[ "$decrypt_ok" == "true" ]]; then
            log_info "Placeholder secrets.yaml already present and decryptable (skipping)"
            log_success "Bootstrap complete — run './setup.sh secrets' to configure credentials"
            return 0
        else
            log_error "secrets.yaml unreadable with current key. Use --force to overwrite."
            return 1
        fi
    fi

    local tmp_secrets
    tmp_secrets=$(mktemp "${PROJECT_ROOT}/secrets/vwsecrets.XXXXXXXXXX.yaml") || return 1
    cat > "$tmp_secrets" << 'PLACEHOLDERS'
admin_token: PLACEHOLDER_NOT_CONFIGURED
admin_basic_auth_hash: PLACEHOLDER_NOT_CONFIGURED
smtp_password: PLACEHOLDER_NOT_CONFIGURED
email_api_token: PLACEHOLDER_NOT_CONFIGURED
backup_passphrase: PLACEHOLDER_NOT_CONFIGURED
push_installation_id: PLACEHOLDER_NOT_CONFIGURED
push_installation_key: PLACEHOLDER_NOT_CONFIGURED
caddy_cloudflare_dns_token: PLACEHOLDER_NOT_CONFIGURED
PLACEHOLDERS
    chmod 600 "$tmp_secrets"
    ( export SOPS_AGE_KEY_FILE="$age_key_file"; \
      sops --encrypt --output "$secrets_file" "$tmp_secrets" ) \
        || { rm -f "$tmp_secrets"; return 1; }
    rm -f "$tmp_secrets"
    chmod 600 "$secrets_file" || return 1
    local real_user; real_user=$(get_real_user)
    chown "${real_user}:$(id -g -n "$real_user")" "$secrets_file" || return 1

    log_success "Placeholder secrets.yaml created and encrypted"
    log_success "Bootstrap complete — run './setup.sh secrets' to configure credentials"
    return 0
}

# ---------------------------------------------------------------------------
# _write_sops_config — write .sops.yaml for a given Age public key
# ---------------------------------------------------------------------------
_write_sops_config() {
    local age_pub="$1" dest="$2"
    cat > "$dest" << SOPS_EOF
creation_rules:
  - path_regex: .*\.yaml$
    age: $age_pub
SOPS_EOF
    chmod 640 "$dest"
    local real_user; real_user=$(get_real_user)
    chown "${real_user}:$(id -g -n "$real_user")" "$dest" 2>/dev/null || true
    log_success "SOPS config written: $dest"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    (( EUID == 0 )) || { log_error "Must run as root."; exit 1; }

    local subcmd="${1:-}"
    shift || true

    case "$subcmd" in
        bootstrap)           _cmd_bootstrap "$@" ;;
        configure)           _cmd_configure "$@" ;;
        rotate)              _cmd_rotate "$@" ;;
        export-recovery-kit) _cmd_export_recovery_kit "$@" ;;
        breakglass)          _cmd_breakglass "$@" ;;
        --help|-h)           _show_help; exit 0 ;;
        "")  log_error "Subcommand required. Use --help for usage."; _show_help; exit 1 ;;
        *)   log_error "Unknown subcommand: ${subcmd}"; _show_help; exit 1 ;;
    esac
}

main "$@"
