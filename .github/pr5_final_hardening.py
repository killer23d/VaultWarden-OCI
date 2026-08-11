from pathlib import Path

p = Path('lib/secrets.sh')
text = p.read_text()

old = '''_grk_sops_extract() {
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
'''
new = '''_grk_sops_extract() {
    local _key="$1" _secrets_file="$2"
    local _val _rc=0

    # Suppress xtrace and SOPS stderr so recovery diagnostics cannot expose
    # plaintext-adjacent context. The key name and exit status are sufficient.
    { set +x; } 2>/dev/null
    _val=$(sops -d --extract "[\\"${_key}\\"]" "$_secrets_file" 2>/dev/null) || _rc=$?
    if (( _rc != 0 )); then
        log_error "generate_recovery_kit: failed to extract schema key '${_key}' (sops exit ${_rc})"
        unset _val
        return 1
    fi
    printf '%s' "$_val"
    unset _val
}
'''
if text.count(old) != 1:
    raise SystemExit('strict SOPS block mismatch')
text = text.replace(old, new, 1)

old = '''generate_recovery_kit() {
    local output_file="$1"
    local age_key
    age_key=$(resolve_age_key_path) || return 1
    local secrets_file="${SECRETS_FILE}"
    local env_file="${PROJECT_ROOT:-.}/.env"
    local _schema_key_list

    if ! schema_validate; then
'''
new = '''generate_recovery_kit() {
    local output_file="$1"
    local age_key
    local secrets_file="${SECRETS_FILE}"
    local env_file="${PROJECT_ROOT:-.}/.env"
    local _schema_key_list

    if ! schema_validate; then
'''
if text.count(old) != 1:
    raise SystemExit('generation preflight header mismatch')
text = text.replace(old, new, 1)

old = '''    if [[ ! -f "$secrets_file" ]]; then
        log_error "generate_recovery_kit: secrets file not found: $secrets_file"
        return 1
    fi
    if [[ ! -f "$age_key" ]]; then
'''
new = '''    if [[ ! -f "$secrets_file" ]]; then
        log_error "generate_recovery_kit: secrets file not found: $secrets_file"
        return 1
    fi
    age_key=$(resolve_age_key_path) || return 1
    if [[ ! -f "$age_key" ]]; then
'''
if text.count(old) != 1:
    raise SystemExit('Age resolution insertion point mismatch')
text = text.replace(old, new, 1)
p.write_text(text)

p = Path('utilities/secrets-export-recovery-kit.sh')
text = p.read_text()
old = '''    This is the canonical standalone entry point for recovery kit export.
    setup-secrets.sh delegates its post-setup export prompt here.
'''
new = '''    This is the canonical standalone entry point for manual recovery kit export.
    setup-secrets.sh uses the same lib/secrets.sh publication path after setup.
'''
if text.count(old) != 1:
    raise SystemExit('standalone ownership help mismatch')
p.write_text(text.replace(old, new, 1))
