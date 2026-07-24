# Email Setup — VaultWarden-OCI

VaultWarden-OCI treats outbound mail as part of appliance reliability.

The normal production path is Postfix-first SMTP:

```text
Vaultwarden application mail
        -> Postfix sidecar
        -> authenticated/TLS upstream SMTP relay

Operational alerts in EMAIL_MODE=smtp
        -> Postfix sidecar
        -> direct upstream SMTP fallback if sidecar submission fails

systemd failure notifications
        -> repository notification helper
        -> configured operational email route

Recovery-kit attachment email
        -> SMTP fallback chain

CrowdSec security-event email (optional)
        -> host 127.0.0.1:587
        -> Postfix sidecar
        -> authenticated/TLS upstream SMTP relay
```

The Postfix container is a private smart-host relay for the stack. It is not a public MX server.

Related docs: [CONFIGURATION.md](CONFIGURATION.md) · [ADVANCED-CUSTOMIZATION.md](ADVANCED-CUSTOMIZATION.md) · [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

## Default production mode — Postfix sidecar SMTP

Configure non-secret mail settings through:

```bash
sudo make edit-env
```

Normal values:

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

Store the upstream relay password in SOPS:

```bash
sudo ./edit-secrets.sh rotate smtp_password
```

`ALLOWED_SENDER_DOMAINS` is a safety boundary. Keep it limited to the sender domain or domains this appliance is expected to use.

Do not put `smtp_password` in `.env`.

## Vaultwarden application SMTP settings

Vaultwarden sends to the internal Postfix sidecar:

```bash
VW_SMTP_HOST=postfix
VW_SMTP_PORT=587
VW_SMTP_SECURITY=off
VW_SMTP_AUTH_MECHANISM=none
VW_SMTP_EXPLICIT_TLS=false
```

This internal Docker-network hop is deliberately different from the authenticated/TLS upstream relay hop.

Do not replace `VW_SMTP_HOST=postfix` with the external provider hostname as the normal configuration. When the external SMTP provider changes, update the `SMTP_*` relay settings and `smtp_password`; Vaultwarden continues to submit to the sidecar.

## How the Postfix route works

The Postfix service receives stack mail and relays it upstream using:

| Configuration | Purpose |
| :-- | :-- |
| `SMTP_HOST` / `SMTP_PORT` | upstream SMTP relay endpoint |
| `SMTP_USERNAME` | upstream relay username |
| `smtp_password` SOPS secret | upstream relay password |
| `SMTP_FROM` / `SMTP_FROM_NAME` | sender identity for repository operational mail |
| `ALLOWED_SENDER_DOMAINS` | sender domains accepted by the sidecar |
| `POSTFIX_MYHOSTNAME` | Postfix hostname |
| `POSTFIX_SMTP_TLS_SECURITY_LEVEL` | upstream Postfix TLS policy |
| `POSTFIX_MESSAGE_SIZE_LIMIT` | message-size limit |

Postfix provides queueing/retry behavior for the normal appliance mail path.

### Postfix safety notes

- Keep `ALLOWED_SENDER_DOMAINS` narrow; do not use `*` as a convenience default.
- Do not expose the Postfix service publicly. It is an internal relay to the configured upstream provider.
- Restrict Docker control/socket access to trusted administrators. A user who can control Docker can inspect container state and therefore must be treated as highly privileged.
- Preserve the capabilities in the current `docker-compose.yml.example` unless a tested image/runtime change proves a smaller set works. Mail spool/ownership operations depend on the current container contract.
- Keep upstream relay authentication in SOPS-backed `smtp_password`, not repository configuration.

## Operational alert routing

Repository operational email uses `lib/email.sh`.

Current route modes are:

| `EMAIL_MODE` | Route |
| :-- | :-- |
| `smtp` | Postfix sidecar SMTP, then direct upstream SMTP fallback |
| `auto` | configured HTTP API provider first, then the SMTP fallback chain |
| `api` | configured HTTP API provider only; no SMTP fallback |
| `direct` | direct upstream SMTP only |
| `host` | deprecated compatibility alias that behaves like `direct` |

The repository template defaults to:

```bash
EMAIL_MODE=smtp
EMAIL_PROVIDER=
```

Use the default for the normal small-team production path.

### SMTP fallback behavior

For `smtp` and the SMTP portion of `auto`, the repository first submits to the Postfix sidecar endpoint. If sidecar submission fails, it attempts direct authenticated upstream SMTP using `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, and the SOPS `smtp_password`.

Direct fallback is a delivery fallback, not a reason to remove the Postfix service from the normal architecture.

### Rate limiting

Non-critical operational subjects use the repository's local per-subject email rate-limit stamp to reduce repeated notification noise. Critical subjects bypass that normal rate-limit check.

The default rate window is controlled by the current email helper configuration and should not be replaced with another notification database or daemon.

### Health incident and recovery context

Health checks keep their existing per-check warning/failure messages and
cooldowns. When the existing `${PROJECT_STATE_DIR}/.vw-health-alert/` path is
writable, the first unhealthy run also creates one private `0600` active
incident snapshot. Failure/warning mail includes its incident ID. Subsequent
unhealthy runs retain the original ID/start time and update bounded,
control-character-sanitized check details.

The next successful recovery email includes the incident ID, start and recovery
times, calculated duration, previously unhealthy checks and their last bounded
details, plus current pass/warning/failure totals. After successful delivery,
only the active incident file is removed. Per-check cooldowns and notification
dead-letter markers are not cleared. If recovery delivery fails, the snapshot
is retained and the existing recovery cooldown is released for the next-cycle
retry.

Incident persistence is best effort. If the existing alert-state directory is
not writable, health logs a bounded warning and continues with the established
health result, email, exit-code, and cooldown behavior without incident
correlation. It does not self-escalate or change directory ownership.

These notification types remain separate:

- CrowdSec security-event email reports matching IP-remediation alerts through
  the optional CrowdSec plugin.
- Health email reports individual unhealthy checks and correlated recovery.
- Generic systemd `OnFailure` email reports a failed unit through
  `utilities/notify-failure.sh`.

## HTTP API provider mode

HTTP API providers are optional for operational alerts.

Current provider identifiers implemented by `lib/email.sh` are:

```text
mailersend
sendgrid
mailgun
postmark
resend
cyberpersons
```

Compatibility aliases for the CyberPersons driver are also accepted by the current helper.

Provider plans, trial allowances, and commercial quotas change independently of this repository. Check the selected provider's current account terms instead of relying on a copied free-tier table in project documentation.

Enable API-first operational alerts:

```bash
EMAIL_MODE=auto
EMAIL_PROVIDER=mailersend
```

Set the common SOPS API-token secret:

```bash
sudo ./edit-secrets.sh rotate email_api_token
```

`EMAIL_MODE=auto` tries the selected API driver and falls back to the Postfix/direct-SMTP chain when the API route fails.

`EMAIL_MODE=api` does not fall back. An unknown provider or API failure returns failure.

`EMAIL_PROVIDER=smtp` is not a valid API-provider selection. SMTP is selected by `EMAIL_MODE=smtp`.

### Mailgun region/domain

The current Mailgun driver supports:

```bash
MAILGUN_REGION=us   # or eu
MAILGUN_DOMAIN=mg.yourdomain.com
```

When `MAILGUN_DOMAIN` is blank, the driver derives the sending domain from `SMTP_FROM`.

## Recovery-kit attachment email

Messages with attachments bypass the HTTP API provider path and use the SMTP fallback chain.

The recovery-kit export workflow may offer attachment delivery through this SMTP path. The current recovery-kit email packaging uses an independently passphrase-protected GnuPG attachment created by the recovery-kit workflow.

That attachment passphrase is separate from:

- the operational Age key;
- the offline recovery Age key;
- an emergency backup passphrase;
- `smtp_password`;
- `email_api_token`.

Treat a recovery-kit attachment as extremely sensitive even while encrypted. Store the received material in the intended password manager/offline recovery location and remove temporary decrypted copies from the trusted workstation after verification.

Do not redesign attachment delivery around a provider API driver unless the repository implements and tests attachment support for that driver. The current generic API email route is text-message oriented.

## Secret ownership

Email secrets in the current schema are:

| Secret key | Consumer |
| :-- | :-- |
| `smtp_password` | Postfix/upstream SMTP and direct SMTP fallback |
| `email_api_token` | selected HTTP API email driver |

The current secret schema apply behavior restarts Postfix when `smtp_password` rotates. `email_api_token` has no automatic service restart because the operational helper reads the secret on invocation.

Use:

```bash
sudo ./edit-secrets.sh rotate smtp_password
sudo ./edit-secrets.sh rotate email_api_token
```

Do not maintain provider-specific plaintext API token variables in `.env` for the normal project secret lifecycle.

## Testing the email path

Run the dedicated diagnostic:

```bash
sudo ./maintenance.sh test-email --verbose
```

Preview the diagnostic without sending:

```bash
sudo utilities/maintenance-email.sh --dry-run
```

Override the recipient when required:

```bash
sudo ./maintenance.sh test-email \
  --recipient admin@example.com \
  --verbose
```

The diagnostic checks Postfix container health, selected operational route prerequisites, CrowdSec integration context, and end-to-end email delivery.

A successful send means the selected delivery chain accepted the message. It does not independently prove the external recipient's spam-folder policy or long-term provider account status.

## Troubleshooting Postfix SMTP

Check the container:

```bash
docker compose ps postfix
docker compose logs postfix --tail=100
```

Check the queue:

```bash
docker exec vaultwarden_postfix mailq
docker exec vaultwarden_postfix postqueue -f
```

Check Vaultwarden SMTP errors:

```bash
docker compose logs vaultwarden --tail=150 \
  | grep -i smtp
```

Common failures:

| Symptom | Likely direction |
| :-- | :-- |
| Vaultwarden reports SMTP auth/STARTTLS errors to `postfix` | restore the current `VW_SMTP_*` internal-sidecar settings |
| Postfix rejects sender | verify `SMTP_FROM` and narrow `ALLOWED_SENDER_DOMAINS` match |
| Postfix upstream SASL auth fails | verify `SMTP_USERNAME` and rotate `smtp_password` |
| Upstream TLS/handshake fails | verify the provider's required port and `SMTP_SECURITY`/Postfix TLS settings |
| Queue grows | inspect upstream connectivity/provider rejection in Postfix logs |
| Attachment email fails | fix the SMTP chain; attachment sends do not use the HTTP API driver |

Edit non-secret values through:

```bash
sudo make edit-env
```

After changes:

```bash
sudo make restart
sudo ./maintenance.sh test-email --verbose
```

## Troubleshooting API mode

Check:

```bash
utilities/env-edit.sh status
sudo ./utilities/secrets-list.sh
sudo ./maintenance.sh test-email --verbose
```

Verify:

- `EMAIL_MODE` is `auto` or `api`;
- `EMAIL_PROVIDER` matches a currently implemented driver identifier;
- `email_api_token` is configured and not a placeholder;
- `SMTP_FROM` is a sender identity accepted by the selected provider;
- provider-specific sending-domain/account configuration is valid.

The HTTP helper uses bounded connection/overall timeouts and temporary mode-`0600` curl config/payload files. Do not "debug" API mode by printing the bearer/API token or authorization header.

For `auto`, an API failure should log the provider failure and continue to the SMTP fallback chain. For `api`, the same failure is final.

## Post-restore and post-update checks

After a restore or material email configuration change:

```bash
sudo make health
sudo ./maintenance.sh test-email --verbose
```

After repository changes that affect installed systemd notification code:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

Git updates the checkout; systemd failure notifications use the managed installed runtime under `/opt/vaultwarden-scripts`.

## Security rules

- Keep `smtp_password` and `email_api_token` in SOPS.
- Keep `ALLOWED_SENDER_DOMAINS` narrow.
- Do not expose Postfix publicly.
- Treat Docker control as highly privileged.
- Do not log SMTP passwords, provider tokens, or authorization headers.
- Do not rely on provider pricing/free-tier numbers copied into repository docs.
- Keep Postfix configured even when advanced API-first operational alerts are enabled.
- Treat recovery-kit attachment delivery as a high-sensitivity path and use the independent attachment passphrase according to the recovery-kit workflow.

## Recovery-kit attachment

<!-- VWOCI-PRR-PATCH-04 -->

`EMAIL_MODE=direct` is a supported direct-SMTP mode and requires the runtime `smtp_password` secret. `host` remains a deprecated compatibility alias.

Recovery-kit email attaches only an AES-256 encrypted ZIP created by the Ubuntu 24.04 `7zip` package. The independently entered attachment passphrase is not included in the message and is not reused from any stored project credential. See [Secure credential and recovery handoffs](SECURE-CREDENTIAL-HANDOFFS.md).
