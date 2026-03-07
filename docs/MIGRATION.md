# Migration Guide — VaultWarden-OCI

This guide describes the current recommended migration approach: build a fresh target deployment using the repository’s script-driven workflow, then migrate data and configuration into that target in a controlled way.

Related docs: [DEPLOYMENT.md](DEPLOYMENT.md) · [BACKUP-RESTORE.md](BACKUP-RESTORE.md) · [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

---

## Migration strategy

For most situations, the safest pattern is **fresh target, then cut over**.

Instead of trying to transform an old installation in place, deploy a clean VaultWarden-OCI environment first, validate it, then import or restore the source data.

This reduces hidden drift and keeps the final environment aligned with the repository’s current templates, secrets workflow, and operational tooling.

---

## Common migration sources

This repository can be used as the target for migrations from:

- A standalone VaultWarden or Bitwarden-compatible host.
- Another Docker Compose VaultWarden deployment.
- A manually maintained OCI setup with drifted configuration.
- An older revision of this repository that no longer matches the current docs or script model.

The exact source details vary, but the target pattern stays the same.

---

## Pre-migration checklist

Before moving anything:

- Inventory the current source environment.
- Confirm where the source database and attachments live.
- Identify SMTP, Cloudflare, push, and admin-related credentials.
- Export or preserve any existing recovery material.
- Schedule a cutover window if the source is actively used.
- Decide whether you are restoring from archives or copying live source data.

Always create a fresh source backup before touching the migration target.

---

## Build the target first

Provision the new environment using the current repository workflow.

```bash
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh

sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto
```

Then start a fresh shell session, review `.env`, complete external secrets, and bring up the stack:

```bash
./startup.sh
./health.sh
```

Do not begin data migration until the fresh target is healthy.

---

## Migration methods

### Method 1 — Restore from a compatible backup

If you already have a suitable backup archive for the source environment, restore into the new target.

Typical flow:

```bash
./restore.sh --file /path/to/backup.age --force
./health.sh
```

This is the cleanest option when the backup format matches the recovery path you want.

### Method 2 — Source data copy with fresh target config

If you are moving from another VaultWarden deployment, keep the new target’s current templates and operational tooling, but move the source data into place during the migration window.

In practice, this usually means preserving:

- The VaultWarden database.
- Attachments and relevant application data.
- Any required mail or integration credentials.

Avoid blindly copying unrelated old operational scripts or stale generated config files into the new repo.

---

## Secrets and credentials

Do not migrate secret handling by copying random plaintext files around.

The target project expects secret material to be maintained through `setup-secrets.sh` and `edit-secrets.sh`.

Recommended approach:

1. Re-enter or rotate external credentials into the new target.
2. Export a fresh recovery kit once the target is complete.
3. Preserve the Age key and recovery material outside the new server.

Useful commands:

```bash
./setup-secrets.sh
./edit-secrets.sh
./edit-secrets.sh --export-recovery-kit
```

---

## Cutover sequence

A practical cutover flow is:

1. Freeze or stop writes on the source environment.
2. Take one final source backup.
3. Apply the final restore or data sync to the target.
4. Start or restart the target stack.
5. Run health checks.
6. Point DNS and Cloudflare to the target.
7. Validate login, admin access, mail, and backup behavior.

Example validation commands:

```bash
./startup.sh --force
./health.sh --comprehensive
./maintenance.sh --test-email --verbose
./backup.sh --type db
```

---

## OCI and Cloudflare considerations

If the target is on OCI, confirm networking before cutover.

- Open TCP `80`, `443`, and `22` appropriately.
- Keep Cloudflare DNS in **DNS Only** mode until HTTPS bootstrap and health checks succeed.
- Switch to **Proxied** mode and **Full (Strict)** only after validation is complete.

If the target public IP differs from the source, confirm DNS propagation and then verify the project’s DNS update workflow is behaving as expected.

---

## After migration

Once the target is live:

- Install scheduled automation with `cron-setup.sh`.
- Export and store fresh recovery material.
- Create a post-migration backup.
- Verify the break-glass admin path.
- Review logs for login, mail, and Fail2ban anomalies.

Recommended commands:

```bash
sudo ./cron-setup.sh --install
./edit-secrets.sh --export-recovery-kit
./create-breakglass-admin.sh
./backup.sh --type emergency
./health.sh --comprehensive
```

---

## What not to carry over

Avoid bringing these into the new deployment without a deliberate reason:

- Stale generated `.env` or Compose files from a different repo revision.
- Old helper scripts that no longer exist in the current project.
- Previous cron entries that bypass `cron-setup.sh`.
- Plaintext credential files outside the Age + SOPS workflow.
- Firewall assumptions that conflict with the current OCI + Cloudflare model.

Migrating old drift is one of the easiest ways to end up with a deployment that technically runs but no longer matches the documented operating model.

---

## Troubleshooting migration issues

### Target starts but login or data looks wrong

Validate what you actually restored and check that the correct data path was migrated.

```bash
docker compose logs vaultwarden
./health.sh --comprehensive
```

### Mail works on source but not target

Re-check `.env` SMTP values and the encrypted `smtp_password`, then run:

```bash
./maintenance.sh --test-email --verbose
docker compose logs postfix
```

### Cloudflare or HTTPS issues after cutover

Keep DNS grey-clouded until Caddy is healthy, then review:

```bash
docker compose logs caddy
./health.sh
```

### Recovery material mismatch

If a restore archive cannot be decrypted, verify that the correct Age key is present before assuming the backup is unusable.

```bash
./edit-secrets.sh --test
ls -la secrets/keys/age-key.txt
```

A good migration finishes only after backup, restore, DNS, mail, and health validation all work in the new environment.
