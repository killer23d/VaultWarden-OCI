#!/usr/bin/env bash
# Consolidated architecture regression suite.
set -euo pipefail

check_architecture_helpers() (
# Focused checks for architecture selection at artifact boundaries.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_output() {
    local expected="$1"
    shift
    local actual
    actual="$("$@")" || fail "command failed: $*"
    [[ "$actual" == "$expected" ]] || fail "expected '$expected', got '$actual' from: $*"
}

assert_fails() {
    if "$@" >/dev/null 2>&1; then
        fail "expected failure from: $*"
    fi
}

setup_system="${PROJECT_ROOT}/utilities/setup-system.sh"
setup_crowdsec="${PROJECT_ROOT}/utilities/setup-crowdsec.sh"

assert_output "http://archive.ubuntu.com/ubuntu" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" ubuntu-archive-url amd64
assert_output "http://ports.ubuntu.com/ubuntu-ports" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" ubuntu-archive-url arm64
assert_output "http://ports.ubuntu.com/ubuntu-ports" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" ubuntu-archive-url s390x

assert_output "amd64" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-release-arch amd64
assert_output "arm64" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-release-arch arm64
assert_output "arm" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-release-arch armhf
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-release-arch riscv64

assert_output "amd64" env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_crowdsec" amd64
assert_output "amd64" env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_crowdsec" x86_64
assert_output "arm64" env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_crowdsec" arm64
assert_output "arm64" env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_crowdsec" aarch64
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_crowdsec" riscv64

printf 'Architecture helper tests passed.\n'

)

check_architecture_helpers
check_repository_interface_cleanup_contracts() (
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# The direct shell runner remains the canonical repository regression entry point.
grep -Fq 'Usage: ./tests/run-tests.sh all' tests/run-tests.sh \
    || fail 'run-tests usage must advertise ./tests/run-tests.sh all'
grep -Fq 'tests/test-architecture.sh' tests/run-tests.sh \
    || fail 'consolidated tests must be inventoried directly in run-tests.sh'

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

printf 'PASS: repository interface cleanup contracts\n'
)

check_repository_interface_cleanup_contracts
