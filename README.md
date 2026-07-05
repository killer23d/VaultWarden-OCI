# VaultWarden-OCI

**Production-ready VaultWarden for small teams on Ubuntu.**

VaultWarden-OCI is an opinionated, security-first deployment for teams of 10 or fewer users. It combines Vaultwarden, Caddy, Cloudflare DNS/proxy/WAF, CrowdSec, Postfix SMTP relay, SOPS/Age secrets, encrypted backups, rclone offsite sync, and systemd automation into a small-team appliance.

> New here? Start with [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md). For recovery planning, read [docs/BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md), [docs/DISASTER-RECOVERY.md](docs/DISASTER-RECOVERY.md), and [docs/RESTORE-RUNTIME-PERMISSIONS.md](docs/RESTORE-RUNTIME-PERMISSIONS.md).

---

## What Makes This Different

- **Set-and-forget operations** — health checks, backups, maintenance, DNS/firewall refresh, and failure notifications via systemd.
- **Root-operated lifecycle** — production commands use `sudo make up`, `sudo make restart`, `sudo make health`, and root-owned runtime state.
- **Shared operation guard** — mutating lifecycle, restore, backup, config, secrets, setup, and systemd install paths serialize through one recoverable guard.
- **Cloudflare-first edge** — Cloudflare DNS/proxy/WAF with Caddy DNS-01 certificates and CrowdSec-driven edge blocking.
- **Encrypted secrets** — SOPS + Age with root-operated persistent secrets and transient `/run` Docker secret files.
- **3-tier backup model** — database rollback, full DR, and clone-grade emergency capsules.
- **Storage-aware restore** — boot and attached block/data-volume layouts are preflighted before destructive restore.
- **Post-restore permission repair** — Caddy/Vaultwarden/root-operated runtime paths are normalized before services start.

---

## Quick Start — Golden Path

### 1. Prepare Cloudflare and provider ingress

- Create `vault.yourdomain.com` in Cloudflare.
- Start DNS as **DNS Only** until origin certificate issuance succeeds.
- Allow inbound TCP `443` to the Ubuntu host. Allow `80` only if you intentionally use HTTP/ACME fallback or redirects.
- Limit SSH to administrator IP ranges where possible.
- After validation, switch Cloudflare to **Proxied** and use SSL/TLS **Full (Strict)**.

### 2. Clone the repository

```bash
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh utilities/*.sh
```

### 3. Run setup

```bash
sudo ./setup.sh install --domain vault.yourdomain.com --email admin@yourdomain.com --auto
```

`--auto` installs dependencies, generates `.env` and `docker-compose.yml`, bootstraps Age/SOPS state, prepares the host firewall, and prints the next required operator actions.

### 4. Configure external credentials

Edit non-secret config:

```bash
sudo make edit-env
```

Then rotate credentials that setup cannot know:

```bash
sudo ./edit-secrets.sh rotate caddy_cloudflare_dns_token
sudo ./edit-secrets.sh rotate cf_worker_bouncer_token
sudo ./edit-secrets.sh rotate cloudflare_zone_id
sudo ./edit-secrets.sh rotate cf_account_id
sudo ./edit-secrets.sh rotate smtp_password
```

### 5. Start and verify

```bash
sudo make up
sudo make health
sudo ./maintenance.sh test-email --verbose
```

### 6. Install automation

```bash
sudo ./setup.sh systemd install
sudo make timers
```

### 7. Export recovery material

```bash
sudo ./utilities/secrets-export-recovery-kit.sh
```

A recovery kit is the plaintext operator handoff containing the Age private key and generated credentials needed for recovery. Store it in your password manager and offline backup location, then remove plaintext copies from the server. Re-export after setup, restore, or Age key rotation.

---

## Core Commands

```bash
sudo make up                 # start stack through startup.sh
sudo make restart            # restart stack through startup.sh
sudo make health             # health check
sudo make operations         # active/interrupted operation status
sudo make backup             # db backup
sudo make backup-full        # full DR backup
sudo make backup-emergency   # clone-grade emergency backup
sudo make restore            # interactive restore
sudo make key-health         # Age key health
sudo make key-rotate         # rotate operational Age/SOPS key
sudo make timers             # systemd timer status
make logs SERVICE=caddy      # container logs
```

---

## 2026 Backup Tier Model

VaultWarden-OCI has three deliberately different backup tiers:

| Tier | Use | Contents | Key handling |
| --- | --- | --- | --- |
| `db` | Quick database rollback | A single encrypted, integrity-checked SQLite snapshot (`.sqlite3.age`) | Encrypted to the operational Age recipient. |
| `full` | Normal fresh-VM disaster recovery | Project root, state directory, persistent config, encrypted SOPS `secrets.yaml`, sidecars/metadata, and a verified DB injected at `${PROJECT_STATE_DIR}/data/db.sqlite3` | Excludes `/etc/vaultwarden/age-key.txt`; restore requires the offline Age recipient's private key or the operational Age key that encrypted that backup. |
| `emergency` | Fastest clone-style recovery | Everything in `full`, plus staged persistent `/etc/vaultwarden` key/config material such as `age-key.txt`, `vaultwarden.env`, and `rclone.conf` when present | Protected independently with `age -p` passphrase mode or `EMERGENCY_BACKUP_AGE_RECIPIENT`; it is never encrypted only to the operational key it contains. |

All tiers contain a complete verified SQLite database snapshot. Full and emergency archives exclude live `db.sqlite3`, WAL/SHM files, backup directories, logs, temp files, sockets/locks, `.pre-restore-*` snapshots, decrypted runtime secrets, and `/run/vaultwarden-oci/secrets/*`. The verified staged DB is added back to the archive at the normal live path.

> **Warning:** Emergency backups are clone-grade secrets-bearing artifacts. Treat them like a password-manager vault export. Because they can contain the operational Age private key, they must be sealed with an independent passphrase prompt or a separate DR recipient (`EMERGENCY_BACKUP_AGE_RECIPIENT`).

Choose `db` for quick database rollback, `full` for a fresh VM restore when you have the offline Age recipient's private key or the operational Age key that encrypted the backup, and `emergency` when fastest clone-style recovery is worth carrying key material inside the sealed capsule. The offline Age recipient is an optional extra Age public recipient for SOPS recovery; it is not the emergency passphrase for a passphrase-sealed emergency backup.

---

## Restore and Runtime Permissions

Before full or emergency restore, inspect storage compatibility:

```bash
sudo ./restore.sh inspect --remote
```

Interactive full/emergency restores default to an operator start prompt. Use the manual inspection window when you want to verify storage, `/etc/vaultwarden`, Cloudflare/DNS, firewall, and config before starting services. If the confirmation channel is lost during emergency Age-key rotation or the new-key `SAVED` acknowledgement, restore fails safe, leaves services stopped, and prints the manual startup checklist.

```bash
sudo ./restore.sh interactive --remote --start-policy ask
sudo utilities/repair-permissions.sh
sudo ./startup.sh --skip-pull
sudo ./maintenance.sh health
```

Full and emergency restores repair the target-host runtime permission contract before service start. This includes Caddy's UID/GID `2000:2000` paths under `${PROJECT_STATE_DIR}/caddy` and `${PROJECT_STATE_DIR}/logs/caddy`, Vaultwarden app data ownership, root-operated config/secrets, and transient `/run` secret files.

See [docs/RESTORE-RUNTIME-PERMISSIONS.md](docs/RESTORE-RUNTIME-PERMISSIONS.md).

---

## Project Components

| Component | Role |
| :-- | :-- |
| Vaultwarden | Password manager application |
| Caddy | TLS termination, reverse proxy, DNS-01 certificate management, structured logs |
| Postfix | Containerized SMTP relay for Vaultwarden and operational alerts |
| CrowdSec | Host threat detection with Cloudflare edge blocking and SSH protection |
| SOPS/Age | Encrypted persistent secrets and backup encryption |
| rclone | Optional offsite backup sync |
| systemd timers | Backup, maintenance, health, DNS/firewall refresh, and failure notification automation |

---

## Documentation

| Doc | Contents |
| :-- | :-- |
| [DEPLOYMENT.md](docs/DEPLOYMENT.md) | Detailed deployment walkthrough |
| [CONFIGURATION.md](docs/CONFIGURATION.md) | `.env` and SOPS secrets reference |
| [EMAIL.md](docs/EMAIL.md) | Postfix-first SMTP and advanced API providers |
| [SECURITY.md](docs/SECURITY.md) | Security hardening deep-dive |
| [OPERATIONS.md](docs/OPERATIONS.md) | Day-to-day operations and maintenance |
| [BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md) | Backup strategy and restore procedures |
| [DISASTER-RECOVERY.md](docs/DISASTER-RECOVERY.md) | Bare-metal DR runbook |
| [RESTORE-RUNTIME-PERMISSIONS.md](docs/RESTORE-RUNTIME-PERMISSIONS.md) | Post-restore permission contract |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Common issues and fixes |
| [SCRIPTS.md](docs/SCRIPTS.md) | Script reference |
| [MIGRATION.md](docs/MIGRATION.md) | Migration guidance |
| [VOLUME-MIGRATION.md](docs/VOLUME-MIGRATION.md) | Boot/block storage migration |
| [BOOTSTRAP_KEY_RECOVERY.md](docs/BOOTSTRAP_KEY_RECOVERY.md) | Age key recovery procedures |

---

## License

MIT License — see [LICENSE](LICENSE).
