# utilities/

Administrative utilities for VaultWarden-OCI. Each script is focused,
re-runnable (idempotent), and accepts `--help` for usage details.

**Not all scripts require root.** Runtime backup/health/DNS jobs are designed to run as the service user (default `ubuntu`). Use `sudo` only for privileged setup/update/firewall/deep-maintenance operations.

---

## Scripts

| File | Dispatcher subcommand | sudo required | Description |
|---|---|---|---|
| `backup-run.sh` | `./backup.sh` (all subcommands) | No (`run/list`), Yes (`verify/rotate`) | Full backup engine |
| `maintenance-db-maint.sh` | `sudo ./maintenance.sh db-maint` | Yes | Deep database optimizations |
| `maintenance-email.sh` | `sudo ./maintenance.sh test-email` | Yes | Email alert diagnostics |
| `maintenance-health.sh` | `./maintenance.sh health` | No | System health probes |
| `maintenance-run.sh` | `sudo ./maintenance.sh run` | Yes | Routine maintenance cycle |
| `maintenance-update-dns.sh` | `sudo ./maintenance.sh update-dns` | Yes | Cloudflare A record updates |
| `maintenance-update-firewall.sh` | `sudo ./maintenance.sh update-firewall` | Yes | Cloudflare IP → UFW sync |
| `maintenance-update.sh` | `sudo ./maintenance.sh update` | Yes | System/package/docker updates |
| `pre-production-drill.sh` | `make drill` | Yes | Non-destructive pre-production dry-run drill |
| `restore-run.sh` | `./restore.sh` (all subcommands) | Yes / No (`list`) | Full restore engine |
| `secrets-edit.sh` | `sudo ./utilities/secrets-edit.sh` | Yes | Interactive encrypted secrets editor |
| `secrets-export-recovery-kit.sh` | `sudo ./utilities/secrets-export-recovery-kit.sh` | Yes | Export plaintext recovery document |
| `secrets-list.sh` | `./utilities/secrets-list.sh` | No | List secret key names (no values) |
| `secrets-rotate.sh` | `sudo ./utilities/secrets-rotate.sh FIELD` | Yes | Rotate a single credential |
| `secrets-view.sh` | `./utilities/secrets-view.sh` | No | View decrypted secrets read-only |
| `setup-crowdsec.sh` | *(Standalone)* | Yes | CrowdSec installation |
| `setup-env.sh` | *(Setup phase)* | Yes | Environment file generation |
| `setup-firewall.sh` | *(Setup phase)* | Yes | Firewall configuration |
| `setup-secrets.sh` | `./setup.sh secrets` | Yes | Secrets management |
| `setup-storage.sh` | *(Setup phase)* | Yes | Storage setup and volume migration |
| `setup-system.sh` | *(Setup phase)* | Yes | System preparation |
| `setup-systemd.sh` | `./setup.sh systemd` | Yes | systemd timer management |
| `smoke-test.sh` | `make smoke-test` | Yes | Pre-production smoke test against the live stack |
| `uninstall-vaultwarden.sh` | *(Standalone)* | Yes | Full project teardown |

---

### `secrets-list.sh` — List secret key names

Lists all secret key names in `secrets/secrets.yaml` without decrypting any values.
Also invocable via `./utilities/secrets-list.sh`.

```bash
./utilities/secrets-list.sh list
./utilities/secrets-list.sh
```

---

### `secrets-view.sh` — View decrypted secrets (read-only)

Decrypts and displays `secrets/secrets.yaml` in a read-only pager. No changes
are saved. The `view` keyword is accepted as an alias for backward compatibility
but is not required.

```bash
./utilities/secrets-view.sh
./utilities/secrets-view.sh --editor vim
./utilities/secrets-view.sh --editor less
```

---

### `secrets-edit.sh` — Interactive encrypted secrets editor

Decrypts, opens in `$EDITOR`, validates YAML, re-encrypts, and backs up on
every save. Offers recovery kit export after modifications.
Also invocable via `sudo ./utilities/secrets-edit.sh`.

```bash
sudo ./utilities/secrets-edit.sh edit
sudo ./utilities/secrets-edit.sh edit --editor vim
sudo ./utilities/secrets-edit.sh edit --no-backup
sudo ./utilities/secrets-edit.sh --editor 'code --wait'
```

---

### `secrets-rotate.sh` — Rotate a single credential

Re-collects and re-hashes one named credential, atomically re-encrypts
`secrets/secrets.yaml`, and resyncs Docker secret bind-mount files.
Pass the field name directly as the first argument. The leading `rotate`
keyword is accepted as an alias for backward compatibility but is not required.

```bash
sudo ./utilities/secrets-rotate.sh admin_token
sudo ./utilities/secrets-rotate.sh email_api_token --dry-run
sudo ./utilities/secrets-rotate.sh smtp_password --no-backup
sudo ./utilities/secrets-rotate.sh caddy_cloudflare_dns_token
sudo ./utilities/secrets-rotate.sh cloudflare_zone_id
sudo ./utilities/secrets-rotate.sh cf_account_id
sudo ./utilities/secrets-rotate.sh cf_worker_bouncer_token
sudo ./utilities/secrets-rotate.sh backup_passphrase
```

Supported fields: `admin_token`, `admin_basic_auth_hash`,
`caddy_cloudflare_dns_token`, `cf_worker_bouncer_token`,
`cloudflare_zone_id`, `cf_account_id`,
`email_api_token`, `smtp_password`,
`push_installation_id`, `push_installation_key`, `backup_passphrase`.

---

### `secrets-export-recovery-kit.sh` — Export plaintext recovery document

Decrypts secrets, validates no placeholder values remain, then exports a
full recovery document (Age private key + all credentials) to a tmpfs-backed
file (mode 0600) with a 30-minute auto-delete via `at(1)`.
Also invocable via `sudo ./utilities/secrets-export-recovery-kit.sh`.

```bash
sudo ./utilities/secrets-export-recovery-kit.sh export-recovery-kit
sudo ./utilities/secrets-export-recovery-kit.sh
```

---

### `setup-system.sh` — System preparation

Installs OS dependencies (Docker, SOPS, age, etc.), configures swap, validates
the toolchain, and sets file permissions. Safe to re-run.

```bash
sudo utilities/setup-system.sh --skip-deps        # re-verify toolchain only
sudo utilities/setup-system.sh --sops-version v3.9.4
sudo utilities/setup-system.sh --dry-run
```

---

### `setup-firewall.sh` — Firewall configuration

Configures UFW (Cloudflare IP allowlist) and iptables (DOCKER-USER chain,
MASQUERADE, OCI default FORWARD-REJECT removal). Consolidates the former
standalone iptables helper into a single firewall utility.

```bash
sudo utilities/setup-firewall.sh --phase all       # UFW + iptables (default)
sudo utilities/setup-firewall.sh --phase iptables  # re-harden after Docker upgrade
sudo utilities/setup-firewall.sh --phase ufw       # refresh Cloudflare CIDRs
sudo utilities/setup-firewall.sh --dry-run
```

---

### `setup-storage.sh` — Storage setup and volume migration

Creates the project directory structure, re-checks permissions, or migrates
from boot volume to a dedicated data volume. Existing ext4/xfs filesystems are
adopted only after confirmation; blank devices are formatted only when
`DATA_VOLUME_FORCE_FORMAT=true` is set. Consolidates the former standalone
migration helper into this script.

```bash
sudo utilities/setup-storage.sh --mode setup           # create layout (first run)
sudo DATA_VOLUME_FORCE_FORMAT=true utilities/setup-storage.sh \
  --mode setup --data-device /dev/disk/by-id/your-volume
sudo utilities/setup-storage.sh --mode verify          # re-check permissions only
sudo utilities/setup-storage.sh --mode migrate         # interactive block-device migration
sudo utilities/setup-storage.sh --mode migrate status  # migration status
```

---

### `setup-env.sh` — Environment file generation

Creates or updates `.env` and `docker-compose.yml` from templates. Idempotent:
files are not overwritten unless values have changed or `--force` is passed.

```bash
sudo utilities/setup-env.sh --domain vault.example.com --email admin@example.com
sudo utilities/setup-env.sh --domain vault.example.com --email admin@example.com --force
```

---

### `setup-secrets.sh` — Secrets management

Full secrets lifecycle: setup, rotation, recovery-kit export, and emergency
break-glass admin. Consolidates the former standalone break-glass helper.

```bash
sudo utilities/setup-secrets.sh configure             # full interactive secrets setup
sudo utilities/setup-secrets.sh configure --auto      # auto-generate passwords
sudo utilities/setup-secrets.sh rotate admin_token    # rotate one credential
sudo utilities/setup-secrets.sh rotate                # rotate all credentials
sudo utilities/setup-secrets.sh export-recovery-kit

# Emergency break-glass admin (serial-console or local recovery)
sudo utilities/setup-secrets.sh breakglass create
sudo utilities/setup-secrets.sh breakglass status
sudo utilities/setup-secrets.sh breakglass remove --force
```

---

### `setup-systemd.sh` — systemd timer management

Installs, validates, and removes the VaultWarden systemd timer suite.

```bash
sudo utilities/setup-systemd.sh install    # install and enable all timers
sudo utilities/setup-systemd.sh remove     # disable and remove all timers
sudo utilities/setup-systemd.sh validate   # check installed state vs repo
sudo utilities/setup-systemd.sh status     # show timer status
sudo utilities/setup-systemd.sh install --dry-run
```

---

### `setup-crowdsec.sh` — CrowdSec installation

Installs or re-installs CrowdSec and the Cloudflare firewall bouncer.
Do not modify — standalone and version-pinned.

```bash
sudo utilities/setup-crowdsec.sh
```

---

### `uninstall-vaultwarden.sh` — Full project teardown

Removes all VaultWarden-OCI components. After it completes, `setup.sh install`
can run on the same host as if it were a fresh machine.

Does **NOT** remove: Docker CE, system packages, user accounts, swap, or
anything that pre-existed this project.

```bash
sudo utilities/uninstall-vaultwarden.sh run --dry-run
sudo utilities/uninstall-vaultwarden.sh run --i-have-saved-my-recovery-kit
sudo utilities/uninstall-vaultwarden.sh run --force   # CI/automation only
```

---

### `maintenance-run.sh` — Routine maintenance cycle

Full maintenance cycle: cleanup (logs, backups, Docker) → DB optimisation → health validation.
Also invocable via `sudo ./maintenance.sh run`.

```bash
sudo utilities/maintenance-run.sh run
sudo utilities/maintenance-run.sh run --comprehensive   # include DNS + firewall
sudo utilities/maintenance-run.sh run --dry-run
```

---

### `maintenance-health.sh` — System health probes

Runs all system health checks. Also invocable via `./maintenance.sh health`.

```bash
sudo utilities/maintenance-health.sh health
sudo utilities/maintenance-health.sh health --fix
sudo utilities/maintenance-health.sh health --report
```

---

### `maintenance-update.sh` — System/package/docker updates

Pulls new images and optionally updates OS packages. Also invocable via `sudo ./maintenance.sh update`.

```bash
sudo utilities/maintenance-update.sh update --system
sudo utilities/maintenance-update.sh update --images
sudo utilities/maintenance-update.sh update --all --email
```

---

### `maintenance-db-maint.sh` — Deep database optimizations

Stops VaultWarden, creates a pre-maintenance encrypted backup, runs `VACUUM + wal_checkpoint(TRUNCATE) + ANALYZE`, verifies integrity, restarts. Also invocable via `sudo ./maintenance.sh db-maint`.

```bash
sudo utilities/maintenance-db-maint.sh db-maint
sudo utilities/maintenance-db-maint.sh db-maint --force    # no confirm prompt
sudo utilities/maintenance-db-maint.sh db-maint --dry-run
```

---

### `maintenance-email.sh` — Email alert diagnostics

Sends test emails to verify the configured delivery chain. Also invocable via `sudo ./maintenance.sh test-email`.

```bash
sudo utilities/maintenance-email.sh test-email
sudo utilities/maintenance-email.sh test-email --recipient admin@example.com
sudo utilities/maintenance-email.sh test-email --dry-run
```

---

### `maintenance-update-dns.sh` — Cloudflare A record updates

Updates Cloudflare DNS A record with the current public IP. Also invocable via `sudo ./maintenance.sh update-dns`.

```bash
sudo utilities/maintenance-update-dns.sh update-dns
sudo utilities/maintenance-update-dns.sh update-dns --email --dry-run
```

---

### `maintenance-update-firewall.sh` — Cloudflare IP → UFW sync

Syncs Cloudflare IP ranges into UFW. Also invocable via `sudo ./maintenance.sh update-firewall`.

```bash
sudo utilities/maintenance-update-firewall.sh update-firewall
sudo utilities/maintenance-update-firewall.sh update-firewall --dry-run
```

---

### `backup-run.sh` — Full backup engine

Directly callable backup engine; identical to running `./backup.sh <subcommand>`.

```bash
sudo utilities/backup-run.sh run db --rclone
sudo utilities/backup-run.sh run full --full-verification
./utilities/backup-run.sh list
```

---

### `restore-run.sh` — Full restore engine

Directly callable restore engine; identical to running `./restore.sh <subcommand>`.

```bash
sudo utilities/restore-run.sh latest db
sudo utilities/restore-run.sh interactive --remote
./utilities/restore-run.sh list
```

---

## Design Principles

| Principle | Enforcement |
|---|---|
| **Idempotent** | Check-before-act everywhere (`grep -q`, `iptables -C`, `dpkg -s`) |
| **Self-sufficient** | Each script has its own arg parser; runs standalone |
| **No env-var IPC** | CLI flags only for inter-script state |
| **Dry-run complete** | Every destructive action gated by `DRY_RUN` check |
| **Root guard** | `(( EUID == 0 ))` checked after arg parsing |
| **Colour-tagged output** | `[HH:MM:SS] [script-name.sh] LEVEL message` via `lib/common.sh` |

---

## Shared library: `lib/maintenance-utils.sh`

Sourced by `maintenance-run.sh`, `maintenance-db-maint.sh`, and `maintenance-email.sh`. Provides: cleanup helpers, `optimize_database`, `validate_system_health`, `generate_maintenance_summary`, and `_wait_wal_quiesce`. **NOT** executable — library only.
