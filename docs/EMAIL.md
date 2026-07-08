# Email Setup — VaultWarden-OCI

VaultWarden-OCI treats email as part of the appliance reliability path. The normal production route is:

```text
Vaultwarden user/admin mail  → Postfix sidecar → external SMTP relay
Operational scripts/alerts   → Postfix sidecar → external SMTP relay
systemd OnFailure notices    → existing notification script → Postfix sidecar → external SMTP relay
Recovery-kit export email    → Postfix sidecar SMTP with attachment support
```

The Postfix container is a **private smart-host relay** for this stack. It is not a public mail server and should not accept arbitrary sender domains. Keep `ALLOWED_SENDER_DOMAINS` restricted to your vault/domain.

Related docs: [CONFIGURATION.md](CONFIGURATION.md) · [ADVANCED-CUSTOMIZATION.md](ADVANCED-CUSTOMIZATION.md) · [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

---

## Default Mode: Postfix Sidecar SMTP

Use this for first install and normal operations:

```bash
EMAIL_MODE=smtp
EMAIL_PROVIDER=
SMTP_HOST=smtp.yourmailprovider.com
SMTP_PORT=587
SMTP_SECURITY=starttls
SMTP_USERNAME=your-smtp-username
SMTP_FROM=noreply@vault.yourdomain.com
SMTP_FROM_NAME=VaultWarden
ALLOWED_SENDER_DOMAINS=yourdomain.com
```

Store the SMTP relay password in SOPS secrets, never in `.env`:

```bash
sudo ./utilities/secrets-rotate.sh smtp_password
```

`ALLOWED_SENDER_DOMAINS` is required safety configuration. Set it to the domain(s) your vault is allowed to send as, for example `yourdomain.com` or `vault.yourdomain.com`. Leaving it broad makes the sidecar easier to misuse.

### Vaultwarden SMTP settings

Vaultwarden must always point at the Postfix sidecar on the internal Docker network:

```bash
VW_SMTP_HOST=postfix
VW_SMTP_PORT=587
VW_SMTP_SECURITY=off
VW_SMTP_AUTH_MECHANISM=none
VW_SMTP_EXPLICIT_TLS=false
```

Do not replace these with your upstream relay hostname. When you change mail providers, update the `SMTP_*` relay settings only; Vaultwarden continues to send to `postfix`.

### Operational alerts and failure notifications

`sudo ./maintenance.sh test-email --verbose`, backup/health/maintenance alerts, systemd `OnFailure` notifications, and recovery-kit email attachments use the same SMTP relay configuration and `smtp_password` secret. Attachment sends bypass HTTP API providers and use SMTP so recovery-kit exports continue to work.

### Recovery-kit attachments

Recovery-kit attachments are SMTP-only. They are sent as `important-documents-YYYYMMDD.tar.gpg`: a TAR stream encrypted with GnuPG symmetric OpenPGP encryption. The attachment passphrase is user-selected, independent from Age/SOPS/emergency backup/SMTP secrets, requires at least 16 characters, and must be confirmed before encryption.

To recover the document, save the attachment on a trusted device and run:

```bash
gpg --output recovery-kit.tar \
  --decrypt important-documents-YYYYMMDD.tar.gpg

tar -xf recovery-kit.tar
```

GnuPG prompts for the independent attachment passphrase. Protect the decrypted recovery kit, then delete `recovery-kit.tar` after the recovered document has been secured.

Test the complete default path after setup:

```bash
sudo ./maintenance.sh test-email --verbose
sudo utilities/maintenance-email.sh --dry-run
```

---

## How Postfix Relays Mail

The Postfix service in `docker-compose.yml.example` accepts mail from the stack and forwards it to your external SMTP provider using these values:

| `.env` value | Purpose |
| :-- | :-- |
| `SMTP_HOST` / `SMTP_PORT` | Upstream relay host and port |
| `SMTP_USERNAME` | Upstream relay username |
| `smtp_password` secret | Upstream relay password |
| `SMTP_FROM` / `SMTP_FROM_NAME` | Sender identity for operational mail |
| `ALLOWED_SENDER_DOMAINS` | Sender domains the sidecar accepts |
| `POSTFIX_MYHOSTNAME` | Postfix internal hostname, normally `postfix` |
| `POSTFIX_SMTP_TLS_SECURITY_LEVEL` | Upstream TLS policy, normally `encrypt` |
| `POSTFIX_MESSAGE_SIZE_LIMIT` | Maximum message size |

Postfix provides queueing and retry behavior that direct SMTP does not. It should remain enabled for the normal appliance path.

### Advanced Postfix safety notes

- `ALLOWED_SENDER_DOMAINS` must stay narrow. Use your sending domain(s), not `*`, so the sidecar cannot be abused by other containers on the Docker network.
- `boky/postfix` writes the upstream relay credential to `/etc/postfix/sasl_passwd` inside the container at startup. This is a Postfix SASL requirement; the file is not bind-mounted to the host, but anyone with Docker socket access can inspect it with `docker exec`. Restrict Docker access to trusted operators.
- Keep the Postfix container capabilities from `docker-compose.yml.example`. In particular, do not remove `DAC_OVERRIDE` or `FOWNER`; mail spool access can fail silently without them.
- The sidecar is not an MX server and should not be exposed publicly. It relays stack mail to your authenticated external SMTP provider.

---

## Advanced API Provider Mode

HTTP API providers are optional alternatives for operators who already use a transactional email API. They are not the first-run default, and `EMAIL_PROVIDER=smtp` is not valid because SMTP is selected by `EMAIL_MODE=smtp`.

Supported API providers:

| Provider | Free tier | Sign-up URL |
| :-- | :-- | :-- |
| MailerSend | 3,000 emails/month | https://app.mailersend.com |
| SendGrid | 100 emails/day | https://sendgrid.com |
| Mailgun | Trial/free allowance varies | https://mailgun.com |
| Postmark | Trial/free allowance varies | https://postmarkapp.com |
| Resend | 3,000 emails/month | https://resend.com |

To enable API-first operational alerts:

```bash
EMAIL_MODE=auto
EMAIL_PROVIDER=mailersend   # sendgrid | mailgun | postmark | resend
```

Store the API token in the canonical SOPS secret key used for all providers:

```bash
sudo ./utilities/secrets-rotate.sh email_api_token
```

`EMAIL_MODE=auto` tries the selected API provider first and then falls back to SMTP paths. Keep Postfix configured even in API mode because Vaultwarden container mail and attachment-based messages still rely on SMTP.

### Mailgun region

Mailgun has separate US and EU API endpoints:

```bash
MAILGUN_REGION=us   # or eu
```

Set `MAILGUN_REGION=eu` for EU-hosted accounts. If your Mailgun sending domain differs from the domain in `SMTP_FROM`, set `MAILGUN_DOMAIN=mg.yourdomain.com`.

---

## EMAIL_MODE Reference

| Value | Behaviour | When to use |
| :-- | :-- | :-- |
| `smtp` | Postfix sidecar SMTP → direct upstream SMTP fallback | Normal production default |
| `auto` | HTTP API → Postfix sidecar SMTP → direct upstream SMTP fallback | Advanced API-first alerts while preserving SMTP fallback |
| `api` | HTTP API only; error if token is missing | API-only diagnostics or special cases; not normal first-run |
| `direct` | Direct upstream SMTP only | Emergency bypass when Docker/sidecar is unavailable; no queueing |
| `host` | Deprecated alias for `direct` | Compatibility only; no host MTA is used |

---

## Full Variable Reference

| Variable | Default | Description |
| :-- | :-- | :-- |
| `EMAIL_MODE` | `smtp` | Delivery chain mode |
| `EMAIL_PROVIDER` | *(blank)* | API provider only when `EMAIL_MODE=auto` or `api` |
| `SMTP_HOST` | `smtp.example.com` | SMTP relay hostname |
| `SMTP_PORT` | `587` | SMTP relay port |
| `SMTP_SECURITY` | `starttls` | `starttls`, `tls`, `on`, or `none` depending on provider |
| `SMTP_USERNAME` | *(operator supplied)* | SMTP relay username |
| `SMTP_FROM` | *(operator supplied)* | Sender address for scripts and Postfix relay |
| `SMTP_FROM_NAME` | `VaultWarden` | Sender display name |
| `SMTP_TIMEOUT` | `30` | Seconds before SMTP client timeout |
| `VW_SMTP_HOST` | `postfix` | Vaultwarden SMTP host — keep as the sidecar service name |
| `VW_SMTP_PORT` | `587` | Vaultwarden SMTP port — internal Postfix port |
| `VW_SMTP_SECURITY` | `off` | Plain internal link to Postfix |
| `VW_SMTP_AUTH_MECHANISM` | `none` | Required because the sidecar internal link has no AUTH |
| `VW_SMTP_EXPLICIT_TLS` | `false` | Prevents STARTTLS on the plain internal link |
| `ALLOWED_SENDER_DOMAINS` | `example.com` | Domains Postfix accepts for relay |
| `POSTFIX_MYHOSTNAME` | `postfix` | Postfix `myhostname` value |
| `POSTFIX_SMTP_TLS_SECURITY_LEVEL` | `encrypt` | Postfix upstream TLS level |
| `POSTFIX_MESSAGE_SIZE_LIMIT` | `10240000` | Postfix max message bytes |
| `POSTFIX_VERSION` | from `.env.example` | Pin for `boky/postfix` image |
| `MAILGUN_REGION` | `us` | API mode only: Mailgun region |
| `MAILGUN_DOMAIN` | domain from `SMTP_FROM` | API mode only: Mailgun sending domain override |

Secrets:

| Secret key | Used by | Description |
| :-- | :-- | :-- |
| `smtp_password` | Postfix sidecar and SMTP fallback | External SMTP relay password |
| `email_api_token` | Advanced API provider mode | MailerSend/SendGrid/Mailgun/Postmark/Resend API token |

> `SMTP_FROM_EMAIL` is a deprecated compatibility alias for `SMTP_FROM`. New installs should use `SMTP_FROM`.

---

## Testing and Troubleshooting

```bash
sudo ./maintenance.sh test-email --verbose
sudo utilities/maintenance-email.sh --dry-run
```

Useful checks:

```bash
docker compose ps postfix
docker compose logs postfix --tail 50
docker compose logs vaultwarden | grep -i smtp
docker exec vaultwarden_postfix mailq
docker exec vaultwarden_postfix postqueue -f
```

Common fixes:

| Symptom | Likely cause | Fix |
| :-- | :-- | :-- |
| Vaultwarden mail hangs or says auth required | `VW_SMTP_AUTH_MECHANISM` is not `none` | Restore the default `VW_SMTP_*` block |
| Postfix rejects sender | `ALLOWED_SENDER_DOMAINS` too narrow or wrong sender domain | Set it to the domain used by `SMTP_FROM` |
| Postfix `SASL authentication failed` | Wrong `smtp_password` secret or SMTP username | Rotate `smtp_password` and verify `SMTP_USERNAME` |
| SMTP handshake failure | Provider requires a different `SMTP_SECURITY`/port pair | Use provider docs; most use `starttls` on `587` |
| API provider fails | Missing `email_api_token` or wrong `EMAIL_PROVIDER` | Rotate `email_api_token` and verify provider value |
| Recovery-kit email with attachment fails | SMTP path is not working | Fix Postfix/SMTP first; attachments do not use HTTP API |
