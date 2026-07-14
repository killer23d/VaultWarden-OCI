#!/usr/bin/env bash
# utilities/env-edit.sh — Public environment-management entrypoint.
#
# Keep the established sync/edit/status implementation in env-edit-core.bash,
# then reconcile the optional CrowdSec email integration only after a
# successful command that can change the installed runtime environment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_SCRIPT="${SCRIPT_DIR}/env-edit-core.bash"
RECONCILE_SCRIPT="${SCRIPT_DIR}/crowdsec-email-reconcile.bash"

if [[ ! -x "$CORE_SCRIPT" ]]; then
    printf 'ERROR: environment-management implementation is missing or not executable: %s\n' "$CORE_SCRIPT" >&2
    exit 1
fi

subcommand="${1:-sync}"
"$CORE_SCRIPT" "$@"

case "$subcommand" in
    sync|edit)
        if [[ ! -x "$RECONCILE_SCRIPT" ]]; then
            printf 'ERROR: CrowdSec email reconciler is missing or not executable: %s\n' "$RECONCILE_SCRIPT" >&2
            exit 1
        fi
        VW_CROWDSEC_ENV_FILE="${VW_SYNC_ETC_DIR:-/etc/vaultwarden}/vaultwarden.env" \
            "$RECONCILE_SCRIPT"
        ;;
esac
