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

# Interactive setup messaging must describe the protected credential handoff truthfully.
grep -Fq \
  'administrator credentials can be captured in the protected setup handoff' \
  setup.sh \
  || fail "protected setup-handoff comment missing"
grep -Fq \
  'administrator credentials are captured in the protected setup handoff' \
  setup.sh \
  || fail "protected setup-handoff information message missing"
grep -Fq \
  'Skipping secrets setup — no setup credential handoff will be created unless new credentials are generated.' \
  setup.sh \
  || fail "truthful setup skip notice missing"
! grep -Fq 'captured and shown in the final summary' setup.sh \
  || fail "stale terminal-summary comment remains"
! grep -Fq 'captured in the final summary' setup.sh \
  || fail "stale terminal-summary message remains"
! grep -Fq 'placeholder text in the summary' setup.sh \
  || fail "stale placeholder-summary message remains"
# Direct automatic secret setup must use protected capture and publication.
setup_secrets_help="$(./utilities/setup-secrets.sh configure --help)" \
  || fail "setup-secrets configure --help failed"
setup_secrets_help_normalized="$(
  printf '%s' "$setup_secrets_help" |
    tr '\n' ' ' |
    sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
)"
[[ "$setup_secrets_help_normalized" == *"protected setup credential handoff"* ]] \
  || fail "direct automatic setup help omits protected handoff"
[[ "$setup_secrets_help_normalized" == *"Generated administrator passwords are never printed"* ]] \
  || fail "direct automatic setup help omits terminal-output prohibition"
[[ "$setup_secrets_help_normalized" == *"exactly three credential groups"* ]] \
  || fail "direct automatic setup help omits the three-group contract"
[[ "$setup_secrets_help_normalized" == *"Publication failure makes the command fail"* ]] \
  || fail "direct automatic setup help omits publication failure behavior"

setup_secrets_source="$(cat utilities/setup-secrets.sh)"
[[ "$setup_secrets_source" == *'source "${PROJECT_ROOT}/lib/setup-credentials.sh"'* ]] \
  || fail "setup-secrets does not load protected handoff support"
[[ "$setup_secrets_source" == *'_ss_prepare_auto_handoff || return 1'* ]] \
  || fail "setup-secrets does not prepare protected automatic capture"
[[ "$setup_secrets_source" == *$'    done\n\n    _ss_prepare_auto_handoff || return 1\n\n    local AGE_KEY_FILE='* ]] \
  || fail "setup-secrets prepares automatic handoff before option parsing completes"
[[ "$setup_secrets_source" == *'_ss_publish_auto_handoff || return 1'* ]] \
  || fail "setup-secrets does not publish direct automatic handoff"
[[ "$setup_secrets_source" != *"scroll up to save the generated passwords"* ]] \
  || fail "setup-secrets still tells operators to recover passwords from terminal output"

auto_generator="$(
  sed -n \
    '/^auto_generate_secret_field() {/,/^_grk_sops_extract() {/p' \
    lib/secrets.sh
)"
[[ "$auto_generator" != *"/dev/tty"* ]] \
  || fail "automatic secret generator still writes plaintext to /dev/tty"
[[ "$auto_generator" != *"_print_secret_banner"* ]] \
  || fail "automatic secret generator still contains the plaintext banner"
[[ "$auto_generator" == *"requires protected capture and publication"* ]] \
  || fail "automatic administrator generation does not fail closed"

# Exercise capture preparation and file permissions without real credentials.
auto_handoff_helpers="$(
  sed -n \
    '/^    _ss_capture_path_count() {/,/^    _ss_show_help() {/p' \
    utilities/setup-secrets.sh |
    sed '$d; s/^    //'
)"
[[ -n "$auto_handoff_helpers" ]] \
  || fail "automatic handoff helper block is missing"
(
  eval "$auto_handoff_helpers"
  log_error() { :; }
  log_info() { :; }
  log_success() { :; }
  log_warn() { :; }

  helper_tmp="$(mktemp -d)"
  trap 'rm -rf "$helper_tmp"' EXIT
  chmod 0700 "$helper_tmp"

  # These values are consumed by the helper functions loaded through eval.
  # Exporting them makes that dynamic contract explicit to ShellCheck.
  export TMP_WORKDIR="$helper_tmp"
  export AUTO_MODE=true
  export QUIET_SUMMARY=false
  export AUTO_HANDOFF_OWNER=false
  export DRY_RUN=false
  unset VW_ADMIN_PLAIN_FILE VW_ADMIN_HASH_FILE
  unset CADDY_PLAIN_FILE CADDY_HASH_FILE

  _ss_prepare_auto_handoff || exit 1
  [[ "$AUTO_HANDOFF_OWNER" == "true" ]] || exit 1
  [[ "$QUIET_SUMMARY" == "true" ]] || exit 1

  synthetic_secret='VW_TEST_SECRET_DO_NOT_PRINT_276'
  _ss_write_capture \
    "$VW_ADMIN_PLAIN_FILE" \
    "$synthetic_secret" \
    "Vaultwarden administrator password" || exit 1
  [[ "$(stat -c '%a' "$VW_ADMIN_PLAIN_FILE")" == "600" ]] || exit 1
  [[ "$(cat "$VW_ADMIN_PLAIN_FILE")" == "$synthetic_secret" ]] || exit 1

  ln -s "$helper_tmp/elsewhere" "$helper_tmp/unsafe-link"
  ! _ss_write_capture \
    "$helper_tmp/unsafe-link" \
    "$synthetic_secret" \
    "unsafe test capture" || exit 1

  unset VW_ADMIN_HASH_FILE CADDY_PLAIN_FILE CADDY_HASH_FILE
  VW_ADMIN_PLAIN_FILE="$helper_tmp/partial"
  ! _ss_prepare_auto_handoff || exit 1
) || fail "protected automatic capture helper contract failed"

# Exercise the real direct command parser and orchestration under a PTY with
# deterministic synthetic values. The dependency and host-output boundaries are
# stubbed only inside a copied fixture; production source remains unchanged.
if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
(
  direct_auto_tmp="$(mktemp -d)"
  cleanup_direct_auto_test() {
    sudo -n rm -rf -- "$direct_auto_tmp" >/dev/null 2>&1 || true
  }
  trap cleanup_direct_auto_test EXIT INT TERM HUP

  direct_auto_fixture="$direct_auto_tmp/repo"
  mkdir -p "$direct_auto_fixture"
  tar \
    --exclude='./.git' \
    --exclude='./test-results' \
    --exclude='./vw_tmp.*' \
    -cf - . | tar -xf - -C "$direct_auto_fixture"

  direct_auto_bin="$direct_auto_tmp/bin"
  direct_auto_state="$direct_auto_tmp/state"
  direct_auto_success_dir="$direct_auto_tmp/recovery-success"
  direct_auto_failure_target="$direct_auto_tmp/recovery-not-a-directory"
  direct_auto_counter="$direct_auto_tmp/generator-counter"
  mkdir -p "$direct_auto_bin" "$direct_auto_state" "$direct_auto_success_dir"
  chmod 0700 "$direct_auto_state" "$direct_auto_success_dir"
  printf '0\n' > "$direct_auto_counter"
  chmod 0666 "$direct_auto_counter"
  printf 'publication must fail here\n' > "$direct_auto_failure_target"

  direct_auto_public="age1$(printf 'q%.0s' {1..58})"
  direct_auto_age_key="$direct_auto_tmp/age-key.txt"
  {
    printf '# AGE-SECRET-KEY-TEST-DO-NOT-LEAK\n'
    printf '%s\n' 'AGE-SECRET-KEY-1SYNTHETIC-DIRECT-AUTO-ONLY'
  } > "$direct_auto_age_key"
  chmod 0600 "$direct_auto_age_key"

  cat > "$direct_auto_fixture/.env" <<EOF_DIRECT_ENV
PROJECT_STATE_DIR=$direct_auto_state
SOPS_AGE_KEY_FILE=
EMAIL_MODE=api
EMAIL_PROVIDER=mailersend
PUSH_ENABLED=false
EOF_DIRECT_ENV
  chmod 0600 "$direct_auto_fixture/.env"
  cat > "$direct_auto_fixture/.sops.yaml" <<EOF_DIRECT_SOPS
creation_rules:
  - path_regex: '.*\.yaml$'
    age: "$direct_auto_public"
EOF_DIRECT_SOPS

  cat >> "$direct_auto_fixture/lib/config.sh" <<'EOF_DIRECT_CONFIG'
load_project_environment() {
  PROJECT_STATE_DIR="${VW_TEST_PROJECT_STATE_DIR:?}"
  SOPS_AGE_KEY_FILE="${VW_TEST_AGE_KEY_FILE:?}"
  SECRETS_FILE="${PROJECT_STATE_DIR}/secrets/secrets.yaml"
  export PROJECT_STATE_DIR SOPS_AGE_KEY_FILE SECRETS_FILE
}
EOF_DIRECT_CONFIG

  cat >> "$direct_auto_fixture/lib/operations.sh" <<'EOF_DIRECT_OPERATIONS'
operation_acquire() { return 0; }
operation_release() { return 0; }
operation_set_phase() { return 0; }
EOF_DIRECT_OPERATIONS

  cat >> "$direct_auto_fixture/lib/secrets.sh" <<'EOF_DIRECT_SECRETS'
schema_validate() { return 0; }
schema_keys() {
  printf '%s\n' admin_token admin_basic_auth_hash file_integrity_hmac_key
}
schema_collect_type() {
  case "$1" in
    file_integrity_hmac_key) printf '%s' auto ;;
    *) printf '%s' manual ;;
  esac
}
schema_field_safe() {
  case "$1:$2" in
    file_integrity_hmac_key:auto_fn) printf '%s' auto_generate_secret_field ;;
    *:label) printf '%s' "Synthetic test field" ;;
    *) printf '%s' "" ;;
  esac
}
generate_secure_string() {
  local requested="$1" next
  if [[ "$requested" == "64" ]]; then
    printf '%s' 'TEST-INTEGRITY-HMAC-NOT-A-HANDOFF-PASSWORD'
    return 0
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
ensure_sops_env() {
  export SOPS_AGE_KEY_FILE="${VW_TEST_AGE_KEY_FILE:?}"
  export SOPS_CONFIG="${PROJECT_ROOT}/.sops.yaml"
}
cleanup_secrets_environment() {
  unset SOPS_AGE_KEY_FILE SOPS_CONFIG
}
secure_secrets_file() { chmod 0600 "$1"; }
export_docker_secrets() { return 0; }
prepare_push_secret_placeholders() { return 0; }
EOF_DIRECT_SECRETS

  cat >> "$direct_auto_fixture/lib/setup-credentials.sh" <<'EOF_DIRECT_HANDOFF'
_setup_handoff_verify_argon2() { return 0; }
_setup_handoff_verify_bcrypt() { return 0; }
EOF_DIRECT_HANDOFF

  cat > "$direct_auto_bin/age-keygen" <<'EOF_DIRECT_AGE_KEYGEN'
#!/usr/bin/env bash
printf '%s\n' "${VW_TEST_PUBLIC_RECIPIENT:?}"
EOF_DIRECT_AGE_KEYGEN
  cat > "$direct_auto_bin/yq" <<'EOF_DIRECT_YQ'
#!/usr/bin/env bash
printf '%s\n' "${VW_TEST_PUBLIC_RECIPIENT:?}"
EOF_DIRECT_YQ
  cat > "$direct_auto_bin/sops" <<'EOF_DIRECT_SOPS_BIN'
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
  cat > "$direct_auto_bin/install" <<'EOF_DIRECT_INSTALL'
#!/usr/bin/env bash
if [[ " $* " == *" /run/vaultwarden-oci/secrets "* ]]; then
  exit 0
fi
exec "${VW_TEST_REAL_INSTALL:?}" "$@"
EOF_DIRECT_INSTALL
  for command_name in age jq htpasswd; do
    cat > "$direct_auto_bin/$command_name" <<'EOF_DIRECT_COMMAND'
#!/usr/bin/env bash
exit 0
EOF_DIRECT_COMMAND
  done
  chmod 0755 "$direct_auto_bin"/*

  direct_auto_pty_runner="$direct_auto_tmp/run-under-pty.py"
  cat > "$direct_auto_pty_runner" <<'PY_DIRECT_PTY'
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
  chmod 0755 "$direct_auto_pty_runner"

  assert_direct_auto_streams_are_secret_free() {
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

  assert_direct_auto_temps_are_clean() {
    ! find "$direct_auto_fixture" -maxdepth 1 -name 'vw_tmp.*' -print -quit | grep -q . \
      || fail "$1 left its plaintext/hash capture workspace behind"
    if [[ -d "$direct_auto_tmp/plaintext-stage" ]]; then
      ! find "$direct_auto_tmp/plaintext-stage" -type f -print -quit | grep -q . \
        || fail "$1 left its plaintext SOPS staging file behind"
    fi
  }

  run_direct_auto_case() {
    local label="$1" handoff_target="$2"
    direct_stdout="$direct_auto_tmp/$label.stdout"
    direct_stderr="$direct_auto_tmp/$label.stderr"
    direct_pty="$direct_auto_tmp/$label.pty"
    : > "$direct_stdout"
    : > "$direct_stderr"
    : > "$direct_pty"
    chmod 0666 "$direct_stdout" "$direct_stderr"
    printf '0\n' > "$direct_auto_counter"

    set +e
    python3 "$direct_auto_pty_runner" \
      "$direct_stdout" "$direct_stderr" "$direct_pty" \
      sudo -n /usr/bin/env \
        "PATH=$direct_auto_bin:$PATH" \
        "OFFLINE_AGE_RECIPIENT=$direct_auto_public" \
        "PROJECT_STATE_DIR=$direct_auto_state" \
        "SOPS_AGE_KEY_FILE=$direct_auto_age_key" \
        "SETUP_CREDENTIALS_DIR=$handoff_target" \
        "VW_HANDOFF_TEST_MODE=true" \
        "VW_TEST_AGE_KEY_FILE=$direct_auto_age_key" \
        "VW_TEST_COUNTER_FILE=$direct_auto_counter" \
        "VW_TEST_PROJECT_STATE_DIR=$direct_auto_state" \
        "VW_TEST_PUBLIC_RECIPIENT=$direct_auto_public" \
        "VW_TEST_REAL_INSTALL=$(command -v install)" \
        "VW_SETUP_SECRETS_TMP_DIR=$direct_auto_tmp/plaintext-stage" \
        bash -x "$direct_auto_fixture/utilities/setup-secrets.sh" configure --auto
    direct_rc=$?
    set -e
  }

  run_direct_auto_case success "$direct_auto_success_dir"
  (( direct_rc == 0 )) || fail "direct configure --auto failed in synthetic PTY fixture"
  grep -Fq '_cmd_configure --auto' "$direct_stderr" \
    || fail "direct automatic regression did not exercise an active command trace"
  assert_direct_auto_streams_are_secret_free "successful direct automatic setup"
  ! grep -Fq 'scroll up to save the generated passwords' \
    "$direct_stdout" "$direct_stderr" "$direct_pty" \
    || fail "direct automatic output contains obsolete scrollback guidance"

  handoff_file="$(
    sudo -n find "$direct_auto_success_dir" \
      -maxdepth 1 -type f -name 'vaultwarden-setup-credentials-*.txt' -print
  )"
  [[ -n "$handoff_file" ]] || fail "direct automatic setup did not publish a handoff"
  [[ "$(sudo -n stat -c '%a' "$direct_auto_success_dir")" == "700" ]] \
    || fail "direct automatic handoff directory mode is not 0700"
  [[ "$(sudo -n stat -c '%a' "$handoff_file")" == "600" ]] \
    || fail "direct automatic handoff file mode is not 0600"
  [[ "$(sudo -n grep -c '^│  0[123]  ' "$handoff_file")" == "3" ]] \
    || fail "direct automatic handoff does not contain exactly three groups"
  for marker in \
    'TEST-VW-PLAINTEXT-DO-NOT-LEAK' \
    'TEST-CADDY-PLAINTEXT-DO-NOT-LEAK' \
    'AGE-SECRET-KEY-TEST-DO-NOT-LEAK'; do
    sudo -n grep -Fq "$marker" "$handoff_file" \
      || fail "direct automatic handoff omitted $marker"
  done
  for heading in \
    'SOPS AGE IDENTITY' \
    'VAULTWARDEN ADMIN' \
    'CADDY ADMIN'; do
    sudo -n grep -Fq "$heading" "$handoff_file" \
      || fail "direct automatic handoff omitted $heading"
  done
  ! sudo -n grep -Eq 'BACKUP PASSPHRASE|file_integrity_hmac_key' "$handoff_file" \
    || fail "direct automatic handoff contains a non-canonical fourth credential"
  grep -Fq "Protected setup credential handoff created: $handoff_file" "$direct_stdout" \
    || fail "direct automatic setup did not report the protected handoff path"
  grep -Fq 'Expected protection: root:root, recovery directory mode 0700, file mode 0600.' "$direct_stdout" \
    || fail "direct automatic setup did not report ownership and permissions"
  grep -Fq 'Credential groups: SOPS Age identity, Vaultwarden administrator password, Caddy administrator password.' "$direct_stdout" \
    || fail "direct automatic setup did not report canonical credential names"
  grep -Fq 'No credential values were written to terminal output.' "$direct_stdout" \
    || fail "direct automatic setup omitted the no-values-printed statement"
  assert_direct_auto_temps_are_clean "direct automatic success"

  run_direct_auto_case publication-failure "$direct_auto_failure_target"
  (( direct_rc != 0 )) || fail "forced direct handoff-publication failure returned success"
  assert_direct_auto_streams_are_secret_free "failed direct automatic setup"
  ! grep -Fq 'Protected setup credential handoff created:' \
    "$direct_stdout" "$direct_stderr" "$direct_pty" \
    || fail "publication failure printed a protected-handoff success summary"
  ! grep -Fq 'No credential values were written to terminal output.' \
    "$direct_stdout" "$direct_stderr" "$direct_pty" \
    || fail "publication failure printed the final completion statement"
  ! grep -Fq 'Secrets Setup Complete!' \
    "$direct_stdout" "$direct_stderr" "$direct_pty" \
    || fail "publication failure printed the generic success summary"
  assert_direct_auto_temps_are_clean "direct automatic failure"
) || fail "behavioral direct automatic protected-handoff contract failed"
else
  printf 'SKIP direct automatic PTY behavior: passwordless sudo unavailable\n'
fi

rotation_summary="$(sed -n '/^_display_rotated_age_key_summary() {/,/^}/p' utilities/key-rotate.sh)"
[[ "$rotation_summary" != *'cat '* ]] || fail "key rotation summary prints private material"
restore_summary="$(sed -n '/^_display_new_key() {/,/^}/p' utilities/restore-run.sh)"
[[ "$restore_summary" != *'priv_key_line'* ]] || fail "restore summary prints private material"
[[ "$restore_summary" != *'AGE-SECRET-KEY'* ]] || fail "restore summary contains private-key content"
[[ "$restore_summary" == *'No private key material was written to terminal output'* ]] || fail "restore secret-free notice missing"

# Recovery-export help must describe persistent publication and conditional cleanup.
recovery_help="$(./utilities/secrets-export-recovery-kit.sh --help)" \
  || fail "recovery-export --help failed"

recovery_help_normalized="$(
  printf '%s' "$recovery_help" |
    tr '\n' ' ' |
    sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
)"
[[ "$recovery_help_normalized" == *"protected plaintext recovery document"* ]] \
  || fail "recovery help omits protected plaintext document contract"
[[ "$recovery_help_normalized" == *"persistent"* ]] \
  || fail "recovery help omits persistent final-output contract"
[[ "$recovery_help_normalized" == *"recovery directory /root/vaultwarden-recovery"* ]] \
  || fail "recovery help omits final recovery directory"
[[ "$recovery_help_normalized" == *"root:root with mode 0700"* ]] \
  || fail "recovery help omits directory ownership/mode"
[[ "$recovery_help_normalized" == *"root:root with mode 0600"* ]] \
  || fail "recovery help omits document ownership/mode"
[[ "$recovery_help_normalized" == *"When at(1) is available"* ]] \
  || fail "recovery help omits conditional at(1) availability"
[[ "$recovery_help_normalized" == *"accepts the cleanup job"* ]] \
  || fail "recovery help omits successful scheduling condition"
[[ "$recovery_help_normalized" == *"secure removal is"*"scheduled after 30 minutes"* ]] \
  || fail "recovery help omits conditional 30-minute cleanup"
[[ "$recovery_help_normalized" == *"If cleanup cannot be scheduled"* ]] \
  || fail "recovery help omits cleanup scheduling failure condition"
[[ "$recovery_help_normalized" == *"must securely remove the document manually"* ]] \
  || fail "recovery help does not require manual secure removal"
[[ "$recovery_help_normalized" == *"explicit"*"manual secure-removal instruction"* ]] \
  || fail "recovery help omits manual secure-removal instruction"
[[ "$recovery_help_normalized" == *"Temporary decryption may use /dev/shm"* ]] \
  || fail "recovery help omits temporary /dev/shm distinction"
[[ "$recovery_help_normalized" == *"document remains under /root/vaultwarden-recovery"* ]] \
  || fail "recovery help confuses temporary and final locations"
[[ "$recovery_help_normalized" == *"Recovery content is"*"never printed to terminal output"* ]] \
  || fail "recovery help omits terminal-output prohibition"
[[ "$recovery_help_normalized" != *"written to a tmpfs-backed directory"* ]] \
  || fail "recovery help still claims tmpfs-backed final output"
[[ "$recovery_help_normalized" != *"/dev/shm) with mode 0600"* ]] \
  || fail "recovery help still presents /dev/shm as final output"
[[ "$recovery_help_normalized" != *"auto-delete"* ]] \
  || fail "recovery help still promises unconditional deletion"
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
! grep -Fq '04  BACKUP PASSPHRASE' "$handoff_file" || fail "retired backup-passphrase section returned"
! grep -Fq 'BACKUP_PLAIN_FILE' setup.sh || fail "retired setup backup capture returned"
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
