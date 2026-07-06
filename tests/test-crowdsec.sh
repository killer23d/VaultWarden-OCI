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
