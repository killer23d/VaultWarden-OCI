# Scripts Reference — VaultWarden-OCI

This guide documents the current script surface for the repository. The project is designed to be operated primarily through these scripts, with Docker and Compose used mainly for inspection, troubleshooting, or exceptional low-level intervention.

Related docs: [OPERATIONS.md](OPERATIONS.md) · [CONFIGURATION.md](CONFIGURATION.md) · [BACKUP-RESTORE.md](BACKUP-RESTORE.md)

---

## Script inventory

Current top-level operational scripts:

| Script | Primary role | Typical privilege |
| :-- | :-- | :-- |
| `setup.sh` | Host bootstrap and config generation | `sudo` |
| `setup-secrets.sh` | Initial secret bootstrap | normal user |
| `startup.sh` | Start, stop, and restart services | normal user |
| `health.sh` | Health validation and optional recovery | normal user |
| `backup.sh` | Encrypted backup creation and listing | normal user |
| `restore.sh` | Restore workflows | normal user |
| `edit-secrets.sh` | Secret editing, rotation, and export | normal user |
| `update.sh` | Validated update workflow | normal user |
| `maintenance.sh` | Maintenance, DNS, email, firewall, DB tasks | mixed; `--db-maint` may require `sudo` |
| `create-breakglass-admin.sh` | Emergency admin lifecycle | typically `sudo` |
| `cron-setup.sh` | Scheduled automation install and validation | `sudo` |

Supporting libraries live under `lib/` and are sourced by the operational scripts.

---

## Control-plane guidance

Use these scripts as the supported operational API for the project.

In practice, that means:

- Use `setup.sh` to generate and re-generate runtime files.
- Use `setup-secrets.sh` and `edit-secrets.sh` for secrets.
- Use `startup.sh` instead of ad-hoc Compose commands for normal lifecycle work.
- Use `update.sh` instead of hand-rolling upgrade sequences.
- Use `cron-setup.sh` instead of maintaining manual cron drift.

---

## `setup.sh`

Purpose: prepare the host and generate deployment files from templates.

Common usage:

```bash
sudo ./setup.sh --domain vault.example.com --email admin@example.com --auto
sudo ./setup.sh --domain vault.example.com --email admin@example.com --force
```

Common flags:

| Flag | Purpose |
| :-- | :-- |
| `--domain` | Required deployment URL/hostname input |
| `--email` | Required admin email input |
| `--auto` | Fast mostly non-interactive bootstrap |
| `--use-latest` | Prefer latest-tag behavior instead of pinned/default versions |
| `--skip-deps` | Skip dependency installation |
| `--force` | Reapply and overwrite generated config artifacts |
| `--dry-run` | Preview actions |

After a successful run, start a fresh shell session so Docker group membership is active.

---

## `setup-secrets.sh`

Purpose: guided bootstrap of encrypted secret material, especially useful after reviewing `.env` during first install.

Common usage:

```bash
./setup-secrets.sh
./setup-secrets.sh --auto
./setup-secrets.sh --auto --quiet-summary
```

Use this when you want the repository’s structured secret-collection path rather than ad-hoc manual entry.

---

## `startup.sh`

Purpose: standard service lifecycle entry point.

Common usage:

```bash
./startup.sh
./startup.sh --force
./startup.sh --down
```

Typical responsibilities include preparing runtime directories, materializing Docker secrets from encrypted inputs, starting or stopping the Compose stack, refreshing DNS where applicable, and running post-start validation unless skipped.

Useful flags:

| Flag | Purpose |
| :-- | :-- |
| `--force` | Restart services through the full scripted path |
| `--force-restart` | Legacy alias for `--force` |
| `--down` | Stop services |
| `--skip-health` | Skip post-start validation |
| `--background` | Daemonized start path |
| `--dry-run` | Preview actions |

---

## `health.sh`

Purpose: validate the deployment and optionally trigger recovery behavior.

Common usage:

```bash
./health.sh
./health.sh --comprehensive
./health.sh --auto-recover
./health.sh --comprehensive --auto-recover --email
```

Useful flags:

| Flag | Purpose |
| :-- | :-- |
| `--comprehensive` | Run broader checks beyond the default validation set |
| `--auto-recover` | Attempt automated recovery for unhealthy services |
| `--email` | Send notification on critical issues |
| `--quiet` | Reduce console output |
| `--json` | Emit structured output |
| `--output FILE` | Save report to a file |
| `--alert-threshold N` | Adjust alerting threshold |

Use this after deployments, updates, maintenance, and recovery work.

---

## `backup.sh`

Purpose: create encrypted backups and optionally sync them offsite.

Common usage:

```bash
./backup.sh --type db
./backup.sh --type full --full-verification
./backup.sh --type emergency
./backup.sh --list
```

Common flags:

| Flag | Purpose |
| :-- | :-- |
| `--type TYPE` | Backup tier: `db`, `full`, `emergency`, and other project-supported modes |
| `--rclone` | Sync the created archive to the configured remote |
| `--full-verification` | Run a deeper verification path |
| `--skip-full-verification` | Use the faster verification path |
| `--keep N` | Override retention for this run |
| `--email` | Send completion/failure notification |
| `--quiet` | Reduce output |
| `--force` | Override normal lock behavior |
| `--list` | List available backups |
| `--dry-run` | Preview actions |

The project’s Age key health checks are part of the backup readiness path.

---

## `restore.sh`

Purpose: restore from a selected backup archive.

Common usage:

```bash
./restore.sh
./restore.sh --latest --type db
./restore.sh --latest --type full --force --no-backup
./restore.sh --file /path/to/backup.age --force
```

Common flags:

| Flag | Purpose |
| :-- | :-- |
| `--file FILE` | Restore a specific archive |
| `--latest` | Restore the latest archive, optionally by type |
| `--type TYPE` | Filter restore candidates |
| `--force` | Skip confirmation prompts |
| `--no-backup` | Skip pre-restore backup creation |
| `--skip-verification` | Skip restore-side integrity checks |
| `--dry-run` | Preview actions |

Use the interactive path first unless you have a strong reason to force a targeted restore.

---

## `edit-secrets.sh`

Purpose: day-two secret management.

Common usage:

```bash
./edit-secrets.sh
./edit-secrets.sh --test
./edit-secrets.sh --list
./edit-secrets.sh --rotate smtp_password
./edit-secrets.sh --export-recovery-kit
```

Common flags:

| Flag | Purpose |
| :-- | :-- |
| `--editor EDITOR` | Override the editor |
| `--rotate FIELD` | Rotate or regenerate a single field |
| `--export-recovery-kit` | Export plaintext recovery material |
| `--view` | View decrypted secrets |
| `--list` | Show defined secret keys |
| `--test` | Validate decryption and secret access |
| `--no-backup` | Skip automatic backup of the encrypted file |

Restart and revalidate after meaningful secret changes.

---

## `update.sh`

Purpose: validated container update workflow with optional system package updates.

Common usage:

```bash
./update.sh
./update.sh --system
./update.sh --system --email
```

Common flags:

| Flag | Purpose |
| :-- | :-- |
| `--system` | Include host package and Docker-related updates |
| `--email` | Send update notification |
| `--no-backup` | Skip the pre-update backup step |
| `--dry-run` | Preview actions |

This should be the default upgrade path instead of manual pull-and-restart sequences.

---

## `maintenance.sh`

Purpose: consolidated maintenance script for routine and targeted tasks.

Common usage:

```bash
./maintenance.sh --comprehensive
./maintenance.sh --update-dns
./maintenance.sh --update-firewall
./maintenance.sh --db-maint
./maintenance.sh --test-email --verbose
```

Common modes and flags:

| Mode or flag | Purpose |
| :-- | :-- |
| `--comprehensive` | Full maintenance cycle |
| `--update-dns` | Refresh Cloudflare DNS A record |
| `--update-firewall` | Refresh Cloudflare-related firewall inputs |
| `--db-maint` | Run deeper SQLite maintenance |
| `--test-email` | Run mail diagnostics |
| `--verbose` | More detailed mail-diagnostic output |
| `--recipient EMAIL` | Override mail test recipient |
| `--email` | Send maintenance summary |
| `--dry-run` | Preview actions |
| `--force` | Skip confirmation for selected destructive modes |

Historically separate helper scripts were consolidated into this script, so this is the correct modern entry point for those tasks.

---

## `create-breakglass-admin.sh`

Purpose: manage the emergency admin account used for recovery scenarios such as console access.

Common usage:

```bash
./create-breakglass-admin.sh --create
./create-breakglass-admin.sh --status
./create-breakglass-admin.sh --password
./create-breakglass-admin.sh --remove
```

Use it as part of the recovery plan, not as a routine daily administration path.

---

## `cron-setup.sh`

Purpose: install, validate, list, and remove scheduled automation.

Common usage:

```bash
sudo ./cron-setup.sh --install
sudo ./cron-setup.sh --list
sudo ./cron-setup.sh --validate
sudo ./cron-setup.sh --remove
```

Common flags:

| Flag | Purpose |
| :-- | :-- |
| `--install` | Install the current cron set securely |
| `--list` | Show installed jobs |
| `--validate` | Validate cron and related security assumptions |
| `--remove` | Remove installed jobs |
| `--dry-run` | Preview changes |

Current documented schedule:

| Schedule | Job |
| :-- | :-- |
| 2 AM Mon–Sat | Comprehensive maintenance |
| 3 AM Sunday | Full backup with verification and optional remote sync |
| 4 AM Mon–Sat | Database backup with optional remote sync |
| Every 30 minutes | Health check |
| Every hour | DNS update |
| Saturday 4 AM | Firewall update |

### Lock directory note

The project uses `/run/vaultwarden-locks/` for flock-protected jobs. Because `/run` is tmpfs-backed, the directory is cleared on reboot.

After reboot, recreate or validate the lock setup:

```bash
sudo ./cron-setup.sh --install
# or
sudo ./cron-setup.sh --validate
```

To recreate it automatically:

```bash
echo 'd /run/vaultwarden-locks 0700 root root -' | sudo tee /etc/tmpfiles.d/vaultwarden-locks.conf
sudo systemd-tmpfiles --create
```

---

## Libraries in `lib/`

The current repository includes shared libraries for common concerns:

| Library | Responsibility |
| :-- | :-- |
| `lib/common.sh` | Logging, env loading, validation, shared helpers |
| `lib/docker.sh` | Docker and Compose lifecycle helpers |
| `lib/crypto.sh` | Encryption, hashing, and Age/SOPS utilities |
| `lib/security.sh` | Security validation and secure file handling |
| `lib/backup_utils.sh` | Backup-specific helper logic |
| `lib/secrets.sh` | Secret bootstrap, validation, rotation helpers |
| `lib/simple_key_resilience.sh` | Age key validation and recovery-support utilities |

These libraries are part of the internal implementation surface, but they are also useful when you need to understand script behavior more deeply.

---

## Practical guidance

When in doubt:

- Run scripts from the project root.
- Use `--dry-run` when it exists.
- Use `setup.sh` and templates for configuration changes.
- Use `startup.sh` and `health.sh` after changes.
- Use `update.sh` for upgrades.
- Use `cron-setup.sh` instead of hand-managed cron entries.

That keeps operations aligned with the current repository design rather than drifting into one-off local behavior.
