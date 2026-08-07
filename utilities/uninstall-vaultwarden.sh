#!/usr/bin/env bash
# VaultWarden-OCI host uninstaller.
# Remove positively owned project artifacts; preserve shared or ambiguous host state.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/lib/defaults.sh" ]] && source "$ROOT/lib/defaults.sh"
[[ -f "$ROOT/lib/log.sh" ]] && source "$ROOT/lib/log.sh"
[[ -f "$ROOT/lib/common.sh" ]] && { source "$ROOT/lib/common.sh"; init_common_lib "$0"; }
[[ -f "$ROOT/lib/operations.sh" ]] && source "$ROOT/lib/operations.sh"

info(){ if declare -f log_info >/dev/null; then log_info "$@"; else printf '[INFO] %s\n' "$*"; fi; }
warn(){ if declare -f log_warn >/dev/null; then log_warn "$@"; else printf '[WARN] %s\n' "$*" >&2; fi; }
ok(){ if declare -f log_success >/dev/null; then log_success "$@"; else printf '[OK] %s\n' "$*"; fi; }
die(){ if declare -f log_error >/dev/null; then log_error "$@"; else printf '[ERROR] %s\n' "$*" >&2; fi; exit 1; }
has(){ command -v "$1" >/dev/null 2>&1; }
uniq(){ awk 'NF && !seen[$0]++'; }

FORCE=false DRY_RUN=false TEST_RESET=false SAVED_RECOVERY=false OP_HELD=false
INSTALLED_ENV="${VW_UNINSTALL_INSTALLED_ENV:-/etc/vaultwarden/vaultwarden.env}"
DEFAULT_STATE="${_VW_DEFAULT_STATE_DIR:-/var/lib/vaultwarden}"
DEFAULT_DATA="${_VW_DEFAULT_DATA_MOUNT:-/mnt/vw-data}"
FSTAB="${VW_UNINSTALL_FSTAB:-/etc/fstab}"
SYSCTL="${VW_UNINSTALL_SYSCTL_CONF:-/etc/sysctl.conf}"
SYSTEMD="${VW_UNINSTALL_SYSTEMD_DIR:-/etc/systemd/system}"
RUNTIME="${VW_UNINSTALL_RUNTIME_DIR:-/run/vaultwarden-oci}"
RECOVERY_DIR="${VW_UNINSTALL_RECOVERY_DIR:-/root/vaultwarden-recovery}"
OPT_DIR="${VW_UNINSTALL_OPT_DIR:-/opt/vaultwarden-scripts}"
ETC_DIR="${VW_UNINSTALL_ETC_DIR:-/etc/vaultwarden}"
SWAPFILE="${VW_UNINSTALL_SWAPFILE:-/swapfile}"
UNIVERSE_SOURCE="${VW_UNINSTALL_UNIVERSE_SOURCE:-/etc/apt/sources.list.d/ubuntu-universe.list}"
MOUNT_GUARD="$SYSTEMD/docker.service.d/10-vaultwarden-data-volume.conf"
CS_DIR="${VW_UNINSTALL_CROWDSEC_DIR:-/etc/crowdsec}"
CS_EMAIL="$CS_DIR/notifications/vaultwarden-email.yaml"
CS_PROFILES="$CS_DIR/profiles.yaml.local"
CS_WORKER="$CS_DIR/bouncers/crowdsec-cloudflare-worker-bouncer.yaml"
CS_WORKER_UNIT="$SYSTEMD/crowdsec-cloudflare-worker-bouncer.service"
CS_EMAIL_MARKER="# Managed by VaultWarden-OCI: CrowdSec email notification"
CS_PROFILE_BEGIN="# BEGIN VaultWarden-OCI CrowdSec email notifications"
CS_PROFILE_END="# END VaultWarden-OCI CrowdSec email notifications"

TIMERS=(vaultwarden-maintenance.timer vaultwarden-db-backup.timer vaultwarden-full-backup.timer vaultwarden-health.timer vaultwarden-dns-update.timer vaultwarden-firewall-update.timer)
SERVICES=(vaultwarden-maintenance.service vaultwarden-db-backup.service vaultwarden-full-backup.service vaultwarden-health.service vaultwarden-dns-update.service vaultwarden-firewall-update.service vaultwarden-notify-failure.service vaultwarden-notify-failure@.service vaultwarden-iptables.service vaultwarden-startup.service)

help(){ cat <<'EOH'
VaultWarden-OCI Uninstall

Usage:
  sudo bash utilities/uninstall-vaultwarden.sh run [OPTIONS]
  bash utilities/uninstall-vaultwarden.sh help

Options:
  --dry-run
      Show the resolved uninstall scope without changing the host.
  --test-reset
      Dedicated test-VM reset. Preserves the Git checkout, but also removes the
      test VM's /swapfile, its fstab entry, the exact vm.swappiness=10 line, and
      the setup fallback universe source. Do not use this as a normal uninstall.
  --i-have-saved-my-recovery-kit
      Acknowledge that managed local Age keys and recovery handoffs may be deleted.
  --force
      Non-interactive mode. Skips confirmation and final-backup prompts. It never
      authorizes erasing separate block-storage contents or ambiguous shared state.
  --version, -V
      Print the project version.

Policy:
  Removes artifacts with positive VaultWarden-OCI ownership. Shared or ambiguous
  Docker, CrowdSec, firewall, OS identity, package, sysctl and backup state is
  preserved. Separate block-storage contents are never bulk-deleted; the verified
  volume is only detached from host boot wiring and unmounted.
EOH
}

[[ $# -gt 0 ]] || { help; exit 1; }
case "$1" in
  help|-h|--help) help; exit 0;;
  --version|-V) printf 'VaultWarden-OCI %s\n' "$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || echo unknown)"; exit 0;;
  run) shift;;
  *) die "Unknown subcommand: $1";;
esac
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=true;;
    --test-reset) TEST_RESET=true;;
    --i-have-saved-my-recovery-kit) SAVED_RECOVERY=true;;
    --force) FORCE=true; SAVED_RECOVERY=true;;
    --version|-V) printf 'VaultWarden-OCI %s\n' "$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || echo unknown)"; exit 0;;
    *) die "Unknown option: $1";;
  esac
  shift
done
[[ "$DRY_RUN" == true || $EUID -eq 0 ]] || die "Live uninstall requires root. Use --dry-run for preview."

read_env(){ local k=$1 f=$2; [[ -f "$f" ]] || return 0; awk -F= -v k="$k" '$1==k{v=substr($0,index($0,"=")+1);gsub(/^["'"'"']|["'"'"']$/,"",v);x=v} END{if(x!="")print x}' "$f" 2>/dev/null || true; }
canon(){ has realpath && realpath -m -- "$1" 2>/dev/null || readlink -m -- "$1" 2>/dev/null; }
inside(){ local c p; c="$(canon "$1")" || return 1; p="$(canon "$2")" || return 1; [[ "$c" == "$p" || "$c" == "$p"/* ]]; }
same_path(){ local a b; [[ "$1" == "$2" ]] && return 0; a="$(canon "$1")" || return 1; b="$(canon "$2")" || return 1; [[ "$a" == "$b" ]]; }

candidates(){
  local f s m

  # /etc/vaultwarden/vaultwarden.env is the installed runtime authority. Do not
  # let a more-populated but stale repo .env outrank it during destructive work.
  if [[ -f "$INSTALLED_ENV" ]]; then
    printf '%s\n' "$INSTALLED_ENV"
    return 0
  fi

  # If the installed copy is already gone, prefer a persistent install.env
  # referenced by the checkout before falling back to defaults or repo .env.
  if [[ -f "$ROOT/.env" ]]; then
    s="$(read_env PROJECT_STATE_DIR "$ROOT/.env")"
    m="$(read_env DATA_VOLUME_MOUNT "$ROOT/.env")"
    [[ -n "$s" && -f "$s/config/install.env" ]] && printf '%s\n' "$s/config/install.env"
    [[ -n "$m" && "$m" != "$s" && -f "$m/config/install.env" ]] && printf '%s\n' "$m/config/install.env"
  fi

  for f in "$DEFAULT_STATE/config/install.env" "$DEFAULT_DATA/config/install.env"; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done
  [[ -f "$ROOT/.env" ]] && printf '%s\n' "$ROOT/.env"
}

resolve(){
  local p f
  if [[ -L "$INSTALLED_ENV" || ( -e "$INSTALLED_ENV" && ! -f "$INSTALLED_ENV" ) ]]; then
    die "Authoritative installed environment is not a regular file: $INSTALLED_ENV"
  fi
  if [[ -e "$INSTALLED_ENV" && ! -r "$INSTALLED_ENV" ]]; then
    die "Cannot read authoritative installed environment: $INSTALLED_ENV. Re-run the dry-run with sudo for an accurate uninstall scope."
  fi
  CONFIG_SOURCE=""
  while IFS= read -r f; do
    [[ -r "$f" ]] || die "Cannot read uninstall configuration candidate: $f. Re-run with sudo for an accurate scope."
    CONFIG_SOURCE="$f"
    break
  done < <(candidates | uniq)
  PROJECT_STATE_DIR="$(read_env PROJECT_STATE_DIR "$CONFIG_SOURCE")"
  DATA_VOLUME_MOUNT="$(read_env DATA_VOLUME_MOUNT "$CONFIG_SOURCE")"
  DATA_VOLUME_DEVICE="$(read_env DATA_VOLUME_DEVICE "$CONFIG_SOURCE")"
  BACKUP_DIR="$(read_env BACKUP_DIR "$CONFIG_SOURCE")"
  COMPOSE_PROJECT="$(read_env COMPOSE_PROJECT_NAME "$CONFIG_SOURCE")"
  DOMAIN_NAME="$(read_env DOMAIN_NAME "$CONFIG_SOURCE")"
  [[ -n "$DOMAIN_NAME" ]] || { DOMAIN_NAME="$(read_env DOMAIN "$CONFIG_SOURCE")"; DOMAIN_NAME="${DOMAIN_NAME#https://}"; DOMAIN_NAME="${DOMAIN_NAME#http://}"; DOMAIN_NAME="${DOMAIN_NAME%%/*}"; }
  [[ -n "$PROJECT_STATE_DIR" || -z "$DATA_VOLUME_MOUNT" ]] || PROJECT_STATE_DIR=$DATA_VOLUME_MOUNT
  PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-$DEFAULT_STATE}"
  BACKUP_DIR="${BACKUP_DIR:-$PROJECT_STATE_DIR/backups}"
  COMPOSE_PROJECT="${COMPOSE_PROJECT:-vaultwarden-oci}"

  if [[ -z "$DATA_VOLUME_DEVICE" && "$PROJECT_STATE_DIR" == /* ]] && mountpoint -q "$PROJECT_STATE_DIR" 2>/dev/null \
     && [[ -f "$PROJECT_STATE_DIR/.vw-data-volume" && ! -L "$PROJECT_STATE_DIR/.vw-data-volume" ]] \
     && [[ "$(head -1 "$PROJECT_STATE_DIR/.vw-data-volume" 2>/dev/null)" == 'VaultWarden-OCI data volume' ]]; then
    DATA_VOLUME_MOUNT=$PROJECT_STATE_DIR
    DATA_VOLUME_DEVICE="$(findmnt -n -o SOURCE --target "$PROJECT_STATE_DIR" 2>/dev/null || true)"
    [[ -n "$DATA_VOLUME_DEVICE" ]] || die "Mounted VaultWarden data volume found but source device cannot be resolved."
    warn "Recovered separate-volume source from the mounted VaultWarden sentinel."
  fi

  AGE_KEYS=()
  for p in "$(read_env SOPS_AGE_KEY_FILE "$CONFIG_SOURCE")" "$(read_env AGE_KEY_FILE "$CONFIG_SOURCE")" "$ETC_DIR/age-key.txt" "$ROOT/secrets/keys/age-key.txt"; do
    [[ -n "$p" ]] || continue; [[ "$p" == /* ]] || p="$ROOT/$p"; AGE_KEYS+=("$p")
  done
  mapfile -t AGE_KEYS < <(printf '%s\n' "${AGE_KEYS[@]}" | uniq)
}

uuid(){ has blkid && blkid -o value -s UUID "$1" 2>/dev/null | head -1; }
same_dev(){ local a=$1 b=$2 ra rb ua ub; [[ -n "$a" && -n "$b" ]] || return 1; [[ "$a" == "$b" ]] && return 0; ra="$(readlink -f -- "$a" 2>/dev/null || true)"; rb="$(readlink -f -- "$b" 2>/dev/null || true)"; [[ -n "$ra" && "$ra" == "$rb" ]] && return 0; ua="$(uuid "$a")"; ub="$(uuid "$b")"; [[ -n "$ua" && "$ua" == "$ub" ]]; }
sentinel_value(){ awk -F: -v k="$1" '$1==k{v=substr($0,index($0,":")+1);sub(/^[[:space:]]+/,"",v);print v;exit}' "$2" 2>/dev/null; }
verify_volume(){
  local s="$DATA_VOLUME_MOUNT/.vw-data-volume" src sm sd
  [[ -f "$s" && ! -L "$s" && "$(head -1 "$s" 2>/dev/null)" == 'VaultWarden-OCI data volume' ]] || return 1
  src="$(findmnt -n -o SOURCE --target "$DATA_VOLUME_MOUNT" 2>/dev/null || true)"; same_dev "$DATA_VOLUME_DEVICE" "$src" || return 1
  sm="$(sentinel_value Mounted "$s")"; [[ -z "$sm" ]] || same_path "$sm" "$DATA_VOLUME_MOUNT" || return 1
  sd="$(sentinel_value Device "$s")"; [[ -z "$sd" || ! -e "$sd" ]] || same_dev "$sd" "$src" || return 1
}

fstab_count(){ awk -v mp="$1" '!/^[[:space:]]*($|#)/&&$2==mp{n++}END{print n+0}' "$FSTAB" 2>/dev/null; }
fstab_match(){ local mp=$1 src=$2 id=$3; awk -v mp="$mp" -v src="$src" -v id="$id" '!/^[[:space:]]*($|#)/&&$2==mp&&((src!=""&&$1==src)||(id!=""&&$1=="UUID="id)){f=1}END{exit !f}' "$FSTAB"; }
fstab_foreign_same_mount(){ local mp=$1 src=$2 id=$3; awk -v mp="$mp" -v src="$src" -v id="$id" '!/^[[:space:]]*($|#)/&&$2==mp&&!((src!=""&&$1==src)||(id!=""&&$1=="UUID="id)){f=1}END{exit !f}' "$FSTAB"; }
fstab_source_elsewhere(){ local mp=$1 src=$2 id=$3; awk -v mp="$mp" -v src="$src" -v id="$id" '!/^[[:space:]]*($|#)/&&$2!=mp&&((src!=""&&$1==src)||(id!=""&&$1=="UUID="id)){f=1}END{exit !f}' "$FSTAB"; }
fstab_setup_signature(){ awk -v mp="$1" '!/^[[:space:]]*($|#)/{count[$1]++;if($2==mp&&$1~/^UUID=/&&($3=="ext4"||$3=="xfs")){a=b=c=0;n=split($4,o,",");for(i=1;i<=n;i++){if(o[i]=="noatime")a=1;if(o[i]=="nofail")b=1;if(o[i]=="x-systemd.device-timeout=30s")c=1}if(a&&b&&c){managed=$1;hits++}}}END{exit(hits==1&&count[managed]==1?0:1)}' "$FSTAB"; }
rewrite(){ local f=$1 awkprog=$2; shift 2; [[ -f "$f" && ! -L "$f" ]] || return 1; local t; t="$(mktemp "$f.vw.XXXXXXXX")" || return 1; if awk "$@" "$awkprog" "$f" > "$t" && chmod --reference="$f" "$t" && chown --reference="$f" "$t" && mv -f "$t" "$f"; then return 0; fi; rm -f "$t"; return 1; }
fstab_can_remove(){
  local mp=$1 src=${2:-} id=${3:-} n; [[ ! -e "$FSTAB" ]] && return 0; [[ -f "$FSTAB" && ! -L "$FSTAB" ]] || return 1; n="$(fstab_count "$mp")"
  if fstab_match "$mp" "$src" "$id"; then ! fstab_foreign_same_mount "$mp" "$src" "$id" && ! fstab_source_elsewhere "$mp" "$src" "$id"; return; fi
  if [[ -z "$id" && ! -e "$src" && "$n" == 1 ]] && fstab_setup_signature "$mp"; then return 0; fi
  [[ "$n" == 0 ]] && ! fstab_source_elsewhere "$mp" "$src" "$id"
}
remove_fstab(){
  local mp=$1 src=${2:-} id=${3:-}; fstab_can_remove "$mp" "$src" "$id" || return 1; [[ -f "$FSTAB" ]] || return 0
  if fstab_match "$mp" "$src" "$id"; then rewrite "$FSTAB" '!(($2==mp)&&((src!=""&&$1==src)||(id!=""&&$1=="UUID="id))){print}' -v mp="$mp" -v src="$src" -v id="$id"; return; fi
  if [[ "$(fstab_count "$mp")" == 1 ]] && fstab_setup_signature "$mp"; then rewrite "$FSTAB" '!(($2==mp)&&$0!~/^[[:space:]]*#/){print}' -v mp="$mp"; return; fi
  return 0
}

guard_managed(){ [[ -f "$MOUNT_GUARD" && ! -L "$MOUNT_GUARD" ]] && grep -Fq 'Managed by VaultWarden-OCI setup.sh' "$MOUNT_GUARD"; }
remove_guard(){ if [[ -e "$MOUNT_GUARD" || -L "$MOUNT_GUARD" ]]; then guard_managed || { warn "Preserving unmarked Docker mount guard: $MOUNT_GUARD"; return 1; }; rm -f "$MOUNT_GUARD"; rmdir "$(dirname "$MOUNT_GUARD")" 2>/dev/null || true; fi; has systemctl && systemctl daemon-reload 2>/dev/null || true; }

storage_ambiguous(){
  [[ -z "$DATA_VOLUME_DEVICE" ]] || return 1
  [[ -n "$DATA_VOLUME_MOUNT" ]] && same_path "$PROJECT_STATE_DIR" "$DATA_VOLUME_MOUNT" && return 0
  same_path "$PROJECT_STATE_DIR" "$DEFAULT_DATA" && return 0
  guard_managed && return 0
  [[ -f "$FSTAB" && ! -L "$FSTAB" ]] && fstab_setup_signature "$PROJECT_STATE_DIR" && return 0
  return 1
}
preflight_docker(){
  has docker || return 0
  docker info >/dev/null 2>&1 || die "Docker is installed but the daemon is unavailable. Start Docker and rerun uninstall so project containers, volumes, and networks can be removed and verified before state is deleted."
}
preflight_storage(){
  storage_ambiguous && die "Storage config looks separate-volume but DATA_VOLUME_DEVICE is missing; repair persisted environment first."
  [[ -n "$DATA_VOLUME_DEVICE" ]] || return 0
  [[ "$DATA_VOLUME_MOUNT" == /* && ! -L "$DATA_VOLUME_MOUNT" ]] || die "Separate volume requires a real absolute DATA_VOLUME_MOUNT."
  same_path "$PROJECT_STATE_DIR" "$DATA_VOLUME_MOUNT" || die "PROJECT_STATE_DIR must equal DATA_VOLUME_MOUNT for separate storage."
  local src=$DATA_VOLUME_DEVICE id="$(uuid "$DATA_VOLUME_DEVICE")"
  if mountpoint -q "$DATA_VOLUME_MOUNT" 2>/dev/null; then verify_volume || die "Mounted data-volume identity verification failed."; src="$(findmnt -n -o SOURCE --target "$DATA_VOLUME_MOUNT")"; fi
  fstab_can_remove "$DATA_VOLUME_MOUNT" "$src" "$id" || die "Data-volume fstab wiring is ambiguous; no changes made."
  [[ ! -e "$MOUNT_GUARD" && ! -L "$MOUNT_GUARD" ]] || guard_managed || die "Docker mount guard is unmarked; no changes made."
}

safe_rm(){ local p=$1 c; [[ "$p" == /* ]] || return 1; c="$(canon "$p")" || return 1; case "$c" in /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/mnt|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var|/var/lib) return 1;; esac; [[ "$DRY_RUN" == true ]] && { info "Would remove $p"; return 0; }; rm -rf --one-file-system -- "$p"; }
state_evidence(){ same_path "$1" "$DEFAULT_STATE" && return 0; [[ -f "$1/config/install.env" || -f "$1/secrets/secrets.yaml" || -f "$1/data/db.sqlite3" || -d "$1/logs/vaultwarden" || -d "$1/caddy" ]]; }

handoff_name(){ [[ "$1" =~ ^vaultwarden-setup-credentials-[0-9]{8}T[0-9]{6}Z\.txt$ || "$1" =~ ^\.vaultwarden-setup-credentials\.[A-Za-z0-9]{8}$ || "$1" =~ ^vaultwarden-age-key-rotation-[0-9]{8}-[0-9]{6}\.txt$ || "$1" =~ ^\.vaultwarden-age-key-rotation\.[A-Za-z0-9]{8}$ || "$1" =~ ^vaultwarden-recovery-kit-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}\.txt$ || "$1" =~ ^\.important-documents\.[A-Za-z0-9]{8}\.zip$ ]]; }
handoffs(){ [[ -d "$RECOVERY_DIR" && ! -L "$RECOVERY_DIR" ]] || return 0; local p; while IFS= read -r -d '' p; do handoff_name "${p##*/}" && printf '%s\n' "$p"; done < <(find -P "$RECOVERY_DIR" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -print0 2>/dev/null); }
validate_handoffs(){
  [[ ! -e "$RECOVERY_DIR" && ! -L "$RECOVERY_DIR" ]] && return 0
  [[ -d "$RECOVERY_DIR" && ! -L "$RECOVERY_DIR" ]] || die "Recovery handoff path is not a real directory."
  [[ "$(stat -c '%u:%g:%a' "$RECOVERY_DIR")" == '0:0:700' ]] || die "Recovery handoff directory must be root:root 0700."
  local p; while IFS= read -r p; do [[ ! -L "$p" && -f "$p" ]] || die "Matching recovery handoff is not a regular file: $p"; [[ "$(stat -c '%u:%g:%a:%h' "$p")" == '0:0:600:1' ]] || die "Unsafe recovery handoff metadata: $p"; done < <(handoffs)
}
key_will_delete(){ inside "$1" "$ETC_DIR" && return 0; inside "$1" "$ROOT/secrets" && return 0; [[ -z "$DATA_VOLUME_DEVICE" ]] && inside "$1" "$PROJECT_STATE_DIR"; }
existing_keys(){ local k; for k in "${AGE_KEYS[@]}"; do [[ -f "$k" ]] && key_will_delete "$k" && printf '%s\n' "$k"; done | uniq; }
confirm_recovery(){ local k h; k="$(existing_keys)"; h="$(handoffs)"; [[ -z "$k$h" ]] && return 0; [[ "$FORCE" == true || "$SAVED_RECOVERY" == true ]] && { warn "Recovery-material deletion explicitly acknowledged."; return 0; }; [[ -n "$k" ]] && printf 'Age keys to delete:\n%s\n' "$k"; [[ -n "$h" ]] && printf 'Recovery handoffs to delete:\n%s\n' "$h"; die "Save recovery material off-host and rerun with --i-have-saved-my-recovery-kit."; }
remove_handoffs(){ local p before after; while IFS= read -r p; do before="$(stat -c '%d:%i:%u:%g:%a:%h' "$p")" || die "Cannot inspect $p"; [[ "$before" == *':0:0:600:1' ]] || die "Recovery handoff changed: $p"; after="$(stat -c '%d:%i:%u:%g:%a:%h' "$p")"; [[ "$after" == "$before" ]] || die "Recovery handoff changed during cleanup: $p"; has shred && shred -fuz -- "$p" 2>/dev/null || rm -f -- "$p"; [[ ! -e "$p" ]] || die "Could not remove $p"; done < <(handoffs); rmdir "$RECOVERY_DIR" 2>/dev/null || true; }
at_jobs(){ has atq && has at || return 0; local id body; while read -r id _; do [[ "$id" =~ ^[0-9]+$ ]] || continue; body="$(at -c "$id" 2>/dev/null || true)"; grep -Fq "$RECOVERY_DIR/" <<<"$body" && grep -Eq 'vaultwarden-recovery-kit-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}\.txt' <<<"$body" && printf '%s\n' "$id"; done < <(atq 2>/dev/null || true); }
recovery_units(){ has systemctl || return 0; systemctl list-units --all --no-legend --plain 'vaultwarden-recovery-cleanup-*' 2>/dev/null | awk 'NF{print $1}' || true; }

backup_inside_state(){ [[ -z "$DATA_VOLUME_DEVICE" ]] && inside "$BACKUP_DIR" "$PROJECT_STATE_DIR"; }
backup_external(){ ! inside "$BACKUP_DIR" "$PROJECT_STATE_DIR"; }
confirm_uninstall(){ [[ "$FORCE" == true ]] && return 0; local x; read -r -t 300 -p "Type UNINSTALL to confirm: " x || die "Confirmation timed out."; [[ "$x" == UNINSTALL ]] || { info "Aborted."; exit 0; }; }
offer_backup(){ [[ "$FORCE" == true || ! -f "$ROOT/backup.sh" ]] && return 0; local a; read -r -t 300 -p "Run a final encrypted backup first? [yes/no] (default no): " a || a=no; [[ "$a" == yes ]] || return 0; local args=(run full); backup_inside_state && { warn "Local backup is inside state and would be deleted; requiring verified off-host sync."; args+=(--rclone --full-verification); }; bash "$ROOT/backup.sh" "${args[@]}" || { read -r -t 300 -p "Backup failed. Continue uninstall? [yes/no]: " a || a=no; [[ "$a" == yes ]] || exit 1; }; }

disable_units(){
  local u d
  if has systemctl; then
    for u in "${TIMERS[@]}" vaultwarden-startup.service; do systemctl disable --now "$u" 2>/dev/null || true; done
    for u in "${SERVICES[@]}"; do [[ "$u" == *'@.'* ]] || systemctl stop "$u" 2>/dev/null || true; done
    while read -r u; do
      [[ -n "$u" ]] || continue
      systemctl stop "$u" 2>/dev/null || true
      systemctl reset-failed "$u" 2>/dev/null || true
    done < <(recovery_units)
  fi
  for u in "${TIMERS[@]}" "${SERVICES[@]}"; do rm -f "$SYSTEMD/$u"; d="$SYSTEMD/$u.d"; rm -f "$d"/{10-state-dir.conf,20-identity.conf,30-run-as-root.conf} 2>/dev/null || true; rmdir "$d" 2>/dev/null || true; done
  if has systemctl; then
    for u in "${SERVICES[@]}"; do [[ "$u" == *'@.'* ]] || systemctl reset-failed "$u" 2>/dev/null || true; done
    systemctl daemon-reload 2>/dev/null || true
  fi
  if has atrm; then while read -r u; do [[ -n "$u" ]] && atrm "$u" 2>/dev/null || true; done < <(at_jobs); fi
}

docker_cleanup(){
  has docker || return 0
  docker info >/dev/null 2>&1 || die "Docker daemon became unavailable during uninstall; refusing to delete persistent state until project containers can be verified stopped."
  local id remaining
  if [[ -f "$ROOT/docker-compose.yml" ]]; then
    (cd "$ROOT" && docker compose -p "$COMPOSE_PROJECT" -f docker-compose.yml down --volumes --remove-orphans --timeout 30) 2>/dev/null \
      || warn "docker compose down reported errors; labelled cleanup continues."
  fi
  while read -r id; do
    [[ -n "$id" ]] || continue
    docker rm -f "$id" 2>/dev/null || warn "Could not remove compose-labelled container: $id"
  done < <(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" 2>/dev/null || true)
  remaining="$(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" 2>/dev/null || true)"
  [[ -z "$remaining" ]] || die "Compose-labelled project container(s) remain: $remaining. Refusing persistent-state deletion."
  while read -r id; do
    [[ -n "$id" ]] || continue
    docker volume rm "$id" 2>/dev/null || warn "Could not remove compose-labelled volume: $id"
  done < <(docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" 2>/dev/null || true)
  while read -r id; do
    [[ -n "$id" ]] || continue
    docker network rm "$id" 2>/dev/null || warn "Could not remove compose-labelled network: $id"
  done < <(docker network ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" 2>/dev/null || true)
}

remove_state(){
  if [[ -z "$DATA_VOLUME_DEVICE" ]]; then
    storage_ambiguous && die "Refusing ambiguous recursive state deletion."
    [[ ! -L "$PROJECT_STATE_DIR" ]] || die "State path is a symlink; refusing recursive deletion."
    mountpoint -q "$PROJECT_STATE_DIR" 2>/dev/null && die "State path is a mountpoint without verified device identity."
    [[ -d "$PROJECT_STATE_DIR" ]] && { state_evidence "$PROJECT_STATE_DIR" || die "State directory lacks recognizable VaultWarden evidence: $PROJECT_STATE_DIR"; safe_rm "$PROJECT_STATE_DIR" || die "Could not remove state."; }
    remove_guard || true; return
  fi
  local mounted=false src=$DATA_VOLUME_DEVICE id="$(uuid "$DATA_VOLUME_DEVICE")"; mountpoint -q "$DATA_VOLUME_MOUNT" 2>/dev/null && mounted=true
  if [[ "$mounted" == true ]]; then verify_volume || die "Data-volume verification failed."; src="$(findmnt -n -o SOURCE --target "$DATA_VOLUME_MOUNT")"; fstab_can_remove "$DATA_VOLUME_MOUNT" "$src" "$id" || die "Ambiguous fstab; refusing detach."; info "Unmounting verified data volume..."; umount "$DATA_VOLUME_MOUNT" 2>/dev/null || die "Unmount failed. Close open files and retry; lazy unmount is not used."; ok "Data volume unmounted; filesystem contents and sentinel preserved."; fi
  remove_fstab "$DATA_VOLUME_MOUNT" "$src" "$id" || die "Could not safely remove fstab wiring."
  remove_guard || die "Could not safely remove Docker mount guard."
  [[ -d "$DATA_VOLUME_MOUNT" ]] && { rmdir "$DATA_VOLUME_MOUNT" 2>/dev/null || warn "Preserving non-empty host mountpoint directory: $DATA_VOLUME_MOUNT"; }
}

rm_except(){ local root=$1 keep=$2 c; [[ -d "$root" && ! -L "$root" ]] || return 1; while IFS= read -r -d '' c; do if same_path "$c" "$keep"; then continue; elif inside "$keep" "$c"; then rm_except "$c" "$keep"; else safe_rm "$c" || return 1; fi; done < <(find -P "$root" -mindepth 1 -maxdepth 1 -print0); }
cleanup_checkout_artifacts(){ local p; for p in .env .sops.yaml docker-compose.yml docker-compose.override.yml docker-compose.override.dev.yml rclone.conf secrets backups logs data caddy/data caddy/config; do p="$ROOT/$p"; [[ -e "$p" || -L "$p" ]] || continue; if [[ -d "$BACKUP_DIR" ]] && backup_external && inside "$BACKUP_DIR" "$p"; then rm_except "$p" "$BACKUP_DIR" || die "Could not clean around preserved backup."; else safe_rm "$p" || die "Could not remove $p"; fi; done; while IFS= read -r -d '' p; do safe_rm "$p" || die "Could not remove $p"; done < <(find -P "$ROOT" -mindepth 1 -maxdepth 1 -type d \( -name '.restore-tmp*' -o -name '.backup-tmp*' \) -print0 2>/dev/null); }
remove_owned_tree(){ local p=$1; [[ -e "$p" || -L "$p" ]] || return 0; if backup_external && [[ -d "$BACKUP_DIR" ]] && inside "$BACKUP_DIR" "$p"; then rm_except "$p" "$BACKUP_DIR"; else safe_rm "$p"; fi; }
remove_installed(){ remove_owned_tree "$OPT_DIR" || warn "Could not completely remove $OPT_DIR"; remove_owned_tree "$ETC_DIR" || warn "Could not completely remove $ETC_DIR"; [[ "$TEST_RESET" == true ]] && cleanup_checkout_artifacts; }

strip_profile(){
  [[ -f "$CS_PROFILES" && ! -L "$CS_PROFILES" ]] || return 0
  local t
  grep -Fxq "$CS_PROFILE_BEGIN" "$CS_PROFILES" || { grep -Fxq "$CS_PROFILE_END" "$CS_PROFILES" && return 1; return 0; }
  grep -Fxq "$CS_PROFILE_END" "$CS_PROFILES" || return 1
  t="$(mktemp "$CS_PROFILES.vw.XXXXXXXX")" || return 1
  awk -v b="$CS_PROFILE_BEGIN" -v e="$CS_PROFILE_END" '$0==b{if(inside_block||seen)exit 42;inside_block=seen=1;next}$0==e{if(!inside_block)exit 43;inside_block=0;next}!inside_block{print}END{if(inside_block)exit 44}' "$CS_PROFILES" > "$t" || { rm -f "$t"; return 1; }
  chmod --reference="$CS_PROFILES" "$t"; chown --reference="$CS_PROFILES" "$t"
  if grep -q '[^[:space:]]' "$t"; then mv -f "$t" "$CS_PROFILES"; else rm -f "$t" "$CS_PROFILES"; fi
}
worker_config_managed(){ [[ -f "$CS_WORKER" && ! -L "$CS_WORKER" ]] || return 1; [[ "$(head -1 "$CS_WORKER" 2>/dev/null)" == '# crowdsec/crowdsec-cloudflare-worker-bouncer.yaml.example' ]]; }
worker_unit_managed(){ [[ -f "$CS_WORKER_UNIT" && ! -L "$CS_WORKER_UNIT" ]] || return 1; grep -Fq 'CrowdSec Cloudflare' "$CS_WORKER_UNIT" && grep -Fq '/usr/local/bin/crowdsec-cloudflare-worker-bouncer' "$CS_WORKER_UNIT" && grep -Fq '/etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml' "$CS_WORKER_UNIT"; }
crowdsec_cleanup(){
  local changed=false worker_owned=false
  worker_config_managed && worker_owned=true
  worker_unit_managed && worker_owned=true
  if [[ "$worker_owned" == true ]] && has systemctl \
     && { systemctl is-active crowdsec-cloudflare-worker-bouncer.service >/dev/null 2>&1 \
          || systemctl is-enabled crowdsec-cloudflare-worker-bouncer.service >/dev/null 2>&1; }; then
    systemctl disable --now crowdsec-cloudflare-worker-bouncer.service 2>/dev/null \
      || die "Could not stop the VaultWarden-attributed CrowdSec Workers bouncer. Its config was preserved; stop the service and rerun uninstall."
  fi
  if [[ -f "$CS_EMAIL" && ! -L "$CS_EMAIL" ]] && grep -Fxq "$CS_EMAIL_MARKER" "$CS_EMAIL"; then rm -f "$CS_EMAIL"; changed=true; fi
  strip_profile || warn "CrowdSec profile markers malformed; preserved for review."
  if worker_config_managed; then rm -f "$CS_WORKER"; changed=true; fi
  if worker_unit_managed; then rm -f "$CS_WORKER_UNIT"; changed=true; fi
  [[ "$changed" == true ]] && has systemctl && systemctl daemon-reload 2>/dev/null || true
  warn "Preserving shared CrowdSec engine, firewall bouncer, packages, repository, state, logs and external Cloudflare resources."
}

ufw_numbers(){ has ufw || return 0; ufw status numbered 2>/dev/null | awk '$0~/#[[:space:]]*CF-IPv[46]([[:space:]-]|$)/{x=$0;sub(/^\[[[:space:]]*/,"",x);sub(/\].*/,"",x);gsub(/[[:space:]]/,"",x);if(x~/^[0-9]+$/)print x}' | sort -rn; }
firewall_cleanup(){ local n; if has ufw; then while read -r n; do [[ -n "$n" ]] && ufw --force delete "$n" >/dev/null 2>&1 || true; done < <(ufw_numbers); fi; warn "Preserving unmarked UFW and raw iptables/ip6tables rules."; }

test_reset_host(){
  [[ "$TEST_RESET" == true ]] || { [[ -e "$SWAPFILE" ]] && warn "Preserving ambiguous $SWAPFILE"; return 0; }

  if [[ -e "$SWAPFILE" || -L "$SWAPFILE" ]]; then
    has swapon || die "--test-reset needs swapon to verify $SWAPFILE is not active."
    if swapon --show=NAME --noheadings 2>/dev/null | awk '{$1=$1; print}' | grep -Fxq "$SWAPFILE"; then
      has swapoff || die "--test-reset needs swapoff before removing active $SWAPFILE."
      swapoff "$SWAPFILE" 2>/dev/null || die "Could not disable active swapfile: $SWAPFILE"
    fi
    rm -f -- "$SWAPFILE" || die "Could not remove test-reset swapfile: $SWAPFILE"
  fi

  if [[ -f "$FSTAB" && ! -L "$FSTAB" ]] && awk -v swap="$SWAPFILE" '$1==swap{f=1}END{exit !f}' "$FSTAB"; then
    rewrite "$FSTAB" '$1!=swap{print}' -v swap="$SWAPFILE" || die "Could not remove test-reset swapfile fstab entry."
  fi
  if [[ -f "$SYSCTL" && ! -L "$SYSCTL" ]] && grep -Fxq 'vm.swappiness=10' "$SYSCTL"; then
    rewrite "$SYSCTL" '$0!="vm.swappiness=10"{print}' || die "Could not remove test-reset swappiness line."
  fi
  [[ ! -e "$UNIVERSE_SOURCE" && ! -L "$UNIVERSE_SOURCE" ]] || rm -f -- "$UNIVERSE_SOURCE" || die "Could not remove test-reset universe source."
}

checkout_recognized(){ [[ ( -d "$ROOT/.git" || -f "$ROOT/.git" ) && -f "$ROOT/setup.sh" && -f "$ROOT/docker-compose.yml.example" && -f "$ROOT/VERSION" ]]; }
remove_checkout(){ [[ "$TEST_RESET" == true ]] && return 0; checkout_recognized || { warn "Preserving directory because it is not positively identified as the VaultWarden-OCI Git checkout: $ROOT"; return 0; }; if [[ -d "$BACKUP_DIR" ]] && backup_external && inside "$BACKUP_DIR" "$ROOT"; then cleanup_checkout_artifacts; warn "Preserving checkout because it contains external backup: $BACKUP_DIR"; else cd /; safe_rm "$ROOT" || warn "Could not remove checkout completely."; fi; }
remove_runtime(){ [[ ! -e "$RUNTIME" && ! -L "$RUNTIME" ]] || safe_rm "$RUNTIME" || die "Could not remove VaultWarden runtime state: $RUNTIME"; }

verify(){
  local bad=0 u ids
  for u in "${TIMERS[@]}" "${SERVICES[@]}"; do
    [[ ! -e "$SYSTEMD/$u" ]] || { warn "RESIDUAL: $SYSTEMD/$u"; bad=$((bad+1)); }
  done
  if has systemctl; then
    for u in "${TIMERS[@]}" vaultwarden-startup.service; do
      systemctl is-enabled "$u" >/dev/null 2>&1 && { warn "RESIDUAL: enabled systemd unit $u"; bad=$((bad+1)); }
    done
    while IFS= read -r u; do [[ -n "$u" ]] && { warn "RESIDUAL: recovery cleanup unit $u"; bad=$((bad+1)); }; done < <(recovery_units)
  fi
  guard_managed && { warn "RESIDUAL: managed Docker mount guard $MOUNT_GUARD"; bad=$((bad+1)); } || true
  for u in "$OPT_DIR" "$ETC_DIR" "$RUNTIME"; do [[ ! -e "$u" && ! -L "$u" ]] || { warn "RESIDUAL: $u"; bad=$((bad+1)); }; done
  [[ -z "$(handoffs)" ]] || { warn "RESIDUAL: managed recovery handoff(s)"; bad=$((bad+1)); }
  [[ -z "$(at_jobs)" ]] || { warn "RESIDUAL: scheduled recovery cleanup at job(s)"; bad=$((bad+1)); }
  if [[ -z "$DATA_VOLUME_DEVICE" ]]; then
    [[ ! -e "$PROJECT_STATE_DIR" && ! -L "$PROJECT_STATE_DIR" ]] || { warn "RESIDUAL: managed boot-volume state $PROJECT_STATE_DIR"; bad=$((bad+1)); }
  else
    mountpoint -q "$DATA_VOLUME_MOUNT" 2>/dev/null && { warn "RESIDUAL: data volume still mounted at $DATA_VOLUME_MOUNT"; bad=$((bad+1)); }
    [[ "$(fstab_count "$DATA_VOLUME_MOUNT")" == 0 ]] || { warn "RESIDUAL: fstab still references $DATA_VOLUME_MOUNT"; bad=$((bad+1)); }
  fi
  if has docker; then
    if ! docker info >/dev/null 2>&1; then
      warn "RESIDUAL: Docker daemon became unavailable; runtime cleanup cannot be verified."
      bad=$((bad+1))
    else
      ids="$(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" 2>/dev/null || true)"; [[ -z "$ids" ]] || { warn "RESIDUAL: compose-labelled container(s): $ids"; bad=$((bad+1)); }
      ids="$(docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" 2>/dev/null || true)"; [[ -z "$ids" ]] || { warn "RESIDUAL: compose-labelled volume(s): $ids"; bad=$((bad+1)); }
      ids="$(docker network ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" 2>/dev/null || true)"; [[ -z "$ids" ]] || { warn "RESIDUAL: compose-labelled network(s): $ids"; bad=$((bad+1)); }
    fi
  fi
  [[ -z "$(ufw_numbers)" ]] || { warn "RESIDUAL: VaultWarden Cloudflare UFW rule(s)"; bad=$((bad+1)); }
  [[ ! -f "$CS_EMAIL" ]] || ! grep -Fxq "$CS_EMAIL_MARKER" "$CS_EMAIL" || { warn "RESIDUAL: managed CrowdSec email notification"; bad=$((bad+1)); }
  [[ ! -f "$CS_PROFILES" ]] || ! grep -Fxq "$CS_PROFILE_BEGIN" "$CS_PROFILES" || { warn "RESIDUAL: managed CrowdSec email profile block"; bad=$((bad+1)); }
  worker_config_managed && { warn "RESIDUAL: managed CrowdSec Workers config"; bad=$((bad+1)); } || true
  worker_unit_managed && { warn "RESIDUAL: managed CrowdSec Workers unit"; bad=$((bad+1)); } || true
  if [[ "$TEST_RESET" == true ]]; then
    [[ ! -e "$SWAPFILE" && ! -L "$SWAPFILE" ]] || { warn "RESIDUAL: test-reset swapfile $SWAPFILE"; bad=$((bad+1)); }
    if [[ -f "$FSTAB" && ! -L "$FSTAB" ]] && awk -v swap="$SWAPFILE" '$1==swap{f=1}END{exit !f}' "$FSTAB"; then warn "RESIDUAL: test-reset fstab still references $SWAPFILE"; bad=$((bad+1)); fi
    [[ ! -f "$SYSCTL" ]] || ! grep -Fxq 'vm.swappiness=10' "$SYSCTL" || { warn "RESIDUAL: test-reset vm.swappiness=10"; bad=$((bad+1)); }
  fi
  [[ $bad -eq 0 ]] || die "Uninstall incomplete: $bad positively managed residual(s) remain."
  ok "Residual verification passed."
}

summary(){ printf '\nVaultWarden-OCI uninstall\n  config: %s\n  state : %s\n  data  : %s @ %s\n  backup: %s\n' "${CONFIG_SOURCE:-<defaults>}" "$PROJECT_STATE_DIR" "${DATA_VOLUME_DEVICE:-boot-volume}" "${DATA_VOLUME_MOUNT:-<none>}" "$BACKUP_DIR"; [[ "$TEST_RESET" == true ]] && printf '  reset : dedicated test-VM reset\n'; [[ "$DRY_RUN" == true ]] && { printf '  mode  : DRY RUN\n'; warn "No changes made. Separate-volume contents, external backups and shared host infrastructure are preserved."; exit 0; }; }

release_op(){ local rc=${1:-0}; [[ "$OP_HELD" == true ]] || return 0; declare -f operation_release >/dev/null && operation_release "$rc" || true; OP_HELD=false; }
finalize_op_success(){
  local rc=0
  [[ "$OP_HELD" == true ]] || return 0
  if declare -f operation_release >/dev/null; then
    # Runtime cleanup intentionally removes the operation state directory. Do not
    # recreate uninstall.state while releasing the successful guard afterward.
    OPERATION_OWNS_STATE=false
    OPERATION_STATE_FILE=""
    operation_release 0 || rc=$?
    unset VW_OPERATION_PARENT_STATE VW_OPERATION_PARENT_TOKEN VW_OPERATION_PARENT_ID
  fi
  OP_HELD=false
  (( rc == 0 )) || die "Could not release the uninstall operation guard cleanly."
}

main(){
  if [[ "$DRY_RUN" != true ]] && declare -f operation_acquire >/dev/null; then operation_acquire --id uninstall --label Uninstall --specific-lock /run/lock/vaultwarden-uninstall.lock || exit $?; OP_HELD=true; trap 'rc=$?; release_op "$rc"; exit "$rc"' EXIT; fi
  resolve
  [[ "$DRY_RUN" == true ]] || { preflight_docker; preflight_storage; validate_handoffs; }
  summary
  confirm_recovery
  confirm_uninstall
  offer_backup
  disable_units
  docker_cleanup
  remove_state
  remove_installed
  remove_handoffs
  crowdsec_cleanup
  firewall_cleanup
  test_reset_host
  warn "Preserving Docker packages/data, OS users/groups/memberships, SOPS/admin tools and external backups."
  remove_runtime
  verify
  finalize_op_success
  trap - EXIT
  remove_checkout
  ok "Uninstall complete."
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main; fi
