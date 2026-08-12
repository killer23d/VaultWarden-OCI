from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path):
    return (ROOT / path).read_text()

def write(path, text):
    (ROOT / path).write_text(text)

def replace_once(path, old, new):
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:80]!r}")
    write(path, text.replace(old, new, 1))

def regex_once(path, pattern, repl):
    text = read(path)
    new, count = re.subn(pattern, repl, text, count=1, flags=re.M | re.S)
    if count != 1:
        raise SystemExit(f"{path}: regex expected one match, found {count}: {pattern}")
    write(path, new)

# Backup: the only normal operational key is the canonical /etc key.
regex_once(
    "utilities/backup-run.sh",
    r'^_resolve_age_key\(\) \{.*?^\}\n\n_default_backup_dir',
    '''_resolve_age_key() {\n    resolve_age_key_path\n}\n\n_default_backup_dir''',
)

# DNS mutation: Cloudflare zone/token data comes only from canonical SOPS state.
regex_once(
    "utilities/maintenance-update-dns.sh",
    r'^# _resolve_cf_token\n.*?^\}\n\n# _resolve_zone_id',
    '''# _resolve_cf_token\n# Cloudflare mutation credentials have one authority: encrypted SOPS state.\n_resolve_cf_token() {\n    local token\n    if token=$(decrypt_secret "caddy_cloudflare_dns_token" 2>/dev/null) && [[ -n "$token" ]]; then\n        printf '%s' "$token"\n        return 0\n    fi\n    log_error "caddy_cloudflare_dns_token could not be resolved from canonical SOPS state"\n    log_error "Fix: ./edit-secrets.sh rotate caddy_cloudflare_dns_token"\n    return 1\n}\n\n# _resolve_zone_id''',
)
regex_once(
    "utilities/maintenance-update-dns.sh",
    r'^# _resolve_zone_id\n.*?^\}\n\n_is_placeholder_value',
    '''# _resolve_zone_id\n# Cloudflare mutation credentials have one authority: encrypted SOPS state.\n_resolve_zone_id() {\n    local zone_id\n    if zone_id=$(decrypt_secret "cloudflare_zone_id" 2>/dev/null) && [[ -n "$zone_id" ]]; then\n        printf '%s' "$zone_id"\n        return 0\n    fi\n    log_error "cloudflare_zone_id could not be resolved from canonical SOPS state"\n    log_error "Fix: ./edit-secrets.sh rotate cloudflare_zone_id"\n    return 1\n}\n\n_is_placeholder_value''',
)
replace_once(
    "utilities/maintenance-update-dns.sh",
    '''SECRET SOURCE PRIORITY:\n    caddy_cloudflare_dns_token — resolved in order:\n        1. decrypt_secret() from encrypted $SECRETS_FILE\n        2. Host file: $CF_TOKEN_FILE or /run/vaultwarden-oci/secrets/caddy_cloudflare_dns_token\n        3. Caddy container: /run/secrets/caddy_cloudflare_dns_token\n\n    DNS_UPDATE_REQUIRED=true or --require-dns makes missing config fail.\n    UPDATE_DNS=false skips cleanly. When UPDATE_DNS is unset, missing or\n    placeholder Cloudflare config logs a warning and exits 0.\n\n    cloudflare_zone_id — resolved in order:\n        1. decrypt_secret() from encrypted $SECRETS_FILE\n        2. Legacy CLOUDFLARE_ZONE_ID shell variable fallback (do not add to .env)\n''',
    '''SECRET SOURCE:\n    caddy_cloudflare_dns_token and cloudflare_zone_id are resolved only from\n    canonical encrypted $SECRETS_FILE through decrypt_secret().\n\n    DNS_UPDATE_REQUIRED=true or --require-dns makes missing config fail.\n    UPDATE_DNS=false skips cleanly. When UPDATE_DNS is unset, missing or\n    placeholder Cloudflare config logs a warning and exits 0.\n''',
)

# Compose v2: fail on non-JSON structured output instead of accepting v1-style output.
replace_once(
    "lib/docker.sh",
    '''    # Guard against non-JSON output (Compose v1, plain-text mode)\n    if ! printf '%s' "$raw_json" | jq -e . >/dev/null 2>&1; then\n        log_debug "get_service_status: non-JSON output from docker compose ps for '$service'; falling back to not_found"\n        echo "not_found"\n        return 0\n    fi\n''',
    '''    if ! printf '%s' "$raw_json" | jq -e . >/dev/null 2>&1; then\n        log_error "docker compose ps did not return structured JSON for '$service'; Docker Compose v2 is required"\n        return 1\n    fi\n''',
)
replace_once(
    "lib/docker.sh",
    '''    # Guard against non-JSON output (Compose v1, plain-text mode)\n    if ! printf '%s' "$raw_json" | jq -e . >/dev/null 2>&1; then\n        log_debug "get_service_health: non-JSON output from docker compose ps for '$service'; falling back to none"\n        echo "none"\n        return 0\n    fi\n''',
    '''    if ! printf '%s' "$raw_json" | jq -e . >/dev/null 2>&1; then\n        log_error "docker compose ps did not return structured JSON for '$service'; Docker Compose v2 is required"\n        return 1\n    fi\n''',
)
replace_once(
    "lib/docker.sh",
    '''check_compose_available() {\n    docker compose version >/dev/null 2>&1\n}\n''',
    '''check_compose_available() {\n    local version\n    version="$(docker compose version --short 2>/dev/null)" || return 1\n    [[ "$version" =~ ^v?2\\. ]] || return 1\n}\n''',
)

# Setup must not accept Docker without the required Compose v2 plugin.
replace_once(
    "utilities/setup-system.sh",
    '''    if command -v docker &>/dev/null && docker info &>/dev/null; then\n        log_info "setup" "Docker already installed: $(docker --version)"\n        return 0\n    fi\n''',
    '''    if command -v docker &>/dev/null && docker info &>/dev/null; then\n        local compose_version=""\n        compose_version="$(docker compose version --short 2>/dev/null || true)"\n        if [[ "$compose_version" =~ ^v?2\\. ]]; then\n            log_info "setup" "Docker already installed: $(docker --version); Compose ${compose_version}"\n            return 0\n        fi\n        log_info "setup" "Docker is present but Docker Compose v2 plugin is missing; installing required plugin"\n    fi\n''',
)
replace_once(
    "utilities/setup-system.sh",
    '''    systemctl enable --now docker\n    log_success "setup" "Docker installed: $(docker --version)"\n}\n''',
    '''    systemctl enable --now docker\n    local compose_version\n    compose_version="$(docker compose version --short 2>/dev/null)" || {\n        log_error "setup" "Docker Compose v2 plugin is unavailable after installation"\n        return 1\n    }\n    [[ "$compose_version" =~ ^v?2\\. ]] || {\n        log_error "setup" "Docker Compose v2 is required; found: ${compose_version}"\n        return 1\n    }\n    log_success "setup" "Docker installed: $(docker --version); Compose ${compose_version}"\n}\n''',
)

# Smoke test inventory follows schema apply/materialization ownership.
replace_once(
    "utilities/smoke-test.sh",
    'source "$SCRIPT_DIR/lib/config.sh"\n',
    'source "$SCRIPT_DIR/lib/config.sh"\nsource "$SCRIPT_DIR/lib/schema.sh"\n',
)
replace_once(
    "utilities/smoke-test.sh",
    '''    local key_file="${SOPS_AGE_KEY_FILE:-${AGE_KEY_FILE:-/etc/vaultwarden/age-key.txt}}"\n''',
    '''    local key_file="/etc/vaultwarden/age-key.txt"\n''',
)
replace_once(
    "utilities/smoke-test.sh",
    '''    local key_file="${SOPS_AGE_KEY_FILE:-}"\n''',
    '''    local key_file="/etc/vaultwarden/age-key.txt"\n''',
)
regex_once(
    "utilities/smoke-test.sh",
    r'''    # All secrets defined in the compose 'secrets:' top-level block\.\n    local required_secrets=\(\n.*?    \)\n''',
    '''    local required_secrets=() key\n    if ! schema_validate; then\n        _check_fail "runtime-secret-inventory" "secrets schema validation failed"\n        return\n    fi\n    while IFS= read -r key; do\n        [[ "$(schema_apply_type_for_key "$key")" == "compose_restart" ]] || continue\n        required_secrets+=("$key")\n    done < <(schema_keys)\n''',
)

# Systemd installation consumes the canonical key; it never copies a checkout key.
replace_once(
    "utilities/setup-systemd.sh",
    '       using ${PROJECT_STATE_DIR}/config/install.env when present, with repository .env as a legacy fallback.\n    5. Copies secrets/keys/age-key.txt -> /etc/vaultwarden/age-key.txt\n',
    '       using ${PROJECT_STATE_DIR}/config/install.env or the installed runtime authority.\n    5. Requires the operational Age key at /etc/vaultwarden/age-key.txt\n',
)
replace_once(
    "utilities/setup-systemd.sh",
    '''    # Install the age key into /etc/vaultwarden/age-key.txt because\n    # ProtectHome=yes makes /home/ubuntu/ inaccessible to service processes.\n    log_info "Installing age key to $AGE_KEY_DEST ..."\n    local age_key_src="$PROJECT_ROOT/secrets/keys/age-key.txt"\n''',
    '''    # The operational Age key is provisioned directly at its canonical path.\n    log_info "Checking canonical age key at $AGE_KEY_DEST ..."\n    local age_key_src="$AGE_KEY_DEST"\n''',
)
# Avoid self-copy; keep the existing validation/remediation branch by making the
# source-present path simply validate permissions.
replace_once(
    "utilities/setup-systemd.sh",
    '''            _run install -m 600 -o root -g root "$age_key_src" "$AGE_KEY_DEST"\n            log_success "Installed age key: $AGE_KEY_DEST"\n''',
    '''            fix_known_path_permissions "$AGE_KEY_DEST"\n            log_success "Canonical age key present: $AGE_KEY_DEST"\n''',
)
replace_once(
    "utilities/setup-systemd.sh",
    '    log_info "  Age key:   $AGE_KEY_DEST  (copied from secrets/keys/age-key.txt)"\n',
    '    log_info "  Age key:   $AGE_KEY_DEST  (canonical operational key)"\n',
)
replace_once(
    "utilities/setup-systemd.sh",
    '        log_error "  Fix: sudo utilities/setup-systemd.sh install  (requires secrets/keys/age-key.txt)"\n',
    '        log_error "  Fix: restore the operational key at $AGE_KEY_DEST, then rerun install"\n',
)

# Restore normal operation always promotes to canonical custody and never rewrites repo .env.
replace_once(
    "utilities/restore-run.sh",
    '    key that decrypts the selected backup. Press Enter to use the operational\n    Age key already configured in .env (SOPS_AGE_KEY_FILE).\n',
    '    key that decrypts the selected backup. Press Enter to use the operational\n    Age key at /etc/vaultwarden/age-key.txt.\n',
)
replace_once(
    "utilities/restore-run.sh",
    '    local OPERATIONAL_SOPS_AGE_KEY_FILE; OPERATIONAL_SOPS_AGE_KEY_FILE="$(get_config_value "SOPS_AGE_KEY_FILE" "secrets/keys/age-key.txt")"\n',
    '    local OPERATIONAL_SOPS_AGE_KEY_FILE="/etc/vaultwarden/age-key.txt"\n',
)
# Rotation block still contains legacy dual-custody operations. Collapse paths and
# env-update targets to the canonical installed authority without changing the
# existing rekey/rollback transaction shape.
text = read("utilities/restore-run.sh")
text = text.replace('$PROJECT_ROOT/secrets/keys/age-key.txt', '/etc/vaultwarden/age-key.txt')
text = text.replace('SOPS_AGE_KEY_FILE updated in .env', 'runtime SOPS authority remains canonical')
# Never rewrite repository .env after restore. Existing installed env updates remain.
text = re.sub(r'^\s*_set_env_var "SOPS_AGE_KEY_FILE" .*?"\$PROJECT_ROOT/\.env".*?\n', '', text, flags=re.M)
write("utilities/restore-run.sh", text)

# Permission/uninstall contracts must not treat checkout key custody as managed state.
for path in ["lib/runtime-permissions.sh", "utilities/uninstall-vaultwarden.sh"]:
    text = read(path)
    text = text.replace('${PROJECT_ROOT}/secrets/keys/age-key.txt', '/etc/vaultwarden/age-key.txt')
    text = text.replace('$PROJECT_ROOT/secrets/keys/age-key.txt', '/etc/vaultwarden/age-key.txt')
    write(path, text)

# Focused authority regression case. Domain-oriented, not PR-number-specific.
test_path = ROOT / "tests/suites/foundation/case-runtime-authority.bash"
test_path.write_text(r'''#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL runtime-authority: $*" >&2; exit 1; }
pass() { echo "PASS runtime-authority: $*"; }

config="$(cat lib/config.sh)"
startup="$(cat startup.sh)"
backup="$(cat utilities/backup-run.sh)"
dns="$(cat utilities/maintenance-update-dns.sh)"
systemd_setup="$(cat utilities/setup-systemd.sh)"
restore="$(cat utilities/restore-run.sh)"
smoke="$(cat utilities/smoke-test.sh)"
docker_lib="$(cat lib/docker.sh)"
setup_system="$(cat utilities/setup-system.sh)"

[[ "$config" == *"load_authoring_environment()"* ]] || fail "authoring loader missing"
[[ "$config" == *"Runtime environment authority is missing."* ]] || fail "runtime missing-authority failure missing"
[[ "$config" != *"Using repository .env — migrate"* ]] || fail "runtime repo .env fallback remains"
[[ "$config" == *"_validate_runtime_env_file"* ]] || fail "runtime env strict validation missing"
pass "runtime and authoring environment authority separated"

for body in "$startup" "$backup" "$systemd_setup"; do
    [[ "$body" != *"secrets/keys/age-key.txt"* ]] || fail "normal production path still references checkout Age key"
done
[[ "$restore" != *'$PROJECT_ROOT/secrets/keys/age-key.txt'* ]] || fail "restore still promotes checkout Age key"
[[ "$restore" != *'_set_env_var "SOPS_AGE_KEY_FILE"'*'$PROJECT_ROOT/.env'* ]] || fail "restore rewrites repo .env key path"
[[ "$startup" == *"/etc/vaultwarden/age-key.txt"* ]] || fail "startup canonical key missing"
[[ "$backup" == *"resolve_age_key_path"* ]] || fail "backup does not use canonical resolver"
pass "normal operational Age custody is canonical"

[[ "$dns" != *"CLOUDFLARE_ZONE_ID"* ]] || fail "DNS legacy zone shell fallback remains"
[[ "$dns" != *"CF_TOKEN_FILE"* ]] || fail "DNS host secret fallback remains"
[[ "$dns" != *"docker compose exec -T caddy"* ]] || fail "DNS container secret fallback remains"
pass "DNS mutation credentials resolve only through SOPS"

[[ "$docker_lib" == *"Docker Compose v2 is required"* ]] || fail "Compose v2 structured-output guard missing"
[[ "$setup_system" == *"Docker Compose v2 plugin is missing"* ]] || fail "setup v2 plugin validation missing"
! grep -R --exclude='*.md' --exclude='case-runtime-authority.bash' -nE '(^|[[:space:]])docker-compose([[:space:]]|$)' lib utilities startup.sh setup.sh >/dev/null || fail "docker-compose executable fallback found"
pass "Docker Compose v2 plugin is the command authority"

[[ "$smoke" == *"schema_apply_type_for_key"* ]] || fail "smoke runtime secret inventory is not schema-driven"
[[ "$smoke" != *"local required_secrets=("* ]] || fail "smoke hard-coded secret inventory remains"
pass "runtime secret inventory derives from schema ownership"
''')

# Register the domain test in the canonical runner.
replace_once(
    "tests/run-tests.sh",
    '    "config-env-core|tests/suites/foundation/case-config-env.bash|core|120"\n',
    '    "config-env-core|tests/suites/foundation/case-config-env.bash|core|120"\n    "runtime-authority|tests/suites/foundation/case-runtime-authority.bash|all|120"\n',
)

# Remove this temporary patch mechanism from the resulting product commit.
(ROOT / ".github/pr8_apply.py").unlink()
(ROOT / ".github/workflows/pr8-apply.yml").unlink()
