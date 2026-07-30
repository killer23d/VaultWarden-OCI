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
! awk '/^up: /,/^start:/' "$ROOT/Makefile" | grep -Fq '$(MAKE) sync-env' || fail 'make up must leave env sync inside guarded startup.sh'
awk '/^restart: /,/^safe-restart:/' "$ROOT/Makefile" | grep -Fq './startup.sh --force' || fail 'make restart must call startup.sh --force'
! awk '/^restart: /,/^safe-restart:/' "$ROOT/Makefile" | grep -Fq '$(MAKE) sync-env' || fail 'make restart must leave env sync inside guarded startup.sh'
grep -Fq 'utilities/env-edit.sh" sync' "$ROOT/startup.sh" || fail 'startup.sh must sync env inside the lifecycle operation'
grep -Fq 'utilities/env-edit.sh" sync' "$ROOT/utilities/setup-env.sh" || fail 'setup-env.sh does not call env-edit.sh sync'
grep -Fq 'utilities/env-edit.sh" sync' "$ROOT/utilities/setup-systemd.sh" || fail 'setup-systemd.sh does not call env-edit.sh sync'
pass 'Makefile, startup, and setup callers use env-edit.sh sync/edit correctly'

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

run_config_probe() {
    local script="$1"
    PROJECT_ROOT="$ROOT" bash -c "$script"
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
    mkdir -p "$fake_repo"
    mkdir -p "$override_state/config"
    write_env "$fake_repo/.env" 'DOMAIN=https://repo.example.test'
    write_env "$installed" "PROJECT_STATE_DIR=$installed_state"
    write_env "$override_state/config/install.env" "PROJECT_STATE_DIR=$TMP/wrong-loaded-state" 'DATA_VOLUME_MOUNT=/loaded-mount' 'SOPS_AGE_KEY_FILE=/loaded/key.txt'

    local output
    output=$(VW_CONFIG_INSTALLED_ENV_FILE="$installed" PROJECT_ROOT="$fake_repo" REAL_CONFIG="$ROOT/lib/config.sh" PROJECT_STATE_DIR="$override_state" DATA_VOLUME_DEVICE=/caller-device DATA_VOLUME_MOUNT=/caller-mount SOPS_AGE_KEY_FILE=/caller/key.txt bash <<'PROBE'
set -euo pipefail
source "$REAL_CONFIG"
load_project_environment
load_project_environment
printf 'PROJECT_STATE_DIR=%s\n' "$PROJECT_STATE_DIR"
printf 'DATA_VOLUME_DEVICE=%s\n' "$DATA_VOLUME_DEVICE"
printf 'DATA_VOLUME_MOUNT=%s\n' "$DATA_VOLUME_MOUNT"
printf 'SOPS_AGE_KEY_FILE=%s\n' "$SOPS_AGE_KEY_FILE"
PROBE
)
    grep -q "PROJECT_STATE_DIR=$override_state" <<< "$output" || fail "caller PROJECT_STATE_DIR override lost: $output"
    grep -q 'DATA_VOLUME_DEVICE=/caller-device' <<< "$output" || fail "caller DATA_VOLUME_DEVICE override lost: $output"
    grep -q 'DATA_VOLUME_MOUNT=/caller-mount' <<< "$output" || fail "caller DATA_VOLUME_MOUNT override lost: $output"
    grep -q 'SOPS_AGE_KEY_FILE=/caller/key.txt' <<< "$output" || fail "caller SOPS_AGE_KEY_FILE override lost: $output"
}

test_installed_runtime_secret_resolution() {
    grep -q 'load_project_environment' "$ROOT/utilities/maintenance-update-dns.sh" \
        || fail "DNS updater does not use load_project_environment"

    grep -q 'load_project_environment' "$ROOT/utilities/notify-failure.sh" \
        || fail "notify-failure helper does not use load_project_environment"

    ! grep -q 'load_env_file /etc/vaultwarden/vaultwarden.env' "$ROOT/utilities/maintenance-update-dns.sh" \
        || fail "DNS updater retains a lower-priority fallback after canonical load failure"

    ! grep -q 'using process environment only' "$ROOT/utilities/notify-failure.sh" \
        || fail "notify-failure helper continues with inherited values after canonical load failure"

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

test_runtime_source_precedence_and_observability() {
    local fake_repo="$TMP/fake-repo-precedence" installed="$TMP/installed-precedence.env"
    local persistent_state="$TMP/persistent-state"
    mkdir -p "$fake_repo"
    write_env "$fake_repo/.env" \
        "PROJECT_STATE_DIR=$persistent_state" \
        'BACKUP_DIR=/from-repository' \
        'TZ=Repo/Zone' \
        'SOPS_AGE_KEY_FILE=/repository/key.txt'
    write_env "$persistent_state/config/install.env" \
        "PROJECT_STATE_DIR=$persistent_state" \
        'BACKUP_DIR=/from-persistent' \
        'TZ=Persistent/Zone' \
        'SOPS_AGE_KEY_FILE=/persistent/key.txt'
    write_env "$installed" \
        "PROJECT_STATE_DIR=$TMP/installed-state" \
        'BACKUP_DIR=/from-installed' \
        'TZ=Installed/Zone' \
        'SOPS_AGE_KEY_FILE=/installed/key.txt'

    local output
    output=$(VW_CONFIG_INSTALLED_ENV_FILE="$installed" PROJECT_ROOT="$fake_repo" REAL_CONFIG="$ROOT/lib/config.sh" bash <<'PROBE'
set -euo pipefail
source "$REAL_CONFIG"
load_project_environment >/dev/null
printf '%s|%s|%s|%s|%s\n' "$VW_CONFIG_SELECTED_ENV_SOURCE" "$VW_CONFIG_SELECTED_ENV_FILE" "$PROJECT_STATE_DIR" "$BACKUP_DIR" "$TZ"
PROBE
)
    [[ "$output" == "installed|$installed|$TMP/installed-state|/from-installed|Installed/Zone" ]] \
        || fail "installed source did not win canonical precedence: $output"

    output=$(VW_CONFIG_INSTALLED_ENV_FILE="$TMP/missing-installed" PROJECT_ROOT="$fake_repo" REAL_CONFIG="$ROOT/lib/config.sh" bash <<'PROBE'
set -euo pipefail
source "$REAL_CONFIG"
load_project_environment >/dev/null
printf '%s|%s|%s|%s\n' "$VW_CONFIG_SELECTED_ENV_SOURCE" "$PROJECT_STATE_DIR" "$BACKUP_DIR" "$TZ"
PROBE
)
    [[ "$output" == "persistent|$persistent_state|/from-persistent|Persistent/Zone" ]] \
        || fail "persistent source did not win over repository .env: $output"

    output=$(VW_CONFIG_INSTALLED_ENV_FILE="$installed" DASHBOARD="$ROOT/dashboard.sh" bash <<'PROBE'
set -euo pipefail
source "$DASHBOARD"
_load_dashboard_environment
printf '%s|%s|%s\n' "$STATE_DIR" "$BACKUP_DIR" "$TZ_DISPLAY"
PROBE
)
    [[ "$(printf '%s\n' "$output" | tail -n 1)" == "$TMP/installed-state|/from-installed|Installed/Zone" ]] \
        || fail "dashboard did not use installed runtime values: $output"

    local fixture_bin="$TMP/runtime-surface-bin" root_bin="$TMP/runtime-root-bin"
    mkdir -p "$fixture_bin" "$root_bin" "$TMP/installed-state"
    cat > "$root_bin/id" <<'EOF_ID'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then
    printf '0\n'
else
    /usr/bin/id "$@"
fi
EOF_ID
    cat > "$fixture_bin/docker" <<'EOF_DOCKER'
#!/usr/bin/env bash
case "${1:-}" in
    compose)
        case "${2:-}" in
            version) printf 'Docker Compose fixture\n' ;;
            *) printf 'compose fixture\n' ;;
        esac
        ;;
    --version) printf 'Docker fixture\n' ;;
    *) printf 'docker fixture\n' ;;
esac
EOF_DOCKER
    cat > "$fixture_bin/systemctl" <<'EOF_SYSTEMCTL'
#!/usr/bin/env bash
exit 1
EOF_SYSTEMCTL
    chmod +x "$root_bin/id" "$fixture_bin/docker" "$fixture_bin/systemctl"

    local surface
    for surface in info status diagnose; do
        local surface_path="$fixture_bin:$PATH"
        [[ "$surface" == "info" ]] || surface_path="$root_bin:$surface_path"
        output=$(PATH="$surface_path" VW_CONFIG_INSTALLED_ENV_FILE="$installed" \
            make --no-print-directory -s -C "$ROOT" "$surface" 2>&1) \
            || fail "make $surface fixture failed: $output"
        if [[ "$surface" == "status" ]]; then
            [[ "$output" == *"$TMP/installed-state"* && "$output" == *"/from-installed"* ]] \
                || fail "make status did not use installed state/backup values: $output"
        else
            [[ "$output" == *"$installed"* ]] \
                || fail "make $surface did not report installed configuration: $output"
        fi
        [[ "$output" != *"/var/lib/vaultwarden"* ]] \
            || fail "make $surface fell back to /var/lib/vaultwarden: $output"
    done
}

test_invalid_selected_production_source_fails_closed() {
    local fake_repo="$TMP/fake-repo-invalid" installed="$TMP/installed-invalid.env"
    mkdir -p "$fake_repo"
    write_env "$fake_repo/.env" \
        "PROJECT_STATE_DIR=$TMP/repo-state" \
        'SOPS_AGE_KEY_FILE=/healthy/repository-key.txt'
    write_env "$installed" \
        "PROJECT_STATE_DIR=$TMP/installed-state" \
        'BROKEN PRODUCTION LINE' \
        'SOPS_AGE_KEY_FILE=/selected/key.txt'

    local output rc
    set +e
    output=$(VW_CONFIG_INSTALLED_ENV_FILE="$installed" PROJECT_ROOT="$fake_repo" REAL_CONFIG="$ROOT/lib/config.sh" \
        ADMIN_EMAIL=inherited@example.test bash <<'PROBE' 2>&1
set +e
source "$REAL_CONFIG"
load_project_environment
rc=$?
printf 'rc=%s selected=%s state=%s\n' "$rc" "${VW_CONFIG_SELECTED_ENV_FILE:-}" "${PROJECT_STATE_DIR:-}"
exit "$rc"
PROBE
)
    rc=$?
    set -e
    [[ "$rc" -ne 0 ]] || fail "malformed installed environment unexpectedly succeeded"
    [[ "$output" == *"Refusing selected production environment: $installed"* ]] \
        || fail "rejected source was not identified: $output"
    [[ "$output" == *"selected=$installed"* ]] || fail "selected source was not observable after rejection: $output"
    [[ "$output" != *"state=$TMP/repo-state"* ]] || fail "rejected installed source fell through to repository state"

    set +e
    output=$(VW_CONFIG_INSTALLED_ENV_FILE="$installed" ADMIN_EMAIL=inherited@example.test \
        "$ROOT/utilities/maintenance-health.sh" --json 2>&1)
    rc=$?
    set -e
    [[ "$rc" -eq 3 ]] || fail "health rejection returned $rc instead of 3: $output"
    [[ "$output" == *"rejected selected runtime environment '$installed'"* ]] \
        || fail "health did not identify the rejected selected source: $output"
    [[ "$output" == *"Refusing to continue with inherited or lower-priority configuration."* ]] \
        || fail "health did not explain its fail-closed boundary: $output"
}

test_age_key_modes_are_explicit_and_deterministic() {
    local fake_repo="$TMP/fake-repo-key-mode" missing_installed="$TMP/no-installed-key-mode"
    mkdir -p "$fake_repo/secrets/keys"
    write_env "$fake_repo/.env" "PROJECT_STATE_DIR=$TMP/dev-state" 'SOPS_AGE_KEY_FILE='

    local output
    output=$(VW_CONFIG_INSTALLED_ENV_FILE="$missing_installed" PROJECT_ROOT="$fake_repo" REAL_CONFIG="$ROOT/lib/config.sh" bash <<'PROBE'
set -euo pipefail
source "$REAL_CONFIG"
load_project_environment >/dev/null
printf '%s\n' "$SOPS_AGE_KEY_FILE"
PROBE
)
    [[ "$output" == "/etc/vaultwarden/age-key.txt" ]] \
        || fail "normal repository bootstrap did not choose canonical production key: $output"

    output=$(VW_CONFIG_AGE_KEY_MODE=repository VW_CONFIG_INSTALLED_ENV_FILE="$missing_installed" \
        PROJECT_ROOT="$fake_repo" REAL_CONFIG="$ROOT/lib/config.sh" bash <<'PROBE'
set -euo pipefail
source "$REAL_CONFIG"
load_project_environment >/dev/null
printf '%s\n' "$SOPS_AGE_KEY_FILE"
PROBE
)
    [[ "$output" == "$fake_repo/secrets/keys/age-key.txt" ]] \
        || fail "explicit repository key mode was not deterministic: $output"
}

test_env_literal_and_injection_contracts() {
    local literal="$TMP/literal.env" dangerous="$TMP/dangerous.env"
    write_env "$literal" \
        'LITERAL_VALUE=left=right\path|pipe&semi;colon' \
        'QUOTED_VALUE="spaces = remain literal"'
    write_env "$dangerous" \
        'PROJECT_STATE_DIR=/safe' \
        'PATH=/attacker/bin'

    local output
    output=$(REAL_CONFIG="$ROOT/lib/config.sh" ENV_FILE="$literal" bash <<'PROBE'
set -euo pipefail
source "$REAL_CONFIG"
load_env_file "$ENV_FILE" >/dev/null
printf '%s|%s\n' "$LITERAL_VALUE" "$QUOTED_VALUE"
PROBE
)
    [[ "$output" == 'left=right\path|pipe&semi;colon|spaces = remain literal' ]] \
        || fail "literal environment values changed: $output"

    if REAL_CONFIG="$ROOT/lib/config.sh" ENV_FILE="$dangerous" bash <<'PROBE' >/dev/null 2>&1
set -euo pipefail
source "$REAL_CONFIG"
load_env_file "$ENV_FILE"
PROBE
    then
        fail "dangerous environment-variable injection was accepted"
    fi
}

test_runtime_callers_use_canonical_authority() {
    grep -Fq 'load_project_environment' "$ROOT/dashboard.sh" \
        || fail "dashboard does not load canonical runtime configuration"
    ! grep -Fq 'done < "${REPO_ROOT}/.env"' "$ROOT/dashboard.sh" \
        || fail "dashboard retains its private repository .env parser"
    local target
    for target in status info diagnose; do
        awk -v target="$target" '
            $0 ~ "^" target ":" { found=1 }
            found && /^[[:alnum:]_.-]+:/ && $0 !~ "^" target ":" { exit }
            found { print }
        ' "$ROOT/Makefile" | grep -Fq 'load_project_environment' \
            || fail "make $target does not load canonical runtime configuration"
    done
    ! grep -Eq "grep ['\"]?\\^PROJECT_STATE_DIR=" "$ROOT/Makefile" \
        || fail "Makefile retains private PROJECT_STATE_DIR parsing"
    grep -Fq 'if ! load_project_environment; then' "$ROOT/utilities/maintenance-health.sh" \
        || fail "health does not fail on canonical runtime load rejection"
    ! grep -Fq 'Continuing with inherited environment only' "$ROOT/utilities/maintenance-health.sh" \
        || fail "health still continues with inherited environment after rejection"
}

run_test 'repo .env without PROJECT_STATE_DIR falls through to installed environment' test_config_falls_through_empty_repo_state
run_test 'explicit caller overrides survive loading and repeated calls' test_config_caller_override_wins
run_test 'installed runtime secret resolution is guarded' test_installed_runtime_secret_resolution
run_test 'DNS update optional and strict modes are represented' test_dns_optional_and_strict_modes
run_test 'installed, persistent, and repository source precedence is canonical and observable' test_runtime_source_precedence_and_observability
run_test 'invalid selected production environment fails closed without fallback' test_invalid_selected_production_source_fails_closed
run_test 'repository Age-key behavior requires an explicit deterministic mode' test_age_key_modes_are_explicit_and_deterministic
run_test 'environment literals and injection protections remain intact' test_env_literal_and_injection_contracts
run_test 'dashboard, Make, health, and maintenance callers use canonical authority' test_runtime_callers_use_canonical_authority
[[ "$TESTS_RUN" -eq 9 ]] || fail "expected 9 tests, ran $TESTS_RUN"
printf '1..%s\n' "$TESTS_RUN"

)

check_config_environment_contracts
