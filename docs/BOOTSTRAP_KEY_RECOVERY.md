# Offline Age Key and Recovery Material — VaultWarden-OCI

This guide explains the current Age key custody and recovery model.

It replaces older USB/GPG-centric procedures as the primary project workflow. You may still wrap or store recovery material with independent tools, but the supported project recovery paths are built around the operational Age key, optional offline recovery recipient, recovery-kit export, backup restore, and `recover.sh` state-volume recovery.

Related docs: [BACKUP-RESTORE.md](BACKUP-RESTORE.md) · [DISASTER-RECOVERY.md](DISASTER-RECOVERY.md) · [SECURITY.md](SECURITY.md) · [ARCHITECTURE.md](ARCHITECTURE.md)

## Key concepts

Do not confuse these values:

| Item | Purpose | Normal location |
| :-- | :-- | :-- |
| Operational Age private key | Live server SOPS/backup decryption identity | `/etc/vaultwarden/age-key.txt` |
| Operational Age public recipient | Recipient derived from the operational key | SOPS policy/backup encryption metadata |
| Offline recovery Age private key | Separate private identity kept off the server | operator-controlled offline location |
| Offline recovery Age public recipient | Optional additional SOPS/recovery recipient | SOPS policy and DR metadata |
| Emergency backup passphrase | Independent protection for passphrase-sealed emergency archives | operator memory/password manager |
| `EMERGENCY_BACKUP_AGE_RECIPIENT` | Separate Age recipient for emergency archive protection | configuration when using recipient mode |
| Recovery kit | Plaintext operator handoff containing Age key and credentials | temporary export; must be moved off-host and secured |

The offline recovery private key must not become the server's live operational key.

## Operational key path

The installed production key is:

```text
/etc/vaultwarden/age-key.txt
```

Expected production ownership is root-only.

Check the active key and recipient:

```bash
sudo make key-show
```

Run the functional health check:

```bash
sudo make key-health
```

Key health validates the operational key, SOPS recipient alignment, and decrypt/encrypt behavior required by the current project.

## Recovery kit — normal operator handoff

After initial setup, restore, or Age key rotation, export a fresh recovery kit:

```bash
sudo ./utilities/secrets-export-recovery-kit.sh
```

The export contains the operational Age private key and the credentials required for recovery. It is intentionally sensitive plaintext while exported.

Store it:

- in a trusted password manager or equivalent secret store;
- in a separate offline recovery location;
- away from the only copy of the encrypted backups.

Then remove plaintext copies from the server after confirming the off-host copies are readable.

The recovery kit is not a normal backup archive and should never be committed to Git.

## Optional offline recovery Age recipient

The project may include a second Age public recipient in SOPS/recovery policy. The matching private key stays offline.

This provides a recovery identity that is independent from the live server's operational Age key.

The normal model is:

```text
operational Age public recipient
            +
offline recovery Age public recipient (optional)
            |
            v
       SOPS recipient policy
```

The private offline key is brought to a replacement host only for recovery and is used in place. `recover.sh` generates a new operational Age key for the recovered server.

Do not copy the offline private key into `/etc/vaultwarden/age-key.txt` as the normal `recover.sh` workflow.

## Operational Age key rotation

Rotate the live operational key with:

```bash
sudo make key-rotate
```

The key-rotation workflow updates the operational key/SOPS recipient contract and verifies decryptability before success.

After rotation:

1. run `sudo make key-health`;
2. export a new recovery kit;
3. secure the new recovery material off-host;
4. retain old recovery identities/material needed to decrypt older backup generations until those backups expire or are deliberately retired.

A new Age key does not retroactively re-encrypt every historical backup.

## Recovery path A — restore a backup archive

Use `restore.sh` for `db`, `full`, or `emergency` backup restore.

Inspect the available archive/storage contract first:

```bash
sudo ./restore.sh inspect --remote
```

For guided remote restore:

```bash
sudo ./restore.sh interactive --remote --start-policy ask
```

When the selected `full` archive is not decryptable by the server's current operational key, supply a private key for one of the recipients that encrypted that archive using the current restore key-file/recovery-kit options.

Use:

```bash
./restore.sh --help
```

or [COMMAND-REFERENCE.md](COMMAND-REFERENCE.md) for the exact current grammar.

Emergency backups use independent protection. A passphrase-sealed emergency archive requires the emergency passphrase; recipient-sealed emergency mode requires the matching emergency private identity. The operational key carried inside an emergency capsule is not used as the only protection for that same capsule.

## Recovery path B — recover an existing state volume

Use `recover.sh` when you have the persistent state volume and its recovery manifest.

The replacement host must:

- run Ubuntu 24.04 LTS Noble on amd64 or arm64;
- use the exact repository commit recorded in the recovery manifest;
- have the state volume mounted at the intended state path;
- have the offline Age private key matching the recovery recipient.

Run:

```bash
sudo ./recover.sh \
  --state-dir /mnt/vw-data \
  --key /secure/path/offline-age-key.txt
```

`recover.sh`:

1. validates the exact repository commit and recovery manifest;
2. uses the offline key in place to decrypt the staged SOPS state;
3. generates a replacement operational Age key;
4. stages the new ciphertext, SOPS policy, persistent environment, and DR manifest;
5. validates the staged recovery identity/config together;
6. promotes the staged artifacts under one pre-commit rollback scope;
7. preserves the committed new recovery artifacts when a later startup or `/alive` check fails.

The offline private key is not persisted as the live operational key.

See [RECOVERY-CARD.md](RECOVERY-CARD.md).

## Recovery/manual-inspection systemd policy

Do not start scheduled jobs merely because recovery copied unit files.

For a replacement host still under inspection:

```bash
sudo ./setup.sh systemd install --no-enable-now
```

After storage, secrets, rclone, Cloudflare/DNS, firewall, and Vaultwarden readiness are verified:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

## Retaining old backup keys

Historical encrypted backups remain decryptable only while you retain a matching private identity.

Before discarding an old operational Age private key or old offline recovery key, determine whether any retained `db` or `full` archives were encrypted only to recipients derived from that key.

Useful checks:

```bash
sudo ./backup.sh list
sudo ./backup.sh verify
```

For an old archive, perform a controlled decryption/verification using the intended retained identity before destroying old key material.

Do not assume key rotation rewrapped historical backup archives.

## Backup integrity HMAC key rotation

`file_integrity_hmac_key` authenticates backup checksum sidecars. It is separate from Age encryption.

Rotating it creates a transition issue for existing `.sha256.hmac` sidecars that were signed with the old key. Retain recovery material containing the old HMAC key until old backup generations are retired or follow the documented transition procedure in [SECRETS-SCHEMA.md](SECRETS-SCHEMA.md).

## Optional independent wrapping

You may independently encrypt a recovery-kit file or Age key copy with GPG or another trusted offline mechanism as an additional operator-controlled layer.

That wrapping is not the repository's primary restore API and does not replace:

- `sudo make key-health`;
- recovery-kit export;
- retention of historical decryption identities;
- backup verification;
- the supported `restore.sh` or `recover.sh` flows.

When using an independent wrapper, test the wrapper's decryption on a separate trusted system before relying on it.

## Quarterly recovery check

At least quarterly:

1. confirm the off-host recovery kit/offline Age identity is readable;
2. run `sudo make key-health` on the live host;
3. run `sudo ./backup.sh verify`;
4. run the current pre-production drill/recovery rehearsal appropriate for the host;
5. confirm the exact repository commit or release reference needed by the DR material is still retrievable;
6. confirm the documented provider-console and Cloudflare access is still available.

A file existing in a password manager or offline disk is not proof that it can decrypt the retained backup generation. Test recovery material deliberately.

## Security rules

- Never commit private Age keys, recovery kits, or plaintext secrets.
- Never persist the offline recovery private key on the production server.
- Keep emergency backup passphrases/separate recipient identities independent from the emergency archive location.
- Do not print private key or secret values into ordinary logs or issue reports.
- Re-export recovery material after operational Age key rotation.
- Keep historical private identities until all dependent backup generations are retired.
- Treat an emergency backup and a recovery kit like a password-manager vault export.

## Root-only Age key handoffs


Setup, key rotation, and restore publish private Age identity material only to protected root-owned files under `/root/vaultwarden-recovery/`. Terminal output may show the public recipient and protected path, never the private identity. See [Secure credential and recovery handoffs](SECURE-CREDENTIAL-HANDOFFS.md).
