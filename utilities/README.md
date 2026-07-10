# `utilities/`

Focused implementation and administrative utilities for VaultWarden-OCI.

Most production mutation is reached through the top-level dispatchers or Makefile. Direct utility invocation is supported where the script documents it, but direct invocation must preserve the same root, operation-guard, environment, storage, and failure contracts as the dispatcher path.

For exact options, run the utility with `--help` or read the generated [../docs/COMMAND-REFERENCE.md](../docs/COMMAND-REFERENCE.md).

## Production privilege model

VaultWarden-OCI uses a root-operated production lifecycle.

Production setup, start/stop/restart, backup creation/verification/retention/sync, restore mutation, secrets mutation, maintenance mutation, storage mutation, systemd install/remove, firewall/DNS mutation, CrowdSec setup, permission repair, smoke testing, and uninstall are root-operated.

Metadata/help/read-only paths may intentionally work without root when the owning script supports that behavior. Do not infer a general unprivileged service-user model from a root-free help or status command.

## Utility map

| Utility | Owner/entry point | Purpose |
| :-- | :-- | :-- |
| `backup-run.sh` | `backup.sh` | backup creation, verify, retention, rclone sync, inventory |
| `crowdsec-worker-apply.sh` | direct/schema apply | render and apply CrowdSec Workers bouncer config |
| `env-edit.sh` | `make edit-env`, `make sync-env` | edit/sync/status for non-secret environment state |
| `key-rotate.sh` | `make key-rotate` | operational Age/SOPS key rotation |
| `maintenance-db-maint.sh` | `maintenance.sh db-maint` | guarded SQLite maintenance |
| `maintenance-email.sh` | `maintenance.sh test-email` | operational email diagnostics |
| `maintenance-health.sh` | `maintenance.sh health` | health checks and optional guarded repair |
| `maintenance-run.sh` | `maintenance.sh run` | aggregate maintenance cycle |
| `maintenance-update-dns.sh` | `maintenance.sh update-dns` | Cloudflare DNS A-record update |
| `maintenance-update-firewall.sh` | `maintenance.sh update-firewall` | Cloudflare CIDR/UFW refresh |
| `maintenance-update.sh` | `maintenance.sh update` | image/package update workflow |
| `notify-failure.sh` | systemd OnFailure integration | operational failure notifications |
| `operations-status.sh` | `make operations` | shared operation status/conflict interface |
| `pre-production-drill.sh` | `make drill` | non-destructive pre-production rehearsal |
| `repair-permissions.sh` | `make fix-permissions` | explicit known-path permission repair/check |
| `restore-run.sh` | `restore.sh` | restore engine |
| `safe-restart.sh` | `make safe-restart` | guarded restart/rollback workflow |
| `secrets-edit.sh` | `edit-secrets.sh edit` | decrypt/edit/validate/re-encrypt SOPS secrets |
| `secrets-export-recovery-kit.sh` | `edit-secrets.sh` / direct | export operator recovery material |
| `secrets-list.sh` | `edit-secrets.sh list` / direct | list secret key names only |
| `secrets-rotate.sh` | `edit-secrets.sh rotate` | schema-aware single-secret rotation/apply |
| `secrets-view.sh` | `edit-secrets.sh view` / direct | read-only decrypted secret view |
| `setup-crowdsec.sh` | setup/direct | CrowdSec and bouncer installation/reconciliation |
| `setup-env.sh` | `setup.sh` | deployment/environment generation |
| `setup-firewall.sh` | `setup.sh` | supported Ubuntu host firewall configuration |
| `setup-secrets.sh` | `setup.sh secrets` | SOPS/Age bootstrap and secret collection |
| `setup-storage.sh` | `setup.sh` / direct | storage setup, verify, migration dispatch |
| `setup-system.sh` | `setup.sh` | Noble/architecture preflight and host dependencies |
| `setup-systemd.sh` | `setup.sh systemd` | managed runtime install/validate/status/remove |
| `smoke-test.sh` | `make smoke-test` | live production-readiness checks |
| `uninstall-vaultwarden.sh` | `make uninstall` | project teardown and same-VM test reset |
| `write-command-reference.sh` | `make docs` | generate exact command-reference documentation |

## Environment editing

Repository `.env` is the operator-editable non-secret surface:

```bash
sudo make edit-env
sudo make sync-env
utilities/env-edit.sh status
```

`sync` writes the accepted environment to `${PROJECT_STATE_DIR}/config/install.env`. `setup-systemd.sh install` installs the accepted runtime environment under `/etc/vaultwarden/vaultwarden.env` for managed automation.

Do not hand-edit generated root-owned runtime environment files as the normal configuration workflow.

## Secret utilities

Canonical mutating forms:

```bash
sudo ./edit-secrets.sh edit
sudo ./edit-secrets.sh rotate admin_token
sudo ./edit-secrets.sh rotate admin_basic_auth_hash
sudo ./edit-secrets.sh rotate caddy_cloudflare_dns_token
```

Read-only key-name listing:

```bash
sudo ./utilities/secrets-list.sh
```

Recovery-kit export:

```bash
sudo ./utilities/secrets-export-recovery-kit.sh
```

`secrets-schema.yaml` owns the secret key, transform, placeholder, collection, required, and apply contracts. Do not maintain a separate hard-coded secret inventory in utility documentation.

## System preparation

```bash
sudo utilities/setup-system.sh
sudo utilities/setup-system.sh --auto
sudo utilities/setup-system.sh --skip-deps
sudo utilities/setup-system.sh --dry-run
```

The utility validates Ubuntu 24.04 LTS Noble and amd64/arm64 before host package/repository work. It owns Docker Engine/Compose installation and the required command toolchain, including the repository's Mike Farah `yq` v4 contract, SOPS, Age, SQLite, rclone, and zstd dependencies.

## Storage setup and migration

Storage modes:

```bash
sudo utilities/setup-storage.sh setup
sudo utilities/setup-storage.sh verify
sudo utilities/setup-storage.sh migrate <subcommand>
```

For setup with an explicit attached volume:

```bash
sudo utilities/setup-storage.sh setup \
  --data-device /dev/disk/by-id/<your-volume> \
  --data-mount /mnt/vw-data
```

Storage setup will not silently select a disk. Existing-filesystem adoption and blank-device formatting use explicit safety gates.

Migration examples:

```bash
sudo utilities/setup-storage.sh migrate run
sudo utilities/setup-storage.sh migrate status
sudo utilities/setup-storage.sh migrate resume
sudo utilities/setup-storage.sh migrate abort
sudo utilities/setup-storage.sh migrate verify
```

A blank target migration device requires explicit `--force-format`. `--force` does not authorize formatting.

See [../docs/VOLUME-MIGRATION.md](../docs/VOLUME-MIGRATION.md).

## systemd installed runtime

```bash
sudo utilities/setup-systemd.sh install --enable-now
sudo utilities/setup-systemd.sh validate
sudo utilities/setup-systemd.sh status
sudo utilities/setup-systemd.sh remove
```

Managed runtime is installed under `/opt/vaultwarden-scripts`, `/etc/vaultwarden`, and `/etc/systemd/system`.

Non-interactive `install` defaults to install/enable without starting timers immediately. Use `--enable-now` only when the host is ready for scheduled jobs. Use `--no-enable-now` for recovery/manual-inspection hosts.

After managed repository code or unit changes:

```bash
sudo utilities/setup-systemd.sh install --enable-now
sudo utilities/setup-systemd.sh validate
sudo utilities/smoke-test.sh
```

## CrowdSec

```bash
sudo utilities/setup-crowdsec.sh
```

The supported architecture is CrowdSec on the host with:

- `crowdsec-firewall-bouncer` for host firewall enforcement;
- `crowdsec-cloudflare-worker-bouncer` for the configured locally generated decisions synchronized to Cloudflare Workers KV.

After rotating Workers bouncer credentials/IDs, use the normal schema apply behavior or:

```bash
sudo utilities/crowdsec-worker-apply.sh
```

See [../docs/CROWDSEC.md](../docs/CROWDSEC.md).

## Permission repair

```bash
sudo utilities/repair-permissions.sh --check
sudo utilities/repair-permissions.sh
```

The helper repairs explicit known project paths. It does not broadly chmod/chown the entire state directory.

## Production readiness

Smoke test:

```bash
sudo utilities/smoke-test.sh
```

Exit `0` requires no failed and no skipped checks. The systemd check delegates to `setup-systemd.sh validate` rather than maintaining a second timer/unit inventory.

Pre-production drill:

```bash
sudo utilities/pre-production-drill.sh
```

Use the drill's explicit skip flags only when the corresponding rehearsal is intentionally out of scope. Missing required restore prerequisites without an explicit skip are not a passing drill.

## Uninstall and test reset

Dry run:

```bash
sudo utilities/uninstall-vaultwarden.sh run --dry-run
```

Same-VM acceptance-test reset while preserving the Git checkout:

```bash
sudo utilities/uninstall-vaultwarden.sh run \
  --test-reset \
  --i-have-saved-my-recovery-kit
```

Normal teardown:

```bash
sudo utilities/uninstall-vaultwarden.sh run \
  --i-have-saved-my-recovery-kit
```

The uninstall verifies known managed residuals and fails instead of claiming success when a managed stack artifact remains.

## Development and maintenance rule

When changing a public parser or utility contract, inspect:

- its top-level dispatcher;
- Makefile callers;
- dashboard callers;
- systemd units/installed runtime;
- nested shell calls;
- permanent domain tests;
- generated command reference;
- hand-maintained operator docs.

A leaf-script parser change is incomplete when a legitimate internal caller still uses grammar the parser rejects.
