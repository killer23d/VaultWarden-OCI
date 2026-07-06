#!/usr/bin/env bash
# Consolidated restore and recovery regression suite.
set -euo pipefail

check_restore_run_contracts() (
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
require_pattern 'trap _restore_safety_net ERR HUP INT TERM' 'restore-run must arm safety-net trap around stopped-service restore work'
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
require 'RESTORE_SAVED_ACK_TIMEOUT.*Type SAVED' "$RESTORE" \
  "SAVED acknowledgement must use bounded timeout"

printf 'PASS: restore confirmation safety\n'

)

check_restore_confirmation_safety
check_restore_preflight_and_cross_layout_safety() (
# shellcheck disable=SC2016
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
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
age(){ printf '%s\n' "\$*" > "$TMP/age.args"; : > "\$4" 2>/dev/null || true; }
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
check_recovery_contracts() (
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

run_test() {
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
        MOCK_USB_KEY_PATH="$MOCK_USB_KEY_PATH" \
        MOCK_USB_RECIPIENT="$MOCK_USB_RECIPIENT" \
        MOCK_NEW_RECIPIENT="$MOCK_NEW_RECIPIENT" \
        MOCK_LIVE_CIPHER="$MOCK_LIVE_CIPHER" \
        MOCK_MOUNTPOINT_FAIL="${MOCK_MOUNTPOINT_FAIL:-false}" \
        MOCK_SOPS_FAIL_OP="${MOCK_SOPS_FAIL_OP:-}" \
        MOCK_SOPS_SIGNAL="${MOCK_SOPS_SIGNAL:-}" \
        MOCK_SOPS_PAUSE="${MOCK_SOPS_PAUSE:-}" \
        MOCK_SIGNAL_READY="${MOCK_SIGNAL_READY:-}" \
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
        MOCK_USB_KEY_PATH="$MOCK_USB_KEY_PATH" \
        MOCK_USB_RECIPIENT="$MOCK_USB_RECIPIENT" \
        MOCK_NEW_RECIPIENT="$MOCK_NEW_RECIPIENT" \
        MOCK_LIVE_CIPHER="$MOCK_LIVE_CIPHER" \
        MOCK_MOUNTPOINT_FAIL="${MOCK_MOUNTPOINT_FAIL:-false}" \
        MOCK_SOPS_FAIL_OP="${MOCK_SOPS_FAIL_OP:-}" \
        MOCK_SOPS_SIGNAL="${MOCK_SOPS_SIGNAL:-}" \
        MOCK_SOPS_PAUSE="${MOCK_SOPS_PAUSE:-}" \
        MOCK_SIGNAL_READY="${MOCK_SIGNAL_READY:-}" \
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

run_test 'missing --state-dir prints usage and fails' test_missing_state_dir
run_test 'missing --key prints usage and fails' test_missing_key
run_test 'non-root bypass requires VW_TEST_MODE and recover flag' test_non_root_bypass_requires_test_mode
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

[[ "$TESTS_RUN" -eq 22 ]] || fail "expected 22 tests, ran $TESTS_RUN"
printf '1..%s\n' "$TESTS_RUN"

)

check_recovery_contracts
