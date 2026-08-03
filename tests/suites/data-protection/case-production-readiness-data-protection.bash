#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS %s\n' "$*"; }

grep -q -- '-mem=AES256' lib/secrets.sh || fail "AES-256 ZIP creation missing"
grep -q 'important-documents-.*\.zip' lib/secrets.sh || fail "ZIP attachment name missing"
! grep -q 'tar\.gpg\|--symmetric' lib/secrets.sh || fail "legacy TAR/GPG attachment path remains"
grep -q -- '--id recovery-export' utilities/secrets-export-recovery-kit.sh || fail "recovery export operation guard missing"
for pattern in \
  'recovery-kit-*.txt' \
  'vaultwarden-recovery-kit-*.txt' \
  'vaultwarden-recovery-*.txt' \
  'vaultwarden-setup-credentials-*.txt' \
  'important-documents-*.zip'; do
  grep -Fq "\"$pattern\"" utilities/backup-run.sh || fail "full-backup exclusion missing: $pattern"
done

# Exercise the actual archive-listing validator against a synthetic forbidden member.
tmp="$(mktemp -d)"
cleanup() {
  if [[ -d "${protected_dir:-}" ]] && (( EUID != 0 )); then
    sudo rm -rf "$protected_dir" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/state/data" "$tmp/project"
printf db > "$tmp/state/data/db.sqlite3"
printf secret > "$tmp/project/vaultwarden-recovery-kit-test.txt"
tar -cf "$tmp/invalid.tar" -C / "${tmp#/}/state/data/db.sqlite3" "${tmp#/}/project/vaultwarden-recovery-kit-test.txt"
sed -n '/^_validate_full_archive_payload() {/,/^}/p' utilities/backup-run.sh > "$tmp/validator.bash"
log_error() { printf '%s\n' "$*" >&2; }
backup_log_warn() { :; }
# shellcheck disable=SC1090
source "$tmp/validator.bash"
if _validate_full_archive_payload "$tmp/invalid.tar" "$tmp/state" "$tmp/project" full >/dev/null 2>&1; then
  fail "full archive accepted a recovery artifact"
fi

# A genuinely fresh host may use explicit process overrides for remote inventory.
mock_bin="$tmp/bin"
mkdir -p "$mock_bin" "$tmp/home/.config/rclone" "$tmp/missing-state"
cat > "$mock_bin/rclone" <<'EOF_RCLONE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${RCLONE_CALLS:?}"
case "${1:-}" in
  lsf)
    [[ "${*: -1}" == *'/db' ]] && printf 'db_backup_20260803_000000.sqlite3.age\n'
    ;;
  lsl)
    printf '123 2026-08-03 00:00:00.000000000 db_backup_20260803_000000.sqlite3.age\n'
    ;;
  listremotes)
    printf 'testremote:\n'
    ;;
esac
EOF_RCLONE
chmod 0755 "$mock_bin/rclone"
printf '[testremote]\ntype = local\n' > "$tmp/home/.config/rclone/rclone.conf"
chmod 0600 "$tmp/home/.config/rclone/rclone.conf"

fresh_output="$tmp/fresh-list.out"
rclone_calls="$tmp/rclone-calls.log"
: > "$rclone_calls"
if ! env \
  PATH="$mock_bin:$PATH" \
  HOME="$tmp/home" \
  PROJECT_STATE_DIR="$tmp/missing-state" \
  VW_CONFIG_INSTALLED_ENV_FILE="$tmp/missing-installed.env" \
  RCLONE_REMOTE_NAME=testremote \
  RCLONE_REMOTE_PATH=testpath \
  RCLONE_CONFIG="$tmp/home/.config/rclone/rclone.conf" \
  RCLONE_CALLS="$rclone_calls" \
  bash ./restore.sh list --remote >"$fresh_output" 2>&1; then
  cat "$fresh_output" >&2
  fail "fresh-host remote inventory rejected explicit session configuration"
fi
grep -Fq 'db_backup_20260803_000000.sqlite3.age' "$fresh_output" \
  || { cat "$fresh_output" >&2; fail "fresh-host remote inventory did not list the remote backup"; }
grep -Fq 'testremote:testpath/db' "$rclone_calls" \
  || { cat "$rclone_calls" >&2; fail "fresh-host remote inventory did not use session remote values"; }
pass "fresh-host remote inventory accepts explicit session configuration"

# A present-but-invalid installed environment must fail before restore work begins.
invalid_env="$tmp/invalid-installed.env"
printf 'PROJECT_STATE_DIR=%s\n' "$tmp/installed-state" > "$invalid_env"
chmod 0644 "$invalid_env"
invalid_output="$tmp/invalid-restore.out"
ops_dir="$tmp/operations"
ops_lock="$tmp/operations.lock"
run_root() {
  if (( EUID == 0 )); then
    "$@"
  else
    sudo -n "$@"
  fi
}
if run_root env \
  PATH="$mock_bin:$PATH" \
  HOME="$tmp/home" \
  PROJECT_STATE_DIR="$tmp/missing-state" \
  VW_CONFIG_INSTALLED_ENV_FILE="$invalid_env" \
  VW_OPERATIONS_STATE_DIR="$ops_dir" \
  VW_OPERATIONS_LOCK="$ops_lock" \
  bash ./restore.sh interactive --remote --force >"$invalid_output" 2>&1; then
  cat "$invalid_output" >&2
  fail "restore accepted an insecure installed environment"
fi
grep -Eiq 'insecure permissions|failed to load project environment' "$invalid_output" \
  || { cat "$invalid_output" >&2; fail "invalid installed environment failure was not actionable"; }
[[ ! -e "$ops_dir" && ! -e "$ops_lock" ]] \
  || fail "restore started operation work before rejecting invalid installed configuration"
pass "invalid installed environment fails before restore work"

# Production permissions must fail clearly for an unsupported unprivileged reader.
if (( EUID != 0 )) && command -v sudo >/dev/null 2>&1; then
  protected_dir="$tmp/protected-installed"
  protected_env="$protected_dir/vaultwarden.env"
  sudo install -d -m 0700 -o root -g root "$protected_dir"
  printf 'PROJECT_STATE_DIR=%s\n' "$tmp/protected-state" \
    | sudo tee "$protected_env" >/dev/null
  sudo chown root:root "$protected_env"
  sudo chmod 0600 "$protected_env"
  protected_output="$tmp/protected-list.out"
  if env \
    PROJECT_STATE_DIR="$tmp/missing-state" \
    VW_CONFIG_INSTALLED_ENV_FILE="$protected_env" \
    bash ./restore.sh list >"$protected_output" 2>&1; then
    cat "$protected_output" >&2
    fail "unprivileged restore inventory bypassed protected installed configuration"
  fi
  grep -Eq 'Re-run .*sudo' "$protected_output" \
    || { cat "$protected_output" >&2; fail "protected installed configuration failure lacked sudo guidance"; }
  pass "protected installed environment fails clearly for unprivileged inventory"
fi

# Optional real 7-Zip smoke test when the distro tool is available.
tool=""
if command -v 7z >/dev/null 2>&1; then
  tool=7z
elif command -v 7zz >/dev/null 2>&1; then
  tool=7zz
fi
if [[ -n "$tool" ]]; then
  printf payload > "$tmp/document.txt"

  # These are synthetic, non-secret test values.  Supplying them with the
  # documented -p{password} switch avoids implementation-specific interactive
  # prompt handling in non-TTY CI.  Production passphrases remain protected by
  # the separate no-secret-in-argv tests.
  ci_passphrase='vwoci-ci-only-aes-zip-password'
  wrong_passphrase='vwoci-ci-only-wrong-password'

  (
    cd "$tmp"
    "$tool" a -tzip -mem=AES256 -mx=5 -bd -y \
      "-p${ci_passphrase}" archive.zip document.txt >/dev/null
  )
  listing="$("$tool" l -slt "$tmp/archive.zip")"
  grep -q '^Type = zip$' <<<"$listing" || fail "real archive is not ZIP"
  grep -Eq '^Method = .*AES-256' <<<"$listing" || fail "real archive is not AES-256"
  "$tool" t -bd -y "-p${ci_passphrase}" "$tmp/archive.zip" >/dev/null
  ! "$tool" t -bd -y "-p${wrong_passphrase}" "$tmp/archive.zip" >/dev/null 2>&1 \
    || fail "wrong password extracted ZIP"
fi

pass "production-readiness recovery/backup regressions"
