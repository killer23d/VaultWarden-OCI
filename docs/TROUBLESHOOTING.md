# Troubleshooting Guide — VaultWarden-OCI

This guide covers the current troubleshooting paths for a deployment built around `setup.sh`, `startup.sh`, `health.sh`, `maintenance.sh`, `backup.sh`, `restore.sh`, and `cron-setup.sh`.

For first-time setup flow, see [DEPLOYMENT.md](DEPLOYMENT.md). For day-to-day tasks, see [OPERATIONS.md](OPERATIONS.md).

---

## Troubleshooting approach

Use this order when something breaks:

1. Confirm the intended workflow was followed.
2. Run `./health.sh` or `./health.sh --comprehensive`.
3. Review service-specific logs.
4. Reapply template-backed configuration if drift is suspected.
5. Restore from backup if validation shows the environment is no longer trustworthy.

Many issues come from configuration drift, incomplete secret setup, or environment assumptions that no longer match the current repository workflow.

---

## First checks

Start with these commands:

```bash
./health.sh
./health.sh --comprehensive
docker compose ps
docker stats --no-stream
```

If the environment recently changed, also check whether the issue started after setup regeneration, secret rotation, an update, or a reboot.

---

## Startup problems

### Services will not start

```bash
docker compose config
docker compose logs vaultwarden
docker compose logs caddy
docker compose logs fail2ban
docker compose logs postfix
./startup.sh --force
```

Common causes:

- Incomplete or invalid `.env` values.
- Missing or undecryptable secrets.
- Template drift between generated files and intended repo state.
- DNS or Cloudflare state that no longer matches bootstrap expectations.

### Secrets do not decrypt

```bash
./edit-secrets.sh --test
ls -la secrets/keys/age-key.txt
```

If the Age key is missing or broken, recover it first before continuing with broader troubleshooting.

---

## HTTPS and Cloudflare problems

### TLS will not provision

Check these first:

- OCI networking allows TCP `80` and `443`.
- The DNS record is still **DNS Only** during bootstrap.
- The requested hostname matches the configured domain values.

Useful commands:

```bash
docker compose logs caddy
./health.sh
```

### Site works locally but not externally

Validate Cloudflare mode, DNS record correctness, and OCI ingress rules.

If you recently cut over DNS, also account for propagation delay before assuming the service itself is broken.

---

## Email problems

Mail troubleshooting should use the current maintenance entry point, not stale legacy helpers.

```bash
./maintenance.sh --test-email --verbose
docker compose ps postfix
docker compose logs postfix
grep SMTP .env
./edit-secrets.sh --test
```

Common causes:

- Wrong SMTP host, port, or security mode.
- Missing or incorrect `smtp_password`.
- Sender-domain rules that do not match the configured mail identity.

---

## Fail2ban and security-response issues

If bans do not seem to be happening, verify both the service state and the Cloudflare-related secret material.

```bash
docker compose exec fail2ban fail2ban-client status
docker compose exec fail2ban fail2ban-client status vaultwarden-auth
docker compose logs fail2ban
./edit-secrets.sh --test
```

If the deployment is proxied through Cloudflare, remember that web response behavior is built around edge enforcement rather than only local host firewall changes.

---

## Backup and restore issues

### Backup failures

```bash
df -h
./backup.sh --type db
./backup.sh --type full --full-verification
ls -la secrets/keys/age-key.txt
```

Common causes:

- Low disk space.
- Missing or invalid Age key.
- rclone remote misconfiguration.
- Permission issues around backup paths.

### Restore uncertainty

Prefer the interactive restore flow when you are unsure which archive to trust:

```bash
./restore.sh
```

If you need a targeted restore:

```bash
./restore.sh --latest --type db
./restore.sh --latest --type full --force
```

After any restore, run:

```bash
./health.sh --comprehensive
```

---

## Cron and reboot issues

### Jobs stopped working after reboot

The project uses `/run/vaultwarden-locks/` for flock-protected jobs, and `/run` is cleared at reboot.

Validate or recreate the lock setup:

```bash
sudo ./cron-setup.sh --validate
sudo ./cron-setup.sh --install
```

For automatic recreation:

```bash
echo 'd /run/vaultwarden-locks 0700 root root -' | sudo tee /etc/tmpfiles.d/vaultwarden-locks.conf
sudo systemd-tmpfiles --create
```

### Cron drift or stale automation

```bash
sudo ./cron-setup.sh --list
sudo ./cron-setup.sh --validate
```

Use `cron-setup.sh` rather than manual cron edits so the scheduled model matches the current repository state.

---

## Update problems

### Service unhealthy after update

Use the project’s normal update and recovery model.

```bash
./update.sh
./health.sh --comprehensive
```

If a rollback is needed manually:

```bash
./restore.sh --latest --type full --force
./health.sh
```

### Unexpected behavior after config or version change

Return to the template-first path:

```bash
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com
./startup.sh --force
./health.sh
```

This is often faster and safer than trying to debug undocumented drift in generated files.

---

## High resource usage

```bash
docker stats --no-stream
du -sh ${PROJECT_STATE_DIR}/logs/*
./maintenance.sh --comprehensive
```

Investigate:

- Log growth.
- Backup accumulation.
- Container memory pressure.
- Database maintenance needs.

If the database appears bloated or fragmented, consider the deeper maintenance path during a quiet window:

```bash
sudo ./maintenance.sh --db-maint
```

---

## When to restore instead of debug

Consider restoring or rebuilding when:

- Multiple services are failing after risky changes.
- Secrets, templates, and runtime files have drifted badly.
- A recent known-good backup exists.
- Recreating the environment cleanly will be faster than uncertain manual repair.

Useful recovery commands:

```bash
./backup.sh --list
./restore.sh
./restore.sh --file /path/to/backup.age --force
```

A disciplined restore is often safer than continuing to patch a deployment you no longer trust.
