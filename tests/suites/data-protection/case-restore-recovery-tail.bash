#!/usr/bin/env bash
# Companion shard for the long restore/recovery functional case.
# The repository runner owns this process and enforces its normal timeout.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export VAULTWARDEN_RESTORE_RECOVERY_SHARD=tail
exec bash "$SCRIPT_DIR/case-restore-recovery.bash" "$@"
