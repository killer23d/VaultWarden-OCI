#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }

orig_present=0
backup="$(mktemp)"
orig_mode=""
if [[ -e .sops.yaml ]]; then
    orig_present=1
    cp -p .sops.yaml "$backup"
    orig_mode="$(stat -c '%a' .sops.yaml)"
fi
cleanup() {
    if [[ "$orig_present" == 1 ]]; then
        cp -p "$backup" .sops.yaml
        chmod "$orig_mode" .sops.yaml 2>/dev/null || true
    else
        rm -f .sops.yaml
    fi
    rm -f "$backup"
}
trap cleanup EXIT

cat > .sops.yaml <<'POLICY'
creation_rules:
  - path_regex: '.*\.yaml$'
    age: "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
POLICY
chmod 0640 .sops.yaml

if utilities/repair-permissions.sh --check > /tmp/vw-repair-check.$$ 2>&1; then
    cat /tmp/vw-repair-check.$$ >&2
    rm -f /tmp/vw-repair-check.$$
    fail "repair --check did not detect .sops.yaml mode drift"
fi
grep -Fq 'ERROR .sops.yaml SOPS policy' /tmp/vw-repair-check.$$ || { cat /tmp/vw-repair-check.$$ >&2; rm -f /tmp/vw-repair-check.$$; fail "repair --check lacks .sops.yaml error"; }
grep -Fq 'fix: sudo utilities/repair-permissions.sh' /tmp/vw-repair-check.$$ || { cat /tmp/vw-repair-check.$$ >&2; rm -f /tmp/vw-repair-check.$$; fail "repair --check lacks repair hint"; }
rm -f /tmp/vw-repair-check.$$
pass "repair --check detects unreadable .sops.yaml drift"

utilities/repair-permissions.sh > /tmp/vw-repair-run.$$ 2>&1 || { cat /tmp/vw-repair-run.$$ >&2; rm -f /tmp/vw-repair-run.$$; fail "repair command failed"; }
[[ "$(stat -c '%a' .sops.yaml)" == "644" ]] || fail ".sops.yaml was not repaired to 0644"
rm -f /tmp/vw-repair-run.$$
pass "repair command fixes .sops.yaml to 0644"

utilities/repair-permissions.sh > /tmp/vw-repair-idem.$$ 2>&1 || { cat /tmp/vw-repair-idem.$$ >&2; rm -f /tmp/vw-repair-idem.$$; fail "idempotent repair failed"; }
grep -Fq 'OK .sops.yaml SOPS policy' /tmp/vw-repair-idem.$$ || { cat /tmp/vw-repair-idem.$$ >&2; rm -f /tmp/vw-repair-idem.$$; fail "idempotent repair did not report OK for .sops.yaml"; }
rm -f /tmp/vw-repair-idem.$$
pass "repair command is idempotent for .sops.yaml"

# Static safety: SOPS writers leave public policy 0644, while private files stay private.
grep -Fq 'chmod 0644 "$dest"' utilities/setup-secrets.sh || fail "_ss_write_policy_file does not chmod .sops.yaml 0644"
grep -Fq 'chmod 644 "$tmp"' utilities/setup-secrets.sh || fail "_write_sops_config does not stage .sops.yaml 0644"
grep -Fq 'chmod 600 "$age_key_file"' utilities/setup-secrets.sh || fail "repo Age key not kept 0600"
grep -Fq 'install -m 600 -o root -g root "$age_key_file" "$canonical_key"' utilities/setup-secrets.sh || fail "installed Age key not root:root 0600"
grep -Fq 'chmod 600 "$secrets_file"' utilities/setup-secrets.sh || fail "secrets.yaml not kept 0600"
grep -Fq 'install -d -m 700 -o root -g root "/run/vaultwarden-oci/secrets"' utilities/setup-secrets.sh || fail "runtime secrets dir not root:root 0700"
pass "permission contract keeps private files private and .sops.yaml public-readable"

# Diagnostics and command boundary stubs.
grep -Fq 'Recommended repair: sudo utilities/repair-permissions.sh' lib/secrets.sh || fail "ensure_sops_env lacks repair hint"
grep -Fq 'Direct fallback: sudo chmod 0644 .sops.yaml' lib/secrets.sh || fail "ensure_sops_env lacks chmod fallback"
if utilities/setup-secrets.sh rotate example > /tmp/vw-rotate-stub.$$ 2>&1; then
    cat /tmp/vw-rotate-stub.$$ >&2
    rm -f /tmp/vw-rotate-stub.$$
    fail "setup-secrets rotate stub should fail"
fi
grep -Fq './edit-secrets.sh rotate FIELD' /tmp/vw-rotate-stub.$$ || { cat /tmp/vw-rotate-stub.$$ >&2; rm -f /tmp/vw-rotate-stub.$$; fail "rotate stub lacks non-root guidance"; }
rm -f /tmp/vw-rotate-stub.$$
pass "root-facing setup-secrets rotate path is a non-root guidance stub"
