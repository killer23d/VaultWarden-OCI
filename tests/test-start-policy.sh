#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail(){ echo "FAIL: $*" >&2; exit 1; }
require(){ rg -n -- "$1" "$2" >/dev/null || fail "$3"; }
reject(){ ! rg -n -- "$1" "$2" >/dev/null || fail "$3"; }
RESTORE="$ROOT/utilities/restore-run.sh"
MIGRATE="$ROOT/lib/migrate.sh"
SYSTEMD="$ROOT/utilities/setup-systemd.sh"

require '--start-policy MODE' "$RESTORE" 'restore help must document --start-policy'
require 'Start VaultWarden services now\? \[y/N\]' "$RESTORE" 'restore ask prompt missing'
require '--no-start' "$RESTORE" 'restore --no-start missing'
require '_restore_should_start_services' "$RESTORE" 'restore start-policy gate missing'
require 'START_POLICY:-auto.*auto|START_POLICY.*== "auto"' "$RESTORE" 'restore safety net must respect auto policy'
require 'Services may be stopped\. Review state before starting' "$RESTORE" 'restore manual recovery warning missing'
require 'sudo ./startup\.sh --skip-pull' "$RESTORE" 'restore manual checklist missing startup command'
require 'docker compose logs --tail=100' "$RESTORE" 'restore manual checklist missing log command'
require '--rotate-age-key' "$RESTORE" 'restore rotate-age-key flag missing'
require '--no-rotate-age-key' "$RESTORE" 'restore no-rotate-age-key flag missing'
require 'Emergency capsule contains operational key material\. Rotate Age key after restore\? \[Y/n\]' "$RESTORE" 'emergency key rotation prompt missing'
require 'Promoted encrypted SOPS secrets' "$RESTORE" 'restore must log promoted SOPS secrets'
require 'Skipped runtime decrypted secrets' "$RESTORE" 'restore must log skipped runtime secrets'
require 'Installed emergency /etc/vaultwarden material' "$RESTORE" 'restore must log emergency etc install'

require '--start-policy <mode>' "$MIGRATE" 'migrate help must document --start-policy'
require 'Start VaultWarden stack now on the migrated storage\? \[Y/n\]' "$MIGRATE" 'migrate ask prompt missing'
require '_MV_START_POLICY="manual"' "$MIGRATE" 'migrate no answer must convert to manual policy'
require 'skipping post-migration health check because services were not started' "$MIGRATE" 'migrate manual policy must skip healthcheck'

require '--no-enable-now' "$SYSTEMD" 'systemd help must document --no-enable-now'
require 'Enable and start backup/maintenance timers now\? \[y/N\]' "$SYSTEMD" 'systemd ask prompt missing'
require 'systemctl enable --now "\$timer"' "$SYSTEMD" 'systemd auto policy must preserve enable --now path'
require 'systemctl enable "\$timer"' "$SYSTEMD" 'systemd manual policy must enable without now'
