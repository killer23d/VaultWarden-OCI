#!/usr/bin/env bash
# Consolidated restore and recovery regression suite.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

check_restore_run_contracts() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
SCRIPT="$ROOT/utilities/restore-run.sh"
fail(){ echo "not ok - $*" >&2; exit 1; }
pass(){ echo "ok - $*"; }

require_pattern(){ local pat="$1" msg="$2"; grep -Eq -- "$pat" "$SCRIPT" || fail "$msg"; }
reject_pattern(){ local pat="$1" msg="$2"; ! grep -Eq -- "$pat" "$SCRIPT" || fail "$msg"; }

require_pattern 'get_config_value "DATA_VOLUME_DEVICE" ""' 'restore-run must inspect DATA_VOLUME_DEVICE before readiness skip'
require_pattern 'FORCE.*USE_REMOTE.*-z "\$_configured_data_device"' 'force remote skip must be limited to no data device'
require_pattern 'require_project_state_ready \|\| exit 1' 'storage readiness must still be enforced'
pass 'restore-run refuses to skip storage readiness when DATA_VOLUME_DEVICE is configured'

require_pattern '^set -E[[:alpha:]-]*[[:space:]]+pipefail' 'restore-run must enable ERR trap inheritance for restore functions'
require_pattern "trap '_restore_safety_net \\$\?' ERR" 'restore-run must arm its error safety net around stopped-service restore work'
require_pattern "trap '_restore_safety_net 129' HUP" 'restore-run must preserve HUP status in the destructive safety net'
require_pattern "trap '_restore_safety_net 130' INT" 'restore-run must preserve INT status in the destructive safety net'
require_pattern "trap '_restore_safety_net 143' TERM" 'restore-run must preserve TERM status in the destructive safety net'
require_pattern 'bash "\$\{PROJECT_ROOT\}/startup.sh" --skip-pull' 'restore-run must invoke startup.sh --skip-pull'
reject_pattern 'docker compose up -d --remove-orphans' 'restore-run must not directly start docker compose'
pass 'restore-run invokes startup path instead of direct docker compose up'
pass 'restore-run enables safety-net restart path for restore function failures'

reject_pattern '-{2}no-unlink' 'restore-run must not pass unsupported tar no-unlink option'
pass 'restore-run avoids unsupported tar no-unlink option'

reject_pattern "find \"\$state_dir\" -maxdepth 1 -mindepth 1.*! -name '\\.pre-restore-\\*'" 'separate-volume restore must not snapshot every non-pre-restore top-level entry'
require_pattern '_restore_payload_allowlist=\(data caddy logs\)' 'separate-volume restore must use a conservative payload allowlist'
require_pattern '\.vw-data-volume, lost\+found, backups, secrets, config' 'separate-volume restore must log protected metadata paths'
require_pattern 'Archive backups/, secrets/, and config/.*intentionally not promoted|Promoted encrypted SOPS secrets' 'separate-volume restore must explicitly handle protected archive directories and SOPS secrets'
require_pattern '_moved_payload_paths=\(\)' 'separate-volume restore must track payload paths moved into the pre-restore snapshot'
require_pattern '_rollback_payload_paths' 'separate-volume restore must attempt rollback for payload paths already moved'
reject_pattern 'mv "\$_subdir" "\$\{_snap_dir\}/"' 'separate-volume restore must not blindly move discovered top-level entries'
pass 'restore-run protects separate-volume metadata and rolls back payload promotion failures'

require_pattern 'local install_env="\$\{STATE_DIR\}/config/install.env"' 'restore-run must target persistent install.env'
require_pattern 'SOPS_AGE_KEY_FILE=\$\{canonical_key\}.*\$install_env|written to \$install_env' 'restore-run must update SOPS_AGE_KEY_FILE in install.env'
pass 'restore-run updates state config install.env when key path changes'

require_pattern 'auto_fix_critical_permissions "\$PROJECT_ROOT"' 'restore-run must run final permission repair'
pass 'restore-run calls final permission repair before startup'

require_pattern '_rollback_rotation' 'restore-run must define transactional key-rotation rollback'
require_pattern 'refusing to start services automatically' 'restore-run must fail loudly before startup when key rotation fails'
require_pattern 'Post-promotion SOPS validation failed' 'restore-run must validate promoted rekey artifacts'
pass 'restore-run has rollback and fail-loud key rotation safeguards'

require_pattern 'RESTORE_DECRYPT_AGE_KEY_FILE="\$supplied_path"' 'restore-supplied key must be stored in restore-scoped variable'
require_pattern 'RESTORE_DECRYPT_AGE_KEY_FILE="\$configured_key"' 'blank Age prompt must use configured key as restore decrypt key'
require_pattern 'For normal same-server restore, press Enter to use the currently configured key' 'Age prompt must document Enter as same-server path'
require_pattern 'Only paste an AGE-SECRET-KEY-1\.\.\. value if this backup was encrypted' 'Age prompt must reserve pasted keys for old/offline keys'
require_pattern 'SOPS_AGE_KEY_FILE="\$operational_sops_age_key_file" "\$\{PROJECT_ROOT\}/utilities/backup-run\.sh" run emergency --quiet' 'pre-restore emergency snapshot must receive operational SOPS key explicitly'
require_pattern 'selected backup decrypt key: \$\{RESTORE_DECRYPT_AGE_KEY_FILE:-<not resolved>\}' 'preflight diagnostic must identify selected backup decrypt key separately'
require_pattern 'Fix current SOPS decryptability, or intentionally skip the safety snapshot with --no-backup' 'preflight diagnostic must explain --no-backup escape hatch'
reject_pattern 'local AGE_KEY_FILE; AGE_KEY_FILE="\$\(get_config_value "SOPS_AGE_KEY_FILE"' 'restore main must not use AGE_KEY_FILE for selected backup decrypt key'
pass 'restore-run separates restore decrypt key from operational SOPS key'

require_pattern 'SOPS_AGE_KEY_FILE="\$RESTORE_REKEY_SOURCE_AGE_KEY_FILE" sops --config "\$policy_tmp" updatekeys --yes "\$cipher_tmp"' 'SOPS updatekeys must use the restore rekey source selector'
require_pattern 'DB restores do not restore secrets.yaml' 'DB restore rekey source comment must explain use of the live operational key'
require_pattern 'RESTORE_REKEY_SOURCE_AGE_KEY_FILE="\$OPERATIONAL_SOPS_AGE_KEY_FILE"' 'DB and separate-volume restore must be able to use the live operational key'
require_pattern 'Full/emergency restores promote the encrypted' 'full/emergency rekey source comment must document promoted SOPS secrets'
require_pattern 'RESTORE_REKEY_SOURCE_AGE_KEY_FILE="\$RESTORE_DECRYPT_AGE_KEY_FILE"' 'full/emergency restore must use the selected backup decrypt key'
reject_pattern 'SOPS_AGE_KEY_FILE="\$RESTORE_DECRYPT_AGE_KEY_FILE" sops --config "\$policy_tmp" updatekeys' 'DB restore with different restore key must not unconditionally use restore decrypt key for updatekeys'
pass 'restore-run selects post-restore rekey source by restore type and storage mode'

bash -n "$SCRIPT"
pass 'bash -n utilities/restore-run.sh'
printf '1..11\n'

)

check_restore_run_contracts
check_restore_confirmation_safety() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
RESTORE="$ROOT/utilities/restore-run.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require() {
  grep -Eq -- "$1" "$2" || fail "$3"
}

reject_function() {
  local func="$1" pattern="$2" message="$3"
  ! awk -v fname="$func" -v pat="$pattern" '
    BEGIN { func_re = "^" fname "[(][)]" }
    $0 ~ func_re { in_func=1 }
    in_func && $0 ~ pat { found=1 }
    in_func && /^}/ { in_func=0 }
    END { exit found ? 0 : 1 }
  ' "$RESTORE" || fail "$message"
}

require 'RESTORE_PREVENT_AUTOSTART=false' "$RESTORE" \
  "restore must have a local flag that prevents automatic startup after prompt loss"
require 'RESTORE_PROMPT_TIMEOUT' "$RESTORE" \
  "restore confirmation prompts must use configurable bounded timeout"
require 'RESTORE_SAVED_ACK_ATTEMPTS' "$RESTORE" \
  "SAVED acknowledgement must have bounded retries"
require 'timeout/EOF is not treated as '\''no'\''' "$RESTORE" \
  "Age rotation timeout/EOF guidance must be explicit"
require '_restore_print_key_ack_abort_guidance' "$RESTORE" \
  "SAVED timeout/EOF must print manual key/startup guidance"
require 'Automatic service startup is disabled' "$RESTORE" \
  "restore safety net must honor prompt-loss no-autostart flag"
reject_function '_restore_should_rotate_age_key' 'answer="no"' \
  "Age rotation decision must not map timeout/EOF to no"
reject_function '_display_new_key' 'while \[\[ "\$_confirm" != "SAVED" \]\]' \
  "SAVED acknowledgement must not loop indefinitely"
require 'read -r -t .*RESTORE_SAVED_ACK_TIMEOUT' "$RESTORE" \
  "SAVED acknowledgement must use bounded timeout"
require 'Type SAVED' "$RESTORE" \
  "SAVED acknowledgement prompt must require explicit SAVED text"

printf 'PASS: restore confirmation safety\n'

)

check_restore_confirmation_safety
check_restore_preflight_and_cross_layout_safety() (
# shellcheck disable=SC2016
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
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
{
    sed -n '/^_tar_filter_for_file()/,/^tar_validate_members()/p' "$RESTORE" | sed '$d'
    sed -n '/^_stage_emergency_private_key_in_control_workspace()/,/^}/p' "$RESTORE"
    sed -n '/^restore_full()/,/^main()/p' "$RESTORE" | sed '$d'
} >> "$HARNESS"
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

bash -n "$RESTORE" "$BACKUP" "$UTILS"
pass 'restore/backup preflight safety functional checks'

)

check_restore_preflight_and_cross_layout_safety
check_restore_behavior_contracts() (
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
# Behavior: passphrase emergency decrypt must not pass -i; DR recipient identity may.
cat > "$TMP/decrypt-probe.sh" <<EOF_PROBE
set -euo pipefail
RESTORE_TYPE=emergency
BACKUP_FILE="$TMP/emergency.tar.zst.age"
EMERGENCY_BACKUP_AGE_IDENTITY_FILE="$TMP/dr-key.txt"
age(){ local output=""; printf '%s\n' "\$*" > "$TMP/age.args"; while (( \$# )); do if [[ "\$1" == -o ]]; then output="\${2:-}"; break; fi; shift; done; [[ -n "\$output" ]] && : > "\$output"; }
$(_extract_func "$ROOT/utilities/restore-run.sh" _age_decrypt_restore_backup)
: > "\$BACKUP_FILE"; : > "\$EMERGENCY_BACKUP_AGE_IDENTITY_FILE"
_age_decrypt_restore_backup "\$BACKUP_FILE" ignored "$TMP/out.tar.zst" "$TMP/err" age-passphrase || exit 1
! grep -q -- ' -i ' "$TMP/age.args" || exit 2
grep -q -- '-o ' "$TMP/age.args" || exit 3
_age_decrypt_restore_backup "\$BACKUP_FILE" ignored "$TMP/out2.tar.zst" "$TMP/err2" age-recipient || exit 4
grep -q -- "-i \$EMERGENCY_BACKUP_AGE_IDENTITY_FILE" "$TMP/age.args" || exit 5
EOF_PROBE
bash "$TMP/decrypt-probe.sh" || fail 'emergency decrypt helper did not implement passphrase/DR recipient behavior'

# Restore destructive confirmation must use shared default-no helper and preserve automation/non-interactive gates.
grep -Fq 'operator_attention warn "Destructive restore confirmation"' "$ROOT/utilities/restore-run.sh" || fail 'restore destructive context does not use operator_attention'
grep -Fq 'operator_confirm_yes_no "Proceed with destructive restore?" "no" 300' "$ROOT/utilities/restore-run.sh" || fail 'restore destructive confirmation is not explicit default-no timed yes/no helper'
grep -Fq 'if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" && "$INSPECT_ONLY" != "true" ]]' "$ROOT/utilities/restore-run.sh" || fail 'restore confirmation no longer preserves force/dry-run/inspect bypass gate'
grep -Fq 'stdin is not a TTY' "$ROOT/utilities/restore-run.sh" || fail 'restore confirmation no longer fails closed for non-TTY stdin'
grep -Fq 'Re-run with --force for non-interactive restore' "$ROOT/utilities/restore-run.sh" || fail 'restore confirmation no longer documents --force automation path'
grep -Fq 'Restore cancelled' "$ROOT/utilities/restore-run.sh" || fail 'restore cancellation message missing'

# Behavior-ish: restore code promotes SOPS secrets and skips runtime secrets explicitly.
grep -q 'Promoted encrypted SOPS secrets' "$ROOT/utilities/restore-run.sh" || fail 'restore lacks SOPS promotion log'
grep -q 'Skipped runtime decrypted secrets' "$ROOT/utilities/restore-run.sh" || fail 'restore lacks runtime secret skip log'

)

check_restore_behavior_contracts
check_restore_payload_staging_contracts() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
RESTORE="$ROOT/utilities/restore-run.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

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

! grep -q 'TMPDIR_RESTORE' "$RESTORE" || fail 'large restore payloads still reference the single legacy tmpfs workspace'
grep -Fq 'local dec_db="$PAYLOAD_WORKSPACE/db.sqlite3"' "$RESTORE" || fail 'DB decryption is not target-filesystem staged'
grep -Fq 'local pull_dir="$PAYLOAD_WORKSPACE/remote_pull"' "$RESTORE" || fail 'remote encrypted downloads are not payload-staged'
grep -Fq 'local age_err="$control_workspace/age-decrypt.err"' "$RESTORE" || fail 'full-restore diagnostics are not control-staged'
grep -Fq 'local staged_key_file="$CONTROL_WORKSPACE/key_stage/restore-age-key.txt"' "$RESTORE" || fail 'pasted keys are not control-staged'
# Secure placement, exact cleanup, cleanup refusal, and signal status/release.
cat > "$TMP/workspace-probe.sh" <<EOF_PROBE
set -euo pipefail
log_info(){ :; }; log_warn(){ printf 'WARN %s\\n' "\$*"; }; log_error(){ printf 'ERROR %s\\n' "\$*" >&2; }
get_config_value(){ [[ "\$1" == DATA_VOLUME_DEVICE ]] && printf '%s' "\${TEST_DEVICE:-}" || printf '%s' "\${2:-}"; }
TEST_MOUNTPOINT=""
_path_is_mountpoint(){ [[ "\$TEST_MOUNTPOINT" == "\$1" ]]; }
operation_release(){ printf '%s\\n' "\$1" >> "$TMP/releases"; }
CONTROL_WORKSPACE=""; CONTROL_WORKSPACE_ID=""; PAYLOAD_WORKSPACE=""; PAYLOAD_WORKSPACE_ID=""
PROMOTION_WORKSPACE=""; PROMOTION_WORKSPACE_ID=""
RESTORE_RETAIN_PAYLOAD=false; RESTORE_RETAIN_REASON=""
RESTORE_CLEANUP_DONE=false
$(_extract_func "$RESTORE" _restore_workspace_identity)
$(_extract_func "$RESTORE" _restore_workspace_is_owned)
$(_extract_func "$RESTORE" _restore_create_owned_workspace)
$(_extract_func "$RESTORE" _restore_remove_owned_workspace)
$(_extract_func "$RESTORE" _restore_log_retained_workspace)
$(_extract_func "$RESTORE" _restore_log_retained_payload)
$(_extract_func "$RESTORE" _restore_retain_payload_for_manual_recovery)
$(_extract_func "$RESTORE" cleanup)
$(_extract_func "$RESTORE" _restore_signal_exit)
$(_extract_func "$RESTORE" _restore_exit_cleanup)
$(_extract_func "$RESTORE" _restore_payload_parent)
$(_extract_func "$RESTORE" _restore_create_payload_workspace)

mkdir -p "$TMP/control-parent" "$TMP/boot/state"
_restore_create_owned_workspace CONTROL_WORKSPACE CONTROL_WORKSPACE_ID "$TMP/control-parent" control
_restore_create_payload_workspace "$TMP/boot/state"
[[ "\$(dirname "\$PAYLOAD_WORKSPACE")" == "$TMP/boot" ]] || exit 10
[[ "\$PAYLOAD_WORKSPACE" != "$TMP/boot/state"/* ]] || exit 11
[[ "\$(stat -c %a "\$CONTROL_WORKSPACE")" == 700 && "\$(stat -c %a "\$PAYLOAD_WORKSPACE")" == 700 ]] || exit 12
[[ "\$(stat -c %u "\$CONTROL_WORKSPACE")" == "\$EUID" && "\$(stat -c %u "\$PAYLOAD_WORKSPACE")" == "\$EUID" ]] || exit 13
control_saved="\$CONTROL_WORKSPACE"; payload_saved="\$PAYLOAD_WORKSPACE"
printf nearby > "$TMP/boot/nearby.keep"
cleanup 0
[[ ! -e "\$control_saved" && ! -e "\$payload_saved" && -f "$TMP/boot/nearby.keep" ]] || exit 14

CONTROL_WORKSPACE=""; CONTROL_WORKSPACE_ID=""; PAYLOAD_WORKSPACE=""; PAYLOAD_WORKSPACE_ID=""
PROMOTION_WORKSPACE=""; PROMOTION_WORKSPACE_ID=""
RESTORE_RETAIN_PAYLOAD=false; RESTORE_RETAIN_REASON=""
RESTORE_CLEANUP_DONE=false
mkdir -p "$TMP/mounted"
TEST_MOUNTPOINT="$TMP/mounted"
_restore_create_owned_workspace CONTROL_WORKSPACE CONTROL_WORKSPACE_ID "$TMP/control-parent" cleanup-control
_restore_create_payload_workspace "$TMP/mounted"
[[ "\$(dirname "\$PAYLOAD_WORKSPACE")" == "$TMP/mounted" ]] || exit 15
[[ "\$(basename "\$PAYLOAD_WORKSPACE")" == .vaultwarden-restore-payload.* ]] || exit 16
case "\$(basename "\$PAYLOAD_WORKSPACE")" in data|caddy|logs|backups|secrets|config) exit 17;; esac
control_saved="\$CONTROL_WORKSPACE"; payload_saved="\$PAYLOAD_WORKSPACE"
chmod 0755 "\$control_saved" "\$payload_saved"
set +e; ( _restore_exit_cleanup 0 ); cleanup_rc=\$?; set -e
[[ "\$cleanup_rc" -eq 1 && -d "\$control_saved" && -d "\$payload_saved" ]] || exit 18
chmod 0700 "\$control_saved" "\$payload_saved"
rm -rf -- "\$control_saved" "\$payload_saved"

(
  CONTROL_WORKSPACE=""; CONTROL_WORKSPACE_ID=""; PAYLOAD_WORKSPACE=""; PAYLOAD_WORKSPACE_ID=""
  PROMOTION_WORKSPACE=""; PROMOTION_WORKSPACE_ID=""
  RESTORE_RETAIN_PAYLOAD=false; RESTORE_RETAIN_REASON=""
  RESTORE_CLEANUP_DONE=false
  TEST_MOUNTPOINT=""
  mktemp(){ return 1; }
  if _restore_create_payload_workspace "$TMP/boot/state"; then exit 181; fi
  [[ -z "\$PAYLOAD_WORKSPACE" && -z "\$PAYLOAD_WORKSPACE_ID" ]] || exit 182
)

CONTROL_WORKSPACE=""; CONTROL_WORKSPACE_ID=""; PAYLOAD_WORKSPACE=""; PAYLOAD_WORKSPACE_ID=""
PROMOTION_WORKSPACE=""; PROMOTION_WORKSPACE_ID=""
RESTORE_RETAIN_PAYLOAD=false; RESTORE_RETAIN_REASON=""
RESTORE_CLEANUP_DONE=false
TEST_MOUNTPOINT=""
_restore_create_owned_workspace CONTROL_WORKSPACE CONTROL_WORKSPACE_ID "$TMP/control-parent" signal-control
_restore_create_payload_workspace "$TMP/boot/state"
printf '%s\\n%s\\n' "\$CONTROL_WORKSPACE" "\$PAYLOAD_WORKSPACE" > "$TMP/signal-paths"
set +e
( _restore_signal_exit 143 )
signal_rc=\$?
set -e
[[ "\$signal_rc" -eq 143 ]] || exit 19
while IFS= read -r path; do [[ ! -e "\$path" ]] || exit 20; done < "$TMP/signal-paths"
[[ "\$(tail -1 "$TMP/releases")" == 143 ]] || exit 21
EOF_PROBE
bash "$TMP/workspace-probe.sh" >"$TMP/workspace.out" 2>&1 || { cat "$TMP/workspace.out" >&2; fail 'secure workspace placement/cleanup probe failed'; }
grep -q 'Refusing to clean unverified, replaced, or permission-mismatched payload workspace' "$TMP/workspace.out" || fail 'cleanup mismatch refusal was not reported'

# Capacity failure must short-circuit before the modeled service stop.
cat > "$TMP/capacity-probe.sh" <<EOF_PROBE
set -euo pipefail
log_info(){ :; }; log_error(){ printf 'ERROR %s\\n' "\$*" >&2; }
df(){ printf 'Filesystem 1-blocks Used Available Use%% Mounted on\\nmock 4096 3072 1024 75%% /mock\\n'; }
docker(){ : > "$TMP/capacity-stop.called"; }
$(_extract_func "$RESTORE" _restore_require_available_bytes)
mkdir -p "$TMP/capacity-target"
if _restore_require_available_bytes "$TMP/capacity-target" 2048 payload; then docker compose stop; exit 30; fi
[[ ! -e "$TMP/capacity-stop.called" ]] || exit 31
EOF_PROBE
bash "$TMP/capacity-probe.sh" >"$TMP/capacity.out" 2>&1 || fail 'insufficient-space preflight probe failed'
grep -q 'Services were not stopped' "$TMP/capacity.out" || fail 'capacity failure did not state that services remain untouched'

# Raw private-key recovery paths must normalize the file before shared validation.
cat > "$TMP/raw-key-probe.sh" <<EOF_PROBE
set -euo pipefail
CONTROL_WORKSPACE="$TMP/key-control"; mkdir -m 700 -p "\$CONTROL_WORKSPACE"
RECOVERY_KIT_FILE="$TMP/recovery-kit.txt"; RESTORE_RECOVERY_KIT_FILE=""
KEY_FILE_ARG=""; RESTORE_AGE_KEY_FILE=""; RESTORE_DECRYPT_AGE_KEY_FILE=""
DRY_RUN=false
RAW_KEY='AGE-SECRET-KEY-1PRIVATEKEYMATERIAL'
PUBLIC_KEY='age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
log_info(){ printf 'INFO %s\n' "\$*"; }; log_warn(){ printf 'WARN %s\n' "\$*"; }; log_error(){ printf 'ERROR %s\n' "\$*" >&2; }; log_success(){ printf 'SUCCESS %s\n' "\$*"; }; log_debug(){ :; }
_age_key_countdown(){ sleep 30; }
has_command(){ [[ "\$1" == age ]]; }
_stat_octal_perms(){ stat -c '%a' "\$1"; }
age-keygen(){
  [[ "\${1:-}" == -y && -f "\${2:-}" ]] || return 1
  grep -qxF "\$RAW_KEY" "\$2" || return 1
  printf '%s\n' "\$PUBLIC_KEY"
}
age(){
  local output="" arg
  if [[ "\${1:-}" == -d ]]; then cat "\${!#}"; return; fi
  while (( \$# )); do
    arg="\$1"; shift
    if [[ "\$arg" == -o ]]; then output="\${1:-}"; shift; fi
  done
  [[ -n "\$output" ]] || return 1
  cat > "\$output"
}
$(_extract_func "$ROOT/lib/crypto.sh" _derive_age_public_key)
$(_extract_func "$ROOT/lib/crypto.sh" check_age_key)
$(_extract_func "$RESTORE" _stage_restore_age_key_line)
$(_extract_func "$RESTORE" _load_recovery_kit)
$(_extract_func "$RESTORE" _prompt_age_key)

assert_normalized(){
  local key_file="\$1"
  [[ -f "\$key_file" && "\$(stat -c %a "\$key_file")" == 600 ]] || return 1
  grep -qxF "# public key: \$PUBLIC_KEY" "\$key_file" || return 1
  grep -qxF "\$RAW_KEY" "\$key_file"
}

case "\${1:-kit}" in
  kit)
    printf '%s\n' "\$RAW_KEY" > "\$RECOVERY_KIT_FILE"; chmod 600 "\$RECOVERY_KIT_FILE"
    _load_recovery_kit
    [[ "\$KEY_FILE_ARG" == "\$CONTROL_WORKSPACE/kit_stage/recovery-kit-age-key.txt" ]]
    assert_normalized "\$KEY_FILE_ARG"
    ;;
  paste)
    _prompt_age_key "$TMP/missing-configured-key.txt"
    [[ "\$RESTORE_DECRYPT_AGE_KEY_FILE" == "\$CONTROL_WORKSPACE/key_stage/restore-age-key.txt" ]]
    assert_normalized "\$RESTORE_DECRYPT_AGE_KEY_FILE"
    ;;
  *) exit 2 ;;
esac
EOF_PROBE
bash "$TMP/raw-key-probe.sh" kit >"$TMP/raw-key-kit.out" 2>&1 \
  || { cat "$TMP/raw-key-kit.out" >&2; fail 'raw recovery-kit Age key was not normalized and accepted'; }
! grep -Fq 'PRIVATEK' "$TMP/raw-key-kit.out" \
  || fail 'recovery-kit output exposed private Age key material'
printf '%s\n' 'AGE-SECRET-KEY-1PRIVATEKEYMATERIAL' \
  | script -qfec "bash '$TMP/raw-key-probe.sh' paste" /dev/null >"$TMP/raw-key-paste.out" 2>&1 \
  || { cat "$TMP/raw-key-paste.out" >&2; fail 'pasted raw Age key was not normalized and accepted'; }

# Local/remote DB and full payloads, remote sidecars, and emergency private-key separation.
cat > "$TMP/payload-flow-probe.sh" <<EOF_PROBE
set -euo pipefail
PAYLOAD_WORKSPACE="$TMP/payload"; CONTROL_WORKSPACE="$TMP/control"; mkdir -p "\$PAYLOAD_WORKSPACE" "\$CONTROL_WORKSPACE"
RCLONE_CONFIG_ARG=(); BACKUP_FILE=""; RESTORE_TYPE=""; STATE_DIR="$TMP/state"; mkdir -p "\$STATE_DIR/data"
SKIP_VERIFICATION=false; EMERGENCY_BACKUP_AGE_IDENTITY_FILE=""; RESTORE_EMERGENCY_STAGED_KEY_FILE=""
log_info(){ :; }; log_error(){ printf 'ERROR %s\\n' "\$*" >&2; }; log_hint(){ :; }; log_warn(){ :; }
check_archive_dependencies(){ return 0; }; _restore_require_available_bytes(){ return 0; }
verify_sqlite(){ return 0; }; _restore_preflight_db_commit_capacity(){ return 0; }
sqlite3(){ printf '1\\n'; }
age(){
  local out="" input="\${!#}"
  while (( \$# )); do [[ "\$1" == -o ]] && { out="\$2"; shift; }; shift; done
  printf sqlite > "\$out"; printf '%s\\n' "\$input" >> "$TMP/db-inputs"
}
rclone(){
  local cmd="\$1"; shift
  if [[ "\$cmd" == lsl ]]; then printf '128 2026-08-05 12:00:00.000000000 %s\\n' "\$(basename "\$1")"; return 0; fi
  [[ "\$cmd" == copy ]] || return 1
  local src="\$1" dest="\$2"; mkdir -p "\$dest"
  printf remote > "\$dest/\$(basename "\$src")"
}
$(_extract_func "$RESTORE" pull_remote_backup)
$(_extract_func "$RESTORE" _stage_db_restore_for_preflight)
$(_extract_func "$RESTORE" _decrypt_restore_archive_for_preflight)
$(_extract_func "$RESTORE" _stage_emergency_private_key_in_control_workspace)
_restore_backup_encryption_mode(){ printf '%s' age-recipient; }
_age_decrypt_restore_backup(){ printf archive > "\$3"; printf '%s\\n' "\$1" >> "$TMP/full-inputs"; }
_restore_age_no_identity_guidance(){ :; }

rm -rf "\$PAYLOAD_WORKSPACE/remote_pull"
for kind in db full; do
  pull_remote_backup "mock:backups/\$kind/\$kind.tar.zst.age" "\$kind"
  [[ "\$BACKUP_FILE" == "\$PAYLOAD_WORKSPACE/remote_pull/\$kind.tar.zst.age" ]] || exit 40
  for suffix in .sha256 .meta; do [[ -f "\${BACKUP_FILE}\${suffix}" ]] || exit 41; done
done

printf local > "$TMP/local-db.age"
rm -f "\$PAYLOAD_WORKSPACE/db.sqlite3"
_stage_db_restore_for_preflight "$TMP/local-db.age" key "\$STATE_DIR"
[[ -f "\$PAYLOAD_WORKSPACE/db.sqlite3" ]] || exit 42
remote_db="\$PAYLOAD_WORKSPACE/remote_pull/db.tar.zst.age"
rm -f "\$PAYLOAD_WORKSPACE/db.sqlite3"
_stage_db_restore_for_preflight "\$remote_db" key "\$STATE_DIR"
[[ -f "\$PAYLOAD_WORKSPACE/db.sqlite3" ]] || exit 43
grep -qxF "$TMP/local-db.age" "$TMP/db-inputs" || exit 44
grep -qxF "\$remote_db" "$TMP/db-inputs" || exit 45

printf local > "$TMP/local-full.tar.zst.age"
local_dec="\$(_decrypt_restore_archive_for_preflight "$TMP/local-full.tar.zst.age" key "\$PAYLOAD_WORKSPACE" "\$CONTROL_WORKSPACE")"
remote_full="\$PAYLOAD_WORKSPACE/remote_pull/full.tar.zst.age"
remote_dec="\$(_decrypt_restore_archive_for_preflight "\$remote_full" key "\$PAYLOAD_WORKSPACE" "\$CONTROL_WORKSPACE")"
[[ "\$local_dec" == "\$PAYLOAD_WORKSPACE/local-full.tar.zst" && "\$remote_dec" == "\$PAYLOAD_WORKSPACE/full.tar.zst" ]] || exit 46

RESTORE_TYPE=emergency
mkdir -p "\$PAYLOAD_WORKSPACE/stage/etc/vaultwarden"
printf private > "\$PAYLOAD_WORKSPACE/stage/etc/vaultwarden/age-key.txt"
_stage_emergency_private_key_in_control_workspace "\$PAYLOAD_WORKSPACE/stage"
[[ ! -e "\$PAYLOAD_WORKSPACE/stage/etc/vaultwarden/age-key.txt" ]] || exit 47
[[ -f "\$RESTORE_EMERGENCY_STAGED_KEY_FILE" && "\$(stat -c %a "\$RESTORE_EMERGENCY_STAGED_KEY_FILE")" == 600 ]] || exit 48
[[ "\$RESTORE_EMERGENCY_STAGED_KEY_FILE" == "\$CONTROL_WORKSPACE/"* ]] || exit 49
EOF_PROBE
bash "$TMP/payload-flow-probe.sh" >"$TMP/payload-flow.out" 2>&1 || { cat "$TMP/payload-flow.out" >&2; fail 'local/remote restore payload flow probe failed'; }

printf 'PASS: split restore control/payload staging and pre-stop capacity contracts\n'
)

check_restore_payload_staging_contracts
check_restore_dr_transaction_contracts() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
RESTORE="$ROOT/utilities/restore-run.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

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

_extract_nested_func(){
  local file="$1" func="$2"
  awk -v f="$func" '
    $0 ~ "^[[:space:]]*" f "\\(\\)" {p=1}
    p {
      sub(/^    /, "")
      print
      opens=gsub(/\{/,"{"); closes=gsub(/\}/,"}")
      depth += opens - closes
      if (depth == 0) exit
    }' "$file"
}

# RDR-01: emergency mode selection fails closed before age dispatch, while both explicit modes remain distinct.
cat > "$TMP/decrypt-mode-probe.sh" <<EOF_PROBE
set -uo pipefail
RESTORE_TYPE=emergency
EMERGENCY_BACKUP_AGE_IDENTITY_FILE=""
log_error(){ printf 'ERROR %s\\n' "\$*" >> "$TMP/decrypt.log"; }
age(){ printf '%s\\n' "\$*" >> "$TMP/age.calls"; return 0; }
$(_extract_func "$RESTORE" _age_decrypt_restore_backup)
: > "$TMP/age.calls"
if _age_decrypt_restore_backup backup.age key.txt out.tar "$TMP/age.err" ""; then exit 10; fi
[[ ! -s "$TMP/age.calls" ]] || exit 11
if _age_decrypt_restore_backup backup.age key.txt out.tar "$TMP/age.err" future-mode; then exit 12; fi
[[ ! -s "$TMP/age.calls" ]] || exit 13
_age_decrypt_restore_backup backup.age key.txt out.tar "$TMP/age.err" age-passphrase || exit 14
! tail -1 "$TMP/age.calls" | grep -q -- ' -i ' || exit 15
_age_decrypt_restore_backup backup.age key.txt out.tar "$TMP/age.err" age-recipient || exit 16
tail -1 "$TMP/age.calls" | grep -q -- '-i key.txt' || exit 17
EOF_PROBE
bash "$TMP/decrypt-mode-probe.sh" || fail 'emergency decrypt dispatch did not fail closed for missing/unknown mode or preserve explicit modes'

# RDR-01: remote emergency primary is not exposed without its matching metadata sidecar.
cat > "$TMP/remote-meta-probe.sh" <<EOF_PROBE
set -uo pipefail
PAYLOAD_WORKSPACE="$TMP/remote-work"
RCLONE_CONFIG_ARG=()
BACKUP_FILE=sentinel-backup
RESTORE_TYPE=sentinel-type
STATE_DIR="$TMP/remote-state"
mkdir -p "\$PAYLOAD_WORKSPACE" "\$STATE_DIR"
log_info(){ printf 'INFO %s\\n' "\$*"; }
log_error(){ printf 'ERROR %s\\n' "\$*"; }
check_archive_dependencies(){ return 0; }
_restore_require_available_bytes(){ return 0; }
rclone(){
  local cmd="\$1"; shift
  if [[ "\$cmd" == lsl ]]; then printf '7 2026-08-05 12:00:00.000000000 emergency-test.age\\n'; return 0; fi
  [[ "\$cmd" == copy ]] || return 1
  local src="\$1" dest="\$2"
  case "\$src" in
    *.meta|*.sha256) return 1 ;;
    *) mkdir -p "\$dest"; printf archive > "\$dest/\$(basename "\$src")"; return 0 ;;
  esac
}
$(_extract_func "$RESTORE" pull_remote_backup)
if pull_remote_backup mockremote:vaultwarden_backups/emergency/emergency-test.age emergency; then exit 20; fi
[[ "\$BACKUP_FILE" == sentinel-backup ]] || exit 21
[[ "\$RESTORE_TYPE" == sentinel-type ]] || exit 22
EOF_PROBE
bash "$TMP/remote-meta-probe.sh" >"$TMP/remote-meta.out" 2>&1 || fail 'remote emergency missing-meta probe failed'
grep -qi 'restore-critical metadata is missing' "$TMP/remote-meta.out" || fail 'remote emergency missing .meta must explain restore-critical metadata failure'

# RDR-02: safe-restart eligibility is restore-type and promotion-commit aware.
cat > "$TMP/safe-restart-probe.sh" <<EOF_PROBE
set -uo pipefail
STATE_DIR="$TMP/safe-state"
mkdir -p "\$STATE_DIR/data"; printf db > "\$STATE_DIR/data/db.sqlite3"
sqlite3(){ printf 'ok\\n'; }
$(_extract_func "$RESTORE" _can_safe_restart)
RESTORE_TYPE=db; RESTORE_FULL_PROMOTION_COMMITTED=false; _can_safe_restart || exit 30
RESTORE_TYPE=full; RESTORE_FULL_PROMOTION_COMMITTED=true; _can_safe_restart || exit 31
RESTORE_TYPE=full; RESTORE_FULL_PROMOTION_COMMITTED=false; if _can_safe_restart; then exit 32; fi
RESTORE_TYPE=emergency; RESTORE_FULL_PROMOTION_COMMITTED=false; if _can_safe_restart; then exit 33; fi
RESTORE_TYPE=unknown; RESTORE_FULL_PROMOTION_COMMITTED=true; if _can_safe_restart; then exit 34; fi
EOF_PROBE
bash "$TMP/safe-restart-probe.sh" || fail '_can_safe_restart restore-type/commit predicate is incorrect'

# RDR-04: selected dependencies fail before the modeled service-stop boundary.
cat > "$TMP/dependency-probe.sh" <<EOF_PROBE
set -uo pipefail
STATE_DIR="$TMP/dependency-state"
mkdir -p "\$STATE_DIR/data"
RESTORE_TYPE=full
ROTATE_AGE_KEY_POLICY="\${ROTATE_AGE_KEY_POLICY:-}"
INSPECT_ONLY="\${INSPECT_ONLY:-false}"
TEST_MOUNTPOINT="\${TEST_MOUNTPOINT:-false}"
MISSING_CMD="\${MISSING_CMD:-}"
STOP_MARKER="$TMP/docker-stop.called"
command(){
  if [[ "\${1:-}" == -v ]]; then
    [[ "\${2:-}" == "\$MISSING_CMD" ]] && return 1
    return 0
  fi
  builtin command "\$@"
}
_path_is_mountpoint(){ [[ "\$TEST_MOUNTPOINT" == true ]]; }
docker(){ [[ "\$*" == 'compose stop' ]] && : > "\$STOP_MARKER"; }
$(_extract_func "$RESTORE" check_archive_dependencies)
check_archive_dependencies "$TMP/full.tar.gz.age"
if [[ "\$INSPECT_ONLY" != true ]]; then docker compose stop; fi
EOF_PROBE
rm -f "$TMP/docker-stop.called"
if MISSING_CMD=sops ROTATE_AGE_KEY_POLICY='' TEST_MOUNTPOINT=false bash "$TMP/dependency-probe.sh" >"$TMP/sops-preflight.out" 2>&1; then fail 'default rekey plan unexpectedly passed without sops'; fi
[[ ! -e "$TMP/docker-stop.called" ]] || fail 'sops dependency failure reached docker compose stop'
[[ ! -e "$TMP/dependency-state/secrets/secrets.yaml" ]] || fail 'sops dependency probe unexpectedly required a live secrets.yaml fixture'
grep -q 'required tools are not installed: sops' "$TMP/sops-preflight.out" || fail 'sops dependency failure was not reported by selected archive preflight'

rm -f "$TMP/docker-stop.called"
if ! MISSING_CMD=sops ROTATE_AGE_KEY_POLICY='' INSPECT_ONLY=true TEST_MOUNTPOINT=false bash "$TMP/dependency-probe.sh" >"$TMP/inspect-sops-preflight.out" 2>&1; then fail 'inspect-only plan unexpectedly required sops'; fi
[[ ! -e "$TMP/docker-stop.called" ]] || fail 'inspect-only dependency plan reached docker compose stop'
! grep -q 'required tools are not installed: sops' "$TMP/inspect-sops-preflight.out" || fail 'inspect-only dependency plan reported missing sops'

rm -f "$TMP/docker-stop.called"
if ! MISSING_CMD=sops ROTATE_AGE_KEY_POLICY=skip INSPECT_ONLY=false TEST_MOUNTPOINT=false bash "$TMP/dependency-probe.sh" >"$TMP/skip-sops-preflight.out" 2>&1; then fail 'explicit no-rotate plan unexpectedly required sops'; fi
[[ -e "$TMP/docker-stop.called" ]] || fail 'explicit no-rotate dependency plan did not continue past preflight'
! grep -q 'required tools are not installed: sops' "$TMP/skip-sops-preflight.out" || fail 'explicit no-rotate dependency plan reported missing sops'

rm -f "$TMP/docker-stop.called"
if MISSING_CMD=rsync ROTATE_AGE_KEY_POLICY=skip TEST_MOUNTPOINT=true DATA_VOLUME_DEVICE='' bash "$TMP/dependency-probe.sh" >"$TMP/rsync-preflight.out" 2>&1; then fail 'mounted full restore unexpectedly passed without rsync'; fi
[[ ! -e "$TMP/docker-stop.called" ]] || fail 'rsync dependency failure reached docker compose stop'
grep -q 'required tools are not installed: rsync' "$TMP/rsync-preflight.out" || fail 'actual-mountpoint rsync dependency failure was not reported'
dep_line="$(grep -nF 'check_archive_dependencies "$BACKUP_FILE"' "$RESTORE" | head -1 | cut -d: -f1)"
stop_line="$(grep -nF 'docker compose stop --timeout 30' "$RESTORE" | head -1 | cut -d: -f1)"
[[ -n "$dep_line" && -n "$stop_line" ]] && (( dep_line < stop_line )) || fail 'selected dependency preflight must remain before service stop'

# RDR-04: inspect-only reaches the real archive preflight without sops, service stop, key rotation, or startup.
inspect_state="$TMP/inspect-state"
inspect_project="$TMP/inspect-project"
inspect_archive="$TMP/inspect-legacy.tar.gz"
inspect_backup="$TMP/inspect-legacy.tar.gz.age"
mkdir -p "$inspect_state/data" "$inspect_project"
printf inspect-db > "$inspect_state/data/db.sqlite3"
tar -czPf "$inspect_archive" "$inspect_state"
: > "$inspect_backup"
printf 'version=1\narchive_format=absolute\n' > "$inspect_backup.meta"
cat > "$inspect_project/startup.sh" <<EOF_STARTUP
#!/usr/bin/env bash
: > "$TMP/inspect-startup.called"
EOF_STARTUP
chmod +x "$inspect_project/startup.sh"
cat > "$TMP/inspect-main-probe.sh" <<EOF_PROBE
set -u
LIST_ONLY=false
LIST_REMOTE=false
INSPECT_ONLY="\${TEST_INSPECT_ONLY:-true}"
DRY_RUN=false
FORCE="\${TEST_FORCE:-false}"
USE_REMOTE=false
NO_PRE_BACKUP="\${TEST_NO_PRE_BACKUP:-true}"
RESTORE_TYPE=full
BACKUP_FILE="$inspect_backup"
ROTATE_AGE_KEY_POLICY="\${TEST_ROTATE_POLICY:-}"
START_POLICY=auto
RESTORE_ENV=true
SKIP_VERIFICATION=true
DATA_VOLUME_MOUNT=""
DATA_VOLUME_DEVICE=""
CONTROL_WORKSPACE=""
PAYLOAD_WORKSPACE=""
MOCK_AVAILABLE_BYTES=4096
PROJECT_ROOT="$inspect_project"
SCRIPT_DIR="$inspect_project"
log_header(){ :; }
log_info(){ printf 'INFO %s\\n' "\$*"; }
log_warn(){ printf 'WARN %s\\n' "\$*"; }
log_error(){ printf 'ERROR %s\\n' "\$*" >&2; }
log_success(){ printf 'SUCCESS %s\\n' "\$*"; }
load_env_file(){ return 0; }
check_dependencies(){ return 0; }
require_root(){ return 0; }
operation_acquire(){ return 0; }
operation_set_phase(){ return 0; }
auto_fix_critical_permissions(){ return 0; }
check_project_state_ready(){ [[ "\${TEST_INSPECT_SENTINEL:-present}" == present ]]; }
require_project_state_ready(){ return 0; }
_restore_create_control_workspace(){ CONTROL_WORKSPACE="$TMP/inspect-control"; mkdir -p "\$CONTROL_WORKSPACE"; }
_restore_create_payload_workspace(){ : > "$TMP/inspect-payload.called"; PAYLOAD_WORKSPACE="$TMP/inspect-payload"; mkdir -p "\$PAYLOAD_WORKSPACE"; }
_restore_preflight_local_decrypt_capacity(){ return 0; }
_restore_preflight_archive_expansion_capacity(){
  if (( MOCK_AVAILABLE_BYTES < 2048 )); then
    log_error "Insufficient target space after pre-restore snapshot. Services were not stopped."
    return 1
  fi
  return 0
}
create_pre_restore_snapshot(){
  [[ "\${TEST_SNAPSHOT_CONSUMES_SPACE:-false}" == true ]] && MOCK_AVAILABLE_BYTES=1024
  : > "$TMP/inspect-snapshot.called"
}
_set_snapshot_operation_phase(){ return 0; }
_load_recovery_kit(){ return 0; }
resolve_backup_file(){ return 0; }
_print_restore_plan_summary(){ return 0; }
_prompt_age_key(){ RESTORE_DECRYPT_AGE_KEY_FILE=unused; return 0; }
_require_selected_archive_tools(){ return 0; }
_rotate_age_key(){ : > "$TMP/inspect-rotate.called"; }
_decrypt_restore_archive_for_preflight(){ : > "$TMP/inspect-decrypt.called"; printf '%s\\n' "$inspect_archive"; }
cleanup(){ return 0; }
_can_safe_restart(){ return 1; }
_restore_print_manual_start_checklist(){ log_warn "Services may be stopped."; }
timeout(){ shift; "\$@"; }
docker(){
  : > "$TMP/inspect-docker-stop.called"
  if [[ "\$*" == "compose stop --timeout 30" ]]; then
    case "\${TEST_STOP_SIGNAL:-}" in
      TERM) kill -TERM "\$\$" ;;
      INT) kill -INT "\$\$" ;;
    esac
  fi
}
get_config_value(){
  case "\$1" in
    PROJECT_STATE_DIR) printf '%s' "$inspect_state" ;;
    BACKUP_DIR) printf '%s' "$TMP" ;;
    SOPS_AGE_KEY_FILE) printf '%s' "$TMP/inspect-age-key.txt" ;;
    DATA_VOLUME_DEVICE) printf '%s' "\${TEST_DATA_VOLUME_DEVICE:-}" ;;
    PUID|PGID) printf '%s' 1000 ;;
    *) printf '%s' "\${2:-}" ;;
  esac
}
command(){
  if [[ "\${1:-}" == -v && "\${2:-}" == sops ]]; then return 1; fi
  builtin command "\$@"
}
$(_extract_func "$RESTORE" read_meta_field)
$(_extract_func "$RESTORE" check_archive_dependencies)
$(_extract_func "$RESTORE" _tar_filter_for_file)
$(_extract_func "$RESTORE" _path_is_mountpoint)
$(_extract_func "$RESTORE" _detect_storage_mode)
$(_extract_func "$RESTORE" _restore_required_dirs)
$(_extract_func "$RESTORE" _restore_inspect_archive_layout)
$(_extract_func "$RESTORE" restore_full_preflight)
$(_extract_func "$RESTORE" tar_validate_members)
$(_extract_func "$RESTORE" check_traversal_only)
$(_extract_func "$RESTORE" main)
main
EOF_PROBE
if ! bash "$TMP/inspect-main-probe.sh" >"$TMP/inspect-main.out" 2>&1; then cat "$TMP/inspect-main.out" >&2; fail 'inspect-only main path unexpectedly failed without sops'; fi
grep -Fq "Source state root:  $inspect_state" "$TMP/inspect-main.out" || fail 'inspect-only path did not reach real archive preflight'
grep -q 'Inspect mode complete — no services stopped, no files restored, no key rotation, no health check.' "$TMP/inspect-main.out" || fail 'inspect-only path did not preserve non-destructive completion'
[[ ! -e "$TMP/inspect-docker-stop.called" ]] || fail 'inspect-only main path invoked docker'
[[ ! -e "$TMP/inspect-rotate.called" ]] || fail 'inspect-only main path attempted key rotation'
[[ ! -e "$TMP/inspect-startup.called" ]] || fail 'inspect-only main path invoked startup.sh'

rm -rf "$TMP/inspect-control" "$TMP/inspect-payload"
rm -f "$TMP/inspect-payload.called" "$TMP/inspect-decrypt.called"
if TEST_DATA_VOLUME_DEVICE=/dev/mock TEST_INSPECT_SENTINEL=missing \
    bash "$TMP/inspect-main-probe.sh" >"$TMP/inspect-missing-sentinel.out" 2>&1; then
  fail 'inspect with configured volume and missing sentinel unexpectedly staged decrypted data'
fi
[[ ! -e "$TMP/inspect-payload.called" && ! -e "$TMP/inspect-decrypt.called" ]] \
  || fail 'inspect created payload staging or decrypted data before volume ownership validation'

rm -rf "$TMP/inspect-control" "$TMP/inspect-payload"
rm -f "$TMP/inspect-snapshot.called" "$TMP/inspect-docker-stop.called"
if TEST_INSPECT_ONLY=false TEST_FORCE=true TEST_NO_PRE_BACKUP=false TEST_ROTATE_POLICY=skip \
    TEST_SNAPSHOT_CONSUMES_SPACE=true \
    bash "$TMP/inspect-main-probe.sh" >"$TMP/post-snapshot-capacity.out" 2>&1; then
  fail 'restore unexpectedly continued after the snapshot consumed reserved capacity'
fi
[[ -e "$TMP/inspect-snapshot.called" ]] \
  || fail 'post-snapshot capacity regression did not create the modeled safety snapshot'
[[ ! -e "$TMP/inspect-docker-stop.called" ]] \
  || fail 'post-snapshot capacity failure reached docker compose stop'
grep -q 'Services were not stopped' "$TMP/post-snapshot-capacity.out" \
  || fail 'post-snapshot capacity failure did not report the untouched service state'

for stop_signal_case in TERM:143 INT:130; do
  IFS=: read -r stop_signal expected_rc <<< "$stop_signal_case"
  stop_signal_out="$TMP/stop-${stop_signal}.out"
  rm -rf "$TMP/inspect-control" "$TMP/inspect-payload"
  rm -f "$TMP/inspect-docker-stop.called" "$TMP/inspect-startup.called"
  set +e
  TEST_INSPECT_ONLY=false TEST_FORCE=true TEST_NO_PRE_BACKUP=true TEST_ROTATE_POLICY=skip \
      TEST_STOP_SIGNAL="$stop_signal" \
      bash "$TMP/inspect-main-probe.sh" >"$stop_signal_out" 2>&1
  stop_signal_rc=$?
  set -e
  [[ "$stop_signal_rc" -eq "$expected_rc" ]] \
    || { cat "$stop_signal_out" >&2; fail "$stop_signal during service stop expected $expected_rc, got $stop_signal_rc"; }
  [[ -e "$TMP/inspect-docker-stop.called" ]] \
    || fail "service-stop $stop_signal regression did not enter docker compose stop"
  ! grep -q 'Restore failed before destructive phase' "$stop_signal_out" \
    || fail "$stop_signal during service stop was reported as pre-destructive"
  ! grep -qi 'services were not stopped' "$stop_signal_out" \
    || fail "$stop_signal during service stop falsely reported untouched services"
  grep -q 'Services may be stopped' "$stop_signal_out" \
    || fail "$stop_signal during service stop did not report possible stopped services"
  [[ ! -e "$TMP/inspect-startup.called" ]] \
    || fail "$stop_signal during service stop attempted unsafe full-restore startup"
done

# RDR-06: snapshot state and persisted operation phase are truthful.
cat > "$TMP/snapshot-probe.sh" <<EOF_PROBE
set -uo pipefail
PROJECT_ROOT="$TMP/snapshot-project"
STATE_DIR="$TMP/snapshot-state"
mkdir -p "\$PROJECT_ROOT/utilities" "\$STATE_DIR/data"
cat > "\$PROJECT_ROOT/utilities/backup-run.sh" <<'BACKUP_MOCK'
#!/usr/bin/env bash
exit "\${MOCK_BACKUP_RC:-0}"
BACKUP_MOCK
chmod +x "\$PROJECT_ROOT/utilities/backup-run.sh"
RESTORE_SNAPSHOT_HARD_FAIL=false
RESTORE_SNAPSHOT_RESULT=not-run
RESTORE_TYPE=full
DRY_RUN=false
NO_PRE_BACKUP=false
OPERATIONAL_SOPS_AGE_KEY_FILE="$TMP/live-key.txt"
printf key > "\$OPERATIONAL_SOPS_AGE_KEY_FILE"
log_info(){ :; }; log_warn(){ :; }; log_error(){ printf 'ERROR %s\\n' "\$*"; }
get_config_value(){ [[ "\$1" == PROJECT_STATE_DIR ]] && printf '%s\\n' "\$STATE_DIR" || printf '%s\\n' "\${2:-}"; }
_preflight_operational_sops_key_for_snapshot(){ return 0; }
sqlite3(){ return 0; }
operation_set_phase(){ printf '%s|%s\\n' "\$1" "\$2" > "$TMP/snapshot.phase"; }
$(_extract_func "$RESTORE" create_pre_restore_snapshot)
$(_extract_func "$RESTORE" _set_snapshot_operation_phase)

NO_PRE_BACKUP=true
create_pre_restore_snapshot "\$OPERATIONAL_SOPS_AGE_KEY_FILE" full || exit 40
[[ "\$RESTORE_SNAPSHOT_RESULT" == skipped ]] || exit 41
_set_snapshot_operation_phase || exit 42
! grep -q 'Created pre-restore snapshot' "$TMP/snapshot.phase" || exit 43

NO_PRE_BACKUP=false
rm -f "\$STATE_DIR/data/db.sqlite3"
create_pre_restore_snapshot "\$OPERATIONAL_SOPS_AGE_KEY_FILE" full || exit 44
[[ "\$RESTORE_SNAPSHOT_RESULT" == skipped ]] || exit 45
_set_snapshot_operation_phase || exit 46
! grep -q 'Created pre-restore snapshot' "$TMP/snapshot.phase" || exit 47

printf db > "\$STATE_DIR/data/db.sqlite3"
MOCK_BACKUP_RC=9
export MOCK_BACKUP_RC
create_pre_restore_snapshot "\$OPERATIONAL_SOPS_AGE_KEY_FILE" full || exit 48
[[ "\$RESTORE_SNAPSHOT_RESULT" == soft-failed ]] || exit 49
_set_snapshot_operation_phase || exit 50
! grep -q 'Created pre-restore snapshot' "$TMP/snapshot.phase" || exit 51
grep -q 'soft-failed' "$TMP/snapshot.phase" || exit 52

MOCK_BACKUP_RC=0
export MOCK_BACKUP_RC
create_pre_restore_snapshot "\$OPERATIONAL_SOPS_AGE_KEY_FILE" full || exit 53
[[ "\$RESTORE_SNAPSHOT_RESULT" == created ]] || exit 54
_set_snapshot_operation_phase || exit 55
grep -q 'Created pre-restore snapshot' "$TMP/snapshot.phase" || exit 56
EOF_PROBE
bash "$TMP/snapshot-probe.sh" || fail 'snapshot result/operation phase contract probe failed'

# RDR-07: exact maintenance-health status controls completion truthfully without touching committed state.
cat > "$TMP/health-probe.sh" <<EOF_PROBE
set -uo pipefail
PROJECT_ROOT="$TMP/health-project"
ROTATED_KEY_FILE=""
DRY_RUN=false
LOG_FILE="$TMP/health.log"
COMMITTED_MARKER="$TMP/committed.marker"
printf committed > "\$COMMITTED_MARKER"
log_info(){ printf 'INFO %s\\n' "\$*" >> "\$LOG_FILE"; }
log_warn(){ printf 'WARN %s\\n' "\$*" >> "\$LOG_FILE"; }
log_error(){ printf 'ERROR %s\\n' "\$*" >> "\$LOG_FILE"; }
log_success(){ printf 'SUCCESS %s\\n' "\$*" >> "\$LOG_FILE"; }
auto_fix_critical_permissions(){ return 0; }
_print_post_restore_summary(){ printf 'SUMMARY committed restore\\n' >> "\$LOG_FILE"; }
$(_extract_func "$RESTORE" _complete_restore_after_health)
health_rc="\$1"
: > "\$LOG_FILE"
rc=0
_complete_restore_after_health "\$health_rc" || rc=\$?
[[ -f "\$COMMITTED_MARKER" ]] || exit 90
printf 'RC=%s\\n' "\$rc"
cat "\$LOG_FILE"
EOF_PROBE

for health_rc in 0 1 2 3 4 75; do
  bash "$TMP/health-probe.sh" "$health_rc" >"$TMP/health-$health_rc.out" 2>&1 || fail "health completion probe crashed for exit $health_rc"
done
grep -q '^RC=0$' "$TMP/health-0.out" || fail 'health exit 0 must return success'
grep -q 'SUCCESS Restore complete\.' "$TMP/health-0.out" || fail 'health exit 0 must permit clean restore success'
grep -q '^RC=0$' "$TMP/health-1.out" || fail 'health exit 1 must return success'
grep -q 'Restore completed with warnings' "$TMP/health-1.out" || fail 'health exit 1 must print warning completion'
! grep -q 'SUCCESS Restore complete\.' "$TMP/health-1.out" || fail 'health exit 1 must not print clean restore success'
for health_rc in 2 3 4; do
  grep -q "^RC=$health_rc\$" "$TMP/health-$health_rc.out" || fail "health exit $health_rc must remain non-zero"
  grep -q 'committed and remain in place' "$TMP/health-$health_rc.out" || fail "health exit $health_rc must report committed artifacts remain"
  ! grep -q 'SUCCESS Restore complete\.' "$TMP/health-$health_rc.out" || fail "health exit $health_rc must not print clean restore success"
done
grep -q '^RC=75$' "$TMP/health-75.out" || fail 'health exit 75 must preserve expected contention status'
grep -qi 'another health or repair operation is active' "$TMP/health-75.out" || fail 'health exit 75 must describe active-operation contention'
! grep -qi 'critical health failure' "$TMP/health-75.out" || fail 'health exit 75 must not be mislabeled as a critical stack failure'
! grep -q 'SUCCESS Restore complete\.' "$TMP/health-75.out" || fail 'health exit 75 must not print clean restore success'

# Shared restore_full harness for RDR-02/03/05 behavioral failure injection.
RESTORE_HARNESS="$TMP/restore-full-harness.sh"
cat > "$RESTORE_HARNESS" <<'HARNESS'
set -Eeuo pipefail
log_info(){ printf 'INFO %s\n' "$*"; }
log_warn(){ printf 'WARN %s\n' "$*"; }
log_error(){ printf 'ERROR %s\n' "$*" >&2; }
log_hint(){ printf 'HINT %s\n' "$*"; }
log_success(){ printf 'SUCCESS %s\n' "$*"; }
get_config_value(){ case "$1" in DATA_VOLUME_MOUNT|DATA_VOLUME_DEVICE) printf '%s' '';; *) printf '%s' "${2:-}";; esac; }
purge_wal_shm(){ :; }
tar_validate_members(){ :; }
check_traversal_only(){ :; }
SCRIPT_DIR="${TEST_PROJECT_ROOT:?}"
PROJECT_ROOT="$TEST_PROJECT_ROOT"
RESTORE_TYPE=full
FORCE=false
INSPECT_ONLY=false
SKIP_VERIFICATION=true
RESTORE_ENV=true
DRY_RUN=false
DATA_VOLUME_MOUNT=""
DATA_VOLUME_DEVICE=""
PUID="$(id -u)"
PGID="$(id -g)"
EMERGENCY_BACKUP_AGE_IDENTITY_FILE=""
SECRETS_FILE=""
CONTROL_WORKSPACE=""; CONTROL_WORKSPACE_ID=""
PAYLOAD_WORKSPACE=""; PAYLOAD_WORKSPACE_ID=""
PROMOTION_WORKSPACE=""; PROMOTION_WORKSPACE_ID=""
RESTORE_RETAIN_PAYLOAD=false; RESTORE_RETAIN_REASON=""
RESTORE_CLEANUP_DONE=false
operation_release(){ :; }
HARNESS
{
  sed -n '/^_restore_workspace_identity()/,/^}/p' "$RESTORE"
  sed -n '/^_restore_workspace_is_owned()/,/^}/p' "$RESTORE"
  sed -n '/^_restore_create_owned_workspace()/,/^}/p' "$RESTORE"
  sed -n '/^_restore_remove_owned_workspace()/,/^}/p' "$RESTORE"
  sed -n '/^_restore_log_retained_workspace()/,/^}/p' "$RESTORE"
  sed -n '/^_restore_log_retained_payload()/,/^}/p' "$RESTORE"
  sed -n '/^_restore_retain_payload_for_manual_recovery()/,/^}/p' "$RESTORE"
  sed -n '/^cleanup()/,/^}/p' "$RESTORE"
  sed -n '/^_restore_signal_exit()/,/^}/p' "$RESTORE"
  sed -n '/^_can_safe_restart()/,/^}/p' "$RESTORE"
  sed -n '/^_tar_filter_for_file()/,/^tar_validate_members()/p' "$RESTORE" | sed '$d'
  sed -n '/^_stage_emergency_private_key_in_control_workspace()/,/^}/p' "$RESTORE"
  sed -n '/^restore_full()/,/^main()/p' "$RESTORE" | sed '$d'
} >> "$RESTORE_HARNESS"
printf '%s\n' "trap 'cleanup \$?' EXIT ERR" >> "$RESTORE_HARNESS"

# RDR-03: materialization failure leaves the live same-layout generation untouched.
materialize_state="$TMP/materialize-state"
materialize_root="$TMP/materialize-root"
materialize_work="$TMP/materialize-work"
mkdir -p "$materialize_root/${materialize_state#/}/data" "$materialize_work" "$TMP/materialize-project"
printf new > "$materialize_root/${materialize_state#/}/generation"
printf db > "$materialize_root/${materialize_state#/}/data/db.sqlite3"
(cd "$materialize_root" && tar -czf "$TMP/materialize.tar.gz" .)
cp "$TMP/materialize.tar.gz" "$materialize_work/materialize.tar.gz"
: > "$TMP/materialize.tar.gz.age"
mkdir -p "$materialize_state/data"
printf old > "$materialize_state/generation"
printf olddb > "$materialize_state/data/db.sqlite3"
cat > "$TMP/materialize-fail-probe.sh" <<EOF_PROBE
source "$RESTORE_HARNESS"
RESTORE_PREFLIGHT_SOURCE_ROOT="$materialize_state"
STARTUP_MARKER="$TMP/materialize-startup.called"
_can_safe_restart(){ : > "\$STARTUP_MARKER"; return 1; }
cp(){
  if [[ "\${1:-}" == -a && "\${2:-}" == "$materialize_work/stage/${materialize_state#/}" \
        && "\${3:-}" == "$materialize_state".restore-workspace.*/state ]]; then
    : > "$TMP/materialize-copy-failed"
    return 66
  fi
  command cp "\$@"
}
mv(){
  if [[ "\${1:-}" == "$materialize_state" ]]; then : > "$TMP/materialize-live-move-attempted"; fi
  command mv "\$@"
}
restore_full "$TMP/materialize.tar.gz.age" unused "$materialize_state" "\$PUID" "\$PGID" "$materialize_work" relative
EOF_PROBE
if TEST_PROJECT_ROOT="$TMP/materialize-project" bash "$TMP/materialize-fail-probe.sh" >"$TMP/materialize.out" 2>&1; then fail 'target-filesystem materialization failure unexpectedly succeeded'; fi
[[ -f "$TMP/materialize-copy-failed" ]] || fail 'target-filesystem materialization failure was not injected'
grep -qx old "$materialize_state/generation" || fail 'target-filesystem materialization failure changed live generation'
[[ ! -e "$TMP/materialize-live-move-attempted" ]] || fail 'target-filesystem materialization failure moved the live generation'
[[ ! -e "$TMP/materialize-startup.called" ]] || fail 'target-filesystem materialization failure reached startup eligibility'
! compgen -G "$materialize_state.restore-workspace.*" >/dev/null || fail 'failed target-filesystem materialization left an unclean staging sibling'
! grep -q 'Full restore promotion completed' "$TMP/materialize.out" || fail 'target-filesystem materialization failure printed promotion success'

rm -f "$TMP/materialize-term-paths"
cat > "$TMP/materialize-term-probe.sh" <<EOF_PROBE
source "$RESTORE_HARNESS"
RESTORE_PREFLIGHT_SOURCE_ROOT="$materialize_state"
_restore_create_owned_workspace CONTROL_WORKSPACE CONTROL_WORKSPACE_ID "$TMP" materialize-control
_restore_create_owned_workspace PAYLOAD_WORKSPACE PAYLOAD_WORKSPACE_ID "$TMP" materialize-payload
cp "$TMP/materialize.tar.gz" "\$PAYLOAD_WORKSPACE/materialize.tar.gz"
trap '_restore_signal_exit 143' TERM
cp(){
  if [[ "\${1:-}" == -a && "\${2:-}" == "\$PAYLOAD_WORKSPACE/stage/${materialize_state#/}" \
        && "\${3:-}" == "$materialize_state".restore-workspace.*/state ]]; then
    command cp "\$@"
    printf '%s\n%s\n%s\n' "\$CONTROL_WORKSPACE" "\$PAYLOAD_WORKSPACE" "\$PROMOTION_WORKSPACE" \
      > "$TMP/materialize-term-paths"
    kill -TERM \$\$
    return 143
  fi
  command cp "\$@"
}
restore_full "$TMP/materialize.tar.gz.age" unused "$materialize_state" "\$PUID" "\$PGID" "\$PAYLOAD_WORKSPACE" relative
EOF_PROBE
set +e
TEST_PROJECT_ROOT="$TMP/materialize-project" bash "$TMP/materialize-term-probe.sh" >"$TMP/materialize-term.out" 2>&1
materialize_term_rc=$?
set -e
[[ "$materialize_term_rc" -eq 143 ]] || { cat "$TMP/materialize-term.out" >&2; fail "materialization TERM expected 143, got $materialize_term_rc"; }
grep -qx old "$materialize_state/generation" || fail 'materialization TERM changed the live generation'
while IFS= read -r path; do [[ ! -e "$path" ]] || fail "materialization TERM left decrypted staging: $path"; done < "$TMP/materialize-term-paths"
! compgen -G "$materialize_state.restore-workspace.*" >/dev/null || fail 'materialization TERM left an untracked promotion sibling'

# RDR-03: a partial canonical destination from the second rename is removed before rollback.
rollback_state="$TMP/rollback-state"
rollback_root="$TMP/rollback-root"
rollback_work="$TMP/rollback-work"
mkdir -p "$rollback_root/${rollback_state#/}/data" "$rollback_work" "$TMP/rollback-project"
printf new > "$rollback_root/${rollback_state#/}/generation"
printf new-only > "$rollback_root/${rollback_state#/}/new-only.marker"
printf db > "$rollback_root/${rollback_state#/}/data/db.sqlite3"
(cd "$rollback_root" && tar -czf "$TMP/rollback.tar.gz" .)
cp "$TMP/rollback.tar.gz" "$rollback_work/rollback.tar.gz"
: > "$TMP/rollback.tar.gz.age"
mkdir -p "$rollback_state/data"
printf old > "$rollback_state/generation"
printf olddb > "$rollback_state/data/db.sqlite3"
cat > "$TMP/rollback-probe.sh" <<EOF_PROBE
source "$RESTORE_HARNESS"
RESTORE_PREFLIGHT_SOURCE_ROOT="$rollback_state"
mv(){
  if [[ "\${1:-}" == "$rollback_state".restore-workspace.*/state && "\${2:-}" == "$rollback_state" ]]; then
    command mkdir -p "$rollback_state"
    local_marker="\$(find "\$1" -maxdepth 1 -name '.restore-promotion.*' -print -quit)"
    [[ -n "\$local_marker" ]] && command cp -a "\$local_marker" "$rollback_state/"
    printf partial > "$rollback_state/new-only.marker"
    return 23
  fi
  command mv "\$@"
}
restore_full "$TMP/rollback.tar.gz.age" unused "$rollback_state" "\$PUID" "\$PGID" "$rollback_work" relative
EOF_PROBE
if TEST_PROJECT_ROOT="$TMP/rollback-project" bash "$TMP/rollback-probe.sh" >"$TMP/rollback.out" 2>&1; then fail 'same-layout staged-state second rename failure unexpectedly succeeded'; fi
grep -qx old "$rollback_state/generation" || fail 'same-layout promotion rollback did not restore old generation at canonical STATE_DIR'
[[ ! -e "$rollback_state/new-only.marker" ]] || fail 'failed staged generation was presented at canonical STATE_DIR'
grep -q 'Removing incomplete canonical state created by the failed promotion attempt' "$TMP/rollback.out" || fail 'partial canonical destination was not identified and removed before rollback'
grep -q 'Restore promotion rollback succeeded' "$TMP/rollback.out" || fail 'successful same-layout rollback was not reported truthfully'
! grep -q 'Full restore promotion completed' "$TMP/rollback.out" || fail 'failed same-layout promotion printed successful restore completion'

# RDR-05: legacy absolute archives are always staged; extraction failures/signals leave live generation unchanged.
legacy_state="$TMP/legacy-state"
legacy_work="$TMP/legacy-work"
legacy_project="$TMP/legacy-project"
mkdir -p "$legacy_state/data" "$legacy_work" "$legacy_project"
printf new > "$legacy_state/generation"
printf db > "$legacy_state/data/db.sqlite3"
tar -czPf "$TMP/legacy.tar.gz" "$legacy_state"
printf old > "$legacy_state/generation"
printf olddb > "$legacy_state/data/db.sqlite3"
cp "$TMP/legacy.tar.gz" "$legacy_work/legacy.tar.gz"
: > "$TMP/legacy.tar.gz.age"
cat > "$TMP/legacy-valid-probe.sh" <<EOF_PROBE
source "$RESTORE_HARNESS"
check_traversal_only(){ : > "$TMP/legacy-traversal.called"; }
_tar_extract_archive(){
  printf '%s\\n' "\$2" > "$TMP/legacy-extract.dest"
  command tar -z -xf "\$1" -C "\$2" --no-same-owner --no-same-permissions
}
mv(){
  if [[ "\${1:-}" == "$legacy_state".restore-workspace.*/state && "\${2:-}" == "$legacy_state" ]]; then
    printf '%s\\n' "\$1" > "$TMP/legacy-promotion-source"
  fi
  command mv "\$@"
}
_restore_inspect_archive_layout "$TMP/legacy.tar.gz" "$legacy_state" absolute
printf '%s\\n' "\$RESTORE_PREFLIGHT_SOURCE_ROOT" > "$TMP/legacy-source-root"
restore_full "$TMP/legacy.tar.gz.age" unused "$legacy_state" "\$PUID" "\$PGID" "$legacy_work" absolute
EOF_PROBE
TEST_PROJECT_ROOT="$legacy_project" bash "$TMP/legacy-valid-probe.sh" >"$TMP/legacy-valid.out" 2>&1 || { cat "$TMP/legacy-valid.out" >&2; fail 'valid staged legacy archive did not reach promotion path'; }
[[ "$(cat "$TMP/legacy-source-root")" == "$legacy_state" ]] || fail 'legacy absolute preflight did not derive the canonical same-layout source root'
[[ "$(cat "$TMP/legacy-extract.dest")" == "$legacy_work/stage" ]] || fail 'legacy archive extraction destination was not secure staging'
[[ "$(cat "$TMP/legacy-extract.dest")" != / ]] || fail 'legacy archive was extracted directly to root'
[[ -f "$TMP/legacy-traversal.called" ]] || fail 'legacy traversal check must run even with skip verification'
grep -qx new "$legacy_state/generation" || fail 'valid staged legacy archive did not promote restored generation'
legacy_promotion_source="$(cat "$TMP/legacy-promotion-source")"
[[ "$(dirname "$(dirname "$legacy_promotion_source")")" == "$(dirname "$legacy_state")" ]] || fail 'same-layout promotion source was not on the target filesystem'
[[ "$legacy_promotion_source" == "$legacy_state".restore-workspace.*/state ]] || fail 'same-layout promotion did not use a target-filesystem restore workspace'
[[ "$legacy_promotion_source" != "$legacy_work/stage/${legacy_state#/}" ]] || fail 'same-layout promotion reused generic restore staging as rename source'
! grep -q 'Cross-layout restore' "$TMP/legacy-valid.out" || fail 'same-layout legacy archive was incorrectly sent through cross-layout promotion'

reset_legacy_live(){ rm -rf "$legacy_state" "$legacy_work/stage"; mkdir -p "$legacy_state/data"; printf old > "$legacy_state/generation"; printf olddb > "$legacy_state/data/db.sqlite3"; }
reset_legacy_live
cat > "$TMP/legacy-fail-probe.sh" <<EOF_PROBE
source "$RESTORE_HARNESS"
_tar_extract_archive(){ printf '%s\\n' "\$2" > "$TMP/legacy-fail.dest"; return 55; }
_restore_inspect_archive_layout "$TMP/legacy.tar.gz" "$legacy_state" absolute
restore_full "$TMP/legacy.tar.gz.age" unused "$legacy_state" "\$PUID" "\$PGID" "$legacy_work" absolute
EOF_PROBE
if TEST_PROJECT_ROOT="$legacy_project" bash "$TMP/legacy-fail-probe.sh" >"$TMP/legacy-fail.out" 2>&1; then fail 'legacy staged extraction failure unexpectedly succeeded'; fi
grep -qx old "$legacy_state/generation" || fail 'legacy staged extraction failure changed live generation'
[[ "$(cat "$TMP/legacy-fail.dest")" != / ]] || fail 'legacy failed extraction targeted root'

for sig in INT TERM; do
  reset_legacy_live
  cat > "$TMP/legacy-signal-probe.sh" <<EOF_PROBE
source "$RESTORE_HARNESS"
_tar_extract_archive(){ printf '%s\\n' "\$2" > "$TMP/legacy-$sig.dest"; kill -$sig \$\$; }
_restore_inspect_archive_layout "$TMP/legacy.tar.gz" "$legacy_state" absolute
restore_full "$TMP/legacy.tar.gz.age" unused "$legacy_state" "\$PUID" "\$PGID" "$legacy_work" absolute
EOF_PROBE
  if TEST_PROJECT_ROOT="$legacy_project" bash "$TMP/legacy-signal-probe.sh" >"$TMP/legacy-$sig.out" 2>&1; then fail "legacy staged extraction $sig unexpectedly succeeded"; fi
  grep -qx old "$legacy_state/generation" || fail "legacy staged extraction $sig changed live generation"
  [[ "$(cat "$TMP/legacy-$sig.dest")" != / ]] || fail "legacy staged extraction $sig targeted root"
done

# RDR-02: real promotion boundaries with a valid new DB never start services before full commit.
transaction_source="$TMP/transaction-source"
transaction_target="$TMP/transaction-target"
transaction_project="$TMP/transaction-project"
transaction_root="$TMP/transaction-root"
transaction_work="$TMP/transaction-work"
mkdir -p "$transaction_root/${transaction_source#/}/data" "$transaction_root/${transaction_source#/}/secrets" "$transaction_root/${transaction_project#/}" "$transaction_work" "$transaction_project"
printf newdb > "$transaction_root/${transaction_source#/}/data/db.sqlite3"
printf encrypted-new-secret > "$transaction_root/${transaction_source#/}/secrets/secrets.yaml"
printf restored-env > "$transaction_root/${transaction_project#/}/.env"
(cd "$transaction_root" && tar -czf "$TMP/transaction.tar.gz" .)
cp "$TMP/transaction.tar.gz" "$transaction_work/transaction.tar.gz"
: > "$TMP/transaction.tar.gz.age"

write_transaction_probe(){
  local mode="$1"
  cat > "$TMP/transaction-$mode.sh" <<EOF_PROBE
source "$RESTORE_HARNESS"
RESTORE_PREFLIGHT_SOURCE_ROOT="$transaction_source"
RESTORE_FULL_PROMOTION_COMMITTED=false
STATE_DIR="$transaction_target"
STARTUP_MARKER="$TMP/startup-$mode.called"
sqlite3(){ printf 'ok\\n'; }
_handle_failure(){
  local rc="\$1"
  trap - ERR INT TERM
  if _can_safe_restart; then : > "\$STARTUP_MARKER"; fi
  exit "\$rc"
}
_on_err(){ local rc=\$?; _handle_failure "\$rc"; }
_on_int(){ _handle_failure 130; }
_on_term(){ _handle_failure 143; }
trap _on_err ERR
trap _on_int INT
trap _on_term TERM
EOF_PROBE
  case "$mode" in
    config-fail)
      cat >> "$TMP/transaction-$mode.sh" <<EOF_PROBE
cp(){
  if [[ "\${1:-}" == -f && "\${2:-}" == "$transaction_work/stage/${transaction_project#/}/.env" && "\${3:-}" == "$transaction_project/.env" ]]; then return 88; fi
  command cp "\$@"
}
EOF_PROBE
      ;;
    secret-int)
      cat >> "$TMP/transaction-$mode.sh" <<EOF_PROBE
install(){
  if [[ "\$*" == *"$transaction_work/stage/${transaction_source#/}/secrets/secrets.yaml"* ]]; then kill -INT \$\$; fi
  command install "\$@"
}
EOF_PROBE
      ;;
    config-term)
      cat >> "$TMP/transaction-$mode.sh" <<EOF_PROBE
cp(){
  if [[ "\${1:-}" == -f && "\${2:-}" == "$transaction_work/stage/${transaction_project#/}/.env" && "\${3:-}" == "$transaction_project/.env" ]]; then kill -TERM \$\$; fi
  command cp "\$@"
}
EOF_PROBE
      ;;
  esac
  cat >> "$TMP/transaction-$mode.sh" <<EOF_PROBE
restore_full "$TMP/transaction.tar.gz.age" unused "$transaction_target" "\$PUID" "\$PGID" "$transaction_work" relative
EOF_PROBE
}

for mode in config-fail secret-int config-term; do
  rm -rf "$transaction_target" "$transaction_work/stage" "$transaction_project/.env" "$TMP/startup-$mode.called"
  mkdir -p "$transaction_target/data"
  printf olddb > "$transaction_target/data/db.sqlite3"
  write_transaction_probe "$mode"
  if TEST_PROJECT_ROOT="$transaction_project" bash "$TMP/transaction-$mode.sh" >"$TMP/transaction-$mode.out" 2>&1; then fail "uncommitted full promotion boundary $mode unexpectedly succeeded"; fi
  [[ -f "$transaction_target/data/db.sqlite3" ]] || fail "$mode did not reach valid DB promotion boundary"
  [[ ! -e "$TMP/startup-$mode.called" ]] || fail "$mode invoked startup.sh eligibility before full promotion commit"
done
grep -q 'encrypted-new-secret' "$transaction_target/secrets/secrets.yaml" || fail 'config TERM case did not reach encrypted secret promotion before later config boundary'

# RDR-02: execute the production safety net after a real full-restore promotion boundary fails.
safety_target="$TMP/safety-target"
safety_root="$TMP/safety-root"
safety_work="$TMP/safety-work"
safety_project="$TMP/safety-project"
mkdir -p "$safety_root/${safety_target#/}/data" "$safety_root/${safety_target#/}/secrets" "$safety_work" "$safety_project"
printf newdb > "$safety_root/${safety_target#/}/data/db.sqlite3"
printf encrypted-new-secret > "$safety_root/${safety_target#/}/secrets/secrets.yaml"
(cd "$safety_root" && tar -czf "$TMP/safety.tar.gz" .)
cp "$TMP/safety.tar.gz" "$safety_work/safety.tar.gz"
: > "$TMP/safety.tar.gz.age"
mkdir -p "$safety_target/data"
printf olddb > "$safety_target/data/db.sqlite3"
cat > "$safety_project/startup.sh" <<EOF_STARTUP
#!/usr/bin/env bash
: > "$TMP/safety-startup.called"
EOF_STARTUP
chmod +x "$safety_project/startup.sh"
cat > "$TMP/safety-net-probe.sh" <<EOF_PROBE
source "$RESTORE_HARNESS"
STATE_DIR="$safety_target"
RESTORE_PREFLIGHT_SOURCE_ROOT="$safety_target"
RESTORE_DESTRUCTIVE_PHASE_STARTED=true
RESTORE_FULL_PROMOTION_COMMITTED=false
RESTORE_PREVENT_AUTOSTART=false
START_POLICY=auto
_RESTORE_SAFETY_NET_RUNNING=false
_RESTORE_CLEANUP_DONE=false
cleanup(){ :; }
sqlite3(){ printf 'ok\\n'; }
$(_extract_func "$RESTORE" _restore_print_manual_start_checklist)
$(_extract_nested_func "$RESTORE" _restore_cleanup_once)
$(_extract_nested_func "$RESTORE" _restore_safety_net)
install(){
  if [[ "\$*" == *"$safety_work/stage/${safety_target#/}/secrets/secrets.yaml"* ]]; then return 86; fi
  command install "\$@"
}
trap _restore_safety_net ERR
restore_full "$TMP/safety.tar.gz.age" unused "$safety_target" "\$PUID" "\$PGID" "$safety_work" relative
EOF_PROBE
if TEST_PROJECT_ROOT="$safety_project" bash "$TMP/safety-net-probe.sh" >"$TMP/safety-net.out" 2>&1; then fail 'production safety-net probe unexpectedly succeeded'; fi
grep -qx newdb "$safety_target/data/db.sqlite3" || fail 'safety-net probe did not reach a valid new DB before the injected promotion failure'
grep -q 'Restore state is not eligible for automatic safety restart' "$TMP/safety-net.out" || fail 'production safety net did not refuse restart for uncommitted full restore'
[[ ! -e "$TMP/safety-startup.called" ]] || fail 'production safety net invoked startup.sh before full promotion commit'
! grep -q 'attempting one service restart' "$TMP/safety-net.out" || fail 'production safety net printed restart-success wording before full promotion commit'
! grep -q 'Full restore promotion completed' "$TMP/safety-net.out" || fail 'failed production safety-net probe printed full promotion success'

printf 'PASS: restore DR transaction, legacy staging, dependency, snapshot, and health contracts\n'
)

check_restore_dr_transaction_contracts
check_recovery_contracts() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
REAL_ETC_SNAPSHOT="$(mktemp -d)"
TEST_ROOT="$(mktemp -d)"
TESTS_RUN=0

USB_RECIPIENT="age1usb0000000000000000000000000000000000000000000000000000000"
NEW_RECIPIENT="age1new0000000000000000000000000000000000000000000000000000000"

cleanup_all() {
    if (( EUID == 0 )); then
        rm -rf "$TEST_ROOT" "$REAL_ETC_SNAPSHOT"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        sudo -n rm -rf "$TEST_ROOT" "$REAL_ETC_SNAPSHOT"
    else
        rm -rf "$TEST_ROOT" "$REAL_ETC_SNAPSHOT"
    fi
}
trap cleanup_all EXIT

if [[ -d /etc/vaultwarden ]]; then
    cp -a /etc/vaultwarden/. "$REAL_ETC_SNAPSHOT/" 2>/dev/null || true
fi

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

assert_real_etc_unchanged() {
    if [[ -d /etc/vaultwarden ]]; then
        diff -qr "$REAL_ETC_SNAPSHOT" /etc/vaultwarden >/dev/null 2>&1 || fail 'real /etc/vaultwarden changed'
    fi
}

_restore_recovery_run_test_impl() {
    local name="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    "$@"
    assert_real_etc_unchanged
    pass "$name"
}

assert_file_equals() {
    local expected="$1" actual="$2" label="$3"
    cmp -s "$expected" "$actual" || fail "$label"
}

assert_file_missing() {
    [[ ! -e "$1" ]] || fail "expected missing: $1"
}

file_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then
        stat -c '%a' "$1"
    else
        stat -f '%Lp' "$1"
    fi
}

canonical_path() {
    /usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

env_value() {
    local key="$1" file="$2"
    if [[ -r "$file" ]]; then
        awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); found = 1 } END { exit found ? 0 : 1 }' "$file"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        sudo -n awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); found = 1 } END { exit found ? 0 : 1 }' "$file"
    else
        return 1
    fi
}

env_has_value() {
    local key="$1" expected="$2" file="$3"
    local actual
    actual="$(env_value "$key" "$file")" || return 1
    [[ "$actual" == "$expected" ]]
}

make_case() {
    local dir="$TEST_ROOT/case-$TESTS_RUN"
    mkdir -p "$dir/state/config" "$dir/state/secrets" "$dir/state/data" "$dir/repo" "$dir/etc" "$dir/mockbin"
    cp "$ROOT/recover.sh" "$dir/repo/recover.sh"
    cp -a "$ROOT/lib" "$dir/repo/lib"
    cat >> "$dir/repo/lib/operations.sh" <<'RELEASE_PROBE'

if [[ -n "${VW_TEST_RELEASE_LOG:-}" ]]; then
    eval "$(declare -f operation_release | sed '1s/operation_release/_test_operation_release/')"
    operation_release() {
        printf '%s\n' "${1:-0}" >> "$VW_TEST_RELEASE_LOG"
        _test_operation_release "$@"
    }
fi
RELEASE_PROBE
    mkdir -p "$dir/repo/utilities"
    cp "$ROOT/utilities/env-edit.sh" "$dir/repo/utilities/env-edit.sh"
    cp "$ROOT/docker-compose.yml.example" "$dir/repo/docker-compose.yml.example"
    chmod +x "$dir/repo/recover.sh" "$dir/repo/utilities/env-edit.sh"
    cat > "$dir/state/config/dr-manifest.env" <<EOF_MANIFEST
DOMAIN=https://vault.example.test
REPO_URL=https://example.test/repo.git
REPO_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OFFLINE_AGE_RECIPIENT=$USB_RECIPIENT
STATE_LAYOUT_VERSION=1
MANIFEST_UPDATED_AT=2026-01-01T00:00:00Z
EOF_MANIFEST
    cat > "$dir/state/config/install.env" <<EOF_ENV
PROJECT_STATE_DIR=$dir/state
DATA_VOLUME_MOUNT=$dir/state
DATA_VOLUME_DEVICE=/dev/mock
SOPS_AGE_KEY_FILE=$dir/etc/age-key.txt
EOF_ENV
    printf 'ciphertext-v1\n' > "$dir/state/secrets/secrets.yaml"
    printf 'old-policy\n' > "$dir/repo/.sops.yaml"
    printf 'old-key\n' > "$dir/etc/age-key.txt"
    printf 'usb-key\n' > "$dir/usb-key.txt"
    printf '%s\n' "$dir"
}

write_mocks() {
    local dir="$1"
    local mock="$dir/mockbin"
    cat > "$mock/mountpoint" <<'MOUNT'
#!/usr/bin/env bash
[[ "${MOCK_MOUNTPOINT_FAIL:-false}" == true ]] && exit 1
exit 0
MOUNT
    cat > "$mock/findmnt" <<'FINDMNT'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_FINDMNT_SOURCE:-/dev/mock-source}"
FINDMNT
    cat > "$mock/blkid" <<'BLKID'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_BLKID_UUID:-1111-2222}"
BLKID
    cat > "$mock/realpath" <<'REALPATH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-e" ]]; then
    shift
    [[ $# -eq 1 && -e "${1:-}" ]] || exit 1
    cd "$(dirname "$1")" || exit 1
    printf '%s/%s\n' "$(pwd)" "$(basename "$1")"
    exit 0
fi
exec /bin/realpath "$@"
REALPATH
    cat > "$mock/docker" <<'DOCKER'
#!/usr/bin/env bash
if [[ "${1:-}" == compose && "${2:-}" == version ]]; then
    echo 'Docker Compose mock'
    exit 0
fi
exit 0
DOCKER
    cat > "$mock/curl" <<'CURL'
#!/usr/bin/env bash
exit "${MOCK_CURL_EXIT:-0}"
CURL
    cat > "$mock/git" <<'GIT'
#!/usr/bin/env bash
if [[ "${1:-}" == -C && "${3:-}" == rev-parse && "${4:-}" == HEAD ]]; then
    printf '%s\n' "${MOCK_GIT_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
    exit 0
fi
exit 0
GIT
    cat > "$mock/age-keygen" <<'AGE'
#!/usr/bin/env bash
[[ -z "${MOCK_AGE_LOG:-}" ]] || printf '%s\n' "$*" >> "$MOCK_AGE_LOG"
if [[ "${1:-}" == -y ]]; then
    [[ -n "${MOCK_USB_KEY_PATH:-}" ]] || exit 2
    if [[ "$(basename "${2:-}")" == "usb-key.txt" ]]; then
        printf '%s\n' "$MOCK_USB_RECIPIENT"
    else
        printf '%s\n' "$MOCK_NEW_RECIPIENT"
    fi
    exit 0
fi
if [[ "${1:-}" == -o ]]; then
    printf 'new-private-key\n' > "$2"
    exit 0
fi
exit 1
AGE
    cat > "$mock/sops" <<'SOPS'
#!/usr/bin/env bash
mode=""; target=""; config=""
prev=""
for arg in "$@"; do
    case "$arg" in
        --config) prev="config" ;;
        updatekeys) mode="updatekeys" ;;
        -d|--decrypt) mode="decrypt" ;;
        --*) ;;
        *)
            if [[ "$prev" == config ]]; then
                config="$arg"; prev=""
            else
                target="$arg"
            fi
            ;;
    esac
done
case "$mode" in
    updatekeys)
        if [[ "${MOCK_SOPS_SIGNAL:-}" == TERM ]]; then
            kill -TERM "$PPID"
            sleep 1
        elif [[ "${MOCK_SOPS_SIGNAL:-}" == INT ]]; then
            kill -INT "$PPID"
            sleep 1
        fi
        if [[ "${MOCK_SOPS_PAUSE:-}" == updatekeys ]]; then
            [[ -n "${MOCK_SIGNAL_READY:-}" ]] && : > "$MOCK_SIGNAL_READY"
            sleep 30
        fi
        [[ "${MOCK_SOPS_FAIL_OP:-}" == updatekeys ]] && exit 1
        cat "$config" >> "$target"
        printf '# mock-age=%s,%s\n' "$MOCK_NEW_RECIPIENT" "$MOCK_USB_RECIPIENT" >> "$target"
        ;;
    decrypt)
        canon(){ /usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
        if [[ "${MOCK_SOPS_FAIL_OP:-}" == decrypt_staged && -n "${MOCK_CIPHER_STAGING:-}" && "$(canon "$target")" == "$(canon "$MOCK_CIPHER_STAGING")" ]]; then exit 1; fi
        if [[ "${MOCK_SOPS_FAIL_OP:-}" == decrypt_live && -n "${MOCK_LIVE_CIPHER:-}" && "$(canon "$target")" == "$(canon "$MOCK_LIVE_CIPHER")" ]]; then exit 1; fi
        cat "$target" >/dev/null
        ;;
    *) exit 1 ;;
esac
SOPS
    cat > "$mock/flock" <<'FLOCK'
#!/usr/bin/env bash
contention_exit=1
nonblocking=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n) nonblocking=true; shift ;;
        -E) contention_exit="${2:-1}"; shift 2 ;;
        *) break ;;
    esac
done
[[ "$nonblocking" == true && "${MOCK_FLOCK_CONTENDED:-false}" == true ]] \
    && exit "$contention_exit"
exit 0
FLOCK
    cat > "$mock/mv" <<'MV'
#!/usr/bin/env bash
last="${@: -1}"
canon(){ /usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
if [[ -n "${MOCK_MV_FAIL_DEST:-}" && "$(canon "$last")" == "$(canon "$MOCK_MV_FAIL_DEST")" ]]; then
    exit 1
fi
if [[ -n "${MOCK_MV_SIGNAL_DEST:-}" && "$(canon "$last")" == "$(canon "$MOCK_MV_SIGNAL_DEST")" ]]; then
    /bin/mv "$@" || exit $?
    kill "-${MOCK_MV_SIGNAL_NAME:-TERM}" "$PPID"
    sleep 1
    exit 0
fi
exec /bin/mv "$@"
MV
    cat > "$mock/touch" <<'TOUCH'
#!/usr/bin/env bash
canon(){ /usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
for arg in "$@"; do
    if [[ -n "${MOCK_TOUCH_SIGNAL_PATH:-}" && "$(canon "$arg")" == "$(canon "$MOCK_TOUCH_SIGNAL_PATH")" ]]; then
        /usr/bin/touch "$@" || exit $?
        kill "-${MOCK_TOUCH_SIGNAL_NAME:-TERM}" "$PPID"
        sleep 1
        exit 0
    fi
done
exec /usr/bin/touch "$@"
TOUCH
    chmod +x "$mock"/*
}

run_recover() {
    local dir="$1" rc=0
    shift || true
    [[ -n "$dir" ]] || fail 'test dir required'
    export MOCK_USB_KEY_PATH="$dir/usb-key.txt"
    [[ -n "$MOCK_USB_KEY_PATH" ]] || fail 'MOCK_USB_KEY_PATH must be set'
    export MOCK_USB_RECIPIENT="$USB_RECIPIENT"
    export MOCK_NEW_RECIPIENT="$NEW_RECIPIENT"
    export MOCK_LIVE_CIPHER="$dir/state/secrets/secrets.yaml"
    set +e
    env PATH="$dir/mockbin:$PATH" \
        MOCK_FINDMNT_SOURCE="/dev/mock-source" \
        VW_TEST_MODE=true \
        VW_RECOVER_TEST_ALLOW_NON_ROOT=true \
        VW_RECOVER_ETC_DIR="$dir/etc" \
        VW_RECOVER_DEV_BY_UUID_DIR="$dir/dev-by-uuid" \
        VW_RECOVER_STARTUP_SCRIPT="$dir/startup.sh" \
        VW_OPERATIONS_LOCK="$dir/operations.lock" \
        VW_OPERATIONS_STATE_DIR="$dir/operations-state" \
        VW_TEST_RECOVERY_REPO="$dir/repo" \
        VW_TEST_NESTED_LOCK="$dir/startup.lock" \
        VW_TEST_RELEASE_LOG="${VW_TEST_RELEASE_LOG:-}" \
        MOCK_USB_KEY_PATH="$MOCK_USB_KEY_PATH" \
        MOCK_USB_RECIPIENT="$MOCK_USB_RECIPIENT" \
        MOCK_NEW_RECIPIENT="$MOCK_NEW_RECIPIENT" \
        MOCK_LIVE_CIPHER="$MOCK_LIVE_CIPHER" \
        MOCK_MOUNTPOINT_FAIL="${MOCK_MOUNTPOINT_FAIL:-false}" \
        MOCK_SOPS_FAIL_OP="${MOCK_SOPS_FAIL_OP:-}" \
        MOCK_SOPS_SIGNAL="${MOCK_SOPS_SIGNAL:-}" \
        MOCK_SOPS_PAUSE="${MOCK_SOPS_PAUSE:-}" \
        MOCK_SIGNAL_READY="${MOCK_SIGNAL_READY:-}" \
        MOCK_FLOCK_CONTENDED="${MOCK_FLOCK_CONTENDED:-false}" \
        MOCK_AGE_LOG="${MOCK_AGE_LOG:-}" \
        MOCK_MV_FAIL_DEST="${MOCK_MV_FAIL_DEST:-}" \
        MOCK_MV_SIGNAL_DEST="${MOCK_MV_SIGNAL_DEST:-}" \
        MOCK_MV_SIGNAL_NAME="${MOCK_MV_SIGNAL_NAME:-}" \
        MOCK_TOUCH_SIGNAL_PATH="${MOCK_TOUCH_SIGNAL_PATH:-}" \
        MOCK_TOUCH_SIGNAL_NAME="${MOCK_TOUCH_SIGNAL_NAME:-}" \
        MOCK_CURL_EXIT="${MOCK_CURL_EXIT:-0}" \
        bash "$dir/repo/recover.sh" --state-dir "$dir/state" --key "$dir/usb-key.txt" "$@" > "$dir/out" 2>&1
    rc=$?
    set -e
    return "$rc"
}

run_recover_async() {
    local dir="$1"
    shift || true
    export MOCK_USB_KEY_PATH="$dir/usb-key.txt"
    export MOCK_USB_RECIPIENT="$USB_RECIPIENT"
    export MOCK_NEW_RECIPIENT="$NEW_RECIPIENT"
    export MOCK_LIVE_CIPHER="$dir/state/secrets/secrets.yaml"
    env PATH="$dir/mockbin:$PATH" \
        MOCK_FINDMNT_SOURCE="/dev/mock-source" \
        VW_TEST_MODE=true \
        VW_RECOVER_TEST_ALLOW_NON_ROOT=true \
        VW_RECOVER_ETC_DIR="$dir/etc" \
        VW_RECOVER_DEV_BY_UUID_DIR="$dir/dev-by-uuid" \
        VW_RECOVER_STARTUP_SCRIPT="$dir/startup.sh" \
        VW_OPERATIONS_LOCK="$dir/operations.lock" \
        VW_OPERATIONS_STATE_DIR="$dir/operations-state" \
        VW_TEST_RECOVERY_REPO="$dir/repo" \
        VW_TEST_NESTED_LOCK="$dir/startup.lock" \
        VW_TEST_RELEASE_LOG="${VW_TEST_RELEASE_LOG:-}" \
        MOCK_USB_KEY_PATH="$MOCK_USB_KEY_PATH" \
        MOCK_USB_RECIPIENT="$MOCK_USB_RECIPIENT" \
        MOCK_NEW_RECIPIENT="$MOCK_NEW_RECIPIENT" \
        MOCK_LIVE_CIPHER="$MOCK_LIVE_CIPHER" \
        MOCK_MOUNTPOINT_FAIL="${MOCK_MOUNTPOINT_FAIL:-false}" \
        MOCK_SOPS_FAIL_OP="${MOCK_SOPS_FAIL_OP:-}" \
        MOCK_SOPS_SIGNAL="${MOCK_SOPS_SIGNAL:-}" \
        MOCK_SOPS_PAUSE="${MOCK_SOPS_PAUSE:-}" \
        MOCK_SIGNAL_READY="${MOCK_SIGNAL_READY:-}" \
        MOCK_FLOCK_CONTENDED="${MOCK_FLOCK_CONTENDED:-false}" \
        MOCK_AGE_LOG="${MOCK_AGE_LOG:-}" \
        MOCK_MV_FAIL_DEST="${MOCK_MV_FAIL_DEST:-}" \
        MOCK_MV_SIGNAL_DEST="${MOCK_MV_SIGNAL_DEST:-}" \
        MOCK_MV_SIGNAL_NAME="${MOCK_MV_SIGNAL_NAME:-}" \
        MOCK_TOUCH_SIGNAL_PATH="${MOCK_TOUCH_SIGNAL_PATH:-}" \
        MOCK_TOUCH_SIGNAL_NAME="${MOCK_TOUCH_SIGNAL_NAME:-}" \
        MOCK_CURL_EXIT="${MOCK_CURL_EXIT:-0}" \
        bash "$dir/repo/recover.sh" --state-dir "$dir/state" --key "$dir/usb-key.txt" "$@" > "$dir/out" 2>&1 &
    printf '%s\n' "$!"
}

setup_startup() {
    local dir="$1"
    cat > "$dir/startup.sh" <<'START'
#!/usr/bin/env bash
echo 'mock startup: OK'
START
    chmod +x "$dir/startup.sh"
}

setup_startup_with_env_sync() {
    local dir="$1"
    cat > "$dir/startup.sh" <<START
#!/usr/bin/env bash
set -euo pipefail
if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo -n env VW_SYNC_ETC_DIR="$dir/etc" "$dir/repo/utilities/env-edit.sh" sync
    echo 'env-sync: ran'
else
    echo 'env-sync: skipped'
fi
echo 'mock startup: OK'
START
    chmod +x "$dir/startup.sh"
}

test_missing_state_dir() {
    local out="$TEST_ROOT/missing-state.out"
    if bash "$ROOT/recover.sh" --key /nope > "$out" 2>&1; then fail 'missing state should fail'; fi
    grep -q 'Usage: ./recover.sh --state-dir DIR --key FILE' "$out" || fail 'usage missing'
}

test_missing_key() {
    local out="$TEST_ROOT/missing-key.out"
    if bash "$ROOT/recover.sh" --state-dir /nope > "$out" 2>&1; then fail 'missing key should fail'; fi
    grep -q 'Usage: ./recover.sh --state-dir DIR --key FILE' "$out" || fail 'usage missing'
}

test_non_root_bypass_requires_test_mode() {
    if [[ $EUID -eq 0 ]]; then
        return 0
    fi
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    if env PATH="$dir/mockbin:$PATH" \
        VW_RECOVER_TEST_ALLOW_NON_ROOT=true \
        VW_RECOVER_ETC_DIR="$dir/etc" \
        VW_RECOVER_DEV_BY_UUID_DIR="$dir/dev-by-uuid" \
        VW_RECOVER_STARTUP_SCRIPT="$dir/startup.sh" \
        bash "$dir/repo/recover.sh" --state-dir "$dir/state" --key "$dir/usb-key.txt" > "$dir/out" 2>&1; then
        fail 'single-variable non-root bypass should fail'
    fi
    grep -q 'ERROR: Must run as root.' "$dir/out" || fail 'root error missing when VW_TEST_MODE is absent'
}

test_missing_flock_is_rejected() {
    local dir noflock bash_path cmd file
    dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    noflock="$dir/noflock-bin"
    mkdir -p "$noflock"
    for file in "$dir/mockbin"/*; do
        [[ "${file##*/}" == flock ]] && continue
        ln -s "$file" "$noflock/${file##*/}"
    done
    for cmd in awk bash basename dirname install tr; do
        ln -s "$(command -v "$cmd")" "$noflock/$cmd"
    done
    bash_path="$(command -v bash)"
    if env PATH="$noflock" \
        VW_TEST_MODE=true \
        VW_RECOVER_TEST_ALLOW_NON_ROOT=true \
        VW_RECOVER_ETC_DIR="$dir/etc" \
        VW_RECOVER_DEV_BY_UUID_DIR="$dir/dev-by-uuid" \
        VW_RECOVER_STARTUP_SCRIPT="$dir/startup.sh" \
        "$bash_path" "$dir/repo/recover.sh" --state-dir "$dir/state" --key "$dir/usb-key.txt" > "$dir/out" 2>&1; then
        fail 'recovery without flock should fail prerequisite validation'
    fi
    grep -q 'ERROR: Missing required command: flock' "$dir/out" || {
        cat "$dir/out"
        fail 'missing flock prerequisite error not reported'
    }
}

test_contention_prevents_recovery_mutation() {
    local dir rc
    dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"; snapshot_recovery_state "$dir"
    rm -f "$dir/repo/.env"
    set +e
    ( MOCK_FLOCK_CONTENDED=true MOCK_AGE_LOG="$dir/age.log" run_recover "$dir" )
    rc=$?
    set -e
    [[ "$rc" -eq 75 ]] || { cat "$dir/out"; fail "contention expected 75, got $rc"; }
    assert_recovery_state_unchanged "$dir" 'operation contention'
    assert_file_missing "$dir/repo/.env"
    ! grep -q '^-o ' "$dir/age.log" || fail 'operational key was generated after recovery contention'
    ! grep -q 'mock startup: OK' "$dir/out" || fail 'startup ran after recovery contention'
    if find "$dir/state/config" "$dir/state/secrets" "$dir/repo" "$dir/etc" -type f \
        \( -name 'secrets.*.yaml' -o -name '.sops.yaml.*' -o -name 'install.env.*' -o -name 'dr-manifest.env.*' -o -name '.age-key.txt.*' \) \
        | grep -q .; then
        fail 'recovery staging artifact created after contention'
    fi
}

test_success_records_and_releases_recovery_operation() {
    local dir list_output release_count
    dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    if ! VW_TEST_RELEASE_LOG="$dir/release.log" run_recover "$dir"; then
        cat "$dir/out"
        fail 'guarded recovery should succeed'
    fi
    grep -qx 'operation=recovery' "$dir/operations-state/recovery.state" || fail 'recovery operation id missing from state'
    grep -qx 'label=Recovery' "$dir/operations-state/recovery.state" || fail 'Recovery label missing from state'
    grep -qx 'state=complete' "$dir/operations-state/recovery.state" || fail 'recovery operation was not completed during cleanup'
    release_count="$(wc -l < "$dir/release.log" | tr -d '[:space:]')"
    [[ "$release_count" == 1 ]] || fail "cleanup released recovery guard $release_count times"
    grep -qx '0' "$dir/release.log" || fail 'successful recovery release status mismatch'
    list_output="$(env VW_OPERATIONS_LOCK="$dir/operations.lock" VW_OPERATIONS_STATE_DIR="$dir/operations-state" \
        bash -c 'source "$1"; operation_list' _ "$dir/repo/lib/operations.sh")"
    grep -q '^Recovery$' <<< "$list_output" || fail 'Recovery missing from operation inventory'
}

test_nested_startup_inherits_recovery_operation() {
    local dir
    if [[ "$(uname -s)" != Linux || ! -d "/proc/$$/fd" ]] || ! command -v flock >/dev/null 2>&1; then
        printf '# SKIP nested recovery/startup inheritance requires Linux /proc and real flock\n'
        return 0
    fi
    dir=$(make_case); write_mocks "$dir"
    rm -f "$dir/mockbin/flock"
    cat > "$dir/startup.sh" <<'NESTED_STARTUP'
#!/usr/bin/env bash
set -euo pipefail
source "${VW_TEST_RECOVERY_REPO}/lib/operations.sh"
operation_acquire \
    --id startup \
    --label "Startup" \
    --specific-lock "$VW_TEST_NESTED_LOCK" \
    --non-interactive skip
[[ "$OPERATION_OWNS_GLOBAL" == false ]]
[[ "$OPERATION_OWNS_STATE" == false ]]
[[ "$OPERATION_STATE_FILE" == "$VW_OPERATION_PARENT_STATE" ]]
[[ "$VW_OPERATION_PARENT_ID" == recovery ]]
printf 'nested startup inherited recovery operation\n'
operation_release 0
NESTED_STARTUP
    chmod +x "$dir/startup.sh"
    if ! run_recover "$dir"; then
        cat "$dir/out"
        fail 'nested startup should inherit the recovery operation'
    fi
    grep -q 'nested startup inherited recovery operation' "$dir/out" || fail 'nested startup inheritance marker missing'
}

test_non_mounted() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    if MOCK_MOUNTPOINT_FAIL=true run_recover "$dir" --storage-mode block; then fail 'non-mounted block should fail'; fi
    grep -q 'ERROR: State directory is not a mounted data/block volume. Attach and mount the data volume first.' "$dir/out" || fail 'mount error mismatch'
}

test_boot_mode_clears_block_env() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    if ! MOCK_MOUNTPOINT_FAIL=true run_recover "$dir" --storage-mode boot; then cat "$dir/out"; fail 'boot mode should not require mountpoint'; fi
    [[ "$(canonical_path "$(env_value PROJECT_STATE_DIR "$dir/state/config/install.env")")" == "$(canonical_path "$dir/state")" ]] || fail 'project state not set'
    grep -q '^DATA_VOLUME_MOUNT=$' "$dir/state/config/install.env" || fail 'data mount not cleared'
    grep -q '^DATA_VOLUME_DEVICE=$' "$dir/state/config/install.env" || fail 'data device not cleared'
}

test_block_mode_uuid_device() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    mkdir -p "$dir/dev-by-uuid"
    touch "$dir/mock-source"
    ln -sf "$dir/mock-source" "$dir/dev-by-uuid/1111-2222"
    if ! run_recover "$dir" --storage-mode block; then cat "$dir/out"; fail 'block mode should succeed'; fi
    grep -q "^DATA_VOLUME_DEVICE=$dir/dev-by-uuid/1111-2222$" "$dir/state/config/install.env" || fail 'uuid device path not used'
    [[ -e "$dir/state/.vw-data-volume" ]] || fail 'sentinel missing'
}

test_final_permissions() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    chmod 0777 "$dir/state/config/install.env" "$dir/state/config/dr-manifest.env" "$dir/state/secrets/secrets.yaml" "$dir/repo/.sops.yaml" "$dir/etc/age-key.txt"
    if ! run_recover "$dir" --storage-mode boot; then cat "$dir/out"; fail 'permissions case failed'; fi
    [[ "$(file_mode "$dir/repo/.sops.yaml")" == "644" ]] || fail '.sops mode mismatch'
    [[ "$(file_mode "$dir/etc/age-key.txt")" == "600" ]] || fail 'active key mode mismatch'
    [[ "$(file_mode "$dir/state/config/install.env")" == "600" ]] || fail 'install env mode mismatch'
    [[ "$(file_mode "$dir/state/config/dr-manifest.env")" == "600" ]] || fail 'manifest mode mismatch'
    [[ "$(file_mode "$dir/state/secrets/secrets.yaml")" == "600" ]] || fail 'secrets mode mismatch'
}

test_cleanup_removes_staged_key() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    if MOCK_SOPS_FAIL_OP=updatekeys run_recover "$dir" --storage-mode boot; then fail 'updatekeys failure should fail'; fi
    if find "$dir" -name 'new-age-key.txt' -type f | grep -q .; then fail 'staged private key leaked'; fi
}

test_updatekeys_failure() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    cp "$dir/state/secrets/secrets.yaml" "$dir/cipher.before"; cp "$dir/etc/age-key.txt" "$dir/key.before"; cp "$dir/repo/.sops.yaml" "$dir/policy.before"; cp "$dir/state/config/install.env" "$dir/install.before"; cp "$dir/state/config/dr-manifest.env" "$dir/manifest.before"
    if MOCK_SOPS_FAIL_OP=updatekeys run_recover "$dir"; then fail 'updatekeys failure should fail'; fi
    assert_file_equals "$dir/cipher.before" "$dir/state/secrets/secrets.yaml" 'cipher changed on updatekeys failure'
    assert_file_equals "$dir/key.before" "$dir/etc/age-key.txt" 'key changed on updatekeys failure'
    assert_file_equals "$dir/policy.before" "$dir/repo/.sops.yaml" 'policy changed on updatekeys failure'
    assert_file_equals "$dir/install.before" "$dir/state/config/install.env" 'install.env changed on updatekeys failure'
    assert_file_equals "$dir/manifest.before" "$dir/state/config/dr-manifest.env" 'manifest changed on updatekeys failure'
}

test_active_key_promotion_failure() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    cp "$dir/state/secrets/secrets.yaml" "$dir/cipher.before"; cp "$dir/etc/age-key.txt" "$dir/key.before"; cp "$dir/repo/.sops.yaml" "$dir/policy.before"
    if MOCK_MV_FAIL_DEST="$dir/etc/age-key.txt" run_recover "$dir"; then fail 'key promotion failure should fail'; fi
    assert_file_equals "$dir/cipher.before" "$dir/state/secrets/secrets.yaml" 'cipher not restored after key failure'
    assert_file_equals "$dir/key.before" "$dir/etc/age-key.txt" 'key not restored after key failure'
    assert_file_equals "$dir/policy.before" "$dir/repo/.sops.yaml" 'policy changed after key failure'
}

test_policy_promotion_failure() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    cp "$dir/state/secrets/secrets.yaml" "$dir/cipher.before"; cp "$dir/etc/age-key.txt" "$dir/key.before"; cp "$dir/repo/.sops.yaml" "$dir/policy.before"
    if MOCK_MV_FAIL_DEST="$dir/repo/.sops.yaml" run_recover "$dir"; then fail 'policy promotion failure should fail'; fi
    assert_file_equals "$dir/cipher.before" "$dir/state/secrets/secrets.yaml" 'cipher not restored after policy failure'
    assert_file_equals "$dir/key.before" "$dir/etc/age-key.txt" 'key not restored after policy failure'
    assert_file_equals "$dir/policy.before" "$dir/repo/.sops.yaml" 'policy not restored after policy failure'
}

test_install_env_promotion_failure_rolls_back_all_artifacts() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    cp "$dir/state/secrets/secrets.yaml" "$dir/cipher.before"; cp "$dir/etc/age-key.txt" "$dir/key.before"; cp "$dir/repo/.sops.yaml" "$dir/policy.before"; cp "$dir/state/config/install.env" "$dir/install.before"; cp "$dir/state/config/dr-manifest.env" "$dir/manifest.before"
    if MOCK_MV_FAIL_DEST="$dir/state/config/install.env" run_recover "$dir"; then fail 'install.env promotion failure should fail'; fi
    assert_file_equals "$dir/cipher.before" "$dir/state/secrets/secrets.yaml" 'cipher not restored after install.env failure'
    assert_file_equals "$dir/key.before" "$dir/etc/age-key.txt" 'key not restored after install.env failure'
    assert_file_equals "$dir/policy.before" "$dir/repo/.sops.yaml" 'policy not restored after install.env failure'
    assert_file_equals "$dir/install.before" "$dir/state/config/install.env" 'install.env not restored after install.env failure'
    assert_file_equals "$dir/manifest.before" "$dir/state/config/dr-manifest.env" 'manifest changed after install.env failure'
}

test_final_decrypt_failure_no_prior_artifacts() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    rm -f "$dir/etc/age-key.txt" "$dir/repo/.sops.yaml"
    cp "$dir/state/secrets/secrets.yaml" "$dir/cipher.before"; cp "$dir/state/config/install.env" "$dir/install.before"; cp "$dir/state/config/dr-manifest.env" "$dir/manifest.before"
    if MOCK_SOPS_FAIL_OP=decrypt_live run_recover "$dir"; then fail 'live decrypt failure should fail'; fi
    assert_file_equals "$dir/cipher.before" "$dir/state/secrets/secrets.yaml" 'cipher not restored after final decrypt failure'
    assert_file_equals "$dir/install.before" "$dir/state/config/install.env" 'install.env not restored after final decrypt failure'
    assert_file_equals "$dir/manifest.before" "$dir/state/config/dr-manifest.env" 'manifest not restored after final decrypt failure'
    assert_file_missing "$dir/etc/age-key.txt"
    assert_file_missing "$dir/repo/.sops.yaml"
    assert_file_missing "$dir/state/.vw-data-volume"
}

test_existing_sentinel_survives_precommit_failure() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    touch "$dir/state/.vw-data-volume"
    if MOCK_SOPS_FAIL_OP=decrypt_live run_recover "$dir"; then fail 'live decrypt failure should fail'; fi
    [[ -e "$dir/state/.vw-data-volume" ]] || fail 'pre-existing sentinel was removed'
}

test_precommit_signals_exit_and_do_not_continue() {
    local sig expected_rc dir
    for sig in INT TERM; do
        dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
        cp "$dir/state/secrets/secrets.yaml" "$dir/cipher.before"; cp "$dir/etc/age-key.txt" "$dir/key.before"; cp "$dir/repo/.sops.yaml" "$dir/policy.before"; cp "$dir/state/config/install.env" "$dir/install.before"; cp "$dir/state/config/dr-manifest.env" "$dir/manifest.before"
        expected_rc=130
        [[ "$sig" == TERM ]] && expected_rc=143
        local rc
        set +e
        ( MOCK_SOPS_SIGNAL="$sig" run_recover "$dir" )
        rc=$?
        set -e
        [[ "$rc" -eq "$expected_rc" ]] || fail "$sig expected exit $expected_rc, got $rc"
        ! grep -q 'mock startup: OK' "$dir/out" || fail "$sig continued into startup"
        assert_file_equals "$dir/cipher.before" "$dir/state/secrets/secrets.yaml" "cipher changed after $sig"
        assert_file_equals "$dir/key.before" "$dir/etc/age-key.txt" "key changed after $sig"
        assert_file_equals "$dir/policy.before" "$dir/repo/.sops.yaml" "policy changed after $sig"
        assert_file_equals "$dir/install.before" "$dir/state/config/install.env" "install.env changed after $sig"
        assert_file_equals "$dir/manifest.before" "$dir/state/config/dr-manifest.env" "manifest changed after $sig"
    done
}

assert_recovery_state_unchanged() {
    local dir="$1" label="$2"
    assert_file_equals "$dir/cipher.before" "$dir/state/secrets/secrets.yaml" "cipher changed after $label"
    assert_file_equals "$dir/key.before" "$dir/etc/age-key.txt" "key changed after $label"
    assert_file_equals "$dir/policy.before" "$dir/repo/.sops.yaml" "policy changed after $label"
    assert_file_equals "$dir/install.before" "$dir/state/config/install.env" "install.env changed after $label"
    assert_file_equals "$dir/manifest.before" "$dir/state/config/dr-manifest.env" "manifest changed after $label"
}

snapshot_recovery_state() {
    local dir="$1"
    cp "$dir/state/secrets/secrets.yaml" "$dir/cipher.before"
    cp "$dir/etc/age-key.txt" "$dir/key.before"
    cp "$dir/repo/.sops.yaml" "$dir/policy.before"
    cp "$dir/state/config/install.env" "$dir/install.before"
    cp "$dir/state/config/dr-manifest.env" "$dir/manifest.before"
}

test_signal_after_live_cipher_mutation_rolls_back() {
    local dir rc
    dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"; snapshot_recovery_state "$dir"
    set +e
    ( MOCK_MV_SIGNAL_DEST="$dir/state/secrets/secrets.yaml" MOCK_MV_SIGNAL_NAME=TERM run_recover "$dir" )
    rc=$?
    set -e
    [[ "$rc" -eq 143 ]] || fail "live cipher mutation signal expected 143, got $rc"
    ! grep -q 'mock startup: OK' "$dir/out" || fail 'continued into startup after live cipher signal'
    assert_recovery_state_unchanged "$dir" 'live cipher signal'
}

test_signal_after_new_sentinel_mutation_rolls_back() {
    local dir rc
    dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"; snapshot_recovery_state "$dir"
    set +e
    ( MOCK_TOUCH_SIGNAL_PATH="$dir/state/.vw-data-volume" MOCK_TOUCH_SIGNAL_NAME=TERM run_recover "$dir" --storage-mode block )
    rc=$?
    set -e
    [[ "$rc" -eq 143 ]] || fail "sentinel mutation signal expected 143, got $rc"
    ! grep -q 'mock startup: OK' "$dir/out" || fail 'continued into startup after sentinel signal'
    assert_recovery_state_unchanged "$dir" 'sentinel signal'
    assert_file_missing "$dir/state/.vw-data-volume"
}

test_reconciles_absent_repo_env_before_startup_sync() {
    local dir
    dir=$(make_case); write_mocks "$dir"; setup_startup_with_env_sync "$dir"
    rm -f "$dir/repo/.env"
    if ! run_recover "$dir" --storage-mode boot; then cat "$dir/out"; fail 'absent repo env recovery failed'; fi
    [[ -f "$dir/repo/.env" ]] || fail 'repo .env was not created'
    [[ "$(canonical_path "$(env_value PROJECT_STATE_DIR "$dir/repo/.env")")" == "$(canonical_path "$dir/state")" ]] || fail 'repo .env PROJECT_STATE_DIR not recovered'
    env_has_value DATA_VOLUME_MOUNT "" "$dir/repo/.env" || fail 'repo .env boot DATA_VOLUME_MOUNT not blank'
    env_has_value DATA_VOLUME_DEVICE "" "$dir/repo/.env" || fail 'repo .env boot DATA_VOLUME_DEVICE not blank'
    ! grep -q '^SOPS_AGE_KEY_FILE=' "$dir/repo/.env" || fail 'runtime SOPS_AGE_KEY_FILE leaked into repo .env'
    ! grep -q '^RCLONE_CONFIG=' "$dir/repo/.env" || fail 'runtime RCLONE_CONFIG leaked into repo .env'
    if grep -q 'env-sync: ran' "$dir/out"; then
        [[ "$(canonical_path "$(env_value PROJECT_STATE_DIR "$dir/state/config/install.env")")" == "$(canonical_path "$dir/state")" ]] || fail 'env sync undid recovered PROJECT_STATE_DIR'
        env_has_value DATA_VOLUME_MOUNT "" "$dir/state/config/install.env" || fail 'env sync undid boot DATA_VOLUME_MOUNT'
        env_has_value DATA_VOLUME_DEVICE "" "$dir/state/config/install.env" || fail 'env sync undid boot DATA_VOLUME_DEVICE'
    fi
}

test_reconciles_stale_repo_env_before_startup_sync() {
    local dir
    dir=$(make_case); write_mocks "$dir"; setup_startup_with_env_sync "$dir"
    cat > "$dir/repo/.env" <<EOF_STALE
PROJECT_STATE_DIR=$dir/stale-state
DATA_VOLUME_MOUNT=$dir/stale-mount
DATA_VOLUME_DEVICE=/dev/stale
SOPS_AGE_KEY_FILE=$dir/stale-key.txt
RCLONE_CONFIG=$dir/stale-rclone.conf
EOF_STALE
    if ! run_recover "$dir" --storage-mode boot; then cat "$dir/out"; fail 'stale repo env recovery failed'; fi
    [[ "$(canonical_path "$(env_value PROJECT_STATE_DIR "$dir/repo/.env")")" == "$(canonical_path "$dir/state")" ]] || fail 'stale repo .env PROJECT_STATE_DIR was not reconciled'
    env_has_value DATA_VOLUME_MOUNT "" "$dir/repo/.env" || fail 'stale repo .env DATA_VOLUME_MOUNT was not reconciled'
    env_has_value DATA_VOLUME_DEVICE "" "$dir/repo/.env" || fail 'stale repo .env DATA_VOLUME_DEVICE was not reconciled'
    ! grep -q '^SOPS_AGE_KEY_FILE=' "$dir/repo/.env" || fail 'stale runtime SOPS_AGE_KEY_FILE persisted into repo .env'
    ! grep -q '^RCLONE_CONFIG=' "$dir/repo/.env" || fail 'stale runtime RCLONE_CONFIG persisted into repo .env'
    if grep -q 'env-sync: ran' "$dir/out"; then
        [[ "$(canonical_path "$(env_value PROJECT_STATE_DIR "$dir/state/config/install.env")")" == "$(canonical_path "$dir/state")" ]] || fail 'env sync restored stale PROJECT_STATE_DIR'
        env_has_value DATA_VOLUME_MOUNT "" "$dir/state/config/install.env" || fail 'env sync restored stale DATA_VOLUME_MOUNT'
        env_has_value DATA_VOLUME_DEVICE "" "$dir/state/config/install.env" || fail 'env sync restored stale DATA_VOLUME_DEVICE'
    fi
}

test_success_fresh_clone() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    rm -f "$dir/repo/.sops.yaml"
    if ! run_recover "$dir"; then cat "$dir/out"; fail 'happy path failed'; fi
    grep -q 'mock startup: OK' "$dir/out" || fail 'startup output missing'
    [[ -f "$dir/etc/age-key.txt" ]] || fail 'new operational key missing'
    grep -q "# mock-age=$NEW_RECIPIENT,$USB_RECIPIENT" "$dir/state/secrets/secrets.yaml" || fail 'cipher metadata missing mock recipients'
    grep -q "$NEW_RECIPIENT,$USB_RECIPIENT" "$dir/repo/.sops.yaml" || fail 'policy recipients missing'
    [[ "$(canonical_path "$(env_value SOPS_AGE_KEY_FILE "$dir/state/config/install.env")")" == "$(canonical_path "$dir/etc/age-key.txt")" ]] || fail 'install.env not updated'
    grep -q "OFFLINE_AGE_RECIPIENT=$USB_RECIPIENT" "$dir/state/config/dr-manifest.env" || fail 'manifest recipient not updated'
    grep -q '^MANIFEST_UPDATED_AT=' "$dir/state/config/dr-manifest.env" || fail 'manifest timestamp missing'
    grep -q 'Recovery complete. Vaultwarden passed health check at https://vault.example.test/alive' "$dir/out" || fail 'health success message missing'
}

test_startup_failure_returns_nonzero_without_rollback() {
    local dir; dir=$(make_case); write_mocks "$dir"
    cat > "$dir/startup.sh" <<'START'
#!/usr/bin/env bash
echo 'mock startup: FAIL'
exit 42
START
    chmod +x "$dir/startup.sh"
    if run_recover "$dir"; then fail 'startup failure should return non-zero'; fi
    grep -q 'Startup: FAIL' "$dir/out" || fail 'startup failure marker missing'
    grep -q 'Committed recovery identity/config remains installed.' "$dir/out" || fail 'startup failure commit message missing'
    grep -q "# mock-age=$NEW_RECIPIENT,$USB_RECIPIENT" "$dir/state/secrets/secrets.yaml" || fail 'cipher artifacts rolled back after startup failure'
    grep -q 'new-private-key' "$dir/etc/age-key.txt" || fail 'active key rolled back after startup failure'
    grep -q "$NEW_RECIPIENT,$USB_RECIPIENT" "$dir/repo/.sops.yaml" || fail 'policy rolled back after startup failure'
}

test_health_failure_reports_nonzero_without_rollback() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    if MOCK_CURL_EXIT=22 run_recover "$dir"; then fail 'health failure should return non-zero'; fi
    if grep -q 'Vaultwarden is running' "$dir/out"; then fail 'health failure must not say Vaultwarden is running'; fi
    grep -q 'Health check: FAIL' "$dir/out" || fail 'health failure marker missing'
    grep -q 'Recovery artifacts were promoted, but Vaultwarden did not pass the health check.' "$dir/out" || fail 'partial-success message missing'
    grep -q 'Committed recovery identity/config remains installed.' "$dir/out" || fail 'committed artifacts message missing'
    grep -q 'Do not treat the service as healthy until the checks below pass.' "$dir/out" || fail 'operator warning missing'
    grep -Eq 'docker compose -f .*docker-compose\.yml ps' "$dir/out" || fail 'compose ps next step missing'
    grep -Eq 'docker compose -f .*docker-compose\.yml logs --tail=200' "$dir/out" || fail 'compose logs next step missing'
    grep -q 'Failed health URL: https://vault.example.test/alive' "$dir/out" || fail 'failed alive URL missing'
    grep -q "# mock-age=$NEW_RECIPIENT,$USB_RECIPIENT" "$dir/state/secrets/secrets.yaml" || fail 'cipher artifacts rolled back after health failure'
    grep -q 'new-private-key' "$dir/etc/age-key.txt" || fail 'active key rolled back after health failure'
    grep -q "$NEW_RECIPIENT,$USB_RECIPIENT" "$dir/repo/.sops.yaml" || fail 'policy rolled back after health failure'
}


# Keep each runner-owned case comfortably within the repository's unchanged
# 120-second per-case deadline. The companion case executes the other half;
# skipped TAP entries keep each shard's plan deterministic and visible.
_RESTORE_RECOVERY_SHARD_SPLIT=13
_restore_recovery_run_test_index=0
_restore_recovery_skip_test() { return 0; }

run_test() {
    local name="${1:-unnamed restore-recovery test}"
    local shard="${VAULTWARDEN_RESTORE_RECOVERY_SHARD:-main}"

    _restore_recovery_run_test_index=$((_restore_recovery_run_test_index + 1))
    case "$shard" in
        main)
            if (( _restore_recovery_run_test_index > _RESTORE_RECOVERY_SHARD_SPLIT )); then
                _restore_recovery_run_test_impl \
                    "${name} # SKIP exercised by case-restore-recovery-tail.bash" \
                    _restore_recovery_skip_test
                return
            fi
            ;;
        tail)
            if (( _restore_recovery_run_test_index <= _RESTORE_RECOVERY_SHARD_SPLIT )); then
                _restore_recovery_run_test_impl \
                    "${name} # SKIP exercised by case-restore-recovery.bash" \
                    _restore_recovery_skip_test
                return
            fi
            ;;
        *)
            printf 'FAIL: invalid VAULTWARDEN_RESTORE_RECOVERY_SHARD: %s\n' "$shard" >&2
            return 2
            ;;
    esac

    _restore_recovery_run_test_impl "$@"
}

run_test 'missing --state-dir prints usage and fails' test_missing_state_dir
run_test 'missing --key prints usage and fails' test_missing_key
run_test 'non-root bypass requires VW_TEST_MODE and recover flag' test_non_root_bypass_requires_test_mode
run_test 'flock is a required recovery prerequisite' test_missing_flock_is_rejected
run_test 'operation contention exits 75 before recovery mutation' test_contention_prevents_recovery_mutation
run_test 'recovery operation is recorded, listed, and released exactly once' test_success_records_and_releases_recovery_operation
run_test 'nested startup inherits recovery operation without self-contention' test_nested_startup_inherits_recovery_operation
run_test 'non-mounted state directory prints exact message' test_non_mounted
run_test 'boot storage mode clears block-volume env values' test_boot_mode_clears_block_env
run_test 'block storage mode writes UUID device path and sentinel' test_block_mode_uuid_device
run_test 'final permissions match split contract' test_final_permissions
run_test 'cleanup removes staged private key on failure' test_cleanup_removes_staged_key
run_test 'sops updatekeys failure leaves artifacts unchanged' test_updatekeys_failure
run_test 'active-key promotion failure rolls back artifacts' test_active_key_promotion_failure
run_test 'policy promotion failure rolls back artifacts' test_policy_promotion_failure
run_test 'install.env promotion failure rolls back full recovery scope' test_install_env_promotion_failure_rolls_back_all_artifacts
run_test 'final live-decryption failure restores absent artifacts' test_final_decrypt_failure_no_prior_artifacts
run_test 'pre-existing block sentinel survives pre-commit failure' test_existing_sentinel_survives_precommit_failure
run_test 'pre-commit INT and TERM exit with signal status and stop execution' test_precommit_signals_exit_and_do_not_continue
run_test 'signal after live ciphertext mutation rolls back' test_signal_after_live_cipher_mutation_rolls_back
run_test 'signal after new sentinel mutation rolls back' test_signal_after_new_sentinel_mutation_rolls_back
run_test 'fresh recovery creates repo env before startup sync' test_reconciles_absent_repo_env_before_startup_sync
run_test 'stale repo env is reconciled before startup sync' test_reconciles_stale_repo_env_before_startup_sync
run_test 'successful fresh-clone recovery updates all artifacts' test_success_fresh_clone
run_test 'startup failure after commit exits non-zero without rollback' test_startup_failure_returns_nonzero_without_rollback
run_test 'health-check failure after commit exits non-zero without rollback' test_health_failure_reports_nonzero_without_rollback

[[ "$TESTS_RUN" -eq 26 ]] || fail "expected 26 tests, ran $TESTS_RUN"
printf '1..%s\n' "$TESTS_RUN"

)

check_recovery_contracts
