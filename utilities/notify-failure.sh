#!/usr/bin/env bash
# utilities/notify-failure.sh — systemd OnFailure notifier with safe cooldown state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/config.sh"
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib notify-failure
source "${PROJECT_ROOT}/lib/crypto.sh"
source "${PROJECT_ROOT}/lib/secrets.sh"
source "${PROJECT_ROOT}/lib/email.sh"

FAILED_UNIT="${1:-unknown.service}"
COOLDOWN_SECONDS=3600

_load_notify_env() {
    if load_project_environment 2>/dev/null; then
        return 0
    fi
    log_error "Runtime environment authority is unavailable."
    log_error "Run: sudo make sync-env"
    return 1
}

_sanitize_unit_name() {
    local raw="${1:-unknown.service}"
    printf '%s' "$raw" | tr -cs '[:alnum:].@_-' '_'
}

_write_delivery_sentinel() {
    local state_dir="$1" safe_unit="$2" sentinel
    sentinel="${state_dir}/NOTIFY_FAILED_${safe_unit}"
    mkdir -p "$state_dir" || return 1
    printf 'unit=%s\ntime=%s\n' "$FAILED_UNIT" "$(date -Iseconds)" > "$sentinel"
}

main() {
    require_root "$@"
    _load_notify_env || return 1

    PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-}"
    if [[ -z "$PROJECT_STATE_DIR" ]]; then
        PROJECT_STATE_DIR=/var/lib/vaultwarden
    fi
    export PROJECT_STATE_DIR

    local safe_unit cooldown_dir cooldown_file lock_file now last subject body admin_email
    safe_unit="$(_sanitize_unit_name "$FAILED_UNIT")"
    cooldown_dir="${PROJECT_STATE_DIR}/.vw-health-alert"
    cooldown_file="${cooldown_dir}/notify_failure_${safe_unit}.cooldown"
    lock_file="/run/lock/vw-notify-${safe_unit}.lock"

    if [[ "$cooldown_dir" == /* && "$cooldown_dir" != "/.vw-health-alert" ]]; then
        mkdir -p "$cooldown_dir"
    else
        log_error "Refusing unsafe cooldown directory: ${cooldown_dir}"
        return 0
    fi

    exec 9>"$lock_file" || { log_warn "Cannot open notify lock ${lock_file}; skipping notification."; return 0; }
    flock -n 9 || { log_info "Failure notification already in progress for ${FAILED_UNIT}; skipping."; return 0; }

    now=$(date +%s)
    last=$(cat "$cooldown_file" 2>/dev/null || printf '0')
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if (( now - last < COOLDOWN_SECONDS )); then
        log_info "Failure notification cooldown active for ${FAILED_UNIT}; skipping."
        return 0
    fi
    printf '%s\n' "$now" > "$cooldown_file"

    admin_email="$(get_config_value ADMIN_EMAIL "")"
    if [[ -z "$admin_email" ]]; then
        log_warn "ADMIN_EMAIL is not configured; no failure email sent for ${FAILED_UNIT}."
        return 0
    fi

    subject="FAILURE: ${FAILED_UNIT} on $(hostname -f 2>/dev/null || hostname)"
    body="A VaultWarden systemd unit failed at $(date -Iseconds).

Unit: ${FAILED_UNIT}
Host: $(hostname -f 2>/dev/null || hostname)

Suggested checks:
  systemctl status '${FAILED_UNIT}'
  journalctl -xeu '${FAILED_UNIT}'"

    if send_email "$admin_email" "$subject" "$body"; then
        log_info "Failure notification sent for ${FAILED_UNIT}."
    else
        log_warn "Failure email delivery failed for ${FAILED_UNIT}; writing sentinel and exiting successfully."
        _write_delivery_sentinel "$PROJECT_STATE_DIR" "$safe_unit" || log_warn "Could not write notification failure sentinel."
        return 0
    fi
}

main "$@"
