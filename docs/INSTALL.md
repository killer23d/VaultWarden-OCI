# Install VaultWarden-OCI

This is the **first-time, interactive installation** guide. The installer handles Docker, Caddy, CrowdSec, SOPS, Age, and other dependencies. You do not need to configure those components by hand.

## 1. Prepare the server and accounts

| You need | What to prepare |
| --- | --- |
| Ubuntu | Fresh **24.04 LTS or 26.04 LTS**, `amd64` or `arm64`, sudo access and Internet |
| Separate data disk | A non-boot disk or ext4/xfs filesystem for vault data |
| Cloudflare | Your domain, a **Proxied** IPv4 A record, and **two** API tokens |
| SMTP | Server hostname, port, security mode, allowed sender address, username and password |
| Recovery storage | A safe place **off the server** for a recovery-kit ZIP and another safe place for its passphrase |

**Disk safety:** Setup refuses production storage on the boot disk. Formatting the wrong separate disk can still destroy its contents. **Check the device name and size before confirming.**

A few terms: **A record** means hostname-to-IPv4; **Proxied** means Cloudflare's orange cloud; **DNS sync / DDNS** keeps that *existing* A record's address current; **offline Age identity** is the private key you keep off the server for recovery.

## 2. Prepare Cloudflare DNS and tokens

In Cloudflare DNS, create or confirm a record like this:

| Field | Example |
| --- | --- |
| Type | `A` |
| Name | `vault` (for `vault.example.com`) |
| Content | Your server's public IPv4, or the old origin's IPv4 during a planned move |
| Proxy | **Proxied** (orange cloud) |

There must be **exactly one A record** for the final vault hostname, with **no explicit AAAA record**. The updater does not create records, enable the proxy, or publish IPv6. If you are replacing an existing server, **do not move the A record to the new IP until the new app starts**.

Create **two separate Cloudflare user API tokens** using [Cloudflare tokens](CLOUDFLARE-TOKENS.md):

- `cloudflare_api_token` — Zone / Zone / Read and Zone / DNS / Edit on your zone; used for Caddy certificate challenges **and DNS updates**.
- `cloudflare_remediation_token` — separate, broader CrowdSec Worker token; required for the standard first-run security setup.

The appliance discovers Cloudflare Zone ID and Account ID itself. It also generates its local CrowdSec bouncer credential; you do not need to supply those.

Prepare an authenticated SMTP account. Use `starttls` for a provider's port 587 or `force_tls` for implicit TLS on 465, as your provider instructs. Make sure your chosen sender address is allowed. Operational HTTPS failure notifications are **optional**, not part of basic SMTP setup.

## 3. Download the correct code and identify the disk

In the Ubuntu terminal:

```bash
sudo apt-get update
sudo apt-get install -y git
git clone --branch v2 --single-branch https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
```

The branch is explicit because the repository's default branch is a different implementation.

Inspect storage **without changing it**:

```bash
findmnt -n -o SOURCE,FSTYPE,TARGET --target /
lsblk -p -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,UUID,MODEL
```

Compare the root/boot device with the separate disk. The installer will show plausible non-boot choices again.

## 4. Run interactive setup

Replace the example values with your own:

```bash
sudo ./setup.sh install \
  --domain example.com \
  --url https://vault.example.com \
  --email admin@example.com
```

`--domain` is the base domain or exact vault hostname, `--url` is the exact public HTTPS vault URL, and `--email` is your administrator/certificate contact. The URL host must equal the domain or `vault.<domain>`.

Follow the prompts in order:

1. **Disk:** select the separate volume. Approve adopting an existing ext4/xfs filesystem or, separately, confirm formatting a blank disk **only after checking the device**.
2. **SMTP config:** in the validated config editor, replace `smtp.invalid` with your SMTP host and set port, security and sender. This lives in `/etc/vaultwarden-oci/config.toml`.
3. **Encrypted secrets:** in the secrets editor, enter the two Cloudflare tokens and `smtp_username`/`smtp_password`. Keep the already generated admin credentials. The encrypted file is `/etc/vaultwarden-oci/secrets.sops.yaml`.
4. **Recovery kit:** if you did not supply an existing offline public recipient, interactive setup creates the offline recovery private identity temporarily, packs it into a **verified AES-256 ZIP**, and prompts for its passphrase and handoff. Keep the kit **off the server** and store its passphrase separately. Complete the exact acknowledgement or verified email handoff before rebooting.

Setup may finish successfully while the **vault is still stopped**. Follow its next-actions output and continue below. If a key handoff fails, **secure the exact transient key before reboot**; do not rerun with a new key for already-encrypted secrets. See [Recovery](RECOVERY.md#recovery-kit-export-and-first-run-handoff).

## 5. Review and validate settings

If setup did not already complete the editors (for example, when you supplied a pre-existing public offline recovery recipient), run:

```bash
sudo vwctl config edit
sudo vwctl secrets edit
```

| Encrypted SOPS field | First-install requirement |
| --- | --- |
| `cloudflare_api_token` | Required for DNS/certificates |
| `cloudflare_remediation_token` | Required for standard CrowdSec Worker setup |
| `smtp_username`, `smtp_password` | Required for authenticated SMTP |
| `vaultwarden_admin_token`, `admin_basic_auth_password` | Generated; normally keep unchanged |
| `email_api_token` | Only if enabling optional HTTPS failure alerts |

Only edit with the supported commands; do not paste secrets into the non-secret TOML file or shell arguments. A successful config/secrets editor may offer a restart if the stack is already running.

## 6. Validate and activate security

Run **in this order**, stopping to fix any `FAIL`:

```bash
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
sudo vwctl secrets validate
sudo vwctl dns update --dry-run
sudo vwctl notification test --smtp
sudo vwctl crowdsec setup
sudo vwctl crowdsec remediation-start
```

- The DNS dry run checks the single existing Proxied A record and Cloudflare permissions **without moving public traffic**.
- The SMTP test sends a **real** test message; check your provider settings if it fails.
- CrowdSec setup and remediation start prepare the security services.

**Manual Cloudflare step:** open the Cloudflare dashboard, find **every Worker Route created by the CrowdSec bouncer**, and set its failure behavior to **Fail Open**. This is a required safety step for the **current** Worker invocation. Then:

```bash
sudo vwctl crowdsec confirm-fail-open
```

Do not skip that confirmation, even if other security services show healthy status.

## 7. Start, update DNS, and create the first backup

After all checks above pass:

```bash
sudo vwctl start
sudo vwctl dns update
sudo vwctl backup
sudo vwctl doctor --json
sudo vwctl status
```

`start` brings up the app and its protected runtime. **Only after start**, `dns update` writes the server's public IPv4 to the **existing** proxied A record if different; Cloudflare is read back to verify it. The first `backup` creates and verifies an encrypted `.vwrec` application recovery point, which is **not** your credential recovery-kit ZIP.

`doctor --json` is the post-start acceptance check. **Any `FAIL` must be fixed before continuing.** A `WARN` for unconfigured offsite/rclone recovery is expected until offsite backups are configured.

**Only after** the first backup succeeds and doctor has no `FAIL`, enable persistent schedules:

```bash
sudo systemctl enable --now vaultwarden-oci.target
sudo vwctl timers
sudo vwctl update check
```

The five-minute health timer launches **separate** local-health and Cloudflare DNS services; DNS failures cannot hide the local health state. The separate DNS service retries/debounces temporary network errors, while hard configuration/record errors fail immediately. Applying appliance updates is still **manual**.

### Protect the first backup offsite

The standard timer always makes a local encrypted backup daily at **03:15 server-local time**, plus up to 15 minutes random delay. To add **automatic offsite copies** to that same schedule, set up a cloud rclone remote under root, then follow the guided setup:

```bash
sudo rclone config
sudo vwctl recovery offsite configure
sudo vwctl backup
sudo vwctl recovery offsite status
```

Choose an existing rclone remote, enter the desired folder, and type `ENABLE` to make future scheduled backups upload automatically. Leave it unconfigured for local-only backups. You can later disable offsite publication without deleting backups. Do **not** give rclone your offline Age private key; store the separate recovery-kit ZIP and passphrase off-host, verify a selected offsite archive using the offline key, and practice on a disposable host. See [Recovery](RECOVERY.md#configure-automatic-offsite-backups-rclone).

## 8. Optional: automatic failure emails

Vaultwarden invitations and other application mail already use authenticated SMTP. **Automatic systemd failure emails are not enabled by SMTP alone**: add `[notifications]` for a supported built-in HTTPS provider and recipient, plus its encrypted `email_api_token`. SMTP is only the **eligible transient** fallback.

Follow [Configuration: Optional automatic failure alerts](CONFIGURATION.md#optional-automatic-failure-alerts), then test:

```bash
sudo vwctl notification test
sudo vwctl notification test --smtp
```

The first command needs the optional provider; the second can test SMTP without one. Providers supported by the current catalog include MailerSend, SendGrid, Mailgun, Postmark, Resend and CyberPersons.

## Advanced options (skip on your first interactive install)

**Automatic install:** `--auto` does **not** guess storage, imply formatting consent, or enable `--use-latest`. Terminal-driven `--auto` can still ask for a passphrase and recovery handoff when you have not supplied an offline recipient:

```bash
sudo ./setup.sh install \
  --domain example.com --url https://vault.example.com --email admin@example.com \
  --data-device /dev/disk/by-id/your-data-volume \
  --confirm-format --auto
```

**Fully headless:** prepare an Age recovery private identity on a **separate trusted workstation** and keep that private key off the appliance. Pass **only its actual public** `age1...` recipient. Example for an **existing** ext4/xfs filesystem:

```bash
sudo ./setup.sh install \
  --domain example.com --url https://vault.example.com --email admin@example.com \
  --data-device /dev/disk/by-id/your-data-volume \
  --offline-recipient 'age1REPLACE_WITH_YOUR_REAL_PUBLIC_RECIPIENT' \
  --accept-existing-filesystem --auto
```

Replace the placeholders. For an approved **blank** device, use `--confirm-format` **instead of** `--accept-existing-filesystem`. A fully headless run without an offline recipient is deliberately rejected before installing or changing storage. Supplying a recipient never causes a new one to be silently substituted. The headless path does **not** open credential editors automatically; complete Step 5 yourself.

**Dry run:** `--dry-run` checks host/inputs/devices without formatting, mounting or installing; a headless/`--auto` dry run still needs `--offline-recipient`.

**Latest components:** by default setup uses the repository-tested exact pins. `--use-latest` is a separate opt-in that resolves current upstream versions to fixed values. Leave it off for first installs.

**Safe reruns:** use the **same** identified storage and recovery recipient after an interrupted attempt. A `--confirm-format --auto` rerun only accepts the previously prepared filesystem when the stored host/device identity proves it was initialized by the prior attempt. Never change to boot storage or generate a different private recovery identity for existing encrypted data.

## If a step fails

Start with [Troubleshooting](TROUBLESHOOTING.md), not generic Docker cleanup or manual firewall changes. Useful checks: `sudo vwctl status`, `sudo vwctl doctor --json`, `sudo vwctl dns status`, `sudo vwctl timers`, and `journalctl -u vaultwarden-oci-dns.service --no-pager --lines=100`. Never share plaintext tokens, private Age identities or kit passphrases in support output.

Next: [Configuration](CONFIGURATION.md) · [Operations](OPERATIONS.md) · [Recovery](RECOVERY.md).
