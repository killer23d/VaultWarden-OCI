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
