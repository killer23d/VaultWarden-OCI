# Install

## Supported production host

VaultWarden-OCI supports Ubuntu 24.04 LTS on `amd64` and `arm64`.

Production persistent application state **must** live on a dedicated ext4/xfs filesystem separate from the boot/root filesystem. A root-only host is rejected. The canonical state mount is `/var/lib/vaultwarden-oci`; it is not a supported root-filesystem fallback.

## Before setup

Attach a dedicated data volume and identify it with read-only host tools:

```bash
findmnt -n -o SOURCE,FSTYPE,TARGET --target /
lsblk -p -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,UUID,MODEL
```

Also create an offline Age identity on a separate trusted workstation and retain its private key away from the appliance. Setup needs only its public `age1...` recipient.

Do not select the boot disk, its parent, or any child device containing `/`.

## Normal first-run path

The supported first-run interface is `setup.sh`:

```bash
sudo ./setup.sh install \
  --domain example.com \
  --url https://vault.example.com \
  --email admin@example.com \
  --data-device /dev/disk/by-id/your-data-volume \
  --offline-recipient age1...
```

Interactive setup may omit `--data-device`; it lists plausible non-boot block devices with size, filesystem, mount, and model information and asks the operator to choose. If no acceptable separate volume exists, setup exits without falling back to `/`.

`--url` is validated against `--domain` and normalized to the runtime hostname. The URL is not persisted as a second configuration authority; `[site].domain` remains authoritative.

### Existing filesystem adoption

Existing ext4/xfs storage is never adopted silently. Interactive setup requires the exact `YES` confirmation. Noninteractive setup requires the deliberately named acknowledgement:

```bash
--accept-existing-filesystem
```

Unknown filesystem types and unknown on-disk signatures fail closed.

### Blank-device formatting

A blank device is formatted as ext4 only after an independent destructive acknowledgement:

```bash
--confirm-format
```

`--auto` never implies this acknowledgement and never authorizes disk guessing.

### Noninteractive setup

`--auto` permits safe locally generated/defaultable choices but still requires an explicit data device and offline recovery public recipient:

```bash
sudo ./setup.sh install \
  --domain example.com \
  --url https://vault.example.com \
  --email admin@example.com \
  --data-device /dev/disk/by-id/your-data-volume \
  --offline-recipient age1... \
  --accept-existing-filesystem \
  --auto
```

External Cloudflare, SMTP, notification, and rclone credentials are never invented.

### Dry run

`--dry-run` validates the host, operator inputs, and selected device/boot relationship without formatting, mounting, installing packages, or writing project state.

### `--use-latest`

The normal path uses repository-tested exact pins. `--use-latest` is an independent explicit override: setup resolves the supported mutable component boundaries once, freezes exact versions and image digests into the immutable installed release, records that frozen set, and never persists a floating `latest` tag.

`--auto` does not imply `--use-latest`.

## What setup installs

After the dedicated-storage preflight succeeds, setup installs/verifies the Ubuntu dependencies used by the appliance, Docker Engine/Compose from Docker's supported Ubuntu repository, exact-pinned SOPS, Age, rclone, and 7-Zip. It then installs the immutable application release and systemd integration.

The installed authorities are:

```text
/opt/vaultwarden-oci/releases/<version>  immutable release content
/opt/vaultwarden-oci/current             active-release selector
/usr/local/bin/vwctl                     authoritative operator CLI
/etc/vaultwarden-oci/config.toml         operator-editable non-secret config
/etc/vaultwarden-oci/secrets.sops.yaml   encrypted secret document
/etc/vaultwarden-oci/age-key.txt         root-only operational Age identity
/var/lib/vaultwarden-oci                 dedicated persistent state mount
/run/vaultwarden-oci                     volatile generated/decrypted material
```

Setup safely generates the operational Age identity if absent, prepopulates normal site/email configuration, and creates an encrypted SOPS starting point containing locally generated admin material. Plaintext generated secrets are passed to SOPS over stdin, not argv or ordinary logs. The offline private Age identity is never stored on the server.

## Dedicated-storage identity and boot guard

Setup writes the persistent mount by filesystem UUID and stores a small identity marker on the selected filesystem itself:

```text
/var/lib/vaultwarden-oci/.vaultwarden-oci-volume.json
```

At runtime, `vwctl start`, `restart`, `backup`, `restore`, recovery mutation, update, and direct install entrypoints verify all of the following before proceeding:

- `/var/lib/vaultwarden-oci` is an actual mount point;
- its filesystem differs from `/`;
- its block device is not the boot/root device or its parent/child;
- the filesystem is ext4/xfs and has a stable UUID;
- the mounted UUID/type match the project identity marker.

`vwctl doctor` reports this as the `storage.dedicated` check.

Setup also installs a Docker systemd drop-in with `RequiresMountsFor=/var/lib/vaultwarden-oci` and a mount-point condition. This prevents Docker's `restart: unless-stopped` behavior from recreating Vaultwarden state paths on the boot filesystem when the dedicated mount is absent during boot.

There is no boot-to-data migration mode. This is a fresh-install product.

## Re-running setup

Setup is intended to be safely re-run after an interrupted first run. Dedicated storage provisioning, UUID fstab ownership, the mount guard, immutable release installation, Age identity creation, and generated starting files are checked before replacement. Existing operator configuration is not silently overwritten after it has been customized.

If a step fails, correct the reported condition and re-run the same setup command; do not rebuild the VM merely to restart setup.

## Complete external configuration

Setup deliberately does not invent external credentials. Complete the supported config/secrets workflow for Cloudflare, SMTP, notification API credentials, and rclone as applicable, then validate:

```bash
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
sudo env SOPS_AGE_KEY_FILE=/etc/vaultwarden-oci/age-key.txt \
  sops decrypt /etc/vaultwarden-oci/secrets.sops.yaml >/dev/null
sudo vwctl doctor --json
```

Treat any doctor `FAIL` as a failed acceptance condition.

## First start

When configuration, secret custody, and doctor checks are ready:

```bash
sudo vwctl start
sudo vwctl status
sudo vwctl doctor --json
```

Then enable the supported lifecycle target/timers as appropriate:

```bash
sudo systemctl enable --now vaultwarden-oci.target
systemctl status vaultwarden-oci.target
systemctl list-timers 'vaultwarden-oci-*'
```

Continue with [OPERATIONS.md](OPERATIONS.md), [RECOVERY.md](RECOVERY.md), and [HOST-ACCEPTANCE.md](HOST-ACCEPTANCE.md).

## Intentionally separate workstreams

This setup workstream does not implement the day-2 dashboard, recovery-kit email UI, boot-volume migration, or a replacement application-update workflow. Those remain separate bounded workstreams under the durable product contract.
