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

An upgraded installation can have one additional bounded transition before that normal restart offer. If an existing Vaultwarden Admin `config.json` is present, see [Existing Vaultwarden Admin configuration](#existing-vaultwarden-admin-configuration) below; the appliance keeps that file effective until the operator explicitly reconciles it instead of silently changing existing policy.

## Scheduled offsite backups

The optional `[backup]` table provides a single, non-secret setting: `remote = ""` (default local-only) or `remote = "offsite:Vaultwarden-OCI"` to upload every daily verified `.vwrec`. The saved destination must be a named rclone remote plus a safe relative folder. Configure it with `sudo vwctl recovery offsite configure` rather than editing systemd units. The command checks root's rclone setup/reachability and commits a validated config change. `sudo vwctl recovery offsite status` checks readiness; `sudo vwctl recovery offsite disable` restores local-only behavior without deleting any backup.

The provider OAuth tokens and other secrets belong only in root's protected rclone configuration, not here or in SOPS. The cloud access setup must also be kept separately off-host for lost-server recovery. Remote configuration is independent of Vaultwarden/Caddy restart; it affects the next backup invocation.

## Vaultwarden settings

Fresh setup writes the following supported `[vaultwarden]` keys. Existing valid minimal configurations remain compatible: omitted catalog keys receive these defaults when rendered.

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

The runtime renders these settings explicitly into the exact pinned Vaultwarden container rather than relying on undocumented implicit defaults. The curated environment-key set has a regression test tied to the exact pinned Vaultwarden configuration surface so a setting that the binary does not consume is not advertised as supported.

## Existing Vaultwarden Admin configuration

Upstream Vaultwarden normally writes Admin-panel settings to `DATA_FOLDER/config.json`, and that saved file overrides environment variables. A fresh appliance does not use that file as durable configuration: VaultWarden-OCI points `CONFIG_FILE` at `/tmp/vaultwarden-admin-config.json` on the container tmpfs, so web Admin changes are temporary/diagnostic and persistent changes belong in `config.toml` or SOPS.

An upgrade must not reach that end state by silently discarding policy that was already saved in `/data/config.json`. If a pre-existing non-empty Admin file is present and has not been explicitly reconciled, the candidate deliberately keeps `CONFIG_FILE=/data/config.json`. The old Admin policy therefore remains effective while the operator performs a one-time bounded reconciliation.

Run the supported editors. `vwctl` compares the old Admin file with the appliance-supported targets and displays supported differences without displaying secret values:

```bash
sudo vwctl config edit
sudo vwctl secrets edit
```

If a supported value still differs, finalization is refused and the old Admin file remains effective. Copy the desired supported values into `config.toml` and, for credentials, into SOPS. When all representable supported values agree, the interactive editor reports the names of legacy-only, incompatible, or sensitive keys that will no longer be honored and asks for explicit finalization. It does not print their values.

Finalization records a root-only marker bound to the SHA-256 of that exact historical `config.json`; the historical file is not deleted. On the next supported start/restart, runtime switches to `/tmp/vaultwarden-admin-config.json`, making `config.toml`/SOPS the sole durable authority. If that historical file is modified later, its digest no longer matches the finalization marker and the transition becomes pending again instead of silently ignoring newly persisted policy.

This transition is intentionally narrow. It is not a generic migration layer for every upstream Vaultwarden option. Supported settings are reconciled; unsupported or sensitive legacy keys require explicit operator acknowledgement before they stop participating.

## SMTP ownership and scope

The common SMTP authority consists of:

- `[smtp]` host, port, security mode, sender address/name, and timeout;
- SOPS `smtp_username` and `smtp_password`.

Those values are supplied to both Vaultwarden application mail (invitations, verification, email 2FA, new-device mail, and the Vaultwarden Admin SMTP test) and VaultWarden-OCI's direct authenticated SMTP path used by `vwctl notification test --smtp` and eligible operational-notification fallback. There is no second Vaultwarden-specific SMTP username/password.

Fresh setup also exposes three **Vaultwarden application-mail modifiers**:

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

`embed_images`, `accept_invalid_certs`, and `accept_invalid_hostnames` are rendered to Vaultwarden itself. They are not switches for the appliance's direct SMTP implementation. In particular, the direct operational SMTP path always uses normal certificate and hostname validation and intentionally does **not** inherit Vaultwarden's invalid-certificate or invalid-hostname exceptions. Keep those exception controls false in production.

Test the common endpoint, security mode, sender and credentials through the strict appliance SMTP path before diagnosing application-specific behavior:

```bash
sudo vwctl notification test --smtp
```

A success proves that common SMTP path under normal TLS validation. It does not prove a Vaultwarden-only TLS exception setting. If the Vaultwarden Admin test still fails, inspect its HTTP status and Caddy/Vaultwarden logs rather than assuming the SMTP server rejected the message.

Operational HTTPS notification tests also identify the actual delivery route in the message body: normal provider API delivery is labelled as that HTTPS API, direct SMTP is labelled as direct authenticated SMTP, and an eligible transient API failure that actually falls back is labelled as authenticated SMTP fallback.

## Caddy `/admin` settings and the 429 SMTP-test symptom

Fresh setup writes:

```toml
[caddy]
admin_rate_limit_events = 60
admin_rate_limit_window = "1m"
```

The previous Caddy route limited **all** `/admin*` HTTP requests to only 5 requests per 5 minutes. The Vaultwarden Admin page performs multiple page/API requests, so ordinary navigation or an SMTP test could exhaust that outer budget. Caddy then returned HTTP `429`, and the Vaultwarden Admin JavaScript attempted to parse the non-JSON rate-limit response, producing the secondary `SyntaxError: Unexpected end of JSON input` message.

The default is now 60 requests per minute for the outer interactive route. This is still bounded, while two other protections remain independent: Caddy Basic Auth at the outer boundary and Vaultwarden's own admin-login limiter (`admin_ratelimit_seconds = 300`, `admin_ratelimit_max_burst = 3`). This fixes normal interactive use without turning `/admin` into an unthrottled endpoint.

Allowed Caddy values are 10-1000 events and a simple positive `s`, `m`, or `h` duration such as `30s`, `1m`, or `1h`.

## Cloudflare DNS updates (DDNS)

The built-in DNS updater uses the vault hostname in `[site].domain` and the existing encrypted `cloudflare_api_token`. There is **no second DDNS token, Zone ID, or configuration block**. In Cloudflare, you must first create **exactly one Proxied (orange-cloud) IPv4 A record** for this hostname, and no explicit AAAA record. The updater discovers the server's public IPv4 and changes **only that existing A record's IPv4 content**. It never creates a record, changes proxy status, or publishes IPv6.

```bash
sudo vwctl dns status             # See server IP, record IP, and sync state
sudo vwctl dns update --dry-run   # Preview; no DNS write
sudo vwctl dns update             # Apply, after the first healthy start
```

After enabling `vaultwarden-oci.target`, a separate DNS service runs on the five-minute health schedule. DNS failure cannot fail local health; the first two consecutive transient timer failures are deferred, while the third fails the DNS service. Unsafe record/credential/read-back failures fail immediately. See [Operations](OPERATIONS.md) and [Troubleshooting](TROUBLESHOOTING.md).

## Optional automatic failure alerts

**Application SMTP is not the same as automatic alerts.** The required `[smtp]` settings and encrypted `smtp_username`/`smtp_password` support Vaultwarden invitations, verification and other account mail. SMTP alone **does not enable systemd failure notifications**.

To receive those alerts, choose a built-in **HTTPS email provider**, a recipient, and its API token. Add this using `sudo vwctl config edit`:

```toml
[notifications]
provider = "mailersend"
to_email = "alerts@example.com"
```

Replace the provider and recipient with yours. Store its token as `email_api_token` through `sudo vwctl secrets edit`; never put the token in TOML. Supported provider IDs: `mailersend`, `sendgrid`, `mailgun`, `postmark`, `resend`, `cyberpersons` (also `cyberpanel`). Your provider may require verified sending domains and senders.

Mailgun needs an additional sending-domain option, and its region defaults to `us`. Use the following example **instead of**, not alongside, the first one:

```toml
[notifications]
provider = "mailgun"
to_email = "alerts@example.com"

[notifications.options]
domain = "mg.example.com"
region = "us"
```

The HTTPS API is tried first. Only classified temporary network/provider failures qualify for bounded retry and authenticated SMTP fallback; permanent, authentication, TLS, and ambiguous failures remain visible. There is no local mail queue. CyberPersons HTTP 503 is retryable by status, but HTTP 429 and 500 are not.

Test with real messages:

```bash
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
sudo vwctl secrets validate
sudo vwctl notification test          # Requires [notifications]
sudo vwctl notification test --smtp   # Direct SMTP; does not require [notifications]
```

The direct SMTP test uses `notifications.to_email` if present or `site.acme_email` otherwise. SMTP test success alone does **not** prove automatic alerts are enabled. Check `notification.*` in `sudo vwctl doctor --json`.

## Other stack components

The same discoverability rule applies across the stack, but only where there is a safe operator choice. Caddy's supported `/admin` rate-limit controls are pre-populated. SMTP controls are pre-populated with the scope described above. Cloudflare tokens, CrowdSec remediation, rclone destinations, storage identity, systemd timers, Docker runtime limits, and proxy-trust behavior are either credentials, workflow inputs, or appliance-owned safety controls rather than free-form application settings, so they intentionally do not become a generic `[options]` bag.

Use [Operations](OPERATIONS.md) for those supported workflows and [Security](SECURITY.md) for the boundaries that remain intentionally non-configurable.

For validation, restart, Admin, SMTP, or secret-custody failures, use the symptom-oriented [Troubleshooting guide](TROUBLESHOOTING.md) rather than editing rendered runtime files directly.
