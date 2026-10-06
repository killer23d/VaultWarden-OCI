#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset PYTHONHOME
export PYTHONPATH="$SCRIPT_DIR"
export PYTHONNOUSERSITE=1
exec python3 -P -m vaultwarden_oci.dashboard "$@"
