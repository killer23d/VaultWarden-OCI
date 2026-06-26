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

# Startup drift visibility must cover the requested non-secret keys and not inspect secrets.
for key in SMTP_FROM SMTP_FROM_NAME ALLOWED_SENDER_DOMAINS MAILGUN_DOMAIN EMAIL_MODE EMAIL_PROVIDER SMTP_HOST SMTP_PORT SMTP_SECURITY; do
  grep -Fq "$key" "$ROOT/startup.sh" || fail "startup drift warning missing $key"
done
awk '/warn_env_drift\(\)/,/^}/' "$ROOT/startup.sh" | grep -Eq 'PASSWORD|TOKEN|SECRET' \
  && fail 'startup drift warning appears to include secret keys'
pass 'startup drift warning covers only requested non-secret keys'

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo 'SKIP: sync-env filesystem behavior requires root'
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

( cd "$TEST_REPO" && VW_SYNC_ETC_DIR="$ETC_DIR" ./utilities/sync-env.sh >/tmp/sync-env-test.out )
for file in "$STATE_DIR/config/install.env" "$ETC_DIR/vaultwarden.env"; do
  grep -Fxq 'SMTP_FROM=bw@lazymocha.com' "$file" || fail "SMTP_FROM not synced to $file"
  grep -Fxq 'ALLOWED_SENDER_DOMAINS=lazymocha.com' "$file" || fail "ALLOWED_SENDER_DOMAINS not synced to $file"
  grep -Fxq 'SOPS_AGE_KEY_FILE=/etc/vaultwarden/age-key.txt' "$file" || fail "SOPS override missing from $file"
  grep -Fxq "RCLONE_CONFIG=$ETC_DIR/rclone.conf" "$file" || fail "RCLONE_CONFIG override missing from $file"
  [[ "$(stat -c '%U:%G %a' "$file")" == 'root:root 600' ]] || fail "$file is not root:root 600"
done
! grep -Fxq 'SOPS_AGE_KEY_FILE=/etc/vaultwarden/age-key.txt' "$TEST_REPO/.env" || fail 'repo .env was modified with SOPS override'
! grep -Fq "RCLONE_CONFIG=$ETC_DIR/rclone.conf" "$TEST_REPO/.env" || fail 'repo .env was modified with RCLONE override'
pass 'sync-env syncs normal config and keeps runtime-only overrides out of repo .env'

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
( cd "$TEST_REPO" && VW_SYNC_ETC_DIR="$ETC_DIR" ./utilities/sync-env.sh >/tmp/sync-env-test.out )
! grep -Fxq "RCLONE_CONFIG=$ETC_DIR/rclone.conf" "$STATE_DIR/config/install.env" || fail 'sync-env invented RCLONE_CONFIG when rclone.conf was absent'
! grep -Fxq "RCLONE_CONFIG=$ETC_DIR/rclone.conf" "$ETC_DIR/vaultwarden.env" || fail 'sync-env installed invented RCLONE_CONFIG when rclone.conf was absent'
pass 'sync-env does not invent canonical RCLONE_CONFIG when rclone.conf is absent'
