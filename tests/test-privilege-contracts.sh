#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }

# Makefile target classification and hidden sudo checks.
grep -Eq '^ROOT_ALLOWED_TARGETS :=([[:space:]]|\\|$)' Makefile || fail "ROOT_ALLOWED_TARGETS missing"
grep -Eq '^[[:space:]]*setup init-secrets restart safe-restart' Makefile || fail "init-secrets/restart/safe-restart not root-allowed"
UP_SNIP="$(mktemp -t vw-priv-up.XXXXXXXXXX)"
trap 'rm -f "$UP_SNIP"' EXIT
awk '/^up:/{in_up=1} in_up && /^start:/{in_up=0} in_up{print}' Makefile > "$UP_SNIP"
grep -Fq 'sudo make init-secrets' "$UP_SNIP" || fail "make up missing init-secrets remediation"
! grep -Fq './setup.sh secrets' "$UP_SNIP" || fail "make up still invokes setup.sh secrets"
! grep -Fq 'sudo ./startup.sh' "$UP_SNIP" || fail "make up still invokes sudo ./startup.sh"
pass "make up privilege contract is explicit"

# Static gate: no hidden self-escalation in operational shell scripts.
if find . -path './tests' -prune -o -name '*.sh' -type f -print \
  | xargs grep -nE 'exec sudo|sudo -n "\$0"|sudo "\$0"|sudo '\''\$\{0\}'\''|sudo "\$\{BASH_SOURCE\[0\]\}"' >/tmp/vw-hidden-sudo.$$; then
    cat /tmp/vw-hidden-sudo.$$ >&2
    rm -f /tmp/vw-hidden-sudo.$$
    fail "hidden sudo self-escalation found"
fi
rm -f /tmp/vw-hidden-sudo.$$
pass "no hidden sudo self-reexec remains"

grep -Fq 'refuse_root_for_user_command()' lib/common.sh || fail "root-refusal helper missing"
for f in utilities/maintenance-health.sh utilities/maintenance-email.sh utilities/secrets-edit.sh; do
    grep -Fq 'refuse_root_for_user_command' "$f" || fail "$f does not call root-refusal helper"
done
pass "normal-user scripts call root-refusal helper"

# CrowdSec diagnostics must degrade without failing the diagnostic solely due to sudo/cscli.
grep -Fq 'sudo -n cscli metrics' utilities/maintenance-health.sh || fail "health does not use non-interactive sudo for cscli"
grep -Fq 'skipping optional cscli check' utilities/maintenance-health.sh || fail "health missing cscli WARN degradation"
grep -Fq 'sudo -n cscli metrics' utilities/maintenance-email.sh || fail "email does not use non-interactive sudo for cscli"
grep -Fq 'skipping optional cscli check' utilities/maintenance-email.sh || fail "email missing cscli WARN degradation"
pass "CrowdSec diagnostics degrade on sudo/cscli failure"
