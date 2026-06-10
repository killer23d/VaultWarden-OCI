#!/usr/bin/env bash
# Static regression checks for the VaultWarden-OCI CrowdSec policy.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACQUIS="${ROOT}/crowdsec/acquis.yaml"
WRAPPER="${ROOT}/utilities/setup-crowdsec.sh"
CORE="${ROOT}/utilities/.setup-crowdsec-core.sh"

bash -n "$WRAPPER"
bash -n "$CORE"

grep -q '"_TRANSPORT=kernel"' "$ACQUIS"
grep -A4 '"_TRANSPORT=kernel"' "$ACQUIS" | grep -q 'type: syslog'

if grep -q '/var/log/kern.log\|/var/log/messages' "$ACQUIS"; then
    echo "CrowdSec must not acquire duplicate kernel logs from files and journald." >&2
    exit 1
fi

grep -q 'crowdsecurity/appsec-generic-rules' "$WRAPPER"
grep -q 'crowdsecurity/appsec-virtual-patching' "$WRAPPER"
grep -q 'collections remove' "$WRAPPER"
grep -q 'Dominic-Wagner/vaultwarden' "$CORE"
grep -q 'crowdsecurity/iptables' "$CORE"

_document_count="$(grep -c '^---$' "$ACQUIS")"
if [[ "$_document_count" -ne 4 ]]; then
    echo "Expected five acquisition documents; found $((_document_count + 1))." >&2
    exit 1
fi

printf 'CrowdSec configuration checks passed.\n'
