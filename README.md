# VaultWarden-OCI

**Production-ready VaultWarden for OCI and small self-hosted teams**

VaultWarden-OCI is a template-driven, operations-focused deployment for running VaultWarden on Oracle Cloud Infrastructure with Cloudflare, encrypted secret management, automated backups, health checks, and recovery tooling.

## What this project includes

This repository is designed around a few operating principles:

- **Template-first configuration** — live files are generated from `.example` templates.
- **Scripted operations** — deployment, startup, backup, restore, updates, health checks, and maintenance are all handled by dedicated scripts.
- **Encrypted secrets** — Age + SOPS protect credentials and backup material.
- **Cloudflare-aware edge protection** — Caddy, dynamic DNS updates, and Fail2ban/Cloudflare integration are built into the workflow.
- **Recovery-first operations** — backups, rollback paths, and a break-glass admin flow are part of the standard deployment.

## Quick start

### 1. Open OCI networking first

Before you run setup, open inbound TCP ports `80`, `443`, and `22` in the OCI Security List attached to the instance subnet.

For web traffic, you can either:

- Allow `0.0.0.0/0` on ports `80` and `443` during bootstrap, or
- Restrict those ports to the current Cloudflare IPv4 ranges.

This must be in place before first boot so Caddy can complete certificate provisioning.

### 2. Stage Cloudflare DNS as DNS-only

Set the vault DNS record to **DNS Only (Grey Cloud)** before first start. After the stack is healthy and HTTPS is working, switch the record to **Proxied (Orange Cloud)** and use **Full (Strict)** SSL/TLS mode.

### 3. Clone and run setup

```bash
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh

sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto
```

`setup.sh` handles host preparation and generates the live deployment files from the repository templates.

After setup finishes, start a new SSH session so your user picks up Docker group membership.

```bash
exit
# SSH back in, then:
cd VaultWarden-OCI
```

### 4. Configure environment and secrets

Edit `.env` before finishing secret setup. At minimum, confirm the deployment identity and set any external service values you need.

```bash
nano .env
```

Common values to review:

- `DOMAIN`
- `DOMAIN_NAME`
- `ADMIN_EMAIL`
- `CLOUDFLARE_ZONE_ID`
- `SMTP_HOST`
- `SMTP_PORT`
- `SMTP_USERNAME`
- `RCLONE_REMOTE_NAME` if you use offsite backups

For `--auto` installs, locally generated secrets are created for you, but external credentials still need to be filled in explicitly.

```bash
./edit-secrets.sh --rotate caddy_cloudflare_dns_token
./edit-secrets.sh --rotate fail2ban_cloudflare_firewall_token
./edit-secrets.sh --rotate smtp_password

# Optional mobile push support
./edit-secrets.sh --rotate push_installation_id
./edit-secrets.sh --rotate push_installation_key
```

If you ran `setup.sh` without `--auto`, follow the interactive bootstrap flow after editing `.env`:

```bash
./setup-secrets.sh
```

### 5. Start and verify

```bash
./startup.sh
./health.sh
```

The standard stack includes:

| Component | Role |
| :-- | :-- |
| `vaultwarden` | Password manager application |
| `caddy` | TLS termination, reverse proxy, headers, and web edge |
| `fail2ban` | Authentication abuse detection and edge blocking integration |
| `postfix` | Containerized SMTP relay |

When health checks pass, switch Cloudflare back to proxied mode.

### 6. Enable ongoing operations

```bash
sudo ./cron-setup.sh --install
./edit-secrets.sh --export-recovery-kit
./create-breakglass-admin.sh
```

These steps enable scheduled operations, export a recovery bundle for secure offline storage, and create emergency admin access for console recovery scenarios.

## Core scripts

| Script | Purpose |
| :-- | :-- |
| `setup.sh` | Initial host and project bootstrap; generates live config from templates |
| `setup-secrets.sh` | Interactive or automated secret bootstrap |
| `startup.sh` | Start, stop, and restart services |
| `health.sh` | Health validation, optional recovery, and diagnostics |
| `backup.sh` | Encrypted database, full, and emergency backups |
| `restore.sh` | Restore workflows from backup archives |
| `update.sh` | Container and optional system updates with validation |
| `maintenance.sh` | Cleanup, DNS update, database maintenance, and diagnostics |
| `edit-secrets.sh` | Secret rotation, testing, and recovery-kit export |
| `cron-setup.sh` | Install, validate, list, or remove scheduled automation |
| `create-breakglass-admin.sh` | Emergency admin lifecycle for recovery access |

## Operating model

The current project flow is:

1. **Generate** deployment files from templates.
2. **Store** secrets in encrypted form with Age + SOPS.
3. **Start** the stack through `startup.sh`, not ad-hoc Compose commands.
4. **Validate** with `health.sh` after changes.
5. **Protect** with automated backups, scheduled maintenance, and rollback-aware updates.

`update.sh` should be the normal path for image refreshes because it wraps backup, restart, and validation into one documented workflow.

## Templates and source of truth

Do not treat generated files as the long-term source of truth.

The repository keeps these templates as the canonical configuration inputs:

| Template | Generated file |
| :-- | :-- |
| `.env.example` | `.env` |
| `docker-compose.yml.example` | `docker-compose.yml` |
| `docker-compose.override.yml.example` | `docker-compose.override.yml` |

When you change templates, re-run setup and then restart the stack.

## Documentation map

| Document | Purpose |
| :-- | :-- |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | End-to-end deployment workflow from fresh host to healthy service |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Day-to-day operations, updates, maintenance, and scheduled automation |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Environment variables and configuration reference |
| [docs/SECURITY.md](docs/SECURITY.md) | Security model and hardening notes |
| [docs/BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md) | Backup and restore procedures |
| [docs/SCRIPTS.md](docs/SCRIPTS.md) | Script-level behavior and flags |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Diagnostics and common fixes |
| [docs/MIGRATION.md](docs/MIGRATION.md) | Migration guidance |
| [docs/ADVANCED-CUSTOMIZATION.md](docs/ADVANCED-CUSTOMIZATION.md) | Overrides, tuning, and advanced changes |
| [docs/API.md](docs/API.md) | API and integration notes |
| [docs/BOOTSTRAP_KEY_RECOVERY.md](docs/BOOTSTRAP_KEY_RECOVERY.md) | Age key recovery procedures |

## Recommended first-run checklist

- Confirm OCI Security List rules are correct.
- Keep Cloudflare grey-clouded until HTTPS succeeds.
- Review `.env` before secrets are finalized.
- Rotate external credentials with `edit-secrets.sh` or finish bootstrap with `setup-secrets.sh`.
- Run `./startup.sh` and `./health.sh` after any material change.
- Install cron automation and export the recovery kit before considering the deployment complete.

## License

MIT License.
