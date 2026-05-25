#!/usr/bin/env bash
# backup.sh — Dispatch VaultWarden-OCI backup operations.

# Thin dispatcher. All logic lives in utilities/backup-run.sh.
# An admin or systemd unit may also call utilities/backup-run.sh directly.

# Usage:
#   sudo ./backup.sh run [TYPE] [OPTIONS]
#   ./backup.sh list
#   sudo ./backup.sh verify
#   sudo ./backup.sh rotate [OPTIONS]

set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/utilities/backup-run.sh" "$@"
