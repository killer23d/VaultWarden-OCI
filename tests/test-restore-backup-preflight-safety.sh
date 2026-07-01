#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESTORE="$ROOT/utilities/restore-run.sh"
BACKUP="$ROOT/utilities/backup-run.sh"
UTILS="$ROOT/lib/backup-utils.sh"
fail(){ echo "not ok - $*" >&2; exit 1; }
pass(){ echo "ok - $*"; }
require(){ local pat="$1" file="$2" msg="$3"; grep -Eq -- "$pat" "$file" || fail "$msg"; }
reject(){ local pat="$1" file="$2" msg="$3"; ! grep -Eq -- "$pat" "$file" || fail "$msg"; }

require 'inspect\)' "$RESTORE" 'restore must expose inspect subcommand'
require 'Inspect mode: skipping live project-state readiness enforcement' "$RESTORE" 'inspect must bypass live storage readiness enforcement'
require 'RESTORE_PREFLIGHT_SOURCE_ROOT' "$RESTORE" 'restore must retain preflight source root'
require 'source_root="\$\{RESTORE_PREFLIGHT_SOURCE_ROOT:-\$state_dir\}"' "$RESTORE" 'restore_full must use detected source root'
require 'Target preparation phase' "$RESTORE" 'target repair must run after confirmation as a separate phase'
require '_RESTORE_SAFETY_NET_RUNNING' "$RESTORE" 'safety net must be non-reentrant'
require 'Restore interrupted by operator \(Ctrl-C\)' "$RESTORE" 'Ctrl-C message must be explicit'
require 'older operational key or offline recovery key' "$RESTORE" 'age diagnostics must mention old/recovery key'
require 'db-age-decrypt.err' "$RESTORE" 'DB restore must capture age stderr'
require 'Cross-layout restore did not promote backups' "$RESTORE" 'cross-layout restore must keep allowlist conservative'
require '--exclude=\$\{state_dir#/\}/\.pre-restore-\*' "$BACKUP" 'state-dir pre-restore snapshots must be explicitly excluded'
require '_validate_full_archive_payload' "$BACKUP" 'post-tar validation helper must exist'
require 'project_state_dir=' "$BACKUP" 'full metadata must include project_state_dir'
require 'storage_mode=' "$BACKUP" 'full metadata must include storage_mode'
require 'awk -F=.*\^\[A-Za-z_\]' "$UTILS" 'metadata writer must keep valid key=value lines only'
reject '^[[:space:]]*\$additional_info$' "$UTILS" 'metadata writer must not heredoc additional_info with leading whitespace'

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HARNESS="$TMP/harness.sh"
cat > "$HARNESS" <<'HARNESS'
set -euo pipefail
log_info(){ :; }; log_warn(){ :; }; log_error(){ echo "$*" >&2; }; log_hint(){ :; }; log_success(){ :; }
get_config_value(){ case "$1" in DATA_VOLUME_MOUNT) printf '%s' "${TEST_DATA_VOLUME_MOUNT:-}";; DATA_VOLUME_DEVICE) printf '%s' "${TEST_DATA_VOLUME_DEVICE:-}";; *) printf '%s' "${2:-}";; esac; }
purge_wal_shm(){ :; }; tar_validate_members(){ :; }; check_traversal_only(){ :; }
SCRIPT_DIR="/home/ubuntu/VaultWarden-OCI"; PROJECT_ROOT="/home/ubuntu/VaultWarden-OCI"
RESTORE_TYPE="full"; FORCE="false"; INSPECT_ONLY="false"; SKIP_VERIFICATION="true"; RESTORE_ENV="false"; DRY_RUN="false"; DATA_VOLUME_MOUNT="${TEST_DATA_VOLUME_MOUNT:-}"; DATA_VOLUME_DEVICE="${TEST_DATA_VOLUME_DEVICE:-}"; PUID="$(id -u)"; PGID="$(id -g)"
HARNESS
sed -n '/^_tar_filter_for_file()/,/^tar_validate_members()/p' "$RESTORE" | sed '$d' >> "$HARNESS"
sed -n '/^restore_full()/,/^main()/p' "$RESTORE" | sed '$d' >> "$HARNESS"
cat >> "$HARNESS" <<'HARNESS'
_path_is_mountpoint(){ [[ "${TEST_MOUNTPOINTS:-}" == *":$1:"* ]]; }
make_tar(){ local root="$1" out="$2"; (cd "$root" && tar -czf "$out" .); }
run_preflight(){ local tarfile="$1" target="$2"; restore_full_preflight "$tarfile" "$tarfile" "$target" "$PUID" "$PGID" "relative" "2"; }
HARNESS

make_archive(){ local name="$1" member="$2"; local dir="$TMP/$name.root"; mkdir -p "$dir/$(dirname "$member")"; : > "$dir/$member"; bash -c "source '$HARNESS'; make_tar '$dir' '$TMP/$name.tar.gz'"; printf '%s' "$TMP/$name.tar.gz"; }
boot_tar=$(make_archive boot var/lib/vaultwarden/data/db.sqlite3)
block_tar=$(make_archive block mnt/vw-data/data/db.sqlite3)
snap_tar=$(make_archive snap mnt/vw-data/.pre-restore-20260630-050137/data/db.sqlite3)
config_tar=$(make_archive config mnt/vw-data/config/install.env)
repo_tar=$(make_archive repo home/ubuntu/VaultWarden-OCI/README.md)

bash -c "source '$HARNESS'; run_preflight '$boot_tar' /var/lib/vaultwarden" || fail 'same-layout boot preflight should pass'
if bash -c "source '$HARNESS'; run_preflight '$block_tar' /var/lib/vaultwarden" >"$TMP/blockboot.out" 2>&1; then fail 'block-source to boot-target must fail'; fi
grep -q 'Storage mismatch: backup appears to be from block storage' "$TMP/blockboot.out" || fail 'block-source failure must explain mismatch'
TEST_DATA_VOLUME_MOUNT="$TMP/mnt/vw-data" TEST_MOUNTPOINTS=":$TMP/mnt/vw-data:" bash -c "mkdir -p '$TMP/mnt/vw-data'; source '$HARNESS'; run_preflight '$boot_tar' '$TMP/mnt/vw-data'" || fail 'boot-source to mounted block target should pass preflight'
for t in "$snap_tar" "$config_tar" "$repo_tar"; do if bash -c "source '$HARNESS'; run_preflight '$t' /var/lib/vaultwarden" >/dev/null 2>&1; then fail "unsafe archive unexpectedly passed: $t"; fi; done

# Prove cross-layout restore reads from detected source root, not target path inside archive.
restore_root="$TMP/restore-root"; mkdir -p "$restore_root"
mkdir -p "$TMP/work"; cp "$boot_tar" "$TMP/work/$(basename "$boot_tar")"
TEST_DATA_VOLUME_MOUNT="$restore_root" TEST_MOUNTPOINTS=":$restore_root:" bash -c "source '$HARNESS'; RESTORE_PREFLIGHT_SOURCE_ROOT=/var/lib/vaultwarden; restore_full '$boot_tar' unused '$restore_root' '$UID' '$(id -g)' '$TMP/work' relative" || fail 'cross-layout restore should use source root and write target STATE_DIR'
[[ -f "$restore_root/data/db.sqlite3" ]] || fail 'cross-layout restore did not write data/db.sqlite3 into target state dir'
[[ ! -e "$restore_root/secrets" && ! -e "$restore_root/config" ]] || fail 'cross-layout restore promoted protected directories'

# Backup tar validation functional checks.
BH="$TMP/backup-harness.sh"
cat > "$BH" <<'BH'
set -euo pipefail
log_error(){ echo "$*" >&2; }; backup_log_warn(){ :; }
BH
sed -n '/^_validate_full_archive_payload()/,/^create_db_snapshot_host()/p' "$BACKUP" | sed '$d' >> "$BH"
state="$TMP/state"; mkdir -p "$state/data"; : > "$state/data/db.sqlite3"
badroot="$TMP/badroot"; mkdir -p "$badroot/${state#/}/.pre-restore-x/data"; : > "$badroot/${state#/}/.pre-restore-x/data/db.sqlite3"; (cd "$badroot" && tar -cf "$TMP/bad.tar" .)
if bash -c "source '$BH'; _validate_full_archive_payload '$TMP/bad.tar' '$state' '$ROOT' full" >/dev/null 2>&1; then fail 'snapshot-only DB must not satisfy backup validation'; fi
goodroot="$TMP/goodroot"; mkdir -p "$goodroot/${state#/}/data"; : > "$goodroot/${state#/}/data/db.sqlite3"; mkdir -p "$goodroot/${ROOT#/}"; (cd "$goodroot" && tar -cf "$TMP/good.tar" .)
bash -c "source '$BH'; _validate_full_archive_payload '$TMP/good.tar' '$state' '$ROOT' full" || fail 'live DB archive should pass backup validation'

# Metadata generation: create a sidecar and assert no malformed lines.
MH="$TMP/meta-harness.sh"
cat > "$MH" <<'MH'
set -euo pipefail
log_error(){ echo "$*" >&2; }; log_warn(){ :; }; log_debug(){ :; }
_stat_file_size(){ stat -c %s "$1"; }; calculate_sha256(){ sha256sum "$1" | awk '{print $1}'; }; require_docker(){ return 1; }
MH
sed -n '/^create_backup_metadata()/,/^_repair_sudo_user_rclone_config_permissions()/p' "$UTILS" | sed '$d' >> "$MH"
: > "$TMP/backup.age"
bash -c "source '$MH'; create_backup_metadata '$TMP/backup.age' full 'project_state_dir=/mnt/vw-data
storage_mode=block
data_volume_mount=/mnt/vw-data
data_volume_device=/dev/sdb
state_dir_is_mountpoint=true
repo_root=$ROOT
archive_format=relative
version=2
barebadline'"
awk 'NF && $0 !~ /^#/ && $0 !~ /^[A-Za-z_][A-Za-z0-9_]*=/ { bad=1 } END { exit bad }' "$TMP/backup.age.meta" || fail 'metadata contains malformed non key=value lines'
grep -q '^project_state_dir=' "$TMP/backup.age.meta" || fail 'metadata missing project_state_dir without leading whitespace'

bash -n "$RESTORE" "$BACKUP" "$UTILS"
pass 'restore/backup preflight safety functional checks'
printf '1..1\n'
