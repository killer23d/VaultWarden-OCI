#!/usr/bin/env bash
# Consolidated storage and setup regression suite.
set -euo pipefail

check_migration_storage_contracts() (
set -euo pipefail

fail(){ echo "FAIL: $*" >&2; exit 1; }
pass(){ echo "PASS: $*"; }

out=$(bash <<'PROBE'
set -euo pipefail
PROJECT_ROOT="$PWD"
_VW_DEFAULT_STATE_DIR=/var/lib/vaultwarden
_VW_DEFAULT_DATA_MOUNT=/mnt/vw-data
DRY_RUN=false
log_info(){ echo "INFO:$*"; }; log_warn(){ :; }; log_error(){ :; }; log_success(){ :; }; log_debug(){ :; }
require_commands(){ :; }
source lib/migrate.sh
PROJECT_STATE_DIR=/var/lib/vaultwarden
DATA_VOLUME_MOUNT=/opt/vaultwarden/data
_MV_SUBCOMMAND=run
_MV_DIRECTION=boot-to-block
_mv_prompt_target <<< ''
printf '%s\n' "$_MV_TARGET"
PROBE
)
grep -Fxq "/mnt/vw-data" <<< "$out" || fail "legacy target default was not /mnt/vw-data: $out"
pass 'boot-to-block legacy DATA_VOLUME_MOUNT defaults target to /mnt/vw-data'

out=$(bash <<'PROBE'
set -euo pipefail
PROJECT_ROOT="$PWD"
_VW_DEFAULT_STATE_DIR=/var/lib/vaultwarden
_VW_DEFAULT_DATA_MOUNT=/mnt/vw-data
DRY_RUN=false
log_info(){ :; }; log_warn(){ :; }; log_error(){ :; }; log_success(){ :; }; log_debug(){ :; }
require_commands(){ :; }
source lib/migrate.sh
PROJECT_STATE_DIR=/var/lib/vaultwarden
DATA_VOLUME_MOUNT=/opt/vaultwarden/data
_MV_SUBCOMMAND=run
_MV_DIRECTION=boot-to-block
_MV_TARGET=/custom/target
_mv_prompt_target
printf '%s\n' "$_MV_TARGET"
PROBE
)
[[ "$out" == "/custom/target" ]] || fail "explicit --target did not win: $out"
pass 'explicit migration target still wins over prompt default'

out=$(bash <<'PROBE'
set -euo pipefail
PROJECT_ROOT="$PWD"
_VW_DEFAULT_STATE_DIR=/var/lib/vaultwarden
_VW_DEFAULT_DATA_MOUNT=/mnt/vw-data
DRY_RUN=false
log_info(){ :; }; log_warn(){ :; }; log_error(){ :; }; log_success(){ :; }; log_debug(){ :; }
require_commands(){ :; }
source lib/migrate.sh
_mv_parse_args run --source /var/lib/vaultwarden --target /mnt/vw-data --device /dev/sdb --force --force-format
printf 'force=%s force_format=%s\n' "$_MV_FORCE" "$_MV_FORCE_FORMAT"
PROBE
)
grep -Fxq 'force=true force_format=true' <<< "$out" || fail "--force-format parser did not preserve separate force flags: $out"
pass 'migrate parser keeps --force and --force-format separate'

help_out=$(bash <<'PROBE'
set -euo pipefail
PROJECT_ROOT="$PWD"
_VW_DEFAULT_DATA_MOUNT=/mnt/vw-data
source lib/migrate.sh
_mv_usage
PROBE
)
grep -Fq -- '--force-format' <<< "$help_out" || fail "migrate help does not document --force-format"
grep -Fq 'Authorize formatting a blank/signature-free target block' <<< "$help_out" || fail "migrate help missing --force-format meaning"
pass 'migrate help documents --force-format'

out=$(bash <<'PROBE'
set -euo pipefail
PROJECT_ROOT="$PWD"
_VW_DEFAULT_STATE_DIR=/var/lib/vaultwarden
_VW_DEFAULT_DATA_MOUNT=/mnt/vw-data
DRY_RUN=false
log_info(){ :; }; log_warn(){ :; }; log_error(){ :; }; log_success(){ :; }; log_debug(){ :; }
require_commands(){ :; }
source lib/migrate.sh
setup_data_volume(){ printf 'DATA_VOLUME_FORCE_FORMAT=%s\n' "${DATA_VOLUME_FORCE_FORMAT:-unset}"; }
mountpoint(){ return 1; }
_mv_check_disk_space(){ :; }
_MV_LOG_FILE=/dev/null
_MV_DIRECTION=boot-to-block
_MV_DEVICE=/dev/fake
_MV_TARGET=/mnt/vw-data
_MV_SOURCE=/var/lib/vaultwarden
_MV_FORCE_FORMAT=false
unset DATA_VOLUME_FORCE_FORMAT
_mv_step_format
_MV_FORCE_FORMAT=true
unset DATA_VOLUME_FORCE_FORMAT
_mv_step_format
PROBE
)
grep -Fxq 'DATA_VOLUME_FORCE_FORMAT=unset' <<< "$out" || fail "_mv_step_format unexpectedly exports force-format when false: $out"
grep -Fxq 'DATA_VOLUME_FORCE_FORMAT=true' <<< "$out" || fail "_mv_step_format does not export force-format when true: $out"
pass '_mv_step_format exports DATA_VOLUME_FORCE_FORMAT only for --force-format'

out=$(bash <<'PROBE'
set -euo pipefail
PROJECT_ROOT="$PWD"
_VW_DEFAULT_STATE_DIR=/var/lib/vaultwarden
_VW_DEFAULT_DATA_MOUNT=/mnt/vw-data
DRY_RUN=false
log_info(){ echo "INFO:$*"; }; log_warn(){ :; }; log_error(){ echo "ERR:$*"; }; log_success(){ :; }; log_debug(){ :; }
require_commands(){ :; }
source lib/migrate.sh
_MV_LOG_FILE=/dev/null
_MV_DIRECTION=boot-to-block
_MV_DEVICE=/dev/sdb
_MV_TARGET=/mnt/vw-data
_MV_SOURCE=/var/lib/vaultwarden
_MV_FORCE_FORMAT=false
mountpoint(){ return 1; }
_mv_device_has_no_fs_or_signatures(){ return 0; }
if _mv_require_force_format_for_blank_device; then
  echo unexpected-success
else
  echo failed-as-expected
fi
PROBE
)
grep -Fq 'Blank target device requires --force-format.' <<< "$out" || fail "blank-device validation lacks clear force-format error: $out"
grep -Fq 'sudo utilities/setup-storage.sh --mode migrate run --device /dev/sdb --target /mnt/vw-data --force-format' <<< "$out" || fail "blank-device validation lacks sudo-safe example: $out"
grep -Fq 'failed-as-expected' <<< "$out" || fail "blank-device validation did not fail without --force-format: $out"
pass 'blank target device requires --force-format before migration proceeds'

out=$(bash <<'PROBE'
set -euo pipefail

REPO_ROOT="$PWD"
state_dir="$(mktemp -d)"
trap 'rm -rf "$state_dir"' EXIT

PROJECT_ROOT="$state_dir"
_VW_DEFAULT_STATE_DIR=/var/lib/vaultwarden
_VW_DEFAULT_DATA_MOUNT=/mnt/vw-data
DRY_RUN=false

log_info(){ :; }
log_warn(){ :; }
log_error(){ :; }
log_success(){ :; }
log_debug(){ :; }
require_commands(){ :; }

source "$REPO_ROOT/lib/migrate.sh"

mkdir -p "$PROJECT_ROOT/src" "$PROJECT_ROOT/target"
: > "$PROJECT_ROOT/docker-compose.yml"

_mv_state_write MV_SOURCE "$PROJECT_ROOT/src"
_mv_state_write MV_TARGET "$PROJECT_ROOT/target"
_mv_state_write MV_DEVICE none
_mv_state_write MV_SKIP_STACK_STOP false
_mv_state_write MV_DELETE_SOURCE false
_mv_state_write MV_FORCE_FORMAT false
_mv_state_write MV_DIRECTION boot-to-block

_mv_parse_args resume --force-format
_mv_run_step(){ :; }
_mv_run_pipeline --resume

printf 'force_format=%s state=%s\n' "$_MV_FORCE_FORMAT" "$(_mv_state_read MV_FORCE_FORMAT)"
PROBE
)
grep -Fxq 'force_format=true state=true' <<< "$out" || fail "resume --force-format did not override saved false state: $out"
pass 'resume --force-format upgrades saved false force-format state'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/docker" <<'EOF_DOCKER'
#!/usr/bin/env bash
state="$DOCKER_STATE_FILE"
if [[ "$1 $2 $3 $4" == "compose ps --status running"* ]]; then
  count="$(cat "$state" 2>/dev/null || echo 0)"
  for ((i=0; i<count; i++)); do echo "cid$i"; done
else
  exit 0
fi
EOF_DOCKER
chmod +x "$BIN/docker"
cat > "$BIN/rsync" <<'EOF_RSYNC'
#!/usr/bin/env bash
set -euo pipefail
dry_run=false
positional=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=true ;;
    --*) ;;
    -*) ;;
    *) positional+=("$arg") ;;
  esac
done
"$dry_run" && exit 0
(( ${#positional[@]} >= 2 )) || exit 2
src="${positional[$((${#positional[@]} - 2))]%/}"
dest="${positional[$((${#positional[@]} - 1))]}"
mkdir -p "$dest"
[[ ! -f "$src/db.sqlite3" ]] || cp "$src/db.sqlite3" "$dest/db.sqlite3"
EOF_RSYNC
chmod +x "$BIN/rsync"
out=$(PATH="$BIN:$PATH" DOCKER_STATE_FILE="$TMP/docker-state" bash <<'PROBE'
set -euo pipefail
PROJECT_ROOT="$PWD"
_VW_DEFAULT_STATE_DIR=/var/lib/vaultwarden
_VW_DEFAULT_DATA_MOUNT=/mnt/vw-data
DRY_RUN=false
log_info(){ echo "INFO:$*"; }; log_warn(){ echo "WARN:$*"; }; log_error(){ echo "ERR:$*"; }; log_success(){ echo "OK:$*"; }; log_debug(){ :; }
require_commands(){ :; }
source lib/migrate.sh
_MV_LOG_FILE=/dev/null
_MV_SKIP_STACK_STOP=false
printf '1' > "$DOCKER_STATE_FILE"
stop_services(){ printf '0' > "$DOCKER_STATE_FILE"; echo STOPPED; }
_mv_ensure_stack_stopped_for_rsync
printf 'state=%s\n' "$(cat "$DOCKER_STATE_FILE")"
PROBE
)
grep -Fq 'STOPPED' <<< "$out" || fail "resume pre-rsync guard did not re-stop running stack: $out"
grep -Fq 'state=0' <<< "$out" || fail "running stack state was not cleared by guard: $out"
pass 'resume pre-rsync guard re-stops containers before rsync'

SRC="$TMP/src"; TGT="$TMP/tgt"; mkdir -p "$SRC" "$TGT"
printf 'data\n' > "$SRC/db.sqlite3"
printf 'source marker\n' > "$SRC/.vw-data-volume"
printf 'target marker\n' > "$TGT/.vw-data-volume"
chmod 000 "$TGT/.vw-data-volume"
SRC="$SRC" TGT="$TGT" PATH="$BIN:$PATH" DOCKER_STATE_FILE="$TMP/docker-zero" bash <<'PROBE'
set -euo pipefail
PROJECT_ROOT="$PWD"
_VW_DEFAULT_STATE_DIR=/var/lib/vaultwarden
_VW_DEFAULT_DATA_MOUNT=/mnt/vw-data
DRY_RUN=false
log_info(){ :; }; log_warn(){ :; }; log_error(){ echo "ERR:$*" >&2; }; log_success(){ :; }; log_debug(){ :; }
require_commands(){ :; }
source lib/migrate.sh
_MV_LOG_FILE=/dev/null
_MV_SOURCE="$SRC"
_MV_TARGET="$TGT"
_MV_SKIP_STACK_STOP=false
printf '0' > "$DOCKER_STATE_FILE"
_mv_step_rsync
PROBE
marker_mode="$(stat -c '%a' "$TGT/.vw-data-volume" 2>/dev/null || stat -f '%OLp' "$TGT/.vw-data-volume")"
chmod 600 "$TGT/.vw-data-volume"
marker="$(cat "$TGT/.vw-data-volume")"
[[ "$marker_mode" == '0' || "$marker_mode" == '000' ]] || fail ".vw-data-volume permissions changed unexpectedly: $marker_mode"
[[ "$marker" == 'target marker' ]] || fail ".vw-data-volume was overwritten or deleted"
[[ -f "$TGT/db.sqlite3" ]] || fail "included file was not copied by rsync"
pass '.vw-data-volume is protected without rsync code 23'

rm -rf "$SRC" "$TGT"; mkdir -p "$SRC" "$TGT/lost+found"
printf 'same\n' > "$SRC/db.sqlite3"
printf 'same\n' > "$TGT/db.sqlite3"
printf 'marker\n' > "$TGT/.vw-data-volume"
printf 'wal\n' > "$SRC/db.sqlite3-wal"
printf 'pid\n' > "$SRC/app.pid"
mkdir -p "$SRC/lost+found"
# Make excluded/protected target-only data large enough to exceed byte tolerance.
dd if=/dev/zero of="$TGT/lost+found/noise" bs=1024 count=64 status=none
out=$(SRC="$SRC" TGT="$TGT" PATH="$BIN:$PATH" bash <<'PROBE'
set -euo pipefail
PROJECT_ROOT="$PWD"
_VW_DEFAULT_STATE_DIR=/var/lib/vaultwarden
_VW_DEFAULT_DATA_MOUNT=/mnt/vw-data
DRY_RUN=false
log_info(){ echo "INFO:$*"; }; log_warn(){ echo "WARN:$*"; }; log_error(){ echo "ERR:$*"; }; log_success(){ echo "OK:$*"; }; log_debug(){ :; }
require_commands(){ :; }
source lib/migrate.sh
_MV_LOG_FILE=/dev/null
_MV_SOURCE="$SRC"
_MV_TARGET="$TGT"
_mv_step_verify
PROBE
)
grep -Fq 'Included-file verification passed' <<< "$out" || fail "verify did not pass on excluded/protected-only delta: $out"
pass 'verify passes when excluded/protected files explain byte-count delta'

)

check_migration_storage_contracts
check_setup_storage_ux_contracts() (
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }

STORAGE="utilities/setup-storage.sh"
SETUP="setup.sh"

# The assistant must be gated to interactive setup only and not affect CI/automation.
grep -Fq '_ss_should_run_storage_assistant' "$STORAGE" || fail 'storage assistant gate missing'
grep -Fq '[[ -t 0 ]] || return 1' "$STORAGE" || fail 'assistant must require terminal stdin'
grep -Fq '[[ "${DRY_RUN}" != "true" ]] || return 1' "$STORAGE" || fail 'assistant must skip dry-run'
grep -Fq '[[ "${_SS_AUTO}" != "true" ]] || return 1' "$STORAGE" || fail 'assistant must honor --auto'
grep -Fq '[[ "${_SS_DATA_DEVICE_PROVIDED}" != "true" ]] || return 1' "$STORAGE" || fail 'assistant must skip explicit --data-device'
pass 'storage assistant is gated away from non-interactive, dry-run, auto, and explicit data-device runs'

# The assistant may collect a path, but existing setup_data_volume remains the only provisioning path.
grep -Fq 'lsblk -dpno NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL' "$STORAGE" || fail 'assistant missing read-only lsblk summary'
grep -Fq 'Path is not a block device' "$STORAGE" || fail 'assistant must reject non-block paths'
grep -Fq 'Block device path cannot be empty.' "$STORAGE" || fail 'assistant must reject empty device input'
grep -Fq 'setup_data_volume will validate and provision using existing safeguards' "$STORAGE" || fail 'assistant must delegate provisioning to setup_data_volume'
! awk '/_ss_storage_assistant\(\)/,/^}/' "$STORAGE" | grep -Eq 'mkfs|wipefs|parted|sfdisk|sgdisk' \
    || fail 'assistant must not format, wipe, or partition disks'
! awk '/_ss_prompt_block_storage\(\)/,/^}/' "$STORAGE" | grep -Eq 'mkfs|wipefs|parted|sfdisk|sgdisk' \
    || fail 'block-storage prompt must not format, wipe, or partition disks'
pass 'storage assistant is read-only except collecting operator-selected device and mount values'

# Menu behavior contracts: boot confirmation, help returns to menu, and cancel exits cleanly.
grep -Fq 'Operator selected boot-volume mode; DATA_VOLUME_DEVICE remains unset.' "$STORAGE" || fail 'boot-volume confirmation missing'
grep -Fq 'Storage setup cancelled by operator.' "$STORAGE" || fail 'cancel log missing'
awk '/3\)/,/;;/' "$STORAGE" | grep -Fq 'show_help' || fail 'option 3 must show help'
awk '/3\)/,/;;/' "$STORAGE" | grep -Fq '_ss_storage_help_text' || fail 'option 3 must return to assistant context'
pass 'storage assistant menu preserves boot, help, and cancel behavior'

# Non-interactive boot-only mode should still succeed and include a next-step hint.
grep -Fq 'DATA_VOLUME_DEVICE not set — skipping data volume provisioning (boot-only mode)' lib/storage.sh \
    || fail 'existing boot-only message missing'
grep -Fq 'To use block storage, re-run with --data-device /dev/disk/by-id/... or set DATA_VOLUME_DEVICE in install.env/.env.' "$STORAGE" \
    || fail 'boot-only next-step hint missing'
pass 'non-interactive boot-only path retains existing behavior with helpful block-storage hint'

# setup.sh install --auto must propagate --auto into phase 2 storage setup.
awk '/setup-storage\.sh" --mode setup/,/\|\| _phase_failed 2/' "$SETUP" | grep -Fq '"${_auto[@]}"' \
    || fail 'setup.sh phase 2 does not pass --auto to setup-storage'
pass 'setup.sh install --auto suppresses the storage assistant in phase 2'

# Help/unknown-option handling remains present.
grep -Fq -- '--help|-h)' "$STORAGE" || fail 'setup-storage help option handling missing'
grep -Fq 'Unknown option: $1' "$STORAGE" || fail 'setup-storage unknown-option handling missing'
grep -Fq 'setup-storage is run interactively' "$STORAGE" \
    || fail 'help text must mention interactive storage prompt'
grep -Fq -- '--auto suppresses the prompt' "$STORAGE" \
    || fail 'help text must mention --auto prompt suppression'
pass 'setup-storage help and unknown-option contracts remain documented'

)

check_setup_storage_ux_contracts
