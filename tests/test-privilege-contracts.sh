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
for target in up down start stop restart health health-quick health-report status logs logs-tail logs-vaultwarden logs-caddy logs-postfix logs-crowdsec crowdsec-status crowdsec-alerts security-report edit-secrets test-secrets test-email health-email diagnose systemd-status prune key-show; do
    grep -Eq "(^|[[:space:]])${target}([[:space:]]|\|$)" Makefile || fail "${target} is not root-allowed"
done
pass "root-supported lifecycle/day-2 targets are allowed under sudo make"

for target in health health-quick health-report status logs logs-tail logs-vaultwarden logs-caddy logs-postfix logs-crowdsec crowdsec-status crowdsec-alerts security-report edit-secrets test-secrets test-email diagnose systemd-status prune key-show; do
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
grep -Fq 'install -d -m 0700 -o root -g root "$manifest_dir" "$rendered_state_dir/secrets"' utilities/setup-env.sh || fail "state config/secrets dirs are not created root:root 0700"
grep -Fq 'chown root:root "$tmp" && chmod 0600 "$tmp"' utilities/setup-env.sh || fail "install.env is not installed root:root 0600"
pass "persistent install.env is installed root:root 0600"

# Encrypted secret authoring is root-operated.
for f in edit-secrets.sh utilities/secrets-edit.sh utilities/secrets-list.sh utilities/secrets-view.sh utilities/secrets-rotate.sh utilities/secrets-export-recovery-kit.sh; do
    grep -Fq 'require_root "$@"' "$f" || fail "$f does not require root"
done
pass "encrypted secret authoring scripts require root"


if (( EUID == 0 )) && command -v runuser >/dev/null 2>&1; then
    for cmd in \
        "utilities/secrets-list.sh list" \
        "utilities/secrets-view.sh view" \
        "utilities/secrets-edit.sh edit" \
        "utilities/secrets-rotate.sh rotate email_api_token --dry-run" \
        "utilities/secrets-export-recovery-kit.sh export-recovery-kit"; do
        _out="$(mktemp -t vw-nonroot-secret.XXXXXXXXXX)"
        if runuser -u nobody -- bash -c "cd '$ROOT' && bash $cmd" >"$_out" 2>&1; then
            cat "$_out" >&2
            rm -f "$_out"
            fail "$cmd should reject non-root execution"
        fi
        grep -Fq 'Re-run with: sudo' "$_out" || { cat "$_out" >&2; rm -f "$_out"; fail "$cmd rejection lacks sudo hint"; }
        rm -f "$_out"
    done
    pass "secrets subcommands reject non-root execution with sudo guidance"
else
    pass "secrets non-root rejection test skipped (requires root test runner with runuser)"
fi

for f in utilities/secrets-list.sh utilities/secrets-view.sh utilities/secrets-edit.sh utilities/secrets-rotate.sh utilities/secrets-export-recovery-kit.sh; do
    grep -Fq '/etc/vaultwarden/age-key.txt' "$f" || fail "$f diagnostics do not mention canonical Age key path"
done
grep -Fq 'resolve_age_key_path >/dev/null 2>&1' utilities/secrets-list.sh || fail "secrets-list does not resolve active Age key"
grep -Fq 'resolve_age_key_path >/dev/null 2>&1' utilities/secrets-view.sh || fail "secrets-view does not resolve active Age key"
pass "secrets prerequisite checks use active Age key resolver and canonical diagnostics"

grep -Fq '"/etc/vaultwarden/age-key.txt"' lib/crypto.sh || fail "Age key resolver does not include installed canonical path"
grep -Fq '"/etc/vaultwarden/vaultwarden.env"' lib/config.sh || fail "environment loader does not include installed env path"
pass "root execution can resolve installed Age key and env defaults"

# setup-secrets bootstrap must preserve repo .env owner/group/mode across atomic replacement.
grep -Fq 'env_uid=$(stat -c '\''%u'\'' "$env_file"' utilities/setup-secrets.sh || fail "setup-secrets does not capture .env owner"
grep -Fq 'env_mode=$(stat -c '\''%a'\'' "$env_file"' utilities/setup-secrets.sh || fail "setup-secrets does not capture .env mode"
grep -Fq 'chown "$env_uid:$env_gid" "$temp_env"' utilities/setup-secrets.sh || fail "setup-secrets does not restore .env owner/group on temp file"
grep -Fq 'chmod "$env_mode" "$temp_env"' utilities/setup-secrets.sh || fail "setup-secrets does not restore .env mode on temp file"
pass "setup-secrets bootstrap preserves repo .env ownership and mode"

# Encrypted secrets live under root-owned persistent state, and runtime secrets stay root-owned.
grep -Fq 'chown root:root "$secrets_dir"' utilities/setup-secrets.sh || fail "setup-secrets does not chown persistent secrets dir to root"
grep -Fq 'chmod 700 "$secrets_dir"' utilities/setup-secrets.sh || fail "setup-secrets does not chmod persistent secrets dir 0700"
grep -Fq 'chown root:root "$secrets_file"' utilities/setup-secrets.sh || fail "setup-secrets does not keep secrets.yaml root-owned"
grep -Fq 'chmod 600 "$secrets_file"' utilities/setup-secrets.sh || fail "setup-secrets does not keep secrets.yaml 0600"
grep -Fq 'install -d -m 700 -o root -g root "/run/vaultwarden-oci/secrets"' utilities/setup-secrets.sh || fail "setup-secrets does not keep runtime secret dir root-owned"
grep -Fq 'fix_known_path_permissions "$secrets_dir"' lib/secrets.sh || fail "secure_secrets_file does not defer secrets dir to central permission helper"
grep -Fq 'fix_known_path_permissions "$secrets_file"' lib/secrets.sh || fail "secure_secrets_file does not defer secrets.yaml to central permission helper"
pass "encrypted secrets stay root-owned and runtime secrets stay root-owned"

# Operator-facing production next steps.
grep -Fq 'sudo make up' setup.sh || fail "setup next steps do not mention sudo make up"
grep -Fq 'sudo make up' utilities/setup-secrets.sh || fail "setup-secrets next steps do not mention sudo make up"
pass "operator-facing production next steps use sudo make up"

# Dashboard should use root-operated lifecycle/health/secrets commands.
grep -Fq 'run_sudo_cmd "sudo make restart"' dashboard.sh || fail "dashboard restart label missing"
grep -Fq 'run_sudo_cmd "sudo make down"' dashboard.sh || fail "dashboard stop label missing"
grep -Fq 'run_sudo_cmd "sudo make health"' dashboard.sh || fail "dashboard health label missing"
grep -Fq 'run_sudo_cmd "sudo ./utilities/secrets-edit.sh" "${edit_sh}"' dashboard.sh || fail "dashboard secrets-edit should use sudo"
grep -Fq 'run_sudo_cmd "sudo ./utilities/secrets-export-recovery-kit.sh" "${kit_sh}"' dashboard.sh || fail "dashboard recovery-kit export should stay root-operated"
grep -Fq 'run_sudo_cmd "sudo make test-email" make -C "${REPO_ROOT}" test-email' dashboard.sh || fail "dashboard email diagnostic should stay root-operated"
! grep -Fq 'run_user_cmd' dashboard.sh || fail "dashboard should not drop root for root-operated actions"
pass "dashboard command labels match root-operated lifecycle"

grep -Fq 'sudo ./setup.sh install --domain <your-domain> --email <your-email>' Makefile \
    || fail "Makefile setup guidance must advertise supported first-install command"
SETUP_SNIP="$(mktemp -t vw-setup-guidance.XXXXXXXXXX)"
extract_make_target setup Makefile > "$SETUP_SNIP" || fail "could not extract setup target"
grep -Fq 'guidance only' "$SETUP_SNIP" || fail "make setup should be guidance only"
grep -Fq '@exit 1' "$SETUP_SNIP" || fail "make setup guidance target must exit non-zero"
rm -f "$SETUP_SNIP"
pass "make setup is no longer advertised as a working first-install parser"

! grep -Eq '^key-path:' Makefile || fail "redundant key-path target should be removed"
grep -Fq 'Create local Age key copy for manual offline transfer' Makefile || fail "key-backup wording must say local transfer copy"
grep -Fq 'NOT OFFLINE YET' Makefile || fail "key-backup must warn local copy is not offline custody"
pass "key inspection/backup targets avoid misleading production status"

STATUS_SNIP="$(mktemp -t vw-status-contract.XXXXXXXXXX)"
extract_make_target status Makefile > "$STATUS_SNIP" || fail "could not extract status target"
grep -Fq 'CSCLI_RC=$$?' "$STATUS_SNIP" || fail "make status must capture cscli exit status"
grep -Fq 'unknown (cscli query failed)' "$STATUS_SNIP" || fail "make status must not turn cscli failure into zero bans"
rm -f "$STATUS_SNIP"
UNBAN_SNIP="$(mktemp -t vw-unban-contract.XXXXXXXXXX)"
extract_make_target unban Makefile > "$UNBAN_SNIP" || fail "could not extract unban target"
grep -Fq 'CSCLI_RC=$$?' "$UNBAN_SNIP" || fail "make unban must capture cscli exit status"
grep -Fq 'CrowdSec unban failed; see cscli output above.' "$UNBAN_SNIP" || fail "make unban must preserve generic cscli errors"
! grep -Fq '&& echo "$(GREEN)' "$UNBAN_SNIP" || fail "make unban must not use command && success || benign fallback"
rm -f "$UNBAN_SNIP"
pass "CrowdSec status and unban preserve real cscli failures"

# Legacy CF token preservation must use root-side file install, not shell value arguments.
grep -Fq 'install -m 0444 -o root -g root "$_cf_flat" "$_cf_dest"' lib/secrets.sh || fail "CF token mirror does not use root-side install"
! grep -Fq '_cf_value' lib/secrets.sh || fail "CF token value should not be read into shell variables"
pass "CF token mirror avoids command-line secret values"


# Operator-facing breakglass-remove must preserve the utility confirmation by default.
BREAKGLASS_REMOVE_SNIP="$(mktemp -t vw-breakglass-remove.XXXXXXXXXX)"
extract_make_target breakglass-remove Makefile > "$BREAKGLASS_REMOVE_SNIP" || fail "could not extract make breakglass-remove target"
grep -Fq 'utilities/setup-secrets.sh breakglass remove' "$BREAKGLASS_REMOVE_SNIP" || fail "make breakglass-remove does not call setup-secrets breakglass remove"
! grep -Fq -- '--force' "$BREAKGLASS_REMOVE_SNIP" || fail "make breakglass-remove must not bypass the utility confirmation with --force"
rm -f "$BREAKGLASS_REMOVE_SNIP"
pass "make breakglass-remove preserves break-glass removal confirmation"

# update-system intentionally remains a direct host package update, with wording that
# distinguishes it from the managed container update workflow while routing through
# the maintenance runner for the shared operation guard and package-manager retry path.
UPDATE_SYSTEM_SNIP="$(mktemp -t vw-update-system.XXXXXXXXXX)"
extract_make_target update-system Makefile > "$UPDATE_SYSTEM_SNIP" || fail "could not extract make update-system target"
grep -Fq 'Updating host OS packages directly' "$UPDATE_SYSTEM_SNIP" || fail "make update-system does not clearly describe direct host package semantics"
grep -Fq 'does not create a VaultWarden pre-update backup or run the managed Compose restart/health workflow' "$UPDATE_SYSTEM_SNIP" || fail "make update-system missing managed-workflow distinction"
grep -Fq 'Host package updates may still restart system services or require a reboot' "$UPDATE_SYSTEM_SNIP" || fail "make update-system missing package-manager side-effect warning"
grep -Fq './maintenance.sh update --system --skip-backup' "$UPDATE_SYSTEM_SNIP" || fail "make update-system must use guarded maintenance system-update path"
rm -f "$UPDATE_SYSTEM_SNIP"
pass "make update-system direct package-update semantics are explicit"

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

grep -Fq 'require_root "$@"' utilities/notify-failure.sh || fail "notify-failure lacks explicit root guard"
pass "notify-failure explicitly requires root"

_backup_list_snip="$(awk '/if \[\[ "\$LIST_ONLY" == "true" \]\]/{flag=1} flag{print} /exit 0/{if(flag){exit}}' utilities/backup-run.sh)"
! grep -Fq 'auto_fix_critical_permissions' <<<"$_backup_list_snip" || fail "backup list-only path mutates permissions"
_restore_pre_root_snip="$(awk '/load_env_file 2>\/dev\/null/{flag=1} /require_root "\$@"/{if(flag){exit}} flag{print}' utilities/restore-run.sh)"
! grep -Fq 'auto_fix_critical_permissions' <<<"$_restore_pre_root_snip" || fail "restore list-only/pre-root path mutates permissions"
pass "backup/restore list-only paths avoid mutating permission repair"

grep -Fq 'sudo ./maintenance.sh <subcommand>' maintenance.sh || fail "maintenance help does not show sudo usage"
grep -Fq 'sudo ./maintenance.sh update-dns' utilities/maintenance-update-dns.sh || fail "DNS updater help lacks sudo dispatcher example"
grep -Fq 'sudo ./maintenance.sh update-firewall' utilities/maintenance-update-firewall.sh || fail "firewall updater help lacks sudo dispatcher example"
! grep -Fq 'Run: ./edit-secrets.sh rotate' utilities/setup-crowdsec.sh || fail "setup post-install guidance advertises non-sudo edit-secrets"
pass "help text uses sudo for root-operated maintenance/secret commands"
