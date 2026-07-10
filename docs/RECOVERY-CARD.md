<!-- TEMPLATE — do not print this file directly.
     The rendered copy with your site's real values is at:
       ${PROJECT_STATE_DIR}/config/recovery-card.md
     Fill in CONTACT_NAME and CONTACT_PHONE before printing.
-->
# Vaultwarden Recovery Card

Store this card separately from the server and backups. Keep the required offline Age private key or other recorded recovery material in a secure location you can access during a server-loss event.

## Before you start

You need:

- this recovery card with contact details filled in;
- the offline Age private key that matches `OFFLINE_AGE_RECIPIENT` in the recovery manifest;
- provider-console access for the replacement host and its upstream firewall/security-group rules;
- access to the repository commit recorded by the recovery manifest.

## Step 1 — Create a supported host

Use Ubuntu 24.04 LTS Noble on amd64 or arm64.

## Step 2 — Attach and identify the restored data volume

```bash
lsblk -f
findmnt
```

Identify the attached volume that contains the VaultWarden state directory and `.vw-data-volume` sentinel. Prefer a stable `/dev/disk/by-id/...` or `/dev/disk/by-uuid/...` identity when your platform exposes one.

Do **not** format the restored volume.

## Step 3 — Clone the recorded repository version

```bash
sudo git clone <REPO_URL> /opt/VaultWarden-OCI
sudo git -C /opt/VaultWarden-OCI checkout <REPO_COMMIT>
cd /opt/VaultWarden-OCI
```

`recover.sh` intentionally refuses a repository commit that does not match `REPO_COMMIT` in the state-volume recovery manifest.

## Step 4 — Install host prerequisites

```bash
sudo ./utilities/setup-system.sh --auto
```

This validates the supported Noble/amd64-or-arm64 host and installs the repository-owned Docker, SOPS, Age, rclone, SQLite, zstd, and related command dependencies.

## Step 5 — Mount/adopt the existing data volume

Mount the existing filesystem at the recorded state mount. Do not use `--force-format` or `DATA_VOLUME_FORCE_FORMAT=true` during recovery of an existing volume.

Example:

```bash
sudo DATA_VOLUME_EXISTING_FS_OK=true \
  ./utilities/setup-storage.sh setup \
    --data-device /dev/disk/by-id/<your-restored-volume> \
    --data-mount /mnt/vw-data
```

Replace the device path and mount point with the values for this deployment.

## Step 6 — Run state-volume recovery

```bash
sudo ./recover.sh \
  --state-dir /mnt/vw-data \
  --key /secure/path/offline-age-key.txt
```

The offline recovery key is used in place. Recovery generates a replacement operational Age key for the server and does not install the offline private key as the live operational key.

If recovery exits non-zero, stop and read the printed failure/next-step guidance. Do not improvise by copying keys between paths until you understand whether recovery failed before or after its commit boundary.

## Step 7 — Inspect the recovered host

Before enabling scheduled jobs, verify:

```bash
sudo utilities/repair-permissions.sh --check
sudo ./maintenance.sh health
sudo ./maintenance.sh test-email --verbose
```

Check Cloudflare/DNS, provider ingress, rclone configuration, and the restored storage mount.

## Step 8 — Activate systemd automation

When the host is genuinely ready for scheduled backup, maintenance, health, DNS, and firewall work:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

A successful browser login alone is not the production-ready gate. `systemd validate` and the smoke test must pass without required checks being skipped.

## If something fails

The recovery tools print the failure and stop. Preserve the state directory, recovery key, and command output for diagnosis.

Contact: `<CONTACT_NAME>` — `<CONTACT_PHONE>`
