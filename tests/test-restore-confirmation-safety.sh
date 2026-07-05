#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESTORE="$ROOT/utilities/restore-run.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require() {
  grep -Eq -- "$1" "$2" || fail "$3"
}

reject_function() {
  local func="$1" pattern="$2" message="$3"
  ! awk -v fname="$func" -v pat="$pattern" '
    BEGIN { func_re = "^" fname "[(][)]" }
    $0 ~ func_re { in_func=1 }
    in_func && $0 ~ pat { found=1 }
    in_func && /^}/ { in_func=0 }
    END { exit found ? 0 : 1 }
  ' "$RESTORE" || fail "$message"
}

require 'RESTORE_PREVENT_AUTOSTART=false' "$RESTORE" \
  "restore must have a local flag that prevents automatic startup after prompt loss"
require 'RESTORE_PROMPT_TIMEOUT' "$RESTORE" \
  "restore confirmation prompts must use configurable bounded timeout"
require 'RESTORE_SAVED_ACK_ATTEMPTS' "$RESTORE" \
  "SAVED acknowledgement must have bounded retries"
require 'timeout/EOF is not treated as '\''no'\''' "$RESTORE" \
  "Age rotation timeout/EOF guidance must be explicit"
require '_restore_print_key_ack_abort_guidance' "$RESTORE" \
  "SAVED timeout/EOF must print manual key/startup guidance"
require 'Automatic service startup is disabled' "$RESTORE" \
  "restore safety net must honor prompt-loss no-autostart flag"
reject_function '_restore_should_rotate_age_key' 'answer="no"' \
  "Age rotation decision must not map timeout/EOF to no"
reject_function '_display_new_key' 'while \[\[ "\$_confirm" != "SAVED" \]\]' \
  "SAVED acknowledgement must not loop indefinitely"
require 'RESTORE_SAVED_ACK_TIMEOUT.*Type SAVED' "$RESTORE" \
  "SAVED acknowledgement must use bounded timeout"

printf 'PASS: restore confirmation safety\n'
