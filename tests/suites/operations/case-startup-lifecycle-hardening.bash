#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$SCRIPT_DIR"
# shellcheck source=../../lib/test-root.bash
source "${SCRIPT_DIR}/../../lib/test-root.bash"
ROOT="${VW_TEST_REPO_ROOT:?VW_TEST_REPO_ROOT was not initialized}"

fail() {
  printf 'FAIL startup lifecycle hardening: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label"
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$label"
}

extract_func() {
  local _entrypoint="$1" func="$2"
  local -a files=("$ROOT/startup.sh")
  if compgen -G "$ROOT/lib/startup-*.sh" >/dev/null; then
    files+=("$ROOT"/lib/startup-*.sh)
  fi
  awk -v f="$func" '
    $0 ~ "^" f "\\(\\)" { capture=1 }
    capture {
      print
      opens=gsub(/\{/ ,"{")
      closes=gsub(/\}/ ,"}")
      depth += opens - closes
      if (depth == 0) exit
    }
  ' "${files[@]}"
}

startup="$(cat "${ROOT}/startup.sh")"
if compgen -G "${ROOT}/lib/startup-*.sh" >/dev/null; then
  startup+=$'\n'"$(cat "${ROOT}"/lib/startup-*.sh)"
fi
restart_block=$(awk '
  /^restart:/ { capture=1 }
  capture && /^safe-restart:/ { exit }
  capture { print }
' "${ROOT}/Makefile")

assert_contains "$restart_block" '$(call check-docker)' \
  "restart must verify Docker availability"
assert_contains "$restart_block" './startup.sh --force --skip-pull' \
  "restart compatibility command must remain accepted"
assert_not_contains "$startup" 'docker compose rm -sf' \
  "startup must not remove working containers before Compose recreation"
assert_contains "$startup" 'compose_args+=(--force-recreate)' \
  "forced restart must still request Compose recreation"
assert_contains "$startup" '--pull never' \
  "ordinary startup must enforce a no-pull Compose policy"
assert_not_contains "$startup" 'docker compose pull --quiet' \
  "ordinary startup must not contain an image-pull operation"
assert_not_contains "$startup" '--remove-orphans' \
  "ordinary Compose startup must not delete orphan containers"
assert_contains "$startup" 'REPAIR=false' \
  "startup must expose an explicit repair mode"
assert_contains "$startup" 'repair_critical_permissions || exit 1' \
  "permission repair failure must stop startup"
assert_contains "$startup" 'reconcile_managed_orphans || exit 1' \
  "managed orphan repair failure must stop startup"
assert_contains "$startup" 'repair_vaultwarden_egress_nat || exit 1' \
  "NAT repair failure must stop startup"
assert_contains "$startup" 'repair_dns_state || exit 1' \
  "DNS repair failure must stop startup"
assert_not_contains "$startup" 'cleanup_docker_system' \
  "startup must not call broad Docker cleanup"
assert_not_contains "$startup" '_startup_pull_images()' \
  "startup must not retain an implicit pull helper"
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
KEY_FIXTURE="$TMP/key-fixture"
mkdir -p "$KEY_FIXTURE/secrets/keys"
printf 'synthetic repository key\n' > "$KEY_FIXTURE/secrets/keys/age-key.txt"
SCRIPT_DIR="$KEY_FIXTURE"
SOPS_AGE_KEY_FILE="$TMP/rejected-configured-key.txt"
export SCRIPT_DIR SOPS_AGE_KEY_FILE
DRY_RUN=false
DOCKER_SECRETS_DIR="$TMP/runtime-secrets"
LOG_FILE="$TMP/key-log"
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
SECRETS_FILE="$TMP/secrets.yaml"
eval "$(extract_func "$ROOT/startup.sh" prepare_docker_secrets)"
if prepare_docker_secrets; then
  fail "Docker secret preparation succeeded after selected Age-key failure"
fi
[[ ! -e "$TMP/schema-called" && ! -e "$TMP/required-secrets-called" && ! -e "$TMP/sops-export-called" ]] \
  || fail "SOPS/schema/secret mutation ran after selected Age-key failure"

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


# Public-entrypoint behavioral fixture and cases are kept in non-case helpers so
# this registered case remains readable while the test runner sees one case.
source "${CASE_DIR}/startup-lifecycle-fixture-a.bash"
source "${CASE_DIR}/startup-lifecycle-fixture-b.bash"
source "${CASE_DIR}/startup-lifecycle-cases.bash"
