# Scripts Reference — VaultWarden-OCI

Complete reference for all management scripts and utility libraries in VaultWarden-OCI.

> **Architecture note:** Several scripts that previously existed as standalone files have been **merged** into `maintenance.sh` via sub-command flags:
> - `db-maint.sh` → `./maintenance.sh --db-maint`
> - `update-dns.sh` → `./maintenance.sh --update-dns`
> - `test-email-simple.sh` → `./maintenance.sh --test-email`
>
> This reduces the number of files to maintain while keeping each task fully self-contained via locking and separate log files.

---

## 🗂️ Script Inventory

| # | Script | Category | sudo? |
|---|---|---|---|
| 1 | `setup.sh` | Initialisation | ✅ |
| 2 | `startup.sh` | Service management | — |
| 3 | `health.sh` | Monitoring | — |
| 4 | `backup.sh` | Backup | — |
| 5 | `restore.sh` | Backup | — |
| 6 | `edit-secrets.sh` | Secrets | — |
| 7 | `update.sh` | Updates | — |
| 8 | `maintenance.sh` | Maintenance (merged) | `--db-maint` only |
| 9 | `create-breakglass-admin.sh` | Emergency | ✅ |
| 10 | `cron-setup.sh` | Automation | ✅ |

**Utility libraries (6):** `lib/common.sh`, `lib/docker.sh`, `lib/crypto.sh`, `lib/security.sh`, `lib/backup_utils.sh`, `lib/simple_key_resilience.sh`

---

## 🔧 Core Management Scripts

### 1. `setup.sh`
**Purpose:** One-time system initialisation and configuration generation

```bash
sudo ./setup.sh --domain vault.example.com --email admin@example.com [OPTIONS]
```

**Key features:**
- Template-based `docker-compose.yml` and `.env` generation
- Platform-specific SSH log detection (Oracle Linux: `/var/log/secure`; Ubuntu: `/var/log/auth.log`)
- UFW firewall configured for Cloudflare-only web traffic
- Age encryption key generation
- SOPS configuration setup
- Dependency installation

**Options:**

| Option | Description |
|---|---|
| `--domain DOMAIN` | VaultWarden domain — required |
| `--email EMAIL` | Administrator email — required |
| `--auto` | Automated setup with minimal prompts |
| `--use-latest` | Use `latest` image tags instead of pinned versions |
| `--skip-deps` | Skip dependency installation |
| `--force` | Overwrite existing configuration files |
| `--dry-run` | Show what would be done without executing |

```bash
sudo ./setup.sh --domain vault.example.com --email admin@example.com --auto
```

> ⚠️ After `setup.sh` adds your user to the `docker` group, **log out and back in** (or start a new shell session) before running any `docker` or `make` commands.

---

### 2. `startup.sh`
**Purpose:** Start, stop, and restart VaultWarden services

```bash
./startup.sh [OPTIONS]
```

**What it does:**
1. Decrypts `secrets/secrets.yaml` once and writes individual Docker secret files to `secrets/.docker_secrets/` (600 permissions)
2. Creates `${PROJECT_STATE_DIR}/logs/` subdirectories with correct ownership
3. Starts all containers with `docker compose up -d`
4. Updates Cloudflare DNS A record
5. Runs `health.sh` post-startup

**Options:**

| Option | Description |
|---|---|
| `--force` | Force restart (preferred flag) — stops containers then restarts |
| `--force-restart` | Legacy alias for `--force` (kept for compatibility) |
| `--skip-health` | Skip post-startup health check |
| `--background` | Start in daemon mode |
| `--dry-run` | Preview operations without executing |

**Makefile shortcuts:**
```bash
make start     # Full initialisation startup (alias: make up)
make stop      # Graceful shutdown (alias: make down)
make restart   # Force restart
```

---

### 3. `health.sh`
**Purpose:** System health monitoring, diagnostics, and auto-recovery

```bash
./health.sh [OPTIONS]
```

**Always-on checks:**
- All 4 containers running (`vaultwarden_app`, `vaultwarden_caddy`, `vaultwarden_fail2ban`, `vaultwarden_postfix`)
- VaultWarden accessible on `localhost:8080`
- External web access via Cloudflare
- Disk space (warn >70%, critical >alert threshold [default 80%])
- SSL certificate expiration (warn <30 days, critical <7 days)
- Database size and growth rate
- Backup age and decrypt verification (Age)
- Email notification configuration

**Options:**

| Option | Description |
|---|---|
| `--comprehensive` | Add resource usage, configuration, and security checks |
| `--auto-recover` | Attempt automatic container restart on failure |
| `--email` | Send email if critical issues found |
| `--quiet` | Suppress non-error console output |
| `--json` | Output results as JSON |
| `--output FILE` | Save report to file |
| `--alert-threshold N` | Set alert threshold % (default: 80) |

```bash
./health.sh --comprehensive --auto-recover --email

make health                        # Basic
make health AUTO_RECOVER=true      # With auto-recovery
make health COMPREHENSIVE=true     # Comprehensive
make health-email                  # Comprehensive + email
```

---

### 4. `backup.sh`
**Purpose:** Create Age-encrypted backups with integrity verification

```bash
sudo ./backup.sh [OPTIONS]
```

**Backup types:**

| Type | Contents | Retention |
|---|---|---|
| `auto` | Auto-selects `db` or `full` based on DB age and last full backup age | — |
| `db` | SQLite database only | 14 days |
| `full` | Database + config + Caddy certs + logs (no secrets) | 30 days |
| `emergency` | Everything including secrets | 90 days |

**Options:**

| Option | Description |
|---|---|
| `--type TYPE` | `auto` (default), `db`, `full`, or `emergency` |
| `--rclone` | Sync encrypted backup to rclone remote after creation (non-fatal on failure) |
| `--full-verification` | End-to-end decrypt + integrity check before sync (fatal on failure) |
| `--skip-full-verification` | Fast checksum only — explicit default |
| `--keep N` | Retention period in days (default: 14) |
| `--email` | Send email notification on completion/failure |
| `--quiet` | Suppress non-error output |
| `--force` | Ignore locks and force backup |
| `--list` | List existing backups and exit (no root required) |
| `--dry-run` | Preview operations without executing |

```bash
# Daily
sudo ./backup.sh --type db

# Daily with offsite sync
sudo ./backup.sh --type db --rclone --email

# Weekly with full verification and remote sync
sudo ./backup.sh --type full --full-verification --rclone --email

# Emergency kit
sudo ./backup.sh --type emergency --rclone

# Keep 30 days of backups
sudo ./backup.sh --type db --keep 30

make backup              # Database backup
make backup-full         # Full backup
make backup-emergency    # Emergency kit
make list-backups        # List backups
```

---

### 5. `restore.sh`
**Purpose:** Restore from an Age-encrypted backup

```bash
./restore.sh [OPTIONS]
```

**Options:**

| Option | Description |
|---|---|
| `--file FILE` | Specific backup file to restore |
| `--latest` | Use the newest backup (optionally filtered by `--type`) |
| `--type TYPE` | Filter backup list by type |
| `--force` | Skip confirmation prompts |
| `--no-backup` | Skip pre-restore emergency snapshot |
| `--skip-verification` | Skip integrity check |
| `--dry-run` | Preview operations |

```bash
# Interactive (recommended)
./restore.sh
make restore

# Specific file
./restore.sh --file /path/to/backup.age --force

# Latest DB backup (non-interactive)
./restore.sh --latest --type db
make restore-db

# Latest full backup, skip confirmation and pre-restore snapshot
# (used internally by update.sh rollback)
./restore.sh --latest --type full --force --no-backup
```

---

### 6. `edit-secrets.sh`
**Purpose:** Securely edit SOPS-encrypted secrets

```bash
./edit-secrets.sh [OPTIONS]
```

**Key features:**
- SOPS Age key path never appears in the process list
- Decrypts to a secure temp file (shredded on exit)
- Creates automatic backup before editing
- Validates secrets after editing

**Managed secrets:**
`admin_token`, `admin_basic_auth_hash`, `smtp_password`, `push_installation_id`, `push_installation_key`, `caddy_cloudflare_dns_token`, `fail2ban_cloudflare_firewall_token`, `backup_passphrase`

**Options:**

| Option | Description |
|---|---|
| `--editor EDITOR` | Specify editor (default: nano) |
| `--rotate FIELD` | Rotate (regenerate) a single secret field |
| `--export-recovery-kit` | Export a plaintext recovery document (key + all secrets) |
| `--view` | View decrypted secrets without editing |
| `--list` | List all available secret key names |
| `--no-backup` | Skip automatic backup before editing |

```bash
./edit-secrets.sh
./edit-secrets.sh --editor vim
./edit-secrets.sh --rotate smtp_password
./edit-secrets.sh --export-recovery-kit
./edit-secrets.sh --view
./edit-secrets.sh --list
make edit-secrets
make test-secrets    # runs --list internally
```

---

### 7. `update.sh`
**Purpose:** Update container images and optionally system packages

```bash
./update.sh [OPTIONS]
```

**Options:**

| Option | Description |
|---|---|
| `--system` | Also update system packages (apt) and Docker engine |
| `--email` | Send email notification on completion |
| `--no-backup` | Skip pre-update emergency backup |
| `--dry-run` | Preview operations |

```bash
./update.sh
./update.sh --system --email

make update           # Containers only
make update-system    # Containers + system packages
```

---

### 8. `maintenance.sh` *(merged script)*
**Purpose:** Routine cleanup, optimisation, DNS update, deep DB maintenance, and email diagnostics — all in one script with sub-command modes

```bash
./maintenance.sh [OPTIONS]
```

**Modes overview:**

| Mode | Command | Cleanup runs? |
|---|---|---|
| Routine | `--comprehensive` | ✅ |
| Targeted DNS | `--update-dns` (alone) | ❌ |
| Targeted Firewall | `--update-firewall` (alone) | ❌ |
| Deep DB maintenance | `--db-maint` | ❌ |
| Email diagnostics | `--test-email` | ❌ |

**Routine options:**

| Option | Description |
|---|---|
| `--comprehensive` | Full routine: cleanup + DB opt + firewall + DNS + health |
| `--no-logs` | Skip log cleanup |
| `--no-backups` | Skip backup pruning |
| `--no-docker` | Skip Docker resource cleanup |
| `--no-database` | Skip scheduled DB optimisation |
| `--email` | Send summary email on completion |
| `--dry-run` | Preview any mode without changes |

**Deep DB maintenance options:**

| Option | Description |
|---|---|
| `--db-maint` | Run full VACUUM cycle (stops VaultWarden; prompts for confirmation) |
| `--db-maint --force` | Skip the confirmation prompt |

**Email diagnostic options:**

| Option | Description |
|---|---|
| `--test-email` | Run Postfix + fail2ban + end-to-end email tests |
| `--verbose` | Detailed output (only meaningful with `--test-email`) |
| `--recipient EMAIL` | Override default `ADMIN_EMAIL` recipient |

**Targeted options:**

| Option | Description |
|---|---|
| `--update-firewall` | Fetch latest Cloudflare IPs and update UFW rules |
| `--update-dns` | Check current public IP and update Cloudflare DNS A record |

```bash
# Routine
./maintenance.sh --comprehensive
./maintenance.sh --comprehensive --email
make maintenance
make maintenance-full

# Deep DB
sudo ./maintenance.sh --db-maint
sudo ./maintenance.sh --db-maint --force
make db-maint

# Email
./maintenance.sh --test-email
./maintenance.sh --test-email --verbose
./maintenance.sh --test-email --recipient admin@example.com
make test-email

# Targeted
./maintenance.sh --update-dns
./maintenance.sh --update-firewall
make update-dns
```

---

### 9. `create-breakglass-admin.sh`
**Purpose:** Emergency OS admin account for OCI Serial Console access

```bash
./create-breakglass-admin.sh [OPTIONS]
```

**Key features:**
- Creates a non-root user with `sudo` privileges
- SSH key authentication + console password authentication
- Comprehensive audit logging
- Security validation via `lib/security.sh`

**Options:**

| Option | Description |
|---|---|
| `--create` | Create the emergency admin account |
| `--status` | Show current break-glass admin status |
| `--password` | Generate a new emergency password |
| `--validate` | Run security validation |
| `--remove` | Remove the emergency admin account |

```bash
./create-breakglass-admin.sh --create

make breakglass-create
make breakglass-status
make breakglass-remove
```

---

### 10. `cron-setup.sh`
**Purpose:** Install, validate, and manage automated cron jobs with security hardening

```bash
sudo ./cron-setup.sh [OPTIONS]
```

**Key features:**
- Copies scripts to `/opt/vaultwarden-scripts/` with `root:root 700` permissions
- Patches `SCRIPT_DIR` and `lib/` source paths at install time (prevents LPE)
- `flock`-based mutual exclusion prevents overlapping cron runs
- Split-brain detection: warns when `/opt/` scripts are older than the git repo
- Validates `lib/simple_key_resilience.sh` presence (Age key health checks)

**Options:**

| Option | Description |
|---|---|
| `--install` | Install cron jobs securely |
| `--remove` | Remove cron jobs and `/opt/` script copies |
| `--list` | List current jobs + check for split-brain |
| `--validate` | Validate security configuration |
| `--dry-run` | Preview without executing |

**Installed schedule:**

| Schedule | Job |
|---|---|
| Daily 2 AM (Mon–Sat) | `backup.sh --type db --rclone --email` |
| Daily 4 AM | `backup.sh --type db --rclone --email` |
| Every 30 min | `health.sh --quiet` |
| Saturday 4 AM | `maintenance.sh --update-firewall` |
| Sunday 3 AM | `backup.sh --type full --full-verification --rclone --email` |
| Every hour | `maintenance.sh --update-dns` |

All scripts run from `$PROJECT_ROOT` to preserve context. Health and maintenance jobs are `flock`-protected. Sunday maintenance is intentionally skipped to avoid overlap with the full backup.

```bash
sudo ./cron-setup.sh --install
sudo ./cron-setup.sh --list
sudo ./cron-setup.sh --validate
sudo ./cron-setup.sh --remove

make cron-install
make cron-list
make cron-remove
```

---

## 📚 Utility Libraries

All libraries live in `lib/` and are sourced at the top of every script. At cron-install time, `cron-setup.sh` copies the entire `lib/` tree to `/opt/vaultwarden-scripts/lib/` and patches source paths.

### `lib/common.sh`
Core functions used by every script.

| Function | Description |
|---|---|
| `init_common_lib "$0"` | Initialise library with script context |
| `log_info/success/warn/error` | Colour-coded logging |
| `require_commands` | Assert required binaries are present |
| `get_config_value KEY DEFAULT` | Read a variable from `.env` |
| `load_env_file` | Source `.env` into the environment |
| `get_real_user` | Resolve actual user even under `sudo` |
| `ensure_dir PATH MODE` | Create directory with permissions |
| `retry_with_backoff N DELAY CMD` | Retry with exponential backoff |
| `validate_domain/email/port` | Input validation helpers |
| `send_notification_email SUBJ BODY` | Send via Postfix container |

### `lib/docker.sh`
Docker and Docker Compose helpers.

| Function | Description |
|---|---|
| `require_docker` | Verify Docker daemon is accessible |
| `is_service_running NAME` | Check if a Compose service is running |
| `wait_for_service NAME TIMEOUT` | Poll until service is healthy |
| `stop_service / start_service` | Service lifecycle helpers |
| `get_container_status` | Detailed container status |
| `docker_cleanup` | Remove unused containers, images, volumes |

### `lib/crypto.sh`
Encryption, decryption, and key management.

| Function | Description |
|---|---|
| `generate_age_key PATH` | Generate an Age identity key |
| `get_age_public_key PATH` | Extract the Age public key |
| `encrypt_data / decrypt_data` | Age encrypt / decrypt |
| `encrypt_sops_file / decrypt_sops_file` | SOPS file operations |
| `generate_secure_string N` | Cryptographically secure random string |
| `calculate_sha256 FILE` | SHA-256 checksum |
| `secure_file PATH` | Set restrictive permissions on a file |
| `check_age_key PATH` | Validate Age key file (used by `health.sh`) |

### `lib/security.sh`
Centralised security validation.

| Function | Description |
|---|---|
| `validate_file_permissions PATH MODE OWNER GROUP` | Assert file permissions |
| `validate_directory_permissions PATH` | Recursive directory validation |
| `create_secure_file PATH CONTENT MODE OWNER GROUP` | Atomic secure file creation |
| `secure_cleanup PATH` | Multi-pass secure deletion |
| `validate_password_strength PASSWORD` | Password strength check |
| `generate_secure_random N` | Cryptographically secure random bytes |
| `validate_system_security` | Comprehensive system security audit |

### `lib/backup_utils.sh`
Backup-specific helpers.

| Function | Description |
|---|---|
| `check_backup_disk_space DIR MIN_MB` | Verify available disk space |
| `list_backups DIR` | List backups with metadata |
| `get_backup_metadata FILE` | Extract metadata from a backup file |
| `verify_backup_integrity FILE` | Verify backup file integrity |
| `cleanup_old_backups DIR TYPE DAYS` | Remove old backups per retention policy |
| `format_backup_size BYTES` | Human-readable size formatting |

### `lib/secrets.sh`
Secrets collection, generation, hashing, validation, and recovery kit export. Used by `setup-secrets.sh` and `edit-secrets.sh`.

| Function | Description |
|---|---|
| `collect_secret_field FIELD` | Interactive prompt, hash, and validate a single secret field |
| `auto_generate_secret_field FIELD` | Non-interactive generation or CHANGE_ME placeholder per field |
| `ensure_sops_env` | Set `SOPS_AGE_KEY_FILE` and `SOPS_CONFIG` for sops calls |
| `secrets_file_exists` | Check whether `secrets/secrets.yaml` is present |
| `validate_secrets_decryption` | Assert the secrets file can be decrypted |
| `validate_required_secrets` | Assert all required keys are present and non-empty |
| `check_placeholder_values` | Detect any remaining CHANGE_ME / PLACEHOLDER values |
| `list_secret_keys` | Print all key names in the secrets file |
| `create_secrets_backup` | Timestamped backup of the encrypted secrets file |
| `generate_recovery_kit FILE` | Write a full plaintext recovery document (key + secrets) |
| `offer_recovery_kit_export` | Interactive or auto prompt to export a recovery kit |

### `lib/simple_key_resilience.sh`
Three-tier Age key protection strategy. Sourced by `backup.sh` (Tier 1 runs automatically on every backup) and available for manual use via the functions below.

> **Optional dependencies:** Tier 3 can generate a QR code if `qrencode` is installed (`sudo apt install qrencode`) and will produce a PDF if `wkhtmltopdf` is installed (`sudo apt install wkhtmltopdf`). Without either, it produces a plain HTML file instead.

| Tier | Function | Description |
|---|---|---|
| 1 | `simple_verify_age_key` | Health check: asserts file exists, auto-fixes permissions to 600 if needed, validates key structure via `age-keygen -y`, and performs a full encrypt/decrypt roundtrip to confirm the key is functional. Called automatically by `backup.sh` before every backup run. |
| 2 | `create_password_manager_escrow OUTPUT_FILE` | Writes a formatted plain-text escrow document containing the Age private key, public key, hostname, date, and step-by-step recovery instructions. Designed to be pasted as a Secure Note in a password manager (Bitwarden, 1Password, etc.). Output is chmod 600. |
| 3 | `create_printable_key_backup [OUTPUT_PDF]` | Generates a printable PDF (requires `wkhtmltopdf`) or HTML paper backup containing the Age key, optional QR code (requires `qrencode`), and recovery steps. The temp HTML file containing the plaintext key is securely wiped via `shred` (or `dd` fallback) immediately after PDF generation. |

**Recommended usage cadence:**

| When | Action |
|---|---|
| After initial setup | Run Tier 2 — store escrow in your password manager |
| After rotating the Age key | Re-run Tier 2 and optionally Tier 3 |
| After any major config change | Re-run `./edit-secrets.sh --export-recovery-kit` (includes the key) |
| Tier 1 | Automatic — runs on every `backup.sh` invocation |

```bash
# Source the library manually if calling outside of backup.sh
source lib/simple_key_resilience.sh

# Tier 1 — manual key health check
simple_verify_age_key

# Tier 2 — password manager escrow export
create_password_manager_escrow ~/vaultwarden-age-key-escrow.txt
# ⚠️  Copy to your password manager, then delete:
shred -fuz ~/vaultwarden-age-key-escrow.txt

# Tier 3 — printable paper backup (PDF if wkhtmltopdf present, HTML otherwise)
sudo apt install qrencode wkhtmltopdf   # optional but recommended
create_printable_key_backup ~/vaultwarden-key-backup.pdf
# ⚠️  Print and store in a fireproof safe, then delete the file
```

---

## 🏗️ Script Design Patterns

### Standardised Error Handling

```bash
function_name() {
    # perform operation
    return 0  # success
    return 1  # failure
}

main() {
    if ! function_name; then
        log_error "Operation failed"
        exit 1
    fi
    exit 0
}
```

### Trap-Based Cleanup

```bash
CLEANUP_ACTIONS=()
register_cleanup() { CLEANUP_ACTIONS+=("$1"); }
perform_cleanup() {
    for ((idx=${#CLEANUP_ACTIONS[@]}-1; idx>=0; idx--)); do
        eval "${CLEANUP_ACTIONS[$idx]}" 2>/dev/null || true
    done
}
trap perform_cleanup EXIT
```

### Library Integration

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh"
# … additional libraries as needed
```

### Flock-Based Mutual Exclusion (Cron Jobs)

Health and maintenance cron jobs are wrapped with `flock -n LOCKFILE CMD`. If the previous run is still active, the new invocation exits immediately — no queuing, no duplicate alerts.

---

## ✅ Best Practices

### Script Execution
1. **Run from project root** — all scripts resolve paths relative to `SCRIPT_DIR`
2. **Use `sudo` where required** — `setup.sh`, `cron-setup.sh`, `create-breakglass-admin.sh`, and `maintenance.sh --db-maint`
3. **Check `--help` first** — every script supports `--help`
4. **Use `--dry-run`** — preview any operation before applying

### Makefile Usage
1. **Prefer Makefile shortcuts** — they handle quoting and flags consistently
2. **Run `make help`** to see all available targets
3. **Use `make test-config`** to validate docker-compose config before deployment

### Security
1. **Never hardcode secrets in `.env`** — use `./edit-secrets.sh` for all sensitive values
2. **Review generated files** — inspect `docker-compose.yml` and `.env` after `setup.sh`
3. **Scripts auto-clean temp files** — sensitive temp files are shredded on exit
4. **All admin actions are logged** — check `/var/log/vaultwarden-cron/` for cron output

### Operational Excellence
1. **Install cron** — `sudo ./cron-setup.sh --install` for hands-off operation
2. **Monitor regularly** — `make health` or rely on the every-30-min cron check
3. **Test backups** — periodically run `./restore.sh` to verify recoverability
4. **Re-run `--install` after updates** — keeps `/opt/` scripts in sync with the git repo
