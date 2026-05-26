# VaultWarden-OCI

**Production-Ready VaultWarden for Small Teams**

A streamlined, secure, and operationally excellent VaultWarden deployment optimised for teams of 10 or fewer users. Designed for Oracle Cloud Infrastructure (OCI) with dynamic IPs, it emphasises template-based configuration, automated operations, and robust multi-layer security.

## 🎯 What Makes This Different

This is a **template-based, hardened deployment** built for small teams who want:

- **Set-and-forget reliability** — automated backups, updates, health checks, and rollback
- **Template-first approach** — all config files maintained as `.example` templates; nothing hardcoded
- **Cloudflare-only web blocking** — iptables removed from proxied services; edge WAF used instead
- **Encrypted secrets** — Age + SOPS for industry-standard secrets management
- **Emergency recovery** — break-glass admin access and automatic rollback on failed updates
- **Simple day-to-day operations** — Makefile shortcuts covering the full lifecycle

---

## ⚡ Quick Start (~15 Minutes)

### Step 0 — Configure OCI Security List (Do This First)

> **⚠️ CRITICAL:** OCI blocks all inbound traffic by default at the hypervisor level. You must open ports 80 and 443 in your VCN Security List **before** cloning — Caddy cannot provision its TLS certificate otherwise.

1. In the OCI Console go to **Compute → Instances → your instance**.
2. Under "Primary VNIC" click your **Subnet → Default Security List**.
3. Add **Ingress Rules** for TCP ports `80` and `443`.

**Option A — Open to all (simplest):**
Set Source CIDR to `0.0.0.0/0`.

**Option B — Restrict to Cloudflare IPs only (recommended):**
Add one rule per CIDR below (OCI does not support comma-separated CIDRs).
Verify the current list at <https://www.cloudflare.com/ips-v4>.

```
173.245.48.0/20   103.21.244.0/22   103.22.200.0/22   103.31.4.0/22
141.101.64.0/18   108.162.192.0/18  190.93.240.0/20   188.114.96.0/20
197.234.240.0/22  198.41.128.0/17   162.158.0.0/15    104.16.0.0/13
104.24.0.0/14     172.64.0.0/13     131.0.72.0/22
```

4. Also add an SSH rule: Source `0.0.0.0/0` (or your IP), Protocol TCP, Port `22`.

> **Why not UFW?** OCI Security Lists drop packets at the hypervisor — before the VM's network stack — making them a harder control than host-level UFW.

---

### Step 1 — Cloudflare DNS Staging (Grey Cloud First)

In your Cloudflare dashboard set your DNS record to **DNS Only (Grey Cloud)** before running setup. Caddy must reach Let's Encrypt directly to provision its TLS certificate on first boot. You can enable the orange proxy cloud after the stack is running.

---

### Step 2 — Clone & Run Setup

```bash
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI

# Make top-level scripts executable — do NOT use -R here.
# lib/*.sh are sourced libraries, not standalone executables.
# utilities/*.sh are set +x automatically by setup.sh.
chmod +x *.sh

# Automated setup — installs deps, generates config files, auto-generates
# VaultWarden admin password, Caddy admin password, and backup passphrase.
# External credentials (CF tokens, SMTP, push keys) are left as
# CHANGE_ME placeholders — the post-install summary lists the exact
# ./utilities/secrets-rotate.sh commands to fill them in.
# Full install — explicit subcommand form (recommended)
sudo ./setup.sh install --domain vault.yourdomain.com --email admin@yourdomain.com --auto

# All setup.sh entry points:
sudo ./setup.sh install --domain DOMAIN --email EMAIL [--auto] [--use-latest] [--skip-deps] [--force] [--dry-run]
sudo ./setup.sh secrets           # Configure/rotate secrets interactively
sudo ./setup.sh systemd install   # Install and enable all systemd timers
sudo ./setup.sh systemd status    # Show timer status
sudo ./setup.sh systemd validate  # Detect stale install paths
sudo ./setup.sh systemd remove    # Disable and remove all timers
./setup.sh help                   # Full usage reference

# Re-login so your user picks up the docker group
exit
# SSH back in, then:
cd VaultWarden-OCI
```

> **`--auto` vs `--use-latest`:** `setup.sh install --auto` is fully non-interactive and does not change container version pins. Pass `--use-latest` separately if you want all container image tags set to `latest` instead of the pinned versions in `.env`.

> **Separate data volume:** If you have a dedicated OCI block storage volume, pass `--data-device /dev/sdb` to provision it automatically. See [Separate Data Volume (Optional)](#separate-data-volume-optional) below.

---

### Step 3 — Configure Environment & External Credentials

**Edit `.env` first** — `CLOUDFLARE_ZONE_ID` must be set before secrets are configured so that Cloudflare token validation works correctly.

```bash
nano .env
# ► Set: CLOUDFLARE_ZONE_ID, SMTP_HOST, SMTP_PORT, SMTP_USERNAME
# ► Set: EMAIL_MODE=auto, EMAIL_PROVIDER=mailersend (or your provider)
# ► Set: ALLOWED_SENDER_DOMAINS=vault.yourdomain.com  (for Postfix sidecar)
# ► Verify: DOMAIN and ADMIN_EMAIL are correct
```

Then supply the external credentials that `--auto` cannot generate for you:

```bash
# Cloudflare tokens (required — Caddy TLS + CrowdSec edge blocking)
./utilities/secrets-rotate.sh caddy_cloudflare_dns_token
./utilities/secrets-rotate.sh crowdsec_cf_firewall_token  # used by CrowdSec cloudflare-bouncer

## Email API token (required for Tier 1)
./utilities/secrets-rotate.sh email_api_token
# Single canonical key used for all providers (selected by EMAIL_PROVIDER)

# SMTP password (required for Tier 2 relay and Postfix sidecar)
./utilities/secrets-rotate.sh smtp_password

# Push notification keys (optional — mobile app push alerts)
./utilities/secrets-rotate.sh push_installation_id
./utilities/secrets-rotate.sh push_installation_key
```

**Interactive install (no `--auto`):** `setup.sh` creates the skeleton and displays a next-steps screen. Follow the steps printed on screen — edit `.env` first, then run `./setup.sh secrets` to be prompted for all credentials at once.

See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for every available variable and [docs/EMAIL.md](docs/EMAIL.md) for a full email setup walkthrough.

---

### Step 4 — Start & Verify

```bash
./startup.sh          # start all services  (or: make start)
./maintenance.sh health  # verify everything is healthy  (or: make health)
```

Once healthy, switch the Cloudflare record to **Proxied (Orange Cloud)** and set SSL/TLS encryption to **Full (Strict)**.

> **`startup.sh` diagnostic improvement:** If the post-startup quiet health check exits non-zero, `startup.sh` now automatically re-runs `./maintenance.sh health` in verbose mode so full diagnostics are always visible to the operator.

---

### Step 5 — Finish Up (Recommended)

```bash
# Set up automated backups, updates, health checks, and maintenance via systemd timers
sudo ./setup.sh systemd install

# Export a plaintext recovery kit to your password manager
# Run this AFTER all secrets are configured so everything is included
./utilities/secrets-export-recovery-kit.sh

# Create emergency admin for OCI serial console recovery
sudo utilities/setup-secrets.sh breakglass create    # or: make breakglass-create
```

> **`setup.sh systemd` improvement:** `setup.sh systemd install` now validates all `OnCalendar=` expressions via `systemd-analyze calendar` before enabling timers and warns on invalid expressions. All generated service units now include an `[Install]` section (`WantedBy=multi-user.target`) so `systemctl enable` is no longer a no-op. See [docs/ADVANCED-CUSTOMIZATION.md](docs/ADVANCED-CUSTOMIZATION.md) for timer details.

The installed systemd timer schedule:

| Timer | Schedule | Protection |
| :-- | :-- | :-- |
| `vaultwarden-maintenance.timer` | 2:05 AM daily | `flock` — skips + logs if already running |
| `vaultwarden-full-backup.timer` | 3 AM Sunday | Internal lock in `backup.sh`; email on failure via `OnFailure=` |
| `vaultwarden-db-backup.timer` | 4 AM daily | Internal lock in `backup.sh`; email on failure via `OnFailure=` |
| `vaultwarden-health.timer` | Every 5 min | `maintenance.sh health --fix`; self-heals, failures notify via `OnFailure=` |
| `vaultwarden-dns-update.timer` | Every hour | `flock` — skips + logs if already running |
| `vaultwarden-firewall-update.timer` | Saturday 4 AM | `flock` — skips + logs if already running |

> **Note on timer persistence:** The health, DNS, firewall-update, and DB-backup timers are installed with `Persistent=true` — if the system reboots while one was due to fire, systemd will run the missed job once on next boot. The full-backup and maintenance timers use `Persistent=false` to avoid a catch-up I/O storm after extended downtime. This replaces the flock lock-directory recreation step that cron required.

> **Runtime user model:** Backup, health, and DNS automation run as the service user (`ubuntu` by default). Root execution is reserved for explicitly privileged jobs (for example firewall rule updates).

> **Viewing timer status:** `systemctl list-timers --all | grep vaultwarden` shows next fire time and last run for every timer.

> **Failure notifications:** Every service unit has `OnFailure=vaultwarden-notify-failure.service`. If any backup, health, or maintenance job fails, an email alert is sent automatically without requiring a separate monitoring tool.

**🎉 Your vault is live at `https://vault.yourdomain.com`**

For day-2 operations and incident handling, keep [RUNBOOK.md](RUNBOOK.md) open in a second terminal session.

---

### Separate Data Volume (Optional)

OCI block storage volumes keep vault data independent of the boot volume, making snapshots, resizes, and instance replacements straightforward. Pass `--data-device` to `setup.sh` to enable this mode.

**Prerequisites:** Attach a block storage volume to your OCI instance **before** running setup. Confirm the device name with `lsblk` — it typically appears as `/dev/sdb` (or `/dev/nvme1n1` on some shapes).

```bash
# Provision a dedicated data volume in one step
# WARNING: the device is formatted as ext4 if it has no existing filesystem
sudo ./setup.sh install --domain vault.yourdomain.com --email admin@yourdomain.com --auto \
  --data-device /dev/sdb \
  --data-mount /mnt/vw-data   # optional; /mnt/vw-data is the default
```

`setup.sh` handles the full provisioning cycle:

- Formats the device as ext4 (skipped idempotently if a filesystem already exists)
- Adds a UUID-based entry to `/etc/fstab` with `nofail` (no duplicate entries on re-run)
- Mounts the volume and writes a sentinel file (`.vw-data-volume`) to confirm identity
- Writes `DATA_VOLUME_DEVICE`, `DATA_VOLUME_MOUNT`, and `PROJECT_STATE_DIR=/mnt/vw-data` into `.env` so all persistent state lands on the data volume
- Installs a systemd drop-in (`/etc/systemd/system/docker.service.d/10-vaultwarden-data-volume.conf`) with `RequiresMountsFor=` to prevent Docker from starting until the volume is mounted — eliminating silent data writes to the boot volume on reboot

**Reverting to boot-only mode:** Re-run setup without `--data-device`. The drop-in is removed automatically and `PROJECT_STATE_DIR` reverts to `/var/lib/vaultwarden`.

> **⚠️ Fail-closed guarantee:** In separate-volume mode, `startup.sh`, `backup.sh`, `restore.sh`, and `maintenance.sh` all exit immediately with a clear diagnostic error if the expected data volume is not mounted. Data is never silently written to the boot volume.

> **Restore safety note:** `restore.sh` now re-validates the mounted data-volume identity marker (`.vw-data-volume`) after restore promotion, so separate-volume guards continue to work even when restoring older archives.

**`.env` variables (set automatically by setup, verify if editing manually):**

```bash
# Boot-only mode (default)
DATA_VOLUME_DEVICE=
DATA_VOLUME_MOUNT=/mnt/vw-data
PROJECT_STATE_DIR=/var/lib/vaultwarden

# Separate-volume mode
DATA_VOLUME_DEVICE=/dev/sdb
DATA_VOLUME_MOUNT=/mnt/vw-data
PROJECT_STATE_DIR=/mnt/vw-data   # MUST equal DATA_VOLUME_MOUNT
```

---

## 📧 Email Delivery

Email is handled by **`lib/common.sh`** (email functions) — a pure bash + curl multi-provider chain. No mail daemon is required on the host. Three tiers are attempted in order when `EMAIL_MODE=auto`:

```
Tier 1 ─ HTTP API       →  MailerSend, SendGrid, Mailgun, Postmark, Resend
           │ fail
           ▼
Tier 2 ─ SMTP           →  direct relay or the Postfix sidecar on 127.0.0.1:587
           │ fail
           ▼
Tier 3 ─ Host MTA       →  local mail/sendmail binary
```

The VaultWarden container also talks to the internal `postfix`
service via `VW_SMTP_*`; only the `SMTP_*` block changes when you switch
upstream relays.

**Minimum setup for operational alerts (all three tiers):**

```bash
# .env
EMAIL_MODE=auto
EMAIL_PROVIDER=mailersend           # or your chosen provider
SMTP_HOST=smtp.mailersend.net
SMTP_PORT=587
SMTP_SECURITY=starttls
SMTP_USERNAME=your-smtp-username
SMTP_FROM=noreply@vault.yourdomain.com
ALLOWED_SENDER_DOMAINS=vault.yourdomain.com

# VaultWarden -> Postfix sidecar (internal Docker network; no auth/TLS here):
VW_SMTP_HOST=postfix
VW_SMTP_PORT=587
VW_SMTP_SECURITY=off
VW_SMTP_AUTH_MECHANISM=none
VW_SMTP_EXPLICIT_TLS=false
```

```bash
# Secrets
./utilities/secrets-rotate.sh email_api_token
./utilities/secrets-rotate.sh smtp_password
```

```bash
# Test end-to-end
./maintenance.sh test-email --verbose
```

Full details, provider setup, Postfix MTA configuration, and troubleshooting: **[docs/EMAIL.md](docs/EMAIL.md)**

---

## 🏗️ Project Components

### Docker Stack

| Container | Role |
| :-- | :-- |
| **Caddy** | TLS termination, reverse proxy, security headers, 4-tier structured JSON logging (512 MB limit). Now requires **Caddy ≥ 2.11.2**; uses `encode zstd gzip`, `roll_compression zstd`, connection timeouts in the global `servers` block, `request_body` size limits on admin/auth handlers, and health-check log suppression. |
| **VaultWarden** | Password manager application (512 MB limit) |
| **Postfix** | Containerised SMTP relay — last-resort MTA for the email chain in `lib/common.sh`; binds `127.0.0.1:587` (256 MB limit) |
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

`maintenance.sh update` runs a fully phased cycle: pre-update health check → backup → pull → restart → post-update health check. If the post-update health check fails, it **automatically rolls back** via `restore.sh latest`. Age key health is now validated before any update operation begins. See [docs/OPERATIONS.md](docs/OPERATIONS.md) for the full phase diagram.

---

## 💾 Backup & Recovery

Three backup tiers with encrypted output (Age key required to restore):

| Tier | Schedule | Default retention |
| :-- | :-- | :-- |
| **Database snapshot** | Daily 4 AM | 14 days |
| **Full system archive** | Sunday 3 AM | 30 days |
| **On-demand emergency** | Manual | 90 days |

Retention is configurable: pass `--keep N` to `backup.sh` (N must be a positive integer), or edit `KEEP_DAYS` in `.env`. Example — keep 30 days of weekly full backups:
```bash
sudo ./backup.sh run full --keep 30
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
make logs [SERVICE=name]               # Container logs (defaults to --tail=100)
make diagnose                          # One-command debug dump: versions, key status, disk, containers, logs
make backup-status                     # Last backup times, directory size, retention window
make lint                              # shellcheck all *.sh scripts
make version                           # Stack version from VERSION file
```

> Several Makefile fixes landed in v1.0.0: `safe-restart` now rolls back on health-check failure; `key-rotate` invokes `bash` explicitly (fixes dash compatibility) and runs a `key-health` pre-flight; `restore-db` no longer passes `--force` so the Age key prompt runs as intended; `watch` uses `health-quick` to avoid hammering the HTTPS endpoint. See [CHANGELOG.md](CHANGELOG.md) for the full list.

---

## 📚 Documentation

| Doc | Contents |
| :-- | :-- |
| [DEPLOYMENT.md](docs/DEPLOYMENT.md) | Detailed deployment walkthrough |
| [CONFIGURATION.md](docs/CONFIGURATION.md) | Every `.env` and secrets variable |
| [EMAIL.md](docs/EMAIL.md) | Email setup: API providers, SMTP relay, Postfix MTA |
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
