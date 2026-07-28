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
[[ "$setup_secrets_source" == *'declare -ga SETUP_SECRETS_CLEANUP_ACTIONS=()'* ]] \
  || fail "setup-secrets cleanup actions are not script-scoped"
[[ "$setup_secrets_source" == *'declare -gA SETUP_SECRETS_COLLECTED_SECRETS=()'* ]] \
  || fail "setup-secrets collected secrets are not script-scoped"
[[ "$setup_secrets_source" != *'local CLEANUP_ACTIONS=()'* ]] \
  || fail "setup-secrets still uses function-local cleanup state"
[[ "$setup_secrets_source" != *"trap '_ss_perform_cleanup' RETURN"* ]] \
  || fail "setup-secrets still installs the unsafe RETURN cleanup trap"
[[ "$setup_secrets_source" == *'_setup_secrets_cleanup_all "$original_status"'* ]] \
  || fail "setup-secrets signal/exit finalizer does not pass the original status"
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
# Exercise the script-scoped cleanup state directly with synthetic files.
cleanup_lifecycle_helpers="$(
  sed -n \
    '/^# Secret cleanup lifecycle is script-scoped/,/^# End secret cleanup lifecycle\./p' \
    utilities/setup-secrets.sh
)"
[[ -n "$cleanup_lifecycle_helpers" ]] || fail "script-scoped cleanup helper block is missing"
(
  cleanup_root="$(mktemp -d)"
  trap 'rm -rf -- "$cleanup_root"' EXIT
  export PROJECT_ROOT="$cleanup_root"
  export TMP_WORKDIR="$cleanup_root/vw_tmp.cleanup-contract"
  mkdir -p "$TMP_WORKDIR"
  cleanup_secrets_environment() { return 0; }
  log_warn() { :; }
  eval "$cleanup_lifecycle_helpers"
  _setup_secrets_cleanup_begin
  printf '%s' 'SYNTHETIC-CLEANUP-SECRET-ONE' > "$TMP_WORKDIR/secret one"
  printf '%s' 'SYNTHETIC-CLEANUP-SECRET-TWO' > "$TMP_WORKDIR/secret-two"
  _ss_register_cleanup "$TMP_WORKDIR/secret one"
  _ss_register_cleanup "rm -f $TMP_WORKDIR/secret-two"
  _ss_register_cleanup "/etc/passwd"
  SETUP_SECRETS_COLLECTED_SECRETS["test"]='SYNTHETIC-COLLECTED-SECRET'
  set +e
  _ss_perform_cleanup 37
  cleanup_rc=$?
  set -e
  (( cleanup_rc == 37 )) || exit 1
  [[ ! -e "$TMP_WORKDIR/secret one" ]] || exit 1
  [[ ! -e "$TMP_WORKDIR/secret-two" ]] || exit 1
  [[ ! -d "$TMP_WORKDIR" ]] || exit 1
  [[ ${#SETUP_SECRETS_CLEANUP_ACTIONS[@]} -eq 0 ]] || exit 1
  [[ ${#SETUP_SECRETS_COLLECTED_SECRETS[@]} -eq 0 ]] || exit 1
  set +e
  _ss_perform_cleanup 23
  repeated_rc=$?
  set -e
  (( repeated_rc == 23 )) || exit 1
) || fail "script-scoped cleanup idempotence and status preservation failed"
for signal_status in 130 143; do
  signal_root="$(mktemp -d)"
  set +e
  (
    export PROJECT_ROOT="$signal_root"
    export TMP_WORKDIR="$signal_root/vw_tmp.signal-contract"
    mkdir -p "$TMP_WORKDIR"
    printf '%s' 'SYNTHETIC-SIGNAL-SECRET' > "$TMP_WORKDIR/signal-secret"
    cleanup_secrets_environment() { return 0; }
    log_warn() { :; }
    eval "$cleanup_lifecycle_helpers"
    _setup_secrets_cleanup_begin
    _ss_register_cleanup "$TMP_WORKDIR/signal-secret"
    case "$signal_status" in
      130)
        trap '_setup_secrets_on_signal 130' INT
        kill -INT "$BASHPID"
        ;;
      143)
        trap '_setup_secrets_on_signal 143' TERM
        kill -TERM "$BASHPID"
        ;;
    esac
    exit 99
  )
  observed_signal_status=$?
  set -e
  [[ ! -e "$signal_root/vw_tmp.signal-contract/signal-secret" ]] \
    || fail "signal cleanup left a plaintext file for status $signal_status"
  [[ ! -d "$signal_root/vw_tmp.signal-contract" ]] \
    || fail "signal cleanup left its workspace for status $signal_status"
  rm -rf -- "$signal_root"
  (( observed_signal_status == signal_status )) \
    || fail "cleanup signal handler did not preserve status $signal_status"
done
pass "script-scoped setup-secrets cleanup lifecycle"

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
    if sudo -n test -d "$direct_auto_tmp/plaintext-stage"; then
      ! sudo -n find "$direct_auto_tmp/plaintext-stage" -type f -print -quit | grep -q . \
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
  pass "direct automatic setup PTY no-leak regression"
else
  if [[ "${CI:-false}" == "true" || "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    fail "mandatory direct automatic PTY regression requires passwordless sudo in CI"
  fi
  printf 'SKIP direct automatic PTY behavior: passwordless sudo unavailable\n'
fi

rotation_summary="$(sed -n '/^_display_rotated_age_key_summary() {/,/^}/p' utilities/key-rotate.sh)"
[[ "$rotation_summary" != *'cat '* ]] || fail "key rotation summary prints private material"
restore_summary="$(sed -n '/^_display_new_key() {/,/^}/p' utilities/restore-run.sh)"
[[ "$restore_summary" != *'priv_key_line'* ]] || fail "restore summary prints private material"
[[ "$restore_summary" != *'AGE-SECRET-KEY'* ]] || fail "restore summary contains private-key content"
[[ "$restore_summary" == *'No private key material was written to terminal output'* ]] || fail "restore secret-free notice missing"

# Recovery-export help must describe fail-closed transient cleanup truthfully.
recovery_help="$(./utilities/secrets-export-recovery-kit.sh --help)" \
  || fail "recovery-export --help failed"

recovery_help_normalized="$(
  printf '%s' "$recovery_help" |
    tr '\n' ' ' |
    sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
)"
[[ "$recovery_help_normalized" == *"protected plaintext recovery document"* ]] \
  || fail "recovery help omits protected plaintext document contract"
[[ "$recovery_help_normalized" == *"recovery directory /root/vaultwarden-recovery"* ]] \
  || fail "recovery help omits final recovery directory"
[[ "$recovery_help_normalized" == *"root:root with mode 0700"* ]] \
  || fail "recovery help omits directory ownership/mode"
[[ "$recovery_help_normalized" == *"root:root with mode 0600"* ]] \
  || fail "recovery help omits document ownership/mode"
[[ "$recovery_help_normalized" == *"systemd transient timer"*"approximately 30 minutes"* ]] \
  || fail "recovery help omits approximate primary 30-minute systemd timer"
[[ "$recovery_help_normalized" == *"at(1) is an optional fallback"* ]] \
  || fail "recovery help does not describe at as optional fallback"
[[ "$recovery_help_normalized" == *"If neither scheduler accepts cleanup, export fails closed and removes the plaintext document"* ]] \
  || fail "recovery help omits fail-closed scheduling behavior"
[[ "$recovery_help_normalized" == *"Successful encrypted email delivery removes the local plaintext copy immediately"* ]] \
  || fail "recovery help omits immediate post-email removal"
[[ "$recovery_help_normalized" == *"Declined or failed email leaves the protected copy temporarily"* ]] \
  || fail "recovery help omits declined/failed email temporary-retention wording"
[[ "$recovery_help_normalized" == *"next routine maintenance run removes eligible leftovers"*"at least 30 minutes old"* ]] \
  || fail "recovery help omits routine-maintenance fallback cleanup"
[[ "$recovery_help_normalized" == *"Best-effort overwrite and unlink. Physical erasure is not guaranteed"* ]] \
  || fail "recovery help overstates physical erasure"
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
[[ "$recovery_help_normalized" != *"remove the document manually"* ]] \
  || fail "recovery help still leaves scheduler failure to manual cleanup"

# Python bcrypt verification must support the Caddy variants without exposing
# plaintext through process arguments, output, tracing, or a PTY. Ubuntu CI
# exercises the real python3-bcrypt module; the portable local fallback exposes
# the same checkpw API and delegates test-vector checking to htpasswd via stdin.
(
  set -euo pipefail
  bcrypt_tmp="$(mktemp -d)"
  trap 'rm -rf "$bcrypt_tmp"' EXIT
  bcrypt_plain='VWOCI-BCRYPT-TEST-PASSWORD'
  bcrypt_hash_2y='$2y$04$66zyrez.FjG6EOPvlQcPLup7..7yC4CwbAyV6v/8E1t1J14u4RskC'
  bcrypt_hash_2a="${bcrypt_hash_2y/\$2y\$/\$2a\$}"
  bcrypt_hash_2b="${bcrypt_hash_2y/\$2y\$/\$2b\$}"
  real_python="$(command -v python3)"
  module_path=""

  if ! "$real_python" -c 'import bcrypt' >/dev/null 2>&1; then
    command -v htpasswd >/dev/null 2>&1 \
      || fail "bcrypt portability fixture requires htpasswd"
    module_path="$bcrypt_tmp/python-module"
    mkdir -p "$module_path"
    cat > "$module_path/bcrypt.py" <<'PY_BCRYPT_FIXTURE'
import os
import subprocess
import tempfile


def checkpw(password, encoded):
    normalized = encoded
    if normalized.startswith(b"$2b$"):
        normalized = b"$2y$" + normalized[4:]
    fd, path = tempfile.mkstemp()
    try:
        os.write(fd, b"admin:" + normalized + b"\n")
        os.close(fd)
        result = subprocess.run(
            ["htpasswd", "-vi", path, "admin"],
            input=password + b"\n",
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return result.returncode == 0
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
PY_BCRYPT_FIXTURE
  fi

  mkdir -p "$bcrypt_tmp/bin"
cat > "$bcrypt_tmp/bin/python3" <<'EOF_BCRYPT_PYTHON_WRAPPER'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${VW_BCRYPT_ARGV_LOG:?}"
/usr/bin/env > "${VW_BCRYPT_ENV_LOG:?}"
exec "${VW_BCRYPT_REAL_PYTHON:?}" "$@"
EOF_BCRYPT_PYTHON_WRAPPER
  chmod +x "$bcrypt_tmp/bin/python3"
  export VW_BCRYPT_ARGV_LOG="$bcrypt_tmp/python.argv"
  export VW_BCRYPT_ENV_LOG="$bcrypt_tmp/python.env"
  export VW_BCRYPT_REAL_PYTHON="$real_python"

  # shellcheck disable=SC1091
  source lib/setup-credentials.sh

  verify_bcrypt_vector() {
    local encoded="$1" plaintext="$2"
    PATH="$bcrypt_tmp/bin:$PATH" PYTHONPATH="$module_path" \
      _setup_handoff_verify_bcrypt "$encoded" 3<<<"$plaintext"
  }

  for bcrypt_hash in "$bcrypt_hash_2a" "$bcrypt_hash_2b" "$bcrypt_hash_2y"; do
    : > "$bcrypt_tmp/verify.out"
    : > "$bcrypt_tmp/verify.err"
    verify_bcrypt_vector "$bcrypt_hash" "$bcrypt_plain" \
      >"$bcrypt_tmp/verify.out" 2>"$bcrypt_tmp/verify.err" \
      || fail "correct bcrypt vector was rejected: ${bcrypt_hash:0:4}"
    [[ ! -s "$bcrypt_tmp/verify.out" && ! -s "$bcrypt_tmp/verify.err" ]] \
      || fail "bcrypt verification wrote to stdout or stderr"
    ! grep -Fq "$bcrypt_plain" "$VW_BCRYPT_ARGV_LOG" \
      || fail "bcrypt plaintext entered Python argv"
    ! grep -Fq "$bcrypt_plain" "$VW_BCRYPT_ENV_LOG" \
      || fail "bcrypt plaintext entered the Python environment"
  done

  if verify_bcrypt_vector "$bcrypt_hash_2y" 'WRONG-BCRYPT-PASSWORD' >/dev/null 2>&1; then
    fail "wrong bcrypt password was accepted"
  fi
  if verify_bcrypt_vector "$bcrypt_hash_2y" "" >/dev/null 2>&1; then
    fail "empty bcrypt password was accepted"
  fi
  if verify_bcrypt_vector "${bcrypt_hash_2y:0:40}" "$bcrypt_plain" >/dev/null 2>&1; then
    fail "truncated bcrypt hash was accepted"
  fi
  if verify_bcrypt_vector 'not-a-bcrypt-hash' "$bcrypt_plain" \
      >"$bcrypt_tmp/malformed.out" 2>"$bcrypt_tmp/malformed.err"; then
    fail "malformed bcrypt hash was accepted"
  fi
  ! grep -Fq 'Traceback' "$bcrypt_tmp/malformed.err" \
    || fail "malformed bcrypt hash emitted a Python traceback"

  : > "$bcrypt_tmp/xtrace"
  (
    set -x
    PATH="$bcrypt_tmp/bin:$PATH" PYTHONPATH="$module_path" \
      _setup_handoff_verify_bcrypt "$bcrypt_hash_2y" 3<<<"$bcrypt_plain"
  ) >"$bcrypt_tmp/xtrace.out" 2>"$bcrypt_tmp/xtrace" \
    || fail "bcrypt verification failed under xtrace"
  ! grep -Fq "$bcrypt_plain" "$bcrypt_tmp/xtrace" \
    || fail "bcrypt plaintext leaked through xtrace"

  printf '%s' "$bcrypt_plain" > "$bcrypt_tmp/plaintext"
  chmod 0600 "$bcrypt_tmp/plaintext"
  cat > "$bcrypt_tmp/pty-probe.sh" <<'EOF_BCRYPT_PTY_PROBE'
#!/usr/bin/env bash
set -euo pipefail
source "${VW_BCRYPT_PROJECT_ROOT:?}/lib/setup-credentials.sh"
plain="$(<"${VW_BCRYPT_PLAIN_FILE:?}")"
_setup_handoff_verify_bcrypt "${VW_BCRYPT_HASH:?}" 3<<<"$plain"
EOF_BCRYPT_PTY_PROBE
  chmod +x "$bcrypt_tmp/pty-probe.sh"
  cat > "$bcrypt_tmp/pty-runner.py" <<'PY_BCRYPT_PTY_RUNNER'
import os
import pty
import sys

output_path = sys.argv[1]
command = sys.argv[2:]
pid, master = pty.fork()
if pid == 0:
    os.execvp(command[0], command)
with open(output_path, "wb") as output:
    while True:
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        output.write(chunk)
os.close(master)
_, status = os.waitpid(pid, 0)
raise SystemExit(os.waitstatus_to_exitcode(status))
PY_BCRYPT_PTY_RUNNER
  env \
    "PATH=$bcrypt_tmp/bin:$PATH" \
    "PYTHONPATH=$module_path" \
    "VW_BCRYPT_ARGV_LOG=$VW_BCRYPT_ARGV_LOG" \
    "VW_BCRYPT_ENV_LOG=$VW_BCRYPT_ENV_LOG" \
    "VW_BCRYPT_HASH=$bcrypt_hash_2y" \
    "VW_BCRYPT_PLAIN_FILE=$bcrypt_tmp/plaintext" \
    "VW_BCRYPT_PROJECT_ROOT=$ROOT" \
    "VW_BCRYPT_REAL_PYTHON=$real_python" \
    python3 "$bcrypt_tmp/pty-runner.py" "$bcrypt_tmp/pty.out" \
    bash "$bcrypt_tmp/pty-probe.sh" \
    || fail "bcrypt verification failed in synthetic PTY"
  ! grep -Fq "$bcrypt_plain" "$bcrypt_tmp/pty.out" \
    || fail "bcrypt plaintext leaked to PTY output"
  ! grep -Fq "$bcrypt_plain" "$VW_BCRYPT_ARGV_LOG" \
    || fail "bcrypt plaintext entered Python argv during PTY verification"
  ! grep -Fq "$bcrypt_plain" "$VW_BCRYPT_ENV_LOG" \
    || fail "bcrypt plaintext entered the Python environment during PTY verification"
) || fail "behavioral python3-bcrypt verification contract failed"

# Recovery cleanup uses mocked schedulers and delivery outcomes. No real timer
# is created and no email is sent.
(
  set -euo pipefail
  recovery_tmp="$(mktemp -d)"
  trap 'rm -rf "$recovery_tmp"' EXIT
  export SECRETS_FILE="$recovery_tmp/secrets.yaml"
  # shellcheck disable=SC1091
  source lib/secrets.sh

  mkdir -p "$recovery_tmp/bin"
  cat > "$recovery_tmp/bin/systemd-run" <<'EOF_SYSTEMD_RUN_MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'ARG=%q\n' "$@" >> "${VW_SYSTEMD_LOG:?}"
case "${VW_SYSTEMD_MODE:-success}" in
  success) exit 0 ;;
  fail) exit 1 ;;
  execute|execute-twice)
    while (( $# > 0 )) && [[ "$1" != "/bin/sh" ]]; do shift; done
    (( $# > 0 )) || exit 1
    "$@"
    [[ "${VW_SYSTEMD_MODE}" != "execute-twice" ]] || "$@"
    ;;
  *) exit 2 ;;
esac
EOF_SYSTEMD_RUN_MOCK
cat > "$recovery_tmp/bin/at" <<'EOF_AT_MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'ARG=%q\n' "$@" >> "${VW_AT_LOG:?}"
job="$(cat)"
printf 'JOB=%s\n' "$job" >> "${VW_AT_LOG:?}"
case "${VW_AT_MODE:-success}" in
  success) exit 0 ;;
  fail) exit 1 ;;
  execute) /bin/sh -c "$job" ;;
  *) exit 2 ;;
esac
EOF_AT_MOCK
  chmod +x "$recovery_tmp/bin/systemd-run" "$recovery_tmp/bin/at"
  export VW_SYSTEMD_LOG="$recovery_tmp/systemd.log"
  export VW_AT_LOG="$recovery_tmp/at.log"
  scheduler_path="$recovery_tmp/bin:$PATH"

  make_recovery_fixture() {
    local path="$1"
    printf '%s\n' 'RECOVERY-CONTENT-DO-NOT-LEAK' > "$path"
    chmod 0600 "$path"
  }

  systemd_file="$recovery_tmp/systemd-success.txt"
  make_recovery_fixture "$systemd_file"
  : > "$VW_SYSTEMD_LOG"
  : > "$VW_AT_LOG"
  VW_SYSTEMD_MODE=success VW_AT_MODE=success PATH="$scheduler_path" \
    _schedule_recovery_cleanup "$systemd_file" \
    || fail "systemd cleanup scheduling success was rejected"
  [[ "${_RECOVERY_CLEANUP_SCHEDULER:-}" == "systemd" ]] \
    || fail "systemd scheduler result was not recorded"
  grep -Fq 'ARG=--on-active=30m' "$VW_SYSTEMD_LOG" \
    || fail "systemd scheduler did not receive the default 30-minute delay"
  [[ ! -s "$VW_AT_LOG" ]] || fail "at fallback ran after systemd success"

  fallback_file="$recovery_tmp/at-fallback.txt"
  make_recovery_fixture "$fallback_file"
  : > "$VW_SYSTEMD_LOG"
  : > "$VW_AT_LOG"
  VW_SYSTEMD_MODE=fail VW_AT_MODE=success PATH="$scheduler_path" \
    _schedule_recovery_cleanup "$fallback_file" \
    || fail "at fallback success was rejected"
  [[ "${_RECOVERY_CLEANUP_SCHEDULER:-}" == "at" ]] \
    || fail "at fallback result was not recorded"
  [[ -s "$VW_SYSTEMD_LOG" && -s "$VW_AT_LOG" ]] \
    || fail "at fallback did not follow a systemd failure"

  at_injection_file="$recovery_tmp/at recovery ' ; touch at-injected ;.txt"
  make_recovery_fixture "$at_injection_file"
  : > "$VW_SYSTEMD_LOG"
  : > "$VW_AT_LOG"
  (
    cd "$recovery_tmp"
    VW_SYSTEMD_MODE=fail VW_AT_MODE=execute PATH="$scheduler_path" \
      _schedule_recovery_cleanup "$at_injection_file"
  ) || fail "at fallback cleanup failed for quoted metacharacter path"
  [[ ! -e "$at_injection_file" && ! -e "$recovery_tmp/at-injected" ]] \
    || fail "at fallback path handling failed or injected a command"

  failed_file="$recovery_tmp/both-fail.txt"
  make_recovery_fixture "$failed_file"
  if VW_SYSTEMD_MODE=fail VW_AT_MODE=fail PATH="$scheduler_path" \
      _schedule_recovery_cleanup "$failed_file" >/dev/null 2>&1; then
    fail "both failed schedulers returned success"
  fi

  missing_file="$recovery_tmp/both-missing.txt"
  make_recovery_fixture "$missing_file"
  mkdir -p "$recovery_tmp/no-schedulers"
  ln -s "$(command -v realpath)" "$recovery_tmp/no-schedulers/realpath"
  ln -s "$(command -v date)" "$recovery_tmp/no-schedulers/date"
  if PATH="$recovery_tmp/no-schedulers" \
      _schedule_recovery_cleanup "$missing_file" >/dev/null 2>&1; then
    fail "missing schedulers returned success"
  fi

  symlink_target="$recovery_tmp/symlink-target.txt"
  make_recovery_fixture "$symlink_target"
  ln -s "$symlink_target" "$recovery_tmp/symlink-recovery.txt"
  : > "$VW_SYSTEMD_LOG"
  if VW_SYSTEMD_MODE=success PATH="$scheduler_path" \
      _schedule_recovery_cleanup "$recovery_tmp/symlink-recovery.txt" >/dev/null 2>&1; then
    fail "symlink recovery path was scheduled"
  fi
  [[ ! -s "$VW_SYSTEMD_LOG" && -f "$symlink_target" ]] \
    || fail "symlink rejection reached the scheduler or changed its target"

  injection_file="$recovery_tmp/recovery ; touch injected-marker ;.txt"
  make_recovery_fixture "$injection_file"
  : > "$VW_SYSTEMD_LOG"
  (
    cd "$recovery_tmp"
    VW_SYSTEMD_MODE=execute-twice VW_AT_MODE=fail PATH="$scheduler_path" \
      _schedule_recovery_cleanup "$injection_file"
  ) || fail "detached cleanup command failed for metacharacter path"
  [[ ! -e "$injection_file" ]] \
    || fail "detached cleanup did not remove the recovery file"
  [[ ! -e "$recovery_tmp/injected-marker" ]] \
    || fail "recovery path injected a scheduler command"
  ! grep -Fq 'RECOVERY-CONTENT-DO-NOT-LEAK' \
      "$VW_SYSTEMD_LOG" "$VW_AT_LOG" \
    || fail "recovery contents entered scheduler arguments"
  ! grep -Fq 'ZIP-PASSPHRASE-DO-NOT-LEAK' \
      "$VW_SYSTEMD_LOG" "$VW_AT_LOG" \
    || fail "ZIP passphrase entered scheduler arguments"

  removal_file="$recovery_tmp/removal.txt"
  make_recovery_fixture "$removal_file"
  _remove_sensitive_file "$removal_file" \
    || fail "regular sensitive file removal failed"
  [[ ! -e "$removal_file" ]] || fail "sensitive file remained after removal"
  _remove_sensitive_file "$removal_file" \
    || fail "absent sensitive file removal was not idempotent"
  mkdir -p "$recovery_tmp/failing-shred"
  cat > "$recovery_tmp/failing-shred/shred" <<'EOF_FAILING_SHRED'
#!/usr/bin/env bash
exit 1
EOF_FAILING_SHRED
  chmod +x "$recovery_tmp/failing-shred/shred"
  fallback_removal="$recovery_tmp/fallback-removal.txt"
  make_recovery_fixture "$fallback_removal"
  PATH="$recovery_tmp/failing-shred:$PATH" \
    _remove_sensitive_file "$fallback_removal" \
    || fail "unlink fallback failed after shred failure"
  [[ ! -e "$fallback_removal" ]] \
    || fail "unlink fallback left the sensitive file behind"
  removal_target="$recovery_tmp/removal-target.txt"
  make_recovery_fixture "$removal_target"
  ln -s "$removal_target" "$recovery_tmp/removal-link.txt"
  if _remove_sensitive_file "$recovery_tmp/removal-link.txt" >/dev/null 2>&1; then
    fail "sensitive-file helper accepted a symlink"
  fi
  [[ -f "$removal_target" ]] || fail "sensitive-file helper removed symlink target"

  prepare_dir="$recovery_tmp/protected-recovery"
  RECOVERY_KIT_DIR="$prepare_dir"
  prepared_path="$(_prepare_recovery_dir)" \
    || fail "protected recovery directory preparation failed"
  [[ "$prepared_path" == "$prepare_dir" ]] \
    || fail "recovery directory helper wrote more than the path to stdout"
  [[ "$(stat -c '%a' "$prepare_dir" 2>/dev/null || stat -f '%Lp' "$prepare_dir")" == "700" ]] \
    || fail "protected recovery directory mode is not 0700"
  mkdir "$recovery_tmp/not-a-recovery-directory"
  rm -rf "$recovery_tmp/not-a-recovery-directory"
  printf x > "$recovery_tmp/not-a-recovery-directory"
  RECOVERY_KIT_DIR="$recovery_tmp/not-a-recovery-directory"
  if _prepare_recovery_dir >/dev/null 2>&1; then
    fail "recovery directory helper accepted a non-directory"
  fi

  run_export_outcome() (
    set -euo pipefail
    local_label="$1"
    mock_schedule_rc="$2"
    mock_email_rc="$3"
    expected_rc="$4"
    expected_file="$5"
    case_dir="$recovery_tmp/export-$local_label"
    event_log="$case_dir/events"
    mkdir -p "$case_dir"
    : > "$event_log"
    RECOVERY_KIT_DIR="$case_dir/recovery"

    _ork_generate_and_secure() {
      printf '%s\n' 'SYNTHETIC-RECOVERY-CONTENT' > "$1"
      chmod 0600 "$1"
    }
    _schedule_recovery_cleanup() {
      printf '%s\n' schedule >> "$event_log"
      _RECOVERY_CLEANUP_SCHEDULER="systemd"
      _RECOVERY_CLEANUP_DELAY="30m"
      return "$mock_schedule_rc"
    }
    _offer_email_recovery_kit() {
      printf '%s\n' email >> "$event_log"
      return "$mock_email_rc"
    }

    set +e
    offer_recovery_kit_export "true" >"$case_dir/stdout" 2>"$case_dir/stderr"
    actual_rc=$?
    set -e
    [[ "$actual_rc" == "$expected_rc" ]] \
      || fail "$local_label export returned $actual_rc, expected $expected_rc"

    recovery_file="$(
      find "$RECOVERY_KIT_DIR" -maxdepth 1 -type f \
        -name 'vaultwarden-recovery-kit-*.txt' -print -quit 2>/dev/null || true
    )"
    if [[ "$expected_file" == "present" ]]; then
      [[ -n "$recovery_file" && -f "$recovery_file" ]] \
        || fail "$local_label export did not retain the timer-protected file"
      [[ "$(stat -c '%a' "$recovery_file" 2>/dev/null || stat -f '%Lp' "$recovery_file")" == "600" ]] \
        || fail "$local_label recovery file mode is not 0600"
      grep -Fq "$recovery_file" "$case_dir/stdout" "$case_dir/stderr" \
        || fail "$local_label outcome did not state the exact recovery path"
      grep -Fq 'Primary cleanup is scheduled for approximately 30 minutes' \
        "$case_dir/stdout" "$case_dir/stderr" \
        || fail "$local_label outcome did not state the approximate primary cleanup"
      grep -Fq 'If it survives that cleanup, the next routine maintenance run removes eligible leftovers.' \
        "$case_dir/stdout" "$case_dir/stderr" \
        || fail "$local_label outcome did not state the maintenance fallback"
    else
      [[ -z "$recovery_file" ]] \
        || fail "$local_label export left an unexpected plaintext recovery file"
    fi

    if [[ "$mock_schedule_rc" == "0" ]]; then
      [[ "$(cat "$event_log")" == $'schedule\nemail' ]] \
        || fail "$local_label did not schedule cleanup before email"
    else
      [[ "$(cat "$event_log")" == "schedule" ]] \
        || fail "$local_label scheduler failure continued to email"
    fi
  )

  run_export_outcome scheduler-failure 1 0 1 absent || exit 1
  run_export_outcome email-declined 0 2 0 present || exit 1
  run_export_outcome email-sent 0 0 0 absent || exit 1
  run_export_outcome email-failed 0 1 1 present || exit 1
) || fail "behavioral recovery cleanup lifecycle contract failed"

stale_directory_helper="_tmpfs""_dir"
stale_removal_helper="_secure""_shred"
deprecated_python_import="import"" crypt"
deprecated_warning_filter="ignore::Deprecation""Warning"
erasure_overclaims='securely delete''d|guaranteed secure er''ase|secure removal guaran''teed|must securely shr''ed'
! grep -R --line-number --fixed-strings "$stale_directory_helper" \
    --exclude-dir=.git . >/dev/null \
  || fail "stale recovery-directory helper reference remains"
! grep -R --line-number --fixed-strings "$stale_removal_helper" \
    --exclude-dir=.git . >/dev/null \
  || fail "stale sensitive-file helper reference remains"
! grep -R --line-number --fixed-strings "$deprecated_python_import" \
    --exclude-dir=.git . >/dev/null \
  || fail "deprecated Python crypt import remains"
! grep -R --line-number --fixed-strings "$deprecated_warning_filter" \
    --exclude-dir=.git . >/dev/null \
  || fail "bcrypt deprecation-warning suppression remains"
! grep -RniE "$erasure_overclaims" \
    --exclude-dir=.git \
    --exclude='PRODUCTION-READINESS-delta-2026-07-23-6a7d9e70954c.md' . >/dev/null \
  || fail "guaranteed secure-erasure wording remains"

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

# Post-publication ownership validation must fail clean.
handoff_publish_block="$(sed -n '/^_setup_handoff_publish_file() {$/,/^}$/p' lib/setup-credentials.sh)"
[[ -n "$handoff_publish_block" ]] \
  || fail "setup handoff publication helper could not be extracted"
HANDOFF_PUBLISH_BLOCK="$handoff_publish_block" bash -s <<'HANDOFF_OWNER_TEST' \
  || fail "post-publication ownership cleanup tests failed"
set -euo pipefail

eval "$HANDOFF_PUBLISH_BLOCK"
fixture="$(mktemp -d)"
trap '/bin/rm -rf -- "$fixture"' EXIT

chown() { :; }
stat() {
  case "${2:-}" in
    %a) printf '%s\n' 600 ;;
    %U:%G)
      case "${HANDOFF_OWNER_CASE:-}" in
        success) printf '%s\n' root:root ;;
        mismatch) printf '%s\n' nobody:nogroup ;;
        error) return 72 ;;
        *) return 73 ;;
      esac
      ;;
    *) command stat "$@" ;;
  esac
}

run_failure_case() {
  local case_name="$1" temp_file final_file rc
  temp_file="$fixture/${case_name}.temporary"
  final_file="$fixture/${case_name}.published"
  printf '%s\n' 'PROTECTED-HANDOFF-CONTENT' > "$temp_file"
  HANDOFF_OWNER_CASE="$case_name"
  set +e
  _setup_handoff_publish_file "$temp_file" "$final_file"
  rc=$?
  set -e
  (( rc != 0 ))
  [[ ! -e "$temp_file" && ! -L "$temp_file" ]]
  [[ ! -e "$final_file" && ! -L "$final_file" ]]
}

run_failure_case mismatch
run_failure_case error

success_temp="$fixture/success.temporary"
success_final="$fixture/success.published"
printf '%s\n' 'PROTECTED-HANDOFF-CONTENT' > "$success_temp"
HANDOFF_OWNER_CASE=success
_setup_handoff_publish_file "$success_temp" "$success_final"
[[ ! -e "$success_temp" && ! -L "$success_temp" ]]
[[ -s "$success_final" && ! -L "$success_final" ]]

/bin/rm -rf -- "$fixture"
trap - EXIT
HANDOFF_OWNER_TEST

pass "production-readiness security/runtime regressions"
