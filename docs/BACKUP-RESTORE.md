# Backup & Restore — VaultWarden-OCI

Operator reference for the current root-operated backup and restore model, boot/data-volume preflight, Age key handling, operator-controlled service start, and post-restore runtime permission repair.

Related docs: [DISASTER-RECOVERY.md](DISASTER-RECOVERY.md) · [BOOTSTRAP_KEY_RECOVERY.md](BOOTSTRAP_KEY_RECOVERY.md) · [RESTORE-RUNTIME-PERMISSIONS.md](RESTORE-RUNTIME-PERMISSIONS.md) · [OPERATIONS.md](OPERATIONS.md)

---

## 💾 Backup Tiers

VaultWarden-OCI has three deliberately different backup tiers:

| Tier | Use | Contents | Key handling |
| --- | --- | --- | --- |
| `db` | Quick database rollback | A single encrypted, integrity-checked SQLite snapshot (`.sqlite3.age`) | Encrypted to the operational Age recipient. |
| `full` | Normal replacement-host disaster recovery | Project/state content required for DR, persistent config, encrypted SOPS `secrets.yaml`, metadata/sidecars, and a verified staged database | Excludes the live operational Age private key. Restore requires a private key for a recipient that encrypted the selected backup. |
| `emergency` | Fastest clone-style recovery | Full DR content plus staged `/etc/vaultwarden` key/config material such as `age-key.txt`, `vaultwarden.env`, and `rclone.conf` when present | Independently sealed with `age -p` or `EMERGENCY_BACKUP_AGE_RECIPIENT`; never protected only by the operational key it can contain. |

All tiers use a complete verified SQLite snapshot. The normal snapshot path uses the SQLite Online Backup API. When the implementation must use its controlled fallback, Vaultwarden is stopped, WAL state is handled, the database is copied and integrity-checked, and service state is restored according to the owning backup path.

Full/emergency archive construction excludes the live SQLite/WAL/SHM set, backup trees, logs, transient runtime secrets, sockets/locks, temporary state, and `.pre-restore-*` snapshots. The verified staged database is inserted at the normal live database path.

> **Warning:** Emergency backups are clone-grade secrets-bearing artifacts. Treat them like a password-manager vault export. Protect the emergency passphrase or separate emergency recipient identity independently from the archive.

The optional offline Age recovery recipient is not the same thing as an emergency-backup passphrase or `EMERGENCY_BACKUP_AGE_RECIPIENT`.

---

## 📦 Creating Backups

Production backup operations are root-operated:

```bash
# Database rollback backup
sudo ./backup.sh run db
sudo make backup

# Full DR backup
sudo ./backup.sh run full
sudo make backup-full

# Independently sealed emergency capsule
sudo ./backup.sh run emergency
sudo make backup-emergency
```

### Full verification

Use end-to-end verification before major changes, after storage migration, and for periodic DR confidence checks:

```bash
sudo ./backup.sh run full --full-verification
sudo ./backup.sh run emergency --full-verification
```

Required verification failure is a backup failure. A newly created archive that fails required quick/full verification is discarded with its normal sidecars and is not left as a normal restore candidate. The failed backup does not run normal retention/pruning or success notification behavior.

### Offsite sync

When rclone is configured:

```bash
sudo ./backup.sh run db --rclone
sudo ./backup.sh run full --full-verification --rclone
sudo ./backup.sh sync
```

`backup.sh sync` copies retained local archives and sidecars to the matching remote type folders and then applies the configured remote retention contract. It is not a blind mirror-delete of every remote file absent locally.

A requested offsite sync that is skipped or fails must not be described as completed offsite protection.

### Retention

Current defaults from `.env.example` are:

| Tier | Default retention |
| :-- | :-- |
| `db` | 14 days |
| `full` | 30 days |
| `emergency` | 90 days |

Override a run with a positive integer:

```bash
sudo ./backup.sh run full --keep 30
```

Retention always preserves the newest parseable timestamped archive for a tier, even when it is older than the retention window. Primary archives with unparseable names fail safe and are not automatically deleted.

Sidecars associated with deleted primary archives are removed with the archive. Orphaned sidecars are cleaned separately.

---

## 🔎 Backup Verification

Verify the canonical latest backup selection:

```bash
sudo ./backup.sh verify
```

The verifier owns latest-backup selection and prints the exact target it verifies.

Do not build operational procedures that independently name one "latest" archive and then invoke the canonical verifier without passing that exact archive; the two selection methods can disagree.

When a backup was encrypted before an operational Age key rotation, verification may require the older matching private identity. Retain old recovery identities until dependent backup generations are retired.

---

## 🔎 Restore Storage Preflight

Before destructive full/emergency restore, inspect archive and target storage compatibility:

```bash
sudo ./restore.sh inspect --remote
```

or use the interactive inspect mode documented by `restore.sh --help`.

The preflight reports source/target storage layout, live database presence, snapshot-only databases, required directories, and a recommended next action.

Database backups are storage-layout independent. Full/emergency restores recover broader state and require a compatible prepared target layout.

When the selected backup expects attached-volume state, restore must not silently write that state to boot storage. Attach/mount/adopt the intended volume first or choose a database-only restore.

Prepared attached-volume targets participate in the `.vw-data-volume` sentinel contract. Restore may recreate safe missing directory/sentinel state on an already mounted writable target, but it does not format, partition, or guess block devices.

---

## 🔄 Restore Flow

The restore workflow is root-operated and follows these boundaries:

| Phase | Contract |
| :-- | :-- |
| Selection | select local/remote archive by supported grammar |
| Preflight | validate archive metadata and target storage before destructive work |
| Key/protection | resolve the private Age identity or independent emergency protection needed by the selected archive |
| Integrity | verify sidecars/metadata according to the archive contract |
| Safety snapshot | create the configured pre-restore backup unless explicitly skipped |
| Stop | stop the live stack |
| Stage/promote | restore database or broader archive content through the owning transaction |
| Re-key | reconcile persistent SOPS secrets and the operational Age key where the selected restore path requires it |
| Permission repair | apply the target-host runtime permission contract |
| Start policy | auto, ask, or manual |
| Health | verify `/alive` and the normal health path when services are started |

An incomplete restore must not be presented as successful.

Full/emergency restore extracts portable archive content without trusting stale owners/modes and then applies the target-host permission contract. See [RESTORE-RUNTIME-PERMISSIONS.md](RESTORE-RUNTIME-PERMISSIONS.md).

---

## 🔐 Supplying a Decryption Identity

Use a private key that can decrypt the selected archive, which may differ from the server's current operational key:

```bash
# Interactive/default key resolution
sudo ./restore.sh latest full

# Explicit key file
sudo ./restore.sh latest full \
  --key-file /secure/path/old-age-key.txt

# Recovery kit
sudo ./restore.sh interactive --remote \
  --from-recovery-kit /secure/path/recovery-kit.txt
```

For scripted restore, `RESTORE_AGE_KEY_FILE` can provide the configured non-interactive key-file override.

Use:

```bash
./restore.sh --help
```

or [COMMAND-REFERENCE.md](COMMAND-REFERENCE.md) for exact current parser grammar and option precedence.

### Emergency protection

Emergency backups may be:

- passphrase-sealed with `age -p`; or
- encrypted to `EMERGENCY_BACKUP_AGE_RECIPIENT`.

A passphrase-sealed archive prompts for the emergency passphrase during decrypt/verification.

The emergency protection is independent from any operational Age key carried inside the capsule.

### Pre-restore emergency snapshot prompt

A separate emergency passphrase prompt can appear when restore creates a pre-restore emergency snapshot of the current host before overwrite. That passphrase protects the safety snapshot; it is not necessarily the credential for the selected `db`/`full` archive.

Keep the pre-restore safety snapshot on an existing/live host unless you intentionally accept the rollback risk.

---

## 🚦 Service Start Policy

Restore and storage migration support explicit start behavior:

| Option | Behavior |
| :-- | :-- |
| `--start-policy auto` or `--start` | start services automatically after successful mutation |
| `--start-policy ask` | prompt before start; interactive restore normally uses an operator gate |
| `--start-policy manual` or `--no-start` | keep services stopped and print manual next steps |

Use `ask` or `manual` when you need to inspect storage, `/etc/vaultwarden`, Cloudflare/DNS, firewall, rclone, or configuration before startup.

Required confirmation timeout/EOF is not converted to a successful implicit answer. Restore fails safe at the current guarded acknowledgement point and prints next steps.

Manual live-stack checklist:

```bash
sudo utilities/repair-permissions.sh
sudo ./startup.sh --skip-pull
docker compose ps
docker compose logs --tail=100
sudo ./maintenance.sh health
```

Do not enable scheduled systemd jobs merely because the live stack starts.

---

## 🧰 Post-Restore Runtime Permission Repair

Full/emergency restore calls the shared repair before the service-start gate.

Manual check/repair:

```bash
sudo utilities/repair-permissions.sh --check
sudo utilities/repair-permissions.sh
sudo ./maintenance.sh health
```

The repair normalizes:

- `${PROJECT_STATE_DIR}/data` and Vaultwarden logs to `PUID:PGID`;
- `${PROJECT_STATE_DIR}/caddy/data`, `${PROJECT_STATE_DIR}/caddy/config`, and `${PROJECT_STATE_DIR}/logs/caddy` to Caddy UID/GID `2000:2000` with the defined runtime modes;
- root-operated state under `${PROJECT_STATE_DIR}/config`, `${PROJECT_STATE_DIR}/secrets`, and `/etc/vaultwarden`;
- transient secret source state under `/run/vaultwarden-oci/secrets`;
- the restored init-permissions sentinel so the replacement host cannot inherit a stale skip decision.

Do not use broad fixes such as:

```bash
sudo chmod -R 777 "$PROJECT_STATE_DIR"
sudo chown -R 2000:2000 "$PROJECT_STATE_DIR"
```

Those commands can expose root-operated secrets and break Vaultwarden application ownership.

---

## 🧭 Common Restore Scenarios

### Database rollback

```bash
sudo ./restore.sh latest db
sudo ./maintenance.sh health
```

Use this when only Vaultwarden database content needs rollback.

### Full replacement-host restore

```bash
sudo ./restore.sh inspect --remote
sudo ./restore.sh interactive --remote \
  --key-file /secure/path/offline-age-key.txt \
  --start-policy ask
```

After the restored live stack, storage, networking, rclone, and Cloudflare state are ready for automation:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

### Emergency clone-style restore

```bash
sudo ./restore.sh interactive --remote --start-policy ask
sudo utilities/repair-permissions.sh --check
sudo ./maintenance.sh health
```

Emergency restore may recover staged `/etc/vaultwarden` key/config material from the independently sealed capsule.

Before enabling scheduled jobs:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

### Failed update rollback

The maintenance update path may invoke restore when its post-update health contract fails. Manual rollback remains available through the current restore grammar, for example:

```bash
sudo ./restore.sh latest full --force --no-backup
```

Use `--force` only when the preflight and selected archive are already understood. It does not bypass shared operation guards.

---

## Verification After Restore

After any restore:

```bash
sudo ./maintenance.sh health
sudo make key-health
sudo ./backup.sh verify
sudo utilities/repair-permissions.sh --check
```

When the host is intended to return to automated production:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

A successful browser login is useful but is not the production-readiness gate.

For local Caddy/TLS symptoms:

```bash
DOMAIN="vault.example.com"

curl -vk --resolve "$DOMAIN:443:127.0.0.1" \
  "https://$DOMAIN/alive" \
  -o /dev/null \
  -w "local HTTPS /alive: HTTP %{http_code}\n"

curl -vk --resolve "$DOMAIN:443:127.0.0.1" \
  "https://$DOMAIN/api/config" \
  -o /dev/null \
  -w "local HTTPS /api/config: HTTP %{http_code}\n"

sudo docker logs vaultwarden_caddy --tail=120 2>&1 \
  | grep -Ei 'permission|certificate|tls|handshake|error|warn|storage|autosave' || true
```

Expected healthy local endpoints return HTTP `200`, and the normal health path reports no Caddy storage permission drift.

---

## Recovery Material

Export a fresh recovery kit after initial setup and after operational Age key rotation or restore-driven replacement of the live key:

```bash
sudo ./utilities/secrets-export-recovery-kit.sh
```

Store it in a trusted password manager and a separate offline recovery location. Remove plaintext copies from the server after verifying the off-host copies.

Retain historical private identities required to decrypt still-retained backup generations.

See [BOOTSTRAP_KEY_RECOVERY.md](BOOTSTRAP_KEY_RECOVERY.md).

---

## Operational Checklist

- Daily: database backup succeeds and requested offsite protection completes.
- Weekly: full backup succeeds with periodic `--full-verification`.
- Monthly: independently sealed emergency backup is created and protected separately.
- After storage migration: create and fully verify a fresh full backup.
- After Age key rotation: export new recovery material and retain old identities needed by retained backups.
- Quarterly: rehearse restore on a disposable host or copied state volume; never rehearse destructive recovery on the only live production state.
- Before go-live or after major DR: `systemd validate` and smoke test pass without required checks skipped.
