#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

patterns=(
    "y""/N"
    "Y""/n"
    "[y""/n]"
    "[Y""/N]"
    "[Y""/n]"
    "[y""/N]"
)

rg_args=(
    --hidden
    --fixed-strings
    --line-number
    --glob '!/.git/**'
    --glob '!*.png'
    --glob '!*.jpg'
    --glob '!*.jpeg'
    --glob '!*.gif'
    --glob '!*.ico'
    --glob '!*.pdf'
)

for pattern in "${patterns[@]}"; do
    set +e
    matches="$(rg "${rg_args[@]}" -- "$pattern" "$ROOT")"
    status=$?
    set -e
    if [[ $status -eq 0 ]]; then
        printf '%s\n' "$matches"
        echo "FAIL: active content contains shorthand confirmation prompt: $pattern" >&2
        exit 1
    fi
    if [[ $status -ne 1 ]]; then
        echo "FAIL: prompt shorthand scan failed for pattern: $pattern" >&2
        exit "$status"
    fi
done

echo "OK: confirmation prompts use full yes/no display text"
