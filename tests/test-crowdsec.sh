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
