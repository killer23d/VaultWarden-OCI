# P8I — read-only installed-but-stopped evidence after first format/install

**Source review only; real P8I NOT RUN.** This is a new independent acceptance branch from the unchanged release baseline. It is specifically for the **NEW disposable** `vaultwarden-oci-7-vnic` on Ubuntu 26.04 ARM64. It cannot reformat, mount, reinstall, recover Vaultwarden data, run Docker Compose, issue certificates, publish Cloudflare DNS, configure Worker Routes, send mail, write Box backups, enable timers, reboot, or start any service.

## Accepted real-host history — 2026-11-04 UTC

- **P8F new guest:** 118 focused tests OK, read-only HOLD/exit 0. A1 Flex instance and one VNIC identified, one 50 GiB blank dedicated data disk with by-id aliases.
- **P8G disk/OCI witness:** 117 focused tests OK, read-only HOLD/exit 0. New guest disk remained unmounted/unsigned/blank, 50 GiB, two stable aliases, original A1 and VNIC fingerprints unchanged. Operator separately confirmed OCI Console disk attachment matched the private by-id details, disk was disposable/non-shared, effective new guest TCP/80 denied, TCP/443 current Cloudflare-only CIDRs, no public IPv6, and serial-console access.
- **Original P8H prepare:** 124 focused tests OK, HOLD/exit 0; its first installation interaction was **CANCELLED/exit 2**, *before* any installer invocation or attempt marker, because the old code disallowed the supplied URL/shared hostname.
- **Corrected P8H prepare, PR #397:** reviewed exact SHA `f75e5b85d465abf328353b1bb94eaee1f7d66eff`; 126 focused tests OK, read-only HOLD/exit 0. Root-private checkpoint `~/vwoci-acceptance/p8h-prepare-20261104T213043Z-2771/checkpoint.json`.
- **Corrected P8H FIRST INSTALL, same exact SHA:** 126 focused tests OK; operator selected witness alias **choice 1**, entered original offline **PUBLIC** Age recovery recipient privately, and typed the complete consent phrase `P8H FORMAT vaultwarden-oci-7-vnic 50GiB b7cd04a730c8 FOR bw.lazymocha.com INSTALL ONLY`. Installer returned **HOLD / P8H_INSTALL_EXIT=0** after one successful format/install. It verified dedicated ext4, dual ownership markers, pinned rc.12, operational SOPS/Age plus original offline public recipient, locked hostname/email `bw.lazymocha.com`/`bw@lazymocha.com`, remote backup disabled and both retentions zero. Installed application/systemd timers remained stopped, no HTTP 80/443 listeners.

Original installed-but-stopped summary lives in the **same root-private** `~/vwoci-acceptance/p8h-prepare-20261104T213043Z-2771/` alongside `install-attempted.json`, `install.summary.txt` and private setup logs. **Do NOT share these files** or raw Age identities, disk aliases, IP addresses, secrets or passwords. The original restored `vaultwarden-oci-6-vnic` stays untouched/stopped; it ALSO configures `bw.lazymocha.com`, so no unique public ingress can be assumed.

## P8I safety and boundaries

Execute `tests/host-acceptance/production-p8i-postinstall-stop-witness.py` only from a clean checkout at the exact pinned P8I PR commit, as `ubuntu` via `sudo -n` on NEW `vaultwarden-oci-7-vnic`.

**Local read-only checks:**

1. Refuse wrong machine, wrong OS/architecture/Python, wrong release manifest/source branch/commit, dirty source checkout or missing original root-private acceptance evidence.
2. Validate the original corrected P8H checkpoint, the **exclusive one-shot installation-attempt marker** (commit, boot ID, disk alias fingerprint and configured hostname digest), original P8G evidence digest, successful P8H installation HOLD summary and private setup logs. Never retry P8H even if a later check BLOCKS.
3. Rehash every product-owned installed release file in `vaultwarden_oci/`, `systemd/`, `vwctl`, `versions.toml`, `email-providers.toml` against the reviewed source; validate immutable ownership/modes, installed systemd unit bytes and canonical `current` release symlink. No source or installed files are written.
4. Validate mounted dedicated ext4 and dual volume ownership markers with the **product-owned, read-only** `storage.verify`, verify root/boot separation and compare against the original PRIVATE P8G resolved disk.
5. Parse protected TOML config (no raw output), confirm `bw.lazymocha.com` and `bw@lazymocha.com`, `backup.remote=""` and retention 0/0; validate original offline public recipient against operational SOPS recipients, protected key/file permissions, and decrypt SOPS **only to `/dev/null`**. No plaintext secrets are retained or displayed.
6. Check every installed systemd unit is loaded but inactive/not enabled; check no HTTP 80/443 socket and no retained Docker container metadata. Docker socket is NOT queried (even a harmless-looking Docker CLI query could activate the daemon). No `/var/lib/vaultwarden-oci/data/db.sqlite3` is permitted before the separately authorized original data restore.
7. Emit a **new** root-private `~/vwoci-acceptance/p8i-postinstall-*/summary.txt` with **only safe statuses** and fingerprints. Existing P8F–P8H evidence is never changed.

**Decision:** A successful P8I run is **HOLD, exit 0**: the new appliance is installed, cryptographically verifiable and still stopped. A missing original attempt marker, disk mismatch, changed release file, SOPS custody failure, active unit/HTTP listener, or unexpected pre-restore SQLite database is **BLOCKED, exit 2**. A BLOCKED result is a stop-and-diagnose condition, **not** permission to re-run install, mount or restore.

## Next recovery gate: plan before decrypting or restoring

This stage must remain **separate**. Operator had confirmed off-host encrypted ZIP, private Age identity and passphrase custody, but the private key MUST NOT be persistently copied to the new VM. An independently reviewed recovery-source gate should identify **one exact original encrypted `.vwrec` artifact** and ciphertext SHA-256, prove where it is held (an operator-supplied local encrypted archive or a separately approved exact Box read), validate secure tmpfs/swap behavior for any future plaintext handling and require fresh typed consent before staging/decryption. Historical remote `bw-backup:bw-backup` and an approved **unused test-only Box prefix** must remain distinct, with zero automatic pruning.

A **different future destructive restore gate** must verify: ciphertext/manifest/SQLite, recovery identity matching the original public recipient, full backup/rollback and cancellation handling, and stopped application/timers. Restoring a historical backup can replace site configuration and Box settings. Do not let a shared hostname or imported credentials produce public traffic. After restore, independently inspect and adjust only under separate authorization.

Subsequent live HTTPS, Caddy, DNS-01, Cloudflare DNS/Worker Routes, SMTP, remote Box backup/readback, timers, reboot persistence, rollback and production GO/NO-GO are **NOT RUN**. No old `bw.lazymocha.com` origin should be accidentally activated.

## Operator command

Use the **new P8I PR's exact-reviewed pinned SHA** (shown in the operator handoff), not the original P8H source branch:

```bash
sudo -n python3 -B -E tests/host-acceptance/production-p8i-postinstall-stop-witness.py --expected-commit <PINNED_P8I_SHA>
```

Paste the sanitized summary and `P8I_EXIT` only. No original recovery kit, private key, password, host cloud token, raw doctor output or private installer log should be pasted.

**Status: original P8H first installation accepted HOLD/exit 0; P8I REAL HOST NOT RUN; restore and live-start NOT RUN; production NO-GO.**
