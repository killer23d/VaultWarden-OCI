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
docker_lib="$(cat lib/docker.sh)"
setup_system="$(cat utilities/setup-system.sh)"
backup_resolver="$(awk '/^_resolve_age_key\(\)/,/^}/' utilities/backup-run.sh)"
restore_rotation="$(awk '/^_rotate_age_key\(\)/,/^}/' utilities/restore-run.sh)"
smoke_inventory="$(awk '/^check_docker_secrets_materialized\(\)/,/^}/' utilities/smoke-test.sh)"

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
pass "normal operational Age custody is canonical"

[[ "$dns" != *"CLOUDFLARE_ZONE_ID"* ]] || fail "DNS legacy zone shell fallback remains"
[[ "$dns" != *"CF_TOKEN_FILE"* ]] || fail "DNS host secret fallback remains"
[[ "$dns" != *"docker compose exec -T caddy"* ]] || fail "DNS container secret fallback remains"
pass "DNS mutation credentials resolve only through SOPS"

[[ "$docker_lib" == *"Docker Compose v2 is required"* ]] || fail "Compose v2 structured-output guard missing"
[[ "$setup_system" == *"Docker Compose v2 plugin is missing"* ]] || fail "setup v2 plugin validation missing"
! grep -R --exclude='*.md' --exclude='case-runtime-authority.bash' -nE 'command -v[[:space:]]+docker-compose|(^|[;&|])[[:space:]]*docker-compose[[:space:]]' lib utilities startup.sh setup.sh >/dev/null || fail "docker-compose executable fallback found"
pass "Docker Compose v2 plugin is the command authority"

[[ "$smoke_inventory" == *"schema_validate"* ]] || fail "smoke inventory does not validate schema"
[[ "$smoke_inventory" == *"schema_apply_type_for_key"* ]] || fail "smoke inventory does not derive materialization ownership from schema"
[[ "$smoke_inventory" == *'required_secrets+=("$key")'* ]] || fail "smoke inventory does not collect schema-derived keys"
[[ "$smoke_inventory" == *'done < <(schema_keys)'* ]] || fail "smoke inventory does not enumerate schema keys"
pass "runtime secret inventory derives from schema ownership"
