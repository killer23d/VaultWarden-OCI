#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

script="utilities/maintenance-email.sh"

[[ -f "$script" ]] || fail "$script not found"

grep -Fq 'require_root "$@"' "$script" \
    || fail "maintenance email diagnostic must require root"

! grep -Fq 'refuse_root_for_user_command' "$script" \
    || fail "maintenance email diagnostic must not refuse root"

grep -Fq 'sudo ./maintenance.sh test-email' "$script" \
    || fail "dispatcher help must show sudo ./maintenance.sh test-email"

grep -Fq 'sudo utilities/maintenance-email.sh' "$script" \
    || fail "direct help must show sudo utilities/maintenance-email.sh"

pass "maintenance-email.sh is root-operated"
