# VaultWarden-OCI

VaultWarden-OCI installs [Vaultwarden](https://github.com/dani-garcia/vaultwarden), a self-hosted password manager for a small team, with HTTPS, Cloudflare protection, encrypted recovery, and an administrator dashboard.

**Supported servers:** Ubuntu 24.04 LTS or 26.04 LTS, `amd64` or `arm64`. Ubuntu 24.04 has disposable real-host acceptance; Ubuntu 26.04 has code/CI compatibility checks, not a recorded real-host acceptance run. **Production data requires a separate ext4/xfs disk/filesystem**; the boot disk is not a supported fallback.

## New here? Follow this path

1. Prepare a fresh Ubuntu server, attach a **separate data disk**, and make sure you know which disk is the boot disk.
2. In Cloudflare, prepare **one Proxied (orange-cloud) A record** for your vault hostname (and no explicit AAAA record). Create **two separate API tokens** for DNS/certificates and CrowdSec. See [Cloudflare tokens](docs/CLOUDFLARE-TOKENS.md).
3. Have an authenticated SMTP account ready for invitations and other Vaultwarden emails.
4. Download the **source described by this guide**:

   ```bash
   sudo apt-get update
   sudo apt-get install -y git
   git clone --branch v2 --single-branch https://github.com/killer23d/VaultWarden-OCI.git
   cd VaultWarden-OCI
   ```

   The branch is explicit because the repository's default branch currently contains a different implementation.

5. Run setup, replacing the example names and email:

   ```bash
   sudo ./setup.sh install \
     --domain example.com \
     --url https://vault.example.com \
     --email admin@example.com
   ```

6. Follow setup's prompts to choose/confirm the disk, fill in SMTP and encrypted Cloudflare credentials, and hand off the verified **recovery-kit ZIP**. Keep that ZIP **off the server** and its passphrase separately.
7. Continue with [the first-start checklist](docs/INSTALL.md#6-validate-and-activate-security) **before opening the vault**. In order: validate settings and DNS, prepare CrowdSec, set the Cloudflare Worker Routes to **Fail Open**, start, update DNS, make the first backup, run doctor, then enable automation. Do not enable timers before backup and post-start checks pass.

**What changed?** The appliance can now keep the **existing Cloudflare-proxied IPv4 A record** in sync when your server's public IP changes. After timers are enabled, its DNS service runs alongside the five-minute health schedule. It never creates DNS records, disables the orange cloud, or updates IPv6.

**Email is not the same as automatic alerts.** Required SMTP settings enable Vaultwarden email and a direct SMTP test. Automatic emails about failed systemd services need an **optional built-in HTTPS notification provider**, its API token and a recipient; SMTP fallback is only for eligible temporary API failures. See [Configuration](docs/CONFIGURATION.md#optional-automatic-failure-alerts).

## Daily tasks

| Task | Command |
| --- | --- |
| Open the dashboard | `sudo /opt/vaultwarden-oci/current/vaultwarden_oci/dashboard.sh` |
| Overall status | `sudo vwctl status` |
| Find failed checks | `sudo vwctl doctor --json` |
| Check Cloudflare DNS | `sudo vwctl dns status` |
| Preview DNS change (no write) | `sudo vwctl dns update --dry-run` |
| Test authenticated SMTP | `sudo vwctl notification test --smtp` |
| Check scheduled jobs | `sudo vwctl timers` |
| Create an encrypted recovery point | `sudo vwctl backup` |

## Backup and disaster-recovery essentials

**The built-in daily backup is local only.** After timers are enabled, it writes an encrypted `.vwrec` to `/var/lib/vaultwarden-oci/backups/` at **03:15 server-local time** (with up to 15 minutes of random delay). Losing the data volume can also lose these local backups. Neither the timer nor the initial setup automatically uploads them.

To get an **offsite** backup, first configure an rclone remote **as root** (`sudo rclone config`) and then run:

```bash
sudo vwctl backup --remote 'offsite:Vaultwarden-OCI'
sudo vwctl recovery list --remote 'offsite:Vaultwarden-OCI'
```

Replace the example remote with yours. Offsite publication is currently a **manual action**, not an automatic schedule. Periodically use `sudo vwctl recovery verify` with your matching **off-server private Age identity** to confirm actual decryption. Keep the separate recovery-kit ZIP and passphrase safe off-host, monitor local disk usage, and practice a restore on a disposable machine.

The [Recovery guide](docs/RECOVERY.md) covers root rclone setup, verification, guided restore, full server loss, and retention.

## Which guide should I read?

| Guide | Purpose |
| --- | --- |
| [Install](docs/INSTALL.md) | First install, first start, safe advanced options |
| [Cloudflare tokens](docs/CLOUDFLARE-TOKENS.md) | Exact scopes for the two credentials |
| [Configuration](docs/CONFIGURATION.md) | Editing settings, SMTP, optional notifications |
| [Operations](docs/OPERATIONS.md) | Dashboard, DNS sync, timers, security and updates |
| [Recovery](docs/RECOVERY.md) | `.vwrec` backups, offline identity, recovery kit and restore |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Diagnose a failed step safely |
| [Security](docs/SECURITY.md) | Security boundaries and practices to avoid |

Maintainers: [Project boundary](docs/PROJECT-BOUNDARY.md), [Decisions](docs/DECISIONS.md), [Development](docs/DEVELOPMENT.md), [Host acceptance](docs/HOST-ACCEPTANCE.md), and [Test strategy](reports/TEST-STRATEGY.md).

## What is managed?

Vaultwarden and custom Caddy provide the application and HTTPS. Cloudflare and CrowdSec protect public traffic, with separate host-origin and web-client controls. SOPS + Age encrypts credentials and separates the server's normal key from your **off-server private recovery identity**. Encrypted `.vwrec` backups are **not** the same as the separate password-protected credential recovery-kit ZIP. systemd manages lifecycle, backup, maintenance, health/DNS and update checks; **applying** updates remains a manual decision.

If something fails, consult [Troubleshooting](docs/TROUBLESHOOTING.md). Never bypass the separate-disk guard, Cloudflare origin firewall, or recovery checks to make a status indicator green.
