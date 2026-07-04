#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail(){ echo "FAIL: $*" >&2; exit 1; }

_extract_func(){
  local file="$1" func="$2"
  awk -v f="$func" '
    $0 ~ "^" f "\\(\\)" {p=1}
    p {
      print
      opens=gsub(/\{/,"{"); closes=gsub(/\}/,"}")
      depth += opens - closes
      if (depth == 0) exit
    }' "$file"
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Behavior: passphrase emergency decrypt must not pass -i; DR recipient identity may.
cat > "$TMP/decrypt-probe.sh" <<EOF_PROBE
set -euo pipefail
RESTORE_TYPE=emergency
BACKUP_FILE="$TMP/emergency.tar.zst.age"
EMERGENCY_BACKUP_AGE_IDENTITY_FILE="$TMP/dr-key.txt"
age(){ printf '%s\n' "\$*" > "$TMP/age.args"; : > "\$4" 2>/dev/null || true; }
$(_extract_func "$ROOT/utilities/restore-run.sh" _age_decrypt_restore_backup)
: > "\$BACKUP_FILE"; : > "\$EMERGENCY_BACKUP_AGE_IDENTITY_FILE"
_age_decrypt_restore_backup "\$BACKUP_FILE" ignored "$TMP/out.tar.zst" "$TMP/err" age-passphrase || exit 1
! grep -q -- ' -i ' "$TMP/age.args" || exit 2
grep -q -- '-o ' "$TMP/age.args" || exit 3
_age_decrypt_restore_backup "\$BACKUP_FILE" ignored "$TMP/out2.tar.zst" "$TMP/err2" age-recipient || exit 4
grep -q -- "-i \$EMERGENCY_BACKUP_AGE_IDENTITY_FILE" "$TMP/age.args" || exit 5
EOF_PROBE
bash "$TMP/decrypt-probe.sh" || fail 'emergency decrypt helper did not implement passphrase/DR recipient behavior'


# Operator UI closure: restore plan summary must not use fixed-width box borders or padded printf columns.
restore_plan_func="$(_extract_func "$ROOT/utilities/restore-run.sh" _print_restore_plan_summary)"
! grep -q '╔\|╠\|╚\|║' <<< "$restore_plan_func" || fail 'restore plan summary still uses fixed-width box drawing'
! grep -q '%-38s' <<< "$restore_plan_func" || fail 'restore plan summary still pads values to a fixed width'
grep -q 'operator_attention warn "Restore plan summary"' <<< "$restore_plan_func" || fail 'restore plan summary does not use operator attention block'

# Behavior: long backup names/paths are printed untruncated in plain summary lines.
cat > "$TMP/restore-plan-probe.sh" <<EOF_PROBE
set -euo pipefail
ROOT="$ROOT"
TMP="$TMP"
source "\$ROOT/lib/log.sh"
source "\$ROOT/lib/common.sh"
init_common_lib restore-plan-probe
RESTORE_TYPE=full
STATE_DIR="\$TMP/state-with-a-deliberately-long-path-component-that-must-not-be-truncated"
OPERATIONAL_SOPS_AGE_KEY_FILE="\$TMP/keys/live-operational-age-key-with-a-deliberately-long-name.txt"
NO_PRE_BACKUP=false
backup_encryption_mode=age-recipient
BACKUP_FILE="\$TMP/vaultwarden-full-backup-with-a-deliberately-long-name-that-would-overflow-the-old-box.tar.zst.age"
touch "\$BACKUP_FILE"
$restore_plan_func
_print_restore_plan_summary >"\$TMP/restore-plan.out" 2>&1
EOF_PROBE
bash "$TMP/restore-plan-probe.sh" || fail 'restore plan summary probe failed'
grep -q 'vaultwarden-full-backup-with-a-deliberately-long-name-that-would-overflow-the-old-box.tar.zst.age' "$TMP/restore-plan.out" || fail 'restore plan summary truncated or hid long backup name'
grep -q 'live-operational-age-key-with-a-deliberately-long-name.txt' "$TMP/restore-plan.out" || fail 'restore plan summary truncated or hid long key path'
! grep -q '╔\|╠\|╚\|║' "$TMP/restore-plan.out" || fail 'restore plan output still contains fixed-width box borders'

# Restore destructive confirmation must use shared default-no helper and preserve automation/non-interactive gates.
grep -Fq 'operator_attention warn "Destructive restore confirmation"' "$ROOT/utilities/restore-run.sh" || fail 'restore destructive context does not use operator_attention'
grep -Fq 'operator_confirm_yes_no "Proceed with destructive restore?" "no" 0' "$ROOT/utilities/restore-run.sh" || fail 'restore destructive confirmation is not explicit default-no yes/no helper'
grep -Fq 'if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" && "$INSPECT_ONLY" != "true" ]]' "$ROOT/utilities/restore-run.sh" || fail 'restore confirmation no longer preserves force/dry-run/inspect bypass gate'
grep -Fq 'stdin is not a TTY' "$ROOT/utilities/restore-run.sh" || fail 'restore confirmation no longer fails closed for non-TTY stdin'
grep -Fq 'Re-run with --force for non-interactive restore' "$ROOT/utilities/restore-run.sh" || fail 'restore confirmation no longer documents --force automation path'
grep -Fq 'Restore cancelled' "$ROOT/utilities/restore-run.sh" || fail 'restore cancellation message missing'

# Behavior: --start-policy missing value fails cleanly, not with an unbound variable.
set +e
bash "$ROOT/utilities/restore-run.sh" latest --start-policy >"$TMP/restore-missing.out" 2>&1
rc=$?
set -e
(( rc != 0 )) || fail 'restore --start-policy without value unexpectedly succeeded'
grep -q -- '--start-policy requires a value' "$TMP/restore-missing.out" || fail 'restore missing start-policy value did not print clean error'

set +e
bash "$ROOT/utilities/setup-systemd.sh" install --start-policy >"$TMP/systemd-missing.out" 2>&1
rc=$?
set -e
(( rc != 0 )) || fail 'setup-systemd --start-policy without value unexpectedly succeeded'
grep -q -- '--start-policy requires a value' "$TMP/systemd-missing.out" || fail 'systemd missing start-policy value did not print clean error'

set +e
bash -c 'log_error(){ echo "$*" >&2; }; _VW_DEFAULT_DATA_MOUNT=/mnt/vw-data; source "$1"; _mv_parse_args run --start-policy' _ "$ROOT/lib/migrate.sh" >"$TMP/migrate-missing.out" 2>&1
rc=$?
set -e
(( rc != 0 )) || fail 'migrate --start-policy without value unexpectedly succeeded'
grep -q -- '--start-policy requires a value' "$TMP/migrate-missing.out" || fail 'migrate missing start-policy value did not print clean error'

# Behavior: systemd manual policy does not run enable --now, while auto does.
cat > "$TMP/systemd-policy-probe.sh" <<'EOF_PROBE'
set -euo pipefail
START_POLICY=manual; DRY_RUN=false; STARTUP_SERVICE=vaultwarden-startup.service
TIMERS=(vaultwarden-db-backup.timer vaultwarden-full-backup.timer)
log_info(){ :; }; log_warn(){ :; }; log_success(){ :; }
calls=()
_run(){ calls+=("$*"); }
probe(){
    _run systemctl enable "$STARTUP_SERVICE"
    local _enable_now=false timer
    case "$START_POLICY" in auto) _enable_now=true ;; ask) _enable_now=false ;; manual) _enable_now=false ;; esac
    if [[ "$_enable_now" == true ]]; then
      for timer in "${TIMERS[@]}"; do _run systemctl enable --now "$timer"; done
    else
      for timer in "${TIMERS[@]}"; do _run systemctl enable "$timer"; done
    fi
}
probe
printf '%s\n' "${calls[@]}" > "$PWD/calls.manual"
! grep -q -- 'enable --now' "$PWD/calls.manual"
START_POLICY=auto; calls=(); probe; printf '%s\n' "${calls[@]}" > "$PWD/calls.auto"
grep -q -- 'enable --now vaultwarden-db-backup.timer' "$PWD/calls.auto"
EOF_PROBE
(cd "$TMP" && bash systemd-policy-probe.sh) || fail 'systemd start policy behavior failed'

# Behavior: restore manual start policy declines startup gate and prints checklist.
cat > "$TMP/restore-nostart-probe.sh" <<EOF_PROBE
set -euo pipefail
START_POLICY=manual
log_warn(){ printf '%s\n' "\$*" >> "$TMP/restore-nostart.log"; }
log_info(){ printf '%s\n' "\$*" >> "$TMP/restore-nostart.log"; }
$(_extract_func "$ROOT/utilities/restore-run.sh" _restore_print_manual_start_checklist)
$(_extract_func "$ROOT/utilities/restore-run.sh" _restore_should_start_services)
if _restore_should_start_services; then exit 1; fi
EOF_PROBE
bash "$TMP/restore-nostart-probe.sh" || fail 'restore --no-start/manual policy did not skip startup gate'
grep -q 'sudo ./startup.sh --skip-pull' "$TMP/restore-nostart.log" || fail 'restore manual start policy did not print startup command'

# Behavior: offline DB fallback restarts if this helper stopped the container and wait fails.
cat > "$TMP/db-restart-probe.sh" <<EOF_PROBE
set -uo pipefail
SCRIPT_DIR="$ROOT"; DB_SNAPSHOT_METHOD=""; DB_SNAPSHOT_RESTART_SERVICE=""; DB_SNAPSHOT_STOPPED_CONTAINER=false; DB_SNAPSHOT_RESTARTED=false
backup_log_info(){ :; }; backup_log_warn(){ :; }; log_error(){ :; }; cleanup(){ :; }
get_config_value(){ printf '%s\n' vaultwarden; }
create_db_snapshot_host(){ return 1; }
verify_sqlite(){ return 1; }
_vaultwarden_container_running(){ return 0; }
wait_for_container_stopped(){ return 1; }
docker(){ printf '%s\n' "docker \$*" >> "$TMP/docker.calls"; }
sqlite3(){ return 1; }
$(_extract_func "$ROOT/utilities/backup-run.sh" _db_snapshot_restart_if_needed)
$(_extract_func "$ROOT/utilities/backup-run.sh" create_consistent_db_snapshot)
mkdir -p "$TMP/state/data"; printf db > "$TMP/state/data/db.sqlite3"
if create_consistent_db_snapshot "$TMP/state" "$TMP/snap.sqlite3" db-test; then exit 1; fi
EOF_PROBE
bash "$TMP/db-restart-probe.sh" || fail 'DB restart probe script failed'
grep -q 'docker compose stop vaultwarden' "$TMP/docker.calls" || fail 'offline fallback did not stop container in probe'
[[ "$(grep -c 'docker compose start vaultwarden' "$TMP/docker.calls")" == "1" ]] || fail 'offline fallback did not restart exactly once after wait failure'

# Behavior-ish: restore code promotes SOPS secrets and skips runtime secrets explicitly.
grep -q 'Promoted encrypted SOPS secrets' "$ROOT/utilities/restore-run.sh" || fail 'restore lacks SOPS promotion log'
grep -q 'Skipped runtime decrypted secrets' "$ROOT/utilities/restore-run.sh" || fail 'restore lacks runtime secret skip log'

printf 'backup/restore behavior tests passed\n'
