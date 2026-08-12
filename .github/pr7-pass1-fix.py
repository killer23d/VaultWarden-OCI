from pathlib import Path
import re


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:80]!r}")
    p.write_text(text.replace(old, new, 1))


def replace_function(path, name, body):
    p = Path(path)
    lines = p.read_text().splitlines(True)
    start = next((i for i, line in enumerate(lines) if line.startswith(name + '() {')), None)
    if start is None:
        raise SystemExit(f"{path}: function {name} not found")
    end = next((i for i in range(start + 1, len(lines)) if lines[i].rstrip('\n') == '}'), None)
    if end is None:
        raise SystemExit(f"{path}: function {name} end not found")
    lines[start:end + 1] = [body.rstrip() + '\n']
    p.write_text(''.join(lines))


# ---- lib/crypto.sh ---------------------------------------------------------
p = Path('lib/crypto.sh')
t = p.read_text()
comment_re = re.compile(
    r"# Encrypts to a mktemp staging file and atomically renames it over the\n"
    r".*?"
    r"# Create a root-only workspace only on verified volatile storage\.\n"
    r"# Callers own lifecycle registration so existing signal/operation traps remain authoritative\.\n",
    re.S,
)
t, n = comment_re.subn(
    "# Sensitive plaintext/private-key workspace helpers. Production callers are\n"
    "# root-only and may use only verified volatile backing. Callers own lifecycle\n"
    "# registration so existing signal/operation traps remain authoritative.\n",
    t,
    count=1,
)
if n != 1:
    raise SystemExit('lib/crypto.sh: stale encryption/workspace comment block not found')
p.write_text(t)

replace_function('lib/crypto.sh', 'create_sensitive_workspace', r'''create_sensitive_workspace() {
    local purpose="${1:-sensitive}" base workspace old_umask metadata
    [[ "$purpose" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
        log_error "Sensitive workspace purpose is invalid: $purpose"
        return 1
    }
    if (( EUID != 0 )); then
        log_error "Sensitive workspaces require root privileges."
        return 1
    fi

    for base in /run/vaultwarden-oci /dev/shm; do
        case "$base" in
            /run/vaultwarden-oci)
                _sensitive_backing_is_volatile /run || continue
                if [[ ! -e "$base" ]]; then
                    install -d -m 0700 -o root -g root "$base" 2>/dev/null || continue
                fi
                [[ -d "$base" && ! -L "$base" ]] || continue
                metadata="$(stat -c '%u:%g:%a' -- "$base" 2>/dev/null)" || continue
                [[ "$metadata" == "0:0:700" ]] || continue
                ;;
            /dev/shm)
                _sensitive_backing_is_volatile "$base" || continue
                metadata="$(stat -c '%u:%g:%a' -- "$base" 2>/dev/null)" || continue
                [[ "$metadata" == "0:0:1777" ]] || continue
                ;;
        esac
        _sensitive_backing_is_volatile "$base" || continue

        old_umask="$(umask)"
        umask 077
        workspace="$(mktemp -d -p "$base" "vw-${purpose}.XXXXXXXXXX" 2>/dev/null)" || {
            umask "$old_umask" || true
            continue
        }
        umask "$old_umask"
        if ! chmod 0700 "$workspace" 2>/dev/null; then
            rm -rf -- "$workspace" 2>/dev/null || true
            continue
        fi
        metadata="$(stat -c '%u:%g:%a' -- "$workspace" 2>/dev/null)" || {
            rm -rf -- "$workspace" 2>/dev/null || true
            continue
        }
        if [[ "$metadata" != "0:0:700" ]] || ! _sensitive_backing_is_volatile "$workspace"; then
            rm -rf -- "$workspace" 2>/dev/null || true
            continue
        fi
        printf '%s\n' "$workspace"
        return 0
    done

    log_error "No verified volatile root-only workspace is available under /run/vaultwarden-oci or /dev/shm."
    return 1
}''')

replace_function('lib/crypto.sh', 'remove_sensitive_workspace', r'''remove_sensitive_workspace() {
    local workspace="${1:-}" file
    [[ -n "$workspace" ]] || return 1
    case "$workspace" in
        /run/vaultwarden-oci/vw-*|/dev/shm/vw-*) ;;
        *) return 1 ;;
    esac
    if [[ ! -e "$workspace" && ! -L "$workspace" ]]; then
        return 0
    fi
    [[ ! -L "$workspace" && -d "$workspace" ]] || return 1
    while IFS= read -r -d '' file; do
        if declare -F secure_delete >/dev/null 2>&1; then
            secure_delete "$file" 2>/dev/null || rm -f -- "$file" 2>/dev/null || true
        elif command -v shred >/dev/null 2>&1; then
            shred -fuz -- "$file" 2>/dev/null || rm -f -- "$file" 2>/dev/null || true
        else
            rm -f -- "$file" 2>/dev/null || true
        fi
    done < <(find -P "$workspace" -type f -print0 2>/dev/null)
    rm -rf -- "$workspace"
}''')

replace_function('lib/crypto.sh', 'encrypt_sops_file', r'''encrypt_sops_file() {
    # The caller supplies a plaintext staging file. Encrypt a private same-directory
    # copy, validate that ciphertext with the operational identity, then atomically
    # replace only the caller's staging file. Live ciphertext promotion is handled
    # separately by promote_sops_ciphertext().
    local file="$1" age_key_file="${2:-}" age_public_key file_dir file_base tmp_file old_umask
    [[ -f "$file" ]] || { log_error "encrypt_sops_file: file not found: $file"; return 1; }
    if [[ -z "$age_key_file" ]]; then
        age_key_file="$(resolve_age_key_path)" || return 1
    fi
    [[ -f "$age_key_file" ]] || { log_error "encrypt_sops_file: Age key not found: $age_key_file"; return 1; }
    age_public_key="$(_derive_age_public_key "$age_key_file")" || {
        log_error "encrypt_sops_file: could not derive the Age recipient from $age_key_file"
        return 1
    }

    file_dir="$(dirname -- "$file")"
    file_base="$(basename -- "$file")"
    old_umask="$(umask)"; umask 077
    tmp_file="$(mktemp "${file_dir}/.${file_base}.encrypt.XXXXXXXXXX")" || { umask "$old_umask"; return 1; }
    umask "$old_umask"
    chmod 0600 "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }
    cp -- "$file" "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }

    if ! SOPS_AGE_KEY_FILE="$age_key_file" sops --encrypt \
            --age "$age_public_key" \
            --input-type yaml \
            --output-type yaml \
            --in-place "$tmp_file"; then
        log_error "encrypt_sops_file: SOPS encryption failed"
        rm -f -- "$tmp_file"
        return 1
    fi
    if ! SOPS_AGE_KEY_FILE="$age_key_file" sops --decrypt \
            --input-type yaml \
            --output-type yaml \
            "$tmp_file" >/dev/null 2>&1; then
        log_error "encrypt_sops_file: encrypted staging file failed round-trip validation"
        rm -f -- "$tmp_file"
        return 1
    fi
    mv -- "$tmp_file" "$file" || { rm -f -- "$tmp_file"; return 1; }
}''')

# ---- lib/secrets.sh --------------------------------------------------------
p = Path('lib/secrets.sh')
lines = p.read_text().splitlines(True)
start = next(i for i, line in enumerate(lines) if line.startswith('validate_cloudflare_token() {'))
end = next(i for i in range(start + 1, len(lines)) if lines[i].rstrip('\n') == '}')
body = ''.join(lines[start:end + 1])
body = body.replace('validate_cloudflare_token() {\n', 'validate_cloudflare_token() (\n', 1)
body = body[:-2] + ')\n'
body = body.replace(
    '    local curl_cfg curl_workspace\n',
    '    local curl_cfg="" curl_workspace=""\n'
    '    trap \'[[ -z "${curl_workspace:-}" ]] || remove_sensitive_workspace "$curl_workspace" >/dev/null 2>&1 || true\' EXIT\n'
    "    trap 'exit 130' INT\n"
    "    trap 'exit 129' HUP\n"
    "    trap 'exit 143' TERM\n",
    1,
)
body = body.replace(
    '    printf \'header = "Authorization: Bearer %s"\\n\' "$token" > "$curl_cfg"\n',
    '    if ! printf \'header = "Authorization: Bearer %s"\\n\' "$token" > "$curl_cfg"; then\n'
    '        log_error "Cloudflare token validation: failed to write protected curl configuration"\n'
    '        return 1\n'
    '    fi\n',
    1,
)
body = body.replace(
    '    rm -f "$curl_cfg" 2>/dev/null || true\n    return "$result"\n',
    '    if ! remove_sensitive_workspace "$curl_workspace"; then\n'
    '        log_error "Cloudflare token validation: failed to clean sensitive workspace"\n'
    '        return 1\n'
    '    fi\n'
    '    curl_workspace=""\n'
    '    return "$result"\n',
    1,
)
if 'trap \'[[ -z "${curl_workspace:-}" ]]' not in body or 'failed to clean sensitive workspace' not in body:
    raise SystemExit('lib/secrets.sh: Cloudflare workspace cleanup patch did not apply')
lines[start:end + 1] = [body]
p.write_text(''.join(lines))

# ---- utilities/setup-secrets.sh ------------------------------------------
p = Path('utilities/setup-secrets.sh')
t = p.read_text()

old_make = '''_ss_make_plaintext_temp() {
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
}
'''
new_make = '''_ss_make_plaintext_temp() {
    local dir tmp
    if [[ "${VW_TEST_MODE:-false}" == "true" && -n "${VW_SETUP_SECRETS_TMP_DIR:-}" ]]; then
        _ss_prepare_plain_tmp_dir || return 1
        dir="$(_ss_plain_tmp_dir)"
    else
        [[ -n "${SETUP_SECRETS_OWNED_WORKDIR:-}" && -d "$SETUP_SECRETS_OWNED_WORKDIR" ]] || {
            log_error "Protected setup-secrets workspace was not initialized by the owning shell."
            return 1
        }
        dir="$SETUP_SECRETS_OWNED_WORKDIR"
    fi
    tmp=$(mktemp -p "$dir" vwsecrets.XXXXXXXXXX.yaml) || return 1
    chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
    printf '%s' "$tmp"
}
'''
if old_make not in t:
    raise SystemExit('utilities/setup-secrets.sh: _ss_make_plaintext_temp old body missing')
t = t.replace(old_make, new_make, 1)

t = t.replace(
    '''        local temp_file=""
        temp_file="$(_ss_make_plaintext_temp)" || {
            log_error "Failed to create protected plaintext staging file"
            return 1
        }
''',
    '''        local temp_file=""
        if ! _setup_secrets_create_workdir; then
            log_error "Failed to initialize protected plaintext workspace"
            return 1
        fi
        temp_file="$(_ss_make_plaintext_temp)" || {
            log_error "Failed to create protected plaintext staging file"
            return 1
        }
''',
    1,
)
t = t.replace(
    '''    local tmp_secrets=""
    tmp_secrets="$(_ss_make_plaintext_temp)" || return 1
''',
    '''    local tmp_secrets=""
    _setup_secrets_create_workdir || return 1
    tmp_secrets="$(_ss_make_plaintext_temp)" || return 1
''',
    1,
)
if t.count('_ss_make_plaintext_temp)') < 2:
    raise SystemExit('utilities/setup-secrets.sh: plaintext temp callers unexpectedly changed')

legacy_re = re.compile(
    r'\n        if groups "\$BREAKGLASS_USER" 2>/dev/null \| grep -qw "sudo"; then\n.*?\n        fi\n\n        if userdel -r "\$BREAKGLASS_USER"',
    re.S,
)
t, n = legacy_re.subn('\n        if userdel -r "$BREAKGLASS_USER"', t, count=1)
if n != 1:
    raise SystemExit('utilities/setup-secrets.sh: legacy sudo-group cleanup block not found')

t = t.replace(
    'echo "  Auto-cleanup timer: ℹ️  Not active via systemd (may be scheduled via \'at\')"',
    'echo "  Auto-cleanup timer: ❌ Not active; break-glass expiry is not verified"',
    1,
)

schedule_block = '''        if ! schedule_auto_cleanup; then
            log_error "Break-glass expiry could not be scheduled; removing the newly created account."
            remove_breakglass_user --force >/dev/null 2>&1 || {
                log_error "CRITICAL: break-glass expiry failed and automatic account rollback also failed."
                return 1
            }
            return 1
        fi

'''
if t.count(schedule_block) != 1:
    raise SystemExit(f'utilities/setup-secrets.sh: expected one breakglass scheduling block, found {t.count(schedule_block)}')
t = t.replace(schedule_block, '', 1)
marker = '        log_success "Break-glass admin created successfully"\n'
if marker not in t:
    raise SystemExit('utilities/setup-secrets.sh: breakglass success marker missing')
t = t.replace(marker, schedule_block + marker, 1)
p.write_text(t)

# ---- utilities/setup-system.sh -------------------------------------------
p = Path('utilities/setup-system.sh')
t = p.read_text()
t = t.replace(
    '# Ubuntu installs package 7zip, while usable command names vary by source.\n# Keep detection centralized so both 7zz and 7z remain valid.\n',
    '# Ubuntu 24.04 installs the supported 7zip package with the 7zz command.\n# Keep the executable check centralized and fail closed if 7zz is unavailable.\n',
    1,
)
p.write_text(t)

# ---- tests ----------------------------------------------------------------
p = Path('tests/suites/security/case-secrets.bash')
t = p.read_text()
# SOPS mocks must tolerate explicit recipient/type arguments between --encrypt and --in-place.
t = t.replace("*' --encrypt --in-place '*)", "*' --encrypt '*)")

# Strengthen the direct PR7 helper regression.
old_root = '''if (( EUID == 0 )); then
    _sensitive_backing_is_volatile() { return 1; }
    if create_sensitive_workspace refusal-test >/dev/null 2>&1; then
        fail 'sensitive workspace succeeded when all backing verification was forced to fail'
    fi

    # The source guard prevents re-sourcing; restore an accepting verifier
    # explicitly for the cleanup-only assertion below.
    _sensitive_backing_is_volatile() { return 0; }
    workspace="$(create_sensitive_workspace test-cleanup)" || fail 'could not create verified volatile workspace on Noble runner'
    [[ "$(stat -c '%u:%g:%a' "$workspace")" == '0:0:700' ]] || fail 'sensitive workspace is not root:root mode 0700'
'''
new_root = '''if (( EUID == 0 )); then
    original_backing_verifier="$(declare -f _sensitive_backing_is_volatile)"
    _sensitive_backing_is_volatile() { return 1; }
    if create_sensitive_workspace refusal-test >/dev/null 2>&1; then
        fail 'sensitive workspace succeeded when all backing verification was forced to fail'
    fi

    eval "$original_backing_verifier"
    workspace="$(create_sensitive_workspace test-cleanup)" || fail 'could not create verified volatile workspace on Noble runner'
    [[ "$(stat -c '%u:%g:%a' "$workspace")" == '0:0:700' ]] || fail 'sensitive workspace is not root:root mode 0700'
'''
if old_root not in t:
    raise SystemExit('tests: PR7 root workspace block not found')
t = t.replace(old_root, new_root, 1)

# Mock public recipient derivation for the isolated encrypt_sops_file regression.
t = t.replace(
    '''plain="$TMP/plain.yaml"
printf 'PLAINTEXT\\n' >"$plain"
sops() {
''',
    '''plain="$TMP/plain.yaml"
printf 'PLAINTEXT\\n' >"$plain"
_derive_age_public_key() { printf '%s\\n' 'age1testrecipient0000000000000000000000000000000000000000000000'; }
sops() {
''',
    1,
)

# Add source-contract assertions beside the existing sensitive-cleanup checks.
anchor = '''grep -Fq 'systemd_cleanup_body' lib/secrets.sh || fail "recovery-owned systemd workaround is missing"
'''
checks = '''grep -Fq -- '--age "$age_public_key"' lib/crypto.sh || fail "SOPS encryption no longer pins the derived Age recipient"
grep -Fq -- '--input-type yaml' lib/crypto.sh || fail "SOPS encryption no longer pins YAML input type"
grep -Fq -- '--output-type yaml' lib/crypto.sh || fail "SOPS encryption no longer pins YAML output type"
grep -Fq '[[ "$metadata" == "0:0:1777" ]]' lib/crypto.sh || fail "/dev/shm ownership/mode is not verified"
grep -Fq 'validate_cloudflare_token() (' lib/secrets.sh || fail "Cloudflare token validation lacks isolated cleanup scope"
grep -Fq 'failed to clean sensitive workspace' lib/secrets.sh || fail "Cloudflare token workspace cleanup is not enforced"
'''
if anchor not in t:
    raise SystemExit('tests: sensitive cleanup source assertion anchor missing')
t = t.replace(anchor, anchor + checks, 1)

t = t.replace(
    '''! grep -Fq 'legacy full-root configuration' utilities/setup-secrets.sh || fail "legacy sudo-group break-glass status remains"
''',
    '''! grep -Fq 'legacy full-root configuration' utilities/setup-secrets.sh || fail "legacy sudo-group break-glass status remains"
! grep -Fq 'gpasswd -d "$BREAKGLASS_USER" sudo' utilities/setup-secrets.sh || fail "legacy sudo-group break-glass cleanup remains"
! grep -Fq 'deluser "$BREAKGLASS_USER" sudo' utilities/setup-secrets.sh || fail "legacy sudo-group break-glass cleanup remains"
! grep -Fq 'may be scheduled via' utilities/setup-secrets.sh || fail "break-glass status still advertises a removed scheduler fallback"
schedule_line="$(grep -nF 'if ! schedule_auto_cleanup; then' utilities/setup-secrets.sh | head -1 | cut -d: -f1)"
success_line="$(grep -nF 'Break-glass admin created successfully' utilities/setup-secrets.sh | head -1 | cut -d: -f1)"
[[ -n "$schedule_line" && -n "$success_line" && "$schedule_line" -lt "$success_line" ]] || fail "break-glass reports success before expiry is verified"
plain_helper_source="$(awk '/^_ss_make_plaintext_temp[(][)]/ {p=1} p {print} p && /^}/ {exit}' utilities/setup-secrets.sh)"
[[ "$plain_helper_source" != *'_setup_secrets_create_workdir'* ]] || fail "plaintext temp helper creates owned workspace inside command substitution"
''',
    1,
)
p.write_text(t)
