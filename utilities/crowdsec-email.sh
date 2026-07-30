#!/usr/bin/env bash
# Minimal controls for the existing CrowdSec email notification integration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${VW_CROWDSEC_EMAIL_ENV_FILE:-${PROJECT_ROOT}/.env}"
SETUP_SCRIPT="${VW_CROWDSEC_SETUP_SCRIPT:-${SCRIPT_DIR}/setup-crowdsec.sh}"
CROWDSEC_ETC="${VW_CROWDSEC_ETC_DIR:-/etc/crowdsec}"
OPERATIONS_LIB="${VW_CROWDSEC_OPERATIONS_LIB:-${PROJECT_ROOT}/lib/operations.sh}"
PLUGIN_FILE="${CROWDSEC_ETC}/notifications/vaultwarden-email.yaml"
PROFILES_FILE="${CROWDSEC_ETC}/profiles.yaml.local"
PLUGIN_MARKER="# Managed by VaultWarden-OCI: CrowdSec email notification"
PROFILE_BEGIN="# BEGIN VaultWarden-OCI CrowdSec email notifications"
PROFILE_END="# END VaultWarden-OCI CrowdSec email notifications"

_CONTROL_OPERATION_ACTIVE=false
_CONTROL_BACKUP=""
_CONTROL_COMMIT_MARKER=""
_CONTROL_COMMIT_TOKEN=""
_CONTROL_TRANSACTION_ACTIVE=false
_CONTROL_TRANSACTION_COMMITTED=false
_CONTROL_INTERRUPTED=false
_CONTROL_FAILURE_REASON=unexpected
_CONTROL_SETUP_PID=""
_CONTROL_SETUP_GROUP=false

error() { printf 'ERROR: %s\n' "$*" >&2; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

show_help() {
    cat <<'HELP'
CrowdSec Email Notifications

USAGE:
    sudo utilities/crowdsec-email.sh enable
    sudo utilities/crowdsec-email.sh disable
    sudo utilities/crowdsec-email.sh status
    sudo utilities/crowdsec-email.sh test
HELP
}

command="${1:-status}"
case "$command" in
    --help|-h|help)
        show_help
        exit 0
        ;;
    enable|disable|status|test)
        ;;
    *)
        error "Unknown command: $command"
        show_help
        exit 2
        ;;
esac

# shellcheck source=../lib/log.sh
source "${PROJECT_ROOT}/lib/log.sh"
# shellcheck source=../lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"

require_runtime() {
    command -v flock >/dev/null 2>&1 || {
        error "Required command is unavailable: flock"
        return 1
    }
    [[ -r "$OPERATIONS_LIB" ]] || {
        error "VaultWarden operation guard is missing or unreadable: $OPERATIONS_LIB"
        return 1
    }
}

load_operations() {
    # shellcheck disable=SC1090,SC1091
    source "$OPERATIONS_LIB"
}

_read_flag_record() {
    local exact_count related_count value
    [[ -e "$ENV_FILE" ]] || { printf 'unknown\n'; return 2; }
    [[ -f "$ENV_FILE" && -r "$ENV_FILE" ]] || { printf 'unknown\n'; return 3; }

    read -r exact_count related_count < <(
        awk '
            /^[[:space:]]*#/ { next }
            {
                trimmed=$0
                sub(/^[[:space:]]*/, "", trimmed)
                if (trimmed ~ /^CROWDSEC_EMAIL_NOTIFICATIONS[[:space:]]*=/) related++
                if ($0 ~ /^CROWDSEC_EMAIL_NOTIFICATIONS=/) exact++
            }
            END { print exact + 0, related + 0 }
        ' "$ENV_FILE"
    ) || { printf 'unknown\n'; return 3; }

    if (( exact_count > 1 || related_count != exact_count )); then
        printf 'invalid\n'
        return 4
    fi
    if (( exact_count == 0 )); then
        printf 'false\n'
        return 0
    fi

    value="$(awk '
        index($0, "CROWDSEC_EMAIL_NOTIFICATIONS=") == 1 {
            print substr($0, length("CROWDSEC_EMAIL_NOTIFICATIONS=") + 1)
            exit
        }
    ' "$ENV_FILE")" || { printf 'unknown\n'; return 3; }
    case "$value" in
        true|false) printf '%s\n' "$value" ;;
        *) printf 'invalid\n'; return 4 ;;
    esac
}

_read_policy_record() {
    local exact_count related_count value
    [[ -e "$ENV_FILE" ]] || { printf 'unknown\n'; return 2; }
    [[ -f "$ENV_FILE" && -r "$ENV_FILE" ]] || { printf 'unknown\n'; return 3; }

    read -r exact_count related_count < <(
        awk '
            /^[[:space:]]*#/ { next }
            {
                trimmed=$0
                sub(/^[[:space:]]*/, "", trimmed)
                if (trimmed ~ /^CROWDSEC_EMAIL_EVENT_POLICY[[:space:]]*=/) related++
                if ($0 ~ /^CROWDSEC_EMAIL_EVENT_POLICY=/) exact++
            }
            END { print exact + 0, related + 0 }
        ' "$ENV_FILE"
    ) || { printf 'unknown\n'; return 3; }

    if (( exact_count > 1 || related_count != exact_count )); then
        printf 'invalid\n'
        return 4
    fi
    if (( exact_count == 0 )); then
        printf 'all\n'
        return 0
    fi

    value="$(awk '
        index($0, "CROWDSEC_EMAIL_EVENT_POLICY=") == 1 {
            print substr($0, length("CROWDSEC_EMAIL_EVENT_POLICY=") + 1)
            exit
        }
    ' "$ENV_FILE")" || { printf 'unknown\n'; return 3; }
    case "$value" in
        all|none) printf '%s\n' "$value" ;;
        *) printf 'invalid\n'; return 4 ;;
    esac
}

write_flag() {
    local value="$1" tmp
    tmp="$(mktemp "${ENV_FILE}.tmp.XXXXXXXX")" || {
        error "Could not create a temporary .env update file."
        return 1
    }
    if ! awk -v value="$value" '
        BEGIN { found = 0 }
        /^CROWDSEC_EMAIL_NOTIFICATIONS=/ {
            if (!found) print "CROWDSEC_EMAIL_NOTIFICATIONS=" value
            found = 1
            next
        }
        { print }
        END { if (!found) print "CROWDSEC_EMAIL_NOTIFICATIONS=" value }
    ' "$ENV_FILE" >"$tmp"; then
        rm -f "$tmp"
        error "Could not render the updated .env."
        return 1
    fi
    if ! chmod --reference="$ENV_FILE" "$tmp" \
        || ! chown --reference="$ENV_FILE" "$tmp"; then
        rm -f "$tmp"
        error "Could not preserve .env ownership or permissions."
        return 1
    fi
    if ! mv -fT -- "$tmp" "$ENV_FILE"; then
        rm -f "$tmp"
        error "Could not atomically replace $ENV_FILE"
        return 1
    fi
}

_plugin_component_state() {
    local rc
    [[ -e "$PLUGIN_FILE" ]] || { printf 'absent\n'; return 0; }
    [[ -f "$PLUGIN_FILE" ]] || { printf 'invalid\n'; return 0; }
    [[ -r "$PLUGIN_FILE" ]] || { printf 'unknown\n'; return 1; }
    if awk -v marker="$PLUGIN_MARKER" '
        $0 == marker { count++ }
        END {
            if (count == 1) exit 0
            exit 20
        }
    ' "$PLUGIN_FILE"; then
        printf 'valid\n'
        return 0
    else
        rc=$?
    fi
    if (( rc == 20 )); then
        printf 'invalid\n'
        return 0
    fi
    printf 'unknown\n'
    return 1
}

_profile_component_state() {
    local rc
    [[ -e "$PROFILES_FILE" ]] || { printf 'absent\n'; return 0; }
    [[ -f "$PROFILES_FILE" ]] || { printf 'invalid\n'; return 0; }
    [[ -r "$PROFILES_FILE" ]] || { printf 'unknown\n'; return 1; }
    if awk -v begin="$PROFILE_BEGIN" -v end="$PROFILE_END" '
        $0 == begin {
            begin_count++
            if (inside) bad=1
            inside=1
            next
        }
        $0 == end {
            end_count++
            if (!inside) bad=1
            inside=0
            next
        }
        END {
            if (begin_count == 0 && end_count == 0) exit 10
            if (begin_count == 1 && end_count == 1 && !inside && !bad) exit 0
            exit 20
        }
    ' "$PROFILES_FILE"; then
        printf 'valid\n'
        return 0
    else
        rc=$?
    fi
    case "$rc" in
        10) printf 'absent\n'; return 0 ;;
        20) printf 'invalid\n'; return 0 ;;
        *) printf 'unknown\n'; return 1 ;;
    esac
}

managed_install_state() {
    local plugin profile plugin_rc=0 profile_rc=0
    plugin="$(_plugin_component_state)" || plugin_rc=$?
    profile="$(_profile_component_state)" || profile_rc=$?

    if (( plugin_rc != 0 )); then
        error "Cannot inspect CrowdSec email plugin; check permissions: $PLUGIN_FILE"
    fi
    if (( profile_rc != 0 )); then
        error "Cannot inspect CrowdSec email profile; check permissions: $PROFILES_FILE"
    fi
    if (( plugin_rc != 0 || profile_rc != 0 )); then
        printf 'unknown\n'
        return 1
    fi
    if [[ "$plugin" == invalid ]]; then
        error "CrowdSec email plugin exists but is not a valid VaultWarden-OCI managed file: $PLUGIN_FILE"
        printf 'invalid\n'
        return 1
    fi
    if [[ "$profile" == invalid ]]; then
        error "CrowdSec email profile markers are malformed or duplicated: $PROFILES_FILE"
        printf 'invalid\n'
        return 1
    fi
    if [[ "$plugin" == valid && "$profile" == valid ]]; then
        printf 'true\n'
    elif [[ "$plugin" == valid && "$profile" == absent ]]; then
        printf 'plugin-only\n'
    elif [[ "$plugin" == absent && "$profile" == absent ]]; then
        printf 'false\n'
    else
        printf 'partial\n'
    fi
}


_restore_env_backup() {
    local backup="$1" restore_stage
    restore_stage="$(mktemp "${ENV_FILE}.restore.XXXXXXXX")" || return 1
    if ! cp -p -- "$backup" "$restore_stage" \
        || ! mv -fT -- "$restore_stage" "$ENV_FILE"; then
        rm -f -- "$restore_stage"
        return 1
    fi
}

_control_commit_marker_matches() {
    [[ -n "${_CONTROL_COMMIT_MARKER:-}" \
        && -f "$_CONTROL_COMMIT_MARKER" \
        && -r "$_CONTROL_COMMIT_MARKER" ]] || return 1
    [[ "$(cat "$_CONTROL_COMMIT_MARKER" 2>/dev/null || true)" == "$_CONTROL_COMMIT_TOKEN" ]]
}

_control_remove_transaction_files() {
    local failed=false path
    for path in "${_CONTROL_COMMIT_MARKER:-}" "${_CONTROL_BACKUP:-}"; do
        [[ -n "$path" ]] || continue
        if ! rm -f -- "$path" || [[ -e "$path" ]]; then
            error "Could not remove temporary transaction file: $path"
            failed=true
        fi
    done
    [[ "$failed" == false ]]
}

_control_release_operation() {
    local rc="${1:-1}"
    if [[ "$_CONTROL_OPERATION_ACTIVE" == true ]]; then
        operation_release "$rc"
        _CONTROL_OPERATION_ACTIVE=false
    fi
}

_control_cleanup() {
    local exit_code="$1" restored=false committed_after_signal=false cleanup_failed=false final_rc
    trap - EXIT
    trap '' INT HUP TERM
    final_rc="$exit_code"
    (( final_rc != 0 )) || final_rc=1

    if [[ "$_CONTROL_TRANSACTION_ACTIVE" == true && "$_CONTROL_TRANSACTION_COMMITTED" == false ]]; then
        _CONTROL_TRANSACTION_ACTIVE=false
        if _control_commit_marker_matches; then
            _CONTROL_TRANSACTION_COMMITTED=true
            committed_after_signal=true
        elif [[ -n "$_CONTROL_BACKUP" && -f "$_CONTROL_BACKUP" ]] \
            && _restore_env_backup "$_CONTROL_BACKUP"; then
            restored=true
        else
            error "Rollback incomplete: could not restore the previous .env."
        fi
    fi

    _control_remove_transaction_files || cleanup_failed=true
    _CONTROL_BACKUP=""
    _CONTROL_COMMIT_MARKER=""
    _CONTROL_COMMIT_TOKEN=""
    _control_release_operation "$final_rc"

    if [[ "$committed_after_signal" == true ]]; then
        warn "CrowdSec email reconciliation committed before interruption; keeping the reconciled .env state."
    elif [[ "$restored" == true ]]; then
        if [[ "$_CONTROL_INTERRUPTED" == true ]]; then
            warn "Interrupted CrowdSec email transaction; restored the previous .env."
        elif [[ "$_CONTROL_FAILURE_REASON" == reconciliation ]]; then
            error "CrowdSec reconciliation failed; the previous .env value was restored."
        else
            error "CrowdSec email transaction failed; the previous .env value was restored."
        fi
    fi
    [[ "$cleanup_failed" == false ]] || final_rc=1
    exit "$final_rc"
}

_control_signal() {
    local exit_code="$1" signal_name="$2" setup_pid="$_CONTROL_SETUP_PID"
    local discovered_pid=""
    _CONTROL_INTERRUPTED=true
    trap '' INT HUP TERM

    if [[ -z "$setup_pid" ]]; then
        discovered_pid="$(jobs -pr 2>/dev/null | tail -n 1 || true)"
        [[ "$discovered_pid" =~ ^[0-9]+$ ]] && setup_pid="$discovered_pid"
    fi
    if [[ -n "$setup_pid" ]] && kill -0 "$setup_pid" 2>/dev/null; then
        if [[ "$_CONTROL_SETUP_GROUP" == true ]]; then
            kill -s "$signal_name" -- "-${setup_pid}" 2>/dev/null \
                || kill -s "$signal_name" "$setup_pid" 2>/dev/null \
                || true
        else
            kill -s "$signal_name" "$setup_pid" 2>/dev/null || true
        fi
        wait "$setup_pid" 2>/dev/null || true
    fi
    _CONTROL_SETUP_GROUP=false
    _CONTROL_SETUP_PID=""
    exit "$exit_code"
}

apply_state() {
    local desired="$1" backup label=disabled setup_rc=1
    [[ -f "$ENV_FILE" && -r "$ENV_FILE" && -w "$ENV_FILE" ]] || {
        error "Repository .env is missing or not readable and writable: $ENV_FILE"
        return 1
    }
    [[ -x "$SETUP_SCRIPT" ]] || {
        error "CrowdSec setup script is missing or not executable: $SETUP_SCRIPT"
        return 1
    }
    require_runtime || return 1
    load_operations

    if ! operation_acquire \
        --id crowdsec-email-control \
        --label "CrowdSec email control" \
        --non-interactive wait; then
        error "Could not acquire the VaultWarden operation guard."
        return 1
    fi
    _CONTROL_OPERATION_ACTIVE=true

    if ! backup="$(mktemp "${ENV_FILE}.backup.XXXXXXXX")"; then
        _control_release_operation 1
        error "Could not create a temporary .env backup."
        return 1
    fi
    if ! cp -p "$ENV_FILE" "$backup"; then
        rm -f "$backup"
        _control_release_operation 1
        error "Could not back up $ENV_FILE"
        return 1
    fi

    _CONTROL_BACKUP="$backup"
    _CONTROL_COMMIT_MARKER="${backup}.committed"
    _CONTROL_COMMIT_TOKEN="${RANDOM}.${BASHPID}.${RANDOM}"
    rm -f -- "$_CONTROL_COMMIT_MARKER"
    _CONTROL_TRANSACTION_ACTIVE=true
    _CONTROL_TRANSACTION_COMMITTED=false
    _CONTROL_INTERRUPTED=false
    _CONTROL_FAILURE_REASON=unexpected
    trap '_control_cleanup "$?"' EXIT
    trap '_control_signal 130 INT' INT
    trap '_control_signal 129 HUP' HUP
    trap '_control_signal 143 TERM' TERM

    if ! _read_flag_record >/dev/null; then
        error "CROWDSEC_EMAIL_NOTIFICATIONS is malformed or duplicated in $ENV_FILE"
        return 1
    fi
    write_flag "$desired"
    if command -v setsid >/dev/null 2>&1; then
        _CONTROL_SETUP_GROUP=true
        VW_CROWDSEC_EMAIL_COMMIT_MARKER="$_CONTROL_COMMIT_MARKER" \
            VW_CROWDSEC_EMAIL_COMMIT_TOKEN="$_CONTROL_COMMIT_TOKEN" \
            setsid "$SETUP_SCRIPT" --reconcile-email &
    else
        _CONTROL_SETUP_GROUP=false
        VW_CROWDSEC_EMAIL_COMMIT_MARKER="$_CONTROL_COMMIT_MARKER" \
            VW_CROWDSEC_EMAIL_COMMIT_TOKEN="$_CONTROL_COMMIT_TOKEN" \
            "$SETUP_SCRIPT" --reconcile-email &
    fi
    _CONTROL_SETUP_PID=$!
    if wait "$_CONTROL_SETUP_PID"; then
        setup_rc=0
    else
        setup_rc=$?
    fi
    _CONTROL_SETUP_PID=""
    _CONTROL_SETUP_GROUP=false
    if (( setup_rc != 0 )); then
        case "$setup_rc" in
            129|130|143) _CONTROL_INTERRUPTED=true ;;
        esac
        _CONTROL_FAILURE_REASON=reconciliation
        return "$setup_rc"
    fi

    if ! _control_commit_marker_matches; then
        _CONTROL_FAILURE_REASON=reconciliation
        error "CrowdSec reconciliation returned success without a transaction commit marker."
        return 1
    fi
    _CONTROL_TRANSACTION_COMMITTED=true
    _CONTROL_TRANSACTION_ACTIVE=false
    if ! _control_remove_transaction_files; then
        _CONTROL_BACKUP=""
        _CONTROL_COMMIT_MARKER=""
        _CONTROL_COMMIT_TOKEN=""
        trap - EXIT
        trap '' INT HUP TERM
        _control_release_operation 1
        return 1
    fi
    _CONTROL_BACKUP=""
    _CONTROL_COMMIT_MARKER=""
    _CONTROL_COMMIT_TOKEN=""
    trap - EXIT
    trap '' INT HUP TERM
    _control_release_operation 0

    if [[ "$desired" == true ]]; then
        label=enabled
    fi
    printf 'CrowdSec email notifications %s.\n' "$label"
}

show_status() {
    local configured event_policy installed
    local configured_rc=0 policy_rc=0 installed_rc=0 consistent=false
    if [[ ! -e "$ENV_FILE" ]]; then
        error "Repository .env not found: $ENV_FILE"
        return 1
    fi
    if [[ ! -f "$ENV_FILE" || ! -r "$ENV_FILE" ]]; then
        error "Cannot inspect repository .env; check permissions: $ENV_FILE"
        printf 'Configured: unknown\nInstalled:  unknown\nConsistent: false\n'
        return 1
    fi

    configured="$(_read_flag_record)" || configured_rc=$?
    event_policy="$(_read_policy_record)" || policy_rc=$?
    installed="$(managed_install_state)" || installed_rc=$?
    if (( configured_rc == 4 )); then
        error "CROWDSEC_EMAIL_NOTIFICATIONS is malformed or duplicated in $ENV_FILE"
    elif (( configured_rc != 0 )); then
        error "Could not inspect CROWDSEC_EMAIL_NOTIFICATIONS in $ENV_FILE"
    fi
    if (( policy_rc == 4 )); then
        error "CROWDSEC_EMAIL_EVENT_POLICY is malformed or duplicated in $ENV_FILE"
    elif (( policy_rc != 0 )); then
        error "Could not inspect CROWDSEC_EMAIL_EVENT_POLICY in $ENV_FILE"
    fi

    if (( configured_rc == 0 && policy_rc == 0 && installed_rc == 0 )); then
        if [[ "$configured" == true && "$event_policy" == all && "$installed" == true ]]; then
            consistent=true
        elif [[ "$configured" == true && "$event_policy" == none && "$installed" == plugin-only ]]; then
            consistent=true
        elif [[ "$configured" == false && "$installed" == false ]]; then
            consistent=true
        fi
    fi

    printf 'Configured: %s\n' "$configured"
    printf 'Event policy: %s\n' "$event_policy"
    printf 'Installed:  %s\n' "$installed"
    printf 'Consistent: %s\n' "$consistent"
    [[ "$consistent" == true ]]
}

send_test() {
    local configured event_policy installed expected_install
    [[ -f "$ENV_FILE" && -r "$ENV_FILE" ]] || {
        error "Repository .env is missing or unreadable: $ENV_FILE"
        return 1
    }
    configured="$(_read_flag_record)" || {
        error "CrowdSec email notification setting is malformed or unreadable."
        return 1
    }
    event_policy="$(_read_policy_record)" || {
        error "CrowdSec email event policy is malformed or unreadable."
        return 1
    }
    installed="$(managed_install_state)" || return 1
    expected_install=true
    [[ "$event_policy" == none ]] && expected_install="plugin-only"
    if [[ "$configured" != true || "$installed" != "$expected_install" ]]; then
        error "CrowdSec email notifications are not enabled."
        return 1
    fi
    command -v cscli >/dev/null 2>&1 || {
        error "Required command is unavailable: cscli"
        return 1
    }
    cscli notifications test vaultwarden_email
    printf 'CrowdSec accepted the test command; confirm mailbox receipt.\n'
}

main() {
    local command="${1:-status}"

    if [[ "${VW_TEST_MODE:-0}" != "1" \
        || "${VAULTWARDEN_TEST_ALLOW_NON_ROOT:-0}" != "1" ]]; then
        require_root "$command"
    fi

    case "$command" in
        enable)  apply_state true ;;
        disable) apply_state false ;;
        status)  show_status ;;
        test)    send_test ;;
    esac
}

main "$command"
