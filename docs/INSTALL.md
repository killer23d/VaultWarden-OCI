# Install

## Prerequisites

Use a clean Ubuntu 24.04 LTS VM on `amd64` or `arm64`. Attach a dedicated ext4/xfs data filesystem that is separate from the boot/root block-device family. Production state is mounted at `/var/lib/vaultwarden-oci`; that path is never a supported root-filesystem fallback.

Inspect storage read-only before setup:

```bash
findmnt -n -o SOURCE,FSTYPE,TARGET --target /
lsblk -p -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,UUID,MODEL
```

For fully headless noninteractive setup, create an offline Age identity on a trusted separate workstation and keep its private key off the appliance. Pass only its `age1...` public recipient to setup. When `--auto` is run from an interactive terminal and no `--offline-recipient` is supplied, setup instead generates the offline identity transiently and hands it off through the verified encrypted recovery kit after installation. If `--offline-recipient` is supplied, that explicit recipient is authoritative and setup does not generate a replacement.

On a clean Ubuntu host, terminal-generated custody does not assume `age-keygen` is already installed. Before generating the transient offline identity, setup bootstraps and verifies the Ubuntu `age` package through the setup dependency owner. This prerequisite happens before the offline private identity is created and before dedicated-storage provisioning; if the Age bootstrap fails, setup stops without generating custody material or formatting/adopting the data device.

**Expected success:** a clearly separate candidate volume is visible. **On failure:** attach or correct dedicated storage before continuing; do not create application state on `/`.

## What `--domain`, `--url`, and `--email` mean

- `--domain` is the DNS name/base used to validate the intended site. It can be the exact vault hostname or a base such as `example.com`.
- `--url` is the exact simple HTTPS public URL. Its host must equal `--domain` or `vault.<domain>`. The normalized URL host becomes the single runtime `[site].domain`; the URL is not stored as a second authority.
- `--email` is the administrator/ACME contact written to `[site].acme_email`. Setup also prepopulates `smtp.from_email` as `vaultwarden@<resolved-site-host>`.

Setup creates the operator config skeleton, operational Age identity, encrypted SOPS document, immutable installed release, storage identity/marker, and systemd storage guard. It does not invent external SMTP, Cloudflare, notification-provider, or rclone credentials.

## Interactive blank-VM install

**Prerequisite:** Ubuntu 24.04, root access, Internet access for dependencies, and an attached non-boot data volume.

```bash
sudo ./setup.sh install \
  --domain example.com \
  --url https://vault.example.com \
  --email admin@example.com
```

Interactive setup lists plausible non-boot devices with size/filesystem/mount/model. Adopting an existing ext4/xfs filesystem requires explicit acknowledgement. Formatting a blank device requires an independent confirmation. If no acceptable separate volume exists, setup exits instead of falling back to root storage.

When no `--offline-recipient` is supplied in an interactive TTY, setup generates that private identity only in root-owned volatile `/run` storage, creates and verifies a complete encrypted recovery-kit ZIP, and removes the transient identity only after authenticated email handoff or the exact off-host custody acknowledgement requested by setup. The same custody behavior applies to terminal-driven `--auto`.

**Expected success:** setup ends in `PASS` with a dedicated mounted/identified volume and an explicit external-config/recovery-custody checkpoint. **On failure:** follow the displayed `ACTION`; if setup says a transient offline identity remains, secure it before reboot, correct the cause, and rerun the same command.

## Automatic `--auto` setup

`--auto` automates install decisions that were supplied explicitly; it never guesses storage, never implies format/adoption consent, and does not imply `--use-latest`. It does not necessarily mean that no human is present for recovery custody.

When `--auto` is launched from an interactive terminal, omitting `--offline-recipient` uses the same transient offline-identity and verified recovery-kit custody flow described above. The install steps remain automatic, but the recovery-kit passphrase and final custody acknowledgement remain interactive security boundaries.

Terminal-driven automatic install with setup-generated offline recovery custody:

```bash
sudo ./setup.sh install \
  --domain example.com \
  --url https://vault.example.com \
  --email admin@example.com \
  --data-device /dev/disk/by-id/your-data-volume \
  --confirm-format \
  --auto
```

A fully headless `--auto` run has no safe channel to hand a newly generated private identity to an absent operator, so it must receive an existing public `--offline-recipient`.

Existing ext4/xfs filesystem with pre-existing offline custody:

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

Both `--offline-recipient age1...` and `--offline-recipient=age1...` are normal CLI value forms. If a recipient is explicitly supplied, setup preserves that choice and never silently substitutes a generated recipient.

For a blank device that setup is allowed to format, use `--confirm-format` instead of `--accept-existing-filesystem`. An interrupted blank-device setup may accept the same `--confirm-format --auto` rerun only when the independent host identity and volume marker prove that the filesystem is the one initialized by that prior attempt.

**Expected success:** the selected device is the canonical dedicated state filesystem and exact release content is installed. If setup generated the offline identity, success also includes a verified encrypted recovery-kit handoff containing the generated credential values and both Age private identities, followed by removal of the transient offline private identity from the host. **On failure:** do not switch devices or confirmations casually; inspect the reported identity/mount condition first. Fully headless `--auto` without an offline recipient must fail before storage provisioning or other install mutations.

## Explicit `--use-latest`

Normal setup uses the repository-tested exact pins. `--use-latest` is an independent explicit override. It resolves each supported mutable upstream boundary once and freezes exact component refs and architecture image digests; it must not leave floating `latest` state.

```bash
sudo ./setup.sh install \
  --domain example.com \
  --url https://vault.example.com \
  --email admin@example.com \
  --data-device /dev/disk/by-id/your-data-volume \
  --offline-recipient age1... \
  --accept-existing-filesystem \
  --use-latest \
  --auto
```

When `--use-latest` is used without `--auto` in a terminal, setup asks for confirmation before proceeding. `--auto` is itself the explicit non-prompting acknowledgement for the use-latest warning; the release values are still resolved once and frozen exactly.

**Expected success:** one exact resolved snapshot is recorded. **On failure:** use the tested pinned path unless you intentionally require the current upstream snapshot; never replace exact values with literal floating tags.

## Dry run

`--dry-run` performs host/input/device-relationship checks without formatting, mounting, dependency installation, or project-state writes. Use it to prove a storage selection before changing a host. Dry run does not generate an offline private identity or create a recovery kit.

## Complete config and secrets

Routine administration does not require teaching a junior admin raw SOPS commands. Use the supported transactions:

```bash
sudo vwctl config edit
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
sudo vwctl secrets edit
sudo vwctl secrets validate
```

Complete external settings such as SMTP, Cloudflare, the operational notification provider, and rclone access. These editors validate protected candidates before replacement; invalid candidates leave the installed authority unchanged.

**Expected success:** validation passes and `sudo vwctl doctor --json` has no configuration/custody `FAIL`. **On failure:** correct the reported config or custody issue through the same editors; do not place plaintext secrets in `config.toml`, shell arguments, or release files.

## First start and persistent automation

```bash
sudo vwctl doctor --json
sudo vwctl start
sudo vwctl status
sudo vwctl doctor --json
```

After the first healthy start:

```bash
sudo systemctl enable --now vaultwarden-oci.target
systemctl status vaultwarden-oci.target
sudo vwctl timers
```

**Expected success:** Vaultwarden/Caddy are healthy, storage identity passes, and the target/timers are active. **On failure:** use `sudo vwctl logs --tail 200`, `journalctl -u vaultwarden-oci.service`, and the named doctor check before retrying.

## Dedicated-storage proof and safe reruns

Runtime acceptance requires `/var/lib/vaultwarden-oci` to be a real mount distinct from `/`, not from the root block family, ext4/xfs with a stable UUID, equal to `/etc/vaultwarden-oci/storage-identity.json`, and carrying the matching volume ownership marker. Docker has a systemd mount guard so a reboot with the intended volume absent cannot silently recreate application paths on the boot filesystem.

Setup is rerunnable after interruption. It proves existing fstab/storage identity, immutable releases, operational Age identity, config, and encrypted secrets before replacement. A customized valid operator config is not silently overwritten. If setup generated an offline identity and reports that it remains in volatile storage after a failed custody handoff, secure that exact identity before reboot; do not rerun in a way that silently creates a different recovery identity for already-written recipients.

Continue with [Operations](OPERATIONS.md), then establish and verify recovery using [Recovery](RECOVERY.md).