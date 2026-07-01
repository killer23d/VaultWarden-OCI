#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESTORE="$ROOT/utilities/restore-run.sh"
BACKUP="$ROOT/utilities/backup-run.sh"
UTILS="$ROOT/lib/backup-utils.sh"
fail(){ echo "not ok - $*" >&2; exit 1; }
pass(){ echo "ok - $*"; }
require(){ local pat="$1" file="$2" msg="$3"; grep -Eq -- "$pat" "$file" || fail "$msg"; }
reject(){ local pat="$1" file="$2" msg="$3"; ! grep -Eq -- "$pat" "$file" || fail "$msg"; }

require 'inspect\)' "$RESTORE" 'restore must expose inspect subcommand'
require 'INSPECT_ONLY=true' "$RESTORE" 'inspect mode flag must exist'
require 'Restore preflight report' "$RESTORE" 'full/emergency preflight report must print'
require 'Source storage' "$RESTORE" 'preflight must report source storage'
require 'Target storage' "$RESTORE" 'preflight must report target storage'
require 'Snapshot DBs' "$RESTORE" 'preflight must report snapshot DBs'
require 'Storage mismatch: backup appears to be from block storage' "$RESTORE" 'block-source to boot-target must fail clearly'
require 'No live state DB found' "$RESTORE" 'snapshot-only/config-only archives must fail clearly'
require 'Archive members \(first 30\)' "$RESTORE" 'unsafe archive diagnostic must list first members'
require '_restore_prepare_block_target' "$RESTORE" 'block target readiness helper must exist'
require 'sudo ./utilities/setup-storage.sh' "$RESTORE" 'unmounted block target must print setup command'
require 'Created missing block-storage directory' "$RESTORE" 'mounted block target must repair dirs'
require 'DB restore is storage-layout independent' "$RESTORE" 'DB restore UX must explain storage independence'
require '_restore_age_no_identity_guidance' "$RESTORE" 'age no-identity guidance must exist'
require 'older operational key or offline recovery key' "$RESTORE" 'age diagnostics must mention old/recovery key'
require '_RESTORE_SAFETY_NET_RUNNING' "$RESTORE" 'safety net must be non-reentrant'
require 'RESTORE_DESTRUCTIVE_PHASE_STARTED=false' "$RESTORE" 'destructive phase flag must initialize false'
require 'Restore failed before destructive phase' "$RESTORE" 'pre-destructive failures must not restart services'
require 'Restore interrupted by operator \(Ctrl-C\)' "$RESTORE" 'Ctrl-C message must be explicit'
require '_RESTORE_CLEANUP_DONE' "$RESTORE" 'cleanup must be guarded once'
require '_restore_payload_allowlist=\(data caddy logs\)' "$RESTORE" 'restore promotion must remain allowlisted'
reject 'rsync -a --no-owner --no-group "\$_staged_payload/" "\$state_dir/\$_payload_name/".*secrets' "$RESTORE" 'secrets must not be promoted as state payload'

require 'project_state_dir=' "$BACKUP" 'full metadata must include project_state_dir'
require 'storage_mode=' "$BACKUP" 'full metadata must include storage_mode'
require 'data_volume_mount=' "$BACKUP" 'full metadata must include data_volume_mount'
require 'data_volume_device=' "$BACKUP" 'full metadata must include data_volume_device'
require 'state_dir_is_mountpoint=' "$BACKUP" 'full metadata must include state_dir_is_mountpoint'
require 'repo_root=' "$BACKUP" 'full metadata must include repo_root'
require '_validate_full_archive_payload' "$BACKUP" 'post-tar validation helper must exist'
require 'Expected DB member path' "$BACKUP" 'backup validation failure must print expected member'
require '\.pre-restore-\*' "$BACKUP" 'backup excludes must include pre-restore snapshots'
require 'awk -F=.*\^\[A-Za-z_\]' "$UTILS" 'metadata writer must keep valid key=value lines only'
require 'awk .*NF \{print; exit\}' "$UTILS" 'vaultwarden version must use first meaningful line'

bash -n "$RESTORE" "$BACKUP"
pass 'restore/backup preflight safety source checks'
printf '1..1\n'
