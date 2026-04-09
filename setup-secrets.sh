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
        can_fix+=("age_key_invalid")
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
                # Key is absent — create fresh; never overwrite because there
                # is nothing to overwrite.  Passing overwrite=false means
                # generate_age_key() will error if the file somehow appeared
                # between the check above and now, which is the safe default.
                log_info "Creating Age encryption key..."
                mkdir -p "$(dirname "$AGE_KEY_FILE")"
                if generate_age_key "$AGE_KEY_FILE" false; then
                    log_success "Age key created: $AGE_KEY_FILE"
                else
                    log_error "Failed to create Age key"
                    return 1
                fi
                ;;
            age_key_invalid)
                # Key file exists but failed validation — only now do we allow
                # overwrite so that valid keys are never silently destroyed by a
                # routine re-run (e.g. to add a user or change a setting).
                log_warn "Age key exists but is invalid — regenerating: $AGE_KEY_FILE"
                if generate_age_key "$AGE_KEY_FILE" true; then
                    log_success "Age key regenerated: $AGE_KEY_FILE"
                else
                    log_error "Failed to regenerate Age key"
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
        create_secrets_backup
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
            pip3 install argon2-cffi && return 0
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
    # Declare SECRETS as a local associative array.  No values are exported to
    # the environment during collection; write_secrets() receives them via the
    # nameref / indirect mechanism below.
    declare -gA _COLLECTED_SECRETS

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
    log_info "════════════════════════════════════════════════════