#!/usr/bin/env bash
# maintenance.sh — Dispatch VaultWarden-OCI maintenance subcommands.

# Thin dispatcher. All logic lives in utilities/maintenance-*.sh.
# An admin or systemd unit may also call those utilities directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -eq 0 ]]; then
    cat << 'EOF'
VaultWarden-OCI Maintenance Script

USAGE:
    ./maintenance.sh <subcommand> [options]

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

Run './maintenance.sh <subcommand> --help' for subcommand-specific options.
EOF
    exit 0
fi

_TASK="${1}"

case "$_TASK" in
    health)
        exec "$SCRIPT_DIR/utilities/maintenance-health.sh" "$@"
        ;;
    update)
        exec "$SCRIPT_DIR/utilities/maintenance-update.sh" "$@"
        ;;
    db-maint)
        exec "$SCRIPT_DIR/utilities/maintenance-db-maint.sh" "$@"
        ;;
    test-email)
        exec "$SCRIPT_DIR/utilities/maintenance-email.sh" "$@"
        ;;
    update-dns)
        exec "$SCRIPT_DIR/utilities/maintenance-update-dns.sh" "$@"
        ;;
    update-firewall)
        exec "$SCRIPT_DIR/utilities/maintenance-update-firewall.sh" "$@"
        ;;
    run)
        exec "$SCRIPT_DIR/utilities/maintenance-run.sh" "$@"
        ;;
    help|--help|-h)
        exec "$0"
        ;;
    *)
        echo "ERROR: Unknown subcommand: '$_TASK'" >&2
        echo "Run './maintenance.sh help' for usage." >&2
        exit 1
        ;;
esac
