#!/usr/bin/env bash
set -euo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
    for bash5 in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [[ -x "$bash5" ]]; then
            exec "$bash5" "$0" "$@"
        fi
    done
fi
BASH_DIR="$(cd "$(dirname "$BASH")" && pwd)"
case ":${PATH}:" in
    *":${BASH_DIR}:"*) ;;
    *) PATH="${BASH_DIR}:${PATH}" ;;
esac
export PATH

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TESTS_DIR="${VAULTWARDEN_TEST_RUNNER_TESTS_DIR:-tests}"
TEST_CASE_TIMEOUT_SECONDS="${TEST_CASE_TIMEOUT_SECONDS:-}"
TIMEOUT_MODE="none"
TIMEOUT_DESCRIPTION="timeout unavailable; no per-logical-case deadline"
TIMEOUT_NOTICE="NOTE: per-logical-case timeout enforcement is unavailable; install GNU coreutils timeout or gtimeout to enable it."
TIMEOUT_COMMAND=()
CASE_TIMED_OUT=false
RUNNER_TEMP_DIR=""

cleanup_runner_temp() {
    if [[ -n "$RUNNER_TEMP_DIR" && -d "$RUNNER_TEMP_DIR" ]]; then
        rm -rf -- "$RUNNER_TEMP_DIR"
    fi
}
trap cleanup_runner_temp EXIT

usage() {
    cat <<'USAGE'
Usage: ./tests/run-tests.sh all
       ./tests/run-tests.sh <suite>
       ./tests/run-tests.sh list
       ./tests/run-tests.sh list-files

Suites:
  foundation       Architecture, configuration, permissions, storage, systemd
  security         Security/privilege, secrets, and email contracts
  operations       Operations, lifecycle, operator UI, CrowdSec, uninstall
  data-protection  Backup and restore/recovery contracts
  all              Run every suite in the order above
  list             Print the logical execution inventory without running it
  list-files       Print the unique physical case inventory without running it

Examples:
  ./tests/run-tests.sh all
  ./tests/run-tests.sh foundation
  ./tests/run-tests.sh list
  ./tests/run-tests.sh list-files
USAGE
}

FOUNDATION_CASES=(
    "host-architecture|tests/suites/foundation/case-storage-setup.bash|host-architecture|120"
    "runner-contracts-core|tests/suites/foundation/case-runner-contracts.bash|core|120"
    "repository-interface|tests/suites/foundation/case-runner-contracts.bash|repository-interface|120"
    "config-env-core|tests/suites/foundation/case-config-env.bash|core|120"
    "ci-dev-setup|tests/suites/foundation/case-config-env.bash|ci-dev-setup|120"
    "permissions|tests/suites/foundation/case-permissions.bash|all|120"
    "storage-setup-core|tests/suites/foundation/case-storage-setup.bash|core|120"
    "systemd|tests/suites/foundation/case-systemd.bash|all|120"
)

SECURITY_CASES=(
    "security-privileges|tests/suites/security/case-security-privileges.bash|all|120"
    "secrets-core|tests/suites/security/case-secrets.bash|core|120"
    "email|tests/suites/security/case-email.bash|all|120"
    "sensitive-cleanup|tests/suites/security/case-secrets.bash|sensitive-cleanup|120"
)

OPERATIONS_CASES=(
    "operations|tests/suites/operations/case-operations.bash|all|120"
    "health-alerts|tests/suites/operations/case-health-alerts.bash|core|120"
    "health-locking|tests/suites/operations/case-health-alerts.bash|locking|120"
    "lifecycle-core|tests/suites/operations/case-lifecycle.bash|core|120"
    "startup-hardening|tests/suites/operations/case-lifecycle.bash|startup-hardening|120"
    "operator-ui|tests/suites/operations/case-operator-ui.bash|all|120"
    "firewall-update|tests/suites/operations/case-firewall-update.bash|all|120"
    "crowdsec|tests/suites/operations/case-crowdsec.bash|all|120"
    "crowdsec-notifications|tests/suites/operations/case-crowdsec-notifications.bash|all|120"
    "email-queue|tests/suites/operations/case-email-queue.bash|all|120"
    "uninstall|tests/suites/operations/case-uninstall.bash|all|120"
)

DATA_PROTECTION_CASES=(
    "backup|tests/suites/data-protection/case-backup.bash|all|120"
    "restore-core|tests/suites/data-protection/case-restore-recovery.bash|core|120"
    "restore-tail|tests/suites/data-protection/case-restore-recovery.bash|tail|120"
)

if [[ -n "${VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_RECORD:-}" \
    && -z "${VAULTWARDEN_TEST_RUNNER_TESTS_DIR:-}" ]]; then
    echo "FAIL VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_RECORD requires VAULTWARDEN_TEST_RUNNER_TESTS_DIR fixture mode" >&2
    exit 2
fi

if [[ -n "${VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_RECORD:-}" ]]; then
    FOUNDATION_CASES+=("$VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_RECORD")
fi

record_field_count() {
    local record="$1" rest count=1
    rest="$record"
    while [[ "$rest" == *'|'* ]]; do
        rest="${rest#*|}"
        count=$((count + 1))
    done
    printf '%s\n' "$count"
}

parse_record() {
    local record="$1" context="$2" field_count
    field_count="$(record_field_count "$record")"
    if [[ "$field_count" -ne 4 ]]; then
        echo "FAIL malformed test record ($context): expected 4 fields, got $field_count: $record" >&2
        return 1
    fi

    IFS='|' read -r RECORD_ID RECORD_PATH RECORD_MODE RECORD_TIMEOUT <<<"$record"
    [[ -n "$RECORD_ID" ]] || { echo "FAIL malformed test record ($context): logical-id is empty: $record" >&2; return 1; }
    [[ -n "$RECORD_PATH" ]] || { echo "FAIL malformed test record ($context): physical-path is empty: $record" >&2; return 1; }
    [[ -n "$RECORD_MODE" ]] || { echo "FAIL malformed test record ($context): mode is empty: $record" >&2; return 1; }
    [[ -n "$RECORD_TIMEOUT" ]] || { echo "FAIL malformed test record ($context): timeout-seconds is empty: $record" >&2; return 1; }

    [[ "$RECORD_ID" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] \
        || { echo "FAIL malformed test record ($context): invalid logical-id '$RECORD_ID'" >&2; return 1; }
    [[ "$RECORD_MODE" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] \
        || { echo "FAIL malformed test record ($context): invalid mode '$RECORD_MODE' for '$RECORD_ID'" >&2; return 1; }
    [[ "$RECORD_TIMEOUT" =~ ^[1-9][0-9]*$ ]] \
        || { echo "FAIL malformed test record ($context): timeout-seconds must be a positive base-10 integer for '$RECORD_ID': $RECORD_TIMEOUT" >&2; return 1; }

    case "$RECORD_PATH" in
        tests/suites/*/case-*.bash) ;;
        *)
            echo "FAIL malformed test record ($context): physical-path must be relative under tests/suites/**/case-*.bash for '$RECORD_ID': $RECORD_PATH" >&2
            return 1
            ;;
    esac
    if [[ "$RECORD_PATH" == /* \
        || "$RECORD_PATH" == *'/../'* \
        || "$RECORD_PATH" == *'/./'* \
        || "$RECORD_PATH" == *'//'* \
        || "$RECORD_PATH" == ../* \
        || "$RECORD_PATH" == */.. ]]; then
        echo "FAIL malformed test record ($context): unsafe physical-path for '$RECORD_ID': $RECORD_PATH" >&2
        return 1
    fi
}

validate_timeout_override() {
    if [[ -n "$TEST_CASE_TIMEOUT_SECONDS" \
        && ! "$TEST_CASE_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
        echo "FAIL TEST_CASE_TIMEOUT_SECONDS must be a positive base-10 integer" >&2
        exit 2
    fi
}

rebuild_all_cases() {
    ALL_CASES=(
        "${FOUNDATION_CASES[@]}"
        "${SECURITY_CASES[@]}"
        "${OPERATIONS_CASES[@]}"
        "${DATA_PROTECTION_CASES[@]}"
    )
}

validate_record_definitions() {
    local index record context path_mode_key
    local -A seen_ids=()
    local -A seen_path_modes=()

    rebuild_all_cases
    for index in "${!ALL_CASES[@]}"; do
        record="${ALL_CASES[$index]}"
        context="ALL_CASES[$index]"
        parse_record "$record" "$context" || exit 1

        if [[ -n "${seen_ids[$RECORD_ID]+x}" ]]; then
            echo "FAIL duplicate logical test ID '$RECORD_ID': ${seen_ids[$RECORD_ID]} and $record" >&2
            exit 1
        fi
        seen_ids[$RECORD_ID]="$record"

        path_mode_key="${RECORD_PATH}|${RECORD_MODE}"
        if [[ -n "${seen_path_modes[$path_mode_key]+x}" ]]; then
            echo "FAIL duplicate physical-path/mode pair '$path_mode_key': ${seen_path_modes[$path_mode_key]} and $record" >&2
            exit 1
        fi
        seen_path_modes[$path_mode_key]="$record"
    done
}

map_fixture_records() {
    local array_name="$1"
    local -n records_ref="$array_name"
    local index record

    for index in "${!records_ref[@]}"; do
        record="${records_ref[$index]}"
        parse_record "$record" "${array_name}[${index}]" || exit 1
        records_ref[$index]="${RECORD_ID}|${TESTS_DIR%/}/${RECORD_PATH#tests/}|${RECORD_MODE}|${RECORD_TIMEOUT}"
    done
}

validate_inventory_files() {
    local record logical_id case_file discovered
    local -A listed_paths=()

    rebuild_all_cases
    for record in "${ALL_CASES[@]}"; do
        IFS='|' read -r logical_id case_file _ _ <<<"$record"
        if [[ ! -f "$case_file" ]]; then
            echo "FAIL listed test case does not exist for '$logical_id': $case_file" >&2
            exit 1
        fi
        listed_paths[$case_file]=1
    done

    if find "$TESTS_DIR" -maxdepth 1 -type f -name 'case-*.bash' -print -quit | grep -q .; then
        echo "FAIL permanent case-*.bash files must live under tests/suites and be registered in tests/run-tests.sh" >&2
        exit 1
    fi
    if find "$TESTS_DIR" -maxdepth 1 -type f -name 'test-*.sh' -print -quit | grep -q .; then
        echo "FAIL permanent test-*.sh files are not allowed directly below tests/" >&2
        exit 1
    fi

    if [[ -d "$TESTS_DIR/suites" ]]; then
        while IFS= read -r -d '' discovered; do
            if [[ -z "${listed_paths[$discovered]+x}" ]]; then
                echo "FAIL unlisted permanent test case: $discovered" >&2
                exit 1
            fi
        done < <(find "$TESTS_DIR/suites" -type f -name 'case-*.bash' -print0 | sort -z)
    fi
}

elapsed_duration() {
    local start="$1" end="$2"
    local start_seconds start_fraction end_seconds end_fraction
    local start_us end_us elapsed_us rounded_centiseconds seconds centiseconds

    start_seconds="${start%%.*}"
    start_fraction="${start#*.}000000"
    start_fraction="${start_fraction:0:6}"
    end_seconds="${end%%.*}"
    end_fraction="${end#*.}000000"
    end_fraction="${end_fraction:0:6}"

    start_us=$(( start_seconds * 1000000 + 10#$start_fraction ))
    end_us=$(( end_seconds * 1000000 + 10#$end_fraction ))
    elapsed_us=$(( end_us - start_us ))
    (( elapsed_us >= 0 )) || elapsed_us=0
    rounded_centiseconds=$(( (elapsed_us + 5000) / 10000 ))
    seconds=$(( rounded_centiseconds / 100 ))
    centiseconds=$(( rounded_centiseconds % 100 ))
    printf '%d.%02ds\n' "$seconds" "$centiseconds"
}

effective_timeout() {
    local record_timeout="$1"
    if [[ -n "$TEST_CASE_TIMEOUT_SECONDS" ]]; then
        printf '%s\n' "$TEST_CASE_TIMEOUT_SECONDS"
    else
        printf '%s\n' "$record_timeout"
    fi
}

print_cases() {
    local suite="$1"
    shift
    local record logical_id case_file mode record_timeout timeout_seconds

    printf '%s:\n' "$suite"
    for record in "$@"; do
        IFS='|' read -r logical_id case_file mode record_timeout <<<"$record"
        timeout_seconds="$(effective_timeout "$record_timeout")"
        printf '  %s|%s|%s|%s\n' "$logical_id" "$case_file" "$mode" "$timeout_seconds"
    done
}

print_case_files() {
    local record case_file
    local -A seen_paths=()

    rebuild_all_cases
    for record in "${ALL_CASES[@]}"; do
        IFS='|' read -r _ case_file _ _ <<<"$record"
        seen_paths["$case_file"]=1
    done
    printf '%s\n' "${!seen_paths[@]}" | LC_ALL=C sort
}

resolve_timeout_candidate() {
    local requested="$1"
    if [[ "$requested" == */* ]]; then
        [[ -x "$requested" ]] || return 1
        printf '%s\n' "$requested"
        return 0
    fi
    command -v "$requested" 2>/dev/null
}

configure_timeout() {
    local candidate requested resolved version_output
    local -a requested_candidates=()

    if [[ -n "${VAULTWARDEN_TEST_RUNNER_TIMEOUT_COMMAND:-}" ]]; then
        requested_candidates+=("$VAULTWARDEN_TEST_RUNNER_TIMEOUT_COMMAND")
    else
        requested_candidates+=(timeout gtimeout)
    fi

    for requested in "${requested_candidates[@]}"; do
        if ! resolved="$(resolve_timeout_candidate "$requested")"; then
            continue
        fi
        candidate="$resolved"
        version_output="$(LC_ALL=C "$candidate" --version 2>/dev/null || true)"
        if [[ "$version_output" != *"GNU coreutils"* ]]; then
            TIMEOUT_NOTICE="NOTE: '$candidate' is not a supported GNU timeout implementation; logical cases will run without a deadline."
            continue
        fi
        if ! LC_ALL=C "$candidate" --kill-after=1s --verbose 1s \
            "$BASH" -c 'exit 0' >/dev/null 2>&1; then
            TIMEOUT_NOTICE="NOTE: '$candidate' does not support the required GNU timeout options; logical cases will run without a deadline."
            continue
        fi
        TIMEOUT_MODE="gnu"
        TIMEOUT_COMMAND=("$candidate" --kill-after=10s)
        TIMEOUT_DESCRIPTION="timeout via ${candidate##*/}"
        TIMEOUT_NOTICE=""
        return 0
    done
}

ensure_runner_temp_dir() {
    if [[ -z "$RUNNER_TEMP_DIR" ]]; then
        RUNNER_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vaultwarden-test-runner.XXXXXX")"
    fi
}

prepare_test_compat_bin() {
    local compat_bin
    ensure_runner_temp_dir
    compat_bin="${RUNNER_TEMP_DIR}/compat-bin"
    mkdir -p "$compat_bin"
    cat > "${compat_bin}/stat" <<'EOF_STAT'
#!/usr/bin/env bash
set -euo pipefail
readonly REAL_STAT="${VW_TEST_REAL_STAT:-/usr/bin/stat}"
[[ -x "$REAL_STAT" ]] || { printf 'test stat adapter: real stat is unavailable at %s\n' "$REAL_STAT" >&2; exit 127; }
if "$REAL_STAT" --version 2>/dev/null | grep -q 'GNU coreutils' \
    && (( $# == 3 )) && [[ "$1" == "-f" ]]; then
    case "$2" in
        '%Lp'|'%OLp') exec "$REAL_STAT" -c '%a' "$3" ;;
        '%u')         exec "$REAL_STAT" -c '%u' "$3" ;;
        '%g')         exec "$REAL_STAT" -c '%g' "$3" ;;
        '%m')         exec "$REAL_STAT" -c '%Y' "$3" ;;
        '%Su')        exec "$REAL_STAT" -c '%U' "$3" ;;
        '%Sg')        exec "$REAL_STAT" -c '%G' "$3" ;;
    esac
fi
exec "$REAL_STAT" "$@"
EOF_STAT
    chmod 0755 "${compat_bin}/stat"
    PATH="${compat_bin}:$PATH"
    export PATH
}

execute_case() {
    local logical_id="$1" case_file="$2" mode="$3" timeout_seconds="$4"
    local rc timeout_stderr
    CASE_TIMED_OUT=false

    if [[ "$TIMEOUT_MODE" != "gnu" ]]; then
        set +e
        env "VW_TEST_CASE_MODE=$mode" "$BASH" "$case_file"
        rc=$?
        set -e
        return "$rc"
    fi

    ensure_runner_temp_dir
    timeout_stderr="$RUNNER_TEMP_DIR/timeout.stderr"
    : > "$timeout_stderr"
    set +e
    env "VW_TEST_CASE_MODE=$mode" LC_ALL=C \
        "${TIMEOUT_COMMAND[@]}" --verbose "${timeout_seconds}s" \
        "$BASH" -c 'exec "$@" 2>&3' _ "$BASH" "$case_file" \
        3>&2 2>"$timeout_stderr"
    rc=$?
    set -e

    if [[ -s "$timeout_stderr" ]]; then
        cat "$timeout_stderr" >&2
    fi
    if grep -Fq 'sending signal TERM to command' "$timeout_stderr"; then
        CASE_TIMED_OUT=true
    fi
    return "$rc"
}

run_suite() {
    local suite="$1"
    shift
    local -a records=("$@")
    local record logical_id case_file mode record_timeout timeout_seconds rc
    local start_time end_time duration

    echo "SUITE $suite (${#records[@]} logical cases; $TIMEOUT_DESCRIPTION)"
    [[ -z "$TIMEOUT_NOTICE" ]] || echo "$TIMEOUT_NOTICE" >&2
    for record in "${records[@]}"; do
        IFS='|' read -r logical_id case_file mode record_timeout <<<"$record"
        timeout_seconds="$(effective_timeout "$record_timeout")"
        echo "RUN     $logical_id [$case_file mode=$mode timeout=${timeout_seconds}s]"
        start_time="$EPOCHREALTIME"
        if execute_case "$logical_id" "$case_file" "$mode" "$timeout_seconds"; then
            end_time="$EPOCHREALTIME"
            duration="$(elapsed_duration "$start_time" "$end_time")"
            echo "PASS    $logical_id ($duration) [$case_file]"
        else
            rc=$?
            end_time="$EPOCHREALTIME"
            duration="$(elapsed_duration "$start_time" "$end_time")"
            if [[ "$CASE_TIMED_OUT" == true ]]; then
                echo "TIMEOUT $logical_id ($duration) [$case_file] after ${timeout_seconds}s" >&2
            else
                echo "FAIL    $logical_id ($duration) [$case_file] (exit $rc)" >&2
            fi
            return "$rc"
        fi
    done
    echo "PASS    suite:$suite (${#records[@]} logical cases)"
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
validate_timeout_override
validate_record_definitions
if [[ -n "${VAULTWARDEN_TEST_RUNNER_TESTS_DIR:-}" ]]; then
    map_fixture_records FOUNDATION_CASES
    map_fixture_records SECURITY_CASES
    map_fixture_records OPERATIONS_CASES
    map_fixture_records DATA_PROTECTION_CASES
fi
validate_inventory_files

case "$1" in
    foundation)
        prepare_test_compat_bin; configure_timeout
        run_suite foundation "${FOUNDATION_CASES[@]}"
        ;;
    security)
        prepare_test_compat_bin; configure_timeout
        run_suite security "${SECURITY_CASES[@]}"
        ;;
    operations)
        prepare_test_compat_bin; configure_timeout
        run_suite operations "${OPERATIONS_CASES[@]}"
        ;;
    data-protection)
        prepare_test_compat_bin; configure_timeout
        run_suite data-protection "${DATA_PROTECTION_CASES[@]}"
        ;;
    all)
        prepare_test_compat_bin; configure_timeout
        run_suite foundation "${FOUNDATION_CASES[@]}"
        run_suite security "${SECURITY_CASES[@]}"
        run_suite operations "${OPERATIONS_CASES[@]}"
        run_suite data-protection "${DATA_PROTECTION_CASES[@]}"
        rebuild_all_cases
        echo "PASS    all (${#ALL_CASES[@]} logical cases across 4 suites)"
        ;;
    list)
        print_cases foundation "${FOUNDATION_CASES[@]}"
        print_cases security "${SECURITY_CASES[@]}"
        print_cases operations "${OPERATIONS_CASES[@]}"
        print_cases data-protection "${DATA_PROTECTION_CASES[@]}"
        ;;
    list-files)
        print_case_files
        ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
