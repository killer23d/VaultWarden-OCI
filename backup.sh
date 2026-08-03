#!/usr/bin/env bash
# backup.sh — Dispatch VaultWarden-OCI backup operations.

# Usage:
#   sudo ./backup.sh run [TYPE] [OPTIONS]
#   sudo ./backup.sh list
#   sudo ./backup.sh verify
#   sudo ./backup.sh rotate [OPTIONS]

set -euo pipefail
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/utilities/backup-run.sh" "$@"
