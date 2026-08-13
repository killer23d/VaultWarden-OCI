#!/usr/bin/env bash
# Check or repair the repository-managed runtime permission contract.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/config.sh"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/lib/operations.sh"
source "${PROJECT_ROOT}/lib/runtime-permissions.sh"
init_common_lib "$0"

MODE="repair"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check|--dry-run) MODE="check"; shift ;;
        --help|-h|help)
            cat <<'HELP'
VaultWarden-OCI permission repair

USAGE:
    sudo utilities/repair-permissions.sh              Repair known permission drift
    sudo utilities/repair-permissions.sh --check      Report drift without changing files
    sudo utilities/repair-permissions.sh --dry-run    Alias for --check
    utilities/repair-permissions.sh --help
    utilities/repair-permissions.sh --version

Checks/repairs explicit repository-managed paths only:
  repository and installed configuration/secrets -> existing private contracts
  PROJECT_STATE_DIR data and service logs -> PUID:PGID, directories 0750, files 0640
  configured backup tree -> PUID:PGID, directories 0750, files 0640
  PROJECT_STATE_DIR Caddy data/config/logs -> UID/GID 2000, directories 0750, files 0640
  /run/vaultwarden-oci secrets and metadata -> existing root-owned runtime contracts

Does not scan arbitrary repository or host directories.

OPTIONS:
  --check, --dry-run  Report drift without changing files (root required)
  --help, -h          Show this help
  --version, -V       Print the VaultWarden-OCI version and exit
HELP
            exit 0
            ;;
        --version|-V)
            print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"
            exit 0
            ;;
        *)
            echo "ERROR unknown option: $1" >&2
            exit 2
            ;;
    esac
done

if (( EUID != 0 )); then
    if [[ "$MODE" == "check" ]]; then
        echo "ERROR check requires root for complete inspection: sudo utilities/repair-permissions.sh --check" >&2
    else
        echo "ERROR repair requires root: sudo utilities/repair-permissions.sh" >&2
    fi
    exit 1
fi

if ! load_project_environment; then
    if [[ "$MODE" == "check" ]]; then
        log_warn "repair-permissions: runtime environment authority unavailable; live installation state cannot be resolved"
        exit 1
    fi
    log_error "repair-permissions: refusing live repair without canonical runtime environment authority"
    log_hint "Run: sudo make sync-env"
    exit 1
fi

PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
PUID="${PUID:-$(get_config_value "PUID" "" 2>/dev/null || true)}"
PGID="${PGID:-$(get_config_value "PGID" "" 2>/dev/null || true)}"
PUID="${PUID//$'\r'/}"; PUID="${PUID%%[[:space:]#]*}"; PUID="${PUID//[[:space:]]/}"
PGID="${PGID//$'\r'/}"; PGID="${PGID%%[[:space:]#]*}"; PGID="${PGID//[[:space:]]/}"

if [[ "$MODE" == "check" ]]; then
    check_runtime_state_permissions "$PROJECT_STATE_DIR" "$PUID" "$PGID" "$PROJECT_ROOT"
    exit $?
fi

operation_acquire \
    --id permission-repair \
    --label "Permission repair" \
    --specific-lock /run/lock/vaultwarden-permission-repair.lock || exit $?
operation_set_phase "repair" "Repairing known permission drift"
trap 'rc=$?; operation_release "$rc"; exit "$rc"' EXIT
trap 'operation_release 130; exit 130' INT
trap 'operation_release 143; exit 143' HUP TERM

repair_runtime_state_permissions "$PROJECT_STATE_DIR" "$PUID" "$PGID" "$PROJECT_ROOT"
