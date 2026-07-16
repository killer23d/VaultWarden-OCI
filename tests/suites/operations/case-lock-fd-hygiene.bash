#!/usr/bin/env bash
# Focused regression coverage for child-process lock descriptor hygiene.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_LIB="$ROOT/lib/log.sh"
CROWDSEC_WORKER_LIB="$ROOT/lib/crowdsec-worker.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

extract_function() {
    local file="$1" function_name="$2"
    awk -v function_name="$function_name" '
        $0 ~ "^" function_name "\\(\\)" { printing=1 }
        printing {
            print
            opens=gsub(/\{/, "{")
            closes=gsub(/\}/, "}")
            depth += opens - closes
            if (depth == 0) exit
        }
    ' "$file"
}

spinner_block="$(sed -n '/^spinner_start()/,/^spinner_stop()/p' "$LOG_LIB")"
for variable in \
    OPERATION_SPECIFIC_LOCK_FD \
    OPERATION_LOCK_FD \
    VW_OPERATION_INHERITED_FD \
    HEALTH_LOCK_FD; do
    grep -Fq "$variable" <<< "$spinner_block" \
        || fail "spinner_start must isolate ${variable}"
done
grep -Fq 'eval "exec ${fd}>&-"' <<< "$spinner_block" \
    || fail "spinner_start must close inherited guard descriptors in its child"

if [[ "$(uname -s)" == "Linux" ]] \
    && [[ -r /proc/$$/stat ]] \
    && command -v flock >/dev/null 2>&1 \
    && command -v script >/dev/null 2>&1 \
    && script -q -e -c 'exit 0' /dev/null >/dev/null 2>&1; then
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    harness="$tmpdir/spinner-harness.bash"
    result="$tmpdir/result"

    cat > "$harness" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail

root="$1"
result="$2"
tmpdir="$3"

# shellcheck source=/dev/null
source "$root/lib/log.sh"

exec {global_fd}>"$tmpdir/global.lock"
exec {specific_fd}>"$tmpdir/specific.lock"
exec {inherited_fd}>"$tmpdir/inherited.lock"
exec {health_fd}>"$tmpdir/health.lock"
flock -n "$global_fd"
flock -n "$specific_fd"
flock -n "$inherited_fd"
flock -n "$health_fd"

OPERATION_LOCK_FD="$global_fd"
OPERATION_SPECIFIC_LOCK_FD="$specific_fd"
VW_OPERATION_INHERITED_FD="$inherited_fd"
HEALTH_LOCK_FD="$health_fd"

spinner_start "Testing descriptor isolation"
spinner_pid="$_spinner_pid"
[[ "$spinner_pid" =~ ^[0-9]+$ ]]

for _ in {1..50}; do
    [[ -d "/proc/${spinner_pid}" ]] && break
    sleep 0.02
done
[[ -d "/proc/${spinner_pid}" ]]

for _ in {1..50}; do
    leaked=false
    for fd in "$global_fd" "$specific_fd" "$inherited_fd" "$health_fd"; do
        [[ -e "/proc/${spinner_pid}/fd/${fd}" ]] && leaked=true
    done
    [[ "$leaked" == "false" ]] && break
    sleep 0.02
done

for fd in "$global_fd" "$specific_fd" "$inherited_fd" "$health_fd"; do
    [[ -e "/proc/${BASHPID}/fd/${fd}" ]]
    [[ ! -e "/proc/${spinner_pid}/fd/${fd}" ]]
done

spinner_stop true >/dev/null
printf 'pass\n' > "$result"
HARNESS
    chmod +x "$harness"

    command_text="$(printf '%q %q %q %q' "$BASH" "$harness" "$ROOT" "$result") $(printf '%q' "$tmpdir")"
    script -q -e -c "$command_text" /dev/null >/dev/null 2>&1 \
        || fail "spinner descriptor-isolation harness failed"
    [[ "$(cat "$result" 2>/dev/null || true)" == "pass" ]] \
        || fail "spinner descriptor-isolation harness did not complete"

    rm -rf "$tmpdir"
    trap - EXIT
else
    printf 'NOTE: spinner descriptor behavior test skipped; Linux /proc, flock, and util-linux script are required.\n'
fi

grep -Fq '_crowdsec_worker_run_without_guard_fds()' "$CROWDSEC_WORKER_LIB" \
    || fail "CrowdSec worker library must provide a narrow external-command isolation helper"
grep -Fq 'if _crowdsec_worker_run_without_guard_fds "$bouncer_bin" -S -c "$dest"; then' "$CROWDSEC_WORKER_LIB" \
    || fail "autonomous CrowdSec Workers deployment must use descriptor isolation"
if grep -Fq 'if "$bouncer_bin" -S -c "$dest"; then' "$CROWDSEC_WORKER_LIB"; then
    fail "autonomous CrowdSec Workers deployment still invokes the bouncer directly"
fi

helper_file="$(mktemp)"
trap 'rm -f "$helper_file"' EXIT
extract_function "$CROWDSEC_WORKER_LIB" _crowdsec_worker_run_without_guard_fds > "$helper_file"
# shellcheck source=/dev/null
source "$helper_file"

marker="$(mktemp)"
operation_run_without_guard_fds() {
    printf 'used\n' > "$marker"
    "$@"
}
wrapped_output="$(_crowdsec_worker_run_without_guard_fds printf '%s' wrapped)"
[[ "$wrapped_output" == "wrapped" && "$(cat "$marker")" == "used" ]] \
    || fail "CrowdSec worker helper did not delegate through operation descriptor isolation"

unset -f operation_run_without_guard_fds
fallback_output="$(_crowdsec_worker_run_without_guard_fds printf '%s' fallback)"
[[ "$fallback_output" == "fallback" ]] \
    || fail "CrowdSec worker helper fallback did not execute the command"

rm -f "$helper_file" "$marker"
trap - EXIT
printf 'Lock descriptor hygiene tests passed.\n'
