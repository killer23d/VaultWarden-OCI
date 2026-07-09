# Secrets Schema — VaultWarden-OCI

`secrets-schema.yaml` is the **single source of truth** for every secret key managed by this project. It is committed unencrypted and contains no secret values — only structural metadata. Plain keys can usually be added in the schema alone; keys with custom collection or condition logic must also provide the referenced Bash function.

Related docs: [BOOTSTRAP_KEY_RECOVERY.md](BOOTSTRAP_KEY_RECOVERY.md) · [BACKUP-RESTORE.md](BACKUP-RESTORE.md) · [SCRIPTS.md](SCRIPTS.md) · [OPERATIONS.md](OPERATIONS.md)

---

## ✏️ Operator Workflow

### Adding or renaming a secret key

1. Edit `secrets-schema.yaml` — add or rename the entry
2. Run `./edit-secrets.sh edit` — type the value next to the key, save, and quit

The key is immediately available to all consumers — bootstrap, rotation, placeholder checks, Docker secret export, and the `edit` hint layer. No script modifications required.

The canonical key list is always available at runtime:

```bash
sudo utilities/setup-secrets.sh rotate list
```

### Changing a secret value

```bash
sudo ./edit-secrets.sh edit
# rename the key or overwrite the value, save, quit
# the file is re-encrypted automatically with the same Age key
```

Plain string secrets (anything with `hash: plain`) can be freely renamed and overwritten inline. Hashed secrets (`hash: argon2id`, `hash: bcrypt`) display an inline hint warning you not to type plaintext there — use `rotate` instead:

```bash
sudo ./edit-secrets.sh rotate admin_token
sudo ./edit-secrets.sh rotate admin_basic_auth_hash
```

---

## 📋 Field Reference

| Field | Type | Required | Description |
| :-- | :-- | :-- | :-- |
| `key` | string | ✅ | Key name as it appears in `secrets.yaml`. Must match `^[a-z][a-z0-9_]*$`. |
| `label` | string | ✅ | Human-readable prompt shown during interactive collection. |
| `hash` | enum | ✅ | Fixed transform contract. See [Hash Types](#hash-types) below. |
| `placeholder` | string | ✅ | Value written by `setup-secrets.sh bootstrap` before real secrets are set. |
| `collect` | enum | ✅ | Collection mode. See [Collect Modes](#collect-modes) below. |
| `auto_fn` | string | ✅ | Supported generator when `collect: auto`. Empty string when not applicable. |
| `condition_fn` | string | Conditional keys | Bash predicate called before collection. It receives the key name, returns `0` to collect, and returns `1` to write the schema placeholder without prompting. |
| `conditional_group` | string | Optional | Named runtime requirement group, currently used for Cloudflare proxy secrets. |
| `apply` | mapping | ✅ | Closed apply contract with `type` and `targets`. Types: `compose_restart`, `systemd_restart`, `crowdsec_worker_config`, `none`. |
| `required` | bool | ✅ | When `true`, `check_placeholder_values()` fails if this key still holds its placeholder. |
| `hint` | string | ✅ | Comment line injected above the key in the plaintext temp file during `edit`. Empty string means no hint. |

### Hash Types

| Value | Behaviour |
| :-- | :-- |
| `argon2id` | Plaintext is hashed with Argon2id before storage. Used by VaultWarden admin token. |
| `bcrypt` | Plaintext is hashed with bcrypt and formatted as `admin <hash>` (htpasswd). Used by Caddy basic auth. |
| `plain` | Value is stored as-is, no transform. Used for all API tokens and passphrases. |
| `none` | Reserved. Not currently used. |

### Collect Modes

| Value | Behaviour |
| :-- | :-- |
| `interactive` | Operator is prompted at the terminal during `setup-secrets.sh configure`. |
| `auto` | Value is generated automatically by the function named in `auto_fn`. |
| `conditional` | The function named by `condition_fn` decides whether collection runs. See [Conditional Keys](#conditional-keys) below. |
| `skip` | Key is never collected interactively; must be set manually via `edit` or `rotate`. |

---

## 🔑 Key Inventory

| Key | Hash | Required | Collect | Apply |
| :-- | :-- | :-- | :-- | :-- |
| `admin_token` | `argon2id` | ✅ | `interactive` | `vaultwarden` |
| `admin_basic_auth_hash` | `bcrypt` | ✅ | `interactive` | `caddy` |
| `smtp_password` | `plain` | — | `interactive` | `postfix` |
| `email_api_token` | `plain` | — | `interactive` | none |
| `file_integrity_hmac_key` | `plain` | — | `auto` | none |
| `push_installation_id` | `plain` | — | `conditional` | `vaultwarden` |
| `push_installation_key` | `plain` | — | `conditional` | `vaultwarden` |
| `caddy_cloudflare_dns_token` | `plain` | ✅ | `interactive` | `caddy` |
| `cf_worker_bouncer_token` | `plain` | — | `interactive` | CrowdSec Workers config apply |
| `cloudflare_zone_id` | `plain` | — | `interactive` | CrowdSec Workers config apply |
| `cf_account_id` | `plain` | — | `interactive` | CrowdSec Workers config apply |

---

## ⚙️ Schema Version

The file must begin with `schema_version: 1`. All scripts assert this value on load and fail fast if it does not match. This prevents silent breakage if the schema format changes in a future version.

```yaml
schema_version: 1

secrets:
  - key: admin_token
    ...
```

---

## 🔀 Conditional Keys

`push_installation_id` and `push_installation_key` use `condition_fn: condition_push_enabled`. The dispatcher evaluates that predicate for each key before entering key-specific collection logic:

| `PUSH_ENABLED` | Behaviour |
| :-- | :-- |
| `true` (auto mode) | Placeholders are written with a warning because Bitwarden credentials cannot be generated automatically; rotate both fields before startup. |
| `true` (interactive) | Operator is prompted for the installation ID and key as one atomic group. |
| `false` or unset | Placeholder is written; push is disabled. |

To add another conditional secret:

1. Set `collect: conditional` and `condition_fn: your_predicate` in the schema.
2. Define `your_predicate KEY` in `collect_secrets()` scope in `utilities/setup-secrets.sh`.
3. Return `0` when the key should be collected and `1` when its schema placeholder should be used.
4. Keep the predicate side-effect free; prompting and value generation belong in the key handler.

An absent or unknown `condition_fn` is a hard configuration error, preventing a future conditional key from being silently skipped.

---

## Per-installation SOPS configuration

`.sops.yaml` is generated by `setup-secrets.sh bootstrap` from the deployment's Age public key and is intentionally gitignored. Committing a placeholder recipient would either dirty every installation during setup or risk encrypting to the wrong key. Re-run bootstrap or `make key-health` if the generated file is missing or stale.

---

## 📧 Email Mode Sentinel Values

`smtp_password` and `email_api_token` are gated by `EMAIL_MODE` in `.env`. When the current mode makes a key inapplicable, `collect_secrets()` writes a `NOT_USED_EMAIL_MODE=<mode>` sentinel value instead of prompting. This sentinel is distinct from a placeholder:

| Value | Meaning |
| :-- | :-- |
| `PLACEHOLDER_NOT_CONFIGURED` | Key has never been set. `check_placeholder_values()` will warn if `required: true`. |
| `NOT_USED_EMAIL_MODE=api` | SMTP key was skipped because `EMAIL_MODE=api`. Not an error. |
| `NOT_USED_EMAIL_MODE=smtp` | API token was skipped because `EMAIL_MODE=smtp`. Not an error. |

---

## 🔧 Schema Library (`lib/schema.sh`)

`lib/schema.sh` is a standalone helper library. It is sourced by `lib/secrets.sh` and is transitively available to all callers without requiring a direct `source` line. It requires `yq` (v4+).

### Functions

| Function | Description |
| :-- | :-- |
| `schema_keys` | Prints all key names to stdout, one per line, in schema order. |
| `schema_field KEY FIELD` | Prints the value of `FIELD` for `KEY`. Returns 1 if key or field is absent. |
| `schema_field_safe KEY FIELD` | Like `schema_field` but returns an empty string instead of an error for absent optional fields. |
| `schema_required_keys` | Prints keys where `required: true`, in schema order. Used by `check_placeholder_values()`. |
| `schema_hinted_keys` | Prints keys where `hint` is non-empty. Used by `secrets-edit.sh` for inline comment injection. |
| `schema_apply_type_for_key KEY` | Prints the closed apply type for `KEY`. |
| `schema_apply_targets_for_key KEY` | Prints space-separated apply targets for `KEY`. |
| `schema_services_for_key KEY` | Compatibility helper that prints Compose restart targets only. Non-Compose actions return empty. |
| `schema_placeholder_for_key KEY` | Prints the placeholder string for `KEY`. Convenience wrapper around `schema_field`. |
| `schema_key_exists KEY` | Returns 0 if `KEY` is defined in the schema, 1 otherwise. Used by `secrets-rotate.sh` to validate field arguments. |
| `schema_collect_type KEY` | Prints the collect type: `interactive`, `auto`, `conditional`, or `skip`. |

### Usage example

```bash
source "${LIB_DIR}/log.sh"
source "${LIB_DIR}/schema.sh"

# Iterate all keys in schema order
while IFS= read -r key; do
    placeholder=$(schema_placeholder_for_key "$key")
    collect_type=$(schema_collect_type "$key")
    echo "$key → collect=$collect_type placeholder=$placeholder"
done < <(schema_keys)
```

### Decrypting a single key at runtime

Use `decrypt_secret` from `lib/secrets.sh`. It handles `SOPS_AGE_KEY_FILE` setup and teardown, suppresses xtrace to prevent values appearing in debug logs, and captures sops stderr for actionable error messages:

```bash
# Always capture via local variable — never pass directly as a command argument
local value
value=$(decrypt_secret "smtp_password") || return 1
```

> **Security note:** Do not pass `$(decrypt_secret ...)` directly as a positional argument to an external command. The plaintext would appear in `/proc/$$/cmdline` and be visible to other processes on the same host. Capture to a local variable first.

---

## 🔗 Dependencies

| Dependency | Purpose | Install |
| :-- | :-- | :-- |
| `yq` v4+ | Reads `secrets-schema.yaml` in all schema functions | `sudo snap install yq` |
| `sops` | Encrypts and decrypts `secrets.yaml` | Installed by `setup.sh` |
| `age` | Key management for SOPS | Installed by `setup.sh` |

`yq` is validated at the top of every schema function. If it is not installed, the function emits a fatal error and returns 1 immediately.

---

## 🛠️ Troubleshooting

**`schema.sh: 'yq' is not installed`**

```bash
sudo snap install yq
# Verify:
yq --version
```

**`schema.sh: schema file not found`**

```bash
ls -la secrets-schema.yaml
# File must exist at the project root. If missing, restore from Git:
git checkout Beta -- secrets-schema.yaml
```

**`schema.sh: unsupported schema_version`**

The `schema_version` field at the top of `secrets-schema.yaml` must be `1`. If you edited the file and changed this value, restore it:

```bash
# Check current value:
yq '.schema_version' secrets-schema.yaml

# Fix:
# Edit secrets-schema.yaml and set schema_version: 1 as the first key.
```

**Key added to schema but not appearing in `edit`**

After adding a key to `secrets-schema.yaml`, run bootstrap to write the placeholder into the encrypted file, then edit to set the real value:

```bash
# Bootstrap writes all schema keys with their placeholder values:
sudo utilities/setup-secrets.sh bootstrap

# Then set the real value:
sudo ./edit-secrets.sh edit
```

> **Note:** Bootstrap will not overwrite an existing `secrets.yaml`. If the file already exists, add the key placeholder manually via `edit`, then set the real value in the same session.

---

## Rotating file_integrity_hmac_key

### Why rotation requires a transition window

Existing `.sha256.hmac` sidecars were signed with the old key. As soon as a new key is loaded, those legacy sidecars fail authentication even when `REQUIRE_AUTHENTICATED_INTEGRITY=false`. That flag permits SHA-256 fallback only when an HMAC sidecar is missing; it never accepts a present sidecar with an invalid HMAC.

Keep an encrypted recovery kit containing the old key until every retained backup predates the rotation window. Legacy sidecars must be quarantined if those backups need SHA-only verification with the new key active.

### Rotation procedure

1. Export and securely store a recovery kit containing the current key:

   ```bash
   sudo ./edit-secrets.sh export-recovery-kit
   ```

2. Temporarily set `REQUIRE_AUTHENTICATED_INTEGRITY=false` in `.env`. Before rotating, rename the existing local `.sha256.hmac` files to `.sha256.hmac.pre-rotation` under the configured `BACKUP_DIR`. This preserves them for authenticated recovery with the old key while allowing SHA-256 fallback during the transition:

   ```bash
   sudo find /path/from/BACKUP_DIR -type f -name '*.sha256.hmac' \
       -exec sh -c 'for f do mv -- "$f" "$f.pre-rotation"; done' sh {} +
   ```

3. Generate and store a new 64-character key through the supported SOPS rotation path:

   ```bash
   sudo ./edit-secrets.sh rotate file_integrity_hmac_key
   ```

4. Create fresh backups of each scheduled type and upload their newly signed sidecars:

   ```bash
   sudo ./backup.sh run db
   sudo ./backup.sh run full
   sudo ./backup.sh sync
   ```

5. Confirm the latest backup verifies with the new key:

   ```bash
   sudo ./backup.sh verify
   ```

6. Keep `REQUIRE_AUTHENTICATED_INTEGRITY=false` only for the quarantine window. After all pre-rotation backups have aged out under `BACKUP_RETENTION_*_DAYS` and remote pruning has removed them, delete the quarantined sidecars, discard the old recovery material, and restore:

   ```dotenv
   REQUIRE_AUTHENTICATED_INTEGRITY=true
   ```

For a legacy restore during the window, retain its quarantined HMAC and recovery kit. To use SHA-only fallback with the new key active, leave the HMAC sidecar quarantined before verification. Restoring its original name correctly requires the old key to be restored temporarily as well. Remote legacy sidecars remain until their archive is pruned; quarantine the downloaded HMAC before verifying an old remote backup with the new key active.

### Emergency recovery when the key is lost

If the old key is unavailable, set `REQUIRE_AUTHENTICATED_INTEGRITY=false` and quarantine the legacy `.sha256.hmac` sidecars as described above. The remaining `.sha256` files can then detect corruption but are not authenticated. Rotate `file_integrity_hmac_key`, create fresh `db` and `full` backups, run `sudo ./backup.sh sync`, and re-enable strict authenticated integrity after the legacy retention window closes.
