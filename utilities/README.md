# utilities/

Administrative utilities for VaultWarden-OCI. These scripts handle one-time,
host-level, or emergency operations that are outside the normal application lifecycle.

**All scripts require root**: `sudo utilities/<script>.sh`

---

## Scripts

### `migrate-volume.sh` — Volume migration

Moves `PROJECT_STATE_DIR` between block devices or directories. Supports
boot-volume-to-dedicated-volume and volume-to-volume migrations. Safe to interrupt;
resumes from the last completed step.

```bash
# Full usage
sudo utilities/migrate-volume.sh --help

# Typical: boot volume → dedicated data volume
sudo utilities/migrate-volume.sh run \
  --source /var/lib/vaultwarden \
  --target /mnt/vw-data \
  --device /dev/sdb

# Dry run first
sudo utilities/migrate-volume.sh run \
  --source /var/lib/vaultwarden \
  --target /mnt/vw-data \
  --device /dev/sdb \
  --dry-run
```

---

### `create-breakglass-admin.sh` — Emergency admin access

Creates a temporary VaultWarden admin account for emergency access when normal
credential paths are unavailable. Intentionally omits the storage guard so it
can run during storage incidents.

```bash
sudo utilities/create-breakglass-admin.sh
```

> **Bootstrap note**: `PROJECT_ROOT` is `$(cd "$(dirname "$0")/.." && pwd)` — one
> level up from `utilities/`.

---

### `uninstall-vaultwarden.sh` — Full uninstall

Removes all VaultWarden-OCI components: containers, images, systemd units, fstab
entries, and optionally data. Irreversible. Prompts for confirmation at each stage.

```bash
sudo utilities/uninstall-vaultwarden.sh
```

---

### `setup-iptables.sh` — iptables / nftables rules

Applies NAT and FORWARD rules required by the Docker network configuration.
Idempotent. Run once at host setup or after a reboot that lost rules.

```bash
sudo utilities/setup-iptables.sh
```

---

## Bootstrap Pattern

Every script in this directory must use the following `PROJECT_ROOT` resolution,
which is one level up from `utilities/`:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"
```

This is the only difference from the root-level script bootstrap pattern.

---

## What Stays at Root

The following scripts remain at the project root because they are referenced by
systemd unit files, called as subprocesses by other scripts, or directly documented
in `README.md` and `RUNBOOK.md`:

| Script | Reason |
|---|---|
| `setup.sh` | Primary installer; all documentation references it at root |
| `backup.sh` | Called by systemd timers and by `restore.sh` |
| `restore.sh` | Paired with `backup.sh`; documented in `RUNBOOK.md` |
| `maintenance.sh` | Called by systemd timers |
| `startup.sh` | Called by systemd `ExecStart=` |
| `edit-secrets.sh` | Frequently used for credential rotation; documented in `README.md` |
