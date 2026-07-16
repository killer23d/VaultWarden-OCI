#!/usr/bin/env bash
# Shared repository-root resolution for cases under tests/suites/<suite>/.

if [[ -z "${VW_TEST_REPO_ROOT_LOADED:-}" ]]; then
    _vw_test_helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    VW_TEST_REPO_ROOT="$(cd "${_vw_test_helper_dir}/../.." && pwd)"
    readonly VW_TEST_REPO_ROOT
    export VW_TEST_REPO_ROOT
    VW_TEST_REPO_ROOT_LOADED=1
    readonly VW_TEST_REPO_ROOT_LOADED
    unset _vw_test_helper_dir
fi
