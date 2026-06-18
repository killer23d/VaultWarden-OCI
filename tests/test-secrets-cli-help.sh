#!/usr/bin/env bash
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
for script in \
    secrets-view.sh \
    secrets-list.sh \
    secrets-rotate.sh \
    secrets-export-recovery-kit.sh; do
    cp "${PROJECT_ROOT}/utilities/${script}" "${ISOLATED_ROOT}/utilities/"
done

run_clean() {
    (
        cd "$RUN_DIR"
        env -i \
            PATH="/usr/bin:/bin" \
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
    output="$(run_clean "${ISOLATED_ROOT}/utilities/${script}" "$@")" ||
        fail "${script} $* exited non-zero"
    [[ -n "$output" ]] || fail "${script} $* produced no output"
    [[ "$output" == *"$heading"* ]] || fail "${script} $* omitted heading: $heading"
    [[ "$output" == *"USAGE:"* ]] || fail "${script} $* omitted USAGE"
    assert_no_initialization_error "$output"
}

assert_version() {
    local option="$1"
    local expected output
    expected="VaultWarden-OCI $(tr -d '[:space:]' < "${ISOLATED_ROOT}/VERSION")"
    output="$(run_clean "${ISOLATED_ROOT}/utilities/secrets-rotate.sh" "$option")" ||
        fail "secrets-rotate.sh $option exited non-zero"
    [[ -n "$output" ]] || fail "secrets-rotate.sh $option produced no output"
    [[ "$output" == "$expected" ]] ||
        fail "secrets-rotate.sh $option output '$output', expected '$expected'"
    assert_no_initialization_error "$output"
}

for option in --help -h; do
    assert_help secrets-view.sh "VaultWarden Secrets — view subcommand" "$option"
    assert_help secrets-list.sh "VaultWarden Secrets — list subcommand" "$option"
    assert_help secrets-rotate.sh "VaultWarden Secrets — rotate subcommand" "$option"
    assert_help secrets-export-recovery-kit.sh \
        "VaultWarden Secrets — export-recovery-kit subcommand" "$option"
done

assert_help secrets-view.sh "VaultWarden Secrets — view subcommand" view --help
assert_help secrets-list.sh "VaultWarden Secrets — list subcommand" list --help
assert_help secrets-rotate.sh "VaultWarden Secrets — rotate subcommand" rotate --help
assert_help secrets-export-recovery-kit.sh \
    "VaultWarden Secrets — export-recovery-kit subcommand" export-recovery-kit --help

assert_version --version
assert_version -V

printf 'Standalone secrets CLI help tests passed.\n'
