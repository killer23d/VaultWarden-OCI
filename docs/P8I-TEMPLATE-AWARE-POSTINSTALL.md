# P8I-R — corrected complete post-install witness after template-only diagnostic

**Status: SOURCE CANDIDATE, real-host P8I-R NOT RUN.** A NEW acceptance branch directly from the unchanged release baseline. This gate is read-only and **does not** install, format, mount, restore, call the Docker socket, start services, write Box, change DNS/Cloudflare/Worker/OCI rules, issue certificates, send SMTP, enable timers or reboot. The original restored `vaultwarden-oci-6-vnic` must stay untouched.

## Actual operator evidence (2026-11-04 UTC)

After a separately typed and approved **single** format/install on NEW disposable `vaultwarden-oci-7-vnic`, corrected P8H first install passed with `P8H_INSTALL_EXIT=0`, **installed-but-stopped HOLD**. The exact rc.12 release, dedicated 50 GiB ext4 with dual markers, original offline **public** Age recipient and operational SOPS, locked `bw.lazymocha.com`/`bw@lazymocha.com`, blank remote and zero retention passed. The exclusive `install-attempted.json` prevents installer replay.

The original first **P8I** at reviewed commit `21e718367088695b191e986d949b912c951505b5` ran 117 focused tests OK and returned **BLOCKED/exit 2** at the final `service_state()` stage. P8I's earlier checks **PASSED**: original P8H attempt/checkpoint/HOLD evidence; 52 immutable product files/12 installed unit bytes; dedicated ext4 dual markers (safe UUID fingerprint `2449f67320a1`); encrypted config/SOPS/original offline public recipient and zero-prune remote-disabled settings.

The independent, immutable **P8I-D diagnostic** at reviewed commit `3f91289b98fc8bdb9e16058b258f5d0fd8188ea1` ran 119 focused tests OK and returned **BLOCKED/exit 2**, revealing:

- All **11 concrete** systemd units: `query=ok load=loaded active=inactive`, with unit files `disabled` or `static`: **PASS**.
- The **uninstantiated** `vaultwarden-oci-notify@.service` template: `query=unavailable load=absent active=absent unitfile=absent` from a direct `systemctl show` of the bare template: **BLOCKED**, exposing the P8I test assumption.
- Local TCP 80/443 listeners: **0/0**, no unparseable rows. Docker container metadata count: **0**. Pre-restore SQLite database: **ABSENT**. All **PASS**.

The original P8I BLOCKED and P8I-D BLOCKED are valid historical observations; **never relabel** either as passed. Their root-private summaries are immutable source evidence:

- `~/vwoci-acceptance/p8i-postinstall-20261104T214222Z-4058/summary.txt`
- `~/vwoci-acceptance/p8id-stopped-state-20261104T214945Z-4163/summary.txt`

**There was no need for, and NO authorization to, repair systemd, reformat, reinstall or restart.** This patch changes only acceptance validation. It does NOT relax checks on notification instances or real active/enabled services.

## Corrected source contract

The independent P8I-R read-only instrument `tests/host-acceptance/production-p8i-template-aware-postinstall-witness.py`:

1. Requires NEW `vaultwarden-oci-7-vnic`, `ubuntu` with passwordless `sudo -n`, exact clean reviewed PR branch/SHA, Ubuntu 26.04 ARM64, Python 3.14 and pinned rc.12 manifest. It refuses the original recovered VM.
2. Binds the historical root-private successful P8H one-shot attempt marker, exact checkpoint/boot ID and original P8G block witness, plus the **original first-P8I BLOCKED** and **P8I-D template-only diagnostic BLOCKED**. Refuses any unexpected second diagnostic blocker; preserves all original summaries unmodified.
3. Rehashes **all 52** source/installed product files and **12** systemd unit files; checks canonical immutable release, dedicated mounted ext4 and dual device/boot separation markers; original off-host **PUBLIC** recovery recipient and operational SOPS custody (decrypt **only** to `/dev/null`), locked hostname/email and disabled remote/retention 0/0.
4. For **11 concrete installed units**, preserves the strict original `LoadState=loaded`, `ActiveState=inactive`, and not enabled/linked requirements. No acceptance shortcuts.
5. For the **static, uninstantiated `vaultwarden-oci-notify@.service` template ONLY**, does **not** call `systemctl show` on the bare template name. Instead requires the root-owned installed template file's bytes and modes to match the immutable audited release and verifies **read-only**:
   - `systemctl list-unit-files --all --no-legend --no-pager --plain 'vaultwarden-oci-notify@*.service'` returns exactly one static template, **no enabled/linked instance alias or unexpected file**;
   - `systemctl list-units --all --no-legend --no-pager --plain --full 'vaultwarden-oci-notify@*.service'` reports **no instantiated notification units at all**.
   
   If either command cannot be read or returns unexpected entries/states, P8I-R still **BLOCKS**. The empty-instance requirement is intentionally conservative and protects against disguised active, enabled, failed or leaked notification instances.
6. Continues to require zero local TCP 80/443 listeners, no retained Docker containers (Docker socket **not queried**) and no pre-restore SQLite DB.
7. Writes **only** a NEW root-private `~/vwoci-acceptance/p8ir-postinstall-*/summary.txt` containing safe status/identity fingerprints. No private data, disk paths, OCIDs, raw systemd output or secrets are printed. Original P8F–P8I-D evidence is left unchanged.

## Expected outcomes and subsequent gates

- **HOLD / exit 0** means the corrected complete local postinstall witness passes, including template-specific strict no-instance checks. It **does not** grant restoration, public exposure, DNS/ACME, Cloudflare Worker, SMTP or Box permissions.
- **BLOCKED / exit 2** means an original storage/custody/stopped-state predicate still fails, or the static template/instance inventory is different or cannot be queried. No repair, install retry, implicit approval or original-host modification.

Even after P8I-R passes, the next step is a separate **read-only encrypted recovery-source and identity/host-swap risk gate**, with *explicit* original ciphertext provenance/sha256, independent off-host private Age key/ZIP custody, safe tmpfs/swap plan and no historical Box writes. An independently approved future destructive restore and separate first HTTPS test must then preserve test-origin isolation, particularly because **both** the new and original stopped VMs configure `bw.lazymocha.com`.

**Production GO/NO-GO has not been reached. No restore/live-start/Cloudflare DNS/Worker/SMTP/Box/timer or reboot is authorized.**
