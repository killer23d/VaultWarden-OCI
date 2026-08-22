# Recovery

VaultWarden-OCI has one normal encrypted application recovery format, `.vwrec`, plus a **separate** password-protected recovery-kit ZIP for credential handoff. They solve different problems and must not be treated as interchangeable.

There is no public `db`/`full`/`emergency` application-recovery tier model and no compatibility reader for the earlier archive format.

## Application recovery custody

A `.vwrec` file is the encrypted application recovery point. It contains the application/configuration state required by the supported recovery contract while excluding the server's operational Age private key.

The offline Age private recovery identity is kept away from the appliance. Only the public recipient needed for normal encryption/configuration is present on the server. Test the offline identity against disposable recovery material before relying on it.

## Create and verify a local recovery point

Use the authoritative CLI:

```bash
sudo vwctl backup
sudo vwctl status
sudo vwctl doctor --json
```

A recovery operation is successful only after the application recovery artifact has passed its required consistency, manifest/path/checksum, encryption/envelope, and relevant SQLite/SOPS custody checks. Failed verification is not success.

## Publish with rclone

Where an rclone remote is configured, normal offsite publication is:

```text
create local candidate
-> verify local candidate
-> copy/copyto-style publication
-> independently verify the remote object
-> report success
```

The current explicit CLI form is:

```bash
sudo vwctl backup --remote REMOTE:path
```

Normal publication must not use destructive `rclone sync`. Creating a new recovery point must not implicitly delete older remote recovery material.

## Human restore picker

The supported human restore experience includes a guided local/remote picker in the useful interaction style of the earlier product. It should help the administrator choose a local `.vwrec` or a remote recovery object, surface what will be restored, and then call the same authoritative restore implementation.

The picker is a human interface, not a second restore engine. Validation, staging, locking, promotion, and post-restore health behavior remain owned by the Python/`vwctl` recovery implementation.

## Explicit local restore for automation

Noninteractive explicit forms remain supported. For example:

```bash
sudo vwctl restore \
  --file /secure/path/recovery.vwrec \
  --identity /secure/offline-age-key.txt
```

Do **not** pre-stop a healthy service merely to begin restore. The restore implementation should perform expensive/safety-critical preflight work before downtime: decryption, archive/manifest/path/checksum validation, SOPS custody validation, storage/free-space checks, staging, ownership/mode preparation, and SQLite integrity proof.

Only after those checks pass should it acquire the mutation boundary, stop/remove the running application as required, and promote staged state.

After a successful promotion, inspect diagnostics and start deliberately unless the selected restore mode explicitly includes a health-gated start:

```bash
sudo vwctl doctor --json
sudo vwctl start
sudo vwctl status
```

## Explicit remote restore for automation

The explicit remote form remains supported, for example:

```bash
sudo vwctl restore \
  --from-remote 'REMOTE:path/recovery-file.vwrec' \
  --identity /secure/offline-age-key.txt
```

The remote object is downloaded/staged and validated before promotion; it is not streamed blindly into live persistent state.

## Separate recovery-kit credential handoff

The recovery-kit ZIP is **not** a `.vwrec` application recovery point. It is a credential-handoff artifact intended to give the operator an independently protected copy of required recovery/credential material.

Its fixed security contract is:

- AES-256 encrypted ZIP;
- passphrase entered interactively and entered again for confirmation;
- passphrase independent of Vaultwarden/admin/SMTP/API/Age credentials already stored by the appliance;
- passphrase never supplied through argv;
- passphrase never supplied through environment variables;
- passphrase never read from a file;
- passphrase never sent by email;
- the completed encrypted ZIP is fully verified before email is attempted;
- failed verification blocks email/handoff success;
- failed/declined email remains an observable handoff outcome rather than rewriting ZIP verification as failure or success.

The implementation should minimize plaintext lifetime and leave no persistent server copy of the separate offline recovery private identity merely to build the kit.

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
9. separately exercise the recovery-kit ZIP handoff and verify the passphrase never appears in argv/environment/file/email/log evidence.

## Update recovery boundary

Application updates verify a pre-update `.vwrec` before activation. If a candidate release fails before it could mutate persistent application state, the implementation may coherently restore the prior release. If candidate runtime activation may have changed persistent state, do not blindly switch binaries backward and claim the data was rolled back. The verified pre-update recovery point is the downgrade boundary.

Ubuntu apt/kernel changes are outside application recovery. `.vwrec` does not pretend to roll back host package state.

## Failure handling

Do not bypass failed recovery checks by unpacking/promoting files manually. Preserve the failed artifact and secret-free diagnostics, correct the underlying storage/config/tooling problem, and retry on disposable state when appropriate.

## Current development-branch gaps

The current development branch already implements the explicit `.vwrec` CLI recovery path and rclone publication/pruning model, but it does not yet provide the approved guided human local/remote picker or the separate approved recovery-kit ZIP workflow on this branch. Those are implementation gaps, not optional product behavior.
