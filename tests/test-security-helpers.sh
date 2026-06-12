#!/usr/bin/env bash
# Focused tests for schema dispatch, password formats, SOPS round trips, and
# authenticated file-integrity sidecars.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_TMP=$(mktemp -d -t vw-security-tests.XXXXXXXXXX)
trap 'rm -rf "$TEST_TMP"' EXIT HUP INT TERM

export PROJECT_ROOT
mkdir -p "${TEST_TMP}/secrets"
export SECRETS_FILE="${TEST_TMP}/secrets/secrets.yaml"
export SECRETS_SCHEMA_FILE="${PROJECT_ROOT}/secrets-schema.yaml"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/defaults.sh"
source "${PROJECT_ROOT}/lib/config.sh"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/lib/secrets.sh"
source "${PROJECT_ROOT}/lib/backup-utils.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_fails() {
    if "$@" >/dev/null 2>&1; then
        fail "expected failure from: $*"
    fi
}

test_hmac_key_not_in_cmdline() {
    local test_key="TEST_HMAC_KEY_SENTINEL_PR172"
    local real_python
    real_python=$(command -v python3) || fail "python3 is required for HMAC tests"

    local mock_bin="${TEST_TMP}/mock-bin"
    local exposure_marker="${TEST_TMP}/hmac-key-exposed"
    mkdir -p "$mock_bin"
    cat > "${mock_bin}/python3" <<EOF
#!/usr/bin/env bash
if tr '\0' '\n' < "/proc/\$\$/cmdline" | grep -Fq 'TEST_HMAC_KEY_SENTINEL_PR172' \
    || tr '\0' '\n' < "/proc/\$\$/environ" | grep -Fq 'TEST_HMAC_KEY_SENTINEL_PR172'; then
    : > "${exposure_marker}"
fi
exec "${real_python}" "\$@"
EOF
    chmod 700 "${mock_bin}/python3"

    local original_path="$PATH"
    PATH="${mock_bin}:${PATH}"
    FILE_INTEGRITY_HMAC_KEY="$test_key" write_file_integrity "$integrity_file" \
        || fail "write_file_integrity failed during command-line exposure test"
    PATH="$original_path"

    [[ ! -e "$exposure_marker" ]] || fail "HMAC key found in child process arguments or environment"
    printf 'PASS: HMAC key not found in child process arguments or environment\n'
}

test_collect_secret_field_rejects_auto_key() {
    local out
    local rc=0
    out=$(collect_secret_field "file_integrity_hmac_key" 2>&1) || rc=$?
    [[ $rc -ne 0 ]] || fail "collect_secret_field accepted an auto key"
    [[ "$out" == *"is an auto key"* ]] || fail "auto-key rejection was not explicit"
    printf 'PASS: collect_secret_field correctly rejected auto key\n'
}

test_resolve_rclone_config_arg() {
    if ! command -v rclone >/dev/null 2>&1; then
        printf 'SKIP: rclone not installed\n'
        return 0
    fi

    # Load the production helper without executing backup-run.sh's main entry.
    # shellcheck disable=SC1090  # process substitution intentionally extracts one function
    source <(sed -n '/^_resolve_rclone_config_arg()/,/^}/p' \
        "${PROJECT_ROOT}/utilities/backup-run.sh")

    local mock_cfg="${TEST_TMP}/rclone.conf"
    printf '[myremote]\ntype = local\n' > "$mock_cfg"
    chmod 600 "$mock_cfg"

    local -a result_arr=()
    local rc=0
    RCLONE_CONFIG="$mock_cfg" _resolve_rclone_config_arg result_arr || rc=$?
    if (( rc != 0 )) || [[ "${result_arr[0]:-}" != "--config" ]]; then
        fail "_resolve_rclone_config_arg did not populate the array"
    fi
    [[ "${result_arr[1]:-}" == "$(realpath -e "$mock_cfg")" ]] \
        || fail "_resolve_rclone_config_arg returned the wrong path"
    printf 'PASS: _resolve_rclone_config_arg populated --config <path>\n'
}

valid_bcrypt_body=$(printf 'A%.0s' {1..53})
_bcrypt_format_ok "\$2y\$12\$${valid_bcrypt_body}" || fail "valid bcrypt format rejected"
assert_fails _bcrypt_format_ok "\$2y\$4\$${valid_bcrypt_body}"
assert_fails _bcrypt_format_ok "\$2y\$120\$${valid_bcrypt_body}"
assert_fails _bcrypt_format_ok "\$2y\$12\$$(printf '!%.0s' {1..53})"

integrity_file="${TEST_TMP}/payload.txt"
printf 'vaultwarden integrity test\n' > "$integrity_file"
export FILE_INTEGRITY_HMAC_KEY="test-only-hmac-key"
export REQUIRE_AUTHENTICATED_INTEGRITY=true
write_file_integrity "$integrity_file" || fail "write_file_integrity failed"
verify_file_integrity "$integrity_file" || fail "verify_file_integrity failed"
printf 'tampered\n' > "${integrity_file}.sha256.hmac"
assert_fails verify_file_integrity "$integrity_file"
test_hmac_key_not_in_cmdline
test_collect_secret_field_rejects_auto_key
test_resolve_rclone_config_arg

command -v yq >/dev/null 2>&1 || fail "yq is required for schema tests"
[[ "$(schema_collect_type push_installation_id)" == "conditional" ]] || fail "conditional collect type missing"
[[ "$(schema_condition_fn push_installation_id)" == "condition_push_enabled" ]] || fail "condition_fn missing"
[[ "$(schema_field_safe file_integrity_hmac_key auto_fn)" == "auto_generate_secret_field" ]] || fail "integrity auto_fn missing"

if command -v htpasswd >/dev/null 2>&1; then
    generated_bcrypt=$(generate_bcrypt_hash "correct horse battery staple" 12)
    _bcrypt_format_ok "$generated_bcrypt" || fail "generated bcrypt hash rejected"
fi

if python3 -c 'import argon2' >/dev/null 2>&1; then
    generated_argon=$(generate_argon2_hash "correct horse battery staple")
    [[ "$generated_argon" == \$argon2id\$* ]] || fail "generated Argon2id hash has wrong prefix"
fi

if command -v age-keygen >/dev/null 2>&1 && command -v sops >/dev/null 2>&1; then
    age_key="${TEST_TMP}/age-key.txt"
    yaml_file="${TEST_TMP}/roundtrip.yaml"
    age-keygen -o "$age_key" >/dev/null 2>&1
    printf 'token: roundtrip-ok\n' > "$yaml_file"
    encrypt_sops_file "$yaml_file" "$age_key" || fail "SOPS encryption round trip failed"
    decrypted=$(SOPS_AGE_KEY_FILE="$age_key" sops --decrypt --extract '["token"]' "$yaml_file")
    [[ "$decrypted" == "roundtrip-ok" ]] || fail "SOPS decrypted value mismatch"
fi

printf 'Security helper tests passed.\n'
