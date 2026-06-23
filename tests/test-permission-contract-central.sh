#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }

source lib/log.sh
source lib/common.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROJECT_STATE_DIR="$TMP/state"
PROJECT_ROOT="$TMP/repo"
export PROJECT_STATE_DIR PROJECT_ROOT SUDO_USER="$(id -un)" SUDO_GID="$(id -g)"
mkdir -p "$PROJECT_ROOT/secrets/keys" "$PROJECT_STATE_DIR/config" "$TMP/etc" "$TMP/run/secrets"

operator="$(get_real_user)"
operator_group="$(id -gn "$operator")"

[[ "$(expected_owner_for_path /etc/vaultwarden/age-key.txt)" == root ]] || fail '/etc age key owner is not root'
[[ "$(expected_group_for_path /etc/vaultwarden/age-key.txt)" == root ]] || fail '/etc age key group is not root'
[[ "$(expected_mode_for_path /etc/vaultwarden/age-key.txt)" == 600 ]] || fail '/etc age key mode is not 600'
pass '/etc/vaultwarden/age-key.txt contract is root:root 0600'

[[ "$(expected_owner_for_path "$PROJECT_ROOT/secrets/keys/age-key.txt")" == "$operator" ]] || fail 'repo age key owner is not operator'
[[ "$(expected_group_for_path "$PROJECT_ROOT/secrets/keys/age-key.txt")" == "$operator_group" ]] || fail 'repo age key group is not operator group'
[[ "$(expected_mode_for_path "$PROJECT_ROOT/secrets/keys/age-key.txt")" == 600 ]] || fail 'repo age key mode is not 600'
pass 'repo-local age key contract is operator-owned 0600'

for p in /etc/vaultwarden/vaultwarden.env /etc/vaultwarden/rclone.conf "$PROJECT_STATE_DIR/config/install.env" "$PROJECT_STATE_DIR/config/dr-manifest.env"; do
    [[ "$(expected_owner_for_path "$p")" == root ]] || fail "$p owner is not root"
    [[ "$(expected_group_for_path "$p")" == root ]] || fail "$p group is not root"
    [[ "$(expected_mode_for_path "$p")" == 600 ]] || fail "$p mode is not 600"
done
pass 'installed env/key config files remain root-owned 0600'

for p in "$PROJECT_ROOT/.env" "$PROJECT_ROOT/secrets/secrets.yaml"; do
    [[ "$(expected_owner_for_path "$p")" == "$operator" ]] || fail "$p owner is not operator"
    [[ "$(expected_mode_for_path "$p")" == 600 ]] || fail "$p mode is not 600"
done
[[ "$(expected_mode_for_path "$PROJECT_ROOT/.sops.yaml")" == 644 ]] || fail '.sops.yaml mode is not 0644'
pass 'repo editable files remain operator-owned with expected modes'

age_warn_pattern="Age key ownership was .*expected.*ubunt""u"
! grep -RIn "$age_warn_pattern" . --exclude-dir=.git >/tmp/vw-age-warn.$$ || { cat /tmp/vw-age-warn.$$ >&2; rm -f /tmp/vw-age-warn.$$; fail 'stale ubuntu age-key warning found'; }
rm -f /tmp/vw-age-warn.$$
ubuntu_expect_pattern="expected 'ubunt""u:ubuntu'"
! grep -RIn "$ubuntu_expect_pattern" . --exclude-dir=.git >/tmp/vw-ubuntu-expect.$$ || { cat /tmp/vw-ubuntu-expect.$$ >&2; rm -f /tmp/vw-ubuntu-expect.$$; fail 'stale expected ubuntu:ubuntu text found'; }
rm -f /tmp/vw-ubuntu-expect.$$
pass 'stale ubuntu ownership warnings are absent'
