# Secure credential and recovery handoffs

This guide explains how VaultWarden-OCI hands generated credentials and recovery material to the operator without printing sensitive values into normal terminal output.

Related docs: [DEPLOYMENT.md](DEPLOYMENT.md) · [BOOTSTRAP_KEY_RECOVERY.md](BOOTSTRAP_KEY_RECOVERY.md) · [BACKUP-RESTORE.md](BACKUP-RESTORE.md) · [EMAIL.md](EMAIL.md)

## Setup credentials

Both supported automatic entry points use the same protected handoff contract:

```bash
sudo ./setup.sh install --domain DOMAIN --email EMAIL --auto
sudo ./utilities/setup-secrets.sh configure --auto
```

They do not print generated credential values to the terminal or command trace. A successful run writes one UTF-8, root-owned file under:

```text
/root/vaultwarden-recovery/vaultwarden-setup-credentials-<UTC_TIMESTAMP>.txt
```

The directory is `root:root` mode `0700`; the file is `root:root` mode `0600`. Publication uses a randomized same-directory temporary file and an atomic no-overwrite handoff. The handoff contains exactly three credential groups: the SOPS Age identity, the Vaultwarden administrator plaintext, and the Caddy administrator plaintext. The setup file is never emailed.

After successful publication, the command displays the protected path, the credential group names, the ownership and permission contract, and a statement that no credential values were printed. Automatic configuration fails if the handoff cannot be published; it does not print a completion summary after publication failure.

`file_integrity_hmac_key` is backup-integrity material, not a backup passphrase, and is managed through the secret schema and recovery-kit workflow rather than the setup-credential handoff.

After storing the handoff offline, remove it explicitly:

```bash
sudo rm -f /root/vaultwarden-recovery/vaultwarden-setup-credentials-<UTC_TIMESTAMP>.txt
```

Required UFW failure, automatic secrets failure, or protected-handoff failure makes setup fail rather than print a successful completion.

Age-key rotation and restore completion output identify only the protected handoff/public status; the private identity is never repeated in terminal output.

## Full recovery kit

The full recovery kit is a later, separate operation:

```bash
sudo ./utilities/secrets-export-recovery-kit.sh
```

The equivalent dispatcher form is:

```bash
sudo ./edit-secrets.sh export-recovery-kit
```

It is written under `/root/vaultwarden-recovery/`, never in the repository root, and its body is not printed to terminal output. Recovery export participates in the shared operation guard so it cannot overlap a backup.

The directory remains `root:root` mode `0700`, and each plaintext kit remains `root:root` mode `0600`. Immediately after publication, export must obtain an accepted 30-minute systemd transient cleanup timer before it offers email delivery. `at` is an optional fallback only. If neither scheduler accepts cleanup, export removes the new plaintext kit and fails; it does not leave the file behind for manual cleanup.

Declining email leaves the protected plaintext kit only until the accepted timer expires. Requested email failure is returned to the operator while the same timer remains active. Successful encrypted email delivery removes the local plaintext copy immediately and leaves the transient timer in place as an idempotent safety net.

Email delivery sends only `important-documents-<YYYYMMDD>.zip`. The ZIP container uses AES-256 through the Ubuntu `7zip` package and contains exactly one recovery-kit text file. The attachment passphrase is independent, is at least 16 characters, and is not placed in argv, environment variables, a file, the message body, or the subject.

Plaintext and temporary ZIP cleanup uses best-effort overwrite and unlink. Physical erasure is not guaranteed on SSDs, snapshots, journaling filesystems, or copy-on-write storage.

Extraction requires an AES-ZIP-capable tool:

- Windows: 7-Zip or equivalent.
- macOS: an AES-ZIP-capable application; Archive Utility may not support the archive.
- Linux: `7z x important-documents-<YYYYMMDD>.zip`.

Install the supported package on Ubuntu 24.04:

```bash
sudo apt-get update
sudo apt-get install -y 7zip
```

## Full backup and runtime contracts

Normal `full` backups explicitly exclude setup/recovery documents, staging names, and emailed ZIPs, then reject any such member discovered in the final archive listing. Emergency backup key-bearing behavior remains separate and is documented in [BACKUP-RESTORE.md](BACKUP-RESTORE.md).

Startup enforces log directories as `0750`, regular log files as `0640`, and canonical numeric `PUID:PGID` ownership. Permission failures are fatal; dry-run does not mutate files.

Normal production email uses `EMAIL_MODE=smtp`: operational mail submits to the Postfix sidecar first and uses direct authenticated SMTP as the fallback path. `EMAIL_MODE=direct` remains an explicit direct-SMTP option. The runtime stack requires the SOPS-managed `smtp_password` secret; see [EMAIL.md](EMAIL.md).

## Backup protection terminology

Normal `db` and `full` backups are Age-encrypted under the project backup-recipient model. `file_integrity_hmac_key` authenticates checksum sidecars and is not a password or backup passphrase. There is no `backup_passphrase` secret in the active schema.

Emergency backups are different: because they may contain operational key/config material, they are independently sealed with an emergency passphrase or `EMERGENCY_BACKUP_AGE_RECIPIENT`.

The emailed recovery-kit ZIP uses a separate, ephemeral attachment passphrase that is never stored in project secrets.
