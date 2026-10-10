# Recovery

VaultWarden-OCI has two different recovery artifacts:

- `.vwrec` — encrypted application state used to verify or restore the appliance.
- recovery-kit ZIP — a separately password-protected AES-256 credential/custody handoff used to rebuild access and secrets.

They are not interchangeable. **First-install checklist:** keep the verified encrypted recovery-kit ZIP **off the server**, keep its passphrase **separately**, and create a `.vwrec` after the first healthy start. The kit contains the offline private recovery identity needed to unlock backup material. A backup without a matching usable identity may be unrecoverable.

## What a `.vwrec` contains

| Included | Explicitly excluded |
| --- | --- |
| Canonical non-secret `config.toml` | Server operational Age private key (`age-key.txt`) |
| Encrypted `secrets.sops.yaml` | Offline recovery private identity |
| Vaultwarden data with a consistent SQLite snapshot | Recovery-kit ZIP and its passphrase |
| Caddy persistent data/config required by the recovery contract | Volatile `/run/vaultwarden-oci` rendered/decrypted state |
| Manifest with format version, member paths, sizes, and SHA-256 checksums | Ordinary logs/support bundles and the backup directory as recursive input |

The `.vwrec` envelope uses Age. Its manifest `format_version = 2` is a real compatibility marker and is independent of product/release naming.

## Automatic versus manual protection

| Task | What happens today |
| --- | --- |
| Scheduled local backup | Once daily at **03:15 server-local time**, plus up to 15 minutes of randomized delay, after `vaultwarden-oci.target` is enabled |
| Local destination | `/var/lib/vaultwarden-oci/backups/` on the dedicated data volume (not protection against loss of that volume) |
| Offsite backup | **Optional automatic** daily verified publication through the same backup timer, enabled with `sudo vwctl recovery offsite configure`; local-only until configured |
| Offline-key verification | **Manual** with `vwctl recovery verify` and the matching off-server private Age identity |
| Retention | No automatic deletion; remote prune is an explicit preview/confirm action, and there is no supported local prune command |
| Recovery-kit ZIP | Separate, password-protected credential handoff; the normal `.vwrec` backup timer does **not** create or upload it |

Backup briefly pauses running application containers for a consistent copy, snapshots SQLite, resumes the containers, and checks their health. It checks the staged manifest, then encrypts to the **offline public Age recipient**. The matching **private key** stays off-server, so a successful scheduled backup does **not** itself prove that the off-server key can decrypt the resulting file. Run an independent `recovery verify` periodically.

**Minimum practical plan:** make a first local backup; protect the credential recovery-kit ZIP and its separate passphrase off-server; publish a `.vwrec` offsite; verify decryption of the offsite copy with the offline identity; and practice restoring onto a disposable host. `vwctl doctor` reports the last recorded backup state but does not replace a real restore test.

## Create and verify without restoring

On a healthy installed server, make and list a local recovery point:

```bash
sudo vwctl backup
sudo vwctl recovery list
```

Use the **actual** filename printed by the command:

```bash
sudo vwctl recovery verify \
  --file /var/lib/vaultwarden-oci/backups/recovery-REPLACE_ME.vwrec
```

On an interactive terminal, verification offers secure paste of the matching offline Age private identity, selection of an identity file (such as removable media), or a local encrypted recovery-kit ZIP. For unattended use, provide an explicit `--identity /secure/offline-age-key.txt`. The regular operational key at `/etc/vaultwarden-oci/age-key.txt` is **not** a replacement for your offline key.

This verification decrypts the real `.vwrec`, checks the manifest/checksums and verifies the encrypted SOPS document, **without changing live application data**. A backup-created PASS and an rclone upload checksum are not substitutes for this key-based check.

## Configure automatic offsite backups (rclone)

**Offsite copies are optional and off by default.** Once enabled, the existing daily backup timer creates a local encrypted recovery point, uploads it through rclone, re-downloads the uploaded bytes, and checks SHA-256. Local recovery points are retained if publication fails, but the service returns failure and reports the offsite problem. No new background scheduler or destructive `rclone sync` is used.

1. Set up a cloud provider with `sudo rclone config`. The scheduled service uses **root's** rclone configuration, not the Ubuntu login user's configuration. Do not store provider tokens, passwords, or the offline Age private identity in `config.toml`.
2. Run `sudo vwctl recovery offsite configure`. Choose a numbered rclone remote, provide a destination folder (default `Vaultwarden-OCI`), and type `ENABLE` to save it. This validates root's rclone remote before modifying the protected operator configuration.
3. Run a first manual backup and inspect the results:

   ```bash
   sudo vwctl backup
   sudo vwctl recovery offsite status
   sudo vwctl recovery list
   sudo vwctl timers
   ```

4. Verify actual Age/SOPS decryption periodically using the **separate offline private identity**, for example by choosing a remote filename from `recovery list`:

   ```bash
   sudo vwctl recovery verify --from-remote 'offsite:Vaultwarden-OCI/recovery-REPLACE_ME.vwrec'
   ```

For a headless administrator, configure the destination explicitly:

```bash
sudo vwctl recovery offsite configure --remote 'offsite:Vaultwarden-OCI'
sudo vwctl recovery offsite status
```

The explicit `--remote` passed to `sudo vwctl backup --remote 'another:folder'` overrides the saved destination **for that run only**. Do not change the scheduled unit or add a second timer. If you deliberately want local-only scheduled backups again, use `sudo vwctl recovery offsite disable` (or add `--confirm` for a headless invocation). Disabling does **not** delete local/remote backup files.

The rclone connection/credentials must separately survive total server loss; they are **not** in the application `.vwrec` or credential-recovery ZIP. An optional rclone crypt remote is compatible but does not replace offline Age private-key custody. There is **no automatic local or remote pruning**, so monitor free space and apply explicit reviewed retention. A successful remote checksum roundtrip alone does not prove that the **offline recovery key** can decrypt a backup.

## Same-host restore

Use this when the server is intact and the canonical dedicated storage identity still passes. **Restore replaces live application state and involves downtime.** Practice on a disposable host rather than risking your only production copy.

**Prerequisites:** `/var/lib/vaultwarden-oci` is the expected dedicated mount, a verified `.vwrec` is available locally or remotely, and you have the offline Age private identity.

Guided path:

```bash
sudo vwctl restore
```

1. Choose local or remote.
2. If you choose remote, accept the saved offsite destination or enter another remote path. Select a recovery point from the newest-first numbered inventory.
3. Supply the matching offline Age private identity through the interactive chooser:
   - press Enter to paste an `AGE-SECRET-KEY` with input echo disabled;
   - select an existing identity file from removable media or another secure path; or
   - select a local encrypted recovery-kit ZIP discovered under `/root/vaultwarden-recovery/`.
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

Interactive restore and verification display the configured public offline recovery recipient before asking for the matching private identity. The offline private key is **not stored on the appliance by default**. Pasted identities and identities extracted from a recovery-kit ZIP exist only in root-owned protected volatile storage under `/run/vaultwarden-oci`, mode `0600`, and are removed when the command completes, fails, is cancelled, or is interrupted. The operational key at `/etc/vaultwarden-oci/age-key.txt` is a different identity and is not a substitute for offline recovery.

**Expected success:** known restored state is present and `sudo vwctl status` plus `sudo vwctl doctor --json` pass after start. **On failure:** do not manually unpack/promote files. A preflight failure should leave healthy live state untouched; if promotion began, follow the reported recovery boundary.

## Lost-server disaster recovery

This is intentionally a different procedure from same-host restore.

**Required off-host material:** a `.vwrec`, the matching offline Age private identity, and preferably the complete recovery-kit ZIP plus its separately stored passphrase. If the only `.vwrec` is on an rclone remote, you also need the credentials/config needed to retrieve it.

1. Build a fresh supported Ubuntu host—24.04 LTS Noble or 26.04 LTS Resolute—on a supported architecture and attach a **dedicated** ext4/xfs data volume. Do not restore onto root-only storage. A `.vwrec` is application-level recovery material, not an operating-system snapshot; an OS move is performed by restoring onto a fresh supported host rather than upgrading the old host in place.
2. Obtain a trusted release/source checkout and inspect storage as described in [Install](INSTALL.md).
3. On a **trusted workstation with Age installed**, derive the **public** recovery recipient from your matching off-server private key:

   ```bash
   age-keygen -y /secure/offline-age-key.txt
   ```

   Copy only the printed `age1...` **public** value to the replacement server. Do not place your offline private identity in persistent server storage. A fresh Ubuntu image may not have `age-keygen` until setup installs its dependencies.

4. Run the trusted `setup.sh install` from [Install](INSTALL.md) with your domain/URL/email and **`--offline-recipient` set to that existing public value**. Choose and explicitly confirm the new **dedicated data disk**. Setup must preserve the existing offline identity instead of generating a new one. **Do not move the public Cloudflare A record to this server yet.**

5. Make the desired `.vwrec` available under a secure local path (such as `/secure/recovery.vwrec`). If it exists only in cloud storage, reconfigure **root's** rclone remote or retrieve the file via a trusted workstation and securely transfer it. Root's rclone config and access credentials are **not inside the `.vwrec` or recovery kit**. Preserve the original remote object and identity.

6. Verify **decryption** of the archive before modifying the freshly installed state:

   ```bash
   sudo vwctl recovery verify --file /secure/recovery.vwrec
   ```

   On an interactive terminal, supply the matching off-server Age private identity through the secure chooser. For noninteractive workflows, an explicit `--identity /secure/offline-age-key.txt` is required.

7. Restore the verified application archive, keeping services stopped until the recovered configuration and required host security are ready:

   ```bash
   sudo vwctl restore --file /secure/recovery.vwrec
   sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
   sudo vwctl secrets validate
   sudo vwctl dns update --dry-run
   ```

   Restore replaces the Vaultwarden data/SQLite database, Caddy persistent state, config, and encrypted secrets. It retains or regenerates/rekeys the new host's **operational** Age identity as needed, while the **offline private key stays in your separate custody**. It does not restore Ubuntu, packages, firewall service setup, or root's rclone configuration.

   Complete the standard Cloudflare/CrowdSec security activation and the **Worker Route Fail Open** confirmation in [Install, Step 6](INSTALL.md#6-validate-and-activate-security) **before** starting. Then follow [Install, Step 7](INSTALL.md#7-start-update-dns-and-create-the-first-backup): start the recovered app, check status/doctor, **only then** update the existing Cloudflare A record to the new host, create a verified backup, and enable timers. If the old host is still active, plan the DNS cutover deliberately rather than blindly overriding live traffic.

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

Export a later/current kit interactively:

```bash
sudo vwctl recovery-kit export
```

The same secure identity chooser is used here. You can also supply the already-custodied identity explicitly:

```bash
sudo vwctl recovery-kit export --offline-identity /secure/offline-age-key.txt
```

This keeps identity selection explicit for scripted wrappers, but recovery-kit export itself remains an interactive TTY workflow because its independent ZIP passphrase is entered and confirmed securely at run time.

The command proves the supplied offline identity matches config, proves both operational/offline identities decrypt the same current SOPS document, prompts twice for an independent passphrase of at least 16 characters, creates AES-256 ZIP encryption, verifies the exact member set/encryption, proves correct-password success and wrong/empty/no-password failure, then atomically publishes the archive. Email, when configured/chosen, happens only after ZIP verification and sends only the encrypted ZIP through the existing authenticated SMTP owner.

**Password custody:** never put the ZIP passphrase in email, config, secrets, argv, environment, or a file beside the archive. Store or communicate it separately from the ZIP. Interactive recovery-kit selection also supplies this passphrase with echo disabled and the secure 7-Zip stdin transport; it is never placed in argv or the environment.

For non-TTY restore/verify callers, omission of `--identity` is an immediate error. For non-TTY recovery-kit export, omission of `--offline-identity` is an immediate error. Noninteractive workflows never read `/dev/tty`, choose a local recovery kit automatically, or attempt to recover a private identity on their own.

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

Creating/publishing a recovery point **never implicitly prunes** older offsite material. The prune command affects only `.vwrec` files under the **specified remote path**; review the Keep/Delete plan and independently verify the retained recovery points and matching Age private identity before confirming.

**Local backup files accumulate daily, too.** There is currently **no supported local `vwctl recovery prune` subcommand** or automatic local-retention setting. Monitor free space with `df -h /var/lib/vaultwarden-oci`. Do not delete the only working recovery point to free space; first verify an independent offsite copy and agree on a retention policy. Neither local nor remote backup jobs automatically refresh the credential recovery-kit ZIP, so refresh its secure off-server custody after credential rotation.

## Update recovery boundary

Application update verifies a pre-update `.vwrec`. A candidate that fails before possible persistent-state mutation may permit coherent binary rollback. Once candidate runtime may have changed persistent data, the verified pre-update recovery point—not an old binary symlink—is the downgrade boundary. Ubuntu apt/kernel state is outside `.vwrec` recovery.

If backup, rclone publication, verification, identity selection, restore, or update recovery does not behave as described, use [Troubleshooting](TROUBLESHOOTING.md). Preserve the original recovery artifact and custody material while diagnosing the failure.
