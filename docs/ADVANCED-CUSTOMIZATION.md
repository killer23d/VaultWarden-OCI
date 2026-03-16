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
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com

# 4. Restart services
./startup.sh --force
```

---

## ⏲️ Automation — systemd Timers

Automation is managed by **systemd timers** (not cron). Install or remove them with:

```bash
sudo ./systemd-setup.sh --install    # install all timers and services
sudo ./systemd-setup.sh --remove     # remove all timers and services
sudo ./systemd-setup.sh --status     # show status of all units
```

### Installed Timer Schedule

| Unit | Schedule | Job |
| :-- | :-- | :-- |
| `vaultwarden-maintenance.timer` | Sunday 2 AM | Comprehensive maintenance |
| `vaultwarden-full-backup.timer` | Sunday 3 AM | Full backup + verify + rclone + email |
| `vaultwarden-db-backup.timer` | Mon–Sat 4 AM | DB snapshot + rclone + email |
| `vaultwarden-health.timer` | Every 30 min | Health check with auto-recover + email |
| `vaultwarden-dns-update.timer` | Every hour | Dynamic DNS update |
| `vaultwarden-firewall-update.timer` | Saturday 4 AM | Cloudflare firewall IP list refresh |

> **Note on the Sunday DB backup gap:** `vaultwarden-db-backup.timer` runs Mon–Sat only. The Sunday 3 AM full backup covers the Sunday snapshot. If you want an additional DB-only run on Sunday after the full backup completes, add a supplemental timer entry with `OnCalendar=Sun *-*-* 05:00:00`.

### Timer Persistence

All timers use `Persistent=true`. If the system reboots while a timer was due to fire, systemd runs the missed job once on next boot — no manual intervention or lock-directory recreation required.

### Failure Notifications

Every service unit has:
```ini
OnFailure=vaultwarden-notify-failure@%n.service
```
If any timer-triggered job fails, an email alert is sent automatically via the shared `vaultwarden-notify-failure@.service` template unit. No external monitoring tool is required for basic failure alerting.

### Viewing Timer Status

```bash
# Show all VaultWarden timers, next fire time, and last result
systemctl list-timers --all | grep vaultwarden

# View logs for a specific unit
journalctl -u vaultwarden-db-backup.service -n 50
journalctl -u vaultwarden-health.service -n 50
```

### Modifying a Timer Schedule

Edit the `.timer` file directly (do not use `systemd-setup.sh` — it would overwrite your change on next install):

```bash
sudo systemctl edit --full vaultwarden-db-backup.timer
# Change OnCalendar= to your preferred schedule
sudo systemctl daemon-reload
sudo systemctl restart vaultwarden-db-backup.timer
```

---

## 📌 Dependency Version Pinning

By default `setup.sh` auto-resolves the latest release of SOPS and age from the GitHub API. To pin specific versions for reproducible deployments, edit the top of `setup.sh` before running:

```bash
SOPS_VERSION="v3.9.4"   # pinned
AGE_VERSION=""           # blank = auto-resolve latest
```

Or override at runtime without editing the file:

```bash
SOPS_VERSION=v3.9.4 sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com
```

| Variable | Default | Example |
| :-- | :-- | :-- |
| `SOPS_VERSION` | `""` (latest) | `"v3.9.4"` |
| `AGE_VERSION` | `""` (latest) | `"v1.2.0"` |

> `AGE_VERSION` only applies when installing age as a standalone binary. By default age is installed via `apt`.

---

## 🖥️ Resource Limits

Default limits are tightly tuned for a **6 GB OCI ARM instance** (512 MB for VaultWarden, Caddy, and Fail2ban; 256 MB for Postfix) to leave ample memory for the host OS. Edit `docker-compose.yml.example` to adjust if you need more resources.

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

### Fail2Ban — Tighter Thresholds

```ini
# Edit fail2ban/jail.d/vaultwarden-oci.conf
[vaultwarden-auth]
maxretry = 2       # reduced from 3
bantime  = 24h     # increased from 2h
findtime = 10m     # tightened from 1h
```

> **Note:** All web-facing jails push bans to the **Cloudflare Edge WAF via API** — local `iptables` is not used for proxied services. Only the SSH jail uses local iptables (leveraging Fail2ban's `network_mode: host`).

### Fail2Ban — NFS Log Mounts

If your Caddy log volume is on an NFS share (common in OCI with block storage), log lines end with `\r\n` instead of `\n`. The JSON `failregex` patterns in `fail2ban/filter.d/vaultwarden-web-auth.conf` must use `\r?$` line anchors to match correctly on NFS mounts:

```ini
# Correct pattern for NFS-mounted logs (\r?$ instead of $)
failregex = ^{"ts":.+"status":40[13].+}\r?$
```

Verify whether your logs have carriage returns:
```bash
cat -A /var/log/caddy/auth_attempts.log | head -5
# A trailing ^M before $ means \r is present — use \r?$ anchors
```

### Custom Fail2Ban Filter

```ini
# Create fail2ban/filter.d/vaultwarden-custom.conf
[Definition]
failregex = ^.*<your-pattern>.*<HOST>.*$
ignoreregex =
```

### Caddy — 4-Tier Log Architecture

Caddy uses four named loggers to route traffic to independent log files with separate retention policies:

| Logger | File | Retention | Purpose |
| :-- | :-- | :-- | :-- |
| `access_log` | `/var/log/caddy/access.log` | 30 days / 50 MB rolls | All general traffic |
| `admin_log` | `/var/log/caddy/admin_access.log` | 90 days / 25 MB rolls | `/admin` panel requests |
| `auth_log` | `/var/log/caddy/auth_attempts.log` | 90 days / 25 MB rolls | Login and token endpoints (Fail2Ban source) |
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

> **If using NFS for Caddy logs:** see the Fail2Ban NFS note above — `\r?$` anchors are required in `failregex` patterns.

### Multi-Destination Backups

```bash
# After running ./backup.sh, sync the entire directory to additional remotes:
rclone copy backups/full/ gdrive:vaultwarden-backups/full/
rclone copy backups/full/ s3:my-bucket/vaultwarden/full/
```

---

## 💾 Backup Retention Customisation

Default retention is **14 days** for all backup tiers. Override at runtime or in `.env`:

```bash
# Keep 30 days of full backups
sudo ./backup.sh --type full --keep 30

# Keep 7 days of DB snapshots
sudo ./backup.sh --type db --keep 7
```

The `--keep` value **must be a positive integer**. Non-integer values are rejected with an error before any backup or cleanup operation begins.

To set a permanent default, edit `KEEP_DAYS` in `.env`:
```bash
KEEP_DAYS=30
```

> **Retention on restored hosts:** Backup retention age is calculated from the **timestamp embedded in the filename** (e.g., `vaultwarden-full-20260312-030000.tar.gz.age`), not from the file's `ctime`. This means backups restored to a new host are cleaned up correctly based on their original creation date, not the date they were copied.

---

## 📧 Email Customisation

Email is handled by the **Postfix sidecar container** (`postfix` service). Configure the relay in `.env`:

```bash
SMTP_HOST=smtp.sendgrid.net
SMTP_PORT=587
SMTP_USERNAME=apikey
ALLOWED_SENDER_DOMAINS=yourdomain.com
```

Set the SMTP password via secrets:

```bash
./edit-secrets.sh --rotate smtp_password
```

Test end-to-end delivery:

```bash
./maintenance.sh --test-email --verbose
# or: make test-email
```

### Decoupled Email Override

The `docker-compose.override.yml.example` is provided specifically to decouple VaultWarden's built-in SMTP from the Postfix sidecar. Copy and activate it if you need to route VaultWarden emails differently:

```bash
cp docker-compose.override.yml.example docker-compose.override.yml
```

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
  fail2ban:
    deploy:
      replicas: 0
  caddy:
    deploy:
      replicas: 0
```

```bash
make dev-setup     # setup dev environment
make test          # run all tests
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
- Run `sudo ./setup.sh --force ...` to regenerate
- Restart with `./startup.sh --force`
- Verify with `./health.sh` or `make health`
- Commit template changes to version control
- Create a backup before major changes: `./backup.sh --type full`
- After re-installing automation: `sudo ./systemd-setup.sh --install && systemctl list-timers --all | grep vaultwarden`
