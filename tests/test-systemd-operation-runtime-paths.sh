#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPS="$ROOT/lib/operations.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

canonical="$(
  sed -n 's/^: "${VW_OPERATIONS_STATE_DIR:=\(.*\)}"$/\1/p' "$OPS"
)"
[[ -n "$canonical" ]] || fail "could not derive VW_OPERATIONS_STATE_DIR from lib/operations.sh"
canonical_root="${canonical%/operations}"
[[ "$canonical" == "/run/vaultwarden-oci/operations" ]] \
  || fail "unexpected canonical operations state dir: $canonical"

guarded_units=(
  vaultwarden-db-backup.service
  vaultwarden-full-backup.service
  vaultwarden-maintenance.service
  vaultwarden-health.service
  vaultwarden-dns-update.service
  vaultwarden-firewall-update.service
  vaultwarden-iptables.service
  vaultwarden-startup.service
)

for unit in "${guarded_units[@]}"; do
  file="$ROOT/systemd/$unit"
  [[ -f "$file" ]] || fail "missing unit: $unit"
  grep -Eq "^ReadWritePaths=.*${canonical_root}" "$file" \
    || fail "$unit does not grant writable canonical operation root $canonical_root"
  grep -Eq "^RuntimeDirectory=.*vaultwarden-oci" "$file" \
    || fail "$unit does not pre-create /run/vaultwarden-oci"
  if grep -Eq '^ReadWritePaths=.* /run/vaultwarden(\s|$)' "$file"; then
    fail "$unit still grants stale /run/vaultwarden operation path"
  fi
done

printf 'PASS: systemd operation runtime paths\n'
