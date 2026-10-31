#!/usr/bin/env bash
# Gate A2: Read-only exact failure classification, no raw log disclosure.
# Never install binaries, run apt, reformat, start Vaultwarden, or change DNS.
set -Eeuo pipefail
umask 077

SOURCE="$(cd "$(dirname "$0")/../.." && pwd -P)"
BRANCH="audit/rc11-ubuntu2604-arm64-production-readiness"
CASE="$HOME/vwoci-acceptance/gate-a2-install-20261030T210031Z"
LOG="$CASE/install.private.log"

[ "$#" -eq 0 ] || { echo "BLOCKED: No arguments supported"; exit 1; }
[ "$(id -un)" = ubuntu ] && [ "$(hostname -s)" = vaultwarden-oci-5-vnic ] || {
  echo "BLOCKED: Wrong host or login user"; exit 1;
}
[ "$(git -C "$SOURCE" branch --show-current)" = "$BRANCH" ] || {
  echo "BLOCKED: Not on the approved audit branch"; exit 1;
}
[ -f "$LOG" ] && [ ! -L "$LOG" ] || {
  echo "BLOCKED: Original private installer log missing"; exit 1;
}
[ "$(stat -c %s "$LOG")" -le 1000000 ] || {
  echo "BLOCKED: Unexpectedly large log; inspect privately"; exit 1;
}

python3 -B - "$LOG" <<'PY'
from pathlib import Path
import re
import sys

lines = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()
clean = lambda s: re.sub(r"\x1b\[[0-9;]*m", "", s).strip()
lines = [clean(s) for s in lines]
fail = [(i, s[5:].lstrip(": \t")) for i, s in enumerate(lines) if re.match(r"^FAIL(?:\s|:)", s, re.I)]
print("=== Exact failure classifier: SAFE ONLY ===")
print("failure_markers=" + str(len(fail)))
stages = {
    "host and dedicated storage preflight": "HOST_STORAGE",
    "dependencies": "DEPENDENCIES",
    "immutable application install": "IMMUTABLE_RELEASE",
    "next actions": "NEXT_ACTIONS",
}
header = next((stages.get(x.strip("= ").lower(), "OTHER") for x in reversed(lines) if x.startswith("== ") and x.endswith(" ==")), "UNKNOWN")
print("last_setup_section=" + header)
if not fail:
    print("failure_reason=UNKNOWN_NO_FAIL_MARKER")
    sys.exit(0)

index, message = fail[-1]
error_block = "\n".join(lines[index:]).lower()
low = message.lower()

# Match the fixed human-readable labels used by vaultwarden_oci/setup.py.
labels = [
    ("APT_INDEX_UPDATE", "apt package index refresh"),
    ("UBUNTU_DEPENDENCY_INSTALL", "ubuntu dependency installation"),
    ("DOCKER_KEY_DOWNLOAD", "docker repository key download"),
    ("DOCKER_APT_INDEX", "docker repository refresh"),
    ("DOCKER_PACKAGE_INSTALL", "docker engine/compose installation"),
    ("SOPS_DOWNLOAD", "sops 3.13.3 download"),
    ("SOPS_CHECKSUM", "sops 3.13.3 sha-256 verification"),
    ("AGE_INSTALL", "age recovery tooling installation"),
    ("AGE_RECIPIENT_DERIVE", "operational age recipient derivation"),
    ("AGE_IDENTITY_GENERATE", "operational age identity generation"),
    ("RESOLVED_RELEASE", "immutable release"),
    ("DOCKER_ENGINE_VERIFY", "dependency verification failed: docker engine"),
    ("DOCKER_COMPOSE_VERIFY", "dependency verification failed: docker compose"),
    ("SOPS_VERIFY", "dependency verification failed: sops"),
    ("AGE_VERIFY", "dependency verification failed: age"),
    ("NANO_VERIFY", "dependency verification failed: nano editor"),
    ("RCLONE_VERIFY", "dependency verification failed: rclone"),
    ("SEVENZIP_VERIFY", "dependency verification failed: 7-zip"),
    ("SECRET_INIT", "initial encrypted secrets creation"),
    ("STORAGE_PROVISION", "dedicated storage"),
]
found = next((name for name, text in labels if text in low), None)
if found is None:
    if "[errno" in low:
        found = "OS_ERROR"
    elif "storage" in low or "filesystem" in low:
        found = "STORAGE_OTHER"
    elif "sops" in low:
        found = "SOPS_OTHER"
    elif "docker" in low:
        found = "DOCKER_OTHER"
    elif "age" in low:
        found = "AGE_OTHER"
    else:
        found = "UNCLASSIFIED"
print("failure_reason=" + found)
print("failure_is_must_subprocess=" + str(" failed:" in low).lower())
if match := re.search(r"\bexit ([-]?[0-9]+)\b", error_block):
    print("subprocess_exit_code=" + match.group(1))
else:
    print("subprocess_exit_code=NOT_REPORTED")
if match := re.search(r"\bcurl:\s*\(([0-9]+)\)", error_block):
    print("curl_error_code=" + match.group(1))
else:
    print("curl_error_code=NOT_REPORTED")
if match := re.search(r"\[errno ([0-9]+)\]", error_block):
    print("os_errno=" + match.group(1))
else:
    print("os_errno=NOT_REPORTED")
indicators = {
    "stopped_or_interrupted": ("signal", "stopped", "interrupted", "terminated"),
    "download_failed": ("curl:", "failed to connect", "could not resolve", "download failed"),
    "disk_full": ("no space left on device",),
    "permission": ("permission denied", "operation not permitted"),
    "executable_missing": ("no such file or directory", "command not found"),
    "temp_directory": ("temporary", "tmp", "/tmp/"),
    "service_unavailable": ("service unavailable", "connection refused"),
}
for name, patterns in indicators.items():
    print("indicator_" + name + "=" + str(any(p in error_block for p in patterns)).lower())
print("failure_message_chars=" + str(len(message)))
print("full_error_text=PRIVATE_NOT_PRINTED")
print("no_mutations=true")
PY
