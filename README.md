# VaultWarden-OCI

**Production-Ready VaultWarden for Small Teams**

A streamlined, secure, and operationally excellent VaultWarden deployment optimised for teams of 10 or fewer users. Designed for Oracle Cloud Infrastructure (OCI) with dynamic IPs, it emphasises template-based configuration, automated operations, and robust multi-layer security.

## 🎯 What Makes This Different

This is a **template-based, hardened deployment** built for small teams who want:

- **Set-and-forget reliability** — automated backups, updates, health checks, and rollback
- **Template-first approach** — all config files maintained as `.example` templates; nothing hardcoded
- **Cloudflare-only web blocking** — iptables removed from proxied services; edge WAF used instead
- **Encrypted secrets** — Age + SOPS for industry-standard secrets management
- **Emergency recovery** — break-glass admin access and automatic rollback on failed updates
- **Simple day-to-day operations** — Makefile shortcuts covering the full lifecycle

---

## ⚡ Quick Start (~15 Minutes)

### Step 0 — Configure OCI Security List (Do This First)

> **⚠️ CRITICAL:** OCI blocks all inbound traffic by default at the hypervisor level. You must open ports 80 and 443 in your VCN Security List **before** cloning — Caddy cannot provision its TLS certificate otherwise.

1. In the OCI Console go to **Compute → Instances → your instance**.
2. Under “Primary VNIC” click your **Subnet → Default Security List**.
3. Add **Ingress Rules** for TCP ports `80` and `443`.

**Option A — Open to all (simplest):**
Set Source CIDR to `0.0.0.0/0`.

**Option B — Restrict to Cloudflare IPs only (recommended):**
Add one rule per CIDR below (OCI does not support comma-separated CIDRs).
Verify the current list at <https://www.cloudflare.com/ips-v4>.

```
173.245.48.0/20   103.21.244.0/22   103.22.200.0/22   103.31.4.0/22
141.101.64.0/18   108.162.192.0/18  190.93.240.0/20   188.114.96.0/20
197.234.240.0/22  198.41.128.0/17   162.158.0.0/15    104.16.0.0/13
104.24.0.0/14     172.64.0.0/13     131.0.72.0/22
```

4. Also add an SSH rule: Source `0.0.0.0/0` (or your IP), Protocol TCP, Port `22`.

> **Why not UFW?** OCI Security Lists drop packets at the hypervisor — before the VM’s network stack — making them a harder control than host-level UFW.

---

### Step 1 — Cloudflare DNS Staging (Grey Cloud First)

In your Cloudflare dashboard set your DNS record to **DNS Only (Grey Cloud)** before running setup. Caddy must reach Let’s Encrypt directly to provision its TLS certificate on first boot. You can enable the orange proxy cloud after the stack is running.

---

### Step 2 — Clone & Run Setup

```bash
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI

# Make top-level scripts executable — do NOT use -R here.
# lib/*.sh are sourced libraries, not standalone executables.
chmod +x *.sh

# Automated setup — installs deps, generates config files, auto-generates
# VaultWarden admin password, Caddy admin password, and backup passphrase.
# External credentials (CF tokens, SMTP, push keys) are left as
# CHANGE_ME placeholders — the post-install summary lists the exact
# ./edit-secrets.sh --rotate commands to fill them in.
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto

# Re-login so your user picks up the docker group
exit
# SSH back in, then:
cd VaultWarden-OCI
```

> **`--auto` vs `--use-latest`:** `--auto` is fully non-interactive and does not change container version pins. Pass `--use-latest` separately if you want all container image tags set to `latest` instead of the pinned versions in `.env`.

---

### Step 3 — Configure Environment & External Credentials

**Edit `.env` first** — `CLOUDFLARE_ZONE_ID` must be set before secrets are configured so that Cloudflare token validation works correctly.

```bash
nano .env
# ► Set: CLOUDFLARE_ZONE_ID, SMTP_HOST, SMTP_PORT, SMTP_USERNAME
# ► Verify: DOMAIN and ADMIN_EMAIL are correct
```

Then supply the external credentials that `--auto` cannot generate for you:

```bash
# Cloudflare tokens (required — Caddy TLS + Fail2ban edge blocking)
./edit-secrets.sh --rotate caddy_cloudflare_dns_token
./edit-secrets.sh --rotate fail2ban_cloudflare_firewall_token

# SMTP password (required if using email notifications)
./edit-secrets.sh --rotate smtp_password

# Push notification keys (optional — mobile app push alerts)
./edit-secrets.sh --rotate push_installation_id
./edit-secrets.sh --rotate push_installation_key
```

**Interactive install (no `--auto`):** `setup.sh` creates the skeleton and displays a next-steps screen. Follow the steps printed on screen — edit `.env` first, then run `./setup-secrets.sh` to be prompted for all credentials at once.

See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for every available variable.

---

### Step 4 — Start & Verify

```bash
./startup.sh          # start all services  (or: make start)
./health.sh           # verify everything is healthy  (or: make health)
```

Once healthy, switch the Cloudflare record to **Proxied (Orange Cloud)** and set SSL/TLS encryption to **Full (Strict)**.

---

### Step 5 — Finish Up (Recommended)

```bash
# Set up automated backups, updates, and maintenance
sudo ./cron-setup.sh --install

# Export a plaintext recovery kit to your password manager
# Run this AFTER all secrets are configured so everything is included
./edit-secrets.sh --export-recovery-kit

# Create emergency admin for OCI serial console recovery
./create-breakglass-admin.sh    # or: make breakglass-create
```

The installed cron schedule:

| Time | Job | Protection |
| :-- | :-- | :-- |
| 2 AM Mon–Sat | Comprehensive maintenance | `flock` — skips + logs if already running |
| 3 AM Sunday | Full backup + verify + rclone + email | Internal lock in `backup.sh` |
| 4 AM daily | DB backup + rclone + email | Internal lock in `backup.sh` |
| Every 30 min | Health check | `flock` — skips + logs if already running |
| Every hour | DNS update | `flock` — skips + logs if already running |
| Saturday 4 AM | Firewall rules update | `flock` — skips + logs if already running |

> **⚠️ After every reboot:** The lock directory `/run/vaultwarden-locks/` lives on a `tmpfs` mount and is wiped on reboot. All four flock-protected jobs will fail to acquire their lock until the directory is recreated. Run `sudo ./cron-setup.sh --install` (idempotent) or `sudo ./cron-setup.sh --validate` to detect and fix this. To avoid manual intervention, add a `systemd-tmpfiles.d` rule:
> ```bash
> echo 'd /run/vaultwarden-locks 0700 root root -' | sudo tee /etc/tmpfiles.d/vaultwarden-locks.conf
> sudo systemd-tmpfiles --create
> ```

**🎉 Your vault is live at `https://vault.yourdomain.com`**

---

## 🏗️ Project Components

### Docker Stack

| Container | Role |
| :-- | :-- |
| **Caddy** | TLS termination, reverse proxy, security headers (1 GB limit) |
| **VaultWarden** | Password manager application (2 GB limit) |
| **Postfix** | Containerised SMTP relay — no host mail dependencies |
| **Fail2ban** | Brute-force detection → Cloudflare edge blocking |

### Scripts

| Script | Purpose |
| :-- | :-- |
| `setup.sh` | One-time system setup: installs deps, generates `.env` and `docker-compose.yml` from templates, creates Age key, SOPS config, and empty secrets structure. In `--auto` mode, also auto-generates passwords/passphrases via `setup-secrets.sh --auto --quiet-summary` after all infra phases complete, then shows a single consolidated summary screen. |
| `setup-secrets.sh` | Initial secrets bootstrap — prompted interactively or via `--auto`. Standalone flow: run **after** editing `.env`. Supports `--quiet-summary` to suppress its completion banner when called from `setup.sh`. |
| `startup.sh` | Start / stop / restart services |
| `health.sh` | Health monitoring with optional auto-recovery |
| `backup.sh` | Encrypted database and full-system backups. Uses host `sqlite3` with the Online Backup API for atomic, WAL-safe DB snapshots — no Docker container required for backup integrity checks. |
| `restore.sh` | Interactive or automated restore. Uses host `sqlite3` for archive integrity verification — no Docker required. |
| `update.sh` | Safe container + system updates with auto-rollback |
| `maintenance.sh` | Cleanup, DNS update, DB maintenance, email test |
| `edit-secrets.sh` | Secure secrets editor (Age + SOPS) — rotate individual fields, list keys, export recovery kit |
| `cron-setup.sh` | Install / remove automation crons. All maintenance tasks (maintenance, health, DNS update, firewall update) are `flock`-protected with skip-logging — overlapping runs are skipped and recorded in the job’s log file rather than silently dropped. |
| `create-breakglass-admin.sh` | Emergency OCI serial console admin |

Full reference: [docs/SCRIPTS.md](docs/SCRIPTS.md)

### Shared Libraries (`lib/`)

| Library | Purpose |
| :-- | :-- |
| `common.sh` | Logging, validation, shared utilities |
| `crypto.sh` | Age / SOPS encryption & decryption |
| `docker.sh` | Docker lifecycle management |
| `security.sh` | Security validation helpers |
| `backup_utils.sh` | Backup-specific shared logic |
| `secrets.sh` | Secrets collection, auto-generation, hashing (Argon2id + bcrypt), Cloudflare token validation, recovery kit generation |
| `simple_key_resilience.sh` | Three-tier Age key protection: health check with auto-permission fix and encrypt/decrypt roundtrip (Tier 1); password-manager-ready plaintext escrow export (Tier 2); printable PDF/HTML paper backup with optional QR code via `qrencode` and `wkhtmltopdf` (Tier 3) |

### Configuration Templates

All live configuration is generated from `.example` templates by `setup.sh`. Edit templates → re-run setup → restart.

| Template | Generates |
| :-- | :-- |
| `docker-compose.yml.example` | `docker-compose.yml` |
| `docker-compose.override.yml.example` | `docker-compose.override.yml` (email decoupling) |
| `.env.example` | `.env` |

---

## 🔒 Security at a Glance

- **Edge WAF** — Cloudflare proxy + Fail2ban pushes bans to Cloudflare API (iptables not used for proxied services)
- **Host firewall** — UFW opens 80/443/22; Cloudflare IP restriction enforced at OCI Security List level
- **Encrypted secrets** — Age + SOPS; no plaintext credentials at rest
- **HTTPS** — Automatic Let’s Encrypt via Caddy with HSTS, CSP, and security headers
- **Container hardening** — Non-root execution, capability restrictions, memory limits
- **Docker-free backup integrity** — `backup.sh` and `restore.sh` use host `sqlite3` (SQLite Online Backup API) for atomic DB snapshots and `PRAGMA integrity_check`; no ephemeral alpine containers with read-write mounts over live vault data
- **Hardened cron temp files** — cron install/remove use `mktemp` with `umask 077`; eliminates PID-predictable `/tmp` symlink attack vector on the root-owned crontab write

Full details: [docs/SECURITY.md](docs/SECURITY.md)

---

## 🔄 Update & Rollback

`update.sh` runs a fully phased cycle: pre-update health check → backup → pull → restart → post-update health check. If the post-update health check fails, it **automatically rolls back** via `restore.sh --latest`. See [docs/OPERATIONS.md](docs/OPERATIONS.md) for the full phase diagram.

---

## 💾 Backup & Recovery

Three backup tiers with encrypted output (Age key required to restore):

| Tier | Schedule | Default retention |
| :-- | :-- | :-- |
| **Database snapshot** | Daily 4 AM | 14 days |
| **Full system archive** | Sunday 3 AM | 14 days |
| **On-demand emergency** | Manual | 14 days |

Retention is configurable: pass `--keep N` to `backup.sh`, or edit `KEEP_DAYS` in `.env`. Example — keep 30 days of weekly full backups:
```bash
sudo ./backup.sh --type full --keep 30
```

> **⚠️ Keep a separate copy of `secrets/keys/age-key.txt`** — it is required to decrypt all backups on a new server. Run `./edit-secrets.sh --export-recovery-kit` after setup to store it in your password manager alongside all other credentials.

Full procedures: [docs/BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md)

---

## 🚀 Makefile Quick Reference

```bash
make start / stop / restart / status   # Service lifecycle
make health                            # Health check
make backup / backup-full / restore    # Backup operations
make update / update-system            # Updates
make maintenance                       # Full maintenance run
make breakglass-create / status        # Emergency admin
make test-email / test-secrets         # Diagnostics
make logs [SERVICE=name]               # Container logs
```

---

## 📚 Documentation

| Doc | Contents |
| :-- | :-- |
| [DEPLOYMENT.md](docs/DEPLOYMENT.md) | Detailed deployment walkthrough |
| [CONFIGURATION.md](docs/CONFIGURATION.md) | Every `.env` and secrets variable |
| [SECURITY.md](docs/SECURITY.md) | Security hardening deep-dive |
| [OPERATIONS.md](docs/OPERATIONS.md) | Day-to-day ops, update/rollback phases |
| [BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md) | Backup strategy and restore procedures |
| [SCRIPTS.md](docs/SCRIPTS.md) | Full script reference |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Common issues and fixes |
| [MIGRATION.md](docs/MIGRATION.md) | Migrating from other setups |
| [ADVANCED-CUSTOMIZATION.md](docs/ADVANCED-CUSTOMIZATION.md) | Version pinning, overrides, tuning |
| [API.md](docs/API.md) | API usage and integrations |
| [BOOTSTRAP_KEY_RECOVERY.md](docs/BOOTSTRAP_KEY_RECOVERY.md) | Age key recovery procedures |

---

## 📄 License

MIT License — see LICENSE file for details.
