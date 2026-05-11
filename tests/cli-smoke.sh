#!/usr/bin/env bash
# tests/cli-smoke.sh
# CLI smoke tests for every Type A script — tests only help/dry-run/zero-arg
# behaviour.  Does NOT require a live VaultWarden system, root privileges, or
# external dependencies.  All tests run by checking exit codes and output only.
#
# Usage:
#   bash tests/cli-smoke.sh          # run all tests
#   bash tests/cli-smoke.sh -v       # verbose (show each PASS/FAIL inline)

set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; SKIP=0
VERBOSE=false
[[ "${1:-}" == "-v" ]] && VERBOSE=true

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; RESET=$'\033[0m'

_pass() { PASS=$(( PASS + 1 )); $VERBOSE && echo "${GREEN}PASS${RESET}  $1"; }
_fail() { FAIL=$(( FAIL + 1 )); echo "${RED}FAIL${RESET}  $1"; }
_skip() { SKIP=$(( SKIP + 1 )); $VERBOSE && echo "${YELLOW}SKIP${RESET}  $1"; }

# expect_exit EXPECTED_CODE LABEL SCRIPT [ARGS...]
# Runs 'bash SCRIPT [ARGS...]' and checks the exit code.
expect_exit() {
    local expected="$1"; shift
    local label="$1"; shift
    local script="$1"; shift
    local actual
    actual="$(bash "$script" "$@" >/dev/null 2>&1; echo $?)" || true
    if [[ "$actual" == "$expected" ]]; then
        _pass "$label"
    else
        _fail "$label (expected exit $expected, got $actual)"
    fi
}

# expect_output_contains LABEL PATTERN SCRIPT [ARGS...]
expect_output_contains() {
    local label="$1"; shift
    local pattern="$1"; shift
    local script="$1"; shift
    local out
    out="$(bash "$script" "$@" 2>&1)" || true
    if echo "$out" | grep -qiE "$pattern"; then
        _pass "$label"
    else
        _fail "$label (pattern not found: '$pattern')"
    fi
}

# Resolve scripts relative to the repo root (parent of tests/)
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Script: backup.sh ────────────────────────────────────────────────────────
BACKUP="$REPO/backup.sh"

expect_exit 0 "backup.sh: zero args → exit 0" "$BACKUP"
expect_output_contains "backup.sh: zero args → shows USAGE" "USAGE|usage|subcommand" "$BACKUP"
expect_exit 0 "backup.sh: --help → exit 0" "$BACKUP" --help
expect_exit 0 "backup.sh: -h → exit 0" "$BACKUP" -h
expect_exit 0 "backup.sh: help → exit 0" "$BACKUP" help
expect_exit 1 "backup.sh: unknown subcommand → exit 1" "$BACKUP" bogus-subcommand

# ── Script: restore.sh ───────────────────────────────────────────────────────
RESTORE="$REPO/restore.sh"

# restore.sh is destructive: zero args → exit 1
expect_exit 1 "restore.sh: zero args → exit 1" "$RESTORE"
expect_exit 0 "restore.sh: --help → exit 0" "$RESTORE" --help
expect_exit 0 "restore.sh: -h → exit 0" "$RESTORE" -h
expect_exit 0 "restore.sh: help → exit 0" "$RESTORE" help
expect_exit 1 "restore.sh: unknown subcommand → exit 1" "$RESTORE" bogus-subcommand

expect_output_contains "restore.sh: --help → shows interactive" "interactive" "$RESTORE" --help
expect_output_contains "restore.sh: --help → shows latest" "latest" "$RESTORE" --help
expect_output_contains "restore.sh: --help → shows list" "list" "$RESTORE" --help

# ── Script: setup.sh ─────────────────────────────────────────────────────────
SETUP="$REPO/setup.sh"

expect_exit 0 "setup.sh: --help → exit 0" "$SETUP" --help
expect_exit 0 "setup.sh: -h → exit 0" "$SETUP" -h
expect_exit 0 "setup.sh: help → exit 0" "$SETUP" help
expect_exit 1 "setup.sh: unknown subcommand → exit 1" "$SETUP" bogus-subcommand

# systemd sub-actions — help always works
expect_exit 0 "setup.sh: systemd help → exit 0" "$SETUP" systemd help
expect_exit 0 "setup.sh: systemd --help → exit 0" "$SETUP" systemd --help
# unknown sub-action in systemd
expect_exit 1 "setup.sh: systemd bogus → exit 1" "$SETUP" systemd bogus

# secrets phase — --help should work
expect_exit 0 "setup.sh: secrets --help → exit 0" "$SETUP" secrets --help

# ── Script: maintenance.sh ───────────────────────────────────────────────────
MAINT="$REPO/maintenance.sh"

expect_exit 0 "maintenance.sh: zero args → exit 0" "$MAINT"
expect_exit 0 "maintenance.sh: --help → exit 0" "$MAINT" --help
expect_exit 0 "maintenance.sh: -h → exit 0" "$MAINT" -h
expect_exit 0 "maintenance.sh: help → exit 0" "$MAINT" help
expect_exit 1 "maintenance.sh: unknown subcommand → exit 1" "$MAINT" bogus-subcommand

# run subcommand with dry-run — requires a live .env; skip if not available
if [[ -f "$REPO/.env" ]]; then
    expect_exit 0 "maintenance.sh: run --dry-run → exit 0" "$MAINT" run --dry-run
else
    _skip "maintenance.sh: run --dry-run (no .env present — live-system test skipped)"
fi
# health: unknown option → exit 1
expect_exit 1 "maintenance.sh: health --bogus → exit 1" "$MAINT" health --bogus
# health: --help → exit 0
expect_exit 0 "maintenance.sh: health --help → exit 0" "$MAINT" health --help

# ── Script: startup.sh ───────────────────────────────────────────────────────
STARTUP="$REPO/startup.sh"

expect_exit 0 "startup.sh: --help → exit 0" "$STARTUP" --help
expect_exit 0 "startup.sh: -h → exit 0" "$STARTUP" -h
expect_exit 0 "startup.sh: help → exit 0" "$STARTUP" help
expect_exit 1 "startup.sh: unknown subcommand → exit 1" "$STARTUP" bogus-subcommand

# ── Script: edit-secrets.sh ──────────────────────────────────────────────────
EDITSEC="$REPO/edit-secrets.sh"

expect_exit 0 "edit-secrets.sh: --help → exit 0" "$EDITSEC" --help
expect_exit 0 "edit-secrets.sh: -h → exit 0" "$EDITSEC" -h
expect_exit 0 "edit-secrets.sh: help → exit 0" "$EDITSEC" help
expect_exit 1 "edit-secrets.sh: unknown subcommand → exit 1" "$EDITSEC" bogus-subcommand

# ── Script: create-breakglass-admin.sh ───────────────────────────────────────
BREAKGLASS="$REPO/create-breakglass-admin.sh"

expect_exit 0 "create-breakglass-admin.sh: zero args → exit 0" "$BREAKGLASS"
expect_exit 0 "create-breakglass-admin.sh: --help → exit 0" "$BREAKGLASS" --help
expect_exit 0 "create-breakglass-admin.sh: -h → exit 0" "$BREAKGLASS" -h
expect_exit 0 "create-breakglass-admin.sh: help → exit 0" "$BREAKGLASS" help
expect_exit 1 "create-breakglass-admin.sh: unknown subcommand → exit 1" "$BREAKGLASS" bogus-subcommand

# ── Script: uninstall-vaultwarden.sh ─────────────────────────────────────────
UNINSTALL="$REPO/uninstall-vaultwarden.sh"

# uninstall is destructive: zero args → exit 1
expect_exit 1 "uninstall-vaultwarden.sh: zero args → exit 1" "$UNINSTALL"
expect_output_contains "uninstall-vaultwarden.sh: zero args → shows USAGE" "USAGE|usage|subcommand|run" "$UNINSTALL" || true
expect_exit 0 "uninstall-vaultwarden.sh: --help → exit 0" "$UNINSTALL" --help
expect_exit 0 "uninstall-vaultwarden.sh: -h → exit 0" "$UNINSTALL" -h
expect_exit 0 "uninstall-vaultwarden.sh: help → exit 0" "$UNINSTALL" help
expect_exit 1 "uninstall-vaultwarden.sh: unknown subcommand → exit 1" "$UNINSTALL" bogus-subcommand
expect_exit 1 "uninstall-vaultwarden.sh: run with unknown option → exit 1" "$UNINSTALL" run --bogus-flag

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${GREEN}${PASS} passed${RESET}  ${RED}${FAIL} failed${RESET}  ${YELLOW}${SKIP} skipped${RESET}"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo "${RED}SMOKE TESTS FAILED${RESET}"
    exit 1
fi
echo "${GREEN}All smoke tests passed.${RESET}"
exit 0
