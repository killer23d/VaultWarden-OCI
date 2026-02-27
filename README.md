# VaultWarden-OCI

**Production-Ready VaultWarden for Small Teams**

A streamlined, secure, and operationally excellent VaultWarden deployment optimized for teams of 10 or fewer users. Designed for Oracle Cloud Infrastructure (OCI) with dynamic IPs, focused on ease of maintenance and robust security.

## 🎯 What Makes This Different

This is a **template-based, hardened deployment** designed specifically for small teams who want:

- **Set-and-forget reliability** with template-based maintenance and automated operations
- **Cloudflare-only blocking** for web traffic — iptables removed from proxied services
- **Robust security** with comprehensive Cloudflare integration and encrypted secrets (Age + SOPS)
- **Simple operations** with a Makefile, 14 lifecycle scripts, and 5 shared libraries
- **Emergency recovery** with break-glass admin access and automatic rollback on failed updates

## 🏗️ Architecture

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
| **UFW** | Host firewall; Cloudflare-IP restriction at OCI VCN level recommended |
| **Age + SOPS** | Encrypted secrets management |
| **14 Scripts** | Full lifecycle: setup, start, backup, restore, update, health, maintenance … |
| **Makefile** | Convenient shortcuts for all common operations |

## ⚠️ Before You Begin — OCI Security List

> **Do this first, before cloning the repo.** Oracle Cloud blocks all incoming traffic at the virtual-network level by default. Your instance will be unreachable until you open the correct ports.

1. Go to **Compute → Instances** → click your instance.
2. Click the **Subnet** under "Primary VNIC" → **Default Security List**.
3. Add **Ingress Rules**: TCP ports `80` and `443` — either from Cloudflare IP ranges only (recommended), or `0.0.0.0/0` as a simpler open rule.
4. Add one SSH rule: Source `0.0.0.0/0` (or your management IP), Protocol TCP, Port `22`.

> Full Cloudflare IP range list, hardened VCN setup, and UFW rules → [docs/SECURITY.md](docs/SECURITY.md)

## ⚡ Quick Start

### 1 — DNS: Grey Cloud First

Set your Cloudflare DNS record to **DNS Only (Grey Cloud)**. Caddy must reach Let's Encrypt directly to provision TLS on first boot. Switch to **Proxied (Orange Cloud)** after Step 5.

### 2 — Clone & Run Setup

```bash
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto
```

### 3 — Re-login (Apply Docker Group)

`setup.sh` adds your user to the `docker` group. Start a fresh SSH session before continuing:

```bash
exit  # then re-SSH into the server
cd VaultWarden-OCI
```

### 4 — Configure Secrets & Environment

```bash
./edit-secrets.sh   # admin hash, Cloudflare API tokens, SMTP password
nano .env           # CLOUDFLARE_ZONE_ID, SMTP relay settings, etc.
```

> Full variable and secrets reference → [docs/CONFIGURATION.md](docs/CONFIGURATION.md)

### 5 — Start Services

```bash
./startup.sh
# or: make start
```

### 6 — Switch to Proxied & Finish

1. In Cloudflare, switch DNS to **Proxied (Orange Cloud)** and set SSL/TLS to **Full (Strict)**.
2. Enable automation: `sudo ./cron-setup.sh --install`
3. Create the break-glass admin: `./create-breakglass-admin.sh`
4. Verify everything is healthy: `./health.sh` (or `make health`)

**🎉 Your VaultWarden is live at `https://vault.yourdomain.com`**

## 📚 Documentation

All technical details live in the `docs/` directory:

| Document | What's Inside |
| :-- | :-- |
| [DEPLOYMENT.md](docs/DEPLOYMENT.md) | Detailed step-by-step deployment guide |
| [CONFIGURATION.md](docs/CONFIGURATION.md) | Full `.env`, secrets, and template reference |
| [SECURITY.md](docs/SECURITY.md) | Security hardening, Cloudflare setup, UFW rules, OCI Security Lists |
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
