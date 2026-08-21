# V2 operational notifications and systemd automation

Phase 6 adds a deliberately small systemd automation surface and operational email delivery. Vaultwarden application email remains direct authenticated SMTP; Phase 6 does not add Postfix, a local MTA, a spool, a durable retry queue, a dead-letter queue, a provider SDK, or a generic HTTP/plugin framework.

## Operator configuration

Operational provider selection lives in the single operator config `/etc/vaultwarden-oci/config.toml`:

```toml
[notifications]
provider = "cyberpersons"
to_email = "ops@example.com"
```

The canonical provider IDs are exactly `mailersend`, `sendgrid`, `mailgun`, `postmark`, `resend`, and `cyberpersons`. `cyberpanel` is accepted only as an alias for `cyberpersons`.

Mailgun is the only built-in that currently needs provider-specific non-secret settings. Provider options use one generic table whose allowed keys and values come only from the selected immutable catalog entry:

```toml
[notifications]
provider = "mailgun"
to_email = "ops@example.com"

[notifications.options]
region = "eu" # us (default) or eu
domain = "mg.example.com"
```

Unknown notification fields, providers, aliases, or provider options fail validation. Operator config cannot override provider endpoints, authentication modes/headers, request payload shapes, success rules, or retry classification. Adding a future non-secret option that is already representable by the catalog's closed `enum`/`domain` option schema does not require provider-specific Python plumbing: `[notifications.options]` is validated against whichever provider is selected and is passed unchanged to the common renderer.

Store the operational API credential as `email_api_token` in `/etc/vaultwarden-oci/secrets.sops.yaml`. It is decrypted only in host memory and is not materialized into the Vaultwarden or Caddy runtime secret mounts. Existing `smtp_username` and `smtp_password`, plus the secure `[smtp]` host/port/security settings used for Vaultwarden application mail, supply the direct authenticated SMTP fallback path.

## Catalog design and maintenance

`email-providers.toml` is immutable release data, not operator config. It contains no secret values. The closed schema represents only capabilities used by the built-ins: canonical ID/aliases/display name, a fixed HTTPS endpoint or narrowly substituted endpoint, finite auth mode, JSON or form request data, exact canonical message placeholders, success status/rule, documented retry statuses, bounded standard `Retry-After`, an optional single top-level numeric retry-delay field with a declared unit, and declared non-secret provider options.

The canonical message vocabulary is exactly:

- `from_email`
- `from_name`
- `from_header` (derived safely from name + email)
- `to_email`
- `subject`
- `text`

Templates are parsed as data and recursively rendered through structured JSON or multipart form serialization. There is no `eval`, Jinja, shell expansion, Python expression, dynamic import, SDK dispatch, or per-provider class/module registry. HTTPS endpoints are checked before and after substitutions; authorization-bearing requests do not follow redirects. Response bodies are bounded and never persisted.

For an ordinary upstream metadata/settings change: verify the current official provider documentation, edit one provider block in `email-providers.toml`, update the smallest focused tests/docs, and—when a newly declared option uses an already supported catalog option/substitution kind—set it through `[notifications.options]`. Change production Python only when a genuinely new transport capability cannot be represented safely by the existing closed schema. This is why the catalog reduces future library edits without becoming a plugin mechanism.

## Retry and fallback behavior

Each HTTPS send gets at most three attempts (initial + two bounded retries). Standard `Retry-After` is honored only on a catalog-declared retryable response and is clamped to a small global maximum. A provider-body retry delay is usable only if the catalog explicitly declares one top-level numeric field and a fixed supported unit; absent/malformed values are ignored. CyberPersons' documented `retry_after` body value is intentionally **not** enabled because the currently reviewed REST documentation does not define a usable field-unit contract.

After the bounded attempts, SMTP fallback is attempted only when the API result is clearly transient: a provider status explicitly classified transient in the immutable catalog or a network/DNS/connectivity timeout. TLS certificate/hostname validation errors, authentication/configuration errors, permanent provider errors, ambiguous success bodies, and other unclassified responses remain visible and are not masked by SMTP.

SMTP fallback uses Python `smtplib` with `ssl.create_default_context()`, either implicit TLS (`force_tls`) or required STARTTLS (`starttls`), followed by authentication. There is no plaintext downgrade.

The persisted result at `/var/lib/vaultwarden-oci/state/notification.json` contains only event ID/time, canonical provider, transport used, outcome, stable category/reason, and bounded secret-free diagnostics. Subject, message body, API token, SMTP credentials, authorization headers, and full provider response bodies are not persisted.

`vwctl status` includes the last notification result, but delivery history is advisory: a previous notification failure is displayed as a warning and does **not** change an otherwise-running/stopped runtime status to failure. This prevents the five-minute health timer from turning notification history into an unbounded notification retry scheduler. `vwctl doctor` separately reports the last delivery as WARN when it failed, validates the catalog and configured provider/options, checks for `email_api_token`, and reports whether authenticated TLS SMTP fallback is configured (not whether a remote SMTP server is currently reachable).

## Current provider contract verified for Phase 6

The following official documentation was re-checked on 2026-08-20/21 before the final Phase 6 review fixes:

- **MailerSend** — `https://developers.mailersend.com/api/v1/email` and `https://developers.mailersend.com/general`. Send endpoint is `POST https://api.mailersend.com/v1/email`, Bearer authentication, JSON payload, success `202`. The general docs distinguish short 429 rate limiting from 429 daily quota exhaustion, so Phase 6 does **not** classify all MailerSend 429 responses as transient. Documented `421 Service isn't available, try again later` is the status-only transient rule.
- **Twilio SendGrid** — `https://www.twilio.com/docs/sendgrid/api-reference/mail-send/mail-send`, `https://www.twilio.com/docs/sendgrid/api-reference/how-to-use-the-sendgrid-v3-api/responses`, and `https://www.twilio.com/docs/sendgrid/api-reference/how-to-use-the-sendgrid-v3-api/rate-limits`. Global endpoint is `POST https://api.sendgrid.com/v3/mail/send`, Bearer API key, JSON payload, accepted send `202`; `429` is documented rate limiting. Phase 6 currently implements the global endpoint only.
- **Mailgun** — `https://documentation.mailgun.com/docs/mailgun/api-reference/send/mailgun/messages` and `https://documentation.mailgun.com/docs/mailgun/api-reference/api-overview`. Send uses Basic auth (`api:<API key>`), multipart form data, `POST /v3/{domain}/messages`, success `200`. US/EU API hosts are `api.mailgun.net` and `api.eu.mailgun.net`. The API overview explicitly documents `429` rate-limit retry and `500` server-error retry with backoff.
- **Postmark** — `https://postmarkapp.com/developer/api/email-api` and `https://postmarkapp.com/developer/api/overview`. Single-send endpoint is `POST https://api.postmarkapp.com/email`; authentication uses `X-Postmark-Server-Token`; success is HTTP `200` plus top-level `ErrorCode: 0`; `429` is rate limiting and `503` is planned service unavailability.
- **Resend** — `https://resend.com/docs/api-reference/emails/send-email`, `https://resend.com/docs/api-reference/introduction`, `https://resend.com/docs/api-reference/rate-limit`, and `https://resend.com/docs/api-reference/errors`. Endpoint is `POST https://api.resend.com/emails`, Bearer API key, JSON, success `200`, and current docs require a User-Agent for direct HTTP requests. Current 429 responses can be either per-second rate limiting or daily/monthly quota exhaustion, so a status-only catalog cannot safely treat all 429s as transient. Current error docs say `500` application/internal server errors should be tried again later, so `500` is the status-only transient rule.
- **CyberPanel Email / CyberPersons** — `https://cyberpanel.net/KnowledgeBase/sending-email-rest-api/`, `https://cyberpanel.net/KnowledgeBase/plans-pricing-rate-limits/`, `https://cyberpanel.net/KnowledgeBase/troubleshooting-common-issues/`, and `https://cyberpanel.net/KnowledgeBase/sending-email-smtp/`. Canonical V2 ID is `cyberpersons`, alias `cyberpanel`. REST send is `POST https://platform.cyberpersons.com/email/v1/send`, recommended Bearer API key with `can_send`, JSON `from`/`to`/`subject`/`text`, success `202` plus `success: true`. The same HTTP `429 rate_limit_exceeded` covers account-wide per-minute, per-hour, per-day, and per-month limits, so Phase 6 keeps 429 visible and does **not** make it retry/fallback eligible by status alone. `503 service_unavailable` remains transient. `500 send_failed`, `400`, and documented `403` cases remain visible. SMTP is `mail.cyberpersons.com:587`, STARTTLS required, with authenticated SMTP credentials separate from the API key; the provider also documents that account limits are shared across API keys and SMTP credentials.

### Intentional V1 behavior changes

V1's `lib/email.sh` used one Bash function per provider, `curl --retry-all-errors`, and Postfix/local-MTA queueing. Phase 6 intentionally replaces those behaviors: provider mechanics are catalog data rendered by one Python stdlib owner, retries are only for documented transient classifications, authorization redirects fail closed, SMTP uses verified TLS directly, and no Postfix/spool/durable queue is created. V1 plaintext/no-TLS SMTP modes are not supported.

## systemd surface

The installed immutable release owns exactly these Phase 6 unit files under `systemd-v2/`, which the installer copies to `/etc/systemd/system` and checks for managed drift:

- `vaultwarden-oci.target` — groups the lifecycle service and three timers.
- `vaultwarden-oci.service` — starts/stops the installed V2 stack through `/opt/vaultwarden-oci/current/vwctl`.
- `vaultwarden-oci-health.service` + `.timer` — runs `vwctl status` every five minutes; notification-delivery history is advisory and cannot by itself make this unit fail/re-notify.
- `vaultwarden-oci-backup.service` + `.timer` — creates the existing Phase 5 encrypted local recovery point daily; Phase 6 does not invent a new rclone destination authority.
- `vaultwarden-oci-maintenance.service` + `.timer` — runs `vwctl doctor` weekly.
- `vaultwarden-oci-notify@.service` — one failure-notification template used by the lifecycle/health/backup/maintenance services.

The timers are systemd scheduling only; there is no application scheduler. Enable/start the automation target only after normal V2 config and SOPS/Age custody are configured:

```bash
sudo systemctl enable --now vaultwarden-oci.target
```

Later phases may add update-engine behavior, but Phase 6 does not implement it.
