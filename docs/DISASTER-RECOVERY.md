# Disaster Recovery — VaultWarden-OCI

Replacement-host runbook for the current root-operated backup, restore, state-volume recovery, storage, and installed-systemd-runtime contracts.

Related docs: [BACKUP-RESTORE.md](BACKUP-RESTORE.md) · [RECOVERY-CARD.md](RECOVERY-CARD.md) · [BOOTSTRAP_KEY_RECOVERY.md](BOOTSTRAP_KEY_RECOVERY.md) · [RESTORE-RUNTIME-PERMISSIONS.md](RESTORE-RUNTIME-PERMISSIONS.md)

## Recovery choices

Choose the path that matches the surviving recovery material:

| Surviving material | Recovery path |
| :-- | :-- |
| `db` backup | database-only restore into a prepared VaultWarden-OCI host |
| `full` backup + matching Age private identity | normal replacement-host disaster recovery |
| independently sealed `emergency` backup | fastest clone-style restore, including staged `/etc/vaultwarden` material when archived |
| existing VaultWarden-OCI state volume + DR manifest + offline Age private key | `recover.sh` state-volume recovery |

Do not treat these paths as interchangeable. A database backup is storage-layout independent; a full/emergency restore recovers broader project state; `recover.sh` is specifically the state-volume recovery transaction.

---

## Before an incident

Production readiness requires recovery material that survives loss of the host:

- verified offsite backups;
- a current recovery kit stored off-host;
- an offline recovery Age private key when the optional offline recipient is used;
- retained older Age identities required by retained backup generations;
- Cloudflare account access;
- provider-console/network-firewall access;
- external SMTP/rclone credentials;
- access to the repository commit/reference recorded by recovery metadata.

Create a current recovery kit:

```bash
sudo ./utilities/secrets-export-recovery-kit.sh
```

Verify backups:

```bash
sudo ./backup.sh verify
```

Run the current production-readiness tools:

```bash
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
sudo ./utilities/pre-production-drill.sh
```

A backup file existing remotely is not proof that the required key, sidecars, and recovery workflow are usable.

---

## Path A — Restore from `full` or `emergency` backup

### 1. Create a supported replacement host

Use Ubuntu 24.04 LTS Noble on amd64 or arm64.

Configure the provider firewall/security group/network firewall for:

- SSH from trusted administrator ranges;
- TCP `443` for the intended Cloudflare-origin path;
- TCP `80` only when the selected documented TLS/redirect path requires it.

Do not point production Cloudflare traffic at the replacement host until its local origin checks are ready.

### 2. Clone the repository

```bash
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh utilities/*.sh
```

When backup metadata records an exact Git SHA needed by the recovery procedure, check out that exact commit before restore:

```bash
git checkout <recorded-git-sha>
```

Do not assume `delta`, `main`, or another moving branch is equivalent to the code that created the retained recovery material.

### 3. Prepare host dependencies

Run the repository-owned host preparation:

```bash
sudo ./utilities/setup-system.sh --auto
```

This validates the Noble/amd64-or-arm64 contract and installs the required Docker/Compose, SOPS, Age, SQLite, rclone, zstd, and supporting command set.

Do not preinstall Ubuntu `docker.io` as a substitute for the repository's Docker Engine/Compose setup contract.

### 4. Prepare storage

For boot-volume recovery, the default state path is:

```text
/var/lib/vaultwarden
```

For an attached data volume, mount/adopt the intended existing filesystem before restoring broader state. Use a stable device path where available:

```bash
sudo DATA_VOLUME_EXISTING_FS_OK=true \
  ./utilities/setup-storage.sh setup \
    --data-device /dev/disk/by-id/<your-restored-volume> \
    --data-mount /mnt/vw-data
```

Do not use blank-device formatting authorization against a volume that contains recovered production state.

Verify the intended layout:

```bash
sudo utilities/setup-storage.sh verify
findmnt
lsblk -f
```

### 5. Configure rclone access when restoring remotely

Create or restore the rclone source configuration through normal rclone tooling:

```bash
rclone config
```

For root-operated automation, the installed runtime config is:

```text
/etc/vaultwarden/rclone.conf
```

The restore CLI can prompt for the remote name/path for session-scoped remote discovery on a fresh host. Use `restore.sh --help` for the exact current grammar.

### 6. Inspect before destructive restore

```bash
sudo ./restore.sh inspect --remote
```

Confirm:

- selected backup tier;
- source storage layout;
- target storage mode/mount;
- required key/protection material;
- database/archive metadata.

If the selected full/emergency archive expects attached-volume state and the replacement host is still configured for boot storage, stop and prepare the correct storage layout.

### 7. Restore with an operator start gate

Full example:

```bash
sudo ./restore.sh interactive --remote \
  --key-file /secure/path/offline-age-key.txt \
  --start-policy ask
```

Emergency restore follows the same selection flow but requires the independent emergency protection used by the archive: passphrase or separate emergency Age recipient.

Restore may rotate/install a new operational Age key. When the workflow requires a `SAVED` acknowledgement for printed recovery material, timeout or lost SSH input fails safe instead of pretending the key was recorded.

### 8. Inspect the restored host before enabling timers

```bash
sudo utilities/repair-permissions.sh --check
sudo ./maintenance.sh health
sudo ./maintenance.sh test-email --verbose
```

Inspect:

```bash
docker compose ps
docker compose logs --tail=100
utilities/env-edit.sh status
sudo utilities/setup-storage.sh verify
```

Check Cloudflare/DNS, provider ingress, rclone, and the mounted state path.

### 9. Local origin checks

Before changing production DNS/proxy routing:

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
```

Expected healthy origin endpoints return HTTP `200`.

### 10. Activate and validate systemd automation

Only after the recovered host is ready for scheduled backup, maintenance, health, DNS, and firewall work:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

On a host still under manual inspection, install without immediate timer start:

```bash
sudo ./setup.sh systemd install --no-enable-now
```

A successful install-only run is not the production-ready gate.

### 11. Cut over Cloudflare/provider routing

After local health, systemd validation, and smoke checks pass:

1. confirm origin firewall rules;
2. point the Cloudflare DNS record/origin path at the replacement host;
3. use Cloudflare **Proxied** mode and **Full (Strict)** after origin validation;
4. run `sudo make health` again from the host;
5. verify external `/alive`, browser login, and operational email delivery.

### 12. Create new recovery points

After cutover:

```bash
sudo ./backup.sh run db --rclone
sudo ./backup.sh run full --full-verification --rclone
sudo ./backup.sh verify
sudo ./utilities/secrets-export-recovery-kit.sh
```

Store the new recovery material off-host before considering DR complete.

---

## Path B — Database-only restore

Use this when only Vaultwarden database contents need recovery and the new host's configuration/storage model should remain intact.

Prepare the supported target through normal setup, then:

```bash
sudo ./restore.sh inspect --remote
sudo ./restore.sh latest db
sudo ./maintenance.sh health
```

Database backups are storage-layout independent.

After acceptance:

```bash
sudo ./backup.sh run full --full-verification
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

---

## Path C — State-volume recovery with `recover.sh`

Use this when the persistent VaultWarden-OCI state volume and DR manifest survive but the original host/runtime identity is gone.

### Required material

- mounted state volume;
- recovery manifest under the state directory;
- offline Age private key matching the recovery recipient;
- exact Git commit recorded in the manifest;
- supported Ubuntu 24.04 Noble amd64/arm64 replacement host.

### Prepare the host

```bash
sudo git clone <REPO_URL> /opt/VaultWarden-OCI
sudo git -C /opt/VaultWarden-OCI checkout <REPO_COMMIT>
cd /opt/VaultWarden-OCI
sudo ./utilities/setup-system.sh --auto
```

Mount/adopt the existing state volume without formatting it.

### Run recovery

```bash
sudo ./recover.sh \
  --state-dir /mnt/vw-data \
  --key /secure/path/offline-age-key.txt
```

`recover.sh` validates the manifest/repository commit, uses the offline private key in place, generates a new operational Age key, and stages/promotes the new ciphertext, SOPS policy, persistent environment, and DR manifest under one local recovery transaction.

Before the commit boundary, failure restores the previous recovery identity/config state. After commit, startup or `/alive` failure returns non-zero and preserves the newly committed artifacts for diagnosis.

Do not replace the generated operational key with the offline recovery private key.

### Activate automation after recovery

When storage, secrets, rclone, Cloudflare/DNS, firewall, and live service readiness are verified:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
sudo ./utilities/secrets-export-recovery-kit.sh
```

See [RECOVERY-CARD.md](RECOVERY-CARD.md).

---

## Caddy/TLS recovery problems

After full/emergency restore, Caddy permission drift may produce Cloudflare `525`, local TLS failures, or storage-lock errors.

Check:

```bash
sudo utilities/repair-permissions.sh --check
sudo docker logs vaultwarden_caddy --tail=120 2>&1 \
  | grep -Ei 'permission|certificate|tls|handshake|error|warn|storage|autosave' || true
```

Repair:

```bash
sudo utilities/repair-permissions.sh
sudo docker compose restart caddy
sudo ./maintenance.sh health
```

The runtime repair contract normalizes Caddy data/config/log mounts to UID/GID `2000:2000` and preserves root-operated config/secrets state.

Do not use `chmod -R 777` or `chown -R 2000:2000 ${PROJECT_STATE_DIR}`.

---

## Backup/key mismatch

A retained backup may have been encrypted to an older operational recipient or an offline recovery recipient.

If decryption fails:

1. inspect the selected backup metadata;
2. identify the recipient generation used by that backup;
3. use the matching retained private identity;
4. do not generate a new key and assume it can decrypt historical ciphertext.

Check current key health:

```bash
sudo make key-health
```

Verify a backup with the intended retained identity before discarding old Age key material.

See [BOOTSTRAP_KEY_RECOVERY.md](BOOTSTRAP_KEY_RECOVERY.md).

---

## DR completion checklist

Do not declare recovery complete until:

- [ ] correct supported repository commit/version is active;
- [ ] storage layout and mount identity pass verification;
- [ ] runtime permissions pass the known-path check;
- [ ] Vaultwarden and Caddy are healthy;
- [ ] local `/alive` returns HTTP `200`;
- [ ] external Cloudflare route works in Full (Strict);
- [ ] user login works;
- [ ] organizations/attachments/Sends behave as expected;
- [ ] operational email test succeeds;
- [ ] rclone access is verified when offsite backups are required;
- [ ] new DB backup succeeds;
- [ ] new full backup passes full verification;
- [ ] `setup.sh systemd validate` succeeds;
- [ ] smoke test succeeds with no skipped checks;
- [ ] fresh recovery material is stored off-host.

A browser login alone is not a production-readiness verdict.

---

## DR rehearsal

Rehearse on a disposable replacement host or copied state volume. Never use the only live production state volume for a destructive recovery drill.

At minimum rehearse:

- retrieval of backup and sidecars;
- retrieval/use of the required private Age identity or emergency protection;
- exact repository commit checkout when recovery metadata requires it;
- storage preparation;
- restore/recover execution;
- Caddy permission/origin validation;
- systemd runtime activation and validation;
- smoke test;
- creation/verification of a new recovery point.

Record the date and any operator confusion, then update the recovery documentation rather than relying on memory.
