#!/usr/bin/env bash
# Audit and repair known VaultWarden-OCI permission drift.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/config.sh"
source "${PROJECT_ROOT}/lib/common.sh"
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
  PROJECT_STATE_DIR config env/manifest files -> non-world-readable private state
  encrypted secrets.yaml and containing directory -> operator-accessible/private
  /run/vaultwarden-oci/secrets -> root:root 0700
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
load_project_environment >/dev/null 2>&1 || true
SECRETS_FILE="${SECRETS_FILE:-${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/secrets/secrets.yaml}"
PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"

OPERATOR_USER="$(get_real_user 2>/dev/null || printf '%s' "${SUDO_USER:-${USER:-root}}")"
OPERATOR_GROUP="$(id -g -n "$OPERATOR_USER" 2>/dev/null || id -gn 2>/dev/null || printf '%s' "$OPERATOR_USER")"
STATUS=0

_mode_of() { stat -c '%a' "$1" 2>/dev/null || printf 'unknown'; }
_owner_of() { stat -c '%U:%G' "$1" 2>/dev/null || printf 'unknown'; }

_report() {
    local level="$1" label="$2" path="$3" expected="$4" actual="$5" action="$6"
    printf '%s %s\n  path: %s\n  expected: %s\n  actual: %s\n  %s\n' "$level" "$label" "$path" "$expected" "$actual" "$action"
}

_apply_chmod() {
    local mode="$1" path="$2" label="$3" expected actual
    expected="mode $mode"
    [[ -e "$path" ]] || return 0
    actual="mode $(_mode_of "$path"), owner $(_owner_of "$path")"
    if [[ "$(_mode_of "$path")" == "${mode#0}" || "$(_mode_of "$path")" == "$mode" ]]; then
        _report OK "$label" "$path" "$expected" "$actual" "action: none"
        return 0
    fi
    if [[ "$MODE" == "check" ]]; then
        STATUS=1
        _report ERROR "$label" "$path" "$expected" "$actual" "fix: sudo utilities/repair-permissions.sh"
    else
        chmod "$mode" "$path"
        _report FIXED "$label" "$path" "$expected" "$actual" "action: chmod $mode"
    fi
}

_apply_owner_mode() {
    local owner="$1" group="$2" mode="$3" path="$4" label="$5" expected actual ok=true
    [[ -e "$path" ]] || return 0
    expected="owner ${owner}:${group}, mode $mode"
    actual="mode $(_mode_of "$path"), owner $(_owner_of "$path")"
    [[ "$(_owner_of "$path")" == "${owner}:${group}" ]] || ok=false
    [[ "$(_mode_of "$path")" == "${mode#0}" || "$(_mode_of "$path")" == "$mode" ]] || ok=false
    if [[ "$ok" == "true" ]]; then
        _report OK "$label" "$path" "$expected" "$actual" "action: none"
        return 0
    fi
    if [[ "$MODE" == "check" ]]; then
        STATUS=1
        _report ERROR "$label" "$path" "$expected" "$actual" "fix: sudo utilities/repair-permissions.sh"
    else
        chown "${owner}:${group}" "$path"
        chmod "$mode" "$path"
        _report FIXED "$label" "$path" "$expected" "$actual" "action: chown ${owner}:${group}; chmod $mode"
    fi
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
    _apply_chmod 0644 "${PROJECT_ROOT}/.sops.yaml" ".sops.yaml SOPS policy"
else
    _report WARN ".sops.yaml SOPS policy" "${PROJECT_ROOT}/.sops.yaml" "mode 0644 when present" "missing" "action: none"
fi

# Repo/operator-managed private authoring files.
if [[ -d "${PROJECT_ROOT}/secrets" ]]; then
    _apply_owner_mode "$OPERATOR_USER" "$OPERATOR_GROUP" 0700 "${PROJECT_ROOT}/secrets/keys" "repo Age key directory"
fi
_apply_owner_mode "$OPERATOR_USER" "$OPERATOR_GROUP" 0600 "${PROJECT_ROOT}/secrets/keys/age-key.txt" "repo Age private key"
_apply_owner_mode "$OPERATOR_USER" "$OPERATOR_GROUP" 0700 "$(dirname "$SECRETS_FILE")" "encrypted secrets directory"
_apply_owner_mode "$OPERATOR_USER" "$OPERATOR_GROUP" 0600 "$SECRETS_FILE" "encrypted secrets.yaml"

# Installed/root-managed private state.
_apply_owner_mode root root 0700 /etc/vaultwarden "installed config directory"
_apply_owner_mode root root 0600 /etc/vaultwarden/age-key.txt "installed Age private key"
_apply_owner_mode root root 0600 /etc/vaultwarden/vaultwarden.env "installed Vaultwarden env"
_apply_owner_mode root root 0600 /etc/vaultwarden/rclone.conf "installed rclone config"
_apply_owner_mode root root 0600 "${PROJECT_STATE_DIR}/config/install.env" "installed state env"
_apply_not_world "${PROJECT_STATE_DIR}/config/dr-manifest.env" "DR manifest"
_apply_owner_mode root root 0700 /run/vaultwarden-oci/secrets "runtime Docker secrets directory"

# Known recovery kit outputs in the checkout only; no broad filesystem scan.
shopt -s nullglob
for kit in "${PROJECT_ROOT}"/recovery-kit-*.txt "${PROJECT_ROOT}"/recovery-kit-*.zip "${PROJECT_ROOT}"/vaultwarden-recovery-kit-*; do
    [[ -e "$kit" ]] || continue
    _apply_not_world "$kit" "recovery kit output"
done

exit "$STATUS"
