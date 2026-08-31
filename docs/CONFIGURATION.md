# Configuration

VaultWarden-OCI has one durable non-secret operator authority: `/etc/vaultwarden-oci/config.toml`. Secret values remain in `/etc/vaultwarden-oci/secrets.sops.yaml`. Setup writes every setting that the appliance intentionally supports for normal small-team administration, with an explicit default and a short comment, so an administrator should not need to search upstream documentation just to discover the supported keys.

This is deliberately a **curated appliance contract**, not a generic pass-through for every Vaultwarden, Caddy, Docker, Cloudflare, CrowdSec, rclone, or systemd option. Storage paths, database paths, logging destinations, proxy trust, Cloudflare origin filtering, container limits, service identities, CrowdSec ownership, and experimental upstream features remain appliance-owned because exposing them would create competing authorities or unsafe combinations.

## Editing and applying changes

Use the supported validated transactions:

```bash
sudo vwctl config edit
sudo vwctl secrets edit
```

Each command edits a protected candidate and commits only after validation. On an interactive terminal, if the stack is running, `vwctl` then asks:

```text
Restart VaultWarden-OCI now to apply these changes? [y/N]:
```

Answering `y` performs the normal supported `vwctl restart` lifecycle immediately. Answering no leaves an explicit restart action. When the stack is stopped, the changes simply apply on the next `vwctl start`. Non-interactive callers are never blocked by a prompt and retain the explicit restart action.

## Vaultwarden settings

Fresh setup writes the following supported `[vaultwarden]` keys. Existing valid minimal V2 configurations remain compatible: omitted catalog keys receive these defaults when rendered.

| Key | Default | Purpose |
| --- | --- | --- |
| `signups_allowed` | `false` | Open self-registration. The appliance stays invite-oriented by default. |
| `signups_verify` | `false` | Require email verification for self-registration. |
| `signups_verify_resend_time` | `3600` | Verification resend interval in seconds. |
| `signups_verify_resend_limit` | `6` | Verification resend limit. |
| `sends_allowed` | `true` | Allow Bitwarden Sends. |
| `invitations_allowed` | `true` | Allow organization administrators to invite users even when open signup is disabled. |
| `invitation_org_name` | `"Vaultwarden"` | Name used for non-organization-specific invitations. |
| `invitation_expiration_hours` | `120` | Invitation/email-token lifetime. |
| `emergency_access_allowed` | `true` | Allow emergency access. |
| `email_change_allowed` | `true` | Allow users to change account email. |
| `org_events_enabled` | `false` | Enable organization event logging. |
| `org_creation_users` | `"all"` | `all`, `none`, or a comma-separated email allow-list. |
| `incomplete_2fa_time_limit` | `3` | Minutes before incomplete-2FA email handling; `0` disables. |
| `password_iterations` | `600000` | Server-side hashing iterations for new users. |
| `password_hints_allowed` | `true` | Allow users to set password hints. |
| `show_password_hint` | `false` | Keep password hints off public pages. |
| `client_suppress_onboarding` | `false` | Suppress client onboarding/promotional interstitials when enabled. |
| `require_device_email` | `false` | Require successful new-device mail for login when enabled. |
| `email_token_size` | `6` | Email 2FA token digits. |
| `email_expiration_time` | `600` | Email 2FA token lifetime in seconds. |
| `email_attempts_limit` | `3` | Email 2FA attempt limit before reset. |
| `email_2fa_enforce_on_verified_invite` | `false` | Set up email 2FA on verified invites when enabled. |
| `email_2fa_auto_fallback` | `false` | Automatically use email 2FA fallback when enabled. |
| `admin_ratelimit_seconds` | `300` | Vaultwarden's own admin-login average rate-limit interval. |
| `admin_ratelimit_max_burst` | `3` | Vaultwarden's own admin-login burst. |
| `admin_session_lifetime` | `20` | Admin-session lifetime in minutes. |
| `login_ratelimit_seconds` | `60` | Login average rate-limit interval. |
| `login_ratelimit_max_burst` | `10` | Login/2FA burst. |
| `unauthenticated_ratelimit_seconds` | `60` | Shared unauthenticated recovery/hint/Send interval. |
| `unauthenticated_ratelimit_max_burst` | `50` | Shared unauthenticated endpoint burst. |

The runtime renders these settings explicitly into the pinned Vaultwarden container rather than relying on undocumented implicit defaults.

### Vaultwarden Admin settings are not a second durable authority

Upstream Vaultwarden writes Admin-panel settings to `DATA_FOLDER/config.json`, and that saved file overrides environment variables. That behavior conflicts with the appliance's one-config-owner rule and can make a value edited in the web UI silently override `config.toml` after a restart.

VaultWarden-OCI therefore points Vaultwarden's `CONFIG_FILE` at `/tmp/vaultwarden-admin-config.json`, which lives on the container's existing tmpfs. The web Admin interface can still make temporary in-process changes for troubleshooting, but they are not durable appliance configuration. Existing `/data/config.json` files are ignored. Make persistent changes through `sudo vwctl config edit` and restart when prompted.

This matters especially for SMTP: a historical `config.json` can no longer override the appliance's shared SMTP host, sender, or credentials.

## Shared SMTP

`[smtp]` is the single non-secret mail configuration for both:

1. Vaultwarden application mail: invitations, verification, email 2FA, new-device mail, and the Vaultwarden Admin SMTP test.
2. VaultWarden-OCI's direct authenticated SMTP path, including `vwctl notification test --smtp` and eligible operational-notification fallback.

The corresponding `smtp_username` and `smtp_password` exist only in SOPS and are materialized into the Vaultwarden container at runtime. There is no second Vaultwarden-specific SMTP password.

Fresh setup writes:

```toml
[smtp]
host = "smtp.invalid"
port = 587
security = "starttls"
from_email = "vaultwarden@vault.example.com"
from_name = "Vaultwarden"
timeout_seconds = 15
embed_images = true
accept_invalid_certs = false
accept_invalid_hostnames = false
```

Replace `smtp.invalid` and set the SOPS credentials before first production start. Keep certificate and hostname validation enabled outside deliberate lab testing.

Test the shared transport directly before diagnosing application-specific behavior:

```bash
sudo vwctl notification test --smtp
```

If that succeeds, the host/port/TLS/username/password/sender path is usable. If the Vaultwarden Admin test still fails, inspect the HTTP status and Caddy/Vaultwarden logs rather than assuming the SMTP server rejected the message.

## Caddy `/admin` settings and the 429 SMTP-test symptom

Fresh setup also writes:

```toml
[caddy]
admin_rate_limit_events = 60
admin_rate_limit_window = "1m"
```

The old V2 Caddy route limited **all** `/admin*` HTTP requests to only 5 requests per 5 minutes. The Vaultwarden Admin page performs multiple page/API requests, so ordinary navigation or an SMTP test could exhaust that outer budget. Caddy then returned HTTP `429`, and the Vaultwarden Admin JavaScript attempted to parse the non-JSON rate-limit response, producing the secondary `SyntaxError: Unexpected end of JSON input` message.

The default is now 60 requests per minute for the outer interactive route. This is still bounded, while two other protections remain independent: Caddy Basic Auth at the outer boundary and Vaultwarden's own admin-login limiter (`admin_ratelimit_seconds = 300`, `admin_ratelimit_max_burst = 3`). This fixes normal interactive use without turning `/admin` into an unthrottled endpoint.

Allowed Caddy values are 10-1000 events and a simple positive `s`, `m`, or `h` duration such as `30s`, `1m`, or `1h`.

## Optional operational HTTPS notifications

Setup does not preselect a notification API provider because it cannot truthfully invent an account or provider choice. Add `[notifications]` only when needed, then keep its API token in SOPS as `email_api_token`. The authenticated SMTP path above remains available independently and is always the canonical Vaultwarden mail transport.

## Other stack components

The same discoverability rule applies across the stack, but only where there is a safe operator choice. Caddy's supported `/admin` rate-limit controls are pre-populated. SMTP safety controls are pre-populated. Cloudflare tokens, CrowdSec remediation, rclone destinations, storage identity, systemd timers, Docker runtime limits, and proxy-trust behavior are either credentials, workflow inputs, or appliance-owned safety controls rather than free-form application settings, so they intentionally do not become a generic `[options]` bag.

Use [Operations](OPERATIONS.md) for those supported workflows and [Security](SECURITY.md) for the boundaries that remain intentionally non-configurable.
