# Advanced Customization — VaultWarden-OCI

This guide covers advanced configuration options beyond the defaults set by `setup.sh`. All customisation follows the same **template-first principle**: edit `.example` files, then regenerate.

Related docs: [CONFIGURATION.md](CONFIGURATION.md) · [DEPLOYMENT.md](DEPLOYMENT.md) · [SECURITY.md](SECURITY.md)

---

## 📋 Template Workflow

Every live config file is generated from a `.example` template. Never edit generated files directly — they are overwritten by `setup.sh`.

```
.example templates  →  setup.sh  →  Generated files  →  docker compose up
```

### Apply Template Changes

```bash
# 1. Edit the template
nano docker-compose.yml.example

# 2. Validate syntax before applying
docker compose -f docker-compose.yml.example config

# 3. Regenerate and apply
sudo ./setup.sh install --domain vault.yourdomain.com --email admin@yourdomain.com --force

# 4. Restart services
./startup.sh --force
```

---

## 🔧 Docker Compose Override File

`docker-compose.override.yml.example` is a **development-only** override template. Docker Compose automatically merges `docker-compose.override.yml` on top of `docker-compose.yml` when both files are present — no extra flags required.

> ⚠️ **Never use `docker-compose.override.yml.example` in production.** The VaultWarden service entrypoint will abort startup if it detects `ENVIRONMENT=production`, preventing accidental activation.

### What It Contains

The override file modifies every core service for local development and testing:

| Service | What changes |
| :-- | :-- |
| `vaultwarden` | Enables `LOG_LEVEL=debug`, `SIGNUPS_ALLOWED=true`, removes resource limits, exposes port `127.0.0.1:8080:80` |
| `caddy` | Binds admin API to loopback (`127.0.0.1:2019`), exposes ports `8081`/`8443`, removes resource limits |
| `postfix` | Relaxes TLS to `may`, exposes submission port `127.0.0.1:1025:587`, adds SASL debug logging |
| `email-tester` | Alpine-based SMTP test container; activated by `--profile development` or `--profile email-testing` |
| `mailpit` | Email capture UI (`axllent/mailpit`) replacing abandoned mailhog; activated by `--profile email-capture` |

All exposed ports bind to `127.0.0.1` exclusively. Use SSH port-forwarding to access them from a remote host.

### When to Use It

Use `docker-compose.override.yml.example` when you need to:

- Test email delivery locally without sending real messages (Mailpit capture)
- Debug container startup issues (`LOG_LEVEL=debug`, Caddy admin API)
- Develop against a live VaultWarden instance with signups enabled
- Test CrowdSec detection against live log output

### Activating the Override

```bash
# 1. Copy the template (make dev-setup does this automatically)
cp docker-compose.override.yml.example docker-compose.override.yml

# 2. Customise as needed
nano docker-compose.override.yml

# 3. Validate the merged config
docker compose -f docker-compose.yml -f docker-compose.override.yml config

# 4. Start with a profile
docker compose --profile development up -d
```

`make dev-setup` copies both `.env.example → .env` and `docker-compose.override.yml.example → docker-compose.override.yml` in one step.

### Available Profiles

| Profile | Services added | Use case |
| :-- | :-- | :-- |
| `development` | `email-tester` | Full dev environment with SMTP test utilities |
| `email-testing` | `email-tester` | Focused SMTP integration testing |
| `email-capture` | `mailpit` | Capture outbound email in a local UI instead of delivering it |

```bash
# Start all core services + email capture UI
docker compose --profile email-capture up -d

# Access Mailpit (SSH tunnel required from a remote host)
# ssh -L 8025:localhost:8025 user@host
# Then open: http://localhost:8025
```

### Production-Specific Overrides (Non-Dev Use Cases)

The override file can also serve narrow production customisation needs without modifying the base template. Use a clean `docker-compose.override.yml` (not the example) for production overrides:

**Disable the Postfix sidecar** when using `EMAIL_MODE=api` or `EMAIL_MODE=smtp` exclusively:

```yaml
# docker-compose.override.yml
services:
  postfix:
    deploy:
      replicas: 0
```

**Enable push notifications** when the network uses `internal: true` (requires removing the internal constraint):

```yaml
# docker-compose.override.yml
networks:
  vaultwarden:
    internal: false
```

> See the [Email Customisation](#-email-customisation) section for the full three-tier delivery chain and provider switching.

### Removing the Override

To return to the base production configuration, remove or rename the file:

```bash
mv docker-compose.override.yml docker-compose.override.yml.bak
./startup.sh --force
```

---

## ⏲️ Automation — systemd Timers

Automation is managed by **systemd timers** (not cron). Install, validate, or remove them with:

```bash
sudo ./setup.sh systemd install    # install all timers and services
sudo ./setup.sh systemd validate   # verify installed state matches repo
sudo ./setup.sh systemd remove     # remove all timers and services
sudo ./setup.sh systemd status     # show status of all units
```

### Installed Timer Schedule

| Unit | Schedule | Job |
| :-- | :-- | :-- |
| `vaultwarden-maintenance.timer` | Daily 2:05 AM | Comprehensive maintenance |
| `vaultwarden-full-backup.timer` | Sunday 3 AM | Full backup + verify + rclone |
| `vaultwarden-db-backup.timer` | Daily 4 AM | DB snapshot + rclone + full verification |
| `vaultwarden-health.timer` | Every 5 min | Health check with auto-recover + email |
| `vaultwarden-dns-update.timer` | Every hour | Dynamic DNS update |
| `vaultwarden-firewall-update.timer` | Saturday 4 AM | Cloudflare firewall IP list refresh |

> **Note on timer overlap:** `vaultwarden-maintenance.timer` now runs every day at 02:05, leaving the Sunday 03:00 full backup window clear. If you customise the schedule, keep at least a one-hour gap before the backup timers.

### Timer Persistence

The health, DNS, DB-backup, and firewall-update timers use `Persistent=true` — if the system reboots while one was due to fire, systemd runs the missed job once on next boot. The full-backup and maintenance timers use `Persistent=false` to avoid a catch-up I/O storm after extended downtime.

### Failure Notifications

Every service unit has:
```ini
OnFailure=vaultwarden-notify-failure.service
```
If any timer-triggered job fails, an email alert is sent automatically via the shared `vaultwarden-notify-failure.service` template unit. No external monitoring tool is required for basic failure alerting.

### Viewing Timer Status

```bash
# Show all VaultWarden timers, next fire time, and last result
systemctl list-timers --all | grep vaultwarden

# View logs for a specific unit
journalctl -u vaultwarden-db-backup.service -n 50
journalctl -u vaultwarden-health.service -n 50
```

### Modifying a Timer Schedule

Edit the `.timer` file directly (do not use `setup.sh systemd` — it would overwrite your change on next install):

```bash
sudo systemctl edit --full vaultwarden-db-backup.timer
# Change OnCalendar= to your preferred schedule
sudo systemctl daemon-reload
sudo systemctl restart vaultwarden-db-backup.timer
```

---

## 📌 Dependency Version Pinning

By default `setup.sh` uses the repository-pinned SOPS production default and installs `age` from Ubuntu Noble packages. To request a specific SOPS release, set `SOPS_VERSION` before running setup:

```bash
SOPS_VERSION="v3.9.4"   # pinned
```

Or override at runtime without editing the file:

```bash
SOPS_VERSION=v3.9.4 sudo ./setup.sh install --domain vault.yourdomain.com --email admin@yourdomain.com
```

| Variable | Default | Example |
| :-- | :-- | :-- |
| `SOPS_VERSION` | repository-pinned default (`v3.13.2`) | `"v3.9.4"` |

Pass `--use-latest` only when you intentionally want setup to resolve the current SOPS release during dependency installation.

---

## 🖥️ Resource Limits

Default limits are tightly tuned for a **6 GB OCI ARM instance** (512 MB for VaultWarden and Caddy; 256 MB for Postfix) to leave ample memory for the host OS and CrowdSec. Edit `docker-compose.yml.example` to adjust if you need more resources.

### Larger Systems (12 GB+ RAM)

```yaml
services:
  vaultwarden:
    deploy:
      resources:
        limits:
          memory: 2G
          cpus: '1.0'
        reservations:
          memory: 512M
          cpus: '0.4'
  caddy:
    deploy:
      resources:
        limits:
          memory: 1G
          cpus: '0.5'
```

### Minimal Systems (2 GB RAM)

```yaml
services:
  vaultwarden:
    deploy:
      resources:
        limits:
          memory: 256M
          cpus: '0.5'
        reservations:
          memory: 128M
```

---

## 🔒 Security Customisation

### CrowdSec — Tighter Thresholds

CrowdSec scenario thresholds are configured via YAML overrides:

```yaml
# /etc/crowdsec/hub/scenarios/crowdsecurity/http-bf.yaml override
type: leaky
name: crowdsecurity/http-bf
description: "HTTP brute force — tighter thresholds"
capacity: 2       # reduced from default
leakspeed: "10m"  # tightened
blackhole: "24h"  # extended ban duration
```

> **Note:** All web-facing bans push to **Cloudflare Edge WAF via API** — local `iptables` is not used for proxied services. Only the SSH scenario uses host iptables via `cs-firewall-bouncer`.

### CrowdSec — Custom Scenarios

```yaml
# /etc/crowdsec/scenarios/vaultwarden-custom.yaml
type: leaky
name: local/vaultwarden-custom
description: "Custom VaultWarden detection"
filter: "evt.Meta.service == 'vaultwarden'"
capacity: 3
leakspeed: "1m"
blackhole: "2h"
labels:
  type: bruteforce
```

### CrowdSec — Whitelist Configuration

```yaml
# /etc/crowdsec/whitelists/myip.yaml
name: local/myip-whitelist
description: "Admin IP whitelist"
whitelist:
  reason: "Admin IP"
  ip:
    - "YOUR_IP_HERE"
```

Or use `cscli` directly:
```bash
sudo cscli whitelists add myip "$(curl -s https://ifconfig.me)"
```

### Caddy — 4-Tier Log Architecture

Caddy uses four named loggers to route traffic to independent log files with separate retention policies:

| Logger | File | Retention | Purpose |
| :-- | :-- | :-- | :-- |
| `access_log` | `/var/log/caddy/access.log` | 30 days / 50 MB rolls | All general traffic |
| `admin_log` | `/var/log/caddy/admin_access.log` | 90 days / 25 MB rolls | `/admin` panel requests |
| `auth_log` | `/var/log/caddy/auth_attempts.log` | 90 days / 25 MB rolls | Login and token endpoints (CrowdSec source) |
| `security_log` | `/var/log/caddy/security.log` | 180 days / 10 MB rolls | Catch-all and anomalous requests |

To adjust retention, edit the `log` blocks in the global section of `caddy/Caddyfile`:

```caddyfile
log auth_log {
    output file /var/log/caddy/auth_attempts.log {
        roll_size 50MB       # increase roll size
        roll_keep 60         # keep 60 rolled files
        roll_keep_for 180d   # retain for 6 months
    }
}
```

### Caddy — Security Headers

The Caddyfile ships with a hardened security header set. Key notes for customisation:

- **`Cross-Origin-Embedder-Policy`** is set to `credentialless` (not `require-corp`). Changing to `require-corp` breaks WebAuthn/passkey flows because cross-origin authenticators cannot load without credentials.
- **`Content-Security-Policy`** on the main site scopes `connect-src` to `wss://{$DOMAIN_NAME}`, `https://push.bitwarden.com`, and `https://identity.bitwarden.com`. If you disable push notifications (`PUSH_ENABLED=false` in `.env`), you can remove the two Bitwarden push URLs from `connect-src` in `caddy/Caddyfile` to tighten the policy.
- **Admin panel CSP** retains `'unsafe-inline'` in `script-src` — this is required by VaultWarden's admin UI which renders inline `<script>` blocks. Do not remove it without testing admin panel functionality.

### Additional Caddy Security Headers

```caddyfile
# Edit caddy/Caddyfile
header {
    Permissions-Policy "geolocation=(), microphone=(), camera=()"
    Expect-CT          "enforce, max-age=86400"
}
```

### Admin IP Allowlisting

```caddyfile
# Edit caddy/Caddyfile
@admin { path /admin* }

handle @admin {
    @allowed { remote_ip 192.168.1.0/24 10.0.0.0/8 }
    handle @allowed {
        basic_auth {
            {env.ADMIN_USERNAME} {env.ADMIN_HASH}
        }
        reverse_proxy vaultwarden:80
    }
    handle { respond "Access Denied" 403 }
}
```

> **Note:** The `@malicious_ua` User-Agent blocklist that appeared in earlier versions has been removed. It was trivially bypassed by any attacker omitting a scanner User-Agent. Configure scanner/bot detection through the **Cloudflare WAF Managed Ruleset** (Cloudflare Dashboard → Security → WAF → Managed rules) for effective protection.

### Bcrypt Cost Factor

All bcrypt hash operations (Caddy admin credential, break-glass admin) enforce a **minimum cost factor of 10**. The validator in `lib/crypto.sh` rejects any hash or cost value below 10 at generation time. The recommended production value is 12 (the default).

If you regenerate the Caddy admin credential manually:
```bash
# Correct: cost 12
htpasswd -nbBC 12 admin 'yourpassword'

# The entrypoint.sh validator will reject hashes with cost < 10 at startup
```

### Caddy Entrypoint Debug Mode

`caddy/entrypoint.sh` supports a `DEBUG_ENTRYPOINT=true` environment variable for troubleshooting startup issues. **Never leave this enabled in production** — it logs `ADMIN_USERNAME` to Docker stdout (which is persisted to the container's `json.log` file on the host).

```bash
# Temporarily enable for one-off debugging only:
docker compose run --rm -e DEBUG_ENTRYPOINT=true caddy

# The entrypoint will print a visible WARNING banner when debug mode is active:
# ⚠️  WARNING: DEBUG_ENTRYPOINT enabled — credential names will be logged — DISABLE IN PRODUCTION
```

---

## 📧 Email Customisation

The normal appliance path is Postfix-first SMTP: Vaultwarden, scripts, alerts, systemd failure notifications, and recovery-kit attachment emails submit to the Postfix sidecar, which relays to your external SMTP provider. Keep Postfix enabled for production reliability.

See [EMAIL.md](EMAIL.md) for the full reference. Advanced options in that document include:

- API-first operational alerts with `EMAIL_MODE=auto` and `EMAIL_PROVIDER=mailersend|sendgrid|mailgun|postmark|resend`.
- Mailgun region overrides.
- Direct SMTP emergency fallback semantics.
- Postfix queue/log troubleshooting.

When switching upstream SMTP relays, change only the external relay settings:

```bash
SMTP_HOST=smtp.sendgrid.net
SMTP_PORT=587
SMTP_SECURITY=starttls
SMTP_USERNAME=apikey
SMTP_FROM=noreply@vault.yourdomain.com
ALLOWED_SENDER_DOMAINS=yourdomain.com
sudo ./utilities/secrets-rotate.sh smtp_password
```

Do not point Vaultwarden directly at the external relay in normal production. Keep:

```bash
VW_SMTP_HOST=postfix
VW_SMTP_PORT=587
VW_SMTP_SECURITY=off
VW_SMTP_AUTH_MECHANISM=none
VW_SMTP_EXPLICIT_TLS=false
```

### Decoupled VaultWarden Email Override

The `docker-compose.override.yml.example` is provided to decouple VaultWarden's built-in SMTP from the `lib/common.sh` (email functions) chain (e.g. to route VaultWarden app emails through a different provider than maintenance/health alert emails):

```bash
cp docker-compose.override.yml.example docker-compose.override.yml
nano docker-compose.override.yml   # customise VaultWarden SMTP overrides
```

### Testing Email Modes

```bash
# Normal Postfix-backed operational alert path
sudo ./maintenance.sh test-email --verbose
make test-email

# Advanced API-mode checks only when EMAIL_MODE=auto/api is configured
EMAIL_MODE=api  sudo ./maintenance.sh test-email --verbose
EMAIL_MODE=smtp sudo ./maintenance.sh test-email --verbose
EMAIL_MODE=host sudo ./maintenance.sh test-email --verbose  # legacy direct-SMTP alias
```

---

## 📦 Storage Customisation

### External Database

```yaml
# Edit docker-compose.yml.example
services:
  vaultwarden:
    environment:
      - DATABASE_URL=postgresql://user:pass@pg-host:5432/vaultwarden
      # or MySQL: mysql://user:pass@mysql-host:3306/vaultwarden
```

### NFS / Separate Volume Mounts

```yaml
services:
  vaultwarden:
    volumes:
      - /mnt/nfs/vaultwarden/attachments:/data/attachments
```

> **If using NFS for Caddy logs:** ensure log line endings are consistent — `\r\n` line endings on OCI File Storage NFS mounts may require special handling in log parsers.

### Multi-Destination Backups

```bash
# After running ./backup.sh, sync the entire directory to additional remotes:
rclone copy backups/full/ gdrive:vaultwarden-backups/full/
rclone copy backups/full/ s3:my-bucket/vaultwarden/full/
```

---

## 💾 Backup Retention Customisation

Default retention is **30 days** for all backup types (controlled by `BACKUP_RETENTION_DAYS` in `.env`). Override at runtime or in `.env`:

```bash
# Keep 30 days of full backups
sudo ./backup.sh run full --keep 30

# Keep 7 days of DB snapshots
sudo ./backup.sh run db --keep 7
```

The `--keep` value **must be a positive integer**. Non-integer values are rejected with an error before any backup or cleanup operation begins.

To set a permanent default, edit `BACKUP_RETENTION_DAYS` in `.env`:
```bash
BACKUP_RETENTION_DAYS=30
```

Per-type overrides take precedence over the global default:
```bash
# Per-type retention (uncomment in .env to override BACKUP_RETENTION_DAYS)
BACKUP_RETENTION_DB_DAYS=14    # retention for db backups
BACKUP_RETENTION_FULL_DAYS=60  # retention for full backups
```

> **Retention on restored hosts:** Backup retention age is calculated from the **timestamp embedded in the filename** (e.g., `vaultwarden-full-20260312-030000.tar.gz.age`), not from the file's `ctime`. This means backups restored to a new host are cleaned up correctly based on their original creation date, not the date they were copied.

---

## ⚡ Performance Tuning

### Database (SQLite)

WAL mode is enabled automatically. To tune further, use `sqlite3` from the host (the VaultWarden container does not ship `sqlite3`):

```bash
# Run against the host-accessible database file
sudo sqlite3 "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/data/bwdata/db.sqlite3" \
  "PRAGMA synchronous=NORMAL; PRAGMA cache_size=-2000;"
```

> ⚠️ Only run manual PRAGMAs when VaultWarden is stopped to avoid WAL conflicts: `docker compose stop vaultwarden` first, then restart with `docker compose start vaultwarden`.

### Caddy — HTTP/3 and Compression

```caddyfile
# Edit caddy/Caddyfile — global options block
{
    servers {
        protocol { experimental_http3 }
        idle_timeout 5m
        read_header_timeout 10s
    }
}

# Inside the site block
encode {
    gzip 6
    zstd
    minimum_length 256
}
```

---

## 🧪 Development Environment

```yaml
# docker-compose.override.yml — dev overrides
services:
  vaultwarden:
    environment:
      - SIGNUPS_ALLOWED=true
      - LOG_LEVEL=debug
      - DOMAIN=http://localhost:8080
    ports:
      - "8080:80"
  caddy:
    deploy:
      replicas: 0
```

```bash
make dev-setup     # setup dev environment
./tests/run-tests.sh all  # run regression suite
make test-config   # validate Docker Compose config
make dry-run       # preview all operations
```

---

## 🔌 Integrations

### SSO via OAuth2 Proxy

```caddyfile
# Edit caddy/Caddyfile
vault.yourdomain.com {
    forward_auth oauth2-proxy:4180 {
        uri /oauth2/auth
        copy_headers X-Auth-Request-User X-Auth-Request-Email
    }
    reverse_proxy vaultwarden:80
}
```

### Webhook Notifications

```bash
# Call from cron or health check scripts
curl -sX POST https://your-webhook-url/notify \
  -H "Content-Type: application/json" \
  -d "{\"event\":\"$1\",\"message\":\"$2\",\"timestamp\":\"$(date -Iseconds)\"}"
```

---

## ✅ Customisation Checklist

- Edit `.example` templates — never generated files
- Validate with `docker compose config` before applying
- Run `sudo ./setup.sh install --force ...` to regenerate
- Restart with `./startup.sh --force`
- Verify with `./maintenance.sh health` or `make health`
- Commit template changes to version control
- Create a backup before major changes: `./backup.sh run full`
- After re-installing automation: `sudo ./setup.sh systemd install && systemctl list-timers --all | grep vaultwarden`
