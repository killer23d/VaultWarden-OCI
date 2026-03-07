# Configuration Reference — VaultWarden-OCI

This guide reflects the current configuration model for the project: template-generated runtime files, non-sensitive settings in `.env`, and encrypted secret material managed through Age + SOPS.

Related docs: [DEPLOYMENT.md](DEPLOYMENT.md) · [ADVANCED-CUSTOMIZATION.md](ADVANCED-CUSTOMIZATION.md) · [SECURITY.md](SECURITY.md)

---

## Configuration model

Treat configuration as three layers:

| Layer | Purpose | How it is managed |
| :-- | :-- | :-- |
| `.example` templates | Source of truth for generated runtime files | Edit in the repo, then regenerate with `setup.sh` |
| `.env` | Non-sensitive deployment settings | Review after setup; regenerate from `.env.example` as needed |
| `secrets/secrets.yaml` | Sensitive values | Manage only through `setup-secrets.sh` or `edit-secrets.sh` |

Generated runtime files are deployment artifacts, not the long-term source of truth.

---

## Normal workflow

Use this flow when changing configuration:

```bash
# 1. Update templates or review generated .env
nano .env.example
nano docker-compose.yml.example
nano docker-compose.override.yml.example

# 2. Reapply generated config
sudo ./setup.sh --force --domain vault.example.com --email admin@example.com

# 3. Restart and validate
./startup.sh --force
./health.sh
```

For secret-only changes, use the secrets tooling and skip template regeneration unless the non-secret config also changed.

---

## Core identity settings

These values define the deployment identity and should be reviewed early in every install:

```bash
DOMAIN=https://vault.yourdomain.com
DOMAIN_NAME=vault.yourdomain.com
ADMIN_EMAIL=admin@yourdomain.com
CLOUDFLARE_ZONE_ID=your_zone_id_here
```

Keep `DOMAIN` as the full HTTPS URL and `DOMAIN_NAME` as the bare hostname.

---

## Host and path settings

Common deployment-level settings include:

```bash
PUID=1000
PGID=1000
PROJECT_STATE_DIR=/var/lib/vaultwarden
TZ=UTC
SSH_PORT=22
SSH_LOG_PATH=/var/log/secure
```

`SSH_LOG_PATH` can vary by platform. OCI and Oracle Linux commonly use `/var/log/secure`, while Ubuntu commonly uses `/var/log/auth.log`.

---

## Version settings

The project supports both controlled pinning and newer-image workflows.

Typical version variables include:

```bash
VAULTWARDEN_VERSION=1.34.3
CADDY_VERSION=2.10.2
FAIL2BAN_VERSION=1.1.0
POSTFIX_VERSION=4.4.0
```

For conservative production operation, keep explicit versions and apply changes through `./update.sh`. If you intentionally want newer image behavior during setup generation, use `setup.sh --use-latest`.

---

## Secret management

Sensitive values belong in encrypted secrets, not in `.env`.

Primary tools:

```bash
./setup-secrets.sh
./edit-secrets.sh
./edit-secrets.sh --test
./edit-secrets.sh --list
```

Common secret fields include:

| Secret | Purpose |
| :-- | :-- |
| `admin_basic_auth_hash` | Protects the admin surface |
| `caddy_cloudflare_dns_token` | Cloudflare DNS/TLS integration |
| `fail2ban_cloudflare_firewall_token` | Edge-ban automation |
| `smtp_password` | SMTP relay authentication |
| `push_installation_id` | Push notification support |
| `push_installation_key` | Push notification support |

For `--auto` installations, locally generated credentials may already exist, but external-service secrets still need to be filled in explicitly.

---

## Email settings

Mail is handled through the containerized Postfix relay used by the deployment.

Common non-secret SMTP settings belong in `.env`:

```bash
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_SECURITY=starttls
SMTP_USERNAME=your-user@example.com
SMTP_FROM=noreply@vault.yourdomain.com
SMTP_FROM_NAME=VaultWarden
SMTP_TIMEOUT=15
ALLOWED_SENDER_DOMAINS="vault.yourdomain.com yourdomain.com"
POSTFIX_MYHOSTNAME=postfix.vault.yourdomain.com
POSTFIX_SMTP_TLS_SECURITY_LEVEL=encrypt
POSTFIX_MESSAGE_SIZE_LIMIT=10240000
```

Store the actual SMTP password in encrypted secrets and validate end to end with:

```bash
./maintenance.sh --test-email --verbose
```

---

## VaultWarden application settings

Application behavior is driven by environment settings exposed through the generated configuration.

Common categories include:

- Signup and invitation policy.
- Emergency access and send behavior.
- Password and hint policy.
- Organization and event retention behavior.
- Database connection and timeout tuning.
- Icon and cache settings.

Example values commonly reviewed:

```bash
SIGNUPS_ALLOWED=false
INVITATIONS_ALLOWED=true
EMERGENCY_ACCESS_ALLOWED=true
SENDS_ALLOWED=true
WEB_VAULT_ENABLED=true
PASSWORD_HINTS_ALLOWED=false
ORG_EVENTS_ENABLED=false
EVENTS_DAYS_RETAIN=365
TRASH_AUTO_DELETE_DAYS=30
DATABASE_MAX_CONNS=10
DATABASE_TIMEOUT=30
```

Use the generated `.env` plus the templates as your final reference for what is deployed in your environment.

---

## Push settings

If you use Bitwarden-compatible push notifications, review the push-related environment values and supply the installation credentials as encrypted secrets.

Typical environment values include:

```bash
PUSH_ENABLED=true
PUSH_RELAY_URI=https://push.bitwarden.com
PUSH_IDENTITY_URI=https://identity.bitwarden.com
```

Then set `push_installation_id` and `push_installation_key` through `edit-secrets.sh`.

---

## Fail2ban and Cloudflare settings

Fail2ban is designed around Cloudflare-backed edge enforcement for proxied web traffic.

Common tunables include:

```bash
F2B_LOG_TARGET=STDOUT
F2B_LOG_LEVEL=INFO
F2B_DB_PURGE_AGE=1d
F2B_MAX_RETRY=3
F2B_DEST_MAIL="${ADMIN_EMAIL}"
F2B_SENDER="fail2ban@${DOMAIN_NAME}"
F2B_ACTION="%(action_mwl)s"
```

The SSH path remains a host-level concern, while web-facing bans are designed around Cloudflare integration rather than local `iptables` blocking for proxied traffic.

---

## Backup settings

Backup behavior should be configured according to your recovery goals.

Typical settings and related controls include:

```bash
BACKUP_VERIFICATION_MODE=quick_check
RCLONE_REMOTE_NAME=your_remote_name
```

Retention should be treated as configurable. Use deployed `.env` values for defaults, and use `./backup.sh --keep N` when you need a run-specific override.

---

## Validation and troubleshooting

Validate generated config before applying or after changing it:

```bash
docker compose config
docker compose -f docker-compose.yml.example config
./edit-secrets.sh --test
./health.sh --comprehensive
```

If configuration drift or breakage is suspected, return to the template-first flow, regenerate with `setup.sh --force`, then restart with `startup.sh --force`.
