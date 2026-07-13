#!/usr/bin/env bash
# Focused behavioral coverage for the canonical developer test runner.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/tests/run-tests.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vaultwarden-runner-contracts.XXXXXX")"
FIXTURE_TESTS="$TMP_ROOT/tests"
LAST_STATUS=0

cleanup() {
    rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

capture() {
    local output_file="$1"
    shift

    set +e
    "$@" >"$output_file" 2>&1
    LAST_STATUS=$?
    set -e
}

assert_status() {
    local expected="$1"
    local context="$2"

    [[ "$LAST_STATUS" -eq "$expected" ]] \
        || fail "$context: expected exit $expected, got $LAST_STATUS"
}

assert_contains() {
    local needle="$1"
    local file="$2"
    local context="$3"

    grep -Fq -- "$needle" "$file" \
        || fail "$context: missing '$needle'"
}

assert_not_contains() {
    local needle="$1"
    local file="$2"
    local context="$3"

    if grep -Fq -- "$needle" "$file"; then
        fail "$context: unexpectedly contained '$needle'"
    fi
}

write_case() {
    local path="$1"
    local command="$2"

    cat >"$path" <<EOF_CASE
#!/usr/bin/env bash
set -euo pipefail
${command}
EOF_CASE
    chmod +x "$path"
}

find_gnu_timeout() {
    local name candidate version_output

    for name in timeout gtimeout; do
        candidate="$(command -v "$name" 2>/dev/null || true)"
        [[ -n "$candidate" ]] || continue
        version_output="$(LC_ALL=C "$candidate" --version 2>/dev/null || true)"
        if [[ "$version_output" == *"GNU coreutils"* ]] \
            && LC_ALL=C "$candidate" --kill-after=1s --verbose 1s \
                "$BASH" -c 'exit 0' >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

mkdir -p "$FIXTURE_TESTS"
real_list="$TMP_ROOT/real-list.out"
capture "$real_list" "$RUNNER" list
assert_status 0 "real runner list"

mapfile -t registered_cases < <(sed -n 's/^  //p' "$real_list")
(( ${#registered_cases[@]} > 0 )) || fail "real runner list returned no registered cases"

for registered_case in "${registered_cases[@]}"; do
    write_case "$FIXTURE_TESTS/${registered_case##*/}" "exit 0"
done

run_output="$TMP_ROOT/run.out"
fixture_env=(env "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS")

capture "$run_output" "${fixture_env[@]}" "$RUNNER" unknown-suite
assert_status 2 "unknown suite"
assert_contains "Usage: ./tests/run-tests.sh all" "$run_output" "unknown suite usage"

capture "$run_output" "${fixture_env[@]}" "$RUNNER"
assert_status 2 "zero arguments"
assert_contains "Usage: ./tests/run-tests.sh all" "$run_output" "zero-argument usage"

capture "$run_output" "${fixture_env[@]}" "$RUNNER" foundation extra
assert_status 2 "multiple arguments"
assert_contains "Usage: ./tests/run-tests.sh all" "$run_output" "multiple-argument usage"

for invalid_timeout in 0 abc; do
    capture "$run_output" env \
        "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
        "TEST_CASE_TIMEOUT_SECONDS=$invalid_timeout" \
        "$RUNNER" list
    assert_status 2 "invalid timeout '$invalid_timeout'"
    assert_contains "TEST_CASE_TIMEOUT_SECONDS must be a positive integer" \
        "$run_output" "invalid timeout '$invalid_timeout' diagnostic"
done

capture "$run_output" env \
    "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
    "VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_CASE=$FIXTURE_TESTS/test-architecture.sh" \
    "$RUNNER" list
assert_status 1 "duplicate inventory entry"
assert_contains "duplicate case inventory entry" "$run_output" "duplicate inventory diagnostic"

capture "$run_output" env \
    "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
    "VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_CASE=$FIXTURE_TESTS/case-missing.bash" \
    "$RUNNER" list
assert_status 1 "missing listed case"
assert_contains "listed test case does not exist" "$run_output" "missing case diagnostic"

write_case "$FIXTURE_TESTS/case-unregistered.bash" "exit 0"
capture "$run_output" "${fixture_env[@]}" "$RUNNER" list
assert_status 1 "unregistered internal case"
assert_contains "unlisted permanent test case" "$run_output" "unregistered case diagnostic"
rm -f -- "$FIXTURE_TESTS/case-unregistered.bash"

write_case "$FIXTURE_TESTS/test-unexpected.sh" "exit 0"
capture "$run_output" "${fixture_env[@]}" "$RUNNER" list
assert_status 1 "unexpected top-level test"
assert_contains "permanent tests must be registered as case-*.bash" \
    "$run_output" "unexpected top-level test diagnostic"
rm -f -- "$FIXTURE_TESTS/test-unexpected.sh"

capture "$run_output" "${fixture_env[@]}" "$RUNNER" list
assert_status 0 "fixture runner list"
listed_count="$(grep -c '^  ' "$run_output" || true)"
[[ "$listed_count" -eq "${#registered_cases[@]}" ]] \
    || fail "list printed $listed_count cases; expected ${#registered_cases[@]}"
for registered_case in "${registered_cases[@]}"; do
    fixture_case="$FIXTURE_TESTS/${registered_case##*/}"
    occurrence_count="$(grep -Fxc "  $fixture_case" "$run_output" || true)"
    [[ "$occurrence_count" -eq 1 ]] \
        || fail "list printed $fixture_case $occurrence_count times; expected once"
done

fake_timeout="$TMP_ROOT/fake-timeout"
fake_timeout_log="$TMP_ROOT/fake-timeout.log"
cat >"$fake_timeout" <<'EOF_TIMEOUT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_TIMEOUT_LOG"
if [[ "${1:-}" == "--version" ]]; then
    printf 'timeout (GNU coreutils) fixture\n'
    exit 0
fi
exit 2
EOF_TIMEOUT
chmod +x "$fake_timeout"

fallback_marker="$TMP_ROOT/fallback-ran"
write_case "$FIXTURE_TESTS/test-architecture.sh" 'printf ran > "$FALLBACK_MARKER"'
capture "$run_output" env \
    "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
    "FALLBACK_MARKER=$fallback_marker" \
    "VAULTWARDEN_TEST_RUNNER_TIMEOUT_COMMAND=$fake_timeout" \
    "FAKE_TIMEOUT_LOG=$fake_timeout_log" \
    "$RUNNER" foundation
assert_status 0 "unsupported timeout fallback"
assert_contains "timeout unavailable; no per-case deadline" \
    "$run_output" "unsupported timeout fallback summary"
assert_contains "does not support the required GNU timeout options" \
    "$run_output" "unsupported timeout capability diagnostic"
[[ -f "$fallback_marker" ]] || fail "fallback path did not execute test cases"
assert_contains "--kill-after=1s --verbose 1s" \
    "$fake_timeout_log" "timeout capability probe"
write_case "$FIXTURE_TESTS/test-architecture.sh" "exit 0"

write_case "$FIXTURE_TESTS/case-config-env.bash" "exit 37"
capture "$run_output" env \
    "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
    "VAULTWARDEN_TEST_RUNNER_TIMEOUT_COMMAND=$fake_timeout" \
    "FAKE_TIMEOUT_LOG=$fake_timeout_log" \
    "$RUNNER" all
assert_status 37 "all failure propagation"
assert_contains "FAIL  $FIXTURE_TESTS/case-config-env.bash (exit 37)" \
    "$run_output" "all failure diagnostic"
assert_not_contains "PASS  all" "$run_output" "all false final success"
write_case "$FIXTURE_TESTS/case-config-env.bash" "exit 0"

if gnu_timeout="$(find_gnu_timeout)"; then
    write_case "$FIXTURE_TESTS/case-config-env.bash" "exit 124"
    capture "$run_output" env \
        "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
        "VAULTWARDEN_TEST_RUNNER_TIMEOUT_COMMAND=$gnu_timeout" \
        "TEST_CASE_TIMEOUT_SECONDS=2" \
        "$RUNNER" all
    assert_status 124 "ordinary exit 124 propagation"
    assert_contains "FAIL  $FIXTURE_TESTS/case-config-env.bash (exit 124)" \
        "$run_output" "ordinary exit 124 diagnostic"
    assert_not_contains "TIMEOUT $FIXTURE_TESTS/case-config-env.bash" \
        "$run_output" "ordinary exit 124 timeout distinction"

    write_case "$FIXTURE_TESTS/case-config-env.bash" "sleep 5"
    capture "$run_output" env \
        "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
        "VAULTWARDEN_TEST_RUNNER_TIMEOUT_COMMAND=$gnu_timeout" \
        "TEST_CASE_TIMEOUT_SECONDS=1" \
        "$RUNNER" all
    assert_status 124 "timed-out case status"
    assert_contains "TIMEOUT $FIXTURE_TESTS/case-config-env.bash after 1s" \
        "$run_output" "timed-out case diagnostic"
    assert_not_contains "PASS  all" "$run_output" "timed-out all false final success"
else
    printf 'SKIP: supported GNU timeout path unavailable in this environment.\n'
fi

printf 'PASS: test runner command, inventory, and timeout contracts\n'
