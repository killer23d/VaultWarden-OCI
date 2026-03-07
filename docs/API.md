# API and Integration Notes — VaultWarden-OCI

This repository does not add a separate custom application API of its own. Instead, it packages and automates several integration surfaces: the VaultWarden web/API service behind Caddy, operational shell scripts, Docker Compose service controls, and Cloudflare-backed automation used by the deployment.

This document explains the current integration model so operators know what is safe to automate and what should remain under script control.

Related docs: [DEPLOYMENT.md](DEPLOYMENT.md) · [OPERATIONS.md](OPERATIONS.md) · [SCRIPTS.md](SCRIPTS.md) · [SECURITY.md](SECURITY.md)

---

## Integration surfaces

The current project exposes or relies on four main surfaces:

| Surface | Purpose | Recommended use |
| :-- | :-- | :-- |
| VaultWarden application endpoints | User-facing vault access and app integrations | Use for normal client and automation flows supported by VaultWarden itself |
| Project shell scripts | Deployment and operations control plane | Use for setup, lifecycle, backup, restore, update, maintenance, and secret handling |
| Docker Compose and container tooling | Service inspection and low-level runtime control | Use for diagnostics and exceptional intervention |
| Cloudflare API integrations | DNS updates and edge ban actions | Let the repository scripts manage this through configured credentials |

---

## VaultWarden application access

The primary externally consumed interface is the VaultWarden service published through Caddy at your configured domain.

Typical consumers include:

- Browser users.
- Official or compatible Bitwarden clients.
- Admins accessing the admin surface through the deployment’s configured protections.

This repository’s job is to deploy and operate that surface reliably; it does not redefine the upstream application API contract.

---

## Project scripts as the operational API

For automation, the most important “API” in this repository is the script layer.

Use these scripts as the supported control surface:

| Script | Use case |
| :-- | :-- |
| `setup.sh` | Generate deployment files and prepare the host |
| `setup-secrets.sh` | Guided secret bootstrap |
| `startup.sh` | Start, stop, restart, and reinitialize services |
| `health.sh` | Validate runtime health and optionally recover unhealthy services |
| `backup.sh` | Create encrypted backups and optional offsite sync |
| `restore.sh` | Restore from selected backup archives |
| `update.sh` | Perform validated updates with rollback-aware workflow |
| `maintenance.sh` | DNS refresh, cleanup, DB maintenance, and email diagnostics |
| `edit-secrets.sh` | Rotate, test, and export secret material |
| `cron-setup.sh` | Install and validate scheduled automation |
| `create-breakglass-admin.sh` | Manage the recovery admin lifecycle |

For most automation tasks, prefer calling one of these scripts over composing a new low-level workflow yourself.

---

## Docker and Compose access

Direct Docker and Compose access is still useful, but it should usually be treated as a diagnostic or emergency interface rather than the first-choice automation path.

Typical examples:

```bash
docker compose ps
docker compose logs vaultwarden --tail=50
docker stats --no-stream
docker compose exec fail2ban fail2ban-client status
```

Use this layer when you need runtime visibility, per-container logs, or one-off troubleshooting detail that the higher-level scripts do not already summarize.

---

## Cloudflare-backed automation

The deployment uses Cloudflare-related credentials for two important integrations:

- DNS record management.
- Fail2ban-driven edge blocking actions.

Manage these via encrypted secrets and the project scripts, not by embedding API calls into ad-hoc local automation.

Common credential operations:

```bash
./edit-secrets.sh --rotate caddy_cloudflare_dns_token
./edit-secrets.sh --rotate fail2ban_cloudflare_firewall_token
./startup.sh --force
./health.sh
```

This keeps Cloudflare automation aligned with the repository’s current security and deployment model.

---

## Email and notification integration

Operational notifications are sent through the containerized Postfix relay used by the deployment.

Validate the mail path with the project tooling:

```bash
./maintenance.sh --test-email
./maintenance.sh --test-email --verbose
docker compose logs postfix
```

SMTP values belong in `.env`, while the SMTP password belongs in encrypted secrets.

---

## Backup and recovery integration

Backups are part of the operational surface and can be integrated into broader workflows through the repository scripts.

Examples:

```bash
./backup.sh --type db
./backup.sh --type full --full-verification
./backup.sh --type db --rclone --email
./restore.sh --latest --type full
```

If external orchestration is added, it should call these commands rather than trying to reimplement encryption, verification, and restore semantics itself.

---

## Safe automation guidance

Use this approach when integrating the project into a larger ops workflow:

1. Treat `.example` files and encrypted secrets as the configuration API.
2. Treat repository scripts as the operational API.
3. Use Docker/Compose only for inspection or exceptional low-level intervention.
4. Re-run `health.sh` after any scripted change.
5. Keep credentials inside the Age + SOPS workflow rather than passing plaintext around.

This will keep your automation compatible with future documentation and repository updates.

---

## What not to build around

Avoid treating these as stable external APIs:

- Temporary decrypted Docker secret files.
- Internal generated file layouts that are recreated by setup.
- Manual one-off container exec workflows for normal lifecycle management.
- Direct hand-written Cloudflare API calls that duplicate existing project behavior.

Those can work in an emergency, but they are the wrong long-term abstraction layer for this repository.
