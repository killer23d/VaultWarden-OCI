# P8I-D — read-only classification of the stopped-state failure

**Source candidate; P8I-D real-host NOT RUN.** This diagnostic is based on the unchanged release-branch baseline, independent of PR #398 and the installed rc.12 runtime. It does **not** update the installed application or change systemd, Docker, the OCI VNIC, Cloudflare, DNS, Worker, Box, SMTP, timers, storage or recovery.

## Previously accepted evidence

On **NEW disposable** `vaultwarden-oci-7-vnic`, accepted first P8H consented install returned **HOLD/P8H_INSTALL_EXIT=0**, after formatting the separately approved 50 GiB non-boot data disk only once and installing pinned rc.12. The original installed app remained stopped; backup remote and automatic pruning remained disabled. Never rerun P8H format/install.

The first P8I read-only post-install witness ran at reviewed commit `21e718367088695b191e986d949b912c951505b5` and returned **117 focused production tests PASS, P8I_EXIT=2 / BLOCKED**. Its first four stages PASS:

- Original root-private successful P8H checkpoint/attempt marker/HOLD evidence unchanged.
- Full immutable rc.12 **52 files and 12 installed systemd unit bytes** match reviewed source.
- Dedicated non-root ext4 and dual ownership markers match the original P8G disk, safe UUID fingerprint `2449f67320a1`.
- Protected config `bw.lazymocha.com`/`bw@lazymocha.com`, zero-pruning/disabled Box remote, operational SOPS + original offline **public** Age recipient PASS.

P8I then **BLOCKED** inside `service_state()` during `stopped app and restore absence`, without reporting which subcondition. Root-private old summary `~/vwoci-acceptance/p8i-postinstall-20261104T214222Z-4058/summary.txt`. **This is a valid hard stop; no P8I acceptance, restoration or live-start authorization.**

## Diagnostic scope

P8I's original `service_state()` checked four things in order, but grouped them under one generic error:

1. Each of **12 installed systemd units**, including the uninstantiated `vaultwarden-oci-notify@.service` template: `LoadState=loaded`, `ActiveState=inactive`, and not unit-file enabled/linked. A legitimate systemd template query can behave differently across implementations; this must be **observed** on the NEW host, not guessed or treated as an automatic exception.
2. Local TCP 80/443 listener absence, without printing listener addresses.
3. `/var/lib/docker/containers` on-disk metadata directory absent/empty (no Docker client/socket queries).
4. `/var/lib/vaultwarden-oci/data/db.sqlite3` absent prior to any separately consented restore.

The P8I-D source uses **only read-only** `systemctl show` and `ss -H -lnt` commands, `lstat` and directory-entry counting; no Docker command, `systemctl daemon-reload`, service start or `vwctl` command. It independently requires `ubuntu` + `sudo -n`, **exact NEW host**, Ubuntu 26.04 ARM64/Python 3.14, exact clean reviewed Git source and the previously recorded **root-private P8I BLOCKED stage**. If any of these cannot be proven, it refuses before running.

Output consists of **only a newly created root-private sanitized** `~/vwoci-acceptance/p8id-stopped-state-*/summary.txt`. It prints the allowlisted unit names, known `loaded/not-found`-type/active/enablement category labels, 80/443 **counts**, Docker container metadata **count without IDs**, and SQLite **presence/type without content**. No Docker IDs, socket addresses, raw systemd output, journals, secrets, Age keys, SOPS/backup/DB contents or other private files are shown. Existing P8F/P8G/P8H/P8I evidence remains unchanged.

| Result | Interpretation |
|---|---|
| `BLOCKED`, exit 2 | A P8I stopped-state subcondition is still violated or could not be safely inspected. The report should identify the safe category for source review. It is **not** permission to change any state. |
| `HOLD`, exit 0 | All original stopped-state subchecks now look safe in this read-only classification. **Original P8I BLOCKED still stands** until a separate corrected gate reproduces and validates the original checks. |
| Early `BLOCKED`, exit 2 | Original failed P8I evidence missing/changed, host or Git commit mismatch. Do not guess, repair or override. |

A query showing `LoadState=not-found` for `vaultwarden-oci-notify@.service`, for example, may indicate an **acceptance-validator mismatch**, but is not grounds to loosen runtime safety without a reviewed code/test change. An **active/linked/enabled** unit, unexpected TCP 80/443 listener, persisted Docker container, or pre-restore SQLite file remains a genuine hard safety blocker until investigated.

## Operator method

Run the approved one-shot **only on `ubuntu@vaultwarden-oci-7-vnic`** from P8I-D's exact CI-reviewed PR SHA; first run focused production tests, then the diagnostic with `sudo -n python3 -B -E`.

Paste only the sanitized summary and `P8ID_EXIT`. Do not paste the old private P8I summary file, the P8H installer logs, any Age identity/private ZIP, raw `systemctl` output, disk alias or Docker IDs.

After classification, open a **separate exact-pinned source correction** only if the observed problem is a test assumption (e.g., an uninstantiated template). Then rerun the corrected full P8I witness on the untouched host. If the problem is real, stop and investigate with additional read-only evidence; no automated remediation.

**No encrypted recovery, Cloudflare DNS or certificate issuance, Caddy/Vaultwarden start, SMTP, Box write, timer, reboot or production cutover is authorized by P8I-D.**
