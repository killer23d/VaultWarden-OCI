#!/usr/bin/env bash
set -euo pipefail

RELEASE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset PYTHONHOME
export PYTHONPATH="$RELEASE_ROOT"
export PYTHONNOUSERSITE=1
exec /usr/bin/python3 -P -m vaultwarden_oci.dashboard "$@"
