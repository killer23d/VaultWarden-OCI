# P8R — one-shot NEW-VM postboot origin-filter re-arm and full security replay

**Status: source candidate, NOT YET executed on the host.** Run only from an exact reviewed commit after all repository CI checks pass. NEW disposable `ubuntu@vaultwarden-oci-7-vnic`, Ubuntu 26.04 ARM64, passwordless sudo and a live interactive SSH TTY. **Working OCI serial-console recovery access is required** before a local firewall change, indicated with `--oci-console-ready`.

## Actual accepted results

- **P8M RESTORED/0:** original independently pinned October 29 recovery from Age/SOPS/SQLite, installed rc.12 owner, start=False, all application services stopped. It staged plaintext temporarily on **unencrypted disposable ext4**. Secure retirement required after testing.
- **P8N HOLD/0:** verified recovered immutable 52 product files/12 systemd units, dedicated ext4, SOPS/Age, full historical SQLite SHA/integrity, inactive app/DNS/timers; flagged unconfigured security.
- **P8O FOUNDATION/0** at reviewed `f989f2c91a1276501aab126443b96d593261e54e`: installed Cloudflare-only Docker TCP443 ingress filtering and CrowdSec engine/Hub + INPUT bouncer; five required local security doctor checks PASS, Worker disabled, original data unchanged, 124 focused tests PASS.
- **P8P BLOCKED/2** at reviewed `f17df88f0c0720be062efcc13cb35080cd0d7ac9`: real host reboot changed kernel boot ID, but an initial generic postboot snapshot failed before firewall refresh. **Preserve** P8P requested one-shot reboot checkpoint and every original attempt marker. Do not rerun P8P or mark it verified retroactively.
- **P8Q READONLY/0** at reviewed `25a2c864d260b29fcd89da88654d5987c1b87a17`: 125 focused tests PASS. On the rebooted NEW VM, independently checked immutable release/units, dedicated ext4 and full restored SQLite SHA/integrity, public Age/SOPS/admin/remediation, Box no-prune, application/DNS/timers disabled, zero Docker containers/HTTP listeners, CrowdSec engine and INPUT bouncer enabled/active, Worker disabled/inactive, dpkg/NTP/tmpfs/no-swap PASS. **Original P8P preboot protected hashes and original P8P snapshot parity now PASS**, but the earlier transient P8P failure cause is not proven. **Cloudflare Docker 443 origin doctor remained PENDING** after reboot. Other expected stopped-host `runtime.paths`, notification/Caddy/recovery live readiness checks are PENDING, not proof of unsafe changed data. Private P8Q sanitized summary: `/home/ubuntu/vwoci-acceptance/p8q-postboot-readonly-20261105T201612Z-1802/summary.txt`.

## What this single batched invocation does

First, require one exact clean P8R branch checkout, original exact clean P8P and P8Q source checkouts, root-only accepted P8O FOUNDATION and P8Q READONLY summaries, original P8P requested checkpoint and independent changed kernel boot ID. Reject any new reboot since the accepted P8Q report, any original P8P rearm attempt or any previous P8R one-shot marker.

Then run the **original P8P reviewed read-only snapshot and complete doctor** TWICE as independent preflight rounds, comparing the original P8P protected checkpoint hashes both times. This repeats the installed 52/12 integrity, original ext4/SQLite full SHA, SOPS/Age/admin, strict imported Box no-prune policy, disabled app/DNS/timers/notifications, empty Docker, no HTTP80/443, CrowdSec engine+host INPUT bouncer, Worker disabled, dpkg/NTP/swap/tmpfs, all 27 doctor controls and stopped generated-path metadata. If the 443 filter is already effective without changes, report **HOLD/0** and do not mutate it.

Only if all original security and data invariants are consistent and exactly the expected local `edge.cloudflare.iptables` remains missing, write an **exclusive root-only, fsync-durable P8R attempt marker** before executing one and only one installed `vwctl edge refresh`. Its raw stdout/stderr are captured in a new root-private evidence directory, never sent into chat. This supported installed product command fetches/validates public Cloudflare CIDRs and re-establishes local Docker TCP443 source filtering; it is NOT a Cloudflare account API, DNS, Worker Route or live origin operation.

Finally, in the same invocation, repeat the **full original P8P stopped-state snapshot and 27-ID doctor**. Require all five local foundation controls PASS, Worker still disabled, CrowdSec engine/host INPUT active, original protected hashes equal to the preboot checkpoint, no unexpected live listener, no app/DNS/timer/backup activation, and no kernel boot change.

- **REARMED / P8R_EXIT=0:** product-owner Cloudflare-only origin filter re-established successfully after reboot and all broad postchecks PASS. This does **not** prove the filter persisted unaided through cold reboot. Original P8P remains in its recorded BLOCKED state and is not modified or marked complete.
- **HOLD / P8R_EXIT=0:** verified safe stopped state and original filter already effective; **no firewall refresh performed**. No production GO.
- **BLOCKED / P8R_EXIT=2:** preflight/evidence fault, changed data/security, product refresh failure or any incomplete postflight. Preserve VM, unique P8R marker, checkpoint and private logs; **never blindly retry or reset attempt markers**.

## Strict non-goals and production path

NO additional reboot, user-facing Caddy/Vaultwarden startup, DNS/Cloudflare Worker/Route/Fail Open, ACME, SMTP, local/remote backup publication/prune, timer activation, restore replay, Docker container start or disk wipe. The new VM and original `-6-vnic` have shared historical domain configuration: that is **not** proof of isolated public origin routing.

Original recovered offsite remote remains configured with zero local/remote retention, but has no timer/publication authorization. Original Box backups and Cloudflare/DNS must remain untouched. After successful P8R, proceed to a **separately reviewed** isolation/controlled live-service gate using an independent hostname, effective OCI NSG/security lists, public Cloudflare route proof, authentic local HTTPS/client checks and a TEST-ONLY offsite prefix. Securely retire the disposable unencrypted test disk after final acceptance.

**Share only P8R sanitized summary and P8R_EXIT**. Never paste private doctor JSON, full config, Age identity or ZIP/passphrase, Box object paths, SSH credentials, private one-shot marker, nftables dumps or raw logs.
