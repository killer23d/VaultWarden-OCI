# API

Reference for operational APIs used by the stack and how they integrate, with scopes/principles of least privilege.

## Cloudflare
- DNS API (Caddy / ACME DNS-01): token with Zone:DNS:Edit + Zone:Zone:Read, scoped to the specific zone used.
- Firewall API (fail2ban): token with Zone:Firewall Services:Edit, scoped to the same zone.
- Rate limits: fail2ban action is internally rate-limited to ~30 calls/min with short delays when exceeded.

### Endpoints (for validation/testing)
- Zones: GET https://api.cloudflare.com/client/v4/zones
- Access Rules (list): GET https://api.cloudflare.com/client/v4/zones/{zone_id}/firewall/access_rules/rules
- Access Rules (create): POST https://api.cloudflare.com/client/v4/zones/{zone_id}/firewall/access_rules/rules
- Access Rules (delete): DELETE https://api.cloudflare.com/client/v4/zones/{zone_id}/firewall/access_rules/rules/{rule_id}

Headers:
- Authorization: Bearer <TOKEN>
- Content-Type: application/json

## ddclient (Cloudflare DNS)
- Updates DNS A/AAAA records based on current public IP.
- Token scope: Zone:DNS:Edit for the target zone.
- Notes: Use proxied records in Cloudflare; origin is UFW-restricted to Cloudflare IPs.

## SMTP (Optional)
- Enables VaultWarden to send emails (verify address, invitations, etc.).
- Configure SMTP_* variables in .env and the smtp_password in secrets.
- Use STARTTLS or SMTPS as supported by your provider.

## Push (Optional)
- If using Bitwarden push notifications, set push_installation_id/key in secrets and WEBSOCKET settings accordingly.
- Alternatively, keep disabled for minimal footprint deployments.
