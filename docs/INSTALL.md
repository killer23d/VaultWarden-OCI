# Install

## Supported production host

VaultWarden-OCI supports Ubuntu 24.04 LTS on `amd64` and `arm64`.

Production persistent application state **must** live on a dedicated ext4/xfs filesystem separate from the boot/root filesystem. A root-only host is rejected. The canonical state mount is `/var/lib/vaultwarden-oci`; it is never a supported root-filesystem fallback.

## Before setup

Attach a dedicated data volume and inspect the host with read-only tools:

```bash
findmnt -n -o SOURCE,FSTYPE,TARGET --target /
lsblk -p -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,UUID,MODEL
```

Create an offline Age identity on a separate trusted workstation and keep its private key off-host. Setup receives only its public `age1...` recipient.

## Supported first run

```bash
sudo ./setup.sh install \
  --domain example.com \
  --url https://vault.example.com \
  --email admin@example.com \
  --data-device /dev/disk/by-id/your-data-volume \
  --offline-recipient age1...
```

Interactive setup may omit `--data-device`; it lists plausible non-boot devices with size, filesystem, mount, and model information. No acceptable separate volume means setup exits without falling back to `/`.

`--url` is normalized/validated against `--domain`; `[site].domain` remains the single runtime authority.

Existing ext4/xfs adoption requires interactive `YES` or `--accept-existing-filesystem`. Blank-device ext4 formatting requires independent `--confirm-format`. Unknown filesystem types, mixed/unknown signatures, the boot disk, and its parent/children fail closed. `--auto` never guesses storage and never implies either acknowledgement.

Noninteractive setup therefore supplies the storage and custody decisions explicitly. For an existing filesystem use `--accept-existing-filesystem`; for a blank device use `--confirm-format`. If a blank-device setup is interrupted after formatting, the exact same `--confirm-format --auto` command is accepted on rerun only when the host-side identity and mounted-volume marker both prove that the now-existing filesystem is the one initialized by the prior setup attempt.

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

`--dry-run` performs host/input/device relationship checks without formatting, mounting, package installation, or project-state writes. `--use-latest` is independent of `--auto`; it resolves mutable upstream boundaries once and freezes exact versions/digests for that install. The normal path uses repository-tested exact pins.

## Setup ownership

After storage preflight, setup installs/verifies required Ubuntu packages, Docker Engine/Compose from Docker's Ubuntu repository, SOPS, Age, rclone, and 7-Zip. The downloaded SOPS binary is verified against the pinned architecture-specific SHA-256 before installation.

Durable authorities include:

```text
/opt/vaultwarden-oci/releases/<version>          immutable release content
/opt/vaultwarden-oci/current                     active-release selector
/usr/local/bin/vwctl                             authoritative operator CLI
/etc/vaultwarden-oci/config.toml                 operator-editable non-secret config
/etc/vaultwarden-oci/secrets.sops.yaml           encrypted secret document
/etc/vaultwarden-oci/age-key.txt                 root-only operational Age identity
/etc/vaultwarden-oci/storage-identity.json       host-side expected data-volume identity
/var/lib/vaultwarden-oci                         dedicated persistent state mount
/var/lib/vaultwarden-oci/.vaultwarden-oci-volume.json  volume ownership marker
/run/vaultwarden-oci                             volatile generated/decrypted material
```

Setup validates generated TOML through the canonical runtime parser before reporting it ready. Existing nonempty SOPS state is not accepted merely because a file exists: its recipients and operational decryptability must still validate. Generated secret plaintext is supplied to SOPS through stdin, not argv.

## Dedicated-storage proof and boot guard

The host-side expected identity under `/etc` is independent of the selected data volume. Runtime verification requires all of the following:

- `/var/lib/vaultwarden-oci` is an actual mount point and differs from `/`;
- the source is not the boot/root block family;
- the filesystem is ext4/xfs with a stable UUID;
- the mounted UUID/type match `/etc/vaultwarden-oci/storage-identity.json`;
- the filesystem's ownership marker matches that same host-side identity.

This prevents a different independently initialized volume from authenticating merely from its own marker. The identity is UUID/type based, so a true block-level clone that preserves the filesystem UUID and marker is not distinguishable by this mechanism; the design does not claim physical-device attestation.

Provisioning reconciles an already-mounted canonical path **before** changing the host identity or `/etc/fstab`. If setup is rerun with volume A mounted but volume B selected, it fails without rewriting next-boot storage to B. Only after the selected/live filesystem agrees does setup persist the UUID mount, host identity, volume marker, and Docker guard.

All CLI paths that can directly or indirectly persist project state are storage-gated, including lifecycle/recovery/update plus `notify`, edge refresh, and CrowdSec operations. This prevents the systemd `OnFailure` notifier or edge LKG writers from recreating `/var/lib/vaultwarden-oci/state` on `/` when the mount is absent.

Docker also receives a systemd drop-in using `RequiresMountsFor=/var/lib/vaultwarden-oci` and `ConditionPathIsMountPoint=/var/lib/vaultwarden-oci`, preventing Docker's own restart policy from recreating application paths on the boot filesystem when dedicated storage is absent during boot.

There is no boot-to-data migration mode; this is a greenfield install path.

## Safe reruns

Setup is intended to be rerun after interruption. Storage identity, fstab ownership, mount guard, immutable release, Age identity, generated config, and encrypted-secret starting state are proven before replacement. Customized operator config is not silently overwritten.

If a step fails, correct the reported condition and rerun the same setup command. Expected operational failures, including version-resolution/network errors, invalid encrypted-secret metadata, and setup lock contention, are reported through the supported `FAIL`/`ACTION` UI rather than as Python tracebacks.

## Complete external configuration

Setup does not invent Cloudflare, SMTP, notification API, or rclone credentials. Complete those through the supported config/secrets workflow, then validate:

```bash
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
sudo env SOPS_AGE_KEY_FILE=/etc/vaultwarden-oci/age-key.txt \
  sops decrypt /etc/vaultwarden-oci/secrets.sops.yaml >/dev/null
sudo vwctl doctor --json
```

Treat any doctor `FAIL` as a failed acceptance condition. When configuration and custody are ready:

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

This workstream does not implement the day-2 dashboard, recovery-kit email UI, boot-volume migration, or a replacement application-update workflow.
