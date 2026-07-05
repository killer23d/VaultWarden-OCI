#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require() {
  grep -Eq -- "$1" "$2" || fail "$3"
}

reject() {
  ! grep -Eq -- "$1" "$2" || fail "$3"
}

line_no() {
  grep -n -- "$1" "$2" | head -1 | cut -d: -f1
}

SETUP_SECRETS="$ROOT/utilities/setup-secrets.sh"
SECRETS_EDIT="$ROOT/utilities/secrets-edit.sh"
SECRETS_ROTATE="$ROOT/utilities/secrets-rotate.sh"
ENV_EDIT="$ROOT/utilities/env-edit.sh"
SETUP_ENV="$ROOT/utilities/setup-env.sh"
SETUP_SYSTEMD="$ROOT/utilities/setup-systemd.sh"
IPTABLES_UNIT="$ROOT/systemd/vaultwarden-iptables.service"

for file in "$SETUP_SECRETS" "$SECRETS_EDIT" "$SECRETS_ROTATE"; do
  require 'lib/operations\.sh|source "\$\{PROJECT_ROOT\}/lib/operations\.sh"' "$file" \
    "secrets mutator must source operation library: $file"
  require '--id secrets' "$file" "secrets mutator must use secrets operation id: $file"
  require '--specific-lock /run/lock/vaultwarden-secrets\.lock' "$file" \
    "secrets mutator must use secrets-specific lock: $file"
done

edit_guard_line="$(line_no 'operation_acquire' "$SECRETS_EDIT")"
edit_sops_line="$(line_no 'sops -d' "$SECRETS_EDIT")"
[[ -n "$edit_guard_line" && -n "$edit_sops_line" && "$edit_guard_line" -lt "$edit_sops_line" ]] \
  || fail "secrets-edit must acquire guard before decrypting"

rotate_guard_line="$(line_no 'operation_acquire' "$SECRETS_ROTATE")"
rotate_sops_line="$(line_no 'sops -d' "$SECRETS_ROTATE")"
[[ -n "$rotate_guard_line" && -n "$rotate_sops_line" && "$rotate_guard_line" -lt "$rotate_sops_line" ]] \
  || fail "secrets-rotate must acquire guard before decrypting"

require '_setup_secrets_should_guard' "$SETUP_SECRETS" \
  "setup-secrets must distinguish mutating and read-only breakglass actions"
require 'status\).*SHOW_STATUS' "$SETUP_SECRETS" \
  "setup-secrets breakglass status must remain a read-only action"

require '--id env-sync' "$ENV_EDIT" "env-edit mutating paths must use env-sync operation id"
require '--specific-lock /run/lock/vaultwarden-env\.lock' "$ENV_EDIT" \
  "env-edit sync/edit must use env-specific lock"
require '_cmd_status "\$@"' "$ENV_EDIT" "env-edit status must remain available"

require '--id env-sync' "$SETUP_ENV" "setup-env direct mutation must use env-sync operation id"
reject '--specific-lock /run/lock/vaultwarden-env\.lock' "$SETUP_ENV" \
  "setup-env parent must not hold env-specific lock before nested env-edit sync"
require 'utilities/env-edit\.sh" sync' "$SETUP_ENV" \
  "setup-env must keep nested env sync under inherited global lock"

require '--id systemd-install' "$SETUP_SYSTEMD" \
  "setup-systemd install/remove must use systemd-install operation id"
require '--specific-lock /run/lock/vaultwarden-systemd\.lock' "$SETUP_SYSTEMD" \
  "setup-systemd must use systemd-specific lock"
require 'utilities/setup-firewall\.sh' "$SETUP_SYSTEMD" \
  "setup-systemd must preserve structured setup-firewall utility path"
reject 'script" == "utilities/setup-firewall\.sh"' "$SETUP_SYSTEMD" \
  "setup-systemd must not flat-install setup-firewall.sh"

require '^ExecStart=/bin/bash /opt/vaultwarden-scripts/utilities/setup-firewall\.sh --phase iptables --auto$' "$IPTABLES_UNIT" \
  "iptables unit must invoke structured installed setup-firewall path with --auto"
require '^SuccessExitStatus=0 75$' "$IPTABLES_UNIT" \
  "iptables unit must treat expected contention as success"
require '^ReadWritePaths=.*/run/lock' "$IPTABLES_UNIT" \
  "iptables unit must expose operation lock path"
require '^ReadWritePaths=.*/run/vaultwarden-oci' "$IPTABLES_UNIT" \
  "iptables unit must expose operation state path"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/opt/vaultwarden-scripts"
cp -R "$ROOT/lib" "$tmp/opt/vaultwarden-scripts/lib"
mkdir -p "$tmp/opt/vaultwarden-scripts/utilities"
cp "$ROOT/utilities/setup-firewall.sh" "$tmp/opt/vaultwarden-scripts/utilities/setup-firewall.sh"
if (( BASH_VERSINFO[0] >= 4 )); then
  "$BASH" "$tmp/opt/vaultwarden-scripts/utilities/setup-firewall.sh" --help >/dev/null
else
  printf 'SKIP: installed setup-firewall help smoke requires Bash 4+ for repo libraries\n'
fi

printf 'PASS: secrets/env/systemd operation guards\n'
