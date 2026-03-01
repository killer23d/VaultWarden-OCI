#!/usr/bin/env bash
# setup-secrets.sh - Idempotent VaultWarden secrets configuration (SECURITY HARDENED)
# Can be run standalone or called from setup.sh --auto.
# Safe to re-run multiple times.
#
# SECURITY ENHANCEMENT: Caddy basic auth hash in htpasswd format (admin:$2y$14$...)
#
# See also: ./edit-secrets.sh  (edit, view, list keys, rotate a single field,
#                               or export recovery kit)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"
source "lib/secrets.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
AUTO_MODE=false
SKIP_VALIDATION=false
SKIP_OPTIONAL=false
FORCE=false
DRY_RUN=false
AUTO_FIX=true
EXPORT_RECOVERY_KIT=false
# Phase 1-B: When called from setup.sh, suppress the completion banner,
# next-steps block, and offer_recovery_kit_export prompt so that setup.sh
# can display a single consolidated summary screen instead.
QUIET_SUMMARY=false

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
CLEANUP_ACTIONS=()
register_cleanup() { CLEANUP_ACTIONS+=("$1"); }
perform_cleanup() {
    for ((idx=${#CLEANUP_ACTIONS[@]}-1; idx>=0; idx--)); do
        eval "${CLEANUP_ACTIONS[$idx]}" 2>/dev/null || true
    done
    cleanup_secrets_environment
}
trap perform_cleanup EXIT

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
show_help() {
    cat << 'HELP'
VaultWarden Interactive Secrets Setup (Idempotent - Security Hardened)

USAGE:
    ./setup-secrets.sh [OPTIONS]

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
        ./edit-secrets.sh --export-recovery-kit

    The intended standalone order is:
        1. sudo ./setup.sh --domain DOMAIN --email EMAIL
        2. nano .env           (set CLOUDFLARE_ZONE_ID, SMTP_HOST, etc.)
        3. ./setup-secrets.sh  (prompted for all credentials)
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

SECURITY ENHANCEMENTS:
    ✅ Caddy basic auth in htpasswd format (admin:\$2y\$14\$...)
    ✅ Hash validation before storage
    ✅ Secure temporary file handling
    ✅ Enhanced error messages

EXAMPLES:
    ./setup-secrets.sh                  # Interactive setup
    ./setup-secrets.sh --auto           # Automated with generated passwords
    ./setup-secrets.sh --force          # Reconfigure without prompting
    ./setup-secrets.sh --skip-optional  # Skip push notifications
    ./setup-secrets.sh --export-recovery-kit # Prompt for kit after setup

SEE ALSO:
    ./edit-secrets.sh --list                  # Show existing secret key names
    ./edit-secrets.sh --rotate FIELD          # Rotate a single secret
    ./edit-secrets.sh                         # Interactive raw edit
    ./edit-secrets.sh --export-recovery-kit   # Standalone recovery kit export
HELP
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
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
        --help)                  show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
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
            log_error "Prerequisites missing. Run './setup.sh' first or use --auto-fix"
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
                cat > .sops.yaml << SOPS_EOF
creation_rules:
  - path_regex: secrets/secrets\.yaml$
    age: $age_public_key
SOPS_EOF
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

# ---------------------------------------------------------------------------
# Idempotency guard
# ---------------------------------------------------------------------------
secrets_are_configured() {
    if ! secrets_file_exists; then return 1; fi
    if ! ensure_sops_env;      then return 1; fi
    if ! check_placeholder_values 2>/dev/null; then
        return 1
    fi
    return 0
}

validate_existing_secrets() {
    log_info "Validating existing secrets..."

    if ! ensure_sops_env; then return 1; fi

    local issues=()

    validate_secrets_decryption || issues+=("Cannot decrypt secrets file")
    validate_secrets_yaml       || issues+=("Invalid YAML structure")
    validate_required_secrets   || issues+=("Missing required secrets")
    check_placeholder_values    || issues+=("Contains placeholder values")

    if [[ ${#issues[@]} -gt 0 ]]; then
        log_warn "Validation issues found:"
        for issue in "${issues[@]}"; do log_warn "  - $issue"; done
        return 1
    fi

    log_success "Existing secrets are valid"
    return 0
}

check_reconfiguration() {
    if ! secrets_are_configured; then
        log_info "No valid secrets found - configuration needed"
        return 0
    fi

    if [[ "$FORCE" == "true" ]]; then
        log_info "Force mode - reconfiguring secrets"
        create_secrets_backup
        return 0
    fi

    log_info "Secrets already configured and valid"

    if [[ "$AUTO_MODE" == "true" ]]; then
        log_info "Auto mode - keeping existing secrets"
        return 1
    fi

    echo ""
    read -r -p "Reconfigure secrets? (yes/no): " confirm

    if [[ "$confirm" == "yes" ]]; then
        create_secrets_backup
        return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# Argon2 check
# ---------------------------------------------------------------------------
ensure_argon2_available() {
    if check_argon2_support >/dev/null 2>&1; then return 0; fi

    log_warn "Argon2 not detected"

    if [[ "$AUTO_MODE" != "true" ]]; then
        read -r -p "Install Python argon2-cffi? (yes/no): " install_it
        if [[ "$install_it" == "yes" ]]; then
            pip3 install argon2-cffi && return 0
        fi
    fi

    log_error "Argon2 required but not available"
    return 1
}

# ---------------------------------------------------------------------------
# Collect secrets
#
# Both AUTO_MODE and interactive paths delegate to lib/secrets.sh:
#   - interactive  → collect_secret_field()        (prompts, hashes, validates)
#   - auto         → auto_generate_secret_field()  (generates, hashes, validates)
#
# In --auto mode, auto_generate_secret_field() intentionally emits CHANGE_ME
# placeholders for credentials that exist in external systems (CF tokens,
# SMTP password, push keys). These must be rotated manually with:
#   ./edit-secrets.sh --rotate FIELD
# This is by design: --auto is truly non-interactive.
#
# All hashing logic (Argon2id, bcrypt) and format validation live exclusively
# in lib/secrets.sh. collect_secrets() is a thin orchestration layer.
# ---------------------------------------------------------------------------
collect_secrets() {
    declare -A SECRETS

    # Helper: call the right lib function based on AUTO_MODE
    _get_field() {
        local field="$1"
        if [[ "$AUTO_MODE" == "true" ]]; then
            auto_generate_secret_field "$field"
        else
            collect_secret_field "$field"
        fi
    }

    # --- VaultWarden admin password (Argon2id) -------------------------------
    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info " VaultWarden Admin Password"
    log_info "═══════════════════════════════════════════════════════════"
    log_info "This password will be hashed with Argon2id for VaultWarden"
    echo ""

    local vw_hash
    vw_hash=$(_get_field "admin_token") || { log_error "Failed to collect admin_token"; return 1; }
    SECRETS["admin_token"]="$vw_hash"

    # --- Caddy admin password (bcrypt / htpasswd) ----------------------------
    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info " Caddy Admin Panel Password"
    log_info "═══════════════════════════════════════════════════════════"
    log_info "This password will be hashed with bcrypt for Caddy basic auth"
    log_info 'Format: htpasswd (admin:$2y$14$...)'
    echo ""

    local caddy_hash
    caddy_hash=$(_get_field "admin_basic_auth_hash") || { log_error "Failed to collect admin_basic_auth_hash"; return 1; }
    SECRETS["admin_basic_auth_hash"]="$caddy_hash"

    # --- Cloudflare DNS token ------------------------------------------------
    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info " Cloudflare DNS API Token"
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Required Permissions: Zone:DNS:Edit + Zone:Zone:Read"
    log_info "Create at: https://dash.cloudflare.com/profile/api-tokens"
    echo ""

    local cf_dns
    cf_dns=$(_get_field "caddy_cloudflare_dns_token") || { log_error "Failed to collect caddy_cloudflare_dns_token"; return 1; }
    SECRETS["caddy_cloudflare_dns_token"]="$cf_dns"

    # --- Cloudflare Firewall token ------------------------------------------
    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info " Cloudflare Firewall API Token"
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Required Permissions: Zone:Firewall Services:Edit"
    log_info "Create at: https://dash.cloudflare.com/profile/api-tokens"
    echo ""

    local cf_fw
    cf_fw=$(_get_field "fail2ban_cloudflare_firewall_token") || { log_error "Failed to collect fail2ban_cloudflare_firewall_token"; return 1; }
    SECRETS["fail2ban_cloudflare_firewall_token"]="$cf_fw"

    # --- SMTP password ------------------------------------------------------
    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info " SMTP Password (Email Notifications)"
    log_info "═══════════════════════════════════════════════════════════"
    echo ""

    local smtp_pass
    if [[ "$AUTO_MODE" == "true" ]]; then
        # auto_generate_secret_field emits CHANGE_ME_SMTP_PASSWORD for this
        # field — correct behaviour; caller must rotate with edit-secrets.sh.
        smtp_pass=$(auto_generate_secret_field "smtp_password") || { log_error "Failed to generate smtp_password"; return 1; }
    else
        read -r -p "Enable email notifications now? (yes/no): " enable_email
        if [[ "$enable_email" == "yes" ]]; then
            smtp_pass=$(collect_secret_field "smtp_password") || { log_error "Failed to collect smtp_password"; return 1; }
            log_success "SMTP password configured"
        else
            smtp_pass="CHANGE_ME_SMTP_PASSWORD"
            log_info "Email skipped - configure later with: ./edit-secrets.sh --rotate smtp_password"
        fi
    fi
    SECRETS["smtp_password"]="$smtp_pass"

    # --- Backup passphrase (always auto-generated) --------------------------
    echo ""
    log_info "Generating backup encryption passphrase..."
    local backup_pass
    backup_pass=$(auto_generate_secret_field "backup_passphrase") || { log_error "Failed to generate backup_passphrase"; return 1; }
    SECRETS["backup_passphrase"]="$backup_pass"

    # --- Push notifications (optional) --------------------------------------
    if [[ "$SKIP_OPTIONAL" != "true" ]]; then
        echo ""
        log_info "═══════════════════════════════════════════════════════════"
        log_info " Push Notifications (Optional)"
        log_info "═══════════════════════════════════════════════════════════"
        log_info "Get credentials from: https://bitwarden.com/host"
        echo ""

        if [[ "$AUTO_MODE" == "true" ]]; then
            # auto_generate_secret_field emits CHANGE_ME placeholders for push
            # keys — correct behaviour for truly non-interactive mode.
            SECRETS["push_installation_id"]=$(auto_generate_secret_field "push_installation_id")
            SECRETS["push_installation_key"]=$(auto_generate_secret_field "push_installation_key")
        else
            read -r -p "Configure push notifications? (yes/no): " do_push
            if [[ "$do_push" == "yes" ]]; then
                SECRETS["push_installation_id"]=$(collect_secret_field "push_installation_id") || return 1
                SECRETS["push_installation_key"]=$(collect_secret_field "push_installation_key") || return 1
                log_success "Push notifications configured"
            else
                SECRETS["push_installation_id"]="CHANGE_ME_OR_LEAVE_EMPTY"
                SECRETS["push_installation_key"]="CHANGE_ME_OR_LEAVE_EMPTY"
                log_info "Push notifications skipped - configure later with: ./edit-secrets.sh --rotate push_installation_id"
            fi
        fi
    else
        SECRETS["push_installation_id"]="CHANGE_ME_OR_LEAVE_EMPTY"
        SECRETS["push_installation_key"]="CHANGE_ME_OR_LEAVE_EMPTY"
    fi

    for key in "${!SECRETS[@]}"; do
        export "SECRET_$key=${SECRETS[$key]}"
    done

    echo ""
    log_success "All secrets collected successfully"
    return 0
}

# ---------------------------------------------------------------------------
# Write secrets (atomic)
# ---------------------------------------------------------------------------
write_secrets() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would write secrets to encrypted file"
        return 0
    fi

    log_info "Writing secrets to encrypted YAML file..."

    local temp_file="$PROJECT_ROOT/secrets/.temp_secrets.yaml"
    touch "$temp_file"
    chmod 600 "$temp_file"
    register_cleanup "rm -f '$temp_file'"

    {
        printf '# VaultWarden Secrets Configuration\n'
        printf '# Generated: %s\n' "$(date -Iseconds)"
        printf '# Encrypted with: SOPS + Age\n\n'
        printf '# VaultWarden admin password (Argon2id hash)\n'
        printf 'admin_token: %s\n\n' "$SECRET_admin_token"
        printf '# Caddy admin password (htpasswd format: admin:$2y$14$...)\n'
        printf 'admin_basic_auth_hash: %s\n\n' "$SECRET_admin_basic_auth_hash"
        printf '# SMTP password for email notifications\n'
        printf 'smtp_password: %s\n\n' "$SECRET_smtp_password"
        printf '# Backup encryption passphrase\n'
        printf 'backup_passphrase: %s\n\n' "$SECRET_backup_passphrase"
        printf '# Push notifications (optional)\n'
        printf 'push_installation_id: %s\n' "$SECRET_push_installation_id"
        printf 'push_installation_key: %s\n\n' "$SECRET_push_installation_key"
        printf '# Cloudflare DNS API token (Zone:DNS:Edit + Zone:Zone:Read)\n'
        printf 'caddy_cloudflare_dns_token: %s\n\n' "$SECRET_caddy_cloudflare_dns_token"
        printf '# Cloudflare Firewall API token (Zone:Firewall Services:Edit)\n'
        printf 'fail2ban_cloudflare_firewall_token: %s\n' "$SECRET_fail2ban_cloudflare_firewall_token"
    } > "$temp_file"

    chmod 600 "$temp_file"

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

    local docker_secrets_dir="$PROJECT_ROOT/secrets/.docker_secrets"
    if [[ ! -d "$docker_secrets_dir" ]]; then
        mkdir -p "$docker_secrets_dir"
        chmod 700 "$docker_secrets_dir"
        log_info "Created Docker secrets directory: $docker_secrets_dir"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log_header "VaultWarden Secrets Setup (Security Hardened)"

    echo ""
    log_info "This script will configure all secrets for VaultWarden deployment"
    log_info "Secrets will be encrypted with SOPS + Age encryption"
    echo ""

    if ! require_commands sops age python3 jq htpasswd; then
        log_error "Missing required commands"
        log_info "Install htpasswd with: sudo apt-get install apache2-utils"
        exit 1
    fi

    if ! ensure_prerequisites;    then exit 1; fi
    if ! ensure_argon2_available; then exit 1; fi

    if ! check_reconfiguration; then
        log_info "Keeping existing secrets - no changes made"
        log_info "Tip: to rotate a single field run: ./edit-secrets.sh --rotate FIELD"
        log_info "Tip: to export a recovery kit run:  ./edit-secrets.sh --export-recovery-kit"
        exit 0
    fi

    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info " Secrets Collection"
    log_info "═══════════════════════════════════════════════════════════"
    if ! collect_secrets; then
        log_error "Failed to collect secrets"
        exit 1
    fi

    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info " Writing Encrypted Secrets"
    log_info "═══════════════════════════════════════════════════════════"
    if ! write_secrets; then
        log_error "Failed to write secrets"
        exit 1
    fi

    # Phase 1-B: Gate the entire completion output on QUIET_SUMMARY.
    #
    # When called from setup.sh --auto with --quiet-summary:
    #   - The auto-generated plaintext passwords emitted by log_warn inside
    #     auto_generate_secret_field() (above) are already visible on screen.
    #   - setup.sh owns show_post_install_summary("auto"), which is the single
    #     consolidated screen listing what still needs to be done.
    #   - Suppressing this block also eliminates the offer_recovery_kit_export
    #     interactive prompt that would hang in a non-TTY context.
    #
    # When run standalone (--quiet-summary not passed):
    #   - Full completion banner and updated next-steps are displayed.
    #   - offer_recovery_kit_export prompt is shown as usual.
    if [[ "$QUIET_SUMMARY" != "true" ]]; then
        echo ""
        log_header "Secrets Setup Complete!"
        echo ""
        log_success "✅ Secrets encrypted and stored in: $SECRETS_FILE"
        log_success "✅ Caddy admin hash in htpasswd format: admin:\$2y\$14\$..."
        log_success "✅ VaultWarden admin hash in Argon2id format"
        log_success "✅ All secrets protected with Age encryption"
        echo ""
        # Phase 2-C: Updated next-steps to reflect the new install order.
        # The user has already edited .env before running this script, so
        # step 1 is "Verify" not "Review/create".
        echo "📋 Next Steps:"
        echo "   1. Verify .env settings:      nano .env"
        echo "      ► Confirm: CLOUDFLARE_ZONE_ID, SMTP_HOST, SMTP_PORT, SMTP_USERNAME"
        echo "   2. Start services:            make up"
        echo "   3. Setup automation:          sudo ./cron-setup.sh --install"
        echo "   4. Export recovery kit:       ./edit-secrets.sh --export-recovery-kit"
        echo "   5. Test health:               ./health.sh"
        echo "   6. To rotate a single field:  ./edit-secrets.sh --rotate FIELD"
        echo "   7. To list secret keys:       ./edit-secrets.sh --list"
        echo ""
        log_warn "⚠️  If you used --auto mode, scroll up to save the generated passwords!"
        echo ""

        if [[ "$DRY_RUN" == "false" ]]; then
            offer_recovery_kit_export "$EXPORT_RECOVERY_KIT"
        fi
    fi

    exit 0
}

main "$@"
