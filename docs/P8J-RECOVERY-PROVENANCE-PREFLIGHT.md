# P8J — off-host encrypted recovery provenance before ANY transfer or restore

**P8J is READ-ONLY and PRE-TRANSFER. Real-host P8J has NOT RUN.** The new acceptance source branch is independent of the previously reviewed P8I-R branch and starts from the unchanged release baseline. The target is **only** the NEW disposable Ubuntu 26.04 ARM64 A1 Flex `vaultwarden-oci-7-vnic`. Do not run on the original restored `vaultwarden-oci-6-vnic`.

## Accepted evidence: NEW host is installed, stopped, not restored

On 2026-11-04 UTC, the operator completed the **corrected full P8I-R** source commit `50b85b6bfd2940193f471f665f53ff50f8345848`. **122 focused production tests OK and P8IR_EXIT=0 / READ-ONLY HOLD.**

- The original successful, typed-consent P8H format/install checkpoint, exclusive one-shot attempt marker and successful stopped-install summary were intact. **Never rerun the installer or format the disposable disk**.
- **52 immutable product files and 12 installed systemd unit bytes** matched the audited rc.12 release. The dedicated 50 GiB non-boot ext4 disk and dual ownership markers matched P8G; safe UUID fingerprint `2449f67320a1`.
- `bw.lazymocha.com` and `bw@lazymocha.com` remained locked; `backup.remote=""`, both retention settings zero. Operational SOPS was decryptable without printing secrets and the original offline **public** Age recipient remained in custody.
- All 11 concrete systemd services/timers were inactive/unenabled, the static notification template had **zero instances**, there were **zero TCP 80/443 listeners**, zero retained Docker containers, and **no pre-restore SQLite database**.
- Historical original P8I and P8I-D **BLOCKED** reports remain accurate and unchanged; they were caused by the original acceptance validator querying an uninstantiated systemd template directly.
- Root-private accepted summary: `~/vwoci-acceptance/p8i-postinstall-20261104T220057Z-4259/summary.txt`.

**P8I-R HOLD does not confirm backup availability, original ciphertext bytes, offline private-key custody, restoration or live public-service isolation.** The original recovered `-6-vnic` also configures `bw.lazymocha.com`; Cloudflare DNS, Worker Route and ACME authority require separate reviews before live startup.

## What the P8J script checks

Only `tests/host-acceptance/production-p8j-recovery-provenance-preflight.py`, from a clean exact-SHA-pinned review checkout, as `ubuntu` with `sudo -n` on the **NEW** guest.

1. Requires original root-private P8I-R `HOLD` and every material PASS marker, exact new VM identity, Ubuntu 26.04 ARM64/Python 3.14/rc.12 manifest and clean reviewed Git source. Existing P8F–P8I-R acceptance evidence remains **untouched**.
2. **Parses, but does not import or execute**, the historical **original-host-only** `tests/host-acceptance/production-recovery-source-preflight.py` constants `HOST`, `HISTORICAL_REMOTE`, `HISTORICAL_SHA256`, and `OFFLINE_RECIPIENT_SHA256`. These provide one previously accepted **candidate** historical Box object and independent ciphertext SHA-256 and offline public-recipient hash; the original-host target and format are checked. This code is **not** evidence the remote object still exists or that it is the best/latest restore point.
3. Independently checks that the **NEW** installed config's offline **PUBLIC** Age recipient hashes to the original-host recipient pin, without printing the recipient, and the configured hostname/email plus `backup.remote=""`, retention 0/0 are unchanged. A recipient mismatch is a **BLOCKED** stop, not an invitation to introduce the private Age identity to fix it.
4. Rechecks the installed rc.12 pointer, 11 concrete units inactive/unenabled, static notify template with **no instantiated units**, no 80/443 listener, zero retained Docker containers and **no restored SQLite DB**. It never contacts the Docker socket.
5. Looks only in the known NEW-host backup and kit publication/staging paths for unexpected `.vwrec`/ZIP files. This **limited inventory** cannot certify global absence of a secret or private key anywhere on the host. An unapproved staged artifact or unsafe symlink **BLOCKS**.
6. Observes whether `/run` is mounted as `tmpfs` and whether any kernel swap is active, without changing mounts, swapping, permissions or encryption. An unsafe/unknown volatile staging policy is **PENDING** for later handling, never a pretext for automatic remediation.
7. Creates only a **NEW root-private** `~/vwoci-acceptance/p8j-recovery-readiness-*/` directory with: `summary.txt` (sanitized, pasteable), and `candidate.private.json` (original reference candidate path, SHA-256 and recipient HASH, labeled **UNVERIFIED**, for operator-only comparison). Do **NOT** paste `candidate.private.json` or any actual off-host files.

A local successful `HOLD / exit 0` means these **local pre-transfer checks** passed and the **off-host/restore prerequisites remain PENDING**. A `BLOCKED / exit 2` means no transfer, decryption, restore or setup retry; preserve evidence for separate read-only triage.

## Critical security and correctness boundaries

- **Original historical Box candidate, not a final choice.** A prior original-host acceptance test pins one exact `.vwrec` object and independent ciphertext SHA-256 (timestamp 2026-10-29). A later, separately authorized **OFF-HOST readback** must choose a known recovery point, obtain its exact object path/size/digest and compare actual ciphertext bytes with a trusted pin; a newer object may be preferable. Do not assume the parent folder or filename alone proves integrity. Do **not** copy private credentials or import original root's rclone config to this fresh guest.
- **The encrypted recovery ZIP is not the encrypted application backup.** The AES-256 ZIP contains identity/credentials; the `.vwrec` is an Age-encrypted application snapshot. ZIP + its independent passphrase + matching offline **private** Age identity are needed to verify/recover, but P8J does **not** open, extract, move, decrypt, print or stage any of them.
- **Never transmit an offline private Age key or ZIP passphrase in chat, GitHub logs, shell history, argv, environment, public file or root-private summary.** Once separately consented, use the supported secure interactive identity chooser in product code, which keeps temporary key material under protected `/run/vaultwarden-oci` and cleans it. Transferring the encrypted ZIP itself onto this guest is still a separate operator decision.
- **Decrypted application payload staging is NOT entirely volatile.** The product recovery verifier and restore engine create temporary plaintext archive/payload files in the dedicated `/var/lib/vaultwarden-oci/backups` filesystem during `verify` and `restore`. That location is **on dedicated ext4**, not automatically a `tmpfs`. The cleanup path and SSD/volume residual data threat must be explicitly accepted or mitigated in a later consent gate; an empty swap list and tmpfs `/run` do not solve the on-disk plaintext question. If the system stores sensitive data on the disposable unencrypted disk, consider the disk's lifecycle/disposal and an encrypted scratch policy before running verification.
- **Restore mutates configuration and data.** Historical recovery may replace `config.toml`, encrypted SOPS secrets, SQLite and Caddy persistent data and may import a remote backup destination/retention that should not reach historical Box. A future restore must stay **STOPPED**, with a separately reviewed configuration isolation/backup-retention proof before timers, SMTP or application startup.
- **Cloudflare routing and DNS ownership are not proven by this guest.** Both the original restored VM and new disposable VM configure the **same** `bw.lazymocha.com`. No sharing/public exposure, DNS/ACME certificate issuance or Worker Route changes are authorized; a later live gate must prove a unique effective origin and restrictive OCI/Cloudflare ingress before Caddy publishes 443.

## Follow-on acceptance sequence — all NOT RUN

**P8K: separately reviewed, read-only OFF-HOST ciphertext availability/integrity and key-custody handoff.** The operator chooses the exact historical/other `.vwrec`; independently proves its full ciphertext SHA-256/size through a trusted workstation or a separately approved Box read-only command. A cloud read can refresh OAuth credentials locally even when it does not modify remote objects. A separate path validates encrypted ZIP possession/passphrase/identity **without** placing private material persistently on the guest. The resulting evidence must contain safe digests, never key/password/plaintext.

**P8L: separately typed restore consent and pre/post stop isolation.** Authorize exact approved artifact, original public/secret Age recipient, disk/boot identity, dedicated backup/rollback plan, plaintext scratch/cleanup risk, available space, cancellation and no live app. Verify the decrypted manifest + hashes/SQLite only within controlled staging, and do not let recovered remote config/timers contact the original Box backup. Never silently reuse a shared hostname as proof of public isolation.

**P8M and later:** separate Cloudflare-only firewall-before-publication/Worker Fail Open/DNS-01/Caddy/Vaultwarden TLS health, real (non-production) notification/SMTP, isolated Box backup SHA readback, natural timers, cold reboot persistence, rollback and final release GO/NO-GO. The original restored `-6-vnic` stays unchanged throughout the disposable test.

**P8J real-host: NOT RUN. Historical P8I-R: ACCEPTED READ-ONLY HOLD. All later restoration and public service steps: NOT AUTHORIZED.**
