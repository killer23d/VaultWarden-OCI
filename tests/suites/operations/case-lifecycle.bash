#!/usr/bin/env bash
# Consolidated lifecycle regression suite.
set -euo pipefail
MODE="${VW_TEST_CASE_MODE:-all}"
case "$MODE" in core|startup-hardening|all) ;; *) printf 'FAIL: unknown VW_TEST_CASE_MODE for case-lifecycle.bash: %s\n' "$MODE" >&2; exit 2 ;; esac

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

check_start_policy_contracts() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
fail(){ echo "FAIL: $*" >&2; exit 1; }
require(){ grep -Eq -- "$1" "$2" || fail "$3"; }
reject(){ ! grep -Eq -- "$1" "$2" || fail "$3"; }
extract_func(){
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
RESTORE="$ROOT/utilities/restore-run.sh"
MIGRATE="$ROOT/lib/migrate.sh"
SYSTEMD="$ROOT/utilities/setup-systemd.sh"
IPTABLES="$ROOT/systemd/vaultwarden-iptables.service"
DB_BACKUP_SERVICE="$ROOT/systemd/vaultwarden-db-backup.service"
FULL_BACKUP_SERVICE="$ROOT/systemd/vaultwarden-full-backup.service"
MAINT_SERVICE="$ROOT/systemd/vaultwarden-maintenance.service"
MAINT_RUN="$ROOT/utilities/maintenance-run.sh"

require '--start-policy MODE' "$RESTORE" 'restore help must document --start-policy'
require 'Start VaultWarden services now\? \[yes/no\] \(default: no\):' "$RESTORE" 'restore ask prompt missing'
require '--no-start' "$RESTORE" 'restore --no-start missing'
require '_restore_should_start_services' "$RESTORE" 'restore start-policy gate missing'
require 'START_POLICY:-auto.*auto|START_POLICY.*== "auto"' "$RESTORE" 'restore safety net must respect auto policy'
require 'Services may be stopped\. Review state before starting' "$RESTORE" 'restore manual recovery warning missing'
require 'sudo ./startup\.sh --skip-pull' "$RESTORE" 'restore manual checklist missing startup command'
require 'docker compose logs --tail=100' "$RESTORE" 'restore manual checklist missing log command'
require '--rotate-age-key' "$RESTORE" 'restore rotate-age-key flag missing'
require '--no-rotate-age-key' "$RESTORE" 'restore no-rotate-age-key flag missing'
require 'Emergency capsule contains operational key material\. Rotate Age key after restore\? \[yes/no\] \(default: yes\):' "$RESTORE" 'emergency key rotation prompt missing'
require 'Promoted encrypted SOPS secrets' "$RESTORE" 'restore must log promoted SOPS secrets'
require 'Skipped runtime decrypted secrets' "$RESTORE" 'restore must log skipped runtime secrets'
require 'Installed emergency /etc/vaultwarden material' "$RESTORE" 'restore must log emergency etc install'

require '--start-policy <mode>' "$MIGRATE" 'migrate help must document --start-policy'
require 'Start VaultWarden stack now on the migrated storage\? \[yes/no\] \(default: yes\):' "$MIGRATE" 'migrate ask prompt missing'
require '_MV_START_POLICY="manual"' "$MIGRATE" 'migrate no answer must convert to manual policy'
require 'skipping post-migration health check because services were not started' "$MIGRATE" 'migrate manual policy must skip healthcheck'

require '--no-enable-now' "$SYSTEMD" 'systemd help must document --no-enable-now'
require 'Non-interactive installs default to manual/install-only' "$SYSTEMD" 'systemd help must document safe non-interactive manual default'
require 'manual: install and enable timer units, but do not start them now' "$SYSTEMD" 'systemd help must define manual install-only behavior'
require 'auto:   enable and start timers now' "$SYSTEMD" 'systemd help must define auto enable/start behavior'
require 'enable timers without immediate execution' "$SYSTEMD" 'systemd help must document enable without immediate execution'
require 'Disaster-recovery/new-VM restores should avoid starting backup/maintenance' "$SYSTEMD" 'systemd help must document DR/new VM safety'
require 'START_POLICY="manual"' "$SYSTEMD" 'systemd non-interactive default must be manual'
require 'Enable and start backup/maintenance timers now\? \[yes/no\] \(default: no\):' "$SYSTEMD" 'systemd ask prompt missing'
require 'systemctl enable --now "\$timer"' "$SYSTEMD" 'systemd auto policy must preserve enable --now path'
require 'systemctl enable "\$timer"' "$SYSTEMD" 'systemd manual policy must enable without now'
require '_report_unhealthy_managed_timers\(\) \{' "$SYSTEMD" 'shared timer health diagnostic helper missing'
require '_list_unhealthy_managed_timers\(\) \{' "$SYSTEMD" 'unhealthy timer listing helper missing'
require 'UNHEALTHY TIMER:' "$SYSTEMD" 'timer diagnostics must print unhealthy timer names'
require 'systemctl is-active \${timer}' "$SYSTEMD" 'timer diagnostics must print is-active command'
require 'systemctl show \${timer} --property=NextElapseUSecRealtime --value' "$SYSTEMD" 'timer diagnostics must print next elapse command'
require 'systemctl status \"\$timer\" --no-pager -l' "$SYSTEMD" 'timer diagnostics must run detailed status command'
require '_report_unhealthy_managed_timers "Post-install timer health"' "$SYSTEMD" 'install must use shared timer diagnostic helper'
require '_report_unhealthy_managed_timers "Validation timer health"' "$SYSTEMD" 'validate must use shared timer diagnostic helper'
require 'Post-install timer health.*\|\| true' "$SYSTEMD" 'install must still print timer diagnostics before failing'
require 'return 1' "$SYSTEMD" 'auto enable-now timer failure must return non-zero'
require 'Install-only/manual state is not production-ready' "$SYSTEMD" 'manual systemd install must not claim production readiness'
require '_report_unhealthy_managed_timers "Validation timer health"' "$SYSTEMD" 'validate must report unhealthy timers'
require '\(\( errors\+\+ \)\)' "$SYSTEMD" 'validation timer health failure must increment errors'

TMP="$(mktemp -d)"
cleanup(){
  if [[ -d "$TMP" ]]; then
    if (( EUID == 0 )); then
      rm -rf "$TMP"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
      sudo -n rm -rf "$TMP"
    else
      rm -rf "$TMP"
    fi
  fi
}
trap cleanup EXIT

can_run_systemd_behavioral_tests(){
  [[ "$(uname -s)" == "Linux" ]] || return 1
  if (( EUID == 0 )); then
    return 0
  fi
  command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1
}

run_root_env_capture(){
  local out="$1"
  shift
  if (( EUID == 0 )); then
    env "$@" > "$out" 2>&1
  else
    # shellcheck disable=SC2024 # The output file is owned by the test runner, not the sudo command.
    sudo -n env "$@" > "$out" 2>&1
  fi
}

write_systemd_install_fakes(){
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
mode="${VW_TEST_SYSTEMCTL_MODE:-healthy}"
cmd="${1:-}"
case "$cmd" in
  is-enabled)
    exit 0
    ;;
  is-active)
    quiet=false
    unit="${2:-}"
    if [[ "$unit" == "--quiet" ]]; then
      quiet=true
      unit="${3:-}"
    fi
    if [[ "$mode" == "unhealthy" && "$unit" == "vaultwarden-maintenance.timer" ]]; then
      [[ "$quiet" == "true" ]] && exit 3
      printf 'inactive\n'
      exit 3
    fi
    [[ "$quiet" == "true" ]] && exit 0
    printf 'active\n'
    exit 0
    ;;
  show)
    if [[ "$mode" == "unhealthy" && "${2:-}" == "vaultwarden-db-backup.timer" ]]; then
      printf 'n/a\n'
    else
      printf 'Mon 2026-07-06 12:00:00 UTC\n'
    fi
    exit 0
    ;;
  status)
    printf 'mock status %s\n' "${2:-}"
    exit 0
    ;;
  enable|disable|daemon-reload|reset-failed|start|restart)
    printf 'systemctl %s\n' "$*" >> "${SYSTEMCTL_LOG:-/dev/null}"
    exit 0
    ;;
  *)
    printf 'systemctl %s\n' "$*" >> "${SYSTEMCTL_LOG:-/dev/null}"
    exit 0
    ;;
esac
SYSTEMCTL
  cat > "$bin/systemd-analyze" <<'SYSTEMD_ANALYZE'
#!/usr/bin/env bash
exit 0
SYSTEMD_ANALYZE
  cat > "$bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
exit 0
SLEEP
  cat > "$bin/getent" <<'GETENT'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  group:vaultwarden)
    printf 'vaultwarden:x:997:root,%s\n' "${VW_TEST_SERVICE_USER:-vwtest}"
    exit 0
    ;;
  passwd:*)
    user="${2:-${VW_TEST_SERVICE_USER:-vwtest}}"
    printf '%s:x:1000:1000:Test User:/home/%s:/bin/bash\n' "$user" "$user"
    exit 0
    ;;
esac
exec /usr/bin/getent "$@"
GETENT
  cat > "$bin/id" <<'ID'
#!/usr/bin/env bash
case "${1:-}" in
  -u) printf '0\n'; exit 0 ;;
  -un) printf 'root\n'; exit 0 ;;
  -g) printf '0\n'; exit 0 ;;
  -gn) printf '%s\n' "${2:-root}"; exit 0 ;;
  -nG) printf '%s vaultwarden\n' "${2:-root}"; exit 0 ;;
  root|"${VW_TEST_SERVICE_USER:-vwtest}") exit 0 ;;
esac
exec /usr/bin/id "$@"
ID
  cat > "$bin/groupadd" <<'GROUPADD'
#!/usr/bin/env bash
exit 0
GROUPADD
  cat > "$bin/usermod" <<'USERMOD'
#!/usr/bin/env bash
exit 0
USERMOD
  cat > "$bin/install" <<'INSTALL'
#!/usr/bin/env bash
set -euo pipefail
make_dirs=false
mode=""
pos=()
while (($#)); do
  case "$1" in
    -d) make_dirs=true ;;
    -m) mode="${2:-}"; shift ;;
    -o|-g) shift ;;
    --) ;;
    *) pos+=("$1") ;;
  esac
  shift || true
done
if [[ "$make_dirs" == "true" ]]; then
  for dest in "${pos[@]}"; do
    mkdir -p "$dest"
    [[ -n "$mode" ]] && /bin/chmod "$mode" "$dest"
  done
  exit 0
fi
if ((${#pos[@]} < 2)); then
  exit 1
fi
src="${pos[${#pos[@]}-2]}"
dest="${pos[${#pos[@]}-1]}"
if [[ "$dest" == /run/lock/* ]]; then
  mkdir -p "${VW_TEST_RUN_LOCK_DIR:?}"
  : > "${VW_TEST_RUN_LOCK_DIR}/$(basename "$dest")"
  [[ -n "$mode" ]] && /bin/chmod "$mode" "${VW_TEST_RUN_LOCK_DIR}/$(basename "$dest")"
  exit 0
fi
if [[ -d "$dest" ]]; then
  dest="$dest/$(basename "$src")"
fi
mkdir -p "$(dirname "$dest")"
/bin/cp "$src" "$dest"
[[ -n "$mode" ]] && /bin/chmod "$mode" "$dest"
INSTALL
  cat > "$bin/chown" <<'CHOWN'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ "$arg" == /run/lock/* ]] && exit 0
done
exec /usr/bin/chown "$@"
CHOWN
  cat > "$bin/chmod" <<'CHMOD'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ "$arg" == /run/lock/* ]] && exit 0
done
exec /bin/chmod "$@"
CHMOD
  chmod +x "$bin"/*
}

copy_systemd_install_repo(){
  local repo="$1" state="$2"
  mkdir -p "$repo" "$state/config"
  cp -a "$ROOT/lib" "$ROOT/utilities" "$ROOT/systemd" "$ROOT/caddy" "$repo/"
  cp "$ROOT/startup.sh" "$ROOT/maintenance.sh" "$ROOT/backup.sh" "$ROOT/restore.sh" \
     "$ROOT/docker-compose.yml.example" "$ROOT/secrets-schema.yaml" "$ROOT/VERSION" "$repo/"
  cp "$ROOT/docker-compose.yml.example" "$repo/docker-compose.yml"
  cat > "$repo/.env" <<EOF_ENV
DOMAIN=https://systemd-policy.example.test
ADMIN_EMAIL=admin@example.test
PROJECT_STATE_DIR=$state
DATA_VOLUME_DEVICE=
DATA_VOLUME_MOUNT=$state
SOPS_AGE_KEY_FILE=
EOF_ENV
  chmod 600 "$repo/.env"
  cat > "$state/config/install.env" <<EOF_RUNTIME
DOMAIN=https://systemd-policy.example.test
ADMIN_EMAIL=admin@example.test
PROJECT_STATE_DIR=$state
DATA_VOLUME_DEVICE=
DATA_VOLUME_MOUNT=$state
SOPS_AGE_KEY_FILE=/etc/vaultwarden/age-key.txt
EOF_RUNTIME
  chmod 600 "$state/config/install.env"
}

run_systemd_install_fixture(){
  local out="$1" repo="$2" bin="$3" unit_dir="$4" opt_dir="$5" env_dir="$6" state="$7" mode="$8"
  shift 8
  mkdir -p "$unit_dir" "$opt_dir" "$env_dir" "$state" "$TMP/run-locks"
  run_root_env_capture "$out" \
    PATH="$bin:$PATH" \
    SYSTEMCTL_LOG="$TMP/systemctl-install.log" \
    VW_TEST_RUN_LOCK_DIR="$TMP/run-locks" \
    VW_TEST_SERVICE_USER="vwtest" \
    SERVICE_USER="vwtest" \
    VW_TEST_SYSTEMCTL_MODE="$mode" \
    PROJECT_STATE_DIR="$state" \
    VW_CONFIG_INSTALLED_ENV_FILE="$env_dir/vaultwarden.env" \
    VW_SYSTEMD_UNIT_DEST_DIR="$unit_dir" \
    VW_SYSTEMD_OPT_SCRIPTS_DIR="$opt_dir" \
    VW_SYSTEMD_ENV_DIR="$env_dir" \
    VW_SYNC_ETC_DIR="$env_dir" \
    bash "$repo/utilities/setup-systemd.sh" install "$@"
}

test_systemd_install_timer_policy_behavior(){
  if ! can_run_systemd_behavioral_tests; then
    printf 'SKIP: systemd install behavioral test requires Linux root or passwordless sudo\n'
    return 0
  fi

  local bin="$TMP/install-bin" repo state unit_dir opt_dir env_dir out
  write_systemd_install_fakes "$bin"

  repo="$TMP/repo-auto"
  state="$TMP/state-auto"
  unit_dir="$TMP/units-auto"
  opt_dir="$TMP/opt-auto"
  env_dir="$TMP/etc-auto"
  copy_systemd_install_repo "$repo" "$state"
  out="$TMP/install-auto-unhealthy.out"
  ! run_systemd_install_fixture "$out" "$repo" "$bin" "$unit_dir" "$opt_dir" "$env_dir" "$state" unhealthy --enable-now \
    || { cat "$out" >&2; fail 'systemd install --enable-now succeeded with unhealthy timers'; }
  grep -Fq 'UNHEALTHY TIMER: vaultwarden-db-backup.timer' "$out" \
    || { cat "$out" >&2; fail 'auto install did not name no-next timer'; }
  grep -Fq 'systemctl show vaultwarden-db-backup.timer --property=NextElapseUSecRealtime --value' "$out" \
    || fail 'auto install did not print next-trigger diagnostic'
  grep -Fq 'UNHEALTHY TIMER: vaultwarden-maintenance.timer' "$out" \
    || { cat "$out" >&2; fail 'auto install did not name inactive timer'; }
  grep -Fq 'systemctl is-active vaultwarden-maintenance.timer' "$out" \
    || fail 'auto install did not print active-state diagnostic'

  repo="$TMP/repo-manual"
  state="$TMP/state-manual"
  unit_dir="$TMP/units-manual"
  opt_dir="$TMP/opt-manual"
  env_dir="$TMP/etc-manual"
  copy_systemd_install_repo "$repo" "$state"
  out="$TMP/install-manual.out"
  run_systemd_install_fixture "$out" "$repo" "$bin" "$unit_dir" "$opt_dir" "$env_dir" "$state" unhealthy --no-enable-now \
    || { cat "$out" >&2; fail 'systemd install --no-enable-now should succeed in manual state'; }
  grep -Fq 'Install-only/manual state is not production-ready' "$out" \
    || { cat "$out" >&2; fail 'manual install did not warn that state is not production-ready'; }
  grep -Fq 'Enabled: vaultwarden-db-backup.timer' "$out" \
    || fail 'manual install did not enable timer without starting it'
}

cat > "$TMP/timer-helper-probe.sh" <<EOF_PROBE
set -euo pipefail
TIMERS=(active-no-next.timer inactive.timer healthy.timer)
log_success(){ printf 'SUCCESS %s\n' "\$*"; }
log_warn(){ printf 'WARN %s\n' "\$*"; }
systemctl(){
  case "\${1:-}" in
    is-active)
      if [[ "\${2:-}" == "--quiet" ]]; then
        case "\${3:-}" in active-no-next.timer|healthy.timer) return 0 ;; *) return 3 ;; esac
      fi
      case "\${2:-}" in active-no-next.timer|healthy.timer) printf 'active\n'; return 0 ;; inactive.timer) printf 'inactive\n'; return 3 ;; esac
      ;;
    show)
      case "\${2:-}" in active-no-next.timer|inactive.timer) printf 'n/a\n' ;; healthy.timer) printf 'Mon 2026-07-06 12:00:00 UTC\n' ;; esac
      ;;
    status)
      printf 'mock status %s\n' "\${2:-}"
      ;;
  esac
}
$(extract_func "$SYSTEMD" _timer_has_next_trigger)
$(extract_func "$SYSTEMD" _timer_is_healthy)
$(extract_func "$SYSTEMD" _list_unhealthy_managed_timers)
$(extract_func "$SYSTEMD" _report_unhealthy_managed_timers)
_list_unhealthy_managed_timers > "$TMP/unhealthy.out"
_report_unhealthy_managed_timers "probe" > "$TMP/report.out" 2>&1 || true
EOF_PROBE
bash "$TMP/timer-helper-probe.sh" || fail 'timer helper probe failed'
grep -Fxq 'active-no-next.timer' "$TMP/unhealthy.out" || fail 'active timer with no next trigger not listed unhealthy'
grep -Fxq 'inactive.timer' "$TMP/unhealthy.out" || fail 'inactive timer not listed unhealthy'
! grep -Fxq 'healthy.timer' "$TMP/unhealthy.out" || fail 'healthy timer incorrectly listed unhealthy'
grep -Fq 'UNHEALTHY TIMER: active-no-next.timer' "$TMP/report.out" || fail 'diagnostic did not name no-next timer'
grep -Fq 'UNHEALTHY TIMER: inactive.timer' "$TMP/report.out" || fail 'diagnostic did not name inactive timer'

test_systemd_install_timer_policy_behavior

# Calendar timers must not also carry OnBootSec catch-up triggers. OnBootSec
# fires during systemctl enable --now on an already-booted host and can create
# install-time bursts.
for timer in "$ROOT"/systemd/vaultwarden-*.timer; do
    reject '^OnBootSec=' "$timer" "timer must not use OnBootSec: $timer"
    require '^OnCalendar=' "$timer" "timer must use predictable calendar scheduling: $timer"
    require '^Persistent=false$' "$timer" "timer must avoid persistent install/boot catch-up: $timer"
done

# StartLimit directives belong in [Unit], not [Service], on Ubuntu 24.04 Noble
# systemd. This catches the warning: Unknown key name 'StartLimitIntervalSec' in
# section 'Service'.
require '^StartLimitIntervalSec=60s$' "$IPTABLES" 'iptables service must set StartLimitIntervalSec'
require '^StartLimitBurst=3$' "$IPTABLES" 'iptables service must set StartLimitBurst'
awk '
    /^\[/ { section=$0 }
    /^StartLimit(IntervalSec|Burst)=/ && section != "[Unit]" { bad=1 }
    END { exit bad }
' "$IPTABLES" || fail 'iptables StartLimit directives must live in [Unit]'

# Backup service units must not check the stale maintenance lock filename. They
# should use the shared operations lock and treat scheduled contention as a clean
# skip without hiding real backup/rclone failures.
for svc in "$DB_BACKUP_SERVICE" "$FULL_BACKUP_SERVICE"; do
    reject 'vaultwarden-maintenance\.lock' "$svc" "backup service must not use stale maintenance lock: $svc"
    reject '/bin/bash -c .*flock|flock -n' "$svc" "backup service must not duplicate script-owned flock wrapper: $svc"
    reject '--skip-ops-lock' "$svc" "backup service must not pass public lock bypass flag: $svc"
    require 'backup\.sh run (db|full) --rclone --full-verification' "$svc" "backup service must delegate directly to backup.sh: $svc"
    require 'exits 75' "$svc" "backup service must document clean lock-contention skip: $svc"
    require '^SuccessExitStatus=0 75$' "$svc" "backup service must treat only success/skip as success: $svc"
    reject '^SuccessExitStatus=.* 2' "$svc" "backup service must not hide real rclone/backup failures as success: $svc"
done

reject '--skip-ops-lock' "$MAINT_RUN" 'maintenance runner must not expose public lock bypass flag'
reject 'SKIP_OPS_LOCK=true' "$MAINT_RUN" 'maintenance runner must not parse public lock bypass flag'
require 'vaultwarden-maintenance\.lock' "$MAINT_RUN" 'maintenance runner must keep canonical maintenance lock filename'
reject '/bin/bash -c .*flock|flock -n' "$MAINT_SERVICE" 'maintenance service must not duplicate script-owned flock wrapper'
reject '--skip-ops-lock' "$MAINT_SERVICE" 'maintenance service must not pass public lock bypass flag'
require '^ExecStart=/opt/vaultwarden-scripts/maintenance\.sh run --email$' "$MAINT_SERVICE" 'maintenance service must run routine maintenance directly'
reject '^ExecStart=.*--comprehensive' "$MAINT_SERVICE" 'scheduled maintenance must not duplicate dedicated DNS and firewall timers'
require 'exits[[:space:]]+75' "$MAINT_SERVICE" 'maintenance service must document clean lock-contention skip'
require '^SuccessExitStatus=75$' "$MAINT_SERVICE" 'maintenance service must treat lock-contention skip as success'

)

check_startup_lifecycle_guards() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require() {
  grep -Eq -- "$1" "$2" || fail "$3"
}

reject() {
  ! grep -Eq -- "$1" "$2" || fail "$3"
}

STARTUP="$ROOT/startup.sh"
SAFE_RESTART="$ROOT/utilities/safe-restart.sh"
MAKEFILE="$ROOT/Makefile"
STARTUP_UNIT="$ROOT/systemd/vaultwarden-startup.service"

require 'source "\$\{SCRIPT_DIR\}/lib/operations\.sh"' "$STARTUP" \
  "startup.sh must source the operation guard library"
require '--id startup' "$STARTUP" "startup.sh must use the startup operation id"
require '--specific-lock /run/lock/vaultwarden-startup\.lock' "$STARTUP" \
  "startup.sh must use the lifecycle-specific lock"

awk '
  /_startup_acquire_operation_guard/ { guard=NR }
  /if \[\[ "\$DO_DOWN" == "true" \]\]/ { stop=NR }
  END { exit !(guard && stop && guard < stop) }
' "$STARTUP" || fail "startup stop path must acquire guard before docker compose down"

awk '
  /^down: /,/^stop:/ { if (/\.\/startup\.sh stop/) found=1 }
  END { exit !found }
' "$MAKEFILE" || fail "make down must route through guarded startup.sh stop"

require 'source "\$\{PROJECT_ROOT\}/lib/operations\.sh"' "$SAFE_RESTART" \
  "safe-restart must source operation guards"
require '--id startup' "$SAFE_RESTART" "safe-restart must hold the lifecycle global operation"
require 'operation_set_phase "rollback"' "$SAFE_RESTART" \
  "safe-restart rollback must remain inside the operation scope"
reject '--specific-lock /run/lock/vaultwarden-startup\.lock' "$SAFE_RESTART" \
  "safe-restart parent must not hold the startup-specific lock before nested startup.sh"

require '^SuccessExitStatus=0 75$' "$STARTUP_UNIT" \
  "startup systemd unit must treat contention exit 75 as success"
require '^ReadWritePaths=.*@PROJECT_STATE_DIR@' "$STARTUP_UNIT" \
  "startup systemd unit must expose project state path"
require '^ReadWritePaths=.*/etc/vaultwarden' "$STARTUP_UNIT" \
  "startup systemd unit must expose runtime env path"
require '^ReadWritePaths=.*/run/lock' "$STARTUP_UNIT" \
  "startup systemd unit must expose operation lock path"
require '^ReadWritePaths=.*/run/vaultwarden-oci' "$STARTUP_UNIT" \
  "startup systemd unit must expose operation state path"
require '^RuntimeDirectory=vaultwarden-oci$' "$STARTUP_UNIT" \
  "startup systemd unit must pre-create /run/vaultwarden-oci"

printf 'PASS: startup lifecycle operation guards\n'

)

check_start_policy_argument_and_manual_restore_behavior() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
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

)


check_typed_lifecycle_health_results() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

extract_func(){
  local file="$1" func="$2"
  awk -v f="$func" '
    $0 ~ "^" f "\\(\\)" {p=1}
    p {
      print
      opens=gsub(/\{/ ,"{"); closes=gsub(/\}/,"}")
      depth += opens - closes
      if (depth == 0) exit
    }' "$file"
}

mkdir -p "$TMP/startup/utilities"
cat > "$TMP/startup/utilities/maintenance-health.sh" <<'MOCK_HEALTH'
#!/usr/bin/env bash
set -euo pipefail
count=$(cat "${HEALTH_COUNT_FILE}" 2>/dev/null || printf '0')
count=$((count + 1))
printf '%s\n' "$count" > "$HEALTH_COUNT_FILE"
IFS=',' read -r -a results <<< "${HEALTH_SEQUENCE:?}"
index=$((count - 1))
if (( index >= ${#results[@]} )); then index=$((${#results[@]} - 1)); fi
exit "${results[$index]}"
MOCK_HEALTH
chmod +x "$TMP/startup/utilities/maintenance-health.sh"

PROJECT_ROOT="$TMP/startup"
SKIP_HEALTH_CHECK=false
export PROJECT_ROOT SKIP_HEALTH_CHECK
log_info(){ printf 'INFO: %s\n' "$*"; }
log_warn(){ printf 'WARN: %s\n' "$*"; }
log_error(){ printf 'ERROR: %s\n' "$*"; }
log_success(){ printf 'SUCCESS: %s\n' "$*"; }
sleep(){ :; }
eval "$(extract_func "$ROOT/startup.sh" run_health_check)"

HEALTH_COUNT_FILE="$TMP/health-count"
HEALTH_SEQUENCE='75,0'
export HEALTH_COUNT_FILE HEALTH_SEQUENCE
: > "$HEALTH_COUNT_FILE"
run_health_check >"$TMP/startup-clears.out" 2>&1 \
    || { cat "$TMP/startup-clears.out" >&2; fail "startup health 75 -> 0 did not succeed"; }
[[ "$(cat "$HEALTH_COUNT_FILE")" == "2" ]] \
    || fail "startup did not retry health contention exactly once before success"
grep -Fq 'Health check passed — all checks healthy' "$TMP/startup-clears.out" \
    || fail "startup did not interpret the completed retry normally"

HEALTH_SEQUENCE='75,75,75'
export HEALTH_SEQUENCE
: > "$HEALTH_COUNT_FILE"
persistent_rc=0
run_health_check >"$TMP/startup-contended.out" 2>&1 || persistent_rc=$?
[[ "$persistent_rc" -eq 75 ]] \
    || fail "persistent startup health contention returned $persistent_rc instead of 75"
[[ "$(cat "$HEALTH_COUNT_FILE")" == "3" ]] \
    || fail "persistent startup contention did not stop after three bounded attempts"
grep -Fq 'Post-start health is unknown' "$TMP/startup-contended.out" \
    || fail "persistent startup contention did not report unknown health"
! grep -Fq 'CRITICAL failures' "$TMP/startup-contended.out" \
    || fail "persistent startup contention used critical executed-health wording"

mkdir -p "$TMP/safe/utilities"
PROJECT_ROOT="$TMP/safe"
eval "$(extract_func "$ROOT/utilities/safe-restart.sh" _safe_restart_rollback_result)"

write_rollback_health(){
    local status="$1"
    cat > "$TMP/safe/utilities/maintenance-health.sh" <<MOCK_ROLLBACK_HEALTH
#!/usr/bin/env bash
exit $status
MOCK_ROLLBACK_HEALTH
    chmod +x "$TMP/safe/utilities/maintenance-health.sh"
}

write_rollback_health 1
rollback_warning_rc=0
_safe_restart_rollback_result >"$TMP/rollback-warning.out" 2>&1 || rollback_warning_rc=$?
[[ "$rollback_warning_rc" -eq 1 ]] \
    || fail "rollback warning health returned $rollback_warning_rc instead of warning-level 1"
grep -Fq 'Rollback restored the previous stack with health warnings.' "$TMP/rollback-warning.out" \
    || fail "rollback warning result did not report restored-with-warnings state"
! grep -Eqi 'rollback was incomplete|manual recovery|required.*recovery' "$TMP/rollback-warning.out" \
    || fail "rollback health warning was misclassified as severe/manual recovery"

write_rollback_health 0
rollback_healthy_rc=0
_safe_restart_rollback_result >"$TMP/rollback-healthy.out" 2>&1 || rollback_healthy_rc=$?
[[ "$rollback_healthy_rc" -eq 1 ]] \
    || fail "healthy rollback must retain requested-restart failure status 1"
grep -Fq 'Rollback restored the previous stack and it is healthy.' "$TMP/rollback-healthy.out" \
    || fail "healthy rollback message does not match restored state"

write_rollback_health 75
rollback_unknown_rc=0
_safe_restart_rollback_result >"$TMP/rollback-unknown.out" 2>&1 || rollback_unknown_rc=$?
[[ "$rollback_unknown_rc" -eq 2 ]] \
    || fail "contended rollback health returned $rollback_unknown_rc instead of severe status 2"
grep -Fq 'Service health is unknown; manual verification and recovery are required.' "$TMP/rollback-unknown.out" \
    || fail "contended rollback health omitted manual recovery classification"

printf 'PASS: startup and safe-restart preserve typed health contention/warning results\n'
)


check_docker_lazy_project_label() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
DOCKER_LIB="$ROOT/lib/docker.sh"
TMP="$(mktemp -d -t vw-docker-label.XXXXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }

MOCK_BIN="$TMP/bin"
DOCKER_LOG="$TMP/docker.log"
JQ_LOG="$TMP/jq.log"
mkdir -p "$MOCK_BIN" "$TMP/outside"
cat >"$MOCK_BIN/docker" <<'EOF_DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${VW_TEST_DOCKER_LOG:?}"
case "$*" in
    'compose config --format json')
        [[ "${VW_TEST_COMPOSE_MODE:-success}" == success ]] || exit 1
        printf '{"name":"mock-project"}\n'
        ;;
    'container prune -f --filter label=com.docker.compose.project=mock-project')
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF_DOCKER
cat >"$MOCK_BIN/jq" <<'EOF_JQ'
#!/usr/bin/env bash
[[ -z "${VW_TEST_JQ_LOG:-}" ]] || printf '%s\n' "$*" >>"$VW_TEST_JQ_LOG"
input="$(cat)"
if [[ "$input" == *'"name":"mock-project"'* ]]; then
    printf 'mock-project\n'
fi
EOF_JQ
chmod +x "$MOCK_BIN/docker" "$MOCK_BIN/jq"

: >"$DOCKER_LOG"
set +e
source_output=$(cd "$TMP/outside" && \
    PATH="$MOCK_BIN:/usr/bin:/bin" VW_TEST_DOCKER_LOG="$DOCKER_LOG" \
    "$BASH" -c 'source "$1"' _ "$DOCKER_LIB" 2>&1)
source_rc=$?
set -e
[[ "$source_rc" -eq 0 ]] || fail "docker library source failed: $source_output"
[[ -z "$source_output" ]] || fail "docker library source produced output: $source_output"
[[ ! -s "$DOCKER_LOG" ]] || fail "docker library source invoked Docker: $(cat "$DOCKER_LOG")"
pass "sourcing docker helpers is quiet and performs no project inspection"

explicit_output=$(PATH="$MOCK_BIN:/usr/bin:/bin" \
    VW_TEST_DOCKER_LOG="$DOCKER_LOG" \
    DOCKER_PROJECT_LABEL='label=custom.project=explicit-value' \
    "$BASH" -c 'source "$1"; _docker_prune_filter' _ "$DOCKER_LIB")
[[ "$explicit_output" == $'--filter\nlabel=custom.project=explicit-value' ]] \
    || fail "explicit Docker project label changed: $explicit_output"
[[ ! -s "$DOCKER_LOG" ]] || fail "explicit Docker project label triggered resolution"
pass "explicit Docker project label is preserved exactly"

: >"$DOCKER_LOG"
: >"$JQ_LOG"
post_source_output=$(PATH="$MOCK_BIN:/usr/bin:/bin" \
    VW_TEST_DOCKER_LOG="$DOCKER_LOG" VW_TEST_JQ_LOG="$JQ_LOG" \
    "$BASH" -c '
        set -euo pipefail
        unset DOCKER_PROJECT_LABEL
        source "$1"
        DOCKER_PROJECT_LABEL="label=com.docker.compose.project=post-source-explicit"
        _docker_prune_filter
    ' _ "$DOCKER_LIB")
[[ "$post_source_output" == $'--filter\nlabel=com.docker.compose.project=post-source-explicit' ]] \
    || fail "post-source Docker project label changed: $post_source_output"
[[ ! -s "$DOCKER_LOG" ]] || fail "post-source Docker project label invoked Docker: $(cat "$DOCKER_LOG")"
[[ ! -s "$JQ_LOG" ]] || fail "post-source Docker project label invoked jq: $(cat "$JQ_LOG")"
pass "Docker project label assigned after sourcing is preserved without discovery"

: >"$DOCKER_LOG"
FILTER_OUTPUT="$TMP/filter.out"
PATH="$MOCK_BIN:/usr/bin:/bin" \
VW_TEST_DOCKER_LOG="$DOCKER_LOG" \
VW_TEST_FILTER_OUTPUT="$FILTER_OUTPUT" \
"$BASH" -c '
    set -euo pipefail
    source "$1"
    _docker_prune_filter >"$VW_TEST_FILTER_OUTPUT"
    _docker_prune_filter >>"$VW_TEST_FILTER_OUTPUT"
' _ "$DOCKER_LIB"
expected_filters=$'--filter\nlabel=com.docker.compose.project=mock-project\n--filter\nlabel=com.docker.compose.project=mock-project'
[[ "$(cat "$FILTER_OUTPUT")" == "$expected_filters" ]] \
    || fail "mock Compose name did not produce the full label filter: $(cat "$FILTER_OUTPUT")"
[[ "$(grep -c '^compose config --format json$' "$DOCKER_LOG")" -eq 1 ]] \
    || fail "repeated filter calls repeated project resolution: $(cat "$DOCKER_LOG")"
pass "Compose project name resolves lazily to one complete label per shell"

missing_docker_output=$("$BASH" -c '
    command(){
        if [[ "${1:-}" == -v && "${2:-}" == docker ]]; then return 1; fi
        builtin command "$@"
    }
    source "$1"
    _docker_prune_filter
' _ "$DOCKER_LIB")
[[ "$missing_docker_output" == $'--filter\nlabel=com.docker.compose.project=vaultwarden-oci' ]] \
    || fail "missing Docker did not use the default project label: $missing_docker_output"

: >"$DOCKER_LOG"
missing_jq_output=$(PATH="$MOCK_BIN:/usr/bin:/bin" VW_TEST_DOCKER_LOG="$DOCKER_LOG" \
    "$BASH" -c '
        command(){
            if [[ "${1:-}" == -v && "${2:-}" == jq ]]; then return 1; fi
            builtin command "$@"
        }
        source "$1"
        _docker_prune_filter
    ' _ "$DOCKER_LIB")
[[ "$missing_jq_output" == $'--filter\nlabel=com.docker.compose.project=vaultwarden-oci' ]] \
    || fail "missing jq did not use the default project label: $missing_jq_output"
[[ ! -s "$DOCKER_LOG" ]] || fail "missing jq still invoked Docker: $(cat "$DOCKER_LOG")"

: >"$DOCKER_LOG"
compose_failure_output=$(PATH="$MOCK_BIN:/usr/bin:/bin" \
    VW_TEST_DOCKER_LOG="$DOCKER_LOG" VW_TEST_COMPOSE_MODE=failure \
    "$BASH" -c 'source "$1"; _docker_prune_filter' _ "$DOCKER_LIB")
[[ "$compose_failure_output" == $'--filter\nlabel=com.docker.compose.project=vaultwarden-oci' ]] \
    || fail "Compose failure did not use the default project label: $compose_failure_output"
pass "missing Docker, jq, or Compose context uses the default label"

: >"$DOCKER_LOG"
PATH="$MOCK_BIN:/usr/bin:/bin" \
VW_TEST_DOCKER_LOG="$DOCKER_LOG" \
"$BASH" -c '
    set -euo pipefail
    source "$1"
    require_docker(){ return 0; }
    cleanup_containers
' _ "$DOCKER_LIB"
grep -Fxq 'container prune -f --filter label=com.docker.compose.project=mock-project' "$DOCKER_LOG" \
    || fail "container prune did not receive the resolved --filter argument: $(cat "$DOCKER_LOG")"
[[ "$(grep -c '^compose config --format json$' "$DOCKER_LOG")" -eq 1 ]] \
    || fail "cleanup consumer resolved the project more than once: $(cat "$DOCKER_LOG")"
pass "prune consumer receives the lazily resolved filter argument"
)

check_startup_lifecycle_hardening() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
fail() {
  printf 'FAIL startup lifecycle hardening: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$label"
}

startup=$(<"${ROOT}/startup.sh")

restart_block=$(awk '
  /^restart:/ { capture=1 }
  capture && /^safe-restart:/ { exit }
  capture { print }
' "${ROOT}/Makefile")

assert_contains "$restart_block" '$(call check-docker)' \
  "restart must verify Docker availability"
assert_contains "$restart_block" './startup.sh --force --skip-pull' \
  "restart must preserve the existing compatibility caller"
assert_not_contains "$restart_block" './startup.sh --force ||' \
  "restart must not use a distinct image-updating startup path"

assert_not_contains "$startup" 'docker compose rm -sf' \
  "startup must not remove working containers before Compose recreation"
assert_contains "$startup" 'compose_args+=(--force-recreate)' \
  "forced restart must still request Compose recreation"
assert_not_contains "$startup" 'wait_for_services || true' \
  "critical readiness failures must not be discarded"
assert_contains "$startup" 'wait_for_services || readiness_rc=$?' \
  "critical readiness result must be preserved"
assert_contains "$startup" 'wait_for_optional_service_health()' \
  "optional service health helper must exist"
assert_contains "$startup" 'wait_for_optional_services || true' \
  "Postfix readiness must receive a nonfatal grace period"

postfix_health=$(awk '
  /postfix status/ { capture=1; remaining=7 }
  capture && remaining > 0 { print; remaining-- }
' "${ROOT}/docker-compose.yml.example")
assert_contains "$postfix_health" 'interval: 15s' \
  "Postfix health interval must support startup readiness"
assert_contains "$postfix_health" 'timeout: 5s' \
  "Postfix health timeout must be bounded"
assert_contains "$postfix_health" 'retries: 4' \
  "Postfix health retries must be bounded"
assert_contains "$postfix_health" 'start_period: 20s' \
  "Postfix health start period must match the readiness grace window"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_marker_command() {
  local path="$1" marker="$2" rc="${3:-0}"
  cat > "$path" <<EOF_STUB
#!/usr/bin/env bash
printf '%s %s\\n' '$marker' "\$*" >> "\${CALL_LOG:?}"
exit $rc
EOF_STUB
  chmod +x "$path"
}

make_startup_fixture() {
  local repo="$1"
  mkdir -p "$repo/lib" "$repo/utilities" "$repo/state/config" "$repo/state/secrets"
  cp "$ROOT/startup.sh" "$repo/startup.sh"
  chmod +x "$repo/startup.sh"
  : > "$repo/docker-compose.yml"
  cat > "$repo/.env" <<EOF_ENV
PROJECT_STATE_DIR=$repo/state
PUID=1000
PGID=1000
SOPS_AGE_KEY_FILE=$repo/age-key.txt
EOF_ENV
  : > "$repo/age-key.txt"
  : > "$repo/secrets.yaml"

  cat > "$repo/lib/log.sh" <<'EOF_LIB'
log_info(){ printf 'INFO %s\n' "$*"; }
log_warn(){ printf 'WARN %s\n' "$*"; }
log_error(){ printf 'ERROR %s\n' "$*" >&2; }
log_success(){ printf 'OK %s\n' "$*"; }
EOF_LIB
  cat > "$repo/lib/defaults.sh" <<'EOF_LIB'
_VW_DEFAULT_REQUIRED_COMMANDS=()
_VW_DEFAULT_CRITICAL_SERVICES=()
_VW_DEFAULT_EMAIL_MODES=(auto api direct smtp host)
AGE_KEY_FILE=/etc/vaultwarden/age-key.txt
SECRETS_FILE=secrets.yaml
EOF_LIB
  cat > "$repo/lib/config.sh" <<'EOF_LIB'
load_project_environment(){
  PROJECT_STATE_DIR="$PWD/state"
  PUID=1000
  PGID=1000
  SOPS_AGE_KEY_FILE="$PWD/age-key.txt"
  SECRETS_FILE="$PWD/secrets.yaml"
  export PROJECT_STATE_DIR PUID PGID SOPS_AGE_KEY_FILE SECRETS_FILE
}
_read_env_value(){ printf ''; }
EOF_LIB
  cat > "$repo/lib/common.sh" <<'EOF_LIB'
init_common_lib(){ :; }
require_root(){ :; }
print_project_version(){ printf 'test\n'; }
_maybe_sudo(){ "$@"; }
EOF_LIB
  cat > "$repo/lib/docker.sh" <<'EOF_LIB'
check_docker_available(){ return 0; }
check_compose_available(){ return 0; }
wait_for_service_ready(){ return 0; }
cleanup_docker_system(){ printf 'CLEANUP_DOCKER\n' >> "${CALL_LOG:?}"; return 0; }
EOF_LIB
  cat > "$repo/lib/crypto.sh" <<'EOF_LIB'
check_age_key_health(){ return 0; }
EOF_LIB
  cat > "$repo/lib/secrets.sh" <<'EOF_LIB'
schema_validate(){ return 0; }
validate_required_secrets(){ return 0; }
export_docker_secrets(){ : > "${SECRET_MARKER:?}"; }
prepare_push_secret_placeholders(){ : > "${PUSH_MARKER:?}"; }
EOF_LIB
  cat > "$repo/lib/storage.sh" <<'EOF_LIB'
check_project_state_ready(){ return 0; }
EOF_LIB
  cat > "$repo/lib/runtime-permissions.sh" <<'EOF_LIB'
check_runtime_state_permissions(){ printf 'PERMISSION_CHECK %s\n' "$*" >> "${CALL_LOG:?}"; return "${PERMISSION_RC:-0}"; }
auto_fix_critical_permissions(){ printf 'PERMISSION_REPAIR\n' >> "${CALL_LOG:?}"; return 0; }
EOF_LIB
  cat > "$repo/lib/operations.sh" <<'EOF_LIB'
operation_acquire(){ return 0; }
operation_release(){ return 0; }
operation_set_phase(){ :; }
EOF_LIB

  make_marker_command "$repo/utilities/env-edit.sh" ENV_SYNC
  make_marker_command "$repo/utilities/maintenance-update-dns.sh" DNS_UPDATE
  make_marker_command "$repo/utilities/setup-firewall.sh" FIREWALL_SETUP
}

make_docker_stub() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/docker" <<'EOF_DOCKER'
#!/usr/bin/env bash
printf 'DOCKER %s\n' "$*" >> "${CALL_LOG:?}"
case "${1:-}:${2:-}:${3:-}" in
  compose:config:--images)
    printf 'example/vaultwarden:local\nexample/caddy:local\n'
    ;;
  image:inspect:*)
    [[ "${MISSING_IMAGE:-false}" != true ]]
    ;;
esac
EOF_DOCKER
  chmod +x "$bin/docker"
  make_marker_command "$bin/iptables" IPTABLES
  make_marker_command "$bin/groupadd" GROUPADD
  make_marker_command "$bin/getent" GETENT 1
}

run_startup() {
  local repo="$1" out="$2"
  shift 2
  (
    cd "$repo"
    PATH="$TMP/bin:$PATH" \
    CALL_LOG="$TMP/calls.log" \
    SECRET_MARKER="$TMP/secret-created" \
    PUSH_MARKER="$TMP/push-created" \
    "$repo/startup.sh" --background "$@"
  ) >"$out" 2>&1
}

repo="$TMP/repo"
make_startup_fixture "$repo"
make_docker_stub "$TMP/bin"
: > "$TMP/calls.log"
run_startup "$repo" "$TMP/success.out" || {
  cat "$TMP/success.out" >&2
  fail 'ordinary startup failed'
}

[[ -e "$TMP/secret-created" ]] || fail 'ordinary startup did not materialize encrypted secrets'
[[ -e "$TMP/push-created" ]] || fail 'ordinary startup did not materialize push placeholders'
grep -Fq 'PERMISSION_CHECK' "$TMP/calls.log" || fail 'ordinary startup did not validate permissions'
! grep -Fq 'PERMISSION_REPAIR' "$TMP/calls.log" || fail 'ordinary startup repaired permissions'
! grep -Eq '^(ENV_SYNC|DNS_UPDATE|FIREWALL_SETUP|CLEANUP_DOCKER|IPTABLES|GROUPADD|GETENT)( |$)' "$TMP/calls.log" \
  || fail 'ordinary startup invoked a prohibited maintenance or host-mutation path'
! grep -Eq 'DOCKER compose pull|DOCKER system prune|DOCKER .* prune|--remove-orphans' "$TMP/calls.log" \
  || fail 'ordinary startup pulled images or pruned Docker resources'
grep -Fq 'DOCKER compose up -d --pull never --no-build' "$TMP/calls.log" \
  || fail 'ordinary startup did not use no-pull/no-build Compose startup'

rm -f "$TMP/secret-created" "$TMP/push-created"
: > "$TMP/calls.log"
if PERMISSION_RC=1 run_startup "$repo" "$TMP/permissions.out"; then
  fail 'startup succeeded with invalid runtime permissions'
fi
grep -Fq 'sudo utilities/repair-permissions.sh' "$TMP/permissions.out" \
  || fail 'permission failure lacked the focused repair command'
[[ ! -e "$TMP/secret-created" && ! -e "$TMP/push-created" ]] \
  || fail 'startup materialized secrets after permission validation failed'
! grep -Fq 'DOCKER compose up' "$TMP/calls.log" \
  || fail 'startup attempted Compose up after permission validation failed'

: > "$TMP/calls.log"
if MISSING_IMAGE=true run_startup "$repo" "$TMP/missing-image.out"; then
  fail 'startup succeeded with a required local image missing'
fi
grep -Fq 'Required local image is missing:' "$TMP/missing-image.out" \
  || fail 'missing-image failure was not reported'
grep -Fq 'sudo ./maintenance.sh update --images' "$TMP/missing-image.out" \
  || fail 'missing-image failure lacked the focused image-maintenance command'
! grep -Fq 'DOCKER compose up' "$TMP/calls.log" \
  || fail 'startup attempted Compose up after image validation failed'

bash -n "${ROOT}/startup.sh" || fail "startup.sh must pass Bash syntax validation"

printf 'PASS startup lifecycle hardening contracts\n'
)

case "$MODE" in
    core)
        check_start_policy_contracts
        check_startup_lifecycle_guards
        check_start_policy_argument_and_manual_restore_behavior
        check_typed_lifecycle_health_results
        check_docker_lazy_project_label
        ;;
    startup-hardening)
        check_startup_lifecycle_hardening
        ;;
    all)
        check_start_policy_contracts
        check_startup_lifecycle_guards
        check_start_policy_argument_and_manual_restore_behavior
        check_typed_lifecycle_health_results
        check_docker_lazy_project_label
        check_startup_lifecycle_hardening
        ;;
    *)
        printf 'FAIL: unknown VW_TEST_CASE_MODE for case-lifecycle.bash: %s\n' "$MODE" >&2
        exit 2
        ;;
esac
