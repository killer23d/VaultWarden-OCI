#!/usr/bin/env bash
# Helpers for deterministic command mocks and deliberately isolated PATHs.

if ! declare -F test_fail >/dev/null 2>&1; then
    # shellcheck source=assertions.bash
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/assertions.bash"
fi

if [[ -z "${VW_TEST_COMMAND_MOCKS_LOADED:-}" ]]; then
    VW_TEST_COMMAND_MOCKS_LOADED=1
    readonly VW_TEST_COMMAND_MOCKS_LOADED

    test_write_command_mock() {
        local path="$1"

        mkdir -p "$(dirname "$path")"
        {
            printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
            cat
        } >"$path"
        chmod 0755 "$path"
    }

    test_build_isolated_path() {
        local destination="$1"
        shift
        local command_name resolved

        mkdir -p "$destination"
        for command_name in "$@"; do
            resolved="$(command -v "$command_name" 2>/dev/null)" \
                || test_fail "required fixture command is unavailable: $command_name"
            [[ "$resolved" == /* && -x "$resolved" ]] \
                || test_fail "fixture command did not resolve to an executable path: $command_name"
            ln -s "$resolved" "$destination/$command_name"
        done
        printf '%s\n' "$destination"
    }
fi
