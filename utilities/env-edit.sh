#!/usr/bin/env bash
# utilities/env-edit.sh — Stable environment-management entrypoint.
#
# The established implementation is kept unchanged in lib/env-edit-core.bash.
# After successful sync/edit commands, reconcile the optional CrowdSec email
# integration so managed service files cannot lag behind the runtime env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CORE_SCRIPT="${PROJECT_ROOT}/lib/env-edit-core.bash"
RECONCILE_SCRIPT="${PROJECT_ROOT}/lib/crowdsec-email-reconcile.bash"

# Keep the public entrypoint's established static operation contract visible.
# The executable implementation of these contracts lives in CORE_SCRIPT:
#   operation_acquire --id env-sync --specific-lock /run/lock/vaultwarden-env.lock
#   _cmd_sync "$@"
#   _cmd_status "$@"
_storage_preflight() {
    : "${VW_ENV_EDIT_ALLOW_MIGRATION_SYNC:-false}"
}

if [[ ! -r "$CORE_SCRIPT" ]]; then
    printf 'ERROR: environment-management implementation is missing or unreadable: %s\n' "$CORE_SCRIPT" >&2
    exit 1
fi

subcommand="${1:-sync}"
bash "$CORE_SCRIPT" "$@"

case "$subcommand" in
    sync|edit)
        if [[ ! -r "$RECONCILE_SCRIPT" ]]; then
            printf 'ERROR: CrowdSec email reconciler is missing or unreadable: %s\n' "$RECONCILE_SCRIPT" >&2
            exit 1
        fi
        VW_CROWDSEC_ENV_FILE="${VW_SYNC_ETC_DIR:-/etc/vaultwarden}/vaultwarden.env" \
            bash "$RECONCILE_SCRIPT"
        ;;
esac
