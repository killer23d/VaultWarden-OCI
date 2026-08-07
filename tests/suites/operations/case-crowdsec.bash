#!/usr/bin/env bash
# Consolidated CrowdSec regression suite.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"
# shellcheck source=../../lib/assertions.bash
source "$VW_TEST_REPO_ROOT/tests/lib/assertions.bash"
# shellcheck source=../../lib/command-mocks.bash
source "$VW_TEST_REPO_ROOT/tests/lib/command-mocks.bash"

check_crowdsec_configuration() (
# Focused checks for the CrowdSec collection set, log acquisition, and
# Vaultwarden log format required by the CrowdSec Vaultwarden parser.

set -euo pipefail

PROJECT_ROOT="$VW_TEST_REPO_ROOT"

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

check_crowdsec_yq_resolution() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
PROJECT_ROOT="$ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
log_error() { printf 'ERROR: %s\n' "$*" >&2; }

sed -n '/^_CS_EMAIL_PLUGIN_MARKER=/,/^# CLI flags/p' \
    "$ROOT/utilities/setup-crowdsec.sh" | sed '$d' >"$TMP/yq-resolution-functions.bash"
# shellcheck source=/dev/null
source "$TMP/yq-resolution-functions.bash"

mike_yq_bin="$TMP/Mike Farah yq bin"
v3_yq_bin="$TMP/v3-yq-bin"
python_yq_bin="$TMP/python-yq-bin"
missing_yq_bin="$TMP/missing-yq-bin"
for fixture_bin in "$mike_yq_bin" "$v3_yq_bin" "$python_yq_bin" "$missing_yq_bin"; do
    test_build_isolated_path "$fixture_bin" bash >/dev/null
done

test_write_command_mock "$mike_yq_bin/yq" <<'EOF_MIKE_YQ'
if [[ "${1:-}" == "--version" ]]; then
    printf 'release metadata follows\nYQ (https://github.com/mikefarah/yq/) VERSION v4.53.3 (stable)\nend metadata\n'
    exit 0
fi
exit 0
EOF_MIKE_YQ
test_write_command_mock "$v3_yq_bin/yq" <<'EOF_V3_YQ'
if [[ "${1:-}" == "--version" ]]; then
    printf 'yq (https://github.com/mikefarah/yq/) version v3.4.1\n'
    exit 0
fi
exit 0
EOF_V3_YQ
test_write_command_mock "$python_yq_bin/yq" <<'EOF_PYTHON_YQ'
if [[ "${1:-}" == "--version" ]]; then
    printf 'yq 3.4.3\n'
    exit 0
fi
exit 0
EOF_PYTHON_YQ

resolved_yq="$(PATH="$mike_yq_bin" _cs_require_mikefarah_yq_v4)" \
    || test_fail "controlled Mike Farah yq v4 command was rejected"
test_assert_equal "$resolved_yq" "$mike_yq_bin/yq"

if PATH="$v3_yq_bin" _cs_require_mikefarah_yq_v4 \
    >"$TMP/v3-yq.out" 2>&1; then
    test_fail "Mike Farah yq v3 command was accepted"
fi
test_assert_file_contains "$TMP/v3-yq.out" "Mike Farah yq v4 is required"
test_assert_file_contains "$TMP/v3-yq.out" "unsupported yq at $v3_yq_bin/yq"

if PATH="$python_yq_bin" _cs_require_mikefarah_yq_v4 \
    >"$TMP/python-yq.out" 2>&1; then
    test_fail "Python yq command was accepted"
fi
test_assert_file_contains "$TMP/python-yq.out" "Mike Farah yq v4 is required"
test_assert_file_contains "$TMP/python-yq.out" "unsupported yq at $python_yq_bin/yq"

test_assert_equal "$(PATH="$missing_yq_bin" command -v bash)" \
    "$missing_yq_bin/bash"
if PATH="$missing_yq_bin" command -v yq >/dev/null 2>&1; then
    test_fail "isolated missing-yq fixture exposed a host yq command"
fi

missing_yq_root="$TMP/missing-yq-crowdsec"
missing_yq_notifications="$missing_yq_root/notifications"
missing_yq_candidate="$missing_yq_notifications/operator-owned.yaml"
missing_yq_managed="$missing_yq_notifications/vaultwarden-email.yaml"
mkdir -p "$missing_yq_notifications"
chmod 0700 "$missing_yq_root" "$missing_yq_notifications"
printf 'name: operator_owned\n' >"$missing_yq_candidate"
chmod 0600 "$missing_yq_candidate"
cp "$missing_yq_candidate" "$TMP/missing-yq-candidate.before"
_CS_LAPI_COHORT_ROOT="$missing_yq_root"
_CS_EMAIL_PLUGIN_PATH="$missing_yq_managed"
_CS_YQ_COMMAND=""
if PATH="$missing_yq_bin" _cs_email_validate_unique_plugin_definition \
    >"$TMP/missing-yq.out" 2>&1; then
    test_fail "CrowdSec YAML inspection accepted a missing yq command"
fi
test_assert_file_contains "$TMP/missing-yq.out" \
    "Mike Farah yq v4 is required"
test_assert_file_contains "$TMP/missing-yq.out" \
    "no yq executable was found in PATH"
cmp -s "$TMP/missing-yq-candidate.before" "$missing_yq_candidate" \
    || test_fail "missing-yq validation modified operator-owned YAML"
test_assert_not_exists "$missing_yq_managed"
if find "$missing_yq_root" -type f ! -name 'operator-owned.yaml' -print -quit | grep -q .; then
    test_fail "missing-yq validation left a partial generated file"
fi

printf 'CrowdSec yq resolution tests passed.\n'
)

check_crowdsec_yq_resolution

check_crowdsec_env_writer_wrapper() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROJECT_ROOT="$TMP/project"
mkdir -p "$PROJECT_ROOT"
CALLS="$TMP/calls"

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log_error(){ printf 'ERROR: %s\n' "$*" >&2; }
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

eval "$(extract_func "$ROOT/utilities/setup-crowdsec.sh" _cs_set_env_var)"
_set_env_var(){ printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$CALLS"; }

_cs_set_env_var CROWDSEC_CF_BOUNCER_API_KEY absent-value
[[ ! -e "$PROJECT_ROOT/.env" && ! -e "$CALLS" ]] \
    || fail 'CrowdSec env wrapper changed its missing-.env success contract'

printf 'CROWDSEC_CF_BOUNCER_API_KEY=old\n' > "$PROJECT_ROOT/.env"
_cs_set_env_var CROWDSEC_CF_BOUNCER_API_KEY new-value
grep -Fxq "CROWDSEC_CF_BOUNCER_API_KEY|new-value|$PROJECT_ROOT/.env" "$CALLS" \
    || fail 'CrowdSec env wrapper did not delegate exact arguments to the canonical helper'

unset -f _set_env_var
if _cs_set_env_var CROWDSEC_CF_BOUNCER_API_KEY unavailable >"$TMP/missing-helper.out" 2>&1; then
    fail 'CrowdSec env wrapper silently continued without lib/config.sh helper'
fi
grep -Fq 'Required configuration helper is unavailable' "$TMP/missing-helper.out" \
    || fail 'CrowdSec env wrapper did not clearly report its missing library helper'

rm -f "$PROJECT_ROOT/.env"
_cs_set_env_var CROWDSEC_CF_BOUNCER_API_KEY still-absent \
    || fail 'missing .env should remain a successful no-op even when the helper is unavailable'

printf 'CrowdSec canonical env writer wrapper tests passed.\n'
)

check_crowdsec_env_writer_wrapper

check_crowdsec_worker_apply_helper() (
set -euo pipefail

PROJECT_ROOT="$VW_TEST_REPO_ROOT"
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

ROOT="$VW_TEST_REPO_ROOT"
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

ROOT="${VW_TEST_ROOT:-$VW_TEST_REPO_ROOT}"
PROJECT_ROOT="$ROOT"
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
    if command stat --version >/dev/null 2>&1; then
        command stat "$@"
        return
    fi
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

_cs_email_address_is_safe "security.o'hara&alerts@example.test" \
    || fail "valid special-character email address was rejected"
unsafe_addresses=(
    "missing-at.example.test"
    "@example.test"
    "admin@"
    "admin@@example.test"
    "admin @example.test"
    "admin@example test"
)
for unsafe_address in "${unsafe_addresses[@]}"; do
    if _cs_email_address_is_safe "$unsafe_address"; then
        fail "unsafe email address was accepted: $unsafe_address"
    fi
done

VALIDATION_RC=0
VALIDATION_WRAPPER_LOG="$TMP/validation-wrapper.log"
: > "$VALIDATION_WRAPPER_LOG"
RESTART_RC=0
crowdsec(){
    printf 'call\n' >> "$VALIDATION_WRAPPER_LOG"
    [[ "${1:-}" == "-t" ]] || return 2
    return "$VALIDATION_RC"
}
systemctl(){ [[ "${1:-}" == "restart" && "${2:-}" == "crowdsec" ]] || return 0; return "$RESTART_RC"; }

DRY_RUN=false
ADMIN_EMAIL=admin@example.test
SMTP_FROM=security@example.test
ALLOWED_SENDER_DOMAINS="example.invalid EXAMPLE.TEST"
CROWDSEC_EMAIL_NOTIFICATIONS=true
CROWDSEC_EMAIL_EVENT_POLICY=all
CROWDSEC_EMAIL_GROUP_WAIT=45s
CROWDSEC_EMAIL_GROUP_THRESHOLD=7
export ADMIN_EMAIL SMTP_FROM ALLOWED_SENDER_DOMAINS CROWDSEC_EMAIL_NOTIFICATIONS
export CROWDSEC_EMAIL_EVENT_POLICY CROWDSEC_EMAIL_GROUP_WAIT
export CROWDSEC_EMAIL_GROUP_THRESHOLD
mkdir -p "$_CS_LAPI_COHORT_ROOT"
printf 'name: operator_profile\nfilters:\n  - true\non_success: continue\n' \
    > "$_CS_LAPI_COHORT_ROOT/profiles.yaml.local"
cp "$_CS_LAPI_COHORT_ROOT/profiles.yaml.local" "$TMP/operator.original"
plugin="$_CS_LAPI_COHORT_ROOT/notifications/vaultwarden-email.yaml"
profiles="$_CS_LAPI_COHORT_ROOT/profiles.yaml.local"

assert_invalid_email_setting() {
    local label="$1" variable="$2" value="$3" previous
    previous="${!variable}"
    printf -v "$variable" '%s' "$value"
    cp "$profiles" "$TMP/${label}.profiles-before"
    if _cs_reconcile_email_notifications >"$TMP/${label}.out" 2>&1; then
        fail "invalid CrowdSec email setting unexpectedly reconciled: $label"
    fi
    [[ ! -d "$(dirname "$plugin")" ]] \
        || fail "invalid CrowdSec email setting created the notifications directory: $label"
    [[ ! -e "$plugin" ]] \
        || fail "invalid CrowdSec email setting installed the plugin: $label"
    cmp -s "$TMP/${label}.profiles-before" "$profiles" \
        || fail "invalid CrowdSec email setting changed profiles: $label"
    printf -v "$variable" '%s' "$previous"
}

assert_invalid_email_setting event-policy CROWDSEC_EMAIL_EVENT_POLICY ALL
assert_invalid_email_setting group-wait CROWDSEC_EMAIL_GROUP_WAIT 0s
assert_invalid_email_setting group-threshold CROWDSEC_EMAIL_GROUP_THRESHOLD 0

_cs_email_sender_domain_is_allowed \
    "security@example.test" "EXAMPLE.TEST other.example" \
    || fail "case-insensitive multi-domain sender allowlist was rejected"

invalid_sender_allowlists=(
    "example.test bad_domain"
    "example.test foo-.example"
    "example.test foo.-example"
    "-bad.example example.test"
    "example.test bad..example"
    ".example.test"
    "example.test."
)
for invalid_allowlist in "${invalid_sender_allowlists[@]}"; do
    if _cs_email_sender_domain_is_allowed "security@example.test" "$invalid_allowlist"; then
        fail "malformed sender allowlist was accepted: $invalid_allowlist"
    fi
done

# The matching domain appears first: validation must still inspect the later
# malformed entry and fail before creating the managed notifications directory.
ALLOWED_SENDER_DOMAINS="example.test bad_domain"
cp "$profiles" "$TMP/sender-domain.profiles-before"
if _cs_reconcile_email_notifications >"$TMP/sender-domain.out" 2>&1; then
    fail "matching sender domain followed by malformed entry unexpectedly enabled email"
fi
grep -Fq 'must exactly match one space-separated ALLOWED_SENDER_DOMAINS entry' \
    "$TMP/sender-domain.out" || fail "malformed allowlist failure did not identify ALLOWED_SENDER_DOMAINS"
[[ ! -d "$(dirname "$plugin")" ]] \
    || fail "malformed sender allowlist created the managed notifications directory"
[[ ! -e "$plugin" ]] || fail "malformed sender allowlist installed the managed plugin"
cmp -s "$TMP/sender-domain.profiles-before" "$profiles" \
    || fail "malformed sender allowlist changed operator profile content"
ALLOWED_SENDER_DOMAINS="example.invalid EXAMPLE.TEST"

assert_plugin_yaml_conflict() {
    local label="$1" content="$2"
    local candidate
    candidate="$(dirname "$plugin")/operator-${label}.yaml"
    mkdir -p "$(dirname "$plugin")"
    printf '%s' "$content" > "$candidate"
    cp "$candidate" "$TMP/${label}.candidate-before"
    cp "$profiles" "$TMP/${label}.profiles-before"
    if _cs_reconcile_email_notifications >"$TMP/${label}.out" 2>&1; then
        fail "operator notification conflict unexpectedly enabled email: $label"
    fi
    grep -Fq "$candidate" "$TMP/${label}.out" \
        || fail "notification conflict did not identify its filename: $label"
    [[ ! -e "$plugin" ]] || fail "notification conflict installed the managed plugin: $label"
    cmp -s "$TMP/${label}.candidate-before" "$candidate" \
        || fail "notification conflict modified operator YAML: $label"
    cmp -s "$TMP/${label}.profiles-before" "$profiles" \
        || fail "notification conflict changed operator profiles: $label"
    rm -f -- "$candidate"
}

assert_plugin_yaml_conflict quoted-key $'type: email\n"name": vaultwarden_email\n'
assert_plugin_yaml_conflict spaced-colon $'type: email\nname : vaultwarden_email\n'
assert_plugin_yaml_conflict indented-root $'  type: email\n  name: vaultwarden_email\n'
assert_plugin_yaml_conflict malformed $'type: email\nname: [\n'

nested_plugin="$(dirname "$plugin")/operator-nested-name.yaml"
cat > "$nested_plugin" <<'EOF_NESTED_PLUGIN'
type: email
name: operator_owned
metadata:
  name: vaultwarden_email
EOF_NESTED_PLUGIN
_cs_email_validate_unique_plugin_definition \
    || fail "nested notification name was falsely treated as the top-level plugin name"
rm -f -- "$nested_plugin"

unreadable_plugin="$(dirname "$plugin")/operator-unreadable.yaml"
ln -s "$TMP/missing-notification.yaml" "$unreadable_plugin"
cp "$profiles" "$TMP/unreadable-plugin.profiles-before"
if _cs_reconcile_email_notifications >"$TMP/unreadable-plugin.out" 2>&1; then
    fail "unreadable notification candidate unexpectedly enabled email"
fi
grep -Fq "$unreadable_plugin" "$TMP/unreadable-plugin.out" \
    || fail "unreadable notification failure did not identify its filename"
[[ ! -e "$plugin" ]] || fail "unreadable notification candidate installed the managed plugin"
cmp -s "$TMP/unreadable-plugin.profiles-before" "$profiles" \
    || fail "unreadable notification candidate changed operator profiles"
rm -f -- "$unreadable_plugin"

assert_profile_yaml_conflict() {
    local label="$1" content="$2"
    cp "$TMP/operator.original" "$profiles"
    printf '%s' "$content" >> "$profiles"
    cp "$profiles" "$TMP/${label}.profiles-before"
    if _cs_reconcile_email_notifications >"$TMP/${label}.out" 2>&1; then
        fail "operator profile conflict unexpectedly enabled email: $label"
    fi
    grep -Fq "$profiles" "$TMP/${label}.out" \
        || fail "profile conflict did not identify its filename: $label"
    [[ ! -e "$plugin" ]] || fail "profile conflict installed the managed plugin: $label"
    cmp -s "$TMP/${label}.profiles-before" "$profiles" \
        || fail "profile conflict changed operator content: $label"
}

assert_profile_yaml_conflict block-list $'---\nname: operator_email_profile\nnotifications:\n  - vaultwarden_email\n'
assert_profile_yaml_conflict inline-list $'---\nname: operator_email_profile\nnotifications: [operator_notification, vaultwarden_email]\n'
assert_profile_yaml_conflict multiline-flow $'---\nname: operator_email_profile\nnotifications:\n  [operator_notification,\n   vaultwarden_email]\n'
assert_profile_yaml_conflict quoted-value $'---\nname: operator_email_profile\nnotifications:\n  - operator_notification\n  - "vaultwarden_email"\n'
assert_profile_yaml_conflict malformed-profile $'---\nname: operator_email_profile\nnotifications: [\n'

cp "$TMP/operator.original" "$profiles"
_cs_email_append_profile_block "$profiles"
_cs_email_validate_unique_profile_reference \
    || fail "the exact VaultWarden-OCI managed profile block was not ignored"
cp "$TMP/operator.original" "$profiles"

unreadable_profile="$_CS_LAPI_COHORT_ROOT/profiles.yaml"
ln -s "$TMP/missing-profiles.yaml" "$unreadable_profile"
cp "$profiles" "$TMP/unreadable-profile.profiles-before"
if _cs_reconcile_email_notifications >"$TMP/unreadable-profile.out" 2>&1; then
    fail "unreadable profile candidate unexpectedly enabled email"
fi
grep -Fq "$unreadable_profile" "$TMP/unreadable-profile.out" \
    || fail "unreadable profile failure did not identify its filename"
[[ ! -e "$plugin" ]] || fail "unreadable profile candidate installed the managed plugin"
cmp -s "$TMP/unreadable-profile.profiles-before" "$profiles" \
    || fail "unreadable profile candidate changed operator content"
rm -f -- "$unreadable_profile"
cp "$TMP/operator.original" "$profiles"

VALIDATION_RC=9

if _cs_reconcile_email_notifications >"$TMP/baseline-invalid.out" 2>&1; then
    fail "pre-existing invalid CrowdSec configuration unexpectedly reached managed promotion"
fi
[[ ! -e "$plugin" ]] || fail "baseline validation failure installed the managed plugin"
cmp -s "$TMP/operator.original" "$profiles" \
    || fail "baseline validation failure changed operator profile content"
grep -Fq 'already invalid before VaultWarden-OCI managed email files are installed' \
    "$TMP/baseline-invalid.out" \
    || fail "baseline validation failure did not identify the pre-existing configuration problem"

VALIDATION_RC=0
_cs_reconcile_email_notifications \
    || fail "enabled CrowdSec email reconciliation failed"
(( $(wc -l < "$VALIDATION_WRAPPER_LOG") >= 3 )) \
    || fail "CrowdSec validation did not consistently use operation descriptor isolation"
grep -Fxq 'smtp_host: 127.0.0.1' "$plugin" || fail "plugin does not use loopback Postfix"
grep -Fxq 'smtp_port: 587' "$plugin" || fail "plugin does not use loopback Postfix port"
grep -Fxq 'auth_type: none' "$plugin" || fail "plugin unexpectedly requires authentication"
grep -Fxq 'encryption_type: none' "$plugin" || fail "plugin unexpectedly enables encryption on loopback hop"
grep -Fxq 'group_wait: 45s' "$plugin" || fail "configured CrowdSec batching wait was not rendered"
grep -Fxq 'group_threshold: 7' "$plugin" || fail "configured CrowdSec batching threshold was not rendered"
grep -Fq "sender_email: 'security@example.test'" "$plugin" || fail "SMTP_FROM was not rendered"
grep -Fq -- "- 'admin@example.test'" "$plugin" || fail "ADMIN_EMAIL was not rendered"

[[ "$(stat -c '%a' "$plugin")" == "640" ]] \
    || fail "managed CrowdSec email plugin was not normalized to mode 0640"
python3 - "$plugin" <<'PY_HTML_TEMPLATE'
import re
import sys
import yaml

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
document = yaml.safe_load(text)
if not isinstance(document, dict):
    raise SystemExit("rendered CrowdSec plugin is not a YAML mapping")
if '<pre style="white-space: pre-wrap; font-family: monospace;">' not in text:
    raise SystemExit("CrowdSec email template is missing the opening pre element")
if '</pre>' not in text:
    raise SystemExit("CrowdSec email template is missing the closing pre element")

fields = (
    "$alert.Source.Value",
    "$alert.Scenario",
    "$alert.MachineID",
    "$decision.Type",
    "$decision.Duration",
)
for field in fields:
    pattern = re.compile(r"{{\s*" + re.escape(field) + r"\s*\|\s*html\s*}}")
    matches = pattern.findall(text)
    if len(matches) != 1:
        raise SystemExit(f"expected exactly one escaped rendering for {field}, found {len(matches)}")
    if field in pattern.sub("", text):
        raise SystemExit(f"unescaped or duplicate rendering remains for {field}")
PY_HTML_TEMPLATE

special_plugin="$TMP/special-addresses.yaml"
SMTP_FROM="security.o'hara&alerts@example.test"
ADMIN_EMAIL="admin&ops@example.test"
_cs_email_write_plugin_stage "$special_plugin" \
    || fail "template rendering failed for valid special-character addresses"
grep -Fq "sender_email: 'security.o''hara&alerts@example.test'" "$special_plugin" \
    || fail "SMTP_FROM special characters were not rendered safely"
grep -Fq -- "- 'admin&ops@example.test'" "$special_plugin" \
    || fail "ADMIN_EMAIL ampersand was not rendered safely"
! grep -Eq '__SMTP_FROM__|__ADMIN_EMAIL__' "$special_plugin" \
    || fail "special-character rendering left unresolved placeholders"
python3 -c '
import sys
import yaml
with open(sys.argv[1], encoding="utf-8") as file:
    document = yaml.safe_load(file)
if not isinstance(document, dict):
    raise SystemExit("rendered CrowdSec plugin is not a YAML mapping")
' "$special_plugin" || fail "rendered CrowdSec email plugin is not valid YAML"
SMTP_FROM=security@example.test
ADMIN_EMAIL=admin@example.test
! grep -Eiq 'smtp_password|smtp_username|email_api_token|authorization|api[_-]?token' "$plugin" \
    || fail "plugin rendered a credential field"
grep -Fxq 'on_success: continue' "$profiles" || fail "notification profile can stop remediation"
grep -Fq 'name: operator_profile' "$profiles" || fail "operator profile content was lost"

before="$(shasum -a 256 "$plugin" "$profiles")"
_cs_reconcile_email_notifications || fail "repeat reconciliation failed"
after="$(shasum -a 256 "$plugin" "$profiles")"
[[ "$before" == "$after" ]] || fail "repeat reconciliation was not byte-stable"

unset CROWDSEC_EMAIL_EVENT_POLICY CROWDSEC_EMAIL_GROUP_WAIT CROWDSEC_EMAIL_GROUP_THRESHOLD
_cs_reconcile_email_notifications || fail "legacy default reconciliation failed"
grep -Fxq 'group_wait: 30s' "$plugin" || fail "missing group wait did not preserve the 30s default"
grep -Fxq 'group_threshold: 10' "$plugin" || fail "missing threshold did not preserve the default of 10"
grep -Fxq "$_CS_EMAIL_PROFILE_BEGIN" "$profiles" \
    || fail "missing event policy did not preserve automatic email behavior"

CROWDSEC_EMAIL_EVENT_POLICY=none
CROWDSEC_EMAIL_GROUP_WAIT=1m
CROWDSEC_EMAIL_GROUP_THRESHOLD=3
_cs_reconcile_email_notifications || fail "none-policy reconciliation failed"
[[ -f "$plugin" ]] || fail "none policy removed the manual-test plugin"
grep -Fxq 'group_wait: 1m' "$plugin" || fail "none policy did not render the configured batching wait"
grep -Fxq 'group_threshold: 3' "$plugin" || fail "none policy did not render the configured threshold"
! grep -Fq "$_CS_EMAIL_PROFILE_BEGIN" "$profiles" \
    || fail "none policy retained the automatic email profile"
grep -Fq 'name: operator_profile' "$profiles" \
    || fail "none policy removed operator profile content"

CROWDSEC_EMAIL_EVENT_POLICY=all
CROWDSEC_EMAIL_GROUP_WAIT=45s
CROWDSEC_EMAIL_GROUP_THRESHOLD=7
_cs_reconcile_email_notifications || fail "all-policy restoration failed"

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
grep -Fxq 'CROWDSEC_EMAIL_EVENT_POLICY=all' "$ROOT/.env.example" \
    || fail "CrowdSec email event policy does not preserve legacy behavior by default"
grep -Fxq 'CROWDSEC_EMAIL_GROUP_WAIT=30s' "$ROOT/.env.example" \
    || fail "CrowdSec email grouping wait default is missing"
grep -Fxq 'CROWDSEC_EMAIL_GROUP_THRESHOLD=10' "$ROOT/.env.example" \
    || fail "CrowdSec email grouping threshold default is missing"
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
ROOT="${VW_TEST_ROOT:-$VW_TEST_REPO_ROOT}"
HEALTH="$ROOT/utilities/maintenance-health.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
extract_func(){
    local file="$1" func="$2"
    awk -v f="$func" '
      $0 ~ "^" f "\\(\\)" {p=1}
      p { print; opens=gsub(/\\{/ ,"{"); closes=gsub(/\\}/,"}"); depth += opens-closes; if (depth==0) exit }
    ' "$file"
}

sed -n '/^_crowdsec_health_sanitize_validation_log() {/,/^_check_disk() {/p' "$HEALTH" \
    | sed '$d' > "$TMP/health-functions.sh"
# shellcheck source=/dev/null
source "$TMP/health-functions.sh"

RESULTS=""
_pass(){ RESULTS+="pass:$1:$2\n"; }
_warn(){ RESULTS+="warn:$1:$2\n"; }

BIN="$TMP/bin"
VALIDATION_TMP="$TMP/validation-tmp"
VALIDATION_OUTPUT_FILE="$TMP/validation-output.log"
mkdir -p "$BIN" "$VALIDATION_TMP"
cat > "$BIN/crowdsec" <<'EOF_CROWDSEC'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "-t" ]] || exit 2
if [[ -n "${EXPECTED_CLOSED_FD:-}" && -e "/proc/${BASHPID}/fd/${EXPECTED_CLOSED_FD}" ]]; then
    printf 'FATAL health lock descriptor %s remained open\n' "$EXPECTED_CLOSED_FD"
    exit 98
fi
[[ -r "${VALIDATION_OUTPUT_FILE:-}" ]] && cat "$VALIDATION_OUTPUT_FILE"
if [[ -n "${VALIDATION_SIGNAL:-}" ]]; then
    kill -s "$VALIDATION_SIGNAL" "${BASHPID}"
    sleep 1
fi
exit "${VALIDATION_RC:-0}"
EOF_CROWDSEC
chmod +x "$BIN/crowdsec"
export PATH="$BIN:$PATH"
export TMPDIR="$VALIDATION_TMP"
export VALIDATION_OUTPUT_FILE

assert_no_validation_logs(){
    if find "$VALIDATION_TMP" -maxdepth 1 -type f -name 'vw-crowdsec-health.*' -print -quit | grep -q .; then
        fail "CrowdSec health validation left a temporary log behind"
    fi
}

sanitize_log="$TMP/sanitize.log"
assert_one_line_bounded(){
    local value="$1" label="$2"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] \
        || fail "$label produced multiline output"
    (( ${#value} <= 240 )) || fail "$label exceeded the 240-character bound"
}

assert_sensitive_redaction(){
    local input="$1" expected="$2" label="$3"
    shift 3
    local detail forbidden
    printf '%s\n' "$input" > "$sanitize_log"
    detail="$(_crowdsec_health_sanitize_validation_log "$sanitize_log")"
    [[ "$detail" == "$expected" ]] \
        || fail "$label produced unexpected detail: $detail"
    [[ "$detail" == *"[REDACTED]"* ]] \
        || fail "$label omitted the redaction marker"
    [[ "$detail" != *\"* && "$detail" != *"'"* ]] \
        || fail "$label retained an unmatched credential quote"
    for forbidden in "$@"; do
        [[ "$detail" != *"$forbidden"* ]] \
            || fail "$label exposed credential material: $forbidden"
    done
    assert_one_line_bounded "$detail" "$label"
}

long_tail="$(printf 'x%.0s' {1..400})"
printf 'INFO ignored first line\n\033[31mFATAL\tbad\rmessage\001 SMTP_PASSWORD=supersecret API_TOKEN=token-value %s\033[0m\nERROR ignored later line\n' \
    "$long_tail" > "$sanitize_log"
detail="$(_crowdsec_health_sanitize_validation_log "$sanitize_log")"
[[ "$detail" == "FATAL bad message SMTP_PASSWORD=[REDACTED]" ]] \
    || fail "sanitizer did not preserve the first actionable severity line and safe prefix"
[[ "$detail" != *$'\033'* ]] || fail "sanitizer retained ANSI escapes"
[[ "$detail" != *$'\001'* && "$detail" != *$'\r'* && "$detail" != *$'\t'* ]] \
    || fail "sanitizer retained unsafe control characters"
[[ "$detail" != *"ERROR ignored later line"* ]] || fail "sanitizer allowed multiline log injection"
[[ "$detail" != *"supersecret"* && "$detail" != *"token-value"* ]] \
    || fail "sanitizer exposed credential values"
[[ "$detail" == *"[REDACTED]"* ]] || fail "sanitizer did not redact credential assignments"
assert_one_line_bounded "$detail" "ANSI and control sanitization"

assert_sensitive_redaction \
    'FATAL Authorization: Bearer abc.def.ghi' \
    'FATAL Authorization: [REDACTED]' \
    'Bearer authorization' \
    'Bearer' 'abc.def.ghi'
assert_sensitive_redaction \
    'ERROR Authorization: Basic dXNlcjpwYXNz' \
    'ERROR Authorization: [REDACTED]' \
    'Basic authorization' \
    'Basic' 'dXNlcjpwYXNz'
assert_sensitive_redaction \
    'WARN authorization=Bearer abc.def.ghi' \
    'WARN authorization=[REDACTED]' \
    'lowercase authorization assignment' \
    'Bearer' 'abc.def.ghi'
assert_sensitive_redaction \
    'FATAL SMTP_PASSWORD="secret containing spaces"' \
    'FATAL SMTP_PASSWORD=[REDACTED]' \
    'quoted SMTP password' \
    'secret containing spaces' 'containing' 'spaces'
assert_sensitive_redaction \
    "ERROR API_TOKEN='token containing spaces'" \
    'ERROR API_TOKEN=[REDACTED]' \
    'quoted API token' \
    'token containing spaces' 'containing' 'spaces'
assert_sensitive_redaction \
    'WARN credential: first second third' \
    'WARN credential: [REDACTED]' \
    'multi-token credential' \
    'first' 'second' 'third'
assert_sensitive_redaction \
    'ERROR secret = unquoted value with spaces' \
    'ERROR secret = [REDACTED]' \
    'unquoted multi-token secret' \
    'unquoted' 'value' 'spaces'
assert_sensitive_redaction \
    'FATAL message before secret=value' \
    'FATAL message before secret=[REDACTED]' \
    'sensitive field after useful context' \
    'value'

assert_sensitive_redaction \
    'ERROR password=plainsecret' \
    'ERROR password=[REDACTED]' \
    'simple password assignment' \
    'plainsecret'
assert_sensitive_redaction \
    'WARN passwd: plainpass' \
    'WARN passwd: [REDACTED]' \
    'passwd assignment' \
    'plainpass'
assert_sensitive_redaction \
    'FATAL token=value' \
    'FATAL token=[REDACTED]' \
    'token assignment' \
    'value'
assert_sensitive_redaction \
    'ERROR api_key=value' \
    'ERROR api_key=[REDACTED]' \
    'api_key assignment' \
    'value'
assert_sensitive_redaction \
    'WARN api-key:value' \
    'WARN api-key:[REDACTED]' \
    'api-key assignment' \
    'value'
assert_sensitive_redaction \
    'FATAL smtp_username=user@example.test' \
    'FATAL smtp_username=[REDACTED]' \
    'SMTP username assignment' \
    'user@example.test'
assert_sensitive_redaction \
    'ERROR CROWDSEC_API_KEY=generic value with spaces' \
    'ERROR CROWDSEC_API_KEY=[REDACTED]' \
    'generic uppercase environment assignment' \
    'generic' 'value' 'spaces'

ordinary_diagnostics=(
    'FATAL CrowdSec parser failed at line 42'
    'WARN notification plugin exited with status 1'
    'ERROR failed to open /etc/crowdsec/config.yaml'
)
for ordinary in "${ordinary_diagnostics[@]}"; do
    printf '%s\n' "$ordinary" > "$sanitize_log"
    detail="$(_crowdsec_health_sanitize_validation_log "$sanitize_log")"
    [[ "$detail" == "$ordinary" ]] \
        || fail "sanitizer unnecessarily removed ordinary diagnostic text: $ordinary"
    [[ "$detail" != *"[REDACTED]"* ]] \
        || fail "sanitizer unnecessarily redacted ordinary diagnostic text: $ordinary"
    assert_one_line_bounded "$detail" "ordinary diagnostic"
done

printf 'ERROR %s\n' "$long_tail" > "$sanitize_log"
detail="$(_crowdsec_health_sanitize_validation_log "$sanitize_log")"
(( ${#detail} == 240 )) || fail "sanitizer did not enforce the 240-character bound"
assert_one_line_bounded "$detail" "truncated diagnostic"

printf 'first fallback\n\nlast fallback\n' > "$sanitize_log"
[[ "$(_crowdsec_health_sanitize_validation_log "$sanitize_log")" == "last fallback" ]] \
    || fail "sanitizer did not retain the last nonempty fallback line"
printf '\001\002\r\t\n' > "$sanitize_log"
[[ -z "$(_crowdsec_health_sanitize_validation_log "$sanitize_log")" ]] \
    || fail "sanitizer invented detail when no useful diagnostic line existed"

VW_CROWDSEC_ETC_DIR="$TMP/etc-crowdsec"
export VW_CROWDSEC_ETC_DIR
CROWDSEC_EMAIL_NOTIFICATIONS=false
CROWDSEC_EMAIL_EVENT_POLICY=all
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
exec {HEALTH_LOCK_FD}>"$TMP/health.lock"
EXPECTED_CLOSED_FD="$HEALTH_LOCK_FD"
export EXPECTED_CLOSED_FD

VALIDATION_RC=8
VALIDATION_SIGNAL=""
printf '\033[33mWARN\tCrowdSec validation failed\r SMTP_PASSWORD=do-not-print\033[0m\nsecond line\n' \
    > "$VALIDATION_OUTPUT_FILE"
export VALIDATION_RC VALIDATION_SIGNAL
RESULTS=""
_check_crowdsec_email_notifications
[[ "$RESULTS" == *pass:*configured* && "$RESULTS" == *warn:*validation*failed* ]] \
    || fail "invalid configured state was not reported distinctly"
[[ "$RESULTS" == *"WARN CrowdSec validation failed"* ]] \
    || fail "health warning omitted the sanitized actionable validation detail"
[[ "$RESULTS" != *"do-not-print"* && "$RESULTS" != *$'\033'* ]] \
    || fail "health warning exposed unsafe validation output"
[[ -e "/proc/${BASHPID}/fd/${HEALTH_LOCK_FD}" ]] \
    || fail "health validation closed the caller's health lock descriptor"
assert_no_validation_logs

VALIDATION_RC=0
: > "$VALIDATION_OUTPUT_FILE"
RESULTS=""
_check_crowdsec_email_notifications
[[ "$RESULTS" == *pass:*configured* && "$RESULTS" == *pass:*validation*valid* ]] \
    || fail "statically valid enabled state was not reported"
assert_no_validation_logs

CROWDSEC_EMAIL_EVENT_POLICY=none
rm -f "$VW_CROWDSEC_ETC_DIR/profiles.yaml.local"
RESULTS=""
_check_crowdsec_email_notifications
[[ "$RESULTS" == *pass:*disabled*policy* && "$RESULTS" == *pass:*validation*valid* ]] \
    || fail "valid none policy was not reported as manual-test-only"
[[ "$RESULTS" != *warn:* ]] || fail "valid none policy produced a health warning"
assert_no_validation_logs

CROWDSEC_EMAIL_EVENT_POLICY=invalid
RESULTS=""
_check_crowdsec_email_notifications
[[ "$RESULTS" == warn:*policy* ]] || fail "invalid event policy was not reported"

CROWDSEC_EMAIL_EVENT_POLICY=all
printf '# BEGIN VaultWarden-OCI CrowdSec email notifications\n# END VaultWarden-OCI CrowdSec email notifications\n' \
    > "$VW_CROWDSEC_ETC_DIR/profiles.yaml.local"
VALIDATION_RC=143
VALIDATION_SIGNAL=TERM
printf 'FATAL validation subprocess terminated\n' > "$VALIDATION_OUTPUT_FILE"
RESULTS=""
_check_crowdsec_email_notifications
[[ "$RESULTS" == *warn:*validation*failed* ]] \
    || fail "signal-related validation failure was not reported"
assert_no_validation_logs

VALIDATION_SIGNAL=""
VALIDATION_RC=8
: > "$VALIDATION_OUTPUT_FILE"
RESULTS=""
_check_crowdsec_email_notifications
[[ "$RESULTS" == *"static validation failed (run: sudo crowdsec -t)"* ]] \
    || fail "empty validation output did not use the generic bounded warning"
assert_no_validation_logs

{ eval "exec ${HEALTH_LOCK_FD}>&-"; }
printf 'CrowdSec email notification health visibility tests passed.\n'
)

check_crowdsec_email_health_visibility

check_crowdsec_worker_descriptor_cleanup_contracts() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
CROWDSEC_WORKER_LIB="$ROOT/lib/crowdsec-worker.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if grep -Fq '_crowdsec_worker_run_without_guard_fds' "$CROWDSEC_WORKER_LIB"; then
    fail "CrowdSec worker library retained obsolete operation descriptor isolation"
fi
grep -Fq 'if "$bouncer_bin" -S -c "$dest"; then' "$CROWDSEC_WORKER_LIB" \
    || fail "autonomous CrowdSec Workers deployment must run normally under owner-bound locking"

printf 'CrowdSec worker descriptor cleanup contracts passed.\n'
)

check_crowdsec_worker_descriptor_cleanup_contracts
