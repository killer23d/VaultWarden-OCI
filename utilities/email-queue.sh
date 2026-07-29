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
    delete ID               Delete one exact queue ID after exact confirmation.
    logs [ID] [--tail N]    Show Postfix logs, optionally filtered by a fixed
                            queue-ID string. N defaults to 200 and is limited to
                            1..5000.
    purge --snapshot        Capture the current queue IDs, confirm the captured
                            count, and delete only those IDs. Mail arriving after
                            the snapshot is never added to the deletion set.
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
    1  Operational failure, cancellation, or partial destructive failure.
    2  Invalid usage.

NOTES:
    Queue state can change between inventory, inspection, and mutation. A retry
    or Postfix acceptance does not prove final delivery to the recipient.
EOF
}

_cleanup_temp() {
    local path
    for path in "${_TEMP_PATHS[@]}"; do
        [[ -n "$path" ]] && rm -rf -- "$path"
    done
    return 0
}
trap _cleanup_temp EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

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

_require_postfix_service() {
    if ! docker compose ps --services --filter status=running 2>/dev/null \
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

_show_queue() {
    docker compose exec -T postfix postqueue -p
}

_capture_inventory() {
    local raw_file="$1" tsv_file="$2"
    _require_machine_inventory || return 1
    if ! docker compose exec -T postfix postqueue -j >"$raw_file"; then
        log_error "Unable to read the machine-readable Postfix queue inventory."
        return 1
    fi
    if ! python3 - "$raw_file" "$tsv_file" <<'PY_INVENTORY'
import json
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
rows = []
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
        arrival = item.get("arrival_time")
        size = item.get("message_size")
        sender = item.get("sender") or ""
        try:
            arrival = int(arrival) if arrival is not None else 0
            size = int(size) if size is not None else 0
        except (TypeError, ValueError) as exc:
            raise ValueError(f"line {number} has invalid numeric metadata") from exc
        reasons = []
        recipients = item.get("recipients") or []
        if not isinstance(recipients, list):
            raise ValueError(f"line {number} recipients is not a list")
        for recipient in recipients:
            if not isinstance(recipient, dict):
                continue
            reason = recipient.get("delay_reason")
            if isinstance(reason, str) and reason.strip():
                reasons.append(" ".join(reason.split()))
        def clean(value):
            return " ".join(str(value).replace("\t", " ").splitlines())
        rows.append((queue_id, clean(queue_name), arrival, size, clean(sender), " || ".join(reasons)))
except Exception as exc:
    print(f"invalid postqueue -j inventory: {exc}", file=sys.stderr)
    raise SystemExit(1)
with dst.open("w", encoding="utf-8", newline="\n") as handle:
    for row in rows:
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
        reasons = fields[5].split(" || ") if len(fields) > 5 and fields[5] else []
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
    if len(fields) < 6:
        raise SystemExit("invalid normalized inventory")
    rows.append({
        "id": fields[0],
        "queue": fields[1],
        "arrival": int(fields[2]),
        "size": int(fields[3]),
        "reason": fields[5],
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
        if ! docker compose exec -T --user root postfix postcat -q "$queue_id"; then
            log_error "Queue ID disappeared or postcat could not inspect it: $queue_id"
            return 1
        fi
    else
        if ! docker compose exec -T --user root postfix postcat -q -e -h "$queue_id"; then
            log_error "Queue ID disappeared or postcat could not inspect it: $queue_id"
            return 1
        fi
    fi
}

_retry_one() {
    local queue_id="$1" tsv
    _make_inventory tsv || return 1
    _validate_queue_id "$queue_id" "$tsv" || return $?
    _print_metadata "$queue_id" "$tsv" || true
    if docker compose exec -T --user root postfix postqueue -i "$queue_id"; then
        log_info "Immediate delivery was scheduled for queue ID $queue_id."
        return 0
    fi
    log_error "Queue ID disappeared or could not be scheduled for retry: $queue_id"
    return 1
}

_retry_all() {
    local tsv count
    _make_inventory tsv || return 1
    _render_summary text "$tsv"
    count=$(_render_summary quiet "$tsv") || return 1
    if [[ "$count" == 0 ]]; then
        return 0
    fi
    log_warn "Repeatedly flushing undeliverable mail can increase relay and delivery load."
    _confirm_exact "RETRY ALL" "retry-all" "Retry-all" || return 1
    if ! docker compose exec -T --user root postfix postqueue -f; then
        log_error "Postfix queue flush failed."
        return 1
    fi
    _summary
}

_delete_one() {
    local queue_id="$1" tsv after_tsv
    _make_inventory tsv || return 1
    _validate_queue_id "$queue_id" "$tsv" || return $?
    _print_metadata "$queue_id" "$tsv" || true
    _confirm_exact "DELETE $queue_id" "delete:$queue_id" "Queue deletion" || return 1
    if ! docker compose exec -T --user root postfix postsuper -d "$queue_id"; then
        _make_inventory after_tsv || return 1
        if ! _queue_id_exists "$queue_id" "$after_tsv"; then
            log_warn "Queue ID $queue_id was already absent before deletion completed."
            return 0
        fi
        log_error "Failed to delete queue ID $queue_id."
        return 1
    fi
    _make_inventory after_tsv || return 1
    if _queue_id_exists "$queue_id" "$after_tsv"; then
        log_error "Postfix reported success but queue ID is still present: $queue_id"
        return 1
    fi
    log_info "Deleted queue ID $queue_id."
}

_purge_snapshot() {
    local legacy_clear="${1:-false}" tsv count expected_token queue_id
    local snapshot_dir snapshot_ids before_tsv after_tsv remaining
    local deleted=0 absent=0 failed=0

    _make_inventory tsv || return 1
    count=$(_render_summary quiet "$tsv") || return 1
    _render_summary text "$tsv"
    if [[ "$count" == 0 ]]; then
        return 0
    fi

    _new_private_tempdir || return 1
    snapshot_dir="$_NEW_TEMP_DIR"
    snapshot_ids="$snapshot_dir/queue-ids"
    cut -f1 -- "$tsv" >"$snapshot_ids"

    expected_token="PURGE $count"
    if [[ "$legacy_clear" == true && "${VW_EMAIL_QUEUE_CLEAR_CONFIRMED:-}" == "1" ]]; then
        :
    else
        _confirm_exact "$expected_token" "purge-snapshot" "Snapshot purge" || return 1
    fi

    while IFS= read -r queue_id; do
        [[ -n "$queue_id" ]] || continue
        _make_inventory before_tsv || { failed=$((failed + 1)); continue; }
        if ! _queue_id_exists "$queue_id" "$before_tsv"; then
            absent=$((absent + 1))
            continue
        fi
        if docker compose exec -T --user root postfix postsuper -d "$queue_id"; then
            _make_inventory after_tsv || { failed=$((failed + 1)); continue; }
            if _queue_id_exists "$queue_id" "$after_tsv"; then
                failed=$((failed + 1))
            else
                deleted=$((deleted + 1))
            fi
        else
            _make_inventory after_tsv || { failed=$((failed + 1)); continue; }
            if _queue_id_exists "$queue_id" "$after_tsv"; then
                failed=$((failed + 1))
            else
                absent=$((absent + 1))
            fi
        fi
    done <"$snapshot_ids"

    _make_inventory after_tsv || return 1
    remaining=$(_render_summary quiet "$after_tsv") || return 1
    printf 'Deleted: %d\nAlready absent: %d\nFailed: %d\nNewly remaining queue count: %d\n' \
        "$deleted" "$absent" "$failed" "$remaining"
    (( failed == 0 ))
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
    if ! docker compose logs --no-color --tail "$tail_lines" postfix >"$log_file"; then
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
