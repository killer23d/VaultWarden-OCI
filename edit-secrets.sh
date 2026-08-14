#!/usr/bin/env bash
# edit-secrets.sh — Dispatch VaultWarden secrets operations.

HISTFILE=/dev/null
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR" && pwd)"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/config.sh"
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"

show_help() {
cat <<'HELP'
VaultWarden-OCI Secrets Editor

USAGE:
    sudo ./edit-secrets.sh <subcommand> [options]

DESCRIPTION:
    Thin dispatcher for VaultWarden secrets management operations. Delegates
    to utilities/secrets-*.sh subcommands. Manage credentials using SOPS
    Age encryption — secrets are never stored in plaintext on disk.

SUBCOMMANDS:
    edit                    Interactively edit decrypted secrets, then re-encrypt
    view                    View decrypted secrets read-only (no changes saved)
    list                    List secret key names only (no values shown)
    rotate FIELD            Re-collect and re-hash a single named field
    export-recovery-kit     Generate a recovery document with unencrypted secrets
    help                    Show this help

OPTIONS:
    --help, -h              Show this help
    --version, -V           Print the VaultWarden-OCI version and exit

EXAMPLES:
    sudo ./edit-secrets.sh edit
    sudo ./edit-secrets.sh edit --editor vim
    sudo ./edit-secrets.sh view
    sudo ./edit-secrets.sh list
    sudo ./edit-secrets.sh rotate admin_token
    sudo ./edit-secrets.sh rotate email_api_token --dry-run
    sudo ./edit-secrets.sh export-recovery-kit

Run 'sudo ./edit-secrets.sh <subcommand> --help' for subcommand-specific options.
If SOPS reports permission drift, run: sudo utilities/repair-permissions.sh
HELP
}

if [[ $# -eq 0 ]]; then
    show_help
    exit 0
fi

_TASK="${1}"
shift

case "$_TASK" in
    edit)
        exec "$SCRIPT_DIR/utilities/secrets-edit.sh" "$@"
        ;;
    view)
        exec "$SCRIPT_DIR/utilities/secrets-view.sh" "$@"
        ;;
    list)
        exec "$SCRIPT_DIR/utilities/secrets-list.sh" "$@"
        ;;
    rotate)
        exec "$SCRIPT_DIR/utilities/secrets-rotate.sh" "$@"
        ;;
    export-recovery-kit)
        exec "$SCRIPT_DIR/utilities/secrets-export-recovery-kit.sh" "$@"
        ;;
    help|--help|-h)
        show_help
        exit 0
        ;;
    --version|-V)
        print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"
        exit 0
        ;;
    *)
        log_error "Unknown subcommand: '$_TASK'"
        log_error "Valid subcommands: edit | view | list | rotate FIELD | export-recovery-kit | help"
        log_error "Run 'sudo ./edit-secrets.sh help' for usage."
        exit 1
        ;;
esac
