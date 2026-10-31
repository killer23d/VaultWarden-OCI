#!/usr/bin/env bash
# Gate A2 SOPS failure: bounded READ-ONLY diagnosis of partial install.
# No install retry, apt-get, formatting, service start, DNS mutation, or key extraction.
set -Eeuo pipefail
umask 077

BASE="e0f961c9093e98139e4f57bc94c49c9b79bbc386"
BRANCH="audit/rc11-ubuntu2604-arm64-production-readiness"
EXPECTED_HOST="vaultwarden-oci-5-vnic"
BYID="/dev/disk/by-id/scsi-36015f8fecf5e4f7ab864af5a651cc628"
EXPECTED_SHA="53b0abacd38ef1b12a66d6c100956691b9cefce018d91f81e73ddf7438b94d77"
URL="https://github.com/getsops/sops/releases/download/v3.13.3/sops-v3.13.3.linux.arm64"
SOURCE="$(cd "$(dirname "$0")/../.." && pwd -P)"
EVIDENCE="$HOME/vwoci-acceptance"
OUT="$EVIDENCE/gate-a2-sops-diagnostic-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"
chmod 700 "$OUT"
REPORT="$OUT/summary.txt"
: > "$REPORT"
chmod 600 "$REPORT"
say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
block() { say "BLOCKED: $*"; say "No repair or installer rerun performed."; exit 1; }

[ "$#" -eq 1 ] || block "Pass the exact original Gate A2 evidence directory"
[ "$(id -un)" = ubuntu ] && [ "$(hostname -s)" = "$EXPECTED_HOST" ] ||
  block "Only run as ubuntu on the known disposable host"
[ "$(git -C "$SOURCE" branch --show-current)" = "$BRANCH" ] ||
  block "Not on the dedicated audit branch"
git -C "$SOURCE" cat-file -e "$BASE^{commit}" 2>/dev/null ||
  block "Approved source commit missing"
git -C "$SOURCE" merge-base --is-ancestor "$BASE" HEAD ||
  block "Audit checkout is not descended from approved rc.11"
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ] ||
  block "Audit checkout has uncommitted tracked modifications"
case "$1" in
  "$EVIDENCE"/gate-a2-install-*) ;;
  *) block "Only an existing absolute gate-a2-install-* evidence directory under the login user is accepted" ;;
esac
CASE="$1"
[ -d "$CASE" ] && [ ! -L "$CASE" ] || block "Specified evidence directory missing or symlink"
LOG="$CASE/install.private.log"
[ -f "$LOG" ] && [ ! -L "$LOG" ] || block "Original private installer log missing"
sudo -n true >/dev/null 2>&1 || block "Passwordless sudo unavailable"

say "=== SOPS install failure (read-only) ==="
say "UTC=$(date -u --iso-8601=seconds)"
say "original_install_log_bytes=$(stat -c %s "$LOG")"
say "audit_commit=$(git -C "$SOURCE" rev-parse HEAD)"
say "official_release_version=3.13.3"
say "official_linux_arm64_sha256=$EXPECTED_SHA"

# No free-form log content is printed: report only recognized static stage,
# the numeric curl error code and presence of any optional HTTP status code.
python3 -B - "$LOG" "$SOURCE/vaultwarden_oci/setup.py" "$EXPECTED_SHA" <<'PY' | tee -a "$REPORT"
import pathlib
import re
import sys

log_path = pathlib.Path(sys.argv[1])
setup_path = pathlib.Path(sys.argv[2])
expected_sha = sys.argv[3]
raw = log_path.read_bytes()
if len(raw) > 2_000_000:
    raw = raw[-2_000_000:]
log = raw.decode("utf-8", errors="replace")
# Installer UI writes "FAIL <message>", not necessarily "FAIL: <message>".
# Preserve only a fixed classification; never echo raw log text.
lines = log.splitlines()
fail_offsets = [
    idx for idx, line in enumerate(lines)
    if re.match(r"^\s*(?:\x1b\[[0-9;]*m)?FAIL(?:[ \t]|:)", line, re.I)
]
print("original_failure_markers=" + str(len(fail_offsets)))
if not fail_offsets:
    print("failure_stage=UNKNOWN_NO_FAIL_MARKER")
    print("curl_exit_code=NOT_IN_ERROR_BLOCK")
    print("http_error_code=NOT_IN_ERROR_BLOCK")
else:
    last_index = fail_offsets[-1]
    last = lines[last_index].strip()
    # _must() embeds stderr, which may span multiple log lines after FAIL.
    # Restrict to the final failure block, not unrelated earlier output.
    failure = "\n".join(lines[last_index:])
    if re.search(r"SOPS\s+3\.13\.3\s+download\s+failed", last, re.I):
        category = "SOPS_DOWNLOAD_FAILED"
    elif re.search(r"SOPS\s+3\.13\.3\s+SHA-256\s+verification\s+failed", last, re.I):
        category = "SOPS_CHECKSUM_MISMATCH"
    elif re.search(r"dependency verification failed:\s*SOPS", last, re.I):
        category = "SOPS_EXECUTION_CHECK_FAILED"
    elif "SOPS" in last:
        category = "OTHER_SOPS_ERROR"
    else:
        category = "NOT_SOPS_FAILURE"
    print("failure_stage=" + category)
    matches = re.findall(r"\bcurl:\s*\((\d+)\)", failure, re.I)
    print("curl_exit_code=" + (matches[-1] if matches else "NOT_IN_ERROR_BLOCK"))
    http = re.search(r"\b(?:HTTP\s+|status(?:\s+code)?\s*[=:]?\s*)(4\d\d|5\d\d)\b", failure, re.I)
    print("http_error_code=" + (http.group(1) if http else "NOT_IN_ERROR_BLOCK"))
    for label, terms in (
        ("resolution_error", ("could not resolve host", "temporary failure resolving")),
        ("connection_timeout", ("timed out", "timeout was reached")),
        ("tls_error", ("SSL certificate problem", "certificate verify failed")),
        ("connection_closed", ("transfer closed", "connection reset")),
        ("disk_io_error", ("failed writing received data", "no space left on device")),
        ("permission_error", ("permission denied", "operation not permitted")),
    ):
        print(label + "=" + str(any(term.lower() in failure.lower() for term in terms)).lower())
source = setup_path.read_text(encoding="utf-8")
m = re.search(r'(?s)SOPS_SHA256\s*=\s*\{(.{0,500}?)\}', source)
pin = re.search(r'"arm64"\s*:\s*"([0-9a-f]{64})"', m.group(1)) if m else None
print("checked_in_sops_sha_matches_official=" +
      str(bool(pin and pin.group(1) == expected_sha)).lower())
print("installer_log=PRIVATE_NOT_PRINTED")
PY

say ""
say "=== Installed SOPS status (read-only) ==="
if sudo -n test -f /usr/local/bin/sops; then
  say "sops_file=present"
  sudo -n sha256sum /usr/local/bin/sops | awk -v expected="$EXPECTED_SHA" \
    '{print "installed_sops_sha_matches_expected=" ($1 == expected ? "true" : "false")}' |
    tee -a "$REPORT"
  if sudo -n /usr/local/bin/sops --version >/dev/null 2>&1; then
    say "sops_binary_executes=true"
  else
    say "sops_binary_executes=false"
  fi
else
  say "sops_file=absent"
fi

say ""
say "=== Dedicated volume continuity (read-only) ==="
[ -L "$BYID" ] || block "Selected OCI volume alias disappeared"
say "selected_disk=$(readlink -e "$BYID")"
if sudo -n python3 -B -E - "$SOURCE" <<'PY' > "$OUT/storage-status.private.txt" 2>&1
import sys
sys.path.insert(0, sys.argv[1])
from vaultwarden_oci import storage
identity = storage.verify()
if identity.fs_type != "ext4":
    raise SystemExit("unexpected filesystem type")
print("dedicated_storage_identity_and_marker=PASS")
PY
then
  say "dedicated_storage_identity_and_marker=PASS"
else
  say "dedicated_storage_identity_and_marker=FAIL"
fi
for path in /opt/vaultwarden-oci/current \
  /etc/vaultwarden-oci/config.toml \
  /etc/vaultwarden-oci/secrets.sops.yaml; do
  if sudo -n test -e "$path" || sudo -n test -L "$path"; then
    say "$path=present"
  else
    say "$path=absent"
  fi
done

say ""
say "=== Optional, bounded GitHub SOPS URL HEAD check ==="
if command -v curl >/dev/null 2>&1; then
  set +e
  CODE="$(curl --location --head --silent --show-error \
    --connect-timeout 5 --max-time 20 \
    --output "$OUT/sops-head.private.txt" \
    --write-out '%{http_code}' "$URL" 2> "$OUT/sops-head.stderr")"
  RC=$?
  set -e
  case "$CODE" in
    [0-9][0-9][0-9]) ;;
    *) CODE="unknown" ;;
  esac
  say "sops_head_http_status=$CODE"
  say "sops_head_curl_exit=$RC"
  say "sops_head_does_not_verify_full_binary_download=true"
else
  say "sops_head=NOT_RUN_curl_missing"
fi

say ""
say "NOT RUN: installer retry, SOPS binary download, apt repair, formatting, restore, DNS mutation"
say "Evidence directory: $OUT"
say "Share only summary.txt or the displayed output, not *.private.txt or the raw installer log."
