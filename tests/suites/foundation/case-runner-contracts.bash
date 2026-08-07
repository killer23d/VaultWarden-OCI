#!/usr/bin/env bash
# Canonical runner and repository-interface contracts.
set -euo pipefail
MODE="${VW_TEST_CASE_MODE:-all}"
case "$MODE" in core|repository-interface|all) ;; *) printf 'FAIL: unknown VW_TEST_CASE_MODE for case-runner-contracts.bash: %s\n' "$MODE" >&2; exit 2 ;; esac

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

check_runner_contracts_core() (
set -euo pipefail
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
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

capture() {
    local output_file="$1"; shift
    set +e
    "$@" >"$output_file" 2>&1
    LAST_STATUS=$?
    set -e
}
assert_status() { [[ "$LAST_STATUS" -eq "$1" ]] || fail "$2: expected exit $1, got $LAST_STATUS"; }
assert_contains() { grep -Fq -- "$1" "$2" || fail "$3: missing '$1'"; }
assert_not_contains() { ! grep -Fq -- "$1" "$2" || fail "$3: unexpectedly contained '$1'"; }
assert_matches() { grep -Eq -- "$1" "$2" || fail "$3: pattern did not match: $1"; }

write_case() {
    local path="$1" command="$2"
    mkdir -p "$(dirname "$path")"
    cat >"$path" <<EOF_CASE
#!/usr/bin/env bash
set -euo pipefail
${command}
EOF_CASE
    chmod +x "$path"
}
write_fixture_case() {
    write_case "$1" 'if [[ -n "${FIXTURE_MODE_LOG:-}" ]]; then printf "%s|%s\\n" "${VW_TEST_CASE_MODE:-}" "$0" >> "$FIXTURE_MODE_LOG"; fi'
}

real_list="$TMP_ROOT/real-list.out"
real_list_repeat="$TMP_ROOT/real-list-repeat.out"
capture "$real_list" "$RUNNER" list
assert_status 0 "real runner list"
capture "$real_list_repeat" "$RUNNER" list
assert_status 0 "real runner list repeat"
cmp -s "$real_list" "$real_list_repeat" || fail "logical list output is not deterministic"
mapfile -t REGISTERED_RECORDS < <(sed -n 's/^  //p' "$real_list")
[[ "${#REGISTERED_RECORDS[@]}" -eq 26 ]] || fail "real runner listed ${#REGISTERED_RECORDS[@]} records; expected 26"

real_files="$TMP_ROOT/real-files.out"
real_files_repeat="$TMP_ROOT/real-files-repeat.out"
capture "$real_files" "$RUNNER" list-files
assert_status 0 "real runner list-files"
capture "$real_files_repeat" "$RUNNER" list-files
assert_status 0 "real runner list-files repeat"
cmp -s "$real_files" "$real_files_repeat" || fail "list-files output is not deterministic"
mapfile -t REGISTERED_PATHS < "$real_files"
[[ "${#REGISTERED_PATHS[@]}" -eq 19 ]] || fail "real runner listed ${#REGISTERED_PATHS[@]} unique physical cases; expected 19"
[[ "$(sort -u "$real_files" | wc -l | tr -d '[:space:]')" -eq 19 ]] || fail "list-files contains duplicate physical paths"

declare -A SEEN_IDS=() SEEN_PATH_MODES=()
for record in "${REGISTERED_RECORDS[@]}"; do
    IFS='|' read -r logical_id physical_path mode timeout <<<"$record"
    [[ -n "$logical_id" && -n "$physical_path" && -n "$mode" && -n "$timeout" ]] || fail "real list emitted an empty record field: $record"
    [[ "$timeout" == 120 ]] || fail "real list changed stored timeout for $logical_id: $timeout"
    [[ -z "${SEEN_IDS[$logical_id]+x}" ]] || fail "real list duplicated logical ID: $logical_id"
    SEEN_IDS[$logical_id]=1
    path_mode="$physical_path|$mode"
    [[ -z "${SEEN_PATH_MODES[$path_mode]+x}" ]] || fail "real list duplicated path/mode: $path_mode"
    SEEN_PATH_MODES[$path_mode]=1
    grep -Fqx "$physical_path" "$real_files" || fail "list-files omitted registered physical case: $physical_path"
done
grep -Fqx 'health-alerts|tests/suites/operations/case-health-alerts.bash|core|120' < <(printf '%s\n' "${REGISTERED_RECORDS[@]}") \
    || fail "health-alerts logical core record is missing"
grep -Fqx 'health-locking|tests/suites/operations/case-health-alerts.bash|locking|120' < <(printf '%s\n' "${REGISTERED_RECORDS[@]}") \
    || fail "health-locking logical record is missing"
[[ "$(grep -Fxc 'tests/suites/operations/case-health-alerts.bash' "$real_files" || true)" -eq 1 ]] \
    || fail "multi-mode health-alerts physical case must appear exactly once in list-files"
health_alerts_line="$(grep -nF '  health-alerts|tests/suites/operations/case-health-alerts.bash|core|120' "$real_list" | cut -d: -f1)"
health_locking_line="$(grep -nF '  health-locking|tests/suites/operations/case-health-alerts.bash|locking|120' "$real_list" | cut -d: -f1)"
[[ -n "$health_alerts_line" && "$health_locking_line" -eq $(( health_alerts_line + 1 )) ]] \
    || fail "logical list order changed for health-alerts/health-locking"

for forbidden in ACTIVE_CASE_LINK CASE_ENTRYPOINT cleanup_case_link prepare_case_entrypoint '.runner-case.' 'ln -s --'; do
    ! grep -Fq -- "$forbidden" "$RUNNER" || fail "runner still contains checkout-mutation machinery: $forbidden"
done

copy_registered_fixture() {
    local tests_dir="$1" physical_path
    mkdir -p "$tests_dir/lib"
    cp "$TEST_ROOT_HELPER" "$tests_dir/lib/test-root.bash"
    for physical_path in "${REGISTERED_PATHS[@]}"; do
        write_fixture_case "$tests_dir/${physical_path#tests/}"
    done
}
copy_registered_fixture "$FIXTURE_TESTS"
fixture_env=(env "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS")
run_output="$TMP_ROOT/run.out"

repo_status_before="$TMP_ROOT/repo-status.before"
repo_status_after="$TMP_ROOT/repo-status.after"
git -C "$ROOT" status --short --untracked-files=all -- tests >"$repo_status_before"

# Stable logical list, physical list-files rewrite, record preservation, and one fixture file per unique physical path.
list_one="$TMP_ROOT/list-one.out"; list_two="$TMP_ROOT/list-two.out"
capture "$list_one" "${fixture_env[@]}" "$RUNNER" list; assert_status 0 "fixture list first pass"
capture "$list_two" "${fixture_env[@]}" "$RUNNER" list; assert_status 0 "fixture list second pass"
cmp -s "$list_one" "$list_two" || fail "fixture logical list output is not stable"
[[ "$(grep -c '^  ' "$list_one")" -eq 26 ]] || fail "fixture list did not preserve 26 logical records"
for record in "${REGISTERED_RECORDS[@]}"; do
    IFS='|' read -r logical_id physical_path mode timeout <<<"$record"
    mapped="$FIXTURE_TESTS/${physical_path#tests/}"
    grep -Fqx "  $logical_id|$mapped|$mode|$timeout" "$list_one" || fail "fixture rewrite changed record fields: $record"
done

files_one="$TMP_ROOT/files-one.out"; files_two="$TMP_ROOT/files-two.out"
capture "$files_one" "${fixture_env[@]}" "$RUNNER" list-files; assert_status 0 "fixture list-files first pass"
capture "$files_two" "${fixture_env[@]}" "$RUNNER" list-files; assert_status 0 "fixture list-files second pass"
cmp -s "$files_one" "$files_two" || fail "fixture list-files output is not stable"
[[ "$(wc -l < "$files_one" | tr -d '[:space:]')" -eq 19 ]] || fail "fixture list-files did not preserve 19 unique physical paths"
[[ "$(sort -u "$files_one" | wc -l | tr -d '[:space:]')" -eq 19 ]] || fail "fixture list-files duplicated a physical path"
for physical_path in "${REGISTERED_PATHS[@]}"; do
    mapped="$FIXTURE_TESTS/${physical_path#tests/}"
    grep -Fqx "$mapped" "$files_one" || fail "fixture list-files omitted rewritten physical path: $mapped"
done
[[ "$(find "$FIXTURE_TESTS/suites" -type f -name 'case-*.bash' | wc -l | tr -d '[:space:]')" -eq 19 ]] \
    || fail "fixture construction did not create one file per unique physical path"

# Fixture hook is a complete record and is forbidden outside fixture mode.
extra_valid='extra-valid|tests/suites/foundation/case-storage-setup.bash|extra-mode|120'
capture "$run_output" env "VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_RECORD=$extra_valid" "$RUNNER" list
assert_status 2 "normal-mode full-record fixture hook"
assert_contains 'VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_RECORD requires VAULTWARDEN_TEST_RUNNER_TESTS_DIR fixture mode' "$run_output" "normal-mode fixture-hook diagnostic"

# Record parser rejects malformed counts, every empty field, invalid syntax, unsafe paths, and invalid timeouts.
declare -a BAD_RECORDS=(
    'bad|tests/suites/foundation/case-storage-setup.bash|core'
    'bad|tests/suites/foundation/case-storage-setup.bash|core|120|extra'
    '|tests/suites/foundation/case-storage-setup.bash|core|120'
    'bad||core|120'
    'bad|tests/suites/foundation/case-storage-setup.bash||120'
    'bad|tests/suites/foundation/case-storage-setup.bash|core|'
    'Bad_ID|tests/suites/foundation/case-storage-setup.bash|core|120'
    'bad|tests/suites/foundation/case-storage-setup.bash|Bad_Mode|120'
    'bad|tests/suites/foundation/case-storage-setup.bash|core|0'
    'bad|tests/suites/foundation/case-storage-setup.bash|core|abc'
    'bad|/tmp/case-bad.bash|core|120'
    'bad|tests/suites/../case-bad.bash|core|120'
)
for bad_record in "${BAD_RECORDS[@]}"; do
    capture "$run_output" env "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
        "VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_RECORD=$bad_record" "$RUNNER" list
    assert_status 1 "malformed record '$bad_record'"
    assert_contains 'FAIL malformed test record' "$run_output" "malformed record diagnostic"
done
for invalid_timeout in 0 abc; do
    capture "$run_output" env "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
        "TEST_CASE_TIMEOUT_SECONDS=$invalid_timeout" "$RUNNER" list
    assert_status 2 "invalid global timeout '$invalid_timeout'"
    assert_contains 'TEST_CASE_TIMEOUT_SECONDS must be a positive base-10 integer' "$run_output" "invalid global timeout diagnostic"
done

probe_record=""
for record in "${REGISTERED_RECORDS[@]}"; do
    if [[ "$record" == permissions\|* ]]; then
        probe_record="$record"
        break
    fi
done
[[ -n "$probe_record" ]] || fail "single-mode probe record 'permissions' is missing"
IFS='|' read -r probe_id probe_path probe_mode _ <<<"$probe_record"
[[ "$probe_path|$probe_mode" == 'tests/suites/foundation/case-permissions.bash|all' ]] \
    || fail "permissions is no longer the expected single-mode probe record"
probe_mapped="$FIXTURE_TESTS/${probe_path#tests/}"
second_path="${REGISTERED_PATHS[1]}"

# Global ID uniqueness and path/mode uniqueness; same path with a different mode is valid.
capture "$run_output" env "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
    "VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_RECORD=$probe_id|$second_path|another-mode|120" "$RUNNER" list
assert_status 1 "duplicate logical ID"
assert_contains "duplicate logical test ID '$probe_id'" "$run_output" "duplicate logical ID diagnostic"

capture "$run_output" env "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
    "VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_RECORD=other-id|$probe_path|$probe_mode|120" "$RUNNER" list
assert_status 1 "duplicate path/mode"
assert_contains "duplicate physical-path/mode pair '$probe_path|$probe_mode'" "$run_output" "duplicate path/mode diagnostic"

capture "$run_output" env "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
    "VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_RECORD=other-id|$probe_path|another-mode|120" "$RUNNER" list
assert_status 0 "same path with different mode"
assert_contains "other-id|$probe_mapped|another-mode|120" "$run_output" "same-path different-mode listing"

# Missing, unlisted, and forbidden top-level files fail inventory validation.
mv "$probe_mapped" "$probe_mapped.saved"
capture "$run_output" "${fixture_env[@]}" "$RUNNER" list
assert_status 1 "missing listed case"
assert_contains "listed test case does not exist for '$probe_id': $probe_mapped" "$run_output" "missing case diagnostic"
mv "$probe_mapped.saved" "$probe_mapped"

unlisted="$FIXTURE_TESTS/suites/security/case-unregistered.bash"; write_fixture_case "$unlisted"
capture "$run_output" "${fixture_env[@]}" "$RUNNER" list; assert_status 1 "unlisted case"
assert_contains "unlisted permanent test case: $unlisted" "$run_output" "unlisted case diagnostic"; rm -f "$unlisted"

top_case="$FIXTURE_TESTS/case-unexpected.bash"; write_fixture_case "$top_case"
capture "$run_output" "${fixture_env[@]}" "$RUNNER" list; assert_status 1 "top-level case"
assert_contains 'permanent case-*.bash files must live under tests/suites' "$run_output" "top-level case diagnostic"; rm -f "$top_case"

top_test="$FIXTURE_TESTS/test-unexpected.sh"; write_fixture_case "$top_test"
capture "$run_output" "${fixture_env[@]}" "$RUNNER" list; assert_status 1 "top-level test"
assert_contains 'permanent test-*.sh files are not allowed directly below tests/' "$run_output" "top-level test diagnostic"; rm -f "$top_test"

# Identical basenames in different suites remain valid because full paths are authoritative.
collision="$FIXTURE_TESTS/suites/foundation/case-email.bash"; write_fixture_case "$collision"
capture "$run_output" env "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
    'VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_RECORD=foundation-email|tests/suites/foundation/case-email.bash|all|120' "$RUNNER" list
assert_status 0 "suite-relative identical basenames"
assert_contains "foundation-email|$collision|all|120" "$run_output" "foundation basename collision path"
assert_contains "$FIXTURE_TESTS/suites/security/case-email.bash" "$run_output" "security basename collision path"
rm -f "$collision"

# Caller PATH precedence is preserved; runner may not move Bash's directory ahead of an existing caller entry.
caller_bin="$TMP_ROOT/caller-bin"; bash_bin="$TMP_ROOT/bash-bin"; mkdir -p "$caller_bin" "$bash_bin"
ln -s "$BASH" "$bash_bin/bash"
path_probe_marker="$TMP_ROOT/path-probe"; path_exec_marker="$TMP_ROOT/path-executed"
write_case "$caller_bin/path-priority-probe" 'printf caller > "$PATH_PRIORITY_EXECUTED"'
write_case "$bash_bin/path-priority-probe" 'printf bash-directory > "$PATH_PRIORITY_EXECUTED"'
write_case "$probe_mapped" 'path-priority-probe
for command_name in path-priority-probe bash dirname stat; do command -v "$command_name"; done > "$PATH_PROBE_MARKER"'
capture "$run_output" env "PATH=$caller_bin:$bash_bin:$PATH" \
    "PATH_PROBE_MARKER=$path_probe_marker" "PATH_PRIORITY_EXECUTED=$path_exec_marker" \
    "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" "$bash_bin/bash" "$RUNNER" foundation
assert_status 0 "caller PATH precedence"
mapfile -t path_probe_results <"$path_probe_marker"
[[ "${#path_probe_results[@]}" -eq 4 ]] || fail "PATH probe did not resolve four commands"
[[ "${path_probe_results[0]}" == "$caller_bin/path-priority-probe" ]] || fail "runner moved Bash directory ahead of caller PATH"
[[ "$(<"$path_exec_marker")" == caller ]] || fail "runner executed Bash-directory mock instead of caller mock"
write_fixture_case "$probe_mapped"

# Mode propagation reaches every logical invocation, including repeated physical paths.
mode_log="$TMP_ROOT/modes.log"; : > "$mode_log"
capture "$run_output" env "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" "FIXTURE_MODE_LOG=$mode_log" "$RUNNER" foundation
assert_status 0 "foundation mode propagation"
assert_matches "^PASS    $probe_id \\([0-9]+\\.[0-9]{2}s\\) \\[$probe_mapped\\]$" "$run_output" "success duration diagnostic"
[[ "$(wc -l < "$mode_log" | tr -d '[:space:]')" -eq 8 ]] || fail "foundation did not execute 8 logical records"
for expected in \
    "host-architecture|$FIXTURE_TESTS/suites/foundation/case-storage-setup.bash" \
    "core|$FIXTURE_TESTS/suites/foundation/case-runner-contracts.bash" \
    "repository-interface|$FIXTURE_TESTS/suites/foundation/case-runner-contracts.bash" \
    "core|$FIXTURE_TESTS/suites/foundation/case-config-env.bash" \
    "ci-dev-setup|$FIXTURE_TESTS/suites/foundation/case-config-env.bash"; do
    grep -Fqx "$expected" "$mode_log" || fail "missing propagated mode: $expected"
done

# Global override changes effective timeout in list output.
capture "$run_output" env "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" TEST_CASE_TIMEOUT_SECONDS=321 "$RUNNER" list
assert_status 0 "global timeout list override"
assert_contains "$probe_id|$probe_mapped|$probe_mode|321" "$run_output" "global timeout list override"

# Unsupported GNU-timeout lookalike falls back safely rather than blocking execution.
fake_timeout="$TMP_ROOT/fake-timeout"; fake_log="$TMP_ROOT/fake-timeout.log"
cat >"$fake_timeout" <<'EOF_TIMEOUT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_TIMEOUT_LOG"
if [[ "${1:-}" == "--version" ]]; then printf 'timeout (GNU coreutils) fixture\n'; exit 0; fi
exit 2
EOF_TIMEOUT
chmod +x "$fake_timeout"; : > "$fake_log"
capture "$run_output" env "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
    "VAULTWARDEN_TEST_RUNNER_TIMEOUT_COMMAND=$fake_timeout" "FAKE_TIMEOUT_LOG=$fake_log" "$RUNNER" foundation
assert_status 0 "unsupported timeout fallback"
assert_contains 'timeout unavailable; no per-logical-case deadline' "$run_output" "unsupported timeout summary"
assert_contains 'does not support the required GNU timeout options' "$run_output" "unsupported timeout diagnostic"
assert_contains '--kill-after=1s --verbose 1s' "$fake_log" "timeout capability probe"

# Failures identify both logical ID and physical path and propagate through all.
write_case "$probe_mapped" 'exit 37'
capture "$run_output" "${fixture_env[@]}" "$RUNNER" all
assert_status 37 "all failure propagation"
assert_matches "^FAIL    $probe_id \\([0-9]+\\.[0-9]{2}s\\) \\[$probe_mapped\\] \\(exit 37\\)$" "$run_output" "failure duration diagnostic"
assert_not_contains 'PASS    all' "$run_output" "false all success"
write_fixture_case "$probe_mapped"

find_gnu_timeout() {
    local name candidate version_output
    for name in timeout gtimeout; do
        candidate="$(command -v "$name" 2>/dev/null || true)"; [[ -n "$candidate" ]] || continue
        version_output="$(LC_ALL=C "$candidate" --version 2>/dev/null || true)"
        if [[ "$version_output" == *'GNU coreutils'* ]] && LC_ALL=C "$candidate" --kill-after=1s --verbose 1s "$BASH" -c 'exit 0' >/dev/null 2>&1; then
            printf '%s\n' "$candidate"; return 0
        fi
    done
    return 1
}

if gnu_timeout="$(find_gnu_timeout)"; then
    # Exit 124 from the test itself is a failure, not a timeout.
    write_case "$probe_mapped" 'exit 124'
    capture "$run_output" env "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
        "VAULTWARDEN_TEST_RUNNER_TIMEOUT_COMMAND=$gnu_timeout" TEST_CASE_TIMEOUT_SECONDS=2 "$RUNNER" foundation
    assert_status 124 "ordinary exit 124 propagation"
    assert_matches "^FAIL    $probe_id \\([0-9]+\\.[0-9]{2}s\\) \\[$probe_mapped\\] \\(exit 124\\)$" "$run_output" "ordinary exit 124 duration diagnostic"
    assert_not_contains "TIMEOUT $probe_id (" "$run_output" "ordinary exit 124 timeout distinction"
    write_fixture_case "$probe_mapped"

    # A real timeout is detected from GNU timeout's own signal diagnostic.
    write_case "$probe_mapped" 'sleep 5'
    capture "$run_output" env "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
        "VAULTWARDEN_TEST_RUNNER_TIMEOUT_COMMAND=$gnu_timeout" TEST_CASE_TIMEOUT_SECONDS=1 "$RUNNER" foundation
    assert_status 124 "true timeout propagation"
    assert_matches "^TIMEOUT $probe_id \\([0-9]+\\.[0-9]{2}s\\) \\[$probe_mapped\\] after 1s$" "$run_output" "true timeout duration diagnostic"
    write_fixture_case "$probe_mapped"

    # Stored per-record timeout is honored independently.
    extra_path="$FIXTURE_TESTS/suites/foundation/case-extra-timeout.bash"
    write_case "$extra_path" 'sleep 5'
    capture "$run_output" env "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
        "VAULTWARDEN_TEST_RUNNER_TIMEOUT_COMMAND=$gnu_timeout" \
        'VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_RECORD=slow-record|tests/suites/foundation/case-extra-timeout.bash|slow|1' \
        "$RUNNER" foundation
    assert_status 124 "stored per-record timeout"
    assert_matches "^TIMEOUT slow-record \\([0-9]+\\.[0-9]{2}s\\) \\[$extra_path\\] after 1s$" "$run_output" "stored per-record timeout duration diagnostic"
    rm -f "$extra_path"

    # Global override wins over a longer stored timeout.
    write_case "$extra_path" 'sleep 5'
    capture "$run_output" env "VAULTWARDEN_TEST_RUNNER_TESTS_DIR=$FIXTURE_TESTS" \
        "VAULTWARDEN_TEST_RUNNER_TIMEOUT_COMMAND=$gnu_timeout" TEST_CASE_TIMEOUT_SECONDS=1 \
        'VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_RECORD=slow-record|tests/suites/foundation/case-extra-timeout.bash|slow|5' \
        "$RUNNER" foundation
    assert_status 124 "global timeout execution override"
    assert_matches "^TIMEOUT slow-record \\([0-9]+\\.[0-9]{2}s\\) \\[$extra_path\\] after 1s$" "$run_output" "global timeout execution duration diagnostic"
    rm -f "$extra_path"
else
    printf 'SKIP: supported GNU timeout path unavailable in this environment.\n'
fi

# A copied repository with a read-only tests tree runs without generated entrypoints or checkout mutation.
mkdir -p "$NORMAL_REPO/tests"; cp "$RUNNER" "$NORMAL_REPO/tests/run-tests.sh"; chmod +x "$NORMAL_REPO/tests/run-tests.sh"
copy_registered_fixture "$NORMAL_REPO/tests"
normal_probe="$NORMAL_REPO/${probe_path}"
root_marker="$TMP_ROOT/root-probe-ran"
cat >"$normal_probe" <<'EOF_ROOT'
#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"
[[ "$VW_TEST_REPO_ROOT" == "${EXPECTED_TEST_REPO_ROOT:?}" ]]
printf ran > "${ROOT_PROBE_MARKER:?}"
EOF_ROOT
chmod +x "$normal_probe"
find "$NORMAL_REPO/tests" -mindepth 1 -print | LC_ALL=C sort >"$TMP_ROOT/normal.before"
chmod -R a-w "$NORMAL_REPO/tests"
capture "$run_output" env "EXPECTED_TEST_REPO_ROOT=$NORMAL_REPO" "ROOT_PROBE_MARKER=$root_marker" "$NORMAL_REPO/tests/run-tests.sh" foundation
assert_status 0 "read-only copied tests tree"
[[ -f "$root_marker" ]] || fail "nested case did not resolve copied repository root"
find "$NORMAL_REPO/tests" -mindepth 1 -print | LC_ALL=C sort >"$TMP_ROOT/normal.after"
cmp -s "$TMP_ROOT/normal.before" "$TMP_ROOT/normal.after" || fail "runner changed paths under read-only tests tree"
if find "$NORMAL_REPO/tests" -type l -name '.runner-case.*' -print -quit | grep -q .; then fail "runner left a generated case symlink"; fi

git -C "$ROOT" status --short --untracked-files=all -- tests >"$repo_status_after"
cmp -s "$repo_status_before" "$repo_status_after" || { diff -u "$repo_status_before" "$repo_status_after" >&2 || true; fail "runner contracts modified repository tests tree"; }

printf 'PASS: logical runner records, fixture isolation, failure, and timeout contracts\n'
)

check_repository_interface_cleanup_contracts() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
cd "$ROOT"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# The direct shell runner remains the canonical repository regression entry point.
grep -Fq 'Usage: ./tests/run-tests.sh all' tests/run-tests.sh \
    || fail 'run-tests usage must advertise ./tests/run-tests.sh all'
grep -Fq 'host-architecture|tests/suites/foundation/case-storage-setup.bash|host-architecture|120' tests/run-tests.sh \
    || fail 'host architecture logical record is missing from run-tests.sh'
! grep -Fq 'tests/test-architecture.sh' tests/run-tests.sh \
    || fail 'run-tests still references the removed top-level architecture test'

extract_make_target() {
    local target="$1"
    awk -v target="$target" '
        BEGIN { in_target=0; found=0 }
        $0 ~ "^" target ":" { in_target=1; found=1; print; next }
        in_target && $0 ~ /^[A-Za-z0-9_.-]+:([^=]|$)/ { exit }
        in_target { print }
        END { if (!found) exit 2 }
    ' Makefile
}

for target in test test-unit fmt lint shellcheck; do
    if extract_make_target "$target" >/dev/null 2>&1; then
        fail "Makefile must not define removed developer target: $target"
    fi
    if grep -RInE "make[[:space:]]+${target}([^[:alnum:]_-]|$)" README.md RUNBOOK.md docs --exclude='COMMAND-REFERENCE.md' >/tmp/vw-removed-make-target.$$ 2>/dev/null; then
        cat /tmp/vw-removed-make-target.$$ >&2
        rm -f /tmp/vw-removed-make-target.$$
        fail "removed Make target is still referenced: make ${target}"
    fi
    rm -f /tmp/vw-removed-make-target.$$
done

if find .github/workflows -type f ! -name 'append-*' -print0 \
  | xargs -0 grep -nE 'make[[:space:]]+(test|test-unit|fmt|lint|shellcheck)([^[:alnum:]_-]|$)' >/tmp/vw-ci-make-target.$$ 2>/dev/null; then
    cat /tmp/vw-ci-make-target.$$ >&2
    rm -f /tmp/vw-ci-make-target.$$
    fail 'CI must call direct validation tools, not removed Make wrappers'
fi
rm -f /tmp/vw-ci-make-target.$$

if find tests -maxdepth 1 -type f -name 'test-*.sh' | grep -E 'followup|post-pr|pr[0-9]|[0-9]{3}' >/tmp/vw-historical-tests.$$; then
    cat /tmp/vw-historical-tests.$$ >&2
    rm -f /tmp/vw-historical-tests.$$
    fail 'permanent top-level test filenames must not retain historical PR/follow-up names'
fi
rm -f /tmp/vw-historical-tests.$$

while IFS= read -r test_file; do
    rel="${test_file#./}"
    grep -Fq "    ${rel}" tests/run-tests.sh || fail "permanent test file is not inventoried: $rel"
done <<EOF_TESTS
$(find tests -maxdepth 1 -type f -name 'test-*.sh' -print | sort)
EOF_TESTS

grep -Fq 'SOPS_DEFAULT_VERSION="v3.13.2"' utilities/setup-system.sh \
    || fail 'setup-system must pin the normal SOPS default'
grep -Fq 'SOPS_VERSION="$1"' utilities/setup-system.sh \
    || fail 'setup-system must retain explicit --sops-version overrides'
grep -Fq 'SOPS_VERSION_CLI_SET=true' utilities/setup-system.sh \
    || fail 'setup-system must track explicit --sops-version ownership'
grep -Fq '[[ "$SOPS_VERSION_ENV_SET" == "true" ]] && _sops_flags=(--sops-version "$SOPS_VERSION")' setup.sh \
    || fail 'setup.sh must pass explicit SOPS_VERSION overrides to setup-system'
awk '/install_sops\(\)/,/^}/' utilities/setup-system.sh | grep -Fq 'if [[ "$USE_LATEST" == "true" ]]' \
    || fail 'SOPS latest resolution must be owned by explicit --use-latest'
awk '/install_sops\(\)/,/^}/' utilities/setup-system.sh | grep -Fq '_sops_resolved_version' \
    || fail 'install_sops must inspect the actual installed SOPS version before reuse'
awk '/install_sops\(\)/,/^}/' utilities/setup-system.sh | grep -Fq '[[ "$installed_sops_ver" == "$sops_ver" ]]' \
    || fail 'install_sops must reuse only an exact selected-version match'
awk '/install_sops\(\)/,/^}/' utilities/setup-system.sh | grep -Fq '[[ "$final_sops_ver" != "$sops_ver" ]]' \
    || fail 'install_sops must verify the final resolved SOPS version after install'
! awk '/install_sops\(\)/,/^}/' utilities/setup-system.sh | grep -Fq 'if command -v sops >/dev/null 2>&1; then' \
    || fail 'install_sops must not bypass selected-version ownership with command -v sops'
awk '/verify_dependencies\(\)/,/^}/' utilities/setup-system.sh | grep -Fq '_validate_sops_contract' \
    || fail 'verify_dependencies must validate the existing sops interface for --skip-deps'
! grep -Fq 'SOPS_VERSION not pinned' utilities/setup-system.sh \
    || fail 'normal setup must not resolve latest merely because SOPS_VERSION is blank'

grep -Fq '"python3-yaml"' utilities/setup-system.sh \
    || fail 'setup-system must explicitly own python3-yaml'
grep -Fq '"python3-bcrypt"' utilities/setup-system.sh \
    || fail 'normal setup must explicitly own python3-bcrypt'
grep -Fq '[python3-bcrypt]=""' utilities/setup-system.sh \
    || fail 'python3-bcrypt package must be checked through dpkg membership'
! grep -Eq 'local basic_packages=.*"yq"' utilities/setup-system.sh \
    || fail 'setup-system basic apt packages must not install Ubuntu python-yq'
grep -Fq 'python3 -c "import yaml"' utilities/setup-system.sh \
    || fail 'verify_dependencies must verify PyYAML import'
grep -Fq 'python3 -c "import bcrypt"' utilities/setup-system.sh \
    || fail 'verify_dependencies must verify the bcrypt module import'
awk '/verify_dependencies\(\)/,/^}/' utilities/setup-system.sh \
    | grep -Fq '_verify_required_python_modules' \
    || fail 'verify_dependencies must run Python module checks with --skip-deps'
main_flow="$(awk '/^main\(\) {/,/^}/' utilities/setup-system.sh)"
[[ "$main_flow" == *$'    install_dependencies\n    verify_dependencies'* ]] \
    || fail '--skip-deps must skip installation only and still verify dependencies'
! grep -REn 'pip(3)?[[:space:]]+install[[:space:]]+bcrypt' \
    utilities/setup-system.sh setup.sh .github/workflows \
    || fail 'bcrypt must not be installed from PyPI'
for cleanup_command in systemd-run shred realpath rm; do
    awk '/verify_dependencies\(\)/,/^}/' utilities/setup-system.sh \
        | grep -Fq "\"${cleanup_command}\"" \
        || fail "verify_dependencies omits cleanup runtime command: ${cleanup_command}"
done
awk '/verify_dependencies\(\)/,/^}/' utilities/setup-system.sh \
    | grep -Fq '[[ -x /bin/sh ]]' \
    || fail 'verify_dependencies must require /bin/sh for detached cleanup'

yq_version="$(sed -n 's/^YQ_VERSION="\([^"]*\)"/\1/p' utilities/setup-system.sh)"
yq_sha_amd64="$(sed -n 's/^YQ_SHA256_AMD64="\([^"]*\)"/\1/p' utilities/setup-system.sh)"
[[ -n "$yq_version" && -n "$yq_sha_amd64" ]] || fail 'setup-system yq constants missing'
grep -Fq "YQ_VERSION=\"${yq_version}\"" .github/workflows/doc-drift.yml \
    || fail 'CI yq version must match production setup'
grep -Fq "$yq_sha_amd64" .github/workflows/doc-drift.yml \
    || fail 'CI yq checksum must match production amd64 setup pin'
grep -Fq 'v3.13.2/sops-v3.13.2.linux.amd64' .github/workflows/doc-drift.yml \
    || fail 'CI SOPS binary must match the production SOPS default version'

if grep -En '^[[:space:]]*--with[[:space:]]+github.com/[^[:space:]@]+([[:space:]\\]|$)' caddy/Dockerfile >/tmp/vw-xcaddy-unpinned.$$; then
    cat /tmp/vw-xcaddy-unpinned.$$ >&2
    rm -f /tmp/vw-xcaddy-unpinned.$$
    fail 'every direct xcaddy module must include an immutable tag or commit'
fi
rm -f /tmp/vw-xcaddy-unpinned.$$
if grep -En '^[[:space:]]*--with[[:space:]]+github.com/.*@(latest|main|master|HEAD)([[:space:]\\]|$)' caddy/Dockerfile >/tmp/vw-xcaddy-mutable.$$; then
    cat /tmp/vw-xcaddy-mutable.$$ >&2
    rm -f /tmp/vw-xcaddy-mutable.$$
    fail 'direct xcaddy modules must not use mutable refs'
fi
rm -f /tmp/vw-xcaddy-mutable.$$
for module in \
    'github.com/caddy-dns/cloudflare@v0.2.4' \
    'github.com/WeidiDeng/caddy-cloudflare-ip@f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5' \
    'github.com/fvbommel/caddy-combine-ip-ranges@v0.0.1' \
    'github.com/mholt/caddy-ratelimit@v0.1.0'; do
    grep -Fq -- "--with ${module}" caddy/Dockerfile \
        || fail "pinned Caddy module missing: ${module}"
done
grep -Fq "dns cloudflare" caddy/Caddyfile \
    || fail 'Caddyfile must retain Cloudflare DNS provider usage'
grep -Fq "rate_limit" caddy/Caddyfile \
    || fail 'Caddyfile must retain Caddy rate_limit usage'
grep -Fq "'caddy/**'" .github/workflows/doc-drift.yml \
    || fail 'Caddy changes must trigger the permanent workflow'
grep -Fq "'AGENTS.md'" .github/workflows/doc-drift.yml \
    || fail 'AGENTS changes must trigger the permanent workflow'

grep -Fq -- '- Ubuntu 24.04 LTS Noble;' AGENTS.md \
    || fail 'AGENTS must document the Noble production contract'
grep -Fq -- '- amd64 or arm64;' AGENTS.md \
    || fail 'AGENTS must document the amd64/arm64 production contract'
! grep -Fq 'Ubuntu 22.04 LTS Jammy or Ubuntu 24.04 LTS Noble' AGENTS.md \
    || fail 'AGENTS must not retain the obsolete Jammy/Noble production matrix'
grep -Fq 'Ubuntu 24.04 LTS Noble' README.md \
    || fail 'README must state the Noble production contract'
grep -Fq 'Ubuntu 24.04 LTS Noble host on amd64 or arm64' docs/PROJECT-BOUNDARY.md \
    || fail 'PROJECT-BOUNDARY must state Noble amd64/arm64'
grep -Fq 'Use Ubuntu 24.04 LTS Noble on amd64 or arm64.' docs/DISASTER-RECOVERY.md \
    || fail 'DISASTER-RECOVERY must state Noble amd64/arm64'
grep -Fq 'Use Ubuntu 24.04 LTS Noble on amd64 or arm64.' docs/RECOVERY-CARD.md \
    || fail 'RECOVERY-CARD must state Noble amd64/arm64'
grep -Fq 'provider firewall/security group/network firewall' RUNBOOK.md \
    || fail 'RUNBOOK must use provider-neutral firewall wording'
! grep -Fq 'Configure OCI Security List' RUNBOOK.md \
    || fail 'RUNBOOK must not present OCI Security List as universal setup'

printf 'PASS: repository interface cleanup contracts\n'
)

case "$MODE" in
    core) check_runner_contracts_core ;;
    repository-interface) check_repository_interface_cleanup_contracts ;;
    all)
        check_runner_contracts_core
        check_repository_interface_cleanup_contracts
        ;;
esac
