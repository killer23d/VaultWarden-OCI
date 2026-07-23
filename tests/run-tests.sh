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
TEST_CASE_TIMEOUT_SECONDS="${TEST_CASE_TIMEOUT_SECONDS:-120}"
if [[ ! "$TEST_CASE_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "FAIL TEST_CASE_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 2
fi

TIMEOUT_MODE="none"
TIMEOUT_DESCRIPTION="timeout unavailable; no per-case deadline"
TIMEOUT_NOTICE="NOTE: per-case timeout enforcement is unavailable; install GNU coreutils timeout or gtimeout to enable it."
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

Suites:
  foundation       Architecture, configuration, permissions, storage, systemd
  security         Security/privilege, secrets, and email contracts
  operations       Operations, lifecycle, operator UI, CrowdSec, uninstall
  data-protection  Backup and restore/recovery contracts
  all              Run every suite in the order above
  list             Print the case inventory without running it

Examples:
  ./tests/run-tests.sh all
  ./tests/run-tests.sh foundation
USAGE
}

FOUNDATION_CASES=(
    tests/test-architecture.sh
    tests/suites/foundation/case-runner-contracts.bash
    tests/suites/foundation/case-config-env.bash
    tests/suites/foundation/case-permissions.bash
    tests/suites/foundation/case-storage-setup.bash
    tests/suites/foundation/case-systemd.bash
)

SECURITY_CASES=(
    tests/suites/security/case-security-privileges.bash
    tests/suites/security/case-secrets.bash
    tests/suites/security/case-email.bash
)

OPERATIONS_CASES=(
    tests/suites/operations/case-operations.bash
    tests/suites/operations/case-health-alerts.bash
    tests/suites/operations/case-lock-fd-hygiene.bash
    tests/suites/operations/case-lifecycle.bash
    tests/suites/operations/case-startup-lifecycle-hardening.bash
    tests/suites/operations/case-operator-ui.bash
    tests/suites/operations/case-firewall-update.bash
    tests/suites/operations/case-crowdsec.bash
    tests/suites/operations/case-crowdsec-notifications.bash
    tests/suites/operations/case-uninstall.bash
)

DATA_PROTECTION_CASES=(
    tests/suites/data-protection/case-backup.bash
    tests/suites/data-protection/case-restore-recovery.bash
)

# Internal fixture hooks for runner-contract tests. They are not part of the
# supported developer CLI and never modify the repository's real tests tree.
if [[ -n "${VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_CASE:-}" \
    && -z "${VAULTWARDEN_TEST_RUNNER_TESTS_DIR:-}" ]]; then
    echo "FAIL VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_CASE requires VAULTWARDEN_TEST_RUNNER_TESTS_DIR fixture mode" >&2
    exit 2
fi

map_fixture_cases() {
    local array_name="$1"
    local -n cases_ref="$array_name"
    local index relative_path

    for index in "${!cases_ref[@]}"; do
        relative_path="${cases_ref[$index]#tests/}"
        cases_ref[$index]="${TESTS_DIR%/}/${relative_path}"
    done
}

if [[ -n "${VAULTWARDEN_TEST_RUNNER_TESTS_DIR:-}" ]]; then
    map_fixture_cases FOUNDATION_CASES
    map_fixture_cases SECURITY_CASES
    map_fixture_cases OPERATIONS_CASES
    map_fixture_cases DATA_PROTECTION_CASES

    if [[ -n "${VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_CASE:-}" ]]; then
        FOUNDATION_CASES+=("$VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_CASE")
    fi
fi

ALL_CASES=(
    "${FOUNDATION_CASES[@]}"
    "${SECURITY_CASES[@]}"
    "${OPERATIONS_CASES[@]}"
    "${DATA_PROTECTION_CASES[@]}"
)

validate_inventory() {
    local i j case_file discovered listed

    for (( i = 0; i < ${#ALL_CASES[@]}; i++ )); do
        for (( j = i + 1; j < ${#ALL_CASES[@]}; j++ )); do
            if [[ "${ALL_CASES[$i]}" == "${ALL_CASES[$j]}" ]]; then
                echo "FAIL duplicate case inventory entry: ${ALL_CASES[$i]}" >&2
                exit 1
            fi
        done
    done

    for case_file in "${ALL_CASES[@]}"; do
        if [[ ! -f "$case_file" ]]; then
            echo "FAIL listed test case does not exist: $case_file" >&2
            exit 1
        fi
    done

    if find "$TESTS_DIR" -maxdepth 1 -type f -name 'case-*.bash' -print -quit | grep -q .; then
        echo "FAIL permanent case files must live under tests/suites and be registered in tests/run-tests.sh" >&2
        exit 1
    fi

    if [[ -d "$TESTS_DIR/suites" ]]; then
        while IFS= read -r -d '' discovered; do
            listed=false
            for case_file in "${ALL_CASES[@]}"; do
                if [[ "$discovered" == "$case_file" ]]; then
                    listed=true
                    break
                fi
            done
            if [[ "$listed" != true ]]; then
                echo "FAIL unlisted permanent test case: $discovered" >&2
                exit 1
            fi
        done < <(find "$TESTS_DIR/suites" -type f -name 'case-*.bash' -print0 | sort -z)
    fi

    if find "$TESTS_DIR" -maxdepth 1 -type f -name 'test-*.sh' \
        ! -name 'test-architecture.sh' -print -quit | grep -q .; then
        echo "FAIL permanent tests must be registered as case-*.bash and run through tests/run-tests.sh" >&2
        exit 1
    fi
}

print_cases() {
    local suite="$1"
    shift
    local case_file
    printf '%s:\n' "$suite"
    for case_file in "$@"; do
        printf '  %s\n' "$case_file"
    done
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
            TIMEOUT_NOTICE="NOTE: '$candidate' is not a supported GNU timeout implementation; cases will run without a per-case deadline."
            continue
        fi
        if ! LC_ALL=C "$candidate" --kill-after=1s --verbose 1s \
            "$BASH" -c 'exit 0' >/dev/null 2>&1; then
            TIMEOUT_NOTICE="NOTE: '$candidate' does not support the required GNU timeout options; cases will run without a per-case deadline."
            continue
        fi

        TIMEOUT_MODE="gnu"
        TIMEOUT_COMMAND=("$candidate" --kill-after=10s)
        TIMEOUT_DESCRIPTION="timeout ${TEST_CASE_TIMEOUT_SECONDS}s each via ${candidate##*/}"
        TIMEOUT_NOTICE=""
        return 0
    done

    return 0
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
# Test-only compatibility adapter for BSD stat format probes on GNU/Linux.
set -euo pipefail

readonly REAL_STAT="${VW_TEST_REAL_STAT:-/usr/bin/stat}"

if [[ ! -x "$REAL_STAT" ]]; then
    printf 'test stat adapter: real stat is unavailable at %s\n' "$REAL_STAT" >&2
    exit 127
fi

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
    local case_file="$1"
    local rc timeout_stderr

    CASE_TIMED_OUT=false

    if [[ "$TIMEOUT_MODE" != "gnu" ]]; then
        set +e
        "$BASH" "$case_file"
        rc=$?
        set -e
        return "$rc"
    fi

    ensure_runner_temp_dir
    timeout_stderr="$RUNNER_TEMP_DIR/timeout.stderr"
    : > "$timeout_stderr"

    set +e
    LC_ALL=C "${TIMEOUT_COMMAND[@]}" --verbose \
        "${TEST_CASE_TIMEOUT_SECONDS}s" \
        "$BASH" -c 'exec "$@" 2>&3' _ "$BASH" "$case_file" \
        3>&2 2>"$timeout_stderr"
    rc=$?
    set -e

    if [[ -s "$timeout_stderr" ]]; then
        cat "$timeout_stderr" >&2
    fi
    if grep -Eq '^[^:]+: sending signal TERM to command ' "$timeout_stderr"; then
        CASE_TIMED_OUT=true
    fi

    return "$rc"
}

run_suite() {
    local suite="$1"
    shift
    local -a cases=("$@")
    local case_file rc

    echo "SUITE $suite (${#cases[@]} cases; $TIMEOUT_DESCRIPTION)"
    if [[ -n "$TIMEOUT_NOTICE" ]]; then
        echo "$TIMEOUT_NOTICE" >&2
    fi
    for case_file in "${cases[@]}"; do
        echo "RUN   $case_file"
        if execute_case "$case_file"; then
            echo "PASS  $case_file"
        else
            rc=$?
            if [[ "$CASE_TIMED_OUT" == true ]]; then
                echo "TIMEOUT $case_file after ${TEST_CASE_TIMEOUT_SECONDS}s" >&2
            else
                echo "FAIL  $case_file (exit $rc)" >&2
            fi
            return "$rc"
        fi
    done
    echo "PASS  suite:$suite (${#cases[@]} cases)"
}

[[ $# -eq 1 ]] || {
    usage >&2
    exit 2
}

validate_inventory

case "$1" in
    foundation)
        prepare_test_compat_bin
        configure_timeout
        run_suite foundation "${FOUNDATION_CASES[@]}"
        ;;
    security)
        prepare_test_compat_bin
        configure_timeout
        run_suite security "${SECURITY_CASES[@]}"
        ;;
    operations)
        prepare_test_compat_bin
        configure_timeout
        run_suite operations "${OPERATIONS_CASES[@]}"
        ;;
    data-protection)
        prepare_test_compat_bin
        configure_timeout
        run_suite data-protection "${DATA_PROTECTION_CASES[@]}"
        ;;
    all)
        prepare_test_compat_bin
        configure_timeout
        run_suite foundation "${FOUNDATION_CASES[@]}"
        run_suite security "${SECURITY_CASES[@]}"
        run_suite operations "${OPERATIONS_CASES[@]}"
        run_suite data-protection "${DATA_PROTECTION_CASES[@]}"
        echo "PASS  all (${#ALL_CASES[@]} cases across 4 suites)"
        ;;
    list)
        print_cases foundation "${FOUNDATION_CASES[@]}"
        print_cases security "${SECURITY_CASES[@]}"
        print_cases operations "${OPERATIONS_CASES[@]}"
        print_cases data-protection "${DATA_PROTECTION_CASES[@]}"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
