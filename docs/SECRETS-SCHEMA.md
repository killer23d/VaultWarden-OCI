# Secrets Schema — VaultWarden-OCI

`secrets-schema.yaml` is the single structural source of truth for secret keys managed by VaultWarden-OCI.

It contains no secret values and is safe to commit. The live values are stored in SOPS-encrypted:

```text
${PROJECT_STATE_DIR}/secrets/secrets.yaml
```

Related docs: [CONFIGURATION.md](CONFIGURATION.md) · [SECURITY.md](SECURITY.md) · [BOOTSTRAP_KEY_RECOVERY.md](BOOTSTRAP_KEY_RECOVERY.md)

## Why the schema exists

Secret setup, edit, rotation, collection, validation, apply behavior, and generated documentation must not maintain independent hard-coded key lists.

The schema owns:

- key name;
- operator label;
- fixed transform contract;
- bootstrap placeholder;
- collection mode;
- supported auto/conditional function;
- optional conditional group;
- apply type/targets;
- required flag;
- editor hint.

The implementation reads this metadata through `lib/schema.sh` and the owning secret utilities.

## Operator workflow

List key names without printing values:

```bash
sudo ./utilities/secrets-list.sh
```

Edit the encrypted file:

```bash
sudo ./edit-secrets.sh edit
```

Rotate one key through its schema transform/apply contract:

```bash
sudo ./edit-secrets.sh rotate admin_token
sudo ./edit-secrets.sh rotate smtp_password
sudo ./edit-secrets.sh rotate caddy_cloudflare_dns_token
```

Do not edit `secrets-schema.yaml` merely to change a secret value. The schema defines structure; `secrets.yaml` contains encrypted values.

## Current schema fields

### `key`

Secret key as stored in `secrets.yaml`.

Required naming pattern:

```text
^[a-z][a-z0-9_]*$
```

### `label`

Human-readable collection prompt/description.

### `hash`

Closed transform contract:

```text
argon2id
bcrypt
plain
none
```

The schema transform is not a suggestion. Rotation must use the fixed transform expected by the consumer.

Examples:

- `admin_token` → `argon2id`;
- `admin_basic_auth_hash` → `bcrypt`;
- Cloudflare/SMTP/API tokens → `plain`.

### `placeholder`

Value used when the bootstrap path creates the encrypted secret structure before a real value is collected/generated.

Required-value validation uses the schema placeholder contract rather than a second hard-coded placeholder list.

### `collect`

Closed collection mode:

```text
interactive
auto
conditional
skip
```

### `auto_fn`

Supported generator used only with `collect: auto`.

The current schema uses:

```text
auto_generate_secret_field
```

for `file_integrity_hmac_key`.

Do not place arbitrary shell code/function names in the schema.

### `condition_fn`

Supported predicate used only with `collect: conditional`.

The current push secret pair uses:

```text
condition_push_enabled
```

When push is disabled, the bootstrap/collection path writes the schema placeholder without prompting for the push pair.

### `conditional_group`

Optional named runtime requirement group. Group membership stays in the schema; Bash configuration logic decides which group semantics are active for the current deployment.

Current groups are:

| Group | Schema keys | Runtime meaning |
| :-- | :-- | :-- |
| `cloudflare_proxy` | `cf_worker_bouncer_token`, `cloudflare_zone_id`, `cf_account_id` | all required when `CLOUDFLARE_PROXY_ENABLED=true` |
| `push` | `push_installation_id`, `push_installation_key` | both required when `PUSH_ENABLED=true` |
| `authenticated_integrity` | `file_integrity_hmac_key` | always required for trusted backup/restore integrity |
| `email_api` | `email_api_token` | additionally required for `EMAIL_MODE=api` |
| `email_smtp` | `smtp_password` | stack-level requirement for every supported `EMAIL_MODE` because the canonical Compose stack always starts Postfix with this file secret |

`EMAIL_MODE=auto` still controls operational email dispatch as an API-to-SMTP fallback chain, but recovery completeness covers the full appliance rather than only `lib/email.sh`. The canonical Compose template always declares the Postfix service and its `smtp_password` file secret, and startup starts the full service set. Therefore `smtp_password` must be configured in `auto` even when an API token is available; `email_api_token` remains optional in `auto`. An omitted `EMAIL_MODE` uses the same effective `auto` semantics.

This lets runtime/setup/recovery validation distinguish configuration-dependent requirements without turning `required: false` into either "always optional" or "always required."

### `apply`

Closed apply contract:

```yaml
apply:
  type: compose_restart | systemd_restart | crowdsec_worker_config | none
  targets:
    - explicit-target
```

Current apply types are intentionally small. Do not add a generic hook/plugin engine for one new secret.

### `required`

When `true`, required-value validation fails while the key still contains the schema placeholder.

A `false` value does not mean the secret is safe to print. It means it is not universally required by the base placeholder check.

### `hint`

Comment injected into the plaintext edit staging file to help the operator.

Hints must not contain real secret values.

## Current secret inventory

| Key | Transform | Collection | Apply |
| :-- | :-- | :-- | :-- |
| `admin_token` | Argon2id | interactive | Compose restart: `vaultwarden` |
| `admin_basic_auth_hash` | bcrypt | interactive | Compose restart: `caddy` |
| `smtp_password` | plain | interactive | Compose restart: `postfix` |
| `email_api_token` | plain | interactive | none |
| `file_integrity_hmac_key` | plain | auto | none |
| `push_installation_id` | plain | conditional | Compose restart: `vaultwarden` |
| `push_installation_key` | plain | conditional | Compose restart: `vaultwarden` |
| `caddy_cloudflare_dns_token` | plain | interactive | Compose restart: `caddy` |
| `cf_worker_bouncer_token` | plain | interactive | CrowdSec Workers config apply |
| `cloudflare_zone_id` | plain | interactive | CrowdSec Workers config apply |
| `cf_account_id` | plain | interactive | CrowdSec Workers config apply |

The table above reflects the current `secrets-schema.yaml`. The YAML file remains the executable source of truth if this reference ever drifts.

## Required keys

The current universally required schema keys are:

```text
admin_token
admin_basic_auth_hash
caddy_cloudflare_dns_token
```

Other keys may become operationally required by the configured feature path, such as Cloudflare proxy/Workers integration, authenticated backup integrity, push, or email mode. Under the canonical full-stack startup contract, `smtp_password` is required for every supported email mode because Postfix is always part of the generated Compose stack; `EMAIL_MODE=api` additionally requires `email_api_token`.

The supported golden production path requires the Cloudflare Workers and SMTP credentials described in [DEPLOYMENT.md](DEPLOYMENT.md), even when a base schema field is represented as conditional/not universally required.

## Apply behavior

### `compose_restart`

The secret rotation path updates encrypted state/runtime secret material and applies the defined Compose service target.

Examples:

```text
admin_token                 -> vaultwarden
admin_basic_auth_hash       -> caddy
smtp_password               -> postfix
caddy_cloudflare_dns_token  -> caddy
push installation pair      -> vaultwarden
```

Do not restart the whole stack when the schema already identifies the affected service unless the owning rotation workflow has another validated reason.

### `crowdsec_worker_config`

Used for:

```text
cf_worker_bouncer_token
cloudflare_zone_id
cf_account_id
```

The owning apply path renders/reconciles the Cloudflare Workers bouncer configuration. It is not a Compose restart.

### `none`

The schema does not prescribe an automatic service restart/apply action.

This does not mean the new value is unused. The consuming workflow may read it on its next invocation.

## Hashing contracts

### `admin_token`

The Vaultwarden admin token is stored as an Argon2id PHC string.

Rotate it through:

```bash
sudo ./edit-secrets.sh rotate admin_token
```

Do not paste a plaintext admin password into `secrets.yaml` and relabel it as `admin_token`.

### `admin_basic_auth_hash`

The Caddy basic-auth credential uses bcrypt.

Rotate it through:

```bash
sudo ./edit-secrets.sh rotate admin_basic_auth_hash
```

### `plain`

`plain` means SOPS stores the raw credential value inside encrypted YAML. It does not mean the value may be stored in plaintext `.env`, documentation, Git, or logs.

## Backup integrity HMAC key

`file_integrity_hmac_key` authenticates backup checksum sidecars.

It is auto-generated by the schema collection path.

Rotation is a compatibility event for retained backups: older `.sha256.hmac` sidecars were signed with the previous key.

Before rotating:

1. ensure recovery material containing the old key is stored off-host;
2. identify retained backup generations signed with the old key;
3. keep the old key available for controlled historical verification until those generations are retired.

Do not delete old recovery material immediately after HMAC-key rotation and assume Age encryption alone proves the old sidecar's authenticity contract.

## Adding a secret

When a real production feature requires a new secret:

1. add one entry to `secrets-schema.yaml`;
2. choose a supported `hash` transform;
3. choose a supported `collect` mode;
4. use only supported `auto_fn`/`condition_fn` values;
5. choose the smallest existing apply type that matches the consumer;
6. add the consuming runtime path;
7. add focused schema/secret tests;
8. update operator docs when the key requires operator action.

Do not add parallel key arrays to:

- `setup-secrets.sh`;
- `secrets-rotate.sh`;
- `secrets-edit.sh`;
- documentation generators;
- tests.

If an existing schema accessor/closed apply type cannot express the new secret, first determine whether a small extension to the existing schema contract is enough. Do not create a generic secret plugin system.

## Removing or renaming a secret

Treat removal/rename as a compatibility change.

Before editing the schema, search:

```bash
grep -R "old_secret_key" . \
  --exclude-dir=.git
```

Inspect:

- Compose consumers;
- Caddy/entrypoint code;
- maintenance/email code;
- CrowdSec setup/Workers rendering;
- backup/recovery code;
- tests;
- generated command reference/help;
- hand-maintained docs.

After the consumer migration is complete, update the schema and encrypted secret state through the supported editor/setup path.

Do not repair a schema mistake with branch-specific commands such as:

```bash
git checkout Beta -- secrets-schema.yaml
```

To restore the current branch's committed schema:

```bash
git restore --source=HEAD -- secrets-schema.yaml
```

## Tool requirement

Schema access requires the Mike Farah `yq` v4 implementation used by the project.

The supported host setup installs and validates the pinned `yq` v4 interface:

```bash
sudo ./utilities/setup-system.sh
```

Do not install Ubuntu/Python `yq` and assume it satisfies the repository syntax.

Verify:

```bash
yq --version
```

The output must identify the Mike Farah implementation and v4 major version; the supported setup also validates the exact pinned default where required.

## Validation

After a schema change:

```bash
sudo ./utilities/secrets-list.sh
sudo make test-secrets
./tests/run-tests.sh all
```

When the change affects public help text, regenerate the command reference through its owner:

```bash
bash utilities/write-command-reference.sh
```

Do not hand-edit [COMMAND-REFERENCE.md](COMMAND-REFERENCE.md).

## Recovery material

Export current recovery material through:

```bash
sudo ./utilities/secrets-export-recovery-kit.sh
```

Re-export after material secret/key rotation according to the recovery plan.

The recovery kit contains sensitive plaintext while exported. Store it off-host and remove plaintext server copies after confirming the external copy is usable.
