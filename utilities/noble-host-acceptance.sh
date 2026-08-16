#!/usr/bin/env bash
# Real-host acceptance controller for Ubuntu 24.04 LTS Noble.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
STATE_ROOT="${VW_ACCEPTANCE_STATE_ROOT:-/var/tmp/vaultwarden-noble-acceptance}"
STATE_FILE="$STATE_ROOT/state"
LOG_DIR="$STATE_ROOT/logs"
PHASE=inventory
RECOVERY_KIT=""
RCLONE_REMOTE=""
RCLONE_CONFIG_PATH=""
APPLICATION_E2E=""
DESTRUCTIVE=false
SKIP_REBOOT=false

usage(){ cat <<'EOF'
VaultWarden-OCI Noble host acceptance

Usage:
  sudo utilities/noble-host-acceptance.sh run OPTIONS
  sudo utilities/noble-host-acceptance.sh resume OPTIONS
  sudo utilities/noble-host-acceptance.sh status

Required options:
  --recovery-kit FILE      External root-owned 0600 recovery kit
  --rclone-remote NAME     rclone remote containing acceptance backups
  --rclone-config FILE     External root-owned 0600 rclone.conf
  --application-e2e FILE   Root-owned executable application E2E hook

Full DR options:
  --destructive            Run same-host uninstall and full rclone restore
                           (also requires VW_NOBLE_TEST_DESTRUCTIVE=YES)
  --skip-reboot            Development-only; full certification requires reboot

The destructive DR phase is intentionally limited to boot-volume project state.
Attached-volume content is preserved by the canonical uninstaller, so this
controller fails closed instead of treating an attached-volume reset as clean DR.
EOF
}
log(){ printf '[acceptance] %s\n' "$*"; }
die(){ printf '[acceptance] ERROR: %s\n' "$*" >&2; exit 1; }
require_root(){ [[ $EUID -eq 0 ]] || die 'Run with sudo/root.'; }

read_env_value(){
  local key=$1 file=$2
  [[ -f "$file" ]] || return 0
  awk -F= -v k="$key" '$1==k{v=substr($0,index($0,"=")+1);gsub(/^["'"']|["'"']$/, "", v);x=v}END{if(x!="")print x}' "$file"
}

validate_host(){
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 && "${VERSION_CODENAME:-}" == noble ]] || die 'Ubuntu 24.04 LTS Noble is required.'
  case "$(dpkg --print-architecture)" in amd64|arm64) ;; *) die 'Only amd64 and arm64 are supported.';; esac
}

external_file(){
  local p owner mode
  p="$(realpath -e -- "$1")" || die "Cannot resolve $2"
  [[ -f "$p" && ! -L "$p" ]] || die "$2 must be a regular file"
  case "$p" in "$ROOT"|"$ROOT"/*|/etc/vaultwarden/*|/var/lib/vaultwarden/*|/mnt/vw-data/*|/run/vaultwarden-oci/*) die "$2 must survive uninstall and live outside managed paths";; esac
  owner="$(stat -c '%u:%g' "$p")"; mode="$(stat -c '%a' "$p")"
  [[ "$owner" == 0:0 && ( "$mode" == 600 || "$mode" == 400 ) ]] || die "$2 must be root:root mode 0600/0400"
  printf '%s\n' "$p"
}

validate_boot_volume(){
  local f device state
  for f in /etc/vaultwarden/vaultwarden.env "$ROOT/.env" /var/lib/vaultwarden/config/install.env /mnt/vw-data/config/install.env; do
    [[ -f "$f" ]] || continue
    device="$(read_env_value DATA_VOLUME_DEVICE "$f")"
    state="$(read_env_value PROJECT_STATE_DIR "$f")"
    [[ -z "$device" ]] || die "Destructive same-host DR refuses attached data volume: $device"
    [[ -z "$state" || "$state" != /mnt/vw-data* ]] || die "Destructive same-host DR refuses attached/ambiguous state: $state"
    return 0
  done
}

save_phase(){
  PHASE=$1
  install -d -m 0700 -o root -g root "$STATE_ROOT" "$LOG_DIR"
  printf '%s\n' "$PHASE" > "$STATE_FILE"
  chmod 0600 "$STATE_FILE"
}
load_phase(){ [[ -f "$STATE_FILE" ]] || die 'No checkpoint; use run first.'; PHASE="$(cat "$STATE_FILE")"; }

step(){
  local name=$1; shift
  log "START $name"
  "$@" > >(tee "$LOG_DIR/$name.log") 2> >(tee -a "$LOG_DIR/$name.log" >&2)
  log "PASS  $name"
}

systemd_jobs(){
  local u
  for u in vaultwarden-health.service vaultwarden-db-backup.service vaultwarden-full-backup.service vaultwarden-maintenance.service vaultwarden-dns-update.service vaultwarden-firewall-update.service; do
    systemctl start "$u"
    ! systemctl --quiet is-failed "$u" || return 1
  done
}

post_uninstall_check(){
  [[ ! -e /etc/vaultwarden ]] || return 1
  [[ ! -e /run/vaultwarden-oci ]] || return 1
  [[ ! -e /var/lib/vaultwarden ]] || return 1
  [[ ! -e "$ROOT/.env" ]] || return 1
  [[ -z "$(docker ps -aq --filter label=com.docker.compose.project=vaultwarden-oci 2>/dev/null)" ]] || return 1
}

parse(){
  while (($#)); do case "$1" in
    --recovery-kit) RECOVERY_KIT=${2:?}; shift 2;;
    --rclone-remote) RCLONE_REMOTE=${2:?}; shift 2;;
    --rclone-config) RCLONE_CONFIG_PATH=${2:?}; shift 2;;
    --application-e2e) APPLICATION_E2E=${2:?}; shift 2;;
    --destructive) DESTRUCTIVE=true; shift;;
    --skip-reboot) SKIP_REBOOT=true; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";;
  esac; done
}

validate_inputs(){
  [[ -n "$RECOVERY_KIT" && -n "$RCLONE_REMOTE" && -n "$RCLONE_CONFIG_PATH" && -n "$APPLICATION_E2E" ]] || die 'Recovery kit, rclone remote/config, and application E2E hook are required.'
  [[ "$RCLONE_REMOTE" =~ ^[A-Za-z0-9_-]+$ ]] || die 'Invalid rclone remote name.'
  RECOVERY_KIT="$(external_file "$RECOVERY_KIT" 'recovery kit')"
  RCLONE_CONFIG_PATH="$(external_file "$RCLONE_CONFIG_PATH" 'rclone config')"
  [[ -f "$APPLICATION_E2E" && ! -L "$APPLICATION_E2E" && -x "$APPLICATION_E2E" && "$(stat -c %u "$APPLICATION_E2E")" == 0 ]] || die 'Application E2E hook must be a root-owned executable regular file.'
  if [[ "$DESTRUCTIVE" == true ]]; then
    [[ "${VW_NOBLE_TEST_DESTRUCTIVE:-}" == YES ]] || die 'Set VW_NOBLE_TEST_DESTRUCTIVE=YES together with --destructive.'
    validate_boot_volume
  fi
}

run_phases(){
  while true; do case "$PHASE" in
    inventory)
      { date -u +%FT%TZ; git rev-parse HEAD; uname -a; cat /etc/os-release; dpkg --print-architecture; lsblk -f; docker version; docker compose version; } > "$LOG_DIR/inventory.log"
      save_phase contracts;;
    contracts)
      step contract-tests bash ./tests/run-tests.sh all; save_phase live;;
    live)
      step make-health make health
      step email-test bash ./maintenance.sh test-email --verbose
      step pre-production-drill bash ./utilities/pre-production-drill.sh
      step smoke-before-dr bash ./utilities/smoke-test.sh
      save_phase backups;;
    backups)
      step db-backup-rclone env RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_CONFIG="$RCLONE_CONFIG_PATH" bash ./backup.sh run db --rclone
      step full-backup-rclone env RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_CONFIG="$RCLONE_CONFIG_PATH" bash ./backup.sh run full --full-verification --rclone
      step backup-verify bash ./backup.sh verify
      step backup-sync env RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_CONFIG="$RCLONE_CONFIG_PATH" bash ./backup.sh sync
      step remote-list env RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_CONFIG="$RCLONE_CONFIG_PATH" bash ./restore.sh list --remote
      save_phase automation;;
    automation)
      step systemd-validate bash ./utilities/setup-systemd.sh validate
      step systemd-jobs systemd_jobs
      step docker-restart systemctl restart docker.service
      step smoke-after-docker-restart bash ./utilities/smoke-test.sh
      step application-before-dr "$APPLICATION_E2E"
      save_phase reboot;;
    reboot)
      if [[ "$SKIP_REBOOT" == true ]]; then save_phase post-reboot; else save_phase post-reboot; log 'Checkpoint saved. Reboot the host now, then rerun with resume.'; exit 75; fi;;
    post-reboot)
      step systemd-after-reboot bash ./utilities/setup-systemd.sh validate
      step smoke-after-reboot bash ./utilities/smoke-test.sh
      [[ "$DESTRUCTIVE" == true ]] && save_phase uninstall || save_phase incomplete;;
    uninstall)
      validate_boot_volume
      step uninstall-reset bash ./utilities/uninstall-vaultwarden.sh run --test-reset --i-have-saved-my-recovery-kit --force
      step uninstall-residuals post_uninstall_check
      save_phase restore;;
    restore)
      step remote-full-restore env RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_CONFIG="$RCLONE_CONFIG_PATH" bash ./restore.sh latest full --remote --from-recovery-kit "$RECOVERY_KIT" --no-backup --start-policy manual --force
      step repair-permissions bash ./utilities/repair-permissions.sh
      step startup bash ./startup.sh
      step systemd-reinstall bash ./utilities/setup-systemd.sh install --enable-now
      step systemd-after-restore bash ./utilities/setup-systemd.sh validate
      step smoke-after-restore bash ./utilities/smoke-test.sh
      step email-after-restore bash ./maintenance.sh test-email --verbose
      step application-after-dr "$APPLICATION_E2E"
      save_phase final-backup;;
    final-backup)
      step post-dr-db env RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_CONFIG="$RCLONE_CONFIG_PATH" bash ./backup.sh run db --rclone
      step post-dr-full env RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_CONFIG="$RCLONE_CONFIG_PATH" bash ./backup.sh run full --full-verification --rclone
      step post-dr-verify bash ./backup.sh verify
      save_phase complete;;
    complete)
      log "FULL ACCEPTANCE PASSED: $(git rev-parse HEAD)"; return 0;;
    incomplete)
      die 'Non-destructive run passed, but full certification requires --destructive and a reboot.';;
    *) die "Unknown phase: $PHASE";;
  esac; done
}

main(){
  case "${1:-}" in
    -h|--help|help) usage; exit 0;;
    status) require_root; [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo 'No checkpoint.'; exit 0;;
    run|resume) local action=$1; shift;;
    *) usage >&2; exit 2;;
  esac
  require_root; parse "$@"; validate_host; validate_inputs
  install -d -m 0700 -o root -g root "$STATE_ROOT" "$LOG_DIR"
  if [[ "$action" == run ]]; then [[ ! -e "$STATE_FILE" ]] || die 'Checkpoint exists; use resume.'; save_phase inventory; else load_phase; fi
  run_phases
}
main "$@"
