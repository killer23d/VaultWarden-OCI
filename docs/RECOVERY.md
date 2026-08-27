# Recovery

VaultWarden-OCI has two different recovery artifacts:

- `.vwrec` — encrypted application state used to verify or restore the appliance.
- recovery-kit ZIP — a separately password-protected AES-256 credential/custody handoff used to rebuild access and secrets.

They are not interchangeable.

## What a `.vwrec` contains

| Included | Explicitly excluded |
| --- | --- |
| Canonical non-secret `config.toml` | Server operational Age private key (`age-key.txt`) |
| Encrypted `secrets.sops.yaml` | Offline recovery private identity |
| Vaultwarden data with a consistent SQLite snapshot | Recovery-kit ZIP and its passphrase |
| Caddy persistent data/config required by the recovery contract | Volatile `/run/vaultwarden-oci` rendered/decrypted state |
| Manifest with format version, member paths, sizes, and SHA-256 checksums | Ordinary logs/support bundles and the backup directory as recursive input |

The `.vwrec` envelope uses Age. Its manifest `format_version = 2` is a real compatibility marker and is independent of product/release naming.

## Create and verify without restoring

**Prerequisite:** healthy dedicated storage and valid config/secrets. Verification also requires the offline Age private identity from secure operator custody.

```bash
sudo vwctl backup
sudo vwctl recovery list
sudo vwctl recovery verify \
  --file /var/lib/vaultwarden-oci/backups/<artifact>.vwrec \
  --identity /secure/offline-age-key.txt
```

Configured offsite publication:

```bash
sudo vwctl backup --remote 'REMOTE:path'
sudo vwctl recovery list --remote 'REMOTE:path'
sudo vwctl recovery verify \
  --from-remote 'REMOTE:path/<artifact>.vwrec' \
  --identity /secure/offline-age-key.txt
```

Publication is create -> local verify -> rclone copy/copyto -> independent remote verify -> success. It never uses destructive `rclone sync` as normal publication.

**Expected success:** verification proves the Age envelope, manifest/member/checksum contract, and that the supplied offline identity decrypts the included SOPS document. **On failure:** no live state is promoted; preserve the artifact, fix custody/storage/tooling, and verify again.

## Same-host restore

Use this when the server is intact and the canonical dedicated storage identity still passes.

**Prerequisites:** `/var/lib/vaultwarden-oci` is the expected dedicated mount, a verified `.vwrec` is available locally or remotely, and you have the offline Age private identity.

Guided path:

```bash
sudo vwctl restore
```

1. Choose local or remote.
2. Select the recovery point from the newest-first inventory.
3. Supply the offline Age private identity path.
4. Review storage/decryption/manifest/SOPS/free-space/SQLite preflight.
5. Review the live state that will be replaced.
6. Type the exact `RESTORE` confirmation.
7. After promotion, start when ready if you did not request automatic start.

Explicit local form:

```bash
sudo vwctl restore \
  --file /secure/recovery.vwrec \
  --identity /secure/offline-age-key.txt
```

Explicit remote form:

```bash
sudo vwctl restore \
  --from-remote 'REMOTE:path/recovery.vwrec' \
  --identity /secure/offline-age-key.txt \
  --start
```

A remote object is downloaded once into protected staging; that exact download is verified and restored. All knowable checks run before the mutation boundary/service stop.

**Expected success:** known restored state is present and `sudo vwctl status` plus `sudo vwctl doctor --json` pass after start. **On failure:** do not manually unpack/promote files. A preflight failure should leave healthy live state untouched; if promotion began, follow the reported recovery boundary.

## Lost-server disaster recovery

This is intentionally a different procedure from same-host restore.

**Required off-host material:** a `.vwrec`, the matching offline Age private identity, and preferably the complete recovery-kit ZIP plus its separately stored passphrase. If the only `.vwrec` is on an rclone remote, you also need the credentials/config needed to retrieve it.

1. Build a fresh Ubuntu 24.04 LTS host on a supported architecture and attach a **dedicated** ext4/xfs data volume. Do not restore onto root-only storage.
2. Obtain a trusted release/source checkout and inspect storage as described in [Install](INSTALL.md).
3. Derive the offline public recipient without making the private key persistent appliance state:

   ```bash
   age-keygen -y /secure/offline-age-key.txt
   ```

4. Run `setup.sh install` with the intended domain/URL/email, dedicated data device, and that `age1...` recipient. Supplying the recipient explicitly tells setup to preserve this existing off-host recovery identity; setup must not generate a replacement identity. Complete the new host's operational setup. If you need old credentials to reach Cloudflare/SMTP/rclone, extract the recovery kit on a trusted workstation and enter needed values through `vwctl secrets edit`.
5. Make the desired `.vwrec` available. If rclone is not configured yet, retrieve the object to a secure local path from another trusted machine rather than weakening the restore contract.
6. Verify before restore:

   ```bash
   sudo vwctl recovery verify \
     --file /secure/recovery.vwrec \
     --identity /secure/offline-age-key.txt
   ```

7. Restore, then start and verify:

   ```bash
   sudo vwctl restore --file /secure/recovery.vwrec --identity /secure/offline-age-key.txt
   sudo vwctl start
   sudo vwctl status
   sudo vwctl doctor --json
   ```

**Expected success:** the known vault state is healthy on the new dedicated volume and operational secrets are again server-encrypted. **On failure:** keep the original `.vwrec` and offline material unchanged, correct the fresh-host prerequisite, and retry on disposable/new state rather than modifying the artifact.

## Recovery-kit export and first-run handoff

A complete kit contains exactly:

- `README.txt`
- `config.toml`
- `credentials.txt` with current top-level SOPS-managed credential values
- `operational-age-identity.txt`
- `offline-recovery-identity.txt`

During first-run setup from an interactive terminal, including terminal-driven `--auto`, omitting `--offline-recipient` asks setup to establish this recovery custody for you. Setup generates the separate offline Age private identity only under root-owned volatile `/run/vaultwarden-oci`, passes only its public recipient into the installer, creates and verifies the recovery-kit ZIP, and removes the transient private identity only after successful email handoff or the exact local off-host custody acknowledgement. The recovery-kit passphrase remains an independent interactive secret even when the installation steps use `--auto`.

A fully headless `--auto` run cannot use that generated-key handoff because no operator is present to receive the private identity and passphrase. It must use a pre-existing off-host identity and pass only its public `--offline-recipient`. An explicitly supplied recipient always wins; setup does not silently generate another recovery identity.

Export a later/current kit with an already-custodied offline identity:

```bash
sudo vwctl recovery-kit export --offline-identity /secure/offline-age-key.txt
```

The command proves the supplied offline identity matches config, proves both operational/offline identities decrypt the same current SOPS document, prompts twice for an independent passphrase of at least 16 characters, creates AES-256 ZIP encryption, verifies the exact member set/encryption, proves correct-password success and wrong/empty/no-password failure, then atomically publishes the archive. Email, when configured/chosen, happens only after ZIP verification and sends only the encrypted ZIP through the existing authenticated SMTP owner.

**Password custody:** never put the ZIP passphrase in email, config, secrets, argv, environment, or a file beside the archive. Store or communicate it separately from the ZIP.

**Transient-key custody:** after successful first-run handoff, the setup-generated offline private identity must no longer exist on the appliance. If setup reports a failed handoff and says that the transient identity remains in `/run`, secure that exact identity before reboot; losing it can strand recovery material already addressed to its public recipient.

## Extract the AES-256 recovery kit

Use software that supports AES-encrypted ZIP archives, on a trusted workstation rather than a cloud preview/extraction service.

- **Ubuntu/Linux with 7-Zip:** `7zz x recovery-kit.zip` (or `7z x recovery-kit.zip` where that is the installed command).
- **macOS:** install 7-Zip if needed (`brew install sevenzip`), then `7zz x recovery-kit.zip`.
- **Windows:** use current 7-Zip (`Extract...`) or `7z x recovery-kit.zip` from a terminal.

Enter the passphrase interactively when prompted.

**Expected success:** exactly the documented members extract. **On failure:** after repeated passphrase/integrity failure, retrieve another verified custody copy; do not weaken or convert the archive in place.

## Retention is separate

Plan deletion first:

```bash
sudo vwctl recovery prune --remote 'REMOTE:path' --keep-last 7
```

Execute only after review:

```bash
sudo vwctl recovery prune --remote 'REMOTE:path' --keep-last 7 --confirm
```

Creating/publishing a recovery point never implicitly prunes older offsite material.

## Update recovery boundary

Application update verifies a pre-update `.vwrec`. A candidate that fails before possible persistent-state mutation may permit coherent binary rollback. Once candidate runtime may have changed persistent data, the verified pre-update recovery point—not an old binary symlink—is the downgrade boundary. Ubuntu apt/kernel state is outside `.vwrec` recovery.
