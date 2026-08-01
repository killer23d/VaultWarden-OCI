# shellcheck shell=bash

# Public-entrypoint fixture. It keeps startup.sh intact while replacing its
# libraries and external commands with observable, non-host-mutating stubs.
FIXTURE="$TMP/startup-repo"
mkdir -p "$FIXTURE/lib" "$FIXTURE/utilities" "$FIXTURE/caddy" "$FIXTURE/state"
cp "$ROOT/startup.sh" "$FIXTURE/startup.sh"
if compgen -G "$ROOT/lib/startup-*.sh" >/dev/null; then
  cp "$ROOT"/lib/startup-*.sh "$FIXTURE/lib/"
fi
printf 'DOMAIN=vault.example.com\n' > "$FIXTURE/.env"
printf 'services: {}\n' > "$FIXTURE/docker-compose.yml"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE/caddy/entrypoint.sh"
chmod 0755 "$FIXTURE/startup.sh" "$FIXTURE/caddy/entrypoint.sh"

INVOCATIONS="$TMP/startup-invocations.log"
OUTPUT="$TMP/startup-output.log"
: > "$INVOCATIONS"

cat > "$FIXTURE/lib/log.sh" <<'EOF_LOG'
log_info(){ printf 'INFO %s\n' "$*"; }
log_warn(){ printf 'WARN %s\n' "$*" >&2; }
log_error(){ printf 'ERROR %s\n' "$*" >&2; }
log_success(){ printf 'SUCCESS %s\n' "$*"; }
log_hint(){ printf 'HINT %s\n' "$*" >&2; }
EOF_LOG
cat > "$FIXTURE/lib/defaults.sh" <<'EOF_DEFAULTS'
readonly _VW_DEFAULT_STATE_DIR="${VW_TEST_STATE_DIR:?}"
readonly _VW_DEFAULT_PUID=0
readonly _VW_DEFAULT_PGID=0
readonly -a _VW_DEFAULT_LOG_SERVICES=(vaultwarden caddy postfix)
readonly -a _VW_DEFAULT_CRITICAL_SERVICES=(vaultwarden caddy)
readonly -a _VW_DEFAULT_EMAIL_MODES=(auto api smtp direct host)
readonly -a _VW_DEFAULT_REQUIRED_COMMANDS=(docker python3)
EOF_DEFAULTS
cat > "$FIXTURE/lib/config.sh" <<'EOF_CONFIG'
load_project_environment(){
  PROJECT_STATE_DIR="${VW_TEST_STATE_DIR:?}"
  DOMAIN="vault.example.com"
  DATA_VOLUME_DEVICE=""
  DATA_VOLUME_MOUNT="/mnt/vw-data"
  SOPS_AGE_KEY_FILE="${VW_TEST_STATE_DIR}/age-key.txt"
  SECRETS_FILE="${VW_TEST_STATE_DIR}/secrets.yaml"
  AGE_KEY_FILE="$SOPS_AGE_KEY_FILE"
  export PROJECT_STATE_DIR DOMAIN DATA_VOLUME_DEVICE DATA_VOLUME_MOUNT SOPS_AGE_KEY_FILE SECRETS_FILE AGE_KEY_FILE
}
get_config_value(){ case "$1" in PUID|PGID) printf '0';; BACKUP_DIR) printf '%s/backups' "${VW_TEST_STATE_DIR:?}";; *) printf '%s' "${2:-}";; esac; }
_read_env_value(){ :; }
EOF_CONFIG
cat > "$FIXTURE/lib/common.sh" <<'EOF_COMMON'
init_common_lib(){ :; }
require_root(){ :; }
is_root(){ return 0; }
_maybe_sudo(){ "$@"; }
print_project_version(){ printf 'VaultWarden-OCI test\n'; }
auto_fix_critical_permissions(){
  printf 'permission-repair\n' >> "${VW_TEST_INVOCATION_LOG:?}"
  [[ "${VW_TEST_FAIL_PERMISSION_REPAIR:-0}" != "1" ]]
}
EOF_COMMON
cat > "$FIXTURE/lib/docker.sh" <<'EOF_DOCKER_LIB'
check_docker_available(){ return 0; }
wait_for_service_ready(){ return 0; }
EOF_DOCKER_LIB
cat > "$FIXTURE/lib/crypto.sh" <<'EOF_CRYPTO'
check_age_key_health(){ return 0; }
EOF_CRYPTO
cat > "$FIXTURE/lib/secrets.sh" <<'EOF_SECRETS'
schema_validate(){ return 0; }
validate_required_secrets(){ return 0; }
export_docker_secrets(){ printf 'export-secrets\n' >> "${VW_TEST_INVOCATION_LOG:?}"; return 0; }
prepare_push_secret_placeholders(){ printf 'prepare-push-placeholders\n' >> "${VW_TEST_INVOCATION_LOG:?}"; return 0; }
EOF_SECRETS
cat > "$FIXTURE/lib/storage.sh" <<'EOF_STORAGE'
check_project_state_ready(){ return 0; }
ensure_caddy_log_permissions(){ printf 'repair-caddy-logs\n' >> "${VW_TEST_INVOCATION_LOG:?}"; return 0; }
EOF_STORAGE
cat > "$FIXTURE/lib/runtime-permissions.sh" <<'EOF_PERMISSIONS'
repair_runtime_state_permissions(){ printf 'repair-runtime-state\n' >> "${VW_TEST_INVOCATION_LOG:?}"; return 0; }
enforce_runtime_log_permissions(){ printf 'repair-runtime-logs\n' >> "${VW_TEST_INVOCATION_LOG:?}"; return 0; }
EOF_PERMISSIONS
cat > "$FIXTURE/lib/operations.sh" <<'EOF_OPERATIONS'
operation_acquire(){ printf 'operation-acquire:%s\n' "$*" >> "${VW_TEST_INVOCATION_LOG:?}"; return 0; }
operation_set_phase(){ printf 'phase:%s\n' "$*" >> "${VW_TEST_INVOCATION_LOG:?}"; return 0; }
operation_release(){ printf 'operation-release:%s\n' "$*" >> "${VW_TEST_INVOCATION_LOG:?}"; return 0; }
EOF_OPERATIONS

cat > "$FIXTURE/utilities/repair-permissions.sh" <<'EOF_REPAIR_PERMS'
#!/usr/bin/env bash
if [[ "${1:-}" == "--check" ]]; then
  printf 'permission-check:%s
' "$*" >> "${VW_TEST_INVOCATION_LOG:?}"
  [[ "${VW_TEST_PERMISSION_DRIFT:-0}" != "1" ]]
  exit $?
fi
printf 'permission-repair
' >> "${VW_TEST_INVOCATION_LOG:?}"
[[ "${VW_TEST_FAIL_PERMISSION_REPAIR:-0}" != "1" ]]
EOF_REPAIR_PERMS
cat > "$FIXTURE/utilities/setup-firewall.sh" <<'EOF_FIREWALL'
#!/usr/bin/env bash
printf 'nat-repair
' >> "${VW_TEST_INVOCATION_LOG:?}"
[[ "${VW_TEST_FAIL_NAT_REPAIR:-0}" != "1" ]]
EOF_FIREWALL
cat > "$FIXTURE/utilities/maintenance-update-dns.sh" <<'EOF_DNS'
#!/usr/bin/env bash
printf 'dns-repair
' >> "${VW_TEST_INVOCATION_LOG:?}"
[[ "${VW_TEST_FAIL_DNS_REPAIR:-0}" != "1" ]]
EOF_DNS
cat > "$FIXTURE/utilities/maintenance-health.sh" <<'EOF_HEALTH'
#!/usr/bin/env bash
exit 0
EOF_HEALTH
chmod 0755 "$FIXTURE/utilities/"*.sh
