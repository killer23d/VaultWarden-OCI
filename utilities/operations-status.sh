#!/usr/bin/env bash
# utilities/operations-status.sh — Show runtime VaultWarden operation status.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"
source "${PROJECT_ROOT}/lib/operations.sh"

show_help() {
    cat <<'EOF'
VaultWarden-OCI Operation Status

USAGE:
    sudo utilities/operations-status.sh [OPTIONS]
    sudo make operations

DESCRIPTION:
    Shows active VaultWarden operation-guard state. Runtime operation metadata
    is root-only, so the status command itself must run with sudo.

OPTIONS:
    --help, -h       Show this help
    --version, -V    Print the VaultWarden-OCI version and exit
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h|help) show_help; exit 0 ;;
        --version|-V) print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"; exit 0 ;;
        *) log_error "Unknown argument: $1"; show_help; exit 1 ;;
    esac
done

if (( EUID != 0 )); then
    log_error "Operation status requires root because runtime state is root-only."
    log_hint "Run: sudo make operations"
    exit 1
fi

operation_list
