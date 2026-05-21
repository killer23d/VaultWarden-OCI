#!/usr/bin/env bash
# edit-secrets.sh — VaultWarden secrets dispatcher
#
# Thin dispatcher. All logic lives in utilities/secrets-*.sh.
# An admin may also call those utilities directly.
#
# SUBCOMMANDS:
#   edit                    Interactively edit decrypted secrets, then re-encrypt
#   view                    View decrypted secrets read-only (no changes saved)
#   list                    List secret key names only (no values shown)
#   rotate FIELD            Re-collect and re-hash a single named field
#   export-recovery-kit     Generate a recovery document with unencrypted secrets
#
# Run './edit-secrets.sh <subcommand> --help' for subcommand-specific options.

HISTFILE=/dev/null
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR" && pwd)"

source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"

_show_help() {
cat << 'HELP'
VaultWarden Secrets Editor

USAGE:
    ./edit-secrets.sh <subcommand> [options]

SUBCOMMANDS:
    edit                    Interactively edit decrypted secrets, then re-encrypt
    view                    View decrypted secrets read-only (no changes saved)
    list                    List secret key names only (no values shown)
    rotate FIELD            Re-collect and re-hash a single named field
    export-recovery-kit     Generate a recovery document with unencrypted secrets
    help                    Show this help

Run './edit-secrets.sh <subcommand> --help' for subcommand-specific options.

EXAMPLES:
    ./edit-secrets.sh edit
    ./edit-secrets.sh edit --editor vim
    ./edit-secrets.sh view
    ./edit-secrets.sh list
    ./edit-secrets.sh rotate admin_token
    ./edit-secrets.sh rotate email_api_token --dry-run
    ./edit-secrets.sh export-recovery-kit

SEE ALSO:
    ./setup.sh secrets  - First-time creation or full reconfiguration
HELP
}

# Zero arguments → show help
if [[ $# -eq 0 ]]; then
    _show_help
    exit 0
fi

_TASK="${1}"

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
        _show_help
        exit 0
        ;;
    *)
        log_error "Unknown subcommand: '$_TASK'"
        log_error "Valid subcommands: edit | view | list | rotate FIELD | export-recovery-kit | help"
        log_error "Run './edit-secrets.sh help' for usage."
        exit 1
        ;;
esac
