# Configuration Reference — VaultWarden-OCI

VaultWarden-OCI separates non-secret configuration, persistent encrypted secrets, installed systemd runtime state, and transient decoded runtime secrets.

Related docs: [DEPLOYMENT.md](DEPLOYMENT.md) · [SECRETS-SCHEMA.md](SECRETS-SCHEMA.md) · [SECURITY.md](SECURITY.md) · [ADVANCED-CUSTOMIZATION.md](ADVANCED-CUSTOMIZATION.md)

## Configuration surfaces

| Surface | Purpose | Normal operator action |
| :-- | :-- | :-- |
| Repository `.env` | Operator-editable non-secret configuration and bootstrap source | `sudo make edit-env` |
| `${PROJECT_STATE_DIR}/config/install.env` | Persistent root-owned runtime configuration stored with project state | Generated/synced; do not hand-edit normally |
| `/etc/vaultwarden/vaultwarden.env` | Installed environment used by systemd-managed runtime | Installed by `setup-systemd.sh`; do not hand-edit normally |
| `${PROJECT_STATE_DIR}/secrets/secrets.yaml` | Persistent SOPS-encrypted secret values | `sudo ./edit-secrets.sh edit` / `rotate` |
| `/etc/vaultwarden/age-key.txt` | Live operational Age private key | Managed by setup/key rotation/recovery |
| `/run/vaultwarden-oci/secrets/` | Transient decoded Docker secret source files | Recreated by startup; never edit |

The optional offline recovery Age private key stays offline. Only its public recipient may be stored in SOPS policy/recovery metadata.

## Environment precedence

The runtime loader first discovers `PROJECT_STATE_DIR` from:

1. an explicit caller override;
2. repository `.env`;
3. `/etc/vaultwarden/vaultwarden.env`;
4. the default `/var/lib/vaultwarden`.

After the state directory is known, one complete runtime environment is loaded in this order:

1. `/etc/vaultwarden/vaultwarden.env`, when installed;
2. `${PROJECT_STATE_DIR}/config/install.env`;
3. repository `.env` as the bootstrap/legacy fallback.

Explicit caller overrides for state directory, data device, data mount, and the SOPS Age key path are reapplied after loading.

The authoring/sync workflow is intentionally different from runtime precedence:

```text
repository .env
    -> sudo make sync-env
${PROJECT_STATE_DIR}/config/install.env
    -> setup-systemd install
/etc/vaultwarden/vaultwarden.env
```

Use `utilities/env-edit.sh status` to inspect paths and drift.

## Normal configuration workflow

Initial setup:

```bash
sudo ./setup.sh install \
  --domain vault.yourdomain.com \
  --email admin@yourdomain.com \
  --auto
```

Edit non-secret values:

```bash
sudo make edit-env
```

`edit-env` opens repository `.env` in the configured editor and syncs changed values into the persistent runtime environment through the guarded environment workflow.

Edit or rotate secrets:

```bash
sudo ./edit-secrets.sh edit
sudo ./edit-secrets.sh rotate <secret-key>
```

Apply normal runtime changes through the root-operated lifecycle:

```bash
sudo make restart
sudo make health
```

When configuration changes affect installed systemd runtime or after repository updates to managed code/units:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

Do not rerun the full `setup.sh install --force` path merely to apply an ordinary `.env` edit.

---

## Core settings

```bash
DOMAIN=https://vault.yourdomain.com
ADMIN_EMAIL=admin@yourdomain.com
TZ=UTC
SSH_PORT=22
SSH_LOG_PATH=/var/log/auth.log
```

`DOMAIN` must include `https://`.

Cloudflare zone/account identifiers used by the CrowdSec Workers integration are SOPS secret keys, not normal `.env` values:

```bash
sudo ./edit-secrets.sh rotate cloudflare_zone_id
sudo ./edit-secrets.sh rotate cf_account_id
```

---

## User and state ownership

```bash
PUID=1000
PGID=1000
PROJECT_STATE_DIR=/var/lib/vaultwarden
```

`PUID` and `PGID` describe Vaultwarden application-data ownership. They do not change the root-operated production lifecycle.

Persistent root-operated state such as `config/`, encrypted SOPS ciphertext, `/etc/vaultwarden`, and runtime secret source directories use the repository's stricter root ownership/permission contract.

Caddy runs as UID/GID `2000:2000`. Restore/runtime permission repair normalizes Caddy data, config, and log bind mounts for that UID/GID.

---

## Storage mode

### Boot-volume mode

Leave `DATA_VOLUME_DEVICE` blank:

```bash
DATA_VOLUME_DEVICE=
DATA_VOLUME_MOUNT=/mnt/vw-data
PROJECT_STATE_DIR=/var/lib/vaultwarden
```

The default persistent state directory remains on the boot volume.

### Dedicated data-volume mode

Use an explicit stable device path where available and set the state directory equal to the mount point:

```bash
DATA_VOLUME_DEVICE=/dev/disk/by-id/your-volume
DATA_VOLUME_MOUNT=/mnt/vw-data
PROJECT_STATE_DIR=/mnt/vw-data
```

Storage safety rules include:

- the project never silently treats an unknown device as the target disk;
- attached-volume mode requires the expected mount to be active;
- `.vw-data-volume` is the project ownership/safety sentinel;
- an existing filesystem requires explicit adoption acceptance;
- blank-device formatting requires an explicit formatting authorization.

First-install example for a blank dedicated data volume:

```bash
sudo DATA_VOLUME_FORCE_FORMAT=true \
  ./setup.sh install \
    --domain vault.yourdomain.com \
    --email admin@yourdomain.com \
    --auto \
    --data-device /dev/disk/by-id/your-volume \
    --data-mount /mnt/vw-data
```

To intentionally adopt an existing filesystem during setup, use the documented `DATA_VOLUME_EXISTING_FS_OK=true` gate for that run.

For moving existing production state, use [VOLUME-MIGRATION.md](VOLUME-MIGRATION.md) rather than manually changing the three storage variables and moving files.

---

## Version pins

The authoritative defaults are in `.env.example`. Current repository pins are:

```bash
VAULTWARDEN_VERSION=1.36.0
CADDY_VERSION=2.11.4
POSTFIX_VERSION=5.1.0
BUSYBOX_VERSION=1.36.1

CROWDSEC_VERSION=1.7.8
CF_WORKER_BOUNCER_VERSION=v0.0.18
FIREWALL_BOUNCER_VERSION=0.0.34
```

Host setup also owns pinned/default tool contracts for SOPS and Mike Farah `yq`.

Keep production pins explicit. Use repository upgrade procedures and validation rather than changing production images to mutable `latest` tags.

---

## SOPS secret inventory

`secrets-schema.yaml` is the canonical secret-key schema. The current keys are:

| Secret | Transform | Normal apply behavior |
| :-- | :-- | :-- |
| `admin_token` | Argon2id | restart `vaultwarden` |
| `admin_basic_auth_hash` | bcrypt | restart `caddy` |
| `smtp_password` | plain | restart `postfix` |
| `email_api_token` | plain | no automatic service restart |
| `file_integrity_hmac_key` | plain/auto-generated | no automatic service restart |
| `push_installation_id` | plain/conditional | restart `vaultwarden` |
| `push_installation_key` | plain/conditional | restart `vaultwarden` |
| `caddy_cloudflare_dns_token` | plain | restart `caddy` |
| `cf_worker_bouncer_token` | plain | apply CrowdSec Workers config |
| `cloudflare_zone_id` | plain | apply CrowdSec Workers config |
| `cf_account_id` | plain | apply CrowdSec Workers config |

Exact required/conditional behavior and schema fields are documented in [SECRETS-SCHEMA.md](SECRETS-SCHEMA.md).

List key names without displaying values:

```bash
sudo ./utilities/secrets-list.sh
```

Edit the encrypted file:

```bash
sudo ./edit-secrets.sh edit
```

Rotate one field through its schema transform/apply contract:

```bash
sudo ./edit-secrets.sh rotate admin_token
sudo ./edit-secrets.sh rotate admin_basic_auth_hash
sudo ./edit-secrets.sh rotate caddy_cloudflare_dns_token
```

Do not place production tokens/passwords in `.env`.

---

## Cloudflare configuration

The supported normal path is Cloudflare-first:

```bash
TLS_PROVIDER=cloudflare
CLOUDFLARE_PROXY_ENABLED=true
ADMIN_ALLOW_CIDR=127.0.0.1/32
```

Set `ADMIN_ALLOW_CIDR` to the trusted administrative source range appropriate for your deployment.

Cloudflare DNS-01 uses `caddy_cloudflare_dns_token`. CrowdSec Workers integration uses `cf_worker_bouncer_token`, `cloudflare_zone_id`, and `cf_account_id`.

The Workers bouncer/KV architecture is documented in [CROWDSEC.md](CROWDSEC.md).

---

## Email configuration

The normal production path is Postfix-first SMTP:

```bash
EMAIL_MODE=smtp
EMAIL_PROVIDER=
SMTP_HOST=smtp.yourmailprovider.com
SMTP_PORT=587
SMTP_SECURITY=starttls
SMTP_USERNAME=your-smtp-username
SMTP_FROM=noreply@vault.yourdomain.com
SMTP_FROM_NAME=VaultWarden
ALLOWED_SENDER_DOMAINS=yourdomain.com
```

Store the relay password in SOPS:

```bash
sudo ./edit-secrets.sh rotate smtp_password
```

Vaultwarden itself points to the internal Postfix sidecar:

```bash
VW_SMTP_HOST=postfix
VW_SMTP_PORT=587
VW_SMTP_SECURITY=off
VW_SMTP_AUTH_MECHANISM=none
VW_SMTP_EXPLICIT_TLS=false
```

Do not replace `VW_SMTP_HOST` with the upstream relay hostname. Postfix owns upstream authentication/TLS/queueing.

Optional CrowdSec security-event mail is ordinary non-secret configuration and is disabled by default:

```bash
CROWDSEC_EMAIL_NOTIFICATIONS=false
```

Manage and reconcile it through the dedicated controller:

```bash
sudo ./utilities/crowdsec-email.sh enable
sudo ./utilities/crowdsec-email.sh status
sudo ./utilities/crowdsec-email.sh test
sudo ./utilities/crowdsec-email.sh disable
```

`enable` and `disable` update the option transactionally and delegate to the established CrowdSec reconciliation path. After changing `ADMIN_EMAIL`, `SMTP_FROM`, or `ALLOWED_SENDER_DOMAINS`, rerun `enable` to regenerate and validate the managed configuration. `status` checks the environment flag and managed markers; `test` confirms plugin dispatch but not mailbox receipt. The broader `sudo ./utilities/setup-crowdsec.sh` path remains valid for initial installation and general CrowdSec maintenance.

Optional API-first operational alert mode:

```bash
EMAIL_MODE=auto
EMAIL_PROVIDER=mailersend   # sendgrid | mailgun | postmark | resend
```

Then set:

```bash
sudo ./edit-secrets.sh rotate email_api_token
```

Keep the SMTP/Postfix path configured because Vaultwarden mail and attachment-based recovery-kit messages still depend on SMTP.

See [EMAIL.md](EMAIL.md).

---

## Vaultwarden application settings

Common application settings include:

```bash
SIGNUPS_ALLOWED=false
INVITATIONS_ALLOWED=true
EMERGENCY_ACCESS_ALLOWED=true
SENDS_ALLOWED=true
WEB_VAULT_ENABLED=true
WEBSOCKET_ENABLED=true

PASSWORD_ITERATIONS=600000
PASSWORD_HINTS_ALLOWED=false
SHOW_PASSWORD_HINT=false
LOG_LEVEL=warn
DISABLE_ADMIN_TOKEN=false
DISABLE_ICON_DOWNLOAD=false

ICON_CACHE_TTL=2592000
ICON_CACHE_NEGTTL=259200
ORG_CREATION_USERS=
ORG_EVENTS_ENABLED=false
EVENTS_DAYS_RETAIN=365
TRASH_AUTO_DELETE_DAYS=30
INCOMPLETE_2FA_TIME_LIMIT=3

DATABASE_MAX_CONNS=10
DATABASE_TIMEOUT=30
```

The admin token is not a plaintext `.env` setting in the production workflow. It is stored as the schema-defined Argon2id `admin_token` secret.

---

## Push notifications

Push is optional:

```bash
PUSH_ENABLED=true
PUSH_RELAY_URI=https://push.bitwarden.com
PUSH_IDENTITY_URI=https://identity.bitwarden.com
```

Set the two conditional SOPS secrets:

```bash
sudo ./edit-secrets.sh rotate push_installation_id
sudo ./edit-secrets.sh rotate push_installation_key
```

The current Compose topology attaches Vaultwarden to the dedicated `vaultwarden_egress` network for outbound access. Do not copy old guidance that tells operators to remove the main `vaultwarden` network's isolation as the normal solution.

After enabling push, restart and run health checks:

```bash
sudo make restart
sudo make health
```

---

## Backup and offsite configuration

Current `.env.example` defaults include:

```bash
BACKUP_ENCRYPTION_ENABLED=true
BACKUP_VERIFICATION_MODE=quick_check
REQUIRE_AUTHENTICATED_INTEGRITY=true

BACKUP_RETENTION_DAYS=30
BACKUP_RETENTION_DB_DAYS=14
BACKUP_RETENTION_FULL_DAYS=30
BACKUP_RETENTION_EMERGENCY_DAYS=90

RCLONE_REMOTE_NAME=CHANGE_ME_RCLONE_REMOTE
RCLONE_CONFIG=
RCLONE_REMOTE_PATH=BW-Backup
```

`BACKUP_DIR` defaults under `PROJECT_STATE_DIR` when left blank.

The normal production path keeps backup encryption enabled. Full and emergency backup semantics are security-relevant and differ from database backups; see [BACKUP-RESTORE.md](BACKUP-RESTORE.md) before changing encryption or retention behavior.

For systemd jobs, the canonical installed rclone config is:

```text
/etc/vaultwarden/rclone.conf
```

After changing rclone configuration, reinstall/validate systemd runtime:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
```

---

## Restore key configuration

`RESTORE_AGE_KEY_FILE` is an optional non-interactive restore key-file override. Leave it blank for normal interactive use.

The restore CLI also supports explicit key-file/recovery-kit selection according to its current command grammar. Use:

```bash
./restore.sh --help
```

or the generated [COMMAND-REFERENCE.md](COMMAND-REFERENCE.md) for exact option precedence and subcommand grammar.

Do not confuse:

- the operational Age key;
- an offline recovery Age private identity;
- the public offline recipient stored in policy/manifest state;
- an emergency backup passphrase;
- `EMERGENCY_BACKUP_AGE_RECIPIENT`.

---

## Operation guard configuration

Mutating workflows use the shared operation guard under `/run/vaultwarden-oci/operations` with kernel `flock` state as the authority.

Use:

```bash
sudo make operations
```

to inspect current operation metadata and active ownership.

Do not delete lock files or operation metadata as a generic way to "unstick" the appliance. First determine whether the owning process/lock is still active.

---

## Applying and validating configuration changes

For ordinary non-secret `.env` changes:

```bash
sudo make edit-env
sudo make restart
sudo make health
```

For secret changes, use `edit-secrets.sh`; schema apply behavior may restart or reconfigure the affected component.

For managed systemd/runtime changes:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

For exact script options, rely on `--help` and [COMMAND-REFERENCE.md](COMMAND-REFERENCE.md). Do not maintain a separate hand-copied option inventory in local notes.
