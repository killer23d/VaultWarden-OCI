#!/usr/bin/env bash
# Consolidated CrowdSec regression suite.
set -euo pipefail

check_crowdsec_configuration() (
# Focused checks for the CrowdSec collection set, log acquisition, and
# Vaultwarden log format required by the CrowdSec Vaultwarden parser.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_file_contains() {
    local file="$1" pattern="$2"
    grep -Fq -- "$pattern" "$file" || fail "expected ${file} to contain: ${pattern}"
}

assert_file_not_contains() {
    local file="$1" pattern="$2"
    if grep -Fq -- "$pattern" "$file"; then
        fail "expected ${file} not to contain: ${pattern}"
    fi
}

setup_script="${PROJECT_ROOT}/utilities/setup-crowdsec.sh"
compose_example="${PROJECT_ROOT}/docker-compose.yml.example"
acquis_file="${PROJECT_ROOT}/crowdsec/acquis.yaml"
env_example="${PROJECT_ROOT}/.env.example"
docs_file="${PROJECT_ROOT}/docs/CROWDSEC.md"

expected_collections=(
    "crowdsecurity/caddy"
    "crowdsecurity/linux"
    "crowdsecurity/iptables"
    "Dominic-Wagner/vaultwarden"
)

for collection in "${expected_collections[@]}"; do
    assert_file_contains "$setup_script" "collections install ${collection}"
    assert_file_contains "$env_example" "$collection"
    assert_file_contains "$docs_file" "$collection"
done

inactive_collections=(
    "crowdsecurity/http-cve"
    "crowdsecurity/base-http-scenarios"
    "crowdsecurity/whitelist-good-actors"
)

for collection in "${inactive_collections[@]}"; do
    assert_file_not_contains "$setup_script" "collections install ${collection}"
    assert_file_not_contains "$env_example" "$collection"
done

# AppSec collections may appear only in removal/commentary paths until a real
# AppSec listener and request-forwarding integration exists.
assert_file_not_contains "$setup_script" "cscli collections install crowdsecurity/appsec-generic-rules"
assert_file_not_contains "$setup_script" "cscli collections install crowdsecurity/appsec-virtual-patching"
assert_file_not_contains "$env_example" "crowdsecurity/appsec-generic-rules"
assert_file_not_contains "$env_example" "crowdsecurity/appsec-virtual-patching"

# Firewall/kernel events should be acquired once through journald and enter the
# CrowdSec parser pipeline as syslog, not through duplicate kern.log/messages.
kernel_sources=$(grep -Fc '_TRANSPORT=kernel' "$acquis_file")
[[ "$kernel_sources" == "1" ]] || fail "expected exactly one kernel journald source, found ${kernel_sources}"
assert_file_contains "$acquis_file" 'source: journalctl'
assert_file_contains "$acquis_file" 'type: syslog'
assert_file_contains "$acquis_file" 'OCI Security List or another provider-side firewall never reaches journald'
assert_file_contains "$acquis_file" 'avoid'

# Vaultwarden must emit timestamps with a numeric UTC offset for the
# Dominic-Wagner/vaultwarden parser. Preserve Cloudflare client-IP handling.
assert_file_contains "$compose_example" 'LOG_TIMESTAMP_FORMAT: "%Y-%m-%d %H:%M:%S.%3f%z"'
assert_file_contains "$compose_example" 'IP_HEADER: ${IP_HEADER:-CF-Connecting-IP}'

cf_bouncer_install_block="$(awk '/Attempting apt install of crowdsec-cloudflare-worker-bouncer/,/Installed crowdsec-cloudflare-worker-bouncer via apt/' "$setup_script")"
grep -Fq 'Dpkg::Options::=--force-confdef' <<< "$cf_bouncer_install_block" \
    || fail "Cloudflare Workers bouncer apt install must include --force-confdef"
grep -Fq 'Dpkg::Options::=--force-confold' <<< "$cf_bouncer_install_block" \
    || fail "Cloudflare Workers bouncer apt install must preserve the project-created stub config with --force-confold"
if grep -Fq 'apt-get install -y crowdsec-cloudflare-worker-bouncer' "$setup_script"; then
    fail "Cloudflare Workers bouncer apt install regressed to bare noninteractive apt without dpkg conffile policy"
fi

printf 'CrowdSec configuration tests passed.\n'

)

check_crowdsec_configuration

check_crowdsec_worker_apply_helper() (
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

install() {
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|-g) shift 2 ;;
            *) args+=("$1"); shift ;;
        esac
    done
    command install "${args[@]}"
}
chown() { return 0; }
decrypt_secret() {
    case "$1" in
        cf_worker_bouncer_token) printf 'NEW_WORKER_TOKEN' ;;
        cloudflare_zone_id) printf 'NEW_ZONE_ID' ;;
        cf_account_id) printf 'NEW_ACCOUNT_ID' ;;
        *) return 1 ;;
    esac
}
cleanup_secrets_environment() { return 0; }

export PROJECT_ROOT
export CLOUDFLARE_PROXY_ENABLED=true
export DOMAIN_NAME="vault.example.test"
export CROWDSEC_CF_BOUNCER_API_KEY="NEW_LAPI_KEY"
export CF_ACCOUNT_EMAIL="ops@example.test"
export CF_FREE_PLAN=true

# shellcheck source=../lib/log.sh
source "$PROJECT_ROOT/lib/log.sh"
# shellcheck source=../lib/config.sh
source "$PROJECT_ROOT/lib/config.sh"
# shellcheck source=../lib/common.sh
source "$PROJECT_ROOT/lib/common.sh"
# shellcheck source=../lib/crowdsec-worker.sh
source "$PROJECT_ROOT/lib/crowdsec-worker.sh"

is_root() { return 0; }
load_project_environment() { return 0; }
crowdsec_worker_service_exists() { return 1; }

cp "$PROJECT_ROOT/crowdsec/crowdsec-cloudflare-worker-bouncer.yaml.example" "$TMP/template.yaml"
export CROWDSEC_WORKER_CONFIG_SRC="$TMP/template.yaml"
export CROWDSEC_WORKER_CONFIG_DEST="$TMP/rendered.yaml"

crowdsec_worker_apply_config --allow-missing-service >/dev/null \
    || fail "worker config apply helper failed with valid inputs"
grep -Fq 'NEW_WORKER_TOKEN' "$TMP/rendered.yaml" || fail "rendered config missing new worker token"
grep -Fq 'NEW_ZONE_ID' "$TMP/rendered.yaml" || fail "rendered config missing new zone id"
grep -Fq 'NEW_ACCOUNT_ID' "$TMP/rendered.yaml" || fail "rendered config missing new account id"
grep -Fq 'NEW_LAPI_KEY' "$TMP/rendered.yaml" || fail "rendered config missing LAPI key"
! grep -Eq '%%[^%]+%%' "$TMP/rendered.yaml" || fail "rendered config contains unresolved template variables"

cp "$PROJECT_ROOT/crowdsec/crowdsec-cloudflare-worker-bouncer.yaml.example" "$TMP/unresolved.yaml"
printf '\nunresolved: %s\n' '%%MISSING_VALUE%%' >> "$TMP/unresolved.yaml"
CROWDSEC_WORKER_CONFIG_SRC="$TMP/unresolved.yaml" \
CROWDSEC_WORKER_CONFIG_DEST="$TMP/unresolved-out.yaml" \
    crowdsec_worker_apply_config --allow-missing-service >/tmp/vw-crowdsec-unresolved.$$ 2>&1 \
    && { rm -f /tmp/vw-crowdsec-unresolved.$$; fail "unresolved template render unexpectedly succeeded"; }
grep -Fq 'unresolved template variables' /tmp/vw-crowdsec-unresolved.$$ \
    || fail "unresolved template failure did not name unresolved variables"
rm -f /tmp/vw-crowdsec-unresolved.$$

cp "$PROJECT_ROOT/crowdsec/crowdsec-cloudflare-worker-bouncer.yaml.example" "$TMP/invalid.yaml"
printf '\nbad_yaml: [\n' >> "$TMP/invalid.yaml"
CROWDSEC_WORKER_CONFIG_SRC="$TMP/invalid.yaml" \
CROWDSEC_WORKER_CONFIG_DEST="$TMP/invalid-out.yaml" \
    crowdsec_worker_apply_config --allow-missing-service >/tmp/vw-crowdsec-invalid.$$ 2>&1 \
    && { rm -f /tmp/vw-crowdsec-invalid.$$; fail "invalid YAML render unexpectedly succeeded"; }
grep -Fq 'rendered YAML is invalid' /tmp/vw-crowdsec-invalid.$$ \
    || fail "invalid YAML failure did not report validation"
rm -f /tmp/vw-crowdsec-invalid.$$

crowdsec_worker_service_exists() { return 0; }
systemctl() {
    case "$1" in
        restart) return 42 ;;
        *) return 0 ;;
    esac
}
CROWDSEC_WORKER_CONFIG_SRC="$TMP/template.yaml" \
CROWDSEC_WORKER_CONFIG_DEST="$TMP/restart-fail.yaml" \
    crowdsec_worker_apply_config --require-service >/tmp/vw-crowdsec-restart.$$ 2>&1 \
    && { rm -f /tmp/vw-crowdsec-restart.$$; fail "restart failure unexpectedly succeeded"; }
grep -Fq 'Failed to restart crowdsec-cloudflare-worker-bouncer' /tmp/vw-crowdsec-restart.$$ \
    || fail "restart failure did not report failed service"
rm -f /tmp/vw-crowdsec-restart.$$

grep -Fq 'crowdsec_worker_apply_config --require-service' "$PROJECT_ROOT/utilities/secrets-rotate.sh" \
    || fail "CrowdSec Workers credential rotation must invoke narrow apply helper"
grep -Fq 'Retry exactly this apply step with: sudo ./utilities/crowdsec-worker-apply.sh' "$PROJECT_ROOT/utilities/secrets-rotate.sh" \
    || fail "rotation apply failure must print exact retry command"
grep -Fq '_apply_status="disabled"' "$PROJECT_ROOT/utilities/secrets-rotate.sh" \
    || fail "disabled Cloudflare proxy rotation must use a distinct disabled apply status"
grep -Fq 'CLOUDFLARE_PROXY_ENABLED is not true' "$PROJECT_ROOT/utilities/secrets-rotate.sh" \
    || fail "disabled Cloudflare proxy rotation must explain why Workers apply was skipped"
grep -Fq 'no active Worker consumer was re-rendered or verified' "$PROJECT_ROOT/utilities/secrets-rotate.sh" \
    || fail "disabled Cloudflare proxy receipt must not claim Worker render or verification"
grep -Fq 'crowdsec_worker_apply_config --allow-missing-service' "$PROJECT_ROOT/utilities/setup-crowdsec.sh" \
    || fail "setup-crowdsec Phase 6 must reuse narrow apply helper"

printf 'CrowdSec worker apply helper tests passed.\n'
)

check_crowdsec_worker_apply_helper

check_crowdsec_lapi_cohort_and_required_services() (
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$ROOT/utilities/setup-crowdsec.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log_info(){ printf 'INFO: %s\n' "$*"; }
log_warn(){ printf 'WARN: %s\n' "$*"; }
log_error(){ printf 'ERROR: %s\n' "$*"; }
log_success(){ printf 'SUCCESS: %s\n' "$*"; }

extract_func(){
    local file="$1" func="$2"
    awk -v f="$func" '
      $0 ~ "^" f "\\(\\)" {p=1}
      p {
        print
        opens=gsub(/\{/,"{"); closes=gsub(/\}/,"}")
        depth += opens - closes
        if (depth == 0) exit
      }' "$file"
}

install(){
    local -a args=()
    while (( $# )); do
        case "$1" in
            -o|-g) shift 2 ;;
            *) args+=("$1"); shift ;;
        esac
    done
    command install "${args[@]}"
}

VW_CROWDSEC_ETC_DIR="$TMP/etc-crowdsec"
export VW_CROWDSEC_ETC_DIR
sed -n '/^_CS_LAPI_COHORT_ROOT=/,/^_cs_diagnose_port()/p' "$SETUP" | sed '$d' \
    > "$TMP/lapi-cohort-functions.sh"
# shellcheck source=/dev/null
source "$TMP/lapi-cohort-functions.sh"

write_cohort(){
    local engine_port="$1" consumer_port="$2" root="$_CS_LAPI_COHORT_ROOT"
    mkdir -p "$root/bouncers"
    printf 'api:\n  server:\n    listen_uri: 127.0.0.1:%s\n' "$engine_port" > "$root/config.yaml"
    printf 'url: http://127.0.0.1:%s\nlogin: local\n' "$consumer_port" > "$root/local_api_credentials.yaml"
    printf 'api_url: http://127.0.0.1:%s/\napi_key: test\n' "$consumer_port" > "$root/bouncers/crowdsec-firewall-bouncer.yaml"
    printf 'crowdsec_config:\n  lapi_url: http://127.0.0.1:%s/\n  lapi_key: test\n' "$consumer_port" > "$root/bouncers/crowdsec-cloudflare-worker-bouncer.yaml"
    chmod 600 "${_CS_LAPI_COHORT_PATHS[@]}"
}

write_cohort 8080 8080
signal_rc=0
(
    set -euo pipefail
    VW_TEST_CROWDSEC_SIGNAL_AFTER_PORT_PROMOTION=1
    export VW_TEST_CROWDSEC_SIGNAL_AFTER_PORT_PROMOTION
    # Bash preserves the pre-trap status after an EXIT trap. Keep cleanup
    # status-neutral so the injected TERM remains observable as 143.
    trap 'if [[ "$_CS_LAPI_COHORT_COMMITTED" != true ]]; then _cs_lapi_cohort_rollback || true; _cs_lapi_cohort_cleanup; fi' EXIT
    trap 'exit 143' TERM
    _cs_reconcile_lapi_port_cohort 8090
) >"$TMP/cohort-signal.out" 2>&1 || signal_rc=$?
[[ "$signal_rc" -eq 143 ]] \
    || fail "partial CrowdSec cohort promotion returned $signal_rc instead of TERM status 143"
_cs_validate_lapi_port_cohort 8080 \
    || fail "partial CrowdSec cohort promotion did not restore the coherent old port"
for file in "${_CS_LAPI_COHORT_PATHS[@]}"; do
    grep -Fq '8080' "$file" || fail "restored CrowdSec cohort member lost old port: $file"
    ! grep -Fq '8090' "$file" || fail "restored CrowdSec cohort member retained new port: $file"
done

write_cohort 8090 8080
_cs_ensure_lapi_port_cohort 8090 >"$TMP/cohort-converge.out" 2>&1 \
    || { cat "$TMP/cohort-converge.out" >&2; fail "normal rerun did not reconcile seeded mixed CrowdSec cohort"; }
_cs_validate_lapi_port_cohort 8090 \
    || fail "normal rerun left CrowdSec cohort mixed"

eval "$(extract_func "$SETUP" _cs_wait_for_required_service)"
eval "$(extract_func "$SETUP" _cs_activate_required_services)"
sleep(){ :; }
journalctl(){ :; }
_cs_wait_for_lapi(){ return 0; }
_cs_resolve_lapi_port(){ printf '8090\n'; }
_cf_worker_bouncer_service_exists(){ return 0; }

systemctl(){
    local cmd="${1:-}" service="${*: -1}"
    case "$cmd" in
        is-active)
            [[ "$service" == crowdsec ]] && return 0
            if [[ "${FAIL_ACTIVE_SERVICE:-}" == "$service" ]]; then return 3; fi
            return 0
            ;;
        enable)
            if [[ "${FAIL_ENABLE_SERVICE:-}" == "$service" ]]; then return 5; fi
            return 0
            ;;
        reset-failed|reload|restart) return 0 ;;
        *) return 0 ;;
    esac
}

run_required_service_completion(){
    if _cs_activate_required_services; then
        log_success "Services enabled."
        log_info "CrowdSec setup complete"
        return 0
    fi
    return 1
}

_CF_PROXY_ENABLED=false
AUTONOMOUS_MODE=false
FAIL_ENABLE_SERVICE=crowdsec-firewall-bouncer
export AUTONOMOUS_MODE FAIL_ENABLE_SERVICE
fw_rc=0
run_required_service_completion >"$TMP/firewall-fail.out" 2>&1 || fw_rc=$?
(( fw_rc != 0 )) || fail "firewall-bouncer enable/start failure returned success"
! grep -Eq 'Services enabled|CrowdSec setup complete|enabled and started' "$TMP/firewall-fail.out" \
    || fail "firewall-bouncer failure reached setup completion text"

_CF_PROXY_ENABLED=true
AUTONOMOUS_MODE=false
FAIL_ENABLE_SERVICE=crowdsec-cloudflare-worker-bouncer
export FAIL_ENABLE_SERVICE
worker_rc=0
run_required_service_completion >"$TMP/worker-fail.out" 2>&1 || worker_rc=$?
(( worker_rc != 0 )) || fail "required Worker enable/start failure returned success"
! grep -Eq 'Services enabled|CrowdSec setup complete|enabled and started' "$TMP/worker-fail.out" \
    || fail "required Worker failure reached setup completion text"

eval "$(extract_func "$SETUP" _cs_ensure_fw_bouncer_key)"
FORCE=true
export FORCE
_CS_FW_BOUNCER_KEY_GENERATED=""
openssl(){ printf 'test-generated-key\n'; }
cscli(){ [[ "$*" == *'bouncers add'* ]] && return 9; return 0; }
printf 'api_key: old-key\n' > "$TMP/firewall.yaml"
registration_rc=0
_cs_ensure_fw_bouncer_key "$TMP/firewall.yaml" >"$TMP/registration-fail.out" 2>&1 || registration_rc=$?
(( registration_rc != 0 )) || fail "firewall-bouncer registration failure was swallowed"
grep -Fq 'api_key: old-key' "$TMP/firewall.yaml" \
    || fail "failed firewall-bouncer registration wrote an unregistered key to config"
! grep -Fq 'regenerated and written to config' "$TMP/registration-fail.out" \
    || fail "failed firewall-bouncer registration printed success wording"

printf 'CrowdSec LAPI cohort and required-service truthfulness tests passed.\n'
)

check_crowdsec_lapi_cohort_and_required_services

# Variables in this behavioral harness are consumed by dynamically extracted
# production functions.
# shellcheck disable=SC2034
check_crowdsec_email_notifications() (
set -euo pipefail

ROOT="${VW_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SETUP="$ROOT/utilities/setup-crowdsec.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log_info(){ :; }
log_warn(){ :; }
log_success(){ :; }
log_error(){ printf 'ERROR: %s\n' "$*" >&2; }

install(){
    local -a args=()
    while (( $# )); do
        case "$1" in
            -o|-g) shift 2 ;;
            *) args+=("$1"); shift ;;
        esac
    done
    command install "${args[@]}"
}
chown(){ return 0; }
stat(){
    if [[ "${1:-}" == "-c" ]]; then
        case "$2" in
            %a) command stat -f '%Lp' "$3" ;;
            %u) command stat -f '%u' "$3" ;;
            %g) command stat -f '%g' "$3" ;;
            *) return 2 ;;
        esac
    else
        command stat "$@"
    fi
}

_CS_LAPI_COHORT_ROOT="$TMP/etc-crowdsec"
sed -n '/^_CS_EMAIL_PLUGIN_MARKER=/,/^# CLI flags/p' "$SETUP" | sed '$d' > "$TMP/email-functions.sh"
# shellcheck source=/dev/null
source "$TMP/email-functions.sh"

VALIDATION_RC=0
RESTART_RC=0
crowdsec(){ [[ "${1:-}" == "-t" ]] || return 2; return "$VALIDATION_RC"; }
systemctl(){ [[ "${1:-}" == "restart" && "${2:-}" == "crowdsec" ]] || return 0; return "$RESTART_RC"; }

DRY_RUN=false
ADMIN_EMAIL=admin@example.test
SMTP_FROM=security@example.test
CROWDSEC_EMAIL_NOTIFICATIONS=true
export ADMIN_EMAIL SMTP_FROM CROWDSEC_EMAIL_NOTIFICATIONS
mkdir -p "$_CS_LAPI_COHORT_ROOT"
printf 'name: operator_profile\nfilters:\n  - true\non_success: continue\n' \
    > "$_CS_LAPI_COHORT_ROOT/profiles.yaml.local"
cp "$_CS_LAPI_COHORT_ROOT/profiles.yaml.local" "$TMP/operator.original"

_cs_reconcile_email_notifications \
    || fail "enabled CrowdSec email reconciliation failed"
plugin="$_CS_LAPI_COHORT_ROOT/notifications/vaultwarden-email.yaml"
profiles="$_CS_LAPI_COHORT_ROOT/profiles.yaml.local"
grep -Fxq 'smtp_host: 127.0.0.1' "$plugin" || fail "plugin does not use loopback Postfix"
grep -Fxq 'smtp_port: 587' "$plugin" || fail "plugin does not use loopback Postfix port"
grep -Fxq 'auth_type: none' "$plugin" || fail "plugin unexpectedly requires authentication"
grep -Fxq 'encryption_type: none' "$plugin" || fail "plugin unexpectedly enables encryption on loopback hop"
grep -Fq "sender_email: 'security@example.test'" "$plugin" || fail "SMTP_FROM was not rendered"
grep -Fq -- "- 'admin@example.test'" "$plugin" || fail "ADMIN_EMAIL was not rendered"
! grep -Eiq 'smtp_password|smtp_username|email_api_token|authorization|api[_-]?token' "$plugin" \
    || fail "plugin rendered a credential field"
grep -Fxq 'on_success: continue' "$profiles" || fail "notification profile can stop remediation"
grep -Fq 'name: operator_profile' "$profiles" || fail "operator profile content was lost"

before="$(shasum -a 256 "$plugin" "$profiles")"
_cs_reconcile_email_notifications || fail "repeat reconciliation failed"
after="$(shasum -a 256 "$plugin" "$profiles")"
[[ "$before" == "$after" ]] || fail "repeat reconciliation was not byte-stable"

CROWDSEC_EMAIL_NOTIFICATIONS=false
export CROWDSEC_EMAIL_NOTIFICATIONS
_cs_reconcile_email_notifications || fail "disable reconciliation failed"
[[ ! -e "$plugin" ]] || fail "disable retained the marked plugin"
cmp -s "$TMP/operator.original" "$profiles" || fail "disable changed operator profile content"

mkdir -p "$(dirname "$plugin")"
printf 'type: email\nname: operator_owned\n' > "$plugin"
if _cs_reconcile_email_notifications >"$TMP/conflict.out" 2>&1; then
    fail "disable deleted an unmarked operator plugin"
fi
grep -Fq 'name: operator_owned' "$plugin" || fail "unmarked operator plugin was modified"
rm -f "$plugin"

CROWDSEC_EMAIL_NOTIFICATIONS=true
export CROWDSEC_EMAIL_NOTIFICATIONS
_cs_reconcile_email_notifications || fail "could not seed rollback fixture"
cp "$plugin" "$TMP/plugin.before"
cp "$profiles" "$TMP/profiles.before"
printf '# local operator tail\n' >> "$profiles"
cp "$profiles" "$TMP/profiles.validation-before"
VALIDATION_RC=9
if _cs_reconcile_email_notifications >"$TMP/validation.out" 2>&1; then
    fail "static validation failure returned success"
fi
cmp -s "$TMP/plugin.before" "$plugin" || fail "validation failure did not restore plugin"
cmp -s "$TMP/profiles.validation-before" "$profiles" || fail "validation failure did not restore profiles"
grep -Fq 'crowdsec -t' "$TMP/validation.out" || fail "validation failure did not name the failing command"

VALIDATION_RC=0
RESTART_RC=7
cp "$plugin" "$TMP/plugin.restart-before"
cp "$profiles" "$TMP/profiles.restart-before"
if _cs_reconcile_email_notifications >"$TMP/restart.out" 2>&1; then
    fail "CrowdSec restart failure returned success"
fi
cmp -s "$TMP/plugin.restart-before" "$plugin" || fail "restart failure did not restore plugin"
cmp -s "$TMP/profiles.restart-before" "$profiles" || fail "restart failure did not restore profiles"
grep -Fq 'systemctl restart crowdsec' "$TMP/restart.out" || fail "restart failure did not name the failing command"

grep -Fxq 'CROWDSEC_EMAIL_NOTIFICATIONS=false' "$ROOT/.env.example" \
    || fail "CrowdSec email notifications are not disabled by default"
! grep -Fq 'CROWDSEC_EMAIL_NOTIFICATIONS' "$ROOT/secrets-schema.yaml" \
    || fail "non-secret CrowdSec option was added to the secret schema"
! grep -Eq 'nc .*127\.0\.0\.1.*587|curl .*127\.0\.0\.1.*587' "$SETUP" \
    || fail "normal setup unexpectedly requires live Postfix connectivity"
grep -Fq 'sudo cscli notifications test vaultwarden_email' "$ROOT/docs/CROWDSEC.md" \
    || fail "CrowdSec documentation omits the explicit notification test"
! grep -E 'cscli notifications test vaultwarden_email.*\|\|[[:space:]]*true' "$ROOT/docs/CROWDSEC.md" \
    || fail "documented explicit notification test hides delivery failure"

printf 'CrowdSec email notification transaction tests passed.\n'
)

check_crowdsec_email_notifications

check_crowdsec_email_health_visibility() (
set -euo pipefail
ROOT="${VW_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HEALTH="$ROOT/utilities/maintenance-health.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
extract_func(){
    local file="$1" func="$2"
    awk -v f="$func" '
      $0 ~ "^" f "\\(\\)" {p=1}
      p { print; opens=gsub(/\{/ ,"{"); closes=gsub(/\}/,"}"); depth += opens-closes; if (depth==0) exit }
    ' "$file"
}
eval "$(extract_func "$HEALTH" _check_crowdsec_email_notifications)"
RESULTS=""
_pass(){ RESULTS+="pass:$1:$2\n"; }
_warn(){ RESULTS+="warn:$1:$2\n"; }
crowdsec(){ return "${VALIDATION_RC:-0}"; }
VW_CROWDSEC_ETC_DIR="$TMP/etc-crowdsec"
export VW_CROWDSEC_ETC_DIR

CROWDSEC_EMAIL_NOTIFICATIONS=false
RESULTS=""
_check_crowdsec_email_notifications
[[ "$RESULTS" == pass:*disabled* ]] || fail "disabled notifications were not reported as a clean pass"
[[ "$RESULTS" != *warn:* ]] || fail "disabled optional notifications produced a warning"

CROWDSEC_EMAIL_NOTIFICATIONS=true
RESULTS=""
_check_crowdsec_email_notifications
[[ "$RESULTS" == warn:*plugin*missing* ]] || fail "missing enabled plugin state was not distinct"

mkdir -p "$VW_CROWDSEC_ETC_DIR/notifications"
printf '# Managed by VaultWarden-OCI: CrowdSec email notification\n' \
    > "$VW_CROWDSEC_ETC_DIR/notifications/vaultwarden-email.yaml"
RESULTS=""
_check_crowdsec_email_notifications
[[ "$RESULTS" == warn:*profile*missing* ]] || fail "missing profile block state was not distinct"

printf '# BEGIN VaultWarden-OCI CrowdSec email notifications\n# END VaultWarden-OCI CrowdSec email notifications\n' \
    > "$VW_CROWDSEC_ETC_DIR/profiles.yaml.local"
VALIDATION_RC=8
RESULTS=""
_check_crowdsec_email_notifications
[[ "$RESULTS" == *pass:*configured* && "$RESULTS" == *warn:*validation*failed* ]] \
    || fail "invalid configured state was not reported distinctly"

VALIDATION_RC=0
RESULTS=""
_check_crowdsec_email_notifications
[[ "$RESULTS" == *pass:*configured* && "$RESULTS" == *pass:*validation*valid* ]] \
    || fail "statically valid enabled state was not reported"

printf 'CrowdSec email notification health visibility tests passed.\n'
)

check_crowdsec_email_health_visibility
