# utilities/

Administrative utilities for VaultWarden-OCI. Each script is focused,
re-runnable (idempotent), and accepts `--help` for usage details.

**All scripts require root**: `sudo utilities/<script>.sh [OPTIONS]`

---

## Scripts

### `setup-system.sh` — System preparation

Installs OS dependencies (Docker, SOPS, age, etc.), configures swap, validates
the toolchain, and sets file permissions. Safe to re-run.

```bash
sudo utilities/setup-system.sh --skip-deps        # re-verify toolchain only
sudo utilities/setup-system.sh --sops-version v3.9.4
sudo utilities/setup-system.sh --dry-run
```

---

### `setup-firewall.sh` — Firewall configuration

Configures UFW (Cloudflare IP allowlist) and iptables (DOCKER-USER chain,
MASQUERADE, OCI default FORWARD-REJECT removal). Consolidates the former
standalone iptables helper into a single firewall utility.

```bash
sudo utilities/setup-firewall.sh --phase all       # UFW + iptables (default)
sudo utilities/setup-firewall.sh --phase iptables  # re-harden after Docker upgrade
sudo utilities/setup-firewall.sh --phase ufw       # refresh Cloudflare CIDRs
sudo utilities/setup-firewall.sh --dry-run
```

---

### `setup-storage.sh` — Storage setup and volume migration

Creates the project directory structure, re-checks permissions, or migrates
from boot volume to a dedicated data volume. Consolidates the former
standalone migration helper into this script.

```bash
sudo utilities/setup-storage.sh --mode setup           # create layout (first run)
sudo utilities/setup-storage.sh --mode verify          # re-check permissions only
sudo utilities/setup-storage.sh --mode migrate         # interactive block-device migration
sudo utilities/setup-storage.sh --mode migrate status  # migration status
```

---

### `setup-env.sh` — Environment file generation

Creates or updates `.env` and `docker-compose.yml` from templates. Idempotent:
files are not overwritten unless values have changed or `--force` is passed.

```bash
sudo utilities/setup-env.sh --domain vault.example.com --email admin@example.com
sudo utilities/setup-env.sh --domain vault.example.com --email admin@example.com --force
```

---

### `setup-secrets.sh` — Secrets management

Full secrets lifecycle: setup, rotation, recovery-kit export, and emergency
break-glass admin. Consolidates the former standalone break-glass helper.

```bash
sudo utilities/setup-secrets.sh configure             # full interactive secrets setup
sudo utilities/setup-secrets.sh configure --auto      # auto-generate passwords
sudo utilities/setup-secrets.sh rotate admin_token    # rotate one credential
sudo utilities/setup-secrets.sh rotate                # rotate all credentials
sudo utilities/setup-secrets.sh export-recovery-kit

# Emergency break-glass admin (OCI serial console recovery)
sudo utilities/setup-secrets.sh breakglass create
sudo utilities/setup-secrets.sh breakglass status
sudo utilities/setup-secrets.sh breakglass remove --force
```

---

### `setup-systemd.sh` — systemd timer management

Installs, validates, and removes the VaultWarden systemd timer suite.

```bash
sudo utilities/setup-systemd.sh install    # install and enable all timers
sudo utilities/setup-systemd.sh remove     # disable and remove all timers
sudo utilities/setup-systemd.sh validate   # check installed state vs repo
sudo utilities/setup-systemd.sh status     # show timer status
sudo utilities/setup-systemd.sh install --dry-run
```

---

### `setup-crowdsec.sh` — CrowdSec installation

Installs or re-installs CrowdSec and the Cloudflare firewall bouncer.
Do not modify — standalone and version-pinned.

```bash
sudo utilities/setup-crowdsec.sh
```

---

### `uninstall-vaultwarden.sh` — Full project teardown

Removes all VaultWarden-OCI components. After it completes, `setup.sh install`
can run on the same host as if it were a fresh machine.

Does **NOT** remove: Docker CE, system packages, user accounts, swap, or
anything that pre-existed this project.

```bash
sudo utilities/uninstall-vaultwarden.sh run --dry-run
sudo utilities/uninstall-vaultwarden.sh run --i-have-saved-my-recovery-kit
sudo utilities/uninstall-vaultwarden.sh run --force   # CI/automation only
```

---

## Design Principles

| Principle | Enforcement |
|---|---|
| **Idempotent** | Check-before-act everywhere (`grep -q`, `iptables -C`, `dpkg -s`) |
| **Self-sufficient** | Each script has its own arg parser; runs standalone |
| **No env-var IPC** | CLI flags only for inter-script state |
| **Dry-run complete** | Every destructive action gated by `DRY_RUN` check |
| **Root guard** | `(( EUID == 0 ))` checked after arg parsing |
| **Colour-tagged output** | `[HH:MM:SS] [script-name.sh] LEVEL message` via `lib/common.sh` |
