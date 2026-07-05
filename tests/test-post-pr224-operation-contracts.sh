#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPS="$ROOT/lib/operations.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$*"
}

require() {
    grep -Eq -- "$1" "$2" || fail "$3"
}

reject() {
    ! grep -Eq -- "$1" "$2" || fail "$3"
}

require 'VW_OPERATIONS_PROMPT_TIMEOUT' "$OPS" "operation conflict prompts must have a timeout"
require 'global_lock_owned=' "$OPS" "operation state must record explicit global lock ownership"
require '_operation_state_global_owned' "$OPS" "global owner lookup must require explicit global ownership"
reject 'flock -u "\$OPERATION_LOCK_FD"' "$OPS" "global operation release must not explicitly LOCK_UN inherited fd"
require 'last inherited descriptor closes' "$OPS" "global release must document descriptor lifetime semantics"
require 'LC_ALL=C "\$@"' "$OPS" "package helper must run wrapped command with deterministic C locale"
require 'add-apt-repository|apt-add-repository' "$OPS" "package child detection must include repository helpers"
require 'operation_package_run add-apt-repository -y universe' "$ROOT/utilities/setup-system.sh" \
    "add-apt-repository must be routed through operation_package_run"

tmpdir="$(mktemp -d)"
cleanup() {
    [[ -n "${child_pid:-}" ]] && kill "$child_pid" 2>/dev/null || true
    [[ -n "${holder_pid:-}" ]] && kill "$holder_pid" 2>/dev/null || true
    [[ -n "${nonglobal_pid:-}" ]] && kill "$nonglobal_pid" 2>/dev/null || true
    rm -rf "$tmpdir"
}
trap cleanup EXIT

lc_file="$tmpdir/lc-all"
LC_ALL=fr_FR.UTF-8 "$BASH" -c '
    set -euo pipefail
    source "$1"
    operation_package_run bash -c '"'"'printf "%s" "$LC_ALL" > "$1"'"'"' _ "$2"
' _ "$OPS" "$lc_file"
[[ "$(cat "$lc_file")" == "C" ]] || fail "operation_package_run did not force LC_ALL=C for child command"

if [[ "$(uname -s)" != "Linux" || ! -r /proc/$$/stat ]] || ! command -v flock >/dev/null 2>&1; then
    pass "post-PR224 operation contracts static checks; Linux flock/proc behavioral checks skipped on this host"
    exit 0
fi

state_dir="$tmpdir/state"
ops_lock="$tmpdir/vaultwarden-operations.lock"

run_ops_shell() {
    VW_OPERATIONS_STATE_DIR="$state_dir" \
    VW_OPERATIONS_LOCK="$ops_lock" \
    "$BASH" "$@"
}

ready="$tmpdir/child.ready"
stop="$tmpdir/child.stop"
pid_file="$tmpdir/child.pid"
run_ops_shell -c '
    set -euo pipefail
    root="$1"; ready="$2"; stop="$3"; pid_file="$4"
    source "$root/lib/log.sh"
    source "$root/lib/common.sh"
    init_common_lib inherited-parent
    source "$root/lib/operations.sh"
    operation_acquire --id inherited-parent --label "Inherited parent"
    "$BASH" -c '"'"'
        set -euo pipefail
        root="$1"; ready="$2"; stop="$3"; pid_file="$4"
        source "$root/lib/log.sh"
        source "$root/lib/common.sh"
        init_common_lib inherited-child
        source "$root/lib/operations.sh"
        operation_acquire --id inherited-child --label "Inherited child"
        printf "%s\n" "$$" > "$pid_file"
        : > "$ready"
        while [[ ! -f "$stop" ]]; do sleep 0.1; done
        operation_release 0
    '"'"' _ "$root" "$ready" "$stop" "$pid_file" &
    for _ in {1..100}; do
        [[ -f "$ready" ]] && break
        sleep 0.1
    done
    [[ -f "$ready" ]] || exit 1
    operation_release 0
' _ "$ROOT" "$ready" "$stop" "$pid_file"

for _ in {1..100}; do
    [[ -s "$pid_file" ]] && break
    sleep 0.1
done
[[ -s "$pid_file" ]] || fail "inherited child did not start"
child_pid="$(cat "$pid_file")"

set +e
run_ops_shell -c '
    set -euo pipefail
    root="$1"
    source "$root/lib/log.sh"
    source "$root/lib/common.sh"
    init_common_lib inherited-contender
    source "$root/lib/operations.sh"
    operation_acquire --id contender --label "Contender" --non-interactive skip
' _ "$ROOT" </dev/null >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 75 ]] || fail "inherited child must retain global lock after parent release; contender rc=$rc"

: > "$stop"
for _ in {1..100}; do
    ! kill -0 "$child_pid" 2>/dev/null && break
    sleep 0.1
done
kill -0 "$child_pid" 2>/dev/null && fail "inherited child did not exit"
child_pid=""

run_ops_shell -c '
    set -euo pipefail
    root="$1"
    source "$root/lib/log.sh"
    source "$root/lib/common.sh"
    init_common_lib inherited-post
    source "$root/lib/operations.sh"
    operation_acquire --id post-inherited --label "Post inherited"
    operation_release 0
' _ "$ROOT"

owner_ready="$tmpdir/owner.ready"
owner_fifo="$tmpdir/owner.fifo"
mkfifo "$owner_fifo"
run_ops_shell -c '
    set -euo pipefail
    root="$1"; ready="$2"; fifo="$3"
    source "$root/lib/log.sh"
    source "$root/lib/common.sh"
    init_common_lib global-owner
    source "$root/lib/operations.sh"
    operation_acquire --id restore --label "Restore A"
    : > "$ready"
    exec 9<> "$fifo"
    while :; do read -r -t 1 _ <&9 || true; done
' _ "$ROOT" "$owner_ready" "$owner_fifo" &
holder_pid=$!
for _ in {1..100}; do [[ -f "$owner_ready" ]] && break; sleep 0.1; done
[[ -f "$owner_ready" ]] || fail "global owner did not start"

specific="$tmpdir/non-global.lock"
nonglobal_ready="$tmpdir/non-global.ready"
nonglobal_fifo="$tmpdir/non-global.fifo"
mkfifo "$nonglobal_fifo"
run_ops_shell -c '
    set -euo pipefail
    root="$1"; specific="$2"; ready="$3"; fifo="$4"
    source "$root/lib/log.sh"
    source "$root/lib/common.sh"
    init_common_lib nonglobal
    source "$root/lib/operations.sh"
    operation_acquire --id health-check --label "Non-global B" --no-global --specific-lock "$specific"
    : > "$ready"
    exec 9<> "$fifo"
    while :; do read -r -t 1 _ <&9 || true; done
' _ "$ROOT" "$specific" "$nonglobal_ready" "$nonglobal_fifo" &
nonglobal_pid=$!
for _ in {1..100}; do [[ -f "$nonglobal_ready" ]] && break; sleep 0.1; done
[[ -f "$nonglobal_ready" ]] || fail "non-global operation did not start"

set +e
owner_output="$(
    run_ops_shell -c '
        set -euo pipefail
        root="$1"
        source "$root/lib/log.sh"
        source "$root/lib/common.sh"
        init_common_lib owner-contender
        source "$root/lib/operations.sh"
        operation_acquire --id contender --label "Contender" --non-interactive skip
    ' _ "$ROOT" </dev/null 2>&1
)"
rc=$?
set -e
[[ "$rc" -eq 75 ]] || fail "global contender should skip with active owner, got $rc"
[[ "$owner_output" == *"Restore A"* ]] || fail "global contender did not attribute verified global owner"
[[ "$owner_output" != *"Non-global B"* ]] || fail "global contender incorrectly attributed non-global operation"

kill "$holder_pid" "$nonglobal_pid" 2>/dev/null || true
wait "$holder_pid" "$nonglobal_pid" 2>/dev/null || true
holder_pid=""
nonglobal_pid=""

same_state_dir="$tmpdir/same-state"
same_lock="$tmpdir/same-specific.lock"
same_ready="$tmpdir/same.ready"
same_fifo="$tmpdir/same.fifo"
mkfifo "$same_fifo"
VW_OPERATIONS_STATE_DIR="$same_state_dir" \
VW_OPERATIONS_LOCK="$tmpdir/same-global.lock" \
SPECIFIC_LOCK="$same_lock" \
READY="$same_ready" \
FIFO="$same_fifo" \
"$BASH" -c '
    set -euo pipefail
    root="$1"
    source "$root/lib/log.sh"
    source "$root/lib/common.sh"
    init_common_lib same-a
    source "$root/lib/operations.sh"
    operation_acquire --id same-id --label "Same ID A" --no-global --specific-lock "$SPECIFIC_LOCK"
    operation_set_phase "hold" "Holding same ID"
    : > "$READY"
    exec 9<> "$FIFO"
    while :; do read -r -t 1 _ <&9 || true; done
' _ "$ROOT" &
holder_pid=$!
for _ in {1..100}; do [[ -f "$same_ready" ]] && break; sleep 0.1; done
[[ -f "$same_ready" ]] || fail "same-ID holder did not start"
same_state="$same_state_dir/same-id.state"
before="$(cat "$same_state")"

set +e
VW_OPERATIONS_STATE_DIR="$same_state_dir" \
VW_OPERATIONS_LOCK="$tmpdir/same-global.lock" \
SPECIFIC_LOCK="$same_lock" \
"$BASH" -c '
    set -euo pipefail
    root="$1"
    source "$root/lib/log.sh"
    source "$root/lib/common.sh"
    init_common_lib same-b
    source "$root/lib/operations.sh"
    operation_acquire --id same-id --label "Same ID B" --no-global --specific-lock "$SPECIFIC_LOCK"
' _ "$ROOT" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "same-ID contender unexpectedly acquired duplicate specific lock"
after="$(cat "$same_state")"
[[ "$before" == "$after" ]] || fail "same-ID losing contender overwrote active owner state"

kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
holder_pid=""

pass "post-PR224 operation contracts"
