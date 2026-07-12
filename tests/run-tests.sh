#!/usr/bin/env bash
set -euo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
    for bash5 in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [[ -x "$bash5" ]]; then
            exec "$bash5" "$0" "$@"
        fi
    done
fi
PATH="$(dirname "$BASH"):$PATH"
export PATH

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
    cat <<'USAGE'
Usage: ./tests/run-tests.sh <suite>

Suites:
  foundation       Architecture, configuration, permissions, storage, systemd
  security         Security/privilege, secrets, and email contracts
  operations       Operations, lifecycle, operator UI, CrowdSec, uninstall
  data-protection  Backup and restore/recovery contracts
  all              Run every suite in the order above
  list             Print the case inventory without running it
USAGE
}

FOUNDATION_CASES=(
    tests/case-architecture.bash
    tests/case-config-env.bash
    tests/case-permissions.bash
    tests/case-storage-setup.bash
    tests/case-systemd.bash
)

SECURITY_CASES=(
    tests/case-security-privileges.bash
    tests/case-secrets.bash
    tests/case-email.bash
)

OPERATIONS_CASES=(
    tests/case-operations.bash
    tests/case-lifecycle.bash
    tests/case-operator-ui.bash
    tests/case-crowdsec.bash
    tests/case-uninstall.bash
)

DATA_PROTECTION_CASES=(
    tests/case-backup.bash
    tests/case-restore-recovery.bash
)

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

    while IFS= read -r -d '' discovered; do
        discovered="${discovered#./}"
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
    done < <(find tests -maxdepth 1 -type f -name 'case-*.bash' -print0 | sort -z)

    if find tests -maxdepth 1 -type f -name 'test-*.sh' ! -name 'run-tests.sh' -print -quit | grep -q .; then
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

run_suite() {
    local suite="$1"
    shift
    local -a cases=("$@")
    local case_file

    echo "SUITE $suite (${#cases[@]} cases)"
    for case_file in "${cases[@]}"; do
        echo "RUN   $case_file"
        if "$BASH" "$case_file"; then
            echo "PASS  $case_file"
        else
            local rc=$?
            echo "FAIL  $case_file (exit $rc)" >&2
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
        run_suite foundation "${FOUNDATION_CASES[@]}"
        ;;
    security)
        run_suite security "${SECURITY_CASES[@]}"
        ;;
    operations)
        run_suite operations "${OPERATIONS_CASES[@]}"
        ;;
    data-protection)
        run_suite data-protection "${DATA_PROTECTION_CASES[@]}"
        ;;
    all)
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
