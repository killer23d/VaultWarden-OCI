# Operations Guide — VaultWarden-OCI

Day-2 operations for the current root-operated VaultWarden-OCI appliance.

Related docs: [DEPLOYMENT.md](DEPLOYMENT.md) · [BACKUP-RESTORE.md](BACKUP-RESTORE.md) · [TROUBLESHOOTING.md](TROUBLESHOOTING.md) · [CROWDSEC.md](CROWDSEC.md)

## Root-operated production model

Production lifecycle and privileged maintenance use root:

```bash
sudo make up
sudo make down
sudo make restart
sudo make health
sudo make backup
sudo make restore
```

The repository intentionally does not use the Docker-group/non-root operator model as the production golden path.

Help, version, and intentionally read-only metadata paths may remain root-free where supported by the owning command.

## Normal status sequence

Start with:

```bash
sudo make status
sudo make health
sudo make operations
```

For live services:

```bash
docker compose ps
docker compose logs --tail=100
```

For installed automation:

```bash
sudo ./setup.sh systemd status
sudo ./setup.sh systemd validate
sudo make timers
```

A check that did not run is not a healthy result. Use the current `PASS`, `FAIL`, `SKIP`, `Ready`, `Not ready`, and `Unknown` states literally.

---

## Service lifecycle

### Start

```bash
sudo make up
```

`make up` synchronizes the accepted environment inside the guarded lifecycle operation and delegates to `startup.sh`. Startup validates storage readiness, materializes runtime secrets, and uses the current Compose lifecycle path.

Do not replace the normal production start path with a bare:

```bash
docker compose up -d
```

A bare Compose start bypasses project preflight, secret materialization, storage, and operation-guard behavior.

### Stop

```bash
sudo make down
```

### Restart

```bash
sudo make restart
```

### Safe restart

```bash
sudo make safe-restart
```

Use the safe-restart workflow when rollback/health semantics matter for the planned change.

---

## Shared operation guard

Conflicting mutating workflows use `lib/operations.sh` and kernel `flock` state.

Inspect active/interrupted work with:

```bash
sudo make operations
```

Operation metadata may show the owning PID, start identity, label, and current phase. The kernel lock is authoritative; file existence alone is not proof that an operation is active.

When a command reports contention:

1. run `sudo make operations`;
2. confirm whether the owner is still active;
3. inspect the phase and elapsed state;
4. wait, resume, or use the guarded conflict action offered by the owning workflow.

Do not delete lock files as a generic fix.

The operation tooling refuses to automatically terminate package-manager work. Do not kill `apt`/`dpkg` simply because another project operation is waiting.

Expected non-interactive contention uses exit `75` where the owning service contract defines a clean skip. DNS/firewall maintenance and their aggregate caller preserve that distinction. Real failures remain failures.

`--force` may skip a documented confirmation; it does not silently bypass the shared operation guard.

---

## Health checks

Full health:

```bash
sudo make health
```

Quick health:

```bash
sudo make health-quick
```

Direct command:

```bash
sudo ./maintenance.sh health
```

The current critical service policy is owned by `lib/defaults.sh`. Do not hard-code a separate list in operator procedures.

The health path verifies the live runtime and includes checks for storage, secrets, Docker services, HTTP/TLS behavior, backup state, and other configured integrations according to the current implementation.

When the existing health alert-state path is writable, unhealthy checks are
correlated under one active incident ID. Existing per-check alert/cooldown
behavior is unchanged. A successful recovery email summarizes the preceding
unhealthy checks and duration, then removes only the active incident snapshot.
If incident persistence is unavailable, health continues without correlation;
it does not change permissions or treat missing incident context as a health
failure.

Repair behavior must be explicit. A failed/unavailable probe cannot be converted into a green status merely because the probe was skipped.

---

## Production smoke test

Run after first deployment, recovery, major storage/systemd change, or activation of new managed runtime:

```bash
sudo ./utilities/smoke-test.sh
```

The smoke test covers:

- canonical project environment;
- Docker/Compose;
- expected critical container readiness;
- TLS/origin behavior;
- root HTTP and `/alive`;
- admin protection;
- operational Age key;
- SOPS decryptability;
- transient runtime secret materialization;
- recent backup evidence;
- canonical systemd installed-runtime/timer validation;
- CrowdSec availability;
- disk space.

Exit `0` requires no `FAIL` and no `SKIP`.

When the systemd check fails, run:

```bash
sudo ./setup.sh systemd validate
```

Then follow the exact stale/missing/timer error reported by the validator.

---

## Repository updates and installed systemd runtime

Managed systemd jobs execute installed copies under:

```text
/opt/vaultwarden-scripts/
```

Unit files live under:

```text
/etc/systemd/system/
```

The installed environment/key material is under:

```text
/etc/vaultwarden/
```

Therefore:

```text
git pull --ff-only origin main
    !=
systemd runtime activation
```

After pulling repository changes that affect managed scripts, libraries, or units:

```bash
git pull --ff-only origin main
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

The validator compares expected repository-managed scripts, libraries, and units against the installed runtime and checks the six managed timers.

`make update` updates container images through the maintenance path. It is not a Git update or `/opt` synchronizer.

---

## systemd timer policy

Managed timers are:

```text
vaultwarden-maintenance.timer
vaultwarden-db-backup.timer
vaultwarden-full-backup.timer
vaultwarden-health.timer
vaultwarden-dns-update.timer
vaultwarden-firewall-update.timer
```

Install and start them now only when the host is ready for scheduled work:

```bash
sudo ./setup.sh systemd install --enable-now
```

For recovery/manual inspection:

```bash
sudo ./setup.sh systemd install --no-enable-now
```

This installs/enables units for future boot but does not start timers immediately.

Validate:

```bash
sudo ./setup.sh systemd validate
```

A production-ready validation result requires the managed installed runtime to match the repository and every managed timer to be active with a next trigger.

Managed services also use the project's failure-notification integration. Expected operation contention must not create a false incident; real execution failure must not be hidden as contention.

---

## Logs

Common Make targets:

```bash
sudo make logs-tail
sudo make logs-vaultwarden
sudo make logs-caddy
sudo make logs-postfix
sudo make logs-crowdsec
```

Compose:

```bash
docker compose logs --tail=100
docker compose logs -f vaultwarden
docker compose logs -f caddy
docker compose logs -f postfix
```

Systemd:

```bash
journalctl -u vaultwarden-health.service -n 100 --no-pager
journalctl -u vaultwarden-db-backup.service -n 100 --no-pager
journalctl -u vaultwarden-full-backup.service -n 100 --no-pager
journalctl -u vaultwarden-maintenance.service -n 100 --no-pager
journalctl -u vaultwarden-dns-update.service -n 100 --no-pager
journalctl -u vaultwarden-firewall-update.service -n 100 --no-pager
```

CrowdSec:

```bash
sudo journalctl -u crowdsec -n 100 --no-pager
sudo journalctl -u crowdsec-firewall-bouncer -n 100 --no-pager
sudo journalctl -u crowdsec-cloudflare-worker-bouncer -n 100 --no-pager
```

Do not paste decrypted secret values, private Age keys, recovery kits, or raw credentials into issue reports.

---

## Backup operations

Create a database backup:

```bash
sudo make backup
```

Create a full DR archive:

```bash
sudo make backup-full
```

Create an independently sealed emergency archive:

```bash
sudo make backup-emergency
```

Full verification:

```bash
sudo ./backup.sh run full --full-verification
```

Verify canonical latest selection:

```bash
sudo ./backup.sh verify
```

List/inventory:

```bash
sudo make list-backups
sudo make backup-status
```

Sync retained local backup sets to rclone:

```bash
sudo ./backup.sh sync
```

The backup success contract is truthful: required verification failure is not success, requested offsite protection failure/skipping is distinguished from completed offsite protection, and a failed new archive does not run normal retention/pruning as though a valid replacement recovery point exists.

See [BACKUP-RESTORE.md](BACKUP-RESTORE.md).

---

## Restore operations

Preflight:

```bash
sudo ./restore.sh inspect --remote
```

Guided restore:

```bash
sudo make restore
```

Guided remote restore:

```bash
sudo ./restore.sh interactive --remote --start-policy ask
```

Database-only restore:

```bash
sudo make restore-db
```

Use `--start-policy manual`/`--no-start` when the recovered host must remain stopped for inspection.

Manual start/health sequence after restore:

```bash
sudo utilities/repair-permissions.sh
sudo ./startup.sh --skip-pull
sudo ./maintenance.sh health
```

When the restored host is ready to return to automated production:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

Do not treat successful systemd install alone as the readiness gate.

---

## Permission repair

Read-only contract check:

```bash
sudo utilities/repair-permissions.sh --check
```

Repair:

```bash
sudo utilities/repair-permissions.sh
```

The helper applies known-path contracts for:

- root-operated persistent config/secrets;
- `/etc/vaultwarden`;
- transient runtime secrets;
- Vaultwarden data/log ownership;
- Caddy UID/GID `2000:2000` runtime state/logs.

Do not run broad `chmod -R 777` or whole-state `chown -R 2000:2000` commands.

---

## Environment changes

Edit non-secret values:

```bash
sudo make edit-env
```

Inspect state/path drift:

```bash
utilities/env-edit.sh status
```

Restart after an ordinary environment change:

```bash
sudo make restart
sudo make health
```

Repository `.env` is the operator-editable source. Persistent `install.env` and `/etc/vaultwarden/vaultwarden.env` are managed runtime copies and should not be hand-edited as the normal configuration workflow.

Runtime environment loading prefers installed `/etc/vaultwarden/vaultwarden.env`, then persistent `install.env`, then repository `.env` as bootstrap/legacy fallback.

---

## Secret operations

Edit:

```bash
sudo ./edit-secrets.sh edit
```

Rotate:

```bash
sudo ./edit-secrets.sh rotate <secret-key>
```

List key names:

```bash
sudo ./utilities/secrets-list.sh
```

Check Age key:

```bash
sudo make key-health
```

Rotate operational Age/SOPS key:

```bash
sudo make key-rotate
```

Export recovery material:

```bash
sudo ./utilities/secrets-export-recovery-kit.sh
```

The secret schema owns the transform/apply behavior for each key. See [SECRETS-SCHEMA.md](SECRETS-SCHEMA.md).

---

## Email operations

Test the operational alert path:

```bash
sudo ./maintenance.sh test-email --verbose
```

Normal production mail is Postfix-first. Vaultwarden talks to the internal Postfix sidecar; Postfix owns upstream SMTP TLS/authentication/queueing.

Optional HTTP API email providers apply to the operational script alert path. Keep SMTP/Postfix configured for Vaultwarden mail and attachment-based recovery-kit delivery.

See [EMAIL.md](EMAIL.md).

---

## CrowdSec operations

Status:

```bash
sudo systemctl status crowdsec
sudo systemctl status crowdsec-firewall-bouncer
sudo systemctl status crowdsec-cloudflare-worker-bouncer
```

Decisions/alerts:

```bash
sudo cscli decisions list
sudo cscli alerts list --since 24h
sudo cscli bouncers list
```

Remove a decision:

```bash
sudo cscli decisions delete --ip <ip-address>
```

Persistent administrator allowlist:

```bash
sudo ./utilities/setup-crowdsec.sh --admin-ip <ip-or-cidr>
```

Apply current Worker config after relevant secret rotation:

```bash
sudo ./utilities/crowdsec-worker-apply.sh
```

Manage the optional CrowdSec security-event email through its dedicated controller:

```bash
sudo ./utilities/crowdsec-email.sh enable
sudo ./utilities/crowdsec-email.sh status
sudo ./utilities/crowdsec-email.sh test
sudo ./utilities/crowdsec-email.sh disable
```

`enable` and `disable` update `CROWDSEC_EMAIL_NOTIFICATIONS` transactionally and
delegate to the established CrowdSec reconciliation path. `status` checks the
environment flag and managed markers. `test` confirms plugin dispatch through
the loopback Postfix route but does not prove mailbox receipt.

This is separate from health-check incident mail and generic systemd
unit-failure mail. Normal CrowdSec setup performs static validation but no live
email test.

See [CROWDSEC.md](CROWDSEC.md).

---

## Maintenance and updates

Routine maintenance:

```bash
sudo make maintenance
```

Comprehensive maintenance:

```bash
sudo make maintenance-full
```

Database maintenance:

```bash
sudo make db-maint
```

Container image update:

```bash
sudo make update
```

Host package update:

```bash
sudo make update-system
```

DNS update:

```bash
sudo make update-dns
```

The update/maintenance paths use the shared operation guard. Package-manager work is specially protected from automatic conflict termination.

---

## Break-glass administration

Create:

```bash
sudo make breakglass-create
```

Status:

```bash
sudo make breakglass-status
```

Remove after the incident:

```bash
sudo make breakglass-remove
```

Break-glass state is for emergency administration, not a permanent alternate admin path.

---

## Same-VM test reset

Preview:

```bash
sudo ./utilities/uninstall-vaultwarden.sh run --test-reset --dry-run
```

Reset the managed stack while preserving the Git checkout:

```bash
sudo ./utilities/uninstall-vaultwarden.sh run \
  --test-reset \
  --i-have-saved-my-recovery-kit
```

This removes known VaultWarden-OCI managed state, installed systemd integration, managed Docker resources, CrowdSec integration, and project firewall rules, then verifies managed residuals.

It intentionally preserves host-wide Docker/tooling state and the Git checkout. It is not a pristine-image rebuild.

---

## Production acceptance sequence

For a healthy existing host after repository updates:

```bash
git pull --ff-only origin main
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

For a new/recovered host, also verify:

```bash
sudo make health
sudo ./maintenance.sh test-email --verbose
sudo ./backup.sh run full --full-verification
sudo ./backup.sh verify
sudo ./utilities/secrets-export-recovery-kit.sh
```

The final production-ready decision should reflect live host behavior, installed automation consistency, backup/recovery evidence, and current operator access—not merely a green repository CI result.
