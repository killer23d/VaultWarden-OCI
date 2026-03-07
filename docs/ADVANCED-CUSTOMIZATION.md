# Advanced Customization — VaultWarden-OCI

This guide covers the supported ways to customize the deployment without fighting the repository’s current operating model.

The project is still built around **template-driven generation** and **scripted operations**. Treat generated files as deployment artifacts, and treat repository templates plus encrypted secrets as the source of truth.

Related docs: [CONFIGURATION.md](CONFIGURATION.md) · [DEPLOYMENT.md](DEPLOYMENT.md) · [OPERATIONS.md](OPERATIONS.md) · [SCRIPTS.md](SCRIPTS.md)

---

## Customization model

The safe pattern for nearly all changes is:

1. Edit the relevant template or encrypted secret.
2. Regenerate or reapply with the project scripts.
3. Restart with `startup.sh`.
4. Validate with `health.sh`.

Use this flow for image versions, resource limits, environment variables, service behavior, and runtime integrations.

---

## Source of truth

These templates are the canonical configuration inputs:

| Template | Generated file |
| :-- | :-- |
| `.env.example` | `.env` |
| `docker-compose.yml.example` | `docker-compose.yml` |
| `docker-compose.override.yml.example` | `docker-compose.override.yml` |

Preferred apply flow:

```bash
nano .env.example
nano docker-compose.yml.example
nano docker-compose.override.yml.example

sudo ./setup.sh --force --domain vault.example.com --email admin@example.com
./startup.sh --force
./health.sh
```

Do not rely on one-off edits to generated files unless you are intentionally making a short-lived local change and understand that re-running setup can overwrite it.

---

## Version strategy

The repository supports both pinned-image and latest-image workflows.

### Pinned/default behavior

The normal production path is to keep explicit image versions in `.env` and use `./update.sh` for controlled upgrades.

Typical workflow:

```bash
nano .env
./backup.sh --type emergency
./update.sh
./health.sh
```

### Latest-image behavior

If you want a more aggressive update posture, use `setup.sh --use-latest` during setup generation or otherwise configure the environment so generated Compose files track latest-tag behavior.

That approach is better for testing than for conservative production use, because update outcomes will be less predictable over time.

---

## Environment customization

Most feature toggles and integration settings should be handled through `.env.example` and then applied by regenerating `.env`.

Common categories to customize:

- Domain and identity settings.
- SMTP and notification behavior.
- Backup retention and rclone remote naming.
- Version pins.
- Resource limits and operational thresholds.
- Cloudflare-related identifiers.

Use [CONFIGURATION.md](CONFIGURATION.md) as the field-level reference when adding or changing values.

---

## Secrets customization

Secrets are not meant to be maintained as plaintext files.

Use the project’s secret tooling instead of editing decrypted runtime material manually:

```bash
./edit-secrets.sh
./edit-secrets.sh --test
./edit-secrets.sh --rotate caddy_cloudflare_dns_token
./edit-secrets.sh --rotate fail2ban_cloudflare_firewall_token
./edit-secrets.sh --rotate smtp_password
```

After secret changes:

```bash
./startup.sh --force
./health.sh
```

If you are doing an interactive bootstrap rather than incremental rotation, use `./setup-secrets.sh` after reviewing `.env`.

---

## Compose customization

`docker-compose.yml.example` is the right place for most service-level tuning.

Typical advanced changes include:

- Resource limits and reservations.
- Volume mappings.
- Service environment wiring.
- Restart policies.
- Capability and security options.
- Additional labels or container arguments.

Validate before applying:

```bash
docker compose -f docker-compose.yml.example config
```

Then regenerate and restart through the normal flow.

### Override file usage

`docker-compose.override.yml.example` exists for supplemental or environment-specific Compose customizations.

Use it when you want to layer behavior without making the base template harder to read, especially for provider-specific adjustments, extra mounts, or local-only service changes.

---

## Caddy and edge behavior

If you need to change web behavior, review both the Caddy-related template content and the Cloudflare assumptions used by the deployment.

Common advanced customizations include:

- Additional security headers.
- Request-size behavior.
- Reverse-proxy tuning.
- Access logging adjustments.
- Cloudflare-aware TLS and DNS settings.

When changing edge behavior:

1. Keep bootstrap DNS on grey cloud until you confirm issuance still works.
2. Re-run startup.
3. Validate with `health.sh`.
4. Inspect Caddy logs if anything regresses.

---

## Fail2ban and ban policy

The repository is built around Fail2ban integration that pushes enforcement to Cloudflare rather than relying on host firewall blocking for proxied web traffic.

Advanced adjustments may include:

- Jail thresholds and timing.
- Filter behavior.
- Cloudflare token scope changes.
- Logging or action tuning.

After Fail2ban-related customization:

```bash
docker compose exec fail2ban fail2ban-client status
docker compose logs fail2ban
./health.sh --comprehensive
```

---

## Backup policy tuning

Backup behavior is customizable and should be aligned to your recovery objectives.

Areas you may tune:

- Retention defaults in `.env`.
- Whether rclone offsite sync is used.
- Which backup type you run before risky changes.
- Whether weekly jobs use full verification.
- Where recovery material is stored outside the server.

Useful examples:

```bash
./backup.sh --type full --keep 30
./backup.sh --type full --full-verification
./backup.sh --type db --rclone --email
./edit-secrets.sh --export-recovery-kit
```

Use [BACKUP-RESTORE.md](BACKUP-RESTORE.md) for the recovery-side implications of these choices.

---

## Cron and automation tuning

The repository installs scheduled operations through `cron-setup.sh` rather than expecting manual crontab editing.

Preferred workflow:

```bash
sudo ./cron-setup.sh --install
sudo ./cron-setup.sh --list
sudo ./cron-setup.sh --validate
```

If you need to change timing or policy, keep the change aligned with the project’s locking model and reboot behavior for `/run/vaultwarden-locks/`.

If your environment reboots regularly, configure tmpfiles recreation so flock-protected jobs keep working automatically:

```bash
echo 'd /run/vaultwarden-locks 0700 root root -' | sudo tee /etc/tmpfiles.d/vaultwarden-locks.conf
sudo systemd-tmpfiles --create
```

---

## Resource tuning

Small-team defaults are intentionally conservative, but you can adjust them if your usage pattern changes.

Good reasons to tune resource settings include:

- Larger attachment usage.
- Higher login volume.
- Heavier logging or longer retention.
- More aggressive maintenance and verification jobs.
- Constrained OCI instance sizes.

After resource changes, use:

```bash
docker stats --no-stream
./health.sh --comprehensive
```

Tune based on observed usage, not on guesswork.

---

## Safe change workflow

Use this checklist for any advanced customization:

- Create a backup first, preferably `./backup.sh --type emergency` before high-risk changes.
- Edit templates or encrypted secrets, not random generated artifacts.
- Regenerate with `setup.sh --force` when template-backed files change.
- Restart with `startup.sh --force`.
- Validate with `health.sh`, and use `--comprehensive` for larger changes.
- Review container logs if behavior changed at the edge, mail, or security layers.

This keeps customizations compatible with the current repository design instead of drifting into an undocumented snowflake deployment.
