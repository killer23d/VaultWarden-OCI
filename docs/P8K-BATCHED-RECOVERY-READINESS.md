# P8K — one-turn batched recovery-readiness and optional read-only Box evidence

**SOURCE CANDIDATE, P8K real-host NOT RUN.** This phase consolidates several previously separate review cycles into **one exact-SHA-pinned, single-command acceptance run** on the NEW disposable Ubuntu 26.04 ARM64 VM `vaultwarden-oci-7-vnic`. The original restored `vaultwarden-oci-6-vnic` remains untouched. The corrected P8I-R and P8J evidence are historical inputs, not retroactively rewritten.

## Accepted source gates (2026-11-04 UTC)

- P8H: one separately typed, successful format/first-install of the approved disposable 50 GiB dedicated ext4 disk only. `P8H_INSTALL_EXIT=0`, installed-but-stopped HOLD. **NEVER retry installer/format.**
- Corrected full P8I-R: exact review source `50b85b6bfd2940193f471f665f53ff50f8345848`, **122 focused tests OK, READ-ONLY HOLD/P8IR_EXIT=0**. Verified all 52 immutable rc.12 product files and 12 unit bytes, mounted dedicated disk markers, original public Age recipient with operational SOPS, 11 concrete units inactive/unenabled, a static notification template with zero instances, no TCP 80/443 listeners, retained Docker containers or pre-restore database. Earlier original P8I and P8I-D BLOCKED are preserved historical evidence about the bare notification-template query, not new runtime failures.
- P8J: exact review source `d9f686f38fc279de5d9da1ae7fd4f9c6e8604d92`, **118 focused tests OK, PRE-TRANSFER HOLD/P8J_EXIT=0**. Original independent OFFLINE *public* Age recipient hash matches the new installed config, historical Box ciphertext object and SHA-256 reference pinned from original-host source (but actual bytes **NOT YET READ**). New VM stopped, known recovery staging empty, `/run` tmpfs and no swap. Root-private accepted evidence:
  - `~/vwoci-acceptance/p8i-postinstall-20261104T220057Z-4259/summary.txt`
  - `~/vwoci-acceptance/p8j-recovery-readiness-20261104T221022Z-4373/summary.txt`
  - `~/vwoci-acceptance/p8j-recovery-readiness-20261104T221022Z-4373/candidate.private.json` — **NEVER PASTE**

## One run, multiple independently classified checks

Run `tests/host-acceptance/production-p8k-batched-recovery-readiness.py` as `ubuntu` through passwordless `sudo -n` from a **clean checkout at the exact reviewed P8K commit**. It requires Ubuntu 26.04 ARM64, Python 3.14, pinned rc.12, and the exact NEW guest hostname before accessing evidence.

| Check group | What is actually verified | State changed |
|---|---|---|
| 1. Historical acceptance | Original root-private P8I-R and P8J HOLD summaries, original P8J unverified candidate JSON and source SHA binding | No |
| 2. Source provenance | Literal-only original-host historical .vwrec object reference, SHA-256 pin and public offline Age recipient SHA-256 match the original P8J candidate | No |
| 3. Installed custody | Current protected test-only domain/email, original PUBLIC recipient, disabled remote and both retention settings zero | No |
| 4. Appliance storage | Immutable current rc.12 symlink, product-owned mounted dedicated ext4 and dual identity markers, non-root/boot separation | No |
| 5. Stopped services | 11 concrete units inactive/unenabled, static notification template with no instances or enabled alias, no local 80/443 listener, retained Docker containers or pre-restore SQLite DB | No |
| 6. Scratch / key isolation | `/run` tmpfs, active swap, free dedicated disk GiB, no already-staged `.vwrec`, ZIP, tar, database or unsafe symlink in the known backup staging folder | No |
| 7. Optional Box source | Explicitly typed opt-in only: check root's `bw-backup:` name, recursively count encrypted `.vwrec` items/newer candidates (no paths printed), stream exactly one **historically pinned** Age ciphertext through bounded SHA-256 and compare with the independent accepted pin | **Can refresh local root rclone OAuth token**; no remote writes, no ciphertext saved |
| 8. Consolidated report | New root-private `~/vwoci-acceptance/p8k-batched-recovery-*/summary.txt` plus PRIVATE candidate evidence JSON containing source refs/digests and any Box readback SHA/size | New private evidence only |

The optional Box streaming step is NOT silently triggered. It is offered only when the operator supplies `--offer-box-readback` **and** types this exact interactive phrase:

```text
P8K READ ORIGINAL BOX CIPHERTEXT ONLY
```

Typing anything else skips it. Root's existing `bw-backup:` rclone remote **may not be configured on the NEW VM**. If it is missing, do not transfer original credentials from `-6-vnic` or attempt a quick workaround; the script reports **PENDING** so the next handoff can be done from an approved trusted workstation. A Box read may refresh the locally stored rclone OAuth token; it does not upload, overwrite, prune, restore or write any cloud object. The pinned object is a historical **candidate**, not automatically the latest/best restore point. A newer listing is reported as a count with selection remaining PENDING. If readback times out or is unavailable, the exact SHA remains PENDING; if readback completes and the checksum **differs**, the run BLOCKS and no further recovery operation is permitted. Stream is limited to 4 GiB/10 minutes; no decrypted bytes or ciphertext file is saved on the VM.

## Boundaries that must NOT be combined without separate typed consent

- P8K does NOT move/open the original encrypted recovery ZIP, validate its independent passphrase, handle the original OFFLINE **private** Age identity, stage an Age key, decrypt any `.vwrec`, verify its plaintext manifest/SQLite, or execute `vwctl restore`. User had attested custody but P8J/P8K are **not** proof that the off-host materials decrypt the selected snapshot.
- A successful `HOLD/exit 0` with Box readback skipped or unavailable is **LOCAL PRE-RESTORE READINESS ONLY**, not actual ciphertext acceptance. Even with matching ciphertext SHA, **offline private-key/ZIP identity proof, plaintext scratch policy and restoration remain separate consent gates**.
- The current supported backup verification/restore owner temporarily stages decrypted application tar/payload under `/var/lib/vaultwarden-oci/backups` on the **dedicated ext4 data disk**, not exclusively protected tmpfs. Before running verification or restore, independently approve plaintext-at-rest/residual data cleanup, free space, access control and key/passphrase custody. Tmpfs `/run` and no swap are necessary but insufficient.
- Historical restoration will replace original SQLite, config, encrypted secrets and Caddy persistent data. The original host and new VM both configure `bw.lazymocha.com`. Imported backup remote/retention/SMTP/Worker/DNS behavior MUST be reviewed before first network exposure; no automatic promotion or cleanup that could prune original Box history.
- Do not start or activate Caddy/Vaultwarden, Docker/socket, timers, Cloudflare/DNS/Worker/ACME, SMTP, Box upload/prune, format, mount, reboot, reinstall, restore, production cutover, or modify original `-6-vnic`.

## Status, return codes and next batched test

**Expected local successful result: HOLD/exit 0**, with a status row for each independent safety check. If the optional Box read returns the pinned digest, that one external provenance check is PASS; **PENDING** remains for newer selection and off-host private Age identity/ZIP passphrase. **BLOCKED/exit 2** if exact host/source/previous evidence/recipient, dedicated disk, stopped unit, scratch, no swap, free space or Box ciphertext digest violates the policy. Never override a BLOCKED by manually changing host state or rerunning the installer.

Next after safe P8K HOLD: **P8L batched encrypted-kit/ciphertext custody proof and controlled restore planning**, performed only with specific private-key handling and plaintext scratch/cleanup approval. An actual destructive restoration and later live TLS/Cloudflare/Worker/SMTP/Box testing must each have their own interactive typed consent even when several tests are delivered in a single terminal session.

**P8K real-host: NOT RUN. P8H installation and P8I-R/P8J preflight accepted HOLD. Production NO-GO.**
