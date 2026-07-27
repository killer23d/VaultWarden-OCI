# Secure credential and recovery handoffs

<!-- VWOCI-PRR-PATCH-04 -->

This document defines the bounded production-readiness remediation for credential output, recovery exports, backups, runtime log permissions, and email mode validation.

## Setup credentials

Both supported automatic entry points use the same protected handoff contract:

```bash
sudo ./setup.sh --domain DOMAIN --email EMAIL --auto
sudo ./utilities/setup-secrets.sh configure --auto
```

They do not print generated credential values to the terminal or command trace. A successful run writes one UTF-8, root-owned file under:

```text
/root/vaultwarden-recovery/vaultwarden-setup-credentials-<UTC_TIMESTAMP>.txt
```

The directory is `root:root` mode `0700`; the file is `root:root` mode `0600`. Publication uses a randomized same-directory temporary file and an atomic no-overwrite handoff. The handoff contains exactly three credential groups: the SOPS Age identity, the Vaultwarden administrator plaintext, and the Caddy administrator plaintext. The setup file is never emailed.

After successful publication, the command displays the protected path, the credential group names, the ownership and permission contract, and a statement that no credential values were printed. Automatic configuration fails if the handoff cannot be published; it does not print a completion summary after publication failure.

The remediation intentionally does **not** label `file_integrity_hmac_key` as a backup passphrase. The audited branch has no canonical backup-passphrase generator/consumer contract. Adding a fourth credential requires a separate design that defines where it is generated, stored, consumed by backup/restore, rotated, and tested.

After storing the handoff offline, remove it explicitly:

```bash
sudo rm -f /root/vaultwarden-recovery/vaultwarden-setup-credentials-<UTC_TIMESTAMP>.txt
```

Required UFW failure, automatic secrets failure, or protected-handoff failure now makes setup fail rather than print a successful completion.

Age-key rotation and restore completion output now identify only the protected handoff/public status; the private identity is never repeated in terminal output.

## Full recovery kit

The full recovery kit remains a later, separate operation:

```bash
sudo ./edit-secrets.sh export-recovery-kit
```

It is written under `/root/vaultwarden-recovery/`, never in the repository root, and its body is not printed to terminal output. Recovery export participates in the shared operation guard so it cannot overlap a backup.

Email delivery sends only `important-documents-<YYYYMMDD>.zip`. The ZIP container uses AES-256 through the Ubuntu `7zip` package and contains exactly one recovery-kit text file. The attachment passphrase is independent, is at least 16 characters, and is not placed in argv, environment variables, a file, the message body, or the subject.

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

Normal `full` backups explicitly exclude current and legacy setup/recovery documents, staging names, and emailed ZIPs, then reject any such member discovered in the final archive listing. Emergency backup key-bearing behavior remains separate.

Startup enforces log directories as `0750`, regular log files as `0640`, and canonical numeric `PUID:PGID` ownership. Permission failures are fatal; dry-run does not mutate files.

`EMAIL_MODE=direct` is canonical. `host` remains a deprecated compatibility alias. `smtp`, `direct`, and `host` all require the runtime `smtp_password` secret.

## Backup protection terminology

Normal `db`, `full`, and `emergency` backups remain encrypted by the operational Age identity. `file_integrity_hmac_key` authenticates checksum sidecars and is not a password or backup passphrase. The active schema has no `backup_passphrase` secret or backup/restore consumer. The emailed recovery-kit ZIP uses a separate, ephemeral attachment passphrase that is never stored in project secrets.
