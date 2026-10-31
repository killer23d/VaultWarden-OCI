#!/usr/bin/env bash
# Read-only Gate A2 failure diagnostics. Never rerun setup, format, or repair.
set -Eeuo pipefail
umask 077

[ "$(id -un)" = ubuntu ] && [ "$(hostname -s)" = vaultwarden-oci-5-vnic ] || {
  echo "BLOCKED: Run as ubuntu on the original disposable acceptance VM"; exit 1;
}
[ "$#" -eq 1 ] || { echo "Usage: $0 /home/ubuntu/vwoci-acceptance/gate-a2-install-TIMESTAMP"; exit 1; }

CASE="$1"
case "$CASE" in
  "$HOME"/vwoci-acceptance/gate-a2-install-*) ;;
  *) echo "BLOCKED: Expected an existing Gate A2 evidence directory"; exit 1 ;;
esac
[ -d "$CASE" ] && [ ! -L "$CASE" ] || { echo "BLOCKED: Evidence directory missing"; exit 1; }
LOG="$CASE/install.private.log"
OLD="$CASE/summary.txt"
[ -f "$LOG" ] && [ ! -L "$LOG" ] && [ -f "$OLD" ] && [ ! -L "$OLD" ] || {
  echo "BLOCKED: Expected installer log and summary are missing"; exit 1;
}
sudo -n true >/dev/null 2>&1 || { echo "BLOCKED: sudo -n unavailable"; exit 1; }

OUT="$HOME/vwoci-acceptance/gate-a2-failure-review-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$OUT"
REPORT="$OUT/summary.txt"
: > "$REPORT"
chmod 600 "$REPORT"
report() { printf '%s\n' "$*" | tee -a "$REPORT"; }

report "=== Installer status ==="
report "UTC=$(date -u --iso-8601=seconds)"
report "installer_log_bytes=$(stat -c %s "$LOG")"
report "installer_log_mtime=$(stat -c %y "$LOG" | cut -d . -f 1)"
grep -E '^(PASS|FAIL|BLOCKED|INFO|NOT RUN)[[:space:]]' "$OLD" | tail -n 16 | tee -a "$REPORT" || true

# Private log contents are NEVER printed. Only deterministic categories are
# calculated from its text and shown, excluding all free-form input/credentials.
report ""
report "=== Private install log: safe classifications ==="
python3 -B - "$LOG" <<'PY' | tee -a "$REPORT"
from pathlib import Path
import re
import sys
path = Path(sys.argv[1])
with path.open("rb") as f:
    f.seek(0, 2)
    size = f.tell()
    f.seek(max(0, size - 2_000_000))
    log = f.read().decode("utf-8", errors="replace")
lower = log.lower()
stages = [
    ("host_preflight", "host and dedicated storage preflight"),
    ("age_bootstrap", "offline recovery custody"),
    ("dependencies", "dependencies"),
    ("immutable_install", "immutable application install"),
]
print("stages=" + (",".join(name for name, phrase in stages if phrase in lower) or "none"))
fail_lines = [line for line in log.splitlines() if re.match(r"^\s*FAIL[: \t]", line)]
print("fail_markers=" + str(len(fail_lines)))
categories = [
    ("age_preflight", ("age recovery tooling",)),
    ("apt_update", ("apt package index refresh",)),
    ("ubuntu_dependencies", ("ubuntu dependency installation",)),
    ("docker_repo", ("docker repository",)),
    ("docker_install", ("docker engine/compose installation",)),
    ("sops", ("sops",)),
    ("storage", ("dedicated storage",)),
    ("pin_validation", ("runtime pin",)),
    ("release_install", ("immutable application",)),
    ("age_identity", ("operational age",)),
    ("secrets", ("encrypted secrets",)),
]
for line in fail_lines[-4:]:
    low = line.lower()
    print("failure_category=" + next((k for k, markers in categories
          if any(mark in low for mark in markers)), "unclassified"))
errors = [
    ("stopped_or_signalled", ("stopped", "signal", "interrupted", "terminated")),
    ("apt_or_dpkg_lock", ("could not get lock", "waiting for cache lock", "unable to acquire")),
    ("dns_resolution", ("temporary failure resolving", "could not resolve")),
    ("network_timeout", ("connection timed out", "network is unreachable", "connection refused")),
    ("tls_error", ("certificate verify failed", "ssl certificate problem")),
    ("repository_gpg_error", ("no_pubkey", "gpg error", "not signed")),
    ("missing_package", ("unable to locate package", "no installation candidate")),
    ("http_error", ("404 not found", "403 forbidden", "503 service unavailable")),
    ("no_space", ("no space left on device",)),
]
flags = [k for k, patterns in errors if any(x in lower for x in patterns)]
print("failure_indicators=" + (",".join(flags) if flags else "none-recognized"))
print("raw_log=PRIVATE_NOT_PRINTED")
PY

report ""
report "=== Package processes (names/states, no command arguments) ==="
ps -eo pid,ppid,stat,etime,comm |
  awk 'NR==1 || $5 ~ /^(apt-get|apt|dpkg|python3|curl|sops)$/ {print}' |
  tee -a "$REPORT"

report ""
report "=== Package database (read only) ==="
if sudo -n dpkg --audit > "$OUT/dpkg-audit.private.txt" 2>&1; then
  report "dpkg_audit_exit=0"
else
  report "dpkg_audit_exit=nonzero"
fi
[ -s "$OUT/dpkg-audit.private.txt" ] && report "dpkg_audit_has_issues=yes" ||
  report "dpkg_audit_has_issues=no"
for package in age 7zip nano rclone docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
  if dpkg -s "$package" 2>/dev/null | grep -q '^Status: install ok installed$'; then
    report "package_$package=installed"
  else
    report "package_$package=absent-or-incomplete"
  fi
done

report ""
report "=== Disk and appliance presence (read only) ==="
DEVICE=/dev/disk/by-id/scsi-36015f8fecf5e4f7ab864af5a651cc628
if [ -L "$DEVICE" ]; then
  resolved="$(readlink -e "$DEVICE")"
  report "data_device=$resolved"
  report "data_fstype=$(lsblk -dn -o FSTYPE "$resolved" | tr -d '[:space:]')"
else
  report "data_device=missing"
fi
if findmnt -rn -M /var/lib/vaultwarden-oci -o SOURCE,FSTYPE,TARGET \
  > "$OUT/appliance-mount.txt" 2>/dev/null; then
  report "dedicated_mount=present"
  cat "$OUT/appliance-mount.txt" | tee -a "$REPORT"
else
  report "dedicated_mount=absent"
fi
for p in /opt/vaultwarden-oci/current /etc/vaultwarden-oci/config.toml \
  /etc/vaultwarden-oci/age-key.txt /etc/vaultwarden-oci/secrets.sops.yaml \
  /etc/vaultwarden-oci/storage-identity.json; do
  if sudo -n test -e "$p" || sudo -n test -L "$p"; then
    report "$p=present"
  else
    report "$p=absent"
  fi
done
for unit in vaultwarden-oci.target vaultwarden-oci.service vaultwarden-oci-dns.service vaultwarden-oci-backup.timer; do
  report "$unit=$(systemctl is-active "$unit" 2>/dev/null || true)"
done
report ""
report "NOT RUN: package repair, installer retry, disk format, application start, restore, DNS write"
report "Private installer log and dpkg audit are NOT for sharing."
report "Share this diagnostic summary: $REPORT"
