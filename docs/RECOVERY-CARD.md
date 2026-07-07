<!-- TEMPLATE — do not print this file.
     The rendered copy with your site's real values is at:
       ${PROJECT_STATE_DIR}/config/recovery-card.md
     Fill in CONTACT_NAME and CONTACT_PHONE before printing.
-->
# Vaultwarden Recovery Card
Store this card with the offline Age recipient private-key USB drive.

## Before you start
- This printed card with contact details filled in
- USB drive containing `age-key.txt`
- provider console access for the replacement VM and firewall/security-group rules

## Step 1 — Create a supported Ubuntu LTS VM
Use Ubuntu 24.04 LTS Noble on amd64 or arm64.

## Step 2 — Attach the data volume and identify the device
```bash
lsblk
```
Find the attached volume device, for example `/dev/sdb`.

## Step 3 — Clone the recorded repository version
```bash
sudo git clone <REPO_URL> /opt/VaultWarden-OCI
sudo git -C /opt/VaultWarden-OCI checkout <REPO_COMMIT>
cd /opt/VaultWarden-OCI
```

## Step 4 — Install prerequisites and adopt the existing volume
```bash
sudo ./utilities/setup-system.sh --auto \
  --data-mount /mnt/vw-data
sudo DATA_VOLUME_EXISTING_FS_OK=true \
  ./utilities/setup-storage.sh setup \
    --data-device /dev/sdb \
    --data-mount /mnt/vw-data
```
Replace `/dev/sdb` with the device found through `lsblk`.

## Step 5 — Run recovery
```bash
sudo ./recover.sh \
  --state-dir /mnt/vw-data \
  --key /media/usb/age-key.txt
```

## Step 6 — Reinstall managed services
```bash
sudo PROJECT_STATE_DIR=/mnt/vw-data \
  ./utilities/setup-systemd.sh install
```

## Step 7 — Verify
Open `<DOMAIN>` in a browser. If login works, recovery is complete.

## If something fails
The script prints the failure and stops.
Contact: `<CONTACT_NAME>` — `<CONTACT_PHONE>`
