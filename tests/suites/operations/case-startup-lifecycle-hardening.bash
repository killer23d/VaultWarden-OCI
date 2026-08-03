#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/test-root.bash
source "${SCRIPT_DIR}/../../lib/test-root.bash"
ROOT="${VW_TEST_REPO_ROOT:?VW_TEST_REPO_ROOT was not initialized}"

fail() {
  printf 'FAIL startup lifecycle hardening: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$label"
}

startup=$(<"${ROOT}/startup.sh")

restart_block=$(awk '
  /^restart:/ { capture=1 }
  capture && /^safe-restart:/ { exit }
  capture { print }
' "${ROOT}/Makefile")

assert_contains "$restart_block" '$(call check-docker)' \
  "restart must verify Docker availability"
assert_contains "$restart_block" './startup.sh --force --skip-pull' \
  "restart must preserve the existing compatibility caller"
assert_not_contains "$restart_block" './startup.sh --force ||' \
  "restart must not use a distinct image-updating startup path"

assert_not_contains "$startup" 'docker compose rm -sf' \
  "startup must not remove working containers before Compose recreation"
assert_contains "$startup" 'compose_args+=(--force-recreate)' \
  "forced restart must still request Compose recreation"
assert_not_contains "$startup" 'wait_for_services || true' \
  "critical readiness failures must not be discarded"
assert_contains "$startup" 'wait_for_services || readiness_rc=$?' \
  "critical readiness result must be preserved"
assert_contains "$startup" 'wait_for_optional_service_health()' \
  "optional service health helper must exist"
assert_contains "$startup" 'wait_for_optional_services || true' \
  "Postfix readiness must receive a nonfatal grace period"

postfix_health=$(awk '
  /postfix status/ { capture=1; remaining=7 }
  capture && remaining > 0 { print; remaining-- }
' "${ROOT}/docker-compose.yml.example")
assert_contains "$postfix_health" 'interval: 15s' \
  "Postfix health interval must support startup readiness"
assert_contains "$postfix_health" 'timeout: 5s' \
  "Postfix health timeout must be bounded"
assert_contains "$postfix_health" 'retries: 4' \
  "Postfix health retries must be bounded"
assert_contains "$postfix_health" 'start_period: 20s' \
  "Postfix health start period must match the readiness grace window"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_startup_fixture() {
  local repo="$1"
  mkdir -p "$repo/lib" "$repo/state/config" "$repo/state/secrets"
  cp "$ROOT/startup.sh" "$repo/startup.sh"
  chmod +x "$repo/startup.sh"
  : > "$repo/docker-compose.yml"
  cat > "$repo/.env" <<EOF_ENV
PROJECT_STATE_DIR=$repo/state
PUID=1000
PGID=1000
SOPS_AGE_KEY_FILE=$repo/age-key.txt
EOF_ENV
  : > "$repo/age-key.txt"
  : > "$repo/secrets.yaml"

  cat > "$repo/lib/log.sh" <<'EOF_LIB'
log_info(){ printf 'INFO %s\n' "$*"; }
log_warn(){ printf 'WARN %s\n' "$*"; }
log_error(){ printf 'ERROR %s\n' "$*" >&2; }
log_success(){ printf 'OK %s\n' "$*"; }
EOF_LIB
  cat > "$repo/lib/defaults.sh" <<'EOF_LIB'
_VW_DEFAULT_REQUIRED_COMMANDS=()
_VW_DEFAULT_CRITICAL_SERVICES=()
_VW_DEFAULT_EMAIL_MODES=(auto api direct smtp host)
AGE_KEY_FILE=/etc/vaultwarden/age-key.txt
SECRETS_FILE=secrets.yaml
EOF_LIB
  cat > "$repo/lib/config.sh" <<'EOF_LIB'
load_project_environment(){
  PROJECT_STATE_DIR="$PWD/state"
  PUID=1000
  PGID=1000
  SOPS_AGE_KEY_FILE="$PWD/age-key.txt"
  SECRETS_FILE="$PWD/secrets.yaml"
  export PROJECT_STATE_DIR PUID PGID SOPS_AGE_KEY_FILE SECRETS_FILE
}
_read_env_value(){ printf ''; }
EOF_LIB
  cat > "$repo/lib/common.sh" <<'EOF_LIB'
init_common_lib(){ :; }
require_root(){ :; }
print_project_version(){ printf 'test\n'; }
EOF_LIB
  cat > "$repo/lib/docker.sh" <<'EOF_LIB'
check_docker_available(){ return 0; }
wait_for_service_ready(){ return 0; }
EOF_LIB
  cat > "$repo/lib/crypto.sh" <<'EOF_LIB'
check_age_key_health(){ return 0; }
EOF_LIB
  cat > "$repo/lib/secrets.sh" <<'EOF_LIB'
schema_validate(){ return 0; }
validate_required_secrets(){ return 0; }
export_docker_secrets(){ : > "${SECRET_MARKER:?}"; }
prepare_push_secret_placeholders(){ : > "${PUSH_MARKER:?}"; }
EOF_LIB
  cat > "$repo/lib/storage.sh" <<'EOF_LIB'
check_project_state_ready(){ return 0; }
EOF_LIB
  cat > "$repo/lib/runtime-permissions.sh" <<'EOF_LIB'
check_runtime_state_permissions(){ printf 'PERMISSION_CHECK %s\n' "$*" >> "${CALL_LOG:?}"; return "${PERMISSION_RC:-0}"; }
auto_fix_critical_permissions(){ printf 'PERMISSION_REPAIR\n' >> "${CALL_LOG:?}"; return 0; }
EOF_LIB
  cat > "$repo/lib/operations.sh" <<'EOF_LIB'
operation_acquire(){ return 0; }
operation_release(){ return 0; }
operation_set_phase(){ :; }
EOF_LIB
}

make_docker_stub() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/docker" <<'EOF_DOCKER'
#!/usr/bin/env bash
printf 'DOCKER %s\n' "$*" >> "${CALL_LOG:?}"
case "${1:-}:${2:-}:${3:-}" in
  compose:config:--images)
    printf 'example/vaultwarden:local\nexample/caddy:local\n'
    ;;
  image:inspect:*)
    [[ "${MISSING_IMAGE:-false}" != true ]]
    ;;
esac
EOF_DOCKER
  chmod +x "$bin/docker"
}

run_startup() {
  local repo="$1" out="$2"
  shift 2
  (
    cd "$repo"
    PATH="$TMP/bin:$PATH" \
    CALL_LOG="$TMP/calls.log" \
    SECRET_MARKER="$TMP/secret-created" \
    PUSH_MARKER="$TMP/push-created" \
    "$repo/startup.sh" --background "$@"
  ) >"$out" 2>&1
}

repo="$TMP/repo"
make_startup_fixture "$repo"
make_docker_stub "$TMP/bin"
: > "$TMP/calls.log"
run_startup "$repo" "$TMP/success.out" || {
  cat "$TMP/success.out" >&2
  fail 'ordinary startup failed'
}

[[ -e "$TMP/secret-created" ]] || fail 'ordinary startup did not materialize encrypted secrets'
[[ -e "$TMP/push-created" ]] || fail 'ordinary startup did not materialize push placeholders'
grep -Fq 'PERMISSION_CHECK' "$TMP/calls.log" || fail 'ordinary startup did not validate permissions'
! grep -Fq 'PERMISSION_REPAIR' "$TMP/calls.log" || fail 'ordinary startup repaired permissions'
! grep -Eq 'DOCKER compose pull|DOCKER system prune|DOCKER .* prune|--remove-orphans' "$TMP/calls.log" \
  || fail 'ordinary startup pulled images or pruned Docker resources'
grep -Fq 'DOCKER compose up -d --pull never --no-build' "$TMP/calls.log" \
  || fail 'ordinary startup did not use no-pull/no-build Compose startup'

rm -f "$TMP/secret-created" "$TMP/push-created"
: > "$TMP/calls.log"
if PERMISSION_RC=1 run_startup "$repo" "$TMP/permissions.out"; then
  fail 'startup succeeded with invalid runtime permissions'
fi
grep -Fq 'sudo utilities/repair-permissions.sh' "$TMP/permissions.out" \
  || fail 'permission failure lacked the focused repair command'
! grep -Fq 'DOCKER compose up' "$TMP/calls.log" \
  || fail 'startup attempted Compose up after permission validation failed'

: > "$TMP/calls.log"
if MISSING_IMAGE=true run_startup "$repo" "$TMP/missing-image.out"; then
  fail 'startup succeeded with a required local image missing'
fi
grep -Fq 'Required local image is missing:' "$TMP/missing-image.out" \
  || fail 'missing-image failure was not reported'
grep -Fq 'sudo ./maintenance.sh update' "$TMP/missing-image.out" \
  || fail 'missing-image failure lacked the focused image-maintenance command'
! grep -Fq 'DOCKER compose up' "$TMP/calls.log" \
  || fail 'startup attempted Compose up after image validation failed'

bash -n "${ROOT}/startup.sh" || fail "startup.sh must pass Bash syntax validation"

printf 'PASS startup lifecycle hardening contracts\n'
