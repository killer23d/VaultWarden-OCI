# VaultWarden-OCI

**Production-ready VaultWarden for small teams on Ubuntu 24.04 LTS Noble.**

VaultWarden-OCI is an opinionated, security-first deployment for teams of roughly 10 or fewer users. It combines Vaultwarden, Caddy, Cloudflare DNS/proxy/WAF, CrowdSec, a Postfix SMTP relay, SOPS/Age secrets, encrypted backups, rclone offsite sync, and systemd automation into a small-team appliance.

> New here? Start with [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md). Before production, also read [docs/BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md), [docs/DISASTER-RECOVERY.md](docs/DISASTER-RECOVERY.md), and [docs/SECURITY.md](docs/SECURITY.md).

---

## What Makes This Different

- **Set-and-forget operations** — health checks, backups, maintenance, DNS/firewall refresh, and failure notifications via systemd.
- **Root-operated production lifecycle** — normal administration uses `sudo make up`, `sudo make restart`, `sudo make health`, and root-owned runtime state.
- **Shared operation guard** — conflicting mutating workflows serialize through the repository's `flock`-based operation guard.
- **Cloudflare-first edge** — Cloudflare DNS/proxy/WAF with Caddy DNS-01 certificates and CrowdSec-driven Cloudflare Workers enforcement.
- **Encrypted secrets** — SOPS + Age with persistent encrypted state and transient `/run/vaultwarden-oci/secrets` runtime files.
- **Three backup tiers** — database rollback, full disaster recovery, and independently sealed emergency capsules.
- **Storage-aware restore** — boot and attached block/data-volume layouts are preflighted before destructive restore.
- **Installed-runtime validation** — systemd automation runs root-owned copies under `/opt/vaultwarden-scripts`; validation detects repository/installed split-brain.

---

## Supported Production Boundary

The normal production path is:

- Ubuntu 24.04 LTS Noble;
- amd64 or arm64;
- Docker Engine with the Docker Compose plugin;
- systemd;
- Cloudflare DNS, proxy, and WAF;
- Caddy with the Cloudflare-first TLS path;
- Vaultwarden;
- Postfix sidecar mail relay;
- CrowdSec with Cloudflare edge enforcement;
- SOPS + Age;
- rclone for offsite backup support.

The host runtime is cloud-provider neutral. OCI, AWS, Azure, Google Cloud, another VM provider, private virtualization, or a physical host can be used when the host satisfies the supported Ubuntu, CPU, networking, storage, and Cloudflare requirements.

See [docs/PROJECT-BOUNDARY.md](docs/PROJECT-BOUNDARY.md).

---

## Quick Start — Golden Path

### 1. Prepare Cloudflare and provider ingress

- Create `vault.yourdomain.com` in Cloudflare.
- Start DNS as **DNS Only** until origin certificate issuance succeeds.
- Allow inbound TCP `443` through your provider firewall, security group, or network firewall. Allow `80` only when your chosen path requires it.
- Limit SSH to administrator IP ranges where possible.
- After origin validation, switch Cloudflare to **Proxied** and use SSL/TLS **Full (Strict)**.

### 2. Clone the repository

```bash
git clone --branch main https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh utilities/*.sh
```

### 3. Run setup

```bash
sudo ./setup.sh install \
  --domain vault.yourdomain.com \
  --email admin@yourdomain.com \
  --auto
```

`setup.sh` validates the supported Noble/amd64-or-arm64 host contract, installs the repository-owned dependency set, generates the deployment files, bootstraps SOPS/Age state, prepares storage, configures the host firewall, and prints remaining operator actions.

### 4. Configure external credentials

Edit non-secret configuration through the environment workflow:

```bash
sudo make edit-env
```

Then set credentials setup cannot know:

```bash
sudo ./edit-secrets.sh rotate caddy_cloudflare_dns_token
sudo ./edit-secrets.sh rotate cf_worker_bouncer_token
sudo ./edit-secrets.sh rotate cloudflare_zone_id
sudo ./edit-secrets.sh rotate cf_account_id
sudo ./edit-secrets.sh rotate smtp_password
```

### 5. Start and verify the live stack

```bash
sudo make up
sudo make health
sudo ./maintenance.sh test-email --verbose
```

### 6. Activate and validate automation

On a host that is ready to run scheduled jobs:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

A zero `systemd validate` result means the expected installed scripts, libraries, managed units, environment/key permissions, and timer readiness match the current repository contract. A zero smoke-test result requires every smoke check to complete without `FAIL` or `SKIP`.

After updating from `main` with `git pull --ff-only origin main`, repeat the three commands above when managed scripts, libraries, or units changed. Git updates the checkout; the systemd installer activates the current repository code under `/opt/vaultwarden-scripts`.

### 7. Export recovery material

```bash
sudo ./utilities/secrets-export-recovery-kit.sh
```

The recovery kit is a plaintext operator handoff containing the Age private key and generated credentials needed for recovery. Store it in your password manager and a separate offline recovery location, then remove plaintext copies from the server. Re-export after setup, restore, or Age key rotation.

---

## Core Commands

```bash
sudo make up                 # start the stack through startup.sh
sudo make down               # stop the stack
sudo make restart            # restart the stack
sudo make health             # health check
sudo make operations         # active/interrupted operation status
sudo make backup             # database backup
sudo make backup-full        # full DR backup
sudo make backup-emergency   # clone-grade emergency backup
sudo make restore            # interactive restore
sudo make key-health         # Age key health
sudo make key-rotate         # rotate the operational Age/SOPS key
sudo make timers             # systemd timer status
sudo make logs SERVICE=caddy # container logs
```

For exact public script grammar and options, use `--help` or [docs/COMMAND-REFERENCE.md](docs/COMMAND-REFERENCE.md).

---

## Backup Tier Model

VaultWarden-OCI has three deliberately different backup tiers:

| Tier | Use | Contents | Key handling |
| --- | --- | --- | --- |
| `db` | Quick database rollback | A single encrypted, integrity-checked SQLite snapshot (`.sqlite3.age`) | Encrypted to the operational Age recipient. |
| `full` | Normal fresh-host disaster recovery | Project/state content required for DR, persistent config, encrypted SOPS `secrets.yaml`, metadata/sidecars, and a verified staged database | Excludes the live operational Age private key. Restore requires a private key for a recipient that encrypted the selected backup. |
| `emergency` | Fastest clone-style recovery | Full DR content plus staged `/etc/vaultwarden` key/config material when present | Independently sealed with passphrase mode or `EMERGENCY_BACKUP_AGE_RECIPIENT`; never protected only by the operational key it can contain. |

All tiers contain a complete verified SQLite database snapshot. Full and emergency archive construction excludes the live SQLite/WAL/SHM set, backup trees, transient runtime secrets, sockets/locks, and restore scratch state; the verified staged database is injected at the normal live database path.

> **Warning:** Emergency backups are clone-grade secrets-bearing artifacts. Treat them like a password-manager vault export and protect the emergency passphrase or separate emergency recipient identity independently.

Choose `db` for database rollback, `full` for normal disaster recovery, and `emergency` when fastest clone-style recovery is worth carrying key material inside the independently protected capsule.

---

## Restore and Runtime Permissions

Before full or emergency restore, inspect storage compatibility:

```bash
sudo ./restore.sh inspect --remote
```

Interactive restores use an operator-controlled start policy. Keep services stopped when you need to inspect storage, `/etc/vaultwarden`, Cloudflare/DNS, firewall, rclone, or configuration before startup.

```bash
sudo ./restore.sh interactive --remote --start-policy ask
sudo utilities/repair-permissions.sh
sudo ./startup.sh --skip-pull
sudo ./maintenance.sh health
```

Full and emergency restores apply the target-host runtime permission contract before service start. This includes Caddy UID/GID `2000:2000` runtime mounts, Vaultwarden application data ownership, root-operated config/secrets, and transient runtime secret files.

After a replacement-host restore is genuinely ready for automation:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

See [docs/RESTORE-RUNTIME-PERMISSIONS.md](docs/RESTORE-RUNTIME-PERMISSIONS.md).

---

## Project Components

| Component | Role |
| :-- | :-- |
| Vaultwarden | Password manager application |
| Caddy | TLS termination, reverse proxy, DNS-01 certificate management, structured logs |
| Postfix | Containerized SMTP relay for Vaultwarden and operational alerts |
| CrowdSec | Host threat detection with Cloudflare Workers enforcement and host firewall protection |
| SOPS/Age | Encrypted persistent secrets and backup encryption |
| rclone | Offsite backup sync support |
| systemd | Startup integration, six scheduled production jobs, and failure notifications |

---

## Documentation

| Doc | Contents |
| :-- | :-- |
| [DEPLOYMENT.md](docs/DEPLOYMENT.md) | Supported production deployment walkthrough |
| [PROJECT-BOUNDARY.md](docs/PROJECT-BOUNDARY.md) | Supported production and non-goal boundary |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | State, environment, secrets, runtime, and recovery architecture |
| [CONFIGURATION.md](docs/CONFIGURATION.md) | Environment and SOPS configuration |
| [SECRETS-SCHEMA.md](docs/SECRETS-SCHEMA.md) | Canonical secret schema contract |
| [EMAIL.md](docs/EMAIL.md) | Postfix-first SMTP and advanced API providers |
| [CROWDSEC.md](docs/CROWDSEC.md) | CrowdSec and Cloudflare Workers enforcement |
| [SECURITY.md](docs/SECURITY.md) | Security model and hardening |
| [OPERATIONS.md](docs/OPERATIONS.md) | Day-to-day operations and maintenance |
| [BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md) | Backup strategy and restore procedures |
| [DISASTER-RECOVERY.md](docs/DISASTER-RECOVERY.md) | Replacement-host DR runbook |
| [RECOVERY-CARD.md](docs/RECOVERY-CARD.md) | Printable recovery procedure template |
| [BOOTSTRAP_KEY_RECOVERY.md](docs/BOOTSTRAP_KEY_RECOVERY.md) | Offline Age key and recovery material guidance |
| [RESTORE-RUNTIME-PERMISSIONS.md](docs/RESTORE-RUNTIME-PERMISSIONS.md) | Post-restore permission contract |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Common issues and fixes |
| [MIGRATION.md](docs/MIGRATION.md) | Data migration into VaultWarden-OCI |
| [VOLUME-MIGRATION.md](docs/VOLUME-MIGRATION.md) | Boot/block storage migration |
| [SCRIPTS.md](docs/SCRIPTS.md) | Public script and implementation ownership map |
| [COMMAND-REFERENCE.md](docs/COMMAND-REFERENCE.md) | Generated exact command grammar |
| [API.md](docs/API.md) | HTTP/API integration boundary |
| [ADVANCED-CUSTOMIZATION.md](docs/ADVANCED-CUSTOMIZATION.md) | Advanced configuration outside the golden path |

---

## License

MIT License — see [LICENSE](LICENSE).

## Secure credential handoffs

<!-- VWOCI-PRR-PATCH-04 -->

Automatic setup writes generated credentials to a protected root-only handoff instead of printing them. The separate full recovery kit is exported under `/root/vaultwarden-recovery/` and can be emailed only as an AES-256 encrypted ZIP. See [Secure credential and recovery handoffs](docs/SECURE-CREDENTIAL-HANDOFFS.md).
