#!/usr/bin/env bash
# Focused tests for schema dispatch, password formats, SOPS round trips, and
# authenticated file-integrity sidecars.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_TMP=$(mktemp -d -t vw-security-tests.XXXXXXXXXX)
trap 'rm -rf "$TEST_TMP"' EXIT HUP INT TERM

export PROJECT_ROOT
export SECRETS_FILE="${TEST_TMP}/secrets.yaml"
export SECRETS_SCHEMA_FILE="${PROJECT_ROOT}/secrets-schema.yaml"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/defaults.sh"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/lib/secrets.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_fails() {
    if "$@" >/dev/null 2>&1; then
        fail "expected failure from: $*"
    fi
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
