# Deployment Guide — VaultWarden-OCI

This guide follows the supported golden path: Ubuntu 24.04 LTS Noble on amd64 or arm64, Cloudflare DNS/proxy/WAF, Caddy DNS-01 with Cloudflare, Vaultwarden, Postfix sidecar mail, CrowdSec with Cloudflare Workers enforcement, SOPS + Age secrets, rclone offsite backup support, and systemd automation.

For the project boundary, see [PROJECT-BOUNDARY.md](PROJECT-BOUNDARY.md).

Related docs: [CONFIGURATION.md](CONFIGURATION.md) · [SECURITY.md](SECURITY.md) · [OPERATIONS.md](OPERATIONS.md) · [VOLUME-MIGRATION.md](VOLUME-MIGRATION.md)

## Prerequisites

| Requirement | Details |
| :-- | :-- |
| Host | Ubuntu 24.04 LTS Noble on amd64 or arm64 |
| Resources | A small production VM/host with enough memory and disk for Docker, CrowdSec, logs, and retained backups |
| Domain | A domain you control in Cloudflare |
| Cloudflare | DNS, proxy, WAF, required API credentials, account ID, and zone ID |
| Email relay | SMTP relay credentials for the Postfix-first default path |
| Backup target | rclone remote when enabling offsite backups |

The host may be in OCI, AWS, Azure, Google Cloud, another VM provider, private virtualization, or on physical hardware. The runtime is provider-neutral. Provider-specific network controls remain an operator prerequisite.

## Phase 1 — Prepare Cloudflare and provider ingress

1. Create the DNS record, for example `vault.yourdomain.com`, in Cloudflare.
2. Keep it **DNS Only** for initial origin certificate provisioning.
3. Allow inbound TCP `443` through the provider firewall, security group, or network firewall.
4. Allow inbound TCP `80` only when your documented TLS/redirect path requires it.
5. Restrict SSH to administrator IP ranges where practical.
6. After origin validation, switch the record to **Proxied** and set Cloudflare SSL/TLS to **Full (Strict)**.

The project configures the supported Ubuntu host firewall. It does not configure your provider's upstream firewall/security group for you.

## Phase 2 — Clone and run setup

```bash
git clone --branch main https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh utilities/*.sh

sudo ./setup.sh install \
  --domain vault.yourdomain.com \
  --email admin@yourdomain.com \
  --auto
```

`setup.sh install --auto` validates Ubuntu 24.04 Noble and the amd64/arm64 architecture boundary, installs the repository-owned dependencies, generates the deployment files, bootstraps encrypted SOPS/Age state, prepares storage, and configures the host firewall.

The normal production lifecycle is root-operated. A Docker-group re-login is not a required deployment phase for the supported operator path.

## Phase 3 — Configure non-secret values and external credentials

Edit non-secret configuration through the environment workflow:

```bash
sudo make edit-env
```

Set or verify the values appropriate for the deployment, including:

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
RCLONE_REMOTE_NAME=your_rclone_remote
RCLONE_CONFIG=/etc/vaultwarden/rclone.conf
```

Then rotate external credentials into the canonical SOPS secrets store:

```bash
sudo ./edit-secrets.sh rotate caddy_cloudflare_dns_token
sudo ./edit-secrets.sh rotate cf_worker_bouncer_token
sudo ./edit-secrets.sh rotate cloudflare_zone_id
sudo ./edit-secrets.sh rotate cf_account_id
sudo ./edit-secrets.sh rotate smtp_password
```

Configure CrowdSec enforcement after those Cloudflare secrets are available:

```bash
sudo ./utilities/setup-crowdsec.sh
```

With `CLOUDFLARE_PROXY_ENABLED=true`, the daemon-backed Cloudflare Workers bouncer is part of normal production readiness. Proxy-disabled and autonomous modes remain explicit advanced alternatives; smoke/health do not label them as the normal production-ready path.

`cloudflare_zone_id` is a SOPS secret. Do not create a second `CLOUDFLARE_ZONE_ID` `.env` source for the normal deployment path.

For the exact secret inventory and apply behavior, see [SECRETS-SCHEMA.md](SECRETS-SCHEMA.md).

## Phase 4 — Start and verify the live stack

```bash
sudo make up
sudo make health
sudo ./maintenance.sh test-email --verbose
```

Once origin health is good, switch Cloudflare to **Proxied** and confirm SSL/TLS **Full (Strict)**.

The normal runtime stack is:

| Component | Role |
| :-- | :-- |
| Vaultwarden container | Password manager application |
| Caddy container | TLS, reverse proxy, security headers, Cloudflare DNS-01 |
| Postfix container | Outbound SMTP relay sidecar |
| CrowdSec host service | Threat detection |
| CrowdSec firewall bouncer | Host firewall enforcement of CrowdSec decisions |
| CrowdSec Cloudflare Workers bouncer | Workers KV synchronization for edge enforcement |

## Phase 5 — Configure offsite backup credentials

Create the rclone configuration with the normal rclone tooling:

```bash
rclone config
```

The canonical installed runtime config is:

```text
/etc/vaultwarden/rclone.conf
```

`utilities/setup-systemd.sh install` copies/installs the accepted rclone config for root-operated automation. Re-run systemd installation after changing the source rclone configuration so scheduled backup jobs receive the current installed config.

Verify backup creation before enabling scheduled work:

```bash
sudo ./backup.sh run db
sudo ./backup.sh verify
```

## Phase 6 — Activate and validate automation

Only after storage, secrets, Cloudflare/DNS, rclone, and the live stack are ready:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

The managed timer set covers:

- health checks;
- database backups;
- full backups;
- maintenance;
- DNS updates;
- Cloudflare firewall CIDR refresh.

Managed services also use failure notification integration.

`systemd validate` detects stale installed scripts, libraries, unit files, environment/key permission failures, rendered startup-unit drift, and unhealthy managed timers.

After updating from `main` with `git pull --ff-only origin main`, repeat:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

Git updates the checkout. The systemd installer activates the managed runtime under `/opt/vaultwarden-scripts`.

## Phase 7 — Export and store recovery material

```bash
sudo ./utilities/secrets-export-recovery-kit.sh
```

Store the recovery kit in a password manager and in a separate offline recovery location. Remove plaintext copies from the server after the kit is secured.

Re-export recovery material after:

- initial production setup;
- operational Age key rotation;
- restore when a new operational Age key is generated;
- a material secret rotation that changes recovery credentials.

Read [BACKUP-RESTORE.md](BACKUP-RESTORE.md), [BOOTSTRAP_KEY_RECOVERY.md](BOOTSTRAP_KEY_RECOVERY.md), and [DISASTER-RECOVERY.md](DISASTER-RECOVERY.md) before treating the host as the only copy of production data.

## Dedicated data volume during first install

A separate block/data volume is optional. The boot-volume default remains supported.

When using a separate volume, provide an explicit stable device path where possible:

```bash
sudo ./setup.sh install \
  --domain vault.yourdomain.com \
  --email admin@yourdomain.com \
  --data-device /dev/disk/by-id/<your-volume> \
  --data-mount /mnt/vw-data
```

Storage code will not silently choose an unknown device. Existing filesystems, blank-device formatting, fstab ownership, mount readiness, and the `.vw-data-volume` sentinel are guarded by the storage workflow.

See [VOLUME-MIGRATION.md](VOLUME-MIGRATION.md) before adopting or moving production data.

## Recovery/manual-inspection hosts

A replacement or recovery host may need the managed runtime installed without starting scheduled backup/maintenance jobs immediately:

```bash
sudo ./setup.sh systemd install --no-enable-now
```

After storage, secrets, rclone, Cloudflare/DNS, firewall state, and Vaultwarden readiness have been inspected:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

Do not call an install-only recovery host production ready merely because the unit files were copied successfully.

## Advanced and optional paths

These features are supported where implemented but should not complicate a first install unless needed:

- **Alternate TLS behavior** — advanced path outside the Cloudflare-first golden path.
- **Dedicated data volume** — storage isolation and replacement-host portability.
- **Push notifications** — optional Bitwarden push integration.
- **Provider-specific email APIs** — advanced operational-alert route; the Postfix SMTP path remains the normal appliance mail path.
- **Disaster-recovery rehearsals** — use the current smoke test and pre-production drill after the normal stack is stable.
- **Deep CrowdSec Worker/KV tuning** — see [CROWDSEC.md](CROWDSEC.md) after the default enforcement path is working.

## Automatic setup credential handoff

<!-- VWOCI-PRR-PATCH-04 -->

Both `sudo ./setup.sh --domain DOMAIN --email EMAIL --auto` and the documented direct command `sudo ./utilities/setup-secrets.sh configure --auto` keep generated credential values out of terminal output. After successful atomic publication, the command displays the root-only handoff path under `/root/vaultwarden-recovery/`, its `root:root` ownership and `0700` directory/`0600` file permissions, and the three included groups: SOPS Age identity, Vaultwarden administrator password, and Caddy administrator password. Automatic configuration fails without a completion summary if the handoff cannot be published. Required UFW and automatic secret-configuration failures also terminate top-level setup before its completion summary. See [Secure credential and recovery handoffs](SECURE-CREDENTIAL-HANDOFFS.md).
