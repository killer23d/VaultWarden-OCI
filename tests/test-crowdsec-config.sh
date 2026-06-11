#!/usr/bin/env bash
# Static regression checks for the VaultWarden-OCI CrowdSec installer.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${ROOT}/utilities/setup-crowdsec.sh"
ACQUIS="${ROOT}/crowdsec/acquis.yaml"

bash -n "$SETUP"

[[ ! -e "${ROOT}/utilities/.setup-crowdsec-core.sh" ]] || {
    echo "Legacy CrowdSec wrapper/core split must not be reintroduced." >&2
    exit 1
}

# Acquisition must use kernel journald as syslog, without duplicate log files.
grep -q '"_TRANSPORT=kernel"' "$ACQUIS"
grep -A4 '"_TRANSPORT=kernel"' "$ACQUIS" | grep -q 'type: syslog'
if grep -Eq '/var/log/(kern\.log|messages)' "$ACQUIS"; then
    echo "Kernel events must not be acquired from files and journald together." >&2
    exit 1
fi

# Only collections matching acquired logs and exposed services are top-level installs.
grep -q 'crowdsecurity/linux' "$SETUP"
grep -q 'crowdsecurity/caddy' "$SETUP"
grep -q 'crowdsecurity/iptables' "$SETUP"
grep -q 'Dominic-Wagner/vaultwarden' "$SETUP"
if grep -Eq 'cscli collections install.*crowdsecurity/appsec-' "$SETUP"; then
    echo "Inactive AppSec-only collections must not be installed." >&2
    exit 1
fi
grep -q 'collections remove.*--purge.*--force' "$SETUP"

# Installer and generated service security invariants.
grep -q '^umask 077$' "$SETUP"
grep -q -- "--proto '=https' --tlsv1.2" "$SETUP"
grep -q 'SHA-256 verification failed' "$SETUP"
grep -q '^NoNewPrivileges=true$' "$SETUP"
grep -q '^CapabilityBoundingSet=$' "$SETUP"
grep -q 'chmod 600 "\$config"' "$SETUP"
grep -q 'chmod 600 "\$dest"' "$SETUP"
grep -q 'chmod 640 "\$dest"' "$SETUP"

_document_count="$(grep -c '^---$' "$ACQUIS")"
[[ "$_document_count" -eq 4 ]] || {
    echo "Expected five acquisition documents; found $((_document_count + 1))." >&2
    exit 1
}

printf 'CrowdSec configuration checks passed.\n'
