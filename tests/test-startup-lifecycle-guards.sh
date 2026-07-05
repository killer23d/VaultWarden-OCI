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

STARTUP="$ROOT/startup.sh"
SAFE_RESTART="$ROOT/utilities/safe-restart.sh"
MAKEFILE="$ROOT/Makefile"
STARTUP_UNIT="$ROOT/systemd/vaultwarden-startup.service"

require 'source "\$\{SCRIPT_DIR\}/lib/operations\.sh"' "$STARTUP" \
  "startup.sh must source the operation guard library"
require '--id startup' "$STARTUP" "startup.sh must use the startup operation id"
require '--specific-lock /run/lock/vaultwarden-startup\.lock' "$STARTUP" \
  "startup.sh must use the lifecycle-specific lock"
require 'utilities/env-edit\.sh" sync' "$STARTUP" \
  "startup.sh must run env sync inside the lifecycle operation"

awk '
  /_startup_acquire_operation_guard/ { guard=NR }
  /if \[\[ "\$DO_DOWN" == "true" \]\]/ { stop=NR }
  END { exit !(guard && stop && guard < stop) }
' "$STARTUP" || fail "startup stop path must acquire guard before docker compose down"

awk '
  /^up: /,/^start:/ {
    if (/\$\(MAKE\) sync-env/) bad=1
    if (/\.\/startup\.sh/) startup=1
  }
  END { exit !(startup && !bad) }
' "$MAKEFILE" || fail "make up must not run env sync before guarded startup.sh"

awk '
  /^restart: /,/^safe-restart:/ {
    if (/\$\(MAKE\) sync-env/) bad=1
    if (/\.\/startup\.sh --force/) startup=1
  }
  END { exit !(startup && !bad) }
' "$MAKEFILE" || fail "make restart must not run env sync before guarded startup.sh"

awk '
  /^down: /,/^stop:/ { if (/\.\/startup\.sh stop/) found=1 }
  END { exit !found }
' "$MAKEFILE" || fail "make down must route through guarded startup.sh stop"

require 'source "\$\{PROJECT_ROOT\}/lib/operations\.sh"' "$SAFE_RESTART" \
  "safe-restart must source operation guards"
require '--id startup' "$SAFE_RESTART" "safe-restart must hold the lifecycle global operation"
require 'operation_set_phase "rollback"' "$SAFE_RESTART" \
  "safe-restart rollback must remain inside the operation scope"
reject '--specific-lock /run/lock/vaultwarden-startup\.lock' "$SAFE_RESTART" \
  "safe-restart parent must not hold the startup-specific lock before nested startup.sh"

require '^SuccessExitStatus=0 75$' "$STARTUP_UNIT" \
  "startup systemd unit must treat contention exit 75 as success"
require '^ReadWritePaths=.*@PROJECT_STATE_DIR@' "$STARTUP_UNIT" \
  "startup systemd unit must expose project state path"
require '^ReadWritePaths=.*/etc/vaultwarden' "$STARTUP_UNIT" \
  "startup systemd unit must expose runtime env path"
require '^ReadWritePaths=.*/run/lock' "$STARTUP_UNIT" \
  "startup systemd unit must expose operation lock path"
require '^ReadWritePaths=.*/run/vaultwarden-oci' "$STARTUP_UNIT" \
  "startup systemd unit must expose operation state path"
require '^RuntimeDirectory=vaultwarden-oci$' "$STARTUP_UNIT" \
  "startup systemd unit must pre-create /run/vaultwarden-oci"

printf 'PASS: startup lifecycle operation guards\n'
