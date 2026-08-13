#!/usr/bin/env bash
# Consolidated storage and setup regression suite.
set -euo pipefail
MODE="${VW_TEST_CASE_MODE:-all}"
case "$MODE" in core|host-architecture|all) ;; *) printf 'FAIL: unknown VW_TEST_CASE_MODE for case-storage-setup.bash: %s\n' "$MODE" >&2; exit 2 ;; esac

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

check_migration_storage_contracts() (
set -euo pipefail

fail(){ echo "FAIL: $*" >&2; exit 1; }
pass(){ echo "PASS: $*"; }

out=$("$BASH" <<'PROBE'
set -euo pipefail
REPO_ROOT="$PWD"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
PROJECT_ROOT="$tmp/repo"
mkdir -p "$PROJECT_ROOT"
printf 'PROJECT_STATE_DIR=/old\n' > "$PROJECT_ROOT/.env"
chmod 0600 "$PROJECT_ROOT/.env"
cp "$PROJECT_ROOT/.env" "$tmp/before"
DRY_RUN=true
log_info(){ :; }
log_warn(){ :; }
log_error(){ :; }
log_success(){ :; }
log_debug(){ :; }
source "$REPO_ROOT/lib/config.sh"
source "$REPO_ROOT/lib/migrate.sh"
_MV_LOG_FILE="$tmp/migrate.log"
_mv_log(){ local level="$1"; shift; printf '[%s] %s\n' "$level" "$*" >> "$_MV_LOG_FILE"; }

_set_env_var(){
    printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmp/delegated"
    printf '%s=%s\n' "$1" "$2" > "$3"
}

_mv_set_env_var PROJECT_STATE_DIR /dry-run
cmp -s "$tmp/before" "$PROJECT_ROOT/.env"
[[ ! -e "$tmp/delegated" ]]

DRY_RUN=false
_mv_set_env_var PROJECT_STATE_DIR /new-state
grep -Fxq "PROJECT_STATE_DIR|/new-state|$PROJECT_ROOT/.env" "$tmp/delegated"
grep -Fxq 'PROJECT_STATE_DIR=/new-state' "$PROJECT_ROOT/.env"

updates_before="$(grep -Fc '.env updated:' "$tmp/migrate.log")"
_set_env_var(){ return 47; }
if _mv_set_env_var PROJECT_STATE_DIR /must-not-log; then
    exit 91
fi
updates_after="$(grep -Fc '.env updated:' "$tmp/migrate.log")"
[[ "$updates_after" == "$updates_before" ]]
printf 'migration-env-wrapper-ok\n'
PROBE
)
grep -Fxq 'migration-env-wrapper-ok' <<< "$out" \
    || fail "migration env wrapper did not preserve dry-run or canonical delegation: $out"
pass 'migration env wrapper preserves dry-run and delegates successful writes to the canonical helper'

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

recover_atomic_body="$(extract_func recover.sh atomic_set_env)"
grep -Fq "awk -F=" <<< "$recover_atomic_body" \
    || fail 'recover.sh atomic_set_env no longer owns its standalone renderer'
! grep -Fq '_set_env_var' <<< "$recover_atomic_body" \
    || fail 'recover.sh atomic_set_env was consolidated into the normal configuration helper'
grep -Fq 'atomic_set_env "$INSTALL_ENV_STAGING" PROJECT_STATE_DIR' recover.sh \
    || fail 'recovery staging no longer uses its standalone env writer'
pass 'recover.sh retains its standalone disaster-recovery env writer'

defaults_line="$(grep -nF 'source "${SCRIPT_DIR}/lib/defaults.sh"' setup.sh | cut -d: -f1)"
storage_line="$(grep -nF 'source "${SCRIPT_DIR}/lib/storage.sh"' setup.sh | cut -d: -f1)"
[[ -n "$defaults_line" && -n "$storage_line" && "$defaults_line" -lt "$storage_line" ]] \
    || fail 'setup.sh must explicitly source defaults.sh before storage.sh'
pass 'setup.sh explicit defaults source precedes storage source'

migrate_main_body="$(extract_func lib/migrate.sh migrate_mode_main)"
! grep -Fq '_mv_parse_args' <<< "$migrate_main_body" \
    || fail 'migrate_mode_main must not parse migration CLI arguments'
! grep -Fq '_mv_resolve_args' <<< "$migrate_main_body" \
    || fail 'migrate_mode_main must not resolve migration CLI arguments'
[[ "$(grep -c '_mv_parse_args' utilities/setup-storage.sh)" == "1" ]] \
    || fail 'setup-storage migration entry path must call _mv_parse_args exactly once'
metadata_line="$(grep -n '^[[:space:]]*_ss_dispatch_metadata ' utilities/setup-storage.sh | cut -d: -f1)"
load_line="$(grep -n '^[[:space:]]*_ss_load_environment$' utilities/setup-storage.sh | cut -d: -f1)"
outer_parse_line="$(grep -n '^[[:space:]]*_parse_outer_args ' utilities/setup-storage.sh | cut -d: -f1)"
parse_line="$(grep -n '^[[:space:]]*_mv_parse_args ' utilities/setup-storage.sh | cut -d: -f1)"
resolve_line="$(grep -n '^[[:space:]]*_mv_resolve_args$' utilities/setup-storage.sh | cut -d: -f1)"
execute_line="$(grep -n '^[[:space:]]*migrate_mode_main$' utilities/setup-storage.sh | cut -d: -f1)"
[[ -n "$metadata_line" && -n "$load_line" && -n "$outer_parse_line" && -n "$resolve_line" && -n "$execute_line" \
    && "$metadata_line" -lt "$load_line" && "$load_line" -lt "$outer_parse_line" \
    && "$outer_parse_line" -lt "$parse_line" && "$parse_line" -lt "$resolve_line" && "$resolve_line" -lt "$execute_line" ]] \
    || fail 'setup-storage must dispatch metadata, load mode-appropriate env defaults, parse outer CLI, parse migration once, resolve, then execute'
pass 'migration parse/resolve/execute ownership is explicit'

out=$(bash <<'PROBE'
set -euo pipefail
PROJECT_ROOT="$PWD"
_VW_DEFAULT_STATE_DIR=/var/lib/vaultwarden
_VW_DEFAULT_DATA_MOUNT=/mnt/vw-data
DRY_RUN=false
log_info(){ :; }; log_warn(){ :; }; log_error(){ :; }; log_success(){ :; }; log_debug(){ :; }
require_commands(){ :; }
source lib/migrate.sh
_MV_DIRECTION=block-to-boot
_mv_parse_args run --source /var/lib/vaultwarden --target /mnt/vw-data
printf 'direction=%s source=%s target=%s\n' "$_MV_DIRECTION" "$_MV_SOURCE" "$_MV_TARGET"
PROBE
)
grep -Fxq 'direction=boot-to-block source=/var/lib/vaultwarden target=/mnt/vw-data' <<< "$out" \
    || fail "_MV_DIRECTION was not reset by parser initialization: $out"
pass 'migrate parser resets direction to boot-to-block'

out=$(bash <<'PROBE'
set -euo pipefail
PROJECT_ROOT="$PWD"
_VW_DEFAULT_STATE_DIR=/var/lib/vaultwarden
_VW_DEFAULT_DATA_MOUNT=/mnt/vw-data
DRY_RUN=false
log_info(){ :; }; log_warn(){ :; }; log_error(){ :; }; log_success(){ :; }; log_debug(){ :; }
require_commands(){ :; }
source lib/migrate.sh
_mv_parse_args run --direction block-to-boot --source /mnt/vw-data --target /var/lib/vaultwarden
printf 'direction=%s\n' "$_MV_DIRECTION"
PROBE
)
grep -Fxq 'direction=block-to-boot' <<< "$out" \
    || fail "--direction block-to-boot did not parse correctly: $out"
pass 'migrate parser preserves explicit block-to-boot direction'

out=$(bash <<'PROBE'
set -euo pipefail
PROJECT_ROOT="$PWD"
PROJECT_STATE_DIR=/var/lib/vaultwarden
_VW_DEFAULT_STATE_DIR=/var/lib/vaultwarden
_VW_DEFAULT_DATA_MOUNT=/mnt/vw-data
DRY_RUN=false
log_info(){ :; }; log_warn(){ :; }; log_error(){ :; }; log_success(){ :; }; log_debug(){ :; }
require_commands(){ :; }
source lib/migrate.sh
_mv_parse_args run --target /mnt/vw-data --yes
_mv_resolve_args
printf 'source=%s target=%s start=%s\n' "$_MV_SOURCE" "$_MV_TARGET" "$_MV_START_POLICY"
PROBE
)
grep -Fxq 'source=/var/lib/vaultwarden target=/mnt/vw-data start=auto' <<< "$out" \
    || fail "runtime resolver did not derive default source/start policy: $out"
pass 'runtime resolver derives source and start policy after parsing'

out=$(bash <<'PROBE'
set -euo pipefail
PROJECT_ROOT="$PWD"
_VW_DEFAULT_STATE_DIR=/var/lib/vaultwarden
_VW_DEFAULT_DATA_MOUNT=/mnt/vw-data
DRY_RUN=false
log_info(){ :; }; log_warn(){ :; }; log_error(){ :; }; log_success(){ :; }; log_debug(){ :; }
require_commands(){ :; }
findmnt(){
  [[ "$*" == "-n -o TARGET --source /dev/sdb" ]] && printf '/mnt/vw-data\n'
}
source lib/migrate.sh
_mv_parse_args run --direction block-to-boot --device /dev/sdb --target /var/lib/vaultwarden
_mv_resolve_args
printf 'source=%s direction=%s\n' "$_MV_SOURCE" "$_MV_DIRECTION"
PROBE
)
grep -Fxq 'source=/mnt/vw-data direction=block-to-boot' <<< "$out" \
    || fail "runtime resolver did not detect block-to-boot source mount: $out"
pass 'runtime resolver owns block-to-boot source mount detection'

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
grep -Fq 'sudo utilities/setup-storage.sh migrate run --device /dev/sdb --target /mnt/vw-data --force-format' <<< "$out" || fail "blank-device validation lacks sudo-safe example: $out"
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

check_setup_storage_ux_contracts() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
cd "$ROOT"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }
TMP="$(mktemp -d)"
metadata_env_created=false
cleanup_storage_setup_test(){
    rm -rf "$TMP"
    [[ "$metadata_env_created" != "true" ]] || rm -f "$ROOT/.env"
}
trap cleanup_storage_setup_test EXIT

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
awk '/setup-storage\.sh" setup/,/\|\| _phase_failed 2/' "$SETUP" | grep -Fq '"${_auto[@]}"' \
    || fail 'setup.sh phase 2 does not pass --auto to setup-storage'
pass 'setup.sh install --auto suppresses the storage assistant in phase 2'

# Full setup must not turn inherited/default storage values into explicit child
# overrides. The child tools own installed storage identity when flags are omitted.
FULL_SETUP_ROOT="$TMP/full-setup-rerun"
mkdir -p "$FULL_SETUP_ROOT/lib" "$FULL_SETUP_ROOT/utilities"
cp "$SETUP" "$ROOT/VERSION" "$FULL_SETUP_ROOT/"
while IFS= read -r required_lib; do
    [[ -n "$required_lib" ]] || continue
    mkdir -p "$FULL_SETUP_ROOT/$(dirname "$required_lib")"
    : > "$FULL_SETUP_ROOT/$required_lib"
done < <(
    sed -n '/^REQUIRED_LIBS=(/,/^)/p' "$FULL_SETUP_ROOT/setup.sh" \
        | sed -n 's/^[[:space:]]*"\([^"]*\.sh\)".*/\1/p'
)
cat > "$FULL_SETUP_ROOT/lib/log.sh" <<'FULL_SETUP_LOG'
COLOR_BOLD_RED=''; COLOR_RESET=''; COLOR_YELLOW=''; COLOR_RED=''; COLOR_CYAN=''; COLOR_GREEN=''
log_header(){ :; }; log_info(){ :; }; log_warn(){ :; }; log_success(){ :; }; log_phase(){ :; }; log_hint(){ :; }
log_error(){ printf 'ERROR: %s\n' "$*" >&2; }
FULL_SETUP_LOG
cat > "$FULL_SETUP_ROOT/lib/validate.sh" <<'FULL_SETUP_VALIDATE'
validate_domain(){ return 0; }
validate_email(){ return 0; }
FULL_SETUP_VALIDATE
cat > "$FULL_SETUP_ROOT/lib/common.sh" <<'FULL_SETUP_COMMON'
init_common_lib(){ :; }
is_root(){ return 0; }
_require_script(){ [[ -x "$1" ]]; }
press_enter_to_continue(){ :; }
FULL_SETUP_COMMON
cat > "$FULL_SETUP_ROOT/lib/operations.sh" <<'FULL_SETUP_OPERATIONS'
operation_acquire(){ return 0; }
operation_set_phase(){ return 0; }
operation_release(){ return 0; }
FULL_SETUP_OPERATIONS
cat > "$FULL_SETUP_ROOT/lib/crypto.sh" <<'FULL_SETUP_CRYPTO'
wait_for_entropy(){ return 0; }
FULL_SETUP_CRYPTO
cat > "$FULL_SETUP_ROOT/lib/secrets.sh" <<'FULL_SETUP_SECRETS'
secrets_file_exists(){ return 1; }
ensure_sops_env(){ return 0; }
check_placeholder_values(){ return 0; }
FULL_SETUP_SECRETS
printf '_VW_DEFAULT_DATA_MOUNT=/mnt/vw-data\n' > "$FULL_SETUP_ROOT/lib/defaults.sh"

cat > "$FULL_SETUP_ROOT/utilities/storage-child.sh" <<'FULL_SETUP_CHILD'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1090
source "${VW_SETUP_EXISTING_ENV:?}"
device="${DATA_VOLUME_DEVICE:-}"
mount="${DATA_VOLUME_MOUNT:-}"
args=("$@")
while (( $# > 0 )); do
    case "$1" in
        --data-device) device="$2"; shift 2 ;;
        --data-mount) mount="$2"; shift 2 ;;
        --domain|--email) shift 2 ;;
        *) shift ;;
    esac
done
case "${0##*/}" in
    setup-storage.sh) result="${VW_SETUP_STORAGE_RESULT:?}"; argv="${VW_SETUP_STORAGE_ARGS:?}" ;;
    setup-env.sh) result="${VW_SETUP_ENV_RESULT:?}"; argv="${VW_SETUP_ENV_ARGS:?}" ;;
    *) exit 2 ;;
esac
printf '%s|%s\n' "$device" "$mount" > "$result"
printf '%s\n' "${args[*]}" > "$argv"
FULL_SETUP_CHILD
cp "$FULL_SETUP_ROOT/utilities/storage-child.sh" "$FULL_SETUP_ROOT/utilities/setup-storage.sh"
cp "$FULL_SETUP_ROOT/utilities/storage-child.sh" "$FULL_SETUP_ROOT/utilities/setup-env.sh"
for utility in setup-system.sh setup-secrets.sh setup-firewall.sh setup-systemd.sh setup-crowdsec.sh uninstall-vaultwarden.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FULL_SETUP_ROOT/utilities/$utility"
done
chmod 0755 "$FULL_SETUP_ROOT/utilities/"*.sh
cat > "$FULL_SETUP_ROOT/.env" <<'FULL_SETUP_ENV'
PROJECT_STATE_DIR=/srv/vaultwarden-data
DATA_VOLUME_DEVICE=/dev/disk/by-id/existing-vaultwarden-data
DATA_VOLUME_MOUNT=/srv/vaultwarden-data
FULL_SETUP_ENV

if ! (
    cd "$FULL_SETUP_ROOT"
    unset DATA_VOLUME_DEVICE DATA_VOLUME_MOUNT PROJECT_STATE_DIR
    VW_SETUP_EXISTING_ENV="$FULL_SETUP_ROOT/.env" \
    VW_SETUP_STORAGE_RESULT="$FULL_SETUP_ROOT/storage.result" \
    VW_SETUP_STORAGE_ARGS="$FULL_SETUP_ROOT/storage.args" \
    VW_SETUP_ENV_RESULT="$FULL_SETUP_ROOT/env.result" \
    VW_SETUP_ENV_ARGS="$FULL_SETUP_ROOT/env.args" \
        bash ./setup.sh install --domain vault.example.test --email admin@example.test \
            --auto --skip-deps --dry-run >/dev/null 2>&1
); then
    fail 'full setup rerun fixture failed'
fi
expected_storage='/dev/disk/by-id/existing-vaultwarden-data|/srv/vaultwarden-data'
[[ "$(cat "$FULL_SETUP_ROOT/storage.result")" == "$expected_storage" ]] \
    || fail 'full setup rerun changed storage identity in setup-storage'
[[ "$(cat "$FULL_SETUP_ROOT/env.result")" == "$expected_storage" ]] \
    || fail 'full setup rerun changed storage identity in setup-env'
! grep -Eq '(^| )--data-(device|mount)( |$)' "$FULL_SETUP_ROOT/storage.args" "$FULL_SETUP_ROOT/env.args" \
    || fail 'full setup rerun forwarded an implicit storage flag'
pass 'full setup rerun preserves custom storage identity when storage flags are omitted'

# Help/unknown-option handling remains present.
grep -Fq -- '--help|-h)' "$STORAGE" || fail 'setup-storage help option handling missing'
grep -Fq 'Unknown option: $1' "$STORAGE" || fail 'setup-storage unknown-option handling missing'
grep -Fq 'setup-storage is run interactively' "$STORAGE" \
    || fail 'help text must mention interactive storage prompt'
grep -Fq -- '--auto suppresses the prompt' "$STORAGE" \
    || fail 'help text must mention --auto prompt suppression'
pass 'setup-storage help and unknown-option contracts remain documented'

run_storage() {
    set +e
    out="$(PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH" bash "$STORAGE" "$@" 2>&1)"
    status=$?
    set -e
}

run_storage setup --help
[[ "$status" -eq 0 && "$out" == *'sudo utilities/setup-storage.sh setup [OPTIONS]'* ]] \
    || fail "canonical setup help failed: $out"
run_storage verify --help
[[ "$status" -eq 0 && "$out" == *'sudo utilities/setup-storage.sh verify [OPTIONS]'* ]] \
    || fail "canonical verify help failed: $out"
run_storage migrate --help
[[ "$status" -eq 0 && "$out" == *'setup-storage.sh migrate <subcommand>'* ]] \
    || fail "canonical migrate help failed: $out"
run_storage --mode migrate --help
[[ "$status" -eq 0 && "$out" == *'setup-storage.sh migrate <subcommand>'* ]] \
    || fail "compatibility --mode migrate help failed: $out"
expected_version="VaultWarden-OCI $(tr -d '[:space:]' < "$ROOT/VERSION")"
run_storage migrate --version
[[ "$status" -eq 0 && "$out" == "$expected_version" ]] \
    || fail "canonical migrate --version failed: $out"
run_storage migrate -V
[[ "$status" -eq 0 && "$out" == "$expected_version" ]] \
    || fail "canonical migrate -V failed: $out"
run_storage --mode migrate --version
[[ "$status" -eq 0 && "$out" == "$expected_version" ]] \
    || fail "compatibility --mode migrate --version failed: $out"
run_storage --mode migrate -V
[[ "$status" -eq 0 && "$out" == "$expected_version" ]] \
    || fail "compatibility --mode migrate -V failed: $out"
run_storage setup verify
[[ "$status" -ne 0 && "$out" == *'Exactly one setup-storage mode is allowed'* ]] \
    || fail "setup-storage accepted multiple modes: $out"
run_storage setup --data-mount --force
[[ "$status" -ne 0 && "$out" == *'--data-mount requires a value'* ]] \
    || fail "setup-storage accepted missing --data-mount value: $out"
run_storage migrate status --target /tmp/foo
[[ "$status" -ne 0 && "$out" == *"Unknown option for 'status': --target"* && "$out" != *'This script must be run as root'* ]] \
    || fail "migrate status accepted --target: $out"
run_storage --mode migrate status --target /tmp/foo
[[ "$status" -ne 0 && "$out" == *"Unknown option for 'status': --target"* && "$out" != *'This script must be run as root'* ]] \
    || fail "compatibility migrate status accepted --target before parser contract: $out"
run_storage migrate status --force
[[ "$status" -ne 0 && "$out" == *"Unknown option for 'status': --force"* ]] \
    || fail "migrate status accepted --force: $out"
run_storage migrate abort --source /tmp/foo
[[ "$status" -ne 0 && "$out" == *"Unknown option for 'abort': --source"* ]] \
    || fail "migrate abort accepted --source: $out"
run_storage migrate verify --direction block-to-boot
[[ "$status" -ne 0 && "$out" == *"Unknown option for 'verify': --direction"* ]] \
    || fail "migrate verify accepted --direction: $out"
run_storage migrate resume --force-format --dry-run
[[ "$status" -ne 0 && "$out" != *'Unknown option'* && ( "$out" == *'This script must be run as root'* || "$out" == *'No state file found. Cannot resume.'* ) ]] \
    || fail "migrate resume rejected legitimate resume options before root/state guard: $out"
run_storage --mode migrate resume --force-format --dry-run
[[ "$status" -ne 0 && "$out" != *'Unknown option'* && ( "$out" == *'This script must be run as root'* || "$out" == *'No state file found. Cannot resume.'* ) ]] \
    || fail "compatibility --mode migrate rejected legitimate resume options before root/state guard: $out"

out=$(bash <<'PROBE'
set -euo pipefail
REPO_ROOT="$PWD"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
PROJECT_ROOT="$tmp/repo"
mkdir -p "$PROJECT_ROOT"
chmod 700 "$PROJECT_ROOT"
cat > "$PROJECT_ROOT/.env" <<'EOF_ENV'
_SS_MODE=verify
_SS_MODE_ARGS=environment-garbage
_SS_MIGRATE_ARGS=environment-garbage
DRY_RUN=false
_MV_DIRECTION=boot-to-block
_MV_FORCE=false
_MV_YES=false
DATA_VOLUME_DEVICE=/dev/disk/by-id/env-default
DATA_VOLUME_MOUNT=/mnt/env-default
EOF_ENV
chmod 600 "$PROJECT_ROOT/.env"
_VW_DEFAULT_STATE_DIR=/var/lib/vaultwarden
_VW_DEFAULT_DATA_MOUNT=/mnt/vw-data
source "$REPO_ROOT/lib/config.sh"
source "$REPO_ROOT/lib/migrate.sh"
_SS_MODE=setup
_SS_DATA_DEVICE="${DATA_VOLUME_DEVICE:-}"
_SS_DATA_MOUNT="${DATA_VOLUME_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}"
_SS_DATA_DEVICE_PROVIDED=false
_SS_DATA_MOUNT_PROVIDED=false
_SS_AUTO=false
_SS_FORCE=false
DRY_RUN=false
declare -a _SS_MODE_ARGS=()
declare -a _SS_MIGRATE_ARGS=()
log_error(){ printf 'ERR:%s\n' "$*" >&2; }
show_help(){ :; }
print_project_version(){ :; }
_require_cli_value(){
    local opt="$1" value="${2-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        log_error "$opt requires a value."
        exit 2
    fi
}
eval "$(awk '
  /^_ss_load_environment\(\)/ {p=1}
  /^_MV_SCRIPT_NAME=/ {p=0}
  p {print}
' "$REPO_ROOT/utilities/setup-storage.sh")"
eval "$(awk '
  /^_ss_dispatch_metadata\(\)/ {p=1}
  /^main\(\)/ {p=0}
  p {print}
' "$REPO_ROOT/utilities/setup-storage.sh")"

_ss_dispatch_metadata migrate status
_ss_load_environment
_parse_outer_args migrate status
_mv_parse_args "${_SS_MIGRATE_ARGS[@]}"
printf 'migrate-status mode=%s sub=%s args=%s\n' \
    "$_SS_MODE" "$_MV_SUBCOMMAND" "${_SS_MIGRATE_ARGS[*]}"

_SS_MODE=setup
_SS_MODE_ARGS=()
_SS_MIGRATE_ARGS=()
DRY_RUN=false
cat > "$PROJECT_ROOT/.env" <<'EOF_ENV'
_SS_MODE=verify
_SS_MODE_ARGS=environment-garbage
_SS_MIGRATE_ARGS=environment-garbage
DRY_RUN=false
_MV_DIRECTION=boot-to-block
_MV_FORCE=false
_MV_YES=false
DATA_VOLUME_DEVICE=/dev/disk/by-id/env-default
DATA_VOLUME_MOUNT=/mnt/env-default
EOF_ENV
_ss_dispatch_metadata migrate run --target /mnt/vw-data --dry-run --direction block-to-boot --force --yes
_ss_load_environment
_parse_outer_args migrate run --target /mnt/vw-data --dry-run --direction block-to-boot --force --yes
_mv_parse_args "${_SS_MIGRATE_ARGS[@]}"
printf 'migrate mode=%s sub=%s dry=%s direction=%s force=%s yes=%s target=%s\n' \
    "$_SS_MODE" "$_MV_SUBCOMMAND" "$DRY_RUN" "$_MV_DIRECTION" "$_MV_FORCE" "$_MV_YES" "$_MV_TARGET"

_SS_MODE=setup
_SS_MODE_ARGS=()
_SS_MIGRATE_ARGS=()
_SS_DATA_DEVICE="${DATA_VOLUME_DEVICE:-}"
_SS_DATA_MOUNT="${DATA_VOLUME_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}"
_SS_DATA_DEVICE_PROVIDED=false
_SS_DATA_MOUNT_PROVIDED=false
DRY_RUN=false
cat > "$PROJECT_ROOT/.env" <<'EOF_ENV'
_SS_MODE=migrate
_SS_MODE_ARGS=environment-garbage
_SS_MIGRATE_ARGS=environment-garbage
DRY_RUN=false
DATA_VOLUME_DEVICE=/dev/disk/by-id/env-default
DATA_VOLUME_MOUNT=/mnt/env-default
EOF_ENV
_ss_dispatch_metadata setup --data-device /dev/disk/by-id/cli-device --data-mount /mnt/cli --dry-run --auto --force
_ss_load_environment
_parse_outer_args setup --data-device /dev/disk/by-id/cli-device --data-mount /mnt/cli --dry-run --auto --force
_parse_setup_args
printf 'setup mode=%s dry=%s auto=%s force=%s device=%s mount=%s\n' \
    "$_SS_MODE" "$DRY_RUN" "$_SS_AUTO" "$_SS_FORCE" "$_SS_DATA_DEVICE" "$_SS_DATA_MOUNT"
PROBE
)
grep -Fxq 'migrate-status mode=migrate sub=status args=status' <<< "$out" \
    || fail "migrate status CLI mode/subcommand did not win over loaded environment mode collisions: $out"
grep -Fxq 'migrate mode=migrate sub=run dry=true direction=block-to-boot force=true yes=true target=/mnt/vw-data' <<< "$out" \
    || fail "migration CLI did not win over loaded environment defaults or mode collisions: $out"
grep -Fxq 'setup mode=setup dry=true auto=true force=true device=/dev/disk/by-id/cli-device mount=/mnt/cli' <<< "$out" \
    || fail "setup CLI did not win over loaded environment defaults or mode collisions: $out"
pass 'explicit setup-storage CLI state wins over loaded environment defaults'

[[ ! -e "$ROOT/.env" ]] || fail 'metadata environment-load regression needs no pre-existing .env'
metadata_env_created=true
printf 'PATH=/tmp/unsafe\n' > "$ROOT/.env"
run_storage migrate --help
[[ "$status" -eq 0 && "$out" == *'setup-storage.sh migrate <subcommand>'* && "$out" != *'refusing to overwrite dangerous variable'* ]] \
    || fail "migrate metadata loaded runtime environment: $out"
run_storage setup --version
[[ "$status" -eq 0 && "$out" == "$expected_version" ]] \
    || fail "setup metadata loaded runtime environment: $out"
run_storage --mode setup --help
[[ "$status" -eq 0 && "$out" == *'MODES:'* && "$out" != *'refusing to overwrite dangerous variable'* ]] \
    || fail "compatibility setup metadata loaded runtime environment: $out"
run_storage --mode migrate --version
[[ "$status" -eq 0 && "$out" == "$expected_version" ]] \
    || fail "compatibility migrate metadata loaded runtime environment: $out"
run_storage --mode verify -V
[[ "$status" -eq 0 && "$out" == "$expected_version" ]] \
    || fail "compatibility verify metadata loaded runtime environment: $out"
rm -f "$ROOT/.env"
metadata_env_created=false
pass 'setup-storage canonical and compatibility CLI grammar is enforced'

)

check_architecture_helpers() (
# Focused checks for architecture selection at artifact boundaries.

set -euo pipefail

PROJECT_ROOT="$VW_TEST_REPO_ROOT"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_output() {
    local expected="$1"
    shift
    local actual
    actual="$("$@")" || fail "command failed: $*"
    [[ "$actual" == "$expected" ]] || fail "expected '$expected', got '$actual' from: $*"
}

assert_fails() {
    if "$@" >/dev/null 2>&1; then
        fail "expected failure from: $*"
    fi
}

setup_system="${PROJECT_ROOT}/utilities/setup-system.sh"
setup_crowdsec="${PROJECT_ROOT}/utilities/setup-crowdsec.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

assert_output "http://archive.ubuntu.com/ubuntu" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" ubuntu-archive-url amd64
assert_output "http://ports.ubuntu.com/ubuntu-ports" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" ubuntu-archive-url arm64
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" ubuntu-archive-url armhf
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" ubuntu-archive-url s390x
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" ubuntu-archive-url unknown

assert_output "amd64" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-release-arch amd64
assert_output "arm64" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-release-arch arm64
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-release-arch armhf
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-release-arch s390x
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-release-arch riscv64
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-release-arch unknown

assert_output "yq_linux_amd64" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" yq-release-asset amd64
assert_output "yq_linux_arm64" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" yq-release-asset arm64
assert_output "fa52a4e758c63d38299163fbdd1edfb4c4963247918bf9c1c5d31d84789eded4" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" yq-release-sha256 amd64
assert_output "578648e463a11c1b6db6010cbf41eafed6bee79466fcffa1bb446672cf7945ea" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" yq-release-sha256 arm64
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" yq-release-asset armhf
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" yq-release-asset s390x
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" yq-release-asset unknown

assert_output "v3.13.2" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-default-version

write_os_release() {
    local file="$1"
    shift
    printf '%s\n' "$@" > "$file"
}

noble="$tmpdir/noble"
write_os_release "$noble" \
    'ID=ubuntu' \
    'VERSION_ID="24.04"' \
    'VERSION_CODENAME=noble' \
    'UBUNTU_CODENAME=noble'
assert_output "noble amd64" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$noble" amd64
assert_output "noble arm64" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$noble" arm64
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$noble" armhf
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$noble" s390x
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$noble" unknown

jammy="$tmpdir/jammy"
write_os_release "$jammy" 'ID=ubuntu' 'VERSION_ID="22.04"' 'VERSION_CODENAME=jammy' 'UBUNTU_CODENAME=jammy'
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$jammy" amd64
unsupported_ubuntu="$tmpdir/oracular"
write_os_release "$unsupported_ubuntu" 'ID=ubuntu' 'VERSION_ID="24.10"' 'VERSION_CODENAME=oracular'
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$unsupported_ubuntu" amd64
non_ubuntu="$tmpdir/debian"
write_os_release "$non_ubuntu" 'ID=debian' 'VERSION_ID="12"' 'VERSION_CODENAME=bookworm'
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$non_ubuntu" amd64
missing_id="$tmpdir/missing-id"
write_os_release "$missing_id" 'VERSION_ID="24.04"' 'VERSION_CODENAME=noble'
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$missing_id" amd64
missing_version="$tmpdir/missing-version"
write_os_release "$missing_version" 'ID=ubuntu' 'VERSION_CODENAME=noble'
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$missing_version" amd64
missing_codename="$tmpdir/missing-codename"
write_os_release "$missing_codename" 'ID=ubuntu' 'VERSION_ID="24.04"'
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$missing_codename" amd64
mismatch="$tmpdir/mismatch"
write_os_release "$mismatch" 'ID=ubuntu' 'VERSION_ID="24.04"' 'VERSION_CODENAME=jammy'
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$mismatch" amd64
codename_disagree="$tmpdir/codename-disagree"
write_os_release "$codename_disagree" 'ID=ubuntu' 'VERSION_ID="24.04"' 'VERSION_CODENAME=noble' 'UBUNTU_CODENAME=jammy'
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$codename_disagree" amd64

preflight_line="$(awk '/^[[:space:]]*validate_supported_host_preflight \|\| exit 1/{print NR; exit}' "$setup_system")"
swap_line="$(awk '/^[[:space:]]*create_swapfile$/{print NR; exit}' "$setup_system")"
deps_line="$(awk '/^[[:space:]]*install_dependencies$/{print NR; exit}' "$setup_system")"
[[ -n "$preflight_line" && -n "$swap_line" && -n "$deps_line" ]] \
    || fail "setup-system main flow markers missing"
(( preflight_line < swap_line )) \
    || fail "supported-host preflight must run before create_swapfile"
(( preflight_line < deps_line )) \
    || fail "supported-host preflight must run before install_dependencies"

if ! bash "$setup_system" --use-latest --sops-version v3.13.2 >/tmp/vw-sops-ambiguous.$$ 2>&1; then
    grep -Fq "cannot be combined" /tmp/vw-sops-ambiguous.$$ \
        || fail "ambiguous --use-latest + --sops-version failure message missing"
else
    fail "ambiguous --use-latest + --sops-version unexpectedly succeeded"
fi
rm -f /tmp/vw-sops-ambiguous.$$

make_yq_stub() {
    local path="$1" mode="$2" version="${3:-v4.53.3}"
    cat > "$path" <<EOF_STUB
#!/usr/bin/env bash
set -euo pipefail
mode="$mode"
version="$version"
if [[ "\${1:-}" == "--version" ]]; then
    case "\$mode" in
        mikefarah4|broken4) printf 'yq (https://github.com/mikefarah/yq/) version %s\n' "\$version" ;;
        mikefarah3) printf 'yq (https://github.com/mikefarah/yq/) version v3.4.1\n' ;;
        python) printf 'yq 3.1.0\n' ;;
    esac
    exit 0
fi
if [[ "\$mode" != "mikefarah4" ]]; then
    exit 1
fi
expr="\${2:-}"
case "\$expr" in
    .answer) printf 'plain-value\n' ;;
    '.secrets[] | select(.required == true) | .key') printf 'cloudflare_zone_id\n' ;;
    *) exit 1 ;;
esac
EOF_STUB
    chmod +x "$path"
}
make_yq_stub "$tmpdir/yq-good" mikefarah4 v4.53.3
make_yq_stub "$tmpdir/yq-older" mikefarah4 v4.52.9
make_yq_stub "$tmpdir/yq-newer" mikefarah4 v4.54.1
make_yq_stub "$tmpdir/yq-prefix" mikefarah4 v4.53.30
make_yq_stub "$tmpdir/yq-broken4" broken4 v4.53.3
make_yq_stub "$tmpdir/yq-python" python
make_yq_stub "$tmpdir/yq-v3" mikefarah3
env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" validate-yq "$tmpdir/yq-good" \
    || fail "Mike Farah yq v4 contract was rejected"
env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" validate-yq-exact "$tmpdir/yq-good" \
    || fail "exact pinned Mike Farah yq v4.53.3 contract was rejected"
assert_output "v4.53.3" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" yq-resolved-version "$tmpdir/yq-good"
for compatible_non_pinned in "$tmpdir/yq-older" "$tmpdir/yq-newer"; do
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" validate-yq "$compatible_non_pinned" \
        || fail "--skip-deps-compatible Mike Farah yq v4 was rejected: $compatible_non_pinned"
    assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" validate-yq-exact "$compatible_non_pinned"
done
assert_output "v4.53.30" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" yq-resolved-version "$tmpdir/yq-prefix"
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" validate-yq-exact "$tmpdir/yq-prefix"
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" validate-yq "$tmpdir/yq-python"
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" validate-yq "$tmpdir/yq-v3"
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" validate-yq "$tmpdir/yq-broken4"

make_sops_stub() {
    local path="$1" version_output="$2"
    cat > "$path" <<EOF_STUB
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "--version" ]]; then
    cat <<'EOF_VERSION'
${version_output}
EOF_VERSION
    exit 0
fi
exit 1
EOF_STUB
    chmod +x "$path"
}
make_sops_stub "$tmpdir/sops-good" 'sops 3.13.2'
make_sops_stub "$tmpdir/sops-good-v-prefix" 'sops version v3.13.2'
make_sops_stub "$tmpdir/sops-good-warn" 'sops 3.13.2
[warning] failed to retrieve latest version from upstream'
make_sops_stub "$tmpdir/sops-newer-patch" 'sops 3.13.20'
make_sops_stub "$tmpdir/sops-prerelease" 'sops 3.13.2-dev'
make_sops_stub "$tmpdir/sops-bad" 'not-sops 3.13.2'
assert_output "v3.13.2" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-version "$tmpdir/sops-good"
assert_output "v3.13.2" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-version "$tmpdir/sops-good-v-prefix"
assert_output "v3.13.2" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-version "$tmpdir/sops-good-warn"
assert_output "v3.13.20" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-version "$tmpdir/sops-newer-patch"
env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-version-equals "$tmpdir/sops-newer-patch" v3.13.20 \
    || fail "exact SOPS version comparison rejected the real installed version"
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-version-equals "$tmpdir/sops-newer-patch" v3.13.2
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-version "$tmpdir/sops-prerelease"
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-version "$tmpdir/sops-bad"

assert_output "amd64" env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_crowdsec" amd64
assert_output "amd64" env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_crowdsec" x86_64
assert_output "arm64" env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_crowdsec" arm64
assert_output "arm64" env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_crowdsec" aarch64
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_crowdsec" riscv64

# Missing Python modules must fail with an actionable package hint. The mock
# accepts Argon2 and rejects only bcrypt so the exact missing dependency path
# is exercised without changing the developer machine.
mkdir -p "$tmpdir/python-missing-bcrypt"
cat > "$tmpdir/python-missing-bcrypt/python3" <<'EOF_PYTHON_MISSING_BCRYPT'
#!/usr/bin/env bash
if [[ " $* " == *" import bcrypt "* ]]; then
    exit 1
fi
exit 0
EOF_PYTHON_MISSING_BCRYPT
chmod +x "$tmpdir/python-missing-bcrypt/python3"
if PATH="$tmpdir/python-missing-bcrypt:$PATH" \
    VAULTWARDEN_TEST_ARCH_HELPERS=1 \
    "$setup_system" verify-python-modules \
    >"$tmpdir/python-modules.out" 2>&1; then
    fail "missing python3-bcrypt unexpectedly passed dependency verification"
fi
grep -Fq 'python3-bcrypt is not installed or cannot be imported' "$tmpdir/python-modules.out" \
    || fail "missing python3-bcrypt error is unclear"
grep -Fq 'sudo apt-get install -y python3-bcrypt' "$tmpdir/python-modules.out" \
    || fail "missing python3-bcrypt install hint is absent"

printf 'Architecture helper tests passed.\n'

)

case "$MODE" in
    core)
        check_migration_storage_contracts
        check_setup_storage_ux_contracts
        ;;
    host-architecture)
        check_architecture_helpers
        ;;
    all)
        check_migration_storage_contracts
        check_setup_storage_ux_contracts
        check_architecture_helpers
        ;;
    *)
        printf 'FAIL: unknown VW_TEST_CASE_MODE for case-storage-setup.bash: %s\n' "$MODE" >&2
        exit 2
        ;;
esac
