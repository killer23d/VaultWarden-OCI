# VaultWarden-OCI

**Production-Ready VaultWarden for Small Teams**

A streamlined, secure, and operationally excellent VaultWarden deployment optimised for teams of 10 or fewer users on Ubuntu. It works on generic Ubuntu hosts and keeps optional OCI-specific guidance separate from core setup. It emphasises template-based configuration, automated operations, and robust multi-layer security.

> **📖 New here? Start with [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for step-by-step setup instructions.**

## 🎯 What Makes This Different

This is a **template-based, hardened deployment** built for small teams who want:

- **Set-and-forget reliability** — automated backups, updates, health checks, and rollback
- **Template-first approach** — all config files maintained as `.example` templates; nothing hardcoded
- **Cloudflare-only web blocking** — iptables removed from proxied services; edge WAF used instead
- **Encrypted secrets** — Age + SOPS for industry-standard secrets management
- **Emergency recovery** — break-glass admin access and automatic rollback on failed updates
- **Simple day-to-day operations** — Makefile shortcuts covering the full lifecycle

---

## ⚡ Quick Start — Supported Golden Path

VaultWarden-OCI is an opinionated, secure appliance for a small team. The normal production path is **Ubuntu + Cloudflare DNS/proxy/WAF + Caddy DNS-01 + Vaultwarden + Postfix + CrowdSec + SOPS/Age + rclone + systemd timers**. See [docs/PROJECT-BOUNDARY.md](docs/PROJECT-BOUNDARY.md) for the project boundary.

### 1. Prepare Cloudflare and your provider firewall

Before setup, prepare the public path:

- Create `vault.yourdomain.com` in Cloudflare and start it as **DNS Only (Grey Cloud)** for initial certificate provisioning.
- Allow inbound TCP `443` to the Ubuntu host. Allow TCP `80` only if you intentionally use the advanced direct `acme_http` fallback or want HTTP redirects.
- Limit SSH (`22`) to your administrator IP range where possible.
- After validation, switch the DNS record to **Proxied (Orange Cloud)** and set Cloudflare SSL/TLS to **Full (Strict)**.
- If your provider supports it, restrict web ingress to Cloudflare IP ranges after the first successful deployment.

> OCI note: OCI Security Lists drop packets before Ubuntu sees them. Add ingress rules under **Compute → Instances → Primary VNIC → Subnet → Default Security List**.

### 2. Clone the repository

```bash
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh
```

### 3. Run setup

```bash
sudo ./setup.sh install --domain vault.yourdomain.com --email admin@yourdomain.com --auto
```

`--auto` installs dependencies, generates `.env` and `docker-compose.yml`, provisions local generated secrets, configures the host firewall, and adds your user to the `docker` group while preserving pinned container versions from `.env.example`.

### 4. Re-login for Docker group membership

```bash
exit
# SSH back in, then:
cd VaultWarden-OCI
```

### 5. Configure required secrets and `.env`

Edit non-secret values first:

```bash
nano .env
```

Set or verify:

- `DOMAIN=https://vault.yourdomain.com`
- `ADMIN_EMAIL=admin@yourdomain.com`
- `EMAIL_MODE=smtp` and `EMAIL_PROVIDER=` for the Postfix-first default
- `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_FROM`, and `ALLOWED_SENDER_DOMAINS`
- `RCLONE_REMOTE_NAME`, `RCLONE_CONFIG`, and `RCLONE_REMOTE_PATH` if enabling offsite backup immediately
- `ADMIN_ALLOW_CIDR` so `/admin` is limited to your LAN, VPN, or admin egress range

Then rotate the external credentials that setup cannot generate:

```bash
sudo ./edit-secrets.sh rotate caddy_cloudflare_dns_token
sudo ./edit-secrets.sh rotate cf_worker_bouncer_token
sudo ./edit-secrets.sh rotate cloudflare_zone_id
sudo ./edit-secrets.sh rotate cf_account_id
sudo ./edit-secrets.sh rotate smtp_password
```

> `cloudflare_zone_id` is stored in SOPS secrets, not as `CLOUDFLARE_ZONE_ID` in `.env`.

### 6. Start and verify

```bash
./startup.sh
./maintenance.sh health
./maintenance.sh test-email --verbose
```

When health checks pass, switch the Cloudflare record to **Proxied (Orange Cloud)** and verify Cloudflare SSL/TLS is **Full (Strict)**.

### 7. Install automation

```bash
sudo ./setup.sh systemd install
```

This installs the appliance automation: health self-healing, database and full backups, maintenance, DNS refresh, firewall refresh, locking, and failure notifications. For the full schedule and customization points, see [docs/ADVANCED-CUSTOMIZATION.md](docs/ADVANCED-CUSTOMIZATION.md).

### 8. Export the recovery kit

```bash
./utilities/secrets-export-recovery-kit.sh
```

Store the recovery kit in your password manager and offline backup location. It is your break-glass bundle for rebuilding or decrypting secrets during recovery.

**🎉 Your vault is live at `https://vault.yourdomain.com`.**

### Advanced setup pointers

Keep first install on the golden path unless you have a specific reason to diverge:

- Direct `acme_http` TLS is an advanced fallback; Cloudflare DNS-01 is the supported production default.
- Dedicated data volumes are optional. See [docs/VOLUME-MIGRATION.md](docs/VOLUME-MIGRATION.md) before adopting or moving production data.
- Push notifications are optional and require additional outbound networking and Bitwarden push credentials. See [docs/CONFIGURATION.md](docs/CONFIGURATION.md).
- Provider-specific email APIs are optional alternatives; the default path is Postfix-first SMTP.

---

## 📧 Email Delivery

The default operator path is **Postfix-first SMTP**: Vaultwarden sends to the internal `postfix` sidecar, and Postfix relays to your external SMTP provider. This keeps mail reliable without requiring a host mail daemon.

Minimum `.env` settings:

```bash
EMAIL_MODE=smtp
EMAIL_PROVIDER=
SMTP_HOST=smtp.yourmailprovider.com
SMTP_PORT=587
SMTP_SECURITY=starttls
SMTP_USERNAME=your-smtp-username
SMTP_FROM=noreply@vault.yourdomain.com
ALLOWED_SENDER_DOMAINS=yourdomain.com
VW_SMTP_HOST=postfix
VW_SMTP_PORT=587
VW_SMTP_SECURITY=off
VW_SMTP_AUTH_MECHANISM=none
VW_SMTP_EXPLICIT_TLS=false
```

Store the relay password in SOPS secrets:

```bash
./utilities/secrets-rotate.sh smtp_password
```

Provider-specific HTTP APIs (`mailersend`, `sendgrid`, `mailgun`, `postmark`, `resend`) remain available as advanced alternatives via `EMAIL_MODE=auto` or `EMAIL_MODE=api`; see [docs/EMAIL.md](docs/EMAIL.md).

---

## 🏗️ Project Components

### Docker Stack

| Container | Role |
| :-- | :-- |
| **Caddy** | TLS termination, reverse proxy, security headers, 4-tier structured JSON logging (512 MB limit). Now requires **Caddy 2.11.4 by default**; uses `encode zstd gzip`, `roll_compression zstd`, connection timeouts in the global `servers` block, `request_body` size limits on admin/auth handlers, and health-check log suppression. |
| **VaultWarden** | Password manager application (512 MB limit) |
| **Postfix** | Containerised private SMTP relay for Vaultwarden and operational alerts; forwards to your external SMTP provider (256 MB limit) |
| **CrowdSec** | Host systemd service — threat detection with Cloudflare edge banning and host iptables |

> The `docker-compose.yml.example` template now enforces `read_only` filesystems, `tmpfs` mounts, `ulimits` (nofile), `no-new-privileges:true`, and tightened Caddy log rotation. See [docs/ADVANCED-CUSTOMIZATION.md](docs/ADVANCED-CUSTOMIZATION.md) for override details.

### Scripts

| Script | Purpose |
| :-- | :-- |
| `setup.sh` | One-time system setup: installs deps, generates `.env` and `docker-compose.yml` from templates, creates Age key, SOPS config, and empty secrets structure. Subcommands: `install --domain DOMAIN --email EMAIL` runs the full install; `secrets` bootstraps or rotates credentials; `systemd <install|remove|validate|status>` manages systemd timer integration. Pass `--data-device DEV` (and optionally `--data-mount PATH`) to provision a dedicated block storage data volume. In `--auto` mode, also auto-generates passwords/passphrases after all infra phases complete, then shows a single consolidated summary screen. |
| `startup.sh` | Start / stop / restart services. Post-startup health check re-runs verbose diagnostics automatically on failure. |
| `backup.sh` | Encrypted database and full-system backups. Uses host `sqlite3` with the Online Backup API for atomic, WAL-safe DB snapshots — no Docker container required for backup integrity checks. Accepts `--keep N` to override retention days (must be a positive integer). |
| `restore.sh` | Interactive or automated restore with a reworked flow: interactive Age decryption key prompt; `--key-file` flag and `RESTORE_AGE_KEY_FILE` env var for scripted/CI use; pre-restore key round-trip validation; post-restore automatic Age key generation and rotation. Uses host `sqlite3` for archive integrity verification — no Docker required. |
| `maintenance.sh` | System cleanup, DNS update, DB maintenance, email test, health monitoring (`health` subcommand), and container updates (`update` subcommand). |
| `utilities/secrets-edit.sh` | Secure secrets editor (Age + SOPS) — rotate individual fields, list keys, export recovery kit |
| `utilities/*.sh` | 24 standalone administrative and engine scripts. See [utilities/README.md](utilities/README.md) for full list. |

Full reference: [docs/SCRIPTS.md](docs/SCRIPTS.md)

### Shared Libraries (`lib/`)

| Library | Purpose |
| :-- | :-- |
| `common.sh` | Logging, validation, shared utilities, and multi-provider email delivery |
| `crypto.sh` | Age / SOPS encryption & decryption, security validation, and Age key resilience (health check, escrow, paper backup). bcrypt cost factor is validated to a minimum of 10 on all hash operations. |
| `docker.sh` | Docker lifecycle management |
| `backup-utils.sh` | Backup-specific shared logic including SQLite Online Backup API integrity verification |
| `secrets.sh` | Secrets collection, auto-generation, hashing (Argon2id + bcrypt), Cloudflare token validation, recovery kit generation |
| `storage.sh` | Storage-mode guard library. `require_project_state_ready()` validates configuration consistency, block device availability, mount presence, and sentinel identity before any script writes to the state directory. No-op in boot-only mode (`DATA_VOLUME_DEVICE` blank). Sourced by `setup.sh`, `startup.sh`, `backup.sh`, `restore.sh`, and `maintenance.sh`. |

### Configuration Templates

All live configuration is generated from `.example` templates by `setup.sh`. Edit templates → re-run setup → restart.

| Template | Generates |
| :-- | :-- |
| `docker-compose.yml.example` | `docker-compose.yml` |
| `docker-compose.override.yml.example` | `docker-compose.override.yml` (email decoupling; dev-only warning banner added) |
| `.env.example` | `.env` (sentinel tokens for all external credentials; `LOG_LEVEL=warn` default; `PUSH_ENABLED=false`; Mailgun EU region note; `STORAGE MODE` block with `DATA_VOLUME_DEVICE`, `DATA_VOLUME_MOUNT`, and `PROJECT_STATE_DIR`) |

---

## 🔒 Security at a Glance

- **Edge WAF & Host Protection** — Cloudflare proxy + CrowdSec host service pushes WAF bans to Cloudflare API and enforces iptables bans for SSH protection.
- **Host firewall** — UFW opens 80/443/22; Cloudflare IP restriction enforced at OCI Security List level
- **Encrypted secrets** — Age + SOPS; no plaintext credentials at rest. `cleanup_secrets_environment()` unsets all SOPS environment variables after every operation.
- **HTTPS** — Automatic Let's Encrypt via Caddy with HSTS, CSP, and security headers
- **Container hardening** — Non-root execution, capability restrictions, memory limits, `read_only` filesystems, `no-new-privileges:true`, and `tmpfs` mounts (see `docker-compose.yml.example`)
- **Docker-free backup integrity** — `backup.sh` and `restore.sh` use host `sqlite3` (SQLite Online Backup API) for atomic DB snapshots and `PRAGMA integrity_check`; no ephemeral alpine containers with read-write mounts over live vault data
- **Systemd hardening** — All service units run with `NoNewPrivileges=yes` and `PrivateTmp=yes`; `[Install]` sections added so `systemctl enable` works correctly; failure notifications are wired via `OnFailure=` on every unit
- **Fail-closed volume guard** — In separate-volume mode, a systemd drop-in (`RequiresMountsFor=`) blocks Docker from starting if the data volume is absent; all operational scripts also exit non-zero before touching the state directory, preventing silent writes to the boot volume
- **Structured forensic logging** — Caddy uses a 4-tier named-logger architecture (access, admin, auth, security) with independent rotation and retention targets (~3 GB total capacity); health-check requests are suppressed from logs

Full details: [docs/SECURITY.md](docs/SECURITY.md)

---

## 🔄 Update & Rollback

`maintenance.sh update --images|--system|--all` runs a fully phased cycle: pre-update health check → backup → pull → restart → post-update health check. If the post-update health check fails, it **automatically rolls back** via `restore.sh latest`. Age key health is now validated before any update operation begins. See [docs/OPERATIONS.md](docs/OPERATIONS.md) for the full phase diagram.

---

## 💾 Backup & Recovery

Three backup tiers with encrypted output (Age key required to restore):

| Tier | Schedule | Default retention |
| :-- | :-- | :-- |
| **Database snapshot** | Daily 4 AM | 14 days |
| **Full system archive** | Sunday 3 AM | 30 days |
| **On-demand emergency** | Manual | 90 days |

Retention is configurable: pass `--keep N` to `backup.sh` (N must be a positive integer), or set the `BACKUP_RETENTION_*_DAYS` values in `.env`. Example — keep 30 days of weekly full backups:
```bash
sudo ./backup.sh run full --keep 30
sudo ./backup.sh sync                  # copy all retained local backups to rclone
```

The restore flow now includes an interactive Age decryption key prompt, a pre-restore key round-trip validation, and automatic post-restore key rotation. Pass `--key-file <path>` or set `RESTORE_AGE_KEY_FILE` for non-interactive/CI restores. See [docs/BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md) for the full 12-step restore procedure.

> **⚠️ Keep a separate copy of `secrets/keys/age-key.txt`** — it is required to decrypt all backups on a new server. Run `./utilities/secrets-export-recovery-kit.sh` after setup to store it in your password manager alongside all other credentials.

Full procedures: [docs/BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md)

---

## 🚀 Makefile Quick Reference

```bash
make start / stop / restart / status   # Service lifecycle
make health                            # Health check
make backup / backup-full / restore    # Backup operations
make update / update-system            # Updates
make maintenance                       # Full maintenance run
make breakglass-create / status        # Emergency admin
make test-email / test-secrets         # Diagnostics
make logs [SERVICE=name]               # Container logs (follows single service, default: vaultwarden)
make diagnose                          # One-command debug dump: versions, key status, disk, containers, logs
make backup-status                     # Last backup times, directory size, retention window
make timers / systemd-status            # Automation status
make help                              # Normal admin/day-2 commands
make help-all                          # Full target list (advanced/dev/dashboard API)
```

> Several Makefile targets are used by the dashboard as a stable command API. Do not rename targets without checking dashboard integration. Developer/test commands such as linting and formatting are still available through `make help-all`.

> Several Makefile fixes landed in v1.0.0: `safe-restart` now rolls back on health-check failure; `key-rotate` invokes `bash` explicitly (fixes dash compatibility) and runs a `key-health` pre-flight; `restore-db` no longer passes `--force` so the Age key prompt runs as intended; `watch` uses `health-quick` to avoid hammering the HTTPS endpoint. See [CHANGELOG.md](CHANGELOG.md) for the full list.

---

## 📚 Documentation

| Doc | Contents |
| :-- | :-- |
| [DEPLOYMENT.md](docs/DEPLOYMENT.md) | Detailed deployment walkthrough |
| [CONFIGURATION.md](docs/CONFIGURATION.md) | Every `.env` and secrets variable |
| [EMAIL.md](docs/EMAIL.md) | Email setup: Postfix-first SMTP default and advanced API providers |
| [SECURITY.md](docs/SECURITY.md) | Security hardening deep-dive |
| [OPERATIONS.md](docs/OPERATIONS.md) | Day-to-day ops, update/rollback phases |
| [BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md) | Backup strategy and restore procedures |
| [DISASTER-RECOVERY.md](docs/DISASTER-RECOVERY.md) | Bare-metal disaster recovery procedure |
| [SCRIPTS.md](docs/SCRIPTS.md) | Full script reference |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Common issues and fixes |
| [MIGRATION.md](docs/MIGRATION.md) | Migrating from other setups |
| [ADVANCED-CUSTOMIZATION.md](docs/ADVANCED-CUSTOMIZATION.md) | Version pinning, overrides, tuning, systemd timers |
| [API.md](docs/API.md) | API usage and integrations |
| [BOOTSTRAP_KEY_RECOVERY.md](docs/BOOTSTRAP_KEY_RECOVERY.md) | Age key recovery procedures |

---

## 📄 License

MIT License — see LICENSE file for details.

## Resilient state and disaster recovery

VaultWarden-OCI now treats `${PROJECT_STATE_DIR}/config/install.env` as the authoritative persistent environment. The repository `.env` remains a compatibility/bootstrap copy, and `/etc/vaultwarden/vaultwarden.env` is an installed bootstrap fallback for systemd. Encrypted secrets live at `${PROJECT_STATE_DIR}/secrets/secrets.yaml`; decrypted Docker secret source files are recreated only under `/run/vaultwarden-oci/secrets/`.

SOPS policies use an operational Age recipient plus an optional offline recovery recipient. Keep the offline private key on USB only. The rendered recovery card is written to `${PROJECT_STATE_DIR}/config/recovery-card.md`; print it after setup and after changing the offline recovery key.
