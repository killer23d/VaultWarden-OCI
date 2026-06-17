#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOPS_CONFIG_FILE="${SCRIPT_DIR}/.sops.yaml"
VW_ETC_DIR="${VW_RECOVER_ETC_DIR:-/etc/vaultwarden}"
VW_STARTUP_SCRIPT="${VW_RECOVER_STARTUP_SCRIPT:-${SCRIPT_DIR}/startup.sh}"

usage() { echo "Usage: ./recover.sh --state-dir DIR --key FILE"; }
fatal() { echo "$*" >&2; exit 1; }
read_env_key() { awk -F= -v k="$1" '$1==k { v=substr($0,index($0,"=")+1); gsub(/^["'"'"']|["'"'"']$/, "", v); print v }' "$2" | tail -1; }
require_cmds() { local c; for c in mountpoint findmnt sops age-keygen awk git install docker curl bash blkid mktemp cp mv rm chmod; do command -v "$c" >/dev/null 2>&1 || fatal "Missing required command: $c"; done; docker compose version >/dev/null 2>&1 || fatal "Missing required command: docker compose version"; }
write_policy() { local file="$1" op="$2" usb="$3"; cat >"$file" <<POLICY
creation_rules:
  - path_regex: '.*\.yaml$'
    # Offline recovery key — USB only, never stored on server
    age: "${op},${usb}"
POLICY
}
atomic_set_env() { local file="$1" key="$2" val="$3" tmp; tmp=$(mktemp -p "$(dirname "$file")" env.XXXXXX); awk -F= -v k="$key" -v v="$val" 'BEGIN{done=0} $1==k{print k"="v; done=1; next} {print} END{if(!done) print k"="v}' "$file" >"$tmp"; chmod --reference="$file" "$tmp" 2>/dev/null || true; chown --reference="$file" "$tmp" 2>/dev/null || true; mv "$tmp" "$file"; }
rollback_file() { local backup="$1" target="$2" existed="$3"; if [[ "$existed" == true ]]; then cp "$backup" "$target"; else rm -f "$target"; fi; }

state_dir=""; key_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir) shift; [[ $# -gt 0 && -n "${1:-}" ]] || fatal "Option --state-dir requires a value."; state_dir="$1" ;;
    --key) shift; [[ $# -gt 0 && -n "${1:-}" ]] || fatal "Option --key requires a value."; key_file="$1" ;;
    --help|-h) usage; exit 0 ;;
    *) fatal "Unknown option: $1" ;;
  esac
  shift
done
[[ -n "$state_dir" ]] || { usage; exit 1; }
[[ -n "$key_file" ]] || { usage; exit 1; }
[[ $EUID -eq 0 ]] || fatal "Must run as root."
require_cmds
mountpoint -q "$state_dir" || fatal "State directory is not a mounted volume. Attach the OCI block volume first."
manifest="$state_dir/config/dr-manifest.env"; install_env="$state_dir/config/install.env"; secrets_file="$state_dir/secrets/secrets.yaml"
[[ -f "$manifest" && ! -L "$manifest" ]] || fatal "Missing recovery manifest: $manifest"
[[ -d "$state_dir/data" ]] || fatal "Missing state data directory: $state_dir/data"
[[ -f "$secrets_file" ]] || fatal "Missing secrets file: $secrets_file"
[[ -f "$install_env" && ! -L "$install_env" ]] || fatal "Missing install environment: $install_env"
[[ -f "$key_file" ]] || fatal "Missing offline Age key: $key_file"
[[ -f "$SCRIPT_DIR/docker-compose.yml.example" ]] || fatal "Repository is missing docker-compose.yml.example"
DOMAIN="$(read_env_key DOMAIN "$manifest")"; REPO_COMMIT="$(read_env_key REPO_COMMIT "$manifest")"; LAYOUT="$(read_env_key STATE_LAYOUT_VERSION "$manifest")"; OFFLINE="$(read_env_key OFFLINE_AGE_RECIPIENT "$manifest")"
[[ "$DOMAIN" == https://* ]] || fatal "Invalid DOMAIN in manifest."
[[ "$REPO_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fatal "Invalid REPO_COMMIT in manifest."
[[ "$LAYOUT" == 1 ]] || fatal "Unsupported STATE_LAYOUT_VERSION in manifest."
[[ -z "$OFFLINE" || "$OFFLINE" =~ ^age1[a-z0-9]{58}$ ]] || fatal "Invalid OFFLINE_AGE_RECIPIENT in manifest."
[[ "$(git -C "$SCRIPT_DIR" rev-parse HEAD)" == "$REPO_COMMIT" ]] || fatal "Checked-out commit does not match recovery manifest."
[[ -f "$SCRIPT_DIR/docker-compose.yml" ]] || cp "$SCRIPT_DIR/docker-compose.yml.example" "$SCRIPT_DIR/docker-compose.yml"
SOPS_AGE_KEY_FILE="$key_file" sops -d "$secrets_file" >/dev/null
usb_public_recipient="$(age-keygen -y "$key_file")"
[[ -z "$OFFLINE" || "$OFFLINE" == "$usb_public_recipient" ]] || fatal "USB Age key does not match OFFLINE_AGE_RECIPIENT in manifest."

mkdir -p "$VW_ETC_DIR"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cipher_staging="$(mktemp -p "$(dirname "$secrets_file")" secrets.XXXXXX.yaml)"; cp "$secrets_file" "$cipher_staging"
new_key_staging="$work/age-key.txt"; age-keygen -o "$new_key_staging" >/dev/null 2>&1
new_public="$(age-keygen -y "$new_key_staging")"; temporary_policy="$work/.sops.yaml"; write_policy "$temporary_policy" "$new_public" "$usb_public_recipient"
cipher_backup="$work/secrets.yaml.bak"; key_backup="$work/age-key.bak"; policy_backup="$work/sops.bak"
cp "$secrets_file" "$cipher_backup"; key_existed=false; policy_existed=false
[[ -f "$VW_ETC_DIR/age-key.txt" ]] && { cp "$VW_ETC_DIR/age-key.txt" "$key_backup"; key_existed=true; }
[[ -f "$SOPS_CONFIG_FILE" ]] && { cp "$SOPS_CONFIG_FILE" "$policy_backup"; policy_existed=true; }
SOPS_AGE_KEY_FILE="$key_file" sops --config "$temporary_policy" updatekeys --yes "$cipher_staging"
SOPS_AGE_KEY_FILE="$new_key_staging" sops -d "$cipher_staging" >/dev/null
install -m 0600 "$new_key_staging" "$work/installed-key"; SOPS_AGE_KEY_FILE="$work/installed-key" sops -d "$cipher_staging" >/dev/null
mv "$cipher_staging" "$secrets_file"
if ! install -m 0600 "$new_key_staging" "$VW_ETC_DIR/age-key.txt"; then rollback_file "$cipher_backup" "$secrets_file" true; exit 1; fi
if ! mv "$temporary_policy" "$SOPS_CONFIG_FILE"; then rollback_file "$cipher_backup" "$secrets_file" true; rollback_file "$key_backup" "$VW_ETC_DIR/age-key.txt" "$key_existed"; exit 1; fi
if ! SOPS_AGE_KEY_FILE="$VW_ETC_DIR/age-key.txt" sops -d "$secrets_file" >/dev/null; then rollback_file "$cipher_backup" "$secrets_file" true; rollback_file "$key_backup" "$VW_ETC_DIR/age-key.txt" "$key_existed"; rollback_file "$policy_backup" "$SOPS_CONFIG_FILE" "$policy_existed"; exit 1; fi

source_dev="$(findmnt -n -o SOURCE --target "$state_dir")"; uuid="$(blkid -s UUID -o value "$source_dev" 2>/dev/null || true)"; device="$source_dev"; [[ -n "$uuid" && -e "/dev/disk/by-uuid/$uuid" ]] && device="/dev/disk/by-uuid/$uuid"
atomic_set_env "$install_env" PROJECT_STATE_DIR "$state_dir"; atomic_set_env "$install_env" DATA_VOLUME_MOUNT "$state_dir"; atomic_set_env "$install_env" DATA_VOLUME_DEVICE "$device"; atomic_set_env "$install_env" SOPS_AGE_KEY_FILE "$VW_ETC_DIR/age-key.txt"
atomic_set_env "$manifest" OFFLINE_AGE_RECIPIENT "$usb_public_recipient"; atomic_set_env "$manifest" MANIFEST_UPDATED_AT "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
export PROJECT_STATE_DIR="$state_dir" DATA_VOLUME_MOUNT="$state_dir" DATA_VOLUME_DEVICE="$device" SOPS_AGE_KEY_FILE="$VW_ETC_DIR/age-key.txt"
bash "$VW_STARTUP_SCRIPT"
if curl -sf "${DOMAIN%/}/alive" >/dev/null; then echo "Health check: PASS"; else echo "Health check: FAIL"; echo "Inspect logs: docker compose -f ${SCRIPT_DIR}/docker-compose.yml logs --tail=200"; fi
echo "Recovery complete. Vaultwarden is running at $DOMAIN"
