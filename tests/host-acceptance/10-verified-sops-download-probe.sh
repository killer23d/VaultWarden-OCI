#!/usr/bin/env bash
# Gate A2: bounded, unprivileged SOPS GET + official pin verification.
# NOT an installer. Never changes /usr/local/bin, /opt, /etc, storage, or timers.
set -Eeuo pipefail
umask 077

BASE="e0f961c9093e98139e4f57bc94c49c9b79bbc386"
BRANCH="audit/rc11-ubuntu2604-arm64-production-readiness"
EXPECTED_HOST="vaultwarden-oci-5-vnic"
SOPS_URL="https://github.com/getsops/sops/releases/download/v3.13.3/sops-v3.13.3.linux.arm64"
EXPECTED_SHA="53b0abacd38ef1b12a66d6c100956691b9cefce018d91f81e73ddf7438b94d77"
EXPECTED_SIZE="48300194"
SOURCE="$(cd "$(dirname "$0")/../.." && pwd -P)"
ROOT="$HOME/vwoci-acceptance"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$ROOT/gate-a2-sops-get-$STAMP"
mkdir -m 700 "$OUT"
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"
chmod 600 "$SUMMARY"
FILE="$OUT/.verified-sops-candidate"
cleanup() { rm -f -- "$FILE"; }
trap cleanup EXIT
say() { printf '%s\n' "$*" | tee -a "$SUMMARY"; }
block() { say "BLOCKED: $*"; exit 1; }

[ "$#" -eq 0 ] || block "No command-line arguments are accepted"
[ "$(id -un)" = ubuntu ] && [ "$(hostname -s)" = "$EXPECTED_HOST" ] ||
  block "Run only as ubuntu on the disposable acceptance VM"
[ "$(git -C "$SOURCE" branch --show-current)" = "$BRANCH" ] ||
  block "Wrong audit branch"
git -C "$SOURCE" cat-file -e "$BASE^{commit}" 2>/dev/null ||
  block "Approved rc.11 baseline unavailable"
git -C "$SOURCE" merge-base --is-ancestor "$BASE" HEAD ||
  block "Audit branch is not descended from approved rc.11"
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ] ||
  block "Uncommitted tracked checkout modifications"
for binary in curl sha256sum stat python3 chmod; do
  command -v "$binary" >/dev/null 2>&1 || block "Required host tool missing: $binary"
done

# Inspect setup source literal pin without installing or executing the source.
if ! python3 -B - "$SOURCE/vaultwarden_oci/setup.py" "$EXPECTED_SHA" <<'PY'
import ast
import sys
source = open(sys.argv[1], encoding="utf-8").read()
tree = ast.parse(source)
found = None
for node in tree.body:
    if isinstance(node, ast.Assign):
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == "SOPS_SHA256":
                found = ast.literal_eval(node.value)
if not isinstance(found, dict) or found.get("arm64") != sys.argv[2]:
    raise SystemExit(1)
PY
then block "Checked-in ARM64 SOPS SHA-256 differs from the official pinned release"; fi

say "=== Bound SOPS 3.13.3 ARM64 binary download (unprivileged) ==="
say "UTC=$(date -u --iso-8601=seconds)"
say "source_release_pin=matches_official_3.13.3_arm64"
say "expected_size_bytes=$EXPECTED_SIZE"
say "expected_sha256=$EXPECTED_SHA"
say "download_max_time_seconds=180"
say "download_stall_abort=30s_below_16KiB_per_second"
say "binary_install=FORBIDDEN"

# No retries here: capture an actual bounded GET result after the earlier HEAD
# passed. Keep transport diagnostics private rather than copying raw text.
if curl --fail --location --silent --show-error \
    --connect-timeout 10 --max-time 180 --speed-time 30 --speed-limit 16384 \
    --output "$FILE" "$SOPS_URL" 2> "$OUT/curl.private.stderr"; then
  say "curl_get_exit=0"
else
  RESULT=$?
  say "curl_get_exit=$RESULT"
  say "curl_get_completed=false"
  say "binary_installed=false"
  say "raw_curl_error=PRIVATE_NOT_PRINTED"
  say "No binary preserved; no installer retry performed."
  say "Evidence: $SUMMARY"
  exit 1
fi

ACTUAL_SIZE="$(stat -c %s "$FILE")"
ACTUAL_SHA="$(sha256sum "$FILE" | cut -d ' ' -f 1)"
say "download_bytes=$ACTUAL_SIZE"
say "actual_sha_matches_official=$([ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] && echo true || echo false)"
[ "$ACTUAL_SIZE" = "$EXPECTED_SIZE" ] ||
  block "SOPS download byte size differs from verified official release; candidate will be deleted"
[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] ||
  block "SOPS download SHA-256 differs from approved pin; candidate will be deleted"

chmod 700 "$FILE"
if "$FILE" --version > "$OUT/sops-version.private.txt" 2>&1; then
  say "verified_sops_binary_executes=true"
else
  say "verified_sops_binary_executes=false"
  block "SHA-verified SOPS download did not execute properly"
fi

say "PASS: Official pinned SOPS 3.13.3 ARM64 binary downloaded and verified in a temporary user directory."
say "candidate_deleted_on_exit=true"
say "NOT RUN: SOPS installation, setup resume, disk formatting, restore, DNS and timers."
say "Evidence: $SUMMARY"
