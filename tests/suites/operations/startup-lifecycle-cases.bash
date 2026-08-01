# shellcheck shell=bash

pass_normal="normal startup validates without repair, cleanup, DNS mutation, NAT mutation, or image pull"
printf 'PASS %s\n' "$pass_normal"

run_startup VW_TEST_PERMISSION_DRIFT=1
(( STARTUP_RC != 0 )) || fail "permission drift did not fail normal startup"
assert_contains "$(cat "$OUTPUT")" 'sudo ./utilities/repair-permissions.sh' \
  "permission drift omitted exact repair command"
assert_contains "$(cat "$OUTPUT")" 'sudo ./startup.sh --repair' \
  "permission drift omitted startup repair command"
assert_no_compose_start "permission drift"

run_startup VW_TEST_ORPHAN_ROW=$'abc123\tremoved-service\trunning\tvaultwarden_old'
(( STARTUP_RC != 0 )) || fail "conflicting managed orphan did not fail normal startup"
assert_contains "$(cat "$OUTPUT")" 'sudo ./startup.sh --repair' \
  "orphan conflict omitted repair command"
! grep -q '^docker:rm ' "$INVOCATIONS" || fail "normal startup removed a managed orphan"
assert_no_compose_start "managed orphan conflict"

run_startup VW_TEST_NAT_MISSING=1
(( STARTUP_RC != 0 )) || fail "missing NAT did not fail normal startup"
assert_contains "$(cat "$OUTPUT")" 'sudo ./utilities/setup-firewall.sh --phase iptables --auto' \
  "missing NAT omitted exact firewall repair command"
assert_no_compose_start "missing NAT"

run_startup VW_TEST_DNS_UNRESOLVED=1
(( STARTUP_RC != 0 )) || fail "unresolved DNS did not fail normal startup"
assert_contains "$(cat "$OUTPUT")" 'sudo ./utilities/maintenance-update-dns.sh' \
  "unresolved DNS omitted exact DNS repair command"
! grep -q '^dns-repair$' "$INVOCATIONS" || fail "normal startup called DNS mutation implementation"
assert_no_compose_start "unresolved DNS"

run_startup VW_TEST_MISSING_IMAGE=postfix:1.0
(( STARTUP_RC != 0 )) || fail "missing local image did not fail normal startup"
assert_contains "$(cat "$OUTPUT")" 'sudo ./utilities/maintenance-update.sh --images' \
  "missing image omitted exact acquisition command"
! grep -Eq '^docker:(compose pull|pull )' "$INVOCATIONS" || fail "missing-image startup attempted a pull"
assert_no_compose_start "missing image"

run_startup VW_TEST_ORPHAN_ROW=$'abc123\tremoved-service\texited\tvaultwarden_old' --repair
(( STARTUP_RC == 0 )) || fail "explicit repair startup failed: $(cat "$OUTPUT")"
for required in 'operation-acquire:--id startup --label Startup repair' permission-repair 'docker:rm -f -- abc123' nat-repair dns-repair 'docker:compose up -d --pull never'; do
  grep -Fq "$required" "$INVOCATIONS" || fail "explicit repair omitted: $required"
done
line_guard="$(grep -n -m1 '^operation-acquire:--id startup --label Startup repair ' "$INVOCATIONS" | cut -d: -f1)"
line_permission="$(grep -n -m1 '^permission-repair$' "$INVOCATIONS" | cut -d: -f1)"
line_orphan="$(grep -n -m1 '^docker:rm -f -- abc123$' "$INVOCATIONS" | cut -d: -f1)"
line_nat="$(grep -n -m1 '^nat-repair$' "$INVOCATIONS" | cut -d: -f1)"
line_dns="$(grep -n -m1 '^dns-repair$' "$INVOCATIONS" | cut -d: -f1)"
line_start="$(grep -n -m1 '^docker:compose up ' "$INVOCATIONS" | cut -d: -f1)"
[[ "$line_guard" -lt "$line_permission" && "$line_permission" -lt "$line_orphan" \
   && "$line_orphan" -lt "$line_nat" && "$line_nat" -lt "$line_dns" \
   && "$line_dns" -lt "$line_start" ]] \
  || fail "explicit repair order is not guard -> permission -> orphan -> NAT -> DNS -> start"
! grep -Eq '^docker:(compose pull|pull )' "$INVOCATIONS" || fail "repair mode silently updated images"
! grep -Eq '^docker:.*prune' "$INVOCATIONS" || fail "repair mode invoked broad Docker cleanup"

for failure_case in permission orphan nat dns; do
  case "$failure_case" in
    permission) args=(VW_TEST_FAIL_PERMISSION_REPAIR=1 --repair) ;;
    orphan) args=(VW_TEST_ORPHAN_ROW=$'abc123\tremoved-service\texited\tvaultwarden_old' VW_TEST_FAIL_ORPHAN_REPAIR=1 --repair) ;;
    nat) args=(VW_TEST_FAIL_NAT_REPAIR=1 --repair) ;;
    dns) args=(VW_TEST_FAIL_DNS_REPAIR=1 --repair) ;;
  esac
  run_startup "${args[@]}"
  (( STARTUP_RC != 0 )) || fail "$failure_case repair failure returned success"
  assert_no_compose_start "$failure_case repair failure"
done
printf 'PASS explicit repair is guarded, ordered, fail-fast, and excludes image updates\n'

bash -n "${ROOT}/startup.sh" || fail "startup.sh must pass Bash syntax validation"
printf 'PASS startup lifecycle hardening contracts\n'
