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

extract_func() {
  local file="$1" func="$2"
  awk -v f="$func" '
    $0 ~ "^" f "\\(\\)" { capture=1 }
    capture {
      print
      opens=gsub(/\{/,"{")
      closes=gsub(/\}/,"}")
      depth += opens - closes
      if (depth == 0) exit
    }
  ' "$file"
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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SCRIPT_DIR="$TMP/repo"
mkdir -p "$SCRIPT_DIR/secrets/keys"
printf 'synthetic repository key\n' > "$SCRIPT_DIR/secrets/keys/age-key.txt"
SOPS_AGE_KEY_FILE="$TMP/rejected-configured-key.txt"
export SCRIPT_DIR SOPS_AGE_KEY_FILE
# shellcheck disable=SC2034 # Consumed by the function extracted with eval below.
DRY_RUN=false
# shellcheck disable=SC2034 # Consumed by the function extracted with eval below.
DOCKER_SECRETS_DIR="$TMP/runtime-secrets"
LOG_FILE="$TMP/log"
CALL_FILE="$TMP/key-health-calls"
log_info(){ printf 'INFO %s\n' "$*" >> "$LOG_FILE"; }
log_warn(){ printf 'WARN %s\n' "$*" >> "$LOG_FILE"; }
log_error(){ printf 'ERROR %s\n' "$*" >> "$LOG_FILE"; }
log_success(){ printf 'SUCCESS %s\n' "$*" >> "$LOG_FILE"; }
check_age_key_health(){
  printf '%s\n' "${1:-}" >> "$CALL_FILE"
  [[ "${1:-}" == "$SCRIPT_DIR/secrets/keys/age-key.txt" ]]
}
eval "$(extract_func "$ROOT/startup.sh" check_age_key_health_preflight)"

if check_age_key_health_preflight; then
  fail "invalid configured Age key was replaced by healthy repository key"
fi
[[ "$SOPS_AGE_KEY_FILE" == "$TMP/rejected-configured-key.txt" ]] \
  || fail "failed key preflight changed the selected Age-key identity"
[[ "$(wc -l < "$CALL_FILE" | tr -d ' ')" == "1" ]] \
  || fail "failed key preflight evaluated a fallback identity"
grep -Fxq "$TMP/rejected-configured-key.txt" "$CALL_FILE" \
  || fail "failed key preflight did not evaluate the configured identity"

check_age_key_health_preflight(){ return 1; }
schema_validate(){ : > "$TMP/schema-called"; }
validate_required_secrets(){ : > "$TMP/required-secrets-called"; }
export_docker_secrets(){ : > "$TMP/sops-export-called"; }
# shellcheck disable=SC2034 # Consumed by the function extracted with eval below.
SECRETS_FILE="$TMP/secrets.yaml"
eval "$(extract_func "$ROOT/startup.sh" prepare_docker_secrets)"
if prepare_docker_secrets; then
  fail "Docker secret preparation succeeded after selected Age-key failure"
fi
[[ ! -e "$TMP/schema-called" && ! -e "$TMP/required-secrets-called" && ! -e "$TMP/sops-export-called" ]] \
  || fail "SOPS/schema/secret mutation ran after selected Age-key failure"

prepare_line="$(awk '/prepare_docker_secrets \|\| exit 1/{print NR; exit}' "$ROOT/startup.sh")"
early_key_line="$(awk '/check_age_key_health_preflight \|\| exit 1/{print NR; exit}' "$ROOT/startup.sh")"
permission_line="$(awk '/if ! auto_fix_critical_permissions/{print NR; exit}' "$ROOT/startup.sh")"
firewall_line="$(awk '/ensure_vaultwarden_egress_nat \|\| true/{print NR; exit}' "$ROOT/startup.sh")"
pull_line="$(awk '/_startup_pull_images \|\| exit 1/{print NR; exit}' "$ROOT/startup.sh")"
start_line="$(awk '/_startup_start_services \|\| exit 1/{print NR; exit}' "$ROOT/startup.sh")"
[[ -n "$early_key_line" && "$early_key_line" -lt "$permission_line" ]] \
  || fail "selected Age-key rejection no longer precedes startup permission/state mutation"
[[ -n "$prepare_line" && "$prepare_line" -lt "$firewall_line" \
   && "$prepare_line" -lt "$pull_line" && "$prepare_line" -lt "$start_line" ]] \
  || fail "Age-key/SOPS gate no longer precedes network, image-pull, and service mutations"

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
