# Bootstrap Key Recovery — VaultWarden-OCI

This guide covers recovery of the Age key and related bootstrap material used by the current VaultWarden-OCI deployment model.

If you lose the Age key, normal encrypted backups and encrypted secret workflows become much harder or impossible to recover. Treat this document as part of the disaster-recovery plan, not as an optional appendix.

Related docs: [BACKUP-RESTORE.md](BACKUP-RESTORE.md) · [DEPLOYMENT.md](DEPLOYMENT.md) · [OPERATIONS.md](OPERATIONS.md)

---

## What key this refers to

The key in scope is the repository’s Age private key stored at:

```bash
secrets/keys/age-key.txt
```

This key is central to the project’s encrypted backup and secret-management model. Protect it separately from the VM and from normal local-only server storage.

---

## Recommended protection layers

The current project supports and encourages multiple recovery layers.

### 1. Export a recovery kit

```bash
./edit-secrets.sh --export-recovery-kit
```

Do this after initial deployment and after meaningful secret or recovery-material changes. Store the exported material in a secure external location such as a password manager secure note or other protected offline repository.

### 2. Maintain offline escrow

Keep a second copy of the Age key outside the server. Good options include:

- Password manager secure note.
- Encrypted removable media.
- Printed or otherwise physically secured backup if your process supports it.

### 3. Verify you can still use it

A recovery artifact that was never tested is only a guess.

After restoring key material, always validate with:

```bash
./edit-secrets.sh --test
./health.sh
```

---

## When recovery is needed

Use this guide when any of these happen:

- `secrets/keys/age-key.txt` is missing.
- The server was rebuilt and you need to restore encrypted material.
- A backup archive cannot be decrypted on the replacement host.
- Secret editing or export flows fail because the Age key is unavailable.

---

## Recovery path on an existing server

If the host still exists and only the key file is missing or damaged:

1. Retrieve the correct Age key from your recovery kit or offline escrow.
2. Restore it to `secrets/keys/age-key.txt`.
3. Restrict permissions.
4. Test decryption and project health.

Example flow:

```bash
mkdir -p secrets/keys
nano secrets/keys/age-key.txt
chmod 600 secrets/keys/age-key.txt

./edit-secrets.sh --test
./health.sh --comprehensive
```

Do not continue with normal operations until decryption works again.

---

## Recovery path on a fresh server

When rebuilding on a new VM, first get the repository into a baseline state and then restore the key material before attempting deeper recovery.

```bash
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh

sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com
```

Then restore the key:

```bash
mkdir -p secrets/keys
nano secrets/keys/age-key.txt
chmod 600 secrets/keys/age-key.txt
```

Then validate and continue with backup or secret recovery:

```bash
./edit-secrets.sh --test
./restore.sh --file /path/to/backup.age --force
./health.sh
```

---

## If you have an emergency backup

An emergency backup may be your fastest recovery path in a total-loss scenario, especially if it was created right before a risky change.

A practical rebuild flow is:

1. Provision the new host.
2. Clone the repository.
3. Run baseline `setup.sh`.
4. Restore the Age key from escrow or recovery material.
5. Restore the emergency archive.
6. Run health validation.

This keeps recovery aligned with the repository’s current setup and restore model.

---

## Permission and handling rules

When restoring the key, keep handling tight:

- Store it only at `secrets/keys/age-key.txt` unless you are staging a short-lived recovery copy.
- Set mode `600`.
- Remove temporary plaintext copies after validation.
- Do not leave the key in shell history, shared paste buffers, or long-lived temp files.

If you exported the key to an intermediate file during recovery, securely remove that file after validation.

---

## Validation checklist

After restoring the key, confirm the deployment is actually usable again:

```bash
./edit-secrets.sh --test
./backup.sh --type db
./restore.sh
./health.sh --comprehensive
```

At minimum, verify that encrypted secrets can be read and that a backup workflow still succeeds.

---

## If no recovery copy exists

If the Age key is lost and you have no recovery kit, no offline escrow, and no other surviving copy, encrypted artifacts protected by that key may be permanently unrecoverable.

In that case, your remaining path is usually to rebuild the deployment, generate new recovery material, and re-enter any credentials or configuration that cannot be recovered from another secure source.

That is why exporting and separately storing recovery material is part of the normal operating procedure, not an optional extra.
