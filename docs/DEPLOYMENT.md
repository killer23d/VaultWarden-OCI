# Deployment Guide — VaultWarden-OCI

This guide walks through a complete deployment from a fresh Ubuntu host to a running vault. OCI-specific steps are optional and called out separately. For a condensed version see the [README quickstart](../README.md).

Related docs: [CONFIGURATION.md](CONFIGURATION.md) · [SECURITY.md](SECURITY.md) · [OPERATIONS.md](OPERATIONS.md) · [MIGRATION.md](MIGRATION.md)

---

## ✅ Prerequisites

| Requirement | Details |
| :-- | :-- |
| **Server** | Ubuntu 24.04 LTS on a VM, cloud instance, or physical host |
| **CPU architecture** | `amd64` and `arm64` are the primary supported Ubuntu architectures; SOPS automatic binary install also supports Debian `armhf` |
| **Resources** | 1 vCPU, 6 GB RAM, 50 GB storage recommended |
| **Domain** | A domain you control with DNS on Cloudflare |
| **Cloudflare account** | Free tier is sufficient |
| **SMTP / API access** | Any SMTP relay or transactional email API (MailerSend, SendGrid, etc.) — optional but strongly recommended |

---

## 📌 Phase 0 — Ingress and Network Access

> **⚠️ CRITICAL:** Your provider firewall, security group, router, or upstream ACL must allow required traffic before the host firewall can help. UFW rules installed by this project cannot receive packets that are dropped before they reach Ubuntu.
>
> Note: In Cloudflare DNS-01 mode, Caddy does not require inbound HTTP for certificate issuance, but port 443 is still required to serve the vault. In direct `acme_http` mode, port 80 must reach Caddy for HTTP-01 validation.

Open these paths before setup:

| Rule | Source CIDR | Protocol | Port |
| :-- | :-- | :-- | :-- |
| HTTPS | `0.0.0.0/0` or Cloudflare IP ranges | TCP | 443 |
| HTTP | `0.0.0.0/0` or Cloudflare IP ranges | TCP | 80 |
| SSH | `0.0.0.0/0` or your IP | TCP | 22 |

Cloudflare IPv4 ranges (verify at <https://www.cloudflare.com/ips-v4>):
```
173.245.48.0/20   103.21.244.0/22   103.22.200.0/22   103.31.4.0/22
141.101.64.0/18   108.162.192.0/18  190.93.240.0/20   188.114.96.0/20
197.234.240.0/22  198.41.128.0/17   162.158.0.0/15    104.16.0.0/13
104.24.0.0/14     172.64.0.0/13     131.0.72.0/22
```

### Optional OCI Security List Notes

On OCI, open these rules under **Compute → Instances → Primary VNIC → Subnet → Default Security List**. OCI does not support comma-separated CIDRs, so add one Cloudflare range per rule if you restrict ingress to Cloudflare.

---

## ☁️ Phase 1 — TLS and DNS Mode

Default mode is `TLS_PROVIDER=cloudflare`. In your Cloudflare dashboard, set your DNS record to **DNS Only (Grey Cloud)** before running setup. This ensures clean DNS propagation during initial TLS provisioning. Caddy uses the **DNS-01 challenge** via your Cloudflare API token and does not require inbound HTTP from Let's Encrypt. Enable the orange proxy cloud after the stack is healthy.

Direct mode is `TLS_PROVIDER=acme_http`. Use it only when the DNS record points directly at the host and inbound TCP `80` reaches Caddy during certificate issuance.

---

## 🛠️ Phase 2 — Server Setup

> **💡 Migrating from an existing VaultWarden deployment?** Follow [MIGRATION.md](MIGRATION.md) instead — it covers database import, attachment transfer, and compatibility differences before you run setup.

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Set timezone
sudo timedatectl set-timezone UTC

# Clone repo
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh
```

### Optional Dedicated Data Volume

Attach or expose the target block storage through your provider, VM manager, or physical host before running setup. Then identify the device from Ubuntu:

```bash
lsblk -o NAME,PATH,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
findmnt /
sudo blkid /dev/disk/by-id/your-volume || true
sudo wipefs --no-act --all /dev/disk/by-id/your-volume
```

Use a stable `/dev/disk/by-id/...` path when available. Do not assume `/dev/sdb`, `/dev/vdb`, or an OCI-specific path. Confirm the selected device is not the OS disk before continuing.

For an existing ext4/xfs filesystem that should be adopted, pass the device to setup and confirm the prompt:

```bash
sudo ./setup.sh install \
  --domain vault.yourdomain.com \
  --email admin@yourdomain.com \
  --auto \
  --data-device /dev/disk/by-id/your-volume \
  --data-mount /mnt/vw-data
```

> **⚠️ Formatting destroys existing data.** For a blank device that setup should format as ext4, set the explicit safeguard flag only after verifying the device identity:

```bash
sudo DATA_VOLUME_FORCE_FORMAT=true ./setup.sh install \
  --domain vault.yourdomain.com \
  --email admin@yourdomain.com \
  --auto \
  --data-device /dev/disk/by-id/your-volume \
  --data-mount /mnt/vw-data
```

---

## ⚙️ Phase 3 — Run Setup

```bash
# Generates docker-compose.yml and .env from templates;
# installs Docker, Age, SOPS, UFW, rclone
sudo ./setup.sh install --domain vault.yourdomain.com --email admin@yourdomain.com --auto
```

`setup.sh install --auto` will:
- Install Docker, Age, SOPS, UFW, rclone (versions from top of `setup.sh`, auto-resolved by default)
- Generate `docker-compose.yml` and `.env` from templates
- Configure UFW
- Add your user to the `docker` group

> **⚠️ Re-login required.** `setup.sh` adds your user to the `docker` group. You must start a fresh SSH session for group membership to take effect before running any Docker or `make` commands.

```bash
exit
# SSH back in, then:
cd VaultWarden-OCI
```

---

## 🔐 Phase 4 — Configure Secrets & Environment

### Cloudflare API Tokens

Create two tokens at <https://dash.cloudflare.com/profile/api-tokens>:

| Token | Permissions | Used by |
| :-- | :-- | :-- |
| **DNS token** | Zone:DNS:Edit + Zone:Zone:Read | Caddy (TLS DNS-01 challenge) |
| **Firewall token** | Zone:Firewall Services:Edit | CrowdSec cloudflare-bouncer (edge banning) |

### Secrets

> **💡 If you ran `setup.sh install --auto`:** `admin_token` and `admin_basic_auth_hash` were already generated by `setup.sh secrets --auto`. Run `./utilities/secrets-view.sh` to confirm them. You still need to set `caddy_cloudflare_dns_token` and the Cloudflare firewall token — those cannot be auto-generated.

```bash
./utilities/secrets-rotate.sh caddy_cloudflare_dns_token
./utilities/secrets-rotate.sh cf_worker_bouncer_token
```

Set at minimum:
- `admin_basic_auth_hash` — auto-generated by `setup.sh secrets --auto`; to regenerate manually:
  ```bash
  ./utilities/secrets-rotate.sh admin_basic_auth_hash
  ```
- `caddy_cloudflare_dns_token`
- `cf_worker_bouncer_token` — used by CrowdSec cloudflare-bouncer (host service)
- Email API token — name matches `email_api_token` (e.g. `email_api_token`)
- `smtp_password` (SMTP relay fallback, if used)

### Environment (.env)

```bash
nano .env
```

Key variables to set:

```bash
DOMAIN=https://vault.yourdomain.com     # WITH https://
ADMIN_EMAIL=admin@yourdomain.com
CLOUDFLARE_ZONE_ID=your_zone_id_here
EMAIL_PROVIDER=mailersend               # mailersend | sendgrid | mailgun | postmark | resend
SMTP_HOST=smtp.yourmailprovider.com     # SMTP fallback host
SMTP_USERNAME=your-relay-account
RCLONE_REMOTE_NAME=your_rclone_remote   # if using offsite backups
```

> **⚠️ Literal values required.** `.env` values are read literally by the stack. The `VW_SMTP_*` block must be real values, not references to other variables.

> **⚠️ Push notifications and `internal: true`.** The `vaultwarden` network is marked `internal: true` by default, blocking outbound internet access from that container. If you set `PUSH_ENABLED=true`, you must remove `internal: true` from the network in `docker-compose.yml` or route push traffic through an outbound proxy. Leaving both enabled causes silent push failures on every sync cycle.

See [CONFIGURATION.md](CONFIGURATION.md) for the full variable reference.

---

## 🚀 Phase 5 — Start & Verify

```bash
./startup.sh        # start all containers
# or: make start

./maintenance.sh health         # verify everything is healthy
# or: make health
```

### Container Stack

| Container | Role | Memory Limit |
| :-- | :-- | :-- |
| **vaultwarden** | Password manager app | 512 MB |
| **caddy** | TLS + reverse proxy | 512 MB |
| **postfix** | SMTP sidecar for VaultWarden and SMTP fallback | 256 MB |

> **CrowdSec note.** CrowdSec runs as a host systemd service (not a Docker container). It reads Vaultwarden, Caddy, and SSH logs and bans attackers via the Cloudflare API and iptables. After starting the stack, verify with: `sudo cscli metrics` and `sudo cscli alerts list`.

Once healthy, switch Cloudflare to **Proxied (Orange Cloud)** and set SSL/TLS to **Full (Strict)**.

---

## 🔄 Phase 6 — Post-Deployment Tasks

```bash
# Install automated backups, health checks, maintenance, and DNS/firewall updates
sudo ./setup.sh systemd install

# Create break-glass emergency admin for serial-console or local recovery
sudo utilities/setup-secrets.sh breakglass create
# or: make breakglass-create

# Create initial backups
./backup.sh run db
./backup.sh run emergency
# or: make backup / make backup-emergency

# Export and store the recovery kit (Age key + secrets) offline
./utilities/secrets-export-recovery-kit.sh

# Test email delivery
./maintenance.sh test-email --verbose
# or: make test-email
```

> **Note:** `cron-setup.sh` has been removed from the repository. Use `setup.sh systemd install` to install all scheduled jobs. If you have legacy cron jobs from a prior installation, remove them to avoid duplicate runs.

**🎉 Vault is live at `https://vault.yourdomain.com`**

---

## 📋 Post-Deployment Checklist

**Immediately:**
- ✅ Access web vault and create your admin account
- ✅ Log in to `/admin` with the bcrypt credentials you set
- ✅ Test email notifications: `make test-email`
- ✅ Test break-glass admin via serial console, local console, or OCI Console Connection if applicable
- ✅ Create and test a backup: `make backup-emergency`
- ✅ Validate systemd timer installation: `sudo ./setup.sh systemd validate`
- ✅ Confirm timers are running: `sudo ./setup.sh systemd status`
- ✅ Store the recovery kit offline: `./utilities/secrets-export-recovery-kit.sh`

**First week:**
- ✅ Invite team members
- ✅ Configure rclone for offsite backups and test sync:
  ```bash
  # rclone is installed by setup.sh install --auto
  # If not already installed:
  curl https://rclone.tech/install.sh | sudo bash

  # Configure a remote (interactive wizard — supports S3, B2, Google Drive, etc.)
  rclone config

  # Set the remote name in .env
  # RCLONE_REMOTE_NAME=your_remote_name

  # Test with a dry-run backup sync
  ./backup.sh run db --rclone

  # Verify files appeared on the remote
  rclone ls your_remote_name:vaultwarden_backups/
  ```
  See [BACKUP-RESTORE.md](BACKUP-RESTORE.md#️-offsite-storage-rclone) for the full offsite storage reference, including supported remote types and systemd timer integration.
- ✅ Test `./restore.sh interactive --dry-run`
- ✅ Review `sudo cscli alerts list --since 24h` for blocking activity
- ✅ If push notifications enabled, verify `PUSH_ENABLED` and `internal: true` settings are compatible

**Ongoing:**
- ✅ Weekly: review `make health` output
- ✅ Monthly: `./maintenance.sh run --comprehensive` for cleanup, DB vacuum, DNS update
- ✅ Quarterly: test break-glass admin; run full recovery drill

---

## 🔧 Applying Configuration Changes

```bash
# Edit the template (source of truth)
nano docker-compose.yml.example   # container / service changes
nano .env.example                  # new environment variables

# Regenerate and apply
# ⚠️ --force regenerates the Age key, orphaning all existing encrypted backups.
# To re-apply config changes without key rotation, omit --force.
sudo ./setup.sh install --domain vault.yourdomain.com --email admin@yourdomain.com --force
./startup.sh --force
# or: make restart
```

To change a backup or maintenance **schedule**, edit the systemd timer directly:

```bash
sudo systemctl edit vaultwarden-db-backup.timer
# Override OnCalendar= in the drop-in file
sudo systemctl daemon-reload
sudo systemctl restart vaultwarden-db-backup.timer
```

---

## 🛠️ Troubleshooting Deployment

**Service won't start:**

```bash
./maintenance.sh health
docker compose logs vaultwarden
docker compose config
```

**TLS certificate not provisioning:**
- Confirm Cloudflare record is set to **DNS Only (Grey Cloud)**
- Confirm `caddy_cloudflare_dns_token` has `Zone:DNS:Edit` + `Zone:Zone:Read` permissions — Caddy uses the **DNS-01 challenge** and does not require inbound HTTP access from Let's Encrypt

**Email not working:**

```bash
./maintenance.sh test-email --verbose
grep -E 'EMAIL_MODE|EMAIL_PROVIDER|SMTP_HOST' .env
./utilities/secrets-edit.sh   # verify the API token key for EMAIL_PROVIDER is set
```

**CrowdSec not detecting attacks:**
- Confirm `crowdsec/acquis.yaml` log paths match your actual log file locations
- Verify with: `sudo cscli bouncers list` and `sudo systemctl status crowdsec`
- Check the Cloudflare firewall token is valid: `sudo cscli decisions list`

**Push notifications not working (silent failures):**

```bash
grep PUSH_ENABLED .env
grep 'internal:' docker-compose.yml
docker compose logs vaultwarden | grep -i push
# If PUSH_ENABLED=true and internal:true are both set, remove internal:true
```

**Secrets decryption failure:**

```bash
ls -l secrets/keys/age-key.txt   # must be mode 600
./utilities/secrets-edit.sh
```

**Re-run setup after fixing issues:**

```bash
sudo ./setup.sh install --domain vault.yourdomain.com --email admin@yourdomain.com --force
./startup.sh --force
```

**Systemd timers not running:**

```bash
sudo ./setup.sh systemd status              # list all VaultWarden timers
sudo ./setup.sh systemd validate            # check for split-brain / missing files
journalctl -u vaultwarden-db-backup.service -n 50   # last 50 lines for backup service
sudo systemctl status vaultwarden-health.timer      # check a specific timer
```

---

## 🌍 Platform Notes

### Generic Ubuntu Hosts
- Core setup, startup, backup, restore, maintenance, secrets, and uninstall workflows do not require OCI metadata, OCI CLI, or OCI APIs.
- Provider-side tasks such as attaching a disk, opening a security group, or assigning a public IP must be completed with that platform's tooling before the Ubuntu commands in this guide.
- For dedicated storage, prefer stable `/dev/disk/by-id/...` paths when available and verify the selected block device with `lsblk`, `blkid`, `wipefs --no-act`, and `findmnt`.

### Oracle Cloud Infrastructure (OCI)
- `setup.sh` auto-detects Oracle Linux and sets `SSH_LOG_PATH=/var/log/secure`
- Break-glass admin is designed for OCI serial console recovery
- Dynamic IP is handled automatically via Cloudflare DNS updates (`./maintenance.sh update-dns`), run hourly by `vaultwarden-dns-update.timer`
- OCI A1 Flex 1 OCPU / 6 GB RAM qualifies for Always Free tier

### Other Cloud Providers (AWS, GCP, Azure, Hetzner)
- `SSH_LOG_PATH` is auto-detected (`/var/log/auth.log` on Debian/Ubuntu)
- All other steps are identical
- Adjust Security Group / Firewall rules to match the OCI Security List instructions above

---

> **Next step →** [Operations](OPERATIONS.md)

## Resilient deployment artifacts

Use Ubuntu 24.04 LTS where available; Ubuntu 22.04 or later is supported. Setup creates persistent configuration at `${PROJECT_STATE_DIR}/config/install.env`, a recovery manifest at `${PROJECT_STATE_DIR}/config/dr-manifest.env`, encrypted secrets at `${PROJECT_STATE_DIR}/secrets/secrets.yaml`, and a rendered recovery card at `${PROJECT_STATE_DIR}/config/recovery-card.md`.

During secrets setup, provide the offline recovery Age public key when prompted. Runtime Docker secret files are transient and are written only to `/run/vaultwarden-oci/secrets/`.
