#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail(){ echo "FAIL: $*" >&2; exit 1; }
require(){ grep -Eq -- "$1" "$2" || fail "$3"; }
reject(){ ! grep -Eq -- "$1" "$2" || fail "$3"; }
RESTORE="$ROOT/utilities/restore-run.sh"
MIGRATE="$ROOT/lib/migrate.sh"
SYSTEMD="$ROOT/utilities/setup-systemd.sh"
IPTABLES="$ROOT/systemd/vaultwarden-iptables.service"
DB_BACKUP_SERVICE="$ROOT/systemd/vaultwarden-db-backup.service"
FULL_BACKUP_SERVICE="$ROOT/systemd/vaultwarden-full-backup.service"
MAINT_SERVICE="$ROOT/systemd/vaultwarden-maintenance.service"
MAINT_RUN="$ROOT/utilities/maintenance-run.sh"

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
require 'install only / manual' "$SYSTEMD" 'systemd help must explain install-only/manual policy'
require 'enable timers without immediate execution' "$SYSTEMD" 'systemd help must document enable-without-start behavior'
require 'enable/start timers now' "$SYSTEMD" 'systemd help must document enable/start behavior'
require 'DR/new VM restore' "$SYSTEMD" 'systemd help must warn DR/new VM restores to avoid immediate jobs'
require 'START_POLICY="manual"' "$SYSTEMD" 'systemd non-interactive default must be manual'
require 'Enable and start backup/maintenance timers now\? \[y/N\]' "$SYSTEMD" 'systemd ask prompt missing'
require 'systemctl enable --now "\$timer"' "$SYSTEMD" 'systemd auto policy must preserve enable --now path'
require 'systemctl enable "\$timer"' "$SYSTEMD" 'systemd manual policy must enable without now'
require '_report_unhealthy_managed_timers' "$SYSTEMD" 'systemd detailed unhealthy timer reporter missing'
require '_check_managed_timer_health' "$SYSTEMD" 'systemd shared timer health helper missing'
require '_wait_for_managed_timer_health' "$SYSTEMD" 'systemd install timer health wait helper missing'
require 'UNHEALTHY TIMER:' "$SYSTEMD" 'systemd diagnostics must print unhealthy timer names'
require 'systemctl is-active "\$timer"' "$SYSTEMD" 'systemd diagnostics must print is-active command per timer'
require 'systemctl show "\$timer" --property=NextElapseUSecRealtime --value' "$SYSTEMD" 'systemd diagnostics must print NextElapseUSecRealtime command per timer'
require 'systemctl status "\$timer" --no-pager -l' "$SYSTEMD" 'systemd diagnostics must print full systemctl status per timer'
require '_wait_for_managed_timer_health "after enablement" 10 1' "$SYSTEMD" 'install must use shared timer health helper'
require '_check_managed_timer_health "during validation"' "$SYSTEMD" 'validate must use shared timer health helper'

# Calendar timers must not also carry OnBootSec catch-up triggers. OnBootSec
# fires during systemctl enable --now on an already-booted host and can create
# install-time bursts.
for timer in "$ROOT"/systemd/vaultwarden-*.timer; do
    reject '^OnBootSec=' "$timer" "timer must not use OnBootSec: $timer"
    require '^OnCalendar=' "$timer" "timer must use predictable calendar scheduling: $timer"
    require '^Persistent=false$' "$timer" "timer must avoid persistent install/boot catch-up: $timer"
done

# StartLimit directives belong in [Unit], not [Service], on Ubuntu 22.04/24.04
# systemd. This catches the warning: Unknown key name 'StartLimitIntervalSec' in
# section 'Service'.
require '^StartLimitIntervalSec=60s$' "$IPTABLES" 'iptables service must set StartLimitIntervalSec'
require '^StartLimitBurst=3$' "$IPTABLES" 'iptables service must set StartLimitBurst'
awk '
    /^\[/ { section=$0 }
    /^StartLimit(IntervalSec|Burst)=/ && section != "[Unit]" { bad=1 }
    END { exit bad }
' "$IPTABLES" || fail 'iptables StartLimit directives must live in [Unit]'

# Backup service units must not check the stale maintenance lock filename. They
# should use the shared operations lock and treat scheduled contention as a clean
# skip without hiding real backup/rclone failures.
for svc in "$DB_BACKUP_SERVICE" "$FULL_BACKUP_SERVICE"; do
    reject 'vaultwarden-maintenance\.lock' "$svc" "backup service must not use stale maintenance lock: $svc"
    require 'vaultwarden-operations\.lock' "$svc" "backup service must use shared operations lock: $svc"
    require '--skip-ops-lock' "$svc" "backup service must delegate with --skip-ops-lock: $svc"
    require 'exit 75' "$svc" "backup service must cleanly skip expected lock contention: $svc"
    require '^SuccessExitStatus=0 75$' "$svc" "backup service must treat only success/skip as success: $svc"
    reject '^SuccessExitStatus=.* 2' "$svc" "backup service must not hide real rclone/backup failures as success: $svc"
done

require '--skip-ops-lock' "$MAINT_RUN" 'maintenance runner must support inherited operations lock contract'
require 'SKIP_OPS_LOCK=true' "$MAINT_RUN" 'maintenance runner must parse --skip-ops-lock'
require 'vaultwarden-maintenance-run\.lock' "$MAINT_RUN" 'maintenance runner must keep canonical maintenance lock filename'
require 'vaultwarden-operations\.lock' "$MAINT_SERVICE" 'maintenance service must use shared operations lock'
require '--skip-ops-lock' "$MAINT_SERVICE" 'maintenance service must delegate with --skip-ops-lock'
require 'exit 75' "$MAINT_SERVICE" 'maintenance service must cleanly skip expected lock contention'
require '^SuccessExitStatus=75$' "$MAINT_SERVICE" 'maintenance service must treat lock-contention skip as success'
