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

# Root-operated lifecycle contract.
grep -Eq '^ROOT_ALLOWED_TARGETS :=([[:space:]]|\|$)' Makefile || fail "ROOT_ALLOWED_TARGETS missing"
for target in up down start stop restart health health-quick health-report status logs logs-tail logs-vaultwarden logs-caddy logs-postfix logs-crowdsec crowdsec-status crowdsec-alerts security-report; do
    grep -Eq "(^|[[:space:]])${target}([[:space:]]|\|$)" Makefile || fail "${target} is not root-allowed"
done
pass "root-supported lifecycle/day-2 targets are allowed under sudo make"

for target in health health-quick health-report status logs logs-tail logs-vaultwarden logs-caddy logs-postfix logs-crowdsec crowdsec-status crowdsec-alerts security-report; do
    _snip="$(mktemp -t vw-priv-${target}.XXXXXXXXXX)"
    extract_make_target "$target" Makefile > "$_snip" || fail "could not extract make ${target} target"
    grep -Fq '$(call require-root)' "$_snip" || { cat "$_snip" >&2; rm -f "$_snip"; fail "make ${target} does not require root"; }
    rm -f "$_snip"
done
pass "health/status/logs/CrowdSec security targets enforce the root-operated policy"

UP_SNIP="$(mktemp -t vw-priv-up.XXXXXXXXXX)"
trap 'rm -f "$UP_SNIP"' EXIT
extract_make_target up Makefile > "$UP_SNIP" || fail "could not extract make up target"
[[ -s "$UP_SNIP" ]] || fail "make up snippet is empty"
grep -Fq '$(call require-root)' "$UP_SNIP" || fail "make up does not require root"
grep -Fq '@./startup.sh' "$UP_SNIP" || fail "make up does not call startup.sh directly"
grep -Fq 'sudo make init-secrets' "$UP_SNIP" || fail "make up missing init-secrets remediation"
grep -Fq 'sudo make up' "$UP_SNIP" || fail "make up operator guidance does not use sudo make up"
! grep -Fq 'secrets/.docker_secrets' "$UP_SNIP" || fail "make up still references repo-local decoded secrets"
pass "make up follows root-operated startup contract"

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

# Internal root health bypass is explicit for root/systemd maintenance callers.
grep -Fq 'VAULTWARDEN_INTERNAL_HEALTH_CHECK' utilities/maintenance-health.sh || fail "health internal flag missing"
grep -Fq 'VAULTWARDEN_INTERNAL_HEALTH_CHECK=true "$_health_script" health' startup.sh || fail "startup does not mark internal health check"
grep -Fq 'VAULTWARDEN_INTERNAL_HEALTH_CHECK=true "${PROJECT_ROOT}/utilities/maintenance-health.sh" --quiet' lib/maintenance-utils.sh || fail "maintenance validation does not mark internal health check"
grep -Fq 'VAULTWARDEN_INTERNAL_HEALTH_CHECK=true "${PROJECT_ROOT}/utilities/maintenance-health.sh" health' utilities/safe-restart.sh || fail "safe-restart does not mark internal health check"
pass "internal root health checks use explicit bypass"

# Live runtime paths must not use repo-local decoded secret caches.
for f in Makefile startup.sh utilities/maintenance-health.sh utilities/maintenance-update-dns.sh; do
    ! grep -Fq 'secrets/.docker_secrets' "$f" || fail "$f still references secrets/.docker_secrets"
done
grep -Fq 'local secrets_dir="${DOCKER_SECRETS_DIR:-/run/vaultwarden-oci/secrets}"' utilities/maintenance-health.sh || fail "health does not inspect runtime secret directory"
pass "live startup/health paths use /run runtime secrets"

# Startup key remediation must preserve the root-operated Age key contract.
! grep -Eq 'chown[[:space:]].*/etc/vaultwarden/age-key\.txt|chgrp[[:space:]].*/etc/vaultwarden|chmod[[:space:]]+750[[:space:]]+/etc/vaultwarden|install[[:space:]]+-d[[:space:]]+-m[[:space:]]+750[[:space:]]+/etc/vaultwarden' startup.sh \
    || fail "startup.sh contains stale non-root Age key remediation"
grep -Fq 'sudo install -d -m 700 -o root -g root /etc/vaultwarden' startup.sh || fail "startup.sh missing root-owned /etc/vaultwarden install remediation"
grep -Fq 'sudo install -m 600 -o root -g root ${repo_local_key} ${canonical_key}' startup.sh || fail "startup.sh missing root-owned age key install remediation"
grep -Fq 'sudo make key-health' startup.sh || fail "startup.sh key verification guidance must use sudo make key-health"
pass "startup key remediation stays root-owned"

# Runtime env ownership contract.
grep -Fq 'chown root:root "$manifest_dir"' utilities/setup-env.sh || fail "state config dir is not root-owned"
grep -Fq 'chmod 0700 "$manifest_dir"' utilities/setup-env.sh || fail "state config dir is not mode 0700"
grep -Fq 'chown root:root "$tmp" && chmod 0600 "$tmp"' utilities/setup-env.sh || fail "install.env is not installed root:root 0600"
pass "persistent install.env is installed root:root 0600"

# Encrypted secret authoring remains a normal-user flow.
for f in edit-secrets.sh utilities/secrets-edit.sh utilities/secrets-list.sh utilities/secrets-rotate.sh; do
    grep -Fq 'refuse_root_for_user_command' "$f" || fail "$f no longer refuses root"
done
pass "encrypted secret authoring scripts still refuse root"

# setup-secrets bootstrap must preserve repo .env owner/group/mode across atomic replacement.
grep -Fq 'env_uid=$(stat -c '\''%u'\'' "$env_file"' utilities/setup-secrets.sh || fail "setup-secrets does not capture .env owner"
grep -Fq 'env_mode=$(stat -c '\''%a'\'' "$env_file"' utilities/setup-secrets.sh || fail "setup-secrets does not capture .env mode"
grep -Fq 'chown "$env_uid:$env_gid" "$temp_env"' utilities/setup-secrets.sh || fail "setup-secrets does not restore .env owner/group on temp file"
grep -Fq 'chmod "$env_mode" "$temp_env"' utilities/setup-secrets.sh || fail "setup-secrets does not restore .env mode on temp file"
pass "setup-secrets bootstrap preserves repo .env ownership and mode"

# Encrypted secrets live under operator-owned persistent state, while runtime secrets stay root-owned.
grep -Fq 'chown "$real_user:$real_group" "$secrets_dir"' utilities/setup-secrets.sh || fail "setup-secrets does not chown persistent secrets dir to operator"
grep -Fq 'chmod 700 "$secrets_dir"' utilities/setup-secrets.sh || fail "setup-secrets does not chmod persistent secrets dir 0700"
grep -Fq 'chown "$real_user:$real_group" "$secrets_file"' utilities/setup-secrets.sh || fail "setup-secrets does not keep secrets.yaml operator-owned"
grep -Fq 'chmod 600 "$secrets_file"' utilities/setup-secrets.sh || fail "setup-secrets does not keep secrets.yaml 0600"
grep -Fq 'install -d -m 700 -o root -g root "/run/vaultwarden-oci/secrets"' utilities/setup-secrets.sh || fail "setup-secrets does not keep runtime secret dir root-owned"
grep -Fq 'chown "$real_user:$real_group" "$secrets_dir"' lib/secrets.sh || fail "secure_secrets_file does not restore persistent secrets dir owner"
grep -Fq 'chmod 700 "$secrets_dir"' lib/secrets.sh || fail "secure_secrets_file does not restore persistent secrets dir mode"
grep -Fq 'chown "$real_user:$real_group" "$secrets_file"' lib/secrets.sh || fail "secure_secrets_file does not restore secrets.yaml owner"
grep -Fq 'chmod 600 "$secrets_file"' lib/secrets.sh || fail "secure_secrets_file does not restore secrets.yaml mode"
pass "encrypted secrets stay operator-owned and runtime secrets stay root-owned"

# Operator-facing production next steps.
grep -Fq 'sudo make up' setup.sh || fail "setup next steps do not mention sudo make up"
grep -Fq 'sudo make up' utilities/setup-secrets.sh || fail "setup-secrets next steps do not mention sudo make up"
pass "operator-facing production next steps use sudo make up"

# Dashboard should use root-operated lifecycle/health commands, while keeping user-only secret edit flows non-root.
grep -Fq 'run_sudo_cmd "sudo make restart"' dashboard.sh || fail "dashboard restart label missing"
grep -Fq 'run_sudo_cmd "sudo make down"' dashboard.sh || fail "dashboard stop label missing"
grep -Fq 'run_sudo_cmd "sudo make health"' dashboard.sh || fail "dashboard health label missing"
grep -Fq 'run_user_cmd "./utilities/secrets-edit.sh" "${edit_sh}"' dashboard.sh || fail "dashboard secrets-edit should remain normal-user"
pass "dashboard command labels match root-operated lifecycle"

# Legacy CF token preservation must use root-side file install, not shell value arguments.
grep -Fq 'install -m 0444 -o root -g root "$_cf_flat" "$_cf_dest"' lib/secrets.sh || fail "CF token mirror does not use root-side install"
! grep -Fq '_cf_value' lib/secrets.sh || fail "CF token value should not be read into shell variables"
pass "CF token mirror avoids command-line secret values"

# Generated command reference must be current.
if [[ -f docs/COMMAND-REFERENCE.md ]]; then
    _cmd_ref_before="$(mktemp -t vw-command-reference.XXXXXXXXXX)"
    cp docs/COMMAND-REFERENCE.md "$_cmd_ref_before"
    DOCKER_PROJECT_LABEL=ci bash utilities/write-command-reference.sh >/dev/null
    if ! diff -q docs/COMMAND-REFERENCE.md "$_cmd_ref_before" >/dev/null 2>&1; then
        diff -u "$_cmd_ref_before" docs/COMMAND-REFERENCE.md >&2 || true
        rm -f "$_cmd_ref_before"
        fail "docs/COMMAND-REFERENCE.md is stale; run DOCKER_PROJECT_LABEL=ci bash utilities/write-command-reference.sh"
    fi
    rm -f "$_cmd_ref_before"
    pass "COMMAND-REFERENCE.md is generated/current"
fi
