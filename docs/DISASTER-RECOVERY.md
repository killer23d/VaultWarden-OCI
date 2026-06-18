# Disaster Recovery

This guide provides a complete, minimal-touchpoint, bare-metal disaster recovery (DR) procedure for restoring VaultWarden from an encrypted remote backup. It covers dependency installation, repository checkout, and single-command restore. The `secrets/` directory is excluded from backup archives. The Age key must be backed up separately.

> **See also:** [README.md](../README.md) — project overview, quick-start, and links to all other docs.

## Prerequisites

- Fresh hardware or VM provisioned and OS installed.
- The Recovery Kit file path (containing your offline age credential).
- The rclone remote name where your full backup is stored.
- `git` installed on the target system.

## What a Full Backup Contains

Full backups are your scheduled DR artifact. They contain exactly what is needed to restore your VaultWarden instance, excluding security-sensitive files.

| Included in Full Backup | Excluded from Full Backup |
| :-- | :-- |
| Project root files (`docker-compose.yml`, `.env`, scripts, docs, `lib/`, systemd files, etc.) | `secrets/` directory |
| Caddy configuration (`caddy/`) | Age key |
| Crowdsec configuration (`crowdsec/`) | `backups/` and `logs/` directories |
| State directory (including `db.sqlite3` and attachments) | `.git`, `.rate-limit`, `*.sock`, `*.lock`, `*.tmp`, `*.age.tmp` |

> **Why are secrets excluded?** Keeping secrets out of the archive limits the blast radius if a backup file is ever exfiltrated. Furthermore, the `restore.sh` process generates a *new* Age encryption key upon success. If the old key was included in the backup, it would be stale the moment the restore completes.

## Step 1 — Install System Dependencies

Install the required tools for the restore scripts to function. Note that `age-keygen` is bundled with the `age` package.

**Ubuntu / Debian:**

```bash
sudo apt update
sudo apt install git docker.io docker-compose-plugin age sqlite3 zstd rclone
```

**Oracle Linux / RHEL variants:**

```bash
sudo dnf install git docker docker-compose-plugin age sqlite3 zstd rclone
```

## Step 2 — Clone the Repository

Clone the VaultWarden-OCI repository, then check out the **exact branch or tag that was running when the backup was taken**.

```bash
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
```

> **IMPORTANT:** You must check out the exact branch or tag that was running when the backup was taken to ensure full script compatibility. Using a different revision can cause silent behavioural differences in `restore.sh`, `backup.sh`, and the shared libraries.

**How to find what was running:**

1. **Check the backup `.meta` sidecar file** — every backup archive ships a `*.meta` file that records the `git_ref` (branch/tag) and `git_sha` at the time the backup was created. Inspect it with:
   ```bash
   cat full_backup_YYYYMMDD_HHMMSS.meta
   # Look for: git_ref, git_sha, version fields
   ```
2. **Check your systemd unit or cron job** — the working directory is the cloned repo; `git -C /path/to/VaultWarden-OCI describe --tags --exact-match 2>/dev/null || git -C /path/to/VaultWarden-OCI rev-parse --abbrev-ref HEAD` shows the active ref.
3. **Fall back to the VERSION file** — if the meta sidecar is unavailable, inspect `VERSION` in the repo root to match the version tag closest to your backup date.

Once you have the ref, check it out:

```bash
# By tag (recommended for production):
git checkout v1.2.3

# By branch:
git checkout Beta
```

## Step 3 — Configure rclone (if not pre-configured)

Configure the rclone remote where your backups are stored.

```bash
rclone config
```

> Reference: If `RCLONE_REMOTE_NAME` is absent from your environment, `restore.sh interactive --remote` will gracefully prompt you for the remote name interactively.

## Step 4 — Run the DR Restore

Run the following single command to trigger the bare-metal restore:

```bash
sudo ./restore.sh interactive --remote --from-recovery-kit /path/to/recovery-kit.txt
```

**What happens automatically:**
- `.env` is restored from the backup.
- `docker-compose.yml` and `caddy`/`crowdsec` configs are restored.
- `db.sqlite3` and attachments are restored.
- A **NEW** age key is generated; operator must type `SAVED` to confirm.
- Services are started automatically.
- A post-restore health check runs.

## Step 5 — Sync systemd (if using systemd mode)

Sync the newly generated age key and update the systemd timers.

```bash
sudo ./setup.sh systemd install
```

> **Why?** This step syncs the new age key to `/etc/vaultwarden/age-key.txt` and updates the `SOPS_AGE_KEY_FILE` reference in your systemd unit files. Without this, automated tasks like scheduled backups will fail.

## Step 6 — Save the New Recovery Kit

The restore process generates a new recovery kit at `/root/vaultwarden-recovery-kit-<timestamp>.txt`.

You must copy this file to your offline storage and delete it from `/root/`.

> **WARNING:** Loss of this file equals the inability to decrypt future backups.

## Step 7 — Verify the Restore

Verify that the restore was completely successful and backups are functioning.

```bash
sudo ./backup.sh verify
sudo ./maintenance.sh health --comprehensive
```

Expected output indicators should show that services are running, the database is intact, and backups can be successfully created.

---

## Archive Format Reference

Full backups use the `.tar.zst.age` extension: a **zstd-compressed tar archive encrypted with Age**. Each backup also ships two sidecar files:

| File | Purpose |
| :-- | :-- |
| `*.age` | Encrypted backup archive |
| `*.sha256` | Post-encryption SHA-256 checksum |
| `*.meta` | Metadata: type, timestamp, archive format, version, git_ref |

### Manual decompression pipeline

```bash
# Full / emergency backup (.tar.zst.age)
age -d -i /path/to/age-key.txt full_backup_YYYYMMDD_HHMMSS.tar.zst.age \
  | zstd -d -T0 -c \
  | tar -xf -

# Database-only backup (.sqlite3.age) — no tar wrapper
age -d -i /path/to/age-key.txt db_backup_YYYYMMDD_HHMMSS.sqlite3.age \
  > db.sqlite3
```

> **Legacy format:** Backups created before the zstd migration use `.tar.gz.age`. Replace `zstd -d -T0 -c` with `gunzip -c` for those files.

---

## Age Key Quick Reference

The `restore.sh` process generates a **new** age key after every successful restore. The key is resolved from the first readable location in this order:

| Priority | Path | When it applies |
| :-- | :-- | :-- |
| 1 | `$AGE_KEY_FILE` env var | Explicit operator override |
| 2 | `/etc/vaultwarden/age-key.txt` | Post-install production path |
| 3 | `secrets/keys/age-key.txt` | Repo-local fallback (dev / pre-install) |

After `setup.sh systemd install` runs (Step 5 above), the active path is `/etc/vaultwarden/age-key.txt`. Use the following commands to inspect it:

```bash
# Show which age key file is currently resolving
make key-path

# Full health check: permissions, decodability, SOPS_AGE_KEY_FILE alignment
make key-health

# Display path, permissions, and public key fingerprint
make key-show
```

> **Update your escrow after every restore.** The new key must be exported to your password manager before the old bootstrap copy becomes stale:
> ```bash
> ./utilities/secrets-export-recovery-kit.sh
> shred -fuz ~/vaultwarden-age-key-escrow.txt   # delete after copying
> ```

---

## Post-Recovery Checklist

Run through these items after every bare-metal restore to confirm the stack is fully operational:

| # | Check | Command |
| :-- | :-- | :-- |
| 1 | Services are running | `make status` |
| 2 | VaultWarden responds on HTTPS | `curl -sI https://vault.yourdomain.com` |
| 3 | Age key path resolved correctly | `make key-path` |
| 4 | Age key is healthy | `make key-health` |
| 5 | New recovery kit saved to password manager | `./utilities/secrets-export-recovery-kit.sh` |
| 6 | Old recovery kit deleted from `/root/` | `shred -fuz /root/vaultwarden-recovery-kit-*.txt` |
| 7 | Systemd timers active | `make timers` |
| 8 | First automated backup succeeds | `sudo ./backup.sh run db --rclone` |
| 9 | Backup verification passes | `sudo ./backup.sh verify` |
| 10 | Comprehensive health report clean | `sudo ./maintenance.sh health --comprehensive` |

## Non-production USB recovery rehearsal

Perform one recovery rehearsal during a planned maintenance or testing window
using a disposable Ubuntu VM or another isolated test VM. Attach only a
snapshot or copy of the production state volume: never mount or modify the live
production state volume. Use a copy of the offline USB Age key, never its only
existing copy.

Keep the rehearsal isolated from production DNS and inbound production traffic.
Do not use the production hostname unless DNS resolution and network routing
are safely overridden so no test traffic can reach or replace production.

> **Warning:** `recover.sh` may rekey and modify the state supplied to it. A
> disposable state-volume copy is mandatory; this procedure is not safe against
> the live production state directory.

On the isolated VM, run:

```bash
sudo ./recover.sh \
  --state-dir <copied-state-path> \
  --key <copied-usb-key-path>

sudo ./setup.sh systemd install

sudo ./utilities/smoke-test.sh
```

`recover.sh` restores and starts the stack directly. Then
`setup.sh systemd install` installs and enables the production startup unit and
timers. Run the smoke test last because it validates that installed systemd
unit and its active service state.

Confirm and record that:

- Docker Compose configuration is valid;
- `/etc/systemd/system/vaultwarden-startup.service` validates;
- `vaultwarden-startup.service` is active;
- `/run/vaultwarden-oci/secrets` is owned by `root:root` with mode `0700`;
- each runtime secret file is owned by `root:root` with mode `0444`;
- the persistent SOPS ciphertext decrypts successfully without displaying
  plaintext;
- the Vaultwarden `/api/alive` endpoint responds successfully;
- the copied state volume, not production state, was used; and
- production state and production availability remained untouched.

After recording a non-secret date and pass/fail result, stop the isolated test
VM. Securely erase or destroy the copied Age key, destroy the copied state
volume or snapshot clone, and destroy the disposable VM when it is no longer
needed. Confirm that no plaintext recovery output remains on the VM. This is a
manual, isolated rehearsal—not automated recovery CI.

## Backup Type Reference

Both **Full** and **Emergency** backups call `perform_full_backup()` identically. The only difference is when and why they are triggered — their archive contents are the same. Neither type includes the `secrets/` directory or the Age key.

| Type | Contents | Purpose | Valid DR Artifact? | When Created |
| :-- | :-- | :-- | :-- | :-- |
| **Full** | Project root (including scripts, docs, `lib/`, and systemd files) + state dir, excluding `secrets/` and the Age key | Scheduled DR artifact | **Yes** | Weekly (via systemd timer) |
| **Emergency** | Same contents as full backup; also excludes `secrets/` and the Age key | Pre-restore safety snapshot | **No*** | Automatically before running `restore.sh` |
| **Database** | `db.sqlite3` only | Quick rollback of vault state | **No** | Daily (via systemd timer) |

> \* Emergency backups are **not** a DR artifact because they are taken mid-restore on the *old* system state — they exist solely as a rollback safety net. They have the same archive format and contents as a full backup (`secrets/` excluded from both). Use a **scheduled full backup** as your primary DR source.

## Non-Obvious Pitfalls

- **Cloning a different branch/tag:** Cloning a different branch/tag than the original install can lead to script incompatibilities.
- **Re-running setup after a restore:** Use `sudo ./setup.sh install --domain DOMAIN --email EMAIL` if you need to regenerate config on the recovered host.
- **rclone remote name not configured and `.env` absent:** The interactive prompt handles this seamlessly.
- **Recovery kit has wrong permissions:** Ensure the file has strict permissions (chmod `600`).
- **Forgetting `setup.sh systemd install`:** Failing to run this after a restore leaves the old key in systemd, breaking automated tasks.
- **Age key mismatch after fresh `setup.sh` before restore:** Running `setup.sh install --force` before restoring creates a new age key that doesn't match the one that encrypted your backup. Always supply the key from your bootstrap escrow (`RESTORE_AGE_KEY_FILE`) or let `restore.sh` prompt you.
- **Emergency kit key vs full-backup key:** Emergency and full backups use the same `perform_full_backup()` code path and exclude `secrets/` identically. Neither embeds an age key inside the archive. You must always supply the age key separately from your bootstrap escrow — regardless of backup type.
- **`make key-path` shows wrong path after restore:** Confirm `setup.sh systemd install` has been run; the systemd service environment may still reference the old repo-local path.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| :-- | :-- | :-- |
| `age: no identity matched any recipient` | Wrong age key for this backup | Supply the key that was active when the backup was taken; use bootstrap escrow if lost |
| `restore.sh: .env not found` | Restore ran before `.env` was populated | Run `./setup.sh install` first, then re-run the restore |
| `rclone: no remote named X` | Remote not configured on new host | Run `rclone config` and create the remote with the same name |
| `make key-health` fails after restore | `SOPS_AGE_KEY_FILE` in `.env` points to old path | Verify with `make key-path`; re-run `setup.sh systemd install` |
| `make key-path` prints `ERROR: No readable age key found` | Key absent at all three resolution locations | Place key via `sudo install -m 600 age-key.txt /etc/vaultwarden/age-key.txt` |
| Services start but backups fail | Systemd unit still uses old key path | Re-run `sudo ./setup.sh systemd install` to resync the key reference |
| `zstd: error 70` or `tar: unexpected EOF` | Wrong decompressor or truncated download | Confirm extension is `.tar.zst.age` and re-download; use `zstd -d`, not `gunzip` |
| Permission/ownership errors after restore | UID/GID differences or stale generated config on the new host | Re-run `sudo ./setup.sh install --domain DOMAIN --email EMAIL` |
| `db.sqlite3: disk I/O error` | SQLite WAL not fully checkpointed in backup | Use a full or emergency backup instead of a db-only backup for this restore |

## Recovery Kit Best Practices

The recovery kit contains your offline credential. Treat it with extreme care.

**Where to store it:**
- A secure password manager (e.g., Bitwarden, 1Password)
- An encrypted offline USB drive
- Printed on paper and stored in a physical fireproof safe

**What NOT to do:**
- Do NOT store it on the same server.
- Do NOT store it in the same cloud storage bucket as the backups.
- Do NOT send it via unencrypted email or messaging apps.

---

## Related Documentation

| Doc | Contents |
| :-- | :-- |
| [README.md](../README.md) | Project overview, quick-start, and full documentation index |
| [BACKUP-RESTORE.md](BACKUP-RESTORE.md) | Full backup strategy, retention policy, and the 12-step restore procedure |
| [BOOTSTRAP_KEY_RECOVERY.md](BOOTSTRAP_KEY_RECOVERY.md) | Age key recovery procedures when the bootstrap key is lost |
| [OPERATIONS.md](OPERATIONS.md) | Day-to-day ops, update/rollback phases |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Common issues and fixes |
