# Deployment Guide — VaultWarden-OCI

This guide reflects the current deployment flow for the repository as it exists today: template-driven setup, encrypted secret bootstrap, scripted startup and health validation, Cloudflare-aware networking, and post-deployment automation.

For quick bootstrap, see the [README](../README.md). For day-to-day management after install, see [OPERATIONS.md](OPERATIONS.md).

---

## Prerequisites

| Requirement | Details |
| :-- | :-- |
| Server | Ubuntu 24.04 LTS or Oracle Linux 8/9 on a public VM |
| Baseline resources | Small-team deployment; size the VM for your user count, storage growth, and backup needs |
| Domain | A hostname you control for the vault |
| Cloudflare | Required for the documented DNS, TLS, and edge-protection workflow |
| SMTP relay | Optional but strongly recommended for operational notifications |

Oracle Cloud Infrastructure A1 Flex remains a common fit for lightweight personal or small-team use, but size the instance for your actual operating profile instead of treating one shape as universal.

---

## Phase 0 — OCI network access

OCI blocks inbound traffic at the network layer unless your Security List or Network Security Group allows it.

Before running setup:

1. Open TCP `80` and `443` to either `0.0.0.0/0` during bootstrap or the current Cloudflare IPv4 ranges.
2. Open TCP `22` to your management IP or your preferred SSH source range.

This must be done before first startup so Caddy can complete certificate provisioning.

Cloudflare IPv4 ranges change over time, so always verify the current list from Cloudflare before hard-coding rules.

---

## Phase 1 — Cloudflare DNS staging

Set the vault DNS record to **DNS Only (Grey Cloud)** before first start.

That allows certificate issuance and first-boot validation to complete without Cloudflare proxy behavior complicating the bootstrap path. After the deployment is healthy, switch the record to **Proxied (Orange Cloud)** and use **Full (Strict)** SSL/TLS mode.

---

## Phase 2 — Clone the repository and run setup

```bash
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh

sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto
```

`setup.sh` is the supported installation entry point. It prepares the host, installs required dependencies, and generates the live deployment files from the repository templates.

After setup completes, log out and back in so your shell picks up Docker group membership.

```bash
exit
# SSH back in, then:
cd VaultWarden-OCI
```

### Auto vs interactive bootstrap

- `--auto` is the fastest path and is intended for mostly non-interactive setup.
- `--use-latest` is optional and should only be added if you intentionally want latest image tags instead of the pinned/default behavior in the generated configuration.
- Running `setup.sh` without `--auto` gives you the staged interactive path for environment review and secret entry.

---

## Phase 3 — Review `.env` and finish secrets

### Review environment values first

Edit `.env` before completing the external-credential workflow.

```bash
nano .env
```

At minimum, confirm or set:

- `DOMAIN`
- `DOMAIN_NAME`
- `ADMIN_EMAIL`
- `CLOUDFLARE_ZONE_ID`
- `SMTP_HOST`
- `SMTP_PORT`
- `SMTP_USERNAME`
- `RCLONE_REMOTE_NAME` if offsite backups are used

Use [CONFIGURATION.md](CONFIGURATION.md) for the full variable reference.

### Secret setup for `--auto` installs

`--auto` can generate local credentials and passphrases, but external service credentials still need to be provided manually.

Rotate or set the required external secrets:

```bash
./edit-secrets.sh --rotate caddy_cloudflare_dns_token
./edit-secrets.sh --rotate fail2ban_cloudflare_firewall_token
./edit-secrets.sh --rotate smtp_password
```

Optional push-notification credentials:

```bash
./edit-secrets.sh --rotate push_installation_id
./edit-secrets.sh --rotate push_installation_key
```

### Secret setup for interactive installs

If you did not use `--auto`, finish bootstrap after `.env` review with:

```bash
./setup-secrets.sh
```

That path is preferred over ad-hoc manual editing when you want the repository’s guided secret collection workflow.

---

## Phase 4 — Start and validate the stack

```bash
./startup.sh
make start

./health.sh
make health
```

The deployed stack is built around four main services:

| Service | Purpose |
| :-- | :-- |
| `vaultwarden` | Main password-manager application |
| `caddy` | Reverse proxy, HTTPS termination, and security headers |
| `fail2ban` | Abuse detection and edge-ban automation |
| `postfix` | Containerized SMTP relay |

Do not switch Cloudflare back to proxied mode until startup and health validation succeed.

---

## Phase 5 — Post-deployment tasks

Once the vault is healthy, complete the operational hardening steps:

```bash
sudo ./cron-setup.sh --install
./edit-secrets.sh --export-recovery-kit
./create-breakglass-admin.sh
./backup.sh --type db
./backup.sh --type emergency
./maintenance.sh --test-email --verbose
```

Recommended first-run checks:

- Access the main vault URL and confirm normal login flow.
- Confirm admin access works as expected.
- Test email notifications.
- Verify backups can be created successfully.
- Confirm the break-glass admin path is documented and recoverable.

At this point, switch Cloudflare to **Proxied (Orange Cloud)** and set SSL/TLS mode to **Full (Strict)**.

---

## Applying configuration changes later

The repository is still template-driven after day one. When you change configuration, update the templates and regenerate the live files.

```bash
nano docker-compose.yml.example
nano docker-compose.override.yml.example
nano .env.example

sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com
./startup.sh --force
./health.sh
```

Treat `.example` files as the source of truth and generated files as deployment artifacts.

---

## Troubleshooting deployment

### Caddy or HTTPS bootstrap fails

- Confirm the DNS record is still **DNS Only (Grey Cloud)**.
- Confirm OCI networking allows port `80` and `443` to reach the instance.
- Re-run `./health.sh` and inspect `docker compose logs caddy`.

### Services will not start

```bash
docker compose config
docker compose logs vaultwarden
docker compose logs caddy
docker compose logs fail2ban
docker compose logs postfix
./startup.sh --force
```

### Secrets or decryption problems

```bash
ls -l secrets/keys/age-key.txt
./edit-secrets.sh --test
./setup-secrets.sh
```

The Age key should remain readable only by the correct user and must be preserved for recovery.

### Email issues

```bash
./maintenance.sh --test-email --verbose
docker compose logs postfix
grep SMTP .env
```

### Need to regenerate after fixes

```bash
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com
./startup.sh --force
./health.sh
```

---

## Platform notes

### OCI-specific behavior

- The project is designed with OCI deployment and recovery in mind.
- Break-glass administration is especially relevant for OCI serial-console recovery scenarios.
- Dynamic public IP handling is covered by the project’s DNS update workflow.

### Other providers

The project can still be used outside OCI, but you need equivalent inbound firewall rules and the same Cloudflare DNS/TLS assumptions if you follow this deployment guide.
