# P8Q — independent READ-ONLY postboot blocker diagnosis

**P8P is currently BLOCKED.** This new checked-in gate is a safety investigation, not a retry, repair or new authorization to use the live origin. Target only NEW disposable Ubuntu 26.04 ARM64 "vaultwarden-oci-7-vnic" via the ubuntu account with passwordless sudo. Do not execute on original restored "-6-vnic".

## Actual host handoff (November 5, 2026 UTC)

P8M independently restored the originally pinned October 29 encrypted recovery with Age/SOPS/SQLite integrity and start=False. P8N HOLD/0 verified the recovered database, original recipient, installed release/units and inactive application. P8O FOUNDATION/0 at reviewed commit f989f2c91a1276501aab126443b96d593261e54e ran 124 focused regression tests and installed the local Cloudflare-only Docker TCP/443 origin filter and CrowdSec/INPUT-only bouncer. Its five local security doctor checks passed.

P8P postboot at reviewed commit f17df88f0c0720be062efcc13cb35080cd0d7ac9 ran 127 regression tests, then produced PASS different kernel boot ID, followed by BLOCKED while executing its general postboot protected-state snapshot. P8P_EXIT=2. The source was blocked **before conditional firewall rearm**. Root-private sanitized summary: /home/ubuntu/vwoci-acceptance/p8p-verify-and-rearm-20261105T200613Z-1565/summary.txt. The actual failing postboot invariant remains unknown. Preserve the VM, original checkpoint and all one-shot attempt markers.

## Single independent read-only diagnostic

A P8Q fresh checked-in checkout must exactly match its reviewed SHA, branch and host. P8Q independently verifies the prior clean P8P checkout at /home/ubuntu/VaultWarden-OCI-p8p-f17df88 and its original exact SHA. It **imports** the original P8P helper module for parity but never executes P8P main(), reboot_once(), checkpoint_finish(), private_log() or conditional rearm flow.

It runs these groups independently, reporting only safe PASS/PENDING/BLOCKED/NOT RUN labels:

1. Original P8O provenance, P8P one-shot reboot checkpoint and changed kernel boot ID.
2. Immutable installed rc.12 pointer, 52 original product files, 12 installed units and original dedicated ext4 identity.
3. Historical configuration, no-prune Box destination, original public Age recipient, encrypted SOPS custody/admin and remediation authority.
4. SQLite full read-only immutable integrity and exact independently pinned original historical SHA.
5. Application, DNS and timer units, notification template, HTTP/Docker listeners, all retained Docker containers and update recovery guard.
6. CrowdSec package, separately checked security engine and host INPUT-only bouncer, disabled Cloudflare Worker.
7. Package manager database, volatile /run tmpfs, no swap and NTP.
8. Installed 27-ID doctor classification by allowlisted status and ID (no raw diagnostic messages), plus independent volatile runtime path classification.
9. Protected preboot checkpoint hash comparison for original config, Age/SOPS, dedicated volume, restored SQLite, accepted P8O evidence and original P8P source.
10. P8P original snapshot parity only when no independent group is BLOCKED.

No cloud, DNS, Worker, firewall, Docker start, application, Box read/write, pruning, SMTP, timers, package install, reboot or disk mutation is permitted. The only newly written files are one root-private sanitized P8Q summary and the existing product doctor's root-private logs in that diagnostic folder. Do not paste original checkpoint or protected file hashes.

## Decision boundaries

Expected normal debug output is a short list of failed categories and other PASS/PENDING results, rather than an arbitrary exception string. BLOCKED/2 still means **no automatic remediation or rerun of the existing P8P**. Analyze the specific failed category, then propose a separately reviewed corrective gate as needed. Do not assume CrowdSec, the data disk, SOPS or local origin filter survived reboot merely because P8O passed before reboot.

Production and live public startup remain NO-GO: the shared public hostname still lacks independent isolated-origin approval; Worker Route Fail Open, live Caddy/TLS, Box test-only backup/timers and rollback have not been accepted. Original restored VM, historical Box data and public Cloudflare configuration remain protected. Securely retire the disposable unencrypted ext4 volume after acceptance because P8M staged plaintext there.

**Only share P8Q's sanitized stdout and P8Q_EXIT.** Never share the full doctor JSON, secrets, private Age identity, recovery ZIP/passphrase, private logs, restored data or original marker JSON.
