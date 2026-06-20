#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }

extract_make_target() {
    local target="$1" file="${2:-Makefile}"
    awk -v target="$target" '
        BEGIN { in_target=0; found=0 }
        $0 ~ "^" target ":" { in_target=1; found=1; print; next }
        in_target && $0 ~ /^[A-Za-z0-9_.-]+:([^=]|$)/ { exit }
        in_target { print }
        END { if (!found) exit 2 }
    ' "$file"
}

# Makefile target classification and hidden sudo checks.
grep -Eq '^ROOT_ALLOWED_TARGETS :=([[:space:]]|\\|$)' Makefile || fail "ROOT_ALLOWED_TARGETS missing"
grep -Eq '^[[:space:]]*setup init-secrets restart safe-restart' Makefile || fail "init-secrets/restart/safe-restart not root-allowed"
UP_SNIP="$(mktemp -t vw-priv-up.XXXXXXXXXX)"
trap 'rm -f "$UP_SNIP"' EXIT
extract_make_target up Makefile > "$UP_SNIP" || fail "could not extract make up target"
[[ -s "$UP_SNIP" ]] || fail "make up snippet is empty"
grep -Fq '@./startup.sh' "$UP_SNIP" || fail "make up does not call startup.sh directly"
grep -Fq 'sudo make init-secrets' "$UP_SNIP" || fail "make up missing init-secrets remediation"
! grep -Fq './setup.sh secrets' "$UP_SNIP" || fail "make up still invokes setup.sh secrets"
! grep -Fq 'sudo ./startup.sh' "$UP_SNIP" || fail "make up still invokes sudo ./startup.sh"
pass "make up privilege contract is explicit"

# Static gate: no hidden self-escalation in operational shell scripts.
if find . \
    -path './tests' -prune -o \
    -path './.rate-limit' -prune -o \
    -name '*.sh' -type f -print0 2>/dev/null \
  | xargs -0 grep -nE 'exec sudo|sudo -n "\$0"|sudo "\$0"|sudo '\''\$\{0\}'\''|sudo "\$\{BASH_SOURCE\[0\]\}"' >/tmp/vw-hidden-sudo.$$; then
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

# Internal root health bypass is explicit and only used by trusted callers.
grep -Fq 'VAULTWARDEN_INTERNAL_HEALTH_CHECK' utilities/maintenance-health.sh || fail "health internal bypass missing"
grep -Fq 'VAULTWARDEN_INTERNAL_HEALTH_CHECK=true "$_health_script" health' startup.sh || fail "startup does not mark internal health check"
grep -Fq 'VAULTWARDEN_INTERNAL_HEALTH_CHECK=true "${PROJECT_ROOT}/utilities/maintenance-health.sh" health' utilities/safe-restart.sh || fail "safe-restart does not mark internal health check"
pass "internal root health checks use explicit bypass"

# Dashboard must match displayed command labels and drop to the normal user for guarded commands.
grep -Fq 'run_sudo_cmd "sudo make restart"' dashboard.sh || fail "dashboard restart label missing"
grep -Fq 'make -C "${REPO_ROOT}" restart' dashboard.sh || fail "dashboard restart does not execute make restart"
grep -Fq 'run_user_cmd "make health" make -C "${REPO_ROOT}" health' dashboard.sh || fail "dashboard quick health should drop to normal user"
grep -Fq 'run_user_cmd "make test-email" make -C "${REPO_ROOT}" test-email' dashboard.sh || fail "dashboard test-email should drop to normal user"
grep -Fq 'run_user_cmd "./utilities/secrets-edit.sh" "${edit_sh}"' dashboard.sh || fail "dashboard secrets-edit should drop to normal user"
grep -Fq 'run_user_cmd "./utilities/secrets-export-recovery-kit.sh" "${kit_sh}"' dashboard.sh || fail "dashboard recovery-kit export should drop to normal user"
pass "dashboard command labels match execution"

# Legacy CF token preservation must use root-side file install, not shell value arguments.
grep -Fq 'install -m 0444 -o root -g root "$_cf_flat" "$_cf_dest"' lib/secrets.sh || fail "CF token mirror does not use root-side install"
! grep -Fq '_cf_value' lib/secrets.sh || fail "CF token value should not be read into shell variables"
pass "CF token mirror avoids command-line secret values"
