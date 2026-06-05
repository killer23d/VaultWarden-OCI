#!/usr/bin/env bash
# maintenance.sh — Dispatch VaultWarden-OCI maintenance subcommands.

# Thin dispatcher. All logic lives in utilities/maintenance-*.sh.
# An admin or systemd unit may also call those utilities directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_help() {
    cat <<'EOF'
VaultWarden-OCI Maintenance Script

USAGE:
    ./maintenance.sh <subcommand> [options]

DESCRIPTION:
    Thin dispatcher that routes maintenance subcommands to their dedicated
    utility scripts. Each subcommand can be called directly via
    utilities/maintenance-<name>.sh. Run with --help for subcommand options.

SUBCOMMANDS:
    run               Full routine maintenance (cleanup + optimize + health)
    run --comprehensive   Full routine + firewall + DNS updates
    health            Run system health checks
    update            Update system packages and/or Docker images
    db-maint          Deep offline database maintenance (VACUUM + checkpoint)
    test-email        Email subsystem diagnostic
    update-dns        Update Cloudflare DNS A record
    update-firewall   Sync Cloudflare IP ranges into UFW
    help              Show this help

OPTIONS:
    --help, -h        Show this help

EXAMPLES:
    ./maintenance.sh run
    ./maintenance.sh health
    ./maintenance.sh run --comprehensive
    ./maintenance.sh health --help

Run './maintenance.sh <subcommand> --help' for subcommand-specific options.
EOF
}

if [[ $# -eq 0 ]]; then
    show_help
    exit 0
fi

# ux.md #19: consume the subcommand token, then pass remaining args (including
# any --help/-h) straight through to the subcommand script via exec.  This
# fixes the old 'help|--help|-h) exec "$0"' pattern which ignored the user's
# subcommand context and always re-displayed top-level help.
_TASK="${1}"
shift

case "$_TASK" in
    health)
        exec "$SCRIPT_DIR/utilities/maintenance-health.sh" health "$@"
        ;;
    update)
        exec "$SCRIPT_DIR/utilities/maintenance-update.sh" update "$@"
        ;;
    db-maint)
        exec "$SCRIPT_DIR/utilities/maintenance-db-maint.sh" db-maint "$@"
        ;;
    test-email)
        exec "$SCRIPT_DIR/utilities/maintenance-email.sh" test-email "$@"
        ;;
    update-dns)
        exec "$SCRIPT_DIR/utilities/maintenance-update-dns.sh" update-dns "$@"
        ;;
    update-firewall)
        exec "$SCRIPT_DIR/utilities/maintenance-update-firewall.sh" update-firewall "$@"
        ;;
    run)
        exec "$SCRIPT_DIR/utilities/maintenance-run.sh" run "$@"
        ;;
    help)
        # Bare 'help' keyword → top-level help only (no subcommand context).
        show_help
        exit 0
        ;;
    --help|-h)
        # --help/-h at the top level (no subcommand given before the flag).
        show_help
        exit 0
        ;;
    *)
        echo "ERROR: Unknown subcommand: '$_TASK'" >&2
        echo "Run './maintenance.sh help' for usage." >&2
        exit 1
        ;;
esac
