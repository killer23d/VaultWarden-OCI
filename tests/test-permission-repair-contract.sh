#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }

TMP_DIR="$(mktemp -d)"
orig_present=0
backup="${TMP_DIR}/sops.yaml.backup"
orig_mode=""
orig_owner=""
orig_group=""
if [[ -e .sops.yaml ]]; then
    orig_present=1
    cp -p .sops.yaml "$backup"
    orig_mode="$(stat -c '%a' .sops.yaml)"
    orig_owner="$(stat -c '%u' .sops.yaml)"
    orig_group="$(stat -c '%g' .sops.yaml)"
fi
cleanup() {
    if [[ "$orig_present" == 1 ]]; then
        if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            sudo cp -p "$backup" .sops.yaml 2>/dev/null || cp -p "$backup" .sops.yaml
            sudo chown "${orig_owner}:${orig_group}" .sops.yaml 2>/dev/null || true
            sudo chmod "$orig_mode" .sops.yaml 2>/dev/null || true
        else
            cp -p "$backup" .sops.yaml 2>/dev/null || true
            chmod "$orig_mode" .sops.yaml 2>/dev/null || true
        fi
    else
        if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            sudo rm -f .sops.yaml 2>/dev/null || rm -f .sops.yaml
        else
            rm -f .sops.yaml 2>/dev/null || true
        fi
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cat > .sops.yaml <<'POLICY'
creation_rules:
  - path_regex: '.*\.yaml$'
    age: "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
POLICY
chmod 0640 .sops.yaml

check_out="${TMP_DIR}/repair-check.out"
if utilities/repair-permissions.sh --check > "$check_out" 2>&1; then
    cat "$check_out" >&2
    fail "repair --check did not detect .sops.yaml mode drift"
fi
grep -Fq 'ERROR .sops.yaml SOPS policy' "$check_out" || { cat "$check_out" >&2; fail "repair --check lacks .sops.yaml error"; }
grep -Fq 'fix: sudo utilities/repair-permissions.sh' "$check_out" || { cat "$check_out" >&2; fail "repair --check lacks repair hint"; }
pass "repair --check detects unreadable .sops.yaml drift"

repair_out="${TMP_DIR}/repair-run.out"
idem_out="${TMP_DIR}/repair-idem.out"
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo utilities/repair-permissions.sh 2>&1 | tee "$repair_out" >/dev/null || { cat "$repair_out" >&2; fail "sudo repair command failed"; }
    [[ "$(stat -c '%a' .sops.yaml)" == "644" ]] || fail ".sops.yaml was not repaired to 0644"
    pass "sudo repair command fixes .sops.yaml to 0644"

    sudo utilities/repair-permissions.sh 2>&1 | tee "$idem_out" >/dev/null || { cat "$idem_out" >&2; fail "idempotent sudo repair failed"; }
    grep -Fq 'OK .sops.yaml SOPS policy' "$idem_out" || { cat "$idem_out" >&2; fail "idempotent repair did not report OK for .sops.yaml"; }
    pass "sudo repair command is idempotent for .sops.yaml"
elif (( EUID == 0 )); then
    utilities/repair-permissions.sh > "$repair_out" 2>&1 || { cat "$repair_out" >&2; fail "root repair command failed"; }
    [[ "$(stat -c '%a' .sops.yaml)" == "644" ]] || fail ".sops.yaml was not repaired to 0644"
    pass "root repair command fixes .sops.yaml to 0644"

    utilities/repair-permissions.sh > "$idem_out" 2>&1 || { cat "$idem_out" >&2; fail "idempotent root repair failed"; }
    grep -Fq 'OK .sops.yaml SOPS policy' "$idem_out" || { cat "$idem_out" >&2; fail "idempotent repair did not report OK for .sops.yaml"; }
    pass "root repair command is idempotent for .sops.yaml"
else
    printf 'SKIP: sudo unavailable; skipping privileged repair execution\n'
fi

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

rotate_out="${TMP_DIR}/rotate-stub.out"
if utilities/setup-secrets.sh rotate example > "$rotate_out" 2>&1; then
    cat "$rotate_out" >&2
    fail "setup-secrets rotate stub should fail"
fi
grep -Fq './edit-secrets.sh rotate FIELD' "$rotate_out" || { cat "$rotate_out" >&2; fail "rotate stub lacks non-root guidance"; }

kit_out="${TMP_DIR}/kit-stub.out"
if utilities/setup-secrets.sh export-recovery-kit > "$kit_out" 2>&1; then
    cat "$kit_out" >&2
    fail "setup-secrets export-recovery-kit stub should fail"
fi
grep -Fq './edit-secrets.sh export-recovery-kit' "$kit_out" || { cat "$kit_out" >&2; fail "export-recovery-kit stub lacks non-root guidance"; }
pass "root-facing setup-secrets secret-authoring paths are non-root guidance stubs"
