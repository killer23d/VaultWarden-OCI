# Troubleshooting Guide — VaultWarden-OCI

Common diagnosis and recovery steps for the current root-operated VaultWarden-OCI appliance.

Related docs: [OPERATIONS.md](OPERATIONS.md) · [BACKUP-RESTORE.md](BACKUP-RESTORE.md) · [DISASTER-RECOVERY.md](DISASTER-RECOVERY.md) · [RESTORE-RUNTIME-PERMISSIONS.md](RESTORE-RUNTIME-PERMISSIONS.md)

## General triage flow

Start with the least destructive checks:

```bash
sudo make operations
sudo ./maintenance.sh health || true
docker compose ps
docker compose logs --tail=100
sudo ./setup.sh systemd validate || true
```

Then narrow by symptom:

| Symptom | First check |
| :-- | :-- |
| SSH disconnected during setup/backup/restore/update/migration | `sudo make operations` |
| Vault inaccessible | `sudo ./maintenance.sh health` |
| Cloudflare `525` / local TLS failure | local SNI curl + Caddy logs |
| Backup failed | backup service journal + `sudo ./backup.sh list` |
| Restore failed | `sudo ./restore.sh inspect --remote` and selected archive/key metadata |
| Secrets unavailable | `sudo make key-health` |
| Timer/automation failure | `sudo ./setup.sh systemd validate` |
| Storage/mount mismatch | `utilities/env-edit.sh status` + `sudo utilities/setup-storage.sh verify` |
| CrowdSec enforcement missing | engine + both bouncers + decision/Worker logs |

If `sudo make operations` shows the original operation is active, inspect its owner/phase and wait or use the guarded conflict action offered by the owning workflow.

Do not delete lock files as a generic repair. The project will not automatically terminate `apt` or `dpkg` package work.

---

## Services will not start

Symptoms:

- `sudo make up` exits non-zero;
- `startup.sh` exits non-zero;
- critical containers are absent, unhealthy, or restarting.

Diagnosis:

```bash
sudo make operations
sudo ./maintenance.sh health || true
docker compose config --quiet
docker compose ps
docker compose logs --tail=120
sudo ls -la /run/vaultwarden-oci/secrets/
utilities/env-edit.sh status
sudo utilities/setup-storage.sh verify
```

Check/repair known path permissions:

```bash
sudo utilities/repair-permissions.sh --check
sudo utilities/repair-permissions.sh
```

Retry the supported lifecycle path:

```bash
sudo make up
sudo make health
```

Do not replace the production start path with `docker compose up -d` merely because Compose syntax is valid. Bare Compose bypasses project storage, secret materialization, environment, and operation-guard behavior.

### Generated Compose file is stale or invalid

First validate the committed template independently:

```bash
docker compose \
  --env-file .env.example \
  -f docker-compose.yml.example \
  config --quiet
```

Then inspect the configured deployment:

```bash
docker compose config --quiet
```

If `docker-compose.yml` is stale relative to the current template/setup contract, correct the owning configuration/setup source and regenerate through the supported setup/environment path. Do not hand-patch a generated file while leaving its source inconsistent.

For ordinary `.env` changes, use:

```bash
sudo make edit-env
sudo make restart
sudo make health
```

Do not rerun full `setup.sh install --force` as a generic configuration repair.

---

## Cloudflare `525` / Caddy TLS failure after restore

Symptoms:

- Cloudflare returns `525`;
- local HTTPS to the origin fails;
- Caddy logs mention permission failures for `/data`, `/config`, `/var/log/caddy`, certificate keys, storage locks, or autosave.

Diagnosis:

```bash
DOMAIN="vault.example.com"

curl -vk --resolve "$DOMAIN:443:127.0.0.1" \
  "https://$DOMAIN/alive" \
  -o /dev/null \
  -w "local HTTPS /alive: HTTP %{http_code}\n"

curl -vk --resolve "$DOMAIN:443:127.0.0.1" \
  "https://$DOMAIN/api/config" \
  -o /dev/null \
  -w "local HTTPS /api/config: HTTP %{http_code}\n"

sudo docker logs vaultwarden_caddy --tail=120 2>&1 \
  | grep -Ei 'permission|certificate|tls|handshake|error|warn|storage|autosave' || true

sudo utilities/repair-permissions.sh --check
```

Repair:

```bash
sudo utilities/repair-permissions.sh
sudo docker compose restart caddy
sudo ./maintenance.sh health
```

The post-restore runtime contract normalizes Caddy data/config/log bind mounts to UID/GID `2000:2000` while preserving root-operated private configuration/secrets.

Do not use:

```bash
sudo chmod -R 777 "$PROJECT_STATE_DIR"
sudo chown -R 2000:2000 "$PROJECT_STATE_DIR"
```

Those commands can expose private state or break Vaultwarden ownership.

---

## Caddy certificate / DNS-01 problems

Symptoms:

- DNS-01 challenge fails;
- certificate issuance fails;
- Caddy logs report Cloudflare API/token errors.

Diagnosis:

```bash
docker compose logs caddy --tail=150 \
  | grep -iE 'cloudflare|dns|challenge|certificate|error'

sudo ./utilities/secrets-list.sh
sudo ./maintenance.sh health
```

Rotate the Caddy DNS token through the schema-aware secret path:

```bash
sudo ./edit-secrets.sh rotate caddy_cloudflare_dns_token
sudo ./maintenance.sh health
```

`cloudflare_zone_id` belongs to the CrowdSec Workers integration; it is not the Caddy DNS-01 token.

After the origin certificate is healthy, confirm Cloudflare SSL/TLS mode is **Full (Strict)**.

---

## Vaultwarden container crashes or database errors

Diagnosis:

```bash
docker compose logs vaultwarden --tail=150
sudo sqlite3 \
  "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/data/db.sqlite3" \
  'PRAGMA integrity_check;'

docker stats --no-stream
```

Run the guarded database-maintenance path only when the database is structurally healthy enough for the owning maintenance workflow:

```bash
sudo ./maintenance.sh db-maint
sudo ./maintenance.sh health
```

If corruption is confirmed and the live database is not a valid repair source, restore a verified database backup:

```bash
sudo ./restore.sh latest db
sudo ./maintenance.sh health
```

Do not manually copy live WAL/SHM files between hosts as a recovery method.

---

## Restore fails

Symptoms:

- Age decrypt error;
- storage preflight refuses the target;
- restore stops before service start;
- a required key acknowledgement times out;
- services or `/alive` fail after restore.

Diagnosis:

```bash
sudo ./restore.sh inspect --remote
sudo make key-health
```

For a selected local archive, inspect its normal sidecars without printing secret contents:

```bash
cat /path/to/backup.age.meta
sha256sum -c /path/to/backup.age.sha256
```

Common causes:

| Cause | Correct direction |
| :-- | :-- |
| Wrong Age identity | Use a private key for a recipient that encrypted the selected backup. |
| Emergency independent protection missing | Supply the emergency passphrase or matching `EMERGENCY_BACKUP_AGE_RECIPIENT` private identity. |
| Attached-volume backup targeting boot storage | Prepare/mount the expected data volume, then rerun inspect. |
| Archive lacks the required verified live-path database | Choose another full/emergency archive or a database backup. |
| Caddy ownership drift | Run `repair-permissions.sh`, then recheck health. |
| Operator wants inspection before startup | Use `--start-policy ask` or `--no-start`. |
| Prompt/`SAVED` acknowledgement timed out | Treat the restore as failed-safe; preserve printed recovery material and follow the manual next steps. |

Backup tiers remain distinct:

- `db` — storage-layout-independent database rollback;
- `full` — normal DR archive without the live operational Age private key;
- `emergency` — independently sealed clone-grade capsule that may carry staged `/etc/vaultwarden` key/config material.

A new operational Age key cannot decrypt a historical archive merely because it is the current server key. Retain and use the private identity matching the selected backup generation.

After a successful restore that is intended to return to automated production:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

---

## Backup creation or verification fails

Diagnosis:

```bash
df -h "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
sudo make key-health
sudo ./backup.sh list
journalctl -u vaultwarden-db-backup.service -n 100 --no-pager
journalctl -u vaultwarden-full-backup.service -n 100 --no-pager
```

Retry only after understanding the failure:

```bash
sudo ./maintenance.sh db-maint
sudo ./backup.sh run db
sudo ./backup.sh run full --full-verification
```

A required verification failure is a real backup failure. The failed new archive is not a valid restore candidate and does not justify retention/pruning of older recovery points.

### rclone/offsite failure

Check the intended remote and the current config source:

```bash
rclone listremotes
rclone lsd your_remote_name:
utilities/env-edit.sh status
```

The root-operated installed runtime path is normally:

```text
/etc/vaultwarden/rclone.conf
```

After fixing/recreating rclone source configuration, activate the current installed systemd runtime:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./backup.sh run db --rclone
```

Do not describe a requested-but-skipped offsite sync as successful remote protection.

---

## Backup verification reports no matching Age key

Diagnosis:

```bash
sudo make key-show
sudo make key-health
sudo ./backup.sh verify
```

If the selected backup was encrypted before an operational key rotation, use the retained old operational key or offline recovery private identity that matches a recipient on that backup.

A newly generated key will not decrypt old ciphertext.

If every matching private identity has been lost, the affected encrypted backup generation is unrecoverable. Do not delete the archives or create misleading new sidecars while investigating key custody.

See [BOOTSTRAP_KEY_RECOVERY.md](BOOTSTRAP_KEY_RECOVERY.md).

---

## Secrets decryption fails

Diagnosis:

```bash
sudo make key-health
sudo ./utilities/secrets-list.sh
```

A direct decrypt probe may be run without printing plaintext:

```bash
sudo bash -c '
  set -euo pipefail
  export PROJECT_ROOT="$PWD"
  source "$PROJECT_ROOT/lib/config.sh"
  load_project_environment
  SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE" \
    sops -d "$SECRETS_FILE" >/dev/null
'
```

Check known permissions:

```bash
sudo utilities/repair-permissions.sh --check
sudo utilities/repair-permissions.sh
sudo make key-health
```

Edit through the supported encrypted workflow:

```bash
sudo ./edit-secrets.sh edit
```

Do not copy decrypted values into `.env` or persist decoded secret state in a world-readable form.

---

## Health reports placeholder or missing feature secrets

List current key names and use the schema-aware rotation path:

```bash
sudo ./utilities/secrets-list.sh
sudo ./edit-secrets.sh rotate caddy_cloudflare_dns_token
sudo ./edit-secrets.sh rotate cf_worker_bouncer_token
sudo ./edit-secrets.sh rotate cloudflare_zone_id
sudo ./edit-secrets.sh rotate cf_account_id
sudo ./edit-secrets.sh rotate smtp_password
sudo make health
```

The exact key inventory and required/conditional behavior are owned by `secrets-schema.yaml` and documented in [SECRETS-SCHEMA.md](SECRETS-SCHEMA.md).

---

## Email not sending

Start with the dedicated diagnostic:

```bash
sudo ./maintenance.sh test-email --verbose
```

Inspect Postfix when using the normal SMTP path:

```bash
sudo make email-queue-summary
sudo make email-queue
sudo make email-queue-logs EMAIL_QUEUE_TAIL=120
```

For one current message, copy its case-sensitive queue ID from the listing and
run `sudo make email-queue-inspect QUEUE_ID=AbC-123`. Message bodies are omitted
by default; use `EMAIL_QUEUE_BODY=true` only when the sensitive content is
needed for diagnosis. An empty queue is not proof of successful recipient
delivery, so correlate the queue state with Postfix and upstream relay evidence.

If snapshot purge reports an identity mismatch or reused queue ID, the current
message was preserved rather than deleted. Review the final counts and recent
Postfix logs, then take a new snapshot before retrying. Any mismatch or failed
destructive operation returns nonzero and represents a partial result.

Edit non-secret SMTP settings through:

```bash
sudo make edit-env
```

Rotate the relay password through SOPS:

```bash
sudo ./edit-secrets.sh rotate smtp_password
```

Then:

```bash
sudo make restart
sudo ./maintenance.sh test-email --verbose
```

Do not point Vaultwarden directly at the upstream SMTP relay in the normal architecture. Vaultwarden uses the internal Postfix sidecar; Postfix owns upstream authentication/TLS/queueing.

For API-mode operational alerts, inspect `EMAIL_MODE`, `EMAIL_PROVIDER`, and `email_api_token`. Keep SMTP/Postfix configured for Vaultwarden mail and attachment-based recovery-kit delivery.

See [EMAIL.md](EMAIL.md).

---

## CrowdSec detects events but enforcement is missing

Check the engine and both bouncers:

```bash
sudo systemctl status crowdsec --no-pager -l
sudo systemctl status crowdsec-firewall-bouncer --no-pager -l
sudo systemctl status crowdsec-cloudflare-worker-bouncer --no-pager -l
sudo cscli decisions list
sudo cscli alerts list --since 24h
sudo cscli bouncers list
```

Inspect logs:

```bash
sudo journalctl -u crowdsec -n 100 --no-pager
sudo journalctl -u crowdsec-firewall-bouncer -n 100 --no-pager
sudo journalctl -u crowdsec-cloudflare-worker-bouncer -n 150 --no-pager
```

After Workers credential/account/zone changes:

```bash
sudo ./utilities/crowdsec-worker-apply.sh
```

Refresh the separate Cloudflare-origin UFW CIDR allowlist through:

```bash
sudo ./maintenance.sh update-firewall
```

Do not confuse these controls:

- CrowdSec firewall bouncer — host decision enforcement;
- Workers bouncer/KV — edge enforcement for the configured locally generated web decision flow;
- UFW Cloudflare CIDR refresh — origin-source allowlist for ports `80`/`443`.

If your own IP has a CrowdSec decision:

```bash
sudo cscli decisions delete --ip <your-ip>
sudo ./utilities/setup-crowdsec.sh --admin-ip <your-ip-or-cidr>
```

See [CROWDSEC.md](CROWDSEC.md).

---

## systemd timers or installed automation are stale

Diagnosis:

```bash
sudo ./setup.sh systemd status
sudo ./setup.sh systemd validate
systemctl list-timers --all | grep vaultwarden
```

The managed timer set contains six timers: maintenance, DB backup, full backup, health, DNS update, and firewall update.

On a production host that is ready to run scheduled jobs, repair/activate the current repository runtime with:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

A plain non-interactive `systemd install` defaults to install/enable without starting timers immediately. That is appropriate for recovery/manual-inspection hosts, not the normal repair for "timers are not running" on an intended production host.

After `git pull`, remember that systemd jobs still execute `/opt/vaultwarden-scripts` until the installer copies the current repository code.

---

## Storage / block volume problems

Symptoms:

- restore preflight refuses to proceed;
- storage verification reports missing mount/sentinel;
- data appears under boot storage unexpectedly;
- attached-volume host writes to the wrong state path.

Diagnosis:

```bash
sudo ./restore.sh inspect --remote
utilities/env-edit.sh status
sudo utilities/setup-storage.sh verify
findmnt
lsblk -f
```

For attached-volume mode, confirm:

- `DATA_VOLUME_DEVICE` is the intended device identity;
- `DATA_VOLUME_MOUNT` is the expected mount;
- `PROJECT_STATE_DIR` matches the data mount;
- the mount is active;
- `.vw-data-volume` belongs to the intended VaultWarden data volume.

Do not fix an ambiguity by manually touching/removing the sentinel or hand-editing `/etc/vaultwarden/vaultwarden.env`.

For existing project data that must move between storage layouts, use:

```bash
sudo utilities/setup-storage.sh migrate run
```

See [VOLUME-MIGRATION.md](VOLUME-MIGRATION.md).

---

## `setup-system.sh` rejects the host

The supported normal production host is exactly:

```text
Ubuntu 24.04 LTS Noble
amd64 or arm64
```

Check:

```bash
cat /etc/os-release
dpkg --print-architecture
```

The setup preflight fails when:

- `ID` is not `ubuntu`;
- `VERSION_ID` is not `24.04`;
- the Ubuntu codename is missing, inconsistent, or not `noble`;
- architecture is not `amd64` or `arm64`.

Do not patch the detected codename to `noble` or force an amd64 download on an unknown architecture. Use a supported host.

---

## `yq` is installed but schema/setup commands fail

The project requires Mike Farah `yq` v4 syntax. Ubuntu/Python `yq` is a different tool.

Check:

```bash
yq --version
```

Use the repository setup path to install/validate the required implementation:

```bash
sudo ./utilities/setup-system.sh
```

Do not change schema expressions to accommodate the wrong `yq` implementation.

---

## Production smoke test reports `SKIP`

A smoke-test skip is **not** production ready.

The current smoke test returns zero only when there are no failed and no skipped checks.

Run it directly:

```bash
sudo ./utilities/smoke-test.sh
```

Then fix the exact unavailable check. Common directions:

```bash
utilities/env-edit.sh status
sudo ./setup.sh systemd validate
sudo make key-health
sudo ./backup.sh verify
sudo systemctl status crowdsec
```

Do not edit the smoke test to turn an unavailable required subsystem into `PASS` or a successful `SKIP` just to clear the readiness gate.

---

## Diagnostic bundle and issue reporting

Collect a bounded diagnostic snapshot:

```bash
sudo make diagnose > vaultwarden-diagnose.txt 2>&1
sudo ./maintenance.sh health >> vaultwarden-diagnose.txt 2>&1 || true
sudo ./setup.sh systemd validate >> vaultwarden-diagnose.txt 2>&1 || true
sudo make operations >> vaultwarden-diagnose.txt 2>&1 || true
```

Before sharing, review the file and remove private material.

Never include:

- Age private key contents;
- recovery-kit plaintext;
- SOPS decrypted values;
- SMTP/API/Cloudflare tokens;
- backup emergency passphrases;
- plaintext password-manager exports.

When reporting a repository defect, include the exact branch/commit, failing command, exit code, concise relevant logs, and whether the failure occurred on a real Noble amd64/arm64 host or only in a mocked/local environment.
