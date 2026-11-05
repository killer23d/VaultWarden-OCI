# P8N — postrestore security and readiness, READ-ONLY

**Target:** NEW disposable Ubuntu 26.04 ARM64 OCI A1 Flex `vaultwarden-oci-7-vnic` only. **Do not execute on original restored `-6-vnic`.** This branch is an acceptance-only test, created from unchanged release-integration baseline `8590d83c074174824df1256b68d5bc0b57f4e9ab`.

## Actual historical result (P8M)

The operator ran P8M candidate `44d078113a67215cacd34df674a07c8f42afb219` on the NEW disposable VM: **121/121 production tests PASS, RESTORED, P8M_EXIT=0** at `2026-11-04T23:28:42Z`. Source was the independently pinned historical Oct 29 358680-byte encrypted Box recovery; offline PRIVATE Age identity was entered only into a hidden terminal prompt. Historical ciphertext SHA, Age recipient matching/authenticated decrypt, format-2 manifest, SOPS, SQLite full integrity and restored exact DB SHA passed. Two newer same-parent ciphertexts also decrypted and validated Age/manifest/SOPS/SQLite, but remain SOURCE UNTRUSTED because their fresh SHA observations lack independent off-host pins. Imported remote config is present, retention values are zero. No Box write, origin publication, app start, timer or Worker enable occurred. Original `-6-vnic` unchanged.

The restored encrypted backup temporarily staged plaintext on disposable dedicated **unencrypted ext4**. Unlink does NOT guarantee forensic erasure. Securely retire volume after acceptance, without assuming a backup/rollback makes deleted plaintext unrecoverable.

## P8N scope

A single **read-only** postrestore host audit:

1. Verify exact clean reviewed branch commit, host, Ubuntu 26.04 ARM64, one-shot immutable P8M marker and root-private success summary; no private keys or evidence contents printed.
2. Verify all 52 immutable rc.12 product release files, 12 installed unit definitions, original dedicated non-boot ext4, expected restored SQLite exact SHA and full read-only integrity.
3. Verify SOPS decrypt/custody, original PUBLIC Age recipient, historical configured hostname/email and **zero** local/remote retention. Treat imported non-null offsite destination as **PENDING**: no backup/timer activation until isolated test prefix is proven.
4. Require application/DNS/timers inactive (and no enabled unit), no active notifications, no Docker containers and no HTTP80/443/Docker TCP listeners.
5. Validate the installed product's exact 27-ID structured doctor JSON, including mandatory `storage.dedicated` and secrets controls. Report security IDs by approved label/status only. Unknown/missing/duplicated IDs, invalid JSON or mandatory FAIL => **BLOCKED**. Security foundation FAIL or missing generated runtime paths remain **PENDING**, not falsely PASS.
6. Hold all public/live gate prerequisites for new origin: verify current OCI ingress rules, Cloudflare DNS/Worker routes, Worker Fail Open before public startup; shared `bw.lazymocha.com` on original and NEW appliances is NOT distinct live origin proof.

**NO** restore replay, secrets materialization, systemd start/enable, CrowdSec/edge firewall setup, Box read/write/prune, DNS/Worker/ACME/SMTP, generated path repairs, reboot or disk formatting. P8N persists only a sanitized root-private summary under `/home/ubuntu/vwoci-acceptance` and prints only approved status labels. Run as ubuntu via passwordless `sudo -n`, from a newly cloned commit-pinned audit branch. All work remains on remote VM; no workstation download required.

**Expected exit:** `HOLD/0` with passing protected recovery/data and pending live prerequisites; `BLOCKED/2` on drift, unexpected activation, security inconsistency or malformed evidence. Neither means production GO.

## Following P8N

Only after reviewing the actual P8N output, prepare a **separate** new-VM host security foundation gate with independently attested OCI console access, recoverable firewall transaction and explicit rollback plan. Do not copy hardcoded old `-6-vnic` volume paths/consent from P5. Preserve original Box objects and production DNS. Public live Caddy/Vaultwarden start is a distinct future authorization, followed by local authenticated tests, isolated offsite backup, timer, reboot persistence and rollback. Never turn on a recovered historic Box destination inadvertently.
