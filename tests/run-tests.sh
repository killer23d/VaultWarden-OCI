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
    echo "Usage: ./tests/run-tests.sh all"
}

[[ "${1:-}" == "all" && $# -eq 1 ]] || {
    usage >&2
    exit 2
}

TESTS=(
    tests/test-architecture.sh
    tests/test-security-privileges.sh
    tests/test-permissions.sh
    tests/test-config-env.sh
    tests/test-secrets.sh
    tests/test-operations.sh
    tests/test-lifecycle.sh
    tests/test-systemd.sh
    tests/test-email.sh
    tests/test-storage-setup.sh
    tests/test-backup.sh
    tests/test-restore-recovery.sh
    tests/test-operator-ui.sh
    tests/test-crowdsec.sh
    tests/test-uninstall.sh
)

for (( i = 0; i < ${#TESTS[@]}; i++ )); do
    for (( j = i + 1; j < ${#TESTS[@]}; j++ )); do
        if [[ "${TESTS[$i]}" == "${TESTS[$j]}" ]]; then
            echo "FAIL duplicate test inventory entry: ${TESTS[$i]}" >&2
            exit 1
        fi
    done
done

for test_file in "${TESTS[@]}"; do
    if [[ ! -f "$test_file" ]]; then
        echo "FAIL listed test does not exist: $test_file" >&2
        exit 1
    fi
done

while IFS= read -r -d '' discovered; do
    discovered="${discovered#./}"
    listed=false
    for test_file in "${TESTS[@]}"; do
        if [[ "$discovered" == "$test_file" ]]; then
            listed=true
            break
        fi
    done
    if [[ "$listed" != true ]]; then
        echo "FAIL unlisted permanent test file: $discovered" >&2
        exit 1
    fi
done < <(find tests -maxdepth 1 -type f -name 'test-*.sh' -print0 | sort -z)

for test_file in "${TESTS[@]}"; do
    echo "RUN  $test_file"
    if "$BASH" "$test_file"; then
        echo "PASS $test_file"
    else
        rc=$?
        echo "FAIL $test_file (exit $rc)" >&2
        exit "$rc"
    fi
done

echo "PASS all (${#TESTS[@]} tests)"
