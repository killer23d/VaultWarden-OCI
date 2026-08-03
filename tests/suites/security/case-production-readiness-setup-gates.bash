#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS %s\n' "$*"; }

# A non-executable sourced library must not break help/version paths.
[[ ! -x lib/setup-credentials.sh ]] || fail "setup-credentials library should not be executable"
version_output="$(./setup.sh --version 2>&1)" || fail "setup.sh --version failed: $version_output"
[[ "$version_output" == VaultWarden-OCI* ]] || fail "setup.sh --version output is unexpected"

# Bootstrap dependency validation must include every sourced library and must
# not contain a bare execution of a library path.
for library in \
  lib/log.sh lib/validate.sh lib/config.sh lib/common.sh lib/operations.sh \
  lib/crypto.sh lib/docker.sh lib/backup-utils.sh lib/secrets.sh \
  lib/setup-credentials.sh lib/defaults.sh lib/storage.sh; do
  grep -Fq "\"$library\"" setup.sh || fail "REQUIRED_LIBS missing: $library"
done
if grep -Eq '^[[:space:]]*"\$\{SCRIPT_DIR\}/lib/(setup-credentials|storage)\.sh"[[:space:]]*$' setup.sh; then
  fail "setup.sh contains a bare library execution"
fi

# The orchestration cases run only when passwordless sudo is available. GitHub's
# Ubuntu runner provides it; local non-sudo environments still retain the static
# and version-path assertions above.
if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; then
  printf 'SKIP behavioral setup orchestration: passwordless sudo unavailable\n'
  pass "setup bootstrap loading contract"
  exit 0
fi

TMP="$(mktemp -d)"
cleanup() { sudo -n rm -rf -- "$TMP" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM HUP
FIXTURE="$TMP/repo"
mkdir -p "$FIXTURE"
tar --exclude='./.git' --exclude='./test-results' -cf - . | tar -xf - -C "$FIXTURE"

# Setup-gates fixture intentionally bypasses input-format validation. Domain and
# email validation have separate coverage; this case must reach the phase
# orchestration so it can prove required UFW and automatic-secrets failures stop
# setup before credential publication.
mkdir -p "$FIXTURE/lib"
cat > "$FIXTURE/lib/validate.sh" <<'EOF_VALIDATE'
validate_domain() { return 0; }
validate_email() { return 0; }
EOF_VALIDATE

INVOCATIONS="$TMP/invocations.log"
: > "$INVOCATIONS"
chmod 0666 "$INVOCATIONS"

cat > "$TMP/utility-stub" <<'EOF_STUB'
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
exit 0
EOF_STUB
chmod 0755 "$TMP/utility-stub"
for utility in \
  setup-system.sh setup-storage.sh setup-env.sh setup-secrets.sh \
  setup-firewall.sh setup-systemd.sh setup-crowdsec.sh uninstall-vaultwarden.sh; do
  cp "$TMP/utility-stub" "$FIXTURE/utilities/$utility"
  chmod 0755 "$FIXTURE/utilities/$utility"
done

run_setup_case() {
  local label="$1" fail_ufw="$2" fail_secrets="$3" output rc
  : > "$INVOCATIONS"
  rm -rf "$TMP/recovery"
  set +e
  output="$(
    sudo -n env \
      VW_TEST_INVOCATION_LOG="$INVOCATIONS" \
      VW_TEST_FAIL_UFW="$fail_ufw" \
      VW_TEST_FAIL_SECRETS="$fail_secrets" \
      SETUP_CREDENTIALS_DIR="$TMP/recovery" \
      ENTROPY_THRESHOLD=0 \
      bash "$FIXTURE/setup.sh" install \
        --domain vault.example.com \
        --email admin@example.com \
        --auto --skip-deps 2>&1
  )"
  rc=$?
  set -e
  (( rc != 0 )) || fail "$label unexpectedly returned success"
  [[ "$output" != *"SETUP CREDENTIALS SAVED"* ]] || fail "$label printed final credential success"
  [[ "$output" != *"Setup completed without printing secret values"* ]] || fail "$label printed setup completion"
  [[ ! -e "$TMP/recovery" ]] || {
    ! find "$TMP/recovery" -type f -name 'vaultwarden-setup-credentials-*' -print -quit | grep -q . \
      || fail "$label published a setup credential handoff"
  }
  printf '%s' "$output"
}

ufw_output="$(run_setup_case "UFW failure" 1 0)"
[[ "$ufw_output" == *"Phase 5"* ]] || fail "UFW failure did not identify phase 5"
! grep -q 'setup-firewall.sh:--phase iptables' "$INVOCATIONS" \
  || fail "iptables phase ran after required UFW failure"
! grep -q 'setup-secrets.sh:configure' "$INVOCATIONS" \
  || fail "secrets configuration ran after required UFW failure"

secrets_output="$(run_setup_case "automatic secrets failure" 0 1)"
[[ "$secrets_output" == *"Phase 6"* ]] || fail "automatic secrets failure did not identify phase 6"
grep -q 'setup-secrets.sh:configure' "$INVOCATIONS" \
  || fail "automatic secrets configure stub was not invoked"

# A full automatic dry-run reaches the secrets route but never allocates the
# top-level plaintext credential workspace or publishes a handoff.
dry_tmp="$TMP/dry-run-tmp"
mkdir -p "$dry_tmp"
: > "$INVOCATIONS"
rm -rf "$TMP/recovery"
set +e
dry_output="$(
  sudo -n env \
    TMPDIR="$dry_tmp" \
    VW_TEST_INVOCATION_LOG="$INVOCATIONS" \
    VW_TEST_FAIL_UFW=0 \
    VW_TEST_FAIL_SECRETS=0 \
    SETUP_CREDENTIALS_DIR="$TMP/recovery" \
    ENTROPY_THRESHOLD=0 \
    bash "$FIXTURE/setup.sh" install \
      --domain vault.example.com \
      --email admin@example.com \
      --auto --skip-deps --dry-run 2>&1
)"
dry_rc=$?
set -e
(( dry_rc == 0 )) || fail "automatic setup dry-run failed: $dry_output"
grep -q 'setup-secrets.sh:configure .*--dry-run' "$INVOCATIONS" \
  || fail "automatic setup dry-run did not delegate dry-run to secrets configuration"
! find "$dry_tmp" -mindepth 1 -maxdepth 1 -name 'vw_setup.*' -print -quit | grep -q . \
  || fail "automatic setup dry-run created a sensitive workspace"
[[ ! -e "$TMP/recovery" ]] || {
  ! find "$TMP/recovery" -type f -name 'vaultwarden-setup-credentials-*' -print -quit | grep -q . \
    || fail "automatic setup dry-run published a credential handoff"
}

pass "behavioral setup failure gates and bootstrap loading"
