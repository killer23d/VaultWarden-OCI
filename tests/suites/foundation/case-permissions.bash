#!/usr/bin/env bash
# Consolidated permissions regression suite.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

check_permission_repair_contract() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
cd "$ROOT"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }

TMP_DIR="$(mktemp -d)"
orig_present=0
backup="${TMP_DIR}/sops.yaml.backup"
orig_mode=""
orig_owner=""
orig_group=""
if [[ -e .sops.yaml ]]; then
    orig_present=1
    cp -p .sops.yaml "$backup"
    orig_mode="$(stat -c '%a' .sops.yaml)"
    orig_owner="$(stat -c '%u' .sops.yaml)"
    orig_group="$(stat -c '%g' .sops.yaml)"
fi
cleanup() {
    if [[ "$orig_present" == 1 ]]; then
        if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            sudo cp -p "$backup" .sops.yaml 2>/dev/null || cp -p "$backup" .sops.yaml
            # shellcheck disable=SC2033 # Later test-local mocks intentionally shadow these commands.
            sudo chown "${orig_owner}:${orig_group}" .sops.yaml 2>/dev/null || true
            # shellcheck disable=SC2033 # Later test-local mocks intentionally shadow these commands.
            sudo chmod "$orig_mode" .sops.yaml 2>/dev/null || true
        else
            cp -p "$backup" .sops.yaml 2>/dev/null || true
            chmod "$orig_mode" .sops.yaml 2>/dev/null || true
        fi
    else
        if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            sudo rm -f .sops.yaml 2>/dev/null || rm -f .sops.yaml
        else
            rm -f .sops.yaml 2>/dev/null || true
        fi
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cat > .sops.yaml <<'POLICY'
creation_rules:
  - path_regex: '.*\.yaml$'
    age: "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
POLICY
chmod 0640 .sops.yaml

check_out="${TMP_DIR}/repair-check.out"
if utilities/repair-permissions.sh --check > "$check_out" 2>&1; then
    cat "$check_out" >&2
    fail "repair --check did not detect .sops.yaml mode drift"
fi
grep -Fq 'ERROR .sops.yaml SOPS policy' "$check_out" || { cat "$check_out" >&2; fail "repair --check lacks .sops.yaml error"; }
grep -Fq 'fix: sudo utilities/repair-permissions.sh' "$check_out" || { cat "$check_out" >&2; fail "repair --check lacks repair hint"; }
pass "repair --check detects unreadable .sops.yaml drift"

repair_out="${TMP_DIR}/repair-run.out"
idem_out="${TMP_DIR}/repair-idem.out"
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo utilities/repair-permissions.sh 2>&1 | tee "$repair_out" >/dev/null || { cat "$repair_out" >&2; fail "sudo repair command failed"; }
    [[ "$(stat -c '%a' .sops.yaml)" == "644" ]] || fail ".sops.yaml was not repaired to 0644"
    pass "sudo repair command fixes .sops.yaml to 0644"

    sudo utilities/repair-permissions.sh 2>&1 | tee "$idem_out" >/dev/null || { cat "$idem_out" >&2; fail "idempotent sudo repair failed"; }
    grep -Fq 'OK .sops.yaml SOPS policy' "$idem_out" || { cat "$idem_out" >&2; fail "idempotent repair did not report OK for .sops.yaml"; }
    pass "sudo repair command is idempotent for .sops.yaml"
elif (( EUID == 0 )); then
    utilities/repair-permissions.sh > "$repair_out" 2>&1 || { cat "$repair_out" >&2; fail "root repair command failed"; }
    [[ "$(stat -c '%a' .sops.yaml)" == "644" ]] || fail ".sops.yaml was not repaired to 0644"
    pass "root repair command fixes .sops.yaml to 0644"

    utilities/repair-permissions.sh > "$idem_out" 2>&1 || { cat "$idem_out" >&2; fail "idempotent root repair failed"; }
    grep -Fq 'OK .sops.yaml SOPS policy' "$idem_out" || { cat "$idem_out" >&2; fail "idempotent repair did not report OK for .sops.yaml"; }
    pass "root repair command is idempotent for .sops.yaml"
else
    printf 'SKIP: sudo unavailable; skipping privileged repair execution\n'
fi

# Static safety: SOPS writers leave public policy 0644, while private files stay private.
grep -Fq 'chmod 0644 "$dest"' utilities/setup-secrets.sh || fail "_ss_write_policy_file does not chmod .sops.yaml 0644"
grep -Fq 'chmod 644 "$tmp"' utilities/setup-secrets.sh || fail "_write_sops_config does not stage .sops.yaml 0644"
grep -Fq 'chmod 600 "$age_key_file"' utilities/setup-secrets.sh || fail "repo Age key not kept 0600"
grep -Fq 'install -m 600 -o root -g root "$age_key_file" "$canonical_key"' utilities/setup-secrets.sh || fail "installed Age key not root:root 0600"
grep -Fq 'chmod 600 "$secrets_file"' utilities/setup-secrets.sh || fail "secrets.yaml not kept 0600"
grep -Fq 'install -d -m 700 -o root -g root "/run/vaultwarden-oci/secrets"' utilities/setup-secrets.sh || fail "runtime secrets dir not root:root 0700"
pass "permission contract keeps private files private and .sops.yaml public-readable"

# Diagnostics and command boundary stubs.
grep -Fq 'Recommended repair: sudo utilities/repair-permissions.sh' lib/secrets.sh || fail "ensure_sops_env lacks repair hint"
grep -Fq 'Direct fallback: sudo chmod 0644 .sops.yaml' lib/secrets.sh || fail "ensure_sops_env lacks chmod fallback"

rotate_out="${TMP_DIR}/rotate-stub.out"
if utilities/setup-secrets.sh rotate example > "$rotate_out" 2>&1; then
    cat "$rotate_out" >&2
    fail "setup-secrets rotate stub should fail"
fi
grep -Fq 'sudo ./edit-secrets.sh rotate FIELD' "$rotate_out" || { cat "$rotate_out" >&2; fail "rotate stub lacks sudo guidance"; }

kit_out="${TMP_DIR}/kit-stub.out"
if utilities/setup-secrets.sh export-recovery-kit > "$kit_out" 2>&1; then
    cat "$kit_out" >&2
    fail "setup-secrets export-recovery-kit stub should fail"
fi
grep -Fq 'sudo ./edit-secrets.sh export-recovery-kit' "$kit_out" || { cat "$kit_out" >&2; fail "export-recovery-kit stub lacks sudo guidance"; }
pass "setup-secrets secret-authoring paths provide sudo guidance"

# Drift prevention: storage setup must not recursively chmod root-operated config/secrets state.
! grep -Fq 'find "${project_state_dir}" -type d -exec chmod 750 {} +' utilities/setup-storage.sh || fail "setup-storage still broad-chmods all state directories"
! grep -Fq 'find "${project_state_dir}" -type f -exec chmod 640 {} +' utilities/setup-storage.sh || fail "setup-storage still broad-chmods all state files"
grep -Fq 'Never broad-chmod' utilities/setup-storage.sh || fail "setup-storage lacks sensitive state chmod guard"
pass "setup-storage avoids broad chmod over config/secrets state"

grep -Fq 'install -d -m 0700 -o root -g root "$manifest_dir" "$rendered_state_dir/secrets"' utilities/setup-env.sh || fail "setup-env does not create config/secrets dirs root:root 0700"
grep -Fq 'chown root:root "$tmp" && chmod 0600 "$tmp" && mv "$tmp" "$manifest_file"' utilities/setup-env.sh || fail "setup-env does not stage dr-manifest.env root:root 0600"
grep -Fq 'chmod 0600 "$manifest_file"' utilities/setup-env.sh || fail "setup-env does not enforce dr-manifest.env 0600 after atomic mv"
pass "setup-env creates persistent manifest/private state with root-operated permissions"

grep -Fq '_apply_known_path "${PROJECT_STATE_DIR}/secrets" "persistent secrets directory"' utilities/repair-permissions.sh || fail "repair does not cover persistent secrets dir"
grep -Fq '_apply_known_path "${PROJECT_STATE_DIR}/secrets/secrets.yaml" "persistent secrets.yaml"' utilities/repair-permissions.sh || fail "repair does not cover persistent secrets.yaml"
grep -Fq '_apply_known_path "${PROJECT_STATE_DIR}/config/dr-manifest.env" "DR manifest"' utilities/repair-permissions.sh || fail "repair does not use central contract for dr-manifest.env"
grep -Fq '_apply_known_path /run/vaultwarden-oci/managed-secrets "managed secret reconciliation metadata"' utilities/repair-permissions.sh || fail "repair does not cover managed-secret metadata outside Docker secrets"
grep -Fq 'find /run/vaultwarden-oci/secrets -mindepth 1 -maxdepth 1 -type f -print0' utilities/repair-permissions.sh || fail "repair does not cover runtime secret files"
! grep -Fq '/run/vaultwarden-oci/secrets/.managed-secrets' utilities/repair-permissions.sh || fail "repair must not special-case private metadata inside Docker secrets"
pass "repair fallback covers persistent, runtime, and managed-secret metadata drift through central helpers"

# Fresh-start Caddy config preparation must target the exact bind mount used by
# the runtime service. Otherwise Caddy creates /config/caddy itself at mode 0700
# and the repository's 0750 storage contract immediately reports drift.
caddy_config_mount='- ${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/caddy/config:/config'
caddy_config_mount_count="$(grep -Fc -- "$caddy_config_mount" docker-compose.yml.example || true)"
[[ "$caddy_config_mount_count" -eq 2 ]] || fail "init-permissions and Caddy must share the same /config bind mount target"
! grep -Fq -- '${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/caddy/config:/config/caddy' docker-compose.yml.example || fail "init-permissions still mounts Caddy config one level too deep"
grep -Fq 'mkdir -p /config/caddy' docker-compose.yml.example || fail "init-permissions does not pre-create Caddy /config/caddy storage"
grep -Fq 'chown -R 2000:2000 /data/caddy /config' docker-compose.yml.example || fail "init-permissions does not own the real Caddy config tree"
grep -Fq 'find /config -type d -exec chmod 750 {} +' docker-compose.yml.example || fail "init-permissions does not enforce 0750 on Caddy config directories"
grep -Fq 'find /config -type f -exec chmod 640 {} +' docker-compose.yml.example || fail "init-permissions does not enforce 0640 on Caddy config files"
pass "init-permissions prepares the runtime Caddy /config tree before first start"

# Post-restore runtime permissions: emergency/full archives strip ownership for
# portability, so restore must re-apply target-host service contracts explicitly.
grep -Fq 'repair_runtime_state_permissions()' lib/runtime-permissions.sh || fail "runtime permission library lacks repair helper"
grep -Fq 'Caddy runtime data' lib/runtime-permissions.sh || fail "runtime repair does not cover Caddy data"
grep -Fq 'Caddy runtime config' lib/runtime-permissions.sh || fail "runtime repair does not cover Caddy config"
grep -Fq 'Caddy logs' lib/runtime-permissions.sh || fail "runtime repair does not cover Caddy logs"
grep -Fq 'Removed restored init-permissions sentinel' lib/runtime-permissions.sh || fail "runtime repair does not invalidate restored init-permissions sentinel"
grep -Fq '_source_lib "lib/runtime-permissions.sh"' utilities/restore-run.sh || fail "restore-run does not source runtime permission helper"
grep -Fq 'repair_runtime_state_permissions "$STATE_DIR" "$PUID" "$PGID"' utilities/restore-run.sh || fail "restore-run does not repair runtime state before startup"
grep -Fq '_check_caddy_storage_permissions' utilities/maintenance-health.sh || fail "health check does not detect Caddy storage drift"
grep -Fq 'Caddy runtime data root' utilities/repair-permissions.sh || fail "repair-permissions --check does not report Caddy runtime data drift"
pass "restore/repair/health cover Caddy post-restore runtime permission drift"

)

check_permission_repair_contract
check_caddy_log_permission_helper() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }
log_error(){ :; }
log_info(){ :; }
log_success(){ :; }

declare -A SYNTHETIC_OWNERS=()
REPAIR_CALLS=0
TOUCH_CALLS=0

_maybe_sudo() {
    local command_name="$1"
    shift
    case "$command_name" in
        chown)
            [[ "${1:-}" == "2000:2000" && $# -eq 2 ]] \
                || fail "unexpected Caddy chown invocation: $*"
            SYNTHETIC_OWNERS["$2"]="2000:2000"
            ((REPAIR_CALLS += 1))
            ;;
        chmod)
            command chmod "$@" || return 1
            ((REPAIR_CALLS += 1))
            ;;
        mkdir)
            command mkdir "$@"
            ;;
        touch)
            command touch "$@" || return 1
            ((TOUCH_CALLS += 1))
            ;;
        *)
            fail "unexpected privileged command: $command_name"
            ;;
    esac
}

stat() {
    if [[ "${1:-}" == "-c" ]]; then
        local format="${2:-}" path="${3:-}"
        case "$format" in
            %u:%g) printf '%s\n' "${SYNTHETIC_OWNERS[$path]:-1000:1000}" ;;
            %a) command stat -c '%a' "$path" ;;
            *) command stat "$@" ;;
        esac
    else
        command stat "$@"
    fi
}

unset VAULTWARDEN_STORAGE_LIB_LOADED
export VW_LOG_LIB_LOADED=1
export VAULTWARDEN_DEFAULTS_LOADED=1
# shellcheck source=../lib/storage.sh
source "$ROOT/lib/storage.sh"

log_dir="$TMP/missing/caddy"
ensure_caddy_log_permissions "$log_dir" \
    || fail "Caddy permission helper failed for a missing log tree"
[[ -d "$log_dir" ]] || fail "Caddy log directory was not created"
[[ -f "$log_dir/access.log" ]] || fail "Caddy access log was not created"
[[ -f "$log_dir/security.log" ]] || fail "Caddy security log was not created"
[[ "$(command stat -c '%a' "$log_dir")" == "750" ]] \
    || fail "Caddy log directory mode is not 0750"
for log_file in "$log_dir/access.log" "$log_dir/security.log"; do
    [[ "$(command stat -c '%a' "$log_file")" == "640" ]] \
        || fail "$log_file mode is not 0640"
    [[ "${SYNTHETIC_OWNERS[$log_file]:-}" == "2000:2000" ]] \
        || fail "$log_file ownership was not repaired to 2000:2000"
done
[[ "${SYNTHETIC_OWNERS[$log_dir]:-}" == "2000:2000" ]] \
    || fail "Caddy log directory ownership was not repaired to 2000:2000"
[[ "$TOUCH_CALLS" -eq 2 ]] || fail "missing Caddy logs were not created exactly once"

command chmod 777 "$log_dir"
command chmod 666 "$log_dir/access.log" "$log_dir/security.log"
SYNTHETIC_OWNERS["$log_dir"]="123:456"
SYNTHETIC_OWNERS["$log_dir/access.log"]="123:456"
SYNTHETIC_OWNERS["$log_dir/security.log"]="123:456"
REPAIR_CALLS=0
TOUCH_CALLS=0
ensure_caddy_log_permissions "$log_dir" \
    || fail "Caddy permission helper failed while repairing drift"
[[ "$REPAIR_CALLS" -eq 6 ]] || fail "Caddy drift did not trigger six ownership/mode repairs"
[[ "$TOUCH_CALLS" -eq 0 ]] || fail "existing Caddy logs were touched during repair"

REPAIR_CALLS=0
TOUCH_CALLS=0
ensure_caddy_log_permissions "$log_dir" \
    || fail "idempotent Caddy permission check failed"
[[ "$REPAIR_CALLS" -eq 0 ]] || fail "second Caddy permission invocation repeated repairs"
[[ "$TOUCH_CALLS" -eq 0 ]] || fail "second Caddy permission invocation touched log files"

dry_dir="$TMP/dry-run/caddy"
DRY_RUN=true
REPAIR_CALLS=0
TOUCH_CALLS=0
ensure_caddy_log_permissions "$dry_dir" \
    || fail "Caddy permission dry-run failed"
[[ ! -e "$dry_dir" ]] || fail "Caddy permission dry-run changed the filesystem"
[[ "$REPAIR_CALLS" -eq 0 && "$TOUCH_CALLS" -eq 0 ]] \
    || fail "Caddy permission dry-run invoked mutating commands"
DRY_RUN=false

if ensure_caddy_log_permissions "" >/dev/null 2>&1; then
    fail "Caddy permission helper accepted an empty path"
fi
relative_path="relative-caddy-${RANDOM}"
if ensure_caddy_log_permissions "$relative_path" >/dev/null 2>&1; then
    fail "Caddy permission helper accepted a relative path"
fi
[[ ! -e "$relative_path" ]] || fail "relative Caddy path was created"

pass 'Caddy log permission helper creates, repairs, and remains idempotent'
)

check_caddy_log_permission_helper

check_central_permission_contract() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
cd "$ROOT"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }

source lib/log.sh
source lib/common.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROJECT_STATE_DIR="$TMP/state"
PROJECT_ROOT="$TMP/repo"
SUDO_USER="$(id -un)"
SUDO_GID="$(id -g)"
export PROJECT_STATE_DIR PROJECT_ROOT SUDO_USER SUDO_GID
mkdir -p "$PROJECT_ROOT/secrets/keys" "$PROJECT_STATE_DIR/config" "$PROJECT_STATE_DIR/secrets" "$TMP/etc" "$TMP/run/secrets"

operator="$(get_real_user)"
operator_group="$(id -gn "$operator")"

[[ "$(expected_owner_for_path /etc/vaultwarden/age-key.txt)" == root ]] || fail '/etc age key owner is not root'
[[ "$(expected_group_for_path /etc/vaultwarden/age-key.txt)" == root ]] || fail '/etc age key group is not root'
[[ "$(expected_mode_for_path /etc/vaultwarden/age-key.txt)" == 600 ]] || fail '/etc age key mode is not 600'
pass '/etc/vaultwarden/age-key.txt contract is root:root 0600'

[[ "$(expected_owner_for_path "$PROJECT_ROOT/secrets/keys/age-key.txt")" == "$operator" ]] || fail 'repo age key owner is not operator'
[[ "$(expected_group_for_path "$PROJECT_ROOT/secrets/keys/age-key.txt")" == "$operator_group" ]] || fail 'repo age key group is not operator group'
[[ "$(expected_mode_for_path "$PROJECT_ROOT/secrets/keys/age-key.txt")" == 600 ]] || fail 'repo age key mode is not 600'
pass 'repo-local age key contract is operator-owned 0600'

for p in /etc/vaultwarden/vaultwarden.env /etc/vaultwarden/rclone.conf "$PROJECT_STATE_DIR/config/install.env" "$PROJECT_STATE_DIR/config/dr-manifest.env"; do
    [[ "$(expected_owner_for_path "$p")" == root ]] || fail "$p owner is not root"
    [[ "$(expected_group_for_path "$p")" == root ]] || fail "$p group is not root"
    [[ "$(expected_mode_for_path "$p")" == 600 ]] || fail "$p mode is not 600"
done
pass 'installed env/key config files remain root-owned 0600'

for p in "$PROJECT_ROOT/.env" "$PROJECT_ROOT/secrets/secrets.yaml"; do
    [[ "$(expected_owner_for_path "$p")" == "$operator" ]] || fail "$p owner is not operator"
    [[ "$(expected_mode_for_path "$p")" == 600 ]] || fail "$p mode is not 600"
done
for p in "$PROJECT_STATE_DIR/secrets" "$PROJECT_STATE_DIR/secrets/secrets.yaml"; do
    [[ "$(expected_owner_for_path "$p")" == root ]] || fail "$p owner is not root"
    [[ "$(expected_group_for_path "$p")" == root ]] || fail "$p group is not root"
done
[[ "$(expected_mode_for_path "$PROJECT_STATE_DIR/secrets/secrets.yaml")" == 600 ]] || fail 'persistent secrets.yaml mode is not 0600'
[[ "$(expected_mode_for_path "$PROJECT_STATE_DIR/secrets")" == 700 ]] || fail 'persistent secrets dir mode is not 0700'
! _is_operator_permission_path "$PROJECT_STATE_DIR/secrets" || fail 'persistent secrets dir is still classified as operator path'
! _is_operator_permission_path "$PROJECT_STATE_DIR/secrets/secrets.yaml" || fail 'persistent secrets.yaml is still classified as operator path'
[[ "$(expected_mode_for_path "$PROJECT_ROOT/.sops.yaml")" == 644 ]] || fail '.sops.yaml mode is not 0644'
pass 'repo editable files remain operator-owned and persistent secrets are root-owned'

[[ "$(expected_owner_for_path /run/vaultwarden-oci/managed-secrets)" == root ]] || fail 'managed-secret metadata owner is not root'
[[ "$(expected_group_for_path /run/vaultwarden-oci/managed-secrets)" == root ]] || fail 'managed-secret metadata group is not root'
[[ "$(expected_mode_for_path /run/vaultwarden-oci/managed-secrets)" == 600 ]] || fail 'managed-secret metadata mode is not 0600'
[[ "$(expected_owner_for_path /run/vaultwarden-oci/secrets/example_secret)" == root ]] || fail 'runtime Docker secret file owner is not root'
[[ "$(expected_group_for_path /run/vaultwarden-oci/secrets/example_secret)" == root ]] || fail 'runtime Docker secret file group is not root'
[[ "$(expected_mode_for_path /run/vaultwarden-oci/secrets/example_secret)" == 444 ]] || fail 'runtime Docker secret file mode is not 0444'
[[ "$(expected_mode_for_path /run/vaultwarden-oci/secrets)" == 700 ]] || fail 'runtime Docker secrets dir mode is not 0700'
pass 'managed-secret metadata is outside the Docker secret wildcard contract'

persistent_secret="$PROJECT_STATE_DIR/secrets/secrets.yaml"
printf 'secrets: {}\n' > "$persistent_secret"
chmod 0755 "$PROJECT_STATE_DIR/secrets"
chmod 0644 "$persistent_secret"
if (( EUID == 0 )); then
    fix_known_path_permissions "$persistent_secret"
    fix_known_path_permissions "$PROJECT_STATE_DIR/secrets"
else
    (
        _common_stat_owner(){ printf 'root'; }
        _common_stat_group(){ printf 'root'; }
        fix_known_path_permissions "$persistent_secret"
        fix_known_path_permissions "$PROJECT_STATE_DIR/secrets"
    )
fi
[[ "$(_common_stat_mode "$persistent_secret")" == 600 ]] || fail 'persistent secrets.yaml was not repaired to 0600'
[[ "$(_common_stat_mode "$PROJECT_STATE_DIR/secrets")" == 700 ]] || fail 'persistent secrets dir was not repaired to 0700'
pass 'persistent state secrets are repaired by central helper'

source lib/config.sh
repo_secret="$PROJECT_ROOT/secrets/secrets.yaml"
printf 'repo-stale\n' > "$repo_secret"
printf 'PROJECT_STATE_DIR=%s\n' "$PROJECT_STATE_DIR" > "$PROJECT_STATE_DIR/config/install.env"
chmod 0600 "$PROJECT_STATE_DIR/config/install.env"

if (( EUID != 0 )); then
    set +e
    (
        _VW_CALLING_SCRIPT=maintenance-health.sh
        export _VW_CALLING_SCRIPT
        load_env_file "$PROJECT_STATE_DIR/config/install.env" >/dev/null 2>&1
    )
    health_guard_rc=$?
    set -e
    [[ "$health_guard_rc" -eq 0 ]] || fail 'maintenance-health non-root env load did not reach read-only checks'
    pass 'maintenance-health direct env load is allowed for read-only checks'
fi

SECRETS_FILE="$repo_secret"
export SECRETS_FILE
load_env_file "$PROJECT_STATE_DIR/config/install.env" || fail 'load_env_file failed for persistent secrets resolution regression'
[[ "$SECRETS_FILE" == "$persistent_secret" ]] || fail 'load_env_file did not resolve persistent secrets.yaml for direct health-style callers'
pass 'load_env_file resolves persistent secrets.yaml for direct health-style callers'

required_target="$PROJECT_STATE_DIR/config/install.env"
if (
    _common_stat_owner(){ printf 'wrong-owner'; }
    _common_stat_group(){ printf 'wrong-group'; }
    _common_stat_mode(){ printf '600'; }
    chown(){ return 41; }
    fix_known_path_permissions "$required_target"
) >/dev/null 2>&1; then
    fail 'required chown failure was swallowed'
fi
pass 'required ownership repair failure returns nonzero'

if (
    _common_stat_owner(){ printf 'root'; }
    _common_stat_group(){ printf 'root'; }
    _common_stat_mode(){ printf '644'; }
    chmod(){ return 42; }
    fix_known_path_permissions "$required_target"
) >/dev/null 2>&1; then
    fail 'required chmod failure was swallowed'
fi
pass 'required mode repair failure returns nonzero'

if (
    _common_stat_owner(){ printf 'wrong-owner'; }
    _common_stat_group(){ printf 'wrong-group'; }
    _common_stat_mode(){ printf '644'; }
    chown(){ return 0; }
    chmod(){ return 0; }
    fix_known_path_permissions "$required_target"
) >/dev/null 2>&1; then
    fail 'zero-returning repair with a false postcondition unexpectedly succeeded'
fi
pass 'permission repair re-stats and rejects a false postcondition'

caddy_fixture="$TMP/caddy-fixture"
mkdir -p "$caddy_fixture/caddy"
printf '#!/usr/bin/env bash\n' > "$caddy_fixture/caddy/entrypoint.sh"
chmod 0644 "$caddy_fixture/caddy/entrypoint.sh"
set +e
caddy_failure_output="$(
    (
        chmod(){ return 43; }
        auto_fix_critical_permissions "$caddy_fixture"
    ) 2>&1
)"
caddy_failure_rc=$?
set -e
[[ "$caddy_failure_rc" -ne 0 ]] || fail 'Caddy execute-bit repair failure unexpectedly succeeded'
[[ "$caddy_failure_output" != *'corrected and verified'* ]] \
    || fail 'Caddy execute-bit failure printed a correction success message'
pass 'Caddy execute-bit repair failure is nonzero and truthful'

startup_main="$ROOT/lib/startup-main.sh"
grep -Fq 'validate_critical_permissions || exit 1' "$startup_main" \
    || fail 'ordinary startup does not enforce validation-only permission checks'
validation_line="$(awk '/validate_critical_permissions \|\| exit 1/{print NR; exit}' "$startup_main")"
prepare_line="$(awk '/operation_set_phase "prepare"/{print NR; exit}' "$startup_main")"
start_line="$(awk '/operation_set_phase "start"/{print NR; exit}' "$startup_main")"
[[ -n "$validation_line" && -n "$prepare_line" && -n "$start_line" \
   && "$validation_line" -lt "$prepare_line" && "$validation_line" -lt "$start_line" ]] \
    || fail 'ordinary startup does not validate permissions before ephemeral preparation and service start'
normal_prefix="$(awk '/if \[\[ "\$REPAIR" == "true" \]\]; then/{exit} {print}' "$startup_main")"
! grep -Fq 'repair_critical_permissions' <<< "$normal_prefix" \
    || fail 'ordinary startup reaches permission repair before the explicit --repair branch'
pass 'ordinary startup validates permissions before preparation and reserves repair for --repair'

age_warn_pattern="Age key ownership was .*expected.*ubunt""u"
! grep -RIn "$age_warn_pattern" . --exclude-dir=.git >/tmp/vw-age-warn.$$ || { cat /tmp/vw-age-warn.$$ >&2; rm -f /tmp/vw-age-warn.$$; fail 'stale ubuntu age-key warning found'; }
rm -f /tmp/vw-age-warn.$$
ubuntu_expect_pattern="expected 'ubunt""u:ubuntu'"
! grep -RIn "$ubuntu_expect_pattern" . --exclude-dir=.git >/tmp/vw-ubuntu-expect.$$ || { cat /tmp/vw-ubuntu-expect.$$ >&2; rm -f /tmp/vw-ubuntu-expect.$$; fail 'stale expected ubuntu:ubuntu text found'; }
rm -f /tmp/vw-ubuntu-expect.$$
pass 'stale ubuntu ownership warnings are absent'

)

check_central_permission_contract
