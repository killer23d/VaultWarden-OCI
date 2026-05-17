# VaultWarden-OCI — Ops Runbook

Quick reference for the most common operations. All commands assume you are in
the repository root on the server. Prefix with `sudo` where indicated.

---

## First Time / Recovery

For first-time setup on a new host:
1. Configure OCI Security List (ports `80`, `443`, and `22`).
2. Copy `.env.example` to `.env` and set at minimum: `DOMAIN`, `ADMIN_EMAIL`, `CLOUDFLARE_ZONE_ID`, and your email settings.
3. Run `sudo ./setup.sh install --domain <fqdn> --email <admin-email> --auto` (or `sudo make setup` if `.env` is already prepared).
4. Re-login so your user picks up `docker` group membership.
5. Start services with `make up` and verify with `make health`.

| Task | Command |
|------|---------|
| Initial setup (`.env` already prepared) | `sudo make setup` |
| Initial setup (recommended explicit command) | `sudo ./setup.sh install --domain <fqdn> --email <admin-email> --auto` |
| Start the stack | `make up` |
| Stop the stack | `make down` |
| Restart all services | `make restart` |

---

## Daily Operations

| Task | Command |
|------|---------|
| View service status | `make status` |
| View all logs (tail) | `make logs-tail` |
| View Vaultwarden logs | `make logs-vaultwarden` |
| View Caddy logs | `make logs-caddy` |
| View Postfix logs | `make logs-postfix` |
| View Fail2Ban logs | `make logs-fail2ban` |
| Watch live logs | `make watch` |

---

## Health & Monitoring

| Task | Command |
|------|---------|
| Full health check | `make health` |
| Quick health check | `make health-quick` |
| Test email delivery | `make health-email` |
| Check age key health | `make key-health` |
| Continuous monitoring (30s) | `make monitor` |
| Full diagnostic dump | `make diagnose` |

---

## Updates

| Task | Command |
|------|---------|
| Update container images | `make update` |
| Check for image updates (no restart) | `make check-updates` |
| Update host OS packages | `make update-system` |
| Update Cloudflare DNS records | `make update-dns` |

---

## Backup & Restore

| Task | Command |
|------|---------|
| Run incremental backup now | `make backup` |
| Run full backup (DB + attachments + config) | `make backup-full` |
| Create emergency backup kit | `make backup-emergency` |
| List available backups | `make list-backups` |
| Show backup health summary | `make backup-status` |
| Interactive restore (guided) | `make restore` |
| Restore from remote storage | `make restore-remote` |
| Restore database only | `make restore-db` |
| Verify restore prerequisites | `make restore-preflight` |

---

## Secrets Management

| Task | Command |
|------|---------|
| Edit encrypted secrets | `make edit-secrets` |
| Initialise secrets file | `make init-secrets` |
| Test secrets decryption | `make test-secrets` |

---

## Age Key Management

| Task | Command |
|------|---------|
| Show current age public key | `make key-show` |
| Check age key health | `make key-health` |
| Backup age key offline (interactive) | `make key-backup` |
| Generate encrypted escrow package | `make key-escrow` |
| Rotate age key (re-encrypts secrets) | `make key-rotate` |
| Install age key from `secrets/keys/` | `make key-install` |

---

## User Management

| Task | Command |
|------|---------|
| Create break-glass admin account | `make breakglass-create` |
| Check break-glass account status | `make breakglass-status` |
| Remove break-glass admin account | `make breakglass-remove` |

---

## Maintenance

| Task | Command |
|------|---------|
| Routine maintenance tasks | `make maintenance` |
| Full maintenance (all checks) | `make maintenance-full` |
| Database maintenance (VACUUM) | `make db-maint` |
| Quick database backup | `make db-backup` |
| Fix file permissions (post-sudo) | `make fix-permissions` |
| Prune unused Docker resources | `make prune` |

---

## Systemd Integration

| Task | Command |
|------|---------|
| Install systemd units & timers | `make install-systemd` |
| Show systemd unit status | `make systemd-status` |
| Show scheduled timer status | `make timers` |
| Validate systemd unit files | `make systemd-validate` |
| Remove systemd units | `make remove-systemd` |

---

## SSH Break-Glass Access

If you are locked out of the Vaultwarden admin panel:

```bash
# 1. Create a temporary break-glass admin account
make breakglass-create

# 2. Log in at https://<your-domain>/admin with the generated credentials

# 3. Remove the break-glass account after resolving the issue
make breakglass-remove
```

---

## Tear-Down

| Task | Command |
|------|---------|
| Preview uninstall (dry run) | `make uninstall-dry-run` |
| Full uninstall (interactive) | `make uninstall` |
