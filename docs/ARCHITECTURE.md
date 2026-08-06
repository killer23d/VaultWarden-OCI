# VaultWarden-OCI Architecture

This document describes the current state, configuration, secret, automation, and recovery boundaries. For the supported production matrix and project non-goals, see [PROJECT-BOUNDARY.md](PROJECT-BOUNDARY.md).

## Configuration and environment flow

The project separates the operator-editable repository environment from persistent and installed runtime copies:

- repository `.env` is edited through `sudo make edit-env` / `utilities/env-edit.sh`;
- `${PROJECT_STATE_DIR}/config/install.env` is the persistent root-owned runtime configuration stored with project state;
- `/etc/vaultwarden/vaultwarden.env` is the installed systemd environment used by managed automation.

`load_project_environment` first resolves the bootstrap state directory from an explicit caller override, then repository `.env`, then the installed systemd environment, with `/var/lib/vaultwarden` as the default.

After the state directory is known, one complete runtime environment is loaded in this order:

1. `/etc/vaultwarden/vaultwarden.env`, when installed;
2. `${PROJECT_STATE_DIR}/config/install.env`;
3. repository `.env` as the legacy/bootstrap fallback.

Explicit caller overrides for state directory, data device, data mount, and SOPS Age key path are reapplied after loading.

This ordering is deliberate: installed systemd jobs use the root-owned installed environment, normal persistent state survives repository replacement, and repository `.env` remains the authoring/bootstrap surface rather than a second live production environment.

## Persistent state layout

Persistent project state is rooted at `PROJECT_STATE_DIR`, normally `/var/lib/vaultwarden` in boot-volume mode or the configured `DATA_VOLUME_MOUNT` in attached-volume mode.

Important paths are:

```text
${PROJECT_STATE_DIR}/config/install.env
${PROJECT_STATE_DIR}/config/dr-manifest.env
${PROJECT_STATE_DIR}/secrets/secrets.yaml
${PROJECT_STATE_DIR}/data/
${PROJECT_STATE_DIR}/caddy/
${PROJECT_STATE_DIR}/logs/
${PROJECT_STATE_DIR}/backups/{db,full,emergency}/
```

`config/` and `secrets/` are root-operated private state. Vaultwarden application data uses the configured `PUID:PGID`. Caddy runtime storage and logs are normalized for the Caddy container UID/GID `2000:2000` when runtime permission repair is applied.

When a dedicated data volume is configured, `PROJECT_STATE_DIR` must match `DATA_VOLUME_MOUNT`, the configured volume must be mounted, and the `.vw-data-volume` sentinel participates in the storage ownership/safety contract.

## Secret lifetimes

The persistent SOPS ciphertext is:

```text
${PROJECT_STATE_DIR}/secrets/secrets.yaml
```

The live operational Age key is installed at:

```text
/etc/vaultwarden/age-key.txt
```

Decrypted Docker Compose secret source files are transient and are created under:

```text
/run/vaultwarden-oci/secrets/
```

`/run` is volatile. Startup recreates the runtime files from SOPS ciphertext; decrypted runtime secrets are not intended to become persistent project state.

## Age recipients and recovery material

The normal SOPS policy contains the operational Age recipient and may include a separate offline recovery Age recipient.

The offline recovery private key stays offline. Only its public recipient may be stored in project policy/manifest state. The offline recovery key is not the same thing as an emergency-backup passphrase or `EMERGENCY_BACKUP_AGE_RECIPIENT`.

The operational Age key can be rotated. Recovery and rotation procedures must preserve access to backup generations encrypted to older recipients until those backups expire or are deliberately retired.

## Startup and systemd runtime

Normal foreground lifecycle runs through `startup.sh` and the root-operated Make targets.

Managed systemd jobs do not execute the repository checkout directly. `utilities/setup-systemd.sh install` copies managed scripts into:

```text
/opt/vaultwarden-scripts/
```

and installs managed units under:

```text
/etc/systemd/system/
```

It also installs the systemd environment and operational Age key under `/etc/vaultwarden`.

Therefore a `git pull` updates repository code but does not activate new code for existing systemd timers. After pulling managed script, library, or unit changes, run:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

On a recovery/manual-inspection host that is not ready for scheduled work, use `--no-enable-now` until state, secrets, networking, rclone, and service readiness have been inspected.

## Shared operation guard

Conflicting mutating workflows use `lib/operations.sh` and `flock`.

Kernel lock state is authoritative. Operation metadata exists for operator diagnostics and interruption handling; lock-file existence by itself is not proof that an operation is active.

One owner-bound Bash holder acquires the global lock before any operation-specific lock. The guarded shell and its ordinary descendants receive no lock descriptors; owner exit closes a private control channel so the holder exits and releases both locks.

Expected non-interactive contention uses exit `75` where the owning script/systemd contract defines a clean skip. Real failures must remain non-zero failures and must not be relabeled as contention.

## Health and maintenance ownership

Health has three profiles: bounded local `--quick`, standard health with no profile flag, and extended `--comprehensive`. The five-minute systemd health service uses quick repair health (`health --quick --fix`) and accepts only `0`, `1`, and `75` as successful statuses. Exit `3` means a critical prerequisite prevented checks; it is not an installation/no-backup success state.

Scheduled daily maintenance is routine maintenance with email reporting. It owns cleanup, canonical retention, online SQLite `PRAGMA optimize` and passive WAL checkpointing, and quick post-maintenance health. DNS and firewall reconciliation remain owned by their dedicated timers. Explicit comprehensive maintenance adds those reconciliations; deep database maintenance is a separate offline backup/integrity/service-stop/`VACUUM` workflow.

The DB backup, full backup, and maintenance units use soft scheduling priority (`Nice=10`, `IOSchedulingClass=best-effort`, `IOSchedulingPriority=7`). These settings express background preference rather than hard CPU, memory, or I/O quotas.

## Backup architecture

The backup model has three intentional tiers:

- `db` — quick encrypted SQLite rollback;
- `full` — normal disaster-recovery archive without the live operational Age private key;
- `emergency` — clone-grade secrets-bearing capsule that can include staged `/etc/vaultwarden` key/config material and is independently sealed.

All tiers use a verified SQLite snapshot. Ordinary database/full payload staging uses the configured backup filesystem while small control material prefers tmpfs; emergency plaintext that may contain private-key material remains on verified capacity-checked tmpfs without persistent fallback. Full verification streams decryption into archive inspection, and atomic publication keeps incomplete candidates out of normal restore selection.

Restore uses a split control/payload workspace model and validates payload/capacity before the destructive service-stop boundary, then repeats the required capacity check after the safety snapshot. See [BACKUP-RESTORE.md](BACKUP-RESTORE.md).

## Dashboard redraw snapshots

Each dashboard redraw reuses process-local snapshots: one Compose-state snapshot, at most one batched inspection for extra container details, and one backup-tree pass. This is an in-process redraw optimization only; there is no persistent cache, collector daemon, database, background worker, or additional timer.

## Compose resource boundary

The production Compose definition retains active standalone hard limits, memory reservations, and security controls. The recent cleanup removed only inactive CPU reservation declarations; operators should not treat those removed reservation values as standalone controls or assume resource controls were removed wholesale.

## Recovery transaction

`recover.sh` is the replacement-host state-volume recovery path. It requires the restored state directory, a private offline Age identity, and the exact repository commit recorded in the recovery manifest.

Before the commit boundary, recovery stages and validates the new recovery identity together:

- SOPS ciphertext;
- replacement operational Age key;
- SOPS policy;
- persistent `install.env`;
- DR manifest;
- data-volume sentinel state when recovery itself must create the sentinel.

The old live artifacts are backed up within the recovery transaction. A pre-commit failure or signal restores the previous recovery identity/config state and removes only sentinel state created by that run.

After staged ciphertext, key, policy, environment, and manifest references validate together, recovery crosses one explicit commit boundary. Startup or `/alive` failure after that point returns non-zero but preserves the newly committed recovery artifacts for operator diagnosis; it does not silently roll back to a mixed old/new identity.

The offline recovery private key is used for decryption in place. Recovery generates and installs a new operational Age key rather than persisting the offline key as the server's live key.

## Runtime permission repair

Full and emergency restore call the shared runtime permission repair before the service-start gate. The repair normalizes:

- Vaultwarden data/log ownership to `PUID:PGID`;
- Caddy data/config/log ownership to UID/GID `2000:2000`;
- root-operated config/secrets and `/etc/vaultwarden` paths;
- transient runtime secret permissions;
- the restored init-permissions sentinel.

See [RESTORE-RUNTIME-PERMISSIONS.md](RESTORE-RUNTIME-PERMISSIONS.md).
