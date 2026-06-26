#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail(){ echo "FAIL: $*" >&2; exit 1; }
pass(){ echo "PASS: $*"; }

assert_contains(){ grep -Fq -- "$2" "$1" || fail "$3"; }
assert_not_contains(){ ! grep -Fq -- "$2" "$1" || fail "$3"; }

# Makefile/caller wiring.
awk '/^sync-env: /,/^edit-env:/' "$ROOT/Makefile" | grep -Fq './utilities/env-edit.sh sync' || fail 'make sync-env does not call env-edit.sh sync'
awk '/^edit-env: /,/^edit-secrets:/' "$ROOT/Makefile" | grep -Fq './utilities/env-edit.sh edit' || fail 'make edit-env does not call env-edit.sh edit'
awk '/^up: /,/^start:/' "$ROOT/Makefile" | awk 'BEGIN{s=0} /\$\(MAKE\) sync-env/{s=NR} /\.\/startup\.sh/{if(!s || s>NR) exit 1}' || fail 'make up must sync before startup.sh'
awk '/^restart: /,/^safe-restart:/' "$ROOT/Makefile" | awk 'BEGIN{s=0} /\$\(MAKE\) sync-env/{s=NR} /\.\/startup\.sh --force/{if(!s || s>NR) exit 1}' || fail 'make restart must sync before startup.sh --force'
grep -Fq 'utilities/env-edit.sh" sync' "$ROOT/utilities/setup-env.sh" || fail 'setup-env.sh does not call env-edit.sh sync'
grep -Fq 'utilities/env-edit.sh" sync' "$ROOT/utilities/setup-systemd.sh" || fail 'setup-systemd.sh does not call env-edit.sh sync'
pass 'Makefile and setup callers use env-edit.sh sync/edit correctly'

grep -Fq '_cmd_sync "$@"' "$ROOT/utilities/env-edit.sh" || fail 'sync subcommand missing'
! awk '/_cmd_sync\(\)/,/^}/' "$ROOT/utilities/env-edit.sh" | grep -Eq '\$\{EDITOR|EDITOR_CMD|nano|vim|code' || fail 'env-edit sync appears to invoke an editor'
pass 'env-edit sync is non-interactive'

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo 'SKIP: env-edit filesystem behavior requires root'
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
copy_repo(){
  local dest="$1"
  mkdir -p "$dest"
  (cd "$ROOT" && tar --exclude=.git --exclude='.migrate-volume.state' -cf - .) | (cd "$dest" && tar -xf -)
}
write_env(){
  local repo="$1" state="$2" mount="${3:-}" dev="${4:-}"
  cat > "$repo/.env" <<EOF_ENV
PROJECT_STATE_DIR=$state
DATA_VOLUME_DEVICE=$dev
DATA_VOLUME_MOUNT=$mount
SMTP_FROM=bw@lazymocha.com
SMTP_FROM_NAME=VaultWarden
ALLOWED_SENDER_DOMAINS=lazymocha.com
SOPS_AGE_KEY_FILE=
RCLONE_CONFIG=
EOF_ENV
  chmod 0600 "$repo/.env"
}

REPO="$TMP/repo"; copy_repo "$REPO"; STATE="$TMP/state"; ETC="$TMP/etc-vaultwarden"
write_env "$REPO" "$STATE" "" ""
mkdir -p "$ETC"; printf '[remote]\n' > "$ETC/rclone.conf"
( cd "$REPO" && VW_SYNC_ETC_DIR="$ETC" EDITOR="$TMP/missing-editor" ./utilities/env-edit.sh sync >"$TMP/sync.out" ) || fail 'boot-only env-edit sync failed'
for f in "$STATE/config/install.env" "$ETC/vaultwarden.env"; do
  [[ -f "$f" ]] || fail "$f was not created"
  [[ "$(stat -c '%U:%G %a' "$f")" == 'root:root 600' ]] || fail "$f is not root:root 600"
  assert_contains "$f" 'SMTP_FROM=bw@lazymocha.com' "SMTP_FROM not copied to $f"
  assert_contains "$f" 'SOPS_AGE_KEY_FILE=/etc/vaultwarden/age-key.txt' "SOPS override missing from $f"
  assert_contains "$f" "RCLONE_CONFIG=$ETC/rclone.conf" "RCLONE_CONFIG override missing from $f"
done
assert_not_contains "$REPO/.env" '/etc/vaultwarden/age-key.txt' 'repo .env received SOPS runtime override'
assert_not_contains "$REPO/.env" "RCLONE_CONFIG=$ETC/rclone.conf" 'repo .env received RCLONE runtime override'
pass 'boot-only sync writes generated env files and keeps runtime-only overrides out of repo .env'

rm -f "$ETC/rclone.conf"
( cd "$REPO" && VW_SYNC_ETC_DIR="$ETC" ./utilities/env-edit.sh sync >/dev/null ) || fail 'boot-only sync without rclone failed'
assert_not_contains "$STATE/config/install.env" "RCLONE_CONFIG=$ETC/rclone.conf" 'RCLONE_CONFIG injected when rclone.conf absent'
pass 'RCLONE_CONFIG is injected only when rclone.conf exists'


# Data-volume fail-closed cases.
for case in missing-device mismatch not-mounted; do
  R="$TMP/repo-$case"; copy_repo "$R"; M="$TMP/mount-$case"; mkdir -p "$M"
  case "$case" in
    missing-device) write_env "$R" "$M" "$M" "/dev/vwmissing$RANDOM" ;;
    mismatch) write_env "$R" "$TMP/state-mismatch" "$M" "/dev/vwmissing$RANDOM" ;;
    not-mounted) write_env "$R" "$M" "$M" "/dev/vwmissing$RANDOM" ;;
  esac
  if ( cd "$R" && VW_SYNC_ETC_DIR="$TMP/etc-$case" ./utilities/env-edit.sh sync >"$TMP/$case.out" 2>&1 ); then
    fail "data-volume case $case unexpectedly succeeded"
  fi
  [[ ! -e "$M/config/install.env" ]] || fail "data-volume case $case created install.env"
  grep -Eiq 'Storage|DATA_VOLUME|mounted|block device|PROJECT_STATE_DIR' "$TMP/$case.out" || fail "data-volume case $case error was unclear"
done
pass 'data-volume negative cases fail closed without writing install.env'

R="$TMP/repo-migration"; copy_repo "$R"; write_env "$R" "$TMP/migrate-state" "" ""
printf 'MIGRATION_STARTED=true\n' > "$R/.migrate-volume.state"
if ( cd "$R" && VW_SYNC_ETC_DIR="$TMP/migrate-etc" ./utilities/env-edit.sh sync >"$TMP/migrate-block.out" 2>&1 ); then fail 'incomplete migration did not block sync'; fi
[[ ! -e "$TMP/migrate-state/config/install.env" ]] || fail 'migration guard wrote install.env'
grep -Eiq 'resume|abort|migration' "$TMP/migrate-block.out" || fail 'migration guard error missing resume/abort'
printf 'MIGRATION_COMPLETE=true\n' > "$R/.migrate-volume.state"
( cd "$R" && VW_SYNC_ETC_DIR="$TMP/migrate-etc" ./utilities/env-edit.sh sync >/dev/null ) || fail 'complete migration still blocked sync'
pass 'migration-state guard blocks incomplete sync and allows completed migration'

R="$TMP/repo-edit"; copy_repo "$R"; write_env "$R" "$TMP/edit-state" "" ""
mkdir -p "$TMP/edit-etc"
( cd "$R" && VW_SYNC_ETC_DIR="$TMP/edit-etc" ./utilities/env-edit.sh sync >/dev/null )
BEFORE="$(stat -c %Y "$TMP/edit-state/config/install.env")"
cat > "$TMP/noop-editor" <<'EON'
#!/usr/bin/env bash
exit 0
EON
chmod +x "$TMP/noop-editor"
( cd "$R" && VW_SYNC_ETC_DIR="$TMP/edit-etc" EDITOR="$TMP/noop-editor" ./utilities/env-edit.sh edit >"$TMP/edit-noop.out" ) || fail 'unchanged edit failed'
grep -Fq 'No changes detected' "$TMP/edit-noop.out" || fail 'unchanged edit did not report no changes'
[[ "$(stat -c %Y "$TMP/edit-state/config/install.env")" == "$BEFORE" ]] || fail 'unchanged edit rewrote install.env'

OWNER="$(stat -c '%u:%g' "$R/.env")"
cat > "$TMP/change-editor" <<'EOC'
#!/usr/bin/env bash
target="${@: -1}"
sed -i 's/^SMTP_FROM=.*/SMTP_FROM=changed@lazymocha.com/' "$target"
chmod 0644 "$target"
EOC
chmod +x "$TMP/change-editor"
( cd "$R" && VW_SYNC_ETC_DIR="$TMP/edit-etc" EDITOR="$TMP/change-editor --flag" ./utilities/env-edit.sh edit >"$TMP/edit-change.out" ) || fail 'changed edit failed'
assert_contains "$TMP/edit-state/config/install.env" 'SMTP_FROM=changed@lazymocha.com' 'changed SMTP_FROM not synced to install.env'
[[ "$(stat -c '%a' "$R/.env")" == '600' ]] || fail 'repo .env mode not restored to 0600'
[[ "$(stat -c '%u:%g' "$R/.env")" == "$OWNER" ]] || fail 'repo .env owner/group not preserved'
pass 'edit mode detects unchanged files, parses EDITOR flags, syncs changes, and preserves .env metadata'

R="$TMP/repo-status"; copy_repo "$R"; write_env "$R" "$TMP/status-state" "$TMP/other-mount" "/dev/vwmissing$RANDOM"
printf 'MIGRATION_STARTED=true\n' > "$R/.migrate-volume.state"
( cd "$R" && VW_SYNC_ETC_DIR="$TMP/status-etc" ./utilities/env-edit.sh status >"$TMP/status.out" ) || fail 'status failed'
grep -Fq 'Repo .env:' "$TMP/status.out" || fail 'status missing repo .env'
grep -Fq 'Install env:' "$TMP/status.out" || fail 'status missing install.env path'
grep -Fq 'Runtime env:' "$TMP/status.out" || fail 'status missing runtime env path'
grep -Fq 'Migration state:' "$TMP/status.out" || fail 'status missing migration state'
grep -Fq 'MISMATCH' "$TMP/status.out" || fail 'status missing storage mismatch'
[[ ! -e "$TMP/status-state/config/install.env" ]] || fail 'status wrote install.env'
pass 'status is read-only and reports env paths, migration state, and storage mismatch'
