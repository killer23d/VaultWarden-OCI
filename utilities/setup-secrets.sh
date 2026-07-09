#!/usr/bin/env bash
# utilities/setup-secrets.sh — Manages VaultWarden-OCI secrets.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

old_umask=$(umask)
umask 077
TMP_WORKDIR=$(mktemp -d -p "${PROJECT_ROOT}" vw_tmp.XXXXXXXXXX) || {
    echo "ERROR: Failed to create secure temporary directory" >&2
    exit 1
}
umask "$old_umask"
trap 'if declare -F _ss_perform_cleanup >/dev/null 2>&1; then _ss_perform_cleanup; fi; rm -rf "${TMP_WORKDIR:-}"' EXIT
trap 'if declare -F _ss_perform_cleanup >/dev/null 2>&1; then _ss_perform_cleanup; fi; rm -rf "${TMP_WORKDIR:-}"; exit 130' INT
trap 'if declare -F _ss_perform_cleanup >/dev/null 2>&1; then _ss_perform_cleanup; fi; rm -rf "${TMP_WORKDIR:-}"; exit 143' TERM

for _lib in "lib/log.sh" "lib/config.sh" "lib/common.sh" "lib/email.sh" "lib/crypto.sh" "lib/secrets.sh" "lib/operations.sh"; do
    if [[ ! -f "${PROJECT_ROOT}/${_lib}" ]]; then
        echo "ERROR: Required library not found: ${PROJECT_ROOT}/${_lib}" >&2
        exit 1
    fi
done
unset _lib

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/config.sh"
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"
source "${PROJECT_ROOT}/lib/operations.sh"
source "${PROJECT_ROOT}/lib/email.sh"
source "${PROJECT_ROOT}/lib/crypto.sh"
source "${PROJECT_ROOT}/lib/secrets.sh"
SOPS_CONFIG_FILE="${PROJECT_ROOT}/.sops.yaml"
export SOPS_CONFIG_FILE

SETUP_SECRETS_GUARD_HELD=false

_setup_secrets_cleanup_all() {
    local rc=$?
    operation_release "$rc"
    if declare -F _ss_perform_cleanup >/dev/null 2>&1; then
        _ss_perform_cleanup
    fi
    rm -rf "${TMP_WORKDIR:-}" 2>/dev/null || true
    exit "$rc"
}

_setup_secrets_should_guard() {
    local subcmd="$1"
    shift || true
    case "$subcmd" in
        bootstrap|configure)
            return 0
            ;;
        breakglass)
            local action="${1:-}"
            case "$action" in
                create|remove|reset-password)
                    local arg
                    for arg in "$@"; do
                        [[ "$arg" == "--dry-run" ]] && return 1
                    done
                    return 0
                    ;;
            esac
            ;;
    esac
    return 1
}

_setup_secrets_acquire_guard() {
    local subcmd="$1"
    shift || true
    _setup_secrets_should_guard "$subcmd" "$@" || return 0
    [[ "$SETUP_SECRETS_GUARD_HELD" == "true" ]] && return 0

    local policy="fail"
    if [[ ! -t 0 || ! -t 1 ]]; then
        policy="skip"
    fi
    operation_acquire \
        --id secrets \
        --label "Secrets" \
        --specific-lock /run/lock/vaultwarden-secrets.lock \
        --non-interactive "$policy" || return $?
    SETUP_SECRETS_GUARD_HELD=true
    trap _setup_secrets_cleanup_all EXIT
    trap 'operation_release 130; if declare -F _ss_perform_cleanup >/dev/null 2>&1; then _ss_perform_cleanup; fi; rm -rf "${TMP_WORKDIR:-}" 2>/dev/null || true; exit 130' INT
    trap 'operation_release 143; if declare -F _ss_perform_cleanup >/dev/null 2>&1; then _ss_perform_cleanup; fi; rm -rf "${TMP_WORKDIR:-}" 2>/dev/null || true; exit 143' HUP TERM
    operation_set_phase "$subcmd" "Secrets ${subcmd}"
}

show_help() {
    cat << 'EOF'
VaultWarden-OCI Secrets Management

USAGE:
    sudo utilities/setup-secrets.sh SUBCOMMAND [OPTIONS]

DESCRIPTION:
    Manages VaultWarden-OCI secrets: bootstrap Age encryption, configure
    credentials interactively or automatically. Interactive view/list/rotate
    and recovery-kit export are root-operated commands via sudo ./edit-secrets.sh.

SUBCOMMANDS:
    bootstrap           Bootstrap Age key, SOPS config, and placeholder secrets
                        (called automatically by setup.sh install phase)
    configure           Full interactive/auto secrets setup (replaces setup.sh secrets)
    breakglass [FLAGS]  Emergency break-glass admin account management
    help, --help, -h    Show this help

OPTIONS:
    --help, -h          Show this help
    --version, -V       Print the VaultWarden-OCI version and exit

Run: setup-secrets.sh SUBCOMMAND --help  for subcommand-specific help.

EXAMPLES:
    sudo utilities/setup-secrets.sh bootstrap
    sudo utilities/setup-secrets.sh configure
    sudo utilities/setup-secrets.sh configure --auto
    sudo ./edit-secrets.sh rotate email_api_token
    sudo ./edit-secrets.sh export-recovery-kit
    sudo utilities/setup-secrets.sh breakglass create
    sudo utilities/setup-secrets.sh breakglass status
EOF
}

# Run interactive or automated secrets setup.
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
        sudo ./edit-secrets.sh export-recovery-kit

    The intended standalone order is:
        1. sudo ./setup.sh --domain DOMAIN --email EMAIL
        2. nano .env           (set EMAIL_MODE, EMAIL_PROVIDER,
                                SMTP_HOST, etc.)
        3. sudo utilities/setup-secrets.sh configure
        4. sudo make up
        
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
    sudo ./edit-secrets.sh list                  # Show existing secret key names
    sudo ./edit-secrets.sh rotate FIELD          # Rotate a single secret
    sudo ./edit-secrets.sh export-recovery-kit   # Export recovery kit
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
                    _write_sops_config "$age_public_key" ".sops.yaml" || return 1
                    log_success "SOPS configuration created: .sops.yaml"
                    ;;
                directories)
                    log_info "Creating directory structure..."
                    mkdir -p secrets/keys /run/vaultwarden-oci/secrets
                    chmod 700 secrets/keys /run/vaultwarden-oci/secrets
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
            [[ "$DRY_RUN" != "true" ]] && create_secrets_backup "$SECRETS_FILE" "$SECRETS_BACKUP_DIR"
            return 0
        fi

        log_info "Secrets already configured and valid"

        if [[ "$AUTO_MODE" == "true" ]]; then
            log_info "Auto mode - keeping existing secrets"
            return 1
        fi

        echo ""
        local confirm
        if ! read -r -t 30 -p "Reconfigure secrets? [yes/no] (default: no): " confirm; then
            _warn_tty "WARNING: No input received (30s timeout). Treating as 'no'."
            confirm="no"
        fi

        if [[ "$confirm" == "yes" ]]; then
            create_secrets_backup "$SECRETS_FILE" "$SECRETS_BACKUP_DIR"
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
            if ! read -r -t 30 -p "Install Python argon2-cffi? [yes/no] (default: no): " install_it; then
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
        # Internal helper: collect one field either by auto-generation or by
        # interactive prompt, depending on the --auto flag.
        _get_field() {
            local field="$1"
            if [[ "$AUTO_MODE" == "true" ]]; then
                auto_generate_secret_field "$field"
            else
                collect_secret_field "$field"
            fi
        }

        # Schema condition_fn predicates receive the key name and return 0 when
        # collection should proceed. Keep predicates side-effect free so they
        # are safe to reuse for every key in an atomic group.
        condition_push_enabled() {
            local _condition_key="$1"
            [[ -n "$_condition_key" && "$_push_enabled" == "true" ]]
        }

        # _dispatch_auto_fn FIELD
        #
        # Calls the function declared by FIELD's schema auto_fn and prints the
        # generated value. Returns 1 when no auto_fn is declared, the function
        # is unavailable, or generation fails. Requires the schema and secrets
        # libraries to be loaded in the current Bash 5+ shell.
        _dispatch_auto_fn() {
            local _field="$1"
            local _auto_fn
            _auto_fn=$(schema_field_safe "$_field" "auto_fn" 2>/dev/null) || _auto_fn=""
            if [[ -z "$_auto_fn" ]]; then
                return 1
            fi
            if ! declare -F "$_auto_fn" >/dev/null 2>&1; then
                log_error "_dispatch_auto_fn: function '$_auto_fn' declared in schema for '$_field' but not defined in this shell"
                return 1
            fi
            "$_auto_fn" "$_field"
        }

        # Read all key names from the schema once so we don't call yq in a loop.
        local _schema_keys
        if ! _schema_keys=$(schema_keys); then
            log_error "collect_secrets: failed to read keys from secrets-schema.yaml"
            return 1
        fi

        # ── Resolve email mode once (used by two keys below) ──────────────────
        local _email_mode _email_provider
        _email_mode=$(    _read_dotenv_value "EMAIL_MODE"     .env)
        _email_provider=$(   _read_dotenv_value "EMAIL_PROVIDER" .env)
        if [[ -z "$_email_mode" && -f ".env" && ! -r ".env" ]]; then
            log_warn "setup-secrets.sh configure: .env is not readable by $(id -un); EMAIL_MODE/EMAIL_PROVIDER defaulting to 'auto'/'mailersend'."
            log_warn "Run setup/secrets through the root-operated path or make .env operator-readable before configuring secrets"
        fi
        _email_mode="${_email_mode:-auto}"
        _email_provider="${_email_provider:-mailersend}"
        local _push_enabled
        _push_enabled=$(_read_dotenv_value "PUSH_ENABLED" .env)
        _push_enabled="${_push_enabled:-false}"

        # ── Schema-driven dispatch loop ───────────────────────────────────────
        #
        # For each key in schema order:
        #   interactive  → prompt user (hash as required by the key's 'hash' field)
        #   auto         → call the function named in 'auto_fn'
        #   conditional  → evaluate condition_fn, then collect or use placeholder
        #   skip         → omit this key entirely
        #
        # Business logic that is too context-dependent to express as a predicate
        # (for example email-mode sentinel values) remains in the matching key
        # branch. The schema drives ordering, collection mode, and simple gates.

        while IFS= read -r _key; do
            [[ -z "$_key" ]] && continue
            local _collect_type
            _collect_type=$(schema_collect_type "$_key")

            if [[ "$_collect_type" == "auto" ]]; then
                local _auto_value
                if ! _auto_value=$(_dispatch_auto_fn "$_key"); then
                    log_error "collect_secrets: auto generation failed for schema key '${_key}'"
                    return 1
                fi
                _COLLECTED_SECRETS["$_key"]="$_auto_value"
                continue
            fi

            if [[ "$_collect_type" == "conditional" ]]; then
                local _condition_fn _placeholder
                _condition_fn=$(schema_condition_fn "$_key")
                if [[ -z "$_condition_fn" ]] || ! declare -F "$_condition_fn" >/dev/null 2>&1; then
                    log_error "collect_secrets: conditional key '${_key}' has invalid condition_fn '${_condition_fn}'"
                    return 1
                fi
                if ! "$_condition_fn" "$_key"; then
                    _placeholder=$(schema_placeholder_for_key "$_key")
                    _COLLECTED_SECRETS["$_key"]="$_placeholder"
                    log_info "${_key}: condition ${_condition_fn} is false; using schema placeholder"
                    continue
                fi
            fi

            case "$_key" in

            # ── admin_token ────────────────────────────────────────────────────
            admin_token)
                echo ""
                log_info "═══════════════════════════════════════════════════════════"
                log_info " VaultWarden Admin Password"
                log_info "═══════════════════════════════════════════════════════════"
                log_info "This password will be hashed with Argon2id for VaultWarden"
                echo ""

                local vw_hash
                if [[ "$QUIET_SUMMARY" == "true" ]] && [[ "$AUTO_MODE" == "true" ]]; then
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
                ;;

            # ── admin_basic_auth_hash ──────────────────────────────────────────
            admin_basic_auth_hash)
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
                ;;

            # ── smtp_password ──────────────────────────────────────────────────
            # Q2: email-mode sentinel — when EMAIL_MODE gates this key out,
            # write the NOT_USED_EMAIL_MODE=<mode> sentinel (not the schema
            # placeholder and not empty) so downstream consumers can distinguish
            # "not applicable" from "not configured".
            smtp_password)
                if [[ "$_email_mode" == "smtp" || "$_email_mode" == "auto" || "$_email_mode" == "direct" || "$_email_mode" == "host" ]]; then
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
                        if ! read -r -t 30 -p "Enter smtp_password now? [yes/no] (default: no): " enable_smtp; then
                            _warn_tty "WARNING: No input received (30s timeout). Treating as 'no'."
                            enable_smtp="no"
                        fi
                        if [[ "$enable_smtp" == "yes" ]]; then
                            smtp_pass=$(collect_secret_field "smtp_password") || { log_error "Failed to collect smtp_password"; return 1; }
                            log_success "smtp_password configured"
                        else
                            smtp_pass="CHANGE_ME_SMTP_PASSWORD"
                            log_info "SMTP password skipped — rotate later with:"
                            log_info "  ./utilities/secrets-rotate.sh smtp_password"
                        fi
                    fi
                    _COLLECTED_SECRETS["smtp_password"]="$smtp_pass"
                else
                    _COLLECTED_SECRETS["smtp_password"]="NOT_USED_EMAIL_MODE=${_email_mode}"
                fi
                ;;

            # ── email_api_token ────────────────────────────────────────────────
            # Q2: same sentinel logic — inactive mode writes NOT_USED_EMAIL_MODE=<mode>.
            email_api_token)
                echo ""
                log_info "═══════════════════════════════════════════════════════════"
                log_info " Email Notifications"
                log_info "═══════════════════════════════════════════════════════════"
                log_info "Current .env settings:"
                log_info "  EMAIL_MODE     = $_email_mode"
                log_info "  EMAIL_PROVIDER = $_email_provider"
                echo ""
                log_info "Delivery tiers (controlled by EMAIL_MODE in .env):"
                log_info "  auto  — try API → Postfix sidecar → direct upstream SMTP in order (recommended)"
                log_info "  api   — HTTP API only   (requires email_api_token in secrets)"
                log_info "  smtp  — Postfix sidecar → direct SMTP (requires smtp_password for direct fallback)"
                log_info "  host  — deprecated alias for direct (smtp_password required)"
                echo ""
                log_info "One token key (email_api_token) works for ALL providers."
                log_info "To switch providers: change EMAIL_PROVIDER in .env only."
                log_info "To rotate the token: ./utilities/secrets-rotate.sh email_api_token"
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
                        log_warn "  ./utilities/secrets-rotate.sh email_api_token"
                    else
                        local skip_api
                        if ! read -r -t 30 -p "Enter email_api_token now? [yes/no] (default: no): " skip_api; then
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
                            log_info "  ./utilities/secrets-rotate.sh email_api_token"
                        fi
                    fi
                    _COLLECTED_SECRETS["email_api_token"]="$email_api_token"
                else
                    _COLLECTED_SECRETS["email_api_token"]="NOT_USED_EMAIL_MODE=${_email_mode}"
                fi
                ;;

            # file_integrity_hmac_key is auto-generated via _dispatch_auto_fn()
            # above. Do not add a manual case here; it would bypass the schema.

            # ── push_installation_id / push_installation_key ───────────────────
            # condition_push_enabled has already gated this block through the
            # schema dispatcher. The two credentials remain an atomic group.
            push_installation_id)
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
                        log_warn "[AUTO] PUSH_ENABLED=true but Bitwarden push credentials cannot be generated automatically."
                        log_warn "Rotate both push fields before startup."
                    else
                        local do_push
                        if ! read -r -t 30 -p "Configure push notifications? [yes/no] (default: no): " do_push; then
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
                            log_info "Push notifications skipped - configure later with: ./utilities/secrets-rotate.sh push_installation_id"
                        fi
                    fi
                else
                    _COLLECTED_SECRETS["push_installation_id"]="CHANGE_ME_OR_LEAVE_EMPTY"
                    _COLLECTED_SECRETS["push_installation_key"]="CHANGE_ME_OR_LEAVE_EMPTY"
                fi
                ;;

            # push_installation_key is collected alongside push_installation_id
            # in the block above; skip it when the loop reaches it directly.
            push_installation_key)
                [[ -n "${_COLLECTED_SECRETS[push_installation_key]+x}" ]] || \
                    _COLLECTED_SECRETS["push_installation_key"]="CHANGE_ME_OR_LEAVE_EMPTY"
                ;;

            # ── caddy_cloudflare_dns_token ─────────────────────────────────────
            caddy_cloudflare_dns_token)
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
                ;;

            # ── cf_worker_bouncer_token / cloudflare_zone_id / cf_account_id ───
            cf_worker_bouncer_token)
                echo ""
                log_info "═══════════════════════════════════════════════════════════"
                log_info " Cloudflare CrowdSec Bouncer Credentials"
                log_info "═══════════════════════════════════════════════════════════"
                log_info "cf_worker_bouncer_token: Cloudflare dashboard → My Profile → API Tokens"
                log_info "cloudflare_zone_id: Cloudflare dashboard → Zone overview page"
                log_info "cf_account_id: Cloudflare dashboard → any Zone overview page"
                echo ""

                local cf_worker_bouncer_token cloudflare_zone_id cf_account_id
                if [[ "$AUTO_MODE" == "true" ]]; then
                    cf_worker_bouncer_token="CHANGE_ME_CF_WORKER_BOUNCER_TOKEN"
                    cloudflare_zone_id="CHANGE_ME_CLOUDFLARE_ZONE_ID"
                    cf_account_id="CHANGE_ME_CF_ACCOUNT_ID"
                    log_warn "[AUTO] Cloudflare CrowdSec bouncer credentials set to placeholders."
                    log_warn "Rotate after setup with: ./utilities/secrets-rotate.sh cf_worker_bouncer_token"
                else
                    cf_worker_bouncer_token=$(_get_field "cf_worker_bouncer_token") || { log_error "Failed to collect cf_worker_bouncer_token"; return 1; }
                    cloudflare_zone_id=$(_get_field "cloudflare_zone_id") || { log_error "Failed to collect cloudflare_zone_id"; return 1; }
                    cf_account_id=$(_get_field "cf_account_id") || { log_error "Failed to collect cf_account_id"; return 1; }
                fi
                _COLLECTED_SECRETS["cf_worker_bouncer_token"]="$cf_worker_bouncer_token"
                _COLLECTED_SECRETS["cloudflare_zone_id"]="$cloudflare_zone_id"
                _COLLECTED_SECRETS["cf_account_id"]="$cf_account_id"
                ;;

            # cloudflare_zone_id and cf_account_id are collected together in the
            # cf_worker_bouncer_token block above; skip when loop reaches them.
            cloudflare_zone_id|cf_account_id)
                :  # already populated by cf_worker_bouncer_token block
                ;;

            # ── Unknown key (future-proofing) ──────────────────────────────────
            *)
                if [[ "$_collect_type" == "skip" ]]; then
                    log_info "collect_secrets: schema key '${_key}' is collect=skip; omitting from fresh secrets"
                else
                    log_error "collect_secrets: no collection handler for schema key '${_key}' (collect=${_collect_type})"
                    return 1
                fi
                ;;

            esac
        done <<< "$_schema_keys"

        while IFS= read -r _key; do
            [[ -z "$_key" ]] && continue
            local _collect_type
            _collect_type=$(schema_collect_type "$_key")
            [[ "$_collect_type" == "skip" ]] && continue
            if [[ -z "${_COLLECTED_SECRETS[$_key]+set}" ]]; then
                log_error "collect_secrets: schema key '${_key}' was not deliberately collected or generated"
                return 1
            fi
        done <<< "$_schema_keys"

        echo ""
        log_success "All secrets collected successfully"
        return 0
    }

    # Assemble the secrets YAML, encrypt it with SOPS, and install it atomically.
    write_secrets() {
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would write secrets to encrypted file"
            return 0
        fi

        log_info "Writing secrets to encrypted YAML file..."

        local secrets_dir
        secrets_dir="$(dirname "$SECRETS_FILE")"
        if ! mkdir -p "$secrets_dir"; then
            log_error "Failed to create secrets directory: $secrets_dir"
            return 1
        fi
        chown root:root "$secrets_dir" || return 1
        chmod 700 "$secrets_dir" || return 1

        local temp_file=""
        temp_file="$(_ss_make_plaintext_temp)" || {
            log_error "Failed to create protected plaintext staging file"
            return 1
        }

        # shellcheck disable=SC2064  # intentional — $temp_file must expand NOW
        _ss_register_cleanup "rm -f ${temp_file}"

        # Build the YAML body from the schema-defined key list so that adding or
        # renaming a key in secrets-schema.yaml is sufficient — no printf lines
        # here need to change.
        {
            printf '# VaultWarden Secrets Configuration\n'
            printf '# Generated: %s\n' "$(date -Iseconds)"
            printf '# Encrypted with: SOPS + Age\n\n'

            local _wkeys
            _wkeys=$(schema_keys) || {
                log_error "write_secrets: failed to read key list from secrets-schema.yaml"
                return 1
            }
            while IFS= read -r _wkey; do
                [[ -z "$_wkey" ]] && continue
                local _label _collect_type
                _collect_type=$(schema_collect_type "$_wkey")
                [[ "$_collect_type" == "skip" ]] && continue
                if [[ -z "${_COLLECTED_SECRETS[$_wkey]+set}" ]]; then
                    log_error "write_secrets: schema key '${_wkey}' has no collected/generated value"
                    return 1
                fi
                _label=$(schema_field_safe "$_wkey" label)
                [[ -n "$_label" ]] && printf '# %s\n' "$_label"
                printf '%s: %s\n\n' \
                    "$_wkey" \
                    "$(yaml_escape "${_COLLECTED_SECRETS[$_wkey]}")"
            done <<< "$_wkeys"
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
        local _operational_key _operational_recipient
        _operational_key="${SOPS_AGE_KEY_FILE:-${AGE_KEY_FILE:-}}"
        _operational_recipient="$(get_age_public_key "$_operational_key")" || return 1
        if ! _ss_commit_ciphertext_transaction "$temp_file" "$_operational_key" "$_operational_recipient" "$SECRETS_FILE" "$SOPS_CONFIG_FILE" plaintext "$(_ss_desired_recipients_csv "$_operational_recipient")"; then
            log_error "Failed to stage, validate, and promote encrypted secrets"
            return 1
        fi
        rm -f "$temp_file"

        if ! secure_secrets_file "$SECRETS_FILE"; then
            log_error "Failed to secure secrets file permissions"
            return 1
        fi

        log_success "Secrets encrypted and written to: $SECRETS_FILE"

        local docker_secrets_dir="/run/vaultwarden-oci/secrets"
        if [[ ! -d "$docker_secrets_dir" ]]; then
            install -d -m 700 -o root -g root "$docker_secrets_dir" || return 1
            log_info "Created Docker secrets directory: $docker_secrets_dir"
        fi

        if ! export_docker_secrets "/run/vaultwarden-oci/secrets"; then
            log_error "Failed to export Docker secret files — run sudo utilities/setup-secrets.sh configure again"
            return 1
        fi
        if ! prepare_push_secret_placeholders "/run/vaultwarden-oci/secrets"; then
            log_error "Failed to prepare push secret placeholder files"
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
            log_info "Tip: to rotate a single field run: sudo ./edit-secrets.sh rotate FIELD"
            log_info "Tip: to export a recovery kit run:  sudo ./edit-secrets.sh export-recovery-kit"
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
            caddy_cloudflare_dns_token cf_account_id cf_worker_bouncer_token cloudflare_zone_id \
            email_api_token smtp_password file_integrity_hmac_key \
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
            log_success "✅ Docker secret files written to: /run/vaultwarden-oci/secrets/"
            echo ""
            echo "📋 Next Steps:"
            echo "   1. Verify .env settings:      nano .env"
            echo "      ► Confirm: EMAIL_MODE, EMAIL_PROVIDER,"
            echo "                 SMTP_HOST, SMTP_PORT, SMTP_USERNAME"
            echo "   2. Start services:            sudo make up"
            echo "   3. Setup automation:          sudo ./setup.sh systemd install"
            echo "   4. Export recovery kit:       sudo ./edit-secrets.sh export-recovery-kit"
            echo "   5. Test health:               ./maintenance.sh health"
            echo "   6. To rotate a single field:  sudo ./edit-secrets.sh rotate FIELD"
            echo "   7. To list secret keys:       sudo ./edit-secrets.sh list"
            echo ""
            echo "📧 Email mode reference (set EMAIL_MODE in .env):"
            echo "   auto  — API → Postfix sidecar → direct upstream SMTP fallback chain (recommended)"
            echo "   api   — HTTP API only  (set EMAIL_PROVIDER + rotate email_api_token)"
            echo "   smtp  — Postfix sidecar → direct SMTP (rotate smtp_password)"
            echo "   host  — deprecated alias for direct (smtp_password required)"
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

_cmd_user_secret_stub() {
    local subcmd="$1"
    log_error "'utilities/setup-secrets.sh ${subcmd}' is not a root setup command."
    log_error "Run root-operated secrets commands with sudo:"
    case "$subcmd" in
        rotate) log_error "  sudo ./edit-secrets.sh rotate FIELD" ;;
        export-recovery-kit) log_error "  sudo ./edit-secrets.sh export-recovery-kit" ;;
    esac
    return 1
}

# Manage the emergency break-glass admin account.
_cmd_breakglass() {
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
----------------------------------------
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
        press_enter_to_continue " Press [Enter] to clear the visible screen and finish..."
        clear

        schedule_auto_cleanup

        return 0
    }

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
            read -r -p "Continue with removal? [yes/no] (default: no): " confirm
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
            --user)
                if [[ -z "${2-}" || "${2}" == --* ]]; then
                    log_error "--user requires a username"
                    _bg_show_help
                    return 1
                fi
                BREAKGLASS_USER="$2"; shift 2 ;;
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
        log_error "Check active operations with: sudo make operations"
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

_ss_plain_tmp_dir() {
    printf '%s' "${VW_SETUP_SECRETS_TMP_DIR:-/run/vaultwarden-oci/tmp}"
}

_ss_prepare_plain_tmp_dir() {
    local dir
    dir="$(_ss_plain_tmp_dir)"
    if [[ "$dir" == "/run/vaultwarden-oci/tmp" ]]; then
        install -d -m 0700 -o root -g root "$dir"
    else
        mkdir -p "$dir" && chmod 0700 "$dir"
    fi
}

_ss_make_plaintext_temp() {
    local dir tmp
    _ss_prepare_plain_tmp_dir || return 1
    dir="$(_ss_plain_tmp_dir)"
    tmp=$(mktemp -p "$dir" vwsecrets.XXXXXXXXXX.yaml) || return 1
    chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
    printf '%s' "$tmp"
}

_ss_valid_age_recipient() {
    [[ "${1:-}" =~ ^age1[a-z0-9]{58}$ ]]
}

_ss_policy_recipients() {
    local file="$1" age_value=""
    [[ -f "$file" ]] || return 0
    if command -v yq >/dev/null 2>&1; then
        age_value="$(yq -r '.creation_rules[0].age // ""' "$file" 2>/dev/null || true)"
    else
        age_value="$(awk -F: '/^[[:space:]]*age:/ { gsub(/[ "'"'"']/, "", $2); print $2; exit }' "$file")"
    fi
    tr ',' '\n' <<< "$age_value" | sed '/^$/d'
}

_ss_cipher_recipients() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    if command -v yq >/dev/null 2>&1; then
        yq -r '.sops.age[]?.recipient // ""' "$file" 2>/dev/null | sed '/^$/d'
    else
        awk '/^[[:space:]]*-[[:space:]]*recipient:/ { print $NF }' "$file"
    fi
}

_ss_manifest_file() {
    printf '%s' "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/config/dr-manifest.env"
}

_ss_manifest_offline_recipient() {
    local manifest
    manifest="$(_ss_manifest_file)"
    [[ -f "$manifest" ]] || return 0
    _read_env_value OFFLINE_AGE_RECIPIENT "$manifest"
}

_ss_explain_offline_recovery_recipient() {
    operator_attention warn "Offline recovery Age recipient" \
        "This optional public key adds a separate offline recipient for encrypted secrets." \
        "If you skip it, disaster recovery depends on the operational Age key or an exported recovery kit."
}

_ss_warn_offline_recovery_recipient_skipped() {
    log_warn "Offline recovery Age public key skipped; encrypted secrets will not have a separate offline recovery recipient."
    log_warn "Export and store a recovery kit offline so disaster recovery does not depend on this server."
}

_ss_desired_recipients_csv() {
    local operational="$1" offline="" recipient unknown=() seen=""
    _ss_valid_age_recipient "$operational" || { log_error "Invalid operational Age recipient: $operational"; return 1; }

    if [[ -n "${OFFLINE_AGE_RECIPIENT:-}" ]]; then
        _ss_valid_age_recipient "$OFFLINE_AGE_RECIPIENT" || { log_error "Invalid OFFLINE_AGE_RECIPIENT format"; return 1; }
        offline="$OFFLINE_AGE_RECIPIENT"
    else
        offline="$(_ss_manifest_offline_recipient)"
        if [[ -n "$offline" ]]; then
            _ss_valid_age_recipient "$offline" || { log_error "Invalid OFFLINE_AGE_RECIPIENT in manifest"; return 1; }
        fi
    fi

    if [[ -z "$offline" ]]; then
        while IFS= read -r recipient; do
            recipient="${recipient// /}"
            [[ -z "$recipient" || "$recipient" == "$operational" ]] && continue
            _ss_valid_age_recipient "$recipient" && unknown+=("$recipient")
        done < <(_ss_policy_recipients "${PROJECT_ROOT}/.sops.yaml")
        if (( ${#unknown[@]} == 1 )); then
            offline="${unknown[0]}"
        elif (( ${#unknown[@]} > 1 )); then
            log_error "Multiple unknown non-operational Age recipients in .sops.yaml; review manually."
            return 1
        fi
    fi

    if [[ -z "$offline" && -t 0 ]]; then
        _ss_explain_offline_recovery_recipient
        while true; do
            read -r -p "Enter offline recovery Age public key (press Enter to skip): " offline
            if [[ -z "$offline" ]]; then
                _ss_warn_offline_recovery_recipient_skipped
                break
            fi
            if _ss_valid_age_recipient "$offline"; then
                break
            else
                log_warn "Invalid format — expected: age1<58 lowercase alphanumeric chars>"
                log_warn "Example:  age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgp..."
                log_warn "Press Enter with no input to skip."
                offline=""
            fi
        done
    fi

    printf '%s' "$operational"
    seen=",${operational},"
    if [[ -n "$offline" && "$seen" != *",${offline},"* ]]; then
        printf ',%s' "$offline"
    fi
}

_ss_recipients_match() {
    local desired_csv="$1" file="$2" mode="$3" desired sorted_desired found sorted_found
    desired=$(tr ',' '\n' <<< "$desired_csv" | sed '/^$/d' | sort -u | paste -sd, -)
    if [[ "$mode" == "policy" ]]; then
        found=$(_ss_policy_recipients "$file" | sort -u | paste -sd, -)
    else
        found=$(_ss_cipher_recipients "$file" | sort -u | paste -sd, -)
    fi
    sorted_desired="$desired"
    sorted_found="$found"
    [[ -n "$sorted_found" && "$sorted_found" == "$sorted_desired" ]]
}

_ss_write_policy_file() {
    local dest="$1" desired_csv="$2"
    {
        printf 'creation_rules:\n'
        printf "  - path_regex: '.*\\.yaml$'\n"
        if [[ "$desired_csv" == *,* ]]; then
            printf '    # Offline recovery key — USB only, never stored on server\n'
        fi
        printf '    age: "%s"\n' "$desired_csv"
    } > "$dest"
    chmod 0644 "$dest"
}

_ss_set_env_var_in_file() {
    local key="$1" value="$2" file="$3"
    local escaped_key tmp_file escaped_value
    escaped_key=$(printf '%s' "$key" | sed 's/[]\/$*.^[]/\\&/g')
    tmp_file="$(dirname "$file")/.env.tmp.$$"
    if grep -q "^${escaped_key}=" "$file" 2>/dev/null; then
        escaped_value="${value//\\/\\\\}"
        escaped_value="${escaped_value//&/\\&}"
        escaped_value="${escaped_value//|/\\|}"
        sed "s|^${escaped_key}=.*|${key}=${escaped_value}|" "$file" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    else
        cp "$file" "$tmp_file" || { rm -f "$tmp_file"; return 1; }
        printf '%s=%s\n' "$key" "$value" >> "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    fi
    chmod --reference="$file" "$tmp_file" 2>/dev/null || true
    mv "$tmp_file" "$file" || { rm -f "$tmp_file"; return 1; }
}

_ss_stage_manifest_update() {
    local desired_csv="$1" manifest_stage="$2" manifest_dir manifest offline=""
    if [[ "$desired_csv" == *,* ]]; then
        offline="${desired_csv#*,}"
    fi
    [[ -n "$offline" ]] || return 0
    manifest="$(_ss_manifest_file)"
    manifest_dir="$(dirname "$manifest")"
    mkdir -p "$manifest_dir" || return 1
    if [[ -f "$manifest" ]]; then
        cp "$manifest" "$manifest_stage" || return 1
    else
        : > "$manifest_stage" || return 1
    fi
    _ss_set_env_var_in_file OFFLINE_AGE_RECIPIENT "$offline" "$manifest_stage" || return 1
    _ss_set_env_var_in_file MANIFEST_UPDATED_AT "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$manifest_stage" || return 1
}

_ss_restore_or_remove() {
    local existed="$1" backup="$2" target="$3"
    if [[ "$existed" == "true" ]]; then
        cp "$backup" "$target"
    else
        rm -f "$target"
    fi
}

_ss_commit_ciphertext_transaction() {
    local plaintext_file="$1" operational_key="$2" operational_recipient="$3" final_file="$4" policy_file="$5" mode="${6:-plaintext}" desired_csv="${7:-}"
    local policy_stage ciphertext_stage manifest_stage backup_dir ciphertext_backup policy_backup manifest_backup manifest_file caller_return_trap caller_int_trap caller_term_trap
    local ciphertext_existed=false policy_existed=false manifest_existed=false ciphertext_promoted=false policy_promoted=false manifest_promoted=false

    if [[ -z "$desired_csv" ]]; then
        desired_csv="$(_ss_desired_recipients_csv "$operational_recipient")" || return 1
    fi
    manifest_file="$(_ss_manifest_file)"
    caller_return_trap="$(trap -p RETURN)"
    caller_int_trap="$(trap -p INT)"
    caller_term_trap="$(trap -p TERM)"

    if [[ "$mode" == "rekey" && -f "$final_file" ]] \
        && _ss_recipients_match "$desired_csv" "$policy_file" policy \
        && _ss_recipients_match "$desired_csv" "$final_file" cipher; then
        log_info "SOPS policy and ciphertext recipients already current"
        return 0
    fi

    mkdir -p "$(dirname "$final_file")" "$(dirname "$policy_file")" "$(dirname "$manifest_file")" || return 1
    backup_dir=$(mktemp -d) || return 1
    policy_stage=$(mktemp -p "$(dirname "$policy_file")" .sops.yaml.XXXXXXXXXX) || { rm -rf "$backup_dir"; return 1; }
    ciphertext_stage=$(mktemp -p "$(dirname "$final_file")" secrets.XXXXXXXXXX.yaml) || { rm -rf "$backup_dir"; rm -f "$policy_stage"; return 1; }
    manifest_stage=$(mktemp -p "$(dirname "$manifest_file")" dr-manifest.env.XXXXXXXXXX) || { rm -rf "$backup_dir"; rm -f "$policy_stage" "$ciphertext_stage"; return 1; }
    ciphertext_backup="$backup_dir/secrets.yaml.bak"
    policy_backup="$backup_dir/sops.yaml.bak"
    manifest_backup="$backup_dir/dr-manifest.env.bak"
    _ss_tx_restore_traps() {
        if [[ -n "$caller_return_trap" ]]; then eval "$caller_return_trap"; else trap - RETURN; fi
        if [[ -n "$caller_int_trap" ]]; then eval "$caller_int_trap"; else trap - INT; fi
        if [[ -n "$caller_term_trap" ]]; then eval "$caller_term_trap"; else trap - TERM; fi
    }
    _ss_tx_cleanup() { rm -f "${policy_stage:-}" "${ciphertext_stage:-}" "${manifest_stage:-}"; rm -rf "${backup_dir:-}"; }
    _ss_tx_rollback() {
        [[ "$ciphertext_promoted" == "true" ]] && _ss_restore_or_remove "$ciphertext_existed" "$ciphertext_backup" "$final_file"
        [[ "$policy_promoted" == "true" ]] && _ss_restore_or_remove "$policy_existed" "$policy_backup" "$policy_file"
        [[ "$manifest_promoted" == "true" ]] && _ss_restore_or_remove "$manifest_existed" "$manifest_backup" "$manifest_file"
    }
    _ss_tx_fail() { local code="${1:-1}"; _ss_tx_rollback; _ss_tx_cleanup; _ss_tx_restore_traps; return "$code"; }
    _ss_tx_signal() { local code="$1"; _ss_tx_fail "$code"; return "$code"; }
    trap '_ss_tx_signal 130; return 130' INT
    trap '_ss_tx_signal 143; return 143' TERM

    if [[ -f "$final_file" ]]; then cp "$final_file" "$ciphertext_backup"; ciphertext_existed=true; fi
    if [[ -f "$policy_file" ]]; then cp "$policy_file" "$policy_backup"; policy_existed=true; fi
    if [[ -f "$manifest_file" ]]; then cp "$manifest_file" "$manifest_backup"; manifest_existed=true; fi

    _ss_write_policy_file "$policy_stage" "$desired_csv" || { _ss_tx_fail 1; return 1; }
    _ss_stage_manifest_update "$desired_csv" "$manifest_stage" || { _ss_tx_fail 1; return 1; }

    if [[ "$mode" == "rekey" ]]; then
        cp "$final_file" "$ciphertext_stage" || { _ss_tx_fail 1; return 1; }
    else
        SOPS_AGE_KEY_FILE="$operational_key" sops --config "$policy_stage" --encrypt --output "$ciphertext_stage" "$plaintext_file" || { _ss_tx_fail 1; return 1; }
    fi

    SOPS_AGE_KEY_FILE="$operational_key" sops --config "$policy_stage" updatekeys --yes "$ciphertext_stage" || { _ss_tx_fail 1; return 1; }
    SOPS_AGE_KEY_FILE="$operational_key" sops -d "$ciphertext_stage" >/dev/null || { _ss_tx_fail 1; return 1; }
    _ss_recipients_match "$desired_csv" "$policy_stage" policy || { log_error "Staged policy recipients do not match desired recipient set"; _ss_tx_fail 1; return 1; }
    _ss_recipients_match "$desired_csv" "$ciphertext_stage" cipher || { log_error "Staged ciphertext recipients do not match desired recipient set"; _ss_tx_fail 1; return 1; }

    if ! mv "$ciphertext_stage" "$final_file"; then
        _ss_tx_fail 1
        return 1
    fi
    ciphertext_promoted=true
    if [[ "${SETUP_SECRETS_TEST_TERM_AFTER_CIPHERTEXT_PROMOTION:-}" == "1" ]]; then
        kill -TERM $$
    fi

    if ! mv "$policy_stage" "$policy_file"; then
        _ss_tx_fail 1
        return 1
    fi
    policy_promoted=true

    if [[ -s "$manifest_stage" ]]; then
        if ! mv "$manifest_stage" "$manifest_file"; then
            _ss_tx_fail 1
            return 1
        fi
        manifest_promoted=true
    else
        rm -f "$manifest_stage"
    fi

    if ! SOPS_AGE_KEY_FILE="$operational_key" sops -d "$final_file" >/dev/null; then
        _ss_tx_fail 1
        return 1
    fi

    _ss_tx_cleanup
    _ss_tx_restore_traps
}

_ss_update_manifest_after_validation() {
    local desired_csv="$1" manifest_dir manifest manifest_stage
    manifest="$(_ss_manifest_file)"
    manifest_dir="$(dirname "$manifest")"
    mkdir -p "$manifest_dir" || return 1
    manifest_stage=$(mktemp -p "$manifest_dir" dr-manifest.env.XXXXXXXXXX) || return 1
    if ! _ss_stage_manifest_update "$desired_csv" "$manifest_stage"; then
        rm -f "$manifest_stage"
        return 1
    fi
    if [[ -s "$manifest_stage" ]]; then
        mv "$manifest_stage" "$manifest"
    else
        rm -f "$manifest_stage"
    fi
}

# Bootstrap the Age key, SOPS config, and placeholder secrets file.
# Run setup-secrets.sh configure after editing .env to add real credentials.
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
    local secrets_file="${SECRETS_FILE:-${PROJECT_ROOT}/secrets/secrets.yaml}"
    local canonical_key="/etc/vaultwarden/age-key.txt"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would bootstrap: Age key, SOPS config, placeholder secrets"
        return 0
    fi

    # Create the directory structure.
    mkdir -p "${PROJECT_ROOT}/secrets/keys" || return 1
    chmod 700 "${PROJECT_ROOT}/secrets/keys" || return 1
    install -d -m 700 -o root -g root "/run/vaultwarden-oci/secrets" || return 1

    # Create or validate the repository Age key.
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

    # Verify the key immediately after generation or validation.
    if ! SOPS_AGE_KEY_FILE="$age_key_file" simple_verify_age_key; then
        log_error "Age key verification failed — aborting bootstrap"
        return 1
    fi

    # Install the canonical /etc/vaultwarden/age-key.txt copy.
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
        install -d -m 700 -o root -g root /etc/vaultwarden || return 1
        install -m 600 -o root -g root "$age_key_file" "$canonical_key" || return 1
        chown root:root "$canonical_key" || return 1
        chmod 600 "$canonical_key" || return 1
        log_success "Age key installed: $canonical_key (mode 600, root:root)"
    fi

    # Ensure repo .env keeps SOPS_AGE_KEY_FILE blank.
    # The canonical path (/etc/vaultwarden/age-key.txt) belongs in the
    # installed runtime config at ${PROJECT_STATE_DIR}/config/install.env,
    # which setup-env.sh refresh_state_artifacts writes during environment setup.
    # Repo .env must stay blank so the resolver can pick the correct readable
    # key path depending on caller context.
    local env_file="${PROJECT_ROOT}/.env"
    if [[ -f "$env_file" ]]; then
        local temp_env env_uid env_gid env_mode real_user real_group
        env_uid=$(stat -c '%u' "$env_file" 2>/dev/null || echo "")
        env_gid=$(stat -c '%g' "$env_file" 2>/dev/null || echo "")
        env_mode=$(stat -c '%a' "$env_file" 2>/dev/null || echo "600")
        if [[ -z "$env_uid" || -z "$env_gid" ]]; then
            real_user=$(get_real_user)
            real_group=$(id -gn "$real_user" 2>/dev/null || echo "$real_user")
            env_uid=$(id -u "$real_user")
            env_gid=$(getent group "$real_group" | cut -d: -f3)
            env_mode="600"
        fi
        temp_env=$(mktemp -p "$(dirname "$env_file")" .env.tmp.XXXXXXXXXX) || return 1
        awk '{
            sub(/^SOPS_AGE_KEY_FILE=.*/, "SOPS_AGE_KEY_FILE=");
            print;
        }' "$env_file" > "$temp_env"
        chown "$env_uid:$env_gid" "$temp_env" || { rm -f "$temp_env"; return 1; }
        chmod "$env_mode" "$temp_env" || { rm -f "$temp_env"; return 1; }
        mv "$temp_env" "$env_file" || { rm -f "$temp_env"; return 1; }
        log_success "SOPS_AGE_KEY_FILE cleared in repo .env (owner/mode preserved)"
    fi

    # Resolve the complete desired recipient set before deciding whether the
    # existing ciphertext can be left untouched. A decryptable file alone is
    # not proof that the policy and ciphertext metadata are current.
    local age_public_key desired_recipients
    age_public_key=$(get_age_public_key "$age_key_file") || return 1
    if [[ -z "$age_public_key" ]] || ! [[ "$age_public_key" =~ ^age1[a-z0-9]{58}$ ]]; then
        log_error "Age public key has unexpected format: '${age_public_key}'"
        return 1
    fi
    desired_recipients="$(_ss_desired_recipients_csv "$age_public_key")" || return 1

    _repair_encrypted_secrets_ownership() {
        local secrets_file="$1"
        local secrets_dir

        secrets_dir="$(dirname "$secrets_file")"

        chown root:root "$secrets_dir" || return 1
        chmod 700 "$secrets_dir" || return 1

        if [[ -f "$secrets_file" ]]; then
            chown root:root "$secrets_file" || return 1
            chmod 600 "$secrets_file" || return 1
        fi
    }
    
    # Create or rekey the placeholder encrypted secrets structure.
    if [[ -f "$secrets_file" ]] && [[ "$FORCE" != "true" ]]; then
        if ! SOPS_AGE_KEY_FILE="$age_key_file" sops -d "$secrets_file" >/dev/null 2>&1; then
            log_error "secrets.yaml unreadable with current key. Use --force to overwrite."
            return 1
        fi

        # Repair ownership even when no ciphertext changes are needed. This
        # handles hosts that previously ended up with root-owned persistent
        # encrypted secrets before returning through the idempotent fast path.
        _repair_encrypted_secrets_ownership "$secrets_file" || return 1

        if [[ -f "$sops_config" ]] \
            && _ss_recipients_match "$desired_recipients" "$sops_config" policy \
            && _ss_recipients_match "$desired_recipients" "$secrets_file" cipher; then
            log_info "Placeholder secrets.yaml recipient state already current (skipping)"
            log_success "Bootstrap complete — run 'sudo ./setup.sh secrets' to configure credentials"
            return 0
        fi

        log_info "Existing secrets.yaml decrypts but recipient state is not current; staging rekey"
        if ! _ss_commit_ciphertext_transaction "" "$age_key_file" "$age_public_key" "$secrets_file" "$sops_config" rekey "$desired_recipients"; then
            log_error "Failed to rekey existing secrets.yaml"
            return 1
        fi
        _repair_encrypted_secrets_ownership "$secrets_file" || return 1
        log_success "Existing secrets.yaml recipient state updated"
        return 0
    fi
    
    local tmp_secrets=""
    tmp_secrets="$(_ss_make_plaintext_temp)" || return 1
    # shellcheck disable=SC2064  # intentional — $tmp_secrets must expand NOW
    trap "rm -f \"${tmp_secrets}\"" RETURN
    # shellcheck disable=SC2064  # intentional — $tmp_secrets must expand NOW
    trap "rm -f \"${tmp_secrets}\"; exit 130" INT
    # shellcheck disable=SC2064  # intentional — $tmp_secrets must expand NOW
    trap "rm -f \"${tmp_secrets}\"; exit 143" TERM
    # Build placeholder YAML body from secrets-schema.yaml so that every key
    # defined in the schema is bootstrapped automatically — no lines here need
    # to change when a key is added or renamed.
    {
        local _bkeys _bkey _bph
        _bkeys=$(schema_keys) || {
            log_error "_cmd_bootstrap: failed to read keys from secrets-schema.yaml"
            return 1
        }
        while IFS= read -r _bkey; do
            [[ -z "$_bkey" ]] && continue
            _bph=$(schema_placeholder_for_key "$_bkey") || _bph="PLACEHOLDER_NOT_CONFIGURED"
            printf '%s: %s\n' "$_bkey" "$_bph"
        done <<< "$_bkeys"
    } > "$tmp_secrets"
    chmod 600 "$tmp_secrets"
    if ! _ss_commit_ciphertext_transaction "$tmp_secrets" "$age_key_file" "$age_public_key" "$secrets_file" "$sops_config" plaintext "$desired_recipients"; then
        rm -f "$tmp_secrets"
        return 1
    fi
    rm -f "$tmp_secrets"
    _repair_encrypted_secrets_ownership "$secrets_file" || return 1

    log_success "Placeholder secrets.yaml created and encrypted"
    log_success "Bootstrap complete — run 'sudo ./setup.sh secrets' to configure credentials"
    return 0
}


_valid_age_recipient() {
    [[ "${1:-}" =~ ^age1[a-z0-9]{58}$ ]]
}

_policy_recipients() {
    local file="$1" age_value=""
    [[ -f "$file" ]] || return 0
    if command -v yq >/dev/null 2>&1; then
        age_value="$(yq -r '.creation_rules[0].age // ""' "$file" 2>/dev/null || true)"
    else
        age_value="$(awk -F: '/^[[:space:]]*age:/ { gsub(/[ "'"'"']/, "", $2); print $2; exit }' "$file")"
    fi
    tr ',' '\n' <<< "$age_value" | sed '/^$/d'
}

_resolve_offline_recipient() {
    local operational="$1" manifest="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/config/dr-manifest.env"
    local candidate="" unknown=() recipient

    if [[ -n "${OFFLINE_AGE_RECIPIENT:-}" ]]; then
        _valid_age_recipient "$OFFLINE_AGE_RECIPIENT" || { log_error "Invalid OFFLINE_AGE_RECIPIENT format"; return 1; }
        printf '%s' "$OFFLINE_AGE_RECIPIENT"
        return 0
    fi

    if [[ -f "$manifest" ]]; then
        candidate="$(_read_env_value OFFLINE_AGE_RECIPIENT "$manifest")"
        if [[ -n "$candidate" ]]; then
            _valid_age_recipient "$candidate" || { log_error "Invalid OFFLINE_AGE_RECIPIENT in $manifest"; return 1; }
            printf '%s' "$candidate"
            return 0
        fi
    fi

    while IFS= read -r recipient; do
        recipient="${recipient// /}"
        [[ -z "$recipient" || "$recipient" == "$operational" ]] && continue
        _valid_age_recipient "$recipient" && unknown+=("$recipient")
    done < <(_policy_recipients "$PROJECT_ROOT/.sops.yaml")

    if (( ${#unknown[@]} == 1 )); then
        printf '%s' "${unknown[0]}"
        return 0
    fi
    if (( ${#unknown[@]} > 1 )); then
        log_error "Multiple unknown recipients in .sops.yaml — review manually before continuing."
        return 1
    fi

    if [[ -t 0 ]]; then
        _ss_explain_offline_recovery_recipient
        while true; do
            read -r -p "Enter offline recovery Age public key (press Enter to skip): " candidate
            if [[ -z "$candidate" ]]; then
                _ss_warn_offline_recovery_recipient_skipped
                break
            fi
            if _valid_age_recipient "$candidate"; then
                printf '%s' "$candidate"
                break
            else
                log_warn "Invalid format — expected: age1<58 lowercase alphanumeric chars>"
                log_warn "Example:  age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgp..."
                log_warn "Press Enter with no input to skip."
                candidate=""
            fi
        done
    fi
}

_update_dr_manifest_offline_recipient() {
    local recipient="$1"
    local manifest_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/config"
    local manifest="$manifest_dir/dr-manifest.env"
    mkdir -p "$manifest_dir" || return 1
    [[ -f "$manifest" ]] || : > "$manifest"
    _set_env_var OFFLINE_AGE_RECIPIENT "$recipient" "$manifest"
    _set_env_var MANIFEST_UPDATED_AT "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$manifest"
}

_write_sops_config() {
    local age_pub="$1" dest="$2" offline_recipient="${3:-}"
    local recipients="$age_pub"
    local tmp

    if [[ -z "$offline_recipient" ]]; then
        offline_recipient="$(_resolve_offline_recipient "$age_pub")" || return 1
    fi
    if [[ -n "$offline_recipient" && "$offline_recipient" != "$age_pub" ]]; then
        recipients="${age_pub},${offline_recipient}"
    fi

    tmp=$(mktemp -p "$(dirname "$dest")" .sops.yaml.XXXXXXXXXX) || return 1
    {
        printf 'creation_rules:\n'
        printf "  - path_regex: '.*\\.yaml$'\n"
        if [[ -n "$offline_recipient" ]]; then
            printf '    # Offline recovery key — USB only, never stored on server\n'
        fi
        printf '    age: "%s"\n' "$recipients"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 644 "$tmp"
    local real_user; real_user=$(get_real_user)
    chown "${real_user}:$(id -g -n "$real_user")" "$tmp" 2>/dev/null || true
    mv "$tmp" "$dest"
    [[ -n "$offline_recipient" ]] && _update_dr_manifest_offline_recipient "$offline_recipient"
    log_success "SOPS config written: $dest"
}


main() {
    local subcmd="${1:-}"
    case "$subcmd:${2:-}" in
        configure:--help|configure:-h)
            shift
            _cmd_configure "$@"
            exit $?
            ;;
        bootstrap:--help|bootstrap:-h)
            shift
            _cmd_bootstrap "$@"
            exit $?
            ;;
        breakglass:--help|breakglass:-h|breakglass:help)
            shift
            _cmd_breakglass "$@"
            exit $?
            ;;
        configure:--version|configure:-V|bootstrap:--version|bootstrap:-V|breakglass:--version|breakglass:-V)
            print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"
            exit 0
            ;;
    esac

    case "$subcmd" in
        help|--help|-h|--version|-V) ;;
        rotate)              _cmd_user_secret_stub rotate; exit $? ;;
        export-recovery-kit) _cmd_user_secret_stub export-recovery-kit; exit $? ;;
        *) (( EUID == 0 )) || { log_error "Must run as root."; exit 1; } ;;
    esac

    shift || true

    case "$subcmd" in
        help|--help|-h)      show_help; exit 0 ;;
        --version|-V)        print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"; exit 0 ;;
        "")  log_error "Subcommand required. Use --help for usage."; show_help; exit 1 ;;
    esac

    load_project_environment || exit 1
    _setup_secrets_acquire_guard "$subcmd" "$@" || exit $?

    case "$subcmd" in
        bootstrap)           _cmd_bootstrap "$@" ;;
        configure)           _cmd_configure "$@" ;;
        breakglass)          _cmd_breakglass "$@" ;;
        *)   log_error "Unknown subcommand: ${subcmd}"; show_help; exit 1 ;;
    esac
}

if [[ "${SETUP_SECRETS_TRANSACTION_TESTING:-}" == "source-only" ]]; then
    # shellcheck disable=SC2317 # valid when this file is sourced instead of executed
    return 0 2>/dev/null || exit 0
fi

main "$@"
