#!/usr/bin/env bash
# utilities/setup-crowdsec.sh — CrowdSec policy wrapper for VaultWarden-OCI.
#
# The implementation is kept in .setup-crowdsec-core.sh. This wrapper prevents
# inactive AppSec-only rule collections from being reinstalled on established
# hosts and removes stale subscriptions after every successful setup run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_SCRIPT="${SCRIPT_DIR}/.setup-crowdsec-core.sh"

if [[ ! -f "$CORE_SCRIPT" ]]; then
    printf 'ERROR: CrowdSec setup implementation not found: %s\n' "$CORE_SCRIPT" >&2
    exit 1
fi

# On an established host, filter the two AppSec rule-only collections before
# the core installer reaches its collection phase. Defining this function only
# when a real cscli binary already exists preserves fresh-install detection in
# the core script.
_CSCLI_REAL="$(type -P cscli 2>/dev/null || true)"
if [[ -n "$_CSCLI_REAL" ]]; then
    cscli() {
        if [[ "${1:-}" == "collections" && "${2:-}" == "install" ]]; then
            case "${3:-}" in
                crowdsecurity/appsec-generic-rules|crowdsecurity/appsec-virtual-patching)
                    if declare -F log_info >/dev/null 2>&1; then
                        log_info "Skipping inactive AppSec collection: ${3}"
                    else
                        printf '[INFO]    crowdsec Skipping inactive AppSec collection: %s\n' "$3"
                    fi
                    return 0
                    ;;
            esac
        fi
        command "$_CSCLI_REAL" "$@"
    }
fi

# shellcheck disable=SC1090
source "$CORE_SCRIPT" "$@"

# Reconcile hosts configured by older releases. AppSec rules do not inspect
# traffic without an AppSec listener and a compatible request-forwarding
# remediation component, neither of which is part of this deployment.
if command -v cscli >/dev/null 2>&1; then
    for _obsolete_collection in \
        crowdsecurity/appsec-generic-rules \
        crowdsecurity/appsec-virtual-patching; do
        if command cscli collections list 2>/dev/null | grep -Fq "$_obsolete_collection"; then
            if command cscli collections remove "$_obsolete_collection" >/dev/null 2>&1; then
                log_success "Removed inactive AppSec collection: ${_obsolete_collection}"
            else
                log_warn "Could not remove inactive AppSec collection: ${_obsolete_collection}"
            fi
        fi
    done
    unset _obsolete_collection
fi
