# Configuration Reference — VaultWarden-OCI

All configuration is split between two files: **`.env`** (non-sensitive settings) and **`secrets/secrets.yaml`** (encrypted with Age + SOPS, edited via `./edit-secrets.sh`). Both are generated from `.example` templates by `setup.sh` — never edit generated files directly.

Related docs: [DEPLOYMENT.md](DEPLOYMENT.md) · [SECURITY.md](SECURITY.md) · [ADVANCED-CUSTOMIZATION.md](ADVANCED-CUSTOMIZATION.md)

---

## 📋 Configuration Workflow

```bash
# Initial setup (generates .env and docker-compose.yml from templates)
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto

# Edit non-sensitive settings
nano .env

# Edit sensitive secrets (encrypted)
./edit-secrets.sh

# Validate
docker compose config

# Apply changes
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com
./startup.sh --force
```

---

## 🌍 Core Settings

```bash
# Your VaultWarden URL — MUST include https://
DOMAIN=https://vault.yourdomain.com

# Bare domain (no protocol) — used by Caddy, Fail2Ban, and Postfix
DOMAIN_NAME=vault.yourdomain.com

# Admin contact for notifications and Fail2Ban emails
ADMIN_EMAIL=admin@yourdomain.com

# Cloudflare Zone ID — find in Cloudflare dashboard → Overview → right sidebar
CLOUDFLARE_ZONE_ID=your_zone_id_here
```

> **⚠️** `DOMAIN` requires `https://`. `DOMAIN_NAME` is the bare hostname without protocol. Both are required and used by different services.

---

## 📁 User & Directory

```bash
PUID=1000                              # Container file ownership UID
PGID=1000                              # Container file ownership GID
PROJECT_STATE_DIR=/var/lib/vaultwarden # Data, logs, and config root
TZ=UTC                                 # Timezone (affects all container logs)
SSH_PORT=22                            # SSH port for Fail2Ban SSH jail
SSH_LOG_PATH=/var/log/secure           # Auto-detected by setup.sh (OCI default)
# Debian/Ubuntu: /var/log/auth.log
# Oracle Linux / RHEL: /var/log/secure
```

---

## 📦 Container Versions

```bash
VAULTWARDEN_VERSION=1.35.4   # Pin for stability; blank = latest
CADDY_VERSION=2.11.1          # Must include Cloudflare module
FAIL2BAN_VERSION=1.1.0-r3
POSTFIX_VERSION=4.3.0         # bokysan/docker-postfix email relay
```

To override versions at runtime without editing files:

```bash
SOPS_VERSION=v3.9.4 sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com
```

See [ADVANCED-CUSTOMIZATION.md](ADVANCED-CUSTOMIZATION.md) for version pinning details.

---

## 🔒 Secrets (Encrypted)

Manage secrets with `./edit-secrets.sh`. They are encrypted with Age + SOPS; never stored in plaintext.

### Required Secrets

| Secret | Purpose | How to Get |
| :-- | :-- | :-- |
| `admin_basic_auth_hash` | Bcrypt hash for Caddy `/admin` basic auth | `docker run --rm -it ghcr.io/caddybuilds/caddy-cloudflare:latest caddy hash-password` |
| `caddy_cloudflare_dns_token` | Caddy DNS-01 challenge (Zone:DNS:Edit + Zone:Zone:Read) | [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) |
| `fail2ban_cloudflare_firewall_token` | Fail2Ban edge banning (Zone:Firewall Services:Edit) | [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) |

### Optional Secrets

| Secret | Purpose |
| :-- | :-- |
| `smtp_password` | SMTP relay password for Postfix/VaultWarden email |
| `push_installation_id` | Bitwarden push notification installation ID |
| `push_installation_key` | Bitwarden push notification installation key |

> **Note:** `fail2ban_cloudflare_firewall_token` is mandatory if you want edge blocking. Without it, Fail2Ban can detect attacks but cannot push bans to Cloudflare WAF.

---

## 📧 Email Configuration (Postfix)

Email is delivered by a **`bokysan/docker-postfix`** sidecar container acting as an SMTP relay. Configure the relay in `.env`; the password goes in secrets.

```bash
# SMTP relay settings (shared by VaultWarden and Postfix)
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_SECURITY=starttls              # starttls or on (SSL/TLS)
SMTP_USERNAME=your-email@gmail.com
SMTP_FROM=noreply@vault.yourdomain.com
SMTP_FROM_NAME=VaultWarden
SMTP_TIMEOUT=15

# Postfix-specific
ALLOWED_SENDER_DOMAINS="vault.yourdomain.com yourdomain.com"
POSTFIX_MYHOSTNAME=postfix.vault.yourdomain.com
POSTFIX_SMTP_TLS_SECURITY_LEVEL=encrypt   # encrypt | may | none
POSTFIX_MESSAGE_SIZE_LIMIT=10240000        # 10 MB
```

SMTP password:

```bash
./edit-secrets.sh   # set: smtp_password
```

Test end-to-end delivery:

```bash
./maintenance.sh --test-email --verbose
# or: make test-email
```

> The Postfix container relays through your `SMTP_HOST`. `RELAYHOST`, `RELAYHOST_USERNAME`, and `RELAYHOST_PASSWORD` are constructed automatically from `SMTP_*` variables in `docker-compose.yml` — do not set them manually.

---

## 🔔 VaultWarden Application Settings

```bash
# Registration
SIGNUPS_ALLOWED=false             # Disable open registration (recommended)
INVITATIONS_ALLOWED=true          # Admin-controlled invites
EMERGENCY_ACCESS_ALLOWED=true
SENDS_ALLOWED=true
WEB_VAULT_ENABLED=true

# Security
PASSWORD_ITERATIONS=600000        # Argon2 / PBKDF2 iterations
PASSWORD_HINTS_ALLOWED=false
SHOW_PASSWORD_HINT=false
DISABLE_ADMIN_TOKEN=false
DISABLE_ICON_DOWNLOAD=false

# Icon cache
ICON_CACHE_TTL=2592000
ICON_CACHE_NEGTTL=259200

# Organisation & events
ORG_CREATION_USERS=               # Blank = anyone; or comma-separated emails
ORG_EVENTS_ENABLED=false
EVENTS_DAYS_RETAIN=365

# Maintenance
TRASH_AUTO_DELETE_DAYS=30
INCOMPLETE_2FA_TIME_LIMIT=3

# Database
DATABASE_MAX_CONNS=10
DATABASE_TIMEOUT=30
```

---

## 📲 Push Notifications

Register at <https://bitwarden.com/host> to get an installation ID and key, then set:

```bash
PUSH_ENABLED=true
PUSH_RELAY_URI=https://push.bitwarden.com
PUSH_IDENTITY_URI=https://identity.bitwarden.com
```

Add `push_installation_id` and `push_installation_key` via `./edit-secrets.sh`.

---

## 🚫 Fail2Ban

```bash
F2B_LOG_TARGET=STDOUT
F2B_LOG_LEVEL=INFO
F2B_DB_PURGE_AGE=1d
F2B_MAX_RETRY=3
F2B_DEST_MAIL="${ADMIN_EMAIL}"    # Ban notification recipient
F2B_SENDER="fail2ban@${DOMAIN_NAME}"
F2B_ACTION="%(action_mwl)s"        # Email + Cloudflare ban
```

> All web-facing jails push bans to **Cloudflare Edge WAF via API** — local `iptables` is not used for proxied services. Only the SSH jail uses local iptables.

---

## 💾 Backup

```bash
BACKUP_VERIFICATION_MODE=quick_check   # quick_check or integrity_check
BACKUP_SCHEDULE="0 4 * * 1-6"          # Cron schedule for automated DB backups
BACKUP_RETENTION_DAYS=30               # Default retention for full backups (days).
                                        # DB backups default to 14 days.
                                        # Override per-run: backup.sh --keep N
RCLONE_REMOTE_NAME=CHANGE_ME_RCLONE_REMOTE  # rclone remote for offsite sync
```

See [BACKUP-RESTORE.md](BACKUP-RESTORE.md) for procedures.

---

## 🛠️ Troubleshooting Configuration

**Validate before applying:**

```bash
docker compose config                              # validate generated compose
docker compose -f docker-compose.yml.example config  # validate template
```

**Regenerate from templates:**

```bash
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com
```

**Secrets issues:**

```bash
ls -l secrets/keys/age-key.txt   # must exist and be mode 600
./edit-secrets.sh                 # verify decryption works
```

**Email issues:**

```bash
docker compose logs postfix
./maintenance.sh --test-email --verbose
grep SMTP .env
```
