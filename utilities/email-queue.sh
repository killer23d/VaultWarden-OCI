#!/usr/bin/env bash
# Inspect or clear the Postfix queue through the Compose service.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/log.sh
source "${PROJECT_ROOT}/lib/log.sh"
# shellcheck source=../lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"
# shellcheck source=../lib/docker.sh
source "${PROJECT_ROOT}/lib/docker.sh"

show_help() {
    cat <<'EOF'
VaultWarden-OCI Postfix Queue Operations

USAGE:
    sudo utilities/email-queue.sh status
    sudo utilities/email-queue.sh clear

COMMANDS:
    status  Show the current Postfix queue.
    clear   Show the queue, delete every queued message after exact
            confirmation, then show the queue again.

AUTOMATION:
    VW_EMAIL_QUEUE_CLEAR_CONFIRMED=1 skips the interactive CLEAR prompt.
    No other value is accepted as confirmation.
EOF
}

_require_postfix_service() {
    if ! docker compose ps --services --filter status=running 2>/dev/null \
        | grep -Fxq postfix; then
        log_error "The Compose service 'postfix' is not running."
        log_hint "Start the stack first: sudo make up"
        return 1
    fi
}

_show_queue() {
    docker compose exec -T postfix postqueue -p
}

_confirm_clear() {
    local confirmation=""
    if [[ "${VW_EMAIL_QUEUE_CLEAR_CONFIRMED:-}" == "1" ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        log_error "Queue clearing requires an interactive TTY or VW_EMAIL_QUEUE_CLEAR_CONFIRMED=1."
        return 1
    fi
    printf 'Type CLEAR to delete every queued email: '
    IFS= read -r confirmation || return 1
    if [[ "$confirmation" != "CLEAR" ]]; then
        log_warn "Postfix queue clear cancelled."
        return 1
    fi
}

clear_queue() {
    log_info "Postfix queue before clear:"
    _show_queue
    _confirm_clear
    docker compose exec -T --user root postfix postsuper -d ALL
    log_info "Postfix queue after clear:"
    _show_queue
}

main() {
    local command="${1:-status}"
    case "$command" in
        --help|-h|help)
            show_help
            return 0
            ;;
        status|clear)
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            return 2
            ;;
    esac

    if [[ "${VW_TEST_MODE:-0}" != "1" \
        || "${VAULTWARDEN_TEST_ALLOW_NON_ROOT:-0}" != "1" ]]; then
        require_root "$@"
    fi
    cd "$PROJECT_ROOT"
    require_docker
    _require_postfix_service

    case "$command" in
        status) _show_queue ;;
        clear) clear_queue ;;
    esac
}

main "$@"
