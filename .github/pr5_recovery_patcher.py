from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


path = Path("lib/secrets.sh")
text = path.read_text()

text = replace_once(
    text,
    '''_schema_required_runtime_keys() {
    local _required_keys
    schema_required_keys || return 1

    if [[ "${CLOUDFLARE_PROXY_ENABLED:-false}" == "true" ]]; then
        local _cf_keys
        if _cf_keys=$(schema_keys_for_conditional_group "cloudflare_proxy" 2>/dev/null); then
            printf '%s\\n' "$_cf_keys"
        else
            printf '%s\\n' "cloudflare_zone_id" "cf_account_id" "cf_worker_bouncer_token"
            log_warn "validate_required_secrets: schema conditional-group lookup unavailable — using static Cloudflare fallback"
        fi
    fi
}
''',
    '''_schema_required_runtime_keys() {
    schema_required_keys || return 1

    if [[ "${CLOUDFLARE_PROXY_ENABLED:-false}" == "true" ]]; then
        local _cf_keys
        if ! _cf_keys=$(schema_keys_for_conditional_group "cloudflare_proxy" 2>/dev/null); then
            log_error "validate_required_secrets: failed to read Cloudflare conditional keys from secrets-schema.yaml"
            return 1
        fi
        printf '%s\\n' "$_cf_keys"
    fi
}
''',
    "authoritative Cloudflare schema lookup",
)

text = replace_once(
    text,
    '''_grk_sops_extract() {
    local _key="$1"
    local _secrets_file="$2"
    local _val
    # Suppress xtrace to prevent plaintext secret appearing in debug logs.
    { set +x; } 2>/dev/null
    _val=$(sops -d --extract "[\\"${_key}\\"]" "$_secrets_file" 2>/dev/null) \\
        && printf '%s' "$_val" \\
        || printf '%s' "Not Set"
    unset _val
}
''',
    '''_grk_sops_extract() {
    local _key="$1" _secrets_file="$2"
    local _val _err_file _rc=0

    _err_file=$(mktemp) || {
        log_error "generate_recovery_kit: failed to allocate SOPS error capture"
        return 1
    }
    # Suppress xtrace to prevent plaintext secret appearing in debug logs.
    { set +x; } 2>/dev/null
    _val=$(sops -d --extract "[\\"${_key}\\"]" "$_secrets_file" 2>"$_err_file") || _rc=$?
    if (( _rc != 0 )); then
        log_error "generate_recovery_kit: failed to extract schema key '${_key}' (sops exit ${_rc})"
        if [[ -s "$_err_file" ]]; then
            log_debug "generate_recovery_kit: sops error for '${_key}': $(cat "$_err_file")"
        fi
        rm -f -- "$_err_file"
        unset _val
        return 1
    fi
    rm -f -- "$_err_file"
    printf '%s' "$_val"
    unset _val
}

_validate_recovery_kit_document() {
    local recovery_file="$1" expected_labels="$2"
    local label count

    [[ -s "$recovery_file" ]] || {
        log_error "Recovery-kit validation failed: staged document is empty"
        return 1
    }
    [[ "$(grep -Fxc 'END OF RECOVERY KIT' "$recovery_file" 2>/dev/null || true)" == "1" ]] || {
        log_error "Recovery-kit validation failed: completion marker is missing or duplicated"
        return 1
    }
    [[ "$(grep -c '^AGE-SECRET-KEY-1' "$recovery_file" 2>/dev/null || true)" == "1" ]] || {
        log_error "Recovery-kit validation failed: expected exactly one Age private identity"
        return 1
    }

    while IFS= read -r label; do
        [[ -n "$label" ]] || continue
        count=$(grep -Fxc "[$label]" "$recovery_file" 2>/dev/null || true)
        if [[ "$count" != "1" ]]; then
            log_error "Recovery-kit validation failed: field '$label' rendered ${count} times (expected once)"
            return 1
        fi
    done <<< "$expected_labels"
    return 0
}
''',
    "strict SOPS extraction and staged-document validator",
)

text = replace_once(
    text,
    '''    local secrets_file="${SECRETS_FILE}"
    local env_file="${PROJECT_ROOT:-.}/.env"

    if [[ ! -f "$age_key" ]]; then
        log_error "Age key not found: $age_key"
        return 1
    fi
''',
    '''    local secrets_file="${SECRETS_FILE}"
    local env_file="${PROJECT_ROOT:-.}/.env"
    local _schema_key_list

    if ! schema_validate; then
        log_error "generate_recovery_kit: secrets-schema.yaml validation failed"
        return 1
    fi
    if ! _schema_key_list=$(schema_keys); then
        log_error "generate_recovery_kit: failed to enumerate secrets-schema.yaml"
        return 1
    fi
    [[ -n "$_schema_key_list" ]] || {
        log_error "generate_recovery_kit: secrets-schema.yaml contains no managed secrets"
        return 1
    }
    if [[ ! -f "$secrets_file" ]]; then
        log_error "generate_recovery_kit: secrets file not found: $secrets_file"
        return 1
    fi
    if [[ ! -f "$age_key" ]]; then
        log_error "Age key not found: $age_key"
        return 1
    fi
    if ! check_age_key "$age_key"; then
        log_error "generate_recovery_kit: Age private identity validation failed"
        return 1
    fi
''',
    "schema and Age preflight",
)

text = replace_once(
    text,
    '''    # Suppress xtrace before reading the private key to prevent it appearing in debug logs.
    { set +x; } 2>/dev/null
    priv_key=$(cat "$age_key")
''',
    '''    # Suppress xtrace before reading the private key to prevent it appearing in debug logs.
    { set +x; } 2>/dev/null
    if ! priv_key=$(cat "$age_key"); then
        log_error "generate_recovery_kit: failed to read Age private identity"
        return 1
    fi
''',
    "private Age identity read",
)

text = replace_once(
    text,
    '''    declare -A _grk_values=()

    if [[ -f "$secrets_file" ]]; then
        if ! ensure_sops_env; then return 1; fi
        trap 'cleanup_secrets_environment' RETURN

        local _schema_key_list
        if ! _schema_key_list=$(schema_keys 2>/dev/null); then
            log_warn "generate_recovery_kit: schema_keys unavailable — recovery kit may be incomplete"
            # Degrade gracefully: continue with an empty map rather than aborting.
            _schema_key_list=""
        fi

        while IFS= read -r _rk_key; do
            [[ -z "$_rk_key" ]] && continue
            _grk_values["$_rk_key"]=$(_grk_sops_extract "$_rk_key" "$secrets_file")
        done <<< "$_schema_key_list"
    else
        log_warn "secrets.yaml not found"
    fi
''',
    '''    declare -A _grk_values=() _grk_labels=() _grk_seen_labels=()
    local expected_labels=""

    if ! ensure_sops_env; then return 1; fi
    trap 'cleanup_secrets_environment' RETURN

    local _rk_key _rk_value _rk_required _rk_placeholder _rk_label
    while IFS= read -r _rk_key; do
        [[ -z "$_rk_key" ]] && continue

        if ! _rk_label=$(schema_field "$_rk_key" label); then
            log_error "generate_recovery_kit: failed to read label for schema key '$_rk_key'"
            unset priv_key
            return 1
        fi
        if [[ -z "$_rk_label" || "$_rk_label" == *$'\\n'* || "$_rk_label" == *$'\\r'* ]]; then
            log_error "generate_recovery_kit: invalid recovery label for schema key '$_rk_key'"
            unset priv_key
            return 1
        fi
        if [[ -n "${_grk_seen_labels[$_rk_label]+set}" ]]; then
            log_error "generate_recovery_kit: duplicate recovery label in schema: $_rk_label"
            unset priv_key
            return 1
        fi
        _grk_seen_labels["$_rk_label"]=1

        if ! _rk_required=$(schema_field "$_rk_key" required); then
            log_error "generate_recovery_kit: failed to read required flag for schema key '$_rk_key'"
            unset priv_key
            return 1
        fi
        if ! _rk_placeholder=$(schema_field "$_rk_key" placeholder); then
            log_error "generate_recovery_kit: failed to read placeholder for schema key '$_rk_key'"
            unset priv_key
            return 1
        fi
        case "$_rk_required" in
            true|false) ;;
            *)
                log_error "generate_recovery_kit: invalid required flag for schema key '$_rk_key': $_rk_required"
                unset priv_key
                return 1
                ;;
        esac

        if ! _rk_value=$(_grk_sops_extract "$_rk_key" "$secrets_file"); then
            unset priv_key
            return 1
        fi
        if _secret_value_is_inactive "$_rk_value" "$_rk_placeholder"; then
            if [[ "$_rk_required" == "true" ]]; then
                log_error "generate_recovery_kit: required secret '$_rk_key' is unset or placeholder"
                unset _rk_value priv_key
                return 1
            fi
            _rk_value="<not set: optional>"
        fi

        _grk_labels["$_rk_key"]="$_rk_label"
        _grk_values["$_rk_key"]="$_rk_value"
        [[ -z "$expected_labels" ]] || expected_labels+=$'\\n'
        expected_labels+="$_rk_label"
        unset _rk_value
    done <<< "$_schema_key_list"

    cleanup_secrets_environment
''',
    "single schema inventory and strict secret collection",
)

text = replace_once(
    text,
    '''    # Emit each secret with its human-readable label from the schema.
    # New keys appear automatically without editing this function.
    local _schema_keys_for_kit
    _schema_keys_for_kit=$(schema_keys 2>/dev/null) || _schema_keys_for_kit=""

    while IFS= read -r _kit_key; do
        [[ -z "$_kit_key" ]] && continue
        local _kit_label
        _kit_label=$(schema_field_safe "$_kit_key" "label") || _kit_label="$_kit_key"
        [[ -z "$_kit_label" ]] && _kit_label="$_kit_key"

        local _kit_value="${_grk_values[$_kit_key]:-Not Set}"

        printf '[%s]\\n' "$_kit_label"       >> "$output_file"
        printf '%s\\n\\n' "$_kit_value"       >> "$output_file"
    done <<< "$_schema_keys_for_kit"

    unset _grk_values
''',
    '''    # Render the same schema inventory collected above. No fallback or second
    # enumeration is permitted once generation begins.
    local _kit_key
    while IFS= read -r _kit_key; do
        [[ -z "$_kit_key" ]] && continue
        printf '[%s]\\n' "${_grk_labels[$_kit_key]}" >> "$output_file"
        printf '%s\\n\\n' "${_grk_values[$_kit_key]}" >> "$output_file"
    done <<< "$_schema_key_list"

    unset _grk_values _grk_labels _grk_seen_labels
''',
    "single-inventory recovery rendering",
)

text = replace_once(
    text,
    '''    # Unset plaintext Age private key from memory immediately after
    # the heredoc that wrote it to the output file.
    unset priv_key

    chmod 600 "$output_file"
}
''',
    '''    # Unset plaintext Age private key from memory immediately after
    # the heredoc that wrote it to the output file.
    unset priv_key

    if ! _validate_recovery_kit_document "$output_file" "$expected_labels"; then
        _remove_sensitive_file "$output_file" 2>/dev/null || rm -f -- "$output_file"
        return 1
    fi
    chmod 600 "$output_file"
}
''',
    "pre-publication document validation",
)

start = text.index("_validate_no_placeholders() {")
end_marker = "\n# ---------------------------------------------------------------------------\n# _warn_if_stack_unavailable"
end = text.index(end_marker, start)
text = text[:start] + '''_validate_no_placeholders() {
    local plain_yaml="$1"
    if ! validate_plaintext_secrets_schema_contract "$plain_yaml"; then
        log_error "Recovery-kit secret preflight failed the authoritative schema contract."
        log_error "Configure required values before exporting; optional unset values are allowed and rendered explicitly."
        return 1
    fi
    return 0
}
''' + text[end:]

path.write_text(text)


test_path = Path("tests/suites/security/case-secrets.bash")
tests = test_path.read_text()
tests = replace_once(
    tests,
    'case "$MODE" in core|sensitive-cleanup|all) ;;',
    'case "$MODE" in core|sensitive-cleanup|recovery-kit|all) ;;',
    "recovery-kit test mode",
)

marker = '\ncase "$MODE" in\n    core)\n'
if tests.count(marker) != 1:
    raise SystemExit("test dispatch: expected exactly one marker")

test_func = r'''
check_recovery_kit_schema_truth() {
  local ROOT="$VW_TEST_REPO_ROOT"
  local TMP
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' RETURN

  recovery_case() (
    set -euo pipefail
    local scenario="$1"
    local work="$TMP/$scenario"
    mkdir -p "$work/recovery"
    export PROJECT_ROOT="$ROOT"
    export SECRETS_FILE="$work/secrets.yaml"
    export RECOVERY_KIT_DIR="$work/recovery"
    export RECOVERY_KIT_REPO_URL="https://example.invalid/VaultWarden-OCI.git"
    printf 'fixture\n' >"$SECRETS_FILE"
    printf 'AGE-SECRET-KEY-1TESTFIXTURE00000000000000000000000000000000000000000000000\n' >"$work/age-key.txt"
    chmod 0600 "$work/age-key.txt"

    # shellcheck source=../../../lib/secrets.sh
    source "$ROOT/lib/secrets.sh"
    log_error() { :; }
    log_warn() { :; }
    log_info() { :; }
    log_debug() { :; }
    log_success() { :; }
    resolve_age_key_path() { printf '%s\n' "$work/age-key.txt"; }
    check_age_key() { [[ "$scenario" != "invalid-age" ]]; }
    _derive_age_public_key() { printf '%s\n' 'age1testfixture000000000000000000000000000000000000000000000000000'; }
    ensure_sops_env() { return 0; }
    cleanup_secrets_environment() { return 0; }
    schema_validate() {
      case "$scenario" in missing-schema|broken-tooling) return 1 ;; esac
      return 0
    }
    schema_keys() { printf '%s\n' required_key optional_key; }
    schema_field() {
      local key="$1" field="$2"
      case "$field:$key" in
        label:required_key) printf '%s' 'Required Test Secret' ;;
        label:optional_key) printf '%s' 'Optional Test Secret' ;;
        required:required_key) printf '%s' true ;;
        required:optional_key) printf '%s' false ;;
        placeholder:required_key) printf '%s' CHANGE_ME_REQUIRED ;;
        placeholder:optional_key) printf '%s' CHANGE_ME_OPTIONAL ;;
        *) return 1 ;;
      esac
    }
    sops() {
      local args="$*"
      if [[ "$args" == *'required_key'* ]]; then
        printf '%s' 'required-secret'
        return 0
      fi
      if [[ "$args" == *'optional_key'* ]]; then
        [[ "$scenario" != "sops-failure" ]] || return 42
        if [[ "$scenario" == "optional-unset" ]]; then
          printf ''
        else
          printf '%s' 'optional-secret'
        fi
        return 0
      fi
      return 2
    }

    local target="$work/recovery/kit.txt"
    case "$scenario" in
      missing-schema|broken-tooling|sops-failure|invalid-age)
        ! _ork_generate_and_secure "$target" || exit 1
        [[ ! -e "$target" && ! -L "$target" ]] || exit 1
        ;;
      optional-unset)
        _ork_generate_and_secure "$target"
        grep -Fqx '<not set: optional>' "$target"
        [[ "$(grep -Fxc '[Required Test Secret]' "$target")" == 1 ]]
        [[ "$(grep -Fxc '[Optional Test Secret]' "$target")" == 1 ]]
        ;;
      valid)
        _ork_generate_and_secure "$target"
        [[ "$(stat -c '%a' "$target")" == 600 ]]
        [[ "$(grep -Fxc '[Required Test Secret]' "$target")" == 1 ]]
        [[ "$(grep -Fxc '[Optional Test Secret]' "$target")" == 1 ]]
        ;;
      cleanup-failure)
        _schedule_recovery_cleanup() { return 1; }
        _offer_email_recovery_kit() { return 99; }
        ! offer_recovery_kit_export true || exit 1
        ! find "$work/recovery" -maxdepth 1 -name 'vaultwarden-recovery-kit-*.txt' -print -quit | grep -q .
        ;;
      *) exit 2 ;;
    esac
  )

  recovery_case missing-schema || fail 'missing schema must abort before publication'
  recovery_case broken-tooling || fail 'broken schema tooling must abort before publication'
  recovery_case sops-failure || fail 'SOPS extraction failure must abort before publication'
  recovery_case invalid-age || fail 'invalid Age private identity must abort before publication'
  recovery_case optional-unset || fail 'optional unset value must render explicitly'
  recovery_case valid || fail 'valid complete recovery kit must publish exactly once per field'
  recovery_case cleanup-failure || fail 'cleanup scheduler failure must remove newly published plaintext'

  (
    set -euo pipefail
    export PROJECT_ROOT="$ROOT" SECRETS_FILE="$TMP/secrets.yaml"
    printf 'fixture\n' >"$SECRETS_FILE"
    source "$ROOT/lib/secrets.sh"
    log_error() { :; }
    schema_required_keys() { printf '%s\n' required_key; }
    schema_keys_for_conditional_group() { return 1; }
    CLOUDFLARE_PROXY_ENABLED=true
    ! _schema_required_runtime_keys
  ) || fail 'authoritative schema conditional accessor failure must be fatal'

  (
    set -euo pipefail
    export PROJECT_ROOT="$ROOT" SECRETS_FILE="$TMP/secrets.yaml"
    source "$ROOT/lib/secrets.sh"
    log_error() { :; }
    local duplicate="$TMP/duplicate.txt" missing="$TMP/missing.txt"
    cat >"$duplicate" <<'EOF'
AGE-SECRET-KEY-1TEST
[Required Test Secret]
[Required Test Secret]
[Optional Test Secret]
END OF RECOVERY KIT
EOF
    cat >"$missing" <<'EOF'
AGE-SECRET-KEY-1TEST
[Required Test Secret]
END OF RECOVERY KIT
EOF
    ! _validate_recovery_kit_document "$duplicate" $'Required Test Secret\nOptional Test Secret'
    ! _validate_recovery_kit_document "$missing" $'Required Test Secret\nOptional Test Secret'
  ) || fail 'duplicate/missing rendered recovery fields must fail validation'

  pass 'recovery-kit schema truth and fail-closed publication'
}
'''

tests = tests.replace(marker, test_func + marker, 1)
tests = replace_once(
    tests,
    '    core)\n        check_secrets_cli_help',
    '    core)\n        check_recovery_kit_schema_truth\n        check_secrets_cli_help',
    "core recovery test dispatch",
)
tests = replace_once(
    tests,
    '    sensitive-cleanup)\n        check_sensitive_cleanup_contracts',
    '    recovery-kit)\n        check_recovery_kit_schema_truth\n        ;;\n    sensitive-cleanup)\n        check_sensitive_cleanup_contracts',
    "focused recovery test dispatch",
)
tests = replace_once(
    tests,
    '    all)\n        check_secrets_cli_help',
    '    all)\n        check_recovery_kit_schema_truth\n        check_secrets_cli_help',
    "all recovery test dispatch",
)
test_path.write_text(tests)
