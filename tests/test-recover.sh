#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_ETC_SNAPSHOT="$(mktemp -d)"
TMP="$(mktemp -d)"
cleanup(){ rm -rf "$TMP" "$REAL_ETC_SNAPSHOT"; }
trap cleanup EXIT

if [[ -d /etc/vaultwarden ]]; then cp -a /etc/vaultwarden/. "$REAL_ETC_SNAPSHOT/" 2>/dev/null || true; fi

pass(){ printf 'ok - %s\n' "$1"; }
fail(){ printf 'not ok - %s\n' "$1" >&2; exit 1; }
assert_etc_unchanged(){ if [[ -d /etc/vaultwarden ]]; then diff -qr "$REAL_ETC_SNAPSHOT" /etc/vaultwarden >/dev/null 2>&1 || fail 'real /etc/vaultwarden changed'; fi; }
run_expect_fail(){ local name="$1"; shift; if "$@" >"$TMP/out" 2>&1; then cat "$TMP/out"; fail "$name"; fi; pass "$name"; }

run_expect_fail 'missing --state-dir fails with usage' bash "$ROOT/recover.sh" --key /nope
grep -q 'Usage: ./recover.sh --state-dir DIR --key FILE' "$TMP/out" || fail 'usage not printed'
run_expect_fail 'missing --key fails with usage' bash "$ROOT/recover.sh" --state-dir /nope
grep -q 'Usage: ./recover.sh --state-dir DIR --key FILE' "$TMP/out" || fail 'usage not printed'

MOCK="$TMP/mockbin"; mkdir -p "$MOCK"
cat > "$MOCK/mountpoint" <<'M'
#!/usr/bin/env bash
exit 1
M
chmod +x "$MOCK/mountpoint"
for c in findmnt sops age-keygen git install docker curl blkid; do cat > "$MOCK/$c" <<'M'
#!/usr/bin/env bash
if [[ "$(basename "$0")" == docker && "${1:-}" == compose && "${2:-}" == version ]]; then exit 0; fi
exit 0
M
chmod +x "$MOCK/$c"; done
run_expect_fail 'non-mounted state directory emits exact message' env PATH="$MOCK:$PATH" VW_RECOVER_ETC_DIR="$TMP/etc" VW_RECOVER_STARTUP_SCRIPT="$TMP/startup" bash "$ROOT/recover.sh" --state-dir "$TMP/state" --key "$TMP/key"
grep -q 'State directory is not a mounted volume. Attach the OCI block volume first.' "$TMP/out" || fail 'mount error text mismatch'

assert_etc_unchanged
pass 'real /etc/vaultwarden unchanged'
