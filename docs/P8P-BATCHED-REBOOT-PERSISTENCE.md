# P8P — batched stopped-only cold reboot and local origin-filter persistence

**Real-host P8P NOT RUN.** This gate is reviewed source for NEW disposable Ubuntu 26.04 ARM64 OCI A1 Flex `ubuntu@vaultwarden-oci-7-vnic`. This independent PR begins at the unchanged release-integration baseline; it does not install or modify the production rc.12 payload. All sensitive evidence remains on the remote VM. The original restored `-6-vnic`, shared Box recovery objects and public Cloudflare DNS/Worker are not disposable and are out of scope.

## Accepted prerequisite: P8O local security foundation

On 2026-11-05 UTC, exact-reviewed P8O `f989f2c91a1276501aab126443b96d593261e54e` actually ran on the NEW VM: **124 focused production tests PASS, P8O_EXIT=0, FOUNDATION**, with the installed immutable rc.12 owner applying Cloudflare-only Docker TCP/443 IPv4/IPv6 origin filtering and setting up CrowdSec engine/Hub plus INPUT-only host nftables bouncer. All **five foundation doctor IDs PASS** after mutation. CrowdSec engine and INPUT bouncer are enabled/active, Cloudflare Worker installed but disabled/inactive. Restored Oct 29 SQLite and exact SHA, original PUBLIC Age/SOPS custody, 52 release-owned product files/12 units, dedicated ext4, stopped Vaultwarden/Caddy/DNS/four timers/no listener or Docker containers, Box no-prune retention0/0 all remained intact. No Cloudflare DNS/Worker, Box write/prune, SMTP, app/Caddy startup, timers, restore or reboot.

Private P8O evidence `/home/ubuntu/vwoci-acceptance/p8o-security-batch-20261105T193844Z-16901/summary.txt` and exclusive `p8o-security-foundation-one-shot-attempt.json` must both be intact. Original recovered Box `bw-backup:bw-backup` remains configured but **must never be published/pruned through timers**. The original VM shares `bw.lazymocha.com`; no public hostname uniqueness is established. P8M temporarily staged plaintext on **unencrypted disposable ext4**; secure retirement of the test volume is required after acceptance.

## Why two terminal commands

A genuine cold reboot necessarily disconnects SSH. The **reboot** invocation performs many checks and records a durable source/data/security checkpoint before invoking a one-time reboot. The **postboot** invocation, on the same reviewed checkout after reconnecting, compares the NEW kernel boot ID, verifies a large stopped-host integrity/security batch and optionally re-establishes ONLY the local Cloudflare Docker-origin filter if that specific policy failed to persist. They are one acceptance gate across a real unavoidable boot boundary; no background agent/service is installed.

Both calls require exact clean Git SHA, correct branch and hostname, Ubuntu 26.04 ARM64/Python 3.14, `sudo -n` as ubuntu. The reboot and optional local firewall re-arm modes additionally require an **interactive SSH terminal and the explicit `--oci-console-ready` flag**. This flag is an operator attestation that OCI serial console recovery access is actively usable; SSH-only access is insufficient for these operations. The operator has already authorized disposable VM-local tests, so no repeated typed consent phrase is needed.

## First call: source/security/data preflight, one-shot checkpoint, reboot

Use `--expected-commit EXACT_SHA --mode reboot --oci-console-ready` **once only**. Its read-only preflight verifies:

1. Original immutable installed rc.12 source (52 files), 12 systemd unit definitions, original dedicated non-boot ext4 ID, public Age recipient, operational SOPS/admin/remediation custody, exact SQLite digest and read-only full database integrity.
2. Accepted root-only P8O one-shot mutation marker and FOUNDATION summary, both bound to exact earlier reviewed source and expected original SQLite/volume fingerprints.
3. Configured hostname/email and unchanged historical Box destination with retention0/0, strict SMTP TLS; 11 app/DNS/timer units disabled/inactive, static notify uninstantiated, no TCP 80/443 or Docker TCP, zero **all** Docker containers (not just running ones), update guard absent.
4. CrowdSec engine and host INPUT-only bouncer active **and enabled**; Cloudflare Worker **disabled/inactive**. Installed 27-ID doctor schema exact, mandatory host/dedicated-storage/SOPS checks PASS; all five foundation controls PASS. Worker FAIL and safe generated-path FAIL remain PENDING, not evidence of application data damage. Unsafe runtime paths BLOCK.
5. dpkg clean, `/run` tmpfs/swap-free, NTP state and reboot-required marker; hash original protected config/ENCRYPTED SOPS/Age key/storage markers/SQLite/P8O evidence and the exact reviewed P8P source into root-private one-shot checkpoint `/home/ubuntu/vwoci-acceptance/p8p-one-shot-reboot-checkpoint.json`.

Only after all critical prerequisites PASS, publish the exclusive checkpoint using `O_EXCL`/0600/fsync and a private sanitized preboot summary. If evidence cannot be persisted, **do not reboot**. If successful, request one `systemctl reboot`; SSH will close. The preboot status is **REBOOT_REQUESTED**, not proof of actual successful reboot. Never rerun the reboot command after uncertain disconnect; inspect checkpoint/OCI console and proceed to postboot verification.

## Second call: postboot batch + conditional local policy re-arm

After reconnecting to the same NEW VM and reviewing that OCI console recovery still works, invoke `--mode verify-and-rearm --oci-console-ready` from the **same** clean pin. It requires the single requested checkpoint and a genuinely **different kernel boot ID**. It repeats the complete restored source/SQLite/SOPS/storage/backup/timer/HTTP/Worker/CrowdSec/package/doctor/runtime-path audit and compares all protected hashes with the saved preboot baseline.

- If all five foundation doctor checks persist, report that no firewall mutation was needed. Mark the checkpoint verified and return **VERIFIED/0**.
- If (and only if) `edge.cloudflare.iptables` is the **sole additional postboot failing doctor ID**, while the Cloudflare CIDR policy, CrowdSec engine/Hub/host INPUT, restored DB, storage, SOPS, worker-off, Docker/HTTP isolation and all other invariants pass, revalidate the full baseline a second time and create an **exclusive 0600 fsync-durable one-shot re-arm marker** before invoking exactly one installed rc.12 `vwctl edge refresh` as root. No other security/package operation is permitted. Immediately audit full restored data, five foundation doctor IDs, Worker/CrowdSec, Docker, app and timers again; compare protected hashes with preboot; record **REARMED/0** only if all checks pass.
- An optional `--mode verify` call does the same postboot checks **read-only** and returns **HOLD/0** if Docker origin filtering was lost, without rearming. It may be followed by `verify-and-rearm` only if the same original checkpoint is still requested and no rearm attempt exists.

Any failure after a rearm attempt yields **BLOCKED/2** with possible partial local firewall state. **Never delete attempt marker or re-run local firewall setup automatically.** A reboot without changed boot ID, drifted source/SQLite/SOPS/config, unstable storage, CrowdSec/Worker state, changed backup policy, unsafe paths or unexpected non-443 doctor failure BLOCKS. No code uses `vwctl start`, `vwctl crowdsec setup`, `vwctl crowdsec remediation-start`, `vwctl dns update`, remote backup or timers. The local firewalls may be refreshed from Cloudflare's public IP-range feeds; that is **not** a Cloudflare account/Worker/DNS mutation.

## Outcomes and remaining production gates

- **REBOOT_REQUESTED / exit 0 or SSH disconnect:** only a reboot attempt recorded, not postboot verification.
- **VERIFIED / exit 0:** different boot, intact restored data/installed security, local origin filtering persisted without mutation.
- **REARMED / exit 0:** reboot proved, local Docker 443 rule was absent at first postboot inspection and restored through exactly one approved local product-owner refresh; **reboot persistence of that rule was not proven**.
- **HOLD / exit 0:** optional read-only postboot verification found missing origin filter, with all protected state safe.
- **BLOCKED / exit 2:** do not retry, restart app, reformat, repeat restore or remove markers. Preserve VM and sanitized evidence for separate diagnosis.

**Production NO-GO remains.** Even a full REARMED result does not prove isolated public hostname/OCI NSG/routing/Cloudflare Worker Route Fail Open, live Caddy/TLS, real client, SMTP, isolated offsite backup, naturally triggered timers or operational rollback. Those require later reviewed gates and independent off-host/network attestation. Original restored -6 VM and original Box objects remain protected. Never infer unique live origin from same-domain settings.
