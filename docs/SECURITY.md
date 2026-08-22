# Security

V2 keeps the supported security boundary intentionally small: one Ubuntu host, immutable release code, root-owned operator configuration, SOPS/Age encrypted credentials, volatile plaintext, Cloudflare-restricted origin ingress, and closed notification/provider metadata.

## Trust and privilege boundaries

- Treat the V2 release/checkout and `versions.toml` as trusted release inputs.
- `/etc/vaultwarden-oci` is root-owned configuration/credential custody; `/var/lib/vaultwarden-oci` is durable service/recovery state; `/run/vaultwarden-oci` is volatile generated material.
- Runtime containers use fixed non-root IDs, read-only roots, dropped capabilities, `no-new-privileges`, bounded resources, and narrowly mounted data/secrets.
- `vwctl` is the only supported mutation authority. There is no dashboard/TUI, arbitrary hook/plugin SDK, or generic HTTP scripting facility.

## SOPS + Age

The SOPS document must be encrypted to two different Age recipients: an operational identity kept root-only on the host and an offline recovery identity kept away from the host. Startup and doctor validate that both recipients are present and distinct.

Plaintext credentials are not written into `config.toml`, release files, Compose source, logs, or recovery archives. Required runtime values are materialized under `/run/vaultwarden-oci/secrets` with narrow ownership/modes and are removed on normal stop/failure cleanup. Host-side remediation/API tokens remain in process memory rather than runtime secret mounts.

The operational Age private key is intentionally excluded from V2 recovery artifacts. A stolen recovery file alone must not provide its own decryption identity.

## Cloudflare origin ingress

V2 obtains Cloudflare IPv4/IPv6 ranges over HTTPS, strictly validates public canonical CIDRs, bounds list sizes, rejects overlaps/unsafe ranges, and stores a time-bounded last-known-good policy. Before refresh it inserts a scoped `DOCKER-USER` guard that blocks published HTTPS toward the V2 bridge. Only after both families are rebuilt successfully is the guard removed.

Therefore an invalid/unavailable current policy plus an unusable cached policy fails closed. The policy is scoped to origin ingress and is not a general host firewall manager.

CrowdSec beta remediation sends web decisions to Cloudflare. A CrowdSec host firewall bouncer is explicitly outside the beta architecture. Cloudflare Worker Routes created for the remediation path must be checked as Fail Open and confirmed through `vwctl crowdsec confirm-fail-open` so a bouncer outage does not become an application outage.

## Operational notifications

`email-providers.toml` is immutable release data with exactly six built-ins. The parser accepts only a closed schema: fixed/narrowly substituted HTTPS endpoints, finite auth modes, JSON/form encoding, declared success/retry rules, and the exact canonical message vocabulary:

```text
from_email | from_name | from_header | to_email | subject | text
```

Operator TOML can select a provider and declared non-secret options; it cannot supply arbitrary endpoints, auth headers/modes, request templates, success rules, or retry rules. Authorization-bearing HTTPS requests do not follow redirects. Response bodies are bounded and sensitive full responses are not persisted.

Routine upstream endpoint/auth/request/success/retry changes belong in the closed catalog plus focused tests/docs. Python changes are reserved for a genuinely new transport capability that the existing schema cannot represent safely.

### CyberPersons/CyberPanel

`cyberpersons` is canonical; `cyberpanel` is only an alias. The API credential must have `can_send` and the sending domain must be verified with the provider. The API token belongs in SOPS as `email_api_token`.

If CyberPersons SMTP is used for fallback, use independent SMTP credentials in `smtp_username`/`smtp_password`; the API token is not an SMTP password. The supported CyberPersons SMTP settings are port 587 with STARTTLS.

Phase 8 re-verified the provider contract on 2026-08-21. HTTP `503 service_unavailable` is the current status-only transient rule. HTTP `429 rate_limit_exceeded` is not classified transient by status alone because current provider documentation uses 429 for minute/hour/day/month account limits and says those limits are shared across API keys and SMTP credentials. HTTP `500 send_failed` also remains visible and is not SMTP-fallback eligible by status alone. Any later provider change must be re-verified against current official documentation before catalog edits.

## SMTP

Vaultwarden application mail is direct authenticated SMTP. Operational fallback uses the same configured SMTP transport only after a clearly transient API/network outcome. TLS uses the platform default trust store with either required STARTTLS or implicit TLS; there is no plaintext downgrade.

V2 has no Postfix/local MTA, spool, durable retry/dead-letter queue, or provider-specific queue tooling. If delivery fails permanently, that failure remains observable rather than being hidden behind a local queue.

## Recovery

The only supported recovery format is V2 `.vwrec`, encrypted to the configured offline Age recipient. Restore validates the Age envelope, manifest, safe paths, complete file set, sizes/checksums, SQLite integrity, and SOPS custody before promotion. There is no V1 reader or migration path.

rclone publication is non-destructive: local verification, `copyto`, remote re-download, checksum verification, success. Remote pruning requires a separate explicit command and confirmation.

## Exact versions

Production `versions.toml` carries exact component versions and architecture-specific image digests. Production install/update never resolves mutable “latest” values. The development-only resolver is gated by `VWOCI_DEVELOPMENT=1`, refuses `/`, resolves each remote boundary once, and records exact values.

## Security diagnostics

Use:

```bash
sudo vwctl doctor --json
```

Treat stable check IDs and statuses as diagnostic truth. In particular, do not ignore `secrets.custody`, `secrets.decrypt`, `runtime.paths`, `notification.catalog`, Cloudflare edge checks, or CrowdSec remediation checks during release acceptance.
