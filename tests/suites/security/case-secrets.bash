#!/usr/bin/env bash
# Consolidated secrets regression suite.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

check_secrets_cli_help() (
# Verify standalone secrets informational options need no project configuration.

set -euo pipefail

PROJECT_ROOT="$VW_TEST_REPO_ROOT"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

ISOLATED_ROOT="${TEST_ROOT}/project"
TEST_HOME="${TEST_ROOT}/home"
RUN_DIR="${TEST_ROOT}/run"
mkdir -p "${ISOLATED_ROOT}/utilities" "$TEST_HOME" "$RUN_DIR"
cp -R "${PROJECT_ROOT}/lib" "$ISOLATED_ROOT/"
cp "${PROJECT_ROOT}/VERSION" "$ISOLATED_ROOT/"
cp "${PROJECT_ROOT}/edit-secrets.sh" "$ISOLATED_ROOT/"
for script in \
    secrets-view.sh \
    secrets-list.sh \
    secrets-rotate.sh \
    secrets-export-recovery-kit.sh \
    secrets-edit.sh; do
    cp "${PROJECT_ROOT}/utilities/${script}" "${ISOLATED_ROOT}/utilities/"
done

run_clean() {
    (
        cd "$RUN_DIR"
        # Keep the environment isolated while allowing macOS developers to
        # use Homebrew Bash 4+ instead of the system Bash 3.2.
        env -i \
            PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
            HOME="$TEST_HOME" \
            bash "$@"
    ) 2>&1
}

assert_no_initialization_error() {
    local output="$1"
    local rejected
    for rejected in \
        "No project environment found" \
        "Environment file not found" \
        "Missing prerequisites" \
        "Age encryption key" \
        "SOPS configuration" \
        "This script must be run as root"; do
        [[ "$output" != *"$rejected"* ]] ||
            fail "informational output contained initialization error: $rejected"
    done
}

assert_help() {
    local script="$1"
    local heading="$2"
    shift 2

    local output
    if [[ "$script" == edit-secrets.sh ]]; then
        output="$(run_clean "${ISOLATED_ROOT}/${script}" "$@")" ||
            fail "${script} $* exited non-zero"
    else
        output="$(run_clean "${ISOLATED_ROOT}/utilities/${script}" "$@")" ||
            fail "${script} $* exited non-zero"
    fi
    [[ -n "$output" ]] || fail "${script} $* produced no output"
    [[ "$output" == *"$heading"* ]] || fail "${script} $* omitted heading: $heading"
    [[ "$output" == *"USAGE:"* ]] || fail "${script} $* omitted USAGE"
    assert_no_initialization_error "$output"
    [[ "$output" == *"sudo ./edit-secrets.sh"* || "$script" == secrets-list.sh ]] || fail "${script} help lacks sudo edit-secrets examples"
}

assert_version() {
    local script="$1"
    local option="$2"
    local expected output
    expected="VaultWarden-OCI $(tr -d '[:space:]' < "${ISOLATED_ROOT}/VERSION")"
    if [[ "$script" == edit-secrets.sh ]]; then
        output="$(run_clean "${ISOLATED_ROOT}/${script}" "$option")" ||
            fail "${script} $option exited non-zero"
    else
        output="$(run_clean "${ISOLATED_ROOT}/utilities/${script}" "$option")" ||
            fail "${script} $option exited non-zero"
    fi
    [[ -n "$output" ]] || fail "${script} $option produced no output"
    [[ "$output" == "$expected" ]] ||
        fail "${script} $option output '$output', expected '$expected'"
    assert_no_initialization_error "$output"
}

assert_wrapper_subcommand_version() {
    local subcommand="$1"
    local option="$2"
    local expected output
    expected="VaultWarden-OCI $(tr -d '[:space:]' < "${ISOLATED_ROOT}/VERSION")"
    output="$(run_clean "${ISOLATED_ROOT}/edit-secrets.sh" "$subcommand" "$option")" ||
        fail "edit-secrets.sh $subcommand $option exited non-zero"
    [[ "$output" == "$expected" ]] ||
        fail "edit-secrets.sh $subcommand $option output '$output', expected '$expected'"
    assert_no_initialization_error "$output"
}

assert_failure_contains() {
    local expected="$1"
    shift
    local output status
    set +e
    output="$(run_clean "$@")"
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "$* unexpectedly succeeded"
    [[ "$output" == *"$expected"* ]] || fail "$* output missing '$expected': $output"
    assert_no_initialization_error "$output"
}

for option in --help -h; do
    assert_help secrets-view.sh "VaultWarden Secrets — view subcommand" "$option"
    assert_help secrets-list.sh "VaultWarden Secrets — list subcommand" "$option"
    assert_help secrets-rotate.sh "VaultWarden Secrets — rotate subcommand" "$option"
    assert_help secrets-export-recovery-kit.sh \
        "VaultWarden Secrets — export-recovery-kit subcommand" "$option"
    assert_help secrets-edit.sh "VaultWarden Secrets — edit subcommand" "$option"
    assert_help edit-secrets.sh "VaultWarden-OCI Secrets Editor" "$option"
done

assert_help secrets-view.sh "VaultWarden Secrets — view subcommand" view --help
assert_help secrets-list.sh "VaultWarden Secrets — list subcommand" list --help
assert_help secrets-rotate.sh "VaultWarden Secrets — rotate subcommand" rotate --help
assert_help secrets-export-recovery-kit.sh \
    "VaultWarden Secrets — export-recovery-kit subcommand" export-recovery-kit --help
assert_help secrets-edit.sh "VaultWarden Secrets — edit subcommand" edit --help
assert_help edit-secrets.sh "VaultWarden-OCI Secrets Editor" help

for option in --version -V; do
    assert_version secrets-view.sh "$option"
    assert_version secrets-list.sh "$option"
    assert_version secrets-rotate.sh "$option"
    assert_version secrets-export-recovery-kit.sh "$option"
    assert_version secrets-edit.sh "$option"
    assert_version edit-secrets.sh "$option"
    assert_wrapper_subcommand_version edit "$option"
    assert_wrapper_subcommand_version view "$option"
    assert_wrapper_subcommand_version list "$option"
    assert_wrapper_subcommand_version rotate "$option"
    assert_wrapper_subcommand_version export-recovery-kit "$option"
done

assert_failure_contains "Unknown option: '--bogus'" "${ISOLATED_ROOT}/utilities/secrets-list.sh" --bogus
assert_failure_contains "Unknown option: '--bogus'" "${ISOLATED_ROOT}/utilities/secrets-export-recovery-kit.sh" --bogus
assert_failure_contains "Unknown option: '--bogus'" "${ISOLATED_ROOT}/utilities/secrets-edit.sh" edit --bogus
assert_failure_contains "'rotate' requires a FIELD argument" "${ISOLATED_ROOT}/utilities/secrets-rotate.sh" --dry-run
assert_failure_contains "--editor requires an argument" "${ISOLATED_ROOT}/utilities/secrets-edit.sh" --editor --help

backup_load_line="$(awk '/load_project_environment \|\| exit 1/{print NR; exit}' "${PROJECT_ROOT}/utilities/backup-run.sh")"
backup_parse_line="$(awk '/^case "\$1" in/{print NR; exit}' "${PROJECT_ROOT}/utilities/backup-run.sh")"
[[ -z "$backup_load_line" ]] || fail "backup-run.sh should not load production project environment before help/version parsing"
[[ -n "$backup_parse_line" ]] || fail "backup-run.sh help/version parser not found"

printf 'Standalone secrets CLI help tests passed.\n'

)

check_secrets_cli_help
check_schema_dependency_contracts() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

command -v yq >/dev/null 2>&1 || fail "yq is required for schema dependency tests"
yq_version="$(yq --version 2>&1)"
[[ "$yq_version" == *"mikefarah/yq"* && "$yq_version" =~ version[[:space:]]v?4\. ]] \
    || fail "tests must run with Mike Farah yq v4, got: $yq_version"

# shellcheck source=../lib/log.sh
source "$ROOT/lib/log.sh"
# shellcheck source=../lib/schema.sh
source "$ROOT/lib/schema.sh"

schema_keys >/dev/null || fail "schema_keys did not accept Mike Farah yq v4"
[[ "$(schema_field cloudflare_zone_id conditional_group)" == "cloudflare_proxy" ]] \
    || fail "schema_field raw output/schema query behavior failed"

cf_keys="$(yq -r '.secrets[] | select(.conditional_group == "cloudflare_proxy") | .key' "$ROOT/secrets-schema.yaml")" \
    || fail "Cloudflare conditional schema query failed"
[[ "$cf_keys" == *"cloudflare_zone_id"* ]] || fail "Cloudflare conditional keys missing cloudflare_zone_id"
[[ "$cf_keys" == *"cf_account_id"* ]] || fail "Cloudflare conditional keys missing cf_account_id"
[[ "$cf_keys" == *"cf_worker_bouncer_token"* ]] || fail "Cloudflare conditional keys missing cf_worker_bouncer_token"
[[ "$cf_keys" != *'"'* ]] || fail "Cloudflare conditional schema keys must be bare shell key names"

[[ "$(schema_apply_type_for_key admin_basic_auth_hash)" == "compose_restart" ]] \
    || fail "admin_basic_auth_hash apply type missing"
[[ "$(schema_apply_targets_for_key admin_basic_auth_hash)" == "caddy" ]] \
    || fail "admin_basic_auth_hash must apply to caddy"
[[ "$(schema_apply_targets_for_key smtp_password)" == "postfix" ]] \
    || fail "smtp_password must apply to postfix"
[[ "$(schema_apply_type_for_key email_api_token)" == "none" ]] \
    || fail "email_api_token must require no restart"
[[ "$(schema_apply_type_for_key cf_worker_bouncer_token)" == "crowdsec_worker_config" ]] \
    || fail "CrowdSec worker token must use the narrow config apply action"
[[ -z "$(schema_services_for_key cf_worker_bouncer_token)" ]] \
    || fail "systemd/CrowdSec apply targets must not be exposed as compose services"
! yq -e '.secrets[] | select(.key == "backup_passphrase")' "$ROOT/secrets-schema.yaml" >/dev/null \
    || fail "backup_passphrase must be retired from active schema"
grep -Fq 'legacy_keys = {"backup_passphrase"}' "$ROOT/lib/secrets.sh" \
    || fail "legacy backup_passphrase must remain manageable in existing secrets files"

grep -Fq 'schema_keys_for_conditional_group "cloudflare_proxy"' "$ROOT/lib/secrets.sh" \
    || fail "validate_required_secrets must use the schema conditional-group accessor"

write_minimal_schema() {
    local file="$1"
    local hash="${2:-plain}"
    local collect="${3:-interactive}"
    local auto_fn="${4:-}"
    local condition_fn="${5:-}"
    local apply_type="${6:-none}"
    local target_block="${7:-[]}"
    cat > "$file" <<SCHEMA
schema_version: 1
secrets:
  - key: admin_token
    label: "Admin"
    hash: ${hash}
    placeholder: "PLACEHOLDER_NOT_CONFIGURED"
    collect: ${collect}
    auto_fn: "${auto_fn}"
    condition_fn: "${condition_fn}"
    apply:
      type: ${apply_type}
      targets: ${target_block}
    required: false
    hint: ""
SCHEMA
}

write_single_key_schema() {
    local file="$1"
    local key="$2"
    local hash="$3"
    cat > "$file" <<SCHEMA
schema_version: 1
secrets:
  - key: ${key}
    label: "Test"
    hash: ${hash}
    placeholder: "PLACEHOLDER_NOT_CONFIGURED"
    collect: interactive
    auto_fn: ""
    condition_fn: ""
    apply:
      type: none
      targets: []
    required: false
    hint: ""
SCHEMA
}

expect_schema_invalid() {
    local file="$1"
    local expected="$2"
    local output status
    set +e
    output="$(schema_keys "$file" 2>&1)"
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "invalid schema unexpectedly passed: $file"
    [[ "$output" == *"$expected"* ]] || fail "invalid schema output missing '$expected': $output"
}

dup_schema="$TMP/duplicate-key.yaml"
cat > "$dup_schema" <<'SCHEMA'
schema_version: 1
secrets:
  - key: admin_token
    label: "Admin"
    hash: plain
    placeholder: "PLACEHOLDER_NOT_CONFIGURED"
    collect: interactive
    auto_fn: ""
    apply:
      type: none
      targets: []
    required: false
    hint: ""
  - key: admin_token
    label: "Admin duplicate"
    hash: plain
    placeholder: "PLACEHOLDER_NOT_CONFIGURED"
    collect: interactive
    auto_fn: ""
    apply:
      type: none
      targets: []
    required: false
    hint: ""
SCHEMA
expect_schema_invalid "$dup_schema" "admin_token.key: must be unique"

bad_collect="$TMP/bad-collect.yaml"; write_minimal_schema "$bad_collect" plain "sometimes"
expect_schema_invalid "$bad_collect" "admin_token.collect"
bad_hash="$TMP/bad-hash.yaml"; write_minimal_schema "$bad_hash" "sha512"
expect_schema_invalid "$bad_hash" "admin_token.hash"
bad_admin_token_hash="$TMP/bad-admin-token-hash.yaml"; write_minimal_schema "$bad_admin_token_hash" "plain"
expect_schema_invalid "$bad_admin_token_hash" "admin_token.hash: implemented transform requires 'argon2id'"
bad_admin_basic_hash="$TMP/bad-admin-basic-hash.yaml"; write_single_key_schema "$bad_admin_basic_hash" "admin_basic_auth_hash" "plain"
expect_schema_invalid "$bad_admin_basic_hash" "admin_basic_auth_hash.hash: implemented transform requires 'bcrypt'"
bad_smtp_hash="$TMP/bad-smtp-hash.yaml"; write_single_key_schema "$bad_smtp_hash" "smtp_password" "bcrypt"
expect_schema_invalid "$bad_smtp_hash" "smtp_password.hash: 'bcrypt' has no implemented transform for this key"
bad_apply="$TMP/bad-apply.yaml"; write_minimal_schema "$bad_apply" plain interactive "" "" "webhook"
expect_schema_invalid "$bad_apply" "admin_token.apply.type"
bad_auto="$TMP/bad-auto.yaml"; write_minimal_schema "$bad_auto" plain auto ""
expect_schema_invalid "$bad_auto" "admin_token.auto_fn"
bad_cond="$TMP/bad-condition.yaml"; write_minimal_schema "$bad_cond" plain conditional "" ""
expect_schema_invalid "$bad_cond" "admin_token.condition_fn"

grep -Fq "collect_secrets: no collection handler for schema key" "$ROOT/utilities/setup-secrets.sh" \
    || fail "setup collection must fail on unhandled schema keys"
grep -Fq "schema key '\${_wkey}' has no collected/generated value" "$ROOT/utilities/setup-secrets.sh" \
    || fail "write_secrets must fail instead of writing empty missing values"
grep -Fq 'validate_plaintext_secrets_schema_contract "$temp_file"' "$ROOT/utilities/secrets-edit.sh" \
    || fail "raw secrets edit must validate plaintext against schema before promotion"
grep -Fq 'export_docker_secrets "$docker_dir" "$SECRETS_FILE"' "$ROOT/utilities/secrets-edit.sh" \
    || fail "raw secrets edit must reconcile runtime secrets after promotion"
grep -Fq 'prepare_push_secret_placeholders "$docker_dir"' "$ROOT/utilities/secrets-edit.sh" \
    || fail "raw secrets edit must preserve push placeholder behavior"
grep -Fq 'No plaintext values were printed; changes were detected by fingerprints.' "$ROOT/utilities/secrets-edit.sh" \
    || fail "raw secrets edit changed-key reporting must avoid plaintext values"
grep -Fq 'schema_validate || return 1' "$ROOT/startup.sh" \
    || fail "startup must validate schema once before schema-heavy secret checks"
grep -Fq 'validate_required_secrets "$SECRETS_FILE" || return 1' "$ROOT/startup.sh" \
    || fail "startup must use validate_required_secrets as the strict required-secret gate"
startup_secret_block="$(awk '/prepare_docker_secrets\(\)/,/^}/' "$ROOT/startup.sh")"
[[ "$startup_secret_block" != *'check_placeholder_values "$SECRETS_FILE"'* ]] \
    || fail "startup should not run duplicate required-secret placeholder validation"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/yq" <<'PYTHON_YQ'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    printf 'yq 3.1.0\n'
    exit 0
fi
exit 1
PYTHON_YQ
chmod +x "$TMP/bin/yq"
if PATH="$TMP/bin:/usr/bin:/bin" bash -c '
    set -euo pipefail
    cd "$1"
    source lib/log.sh
    source lib/schema.sh
    schema_keys >/dev/null
' _ "$ROOT" >/tmp/vw-wrong-yq.$$ 2>&1; then
    rm -f /tmp/vw-wrong-yq.$$
    fail "schema library accepted python-yq compatibility shim"
fi
grep -Fq "Mike Farah yq v4 is required" /tmp/vw-wrong-yq.$$ \
    || fail "wrong-yq failure did not name the Mike Farah v4 requirement"
rm -f /tmp/vw-wrong-yq.$$

cat > "$TMP/bin/yq" <<'V3_YQ'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    printf 'yq (https://github.com/mikefarah/yq/) version v3.4.1\n'
    exit 0
fi
exit 1
V3_YQ
chmod +x "$TMP/bin/yq"
if PATH="$TMP/bin:/usr/bin:/bin" bash -c '
    set -euo pipefail
    cd "$1"
    source lib/log.sh
    source lib/schema.sh
    schema_keys >/dev/null
' _ "$ROOT" >/tmp/vw-wrong-yq-major.$$ 2>&1; then
    rm -f /tmp/vw-wrong-yq-major.$$
    fail "schema library accepted wrong Mike Farah yq major version"
fi
rm -f /tmp/vw-wrong-yq-major.$$

printf 'Schema dependency contract tests passed.\n'
)

check_schema_dependency_contracts

check_crowdsec_worker_post_edit_apply() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

sed -n '/^_changed_keys_require_crowdsec_worker_config()/,/^# Interactively edit secrets/p' \
    "$ROOT/utilities/secrets-edit.sh" > "$TMP/post-edit-apply-functions.sh"
# shellcheck source=/dev/null
source "$TMP/post-edit-apply-functions.sh"

schema_key_exists() { [[ "$1" != "unknown_key" ]]; }
schema_apply_type_for_key() {
    case "$1" in
        custom_worker_credential|another_worker_credential) printf 'crowdsec_worker_config\n' ;;
        *) printf 'none\n' ;;
    esac
}
log_info() { printf 'INFO: %s\n' "$*"; }
log_warn() { printf 'WARN: %s\n' "$*"; }
log_error() { printf 'ERROR: %s\n' "$*"; }
log_success() { printf 'SUCCESS: %s\n' "$*"; }

apply_calls=0
crowdsec_worker_apply_config() {
    [[ "$1" == "--require-service" ]] || fail "CrowdSec apply helper did not receive --require-service"
    apply_calls=$((apply_calls + 1))
    return "${MOCK_APPLY_STATUS:-0}"
}

CLOUDFLARE_PROXY_ENABLED=true \
    _offer_crowdsec_worker_config_apply custom_worker_credential another_worker_credential \
    <<< "yes" >"$TMP/yes.out" 2>&1 || fail "yes apply offer failed"
[[ "$apply_calls" -eq 1 ]] || fail "multiple CrowdSec worker keys did not produce exactly one apply"
grep -Fq 'CrowdSec Workers credentials changed.' "$TMP/yes.out" \
    || fail "CrowdSec worker credential change did not select offer path"

apply_calls=0
CLOUDFLARE_PROXY_ENABLED=false \
    _offer_crowdsec_worker_config_apply custom_worker_credential \
    <<< "yes" >"$TMP/disabled.out" 2>&1 || fail "disabled Cloudflare proxy must preserve successful secrets edit"
[[ "$apply_calls" -eq 0 ]] || fail "disabled Cloudflare proxy invoked CrowdSec worker apply helper"
grep -Fq 'CrowdSec Workers config apply skipped: CLOUDFLARE_PROXY_ENABLED is not true.' "$TMP/disabled.out" \
    || fail "disabled Cloudflare proxy did not report skipped apply"
grep -Fq 'no active Worker consumer was re-rendered or service-verified' "$TMP/disabled.out" \
    || fail "disabled Cloudflare proxy did not describe unapplied Worker state"
if grep -Fq 'CrowdSec Cloudflare Worker bouncer config applied successfully.' "$TMP/disabled.out"; then
    fail "disabled Cloudflare proxy falsely reported successful apply"
fi

apply_calls=0
_offer_crowdsec_worker_config_apply custom_worker_credential \
    <<< "no" >"$TMP/no.out" 2>&1 || fail "no response must preserve successful secrets edit"
[[ "$apply_calls" -eq 0 ]] || fail "no response invoked CrowdSec worker apply helper"
grep -Fq 'sudo ./utilities/crowdsec-worker-apply.sh' "$TMP/no.out" \
    || fail "no response omitted CrowdSec worker apply retry command"

apply_calls=0
_offer_crowdsec_worker_config_apply custom_worker_credential \
    </dev/null >"$TMP/eof.out" 2>&1 || fail "EOF must preserve successful secrets edit"
[[ "$apply_calls" -eq 0 ]] || fail "EOF invoked CrowdSec worker apply helper"
grep -Fq 'sudo ./utilities/crowdsec-worker-apply.sh' "$TMP/eof.out" \
    || fail "EOF omitted CrowdSec worker apply retry command"

apply_calls=0
read() { return 1; }
_offer_crowdsec_worker_config_apply custom_worker_credential \
    >"$TMP/timeout.out" 2>&1 || fail "timeout must preserve successful secrets edit"
unset -f read
[[ "$apply_calls" -eq 0 ]] || fail "timeout invoked CrowdSec worker apply helper"
grep -Fq 'sudo ./utilities/crowdsec-worker-apply.sh' "$TMP/timeout.out" \
    || fail "timeout omitted CrowdSec worker apply retry command"

apply_calls=0
_offer_crowdsec_worker_config_apply custom_worker_credential \
    <<< "y" >"$TMP/invalid.out" 2>&1 || fail "invalid response must preserve successful secrets edit"
[[ "$apply_calls" -eq 0 ]] || fail "invalid response invoked CrowdSec worker apply helper"
grep -Fq 'Invalid response; CrowdSec Workers config was not re-rendered.' "$TMP/invalid.out" \
    || fail "invalid response was not rejected"

apply_calls=0
if CLOUDFLARE_PROXY_ENABLED=true MOCK_APPLY_STATUS=1 \
    _offer_crowdsec_worker_config_apply custom_worker_credential \
    <<< "yes" >"$TMP/failure.out" 2>&1; then
    fail "CrowdSec worker apply failure must fail the edit command"
fi
[[ "$apply_calls" -eq 1 ]] || fail "failed CrowdSec worker apply was not attempted exactly once"
grep -Fq 'Secrets were updated, but CrowdSec Workers config apply failed.' "$TMP/failure.out" \
    || fail "apply failure did not describe promoted secrets state"
grep -Fq 'sudo ./utilities/crowdsec-worker-apply.sh' "$TMP/failure.out" \
    || fail "apply failure omitted CrowdSec worker apply retry command"

post_save_calls=0
_print_post_edit_apply_guidance() { :; }
offer_recovery_kit_export() { post_save_calls=$((post_save_calls + 1)); }
apply_calls=0
if CLOUDFLARE_PROXY_ENABLED=true MOCK_APPLY_STATUS=1 \
    _run_post_edit_workflows custom_worker_credential \
    <<< "yes" >"$TMP/post-save-failure.out" 2>&1; then
    fail "post-save workflow must retain CrowdSec worker apply failure"
fi
[[ "$apply_calls" -eq 1 ]] || fail "post-save workflow did not attempt failed CrowdSec worker apply"
[[ "$post_save_calls" -eq 1 ]] || fail "failed CrowdSec worker apply bypassed recovery kit offer"

apply_calls=0
_offer_crowdsec_worker_config_apply ordinary_secret unknown_key \
    >"$TMP/non-worker.out" 2>&1 || fail "non-worker change unexpectedly failed"
[[ "$apply_calls" -eq 0 ]] || fail "non-worker change invoked CrowdSec worker apply helper"
[[ ! -s "$TMP/non-worker.out" ]] || fail "non-worker change showed CrowdSec worker apply prompt"

grep -Fq 'read -r -t 30 -p "Re-render and apply CrowdSec Cloudflare Worker bouncer config? [yes/no]: "' \
    "$ROOT/utilities/secrets-edit.sh" \
    || fail "CrowdSec worker apply prompt contract must remain bounded to 30 seconds"

printf 'CrowdSec worker post-edit apply tests passed.\n'
)

check_crowdsec_worker_post_edit_apply

check_runtime_secret_reconciliation() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

mkdir -p "$TMP/bin" "$TMP/runtime"
cat > "$TMP/bin/sops" <<'SOPS'
#!/usr/bin/env bash
set -euo pipefail
target="${@: -1}"
if [[ "${1:-}" == "-d" || "${1:-}" == "--decrypt" ]]; then
    cat "$target"
    exit 0
fi
if [[ "${1:-}" == "--version" ]]; then
    printf 'sops mock\n'
    exit 0
fi
cat "$target"
SOPS
chmod +x "$TMP/bin/sops"

PATH="$TMP/bin:$PATH"
SECRETS_FILE="$TMP/secrets.yaml"
SECRETS_SCHEMA_FILE="$ROOT/secrets-schema.yaml"
PROJECT_ROOT="$ROOT"
export PATH SECRETS_FILE SECRETS_SCHEMA_FILE PROJECT_ROOT

# shellcheck source=../lib/log.sh
source "$ROOT/lib/log.sh"
# shellcheck source=../lib/config.sh
source "$ROOT/lib/config.sh"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/crypto.sh
source "$ROOT/lib/crypto.sh"
# shellcheck source=../lib/secrets.sh
source "$ROOT/lib/secrets.sh"

ensure_sops_env() { return 0; }
cleanup_secrets_environment() { return 0; }
_maybe_sudo() {
    local cmd="$1"; shift
    if [[ "$cmd" == "install" ]]; then
        local args=()
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -o|-g) shift 2 ;;
                *) args+=("$1"); shift ;;
            esac
        done
        command install "${args[@]}"
    elif [[ "$cmd" == "chown" ]]; then
        return 0
    else
        command "$cmd" "$@"
    fi
}
stat() {
    if [[ "${1:-}" == "-c" && "${2:-}" == "%u:%g" &&
          ( "${3:-}" == "$TMP/runtime"* || "${3:-}" == "$TMP/managed-secrets" ) ]]; then
        printf '0:0\n'
        return 0
    fi
    command stat "$@"
}

write_secret_yaml() {
    local smtp_value="$1"
    local push_id="${2:-CHANGE_ME_OR_LEAVE_EMPTY}"
    local push_key="${3:-CHANGE_ME_OR_LEAVE_EMPTY}"
    cat > "$SECRETS_FILE" <<YAML
smtp_password: "${smtp_value}"
push_installation_id: "${push_id}"
push_installation_key: "${push_key}"
backup_passphrase: "legacy-encrypted-state-value"
YAML
}

write_secret_yaml "real-smtp-secret"
printf 'operator data\n' > "$TMP/runtime/operator_file"
export_docker_secrets "$TMP/runtime" "$SECRETS_FILE" >/dev/null
[[ "$(cat "$TMP/runtime/smtp_password")" == "real-smtp-secret" ]] \
    || fail "real smtp_password was not exported"
[[ "$(stat -c '%a' "$TMP/runtime/smtp_password")" == "444" ]] \
    || fail "runtime Docker secret file was not mode 0444"
[[ -f "$TMP/runtime/operator_file" ]] || fail "unknown operator file was removed"
[[ ! -e "$TMP/runtime/.managed-secrets" ]] \
    || fail "managed-secret metadata was written inside Docker secrets directory"
[[ -f "$TMP/managed-secrets" ]] \
    || fail "managed-secret metadata was not written beside Docker secrets directory"
[[ "$(stat -c '%u:%g' "$TMP/managed-secrets")" == "0:0" ]] \
    || fail "managed-secret metadata owner contract is not root:root"
[[ "$(stat -c '%a' "$TMP/managed-secrets")" == "600" ]] \
    || fail "managed-secret metadata was not mode 0600"
write_secret_yaml "real-smtp-secret"
export_docker_secrets "$TMP/runtime" "$SECRETS_FILE" >/dev/null
[[ "$(stat -c '%a' "$TMP/managed-secrets")" == "600" ]] \
    || fail "repeated export changed managed-secret metadata mode"

write_secret_yaml "NOT_USED_EMAIL_MODE=api"
export_docker_secrets "$TMP/runtime" "$SECRETS_FILE" >/dev/null
[[ ! -e "$TMP/runtime/smtp_password" ]] \
    || fail "smtp_password remained after NOT_USED transition"
[[ -f "$TMP/runtime/operator_file" ]] || fail "unknown operator file removed after NOT_USED transition"

write_secret_yaml "real-smtp-secret"
export_docker_secrets "$TMP/runtime" "$SECRETS_FILE" >/dev/null
write_secret_yaml "CHANGE_ME_SMTP_PASSWORD"
export_docker_secrets "$TMP/runtime" "$SECRETS_FILE" >/dev/null
[[ ! -e "$TMP/runtime/smtp_password" ]] \
    || fail "smtp_password remained after CHANGE_ME transition"

printf 'legacy\n' > "$TMP/runtime/retired_schema_key"
printf 'retired_schema_key\n' > "$TMP/managed-secrets"
export_docker_secrets "$TMP/runtime" "$SECRETS_FILE" >/dev/null
[[ ! -e "$TMP/runtime/retired_schema_key" ]] \
    || fail "manifest-managed retired key was not removed"
[[ -f "$TMP/runtime/operator_file" ]] || fail "unknown operator file removed during stale cleanup"

rm -f "$TMP/managed-secrets"
printf 'old backup passphrase\n' > "$TMP/runtime/backup_passphrase"
export_docker_secrets "$TMP/runtime" "$SECRETS_FILE" >/dev/null
[[ ! -e "$TMP/runtime/backup_passphrase" ]] \
    || fail "pre-manifest legacy backup_passphrase runtime file was not removed"
[[ -f "$TMP/runtime/operator_file" ]] || fail "unknown operator file removed during legacy cleanup"

PUSH_ENABLED=true
export PUSH_ENABLED
write_secret_yaml "real-smtp-secret" "real-push-id" "real-push-key"
export_docker_secrets "$TMP/runtime" "$SECRETS_FILE" >/dev/null
[[ "$(cat "$TMP/runtime/push_installation_id")" == "real-push-id" ]] \
    || fail "PUSH_ENABLED=true did not export real push_installation_id"
[[ "$(cat "$TMP/runtime/push_installation_key")" == "real-push-key" ]] \
    || fail "PUSH_ENABLED=true did not export real push_installation_key"
[[ "$(stat -c '%a' "$TMP/runtime/push_installation_id")" == "444" ]] \
    || fail "real push_installation_id was not mode 0444"

PUSH_ENABLED=false
export PUSH_ENABLED
export_docker_secrets "$TMP/runtime" "$SECRETS_FILE" >/dev/null
prepare_push_secret_placeholders "$TMP/runtime" >/dev/null
[[ -f "$TMP/runtime/push_installation_id" && ! -s "$TMP/runtime/push_installation_id" ]] \
    || fail "PUSH_ENABLED=false left real push_installation_id content in runtime"
[[ -f "$TMP/runtime/push_installation_key" && ! -s "$TMP/runtime/push_installation_key" ]] \
    || fail "PUSH_ENABLED=false left real push_installation_key content in runtime"
[[ "$(stat -c '%a' "$TMP/runtime/push_installation_id")" == "444" ]] \
    || fail "disabled push_installation_id placeholder was not mode 0444"
[[ "$(stat -c '%a' "$TMP/runtime/push_installation_key")" == "444" ]] \
    || fail "disabled push_installation_key placeholder was not mode 0444"

printf 'Runtime secret reconciliation tests passed.\n'
)

check_runtime_secret_reconciliation
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
TESTS_RUN=0
OP="age1op00000000000000000000000000000000000000000000000000000000"
OFF="age1off0000000000000000000000000000000000000000000000000000000"
OFF2="age1of20000000000000000000000000000000000000000000000000000000"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

write_stubs() {
    local bin="$TMP/bin"
    mkdir -p "$bin"
    cat > "$bin/sops" <<'SOPS'
#!/usr/bin/env bash
set -euo pipefail
config=""; mode=""; output=""; target=""; prev=""
for arg in "$@"; do
    case "$arg" in
        --config) prev=config ;;
        --output) prev=output ;;
        --encrypt) mode=encrypt ;;
        updatekeys) mode=updatekeys ;;
        -d|--decrypt) mode=decrypt ;;
        --yes) ;;
        *)
            case "$prev" in
                config) config="$arg"; prev="" ;;
                output) output="$arg"; prev="" ;;
                *) target="$arg" ;;
            esac
            ;;
    esac
done
recipients_from_policy() {
    sed -n 's/^[[:space:]]*age:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$1" | tail -1
}
write_meta() {
    local file="$1" csv="$2" r
    {
        printf 'payload: encrypted\n'
        printf 'sops:\n  age:\n'
        IFS=',' read -ra recs <<< "$csv"
        for r in "${recs[@]}"; do
            printf '    - recipient: %s\n' "$r"
        done
    } > "$file"
}
case "$mode" in
    encrypt)
        [[ -n "$config" && -n "$output" && -n "$target" ]] || exit 2
        write_meta "$output" "$(recipients_from_policy "$config")"
        ;;
    updatekeys)
        [[ -n "$config" && -n "$target" ]] || exit 2
        if [[ -n "${MOCK_FAIL_UPDATEKEYS_UNDER:-}" && "$target" == "$MOCK_FAIL_UPDATEKEYS_UNDER"/* ]]; then
            exit 42
        fi
        write_meta "$target" "$(recipients_from_policy "$config")"
        ;;
    decrypt)
        [[ -n "$target" ]] || exit 2
        cat "$target" >/dev/null
        ;;
    *) exit 2 ;;
esac
SOPS
    chmod +x "$bin/sops"
}

source_helpers() {
    export PATH="$TMP/bin:$PATH"
    export SETUP_SECRETS_TRANSACTION_TESTING=source-only
    export PROJECT_STATE_DIR="$TMP/state"
    export VW_SETUP_SECRETS_TMP_DIR="$TMP/run-tmp"
    mkdir -p "$PROJECT_STATE_DIR/config" "$PROJECT_STATE_DIR/secrets"
    # shellcheck source=../utilities/setup-secrets.sh
    source "$ROOT/utilities/setup-secrets.sh"
}

case_dir() {
    local d="$TMP/case-$TESTS_RUN"
    mkdir -p "$d/state/config" "$d/state/secrets" "$d/policy"
    printf 'STATE_LAYOUT_VERSION=1\n' > "$d/state/config/dr-manifest.env"
    printf '%s' "$d"
}

assert_recipients() {
    local file="$1" shift_csv="$2" r
    IFS=',' read -ra recs <<< "$shift_csv"
    for r in "${recs[@]}"; do
        grep -q "recipient: $r" "$file" || fail "missing recipient $r in $file"
    done
}

assert_policy_recipients() {
    local file="$1" csv="$2"
    grep -q "age: \"$csv\"" "$file" || fail "policy recipients mismatch in $file"
}

assert_no_plaintext_outside_tmp() {
    local d="$1"
    ! find "$d" -path "$VW_SETUP_SECRETS_TMP_DIR" -prune -o -name 'vwsecrets*.yaml' -print | grep -q . || fail 'plaintext staging leaked outside protected tmp dir'
    ! find "$VW_SETUP_SECRETS_TMP_DIR" -type f -print 2>/dev/null | grep -q . || fail 'plaintext staging file left behind'
}

assert_no_transaction_leftovers() {
    local d="$1"
    ! find "$d" \( -name '.sops.yaml.*' -o -name 'dr-manifest.env.*' -o -name 'tmp.*.yaml' -o -name 'secrets.yaml.bak' -o -name 'sops.yaml.bak' -o -name 'dr-manifest.env.bak' \) -print | grep -q . || fail 'transaction staging or backup file left behind'
}

run_test() {
    local name="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    "$@"
    pass "$name"
}

test_fresh_bootstrap() {
    local d; d=$(case_dir)
    PROJECT_STATE_DIR="$d/state"
    export OFFLINE_AGE_RECIPIENT="$OFF"
    local plain final policy
    plain="$(_ss_make_plaintext_temp)"
    chmod 0600 "$plain"
    printf 'admin_token: PLACEHOLDER\n' > "$plain"
    final="$d/state/secrets/secrets.yaml"
    policy="$d/policy/.sops.yaml"
    _ss_commit_ciphertext_transaction "$plain" "$d/key.txt" "$OP" "$final" "$policy" plaintext
    rm -f "$plain"
    [[ -f "$final" ]] || fail 'ciphertext not installed'
    assert_recipients "$final" "$OP,$OFF"
    assert_policy_recipients "$policy" "$OP,$OFF"
    grep -q "OFFLINE_AGE_RECIPIENT=$OFF" "$d/state/config/dr-manifest.env" || fail 'manifest not updated'
    assert_no_plaintext_outside_tmp "$d"
}

test_add_offline_recipient_existing_ciphertext() {
    local d; d=$(case_dir)
    PROJECT_STATE_DIR="$d/state"
    unset OFFLINE_AGE_RECIPIENT || true
    local final policy
    final="$d/state/secrets/secrets.yaml"
    policy="$d/policy/.sops.yaml"
    printf 'OFFLINE_AGE_RECIPIENT=%s\n' "$OFF2" >> "$d/state/config/dr-manifest.env"
    cat > "$policy" <<POLICY
creation_rules:
  - path_regex: '.*\.yaml$'
    age: "$OP"
POLICY
    cat > "$final" <<CIPHER
payload: encrypted
sops:
  age:
    - recipient: $OP
CIPHER
    _ss_commit_ciphertext_transaction "" "$d/key.txt" "$OP" "$final" "$policy" rekey
    assert_recipients "$final" "$OP,$OFF2"
    assert_policy_recipients "$policy" "$OP,$OFF2"
    grep -q "OFFLINE_AGE_RECIPIENT=$OFF2" "$d/state/config/dr-manifest.env" || fail 'manifest did not preserve offline recipient'
}

test_staged_update_failure() {
    local d; d=$(case_dir)
    PROJECT_STATE_DIR="$d/state"
    export OFFLINE_AGE_RECIPIENT="$OFF"
    local final policy plain
    final="$d/state/secrets/secrets.yaml"
    policy="$d/policy/.sops.yaml"
    plain="$(_ss_make_plaintext_temp)"
    printf 'admin_token: PLACEHOLDER\n' > "$plain"
    printf 'live-cipher\n' > "$final"
    printf 'live-policy\n' > "$policy"
    cp "$final" "$d/final.before"
    cp "$policy" "$d/policy.before"
    cp "$d/state/config/dr-manifest.env" "$d/manifest.before"
    if MOCK_FAIL_UPDATEKEYS_UNDER="$d/state/secrets" _ss_commit_ciphertext_transaction "$plain" "$d/key.txt" "$OP" "$final" "$policy" plaintext; then
        fail 'transaction unexpectedly succeeded'
    fi
    cmp -s "$d/final.before" "$final" || fail 'live ciphertext changed on update failure'
    cmp -s "$d/policy.before" "$policy" || fail 'live policy changed on update failure'
    cmp -s "$d/manifest.before" "$d/state/config/dr-manifest.env" || fail 'manifest changed on update failure'
    rm -f "$plain"
    assert_no_plaintext_outside_tmp "$d"
    ! find "$d/state/secrets" -name '*.yaml' ! -name 'secrets.yaml' -print | grep -q . || fail 'ciphertext staging file left behind'
    assert_no_transaction_leftovers "$d"
}

test_manifest_helper_failure_preserves_artifacts() {
    local d; d=$(case_dir)
    PROJECT_STATE_DIR="$d/state"
    export OFFLINE_AGE_RECIPIENT="$OFF"
    local final policy plain original_set_env_var
    final="$d/state/secrets/secrets.yaml"
    policy="$d/policy/.sops.yaml"
    plain="$(_ss_make_plaintext_temp)"
    printf 'admin_token: PLACEHOLDER\n' > "$plain"
    printf 'live-cipher\n' > "$final"
    printf 'live-policy\n' > "$policy"
    printf 'OFFLINE_AGE_RECIPIENT=%s\nMANIFEST_UPDATED_AT=original\n' "$OFF2" > "$d/state/config/dr-manifest.env"
    cp "$final" "$d/final.before"
    cp "$policy" "$d/policy.before"
    cp "$d/state/config/dr-manifest.env" "$d/manifest.before"

    original_set_env_var="$(declare -f _set_env_var)"
    _set_env_var(){ return 47; }
    if _ss_commit_ciphertext_transaction "$plain" "$d/key.txt" "$OP" "$final" "$policy" plaintext; then
        eval "$original_set_env_var"
        fail 'manifest helper failure unexpectedly succeeded'
    fi
    eval "$original_set_env_var"

    cmp -s "$d/final.before" "$final" || fail 'live ciphertext changed after manifest helper failure'
    cmp -s "$d/policy.before" "$policy" || fail 'live policy changed after manifest helper failure'
    cmp -s "$d/manifest.before" "$d/state/config/dr-manifest.env" || fail 'manifest changed after helper failure'
    rm -f "$plain"
    assert_no_transaction_leftovers "$d"
}

test_manifest_promotion_failure_preserves_artifacts() {
    local d; d=$(case_dir)
    PROJECT_STATE_DIR="$d/state"
    export OFFLINE_AGE_RECIPIENT="$OFF"
    local final policy plain
    final="$d/state/secrets/secrets.yaml"
    policy="$d/policy/.sops.yaml"
    plain="$(_ss_make_plaintext_temp)"
    printf 'admin_token: PLACEHOLDER\n' > "$plain"
    printf 'live-cipher\n' > "$final"
    printf 'live-policy\n' > "$policy"
    printf 'OFFLINE_AGE_RECIPIENT=%s\nMANIFEST_UPDATED_AT=original\n' "$OFF2" > "$d/state/config/dr-manifest.env"
    cp "$final" "$d/final.before"
    cp "$policy" "$d/policy.before"
    cp "$d/state/config/dr-manifest.env" "$d/manifest.before"
    mv() {
        if [[ "${MOCK_FAIL_MANIFEST_PROMOTE:-}" == "1" && "${*: -1}" == "$d/state/config/dr-manifest.env" ]]; then
            return 55
        fi
        command mv "$@"
    }
    if MOCK_FAIL_MANIFEST_PROMOTE=1 _ss_commit_ciphertext_transaction "$plain" "$d/key.txt" "$OP" "$final" "$policy" plaintext; then
        unset -f mv
        fail 'manifest promotion failure unexpectedly succeeded'
    fi
    unset -f mv
    cmp -s "$d/final.before" "$final" || fail 'live ciphertext changed on manifest promotion failure'
    cmp -s "$d/policy.before" "$policy" || fail 'live policy changed on manifest promotion failure'
    cmp -s "$d/manifest.before" "$d/state/config/dr-manifest.env" || fail 'manifest changed on manifest promotion failure'
    rm -f "$plain"
    assert_no_transaction_leftovers "$d"
}

test_manifest_promotion_failure_preserves_absent_manifest() {
    local d; d=$(case_dir)
    PROJECT_STATE_DIR="$d/state"
    export OFFLINE_AGE_RECIPIENT="$OFF"
    local final policy plain
    final="$d/state/secrets/secrets.yaml"
    policy="$d/policy/.sops.yaml"
    plain="$(_ss_make_plaintext_temp)"
    printf 'admin_token: PLACEHOLDER\n' > "$plain"
    printf 'live-cipher\n' > "$final"
    printf 'live-policy\n' > "$policy"
    rm -f "$d/state/config/dr-manifest.env"
    cp "$final" "$d/final.before"
    cp "$policy" "$d/policy.before"
    mv() {
        if [[ "${MOCK_FAIL_MANIFEST_PROMOTE:-}" == "1" && "${*: -1}" == "$d/state/config/dr-manifest.env" ]]; then
            return 55
        fi
        command mv "$@"
    }
    if MOCK_FAIL_MANIFEST_PROMOTE=1 _ss_commit_ciphertext_transaction "$plain" "$d/key.txt" "$OP" "$final" "$policy" plaintext; then
        unset -f mv
        fail 'absent manifest promotion failure unexpectedly succeeded'
    fi
    unset -f mv
    cmp -s "$d/final.before" "$final" || fail 'live ciphertext changed on absent manifest promotion failure'
    cmp -s "$d/policy.before" "$policy" || fail 'live policy changed on absent manifest promotion failure'
    [[ ! -e "$d/state/config/dr-manifest.env" ]] || fail 'absent manifest was created on failed transaction'
    rm -f "$plain"
    assert_no_transaction_leftovers "$d"
}

test_term_after_ciphertext_promotion_rolls_back_and_preserves_traps() {
    local d; d=$(case_dir)
    PROJECT_STATE_DIR="$d/state"
    export OFFLINE_AGE_RECIPIENT="$OFF"
    local final policy plain before_return before_int before_term after_return after_int after_term status
    final="$d/state/secrets/secrets.yaml"
    policy="$d/policy/.sops.yaml"
    plain="$(_ss_make_plaintext_temp)"
    printf 'admin_token: PLACEHOLDER\n' > "$plain"
    printf 'live-cipher\n' > "$final"
    cp "$final" "$d/final.before"
    rm -f "$policy" "$d/state/config/dr-manifest.env"
    trap 'printf outer-return-trap >/dev/null' RETURN
    trap 'printf outer-int-trap >/dev/null' INT
    trap 'printf outer-term-trap >/dev/null' TERM
    before_return="$(trap -p RETURN)"
    before_int="$(trap -p INT)"
    before_term="$(trap -p TERM)"
    set +e
    SETUP_SECRETS_TEST_TERM_AFTER_CIPHERTEXT_PROMOTION=1 _ss_commit_ciphertext_transaction "$plain" "$d/key.txt" "$OP" "$final" "$policy" plaintext
    status=$?
    set -e
    after_return="$(trap -p RETURN)"
    after_int="$(trap -p INT)"
    after_term="$(trap -p TERM)"
    trap - RETURN INT TERM
    [[ "$status" -eq 143 ]] || fail "TERM transaction returned $status instead of 143"
    [[ "$after_return" == "$before_return" ]] || fail 'outer RETURN trap was not preserved after TERM'
    [[ "$after_int" == "$before_int" ]] || fail 'outer INT trap was not preserved after TERM'
    [[ "$after_term" == "$before_term" ]] || fail 'outer TERM trap was not preserved after TERM'
    cmp -s "$d/final.before" "$final" || fail 'ciphertext not restored after TERM'
    [[ ! -e "$policy" ]] || fail 'absent policy created after TERM rollback'
    [[ ! -e "$d/state/config/dr-manifest.env" ]] || fail 'absent manifest created after TERM rollback'
    rm -f "$plain"
    assert_no_transaction_leftovers "$d"
}

test_preserves_outer_return_trap() {
    local d; d=$(case_dir)
    PROJECT_STATE_DIR="$d/state"
    export OFFLINE_AGE_RECIPIENT="$OFF"
    local plain final policy before after
    plain="$(_ss_make_plaintext_temp)"
    printf 'admin_token: PLACEHOLDER\n' > "$plain"
    final="$d/state/secrets/secrets.yaml"
    policy="$d/policy/.sops.yaml"
    trap 'printf outer-return-trap >/dev/null' RETURN
    before="$(trap -p RETURN)"
    _ss_commit_ciphertext_transaction "$plain" "$d/key.txt" "$OP" "$final" "$policy" plaintext "$OP,$OFF"
    after="$(trap -p RETURN)"
    trap - RETURN
    rm -f "$plain"
    [[ "$after" == "$before" ]] || fail 'outer RETURN trap was not preserved after transaction success'
    [[ -f "$final" ]] || fail 'ciphertext not installed with outer trap present'
}

write_stubs
source_helpers
run_test 'fresh bootstrap stages plaintext in tmpfs and installs recipients' test_fresh_bootstrap
run_test 'adding offline recipient rekeys existing ciphertext metadata' test_add_offline_recipient_existing_ciphertext
run_test 'staged update failure preserves live artifacts and cleans staging' test_staged_update_failure
run_test 'manifest helper failure prevents partial artifact promotion' test_manifest_helper_failure_preserves_artifacts
run_test 'manifest promotion failure preserves existing live artifacts' test_manifest_promotion_failure_preserves_artifacts
run_test 'manifest promotion failure preserves absent manifest' test_manifest_promotion_failure_preserves_absent_manifest
run_test 'TERM after ciphertext promotion rolls back artifacts and preserves traps' test_term_after_ciphertext_promotion_rolls_back_and_preserves_traps
run_test 'successful transaction preserves existing caller return trap' test_preserves_outer_return_trap
[[ "$TESTS_RUN" -eq 8 ]] || fail "expected 8 tests, ran $TESTS_RUN"
printf '1..%s\n' "$TESTS_RUN"

check_key_rotate_live_generation_transaction() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log_warn() { printf 'WARN: %s\n' "$*" >&2; }
log_error() { printf 'ERROR: %s\n' "$*" >&2; }
log_success() { printf 'SUCCESS: %s\n' "$*" >&2; }

sed -n '/^_KEY_ROTATE_COMMITTED=false$/,/^_display_rotated_age_key_summary()/p' \
    "$ROOT/utilities/key-rotate.sh" | sed '$d' > "$TMP/key-rotate-transaction.sh"
# shellcheck source=/dev/null
source "$TMP/key-rotate-transaction.sh"

check_age_key() {
    [[ -s "$1" ]]
}
sops() {
    local target="${*: -1}" key_value cipher_value
    [[ "${1:-}" == "-d" ]] || return 2
    key_value="$(cat "${SOPS_AGE_KEY_FILE:?}")"
    cipher_value="$(cat "$target")"
    [[ "$key_value" == "key-old" && "$cipher_value" == "cipher-old" ]] \
        || [[ "$key_value" == "key-new" && "$cipher_value" == "cipher-new" ]]
}

mkdir -p "$TMP/live" "$TMP/backup" "$TMP/staged"
chmod 700 "$TMP/live" "$TMP/backup" "$TMP/staged"
artifacts=(system-key repo-key ciphertext policy repo-env system-env install-env)
for artifact in "${artifacts[@]}"; do
    case "$artifact" in
        system-key|repo-key) old_value="key-old"; new_value="key-new" ;;
        ciphertext) old_value="cipher-old"; new_value="cipher-new" ;;
        *) old_value="${artifact}-old"; new_value="${artifact}-new" ;;
    esac
    printf '%s\n' "$old_value" > "$TMP/live/$artifact"
    printf '%s\n' "$old_value" > "$TMP/backup/$artifact"
    printf '%s\n' "$new_value" > "$TMP/staged/$artifact"
    chmod 600 "$TMP/live/$artifact" "$TMP/backup/$artifact" "$TMP/staged/$artifact"
done

run_rotation_generation() (
    set -euo pipefail
    local signal_after="${1:-}"
    _key_rotate_reset_transaction
    _KEY_ROTATE_OLD_KEY="$TMP/live/system-key"
    _KEY_ROTATE_LIVE_SECRETS="$TMP/live/ciphertext"
    VW_TEST_KEY_ROTATE_SIGNAL_AFTER="$signal_after"
    export VW_TEST_KEY_ROTATE_SIGNAL_AFTER
    # Bash preserves the pre-trap status after an EXIT trap, so rollback can
    # remain status-neutral without an extra trap-local status variable.
    trap '_key_rotate_rollback_live_generation || true' EXIT
    trap 'exit 130' INT
    trap 'exit 129' HUP
    trap 'exit 143' TERM

    local artifact
    for artifact in "${artifacts[@]}"; do
        _key_rotate_promote_file \
            "$TMP/staged/$artifact" "$TMP/live/$artifact" \
            "$TMP/backup/$artifact" true 600
        _key_rotate_test_signal_after "$artifact"
    done
    SOPS_AGE_KEY_FILE="$TMP/live/system-key" sops -d "$TMP/live/ciphertext" >/dev/null
    _KEY_ROTATE_COMMITTED=true
)

status=0
run_rotation_generation system-key >"$TMP/interrupted.out" 2>&1 || status=$?
[[ "$status" -eq 143 ]] || fail "interrupted rotation returned $status instead of TERM status 143"
for artifact in "${artifacts[@]}"; do
    cmp -s "$TMP/backup/$artifact" "$TMP/live/$artifact" \
        || fail "interrupted rotation did not restore $artifact"
done
SOPS_AGE_KEY_FILE="$TMP/live/system-key" sops -d "$TMP/live/ciphertext" >/dev/null \
    || fail "restored old key does not decrypt restored ciphertext"
grep -Fq 'Previous Age/SOPS generation restored and decryptable.' "$TMP/interrupted.out" \
    || fail "interrupted rotation did not validate and report the restored generation"

run_rotation_generation "" >"$TMP/retry.out" 2>&1 \
    || { cat "$TMP/retry.out" >&2; fail "normal retry after interrupted rotation failed"; }
[[ "$(cat "$TMP/live/system-key")" == "key-new" ]] \
    || fail "normal retry did not promote the new canonical key"
[[ "$(cat "$TMP/live/ciphertext")" == "cipher-new" ]] \
    || fail "normal retry did not promote matching ciphertext"
SOPS_AGE_KEY_FILE="$TMP/live/system-key" sops -d "$TMP/live/ciphertext" >/dev/null \
    || fail "new canonical key does not decrypt live ciphertext after retry"

printf 'Key rotation live-generation rollback and retry tests passed.\n'
)

check_key_rotate_live_generation_transaction

check_key_rotate_full_entrypoint_cleanup_contract() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

case_root="$TMP/key-rotate-entrypoint"
repo="$case_root/repo"
rootfs="$case_root/rootfs"
mkdir -p "$repo/utilities" "$repo/lib" "$repo/secrets/keys" "$case_root/bin" \
    "$rootfs/etc/vaultwarden" "$rootfs/state/secrets" "$rootfs/state/config" "$rootfs/root"

cp "$ROOT/utilities/key-rotate.sh" "$repo/utilities/key-rotate.sh"
# Redirect only hard-coded host roots in the disposable script copy;
# the production control flow, traps, and cleanup functions remain intact.
sed -i \
    -e 's#/etc/vaultwarden#${VW_TEST_ROOT}/etc/vaultwarden#g' \
    -e 's#/root/#${VW_TEST_ROOT}/root/#g' \
    "$repo/utilities/key-rotate.sh"
chmod +x "$repo/utilities/key-rotate.sh"

cat > "$repo/lib/log.sh" <<'MOCK_LOG'
log_header(){ printf 'HEADER: %s\n' "$*"; }
log_info(){ printf 'INFO: %s\n' "$*"; }
log_warn(){ printf 'WARN: %s\n' "$*" >&2; }
log_error(){ printf 'ERROR: %s\n' "$*" >&2; }
log_success(){ printf 'SUCCESS: %s\n' "$*"; }
COLOR_RED=''; COLOR_RESET=''; COLOR_CYAN=''; COLOR_GREEN=''
MOCK_LOG
cat > "$repo/lib/config.sh" <<'MOCK_CONFIG'
load_project_environment(){ return 0; }
get_config_value(){
    case "$1" in
        PROJECT_STATE_DIR) printf '%s\n' "${VW_TEST_ROOT:?}/state" ;;
        *) printf '%s\n' "${2:-}" ;;
    esac
}
_stat_octal_perms(){ stat -c '%a' "$1"; }
_stat_owner(){ stat -c '%U' "$1"; }
_stat_group(){ stat -c '%G' "$1"; }
MOCK_CONFIG
cat > "$repo/lib/common.sh" <<'MOCK_COMMON'
init_common_lib(){ :; }
require_root(){ :; }
operator_attention(){ :; }
operator_confirm_yes_no(){ return 0; }
MOCK_COMMON
cat > "$repo/lib/operations.sh" <<'MOCK_OPERATIONS'
operation_acquire(){ return 0; }
operation_set_phase(){ return 0; }
operation_release(){ printf '%s\n' "$1" >> "${VW_TEST_RELEASE_LOG:?}"; }
MOCK_OPERATIONS
cat > "$repo/lib/crypto.sh" <<'MOCK_CRYPTO'
resolve_age_key_path(){ printf '%s\n' "${VW_TEST_ROOT:?}/etc/vaultwarden/age-key.txt"; }
check_age_key(){ [[ -s "$1" ]]; }
MOCK_CRYPTO
cat > "$repo/lib/setup-credentials.sh" <<'MOCK_SETUP_CREDENTIALS'
# Minimal functional mock for the full-entrypoint transaction fixture.  The
# production helper's formatting is covered elsewhere; this fixture needs the
# sourced symbol and the root-only handoff artifact expected after a retry.
publish_age_rotation_handoff() {
    local key_file="$1" timestamp="$3"
    local destination="${VW_TEST_ROOT:?}/root/vaultwarden-recovery-kit-age-rotate-${timestamp}.txt"
    install -m 600 "$key_file" "$destination"
    printf '%s\n' "$destination"
}
MOCK_SETUP_CREDENTIALS

cat > "$case_root/bin/install" <<'MOCK_INSTALL'
#!/usr/bin/env bash
set -euo pipefail
args=()
while (( $# )); do
    case "$1" in
        -o|-g) shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
exec /usr/bin/install "${args[@]}"
MOCK_INSTALL
cat > "$case_root/bin/mktemp" <<'MOCK_MKTEMP'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'vw-age-rotate.'* ]]; then
    workdir="${VW_TEST_ROOT:?}/workdir"
    rm -rf "$workdir"
    mkdir -p "$workdir"
    printf '%s\n' "$workdir" > "${VW_TEST_WORKDIR_RECORD:?}"
    printf '%s\n' "$workdir"
    exit 0
fi
exec /usr/bin/mktemp "$@"
MOCK_MKTEMP
cat > "$case_root/bin/age-keygen" <<'MOCK_AGE_KEYGEN'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    -o)
        printf 'AGE-SECRET-KEY-1NEW\n' > "${2:?}"
        ;;
    -y)
        if grep -Fq 'OLD' "${2:?}"; then
            printf 'age1'; printf 'a%.0s' {1..58}; printf '\n'
        else
            printf 'age1'; printf 'b%.0s' {1..58}; printf '\n'
        fi
        ;;
    *) exit 2 ;;
esac
MOCK_AGE_KEYGEN
cat > "$case_root/bin/sops" <<'MOCK_SOPS'
#!/usr/bin/env bash
set -euo pipefail
target="${*: -1}"
if [[ " $* " == *' updatekeys '* ]]; then
    printf 'cipher-new\n' > "$target"
    exit 0
fi
[[ "${1:-}" == '-d' ]] || exit 2
key_value="$(cat "${SOPS_AGE_KEY_FILE:?}")"
cipher_value="$(cat "$target")"
[[ "$key_value" == 'AGE-SECRET-KEY-1OLD' && "$cipher_value" == 'cipher-old' ]] \
    || [[ "$key_value" == 'AGE-SECRET-KEY-1NEW' && "$cipher_value" == 'cipher-new' ]]
MOCK_SOPS
chmod +x "$case_root/bin/"*

old_pub="age1$(printf 'a%.0s' {1..58})"
canonical_key="$rootfs/etc/vaultwarden/age-key.txt"
secrets_file="$rootfs/state/secrets/secrets.yaml"
printf 'AGE-SECRET-KEY-1OLD\n' > "$canonical_key"
printf 'AGE-SECRET-KEY-1OLD\n' > "$repo/secrets/keys/age-key.txt"
printf 'cipher-old\n' > "$secrets_file"
printf 'creation_rules:\n  - age: "%s"\n' "$old_pub" > "$repo/.sops.yaml"
printf 'SOPS_AGE_KEY_FILE=%s\n' "$canonical_key" > "$repo/.env"
printf 'SOPS_AGE_KEY_FILE=%s\n' "$canonical_key" > "$rootfs/etc/vaultwarden/vaultwarden.env"
printf 'SOPS_AGE_KEY_FILE=%s\n' "$canonical_key" > "$rootfs/state/config/install.env"
: > "$rootfs/state/config/dr-manifest.env"
chmod 600 "$canonical_key" "$repo/secrets/keys/age-key.txt" "$secrets_file" \
    "$repo/.env" "$rootfs/etc/vaultwarden/vaultwarden.env" \
    "$rootfs/state/config/install.env"
chmod 644 "$repo/.sops.yaml"

release_log="$case_root/releases.log"
workdir_record="$case_root/workdir.path"
run_full_rotation(){
    local signal_after="$1" output_file="$2" rc=0
    : > "$release_log"
    rm -f "$workdir_record"
    SECRETS_FILE="$secrets_file" \
    VW_TEST_ROOT="$rootfs" \
    VW_TEST_RELEASE_LOG="$release_log" \
    VW_TEST_WORKDIR_RECORD="$workdir_record" \
    VW_TEST_KEY_ROTATE_SIGNAL_AFTER="$signal_after" \
    PATH="$case_root/bin:$PATH" \
        bash "$repo/utilities/key-rotate.sh" --yes >"$output_file" 2>&1 || rc=$?
    printf '%s\n' "$rc"
}

assert_old_generation(){
    grep -Fxq 'AGE-SECRET-KEY-1OLD' "$canonical_key" \
        || fail 'interrupted entrypoint did not restore the canonical system key'
    grep -Fxq 'AGE-SECRET-KEY-1OLD' "$repo/secrets/keys/age-key.txt" \
        || fail 'interrupted entrypoint changed the repository key'
    grep -Fxq 'cipher-old' "$secrets_file" \
        || fail 'interrupted entrypoint did not preserve old ciphertext'
    grep -Fq "$old_pub" "$repo/.sops.yaml" \
        || fail 'interrupted entrypoint changed the old SOPS policy'
    for env_file in "$repo/.env" "$rootfs/etc/vaultwarden/vaultwarden.env" \
        "$rootfs/state/config/install.env"; do
        grep -Fxq "SOPS_AGE_KEY_FILE=$canonical_key" "$env_file" \
            || fail "interrupted entrypoint changed canonical key reference: $env_file"
    done
    SOPS_AGE_KEY_FILE="$canonical_key" PATH="$case_root/bin:$PATH" \
        sops -d "$secrets_file" >/dev/null \
        || fail 'restored entrypoint generation is not decryptable'
}

interrupted_rc="$(run_full_rotation system-key "$case_root/interrupted.out")"
[[ "$interrupted_rc" == '143' ]] \
    || { cat "$case_root/interrupted.out" >&2; fail "full entrypoint returned $interrupted_rc instead of TERM status 143"; }
assert_old_generation
mapfile -t interrupted_releases < "$release_log"
[[ "${#interrupted_releases[@]}" -eq 1 && "${interrupted_releases[0]}" == '143' ]] \
    || fail "interrupted entrypoint released the operation guard ${#interrupted_releases[@]} time(s): ${interrupted_releases[*]:-none}"
[[ -s "$workdir_record" ]] || fail 'entrypoint did not record its staging workdir'
interrupted_workdir="$(cat "$workdir_record")"
[[ ! -e "$interrupted_workdir" ]] \
    || fail "entrypoint left sensitive staging workdir after TERM: $interrupted_workdir"
grep -Fq 'Previous Age/SOPS generation restored and decryptable.' "$case_root/interrupted.out" \
    || fail 'full entrypoint did not report validated rollback'

retry_rc="$(run_full_rotation '' "$case_root/retry.out")"
[[ "$retry_rc" == '0' ]] \
    || { cat "$case_root/retry.out" >&2; fail "full entrypoint retry returned $retry_rc"; }
mapfile -t retry_releases < "$release_log"
[[ "${#retry_releases[@]}" -eq 1 && "${retry_releases[0]}" == '0' ]] \
    || fail "successful entrypoint released the operation guard ${#retry_releases[@]} time(s): ${retry_releases[*]:-none}"
[[ -s "$workdir_record" ]] || fail 'successful entrypoint did not record its staging workdir'
retry_workdir="$(cat "$workdir_record")"
[[ ! -e "$retry_workdir" ]] \
    || fail "successful entrypoint left sensitive staging workdir: $retry_workdir"
grep -Fxq 'AGE-SECRET-KEY-1NEW' "$canonical_key" \
    || fail 'full entrypoint retry did not promote the new canonical key'
grep -Fxq 'cipher-new' "$secrets_file" \
    || fail 'full entrypoint retry did not promote matching ciphertext'
SOPS_AGE_KEY_FILE="$canonical_key" PATH="$case_root/bin:$PATH" \
    sops -d "$secrets_file" >/dev/null \
    || fail 'full entrypoint retry left an undecryptable live generation'
find "$rootfs/root" -maxdepth 1 -type f \
    -name 'vaultwarden-recovery-kit-age-rotate-*.txt' -print -quit | grep -q . \
    || fail 'successful full entrypoint did not write its recovery kit'

printf 'Full key-rotation entrypoint rollback, cleanup, guard-release, and retry tests passed.\n'
)

check_key_rotate_full_entrypoint_cleanup_contract
