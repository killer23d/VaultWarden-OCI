#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS %s\n' "$*"; }

# Canonical email contract.
# shellcheck disable=SC1091
source lib/defaults.sh
[[ " ${_VW_DEFAULT_EMAIL_MODES[*]} " == *" direct "* ]] || fail "direct mode missing from defaults"
grep -q 'smtp|direct|host)' startup.sh || fail "startup direct-mode SMTP check missing"
! grep -q 'chmod -R 755.*logs' startup.sh || fail "recursive 0755 log widening remains"

# Truthful setup failure gates and secret-free summaries.
grep -q '_phase_failed 5 "Required UFW firewall configuration failed"' setup.sh || fail "UFW failure gate missing"
grep -q '_phase_failed 6 "Required automatic secrets configuration failed"' setup.sh || fail "automatic secrets failure gate missing"
summary="$(sed -n '/^show_post_install_summary() {/,/^}/p' setup.sh)"
[[ "$summary" == *"No credential values were written to terminal output"* ]] || fail "secret-free setup summary missing"
[[ "$summary" != *'cat "$age_key_file"'* ]] || fail "setup summary prints Age identity"
rotation_summary="$(sed -n '/^_display_rotated_age_key_summary() {/,/^}/p' utilities/key-rotate.sh)"
[[ "$rotation_summary" != *'cat '* ]] || fail "key rotation summary prints private material"
restore_summary="$(sed -n '/^_display_new_key() {/,/^}/p' utilities/restore-run.sh)"
[[ "$restore_summary" != *'priv_key_line'* ]] || fail "restore summary prints private material"
[[ "$restore_summary" != *'AGE-SECRET-KEY'* ]] || fail "restore summary contains private-key content"
[[ "$restore_summary" == *'No private key material was written to terminal output'* ]] || fail "restore secret-free notice missing"

# Protected setup handoff behavior with synthetic values only.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/date" <<'EOF_FAKE_DATE'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" && "${2:-}" == "+%Y%m%dT%H%M%SZ" ]]; then
  printf '%s\n' '20260724T000000Z'
else
  exec /usr/bin/date "$@"
fi
EOF_FAKE_DATE
chmod +x "$tmp/bin/date"
public_recipient="age1$(printf 'q%.0s' {1..58})"
cat > "$tmp/bin/age-keygen" <<EOF_FAKE_AGE
#!/usr/bin/env bash
printf '%s\n' '$public_recipient'
EOF_FAKE_AGE
chmod +x "$tmp/bin/age-keygen"
printf '%s\n' '# created: synthetic' 'AGE-SECRET-KEY-1SYNTHETIC-TEST-ONLY' > "$tmp/age.txt"
printf '%s' 'VW-SYNTHETIC-PLAINTEXT' > "$tmp/vw-plain"
printf '%s' 'VW-SYNTHETIC-HASH' > "$tmp/vw-hash"
printf '%s' 'CADDY-SYNTHETIC-PLAINTEXT' > "$tmp/caddy-plain"
printf '%s' 'admin CADDY-SYNTHETIC-HASH' > "$tmp/caddy-hash"
PATH="$tmp/bin:$PATH"
# shellcheck disable=SC1091
source lib/setup-credentials.sh
_setup_handoff_verify_argon2() { return 0; }
_setup_handoff_verify_bcrypt() { return 0; }
SETUP_CREDENTIALS_DIR="$tmp/recovery"
VW_HANDOFF_TEST_MODE=true
handoff_output="$(publish_setup_credentials \
  "$tmp/age.txt" "$tmp/vw-plain" "$tmp/vw-hash" \
  "$tmp/caddy-plain" "$tmp/caddy-hash" 2>"$tmp/handoff.err")" || fail "synthetic setup handoff failed"
[[ -z "$(cat "$tmp/handoff.err")" ]] || fail "setup handoff wrote unexpected stderr"
[[ "$handoff_output" == "$tmp/recovery/"vaultwarden-setup-credentials-*.txt ]] || fail "setup handoff output was not path-only"
handoff_file="$handoff_output"
[[ "$(stat -c '%a' "$tmp/recovery")" == "700" ]] || fail "setup handoff directory mode"
[[ "$(stat -c '%a' "$handoff_file")" == "600" ]] || fail "setup handoff file mode"
for marker in 'AGE-SECRET-KEY-1SYNTHETIC-TEST-ONLY' 'VW-SYNTHETIC-PLAINTEXT' 'CADDY-SYNTHETIC-PLAINTEXT'; do
  grep -Fq "$marker" "$handoff_file" || fail "setup handoff omitted synthetic marker"
  [[ "$handoff_output" != *"$marker"* ]] || fail "setup handoff printed synthetic marker"
done
[[ "$(grep -c '^│  0[123]  ' "$handoff_file")" == "3" ]] || fail "unexpected setup handoff section count"
! grep -Eq 'CLOUDFLARE|SMTP|PUSH|RECOVERY PROCEDURE' "$handoff_file" || fail "setup handoff contains out-of-scope inventory"
if publish_setup_credentials \
  "$tmp/age.txt" "$tmp/vw-plain" "$tmp/vw-hash" \
  "$tmp/caddy-plain" "$tmp/caddy-hash" >/dev/null 2>&1; then
  fail "setup handoff overwrote timestamp-colliding file"
fi

# Runtime permission behavior, including dry-run no-op.
mkdir -p "$tmp/logs/caddy" "$tmp/logs/postfix"
printf x > "$tmp/logs/caddy/access.log"
printf y > "$tmp/logs/postfix/mail.log"
chmod 0777 "$tmp/logs" "$tmp/logs/caddy" "$tmp/logs/postfix" "$tmp/logs/caddy/access.log" "$tmp/logs/postfix/mail.log"
log_error() { printf '%s\n' "$*" >&2; }
log_info() { :; }
_maybe_sudo() { "$@"; }
# shellcheck disable=SC1091
source lib/runtime-permissions.sh
enforce_runtime_log_permissions "$tmp/logs" "$(id -u)" "$(id -g)" false
while IFS= read -r -d '' path; do
  [[ "$(stat -c '%a' "$path")" == "750" ]] || fail "directory mode is not 0750: $path"
done < <(find "$tmp/logs" -type d -print0)
while IFS= read -r -d '' path; do
  [[ "$(stat -c '%a' "$path")" == "640" ]] || fail "file mode is not 0640: $path"
done < <(find "$tmp/logs" -type f -print0)
chmod 0777 "$tmp/logs/caddy/access.log"
enforce_runtime_log_permissions "$tmp/logs" "$(id -u)" "$(id -g)" true
[[ "$(stat -c '%a' "$tmp/logs/caddy/access.log")" == "777" ]] || fail "dry-run mutated fixture"

pass "production-readiness security/runtime regressions"
