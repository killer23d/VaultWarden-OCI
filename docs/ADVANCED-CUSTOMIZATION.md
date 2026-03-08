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

### Custom Fail2Ban Filter

```ini
# Create fail2ban/filter.d/vaultwarden-custom.conf
[Definition]
failregex = ^.*<your-pattern>.*<HOST>.*$
ignoreregex =
```

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
        basic_auth { import secret_admin_basic_auth_hash }
        reverse_proxy vaultwarden:80
    }
    handle { respond "Access Denied" 403 }
}
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

### Multi-Destination Backups

```bash
# After running ./backup.sh, sync the entire directory to additional remotes:
rclone copy backups/full/ gdrive:vaultwarden-backups/full/
rclone copy backups/full/ s3:my-bucket/vaultwarden/full/
```

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
./edit-secrets.sh   # set: smtp_password
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
