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

migrate_main_body="$(extract_func lib/migrate.sh migrate_mode_main)"
! grep -Fq '_mv_parse_args' <<< "$migrate_main_body" \
    || fail 'migrate_mode_main must not parse migration CLI arguments'
! grep -Fq '_mv_resolve_args' <<< "$migrate_main_body" \
    || fail 'migrate_mode_main must not resolve migration CLI arguments'
[[ "$(grep -c '_mv_parse_args' utilities/setup-storage.sh)" == "1" ]] \
    || fail 'setup-storage migration entry path must call _mv_parse_args exactly once'
load_line="$(grep -n '^[[:space:]]*_ss_load_runtime_environment$' utilities/setup-storage.sh | cut -d: -f1)"
parse_line="$(grep -n '^[[:space:]]*_mv_parse_args ' utilities/setup-storage.sh | cut -d: -f1)"
resolve_line="$(grep -n '^[[:space:]]*_mv_resolve_args$' utilities/setup-storage.sh | cut -d: -f1)"
execute_line="$(grep -n '^[[:space:]]*migrate_mode_main$' utilities/setup-storage.sh | cut -d: -f1)"
[[ -n "$load_line" && -n "$resolve_line" && -n "$execute_line" \
    && "$load_line" -lt "$parse_line" && "$parse_line" -lt "$resolve_line" && "$resolve_line" -lt "$execute_line" ]] \
    || fail 'setup-storage must load env defaults, parse once, resolve, then execute migration in order'
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

check_migration_storage_contracts
check_setup_storage_ux_contracts() (
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
[[ "$status" -ne 0 && "$out" == *'This script must be run as root'* && "$out" != *'Unknown option'* ]] \
    || fail "migrate resume rejected legitimate resume options before root guard: $out"
run_storage --mode migrate resume --force-format --dry-run
[[ "$status" -ne 0 && "$out" == *'This script must be run as root'* && "$out" != *'Unknown option'* ]] \
    || fail "compatibility --mode migrate rejected legitimate resume options before root guard: $out"

out=$(bash <<'PROBE'
set -euo pipefail
REPO_ROOT="$PWD"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
PROJECT_ROOT="$tmp/repo"
mkdir -p "$PROJECT_ROOT"
chmod 700 "$PROJECT_ROOT"
cat > "$PROJECT_ROOT/.env" <<'EOF_ENV'
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
  /^_ss_load_runtime_environment\(\)/ {p=1}
  /^_MV_SCRIPT_NAME=/ {p=0}
  p {print}
' "$REPO_ROOT/utilities/setup-storage.sh")"
eval "$(awk '
  /^_parse_outer_args\(\)/ {p=1}
  /^main\(\)/ {p=0}
  p {print}
' "$REPO_ROOT/utilities/setup-storage.sh")"

_parse_outer_args migrate run --target /mnt/vw-data --dry-run --direction block-to-boot --force --yes
_ss_load_runtime_environment
_mv_parse_args "${_SS_MIGRATE_ARGS[@]}"
printf 'migrate dry=%s direction=%s force=%s yes=%s target=%s\n' \
    "$DRY_RUN" "$_MV_DIRECTION" "$_MV_FORCE" "$_MV_YES" "$_MV_TARGET"

_SS_MODE=setup
_SS_MODE_ARGS=()
_SS_MIGRATE_ARGS=()
_SS_DATA_DEVICE="${DATA_VOLUME_DEVICE:-}"
_SS_DATA_MOUNT="${DATA_VOLUME_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}"
_SS_DATA_DEVICE_PROVIDED=false
_SS_DATA_MOUNT_PROVIDED=false
DRY_RUN=false
_parse_outer_args setup --data-device /dev/disk/by-id/cli-device --data-mount /mnt/cli --dry-run --auto --force
_ss_load_runtime_environment
_parse_setup_args
printf 'setup dry=%s auto=%s force=%s device=%s mount=%s\n' \
    "$DRY_RUN" "$_SS_AUTO" "$_SS_FORCE" "$_SS_DATA_DEVICE" "$_SS_DATA_MOUNT"
PROBE
)
grep -Fxq 'migrate dry=true direction=block-to-boot force=true yes=true target=/mnt/vw-data' <<< "$out" \
    || fail "migration CLI did not win over loaded environment defaults: $out"
grep -Fxq 'setup dry=true auto=true force=true device=/dev/disk/by-id/cli-device mount=/mnt/cli' <<< "$out" \
    || fail "setup CLI did not win over loaded environment defaults: $out"
pass 'explicit setup-storage CLI state wins over loaded environment defaults'

[[ ! -e "$ROOT/.env" ]] || fail 'metadata environment-load regression needs no pre-existing .env'
metadata_env_created=true
printf 'PATH=/tmp/unsafe\n' > "$ROOT/.env"
run_storage migrate --help
[[ "$status" -eq 0 && "$out" == *'setup-storage.sh migrate <subcommand>'* && "$out" != *'refusing to overwrite dangerous variable'* ]] \
    || fail "migrate metadata loaded runtime environment: $out"
run_storage --mode migrate --version
[[ "$status" -eq 0 && "$out" == "$expected_version" ]] \
    || fail "compatibility migrate metadata loaded runtime environment: $out"
rm -f "$ROOT/.env"
metadata_env_created=false
pass 'setup-storage canonical and compatibility CLI grammar is enforced'

)

check_setup_storage_ux_contracts
