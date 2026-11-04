# P8H — isolated disposable rc.12 installation with separate typed consent

**SOURCE CANDIDATE. The real P8H PREPARE and INSTALL phases have NOT RUN.** This branch changes only host-acceptance scripts, focused tests and documentation, not production runtime. It begins at the unchanged accepted release-branch baseline. It is strictly for the NEW disposable `vaultwarden-oci-7-vnic` and MUST NOT run on the original restored `vaultwarden-oci-6-vnic`.

## Actual prior acceptance evidence and independent operator attestations

On the NEW disposable OCI VM:
- **P8F** at reviewed commit `6e7e84904f9044d55b26fe2118b5f2d32e3295cc`: 118 focused tests PASS; real-host READ-ONLY HOLD/exit 0. One blank non-root disk, A1 Flex VM, one VNIC, no appliance/Docker/HTTP listeners. Original host untouched.
- **P8G** at reviewed commit `a98a58d02160ac01e9e9ce7bc8ba683a33929915`: 117 focused tests PASS; real-host READ-ONLY HOLD/exit 0. One unmounted unsigned whole-disk **50 GiB**, two stable by-id aliases, sanitized first-alias fingerprint `b7cd04a730c8`, instance fingerprint `0dccfd58cbbd`, VNIC fingerprint `36862e16cc9f`, no appliance or TCP 80/443 listener. Original root-private P8G evidence remains in `~/vwoci-acceptance/p8g-disk-network-witness-20261104T205546Z-2275/`.
- Operator **independently attests from OCI Console**, specifically for NEW `-7-vnic`: disk attachment matches guest stable alias and capacity, is disposable/non-shared; ALL new VNIC NSGs and subnet security lists reviewed; effective Internet TCP 80 **denied**, TCP 443 **current Cloudflare CIDRs only**, public IPv6 **No**; serial console available. Test-only hostname and DNS-01 authority verified, no overlapping Worker Route, original encrypted recovery ZIP/private Age identity and passphrase remain off-host, approved separate Box test prefix unused. These are **operator attestations**, not automatic OCI/Cloudflare control-plane proof and not authorization to start public services.

**This P8H source gate is the first deliberately destructive potential action in the NEW VM sequence.** The operator's prior Yes/No attestations establish prerequisites to prepare the gate, but cannot silently consent to formatting. The actual selected by-id alias, exact hostname, public recipient and current disk identity require a fresh, separately typed consent.

## Source-level installation audit

This gate delegates the **only** disk/system mutation to the existing supported `setup.sh install` owner. The reviewed rc.12 source implements `--auto --dry-run` (no filesystem/package/config/SOPS/systemd writes), `--data-device` (never guesses a disk), `--confirm-format` (explicit blank-disk format acknowledgement), and `--offline-recipient` (use the ORIGINAL offline **public** Age recipient, without generating or retaining a new offline private key). The normal pinned version manifest is used; `--use-latest` is not permitted.

The actual installer can format the approved new data block volume, create dedicated ext4, install packages/Docker/systemd/release metadata, generate a NEW operational Age key, and create initial SOPS ciphertext addressed to the operational key and **supplied original off-host public** recovery recipient. The freshly generated TOML has a separate configured test hostname, placeholder SMTP settings/blank external credentials, `backup.remote=""`, and retention 0/0. A clean install does **not** restore an encrypted `.vwrec`, start Caddy/Vaultwarden, publish DNS, initiate ACME certificates, activate Worker, send mail, or write Box backups.

**Installation is not restoration.** The restored original `.vwrec` may contain the shared `bw.lazymocha.com` hostname and original offsite destination. A later separate recovery gate must verify and control that configuration before any test-host app startup. Do not run the restore command after setup simply because setup succeeded.

## P8H modes

### A. `prepare` (first one-shot; READ ONLY)

Run from a separate **exact SHA pinned** clean checkout of this PR as `ubuntu` on `vaultwarden-oci-7-vnic` using passwordless `sudo -n`. The operator handoff includes the complete one-shot command; it runs the focused production tests first, then executes:

`sudo -n python3 -B -E tests/host-acceptance/production-p8h-isolated-install-consent.py --expected-commit <REVIEWED_PR_HEAD> prepare`

It confirms the exact expected Ubuntu 26.04 ARM64/rc.12 source and hostname, requires the original root-private P8G HOLD summary and disk-details proof (without copying raw paths), ensures the accepted 50 GiB disk, BOTH stable aliases, partitions/signatures/mounts/root ancestry and original OCI instance/VNIC fingerprints have not changed, and requires a still-clean appliance/Docker/80/443 state.

Only a new root-private `~/vwoci-acceptance/p8h-prepare-<timestamp>-<pid>/checkpoint.json` and sanitized `summary.txt` are written. The checkpoint binds the reviewed source SHA, current **Linux boot ID**, exact P8G proof digest, original instance/VNIC/alias fingerprints and disk size. **It records preparation, not authorization.** Expected result: `HOLD/exit 0`; any unexpected change `BLOCKED/exit 2`. Paste only the printed summary and `P8H_EXIT`; never paste private checkpoint JSON, disk paths, keys, or raw logs.

### B. `install` (separate future approval; destructive)

This mode is NOT included in the read-only P8H preparation command and must be invoked separately, only after operator review of the prepare result and exact commit. It requires `--checkpoint <absolute-accepted-P8H-checkpoint-path>` and a **live interactive terminal**. It revalidates every P8G disk/OCI/host/source invariant and the same boot ID; it refuses a repeated/partial attempt.

The operator privately chooses one of the two previously witnessed stable by-id aliases **by index**, enters the distinct test-only HTTPS hostname and its ACME account email, and enters the ORIGINAL **public** Age recipient (hidden input). Entering `bw.lazymocha.com` or the parent production domain is prohibited. The script requires this complete exact phrase before any format:

```text
P8H FORMAT vaultwarden-oci-7-vnic 50GiB b7cd04a730c8 OCI CONSOLE AND TEST DNS VERIFIED
```

It first executes the supported non-mutating **installer dry run** using the exact inputs and requires the product's affirmative no-mutation output, saving the private log. It rechecks the whole disk and OCI fingerprint after dry run. **Before** the first destructive installer invocation, it writes a root-private `install-attempted.json` exclusive marker; no subsequent invocation may silently repeat the operation. It then invokes **once** the supported `setup.sh install --confirm-format --auto` with the explicitly selected by-id alias and original offline public recipient. This stage can install packages and write the **NEW disposable disk**; no programmatic wipe outside the product owner occurs.

Post-install verification checks the immutable pinned rc.12 release, dedicated ext4 storage dual markers, supplied test hostname and offline Age recipient, SOPS encrypted custody/decryption to `/dev/null`, disabled remote destination/retention 0/0, and no app/timer/HTTP start. On success `HOLD` still means **installed and stopped**, not restored or safe for public traffic.

On any setup failure, timeout, interrupt, install marker or unverifiable partial state: **BLOCKED, do NOT rerun, reformat, reinstall, start services, or manually repair without a separate read-only triage gate.** The private setup log remains on the guest and must NOT be pasted.

## Subsequent gates — not authorized

- **P8I**: separately controlled original recovery-kit identity/private-key handling, independently verified encrypted `.vwrec` source/readback/restore and restored configuration isolation. Recovery may introduce the shared production-like hostname; keep all services stopped and test-only Box separate.
- **P8J**: independently controlled Cloudflare-only Docker ingress *before* Compose publication, test-only DNS-01 issuance, actual TLS/Caddy/Vaultwarden authenticated client tests, CrowdSec/Worker invocation-specific Fail Open. No production/shared hostname or Worker Route change.
- **P8K+**: separate SMTP delivery, remote Box backup/readback and no-prune proof, natural timers, cold reboot persistence, rollback, release freeze and final production GO/NO-GO.

No part of P8H authorizes DNS/Cloudflare/Worker API mutation, real SMTP sends, Box writes, backup restores, live service startup, timer activation, reboot, migration or production cutover. PR must remain open until independently reviewed.

Reference existing owners: `vaultwarden_oci/setup.py` (`--dry-run`, `--confirm-format`, `--offline-recipient`), `vaultwarden_oci/setup_frontend.py` (custody behavior), `vaultwarden_oci/storage.py` (boot ancestry/dedicated volume), and `tests/host-acceptance/24-rc12-clean-install-ubuntu2604-arm64.sh` (historical destructive clean-install acceptance, not an approved script for this test hostname).
