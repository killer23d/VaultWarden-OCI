# Migration Guide — VaultWarden-OCI

This guide covers moving an existing Vaultwarden deployment or exported password-manager data into the current VaultWarden-OCI appliance.

The target production host must be Ubuntu 24.04 LTS Noble on amd64 or arm64. The runtime is cloud-provider neutral; there is no supported Oracle Linux, OCI-only, or other distribution-specific target path.

Related docs: [DEPLOYMENT.md](DEPLOYMENT.md) · [BACKUP-RESTORE.md](BACKUP-RESTORE.md) · [VOLUME-MIGRATION.md](VOLUME-MIGRATION.md) · [RESTORE-RUNTIME-PERMISSIONS.md](RESTORE-RUNTIME-PERMISSIONS.md)

## Choose the migration method

| Source | Preferred method |
| :-- | :-- |
| Existing Vaultwarden SQLite deployment | Offline database/data migration when exact data continuity is required |
| Bitwarden cloud | Vault export/import |
| Other password manager | Supported Vaultwarden/Bitwarden import format |
| Existing VaultWarden-OCI host | Project backup/restore or state-volume recovery, not manual migration |
| Current VaultWarden-OCI state moving between disks | `utilities/setup-storage.sh migrate`; see [VOLUME-MIGRATION.md](VOLUME-MIGRATION.md) |

Do not use this guide to move a current VaultWarden-OCI installation between its own storage locations. The storage migration utility owns that contract.

---

## Pre-migration checklist

Before changing either system:

- create and verify a backup of the source;
- record the source Vaultwarden version;
- document organization ownership, attachments, Sends, and special integrations;
- prepare the supported Noble target host;
- keep the old system intact until the target is fully verified;
- schedule a maintenance window;
- notify users before the final write freeze.

For direct SQLite migration, stop the source Vaultwarden service before taking the final database copy or use a verified SQLite backup snapshot. Do not copy a live `db.sqlite3` while writes continue and assume the copy is transactionally complete.

---

## Prepare the VaultWarden-OCI target

Clone and install the current project:

```bash
git clone --branch delta https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh utilities/*.sh

sudo ./setup.sh install \
  --domain vault.example.com \
  --email admin@example.com \
  --auto
```

Configure non-secret values and external credentials:

```bash
sudo make edit-env
sudo ./edit-secrets.sh rotate caddy_cloudflare_dns_token
sudo ./edit-secrets.sh rotate cloudflare_zone_id
sudo ./edit-secrets.sh rotate cf_account_id
sudo ./edit-secrets.sh rotate cf_worker_bouncer_token
sudo ./edit-secrets.sh rotate smtp_password
```

Do not enable scheduled automation until the migrated data is installed and the live stack is verified.

For a target under migration/manual inspection, systemd runtime may be installed without starting timers:

```bash
sudo ./setup.sh systemd install --no-enable-now
```

---

## Method 1 — Existing Vaultwarden SQLite deployment

Use this method when preserving the existing Vaultwarden database and attachment tree is required.

### 1. Freeze the source

On the source deployment, stop Vaultwarden before the final transfer:

```bash
docker stop vaultwarden
```

Use the source deployment's real container/service name if different.

Verify the SQLite database before transfer:

```bash
sqlite3 /path/to/source/data/db.sqlite3 'PRAGMA integrity_check;'
```

Expected result:

```text
ok
```

Copy the final database and attachment tree to a secure staging location on the target:

```bash
scp /path/to/source/data/db.sqlite3 user@new-server:/tmp/db.sqlite3.source
scp -r /path/to/source/data/attachments user@new-server:/tmp/attachments.source
```

Transfer other Vaultwarden data subtrees only when you understand their purpose and need to preserve them. Do not copy source Docker runtime secrets, PID/socket files, or an unrelated reverse-proxy configuration into the new state directory.

### 2. Stop the target stack

On the VaultWarden-OCI target:

```bash
cd /path/to/VaultWarden-OCI
sudo make down
```

Determine the active project state path:

```bash
utilities/env-edit.sh status
```

The default boot-volume path is `/var/lib/vaultwarden`; a dedicated-volume deployment may use `/mnt/vw-data` or another configured mount.

For the examples below:

```bash
STATE_DIR=/var/lib/vaultwarden
```

Replace that value with the actual `PROJECT_STATE_DIR`.

### 3. Install the database

Preserve the target-generated database as a temporary migration fallback:

```bash
sudo cp -a \
  "$STATE_DIR/data/db.sqlite3" \
  "$STATE_DIR/data/db.sqlite3.pre-migration" 2>/dev/null || true
```

Install the source database:

```bash
sudo install -m 0640 /tmp/db.sqlite3.source \
  "$STATE_DIR/data/db.sqlite3"
```

Do not copy source WAL/SHM files into the target:

```bash
sudo rm -f \
  "$STATE_DIR/data/db.sqlite3-wal" \
  "$STATE_DIR/data/db.sqlite3-shm"
```

### 4. Install attachments

When the source has attachments:

```bash
sudo rm -rf "$STATE_DIR/data/attachments"
sudo cp -a /tmp/attachments.source "$STATE_DIR/data/attachments"
```

### 5. Apply the target-host permission contract

Use the repository helper rather than hard-coded `chown 1000:1000` or broad `chmod -R` commands:

```bash
sudo utilities/repair-permissions.sh
sudo utilities/repair-permissions.sh --check
```

The helper derives the current `PUID:PGID`, applies the Caddy UID/GID `2000:2000` contract where required, and preserves root-operated private configuration/secrets paths.

### 6. Verify the migrated database

```bash
sudo sqlite3 \
  "$STATE_DIR/data/db.sqlite3" \
  'PRAGMA integrity_check;'
```

Expected result:

```text
ok
```

### 7. Start the target and verify

```bash
sudo make up
sudo make health
```

Test:

- user login;
- organization access/permissions;
- attachments;
- Sends when used;
- two-factor authentication;
- `/admin` access through the configured protection path;
- SMTP delivery.

Test the operational email path:

```bash
sudo ./maintenance.sh test-email --verbose
```

### 8. Activate automation after migration acceptance

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

Create and verify fresh VaultWarden-OCI backups:

```bash
sudo ./backup.sh run db
sudo ./backup.sh run full --full-verification
sudo ./backup.sh verify
```

Export fresh recovery material:

```bash
sudo ./utilities/secrets-export-recovery-kit.sh
```

Only after these checks should the target replace the old source as the production system.

---

## Method 2 — Vault export/import

Export/import is the safer cross-version or cross-product path when direct SQLite continuity is not required.

### Export from Bitwarden/Vaultwarden

Use the source web vault or supported Bitwarden CLI export flow. Prefer an encrypted export format when the source and import workflow support it.

Unencrypted JSON/CSV exports contain vault secrets in plaintext. Keep them on a trusted device, do not email them, and delete them securely after successful migration.

### Prepare and start the target

```bash
sudo make up
sudo make health
```

### Import

Use the target web vault's import function and select the format matching the exported source.

Export/import may not preserve every historical or server-side object exactly. Verify:

- item count/content;
- organizations/collections;
- attachments;
- Sends;
- trash/history behavior important to your deployment.

Recreate organization membership/invitations as required by the source export format.

### Complete target validation

```bash
sudo ./maintenance.sh test-email --verbose
sudo ./backup.sh run full --full-verification
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
sudo ./utilities/secrets-export-recovery-kit.sh
```

---

## Migrating from another password manager

Use the current Vaultwarden/Bitwarden web-vault import format that matches the source product.

General workflow:

1. export from the source on a trusted device;
2. create the target VaultWarden-OCI host through the supported deployment path;
3. start and health-check the target;
4. import through the web vault;
5. verify logins, organizations, attachments, 2FA, and Sends;
6. configure email and Cloudflare/CrowdSec;
7. create/verify a full backup;
8. activate/validate systemd automation;
9. export recovery material;
10. securely remove plaintext source exports.

Do not keep unencrypted CSV/JSON exports as the long-term backup strategy for this appliance.

---

## Provider-neutral target guidance

VaultWarden-OCI does not auto-detect or support Oracle Linux, Amazon Linux, Debian, or another distribution as the normal production target.

The supported host check requires:

```text
ID=ubuntu
VERSION_ID=24.04
VERSION_CODENAME or UBUNTU_CODENAME=noble
architecture=amd64 or arm64
```

Cloud-provider differences belong at the infrastructure boundary:

- attach/create the VM or physical host;
- configure upstream firewall/security-group rules;
- attach an optional data volume;
- provide DNS/public IP routing.

Once Ubuntu 24.04 Noble is running, the repository scripts own the normal host/runtime configuration.

Provider-specific examples may be useful, but they do not expand the supported OS contract.

---

## Migrating VaultWarden-OCI storage

To move an existing current project state from boot storage to a dedicated volume, between data volumes, or back to boot storage, use:

```bash
sudo utilities/setup-storage.sh migrate run
```

The migration pipeline owns:

- operation guards;
- explicit device selection;
- blank-device formatting authorization;
- stack stop/recheck;
- WAL/SHM exclusion;
- rsync transfer;
- byte-count and checksum verification;
- environment/state updates;
- systemd/runtime regeneration required by the migration path;
- start policy;
- resume/abort state.

See [VOLUME-MIGRATION.md](VOLUME-MIGRATION.md). Do not replace this with a manual `cp -r`/`.env` edit procedure for a current VaultWarden-OCI deployment.

---

## Post-migration acceptance checklist

Before retiring the source:

- [ ] Target is Ubuntu 24.04 Noble on amd64 or arm64.
- [ ] `sudo make health` passes.
- [ ] Users can log in with expected credentials.
- [ ] Organizations/collections are correct.
- [ ] 2FA works.
- [ ] Attachments download correctly.
- [ ] Sends work when used.
- [ ] Operational email test succeeds.
- [ ] Cloudflare origin/proxy path is healthy.
- [ ] CrowdSec and both bouncers are in the intended state.
- [ ] A new DB backup succeeds.
- [ ] A new full backup succeeds with full verification.
- [ ] Offsite backup sync works when enabled.
- [ ] `sudo ./setup.sh systemd validate` passes.
- [ ] `sudo ./utilities/smoke-test.sh` passes without skipped checks.
- [ ] Fresh recovery material is stored off-host.
- [ ] The old source and plaintext export/staging files remain protected until final acceptance, then are retired deliberately.

---

## Rollback

Keep the old source stopped but intact until the target is accepted.

If target acceptance fails:

1. stop the target with `sudo make down`;
2. return DNS/proxy routing to the old source as appropriate;
3. restart the old source only after confirming no writes were accepted by the target that must be reconciled;
4. investigate the target using `sudo make health`, `sudo make diagnose`, and the relevant logs;
5. repeat migration from a known source snapshot or use export/import.

Do not run both old and new servers as independent writable production systems and later assume their SQLite databases can be merged.

---

## Troubleshooting

### Database integrity fails

Do not start Vaultwarden with a known-corrupt migrated database.

Return to the source/final source snapshot, run the source's SQLite integrity checks, and repeat the transfer. VaultWarden-OCI database maintenance is not a substitute for a valid migration source.

### Attachments are inaccessible

Check the target path and permission contract:

```bash
sudo utilities/repair-permissions.sh --check
sudo utilities/repair-permissions.sh
sudo make restart
sudo make health
```

Do not use `chmod -R 777` or a hard-coded numeric ownership fix across the whole state directory.

### Target starts but automation fails validation

Repository code and installed systemd runtime may be out of sync:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

### Storage path is wrong

```bash
utilities/env-edit.sh status
sudo utilities/setup-storage.sh verify
findmnt
lsblk -f
```

Do not edit the installed systemd environment to hide a mount/state mismatch. Correct the storage/environment source and resynchronize through the supported tools.
