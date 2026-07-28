#!/usr/bin/env bash
# Focused behavior and command-shape coverage for Postfix queue operations.

set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

FIXTURE="$TMP/project"
BIN="$TMP/bin"
CALLS="$TMP/docker.calls"
mkdir -p "$FIXTURE/utilities" "$FIXTURE/lib" "$BIN"
cp "$ROOT/utilities/email-queue.sh" "$FIXTURE/utilities/"
cp "$ROOT/lib/log.sh" "$ROOT/lib/common.sh" "$ROOT/lib/docker.sh" "$FIXTURE/lib/"
chmod +x "$FIXTURE/utilities/email-queue.sh"

cat >"$BIN/docker" <<'EOF_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${VW_TEST_DOCKER_CALLS:?}"
case "$*" in
    info)
        exit 0
        ;;
    "compose version")
        printf 'Docker Compose version test\n'
        ;;
    "compose ps --services --filter status=running")
        [[ "${VW_TEST_POSTFIX_RUNNING:-true}" == true ]] && printf 'postfix\n'
        ;;
    "compose exec -T postfix postqueue -p")
        printf '%s\n' "${VW_TEST_QUEUE_OUTPUT:--- 0 Kbytes in 0 Requests.}"
        ;;
    "compose exec -T --user root postfix postsuper -d ALL")
        printf 'Deleted: ALL\n'
        ;;
    *)
        printf 'unexpected docker invocation: %s\n' "$*" >&2
        exit 97
        ;;
esac
EOF_DOCKER
chmod +x "$BIN/docker"

run_queue() {
    env \
        "PATH=$BIN:$PATH" \
        "VW_TEST_DOCKER_CALLS=$CALLS" \
        "VW_TEST_POSTFIX_RUNNING=${VW_TEST_POSTFIX_RUNNING:-true}" \
        "VW_EMAIL_QUEUE_CLEAR_CONFIRMED=${VW_EMAIL_QUEUE_CLEAR_CONFIRMED:-}" \
        "VW_TEST_MODE=1" \
        "VAULTWARDEN_TEST_ALLOW_NON_ROOT=1" \
        bash "$FIXTURE/utilities/email-queue.sh" "$@"
}

grep -Fq 'require_root "$@"' "$ROOT/utilities/email-queue.sh" \
    || fail "queue utility does not explicitly require root"
grep -Fq 'VW_TEST_MODE:-0' "$ROOT/utilities/email-queue.sh" \
    || fail "queue utility test bypass is not narrowly test-gated"
grep -Fq 'VAULTWARDEN_TEST_ALLOW_NON_ROOT:-0' "$ROOT/utilities/email-queue.sh" \
    || fail "queue utility test bypass lacks the explicit non-root gate"
grep -Fq 'if [[ "$confirmation" != "CLEAR" ]]' "$ROOT/utilities/email-queue.sh" \
    || fail "queue utility does not require the exact interactive CLEAR token"
grep -Fq '[[ "${VW_EMAIL_QUEUE_CLEAR_CONFIRMED:-}" == "1" ]]' \
    "$ROOT/utilities/email-queue.sh" \
    || fail "queue utility does not require the exact automation confirmation marker"

if (( EUID != 0 )); then
    if env \
        "PATH=$BIN:$PATH" \
        "VW_TEST_DOCKER_CALLS=$CALLS" \
        bash "$FIXTURE/utilities/email-queue.sh" status \
        >"$TMP/nonroot.out" 2>&1; then
        fail "queue utility accepted ordinary non-root execution"
    fi
    grep -Fq 'Re-run with: sudo' "$TMP/nonroot.out" \
        || fail "queue utility non-root rejection lacks sudo guidance"
fi

: >"$CALLS"
run_queue status >"$TMP/status.out"
grep -Fxq 'compose exec -T postfix postqueue -p' "$CALLS" \
    || fail "queue status did not use the Compose postfix service"
! grep -Fq 'postsuper' "$CALLS" || fail "queue status attempted deletion"

: >"$CALLS"
VW_EMAIL_QUEUE_CLEAR_CONFIRMED=true
export VW_EMAIL_QUEUE_CLEAR_CONFIRMED
if run_queue clear </dev/null >"$TMP/wrong-marker.out" 2>&1; then
    fail "non-exact automation marker cleared the queue"
fi
grep -Fq 'requires an interactive TTY or VW_EMAIL_QUEUE_CLEAR_CONFIRMED=1' \
    "$TMP/wrong-marker.out" \
    || fail "non-interactive clear did not explain the exact automation marker"
! grep -Fq 'postsuper' "$CALLS" || fail "non-exact marker reached queue deletion"

: >"$CALLS"
VW_EMAIL_QUEUE_CLEAR_CONFIRMED=1
export VW_EMAIL_QUEUE_CLEAR_CONFIRMED
run_queue clear </dev/null >"$TMP/clear.out"
mapfile -t queue_calls < <(
    grep -E '^compose exec -T (postfix postqueue -p|--user root postfix postsuper -d ALL)$' "$CALLS"
)
[[ "${#queue_calls[@]}" -eq 3 ]] || fail "clear did not perform before/delete/after sequence"
[[ "${queue_calls[0]}" == 'compose exec -T postfix postqueue -p' ]] \
    || fail "clear did not inspect the queue first"
[[ "${queue_calls[1]}" == 'compose exec -T --user root postfix postsuper -d ALL' ]] \
    || fail "clear did not use root inside the Compose postfix service"
[[ "${queue_calls[2]}" == 'compose exec -T postfix postqueue -p' ]] \
    || fail "clear did not inspect the queue after deletion"

: >"$CALLS"
VW_TEST_POSTFIX_RUNNING=false
export VW_TEST_POSTFIX_RUNNING
if run_queue status >"$TMP/stopped.out" 2>&1; then
    fail "queue status succeeded while the Compose postfix service was stopped"
fi
grep -Fq "Compose service 'postfix' is not running" "$TMP/stopped.out" \
    || fail "stopped Postfix failure was not actionable"
! grep -Fq 'compose exec' "$CALLS" || fail "stopped service still received an exec"

printf 'Postfix queue operation tests passed.\n'
