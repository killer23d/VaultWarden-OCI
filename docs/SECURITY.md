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
│   Layer 4: CrowdSec Monitoring          │
│   - Cloudflare-ONLY for Web Traffic    │
│   - Local iptables ONLY for SSH         │
│   - Behavioural Log Analysis            │
│   - Three-Layer Defence                 │
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

CrowdSec detects threats from logs and issues ban decisions. The
`cs-cloudflare-bouncer` then blocks IPs at Cloudflare's edge via the WAF
Custom Rules Rulesets API:

```bash
# Check active web bans
sudo cscli decisions list --type ban

# Check Cloudflare bouncer is applying bans
sudo journalctl -u cs-cloudflare-bouncer | grep -i "add\|block"
```

#### SSH Traffic (Direct, NOT Proxied)

```bash
# SSH is NOT proxied, so iptables works correctly
# crowdsec-firewall-bouncer inserts iptables rules on the host
sudo systemctl status crowdsec-firewall-bouncer
sudo iptables -L CROWDSEC_CHAIN -n
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

#### Token 2: Firewall Management (CrowdSec)
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

CrowdSec cloudflare-bouncer uses the current **WAF Custom Rules Rulesets API** — the legacy
`/firewall/access_rules/rules` endpoint is deprecated and no longer used.

CrowdSec creates rules like:
```
Rule: crowdsec-ban
Action: Block
Expression: (ip.src in {1.2.3.4 5.6.7.8})
```

These rules:
- Block at Cloudflare edge (never reach your server)
- Apply globally across all Cloudflare edge locations
- Use actual attacker IP from `CF-Connecting-IP` header
- Expire automatically based on CrowdSec decision duration

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
crowdsec_cf_firewall_token: "cloudflare_firewall_token"  # used by cs-cloudflare-bouncer
smtp_password: "smtp_password"
push_installation_id: "optional"
push_installation_key: "optional"
backup_passphrase: "optional"
```

### Enhanced Security Features

The secrets management layer (`lib/secrets.sh`, `utilities/secrets-edit.sh`, `setup.sh secrets`) implements several hardened behaviours:

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
./utilities/secrets-edit.sh

# Specify editor
./utilities/secrets-edit.sh --editor vim

# Validate secrets without editing
./utilities/secrets-list.sh
# or manually:
sops -d secrets/secrets.yaml > /dev/null && echo "Valid"

# Backup secrets manually
cp secrets/secrets.yaml secrets/secrets.yaml.backup-$(date +%Y%m%d-%H%M%S)
chmod 600 secrets/secrets.yaml.backup-*
```

## CrowdSec Detection Configuration

### Cloudflare-Only Web Bans

CrowdSec detects threats from VaultWarden and Caddy logs. All web-facing ban
decisions are executed via the Cloudflare WAF (`cs-cloudflare-bouncer`):

```bash
# Check active decisions
sudo cscli decisions list

# Check alerts from web-auth scenarios
sudo cscli alerts list --scenario crowdsecurity/http-bf-wordpress_bf_xmlrpc
```

### Local iptables for SSH Only

SSH protection uses local iptables (direct connection, not proxied through
Cloudflare). The `crowdsec-firewall-bouncer` inserts host iptables rules:

```bash
# SSH is NOT proxied, so iptables works correctly
sudo systemctl status crowdsec-firewall-bouncer
sudo iptables -L CROWDSEC_CHAIN -n
```

### CrowdSec Collections

CrowdSec uses collections of parsers and scenarios for detection:

```bash
# List installed collections
sudo cscli collections list

# Update hub (parsers, scenarios, collections)
sudo cscli hub update && sudo cscli hub upgrade
```

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

  # postfix uses container-default user; CrowdSec runs as a host systemd service
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
```

> **CrowdSec** runs as a host systemd service and manages its own capabilities via systemd unit configuration — it is not a Docker container.

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
  Caddy → VaultWarden)
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
```

### Systemd Service Hardening

All VaultWarden systemd service units are hardened consistently:

```ini
[Service]
# Runtime jobs run as the service user by default (ubuntu).
# Root is reserved for explicitly privileged units (e.g. firewall updates).
User=ubuntu
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

# CrowdSec logs (host systemd service)
sudo journalctl -u crowdsec

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

Rate limiting for web traffic is enforced at two layers:

1. **Caddy `rate_limit`** — fast, in-process request throttling (module `mholt/caddy-ratelimit`)
2. **Cloudflare WAF Rate Limiting** — edge-level enforcement

To adjust Cloudflare WAF limits:

1. Go to **Cloudflare Dashboard → Security → WAF → Rate limiting rules**
2. Locate the relevant rule (auth endpoints, admin panel, general API)
3. Update the threshold and period

### Push Notifications and `internal: true`

When `PUSH_ENABLED=true` is set in `.env`, the VaultWarden Docker network **must not**
be marked `internal: true`. Push relay requires outbound HTTPS to `push.bitwarden.com`.
`startup.sh` enforces this at launch and exits with an error if the combination is
detected. `entrypoint.sh` also conditionally sets `{$PUSH_CSP}` — an empty string when
push is disabled, or the Bitwarden push endpoints when enabled — so the
`Content-Security-Policy` header does not unnecessarily widen its `connect-src`
attack surface for non-push deployments.

---

## CrowdSec Configuration Reference

CrowdSec runs as a **host systemd service** (not a Docker container) and provides
behavioural threat detection with automated response via bouncers.

### Three-Layer Defence

```
Caddy rate_limit → CrowdSec detection → Cloudflare/iptables ban
```

| Layer | Mechanism | What it blocks |
| :-- | :-- | :-- |
| 1 — Caddy `rate_limit` | Module `mholt/caddy-ratelimit` | Burst/volume traffic before it reaches VaultWarden |
| 2 — CrowdSec detection | Parses logs; runs LAPI scenarios | Identifies brute-force, scanning, and exploit attempts |
| 3 — Cloudflare/iptables ban | `cs-cloudflare-bouncer` + `crowdsec-firewall-bouncer` | Blocks IPs at Cloudflare edge and host iptables |

### Key Commands

```bash
# List active bans
sudo cscli decisions list

# List recent alerts
sudo cscli alerts list

# List registered bouncers
sudo cscli bouncers list

# Check CrowdSec service status
sudo systemctl status crowdsec

# View live logs
sudo journalctl -u crowdsec -f

# Manually ban an IP (expires after 4h by default)
sudo cscli decisions add --ip 1.2.3.4 --duration 4h --reason "manual ban"

# Unban an IP
sudo cscli decisions delete --ip 1.2.3.4
```

### Cloudflare Bouncer

The `cs-cloudflare-bouncer` reads the Cloudflare API token from
`${PROJECT_STATE_DIR}/secrets/.docker_secrets/crowdsec_cf_firewall_token`
and creates WAF Custom Rules via the Rulesets API when CrowdSec issues ban decisions.

```bash
# Check bouncer status
sudo systemctl status cs-cloudflare-bouncer

# View bouncer logs
sudo journalctl -u cs-cloudflare-bouncer -f
```

### Firewall Bouncer (SSH / iptables)

The `crowdsec-firewall-bouncer` enforces iptables bans on the host for SSH
and any traffic CrowdSec flags at the network layer.

```bash
# Check bouncer status
sudo systemctl status crowdsec-firewall-bouncer

# View current iptables rules inserted by bouncer
sudo iptables -L CROWDSEC_CHAIN -n
```

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
sudo utilities/setup-secrets.sh breakglass create

# Or use Makefile
make breakglass-create

# Check status
sudo utilities/setup-secrets.sh breakglass status
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
- All containers running and healthy (`vaultwarden`, `caddy`, `postfix`)
- Local service accessibility on port 8080
- Disk space against configurable threshold (default 80%)
- SSL certificate expiry (warn < 30 days, critical < 7 days)
- Database size and growth rate
- Backup age and decryptability
- Resource usage (comprehensive mode)
- Configuration validity (comprehensive mode)
- Security status: CrowdSec, Age key, SOPS config (comprehensive mode)

### Monitoring CrowdSec

```bash
# Check active bans and recent alerts
sudo cscli decisions list
sudo cscli alerts list

# Check Cloudflare bouncer integration
sudo journalctl -u cs-cloudflare-bouncer | grep -i cloudflare

# View active bans for a specific IP
sudo cscli decisions list --ip 1.2.3.4
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
- ✅ Monitor CrowdSec alerts weekly
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
   # Check CrowdSec ban status
   sudo cscli decisions list

   # Review recent alerts
   sudo cscli alerts list --limit 20

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
   ./utilities/secrets-edit.sh

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

### CrowdSec Not Blocking

```bash
# Check CrowdSec service status
sudo systemctl status crowdsec

# Check Cloudflare bouncer status
sudo systemctl status cs-cloudflare-bouncer

# Verify Cloudflare token is readable
cat ${PROJECT_STATE_DIR}/secrets/.docker_secrets/crowdsec_cf_firewall_token

# Check for errors in CrowdSec logs
sudo journalctl -u crowdsec | grep -i error

# Check decisions are being issued
sudo cscli decisions list
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
./utilities/secrets-edit.sh
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

This security guide reflects the current architecture with Cloudflare-only blocking for web traffic, CrowdSec host service for threat detection and iptables SSH protection, containerised Postfix email relay, comprehensive resource management, enhanced forensic logging, systemd-hardened service units, and robust security practices optimised for small teams requiring enterprise-grade password management security.
