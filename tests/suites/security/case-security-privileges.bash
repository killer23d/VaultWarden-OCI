#!/usr/bin/env bash
# Consolidated security and privilege regression suite.
# This static assertion suite intentionally uses literal shell/Make patterns and
# subshell-local PATH probes; keep plain ShellCheck focused on actionable findings.
# shellcheck disable=SC1091,SC2016,SC2030,SC2031
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

check_security_helpers() (
# Focused tests for schema dispatch, password formats, SOPS round trips, and
# authenticated file-integrity sidecars.

set -euo pipefail

PROJECT_ROOT="$VW_TEST_REPO_ROOT"
TEST_TMP=$(mktemp -d -t vw-security-tests.XXXXXXXXXX)
trap 'rm -rf "$TEST_TMP"' EXIT HUP INT TERM

export PROJECT_ROOT
export SECRETS_FILE="${TEST_TMP}/secrets.yaml"
export SECRETS_SCHEMA_FILE="${PROJECT_ROOT}/secrets-schema.yaml"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/defaults.sh"
source "${PROJECT_ROOT}/lib/config.sh"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/lib/secrets.sh"
source "${PROJECT_ROOT}/lib/backup-utils.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_fails() {
    if "$@" >/dev/null 2>&1; then
        fail "expected failure from: $*"
    fi
}

test_hmac_key_not_in_cmdline() {
    local test_key="TEST_HMAC_KEY_SENTINEL"
    local real_python
    real_python=$(command -v python3) || fail "python3 is required for HMAC tests"

    local mock_bin="${TEST_TMP}/mock-bin"
    local exposure_marker="${TEST_TMP}/hmac-key-exposed"
    mkdir -p "$mock_bin"
    cat > "${mock_bin}/python3" <<EOF
#!/usr/bin/env bash
if tr '\0' '\n' < "/proc/\$\$/cmdline" | grep -Fq 'TEST_HMAC_KEY_SENTINEL' \
    || tr '\0' '\n' < "/proc/\$\$/environ" | grep -Fq 'TEST_HMAC_KEY_SENTINEL'; then
    : > "${exposure_marker}"
fi
exec "${real_python}" "\$@"
EOF
    chmod 700 "${mock_bin}/python3"

    local original_path="$PATH"
    PATH="${mock_bin}:${PATH}"
    FILE_INTEGRITY_HMAC_KEY="$test_key" write_file_integrity "$integrity_file" \
        || fail "write_file_integrity failed during command-line exposure test"
    PATH="$original_path"

    [[ ! -e "$exposure_marker" ]] || fail "HMAC key found in child process arguments or environment"
    printf 'PASS: HMAC key not found in child process arguments or environment\n'
}

test_collect_secret_field_rejects_auto_key() {
    local out
    local rc=0
    out=$(collect_secret_field "file_integrity_hmac_key" 2>&1) || rc=$?
    [[ $rc -ne 0 ]] || fail "collect_secret_field accepted an auto key"
    [[ "$out" == *"is an auto key"* ]] || fail "auto-key rejection was not explicit"
    printf 'PASS: collect_secret_field correctly rejected auto key\n'
}

valid_bcrypt_body=$(printf 'A%.0s' {1..53})
_bcrypt_format_ok "\$2y\$12\$${valid_bcrypt_body}" || fail "valid bcrypt format rejected"
assert_fails _bcrypt_format_ok "\$2y\$4\$${valid_bcrypt_body}"
assert_fails _bcrypt_format_ok "\$2y\$120\$${valid_bcrypt_body}"
assert_fails _bcrypt_format_ok "\$2y\$12\$$(printf '!%.0s' {1..53})"

integrity_file="${TEST_TMP}/payload.txt"
printf 'vaultwarden integrity test\n' > "$integrity_file"
export FILE_INTEGRITY_HMAC_KEY="test-only-hmac-key"
export REQUIRE_AUTHENTICATED_INTEGRITY=true
write_file_integrity "$integrity_file" || fail "write_file_integrity failed"
verify_file_integrity "$integrity_file" || fail "verify_file_integrity failed"
printf 'tampered\n' > "${integrity_file}.sha256.hmac"
assert_fails verify_file_integrity "$integrity_file"
test_hmac_key_not_in_cmdline
test_collect_secret_field_rejects_auto_key

command -v yq >/dev/null 2>&1 || fail "yq is required for schema tests"
[[ "$(schema_collect_type push_installation_id)" == "conditional" ]] || fail "conditional collect type missing"
[[ "$(schema_condition_fn push_installation_id)" == "condition_push_enabled" ]] || fail "condition_fn missing"
[[ "$(schema_field_safe file_integrity_hmac_key auto_fn)" == "auto_generate_secret_field" ]] || fail "integrity auto_fn missing"

if command -v htpasswd >/dev/null 2>&1; then
    generated_bcrypt=$(generate_bcrypt_hash "correct horse battery staple" 12)
    _bcrypt_format_ok "$generated_bcrypt" || fail "generated bcrypt hash rejected"
fi

if python3 -c 'import argon2' >/dev/null 2>&1; then
    generated_argon=$(generate_argon2_hash "correct horse battery staple")
    [[ "$generated_argon" == \$argon2id\$* ]] || fail "generated Argon2id hash has wrong prefix"
fi

if command -v age-keygen >/dev/null 2>&1 && command -v sops >/dev/null 2>&1; then
    age_key="${TEST_TMP}/age-key.txt"
    yaml_file="${TEST_TMP}/roundtrip.yaml"
    age-keygen -o "$age_key" >/dev/null 2>&1
    printf 'token: roundtrip-ok\n' > "$yaml_file"
    encrypt_sops_file "$yaml_file" "$age_key" || fail "SOPS encryption round trip failed"
    decrypted=$(SOPS_AGE_KEY_FILE="$age_key" sops --decrypt --extract '["token"]' "$yaml_file")
    [[ "$decrypted" == "roundtrip-ok" ]] || fail "SOPS decrypted value mismatch"
fi

test_postfix_read_only_regression() {
    local compose_file="${PROJECT_ROOT}/docker-compose.yml.example"
    if awk '/^  postfix:/{p=1} /^  [a-zA-Z0-9_-]+:/{if($1!="postfix:")p=0} p && /^[[:space:]]+read_only:[[:space:]]*true/{f=1} END{exit f}' "$compose_file"; then
        :
    else
        fail "postfix must not use read_only: true; boky/postfix mutates /scripts at startup"
    fi
}

test_postfix_read_only_regression

printf 'Security helper tests passed.\n'

)

check_security_helpers
check_root_remediation_hints() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d -t vw-root-hints.XXXXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }

NONROOT_MODE=""
NONROOT_USER=""
if (( EUID != 0 )); then
    NONROOT_MODE=current
elif command -v runuser >/dev/null 2>&1 && id nobody >/dev/null 2>&1; then
    NONROOT_MODE=runuser
    NONROOT_USER=nobody
elif command -v sudo >/dev/null 2>&1 && id nobody >/dev/null 2>&1 \
    && sudo -n -u nobody true >/dev/null 2>&1; then
    NONROOT_MODE=sudo
    NONROOT_USER=nobody
else
    printf 'SKIP: CQA-003 behavioral root-hint tests require a non-root execution user\n'
    exit 0
fi

chmod 0755 "$TMP"
mkdir -p "$TMP/home" "$TMP/state/config"
chmod 0755 "$TMP/home" "$TMP/state" "$TMP/state/config"
cat >"$TMP/state/config/install.env" <<EOF_ENV
PROJECT_STATE_DIR=$TMP/state
SOPS_AGE_KEY_FILE=
EOF_ENV
chmod 0644 "$TMP/state/config/install.env"

PROBE="$TMP/root-hint-probe"
cat >"$PROBE" <<EOF_PROBE
#!/usr/bin/env bash
source "$ROOT/lib/common.sh"
log_error(){ printf 'ERROR: %s\n' "\$*" >&2; }
log_hint(){ printf 'HINT: %s\n' "\$*" >&2; }
require_root "\$@"
EOF_PROBE
chmod 0755 "$PROBE"
ABS_PROBE="$TMP/absolute probe.sh"
cp "$PROBE" "$ABS_PROBE"
chmod 0755 "$ABS_PROBE"

# setup-system creates its secure work directory before the root gate. Give a
# runuser-based test an isolated writable project copy so it reaches the real
# require_root call without weakening production setup behavior.
SYSTEM_ROOT="$TMP/system-repo"
mkdir -p "$SYSTEM_ROOT/utilities"
cp "$ROOT/utilities/setup-system.sh" "$SYSTEM_ROOT/utilities/"
cp "$ROOT/VERSION" "$SYSTEM_ROOT/"
cp -R "$ROOT/lib" "$SYSTEM_ROOT/"
chmod 0777 "$SYSTEM_ROOT"
chmod -R a+rX "$SYSTEM_ROOT/lib" "$SYSTEM_ROOT/utilities" "$SYSTEM_ROOT/VERSION"

NONROOT_ENV=(
    "PATH=$PATH"
    "HOME=$TMP/home"
    "DOCKER_PROJECT_LABEL=label=com.docker.compose.project=vaultwarden-oci"
    "PROJECT_STATE_DIR=$TMP/state"
    "VW_CONFIG_INSTALLED_ENV_FILE=$TMP/state/config/install.env"
)

run_nonroot() {
    local cwd="$1" output_file="$2"
    shift 2
    case "$NONROOT_MODE" in
        current)
            (cd "$cwd" && env "${NONROOT_ENV[@]}" "$@") >"$output_file" 2>&1
            ;;
        runuser)
            runuser -u "$NONROOT_USER" -- env "${NONROOT_ENV[@]}" \
                "$BASH" -c 'cd "$1"; shift; exec "$@"' _ "$cwd" "$@" \
                >"$output_file" 2>&1
            ;;
        sudo)
            # Redirect is intentionally owned by the test runner, not sudo.
            # shellcheck disable=SC2024
            sudo -n -u "$NONROOT_USER" env "${NONROOT_ENV[@]}" \
                "$BASH" -c 'cd "$1"; shift; exec "$@"' _ "$cwd" "$@" \
                >"$output_file" 2>&1
            ;;
    esac
}

assert_hint() {
    local expected="$1" cwd="$2" label="$3"
    shift 3
    local output_file="$TMP/hint-$RANDOM.out" rc hint
    set +e
    run_nonroot "$cwd" "$output_file" "$@"
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]] || {
        cat "$output_file" >&2
        fail "$label returned $rc instead of 1"
    }
    hint="$(sed -n 's/^.*Re-run with: //p' "$output_file" | tail -1)"
    [[ "$hint" == "$expected" ]] || {
        cat "$output_file" >&2
        fail "$label hint '$hint' did not equal '$expected'"
    }
    [[ "$hint" != *"requires root"* && "$hint" != *"must be run"* ]] \
        || fail "$label appended prose to the sudo command"
    ASSERTED_HINT="$hint"
}

assert_hint_round_trip() {
    local hint="$1" label="$2"
    shift 2
    python3 - "$hint" "$@" <<'PY_PARSE' \
        || fail "$label remediation did not parse back to the original argument vector"
import shlex
import sys

actual = shlex.split(sys.argv[1], posix=True)
expected = ["sudo", *sys.argv[2:]]
if actual != expected:
    print(f"actual={actual!r}", file=sys.stderr)
    print(f"expected={expected!r}", file=sys.stderr)
    raise SystemExit(1)
PY_PARSE
}

assert_root_free() {
    local cwd="$1" label="$2"
    shift 2
    local output_file="$TMP/root-free-$RANDOM.out" rc
    set +e
    run_nonroot "$cwd" "$output_file" "$@"
    rc=$?
    set -e
    [[ "$rc" -eq 0 ]] || {
        cat "$output_file" >&2
        fail "$label returned $rc for a root-free metadata path"
    }
    ! grep -Fq 'Re-run with: sudo' "$output_file" \
        || fail "$label unexpectedly reached the root gate"
}

assert_hint 'sudo ./startup.sh --skip-pull --background' "$ROOT" 'startup flags' \
    "$BASH" startup.sh --skip-pull --background
assert_hint 'sudo ./startup.sh stop' "$ROOT" 'startup stop' \
    "$BASH" startup.sh stop

quote_value='value with spaces;dollar$paren()&pipe|'
printf -v quote_rendered '%q' "$quote_value"
assert_hint "sudo ./root-hint-probe --label $quote_rendered" "$TMP" 'quoted bare caller' \
    "$BASH" root-hint-probe --label "$quote_value"
assert_hint_round_trip "$ASSERTED_HINT" 'quoted bare caller' \
    ./root-hint-probe --label "$quote_value"
pass "quoted remediation parses back without execution"

printf -v abs_probe_rendered '%q' "$ABS_PROBE"
assert_hint "sudo $abs_probe_rendered stop" "$ROOT" 'absolute caller path' \
    "$BASH" "$ABS_PROBE" stop
assert_hint_round_trip "$ASSERTED_HINT" 'absolute caller path' "$ABS_PROBE" stop
pass "absolute caller paths remain unchanged and shell-safe"

assert_hint 'sudo utilities/env-edit.sh sync' "$ROOT" 'env-edit sync' \
    "$BASH" utilities/env-edit.sh sync
for action in install remove validate; do
    assert_hint "sudo utilities/setup-systemd.sh $action" "$ROOT" "setup-systemd $action" \
        "$BASH" utilities/setup-systemd.sh "$action"
done
assert_hint 'sudo utilities/setup-systemd.sh install --dry-run' "$ROOT" 'setup-systemd install --dry-run' \
    "$BASH" utilities/setup-systemd.sh install --dry-run
assert_hint 'sudo utilities/setup-systemd.sh install --enable-now' "$ROOT" 'setup-systemd install --enable-now' \
    "$BASH" utilities/setup-systemd.sh install --enable-now
assert_hint 'sudo utilities/setup-systemd.sh install --start-policy manual' "$ROOT" 'setup-systemd install --start-policy manual' \
    "$BASH" utilities/setup-systemd.sh install --start-policy manual
assert_hint 'sudo utilities/setup-systemd.sh install --no-enable-now' "$ROOT" 'setup-systemd install --no-enable-now' \
    "$BASH" utilities/setup-systemd.sh install --no-enable-now
assert_hint 'sudo utilities/setup-systemd.sh remove --dry-run' "$ROOT" 'setup-systemd remove --dry-run' \
    "$BASH" utilities/setup-systemd.sh remove --dry-run
assert_hint 'sudo utilities/setup-firewall.sh --phase iptables --auto' "$ROOT" 'setup-firewall' \
    "$BASH" utilities/setup-firewall.sh --phase iptables --auto
assert_hint 'sudo utilities/setup-system.sh --skip-deps --auto' "$SYSTEM_ROOT" 'setup-system' \
    "$BASH" utilities/setup-system.sh --skip-deps --auto
pass "root enforcement emits exact executable remediation commands"

for option in --help --version; do
    assert_root_free "$ROOT" "startup $option" "$BASH" startup.sh "$option"
    assert_root_free "$ROOT" "env-edit $option" "$BASH" utilities/env-edit.sh "$option"
    assert_root_free "$ROOT" "setup-systemd $option" "$BASH" utilities/setup-systemd.sh "$option"
    assert_root_free "$ROOT" "setup-firewall $option" "$BASH" utilities/setup-firewall.sh "$option"
    assert_root_free "$SYSTEM_ROOT" "setup-system $option" "$BASH" utilities/setup-system.sh "$option"
done
pass "help and version paths remain root-free"

! grep -Eq 'exec sudo|sudo -n "\$0"|sudo "\$0"|sudo "\$\{BASH_SOURCE\[0\]\}"' \
    "$ROOT/startup.sh" "$ROOT/utilities/env-edit.sh" "$ROOT/utilities/setup-systemd.sh" \
    "$ROOT/utilities/setup-firewall.sh" "$ROOT/utilities/setup-system.sh" \
    || fail "root normalization introduced hidden self-escalation"
pass "root normalization does not self-escalate"
)

check_root_remediation_hints

check_privilege_contracts() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
cd "$ROOT"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }

extract_make_target() {
    local target="$1" file="${2:-Makefile}"
    awk -v target="$target" '
        BEGIN { in_target=0; found=0 }
        $0 ~ "^" target ":" { in_target=1; found=1; print; next }
        in_target && $0 ~ /^[A-Za-z0-9_.-]+:([^=]|$)/ { exit }
        in_target { print }
        END { if (!found) exit 2 }
    ' "$file"
}

extract_shell_function() {
    local function_name="$1" file="$2"
    awk -v function_name="$function_name" '
        $0 ~ "^" function_name "\\(\\)[[:space:]]*\\{" {
            found=1
            inside=1
        }
        inside { print }
        inside && /^}$/ { exit }
        END { if (!found) exit 2 }
    ' "$file"
}

# Root-operated lifecycle contract.
grep -Eq '^ROOT_ALLOWED_TARGETS :=([[:space:]]|\|$)' Makefile || fail "ROOT_ALLOWED_TARGETS missing"
for target in up down start stop restart health health-quick health-report status logs logs-tail logs-vaultwarden logs-caddy logs-postfix logs-crowdsec crowdsec-status crowdsec-alerts security-report edit-secrets test-secrets test-email email-queue email-queue-summary email-queue-inspect email-queue-retry email-queue-retry-all email-queue-delete email-queue-logs email-queue-purge email-queue-clear health-email diagnose systemd-status prune key-show info dry-run; do
    grep -Eq "(^|[[:space:]])${target}([[:space:]]|\|$)" Makefile || fail "${target} is not root-allowed"
done
pass "root-supported lifecycle/day-2 targets are allowed under sudo make"

for target in health health-quick health-report status logs logs-tail logs-vaultwarden logs-caddy logs-postfix logs-crowdsec crowdsec-status crowdsec-alerts security-report edit-secrets test-secrets test-email email-queue email-queue-summary email-queue-inspect email-queue-retry email-queue-retry-all email-queue-delete email-queue-logs email-queue-purge email-queue-clear diagnose systemd-status prune key-show; do
    _snip="$(mktemp -t vw-priv-${target}.XXXXXXXXXX)"
    extract_make_target "$target" Makefile > "$_snip" || fail "could not extract make ${target} target"
    grep -Fq '$(call require-root)' "$_snip" || { cat "$_snip" >&2; rm -f "$_snip"; fail "make ${target} does not require root"; }
    rm -f "$_snip"
done
pass "health/status/logs/CrowdSec security targets enforce the root-operated policy"
for target in email-queue email-queue-summary email-queue-inspect email-queue-retry email-queue-retry-all email-queue-delete email-queue-logs email-queue-purge email-queue-clear; do
    QUEUE_TARGET_SNIP="$(mktemp -t vw-priv-${target}.XXXXXXXXXX)"
    extract_make_target "$target" Makefile > "$QUEUE_TARGET_SNIP" \
        || fail "could not extract make ${target} target"
    grep -Fq '$(call require-root)' "$QUEUE_TARGET_SNIP" \
        || fail "make ${target} does not explicitly require root"
    grep -E '^[[:space:]]' "$QUEUE_TARGET_SNIP" \
        | grep -Fq './utilities/email-queue.sh' \
        || fail "make ${target} does not delegate to the queue utility"
    if grep -E '^[[:space:]]' "$QUEUE_TARGET_SNIP" \
        | grep -Eq 'docker([[:space:]]+compose|[[:space:]]+exec)|postqueue|postcat|postsuper'; then
        fail "make ${target} bypasses the queue utility"
    fi
    rm -f "$QUEUE_TARGET_SNIP"
done
pass "Postfix queue Make targets preserve root and utility ownership boundaries"

UP_SNIP="$(mktemp -t vw-priv-up.XXXXXXXXXX)"
trap 'rm -f "$UP_SNIP"; rm -rf "${KEY_TMP:-}"' EXIT
extract_make_target up Makefile > "$UP_SNIP" || fail "could not extract make up target"
[[ -s "$UP_SNIP" ]] || fail "make up snippet is empty"
grep -Fq '$(call require-root)' "$UP_SNIP" || fail "make up does not require root"
grep -Fq '@./startup.sh' "$UP_SNIP" || fail "make up does not call startup.sh directly"
grep -Fq 'sudo make init-secrets' "$UP_SNIP" || fail "make up missing init-secrets remediation"
grep -Fq 'sudo make up' "$UP_SNIP" || fail "make up operator guidance does not use sudo make up"
! grep -Fq 'secrets/.docker_secrets' "$UP_SNIP" || fail "make up still references repo-local decoded secrets"
pass "make up follows root-operated startup contract"

# Static gate: no hidden self-escalation in operational shell scripts.
if find . \
    -path './tests' -prune -o \
    -path './.rate-limit' -prune -o \
    -name '*.sh' -type f -print0 2>/dev/null \
  | xargs -0 grep -nE 'exec sudo|sudo -n "\$0"|sudo "\$0"|sudo '\''\$\{0\}'\''|sudo "\$\{BASH_SOURCE\[0\]\}"' >/tmp/vw-hidden-sudo.$$; then
    cat /tmp/vw-hidden-sudo.$$ >&2
    rm -f /tmp/vw-hidden-sudo.$$
    fail "hidden sudo self-escalation found"
fi
rm -f /tmp/vw-hidden-sudo.$$
pass "no hidden sudo self-reexec remains"

# Internal root health bypass is explicit for root/systemd maintenance callers.
grep -Fq 'VAULTWARDEN_INTERNAL_HEALTH_CHECK' utilities/maintenance-health.sh || fail "health internal flag missing"
grep -Fq 'VAULTWARDEN_INTERNAL_HEALTH_CHECK=true "$_health_script" health' startup.sh || fail "startup does not mark internal health check"
grep -Fq 'VAULTWARDEN_INTERNAL_HEALTH_CHECK=true "${PROJECT_ROOT}/utilities/maintenance-health.sh" --quiet' lib/maintenance-utils.sh || fail "maintenance validation does not mark internal health check"
grep -Fq 'VAULTWARDEN_INTERNAL_HEALTH_CHECK=true "${PROJECT_ROOT}/utilities/maintenance-health.sh" health' utilities/safe-restart.sh || fail "safe-restart does not mark internal health check"
pass "internal root health checks use explicit bypass"

# Live runtime paths must not use repo-local decoded secret caches.
for f in Makefile startup.sh utilities/maintenance-health.sh utilities/maintenance-update-dns.sh; do
    ! grep -Fq 'secrets/.docker_secrets' "$f" || fail "$f still references secrets/.docker_secrets"
done
grep -Fq 'local secrets_dir="${DOCKER_SECRETS_DIR:-/run/vaultwarden-oci/secrets}"' utilities/maintenance-health.sh || fail "health does not inspect runtime secret directory"
pass "live startup/health paths use /run runtime secrets"

# Startup key remediation must preserve the root-operated Age key contract.
! grep -Eq 'chown[[:space:]].*/etc/vaultwarden/age-key\.txt|chgrp[[:space:]].*/etc/vaultwarden|chmod[[:space:]]+750[[:space:]]+/etc/vaultwarden|install[[:space:]]+-d[[:space:]]+-m[[:space:]]+750[[:space:]]+/etc/vaultwarden' startup.sh \
    || fail "startup.sh contains stale non-root Age key remediation"
grep -Fq 'sudo install -d -m 700 -o root -g root /etc/vaultwarden' startup.sh || fail "startup.sh missing root-owned /etc/vaultwarden install remediation"
grep -Fq 'sudo install -m 600 -o root -g root ${repo_local_key} ${canonical_key}' startup.sh || fail "startup.sh missing root-owned age key install remediation"
grep -Fq 'sudo make key-health' startup.sh || fail "startup.sh key verification guidance must use sudo make key-health"
pass "startup key remediation stays root-owned"

# Encrypted secret authoring leaf utilities are root-operated. The top-level
# edit-secrets.sh dispatcher stays metadata-friendly and delegates to these
# utilities for real work.
for f in utilities/secrets-edit.sh utilities/secrets-list.sh utilities/secrets-view.sh utilities/secrets-rotate.sh utilities/secrets-export-recovery-kit.sh; do
    grep -Fq 'require_root "$@"' "$f" || fail "$f does not require root"
done
grep -Fq 'exec "$SCRIPT_DIR/utilities/secrets-edit.sh" "$@"' edit-secrets.sh || fail "edit dispatcher does not delegate to root-enforcing edit utility"
grep -Fq 'exec "$SCRIPT_DIR/utilities/secrets-view.sh" "$@"' edit-secrets.sh || fail "edit dispatcher does not delegate to root-enforcing view utility"
grep -Fq 'exec "$SCRIPT_DIR/utilities/secrets-list.sh" "$@"' edit-secrets.sh || fail "edit dispatcher does not delegate to root-enforcing list utility"
grep -Fq 'exec "$SCRIPT_DIR/utilities/secrets-rotate.sh" "$@"' edit-secrets.sh || fail "edit dispatcher does not delegate to root-enforcing rotate utility"
grep -Fq 'exec "$SCRIPT_DIR/utilities/secrets-export-recovery-kit.sh" "$@"' edit-secrets.sh || fail "edit dispatcher does not delegate to root-enforcing export utility"
pass "encrypted secret authoring utilities require root and dispatcher delegates"


if (( EUID == 0 )) && command -v runuser >/dev/null 2>&1; then
    for cmd in \
        "utilities/secrets-list.sh list" \
        "utilities/secrets-view.sh view" \
        "utilities/secrets-edit.sh edit" \
        "utilities/secrets-rotate.sh rotate email_api_token --dry-run" \
        "utilities/secrets-export-recovery-kit.sh export-recovery-kit"; do
        _out="$(mktemp -t vw-nonroot-secret.XXXXXXXXXX)"
        if runuser -u nobody -- bash -c "cd '$ROOT' && bash $cmd" >"$_out" 2>&1; then
            cat "$_out" >&2
            rm -f "$_out"
            fail "$cmd should reject non-root execution"
        fi
        grep -Fq 'Re-run with: sudo' "$_out" || { cat "$_out" >&2; rm -f "$_out"; fail "$cmd rejection lacks sudo hint"; }
        rm -f "$_out"
    done
    pass "secrets subcommands reject non-root execution with sudo guidance"
else
    pass "secrets non-root rejection test skipped (requires root test runner with runuser)"
fi

for f in utilities/secrets-list.sh utilities/secrets-view.sh utilities/secrets-edit.sh utilities/secrets-rotate.sh utilities/secrets-export-recovery-kit.sh; do
    grep -Fq '/etc/vaultwarden/age-key.txt' "$f" || fail "$f diagnostics do not mention canonical Age key path"
done
grep -Fq 'resolve_age_key_path >/dev/null 2>&1' utilities/secrets-list.sh || fail "secrets-list does not resolve active Age key"
grep -Fq 'resolve_age_key_path >/dev/null 2>&1' utilities/secrets-view.sh || fail "secrets-view does not resolve active Age key"
pass "secrets prerequisite checks use active Age key resolver and canonical diagnostics"

grep -Fq '"/etc/vaultwarden/age-key.txt"' lib/crypto.sh || fail "Age key resolver does not include installed canonical path"
grep -Fq '"/etc/vaultwarden/vaultwarden.env"' lib/config.sh || fail "environment loader does not include installed env path"
pass "root execution can resolve installed Age key and env defaults"

# setup-secrets bootstrap must preserve repo .env owner/group/mode across atomic replacement.
grep -Fq 'env_uid=$(stat -c '\''%u'\'' "$env_file"' utilities/setup-secrets.sh || fail "setup-secrets does not capture .env owner"
grep -Fq 'env_mode=$(stat -c '\''%a'\'' "$env_file"' utilities/setup-secrets.sh || fail "setup-secrets does not capture .env mode"
grep -Fq 'chown "$env_uid:$env_gid" "$temp_env"' utilities/setup-secrets.sh || fail "setup-secrets does not restore .env owner/group on temp file"
grep -Fq 'chmod "$env_mode" "$temp_env"' utilities/setup-secrets.sh || fail "setup-secrets does not restore .env mode"
grep -Fq 'local age_key_file="/etc/vaultwarden/age-key.txt"' utilities/setup-secrets.sh || fail "setup-secrets bootstrap does not own the canonical Age key"
grep -Fq 'local AGE_KEY_FILE="${AGE_KEY_FILE:-/etc/vaultwarden/age-key.txt}"' utilities/setup-secrets.sh || fail "setup-secrets configure does not default to the canonical Age key"
grep -Fq 'AGE_KEY_FILE must be an absolute path' utilities/setup-secrets.sh || fail "setup-secrets configure does not reject relative Age key overrides"
! grep -Fq 'local age_key_file="${PROJECT_ROOT}/secrets/keys/age-key.txt"' utilities/setup-secrets.sh || fail "setup-secrets bootstrap still owns a repo-local Age key"
pass "setup-secrets bootstrap preserves .env metadata and canonical Age key custody"

# Encrypted secrets live under root-owned persistent state, and runtime secrets stay root-owned.
grep -Fq 'chown root:root "$secrets_dir"' utilities/setup-secrets.sh || fail "setup-secrets does not chown persistent secrets dir to root"
grep -Fq 'chmod 700 "$secrets_dir"' utilities/setup-secrets.sh || fail "setup-secrets does not chmod persistent secrets dir 0700"
grep -Fq 'chown root:root "$secrets_file"' utilities/setup-secrets.sh || fail "setup-secrets does not keep secrets.yaml root-owned"
grep -Fq 'chmod 600 "$secrets_file"' utilities/setup-secrets.sh || fail "setup-secrets does not keep secrets.yaml 0600"
grep -Fq 'install -d -m 700 -o root -g root "/run/vaultwarden-oci/secrets"' utilities/setup-secrets.sh || fail "setup-secrets does not keep runtime secret dir root-owned"
grep -Fq 'fix_known_path_permissions "$secrets_dir"' lib/secrets.sh || fail "secure_secrets_file does not defer secrets dir to central permission helper"
grep -Fq 'fix_known_path_permissions "$secrets_file"' lib/secrets.sh || fail "secure_secrets_file does not defer secrets.yaml to central permission helper"
pass "encrypted secrets stay root-owned and runtime secrets stay root-owned"

# Operator-facing production next steps.
grep -Fq 'sudo make up' setup.sh || fail "setup next steps do not mention sudo make up"
grep -Fq 'sudo make up' utilities/setup-secrets.sh || fail "setup-secrets next steps do not mention sudo make up"
pass "operator-facing production next steps use sudo make up"

# Dashboard should use root-operated lifecycle/health/secrets commands.
grep -Fq 'run_sudo_cmd "sudo make restart"' dashboard.sh || fail "dashboard restart label missing"
grep -Fq 'run_sudo_cmd "sudo make down"' dashboard.sh || fail "dashboard stop label missing"
grep -Fq 'run_sudo_cmd "sudo make health-quick"' dashboard.sh || fail "dashboard quick-health label missing"
grep -Fq 'run_sudo_cmd "sudo ./utilities/secrets-edit.sh" "${edit_sh}"' dashboard.sh || fail "dashboard secrets-edit should use sudo"
grep -Fq 'run_sudo_cmd "sudo ./utilities/secrets-export-recovery-kit.sh" "${kit_sh}"' dashboard.sh || fail "dashboard recovery-kit export should stay root-operated"
EMAIL_MENU_SNIP="$(mktemp -t vw-dashboard-email.XXXXXXXXXX)"
QUEUE_MENU_SNIP="$(mktemp -t vw-dashboard-queue.XXXXXXXXXX)"
EMAIL_MENU_NORM="$(mktemp -t vw-dashboard-email-normalized.XXXXXXXXXX)"
QUEUE_MENU_NORM="$(mktemp -t vw-dashboard-queue-normalized.XXXXXXXXXX)"
extract_shell_function handle_email_operations_menu dashboard.sh > "$EMAIL_MENU_SNIP" \
    || fail "could not extract dashboard email transport handler"
extract_shell_function handle_email_queue_menu dashboard.sh > "$QUEUE_MENU_SNIP" \
    || fail "could not extract dashboard queue handler"
tr '\n' ' ' < "$EMAIL_MENU_SNIP" \
    | sed 's/\\[[:space:]]*/ /g; s/[[:space:]][[:space:]]*/ /g' > "$EMAIL_MENU_NORM"
tr '\n' ' ' < "$QUEUE_MENU_SNIP" \
    | sed 's/\\[[:space:]]*/ /g; s/[[:space:]][[:space:]]*/ /g' > "$QUEUE_MENU_NORM"
grep -Fq 'run_sudo_cmd' "$EMAIL_MENU_NORM" \
    || fail "dashboard email diagnostic does not use run_sudo_cmd"
grep -Fq '"sudo make test-email EMAIL_TEST_TRANSPORT=${transport}"' "$EMAIL_MENU_NORM" \
    || fail "dashboard email diagnostic label does not show the root-operated Make command"
grep -Fq 'make -C "${REPO_ROOT}" test-email "EMAIL_TEST_TRANSPORT=${transport}"' "$EMAIL_MENU_NORM" \
    || fail "dashboard email diagnostic does not invoke the root-operated Make target"
grep -Fq 'ACTIVE_MENU="email_queue"' "$EMAIL_MENU_NORM" \
    || fail "dashboard email handler does not enter the nested queue menu"
grep -Fq 'run_sudo_cmd' "$QUEUE_MENU_NORM" \
    || fail "dashboard queue operations do not use run_sudo_cmd"
for target in email-queue-summary email-queue email-queue-inspect email-queue-retry email-queue-delete email-queue-retry-all email-queue-logs email-queue-purge; do
    grep -Fq "sudo make ${target}" "$QUEUE_MENU_NORM" \
        || fail "dashboard queue label missing sudo make ${target}"
    grep -Fq "make -C \"\${REPO_ROOT}\" ${target}" "$QUEUE_MENU_NORM" \
        || fail "dashboard queue action missing Make target ${target}"
done
! grep -Eq 'run_cmd|run_user_cmd|utilities/email-queue\.sh|docker([[:space:]]+compose|[[:space:]]+exec)|postqueue|postcat|postsuper' \
    "$EMAIL_MENU_NORM" "$QUEUE_MENU_NORM" \
    || fail "dashboard email handlers bypass the root-operated Make interface"
grep -Fq '(IFS=" "; "$@")' dashboard.sh \
    || fail "dashboard command runner does not execute the supplied argv directly"
! grep -Eq '(^|[;&|[:space:]])(eval|bash[[:space:]]+-c|sh[[:space:]]+-c)([;&|[:space:]]|$)' \
    "$EMAIL_MENU_SNIP" "$QUEUE_MENU_SNIP" \
    || fail "dashboard email handlers construct a second shell-evaluation path"
rm -f "$EMAIL_MENU_SNIP" "$QUEUE_MENU_SNIP" "$EMAIL_MENU_NORM" "$QUEUE_MENU_NORM"
! grep -Fq 'run_user_cmd' dashboard.sh || fail "dashboard should not drop root for root-operated actions"
pass "dashboard command labels match root-operated lifecycle"

python3 - Makefile <<'PY_MAKE_LITERAL_ORDER' \
    || fail "documented Make inputs are not frozen before the first parse-time shell expression"
from pathlib import Path

lines = Path("Makefile").read_text(encoding="utf-8").splitlines()
first_shell = next((
    number
    for number, line in enumerate(lines, 1)
    if not line.startswith("\t")
    and not line.lstrip().startswith("#")
    and "$(shell" in line
), None)
if first_shell is None:
    raise SystemExit("no active parse-time $(shell expression found")
for name in ("EMAIL_TEST_TRANSPORT", "QUEUE_ID", "EMAIL_QUEUE_TAIL", "EMAIL_QUEUE_BODY"):
    expected = f"override {name} := $(value {name})"
    matches = [number for number, line in enumerate(lines, 1) if line.strip() == expected]
    if len(matches) != 1:
        raise SystemExit(f"expected one {expected!r}, found {len(matches)}")
    if matches[0] >= first_shell:
        raise SystemExit(f"{name} is normalized at line {matches[0]}, not before first shell at line {first_shell}")
PY_MAKE_LITERAL_ORDER
pass "documented Make parameters are frozen before parse-time shell expansion"
MAKE_LITERAL_TMP="$(mktemp -d -t vw-make-email-literals.XXXXXXXXXX)"
MAKE_LITERAL_REPO="$MAKE_LITERAL_TMP/repo"
MAKE_LITERAL_BIN="$MAKE_LITERAL_TMP/bin"
MAKE_LITERAL_CALLS="$MAKE_LITERAL_TMP/calls.jsonl"
MAKE_LITERAL_SUPPLEMENT="$MAKE_LITERAL_TMP/supplement.mk"
MAKE_LITERAL_FEATURES_MK="$MAKE_LITERAL_TMP/features.mk"
rm -rf "$MAKE_LITERAL_TMP"
mkdir -p "$MAKE_LITERAL_REPO/utilities" "$MAKE_LITERAL_BIN"
cat > "$MAKE_LITERAL_BIN/id" <<'EOF_MAKE_LITERAL_ID'
#!/usr/bin/env bash
case "${1:-}" in
    -u) printf '0\n' ;;
    -un) printf 'root\n' ;;
    -g) printf '0\n' ;;
    -gn) printf 'root\n' ;;
    *) /usr/bin/id "$@" ;;
esac
EOF_MAKE_LITERAL_ID
cat > "$MAKE_LITERAL_REPO/maintenance.sh" <<'EOF_MAKE_LITERAL_MAINTENANCE'
#!/usr/bin/env python3
import json
import os
import sys
with open(os.environ["VW_MAKE_LITERAL_CALLS"], "a", encoding="utf-8") as handle:
    handle.write(json.dumps(sys.argv[1:], separators=(",", ":")) + "\n")
EOF_MAKE_LITERAL_MAINTENANCE
cat > "$MAKE_LITERAL_REPO/utilities/email-queue.sh" <<'EOF_MAKE_LITERAL_QUEUE'
#!/usr/bin/env python3
import json
import os
import sys
with open(os.environ["VW_MAKE_LITERAL_CALLS"], "a", encoding="utf-8") as handle:
    handle.write(json.dumps(sys.argv[1:], separators=(",", ":")) + "\n")
EOF_MAKE_LITERAL_QUEUE
cat > "$MAKE_LITERAL_SUPPLEMENT" <<'EOF_MAKE_LITERAL_SUPPLEMENT'
test-email:
	@python3 -c 'import json,os; print(json.dumps({name:os.environ[name] for name in ("EMAIL_TEST_TRANSPORT","QUEUE_ID","EMAIL_QUEUE_TAIL","EMAIL_QUEUE_BODY")}, separators=(",",":")))'
EOF_MAKE_LITERAL_SUPPLEMENT
cat > "$MAKE_LITERAL_FEATURES_MK" <<'EOF_MAKE_LITERAL_FEATURES'
.PHONY: print-features
print-features:
	@printf '%s\n' '$(.FEATURES)'
EOF_MAKE_LITERAL_FEATURES
chmod +x "$MAKE_LITERAL_BIN/id" "$MAKE_LITERAL_REPO/maintenance.sh" \
    "$MAKE_LITERAL_REPO/utilities/email-queue.sh"
run_make_literal_target() {
    local target="$1"
    shift
    : >"$MAKE_LITERAL_CALLS"
    PATH="$MAKE_LITERAL_BIN:$PATH" VW_MAKE_LITERAL_CALLS="$MAKE_LITERAL_CALLS" \
        make -s -C "$MAKE_LITERAL_REPO" -f "$ROOT/Makefile" "$target" "$@"
}
assert_make_literal_call() {
    local expected_json="$1"
    python3 - "$MAKE_LITERAL_CALLS" "$expected_json" <<'PY_MAKE_LITERAL_CALL' \
        || fail "Make target did not preserve the expected literal argv"
import json, sys
from pathlib import Path
rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()]
assert rows == [json.loads(sys.argv[2])], rows
PY_MAKE_LITERAL_CALL
}
for transport in configured all api sidecar direct; do
    run_make_literal_target test-email "EMAIL_TEST_TRANSPORT=$transport" \
        >"$MAKE_LITERAL_TMP/test-email-${transport}.out"
    assert_make_literal_call "[\"test-email\",\"--transport\",\"$transport\",\"--verbose\"]"
done
malformed_transport='bad"; touch SHOULD_NOT_EXIST; printf "'
run_make_literal_target test-email "EMAIL_TEST_TRANSPORT=$malformed_transport" \
    >"$MAKE_LITERAL_TMP/test-email-malformed.out"
python3 - "$MAKE_LITERAL_CALLS" "$malformed_transport" <<'PY_MAKE_LITERAL_TRANSPORT' \
    || fail "malformed transport escaped its quoted Make recipe argument"
import json, sys
from pathlib import Path
rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()]
assert rows == [["test-email", "--transport", sys.argv[2], "--verbose"]], rows
PY_MAKE_LITERAL_TRANSPORT
[[ ! -e "$MAKE_LITERAL_REPO/SHOULD_NOT_EXIST" ]] \
    || fail "malformed transport executed a constructed shell command"
run_make_literal_target email-queue-inspect 'QUEUE_ID=AbC-123' 'EMAIL_QUEUE_BODY=false' \
    >"$MAKE_LITERAL_TMP/queue-inspect.out"
assert_make_literal_call '["inspect","AbC-123"]'
run_make_literal_target email-queue-inspect 'QUEUE_ID=AbC-123' 'EMAIL_QUEUE_BODY=true' \
    >"$MAKE_LITERAL_TMP/queue-inspect-body.out"
assert_make_literal_call '["inspect","AbC-123","--body"]'
run_make_literal_target email-queue-logs 'QUEUE_ID=AbC-123' 'EMAIL_QUEUE_TAIL=37' \
    >"$MAKE_LITERAL_TMP/queue-logs.out"
assert_make_literal_call '["logs","AbC-123","--tail","37"]'

literal_shell='$(shell touch '"$MAKE_LITERAL_TMP/marker-shell"')'
literal_error='$(error injected)'
literal_escaped='$$(shell touch '"$MAKE_LITERAL_TMP/marker-escaped"')'
PATH="$MAKE_LITERAL_BIN:$PATH" \
    make -s -C "$MAKE_LITERAL_REPO" -f "$ROOT/Makefile" -f "$MAKE_LITERAL_SUPPLEMENT" \
        test-email \
        "EMAIL_TEST_TRANSPORT=$literal_shell" \
        "QUEUE_ID=$literal_error" \
        "EMAIL_QUEUE_TAIL=$literal_escaped" \
        'EMAIL_QUEUE_BODY=false' \
        >"$MAKE_LITERAL_TMP/exported-values.json" \
        2>"$MAKE_LITERAL_TMP/exported-values.err" \
    || { cat "$MAKE_LITERAL_TMP/exported-values.err" >&2; fail "literal Make values were evaluated during parsing or export"; }
[[ ! -e "$MAKE_LITERAL_TMP/marker-shell" && ! -e "$MAKE_LITERAL_TMP/marker-escaped" ]] \
    || fail "documented NAME=value input executed a Make shell function"
python3 - "$MAKE_LITERAL_TMP/exported-values.json" \
    "$literal_shell" "$literal_error" "$literal_escaped" <<'PY_MAKE_LITERAL_VALUES' \
    || fail "documented NAME=value inputs did not reach the receiving shell literally"
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    values = json.load(handle)
assert values == {
    "EMAIL_TEST_TRANSPORT": sys.argv[2],
    "QUEUE_ID": sys.argv[3],
    "EMAIL_QUEUE_TAIL": sys.argv[4],
    "EMAIL_QUEUE_BODY": "false",
}, values
PY_MAKE_LITERAL_VALUES
MAKE_LITERAL_FEATURES="$(make -s -f "$MAKE_LITERAL_FEATURES_MK" print-features)"
if [[ " $MAKE_LITERAL_FEATURES " == *" shell-export "* ]]; then
    shell_export_shell='$(shell touch '"$MAKE_LITERAL_TMP/marker-shell-export"')'
    shell_export_error='$(error injected)'
    shell_export_escaped='$$(shell touch '"$MAKE_LITERAL_TMP/marker-shell-export-escaped"')'
    PATH="$MAKE_LITERAL_BIN:$PATH" \
        make -s -C "$MAKE_LITERAL_REPO" -f "$ROOT/Makefile" -f "$MAKE_LITERAL_SUPPLEMENT" \
        test-email \
        "EMAIL_TEST_TRANSPORT=$shell_export_shell" \
        "QUEUE_ID=$shell_export_error" \
        "EMAIL_QUEUE_TAIL=$shell_export_escaped" \
        'EMAIL_QUEUE_BODY=true' \
        >"$MAKE_LITERAL_TMP/shell-export-values.json" \
        2>"$MAKE_LITERAL_TMP/shell-export-values.err" \
        || { cat "$MAKE_LITERAL_TMP/shell-export-values.err" >&2; fail "GNU Make shell-export evaluated a documented input during parsing"; }
    [[ ! -e "$MAKE_LITERAL_TMP/marker-shell-export" \
        && ! -e "$MAKE_LITERAL_TMP/marker-shell-export-escaped" ]] \
        || fail "GNU Make shell-export executed a documented Make input"
    python3 - "$MAKE_LITERAL_TMP/shell-export-values.json" \
        "$shell_export_shell" "$shell_export_error" "$shell_export_escaped" <<'PY_MAKE_SHELL_EXPORT' \
        || fail "GNU Make shell-export changed a documented input before the receiving shell"
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    values = json.load(handle)
assert values == {
    "EMAIL_TEST_TRANSPORT": sys.argv[2],
    "QUEUE_ID": sys.argv[3],
    "EMAIL_QUEUE_TAIL": sys.argv[4],
    "EMAIL_QUEUE_BODY": "true",
}, values
PY_MAKE_SHELL_EXPORT
    pass "GNU Make shell-export preserves documented Make inputs literally"
else
    pass "GNU Make shell-export reproduction skipped because the installed Make lacks the feature"
fi
rm -rf "$MAKE_LITERAL_TMP"
pass "documented email Make parameters remain literal and argv-safe"

grep -Fq 'sudo ./setup.sh install --domain <your-domain> --email <your-email>' Makefile \
    || fail "Makefile setup guidance must advertise supported first-install command"
SETUP_SNIP="$(mktemp -t vw-setup-guidance.XXXXXXXXXX)"
extract_make_target setup Makefile > "$SETUP_SNIP" || fail "could not extract setup target"
grep -Fq 'guidance only' "$SETUP_SNIP" || fail "make setup should be guidance only"
grep -Fq '@exit 1' "$SETUP_SNIP" || fail "make setup guidance target must exit non-zero"
rm -f "$SETUP_SNIP"
pass "make setup is no longer advertised as a working first-install parser"

! grep -Eq '^key-path:' Makefile || fail "redundant key-path target should be removed"
grep -Fq 'Create local Age key copy for manual offline transfer' Makefile || fail "key-backup wording must say local transfer copy"
grep -Fq 'NOT OFFLINE YET' Makefile || fail "key-backup must warn local copy is not offline custody"
pass "key inspection/backup targets avoid misleading production status"

KEY_TMP="$(mktemp -d -t vw-key-contract.XXXXXXXXXX)"
KEY_REPO="$KEY_TMP/repo"
KEY_BIN="$KEY_TMP/bin"
KEY_ENV="$KEY_TMP/installed.env"
mkdir -p "$KEY_REPO/secrets/keys" "$KEY_REPO/lib" "$KEY_BIN" "$KEY_TMP/home" "$KEY_TMP/state"
cp Makefile "$KEY_REPO/Makefile"
cp -a lib/. "$KEY_REPO/lib/"
PROD_KEY="$KEY_TMP/prod-age-key.txt"
REPO_KEY="$KEY_REPO/secrets/keys/age-key.txt"
PROD_RECIPIENT="age1prod000000000000000000000000000000000000000000000000000000"
REPO_RECIPIENT="age1repo000000000000000000000000000000000000000000000000000000"
printf '# public key: %s\nAGE-SECRET-KEY-1PRODUCTION-ACTIVE-KEY\n' "$PROD_RECIPIENT" > "$PROD_KEY"
printf '# public key: %s\nAGE-SECRET-KEY-1REPO-LOCAL-KEY\n' "$REPO_RECIPIENT" > "$REPO_KEY"
chmod 0600 "$PROD_KEY" "$REPO_KEY"
cat > "$KEY_ENV" <<EOF_KEY_ENV
PROJECT_STATE_DIR=$KEY_TMP/state
SOPS_AGE_KEY_FILE=$PROD_KEY
EOF_KEY_ENV
chmod 0600 "$KEY_ENV"
cat > "$KEY_REPO/.sops.yaml" <<EOF_KEY_POLICY
creation_rules:
  - path_regex: '.*\.yaml$'
    age: "$PROD_RECIPIENT"
EOF_KEY_POLICY
cat > "$KEY_BIN/id" <<'EOF_ID'
#!/usr/bin/env bash
case "${1:-}" in
  -u) printf '0\n' ;;
  -un) printf 'root\n' ;;
  -g) printf '0\n' ;;
  -gn) printf 'root\n' ;;
  *) /usr/bin/id "$@" ;;
esac
EOF_ID
cat > "$KEY_BIN/age-keygen" <<EOF_AGE_KEYGEN
#!/usr/bin/env bash
if [[ "\${1:-}" == "-y" ]]; then
  case "\$(cat "\${2:-}" 2>/dev/null)" in
    *PRODUCTION-ACTIVE-KEY*) printf '%s\n' "$PROD_RECIPIENT" ;;
    *REPO-LOCAL-KEY*) printf '%s\n' "$REPO_RECIPIENT" ;;
    *) exit 1 ;;
  esac
  exit 0
fi
exit 1
EOF_AGE_KEYGEN
cat > "$KEY_BIN/age" <<'EOF_AGE'
#!/usr/bin/env bash
cat
EOF_AGE
chmod +x "$KEY_BIN"/*
run_key_make() {
    local target="$1" out="$2"
    PATH="$KEY_BIN:/opt/homebrew/bin:$PATH" \
        VW_CONFIG_INSTALLED_ENV_FILE="$KEY_ENV" \
        AGE_KEY_FILE="$PROD_KEY" \
        SOPS_CONFIG_FILE="$KEY_REPO/.sops.yaml" \
        HOME="$KEY_TMP/home" \
        make -C "$KEY_REPO" "$target" > "$out" 2>&1
}

KEY_SHOW_OUT="$KEY_TMP/key-show.out"
run_key_make key-show "$KEY_SHOW_OUT" || { cat "$KEY_SHOW_OUT" >&2; fail "key-show target failed"; }
grep -Fq "$PROD_KEY" "$KEY_SHOW_OUT" || { cat "$KEY_SHOW_OUT" >&2; fail "key-show did not report production active key"; }
grep -Fq "$PROD_RECIPIENT" "$KEY_SHOW_OUT" || { cat "$KEY_SHOW_OUT" >&2; fail "key-show did not derive production public recipient"; }
! grep -Fq "$REPO_KEY" "$KEY_SHOW_OUT" || fail "key-show fell back to repo-local key"

KEY_HEALTH_OUT="$KEY_TMP/key-health.out"
run_key_make key-health "$KEY_HEALTH_OUT" || { cat "$KEY_HEALTH_OUT" >&2; fail "key-health target failed"; }
grep -Fq "$PROD_KEY" "$KEY_HEALTH_OUT" || { cat "$KEY_HEALTH_OUT" >&2; fail "key-health did not resolve production active key"; }
grep -Fq 'Age key is healthy' "$KEY_HEALTH_OUT" || { cat "$KEY_HEALTH_OUT" >&2; fail "key-health did not complete active-key health check"; }

KEY_BACKUP_OUT="$KEY_TMP/key-backup.out"
run_key_make key-backup "$KEY_BACKUP_OUT" || { cat "$KEY_BACKUP_OUT" >&2; fail "key-backup target failed"; }
backup_copy="$(find "$KEY_TMP/home" -name 'age-key-backup-*.txt' -type f -print | head -1)"
[[ -n "$backup_copy" ]] || fail "key-backup did not create a transfer copy"
grep -Fq 'PRODUCTION-ACTIVE-KEY' "$backup_copy" || fail "key-backup copied repo-local key instead of production active key"
! grep -Fq 'REPO-LOCAL-KEY' "$backup_copy" || fail "key-backup transfer copy contains repo-local key"

KEY_ESCROW_OUT="$KEY_TMP/key-escrow.out"
run_key_make key-escrow "$KEY_ESCROW_OUT" || { cat "$KEY_ESCROW_OUT" >&2; fail "key-escrow target failed"; }
escrow_copy="$(find "$KEY_TMP/home" -name 'age-key-escrow-*.txt' -type f -print | head -1)"
[[ -n "$escrow_copy" ]] || { cat "$KEY_ESCROW_OUT" >&2; fail "key-escrow did not create an escrow file"; }
grep -Fq 'PRODUCTION-ACTIVE-KEY' "$escrow_copy" || fail "key-escrow wrote escrow from the wrong key"
! grep -Fq 'REPO-LOCAL-KEY' "$escrow_copy" || fail "key-escrow escrow contains repo-local key"
pass "retained key targets use the production key and ignore the repo-local decoy"

STATUS_SNIP="$(mktemp -t vw-status-contract.XXXXXXXXXX)"
extract_make_target status Makefile > "$STATUS_SNIP" || fail "could not extract status target"
grep -Fq 'CSCLI_RC=$$?' "$STATUS_SNIP" || fail "make status must capture cscli exit status"
grep -Fq 'unknown (cscli query failed)' "$STATUS_SNIP" || fail "make status must not turn cscli failure into zero bans"
rm -f "$STATUS_SNIP"
UNBAN_SNIP="$(mktemp -t vw-unban-contract.XXXXXXXXXX)"
extract_make_target unban Makefile > "$UNBAN_SNIP" || fail "could not extract unban target"
grep -Fq 'CSCLI_RC=$$?' "$UNBAN_SNIP" || fail "make unban must capture cscli exit status"
grep -Fq 'CrowdSec unban failed; see cscli output above.' "$UNBAN_SNIP" || fail "make unban must preserve generic cscli errors"
! grep -Fq '&& echo "$(GREEN)' "$UNBAN_SNIP" || fail "make unban must not use command && success || benign fallback"
rm -f "$UNBAN_SNIP"
pass "CrowdSec status and unban preserve real cscli failures"

# Legacy CF token preservation must use root-side file install, not shell value arguments.
grep -Fq 'install -m 0444 -o root -g root "$_cf_flat" "$_cf_dest"' lib/secrets.sh || fail "CF token mirror does not use root-side install"
! grep -Fq '_cf_value' lib/secrets.sh || fail "CF token value should not be read into shell variables"
pass "CF token mirror avoids command-line secret values"


# Operator-facing breakglass-remove must preserve the utility confirmation by default.
BREAKGLASS_REMOVE_SNIP="$(mktemp -t vw-breakglass-remove.XXXXXXXXXX)"
extract_make_target breakglass-remove Makefile > "$BREAKGLASS_REMOVE_SNIP" || fail "could not extract make breakglass-remove target"
grep -Fq 'utilities/setup-secrets.sh breakglass remove' "$BREAKGLASS_REMOVE_SNIP" || fail "make breakglass-remove does not call setup-secrets breakglass remove"
! grep -Fq -- '--force' "$BREAKGLASS_REMOVE_SNIP" || fail "make breakglass-remove must not bypass the utility confirmation with --force"
rm -f "$BREAKGLASS_REMOVE_SNIP"
pass "make breakglass-remove preserves break-glass removal confirmation"

# update-system intentionally remains a direct host package update, with wording that
# distinguishes it from the managed container update workflow while routing through
# the maintenance runner for the shared operation guard and package-manager retry path.
UPDATE_SYSTEM_SNIP="$(mktemp -t vw-update-system.XXXXXXXXXX)"
extract_make_target update-system Makefile > "$UPDATE_SYSTEM_SNIP" || fail "could not extract make update-system target"
grep -Fq 'Updating host OS packages directly' "$UPDATE_SYSTEM_SNIP" || fail "make update-system does not clearly describe direct host package semantics"
grep -Fq 'does not create a VaultWarden pre-update backup or run the managed Compose restart/health workflow' "$UPDATE_SYSTEM_SNIP" || fail "make update-system missing managed-workflow distinction"
grep -Fq 'Host package updates may still restart system services or require a reboot' "$UPDATE_SYSTEM_SNIP" || fail "make update-system missing package-manager side-effect warning"
grep -Fq './maintenance.sh update --system --skip-backup' "$UPDATE_SYSTEM_SNIP" || fail "make update-system must use guarded maintenance system-update path"
rm -f "$UPDATE_SYSTEM_SNIP"
pass "make update-system direct package-update semantics are explicit"

# Generated command reference must be current.
if [[ -f docs/COMMAND-REFERENCE.md ]]; then
    _cmd_ref_before="$(mktemp -t vw-command-reference.XXXXXXXXXX)"
    cp docs/COMMAND-REFERENCE.md "$_cmd_ref_before"
    DOCKER_PROJECT_LABEL=ci bash utilities/write-command-reference.sh >/dev/null
    if ! diff -q docs/COMMAND-REFERENCE.md "$_cmd_ref_before" >/dev/null 2>&1; then
        diff -u "$_cmd_ref_before" docs/COMMAND-REFERENCE.md >&2 || true
        rm -f "$_cmd_ref_before"
        fail "docs/COMMAND-REFERENCE.md is stale; run DOCKER_PROJECT_LABEL=ci bash utilities/write-command-reference.sh"
    fi
    rm -f "$_cmd_ref_before"
    pass "COMMAND-REFERENCE.md is generated/current"
fi

grep -Fq 'require_root "$@"' utilities/notify-failure.sh || fail "notify-failure lacks explicit root guard"
pass "notify-failure explicitly requires root"

_backup_list_snip="$(awk '/if \[\[ "\$LIST_ONLY" == "true" \]\]/{flag=1} flag{print} /exit 0/{if(flag){exit}}' utilities/backup-run.sh)"
! grep -Fq 'auto_fix_critical_permissions' <<<"$_backup_list_snip" || fail "backup list-only path mutates permissions"
_restore_pre_root_snip="$(awk '/load_env_file 2>\/dev\/null/{flag=1} /require_root "\$@"/{if(flag){exit}} flag{print}' utilities/restore-run.sh)"
! grep -Fq 'auto_fix_critical_permissions' <<<"$_restore_pre_root_snip" || fail "restore list-only/pre-root path mutates permissions"
pass "backup/restore list-only paths avoid mutating permission repair"

grep -Fq 'sudo ./maintenance.sh <subcommand>' maintenance.sh || fail "maintenance help does not show sudo usage"
grep -Fq 'sudo ./maintenance.sh update-dns' utilities/maintenance-update-dns.sh || fail "DNS updater help lacks sudo dispatcher example"
grep -Fq 'sudo ./maintenance.sh update-firewall' utilities/maintenance-update-firewall.sh || fail "firewall updater help lacks sudo dispatcher example"
! grep -Fq 'Run: ./edit-secrets.sh rotate' utilities/setup-crowdsec.sh || fail "setup post-install guidance advertises non-sudo edit-secrets"
pass "help text uses sudo for root-operated maintenance/secret commands"

# CrowdSec email and health incident context must remain additive to the
# established privilege, ownership, and secret contracts.
! grep -Fq 'CROWDSEC_EMAIL_NOTIFICATIONS' secrets-schema.yaml \
    || fail "CrowdSec email opt-in was added to the secret schema"
! grep -Fq 'active-incident.state' lib/common.sh \
    || fail "health incident state was added to central known-path ownership tables"
! grep -Fq 'active-incident.state' lib/runtime-permissions.sh \
    || fail "health incident state was added to runtime permission repair"
! grep -Fq 'active-incident.state' utilities/repair-permissions.sh \
    || fail "health incident state was added to permission repair"
_incident_snip="$(sed -n '/^_incident_sanitize()/,/^local -A check_results=/p' utilities/maintenance-health.sh)"
! grep -Eq 'chown|chmod[[:space:]]+-R|chown[[:space:]]+-R|sudo' <<<"$_incident_snip" \
    || fail "health incident persistence changes ownership, recurses permissions, or self-escalates"
_crowdsec_email_snip="$(sed -n '/^_CS_EMAIL_PLUGIN_MARKER=/,/^# CLI flags/p' utilities/setup-crowdsec.sh)"
! grep -Eq 'chmod[[:space:]]+-R|chown[[:space:]]+-R|setfacl|usermod|groupadd|useradd|setcap' <<<"$_crowdsec_email_snip" \
    || fail "CrowdSec email reconciliation broadens permissions or identity mechanisms"
! grep -Eq 'get_secret|decrypt_secret|smtp_password:[[:space:]]|email_api_token:[[:space:]]|\$\{SMTP_PASSWORD|\$\{EMAIL_API_TOKEN' <<<"$_crowdsec_email_snip" \
    || fail "CrowdSec email reconciliation references a credential store"
grep -Fq 'CADDY_UID:-2000' lib/runtime-permissions.sh \
    || fail "Caddy UID 2000 contract changed"
grep -Fq 'CADDY_GID:-2000' lib/runtime-permissions.sh \
    || fail "Caddy GID 2000 contract changed"
pass "CrowdSec email and incident context preserve privilege/ownership/secret contracts"

)

check_privilege_contracts

check_setup_force_acknowledgement() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
SETUP="$ROOT/setup.sh"
TMP="$(mktemp -d -t vw-setup-force.XXXXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }

run_non_tty() {
    local token="$1"
    shift
    set +e
    FORCE_OUTPUT=$(env \
        VW_TEST_MODE=true \
        VW_SETUP_TEST_FORCE_ACK_ONLY=true \
        VW_FORCE_ACK="$token" \
        bash "$SETUP" "$@" </dev/null 2>&1)
    FORCE_STATUS=$?
    set -e
}

run_tty() {
    local token="$1" action="$2"
    shift 2
    set +e
    FORCE_OUTPUT=$(env \
        VW_TEST_MODE=true \
        VW_SETUP_TEST_FORCE_ACK_ONLY=true \
        VW_SETUP_TEST_FORCE_ACK_TIMEOUT=1 \
        VW_FORCE_ACK="$token" \
        python3 - "$SETUP" "$action" "$@" <<'PY'
import os
import pty
import select
import signal
import sys
import time

setup = sys.argv[1]
action = sys.argv[2]
setup_args = sys.argv[3:]
pid, master = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", setup, *setup_args])

os.set_blocking(master, False)
output = bytearray()
sent = action in {"none", "timeout"}
deadline = time.monotonic() + 8
status = None

while time.monotonic() < deadline:
    ready, _, _ = select.select([master], [], [], 0.05)
    if ready:
        try:
            chunk = os.read(master, 4096)
        except OSError:
            chunk = b""
        output.extend(chunk)
    if not sent and b"Type YES to confirm" in output:
        if action == "yes":
            os.write(master, b"YES\n")
        elif action == "no":
            os.write(master, b"NO\n")
        elif action == "eof":
            os.write(master, b"\x04")
        sent = True
    done, child_status = os.waitpid(pid, os.WNOHANG)
    if done:
        status = child_status
        break

if status is None:
    os.kill(pid, signal.SIGKILL)
    _, status = os.waitpid(pid, 0)
    sys.stdout.buffer.write(output)
    raise SystemExit(124)

while True:
    try:
        chunk = os.read(master, 4096)
    except OSError:
        break
    if not chunk:
        break
    output.extend(chunk)

sys.stdout.buffer.write(output)
raise SystemExit(os.waitstatus_to_exitcode(status))
PY
    )
    FORCE_STATUS=$?
    set -e
}

grep -Fq 'I_UNDERSTAND_OVERWRITING_CURRENT_STATE' "$SETUP" \
    || fail 'setup --force does not advertise the current-state acknowledgement token'
! grep -Fq 'WILL ROTATE YOUR AGE KEY' "$SETUP" \
    || fail 'setup --force still claims that it rotates the Age key'
grep -Fq -- '--force does NOT rotate the Age key.' "$SETUP" \
    || fail 'setup --force warning does not state retained-key behavior'
pass 'setup --force warning matches the retained-key bootstrap contract'

run_non_tty I_UNDERSTAND_OVERWRITING_CURRENT_STATE --force
[[ "$FORCE_STATUS" -eq 0 ]] || fail "non-TTY token acknowledgement failed: $FORCE_OUTPUT"
[[ "$FORCE_OUTPUT" != *"Type YES to confirm"* ]] || fail "non-TTY token acknowledgement prompted"
pass "non-TTY exact token is accepted without prompting"

run_tty I_UNDERSTAND_OVERWRITING_CURRENT_STATE none --force
[[ "$FORCE_STATUS" -eq 0 ]] || fail "TTY token acknowledgement failed: $FORCE_OUTPUT"
[[ "$FORCE_OUTPUT" != *"Type YES to confirm"* ]] || fail "TTY token acknowledgement prompted"
pass "TTY exact token is accepted without prompting"

run_non_tty I_UNDERSTAND_LOSING_OLD_BACKUPS --force
[[ "$FORCE_STATUS" -eq 0 ]] || fail "legacy non-TTY token acknowledgement failed: $FORCE_OUTPUT"
pass "legacy force acknowledgement token remains accepted"

run_tty "" yes --force
[[ "$FORCE_STATUS" -eq 0 ]] || fail "TTY YES acknowledgement failed: $FORCE_OUTPUT"
[[ "$FORCE_OUTPUT" == *"Type YES to confirm"* ]] || fail "TTY YES acknowledgement did not prompt"
pass "TTY exact YES acknowledgement is accepted"

run_tty "" no --force
[[ "$FORCE_STATUS" -eq 1 ]] || fail "TTY NO returned $FORCE_STATUS instead of 1: $FORCE_OUTPUT"
pass "TTY wrong acknowledgement fails closed"

run_tty "" eof --force
[[ "$FORCE_STATUS" -eq 1 ]] || fail "TTY EOF returned $FORCE_STATUS instead of 1: $FORCE_OUTPUT"
pass "TTY EOF fails closed"

run_tty "" timeout --force
[[ "$FORCE_STATUS" -eq 1 ]] || fail "TTY timeout returned $FORCE_STATUS instead of 1: $FORCE_OUTPUT"
[[ "$FORCE_OUTPUT" == *"No confirmation received within 5 minutes"* ]] \
    || fail "TTY timeout diagnostic missing: $FORCE_OUTPUT"
pass "TTY timeout fails closed"

run_non_tty "" --force
[[ "$FORCE_STATUS" -eq 2 ]] || fail "non-TTY missing token returned $FORCE_STATUS instead of 2: $FORCE_OUTPUT"
pass "non-TTY missing token returns 2"

run_non_tty "" --dry-run --force
[[ "$FORCE_STATUS" -eq 0 ]] || fail "dry-run force acknowledgement failed: $FORCE_OUTPUT"
[[ "$FORCE_OUTPUT" != *"Type YES to confirm"* ]] || fail "dry-run force prompted"
pass "dry-run force needs no acknowledgement"

# Exercise the real setup control flow with only its dependencies stubbed.
# The guard returns 75 before any setup utility can run; both forced and
# unforced invocations must reach it with the same arguments.
GUARD_ROOT="$TMP/guard-repo"
mkdir -p "$GUARD_ROOT/lib" "$GUARD_ROOT/utilities"
cp "$SETUP" "$ROOT/VERSION" "$GUARD_ROOT/"
# Keep this fixture aligned with setup.sh instead of maintaining a second,
# drift-prone dependency list in the test.
guard_required_lib_count=0
while IFS= read -r required_lib; do
    [[ -n "$required_lib" ]] || continue
    mkdir -p "$GUARD_ROOT/$(dirname "$required_lib")"
    : >"$GUARD_ROOT/$required_lib"
    guard_required_lib_count=$((guard_required_lib_count + 1))
done < <(
    sed -n '/^REQUIRED_LIBS=(/,/^)/p' "$GUARD_ROOT/setup.sh" \
        | sed -n 's/^[[:space:]]*"\([^"]*\.sh\)".*/\1/p'
)
(( guard_required_lib_count > 0 )) \
    || fail "could not derive setup required-library fixture"
cat >"$GUARD_ROOT/lib/log.sh" <<'EOF_LOG'
COLOR_BOLD_RED=""; COLOR_RESET=""; COLOR_YELLOW=""; COLOR_RED=""; COLOR_CYAN=""; COLOR_GREEN=""
log_error(){ printf 'ERROR: %s\n' "$*" >&2; }
log_hint(){ printf 'HINT: %s\n' "$*" >&2; }
log_info(){ :; }
log_header(){ :; }
EOF_LOG
cat >"$GUARD_ROOT/lib/validate.sh" <<'EOF_VALIDATE'
validate_domain(){ return 0; }
validate_email(){ return 0; }
EOF_VALIDATE
cat >"$GUARD_ROOT/lib/common.sh" <<'EOF_COMMON'
init_common_lib(){ :; }
is_root(){ return 0; }
EOF_COMMON
cat >"$GUARD_ROOT/lib/operations.sh" <<'EOF_OPERATIONS'
operation_acquire(){ printf '%s\n' "$*" >"${VW_TEST_GUARD_MARKER:?}"; return 75; }
EOF_OPERATIONS
printf '_VW_DEFAULT_DATA_MOUNT=/mnt/vw-data\n' >"$GUARD_ROOT/lib/defaults.sh"

for mode in normal force; do
    marker="$TMP/guard-$mode"
    args=(install --domain vault.example.test --email admin@example.test)
    env_args=(VW_TEST_GUARD_MARKER="$marker")
    if [[ "$mode" == force ]]; then
        args+=(--force)
        env_args+=(VW_FORCE_ACK=I_UNDERSTAND_LOSING_OLD_BACKUPS)
    fi
    set +e
    env "${env_args[@]}" bash "$GUARD_ROOT/setup.sh" "${args[@]}" </dev/null >"$TMP/$mode.out" 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 75 ]] || fail "$mode setup guard returned $rc instead of 75"
    [[ -s "$marker" ]] || fail "$mode setup did not invoke operation_acquire"
    grep -Fq -- '--id setup --label Setup --specific-lock /run/lock/vaultwarden-setup.lock' "$marker" \
        || fail "$mode setup invoked operation_acquire with unexpected arguments"
done
cmp -s "$TMP/guard-normal" "$TMP/guard-force" \
    || fail "--force changed setup operation guard acquisition"
pass "--force remains independent of the shared operation guard"
)

check_setup_force_acknowledgement
