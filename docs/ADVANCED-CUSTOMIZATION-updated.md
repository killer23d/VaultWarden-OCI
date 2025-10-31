# ADVANCED CUSTOMIZATION

Guidance for optional tuning and extensions while keeping the small-team, low-maintenance goals intact.

## Compose & Networking
- Networks: default bridge with named network; avoid host networking for isolation.
- IPAM: project-scoped subnet ensures predictable container addressing.
- Service depends_on with health conditions ensures startup order without brittle sleeps.

## Caddy
- Security headers are enabled; extend Content-Security-Policy (CSP) only if introducing external assets.
- Enable WebSockets by uncommenting the /notifications/hub* route when WEBSOCKET_ENABLED=true.
- Optional rate limiting:
  - General: 60/min per IP; Admin: 10/min per IP.
  - Keep limits modest; Cloudflare already provides significant edge protections.

## fail2ban
- Filters: vaultwarden-admin, vaultwarden-api tuned to Caddy JSON logs.
- Action: cloudflare-optimized adds rate limiting (≈30 calls/min), timeouts, and logging.
- Jails: avoid overly aggressive botsearch rules to prevent blocking legitimate services.
- SSH jail: stricter thresholds and longer bans (24h) than HTTP jails.

## UFW
- Cloudflare IP ranges downloaded and applied; on failure, script warns and offers safe options.
- Consider moving SSH to a non-standard port and update .env SSH_PORT accordingly.
- Periodically verify Cloudflare IP lists or re-run setup if necessary.

## Versions & Resources
- Pin versions in .env for stability; unpin during testing, then re-pin validated versions.
- Resource limits set for 1 OCPU / 6 GB RAM; adjust conservatively if usage grows.
- Keep total CPU limits below host capacity; leave headroom for OS and maintenance.

## Backups
- Increase retention based on storage; prioritize emergency kits offsite.
- Consider a periodic manual integrity test (restore --validate-only) on non-prod.
- rclone remotes: prefer object storage with lifecycle rules for cost control.

## Secrets & SOPS
- Enforce least privilege on Cloudflare tokens; scope to specific zones.
- Rotate secrets annually or after incidents; use edit-secrets.sh to manage encryption.
- Keep Age key backed up offline; store emergency kit and key separately.

## OCI-Specific
- Use Ampere A1 Flex shapes for cost efficiency; allocate 1 OCPU with 6 GB RAM.
- Utilize console connections only for emergencies; remove after each use.
- Tag resources for auditing; restrict IAM where feasible.

## Observability
- Health script summarizes status; extend with external monitors (HTTP probe + cert expiry).
- Log shipping optional: tail Caddy JSON logs to a lightweight aggregator if desired.
- Alerts: simple mailutils notifications can be integrated in backup_utils.

## Minimal Footprint Principle
- Prefer fewer moving parts; do not add databases, message queues, or sidecars unless essential.
- Revisit customizations quarterly; remove changes that don’t provide clear operational value.
