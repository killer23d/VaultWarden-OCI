#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEALTH="$ROOT/utilities/maintenance-health.sh"
CONFIG="$ROOT/lib/config.sh"
UNIT="$ROOT/systemd/vaultwarden-health.service"

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

require '_acquire_readonly_health_lock' "$HEALTH" \
  "read-only health must use direct health-specific flock"
reject '--no-global' "$HEALTH" \
  "read-only health must not use operation_acquire --no-global"
require '--id health-repair' "$HEALTH" \
  "health --fix must use the global health-repair operation"
require 'return "\$lock_rc"' "$HEALTH" \
  "health lock acquisition failures must preserve their real status"
require 'health --fix requires root' "$HEALTH" \
  "health repair mode must remain root-operated"
require 'return 4' "$HEALTH" \
  "health --fix guard infrastructure failures must be real failures"
reject 'maintenance-health\.sh must be run as root' "$CONFIG" \
  "config loading must not block documented non-root read-only health"
require '^SuccessExitStatus=0 1 3 75$' "$UNIT" \
  "health unit must treat expected contention 75 as success, but not all failures"

printf 'PASS: health operation contract\n'
