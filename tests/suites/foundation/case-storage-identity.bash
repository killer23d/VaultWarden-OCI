#!/usr/bin/env bash
# Filesystem identity contract for dedicated VaultWarden data volumes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_fails() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$label unexpectedly succeeded"
    fi
}

UUID_A="11111111-2222-3333-4444-555555555555"
UUID_B="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
TMP="/tmp/vw_storage_identity_$$"
MOUNT="$TMP/mount"
MARKER="$MOUNT/.vw-data-volume"
DEVICE_A="/dev/vw-test-a"
DEVICE_RENAMED="/dev/disk/by-id/vw-test-renamed"
MOCK_MOUNT_UUID="$UUID_A"
MOCK_DEVICE_UUID="$UUID_A"
MOCK_MARKER_MODE=444
REAL_STAT="$(command -v stat)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$MOUNT"

is_root() { return 0; }
get_real_user() { printf 'root\n'; }
source lib/storage.sh

# Mock only the host discovery boundary. Marker file parsing/writing is real.
_storage_identity_read_mount_facts() {
    printf '/dev/current-node\n%s\n%s\n' "$MOCK_MOUNT_UUID" "$MOUNT"
}
_storage_identity_device_uuid() {
    printf '%s\n' "$MOCK_DEVICE_UUID"
}
chown() { return 0; }
chattr() { return 0; }
stat() {
    if [[ "${1:-}" == -c ]]; then
        case "${2:-}" in
            %u) printf '0\n'; return 0 ;;
            %g) printf '0\n'; return 0 ;;
            %a) printf '%s\n' "$MOCK_MARKER_MODE"; return 0 ;;
        esac
    fi
    "$REAL_STAT" "$@"
}

write_marker() {
    local uuid="$1" target="$2" device_context="${3:-$DEVICE_A}" operation="${4:-setup}"
    rm -f "$MARKER"
    cat > "$MARKER" <<EOF_MARKER
SIGNATURE=VaultWarden-OCI-data-volume
FORMAT=1
FILESYSTEM_UUID=$uuid
MOUNT_TARGET=$target
DEVICE_CONTEXT=$device_context
CREATED_AT=2026-08-10T12:00:00Z
OPERATION=$operation
EOF_MARKER
    chmod 0444 "$MARKER"
}

# Canonical setup writer produces an identity accepted by the validator and runtime readiness.
storage_write_volume_identity "$MOUNT" "$DEVICE_A" setup >/dev/null \
    || fail 'setup writer did not create an accepted marker'
storage_validate_volume_identity "$MOUNT" "$DEVICE_A" >/dev/null \
    || fail 'validator rejected canonical setup marker'
PROJECT_STATE_DIR="$MOUNT"
DATA_VOLUME_MOUNT="$MOUNT"
DATA_VOLUME_DEVICE="$DEVICE_A"
check_project_state_ready >/dev/null \
    || fail 'runtime readiness rejected canonical setup marker'

grep -Fxq "FILESYSTEM_UUID=$UUID_A" "$MARKER" || fail 'marker does not record filesystem UUID'
grep -Fxq "MOUNT_TARGET=$MOUNT" "$MARKER" || fail 'marker does not record mount target'
grep -Fxq 'FORMAT=1' "$MARKER" || fail 'marker does not record format version'

# Wrong filesystem at the correct target fails even when the marker itself is valid.
MOCK_MOUNT_UUID="$UUID_B"
MOCK_DEVICE_UUID="$UUID_A"
assert_fails 'wrong mounted filesystem' storage_validate_volume_identity "$MOUNT" "$DEVICE_A"

# A copied marker on another otherwise correctly configured filesystem fails.
MOCK_DEVICE_UUID="$UUID_B"
assert_fails 'copied marker on another filesystem' storage_validate_volume_identity "$MOUNT" "$DEVICE_A"

# Empty, malformed and wrong-target markers fail closed.
MOCK_MOUNT_UUID="$UUID_A"
MOCK_DEVICE_UUID="$UUID_A"
rm -f "$MARKER"
: > "$MARKER"
chmod 0444 "$MARKER"
assert_fails 'zero-byte marker' storage_validate_volume_identity "$MOUNT" "$DEVICE_A"

rm -f "$MARKER"
printf 'not-a-storage-identity\n' > "$MARKER"
chmod 0444 "$MARKER"
assert_fails 'malformed marker' storage_validate_volume_identity "$MOUNT" "$DEVICE_A"

write_marker "$UUID_A" /mnt/wrong-target
assert_fails 'wrong marker target' storage_validate_volume_identity "$MOUNT" "$DEVICE_A"

# Unsafe marker symlinks and permissions fail.
rm -f "$MARKER"
printf 'target\n' > "$TMP/symlink-target"
ln -s "$TMP/symlink-target" "$MARKER"
assert_fails 'symlink marker' storage_validate_volume_identity "$MOUNT" "$DEVICE_A"

write_marker "$UUID_A" "$MOUNT"
MOCK_MARKER_MODE=644
assert_fails 'unsafe marker mode' storage_validate_volume_identity "$MOUNT" "$DEVICE_A"
MOCK_MARKER_MODE=444

# Non-regular and multiply-linked marker paths fail validation and the writer
# refuses them before chattr/publication, leaving the existing object untouched.
rm -f "$MARKER"
mkdir "$MARKER"
assert_fails 'directory marker validation' storage_validate_volume_identity "$MOUNT" "$DEVICE_A"
assert_fails 'directory marker writer replacement' storage_write_volume_identity "$MOUNT" "$DEVICE_A" repair
[[ -d "$MARKER" ]] || fail 'directory marker was mutated by writer'
[[ -z "$(find "$MARKER" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'writer created content inside directory marker'
rmdir "$MARKER"

write_marker "$UUID_A" "$MOUNT"
ln "$MARKER" "$TMP/marker-hardlink"
assert_fails 'multiply-linked marker validation' storage_validate_volume_identity "$MOUNT" "$DEVICE_A"
assert_fails 'multiply-linked marker writer replacement' storage_write_volume_identity "$MOUNT" "$DEVICE_A" repair
[[ "$("$REAL_STAT" -c '%h' "$MARKER")" == 2 ]] || fail 'writer changed multiply-linked marker topology'
rm -f "$TMP/marker-hardlink" "$MARKER"

# A symlinked mount target is rejected before findmnt/blkid discovery.
ln -s "$MOUNT" "$TMP/mount-link"
assert_fails 'symlink mount target' _storage_identity_mount_facts "$TMP/mount-link"

# Device-node/path changes are allowed when they resolve to the same filesystem UUID.
write_marker "$UUID_A" "$MOUNT" "$DEVICE_A"
storage_validate_volume_identity "$MOUNT" "$DEVICE_RENAMED" >/dev/null \
    || fail 'same UUID through a different device path was rejected'

# Explicit adoption and recovery use the same writer and produce accepted markers.
rm -f "$MARKER"
storage_write_volume_identity "$MOUNT" "$DEVICE_A" adopt >/dev/null \
    || fail 'adoption writer did not create an accepted marker'
storage_validate_volume_identity "$MOUNT" "$DEVICE_A" >/dev/null \
    || fail 'validator rejected adoption-created marker'
grep -Fxq 'OPERATION=adopt' "$MARKER" || fail 'adoption metadata was not recorded'

rm -f "$MARKER"
storage_write_volume_identity "$MOUNT" "$DEVICE_RENAMED" recover >/dev/null \
    || fail 'recovery writer did not create an accepted marker'
DATA_VOLUME_DEVICE="$DEVICE_RENAMED"
check_project_state_ready >/dev/null \
    || fail 'runtime readiness rejected recovery-created marker'
grep -Fxq 'OPERATION=recover' "$MARKER" || fail 'recovery metadata was not recorded'

# A boot-to-block resume before the format/mount step may continue with the saved
# device and target, but once that step completed an absent mount must fail closed.
run_resume_mount_probe() (
    local format_done="$1"
    PROJECT_ROOT="$TMP/migrate-resume-$format_done"
    mkdir -p "$PROJECT_ROOT/source" "$PROJECT_ROOT/target"
    : > "$PROJECT_ROOT/docker-compose.yml"
    DRY_RUN=false
    source "$ROOT/lib/migrate.sh"

    _mv_state_write MV_SOURCE "$PROJECT_ROOT/source"
    _mv_state_write MV_TARGET "$PROJECT_ROOT/target"
    _mv_state_write MV_DEVICE /dev/vw-test-a
    _mv_state_write MV_SKIP_STACK_STOP false
    _mv_state_write MV_DELETE_SOURCE false
    _mv_state_write MV_FORCE_FORMAT false
    _mv_state_write MV_DIRECTION boot-to-block
    [[ "$format_done" != true ]] || _mv_state_write STEP_FORMAT_DONE true

    mountpoint() { return 1; }
    _mv_run_step() { :; }
    _mv_run_pipeline --resume >/dev/null 2>&1
)

run_resume_mount_probe false \
    || fail 'pre-format migration resume incorrectly required target to already be mounted'
assert_fails 'post-format migration resume without saved mount' run_resume_mount_probe true

# An already-mounted boot-to-block target must be a proven VaultWarden filesystem;
# skipping format cannot silently skip the identity gate.
run_mounted_target_format_probe() (
    local identity_ok="$1"
    PROJECT_ROOT="$TMP/migrate-format-$identity_ok"
    mkdir -p "$PROJECT_ROOT/source" "$PROJECT_ROOT/target"
    DRY_RUN=false
    source "$ROOT/lib/migrate.sh"
    _MV_LOG_FILE="$PROJECT_ROOT/migrate.log"
    _MV_DIRECTION=boot-to-block
    _MV_SOURCE="$PROJECT_ROOT/source"
    _MV_TARGET="$PROJECT_ROOT/target"
    _MV_DEVICE=/dev/vw-test-a

    mountpoint() { return 0; }
    storage_validate_volume_identity() { [[ "$identity_ok" == true ]]; }
    _mv_check_disk_space() { :; }
    _mv_step_format >/dev/null 2>&1
)

assert_fails 'mounted migration target with invalid identity' run_mounted_target_format_probe false
run_mounted_target_format_probe true \
    || fail 'mounted migration target with valid identity was rejected'

# Mounted boot-to-block targets are rejected during preflight, before the
# stack-stop step, and then revalidated again during format/target preparation.
run_mounted_target_identity_probe() (
    local identity_ok="$1"
    PROJECT_ROOT="$TMP/migrate-preflight-$identity_ok"
    mkdir -p "$PROJECT_ROOT/source" "$PROJECT_ROOT/target"
    DRY_RUN=false
    source "$ROOT/lib/migrate.sh"
    _MV_LOG_FILE="$PROJECT_ROOT/migrate.log"
    _MV_DIRECTION=boot-to-block
    _MV_SOURCE="$PROJECT_ROOT/source"
    _MV_TARGET="$PROJECT_ROOT/target"
    _MV_DEVICE=/dev/vw-test-a

    mountpoint() { return 0; }
    storage_validate_volume_identity() { [[ "$identity_ok" == true ]]; }
    _mv_validate_mounted_target_identity >/dev/null 2>&1
)

assert_fails 'mounted migration target passed preflight with invalid identity' \
    run_mounted_target_identity_probe false
run_mounted_target_identity_probe true \
    || fail 'mounted migration target with valid identity failed preflight'

mapfile -t mounted_target_gate_lines < <(grep -nF '_mv_validate_mounted_target_identity || return 1' lib/migrate.sh | cut -d: -f1)
[[ "${#mounted_target_gate_lines[@]}" -eq 2 ]] \
    || fail 'mounted target identity gate must run in both preflight and format steps'

validate_step_body="$(awk '/^_mv_step_validate\(\)/,/^}/' lib/migrate.sh)"
format_step_body="$(awk '/^_mv_step_format\(\)/,/^}/' lib/migrate.sh)"
grep -Fq '_mv_validate_mounted_target_identity || return 1' <<< "$validate_step_body" \
    || fail 'mounted target identity gate is not owned by migration preflight validation'
grep -Fq '_mv_validate_mounted_target_identity || return 1' <<< "$format_step_body" \
    || fail 'format step no longer revalidates mounted target identity'

pipeline_body="$(awk '/^_mv_run_pipeline\(\)/,/^}/' lib/migrate.sh)"
validate_dispatch_line="$(grep -nF '"STEP_VALIDATE_DONE:_mv_step_validate"' <<< "$pipeline_body" | head -1 | cut -d: -f1)"
stop_dispatch_line="$(grep -nF '"STEP_STOP_DONE:_mv_step_stop"' <<< "$pipeline_body" | head -1 | cut -d: -f1)"
[[ -n "$validate_dispatch_line" && -n "$stop_dispatch_line" ]] \
    || fail 'migration pipeline no longer exposes validate/stop dispatch ordering'
(( validate_dispatch_line < stop_dispatch_line )) \
    || fail 'mounted target preflight validation no longer runs before stack stop'

# Resume must re-prove identity even when the original validation checkpoint is saved.
run_resume_identity_probe() (
    local direction="$1" identity_ok="$2"
    PROJECT_ROOT="$TMP/migrate-resume-identity-$direction-$identity_ok"
    mkdir -p "$PROJECT_ROOT/source" "$PROJECT_ROOT/target"
    : > "$PROJECT_ROOT/docker-compose.yml"
    DRY_RUN=false
    source "$ROOT/lib/migrate.sh"

    _mv_state_write MV_SOURCE "$PROJECT_ROOT/source"
    _mv_state_write MV_TARGET "$PROJECT_ROOT/target"
    _mv_state_write MV_DEVICE /dev/vw-test-a
    _mv_state_write MV_SKIP_STACK_STOP false
    _mv_state_write MV_DELETE_SOURCE false
    _mv_state_write MV_FORCE_FORMAT false
    _mv_state_write MV_DIRECTION "$direction"
    _mv_state_write STEP_VALIDATE_DONE true
    [[ "$direction" != boot-to-block ]] || _mv_state_write STEP_FORMAT_DONE true

    mountpoint() {
        [[ "${1:-}" == -q ]] || return 1
        case "$direction" in
            boot-to-block) [[ "${2:-}" == "$PROJECT_ROOT/target" ]] ;;
            block-to-boot) [[ "${2:-}" == "$PROJECT_ROOT/source" ]] ;;
        esac
    }
    storage_validate_volume_identity() { [[ "$identity_ok" == true ]]; }
    _mv_run_step() { :; }
    _mv_run_pipeline --resume >/dev/null 2>&1
)

assert_fails 'boot-to-block resume accepted changed target identity' \
    run_resume_identity_probe boot-to-block false
run_resume_identity_probe boot-to-block true \
    || fail 'boot-to-block resume rejected proven target identity'
assert_fails 'block-to-boot resume accepted changed source identity' \
    run_resume_identity_probe block-to-boot false
run_resume_identity_probe block-to-boot true \
    || fail 'block-to-boot resume rejected proven source identity'

# Every material production manufacturer/consumer must delegate to the canonical identity contract.
grep -Fq 'storage_write_volume_identity "$mount_point" "$device" setup' lib/storage.sh \
    || fail 'setup does not use canonical identity writer'
grep -Fq 'storage_write_volume_identity "$STATE_DIR" "$DEVICE_PATH" recover' recover.sh \
    || fail 'recovery does not use canonical identity writer'
grep -Fq 'storage_write_volume_identity "$mount_point" "$device" recover' utilities/restore-run.sh \
    || fail 'restore does not use canonical identity writer'
grep -Fq 'storage_validate_volume_identity "${_MV_SOURCE}" "${_MV_DEVICE}"' lib/migrate.sh \
    || fail 'block-to-boot migration does not validate source filesystem identity'
grep -Fq 'storage_validate_volume_identity "${_MV_TARGET}" "${_MV_DEVICE}"' lib/migrate.sh \
    || fail 'boot-to-block migration does not validate mounted target filesystem identity'
grep -Fq 'storage_validate_volume_identity "$data_volume_mount" "$data_volume_device"' utilities/env-edit.sh \
    || fail 'env-edit status does not validate filesystem identity'
grep -Fq 'storage_validate_volume_identity "$DATA_VOLUME_MOUNT" "$DATA_VOLUME_DEVICE"' utilities/uninstall-vaultwarden.sh \
    || fail 'uninstall destructive volume proof does not validate filesystem identity'
grep -Fq 'storage_validate_volume_identity "$PROJECT_STATE_DIR" "$mounted_source"' utilities/uninstall-vaultwarden.sh \
    || fail 'uninstall mounted-source recovery does not validate filesystem identity'

# Scan every production shell source, not a hand-maintained consumer list. Tests are
# excluded because recovery/uninstall fixtures intentionally model legacy inputs.
mapfile -d '' -t production_shell_files < <(
    find . -type f \( -name '*.sh' -o -name '*.bash' \) \
        ! -path './tests/*' ! -path './.git/*' -print0
)
(( ${#production_shell_files[@]} > 0 )) || fail 'production shell inventory is empty'

if grep -Eq 'touch[[:space:]].*\.vw-data-volume|sudo touch[^[:cntrl:]]*\.vw-data-volume' "${production_shell_files[@]}"; then
    fail 'production source still manufactures .vw-data-volume with touch'
fi
if grep -Fq 'VaultWarden-OCI data volume' "${production_shell_files[@]}"; then
    fail 'legacy plaintext storage marker writer or authority remains in production source'
fi
if grep -Eq '_restore_ensure_volume_sentinel|_mv_find_sentinel_mount|sentinel_value\(\)' "${production_shell_files[@]}"; then
    fail 'legacy filename-authority storage helper remains in production source'
fi

# Resume must fail on an absent saved mount instead of retargeting from marker filenames.
grep -Fq 'Refusing to discover or rewrite MV_TARGET from marker filenames.' lib/migrate.sh \
    || fail 'migration resume no longer documents fail-closed saved-target behavior'

printf 'Storage filesystem identity tests passed.\n'
