# Scripts and Implementation Map — VaultWarden-OCI

This document explains the current public command surfaces and which utilities/libraries own their behavior.

For exact CLI grammar, options, and exit-code text, use the script's `--help` output or the generated [COMMAND-REFERENCE.md](COMMAND-REFERENCE.md). Do not treat this file as a second hand-maintained option inventory.

Related docs: [OPERATIONS.md](OPERATIONS.md) · [ARCHITECTURE.md](ARCHITECTURE.md) · [PROJECT-BOUNDARY.md](PROJECT-BOUNDARY.md)

## Public top-level entry points

The normal operator-facing scripts are thin dispatchers or lifecycle entry points:

| Entry point | Purpose | Production privilege |
| :-- | :-- | :-- |
| `setup.sh` | Host/setup phase dispatcher | root |
| `startup.sh` | Start, stop, and restart lifecycle | root |
| `maintenance.sh` | Health, update, DNS/firewall, DB maintenance, email, routine maintenance | root for production operations |
| `backup.sh` | Backup creation, verification, retention, sync, inventory | root for production operations; metadata/help paths may be root-free |
| `restore.sh` | Restore inspection, listing, and mutation | root for restore mutation; metadata paths may be root-free where supported |
| `edit-secrets.sh` | Encrypted secret edit/rotate/list/view/recovery-kit dispatcher | root for mutating secret operations |
| `recover.sh` | Replacement-host state-volume recovery | root |
| `dashboard.sh` | Junior-operator dashboard | follows the privilege contract of the command it invokes |

The Makefile is the normal day-2 command surface. It is not the permanent test inventory.

Common production forms are:

```bash
sudo make up
sudo make restart
sudo make health
sudo make backup
sudo make restore
sudo make operations
```

## Dispatcher ownership

### `setup.sh`

Owns the supported setup flow and delegates to:

- `utilities/setup-system.sh` — Noble/architecture preflight, Docker/tool dependencies, swap/toolchain validation;
- `utilities/setup-env.sh` — deployment file/environment generation;
- `utilities/setup-storage.sh` — storage setup, verification, and migration dispatch;
- `utilities/setup-firewall.sh` — supported host firewall setup;
- `utilities/setup-secrets.sh` — SOPS/Age secret bootstrap/configuration;
- `utilities/setup-crowdsec.sh` — CrowdSec and bouncer installation;
- `utilities/setup-systemd.sh` — installed runtime and timer integration.

Supported first install:

```bash
sudo ./setup.sh install \
  --domain vault.example.com \
  --email admin@example.com
```

`setup-system.sh` fails closed outside Ubuntu 24.04 LTS Noble and outside amd64/arm64.

### `startup.sh`

Owns foreground production lifecycle. Startup:

1. acquires the shared global/lifecycle operation guard;
2. loads the accepted runtime environment and reports relevant repository/runtime drift without persistently synchronizing it;
3. validates project state, storage readiness, prerequisites, known runtime permissions, local images, and Age/SOPS secret state;
4. materializes transient runtime secrets under `/run/vaultwarden-oci/secrets`;
5. starts the existing Compose definition without pulling or building; explicit force mode may recreate containers;
6. performs critical/optional service readiness checks and the standard post-start health profile.

Ordinary startup does not persistently synchronize environment state, repair permissions, update images, reconcile DNS or firewall state, clean Docker resources, remove orphans, or create groups. Those actions remain owned by the environment, repair, update, dedicated DNS/firewall, maintenance, and setup-systemd workflows.

Use the root-operated Make targets rather than calling bare `docker compose up` as the production lifecycle API:

```bash
sudo make up
sudo make down
sudo make restart
sudo make safe-restart
```

### `maintenance.sh`

Delegates to the maintenance utilities:

- `maintenance-health.sh`;
- `maintenance-run.sh`;
- `maintenance-update.sh`;
- `maintenance-update-dns.sh`;
- `maintenance-update-firewall.sh`;
- `maintenance-db-maint.sh`;
- `maintenance-email.sh`.

The health path is read-only unless repair/fix behavior is requested. Mutating health repair uses the shared operation guard. Health exposes bounded quick, standard, and comprehensive profiles; standard health is the no-profile default.

Scheduled daily maintenance runs the routine path with email reporting. Routine maintenance owns cleanup, canonical backup pruning, online SQLite `PRAGMA optimize` plus passive WAL checkpointing, and quick post-maintenance health. DNS and firewall reconciliation remain owned by their dedicated timers. Explicit comprehensive maintenance may include them, while deep database maintenance is a separate offline workflow that owns backup, integrity checks, service stop/start, and `VACUUM`.

Routine maintenance treats health status `1` as successful completion with advisory warnings and status `75` as successful completion with a visible health skip. Genuine health failures remain maintenance failures. The aggregate maintenance path also understands exit `75` as an expected active-operation skip for guarded DNS/firewall leaves; a real nonzero leaf failure remains a maintenance failure.

### `utilities/email-queue.sh`

Owns all Postfix queue inventory, inspection, retry, deletion, log filtering,
and identity-verified snapshot-purge behavior. The Makefile is the stable
root-operated operator surface, while the dashboard calls only explicit Make
targets through `run_sudo_cmd`. Machine-readable operations parse `postqueue -j`
with Python; they do not scrape human `mailq` output or expose a generic Postfix
pass-through.

Mutating operations share an exclusive host-side `flock`. Destructive
operations first require the effective Postfix setting
`enable_long_queue_ids=yes`; there is no production bypass. Targeted deletion
captures the selected identity before confirmation, holds only that exact ID,
re-inventories, and deletes only a held identity match. Snapshot purge stores the
same stable identity metadata, batches exact IDs through Postfix hold/delete
stdin, and retains its fixed four-inventory workflow. Metadata is defence in
depth rather than a substitute for long queue IDs.

Inventory normalization collapses equivalent duplicate `postqueue -j` records,
prefers `hold` when queue names differ, and otherwise chooses a deterministic
queue name. Conflicting identities for one ID reject the inventory. Reused IDs
are skipped, pre-existing holds are preserved, and newly introduced holds are
rolled back after failures or handled signals when possible. Direct external
Postfix administration is outside this utility lock. The deprecated `clear`
interface uses the snapshot workflow and never a live all-queue deletion.

### `backup.sh`

Delegates backup work to `utilities/backup-run.sh` and shared backup logic in `lib/backup-utils.sh`.

The three backup tiers are intentionally different:

| Tier | Contract |
| :-- | :-- |
| `db` | encrypted verified SQLite snapshot for quick rollback |
| `full` | normal DR archive with persistent project state and encrypted SOPS ciphertext, but without the live operational Age private key |
| `emergency` | clone-grade secrets-bearing capsule that may include staged `/etc/vaultwarden` key/config material and is independently sealed |

All tiers use a verified SQLite snapshot. Full/emergency archive construction excludes live SQLite WAL/SHM state and transient runtime material, then injects the verified staged database at the normal live database path.

Ordinary database/full payload staging uses the configured backup filesystem; small control material uses a restrictive control workspace. Emergency plaintext can contain operational private-key material and remains on verified, capacity-checked tmpfs without silently falling back to persistent plaintext staging. Full verification streams decryption into archive inspection instead of creating a second plaintext full archive.

Retention resolution is shared by direct backup, routine maintenance, and local/remote pruning: nonempty `--keep`, matching `BACKUP_RETENTION_*_DAYS`, shared `BACKUP_RETENTION_DAYS`, then the per-tier fallback. Retention preserves the newest parseable timestamped archive even when it is older than the configured retention window. Unparseable archive names fail safe and are not automatically deleted as primary archives. A missing remote tier can be empty; a real remote listing failure skips pruning for that tier and makes the requested prune/rotate operation fail.

Quick/full verification failure is not successful backup completion. A new archive that fails required verification is not left eligible as a normal restore candidate and must not trigger normal retention/success behavior.

See [BACKUP-RESTORE.md](BACKUP-RESTORE.md).

### `restore.sh`

Delegates restore execution to `utilities/restore-run.sh`.

Restore supports the three backup tiers and preserves the distinctions between:

- archive selection;
- storage preflight;
- Age identity selection;
- emergency independent protection;
- pre-restore snapshot;
- service stop;
- staged extraction/promotion;
- runtime permission repair;
- Age key handling/rotation;
- service start policy;
- `/alive` verification.

Restore uses split restrictive staging: small sensitive control material uses a control workspace, while remote downloads, decrypted large payloads, and extracted trees use a workspace on the target filesystem. Validation and initial capacity checks occur before service stop; required capacity is checked again after the pre-restore snapshot and before promotion. Failure before that destructive boundary leaves services untouched. Cleanup removes only workspaces owned by the current invocation, and retained staging is printed only when manual rollback/recovery genuinely requires it.

Interactive full/emergency restore uses an operator-controlled start policy. Timeout/EOF at required confirmation or `SAVED` acknowledgement points fails safe rather than being converted into an implicit answer.

### `edit-secrets.sh`

Routes secret operations to the focused utilities:

- `utilities/secrets-edit.sh` — decrypt/edit/validate/re-encrypt;
- `utilities/secrets-rotate.sh` — schema-aware field rotation and apply behavior;
- `utilities/secrets-list.sh` — key names only;
- `utilities/secrets-view.sh` — read-only decrypted view;
- `utilities/secrets-export-recovery-kit.sh` — recovery document export.

Mutating secret paths are root-operated and guarded.

`secrets-schema.yaml` is the key/transform/apply source of truth. See [SECRETS-SCHEMA.md](SECRETS-SCHEMA.md).

### `recover.sh`

`recover.sh` is the state-volume replacement-host recovery path, not an ordinary backup restore wrapper.

It requires:

- a recovered state directory;
- the offline Age private identity that matches the manifest/policy;
- the exact repository commit recorded by the recovery manifest.

Recovery acquires the shared operation guard before creating recovery backups, generating keys, staging files, or promoting artifacts. Non-interactive contention exits with status `75` without mutating recovery state; inspect the active owner with `sudo make operations` and retry after it finishes.

Recovery stages ciphertext, a replacement operational Age key, SOPS policy, persistent environment, DR manifest, and required sentinel state under one local pre-commit rollback boundary. After the recovery identity/config commits, startup or `/alive` failure remains non-zero but does not revert the committed recovery artifacts.

See [ARCHITECTURE.md](ARCHITECTURE.md) and [DISASTER-RECOVERY.md](DISASTER-RECOVERY.md).

## Environment utility

### `utilities/env-edit.sh`

The operator-editable non-secret environment is repository `.env`.

Normal workflow:

```bash
sudo make edit-env
sudo make sync-env
utilities/env-edit.sh status
```

`sync` writes the current accepted operator environment into persistent runtime configuration. `setup-systemd.sh install` installs the current accepted environment into `/etc/vaultwarden/vaultwarden.env` for managed automation.

Runtime environment loading prefers the installed environment when present, then persistent `install.env`, then repository `.env` as bootstrap/legacy fallback.

## Storage utility

### `utilities/setup-storage.sh`

Modes:

```bash
sudo utilities/setup-storage.sh setup
sudo utilities/setup-storage.sh verify
sudo utilities/setup-storage.sh migrate <subcommand>
```

`setup` provisions/validates the state layout and optional attached volume.

`verify` is read-only and checks known storage/permission contracts.

`migrate` routes to `lib/migrate.sh`, which owns resumable boot-to-block/block-to-boot or directory-to-directory migration behavior.

Important migration controls include explicit formatting authorization, the `.vw-data-volume` sentinel, persistent migration state, resume/abort/verify subcommands, and service start policy.

See [VOLUME-MIGRATION.md](VOLUME-MIGRATION.md).

## Systemd utility

### `utilities/setup-systemd.sh`

Actions:

```bash
sudo utilities/setup-systemd.sh install
sudo utilities/setup-systemd.sh validate
sudo utilities/setup-systemd.sh status
sudo utilities/setup-systemd.sh remove
```

Installed runtime lives under:

```text
/opt/vaultwarden-scripts/
/etc/vaultwarden/
/etc/systemd/system/
```

`install` enables managed timers and starts them only according to the requested start policy.

Use:

```bash
sudo utilities/setup-systemd.sh install --enable-now
```

only when the host is ready for scheduled jobs.

Use:

```bash
sudo utilities/setup-systemd.sh install --no-enable-now
```

for recovery/manual-inspection hosts that are not ready to run scheduled backup/maintenance work immediately.

`validate` checks installed scripts, libraries, units, rendered startup service, required environment/key permissions, and managed timer readiness. Run install + validate after managed repository code changes.

The DB backup, full backup, and routine maintenance services use soft process/I/O scheduling priority (`Nice=10`, best-effort I/O, priority `7`). These are not hard CPU, memory, or I/O quotas.

## CrowdSec utilities

### `utilities/setup-crowdsec.sh`

Owns CrowdSec, the host firewall bouncer, the Cloudflare Workers bouncer, and
the opt-in marked CrowdSec email-plugin/profile reconciliation path. The email
plugin uses the existing host-loopback Postfix relay and performs static
CrowdSec validation without making live mail delivery part of normal setup.

### `utilities/crowdsec-email.sh`

Provides the focused root-operated control surface for optional CrowdSec security-event email:

```bash
sudo ./utilities/crowdsec-email.sh enable
sudo ./utilities/crowdsec-email.sh status
sudo ./utilities/crowdsec-email.sh test
sudo ./utilities/crowdsec-email.sh disable
```

`enable` and `disable` update the non-secret environment transactionally and delegate to the established CrowdSec reconciliation path. `status` checks the enablement flag and VaultWarden-OCI managed markers; `test` dispatches through the installed plugin but does not prove mailbox receipt.

### `utilities/crowdsec-worker-apply.sh`

Re-renders/applies the Workers bouncer configuration from the current SOPS secret values. Use after rotating the bouncer token/account/zone values when the schema apply path directs that operation.

### `utilities/maintenance-update-firewall.sh`

Refreshes Cloudflare ingress ranges in the supported host firewall path. Operation contention is exit `75` where the caller/systemd contract treats active-operation overlap as a clean skip.

### `utilities/maintenance-update-dns.sh`

Updates the Cloudflare DNS A record from the current public IP. It also preserves the expected exit `75` contention contract.

See [CROWDSEC.md](CROWDSEC.md).

## Permission repair

### `utilities/repair-permissions.sh`

Normal repair:

```bash
sudo utilities/repair-permissions.sh
```

Read-only check:

```bash
sudo utilities/repair-permissions.sh --check
```

The helper applies explicit known-path contracts. It is not a broad `chmod -R`/`chown -R` wrapper for the entire project state.

See [RESTORE-RUNTIME-PERMISSIONS.md](RESTORE-RUNTIME-PERMISSIONS.md).

## Production-readiness utilities

### `utilities/smoke-test.sh`

Runs the live production readiness checks. Exit `0` requires no failed and no skipped checks.

The systemd portion delegates to the canonical installed-runtime validator instead of maintaining another timer/unit inventory.

### `utilities/pre-production-drill.sh`

Runs the repository's non-destructive pre-production rehearsal. Explicit skip flags are the normal source of skipped drill steps; required restore rehearsal prerequisites must not silently become a passing drill.

The drill uses the canonical backup verifier for latest-backup selection rather than independently naming one archive and verifying another.

## Uninstall/test reset

### `utilities/uninstall-vaultwarden.sh`

Owns project teardown and same-VM test reset.

Use a dry run before destructive teardown:

```bash
sudo ./utilities/uninstall-vaultwarden.sh run --dry-run
```

For repeated setup/restore acceptance testing while preserving the Git checkout:

```bash
sudo ./utilities/uninstall-vaultwarden.sh run \
  --test-reset \
  --i-have-saved-my-recovery-kit
```

The uninstall verifies known managed residuals and fails instead of reporting success when a managed stack artifact remains.

## Shared libraries

| Library | Primary ownership |
| :-- | :-- |
| `lib/log.sh` | logging/output helpers |
| `lib/defaults.sh` | canonical project defaults and critical service policy |
| `lib/config.sh` | environment loading, paths, configuration resolution |
| `lib/common.sh` | shared shell/system helpers |
| `lib/operations.sh` | global/specific `flock` operation guard and operator metadata |
| `lib/docker.sh` | Docker/Compose helpers |
| `lib/crypto.sh` | SOPS/Age, hashing, key health/rotation support |
| `lib/schema.sh` | `secrets-schema.yaml` accessors/validation |
| `lib/secrets.sh` | SOPS secret decrypt/materialization helpers |
| `lib/backup-utils.sh` | backup verification, metadata, retention, rclone config validation |
| `lib/storage.sh` | storage readiness, device/mount/sentinel safety |
| `lib/migrate.sh` | resumable storage migration pipeline |
| `lib/runtime-permissions.sh` | post-restore runtime permission repair |
| `lib/email.sh` | operational email provider/SMTP chain |
| `lib/maintenance-utils.sh` | shared maintenance helpers |
| `lib/crowdsec-worker.sh` | CrowdSec Workers configuration/application helpers |
| `lib/validate.sh` | shared validation helpers |

When changing a library contract, trace every public caller, systemd-installed caller, and test that sources it.

## Tests and CI ownership

The canonical permanent Bash test entry point is:

```bash
./tests/run-tests.sh all
```

`tests/run-tests.sh` owns the registered permanent case inventory under `tests/suites/<suite>/case-*.bash` together with the architecture check, and fails when a registered case is missing or duplicated. Cases execute directly at their registered paths; the runner does not create compatibility files or symlinks in the checkout.

GitHub Actions calls the four public suites through the runner. The Makefile and workflow YAML must not maintain a second permanent case-file inventory.

The documentation workflow also covers contract-owning changes under `crowdsec/**`, `VERSION`, and `docker-compose.override.dev.yml.example`. It validates both production Compose and production Compose merged with the development override. External actions remain pinned to immutable commit SHAs.

Strict ShellCheck remains an independent CI check.

## Generated command reference

[COMMAND-REFERENCE.md](COMMAND-REFERENCE.md) is generated by:

```bash
bash utilities/write-command-reference.sh
```

The pull-request documentation workflow regenerates it and fails when the committed copy is stale.

Do not hand-edit the generated reference. Change the owning script help text, then regenerate the document.
