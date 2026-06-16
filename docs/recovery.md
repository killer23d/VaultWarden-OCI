# VaultWarden-OCI Recovery Runbook

## Off-host items required

Keep these outside the VM and outside the repository:

- A snapshot or copy of the persistent state volume.
- The operational Age private key, or the offline recovery Age private key.
- The public offline Age recipient recorded in `config/sops-policy.yaml`.
- The repository ref from `config/dr-manifest.env` (`REPO_REF`).
- Any provider metadata needed to attach the copied/snapshotted block volume.

The offline recovery private key must never live on the host. Only its public recipient is stored in the SOPS policy.

## State layout

Authoritative encrypted state lives under `PROJECT_STATE_DIR` (default `/var/lib/vaultwarden`):

```text
config/install.env
config/sops-policy.yaml
config/dr-manifest.env
secrets/secrets.sops.yaml
data/
caddy/
logs/
backups/
.vw-state-volume
```

Plaintext runtime secret files are materialized only under `/run/vaultwarden-oci/secrets/` and are mounted into containers as `/run/secrets/*`. Do not store decrypted secrets, Age private keys, CrowdSec local credentials, or recovery kits on the block volume.

## Clean VM recovery

1. Provision a clean Ubuntu host.
2. Attach and mount the copied/snapshotted state volume at the path recorded by `EXPECTED_STATE_DIR` in `config/dr-manifest.env`.
3. Check out the repository and ref recorded by `REPO_REF`.
4. Run recovery with an explicit key file:

```bash
sudo ./setup.sh recover \
  --state-dir /mounted/state/path \
  --age-key-file /path/to/age-key.txt
```

Recovery fails closed unless the supplied state dir is a mount point, `STATE_LAYOUT_VERSION=2`, the manifest and `.vw-state-volume` `INSTALLATION_ID` values match, `EXPECTED_STATE_DIR` equals the supplied path, `install.env` parses safely, and the Age key decrypts `secrets/secrets.sops.yaml`.

Only after those checks does recovery install the operational key to `/etc/vaultwarden/age-key.txt`, regenerate host configuration, materialize runtime secrets under `/run`, start the Compose stack, and run health checks.

## Offline-key recovery

If the operational key is lost, retrieve the offline recovery private key from off-host storage and pass it with `--age-key-file`. Do not paste private keys into the command line, environment variables, or stdin.

## Health verification

After recovery, verify:

```bash
./maintenance.sh status
./maintenance.sh health
./maintenance.sh logs vaultwarden
```

Also confirm application login, outbound email, Caddy TLS, backups, restore listing, and CrowdSec bouncer status on a real Ubuntu host.

## Backup keys

Backups use `backup_key_current`. Restore attempts `backup_key_current` first and then `backup_key_previous`. Rotation moves current to previous, generates a new current, and records `backup_key_rotated_at` in UTC. Rotation is blocked while the longest effective retention window has not elapsed, or when any effective retention tier is `0`, until the operator removes, re-encrypts, or explicitly verifies backups protected by the previous key.

## Migration and legacy files

`./setup.sh migrate-state [STATE_DIR]` performs a non-destructive copy of legacy repository files into the persistent layout and writes `dr-manifest.env` plus `.vw-state-volume`. It does not delete legacy files, modify systemd, restart services, or activate the new path. Keep legacy `.env`, `.sops.yaml`, and `secrets/secrets.yaml` until a clean-VM recovery drill has proven the new state volume.

## Manual DR drill

At least once after migration and after major changes:

1. Snapshot or copy the state volume.
2. Boot a clean VM.
3. Attach the copied/snapshotted state volume.
4. Mount it at `EXPECTED_STATE_DIR`.
5. Check out `REPO_REF`.
6. Run `setup.sh recover` with the operational key.
7. Repeat with the offline recovery key in a separate drill if possible.
8. Verify health, login, email, backups, restore fallback, and CrowdSec before considering recovery proven.
