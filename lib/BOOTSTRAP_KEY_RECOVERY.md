# VaultWarden-OCI: Age Key Bootstrap & Recovery Guide

> **Audience:** System administrators performing initial setup or recovering
> from key loss.  
> **Last updated:** 2026-03-16  
> The Age private key at `secrets/keys/age-key.txt` is the single master
> credential that encrypts every backup and every SOPS-managed secret. This
> guide covers generating it, protecting it, verifying it, and recovering from
> all failure scenarios.

---

## Table of Contents

1. [What the Age Key Protects](#what-the-age-key-protects)
2. [Key Generation (Bootstrap)](#key-generation-bootstrap)
3. [Key Health Verification](#key-health-verification)
4. [Three-Tier Protection Strategy](#three-tier-protection-strategy)
5. [Tier 1: Password Manager Escrow](#tier-1-password-manager-escrow)
6. [Tier 2: Printable Key Backup](#tier-2-printable-key-backup)
7. [Tier 3: Key Replicas and Verification](#tier-3-key-replicas-and-verification)
8. [Recovery Kit Export](#recovery-kit-export)
9. [Recovery Scenarios](#recovery-scenarios)
10. [Rotating the Age Key](#rotating-the-age-key)
11. [Security Invariants](#security-invariants)
12. [Known Issues Fixed](#known-issues-fixed)

---

## What the Age Key Protects

| Protected asset | How |
|----------------|-----|
| All `.age` backup files | Encrypted with the Age public key at backup time |
| `secrets/secrets.yaml` | SOPS uses the Age key as the data encryption key (DEK) wrapper |
| Recovery kit export | The recovery kit itself contains the Age private key |

**Without the Age private key:**
- All backups are permanently unreadable.
- `secrets.yaml` cannot be decrypted (VaultWarden will not start).
- There is no master password reset path — the data is gone.

---

## Key Generation (Bootstrap)

The Age key is generated automatically during `./setup.sh`. If you need to
generate or regenerate it manually:

```bash
# Create the key directory
mkdir -p secrets/keys

# Generate a new Age key pair
age-keygen -o secrets/keys/age-key.txt

# Lock permissions
chmod 600 secrets/keys/age-key.txt
```

`age-keygen` writes both the private key and a comment line containing the
public key to the output file:

```
# created: 2026-03-16T04:00:00Z
# public key: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
AGE-SECRET-KEY-1XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
```

> **After generating a new key:** You must re-encrypt `secrets/secrets.yaml`
> and all existing backups with the new public key, or restore from a backup
> taken before the key was rotated. See [Rotating the Age Key](#rotating-the-age-key).

---

## Key Health Verification

The `simple_verify_age_key()` function in `lib/simple_key_resilience.sh`
performs a comprehensive health check on the Age key file.

```bash
# Run the health check (called automatically by health.sh)
./health.sh --check-keys
```

### What is checked

1. **File existence:** `secrets/keys/age-key.txt` must be present.
2. **Permissions:** Must be exactly mode `600`. If wrong, auto-corrected with
   a `log_warn` audit entry before the fix is applied. *(Patch SKR-M1)*
3. **Ownership:** Must be owned by the real (non-root) operator user. Auto-
   corrected with `log_warn` if wrong. *(Patch SKR-M1)*
4. **Functional roundtrip:** `printf '%s' "$test_data" | age -r <pubkey> | age -d -i <key>` must reproduce the original test string exactly. *(Patch SK-1)*

> **Why `printf '%s'` and not `echo`:** `echo` appends a trailing newline.
> The old roundtrip test only appeared to work because `$()` strips trailing
> newlines — a fragile coincidence. `printf '%s'` emits exactly the bytes in
> `$test_data` with no newline, making the comparison deterministic and safe.
> *(Patch SK-1 fix)*

### Auto-fix behaviour

If permissions or ownership are wrong, `simple_verify_age_key()` corrects
them automatically **but logs at `log_warn` first**. This ensures that any
silent privilege escalation that temporarily widened the key's permissions is
visible in audit logs even after it is corrected.

---

## Three-Tier Protection Strategy

The `lib/simple_key_resilience.sh` library implements three escalating
levels of key protection, intended to be deployed in order:

| Tier | Function | Medium | When to use |
|------|----------|--------|-------------|
| 1 | `create_password_manager_escrow` | Digital secure note | Always — primary recovery path |
| 2 | `create_printable_key_backup` | Printed PDF or HTML | Recommended — offline backup |
| 3 | `verify_key_replica` + `restore_key_from_replica` | Filesystem replicas | Optional — high-availability setups |

---

## Tier 1: Password Manager Escrow

Creates a formatted plaintext text file containing the Age private key, public
key, hostname, date, and recovery instructions — suitable for pasting into a
password manager Secure Note (1Password, Bitwarden, etc.).

```bash
# Create the escrow file
create_password_manager_escrow "$SOPS_AGE_KEY_FILE" /tmp/age-key-escrow.txt

# The output file is created at mode 600.
# Copy its contents to your password manager, then securely delete:
shred -fuz /tmp/age-key-escrow.txt
# Or use the library helper:
_secure_remove_file /tmp/age-key-escrow.txt
```

### What the escrow file contains

```
═══════════════════════════════════════════════════════════════
VaultWarden Age Key Backup - <date>
═══════════════════════════════════════════════════════════════

🔐 CRITICAL: Store this entire file in your password manager
   as a secure note.

📝 Recovery Instructions:
   1. Save the key content below to: secrets/keys/age-key.txt
   2. Run: chmod 600 secrets/keys/age-key.txt
   3. Decrypt backups: age -d -i secrets/keys/age-key.txt backup.age

AGE PRIVATE KEY (copy everything below this line):
───────────────────────────────────────────────────────────────
# created: ...
# public key: age1...
AGE-SECRET-KEY-1...
───────────────────────────────────────────────────────────────
Public Key: age1...
Created: <date>
Hostname: <hostname>
```

### Security properties

- Output file atomically created at mode `600` via `install -m 600 /dev/null`.
- Uses `trap ... RETURN` so this function’s cleanup does not overwrite
  any caller-level `EXIT` trap. *(Patch SKR-L1)*
- On success, the RETURN trap is cleared — the file is kept for the caller.
- On failure, `_secure_remove_file` is called automatically.

---

## Tier 2: Printable Key Backup

Creates an HTML or PDF document containing the Age key in text and optionally
as a QR code, suitable for printing and storing in a fireproof safe.

```bash
# Requires: wkhtmltopdf (for PDF) or any browser (for HTML)
# Optional: qrencode (for QR code generation)

create_printable_key_backup ~/vaultwarden-key-backup.pdf
```

If `wkhtmltopdf` is not installed, an `.html` file is created instead. A
self-delete reminder banner is embedded in the HTML, and a 30-minute reminder
schedule is set via `at(1)` (or a background `sleep` subshell if `at` is not
available). *(Patch SKR-M2)*

### QR code security

**Patch BUG-R3:** The Age private key is piped to `qrencode` via stdin
(`qrencode --read-from=`), never passed as a command-line argument. Passing
sensitive data as CLI arguments makes it visible in `ps aux`,
`/proc/<pid>/cmdline`, and shell history.

### HTML cleanup

```bash
# After printing, securely delete the HTML file:
shred -fuz ~/vaultwarden-key-backup.html
```

> **Note on OCI block volume snapshots:** If the printable backup is generated
> while an OCI block volume snapshot is running, the snapshot may capture the
> plaintext file. Disable automated snapshots during key backup operations or
> use `create_password_manager_escrow` instead (which uses memory, not disk,
> for the final product).

---

## Tier 3: Key Replicas and Verification

For high-availability setups, maintain one or more replica copies of the Age
private key (e.g., on a separate attached volume, an NFS share, or another
host).

### Verifying replicas

```bash
verify_key_replica \
    secrets/keys/age-key.txt \
    /mnt/backup-volume/age-key-replica.txt \
    /mnt/offsite/age-key-replica2.txt
```

**Two-step verification per replica (Patch SKR-M3):**
1. SHA-256 hash comparison (byte-level).
2. Functional `age` encrypt/decrypt roundtrip against the replica key.

Step 2 is critical: if the primary key itself is corrupt, all replicas may
match its corrupt hash. The functional roundtrip detects corruption that
is byte-identical to a corrupt reference.

**The primary key is also verified** with a functional roundtrip before being
used as the comparison reference.

**Empty replica list behaviour (Patch SKR-L2):** If no replicas are provided,
the function returns `1` with `log_warn` rather than silently returning
success. This prevents a misconfigured replica list from hiding the absence
of any actual verification.

### Restoring from a replica

```bash
restore_key_from_replica \
    /mnt/backup-volume/age-key-replica.txt \
    secrets/keys/age-key.txt
```

**Atomic restore (Patch SKR-M4):** The restore writes to a `.tmp.$$` sidecar
first, then atomically renames into place with `mv`. A crash or signal during
the copy leaves the existing primary intact (or absent) — never a partial
file.

---

## Recovery Kit Export

The recovery kit is a single formatted plaintext document containing:
- The Age private + public key.
- All eight decrypted secret values.
- A complete disaster recovery checklist.

It is intended to be saved to a password manager Secure Note or printed and
stored in a fireproof safe immediately after setup.

```bash
# Interactive export (prompts yes/no, then 120-second countdown to shred)
./setup-secrets.sh --export-recovery-kit

# Or call directly from a script:
offer_recovery_kit_export true   # true = skip yes/no prompt
```

### Where the file is written

**Patch BUG-S5 (CRITICAL):** The recovery kit is written to a tmpfs directory,
not `$HOME`. Priority order:

1. `/dev/shm` — POSIX shared memory, backed by RAM (Linux)
2. `/run/user/<UID>` — systemd user runtime dir, backed by RAM (Linux)
3. `/tmp` — last resort; may or may not be tmpfs; a warning is printed to
   `/dev/tty`

This minimises the window during which the plaintext recovery kit exists on
persistent block storage, reducing the risk from OCI block volume snapshots.

### The 120-second window

After the recovery kit is created, you have **120 seconds** to read and save
it before it is automatically shredded:

```
════════════════════════════════════════════════════════════
 SECURITY NOTICE -- PLAINTEXT FILE ABOUT TO BE WRITTEN
════════════════════════════════════════════════════════════
The recovery kit will be written to:
  /dev/shm/vaultwarden-recovery-kit-20260316040012.txt
...
════════════════════════════════════════════════════════════

 1. Open the file: cat '/dev/shm/vaultwarden-recovery-kit-...txt'
 2. Copy ALL contents to your password manager (Secure Note).
 3. Optionally print a physical copy for your fireproof safe.

This file will be securely deleted after you press Enter.
If you do not respond within 120 seconds it will be deleted automatically.

Press Enter once you have saved the recovery kit:
```

### Shred behaviour

The file is deleted with `shred -fuz` if available, or overwritten with
`dd if=/dev/urandom` + `rm` as a fallback. *(Patch BUG-S1: portable
`stat -c%s` / `stat -f%z` used to determine file size for `dd`.)*

### Individual secret extraction (LS-1 fix)

Each of the eight secret values is extracted individually via:
```bash
sops -d --extract '["key"]' secrets/secrets.yaml
```

The full plaintext JSON is **never** materialised in a bash variable or pipe.
The previous implementation decrypted the entire file into `$secrets_json`
and piped it through 8+ separate `echo "$secrets_json" | jq` subshells,
exposing the complete payload in `/proc/$$/fd/` pipe buffers readable by any
same-UID process.

---

## Recovery Scenarios

### Scenario A: Key file has wrong permissions

`simple_verify_age_key()` detects and auto-corrects this, logging a warning.

```bash
# Manual fix:
chmod 600 secrets/keys/age-key.txt
chown $(logname):$(logname) secrets/keys/age-key.txt
```

### Scenario B: Key file deleted or corrupted on primary

```bash
# Step 1: Confirm you have the key content from your password manager escrow.
# Step 2: Recreate the file.
mkdir -p secrets/keys
nano secrets/keys/age-key.txt    # Paste the full key content including # comment lines
chmod 600 secrets/keys/age-key.txt

# Step 3: Verify it works.
simple_verify_age_key

# Step 4: Test decryption of a known-good backup.
age -d -i secrets/keys/age-key.txt backups/db/<latest>.tar.gz.age > /dev/null && echo OK

# Step 5: Re-validate secrets.yaml.
validate_secrets_yaml
```

### Scenario C: Restore from a filesystem replica

```bash
restore_key_from_replica /mnt/backup-volume/age-key-replica.txt
simple_verify_age_key
```

### Scenario D: Key completely lost (all copies destroyed)

> **This scenario results in permanent data loss.** All encrypted backups and
> `secrets.yaml` are permanently unreadable.

Recovery steps:
```bash
# 1. Generate a new Age key
mkdir -p secrets/keys
age-keygen -o secrets/keys/age-key.txt
chmod 600 secrets/keys/age-key.txt

# 2. Re-run secrets setup (all previous secrets must be re-entered)
./setup-secrets.sh

# 3. Restart VaultWarden (it will start with an empty vault)
make down && make up

# 4. If VaultWarden still has a live database (not from backup),
#    re-encrypt it manually with the new key.
#    WARNING: old backups encrypted with the lost key are gone.

# 5. Take a new full backup immediately
./backup.sh --type full

# 6. Export a new recovery kit and save it securely
./setup-secrets.sh --export-recovery-kit
```

### Scenario E: `secrets.yaml` cannot be decrypted

```bash
# Verify the Age key itself is healthy
simple_verify_age_key

# If the key is healthy but sops -d still fails, the .sops.yaml config
# may reference a different public key.
cat .sops.yaml
age-keygen -y secrets/keys/age-key.txt   # Print the public key
# Compare: the public key in .sops.yaml must match.

# If they do not match, the secrets.yaml was encrypted with a different
# Age key. Restore secrets.yaml from a backup:
./restore.sh --type full --file backups/full/<latest>.tar.gz.age
```

---

## Rotating the Age Key

Key rotation replaces the Age key pair and re-encrypts all SOPS-managed
secrets with the new public key. Existing encrypted backups remain readable
only with the **old** key — they are not re-encrypted.

```bash
# Step 1: Back up the current key
create_password_manager_escrow "$SOPS_AGE_KEY_FILE" /tmp/old-key-escrow.txt
# Save /tmp/old-key-escrow.txt to your password manager, then:
shred -fuz /tmp/old-key-escrow.txt

# Step 2: Generate new key
age-keygen -o secrets/keys/age-key.txt
chmod 600 secrets/keys/age-key.txt

# Step 3: Extract new public key
new_pub=$(age-keygen -y secrets/keys/age-key.txt)
echo "New public key: $new_pub"

# Step 4: Update .sops.yaml with new public key
sed -i "s|age1[a-z0-9]*|${new_pub}|", .sops.yaml

# Step 5: Re-encrypt secrets.yaml with new key
#   (This requires the OLD key to be available to decrypt first)
#   If old key is still on disk, sops will use it automatically.
sops rotate -i secrets/secrets.yaml

# Step 6: Verify decryption works with new key
validate_secrets_yaml

# Step 7: Take a full backup (encrypted with new key)
./backup.sh --type full

# Step 8: Save new recovery kit
./setup-secrets.sh --export-recovery-kit

# Step 9: Archive old key (for decrypting old backups) in password manager
```

> **Keep the old key:** Old backups encrypted with the previous key are **not**
> automatically re-encrypted. Archive the old key in your password manager
> under a label like "VaultWarden Age Key (retired YYYY-MM-DD)" so old backups
> remain recoverable.

---

## Security Invariants

| Invariant | Where enforced |
|-----------|----------------|
| Age key mode is `600` | `simple_verify_age_key()` auto-corrects with `log_warn` |
| Age key owned by real operator user (not root) | `simple_verify_age_key()` auto-corrects with `log_warn` |
| Plaintext key never passed as CLI argument | `qrencode --read-from=` stdin *(BUG-R3)* |
| Plaintext key unset from env after use | `unset key_content` after heredoc *(SKR-H1)* |
| Recovery kit written to tmpfs (not home dir) | `_tmpfs_dir()` resolves `/dev/shm` → `/run/user/UID` → `/tmp` *(BUG-S5)* |
| Recovery kit shredded after operator acknowledges | `_ork_generate_and_secure()` with 120-second timeout *(BUG-S5)* |
| Functional roundtrip validates actual key operation | `simple_verify_age_key()`, `verify_key_replica()` |
| Replica restore is atomic (no partial writes) | `restore_key_from_replica()` cp-to-tmp then `mv` *(SKR-M4)* |
| `SOPS_AGE_KEY_FILE` unset after secrets operations | `cleanup_secrets_environment()` — call explicitly after `ensure_sops_env()` *(LS-2)* |

---

## Known Issues Fixed

| ID | Severity | File | Summary |
|----|----------|------|---------|
| SK-1 | Medium | `simple_key_resilience.sh` | `simple_verify_age_key`: `printf '%s'` replaces `echo` for roundtrip test |
| BUG-R1 | High | `simple_key_resilience.sh` | `simple_verify_age_key`: portable `_stat_octal_perms_local()` replaces GNU-only `stat -c '%a'` |
| BUG-R2 | Medium | `simple_key_resilience.sh` | `create_printable_key_backup`: trap double-quoted so `$temp_html` expands at registration time |
| BUG-R3 | Medium | `simple_key_resilience.sh` | `create_printable_key_backup`: Age key piped via stdin to `qrencode` — never a CLI argument |
| BUG-R4 | Low | `simple_key_resilience.sh` | `_secure_remove_file`: portable `_stat_file_size()` replaces GNU-only `stat -c%s` |
| SKR-H1 | High | `simple_key_resilience.sh` | `create_printable_key_backup`: `unset key_content` after heredoc; HTML-escape before embed |
| SKR-M1 | Medium | `simple_key_resilience.sh` | `simple_verify_age_key`: log_warn before auto-fixing permissions/ownership |
| SKR-M2 | Medium | `simple_key_resilience.sh` | `create_printable_key_backup`: self-delete reminder in HTML + at(1) job |
| SKR-M3 | Medium | `simple_key_resilience.sh` | `verify_key_replica`: functional roundtrip per replica in addition to SHA-256 |
| SKR-M4 | Medium | `simple_key_resilience.sh` | `restore_key_from_replica`: atomic cp-to-tmp then mv |
| SKR-L1 | Medium | `simple_key_resilience.sh` | `create_password_manager_escrow`: `trap ... RETURN` not EXIT |
| SKR-L2 | Low | `simple_key_resilience.sh` | `verify_key_replica`: empty replica list returns 1 with log_warn |
| BUG-S5 | Critical | `secrets.sh` | `offer_recovery_kit_export`: tmpfs directory via `_tmpfs_dir()`, not `$HOME` |
| LS-1 | Critical | `secrets.sh` | `generate_recovery_kit`: per-key SOPS extract, no full-JSON variable |
| LS-2 | Critical | `secrets.sh` | `cleanup_secrets_environment`: real unset, not no-op |
| LS-6 | Medium | `secrets.sh` | `_ork_generate_and_secure`: `trap ... RETURN` not EXIT |
