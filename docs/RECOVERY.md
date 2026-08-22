# Recovery

V2 supports one recovery format and one offsite publication model. There is no V1 backup reader, migration format, provider framework, or destructive rclone sync path.

## Recovery custody

A `.vwrec` file is an Age-encrypted V2 recovery archive addressed to the offline Age recipient configured in `/etc/vaultwarden-oci/config.toml`. It contains the operator config, the still-encrypted SOPS document, a consistent Vaultwarden SQLite snapshot/data, and Caddy state needed by V2. It does **not** contain the host operational Age private key.

Keep the offline Age private identity away from the host and test that it can decrypt a disposable recovery artifact before relying on it.

## Create a local recovery point

```bash
sudo vwctl backup
```

The recovery owner quiesces running V2 containers as needed, creates a consistent SQLite snapshot, builds and validates the V2 manifest/archive, encrypts it with Age, verifies the resulting envelope, records its SHA-256/size, and resumes services. A failed verification is not reported as success.

Check status/doctor afterward:

```bash
sudo vwctl status
sudo vwctl doctor --json
```

## Publish with rclone

Configure an rclone remote independently, then:

```bash
sudo vwctl backup --remote REMOTE:path
```

Success means all of these completed:

1. local V2 artifact verified;
2. `rclone copyto` uploaded that exact object;
3. the remote object was downloaded to a temporary local path with `rclone copyto`;
4. the downloaded Age envelope, size, and SHA-256 matched the verified local artifact.

No `rclone sync` is used. Publication does not prune old objects.

## Restore from a local artifact

On a disposable/replacement V2 host with the offline Age private identity available as a root-readable file, invoke restore directly; **do not pre-stop the V2 service**:

```bash
sudo vwctl restore --file /secure/path/recovery.vwrec --identity /secure/offline-age-key.txt
```

Restore deliberately performs the expensive/safety-critical work before downtime: Age decryption, archive/manifest/path/checksum validation, offline SOPS custody validation, target/free-space preflight, staging, ownership/mode preparation, SQLite integrity proof, and replacement operational Age/SOPS custody validation. Only after those checks succeed does it acquire the mutation lock, stop/remove existing V2 containers, and promote staged state. A wrong identity, corrupt artifact, insufficient space, or invalid custody should therefore fail before a running service is stopped.

By default services remain stopped after successful promotion. Inspect the restored configuration and diagnostics, then start deliberately:

```bash
sudo vwctl doctor --json
sudo vwctl start
sudo vwctl status
```

Or request post-promotion startup/health gating in the restore transaction:

```bash
sudo vwctl restore --file /secure/path/recovery.vwrec \
  --identity /secure/offline-age-key.txt --start
```

Restore accepts only the V2 format, validates safe paths and exact manifest membership/checksums, rejects an embedded operational Age key, validates SQLite integrity and SOPS/Age custody, and promotes through a rollback-aware transaction.

## Restore directly from rclone

Again, do not stop a healthy V2 service first. Let restore complete download and preflight before it introduces downtime:

```bash
sudo vwctl restore \
  --from-remote 'REMOTE:path/recovery-file.vwrec' \
  --identity /secure/offline-age-key.txt
```

The remote object is first downloaded to a partial local path and verified before restore processing. It is not streamed blindly into persistent state.

## Explicit remote retention

Plan first:

```bash
sudo vwctl recovery prune --remote REMOTE:path --keep-last 7
```

Review the displayed keep/delete decision. Execute only with explicit confirmation:

```bash
sudo vwctl recovery prune --remote REMOTE:path --keep-last 7 --confirm
```

Retention is deliberately separate from backup publication so creating a new recovery point cannot implicitly delete older remote recovery material.

## Disposable recovery acceptance

A release gate should prove the complete path, not merely archive creation:

1. create known Vaultwarden state on the disposable source host;
2. `vwctl backup --remote REMOTE:acceptance/...`;
3. independently confirm the remote object exists;
4. restore/download it on a clean disposable V2 target (or after preparing disposable target state) **without pre-stopping a healthy target**;
5. use only the offline Age identity for restore decryption;
6. start and pass `vwctl status` + `vwctl doctor --json`;
7. verify the known Vaultwarden state survived;
8. verify the offline identity was not copied into `/etc/vaultwarden-oci` or the recovery artifact.

For a running disposable target, include one deliberate preflight-failure check (for example, a wrong offline identity) and verify `vwctl status` remains healthy afterward. This proves the documented preflight-before-stop property without requiring a destructive failure after promotion begins.

Record the artifact SHA-256, source/target architecture, V2 release version, and acceptance date. Delete acceptance-only remote artifacts explicitly when the release record no longer needs them.

## Failure handling

Do not work around a failed recovery check by unpacking/promoting files manually. Preserve the failed artifact and secret-free diagnostics, correct the underlying configuration/storage/tooling problem, and repeat on disposable state. Recovery code intentionally refuses unsafe paths, symlinks/unsupported file types, incomplete manifests, checksum mismatches, invalid Age envelopes, unrecoverable SOPS custody, and insufficient/unsafe promotion conditions.
