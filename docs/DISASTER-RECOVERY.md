# Disaster Recovery

This guide provides a complete, minimal-touchpoint, bare-metal disaster recovery (DR) procedure for restoring VaultWarden from an encrypted remote backup. It covers dependency installation, repository checkout, and single-command restore. Note that **secrets are explicitly out of scope**; they are excluded to limit blast radius in case of exfiltration, and because the age encryption key rotates after every restore, rendering archived keys immediately stale.

## Prerequisites

- Fresh hardware or VM provisioned and OS installed.
- The Recovery Kit file path (containing your offline age credential).
- The rclone remote name where your full backup is stored.
- `git` installed on the target system.

## What a Full Backup Contains

Full backups are your scheduled DR artifact. They contain exactly what is needed to restore your VaultWarden instance, excluding security-sensitive files.

| Included in Full Backup | Excluded from Full Backup |
| :-- | :-- |
| Project root files (`docker-compose.yml`, `.env`, etc.) | `secrets/` directory (Age keys, SSH keys, passwords) |
| Caddy configuration (`caddy/`) | `*.sh` scripts (pulled fresh via `git clone`) |
| Crowdsec configuration (`crowdsec/`) | `backups/` and `logs/` directories |
| State directory (`db.sqlite3` and attachments) | |

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

Clone the VaultWarden-OCI repository.

```bash
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
```

> **IMPORTANT:** You must check out the exact branch or tag that was running when the backup was taken to ensure full script compatibility.

## Step 3 — Configure rclone (if not pre-configured)

Configure the rclone remote where your backups are stored.

```bash
rclone config
```

> Reference: If `RCLONE_REMOTE_NAME` is absent from your environment, `restore.sh interactive --remote` will gracefully prompt you for the remote name interactively.

## Archive Format Reference

Full backups use the `.tar.zst.age` extension: a **zstd-compressed tar archive encrypted with Age**. Each backup also ships two sidecar files:

| File | Purpose |
| :-- | :-- |
| `*.age` | Encrypted backup archive |
| `*.sha256` | Post-encryption SHA-256 checksum |
| `*.meta` | Metadata: type, timestamp, archive format, version |

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

## Backup Type Reference

| Type | Contents | Purpose | Valid DR Artifact? | When Created |
| :-- | :-- | :-- | :-- | :-- |
| **Full** | Project root (config) + State dir (DB, attachments) | Scheduled DR artifact | **Yes** | Weekly (via systemd timer) |
| **Emergency** | Full + `secrets/` directory + Age key | Pre-restore safety snapshot | **No** | Automatically before running `restore.sh` |
| **Database** | `db.sqlite3` only | Quick rollback of vault state | **No** | Daily (via systemd timer) |

> **Note:** Emergency backups are pre-restore safety snapshots taken automatically by `restore.sh` before any restore begins. They are **NOT** a DR artifact. Full backups are your scheduled DR artifact.

## Non-Obvious Pitfalls

- **Cloning a different branch/tag:** Cloning a different branch/tag than the original install can lead to script incompatibilities.
- **Using `--force` when PUID/PGID are wrong:** This skips the interactive prompt for these values, which could break permissions.
- **rclone remote name not configured and `.env` absent:** The interactive prompt handles this seamlessly.
- **Recovery kit has wrong permissions:** Ensure the file has strict permissions (chmod `600`).
- **Forgetting `setup.sh systemd install`:** Failing to run this after a restore leaves the old key in systemd, breaking automated tasks.
- **Age key mismatch after fresh `setup.sh` before restore:** Running `setup.sh install --force` before restoring creates a new age key that doesn't match the one that encrypted your backup. Always supply the key from inside the emergency kit (`RESTORE_AGE_KEY_FILE`) or let `restore.sh` prompt you.
- **Emergency kit key vs full-backup key:** Emergency kits include their own age key inside the archive. Full backups do not — you must supply the key separately from your bootstrap escrow.
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
| `PUID/PGID permission errors` | UID mismatch between old and new host | Re-run `setup.sh` with correct `--puid` / `--pgid` values |
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
