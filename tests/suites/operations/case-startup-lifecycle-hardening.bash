#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/test-root.bash
source "${SCRIPT_DIR}/../../lib/test-root.bash"
ROOT="${VW_TEST_REPO_ROOT:?VW_TEST_REPO_ROOT was not initialized}"

fail() {
  printf 'FAIL startup lifecycle hardening: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$label"
}

startup=$(<"${ROOT}/startup.sh")

restart_block=$(awk '
  /^restart:/ { capture=1 }
  capture && /^safe-restart:/ { exit }
  capture { print }
' "${ROOT}/Makefile")

assert_contains "$restart_block" '$(call check-docker)' \
  "restart must verify Docker availability"
assert_contains "$restart_block" './startup.sh --force --skip-pull' \
  "restart must recreate containers without pulling images"
assert_not_contains "$restart_block" './startup.sh --force ||' \
  "restart must not use the image-pulling startup path"

assert_not_contains "$startup" 'docker compose rm -sf' \
  "startup must not remove working containers before Compose recreation"
assert_contains "$startup" 'compose_args+=(--force-recreate)' \
  "forced restart must still request Compose recreation"
assert_not_contains "$startup" 'cleanup_docker_system || true' \
  "cleanup failures must not be silently discarded"
assert_contains "$startup" 'if cleanup_docker_system; then' \
  "cleanup result must be checked"
assert_contains "$startup" 'Orphaned resource cleanup failed; startup will continue' \
  "cleanup failure must be reported"
assert_contains "$startup" '_maybe_sudo "$_fw_script" --phase iptables </dev/null' \
  "startup firewall reconciliation must be noninteractive"
assert_not_contains "$startup" 'wait_for_services || true' \
  "critical readiness failures must not be discarded"
assert_contains "$startup" 'wait_for_services || readiness_rc=$?' \
  "critical readiness result must be preserved"
assert_contains "$startup" 'wait_for_optional_service_health()' \
  "optional service health helper must exist"
assert_contains "$startup" 'wait_for_optional_services || true' \
  "Postfix readiness must receive a nonfatal grace period"

postfix_health=$(awk '
  /postfix status/ { capture=1; remaining=7 }
  capture && remaining > 0 { print; remaining-- }
' "${ROOT}/docker-compose.yml.example")
assert_contains "$postfix_health" 'interval: 15s' \
  "Postfix health interval must support startup readiness"
assert_contains "$postfix_health" 'timeout: 5s' \
  "Postfix health timeout must be bounded"
assert_contains "$postfix_health" 'retries: 4' \
  "Postfix health retries must be bounded"
assert_contains "$postfix_health" 'start_period: 20s' \
  "Postfix health start period must match the readiness grace window"

bash -n "${ROOT}/startup.sh" || fail "startup.sh must pass Bash syntax validation"

printf 'PASS startup lifecycle hardening contracts\n'
