#!/usr/bin/env bash
# restore.sh — VaultWarden-OCI restore dispatcher
#
# Thin dispatcher. All logic lives in utilities/restore-run.sh.
# An admin may also call utilities/restore-run.sh directly.
#
# USAGE:
#   sudo ./restore.sh latest [TYPE] [OPTIONS]
#   ./restore.sh list [--remote]
#   sudo ./restore.sh interactive [OPTIONS]

set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/utilities/restore-run.sh" "$@"
