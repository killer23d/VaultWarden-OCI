# Disaster Recovery — VaultWarden-OCI

This guide is the bare-metal recovery runbook for rebuilding VaultWarden-OCI on a replacement Ubuntu host from encrypted backups. It reflects the current 2026 backup tier model, root-operated lifecycle, block/boot storage preflight, operator-controlled service start, and post-restore runtime permission repair.

Related docs: [BACKUP-RESTORE.md](BACKUP-RESTORE.md) · [RESTORE-RUNTIME-PERMISSIONS.md](RESTORE-RUNTIME-PERMISSIONS.md) · [OPERATIONS.md](OPERATIONS.md) · [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

---

## Recovery Goals

Use the smallest backup tier that solves the incident:

| Tier | Best use | DR role |
| :-- | :-- | :-- |
| `db` | Quick database rollback | Restores Vaultwarden database contents only; storage-layout independent. |
| `full` | Normal fresh-VM disaster recovery | Primary scheduled DR artifact when you have the offline Age key or the key that encrypted the selected backup. |
| `emergency` | Fastest clone-style recovery | Clone-grade sealed capsule that can include staged `/etc/vaultwarden` key/config material. |

> **Warning:** Emergency backups are clone-grade secrets-bearing artifacts. Treat them like a password-manager vault export. Because they can contain the operational Age private key, they must be sealed with an independent passphrase prompt or a separate DR recipient (`EMERGENCY_BACKUP_AGE_RECIPIENT`).

Choose `db` for database rollback, `full` for normal DR with the offline Age key, and `emergency` when fastest recovery is worth carrying key material inside the sealed capsule.

---

## Prerequisites

Before beginning a full or emergency DR restore, have:

- a fresh or replacement Ubuntu 22.04/24.04 host;
- provider ingress prepared for SSH and HTTPS;
- Cloudflare DNS/proxy/WAF access;
- the rclone remote containing the backups, if using offsite restore;
- the Age key, recovery kit, emergency passphrase, or emergency recipient identity that decrypts the selected backup;
- the storage layout decision: boot storage (`/var/lib/vaultwarden`) or attached block/data volume such as `/mnt/vw-data`.

For block storage recovery, attach and mount the target data volume before running a destructive full/emergency restore. The restore preflight will not silently restore a block-volume backup into boot storage.

---

## Step 1 — Install Dependencies

```bash
sudo apt update
sudo apt install -y git docker.io docker-compose-plugin age sqlite3 zstd rclone
sudo systemctl enable --now docker
```

Log out and back in if Docker group membership is changed by setup later.

---

## Step 2 — Clone the Repository

Clone the repository and check out the branch or tag that matches the backup metadata when possible.

```bash
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
git checkout delta   # or the git_ref recorded in the backup .meta sidecar
chmod +x *.sh utilities/*.sh
```

Every full/emergency backup has a `.meta` sidecar. Check it when available:

```bash
cat full_backup_YYYYMMDD_HHMMSS.tar.zst.age.meta
# Look for: git_ref, git_sha, archive_format, storage_mode, project_state_dir
```

Using a very different repo revision can cause restore behavior to differ from the backup's expected format.

---

## Step 3 — Prepare Storage

### Boot-storage target

Boot-only recovery uses the default state directory:

```bash
PROJECT_STATE_DIR=/var/lib/vaultwarden
```

Run setup normally before restore so the host has baseline config and dependencies:

```bash
sudo ./setup.sh install --domain vault.example.com --email admin@example.com --auto
```

### Block-storage target

If the old host used block storage, attach and mount the replacement data volume first. Then run setup with the data-device options or restore only after the mounted state root is ready.

Use inspect mode before destructive restore:

```bash
sudo ./restore.sh inspect --remote
```

The target should be mounted and writable, and the report should show the expected required directories: `data`, `caddy`, `logs`, `config`, `secrets`, `backups`, plus the `.vw-data-volume` sentinel when in separate-volume mode.

---

## Step 4 — Select the Restore Tier

### DB rollback

Use this when the host and services are otherwise intact:

```bash
sudo ./restore.sh latest db
sudo ./maintenance.sh health
```

### Full DR restore

Use this for normal fresh-VM recovery:

```bash
sudo ./restore.sh inspect --remote
sudo ./restore.sh interactive --remote --key-file /path/to/offline-age-key.txt --start-policy ask
```

### Emergency clone-style restore

Use this when you need the sealed clone-grade capsule:

```bash
sudo ./restore.sh inspect --remote
sudo ./restore.sh interactive --remote --start-policy ask
```

If the emergency backup is passphrase-sealed, `age` will prompt for the emergency passphrase. If it uses an emergency recipient, provide the matching identity through the supported restore key/recovery-kit path.

---

## Step 5 — Inspect Before Starting Services

Interactive full/emergency restores default to `--start-policy ask`. Answer `n` when you want to inspect the recovered host before starting containers.

Checklist before start:

```bash
sudo utilities/repair-permissions.sh
sudo docker compose config --quiet
sudo ls -ld /etc/vaultwarden ${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/{data,caddy,logs,config,secrets}
sudo ./maintenance.sh health --json || true
```

The runtime permission repair is safe and idempotent. It normalizes root-operated config/secrets and Caddy's UID/GID `2000:2000` runtime paths. See [RESTORE-RUNTIME-PERMISSIONS.md](RESTORE-RUNTIME-PERMISSIONS.md).

Start manually after inspection:

```bash
sudo ./startup.sh --skip-pull
docker compose ps
sudo ./maintenance.sh health
```

---

## Step 6 — Install / Sync Systemd

After a successful restore, install or refresh systemd integration so `/opt` scripts, units, timers, env references, and Age key paths match the recovered host:

```bash
sudo ./setup.sh systemd install
sudo ./setup.sh systemd validate
sudo make timers
```

If you want units installed but not timers started immediately, use the setup-systemd start-policy/no-enable-now support documented in the command reference.

---

## Step 7 — Save the New Key / Recovery Kit

A successful restore may rotate or re-promote the operational Age key and re-key SOPS secrets for the recovered host. Export the recovery kit after restore:

```bash
sudo ./utilities/secrets-export-recovery-kit.sh
```

Store the result in your password manager and offline storage. Delete any plaintext copy left on the host after saving it.

---

## Step 8 — Verify the Recovery

```bash
sudo ./maintenance.sh health
sudo ./backup.sh verify
sudo ./backup.sh run db --rclone
sudo make key-health
sudo make timers
```

For public-path verification through local Caddy SNI:

```bash
DOMAIN="vault.example.com"

curl -vk --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/alive" \
  -o /dev/null -w "local HTTPS /alive: HTTP %{http_code}\n"

curl -vk --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/api/config" \
  -o /dev/null -w "local HTTPS /api/config: HTTP %{http_code}\n"
```

Expected result: both local HTTPS probes return HTTP `200`, and health reports Caddy storage/log permissions as correct.

---

## Common Pitfalls

| Pitfall | Fix |
| :-- | :-- |
| Restoring a block-storage backup into boot storage | Attach/mount the data volume first or restore a `db` backup instead. |
| Wrong Age key | Use the key that encrypted the selected backup, not necessarily the key currently installed on the replacement host. |
| Emergency passphrase unavailable | Use a different backup or the emergency recipient identity if configured. |
| Caddy returns Cloudflare 525 after restore | Run `sudo utilities/repair-permissions.sh`, restart Caddy, and re-run health. |
| Services start before inspection | Use `--start-policy ask`, answer `n`, or use `--no-start`. |
| Systemd timers fail after restore | Re-run `sudo ./setup.sh systemd install` and `sudo ./setup.sh systemd validate`. |

---

## Non-Production Recovery Rehearsal

Rehearse recovery only on a disposable VM or copied state volume. Never mount or modify the live production state volume for a drill.

Suggested drill:

```bash
sudo ./restore.sh inspect --remote
sudo ./restore.sh interactive --remote --start-policy manual
sudo utilities/repair-permissions.sh
sudo ./startup.sh --skip-pull
sudo ./maintenance.sh health
```

Confirm and record that:

- Docker Compose configuration validates;
- `/run/vaultwarden-oci/secrets` is `root:root 0700` and runtime secret files are `0444`;
- Caddy storage/log paths are `2000:2000` and writable by the Caddy container;
- the persistent SOPS ciphertext decrypts without exposing plaintext in logs;
- Vaultwarden `/alive` and `/api/config` respond over local SNI HTTPS;
- the copied state volume, not production state, was used.

Destroy the disposable VM, copied state volume, and copied key material after the drill.
