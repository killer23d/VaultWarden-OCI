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
trap 'rm -rf "$tmp"' EXIT
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

# Optional real 7-Zip smoke test when the distro tool is available.
tool=""
if command -v 7z >/dev/null 2>&1; then
  tool=7z
elif command -v 7zz >/dev/null 2>&1; then
  tool=7zz
fi
if [[ -n "$tool" ]]; then
  printf payload > "$tmp/document.txt"
  passphrase='VWOCI-synthetic-zip-passphrase-2026'
  printf '%s\n%s\n' "$passphrase" "$passphrase" | (
    cd "$tmp" && "$tool" a -tzip -mem=AES256 -mx=5 -bd -y -p archive.zip document.txt >/dev/null
  )
  listing="$("$tool" l -slt "$tmp/archive.zip")"
  grep -q '^Type = zip$' <<<"$listing" || fail "real archive is not ZIP"
  grep -Eq '^Method = .*AES-256' <<<"$listing" || fail "real archive is not AES-256"
  printf '%s\n' "$passphrase" | "$tool" t -bd -y -p "$tmp/archive.zip" >/dev/null
  ! printf '%s\n' wrong | "$tool" t -bd -y -p "$tmp/archive.zip" >/dev/null 2>&1 || fail "wrong password extracted ZIP"
fi

pass "production-readiness recovery/backup regressions"
