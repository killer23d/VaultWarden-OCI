#!/usr/bin/env bash
# restore.sh — Dispatch VaultWarden-OCI restore operations.

# Usage:
#   sudo ./restore.sh latest [TYPE] [OPTIONS]
#   ./restore.sh list [--remote]
#   sudo ./restore.sh interactive [OPTIONS]

set -euo pipefail
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/utilities/restore-run.sh" "$@"
