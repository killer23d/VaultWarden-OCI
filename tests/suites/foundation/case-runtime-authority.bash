#!/usr/bin/env bash
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
