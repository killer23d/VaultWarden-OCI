#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/log.sh"
source "$ROOT/lib/defaults.sh"
source "$ROOT/lib/config.sh"
source "$ROOT/lib/recovery.sh"
source "$ROOT/lib/secrets.sh"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass(){ echo "ok - $1"; }
fail_case(){ local name=$1 body=$2; if bash -c "source '$ROOT/lib/log.sh'; source '$ROOT/lib/defaults.sh'; source '$ROOT/lib/config.sh'; $body" >/dev/null 2>&1; then echo "not ok - $name"; exit 1; else pass "$name"; fi; }

cat > "$tmp/good.env" <<'E'
DOMAIN=example.com
ADMIN_EMAIL='admin@example.com'
NAME="value with spaces !@#"
PLAIN=a b c
E
load_install_env "$tmp/good.env"; [[ "$DOMAIN" == example.com && "$ADMIN_EMAIL" == admin@example.com && "$NAME" == 'value with spaces !@#' && "$PLAIN" == 'a b c' ]]; pass "install.env valid values"
fail_case malformed "load_install_env '$tmp/bad.env'" || true
printf 'badline\n' > "$tmp/bad.env"; if load_install_env "$tmp/bad.env" >/dev/null 2>&1; then exit 1; fi; pass malformed
printf 'bad_key=x\n' > "$tmp/bad.env"; if load_install_env "$tmp/bad.env" >/dev/null 2>&1; then exit 1; fi; pass invalid-key
printf 'DOMAIN=a\nDOMAIN=b\n' > "$tmp/bad.env"; if load_install_env "$tmp/bad.env" >/dev/null 2>&1; then exit 1; fi; pass duplicate
printf 'API_TOKEN=x\n' > "$tmp/bad.env"; if load_install_env "$tmp/bad.env" >/dev/null 2>&1; then exit 1; fi; pass credential-key
printf 'DOMAIN=$(id)\n' > "$tmp/bad.env"; if load_install_env "$tmp/bad.env" >/dev/null 2>&1; then exit 1; fi; pass command-substitution
printf 'DOMAIN=`id`\n' > "$tmp/bad.env"; if load_install_env "$tmp/bad.env" >/dev/null 2>&1; then exit 1; fi; pass backticks
printf 'DOMAIN=${HOME}\n' > "$tmp/bad.env"; if load_install_env "$tmp/bad.env" >/dev/null 2>&1; then exit 1; fi; pass brace-expansion

state="$tmp/state"; mkdir -p "$state/config" "$state/secrets"; printf 'DOMAIN=example.com\n' > "$state/config/install.env"; printf 'x' > "$state/secrets/secrets.sops.yaml"
printf 'STATE_LAYOUT_VERSION=1\nEXPECTED_STATE_DIR=%s\nINSTALLATION_ID=a\n' "$state" > "$state/config/dr-manifest.env"; printf 'INSTALLATION_ID=a\n' > "$state/.vw-state-volume"; if validate_state_manifest "$state" false >/dev/null 2>&1; then exit 1; fi; pass layout-version-rejection
rm "$state/config/dr-manifest.env"; if validate_state_manifest "$state" false >/dev/null 2>&1; then exit 1; fi; pass missing-manifest
printf 'STATE_LAYOUT_VERSION=2\nEXPECTED_STATE_DIR=%s\nINSTALLATION_ID=a\n' "$state" > "$state/config/dr-manifest.env"; rm "$state/.vw-state-volume"; if validate_state_manifest "$state" false >/dev/null 2>&1; then exit 1; fi; pass missing-sentinel
printf 'INSTALLATION_ID=b\n' > "$state/.vw-state-volume"; if validate_state_manifest "$state" false >/dev/null 2>&1; then exit 1; fi; pass mismatched-installation-id
printf 'STATE_LAYOUT_VERSION=2\nEXPECTED_STATE_DIR=/wrong\nINSTALLATION_ID=b\n' > "$state/config/dr-manifest.env"; if validate_state_manifest "$state" false >/dev/null 2>&1; then exit 1; fi; pass expected-path-mismatch
printf 'STATE_LAYOUT_VERSION=2\nEXPECTED_STATE_DIR=%s\nINSTALLATION_ID=b\n' "$state" > "$state/config/dr-manifest.env"; validate_state_manifest "$state" false; pass valid-manifest
if validate_state_manifest "$state" true >/dev/null 2>&1; then exit 1; fi; pass mocked-non-mount-rejection

mkdir -p "$tmp/proc"; printf '1 1 0:1 / /run rw - tmpfs tmpfs rw\n' > "$tmp/mountinfo"; VW_TEST_MOUNTINFO_FILE="$tmp/mountinfo" vw_run_is_tmpfs /run; pass tmpfs-detection
printf '1 1 0:1 / /run rw - ext4 /dev/sda rw\n' > "$tmp/mountinfo"; if VW_TEST_MOUNTINFO_FILE="$tmp/mountinfo" vw_run_is_tmpfs /run; then exit 1; fi; pass mocked-non-tmpfs-rejection

BACKUP_RETENTION_DAYS=30 backup_rotation_allowed ""; pass first-rotation-no-previous
if BACKUP_RETENTION_DAYS=30 backup_rotation_allowed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1; then exit 1; fi; pass rotation-blocked-window
if BACKUP_RETENTION_DB_DAYS=0 backup_rotation_allowed "" >/dev/null 2>&1; then exit 1; fi; pass rotation-blocked-zero

echo "resilient-state tests passed"
