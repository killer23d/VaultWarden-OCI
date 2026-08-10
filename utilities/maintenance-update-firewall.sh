#!/usr/bin/env bash
# utilities/maintenance-update-firewall.sh — Reconciles Cloudflare UFW ingress.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "$PROJECT_ROOT/lib/log.sh"
source "$PROJECT_ROOT/lib/config.sh"
source "$PROJECT_ROOT/lib/common.sh"
init_common_lib "$0"
source "$PROJECT_ROOT/lib/operations.sh"

DRY_RUN=false

show_help() {
    cat <<'HELP'
VaultWarden-OCI Firewall Range Updater

USAGE:
    sudo utilities/maintenance-update-firewall.sh [OPTIONS]
    sudo ./maintenance.sh update-firewall [OPTIONS]

DESCRIPTION:
    Reconciles ports 80/443 to the exact current Cloudflare CIDR set by using
    the canonical setup-firewall UFW reconciler. Conflicting public ingress and
    retired managed ranges are removed. Skipped when CLOUDFLARE_PROXY_ENABLED
    is not "true".

OPTIONS:
    --dry-run     Preview what would be done without making changes
    --help, -h    Show this help
    --version, -V Print the VaultWarden-OCI version and exit

EXIT CODES:
    0 — firewall reconciled successfully or skipped by configuration
    75 — skipped because another VaultWarden operation owns the lock
    Other non-zero — firewall reconciliation failed
HELP
}

[[ "${1:-}" == "update-firewall" ]] && shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)      DRY_RUN=true; shift ;;
        --help|-h|help) show_help; exit 0 ;;
        --version|-V)   print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"; exit 0 ;;
        *) log_error "Unknown option for 'update-firewall': $1"; show_help; exit 1 ;;
    esac
done

main() {
    local rc=0
    require_root "$@"
    load_project_environment || exit 1

    if [[ "${CLOUDFLARE_PROXY_ENABLED:-false}" != "true" ]]; then
        log_info "Skipping Cloudflare firewall update (CLOUDFLARE_PROXY_ENABLED is not 'true')"
        return 0
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        operation_acquire \
            --id firewall-update \
            --label "Firewall update" \
            --specific-lock /run/lock/vaultwarden-firewall-update.lock \
            --non-interactive skip || return $?
        operation_set_phase "update" "Updating Cloudflare firewall ranges"
        _firewall_update_cleanup() {
            local exit_rc=$?
            operation_release "$exit_rc"
            return "$exit_rc"
        }
        trap _firewall_update_cleanup EXIT
        trap 'operation_release 130; exit 130' INT
        trap 'operation_release 143; exit 143' HUP TERM
    fi

    local -a args=(--phase ufw --auto)
    [[ "$DRY_RUN" == "true" ]] && args+=(--dry-run)

    "$PROJECT_ROOT/utilities/setup-firewall.sh" "${args[@]}" || rc=$?
    if (( rc != 0 )); then
        log_error "Cloudflare firewall reconciliation failed (exit ${rc})."
        return "$rc"
    fi
    return 0
}

main "$@"
