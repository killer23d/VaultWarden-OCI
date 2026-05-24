# Email Setup — VaultWarden-OCI

This document covers the complete email delivery system: how it works, how to
configure each delivery path, and how to keep the Postfix sidecar aligned with
the SMTP settings.

Related docs: [CONFIGURATION.md](CONFIGURATION.md) · [ADVANCED-CUSTOMIZATION.md](ADVANCED-CUSTOMIZATION.md) · [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

---

## Architecture Overview

Email is handled by **`lib/email.sh`** — a pure bash + curl multi-provider
chain. No mail daemon is required for the normal API or SMTP paths. The
delivery chain has three stages when `EMAIL_MODE=auto`:

```
                ┌─────────────────────────────────────┐
                │         lib/email.sh                 │
                │                                     │
  EMAIL_MODE    │  Stage 1 ── HTTP API                │  MailerSend, SendGrid,
     =auto  ──► │           (curl + JSON)             │  Mailgun, Postmark,
                │              │ fail                 │  Resend
                │              ▼                      │
                │  Stage 2 ── SMTP                    │  Direct relay or the
                │           (curl smtps/starttls)     │  Postfix sidecar
                │              │ fail                 │
                │              ▼                      │
                │  Stage 3 ── Host MTA                │  Local mail/sendmail
                │           (mail binary / sendmail)  │  binary
                └─────────────────────────────────────┘
```

Two additional consumers sit outside `lib/email.sh` and use SMTP directly:

| Consumer | How it sends email | Variables |
| :-- | :-- | :-- |
| **VaultWarden container** | Built-in SMTP client → Postfix sidecar | `VW_SMTP_*` in `.env` |

> **VaultWarden routes through Postfix, not the external relay directly.**
> The `VW_SMTP_*` block points at the internal Postfix sidecar
> (`VW_SMTP_HOST=postfix`, port 587, no auth, no TLS). Postfix then relays
> outbound using the `SMTP_HOST` / `SMTP_USERNAME` credentials. This means
> VaultWarden's SMTP settings are fixed and do not need updating when you
> change your upstream relay provider.

---

## Quick-Start: Recommended Setup (Tier 1 — HTTP API)

For most deployments, configure a transactional email API provider. This
requires no local mail daemon and is the most reliable path.

### 1. Choose a provider and get an API token

| Provider | Free tier | Sign-up URL |
| :-- | :-- | :-- |
| **MailerSend** | 3 000 emails/month | https://app.mailersend.com |
| **SendGrid** | 100 emails/day | https://sendgrid.com |
| **Mailgun** | 1 000 emails/month (trial) | https://mailgun.com |
| **Postmark** | 100 emails/month (free) | https://postmarkapp.com |
| **Resend** | 3 000 emails/month | https://resend.com |

All providers require you to **verify your sending domain** (add DNS TXT/CNAME
records in Cloudflare). Follow your provider's domain verification guide before
proceeding.

### 2. Set the provider in `.env`

```bash
EMAIL_MODE=auto
EMAIL_PROVIDER=mailersend    # change to: sendgrid | mailgun | postmark | resend
```

### 3. Store the API token in secrets

`lib/email.sh` uses a single canonical secret key (`email_api_token`) and
resolves the correct provider token automatically based on `EMAIL_PROVIDER`.
Store the token in the canonical `email_api_token` key (used for all providers):

```bash
# Any provider selected by EMAIL_PROVIDER uses this same secrets key
./utilities/secrets-rotate.sh email_api_token
```

In `.env`, uncomment **only** the line matching your `EMAIL_PROVIDER` and leave
its value blank (the actual token lives in the encrypted secrets file):

```bash
# keep provider selection in .env
EMAIL_PROVIDER=mailersend

# token value lives only in secrets.yaml (do not store plaintext in .env)
```

### 4. Set sender address in `.env`

```bash
SMTP_FROM=noreply@vault.yourdomain.com
SMTP_FROM_NAME=VaultWarden
```

> **`SMTP_FROM` is the canonical sender variable.** The legacy name
> `SMTP_FROM_EMAIL` still works via a backward-compatibility shim but is
> deprecated and will be removed in a future release. Migrate any existing
> `.env` files to `SMTP_FROM=`.

### 5. Test delivery

```bash
./maintenance.sh test-email --verbose
# or: make test-email
```

---

## Stage 2 — SMTP (direct relay or Postfix sidecar)

Used automatically when `EMAIL_MODE=auto` and the API tier fails, or explicitly
with `EMAIL_MODE=smtp`. This path uses `curl --url smtps://` or
`--url smtp://` with STARTTLS — no Postfix or local MTA is needed.

### Configuration in `.env`

```bash
EMAIL_MODE=auto           # or: smtp to force this tier
SMTP_HOST=smtp.mailersend.net
SMTP_PORT=587
SMTP_SECURITY=starttls    # starttls (port 587) or on (SSL/TLS, port 465)
SMTP_USERNAME=your-smtp-username
# SMTP_FROM and SMTP_FROM_NAME already set above
SMTP_TIMEOUT=30
```

Store the SMTP password in secrets (never in `.env`):

```bash
./utilities/secrets-rotate.sh smtp_password
```

### VaultWarden container SMTP

VaultWarden routes all its email through the **Postfix sidecar**, not directly
through the external SMTP relay. The `VW_SMTP_*` block must point at the
Postfix container on the internal Docker network:

```bash
VW_SMTP_HOST=postfix       # Docker service name of the Postfix sidecar
VW_SMTP_PORT=587
VW_SMTP_SECURITY=off       # plain — TLS is handled by Postfix → upstream relay
VW_SMTP_AUTH_MECHANISM=none  # no auth on the internal link
VW_SMTP_EXPLICIT_TLS=false
```

> **`VW_SMTP_AUTH_MECHANISM=none` is required.** Without it, VaultWarden
> defaults to `Plain` auth and attempts SASL authentication against Postfix.
> The sidecar has no AUTH configured for the internal link, so the connection
> hangs or returns "authentication required", blocking all VaultWarden email.
> `VW_SMTP_EXPLICIT_TLS=false` prevents VaultWarden from attempting STARTTLS
> on the plain internal link.

When you change your upstream relay provider, you only update the `SMTP_*`
variables. The `VW_SMTP_*` block stays fixed — VaultWarden always talks to
the Postfix sidecar.

---

## Postfix Sidecar and Host-MTA Fallback

The Postfix sidecar (`boky/docker-postfix`) is the SMTP sidecar used when
`SMTP_PASSWORD` is blank. It remains the SMTP path for the VaultWarden container.
`EMAIL_MODE=host` is separate: it tries a local mail/sendmail binary on the
host.

### Postfix and CrowdSec

CrowdSec runs as a host systemd service and does not use the Postfix container
for email notifications. CrowdSec notification settings are configured in the
CrowdSec profile/notification YAML files on the host.

### Postfix container configuration

The Postfix service is defined in `docker-compose.yml.example`. It acts as a
**smart-host relay**: it accepts mail locally and forwards it upstream via your
SMTP relay credentials. It does **not** deliver directly to the internet.

Key environment variables passed to the container:

| Variable | Purpose | Example |
| :-- | :-- | :-- |
| `RELAYHOST` | Upstream relay `host:port` | `smtp.mailersend.net:587` |
| `RELAYHOST_USERNAME` | SMTP auth username | `your-smtp-username` |
| `RELAYHOST_PASSWORD_FILE` | Path to Docker secret file | `/run/secrets/smtp_password` |
| `ALLOWED_SENDER_DOMAINS` | Domains Postfix will accept mail from | `vault.yourdomain.com` |
| `POSTFIX_myhostname` | Postfix `myhostname` setting | `postfix` |
| `POSTFIX_smtp_tls_security_level` | TLS enforcement | `encrypt` |
| `POSTFIX_message_size_limit` | Max message bytes | `10240000` (10 MB) |

These are assembled from your `.env` by Docker Compose — set the underlying
SMTP variables in `.env` and Postfix picks them up automatically:

```bash
# In .env — Postfix reads SMTP_HOST, SMTP_PORT, SMTP_USERNAME
SMTP_HOST=smtp.mailersend.net
SMTP_PORT=587
SMTP_USERNAME=your-smtp-username
ALLOWED_SENDER_DOMAINS=vault.yourdomain.com
POSTFIX_MYHOSTNAME=postfix
POSTFIX_SMTP_TLS_SECURITY_LEVEL=encrypt
POSTFIX_MESSAGE_SIZE_LIMIT=10240000
```

The SMTP password is injected via Docker secret — store it with:

```bash
./utilities/secrets-rotate.sh smtp_password
```

### Postfix container versions

`POSTFIX_VERSION` is **optional** in `.env`. If unset, Docker Compose uses the
default pinned in `docker-compose.yml.example` (currently `boky/postfix:4.3.0`).
To override:

```bash
# In .env
POSTFIX_VERSION=4.3.0
```

Check for the latest release at https://hub.docker.com/r/boky/postfix/tags

### Security note: SASL password file

`boky/postfix` writes the relay password to `/etc/postfix/sasl_passwd` inside
the container as part of its entrypoint. This is an upstream Postfix
requirement — the SASL mechanism needs a plaintext file at runtime. The file
is inside the container filesystem (not a bind-mount) and is not accessible
from the host without `docker exec`. Restrict Docker socket access to prevent
unauthorised inspection:

```bash
# Inspect the file if you need to verify credentials (requires root):
docker exec vaultwarden_postfix cat /etc/postfix/sasl_passwd
```

### Postfix capabilities

The container requires exactly 6 Linux capabilities (all others are dropped).
Do not remove `DAC_OVERRIDE` or `FOWNER` — mail spool access requires them:

```
CHOWN  SETUID  SETGID  NET_BIND_SERVICE  DAC_OVERRIDE  FOWNER
```

Verify after any Docker Compose change:

```bash
docker inspect vaultwarden_postfix | grep -A 20 CapAdd
```

### Disabling Postfix (API-only deployments)

If you are confident your API and SMTP relay tiers will always be available and
you do not need the Postfix container, you can disable it. Edit `docker-compose.yml.example`:

```yaml
# Comment out or remove the postfix service block, then regenerate:
sudo ./setup.sh install --domain vault.yourdomain.com --email admin@yourdomain.com --force
./startup.sh --force
```

> **Warning:** disabling Postfix means VaultWarden's own notification emails will not be
> delivered. The ban actions themselves (Cloudflare WAF rules, iptables blocks via CrowdSec)
> still fire — only VaultWarden's email notifications are affected.

---

## Mailgun Region

Mailgun operates two independent API fleets. Set `MAILGUN_REGION` in `.env` to
match your account:

| `MAILGUN_REGION` | API endpoint | Account at |
| :-- | :-- | :-- |
| `us` (default) | `api.mailgun.net` | mailgun.com |
| `eu` | `api.eu.mailgun.net` | eu.mailgun.com |

EU-region accounts always receive HTTP 404 from the US endpoint. If you see
`Domain not found` errors, verify `MAILGUN_REGION=eu` is set.

To override the sending domain (defaults to the domain portion of `SMTP_FROM`):

```bash
MAILGUN_DOMAIN=mg.yourdomain.com  # optional — set only if different from SMTP_FROM domain
```

---

## EMAIL_MODE Reference

| Value | Behaviour | When to use |
| :-- | :-- | :-- |
| `auto` | Try API → SMTP → host MTA in order | Recommended for all deployments |
| `api` | HTTP API only; error if token not set | API-only, no SMTP fallback desired |
| `smtp` | SMTP only (direct relay when `SMTP_PASSWORD` is set, otherwise the Postfix sidecar) | No API provider; reliable SMTP relay |
| `host` | Host mail/sendmail only | Only when the host already has a working local MTA |

---

## Full Variable Reference

### `.env` email variables

| Variable | Default | Description |
| :-- | :-- | :-- |
| `EMAIL_MODE` | `auto` | Delivery chain mode |
| `EMAIL_PROVIDER` | `mailersend` | HTTP API provider |
| `SMTP_HOST` | *(empty)* | SMTP relay hostname |
| `SMTP_PORT` | `587` | SMTP relay port |
| `SMTP_SECURITY` | `starttls` | `starttls` or `on` (SSL/TLS) |
| `SMTP_USERNAME` | *(empty)* | SMTP relay username |
| `SMTP_FROM` | *(empty)* | Sender address for `lib/email.sh` and Postfix relay |
| `SMTP_FROM_NAME` | `VaultWarden` | Sender display name |
| `SMTP_TIMEOUT` | `30` | Seconds before curl gives up |
| `VW_SMTP_HOST` | `postfix` | VaultWarden SMTP host — Postfix sidecar service name |
| `VW_SMTP_PORT` | `587` | VaultWarden SMTP port — internal Postfix port |
| `VW_SMTP_SECURITY` | `off` | VaultWarden TLS mode — plain on the internal link |
| `VW_SMTP_AUTH_MECHANISM` | `none` | VaultWarden auth — must be `none` for the internal link |
| `VW_SMTP_EXPLICIT_TLS` | `false` | VaultWarden STARTTLS — must be `false` on the internal link |
| `MAILGUN_REGION` | `us` | Mailgun API region: `us` or `eu` |
| `MAILGUN_DOMAIN` | *(domain from `SMTP_FROM`)* | Mailgun sending domain override |
| `ALLOWED_SENDER_DOMAINS` | *(empty)* | Postfix: domains accepted for relay |
| `POSTFIX_MYHOSTNAME` | `postfix` | Postfix `myhostname` value |
| `POSTFIX_SMTP_TLS_SECURITY_LEVEL` | `encrypt` | Postfix upstream TLS level |
| `POSTFIX_MESSAGE_SIZE_LIMIT` | `10240000` | Postfix max message bytes (10 MB) |
| `POSTFIX_VERSION` | *(uses compose default)* | Pin `boky/postfix` image tag |

> **Deprecated:** `SMTP_FROM_EMAIL` is the legacy sender variable. A
> backward-compatibility shim maps it to `SMTP_FROM` at runtime. Migrate
> to `SMTP_FROM=` — the shim will be removed in a future release.

### Secrets (via `./utilities/secrets-edit.sh`)

| Secret key | Used by | Description |
| :-- | :-- | :-- |
| `email_api_token` | `lib/email.sh` tier 1 | API token used by MailerSend / SendGrid / Mailgun / Postmark / Resend |
| `smtp_password` | `lib/email.sh` tier 2, Postfix | SMTP relay password |

---

## Testing & Troubleshooting

### End-to-end delivery test

```bash
./maintenance.sh test-email --verbose
# or: make test-email
```

This exercises the full `lib/email.sh` chain from tier 1 through to tier 3 and
prints which tier succeeded or failed.

### Check which tier delivered

```bash
# lib/email.sh logs to the maintenance log — look for tier labels:
grep -E 'EMAIL|SMTP|MTA|tier' /var/lib/vaultwarden/logs/maintenance.log | tail -30
```

### Test Postfix directly

```bash
# Check Postfix container health
docker compose ps postfix
docker compose logs postfix --tail 50

# Send a test message through Postfix (from the host)
echo "Subject: Postfix test" | sendmail -v admin@yourdomain.com
# or via nc:
echo -e "EHLO test\nQUIT" | nc 127.0.0.1 587

# Check Postfix mail queue
docker exec vaultwarden_postfix mailq

# Force queue flush
docker exec vaultwarden_postfix postqueue -f
```

### Test VaultWarden SMTP

```bash
# VaultWarden sends its own emails (invitations, 2FA codes, etc.)
# Check its logs for SMTP errors:
docker compose logs vaultwarden | grep -i smtp

# Trigger a test email from the VaultWarden admin panel:
# https://vault.yourdomain.com/admin → Diagnostics → Send test email
```

### Common issues

| Symptom | Likely cause | Fix |
| :-- | :-- | :-- |
| API tier always fails | Token not set or wrong key name | Run `./utilities/secrets-edit.sh` and verify the matching `email_api_token` is set |
| SMTP tier `SSL handshake failed` | `SMTP_SECURITY` mismatch | `starttls` → port 587; `on` → port 465 |
| VaultWarden email fails with "authentication required" | `VW_SMTP_AUTH_MECHANISM` not set to `none` | Set `VW_SMTP_AUTH_MECHANISM=none` and `VW_SMTP_EXPLICIT_TLS=false` in `.env` |
| VaultWarden sends email but `lib/email.sh` does not | `SMTP_*` misconfigured; Postfix not relaying | Check Postfix logs: `docker compose logs postfix` |
| Postfix `SASL authentication failed` | Wrong SMTP password in secrets | `./utilities/secrets-rotate.sh smtp_password` |
| Mailgun HTTP 404 `Domain not found` | Wrong API region | Set `MAILGUN_REGION=eu` in `.env` for EU accounts |
| All tiers fail silently on `EMAIL_MODE=auto` | `EMAIL_MODE` typo or not set | `grep EMAIL_MODE .env` — must be `auto`, `api`, `smtp`, or `host` |

---

## Decision Guide

Use this to choose the right setup for your deployment:

```
Do you want operational alert emails (backups, health, failures)?
  └─ Yes ──► Do you have a transactional email provider account?
               └─ Yes ──► Set EMAIL_MODE=auto, EMAIL_PROVIDER=<name>,
               │           store `email_api_token` in secrets.  ← RECOMMENDED
               └─ No  ──► Do you have an SMTP relay (e.g., Gmail, Outlook)?
                            └─ Yes ──► Set EMAIL_MODE=smtp, fill SMTP_* in .env,
                            │          store smtp_password in secrets.
                            └─ No  ──► Set EMAIL_MODE=host only if the host has
                                        a working local mail/sendmail binary.
                                        OCI blocks direct port 25 egress by
                                        default, so an SMTP relay is usually the
                                        safer choice.
```

> **OCI and port 25:** Oracle Cloud Infrastructure blocks outbound port 25
> (direct SMTP) on all compute instances by default. This means Postfix cannot
> deliver directly to recipient mail servers — it must relay through an upstream
> SMTP provider. You can request port 25 unblocking via an OCI support ticket,
> but using a transactional API provider (Tier 1) or SMTP relay (Tier 2) is
> the simpler path.
