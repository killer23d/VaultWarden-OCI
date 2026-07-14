#!/usr/bin/env bash
# Reconcile optional CrowdSec email notifications after runtime env sync.
#
# This intentionally manages only the VaultWarden-OCI-marked plugin file and
# profile block. Operator-owned CrowdSec configuration is never overwritten.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/log.sh
source "${PROJECT_ROOT}/lib/log.sh"
# shellcheck source=lib/config.sh
source "${PROJECT_ROOT}/lib/config.sh"

ENV_FILE="${VW_CROWDSEC_ENV_FILE:-${VW_SYNC_ETC_DIR:-/etc/vaultwarden}/vaultwarden.env}"
ETC_DIR="${VW_CROWDSEC_ETC_DIR:-/etc/crowdsec}"
PLUGIN_FILE="${ETC_DIR}/notifications/vaultwarden-email.yaml"
PROFILES_FILE="${ETC_DIR}/profiles.yaml.local"
PLUGIN_MARKER="# Managed by VaultWarden-OCI: CrowdSec email notification"
PROFILE_BEGIN="# BEGIN VaultWarden-OCI CrowdSec email notifications"
PROFILE_END="# END VaultWarden-OCI CrowdSec email notifications"
SKIP_SERVICE_ACTIONS="${VW_CROWDSEC_SKIP_SERVICE_ACTIONS:-false}"

# env-edit runs on systems before CrowdSec is installed. Keep that path quiet.
if [[ ! -d "$ETC_DIR" && "$ETC_DIR" == "/etc/crowdsec" ]]; then
    log_debug "CrowdSec config directory is absent; skipping email notification reconciliation."
    exit 0
fi
if [[ ! -f "$ENV_FILE" ]]; then
    log_error "CrowdSec email reconciliation cannot read runtime env: $ENV_FILE"
    exit 1
fi
if (( EUID != 0 )) && [[ "$ETC_DIR" == "/etc/crowdsec" ]]; then
    log_error "CrowdSec email reconciliation requires root for ${ETC_DIR}."
    exit 1
fi

load_env_file "$ENV_FILE" || {
    log_error "CrowdSec email reconciliation stopped because the runtime env could not be loaded safely."
    exit 1
}

enabled="${CROWDSEC_EMAIL_NOTIFICATIONS:-false}"
enabled="${enabled,,}"
[[ "$enabled" == "true" ]] || enabled=false

_yaml_single_quote() {
    local value="$1"
    value="${value//\'/\'\'}"
    printf "'%s'" "$value"
}

_safe_email() {
    local value="${1:-}"
    [[ -n "$value" && ${#value} -le 254 && "$value" == *@* ]]
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* ]]
    [[ "$value" != *[[:cntrl:]]* ]]
}

_strip_profile_block() {
    local input="$1" output="$2"
    awk -v begin="$PROFILE_BEGIN" -v end="$PROFILE_END" '
        $0 == begin {
            if (inside || seen) exit 42
            inside=1; seen=1; next
        }
        $0 == end {
            if (!inside) exit 43
            inside=0; next
        }
        !inside { print }
        END { if (inside) exit 44 }
    ' "$input" > "$output"
}

_append_profile_block() {
    local output="$1"
    cat >> "$output" <<EOF_PROFILE
${PROFILE_BEGIN}
---
name: vaultwarden_email_notifications
filters:
  - Alert.Remediation == true && Alert.GetScope() == "Ip"
notifications:
  - vaultwarden_email
on_success: continue
${PROFILE_END}
EOF_PROFILE
}

_write_plugin() {
    local output="$1" sender receiver
    sender="$(_yaml_single_quote "$SMTP_FROM")"
    receiver="$(_yaml_single_quote "$ADMIN_EMAIL")"
    cat > "$output" <<EOF_PLUGIN
${PLUGIN_MARKER}
# Regenerate by syncing .env: sudo make sync-env
# Or run directly: sudo utilities/crowdsec-email-reconcile.sh
type: email
name: vaultwarden_email
log_level: info
group_wait: 30s
group_threshold: 10
max_retry: 3
timeout: 20s
connect_timeout: 10s
send_timeout: 10s
format: |
  CrowdSec security event notification (up to 10 alerts and 5 decisions per alert).
  {{ range \$alertIndex, \$alert := . -}}
  {{ if lt \$alertIndex 10 -}}
  Source: {{ if \$alert.Source }}{{ \$alert.Source.Value }}{{ else }}unknown{{ end }}
  Scenario: {{ \$alert.Scenario }}
  Machine ID: {{ \$alert.MachineID }}
  {{ range \$decisionIndex, \$decision := \$alert.Decisions -}}
  {{ if lt \$decisionIndex 5 -}}
  Decision type: {{ \$decision.Type }}
  Decision duration: {{ \$decision.Duration }}
  {{ end -}}
  {{ end -}}
  ---
  {{ end -}}
  {{ end -}}
smtp_host: 127.0.0.1
smtp_port: 587
auth_type: none
encryption_type: none
sender_name: CrowdSec
sender_email: ${sender}
email_subject: "CrowdSec security event"
receiver_emails:
  - ${receiver}
EOF_PLUGIN
}

_file_metadata() {
    local path="$1" default_mode="${2:-640}" default_uid default_gid
    default_uid="$(id -u)"
    default_gid="$(id -g)"
    if (( EUID == 0 )); then
        default_uid=0
        default_gid=0
    fi
    if [[ -e "$path" ]]; then
        printf '%s %s %s\n' \
            "$(stat -c '%a' "$path")" "$(stat -c '%u' "$path")" "$(stat -c '%g' "$path")"
    else
        printf '%s %s %s\n' "$default_mode" "$default_uid" "$default_gid"
    fi
}

_promote_stage() {
    local stage="$1" destination="$2" metadata="$3" mode uid gid
    read -r mode uid gid <<< "$metadata"
    install -m "$mode" "$stage" "$destination"
    if (( EUID == 0 )); then
        chown "$uid:$gid" "$destination"
    fi
}

_restore_path() {
    local destination="$1" backup="$2" existed="$3"
    if [[ "$existed" == "true" ]]; then
        cp -p "$backup" "$destination"
    else
        rm -f "$destination"
    fi
}

if [[ -f "$PLUGIN_FILE" ]] && ! grep -Fxq "$PLUGIN_MARKER" "$PLUGIN_FILE"; then
    log_error "Refusing to overwrite unmarked operator file: $PLUGIN_FILE"
    exit 1
fi
if [[ "$enabled" == "true" ]]; then
    if ! _safe_email "${ADMIN_EMAIL:-}" || ! _safe_email "${SMTP_FROM:-}"; then
        log_error "CROWDSEC_EMAIL_NOTIFICATIONS=true requires safe ADMIN_EMAIL and SMTP_FROM values."
        exit 1
    fi
fi
if [[ "$enabled" == "false" && ! -e "$PLUGIN_FILE" ]] \
    && { [[ ! -f "$PROFILES_FILE" ]] \
        || { ! grep -Fq "$PROFILE_BEGIN" "$PROFILES_FILE" \
            && ! grep -Fq "$PROFILE_END" "$PROFILES_FILE"; }; }; then
    exit 0
fi

install -d -m 0750 "$(dirname "$PLUGIN_FILE")" "$(dirname "$PROFILES_FILE")"
workdir="$(mktemp -d "${ETC_DIR}/.vw-email-sync.XXXXXXXX")"
trap 'rm -rf "$workdir"' EXIT
plugin_stage="${workdir}/plugin.yaml"
profiles_stage="${workdir}/profiles.yaml.local"
empty_input="${workdir}/empty"
: > "$empty_input"

plugin_existed=false
profiles_existed=false
plugin_metadata="$(_file_metadata "$PLUGIN_FILE" 640)"
profiles_metadata="$(_file_metadata "$PROFILES_FILE" 640)"
if [[ -e "$PLUGIN_FILE" ]]; then
    plugin_existed=true
    cp -p "$PLUGIN_FILE" "${workdir}/plugin.backup"
fi
if [[ -e "$PROFILES_FILE" ]]; then
    profiles_existed=true
    cp -p "$PROFILES_FILE" "${workdir}/profiles.backup"
fi

profile_input="$empty_input"
[[ "$profiles_existed" == "true" ]] && profile_input="$PROFILES_FILE"
if ! _strip_profile_block "$profile_input" "$profiles_stage"; then
    log_error "Refusing malformed or duplicate VaultWarden-OCI block in $PROFILES_FILE"
    exit 1
fi

if [[ "$enabled" == "true" ]]; then
    _write_plugin "$plugin_stage"
    _append_profile_block "$profiles_stage"
else
    : > "$plugin_stage"
fi

plugin_changed=false
profiles_changed=false
if [[ "$enabled" == "true" ]]; then
    [[ -f "$PLUGIN_FILE" ]] && cmp -s "$plugin_stage" "$PLUGIN_FILE" || plugin_changed=true
else
    [[ "$plugin_existed" == "true" ]] && plugin_changed=true
fi
if [[ -s "$profiles_stage" ]]; then
    [[ -f "$PROFILES_FILE" ]] && cmp -s "$profiles_stage" "$PROFILES_FILE" || profiles_changed=true
else
    [[ "$profiles_existed" == "true" ]] && profiles_changed=true
fi

if [[ "$plugin_changed" == "false" && "$profiles_changed" == "false" ]]; then
    exit 0
fi

if [[ "$enabled" == "true" ]]; then
    _promote_stage "$plugin_stage" "$PLUGIN_FILE" "$plugin_metadata"
else
    rm -f "$PLUGIN_FILE"
fi
if [[ -s "$profiles_stage" ]]; then
    _promote_stage "$profiles_stage" "$PROFILES_FILE" "$profiles_metadata"
else
    rm -f "$PROFILES_FILE"
fi

failed_step=""
if [[ "$SKIP_SERVICE_ACTIONS" != "true" ]]; then
    if ! command -v crowdsec >/dev/null 2>&1 || ! crowdsec -t; then
        failed_step="crowdsec -t"
    elif command -v systemctl >/dev/null 2>&1 \
        && systemctl is-active --quiet crowdsec 2>/dev/null \
        && ! systemctl restart crowdsec; then
        failed_step="systemctl restart crowdsec"
    fi
fi

if [[ -n "$failed_step" ]]; then
    log_error "CrowdSec email reconciliation failed at ${failed_step}; restoring previous managed files."
    _restore_path "$PLUGIN_FILE" "${workdir}/plugin.backup" "$plugin_existed"
    _restore_path "$PROFILES_FILE" "${workdir}/profiles.backup" "$profiles_existed"
    if [[ "$SKIP_SERVICE_ACTIONS" != "true" ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl restart crowdsec >/dev/null 2>&1 || true
    fi
    exit 1
fi

if [[ "$enabled" == "true" ]]; then
    log_success "CrowdSec email notifications reconciled through 127.0.0.1:587."
else
    log_info "CrowdSec email notifications disabled; managed notification files removed."
fi
