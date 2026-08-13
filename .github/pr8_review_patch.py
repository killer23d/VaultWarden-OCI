from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}")
    p.write_text(text.replace(old, new, 1))


# 1. setup-systemd: fail closed on canonical Age key before install-path mutation.
replace_once(
    "utilities/setup-systemd.sh",
    'source "${PROJECT_ROOT}/lib/common.sh"\ninit_common_lib "$0"\n# shellcheck source=../lib/operations.sh\nsource "${PROJECT_ROOT}/lib/operations.sh"\n',
    'source "${PROJECT_ROOT}/lib/common.sh"\ninit_common_lib "$0"\n# shellcheck disable=SC1091\n# shellcheck source=../lib/crypto.sh\nsource "${PROJECT_ROOT}/lib/crypto.sh"\n# shellcheck source=../lib/operations.sh\nsource "${PROJECT_ROOT}/lib/operations.sh"\n',
)

preflight = r'''_preflight_canonical_age_key() {
    log_info "Preflighting canonical Age key at $AGE_KEY_DEST ..."
    if [[ ! -f "$AGE_KEY_DEST" || ! -r "$AGE_KEY_DEST" ]]; then
        log_error "Canonical Age key is missing or unreadable: $AGE_KEY_DEST"
        log_error "Install the operational key at /etc/vaultwarden/age-key.txt, then rerun this command."
        return 1
    fi
    if ! check_age_key "$AGE_KEY_DEST"; then
        log_error "Canonical Age key failed validation: $AGE_KEY_DEST"
        log_error "Restore a valid operational key at /etc/vaultwarden/age-key.txt, then rerun this command."
        return 1
    fi
    log_success "Canonical Age key preflight passed: $AGE_KEY_DEST"
    return 0
}

'''
replace_once(
    "utilities/setup-systemd.sh",
    '_sync_runtime_environment_files() {\n',
    preflight + '_sync_runtime_environment_files() {\n',
)
replace_once(
    "utilities/setup-systemd.sh",
    '    log_info "Installing scripts to $OPT_SCRIPTS_DIR ..."\n',
    '    _preflight_canonical_age_key || return 1\n\n    log_info "Installing scripts to $OPT_SCRIPTS_DIR ..."\n',
)
replace_once(
    "utilities/setup-systemd.sh",
    '''    # The operational Age key is provisioned directly at its canonical path.
    log_info "Checking canonical age key at $AGE_KEY_DEST ..."
    if [[ -f "$AGE_KEY_DEST" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would validate root:root 600 on $AGE_KEY_DEST"
        else
            fix_known_path_permissions "$AGE_KEY_DEST"
            log_success "Canonical age key present: $AGE_KEY_DEST"
        fi
    else
        log_warn "Canonical Age key is missing: $AGE_KEY_DEST"
        log_warn "Install the correct operational key there, then rerun this command."
    fi
''',
    '''    # The read-only preflight above proved the operational identity before
    # any install-path mutation. Preserve the existing ownership repair only after
    # that safety boundary has passed.
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would validate root:root 600 on $AGE_KEY_DEST"
    else
        fix_known_path_permissions "$AGE_KEY_DEST"
        log_success "Canonical age key present: $AGE_KEY_DEST"
    fi
''',
)

# 2. Backup remediation must point only at the canonical operational key.
p = Path("utilities/backup-run.sh")
text = p.read_text()
stale = '            log_error "Set SOPS_AGE_KEY_FILE in .env, or place the key at /etc/vaultwarden/age-key.txt"'
if text.count(stale) != 2:
    raise SystemExit(f"utilities/backup-run.sh: expected two stale key hints, found {text.count(stale)}")
text = text.replace(stale, '            log_error "Restore the operational Age key at /etc/vaultwarden/age-key.txt, then re-run the backup."')
p.write_text(text)

# 3. key-rotate is a runtime-authority operation, not a repo-.env editor.
replace_once(
    "Makefile",
    'key-rotate: ## Rotate age encryption key (re-encrypts all secrets)\n\t$(call require-root)\n\t$(call check-env-readable)\n\t@./utilities/key-rotate.sh\n',
    'key-rotate: ## Rotate age encryption key (re-encrypts all secrets)\n\t$(call require-root)\n\t@./utilities/key-rotate.sh\n',
)

# 4. setup-storage: setup mode deliberately reads authoring .env directly.
replace_once(
    "utilities/setup-storage.sh",
    '''_ss_load_runtime_environment() {
    local installed_env="${VW_CONFIG_INSTALLED_ENV_FILE:-/etc/vaultwarden/vaultwarden.env}"
    if [[ -f "${PROJECT_ROOT}/.env" || -f "${installed_env}" || -f "${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}/config/install.env" ]]; then
        load_project_environment || {
            # setup-storage also supports first-run bootstrapping before runtime env exists.
            if [[ -f "${PROJECT_ROOT}/.env" ]]; then
                load_env_file "${PROJECT_ROOT}/.env" || true
            fi
        }
    fi

    if [[ "${_SS_DATA_DEVICE_PROVIDED}" != "true" ]]; then
        _SS_DATA_DEVICE="${DATA_VOLUME_DEVICE:-${_SS_DATA_DEVICE:-}}"
    fi
    if [[ "${_SS_DATA_MOUNT_PROVIDED}" != "true" ]]; then
        _SS_DATA_MOUNT="${DATA_VOLUME_MOUNT:-${_SS_DATA_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}}"
    fi
}
''',
    '''_ss_load_environment() {
    local installed_env="${VW_CONFIG_INSTALLED_ENV_FILE:-/etc/vaultwarden/vaultwarden.env}"
    local persistent_env="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}/config/install.env"

    case "${_SS_MODE}" in
        setup)
            # First-install storage deliberately consumes the authoring input.
            # Do not probe runtime authority and then fall back to repo .env.
            if [[ -f "${PROJECT_ROOT}/.env" ]]; then
                load_authoring_environment || return 1
            fi
            ;;
        verify|migrate)
            if [[ -f "${installed_env}" || -f "${persistent_env}" ]]; then
                load_project_environment || return 1
            fi
            ;;
    esac

    if [[ "${_SS_DATA_DEVICE_PROVIDED}" != "true" ]]; then
        _SS_DATA_DEVICE="${DATA_VOLUME_DEVICE:-${_SS_DATA_DEVICE:-}}"
    fi
    if [[ "${_SS_DATA_MOUNT_PROVIDED}" != "true" ]]; then
        _SS_DATA_MOUNT="${DATA_VOLUME_MOUNT:-${_SS_DATA_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}}"
    fi
}
''',
)
replace_once(
    "utilities/setup-storage.sh",
    '''main() {
    _ss_dispatch_metadata "$@"
    _ss_load_runtime_environment
    _parse_outer_args "$@"

    if [[ "${_SS_MODE}" == "migrate" ]]; then
''',
    '''main() {
    _ss_dispatch_metadata "$@"
    _parse_outer_args "$@"
    _ss_load_environment

    if [[ "${_SS_MODE}" == "migrate" ]]; then
''',
)

# Systemd domain test: prove missing canonical key fails before install-path mutation.
p = Path("tests/suites/foundation/case-systemd.bash")
text = p.read_text()
marker = 'test_systemd_missing_source_and_dry_run_behavior() {\n'
if text.count(marker) != 1:
    raise SystemExit(f"case-systemd: insertion marker count {text.count(marker)}")
helper = r'''write_fake_age_contract() {
    local key_file="$1" bin="$2"
    mkdir -p "$(dirname "$key_file")" "$bin"
    cat > "$key_file" <<'EOF_KEY'
# public key: age1systemdtest000000000000000000000000000000000000000000000000
AGE-SECRET-KEY-1SYSTEMDTEST
EOF_KEY
    chmod 600 "$key_file"
    cat > "$bin/age" <<'EOF_AGE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-r" ]]; then
    out=""
    while (($#)); do
        case "$1" in
            -o) out="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done
    [[ -n "$out" ]] || exit 2
    cat > "$out"
    exit 0
fi
if [[ "${1:-}" == "-d" ]]; then
    file="${@: -1}"
    cat "$file"
    exit 0
fi
exit 2
EOF_AGE
    chmod +x "$bin/age"
}

test_systemd_missing_canonical_age_key_fails_before_install_mutation() {
    if ! can_run_systemd_behavioral_tests; then
        printf 'SKIP: systemd missing-key install test requires Linux root or passwordless sudo\n'
        return 0
    fi

    local repo="$TMP/missing-key-repo" state="$TMP/missing-key-state"
    local unit_dir="$TMP/missing-key-units" opt_dir="$TMP/missing-key-opt" env_dir="$TMP/missing-key-etc"
    local out="$TMP/missing-key.out"
    prepare_systemd_install_repo "$repo" "$state"

    if run_root_env_capture "$out" \
        PROJECT_STATE_DIR="$state" \
        VW_CONFIG_INSTALLED_ENV_FILE="$env_dir/vaultwarden.env" \
        VW_SYSTEMD_UNIT_DEST_DIR="$unit_dir" \
        VW_SYSTEMD_OPT_SCRIPTS_DIR="$opt_dir" \
        VW_SYSTEMD_ENV_DIR="$env_dir" \
        bash "$repo/utilities/setup-systemd.sh" install --no-enable-now; then
        fail "systemd install succeeded without the canonical Age key"
    fi

    grep -Fq "Canonical Age key is missing or unreadable: $env_dir/age-key.txt" "$out" \
        || { cat "$out" >&2; fail "missing canonical Age key was not reported"; }
    [[ ! -e "$unit_dir" && ! -e "$opt_dir" && ! -e "$env_dir" ]] \
        || fail "missing-key preflight mutated install paths"
}

'''
text = text.replace(marker, helper + marker, 1)

old = '''    cp "$ROOT/utilities/backup-run.sh" "$repo/utilities/backup-run.sh"
    run_root_env_capture "$dry_out" \
        PROJECT_STATE_DIR="$state" \
        VW_CONFIG_INSTALLED_ENV_FILE="$env_dir/vaultwarden.env" \
        VW_SYSTEMD_UNIT_DEST_DIR="$unit_dir" \
        VW_SYSTEMD_OPT_SCRIPTS_DIR="$opt_dir" \
        VW_SYSTEMD_ENV_DIR="$env_dir" \
        bash "$repo/utilities/setup-systemd.sh" install --dry-run \
'''
new = '''    cp "$ROOT/utilities/backup-run.sh" "$repo/utilities/backup-run.sh"
    local age_bin="$TMP/inventory-age-bin"
    write_fake_age_contract "$env_dir/age-key.txt" "$age_bin"
    run_root_env_capture "$dry_out" \
        PATH="$age_bin:$PATH" \
        PROJECT_STATE_DIR="$state" \
        VW_CONFIG_INSTALLED_ENV_FILE="$env_dir/vaultwarden.env" \
        VW_SYSTEMD_UNIT_DEST_DIR="$unit_dir" \
        VW_SYSTEMD_OPT_SCRIPTS_DIR="$opt_dir" \
        VW_SYSTEMD_ENV_DIR="$env_dir" \
        bash "$repo/utilities/setup-systemd.sh" install --dry-run \
'''
if text.count(old) != 1:
    raise SystemExit(f"case-systemd: dry-run patch expected one match, found {text.count(old)}")
text = text.replace(old, new, 1)
old_assert = '''    [[ ! -e "$unit_dir" && ! -e "$opt_dir" && ! -e "$env_dir" ]] \
        || fail "dry-run mutated installation paths"
'''
new_assert = '''    [[ ! -e "$unit_dir" && ! -e "$opt_dir" ]] \
        || fail "dry-run mutated unit or /opt installation paths"
    [[ -f "$env_dir/age-key.txt" && "$(find "$env_dir" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 1 ]] \
        || fail "dry-run mutated the pre-existing canonical-key directory"
'''
if text.count(old_assert) != 1:
    raise SystemExit(f"case-systemd: dry-run assertion match count {text.count(old_assert)}")
text = text.replace(old_assert, new_assert, 1)
run_marker = "run_test 'systemd missing source fails before mutation and dry-run stays read-only' test_systemd_missing_source_and_dry_run_behavior\n"
if text.count(run_marker) != 1:
    raise SystemExit("case-systemd: run marker missing")
text = text.replace(
    run_marker,
    "run_test 'systemd missing canonical Age key fails before install mutation' test_systemd_missing_canonical_age_key_fails_before_install_mutation\n" + run_marker,
    1,
)
expected = '[[ "$TESTS_RUN" -eq 11 ]] || fail "expected 11 tests, ran $TESTS_RUN"'
if text.count(expected) != 1:
    raise SystemExit(f"case-systemd: expected count assertion once, found {text.count(expected)}")
text = text.replace(expected, '[[ "$TESTS_RUN" -eq 12 ]] || fail "expected 12 tests, ran $TESTS_RUN"', 1)
p.write_text(text)

# Existing lifecycle systemd install fixtures now provide the required identity.
p = Path("tests/suites/operations/case-lifecycle.bash")
text = p.read_text()
chmod_marker = '  chmod +x "$bin"/*\n}\n\ncopy_systemd_install_repo(){\n'
if text.count(chmod_marker) != 1:
    raise SystemExit(f"case-lifecycle: fake-bin marker count {text.count(chmod_marker)}")
fake_age = r'''  cat > "$bin/age" <<'AGE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-r" ]]; then
  out=""
  while (($#)); do
    case "$1" in -o) out="${2:-}"; shift 2 ;; *) shift ;; esac
  done
  [[ -n "$out" ]] || exit 2
  cat > "$out"
  exit 0
fi
if [[ "${1:-}" == "-d" ]]; then
  cat "${@: -1}"
  exit 0
fi
exit 2
AGE
'''
text = text.replace(chmod_marker, fake_age + chmod_marker, 1)
fixture_marker = '''  mkdir -p "$unit_dir" "$opt_dir" "$env_dir" "$state" "$TMP/run-locks"
  run_root_env_capture "$out" \
'''
if text.count(fixture_marker) != 1:
    raise SystemExit(f"case-lifecycle: install fixture marker count {text.count(fixture_marker)}")
text = text.replace(
    fixture_marker,
    '''  mkdir -p "$unit_dir" "$opt_dir" "$env_dir" "$state" "$TMP/run-locks"
  cat > "$env_dir/age-key.txt" <<'EOF_KEY'
# public key: age1systemdpolicy00000000000000000000000000000000000000000000000
AGE-SECRET-KEY-1SYSTEMDPOLICY
EOF_KEY
  chmod 600 "$env_dir/age-key.txt"
  run_root_env_capture "$out" \
''',
    1,
)
p.write_text(text)

# Runtime-authority suite: behavioral DNS failure proof + remaining authority seams.
p = Path("tests/suites/foundation/case-runtime-authority.bash")
text = p.read_text()
var_marker = 'setup_secrets="$(cat utilities/setup-secrets.sh)"\nrepair_permissions="$(cat utilities/repair-permissions.sh)"\n'
if text.count(var_marker) != 1:
    raise SystemExit(f"case-runtime-authority: setup_storage variable marker count {text.count(var_marker)}")
text = text.replace(
    var_marker,
    'setup_secrets="$(cat utilities/setup-secrets.sh)"\nsetup_storage="$(cat utilities/setup-storage.sh)"\nrepair_permissions="$(cat utilities/repair-permissions.sh)"\n',
    1,
)

dns_pass = 'pass "DNS mutation credentials resolve only through SOPS"\n'
if text.count(dns_pass) != 1:
    raise SystemExit("case-runtime-authority: DNS insertion marker missing")
dns_test = r'''

can_run_root_fixture() {
    (( EUID == 0 )) && return 0
    command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1
}

run_root_fixture() {
    if (( EUID == 0 )); then
        env "$@"
    else
        sudo -n env "$@"
    fi
}

if can_run_root_fixture; then
    dns_repo="$tmp/dns-repo"
    dns_state="$tmp/dns-state"
    dns_bin="$tmp/dns-bin"
    dns_out="$tmp/dns-broken-sops.out"
    dns_curl_log="$tmp/dns-curl.log"
    mkdir -p "$dns_repo/utilities" "$dns_state/config" "$dns_bin"
    cp -a "$ROOT/lib" "$dns_repo/"
    cp "$ROOT/utilities/maintenance-update-dns.sh" "$dns_repo/utilities/"
    cat > "$dns_state/config/install.env" <<EOF_DNS_ENV
PROJECT_STATE_DIR=$dns_state
DOMAIN=https://dns-authority.example.test
UPDATE_DNS=true
DNS_UPDATE_REQUIRED=true
EOF_DNS_ENV
    chmod 600 "$dns_state/config/install.env"
    cat > "$dns_bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DNS_CURL_LOG:?}"
exit 99
EOF_CURL
    chmod +x "$dns_bin/curl"
    : > "$dns_curl_log"

    if run_root_fixture \
        PATH="$dns_bin:$PATH" \
        DNS_CURL_LOG="$dns_curl_log" \
        AGE_KEY_FILE="$dns_state/missing-age-key.txt" \
        PROJECT_STATE_DIR="$dns_state" \
        VW_CONFIG_INSTALLED_ENV_FILE="$dns_state/config/install.env" \
        UPDATE_DNS=true \
        DNS_UPDATE_REQUIRED=true \
        bash "$dns_repo/utilities/maintenance-update-dns.sh" --require-dns \
        >"$dns_out" 2>&1; then
        cat "$dns_out" >&2
        fail "DNS updater succeeded when canonical SOPS resolution was broken"
    fi
    grep -Eq 'cloudflare_zone_id is not configured|DNS update is required' "$dns_out" \
        || { cat "$dns_out" >&2; fail "DNS broken-SOPS failure was not operator-visible"; }
    [[ ! -s "$dns_curl_log" ]] \
        || { cat "$dns_curl_log" >&2; fail "DNS updater attempted a network/Cloudflare request after SOPS resolution failed"; }
    if (( EUID != 0 )); then
        sudo -n rm -rf "$dns_repo" "$dns_state" 2>/dev/null || true
    fi
    pass "DNS mutation fails before any request when canonical SOPS resolution is broken"
else
    echo "SKIP runtime-authority: DNS broken-SOPS behavioral proof requires root or passwordless sudo"
fi
'''
text = text.replace(dns_pass, dns_pass + dns_test, 1)

authority_marker = 'pass "runtime secret inventory derives from schema ownership"\n'
if text.count(authority_marker) != 1:
    raise SystemExit("case-runtime-authority: final marker missing")
extra = r'''

! grep -Fq 'Set SOPS_AGE_KEY_FILE in .env' utilities/backup-run.sh \
    || fail "backup remediation still points operators at repo .env for the Age key"
key_rotate_recipe="$(awk '/^key-rotate:/{p=1; next} p && /^[^[:space:]#].*:/{exit} p{print}' Makefile)"
[[ "$key_rotate_recipe" != *"check-env-readable"* ]] \
    || fail "key-rotate still depends on the repo .env readability guard"
pass "backup and key-rotation guidance no longer leak authoring authority"

storage_loader="$(awk '/^_ss_load_environment\(\)/,/^}/' utilities/setup-storage.sh)"
[[ "$storage_loader" == *"load_authoring_environment"* ]] \
    || fail "setup-storage setup path does not use the explicit authoring loader"
[[ "$storage_loader" != *'load_env_file "${PROJECT_ROOT}/.env"'* ]] \
    || fail "setup-storage still directly falls back to repo .env through load_env_file"
storage_parse_pos="$(grep -n '    _parse_outer_args "$@"' utilities/setup-storage.sh | head -1 | cut -d: -f1)"
storage_load_pos="$(grep -n '    _ss_load_environment' utilities/setup-storage.sh | head -1 | cut -d: -f1)"
[[ -n "$storage_parse_pos" && -n "$storage_load_pos" && "$storage_parse_pos" -lt "$storage_load_pos" ]] \
    || fail "setup-storage must resolve setup/runtime mode before choosing an environment loader"
pass "setup-storage first-install path uses authoring authority without runtime fallback noise"
'''
text = text.replace(authority_marker, authority_marker + extra, 1)
p.write_text(text)
