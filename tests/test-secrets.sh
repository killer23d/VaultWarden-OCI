#!/usr/bin/env bash
# Consolidated secrets regression suite.
set -euo pipefail

check_secrets_cli_help() (
# Verify standalone secrets informational options need no project configuration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

grep -Fq 'yq -r '\''.secrets[] | select(.conditional_group == "cloudflare_proxy") | .key'\''' "$ROOT/lib/secrets.sh" \
    || fail "validate_required_secrets must use explicit raw yq output for Cloudflare keys"
grep -Fq 'python3 -c "import yaml"' "$ROOT/utilities/setup-system.sh" \
    || fail "setup dependency verification must check PyYAML import"
grep -Fq '"python3-yaml"' "$ROOT/utilities/setup-system.sh" \
    || fail "setup apt package ownership must include python3-yaml"
! grep -Eq 'local basic_packages=.*"yq"' "$ROOT/utilities/setup-system.sh" \
    || fail "setup apt package ownership must not use Ubuntu python-yq"

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
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
run_test 'manifest promotion failure preserves existing live artifacts' test_manifest_promotion_failure_preserves_artifacts
run_test 'manifest promotion failure preserves absent manifest' test_manifest_promotion_failure_preserves_absent_manifest
run_test 'TERM after ciphertext promotion rolls back artifacts and preserves traps' test_term_after_ciphertext_promotion_rolls_back_and_preserves_traps
run_test 'successful transaction preserves existing caller return trap' test_preserves_outer_return_trap
[[ "$TESTS_RUN" -eq 7 ]] || fail "expected 7 tests, ran $TESTS_RUN"
printf '1..%s\n' "$TESTS_RUN"
