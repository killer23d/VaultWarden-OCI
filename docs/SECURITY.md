# Security

VaultWarden-OCI keeps a small explicit trust boundary: one Ubuntu 24.04 appliance host, mandatory dedicated persistent storage, immutable release code, root-owned operator config, SOPS/Age encrypted credentials, volatile plaintext runtime material, Cloudflare-restricted public origin ingress, a closed notification catalog, and explicit recovery/update boundaries.

## Secrets and privilege

`/etc/vaultwarden-oci/config.toml` is the single durable non-secret operator configuration authority. `/etc/vaultwarden-oci/secrets.sops.yaml` is the encrypted credential authority. The root-only operational Age private identity stays on the appliance. The separate offline recovery private identity is never persistent server state: it normally stays off-host, but terminal-driven first-run setup, including `--auto`, may generate it only in root-owned volatile `/run` storage when no `--offline-recipient` was supplied. Only its public recipient is configured; the private identity enters the verified encrypted recovery kit and is removed from host-side volatile storage only after successful custody handoff. Fully headless setup must receive an existing public recipient. If an operator supplies `--offline-recipient` explicitly, that recipient is authoritative and setup must not silently generate or substitute another identity. Plaintext credentials do not belong in config, release metadata, ordinary logs, argv, or `.vwrec` artifacts.

Vaultwarden's upstream Admin UI normally persists edits in `DATA_FOLDER/config.json`, and that user file takes precedence over environment configuration. The appliance must not allow that file to become a second durable authority. Managed runtime therefore sets Vaultwarden `CONFIG_FILE` to `/tmp/vaultwarden-admin-config.json` on the container's existing tmpfs. Admin-panel changes can exist temporarily in the running process for diagnostics, but persistent changes belong in `config.toml`; an old `/data/config.json` is ignored by the managed runtime. This also prevents stale web-Admin SMTP values from overriding the appliance SMTP authority after restart.

Runtime containers use narrow mounts, fixed non-root identities where applicable, dropped capabilities/read-only roots where applicable, and `no-new-privileges`. Volatile generated/decrypted material belongs under `/run/vaultwarden-oci`. A transient setup-generated offline identity is a narrow first-run custody exception to the usual off-host location, not permission to retain that identity under `/run` after successful handoff.

## Dedicated-storage fail-safe

Production services are not allowed to silently write persistent application/recovery state to `/` if the intended volume is missing. Setup, mutating CLI commands, doctor, and the Docker systemd mount guard prove the dedicated storage identity. Missing or wrong storage is an availability failure, not permission to create replacement state on the boot disk. A fully headless `--auto` install that lacks an offline public recipient must fail before storage provisioning or other installation mutation; missing recovery custody is not permission to proceed and repair custody later.

## Caddy trust versus origin filtering

Caddy is an exact-pinned xcaddy build with Cloudflare DNS, Cloudflare trusted-proxy/real-client-IP support, combined Cloudflare ranges, and rate limiting. The trusted-proxy module is the single request-layer authority for trusting the real client IP; the project does not render a second static Cloudflare `trusted_proxies` CIDR list into Caddy.

The host-level `DOCKER-USER` path is separate. It allows published HTTPS only from strictly validated Cloudflare IPv4/IPv6 sources, uses bounded last-known-good data, and fails closed if no safe policy exists. Never disable this filter merely to make an origin test work.

CrowdSec is separate again. It ingests the appliance-owned Caddy and Vaultwarden logs plus Ubuntu SSH and kernel/firewall signals. The Cloudflare Worker remediates locally generated proxied web-client decisions where the trusted real client IP is enforceable. Its effective source filter must be exactly `only_include_decisions_from: ["cscli", "crowdsec"]`; broad CAPI/community/list decisions are deliberately kept off the Worker/KV path and consumed by the host-input firewall bouncer instead. A healthy Worker requires an invocation-bound attestation containing that exact source set and a digest of the exact base/local config files. A config edit or new systemd invocation invalidates that proof. The Worker remains boot-disabled and every recreated route requires a fresh explicit Fail Open confirmation for the current invocation.

The CrowdSec nftables firewall bouncer may consume broader CrowdSec/community/list decisions for host services, but it is constrained to the host `input` hook and must not claim Docker `forward` or `DOCKER-USER` ownership.

## `/admin`

When enabled, `/admin` has Vaultwarden's admin token, Caddy per-client rate limiting, and one outer Basic Auth gate. The high-entropy `vaultwarden_admin_token` value in SOPS remains the operator's recoverable `/admin` login secret; at start/restart the appliance uses the exact pinned Vaultwarden image to derive an Argon2id PHC and materializes only that PHC into the Vaultwarden runtime boundary. The source Basic Auth password is likewise encrypted in SOPS; only its derived hash is materialized into volatile Caddy runtime state. Removing both admin secrets deliberately disables/closes the admin route.

The rate limits are intentionally layered rather than duplicated at the same boundary. Caddy's outer interactive `/admin*` route defaults to 60 requests per minute per trusted real client IP, enough for normal Admin HTML/API activity while remaining bounded. Vaultwarden separately retains its much tighter admin-**login** limiter (300-second average interval with a burst of 3 by default). The previous outer 5-requests-per-5-minutes setting applied to every Admin request, not just authentication attempts, and could deny normal navigation or an SMTP test with HTTP 429 before Vaultwarden handled it. Raising only the outer interactive budget does not remove Basic Auth or weaken Vaultwarden's login-specific throttle.

## Notification and SMTP security

Operational HTTPS providers are defined only in immutable `email-providers.toml`. Operator config can select supported IDs/options but cannot inject arbitrary endpoints, auth headers/modes, request templates, success rules, or retry rules. Authorization-bearing HTTPS requests retain TLS validation and do not silently follow unsafe credential-bearing redirects.

Vaultwarden application mail and the appliance direct-SMTP path share one authenticated SMTP authority: `[smtp]` supplies host/port/TLS/sender settings and SOPS supplies `smtp_username`/`smtp_password`. Vaultwarden does not receive a separate credential set. Certificate and hostname validation default on; the explicitly visible invalid-cert/hostname switches are for deliberate exceptional use and should remain false in production. Operational SMTP fallback follows only an eligible transient API/network result. Permanent/authentication/TLS/ambiguous delivery failures remain visible; there is no local MTA, durable spool, queue, or dead-letter service.

## Recovery and update security

A `.vwrec` is encrypted application state and excludes the server operational Age private key. The recovery-kit ZIP is a different credential artifact with AES-256 encryption and an independent interactively entered passphrase. The ZIP must be fully verified before email handoff. Terminal-driven `--auto` can automate installation while still requiring this human recovery-kit passphrase/custody boundary when setup generated the offline identity; `--auto` does not weaken that boundary.

Application updates stage exact immutable content, verify a pre-update recovery point, health-gate activation, and refuse unsafe old-binary rollback after possible persistent-state mutation. A compatibility update that must recreate the Cloudflare Worker may stop before recovery so the operator can set the new route Fail Open and confirm that new local-only invocation; the previous Fail Open proof is never carried across the restart. Broader host CrowdSec package/Hub/acquisition/firewall migration is not performed until the rerun has a verified recovery point and enters candidate activation under the update transaction. Ubuntu package changes remain a separate recovery domain and the appliance never auto-reboots.

## Unsupported security-expanding designs

Do not add another Docker firewall owner, give the CrowdSec firewall bouncer `forward`/`DOCKER-USER` ownership, add an enterprise identity stack, arbitrary notification scripting, KMS/provider framework, dynamic plugin framework, Postfix/queue, generic repair engine, HA/Kubernetes layer, or compatibility reader for an earlier archive format without an explicit new product decision.

After security or credential changes, accept the interactive restart offer when appropriate or restart explicitly, then run:

```bash
sudo vwctl doctor --json
```

A human dashboard summary must never reinterpret a doctor `FAIL` as success.
