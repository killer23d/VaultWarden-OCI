#!/usr/bin/env bash
# Audit and repair known VaultWarden-OCI permission drift.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/config.sh"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/lib/runtime-permissions.sh"
init_common_lib "$0"

MODE="repair"
case "${1:-}" in
    --check|--dry-run) MODE="check"; shift ;;
    --help|-h)
        cat <<HELP
VaultWarden-OCI permission repair

USAGE:
    sudo utilities/repair-permissions.sh        Repair known permission drift
    utilities/repair-permissions.sh --check     Report drift without changing files
    sudo utilities/repair-permissions.sh --dry-run
    utilities/repair-permissions.sh --help

Checks/repairs explicit project paths only:
  .sops.yaml -> 0644 (public SOPS policy/Age recipients; owner preserved)
  repo Age key -> operator-owned 0600 when present
  /etc/vaultwarden and installed key/env/rclone files -> root:root private
  PROJECT_STATE_DIR config/secrets env/manifest files -> root:root private state
  encrypted persistent secrets.yaml and containing directory -> root:root private state
  /run/vaultwarden-oci/secrets and files inside -> root:root runtime secrets
  PROJECT_STATE_DIR/caddy data/config paths -> UID/GID 2000, Caddy-writable
  PROJECT_STATE_DIR/logs/caddy -> UID/GID 2000, Caddy-writable
  known recovery-kit outputs under the project root -> not world-readable

Does not recursively chmod broad directories and never makes private keys,
env files, encrypted secrets, backups, or recovery kits world-readable.
HELP
        exit 0 ;;
    "") ;;
    *) echo "ERROR unknown option: $1" >&2; exit 2 ;;
esac

if [[ "$MODE" == "repair" && $EUID -ne 0 ]]; then
    echo "ERROR repair requires root: sudo utilities/repair-permissions.sh" >&2
    exit 1
fi

# Best effort: load environment if present; continue with defaults otherwise.
if ! load_project_environment >/dev/null 2>&1; then
    log_warn "repair-permissions: could not load project environment; checking default paths only"
fi
SECRETS_FILE="${SECRETS_FILE:-${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/secrets/secrets.yaml}"
PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"

PUID="${PUID:-$(get_config_value "PUID" "" 2>/dev/null || true)}"
PGID="${PGID:-$(get_config_value "PGID" "" 2>/dev/null || true)}"
PUID="${PUID//$'\r'/}"; PUID="${PUID%%[[:space:]#]*}"; PUID="${PUID//[[:space:]]/}"
PGID="${PGID//$'\r'/}"; PGID="${PGID%%[[:space:]#]*}"; PGID="${PGID//[[:space:]]/}"

STATUS=0

_mode_of() { stat -c '%a' "$1" 2>/dev/null || printf 'unknown'; }
_owner_of() { stat -c '%U:%G' "$1" 2>/dev/null || printf 'unknown'; }

_report() {
    local level="$1" label="$2" path="$3" expected="$4" actual="$5" action="$6"
    printf '%s %s\n  path: %s\n  expected: %s\n  actual: %s\n  %s\n' "$level" "$label" "$path" "$expected" "$actual" "$action"
}

_apply_known_path() {
    local path="$1" label="$2" owner group mode expected actual ok=true
    [[ -e "$path" ]] || return 0
    owner="$(expected_owner_for_path "$path")" || return 0
    group="$(expected_group_for_path "$path")" || return 0
    mode="$(expected_mode_for_path "$path")" || return 0
    expected="owner ${owner}:${group}, mode $mode"
    actual="mode $(_mode_of "$path"), owner $(_owner_of "$path")"
    [[ "$(_owner_of "$path")" == "${owner}:${group}" ]] || ok=false
    [[ "$(_mode_of "$path")" == "$mode" ]] || ok=false
    if [[ "$ok" == "true" ]]; then
        _report OK "$label" "$path" "$expected" "$actual" "action: none"
        return 0
    fi
    if [[ "$MODE" == "check" ]]; then
        STATUS=1
        _report ERROR "$label" "$path" "$expected" "$actual" "fix: sudo utilities/repair-permissions.sh"
    else
        fix_known_path_permissions "$path"
        _report FIXED "$label" "$path" "$expected" "$actual" "action: fix_known_path_permissions"
    fi
}

_apply_numeric_path() {
    local path="$1" label="$2" owner="$3" group="$4" mode="$5" expected actual ok=true
    [[ -e "$path" ]] || return 0
    expected="owner ${owner}:${group}, mode $mode"
    actual="mode $(_mode_of "$path"), owner $(stat -c '%u:%g' "$path" 2>/dev/null || printf 'unknown')"
    [[ "$(stat -c '%u:%g' "$path" 2>/dev/null || printf 'unknown')" == "${owner}:${group}" ]] || ok=false
    [[ "$(_mode_of "$path")" == "$mode" ]] || ok=false
    if [[ "$ok" == "true" ]]; then
        _report OK "$label" "$path" "$expected" "$actual" "action: none"
        return 0
    fi
    if [[ "$MODE" == "check" ]]; then
        STATUS=1
        _report ERROR "$label" "$path" "$expected" "$actual" "fix: sudo utilities/repair-permissions.sh"
    else
        chown "${owner}:${group}" "$path" 2>/dev/null || true
        chmod "$mode" "$path" 2>/dev/null || true
        _report FIXED "$label" "$path" "$expected" "$actual" "action: chown/chmod"
    fi
}

_apply_caddy_check_paths() {
    _apply_numeric_path "${PROJECT_STATE_DIR}/caddy/data" "Caddy runtime data root" 2000 2000 750
    _apply_numeric_path "${PROJECT_STATE_DIR}/caddy/config" "Caddy runtime config root" 2000 2000 750
    _apply_numeric_path "${PROJECT_STATE_DIR}/logs/caddy" "Caddy log directory" 2000 2000 750
    _apply_numeric_path "${PROJECT_STATE_DIR}/logs/caddy/access.log" "Caddy access log" 2000 2000 640
    _apply_numeric_path "${PROJECT_STATE_DIR}/logs/caddy/security.log" "Caddy security log" 2000 2000 640
}

_apply_not_world() {
    local path="$1" label="$2" mode perm_int new_mode actual
    [[ -e "$path" ]] || return 0
    mode="$(_mode_of "$path")"
    actual="mode $mode, owner $(_owner_of "$path")"
    [[ "$mode" == "unknown" ]] && { _report WARN "$label" "$path" "not world-readable/writable" "$actual" "action: inspect manually"; return 0; }
    perm_int=$((8#$mode))
    if (( (perm_int & 0007) == 0 )); then
        _report OK "$label" "$path" "not world-readable/writable" "$actual" "action: none"
        return 0
    fi
    new_mode=$(printf '%03o' $((perm_int & 0770)))
    if [[ "$MODE" == "check" ]]; then
        STATUS=1
        _report ERROR "$label" "$path" "not world-readable/writable" "$actual" "fix: sudo utilities/repair-permissions.sh"
    else
        chmod "$new_mode" "$path"
        _report FIXED "$label" "$path" "not world-readable/writable" "$actual" "action: chmod $new_mode"
    fi
}

# Public metadata: operator-readable, owner preserved.
if [[ -e "${PROJECT_ROOT}/.sops.yaml" ]]; then
    _apply_known_path "${PROJECT_ROOT}/.sops.yaml" ".sops.yaml SOPS policy"
else
    _report WARN ".sops.yaml SOPS policy" "${PROJECT_ROOT}/.sops.yaml" "mode 0644 when present" "missing" "action: none"
fi

# Repo/operator-managed private authoring files.
_apply_known_path "${PROJECT_ROOT}/secrets/keys/age-key.txt" "repo Age private key"

# Installed/root-managed private state.
_apply_known_path /etc/vaultwarden "installed config directory"
_apply_known_path /etc/vaultwarden/age-key.txt "installed Age private key"
_apply_known_path /etc/vaultwarden/vaultwarden.env "installed Vaultwarden env"
_apply_known_path /etc/vaultwarden/rclone.conf "installed rclone config"
_apply_known_path "${PROJECT_STATE_DIR}/config" "state config directory"
_apply_known_path "${PROJECT_STATE_DIR}/config/install.env" "installed state env"
_apply_known_path "${PROJECT_STATE_DIR}/config/dr-manifest.env" "DR manifest"
_apply_known_path "${PROJECT_STATE_DIR}/secrets" "persistent secrets directory"
_apply_known_path "${PROJECT_STATE_DIR}/secrets/secrets.yaml" "persistent secrets.yaml"
_apply_known_path /run/vaultwarden-oci/secrets "runtime Docker secrets directory"
if [[ -d /run/vaultwarden-oci/secrets ]]; then
    while IFS= read -r -d '' runtime_secret; do
        _apply_known_path "$runtime_secret" "runtime Docker secret file"
    done < <(find /run/vaultwarden-oci/secrets -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
fi

if [[ "$MODE" == "check" ]]; then
    _apply_caddy_check_paths
elif [[ -d "$PROJECT_STATE_DIR" ]]; then
    if ! repair_runtime_state_permissions "$PROJECT_STATE_DIR" "$PUID" "$PGID"; then
        STATUS=1
        _report WARN "runtime state permissions" "$PROJECT_STATE_DIR" "known service-specific contract" "repair reported warnings" "action: inspect output above"
    fi
else
    _report OK "runtime state permissions" "$PROJECT_STATE_DIR" "installed state directory when present" "state directory missing; skipped" "action: none"
fi

# Known recovery kit outputs in the checkout only; no broad filesystem scan.
shopt -s nullglob
for kit in "${PROJECT_ROOT}"/recovery-kit-*.txt "${PROJECT_ROOT}"/recovery-kit-*.zip "${PROJECT_ROOT}"/vaultwarden-recovery-kit-*; do
    [[ -e "$kit" ]] || continue
    _apply_not_world "$kit" "recovery kit output"
done

exit "$STATUS"
