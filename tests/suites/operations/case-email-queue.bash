#!/usr/bin/env bash
# Focused behavior and command-shape coverage for safe Postfix queue operations.

set -euo pipefail
# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
signal_pid=""
lock_pid=""
fd_session_pid=""
fd_parent_pid=""
fd_child_pid=""

stop_test_process_group() {
    local pid="${1:-}" _
    [[ -n "$pid" ]] || return 0
    if kill -0 -- "-$pid" 2>/dev/null; then
        kill -TERM -- "-$pid" 2>/dev/null || true
        for _ in $(seq 1 50); do
            kill -0 -- "-$pid" 2>/dev/null || break
            sleep 0.02
        done
        if kill -0 -- "-$pid" 2>/dev/null; then
            kill -KILL -- "-$pid" 2>/dev/null || true
        fi
    fi
    wait "$pid" 2>/dev/null || true
}

cleanup_test_processes() {
    stop_test_process_group "${signal_pid:-}"
    stop_test_process_group "${lock_pid:-}"
    stop_test_process_group "${fd_session_pid:-}"
    for pid in "${fd_parent_pid:-}" "${fd_child_pid:-}"; do
        [[ -n "$pid" ]] || continue
        kill -TERM "$pid" 2>/dev/null || true
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    rm -rf "$TMP"
}
trap cleanup_test_processes EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

FIXTURE="$TMP/project"
BIN="$TMP/bin"
CALLS="$TMP/docker.calls"
INVENTORY="$TMP/inventory.ndjson"
QUEUE_TMP="$TMP/queue-tmp"
LOCK_FILE="$TMP/email-queue.lock"
INVENTORY_CALLS="$TMP/inventory.calls"
mkdir -p "$FIXTURE/utilities" "$FIXTURE/lib" "$BIN" "$QUEUE_TMP"
: >"$INVENTORY_CALLS"
cp "$ROOT/utilities/email-queue.sh" "$FIXTURE/utilities/"
cp "$ROOT/lib/log.sh" "$ROOT/lib/common.sh" "$ROOT/lib/docker.sh" "$FIXTURE/lib/"
chmod +x "$FIXTURE/utilities/email-queue.sh"

write_inventory() {
    cat >"$INVENTORY"
}

cat >"$BIN/docker" <<'EOF_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'argc=%d' "$#"
    printf ' <%s>' "$@"
    printf '\n'
} >>"${VW_TEST_DOCKER_CALLS:?}"

mutate_inventory() {
    local action="$1" id="${2:-}"
    python3 - "$action" "$id" "${VW_TEST_INVENTORY:?}" <<'PY_MUTATE'
import json, os, sys
from pathlib import Path

action, wanted, path = sys.argv[1], sys.argv[2], Path(sys.argv[3])
rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

def write():
    path.write_text("".join(json.dumps(row, separators=(",", ":")) + "\n" for row in rows))

if action == "remove":
    rows[:] = [row for row in rows if row.get("queue_id") != wanted]
elif action == "replace":
    replacement = {
        "queue_id": wanted,
        "queue_name": "deferred",
        "arrival_time": 1800000000,
        "message_size": 999,
        "sender": "replacement@example.test",
        "recipients": [{"address": "replacement-recipient@example.test", "delay_reason": "new message"}],
    }
    rows[:] = [row for row in rows if row.get("queue_id") != wanted]
    rows.append(replacement)
elif action == "replace-same-identity":
    original = next((row for row in rows if row.get("queue_id") == wanted), None)
    if original is not None:
        replacement = {
            "queue_id": wanted,
            "queue_name": "deferred",
            "arrival_time": original.get("arrival_time"),
            "message_size": original.get("message_size"),
            "sender": original.get("sender"),
            "recipients": original.get("recipients"),
            "test_marker": "replacement-with-same-normalized-identity",
        }
        rows[:] = [row for row in rows if row.get("queue_id") != wanted]
        rows.append(replacement)
elif action == "add-new":
    if not any(row.get("queue_id") == "NEW-AFTER-SNAPSHOT" for row in rows):
        rows.append({
            "queue_id": "NEW-AFTER-SNAPSHOT",
            "queue_name": "deferred",
            "arrival_time": 1800000100,
            "message_size": 5,
            "sender": "new@example.test",
            "recipients": [{"address": "new-recipient@example.test"}],
        })
elif action in {"hold", "release"}:
    for row in rows:
        if row.get("queue_id") == wanted:
            row["queue_name"] = "hold" if action == "hold" else "deferred"
elif action == "delete":
    rows[:] = [row for row in rows if row.get("queue_id") != wanted]
else:
    raise SystemExit(f"unknown mutation {action}")
write()
PY_MUTATE
}

read_ids() {
    mapfile -t POSTSUPER_IDS
    {
        printf 'stdin'
        printf ' <%s>' "${POSTSUPER_IDS[@]}"
        printf '\n'
    } >>"${VW_TEST_DOCKER_CALLS:?}"
}

if [[ "${1:-}" == info ]]; then
    exit 0
fi
if [[ "${1:-}" == compose && "${2:-}" == version ]]; then
    printf 'Docker Compose version test\n'
    exit 0
fi
if [[ "${1:-}" == compose && "${2:-}" == ps && "${3:-}" == --services \
    && "${4:-}" == --filter && "${5:-}" == status=running ]]; then
    [[ "${VW_TEST_POSTFIX_RUNNING:-true}" == true ]] && printf 'postfix\n'
    exit 0
fi
if [[ "${1:-}" == compose && "${2:-}" == exec && "${3:-}" == -T ]]; then
    shift 3
    if [[ "${1:-}" == postfix && "${2:-}" == postqueue && "${3:-}" == -p ]]; then
        printf '%s\n' "${VW_TEST_QUEUE_OUTPUT:--- 0 Kbytes in 0 Requests.}"
        exit 0
    fi
    if [[ "${1:-}" == postfix && "${2:-}" == postqueue && "${3:-}" == -j ]]; then
        printf '1\n' >>"${VW_TEST_INVENTORY_CALLS:?}"
        [[ "${VW_TEST_MALFORMED_INVENTORY:-false}" == true ]] \
            && { printf '{not-json}\n'; exit 0; }
        cat "${VW_TEST_INVENTORY:?}"
        exit 0
    fi
    if [[ "${1:-}" == --user && "${2:-}" == root && "${3:-}" == postfix ]]; then
        shift 3
        if [[ "${1:-}" == postconf && "${2:-}" == -h && "${3:-}" == enable_long_queue_ids ]]; then
            [[ "${VW_TEST_POSTCONF_FAIL:-false}" == true ]] && exit 1
            printf '%s\n' "${VW_TEST_LONG_QUEUE_IDS:-yes}"
            exit 0
        fi
        if [[ "${1:-}" == postcat ]]; then
            if [[ "$*" == *" -e -h "* ]]; then
                printf '*** ENVELOPE RECORDS ***\n*** MESSAGE CONTENTS ***\nSubject: test\n\n'
            else
                printf '*** ENVELOPE RECORDS ***\nSubject: test\n\nSECRET-BODY\n'
            fi
            exit 0
        fi
        if [[ "${1:-}" == postqueue && "${2:-}" == -i ]]; then
            [[ "${VW_TEST_FAIL_RETRY_ID:-}" == "${3:-}" ]] && exit 1
            printf 'scheduled %s\n' "${3:-}"
            exit 0
        fi
        if [[ "${1:-}" == postqueue && "${2:-}" == -f ]]; then
            if [[ -n "${VW_TEST_BLOCK_DOCKER_MARKER:-}" ]]; then
                printf '%s
' "$$" >"$VW_TEST_BLOCK_DOCKER_MARKER"
                printf '%s
' "$PPID" >"${VW_TEST_BLOCK_DOCKER_MARKER}.parent"
                while [[ ! -e "${VW_TEST_BLOCK_DOCKER_RELEASE:-/nonexistent}" ]]; do
                    sleep 0.05
                done
            fi
            printf 'flushed
'
            exit 0
        fi
        if [[ "${1:-}" == postsuper && "${2:-}" == -d && "${3:-}" != - ]]; then
            id="${3:-}"
            [[ "${VW_TEST_FAIL_DELETE_ID:-}" == "$id" ]] && exit 1
            if [[ "${VW_TEST_ALREADY_ABSENT_DELETE_ID:-}" == "$id" ]]; then
                mutate_inventory remove "$id"
                exit 1
            fi
            mutate_inventory delete "$id"
            printf 'deleted %s\n' "$id"
            exit 0
        fi
        if [[ "${1:-}" == postsuper && "${3:-}" == - ]]; then
            op="${2:-}"
            read_ids
            rc=0
            if [[ "$op" == -h && ! -e "${VW_TEST_INVENTORY}.hold-event" ]]; then
                [[ -n "${VW_TEST_REUSE_ID_ON_HOLD:-}" ]] \
                    && mutate_inventory replace "$VW_TEST_REUSE_ID_ON_HOLD"
                [[ -n "${VW_TEST_REUSE_SAME_ID_ON_HOLD:-}" ]] \
                    && mutate_inventory replace-same-identity "$VW_TEST_REUSE_SAME_ID_ON_HOLD"
                [[ -n "${VW_TEST_REMOVE_ID_ON_HOLD:-}" ]] \
                    && mutate_inventory remove "$VW_TEST_REMOVE_ID_ON_HOLD"
                [[ "${VW_TEST_ADD_NEW_ON_HOLD:-false}" == true ]] \
                    && mutate_inventory add-new
                : >"${VW_TEST_INVENTORY}.hold-event"
            fi
            fail_id=""
            case "$op" in
                -h) fail_id="${VW_TEST_FAIL_HOLD_ID:-}" ;;
                -H) fail_id="${VW_TEST_FAIL_RELEASE_ID:-}" ;;
                -d) fail_id="${VW_TEST_FAIL_DELETE_IDS:-${VW_TEST_FAIL_DELETE_ID:-}}" ;;
                *) exit 97 ;;
            esac
            set +e
            python3 - "$op" "$fail_id" "${VW_TEST_REUSE_ID_AFTER_DELETE:-}" \
                "${VW_TEST_REUSE_ID_AFTER_DELETE_QUEUE_NAME:-deferred}" \
                "${VW_TEST_INVENTORY:?}" "${POSTSUPER_IDS[@]}" <<'PY_BATCH'
import json, sys
from pathlib import Path
op, fail_id, reuse_after_delete, reuse_queue_name = sys.argv[1:5]
path = Path(sys.argv[5])
ids = [item for item in sys.argv[6:] if item]
fail_ids = {item for item in fail_id.split(",") if item}
rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
for queue_id in ids:
    if queue_id in fail_ids:
        continue
    if op == "-d":
        rows[:] = [row for row in rows if row.get("queue_id") != queue_id]
        if queue_id == reuse_after_delete:
            rows.append({
                "queue_id": queue_id,
                "queue_name": reuse_queue_name,
                "arrival_time": 1800000000,
                "message_size": 999,
                "sender": "replacement@example.test",
                "recipients": [{"address": "replacement-recipient@example.test", "delay_reason": "new message"}],
                "test_marker": "replacement-after-delete",
            })
    else:
        for row in rows:
            if row.get("queue_id") == queue_id:
                row["queue_name"] = "hold" if op == "-h" else "deferred"
path.write_text("".join(json.dumps(row, separators=(",", ":")) + "\n" for row in rows))
raise SystemExit(1 if fail_ids.intersection(ids) else 0)
PY_BATCH
            batch_rc=$?
            set -e
            if [[ "$op" == -h && -n "${VW_TEST_BLOCK_AFTER_HOLD_MARKER:-}" ]]; then
                : >"$VW_TEST_BLOCK_AFTER_HOLD_MARKER"
                while [[ ! -e "${VW_TEST_BLOCK_AFTER_HOLD_RELEASE:-/nonexistent}" ]]; do
                    sleep 0.05
                done
            fi
            exit "$batch_rc"
        fi
    fi
fi
if [[ "${1:-}" == compose && "${2:-}" == logs && "${3:-}" == --no-color \
    && "${4:-}" == --tail && "${6:-}" == postfix ]]; then
    printf '%s\n' "${VW_TEST_LOG_OUTPUT:-Jul 28 postfix ABC[123]: queued}"
    exit 0
fi
printf 'unexpected docker invocation:' >&2
printf ' <%s>' "$@" >&2
printf '\n' >&2
exit 97
EOF_DOCKER
chmod +x "$BIN/docker"

run_queue() {
    env \
        "PATH=$BIN:$PATH" \
        "VW_TEST_DOCKER_CALLS=$CALLS" \
        "VW_TEST_INVENTORY=$INVENTORY" \
        "VW_TEST_POSTFIX_RUNNING=${VW_TEST_POSTFIX_RUNNING:-true}" \
        "VW_TEST_MALFORMED_INVENTORY=${VW_TEST_MALFORMED_INVENTORY:-false}" \
        "VW_TEST_FAIL_DELETE_ID=${VW_TEST_FAIL_DELETE_ID:-}" \
        "VW_TEST_FAIL_DELETE_IDS=${VW_TEST_FAIL_DELETE_IDS:-}" \
        "VW_TEST_ALREADY_ABSENT_DELETE_ID=${VW_TEST_ALREADY_ABSENT_DELETE_ID:-}" \
        "VW_TEST_FAIL_RETRY_ID=${VW_TEST_FAIL_RETRY_ID:-}" \
        "VW_TEST_REUSE_ID_ON_HOLD=${VW_TEST_REUSE_ID_ON_HOLD:-}" \
        "VW_TEST_REUSE_SAME_ID_ON_HOLD=${VW_TEST_REUSE_SAME_ID_ON_HOLD:-}" \
        "VW_TEST_REUSE_ID_AFTER_DELETE=${VW_TEST_REUSE_ID_AFTER_DELETE:-}" \
        "VW_TEST_REUSE_ID_AFTER_DELETE_QUEUE_NAME=${VW_TEST_REUSE_ID_AFTER_DELETE_QUEUE_NAME:-deferred}" \
        "VW_TEST_REMOVE_ID_ON_HOLD=${VW_TEST_REMOVE_ID_ON_HOLD:-}" \
        "VW_TEST_ADD_NEW_ON_HOLD=${VW_TEST_ADD_NEW_ON_HOLD:-false}" \
        "VW_TEST_FAIL_HOLD_ID=${VW_TEST_FAIL_HOLD_ID:-}" \
        "VW_TEST_FAIL_RELEASE_ID=${VW_TEST_FAIL_RELEASE_ID:-}" \
        "VW_TEST_LONG_QUEUE_IDS=${VW_TEST_LONG_QUEUE_IDS:-yes}" \
        "VW_TEST_POSTCONF_FAIL=${VW_TEST_POSTCONF_FAIL:-false}" \
        "VW_TEST_BLOCK_AFTER_HOLD_MARKER=${VW_TEST_BLOCK_AFTER_HOLD_MARKER:-}" \
        "VW_TEST_BLOCK_AFTER_HOLD_RELEASE=${VW_TEST_BLOCK_AFTER_HOLD_RELEASE:-}" \
        "VW_TEST_BLOCK_DOCKER_MARKER=${VW_TEST_BLOCK_DOCKER_MARKER:-}" \
        "VW_TEST_BLOCK_DOCKER_RELEASE=${VW_TEST_BLOCK_DOCKER_RELEASE:-}" \
        "VW_TEST_LOG_OUTPUT=${VW_TEST_LOG_OUTPUT:-Jul 28 postfix ABC[123]: queued}" \
        "VW_TEST_INVENTORY_CALLS=$INVENTORY_CALLS" \
        "VW_EMAIL_QUEUE_LOCK_FILE=$LOCK_FILE" \
        "TMPDIR=$QUEUE_TMP" \
        "VW_EMAIL_QUEUE_CONFIRM=${VW_EMAIL_QUEUE_CONFIRM:-}" \
        "VW_EMAIL_QUEUE_CLEAR_CONFIRMED=${VW_EMAIL_QUEUE_CLEAR_CONFIRMED:-}" \
        "VW_TEST_MODE=1" \
        "VAULTWARDEN_TEST_ALLOW_NON_ROOT=1" \
        bash "$FIXTURE/utilities/email-queue.sh" "$@"
}

assert_no_destructive_postsuper() {
    if grep -Eq '<postsuper> <-h>|<postsuper> <-H>|<postsuper> <-d>' "$CALLS"; then
        fail "blocked operation invoked hold, release, or deletion"
    fi
}
assert_post_delete_purge_reuse() {
    local replacement_queue="$1" label="$2"
    local out="$TMP/purge-post-delete-${replacement_queue}.out" lock_fd
    rm -f "${INVENTORY}.hold-event"
    write_inventory <<'EOF_PURGE_POST_DELETE_REUSE'
{"queue_id":"PURGE-REUSE","queue_name":"deferred","arrival_time":1700000200,"message_size":321,"sender":"original@example.test","recipients":[{"address":"original-recipient@example.test","delay_reason":"temporary failure"}]}
EOF_PURGE_POST_DELETE_REUSE
    : >"$CALLS"
    : >"$INVENTORY_CALLS"
    VW_EMAIL_QUEUE_CONFIRM=purge-snapshot
    VW_TEST_REUSE_ID_AFTER_DELETE=PURGE-REUSE
    VW_TEST_REUSE_ID_AFTER_DELETE_QUEUE_NAME="$replacement_queue"
    VW_TEST_ADD_NEW_ON_HOLD=true
    export VW_EMAIL_QUEUE_CONFIRM VW_TEST_REUSE_ID_AFTER_DELETE \
        VW_TEST_REUSE_ID_AFTER_DELETE_QUEUE_NAME VW_TEST_ADD_NEW_ON_HOLD
    if run_queue purge --snapshot </dev/null >"$out" 2>&1; then
        fail "$label returned success"
    fi
    python3 - "$INVENTORY" "$replacement_queue" <<'PY_PURGE_POST_DELETE_REUSE' \
        || fail "$label did not preserve the replacement and unrelated message exactly"
import json, sys
from pathlib import Path
path, replacement_queue = Path(sys.argv[1]), sys.argv[2]
rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
by_id = {row["queue_id"]: row for row in rows}
assert set(by_id) == {"PURGE-REUSE", "NEW-AFTER-SNAPSHOT"}
assert by_id["PURGE-REUSE"] == {
    "queue_id": "PURGE-REUSE",
    "queue_name": replacement_queue,
    "arrival_time": 1800000000,
    "message_size": 999,
    "sender": "replacement@example.test",
    "recipients": [{"address": "replacement-recipient@example.test", "delay_reason": "new message"}],
    "test_marker": "replacement-after-delete",
}
assert by_id["NEW-AFTER-SNAPSHOT"] == {
    "queue_id": "NEW-AFTER-SNAPSHOT",
    "queue_name": "deferred",
    "arrival_time": 1800000100,
    "message_size": 5,
    "sender": "new@example.test",
    "recipients": [{"address": "new-recipient@example.test"}],
}
PY_PURGE_POST_DELETE_REUSE
    grep -Fq 'Deleted snapshot messages: 0' "$out" \
        || fail "$label counted the replacement as an ordinary deletion"
    grep -Fq 'Identity mismatches or reused IDs skipped: 1' "$out" \
        || fail "$label did not include the post-delete replacement in the mismatch total"
    grep -Eqi 'post-delete.*queue-ID reuse|post-delete.*identity mismatch' "$out" \
        || fail "$label did not explain the post-delete identity replacement"
    [[ "$(grep -Fc '<postsuper> <-h> <->' "$CALLS" || true)" -eq 1 ]] \
        || fail "$label did not perform exactly one intended hold batch"
    [[ "$(grep -Fc '<postsuper> <-d> <->' "$CALLS" || true)" -eq 1 ]] \
        || fail "$label did not perform exactly one intended delete batch"
    ! grep -Fq '<postsuper> <-H> <->' "$CALLS" \
        || fail "$label released the post-delete replacement"
    ! grep -Fq '<postqueue> <-i>' "$CALLS" \
        || fail "$label retried the post-delete replacement"
    ! grep -Fq '<postqueue> <-f>' "$CALLS" \
        || fail "$label flushed the queue"
    if find "$QUEUE_TMP" -mindepth 1 -print -quit | grep -q .; then
        fail "$label left private temporary files behind"
    fi
    exec {lock_fd}>"$LOCK_FILE"
    flock -n "$lock_fd" || fail "$label left the mutation lock held"
    exec {lock_fd}>&-
    rm -f "${INVENTORY}.hold-event"
    unset VW_TEST_REUSE_ID_AFTER_DELETE VW_TEST_REUSE_ID_AFTER_DELETE_QUEUE_NAME \
        VW_TEST_ADD_NEW_ON_HOLD
    VW_EMAIL_QUEUE_CONFIRM=
    export VW_EMAIL_QUEUE_CONFIRM
    pass "$label"
}

base_inventory() {
    write_inventory <<'EOF_INV'
{"queue_id":"AbC-123","queue_name":"deferred","arrival_time":1700000000,"message_size":100,"sender":"sender@example.test","recipients":[{"address":"one@example.test","delay_reason":"connection timed out"}]}
{"queue_id":"XYZ987","queue_name":"active","arrival_time":1700000100,"message_size":250,"sender":"second@example.test","recipients":[{"address":"two@example.test","delay_reason":"connection timed out"},{"address":"three@example.test","delay_reason":"temporary lookup failure"}]}
EOF_INV
}

run_hardening_tests() {
    # Core coverage intentionally leaves failure controls set. Reset the shared
    # mock state so the hardening matrix is deterministic in the same process.
    unset VW_TEST_POSTFIX_RUNNING VW_TEST_MALFORMED_INVENTORY \
        VW_TEST_FAIL_DELETE_ID VW_TEST_FAIL_DELETE_IDS \
        VW_TEST_ALREADY_ABSENT_DELETE_ID VW_TEST_FAIL_RETRY_ID \
        VW_TEST_REUSE_ID_ON_HOLD VW_TEST_REUSE_SAME_ID_ON_HOLD \
        VW_TEST_REUSE_ID_AFTER_DELETE VW_TEST_REUSE_ID_AFTER_DELETE_QUEUE_NAME \
        VW_TEST_REMOVE_ID_ON_HOLD VW_TEST_ADD_NEW_ON_HOLD \
        VW_TEST_FAIL_HOLD_ID VW_TEST_FAIL_RELEASE_ID \
        VW_TEST_LONG_QUEUE_IDS VW_TEST_POSTCONF_FAIL \
        VW_TEST_BLOCK_AFTER_HOLD_MARKER VW_TEST_BLOCK_AFTER_HOLD_RELEASE \
        VW_TEST_BLOCK_DOCKER_MARKER VW_TEST_BLOCK_DOCKER_RELEASE \
        VW_TEST_LOG_OUTPUT VW_EMAIL_QUEUE_CONFIRM VW_EMAIL_QUEUE_CLEAR_CONFIRMED
    rm -f "${INVENTORY}.hold-event"
    : >"$CALLS"
    : >"$INVENTORY_CALLS"
write_inventory <<'EOF_DUPLICATE_IDENTICAL'
{"queue_id":"DUP-1","queue_name":"deferred","arrival_time":1700000000,"message_size":100,"sender":"sender@example.test","recipients":[{"address":"one@example.test","delay_reason":"connection timed out"}]}
{"queue_id":"DUP-1","queue_name":"deferred","arrival_time":1700000000,"message_size":100,"sender":"sender@example.test","recipients":[{"address":"one@example.test","delay_reason":"connection timed out"}]}
EOF_DUPLICATE_IDENTICAL
[[ "$(run_queue summary --quiet 2>"$TMP/duplicate-identical.err")" == 1 ]] \
    || fail 'identical duplicate records were double-counted'
[[ ! -s "$TMP/duplicate-identical.err" ]] || fail 'identical duplicates emitted diagnostics'
run_queue summary --json >"$TMP/duplicate-identical.json"
python3 - "$TMP/duplicate-identical.json" <<'PY_DUPLICATE_IDENTICAL' \
    || fail 'identical duplicate summary is incorrect'
import json, sys
obj = json.load(open(sys.argv[1]))
assert obj["count"] == 1
assert obj["total_bytes"] == 100
assert obj["queues"] == {"deferred": 1}
PY_DUPLICATE_IDENTICAL
run_queue summary >"$TMP/duplicate-identical.txt"
grep -Fq 'Total messages: 1' "$TMP/duplicate-identical.txt" \
    || fail 'text summary double-counted identical duplicates'
pass 'identical duplicate inventory records are normalized once'

write_inventory <<'EOF_DUPLICATE_QUEUES'
{"queue_id":"DUP-QUEUE","queue_name":"deferred","arrival_time":1700000000,"message_size":100,"sender":"sender@example.test","recipients":[{"address":"one@example.test"}]}
{"queue_id":"DUP-QUEUE","queue_name":"active","arrival_time":1700000000,"message_size":100,"sender":"sender@example.test","recipients":[{"address":"one@example.test"}]}
EOF_DUPLICATE_QUEUES
run_queue summary --json >"$TMP/duplicate-queues.json"
python3 - "$TMP/duplicate-queues.json" <<'PY_DUPLICATE_QUEUES' \
    || fail 'equivalent queue-name duplicates were not deterministic'
import json, sys
obj = json.load(open(sys.argv[1]))
assert obj["count"] == 1
assert obj["queues"] == {"active": 1}
PY_DUPLICATE_QUEUES
pass 'equivalent duplicates use a deterministic queue name'

write_inventory <<'EOF_DUPLICATE_HOLD'
{"queue_id":"DUP-HOLD","queue_name":"deferred","arrival_time":1700000000,"message_size":100,"sender":"sender@example.test","recipients":[{"address":"one@example.test"}]}
{"queue_id":"DUP-HOLD","queue_name":"hold","arrival_time":1700000000,"message_size":100,"sender":"sender@example.test","recipients":[{"address":"one@example.test"}]}
EOF_DUPLICATE_HOLD
run_queue summary --json >"$TMP/duplicate-hold.json"
python3 - "$TMP/duplicate-hold.json" <<'PY_DUPLICATE_HOLD' \
    || fail 'hold queue preference was not preserved'
import json, sys
obj = json.load(open(sys.argv[1]))
assert obj["count"] == 1
assert obj["queues"] == {"hold": 1}
PY_DUPLICATE_HOLD
pass 'hold wins when equivalent duplicates report different queues'

write_inventory <<'EOF_DUPLICATE_CONFLICT'
{"queue_id":"DUP-CONFLICT","queue_name":"deferred","arrival_time":1700000000,"message_size":100,"sender":"sender@example.test","recipients":[{"address":"one@example.test"}]}
{"queue_id":"DUP-CONFLICT","queue_name":"active","arrival_time":1700000001,"message_size":100,"sender":"sender@example.test","recipients":[{"address":"one@example.test"}]}
EOF_DUPLICATE_CONFLICT
if run_queue summary --quiet >"$TMP/duplicate-conflict.out" 2>&1; then
    fail 'conflicting duplicate identities were accepted'
fi
grep -Fq "queue_id 'DUP-CONFLICT' has conflicting normalized identities" \
    "$TMP/duplicate-conflict.out" || fail 'conflicting duplicate diagnostic is not useful'
! grep -Fq 'MESSAGE CONTENTS' "$TMP/duplicate-conflict.out" \
    || fail 'conflicting duplicate diagnostic exposed message content'
for conflict_command in delete purge; do
    : >"$CALLS"
    VW_TEST_LONG_QUEUE_IDS=yes
    VW_TEST_POSTCONF_FAIL=false
    VW_EMAIL_QUEUE_CONFIRM=delete:DUP-CONFLICT
    [[ "$conflict_command" == purge ]] && VW_EMAIL_QUEUE_CONFIRM=purge-snapshot
    export VW_TEST_LONG_QUEUE_IDS VW_TEST_POSTCONF_FAIL VW_EMAIL_QUEUE_CONFIRM
    set +e
    if [[ "$conflict_command" == delete ]]; then
        run_queue delete DUP-CONFLICT </dev/null >"$TMP/conflict-delete.out" 2>&1
    else
        run_queue purge --snapshot </dev/null >"$TMP/conflict-purge.out" 2>&1
    fi
    conflict_rc=$?
    set -e
    [[ $conflict_rc -ne 0 ]] || fail "$conflict_command accepted conflicting inventory"
    assert_no_destructive_postsuper
done
pass 'conflicting duplicates fail closed before queue mutation'

base_inventory
VW_TEST_LONG_QUEUE_IDS=no
VW_TEST_POSTCONF_FAIL=false
export VW_TEST_LONG_QUEUE_IDS VW_TEST_POSTCONF_FAIL
for blocked_command in delete purge clear; do
    rm -f "${INVENTORY}.hold-event"
    base_inventory
    : >"$CALLS"
    VW_EMAIL_QUEUE_CONFIRM=delete:AbC-123
    VW_EMAIL_QUEUE_CLEAR_CONFIRMED=
    [[ "$blocked_command" == purge ]] && VW_EMAIL_QUEUE_CONFIRM=purge-snapshot
    [[ "$blocked_command" == clear ]] && VW_EMAIL_QUEUE_CLEAR_CONFIRMED=1
    export VW_EMAIL_QUEUE_CONFIRM VW_EMAIL_QUEUE_CLEAR_CONFIRMED
    set +e
    case "$blocked_command" in
        delete) run_queue delete AbC-123 </dev/null >"$TMP/long-no-delete.out" 2>&1 ;;
        purge) run_queue purge --snapshot </dev/null >"$TMP/long-no-purge.out" 2>&1 ;;
        clear) run_queue clear </dev/null >"$TMP/long-no-clear.out" 2>&1 ;;
    esac
    blocked_rc=$?
    set -e
    [[ $blocked_rc -ne 0 ]] || fail "$blocked_command accepted enable_long_queue_ids=no"
    grep -Fq 'POSTFIX_ENABLE_LONG_QUEUE_IDS=yes' "$TMP/long-no-$blocked_command.out" \
        || fail "$blocked_command long-ID error lacks environment remediation"
    grep -Fq 'sudo make up' "$TMP/long-no-$blocked_command.out" \
        || fail "$blocked_command long-ID error lacks recreate workflow"
    assert_no_destructive_postsuper
done
pass 'destructive operations require enable_long_queue_ids=yes'

VW_TEST_LONG_QUEUE_IDS=yes
VW_TEST_POSTCONF_FAIL=true
export VW_TEST_LONG_QUEUE_IDS VW_TEST_POSTCONF_FAIL
for blocked_command in delete purge clear; do
    rm -f "${INVENTORY}.hold-event"
    base_inventory
    : >"$CALLS"
    VW_EMAIL_QUEUE_CONFIRM=delete:AbC-123
    VW_EMAIL_QUEUE_CLEAR_CONFIRMED=
    [[ "$blocked_command" == purge ]] && VW_EMAIL_QUEUE_CONFIRM=purge-snapshot
    [[ "$blocked_command" == clear ]] && VW_EMAIL_QUEUE_CLEAR_CONFIRMED=1
    export VW_EMAIL_QUEUE_CONFIRM VW_EMAIL_QUEUE_CLEAR_CONFIRMED
    set +e
    case "$blocked_command" in
        delete) run_queue delete AbC-123 </dev/null >"$TMP/postconf-fail-delete.out" 2>&1 ;;
        purge) run_queue purge --snapshot </dev/null >"$TMP/postconf-fail-purge.out" 2>&1 ;;
        clear) run_queue clear </dev/null >"$TMP/postconf-fail-clear.out" 2>&1 ;;
    esac
    blocked_rc=$?
    set -e
    [[ $blocked_rc -ne 0 ]] || fail "$blocked_command accepted an unreadable long-ID setting"
    grep -Fq 'could not be read' "$TMP/postconf-fail-$blocked_command.out" \
        || fail "$blocked_command postconf failure is not explicit"
    assert_no_destructive_postsuper
done
pass 'destructive operations fail closed when postconf cannot be read'

write_inventory <<'EOF_SAME_METADATA_REPLACEMENT'
{"queue_id":"AbC-123","queue_name":"deferred","arrival_time":1700000000,"message_size":100,"sender":"sender@example.test","recipients":[{"address":"one@example.test","delay_reason":"connection timed out"}],"test_marker":"replacement-with-same-normalized-identity"}
EOF_SAME_METADATA_REPLACEMENT
: >"$CALLS"
VW_TEST_LONG_QUEUE_IDS=no
VW_TEST_POSTCONF_FAIL=false
VW_EMAIL_QUEUE_CONFIRM=delete:AbC-123
export VW_TEST_LONG_QUEUE_IDS VW_TEST_POSTCONF_FAIL VW_EMAIL_QUEUE_CONFIRM
if run_queue delete AbC-123 </dev/null >"$TMP/same-metadata-short-id.out" 2>&1; then
    fail 'same-metadata replacement was deletable without long queue IDs'
fi
grep -Fq 'replacement-with-same-normalized-identity' "$INVENTORY" \
    || fail 'same-metadata replacement was changed on blocked deletion'
assert_no_destructive_postsuper
pass 'same-metadata replacement cannot reach deletion without long queue IDs'

base_inventory
: >"$CALLS"
VW_TEST_LONG_QUEUE_IDS=no
VW_TEST_POSTCONF_FAIL=false
VW_EMAIL_QUEUE_CONFIRM=
export VW_TEST_LONG_QUEUE_IDS VW_TEST_POSTCONF_FAIL VW_EMAIL_QUEUE_CONFIRM
run_queue status >"$TMP/read-only-status.out"
run_queue summary --quiet >"$TMP/read-only-summary.out"
run_queue inspect AbC-123 >"$TMP/read-only-inspect.out"
run_queue logs AbC-123 --tail 10 >"$TMP/read-only-logs.out"
! grep -Fq '<postconf>' "$CALLS" || fail 'read-only commands queried the destructive long-ID prerequisite'
VW_TEST_LONG_QUEUE_IDS=yes
VW_TEST_POSTCONF_FAIL=true
export VW_TEST_LONG_QUEUE_IDS VW_TEST_POSTCONF_FAIL
run_queue summary --quiet >"$TMP/read-only-postconf-fail.out"
! grep -Fq '<postconf>' "$CALLS" || fail 'read-only commands queried an unavailable postconf path'
pass 'read-only commands remain available without long-ID verification'

base_inventory
: >"$CALLS"
VW_TEST_LONG_QUEUE_IDS=no
VW_TEST_POSTCONF_FAIL=false
export VW_TEST_LONG_QUEUE_IDS VW_TEST_POSTCONF_FAIL
run_queue retry AbC-123 >"$TMP/retry-short-id.out" 2>"$TMP/retry-short-id.err"
grep -Fq 'destructive queue operations remain blocked' "$TMP/retry-short-id.err" \
    || fail 'targeted retry did not warn when long IDs were disabled'
grep -Fq '<postqueue> <-i> <AbC-123>' "$CALLS" \
    || fail 'targeted retry was incorrectly blocked by the long-ID warning'
VW_EMAIL_QUEUE_CONFIRM=retry-all
export VW_EMAIL_QUEUE_CONFIRM
run_queue retry --all </dev/null >"$TMP/retry-all-short-id.out" 2>"$TMP/retry-all-short-id.err"
grep -Fq 'destructive queue operations remain blocked' "$TMP/retry-all-short-id.err" \
    || fail 'retry-all did not warn when long IDs were disabled'
grep -Fq '<postqueue> <-f>' "$CALLS" \
    || fail 'retry-all was incorrectly blocked by the long-ID warning'
VW_TEST_LONG_QUEUE_IDS=yes
VW_TEST_POSTCONF_FAIL=true
VW_EMAIL_QUEUE_CONFIRM=
export VW_TEST_LONG_QUEUE_IDS VW_TEST_POSTCONF_FAIL VW_EMAIL_QUEUE_CONFIRM
run_queue retry AbC-123 >"$TMP/retry-postconf-fail.out" 2>"$TMP/retry-postconf-fail.err"
grep -Fq 'Could not verify Postfix enable_long_queue_ids' "$TMP/retry-postconf-fail.err" \
    || fail 'targeted retry did not warn when postconf was unreadable'
pass 'retry operations remain available with clear long-ID warnings'
}

script="$ROOT/utilities/email-queue.sh"
grep -Fq 'require_root "${original_args[@]}"' "$script" || fail 'root requirement missing'
grep -Fq 'VW_TEST_MODE:-0' "$script" || fail 'test gate missing'
grep -Fq 'VAULTWARDEN_TEST_ALLOW_NON_ROOT:-0' "$script" || fail 'non-root test gate missing'
! grep -Fq 'postsuper -d ALL' "$script" || fail 'unsafe live ALL deletion remains'
! grep -Eq 'postsuper[[:space:]]+"\$@"|eval[[:space:]]' "$script" || fail 'generic command forwarding or eval found'
grep -Fq 'postsuper -h -' "$script" || fail 'snapshot purge does not batch exact hold IDs through stdin'
grep -Fq 'postsuper -d -' "$script" || fail 'snapshot purge does not batch exact delete IDs through stdin'
grep -Fq 'flock -n' "$script" || fail 'mutating queue lock is missing'
grep -Fq '_HOLD_ROLLBACK_ACTIVE' "$script" || fail 'generic hold rollback state is missing'
! grep -Fq '_PURGE_ROLLBACK_' "$script" || fail 'purge-specific rollback state remains'
grep -Fq "trap '_signal_exit 129' HUP" "$script" || fail 'explicit SIGHUP exit handling is missing'
grep -Fq 'postconf -h enable_long_queue_ids' "$script"     || fail 'runtime long queue-ID verification is missing'
grep -Fq 'umask 077' "$script" || fail 'private temporary-file umask is missing'
grep -Fq 'POSTFIX_enable_long_queue_ids=${POSTFIX_ENABLE_LONG_QUEUE_IDS:-yes}'     "$ROOT/docker-compose.yml.example"     || fail 'Compose does not enable long queue IDs by default'
grep -Fq 'POSTFIX_ENABLE_LONG_QUEUE_IDS=yes' "$ROOT/.env.example"     || fail 'long queue-ID operator setting is not documented in .env.example'
grep -Fq '_require_long_queue_ids "targeted deletion"' "$script" \
    || fail 'targeted deletion does not require verified long queue IDs'
grep -Fq '_require_long_queue_ids "snapshot purge"' "$script" \
    || fail 'snapshot purge does not require verified long queue IDs'
pass 'static queue safety and mandatory long-ID contract'

if (( EUID != 0 )); then
    if env PATH="$BIN:$PATH" VW_TEST_DOCKER_CALLS="$CALLS" \
        bash "$FIXTURE/utilities/email-queue.sh" status >"$TMP/nonroot.out" 2>&1; then
        fail 'ordinary non-root execution was accepted'
    fi
    grep -Fq 'Re-run with: sudo' "$TMP/nonroot.out" || fail 'root rejection lacks sudo remediation'
fi
pass 'root requirement and narrow bypass'

base_inventory
for args in 'unknown' 'status extra' 'summary --bad' 'inspect' 'inspect --body' 'retry' 'delete' 'purge' 'purge --snapshot extra' 'logs --tail 0' 'logs --tail 5001'; do
    set +e
    # shellcheck disable=SC2086
    run_queue $args >"$TMP/bad.out" 2>&1
    rc=$?
    set -e
    [[ $rc -ne 0 ]] || fail "invalid usage succeeded: $args"
    [[ $rc -eq 2 ]] || fail "invalid usage returned $rc instead of 2: $args"
done
pass 'unknown commands, options, and operands return 2'

: >"$CALLS"
run_queue status >"$TMP/status.out"
grep -Fq '<postfix> <postqueue> <-p>' "$CALLS" || fail 'status did not call postqueue -p'
! grep -Fq '<postsuper>' "$CALLS" || fail 'status mutated the queue'
pass 'status is read-only'

base_inventory
[[ "$(run_queue summary --quiet 2>"$TMP/quiet.err")" == 2 ]] || fail 'quiet summary count is wrong'
[[ ! -s "$TMP/quiet.err" ]] || fail 'quiet summary wrote diagnostics'
run_queue summary --json >"$TMP/summary.json"
python3 - "$TMP/summary.json" <<'PY_ASSERT_JSON' || fail 'summary JSON is invalid or incomplete'
import json, sys
obj = json.load(open(sys.argv[1]))
assert obj["count"] == 2
assert obj["total_bytes"] == 350
assert obj["queues"] == {"active": 1, "deferred": 1}
assert obj["top_delay_reason"] == "connection timed out"
assert isinstance(obj["oldest_age_seconds"], int)
PY_ASSERT_JSON
run_queue summary >"$TMP/summary.txt"
grep -Fq 'Total messages: 2' "$TMP/summary.txt" || fail 'text summary count missing'
grep -Fq 'Total size:' "$TMP/summary.txt" || fail 'text summary size missing'
pass 'summary text, quiet, and deterministic JSON'


VW_TEST_MALFORMED_INVENTORY=true
export VW_TEST_MALFORMED_INVENTORY
if run_queue summary --quiet >"$TMP/malformed.out" 2>&1; then
    fail 'malformed inventory was accepted'
fi
unset VW_TEST_MALFORMED_INVENTORY
pass 'malformed inventory fails safely'

base_inventory
if run_queue inspect abc-123 >"$TMP/case.out" 2>&1; then
    fail 'queue ID validation was not case-sensitive'
fi
run_queue inspect AbC-123 >"$TMP/inspect.out"
! grep -Fq 'SECRET-BODY' "$TMP/inspect.out" || fail 'inspect exposed body by default'
run_queue inspect AbC-123 --body >"$TMP/inspect-body.out" 2>"$TMP/inspect-body.err"
grep -Fq 'SECRET-BODY' "$TMP/inspect-body.out" || fail 'inspect --body did not include body'
grep -Fqi 'sensitive' "$TMP/inspect-body.err" || fail 'inspect --body warning missing'
grep -Fq '<--user> <root> <postfix> <postcat>' "$CALLS" || fail 'postcat was not root-operated inside the container'
pass 'exact validation and body opt-in'


VW_TEST_LONG_QUEUE_IDS=yes
VW_TEST_POSTCONF_FAIL=false
export VW_TEST_LONG_QUEUE_IDS VW_TEST_POSTCONF_FAIL
base_inventory
: >"$CALLS"
run_queue retry AbC-123 >"$TMP/retry.out"
grep -Fq '<postqueue> <-i> <AbC-123>' "$CALLS" || fail 'single retry did not pass ID as one argument'
! grep -Fq '<postqueue> <-f>' "$CALLS" || fail 'single retry flushed all messages'
pass 'single-message retry isolation'

base_inventory
VW_EMAIL_QUEUE_CONFIRM=wrong
export VW_EMAIL_QUEUE_CONFIRM
if run_queue retry --all </dev/null >"$TMP/retry-all-wrong.out" 2>&1; then
    fail 'retry-all accepted wrong marker'
fi
VW_EMAIL_QUEUE_CONFIRM=retry-all
export VW_EMAIL_QUEUE_CONFIRM
run_queue retry --all </dev/null >"$TMP/retry-all.out"
grep -Fq '<postqueue> <-f>' "$CALLS" || fail 'retry-all did not flush exactly once'
pass 'retry-all exact confirmation'
fd_marker="$TMP/long-lived-docker.pid"
fd_release="$TMP/long-lived-docker.release"
fd_queue_tmp="$TMP/fd-inheritance-queue-tmp"
rm -f "$fd_marker" "${fd_marker}.parent" "$fd_release"
rm -rf "$fd_queue_tmp"
mkdir -p "$fd_queue_tmp"
base_inventory
: >"$CALLS"
(
    exec setsid env \
        "PATH=$BIN:$PATH" \
        "VW_TEST_DOCKER_CALLS=$CALLS" \
        "VW_TEST_INVENTORY=$INVENTORY" \
        "VW_TEST_POSTFIX_RUNNING=true" \
        "VW_TEST_MALFORMED_INVENTORY=false" \
        "VW_TEST_FAIL_DELETE_ID=" \
        "VW_TEST_FAIL_DELETE_IDS=" \
        "VW_TEST_ALREADY_ABSENT_DELETE_ID=" \
        "VW_TEST_FAIL_RETRY_ID=" \
        "VW_TEST_REUSE_ID_ON_HOLD=" \
        "VW_TEST_REUSE_SAME_ID_ON_HOLD=" \
        "VW_TEST_REUSE_ID_AFTER_DELETE=" \
        "VW_TEST_REMOVE_ID_ON_HOLD=" \
        "VW_TEST_ADD_NEW_ON_HOLD=false" \
        "VW_TEST_FAIL_HOLD_ID=" \
        "VW_TEST_FAIL_RELEASE_ID=" \
        "VW_TEST_LONG_QUEUE_IDS=yes" \
        "VW_TEST_POSTCONF_FAIL=false" \
        "VW_TEST_BLOCK_AFTER_HOLD_MARKER=" \
        "VW_TEST_BLOCK_AFTER_HOLD_RELEASE=" \
        "VW_TEST_BLOCK_DOCKER_MARKER=$fd_marker" \
        "VW_TEST_BLOCK_DOCKER_RELEASE=$fd_release" \
        "VW_TEST_LOG_OUTPUT=Jul 28 postfix test" \
        "VW_TEST_INVENTORY_CALLS=$INVENTORY_CALLS" \
        "VW_EMAIL_QUEUE_LOCK_FILE=$LOCK_FILE" \
        "TMPDIR=$fd_queue_tmp" \
        "VW_EMAIL_QUEUE_CONFIRM=retry-all" \
        "VW_EMAIL_QUEUE_CLEAR_CONFIRMED=" \
        "VW_TEST_MODE=1" \
        "VAULTWARDEN_TEST_ALLOW_NON_ROOT=1" \
        bash "$FIXTURE/utilities/email-queue.sh" retry --all
) >"$TMP/fd-inheritance.out" 2>&1 &
fd_session_pid=$!
fd_ready=false
for _ in $(seq 1 300); do
    if [[ -s "$fd_marker" && -s "${fd_marker}.parent" ]]; then
        fd_ready=true
        break
    fi
    kill -0 "$fd_session_pid" 2>/dev/null || break
    sleep 0.01
done
[[ "$fd_ready" == true ]] || fail 'FD regression did not reach the long-lived Docker child'
fd_child_pid=$(<"$fd_marker")
fd_parent_pid=$(<"${fd_marker}.parent")
[[ "$fd_child_pid" =~ ^[0-9]+$ && "$fd_parent_pid" =~ ^[0-9]+$ ]] \
    || fail 'FD regression recorded invalid process IDs'
kill -0 "$fd_parent_pid" 2>/dev/null || fail 'email-queue parent exited before lock assertion'
kill -0 "$fd_child_pid" 2>/dev/null || fail 'mocked Docker child exited before lock assertion'
exec {lock_probe_fd}>"$LOCK_FILE"
if flock -n "$lock_probe_fd"; then
    flock -u "$lock_probe_fd" || true
    exec {lock_probe_fd}>&-
    fail 'email-queue parent did not retain the mutation lock while alive'
fi
exec {lock_probe_fd}>&-
kill -KILL "$fd_parent_pid"
if [[ "$fd_parent_pid" == "$fd_session_pid" ]]; then
    wait "$fd_session_pid" 2>/dev/null || true
    fd_session_pid=""
else
    for _ in $(seq 1 200); do
        kill -0 "$fd_parent_pid" 2>/dev/null || break
        sleep 0.01
    done
fi
kill -0 "$fd_parent_pid" 2>/dev/null && fail 'email-queue parent did not terminate independently'
kill -0 "$fd_child_pid" 2>/dev/null || fail 'mocked Docker child did not survive parent termination'
exec {lock_probe_fd}>"$LOCK_FILE"
flock -n "$lock_probe_fd" \
    || fail 'mocked Docker child inherited and retained the mutation lock descriptor'
flock -u "$lock_probe_fd"
exec {lock_probe_fd}>&-
: >"$fd_release"
for _ in $(seq 1 200); do
    kill -0 "$fd_child_pid" 2>/dev/null || break
    sleep 0.01
done
if kill -0 "$fd_child_pid" 2>/dev/null; then
    kill -TERM "$fd_child_pid" 2>/dev/null || true
    fail 'mocked Docker child did not exit after release'
fi
if [[ -n "$fd_session_pid" ]]; then
    wait "$fd_session_pid" 2>/dev/null || true
fi
rm -rf "$fd_queue_tmp"
[[ ! -e "$fd_queue_tmp" ]] \
    || fail 'FD regression did not clean its forced-crash temporary root'
fd_session_pid=""
fd_parent_pid=""
fd_child_pid=""
pass 'Docker children do not inherit the parent mutation lock descriptor'

base_inventory
VW_EMAIL_QUEUE_CONFIRM=delete:WRONG
export VW_EMAIL_QUEUE_CONFIRM
if run_queue delete AbC-123 </dev/null >"$TMP/delete-wrong.out" 2>&1; then
    fail 'delete accepted marker for another ID'
fi
VW_EMAIL_QUEUE_CONFIRM=delete:AbC-123
export VW_EMAIL_QUEUE_CONFIRM
: >"$CALLS"
rm -f "${INVENTORY}.hold-event"
run_queue delete AbC-123 </dev/null >"$TMP/delete.out"
! grep -Fq '"queue_id":"AbC-123"' "$INVENTORY" || fail 'delete did not remove selected identity'
grep -Fq '"queue_id":"XYZ987"' "$INVENTORY" || fail 'delete removed an unrelated message'
grep -Fq '<postsuper> <-h> <->' "$CALLS" || fail 'targeted delete did not hold through exact stdin mode'
grep -Fq '<postsuper> <-d> <->' "$CALLS" || fail 'targeted delete did not delete through exact stdin mode'
grep -Fq 'stdin <AbC-123>' "$CALLS" || fail 'targeted delete did not pass the exact case-sensitive ID record'
! grep -Fq 'stdin <abc-123>' "$CALLS" || fail 'targeted delete changed queue-ID case'
grep -Fq '<postconf> <-h> <enable_long_queue_ids>' "$CALLS" \
    || fail 'targeted delete did not verify effective long queue IDs'
pass 'targeted deletion holds, identity-verifies, and deletes only the selected message'
rm -f "${INVENTORY}.hold-event"
base_inventory
: >"$CALLS"
VW_TEST_REUSE_ID_AFTER_DELETE=AbC-123
export VW_TEST_REUSE_ID_AFTER_DELETE
if run_queue delete AbC-123 </dev/null >"$TMP/delete-post-reuse.out" 2>&1; then
    fail 'post-delete queue-ID reuse was reported as success'
fi
grep -Fq '"queue_id":"AbC-123"' "$INVENTORY" \
    || fail 'post-delete replacement did not remain queued'
grep -Fq '"queue_name":"deferred"' "$INVENTORY" \
    || fail 'post-delete replacement was held or released incorrectly'
grep -Fq 'replacement@example.test' "$INVENTORY" \
    || fail 'post-delete replacement identity was not preserved'
[[ "$(grep -Fc '<postsuper> <-h> <->' "$CALLS" || true)" -eq 1 ]] \
    || fail 'post-delete reuse path performed an unexpected hold operation'
[[ "$(grep -Fc '<postsuper> <-d> <->' "$CALLS" || true)" -eq 1 ]] \
    || fail 'post-delete reuse path performed an unexpected delete operation'
! grep -Fq '<postsuper> <-H> <->' "$CALLS" \
    || fail 'post-delete reuse path released the replacement'
! grep -Fq '<postqueue> <-i>' "$CALLS" \
    || fail 'post-delete reuse path retried the replacement'
! grep -Fq '<postqueue> <-f>' "$CALLS" \
    || fail 'post-delete reuse path flushed the queue'
grep -Eqi 'queue ID.*different message|queue-ID reuse|identity mismatch' "$TMP/delete-post-reuse.out" \
    || fail 'post-delete queue-ID reuse was not explained clearly'
! grep -Fq 'Deleted the identity-verified queue message' "$TMP/delete-post-reuse.out" \
    || fail 'post-delete queue-ID reuse printed the normal success message'
unset VW_TEST_REUSE_ID_AFTER_DELETE
pass 'post-delete queue-ID reuse preserves the replacement and returns failure'

rm -f "${INVENTORY}.hold-event"
base_inventory
VW_TEST_REUSE_ID_ON_HOLD=AbC-123
export VW_TEST_REUSE_ID_ON_HOLD
if run_queue delete AbC-123 </dev/null >"$TMP/delete-reuse.out" 2>&1; then
    fail 'targeted delete accepted a reused queue ID'
fi
grep -Fq '"queue_id":"AbC-123"' "$INVENTORY" || fail 'reused-ID replacement was deleted'
grep -Fq 'replacement@example.test' "$INVENTORY" || fail 'replacement identity was not preserved'
grep -Fq '"queue_name":"deferred"' "$INVENTORY" || fail 'new hold on replacement was not released'
grep -Fqi 'different message' "$TMP/delete-reuse.out" || fail 'identity mismatch was not reported'
unset VW_TEST_REUSE_ID_ON_HOLD
pass 'targeted deletion skips and releases a reused-ID replacement'

rm -f "${INVENTORY}.hold-event"
base_inventory
VW_TEST_REMOVE_ID_ON_HOLD=AbC-123
export VW_TEST_REMOVE_ID_ON_HOLD
run_queue delete AbC-123 </dev/null >"$TMP/delete-absent.out" 2>&1
! grep -Fq '"queue_id":"AbC-123"' "$INVENTORY" || fail 'disappeared original remained unexpectedly'
grep -Fq '"queue_id":"XYZ987"' "$INVENTORY" || fail 'absent-original path deleted an unrelated message'
grep -Fqi 'already absent' "$TMP/delete-absent.out" || fail 'already-absent original was not reported'
unset VW_TEST_REMOVE_ID_ON_HOLD
pass 'targeted deletion reports an original that disappears at the hold boundary'

rm -f "${INVENTORY}.hold-event"
base_inventory
: >"$CALLS"
VW_TEST_FAIL_HOLD_ID=AbC-123
export VW_TEST_FAIL_HOLD_ID
if run_queue delete AbC-123 </dev/null >"$TMP/delete-hold-fail.out" 2>&1; then
    fail 'targeted delete succeeded without holding the matching message'
fi
grep -Fq '"queue_id":"AbC-123","queue_name":"deferred"' "$INVENTORY" \
    || fail 'hold-failure path mutated the matching message'
! grep -Fq '<postsuper> <-d> <->' "$CALLS" || fail 'hold-failure path attempted deletion'
grep -Fqi 'could not place the matching message on hold' "$TMP/delete-hold-fail.out" \
    || fail 'hold failure was not reported'
unset VW_TEST_FAIL_HOLD_ID
pass 'targeted deletion fails closed when hold does not stabilize the match'

rm -f "${INVENTORY}.hold-event"
base_inventory
VW_TEST_FAIL_DELETE_IDS=AbC-123
export VW_TEST_FAIL_DELETE_IDS
if run_queue delete AbC-123 </dev/null >"$TMP/delete-fail-normal.out" 2>&1; then
    fail 'targeted delete returned success after deletion failure'
fi
grep -Fq '"queue_id":"AbC-123","queue_name":"deferred"' "$INVENTORY" \
    || fail 'newly held deletion survivor was not released'
grep -Fqi 'failed to delete' "$TMP/delete-fail-normal.out" || fail 'deletion failure was not reported'
unset VW_TEST_FAIL_DELETE_IDS
pass 'targeted deletion releases a newly held survivor after deletion failure'

rm -f "${INVENTORY}.hold-event"
write_inventory <<'EOF_DELETE_PREHELD'
{"queue_id":"AbC-123","queue_name":"hold","arrival_time":1700000000,"message_size":100,"sender":"sender@example.test","recipients":[{"address":"one@example.test"}]}
{"queue_id":"XYZ987","queue_name":"deferred","arrival_time":1700000100,"message_size":250,"sender":"second@example.test","recipients":[{"address":"two@example.test"}]}
EOF_DELETE_PREHELD
VW_TEST_FAIL_DELETE_IDS=AbC-123
export VW_TEST_FAIL_DELETE_IDS
if run_queue delete AbC-123 </dev/null >"$TMP/delete-fail-preheld.out" 2>&1; then
    fail 'pre-held deletion failure returned success'
fi
grep -Fq '"queue_id":"AbC-123","queue_name":"hold"' "$INVENTORY" \
    || fail 'message held before targeted delete did not remain held'
unset VW_TEST_FAIL_DELETE_IDS
pass 'targeted deletion preserves a pre-existing hold after deletion failure'

assert_post_delete_purge_reuse deferred \
    'snapshot purge preserves a deferred replacement created after deletion'
assert_post_delete_purge_reuse hold \
    'snapshot purge preserves a held replacement created after deletion'
base_inventory
VW_EMAIL_QUEUE_CONFIRM=purge-snapshot
VW_TEST_REUSE_ID_ON_HOLD=AbC-123
export VW_EMAIL_QUEUE_CONFIRM VW_TEST_REUSE_ID_ON_HOLD
if run_queue purge --snapshot </dev/null >"$TMP/purge-reuse.out" 2>&1; then
    fail 'reused queue ID returned success'
fi
grep -Fq '"queue_id":"AbC-123"' "$INVENTORY" || fail 'reused queue ID replacement was deleted'
grep -Fq 'replacement@example.test' "$INVENTORY" || fail 'replacement identity was not preserved'
grep -Fq '"queue_name":"deferred"' "$INVENTORY" || fail 'mismatched replacement was not released'
grep -Fq 'Identity mismatches or reused IDs skipped: 1' "$TMP/purge-reuse.out" \
    || fail 'identity mismatch was not reported'
grep -Fq '<postconf> <-h> <enable_long_queue_ids>' "$CALLS" \
    || fail 'purge did not verify the effective long queue-ID setting'
unset VW_TEST_REUSE_ID_ON_HOLD
pass 'reused queue ID is released, skipped, and returns nonzero'

rm -f "${INVENTORY}.hold-event"
base_inventory
VW_TEST_REMOVE_ID_ON_HOLD=AbC-123
export VW_TEST_REMOVE_ID_ON_HOLD
run_queue purge --snapshot </dev/null >"$TMP/purge-absent.out"
grep -Fq 'Already absent: 1' "$TMP/purge-absent.out" \
    || fail 'disappeared original was not reported absent'
unset VW_TEST_REMOVE_ID_ON_HOLD
pass 'disappeared original is reported already absent'

rm -f "${INVENTORY}.hold-event"
write_inventory <<'EOF_HOLD_FAILURES'
{"queue_id":"HELD-1","queue_name":"hold","arrival_time":1700000000,"message_size":100,"sender":"held@example.test","recipients":[{"address":"one@example.test"}]}
{"queue_id":"NORMAL-1","queue_name":"deferred","arrival_time":1700000100,"message_size":200,"sender":"normal@example.test","recipients":[{"address":"two@example.test"}]}
EOF_HOLD_FAILURES
VW_TEST_FAIL_DELETE_IDS=HELD-1,NORMAL-1
export VW_TEST_FAIL_DELETE_IDS
if run_queue purge --snapshot </dev/null >"$TMP/purge-partial.out" 2>&1; then
    fail 'partial purge failure returned success'
fi
grep -Fq '"queue_id":"HELD-1","queue_name":"hold"' "$INVENTORY" \
    || fail 'message held before purge did not remain held'
grep -Fq '"queue_id":"NORMAL-1","queue_name":"deferred"' "$INVENTORY" \
    || fail 'newly held deletion survivor was not released'
grep -Fq 'Failed operations:' "$TMP/purge-partial.out" || fail 'partial failure summary missing'
unset VW_TEST_FAIL_DELETE_IDS
pass 'pre-existing holds are preserved and newly held survivors are restored'

rm -f "${INVENTORY}.hold-event"
: >"$INVENTORY_CALLS"
python3 - "$INVENTORY" <<'PY_LARGE'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
with path.open("w") as handle:
    for index in range(100):
        item = {
            "queue_id": f"Q{index:03d}",
            "queue_name": "deferred",
            "arrival_time": 1700000000 + index,
            "message_size": 100 + index,
            "sender": f"sender{index}@example.test",
            "recipients": [{"address": f"recipient{index}@example.test"}],
        }
        handle.write(json.dumps(item, separators=(",", ":")) + "\n")
PY_LARGE
VW_TEST_ADD_NEW_ON_HOLD=true
export VW_TEST_ADD_NEW_ON_HOLD
run_queue purge --snapshot </dev/null >"$TMP/purge-large.out"
grep -Fq '"queue_id":"NEW-AFTER-SNAPSHOT"' "$INVENTORY" \
    || fail 'new different queue ID was deleted'
[[ "$(grep -c '^' "$INVENTORY")" -eq 1 ]] || fail 'stable snapshot messages were not all deleted'
grep -Fq 'Deleted snapshot messages: 100' "$TMP/purge-large.out" \
    || fail 'stable snapshot deletions were not reported'
inventory_count=$(wc -l <"$INVENTORY_CALLS")
(( inventory_count <= 4 )) \
    || fail "100-message purge used $inventory_count complete inventories"
unset VW_TEST_ADD_NEW_ON_HOLD
pass '100 stable messages delete with fixed inventories while new mail remains'

if find "$QUEUE_TMP" -mindepth 1 -print -quit | grep -q .; then
    fail 'queue utility left private temporary files behind'
fi
pass 'private queue temporary files are cleaned'

rm -f "${INVENTORY}.hold-event"
base_inventory
VW_EMAIL_QUEUE_CONFIRM=
VW_EMAIL_QUEUE_CLEAR_CONFIRMED=true
export VW_EMAIL_QUEUE_CONFIRM VW_EMAIL_QUEUE_CLEAR_CONFIRMED
if run_queue clear </dev/null >"$TMP/clear-wrong.out" 2>&1; then
    fail 'deprecated clear accepted non-exact legacy marker'
fi
VW_EMAIL_QUEUE_CLEAR_CONFIRMED=1
export VW_EMAIL_QUEUE_CLEAR_CONFIRMED
run_queue clear </dev/null >"$TMP/clear.out"
grep -Fqi 'deprecated' "$TMP/clear.out" "$TMP/clear-wrong.out" || fail 'clear deprecation warning missing'
! grep -Fq '<postsuper> <-d> <ALL>' "$CALLS" || fail 'clear alias used ALL deletion'
pass 'deprecated clear uses identity-verified snapshot behavior'

base_inventory
VW_TEST_LOG_OUTPUT='Jul 28 postfix literal.ABC[123] result'
export VW_TEST_LOG_OUTPUT
run_queue logs 'ABC[123]' --tail 100 >"$TMP/logs.out"
grep -Fq 'literal.ABC[123]' "$TMP/logs.out" || fail 'logs did not use fixed-string queue ID matching'
run_queue logs DOES-NOT-MATCH --tail 100 >"$TMP/no-logs.out" 2>&1
grep -Fq 'No Postfix log lines matched' "$TMP/no-logs.out" || fail 'no-match log result was not truthful'
pass 'log tail validation and fixed-string filtering'

write_inventory <<'EOF_SIGNAL'
{"queue_id":"SIGNAL-NEW","queue_name":"deferred","arrival_time":1700000200,"message_size":300,"sender":"signal@example.test","recipients":[{"address":"signal-recipient@example.test"}]}
{"queue_id":"SIGNAL-HELD","queue_name":"hold","arrival_time":1700000300,"message_size":400,"sender":"preheld@example.test","recipients":[{"address":"preheld-recipient@example.test"}]}
EOF_SIGNAL
rm -f "${INVENTORY}.hold-event"
signal_marker="$TMP/targeted-delete-hold-ready"
signal_release="$TMP/targeted-delete-hold-release"
rm -f "$signal_marker" "$signal_release"
VW_EMAIL_QUEUE_CONFIRM=delete:SIGNAL-NEW
VW_TEST_BLOCK_AFTER_HOLD_MARKER="$signal_marker"
VW_TEST_BLOCK_AFTER_HOLD_RELEASE="$signal_release"
export VW_EMAIL_QUEUE_CONFIRM VW_TEST_BLOCK_AFTER_HOLD_MARKER VW_TEST_BLOCK_AFTER_HOLD_RELEASE
(
    exec setsid env \
        "PATH=$BIN:$PATH" \
        "VW_TEST_DOCKER_CALLS=$CALLS" \
        "VW_TEST_INVENTORY=$INVENTORY" \
        "VW_TEST_POSTFIX_RUNNING=true" \
        "VW_TEST_MALFORMED_INVENTORY=false" \
        "VW_TEST_FAIL_DELETE_ID=" \
        "VW_TEST_FAIL_DELETE_IDS=" \
        "VW_TEST_ALREADY_ABSENT_DELETE_ID=" \
        "VW_TEST_FAIL_RETRY_ID=" \
        "VW_TEST_REUSE_ID_ON_HOLD=" \
        "VW_TEST_REUSE_SAME_ID_ON_HOLD=" \
        "VW_TEST_REMOVE_ID_ON_HOLD=" \
        "VW_TEST_ADD_NEW_ON_HOLD=false" \
        "VW_TEST_FAIL_HOLD_ID=" \
        "VW_TEST_FAIL_RELEASE_ID=" \
        "VW_TEST_LONG_QUEUE_IDS=yes" \
        "VW_TEST_POSTCONF_FAIL=false" \
        "VW_TEST_BLOCK_AFTER_HOLD_MARKER=$signal_marker" \
        "VW_TEST_BLOCK_AFTER_HOLD_RELEASE=$signal_release" \
        "VW_TEST_LOG_OUTPUT=Jul 28 postfix test" \
        "VW_TEST_INVENTORY_CALLS=$INVENTORY_CALLS" \
        "VW_EMAIL_QUEUE_LOCK_FILE=$LOCK_FILE" \
        "TMPDIR=$QUEUE_TMP" \
        "VW_EMAIL_QUEUE_CONFIRM=delete:SIGNAL-NEW" \
        "VW_EMAIL_QUEUE_CLEAR_CONFIRMED=" \
        "VW_TEST_MODE=1" \
        "VAULTWARDEN_TEST_ALLOW_NON_ROOT=1" \
        bash "$FIXTURE/utilities/email-queue.sh" delete SIGNAL-NEW
) >"$TMP/signal.out" 2>&1 &
signal_pid=$!
signal_ready=false
for _ in $(seq 1 200); do
    if [[ -e "$signal_marker" ]]; then
        signal_ready=true
        break
    fi
    if ! kill -0 "$signal_pid" 2>/dev/null; then
        break
    fi
    sleep 0.01
done
if [[ "$signal_ready" != true ]]; then
    stop_test_process_group "$signal_pid"
    signal_pid=""
    fail 'signal rollback test did not reach the post-hold synchronization marker'
fi
kill -TERM -- "-$signal_pid"
set +e
wait "$signal_pid"
signal_rc=$?
set -e
stop_test_process_group "$signal_pid"
signal_pid=""
[[ $signal_rc -eq 143 ]] || fail "signal rollback returned $signal_rc instead of 143"
grep -Fq '"queue_id":"SIGNAL-NEW","queue_name":"deferred"' "$INVENTORY" \
    || fail 'SIGTERM cleanup did not release the newly held survivor'
grep -Fq '"queue_id":"SIGNAL-HELD","queue_name":"hold"' "$INVENTORY" \
    || fail 'SIGTERM cleanup released a pre-existing hold'
if find "$QUEUE_TMP" -mindepth 1 -print -quit | grep -q .; then
    fail 'SIGTERM cleanup left private temporary files behind'
fi
unset VW_TEST_BLOCK_AFTER_HOLD_MARKER VW_TEST_BLOCK_AFTER_HOLD_RELEASE
VW_EMAIL_QUEUE_CONFIRM=
export VW_EMAIL_QUEUE_CONFIRM
run_queue retry SIGNAL-NEW >"$TMP/post-signal-lock.out" \
    || fail 'mutation lock was not available after signal cleanup'
pass 'signal cleanup releases only newly introduced holds and frees the mutation lock'

base_inventory
VW_EMAIL_QUEUE_CONFIRM=retry-all
export VW_EMAIL_QUEUE_CONFIRM
setsid bash -c '
    set -euo pipefail
    lock_file=$1
    ready_file=$2
    exec 8>"$lock_file"
    flock 8
    : >"$ready_file"
    exec sleep 30
' _ "$LOCK_FILE" "$TMP/lock-ready" &
lock_pid=$!
for _ in $(seq 1 100); do
    [[ -e "$TMP/lock-ready" ]] && break
    sleep 0.01
done
if run_queue retry --all </dev/null >"$TMP/lock.out" 2>&1; then
    stop_test_process_group "$lock_pid"
    lock_pid=""
    fail 'concurrent queue mutation acquired an already-held lock'
fi
stop_test_process_group "$lock_pid"
lock_pid=""
grep -Fq 'Another Postfix queue mutation is already running' "$TMP/lock.out" \
    || fail 'lock contention error is not actionable'
exec {lock_probe_fd}>"$LOCK_FILE"
flock -n "$lock_probe_fd" \
    || fail 'lock-holder test process group survived cleanup'
flock -u "$lock_probe_fd"
exec {lock_probe_fd}>&-
pass 'mutating queue commands use an exclusive host-side lock'

VW_TEST_POSTFIX_RUNNING=false
export VW_TEST_POSTFIX_RUNNING
if run_queue status >"$TMP/stopped.out" 2>&1; then
    fail 'status succeeded while Postfix was stopped'
fi
grep -Fq "Compose service 'postfix' is not running" "$TMP/stopped.out" || fail 'stopped service error is not actionable'
pass 'stopped Postfix failure'

run_hardening_tests
printf 'Postfix queue operation tests passed.\n'
