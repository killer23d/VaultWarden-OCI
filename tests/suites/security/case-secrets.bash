#!/usr/bin/env bash
# Consolidated secrets regression suite.
set -euo pipefail
MODE="${VW_TEST_CASE_MODE:-all}"
case "$MODE" in core|sensitive-cleanup|all) ;; *) printf 'FAIL: unknown VW_TEST_CASE_MODE for case-secrets.bash: %s\n' "$MODE" >&2; exit 2 ;; esac

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

check_recovery_kit_attachment_passphrase_contract() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

helper_source="$TMP/encrypt-helper.sh"
transport_source="$TMP/stdin-helper.sh"
awk '
  /^_encrypt_recovery_kit_attachment[(][)]/ { in_helper=1 }
  in_helper { print }
  in_helper && /^}/ { exit }
' "$ROOT/lib/secrets.sh" >"$helper_source"
awk '
  /^_run_7zip_with_passphrase[(][)]/ { in_helper=1 }
  in_helper { print }
  in_helper && /^}/ { exit }
' "$ROOT/lib/secrets.sh" >"$transport_source"
[[ -s "$helper_source" && -s "$transport_source" ]] \
    || fail 'could not isolate recovery-kit passphrase helpers'

grep -Fq 'prompt_password_with_confirmation' "$helper_source" \
    || fail 'attachment helper must use password confirmation'
grep -Fq '"Passphrase to encrypt emailed AES-256 ZIP (independent from stored project credentials)" 16)' "$helper_source" \
    || fail 'attachment helper must enforce the 16-character minimum'
grep -Fq '_run_7zip_with_passphrase "$passphrase"' "$helper_source" \
    || fail 'attachment helper must use the private 7-Zip passphrase transport'
grep -Fq 'set +x' "$helper_source" \
    || fail 'attachment helper must disable xtrace while the passphrase is live'
grep -Fq 'unset passphrase' "$helper_source" \
    || fail 'attachment helper must unset the passphrase promptly'
grep -Fq "printf '%s\\n%s\\n' \"\$passphrase\" \"\$passphrase\"" "$transport_source" \
    || fail 'archive creation must supply the confirmed passphrase twice on stdin'
grep -Fq "printf '%s\\n' \"\$passphrase\"" "$transport_source" \
    || fail 'archive read operations must supply one passphrase on stdin'
grep -Fq -- '-p?*)' "$transport_source" \
    || fail '7-Zip transport must reject inline password arguments'
! grep -Eq 'pty[.]fork|python3 -|3<<<|fd 3|passphrase[-_]file|_pass_file|ZIP_PASSWORD|RECOVERY_PASSWORD' \
    "$helper_source" "$transport_source" \
    || fail 'obsolete passphrase transport mechanism remains'
! awk '
  /-p|--password/ &&
  /\$[{]?(passphrase|password|secret|zip_password|recovery_password)([}]|[^A-Za-z0-9_])/ {
    found=1
  }
  END { exit found ? 0 : 1 }
' "$helper_source" "$transport_source" \
    || fail 'passphrase variable must not be placed in archiver argv'

mkdir -p "$TMP/bin"
cat > "$TMP/bin/7zz" <<'MOCK_7ZZ'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_ARGV_FILE:?}" "${MOCK_STDIN_FILE:?}" "${MOCK_ENV_FILE:?}"
printf '%s\n' "$@" >"$MOCK_ARGV_FILE"
export -p >"$MOCK_ENV_FILE"
cat >"$MOCK_STDIN_FILE"
[[ "${MOCK_FAIL_7ZIP:-0}" != "1" ]] || exit 42
case "${1:-}" in
  a|u)
    grep -Fxq -- '-p' "$MOCK_ARGV_FILE"
    mapfile -t lines <"$MOCK_STDIN_FILE"
    [[ "${#lines[@]}" -eq 2 && "${lines[0]}" == "${lines[1]}" ]]
    ;;
  t|x|e|l)
    ! grep -Fxq -- '-p' "$MOCK_ARGV_FILE"
    mapfile -t lines <"$MOCK_STDIN_FILE"
    [[ "${#lines[@]}" -eq 1 ]]
    ;;
  *) exit 7 ;;
esac
MOCK_7ZZ
chmod +x "$TMP/bin/7zz"

sentinel='TEST_ATTACHMENT_SECRET_1234567890'
(
    cd "$ROOT"
    PATH="$TMP/bin:$PATH"
    export PATH MOCK_ARGV_FILE="$TMP/add.argv" MOCK_STDIN_FILE="$TMP/add.stdin" MOCK_ENV_FILE="$TMP/add.env"
    # shellcheck source=../lib/secrets.sh
    source "$ROOT/lib/secrets.sh"
    _run_7zip_with_passphrase "$sentinel" 7zz a -tzip -mem=AES256 -p -- out.zip recovery-kit.txt
)
! grep -Fq "$sentinel" "$TMP/add.argv" \
    || fail '7-Zip argv contains the sentinel passphrase'
! grep -Fq "$sentinel" "$TMP/add.env" \
    || fail '7-Zip environment contains the sentinel passphrase'
[[ "$(grep -Fxc "$sentinel" "$TMP/add.stdin")" -eq 2 ]] \
    || fail 'archive creation did not receive the confirmed passphrase twice'

(
    cd "$ROOT"
    PATH="$TMP/bin:$PATH"
    export PATH MOCK_ARGV_FILE="$TMP/read.argv" MOCK_STDIN_FILE="$TMP/read.stdin" MOCK_ENV_FILE="$TMP/read.env"
    # shellcheck source=../lib/secrets.sh
    source "$ROOT/lib/secrets.sh"
    _run_7zip_with_passphrase "$sentinel" 7zz t -bd -y -p -- out.zip
)
! grep -Fq "$sentinel" "$TMP/read.argv" \
    || fail '7-Zip read argv contains the sentinel passphrase'
! grep -Fq "$sentinel" "$TMP/read.env" \
    || fail '7-Zip read environment contains the sentinel passphrase'
[[ "$(grep -Fxc "$sentinel" "$TMP/read.stdin")" -eq 1 ]] \
    || fail 'archive validation did not receive exactly one passphrase line'

failure_output="$TMP/failure.out"
if (
    cd "$ROOT"
    PATH="$TMP/bin:$PATH"
    export PATH MOCK_FAIL_7ZIP=1 MOCK_ARGV_FILE="$TMP/fail.argv" MOCK_STDIN_FILE="$TMP/fail.stdin" MOCK_ENV_FILE="$TMP/fail.env"
    # shellcheck source=../lib/secrets.sh
    source "$ROOT/lib/secrets.sh"
    _run_7zip_with_passphrase "$sentinel" 7zz t -bd -y -p -- out.zip
) >"$failure_output" 2>&1; then
    fail 'forced 7-Zip failure unexpectedly succeeded'
fi
! grep -Fq "$sentinel" "$failure_output" \
    || fail '7-Zip failure output exposed the passphrase'
! grep -Fq "$sentinel" "$TMP/fail.argv" \
    || fail '7-Zip failure argv exposed the passphrase'
! grep -Fq "$sentinel" "$TMP/fail.env" \
    || fail '7-Zip failure environment exposed the passphrase'

plaintext="$TMP/recovery-kit.txt"
printf 'test recovery kit\n' >"$plaintext"
transport_log="$TMP/transport.log"
run_encrypt_with_prompt() {
    local prompt_body="$1" out_file="$2"
    (
        cd "$ROOT"
        # shellcheck source=../lib/secrets.sh
        source "$ROOT/lib/secrets.sh"
        7zz() {
            case "${1:-}" in
                l)
                    cat <<'LISTING'
Type = zip
Method = AES-256 Deflate
----------
Path = recovery-kit.txt
LISTING
                    ;;
                t) return 1 ;;
                *) return 1 ;;
            esac
        }
        prompt_password_with_confirmation(){ eval "$prompt_body"; }
        _run_7zip_with_passphrase() {
            local secret="$1"
            shift 2
            printf '%s\n' "$secret" >>"$transport_log"
            [[ "$secret" != 'VWOCI-DELIBERATELY-WRONG-PASSPHRASE' ]] || return 1
            case " ${*} " in
              *' a '*) printf 'mock zip\n' >"$out_file"; return 0 ;;
              *' t '*) return 0 ;;
              *) return 1 ;;
            esac
        }
        export transport_log out_file
        _encrypt_recovery_kit_attachment "$plaintext" "$out_file" 7zz
    )
}
if run_encrypt_with_prompt 'return 1' "$TMP/rejected.zip"; then
    fail 'password-helper rejection must stop attachment creation'
fi
[[ ! -s "$TMP/rejected.zip" ]] \
    || fail 'rejected passphrase left a successful archive'
exact16='1234567890abcdef'
run_encrypt_with_prompt "printf %s '$exact16'" "$TMP/exact.zip" \
    || fail 'matching 16-character passphrase should be accepted'
longer='1234567890abcdefghi'
run_encrypt_with_prompt "printf %s '$longer'" "$TMP/long.zip" \
    || fail 'matching longer passphrase should be accepted'
grep -Fq "$exact16" "$transport_log" \
    || fail 'attachment helper did not pass the confirmed passphrase to the stdin transport'

real_tool=""
if command -v 7zz >/dev/null 2>&1; then
    real_tool=7zz
elif command -v 7z >/dev/null 2>&1; then
    real_tool=7z
fi
if [[ -n "$real_tool" ]]; then
    smoke_dir="$TMP/smoke"
    mkdir -p "$smoke_dir/out"
    printf 'real archive sentinel content\n' >"$smoke_dir/recovery-kit.txt"
    (
        cd "$ROOT"
        # shellcheck source=../lib/secrets.sh
        source "$ROOT/lib/secrets.sh"
        prompt_password_with_confirmation(){ printf '%s' 'NonProdTestPassphrase16'; }
        _encrypt_recovery_kit_attachment \
            "$smoke_dir/recovery-kit.txt" "$smoke_dir/kit.zip" "$real_tool"
        _run_7zip_with_passphrase 'NonProdTestPassphrase16' "$real_tool" \
            x -bd -y -p "-o$smoke_dir/out" -- "$smoke_dir/kit.zip" >/dev/null 2>&1
        if _run_7zip_with_passphrase 'WrongNonProdPassphrase16' "$real_tool" \
            t -bd -y -p -- "$smoke_dir/kit.zip" >/dev/null 2>&1; then
            exit 9
        fi
    ) || fail 'real AES-256 ZIP stdin smoke test failed'
    [[ -s "$smoke_dir/kit.zip" ]] || fail 'real AES-256 ZIP archive was not created'
    ! LC_ALL=C grep -aFq 'real archive sentinel content' "$smoke_dir/kit.zip" \
        || fail 'real AES-256 ZIP contains plaintext sentinel content'
    cmp "$smoke_dir/recovery-kit.txt" "$smoke_dir/out/recovery-kit.txt" \
        || fail 'real AES-256 ZIP extracted content mismatch'
else
    printf 'Real AES-256 ZIP stdin smoke test skipped: 7z/7zz unavailable.\n'
fi

printf 'Recovery-kit passphrase transport contract tests passed.\n'
)

if [[ "$MODE" == "core" || "$MODE" == "all" ]]; then
    check_recovery_kit_attachment_passphrase_contract
fi

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
cat > "$repo/lib/storage.sh" <<'MOCK_STORAGE'
require_project_state_ready(){ return 0; }
MOCK_STORAGE
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
    local signal_after="$1" output_file="$2" assume_yes="${3:-true}" rc=0
    local -a rotate_args=()
    [[ "$assume_yes" == "true" ]] && rotate_args+=(--yes)
    : > "$release_log"
    rm -f "$workdir_record"
    SECRETS_FILE="$secrets_file" \
    VW_TEST_ROOT="$rootfs" \
    VW_TEST_RELEASE_LOG="$release_log" \
    VW_TEST_WORKDIR_RECORD="$workdir_record" \
    VW_TEST_KEY_ROTATE_SIGNAL_AFTER="$signal_after" \
    PATH="$case_root/bin:$PATH" \
        bash "$repo/utilities/key-rotate.sh" "${rotate_args[@]}" </dev/null >"$output_file" 2>&1 || rc=$?
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

ack_rc="$(run_full_rotation '' "$case_root/ack-eof.out" false)"
[[ "$ack_rc" == '0' ]] \
    || { cat "$case_root/ack-eof.out" >&2; fail "committed rotation returned $ack_rc when acknowledgement input ended"; }
grep -Fq 'Age key rotation is already committed; offline-copy acknowledgement was not received.' "$case_root/ack-eof.out" \
    || fail 'committed rotation did not distinguish incomplete acknowledgement from transaction failure'
mapfile -t ack_releases < "$release_log"
[[ "${#ack_releases[@]}" -eq 1 && "${ack_releases[0]}" == '0' ]] \
    || fail 'committed rotation released the operation guard as a failure after acknowledgement EOF'

printf 'Full key-rotation entrypoint rollback, cleanup, guard-release, retry, and post-commit acknowledgement tests passed.\n'
)

check_sensitive_cleanup_contracts() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
cd "$ROOT"
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS %s\n' "$*"; }

# Integration and systemd contracts.
grep -Fq 'cleanup_expired_recovery_kits "$DRY_RUN" || recovery_cleanup_result=$?' \
  utilities/maintenance-run.sh || fail "maintenance does not invoke recovery fallback cleanup"
grep -Fq '"$health_validation_result" "$_maint_duration_seconds" "$recovery_cleanup_result"' \
  utilities/maintenance-run.sh || fail "maintenance does not pass recovery cleanup into canonical final status"
grep -Fq 'ReadWritePaths=-/root/vaultwarden-recovery' \
  systemd/vaultwarden-maintenance.service || fail "maintenance sandbox lacks exact recovery path"
grep -Fq 'OnCalendar=*-*-* 02:05:00' systemd/vaultwarden-maintenance.timer \
  || fail "maintenance timer schedule changed"
grep -Fq 'Persistent=false' systemd/vaultwarden-maintenance.timer \
  || fail "maintenance timer persistence changed"
if find systemd -maxdepth 1 -type f \
  \( -name 'vaultwarden-recovery-cleanup.service' -o -name 'vaultwarden-recovery-cleanup.timer' \) \
  -print -quit | grep -q .; then
  fail "a separate recovery cleanup unit was added"
fi

cleanup_helpers="$(sed -n '/^_remove_sensitive_file() {/,/^_prepare_recovery_dir() {/p' lib/secrets.sh | sed '$d')"
[[ "$cleanup_helpers" == *'cleanup_expired_recovery_kits()'* ]] \
  || fail "recovery cleanup helper block is missing"

if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  fixture="$(mktemp -d)"
  trap 'sudo -n /bin/rm -rf -- "$fixture" >/dev/null 2>&1 || true' EXIT
  sudo -n chown root:root "$fixture"
  sudo -n chmod 0700 "$fixture"
  sudo -n env \
    RECOVERY_KIT_DIR="$fixture" \
    VW_TEST_MODE=true \
    VW_RECOVERY_CLEANUP_MIN_AGE_SECONDS=60 \
    CLEANUP_HELPERS="$cleanup_helpers" \
    bash -s <<'ROOT_TEST' || fail "recovery cleanup behavior failed"
set -euo pipefail
log_debug() { :; }
log_info() { printf 'INFO %s\n' "$*"; }
log_warn() { printf 'WARN %s\n' "$*" >&2; }
log_error() { printf 'ERROR %s\n' "$*" >&2; }
eval "$CLEANUP_HELPERS"

make_file() {
  local path="$1" content="${2:-x}"
  printf '%s' "$content" > "$path"
  chmod 0600 "$path"
}
old="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120000Z-a1b2c3.txt"
young="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120001Z-a1b2c4.txt"
wrong_mode="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120002Z-a1b2c5.txt"
wrong_owner="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120003Z-a1b2c6.txt"
link="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120004Z-a1b2c7.txt"
target="$RECOVERY_KIT_DIR/target"
dir_candidate="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120005Z-a1b2c8.txt"
fifo_candidate="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120006Z-a1b2c9.txt"
hard="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120007Z-a1b2ca.txt"
hard_peer="$RECOVERY_KIT_DIR/hard-peer"
metachar="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120008Z-a1b2cb;touch-PWNED.txt"
nonmatching="$RECOVERY_KIT_DIR/unrelated.txt"
handoff="$RECOVERY_KIT_DIR/vaultwarden-setup-credentials-20260727T120000Z.txt"
zip_file="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120000Z-a1b2c3.zip"

make_file "$old" 'SECRET-MUST-NOT-APPEAR'
make_file "$young"
make_file "$wrong_mode"
chmod 0644 "$wrong_mode"
make_file "$wrong_owner"
chown 65534:65534 "$wrong_owner"
make_file "$target"
ln -s "$target" "$link"
mkdir "$dir_candidate"
mkfifo "$fifo_candidate"
make_file "$hard"
ln "$hard" "$hard_peer"
make_file "$metachar"
make_file "$nonmatching"
make_file "$handoff"
make_file "$zip_file"
touch -d '120 seconds ago' "$old" "$wrong_mode" "$wrong_owner" "$link" \
  "$dir_candidate" "$fifo_candidate" "$hard" "$metachar"

set +e
dry_output="$(cleanup_expired_recovery_kits true 2>&1)"
dry_rc=$?
set -e
(( dry_rc != 0 )) || exit 1
[[ -f "$old" ]] || exit 1
[[ "$dry_output" == *'[DRY RUN] Would remove expired plaintext recovery kit:'* ]] || exit 1
[[ "$dry_output" != *'SECRET-MUST-NOT-APPEAR'* ]] || exit 1

set +e
output="$(cleanup_expired_recovery_kits false 2>&1)"
rc=$?
set -e
(( rc != 0 )) || exit 1
[[ ! -e "$old" ]] || exit 1
[[ -e "$young" && -e "$wrong_mode" && -e "$wrong_owner" ]] || exit 1
[[ -L "$link" && -e "$target" && -d "$dir_candidate" && -p "$fifo_candidate" ]] || exit 1
[[ -e "$hard" && -e "$hard_peer" && -e "$metachar" ]] || exit 1
[[ -e "$nonmatching" && -e "$handoff" && -e "$zip_file" ]] || exit 1
[[ "$output" != *'SECRET-MUST-NOT-APPEAR'* ]] || exit 1
[[ ! -e "$RECOVERY_KIT_DIR/touch-PWNED.txt" ]] || exit 1

/bin/rm -f -- "$wrong_mode" "$wrong_owner" "$link" "$fifo_candidate" \
  "$hard" "$hard_peer" "$metachar" "$young" "$nonmatching" "$handoff" "$zip_file" "$target"
rmdir -- "$dir_candidate"
cleanup_expired_recovery_kits false

# Best-effort overwrite failure still falls back to unlink.
old2="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T121000Z-a1b2cc.txt"
make_file "$old2"
touch -d '120 seconds ago' "$old2"
shim_dir="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 1\n' > "$shim_dir/shred"
chmod 0755 "$shim_dir/shred"
PATH="$shim_dir:$PATH" cleanup_expired_recovery_kits false
[[ ! -e "$old2" ]] || exit 1
/bin/rm -rf -- "$shim_dir"

# A complete removal failure is reported and leaves the file in place.
old3="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T121100Z-a1b2cd.txt"
make_file "$old3"
touch -d '120 seconds ago' "$old3"
original_remove="$(declare -f _remove_sensitive_file)"
_remove_sensitive_file() { return 1; }
set +e
cleanup_expired_recovery_kits false >/dev/null 2>&1
rc=$?
set -e
(( rc != 0 )) || exit 1
[[ -e "$old3" ]] || exit 1
eval "$original_remove"
/bin/rm -f -- "$old3"

# A changed identity is never deleted.
race="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T121200Z-a1b2ce.txt"
make_file "$race"
touch -d '120 seconds ago' "$race"
real_stat="$(command -v stat)"
stat_counter="$RECOVERY_KIT_DIR/.stat-counter"
printf '0\n' > "$stat_counter"
stat() {
  local last="${!#}" count
  if [[ "$last" == "$race" && "${1:-}" == "-c" ]]; then
    count="$(cat "$stat_counter")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$stat_counter"
    if (( count == 2 )); then
      "$real_stat" "$@" | awk -F: 'BEGIN{OFS=":"} {$2=$2+1; print}'
      return 0
    fi
  fi
  "$real_stat" "$@"
}
set +e
cleanup_expired_recovery_kits false >/dev/null 2>&1
rc=$?
set -e
unset -f stat
(( rc != 0 )) || exit 1
[[ -e "$race" ]] || exit 1
/bin/rm -f -- "$race" "$stat_counter"

# Enumeration failure is visible, returns nonzero, and processes no partial list.
enum_fail="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T121300Z-a1b2cf.txt"
make_file "$enum_fail"
touch -d '120 seconds ago' "$enum_fail"
real_find="$(command -v find)"
find() {
  if [[ "$*" == *"vaultwarden-recovery-kit-*.txt"* ]]; then
    return 73
  fi
  "$real_find" "$@"
}
set +e
enum_output="$(cleanup_expired_recovery_kits false 2>&1)"
enum_rc=$?
set -e
unset -f find
(( enum_rc != 0 )) || exit 1
[[ -e "$enum_fail" ]] || exit 1
[[ "$enum_output" == *"failed to enumerate recovery-kit candidates"* ]] || exit 1
[[ "$enum_output" != *"Removed expired plaintext recovery kit"* ]] || exit 1
/bin/rm -f -- "$enum_fail"
# An absent test directory is an idempotent no-op and is not created.
absent="${RECOVERY_KIT_DIR}.absent"
RECOVERY_KIT_DIR="$absent" cleanup_expired_recovery_kits false
[[ ! -e "$absent" ]] || exit 1
ROOT_TEST
else
  printf 'SKIP root-owned recovery fixture: passwordless sudo unavailable\n'
fi

# Direct configure uses its installed TERM trap to clean the owned workspace.
direct_workspace_helpers="$(
  sed -n \
    '/^unset TMP_WORKDIR$/,/^trap '\''_setup_secrets_on_signal 143'\'' TERM$/p' \
    utilities/setup-secrets.sh
)"
[[ -n "$direct_workspace_helpers" ]] \
  || fail "direct sensitive-workspace helpers could not be extracted"
direct_signal_fixture="$(mktemp -d)"
direct_signal_marker="$direct_signal_fixture/workspace.path"
direct_runtime_tmp="$direct_signal_fixture/runtime-tmp"
set +e
DIRECT_WORKSPACE_HELPERS="$direct_workspace_helpers" \
DIRECT_SIGNAL_MARKER="$direct_signal_marker" \
VW_SETUP_SECRETS_TMP_DIR="$direct_runtime_tmp" \
PROJECT_ROOT="$direct_signal_fixture" \
bash -s <<'DIRECT_SIGNAL_TEST' >/dev/null 2>&1
set -euo pipefail
log_warn() { printf 'WARN %s\n' "$*" >&2; }
cleanup_secrets_environment() { return 0; }
operation_release() { return 0; }
_ss_plain_tmp_dir() { printf '%s' "$VW_SETUP_SECRETS_TMP_DIR"; }
_ss_prepare_plain_tmp_dir() { mkdir -p "$VW_SETUP_SECRETS_TMP_DIR"; chmod 0700 "$VW_SETUP_SECRETS_TMP_DIR"; }
eval "$DIRECT_WORKSPACE_HELPERS"
_setup_secrets_create_workdir
[[ "$SETUP_SECRETS_OWNED_WORKDIR" == "$VW_SETUP_SECRETS_TMP_DIR"/* ]]
printf '%s' "$SETUP_SECRETS_OWNED_WORKDIR" > "$DIRECT_SIGNAL_MARKER"
printf '%s' 'DIRECT-SIGNAL-SECRET' > "$SETUP_SECRETS_OWNED_WORKDIR/capture"
kill -TERM "$BASHPID"
exit 99
DIRECT_SIGNAL_TEST
direct_signal_rc=$?
set -e
direct_signal_workspace="$(cat "$direct_signal_marker")"
[[ "$direct_signal_rc" == 143 ]] \
  || fail "direct TERM path returned $direct_signal_rc instead of 143"
[[ ! -e "$direct_signal_workspace" ]] \
  || fail "direct TERM path left the sensitive workspace behind"
/bin/rm -rf -- "$direct_signal_fixture"

# Top-level setup creates one private workspace only when credential capture starts.
setup_workspace_helpers="$(
  sed -n \
    '/^unset VW_ADMIN_PLAIN_FILE/,/^trap '\''_setup_on_signal 143'\'' TERM$/p' \
    setup.sh
)"
[[ -n "$setup_workspace_helpers" ]] \
  || fail "top-level sensitive-workspace helpers could not be extracted"
SETUP_WORKSPACE_HELPERS="$setup_workspace_helpers" bash -s <<'TOP_LEVEL_WORKSPACE_TEST' \
  || fail "top-level lazy sensitive-workspace lifecycle failed"
set -euo pipefail
fixture="$(mktemp -d)"
trap '/bin/rm -rf -- "$fixture"' EXIT
TMPDIR="$fixture/tmp"
mkdir -p "$TMPDIR"
log_warn() { printf 'WARN %s\n' "$*" >&2; }
operation_release() { return 0; }
eval "$SETUP_WORKSPACE_HELPERS"
trap - EXIT INT HUP TERM

! find "$TMPDIR" -maxdepth 1 -name 'vw_setup.*' -print -quit | grep -q .
_setup_create_sensitive_workspace
workspace="$TMP_WORKDIR"
[[ -d "$workspace" && "$(stat -c '%a' "$workspace")" == "700" ]]
for capture in \
  "$VW_ADMIN_PLAIN_FILE" "$VW_ADMIN_HASH_FILE" \
  "$CADDY_PLAIN_FILE" "$CADDY_HASH_FILE"; do
  [[ "${capture%/*}" == "$workspace" ]]
done
printf '%s' 'TOP-LEVEL-PLAINTEXT-DO-NOT-LEAK' > "$VW_ADMIN_PLAIN_FILE"
_setup_remove_sensitive_workspace 0
[[ ! -e "$workspace" ]]

_setup_create_sensitive_workspace
blocked_workspace="$TMP_WORKDIR"
printf '%s' 'TOP-LEVEL-FAILURE-SECRET' > "$VW_ADMIN_PLAIN_FILE"
rm() {
  local last="${!#}"
  [[ "$last" == "$blocked_workspace" ]] && return 73
  command rm "$@"
}
set +e
failure_output="$({ set -x; _setup_remove_sensitive_workspace 0; } 2>&1)"
failure_rc=$?
set -e
[[ "$failure_rc" == 73 ]]
[[ -d "$blocked_workspace" ]]
[[ "$failure_output" == *"Failed to remove the setup sensitive workspace"* ]]
[[ "$failure_output" != *'TOP-LEVEL-FAILURE-SECRET'* ]]
set +e
_setup_remove_sensitive_workspace 42 >/dev/null 2>&1
original_rc=$?
set -e
[[ "$original_rc" == 42 ]]
unset -f rm
/bin/rm -rf -- "$blocked_workspace"
unset TMP_WORKDIR VW_ADMIN_PLAIN_FILE VW_ADMIN_HASH_FILE CADDY_PLAIN_FILE CADDY_HASH_FILE

signal_marker="$fixture/top-level-signal-workspace.path"
set +e
SETUP_WORKSPACE_HELPERS="$SETUP_WORKSPACE_HELPERS" \
TOP_LEVEL_SIGNAL_MARKER="$signal_marker" \
TMPDIR="$TMPDIR" \
bash -s <<'TOP_LEVEL_SIGNAL_TEST' >/dev/null 2>&1
set -euo pipefail
log_warn() { printf 'WARN %s\n' "$*" >&2; }
operation_release() { return 0; }
eval "$SETUP_WORKSPACE_HELPERS"
_setup_create_sensitive_workspace
printf '%s' "$TMP_WORKDIR" > "$TOP_LEVEL_SIGNAL_MARKER"
printf '%s' 'TOP-LEVEL-SIGNAL-SECRET' > "$VW_ADMIN_PLAIN_FILE"
kill -TERM "$BASHPID"
exit 99
TOP_LEVEL_SIGNAL_TEST
signal_rc=$?
set -e
signal_workspace="$(cat "$signal_marker")"
[[ "$signal_rc" == 143 ]]
[[ ! -e "$signal_workspace" ]]
/bin/rm -rf -- "$fixture"
trap - EXIT
TOP_LEVEL_WORKSPACE_TEST

# Ubuntu 7zip package and executable-selection contracts.
# Exact apt dependency-array tokenization contract.
python3 - <<'PY_PACKAGES' \
  || fail "dependency package array tokenization contract failed"
from pathlib import Path
import re
import shlex

expected = [
    "age", "make", "nano", "rclone", "sqlite3", "jq", "ufw", "curl",
    "wget", "unzip", "7zip", "git", "gpg", "coreutils", "util-linux",
    "haveged", "dnsutils", "rsync", "python3", "python3-argon2",
    "python3-bcrypt", "python3-yaml", "apache2-utils", "cron", "openssl",
    "tar", "zstd",
]
text = Path("utilities/setup-system.sh").read_text(encoding="utf-8")
matches = re.findall(
    r"(?m)^[ \t]*local basic_packages=\((.*)\)[ \t]*$",
    text,
)
if len(matches) != 1:
    raise SystemExit(
        f"expected one basic_packages declaration, found {len(matches)}"
    )
actual = shlex.split(matches[0], posix=True)
if actual != expected:
    raise SystemExit(
        "basic_packages tokenization mismatch:\n"
        f"expected={expected!r}\nactual={actual!r}"
    )
PY_PACKAGES
grep -Fq '"unzip" "7zip" "git"' utilities/setup-system.sh \
  || fail "normal dependency list does not install Ubuntu 7zip"
grep -Fq '"dnsutils" "rsync" "python3" "python3-argon2"' utilities/setup-system.sh \
  || fail "dependency list must keep rsync and python3 as separate package entries"
! grep -Fq '"rsync""python3"' utilities/setup-system.sh \
  || fail "dependency list contains a concatenated rsync/python3 package token"
! grep -Eq '^[[:space:]]*\[7zip\]=' utilities/setup-system.sh \
  || fail "generic dependency map must not claim one guaranteed 7-Zip executable"
grep -Fq 'for candidate in 7zz 7z; do' utilities/setup-system.sh \
  || fail "setup dependency resolver does not prefer 7zz with 7z fallback"
grep -Fq '_require_7zip_command || return 1' utilities/setup-system.sh \
  || fail "--skip-deps verification does not require a usable 7-Zip executable"
grep -Fq 'Install hint: sudo apt-get install -y 7zip' utilities/setup-system.sh \
  || fail "setup-system 7zip installation guidance is incorrect"
grep -Fq 'sudo apt-get install -y docker.io age sops 7zip python3-argon2 python3-bcrypt' setup.sh \
  || fail "top-level setup phase guidance omits 7zip"
grep -Fq 'for candidate in 7zz 7z; do' lib/secrets.sh \
  || fail "recovery ZIP helper does not prefer 7zz with 7z fallback"
grep -Fq 'a -tzip -mem=AES256' lib/secrets.sh \
  || fail "recovery artifact is no longer an AES-256 encrypted ZIP"
resolver_block="$(sed -n '/^_resolve_7zip_command() {/,/^# Install the required system packages/p' utilities/setup-system.sh | sed '$d')"
[[ -n "$resolver_block" ]] || fail "7zip resolver block could not be extracted"
RESOLVER_BLOCK="$resolver_block" bash -s <<'SEVENZIP_TEST' \
  || fail "7zip executable resolution tests failed"
set -euo pipefail
log_error() { printf 'ERROR %s\n' "$*" >&2; }
log_info() { printf 'INFO %s\n' "$*" >&2; }
log_debug() { :; }
eval "$RESOLVER_BLOCK"
fixture="$(mktemp -d)"
trap '/bin/rm -rf -- "$fixture"' EXIT
make_cmd() {
  local dir="$1" name="$2"
  mkdir -p -- "$dir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/$name"
  chmod 0755 "$dir/$name"
}
preferred="$fixture/preferred"
make_cmd "$preferred" 7zz
[[ "$(PATH="$preferred" _resolve_7zip_command)" == 7zz ]]
PATH="$preferred" _require_7zip_command
both="$fixture/both"
make_cmd "$both" 7zz
make_cmd "$both" 7z
[[ "$(PATH="$both" _resolve_7zip_command)" == 7zz ]]
PATH="$both" _require_7zip_command
fallback="$fixture/fallback"
make_cmd "$fallback" 7z
[[ "$(PATH="$fallback" _resolve_7zip_command)" == 7z ]]
PATH="$fallback" _require_7zip_command
empty="$fixture/empty"
mkdir -p -- "$empty"
set +e
missing_output="$(PATH="$empty" _require_7zip_command 2>&1)"
missing_rc=$?
set -e
(( missing_rc != 0 ))
[[ "$missing_output" == *"expected 7zz (preferred) or 7z"* ]]
[[ "$missing_output" == *"sudo apt-get install -y 7zip"* ]]
/bin/rm -rf -- "$fixture"
trap - EXIT
SEVENZIP_TEST
python3 - <<'PY_ORDER' || fail "success-summary ordering is unsafe"
from pathlib import Path
setup = Path('setup.sh').read_text()
secrets = Path('utilities/setup-secrets.sh').read_text()
start = setup.index('credential_file="$(publish_setup_credentials')
assert setup.index('_setup_remove_sensitive_workspace 0', start) < setup.index('│  SETUP CREDENTIALS SAVED', start)
start = secrets.index('_ss_publish_auto_handoff || return 1')
assert secrets.index('_ss_perform_cleanup 0', start) < secrets.index('Secrets Setup Complete!', start)
PY_ORDER

pass "recovery fallback and sensitive cleanup contracts"

check_setup_failure_gates() (
set -euo pipefail

if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; then
  if [[ "${CI:-false}" == "true" || "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    fail "mandatory setup failure-gate regressions require passwordless sudo in CI"
  fi
  printf 'SKIP setup failure gates: passwordless sudo unavailable\n'
  exit 0
fi

setup_tmp="$(mktemp -d)"
trap 'sudo -n rm -rf -- "$setup_tmp" >/dev/null 2>&1 || true' EXIT INT TERM HUP
setup_fixture="$setup_tmp/repo"
mkdir -p "$setup_fixture"
tar --exclude='./.git' --exclude='./test-results' -cf - . | tar -xf - -C "$setup_fixture"
cat > "$setup_fixture/lib/validate.sh" <<'EOF_SETUP_VALIDATE'
validate_domain() { return 0; }
validate_email() { return 0; }
EOF_SETUP_VALIDATE

setup_invocations="$setup_tmp/invocations.log"
: > "$setup_invocations"
chmod 0666 "$setup_invocations"
cat > "$setup_tmp/utility-stub" <<'EOF_SETUP_STUB'
#!/usr/bin/env bash
set -euo pipefail
name="$(basename "$0")"
printf '%s:%s\n' "$name" "$*" >> "${VW_TEST_INVOCATION_LOG:?}"
case "$name" in
  setup-firewall.sh)
    if [[ " $* " == *" --phase ufw "* && "${VW_TEST_FAIL_UFW:-0}" == "1" ]]; then
      exit 42
    fi
    ;;
  setup-secrets.sh)
    if [[ "${1:-}" == "configure" && "${VW_TEST_FAIL_SECRETS:-0}" == "1" ]]; then
      exit 43
    fi
    ;;
esac
EOF_SETUP_STUB
chmod 0755 "$setup_tmp/utility-stub"
for utility in \
  setup-system.sh setup-storage.sh setup-env.sh setup-secrets.sh \
  setup-firewall.sh setup-systemd.sh setup-crowdsec.sh uninstall-vaultwarden.sh; do
  cp "$setup_tmp/utility-stub" "$setup_fixture/utilities/$utility"
  chmod 0755 "$setup_fixture/utilities/$utility"
done

run_setup_failure() {
  local label="$1" fail_ufw="$2" fail_secrets="$3" output rc
  : > "$setup_invocations"
  rm -rf "$setup_tmp/recovery"
  set +e
  output="$(
    sudo -n env \
      VW_TEST_INVOCATION_LOG="$setup_invocations" \
      VW_TEST_FAIL_UFW="$fail_ufw" \
      VW_TEST_FAIL_SECRETS="$fail_secrets" \
      SETUP_CREDENTIALS_DIR="$setup_tmp/recovery" \
      ENTROPY_THRESHOLD=0 \
      bash "$setup_fixture/setup.sh" install \
        --domain vault.example.com \
        --email admin@example.com \
        --auto --skip-deps 2>&1
  )"
  rc=$?
  set -e
  (( rc != 0 )) || fail "$label unexpectedly returned success"
  [[ "$output" != *"SETUP CREDENTIALS SAVED"* ]] \
    || fail "$label printed credential-publication success"
  [[ ! -e "$setup_tmp/recovery" ]] || {
    ! find "$setup_tmp/recovery" -type f \
      -name 'vaultwarden-setup-credentials-*' -print -quit | grep -q . \
      || fail "$label published a setup credential handoff"
  }
  printf '%s' "$output"
}

ufw_output="$(run_setup_failure "UFW failure" 1 0)"
[[ "$ufw_output" == *"Phase 5"* ]] || fail "UFW failure did not identify phase 5"
! grep -q 'setup-firewall.sh:--phase iptables' "$setup_invocations" \
  || fail "iptables phase ran after required UFW failure"
! grep -q 'setup-secrets.sh:configure' "$setup_invocations" \
  || fail "secrets configuration ran after required UFW failure"

secrets_output="$(run_setup_failure "automatic secrets failure" 0 1)"
[[ "$secrets_output" == *"Phase 6"* ]] \
  || fail "automatic secrets failure did not identify phase 6"
grep -q 'setup-secrets.sh:configure' "$setup_invocations" \
  || fail "automatic secrets configure stub was not invoked"

# Automatic dry-run must reach secrets configuration without allocating or publishing plaintext state.
dry_tmp="$setup_tmp/dry-run-tmp"
mkdir -p "$dry_tmp"
: > "$setup_invocations"
rm -rf "$setup_tmp/recovery"
set +e
dry_output="$(
  sudo -n env \
    TMPDIR="$dry_tmp" \
    VW_TEST_INVOCATION_LOG="$setup_invocations" \
    VW_TEST_FAIL_UFW=0 \
    VW_TEST_FAIL_SECRETS=0 \
    SETUP_CREDENTIALS_DIR="$setup_tmp/recovery" \
    ENTROPY_THRESHOLD=0 \
    bash "$setup_fixture/setup.sh" install \
      --domain vault.example.com \
      --email admin@example.com \
      --auto --skip-deps --dry-run 2>&1
)"
dry_rc=$?
set -e
(( dry_rc == 0 )) || fail "automatic setup dry-run failed: $dry_output"
grep -q 'setup-secrets.sh:configure .*--dry-run' "$setup_invocations" \
  || fail "automatic setup dry-run did not delegate dry-run to secrets configuration"
! find "$dry_tmp" -mindepth 1 -maxdepth 1 -name 'vw_setup.*' -print -quit | grep -q . \
  || fail "automatic setup dry-run created a sensitive workspace"
[[ ! -e "$setup_tmp/recovery" ]] || {
  ! find "$setup_tmp/recovery" -type f \
    -name 'vaultwarden-setup-credentials-*' -print -quit | grep -q . \
    || fail "automatic setup dry-run published a credential handoff"
}
)
check_setup_failure_gates
pass "behavioral setup failure gates and dry-run safety"

# Exercise the real direct command parser and orchestration under a PTY with
# deterministic synthetic values. Host-output boundaries are replaced only in
# a copied fixture; production source remains unchanged.
if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
(
  direct_tmp="$(mktemp -d)"
  trap 'sudo -n rm -rf -- "$direct_tmp" >/dev/null 2>&1 || true' EXIT INT TERM HUP
  direct_fixture="$direct_tmp/repo"
  mkdir -p "$direct_fixture"
  tar --exclude='./.git' --exclude='./test-results' --exclude='./vw_tmp.*' \
    -cf - . | tar -xf - -C "$direct_fixture"

  direct_bin="$direct_tmp/bin"
  direct_state="$direct_tmp/state"
  success_dir="$direct_tmp/recovery-success"
  failure_target="$direct_tmp/recovery-not-a-directory"
  counter_file="$direct_tmp/generator-counter"
  workspace_mode_file="$direct_tmp/workspace.mode"
  mkdir -p "$direct_bin" "$direct_state" "$success_dir"
  chmod 0700 "$direct_state" "$success_dir"
  printf '0\n' > "$counter_file"
  chmod 0666 "$counter_file"
  printf 'publication must fail here\n' > "$failure_target"

  public_recipient="age1$(printf 'q%.0s' {1..58})"
  age_key_file="$direct_tmp/age-key.txt"
  {
    printf '# AGE-SECRET-KEY-TEST-DO-NOT-LEAK\n'
    printf '%s\n' 'AGE-SECRET-KEY-1SYNTHETIC-DIRECT-AUTO-ONLY'
  } > "$age_key_file"
  chmod 0600 "$age_key_file"

  cat > "$direct_fixture/.env" <<EOF_DIRECT_ENV
PROJECT_STATE_DIR=$direct_state
SOPS_AGE_KEY_FILE=
EMAIL_MODE=api
EMAIL_PROVIDER=mailersend
PUSH_ENABLED=false
EOF_DIRECT_ENV
  chmod 0600 "$direct_fixture/.env"
  cat > "$direct_fixture/.sops.yaml" <<EOF_DIRECT_SOPS
creation_rules:
  - path_regex: '.*\\.yaml$'
    age: "$public_recipient"
EOF_DIRECT_SOPS

  cat >> "$direct_fixture/lib/config.sh" <<'EOF_DIRECT_CONFIG'
load_project_environment() {
  PROJECT_STATE_DIR="${VW_TEST_PROJECT_STATE_DIR:?}"
  SOPS_AGE_KEY_FILE="${VW_TEST_AGE_KEY_FILE:?}"
  SECRETS_FILE="${PROJECT_STATE_DIR}/secrets/secrets.yaml"
  export PROJECT_STATE_DIR SOPS_AGE_KEY_FILE SECRETS_FILE
}
EOF_DIRECT_CONFIG
  cat >> "$direct_fixture/lib/operations.sh" <<'EOF_DIRECT_OPERATIONS'
operation_acquire() { return 0; }
operation_release() { return 0; }
operation_set_phase() { return 0; }
EOF_DIRECT_OPERATIONS
  cat >> "$direct_fixture/lib/secrets.sh" <<'EOF_DIRECT_SECRETS'
schema_validate() { return 0; }
schema_keys() { printf '%s\n' admin_token admin_basic_auth_hash file_integrity_hmac_key; }
schema_collect_type() {
  case "$1" in
    file_integrity_hmac_key) printf '%s' auto ;;
    *) printf '%s' manual ;;
  esac
}
schema_field_safe() {
  case "$1:$2" in
    file_integrity_hmac_key:auto_fn) printf '%s' auto_generate_secret_field ;;
    *:label) printf '%s' 'Synthetic test field' ;;
    *) printf '%s' '' ;;
  esac
}
generate_secure_string() {
  local requested="$1" next
  if [[ "$requested" == "64" ]]; then
    printf '%s' 'TEST-INTEGRITY-HMAC-NOT-A-HANDOFF-PASSWORD'
    return 0
  fi
  if [[ -n "${VW_ADMIN_PLAIN_FILE:-}" ]]; then
    stat -c '%a' "$(dirname "$VW_ADMIN_PLAIN_FILE")" \
      > "${VW_TEST_WORKSPACE_MODE_FILE:?}"
  fi
  next="$(( $(cat "${VW_TEST_COUNTER_FILE:?}") + 1 ))"
  printf '%s\n' "$next" > "${VW_TEST_COUNTER_FILE}"
  case "$next" in
    1) printf '%s' 'TEST-VW-PLAINTEXT-DO-NOT-LEAK' ;;
    2) printf '%s' 'TEST-CADDY-PLAINTEXT-DO-NOT-LEAK' ;;
    *) return 1 ;;
  esac
}
generate_argon2_hash() { printf '%s' 'TEST-VW-ARGON2-HASH'; }
generate_bcrypt_hash() { printf '%s' 'TEST-CADDY-BCRYPT-HASH'; }
_bcrypt_format_ok() { return 0; }
check_age_key() { return 0; }
check_argon2_support() { return 0; }
get_age_public_key() { printf '%s' "${VW_TEST_PUBLIC_RECIPIENT:?}"; }
secrets_file_exists() { return 1; }
check_placeholder_values() { return 0; }
ensure_sops_env() {
  export SOPS_AGE_KEY_FILE="${VW_TEST_AGE_KEY_FILE:?}"
  export SOPS_CONFIG="${PROJECT_ROOT}/.sops.yaml"
}
cleanup_secrets_environment() { unset SOPS_AGE_KEY_FILE SOPS_CONFIG; }
secure_secrets_file() { chmod 0600 "$1"; }
export_docker_secrets() { return 0; }
prepare_push_secret_placeholders() { return 0; }
EOF_DIRECT_SECRETS
  cat >> "$direct_fixture/lib/setup-credentials.sh" <<'EOF_DIRECT_HANDOFF'
_setup_handoff_verify_argon2() { return 0; }
_setup_handoff_verify_bcrypt() { return 0; }
EOF_DIRECT_HANDOFF

  cat > "$direct_bin/age-keygen" <<'EOF_DIRECT_AGE'
#!/usr/bin/env bash
printf '%s\n' "${VW_TEST_PUBLIC_RECIPIENT:?}"
EOF_DIRECT_AGE
  cat > "$direct_bin/yq" <<'EOF_DIRECT_YQ'
#!/usr/bin/env bash
printf '%s\n' "${VW_TEST_PUBLIC_RECIPIENT:?}"
EOF_DIRECT_YQ
  cat > "$direct_bin/sops" <<'EOF_DIRECT_SOPS_BIN'
#!/usr/bin/env bash
set -euo pipefail
output=""
input="${!#}"
for (( index=1; index<=$#; index++ )); do
  arg="${!index}"
  if [[ "$arg" == "--output" ]]; then
    next=$((index + 1))
    output="${!next}"
  elif [[ "$arg" == "updatekeys" ]]; then
    exit 0
  fi
done
if [[ " $* " == *" --encrypt "* ]]; then
  cp "$input" "$output"
elif [[ " $* " == *" -d "* ]]; then
  cat "$input"
fi
EOF_DIRECT_SOPS_BIN
  cat > "$direct_bin/install" <<'EOF_DIRECT_INSTALL'
#!/usr/bin/env bash
if [[ " $* " == *" /run/vaultwarden-oci/secrets "* ]]; then
  exit 0
fi
exec "${VW_TEST_REAL_INSTALL:?}" "$@"
EOF_DIRECT_INSTALL
  for command_name in age jq htpasswd; do
    cat > "$direct_bin/$command_name" <<'EOF_DIRECT_COMMAND'
#!/usr/bin/env bash
exit 0
EOF_DIRECT_COMMAND
  done
  chmod 0755 "$direct_bin"/*

  pty_runner="$direct_tmp/run-under-pty.py"
  cat > "$pty_runner" <<'PY_DIRECT_PTY'
#!/usr/bin/env python3
import os
import pty
import sys

stdout_path, stderr_path, pty_path = sys.argv[1:4]
command = sys.argv[4:]
pid, master = pty.fork()
if pid == 0:
    stdout_fd = os.open(stdout_path, os.O_WRONLY | os.O_TRUNC)
    stderr_fd = os.open(stderr_path, os.O_WRONLY | os.O_TRUNC)
    os.dup2(stdout_fd, 1)
    os.dup2(stderr_fd, 2)
    os.execvp(command[0], command)
with open(pty_path, "wb") as pty_output:
    while True:
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        pty_output.write(chunk)
os.close(master)
_, status = os.waitpid(pid, 0)
raise SystemExit(os.waitstatus_to_exitcode(status))
PY_DIRECT_PTY
  chmod 0755 "$pty_runner"

  assert_secret_free_streams() {
    local label="$1" stream marker
    for stream in "$direct_stdout" "$direct_stderr" "$direct_pty"; do
      for marker in \
        'TEST-VW-PLAINTEXT-DO-NOT-LEAK' \
        'TEST-CADDY-PLAINTEXT-DO-NOT-LEAK' \
        'AGE-SECRET-KEY-TEST-DO-NOT-LEAK'; do
        ! grep -Fq "$marker" "$stream" \
          || fail "$label leaked $marker through $(basename "$stream")"
      done
    done
  }

  assert_direct_temps_clean() {
    ! find "$direct_fixture" -maxdepth 1 -name 'vw_tmp.*' -print -quit | grep -q . \
      || fail "$1 left its credential workspace behind"
    if sudo -n test -d "$direct_tmp/plaintext-stage"; then
      ! sudo -n find "$direct_tmp/plaintext-stage" -type f -print -quit | grep -q . \
        || fail "$1 left its plaintext SOPS staging file behind"
    fi
  }

  run_direct_case() {
    local label="$1" handoff_target="$2"
    direct_stdout="$direct_tmp/$label.stdout"
    direct_stderr="$direct_tmp/$label.stderr"
    direct_pty="$direct_tmp/$label.pty"
    : > "$direct_stdout"
    : > "$direct_stderr"
    : > "$direct_pty"
    : > "$workspace_mode_file"
    chmod 0666 "$direct_stdout" "$direct_stderr" "$workspace_mode_file"
    printf '0\n' > "$counter_file"
    set +e
    python3 "$pty_runner" "$direct_stdout" "$direct_stderr" "$direct_pty" \
      sudo -n /usr/bin/env \
        "PATH=$direct_bin:$PATH" \
        "OFFLINE_AGE_RECIPIENT=$public_recipient" \
        "PROJECT_STATE_DIR=$direct_state" \
        "AGE_KEY_FILE=$age_key_file" \
        "SOPS_AGE_KEY_FILE=$age_key_file" \
        "SETUP_CREDENTIALS_DIR=$handoff_target" \
        "VW_HANDOFF_TEST_MODE=true" \
        "VW_TEST_AGE_KEY_FILE=$age_key_file" \
        "VW_TEST_COUNTER_FILE=$counter_file" \
        "VW_TEST_PROJECT_STATE_DIR=$direct_state" \
        "VW_TEST_PUBLIC_RECIPIENT=$public_recipient" \
        "VW_TEST_REAL_INSTALL=$(command -v install)" \
        "VW_TEST_WORKSPACE_MODE_FILE=$workspace_mode_file" \
        "VW_SETUP_SECRETS_TMP_DIR=$direct_tmp/plaintext-stage" \
        bash -x "$direct_fixture/utilities/setup-secrets.sh" configure --auto
    direct_rc=$?
    set -e
  }

  run_direct_case success "$success_dir"
  (( direct_rc == 0 )) || fail "direct configure --auto failed in PTY fixture"
  grep -Fq '_cmd_configure --auto' "$direct_stderr" \
    || fail "direct automatic regression did not exercise the command parser"
  assert_secret_free_streams "successful direct automatic setup"
  [[ "$(cat "$workspace_mode_file")" == "700" ]] \
    || fail "direct automatic credential workspace mode is not 0700"
  handoff_file="$(
    sudo -n find "$success_dir" -maxdepth 1 -type f \
      -name 'vaultwarden-setup-credentials-*.txt' -print
  )"
  [[ -n "$handoff_file" ]] || fail "direct automatic setup did not publish a handoff"
  # stat() mocks elsewhere in this test execute in isolated child shells;
  # this invocation intentionally runs the external stat command through sudo.
  # shellcheck disable=SC2033
  [[ "$(sudo -n stat -c '%a' "$handoff_file")" == "600" ]] \
    || fail "direct automatic handoff file mode is not 0600"
  [[ "$(sudo -n grep -c '^│  0[123]  ' "$handoff_file")" == "3" ]] \
    || fail "direct automatic handoff does not contain exactly three groups"
  grep -Fq "Protected setup credential handoff created: $handoff_file" "$direct_stdout" \
    || fail "direct automatic setup did not report the protected handoff path"
  assert_direct_temps_clean "direct automatic success"

  run_direct_case publication-failure "$failure_target"
  (( direct_rc != 0 )) || fail "forced handoff-publication failure returned success"
  assert_secret_free_streams "failed direct automatic setup"
  ! grep -Fq 'Protected setup credential handoff created:' \
    "$direct_stdout" "$direct_stderr" "$direct_pty" \
    || fail "publication failure printed a protected-handoff success summary"
  ! grep -Fq 'Secrets Setup Complete!' \
    "$direct_stdout" "$direct_stderr" "$direct_pty" \
    || fail "publication failure printed the generic success summary"
  assert_direct_temps_clean "direct automatic failure"
) || fail "behavioral direct automatic protected-handoff contract failed"
  pass "direct automatic setup PTY no-leak regression"
else
  if [[ "${CI:-false}" == "true" || "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    fail "mandatory direct automatic PTY regression requires passwordless sudo in CI"
  fi
  printf 'SKIP direct automatic PTY behavior: passwordless sudo unavailable\n'
fi
)

case "$MODE" in
    core)
        check_secrets_cli_help
        check_schema_dependency_contracts
        check_crowdsec_worker_post_edit_apply
        check_runtime_secret_reconciliation
        check_key_rotate_live_generation_transaction
        check_key_rotate_full_entrypoint_cleanup_contract
        ;;
    sensitive-cleanup)
        check_sensitive_cleanup_contracts
        ;;
    all)
        check_secrets_cli_help
        check_schema_dependency_contracts
        check_crowdsec_worker_post_edit_apply
        check_runtime_secret_reconciliation
        check_key_rotate_live_generation_transaction
        check_key_rotate_full_entrypoint_cleanup_contract
        check_sensitive_cleanup_contracts
        ;;
    *)
        printf 'FAIL: unknown VW_TEST_CASE_MODE for case-secrets.bash: %s\n' "$MODE" >&2
        exit 2
        ;;
esac
