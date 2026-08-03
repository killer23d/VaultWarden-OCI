#!/usr/bin/env bash
# Consolidated permissions regression suite.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$*"
}

check_canonical_permission_inventory() (
    set -euo pipefail
    cd "$VW_TEST_REPO_ROOT"

    source lib/log.sh
    source lib/config.sh
    source lib/common.sh
    source lib/runtime-permissions.sh

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    PROJECT_STATE_DIR="$TMP/state"
    PROJECT_ROOT="$TMP/repo"
    SUDO_USER="$(id -un)"
    SUDO_GID="$(id -g)"
    export PROJECT_STATE_DIR PROJECT_ROOT SUDO_USER SUDO_GID

    mkdir -p "$PROJECT_ROOT/secrets/keys" "$PROJECT_STATE_DIR/config" "$PROJECT_STATE_DIR/secrets"

    [[ "$(expected_owner_for_path "$PROJECT_STATE_DIR/config")" == root ]] \
        || fail "state config owner is not root"
    [[ "$(expected_mode_for_path "$PROJECT_STATE_DIR/config")" == 700 ]] \
        || fail "state config mode is not 0700"
    [[ "$(expected_owner_for_path "$PROJECT_STATE_DIR/secrets/secrets.yaml")" == root ]] \
        || fail "persistent secret owner is not root"
    [[ "$(expected_mode_for_path "$PROJECT_STATE_DIR/secrets/secrets.yaml")" == 600 ]] \
        || fail "persistent secret mode is not 0600"
    [[ "$(expected_mode_for_path /run/vaultwarden-oci/secrets/example)" == 444 ]] \
        || fail "runtime secret mode is not 0444"
    [[ "$(expected_mode_for_path "$PROJECT_ROOT/.sops.yaml")" == 644 ]] \
        || fail ".sops.yaml mode is not 0644"

    pass "canonical inventory preserves private configuration and runtime secret modes"
)

check_canonical_permission_inventory

check_systemd_operator_ownership() (
    set -euo pipefail
    cd "$VW_TEST_REPO_ROOT"

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    repo="$TMP/repo"
    state="$TMP/state"
    marker_file="$TMP/chown-called"
    mkdir -p "$repo" "$state"
    printf 'DOMAIN=https://example.invalid\n' > "$repo/.env"
    chmod 600 "$repo/.env"
    original_owner="$(stat -c '%u:%g' "$repo/.env")"

    root_case='set -euo pipefail
cd "$1"
source lib/log.sh
source lib/config.sh
source lib/common.sh
source lib/runtime-permissions.sh
PROJECT_ROOT="$2"
PROJECT_STATE_DIR="$3"
USER=root
unset SUDO_USER
export PROJECT_ROOT PROJECT_STATE_DIR USER
get_real_user() { printf "%s\\n" root; }
chown() { printf "%s\\n" "$*" > "$4"; return 1; }
_vw_runtime_apply_known_path repair "$PROJECT_ROOT/.env" "repository configuration path" >/dev/null
chmod 644 "$PROJECT_ROOT/.env"
_vw_runtime_apply_known_path repair "$PROJECT_ROOT/.env" "repository configuration path" >/dev/null'

    if (( EUID == 0 )); then
        bash -c "$root_case" -- "$VW_TEST_REPO_ROOT" "$repo" "$state" "$marker_file"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo -n env -u SUDO_USER USER=root bash -c "$root_case" -- \
            "$VW_TEST_REPO_ROOT" "$repo" "$state" "$marker_file"
    else
        printf 'SKIP: root/systemd ownership regression requires root or passwordless sudo\n'
        return 0
    fi

    [[ ! -e "$marker_file" ]] \
        || fail "systemd-style repair attempted to chown an operator-owned repository file"
    [[ "$(stat -c '%u:%g' "$repo/.env")" == "$original_owner" ]] \
        || fail "systemd-style repair changed repository file ownership"
    [[ "$(stat -c '%a' "$repo/.env")" == 600 ]] \
        || fail "systemd-style repair did not correct .env mode drift"

    pass "systemd-style repair preserves unresolved operator ownership while enforcing mode"
)

check_systemd_operator_ownership

check_runtime_permission_behavior() (
    set -euo pipefail
    cd "$VW_TEST_REPO_ROOT"

    source lib/log.sh
    source lib/config.sh
    source lib/common.sh
    source lib/runtime-permissions.sh

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    uid="$(id -u)"
    gid="$(id -g)"
    state="$TMP/state"
    repo="$TMP/repo"

    mkdir -p \
        "$state/config" \
        "$state/secrets" \
        "$state/data" \
        "$state/logs/vaultwarden" \
        "$state/logs/postfix" \
        "$state/logs/caddy" \
        "$state/backups/db" \
        "$state/backups/full" \
        "$state/backups/emergency" \
        "$state/caddy/data" \
        "$state/caddy/config" \
        "$repo"
    touch "$state/logs/caddy/access.log" "$state/logs/caddy/security.log"
    chmod 750 "$state" \
        "$state/data" \
        "$state/logs/vaultwarden" \
        "$state/logs/postfix" \
        "$state/logs/caddy" \
        "$state/backups" \
        "$state/backups/db" \
        "$state/backups/full" \
        "$state/backups/emergency" \
        "$state/caddy/data" \
        "$state/caddy/config"
    chmod 640 "$state/logs/caddy/access.log" "$state/logs/caddy/security.log"

    before="$TMP/before"
    after="$TMP/after"
    find "$state" -printf '%P %m %u %g %s\n' | sort > "$before"
    _vw_runtime_manage_tree check "$state/data" "$uid" "$gid" 750 640 "representative state" >/dev/null \
        || fail "check-only rejected a correct representative runtime tree"
    find "$state" -printf '%P %m %u %g %s\n' | sort > "$after"
    cmp -s "$before" "$after" || fail "check-only mode mutated the filesystem"
    pass "check-only mode performs no mutation"

    if (( EUID != 0 )); then
        set +e
        root_output="$(check_runtime_state_permissions "$state" "$uid" "$gid" "$repo" 2>&1)"
        root_rc=$?
        set -e
        [[ "$root_rc" -ne 0 ]] || fail "complete permission check succeeded without root"
        [[ "$root_output" == *"require root for complete inspection"* ]] \
            || fail "non-root complete check did not explain the root requirement"
        pass "complete permission checks require root"
    fi

    required_path="$TMP/missing-required-config"
    set +e
    required_output="$(_vw_runtime_apply_known_path check "$required_path" "required configuration" true 2>&1)"
    required_rc=$?
    set -e
    [[ "$required_rc" -ne 0 ]] || fail "missing required configuration path returned success"
    [[ "$required_output" == *"required managed path"* && "$required_output" == *"missing"* ]] \
        || fail "missing required configuration path was not reported clearly"
    pass "missing required configuration paths fail check mode"

    chmod 777 "$state/data"
    printf 'db\n' > "$state/data/example.db"
    chmod 666 "$state/data/example.db"
    _vw_runtime_manage_tree repair "$state/data" "$uid" "$gid" 750 640 "representative state" >/dev/null \
        || fail "representative runtime repair failed"
    [[ "$(stat -c '%a' "$state/data")" == 750 ]] \
        || fail "representative directory was not repaired to 0750"
    [[ "$(stat -c '%a' "$state/data/example.db")" == 640 ]] \
        || fail "representative file was not repaired to 0640"
    pass "repair corrects representative directory and file modes"

    failed="$TMP/failed"
    mkdir -p "$failed"
    chmod 777 "$failed"
    chown() { return 1; }
    set +e
    failure_output="$(_vw_runtime_manage_tree repair "$failed" 99999 99999 750 640 "forced failure" 2>&1)"
    failure_rc=$?
    set -e
    unset -f chown
    [[ "$failure_rc" -ne 0 ]] || fail "required chown failure returned success"
    [[ "$failure_output" != *"FIXED forced failure"* ]] \
        || fail "success was reported after an uncorrected failure"
    [[ "$failure_output" == *"action: chown failed"* ]] \
        || fail "required chown failure was not reported clearly"
    pass "required permission failure returns nonzero without false success"

    missing_path="$TMP/missing/tree"
    mkdir() { return 1; }
    set +e
    mkdir_output="$(_vw_runtime_manage_tree repair "$missing_path" "$uid" "$gid" 750 640 "mkdir failure" 2>&1)"
    mkdir_rc=$?
    set -e
    unset -f mkdir
    [[ "$mkdir_rc" -ne 0 ]] || fail "required mkdir failure returned success"
    [[ "$mkdir_output" != *"FIXED mkdir failure"* ]] \
        || fail "success was reported after mkdir failure"
    pass "required mkdir failure is fatal and never reported as fixed"

    inspection_tree="$TMP/inspection-failure"
    mkdir -p "$inspection_tree"
    chmod 750 "$inspection_tree"
    find() { return 2; }
    set +e
    inspection_output="$(_vw_runtime_manage_tree check "$inspection_tree" "$uid" "$gid" 750 640 "inspection failure" 2>&1)"
    inspection_rc=$?
    set -e
    unset -f find
    [[ "$inspection_rc" -ne 0 ]] || fail "tree inspection failure returned success"
    [[ "$inspection_output" == *"action: inspection failed"* ]] \
        || fail "tree inspection failure was not reported clearly"
    pass "check-only mode fails closed when a managed tree cannot be inspected"
)

check_runtime_permission_behavior

check_permission_callers_are_thin() (
    set -euo pipefail
    cd "$VW_TEST_REPO_ROOT"

    operator_wrapper="utilities/repair-permissions.sh"
    grep -Fq 'check_runtime_state_permissions' "$operator_wrapper" \
        || fail "check mode does not delegate to the canonical library"
    grep -Fq 'repair_runtime_state_permissions' "$operator_wrapper" \
        || fail "repair mode does not delegate to the canonical library"
    grep -Fq 'sudo utilities/repair-permissions.sh --check' "$operator_wrapper" \
        || fail "operator help does not describe the root-complete check contract"
    if grep -Eq '^[[:space:]]*(chown|chmod|mkdir|touch|install)[[:space:]]' "$operator_wrapper"; then
        fail "operator wrapper still contains permission mutation"
    fi
    grep -Fq 'lib/runtime-permissions.sh' "$operator_wrapper" \
        || fail "operator wrapper does not source the canonical owner"

    common_wrapper="$(awk '/^auto_fix_critical_permissions\(\)/{inside=1} inside{print} inside && /^}/{exit}' lib/common.sh)"
    [[ "$common_wrapper" == *'repair_runtime_state_permissions "$state_dir" "$puid" "$pgid" "$project_root"'* ]] \
        || fail "common compatibility hook does not delegate to canonical repair"
    if grep -Eq '^[[:space:]]*(chown|chmod|mkdir|touch|install|find)[[:space:]]' <<<"$common_wrapper"; then
        fail "common compatibility hook still contains permission mutation"
    fi
    [[ "$common_wrapper" != *'caddy/entrypoint.sh'* ]] \
        || fail "common compatibility hook still performs unrelated executable repair"

    pass "operator and compatibility entry points are thin canonical callers"
)

check_permission_callers_are_thin

check_compose_startup_and_setup_contract() (
    set -euo pipefail
    cd "$VW_TEST_REPO_ROOT"

    compose="docker-compose.yml.example"
    ! grep -Fq 'init-permissions:' "$compose" \
        || fail "Compose still defines init-permissions"
    ! grep -Fq 'condition: service_completed_successfully' "$compose" \
        || fail "Compose still depends on the removed permission init service"
    ! grep -Fq '.permissions-initialized' "$compose" \
        || fail "Compose still contains the obsolete permission sentinel"

    source_line="$(grep -nF 'source "${SCRIPT_DIR}/lib/runtime-permissions.sh"' startup.sh | head -1 | cut -d: -f1)"
    ready_line="$(grep -nF 'check_project_state_ready || exit 1' startup.sh | head -1 | cut -d: -f1)"
    repair_line="$(grep -nF 'auto_fix_critical_permissions "$PROJECT_ROOT" || exit 1' startup.sh | head -1 | cut -d: -f1)"
    secrets_line="$(grep -nF 'prepare_docker_secrets || exit 1' startup.sh | head -1 | cut -d: -f1)"
    services_line="$(grep -nF '_startup_start_services || exit 1' startup.sh | head -1 | cut -d: -f1)"
    [[ -n "$source_line" && -n "$ready_line" && -n "$repair_line" && -n "$secrets_line" && -n "$services_line" ]] \
        || fail "startup permission preparation markers are incomplete"
    (( source_line < ready_line && ready_line < repair_line && repair_line < secrets_line && repair_line < services_line )) \
        || fail "startup does not prepare runtime permissions once before secrets and services"
    ! grep -Eq '^[[:space:]]*(prepare_directories|prepare_log_directories)[[:space:]]*\|\|' startup.sh \
        || fail "startup still invokes legacy runtime directory preparation"
    ! grep -Fq 'enforce_runtime_log_permissions' startup.sh \
        || fail "startup still invokes the broad legacy log permission policy"
    ! grep -Fq 'ensure_caddy_log_permissions' startup.sh \
        || fail "startup still invokes the separate Caddy permission policy"
    ! grep -Fq 'ensure_caddy_log_permissions()' lib/storage.sh \
        || fail "storage library still contains a second Caddy permission implementation"

    setup_body="$(awk '/^setup_directories\(\)/{inside=1} inside{print} inside && /^}/{exit}' utilities/setup-storage.sh)"
    [[ "$setup_body" == *'repair_runtime_state_permissions "$project_state_dir" "$puid" "$pgid" "$PROJECT_ROOT"'* ]] \
        || fail "first-run storage setup does not invoke canonical runtime repair"
    if grep -Eq 'chown[[:space:]]+-R|find .*chmod|ensure_caddy_log_permissions' <<<"$setup_body"; then
        fail "storage setup still contains a second runtime permission implementation"
    fi
    grep -Fq 'check_runtime_state_permissions "$project_state_dir" "$puid" "$pgid" "$PROJECT_ROOT"' utilities/setup-storage.sh \
        || fail "storage verification does not use the canonical check-only path"

    pass "Compose removes init-permissions and host startup/setup use the canonical owner"
)

check_compose_startup_and_setup_contract

printf 'Permission tests passed.\n'
