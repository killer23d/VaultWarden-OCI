# Deployment Guide — VaultWarden-OCI

This guide follows the supported golden path: Ubuntu host, Cloudflare DNS/proxy/WAF, Caddy DNS-01 with Cloudflare, Vaultwarden, Postfix sidecar mail, CrowdSec with Cloudflare edge enforcement, SOPS+Age secrets, rclone/offsite backup, and systemd automation. For the project boundary, see [PROJECT-BOUNDARY.md](PROJECT-BOUNDARY.md).

Related docs: [CONFIGURATION.md](CONFIGURATION.md) · [SECURITY.md](SECURITY.md) · [OPERATIONS.md](OPERATIONS.md) · [VOLUME-MIGRATION.md](VOLUME-MIGRATION.md)

## Prerequisites

| Requirement | Details |
| :-- | :-- |
| Server | Ubuntu 24.04 LTS VM, cloud instance, or physical host |
| Resources | 1 vCPU, 6 GB RAM, 50 GB storage recommended |
| Domain | A domain you control in Cloudflare |
| Cloudflare | DNS, proxy, WAF, API tokens, and account/zone IDs |
| Email relay | SMTP relay credentials for the Postfix-first default path |
| Backup target | rclone remote if enabling offsite backups immediately |

## Phase 1 — Prepare Cloudflare and provider firewall

1. Create the DNS record, for example `vault.yourdomain.com`, in Cloudflare.
2. Keep it **DNS Only (Grey Cloud)** for first certificate provisioning.
3. Allow inbound TCP `443` through the provider firewall/security group/router.
4. Allow inbound TCP `80` only if you deliberately use the advanced direct `acme_http` fallback or need redirects.
5. Restrict SSH (`22`) to your administrator IP range where practical.
6. After validation, switch the record to **Proxied (Orange Cloud)** and set SSL/TLS to **Full (Strict)**.

> OCI note: OCI Security Lists drop packets before Ubuntu sees them. Add rules under **Compute → Instances → Primary VNIC → Subnet → Default Security List**. OCI requires one CIDR per rule.

## Phase 2 — Clone and run setup

```bash
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh
sudo ./setup.sh install --domain vault.yourdomain.com --email admin@yourdomain.com --auto
```

`setup.sh install --auto` installs dependencies, generates `.env` and `docker-compose.yml`, configures the host firewall, creates generated local secrets, and adds your user to the `docker` group while preserving pinned versions from `.env.example`.

Re-login before using Docker:

```bash
exit
# SSH back in, then:
cd VaultWarden-OCI
```

## Phase 3 — Configure required secrets and non-secrets

Edit `.env` for non-secret values:

```bash
nano .env
```

Set or verify:

```bash
DOMAIN=https://vault.yourdomain.com
ADMIN_EMAIL=admin@yourdomain.com
EMAIL_MODE=smtp
EMAIL_PROVIDER=
SMTP_HOST=smtp.yourmailprovider.com
SMTP_PORT=587
SMTP_USERNAME=your-relay-account
SMTP_FROM=noreply@yourdomain.com
ALLOWED_SENDER_DOMAINS=yourdomain.com
ADMIN_ALLOW_CIDR=your-admin-cidr
RCLONE_REMOTE_NAME=your_rclone_remote   # if offsite backup is enabled now
RCLONE_CONFIG=/etc/rclone/rclone.conf   # recommended for systemd backups
```

Rotate required external credentials into SOPS secrets:

```bash
sudo ./edit-secrets.sh rotate caddy_cloudflare_dns_token
sudo ./edit-secrets.sh rotate cf_worker_bouncer_token
sudo ./edit-secrets.sh rotate cloudflare_zone_id
sudo ./edit-secrets.sh rotate cf_account_id
sudo ./edit-secrets.sh rotate smtp_password
```

`cloudflare_zone_id` is a SOPS secret key in the current implementation. Do not add a new `CLOUDFLARE_ZONE_ID` setting to `.env` for normal deployments.

## Phase 4 — Start and verify

```bash
./startup.sh
./maintenance.sh health
sudo ./maintenance.sh test-email --verbose
```

Once healthy, switch Cloudflare to **Proxied (Orange Cloud)** and confirm SSL/TLS is **Full (Strict)**.

The runtime stack remains:

| Component | Role |
| :-- | :-- |
| Vaultwarden container | Password manager application |
| Caddy container | TLS, reverse proxy, security headers, Cloudflare DNS-01 |
| Postfix container | Reliable outbound SMTP sidecar |
| CrowdSec host service | Host/app threat detection with Cloudflare edge enforcement |

## Phase 5 — Install automation and recovery kit

```bash
sudo ./setup.sh systemd install
sudo ./utilities/secrets-export-recovery-kit.sh
```

Systemd automation covers health self-healing, backups, maintenance, DNS refresh, firewall refresh, locking, and failure notifications. See [ADVANCED-CUSTOMIZATION.md](ADVANCED-CUSTOMIZATION.md) for the full timer schedule and overrides.

Store the recovery kit in a password manager and offline backup location.

## Advanced and optional paths

These features are supported where implemented, but should not be part of a first install unless needed:

- **Direct TLS (`TLS_PROVIDER=acme_http`)**: fallback for non-Cloudflare DNS-01 environments; requires inbound TCP `80` for HTTP-01.
- **Dedicated data volume**: useful for snapshots and host replacement. Read [VOLUME-MIGRATION.md](VOLUME-MIGRATION.md) before adopting or moving data.
- **Push notifications**: optional Bitwarden push relay integration; requires additional secrets and outbound networking.
- **Provider-specific email APIs**: optional alternative to Postfix-first SMTP. See [EMAIL.md](EMAIL.md).
- **Disaster-recovery rehearsals**: recommended after production is stable. See [DISASTER-RECOVERY.md](DISASTER-RECOVERY.md).
- **Deep CrowdSec Worker/KV tuning**: see [CROWDSEC.md](CROWDSEC.md) after the normal bouncer path is working.
