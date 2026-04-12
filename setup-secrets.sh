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
# FIX (Issue 3): Declare _COLLECTED_SECRETS at script top-level so its
# lifecycle is controlled entirely by this script — not by function scope.
# collect_secrets() populates it; write_secrets() reads and zeros it.
# The EXIT trap below zeroes any remaining keys if the script aborts early.
# ---------------------------------------------------------------------------
declare -A _COLLECTED_SECRETS

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
CLEANUP_ACTIONS=()
register_cleanup() { CLEANUP_ACTIONS+=("$1"); }

# FIX (MEDIUM): Replace eval with a named dispatch helper to eliminate the
# structural eval risk.  Each cleanup action is a string token whose first
# word is looked up in the dispatch table; unknown tokens are logged and
# skipped rather than executed as arbitrary shell code.
_run_cleanup_action() {
    local action="$1"
    case "$action" in
        rm\ -f\ *)
            # Only allow "rm -f <single-path>" entries written by this script.
            local target="${action#rm -f }"
            # Strip surrounding single-quotes added by register_cleanup callers.
            target="${target//\'/}"
            if [[ -z "$target" || "$target" == *$'\n'* ]]; then
                return 0
            fi
            # BUG-#15 FIX: Validate cleanup target resolves inside allowed
            # directories before rm -f to prevent glob expansion or path
            # traversal from deleting files outside /tmp or secrets/.
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
            # Unknown action: log and skip rather than eval.
            log_warn "perform_cleanup: skipping unknown action: $action"
            ;;
    esac
}

perform_cleanup() {
    # FIX (Issue 3): Zero all collected secret values on any EXIT so plaintext
    # secrets are not left live in the process if the script aborts early.
    for key in "${!_COLLECTED_SECRETS[@]}"; do
        _COLLECTED_SECRETS["$key"]=""
    done
    unset _COLLECTED_SECRETS 2>/dev/null || true

    for ((idx=${#CLEANUP_ACTIONS[@]}-1; idx>=0; idx--)); do
        _run_cleanup_action "${CLEANUP_ACTIONS[$idx]}"
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
        2. nano .env           (set CLOUDFLARE_ZONE_ID, EMAIL_MODE, EMAIL_PROVIDER,
                                SMTP_HOST, etc.)
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
    ✅ Collects email API token OR smtp_password based on EMAIL_MODE

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
                # FIX (MEDIUM): Validate the Age public key format before writing
                # .sops.yaml.  An empty or malformed key is accepted silently by the
                # previous code, causing sops --encrypt to fail later with a confusing
                # error.  Age public keys always begin with "age1" and consist of
                # lowercase bech32 characters (a-z0-9).
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

# ---------------------------------------------------------------------------
# SS-L2: Helper — write timeout warnings to /dev/tty when available so that
# automated pipelines capturing stdout are not silently confused by the
# default-to-'no' decision.
#
# FIX (LOW): Suppress /dev/tty output when --quiet-summary is active to
# prevent unexpected terminal output during silent sub-invocations.
# ---------------------------------------------------------------------------
_warn_tty() {
    local msg="$1"
    # When QUIET_SUMMARY is true this script is being called by setup.sh in a
    # non-interactive context; writing to /dev/tty would produce unexpected
    # output on the operator's terminal that setup.sh has not accounted for.
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
        # FIX (Issue 6): Do not write a backup when --dry-run is also active.
        # An admin running --dry-run --force expects a preview only; writing a
        # real backup file is a side-effect they do not expect.
        [[ "$DRY_RUN" != "true" ]] && create_secrets_backup
        return 0
    fi

    log_info "Secrets already configured and valid"

    if [[ "$AUTO_MODE" == "true" ]]; then
        log_info "Auto mode - keeping existing secrets"
        return 1
    fi

    echo ""
    # FIX [L-04]: Add -t 30 timeout to avoid hanging in non-interactive contexts
    # FIX SS-L2: Route timeout warning to /dev/tty when available
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

# ---------------------------------------------------------------------------
# Argon2 check
# ---------------------------------------------------------------------------
ensure_argon2_available() {
    if check_argon2_support >/dev/null 2>&1; then return 0; fi

    # FIX (Issue 2): Gate on an import check first so we skip the pip install
    # entirely when argon2-cffi is already installed under a different path
    # (e.g. system package).  Only proceed to install if the module is genuinely
    # absent.  Use a pinned version range to prevent silent breaking upgrades and
    # add a PEP 668 (externally-managed-environment) fallback via --user.
    if python3 -c "import argon2" 2>/dev/null; then
        return 0
    fi

    log_warn "Argon2 not detected"

    if [[ "$AUTO_MODE" != "true" ]]; then
        # FIX [L-04]: Add -t 30 timeout to avoid hanging in non-interactive contexts
        # FIX SS-L2: Route timeout warning to /dev/tty when available
        local install_it
        if ! read -r -t 30 -p "Install Python argon2-cffi? (yes/no): " install_it; then
            _warn_tty "WARNING: No input received (30s timeout). Treating as 'no'."
            install_it="no"
        fi
        if [[ "$install_it" == "yes" ]]; then
            # FIX (Issue 2): Pinned version range prevents silent breaking upgrades.
            # PEP 668 fallback: if the system Python is externally managed, try --user.
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
#
# FIX (MEDIUM): Secret values must be YAML-safe.  Values containing : # [ {
# or leading whitespace produce malformed YAML when written with bare printf
# '%s'.  This helper wraps the value in YAML single-quote scalars and escapes
# any literal single-quote characters inside the value (YAML spec: '' → ').
# Output is ready for direct embedding in a YAML single-quoted scalar context.
# ---------------------------------------------------------------------------
yaml_escape() {
    local value="$1"
    # Replace every ' with '' (YAML single-quote escape), then wrap in '...'.
    local escaped="${value//\'/\'\'}"
    printf "'%s'" "$escaped"
}

# ---------------------------------------------------------------------------
# _read_dotenv_value KEY [FILE]
#
# Read a single KEY from .env (or FILE) without sourcing the whole file.
# Returns the value, or an empty string if the key is not found.
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
    # Strip inline comments (one-or-more whitespace then #) and trailing whitespace.
    # Requiring at least one space before # deliberately preserves passwords that
    # contain '#' (e.g. "p@ss#1") while correctly stripping "VALUE  # comment".
    val=$(grep -E "^${key}=" "$file" | head -1 | sed "s/^${key}=//;s/[[:space:]]\+#.*$//;s/[[:space:]]*$//")
    echo "$val"
}

# ---------------------------------------------------------------------------
# Collect secrets
#
# FIX (HIGH): SECRET_* env vars must NOT be exported during the collection
# phase because they are visible in /proc/$$/environ to all subprocesses.
# All secret values are stored exclusively in the local SECRETS associative
# array.  The export loop that previously ran at the end of collect_secrets()
# has been removed.  write_secrets() reads directly from SECRETS[key].
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
#
# EMAIL COLLECTION:
#   The email tier is chosen by reading EMAIL_MODE from .env:
#     auto  — collect BOTH the API token (email_api_token) and smtp_password
#             (lib/email.sh will try API first, then SMTP as fallback)
#     api   — collect email_api_token only
#     smtp  — collect smtp_password only
#     host  — skip both (Postfix sidecar; no credential needed here)
#   A single canonical key "email_api_token" is used for ALL providers.
#   Changing EMAIL_PROVIDER in .env is the only action needed to switch;
#   the token value in secrets.yaml does not need re-keying.
# ---------------------------------------------------------------------------
collect_secrets() {
    # _COLLECTED_SECRETS is declared at script top-level (see top of file).
    # Populate it here; write_secrets() reads and zeroes it.

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
    _COLLECTED_SECRETS["admin_token"]="$vw_hash"

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
    _COLLECTED_SECRETS["admin_basic_auth_hash"]="$caddy_hash"

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
    _COLLECTED_SECRETS["caddy_cloudflare_dns_token"]="$cf_dns"

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
    _COLLECTED_SECRETS["fail2ban_cloudflare_firewall_token"]="$cf_fw"

    # --- Email credentials (API token + SMTP password) ----------------------
    #
    # Read EMAIL_MODE and EMAIL_PROVIDER from .env so we know which
    # credential(s) to collect.  Defaults: mode=auto, provider=mailersend.
    # ---------------------------------------------------------------------------
    local _email_mode _email_provider
    _email_mode=$(    _read_dotenv_value "EMAIL_MODE"     .env)
    _email_provider=$(   _read_dotenv_value "EMAIL_PROVIDER" .env)
    if [[ -z "$_email_mode" && -f ".env" && ! -r ".env" ]]; then
        log_warn "collect_secrets: .env is not readable by $(id -un); EMAIL_MODE/EMAIL_PROVIDER defaulting to 'auto'/'mailersend'."
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
    log_info "To rotate the token: ./edit-secrets.sh --rotate email_api_token"
    echo ""

    # ----------- Tier 1: provider HTTP API token ----------------------------
    # Single canonical key "email_api_token" used for all providers.
    # No per-provider key derivation — switching EMAIL_PROVIDER in .env is
    # the only change needed; the token value in secrets.yaml stays the same.
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
            log_warn "  ./edit-secrets.sh --rotate email_api_token"
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
                log_info "  ./edit-secrets.sh --rotate email_api_token"
            fi
        fi
        _COLLECTED_SECRETS["email_api_token"]="$email_api_token"
    else
        _COLLECTED_SECRETS["email_api_token"]="NOT_USED_EMAIL_MODE=${_email_mode}"
    fi

    # ----------- Tier 2: SMTP relay password --------------------------------
    # Collected when EMAIL_MODE is 'smtp' or 'auto'.
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
                log_info "  ./edit-secrets.sh --rotate smtp_password"
            fi
        fi
        _COLLECTED_SECRETS["smtp_password"]="$smtp_pass"
    elif [[ "$_email_mode" == "host" ]]; then
        # Postfix sidecar: no SMTP relay password needed from secrets.
        _COLLECTED_SECRETS["smtp_password"]="NOT_USED_EMAIL_MODE=host"
        log_info "EMAIL_MODE=host: smtp_password not needed (Postfix sidecar handles delivery)"
    else
        # api-only mode: SMTP password not used, but store a clear placeholder
        # so the secrets file always has all expected keys.
        _COLLECTED_SECRETS["smtp_password"]="NOT_USED_EMAIL_MODE=${_email_mode}"
    fi

    # --- Backup passphrase (always auto-generated) --------------------------
    echo ""
    log_info "Generating backup encryption passphrase..."
    local backup_pass
    backup_pass=$(auto_generate_secret_field "backup_passphrase") || { log_error "Failed to generate backup_passphrase"; return 1; }
    _COLLECTED_SECRETS["backup_passphrase"]="$backup_pass"

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
            _COLLECTED_SECRETS["push_installation_id"]=$(auto_generate_secret_field "push_installation_id")
            _COLLECTED_SECRETS["push_installation_key"]=$(auto_generate_secret_field "push_installation_key")
        else
            # FIX [L-04]: Add -t 30 timeout to avoid hanging in non-interactive contexts
            # FIX SS-L2: Route timeout warning to /dev/tty when available
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
                log_info "Push notifications skipped - configure later with: ./edit-secrets.sh --rotate push_installation_id"
            fi
        fi
    else
        _COLLECTED_SECRETS["push_installation_id"]="CHANGE_ME_OR_LEAVE_EMPTY"
        _COLLECTED_SECRETS["push_installation_key"]="CHANGE_ME_OR_LEAVE_EMPTY"
    fi

    # FIX (HIGH): The previous export loop:
    #   for key in "${!SECRETS[@]}"; do export "SECRET_$key=${SECRETS[$key]}"; done
    # made all plaintext secrets visible in /proc/$$/environ to every subprocess
    # spawned during the collection phase.  It has been removed entirely.
    # write_secrets() now reads directly from _COLLECTED_SECRETS[].

    echo ""
    log_success "All secrets collected successfully"
    return 0
}

# ---------------------------------------------------------------------------
# export_docker_secrets
#
# Decrypt every canonical key from the SOPS-encrypted secrets/secrets.yaml
# and write a corresponding plain-text file under secrets/.docker_secrets/.
# Each file is created with mode 600 (enforced by write_secret_file()) and
# the directory is ensured at mode 700.
#
# This function must be called AFTER write_secrets() has moved the encrypted
# file to its final location.  It is the authoritative step that satisfies
# the `make up` pre-flight check:
#   test -s secrets/.docker_secrets/admin_token
#
# Security properties:
#   - SOPS env is set up and torn down within this function.
#   - decrypt_secret() suppresses xtrace and unsets the value after printf.
#   - write_secret_file() verifies non-empty write and sets chmod 600.
#   - Plaintext local variables are unset immediately after the write call.
# ---------------------------------------------------------------------------
export_docker_secrets() {
    local docker_secrets_dir="$PROJECT_ROOT/secrets/.docker_secrets"

    log_info "Exporting decrypted secrets to Docker secrets directory..."

    # Ensure the directory exists with tight permissions.
    if ! mkdir -p "$docker_secrets_dir"; then
        log_error "export_docker_secrets: failed to create $docker_secrets_dir"
        return 1
    fi
    chmod 700 "$docker_secrets_dir"

    if ! ensure_sops_env; then
        log_error "export_docker_secrets: failed to set up SOPS environment"
        return 1
    fi

    # Canonical list of keys that must have corresponding flat files.
    # Keep in sync with validate_required_secrets() in lib/secrets.sh.
    local -a _keys=(
        admin_token
        admin_basic_auth_hash
        caddy_cloudflare_dns_token
        fail2ban_cloudflare_firewall_token
        email_api_token
        smtp_password
        backup_passphrase
        push_installation_id
        push_installation_key
    )

    local _failed=0
    local _key _value

    for _key in "${_keys[@]}"; do
        # decrypt_secret() handles SOPS env, xtrace suppression, and stderr capture.
        _value=$(decrypt_secret "$_key" "$SECRETS_FILE") || {
            log_error "export_docker_secrets: failed to decrypt '$_key'"
            _failed=$(( _failed + 1 ))
            continue
        }

        if ! write_secret_file "${docker_secrets_dir}/${_key}" "$_value"; then
            log_error "export_docker_secrets: failed to write ${docker_secrets_dir}/${_key}"
            _failed=$(( _failed + 1 ))
        fi

        # Unset plaintext value immediately after the write.
        unset _value
    done
    unset _key

    cleanup_secrets_environment

    if [[ $_failed -gt 0 ]]; then
        log_error "export_docker_secrets: $_failed key(s) failed to export"
        return 1
    fi

    log_success "Docker secrets exported to: $docker_secrets_dir"
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

    # FIX (HIGH): Detect and report mkdir failure explicitly instead of
    # swallowing it with '2>/dev/null || true'.  A failed mkdir would cause
    # the subsequent mktemp -p to fail with an opaque "No such file or
    # directory" error that hides the true root cause.
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
    register_cleanup "rm -f '$temp_file'"

    # FIX (MEDIUM): All secret values are passed through yaml_escape() which
    # wraps them in YAML single-quoted scalars and escapes internal
    # single-quotes.  This prevents values containing : # [ { or leading
    # whitespace from producing malformed YAML.
    {
        printf '# VaultWarden Secrets Configuration\n'
        printf '# Generated: %s\n' "$(date -Iseconds)"
        printf '# Encrypted with: SOPS + Age\n\n'
        printf '# VaultWarden admin password (Argon2id hash)\n'
        printf 'admin_token: %s\n\n'                       "$(yaml_escape "${_COLLECTED_SECRETS[admin_token]}")"
        printf '# Caddy admin password (htpasswd format: admin:$2y$14$...)\n'
        printf 'admin_basic_auth_hash: %s\n\n'             "$(yaml_escape "${_COLLECTED_SECRETS[admin_basic_auth_hash]}")"
        printf '# Email — Tier 1: HTTP API token (all providers)\n'
        printf '# Single key regardless of EMAIL_PROVIDER. Change EMAIL_PROVIDER in .env\n'
        printf '# to switch providers; no re-keying of this secret is required.\n'
        printf '# To rotate: ./edit-secrets.sh --rotate email_api_token\n'
        printf 'email_api_token: %s\n\n'                   "$(yaml_escape "${_COLLECTED_SECRETS[email_api_token]:-}")"
        printf '# Email — Tier 2: SMTP relay password\n'
        printf '# Used when EMAIL_MODE=smtp or EMAIL_MODE=auto (fallback from API).\n'
        printf '# To rotate: ./edit-secrets.sh --rotate smtp_password\n'
        printf 'smtp_password: %s\n\n'                     "$(yaml_escape "${_COLLECTED_SECRETS[smtp_password]}")"
        printf '# Backup encryption passphrase\n'
        printf 'backup_passphrase: %s\n\n'                 "$(yaml_escape "${_COLLECTED_SECRETS[backup_passphrase]}")"
        printf '# Push notifications (optional)\n'
        printf 'push_installation_id: %s\n'                "$(yaml_escape "${_COLLECTED_SECRETS[push_installation_id]}")"
        printf 'push_installation_key: %s\n\n'             "$(yaml_escape "${_COLLECTED_SECRETS[push_installation_key]}")"
        printf '# Cloudflare DNS API token (Zone:DNS:Edit + Zone:Zone:Read)\n'
        printf 'caddy_cloudflare_dns_token: %s\n\n'        "$(yaml_escape "${_COLLECTED_SECRETS[caddy_cloudflare_dns_token]}")"
        printf '# Cloudflare Firewall API token (Zone:Firewall Services:Edit)\n'
        printf 'fail2ban_cloudflare_firewall_token: %s\n'  "$(yaml_escape "${_COLLECTED_SECRETS[fail2ban_cloudflare_firewall_token]}")"
    } > "$temp_file"

    # Clear the in-memory associative array immediately after writing, to
    # minimise the window in which plaintext values are live in the process.
    for key in "${!_COLLECTED_SECRETS[@]}"; do
        _COLLECTED_SECRETS["$key"]=""
    done
    unset _COLLECTED_SECRETS
    # Re-declare as empty so the EXIT trap does not error on an unbound variable.
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

    # Ensure the Docker secrets directory exists (may not yet exist on first run).
    local docker_secrets_dir="$PROJECT_ROOT/secrets/.docker_secrets"
    if [[ ! -d "$docker_secrets_dir" ]]; then
        mkdir -p "$docker_secrets_dir"
        chmod 700 "$docker_secrets_dir"
        log_info "Created Docker secrets directory: $docker_secrets_dir"
    fi

    # Export decrypted flat files so that `make up` pre-flight checks pass.
    # This is the authoritative write of secrets/.docker_secrets/* and must
    # run every time write_secrets() succeeds.
    if ! export_docker_secrets; then
        log_error "Failed to export Docker secret files — run ./setup-secrets.sh again"
        return 1
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

    # FIX (Issue 5): Verify that the installed htpasswd binary supports bcrypt
    # (-B flag).  Some minimal apache2-utils builds ship without bcrypt support;
    # the failure would otherwise surface deep inside lib/secrets.sh with an
    # opaque error.  Run a quick smoke-test here and exit early with a clear
    # install hint if bcrypt is unavailable.
    if ! htpasswd -nbB _test_ _test123_ &>/dev/null; then
        log_error "htpasswd on this system does not support bcrypt (-B flag)"
        log_error "This is required for Caddy admin basic-auth hashing."
        log_info  "Fix: sudo apt-get install --reinstall apache2-utils"
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

    # FIX (Issue 4): Scope the SECRET_* cleanup sweep to only the exact keys
    # defined and used by this script. The previous compgen -v SECRET_ prefix
    # sweep was overly broad and would unset any SECRET_* variable exported by
    # a parent process (e.g. SECRET_KEY from a CI system), which is destructive
    # in shared-host or CI environments.
    for _cleanup_key in \
        admin_token admin_basic_auth_hash \
        caddy_cloudflare_dns_token fail2ban_cloudflare_firewall_token \
        email_api_token smtp_password backup_passphrase \
        push_installation_id push_installation_key; do
        unset "SECRET_${_cleanup_key}" 2>/dev/null || true
    done
    unset _cleanup_key

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
        log_success "✅ Docker secret files written to: secrets/.docker_secrets/"
        echo ""
        # Phase 2-C: Updated next-steps to reflect the new install order.
        # The user has already edited .env before running this script, so
        # step 1 is "Verify" not "Review/create".
        # FIX SS-L1: cron-setup.sh was removed; reference setup-systemd.sh instead.
        echo "📋 Next Steps:"
        echo "   1. Verify .env settings:      nano .env"
        echo "      ► Confirm: CLOUDFLARE_ZONE_ID, EMAIL_MODE, EMAIL_PROVIDER,"
        echo "                 SMTP_HOST, SMTP_PORT, SMTP_USERNAME"
        echo "   2. Start services:            make up"
        echo "   3. Setup automation:          sudo ./setup-systemd.sh --install"
        echo "   4. Export recovery kit:       ./edit-secrets.sh --export-recovery-kit"
        echo "   5. Test health:               ./health.sh"
        echo "   6. To rotate a single field:  ./edit-secrets.sh --rotate FIELD"
        echo "   7. To list secret keys:       ./edit-secrets.sh --list"
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

    exit 0
}

main "$@"
