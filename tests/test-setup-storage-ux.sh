#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }

STORAGE="utilities/setup-storage.sh"
SETUP="setup.sh"

# The assistant must be gated to interactive setup only and not affect CI/automation.
grep -Fq '_ss_should_run_storage_assistant' "$STORAGE" || fail 'storage assistant gate missing'
grep -Fq '[[ -t 0 ]] || return 1' "$STORAGE" || fail 'assistant must require terminal stdin'
grep -Fq '[[ "${DRY_RUN}" != "true" ]] || return 1' "$STORAGE" || fail 'assistant must skip dry-run'
grep -Fq '[[ "${_SS_AUTO}" != "true" ]] || return 1' "$STORAGE" || fail 'assistant must honor --auto'
grep -Fq '[[ "${_SS_DATA_DEVICE_PROVIDED}" != "true" ]] || return 1' "$STORAGE" || fail 'assistant must skip explicit --data-device'
pass 'storage assistant is gated away from non-interactive, dry-run, auto, and explicit data-device runs'

# The assistant may collect a path, but existing setup_data_volume remains the only provisioning path.
grep -Fq 'lsblk -dpno NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL' "$STORAGE" || fail 'assistant missing read-only lsblk summary'
grep -Fq 'Path is not a block device' "$STORAGE" || fail 'assistant must reject non-block paths'
grep -Fq 'Block device path cannot be empty.' "$STORAGE" || fail 'assistant must reject empty device input'
grep -Fq 'setup_data_volume will validate and provision using existing safeguards' "$STORAGE" || fail 'assistant must delegate provisioning to setup_data_volume'
! awk '/_ss_storage_assistant\(\)/,/^}/' "$STORAGE" | grep -Eq 'mkfs|wipefs|parted|sfdisk|sgdisk' \
    || fail 'assistant must not format, wipe, or partition disks'
! awk '/_ss_prompt_block_storage\(\)/,/^}/' "$STORAGE" | grep -Eq 'mkfs|wipefs|parted|sfdisk|sgdisk' \
    || fail 'block-storage prompt must not format, wipe, or partition disks'
pass 'storage assistant is read-only except collecting operator-selected device and mount values'

# Menu behavior contracts: boot confirmation, help returns to menu, and cancel exits cleanly.
grep -Fq 'Operator selected boot-volume mode; DATA_VOLUME_DEVICE remains unset.' "$STORAGE" || fail 'boot-volume confirmation missing'
grep -Fq 'Storage setup cancelled by operator.' "$STORAGE" || fail 'cancel log missing'
awk '/3\)/,/;;/' "$STORAGE" | grep -Fq 'show_help' || fail 'option 3 must show help'
awk '/3\)/,/;;/' "$STORAGE" | grep -Fq '_ss_storage_help_text' || fail 'option 3 must return to assistant context'
pass 'storage assistant menu preserves boot, help, and cancel behavior'

# Non-interactive boot-only mode should still succeed and include a next-step hint.
grep -Fq 'DATA_VOLUME_DEVICE not set — skipping data volume provisioning (boot-only mode)' lib/storage.sh \
    || fail 'existing boot-only message missing'
grep -Fq 'To use block storage, re-run with --data-device /dev/disk/by-id/... or set DATA_VOLUME_DEVICE in install.env/.env.' "$STORAGE" \
    || fail 'boot-only next-step hint missing'
pass 'non-interactive boot-only path retains existing behavior with helpful block-storage hint'

# setup.sh install --auto must propagate --auto into phase 2 storage setup.
awk '/setup-storage\.sh" --mode setup/,/\|\| _phase_failed 2/' "$SETUP" | grep -Fq '"${_auto[@]}"' \
    || fail 'setup.sh phase 2 does not pass --auto to setup-storage'
pass 'setup.sh install --auto suppresses the storage assistant in phase 2'

# Help/unknown-option handling remains present.
grep -Fq -- '--help|-h)' "$STORAGE" || fail 'setup-storage help option handling missing'
grep -Fq 'Unknown option: $1' "$STORAGE" || fail 'setup-storage unknown-option handling missing'
grep -Fq 'setup-storage is run interactively' "$STORAGE" \
    || fail 'help text must mention interactive storage prompt'
grep -Fq -- '--auto suppresses the prompt' "$STORAGE" \
    || fail 'help text must mention --auto prompt suppression'
pass 'setup-storage help and unknown-option contracts remain documented'
