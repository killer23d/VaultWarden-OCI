#!/usr/bin/env bash
# Focused behavioral coverage for the canonical developer test runner.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

ROOT="$VW_TEST_REPO_ROOT"
RUNNER="$ROOT/tests/run-tests.sh"
TEST_ROOT_HELPER="$ROOT/tests/lib/test-root.bash"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vaultwarden-runner-contracts.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd)"
FIXTURE_TESTS="$TMP_ROOT/fixture-tests"
NORMAL_REPO="$TMP_ROOT/normal-repo"
LAST_STATUS=0

cleanup() {
    chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
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

production_compose="$ROOT/docker-compose.yml.example"
development_compose="$ROOT/docker-compose.override.dev.yml.example"
for compose_file in "$production_compose" "$development_compose"; do
    if grep -Eq '^[[:space:]]+deploy:[[:space:]]*$' "$compose_file"; then
        fail "Compose example retains an inactive Docker Swarm deploy declaration: $compose_file"
    fi
done
[[ "$(grep -Fxc '    mem_limit: 512M' "$production_compose")" -eq 1 ]] \
    || fail 'Vaultwarden standalone memory limit changed'
[[ "$(grep -Fxc '    memswap_limit: 512M' "$production_compose")" -eq 1 ]] \
    || fail 'Vaultwarden standalone swap limit changed'
[[ "$(grep -Fxc '    mem_limit: 256M' "$production_compose")" -eq 2 ]] \
    || fail 'Caddy/Postfix standalone memory limits changed'
[[ "$(grep -Fxc '    memswap_limit: 256M' "$production_compose")" -eq 2 ]] \
    || fail 'Caddy/Postfix standalone swap limits changed'
[[ "$(grep -Fxc '    cpus: "0.25"' "$production_compose")" -eq 1 ]] \
    || fail 'Caddy standalone CPU limit changed'
[[ "$(grep -Fxc '    pids_limit: 200' "$production_compose")" -eq 1 ]] \
    || fail 'Caddy standalone process limit changed'
printf 'PASS: Compose examples retain only active standalone resource limits\n'

write_case() {
    local path="$1"
    local command="$2"

    mkdir -p "$(dirname "$path")"
    cat >"$path" <<EOF_CASE
#!/usr/bin/env bash
set -euo pipefail
${command}
EOF_CASE
    chmod +x "$path"
}

copy_registered_fixture() {
    local tests_dir="$1"
    local registered_case relative_path

    mkdir -p "$tests_dir/lib"
    cp "$TEST_ROOT_HELPER" "$tests_dir/lib/test-root.bash"
    for registered_case in "${REGISTERED_CASES[@]}"; do
        relative_path="${registered_case#tests/}"
        write_case "$tests_dir/$relative_path" "exit 0"
    done
}

snapshot_paths() {
    local tree="$1"
    find "$tree" -mindepth 1 -print | LC_ALL=C sort
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

for forbidden in \
    'ACTIVE_CASE_LINK' \
    'CASE_ENTRYPOINT' \
    'cleanup_case_link' \
    'prepare_case_entrypoint' \
    '.runner-case.' \
    'ln -s --'; do
    ! grep -Fq -- "$forbidden" "$RUNNER" \
        || fail "runner still contains checkout-mutation machinery: $forbidden"
done

real_list="$TMP_ROOT/real-list.out"
capture "$real_list" "$RUNNER" list
assert_status 0 "real runner list"
mapfile -t REGISTERED_CASES < <(sed -n 's/^  //p' "$real_list")
(( ${#REGISTERED_CASES[@]} > 0 )) || fail "real runner list returned no registered cases"

repo_status_before="$TMP_ROOT/repo-status.before"
repo_status_after="$TMP_ROOT/repo-status.after"
git -C "$ROOT" status --short --untracked-files=all -- tests >"$repo_status_before"

copy_registered_fixture "$FIXTURE_TESTS"
fixture_env=(env "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS")
run_output="$TMP_ROOT/run.out"

# If the Bash executable's directory is already in PATH, the runner must not
# move it ahead of a caller-selected command directory.
caller_bin="$TMP_ROOT/caller-bin"
bash_bin="$TMP_ROOT/bash-bin"
path_probe_marker="$TMP_ROOT/path-probe"
path_execution_marker="$TMP_ROOT/path-probe-executed"
mkdir -p "$caller_bin" "$bash_bin"
ln -s "$BASH" "$bash_bin/bash"
write_case "$caller_bin/path-priority-probe" \
    'printf caller > "$PATH_PRIORITY_EXECUTED"'
write_case "$bash_bin/path-priority-probe" \
    'printf bash-directory > "$PATH_PRIORITY_EXECUTED"'
write_case "$FIXTURE_TESTS/test-architecture.sh" \
    'path-priority-probe
for command_name in path-priority-probe bash dirname stat; do
    resolved_command="$(command -v "$command_name")"
    [[ "$resolved_command" == /* && -x "$resolved_command" ]]
    printf "%s\n" "$resolved_command"
done > "$PATH_PROBE_MARKER"'
capture "$run_output" env \
    "PATH=$caller_bin:$bash_bin:$PATH" \
    "PATH_PROBE_MARKER=$path_probe_marker" \
    "PATH_PRIORITY_EXECUTED=$path_execution_marker" \
    "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
    "$bash_bin/bash" "$RUNNER" foundation
assert_status 0 "caller PATH precedence"
mapfile -t path_probe_results <"$path_probe_marker"
[[ "${#path_probe_results[@]}" -eq 4 ]] \
    || fail "runner fixture did not resolve every required baseline utility"
[[ "${path_probe_results[0]}" == "$caller_bin/path-priority-probe" ]] \
    || fail "runner moved the Bash directory ahead of the caller-selected PATH entry"
[[ "$(<"$path_execution_marker")" == caller ]] \
    || fail "runner executed the Bash-directory mock instead of the caller-provided mock"
for resolved_baseline in "${path_probe_results[@]:1}"; do
    [[ "$resolved_baseline" == /* ]] \
        || fail "runner lost a required baseline utility: $resolved_baseline"
done
write_case "$FIXTURE_TESTS/test-architecture.sh" "exit 0"

normal_extra_case="$TMP_ROOT/normal-extra.bash"
normal_extra_marker="$TMP_ROOT/normal-extra-ran"
write_case "$normal_extra_case" 'printf ran > "$NORMAL_EXTRA_MARKER"'
capture "$run_output" env \
    "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=" \
    "VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_CASE=$normal_extra_case" \
    "NORMAL_EXTRA_MARKER=$normal_extra_marker" \
    "$RUNNER" foundation
assert_status 2 "normal-mode extra foundation case"
assert_contains "VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_CASE requires VAULTWARDEN_TEST_RUNNER_TESTS_DIR fixture mode" \
    "$run_output" "normal-mode fixture-hook diagnostic"
assert_not_contains "RUN   $normal_extra_case" \
    "$run_output" "normal-mode fixture-hook inventory isolation"
[[ ! -e "$normal_extra_marker" ]] \
    || fail "normal-mode fixture hook executed the injected case"

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

missing_case="$FIXTURE_TESTS/suites/foundation/case-config-env.bash"
mv "$missing_case" "$missing_case.saved"
capture "$run_output" "${fixture_env[@]}" "$RUNNER" list
assert_status 1 "missing listed case"
assert_contains "listed test case does not exist: $missing_case" \
    "$run_output" "missing case diagnostic"
mv "$missing_case.saved" "$missing_case"

unregistered_case="$FIXTURE_TESTS/suites/security/case-unregistered.bash"
write_case "$unregistered_case" "exit 0"
capture "$run_output" "${fixture_env[@]}" "$RUNNER" list
assert_status 1 "unregistered internal case"
assert_contains "unlisted permanent test case: $unregistered_case" \
    "$run_output" "unregistered case diagnostic"
rm -f -- "$unregistered_case"

top_level_case="$FIXTURE_TESTS/case-unexpected.bash"
write_case "$top_level_case" "exit 0"
capture "$run_output" "${fixture_env[@]}" "$RUNNER" list
assert_status 1 "unexpected top-level case"
assert_contains "permanent case files must live under tests/suites" \
    "$run_output" "unexpected top-level case diagnostic"
rm -f -- "$top_level_case"

top_level_test="$FIXTURE_TESTS/test-unexpected.sh"
write_case "$top_level_test" "exit 0"
capture "$run_output" "${fixture_env[@]}" "$RUNNER" list
assert_status 1 "unexpected top-level test"
assert_contains "permanent tests must be registered as case-*.bash" \
    "$run_output" "unexpected top-level test diagnostic"
rm -f -- "$top_level_test"

capture "$run_output" "${fixture_env[@]}" "$RUNNER" list
assert_status 0 "fixture runner list"
listed_count="$(grep -c '^  ' "$run_output" || true)"
[[ "$listed_count" -eq "${#REGISTERED_CASES[@]}" ]] \
    || fail "list printed $listed_count cases; expected ${#REGISTERED_CASES[@]}"
for registered_case in "${REGISTERED_CASES[@]}"; do
    fixture_case="$FIXTURE_TESTS/${registered_case#tests/}"
    occurrence_count="$(grep -Fxc "  $fixture_case" "$run_output" || true)"
    [[ "$occurrence_count" -eq 1 ]] \
        || fail "list printed $fixture_case $occurrence_count times; expected once"
done

collision_case="$FIXTURE_TESTS/suites/foundation/case-email.bash"
write_case "$collision_case" "exit 0"
capture "$run_output" env \
    "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
    "VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_CASE=$collision_case" \
    "$RUNNER" list
assert_status 0 "suite-relative identical basenames"
assert_contains "  $collision_case" "$run_output" "foundation basename collision path"
assert_contains "  $FIXTURE_TESTS/suites/security/case-email.bash" \
    "$run_output" "security basename collision path"
rm -f -- "$collision_case"

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

failure_case="$FIXTURE_TESTS/suites/foundation/case-config-env.bash"
write_case "$failure_case" "exit 37"
capture "$run_output" env \
    "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
    "VAULTWARDEN_TEST_RUNNER_TIMEOUT_COMMAND=$fake_timeout" \
    "FAKE_TIMEOUT_LOG=$fake_timeout_log" \
    "$RUNNER" all
assert_status 37 "all failure propagation"
assert_contains "FAIL  $failure_case (exit 37)" \
    "$run_output" "all failure diagnostic"
assert_not_contains "PASS  all" "$run_output" "all false final success"
write_case "$failure_case" "exit 0"

if gnu_timeout="$(find_gnu_timeout)"; then
    write_case "$failure_case" "exit 124"
    capture "$run_output" env \
        "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
        "VAULTWARDEN_TEST_RUNNER_TIMEOUT_COMMAND=$gnu_timeout" \
        "TEST_CASE_TIMEOUT_SECONDS=2" \
        "$RUNNER" all
    assert_status 124 "ordinary exit 124 propagation"
    assert_contains "FAIL  $failure_case (exit 124)" \
        "$run_output" "ordinary exit 124 diagnostic"
    assert_not_contains "TIMEOUT $failure_case" \
        "$run_output" "ordinary exit 124 timeout distinction"

    write_case "$failure_case" "sleep 5"
    capture "$run_output" env \
        "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
        "VAULTWARDEN_TEST_RUNNER_TIMEOUT_COMMAND=$gnu_timeout" \
        "TEST_CASE_TIMEOUT_SECONDS=1" \
        "$RUNNER" all
    assert_status 124 "timed-out case status"
    assert_contains "TIMEOUT $failure_case after 1s" \
        "$run_output" "timed-out case diagnostic"
    assert_not_contains "PASS  all" "$run_output" "timed-out all false final success"
    write_case "$failure_case" "exit 0"
else
    printf 'SKIP: supported GNU timeout path unavailable in this environment.\n'
fi

mkdir -p "$NORMAL_REPO/tests"
cp "$RUNNER" "$NORMAL_REPO/tests/run-tests.sh"
chmod +x "$NORMAL_REPO/tests/run-tests.sh"
copy_registered_fixture "$NORMAL_REPO/tests"
root_probe_case="$NORMAL_REPO/tests/suites/foundation/case-config-env.bash"
root_probe_marker="$TMP_ROOT/root-probe-ran"
cat >"$root_probe_case" <<'EOF_ROOT_PROBE'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"
[[ "$VW_TEST_REPO_ROOT" == "${EXPECTED_TEST_REPO_ROOT:?}" ]]
printf ran > "${ROOT_PROBE_MARKER:?}"
EOF_ROOT_PROBE
chmod +x "$root_probe_case"

normal_paths_before="$TMP_ROOT/normal-paths.before"
normal_paths_after="$TMP_ROOT/normal-paths.after"
snapshot_paths "$NORMAL_REPO/tests" >"$normal_paths_before"
chmod -R a-w "$NORMAL_REPO/tests"
capture "$run_output" env \
    "EXPECTED_TEST_REPO_ROOT=$NORMAL_REPO" \
    "ROOT_PROBE_MARKER=$root_probe_marker" \
    "$NORMAL_REPO/tests/run-tests.sh" foundation
assert_status 0 "normal runner with read-only tests tree"
[[ -f "$root_probe_marker" ]] \
    || fail "nested case did not resolve the copied repository root"
snapshot_paths "$NORMAL_REPO/tests" >"$normal_paths_after"
cmp -s "$normal_paths_before" "$normal_paths_after" \
    || fail "normal runner changed paths under a read-only tests tree"
if find "$NORMAL_REPO/tests" -type l -name '.runner-case.*' -print -quit | grep -q .; then
    fail "normal runner left a generated case symlink under tests"
fi

git -C "$ROOT" status --short --untracked-files=all -- tests >"$repo_status_after"
cmp -s "$repo_status_before" "$repo_status_after" \
    || { diff -u "$repo_status_before" "$repo_status_after" >&2 || true; fail "runner contracts modified the repository tests tree"; }

printf 'PASS: test runner path, inventory, isolation, and timeout contracts\n'
