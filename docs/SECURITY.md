# Security

VaultWarden-OCI keeps the supported security boundary intentionally small: one Ubuntu 24.04 appliance host, dedicated persistent storage, immutable release code, root-owned operator configuration, SOPS/Age encrypted credentials, volatile plaintext, Cloudflare-restricted origin ingress, a closed notification catalog, and explicit recovery/update boundaries.

## Trust and privilege boundaries

- Treat the trusted release and `versions.toml` as release inputs.
- `/etc/vaultwarden-oci` is the operator configuration/credential-custody authority and remains root-owned.
- Persistent application/recovery state must live on the validated dedicated production filesystem/volume, not solely on the boot/root filesystem.
- `/run/vaultwarden-oci` is volatile generated/decrypted material.
- Runtime containers remain least-privileged: fixed non-root identities where applicable, read-only roots, dropped capabilities, `no-new-privileges`, bounded resources, and narrow mounts.
- `vwctl` is the implementation/mutation authority. `setup.sh` and `dashboard.sh` are supported human interfaces but must delegate mutations rather than create parallel state authorities.

## SOPS + Age

The encrypted SOPS document uses distinct operational and offline recovery identities.

The operational Age private identity is root-only on the appliance. The separate offline recovery private identity is kept away from the server and is not persistently stored there. Plaintext credentials are not written into operator config, release files, Compose/Caddy source, ordinary logs, or application recovery archives. Required runtime values are materialized only in the root-owned volatile runtime tree and removed during normal cleanup.

A stolen `.vwrec` application recovery file must not contain the operational Age private key or otherwise carry its own decryption identity.

## Dedicated-storage fail-safe

Production services must not silently write persistent application/recovery state to the root filesystem if the intended dedicated storage is missing or mounted incorrectly.

The setup/start/doctor path must validate the dedicated-storage invariant and fail safely. A missing mount is an availability failure, not permission to create replacement state directories on `/`.

## Caddy real-client-IP trust

Caddy remains an exact-pinned xcaddy custom build with:

- Cloudflare DNS;
- Cloudflare trusted-proxy/real-client-IP support;
- combined Cloudflare IP ranges;
- Caddy rate limiting.

Caddy's Cloudflare trusted-proxy module is the single authority for trusting `CF-Connecting-IP`/equivalent client-IP information. Do not also render a static Cloudflare CIDR `trusted_proxies` block into the Caddy configuration.

This is a request-layer trust decision, not an origin firewall.

## Cloudflare-only origin ingress

Host-level origin protection is separate from Caddy's trusted-proxy handling.

The appliance maintains one small project-owned Docker `DOCKER-USER` path that allows published HTTPS only from strictly validated Cloudflare IPv4/IPv6 source ranges. A bounded last-known-good range set may be used; if neither live nor acceptably fresh cached policy is safe, published HTTPS remains blocked.

The Caddy trusted-proxy module does **not** replace this origin filter. Conversely, the origin source allowlist does not decide the end-user client identity Caddy should trust.

CrowdSec remediates proxied web-client decisions through Cloudflare. A CrowdSec host firewall bouncer is outside the supported architecture. Do not combine the origin filter and CrowdSec into one ambiguous decision plane.

## `/admin` defense in depth

Keep `/admin` deliberately simple and layered:

1. Vaultwarden admin token;
2. Caddy-side rate limiting;
3. one simple outer authentication gate.

Do not add an enterprise identity stack or stack multiple redundant outer authentication products around the admin endpoint.

## Operational notifications

`email-providers.toml` is immutable release data containing the closed supported provider definitions. The parser/operator config must not become a general HTTP scripting mechanism.

The canonical message vocabulary remains:

```text
from_email | from_name | from_header | to_email | subject | text
```

Operator config may choose a supported provider and declared non-secret options. It may not supply arbitrary endpoints, authentication headers/modes, request templates, success rules, or retry rules. Authorization-bearing HTTPS requests must retain normal TLS verification and must not leak credentials through redirects/logs/status persistence.

Routine upstream endpoint/auth/request/success/retry changes belong in the closed catalog plus focused tests/docs when the existing schema can safely express them.

### CyberPersons / CyberPanel

`cyberpersons` is canonical; `cyberpanel` is only an alias. API credentials belong in SOPS as `email_api_token`. If SMTP fallback uses the same vendor, use independent SMTP credentials; the API token is not an SMTP password.

Current verified classification is:

- HTTP `503 service_unavailable`: status-only transient/retry/fallback eligible;
- HTTP `429 rate_limit_exceeded`: not transient by status alone because the current provider uses it for account-wide minute/hour/day/month limits shared by API and SMTP credentials;
- HTTP `500 send_failed`: not transient by status alone and not SMTP-fallback eligible merely because it is HTTP 500.

Do not reintroduce the older 429-is-always-transient assumption. Re-verify current official provider documentation before a focused catalog behavior change.

## SMTP

Vaultwarden application mail is direct authenticated SMTP. Operational SMTP fallback occurs only after a clearly transient API/network outcome. TLS uses the platform trust store and an authenticated encrypted transport; there is no plaintext downgrade.

There is no Postfix/local MTA, durable spool, dead-letter queue, or provider-specific queue tooling. Permanent failures remain visible.

## Recovery

The normal application recovery format is one encrypted `.vwrec`. Restore validates/decrypts/checks/stages before promotion and retains explicit CLI forms for automation plus a guided local/remote picker for humans.

The password-protected recovery-kit ZIP is a **different security artifact** used for credential handoff. It uses AES-256 ZIP encryption with a passphrase entered and confirmed interactively. That passphrase is independent of stored credentials and is never accepted through argv, environment variables, files, or email. The encrypted ZIP must be verified before any email handoff is attempted.

Do not conflate possession of a recovery kit with a verified application recovery point.

## Exact versions and `--use-latest`

Normal installed application state is immutable and exact-pinned.

`setup.sh --use-latest` is a supported, explicit operator override. Its security requirement is that every mutable upstream boundary is resolved once to an exact version/digest and those immutable values are recorded/used thereafter. No installed config, image reference, or state may remain floating on `latest`.

## Application versus host updates

Application update and Ubuntu package update are separate trust/recovery domains.

Application update must stage/download/build before downtime where possible, verify a pre-update `.vwrec`, activate an immutable release, health-gate it, and roll back coherently only when safe. If candidate runtime state may have changed, do not pretend a binary rollback also reverted data.

Ubuntu apt/kernel changes cannot be rolled back by application recovery. The appliance never auto-reboots.

## Security diagnostics

Use the authoritative diagnostics after install/config/security changes:

```bash
sudo vwctl doctor --json
```

Treat secret custody/decryption, runtime/storage paths, notification catalog/provider, edge/origin, CrowdSec, and recovery checks as acceptance boundaries. Human dashboard presentation may summarize them but must not hide or reinterpret a `FAIL` as success.

## Current development-branch gaps

The current development branch still renders static Cloudflare trusted-proxy CIDRs, builds only the Cloudflare DNS xcaddy module, stores state under `/var/lib/vaultwarden-oci` without dedicated-storage enforcement, and lacks the approved dashboard/setup surfaces. Those are known implementation gaps and must not be cited as a reason to change the durable security contract.
