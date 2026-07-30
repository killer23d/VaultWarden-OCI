#!/usr/bin/env bash
# Safe Postfix queue operations through the Compose service.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/log.sh
source "${PROJECT_ROOT}/lib/log.sh"
# shellcheck source=../lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"
# shellcheck source=../lib/docker.sh
source "${PROJECT_ROOT}/lib/docker.sh"

_TEMP_PATHS=()
_NEW_TEMP_DIR=""
_MUTATION_LOCK_FD=""
_HOLD_ROLLBACK_FILE=""
_HOLD_ROLLBACK_ACTIVE=false
_LONG_QUEUE_IDS_VALUE=""

show_help() {
    cat <<'EOF'
VaultWarden-OCI Postfix Queue Operations

USAGE:
    sudo utilities/email-queue.sh [status]
    sudo utilities/email-queue.sh summary [--quiet | --json]
    sudo utilities/email-queue.sh inspect QUEUE_ID [--body]
    sudo utilities/email-queue.sh retry QUEUE_ID
    sudo utilities/email-queue.sh retry --all
    sudo utilities/email-queue.sh delete QUEUE_ID
    sudo utilities/email-queue.sh logs [QUEUE_ID] [--tail N]
    sudo utilities/email-queue.sh purge --snapshot
    sudo utilities/email-queue.sh clear

COMMANDS:
    status                  Show the human-readable Postfix queue. This is the
                            default and never mutates queued mail.
    summary [MODE]          Show count, bytes, oldest age, queue states, and the
                            most frequent current delay reason. MODE is
                            --quiet or --json.
    inspect ID [--body]     Show envelope and header details for an exact queue
                            ID. Message bodies are excluded unless --body is
                            explicitly supplied.
    retry ID                Schedule immediate delivery for one exact queue ID.
    retry --all             Flush all currently queued mail after exact
                            confirmation.
    delete ID               Require verified long queue IDs, then hold and
                            identity-verify one exact message after confirmation
                            and delete only that held identity match.
    logs [ID] [--tail N]    Show Postfix logs, optionally filtered by a fixed
                            queue-ID string. N defaults to 200 and is limited to
                            1..5000.
    purge --snapshot        Require verified long queue IDs, capture stable
                            identities, hold eligible snapshot messages, and
                            delete only held identity matches.
    clear                   Deprecated alias for purge --snapshot.

AUTOMATION CONFIRMATION:
    VW_EMAIL_QUEUE_CONFIRM=retry-all
    VW_EMAIL_QUEUE_CONFIRM=delete:QUEUE_ID
    VW_EMAIL_QUEUE_CONFIRM=purge-snapshot
    VW_EMAIL_QUEUE_CLEAR_CONFIRMED=1   Deprecated; accepted only by clear.

CONFIRMATION TOKENS:
    retry --all             RETRY ALL
    delete QUEUE_ID         DELETE QUEUE_ID
    purge --snapshot        PURGE N

EXIT STATUS:
    0  Success, including an empty queue or no matching log lines.
    1  Operational failure, cancellation, identity mismatch, or partial destructive failure.
    2  Invalid usage.
    129, 130, 143  Interrupted by SIGHUP, SIGINT, or SIGTERM.

NOTES:
    Mutating commands use one exclusive host-side lock. Destructive commands
    fail closed unless the effective Postfix setting enable_long_queue_ids=yes.
    They also compare arrival time, size, envelope sender, and recipients, then
    require a matching record to be held before deletion; metadata is defence in
    depth, not a substitute for non-repeating queue IDs. Newly introduced
    holds are restored after failure or interruption when possible; pre-existing
    holds are preserved. External administrators that bypass this utility are
    outside the host lock and must not mutate the queue during destructive work.
    A retry or Postfix acceptance does not prove final recipient delivery.
EOF
}

_best_effort_hold_rollback() {
    local rollback_file="${_HOLD_ROLLBACK_FILE:-}"
    if [[ "${_HOLD_ROLLBACK_ACTIVE:-false}" != true \
        || -z "$rollback_file" || ! -s "$rollback_file" ]]; then
        return 0
    fi
    # Clear the guard first so an EXIT-path failure cannot recurse. This is a
    # best-effort safety net for signals and unexpected errors after holding.
    _HOLD_ROLLBACK_ACTIVE=false
    if declare -F _release_ids >/dev/null 2>&1; then
        _release_ids "$rollback_file" \
            || log_warn "Could not fully roll back Postfix holds during cleanup."
    fi
}

_cleanup_temp() {
    local original_status=$? path
    # Prevent cleanup failures from changing the command result or recursively
    # triggering another EXIT cleanup while rollback is in progress.
    trap - EXIT
    set +e
    _best_effort_hold_rollback
    for path in "${_TEMP_PATHS[@]}"; do
        [[ -n "$path" ]] && rm -rf -- "$path"
    done
    return "$original_status"
}

_signal_exit() {
    local status="$1"
    exit "$status"
}

trap _cleanup_temp EXIT
trap '_signal_exit 130' INT
trap '_signal_exit 129' HUP
trap '_signal_exit 143' TERM

_new_private_tempdir() {
    local dir
    umask 077
    dir=$(mktemp -d -t vw-email-queue.XXXXXXXXXX) || {
        log_error "Unable to create a private temporary directory."
        return 1
    }
    _TEMP_PATHS+=("$dir")
    _NEW_TEMP_DIR="$dir"
}

_run_without_mutation_lock_fd() (
    # Docker/Compose descendants must never extend the lifetime of the
    # host mutation lock. The parent retains its descriptor throughout.
    if [[ -n "${_MUTATION_LOCK_FD:-}" ]]; then
        exec {_MUTATION_LOCK_FD}>&-
    fi
    exec "$@"
)

_require_postfix_service() {
    if ! _run_without_mutation_lock_fd docker compose ps --services --filter status=running 2>/dev/null \
        | grep -Fxq postfix; then
        log_error "The Compose service 'postfix' is not running."
        log_hint "Start the stack first: sudo make up"
        return 1
    fi
}

_require_machine_inventory() {
    if ! command -v python3 >/dev/null 2>&1; then
        log_error "Machine-readable queue operations require python3 to parse 'postqueue -j' safely."
        log_hint "Install the repository-supported host dependencies, then retry."
        return 1
    fi
}


_resolve_mutation_lock_file() {
    if [[ "${VW_TEST_MODE:-0}" == "1" \
        && "${VAULTWARDEN_TEST_ALLOW_NON_ROOT:-0}" == "1" \
        && -n "${VW_EMAIL_QUEUE_LOCK_FILE:-}" ]]; then
        printf '%s\n' "$VW_EMAIL_QUEUE_LOCK_FILE"
    else
        printf '%s\n' '/run/lock/vaultwarden-email-queue.lock'
    fi
}

_acquire_mutation_lock() {
    local lock_file lock_dir old_umask
    if ! command -v flock >/dev/null 2>&1; then
        log_error "Mutating queue operations require flock for exclusive host-side locking."
        return 1
    fi
    lock_file=$(_resolve_mutation_lock_file)
    lock_dir=${lock_file%/*}
    if [[ "${VW_TEST_MODE:-0}" == "1" \
        && "${VAULTWARDEN_TEST_ALLOW_NON_ROOT:-0}" == "1" ]]; then
        mkdir -p -- "$lock_dir" || return 1
    elif [[ ! -d "$lock_dir" ]]; then
        log_error "Queue mutation lock directory is unavailable: $lock_dir"
        return 1
    fi
    old_umask=$(umask)
    umask 077
    if ! exec {_MUTATION_LOCK_FD}>"$lock_file"; then
        umask "$old_umask"
        log_error "Unable to open the queue mutation lock: $lock_file"
        return 1
    fi
    umask "$old_umask"
    if ! flock -n "$_MUTATION_LOCK_FD"; then
        log_error "Another Postfix queue mutation is already running."
        log_hint "Wait for it to finish, then retry. Lock: $lock_file"
        return 1
    fi
}

_read_long_queue_ids() {
    local output_file
    local -a lines=()
    _LONG_QUEUE_IDS_VALUE=""
    _new_private_tempdir || return 1
    output_file="$_NEW_TEMP_DIR/enable-long-queue-ids"
    if ! _run_without_mutation_lock_fd docker compose exec -T --user root postfix \
        postconf -h enable_long_queue_ids >"$output_file" 2>/dev/null; then
        return 1
    fi
    mapfile -t lines <"$output_file"
    (( ${#lines[@]} == 1 )) || return 1
    _LONG_QUEUE_IDS_VALUE=${lines[0]%$'\r'}
}

_long_queue_ids_remediation() {
    log_hint "Set POSTFIX_ENABLE_LONG_QUEUE_IDS=yes in the production environment."
    log_hint "Recreate/apply the Postfix service with the normal root-operated workflow: sudo make up"
    log_hint "Verify before retrying: sudo docker compose exec -T postfix postconf -h enable_long_queue_ids"
}

_require_long_queue_ids() {
    local operation="${1:-destructive queue operation}" value
    if ! _read_long_queue_ids; then
        log_error "Cannot safely perform $operation because the effective Postfix enable_long_queue_ids value could not be read."
        _long_queue_ids_remediation
        return 1
    fi
    value=$_LONG_QUEUE_IDS_VALUE
    if [[ "$value" != "yes" ]]; then
        log_error "Cannot safely perform $operation because Postfix enable_long_queue_ids is '$value', not 'yes'."
        _long_queue_ids_remediation
        return 1
    fi
    log_info "Postfix long queue IDs are enabled. Stable metadata comparison remains defence in depth."
}

_warn_long_queue_ids_for_retry() {
    local operation="${1:-queue retry}" value
    if ! _read_long_queue_ids; then
        log_warn "Could not verify Postfix enable_long_queue_ids before $operation. Retry may proceed, but destructive queue operations remain blocked."
        _long_queue_ids_remediation
        return 0
    fi
    value=$_LONG_QUEUE_IDS_VALUE
    if [[ "$value" != "yes" ]]; then
        log_warn "Postfix enable_long_queue_ids is '$value' before $operation. Retry may proceed, but destructive queue operations remain blocked."
        _long_queue_ids_remediation
    fi
}

_show_queue() {
    _run_without_mutation_lock_fd docker compose exec -T postfix postqueue -p
}

_capture_inventory() {
    local raw_file="$1" tsv_file="$2"
    _require_machine_inventory || return 1
    if ! _run_without_mutation_lock_fd docker compose exec -T postfix postqueue -j >"$raw_file"; then
        log_error "Unable to read the machine-readable Postfix queue inventory."
        return 1
    fi
    if ! python3 - "$raw_file" "$tsv_file" <<'PY_INVENTORY'
import base64
import hashlib
import json
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
records = {}
try:
    for number, raw in enumerate(src.read_text(encoding="utf-8").splitlines(), 1):
        if not raw.strip():
            continue
        item = json.loads(raw)
        if not isinstance(item, dict):
            raise ValueError(f"line {number} is not an object")
        queue_id = item.get("queue_id")
        if not isinstance(queue_id, str) or not queue_id:
            raise ValueError(f"line {number} has no queue_id")
        if any(ch in queue_id for ch in "\t\r\n\0"):
            raise ValueError(f"line {number} has an unsupported queue_id separator")

        queue_name = item.get("queue_name") or "unknown"
        sender = item.get("sender")
        if not isinstance(queue_name, str) or not isinstance(sender, str):
            raise ValueError(f"line {number} has invalid queue_name or sender")

        def clean(value):
            return " ".join(str(value).replace("\t", " ").splitlines())

        queue_name = clean(queue_name) or "unknown"
        sender = clean(sender)
        try:
            arrival = int(item.get("arrival_time"))
            size = int(item.get("message_size"))
        except (TypeError, ValueError) as exc:
            raise ValueError(f"line {number} has invalid numeric metadata") from exc
        if arrival < 0 or size < 0:
            raise ValueError(f"line {number} has negative numeric metadata")

        recipients = item.get("recipients")
        if not isinstance(recipients, list):
            raise ValueError(f"line {number} recipients is not a list")
        addresses = []
        reasons = []
        for recipient in recipients:
            if not isinstance(recipient, dict):
                raise ValueError(f"line {number} has a non-object recipient")
            address = recipient.get("address")
            if not isinstance(address, str):
                raise ValueError(f"line {number} recipient has no string address")
            addresses.append(clean(address))
            reason = recipient.get("delay_reason")
            if isinstance(reason, str) and reason.strip():
                reasons.append(" ".join(reason.split()))

        identity = {
            "arrival_time": arrival,
            "message_size": size,
            "sender": sender,
            "recipients": sorted(addresses),
        }
        canonical = json.dumps(
            identity, ensure_ascii=False, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
        digest = hashlib.sha256(canonical).hexdigest()
        encoded = base64.urlsafe_b64encode(canonical).decode("ascii")

        normalized_reasons = {clean(reason) for reason in reasons if clean(reason)}
        previous = records.get(queue_id)
        if previous is None:
            records[queue_id] = {
                "line": number,
                "queue_name": queue_name,
                "arrival": arrival,
                "size": size,
                "sender": sender,
                "digest": digest,
                "encoded": encoded,
                "reasons": normalized_reasons,
            }
            continue
        if previous["digest"] != digest:
            raise ValueError(
                f"queue_id {queue_id!r} has conflicting normalized identities "
                f"on lines {previous['line']} and {number}"
            )
        if queue_name == "hold" or previous["queue_name"] == "hold":
            previous["queue_name"] = "hold"
        else:
            previous["queue_name"] = min(previous["queue_name"], queue_name)
        previous["reasons"].update(normalized_reasons)
except Exception as exc:
    print(f"invalid postqueue -j inventory: {exc}", file=sys.stderr)
    raise SystemExit(1)
with dst.open("w", encoding="utf-8", newline="\n") as handle:
    for queue_id in sorted(records):
        record = records[queue_id]
        row = (
            queue_id,
            record["queue_name"],
            record["arrival"],
            record["size"],
            record["sender"],
            record["digest"],
            record["encoded"],
            " || ".join(sorted(record["reasons"])),
        )
        handle.write("\t".join(map(str, row)) + "\n")
PY_INVENTORY
    then
        log_error "Postfix returned malformed machine-readable queue data."
        log_hint "The human-readable status command remains available: sudo make email-queue"
        return 1
    fi
}

_queue_id_exists() {
    local queue_id="$1" tsv_file="$2" candidate _
    while IFS=$'\t' read -r candidate _; do
        if [[ "$candidate" == "$queue_id" ]]; then
            return 0
        fi
    done <"$tsv_file"
    return 1
}

_validate_queue_id() {
    local queue_id="$1" tsv_file="$2"
    if [[ -z "$queue_id" ]]; then
        log_error "QUEUE_ID must not be empty."
        return 2
    fi
    if ! _queue_id_exists "$queue_id" "$tsv_file"; then
        log_error "Queue ID not found in the current exact inventory: $queue_id"
        return 1
    fi
}

_print_metadata() {
    local queue_id="$1" tsv_file="$2"
    python3 - "$queue_id" "$tsv_file" <<'PY_METADATA'
import datetime as dt
import sys
from pathlib import Path

wanted, path = sys.argv[1], Path(sys.argv[2])
for line in path.read_text(encoding="utf-8").splitlines():
    fields = line.split("\t")
    if fields and fields[0] == wanted:
        queue, arrival, size, sender = fields[1], int(fields[2]), int(fields[3]), fields[4]
        reasons = fields[7].split(" || ") if len(fields) > 7 and fields[7] else []
        when = dt.datetime.fromtimestamp(arrival, dt.timezone.utc).isoformat() if arrival else "unknown"
        print(f"Queue ID: {wanted}")
        print(f"Queue: {queue}")
        print(f"Arrival: {when}")
        print(f"Size: {size} bytes")
        print(f"Sender: {sender or '(empty envelope sender)'}")
        if reasons:
            print("Delay reasons:")
            for reason in reasons:
                print(f"  - {reason}")
        else:
            print("Delay reasons: none recorded")
        raise SystemExit(0)
raise SystemExit(1)
PY_METADATA
}

_render_summary() {
    local mode="$1" tsv_file="$2"
    python3 - "$mode" "$tsv_file" <<'PY_SUMMARY'
import collections
import datetime as dt
import json
import sys
import time
from pathlib import Path

mode, path = sys.argv[1], Path(sys.argv[2])
rows = []
for raw in path.read_text(encoding="utf-8").splitlines():
    if not raw:
        continue
    fields = raw.split("\t")
    if len(fields) < 8:
        raise SystemExit("invalid normalized inventory")
    rows.append({
        "id": fields[0],
        "queue": fields[1],
        "arrival": int(fields[2]),
        "size": int(fields[3]),
        "reason": fields[7],
    })
count = len(rows)
total_bytes = sum(row["size"] for row in rows)
arrivals = [row["arrival"] for row in rows if row["arrival"] > 0]
oldest = min(arrivals) if arrivals else None
age = max(0, int(time.time()) - oldest) if oldest is not None else None
queues = collections.Counter(row["queue"] for row in rows)
reasons = collections.Counter()
for row in rows:
    for reason in filter(None, row["reason"].split(" || ")):
        reasons[reason] += 1
top_reason = None
if reasons:
    top_reason = sorted(reasons.items(), key=lambda pair: (-pair[1], pair[0]))[0][0]
obj = {
    "count": count,
    "total_bytes": total_bytes,
    "oldest_arrival_time": oldest,
    "oldest_age_seconds": age,
    "queues": dict(sorted(queues.items())),
    "top_delay_reason": top_reason,
}
if mode == "quiet":
    print(count)
elif mode == "json":
    print(json.dumps(obj, sort_keys=True, separators=(",", ":")))
elif mode == "text":
    def human_bytes(value):
        amount = float(value)
        units = ["B", "KiB", "MiB", "GiB", "TiB"]
        unit = units[0]
        for unit in units:
            if amount < 1024 or unit == units[-1]:
                break
            amount /= 1024
        return f"{int(amount)} {unit}" if unit == "B" else f"{amount:.1f} {unit}"
    def human_age(seconds):
        if seconds is None:
            return "n/a"
        days, rem = divmod(seconds, 86400)
        hours, rem = divmod(rem, 3600)
        minutes, secs = divmod(rem, 60)
        parts = []
        if days: parts.append(f"{days}d")
        if hours: parts.append(f"{hours}h")
        if minutes: parts.append(f"{minutes}m")
        if not parts: parts.append(f"{secs}s")
        return " ".join(parts)
    print(f"Total messages: {count}")
    print(f"Total size: {human_bytes(total_bytes)} ({total_bytes} bytes)")
    print(f"Oldest message age: {human_age(age)}")
    if queues:
        print("Queue states:")
        for name, value in sorted(queues.items()):
            print(f"  {name}: {value}")
    else:
        print("Queue states: none")
    print(f"Most frequent delay reason: {top_reason or 'none'}")
else:
    raise SystemExit("invalid summary mode")
PY_SUMMARY
}

_make_inventory() {
    local result_var="$1" dir raw inventory_tsv
    _new_private_tempdir || return 1
    dir="$_NEW_TEMP_DIR"
    raw="$dir/inventory.ndjson"
    inventory_tsv="$dir/inventory.tsv"
    _capture_inventory "$raw" "$inventory_tsv" || return 1
    printf -v "$result_var" '%s' "$inventory_tsv"
}

_summary() {
    local mode="text" tsv
    case "${1:-}" in
        "") ;;
        --quiet) mode="quiet" ;;
        --json) mode="json" ;;
        *) log_error "Unknown summary option: ${1:-}"; return 2 ;;
    esac
    [[ $# -le 1 ]] || { log_error "summary accepts at most one option."; return 2; }
    _make_inventory tsv || return 1
    _render_summary "$mode" "$tsv"
}

_confirm_exact() {
    local expected_token="$1" automation_value="$2" description="$3"
    local confirmation=""
    if [[ "${VW_EMAIL_QUEUE_CONFIRM:-}" == "$automation_value" ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        log_error "$description requires an interactive TTY or VW_EMAIL_QUEUE_CONFIRM=$automation_value."
        return 1
    fi
    printf 'Type %s to continue: ' "$expected_token"
    IFS= read -r confirmation || return 1
    if [[ "$confirmation" != "$expected_token" ]]; then
        log_warn "$description cancelled."
        return 1
    fi
}

_inspect() {
    local queue_id="$1" include_body="${2:-false}" tsv
    _make_inventory tsv || return 1
    _validate_queue_id "$queue_id" "$tsv" || return $?
    _print_metadata "$queue_id" "$tsv" || true
    if [[ "$include_body" == true ]]; then
        log_warn "Message bodies may contain credentials, reset links, or other sensitive content."
        if ! _run_without_mutation_lock_fd docker compose exec -T --user root postfix postcat -q "$queue_id"; then
            log_error "Queue ID disappeared or postcat could not inspect it: $queue_id"
            return 1
        fi
    else
        if ! _run_without_mutation_lock_fd docker compose exec -T --user root postfix postcat -q -e -h "$queue_id"; then
            log_error "Queue ID disappeared or postcat could not inspect it: $queue_id"
            return 1
        fi
    fi
}

_retry_one() {
    local queue_id="$1" tsv
    _warn_long_queue_ids_for_retry "targeted retry"
    _make_inventory tsv || return 1
    _validate_queue_id "$queue_id" "$tsv" || return $?
    _print_metadata "$queue_id" "$tsv" || true
    if _run_without_mutation_lock_fd docker compose exec -T --user root postfix postqueue -i "$queue_id"; then
        log_info "Immediate delivery was scheduled for queue ID $queue_id."
        return 0
    fi
    log_error "Queue ID disappeared or could not be scheduled for retry: $queue_id"
    return 1
}

_retry_all() {
    local tsv count
    _warn_long_queue_ids_for_retry "retry-all"
    _make_inventory tsv || return 1
    _render_summary text "$tsv"
    count=$(_render_summary quiet "$tsv") || return 1
    if [[ "$count" == 0 ]]; then
        return 0
    fi
    log_warn "Repeatedly flushing undeliverable mail can increase relay and delivery load."
    _confirm_exact "RETRY ALL" "retry-all" "Retry-all" || return 1
    if ! _run_without_mutation_lock_fd docker compose exec -T --user root postfix postqueue -f; then
        log_error "Postfix queue flush failed."
        return 1
    fi
    _summary
}

_selected_queue_name() {
    local queue_id="$1" tsv_file="$2"
    python3 - "$queue_id" "$tsv_file" <<'PY_SELECTED_QUEUE'
import sys
from pathlib import Path

wanted, path = sys.argv[1], Path(sys.argv[2])
for raw in path.read_text(encoding="utf-8").splitlines():
    fields = raw.split("\t")
    if fields and fields[0] == wanted:
        print(fields[1])
        raise SystemExit(0)
raise SystemExit(1)
PY_SELECTED_QUEUE
}

_classify_selected_identity() {
    local queue_id="$1" snapshot_tsv="$2" current_tsv="$3"
    python3 - "$queue_id" "$snapshot_tsv" "$current_tsv" <<'PY_SELECTED_IDENTITY'
import sys
from pathlib import Path

wanted = sys.argv[1]
snapshot_path, current_path = map(Path, sys.argv[2:])

def find(path):
    for raw in path.read_text(encoding="utf-8").splitlines():
        fields = raw.split("\t")
        if fields and fields[0] == wanted:
            if len(fields) < 8:
                raise SystemExit("invalid normalized inventory")
            return fields
    return None

snapshot = find(snapshot_path)
if snapshot is None:
    raise SystemExit("selected snapshot record is missing")
current = find(current_path)
if current is None:
    print("absent\t")
elif current[5] != snapshot[5]:
    print(f"mismatch\t{current[1]}")
elif current[1] == "hold":
    print("match-held\thold")
else:
    print(f"match-unheld\t{current[1]}")
PY_SELECTED_IDENTITY
}

_delete_one() {
    local queue_id="$1" delete_dir selected_ids
    local before_raw before_tsv after_hold_raw after_hold_tsv
    local after_delete_raw after_delete_tsv before_queue state_info state current_queue
    local hold_rc=0 delete_rc=0 release_rc=0

    _require_long_queue_ids "targeted deletion" || return 1
    _new_private_tempdir || return 1
    delete_dir="$_NEW_TEMP_DIR"
    selected_ids="$delete_dir/selected.ids"
    before_raw="$delete_dir/before.ndjson"
    before_tsv="$delete_dir/before.tsv"
    after_hold_raw="$delete_dir/after-hold.ndjson"
    after_hold_tsv="$delete_dir/after-hold.tsv"
    after_delete_raw="$delete_dir/after-delete.ndjson"
    after_delete_tsv="$delete_dir/after-delete.tsv"

    _capture_inventory "$before_raw" "$before_tsv" || return 1
    _validate_queue_id "$queue_id" "$before_tsv" || return $?
    _print_metadata "$queue_id" "$before_tsv" || true
    before_queue=$(_selected_queue_name "$queue_id" "$before_tsv") || return 1
    _confirm_exact "DELETE $queue_id" "delete:$queue_id" "Queue deletion" || return 1
    printf '%s\n' "$queue_id" >"$selected_ids"

    # The exact selected ID is held after confirmation, then compared with the
    # pre-confirmation identity. Holding closes the normal-delivery reuse window;
    # direct external Postfix administration remains outside the utility lock.
    if [[ "$before_queue" != "hold" ]]; then
        _HOLD_ROLLBACK_FILE="$selected_ids"
        _HOLD_ROLLBACK_ACTIVE=true
        _hold_ids "$selected_ids" || hold_rc=$?
    fi

    if ! _capture_inventory "$after_hold_raw" "$after_hold_tsv"; then
        log_error "Unable to verify the selected identity after the hold attempt."
        return 1
    fi
    state_info=$(_classify_selected_identity "$queue_id" "$before_tsv" "$after_hold_tsv") || return 1
    IFS=$'\t' read -r state current_queue <<<"$state_info"

    case "$state" in
        absent)
            _HOLD_ROLLBACK_ACTIVE=false
            log_warn "The selected original message is already absent: $queue_id"
            return 0
            ;;
        mismatch)
            if [[ "$before_queue" != "hold" && "$current_queue" == "hold" ]]; then
                _release_ids "$selected_ids" || release_rc=$?
                if (( release_rc == 0 )); then
                    _HOLD_ROLLBACK_ACTIVE=false
                else
                    log_warn "The reused queue ID could not be released immediately; cleanup will retry."
                fi
            else
                _HOLD_ROLLBACK_ACTIVE=false
            fi
            log_error "Queue ID $queue_id now refers to a different message; the replacement was not deleted."
            return 1
            ;;
        match-unheld)
            _HOLD_ROLLBACK_ACTIVE=false
            if (( hold_rc != 0 )); then
                log_error "Postfix could not place the matching message on hold: $queue_id"
            else
                log_error "The matching message is not in the hold queue; refusing deletion: $queue_id"
            fi
            return 1
            ;;
        match-held)
            if [[ "$before_queue" == "hold" ]]; then
                _HOLD_ROLLBACK_ACTIVE=false
            elif (( hold_rc != 0 )); then
                log_warn "The hold command reported failure, but the matching message is held; continuing with identity-safe deletion."
            fi
            ;;
        *)
            log_error "Unexpected selected-message classification: $state"
            return 1
            ;;
    esac

    _delete_ids "$selected_ids" || delete_rc=$?
    if ! _capture_inventory "$after_delete_raw" "$after_delete_tsv"; then
        log_error "Unable to verify targeted deletion; cleanup will release a newly introduced hold when possible."
        return 1
    fi
    state_info=$(_classify_selected_identity "$queue_id" "$before_tsv" "$after_delete_tsv") || return 1
    IFS=$'\t' read -r state current_queue <<<"$state_info"

    case "$state" in
        absent)
            _HOLD_ROLLBACK_ACTIVE=false
            if (( delete_rc == 0 )); then
                log_info "Deleted the identity-verified queue message: $queue_id"
            else
                log_warn "The selected original became absent while deletion completed: $queue_id"
            fi
            return 0
            ;;
        mismatch)
            # The original is gone and a replacement now owns the reused ID.
            # Disable ID-based rollback before returning; never mutate replacement mail.
            _HOLD_ROLLBACK_ACTIVE=false
            log_error "The original identity-verified message is gone, but queue ID $queue_id now belongs to a different message. The replacement was not held, released, retried, or deleted."
            return 1
            ;;
        match-held)
            if [[ "$before_queue" != "hold" ]]; then
                _release_ids "$selected_ids" || release_rc=$?
                if (( release_rc == 0 )); then
                    _HOLD_ROLLBACK_ACTIVE=false
                else
                    log_error "Failed to release the matching deletion survivor: $queue_id"
                fi
            else
                _HOLD_ROLLBACK_ACTIVE=false
            fi
            log_error "Failed to delete the identity-verified queue message: $queue_id"
            return 1
            ;;
        match-unheld)
            _HOLD_ROLLBACK_ACTIVE=false
            log_error "The matching message left the hold queue before deletion verification: $queue_id"
            return 1
            ;;
        *)
            log_error "Unexpected post-deletion classification: $state"
            return 1
            ;;
    esac
}

_hold_ids() {
    local ids_file="$1"
    [[ -s "$ids_file" ]] || return 0
    _run_without_mutation_lock_fd docker compose exec -T --user root postfix postsuper -h - <"$ids_file"
}

_release_ids() {
    local ids_file="$1"
    [[ -s "$ids_file" ]] || return 0
    _run_without_mutation_lock_fd docker compose exec -T --user root postfix postsuper -H - <"$ids_file"
}

_delete_ids() {
    local ids_file="$1"
    [[ -s "$ids_file" ]] || return 0
    _run_without_mutation_lock_fd docker compose exec -T --user root postfix postsuper -d - <"$ids_file"
}

_count_file_lines() {
    local file="$1"
    awk 'END { print NR + 0 }' "$file"
}

_prepare_snapshot_lists() {
    local snapshot_tsv="$1" to_hold_file="$2" preheld_file="$3"
    python3 - "$snapshot_tsv" "$to_hold_file" "$preheld_file" <<'PY_PREPARE'
import sys
from pathlib import Path

snapshot, to_hold, preheld = map(Path, sys.argv[1:])
hold_ids = []
preheld_ids = []
for raw in snapshot.read_text(encoding="utf-8").splitlines():
    if not raw:
        continue
    fields = raw.split("\t")
    if len(fields) < 8:
        raise SystemExit("invalid normalized snapshot")
    (preheld_ids if fields[1] == "hold" else hold_ids).append(fields[0])
to_hold.write_text("".join(f"{item}\n" for item in hold_ids), encoding="utf-8")
preheld.write_text("".join(f"{item}\n" for item in preheld_ids), encoding="utf-8")
PY_PREPARE
}

_classify_after_hold() {
    local snapshot_tsv="$1" current_tsv="$2" output_dir="$3"
    python3 - "$snapshot_tsv" "$current_tsv" "$output_dir" <<'PY_AFTER_HOLD'
import sys
from pathlib import Path

snapshot_path, current_path, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])

def load(path):
    result = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw:
            continue
        fields = raw.split("\t")
        if len(fields) < 8:
            raise SystemExit("invalid normalized inventory")
        result[fields[0]] = fields
    return result

snapshot = load(snapshot_path)
current = load(current_path)
files = {name: [] for name in (
    "eligible", "absent", "mismatch", "hold_failed", "release_mismatch",
    "newly_held"
)}
for queue_id, snap in snapshot.items():
    now = current.get(queue_id)
    if now is None:
        files["absent"].append(queue_id)
    elif now[5] != snap[5]:
        files["mismatch"].append(queue_id)
        if snap[1] != "hold" and now[1] == "hold":
            files["release_mismatch"].append(queue_id)
    elif now[1] == "hold":
        files["eligible"].append(queue_id)
        if snap[1] != "hold":
            files["newly_held"].append(queue_id)
    else:
        files["hold_failed"].append(queue_id)
for name, values in files.items():
    (out / f"{name}.ids").write_text(
        "".join(f"{item}\n" for item in values), encoding="utf-8"
    )
PY_AFTER_HOLD
}

_classify_after_delete() {
    local snapshot_tsv="$1" eligible_file="$2" current_tsv="$3" output_dir="$4"
    python3 - "$snapshot_tsv" "$eligible_file" "$current_tsv" "$output_dir" <<'PY_AFTER_DELETE'
import sys
from pathlib import Path

snapshot_path, eligible_path, current_path, out = map(Path, sys.argv[1:])
def load(path):
    result = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw:
            continue
        fields = raw.split("\t")
        if len(fields) < 8:
            raise SystemExit("invalid normalized inventory")
        result[fields[0]] = fields
    return result
snapshot = load(snapshot_path)
current = load(current_path)
eligible = [line for line in eligible_path.read_text(encoding="utf-8").splitlines() if line]
deleted = []
delete_failed = []
post_delete_mismatch = []
rollback = set()
for queue_id in eligible:
    snap = snapshot[queue_id]
    now = current.get(queue_id)
    if now is None:
        deleted.append(queue_id)
    elif now[5] != snap[5]:
        post_delete_mismatch.append(queue_id)
    else:
        delete_failed.append(queue_id)
        if snap[1] != "hold" and now[1] == "hold":
            rollback.add(queue_id)
(out / "deleted.ids").write_text("".join(f"{item}\n" for item in deleted), encoding="utf-8")
(out / "delete_failed.ids").write_text("".join(f"{item}\n" for item in delete_failed), encoding="utf-8")
(out / "post_delete_mismatch.ids").write_text(
    "".join(f"{item}\n" for item in post_delete_mismatch), encoding="utf-8"
)
(out / "rollback.ids").write_text("".join(f"{item}\n" for item in sorted(rollback)), encoding="utf-8")
PY_AFTER_DELETE
}

_count_held_ids() {
    local ids_file="$1" current_tsv="$2"
    python3 - "$ids_file" "$current_tsv" <<'PY_COUNT_HELD'
import sys
from pathlib import Path

ids_path, current_path = map(Path, sys.argv[1:])
wanted = set(ids_path.read_text(encoding="utf-8").splitlines())
held = 0
for raw in current_path.read_text(encoding="utf-8").splitlines():
    if not raw:
        continue
    fields = raw.split("\t")
    if fields[0] in wanted and fields[1] == "hold":
        held += 1
print(held)
PY_COUNT_HELD
}

_purge_snapshot() {
    local legacy_clear="${1:-false}" purge_dir snapshot_raw snapshot_tsv
    local after_hold_raw after_hold_tsv after_delete_raw after_delete_tsv
    local final_raw final_tsv to_hold preheld eligible absent_ids mismatch_ids
    local hold_failed_ids release_mismatch newly_held rollback_pending rollback_ids
    local post_delete_mismatch_ids
    local count to_hold_count preheld_count
    local deleted absent mismatches post_delete_mismatch hold_failed delete_failed restore_failed failed remaining
    local expected_token
    _require_long_queue_ids "snapshot purge" || return 1
    _new_private_tempdir || return 1
    purge_dir="$_NEW_TEMP_DIR"
    snapshot_raw="$purge_dir/snapshot.ndjson"
    snapshot_tsv="$purge_dir/snapshot.tsv"
    after_hold_raw="$purge_dir/after-hold.ndjson"
    after_hold_tsv="$purge_dir/after-hold.tsv"
    after_delete_raw="$purge_dir/after-delete.ndjson"
    after_delete_tsv="$purge_dir/after-delete.tsv"
    final_raw="$purge_dir/final.ndjson"
    final_tsv="$purge_dir/final.tsv"
    to_hold="$purge_dir/to-hold.ids"
    preheld="$purge_dir/preheld.ids"
    _capture_inventory "$snapshot_raw" "$snapshot_tsv" || return 1
    count=$(_render_summary quiet "$snapshot_tsv") || return 1
    _render_summary text "$snapshot_tsv"
    if [[ "$count" == 0 ]]; then
        return 0
    fi
    _prepare_snapshot_lists "$snapshot_tsv" "$to_hold" "$preheld" || return 1
    to_hold_count=$(_count_file_lines "$to_hold")
    preheld_count=$(_count_file_lines "$preheld")
    printf 'Snapshot messages: %d\nWill place on hold before identity verification: %d\nAlready held: %d\n' \
        "$count" "$to_hold_count" "$preheld_count"
    printf '%s\n' 'Only messages whose arrival time, size, sender, and recipients still match will be deleted.'
    expected_token="PURGE $count"
    if [[ "$legacy_clear" == true && "${VW_EMAIL_QUEUE_CLEAR_CONFIRMED:-}" == "1" ]]; then
        :
    else
        _confirm_exact "$expected_token" "purge-snapshot" "Snapshot purge" || return 1
    fi
    # The host lock serializes this utility. Holding prevents normal Postfix delivery
    # from removing a verified item between the post-hold inventory and batch delete.
    # Administrators invoking Postfix directly are outside this lock and must not
    # mutate the queue during the operation.
    _HOLD_ROLLBACK_FILE="$to_hold"
    _HOLD_ROLLBACK_ACTIVE=true
    _hold_ids "$to_hold" || log_warn "One or more snapshot IDs could not be placed on hold; identity verification will decide eligibility."
    if ! _capture_inventory "$after_hold_raw" "$after_hold_tsv"; then
        log_error "Unable to verify held snapshot identities; attempting to release IDs held by this operation."
        _release_ids "$to_hold" || true
        return 1
    fi
    _classify_after_hold "$snapshot_tsv" "$after_hold_tsv" "$purge_dir" || return 1
    eligible="$purge_dir/eligible.ids"
    absent_ids="$purge_dir/absent.ids"
    mismatch_ids="$purge_dir/mismatch.ids"
    hold_failed_ids="$purge_dir/hold_failed.ids"
    release_mismatch="$purge_dir/release_mismatch.ids"
    newly_held="$purge_dir/newly_held.ids"
    rollback_pending="$purge_dir/rollback-pending.ids"
    cat "$newly_held" "$release_mismatch" >"$rollback_pending"
    _HOLD_ROLLBACK_FILE="$rollback_pending"
    if [[ -s "$release_mismatch" ]]; then
        _release_ids "$release_mismatch" || log_warn "A mismatched held queue ID could not be released immediately; cleanup will retry."
    fi
    _delete_ids "$eligible" || log_warn "One or more verified held messages could not be deleted; survivors will be released when appropriate."
    if ! _capture_inventory "$after_delete_raw" "$after_delete_tsv"; then
        log_error "Unable to verify deletion results; cleanup will release newly held snapshot survivors."
        return 1
    fi
    _classify_after_delete "$snapshot_tsv" "$eligible" "$after_delete_tsv" "$purge_dir" || return 1
    post_delete_mismatch_ids="$purge_dir/post_delete_mismatch.ids"
    if [[ -s "$post_delete_mismatch_ids" ]]; then
        log_warn "Detected post-delete queue-ID reuse or identity mismatch; replacement messages were preserved unchanged."
    fi
    rollback_ids="$purge_dir/rollback.ids"
    _HOLD_ROLLBACK_FILE="$rollback_ids"
    if [[ -s "$rollback_ids" ]]; then
        _release_ids "$rollback_ids" || log_warn "One or more newly introduced holds could not be rolled back."
    fi
    _capture_inventory "$final_raw" "$final_tsv" || return 1
    _HOLD_ROLLBACK_ACTIVE=false
    deleted=$(_count_file_lines "$purge_dir/deleted.ids")
    absent=$(_count_file_lines "$absent_ids")
    mismatches=$(_count_file_lines "$mismatch_ids")
    post_delete_mismatch=$(_count_file_lines "$post_delete_mismatch_ids")
    mismatches=$((mismatches + post_delete_mismatch))
    hold_failed=$(_count_file_lines "$hold_failed_ids")
    delete_failed=$(_count_file_lines "$purge_dir/delete_failed.ids")
    restore_failed=$(_count_held_ids "$rollback_ids" "$final_tsv")
    failed=$((hold_failed + delete_failed + restore_failed))
    remaining=$(_render_summary quiet "$final_tsv") || return 1
    printf 'Deleted snapshot messages: %d\n' "$deleted"
    printf 'Already absent: %d\n' "$absent"
    printf 'Identity mismatches or reused IDs skipped: %d\n' "$mismatches"
    printf 'Failed operations: %d\n' "$failed"
    printf 'Messages currently remaining in queue: %d\n' "$remaining"
    (( mismatches == 0 && failed == 0 ))
}

_logs() {
    local queue_id="$1" tail_lines="$2" dir log_file tsv grep_rc=0
    _new_private_tempdir || return 1
    dir="$_NEW_TEMP_DIR"
    log_file="$dir/postfix.log"
    if [[ ! "$tail_lines" =~ ^[0-9]+$ ]] || (( tail_lines < 1 || tail_lines > 5000 )); then
        log_error "--tail must be a base-10 integer from 1 to 5000."
        return 2
    fi
    if [[ -n "$queue_id" ]]; then
        if _make_inventory tsv 2>/dev/null; then
            if ! _queue_id_exists "$queue_id" "$tsv"; then
                log_warn "Queue ID is not currently present; searching recent logs anyway: $queue_id"
            fi
        fi
    fi
    if ! _run_without_mutation_lock_fd docker compose logs --no-color --tail "$tail_lines" postfix >"$log_file"; then
        log_error "Unable to read Postfix logs."
        return 1
    fi
    if [[ -z "$queue_id" ]]; then
        cat "$log_file"
        return 0
    fi
    grep -F -- "$queue_id" "$log_file" || grep_rc=$?
    if (( grep_rc == 1 )); then
        log_info "No Postfix log lines matched queue ID $queue_id."
        return 0
    fi
    return "$grep_rc"
}

_usage_error() {
    log_error "$1"
    show_help
    return 2
}

main() {
    local command="${1:-status}" queue_id="" tail_lines=200 include_body=false
    local summary_mode="" retry_all=false option=""
    local -a original_args=("$@")

    case "$command" in
        --help|-h|help)
            if [[ $# -ne 1 ]]; then
                _usage_error "help does not accept operands." || return $?
            fi
            show_help
            return 0
            ;;
        status|summary|inspect|retry|delete|logs|purge|clear) ;;
        *) _usage_error "Unknown command: $command" || return $? ;;
    esac

    shift || true
    case "$command" in
        status)
            if [[ $# -ne 0 ]]; then
                _usage_error "status does not accept operands." || return $?
            fi
            ;;
        summary)
            if [[ $# -gt 1 ]]; then
                _usage_error "summary accepts at most one option." || return $?
            fi
            summary_mode="${1:-}"
            case "$summary_mode" in
                ""|--quiet|--json) ;;
                *) _usage_error "Unknown summary option: $summary_mode" || return $? ;;
            esac
            ;;
        inspect)
            if [[ $# -lt 1 || $# -gt 2 || "$1" == --* ]]; then
                _usage_error "inspect requires QUEUE_ID and optional --body." || return $?
            fi
            queue_id="$1"
            if [[ $# -eq 2 ]]; then
                if [[ "$2" != "--body" ]]; then
                    _usage_error "inspect accepts only the --body option." || return $?
                fi
                include_body=true
            fi
            ;;
        retry)
            if [[ $# -ne 1 ]]; then
                _usage_error "retry requires QUEUE_ID or --all." || return $?
            fi
            if [[ "$1" == "--all" ]]; then
                retry_all=true
            elif [[ "$1" == --* ]]; then
                _usage_error "Unknown retry option: $1" || return $?
            else
                queue_id="$1"
            fi
            ;;
        delete)
            if [[ $# -ne 1 || "$1" == --* ]]; then
                _usage_error "delete requires exactly one QUEUE_ID." || return $?
            fi
            queue_id="$1"
            ;;
        purge)
            if [[ $# -ne 1 || "$1" != "--snapshot" ]]; then
                _usage_error "purge requires exactly --snapshot." || return $?
            fi
            ;;
        clear)
            if [[ $# -ne 0 ]]; then
                _usage_error "clear does not accept operands." || return $?
            fi
            ;;
        logs)
            while [[ $# -gt 0 ]]; do
                option="$1"
                shift
                case "$option" in
                    --tail)
                        if [[ $# -eq 0 ]]; then
                            _usage_error "--tail requires a value." || return $?
                        fi
                        tail_lines="$1"
                        shift
                        ;;
                    --*) _usage_error "Unknown logs option: $option" || return $? ;;
                    *)
                        if [[ -n "$queue_id" ]]; then
                            _usage_error "logs accepts at most one QUEUE_ID." || return $?
                        fi
                        queue_id="$option"
                        ;;
                esac
            done
            if [[ ! "$tail_lines" =~ ^[0-9]+$ ]] || (( tail_lines < 1 || tail_lines > 5000 )); then
                _usage_error "--tail must be a base-10 integer from 1 to 5000." || return $?
            fi
            ;;
    esac

    if [[ "${VW_TEST_MODE:-0}" != "1" \
        || "${VAULTWARDEN_TEST_ALLOW_NON_ROOT:-0}" != "1" ]]; then
        require_root "${original_args[@]}" || return 1
    fi
    cd "$PROJECT_ROOT"
    require_docker || return 1
    _require_postfix_service || return 1
    case "$command" in
        retry|delete|purge|clear) _acquire_mutation_lock || return 1 ;;
    esac

    case "$command" in
        status) _show_queue ;;
        summary) _summary "$summary_mode" ;;
        inspect) _inspect "$queue_id" "$include_body" ;;
        retry)
            if [[ "$retry_all" == true ]]; then
                _retry_all
            else
                _retry_one "$queue_id"
            fi
            ;;
        delete) _delete_one "$queue_id" ;;
        purge) _purge_snapshot false ;;
        clear)
            log_warn "'clear' is deprecated; use 'purge --snapshot'."
            _purge_snapshot true
            ;;
        logs) _logs "$queue_id" "$tail_lines" ;;
    esac
}

main "$@"
