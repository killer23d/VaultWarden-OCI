#!/usr/bin/env bash
# Small, dependency-free assertions shared by executable test cases.

if [[ -z "${VW_TEST_ASSERTIONS_LOADED:-}" ]]; then
    VW_TEST_ASSERTIONS_LOADED=1
    readonly VW_TEST_ASSERTIONS_LOADED

    test_fail() {
        printf 'FAIL: %s\n' "$*" >&2
        exit 1
    }

    test_assert_file_contains() {
        local file="$1" expected="$2"
        grep -Fq -- "$expected" "$file" \
            || test_fail "expected $file to contain: $expected"
    }

    test_assert_file_not_contains() {
        local file="$1" unexpected="$2"
        if grep -Fq -- "$unexpected" "$file"; then
            test_fail "expected $file not to contain: $unexpected"
        fi
    }

    test_assert_equal() {
        local actual="$1" expected="$2"
        [[ "$actual" == "$expected" ]] \
            || test_fail "expected '$actual' == '$expected'"
    }

    test_assert_not_exists() {
        local path="$1"
        [[ ! -e "$path" && ! -L "$path" ]] \
            || test_fail "expected path not to exist: $path"
    }

    test_wait_for_file() {
        local file="$1" attempts="${2:-200}" delay="${3:-0.05}"
        local attempt

        for (( attempt = 1; attempt <= attempts; attempt++ )); do
            [[ -e "$file" ]] && return 0
            sleep "$delay"
        done
        test_fail "timed out waiting for $file"
    }
fi
