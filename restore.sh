#!/usr/bin/env bash
# restore.sh — Dispatch VaultWarden-OCI restore operations.

# Usage:
#   sudo ./restore.sh latest [TYPE] [OPTIONS]
#   sudo ./restore.sh list [--remote]
#   sudo ./restore.sh interactive [OPTIONS]

set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
    help|--help|-h|--version|-V)
        ;;
    *)
        if (( EUID != 0 )); then
            printf 'ERROR: restore %s requires root. Run: sudo ./restore.sh %s\n' \
                "${1:-operation}" "${1:-operation}" >&2
            exit 1
        fi
        # Inventory and restore operations depend on the root-owned installed
        # runtime environment. Fail before dispatch rather than falling back to
        # repository or default values.
        # shellcheck source=lib/config.sh
        source "${PROJECT_ROOT}/lib/config.sh"
        load_project_environment || {
            printf 'ERROR: Failed to load project environment for restore %s.\n' \
                "${1:-operation}" >&2
            exit 1
        }
        ;;
esac

exec bash "${PROJECT_ROOT}/utilities/restore-run.sh" "$@"
