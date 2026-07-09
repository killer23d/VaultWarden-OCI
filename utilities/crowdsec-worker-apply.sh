#!/usr/bin/env bash
# utilities/crowdsec-worker-apply.sh - Re-render/apply CrowdSec CF Workers bouncer config.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

show_help() {
    cat <<'EOF'
VaultWarden CrowdSec Workers — apply config

USAGE:
    sudo ./utilities/crowdsec-worker-apply.sh

DESCRIPTION:
    Re-renders /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml
    from the current project environment and encrypted secrets, then restarts
    and verifies crowdsec-cloudflare-worker-bouncer.

EOF
}

case "${1:-}" in
    --help|-h|help)
        show_help
        exit 0
        ;;
    --version|-V)
        printf 'VaultWarden-OCI %s\n' "$(tr -d '[:space:]' < "${PROJECT_ROOT}/VERSION" 2>/dev/null || echo unknown)"
        exit 0
        ;;
    "")
        ;;
    *)
        echo "ERROR: Unknown option: '$1'" >&2
        show_help >&2
        exit 1
        ;;
esac

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/config.sh"
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"
require_root "$@"
source "${PROJECT_ROOT}/lib/crypto.sh"
source "${PROJECT_ROOT}/lib/secrets.sh"
source "${PROJECT_ROOT}/lib/crowdsec-worker.sh"

SOPS_CONFIG_FILE="${PROJECT_ROOT}/.sops.yaml"
export SOPS_CONFIG_FILE

crowdsec_worker_apply_config --require-service
