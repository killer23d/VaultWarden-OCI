#!/usr/bin/env bash
# Optional CrowdSec notification mode reconciler.
#
# It does not implement email providers. SMTP mode delegates to the existing
# setup-crowdsec.sh transaction; auto mode sends CrowdSec alert JSON to a private
# socket-activated adapter which calls lib/email.sh's existing auto fallback chain.

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/config.sh"
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib crowdsec-notifications
source "${PROJECT_ROOT}/lib/operations.sh"
source "${PROJECT_ROOT}/lib/crypto.sh"
source "${PROJECT_ROOT}/lib/secrets.sh"
source "${PROJECT_ROOT}/lib/email.sh"

readonly MANAGED_PLUGIN_MARKER="# Managed by VaultWarden-OCI: CrowdSec auto notification"
readonly PROFILE_BEGIN="# BEGIN VaultWarden-OCI CrowdSec auto notifications"
readonly PROFILE_END="# END VaultWarden-OCI CrowdSec auto notifications"
readonly PLUGIN_NAME="vaultwarden_auto"
readonly SOCKET_UNIT="vaultwarden-crowdsec-notify.socket"
readonly SERVICE_UNIT="vaultwarden-crowdsec-notify@.service"
readonly SOCKET_PATH="/run/vaultwarden-crowdsec-notify.sock"

CROWDSEC_ETC_DIR="${VW_CROWDSEC_ETC_DIR:-/etc/crowdsec}"
PLUGIN_PATH="${CROWDSEC_ETC_DIR}/notifications/vaultwarden-auto.yaml"
PROFILES_PATH="${CROWDSEC_ETC_DIR}/profiles.yaml.local"
UNIT_DEST_DIR="${VW_SYSTEMD_UNIT_DEST_DIR:-/etc/systemd/system}"
OPT_SCRIPTS_DIR="${VW_SYSTEMD_OPT_SCRIPTS_DIR:-/opt/vaultwarden-scripts}"
ENV_FILE="${PROJECT_ROOT}/.env"
LOCK_FILE="${VW_CROWDSEC_NOTIFICATIONS_LOCK:-/run/lock/vaultwarden-crowdsec-notifications.lock}"
LOCK_FD=""
DRY_RUN=false
ACTION=""

show_help() {
    cat <<'HELP'
VaultWarden-OCI CrowdSec Notification Modes

USAGE:
    sudo utilities/crowdsec-notifications.sh reconcile [--dry-run]
    sudo utilities/crowdsec-notifications.sh status
    sudo utilities/crowdsec-notifications.sh test
    sudo utilities/crowdsec-notifications.sh uninstall [--dry-run]

CONFIGURATION:
    CROWDSEC_NOTIFICATION_MODE=off|smtp|auto

MODES:
    off   Remove project-managed CrowdSec mail notification profiles.
    smtp  Use CrowdSec's built-in email plugin through 127.0.0.1:587 Postfix.
    auto  Use CrowdSec's built-in HTTP plugin over a private Unix socket, then
          reuse lib/email.sh: HTTP API -> Postfix -> direct upstream SMTP.

NOTES:
    - The existing CROWDSEC_EMAIL_NOTIFICATIONS flag is maintained as an
      internal compatibility value for setup-crowdsec.sh.
    - Auto mode requires EMAIL_PROVIDER and the SOPS email_api_token plus the
      existing SMTP fallback configuration.
    - This is a synchronous, socket-activated adapter for a small installation;
      it does not add a persistent queue or another long-running application.
HELP
}

_require_action() {
    local action="$1"
    if [[ -n "$ACTION" ]]; then
        log_error "Exactly one action is required."
        exit 2
    fi
    ACTION="$action"
}

while (( $# )); do
    case "$1" in
        reconcile|status|test|uninstall) _require_action "$1"; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        help|--help|-h) show_help; exit 0 ;;
        --version|-V) print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"; exit 0 ;;
        *) log_error "Unknown argument: $1"; show_help; exit 2 ;;
    esac
done
[[ -n "$ACTION" ]] || { show_help; exit 2; }
if [[ "$DRY_RUN" == true && "$ACTION" != reconcile && "$ACTION" != uninstall ]]; then
    log_error "--dry-run is valid only for reconcile or uninstall."
    exit 2
fi

_run() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] $*"
    else
        "$@"
    fi
}

_load_repo_environment() {
    [[ -f "$ENV_FILE" ]] || {
        log_error "Missing ${ENV_FILE}. Run setup first or copy .env.example to .env."
        return 1
    }
    load_env_file "$ENV_FILE"
    resolve_secrets_file
}

_notification_mode() {
    local mode="${CROWDSEC_NOTIFICATION_MODE:-}"
    mode="${mode,,}"
    if [[ -z "$mode" ]]; then
        case "${CROWDSEC_EMAIL_NOTIFICATIONS:-false}" in
            true|TRUE|True|1|yes|YES|on|ON) mode=smtp ;;
            *) mode=off ;;
        esac
    fi
    case "$mode" in
        off|smtp|auto) printf '%s\n' "$mode" ;;
        *)
            log_error "Invalid CROWDSEC_NOTIFICATION_MODE='${CROWDSEC_NOTIFICATION_MODE:-}'. Valid: off smtp auto"
            return 1
            ;;
    esac
}

_acquire_lock() {
    [[ "$DRY_RUN" == true ]] && return 0
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec {LOCK_FD}>"$LOCK_FILE"
    chmod 0600 "$LOCK_FILE" 2>/dev/null || true
    if ! flock -n "$LOCK_FD"; then
        log_error "Another CrowdSec notification reconciliation is already running."
        return 75
    fi
}

_run_isolated() (
    [[ -n "$LOCK_FD" ]] && eval "exec ${LOCK_FD}>&-"
    "$@"
)

_validate_email_chain_config() {
    local provider token smtp_password
    require_config ADMIN_EMAIL SMTP_FROM EMAIL_PROVIDER SMTP_HOST SMTP_PORT SMTP_USERNAME || return 1
    provider="$(_email_driver_lookup "$EMAIL_PROVIDER")" || {
        log_error "CROWDSEC_NOTIFICATION_MODE=auto requires a supported EMAIL_PROVIDER."
        log_error "Supported providers: mailersend sendgrid mailgun postmark resend cyberpersons"
        return 1
    }
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would verify SOPS email_api_token and smtp_password."
        return 0
    fi
    token="$(get_secret email_api_token 2>/dev/null || true)"
    if [[ -z "$token" || "$token" == PLACEHOLDER* || "$token" == NOT_USED_* ]]; then
        unset token
        log_error "Auto mode requires a configured SOPS email_api_token for provider ${provider}."
        return 1
    fi
    unset token
    smtp_password="$(get_secret smtp_password 2>/dev/null || true)"
    if [[ -z "$smtp_password" || "$smtp_password" == PLACEHOLDER* || "$smtp_password" == NOT_USED_* ]]; then
        unset smtp_password
        log_error "Auto mode requires smtp_password so the Postfix/direct SMTP fallback chain is usable."
        return 1
    fi
    unset smtp_password
}

_sync_legacy_flag() {
    local mode="$1" desired=false
    [[ "$mode" == smtp ]] && desired=true
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would set CROWDSEC_EMAIL_NOTIFICATIONS=${desired} in ${ENV_FILE}"
        return 0
    fi
    _set_env_var CROWDSEC_EMAIL_NOTIFICATIONS "$desired" "$ENV_FILE"
    CROWDSEC_EMAIL_NOTIFICATIONS="$desired"
    export CROWDSEC_EMAIL_NOTIFICATIONS
}

_sync_runtime_environment() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would run utilities/env-edit.sh sync"
        return 0
    fi
    "${PROJECT_ROOT}/utilities/env-edit.sh" sync
}

_run_existing_crowdsec_setup() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would run utilities/setup-crowdsec.sh"
        return 0
    fi
    _run_isolated "${PROJECT_ROOT}/utilities/setup-crowdsec.sh" --auto
}

_email_runtime_is_current() {
    local -a required_libs=(log.sh config.sh common.sh crypto.sh secrets.sh email.sh)
    local lib repo_file installed_file repo_sum installed_sum
    for lib in "${required_libs[@]}"; do
        repo_file="${PROJECT_ROOT}/lib/${lib}"
        installed_file="${OPT_SCRIPTS_DIR}/lib/${lib}"
        [[ -r "$repo_file" && -r "$installed_file" ]] || {
            log_error "Auto notification runtime is not installed: ${installed_file}"
            log_error "Run: sudo ./setup.sh systemd install"
            return 1
        }
        repo_sum="$(sha256sum "$repo_file" | awk '{print $1}')"
        installed_sum="$(sha256sum "$installed_file" | awk '{print $1}')"
        if [[ "$repo_sum" != "$installed_sum" ]]; then
            log_error "Installed runtime library is stale: ${installed_file}"
            log_error "Run: sudo ./setup.sh systemd install"
            return 1
        fi
    done
}

_render_service_unit() {
    local source="$1" destination="$2" project_state_dir
    project_state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    awk -v state="$project_state_dir" '
      { print }
      /^ReadWritePaths=\/var\/lib\/vaultwarden / && state != "/var/lib/vaultwarden" {
        print "ReadWritePaths=" state
      }
    ' "$source" >"$destination"
}

_install_adapter_runtime() {
    local adapter_src="${PROJECT_ROOT}/utilities/crowdsec-notify-adapter.sh"
    local adapter_dest="${OPT_SCRIPTS_DIR}/utilities/crowdsec-notify-adapter.sh"
    local socket_src="${PROJECT_ROOT}/systemd/${SOCKET_UNIT}"
    local service_src="${PROJECT_ROOT}/systemd/${SERVICE_UNIT}"
    local service_tmp

    for source in "$adapter_src" "$socket_src" "$service_src"; do
        [[ -r "$source" ]] || { log_error "Missing adapter source: $source"; return 1; }
    done

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would verify installed shared email libraries match the repository."
        log_info "[DRY RUN] Would install ${adapter_dest} (root:root 0700)"
        log_info "[DRY RUN] Would install ${UNIT_DEST_DIR}/${SOCKET_UNIT} and ${UNIT_DEST_DIR}/${SERVICE_UNIT}"
        log_info "[DRY RUN] Would run systemctl daemon-reload"
        return 0
    fi

    _email_runtime_is_current || return 1
    install -d -m 0755 -o root -g root "$(dirname "$adapter_dest")"
    install -m 0700 -o root -g root "$adapter_src" "$adapter_dest"
    install -m 0644 -o root -g root "$socket_src" "${UNIT_DEST_DIR}/${SOCKET_UNIT}"
    service_tmp="$(mktemp "${UNIT_DEST_DIR}/.${SERVICE_UNIT}.XXXXXXXX")"
    _render_service_unit "$service_src" "$service_tmp"
    chmod 0644 "$service_tmp"
    chown root:root "$service_tmp"
    mv -f "$service_tmp" "${UNIT_DEST_DIR}/${SERVICE_UNIT}"
    systemctl daemon-reload
}

_enable_adapter_socket() {
    _run systemctl enable --now "$SOCKET_UNIT"
    if [[ "$DRY_RUN" == false ]] && ! systemctl is-active --quiet "$SOCKET_UNIT"; then
        log_error "Failed to activate ${SOCKET_UNIT}."
        return 1
    fi
}

_disable_adapter_socket() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would disable and stop ${SOCKET_UNIT} when installed"
        return 0
    fi
    if [[ -f "${UNIT_DEST_DIR}/${SOCKET_UNIT}" ]]; then
        systemctl disable --now "$SOCKET_UNIT" >/dev/null 2>&1 || true
    fi
    rm -f "$SOCKET_PATH" 2>/dev/null || true
}

_ensure_managed_dir() {
    local path="$1"
    [[ -d "$path" ]] && return 0
    install -d -m 0750 -o root -g root "$path"
}

_find_duplicate_auto_plugin() {
    local candidate
    while IFS= read -r -d '' candidate; do
        [[ "$candidate" == "$PLUGIN_PATH" ]] && continue
        if grep -Eq "^[[:space:]]*name:[[:space:]]*['\"]?${PLUGIN_NAME}['\"]?[[:space:]]*$" "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(
        find "$(dirname "$PLUGIN_PATH")" -type f \
            \( -name '*.yaml' -o -name '*.yml' \) -print0 2>/dev/null
    )
    return 1
}

_strip_profile_block() {
    local input="$1" output="$2"
    awk -v begin="$PROFILE_BEGIN" -v end="$PROFILE_END" '
      $0 == begin { if (inside || seen) exit 42; inside=1; seen=1; next }
      $0 == end   { if (!inside) exit 43; inside=0; next }
      !inside { print }
      END { if (inside) exit 44 }
    ' "$input" >"$output"
}

_append_profile_block() {
    local output="$1"
    cat >>"$output" <<EOF_PROFILE
${PROFILE_BEGIN}
---
name: vaultwarden_auto_notifications
filters:
  - Alert.Remediation == true && Alert.GetScope() == "Ip"
notifications:
  - ${PLUGIN_NAME}
on_success: continue
${PROFILE_END}
EOF_PROFILE
}

_validate_crowdsec() {
    local context="$1"
    command -v crowdsec >/dev/null 2>&1 || {
        log_error "CrowdSec is unavailable while validating ${context}."
        return 1
    }
    if declare -f operation_run_without_guard_fds >/dev/null 2>&1; then
        _run_isolated operation_run_without_guard_fds crowdsec -t
    else
        _run_isolated crowdsec -t
    fi
}

_file_metadata() {
    local path="$1" default_mode="${2:-640}"
    if [[ -e "$path" ]]; then
        printf '%s %s %s\n' \
            "$(stat -c '%a' "$path")" "$(stat -c '%u' "$path")" "$(stat -c '%g' "$path")"
    else
        printf '%s 0 0\n' "$default_mode"
    fi
}

_promote_file() {
    local stage="$1" destination="$2" metadata="$3" mode uid gid
    read -r mode uid gid <<<"$metadata"
    chmod "$mode" "$stage"
    chown "$uid:$gid" "$stage"
    mv -f "$stage" "$destination"
}

_restore_file() {
    local destination="$1" backup="$2" existed="$3" metadata="$4" stage
    if [[ "$existed" == true ]]; then
        stage="$(mktemp "$(dirname "$destination")/.vw-auto-restore.XXXXXXXX")"
        cp "$backup" "$stage"
        _promote_file "$stage" "$destination" "$metadata"
    else
        rm -f "$destination"
    fi
}

_reconcile_auto_profile() {
    local enabled="$1"
    local plugin_existed=false profiles_existed=false empty_input workdir plugin_stage profiles_stage
    local plugin_metadata plugin_restore_metadata profiles_metadata failed_step=""

    if [[ "$enabled" == false && ! -e "$PLUGIN_PATH" ]] \
       && { [[ ! -f "$PROFILES_PATH" ]] || { ! grep -Fq "$PROFILE_BEGIN" "$PROFILES_PATH" \
            && ! grep -Fq "$PROFILE_END" "$PROFILES_PATH"; }; }; then
        log_info "CrowdSec auto notifications are already absent."
        return 0
    fi

    if [[ -f "$PLUGIN_PATH" ]] && ! grep -Fxq "$MANAGED_PLUGIN_MARKER" "$PLUGIN_PATH"; then
        log_error "Refusing to overwrite unmarked operator file: ${PLUGIN_PATH}"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would reconcile CrowdSec auto notification profile: enabled=${enabled}"
        return 0
    fi

    if [[ "$enabled" == true && ! -e "$PLUGIN_PATH" ]] \
       && { [[ ! -f "$PROFILES_PATH" ]] || ! grep -Fq "$PROFILE_BEGIN" "$PROFILES_PATH"; }; then
        _validate_crowdsec "existing configuration before auto notification installation" || {
            log_error "CrowdSec configuration is already invalid; no auto notification files were changed."
            return 1
        }
    fi

    _ensure_managed_dir "$(dirname "$PLUGIN_PATH")"
    _ensure_managed_dir "$(dirname "$PROFILES_PATH")"
    workdir="$(mktemp -d "${CROWDSEC_ETC_DIR}/.vw-auto-notify.XXXXXXXX")"
    chmod 0700 "$workdir"
    plugin_stage="$(mktemp "$(dirname "$PLUGIN_PATH")/.vw-auto-plugin.XXXXXXXX")"
    profiles_stage="$(mktemp "$(dirname "$PROFILES_PATH")/.vw-auto-profiles.XXXXXXXX")"
    empty_input="${workdir}/empty"
    : >"$empty_input"

    if [[ -e "$PLUGIN_PATH" ]]; then
        plugin_existed=true
        cp -p "$PLUGIN_PATH" "${workdir}/plugin.backup"
    fi
    if [[ -e "$PROFILES_PATH" ]]; then
        profiles_existed=true
        cp -p "$PROFILES_PATH" "${workdir}/profiles.backup"
    fi
    # The dedicated project-owned plugin is always normalized to root:root
    # 0640. Preserve metadata only for profiles.yaml.local because that file can
    # contain operator-owned profiles outside the marked project block.
    plugin_restore_metadata="$(_file_metadata "$PLUGIN_PATH" 640)"
    plugin_metadata="640 0 0"
    profiles_metadata="$(_file_metadata "$PROFILES_PATH" 640)"

    if ! _strip_profile_block \
        "$([[ "$profiles_existed" == true ]] && printf '%s' "$PROFILES_PATH" || printf '%s' "$empty_input")" \
        "$profiles_stage"; then
        log_error "Malformed or duplicate managed auto notification block in ${PROFILES_PATH}."
        rm -f "$plugin_stage" "$profiles_stage"
        rm -rf "$workdir"
        return 1
    fi

    if [[ "$enabled" == true ]]; then
        [[ -r "${PROJECT_ROOT}/crowdsec/vaultwarden-auto.yaml.template" ]] || {
            log_error "Missing CrowdSec auto notification template."
            rm -f "$plugin_stage" "$profiles_stage"
            rm -rf "$workdir"
            return 1
        }
        local duplicate_plugin
        duplicate_plugin="$(_find_duplicate_auto_plugin || true)"
        if [[ -n "$duplicate_plugin" ]]; then
            log_error "Notification name ${PLUGIN_NAME} is already defined in operator file: ${duplicate_plugin}"
            rm -f "$plugin_stage" "$profiles_stage"
            rm -rf "$workdir"
            return 1
        fi
        if grep -Eq "^[[:space:]]*-[[:space:]]*${PLUGIN_NAME}[[:space:]]*$" "$profiles_stage" \
           || { [[ -f "${CROWDSEC_ETC_DIR}/profiles.yaml" ]] \
                && grep -Eq "^[[:space:]]*-[[:space:]]*${PLUGIN_NAME}[[:space:]]*$" \
                    "${CROWDSEC_ETC_DIR}/profiles.yaml"; }; then
            log_error "An operator profile already references ${PLUGIN_NAME}; refusing a duplicate notification path."
            rm -f "$plugin_stage" "$profiles_stage"
            rm -rf "$workdir"
            return 1
        fi
        cp "${PROJECT_ROOT}/crowdsec/vaultwarden-auto.yaml.template" "$plugin_stage"
        _append_profile_block "$profiles_stage"
        grep -Fxq "$MANAGED_PLUGIN_MARKER" "$plugin_stage" || failed_step="managed marker validation"
        grep -Fxq 'type: http' "$plugin_stage" || failed_step="HTTP plugin validation"
        grep -Fxq 'unix_socket: /run/vaultwarden-crowdsec-notify.sock' "$plugin_stage" || failed_step="Unix socket validation"
        grep -Fxq "  - ${PLUGIN_NAME}" "$profiles_stage" || failed_step="profile notification validation"
        grep -Fxq 'on_success: continue' "$profiles_stage" || failed_step="profile continuation validation"
    else
        : >"$plugin_stage"
    fi

    if [[ -n "$failed_step" ]]; then
        log_error "CrowdSec auto notification staged-file validation failed at ${failed_step}."
        rm -f "$plugin_stage" "$profiles_stage"
        rm -rf "$workdir"
        return 1
    fi

    if [[ "$enabled" == true ]]; then
        _promote_file "$plugin_stage" "$PLUGIN_PATH" "$plugin_metadata" || failed_step="plugin promotion"
    else
        rm -f "$plugin_stage"
        rm -f "$PLUGIN_PATH" || failed_step="plugin removal"
    fi
    if [[ -z "$failed_step" ]]; then
        if [[ -s "$profiles_stage" ]]; then
            _promote_file "$profiles_stage" "$PROFILES_PATH" "$profiles_metadata" || failed_step="profile promotion"
        else
            rm -f "$profiles_stage"
            rm -f "$PROFILES_PATH" || failed_step="profile removal"
        fi
    fi
    if [[ -z "$failed_step" ]] && ! _validate_crowdsec "managed auto notification configuration"; then
        failed_step="crowdsec -t"
    fi
    if [[ -z "$failed_step" ]] && ! _run_isolated systemctl restart crowdsec; then
        failed_step="systemctl restart crowdsec"
    fi

    if [[ -n "$failed_step" ]]; then
        log_error "Auto notification reconciliation failed at ${failed_step}; restoring previous files."
        _restore_file "$PLUGIN_PATH" "${workdir}/plugin.backup" "$plugin_existed" "$plugin_restore_metadata" || true
        _restore_file "$PROFILES_PATH" "${workdir}/profiles.backup" "$profiles_existed" "$profiles_metadata" || true
        _run_isolated systemctl restart crowdsec >/dev/null 2>&1 || true
        rm -f "$plugin_stage" "$profiles_stage"
        rm -rf "$workdir"
        return 1
    fi

    rm -f "$plugin_stage" "$profiles_stage"
    rm -rf "$workdir"
}

_reconcile_mode() {
    local mode="$1"
    case "$mode" in
        auto)
            _validate_email_chain_config
            _install_adapter_runtime
            _enable_adapter_socket
            if ! _reconcile_auto_profile true; then
                _disable_adapter_socket
                return 1
            fi
            # Activate the replacement path before removing SMTP-only delivery.
            # A later failure can temporarily leave both paths active, but never
            # removes the last working security-event notification channel.
            _sync_legacy_flag auto
            _sync_runtime_environment
            _run_existing_crowdsec_setup
            log_success "CrowdSec auto notifications enabled: API -> Postfix -> direct SMTP."
            ;;
        smtp)
            # Activate SMTP first, then remove auto mode. This intentionally
            # prefers temporary duplicate delivery over a silent notification gap.
            _sync_legacy_flag smtp
            _sync_runtime_environment
            _run_existing_crowdsec_setup
            _reconcile_auto_profile false
            _disable_adapter_socket
            log_success "CrowdSec SMTP notifications enabled through the existing Postfix relay."
            ;;
        off)
            _sync_legacy_flag off
            _sync_runtime_environment
            _run_existing_crowdsec_setup
            _reconcile_auto_profile false
            _disable_adapter_socket
            log_success "CrowdSec project-managed email notifications disabled."
            ;;
    esac
}

_show_status() {
    local mode legacy auto_plugin=missing auto_profile=missing socket_state=not-installed sentinel
    mode="$(_notification_mode)"
    legacy="${CROWDSEC_EMAIL_NOTIFICATIONS:-false}"
    [[ -f "$PLUGIN_PATH" ]] && auto_plugin=present
    [[ -f "$PROFILES_PATH" ]] && grep -Fq "$PROFILE_BEGIN" "$PROFILES_PATH" && auto_profile=present
    if [[ -f "${UNIT_DEST_DIR}/${SOCKET_UNIT}" ]]; then
        socket_state="$(systemctl is-active "$SOCKET_UNIT" 2>/dev/null || true)"
        [[ -n "$socket_state" ]] || socket_state=inactive
    fi
    sentinel="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/.vw-health-alert/CROWDSEC_NOTIFY_FAILED"
    printf 'Mode:                    %s\n' "$mode"
    printf 'Legacy SMTP flag:        %s\n' "$legacy"
    printf 'Auto plugin file:        %s\n' "$auto_plugin"
    printf 'Auto profile block:      %s\n' "$auto_profile"
    printf 'Adapter socket:          %s\n' "$socket_state"
    printf 'Delivery failure state:  %s\n' "$([[ -f "$sentinel" ]] && printf present || printf clear)"
}

_test_mode() {
    local mode payload
    mode="$(_notification_mode)"
    case "$mode" in
        auto)
            systemctl is-active --quiet "$SOCKET_UNIT" || {
                log_error "${SOCKET_UNIT} is not active. Run reconcile first."
                return 1
            }
            payload='[{"scenario":"vaultwarden-oci/test","machine_id":"local-test","source":{"value":"192.0.2.10"},"decisions":[{"type":"ban","duration":"4h"}]}]'
            curl --fail --show-error --silent \
                --unix-socket "$SOCKET_PATH" \
                -H 'Content-Type: application/json' \
                --data-binary "$payload" \
                http://localhost/notify
            log_success "Auto notification adapter accepted the end-to-end test message. Confirm mailbox receipt."
            ;;
        smtp)
            cscli notifications test vaultwarden_email
            log_info "CrowdSec dispatched the SMTP plugin test. Confirm mailbox receipt and inspect Postfix logs."
            ;;
        off)
            log_error "CrowdSec notifications are disabled."
            return 1
            ;;
    esac
}

_uninstall_adapter() {
    _reconcile_auto_profile false
    _disable_adapter_socket
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would remove adapter unit and installed adapter files."
        return 0
    fi
    rm -f "${UNIT_DEST_DIR}/${SOCKET_UNIT}" "${UNIT_DEST_DIR}/${SERVICE_UNIT}"
    rm -f "${OPT_SCRIPTS_DIR}/utilities/crowdsec-notify-adapter.sh"
    systemctl daemon-reload
    log_success "CrowdSec auto notification adapter uninstalled."
}

main() {
    require_root "$@"
    _load_repo_environment
    case "$ACTION" in
        status) _show_status ;;
        test) _test_mode ;;
        reconcile)
            _acquire_lock
            _reconcile_mode "$(_notification_mode)"
            ;;
        uninstall)
            _acquire_lock
            _uninstall_adapter
            ;;
    esac
}

main "$@"
