# VaultWarden-OCI

**Production-Ready VaultWarden for Small Teams**

A streamlined, secure, and operationally excellent VaultWarden deployment optimized for teams of 10 or fewer users. Designed for Oracle Cloud Infrastructure (OCI) with dynamic IPs, this project focuses on essential functionality, ease of maintenance, and robust security for reliable password management.

## 🎯 What Makes This Different

This is a **template-based, hardened deployment** designed specifically for small teams who want:

- **Set-and-forget reliability** with template-based maintenance and automated operations
- **Cloudflare-only blocking** for web traffic — iptables removed from proxied services
- **Robust security** with comprehensive Cloudflare integration and encrypted secrets (Age + SOPS)
- **Simple operations** with a Makefile, 14 lifecycle scripts, and 5 shared libraries
- **Emergency recovery** with break-glass admin access and automatic rollback on failed updates

## 🏗️ Project Components

```
 Cloudflare Edge (Proxy, WAF, DNS)
         ↑ ↓
 Host Firewall (UFW — Ports 80/443 + SSH)
         ↑ ↓
┌─────────────────────────────────────────┐
│        Docker Application Stack         │
│  ┌──────┐  ┌───────────┐  ┌──────────┐ │
│  │Caddy │→ │VaultWarden│  │ Postfix  │ │
│  │(SSL) │  │(App)      │  │ (Email)  │ │
│  └──────┘  └───────────┘  └──────────┘ │
│              ┌──────────┐               │
│              │ fail2ban │               │
│              │ (Edge)   │               │
│              └──────────┘               │
└─────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────┐
│     Management & Recovery Layer         │
│  14 scripts · 5 libraries · Makefile    │
│  Age+SOPS secrets · Break-glass admin   │
│  Auto-rollback · Encrypted backups      │
└─────────────────────────────────────────┘
```

| Component | Role |
| :-- | :-- |
| **Caddy** | Reverse proxy, automatic TLS via Let's Encrypt |
| **VaultWarden** | Bitwarden-compatible password manager (2 GB limit) |
| **Postfix** | Containerised SMTP relay — no host mail dependencies |
| **fail2ban** | Blocks attackers via Cloudflare Edge WAF (not iptables) |
| **UFW** | Host firewall; Cloudflare-IP restriction recommended at OCI VCN level |
| **Age + SOPS** | Encrypted secrets management |
| **14 Scripts** | Full lifecycle: setup, start, backup, restore, update, health, maintenance … |
| **Makefile** | Convenient shortcuts for all common operations |

> For a full breakdown of scripts, libraries, and the Makefile reference see [docs/SCRIPTS.md](docs/SCRIPTS.md) and [docs/OPERATIONS.md](docs/OPERATIONS.md).

## ⚡ Quick Start

### Step 1 — OCI VCN Security List (Do This First)

Oracle Cloud blocks all incoming traffic at the virtual-network level by default. **Configure your Security List before cloning the repo.**

1. Go to **Compute → Instances** → click your instance.
2. Click the **Subnet** under "Primary VNIC" → **Default Security List**.
3. Add **Ingress Rules** for web traffic:

**Option A — Open (simpler):** Add one rule with Source CIDR `0.0.0.0/0`, Protocol TCP, Destination Ports `80,443`.

**Option B — Hardened (recommended):** Add one rule per Cloudflare IPv4 range (OCI does not support comma-separated CIDRs), Protocol TCP, Ports `80,443`. Verify the current list at https://www.cloudflare.com/ips-v4:

```
173.245.48.0/20   103.21.244.0/22   103.22.200.0/22   103.31.4.0/22
141.101.64.0/18   108.162.192.0/18  190.93.240.0/20   188.114.96.0/20
197.234.240.0/22  198.41.128.0/17   162.158.0.0/15    104.16.0.0/13
104.24.0.0/14     172.64.0.0/13     131.0.72.0/22
```

4. Add one SSH rule: Source `0.0.0.0/0` (or your management IP), Protocol TCP, Port `22`.

> **Why not just UFW?** OCI Security Lists drop packets at the hypervisor before they ever reach the VM — a harder control than host-level UFW.

### Step 2 — Cloudflare DNS (Grey Cloud First)

Before running setup, set your Cloudflare DNS record to **DNS Only (Grey Cloud)**. Caddy must reach Let's Encrypt directly to provision its TLS certificate on first boot. You can switch to **Proxied (Orange Cloud)** after Step 7.

### Step 3 — Clone & Run Setup

```bash
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh

# Automated setup (template-based)
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto
```

### Step 4 — Re-login (Apply Docker Group)

`setup.sh` adds your user to the `docker` group. You **must** start a fresh SSH session before running Docker commands:

```bash
exit
# Re-SSH, then:
cd VaultWarden-OCI
```

### Step 5 — Configure Secrets & Environment

```bash
# Set admin_basic_auth_hash, Cloudflare API tokens, SMTP password
./edit-secrets.sh

# Set CLOUDFLARE_ZONE_ID, SMTP relay settings, etc.
nano .env
```

> See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for all secrets and `.env` variables.

### Step 6 — Start Services

```bash
./startup.sh
# or: make start
```

### Step 7 — Switch to Proxied & Finish

1. In Cloudflare, switch your DNS record to **Proxied (Orange Cloud)**.
2. Set SSL/TLS encryption mode to **Full (Strict)**.
3. Enable automation (recommended for set-and-forget operation):
   ```bash
   sudo ./cron-setup.sh --install
   ```
4. Create the break-glass emergency admin:
   ```bash
   ./create-breakglass-admin.sh
   # or: make breakglass-create
   ```
5. Verify everything is healthy:
   ```bash
   ./health.sh
   # or: make health
   ```

**🎉 Your VaultWarden is now operational at `https://vault.yourdomain.com`**

## 📚 Documentation

All technical details live in the `docs/` directory:

| Document | What's Inside |
| :-- | :-- |
| [DEPLOYMENT.md](docs/DEPLOYMENT.md) | Detailed step-by-step deployment guide |
| [CONFIGURATION.md](docs/CONFIGURATION.md) | Full `.env`, secrets, and template reference |
| [SECURITY.md](docs/SECURITY.md) | Security hardening, Cloudflare setup, UFW rules |
| [OPERATIONS.md](docs/OPERATIONS.md) | Day-to-day operations, Makefile reference, cron jobs |
| [SCRIPTS.md](docs/SCRIPTS.md) | All 14 scripts and 5 libraries documented |
| [BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md) | Backup strategy, restore procedures, exit codes |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Common issues, fail2ban, email, update failures |
| [MIGRATION.md](docs/MIGRATION.md) | Migrating from other setups |
| [ADVANCED-CUSTOMIZATION.md](docs/ADVANCED-CUSTOMIZATION.md) | Advanced configuration and customisation |
| [API.md](docs/API.md) | API usage and integration |
| [BOOTSTRAP_KEY_RECOVERY.md](docs/BOOTSTRAP_KEY_RECOVERY.md) | Key recovery procedures |

## 📄 License

MIT License — see LICENSE file for details.
