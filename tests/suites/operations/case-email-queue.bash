#!/usr/bin/env bash
# Focused behavior and command-shape coverage for safe Postfix queue operations.

set -euo pipefail
# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

FIXTURE="$TMP/project"
BIN="$TMP/bin"
CALLS="$TMP/docker.calls"
INVENTORY="$TMP/inventory.ndjson"
QUEUE_TMP="$TMP/queue-tmp"
mkdir -p "$FIXTURE/utilities" "$FIXTURE/lib" "$BIN" "$QUEUE_TMP"
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
if [[ "${1:-}" == info ]]; then
    exit 0
fi
if [[ "${1:-}" == compose && "${2:-}" == version ]]; then
    printf 'Docker Compose version test\n'
    exit 0
fi
if [[ "${1:-}" == compose && "${2:-}" == ps && "${3:-}" == --services     && "${4:-}" == --filter && "${5:-}" == status=running ]]; then
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
        [[ "${VW_TEST_MALFORMED_INVENTORY:-false}" == true ]] \
            && { printf '{not-json}\n'; exit 0; }
        cat "${VW_TEST_INVENTORY:?}"
        exit 0
    fi
    if [[ "${1:-}" == --user && "${2:-}" == root && "${3:-}" == postfix ]]; then
        shift 3
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
            printf 'flushed\n'
            exit 0
        fi
        if [[ "${1:-}" == postsuper && "${2:-}" == -d ]]; then
            id="${3:-}"
            if [[ "${VW_TEST_FAIL_DELETE_ID:-}" == "$id" ]]; then
                exit 1
            fi
            already_absent=false
            if [[ "${VW_TEST_ALREADY_ABSENT_DELETE_ID:-}" == "$id" ]]; then
                already_absent=true
            fi
            python3 - "$id" "${VW_TEST_INVENTORY:?}" <<'PY_DELETE'
import json, sys
from pathlib import Path
wanted, path = sys.argv[1], Path(sys.argv[2])
kept = []
for line in path.read_text().splitlines():
    if not line.strip():
        continue
    if json.loads(line).get("queue_id") != wanted:
        kept.append(line)
path.write_text("\n".join(kept) + ("\n" if kept else ""))
PY_DELETE
            if [[ "$already_absent" == true ]]; then
                exit 1
            fi
            if [[ "${VW_TEST_ADD_AFTER_FIRST_DELETE:-false}" == true && ! -e "${VW_TEST_INVENTORY}.added" ]]; then
                printf '%s\n' '{"queue_id":"NEW-AFTER-SNAPSHOT","queue_name":"deferred","arrival_time":1700000300,"message_size":5,"sender":"new@example.test","recipients":[]}' >>"${VW_TEST_INVENTORY}"
                : >"${VW_TEST_INVENTORY}.added"
            fi
            printf 'deleted %s\n' "$id"
            exit 0
        fi
    fi
fi
if [[ "${1:-}" == compose && "${2:-}" == logs && "${3:-}" == --no-color && "${4:-}" == --tail && "${6:-}" == postfix ]]; then
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
        "VW_TEST_ALREADY_ABSENT_DELETE_ID=${VW_TEST_ALREADY_ABSENT_DELETE_ID:-}" \
        "VW_TEST_FAIL_RETRY_ID=${VW_TEST_FAIL_RETRY_ID:-}" \
        "VW_TEST_ADD_AFTER_FIRST_DELETE=${VW_TEST_ADD_AFTER_FIRST_DELETE:-false}" \
        "VW_TEST_LOG_OUTPUT=${VW_TEST_LOG_OUTPUT:-Jul 28 postfix ABC[123]: queued}" \
        "TMPDIR=$QUEUE_TMP" \
        "VW_EMAIL_QUEUE_CONFIRM=${VW_EMAIL_QUEUE_CONFIRM:-}" \
        "VW_EMAIL_QUEUE_CLEAR_CONFIRMED=${VW_EMAIL_QUEUE_CLEAR_CONFIRMED:-}" \
        "VW_TEST_MODE=1" \
        "VAULTWARDEN_TEST_ALLOW_NON_ROOT=1" \
        bash "$FIXTURE/utilities/email-queue.sh" "$@"
}

base_inventory() {
    write_inventory <<'EOF_INV'
{"queue_id":"AbC-123","queue_name":"deferred","arrival_time":1700000000,"message_size":100,"sender":"sender@example.test","recipients":[{"address":"one@example.test","delay_reason":"connection timed out"}]}
{"queue_id":"XYZ987","queue_name":"active","arrival_time":1700000100,"message_size":250,"sender":"second@example.test","recipients":[{"address":"two@example.test","delay_reason":"connection timed out"},{"address":"three@example.test","delay_reason":"temporary lookup failure"}]}
EOF_INV
}

script="$ROOT/utilities/email-queue.sh"
grep -Fq 'require_root "${original_args[@]}"' "$script" || fail 'root requirement missing'
grep -Fq 'VW_TEST_MODE:-0' "$script" || fail 'test gate missing'
grep -Fq 'VAULTWARDEN_TEST_ALLOW_NON_ROOT:-0' "$script" || fail 'non-root test gate missing'
! grep -Fq 'postsuper -d ALL' "$script" || fail 'unsafe live ALL deletion remains'
! grep -Eq 'postsuper[[:space:]]+"\$@"|eval[[:space:]]' "$script" || fail 'generic command forwarding or eval found'
pass 'static queue safety contract'

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

base_inventory
VW_EMAIL_QUEUE_CONFIRM=delete:WRONG
export VW_EMAIL_QUEUE_CONFIRM
if run_queue delete AbC-123 </dev/null >"$TMP/delete-wrong.out" 2>&1; then
    fail 'delete accepted marker for another ID'
fi
VW_EMAIL_QUEUE_CONFIRM=delete:AbC-123
export VW_EMAIL_QUEUE_CONFIRM
run_queue delete AbC-123 </dev/null >"$TMP/delete.out"
! grep -Fq '"queue_id":"AbC-123"' "$INVENTORY" || fail 'delete did not remove selected ID'
grep -Fq '"queue_id":"XYZ987"' "$INVENTORY" || fail 'delete removed another ID'
pass 'single deletion is ID-bound'

base_inventory
VW_EMAIL_QUEUE_CONFIRM=purge-snapshot
VW_TEST_ADD_AFTER_FIRST_DELETE=true
export VW_EMAIL_QUEUE_CONFIRM VW_TEST_ADD_AFTER_FIRST_DELETE
run_queue purge --snapshot </dev/null >"$TMP/purge.out"
grep -Fq '"queue_id":"NEW-AFTER-SNAPSHOT"' "$INVENTORY" || fail 'snapshot purge deleted newly arrived mail'
! grep -Fq '"queue_id":"AbC-123"' "$INVENTORY" || fail 'snapshot purge left captured ID'
! grep -Fq '"queue_id":"XYZ987"' "$INVENTORY" || fail 'snapshot purge left captured ID'
! grep -Fq '<postsuper> <-d> <ALL>' "$CALLS" || fail 'snapshot purge used ALL'
unset VW_TEST_ADD_AFTER_FIRST_DELETE
pass 'snapshot purge deletes only captured IDs'

base_inventory
VW_TEST_ALREADY_ABSENT_DELETE_ID=AbC-123
export VW_TEST_ALREADY_ABSENT_DELETE_ID
run_queue purge --snapshot </dev/null >"$TMP/purge-absent.out"
grep -Fq 'Already absent: 1' "$TMP/purge-absent.out" || fail 'concurrently absent item was not reported accurately'
unset VW_TEST_ALREADY_ABSENT_DELETE_ID
pass 'snapshot purge handles an already-missing item'

if find "$QUEUE_TMP" -mindepth 1 -print -quit | grep -q .; then
    fail 'queue utility left private temporary files behind'
fi
pass 'private queue temporary files are cleaned'

base_inventory
VW_TEST_FAIL_DELETE_ID=XYZ987
export VW_TEST_FAIL_DELETE_ID
if run_queue purge --snapshot </dev/null >"$TMP/purge-partial.out" 2>&1; then
    fail 'partial purge failure returned success'
fi
grep -Fq 'Failed: 1' "$TMP/purge-partial.out" || fail 'partial purge failure was not reported'
unset VW_TEST_FAIL_DELETE_ID
pass 'snapshot purge continues and reports partial failure'

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
pass 'deprecated clear uses snapshot behavior'

base_inventory
VW_TEST_LOG_OUTPUT='Jul 28 postfix literal.ABC[123] result'
export VW_TEST_LOG_OUTPUT
run_queue logs 'ABC[123]' --tail 100 >"$TMP/logs.out"
grep -Fq 'literal.ABC[123]' "$TMP/logs.out" || fail 'logs did not use fixed-string queue ID matching'
run_queue logs DOES-NOT-MATCH --tail 100 >"$TMP/no-logs.out"
grep -Fq 'No Postfix log lines matched' "$TMP/no-logs.out" || fail 'no-match log result was not truthful'
pass 'log tail validation and fixed-string filtering'

VW_TEST_POSTFIX_RUNNING=false
export VW_TEST_POSTFIX_RUNNING
if run_queue status >"$TMP/stopped.out" 2>&1; then
    fail 'status succeeded while Postfix was stopped'
fi
grep -Fq "Compose service 'postfix' is not running" "$TMP/stopped.out" || fail 'stopped service error is not actionable'
pass 'stopped Postfix failure'

printf 'Postfix queue operation tests passed.\n'
