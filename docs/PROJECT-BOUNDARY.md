# Project Boundary — VaultWarden-OCI

VaultWarden-OCI is a secure, self-running Vaultwarden appliance for small teams, not a generic Vaultwarden framework. It is intended for a small production deployment managed by one junior administrator who needs safe defaults, clear recovery paths, and set-and-forget operations.

## Supported normal production path

The supported golden path is:

- Ubuntu 24.04 LTS Noble host on amd64 or arm64
- Cloudflare DNS, proxy, and WAF
- Caddy with DNS-01 certificates using Cloudflare
- Vaultwarden
- Postfix sidecar for reliable outbound mail
- CrowdSec host service with Cloudflare edge enforcement
- SOPS + Age encrypted secrets
- rclone/offsite backup
- systemd automation for backups, health checks, maintenance, DNS, and firewall updates

## First-run rule

Advanced features must not complicate first-time setup. The default docs and `.env.example` should keep a junior admin on the secure Cloudflare + Postfix + CrowdSec + SOPS/Age + rclone + systemd path.

## Advanced or optional topics

These remain supported where implemented, but should live outside the first-run path:

- Alternate TLS modes such as direct HTTP-01 (`acme_http`)
- Push notifications
- Dedicated volume migration and storage adoption workflows
- Provider-specific email API routing
- Disaster-recovery rehearsal details
- Deep CrowdSec Workers, KV, free-plan, and bouncer internals

## Explicit product-scope decisions

These decisions are intentional and should not be reopened as generic cleanup work without new product evidence:

- **C1 — `acme_http`: keep.** Direct HTTP-01 remains an advanced fallback. Cloudflare DNS-01 stays the first-run and normal production path.
- **C2 — macOS developer convenience: keep only in developer/test tooling.** Production host code assumes the supported Ubuntu Noble GNU userspace and must not carry BSD/macOS runtime branches.
- **C3 — restore start-policy aliases: keep.** `--start` and `--no-start` remain concise aliases for `--start-policy auto` and `--start-policy manual`; they do not create a second policy authority.
- **C4 — HTTP email providers: keep.** Provider API drivers remain advanced alternatives. Postfix/direct SMTP remains the normal production interface and first-run path.
- **C5 — CrowdSec advanced modes: keep the currently documented modes only.** The normal installer remains the daemon-backed Cloudflare Workers path. Existing proxy-disabled/autonomous modes remain advanced options; do not add more variants without a demonstrated small-team need.

## Version and host policy

The project is pre-release. `VERSION` is a development identifier until the first real release. Production setup consumes source-controlled version pins by default. An explicit `--use-latest` override remains available for operator-requested live-version runs, but it is outside the normal/golden path. Runtime host code targets Ubuntu 24.04 LTS Noble on amd64/arm64 and may use its GNU toolchain directly.
