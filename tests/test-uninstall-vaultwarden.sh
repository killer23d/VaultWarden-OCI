#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/utilities/uninstall-vaultwarden.sh"
TMP="$(mktemp -d)"
ORIG_ENV_BACKUP=""
cleanup() {
  rm -rf "$TMP"
  if [[ -n "$ORIG_ENV_BACKUP" && -f "$ORIG_ENV_BACKUP" ]]; then
    mv -f "$ORIG_ENV_BACKUP" "$ROOT/.env"
  else
    rm -f "$ROOT/.env"
  fi
}
trap cleanup EXIT

if [[ -f "$ROOT/.env" ]]; then
  ORIG_ENV_BACKUP="$TMP/original.env"
  cp "$ROOT/.env" "$ORIG_ENV_BACKUP"
fi

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "did not expect '$2' in $1"; }

bash -n "$SCRIPT"
"$SCRIPT" --help >/dev/null
"$SCRIPT" --version >/dev/null

# Dry-run does not require root-only live operations and does not mutate repo .env.
printf 'PROJECT_STATE_DIR=%s/state-repo\nDATA_VOLUME_DEVICE=\n' "$TMP" > "$ROOT/.env"
before="$(sha256sum "$ROOT/.env" | awk '{print $1}')"
"$SCRIPT" run --dry-run > "$TMP/dry-repo.out" 2>&1
_after="$(sha256sum "$ROOT/.env" | awk '{print $1}')"
[[ "$before" == "$_after" ]] || fail "dry-run mutated repo .env"
assert_contains "$TMP/dry-repo.out" "Storage mode      : boot-volume"
assert_contains "$TMP/dry-repo.out" "$TMP/state-repo"

# Install env discovered through repo PROJECT_STATE_DIR takes precedence over repo-local values.
mkdir -p "$TMP/state-repo/config"
printf 'PROJECT_STATE_DIR=%s/state-installed\nDATA_VOLUME_DEVICE=\n' "$TMP" > "$TMP/state-repo/config/install.env"
"$SCRIPT" run --dry-run > "$TMP/dry-install.out" 2>&1
assert_contains "$TMP/dry-install.out" "$TMP/state-installed"

# Separate-volume path resolution and unmounted safety wording.
printf 'PROJECT_STATE_DIR=%s/mnt\nDATA_VOLUME_DEVICE=/dev/sdz\nDATA_VOLUME_MOUNT=%s/mnt\n' "$TMP" "$TMP" > "$ROOT/.env"
rm -rf "$TMP/state-repo"
"$SCRIPT" run --dry-run > "$TMP/dry-block.out" 2>&1
assert_contains "$TMP/dry-block.out" "Storage mode      : separate block-storage"
assert_contains "$TMP/dry-block.out" "device=/dev/sdz mount=$TMP/mnt mounted=false sentinel=false"
assert_contains "$TMP/dry-block.out" "unmounted mountpoint contents will NOT be recursively deleted"

# Systemd and Docker managed lists match current setup contracts.
assert_contains "$SCRIPT" "vaultwarden-firewall-update.timer"
assert_contains "$SCRIPT" "vaultwarden-notify-failure@.service"
assert_contains "$SCRIPT" "vaultwarden-startup.service"
assert_contains "$SCRIPT" "10-state-dir.conf"
assert_contains "$SCRIPT" "20-identity.conf"
assert_contains "$SCRIPT" "30-run-as-root.conf"
assert_contains "$SCRIPT" "vaultwarden_init"
assert_contains "$SCRIPT" "vaultwarden_app"
assert_contains "$SCRIPT" "vaultwarden_caddy"
assert_contains "$SCRIPT" "vaultwarden_postfix"
assert_contains "$SCRIPT" "vaultwarden_egress_network"
assert_contains "$SCRIPT" "caddy_external_network"
assert_contains "$SCRIPT" "postfix_relay_network"
assert_not_contains "$SCRIPT" "name=caddy"
assert_not_contains "$SCRIPT" "name=postfix"


# External BACKUP_DIR preservation must run before checkout deletion can remove its parent.
assert_contains "$SCRIPT" "_backup_dir_is_external_to_state()"
assert_contains "$SCRIPT" "Preserving project checkout because external BACKUP_DIR is inside it"
assert_contains "$SCRIPT" "Move/delete the backup directory manually"
state_line="$(awk '/^main\(\)/{in_main=1} in_main && /remove_state_and_mount/{print NR; exit}' "$SCRIPT")"
installed_line="$(awk '/^main\(\)/{in_main=1} in_main && /remove_installed_files/{print NR; exit}' "$SCRIPT")"
[[ -n "$state_line" && -n "$installed_line" ]] || fail "could not locate cleanup order in main"
(( state_line < installed_line )) || fail "remove_state_and_mount must run before remove_installed_files"

# _safe_rm_rf broad-path denylist contract.
assert_contains "$SCRIPT" "Refusing to remove unsafe broad path"
assert_contains "$SCRIPT" "/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/mnt|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var|/var/lib"

echo "test-uninstall-vaultwarden: ok"
