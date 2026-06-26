#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail(){ echo "FAIL: $*" >&2; exit 1; }
pass(){ echo "PASS: $*"; }

# Makefile integration contract.
# shellcheck disable=SC2016
awk '/^up: /,/^start:/' "$ROOT/Makefile" | grep -Fq '$(MAKE) sync-env' \
  || fail 'make up does not invoke sync-env before startup.sh'
awk '/^up: /,/^start:/' "$ROOT/Makefile" | awk 'BEGIN{s=0} /sync-env/{s=NR} /\.\/startup\.sh/{if(!s || s>NR) exit 1}' \
  || fail 'make up sync-env ordering is wrong'
pass 'make up invokes sync-env before startup.sh'

# shellcheck disable=SC2016
awk '/^restart: /,/^safe-restart:/' "$ROOT/Makefile" | grep -Fq '$(MAKE) sync-env' \
  || fail 'make restart does not invoke sync-env before startup.sh --force'
awk '/^restart: /,/^safe-restart:/' "$ROOT/Makefile" | awk 'BEGIN{s=0} /sync-env/{s=NR} /\.\/startup\.sh --force/{if(!s || s>NR) exit 1}' \
  || fail 'make restart sync-env ordering is wrong'
pass 'make restart invokes sync-env before startup.sh --force'


# Makefile compatibility/admin targets should dispatch to env-edit modes.
awk '/^sync-env: /,/^edit-env:/' "$ROOT/Makefile" | grep -Fq './utilities/env-edit.sh sync' \
  || fail 'make sync-env does not call env-edit.sh sync'
pass 'make sync-env calls env-edit.sh sync'
awk '/^edit-env: /,/^edit-secrets:/' "$ROOT/Makefile" | grep -Fq './utilities/env-edit.sh edit' \
  || fail 'make edit-env does not call env-edit.sh edit'
pass 'make edit-env calls env-edit.sh edit'

# Setup helpers must use non-interactive sync mode.
grep -Fq '"${PROJECT_ROOT}/utilities/env-edit.sh" sync' "$ROOT/utilities/setup-env.sh" \
  || fail 'setup-env.sh does not call env-edit.sh sync'
grep -Fq '"${PROJECT_ROOT}/utilities/env-edit.sh" sync' "$ROOT/utilities/setup-systemd.sh" \
  || fail 'setup-systemd.sh does not call env-edit.sh sync'
! grep -Fq 'env-edit.sh" edit' "$ROOT/utilities/setup-systemd.sh" \
  || fail 'setup-systemd.sh must not use interactive edit mode'
pass 'setup helpers call env-edit.sh sync non-interactively'

# Startup drift visibility must cover the requested non-secret keys and not inspect secrets.
for key in SMTP_FROM SMTP_FROM_NAME ALLOWED_SENDER_DOMAINS MAILGUN_DOMAIN EMAIL_MODE EMAIL_PROVIDER SMTP_HOST SMTP_PORT SMTP_SECURITY; do
  grep -Fq "$key" "$ROOT/startup.sh" || fail "startup drift warning missing $key"
done
awk '/warn_env_drift\(\)/,/^}/' "$ROOT/startup.sh" | grep -Eq 'PASSWORD|TOKEN|SECRET' \
  && fail 'startup drift warning appears to include secret keys'
pass 'startup drift warning covers only requested non-secret keys'
grep -Fq '/etc/vaultwarden/vaultwarden.env' "$ROOT/startup.sh" \
  || fail 'startup drift warning does not compare the systemd EnvironmentFile'
grep -Fq '/config/install.env' "$ROOT/startup.sh" \
  || fail 'startup drift warning does not compare generated install.env'
pass 'startup drift warning compares both generated env files when present'

# setup-systemd may install/correct root-only support files, but env mutation
# must flow back through env-edit sync so install.env and vaultwarden.env do not
# diverge.
setup_systemd_env_block="$(awk '/Installing age key to/,/Installing systemd unit files/' "$ROOT/utilities/setup-systemd.sh")"
! grep -Eq '_set_env_var[[:space:]]+"(SOPS_AGE_KEY_FILE|RCLONE_CONFIG)"' <<< "$setup_systemd_env_block" \
  || fail 'setup-systemd directly mutates runtime-only env overrides instead of using env-edit sync'
grep -Fq '_sync_runtime_environment_files || return 1' <<< "$setup_systemd_env_block" \
  || fail 'setup-systemd does not resync generated env files after age/rclone setup'
awk '/Setting up rclone config/,/_sync_runtime_environment_files/' "$ROOT/utilities/setup-systemd.sh" \
  | awk 'BEGIN{r=0;s=0} /Setting up rclone config/{r=NR} /_sync_runtime_environment_files/{s=NR} END{exit !(r && s && r < s)}' \
  || fail 'setup-systemd must call env-edit sync after rclone config handling'
pass 'setup-systemd centralizes runtime-only env overrides through env-edit sync'

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo 'SKIP: env-edit filesystem behavior requires root'
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TEST_REPO="$TMP/repo"
mkdir -p "$TEST_REPO"
(cd "$ROOT" && tar --exclude=.git -cf - .) | (cd "$TEST_REPO" && tar -xf -)
STATE_DIR="$TMP/state"
ETC_DIR="$TMP/etc-vaultwarden"
cat > "$TEST_REPO/.env" <<EOF_ENV
PROJECT_STATE_DIR=$STATE_DIR
SMTP_FROM=bw@lazymocha.com
SMTP_FROM_NAME=VaultWarden
ALLOWED_SENDER_DOMAINS=lazymocha.com
SOPS_AGE_KEY_FILE=
RCLONE_CONFIG=
EOF_ENV
chmod 0600 "$TEST_REPO/.env"

mkdir -p "$STATE_DIR/config" "$ETC_DIR"
printf 'SMTP_FROM=noreply@bw.lazymocha.com\nALLOWED_SENDER_DOMAINS=bw.lazymocha.com\n' > "$STATE_DIR/config/install.env"
printf 'SMTP_FROM=noreply@bw.lazymocha.com\nALLOWED_SENDER_DOMAINS=bw.lazymocha.com\n' > "$ETC_DIR/vaultwarden.env"
printf '[remote]\n' > "$ETC_DIR/rclone.conf"

( cd "$TEST_REPO" && VW_SYNC_ETC_DIR="$ETC_DIR" ./utilities/env-edit.sh sync >/tmp/env-edit-test.out )
for file in "$STATE_DIR/config/install.env" "$ETC_DIR/vaultwarden.env"; do
  grep -Fxq 'SMTP_FROM=bw@lazymocha.com' "$file" || fail "SMTP_FROM not synced to $file"
  grep -Fxq 'ALLOWED_SENDER_DOMAINS=lazymocha.com' "$file" || fail "ALLOWED_SENDER_DOMAINS not synced to $file"
  grep -Fxq 'SOPS_AGE_KEY_FILE=/etc/vaultwarden/age-key.txt' "$file" || fail "SOPS override missing from $file"
  grep -Fxq "RCLONE_CONFIG=$ETC_DIR/rclone.conf" "$file" || fail "RCLONE_CONFIG override missing from $file"
  [[ "$(stat -c '%U:%G %a' "$file")" == 'root:root 600' ]] || fail "$file is not root:root 600"
done
! grep -Fxq 'SOPS_AGE_KEY_FILE=/etc/vaultwarden/age-key.txt' "$TEST_REPO/.env" || fail 'repo .env was modified with SOPS override'
! grep -Fq "RCLONE_CONFIG=$ETC_DIR/rclone.conf" "$TEST_REPO/.env" || fail 'repo .env was modified with RCLONE override'
pass 'env-edit sync syncs normal config and keeps runtime-only overrides out of repo .env'

rm -f "$ETC_DIR/rclone.conf"
cat > "$TEST_REPO/.env" <<EOF_ENV
PROJECT_STATE_DIR=$STATE_DIR
SMTP_FROM=bw@lazymocha.com
SMTP_FROM_NAME=VaultWarden
ALLOWED_SENDER_DOMAINS=lazymocha.com
SOPS_AGE_KEY_FILE=
RCLONE_CONFIG=
EOF_ENV
chmod 0600 "$TEST_REPO/.env"
( cd "$TEST_REPO" && VW_SYNC_ETC_DIR="$ETC_DIR" ./utilities/env-edit.sh sync >/tmp/env-edit-test.out )
! grep -Fxq "RCLONE_CONFIG=$ETC_DIR/rclone.conf" "$STATE_DIR/config/install.env" || fail 'env-edit sync invented RCLONE_CONFIG when rclone.conf was absent'
! grep -Fxq "RCLONE_CONFIG=$ETC_DIR/rclone.conf" "$ETC_DIR/vaultwarden.env" || fail 'env-edit sync installed invented RCLONE_CONFIG when rclone.conf was absent'
pass 'env-edit sync does not invent canonical RCLONE_CONFIG when rclone.conf is absent'


# env-edit status reports generated env paths.
( cd "$TEST_REPO" && VW_SYNC_ETC_DIR="$ETC_DIR" ./utilities/env-edit.sh status >/tmp/env-edit-status.out )
grep -Fq 'repo .env:' /tmp/env-edit-status.out || fail 'env-edit status did not report repo .env'
grep -Fq 'install.env:' /tmp/env-edit-status.out || fail 'env-edit status did not report install.env'
grep -Fq 'systemd env:' /tmp/env-edit-status.out || fail 'env-edit status did not report systemd env'
pass 'env-edit status reports env file locations'

# edit mode should not sync when the editor leaves .env unchanged.
before_mtime="$(stat -c '%Y' "$STATE_DIR/config/install.env")"
( cd "$TEST_REPO" && EDITOR=true VW_SYNC_ETC_DIR="$ETC_DIR" ./utilities/env-edit.sh edit >/tmp/env-edit-unchanged.out )
after_mtime="$(stat -c '%Y' "$STATE_DIR/config/install.env")"
grep -Fq 'No changes detected' /tmp/env-edit-unchanged.out || fail 'env-edit edit unchanged did not report no changes'
[[ "$before_mtime" == "$after_mtime" ]] || fail 'env-edit edit unchanged rewrote install.env'
pass 'env-edit edit exits cleanly without syncing when .env is unchanged'

# edit mode should sync when the editor changes .env.
editor_script="$TMP/editor-change.sh"
cat > "$editor_script" <<'EOF_EDITOR'
#!/usr/bin/env bash
printf '\nSMTP_FROM=changed@example.com\n' >> "$1"
EOF_EDITOR
chmod +x "$editor_script"
( cd "$TEST_REPO" && EDITOR="$editor_script" VW_SYNC_ETC_DIR="$ETC_DIR" ./utilities/env-edit.sh edit >/tmp/env-edit-changed.out )
grep -Fq 'Changes detected' /tmp/env-edit-changed.out || fail 'env-edit edit changed did not report syncing'
grep -Fxq 'SMTP_FROM=changed@example.com' "$STATE_DIR/config/install.env" || fail 'env-edit edit changed did not sync install.env'
grep -Fxq 'SMTP_FROM=changed@example.com' "$ETC_DIR/vaultwarden.env" || fail 'env-edit edit changed did not sync systemd env'
pass 'env-edit edit syncs when .env changes'
