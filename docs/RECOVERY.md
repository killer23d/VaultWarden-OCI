# Recovery

VaultWarden-OCI has one normal encrypted application recovery format, `.vwrec`, plus a **separate** password-protected recovery-kit ZIP for credential handoff. They solve different problems and must not be treated as interchangeable.

There is no public `db`/`full`/`emergency` application-recovery tier model and no compatibility reader for the earlier archive format.

## Application recovery custody

A `.vwrec` file is the encrypted application recovery point. It contains the coherent application/configuration state required by the supported recovery contract while excluding the server's operational Age private key.

The offline Age private recovery identity is kept away from the appliance. Only its public recipient is normal persistent server configuration. The operational Age identity remains server-held and is regenerated/rekeyed safely during a fresh-host restore when required.

## Create, list, and verify recovery points

Use the authoritative CLI:

```bash
sudo vwctl backup
sudo vwctl recovery list
sudo vwctl recovery list --remote REMOTE:path
sudo vwctl recovery verify --file /secure/path/recovery.vwrec --identity /secure/offline-age-key.txt
sudo vwctl recovery verify --from-remote 'REMOTE:path/recovery-file.vwrec' --identity /secure/offline-age-key.txt
```

Inventory is derived from the local recovery directory, rclone listing, and the existing recovery state file. It does not create a second recovery database. Entries are newest-first and show time, size, location, and verification state when known.

`recovery verify` is non-destructive. It decrypts and validates the `.vwrec` envelope, manifest/path/member/checksum contract and proves the supplied offline identity can decrypt the included SOPS document. A failed verification never stops services or promotes data.

## Publish with rclone

Where an rclone remote is configured, normal offsite publication is:

```text
create local candidate
-> verify local candidate
-> copy/copyto-style publication
-> independently verify the remote object
-> report success
```

The explicit CLI form is:

```bash
sudo vwctl backup --remote REMOTE:path
```

Normal publication must not use destructive `rclone sync`. Creating a new recovery point must not implicitly delete older remote recovery material.

## Guided human restore

Run `sudo vwctl restore` in a TTY. The guided flow is:

1. choose local or remote recovery source;
2. display newest-first numbered `.vwrec` recovery points with time, size, location, and known verification state;
3. choose one recovery point;
4. supply the offline Age private identity path;
5. prove the dedicated production-storage mount/identity and perform non-destructive cryptographic/manifest/SOPS preflight;
6. display the live state that will be replaced;
7. require the exact `RESTORE` confirmation;
8. call the same authoritative `recovery.py` restore transaction used by scripted restore.

Cancellation at either picker or final confirmation is safe and does not mutate live state. The picker is a human interface, not a second restore engine.

The restore transaction itself finishes all knowable decryption, checksum, SOPS, free-space, staging, ownership/mode and SQLite checks before it acquires the mutation boundary and stops/removes services. The `vwctl` wrapper also refuses restore/recovery operations unless the filesystem mounted at `/var/lib/vaultwarden-oci` matches both the host storage identity and the mounted-volume ownership marker, so restored data cannot silently fall back to the boot filesystem.

## Explicit restore for automation

Scripted forms remain supported:

```bash
sudo vwctl restore \
  --file /secure/path/recovery.vwrec \
  --identity /secure/offline-age-key.txt

sudo vwctl restore \
  --from-remote 'REMOTE:path/recovery-file.vwrec' \
  --identity /secure/offline-age-key.txt
```

Add `--start` only when a health-gated post-promotion start is desired. Without it, services remain stopped after successful promotion for deliberate operator review.

## Separate recovery-kit credential handoff

The recovery-kit ZIP is **not** a `.vwrec` application recovery point. It is a credential/admin custody artifact. A complete kit contains exactly:

- `README.txt` — recovery-kit purpose/custody instructions without secret values;
- `config.toml` — canonical non-secret appliance configuration useful during rebuild;
- `credentials.txt` — every current top-level SOPS-managed credential value, including Vaultwarden admin and Caddy admin Basic Auth credentials when configured;
- `operational-age-identity.txt` — the server-held operational Age private identity;
- `offline-recovery-identity.txt` — the matching offline recovery Age private identity.

Later complete export is explicit:

```bash
sudo vwctl recovery-kit export --offline-identity /secure/offline-age-key.txt
```

The appliance cannot recreate the same offline identity later. The command derives its public recipient, requires it to match `config.toml`, proves both the operational and supplied offline identities decrypt the same current SOPS document, and refuses to label/export the kit as complete when that proof is unavailable.

The fixed ZIP security contract is:

- plaintext kit members exist only in a protected root-owned temporary workspace;
- independent ZIP passphrase is entered interactively twice and must be at least 16 characters;
- passphrase is supplied to `7zz` over stdin only, never argv, environment, a file, logs, email subject/body, or project secrets;
- Ubuntu `7zip`/`7zz` creates an AES-256 ZIP;
- before publication/email, verification proves ZIP container type, exact member set, AES-256 encryption for every member, correct-passphrase archive test success, deliberate wrong-passphrase failure, empty-passphrase failure, and no-passphrase failure;
- only a fully verified ZIP is atomically published in the protected recovery directory;
- email, when accepted, uses direct authenticated SMTP with the configured TLS mode and sends only the verified ZIP attachment; provider-specific HTTP attachment APIs are not used;
- the ZIP passphrase is never included in email.

The protected plaintext workspace is removed after publication; cleanup failure is an observable command failure.

## Initial setup offline custody

Interactive first-run setup without `--offline-recipient` generates the offline Age private identity only in a root-owned volatile `/run/vaultwarden-oci/setup-offline-recovery-*` workspace. Setup receives only the derived public recipient. After setup completes, the same private identity is included in the verified complete recovery-kit ZIP. Only after that handoff succeeds is the host-side volatile private copy removed.

If setup or kit publication fails after generation, the wrapper reports the volatile path and does **not** pretend custody succeeded. The private identity is never installed as ordinary persistent server state. Noninteractive setup and setup with an explicit `--offline-recipient` keep the existing operator-supplied custody model.

The same supported export surface is reachable from setup as:

```bash
sudo ./setup.sh recovery-kit export --offline-identity /secure/offline-age-key.txt
```

A later dashboard may call the same public Python/`vwctl` interface; no dashboard-specific recovery engine is required.

## Explicit remote retention

Retention/deletion is separate from publication. Plan before destructive action:

```bash
sudo vwctl recovery prune --remote REMOTE:path --keep-last 7
```

Then require the explicit confirmation form before deletion:

```bash
sudo vwctl recovery prune --remote REMOTE:path --keep-last 7 --confirm
```

## Recovery acceptance

A release gate should prove the complete path on disposable state:

1. create known application state;
2. create and verify a `.vwrec`;
3. publish it to a test remote and independently verify the remote object;
4. prove a safe preflight failure does not stop/corrupt a healthy target;
5. restore on a clean/disposable target using only the offline Age identity for recovery decryption;
6. start and pass `vwctl status` plus `vwctl doctor --json`;
7. confirm known application state survived;
8. confirm the operational Age private key was not embedded in the recovery point;
9. separately exercise the recovery-kit ZIP handoff and verify AES/member/password behavior and passphrase redaction.

## Update recovery boundary

Application updates verify a pre-update `.vwrec` before activation. If a candidate release fails before it could mutate persistent application state, the implementation may coherently restore the prior release. If candidate runtime activation may have changed persistent state, do not blindly switch binaries backward and claim the data was rolled back. The verified pre-update recovery point is the downgrade boundary.

Ubuntu apt/kernel changes are outside application recovery. `.vwrec` does not pretend to roll back host package state.

## Failure handling

Do not bypass failed recovery checks by unpacking/promoting files manually. Preserve the failed artifact and secret-free diagnostics, correct the underlying storage/config/tooling problem, and retry on disposable state when appropriate.
