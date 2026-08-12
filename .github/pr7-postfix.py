from pathlib import Path


def replace_function(path, name, body):
    p = Path(path)
    lines = p.read_text().splitlines(True)
    start = next((i for i, line in enumerate(lines) if line.startswith(name + '() {')), None)
    if start is None:
        raise SystemExit(f'{path}: {name} not found')
    end = next((i for i in range(start + 1, len(lines)) if lines[i].rstrip('\n') == '}'), None)
    if end is None:
        raise SystemExit(f'{path}: {name} end not found')
    lines[start:end + 1] = [body.rstrip() + '\n']
    p.write_text(''.join(lines))


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    if text.count(old) != 1:
        raise SystemExit(f'{path}: expected one match, got {text.count(old)}')
    p.write_text(text.replace(old, new, 1))


replace_function('lib/crypto.sh', 'encrypt_sops_file', r'''encrypt_sops_file() {
    local file="$1" age_key_file="${2:-}" file_dir file_base tmp_file old_umask
    [[ -f "$file" ]] || { log_error "encrypt_sops_file: file not found: $file"; return 1; }
    if [[ -z "$age_key_file" ]]; then
        age_key_file="$(resolve_age_key_path)" || return 1
    fi
    [[ -f "$age_key_file" ]] || { log_error "encrypt_sops_file: Age key not found: $age_key_file"; return 1; }

    file_dir="$(dirname -- "$file")"
    file_base="$(basename -- "$file")"
    old_umask="$(umask)"; umask 077
    tmp_file="$(mktemp "${file_dir}/.${file_base}.encrypt.XXXXXXXXXX")" || { umask "$old_umask"; return 1; }
    umask "$old_umask"
    chmod 0600 "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }
    cp -- "$file" "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }

    if ! SOPS_AGE_KEY_FILE="$age_key_file" sops --encrypt --in-place "$tmp_file"; then
        log_error "encrypt_sops_file: SOPS encryption failed"
        rm -f -- "$tmp_file"
        return 1
    fi
    if ! SOPS_AGE_KEY_FILE="$age_key_file" sops --decrypt "$tmp_file" >/dev/null 2>&1; then
        log_error "encrypt_sops_file: encrypted staging file failed round-trip validation"
        rm -f -- "$tmp_file"
        return 1
    fi
    mv -- "$tmp_file" "$file" || { rm -f -- "$tmp_file"; return 1; }
}''')

crypto = Path('lib/crypto.sh')
text = crypto.read_text()
anchor = '\nremove_sensitive_workspace() {'
idx = text.find(anchor)
if idx < 0:
    raise SystemExit('lib/crypto.sh: workspace cleanup anchor missing')
lines = text.splitlines(True)
start = next(i for i, line in enumerate(lines) if line.startswith('remove_sensitive_workspace() {'))
end = next(i for i in range(start + 1, len(lines)) if lines[i].rstrip('\n') == '}')
promote = r'''

promote_sops_ciphertext() {
    local staged="$1" destination="$2" age_key_file="${3:-}" dest_dir dest_base rollback old_umask
    [[ -f "$staged" && -f "$destination" ]] || {
        log_error "promote_sops_ciphertext: staged and existing destination files are required"
        return 1
    }
    if [[ -z "$age_key_file" ]]; then
        age_key_file="$(resolve_age_key_path)" || return 1
    fi
    SOPS_AGE_KEY_FILE="$age_key_file" sops --decrypt "$staged" >/dev/null 2>&1 || {
        log_error "promote_sops_ciphertext: staged ciphertext is not decryptable"
        return 1
    }

    dest_dir="$(dirname -- "$destination")"
    dest_base="$(basename -- "$destination")"
    old_umask="$(umask)"; umask 077
    rollback="$(mktemp "${dest_dir}/.${dest_base}.rollback.XXXXXXXXXX")" || { umask "$old_umask"; return 1; }
    umask "$old_umask"
    if ! cp -a -- "$destination" "$rollback"; then
        rm -f -- "$rollback"
        log_error "promote_sops_ciphertext: rollback copy failed; ciphertext was not replaced"
        return 1
    fi

    if ! mv -- "$staged" "$destination"; then
        rm -f -- "$rollback"
        log_error "promote_sops_ciphertext: atomic ciphertext promotion failed"
        return 1
    fi
    if ! SOPS_AGE_KEY_FILE="$age_key_file" sops --decrypt "$destination" >/dev/null 2>&1; then
        log_error "promote_sops_ciphertext: promoted ciphertext failed validation; restoring previous ciphertext"
        if mv -f -- "$rollback" "$destination"; then
            return 1
        fi
        log_error "promote_sops_ciphertext: CRITICAL: rollback restore failed; previous ciphertext remains at $rollback"
        return 1
    fi
    rm -f -- "$rollback" || {
        log_warn "promote_sops_ciphertext: valid ciphertext promoted, but rollback copy remains at $rollback"
        return 1
    }
}'''
lines[end + 1:end + 1] = [promote + '\n']
crypto.write_text(''.join(lines))

replace_once('utilities/secrets-edit.sh', '''    if ! mv "$encrypted_temp" "$SECRETS_FILE"; then
        log_error "Atomic mv failed — encrypted output left at: $encrypted_temp"
        return 1
    fi
''', '''    if ! promote_sops_ciphertext "$encrypted_temp" "$SECRETS_FILE" "$_age_key_path"; then
        log_error "Failed to promote encrypted secrets; previous ciphertext was preserved or restored"
        return 1
    fi
''')
replace_once('utilities/secrets-rotate.sh', '''    if ! mv "$temp_enc" "$SECRETS_FILE"; then
        log_error "Atomic mv failed — encrypted output in: $temp_enc"
        return 1
    fi
''', '''    if ! promote_sops_ciphertext "$temp_enc" "$SECRETS_FILE" "$_age_key_path"; then
        log_error "Failed to promote rotated secrets; previous ciphertext was preserved or restored"
        return 1
    fi
''')

# Keep plaintext entirely inside the verified volatile workspace. The same-directory
# disk staging files are populated only after the volatile file has been encrypted
# and round-trip validated.
replace_once('utilities/secrets-edit.sh', '    cp "$temp_file" "$encrypted_temp"\n', '')
replace_once('utilities/secrets-edit.sh', '''    if ! encrypt_sops_file "$encrypted_temp" "$_age_key_path"; then
        log_error "Failed to encrypt secrets"
        rm -f "$encrypted_temp"
        return 1
    fi
''', '''    if ! encrypt_sops_file "$temp_file" "$_age_key_path"; then
        log_error "Failed to encrypt secrets"
        rm -f "$encrypted_temp"
        return 1
    fi
    if ! cp -- "$temp_file" "$encrypted_temp"; then
        log_error "Failed to stage encrypted secrets"
        rm -f "$encrypted_temp"
        return 1
    fi
''')
replace_once('utilities/secrets-rotate.sh', '    cp "$temp_patched" "$temp_enc"\n', '')
replace_once('utilities/secrets-rotate.sh', '''    if ! encrypt_sops_file "$temp_enc" "$_age_key_path"; then
        log_error "Failed to re-encrypt secrets"
        rm -f "$temp_enc"
        return 1
    fi
''', '''    if ! encrypt_sops_file "$temp_patched" "$_age_key_path"; then
        log_error "Failed to re-encrypt secrets"
        rm -f "$temp_enc"
        return 1
    fi
    if ! cp -- "$temp_patched" "$temp_enc"; then
        log_error "Failed to stage encrypted secrets"
        rm -f "$temp_enc"
        return 1
    fi
''')

replace_function('utilities/setup-secrets.sh', '_ss_make_plaintext_temp', r'''_ss_make_plaintext_temp() {
    local dir tmp
    if [[ "${VW_TEST_MODE:-false}" == "true" && -n "${VW_SETUP_SECRETS_TMP_DIR:-}" ]]; then
        _ss_prepare_plain_tmp_dir || return 1
        dir="$(_ss_plain_tmp_dir)"
    else
        _setup_secrets_create_workdir || return 1
        dir="$SETUP_SECRETS_OWNED_WORKDIR"
    fi
    tmp=$(mktemp -p "$dir" vwsecrets.XXXXXXXXXX.yaml) || return 1
    chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
    printf '%s' "$tmp"
}''')

p = Path('lib/secrets.sh')
t = p.read_text()
old = '''    local curl_cfg
    if ! curl_cfg=$(mktemp) || ! install -m 600 /dev/null "$curl_cfg"; then
        rm -f "$curl_cfg" 2>/dev/null || true
        return 1
    fi
'''
new = '''    local curl_cfg curl_workspace
    curl_workspace="$(create_sensitive_workspace cloudflare-token)" || return 1
    curl_cfg="${curl_workspace}/curl.conf"
    if ! install -m 600 /dev/null "$curl_cfg"; then
        remove_sensitive_workspace "$curl_workspace" 2>/dev/null || true
        return 1
    fi
'''
if old not in t:
    raise SystemExit('lib/secrets.sh: Cloudflare curl config block missing')
t = t.replace(old, new, 1)
t = t.replace('''    rm -f "$curl_cfg"
    return "$rc"
}''', '''    remove_sensitive_workspace "$curl_workspace" 2>/dev/null || true
    return "$rc"
}''', 1)
p.write_text(t)

p = Path('utilities/setup-secrets.sh')
t = p.read_text()
old = '''        schedule_auto_cleanup

        return 0
'''
new = '''        if ! schedule_auto_cleanup; then
            log_error "Break-glass expiry could not be scheduled; removing the newly created account."
            remove_breakglass_user --force >/dev/null 2>&1 || {
                log_error "CRITICAL: break-glass expiry failed and automatic account rollback also failed."
                return 1
            }
            return 1
        fi

        return 0
'''
if old not in t:
    raise SystemExit('utilities/setup-secrets.sh: breakglass scheduling call missing')
t = t.replace(old, new, 1)
p.write_text(t)

p = Path('utilities/secrets-export-recovery-kit.sh')
t = p.read_text().replace('temporary plaintext may use /dev/shm', 'temporary plaintext uses verified volatile storage')
p.write_text(t)
