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

## Backup architecture

The backup model has three intentional tiers:

- `db` — quick encrypted SQLite rollback;
- `full` — normal disaster-recovery archive without the live operational Age private key;
- `emergency` — clone-grade secrets-bearing capsule that can include staged `/etc/vaultwarden` key/config material and is independently sealed.

All tiers use a verified SQLite snapshot. Full/emergency archive construction excludes transient/runtime material and injects the verified staged database at the normal live database path.

See [BACKUP-RESTORE.md](BACKUP-RESTORE.md).

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
