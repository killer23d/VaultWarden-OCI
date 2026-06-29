#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail(){ echo "FAIL: $*" >&2; exit 1; }
pass(){ echo "PASS: $*"; }

source_migrate(){
  PROJECT_ROOT="$ROOT"
  _VW_DEFAULT_STATE_DIR=/var/lib/vaultwarden
  _VW_DEFAULT_DATA_MOUNT=/mnt/vw-data
  DRY_RUN=false
  log_info(){ :; }; log_warn(){ :; }; log_error(){ :; }; log_success(){ :; }; log_debug(){ :; }
  require_commands(){ :; }
  source "$ROOT/lib/migrate.sh"
}

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
marker="$(cat "$TGT/.vw-data-volume")"
chmod 600 "$TGT/.vw-data-volume"
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
