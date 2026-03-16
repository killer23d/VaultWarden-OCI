# VaultWarden-OCI Library API Reference

> **Audience:** System administrators maintaining or extending this project.  
> **Last updated:** 2026-03-16  
> This document describes every public function exported by the `lib/` shell
> libraries. It reflects the current patched state of the codebase. Internal
> helpers (prefixed `_`) are documented where their behaviour is security-
> relevant.

---

## Table of Contents

1. [Library Load Order](#library-load-order)
2. [lib/secrets.sh](#libsecretssh)
3. [lib/backup_utils.sh](#libbackup_utilssh)
4. [lib/crypto.sh](#libcryptosh)
5. [lib/simple_key_resilience.sh](#libsimple_key_resiliencesh)
6. [lib/common.sh](#libcommonsh)
7. [lib/docker.sh](#libdockersh)
8. [lib/email.sh](#libemailsh)
9. [lib/security.sh](#libsecuritysh)
10. [Security Invariants](#security-invariants)
11. [Known Patch History](#known-patch-history)

---

## Library Load Order

Libraries have the following dependency chain. Always source in this order:

```
lib/common.sh        ← no dependencies
lib/crypto.sh        ← requires common.sh
lib/secrets.sh       ← requires crypto.sh
lib/backup_utils.sh  ← requires crypto.sh
lib/simple_key_resilience.sh ← requires crypto.sh
lib/docker.sh        ← requires common.sh
lib/email.sh         ← requires common.sh
lib/security.sh      ← requires common.sh
```

Each library is guard-loaded (idempotent `[[ -n "${LIB_LOADED:-}" ]]` check at
the top), so sourcing a library twice is safe.

---

## lib/secrets.sh

Manages SOPS-encrypted secrets, Cloudflare token validation, interactive
collection, and the plaintext recovery kit export workflow.

### `ensure_sops_env [AGE_KEY_PATH]`

Sets `SOPS_AGE_KEY_FILE` and `SOPS_CONFIG` in the calling process environment.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `AGE_KEY_PATH` | `$AGE_KEY_FILE` (`secrets/keys/age-key.txt`) | Absolute or relative path to the Age private key |

Returns `0` on success, `1` if the key file does not exist.

> **Note:** `setup_secrets_environment()` is an alias for this function.

---

### `cleanup_secrets_environment`

**Patch LS-2 (CRITICAL):** Previously a deliberate no-op. Now performs real
cleanup by unsetting `SOPS_AGE_KEY_FILE` and `SOPS_CONFIG` from the process
environment so child processes (Docker, rclone, curl) do not inherit the Age
key file path.

Call this at the end of any script that calls `ensure_sops_env`.

```bash
ensure_sops_env
# ... do secret operations ...
cleanup_secrets_environment
```

---

### `write_secret_file DEST VALUE`

**Patch BUG-S7 (HIGH):** Writes `VALUE` to `DEST` with `umask 077` active so
the file is created at mode `600` atomically. A subsequent `chmod 600` is
retained as belt-and-suspenders.

| Parameter | Description |
|-----------|-------------|
| `DEST` | Destination file path |
| `VALUE` | Secret string to write |

Returns `1` if the write fails.

---

### `generate_admin_token [LENGTH]`

**Patch BUG-S9 (MEDIUM):** Generates a random alphanumeric admin token using
`openssl rand`. Runs in a subshell with `pipefail` so `openssl` failures
propagate correctly (the original pipeline masked them). Also enforces a
minimum token length of 32 characters.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `LENGTH` | `48` | Token length |

Prints the token on stdout. Returns `1` on failure.

---

### `decrypt_secret KEY [SECRETS_FILE]`

**Patch BUG-S10 (MEDIUM):** Decrypts a single named key from the SOPS secrets
file using `sops -d --extract`. Immediately unsets `SOPS_AGE_KEY_FILE` after
the call so child processes do not inherit it.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `KEY` | — | YAML key name to decrypt |
| `SECRETS_FILE` | `$SECRETS_FILE` | Path to `secrets.yaml` |

Prints the plaintext value on stdout. Returns `1` on failure.

> **Security:** Only the value for `KEY` is decrypted. No full-file decryption
> occurs.

---

### `list_secrets [SECRETS_FILE]`

**Patch BUG-S11 (LOW):** Lists top-level key names from the encrypted secrets
file. Uses `python3 / yaml.safe_load()` on the decrypted YAML structure only;
secret values are never passed through the pipeline.

Prints one key name per line on stdout. Returns `1` on decryption failure.

---

### `secrets_file_exists`

Returns `0` if `$SECRETS_FILE` exists, `1` otherwise. No decryption.

---

### `validate_secrets_decryption [SECRETS_FILE]`

Verifies that the secrets file can be decrypted at all (discards output).
Returns `1` if decryption fails.

---

### `validate_secrets_yaml [SECRETS_FILE]`

**Patch LS-3 (HIGH):** Previously piped full plaintext through `python3`.
Now runs `sops -d --output-type json "$secrets_file" > /dev/null` which
validates both decryptability and YAML structure without materialising
plaintext in a kernel pipe buffer.

Returns `1` if validation fails.

---

### `validate_required_secrets [SECRETS_FILE]`

Verifies that these four required keys exist and are decryptable:
`admin_token`, `admin_basic_auth_hash`, `caddy_cloudflare_dns_token`,
`fail2ban_cloudflare_firewall_token`.

Returns `1` with a `log_warn` listing any missing keys.

---

### `check_placeholder_values [SECRETS_FILE]`

Checks that none of the four required secrets still hold `CHANGE_ME` or
`PLACEHOLDER_NOT_CONFIGURED` values. Returns `1` if placeholders are found.

---

### `list_secret_keys [SECRETS_FILE]`

Functionally equivalent to `list_secrets`. Uses a more compact python3
one-liner. Prefer `list_secrets` in new code.

---

### `create_secrets_backup [SECRETS_FILE [BACKUP_DIR]]`

**Patch LS-4 (HIGH):** Creates a timestamped backup of the SOPS-encrypted
secrets file. The destination is atomically pre-created at mode `600` via
`install -m 600 /dev/null` before `cp` writes any data, so the backup is
never world-readable even for an instant.

File is named `secrets.yaml.backup-YYYYMMDD-HHMMSS`.

---

### `cleanup_old_secret_backups [BACKUP_DIR [KEEP_COUNT]]`

**Patch LS-5 (MEDIUM):** Removes old secret backups, keeping the most recent
`KEEP_COUNT`. Uses a fully NUL-delimited pipeline (`find -print0 | sort -rz |
tail -z | xargs -0 rm -f`) so paths with spaces are handled correctly.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `BACKUP_DIR` | `$SECRETS_BACKUP_DIR` | Directory containing backups |
| `KEEP_COUNT` | `5` | Number of most-recent backups to retain |

---

### `validate_cloudflare_token TOKEN TYPE [ZONE_ID]`

**Patch BUG-S2 + BUG-S8 (MEDIUM/HIGH):** Validates a Cloudflare API token
against a live API endpoint.

| `TYPE` value | Endpoint tested |
|-------------|-----------------|
| `dns` | `zones/{id}/dns_records` |
| `firewall` | `zones/{id}/rulesets` (WAF Custom Rules — **not** the deprecated Firewall Access Rules endpoint) |

**BUG-S2 fix:** The curl config file is atomically created at mode `600` via
`install -m 600 /dev/null` before the token is written, eliminating the
TOCTOU race in the previous `mktemp` + `chmod` sequence.

**BUG-S8 fix:** Returns `1` (not `0`) with `log_warn` when `CLOUDFLARE_ZONE_ID`
is absent or a placeholder. Callers can now reliably distinguish "skipped" from
"validated OK".

---

### `collect_secret_field FIELD`

Interactive collection for all eight secret fields. Prompts the operator,
performs hashing where required, and returns the value to be stored.

| `FIELD` value | Collection method |
|--------------|-------------------|
| `admin_token` | Interactive password → Argon2id hash |
| `admin_basic_auth_hash` | Interactive password → bcrypt hash (`admin $2y$...`) |
| `caddy_cloudflare_dns_token` | Read from TTY, optionally validated |
| `fail2ban_cloudflare_firewall_token` | Read from TTY, optionally validated |
| `smtp_password` | Silent read from TTY |
| `push_installation_id` | Read from TTY |
| `push_installation_key` | Read from TTY |
| `backup_passphrase` | Auto-generated 32-char random string, printed to `/dev/tty` only |

**Patch BUG-S6 (MEDIUM):** All plaintext passwords are written to `/dev/tty`
exclusively, never to `stderr`. This prevents them from appearing in the
systemd journal when the script runs non-interactively.

---

### `auto_generate_secret_field FIELD`

Non-interactive counterpart to `collect_secret_field`. Generates values for
all eight fields without operator input. Cloudflare tokens and SMTP password
receive `CHANGE_ME_*` placeholders — these **must** be replaced before
deployment.

Auto-generated admin passwords are written to `/dev/tty` only (same BUG-S6
fix). If `/dev/tty` is unavailable (CI/batch), a redacted notice goes to
`stderr`.

---

### `generate_recovery_kit OUTPUT_FILE`

**Patch LS-1 (CRITICAL):** Writes a complete, formatted plaintext recovery
document to `OUTPUT_FILE`. 

Each of the eight secrets is extracted individually via
`sops -d --extract '["key"]'`. The full plaintext JSON is **never**
materialised in a variable or pipe, preventing exposure in `/proc/$$/fd/`
pipe buffers.

`OUTPUT_FILE` is atomically created at mode `600` via `install -m 600 /dev/null`.

> **Contract:** The caller is responsible for securely deleting `OUTPUT_FILE`
> after use. Use `offer_recovery_kit_export()` which handles this automatically.

The generated document includes:
- Age private + public key
- All eight decrypted secret values
- Disaster recovery checklist with repo clone URL (derived from `git remote`,
  or `$RECOVERY_KIT_REPO_URL` env var, never hardcoded)

---

### `offer_recovery_kit_export [AUTO_EXPORT]`

**Patch BUG-S5 (CRITICAL) + LS-6 (MEDIUM):**

Wrapper around `generate_recovery_kit` that:
1. Resolves a tmpfs directory via `_tmpfs_dir()` (prefers `/dev/shm`, then
   `/run/user/UID`, then `/tmp` with a warning) so plaintext never touches
   persistent block storage where possible.
2. Prints a `SECURITY NOTICE` banner to `/dev/tty` **before** the file is
   opened.
3. Waits up to 120 seconds for the operator to acknowledge before securely
   shredding the file via `_secure_shred()`.
4. Uses `trap ... RETURN` (not `trap ... EXIT`) to prevent overwriting any
   caller-level EXIT trap. *(LS-6 fix)*

| Parameter | Default | Description |
|-----------|---------|-------------|
| `AUTO_EXPORT` | `false` | Set to `true` to skip the interactive yes/no prompt |

---

### Internal helpers (security-relevant)

| Function | Description |
|----------|-------------|
| `_secure_shred FILE` | Overwrites and removes a file with `shred -fuz` or a `dd /dev/urandom` fallback. Portable: uses `stat -c%s` (GNU) or `stat -f%z` (BSD). *(BUG-S1 fix)* |
| `_tmpfs_dir` | Returns a writable tmpfs path in priority order: `/dev/shm` → `/run/user/UID` → `/tmp`. Emits a TTY warning if falling back to `/tmp`. *(BUG-S5 fix)* |
| `_ork_generate_and_secure OUTPUT_FILE` | Top-level (non-nested) implementation of the recovery kit write + shred cycle. Uses `trap ... RETURN`. *(BUG-S3, LS-6 fix)* |
| `_bcrypt_format_ok HASH` | Returns `0` if `HASH` matches `$2[aby]$NN$<53 chars>`. Used to validate htpasswd-generated hashes before storing. |

---

## lib/backup_utils.sh

Provides backup listing, validation, retention cleanup, disk space checks,
metadata creation, and database integrity verification.

### `list_backups [BACKUP_BASE_DIR]`

Lists all `.age` backup files found under `BACKUP_BASE_DIR/{db,full,emergency}`
subdirectories. Displays filename, human-readable size, and modification time.

Uses `stat -c '%y'` (GNU) or `stat -f '%Sm'` (BSD) for modification time —
never `date -r` which is macOS-only. *(FIX ISSUE-13)*

If a `.meta` sidecar exists, also prints the `vaultwarden_version` field.

Returns `1` if no backups are found.

---

### `validate_backup_integrity BACKUP_FILE [AGE_KEY_FILE]`

Validates a `.age` backup file by:
1. Checking file size is > 1 KiB (basic corruption detection).
2. Verifying SHA-256 checksum against the companion `.sha256` sidecar if present.
3. Running a decryption test: `age -d -i KEY BACKUP > /dev/null`.

> **Note:** Decryption uses direct redirect to `/dev/null`, not a pipeline,
> so `age`'s exit code is captured directly without `PIPESTATUS` complications.
> *(FIX ISSUE-7)*

Returns `1` on any failure.

---

### `verify_backup_integrity DB_PATH [AGE_KEY_FILE]`

**Patch LB-1 (CRITICAL):** Performs a SQLite `PRAGMA integrity_check` on the
live VaultWarden database.

**Previous behaviour (incorrect):** Three sequential `cp` calls on `.db`,
`-wal`, and `-shm` files. A VaultWarden write between the first and second `cp`
produced an inconsistent snapshot; `integrity_check` could return a false `ok`.

**Current behaviour:** Uses `sqlite3 "$db_path" ".backup '$db_copy'"` (SQLite
Online Backup API) which holds a shared read lock for the full duration of the
copy, integrating all pending WAL frames. The WAL and SHM sidecars are **not**
manually copied — the Online Backup API handles WAL integration internally.

The copy is placed in a `mktemp -d` directory with mode `700`, cleaned up via
a `trap ... RETURN`.

Returns `1` if `sqlite3` is unavailable, if the backup fails, or if
`integrity_check` does not return exactly `ok`.

---

### `get_backup_size BACKUP_FILE`

**Patch AUD-B2 (MEDIUM):** Returns the file size in raw bytes as a plain
integer on stdout. Uses `stat -c%s` (GNU) or `stat -f%z` (BSD).

Previous implementation used `du -sh` which returned a human-readable string
unsuitable for arithmetic.

---

### `check_backup_disk_space TARGET_DIR [REQUIRED_SPACE_MB]`

**Patch BUG-B1 (HIGH):** Checks that `TARGET_DIR` has at least
`REQUIRED_SPACE_MB` of free space. Uses portable `awk 'END {print $4}'` on
`df` output (column 4 = available 1 KiB blocks on both GNU and BSD `df`).
Previous implementation used `df --output=avail` which is GNU-only.

Uses `awk 'END'` (last line) rather than `NR==2` to handle long filesystem
paths that wrap `df` output across two lines. *(FIX L-11)*

| Parameter | Default | Description |
|-----------|---------|-------------|
| `REQUIRED_SPACE_MB` | `1000` (1 GB) | Minimum required free space in MB |

---

### `cleanup_old_backups BACKUP_DIR BACKUP_TYPE RETENTION_DAYS`

**Patches BUG-B4, P2-M3, AUD-B3, LB-2.**

Removes `.age` files (and their `.sha256`/`.meta` sidecars) older than
`RETENTION_DAYS`.

**Age calculation (LB-2 fix):** Uses `_backup_filename_age_days()` as the
primary age source, parsing the immutable `YYYYMMDD-HHMMSS` timestamp embedded
in the filename. Falls back to `_backup_ctime_age_days()` only for files whose
names contain no such timestamp (i.e., files predating the naming convention).

> **Why this matters:** `ctime` is reset by `cp`, `mv` across filesystems,
> `chmod`, and `chown`. Backups restored to a fresh OCI host would show
> `ctime = now`, appear 0 days old, and be permanently exempt from cleanup.
> The filename timestamp is unaffected by any of these operations.

**Orphan sidecar sweep (P2-M3 fix):** After the age-based pass, a second sweep
removes any `.meta` or `.sha256` file whose corresponding `.age` primary no
longer exists. This prevents indefinite accumulation from partial prior runs or
manual deletions.

---

### `get_backup_statistics [BACKUP_BASE_DIR]`

Prints a formatted table of backup counts and total sizes (in MB) for each
of `db`, `full`, and `emergency` backup types, plus a grand total.

Uses `_stat_file_size()` from `lib/crypto.sh` for portable per-file size
accumulation. *(BUG-B2 fix: previous `find -exec stat -c%s {} +` was
GNU-only)*

---

### `create_backup_metadata BACKUP_FILE BACKUP_TYPE [ADDITIONAL_INFO]`

Creates a `.meta` sidecar file adjacent to `BACKUP_FILE` containing:

```ini
backup_type=<type>
timestamp=<ISO-8601>
hostname=<fqdn>
file_size=<bytes>
sha256=<hex>
vaultwarden_version=<version>
creator=VaultWarden-OCI-NG
```

`file_size` uses `_stat_file_size()` for portability. *(BUG-B3 fix)*

The heredoc is guarded with `if ! cat > file <<EOF` rather than checking `$?`
after the fact. *(BUG-B5 fix)*

---

### Internal helpers

| Function | Description |
|----------|-------------|
| `_backup_filename_age_days FILE` | Parses `YYYYMMDD-HHMMSS` from the filename and returns age in whole days. Returns empty string if no timestamp found. *(LB-2 fix)* |
| `_backup_ctime_age_days FILE` | Returns age in whole days based on inode `ctime`. Fallback only. |

---

## lib/crypto.sh

Cryptographic utilities: Argon2id hashing, bcrypt hashing, Age key derivation,
SHA-256 calculation, and portable `stat` wrappers.

### Key functions (summary)

| Function | Description |
|----------|-------------|
| `generate_argon2_hash PASSWORD` | Generates an Argon2id hash suitable for VaultWarden's `ADMIN_TOKEN` env var |
| `generate_bcrypt_hash PASSWORD [COST]` | Generates an `htpasswd`-compatible bcrypt hash. **Patch LC-1:** validates cost factor is in range `[10–31]` locally before calling `htpasswd`. Default cost: `12`. |
| `check_age_key [KEY_FILE]` | Performs a round-trip encrypt/decrypt test on the Age key. **Patch LC-2:** returns `1` (fail-closed) if `mktemp` fails, rather than silently returning `0`. |
| `encrypt_sops_file FILE` | Encrypts a file in-place with SOPS. **Patch LC-3:** `chmod 600` is applied to the temp file immediately after `mktemp`, before SOPS writes any ciphertext. |
| `_derive_age_public_key KEY_FILE` | Extracts the Age public key from a private key file via `age-keygen -y`. |
| `_stat_file_size FILE` | Portable file size: `stat -c%s` (GNU) or `stat -f%z` (BSD). |
| `_stat_octal_perms_local FILE` | Portable octal permissions: `stat -c '%a'` (GNU) or `stat -f '%OLp'` (BSD). |
| `calculate_sha256 FILE` | Returns the hex SHA-256 of `FILE`. Uses `sha256sum` (Linux) or `shasum -a 256` (macOS). |
| `verify_sha256 FILE EXPECTED_HEX` | Verifies `FILE` matches `EXPECTED_HEX`. Returns `1` on mismatch. |
| `generate_secure_string [LENGTH]` | Generates a random alphanumeric string of `LENGTH` chars (default: 32) using `openssl rand`. |

> **bcrypt cost validation detail (LC-1):** `generate_bcrypt_hash` checks that
> the caller-supplied `rounds` value satisfies `10 ≤ rounds ≤ 31` before
> invoking `htpasswd`. This prevents a misconfigured `.env` (e.g., `BCRYPT_ROUNDS=6`)
> from silently producing cryptographically weak Caddy admin credentials.

---

## lib/simple_key_resilience.sh

Three-tier Age key protection: health checks, password manager escrow, and
paper (printable) backup.

### `simple_verify_age_key`

Verifies the Age key at `$SOPS_AGE_KEY_FILE` is present, has mode `600` with
correct ownership, and passes a functional encrypt/decrypt roundtrip.

**Patch SK-1 (MEDIUM):** The roundtrip now uses `printf '%s'` instead of
`echo` to pipe test data into `age`, ensuring no trailing newline is appended.
The previous `echo`-based test worked only due to `$()` stripping trailing
newlines — a fragile coincidence.

**Patch SKR-M1 (MEDIUM):** Permissions and ownership corrections are logged at
`log_warn` level before the fix is applied, making silent privilege escalations
visible in audit logs.

**Patch BUG-R1 (HIGH):** Uses `_stat_octal_perms_local()` from `crypto.sh`
(portable to BSD/macOS) instead of `stat -c '%a'` (GNU-only).

---

### `create_password_manager_escrow AGE_KEY OUTPUT_FILE`

Creates a formatted plaintext text file at `OUTPUT_FILE` containing the Age
private key, public key, hostname, date, and recovery instructions — suitable
for pasting into a password manager Secure Note.

`OUTPUT_FILE` is atomically created at mode `600` via `install -m 600 /dev/null`.

**Patch SKR-L1 (MEDIUM):** Uses `trap ... RETURN` (not `trap ... EXIT`) for
cleanup so the caller's EXIT trap is not overwritten. On success, the RETURN
trap is cleared (the file is kept for the caller); on error, `_secure_remove_file`
is called.

After success, the admin is warned to delete the file after saving:
```bash
_secure_remove_file '<output_file>'
```

---

### `verify_key_replica [PRIMARY_KEY] [REPLICA_KEY...]`

**Patch SKR-M3 (MEDIUM) + SKR-L2 (LOW):**

Verifies one or more replica keys against the primary.

**Two-step verification per replica:**
1. SHA-256 hash comparison (byte-level).
2. Functional `age` encrypt/decrypt roundtrip — detects corruption that is
   byte-identical to a corrupt primary (i.e., corruption that would pass a
   hash check alone).

The **primary key itself** is also verified with a functional roundtrip before
being used as the comparison reference.

**SKR-L2 fix:** Returns `1` with `log_warn` if the replica list is empty,
rather than silently reporting success with no verification performed.

---

### `restore_key_from_replica REPLICA_KEY [PRIMARY_KEY]`

**Patch SKR-M4 (MEDIUM):** Restores the primary Age key from a replica.

Previous behaviour: `cp replica primary` directly — a crash mid-copy produced
a partial/truncated primary key.

Current behaviour: copies to `<primary>.tmp.$$` first, then atomically renames
into place with `mv`. The primary is never replaced unless the full copy
succeeds on disk.

---

### `create_printable_key_backup [OUTPUT_PDF]`

**Patches BUG-R2, BUG-R3, SKR-H1, SKR-M2.**

Creates a printable HTML/PDF backup of the Age key with an optional QR code.

| Patch | Issue | Fix |
|-------|-------|-----|
| BUG-R2 | `trap` used single quotes; `$temp_html` not expanded at registration | Changed to double-quote wrapper so path expands at registration time |
| BUG-R3 | `qrencode` received raw Age key as CLI argument (visible in `ps aux`) | Key fed via stdin: `printf '%s' "$key" \| qrencode --read-from=-` |
| SKR-H1 | `key_content` held plaintext key in process env after heredoc write | `unset key_content` immediately after heredoc; HTML-escaped before embedding |
| SKR-M2 | HTML fallback left plaintext key file on disk indefinitely | Self-delete reminder embedded in HTML; `at(1)` job (or background `sleep` fallback) scheduled 30 minutes after creation |

If `wkhtmltopdf` is installed, produces a PDF. Otherwise creates an `.html`
file with a visible deletion reminder banner and a 30-minute auto-remind job.

---

### Internal helpers

| Function | Description |
|----------|-------------|
| `_secure_remove_file FILE` | Like `_secure_shred` in `secrets.sh` — overwrites with `shred -fuz -n 3` or `dd /dev/urandom`, then `rm`. Portable file size via `_stat_file_size()`. *(BUG-R4 fix)* |
| `_html_escape STRING` | Replaces `& < > " '` with HTML entities. Applied to key content before embedding in HTML template. *(SKR-H1 helper)* |

---

## lib/common.sh

General-purpose utilities used by all other libraries and scripts.

### Key functions (summary)

| Function | Description |
|----------|-------------|
| `log_info MSG` | Prints `[INFO] MSG` to stderr with timestamp |
| `log_warn MSG` | Prints `[WARN] MSG` to stderr with timestamp |
| `log_error MSG` | Prints `[ERROR] MSG` to stderr with timestamp |
| `log_success MSG` | Prints `[OK] MSG` to stderr with timestamp |
| `log_debug MSG` | Prints `[DEBUG] MSG` to stderr (only when `DEBUG=true`) |
| `get_real_user` | Returns the real (non-root) username when running under `sudo`. Falls back to `$USER`. |
| `get_config_value KEY DEFAULT` | Reads a key=value pair from `.env`. Returns `DEFAULT` if not set. |
| `require_root` | Exits `1` with error if not running as root. |
| `require_command CMD` | Exits `1` with error if `CMD` is not in `PATH`. |

---

## lib/docker.sh

Docker and Docker Compose helpers.

### Key functions (summary)

| Function | Description |
|----------|-------------|
| `require_docker` | Verifies Docker daemon is running. Returns `1` if not. |
| `is_service_running SERVICE` | Returns `0` if the named Docker Compose service is running. |
| `get_container_id SERVICE` | Returns the container ID for a running service. |
| `safe_docker_exec SERVICE CMD...` | Runs `docker compose exec` with a timeout and error capture. |

---

## lib/email.sh

Email notification helpers for backup and health alert events.

### Key functions (summary)

| Function | Description |
|----------|-------------|
| `send_email SUBJECT BODY` | Sends an email via SMTP using credentials from `.env` (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_FROM`, `SMTP_TO`). |
| `send_backup_notification TYPE STATUS DETAILS` | Sends a formatted backup result notification. |
| `send_health_alert COMPONENT STATUS DETAILS` | Sends a health-check failure alert. |

---

## lib/security.sh

UFW firewall management and permission helpers.

### Key functions (summary)

| Function | Description |
|----------|-------------|
| `setup_ufw_rules` | Opens ports `80/tcp` and `443/tcp`. See [SS-3 note](#security-invariants) about Cloudflare CIDR restriction. |
| `set_file_permissions PATH MODE` | Sets mode on path with `chmod`. |
| `set_directory_permissions DIR MODE` | Sets mode on directory recursively. |
| `check_secrets_permissions` | Verifies `secrets/` directory and key files have correct restrictive permissions. |

---

## Security Invariants

The following invariants must hold at all times on a production deployment.
These are enforced by the library functions but administrators should verify
them periodically with `./health.sh`.

| Invariant | How enforced |
|-----------|-------------|
| `secrets/keys/age-key.txt` mode is `600` | `simple_verify_age_key()` auto-corrects and logs any deviation |
| `secrets/secrets.yaml` mode is `600` | `secure_secrets_file()` in `secrets.sh`; `check_secrets_permissions()` in `security.sh` |
| SOPS env vars unset after secrets operations | `cleanup_secrets_environment()` — must be called by any script that calls `ensure_sops_env()` |
| Plaintext secrets never written to `/home` or project root | `_tmpfs_dir()` resolves to `/dev/shm` or `/run/user/UID` first |
| Plaintext passwords never appear in systemd journal | All password output routed to `/dev/tty` only (BUG-S6 fix) |
| bcrypt cost factor ≥ 10 | `generate_bcrypt_hash()` validates before calling `htpasswd` (LC-1 fix); `caddy/entrypoint.sh` validates stored hash (CE-1 fix) |
| Cloudflare firewall token validated against WAF Rulesets API | `validate_cloudflare_token()` uses `/zones/{id}/rulesets` for `firewall` type — not the deprecated Firewall Access Rules endpoint |

---

## Known Patch History

| ID | Severity | File | Summary |
|----|----------|------|---------|
| LS-1 | Critical | `secrets.sh` | `generate_recovery_kit`: per-key SOPS extract; no full JSON variable |
| LS-2 | Critical | `secrets.sh` | `cleanup_secrets_environment`: real unset, not no-op |
| LS-3 | High | `secrets.sh` | `validate_secrets_yaml`: discard output, no plaintext pipeline |
| LS-4 | High | `secrets.sh` | `create_secrets_backup`: `install -m 600` before `cp` |
| LS-5 | Medium | `secrets.sh` | `cleanup_old_secret_backups`: NUL-delimited pipeline |
| LS-6 | Medium | `secrets.sh` | `_ork_generate_and_secure`: `trap ... RETURN` not EXIT |
| LB-1 | Critical | `backup_utils.sh` | `verify_backup_integrity`: SQLite Online Backup API |
| LB-2 | High | `backup_utils.sh` | Retention: filename timestamp primary, ctime fallback |
| LC-1 | High | `crypto.sh` | `generate_bcrypt_hash`: validate cost factor `[10–31]` |
| LC-2 | Medium | `crypto.sh` | `check_age_key`: fail-closed on `mktemp` failure |
| LC-3 | Medium | `crypto.sh` | `encrypt_sops_file`: `chmod 600` temp file before SOPS write |
| SK-1 | Medium | `simple_key_resilience.sh` | `simple_verify_age_key`: `printf '%s'` not `echo` |
| BUG-S1–S11 | Various | `secrets.sh` | See inline comments in source |
| BUG-B1–B5 | Various | `backup_utils.sh` | See inline comments in source |
| BUG-R1–R4 | Various | `simple_key_resilience.sh` | See inline comments in source |
| SKR-H1,M1–M4,L1–L2 | Various | `simple_key_resilience.sh` | See inline comments in source |
