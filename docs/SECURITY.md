# Security Guide — VaultWarden-OCI

This comprehensive security guide covers the multi-layered security approach implemented in VaultWarden-OCI, including Cloudflare-only blocking for web traffic, encrypted secrets management, firewall hardening, and emergency access procedures.

## Security Architecture Overview

VaultWarden-OCI implements defense-in-depth with multiple security layers:

```
┌─────────────────────────────────────────┐
│   Layer 1: Cloudflare Edge Security    │
│   - Global WAF                          │
│   - DDoS Protection                     │
│   - IP Blocking (Web Traffic ONLY)     │
│   - TLS Termination at Edge             │
└─────────────────────────────────────────┘
                  ↓
┌─────────────────────────────────────────┐
│   Layer 2: Host Firewall (UFW)         │
│   - Cloudflare IP Whitelist             │
│   - SSH Protection (Local iptables)     │
│   - Safe Update Mechanism               │
└─────────────────────────────────────────┘
                  ↓
┌─────────────────────────────────────────┐
│   Layer 3: Application Security         │
│   - Caddy Reverse Proxy                 │
│   - Enhanced Rate Limiting              │
│   - Forensic Logging (3GB retention)    │
│   - Security Headers                    │
└─────────────────────────────────────────┘
                  ↓
┌─────────────────────────────────────────┐
│   Layer 4: Fail2Ban Monitoring         │
│   - Cloudflare-ONLY for Web Traffic    │
│   - Local iptables ONLY for SSH         │
│   - High-Fidelity Log Parsing           │
│   - Email Alerts via Postfix            │
└─────────────────────────────────────────┘
                  ↓
┌─────────────────────────────────────────┐
│   Layer 5: Container Security          │
│   - Non-root Execution                  │
│   - Capability Restrictions             │
│   - Resource Limits                     │
│   - Encrypted Secrets                   │
│   - Network Isolation (internal: true)  │
└─────────────────────────────────────────┘
                  ↓
┌─────────────────────────────────────────┐
│   Layer 6: Data Security                │
│   - Age + SOPS Encryption               │
│   - Atomic Backup Operations            │
│   - Integrity Verification              │
│   - Encrypted Remote Backups            │
└─────────────────────────────────────────┘
```

## Critical Understanding: Cloudflare Proxy Architecture

### Why Cloudflare-Only Blocking for Web Traffic

**CRITICAL**: When VaultWarden is behind Cloudflare proxy:
- All web traffic appears to come from Cloudflare IP addresses
- The actual attacker's IP is in the `CF-Connecting-IP` header
- Local iptables rules blocking attacker IPs are **completely ineffective**
- The firewall would block Cloudflare's IPs, breaking all web access

### Current Blocking Strategy

#### Web Traffic (Proxied through Cloudflare)
```ini
# All web-facing jails use Cloudflare API ONLY
[vaultwarden-auth]
action = smtp[...]
         cloudflare-apiv4    # ✅ Blocks at Cloudflare edge

[vaultwarden-admin]
action = smtp[...]
         cloudflare-apiv4    # ✅ Blocks at Cloudflare edge

[vaultwarden-web-*]
action = smtp[...]
         cloudflare-apiv4    # ✅ Blocks at Cloudflare edge
```

#### SSH Traffic (Direct, NOT Proxied)
```ini
# SSH jail uses local iptables (direct connection)
# Fail2ban 1.1.0-r3 leverages iptables-legacy fallbacks to ensure compatibility
# with modern OS networking stacks (like Oracle Linux and Debian).
[sshd]
action = smtp[...]
         iptables-multiport  # ✅ Local blocking works for SSH
```

### Benefits of Cloudflare-Only Web Blocking
- ✅ **Global reach**: Blocks attackers at Cloudflare's edge, before they reach your server
- ✅ **True source IP**: Uses `CF-Connecting-IP` header for accurate detection
- ✅ **No firewall pollution**: Doesn't add ineffective rules to local firewall
- ✅ **Faster blocking**: Edge blocking is immediate and global
- ✅ **API-driven**: Automated, programmatic control via Cloudflare WAF Custom Rules API

## Cloudflare Integration

### API Token Requirements

Two separate tokens are required for enhanced security:

#### Token 1: DNS Management (Caddy)
```
Name: VaultWarden DNS Management
Permissions:
  - Zone:DNS:Edit
  - Zone:Zone:Read
Zone Resources:
  - Include → Specific zone → yourdomain.com
```

**Used for**:
- Automatic Let's Encrypt DNS challenge
- Dynamic DNS updates for changing IPs

#### Token 2: Firewall Management (Fail2Ban)
```
Name: VaultWarden Firewall Management
Permissions:
  - Zone:Zone:Read
  - Zone:Firewall Services:Edit
Zone Resources:
  - Include → Specific zone → yourdomain.com
```

**Used for**:
- Creating WAF Custom Rules to block malicious IPs via the Rulesets API
- Managing Cloudflare-level IP access lists
- Automated ban/unban operations

### Cloudflare WAF Custom Rules (Rulesets API)

Fail2Ban uses the current **WAF Custom Rules Rulesets API** — the legacy
`/firewall/access_rules/rules` endpoint is deprecated and no longer used.

Fail2Ban creates rules like:
```
Rule: fail2ban-vaultwarden-auth
Action: Block
Expression: (ip.src in {1.2.3.4 5.6.7.8})
```

These rules:
- Block at Cloudflare edge (never reach your server)
- Apply globally across all Cloudflare edge locations
- Use actual attacker IP from `CF-Connecting-IP` header
- Expire automatically based on `bantime` configuration

#### Verify Cloudflare Firewall Token

```bash
# Verify the token can access the WAF Custom Rules endpoint (Rulesets API)
curl -s -X GET \
  "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/rulesets/phases/http_request_firewall_custom/entrypoint" \
  -H "Authorization: Bearer YOUR_FIREWALL_TOKEN" \
  -H "Content-Type: application/json" | jq .result.id
```

## Encrypted Secrets Management

### Age + SOPS Architecture

All sensitive data is encrypted using industry-standard tools:

```
Age (Encryption)
  ↓
SOPS (Secrets Management)
  ↓
Docker Secrets (Runtime)
  ↓
Containers (Read-Only Access)
```

### Protected Secrets

```yaml
# secrets/secrets.yaml (encrypted)
admin_token: "48-char-alphanumeric-string"
admin_basic_auth_hash: "admin $2b$14$bcrypt_hash"
caddy_cloudflare_dns_token: "cloudflare_dns_token"
fail2ban_cloudflare_firewall_token: "cloudflare_firewall_token"
smtp_password: "smtp_password"
push_installation_id: "optional"
push_installation_key: "optional"
backup_passphrase: "optional"
```

### Enhanced Security Features

The secrets management layer (`lib/secrets.sh`, `edit-secrets.sh edit`, `setup.sh secrets`) implements several hardened behaviours:

- **Umask guard on file creation**: `write_secret_file()` saves and restores the process umask around every secret file write, ensuring files are born at mode `600` — not world-readable at any point.
- **SOPS key scoping**: `decrypt_secret()` unsets `SOPS_AGE_KEY_FILE` immediately after each `sops -d` call so no child process (Docker, rclone, curl) inherits the Age key file path.
- **Key-names-only listing**: `list_secrets()` decodes only YAML key names via `python3/yaml` — secret values are never decrypted into the shell pipeline buffer.
- **Environment cleanup**: `cleanup_secrets_environment()` actively unsets `SOPS_AGE_KEY_FILE` and `SOPS_CONFIG` when called at the end of any secrets workflow. SOPS variables do not persist for the script lifetime.
- **Process privacy**: SOPS key path is never exposed in process list (`ps aux`)
- **Secure temp files**: Proper cleanup of temporary decrypted data via EXIT trap on a dedicated tmpfs path
- **Automatic backups**: Creates backup before editing, using `install -m 600` for atomic secure creation
- **Validation**: Comprehensive checks after editing
- **Editor security**: Validates editor is not running as root

### Managing Secrets

```bash
# Edit secrets securely (recommended)
./edit-secrets.sh edit

# Specify editor
./edit-secrets.sh edit --editor vim

# Validate secrets without editing
./edit-secrets.sh list
# or manually:
sops -d secrets/secrets.yaml > /dev/null && echo "Valid"

# Backup secrets manually
cp secrets/secrets.yaml secrets/secrets.yaml.backup-$(date +%Y%m%d-%H%M%S)
chmod 600 secrets/secrets.yaml.backup-*
```

## Fail2Ban Configuration

### Cloudflare-Only Web Jails

All web-facing jails use Cloudflare API exclusively:

```ini
# iptables removed - ineffective for proxied traffic
[vaultwarden-auth]
action = smtp[name=vaultwarden-auth, ...]
         cloudflare-apiv4

[vaultwarden-admin]
action = smtp[name=vaultwarden-admin, ...]
         cloudflare-apiv4

[vaultwarden-web-auth]
action = smtp[name=vaultwarden-web-auth, ...]
         cloudflare-apiv4
```

### Local iptables for SSH Only

SSH protection uses local iptables (direct connection). Fail2Ban runs with
`network_mode: host` to allow direct host iptables manipulation:

```ini
# SSH is NOT proxied, so iptables works correctly
[sshd]
action = smtp[name=sshd, ...]
         iptables-multiport[name=sshd, port="ssh", protocol=tcp]
```

### Enhanced Detection Capabilities

#### High-Fidelity VaultWarden Log Parsing
```ini
# Direct application log monitoring
[vaultwarden-auth]
logpath  = /var/log/vaultwarden/vaultwarden.log
filter   = vaultwarden-auth
maxretry = 3
bantime  = 2h
```

#### Fail2Ban Filter Notes

- **`vaultwarden-admin.conf`**: `ignoreregex` does **not** suppress `[INFO]` lines — the
  filter is scoped tightly to the exact `Invalid admin token` message only, preventing
  a log-level change in VaultWarden from silently disabling admin brute-force protection.
- **`vaultwarden-web-auth.conf`**: All JSON `failregex` patterns include a `\r?$` anchor
  so detection works correctly on NFS-mounted log volumes (OCI File Storage) where lines
  may end with `\r\n` rather than `\n`.

#### Specialized Caddy Log Monitoring
```ini
# Enhanced forensic logs with long retention
[vaultwarden-web-auth]
logpath  = /var/log/caddy/auth_attempts.log  # 750MB retention
filter   = vaultwarden-web-auth
maxretry = 10

[vaultwarden-web-admin]
logpath  = /var/log/caddy/admin_access.log   # 750MB retention
maxretry = 5
```

### Email Notifications via Postfix

Email alerts are sent via the containerised Postfix relay (`bokysan/docker-postfix`,
port 587). Fail2Ban uses `network_mode: host` and therefore reaches Postfix
at `127.0.0.1:587`:

```ini
# All jails include email notifications
action = smtp[name=jail_name, dest="admin@example.com", sender="fail2ban@domain.com"]
         cloudflare-apiv4  # or iptables-multiport for SSH
```

Benefits:
- ✅ No host dependencies (mailutils not required)
- ✅ Consistent SMTP configuration via a single Postfix relay
- ✅ Dedicated container logs for troubleshooting (`docker compose logs postfix`)
- ✅ Resource-efficient (256MB memory limit, 0.1 CPU)

## Firewall Hardening (UFW)

### Cloudflare IP Whitelist

Only Cloudflare IPs are allowed for web traffic:

```bash
# Allow Cloudflare IPv4 ranges
sudo ufw allow from 173.245.48.0/20 to any port 443 proto tcp
sudo ufw allow from 103.21.244.0/22 to any port 443 proto tcp
# ... (all Cloudflare IPv4 ranges)

# Allow Cloudflare IPv6 ranges
sudo ufw allow from 2400:cb00::/32 to any port 443 proto tcp
# ... (all Cloudflare IPv6 ranges)
```

> **OPERATOR ACTION REQUIRED**: During initial setup, `setup.sh` opens ports 80 and 443
> to all sources. You must restrict those rules to Cloudflare CIDRs after deployment using
> `./maintenance.sh update-firewall` or by running the UFW commands in
> `docker-compose.yml.example` comments.

### SSH Protection

```bash
# SSH access (rate limited)
sudo ufw limit 22/tcp comment 'SSH rate limit'
```

### Safe Firewall Updates

The maintenance script applies new Cloudflare IP ranges **before** removing
old ones to eliminate race conditions:

```bash
# Safe update (targeted mode — skips routine cleanup)
./maintenance.sh update-firewall

# Features:
# 1. Fetches current Cloudflare IPv4 + IPv6 ranges
# 2. Adds new rules BEFORE removing old ones
# 3. Validates ranges with regex before applying
# 4. Falls back safely if API fails
# 5. Comprehensive logging of all changes
```

## Container Security

### Non-Root Execution

All containers run as non-root users:

```yaml
services:
  vaultwarden:
    user: "${PUID}:${PGID}"  # Typically 1000:1000

  caddy:
    user: "${PUID}:${PGID}"

  # postfix uses container-default user; fail2ban uses host networking
```

### Capability Restrictions

Containers drop all capabilities and only add the minimum required:

```yaml
vaultwarden:
  cap_drop:
    - ALL
  # No additional capabilities

caddy:
  cap_drop:
    - ALL
  cap_add:
    - NET_BIND_SERVICE  # Required for ports 80/443

postfix:
  cap_drop:
    - ALL
  cap_add:
    - CHOWN              # Mail queue ownership
    - SETUID             # User switching
    - SETGID             # Group switching
    - NET_BIND_SERVICE   # Port 587
    - DAC_OVERRIDE       # Spool permission overrides (REQUIRED)
    - FOWNER             # Spool file ownership (REQUIRED)

fail2ban:
  # network_mode: host — no cap_drop (host network namespace)
  cap_add:
    - NET_ADMIN  # Required for iptables manipulation
    - NET_RAW    # Required for network monitoring
```

### Resource Limits

Prevents resource exhaustion attacks. Values are tightly optimised:

```yaml
vaultwarden:
  deploy:
    resources:
      limits:
        memory: 512M
        cpus: '0.3'
      reservations:
        memory: 128M
        cpus: '0.1'

caddy:
  deploy:
    resources:
      limits:
        memory: 512M
        cpus: '0.25'
      reservations:
        memory: 128M
        cpus: '0.1'

fail2ban:
  deploy:
    resources:
      limits:
        memory: 512M
        cpus: '0.15'
      reservations:
        memory: 128M
        cpus: '0.05'

postfix:
  deploy:
    resources:
      limits:
        memory: 256M
        cpus: '0.1'
        pids: 50
      reservations:
        memory: 64M
        cpus: '0.02'
```

### Network Isolation (`internal: true`)

By default the `vaultwarden` Docker network is marked `internal: true` in
`docker-compose.yml.example`. This prevents any container on that network from
making outbound connections to the internet.

**What `internal: true` blocks**:
- All outbound internet traffic originating from the VaultWarden, Caddy, or
  Postfix containers
- Any container-initiated calls to external APIs, update servers, or tracking endpoints

**What `internal: true` allows**:
- Container-to-container communication within the `vaultwarden` network (e.g.
  Caddy → VaultWarden, Fail2Ban → Postfix)
- Inbound connections routed through Caddy (Caddy itself has a separate bridge
  network for host port binding)

**Conflict with push notifications**: Push relay requires outbound HTTPS from
the VaultWarden container to `push.bitwarden.com`. When `PUSH_ENABLED=true` is
set in `.env`, the `internal: true` constraint **must be removed** from the
network definition. `startup.sh` detects this combination at launch and exits
with an error if both are present simultaneously. To enable push notifications
while preserving isolation for the other containers, use
`docker-compose.override.yml.example` to override only the network definition:

```yaml
# docker-compose.override.yml — relax internal: true for push notifications only
networks:
  vaultwarden:
    internal: false
```

**Hardening**: If you do not use push notifications, keep `internal: true`
(the default). Verify the setting is active:

```bash
# Confirm the network has no external gateway
docker network inspect vaultwarden-oci_vaultwarden | grep -i internal
# Expected: "Internal": true
```

> See also: [CONFIGURATION.md](CONFIGURATION.md) for `PUSH_ENABLED` details and
> [DEPLOYMENT.md](DEPLOYMENT.md) for post-deployment checklist items related to
> network isolation.

### Security Options

```yaml
security_opt:
  - no-new-privileges:true
```

Applied to all containers. Prevents privilege escalation within containers.

### Log Rotation (Docker Driver)

All runtime containers cap their Docker json-file logs at the driver level
to prevent disk fill:

```yaml
logging:
  driver: "json-file"
  options:
    max-size: "20m"   # caddy: 20m × 5 = 100MB worst-case
    max-file: "5"
# vaultwarden: 10m × 5 = 50MB
# postfix:      5m × 3 = 15MB
# fail2ban:     5m × 3 = 15MB
```

### Systemd Service Hardening

All VaultWarden systemd service units are hardened consistently:

```ini
[Service]
User=root
NoNewPrivileges=yes
PrivateTmp=yes          # Isolated /tmp per service (prevents name collisions)
OnFailure=vaultwarden-notify-failure.service
EnvironmentFile=/etc/vaultwarden/vaultwarden.env
```

- `PrivateTmp=yes` gives each service its own private `/tmp` mount, preventing
  temp-file name collisions between concurrently running backup, health, and
  maintenance units.
- `OnFailure=` is set on **all** service units — including `firewall-update` and
  `dns-update` — so no failure goes unnotified.
- The `vaultwarden-notify-failure.service` template uses `printf` for email body
  construction (bash `"..."` strings do not expand `\n`) and calls `init_common_lib`
  to enable `set -euo pipefail` consistently.

## Application Security

### Admin Panel Protection

Two-factor protection for the admin panel:

1. **Caddy Basic Authentication** (bcrypt hash from secrets):
```caddyfile
@admin path /admin*
handle @admin {
    basic_auth {
        {env.ADMIN_USERNAME} {env.ADMIN_HASH}
    }
    reverse_proxy vaultwarden:80
}
```

2. **Admin Token** (stored in encrypted secrets, minimum 48 characters):
```yaml
admin_token: "48-char-alphanumeric-string"
```

**Bcrypt cost factor**: The bcrypt hash stored in `admin_basic_auth_hash` must use
a cost factor of **≥ 10** (OWASP minimum). `caddy/entrypoint.sh` validates the
cost factor on every container start and exits with an error if it is below 10.
Generate compliant hashes with:
```bash
docker run --rm -it ghcr.io/caddybuilds/caddy-cloudflare:latest caddy hash-password --cost 14
```

**DEBUG_ENTRYPOINT**: The `DEBUG_ENTRYPOINT=true` environment variable logs the
parsed `ADMIN_USERNAME` to Docker stdout. This is for troubleshooting only and
**must not be enabled in production** — it is not set by default. If enabled, a
prominent `WARNING: DEBUG_ENTRYPOINT enabled` banner is emitted to stderr to
remind operators to disable it.

### Rate Limiting (Cloudflare WAF)

Cloudflare WAF rules must be configured manually in the Cloudflare dashboard:

| Rule | Path | Limit | Action |
| :-- | :-- | :-- | :-- |
| Auth endpoint protection | `/identity/connect/token*`, `/api/accounts/prelogin*` | 10 req / 1 min per IP | Block (429) |
| Admin panel protection | `/admin*` | 5 req / 1 min per IP | Block (429) |
| General API protection (optional) | `/api/*` | 100 req / 1 min per IP | Managed Challenge |

### Security Headers

The following hardened security headers are enforced in the Caddyfile:

```caddyfile
header {
    # HSTS with preload
    Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"

    # Classic security headers
    X-Content-Type-Options "nosniff"
    X-Frame-Options "DENY"
    X-XSS-Protection "1; mode=block"
    Referrer-Policy "strict-origin-when-cross-origin"

    # Modern isolation headers (Spectre mitigation)
    Cross-Origin-Opener-Policy "same-origin"
    Cross-Origin-Resource-Policy "same-origin"
    # credentialless (not require-corp) — preserves Spectre isolation while
    # allowing cross-origin WebAuthn/passkey flows without blocking them.
    Cross-Origin-Embedder-Policy "credentialless"
    X-DNS-Prefetch-Control "off"

    # Content Security Policy — connect-src is scoped to known endpoints only.
    # wss: is replaced with wss://{$DOMAIN_NAME} to prevent XSS exfiltration
    # to arbitrary WebSocket hosts.
    Content-Security-Policy "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self' wss://{$DOMAIN_NAME} https://push.bitwarden.com https://identity.bitwarden.com; frame-src 'self'; object-src 'none'; base-uri 'self';"

    # Permissions Policy (restrict dangerous features)
    Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=(), usb=()"

    # Request tracking (response header)
    X-Request-ID {uuid}

    # Remove server identification
    -Server
    -X-Powered-By
}
```

> **Note**: The `Content-Security-Policy connect-src` directive includes
> `https://push.bitwarden.com` and `https://identity.bitwarden.com` only when
> `PUSH_ENABLED=true`. If push notifications are disabled, those external endpoints
> are not needed in the CSP. Review your configuration if you do not use push.

## Forensic Logging

### 4-Log Forensic Architecture (~3 GB Total Capacity)

Caddy routes log output to dedicated files per category, enabling per-category
retention targets.

```
Main Access Log:   50MB × 20 files = 1GB    (30-day retention)   → access.log
Admin Access Log:  25MB × 30 files = 750MB  (90-day retention)   → admin_access.log
Auth Attempts Log: 25MB × 30 files = 750MB  (90-day retention)   → auth_attempts.log
Security Log:      10MB × 50 files = 500MB  (180-day retention)  → security.log
```

### Structured JSON Logging

All Caddy logs use structured JSON format for easy parsing:

```json
{
  "level": "info",
  "ts": "2024-11-10T14:30:15.123Z",
  "request": {
    "remote_ip": "1.2.3.4",
    "remote_port": "54321",
    "client_ip": "1.2.3.4",
    "proto": "HTTP/2.0",
    "method": "POST",
    "host": "vault.example.com",
    "uri": "/api/accounts/prelogin",
    "headers": {
      "User-Agent": ["..."],
      "Cf-Connecting-Ip": ["1.2.3.4"]
    }
  },
  "duration": 0.123,
  "status": 401
}
```

### Log Locations

```bash
# VaultWarden application logs
${PROJECT_STATE_DIR}/logs/vaultwarden/vaultwarden.log

# Caddy logs (4 forensic log files)
${PROJECT_STATE_DIR}/logs/caddy/access.log        # General access (main site)
${PROJECT_STATE_DIR}/logs/caddy/admin_access.log  # Admin panel traffic
${PROJECT_STATE_DIR}/logs/caddy/auth_attempts.log # Auth endpoints
${PROJECT_STATE_DIR}/logs/caddy/security.log      # Direct-IP / catch-all block

# Fail2Ban logs
${PROJECT_STATE_DIR}/logs/fail2ban/fail2ban.log

# Postfix logs
${PROJECT_STATE_DIR}/logs/postfix/
docker compose logs postfix   # live container output
```

---

## Caddy Configuration Reference

The Caddyfile lives at `caddy/Caddyfile` and is injected into the container as a bind
mount. `caddy/entrypoint.sh` substitutes environment variables (e.g. `{$DOMAIN_NAME}`,
`{$PUSH_CSP}`) before Caddy starts, so the file on disk contains literal placeholder
strings — the resolved values only exist inside the running container.

### File Location

```
caddy/
├── Caddyfile       # Main Caddy configuration (bind-mounted into container)
└── entrypoint.sh   # Variable substitution + bcrypt cost validation on startup
```

> ⚠️ **Do not edit the Caddyfile inside the running container.** Changes made there are
> lost on restart. Edit `caddy/Caddyfile` in the project directory and run
> `make restart` to apply.

### Caddyfile Structure

The file is divided into four top-level blocks:

| Block | Purpose |
| :-- | :-- |
| `{ … }` (global options) | ACME DNS provider, trusted proxy config, 4-log forensic architecture |
| `127.0.0.1:8080 { … }` | Internal health check endpoint (loopback only, not internet-accessible) |
| `{$DOMAIN_NAME} { … }` | Main site — security headers, routing, admin auth, WebSocket, catch-all |
| `www.{$DOMAIN_NAME} { … }` | Permanent redirect www → apex |
| `:80, :443 { … }` | Catch-all that returns 404 for direct-IP access |

### Route Handlers (Main Site Block)

Routes are evaluated in declaration order. Each handler uses `handle` (exclusive match)
so only the first matching block fires:

| # | Matcher | Handler | Log target |
| :-- | :-- | :-- | :-- |
| 1 | `@health path /alive` | `reverse_proxy vaultwarden:80` | `access_log` |
| 2 | `handle /notifications/hub` | `reverse_proxy vaultwarden:80` (WebSocket headers forwarded) | `access_log` |
| 3 | `@admin path /admin*` | `basic_auth` → `reverse_proxy vaultwarden:80` | `admin_log` |
| 4 | `@auth_endpoints path /api/accounts/prelogin* /identity/connect/token*` | `reverse_proxy vaultwarden:80` | `auth_log` |
| 5 | `handle` (default) | `reverse_proxy vaultwarden:80` | `access_log` |

All `reverse_proxy` blocks unconditionally set `CF-Connecting-IP`, `X-Real-IP`,
`X-Forwarded-For`, and `X-Request-ID` upstream headers using Caddy's resolved
`{client_ip}` placeholder (derived from `trusted_proxies cloudflare` +
`client_ip_headers Cf-Connecting-Ip`). This ensures VaultWarden always receives
a non-empty, validated real IP regardless of upstream header content.

### Adding a Custom Route

To add a custom path — for example, exposing a status page at `/status` — add a
new `handle` block **before** the default catch-all in `caddy/Caddyfile`:

```caddyfile
# Custom route example — add BEFORE the default handle {} block
@status path /status
handle @status {
    log_name access_log
    respond "OK" 200
}
```

Then apply:
```bash
make restart
# Verify config parses correctly before restarting:
make test-config
```

> **Route ordering matters.** Caddy's `handle` directive uses exclusive matching —
> place more-specific routes above the default `handle {}` block or they will never
> fire.

### Adjusting Rate Limiting

Rate limiting for web traffic is enforced at the **Cloudflare WAF layer**, not
inside the Caddyfile. To adjust limits:

1. Go to **Cloudflare Dashboard → Security → WAF → Rate limiting rules**
2. Locate the relevant rule (auth endpoints, admin panel, general API)
3. Update the threshold and period

The Caddyfile itself does not contain `rate_limit` directives. The `[vaultwarden-rate-limit]`
Fail2Ban jail provides a secondary, coarser rate guard (30 requests / 1 min) at the
application layer for cases where Cloudflare WAF rules have not yet fired.

### Push Notifications and `internal: true`

When `PUSH_ENABLED=true` is set in `.env`, the VaultWarden Docker network **must not**
be marked `internal: true`. Push relay requires outbound HTTPS to `push.bitwarden.com`.
`startup.sh` enforces this at launch and exits with an error if the combination is
detected. `entrypoint.sh` also conditionally sets `{$PUSH_CSP}` — an empty string when
push is disabled, or the Bitwarden push endpoints when enabled — so the
`Content-Security-Policy` header does not unnecessarily widen its `connect-src`
attack surface for non-push deployments.

---

## Fail2Ban Configuration Reference

The Fail2Ban configuration lives entirely under `fail2ban/` and is bind-mounted
into the `crazymax/fail2ban` container at startup.

### Directory Layout

```
fail2ban/
├── jail.d/
│   └── vaultwarden-oci.conf      # All jail definitions (single file)
├── filter.d/
│   ├── vaultwarden-auth.conf     # VaultWarden app log — login failures
│   ├── vaultwarden-admin.conf    # VaultWarden app log — admin token failures
│   ├── vaultwarden-web-auth.conf # Caddy JSON log — web auth/API failures
│   ├── vaultwarden-web-admin.conf# Caddy JSON log — admin path access
│   ├── vaultwarden-web-caddy.conf# Legacy combined filter (kept for reference; not used by active jails)
│   └── vaultwarden-security.conf # Caddy JSON log — catch-all security events
└── action.d/
    ├── cloudflare-apiv4.conf     # Cloudflare WAF Rulesets API ban/unban action
    ├── cloudflare-apiv4-helpers.sh # Shell helpers called by the action
    ├── smtp.conf                 # Email notification action (Postfix on 127.0.0.1:587)
    └── smtp_notify.py            # Python email helper used by smtp.conf
```

### Active Jails and What They Target

| Jail | Log source | Filter | `maxretry` / `bantime` | Ban method |
| :-- | :-- | :-- | :-- | :-- |
| `sshd` | `/var/log/ssh-auth.log` | `sshd` (built-in) | 3 / 24 h | local `iptables-multiport` |
| `sshd-custom` | `/var/log/ssh-auth.log` | `sshd` (built-in) | 3 / 24 h | local `iptables-multiport` — **disabled by default** |
| `vaultwarden-auth` | VaultWarden app log | `vaultwarden-auth` | 3 / 2 h | Cloudflare WAF |
| `vaultwarden-admin` | VaultWarden app log | `vaultwarden-admin` | 2 / 24 h | Cloudflare WAF |
| `vaultwarden-web-auth` | `caddy/access.log` | `vaultwarden-web-auth` | 10 / 1 h | Cloudflare WAF |
| `vaultwarden-web-admin` | `caddy/access.log` | `vaultwarden-web-admin` | 5 / 24 h | Cloudflare WAF |
| `vaultwarden-rate-limit` | `caddy/access.log` | `vaultwarden-web-auth` (reused) | 30 / 30 min | Cloudflare WAF |
| `vaultwarden-security` | `caddy/access.log` | `vaultwarden-security` | 1 / 48 h | Cloudflare WAF |
| `recidive` | Fail2Ban's own log | `recidive` (built-in) | 5 / 1 week | Cloudflare WAF |

> **Dual-jail design for auth endpoints**: `vaultwarden-web-auth` (failure-based,
> `maxretry=10/5m`) and `vaultwarden-rate-limit` (volume-based, `maxretry=30/1m`)
> intentionally share the same filter and log file. Each enforces a distinct policy —
> credential failures vs raw request volume — and both incrementing the same log line
> is correct behaviour.

### Dedicated Filters Prevent Double-Fire

Each jail uses its **own dedicated filter** to prevent a single log line from
incrementing multiple jails' counters simultaneously (double-fire). The legacy
`vaultwarden-web-caddy.conf` filter was shared across both `web-auth` and `web-admin`
and caused this problem; it is kept in `filter.d/` for reference only and is not
referenced by any active jail.

### Cloudflare WAF Ban Flow

When a web jail threshold is reached:

1. Fail2Ban calls `cloudflare-apiv4.conf` `actionban`
2. `cloudflare-apiv4-helpers.sh` reads the API token from the Docker secret file
   (`/run/secrets/fail2ban_cloudflare_firewall_token`) — never from an environment variable
3. A WAF Custom Rule is created via the **Rulesets API**:
   `PATCH /zones/{zone_id}/rulesets/phases/http_request_firewall_custom/entrypoint`
4. The rule expression `(ip.src in {<banned_ip>})` blocks the IP at Cloudflare's edge
5. On `actionunban`, the rule is removed (or the IP removed from the expression list)

The `bantime` in each jail controls how long the rule persists. Fail2Ban manages
removal automatically — no manual Cloudflare dashboard intervention is required.

### Adding a Custom Jail

1. **Create a filter** in `fail2ban/filter.d/my-custom.conf`:

```ini
[Definition]
# Match lines from Caddy's JSON access log
# {client_ip} field holds the real visitor IP (resolved by Caddy from CF-Connecting-IP)
failregex = ^\{.*"client_ip":"<HOST>".*"uri":"/my-path.*"status":4\d\d.*\}$
ignoreregex =
```

2. **Add a jail** in `fail2ban/jail.d/vaultwarden-oci.conf`:

```ini
[my-custom-jail]

enabled  = true
filter   = my-custom
port     = 80,443
logpath  = /var/log/caddy/access.log
maxretry = 5
bantime  = 1h
findtime = 10m

action = smtp[name=my-custom-jail, dest="%(destemail)s", sender="%(sender)s", host="127.0.0.1", port=587]
         cloudflare-apiv4
```

3. **Reload Fail2Ban** inside the container:

```bash
docker compose exec fail2ban fail2ban-client reload

# Verify the jail is active
docker compose exec fail2ban fail2ban-client status my-custom-jail

# Test your filter regex against a live log sample
docker compose exec fail2ban fail2ban-regex \
  /var/log/caddy/access.log \
  /data/fail2ban/filter.d/my-custom.conf
```

> **Custom jail checklist:**
> - Use a **dedicated filter** — never reuse an existing filter for a new jail unless
>   you explicitly want both jails to increment on the same log line (as with `vaultwarden-rate-limit`).
> - Include `\r?$` at the end of every `failregex` pattern to handle `\r\n` line endings
>   on NFS-mounted log volumes (OCI File Storage).
> - For SSH jails on a non-standard port, disable `[sshd]` before enabling `[sshd-custom]`
>   to avoid both jails counting the same log lines and halving the effective `maxretry`.

---

## Emergency Access

### Break-Glass Admin Account

A dedicated emergency admin account for OCI serial console access:

#### Features
- Separate non-root user with sudo privileges
- SSH key authentication for normal access
- Password authentication enabled ONLY for OCI console
- Secure credential generation
- Comprehensive audit logging

#### Creating Break-Glass Admin

```bash
# Create emergency admin
sudo utilities/create-breakglass-admin.sh create

# Or use Makefile
make breakglass-create

# Check status
sudo utilities/create-breakglass-admin.sh status
make breakglass-status
```

#### Using Break-Glass Admin

**Scenario**: Locked out of SSH (firewall issue)

1. Access OCI Console → Compute → Instance → Console Connection
2. Create console connection if not exists
3. Launch Cloud Shell connection
4. Login with break-glass admin credentials
5. Fix the issue (e.g., `sudo ufw allow 22/tcp`)
6. Verify SSH access restored
7. **CRITICAL**: Delete console connection
8. Rotate break-glass admin password

#### Security Considerations

- ✅ Only use for emergencies
- ✅ Delete console connection immediately after use
- ✅ Rotate password after each use
- ✅ Monitor audit logs for unauthorized access
- ✅ Validate break-glass admin security quarterly

## Backup Security

### Encrypted Backups

All backups are encrypted with Age:

```
Backup process:
1. WAL checkpoint (TRUNCATE) on live database — verified before proceeding
2. Consistent DB snapshot via SQLite Online Backup API (.backup dot-command)
   — acquires shared read lock, integrates WAL frames atomically
3. Compress snapshot with zstd
4. Encrypt with Age (recipient: age public key from secrets/keys/age-key.txt)
5. Write SHA-256 checksum sidecar (.sha256)
6. Write metadata sidecar (.meta) — includes VaultWarden version, hostname, timestamp
7. Quick verification — decrypt probe to /dev/null (Age key MUST exist; missing key
   is a hard failure, not a soft warning)
8. Cleanup temporary files securely from private tmpdir
```

> **Backup integrity note**: `verify_backup_integrity()` in `lib/backup-utils.sh`
> uses the SQLite Online Backup API (`.backup` dot-command) rather than OS-level
> `cp` to create the verification snapshot. This holds the correct shared read lock
> and guarantees a consistent copy even while VaultWarden is actively writing.

### Backup Retention

Retention age is determined from the **filename-embedded timestamp**
(`YYYYMMDD-HHMMSS`), which is immutable across `cp`, `mv`, `chmod`, and `chown`.
`ctime`-based fallback is used only for files predating the current naming convention.
This ensures backups restored to a fresh host are not treated as brand-new and
excluded from retention enforcement.

### Backup Verification

```bash
# Standard backup (checksum-based verification + Age decrypt probe)
./backup.sh run db

# Full backup with end-to-end recoverability test
./backup.sh run full --full-verification

# Verification process (--full-verification):
1. SHA-256 checksum check
2. Decrypt backup with Age key
3. Extract and decompress
4. Verify SQLite database integrity (Online Backup API snapshot, WAL-safe)
5. Confirm all expected files present
6. Cleanup test environment
```

### Remote Backup Security

```bash
# Configure encrypted remote storage
rclone config

# Backup with remote sync
./backup.sh run db --rclone

# Security features:
# - Encrypted BEFORE upload (Age encryption at rest)
# - TLS in transit to remote
# - Access token secured in rclone config
```

## Security Monitoring

### Health Checks

```bash
# Basic health check (containers + service accessibility)
./maintenance.sh health

# Comprehensive check (adds disk, SSL, DB, backups, resources, config, security)
./maintenance.sh health --comprehensive

# With automatic recovery of unhealthy containers
./maintenance.sh health --fix

# Full comprehensive check with auto-recovery
# (this is what the systemd vaultwarden-health timer runs)
./maintenance.sh health --comprehensive --fix
```

Checks performed:
- All containers running and healthy (`vaultwarden`, `caddy`, `fail2ban`, `postfix`)
- Local service accessibility on port 8080
- Disk space against configurable threshold (default 80%)
- SSL certificate expiry (warn < 30 days, critical < 7 days)
- Database size and growth rate
- Backup age and decryptability
- Resource usage (comprehensive mode)
- Configuration validity (comprehensive mode)
- Security status: Fail2Ban, Age key, SOPS config (comprehensive mode)

### Monitoring Fail2Ban

```bash
# Check ban status across all jails
docker compose exec fail2ban fail2ban-client status

# View specific jail bans
docker compose exec fail2ban fail2ban-client status vaultwarden-auth

# Check Cloudflare integration
docker compose logs fail2ban | grep -i cloudflare

# View banned IPs for a jail
docker compose exec fail2ban fail2ban-client get vaultwarden-auth banip
```

### Log Analysis

```bash
# View authentication failures
cat ${PROJECT_STATE_DIR}/logs/caddy/auth_attempts.log | jq 'select(.status == 401)'

# View admin panel access
cat ${PROJECT_STATE_DIR}/logs/caddy/admin_access.log | jq

# View security events
cat ${PROJECT_STATE_DIR}/logs/caddy/security.log | jq 'select(.status >= 400)'

# Analyse VaultWarden logs
grep "ERROR" ${PROJECT_STATE_DIR}/logs/vaultwarden/vaultwarden.log
```

## Security Best Practices

### Initial Setup
- ✅ Generate bcrypt hash with cost factor ≥ 14 for admin basic auth
- ✅ Use separate Cloudflare API tokens (DNS and Firewall)
- ✅ Enable Cloudflare proxy (orange cloud) for DNS record
- ✅ Configure HTTPS-only redirect at Cloudflare
- ✅ Enable Cloudflare WAF managed rules
- ✅ Configure WAF rate limiting rules (auth, admin, API)
- ✅ Set up break-glass admin immediately
- ✅ Test emergency access procedures
- ✅ Create initial encrypted backup
- ✅ Configure email notifications and run `make test-email`
- ✅ Verify all health checks pass: `./maintenance.sh health --comprehensive`
- ✅ Restrict UFW ports 80/443 to Cloudflare CIDRs: `./maintenance.sh update-firewall`
- ✅ Confirm `internal: true` is active on the Docker network (unless push is enabled)

### Ongoing Operations
- ✅ Monitor Fail2Ban logs weekly
- ✅ Review Cloudflare analytics monthly
- ✅ Test backup restoration monthly
- ✅ Rotate secrets annually
- ✅ Update containers weekly (automated via systemd timer)
- ✅ Review firewall rules quarterly
- ✅ Test emergency procedures quarterly
- ✅ Monitor resource usage monthly
- ✅ Review forensic logs for incidents
- ✅ Keep break-glass admin credentials secure
- ✅ Run `sudo ./setup.sh systemd validate` after pulling repo updates

### Incident Response

If you detect suspicious activity:

1. **Immediate Actions**:
   ```bash
   # Check Fail2Ban status
   docker compose exec fail2ban fail2ban-client status

   # Review recent bans
   docker compose logs fail2ban --tail=100

   # Check for unauthorized access
   grep "401\|403\|404" ${PROJECT_STATE_DIR}/logs/caddy/access.log
   ```

2. **Analysis**:
   ```bash
   # Analyse authentication failures
   cat ${PROJECT_STATE_DIR}/logs/caddy/auth_attempts.log | jq

   # Check admin panel access
   cat ${PROJECT_STATE_DIR}/logs/caddy/admin_access.log | jq

   # Review VaultWarden logs
   tail -n 500 ${PROJECT_STATE_DIR}/logs/vaultwarden/vaultwarden.log
   ```

3. **Response**:
   ```bash
   # Manual ban if needed (Cloudflare)
   # Use Cloudflare dashboard → Security → WAF → Tools
   # Add IP to IP Access Rules → Block

   # Emergency: Disable user accounts
   # Access admin panel → Users → Disable

   # Create incident backup
   ./backup.sh run emergency
   ```

4. **Recovery**:
   ```bash
   # If compromised, rotate all secrets
   ./edit-secrets.sh edit

   # Update admin token and hash
   # Restart services
   ./startup.sh --force

   # Verify security
   ./maintenance.sh health --comprehensive
   ```

## Security Troubleshooting

### Cloudflare API Issues

```bash
# Test DNS token
curl -X GET "https://api.cloudflare.com/client/v4/zones" \
     -H "Authorization: Bearer YOUR_DNS_TOKEN" \
     -H "Content-Type: application/json"

# Test Firewall token against the current WAF Custom Rules endpoint
curl -X GET "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/rulesets/phases/http_request_firewall_custom/entrypoint" \
     -H "Authorization: Bearer YOUR_FIREWALL_TOKEN" \
     -H "Content-Type: application/json"
```

### Fail2Ban Not Blocking

```bash
# Check Cloudflare action is configured (uses Rulesets API — not legacy access_rules)
docker compose exec fail2ban cat /data/fail2ban/action.d/cloudflare-apiv4.conf

# Verify zone ID and token
docker compose exec fail2ban env | grep CF_

# Test filter regex against live VaultWarden log
docker compose exec fail2ban fail2ban-regex \
  /var/log/vaultwarden/vaultwarden.log \
  /data/fail2ban/filter.d/vaultwarden-auth.conf

# Test filter regex against live Caddy JSON log
docker compose exec fail2ban fail2ban-regex \
  /var/log/caddy/auth_attempts.log \
  /data/fail2ban/filter.d/vaultwarden-web-auth.conf

# Check for errors
docker compose logs fail2ban | grep -i error
```

### Email Notifications Not Working

```bash
# Check postfix container status and logs
docker compose ps postfix
docker compose logs postfix          # live output
make logs-postfix                    # shortcut

# Run full email diagnostic (4 tests)
./maintenance.sh test-email

# Verbose output for detailed diagnosis
./maintenance.sh test-email --verbose

# Test with specific recipient
./maintenance.sh test-email --recipient admin@example.com

# Preview without sending (dry-run)
./maintenance.sh test-email --dry-run

# Verify SMTP settings in .env
grep -E 'SMTP|POSTFIX|ALLOWED_SENDER' .env

# Verify SMTP password in secrets
./edit-secrets.sh edit
```

## Compliance and Hardening

### CIS Docker Benchmark Alignment

- ✅ Containers run as non-root
- ✅ Capabilities dropped and minimally added
- ✅ Resource limits configured (memory, CPU, PIDs)
- ✅ Security options enabled (`no-new-privileges:true`)
- ✅ Secrets not in environment variables (Docker secrets via files)
- ✅ Docker json-file log rotation caps applied
- ✅ Minimal images used
- ✅ Health checks configured on all containers

### Additional Hardening

For additional security:

```bash
# Enable audit logging
sudo apt install auditd
sudo systemctl enable auditd

# Install additional security tools
sudo apt install aide rkhunter

# Configure automatic security updates
sudo apt install unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

---

This security guide reflects the current architecture with Cloudflare-only blocking for web traffic, local iptables for SSH (Fail2Ban in host-network mode), containerised Postfix email relay, comprehensive resource management, enhanced forensic logging, systemd-hardened service units, and robust security practices optimised for small teams requiring enterprise-grade password management security.
