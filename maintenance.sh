#!/usr/bin/env bash
# maintenance.sh — Dispatch VaultWarden-OCI maintenance subcommands.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_help() {
    cat <<'EOF'
VaultWarden-OCI Maintenance Script

USAGE:
    sudo ./maintenance.sh <subcommand> [options]

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
    --version, -V     Print the VaultWarden-OCI version and exit

EXAMPLES:
    sudo ./maintenance.sh run
    sudo ./maintenance.sh health
    sudo ./maintenance.sh run --comprehensive
    ./maintenance.sh --help

Run './maintenance.sh <subcommand> --help' for subcommand-specific options.
EOF
}

if [[ $# -eq 0 ]]; then
    show_help
    exit 0
fi

if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
    printf 'VaultWarden-OCI %s\n' "$(tr -d '[:space:]' < "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo unknown)"
    exit 0
fi

_TASK="${1}"
shift

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
    help)
        show_help
        exit 0
        ;;
    --help|-h)
        show_help
        exit 0
        ;;
    --version|-V)
        printf 'VaultWarden-OCI %s\n' "$(tr -d '[:space:]' < "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo unknown)"
        exit 0
        ;;
    *)
        echo "ERROR: Unknown subcommand: '$_TASK'" >&2
        echo "Run './maintenance.sh help' for usage." >&2
        exit 1
        ;;
esac
