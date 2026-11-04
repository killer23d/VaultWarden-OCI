# P8L — trusted off-host encrypted source handoff and batched on-host SHA verification

**SOURCE CANDIDATE; NO P8L REAL-HOST/OFF-HOST ACCEPTANCE YET.** This work starts from the unchanged accepted release baseline. Its goal is to resolve the only remaining P8K source blocker: root's bw-backup: rclone remote is unavailable on the **NEW** disposable Ubuntu 26.04 ARM64 vaultwarden-oci-7-vnic. Do not touch original restored vaultwarden-oci-6-vnic or import its rclone credentials.

## Accepted foundation (November 4, 2026 UTC)

- P8H: approved disposable 50 GiB data volume formatted and installed rc.12 ONCE; HOLD/exit 0. **NEVER run install or format again.**
- P8I-R: 122 focused tests OK, READ-ONLY HOLD/exit 0; 52 immutable release files, 12 unit bytes, ext4 markers, operational SOPS and offline PUBLIC Age recipient; 11 concrete units inactive/unenabled, static notification template zero instances, TCP80/443 zero, Docker containers zero, SQLite pre-restore database absent.
- P8J: 118 focused tests OK, PRE-TRANSFER HOLD/exit 0; historical original-host ciphertext path/SHA metadata identified and installed public recipient matched original pin. Private key/ZIP/passphrase and actual Box ciphertext bytes NOT verified; /run tmpfs, no swap.
- P8K: 121 focused tests OK, READ-ONLY HOLD/exit 0, exact candidate e446677fc2c846aa0ac4fb734f7b03729cefad4d. Dedicated disk 46 GiB free; all local checks pass. Operator typed Box-read consent, but ROOT bw-backup: was NOT configured on NEW guest: **no Box object read, no remote checksum checked.** The root-private accepted summary is at /home/ubuntu/vwoci-acceptance/p8k-batched-recovery-20261104T222145Z-4474/summary.txt and must remain unchanged.

One **historically accepted** candidate is the Age-encrypted file recovery-20261029T223200Z-1d319a79.vwrec, original Box parent bw-backup:bw-backup. Its trusted previously pinned encrypted SHA-256 is:

~~~text
ee2b43a859ca85fb64ce20af67a3c862a2c2946ebf11df1e9fb95f880e235060
~~~

This is a HISTORICAL candidate, **not** a claim about latest available snapshot or current Box object availability. Never select a newer or different source merely by its timestamp without independent hash/identity review.

## Part A: independent trusted macOS/Linux workstation — encrypted ciphertext only

Run tools/p8l-offhost-encrypted-source.py on a **trusted workstation as a normal user**, never on either OCI VM or as root.

Option 1: already downloaded encrypted file from Box web UI. Preserve its exact filename and set it mode 0600 (chmod 600). Verify bytes with:

~~~bash
python3 tools/p8l-offhost-encrypted-source.py --local /absolute/path/recovery-20261029T223200Z-1d319a79.vwrec
~~~

Option 2: workstation has its own independently configured rclone remote named bw-backup: (do NOT copy the original restored VM root config):

~~~bash
python3 tools/p8l-offhost-encrypted-source.py --box
~~~

Live TTY consent phrase: **P8L DOWNLOAD HISTORICAL ENCRYPTED CIPHERTEXT ONLY**. This reads a single historical Box ciphertext, hashes it against the prior trusted SHA, and saves ONLY an Age-encrypted 0600 file under private 0700 workstation directory ~/vwoci-encrypted-handoff. It never uploads, overwrites or prunes Box, decrypts or opens an offline identity. The workstation OAuth token may refresh locally. If this remote is absent, use the Box UI download mode instead; do not import credentials from the original guest.

Optional structural **AES-256 encrypted recovery-kit ZIP** check in the same invocation:

~~~bash
python3 tools/p8l-offhost-encrypted-source.py --local /absolute/path/recovery-20261029T223200Z-1d319a79.vwrec --kit /absolute/path/vaultwarden-recovery-kit-YYYYMMDDTHHMMSSZ.zip
~~~

The kit test reads ONLY ZIP metadata and requires five expected members each protected by WinZip AES-256. It does not read the member contents, ask for or test a password, extract Age keys or prove that the private identity matches the ciphertext. Do not share the ZIP or passphrase in ChatGPT, GitHub, shell history or logs.

**Encrypted-only manual transfer is a separate operator action.** On the NEW guest as ubuntu, create one private inbox and copy ONLY the verified encrypted file from the trusted workstation using your established SSH address:

~~~bash
# On NEW vaultwarden-oci-7-vnic, as ubuntu
install -d -m 0700 "$HOME/vwoci-encrypted-inbox"

# On your trusted workstation (replace SSH address yourself):
# scp -p /path/to/recovery-20261029T223200Z-1d319a79.vwrec ubuntu@NEW_VM_SSH_ADDRESS:/home/ubuntu/vwoci-encrypted-inbox/

# Back on NEW guest, with no file contents printed:
chmod 0600 "$HOME/vwoci-encrypted-inbox/recovery-20261029T223200Z-1d319a79.vwrec"
~~~

Never transfer the offline PRIVATE Age identity, decrypted ZIP contents or passphrase at this gate. Do not place the encrypted backup into the product's on-disk backups directory before restoration consent.

## Part B: one-shot batched **NEW guest** source proof

Run tests/host-acceptance/production-p8l-encrypted-source-handoff.py from an exact-reviewed, clean P8L checkout via sudo -n as ubuntu on **only vaultwarden-oci-7-vnic**.

It binds the original P8K HOLD and private candidate metadata, including the prior REMOTE_UNAVAILABLE classification; parses original-host recovery metadata without executing old host code; checks the installed offline PUBLIC Age recipient and disabled backup/retention zero; verifies dedicated non-root ext4 and rc.12 release, concrete and templated systemd stopped state, no HTTP80/443/Docker/SQLite, /run tmpfs, swap off, adequate free disk and absence of unexpected on-disk backup payload.

If --artifact is specified, it must point **exactly** to:

~~~text
/home/ubuntu/vwoci-encrypted-inbox/recovery-20261029T223200Z-1d319a79.vwrec
~~~

The path must reside in a 0700 private inbox, be a single-link regular 0600 file owned by ubuntu/root, have the supported age-encryption ciphertext header and be within the 4 GiB bound; a full SHA-256 is compared with the original accepted digest. The script never decrypts or changes the encrypted source. WITHOUT --artifact, the local checks can still return HOLD but the actual ciphertext integrity remains PENDING.

Output: a new root-private sanitized summary and a **separate private** ciphertext metadata file; paste ONLY the sanitized status and P8L_EXIT, never the private JSON. A mismatch, unexpected staging, active service, changed recipient/disk or unsafe source returns **BLOCKED/exit 2**; no automatic remediation.

## Future consented batches

After the encrypted source is verified, the next gate may combine OFF-HOST private Age/ZIP identity handoff, controlled decryption, recovery manifest/SQLite integrity, SOPS custody, actual plaintext expansion/rollback space and a reversible cancellation check. **That is a separate explicit consent boundary**, because the supported recovery owner writes temporary plaintext tar/payload onto dedicated ext4, not entirely tmpfs; /run tmpfs and zero swap alone do not remove residual-at-rest risk.

Actual RESTORE, imported backup-remote/SMTP/DNS/Worker config isolation and postrestore checks can be batched behind a fresh typed RESTORE confirmation. Public Caddy/Vaultwarden startup, Cloudflare DNS/Worker changes, SMTP, Box write/prune, timers and reboot remain separately reviewed/authorized. Both original and NEW stopped guests configure bw.lazymocha.com, which by itself does NOT prove unique live public routing.

**P8L source review only; no encrypted source transfer/decryption/restore/public service authorized. Production NO-GO.**
