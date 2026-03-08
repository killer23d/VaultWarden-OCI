# Deployment Guide — VaultWarden-OCI

This guide walks through a complete deployment from a fresh OCI instance to a running vault. For a condensed version see the [README quickstart](../README.md).

Related docs: [CONFIGURATION.md](CONFIGURATION.md) · [SECURITY.md](SECURITY.md) · [OPERATIONS.md](OPERATIONS.md)

---

## ✅ Prerequisites

| Requirement | Details |
| :-- | :-- |
| **Server** | Ubuntu 24.04 LTS or Oracle Linux 8/9 (OCI A1 Flex recommended) |
| **Resources** | 1 vCPU, 6 GB RAM, 50 GB storage (OCI Always Free tier) |
| **Domain** | A domain you control with DNS on Cloudflare |
| **Cloudflare account** | Free tier is sufficient |
| **SMTP access** | Any SMTP relay (Gmail, SendGrid, etc.) — optional but recommended |

---

## 📌 Phase 0 — OCI Security List (Do This First)

> **⚠️ CRITICAL:** OCI blocks all inbound traffic by default at the hypervisor level. You must open ports 80 and 443 **before** running setup — Caddy cannot provision its TLS certificate otherwise.

1. OCI Console → **Compute → Instances → your instance**
2. Under "Primary VNIC" click **Subnet → Default Security List**
3. Add **Ingress Rules** (one per row):

| Rule | Source CIDR | Protocol | Port |
| :-- | :-- | :-- | :-- |
| Web (open) | `0.0.0.0/0` | TCP | 80, 443 |
| Web (Cloudflare IPs only — recommended) | one per CF range | TCP | 80, 443 |
| SSH | `0.0.0.0/0` or your IP | TCP | 22 |

Cloudflare IPv4 ranges (verify at <https://www.cloudflare.com/ips-v4>):
```
173.245.48.0/20   103.21.244.0/22   103.22.200.0/22   103.31.4.0/22
141.101.64.0/18   108.162.192.0/18  190.93.240.0/20   188.114.96.0/20
197.234.240.0/22  198.41.128.0/17   162.158.0.0/15    104.16.0.0/13
104.24.0.0/14     172.64.0.0/13     131.0.72.0/22
```

---

## ☁️ Phase 1 — Cloudflare DNS Staging

In your Cloudflare dashboard, set your DNS record to **DNS Only (Grey Cloud)** before running setup. Caddy needs to reach Let's Encrypt directly to complete the HTTP-01 TLS challenge on first boot. Enable the orange proxy cloud after the stack is healthy.

---

## 🛠️ Phase 2 — Server Setup

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

---

## ⚙️ Phase 3 — Run Setup

```bash
# Generates docker-compose.yml and .env from templates;
# installs Docker, Age, SOPS, UFW, rclone
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto
```

`setup.sh --auto` will:
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
| **Firewall token** | Zone:Firewall Services:Edit | Fail2Ban (edge banning) |

### Secrets

```bash
./edit-secrets.sh
```

Set at minimum:
- `admin_basic_auth_hash` — generate with: `docker run --rm -it ghcr.io/caddybuilds/caddy-cloudflare:latest caddy hash-password`
- `caddy_cloudflare_dns_token`
- `fail2ban_cloudflare_firewall_token`
- `smtp_password` (if using email)

### Environment (.env)

```bash
nano .env
```

Key variables to set:

```bash
DOMAIN=https://vault.yourdomain.com     # WITH https://
DOMAIN_NAME=vault.yourdomain.com        # bare hostname, no protocol
ADMIN_EMAIL=admin@yourdomain.com
CLOUDFLARE_ZONE_ID=your_zone_id_here
SMTP_HOST=smtp.yourmailprovider.com
SMTP_USERNAME=your-relay-account
RCLONE_REMOTE_NAME=your_rclone_remote   # if using offsite backups
```

See [CONFIGURATION.md](CONFIGURATION.md) for the full variable reference.

---

## 🚀 Phase 5 — Start & Verify

```bash
./startup.sh        # start all containers
# or: make start

./health.sh         # verify everything is healthy
# or: make health
```

### Container Stack

| Container | Role | Memory Limit |
| :-- | :-- | :-- |
| **vaultwarden** | Password manager app | 2 GB |
| **caddy** | TLS + reverse proxy | 1 GB |
| **fail2ban** | Brute-force detection | 512 MB |
| **postfix** | Containerised SMTP relay ([bokysan/docker-postfix](https://github.com/bokysan/docker-postfix)) | 128 MB |

Once healthy, switch Cloudflare to **Proxied (Orange Cloud)** and set SSL/TLS to **Full (Strict)**.

---

## 🔄 Phase 6 — Post-Deployment Tasks

```bash
# Install automated backups, updates, and maintenance crons
sudo ./cron-setup.sh --install

# Create break-glass emergency admin for OCI serial console
./create-breakglass-admin.sh
# or: make breakglass-create

# Create initial backups
./backup.sh --type db
./backup.sh --type emergency
# or: make backup / make backup-emergency

# Test email delivery
./test-email-simple.sh --verbose
# or: make test-email
```

**🎉 Vault is live at `https://vault.yourdomain.com`**

---

## 📋 Post-Deployment Checklist

**Immediately:**
- ✅ Access web vault and create your admin account
- ✅ Log in to `/admin` with the bcrypt credentials you set
- ✅ Test email notifications: `make test-email`
- ✅ Test break-glass admin via OCI Console Connection
- ✅ Create and test a backup: `make backup-emergency`

**First week:**
- ✅ Invite team members
- ✅ Configure rclone for offsite backups; test sync
- ✅ Test `./restore.sh --dry-run`
- ✅ Review `docker compose logs fail2ban` for blocking activity

**Ongoing:**
- ✅ Weekly: review `make health` output
- ✅ Monthly: `./maintenance.sh` for cleanup, DB vacuum, DNS update
- ✅ Quarterly: test break-glass admin; run full recovery drill

---

## 🔧 Applying Configuration Changes

```bash
# Edit the template (source of truth)
nano docker-compose.yml.example   # container / service changes
nano .env.example                  # new environment variables

# Regenerate and apply
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com
./startup.sh --force
# or: make restart
```

---

## 🛠️ Troubleshooting Deployment

**Service won't start:**

```bash
./health.sh
docker compose logs vaultwarden
docker compose config
```

**TLS certificate not provisioning:**
- Confirm Cloudflare record is set to **DNS Only (Grey Cloud)**
- Confirm OCI Security List allows port 80 from `0.0.0.0/0` (Let's Encrypt needs to reach your server)

**Email not working:**

```bash
docker compose logs postfix
./test-email-simple.sh --verbose
grep SMTP .env
```

**Secrets decryption failure:**

```bash
ls -l secrets/keys/age-key.txt   # must be mode 600
./edit-secrets.sh
```

**Re-run setup after fixing issues:**

```bash
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com
./startup.sh --force
```

---

## 🌍 Platform Notes

### Oracle Cloud Infrastructure (OCI)
- `setup.sh` auto-detects Oracle Linux and sets `SSH_LOG_PATH=/var/log/secure`
- Break-glass admin is designed for OCI serial console recovery
- Dynamic IP is handled automatically via Cloudflare DNS updates (`./maintenance.sh --update-dns`)
- OCI A1 Flex 1 OCPU / 6 GB RAM qualifies for Always Free tier

### Other Cloud Providers (AWS, GCP, Azure, Hetzner)
- `SSH_LOG_PATH` is auto-detected (`/var/log/auth.log` on Debian/Ubuntu)
- All other steps are identical
- Adjust Security Group / Firewall rules to match the OCI Security List instructions above
