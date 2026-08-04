#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS %s\n' "$*"; }

# Parse every tracked shell entry point separately from ShellCheck.
while IFS= read -r -d '' shell_file; do
  bash -n "$shell_file" || fail "bash syntax validation failed: $shell_file"
done < <(git ls-files -z '*.sh' '*.bash')
pass "repository-wide bash -n"

# Check the exact pull-request diff in Actions; check the working tree locally.
if [[ -n "${GITHUB_EVENT_PATH:-}" && -r "$GITHUB_EVENT_PATH" ]]; then
  base_sha="$(python3 -c 'import json, os; print(json.load(open(os.environ["GITHUB_EVENT_PATH"]))["pull_request"]["base"]["sha"])')"
  git fetch --no-tags --depth=1 origin "$base_sha" >/dev/null
  git diff --check "$base_sha" HEAD
else
  git diff --check
fi
pass "git diff --check"

# Integration and systemd contracts.
grep -Fq 'cleanup_expired_recovery_kits "$DRY_RUN" || recovery_cleanup_result=$?' \
  utilities/maintenance-run.sh || fail "maintenance does not invoke recovery fallback cleanup"
grep -Fq '[[ "$recovery_cleanup_result" != "0" ]] && ((++critical_failures))' \
  utilities/maintenance-run.sh || fail "recovery cleanup does not affect final status"
grep -Fq 'ReadWritePaths=-/root/vaultwarden-recovery' \
  systemd/vaultwarden-maintenance.service || fail "maintenance sandbox lacks exact recovery path"
grep -Fq 'OnCalendar=*-*-* 02:05:00' systemd/vaultwarden-maintenance.timer \
  || fail "maintenance timer schedule changed"
grep -Fq 'Persistent=false' systemd/vaultwarden-maintenance.timer \
  || fail "maintenance timer persistence changed"
if find systemd -maxdepth 1 -type f \
  \( -name 'vaultwarden-recovery-cleanup.service' -o -name 'vaultwarden-recovery-cleanup.timer' \) \
  -print -quit | grep -q .; then
  fail "a separate recovery cleanup unit was added"
fi

cleanup_helpers="$(sed -n '/^_remove_sensitive_file() {/,/^_prepare_recovery_dir() {/p' lib/secrets.sh | sed '$d')"
[[ "$cleanup_helpers" == *'cleanup_expired_recovery_kits()'* ]] \
  || fail "recovery cleanup helper block is missing"

if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  fixture="$(mktemp -d)"
  trap 'sudo -n /bin/rm -rf -- "$fixture" >/dev/null 2>&1 || true' EXIT
  sudo -n chown root:root "$fixture"
  sudo -n chmod 0700 "$fixture"
  sudo -n env \
    RECOVERY_KIT_DIR="$fixture" \
    VW_TEST_MODE=true \
    VW_RECOVERY_CLEANUP_MIN_AGE_SECONDS=60 \
    CLEANUP_HELPERS="$cleanup_helpers" \
    bash -s <<'ROOT_TEST' || fail "recovery cleanup behavior failed"
set -euo pipefail
log_debug() { :; }
log_info() { printf 'INFO %s\n' "$*"; }
log_warn() { printf 'WARN %s\n' "$*" >&2; }
log_error() { printf 'ERROR %s\n' "$*" >&2; }
eval "$CLEANUP_HELPERS"

make_file() {
  local path="$1" content="${2:-x}"
  printf '%s' "$content" > "$path"
  chmod 0600 "$path"
}
old="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120000Z-a1b2c3.txt"
young="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120001Z-a1b2c4.txt"
wrong_mode="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120002Z-a1b2c5.txt"
wrong_owner="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120003Z-a1b2c6.txt"
link="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120004Z-a1b2c7.txt"
target="$RECOVERY_KIT_DIR/target"
dir_candidate="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120005Z-a1b2c8.txt"
fifo_candidate="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120006Z-a1b2c9.txt"
hard="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120007Z-a1b2ca.txt"
hard_peer="$RECOVERY_KIT_DIR/hard-peer"
metachar="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120008Z-a1b2cb;touch-PWNED.txt"
nonmatching="$RECOVERY_KIT_DIR/unrelated.txt"
handoff="$RECOVERY_KIT_DIR/vaultwarden-setup-credentials-20260727T120000Z.txt"
zip_file="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120000Z-a1b2c3.zip"

make_file "$old" 'SECRET-MUST-NOT-APPEAR'
make_file "$young"
make_file "$wrong_mode"
chmod 0644 "$wrong_mode"
make_file "$wrong_owner"
chown 65534:65534 "$wrong_owner"
make_file "$target"
ln -s "$target" "$link"
mkdir "$dir_candidate"
mkfifo "$fifo_candidate"
make_file "$hard"
ln "$hard" "$hard_peer"
make_file "$metachar"
make_file "$nonmatching"
make_file "$handoff"
make_file "$zip_file"
touch -d '120 seconds ago' "$old" "$wrong_mode" "$wrong_owner" "$link" \
  "$dir_candidate" "$fifo_candidate" "$hard" "$metachar"

set +e
dry_output="$(cleanup_expired_recovery_kits true 2>&1)"
dry_rc=$?
set -e
(( dry_rc != 0 )) || exit 1
[[ -f "$old" ]] || exit 1
[[ "$dry_output" == *'[DRY RUN] Would remove expired plaintext recovery kit:'* ]] || exit 1
[[ "$dry_output" != *'SECRET-MUST-NOT-APPEAR'* ]] || exit 1

set +e
output="$(cleanup_expired_recovery_kits false 2>&1)"
rc=$?
set -e
(( rc != 0 )) || exit 1
[[ ! -e "$old" ]] || exit 1
[[ -e "$young" && -e "$wrong_mode" && -e "$wrong_owner" ]] || exit 1
[[ -L "$link" && -e "$target" && -d "$dir_candidate" && -p "$fifo_candidate" ]] || exit 1
[[ -e "$hard" && -e "$hard_peer" && -e "$metachar" ]] || exit 1
[[ -e "$nonmatching" && -e "$handoff" && -e "$zip_file" ]] || exit 1
[[ "$output" != *'SECRET-MUST-NOT-APPEAR'* ]] || exit 1
[[ ! -e "$RECOVERY_KIT_DIR/touch-PWNED.txt" ]] || exit 1

/bin/rm -f -- "$wrong_mode" "$wrong_owner" "$link" "$fifo_candidate" \
  "$hard" "$hard_peer" "$metachar" "$young" "$nonmatching" "$handoff" "$zip_file" "$target"
rmdir -- "$dir_candidate"
cleanup_expired_recovery_kits false

# Best-effort overwrite failure still falls back to unlink.
old2="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T121000Z-a1b2cc.txt"
make_file "$old2"
touch -d '120 seconds ago' "$old2"
shim_dir="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 1\n' > "$shim_dir/shred"
chmod 0755 "$shim_dir/shred"
PATH="$shim_dir:$PATH" cleanup_expired_recovery_kits false
[[ ! -e "$old2" ]] || exit 1
/bin/rm -rf -- "$shim_dir"

# A complete removal failure is reported and leaves the file in place.
old3="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T121100Z-a1b2cd.txt"
make_file "$old3"
touch -d '120 seconds ago' "$old3"
original_remove="$(declare -f _remove_sensitive_file)"
_remove_sensitive_file() { return 1; }
set +e
cleanup_expired_recovery_kits false >/dev/null 2>&1
rc=$?
set -e
(( rc != 0 )) || exit 1
[[ -e "$old3" ]] || exit 1
eval "$original_remove"
/bin/rm -f -- "$old3"

# A changed identity is never deleted.
race="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T121200Z-a1b2ce.txt"
make_file "$race"
touch -d '120 seconds ago' "$race"
real_stat="$(command -v stat)"
stat_counter="$RECOVERY_KIT_DIR/.stat-counter"
printf '0\n' > "$stat_counter"
stat() {
  local last="${!#}" count
  if [[ "$last" == "$race" && "${1:-}" == "-c" ]]; then
    count="$(cat "$stat_counter")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$stat_counter"
    if (( count == 2 )); then
      "$real_stat" "$@" | awk -F: 'BEGIN{OFS=":"} {$2=$2+1; print}'
      return 0
    fi
  fi
  "$real_stat" "$@"
}
set +e
cleanup_expired_recovery_kits false >/dev/null 2>&1
rc=$?
set -e
unset -f stat
(( rc != 0 )) || exit 1
[[ -e "$race" ]] || exit 1
/bin/rm -f -- "$race" "$stat_counter"

# Enumeration failure is visible, returns nonzero, and processes no partial list.
enum_fail="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T121300Z-a1b2cf.txt"
make_file "$enum_fail"
touch -d '120 seconds ago' "$enum_fail"
real_find="$(command -v find)"
find() {
  if [[ "$*" == *"vaultwarden-recovery-kit-*.txt"* ]]; then
    return 73
  fi
  "$real_find" "$@"
}
set +e
enum_output="$(cleanup_expired_recovery_kits false 2>&1)"
enum_rc=$?
set -e
unset -f find
(( enum_rc != 0 )) || exit 1
[[ -e "$enum_fail" ]] || exit 1
[[ "$enum_output" == *"failed to enumerate recovery-kit candidates"* ]] || exit 1
[[ "$enum_output" != *"Removed expired plaintext recovery kit"* ]] || exit 1
/bin/rm -f -- "$enum_fail"
# An absent test directory is an idempotent no-op and is not created.
absent="${RECOVERY_KIT_DIR}.absent"
RECOVERY_KIT_DIR="$absent" cleanup_expired_recovery_kits false
[[ ! -e "$absent" ]] || exit 1
ROOT_TEST
else
  printf 'SKIP root-owned recovery fixture: passwordless sudo unavailable\n'
fi

# Direct configure uses its installed TERM trap to clean the owned workspace.
direct_workspace_helpers="$(
  sed -n \
    '/^unset TMP_WORKDIR$/,/^trap '\''_setup_secrets_on_signal 143'\'' TERM$/p' \
    utilities/setup-secrets.sh
)"
[[ -n "$direct_workspace_helpers" ]] \
  || fail "direct sensitive-workspace helpers could not be extracted"
direct_signal_fixture="$(mktemp -d)"
direct_signal_marker="$direct_signal_fixture/workspace.path"
set +e
DIRECT_WORKSPACE_HELPERS="$direct_workspace_helpers" \
DIRECT_SIGNAL_MARKER="$direct_signal_marker" \
PROJECT_ROOT="$direct_signal_fixture" \
bash -s <<'DIRECT_SIGNAL_TEST' >/dev/null 2>&1
set -euo pipefail
log_warn() { printf 'WARN %s\n' "$*" >&2; }
cleanup_secrets_environment() { return 0; }
operation_release() { return 0; }
eval "$DIRECT_WORKSPACE_HELPERS"
_setup_secrets_create_workdir
printf '%s' "$SETUP_SECRETS_OWNED_WORKDIR" > "$DIRECT_SIGNAL_MARKER"
printf '%s' 'DIRECT-SIGNAL-SECRET' > "$SETUP_SECRETS_OWNED_WORKDIR/capture"
kill -TERM "$BASHPID"
exit 99
DIRECT_SIGNAL_TEST
direct_signal_rc=$?
set -e
direct_signal_workspace="$(cat "$direct_signal_marker")"
[[ "$direct_signal_rc" == 143 ]] \
  || fail "direct TERM path returned $direct_signal_rc instead of 143"
[[ ! -e "$direct_signal_workspace" ]] \
  || fail "direct TERM path left the sensitive workspace behind"
/bin/rm -rf -- "$direct_signal_fixture"

# Top-level setup creates one private workspace only when credential capture starts.
setup_workspace_helpers="$(
  sed -n \
    '/^unset VW_ADMIN_PLAIN_FILE/,/^trap '\''_setup_on_signal 143'\'' TERM$/p' \
    setup.sh
)"
[[ -n "$setup_workspace_helpers" ]] \
  || fail "top-level sensitive-workspace helpers could not be extracted"
SETUP_WORKSPACE_HELPERS="$setup_workspace_helpers" bash -s <<'TOP_LEVEL_WORKSPACE_TEST' \
  || fail "top-level lazy sensitive-workspace lifecycle failed"
set -euo pipefail
fixture="$(mktemp -d)"
trap '/bin/rm -rf -- "$fixture"' EXIT
TMPDIR="$fixture/tmp"
mkdir -p "$TMPDIR"
log_warn() { printf 'WARN %s\n' "$*" >&2; }
operation_release() { return 0; }
eval "$SETUP_WORKSPACE_HELPERS"
trap - EXIT INT HUP TERM

! find "$TMPDIR" -maxdepth 1 -name 'vw_setup.*' -print -quit | grep -q .
_setup_create_sensitive_workspace
workspace="$TMP_WORKDIR"
[[ -d "$workspace" && "$(stat -c '%a' "$workspace")" == "700" ]]
for capture in \
  "$VW_ADMIN_PLAIN_FILE" "$VW_ADMIN_HASH_FILE" \
  "$CADDY_PLAIN_FILE" "$CADDY_HASH_FILE"; do
  [[ "${capture%/*}" == "$workspace" ]]
done
printf '%s' 'TOP-LEVEL-PLAINTEXT-DO-NOT-LEAK' > "$VW_ADMIN_PLAIN_FILE"
_setup_remove_sensitive_workspace 0
[[ ! -e "$workspace" ]]

_setup_create_sensitive_workspace
blocked_workspace="$TMP_WORKDIR"
printf '%s' 'TOP-LEVEL-FAILURE-SECRET' > "$VW_ADMIN_PLAIN_FILE"
rm() {
  local last="${!#}"
  [[ "$last" == "$blocked_workspace" ]] && return 73
  command rm "$@"
}
set +e
failure_output="$({ set -x; _setup_remove_sensitive_workspace 0; } 2>&1)"
failure_rc=$?
set -e
[[ "$failure_rc" == 73 ]]
[[ -d "$blocked_workspace" ]]
[[ "$failure_output" == *"Failed to remove the setup sensitive workspace"* ]]
[[ "$failure_output" != *'TOP-LEVEL-FAILURE-SECRET'* ]]
set +e
_setup_remove_sensitive_workspace 42 >/dev/null 2>&1
original_rc=$?
set -e
[[ "$original_rc" == 42 ]]
unset -f rm
/bin/rm -rf -- "$blocked_workspace"
unset TMP_WORKDIR VW_ADMIN_PLAIN_FILE VW_ADMIN_HASH_FILE CADDY_PLAIN_FILE CADDY_HASH_FILE

signal_marker="$fixture/top-level-signal-workspace.path"
set +e
SETUP_WORKSPACE_HELPERS="$SETUP_WORKSPACE_HELPERS" \
TOP_LEVEL_SIGNAL_MARKER="$signal_marker" \
TMPDIR="$TMPDIR" \
bash -s <<'TOP_LEVEL_SIGNAL_TEST' >/dev/null 2>&1
set -euo pipefail
log_warn() { printf 'WARN %s\n' "$*" >&2; }
operation_release() { return 0; }
eval "$SETUP_WORKSPACE_HELPERS"
_setup_create_sensitive_workspace
printf '%s' "$TMP_WORKDIR" > "$TOP_LEVEL_SIGNAL_MARKER"
printf '%s' 'TOP-LEVEL-SIGNAL-SECRET' > "$VW_ADMIN_PLAIN_FILE"
kill -TERM "$BASHPID"
exit 99
TOP_LEVEL_SIGNAL_TEST
signal_rc=$?
set -e
signal_workspace="$(cat "$signal_marker")"
[[ "$signal_rc" == 143 ]]
[[ ! -e "$signal_workspace" ]]
/bin/rm -rf -- "$fixture"
trap - EXIT
TOP_LEVEL_WORKSPACE_TEST

# Ubuntu 7zip package and executable-selection contracts.
# Exact apt dependency-array tokenization contract.
python3 - <<'PY_PACKAGES' \
  || fail "dependency package array tokenization contract failed"
from pathlib import Path
import re
import shlex

expected = [
    "age", "make", "nano", "rclone", "sqlite3", "jq", "ufw", "curl",
    "wget", "unzip", "7zip", "git", "gpg", "coreutils", "util-linux",
    "haveged", "dnsutils", "rsync", "python3", "python3-argon2",
    "python3-bcrypt", "python3-yaml", "apache2-utils", "cron", "openssl",
    "tar", "zstd",
]
text = Path("utilities/setup-system.sh").read_text(encoding="utf-8")
matches = re.findall(
    r"(?m)^[ \t]*local basic_packages=\((.*)\)[ \t]*$",
    text,
)
if len(matches) != 1:
    raise SystemExit(
        f"expected one basic_packages declaration, found {len(matches)}"
    )
actual = shlex.split(matches[0], posix=True)
if actual != expected:
    raise SystemExit(
        "basic_packages tokenization mismatch:\n"
        f"expected={expected!r}\nactual={actual!r}"
    )
PY_PACKAGES
grep -Fq '"unzip" "7zip" "git"' utilities/setup-system.sh \
  || fail "normal dependency list does not install Ubuntu 7zip"
grep -Fq '"dnsutils" "rsync" "python3" "python3-argon2"' utilities/setup-system.sh \
  || fail "dependency list must keep rsync and python3 as separate package entries"
! grep -Fq '"rsync""python3"' utilities/setup-system.sh \
  || fail "dependency list contains a concatenated rsync/python3 package token"
! grep -Eq '^[[:space:]]*\[7zip\]=' utilities/setup-system.sh \
  || fail "generic dependency map must not claim one guaranteed 7-Zip executable"
grep -Fq 'for candidate in 7zz 7z; do' utilities/setup-system.sh \
  || fail "setup dependency resolver does not prefer 7zz with 7z fallback"
grep -Fq '_require_7zip_command || return 1' utilities/setup-system.sh \
  || fail "--skip-deps verification does not require a usable 7-Zip executable"
grep -Fq 'Install hint: sudo apt-get install -y 7zip' utilities/setup-system.sh \
  || fail "setup-system 7zip installation guidance is incorrect"
grep -Fq 'sudo apt-get install -y docker.io age sops 7zip python3-argon2 python3-bcrypt' setup.sh \
  || fail "top-level setup phase guidance omits 7zip"
grep -Fq 'for candidate in 7zz 7z; do' lib/secrets.sh \
  || fail "recovery ZIP helper does not prefer 7zz with 7z fallback"
grep -Fq 'a -tzip -mem=AES256' lib/secrets.sh \
  || fail "recovery artifact is no longer an AES-256 encrypted ZIP"
resolver_block="$(sed -n '/^_resolve_7zip_command() {/,/^# Install the required system packages/p' utilities/setup-system.sh | sed '$d')"
[[ -n "$resolver_block" ]] || fail "7zip resolver block could not be extracted"
RESOLVER_BLOCK="$resolver_block" bash -s <<'SEVENZIP_TEST' \
  || fail "7zip executable resolution tests failed"
set -euo pipefail
log_error() { printf 'ERROR %s\n' "$*" >&2; }
log_info() { printf 'INFO %s\n' "$*" >&2; }
log_debug() { :; }
eval "$RESOLVER_BLOCK"
fixture="$(mktemp -d)"
trap '/bin/rm -rf -- "$fixture"' EXIT
make_cmd() {
  local dir="$1" name="$2"
  mkdir -p -- "$dir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/$name"
  chmod 0755 "$dir/$name"
}
preferred="$fixture/preferred"
make_cmd "$preferred" 7zz
[[ "$(PATH="$preferred" _resolve_7zip_command)" == 7zz ]]
PATH="$preferred" _require_7zip_command
both="$fixture/both"
make_cmd "$both" 7zz
make_cmd "$both" 7z
[[ "$(PATH="$both" _resolve_7zip_command)" == 7zz ]]
PATH="$both" _require_7zip_command
fallback="$fixture/fallback"
make_cmd "$fallback" 7z
[[ "$(PATH="$fallback" _resolve_7zip_command)" == 7z ]]
PATH="$fallback" _require_7zip_command
empty="$fixture/empty"
mkdir -p -- "$empty"
set +e
missing_output="$(PATH="$empty" _require_7zip_command 2>&1)"
missing_rc=$?
set -e
(( missing_rc != 0 ))
[[ "$missing_output" == *"expected 7zz (preferred) or 7z"* ]]
[[ "$missing_output" == *"sudo apt-get install -y 7zip"* ]]
/bin/rm -rf -- "$fixture"
trap - EXIT
SEVENZIP_TEST
python3 - <<'PY_ORDER' || fail "success-summary ordering is unsafe"
from pathlib import Path
setup = Path('setup.sh').read_text()
secrets = Path('utilities/setup-secrets.sh').read_text()
start = setup.index('credential_file="$(publish_setup_credentials')
assert setup.index('_setup_remove_sensitive_workspace 0', start) < setup.index('│  SETUP CREDENTIALS SAVED', start)
start = secrets.index('_ss_publish_auto_handoff || return 1')
assert secrets.index('_ss_perform_cleanup 0', start) < secrets.index('Secrets Setup Complete!', start)
PY_ORDER

pass "recovery fallback and sensitive cleanup contracts"

check_setup_failure_gates() (
set -euo pipefail

if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; then
  if [[ "${CI:-false}" == "true" || "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    fail "mandatory setup failure-gate regressions require passwordless sudo in CI"
  fi
  printf 'SKIP setup failure gates: passwordless sudo unavailable\n'
  exit 0
fi

setup_tmp="$(mktemp -d)"
trap 'sudo -n rm -rf -- "$setup_tmp" >/dev/null 2>&1 || true' EXIT INT TERM HUP
setup_fixture="$setup_tmp/repo"
mkdir -p "$setup_fixture"
tar --exclude='./.git' --exclude='./test-results' -cf - . | tar -xf - -C "$setup_fixture"
cat > "$setup_fixture/lib/validate.sh" <<'EOF_SETUP_VALIDATE'
validate_domain() { return 0; }
validate_email() { return 0; }
EOF_SETUP_VALIDATE

setup_invocations="$setup_tmp/invocations.log"
: > "$setup_invocations"
chmod 0666 "$setup_invocations"
cat > "$setup_tmp/utility-stub" <<'EOF_SETUP_STUB'
#!/usr/bin/env bash
set -euo pipefail
name="$(basename "$0")"
printf '%s:%s\n' "$name" "$*" >> "${VW_TEST_INVOCATION_LOG:?}"
case "$name" in
  setup-firewall.sh)
    if [[ " $* " == *" --phase ufw "* && "${VW_TEST_FAIL_UFW:-0}" == "1" ]]; then
      exit 42
    fi
    ;;
  setup-secrets.sh)
    if [[ "${1:-}" == "configure" && "${VW_TEST_FAIL_SECRETS:-0}" == "1" ]]; then
      exit 43
    fi
    ;;
esac
EOF_SETUP_STUB
chmod 0755 "$setup_tmp/utility-stub"
for utility in \
  setup-system.sh setup-storage.sh setup-env.sh setup-secrets.sh \
  setup-firewall.sh setup-systemd.sh setup-crowdsec.sh uninstall-vaultwarden.sh; do
  cp "$setup_tmp/utility-stub" "$setup_fixture/utilities/$utility"
  chmod 0755 "$setup_fixture/utilities/$utility"
done

run_setup_failure() {
  local label="$1" fail_ufw="$2" fail_secrets="$3" output rc
  : > "$setup_invocations"
  rm -rf "$setup_tmp/recovery"
  set +e
  output="$(
    sudo -n env \
      VW_TEST_INVOCATION_LOG="$setup_invocations" \
      VW_TEST_FAIL_UFW="$fail_ufw" \
      VW_TEST_FAIL_SECRETS="$fail_secrets" \
      SETUP_CREDENTIALS_DIR="$setup_tmp/recovery" \
      ENTROPY_THRESHOLD=0 \
      bash "$setup_fixture/setup.sh" install \
        --domain vault.example.com \
        --email admin@example.com \
        --auto --skip-deps 2>&1
  )"
  rc=$?
  set -e
  (( rc != 0 )) || fail "$label unexpectedly returned success"
  [[ "$output" != *"SETUP CREDENTIALS SAVED"* ]] \
    || fail "$label printed credential-publication success"
  [[ ! -e "$setup_tmp/recovery" ]] || {
    ! find "$setup_tmp/recovery" -type f \
      -name 'vaultwarden-setup-credentials-*' -print -quit | grep -q . \
      || fail "$label published a setup credential handoff"
  }
  printf '%s' "$output"
}

ufw_output="$(run_setup_failure "UFW failure" 1 0)"
[[ "$ufw_output" == *"Phase 5"* ]] || fail "UFW failure did not identify phase 5"
! grep -q 'setup-firewall.sh:--phase iptables' "$setup_invocations" \
  || fail "iptables phase ran after required UFW failure"
! grep -q 'setup-secrets.sh:configure' "$setup_invocations" \
  || fail "secrets configuration ran after required UFW failure"

secrets_output="$(run_setup_failure "automatic secrets failure" 0 1)"
[[ "$secrets_output" == *"Phase 6"* ]] \
  || fail "automatic secrets failure did not identify phase 6"
grep -q 'setup-secrets.sh:configure' "$setup_invocations" \
  || fail "automatic secrets configure stub was not invoked"

# Automatic dry-run must reach secrets configuration without allocating or publishing plaintext state.
dry_tmp="$setup_tmp/dry-run-tmp"
mkdir -p "$dry_tmp"
: > "$setup_invocations"
rm -rf "$setup_tmp/recovery"
set +e
dry_output="$(
  sudo -n env \
    TMPDIR="$dry_tmp" \
    VW_TEST_INVOCATION_LOG="$setup_invocations" \
    VW_TEST_FAIL_UFW=0 \
    VW_TEST_FAIL_SECRETS=0 \
    SETUP_CREDENTIALS_DIR="$setup_tmp/recovery" \
    ENTROPY_THRESHOLD=0 \
    bash "$setup_fixture/setup.sh" install \
      --domain vault.example.com \
      --email admin@example.com \
      --auto --skip-deps --dry-run 2>&1
)"
dry_rc=$?
set -e
(( dry_rc == 0 )) || fail "automatic setup dry-run failed: $dry_output"
grep -q 'setup-secrets.sh:configure .*--dry-run' "$setup_invocations" \
  || fail "automatic setup dry-run did not delegate dry-run to secrets configuration"
! find "$dry_tmp" -mindepth 1 -maxdepth 1 -name 'vw_setup.*' -print -quit | grep -q . \
  || fail "automatic setup dry-run created a sensitive workspace"
[[ ! -e "$setup_tmp/recovery" ]] || {
  ! find "$setup_tmp/recovery" -type f \
    -name 'vaultwarden-setup-credentials-*' -print -quit | grep -q . \
    || fail "automatic setup dry-run published a credential handoff"
}
)
check_setup_failure_gates
pass "behavioral setup failure gates and dry-run safety"

# Exercise the real direct command parser and orchestration under a PTY with
# deterministic synthetic values. Host-output boundaries are replaced only in
# a copied fixture; production source remains unchanged.
if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
(
  direct_tmp="$(mktemp -d)"
  trap 'sudo -n rm -rf -- "$direct_tmp" >/dev/null 2>&1 || true' EXIT INT TERM HUP
  direct_fixture="$direct_tmp/repo"
  mkdir -p "$direct_fixture"
  tar --exclude='./.git' --exclude='./test-results' --exclude='./vw_tmp.*' \
    -cf - . | tar -xf - -C "$direct_fixture"

  direct_bin="$direct_tmp/bin"
  direct_state="$direct_tmp/state"
  success_dir="$direct_tmp/recovery-success"
  failure_target="$direct_tmp/recovery-not-a-directory"
  counter_file="$direct_tmp/generator-counter"
  workspace_mode_file="$direct_tmp/workspace.mode"
  mkdir -p "$direct_bin" "$direct_state" "$success_dir"
  chmod 0700 "$direct_state" "$success_dir"
  printf '0\n' > "$counter_file"
  chmod 0666 "$counter_file"
  printf 'publication must fail here\n' > "$failure_target"

  public_recipient="age1$(printf 'q%.0s' {1..58})"
  age_key_file="$direct_tmp/age-key.txt"
  {
    printf '# AGE-SECRET-KEY-TEST-DO-NOT-LEAK\n'
    printf '%s\n' 'AGE-SECRET-KEY-1SYNTHETIC-DIRECT-AUTO-ONLY'
  } > "$age_key_file"
  chmod 0600 "$age_key_file"

  cat > "$direct_fixture/.env" <<EOF_DIRECT_ENV
PROJECT_STATE_DIR=$direct_state
SOPS_AGE_KEY_FILE=
EMAIL_MODE=api
EMAIL_PROVIDER=mailersend
PUSH_ENABLED=false
EOF_DIRECT_ENV
  chmod 0600 "$direct_fixture/.env"
  cat > "$direct_fixture/.sops.yaml" <<EOF_DIRECT_SOPS
creation_rules:
  - path_regex: '.*\\.yaml$'
    age: "$public_recipient"
EOF_DIRECT_SOPS

  cat >> "$direct_fixture/lib/config.sh" <<'EOF_DIRECT_CONFIG'
load_project_environment() {
  PROJECT_STATE_DIR="${VW_TEST_PROJECT_STATE_DIR:?}"
  SOPS_AGE_KEY_FILE="${VW_TEST_AGE_KEY_FILE:?}"
  SECRETS_FILE="${PROJECT_STATE_DIR}/secrets/secrets.yaml"
  export PROJECT_STATE_DIR SOPS_AGE_KEY_FILE SECRETS_FILE
}
EOF_DIRECT_CONFIG
  cat >> "$direct_fixture/lib/operations.sh" <<'EOF_DIRECT_OPERATIONS'
operation_acquire() { return 0; }
operation_release() { return 0; }
operation_set_phase() { return 0; }
EOF_DIRECT_OPERATIONS
  cat >> "$direct_fixture/lib/secrets.sh" <<'EOF_DIRECT_SECRETS'
schema_validate() { return 0; }
schema_keys() { printf '%s\n' admin_token admin_basic_auth_hash file_integrity_hmac_key; }
schema_collect_type() {
  case "$1" in
    file_integrity_hmac_key) printf '%s' auto ;;
    *) printf '%s' manual ;;
  esac
}
schema_field_safe() {
  case "$1:$2" in
    file_integrity_hmac_key:auto_fn) printf '%s' auto_generate_secret_field ;;
    *:label) printf '%s' 'Synthetic test field' ;;
    *) printf '%s' '' ;;
  esac
}
generate_secure_string() {
  local requested="$1" next
  if [[ "$requested" == "64" ]]; then
    printf '%s' 'TEST-INTEGRITY-HMAC-NOT-A-HANDOFF-PASSWORD'
    return 0
  fi
  if [[ -n "${VW_ADMIN_PLAIN_FILE:-}" ]]; then
    stat -c '%a' "$(dirname "$VW_ADMIN_PLAIN_FILE")" \
      > "${VW_TEST_WORKSPACE_MODE_FILE:?}"
  fi
  next="$(( $(cat "${VW_TEST_COUNTER_FILE:?}") + 1 ))"
  printf '%s\n' "$next" > "${VW_TEST_COUNTER_FILE}"
  case "$next" in
    1) printf '%s' 'TEST-VW-PLAINTEXT-DO-NOT-LEAK' ;;
    2) printf '%s' 'TEST-CADDY-PLAINTEXT-DO-NOT-LEAK' ;;
    *) return 1 ;;
  esac
}
generate_argon2_hash() { printf '%s' 'TEST-VW-ARGON2-HASH'; }
generate_bcrypt_hash() { printf '%s' 'TEST-CADDY-BCRYPT-HASH'; }
_bcrypt_format_ok() { return 0; }
check_age_key() { return 0; }
check_argon2_support() { return 0; }
get_age_public_key() { printf '%s' "${VW_TEST_PUBLIC_RECIPIENT:?}"; }
secrets_file_exists() { return 1; }
check_placeholder_values() { return 0; }
ensure_sops_env() {
  export SOPS_AGE_KEY_FILE="${VW_TEST_AGE_KEY_FILE:?}"
  export SOPS_CONFIG="${PROJECT_ROOT}/.sops.yaml"
}
cleanup_secrets_environment() { unset SOPS_AGE_KEY_FILE SOPS_CONFIG; }
secure_secrets_file() { chmod 0600 "$1"; }
export_docker_secrets() { return 0; }
prepare_push_secret_placeholders() { return 0; }
EOF_DIRECT_SECRETS
  cat >> "$direct_fixture/lib/setup-credentials.sh" <<'EOF_DIRECT_HANDOFF'
_setup_handoff_verify_argon2() { return 0; }
_setup_handoff_verify_bcrypt() { return 0; }
EOF_DIRECT_HANDOFF

  cat > "$direct_bin/age-keygen" <<'EOF_DIRECT_AGE'
#!/usr/bin/env bash
printf '%s\n' "${VW_TEST_PUBLIC_RECIPIENT:?}"
EOF_DIRECT_AGE
  cat > "$direct_bin/yq" <<'EOF_DIRECT_YQ'
#!/usr/bin/env bash
printf '%s\n' "${VW_TEST_PUBLIC_RECIPIENT:?}"
EOF_DIRECT_YQ
  cat > "$direct_bin/sops" <<'EOF_DIRECT_SOPS_BIN'
#!/usr/bin/env bash
set -euo pipefail
output=""
input="${!#}"
for (( index=1; index<=$#; index++ )); do
  arg="${!index}"
  if [[ "$arg" == "--output" ]]; then
    next=$((index + 1))
    output="${!next}"
  elif [[ "$arg" == "updatekeys" ]]; then
    exit 0
  fi
done
if [[ " $* " == *" --encrypt "* ]]; then
  cp "$input" "$output"
elif [[ " $* " == *" -d "* ]]; then
  cat "$input"
fi
EOF_DIRECT_SOPS_BIN
  cat > "$direct_bin/install" <<'EOF_DIRECT_INSTALL'
#!/usr/bin/env bash
if [[ " $* " == *" /run/vaultwarden-oci/secrets "* ]]; then
  exit 0
fi
exec "${VW_TEST_REAL_INSTALL:?}" "$@"
EOF_DIRECT_INSTALL
  for command_name in age jq htpasswd; do
    cat > "$direct_bin/$command_name" <<'EOF_DIRECT_COMMAND'
#!/usr/bin/env bash
exit 0
EOF_DIRECT_COMMAND
  done
  chmod 0755 "$direct_bin"/*

  pty_runner="$direct_tmp/run-under-pty.py"
  cat > "$pty_runner" <<'PY_DIRECT_PTY'
#!/usr/bin/env python3
import os
import pty
import sys

stdout_path, stderr_path, pty_path = sys.argv[1:4]
command = sys.argv[4:]
pid, master = pty.fork()
if pid == 0:
    stdout_fd = os.open(stdout_path, os.O_WRONLY | os.O_TRUNC)
    stderr_fd = os.open(stderr_path, os.O_WRONLY | os.O_TRUNC)
    os.dup2(stdout_fd, 1)
    os.dup2(stderr_fd, 2)
    os.execvp(command[0], command)
with open(pty_path, "wb") as pty_output:
    while True:
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        pty_output.write(chunk)
os.close(master)
_, status = os.waitpid(pid, 0)
raise SystemExit(os.waitstatus_to_exitcode(status))
PY_DIRECT_PTY
  chmod 0755 "$pty_runner"

  assert_secret_free_streams() {
    local label="$1" stream marker
    for stream in "$direct_stdout" "$direct_stderr" "$direct_pty"; do
      for marker in \
        'TEST-VW-PLAINTEXT-DO-NOT-LEAK' \
        'TEST-CADDY-PLAINTEXT-DO-NOT-LEAK' \
        'AGE-SECRET-KEY-TEST-DO-NOT-LEAK'; do
        ! grep -Fq "$marker" "$stream" \
          || fail "$label leaked $marker through $(basename "$stream")"
      done
    done
  }

  assert_direct_temps_clean() {
    ! find "$direct_fixture" -maxdepth 1 -name 'vw_tmp.*' -print -quit | grep -q . \
      || fail "$1 left its credential workspace behind"
    if sudo -n test -d "$direct_tmp/plaintext-stage"; then
      ! sudo -n find "$direct_tmp/plaintext-stage" -type f -print -quit | grep -q . \
        || fail "$1 left its plaintext SOPS staging file behind"
    fi
  }

  run_direct_case() {
    local label="$1" handoff_target="$2"
    direct_stdout="$direct_tmp/$label.stdout"
    direct_stderr="$direct_tmp/$label.stderr"
    direct_pty="$direct_tmp/$label.pty"
    : > "$direct_stdout"
    : > "$direct_stderr"
    : > "$direct_pty"
    : > "$workspace_mode_file"
    chmod 0666 "$direct_stdout" "$direct_stderr" "$workspace_mode_file"
    printf '0\n' > "$counter_file"
    set +e
    python3 "$pty_runner" "$direct_stdout" "$direct_stderr" "$direct_pty" \
      sudo -n /usr/bin/env \
        "PATH=$direct_bin:$PATH" \
        "OFFLINE_AGE_RECIPIENT=$public_recipient" \
        "PROJECT_STATE_DIR=$direct_state" \
        "SOPS_AGE_KEY_FILE=$age_key_file" \
        "SETUP_CREDENTIALS_DIR=$handoff_target" \
        "VW_HANDOFF_TEST_MODE=true" \
        "VW_TEST_AGE_KEY_FILE=$age_key_file" \
        "VW_TEST_COUNTER_FILE=$counter_file" \
        "VW_TEST_PROJECT_STATE_DIR=$direct_state" \
        "VW_TEST_PUBLIC_RECIPIENT=$public_recipient" \
        "VW_TEST_REAL_INSTALL=$(command -v install)" \
        "VW_TEST_WORKSPACE_MODE_FILE=$workspace_mode_file" \
        "VW_SETUP_SECRETS_TMP_DIR=$direct_tmp/plaintext-stage" \
        bash -x "$direct_fixture/utilities/setup-secrets.sh" configure --auto
    direct_rc=$?
    set -e
  }

  run_direct_case success "$success_dir"
  (( direct_rc == 0 )) || fail "direct configure --auto failed in PTY fixture"
  grep -Fq '_cmd_configure --auto' "$direct_stderr" \
    || fail "direct automatic regression did not exercise the command parser"
  assert_secret_free_streams "successful direct automatic setup"
  [[ "$(cat "$workspace_mode_file")" == "700" ]] \
    || fail "direct automatic credential workspace mode is not 0700"
  handoff_file="$(
    sudo -n find "$success_dir" -maxdepth 1 -type f \
      -name 'vaultwarden-setup-credentials-*.txt' -print
  )"
  [[ -n "$handoff_file" ]] || fail "direct automatic setup did not publish a handoff"
  [[ "$(sudo -n stat -c '%a' "$handoff_file")" == "600" ]] \
    || fail "direct automatic handoff file mode is not 0600"
  [[ "$(sudo -n grep -c '^│  0[123]  ' "$handoff_file")" == "3" ]] \
    || fail "direct automatic handoff does not contain exactly three groups"
  grep -Fq "Protected setup credential handoff created: $handoff_file" "$direct_stdout" \
    || fail "direct automatic setup did not report the protected handoff path"
  assert_direct_temps_clean "direct automatic success"

  run_direct_case publication-failure "$failure_target"
  (( direct_rc != 0 )) || fail "forced handoff-publication failure returned success"
  assert_secret_free_streams "failed direct automatic setup"
  ! grep -Fq 'Protected setup credential handoff created:' \
    "$direct_stdout" "$direct_stderr" "$direct_pty" \
    || fail "publication failure printed a protected-handoff success summary"
  ! grep -Fq 'Secrets Setup Complete!' \
    "$direct_stdout" "$direct_stderr" "$direct_pty" \
    || fail "publication failure printed the generic success summary"
  assert_direct_temps_clean "direct automatic failure"
) || fail "behavioral direct automatic protected-handoff contract failed"
  pass "direct automatic setup PTY no-leak regression"
else
  if [[ "${CI:-false}" == "true" || "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    fail "mandatory direct automatic PTY regression requires passwordless sudo in CI"
  fi
  printf 'SKIP direct automatic PTY behavior: passwordless sudo unavailable\n'
fi
