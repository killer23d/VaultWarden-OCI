#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL runtime-authority: $*" >&2; exit 1; }
pass() { echo "PASS runtime-authority: $*"; }

config="$(cat lib/config.sh)"
startup="$(cat startup.sh)"
dns="$(cat utilities/maintenance-update-dns.sh)"
systemd_setup="$(cat utilities/setup-systemd.sh)"
docker_lib="$(cat lib/docker.sh)"
setup_system="$(cat utilities/setup-system.sh)"
makefile="$(cat Makefile)"
setup_secrets="$(cat utilities/setup-secrets.sh)"
repair_permissions="$(cat utilities/repair-permissions.sh)"
backup_resolver="$(awk '/^_resolve_age_key\(\)/,/^}/' utilities/backup-run.sh)"
restore_rotation="$(awk '/^_rotate_age_key\(\)/,/^}/' utilities/restore-run.sh)"
smoke_inventory="$(awk '/^check_docker_secrets_materialized\(\)/,/^}/' utilities/smoke-test.sh)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/repo" "$tmp/state/config"
printf 'AUTHORING_ONLY=repo-ok\n' > "$tmp/repo/.env"
chmod 600 "$tmp/repo/.env"

(
    export PROJECT_ROOT="$tmp/repo"
    source "$ROOT/lib/config.sh"
    load_authoring_environment >/dev/null
    [[ "${AUTHORING_ONLY:-}" == "repo-ok" ]]
) || fail "repository .env is not usable through the authoring loader"

(
    export PROJECT_ROOT="$tmp/repo"
    export PROJECT_STATE_DIR="$tmp/state"
    export VW_CONFIG_INSTALLED_ENV_FILE="$tmp/missing-installed.env"
    source "$ROOT/lib/config.sh"
    if load_project_environment >/dev/null 2>&1; then exit 1; fi
    [[ -z "${AUTHORING_ONLY:-}" ]]
) || fail "runtime loader fell back to repository .env when runtime authority was missing"

printf 'PROJECT_STATE_DIR=%s\nBROKEN RUNTIME LINE\n' "$tmp/state" > "$tmp/bad-runtime.env"
chmod 600 "$tmp/bad-runtime.env"
(
    export PROJECT_ROOT="$tmp/repo"
    export PROJECT_STATE_DIR="$tmp/state"
    export VW_CONFIG_INSTALLED_ENV_FILE="$tmp/bad-runtime.env"
    source "$ROOT/lib/config.sh"
    ! load_project_environment >/dev/null 2>&1
) || fail "malformed runtime environment was accepted"

printf 'PROJECT_STATE_DIR=%s\nRUNTIME_ONLY=installed-ok\n' "$tmp/state" > "$tmp/state/config/install.env"
chmod 600 "$tmp/state/config/install.env"
(
    export PROJECT_ROOT="$tmp/repo"
    export PROJECT_STATE_DIR="$tmp/state"
    export VW_CONFIG_INSTALLED_ENV_FILE="$tmp/missing-installed.env"
    source "$ROOT/lib/config.sh"
    load_project_environment >/dev/null
    [[ "${RUNTIME_ONLY:-}" == "installed-ok" ]]
    [[ "${SOPS_AGE_KEY_FILE:-}" == "/etc/vaultwarden/age-key.txt" ]]
) || fail "persistent runtime authority or canonical Age-key override failed"
pass "authoring and strict runtime environment behavior"

custom_state="$tmp/custom-state"
mkdir -p "$custom_state/config"
printf 'PROJECT_STATE_DIR=%s\nCUSTOM_RUNTIME_ONLY=custom-state-ok\n' "$custom_state" > "$custom_state/config/install.env"
chmod 600 "$custom_state/config/install.env"
(
    export PROJECT_ROOT="$tmp/repo"
    unset PROJECT_STATE_DIR
    export VW_CONFIG_INSTALLED_ENV_FILE="$tmp/missing-custom-installed.env"
    source "$ROOT/lib/config.sh"
    if load_project_environment >/dev/null 2>&1; then exit 1; fi
    [[ -z "${CUSTOM_RUNTIME_ONLY:-}" ]]
) || fail "runtime loader auto-discovered a non-default persistent state path without an explicit locator"
(
    export PROJECT_ROOT="$tmp/repo"
    export PROJECT_STATE_DIR="$custom_state"
    export VW_CONFIG_INSTALLED_ENV_FILE="$tmp/missing-custom-installed.env"
    source "$ROOT/lib/config.sh"
    load_project_environment >/dev/null
    [[ "${PROJECT_STATE_DIR:-}" == "$custom_state" ]]
    [[ "${CUSTOM_RUNTIME_ONLY:-}" == "custom-state-ok" ]]
) || fail "explicit PROJECT_STATE_DIR did not recover custom persistent runtime authority when installed env was missing"
pass "custom persistent runtime fallback requires an explicit state locator when installed env is missing"

[[ "$config" == *"load_authoring_environment()"* ]] || fail "authoring loader missing"
[[ "$config" == *"Runtime environment authority is missing."* ]] || fail "runtime missing-authority failure missing"
[[ "$config" != *"Using repository .env — migrate"* ]] || fail "runtime repo .env fallback remains"
[[ "$config" == *"_validate_runtime_env_file"* ]] || fail "runtime env strict validation missing"
pass "runtime and authoring environment authority separated"

[[ "$startup" != *"secrets/keys/age-key.txt"* ]] || fail "startup still references checkout Age key"
[[ "$systemd_setup" != *"secrets/keys/age-key.txt"* ]] || fail "systemd install still references checkout Age key"
[[ "$backup_resolver" != *"secrets/keys/age-key.txt"* ]] || fail "backup key resolution still accepts checkout Age key"
[[ "$backup_resolver" == *"resolve_age_key_path"* ]] || fail "backup does not use canonical resolver"
[[ "$restore_rotation" != *"secrets/keys/age-key.txt"* ]] || fail "restore rotation still promotes checkout Age key"
[[ "$restore_rotation" != *'$PROJECT_ROOT/.env'* ]] || fail "restore rotation still rewrites repo .env"
[[ "$startup" == *"/etc/vaultwarden/age-key.txt"* ]] || fail "startup canonical key missing"
[[ "$systemd_setup" == *"/etc/vaultwarden/age-key.txt"* ]] || fail "systemd canonical key missing"
[[ "$setup_secrets" == *'local AGE_KEY_FILE="/etc/vaultwarden/age-key.txt"'* ]] || fail "normal secrets setup does not pin canonical Age key"
[[ "$setup_secrets" != *'local AGE_KEY_FILE="${AGE_KEY_FILE:-/etc/vaultwarden/age-key.txt}"'* ]] || fail "normal secrets setup still accepts an alternate operational Age key"
pass "normal operational Age custody is canonical"

[[ "$dns" != *"CLOUDFLARE_ZONE_ID"* ]] || fail "DNS legacy zone shell fallback remains"
[[ "$dns" != *"CF_TOKEN_FILE"* ]] || fail "DNS host secret fallback remains"
[[ "$dns" != *"docker compose exec -T caddy"* ]] || fail "DNS container secret fallback remains"
[[ "$dns" == *'decrypt_secret "cloudflare_zone_id"'* ]] || fail "DNS zone does not use canonical SOPS resolver"
[[ "$dns" == *'decrypt_secret "caddy_cloudflare_dns_token"'* ]] || fail "DNS token does not use canonical SOPS resolver"
pass "DNS mutation credentials resolve only through SOPS"


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
PUID=1000
PGID=1000
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

mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<'EOF_DOCKER'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-} ${3:-}" == "compose version --short" ]]; then
    printf '%s\n' "${FAKE_COMPOSE_VERSION:-1.29.2}"
    exit 0
fi
exit 1
EOF_DOCKER
chmod +x "$tmp/bin/docker"
(
    PATH="$tmp/bin:$PATH"
    export FAKE_COMPOSE_VERSION=1.29.2
    source "$ROOT/lib/docker.sh"
    ! check_compose_available
) || fail "Compose v1 version was accepted"
(
    PATH="$tmp/bin:$PATH"
    export FAKE_COMPOSE_VERSION=2.40.0
    source "$ROOT/lib/docker.sh"
    check_compose_available
) || fail "Compose v2 version was rejected"
[[ "$docker_lib" == *"Docker Compose v2 is required"* ]] || fail "Compose v2 structured-output guard missing"
[[ "$setup_system" == *"Docker Compose v2 plugin is missing"* ]] || fail "setup v2 plugin validation missing"
[[ "$makefile" == *'DOCKER_COMP          := docker compose'* ]] || fail "Makefile does not use docker compose as its command authority"
[[ "$makefile" != *'echo "docker-compose"'* ]] || fail "Makefile still contains a Compose v1 executable fallback"
! grep -R --exclude='*.md' --exclude='case-runtime-authority.bash' -nE 'command -v[[:space:]]+docker-compose|(^|[;&|])[[:space:]]*docker-compose[[:space:]]' lib utilities startup.sh setup.sh Makefile >/dev/null || fail "docker-compose executable fallback found"
pass "Docker Compose v2 plugin is the command authority"

load_pos="$(grep -n 'load_project_environment' utilities/repair-permissions.sh | head -1 | cut -d: -f1)"
lock_pos="$(grep -n 'operation_acquire' utilities/repair-permissions.sh | head -1 | cut -d: -f1)"
repair_pos="$(grep -n 'repair_runtime_state_permissions' utilities/repair-permissions.sh | head -1 | cut -d: -f1)"
[[ -n "$load_pos" && -n "$lock_pos" && -n "$repair_pos" && "$load_pos" -lt "$lock_pos" && "$load_pos" -lt "$repair_pos" ]] || fail "permission repair can mutate before runtime authority resolves"
[[ "$repair_permissions" == *"refusing live repair without canonical runtime environment authority"* ]] || fail "permission repair fail-closed diagnostic missing"
pass "permission repair resolves authority before mutation"

[[ "$smoke_inventory" == *"schema_validate"* ]] || fail "smoke inventory does not validate schema"
[[ "$smoke_inventory" == *"schema_apply_type_for_key"* ]] || fail "smoke inventory does not derive materialization ownership from schema"
[[ "$smoke_inventory" == *'required_secrets+=("$key")'* ]] || fail "smoke inventory does not collect schema-derived keys"
[[ "$smoke_inventory" == *'done < <(schema_keys)'* ]] || fail "smoke inventory does not enumerate schema keys"
pass "runtime secret inventory derives from schema ownership"


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
storage_metadata_pos="$(grep -n '    _ss_dispatch_metadata "$@"' utilities/setup-storage.sh | head -1 | cut -d: -f1)"
storage_load_pos="$(grep -n '    _ss_load_environment' utilities/setup-storage.sh | head -1 | cut -d: -f1)"
storage_parse_pos="$(grep -n '    _parse_outer_args "$@"' utilities/setup-storage.sh | head -1 | cut -d: -f1)"
[[ -n "$storage_metadata_pos" && -n "$storage_load_pos" && -n "$storage_parse_pos" && "$storage_metadata_pos" -lt "$storage_load_pos" && "$storage_load_pos" -lt "$storage_parse_pos" ]] || fail "setup-storage must resolve mode metadata, load mode-appropriate defaults, then let CLI parsing win"
pass "setup-storage first-install path uses authoring authority without runtime fallback noise"
