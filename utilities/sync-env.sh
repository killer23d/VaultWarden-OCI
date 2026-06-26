#!/usr/bin/env bash
# utilities/sync-env.sh — Compatibility shim; delegates to env-edit.sh sync.
# Use utilities/env-edit.sh directly for new call sites.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  "")
    exec "${SCRIPT_DIR}/env-edit.sh" sync
    ;;
  --help|-h)
    cat <<'HELP'
VaultWarden-OCI sync-env compatibility shim

USAGE:
  sudo utilities/sync-env.sh

This legacy command delegates to:
  sudo utilities/env-edit.sh sync

For the full environment manager help, run:
  utilities/env-edit.sh --help
HELP
    ;;
  --version|-V)
    exec "${SCRIPT_DIR}/env-edit.sh" --version
    ;;
  *)
    printf 'sync-env.sh: unknown argument: %s\n' "$1" >&2
    printf 'Use utilities/env-edit.sh sync for syncing, or utilities/env-edit.sh --help.\n' >&2
    exit 2
    ;;
esac
