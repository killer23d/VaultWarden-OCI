# VaultWarden-OCI — Ops Runbook

Quick reference for the most common operations. All commands assume you are in
the repository root on the server. Prefix with `sudo` where indicated.

---

## First Time / Recovery

For first-time setup on a new host:

1. Configure OCI Security List (ports `80`, `443`, and `22`).
2. Copy `.env.example` to `.env` and set at minimum: `DOMAIN`, `ADMIN_EMAIL`,
   your email settings.
   Before running CrowdSec setup, inject the Cloudflare credentials into secrets:
   `sudo ./edit-secrets.sh rotate cloudflare_zone_id`,
   `sudo ./edit-secrets.sh rotate cf_account_id`, and
   `sudo ./edit-secrets.sh rotate cf_worker_bouncer_token`.
3. Run `sudo ./setup.sh install --domain <fqdn> --email <admin-email> --auto`
   (or `sudo make setup` if `.env` is already prepared).
4. Re-login so your user picks up `docker` group membership.
5. Start services with `make up` and verify with `make health`.
6. **After CrowdSec is installed**, set the Cloudflare Worker route to
   **Fail Open**: Cloudflare dashboard → your domain → Workers Routes → Edit
   → Request limit failure mode → Fail open.

See [docs/CROWDSEC.md](docs/CROWDSEC.md) for the full CrowdSec + Cloudflare
Workers bouncer setup guide.

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
| View CrowdSec logs | `make logs-crowdsec` |
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

## Post-deployment and post-recovery VM smoke check

From the repository root on the Ubuntu VM, use the smoke test as the normal
verification path after deployment or recovery:

```bash
sudo ./utilities/smoke-test.sh
```

If a check fails, run this compact troubleshooting sequence:

```bash
docker compose -f docker-compose.yml config --quiet

sudo systemd-analyze verify \
  /etc/systemd/system/vaultwarden-startup.service

# Operator remediation when the startup service is inactive; the smoke test
# reports this command but never starts the service itself.
sudo systemctl start vaultwarden-startup.service

sudo test \
  "$(stat -c '%U:%G %a' /run/vaultwarden-oci/secrets)" \
  = "root:root 700"

sudo find /run/vaultwarden-oci/secrets \
  -maxdepth 1 \
  -type f \
  \( ! -user root -o ! -group root -o ! -perm 0444 \) \
  -print

sudo bash -c '
  set -euo pipefail
  export PROJECT_ROOT="$PWD"
  source "$PROJECT_ROOT/lib/config.sh"
  load_project_environment
  SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE" \
    sops -d "$SECRETS_FILE" >/dev/null
'

curl -fsS https://<vault-domain>/api/alive
```

No output from `find` means it found no runtime secret file with an incorrect
owner, group, or mode. Successful SOPS verification intentionally sends all
plaintext to `/dev/null`; none of these checks should print secret values.
`/run/vaultwarden-oci/secrets` is transient and is expected to be recreated
after reboot by `vaultwarden-startup.service`. The documented `systemctl start`
command is an operator action and is never performed automatically by the smoke
test.

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
| Copy all retained local backups to rclone | `sudo ./backup.sh sync` |
| Interactive restore (guided) | `make restore` |
| Restore from remote storage | `make restore-remote` |
| Restore database only | `make restore-db` |
| Verify restore prerequisites | `make restore-preflight` |
| Disaster Recovery | Complete bare-metal restore from remote backup. See [docs/DISASTER-RECOVERY.md](docs/DISASTER-RECOVERY.md) |

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

## 🛡️ CrowdSec Operations

CrowdSec runs as a host systemd service (not a Docker container). It reads
Vaultwarden, Caddy, and SSH logs and bans attackers via Cloudflare Workers KV
(edge enforcement) and iptables (host-level enforcement).

For full setup, Cloudflare dashboard configuration, and troubleshooting see
[docs/CROWDSEC.md](docs/CROWDSEC.md).

### Service management

| Task | Command |
|------|---------|
| Check CrowdSec engine status | `sudo systemctl status crowdsec` |
| Check Workers bouncer status | `sudo systemctl status crowdsec-cloudflare-worker-bouncer` |
| Restart bouncer after config change | `sudo systemctl restart crowdsec-cloudflare-worker-bouncer` |
| View bouncer logs (live) | `sudo journalctl -u crowdsec-cloudflare-worker-bouncer -f` |
| Restart CrowdSec engine | `sudo systemctl restart crowdsec` |

### Decision management

| Task | Command |
|------|---------|
| View active bans | `sudo cscli decisions list` |
| View recent alerts | `sudo cscli alerts list --since 24h` |
| Manually ban an IP (24 h) | `sudo cscli decisions add --ip 1.2.3.4 --duration 24h` |
| Unban an IP | `sudo cscli decisions delete --ip 1.2.3.4` |
| View metrics | `make crowdsec-status` |
| Tail CrowdSec logs | `make logs-crowdsec` |
| View security events (last 1h) | `make security-report` |
| Check bouncer registration | `sudo cscli bouncers list` |

### Self-lockout prevention

Add your admin IP to the persistent CrowdSec allowlist using the setup script
(writes a YAML parser file that survives hub updates):

```bash
# Single IP
sudo ./utilities/setup-crowdsec.sh --admin-ip "$(curl -s https://ifconfig.me)"

# CIDR range
sudo ./utilities/setup-crowdsec.sh --admin-ip 203.0.113.0/24
```

### If you are locked out

If your IP is banned and you cannot access the vault:

```bash
# 1. SSH to the server (vault bans do not affect SSH)
# 2. Delete the ban immediately
sudo cscli decisions delete --ip <your-ip>
# 3. Add a persistent allowlist entry so it cannot recur
sudo ./utilities/setup-crowdsec.sh --admin-ip <your-ip>
```

### Re-run CrowdSec setup (e.g. after rotating the CF token)

```bash
./edit-secrets.sh rotate cf_worker_bouncer_token
sudo ./utilities/setup-crowdsec.sh --force
```

---

## Tear-Down

| Task | Command |
|------|---------|
| Preview uninstall (dry run) | `make uninstall-dry-run` |
| Full uninstall (interactive) | `make uninstall` |

## Resilient recovery quick reference

Run recovery on the replacement VM after attaching and mounting the data volume:

```bash
sudo ./recover.sh --state-dir /mnt/vw-data --key /media/usb/age-key.txt
```

Environment precedence is persistent install env, repository `.env`, then installed systemd env. Runtime secrets are regenerated in `/run/vaultwarden-oci/secrets/` on startup by `vaultwarden-startup.service`; they are not persistent and disappear on reboot.

Offline-key resolution is environment, manifest, existing policy, TTY prompt, then deliberate skip. To remove an offline recipient, make a staged ciphertext copy, update `.sops.yaml` deliberately, run `sops --config "$PWD/.sops.yaml" updatekeys --yes "$staging"`, validate decryption, then promote with `mv`.
