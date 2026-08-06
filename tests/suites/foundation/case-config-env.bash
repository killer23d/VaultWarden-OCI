#!/usr/bin/env bash
# Consolidated configuration and environment regression suite.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

check_env_edit_contracts() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
fail(){ echo "FAIL: $*" >&2; exit 1; }
pass(){ echo "PASS: $*"; }

assert_contains(){ grep -Fq -- "$2" "$1" || fail "$3"; }
assert_not_contains(){ ! grep -Fq -- "$2" "$1" || fail "$3"; }

# Makefile/caller wiring.
awk '/^sync-env: /,/^edit-env:/' "$ROOT/Makefile" | grep -Fq './utilities/env-edit.sh sync' || fail 'make sync-env does not call env-edit.sh sync'
awk '/^edit-env: /,/^edit-secrets:/' "$ROOT/Makefile" | grep -Fq './utilities/env-edit.sh edit' || fail 'make edit-env does not call env-edit.sh edit'
awk '/^up: /,/^start:/' "$ROOT/Makefile" | grep -Fq './startup.sh' || fail 'make up must call startup.sh'
! awk '/^up: /,/^start:/' "$ROOT/Makefile" | grep -Fq '$(MAKE) sync-env' || fail 'make up must not regenerate persistent environment state'
awk '/^restart: /,/^safe-restart:/' "$ROOT/Makefile" | grep -Fq './startup.sh --force' || fail 'make restart must call startup.sh --force'
! awk '/^restart: /,/^safe-restart:/' "$ROOT/Makefile" | grep -Fq '$(MAKE) sync-env' || fail 'make restart must not regenerate persistent environment state'
! grep -Fq 'utilities/env-edit.sh" sync' "$ROOT/startup.sh" || fail 'startup.sh must not regenerate persistent environment state'
grep -Fq 'utilities/env-edit.sh" sync' "$ROOT/utilities/setup-env.sh" || fail 'setup-env.sh does not call env-edit.sh sync'
grep -Fq 'utilities/env-edit.sh" sync' "$ROOT/utilities/setup-systemd.sh" || fail 'setup-systemd.sh does not call env-edit.sh sync'
pass 'environment synchronization remains an explicit operator or setup action'

awk '/^_mv_step_update_dropin\(\)/,/^}/' "$ROOT/lib/migrate.sh" | grep -Fq 'VW_ENV_EDIT_ALLOW_MIGRATION_SYNC=true "${PROJECT_ROOT}/utilities/setup-systemd.sh" install' \
  || fail 'migration drop-in regeneration does not pass env-edit migration bypass to setup-systemd install'
awk '/_storage_preflight\(\)/,/^}/' "$ROOT/utilities/env-edit.sh" | grep -Fq 'VW_ENV_EDIT_ALLOW_MIGRATION_SYNC:-false' \
  || fail 'env-edit migration guard bypass hook missing from storage preflight'
pass 'migration drop-in regeneration scopes env-edit bypass to setup-systemd install'

grep -Fq '_cmd_sync "$@"' "$ROOT/utilities/env-edit.sh" || fail 'sync subcommand missing'
! awk '/_cmd_sync\(\)/,/^}/' "$ROOT/utilities/env-edit.sh" | grep -Eq '\$\{EDITOR|EDITOR_CMD|nano|vim|code' || fail 'env-edit sync appears to invoke an editor'
pass 'env-edit sync is non-interactive'

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo 'SKIP: env-edit filesystem behavior requires root'
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
copy_repo(){
  local dest="$1"
  mkdir -p "$dest"
  (cd "$ROOT" && tar --exclude=.git --exclude='.migrate-volume.state' -cf - .) | (cd "$dest" && tar -xf -)
}
write_env(){
  local repo="$1" state="$2" mount="${3:-}" dev="${4:-}"
  cat > "$repo/.env" <<EOF_ENV
PROJECT_STATE_DIR=$state
DATA_VOLUME_DEVICE=$dev
DATA_VOLUME_MOUNT=$mount
SMTP_FROM=bw@lazymocha.com
SMTP_FROM_NAME=VaultWarden
ALLOWED_SENDER_DOMAINS=lazymocha.com
SOPS_AGE_KEY_FILE=
RCLONE_CONFIG=
EOF_ENV
  chmod 0600 "$repo/.env"
}

REPO="$TMP/repo"; copy_repo "$REPO"; STATE="$TMP/state"; ETC="$TMP/etc-vaultwarden"
write_env "$REPO" "$STATE" "" ""
mkdir -p "$ETC"; printf '[remote]\n' > "$ETC/rclone.conf"
( cd "$REPO" && VW_SYNC_ETC_DIR="$ETC" EDITOR="$TMP/missing-editor" ./utilities/env-edit.sh sync >"$TMP/sync.out" ) || fail 'boot-only env-edit sync failed'
for f in "$STATE/config/install.env" "$ETC/vaultwarden.env"; do
  [[ -f "$f" ]] || fail "$f was not created"
  [[ "$(stat -c '%U:%G %a' "$f")" == 'root:root 600' ]] || fail "$f is not root:root 600"
  assert_contains "$f" 'SMTP_FROM=bw@lazymocha.com' "SMTP_FROM not copied to $f"
  assert_contains "$f" 'SOPS_AGE_KEY_FILE=/etc/vaultwarden/age-key.txt' "SOPS override missing from $f"
  assert_contains "$f" "RCLONE_CONFIG=$ETC/rclone.conf" "RCLONE_CONFIG override missing from $f"
done
assert_not_contains "$REPO/.env" '/etc/vaultwarden/age-key.txt' 'repo .env received SOPS runtime override'
assert_not_contains "$REPO/.env" "RCLONE_CONFIG=$ETC/rclone.conf" 'repo .env received RCLONE runtime override'
pass 'boot-only sync writes generated env files and keeps runtime-only overrides out of repo .env'

rm -f "$ETC/rclone.conf"
( cd "$REPO" && VW_SYNC_ETC_DIR="$ETC" ./utilities/env-edit.sh sync >/dev/null ) || fail 'boot-only sync without rclone failed'
assert_not_contains "$STATE/config/install.env" "RCLONE_CONFIG=$ETC/rclone.conf" 'RCLONE_CONFIG injected when rclone.conf absent'
pass 'RCLONE_CONFIG is injected only when rclone.conf exists'

# Data-volume fail-closed cases.
for case in missing-device mismatch not-mounted; do
  R="$TMP/repo-$case"; copy_repo "$R"; M="$TMP/mount-$case"; mkdir -p "$M"
  case "$case" in
    missing-device) write_env "$R" "$M" "$M" "/dev/vwmissing$RANDOM" ;;
    mismatch) write_env "$R" "$TMP/state-mismatch" "$M" "/dev/vwmissing$RANDOM" ;;
    not-mounted) write_env "$R" "$M" "$M" "/dev/vwmissing$RANDOM" ;;
  esac
  if ( cd "$R" && VW_SYNC_ETC_DIR="$TMP/etc-$case" ./utilities/env-edit.sh sync >"$TMP/$case.out" 2>&1 ); then
    fail "data-volume case $case unexpectedly succeeded"
  fi
  [[ ! -e "$M/config/install.env" ]] || fail "data-volume case $case created install.env"
  grep -Eiq 'Storage|DATA_VOLUME|mounted|block device|PROJECT_STATE_DIR' "$TMP/$case.out" || fail "data-volume case $case error was unclear"
done
pass 'data-volume negative cases fail closed without writing install.env'

R="$TMP/repo-migration"; copy_repo "$R"; write_env "$R" "$TMP/migrate-state" "" ""
printf 'MIGRATION_STARTED=true\n' > "$R/.migrate-volume.state"
if ( cd "$R" && VW_SYNC_ETC_DIR="$TMP/migrate-etc" ./utilities/env-edit.sh sync >"$TMP/migrate-block.out" 2>&1 ); then fail 'incomplete migration did not block sync'; fi
[[ ! -e "$TMP/migrate-state/config/install.env" ]] || fail 'migration guard wrote install.env'
grep -Eiq 'resume|abort|migration' "$TMP/migrate-block.out" || fail 'migration guard error missing resume/abort'
printf 'MIGRATION_COMPLETE=true\n' > "$R/.migrate-volume.state"
( cd "$R" && VW_SYNC_ETC_DIR="$TMP/migrate-etc" ./utilities/env-edit.sh sync >/dev/null ) || fail 'complete migration still blocked sync'
pass 'migration-state guard blocks incomplete sync and allows completed migration'

R="$TMP/repo-edit"; copy_repo "$R"; write_env "$R" "$TMP/edit-state" "" ""
mkdir -p "$TMP/edit-etc"
( cd "$R" && VW_SYNC_ETC_DIR="$TMP/edit-etc" ./utilities/env-edit.sh sync >/dev/null )
BEFORE="$(stat -c %Y "$TMP/edit-state/config/install.env")"
cat > "$TMP/noop-editor" <<'EON'
#!/usr/bin/env bash
exit 0
EON
chmod +x "$TMP/noop-editor"
( cd "$R" && VW_SYNC_ETC_DIR="$TMP/edit-etc" EDITOR="$TMP/noop-editor" ./utilities/env-edit.sh edit >"$TMP/edit-noop.out" ) || fail 'unchanged edit failed'
grep -Fq 'No changes detected' "$TMP/edit-noop.out" || fail 'unchanged edit did not report no changes'
[[ "$(stat -c %Y "$TMP/edit-state/config/install.env")" == "$BEFORE" ]] || fail 'unchanged edit rewrote install.env'

OWNER="$(stat -c '%u:%g' "$R/.env")"
cat > "$TMP/change-editor" <<'EOC'
#!/usr/bin/env bash
target="${@: -1}"
sed -i 's/^SMTP_FROM=.*/SMTP_FROM=changed@lazymocha.com/' "$target"
chmod 0644 "$target"
EOC
chmod +x "$TMP/change-editor"
( cd "$R" && VW_SYNC_ETC_DIR="$TMP/edit-etc" EDITOR="$TMP/change-editor --flag" ./utilities/env-edit.sh edit >"$TMP/edit-change.out" ) || fail 'changed edit failed'
assert_contains "$TMP/edit-state/config/install.env" 'SMTP_FROM=changed@lazymocha.com' 'changed SMTP_FROM not synced to install.env'
[[ "$(stat -c '%a' "$R/.env")" == '600' ]] || fail 'repo .env mode not restored to 0600'
[[ "$(stat -c '%u:%g' "$R/.env")" == "$OWNER" ]] || fail 'repo .env owner/group not preserved'
pass 'edit mode detects unchanged files, parses EDITOR flags, syncs changes, and preserves .env metadata'

R="$TMP/repo-status"; copy_repo "$R"; write_env "$R" "$TMP/status-state" "$TMP/other-mount" "/dev/vwmissing$RANDOM"
printf 'MIGRATION_STARTED=true\n' > "$R/.migrate-volume.state"
( cd "$R" && VW_SYNC_ETC_DIR="$TMP/status-etc" ./utilities/env-edit.sh status >"$TMP/status.out" ) || fail 'status failed'
grep -Fq 'Repo .env:' "$TMP/status.out" || fail 'status missing repo .env'
grep -Fq 'Install env:' "$TMP/status.out" || fail 'status missing install.env path'
grep -Fq 'Runtime env:' "$TMP/status.out" || fail 'status missing runtime env path'
grep -Fq 'Migration state:' "$TMP/status.out" || fail 'status missing migration state'
grep -Fq 'MISMATCH' "$TMP/status.out" || fail 'status missing storage mismatch'
[[ ! -e "$TMP/status-state/config/install.env" ]] || fail 'status wrote install.env'
pass 'status is read-only and reports env paths, migration state, and storage mismatch'

)

check_env_edit_contracts
check_set_env_var_contracts() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }
file_metadata(){
    stat -c '%a:%u:%g' -- "$1" 2>/dev/null \
        || stat -f '%Lp:%u:%g' "$1"
}
file_mode(){
    stat -c '%a' -- "$1" 2>/dev/null \
        || stat -f '%Lp' "$1"
}
assert_no_env_temps(){
    if find "$TMP" -name '.env.tmp.*' -print -quit | grep -q .; then
        find "$TMP" -name '.env.tmp.*' -print >&2
        fail 'temporary env mutation file was not removed'
    fi
}

# shellcheck source=../lib/config.sh
source "$ROOT/lib/config.sh"

env_file="$TMP/environment"
cat > "$env_file" <<'EOF_ENV'
# leading comment
KEY_EXTRA=unchanged
KEY=old-one

OTHER=keep/me&too|yes
KEY=old-two
# trailing comment
DOTxKEY=not-the-literal-key
DOT.KEY=old-dot
EOF_ENV
chmod 0640 "$env_file"
metadata_before="$(file_metadata "$env_file")"

# Inspect the already-created temp file from the ordinary rendering command.
# This replaces no production behavior and verifies the build file is private.
awk() {
    local active_tmp
    active_tmp="$(find "$TMP" -name '.env.tmp.*' -print -quit)"
    [[ -n "$active_tmp" ]] || return 90
    file_mode "$active_tmp" > "$TMP/temp-mode"
    command awk "$@"
}
_set_env_var KEY 'value with spaces=left\right&both|pipe/slash!?.,:;' "$env_file"
unset -f awk

[[ "$(cat "$TMP/temp-mode")" == "600" ]] \
    || fail 'temporary env mutation file was accessible to other users'
cat > "$TMP/expected" <<'EOF_EXPECTED'
# leading comment
KEY_EXTRA=unchanged
KEY=value with spaces=left\right&both|pipe/slash!?.,:;

OTHER=keep/me&too|yes
KEY=value with spaces=left\right&both|pipe/slash!?.,:;
# trailing comment
DOTxKEY=not-the-literal-key
DOT.KEY=old-dot
EOF_EXPECTED
cmp -s "$TMP/expected" "$env_file" \
    || fail 'exact-key update changed unrelated content, ordering, or literal value data'
[[ "$(grep -Fxc 'KEY=value with spaces=left\right&both|pipe/slash!?.,:;' "$env_file")" -eq 2 ]] \
    || fail 'duplicate exact key records were not all updated'
pass 'canonical env mutation updates every exact key and preserves literal data and unrelated records'

_set_env_var DOT.KEY 'literal-dot' "$env_file"
grep -Fxq 'DOT.KEY=literal-dot' "$env_file" || fail 'literal punctuation key was not updated'
grep -Fxq 'DOTxKEY=not-the-literal-key' "$env_file" || fail 'key punctuation was treated as a regular expression'
_set_env_var ABSENT 'new=value\with&literal|data/path' "$env_file"
[[ "$(tail -n 1 "$env_file")" == 'ABSENT=new=value\with&literal|data/path' ]] \
    || fail 'absent key was not appended exactly once'
[[ "$(grep -c '^ABSENT=' "$env_file")" -eq 1 ]] || fail 'absent key append was duplicated'
[[ "$(file_metadata "$env_file")" == "$metadata_before" ]] \
    || fail 'mode, UID, or GID changed after env mutation'
assert_no_env_temps
pass 'canonical env mutation appends absent keys and preserves mode, UID, and GID'

render_file="$TMP/render-failure"
printf 'KEY=original\nOTHER=stable\n' > "$render_file"
chmod 0600 "$render_file"
cp "$render_file" "$TMP/render-before"
awk(){ return 41; }
if _set_env_var KEY changed "$render_file"; then
    unset -f awk
    fail 'forced rendering failure unexpectedly succeeded'
fi
unset -f awk
cmp -s "$TMP/render-before" "$render_file" || fail 'rendering failure changed the original file'
assert_no_env_temps

metadata_file="$TMP/metadata-failure"
printf 'KEY=original\n' > "$metadata_file"
chmod 0600 "$metadata_file"
cp "$metadata_file" "$TMP/metadata-before"
chown(){ return 42; }
if _set_env_var KEY changed "$metadata_file"; then
    unset -f chown
    fail 'forced metadata preservation failure unexpectedly succeeded'
fi
unset -f chown
cmp -s "$TMP/metadata-before" "$metadata_file" || fail 'metadata failure changed the original file'
assert_no_env_temps

promotion_file="$TMP/promotion-failure"
printf 'KEY=original\n' > "$promotion_file"
chmod 0600 "$promotion_file"
cp "$promotion_file" "$TMP/promotion-before"
mv(){ return 43; }
if _set_env_var KEY changed "$promotion_file"; then
    unset -f mv
    fail 'forced promotion failure unexpectedly succeeded'
fi
unset -f mv
cmp -s "$TMP/promotion-before" "$promotion_file" || fail 'promotion failure changed the original file'
assert_no_env_temps
pass 'canonical env mutation preserves originals and removes temporary files after failures'

missing_file="$TMP/missing"
if _set_env_var NEW value "$missing_file" 2>/dev/null; then
    fail 'missing target unexpectedly succeeded'
fi
[[ ! -e "$missing_file" ]] || fail 'missing target was created'
if _set_env_var KEY value 2>/dev/null; then
    fail 'two-argument call unexpectedly succeeded'
fi
if _set_env_var KEY value "$env_file" extra 2>/dev/null; then
    fail 'four-argument call unexpectedly succeeded'
fi
pass 'canonical env mutation requires exactly three arguments and an existing regular file'

trap_file="$TMP/traps"
trap_env="$TMP/trap-env"
printf 'KEY=before\n' > "$trap_env"
chmod 0600 "$trap_env"
(
    set -euo pipefail
    set -T
    return_hits=0
    trap 'return_hits=$((return_hits + 1))' RETURN
    trap 'printf "caller-exit\n" >> "$trap_file"' EXIT
    trap 'printf "caller-term\n" >> "$trap_file"' TERM
    return_before="$(trap -p RETURN)"
    exit_before="$(trap -p EXIT)"
    term_before="$(trap -p TERM)"
    _set_env_var KEY after "$trap_env"
    [[ "$(trap -p RETURN)" == "$return_before" ]] || fail 'caller RETURN trap was replaced'
    [[ "$(trap -p EXIT)" == "$exit_before" ]] || fail 'caller EXIT trap was replaced'
    [[ "$(trap -p TERM)" == "$term_before" ]] || fail 'caller TERM trap was replaced'
    hits_before=$return_hits
    return_probe(){ :; }
    return_probe
    (( return_hits > hits_before )) || fail 'caller RETURN trap was no longer functional'
)
grep -Fxq 'caller-exit' "$trap_file" || fail 'caller EXIT trap was no longer functional'
grep -Fxq 'KEY=after' "$trap_env" || fail 'strict-mode env mutation did not complete'
assert_no_env_temps
pass 'canonical env mutation is strict-mode safe and preserves caller traps'
)

check_set_env_var_contracts
check_config_environment_contracts() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
TESTS_RUN=0
chmod 0755 "$TMP"

cleanup() {
    if [[ -d "$TMP" ]]; then
        if (( EUID == 0 )); then
            rm -rf "$TMP"
        elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
            sudo -n rm -rf "$TMP"
        else
            rm -rf "$TMP"
        fi
    fi
}
trap cleanup EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
run_test() { local name="$1"; shift; TESTS_RUN=$((TESTS_RUN + 1)); "$@"; pass "$name"; }

write_env() {
    local file="$1"; shift
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "$@" > "$file"
    chmod 0600 "$file"
}

run_unprivileged() {
    if (( EUID == 0 )); then
        command -v runuser >/dev/null 2>&1 || fail 'runuser is required for unreadable-file configuration tests'
        runuser -u nobody -- "$@"
    else
        "$@"
    fi
}

test_config_falls_through_empty_repo_state() {
    local fake_repo="$TMP/fake-repo-fallthrough" installed="$TMP/installed.env" installed_state="$TMP/installed-state"
    mkdir -p "$fake_repo"
    write_env "$fake_repo/.env" 'DOMAIN=https://repo.example.test' 'ADMIN_EMAIL=repo@example.test'
    write_env "$installed" "PROJECT_STATE_DIR=$installed_state" 'DATA_VOLUME_MOUNT=/from-installed' 'SOPS_AGE_KEY_FILE=/installed/key.txt'

    local output
    output=$(VW_CONFIG_INSTALLED_ENV_FILE="$installed" PROJECT_ROOT="$fake_repo" REAL_CONFIG="$ROOT/lib/config.sh" bash <<'PROBE'
set -euo pipefail
source "$REAL_CONFIG"
load_project_environment
printf 'PROJECT_STATE_DIR=%s\n' "$PROJECT_STATE_DIR"
PROBE
)
    grep -q "PROJECT_STATE_DIR=$installed_state" <<< "$output" || fail "expected installed PROJECT_STATE_DIR, got: $output"
}

test_config_caller_override_wins() {
    local fake_repo="$TMP/fake-repo-override" installed="$TMP/installed-override.env" installed_state="$TMP/installed-other" override_state="$TMP/override-state"
    mkdir -p "$fake_repo" "$override_state/config"
    write_env "$fake_repo/.env" 'DOMAIN=https://repo.example.test'
    write_env "$installed" "PROJECT_STATE_DIR=$installed_state" 'BACKUP_DIR=/loaded/backups' 'TZ=UTC' 'RCLONE_REMOTE_NAME=loaded-remote'

    local output
    output=$(VW_CONFIG_INSTALLED_ENV_FILE="$installed" PROJECT_ROOT="$fake_repo" REAL_CONFIG="$ROOT/lib/config.sh" \
        PROJECT_STATE_DIR="$override_state" DATA_VOLUME_MOUNT=/caller-mount \
        SOPS_AGE_KEY_FILE=/caller/key.txt BACKUP_DIR=/caller/backups \
        TZ=America/Vancouver RCLONE_REMOTE_NAME=caller-remote \
        SECRETS_FILE=/caller/secrets.yaml bash <<'PROBE'
set -euo pipefail
source "$REAL_CONFIG"
load_project_environment
load_project_environment
printf 'PROJECT_STATE_DIR=%s\n' "$PROJECT_STATE_DIR"
printf 'DATA_VOLUME_MOUNT=%s\n' "$DATA_VOLUME_MOUNT"
printf 'SOPS_AGE_KEY_FILE=%s\n' "$SOPS_AGE_KEY_FILE"
printf 'BACKUP_DIR=%s\n' "$BACKUP_DIR"
printf 'TZ=%s\n' "$TZ"
printf 'RCLONE_REMOTE_NAME=%s\n' "$RCLONE_REMOTE_NAME"
printf 'SECRETS_FILE=%s\n' "$SECRETS_FILE"
PROBE
)
    grep -q "PROJECT_STATE_DIR=$override_state" <<< "$output" || fail "caller PROJECT_STATE_DIR override lost: $output"
    grep -q 'DATA_VOLUME_MOUNT=/caller-mount' <<< "$output" || fail "caller DATA_VOLUME_MOUNT override lost: $output"
    grep -q 'SOPS_AGE_KEY_FILE=/caller/key.txt' <<< "$output" || fail "caller SOPS_AGE_KEY_FILE override lost: $output"
    grep -q 'BACKUP_DIR=/caller/backups' <<< "$output" || fail "caller BACKUP_DIR override lost: $output"
    grep -q 'TZ=America/Vancouver' <<< "$output" || fail "caller TZ override lost: $output"
    grep -q 'RCLONE_REMOTE_NAME=caller-remote' <<< "$output" || fail "caller RCLONE_REMOTE_NAME override lost: $output"
    grep -q 'SECRETS_FILE=/caller/secrets.yaml' <<< "$output" || fail "caller SECRETS_FILE override lost: $output"
}

test_unreadable_repo_allows_installed_environment() {
    local fake_repo="$TMP/fake-repo-unreadable" installed="$TMP/readable-installed.env" installed_state="$TMP/readable-installed-state"
    mkdir -p "$fake_repo"
    chmod 0755 "$fake_repo"
    write_env "$fake_repo/.env" 'PROJECT_STATE_DIR=/wrong/repo/state' 'DOMAIN=https://repo.example.test'
    chmod 000 "$fake_repo/.env"
    write_env "$installed" "PROJECT_STATE_DIR=$installed_state" 'DOMAIN=https://installed.example.test'
    chmod 0644 "$installed"

    local output
    output=$(run_unprivileged env VW_CONFIG_INSTALLED_ENV_FILE="$installed" PROJECT_ROOT="$fake_repo" \
        REAL_CONFIG="$ROOT/lib/config.sh" bash -c '
set -euo pipefail
source "$REAL_CONFIG"
load_project_environment
printf "PROJECT_STATE_DIR=%s\nDOMAIN=%s\n" "$PROJECT_STATE_DIR" "$DOMAIN"
') || fail 'unreadable repository .env blocked a readable installed environment'
    grep -Fq "PROJECT_STATE_DIR=$installed_state" <<< "$output" || fail "installed state was not selected: $output"
    grep -Fq 'DOMAIN=https://installed.example.test' <<< "$output" || fail "installed domain was not selected: $output"
}

test_unreadable_selected_environment_fails() {
    local fake_repo="$TMP/fake-repo-selected-unreadable" installed="$TMP/unreadable-installed.env"
    mkdir -p "$fake_repo"
    chmod 0755 "$fake_repo"
    write_env "$installed" "PROJECT_STATE_DIR=$TMP/unreadable-state" 'DOMAIN=https://installed.example.test'
    chmod 000 "$installed"

    local output
    if output=$(run_unprivileged env VW_CONFIG_INSTALLED_ENV_FILE="$installed" PROJECT_ROOT="$fake_repo" \
        REAL_CONFIG="$ROOT/lib/config.sh" bash -c '
set -euo pipefail
source "$REAL_CONFIG"
load_project_environment
' 2>&1); then
        fail 'unreadable selected canonical environment unexpectedly succeeded'
    fi
    grep -Fq 'Environment file is not readable' <<< "$output" \
        || fail "unreadable selected environment error was unclear: $output"
}

test_operator_interfaces_share_installed_configuration() {
    local fixture="$TMP/interface-repo" installed="$TMP/interface-installed.env"
    local installed_state="$TMP/interface-installed-state" installed_backup="$TMP/interface-installed-backups"
    local repo_state="$TMP/interface-repo-state" repo_backup="$TMP/interface-repo-backups"
    local installed_archive='db_backup_20990101_000000.sqlite3.age'
    local repo_archive='db_backup_19990101_000000.sqlite3.age'

    mkdir -p "$fixture/utilities" "$installed_state/secrets" "$installed_backup/db" "$repo_backup/db" "$TMP/interface-bin"
    cp "$ROOT/Makefile" "$ROOT/dashboard.sh" "$ROOT/backup.sh" "$ROOT/VERSION" "$fixture/"
    cp "$ROOT/utilities/backup-run.sh" "$fixture/utilities/"
    ln -s "$ROOT/lib" "$fixture/lib"
    chmod 0755 "$fixture" "$fixture/utilities" "$installed_state" "$installed_state/secrets" "$installed_backup" "$installed_backup/db" "$repo_backup" "$repo_backup/db"
    chmod +x "$fixture/backup.sh" "$fixture/utilities/backup-run.sh"
    sed -i 's/^main "$@"$/: # fixture: do not auto-run dashboard/' "$fixture/dashboard.sh"

    write_env "$fixture/.env" \
        "PROJECT_STATE_DIR=$repo_state" \
        "BACKUP_DIR=$repo_backup" \
        'TZ=UTC' \
        'RCLONE_REMOTE_NAME=repo-remote' \
        'DOMAIN=https://repo.example.test' \
        'ADMIN_EMAIL=repo@example.test'
    write_env "$installed" \
        "PROJECT_STATE_DIR=$installed_state" \
        "BACKUP_DIR=$installed_backup" \
        'TZ=America/Vancouver' \
        'RCLONE_REMOTE_NAME=installed-remote' \
        'DOMAIN=https://installed.example.test' \
        'ADMIN_EMAIL=installed@example.test'
    printf 'encrypted fixture\n' > "$installed_state/secrets/secrets.yaml"
    touch "$installed_backup/db/$installed_archive" "$repo_backup/db/$repo_archive"

    cat > "$TMP/interface-bin/docker" <<'MOCK_DOCKER'
#!/usr/bin/env bash
case "${1:-}" in
    info) exit 0 ;;
    compose) exit 0 ;;
    stats) exit 0 ;;
    inspect) exit 1 ;;
    *) exit 0 ;;
esac
MOCK_DOCKER
    cat > "$TMP/interface-bin/systemctl" <<'MOCK_SYSTEMCTL'
#!/usr/bin/env bash
exit 1
MOCK_SYSTEMCTL
    cat > "$TMP/interface-bin/id" <<'MOCK_ID'
#!/usr/bin/env bash
case "${1:-}" in
    -u) printf '0\n' ;;
    -un) printf 'root\n' ;;
    -gn) printf 'root\n' ;;
    *) exec /usr/bin/id "$@" ;;
esac
MOCK_ID
    chmod +x "$TMP/interface-bin/docker" "$TMP/interface-bin/systemctl" "$TMP/interface-bin/id"

    local direct_output dashboard_output cli_output make_output init_output info_output dry_run_output
    direct_output=$(VW_CONFIG_INSTALLED_ENV_FILE="$installed" PROJECT_ROOT="$fixture" REAL_CONFIG="$ROOT/lib/config.sh" bash <<'PROBE'
set -euo pipefail
source "$REAL_CONFIG"
load_env_file
printf 'STATE=%s\nBACKUP=%s\nSECRETS=%s\n' "$PROJECT_STATE_DIR" "$BACKUP_DIR" "$SECRETS_FILE"
PROBE
)

    dashboard_output=$(VW_CONFIG_INSTALLED_ENV_FILE="$installed" DASHBOARD="$fixture/dashboard.sh" bash <<'PROBE'
set -euo pipefail
source "$DASHBOARD"
_load_dashboard_config
printf 'STATE=%s\nBACKUP=%s\nTZ=%s\nREMOTE=%s\nSECRETS=%s\n' \
    "$STATE_DIR" "$BACKUP_DIR" "$TZ_DISPLAY" "$RCLONE_REMOTE_NAME" "$SECRETS_FILE"
PROBE
)

    cli_output=$(cd "$fixture" && PATH="$TMP/interface-bin:$PATH" VW_CONFIG_INSTALLED_ENV_FILE="$installed" ./backup.sh list 2>&1)
    make_output=$(PATH="$TMP/interface-bin:$PATH" VW_CONFIG_INSTALLED_ENV_FILE="$installed" make -s -C "$fixture" status 2>&1)
    init_output=$(PATH="$TMP/interface-bin:$PATH" VW_CONFIG_INSTALLED_ENV_FILE="$installed" make -s -C "$fixture" init-secrets 2>&1)
    info_output=$(PATH="$TMP/interface-bin:$PATH" VW_CONFIG_INSTALLED_ENV_FILE="$installed" make -s -C "$fixture" info 2>&1)
    dry_run_output=$(PATH="$TMP/interface-bin:$PATH" VW_CONFIG_INSTALLED_ENV_FILE="$installed" make --no-print-directory -n -C "$fixture" dry-run 2>&1)

    for output in "$direct_output" "$dashboard_output"; do
        grep -Fq "STATE=$installed_state" <<< "$output" || fail "interface selected the repository state: $output"
        grep -Fq "BACKUP=$installed_backup" <<< "$output" || fail "interface selected the repository backup path: $output"
        grep -Fq "SECRETS=$installed_state/secrets/secrets.yaml" <<< "$output" || fail "interface selected the wrong secrets path: $output"
    done
    grep -Fq 'TZ=America/Vancouver' <<< "$dashboard_output" || fail "dashboard selected the repository timezone: $dashboard_output"
    grep -Fq 'REMOTE=installed-remote' <<< "$dashboard_output" || fail "dashboard selected the repository rclone remote: $dashboard_output"
    grep -Fq "$installed_archive" <<< "$cli_output" || fail "backup CLI did not use installed backup path: $cli_output"
    ! grep -Fq "$repo_archive" <<< "$cli_output" || fail "backup CLI used repository backup path: $cli_output"
    grep -Fq "$installed_archive" <<< "$make_output" || fail "Make status did not use backup CLI installed path: $make_output"
    grep -Fq "$installed_state" <<< "$make_output" || fail "Make status did not use installed state path: $make_output"
    grep -Fq 'Secrets file already exists' <<< "$init_output" || fail "Make init-secrets did not use installed secrets path: $init_output"
    grep -Fq 'https://installed.example.test' <<< "$info_output" || fail "Make info did not report installed domain: $info_output"
    grep -Fq "$installed_state" <<< "$info_output" || fail "Make info did not report installed state path: $info_output"
    ! grep -Fq 'https://repo.example.test' <<< "$info_output" || fail "Make info reported repository domain: $info_output"
    ! grep -Fq "$repo_state" <<< "$info_output" || fail "Make info reported repository state path: $info_output"
    grep -Fq './startup.sh --dry-run' <<< "$dry_run_output" || fail "Make dry-run did not reach the startup dry-run recipe: $dry_run_output"
}

test_installed_runtime_secret_resolution() {
    local fake_repo="$TMP/fake-repo-secrets" installed="$TMP/secrets-installed.env" state="$TMP/secrets-state"
    mkdir -p "$fake_repo" "$state/secrets"
    write_env "$fake_repo/.env" 'PROJECT_STATE_DIR=/wrong/repository/state'
    write_env "$installed" "PROJECT_STATE_DIR=$state"
    printf 'encrypted fixture\n' > "$state/secrets/secrets.yaml"

    local output
    output=$(VW_CONFIG_INSTALLED_ENV_FILE="$installed" PROJECT_ROOT="$fake_repo" REAL_CONFIG="$ROOT/lib/config.sh" bash <<'PROBE'
set -euo pipefail
source "$REAL_CONFIG"
load_project_environment
printf 'SECRETS_FILE=%s\n' "$SECRETS_FILE"
PROBE
)
    grep -Fq "SECRETS_FILE=$state/secrets/secrets.yaml" <<< "$output" \
        || fail "canonical environment did not resolve installed secrets path: $output"

    grep -q 'unset SOPS_CONFIG' "$ROOT/lib/secrets.sh" \
        || fail "ensure_sops_env does not unset missing SOPS_CONFIG"
    grep -q 'config=<unset; no .sops.yaml found>' "$ROOT/lib/secrets.sh" \
        || fail "ensure_sops_env does not document missing .sops.yaml fallback"
}

test_dns_optional_and_strict_modes() {
    grep -q 'UPDATE_DNS=false; skipping DNS update' "$ROOT/utilities/maintenance-update-dns.sh" \
        || fail "DNS updater does not skip cleanly when UPDATE_DNS=false"
    grep -q 'DNS automation not configured' "$ROOT/utilities/maintenance-update-dns.sh" \
        || fail "DNS updater does not warn for optional missing DNS config"
    grep -q 'DNS update is required' "$ROOT/utilities/maintenance-update-dns.sh" \
        || fail "DNS updater does not fail strict missing DNS config"
}

run_test 'repo .env without PROJECT_STATE_DIR falls through to installed environment' test_config_falls_through_empty_repo_state
run_test 'explicit caller overrides survive loading and repeated calls' test_config_caller_override_wins
run_test 'unreadable repository .env does not block installed runtime configuration' test_unreadable_repo_allows_installed_environment
run_test 'unreadable selected canonical environment fails explicitly' test_unreadable_selected_environment_fails
run_test 'Make, dashboard, and backup CLI share installed configuration' test_operator_interfaces_share_installed_configuration
run_test 'installed runtime secrets path is resolved canonically' test_installed_runtime_secret_resolution
run_test 'DNS update optional and strict modes are represented' test_dns_optional_and_strict_modes
[[ "$TESTS_RUN" -eq 7 ]] || fail "expected 7 tests, ran $TESTS_RUN"
printf '1..%s\n' "$TESTS_RUN"

)

check_config_environment_contracts

check_compose_resource_contracts() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
PRODUCTION="$ROOT/docker-compose.yml.example"
DEVELOPMENT="$ROOT/docker-compose.override.dev.yml.example"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

service_block() {
    local file="$1" service="$2"
    awk -v header="  ${service}:" '
        $0 == header { active = 1 }
        active && $0 ~ /^  [[:alnum:]_-]+:[[:space:]]*$/ && $0 != header { exit }
        active { print }
    ' "$file"
}

assert_line() {
    local block="$1" expected="$2" context="$3"
    grep -Fqx -- "$expected" <<< "$block" || fail "$context"
}

assert_no_line() {
    local block="$1" unexpected="$2" context="$3"
    ! grep -Fqx -- "$unexpected" <<< "$block" || fail "$context"
}

vaultwarden="$(service_block "$PRODUCTION" vaultwarden)"
caddy="$(service_block "$PRODUCTION" caddy)"
postfix="$(service_block "$PRODUCTION" postfix)"
mailpit="$(service_block "$DEVELOPMENT" mailpit)"

assert_line "$vaultwarden" '    mem_limit: 512M' 'Vaultwarden top-level memory limit changed'
assert_line "$vaultwarden" '    memswap_limit: 512M' 'Vaultwarden swap limit changed'
assert_line "$vaultwarden" '    deploy:' 'Vaultwarden deploy resources are missing'
assert_line "$vaultwarden" '          memory: 512M' 'Vaultwarden deploy memory limit changed'
assert_line "$vaultwarden" "          cpus: '0.3'" 'Vaultwarden CPU limit changed'
assert_line "$vaultwarden" '          pids: 200' 'Vaultwarden PID limit changed'
assert_line "$vaultwarden" '          memory: 128M' 'Vaultwarden memory reservation changed'
assert_line "$vaultwarden" "          cpus: '0.1'" 'Vaultwarden CPU reservation changed'

assert_line "$caddy" '    mem_limit: 256M' 'Caddy top-level memory limit changed'
assert_line "$caddy" '    memswap_limit: 256M' 'Caddy swap limit changed'
assert_line "$caddy" '    cpus: "0.25"' 'Caddy top-level CPU limit changed'
assert_line "$caddy" '    pids_limit: 200' 'Caddy top-level PID limit changed'
assert_line "$caddy" '    deploy:' 'Caddy deploy resources are missing'
assert_line "$caddy" '          memory: 256M' 'Caddy deploy memory limit changed'
assert_line "$caddy" "          cpus: '0.25'" 'Caddy deploy CPU limit changed'
assert_line "$caddy" '          pids: 200' 'Caddy deploy PID limit changed'
assert_line "$caddy" '          memory: 128M' 'Caddy memory reservation changed'
assert_line "$caddy" "          cpus: '0.1'" 'Caddy CPU reservation changed'

assert_line "$postfix" '    mem_limit: 256M' 'Postfix top-level memory limit changed'
assert_line "$postfix" '    memswap_limit: 256M' 'Postfix swap limit changed'
assert_line "$postfix" '    deploy:' 'Postfix deploy resources are missing'
assert_line "$postfix" '          memory: 256M' 'Postfix deploy memory limit changed'
assert_line "$postfix" "          cpus: '0.1'" 'Postfix CPU limit changed'
assert_line "$postfix" '          pids: 50' 'Postfix PID limit changed'
assert_line "$postfix" '          memory: 64M' 'Postfix memory reservation changed'
assert_line "$postfix" "          cpus: '0.02'" 'Postfix CPU reservation changed'

assert_line "$mailpit" '    deploy:' 'Mailpit deploy resources are missing'
assert_line "$mailpit" '          memory: 128M' 'Mailpit memory limit changed'
assert_line "$mailpit" "          cpus: '0.1'" 'Mailpit CPU limit changed'

for service in vaultwarden caddy postfix; do
    override_block="$(service_block "$DEVELOPMENT" "$service")"
    assert_no_line "$override_block" '    deploy:' "$service development override must not claim to clear active limits"
done

for block in "$vaultwarden" "$caddy" "$postfix"; do
    assert_line "$block" '    # Docker Compose applies deploy.resources hard limits and memory reservations' \
        'standalone Compose resource comment is missing'
    assert_line "$block" '    # in standalone mode. CPU reservations are used only by Docker Swarm.' \
        'CPU reservation scope comment is missing'
done

! grep -Fq 'deploy.resources is evaluated only in Docker Swarm mode' "$PRODUCTION" \
    || fail 'production Compose still claims deploy resources are Swarm-only'
! grep -Fq 'cpu and pid limits are silently ignored' "$PRODUCTION" \
    || fail 'production Compose still claims standalone CPU/PID limits are ignored'

printf 'PASS: Compose resource controls remain service-scoped and truthful\n'
)

check_compose_resource_contracts
