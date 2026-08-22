# Operations

`vwctl --help` and each subcommand's `--help` output are the command reference. Keep automation tied to command behavior and stable diagnostic IDs instead of copying a generated manual into the repository.

## Routine lifecycle

```bash
sudo vwctl start
sudo vwctl status
sudo vwctl doctor
sudo vwctl doctor --json
sudo vwctl logs --tail 200
sudo vwctl logs vaultwarden --tail 500
sudo vwctl restart
sudo vwctl stop
```

`status` reports Vaultwarden/Caddy state plus the latest recovery and notification state. `doctor --json` is the machine-readable diagnostic truth. Its top-level schema is versioned and each check has a stable ID; scripts should key on IDs/status rather than prose messages.

Important current IDs include:

- `runtime.docker`, `runtime.compose`, `runtime.paths`
- `secrets.custody`, `secrets.decrypt`
- `notification.catalog`, `notification.provider`, `notification.api_secret`, `notification.smtp_fallback`, `notification.last_delivery`
- the `edge.*`, `crowdsec.*`, and recovery checks emitted by their owners

A doctor `FAIL` blocks acceptance. `WARN` is intentionally visible and should not be rewritten to success by wrapper scripts.

## Logs

Runtime container logs are available through `vwctl logs`. Systemd automation logs remain in the journal:

```bash
journalctl -u vaultwarden-oci.service
journalctl -u vaultwarden-oci-health.service
journalctl -u vaultwarden-oci-backup.service
journalctl -u vaultwarden-oci-maintenance.service
journalctl -u 'vaultwarden-oci-notify@*'
```

There is no V2 dashboard/TUI or alternate status script.

## Systemd automation

The V2 target groups lifecycle plus health, backup, and maintenance timers:

```bash
sudo systemctl enable --now vaultwarden-oci.target
systemctl status vaultwarden-oci.target
systemctl list-timers 'vaultwarden-oci-*'
```

The installed services invoke `/opt/vaultwarden-oci/current/vwctl` directly. The notification template handles service failures; no Postfix/local MTA, spool, durable retry queue, or application scheduler is installed.

## Cloudflare edge and CrowdSec

Refresh the origin policy explicitly when needed:

```bash
sudo vwctl edge refresh
sudo vwctl crowdsec status
```

The edge owner validates bounded public Cloudflare CIDRs and applies both IPv4 and IPv6 policy while a scoped fail-closed guard protects published port 443. A current policy is preferred; only a bounded last-known-good policy is accepted as fallback.

CrowdSec beta remediation is Cloudflare-only:

```bash
sudo vwctl crowdsec setup
sudo vwctl crowdsec remediation-start
# Verify every created Worker Route is Fail Open in Cloudflare.
sudo vwctl crowdsec confirm-fail-open
sudo vwctl crowdsec status
```

The confirmation is deliberately explicit because Cloudflare route behavior is external state. V2 does not require or install a CrowdSec host firewall bouncer.

## Notifications

Operational notifications use exactly six built-ins from the immutable `email-providers.toml`: `mailersend`, `sendgrid`, `mailgun`, `postmark`, `resend`, and `cyberpersons`; `cyberpanel` resolves to `cyberpersons`.

The provider API is attempted first with bounded retries only for catalog-declared transient responses or network/connectivity failures. Direct authenticated TLS SMTP is attempted only after an eligible transient API outcome. It is not a durable queue and it does not mask authentication, TLS verification, permanent provider, or ambiguous response failures.

For CyberPersons, `503 service_unavailable` is the current status-only transient rule. `429 rate_limit_exceeded` remains visible because the provider uses the same status for account-wide minute/hour/day/month limits shared by API and SMTP credentials, so status alone cannot prove a bounded transient condition. `500 send_failed` also remains visible and is not fallback-eligible by status alone. Provider metadata is release data: re-check current official documentation before changing retry/success rules.

## Recovery and rclone

Create a verified local recovery point:

```bash
sudo vwctl backup
```

Publish and remotely verify in the same operation:

```bash
sudo vwctl backup --remote REMOTE:path
```

Remote publication uses copy semantics, never destructive sync. Pruning is a separate plan/confirm operation:

```bash
sudo vwctl recovery prune --remote REMOTE:path --keep-last 7
sudo vwctl recovery prune --remote REMOTE:path --keep-last 7 --confirm
```

See [RECOVERY.md](RECOVERY.md) before any restore.

## Versions and updates

Show exact active/source pins:

```bash
vwctl versions
```

Production updates are explicit and source-pinned:

```bash
cd /path/to/trusted/new-release
sudo vwctl update check --source "$PWD"
sudo vwctl update apply --source "$PWD"
```

The update path gates current `status` and `doctor --json`, creates a verified pre-update recovery point, validates exact image/component pins, stages a new immutable release, switches `current`, and gates the activated runtime. If release content changes, `vaultwarden_oci.version` in `versions.toml` must change as well.

`--use-latest` is not an operator update mode. It is allowed only with `VWOCI_DEVELOPMENT=1` and a non-production `--root`, where remote versions/digests are resolved once and recorded as exact values for that run.

## Configuration changes

After editing `config.toml` or the SOPS document:

```bash
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
sudo vwctl doctor --json
sudo vwctl restart
sudo vwctl status
```

Do not create alternate wrappers that mutate the same state. The single CLI and its mutation lock are the supported authority.
