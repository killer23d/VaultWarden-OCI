#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS %s\n' "$*"; }

[[ -f setup.sh ]] || fail "setup.sh is missing"
[[ -f lib/setup-main.sh ]] || fail "lib/setup-main.sh is missing"

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT INT TERM HUP
FIXTURE="$TMP/repo"
LOG="$TMP/invocations.log"
LOCK_GLOBAL="$TMP/vaultwarden-operations.lock"
LOCK_SETUP="$TMP/vaultwarden-setup.lock"
STATE_DIR="$TMP/operations"
mkdir -p "$FIXTURE/lib" "$FIXTURE/utilities" "$TMP/bin" "$STATE_DIR"
cp setup.sh "$FIXTURE/setup.sh"
chmod 0755 "$FIXTURE/setup.sh"
printf 'global-sentinel\n' > "$LOCK_GLOBAL"
printf 'setup-sentinel\n' > "$LOCK_SETUP"
chmod 0640 "$LOCK_GLOBAL" "$LOCK_SETUP"
GLOBAL_BEFORE="$(stat -c '%a:%s:%Y' "$LOCK_GLOBAL")"
SETUP_BEFORE="$(stat -c '%a:%s:%Y' "$LOCK_SETUP")"

cat > "$FIXTURE/lib/setup-main.sh" <<'EOF_CORE'
#!/usr/bin/env bash
printf 'core:%s\n' "$*" >> "${VW_TEST_LOG:?}"
exit "${VW_TEST_CORE_RC:-0}"
EOF_CORE

cat > "$FIXTURE/lib/log.sh" <<'EOF_LOG'
log_header() { printf 'HEADER %s\n' "$*"; }
log_info() { printf 'INFO %s\n' "$*"; }
log_warn() { printf 'WARN %s\n' "$*" >&2; }
log_error() { printf 'ERROR %s\n' "$*" >&2; }
log_success() { printf 'OK %s\n' "$*"; }
EOF_LOG
cat > "$FIXTURE/lib/validate.sh" <<'EOF_VALIDATE'
validate_domain() { [[ "$1" == *.* ]]; }
validate_email() { [[ "$1" == *@*.* ]]; }
EOF_VALIDATE
cat > "$FIXTURE/lib/config.sh" <<'EOF_CONFIG'
:
EOF_CONFIG
cat > "$FIXTURE/lib/common.sh" <<'EOF_COMMON'
init_common_lib() { :; }
EOF_COMMON
cat > "$FIXTURE/lib/operations.sh" <<'EOF_OPERATIONS'
operation_acquire() { printf 'operation_acquire:%s\n' "$*" >> "${VW_TEST_LOG:?}"; }
operation_set_phase() { printf 'operation_set_phase:%s\n' "$*" >> "${VW_TEST_LOG:?}"; }
operation_release() { printf 'operation_release:%s\n' "$*" >> "${VW_TEST_LOG:?}"; }
EOF_OPERATIONS
cat > "$FIXTURE/lib/docker.sh" <<'EOF_DOCKER'
pull_image_with_retry() { printf 'pull_image:%s\n' "$1" >> "${VW_TEST_LOG:?}"; }
EOF_DOCKER
cat > "$FIXTURE/lib/defaults.sh" <<'EOF_DEFAULTS'
readonly _VW_DEFAULT_DATA_MOUNT=/mnt/vw-data
EOF_DEFAULTS

cat > "$TMP/phase" <<'EOF_PHASE'
#!/usr/bin/env bash
printf '%s:%s\n' "$(basename "$0")" "$*" >> "${VW_TEST_LOG:?}"
exit 0
EOF_PHASE
chmod 0755 "$TMP/phase"
for phase in setup-system.sh setup-storage.sh setup-env.sh setup-secrets.sh setup-firewall.sh; do
  cp "$TMP/phase" "$FIXTURE/utilities/$phase"
done

cat > "$TMP/bin/getent" <<'EOF_GETENT'
#!/usr/bin/env bash
printf 'getent:%s\n' "$*" >> "${VW_TEST_LOG:?}"
if [[ "${VW_TEST_GROUP_EXISTS:-0}" == 1 ]]; then
  printf 'vaultwarden:x:999:\n'
  exit 0
fi
exit 2
EOF_GETENT
cat > "$TMP/bin/groupadd" <<'EOF_GROUPADD'
#!/usr/bin/env bash
printf 'groupadd:%s\n' "$*" >> "${VW_TEST_LOG:?}"
EOF_GROUPADD
cat > "$TMP/bin/docker" <<'EOF_DOCKER_CMD'
#!/usr/bin/env bash
printf 'docker:%s\n' "$*" >> "${VW_TEST_LOG:?}"
if [[ "${1:-}" == compose && "${2:-}" == config && "${3:-}" == --images ]]; then
  printf 'vaultwarden/server:1.0\nvaultwarden-oci-caddy\npostfix:1.0\n'
fi
EOF_DOCKER_CMD
for command_name in flock chown chmod systemctl iptables ip6tables ufw apt-get mount umount; do
  cat > "$TMP/bin/$command_name" <<EOF_MUTATION
#!/usr/bin/env bash
printf '${command_name}:%s\\n' "\$*" >> "\${VW_TEST_LOG:?}"
exit 97
EOF_MUTATION
done
chmod 0755 "$TMP/bin"/*

run_setup() {
  local group_exists="$1" mode="$2" output rc
  : > "$LOG"
  set +e
  output="$(sudo -n env \
    PATH="$TMP/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    VW_TEST_LOG="$LOG" VW_TEST_GROUP_EXISTS="$group_exists" \
    VW_OPERATIONS_LOCK="$LOCK_GLOBAL" VW_OPERATIONS_STATE_DIR="$STATE_DIR" \
    bash "$FIXTURE/setup.sh" install \
      --domain vault.example.com --email admin@example.com --auto --skip-deps "$mode" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$rc" > "$TMP/rc"
  printf '%s' "$output"
}

if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; then
  printf 'SKIP setup entrypoint behavior requires passwordless sudo\n'
  exit 0
fi

for group_exists in 0 1; do
  output="$(run_setup "$group_exists" --dry-run)"
  [[ "$(cat "$TMP/rc")" == 0 ]] || fail "full dry-run failed with group_exists=$group_exists: $output"
  [[ "$output" == *"Operation locks and operation state will not be acquired or created"* ]] || fail "dry-run omitted no-lock diagnostic"
  [[ "$output" == *"Would acquire the pinned Compose image set"* ]] || fail "dry-run omitted image preview"
  ! grep -Eq '^(groupadd|operation_acquire|flock|chown|chmod|systemctl|docker|iptables|ip6tables|ufw|apt-get|mount|umount):' "$LOG" \
    || fail "dry-run invoked prohibited mutation with group_exists=$group_exists: $(cat "$LOG")"
  grep -Eq '^setup-system\.sh:.*--dry-run' "$LOG" || fail "system phase missed --dry-run"
  grep -Eq '^setup-storage\.sh:.*--dry-run' "$LOG" || fail "storage phase missed --dry-run"
  grep -Eq '^setup-env\.sh:.*--dry-run' "$LOG" || fail "env phase missed --dry-run"
  grep -Eq '^setup-firewall\.sh:--phase ufw .*--dry-run' "$LOG" || fail "UFW phase missed --dry-run"
  grep -Eq '^setup-firewall\.sh:--phase iptables .*--dry-run' "$LOG" || fail "iptables phase missed --dry-run"
  ! grep -q '^setup-secrets\.sh:' "$LOG" || fail "dry-run executed secrets helper bootstrap state"
  [[ "$(stat -c '%a:%s:%Y' "$LOCK_GLOBAL")" == "$GLOBAL_BEFORE" ]] || fail "dry-run changed global lock metadata"
  [[ "$(stat -c '%a:%s:%Y' "$LOCK_SETUP")" == "$SETUP_BEFORE" ]] || fail "dry-run changed setup lock metadata"
  [[ -z "$(find "$STATE_DIR" -mindepth 1 -print -quit)" ]] || fail "dry-run created operation state"
done
pass "full setup dry-run is read-only without and with vaultwarden group"

: > "$LOG"
set +e
sudo -n env \
  PATH="$TMP/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  VW_TEST_LOG="$LOG" VW_TEST_GROUP_EXISTS=0 \
  bash "$FIXTURE/setup.sh" install \
    --domain vault.example.com --email admin@example.com --auto --skip-deps >/dev/null 2>&1
real_rc=$?
set -e
(( real_rc == 0 )) || fail "real setup fixture failed"

line_of() { grep -n -m1 "$1" "$LOG" | cut -d: -f1; }
getent_line="$(line_of '^getent:group vaultwarden')"
groupadd_line="$(line_of '^groupadd:--system vaultwarden')"
acquire_line="$(line_of '^operation_acquire:')"
core_line="$(line_of '^core:')"
config_line="$(line_of '^docker:compose config --images')"
[[ -n "$getent_line" && -n "$groupadd_line" && -n "$acquire_line" && -n "$core_line" && -n "$config_line" ]] \
  || fail "real setup ordering events missing: $(cat "$LOG")"
(( getent_line < groupadd_line && groupadd_line < acquire_line && acquire_line < core_line && core_line < config_line )) \
  || fail "real setup ordering is incorrect: $(cat "$LOG")"
grep -q '^docker:compose build --pull caddy$' "$LOG" || fail "first install did not build custom Caddy image"
grep -q '^pull_image:vaultwarden/server:1.0$' "$LOG" || fail "first install did not acquire Vaultwarden image"
grep -q '^pull_image:postfix:1.0$' "$LOG" || fail "first install did not acquire Postfix image"
pass "real setup preserves group-before-lock ordering and acquires initial pinned images"

pass "behavioral setup gates and bootstrap loading"
