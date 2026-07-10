# Advanced Customization — VaultWarden-OCI

This guide covers supported customization outside the first-run golden path.

Read [PROJECT-BOUNDARY.md](PROJECT-BOUNDARY.md), [CONFIGURATION.md](CONFIGURATION.md), and [SECURITY.md](SECURITY.md) first. Advanced customization must preserve the Noble amd64/arm64 host boundary, root-operated lifecycle, SOPS/Age custody, storage safety, shared operation guard, and truthful readiness contracts.

Do not turn a one-host small-team appliance into a provider framework or enterprise platform merely to add one optional feature.

## Configuration ownership

Not every live file is generated from a `.example` template.

The current environment model is:

```text
repository .env                       operator-editable non-secret source
        |
        | env-edit sync
        v
${PROJECT_STATE_DIR}/config/install.env   persistent root-owned runtime state
        |
        | setup-systemd install
        v
/etc/vaultwarden/vaultwarden.env          installed systemd environment
```

Edit normal non-secret values through:

```bash
sudo make edit-env
```

Inspect state and drift with:

```bash
utilities/env-edit.sh status
```

Do not hand-edit `install.env` or `/etc/vaultwarden/vaultwarden.env` as the normal customization workflow.

For ordinary environment changes:

```bash
sudo make edit-env
sudo make restart
sudo make health
```

For changes affecting installed systemd runtime:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

Do not rerun full setup with `--force` merely to apply a normal `.env` edit.

---

## Compose customization

The generated production file is:

```text
docker-compose.yml
```

It is generated from:

```text
docker-compose.yml.example
```

Production startup rejects the development override file when it would be implicitly loaded into the normal Compose project.

The repository's development example is:

```text
docker-compose.override.dev.yml.example
```

Do not copy old instructions that refer to `docker-compose.override.yml.example`; that file is no longer the current example name.

When experimenting locally, create the actual Compose override only on a non-production development checkout and remove it before using the production lifecycle.

Validate Compose rendering:

```bash
docker compose \
  --env-file .env.example \
  -f docker-compose.yml.example \
  config --quiet
```

On a configured host:

```bash
docker compose config --quiet
```

### Do not add `platform: linux/amd64`

The supported production architectures are amd64 and arm64.

Do not hard-code:

```yaml
platform: linux/amd64
```

into the normal Compose path unless a demonstrated upstream limitation intentionally changes the supported architecture of a component and the project boundary is updated accordingly.

### Service criticality

The canonical critical-service policy is owned by `lib/defaults.sh`.

Do not add another hard-coded "core services" list to a customization script, smoke check, or dashboard parser.

Postfix is part of the normal mail design but is not in the same critical-container readiness list as Vaultwarden and Caddy. Email delivery is validated through the dedicated email diagnostics/drill path.

---

## Caddy customization

Caddy uses the repository's pinned xcaddy build in `caddy/Dockerfile`.

The current production build is version-pinned through:

```bash
CADDY_VERSION=2.11.4
```

Do not set `CADDY_VERSION=latest` for the production path.

After changing Caddy version or the xcaddy module list:

```bash
docker compose build --pull --no-cache caddy
sudo make restart
sudo make health
sudo ./utilities/smoke-test.sh
```

For architecture-sensitive module changes, verify the pinned build chain on both amd64 and arm64. A multi-architecture Caddy base image does not prove every pinned xcaddy module builds on both supported architectures.

### Caddy configuration files

Current sources are:

```text
caddy/Caddyfile
caddy/Caddyfile.degraded
caddy/entrypoint.sh
caddy/Dockerfile
```

The normal production route is Cloudflare-first DNS-01.

Do not remove the `/alive` path or replace it with `/api/alive` in readiness tooling. The current Compose and production health paths use `/alive`.

### Caddy state and log permissions

Caddy runs as UID/GID `2000:2000`.

Runtime state/log bind mounts are:

```text
${PROJECT_STATE_DIR}/caddy/data
${PROJECT_STATE_DIR}/caddy/config
${PROJECT_STATE_DIR}/logs/caddy
```

Use:

```bash
sudo utilities/repair-permissions.sh --check
sudo utilities/repair-permissions.sh
```

for target-host permission normalization. Do not broadly chown the entire project state to Caddy.

---

## Network customization

The Compose topology intentionally separates private application networking from explicit outbound access.

Vaultwarden currently joins:

```text
vaultwarden
vaultwarden_egress
```

Caddy joins:

```text
vaultwarden
caddy_external
```

Do not use the old push-notification workaround that removes the main `vaultwarden` network's isolation. The current topology already gives Vaultwarden the dedicated `vaultwarden_egress` path for outbound requirements.

When adding an outbound integration, prefer attaching only the component that needs egress to an existing appropriate network rather than making every internal service externally reachable.

Do not add host networking to the application containers merely to solve a DNS or proxy mistake.

---

## Push notifications

Push remains optional:

```bash
PUSH_ENABLED=true
PUSH_RELAY_URI=https://push.bitwarden.com
PUSH_IDENTITY_URI=https://identity.bitwarden.com
```

Set the conditional SOPS secrets:

```bash
sudo ./edit-secrets.sh rotate push_installation_id
sudo ./edit-secrets.sh rotate push_installation_key
```

Then:

```bash
sudo make restart
sudo make health
```

Do not place the installation ID/key in `.env`.

---

## Email API customization

The normal appliance mail path is Postfix-first SMTP.

Operational scripts may use an HTTP API provider:

```bash
EMAIL_MODE=auto
EMAIL_PROVIDER=mailersend
```

Supported provider names are documented by the current script help and [EMAIL.md](EMAIL.md).

Set the API token through SOPS:

```bash
sudo ./edit-secrets.sh rotate email_api_token
```

Keep the Postfix SMTP path configured. Vaultwarden application mail and attachment-based recovery-kit delivery still use SMTP/Postfix.

Do not remove Postfix merely because `EMAIL_MODE=api` works for one operational notification.

---

## Backup customization

Current defaults are:

```bash
BACKUP_VERIFICATION_MODE=quick_check
REQUIRE_AUTHENTICATED_INTEGRITY=true
BACKUP_RETENTION_DAYS=30
BACKUP_RETENTION_DB_DAYS=14
BACKUP_RETENTION_FULL_DAYS=30
BACKUP_RETENTION_EMERGENCY_DAYS=90
```

### Retention

Retention preserves the newest parseable timestamped primary archive for each tier even when older than the retention window.

Do not customize retention by replacing the canonical helper with `find ... -mtime +N -delete`. That would bypass the newest-recovery-point and sidecar contracts.

### Verification

Required quick/full verification failure is backup failure. A failed new archive is discarded and does not run normal retention/pruning/success notification behavior.

Do not treat verification as "best effort" in a way that returns success with a known failed archive.

### Emergency backup protection

Emergency archives can contain staged `/etc/vaultwarden` operational key/config material.

They must remain independently sealed using passphrase mode or a separate `EMERGENCY_BACKUP_AGE_RECIPIENT`.

Do not configure emergency archives to be encrypted only to the operational Age key they carry.

See [BACKUP-RESTORE.md](BACKUP-RESTORE.md).

---

## rclone customization

The normal root-operated automation path uses:

```text
/etc/vaultwarden/rclone.conf
```

Create/update source configuration through normal rclone tooling, then reinstall/validate systemd runtime:

```bash
rclone config
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
```

The backup config validator accepts the canonical `/root/.config/rclone/rclone.conf` fallback only when the resolved path is exactly that regular file, is root-owned, and is not world-writable.

Arbitrary `/root` paths are not acceptable.

Do not point `RCLONE_CONFIG` at sensitive system files or a symlink resolving into protected paths.

---

## Storage customization

Boot-volume mode is supported. A dedicated data volume is optional.

Current defaults:

```bash
PROJECT_STATE_DIR=/var/lib/vaultwarden
DATA_VOLUME_DEVICE=
DATA_VOLUME_MOUNT=/mnt/vw-data
```

For an attached volume, `PROJECT_STATE_DIR` must match `DATA_VOLUME_MOUNT` and the `.vw-data-volume` sentinel/mount contract must pass.

Use stable device paths where available:

```text
/dev/disk/by-id/...
/dev/disk/by-uuid/...
```

Do not put a provider-specific device path into the default template.

### Existing filesystem adoption

Existing ext4/xfs adoption is an explicit operator decision.

For non-interactive setup, use the documented `DATA_VOLUME_EXISTING_FS_OK=true` gate for the run when you intentionally adopt an existing filesystem.

### Formatting

First-install storage setup and migration have explicit formatting gates.

Migration uses:

```bash
--force-format
```

`--force` is not formatting authorization.

See [VOLUME-MIGRATION.md](VOLUME-MIGRATION.md).

---

## systemd schedule customization

Managed timer sources live in:

```text
systemd/*.timer
```

The canonical managed timer list is owned by `utilities/setup-systemd.sh`:

```text
vaultwarden-maintenance.timer
vaultwarden-db-backup.timer
vaultwarden-full-backup.timer
vaultwarden-health.timer
vaultwarden-dns-update.timer
vaultwarden-firewall-update.timer
```

To change a schedule:

1. edit the owning timer source under `systemd/`;
2. keep the unit's service/operation contention contract intact;
3. update focused tests when the schedule/managed-unit contract is protected structurally;
4. install the current unit set;
5. validate every managed timer.

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo make timers
```

Do not maintain a second six-timer list in smoke tests or local documentation automation. `setup-systemd.sh validate` is the canonical installed automation-readiness check.

### Recovery/manual inspection

For a host that is not ready to run scheduled jobs:

```bash
sudo ./setup.sh systemd install --no-enable-now
```

Enable/start only after readiness inspection:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

---

## Failure notifications

Managed systemd services use the repository's notification integration, including the template unit where service instance context is required.

Operational email delivery follows [EMAIL.md](EMAIL.md).

Expected shared-operation contention must not produce a false incident. A real failure must not be converted into clean contention merely to keep a timer green.

When adding a managed unit, inspect:

```text
systemd/
utilities/setup-systemd.sh
utilities/notify-failure.sh
```

and add the unit to the existing canonical install/validation ownership only when it is truly a managed production unit.

---

## Resource limits

The production Compose file uses explicit top-level resource controls for core containers where standalone Docker Compose enforces them, including memory/swap limits and selected CPU/PID controls.

The defaults are tuned for a small production host, not specifically for OCI ARM or one cloud instance shape.

When changing limits:

- preserve both amd64 and arm64 support;
- use top-level Compose properties that standalone Compose actually enforces for the intended control;
- remember that `deploy.resources` is primarily a Swarm construct and is not the sole enforcement source for this repository;
- verify container health and host memory pressure after changes.

Do not add a new resource scheduler or orchestration platform for a ten-user appliance.

---

## Dependency pin customization

Host setup owns pinned/default versions for architecture-sensitive downloaded tools such as SOPS and Mike Farah `yq` v4.

The current setup-system defaults include:

```text
SOPS v3.13.2
yq v4.53.3
```

The system preparation path validates the implementation/interface the repository actually needs.

Do not install Ubuntu's `python-yq` and assume it satisfies the Mike Farah `yq` v4 syntax used by the project.

Use the supported setup path:

```bash
sudo ./utilities/setup-system.sh
```

For an intentional SOPS override, use the current documented setup option rather than editing download URLs by hand:

```bash
sudo ./utilities/setup-system.sh --sops-version vX.Y.Z
```

`--use-latest` is an explicit advanced mode; it is not the default reproducible production path.

---

## Adding a new secret

`secrets-schema.yaml` is the single secret-key schema source of truth.

When adding a secret:

1. add the key and metadata to `secrets-schema.yaml`;
2. choose the correct fixed transform contract;
3. choose collection mode and conditional function only from supported schema behavior;
4. define the closed apply type/targets;
5. update the consuming runtime path;
6. add focused schema/secret behavior tests;
7. regenerate/update operator documentation where the new key is user-facing.

Do not add a parallel key array to setup, edit, rotate, docs generation, and tests.

See [SECRETS-SCHEMA.md](SECRETS-SCHEMA.md).

---

## Adding a public script option or subcommand

The public script interface is an operator API.

Before changing grammar, search:

- Makefile;
- dashboard;
- systemd units;
- top-level dispatchers;
- nested shell calls;
- permanent domain tests;
- command-reference generator/output;
- hand-maintained docs.

Options must validate required values before shifting. Options must apply only to the subcommands that use them. Unknown arguments should fail clearly.

After changing public help text:

```bash
bash utilities/write-command-reference.sh
```

Do not hand-edit [COMMAND-REFERENCE.md](COMMAND-REFERENCE.md).

---

## Advanced change validation

Use the lowest-cost meaningful layer for the change.

Common checks include:

```bash
git diff --check
```

```bash
find . \
  -path './.git' -prune -o \
  -type f -name '*.sh' -print0 \
  | xargs -0 -n 1 bash -n
```

```bash
find . \
  -path './.git' -prune -o \
  -type f -name '*.sh' -print0 \
  | xargs -0 shellcheck -x --severity=warning
```

```bash
./tests/run-tests.sh all
```

```bash
docker compose \
  --env-file .env.example \
  -f docker-compose.yml.example \
  config --quiet
```

For destructive storage/systemd/recovery behavior, a real Noble production-host acceptance test may be required. Do not claim that macOS parser tests or repository CI prove Linux `/proc`, `flock`, systemd, apt/dpkg, iptables, or block-device behavior.
