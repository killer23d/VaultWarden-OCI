# TROUBLESHOOTING

Quick resolution guide for common issues in small-scale, single-admin deployments.

## Setup & Templates
- Validation: docker compose config to check generated docker-compose.yml.
- Force regeneration: sudo ./setup.sh --force --domain X --email Y, then ./startup.sh --force-restart.
- Placeholders: ensure CLOUDFLARE_ZONE_ID set in .env; secrets edited via ./edit-secrets.sh.

## Networking & Firewall
- UFW status: sudo ufw status numbered (expect Cloudflare IP rules + SSH).
- Cloudflare IP fetch failed: check connectivity; add ranges manually then re-run setup.
- SSH locked out: use OCI serial console + break-glass admin; reopen SSH and rotate password.

## TLS / Caddy
- Certificates: docker compose exec caddy caddy list-certificates.
- Logs: docker compose logs caddy | tail -n 200.
- Admin basic auth: generate bcrypt hash and set admin_basic_auth_hash in secrets.

## fail2ban
- Status: docker compose exec fail2ban fail2ban-client status.
- Jails: vaultwarden-admin, vaultwarden-api, sshd; caddy-botsearch disabled by default.
- Cloudflare API: check logs for HTTP codes; tokens in secrets must have correct scopes.

## Backups
- Create: ./backup.sh --type db|full|emergency; List: ./backup.sh --list.
- Remote: configure rclone and set RCLONE_REMOTE_NAME in .env.
- Restore: ./restore.sh (interactive) or ./restore.sh --file X.

## Versions & Updates
- View pins: make pins; check updates: make check-updates.
- Safe update: backup → pin → update-containers → health.
- Rollback: re-pin prior versions; restore from last good backup if required.

## Health & Logs
- Health: ./health.sh; Status: make status.
- Service logs: docker compose logs SERVICE; Follow: make logs-follow SERVICE=…. 
- Disk: df -h and du -sh $PROJECT_STATE_DIR/data for capacity checks.

## Emergency
- Break-glass admin: ./create-breakglass-admin.sh; test OCI console access.
- After use: delete console connection, rotate break-glass password.
