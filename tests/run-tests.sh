#!/usr/bin/env bash
set -euo pipefail

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
    tests/test-architecture-helpers.sh
    tests/test-security-helpers.sh
    tests/test-secrets-cli-help.sh
    tests/test-privilege-contracts.sh
    tests/test-permission-repair-contract.sh
    tests/test-permission-contract-central.sh
    tests/test-env-edit.sh
    tests/test-config-systemd-followup.sh
    tests/test-secrets-env-systemd-guards.sh
    tests/test-systemd-operation-runtime-paths.sh
    tests/test-start-policy.sh
    tests/test-operation-guards.sh
    tests/test-post-pr224-operation-contracts.sh
    tests/test-startup-lifecycle-guards.sh
    tests/test-health-operation-contract.sh
    tests/test-maintenance-email-root.sh
    tests/test-email-refactor.sh
    tests/test-migrate-followup.sh
    tests/test-setup-storage-ux.sh
    tests/test-setup-secrets-transaction.sh
    tests/test-backup-architecture-policy.sh
    tests/test-backup-restore-behavior.sh
    tests/test-restore-run-followup.sh
    tests/test-restore-backup-preflight-safety.sh
    tests/test-restore-confirmation-safety.sh
    tests/test-recover.sh
    tests/test-operator-ui.sh
    tests/test-confirmation-prompt-format.sh
    tests/test-crowdsec-config.sh
    tests/test-uninstall-vaultwarden.sh
)

declare -A seen=()
for test_file in "${TESTS[@]}"; do
    if [[ -n "${seen[$test_file]:-}" ]]; then
        echo "FAIL duplicate test inventory entry: $test_file" >&2
        exit 1
    fi
    seen[$test_file]=1
    if [[ ! -f "$test_file" ]]; then
        echo "FAIL listed test does not exist: $test_file" >&2
        exit 1
    fi
done

while IFS= read -r -d '' discovered; do
    discovered="${discovered#./}"
    if [[ -z "${seen[$discovered]:-}" ]]; then
        echo "FAIL unlisted permanent test file: $discovered" >&2
        exit 1
    fi
done < <(find tests -maxdepth 1 -type f -name 'test-*.sh' -print0 | sort -z)

for test_file in "${TESTS[@]}"; do
    echo "RUN  $test_file"
    if bash "$test_file"; then
        echo "PASS $test_file"
    else
        rc=$?
        echo "FAIL $test_file (exit $rc)" >&2
        exit "$rc"
    fi
done

echo "PASS all (${#TESTS[@]} tests)"
