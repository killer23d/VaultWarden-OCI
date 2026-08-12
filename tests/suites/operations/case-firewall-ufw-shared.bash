#!/usr/bin/env bash
# Focused ownership and parsing checks for the shared UFW policy library.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

ROOT="$VW_TEST_REPO_ROOT"
UFW_LIB="$ROOT/lib/firewall-ufw.sh"
SETUP="$ROOT/utilities/setup-firewall.sh"
UPDATER="$ROOT/utilities/maintenance-update-firewall.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

for caller in "$SETUP" "$UPDATER"; do
    grep -Fq 'lib/firewall-ufw.sh' "$caller" \
        || fail "$(basename "$caller") does not source the shared UFW library"
    grep -Fq 'firewall_ufw_status' "$caller" \
        || fail "$(basename "$caller") does not use shared UFW status parsing"
    grep -Fq 'firewall_ufw_collect_web_conflicts' "$caller" \
        || fail "$(basename "$caller") does not use shared web-rule classification"
done

# Common parser/policy implementations belong in one place. Setup keeps only
# two thin compatibility aliases used by the older extraction-based test case.
for legacy in \
    _ufw_status \
    _ufw_has_range_port \
    _ufw_line_cidr \
    _ufw_collect_conflicts \
    _ufw_default_incoming_fail_closed \
    _ufw_reject_ambiguous_inbound_allows; do
    ! grep -Eq "^[[:space:]]*${legacy}\\(\\)" "$SETUP" "$UPDATER" \
        || fail "duplicated UFW policy helper remains: ${legacy}"
done

log_error() { :; }
log_dry_run() { :; }
# shellcheck source=../../../lib/firewall-ufw.sh
source "$UFW_LIB"

status=$'80/tcp ALLOW 203.0.113.0/24\n443/tcp ALLOW OUT 203.0.113.0/24'
firewall_ufw_has_range_port "$status" 203.0.113.0/24 80 \
    || fail "implicit inbound Cloudflare rule was not recognized"
if firewall_ufw_has_range_port "$status" 203.0.113.0/24 443; then
    fail "outbound Cloudflare rule counted as inbound admission"
fi

numbered=$'[ 4] 80/tcp ALLOW Anywhere # operator note: ALLOW OUT 203.0.113.0/24'
[[ "$(firewall_ufw_collect_web_conflicts "$numbered" 203.0.113.0/24)" == 4 ]] \
    || fail "comment text spoofed web-rule direction/CIDR classification"

numbered=$'[ 5] 80/tcp ALLOW 203.0.113.0/24\n[ 6] 443/tcp ALLOW IN 203.0.113.0/24'
[[ -z "$(firewall_ufw_collect_web_conflicts "$numbered" 203.0.113.0/24)" ]] \
    || fail "exact implicit/explicit inbound Cloudflare rules were classified as conflicts"

if firewall_ufw_reject_ambiguous_inbound_allows $'[ 7] Nginx Full ALLOW FWD Anywhere'; then
    fail "routed/FWD application-profile allow was accepted as unambiguous inbound policy"
fi

firewall_ufw_default_incoming_fail_closed \
    $'Status: active\nDefault: deny (incoming), allow (outgoing), disabled (routed)' \
    || fail "default deny incoming was rejected"
firewall_ufw_default_incoming_fail_closed \
    $'Status: active\nDefault: reject (incoming), allow (outgoing), disabled (routed)' \
    || fail "default reject incoming was rejected"
if firewall_ufw_default_incoming_fail_closed \
    $'Status: active\nDefault: allow (incoming), allow (outgoing), disabled (routed)'; then
    fail "default allow incoming was accepted"
fi

if firewall_ufw_status true >/dev/null 2>&1; then
    fail "boolean UFW status alias true was still accepted"
else
    rc=$?
    [[ "$rc" -eq 2 ]] || fail "unknown UFW status mode returned $rc instead of 2"
fi
if firewall_ufw_status false >/dev/null 2>&1; then
    fail "boolean UFW status alias false was still accepted"
fi

UFW_TEST_CALLS="$(mktemp)"
trap 'rm -f "$UFW_TEST_CALLS"' EXIT
ufw() {
    printf '%s\n' "$*" >> "$UFW_TEST_CALLS"
    if [[ "${1:-}" == "status" && $# -eq 1 ]]; then
        printf '80/tcp ALLOW IN 203.0.113.0/24\n'
        return 0
    fi
    if [[ "${1:-}" == "allow" ]]; then
        return 0
    fi
    return 2
}

firewall_ufw_ensure_web_range 203.0.113.0/24 CF-IPv4 \
    || fail "web range reconciliation failed"
[[ "$(grep -c '^status$' "$UFW_TEST_CALLS")" -eq 1 ]] \
    || fail "web range reconciliation read UFW status more than once"
! grep -Fq 'port 80 ' "$UFW_TEST_CALLS" \
    || fail "existing port 80 rule was added again"
grep -Fq 'port 443 comment CF-IPv4' "$UFW_TEST_CALLS" \
    || fail "missing port 443 rule was not added"

printf 'PASS: shared UFW policy ownership and parsing contracts\n'
