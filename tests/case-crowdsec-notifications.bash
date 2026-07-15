#!/usr/bin/env bash
# Focused tests for the optional CrowdSec auto notification adapter/reconciler.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

write_common_stubs() {
    local fixture="$1"
    mkdir -p "$fixture/lib"
    cat >"$fixture/lib/log.sh" <<'EOF_LOG'
log_info(){ printf 'INFO %s\n' "$*" >&2; }
log_warn(){ printf 'WARN %s\n' "$*" >&2; }
log_error(){ printf 'ERROR %s\n' "$*" >&2; }
log_success(){ printf 'SUCCESS %s\n' "$*" >&2; }
EOF_LOG
    cat >"$fixture/lib/common.sh" <<'EOF_COMMON'
init_common_lib(){ :; }
require_root(){ :; }
print_project_version(){ :; }
EOF_COMMON
    printf ':\n' >"$fixture/lib/crypto.sh"
    cat >"$fixture/lib/operations.sh" <<'EOF_OPERATIONS'
operation_run_without_guard_fds(){ "$@"; }
EOF_OPERATIONS
}

check_adapter() (
    set -euo pipefail
    local fixture="$TMP/adapter" payload length request rc
    mkdir -p "$fixture/utilities"
    cp "$ROOT/utilities/crowdsec-notify-adapter.sh" "$fixture/utilities/"
    write_common_stubs "$fixture"
    cat >"$fixture/lib/config.sh" <<'EOF_CONFIG'
load_project_environment(){
  ADMIN_EMAIL=admin@example.test
  SMTP_FROM=security@example.test
  EMAIL_PROVIDER=mailersend
  PROJECT_STATE_DIR="${VW_TEST_STATE_DIR:?}"
  export ADMIN_EMAIL SMTP_FROM EMAIL_PROVIDER PROJECT_STATE_DIR
}
load_env_file(){ load_project_environment; }
resolve_secrets_file(){ :; }
EOF_CONFIG
    cat >"$fixture/lib/secrets.sh" <<'EOF_SECRETS'
get_secret(){ printf 'test-secret'; }
EOF_SECRETS
    cat >"$fixture/lib/email.sh" <<'EOF_EMAIL'
send_email(){
  printf 'TO=%s\nSUBJECT=%s\nBODY<<\n%s\n>>BODY\nMODE=%s\n' \
    "$1" "$2" "$3" "${EMAIL_MODE:-}" >>"${VW_TEST_CAPTURE:?}"
  [[ "${VW_TEST_SEND_FAIL:-0}" != 1 ]]
}
EOF_EMAIL

    payload='[{"scenario":"vaultwarden-oci/test","machine_id":"local-test","source":{"value":"192.0.2.10"},"decisions":[{"type":"ban","duration":"4h"}]}]'
    length="$(printf '%s' "$payload" | wc -c | tr -d ' ')"
    request="$(printf 'POST /notify HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "$length" "$payload")"
    mkdir -p "$TMP/adapter-state"
    VW_TEST_STATE_DIR="$TMP/adapter-state" VW_TEST_CAPTURE="$TMP/adapter.capture" \
        bash "$fixture/utilities/crowdsec-notify-adapter.sh" <<<"$request" \
        >"$TMP/adapter.response" 2>"$TMP/adapter.stderr"
    grep -Fq 'HTTP/1.1 204 No Content' "$TMP/adapter.response" || fail "adapter did not return 204"
    grep -Fq 'MODE=auto' "$TMP/adapter.capture" || fail "adapter did not force the existing auto chain"
    grep -Fq 'Scenario: vaultwarden-oci/test' "$TMP/adapter.capture" || fail "adapter body omitted scenario"
    grep -Fq 'Decision duration: 4h' "$TMP/adapter.capture" || fail "adapter body omitted decision"

    payload='not-json'
    length="$(printf '%s' "$payload" | wc -c | tr -d ' ')"
    request="$(printf 'POST /notify HTTP/1.1\r\nContent-Length: %s\r\n\r\n%s' "$length" "$payload")"
    VW_TEST_STATE_DIR="$TMP/adapter-state" VW_TEST_CAPTURE="$TMP/adapter.capture" \
        bash "$fixture/utilities/crowdsec-notify-adapter.sh" <<<"$request" \
        >"$TMP/adapter.bad.response" 2>"$TMP/adapter.bad.stderr"
    grep -Fq 'HTTP/1.1 400 Bad Request' "$TMP/adapter.bad.response" || fail "malformed JSON was not rejected"

    payload='[]'
    length="$(printf '%s' "$payload" | wc -c | tr -d ' ')"
    request="$(printf 'POST /notify HTTP/1.1\r\nContent-Length: %s\r\nContent-Length: %s\r\n\r\n%s' "$length" "$length" "$payload")"
    VW_TEST_STATE_DIR="$TMP/adapter-state" VW_TEST_CAPTURE="$TMP/adapter.capture" \
        bash "$fixture/utilities/crowdsec-notify-adapter.sh" <<<"$request" \
        >"$TMP/adapter.duplicate-length.response" 2>"$TMP/adapter.duplicate-length.stderr"
    grep -Fq 'HTTP/1.1 400 Bad Request' "$TMP/adapter.duplicate-length.response" \
        || fail "duplicate Content-Length was not rejected"

    payload='[{"scenario":"failure","source":{"value":"192.0.2.11"},"decisions":[]}]'
    length="$(printf '%s' "$payload" | wc -c | tr -d ' ')"
    request="$(printf 'POST /notify HTTP/1.1\r\nContent-Length: %s\r\n\r\n%s' "$length" "$payload")"
    set +e
    VW_TEST_STATE_DIR="$TMP/adapter-state" VW_TEST_CAPTURE="$TMP/adapter.capture" VW_TEST_SEND_FAIL=1 \
        bash "$fixture/utilities/crowdsec-notify-adapter.sh" <<<"$request" \
        >"$TMP/adapter.fail.response" 2>"$TMP/adapter.fail.stderr"
    rc=$?
    set -e
    (( rc != 0 )) || fail "all-route delivery failure returned success"
    [[ ! -s "$TMP/adapter.fail.response" ]] || fail "delivery failure returned HTTP and would suppress CrowdSec retry"
    [[ -f "$TMP/adapter-state/.vw-health-alert/CROWDSEC_NOTIFY_FAILED" ]] || fail "delivery failure sentinel missing"
)

check_reconciler() (
    set -euo pipefail
    local fixture="$TMP/reconcile" runtime="$TMP/runtime" rc
    mkdir -p "$fixture"/{utilities,crowdsec,systemd,lib} \
             "$runtime"/{etc/crowdsec/notifications,units,opt/lib,bin,state/config,state/secrets}
    cp "$ROOT/utilities/crowdsec-notifications.sh" "$fixture/utilities/"
    cp "$ROOT/utilities/crowdsec-notify-adapter.sh" "$fixture/utilities/"
    cp "$ROOT/crowdsec/vaultwarden-auto.yaml.template" "$fixture/crowdsec/"
    cp "$ROOT/systemd/vaultwarden-crowdsec-notify.socket" "$fixture/systemd/"
    cp "$ROOT/systemd/vaultwarden-crowdsec-notify@.service" "$fixture/systemd/"
    write_common_stubs "$fixture"

    cat >"$fixture/lib/config.sh" <<'EOF_CONFIG'
load_env_file(){
  local file="$1" line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
    key="${line%%=*}"; value="${line#*=}"
    printf -v "$key" '%s' "$value"; export "$key"
  done <"$file"
}
load_project_environment(){ load_env_file "${PROJECT_ROOT}/.env"; }
resolve_secrets_file(){ SECRETS_FILE="${PROJECT_STATE_DIR:-/tmp}/secrets/secrets.yaml"; export SECRETS_FILE; }
require_config(){ local key; for key in "$@"; do [[ -n "${!key:-}" ]] || return 1; done; }
_set_env_var(){
  local key="$1" value="$2" file="$3" tmp
  tmp="${file}.tmp.$$"
  if grep -q "^${key}=" "$file"; then
    sed "s|^${key}=.*|${key}=${value}|" "$file" >"$tmp"
  else
    cp "$file" "$tmp"; printf '%s=%s\n' "$key" "$value" >>"$tmp"
  fi
  mv "$tmp" "$file"
}
EOF_CONFIG
    cat >"$fixture/lib/secrets.sh" <<'EOF_SECRETS'
get_secret(){ case "$1" in email_api_token|smtp_password) printf 'test-secret';; *) return 1;; esac; }
EOF_SECRETS
    cat >"$fixture/lib/email.sh" <<'EOF_EMAIL'
_email_driver_lookup(){ case "$1" in mailersend|sendgrid|mailgun|postmark|resend|cyberpersons) printf '%s' "$1";; *) return 1;; esac; }
send_email(){ return 0; }
EOF_EMAIL
    cat >"$fixture/utilities/env-edit.sh" <<'EOF_ENV_EDIT'
#!/usr/bin/env bash
printf 'env-edit %s\n' "$*" >>"${VW_TEST_CALL_LOG:?}"
EOF_ENV_EDIT
    cat >"$fixture/utilities/setup-crowdsec.sh" <<'EOF_SETUP'
#!/usr/bin/env bash
root="$(cd "$(dirname "$0")/.." && pwd)"
printf 'setup-crowdsec legacy=%s args=%s\n' \
  "$(grep '^CROWDSEC_EMAIL_NOTIFICATIONS=' "$root/.env" | cut -d= -f2-)" "$*" >>"${VW_TEST_CALL_LOG:?}"
EOF_SETUP
    chmod +x "$fixture/utilities/"*.sh

    cp "$fixture/lib/"{log.sh,config.sh,common.sh,crypto.sh,secrets.sh,email.sh} "$runtime/opt/lib/"
    cat >"$runtime/bin/crowdsec" <<'EOF_CROWDSEC'
#!/usr/bin/env bash
[[ "${1:-}" == -t ]] || exit 2
printf 'crowdsec-test\n' >>"${VW_TEST_CALL_LOG:?}"
[[ "${VW_TEST_CROWDSEC_FAIL:-0}" != 1 ]]
EOF_CROWDSEC
    cat >"$runtime/bin/systemctl" <<'EOF_SYSTEMCTL'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"${VW_TEST_CALL_LOG:?}"
case "${1:-}" in
  is-active) [[ -f "${VW_TEST_SOCKET_ACTIVE:?}" ]] ;;
  enable) touch "${VW_TEST_SOCKET_ACTIVE:?}" ;;
  disable) rm -f "${VW_TEST_SOCKET_ACTIVE:?}" ;;
  *) exit 0 ;;
esac
EOF_SYSTEMCTL
    chmod +x "$runtime/bin/"*

    cat >"$fixture/.env" <<EOF_ENV
ADMIN_EMAIL=admin@example.test
SMTP_FROM=security@example.test
EMAIL_PROVIDER=mailersend
SMTP_HOST=smtp.example.test
SMTP_PORT=587
SMTP_USERNAME=user
PROJECT_STATE_DIR=$runtime/state
CROWDSEC_NOTIFICATION_MODE=auto
CROWDSEC_EMAIL_NOTIFICATIONS=true
EOF_ENV
    chmod 0755 "$runtime/etc/crowdsec"
    printf 'name: operator_profile\nfilters:\n  - true\non_success: continue\n' \
        >"$runtime/etc/crowdsec/profiles.yaml.local"
    mkdir -p "$runtime/etc/crowdsec/notifications/operator"
    printf 'type: http\nname: vaultwarden_auto\nurl: http://operator.invalid\nmethod: POST\nformat: x\n' \
        >"$runtime/etc/crowdsec/notifications/operator/auto.yaml"
    : >"$runtime/calls.log"
    export PATH="$runtime/bin:$PATH"
    export VW_TEST_CALL_LOG="$runtime/calls.log" VW_TEST_SOCKET_ACTIVE="$runtime/socket.active"
    export VW_CROWDSEC_ETC_DIR="$runtime/etc/crowdsec"
    export VW_SYSTEMD_UNIT_DEST_DIR="$runtime/units"
    export VW_SYSTEMD_OPT_SCRIPTS_DIR="$runtime/opt"
    export VW_CROWDSEC_NOTIFICATIONS_LOCK="$runtime/notify.lock"

    if bash "$fixture/utilities/crowdsec-notifications.sh" reconcile \
        >"$runtime/duplicate.out" 2>"$runtime/duplicate.err"; then
        fail "duplicate auto plugin name was accepted"
    fi
    grep -Fq 'already defined in operator file' "$runtime/duplicate.err" \
        || fail "duplicate auto plugin failure was not actionable"
    rm -rf "$runtime/etc/crowdsec/notifications/operator"

    printf 'name: operator_main\nfilters:\n  - true\nnotifications:\n  - vaultwarden_auto\non_success: continue\n' \
        >"$runtime/etc/crowdsec/profiles.yaml"
    if bash "$fixture/utilities/crowdsec-notifications.sh" reconcile \
        >"$runtime/duplicate-profile.out" 2>"$runtime/duplicate-profile.err"; then
        fail "duplicate operator profile reference was accepted"
    fi
    grep -Fq 'operator profile already references' "$runtime/duplicate-profile.err" \
        || fail "duplicate operator profile failure was not actionable"
    rm -f "$runtime/etc/crowdsec/profiles.yaml"

    bash "$fixture/utilities/crowdsec-notifications.sh" reconcile
    grep -Fxq '# Managed by VaultWarden-OCI: CrowdSec auto notification' \
        "$runtime/etc/crowdsec/notifications/vaultwarden-auto.yaml" || fail "auto plugin not installed"
    grep -Fq 'name: operator_profile' "$runtime/etc/crowdsec/profiles.yaml.local" || fail "operator profile lost"
    grep -Fq '# BEGIN VaultWarden-OCI CrowdSec auto notifications' \
        "$runtime/etc/crowdsec/profiles.yaml.local" || fail "auto profile not installed"
    grep -Fxq 'CROWDSEC_EMAIL_NOTIFICATIONS=false' "$fixture/.env" || fail "legacy SMTP flag not disabled"
    [[ -f "$runtime/socket.active" ]] || fail "adapter socket not enabled"
    [[ "$(stat -c '%a' "$runtime/etc/crowdsec")" == 755 ]] \
        || fail "reconciliation changed existing CrowdSec directory permissions"

    sed -i 's/CROWDSEC_NOTIFICATION_MODE=auto/CROWDSEC_NOTIFICATION_MODE=smtp/' "$fixture/.env"
    : >"$runtime/calls.log"
    bash "$fixture/utilities/crowdsec-notifications.sh" reconcile
    [[ ! -e "$runtime/etc/crowdsec/notifications/vaultwarden-auto.yaml" ]] || fail "auto plugin retained in SMTP mode"
    ! grep -Fq '# BEGIN VaultWarden-OCI CrowdSec auto notifications' \
        "$runtime/etc/crowdsec/profiles.yaml.local" || fail "auto profile retained in SMTP mode"
    grep -Fxq 'CROWDSEC_EMAIL_NOTIFICATIONS=true' "$fixture/.env" || fail "legacy SMTP flag not enabled"
    [[ ! -f "$runtime/socket.active" ]] || fail "adapter socket retained in SMTP mode"

    sed -i 's/CROWDSEC_NOTIFICATION_MODE=smtp/CROWDSEC_NOTIFICATION_MODE=auto/' "$fixture/.env"
    bash "$fixture/utilities/crowdsec-notifications.sh" reconcile >/dev/null
    chmod 0600 "$runtime/etc/crowdsec/notifications/vaultwarden-auto.yaml"
    cp "$runtime/etc/crowdsec/notifications/vaultwarden-auto.yaml" "$runtime/plugin.before"
    cp "$runtime/etc/crowdsec/profiles.yaml.local" "$runtime/profiles.before"
    set +e
    VW_TEST_CROWDSEC_FAIL=1 bash "$fixture/utilities/crowdsec-notifications.sh" reconcile \
        >"$runtime/rollback.out" 2>"$runtime/rollback.err"
    rc=$?
    set -e
    (( rc != 0 )) || fail "validation failure returned success"
    cmp -s "$runtime/plugin.before" "$runtime/etc/crowdsec/notifications/vaultwarden-auto.yaml" \
        || fail "validation failure did not restore plugin"
    [[ "$(stat -c '%a' "$runtime/etc/crowdsec/notifications/vaultwarden-auto.yaml")" == 600 ]] \
        || fail "validation failure did not restore plugin metadata"
    cmp -s "$runtime/profiles.before" "$runtime/etc/crowdsec/profiles.yaml.local" \
        || fail "validation failure did not restore profiles"

    bash "$fixture/utilities/crowdsec-notifications.sh" uninstall >/dev/null
    [[ ! -e "$runtime/etc/crowdsec/notifications/vaultwarden-auto.yaml" ]] \
        || fail "uninstall retained the auto plugin"
    [[ ! -e "$runtime/units/vaultwarden-crowdsec-notify.socket" ]] \
        || fail "uninstall retained the socket unit"
    [[ ! -e "$runtime/units/vaultwarden-crowdsec-notify@.service" ]] \
        || fail "uninstall retained the service unit"
    [[ ! -e "$runtime/opt/utilities/crowdsec-notify-adapter.sh" ]] \
        || fail "uninstall retained the installed adapter"
)

bash -n "$ROOT/utilities/crowdsec-notify-adapter.sh" \
        "$ROOT/utilities/crowdsec-notifications.sh"
check_adapter
check_reconciler
printf 'CrowdSec auto notification tests passed.\n'
