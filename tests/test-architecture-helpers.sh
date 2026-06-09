#!/usr/bin/env bash
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
