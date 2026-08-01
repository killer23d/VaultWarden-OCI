# shellcheck shell=bash

MOCK_BIN="$TMP/startup-mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/docker" <<'EOF_DOCKER'
#!/usr/bin/env bash
printf 'docker:%s\n' "$*" >> "${VW_TEST_INVOCATION_LOG:?}"
case "${1:-}:${2:-}:${3:-}" in
  info::) exit 0 ;;
  compose:config:--services)
    printf 'vaultwarden\ncaddy\npostfix\n'
    exit 0
    ;;
  compose:config:--images)
    printf 'vaultwarden/server:1.0\nvaultwarden-oci-caddy\npostfix:1.0\n'
    exit 0
    ;;
  ps:-a:--filter)
    [[ -n "${VW_TEST_ORPHAN_ROW:-}" ]] && printf '%b\n' "$VW_TEST_ORPHAN_ROW"
    exit 0
    ;;
  image:inspect:*)
    [[ "${3:-}" != "${VW_TEST_MISSING_IMAGE:-}" ]]
    exit $?
    ;;
  rm:-f:--)
    [[ "${VW_TEST_FAIL_ORPHAN_REPAIR:-0}" != "1" ]]
    exit $?
    ;;
  compose:up:*) exit 0 ;;
esac
if [[ " $* " == *" pull "* || " $* " == *" prune "* || " $* " == *" system prune "* ]]; then
  exit 91
fi
exit 0
EOF_DOCKER
cat > "$MOCK_BIN/iptables" <<'EOF_IPTABLES'
#!/usr/bin/env bash
printf 'iptables:%s\n' "$*" >> "${VW_TEST_INVOCATION_LOG:?}"
if [[ " $* " == *" -A "* || " $* " == *" -D "* || " $* " == *" -I "* ]]; then
  exit 92
fi
[[ "${VW_TEST_NAT_MISSING:-0}" != "1" ]]
EOF_IPTABLES
cat > "$MOCK_BIN/getent" <<'EOF_GETENT'
#!/usr/bin/env bash
printf 'getent:%s\n' "$*" >> "${VW_TEST_INVOCATION_LOG:?}"
if [[ "${1:-}" == "ahosts" ]]; then
  [[ "${VW_TEST_DNS_UNRESOLVED:-0}" != "1" ]] && printf '203.0.113.10 STREAM %s\n' "${2:-}"
  [[ "${VW_TEST_DNS_UNRESOLVED:-0}" != "1" ]]
  exit $?
fi
exec /usr/bin/getent "$@"
EOF_GETENT
cat > "$MOCK_BIN/netfilter-persistent" <<'EOF_NETFILTER'
#!/usr/bin/env bash
printf 'netfilter-persistent:%s\n' "$*" >> "${VW_TEST_INVOCATION_LOG:?}"
exit 0
EOF_NETFILTER
cat > "$MOCK_BIN/python3" <<'EOF_PYTHON'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" && "${2:-}" == "import yaml" ]]; then
  exit 0
fi
exec /usr/bin/python3 "$@"
EOF_PYTHON
for command_name in chown chmod; do
  cat > "$MOCK_BIN/$command_name" <<EOF_MUTATION
#!/usr/bin/env bash
printf '${command_name}:%s\\n' "\$*" >> "\${VW_TEST_INVOCATION_LOG:?}"
exit 93
EOF_MUTATION
  chmod 0755 "$MOCK_BIN/$command_name"
done
chmod 0755 "$MOCK_BIN/docker" "$MOCK_BIN/iptables" "$MOCK_BIN/getent" "$MOCK_BIN/netfilter-persistent" "$MOCK_BIN/python3"

run_startup() {
  local arg
  local -a env_args=() startup_args=(--background)
  for arg in "$@"; do
    if [[ "$arg" == "--repair" ]]; then
      startup_args+=(--repair)
    else
      env_args+=("$arg")
    fi
  done
  : > "$INVOCATIONS"
  rm -rf "$FIXTURE/state"
  mkdir -p "$FIXTURE/state"
  printf 'AGE-SECRET-KEY-test\n' > "$FIXTURE/state/age-key.txt"
  printf 'encrypted\n' > "$FIXTURE/state/secrets.yaml"
  set +e
  env \
    PATH="$MOCK_BIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    VW_TEST_STATE_DIR="$FIXTURE/state" \
    VW_TEST_INVOCATION_LOG="$INVOCATIONS" \
    "${env_args[@]}" \
    bash "$FIXTURE/startup.sh" "${startup_args[@]}" >"$OUTPUT" 2>&1
  STARTUP_RC=$?
  set -e
}

assert_no_compose_start() {
  ! grep -q '^docker:compose up ' "$INVOCATIONS" || fail "$1 started Compose after a required failure"
  ! grep -q 'VaultWarden-OCI startup completed' "$OUTPUT" || fail "$1 printed startup success after failure"
}

run_startup
(( STARTUP_RC == 0 )) || fail "healthy normal startup failed: $(cat "$OUTPUT")"
! grep -q '^permission-repair$' "$INVOCATIONS" || fail "normal startup repaired permissions"
! grep -q '^nat-repair$' "$INVOCATIONS" || fail "normal startup invoked NAT repair"
! grep -q '^dns-repair$' "$INVOCATIONS" || fail "normal startup invoked DNS repair"
! grep -Eq '^docker:(rm|container prune|image prune|volume prune|network prune|system prune)' "$INVOCATIONS" \
  || fail "normal startup deleted Docker resources"
! grep -Eq '^docker:(compose pull|pull )' "$INVOCATIONS" || fail "normal startup pulled images"
! grep -Eq '^iptables:.* (-A|-D|-I) ' "$INVOCATIONS" || fail "normal startup modified iptables"
! grep -Eq '^(chown|chmod):' "$INVOCATIONS" || fail "normal startup ran corrective chown/chmod"
compose_up="$(grep '^docker:compose up ' "$INVOCATIONS" || true)"
[[ "$compose_up" == *"--pull never"* ]] || fail "normal startup did not pass --pull never"
[[ "$compose_up" != *"--remove-orphans"* ]] || fail "normal startup allowed implicit orphan deletion"
