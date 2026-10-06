#!/usr/bin/env bash
set -euo pipefail

RELEASE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RELEASE_ROOT"
export PYTHONPATH="$RELEASE_ROOT"
exec python3 -m vaultwarden_oci.dashboard "$@"
