#!/usr/bin/env bash
# utilities/operations-status.sh — Show runtime VaultWarden operation status.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"
source "${PROJECT_ROOT}/lib/operations.sh"

if (( EUID != 0 )); then
    log_error "Operation status requires root because runtime state is root-only."
    log_hint "Run: sudo make operations"
    exit 1
fi

operation_list
