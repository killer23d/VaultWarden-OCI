#!/usr/bin/env bash
# restore.sh — Dispatch VaultWarden-OCI restore operations.

# Usage:
#   sudo ./restore.sh latest [TYPE] [OPTIONS]
#   sudo ./restore.sh list [--remote]
#   sudo ./restore.sh interactive [OPTIONS]

set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "list" ]]; then
    # Let metadata and malformed inventory commands reach the established
    # utility parser before privilege checks, preserving root-free help/version
    # and clear option diagnostics.
    case "${2:-}" in
        ""|--remote)
            ;;
        --help|-h|--version|-V)
            exec bash "${PROJECT_ROOT}/utilities/restore-run.sh" "$@"
            ;;
        *)
            exec bash "${PROJECT_ROOT}/utilities/restore-run.sh" "$@"
            ;;
    esac
    if (( $# > 2 )); then
        exec bash "${PROJECT_ROOT}/utilities/restore-run.sh" "$@"
    fi

    if (( EUID != 0 )); then
        printf 'ERROR: restore list requires root. Run: sudo ./restore.sh list\n' >&2
        exit 1
    fi

    # Inventory depends on the root-owned installed runtime environment. Load
    # it before dispatch so the utility cannot fall back to repository/default
    # state, backup, or rclone values on an installed host.
    # shellcheck source=lib/config.sh
    source "${PROJECT_ROOT}/lib/config.sh"
    load_project_environment || {
        printf 'ERROR: Failed to load project environment for restore list.\n' >&2
        exit 1
    }
fi

exec bash "${PROJECT_ROOT}/utilities/restore-run.sh" "$@"
