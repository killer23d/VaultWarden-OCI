# Supported-host validation and disposable-host acceptance

Supported hosts are Ubuntu 24.04 LTS Noble and Ubuntu 26.04 LTS Resolute on `amd64` and `arm64`.

The established disposable Ubuntu 24.04 release baseline remains applicable where available. Ubuntu 26.04 is covered by source review, automated checks, native Python 3.14, explicit x64/Arm64 CI, package/repository and systemd checks, **and actual OCI ARM64 acceptance performed on October 30–31, 2026**. The frozen rc.11 A0–C1/B2 and corrected rc.12 D1R/D2 gates are recorded in the [historical infrastructure and host acceptance archive](HISTORICAL-INFRASTRUCTURE-ACCEPTANCE.md). **Ubuntu 26.04 AMD64 real-host acceptance, uninterrupted initial rc.12 first-pass install, full live rc.12 application/security/batch operation, and production cutover remain NOT RUN.** Do not extend one gate's PASS to another.

Record unavailable architecture/provider/destructive coverage as **NOT RUN**; CI mocks or container integrations do not turn missing real-host evidence into `PASS`.

The gate is intentionally appliance-sized for a small team: prove the supported operator paths and security ownership boundaries directly rather than inventing a second orchestration or migration layer just for acceptance.

**Software-release acceptance is the active contract.** The old
VM-specific rc.11/rc.12 stage one-shots, OCI provider/Cloudflare
inventories and their duplicate reports are preserved only in
[Historical infrastructure acceptance](HISTORICAL-INFRASTRUCTURE-ACCEPTANCE.md)
at an immutable Git commit. They are not release criteria to replay on a
new VM. Keep product-level fail-closed origin security, install,
recoverability, and rollback validation below; do not infer live
security from source or a stopped reference host.

The two retained reusable host instruments are
`tests/host-acceptance/production-new-host-preflight.py` for a
clean blank host and `tests/host-acceptance/production-readiness-inventory.py`
for a deliberately selected already-installed appliance.
Both are read-only inventories; neither grants consent to install,
format, activate, alter provider policy or restore.

## Release-readiness reconciliation: rc.15 (RC15-G, 2026-11-19)

**Decision: scoped software acceptance PASS after G5; release publication and production GO remain HOLD.** See the November 24 G5 reconciliation below. Original review baseline is immutable
[commit `91162bc3e0188f3a75a565b90aff1ea62c6324d0`](https://github.com/killer23d/VaultWarden-OCI/commit/91162bc3e0188f3a75a565b90aff1ea62c6324d0).
The RC15-G review began at this commit. The final G5-reviewed integration baseline, exact installed source comparison and CI are recorded below; later commits require their own applicable CI. The authoritative rc.15 installed live
candidate, VM8 receipts and the RC15-C Git-index exception remain recorded
**only** in [the consolidated historical acceptance archive](HISTORICAL-INFRASTRUCTURE-ACCEPTANCE.md).
The [rc.13 P3-G11C–G11G populated-vault remote recovery results](#current-rc13-p2p3-software-acceptance-evidence--november-18-2026-utc)
remain valid *earlier-release* evidence. The separate VM9 G3 result below now proves the exact installed rc.15 automated remote recovery regression; it does not broaden the earlier rc.13 evidence.

| Release gate | Status as of reconciliation | Evidence / bounded next step |
| --- | --- | --- |
| Exact rc.15 source, component pins and release review | **PASS — G5AB** | Reviewed integration `fc7d00c43ad9601d6bc4feda9089cef8d8b95ef6`; installed source `162289365800ffe814517fbed920b5066cba4c33`. Direct two-tree comparison of release-owned source and supported entrypoints unchanged; all 56 installed files verified. |
| Exact rc.15 candidate CI | **PASS — reviewed integration baseline** | [Final integration CI](https://github.com/killer23d/VaultWarden-OCI/actions/runs/45320144059) 9/9 at `fc7d00c43ad9601d6bc4feda9089cef8d8b95ef6`; prior [candidate CI](https://github.com/killer23d/VaultWarden-OCI/actions/runs/44618010233) and [harness CI](https://github.com/killer23d/VaultWarden-OCI/actions/runs/44628483849) retained. Subsequent documentation commit requires separate CI. |
| Supported rc.14 → rc.15 upgrade / Worker re-arm and Fail Open | PASS | VM8 RC15-A/B, supported upgrade with recovery and new invocation/Route readback; see historical archive. Do not replay. |
| Real reboot, selected application/Worker activation and four scheduled jobs | PASS for expressly staged VM8 scope | VM8 RC15-C/D/E; RC15-C Git-index wrapper exception retained, independent RC15-D corrected-source check PASS. RC15-F cleanup deliberately disabled future auto-start; no further VM8 work. |
| RC15-G0 new-host read-only source/storage preflight | PASS at `d847fbfc861a5be0886e4d911f51649619e33def` | Operator report from `vaultwarden-oci-9-vnic` at `2026-11-21T07:04:42Z`: exact source/preflight blob `56176804491c9ab9c38b1e1efb3386aab40e3c60`, 10/10 focused tests, Ubuntu 26.04 ARM64/Python 3.14.4, root `/dev/sdb1` excluded, 50 GiB unmounted signature-blank nonboot candidate with stable alias, no installed appliance, `RC15_G0_EXIT=0`. Protected local evidence: `~/vwoci-acceptance/production-newhost-p0-20261121T070442Z-13549`. Disk attachment and format authorization remain **PENDING**. Any later source commit is not retroactively tested. |
| Exact rc.15 fresh blank-disk installation and first-run offline recovery-kit custody | **PASS (scoped VM9 G1)** | Ubuntu 26.04 ARM64 `vaultwarden-oci-9-vnic`: G1A installer dry run and wrong-custody/boot-disk refusals PASS at source `162289365800ffe814517fbed920b5066cba4c33`; G1B separately approved formatting of blank 50 GiB dedicated disk alias `scsi-360a00918965d4e0eac9abd8c1d3e9dea`, ext4 UUID `0d043614-606c-4098-9617-1b1467155b6f`, followed by real setup with transient Age custody and verified encrypted five-member recovery-kit ZIP. Preserved external wrapper faults: initial G1B two malformed Python heredocs printed `IndentationError` and a **false wrapper success**; first G1B-R stopped after 56 exact installed files and storage PASS because its hard-coded hostname did not match the intentionally configured `bw.lazymocha.com` / `bw@lazymocha.com`. Corrected **G1B-R2 PASS** independently verified installed release/storage, owner/modes, configured non-production domain, SOPS recipients, transient-key absence, exact AES-256 member set, valid installed CLI/config/secrets, stopped app/target and no running containers. Off-host emailed ZIP SHA-256 independently matched the on-host ZIP: `6a34d1e9c70d4f0fa6c4b3aa14652533b71b1b969c9084855bdcabce5d2f2770`; `RC15_G1BR2_EXIT=0`. Private receipt `~/vwoci-acceptance/rc15-g1br2-20261122T191643Z-19675`. This proves matching ciphertext delivery, **not** separately entering the off-host passphrase to decrypt the copied ZIP. No public DNS, Worker, firewall, container start, or remote recovery gate was accepted by G1. |
| Real non-Cloudflare origin denial across Docker DNAT/FORWARD and userland proxy; fail-closed policy | **PASS — VM9 G2 software packet path corroborated; separate OCI provider API audit NOT RUN** | Exact rc.15 source `162289365800ffe814517fbed920b5066cba4c33`. G2D separately authorized one existing proxied A-record repoint `bw.lazymocha.com` to VM9 `163.192.44.228`, in-sync readback. G2E from independent Cloud Shell Public Network `152.67.228.206`: genuine Cloudflare TLS-protected requests to `/`, `/api/config`, `/admin/` returned 200/200/401 with CF-Ray; direct public TCP22/80 not accepted; two direct HTTPS origin probes timed out (curl exit 28). G2D did **not** observe a Docker DROP counter increase from its own baseline, and correctly exited 2 HOLD (retain). G2F/G2P then used independent PNA path to VM9 private IPv4 `10.0.0.211`: private TCP22 connected, two non-Cloudflare direct HTTPS probes timed out (exit 28); `RC15_G2P_EXIT=0`. Independent read-only SSH G2F-R re-read G2F baseline `VWOCI-CF-HTTPS` DROP packets 21 and current 27 (+6) after the private probes; doctor all mandatory security IDs PASS / overall WARN, in-sync DNS, current Worker Route prefix `c5ccbbc6` and Fail Open, unchanged dedicated ext4, both containers healthy; `RC15_G2FR_EXIT=0 DOCKER_DENIAL_CORROBORATED`. Correlated counters support the local Docker filter, but are not per-source packet attribution. Private G2F-R receipt: `~/vwoci-acceptance/rc15-g2fr-20261122T212908Z-33838`; G2P private Cloud Shell receipt `~/vwoci-acceptance/rc15-g2p-pna-20261122T212338Z-1259`. **OCI effective security-list/NSG policy API inventory NOT RUN**, an administrator network-configuration audit, not a duplicate software gate. Do not claim its proof. No host/Worker/DNS mutation in G2F/G2P/G2F-R. |
| Exact rc.15 Caddy/Admin/local TLS, CrowdSec and core health | **PASS — VM9 G2C TLS + G2E public HTTPS + G2F-R post-probe security** | VM9 G2B supported CrowdSec setup, exact Worker invocation/Route Fail Open readback, secured startup, all mandatory doctor IDs PASS, both Caddy/Vaultwarden healthy. Its first immediate TLS handshake failed `curl (35)` and correctly stopped G2B with exit 2; later read-only G2C observed completed ACME certificate issuance and verified SNI/trust local `/`=200, `/api/config`=200, unauthenticated `/admin/`=401, `RC15_G2C_EXIT=0`. G2E independently proved all three same responses over real Cloudflare HTTPS with CF-Ray, and G2F-R reconfirmed doctor PASS on required IDs and both live containers healthy. Original transient hold and subsequent independent PASS receipts retained; broader admin authenticated browser workflows beyond exact rc.15 test scope are not implied. |
| Populated-vault remote publication, remote ciphertext readback, offline cryptographic verification and actual remote restore | **PASS — exact rc.15 VM9 G3 automated recovery and operator-confirmed item-presence smoke** | On installed source `162289365800ffe814517fbed920b5066cba4c33`, VM9 G3A–G3C-R3 independently proved isolated encrypted Box backup publication/readback, matching offline Age identity via the password-protected **local** recovery-kit ZIP, native remote restoration with restart, one original user and cipher restored exactly, later cipher absent, SQLite integrity, running runtime and doctor PASS. `RC15_G3CR3_EXIT=0 PASS REMOTE_RECOVERY_ACCEPTANCE; BROWSER_SMOKE=PENDING; RELEASE_GO=HOLD`. Automation intentionally inactive; status exit 1 correctly reflects that boundary. See detailed G3 evidence below; no repeat backup or restore needed. Operator subsequently confirmed that only the original item remains in the Web Vault. Separate off-host emailed ZIP decryption and explicit field-by-field browser-content verification are not independently established. |
| SMTP and operational notifications | **PASS for direct rc.15 SMTP + independent mailbox receipt; HTTPS operational route NOT RUN** | VM9 G2A on exact installed rc.15: operator authorized one `vwctl notification test --smtp` at `2026-11-22T19:22:48Z`; appliance reported authenticated SMTP accepted and operator independently confirmed fresh test message received with `RECEIVED_G2A_SMTP_MESSAGE`. Earlier first-run recovery-kit attachment reached off-host custody with exact ciphertext checksum. Distinct optional HTTPS provider/fallback was not configured/tested; do not claim its PASS or repeat SMTP without reason. Protected VM9 G2A receipt `~/vwoci-acceptance/rc15-g2a-20261122T192240Z-19860`. |
| Controlled failure, quarantine and rollback/recovery safety | **PASS — scoped VM9 G4 live negative recovery and isolated regressions; live update failure/rollback NOT RUN** | Exact installed rc.15: 294 focused ARM64 source tests passed, 56 immutable files verified, six native negative/cancel paths and unchanged pre/post safety evidence passed. The separate real update failure, quarantine, and coherent update rollback transition remains NOT RUN; isolated regression evidence is not a live transition. See G4 evidence below. |
| Supported automation lifecycle on VM9 | **PASS — G5CR scoped live service and timer activation** | Clean lifecycle start without container recreation, actual backup/maintenance/update-check/health and separate DNS no-change service success, four timers active through enabled target, structured status PASS; returned to isolated scheduling with lifecycle/app still running. Natural timer triggers NOT OBSERVED in VM9. See G5 evidence below. |
| Final release notes/tag/publication and production decision | HOLD — explicit authorization pending | Scoped software acceptance and independent off-host kit check completed; final targeted gap closure and review/CI pending. No version bump, tag, publication or production GO authorized. AMD64 live remains NOT RUN/best effort. |

**VM9 G1B-R read-only follow-up (operator reported, 2026-11-22 UTC):** The first independent verifier proved 56 release files byte-identical to the pinned rc.15 checkout and checked dedicated ext4 UUID/boot separation (`PASS`). It then exited `RC15_G1BR_EXIT=2 HOLD` because an *external test wrapper*, not the appliance, had hard-coded `vwoci-rc15-vm9.bw.lazymocha.com`. The operator intentionally uses the non-production `bw.lazymocha.com` with `bw@lazymocha.com`; this is an input-expectation mismatch, not evidence of an application configuration failure. Subsequent SOPS recipient, ZIP member/AES mode, service-state and off-host attachment-hash checks were not executed and remain pending. Private receipt: `~/vwoci-acceptance/rc15-g1br-20261122T191006Z-19675`. Do not rerun setup/format or send another recovery-kit email. The shared hostname is **not** proof of DNS/Worker-route isolation from older labs; do not perform Cloudflare/DNS/firewall mutations without a separate review and authorization.

**VM9 G2A read-only Cloudflare/SMTP result (2026-11-22 UTC):** Product source and dedicated storage PASS; `G2_DNS_ORIGIN=DIFFERENT_ORIGIN`, one effective matching Worker Route and no Worker Custom Domain, yielding `RC15_G2A_EXIT=2 HOLD` **solely due to unresolved external Worker ownership**, not an SMTP failure. The separately authorized direct SMTP test completed with `SMTP_NOTIFICATION=PASS_INDEPENDENT_MAILBOX_RECEIPT`; preserve the mixed-status result. Operator confirms terminated VM8 and continuing dedicated-use testing of `bw.lazymocha.com` / `bw@lazymocha.com`. Private G2A receipt `~/vwoci-acceptance/rc15-g2a-20261122T192240Z-19860`. Release GO remains HOLD. No DNS/Cloudflare/firewall mutation, activation, or live packet test authorized by this G2A receipt.

**VM9 G2B bounded live security result (2026-11-22 UTC):** The earlier G2B launcher SHA-256 typo stopped before execution; corrected launcher verified both script SHA-256 and Git blob. The grouped run explicitly authorized the scoped old-Route deletion, CrowdSec/firewall setup, fresh Worker Fail Open, and first start. All passed with doctor zero FAIL and both containers healthy. The next immediate `curl --resolve bw.lazymocha.com:443:127.0.0.1 https://bw.lazymocha.com/` failed TLS handshake with `tlsv1 alert internal error`; **`RC15_G2B_EXIT=2` and `G2B_WRAPPER_EXIT=2` are preserved**, not promoted to PASS. No current G2B DNS repoint was executed and the A record still referenced another origin at the prior preflight. Do not re-run G2B or blindly restart services, modify Cloudflare DNS, or turn off origin filtering to bypass TLS. Read-only Caddy ACME and certificate investigation next; fresh external network proof remains pending.

**VM9 G2C independent TLS reconciliation (2026-11-22 UTC):** The operator ran a subsequent read-only diagnostic with both containers `running/healthy`; Caddy certificate issuance was observed (`CERTIFICATE_OBTAINED:1`, certificate inventory count 1). The HTTPS/SNI probe with normal trust verification returned `/=200`, `/api/config=200`, `/admin/=401`. `RC15_G2C_EXIT=0 LOCAL_TLS_VERIFIED_PASS`; no DNS, Worker, firewall or restart mutation. This resolves the separate G2B *local TLS gate*, but does not rewrite the historical G2B exit=2. Runtime code implements Compose container readiness and Caddy admin endpoint health; the first public ACME DNS-01 certificate is asynchronous. Correct the **acceptance harness**, not the immutable installed rc.15 runtime: a bounded trust-validating HTTPS probe now lives in `tests/host-acceptance/https_readiness.py`, covered by four offline regressions in `tests/test_https_readiness.py`. Documentation under `docs/INSTALL.md` describes why TLS/SNI verification must precede any separately authorized DNS publication. A full runtime-source change would require a distinct immutable release candidate and new acceptance evidence; not justified by this transient test observation. External non-Cloudflare packet and restore/failure gates remain outstanding.

**VM9 G2D/G2E external evidence and remaining HOLD (2026-11-22 UTC):** G2D separately authorized one repoint of the **already existing** proxied IPv4 A record `bw.lazymocha.com` to the current VM9 origin, preserving Worker Route/Fail Open and local Caddy 200/200/401. G2E independent Cloud Shell Public Network HTTPS returned 200/200/401 through genuine Cloudflare (`CF-Ray` observed); TCP22/80 did not accept connections; non-Cloudflare direct TCP443 probes failed with curl exit 28 twice. These are **real external-access behavior PASS**, but G2D post-probe software-packet-path gate **HOLD**: `VWOCI-CF-HTTPS` DROP counter did not increase from baseline 7. Do not classify an upstream OCI block as proof that an external packet traversed Docker DNAT/FORWARD; do not open public SSH/80, remove host filtering or rerun DNS update to force the gate. Use source-specific passive VNIC observation and the existing counter in the next read-only window; source inventory/provider policy review if no ingress reaches the VM. Protected receipts remain local at `~/vwoci-acceptance/rc15-g2d-vm9-20261122T203222Z-27756` and Cloud Shell `~/vwoci-acceptance/rc15-g2e-public-20261122T203439Z-1804`. G3/G4/final GO remain gated.

**VM9 G2D/G2E split outcome (2026-11-22 UTC):** VM9's one approved DNS publication wrote and independently read back the single existing proxied A record `bw.lazymocha.com` to VM9 public IPv4 `163.192.44.228`; no AAAA/Worker modification, live Caddy and Vaultwarden healthy, doctor WARN/zero FAIL, Worker current-invocation and Fail Open PASS. Independent Cloud Shell Public Network proved real Cloudflare-proxied HTTPS 200/200/401 with `CF-Ray`, public TCP22/80 did not accept connections and direct-to-origin HTTPS/443 was denied twice (curl exit 28), source IPv4 `152.67.228.206`. G2E result `RC15_G2E_EXIT=0 EXTERNAL_CLOUDFLARE_ACCESS_AND_DIRECT_DENIAL_PASS` remains valid for this observational boundary. **G2D correctly returned `RC15_G2D_EXIT=2`**, because its `VWOCI-CF-HTTPS` DROP counter did not increase after public Cloud Shell probes (initial 7). That does **not** establish that Docker filtering blocked the public source: the OCI provider may have dropped the packets upstream. Keep this as a separately scoped software datapath HOLD. Proposed next proof is a private-network PNA non-Cloudflare probe with VM9 counter correlation while all currently healthy services, firewall policy, Worker and proxied DNS remain untouched. No production GO/merge/tag until required remaining tests pass.

**VM9 G2 FINAL software acceptance reconciliation (2026-11-22 UTC):** G2E from independent Cloud Shell **Public Network** returned `RC15_G2E_EXIT=0` after Cloudflare-proxied 200/200/401 with CF-Ray, external public TCP22/80 denial, and two direct non-Cloudflare public origin HTTPS timeout probes. The G2D same-window Docker counter did not increase and correctly remained `RC15_G2D_EXIT=2 HOLD`; **do not erase that exception**. G2P then ran from approved **Private Network Access**, established private TCP22 connectivity to `10.0.0.211`, and independently denied two direct private non-Cloudflare HTTPS probes with curl exit 28: `RC15_G2P_EXIT=0 PRIVATE_NON_CLOUDFLARE_443_DENIED` (operator Cloud Shell private receipt `~/vwoci-acceptance/rc15-g2p-pna-20261122T212338Z-1259`). After those probes, G2F-R executed over a fresh authenticated private SSH connection, verified the earlier G2F Docker `VWOCI-CF-HTTPS` DROP baseline of 21 and a current count of 27 (**delta +6**), reconfirmed all mandatory doctor/security checks PASS (overall WARN with zero FAIL), current Worker `c5ccbbc6...` and Cloudflare Fail Open, proxied in-sync DNS to `163.192.44.228`, dedicated ext4 UUID unchanged and both containers `running/healthy`. Final `RC15_G2FR_EXIT=0 DOCKER_DENIAL_CORROBORATED` (VM9 private receipt `~/vwoci-acceptance/rc15-g2fr-20261122T212908Z-33838`). Counter correlation supports local Docker deny enforcement in a private-network test; does not prove that the earlier *public* probe reached Docker nor identify individual packet sources. **G2 software-network functional acceptance = PASS (scoped)**; external OCI provider effective security-list/NSG API inventory remains **NOT RUN** and should be tracked distinctly as operator network configuration audit, not silently promoted to PASS. No further G2 mutation or reboot required; next G3 exact rc.15 isolated remote recovery gate, then G4 failure/recovery, then separate explicit release decision. No merge/tag/GO authorized.

**G0 read-only handoff:** Run the existing
`tests/host-acceptance/production-new-host-preflight.py` on the **new host,
not Cloud Shell and never VM8** with `--purpose fresh-install
--expected-version 0.1.0-rc.15 --expected-sha <exact reviewed RC15-G HEAD>`.
Pin the branch HEAD before cloning, verify clean unprivileged Git status
*and its exit code*, run `tests/test_production_new_host_preflight.py`,
then invoke the instrument with `sudo -n python3 -B`. Its **exit 0 means
PENDING inventory, not authorization**. Exit 2 means BLOCKED. G0 never
mounts/formats storage, installs packages, starts services, changes firewall,
contacts SMTP/Box/Cloudflare or restarts the host. Protected evidence is
operator-private in `~/vwoci-acceptance`; share only its sanitized summary.
Storage identity/blankness still require independent operator verification.

**Preserved CI exception:** Initial RC15-G branch commit `d847fbfc861a5be0886e4d911f51649619e33def` passed eight of nine CI jobs but [the quality-unit documentation audit failed](https://github.com/killer23d/VaultWarden-OCI/actions/runs/44635980353) because this matrix contained a disallowed product-generation branch label. This documentation-only audit failure is preserved as FAIL for that exact run; the label was removed without weakening the audit. On corrected source `162289365800ffe814517fbed920b5066cba4c33`, [push CI](https://github.com/killer23d/VaultWarden-OCI/actions/runs/44878652985) passed 9/9; the [PR run](https://github.com/killer23d/VaultWarden-OCI/actions/runs/44878656660) initially failed container-originated HTTPS egress on the runner but passed all nine jobs on its second attempt. Preserve the initial runner failure; do not imply the revised evidence-only documentation commit has been tested by those earlier runs. The later evidence-only documentation commit `a1ff73080b6bb0a3a29c33e07d42a798b5d73526` separately passed all nine jobs in both [push CI](https://github.com/killer23d/VaultWarden-OCI/actions/runs/45059731409) and [PR CI](https://github.com/killer23d/VaultWarden-OCI/actions/runs/45059737102). Any subsequent documentation HEAD must be evaluated separately. No appliance runtime source or preflight instrument changed.

### VM9 G3 exact rc.15 populated remote recovery — November 23–24, 2026 UTC

**Automated remote recovery: PASS; browser item-presence/absence smoke: PASS (operator-confirmed); production GO: HOLD.** Operator-reported live terminal evidence, Ubuntu 26.04 ARM64 on disposable `vaultwarden-oci-9-vnic`, immutable installed rc.15 source `162289365800ffe814517fbed920b5066cba4c33` (56 release files byte-identical), dedicated ext4 UUID `0d043614-606c-4098-9617-1b1467155b6f`. This evidence applies to the installed candidate, not to a later documentation HEAD. G3 did not re-run G0/G1/G2 or change the installed release.

| Gate | Observed result and preserved limits |
| --- | --- |
| G3A/G3A-R | Source, storage, local-only zero-retention policy, inactive backup timer, runtime, proxied in-sync DNS and current Worker Route Fail Open passed. Original `RC15_G3A_EXIT=2 HOLD: BOX_PARENT_ID_NOT_AVAILABLE` reflected an unnecessary provider-ID assumption in the external harness. G3A-R independently confirmed the existing Box parent and an absent candidate twice, ending `RC15_G3AR_EXIT=0 PASS READ_ONLY_RECONCILIATION`. No Box object writes in either read-only precheck. |
| G3B/G3B-F | Initial G3B safely held on the nonempty vault; inventory then proved one user, one cipher, zero organizations/attachments/folders, SQLite integrity OK. Operator explicitly attested that all records were synthetic/disposable and authorized the scoped test operations. Baseline cipher-record fingerprint: `4b966a356486f92b7b85cb8f424f99235b7a5336465472875af3ac524e62a752`. G3B-F inventory PASS was not backup or restore evidence. |
| G3B-P/G3B-P-R | G3B-P stopped before its mkdir/backup on `TEST_REMOTE_FOLDER_ALREADY_EXISTS`. The original candidate subsequently had one immediate child; its provenance was not established, and the continuation preserved it without reuse or deletion. G3B-P-R generated a different isolated directory, proved absence twice, created only that directory, and executed the supported one-time `vwctl backup --remote`. Product publication/readback and independent ciphertext SHA-256/byte-count comparison passed. The native secure-paste chooser in the nested harness did not display the next prompt; operator interrupted it, retaining `RC15_G3BPR_EXIT=2 HOLD: INTERRUPTED_OR_CANCELLED`. No raw Age private key was supplied in the recorded attempt. A subsequent direct terminal `vwctl recovery verify --from-remote` selected local recovery-kit ZIP (option 3) and accepted its hidden passphrase, reporting `PASS verified recovery` for the exact object below. This proves usable local encrypted-kit recovery, not independent decryption of the off-host emailed copy or resolution of all secure-paste UX paths. |
| G3C/G3C-R | Initial wrapper held because it assumed the live vault still contained one cipher. G3C-R proved two items already existed, with the original exact fingerprint preserved, and independently re-read the same remote ciphertext. The operator authorized disposable replacement; native `vwctl restore --from-remote ... --start --confirm RESTORE` used the local encrypted kit, reported successful cryptography/manifest/checksums/SOPS preflight and `PASS restored recovery point created 2026-11-23T23:45:10Z`. Independent post-checks proved one original cipher restored, the later cipher absent, unchanged dedicated storage/config/Worker invocation and Route, SOPS/doctor and running healthy containers, and trusted private HTTPS Web/API/Admin 200/200/401 before the final structured status command returned nonzero. Preserve `RC15_G3CR_EXIT=2 HOLD: postrestore` as an external wrapper status-handling exception, not a failed native restore. |
| G3C-R2/G3C-R3 | G3C-R2 preserved the prior delta/restore evidence but held on a missing user-fingerprint receipt field (`KeyError`). G3C-R3 correctly obtained the user fingerprint from the original G3C pre-hold receipt and independently verified the same user, exact original cipher, absence of the newer item, and SQLite integrity. `vwctl status --json` returned 1 with runtime `running`, doctor `PASS`, automation `FAIL`. All four timers and triggered services were inactive, each trigger result `success`, lifecycle target inactive/disabled, and no unexpected timer/target problems. This is the intentional acceptance state; the installed status implementation correctly reports automation not ready. `RC15_G3CR3_EXIT=0 PASS REMOTE_RECOVERY_ACCEPTANCE; BROWSER_SMOKE=PENDING; RELEASE_GO=HOLD`. No repeated backup/restore or timer enablement was needed. |

Exact new isolated recovery point: `bw-backup:bw-backup/rc15-g3-vm9-20261123T234459Z-61a2904627053c9af144aa97/recovery-20261123T234510Z-bc6087a3.vwrec`, created `2026-11-23T23:45:10Z`, **348,440 bytes**, SHA-256 `b64f50fb8140df7a83fbd84b4f8e4fb84a095922b739579b3a8a975aedee9e59`. The independent post-restore cipher-record fingerprint equals the pre-backup baseline above. Saved backup policy remains local-only, both retention policies zero; timers remain inactive. No historical Box object was intentionally modified, no pruning, no new DNS/Worker mutation or release publication.

Protected operator-private receipts are retained under `~/vwoci-acceptance/`: G3A `rc15-g3a-20261123T230016Z-ftKy2r`; G3A-R `rc15-g3ar-20261123T230503Z-VvGMlL`; original G3B `rc15-g3b-20261123T232137Z-d3hHD5`; fixture inventory `rc15-g3bf-20261123T232553Z-6MsSgP`; collision `rc15-g3bp-20261123T234029Z-Qd2V5S`; successful publication/readback with interrupted verification `rc15-g3bpr-20261123T234450Z-LAsjj0`; initial G3C `rc15-g3c-20261124T020052Z-wf1zog`; native restore and post-status HOLD `rc15-g3cr-20261124T023425Z-Zblk8X`; receipt-field HOLD `rc15-g3cr2-20261124T023832Z-3kTcb4`; final reconciliation `rc15-g3cr3-20261124T024309Z-ocpyLf/g3cr3-sanitized.json`. These paths are references to operator-reported evidence, not committed private receipts or independent access to the live host.

**G3 browser follow-up (operator confirmation):** After the G3C-R3 PASS, the operator reported, “Confirmed only the original item remains.” This closes the manual item-presence/absence smoke for the restored fixture. It corroborates the independently verified original cipher fingerprint and removal of the later cipher; explicit field-by-field client-content verification was not separately reported. Preserve the original terminal receipt's `BROWSER_SMOKE=PENDING` as its historical state, superseded only for this scoped manual observation.

**Remaining boundaries:** G4 exact targeted failure injection/rollback, independently reviewed final HEAD CI and production release GO remain outstanding. G3's actual recovery proves neither a fully enabled production automation schedule nor independent off-host key custody.

### VM9 G4 controlled failure, quarantine and coherent recovery — November 24, 2026 UTC

**Scope:** Exact installed rc.15 source `162289365800ffe814517fbed920b5066cba4c33`; VM9 G0–G3 evidence above remains accepted within its stated scope. G4 source review, fresh focused regression, native read-only preflight, targeted live negative recovery and post-test safety reconciliation are PASS within their stated scopes. Live update failure injection and coherent rollback are NOT RUN; production GO remains HOLD.

| Boundary | Source owner and existing regression evidence |
| --- | --- |
| Before possible persistent-state mutation | `update_appliance.apply_prepared` durably verifies the recovery artifact and publishes the exact guard before unit/pointer mutation. A proven pre-start failure restores the previous pointer and units and proves previous runtime health before clearing the guard. Existing update appliance, workflow, guard publication and interruption tests exercise the transaction ordering. |
| After possible persistent-state mutation | `PersistentStateFailure`, `_stop_candidate_locked`, `_engage_transaction_guard` and `_quarantine_current` refuse old-code-only rollback; an unclassified activation interruption is treated as possible mutation. `update_cli` blocks normal start/restart/restore/install and update apply while guarded; the systemd lifecycle unit delegates to installed start. |
| Coherent recovery and retry | `coherent_rollback` and `update_recovery.prepare_restore` require the exact recovery artifact and previous release, preserve guard-aware selection until data recovery, and retain the guard through guarded previous-runtime health proof. Rollback, crash-safety, fail-closed and interruption tests cover guard re-engagement, failed promotion and retry. |
| Negative recovery and storage | `recovery.restore_recovery` and `recovery_ux` validate cryptography, offline SOPS, identity and staged targets before stopping services. Existing recovery and UX tests exercise wrong identity, corruption, invalid manifest, cancelled recovery and refusal before live mutation. Storage tests exercise missing mount, wrong identity and boot-device refusal. |
| Security and diagnostics | Runtime activation gates CrowdSec/origin health; storage and distinct operational/offline Age custody are independently checked. Structured status distinguishes runtime/doctor from automation; deliberately inactive VM9 automation must not be treated as a live runtime failure or concealed as automation readiness. |

**Retrieved exact-source CI evidence:** [push run 44878652985](https://github.com/killer23d/VaultWarden-OCI/actions/runs/44878652985) completed successfully at the installed source SHA; all nine job conclusions are success. The [quality-unit log](https://github.com/killer23d/VaultWarden-OCI/actions/runs/44878652985/job/136768868996) records 584 tests and OK, including wrong-key/corruption/pre-stop, guard-publication ordering, post-start rollback refusal, coherent rollback guard retention, interruption quarantine, cancellation and wrong-storage checks. The [recovery-crypto integration log](https://github.com/killer23d/VaultWarden-OCI/actions/runs/44878652985/job/136768868980) records real Age/SOPS/rclone fresh-host recovery, verification, rekey and prune acceptance. Native Ubuntu 26.04 ARM64 compatibility and security integrations passed their own scopes. These are existing source and isolated integration results, not a fresh branch run or live VM9 update rollback.

**Operator-reported live VM9 acceptance:** Exact installed source and original G3 ciphertext/fixture remained unchanged. All runs used the disposable Ubuntu 26.04 ARM64 VM9 with passwordless sudo and dedicated ext4 UUID `0d043614-606c-4098-9617-1b1467155b6f`. Preserve the historical external-wrapper HOLDs; do not rewrite them as successful terminal runs.

| Gate | Observed evidence |
| --- | --- |
| G4AB / G4AB-R | Both immutable-verification attempts stopped with exit 2. G4AB-R2 reproduced the shell variable collision: sourcing Ubuntu's OS release file overwrote the harness's expected appliance VERSION with the OS version. The corrected distinct variable/subshell proved source and installed project version both 0.1.0-rc.15 and all 56 release files byte-identical, with expected ownership and immutable modes. No release repair or reinstallation was performed. |
| G4AB-R2 | Nine focused suites on native ARM64 passed: update 103, recovery 81, runtime 20, storage/setup 26, immutable-bytecode 1, Worker policy 6, origin startup 8, operations 49, systemd runtime 6; **294 tests, all OK**. Dedicated storage, protected configuration, distinct Age custody/SOPS decryption, absent recovery guard, available mutation lock, one original user/cipher with exact G3 cipher fingerprint and SQLite integrity, healthy containers, mandatory doctor/security PASS, current Worker invocation and API Fail Open, and exact G3 remote ciphertext readback all passed. Status exit 1 accurately represented deliberately inactive automation; each triggered service was inactive with result success. The final external receipt generator failed reading the protected G3 receipt as an unprivileged user, so the original G4AB-R2 exit 2 HOLD remains preserved. |
| G4AB-R3 | Read the protected G3 receipt via passwordless sudo without changing its permissions; reconciled all nine successful suites, exact release/fixture and remote evidence, and preserved three prior HOLDs. `RC15_G4ABR3_EXIT=0 PASS PREFLIGHT_RECONCILED`. Rechecked exact immutable selection and current pre-fault safety before proceeding. |
| G4C automated negatives | Native non-TTY missing verify identity, missing restore identity, missing restore confirmation, and distinct synthetic wrong Age identity each returned exit 1 with its intended refusal. The wrong key was tested against the verified ciphertext through the actual restore CLI, not merely an isolated mock. |
| G4C interactive negative/cancel | The correct offline identity from the local encrypted recovery kit was used against a temporary same-size ciphertext copy corrupted at its last byte. Native restore returned exit 1 at Age decryption, before final restore confirmation. A second native restore using the unmodified ciphertext and correct kit verified Age, manifest, checksums and offline SOPS, then returned exit 0 with explicit native message: restore cancelled after preflight; no live state was changed. Operator pressed Enter at the final prompt rather than typing RESTORE, which is the supported fail-closed cancellation behavior. The pasted transcript closes the receipt's historical TRANSCRIPT_REQUIRED marker; no new successful restore is claimed. |
| G4C post-test reconciliation | Pre/post snapshots were identical: original user/cipher fingerprints, SQLite integrity, protected config/secrets/operational Age hashes, recovery state, both container IDs/start times/PIDs/restart counts/health, lifecycle unit, storage, absent guard, Worker invocation/Route/Fail Open, doctor and security, and intentionally inactive automation. No retained offline identity workspace or changed recovery staging inventory. Temporary synthetic key and ciphertext copies removed, original archive unchanged. `RC15_G4C_EXIT=0 PASS NEGATIVE_RECOVERY_AND_SAFETY_RECONCILIATION`. |

Protected operator-private evidence directories (references only, not committed receipts): G4AB `rc15-g4ab-20261124T030533Z-2oWgec`; G4AB-R `rc15-g4abr-20261124T030733Z-49ZGLw`; G4AB-R2 `rc15-g4abr2-20261124T030921Z-p3xSQ5`; G4AB-R3/G4C `rc15-g4c-20261124T032133Z-LfxOmu`, containing `g4abr3-sanitized.json` and `g4c-sanitized.json` (operator-reported final receipt SHA-256 `8ae7ab04920c2740ce56deff079edc8fb7756d2d4d604616137e6f272615dd90`). Original G3 archive SHA-256 remains `b64f50fb8140df7a83fbd84b4f8e4fb84a095922b739579b3a8a975aedee9e59` (348,440 bytes); original cipher fingerprint remains `4b966a356486f92b7b85cb8f424f99235b7a5336465472875af3ac524e62a752`.

**G4 disposition:** PASS for source audit, scoped isolated regression and VM9 live negative recovery/cancellation/safety reconciliation. Actual live pre-mutation update rollback and post-mutation quarantine/coherent update rollback remain **NOT RUN**: no safe distinct supported release transition is available in the exact rc.15 VM9 scope. Do not create a fabricated release or guard, alter immutable files, unmount storage, or disable security to force those transitions. No additional successful remote backup/restore was required. Independent off-host emailed recovery-kit decryption remains NOT RUN, as do the separately scoped OCI provider API policy inventory and fully enabled automation readiness. No version change or publication authorized. Fresh final documentation HEAD CI, review of remaining acceptance gaps, integration authorization and explicit production GO remain separate. Retain original G0–G3 and HOLD evidence above.

### VM9 G5 final release and automation reconciliation — November 24, 2026 UTC

**Scoped software acceptance: PASS; release publication and production deployment remain unauthorized.** The operator-reported G5AB and G5CR results establish native rc.15 operational readiness within the recorded scope, not a new production deployment or a live failed-update transition.

- Reviewed integration baseline: `fc7d00c43ad9601d6bc4feda9089cef8d8b95ef6` (G4 squash integration). Installed immutable source: `162289365800ffe814517fbed920b5066cba4c33`. G5AB independently compared the two commit trees across `vwctl`, `versions.toml`, `email-providers.toml`, `vaultwarden_oci/`, `systemd/`, `setup.sh` and `dashboard.sh`: no differences. All 56 installed release files and ownership/modes, selected release and launcher were independently verified. Project version remains `0.1.0-rc.15`; Vaultwarden 1.37.4, Caddy 2.11.7 and exact plugin/image pins remain unchanged. The [integration CI](https://github.com/killer23d/VaultWarden-OCI/actions/runs/45320144059) and both [G4 branch CI](https://github.com/killer23d/VaultWarden-OCI/actions/runs/45319728499) [runs](https://github.com/killer23d/VaultWarden-OCI/actions/runs/45319735622) were independently checked: each completed 9/9 jobs successfully. These results apply to the reviewed commits, not a subsequent documentation commit.
- **G5AB PASS**: dedicated ext4, absent recovery-required guard, available mutation lock at probe, all 13 installed systemd fragments and effective automation units without overrides, local-only backups with both retention values zero, optional HTTPS operational notifications disabled, protected G4 receipt checksum, healthy unpaused containers, mandatory doctor/security checks, intentional inactive automation, active boot-disabled Worker and in-sync proxied DNS. Reboot-required was true. `RC15_G5AB_EXIT=0 PASS READONLY_AUTOMATION_PREFLIGHT`; sanitized receipt SHA-256 `d66d076dbec78c514bba9eb24b2efdf92daa9f43b14ea9f375c33708ee51443f`.
- **G5C HOLD preserved**: the external wrapper required the lifecycle unit to be active/exited before supported activation. It exited 2 before starting automation jobs. Receipt SHA-256 `641ca540b157a40a503689e6cc182a810fe6ccf1c61b8da6412e62ce59b3a6db`. This was not evidence of application failure.
- **G5CR PASS**: the corrected wrapper verified both historical receipts, found the lifecycle unit clean inactive/dead with result success, and used the supported systemd lifecycle start. Active/exited converged without container recreation. Actual backup, maintenance, project update-check, and health services completed successfully; the health service's separate DNS service proved a successful no-change synchronization. The enabled appliance target brought all four timers active (individual unit files remained disabled, as expected for target-owned activation); structured timers/status passed. **Natural timer triggers were NOT OBSERVED in this VM9 window**; service execution and activation are independently established, and the historical VM8 RC15-D/E scope remains distinct.
- The wrapper then stopped the timers, drained in-flight work and disabled the target without stopping the lifecycle service. One new local encrypted recovery point (348,440 bytes, SHA-256 `bd95f4500c01f111a0f5f43c9589812da5da1b2424680017fd680f2c308a931d`) matched the local recovery receipt, had the Age header and root-only custody; all previous archives and offsite receipt remained unchanged. Update-check state was fresh, successful and reported no available stable candidate; no update apply. Final immutable release, dedicated storage, absent guard, protected config/SOPS/operational identity, original user/cipher rows, SQLite quick check, post-convergence container identities, Worker invocation and confirmation receipt, DNS and mandatory doctor checks all passed. Reboot-required remained true; no host upgrade or reboot was performed. `RC15_G5CR_EXIT=0 PASS LIVE_AUTOMATION_AND_ISOLATION`; sanitized receipt SHA-256 `3bf0b4f4f4a08f9aa5561668296b16863e6cac6f1a8575ac72aea4fcbf8c5a30`. VM9 remains a disposable acceptance host with running app/lifecycle and Worker, target/four timers disabled, Worker boot re-arm disabled, local-only backup and zero retention. This is not a production automation configuration.

#### G5 remaining boundaries and release recommendation

| Boundary | Classification and disposition |
| --- | --- |
| Native fresh install, dedicated storage, origin security, recovery and supported automation | PASS within documented G1–G5 live ARM64 scope. No new immutable runtime defect identified; no repeat install, publication, restore or destructive failure run needed. |
| Actual live failed-update rollback/quarantine | NOT RUN on VM9. Exact supported rc.14 to rc.15 upgrade was accepted on VM8; isolated transition/failure coverage and G4 focused tests remain separate. No available disposable predecessor or supported distinct transition for another live failure exercise; do not manufacture one or assert live rollback PASS. |
| Independent emailed recovery-kit decryption | **PASS — operator-confirmed G5D**. G1 proved identical emailed ciphertext; G3/G4 proved correct-passphrase local kit use and recovery. The operator subsequently confirmed successful decryption of the independently held emailed kit. This is operator-reported custody evidence, not an automated off-host inspection; no private material was collected. |
| OCI effective security-list/NSG provider API inventory | NOT RUN / deployment-specific administrator gate. Live packet path evidence remains G2-scoped; audit actual network policy before each production deployment. |
| Production automation, scheduled backup/maintenance and update check | Supported target activation and real service execution PASS; VM9 natural timer triggers NOT OBSERVED, enabled remote schedule NOT RUN (one-time actual publication and restore PASS in G3). Configure durable local/offsite policy and enable timers only after first verified backup and clean doctor; review ongoing recovery age and scheduling. |
| Host package maintenance and reboot-required | G5 read-model reports pending reboot; actual package apply/reboot NOT RUN in G5. Prior VM8 reboot evidence retained. Separate administrator maintenance and recovery planning required; never auto-reboot. |
| Worker boot re-arm | Prior scoped VM8 acceptance retained. VM9 Worker active and boot-disabled, opt-in boot re-arm disabled. Production operator must choose and verify the supported re-arm path and current invocation-bound Fail Open after reboot. |
| Optional HTTPS notifications | NOT RUN for this VM9 configuration; direct authenticated SMTP and mailbox receipt PASS in G2. Enable/test the selected HTTPS provider and fallback if needed; SMTP alone does not enable operational failure emails. |
| Authenticated Admin/browser and client verification | G2 outer unauthenticated Admin gate and HTTPS smoke PASS; G3 restored item presence confirmed by operator, exact database verification PASS. Broader authenticated Admin workflows and explicit client field-by-field checks NOT RUN. |
| Ubuntu 26.04 AMD64 live host | NOT RUN; best-effort automated coverage, not a replacement for native ARM64. |

**G5D (operator confirmation):** independent emailed recovery-kit decryption confirmed, in addition to the previously recorded ciphertext hash match. No key, passphrase, or copied archive collected. The initial [G5 documentation PR CI](https://github.com/killer23d/VaultWarden-OCI/actions/runs/45322102167) completed all 9 jobs successfully at commit `7c8ab41c537bdad7d0e955707792aa63ea1c014e`; later documentation commits require their own CI.

**Targeted gap closure (pending):** after operator review of remaining boundaries, distinguish actual native timer firing from manual systemd service activation, and exercise a real backup-service invocation using a temporarily saved, uniquely isolated Box destination. This adds evidence for native scheduling dispatch and the backup unit's real rclone permissions/configuration, not a repeat remote restore. Keep retention zero; return to local-only scheduling isolation and retain test ciphertext. Do not force the host clock, change timer definitions, simulate a stable release, or claim unsupported live rollback/provider/architecture coverage.

**Recommendation:** proceed to documentation review and release preparation for the validated rc.15 software scope after targeted gap closure, CI on the documentation change and explicit operator decisions. Keep unperformed coverage labelled NOT RUN; the unavailable live failure transition is an explicit coverage limitation, not a demonstrated defect. Do not represent VM9 as production-ready configured infrastructure. Stable version selection, any version-changing candidate validation, release tag, publication, and production deployment each require separate authorization. No stable tag or publication was performed in G5.

## Current code-release candidate: grouped blank-host source preflight

The approved objective is to ship a validated **software codebase for future
production sites**, not to turn the existing OCI/Cloudflare laboratory into
production. The stopped Ubuntu 26.04 ARM64 reference host contains **recovered
Vaultwarden data** and must not be wiped, reused for first-install tests,
started with rc.13, or pointed at test-only remote writes. Its P8V-B source
tests and recovered-state continuity are already recorded; do not repeat them
to create a false fresh-install PASS.

The existing read-only `tests/host-acceptance/production-new-host-preflight.py`
now supports **two** mutually clear purposes:

- Historical default (no arguments): the original fixed rc.12 replacement-host
  recovery inventory, retained for old evidence.
- `--purpose fresh-install --expected-version 0.1.0-rc.13
  --expected-sha <40-hex-reviewed-commit>`: a clean-slate **software-release
  preflight**, requiring clean exact-source proof and a blank unmounted
  non-boot volume; an ext4/xfs volume with any existing data does **not**
  count as blank.

**One grouped read-only command on a genuinely NEW disposable Ubuntu 26.04
ARM64 host** with a separately attached, blank dedicated data disk. This is
**not** a Cloud Shell command and **must not run** on an existing rc.12
restored-state test VM. Clone the **reviewed candidate ref**, pin the exact
40-character SHA from the approved source/PR/CI, run its focused offline
tests and only then the read-only P0. The command creates an isolated
source checkout and root/operator-private evidence, but performs **no**
disk formatting, apt, Docker start, systemd edit, SOPS/backup, firewall,
DNS, Worker/API, email, remote read/write or reboot:

```bash
(
set -Eeuo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
REPO="killer23d/VaultWarden-OCI"
REF="REPLACE_WITH_REVIEWED_CANDIDATE_REF"
PIN="REPLACE_WITH_REVIEWED_40_CHARACTER_COMMIT_SHA"
VERSION="0.1.0-rc.13"
WORK="$HOME/VaultWarden-OCI-release-p0-${PIN:0:12}"
fail() { printf 'RELEASE_P0_EXIT=2 BLOCKED: %s\n' "$1"; exit 2; }
case "$PIN" in (*[!0-9a-f]*|"") fail "source pin invalid";; esac
[ "${#PIN}" -eq 40 ] || fail "source pin length invalid"
[ "$(id -un)" = ubuntu ] && [ "$(uname -m)" = aarch64 ] ||
    fail "run as ubuntu on a new ARM64 acceptance host"
sudo -n true || fail "passwordless sudo unavailable"
for state in /opt/vaultwarden-oci /etc/vaultwarden-oci /var/lib/vaultwarden-oci; do
    [ ! -e "$state" ] && [ ! -L "$state" ] ||
        fail "already-installed or recovered state exists"
done
[ ! -e "$WORK" ] && [ ! -L "$WORK" ] ||
    fail "source checkout already exists"
git clone --quiet --depth 1 --branch "$REF" \
    "https://github.com/$REPO.git" "$WORK" ||
    fail "reviewed source clone unavailable"
cd "$WORK"
[ "$(git rev-parse HEAD)" = "$PIN" ] || fail "source changed"
if ! status="$(git --no-optional-locks status --porcelain --untracked-files=all 2>/dev/null)"; then
    fail "source checkout Git status failed; verify index ownership before continuing"
fi
[ -z "$status" ] || fail "source checkout not clean"
echo "=== OFFLINE SOURCE PREFLIGHT UNIT TESTS ==="
python3 -B -m unittest discover -s tests \
    -p 'test_production_new_host_preflight.py' -v ||
    fail "focused source negative-path tests failed"
echo "=== READ-ONLY BLANK-HOST PRE-FLIGHT ==="
set +e
sudo -n /usr/bin/python3 -B \
    tests/host-acceptance/production-new-host-preflight.py \
    --purpose fresh-install --expected-version "$VERSION" \
    --expected-sha "$PIN"
rc=$?
set -e
printf 'RELEASE_P0_EXIT=%s\n' "$rc"
exit "$rc"
)
```

**Gate semantics:** exit **2/BLOCKED** means an unsafe/wrong host, wrong
source version, dirty/nonmatching SHA, recovered appliance files,
missing separate *blank* non-boot data candidate or a failed read. Exit
**0/PENDING** reports an accurate read-only inventory only, **not**
approval to install or evidence that a real application works. An
empty or unsigned disk is only a candidate until independently reviewed
against the actual block-volume identity. Private JSON stays
mode 0600 under the invoking operator's `vwoci-acceptance`; share
only sanitized summary/output and the exit label.

**P0 handoff plan recorded before P2 (subsequently performed in part):**
use the existing [Install](INSTALL.md) workflow with a distinct
test-only hostname, a new offline Age identity, approved blank data disk
and test-only credentials. First the supported `setup.sh install
--dry-run` path, then actual installation/custody; then real TLS/admin/
SMTP/CrowdSec, Cloudflare-only external origin denial through Docker
NAT/FORWARD/userland proxy, systemd/reboot/fail-closed transitions,
and a **test-only** encrypted backup plus guided restore. No original
Box/recovered data. Record each mandatory gate PASS/FAIL/NOT RUN in the
accepted record below before considering a stable release tag.
This is a **software release** gate; OCI site setup belongs separately
to [new-site OCI administration](OCI-CLOUD-SHELL-AND-PRIVATE-SSH.md).

### Real P1 dry-run evidence and Git-index safety — November 18, 2026

The operator ran P0 successfully on a new, separate Ubuntu 26.04 ARM64
test VM. Source and OS checks passed, with one 50 GiB blank non-boot disk
candidate and eight source-level negative-path tests. The subsequent
P1 dry run of the **supported installer** reported `P1_EXIT=0`
and confirmed its no-format/no-install boundary. The operator supplied
a new *public* offline Age recipient, but the offline private-key custody
and the disk's actual provider attachment are **not yet approved**.
At the P1 checkpoint, rc.13 had not yet been installed, started or tested with real external traffic. The later P2/P3 results below are separate evidence against a newer pinned release candidate.

During the P1 wrapper, the unprivileged checkout reported
`fatal: .git/index: index file open failed: Permission denied`.
The original root P0 script had executed `git status` as root in the
operator checkout; Git may refresh/write the index, leaving it
root-owned. The P1 shell's `[ -z "$(git status ...)" ]` pattern
incorrectly accepted the resulting empty stdout despite Git's
nonzero exit code. **Do not treat that one "clean checkout" PASS as
independent proof of a successful Git status check.**

The corrected P0 source now runs its exact source-pin and clean-tree
proof as the named unprivileged `SUDO_USER`, using
`git --no-optional-locks`. A failed Git status is BLOCKED instead of
silently considered clean. For an existing checkout, inspect the
`.git/index` owner before resuming; only a verified root-owned
*regular* index inside the expected operator-owned repository should
have its ownership repaired to the operator. Never use `chown -R`,
delete the index, disable Git's safety checks, or replay P0 on the
recovered-data reference VM.

Any Git wrapper using command substitution must check its exit status
separately before examining stdout, for example:

```bash
if ! clean_status="$(git --no-optional-locks status --porcelain --untracked-files=all 2>/dev/null)"; then
    echo "BLOCKED: Git status could not read checkout" >&2
    exit 2
fi
[ -z "$clean_status" ] || { echo "BLOCKED: checkout not clean" >&2; exit 2; }
```

**Boundary:** P1's successful dry run only proves installer input/host
acceptance with no changes. Standing alone, it did **not** approve formatting the
50 GiB candidate, validate independent offline-key custody, prove
Cloudflare/SMTP/backup integration, or grant a future production GO.
P2 was later separately approved and performed on this disposable host;
that approval does not retroactively expand P1.

### Current rc.13 P2/P3 software acceptance evidence — November 18, 2026 UTC

**Interim source-release record, not a production GO.** This is the next
operator-reported evidence checkpoint after the immutable P0/P1 and
historical-infrastructure records above. The disposable new host is
`vaultwarden-oci-8`, Ubuntu 26.04 ARM64 with native Python 3.14.
The executed P2/P3 source was the reviewed candidate commit,
tracked on `acceptance/p2-rc13-blank-install-20261118` and pinned at
`fd56313255c97992dc55c1475d94477597b88602`
(`0.1.0-rc.13`, after PR #432). Earlier P0/P1 evidence was pinned to a
*different* source commit; it is not silently rebadged as a P0/P1 run
against this exact P2 candidate.

| Gate / status | Observed operator evidence | Limit or pending proof |
| --- | --- | --- |
| P2 first install — **PASS, with wrapper exception** | Supported `sudo ./setup.sh install --auto --confirm-format --data-device /dev/oracleoci/oraclevdb --offline-recipient <test public recipient>` succeeded; release, copied source bytes, config, root-only state, storage and SOPS recipients/decryption passed after installation | One external shell-wrapper preformat Python gate had an invalid heredoc/guard and did **not** run; do not claim that particular preformat check passed |
| P2 independent post-install storage reconciliation — **PASS** | Disposable 50 GiB `/dev/oracleoci/oraclevdb` resolves to `/dev/sda`; real block disk, stable by-id alias, disjoint boot/root lineage, ext4, mounted at `/var/lib/vaultwarden-oci` on a different filesystem from `/`; UUID, fstab, identity/marker and Docker mount dependency match; immutable rc.13 release and 0600 root-only files passed | Proves the installed boundary and a separate data disk, not retroactive execution of the skipped preformat wrapper gate |
| P2 explicit off-host recipient — **PASS for test-only configuration** | Preserved supplied Age *public* recipient alongside the separate on-host operational recipient; SOPS decrypts with operational identity | The disposable offline **private** identity appeared in an operator terminal transcript; it is **not** secure production custody evidence. Never commit or publish the identity, secret values or private logs |
| P3 config and SMTP — **PASS for local configuration and server acceptance** | Supported `vwctl config edit` and `secrets edit` committed; `config validate` and `secrets validate` passed; initial `smtp.invalid` placeholder was corrected; IPv4 DNS resolved; direct authenticated TLS SMTP reported `category=accepted` | SMTP *mailbox receipt* and browser Admin SMTP test were not independently verified; no public application start |
| P3 Cloudflare DNS dry run — **PASS, publication HOLD** | Existing Proxied A record and token/API access verified in read-only `vwctl dns update --dry-run` | Existing A-record origin did **not** match this disposable host. **No DNS write/cutover** was performed |
| P3 local origin/CrowdSec — **PASS** | `vwctl edge refresh` and `vwctl crowdsec setup` completed; `edge.cloudflare.cidrs`, `edge.cloudflare.iptables`, `crowdsec.engine`, `crowdsec.hub` and `crowdsec.firewall` all reported `PASS` | Doctor checks verify configured local policy, not an independently witnessed non-Cloudflare packet denial via Docker NAT/FORWARD |
| P3 Worker Route and Fail Open — **PASS for invocation-bound security** | Pre-start Cloudflare API inventory found zero matching routes/custom domains; `vwctl crowdsec remediation-start` succeeded with boot-disabled Worker; operator set newly created routes to Fail Open; `confirm-fail-open` succeeded; 0600 confirmation bound to the unchanged systemd invocation; all **six** origin/CrowdSec doctor checks reported `PASS` | Worker Routes now exist and can affect the pre-existing DNS origin. Fail Open is operator-attested; no synthetic request or current independent Cloudflare read-back of the route failure mode is claimed |
| P3-F initial overall doctor — **FAIL before first start, subsequently diagnosed** | Final prestart `doctor --json` reported all six security gates `PASS`, but `overall=FAIL` with `runtime.paths`; the appliance remained stopped | P3-G0 proved this was a genuinely partial state created by CrowdSec's required log acquisition; the prestart FAIL is preserved, not relabelled as PASS |
| P3-G0/G0R diagnosis — **PASS for investigation, runtime still HOLD before start** | Eight focused source regression tests passed on the host. Root-owned base/run/transient/lock 0700/0600 passed, CrowdSec-created `vaultwarden/log/vaultwarden.log` was the sole application subtree precreated (65532:65532); Caddy/data/volatile directories and rendered files absent. Worker active and boot-disabled, invocation `a80be9e43af84a24b505b9e4b127abeb` unchanged; source inspection confirmed CrowdSec setup creates that log and supported lifecycle owns the remaining materialization | Exact `runtime.paths=FAIL` reason: `runtime paths are only partially materialized`. First diagnostic wrapper misclassified `systemctl is-enabled` nonzero/disabled as unavailable; corrected `systemctl show UnitFileState=disabled` resolved that wrapper error. No hot-patch or early doctor PASS |
| P3-G1 supported start — **PASS** | Installed `0.1.0-rc.13` `vwctl start` exit 0 with same dedicated ext4/UUID ownership. Vaultwarden and custom Caddy running/healthy on exact ARM64 image pins; required Caddy modules and derived Argon2id Admin PHC/Basic Auth hashes verified; `runtime.paths=PASS`, six origin/CrowdSec checks PASS, Worker invocation unchanged; `status.runtime=running`; doctor `overall=WARN`, **zero FAIL** | Warnings `recovery.local`, `recovery.offsite`, `recovery.rclone` remain; automation target/timers deliberately not activated and status reports automation FAIL. No DNS update, public cutover, backup, reboot, or external traffic test |
| P3-G2A local TLS/application — **PASS for local-only checks** | Using real Caddy loopback with hostname/SNI and verified certificate, Web Vault `GET /` returned HTTP 200, API config HTTP 200, unauthenticated `/admin` HTTP 401; Caddy trusted-proxy/Admin outer Basic Auth and per-client rate-limit configuration recognized; doctor WARN with recovery-only warnings | No authenticated browser Admin login/SMTP test, true Cloudflare client-IP confirmation, actual threshold/429, independently measured direct-origin denial, or public HTTPS cutover; DNS still points to another origin |
| P3-G2B live Admin outer gate and untrusted IP — **PASS for local-only checks** | Authenticated in-container Caddy HTTPS with SOPS-held Basic Auth supplied via curl stdin: `/admin/` missing and wrong credentials returned HTTP 401; correct and repeated correct credentials returned HTTP 200, all with verified TLS. Fake `CF-Connecting-IP` and `X-Forwarded-For` from untrusted loopback returned API HTTP 200 but Caddy JSON access log retained the real remote/client identity; previous Worker invocation `a80be9e43af84a24b505b9e4b127abeb` preserved, doctor `WARN` with no new FAIL | This proves the actual outer Caddy gate and local untrusted-header handling. Inner Vaultwarden Admin token login, browser navigation/SMTP delivery, actual 429 threshold, independently verified Cloudflare client identity or public-origin denial are NOT RUN. Do not treat a localhost request as a Cloudflare traffic test |
| P3-G2C inner Admin and application SMTP route — **PASS for in-container HTTPS, mailbox receipt unverified** | Using the installed release and existing SOPS custody, POST `/admin/` with the original recoverable Vaultwarden Admin token returned HTTP 200 over verified TLS; the `VW_ADMIN` session cookie satisfied Secure/HttpOnly/SameSite Strict checks. Authenticated `/admin/users` returned HTTP 200 and a JSON list; `/admin/` and `/admin/users/overview` both returned HTTP 200; one POST `/admin/test/smtp` returned HTTP 200 over verified TLS. Subsequent doctor remained WARN/no FAIL and CrowdSec Worker kept its original invocation | Proves accepted inner application routes with a genuine session, but **HTTP 200 is not independent mailbox-delivery proof**; recipient receipt not confirmed. Browser/UI rendering and the native browser SMTP workflow NOT RUN; actual 429 threshold and independent Cloudflare/public origin traffic NOT RUN. One test message was submitted, do not repeat automatically |
| P3-G3 first local encrypted recovery — **PASS, offline decryption still NOT RUN** | On the disposable ARM64 host, installed `vwctl backup` returned 0; LOCAL-ONLY and both retention paths disabled. Created `/var/lib/vaultwarden-oci/backups/recovery-20261118T202543Z-e3ef03c7.vwrec` (348,440 bytes), SHA-256 `47f775b7e2f534e53cc4c6c5056df786fe0bbb0e316f5fa907b1b1c879546a44`, Age-encrypted envelope, owned root mode 0600; hash and size independently matched recovery state. `recovery.local=PASS`, overall doctor WARN with zero FAIL, both application containers resumed healthy/unpaused and CrowdSec Worker invocation preserved | Local encryption/envelope/hash and supported backup health are verified, **not** the ability of the separately held offline Age private identity to decrypt and verify SOPS/manifest; no offsite upload, restore, prune, or automated timer. No claim that this test key demonstrates secure production custody |
| P3-G4 independent offline-key verification — **PASS on exact P3-G3 artifact** | Using the supported interactive `vwctl recovery verify --file` with the matching test offline Age private identity provided by hidden paste, the application returned `PASS verified recovery` for the exact file created at `2026-11-18T20:25:43Z`, size 348,440 bytes and SHA-256 `47f775b7e2f534e53cc4c6c5056df786fe0bbb0e316f5fa907b1b1c879546a44`. Cryptographic Age decryption, manifest/member checksums and offline SOPS custody completed. Wrapper confirmed a **new** artifact-bound `verified_objects` record; doctor remained WARN with zero FAIL and Worker/containers remained healthy and unchanged | Validated decryptability with this **disposable test identity**, not secure production custody; earlier operator test transcript exposed this private identity. No restore, offsite publication, external-cloud readback, browser SMTP/mailbox receipt or public ingress verification was performed |
| P3-G5 and G5R restore refusal/preflight/cancellation — **PASS after external-wrapper TTY correction** | First wrapper stopped safely before tests due to incorrect `stdin` TTY assumption in a heredoc. Corrected `P3-G5R` preflight verified original rc.13 source, dedicated storage, unchanged 348,440-byte P3-G3 artifact SHA-256, healthy runtime and Worker invocation. Non-TTY `restore --file` without `--identity` refused; non-TTY restore with dummy identity but no `--confirm RESTORE` refused. Matching Age test identity provided by hidden interactive input passed exact `verify_local(..., record=False)` cryptographic preflight; real `_restore_approved` helper with forced `CANCEL` refused authorization. Recovery metadata, config, encrypted SOPS bytes remained unchanged; Caddy/Vaultwarden healthy and Worker preserved. Final `P3_G5R_EXIT=0 PASS` | This is a real preflight of the backup plus exercised consent logic in-process, **not** a destructive restore or the CLI's complete interactive restore transaction. No service stop/promotion, offsite transfer, DNS mutation, or reboot. Same test-only offline identity custody limitation applies |
| P3-G6 real Admin rate-limit threshold — **PASS for internal loopback client** | The installed Caddy module had the validated Admin limit `60 events / 1m` keyed on `{client_ip}`. Sixty consecutive authenticated Admin `GET /admin/` requests returned HTTP 200; the bounded burst observed HTTP 429 on the next request. The unrelated unauthenticated `/api/config` endpoint continued to return HTTP 200. Live post-test doctor, both healthy/unpaused application containers and unchanged CrowdSec Worker invocation all passed; `P3_G6_EXIT=0 PASS` | Demonstrates the active Caddy Admin outer rate-limit boundary and separation from a non-Admin endpoint for the internal loopback client, **not** a real Cloudflare client. Brief internal client throttling was expected; no DNS/Worker/config/service changes. Browser-rendered UI/SMTP receipt and external origin validation are NOT RUN |
| P3-G7 negative Age recovery paths — **PASS for wrong key and tamper** | The actual installed P3-G3 backup was proven unchanged and the runtime healthy. A newly generated synthetic Age private key (not the configured recipient) was rejected by `verify_local(..., record=False)` with an Age decryption failure. Using the matching offline test identity from secure hidden paste, a separate temporary ciphertext copy with one trailing byte changed also failed at Age decryption. Original `.vwrec` checksum and persistent config, SOPS and recovery state were unchanged; both application containers and CrowdSec Worker remained healthy with doctor showing no FAIL. Final `P3_G7_EXIT=0 PASS` | Demonstrates authenticated ciphertext failure closed before live mutation. No restore, offsite transport, public DNS change or Worker restart; tmpfs negative-test files were cleaned up. This does not substitute for an actual successful restore or cloud roundtrip |
| P3-G8 actual restore engine into private scratch — **PASS for isolated promotion and new operational custody** | On pinned `0.1.0-rc.13` ARM64 host, the exact P3-G3 archive SHA-256 and dedicated storage were checked before `recovery.restore_recovery(artifact, identity, paths=isolated_paths, runner=isolated_runner, start=False)`. Matching offline test identity was supplied by hidden prompt; real Age/SOPS cryptography, staged application/Caddy state, and promoted to isolated `/run/vaultwarden-oci/p3g8-*` paths. The engine generated a distinct operational Age identity and rotated/validated SOPS recipients; restored SQLite `PRAGMA integrity_check` returned `ok` and Caddy data/config were present. Docker version/inspect were intercepted only in this sandbox, with no Docker stop/remove call. Private scratch was cleaned; original archive and live config, SOPS, operational Age key and recovery record remained unchanged, containers healthy and CrowdSec Worker invocation preserved; `P3_G8_EXIT=0 PASS` | Proves real recovery-engine implementation on the real archive **with redirected temporary paths**, not complete live host restore or production boot. Docker lifecycle was intentionally simulated for sandbox isolation; actual stopped-container promotion/start, offsite retrieval and public origin cutover are NOT RUN |
| P3-G9A same-host full-restore readiness — **PASS, READ-ONLY** | On disposable `vaultwarden-oci-8` with pinned installed rc.13 source `fd56313255c97992dc55c1475d94477597b88602`, exact immutable release content (52 files), Ubuntu 26.04 ARM64/Python 3.14, dedicated ext4 disk UUID `f4e0bd62-48e7-4745-8987-44b14013216d`, unchanged encrypted P3-G3 archive (348,440 bytes, SHA-256 `47f775b7e2f534e53cc4c6c5056df786fe0bbb0e316f5fa907b1b1c879546a44`), prior independent Age verification record, local-only/retention-zero policy, free space, global lock, inactive timers/jobs, healthy Vaultwarden/Caddy, and unchanged CrowdSec Worker invocation `a80be9e43af84a24b505b9e4b127abeb` all passed. Doctor had zero FAIL and required runtime/origin/CrowdSec/recovery.local checks passed. Four operator attestations were entered as `YES` for disposable host, off-host Age identity, independent rollback, and a pre-backup known test state; final output `P3_G9A_EXIT=0 READINESS_PASS_ONLY`. | Earlier G9A attempts safely HOLD on a script-only notification SKIP classification error and a sudo-heredoc `/dev/tty` placement error; corrected script is pinned at `da08ca24141c8400b149c727ec3faedf64f1c866`. Attestations are operator assertions, **not** independent proof of off-host custody/recoverability. Optional operational notifications remain unconfigured and notification.last_delivery is SKIP; offsite/rclone remains unaccepted. **No real restore, service stop/promotion, offsite upload, public DNS change, or production approval occurred**. P3-G9B required its own authorization. |
| P3-G9B authorized real same-host restore — **PASS at supported CLI; independent G9C checks observed** | The exact P3-G9A preflight re-passed with four repeated operator attestations. The operator independently entered `AUTHORIZE P3-G9B` and again checked the original P3-G3 archive SHA-256. The installed supported `sudo vwctl restore --file <exact local .vwrec> --start` interactive workflow received the matching offline test Age private identity through hidden input, cryptographically authenticated the local `2026-11-18T20:25:43Z` recovery point and SOPS custody, displayed replacement impact, and independently received literal `RESTORE`. The product reported `PASS restored recovery point created 2026-11-18T20:25:43Z`, warned that the restored policy remains local-only, and returned CLI exit 0. | P3-G9C has separately checked the restored SQLite integrity, operational SOPS/secret custody, healthy containers, verified local TLS/Admin and unchanged Worker invocation. However, **actual user/item recovery remains unproven** because the recovered SQLite database contains zero users and zero ciphers. This was an authorized destructive restore on this disposable host only; no remote retrieval, DNS/public ingress change, timer enablement, or release GO. |
| P3-G9C independent real post-restore health — **AUTOMATED PASS; item recovery HOLD** | Operator ran the exact pinned `P3-G9C` read-only script on `vaultwarden-oci-8` after the authorized real restore. Pinned rc.13 and dedicated ext4 UUID remained unchanged; restored config/SOPS/operational Age key had protected ownership; original encrypted P3-G3 artifact SHA-256 remained intact. All background timers/jobs remained inactive and CrowdSec Worker still active/boot-disabled at invocation `a80be9e43af84a24b505b9e4b127abeb`. Both actual post-restore Caddy/Vaultwarden containers were healthy/unpaused; SQLite online snapshot `PRAGMA integrity_check=ok`; doctor had zero FAIL and required SOPS, runtime, recovery, Cloudflare-origin/CrowdSec gates were PASS; runtime status was `running`; verified local HTTPS Web Vault / API returned 200/200 and unauthenticated Admin returned 401. Printed `P3_G9C_AUTOMATED=PASS; LIVE_STATE=HEALTHY` and `P3_G9C_EXIT=0 POSTRESTORE_PASS; RELEASE_GO=HOLD`. | **User/item recovery NOT PROVEN**: independent SQLite counts were `users=0 ciphers=0`. The operator entered `YES` to the script's known-test-user/item attestation, but there is no database record to substantiate that item-level assertion; it must not be reported as an independently restored saved vault item. The original script incorrectly permitted this contradictory attestation; updated at `77e4a37569cbcfcefb02b10f2d3ca8e472a14cda` to fail closed when both counts are zero. This updated script has not been rerun against the host. A later **populated disposable test vault** and independently verified backup/restore remains mandatory for nonempty-record acceptance. No public DNS change, remote backup or timer enablement. |

| P3-G11A root rclone inventory — **PASS for configured root remote; cloud access HOLD** | First read-only run on disposable `vaultwarden-oci-8` confirmed local-only backup policy, retention zero, installed `rclone v1.60.1-DEV`, and no root remotes, ending `P3_G11A_EXIT=0 ROOT_REMOTE_SETUP_REQUIRED`. A later operator rerun with the same guard confirmed the same disabled backup/retention policy and now listed the root remote `bw-backup:`, ending `P3_G11A_EXIT=0 INVENTORY_PASS_ONLY`. Operator specified the offsite parent `bw-backup:bw-backup`. | **Remote connectivity, directory existence, encrypted object inventory, ciphertext readback, offline Age decryption from remote, and populated-vault restore remain NOT RUN**. The remote name alone does not establish its backend/encryption or recoverability. Next P3-G11B checks the parent read-only before any test-only upload or remote restore authorization; do not overwrite or alter historical objects. The installed release, automatic offsite publication, retention and public DNS are unchanged. |

| P3-G11B existing Box backup parent metadata — **PASS read-only; cryptographic recovery HOLD** | On disposable `vaultwarden-oci-8`, exact pinned read-only G11B script `d8d9bc24ffa23a219430d63529401f0d0f216e89` confirmed LOCAL-ONLY backup policy/zero retention, root `bw-backup:` remote, and accessible directory `bw-backup:bw-backup`. One-level listing returned 3 directories and 4 files; a bounded four-level recursive metadata scan found **9 `.vwrec` files**, including historical October 2026 objects (example `recovery-20261031T032317Z-7d36795f.vwrec`, 358680 bytes). Final output `P3_G11B_EXIT=0 REMOTE_METADATA_PASS_ONLY; REMOTE_RESTORE=HOLD`. | **Only metadata/reachability proof.** No archive bytes downloaded, Age/SOPS key tested, upload/overwrite/deletion, remote restore or historical-object mutation; prior October archives were not created by this disposable host and must not be mistaken for the current host's recovery points. Next requires a separate nonempty disposable vault state and fresh, uniquely isolated upload plus read-back and independent Age verification before any remotely sourced destructive restore. |

| P3-G11C populated-fixture readiness — **PASS, READ-ONLY; upload HOLD** | On the disposable Ubuntu 26.04 ARM64 host, the SHA-256-pinned `tests/host-acceptance/rc13-p3g11c-populated-vault-readonly.sh` at `8c9715b92f0e47530e9b51263473e3b8ac800cce` passed installed release, dedicated disk, and local-only retention-zero policy checks. An online read-only SQLite snapshot reported `users=1`, `ciphers=1`, and integrity `ok`. The secret-free record fingerprint was `10b53feb60db4f7d94f280b6601e6fdfd35d6137d13eb351b94f99234c4149fa`. Final result `P3_G11C_EXIT=0 POPULATED_FIXTURE_READY; REMOTE_UPLOAD=HOLD`. | Shows a nonempty synthetic fixture **before** cloud backup; no uploaded .vwrec, independent remote Age/SOPS decryption, or restored record equivalence yet. This fingerprint must match the subsequent pre-backup fixture and restored records for an item-level data-recovery claim. Existing historical Box objects, saved offsite policy, timers, remote retention, public DNS, and Worker invocation were not changed by G11C. |

| P3-G11D authorized populated-vault offsite snapshot — **PASS upload/readback + independent Age/SOPS; remote restore HOLD** | Following fresh read-only fixture, disk, Worker, lock, and Box parent guards, operator explicitly entered `AUTHORIZE P3-G11D UPLOAD`. The supported one-time `vwctl backup --remote` command created local `/var/lib/vaultwarden-oci/backups/recovery-20261118T215628Z-a478ee3e.vwrec` (348,440 bytes, SHA-256 `48c46b90e4a2b0004d920b286df2c2649c6a80bcf34bd6be038ffe3eefb7e749`) and published to `bw-backup:bw-backup/acceptance-rc13-vm8-20261118T215615Z-208eae43675f/recovery-20261118T215628Z-a478ee3e.vwrec`. Product re-downloaded the object and checksum-verified the ciphertext. Operator independently selected the test offline Age key via hidden-input chooser; `vwctl recovery verify --from-remote` confirmed the exact remote object's manifest and SOPS. Post-run populated-record fingerprint `10b53feb60db4f7d94f280b6601e6fdfd35d6137d13eb351b94f99234c4149fa`, containers, doctor, CrowdSec Worker invocation and local-only/retention-zero policy remained unchanged. Final `P3_G11D_EXIT=0 UPLOAD_READBACK_AGE_PASS; REMOTE_RESTORE=HOLD`. | Upload consent **was not restore consent**. No remotely sourced live restore or independent post-remote-restore record comparison has occurred. Historical Box objects were not altered; the isolated folder holds the newly created test recovery point. Preserve that exact remote object and its offline identity; create a deliberate second *post-backup* synthetic cipher, then restore the prior point with fresh independent authorization and prove the second record disappears while the original baseline returns. No DNS, timers, retention or release GO change. |

| P3-G11E post-backup delta + exact remote ciphertext — **PASS, READ-ONLY; G11F restore HOLD** | Operator ran SHA-256-pinned `tests/host-acceptance/rc13-p3g11e-postbackup-delta-readonly.sh` from commit `5649ff7f91cbda7099deb43d07f93bd3831e19c8` on disposable `vaultwarden-oci-8`. Installed rc.13 release, dedicated ext4 storage and LOCAL-ONLY zero-retention policy passed. A read-only live SQLite snapshot demonstrated **1 user and 2 ciphers**: the original cipher still matched the G11C/G11D fingerprint `10b53feb60db4f7d94f280b6601e6fdfd35d6137d13eb351b94f99234c4149fa`, plus one new post-backup cipher. Original local and independently Age-verified offsite metadata still pointed to the exact isolated test object `bw-backup:bw-backup/acceptance-rc13-vm8-20261118T215615Z-208eae43675f/recovery-20261118T215628Z-a478ee3e.vwrec`. A new read-only `rclone cat` confirmed ciphertext SHA-256 `48c46b90e4a2b0004d920b286df2c2649c6a80bcf34bd6be038ffe3eefb7e749` and exact 348440-byte size. Final `P3_G11E_EXIT=0 POSTBACKUP_DELTA_AND_REMOTE_BYTES_PASS; REMOTE_RESTORE=HOLD`. | Demonstrates a distinct post-backup saved item and unchanged recovery source, not that the live restore works. Explicit G11D upload consent does **not** authorize G11F. Subsequent real remote restore must use a fresh privileged preflight, independent literal authorization and product-owned uppercase `RESTORE`, then separately demonstrate restored 1 user/1 original cipher, absent newer cipher, operational SOPS, Caddy/Vaultwarden and CrowdSec integrity. The historical Box backups, public DNS and schedules must remain untouched. |

| P3-G11F remotely sourced populated-vault restore + P3-G11G independent recovery verification — **PASS; production GO HOLD** | On disposable `vaultwarden-oci-8`, exact pinned G11F script `79ca7c231c8ab976c8892bbd8c6b23de4c472ba0` re-ran G11E read-only preflight before and after separate literal `AUTHORIZE P3-G11F REMOTE RESTORE`. It proved the same 1-user/2-cipher pre-restore delta and unchanged exact remote ciphertext, obtained the separately held offline test Age identity by hidden secure paste, authenticated the remote recovery point and SOPS/manifest `2026-11-18T21:56:28Z`, and the operator independently typed uppercase `RESTORE`. The product reported `PASS restored recovery point created 2026-11-18T21:56:28Z` with `--start`. Afterward the pinned independent G11G verifier `4a877a5f5f43658a485f480076329c3c2b178b5a` proved SQLite integrity `ok`, exactly **1 user, 1 original cipher, post-backup second cipher absent**, and exact recovered item fingerprint `10b53feb60db4f7d94f280b6601e6fdfd35d6137d13eb351b94f99234c4149fa`; operational SOPS custody/decryption; doctor zero FAIL; restored healthy/unpaused Caddy and Vaultwarden containers; private TLS Web Vault/API/Admin statuses 200/200/401; dedicated ext4 volume UUID; inactive background automation; saved LOCAL-ONLY/retention-zero policy; and unchanged invocation-bound CrowdSec Worker. Final `P3_G11G_EXIT=0 INDEPENDENT_POSTRESTORE_PASS; PRODUCTION_GO=HOLD` and `P3_G11F_EXIT=0 REMOTE_RESTORE_AND_INDEPENDENT_POSTCHECK_PASS; RELEASE_GO=HOLD`. Exact remote test object: `bw-backup:bw-backup/acceptance-rc13-vm8-20261118T215615Z-208eae43675f/recovery-20261118T215628Z-a478ee3e.vwrec` SHA-256 `48c46b90e4a2b0004d920b286df2c2649c6a80bcf34bd6be038ffe3eefb7e749`. | This **closes automated nonempty remote-backup restore** on this disposable host, not all user-facing or site-release acceptance. A real browser/client still must confirm the original item is accessible and the second item is absent. Browser Admin navigation and independently delivered SMTP mail, public non-Cloudflare origin packet denial, full systemd/reboot persistence with explicit Worker re-arm, optional fresh-install custody variants, supported-predecessor upgrade claims, and final immutable software release decision remain NOT RUN/HOLD as described in this document. The historical Box objects/public DNS were not intentionally altered; no blanket permission for timer enablement, reboot, production cutover or remote deletion was given. |

| P3-G12 preliminary user-facing smoke — **operator-observed, scoped** | After G11F/G11G remote restore, operator reported: "so far everything works, admin, caddy and restore works." A separate previously logged-in Admin/Caddy session has not been supplied as structured browser trace or step-by-step acceptance log. The G11F/G11G automated HTTP TLS/Admin negative gate, health, SOPS, and populated-data rollback remain independently proven and are not dependent on this report. | Treat the user's functional observation as a valuable **manual smoke report**, **not a documented full P3-G12 PASS**. The actual restored item still needs real-client field/usability verification and independent confirmation that the post-backup second item is absent; multi-page browser Admin navigation without unexpected 429, Admin SMTP send and **mailbox receipt** are not proven by the user's statement. Real external origin packets and reboot/Worker re-arm remain separate release gates. |


**P3 phase closeout / production software acceptance boundary:** Against the
*installed* immutable source `fd56313255c97992dc55c1475d94477597b88602`,
P3-G1 through P3-G9A have operator-reported PASS evidence for supported
first start and health, verified local TLS, Caddy outer and Vaultwarden
inner Admin authentication, accepted Admin SMTP HTTP response, safe
untrusted-IP handling, the exact 60/1m Admin threshold, consistent local
encrypted backup, independent offline-key decryption and corruption
rejection, fail-closed restore consent, and **real recovery promotion/
operational SOPS rekey into isolated temporary paths**, plus independent
read-only same-host restore readiness with four operator attestations.
Latest checks
report doctor WARN with no FAIL, healthy/unpaused app containers,
`recovery.local=PASS`, and unchanged invocation-bound CrowdSec Worker.
P3-G9B established explicit authorized local same-host restoration and
P3-G9C verified its operational health; its original *empty* vault could
not prove recovered saved items. P3-G11C through P3-G11G subsequently
proved a populated test vault, one-time isolated Box upload/readback,
independent offline Age/SOPS verification, an exact post-backup new-item
delta, and independently verified live **remote restore** to precisely
the original one-user/one-item fingerprint. This closes automated
populated-data remote recovery **on the disposable host only**. It does
**not** constitute production release GO.

Nine additional permanent, fixture-only regression tests in
`tests/test_runtime_prestart_paths.py` were introduced by PR #434 and
merged into the integration branch as commit
`03c4cd6a375dc944acc36e2b11ee0aed064fa204` after these host
runs. They record the CrowdSec log-only prestart cause and preserve
fail-closed behavior without a product implementation change. **Do not
silently attribute live-host results to this later merge commit**.

The remaining operator and release requirements include genuine
browser/client confirmation of the restored original item and absent
post-backup item; browser Admin navigation and authenticated SMTP with
independent mailbox receipt; service/timer/reboot persistence with
explicit Worker re-arm; real external non-Cloudflare origin denial;
and applicable clean-install/upgrade variants or explicitly scoped
NOT RUN limitations. Existing production-facing DNS is unchanged;
**saved** offsite publishing and automation remain intentionally disabled
(one G11D upload used only a per-invocation remote override). No new
historical provider/VM inventory files were added.


**Wrapper/automation incident:** A separate assistant-supplied, out-of-tree
P2 shell command placed an error handler immediately after a Python
heredoc redirection, causing an `IndentationError` in the supposed
preformat gate while the shell continued to the real installer. The
installer itself reported success, and the independent read-only
post-install disk/boot-identity reconciliation passed. This was a
**test-wrapper defect**, not evidence of a product installer defect.
Future acceptance wrappers must use a correctly closed heredoc with
explicit checked status and an immediate stop before any destructive
command; verify a script's actual gate outcome, not only its final exit
code. No additional permanent VM/provider test infrastructure is
introduced by this record.

**Not run / release HOLD:** fresh-install variants requiring separately
disposable blank state (interactive generated-custody, headless custody
rejection, failed bootstrap, root-only rejection), authenticated browser
Admin session/navigation and Admin-originated SMTP, independent mailbox
receipt, actual real-client Cloudflare identity/rate-limit behavior and
public origin packet denial, DNS cutover, full systemd/timer/reboot
persistence, browser/client verification of the restored vault item,
and supported-predecessor upgrade/rollback. **Test-only populated offsite
backup/readback, offline Age/SOPS verification and authorized remote restore
are PASS through P3-G11G**, not NOT RUN. The historical
recovered-data reference host and its Box objects are **not** used for
this rehearsal. Stable production software release approval is
**NOT RUN**.

**Next acceptance boundary:** P3-G11F and independent P3-G11G have
PASS results from an expressly authorized live restore of the exact
isolated Box .vwrec, with the post-backup synthetic second item removed
and the first item's one-cipher fingerprint exactly restored. The
disposable live vault is now back at **one user / one cipher**. Do not
re-run G11E (which expects two ciphers), upload another backup, or run
another destructive restore merely to repeat the already accepted gate.

**Next focus: software-facing behavior.** The operator reports that
Admin, Caddy and restore work after G11F; this is a *manual smoke*
observation, not yet an independently documented browser/mailbox test.
In a real test client/browser, check that the original synthetic saved
item remains usable and the post-backup item is absent; do not capture
production credentials in evidence. Reconcile the manual Caddy Basic
Auth and inner Vaultwarden Admin login/navigation result, and explicitly
check for false 429 behavior. Perform an Admin SMTP test and verify
independent mailbox receipt only if a disposable test provider/recipient
is configured. Otherwise record the SMTP/mailbox gate NOT RUN. Automation,
reboot and the invocation-bound CrowdSec Worker re-arm must be treated
as a separately authorized lifecycle gate; never reboot or restart
the Worker and silently reuse its prior Fail Open confirmation.

Keep the public proxied Cloudflare A record, origin route, historical
Box backups, isolated test archive, saved LOCAL-ONLY backup policy and
both retention periods zero unchanged. Existing OCI/provider inventory
is historical context, not a substitute for any still-required live
external origin packet-denial proof. Upgrade/clean-install variants
that cannot be safely exercised must be explicitly marked NOT RUN,
and no stable software release GO is implied.

### P3 one-shot audit provenance (historical, not active replay tools)
The exact one-host scripted evidence is recoverable via the immutable Git
commit URLs below. These scripts pin VM identity, release bytes, a specific
SOPS/Box recovery object and an invocation-bound CrowdSec Worker. Some
also format or replace live data. Preserve the above operator transcript
and PASS/HOLD record, but **do not install or execute these archived tools
as normal site acceptance**. Reusable tests remain in supported CI and
the two read-only host inventory tools; no product implementation change
was made by this acceptance-only branch.

| Historical executed tool | Immutable source evidence |
| --- | --- |
| P3-G9A guarded read-only full-restore readiness | [rc13-p3g9a-readonly.sh](https://github.com/killer23d/VaultWarden-OCI/blob/da08ca24141c8400b149c727ec3faedf64f1c866/tests/host-acceptance/rc13-p3g9a-readonly.sh) |
| P3-G9C independent same-host restore checks (later corrected for empty fixture) | [rc13-p3g9c-postrestore-readonly.sh](https://github.com/killer23d/VaultWarden-OCI/blob/77e4a37569cbcfcefb02b10f2d3ca8e472a14cda/tests/host-acceptance/rc13-p3g9c-postrestore-readonly.sh) |
| P3-G11B Box parent metadata check | [rc13-p3g11b-remote-readonly.sh](https://github.com/killer23d/VaultWarden-OCI/blob/d8d9bc24ffa23a219430d63529401f0d0f216e89/tests/host-acceptance/rc13-p3g11b-remote-readonly.sh) |
| P3-G11C populated fixture baseline | [rc13-p3g11c-populated-vault-readonly.sh](https://github.com/killer23d/VaultWarden-OCI/blob/8c9715b92f0e47530e9b51263473e3b8ac800cce/tests/host-acceptance/rc13-p3g11c-populated-vault-readonly.sh) |
| P3-G11D one-time encrypted Box publication/readback | [rc13-p3g11d-offsite-test-backup.sh](https://github.com/killer23d/VaultWarden-OCI/blob/7e7a1e8512def01c1f3ddd66f8416631ad3cec51/tests/host-acceptance/rc13-p3g11d-offsite-test-backup.sh) |
| P3-G11E post-backup cipher delta and ciphertext checksum | [rc13-p3g11e-postbackup-delta-readonly.sh](https://github.com/killer23d/VaultWarden-OCI/blob/5649ff7f91cbda7099deb43d07f93bd3831e19c8/tests/host-acceptance/rc13-p3g11e-postbackup-delta-readonly.sh) |
| P3-G11F separately authorized live remote restore | [rc13-p3g11f-remote-restore.sh](https://github.com/killer23d/VaultWarden-OCI/blob/79ca7c231c8ab976c8892bbd8c6b23de4c472ba0/tests/host-acceptance/rc13-p3g11f-remote-restore.sh) |
| P3-G11G independent populated post-remote-restore checks | [rc13-p3g11g-remote-postrestore-readonly.sh](https://github.com/killer23d/VaultWarden-OCI/blob/4a877a5f5f43658a485f480076329c3c2b178b5a/tests/host-acceptance/rc13-p3g11g-remote-postrestore-readonly.sh) |



## Acceptance record

```text
release/ref:
commit:
versions output:
host architecture: amd64 | arm64
Ubuntu image/build:
dedicated storage device/filesystem/mount:
Docker/Compose version:
Cloudflare test zone:
notification provider:
rclone remote/path:
offline Age identity custody verified: yes/no
setup custody mode: interactive | terminal-auto-generated | explicit-recipient | headless-refusal
pre-existing Vaultwarden Admin config: absent | reconciled | NOT RUN
Admin browser navigation/SMTP test: PASS | FAIL | NOT RUN
config/secrets edit restart prompt: PASS | FAIL | NOT RUN
normal reboot persistence: PASS | FAIL | NOT RUN
started at:
completed at:
result: PASS | FAIL | NOT RUN
notes:
```

A release is not accepted for an architecture unless every applicable mandatory section passes.

## 1. Clean install, auto custody, and root-only refusal

On clean hosts with real separate data volumes, exercise the supported `setup.sh` path from [Install](INSTALL.md) with all applicable first-run custody boundaries:

1. one normal interactive install;
2. one interactive-terminal `--auto` install with no `--offline-recipient` on a host where `age-keygen` is initially absent, proving setup bootstraps/verifies the Ubuntu `age` tooling before private-identity generation and before dedicated-storage provisioning, then completes setup-generated offline custody and verified recovery-kit handoff;
3. one interactive-terminal `--auto` install with an explicit offline recipient, including at least one normal value form such as `--offline-recipient=age1...`, proving the supplied recipient is preserved and no replacement identity is generated;
4. one fully headless `--auto` invocation without an offline recipient, proving it fails before storage provisioning or other installation mutation;
5. on separate disposable/root-only state, attempt setup without acceptable separate storage.

Where practical, also force the pre-custody Age bootstrap to fail on disposable state (for example with package access intentionally unavailable) and prove setup stops before generating an offline private identity or provisioning the data device.

**PASS:** supported OS/architecture accepted; root-only production install refused; real dedicated volume is mounted at `/var/lib/vaultwarden-oci`; immutable release/current/vwctl/config/secrets exist with correct ownership; a clean host without preinstalled `age-keygen` reaches the setup-owned Age bootstrap before private-key generation and storage provisioning; terminal-driven `--auto` without a recipient reaches the verified recovery-kit handoff and removes its transient offline identity after successful custody; an explicit recipient reaches installed config/secrets unchanged and is not replaced; fully headless `--auto` without a recipient fails before storage provisioning; a failed Age bootstrap creates no private identity and does not provision the data device; setup stops at a truthful external-config/custody checkpoint. **FAIL:** any silent persistent-state fallback to `/`, explicit-recipient substitution, headless generated private identity, private-identity generation before required Age tooling is verified, data-device provisioning after a failed Age bootstrap, install mutation before missing headless custody is rejected, or false success.

## 2. Dedicated-volume identity, boot guard, and restart safety

Record `findmnt`, UUID/type, `/etc/vaultwarden-oci/storage-identity.json`, and the volume marker. Start successfully, then on disposable state hide/unmount the intended volume and exercise boot/service restart safeguards.

**PASS:** start/doctor/mutating paths fail safely and Docker/systemd do not recreate persistent appliance paths on root. Restore the intended volume before continuing.

### Normal reboot persistence

After the candidate is installed or reached through the supported current-predecessor update path, record `vwctl versions`, `vwctl status`, `vwctl doctor`, `systemctl is-enabled vaultwarden-oci.target`, `systemctl is-active vaultwarden-oci.target`, `systemctl status vaultwarden-oci.service --no-pager`, and `stat -c '%U:%G %a %n' /run/vaultwarden-oci`. Perform a genuine `sudo reboot`.

After reconnecting, **do not** manually create `/run/vaultwarden-oci`, run `vwctl start`, or manually start the lifecycle service. SSH may become available before the normal boot transaction has reached the appliance target. Allow the boot-owned lifecycle path to converge naturally for up to the service's existing `TimeoutStartSec=600`; while waiting, use `systemctl is-active vaultwarden-oci.target`, `systemctl is-active vaultwarden-oci.service`, and `systemctl is-failed vaultwarden-oci.service` to distinguish normal activation from an actual failure. Do not judge a still-activating boot as failed merely because the runtime root or containers are not present yet.

After the target has converged or the lifecycle service has failed, re-run the version/status/doctor and target/service checks, inspect both managed containers, and require `root:root 700 /run/vaultwarden-oci`. Inspect `journalctl -b -u vaultwarden-oci.service --no-pager` and require that `226/NAMESPACE`, `Failed to set up mount namespacing`, and `/run/vaultwarden-oci: No such file or directory` are absent and that the current-boot lifecycle invocation completed successfully.

The supported CrowdSec Cloudflare Worker is intentionally boot-disabled. Immediately after a genuine reboot, `crowdsec.cloudflare` may therefore be the only doctor `FAIL`, and a health-timer invocation during that expected unarmed window may be recorded failed. First prove the lifecycle/runtime-directory reboot boundary above. Then run `sudo vwctl crowdsec remediation-start`, set every recreated bouncer Worker Route to Fail Open in Cloudflare, run `sudo vwctl crowdsec confirm-fail-open`, clear any health/notification failure recorded during the unarmed window, and re-run the health service. Finally inspect `systemctl --failed --no-pager`, `vwctl timers`, and the appliance timers; require no remaining unexpected failure; then run a real `vwctl backup` followed by final status and doctor.

**PASS:** dedicated storage remounts; immutable release selection survives; systemd recreates the volatile runtime root before the appliance service executes; `vaultwarden-oci.service` is active with successful current-boot `ExecStart`; Vaultwarden and Caddy are running, unpaused, and healthy; the original namespace failure is absent; the intentionally boot-disabled Cloudflare Worker can be explicitly re-armed and returns CrowdSec/health automation to the expected state; status/doctor are truthful; and the post-reboot backup creates and verifies a new `.vwrec` without degrading either container. **FAIL:** manual runtime-directory or lifecycle recovery is required, the namespace failure recurs, release/storage selection changes, service/container health is not restored after the bounded boot convergence window, CrowdSec cannot be safely re-armed, an unexpected failed unit/timer remains, or post-reboot backup fails.

## 3. Config/secrets, existing Admin policy, restart UX, and plaintext leakage

Use only `vwctl config edit/validate` and `vwctl secrets edit/validate` for normal configuration. Configure distinct operational/offline Age identities and required test credentials. For the terminal-auto-generated case, inspect root-owned volatile state before and after the recovery-kit handoff.

On a clean installation with no historical Vaultwarden Admin file, inspect the running container environment and prove `CONFIG_FILE=/tmp/vaultwarden-admin-config.json` with `/tmp` backed by the declared container tmpfs. Make a harmless Admin-panel setting change, use the supported restart path, and prove the web-only change does not become durable while the value rendered from `config.toml` remains authoritative.

On a separate disposable upgrade host, start from the exact supported predecessor and create a representative pre-existing `/var/lib/vaultwarden-oci/data/config.json` before the candidate update. Include at least one appliance-supported policy difference, such as organization creation restricted to `none`, and at least one harmless legacy-only key. Do not use production secrets as fixtures.

Exercise the exact candidate update and prove the bounded transition in order:

1. the candidate starts healthy without silently replacing the historical Admin policy;
2. the running container initially has `CONFIG_FILE=/data/config.json` and the representative historical supported policy is still effective;
3. `sudo vwctl config edit` reports the supported legacy/current difference without printing secret values and refuses finalization while the supported values differ;
4. after copying the intended supported value into `config.toml` (and using `secrets edit` for any relevant credential authority), the interactive flow names legacy-only/incompatible/sensitive keys by **name only**, asks for explicit finalization, and writes a root-only digest-bound reconciliation marker;
5. accepting the normal restart prompt makes the next runtime use `CONFIG_FILE=/tmp/vaultwarden-admin-config.json` while the historical file remains retained rather than being destructively deleted;
6. changing that retained historical file after finalization invalidates its digest binding and makes the reconciliation state pending again rather than silently ignoring newly persisted Admin policy; restore/reconcile the fixture before continuing;
7. a normal successful interactive `config edit` and `secrets edit` on the reconciled state offer the expected restart behavior, while non-TTY callers do not block on prompts.

**PASS:** encrypted authority is valid/decryptable by the operational identity; the offline private identity is not persistent server state; a setup-generated offline identity exists only in protected volatile storage until handoff and is absent afterward; process listings/logs/operator config/release files contain no plaintext credential leakage; clean installs use tmpfs Admin persistence; supported predecessor upgrades preserve pre-existing Admin policy until explicit reconciliation; finalization cannot occur while supported values differ; the marker is bound to the exact historical file; legacy-only/sensitive **values** are never displayed or persisted in the marker; and restart semantics are truthful. **FAIL:** an update silently discards historical Admin policy, an unfinalized legacy file is ignored, unsupported/sensitive values are printed, finalization bypasses supported differences, or web Admin changes remain a competing durable authority after reconciliation.

## 4. Exact custom Caddy, Cloudflare trust, and fail-closed origin

Inspect the installed Caddy module set and rendered configuration. Exercise real origin packets from permitted Cloudflare test context and a non-Cloudflare source where the environment permits it; also invalidate current and cached range input on disposable state.

**PASS:** exact-pinned Cloudflare DNS, trusted-proxy/client-IP, combined-range, and rate-limit capabilities are present; Caddy has one trusted-proxy authority; direct non-Cloudflare origin TCP/443 is denied; no safe range policy means fail-closed ingress.

## 5. `/admin` protection, normal navigation, SMTP test, and authentication rate limiting

With admin enabled, prove Vaultwarden admin token + Caddy rate limit + one outer auth gate. Exercise repeated test authentication requests from a safe source. In a browser, pass Caddy Basic Auth and then authenticate to Vaultwarden `/admin` using the original recoverable `vaultwarden_admin_token` from the supported custody path.

Navigate several normal Admin pages/actions in one minute and prove the supported outer interactive budget does not return a premature `429`. Confirm the rendered Caddy route uses the configured default `60` events / `1m` (or the explicitly configured accepted values), while Vaultwarden's own admin-login limiter remains the separate configured control. From the real browser Admin page, run Vaultwarden's SMTP test and prove it completes without the previous outer-route `429`/JSON-parse failure.

Also inspect the volatile runtime admin value only by shape: it must be an Argon2id PHC derived by the selected Vaultwarden image, not the plaintext source secret, and normal Vaultwarden logs must not contain the plaintext `ADMIN_TOKEN` warning.

**PASS:** unauthenticated outer access is rejected; valid outer auth still requires Vaultwarden admin authentication; the original recoverable source admin secret successfully authenticates through the application boundary; normal Admin navigation and the browser SMTP test do not prematurely exhaust the outer route; only an Argon2id PHC is materialized at runtime; configured outer and login-specific rate limiting remain independent; and a deliberately disabled admin route is closed rather than exposed. **FAIL:** the runtime PHC becomes the operator credential, the recoverable source secret no longer authenticates, plaintext admin material leaks, normal navigation hits the former false-positive rate limit, or the outer gate/rate limit can be bypassed.

## 6. Start, status, doctor, dashboard, and logs

```bash
sudo vwctl start
sudo vwctl status
sudo vwctl doctor --json | tee /tmp/vwoci-doctor.json
sudo vwctl logs --tail 50
sudo /opt/vaultwarden-oci/current/vaultwarden_oci/dashboard.sh
```

**PASS:** application healthy, doctor has no `FAIL`, dashboard accurately represents failures/warnings, and dashboard mutations delegate to `vwctl`. Human `status` may use the color dashboard on a TTY, while `status --json` and captured/non-TTY status remain machine-safe and retain the stable CLI contract used by update health gates.

## 7. Backup -> verify -> rclone -> guided restore

Create known vault state, then:

```bash
sudo vwctl backup --remote 'REMOTE:vwoci-acceptance'
sudo vwctl recovery list --remote 'REMOTE:vwoci-acceptance'
```

Record the local `.vwrec` SHA-256 and independently confirm/verify the remote object. Exercise a wrong offline identity first and prove it fails before live mutation. Then exercise guided local restore and guided remote restore on disposable dedicated storage; retain one explicit noninteractive restore case.

During the human paths, exercise the shared offline-identity chooser: secure paste as the Enter/default choice, a matching identity file, and selection of a local recovery-kit ZIP from `/root/vaultwarden-recovery/`. Confirm the configured public recipient is displayed, pasted/extracted plaintext identity material exists only under protected `/run/vaultwarden-oci` state while needed, and cancellation before final restore confirmation leaves containers untouched. Also capture non-TTY omission failures for `restore` and `recovery verify`; they must name the explicit `--identity` requirement rather than prompting or selecting a kit.

**PASS:** offsite success only after remote verification; bad preflight does not stop/corrupt healthy state; valid restore returns known state; the chooser does not persist the offline identity or leak private material/passphrases; non-TTY behavior remains deterministic; operational Age private key is absent from `.vwrec` and cannot substitute for the offline identity; status/doctor pass afterward.

## 8. Complete recovery-kit AES-256 ZIP and SMTP email path

Run complete export both through the interactive shared identity chooser and with an explicit `--offline-identity`. Also exercise the first-run terminal-generated recovery-kit path from section 1. Inspect process/log/filesystem behavior and exercise SMTP email handoff where a real test account is available. A non-TTY export with the identity option omitted must fail immediately with actionable `--offline-identity` guidance; it must not auto-select or extract a local kit.

**PASS:** exact documented member set, AES-256 encryption, correct-password test succeeds, wrong/empty/no-password tests fail, passphrase never appears in argv/env/file/email/logs, ZIP verification completes before SMTP, email failure is reported as email failure rather than archive-verification failure, the first-run generated kit contains the generated credential values plus both Age private identities, and the setup-generated offline private identity is removed from host-side volatile storage only after successful custody handoff. If handoff is deliberately declined/fails, the transient identity remains protected and setup reports truthful recovery guidance instead of claiming success.

## 9. Stable update, supported-predecessor handoff, config-owner transition, and rollback boundary

From a healthy installed release:

```bash
sudo vwctl update check
sudo vwctl update apply
sudo vwctl versions
sudo vwctl status
sudo vwctl doctor --json
```

**PASS for the ordinary stable path:** the project candidate is discovered/staged with exact immutable values before downtime where practical; a verified pre-update `.vwrec` exists before candidate-owned persistent-state mutation; activation health-gates; safely rollbackable pre-mutation failure restores the previous release coherently; and a post-possible-data-mutation failure refuses fake old-code-only rollback and identifies the verified recovery point as the downgrade boundary.

When the release deliberately supports a predecessor compatibility transition, exercise that transition from the exact documented predecessor rather than synthesizing arbitrary intermediate hops. Record each boundary separately:

1. **Pre-recovery Worker re-arm:** the predecessor's broader/legacy Cloudflare Worker policy is replaced by the supported local-source policy (`cscli`,`crowdsec`), the old Fail Open proof is invalidated, a new systemd invocation is created, and the update stops for explicit operator Fail Open confirmation before recovery or target data mutation.
2. **Controller handoff when required:** candidate code may pre-stage only the exact target update controller and publish the bounded handoff while `/opt/vaultwarden-oci/current` still points to the predecessor. Ordinary non-update commands continue to execute through the selected predecessor. The handoff does not advance recovery or silently activate the target.
3. **Target-owned retry:** rerunning the same installed update command through the staged target controller creates/verifies the pre-update recovery point, owns the bounded application-health settle window, and continues the transaction.
4. **Existing Admin-policy preservation:** when the predecessor has the representative `config.json` fixture from section 3, target activation keeps that exact historical file effective until explicit reconciliation. The update itself must not silently flip its supported policy to catalog defaults merely because the target owns a new steady-state config model.
5. **Forward-only host dependency boundary:** any explicitly permitted CrowdSec/logrotate compatibility package transition occurs only after candidate prevalidation and verified recovery. It is host state outside `.vwrec` rollback; no general apt upgrade, kernel update, package downgrade, or reboot is implied.
6. **Coherent failure and retry:** on disposable state inject a candidate failure after the permitted host dependency transition. Application rollback must restore a healthy predecessor without pretending to roll back apt state; CrowdSec ownership must remain approved; and retrying the same target must converge safely without destructive package cleanup.

**PASS:** every intentional stop names the next operator action; Worker source policy/invocation/Fail Open proof is never silently reused; `current` and installed launcher ownership are truthful at each handoff boundary; recovery occurs before forward-only host expansion; pre-existing Admin policy remains effective until the operator separately finalizes its reconciliation; the predecessor remains healthy after rollback with retained approved host state; and the same target succeeds on retry. **FAIL:** candidate checkout directly takes over ordinary commands, a stale Worker invocation/Fail Open confirmation is accepted, recovery advances during a pre-recovery handoff, generic package maintenance is folded into application update, historical Admin policy is silently replaced, or rollback claims to undo host package state it did not restore.

## 10. Explicit `--use-latest` exact freeze and source-aware identity

On separate disposable state:

```bash
sudo vwctl update check --use-latest
sudo vwctl update apply --use-latest
```

Also exercise `setup.sh ... --use-latest` on a separate disposable blank install, including the terminal-driven `--auto` path where applicable.

In addition to exact upstream refs/digests, prove source-aware immutable identity:

1. changing release-owned source bytes changes the `.latest` identity even when component/image pins are unchanged;
2. generated `__pycache__`/`.pyc` content does not affect identity and installed `vwctl` does not create bytecode inside immutable releases;
3. an already-frozen legacy latest source can be re-keyed locally without silently resolving a different upstream snapshot;
4. where a bounded predecessor controller handoff exists, a newer source-aware snapshot may supersede only an older **unselected, pre-recovery** handoff; it must not replace a selected release or a handoff that has crossed the recovery boundary.

**PASS:** every supported mutable upstream boundary is resolved once to exact refs/digests; exact release-owned source bytes participate in the frozen identity; cache artifacts do not; no installed image/config/state retains floating `latest` semantics; and supported long-option forms do not bypass setup warning/confirmation semantics.

## 11. Update-check timer, edge maintenance, host upgrade, and reboot-required handling

```bash
sudo systemctl enable --now vaultwarden-oci.target
sudo systemctl start vaultwarden-oci-maintenance.service
sudo systemctl show vaultwarden-oci-maintenance.service -p Result --value
sudo vwctl doctor --json
sudo vwctl timers
sudo vwctl host-upgrade check
sudo vwctl host-upgrade apply
```

Exercise the five-minute health service's **independent** DNS synchronization path. Check pre-start `dns update --dry-run` (no write), post-start `dns update` with verified read-back, and clean `dns status`. Require exactly one proxied A record for the validated public IPv4 and no explicit AAAA ownership; prove a temporary DNS failure does not fail local health. Record the Cloudflare last-known-good age immediately before and after the maintenance invocation. The maintenance unit must refresh the origin policy through `vwctl edge refresh` before running doctor, and the installed maintenance timer must be daily so a continuously running host does not age past the 72-hour last-known-good validity window merely because no operator restarted or manually refreshed it.

**PASS:** the maintenance service reports `success`, the Cloudflare CIDR and iptables checks pass with a newly refreshed policy, all four appliance timers remain healthy, automatic project **check/notification** works without unattended application apply, host package workflow remains separate except for an explicitly documented/tested supported-predecessor compatibility dependency transition from section 9, reboot-required state is surfaced when applicable, and no supported path auto-reboots.

## 12. CrowdSec split remediation and representative notification path

Exercise the supported small-team protection split with real systemd/CrowdSec state:

```bash
sudo vwctl crowdsec setup
sudo vwctl crowdsec remediation-start
# Set every bouncer-created Cloudflare Worker Route to Fail Open.
sudo vwctl crowdsec confirm-fail-open
sudo vwctl doctor --json | tee /tmp/vwoci-crowdsec-doctor.json
sudo systemctl is-active crowdsec.service
sudo systemctl is-active crowdsec-firewall-bouncer.service
sudo systemctl is-enabled crowdsec-firewall-bouncer.service
sudo systemctl is-active crowdsec-cloudflare-worker-bouncer.service
sudo systemctl is-enabled crowdsec-cloudflare-worker-bouncer.service || true
```

Record secret-free live nftables evidence for both families and the Worker `InvocationID`. Verify the Worker configuration/attestation reports exactly the local decision sources `cscli` and `crowdsec`.

The supported ownership model is:

- CrowdSec engine + Hub collections detect Caddy, Vaultwarden, SSH/Linux, and kernel/firewall abuse;
- the nftables firewall bouncer is active and enabled for broad/community decisions on host `INPUT` only;
- it owns exactly the IPv4 `crowdsec-chain-input` and IPv6 `crowdsec6-chain-input` hooks and no `forward` hook;
- it never owns Docker `FORWARD` or `DOCKER-USER`;
- Docker/public 443 remains under the separate Cloudflare-only origin filter;
- the Cloudflare Worker handles local/proxied decisions only, is active for the explicitly armed invocation, remains boot-disabled, is attested to that exact invocation/config, and is Fail-Open-confirmed for that invocation.

Require these canonical doctor IDs to be `PASS`: `crowdsec.engine`, `crowdsec.hub`, `crowdsec.firewall`, and `crowdsec.cloudflare`.

Then exercise one real built-in operational HTTPS provider success, one documented transient path with SMTP fallback, and direct SMTP test. Also verify that SMTP-only configuration does **not** claim to enable systemd failure alerts when `[notifications]` is absent. For CyberPersons, status-only transient is `503 service_unavailable`; `429` and `500 send_failed` must not become fallback-eligible by status alone. Inspect the delivered diagnostics: API success must identify the actual HTTPS provider route, direct SMTP must identify direct authenticated SMTP, and a real eligible fallback must identify authenticated SMTP fallback. The direct SMTP path must retain normal certificate/hostname validation regardless of Vaultwarden's application-specific invalid-certificate/hostname options.

**PASS:** all four CrowdSec checks pass; IPv4/IPv6 firewall ownership is exactly host INPUT-only; no CrowdSec rule claims `forward`/`DOCKER-USER`; the Worker is local-source-only, boot-disabled, invocation-attested, and Fail-Open-confirmed; the Cloudflare origin filter still exclusively owns Docker/public 443; successful notification API delivery does not invoke SMTP and truthfully labels the API route; eligible transient fallback is bounded and truthfully labelled; direct SMTP is truthfully labelled and uses strict TLS; and auth/TLS/permanent/ambiguous failures remain visible.

## 13. Evidence and cleanup

Collect only secret-free evidence: commit/version, architecture/Ubuntu build, storage identity/mount evidence, exact resolved pins, command/result, doctor JSON, artifact hashes, systemd invocation IDs, nftables hook names, reconciliation-marker digest/state (not secret values), and external verification notes. Do not record generated private identities, recovery-kit passphrases, admin plaintext credentials, SMTP passwords, bouncer API keys, or other plaintext secrets as acceptance evidence. Remove acceptance-only hosts/remote objects explicitly and rotate test credentials as appropriate.

Report each architecture and each external-provider section as `PASS`, `FAIL`, or `NOT RUN`. CI integration that builds Caddy, uses real Age/SOPS/rclone on temporary data, verifies an AES ZIP, or exercises Docker packet rules is valuable, but it is not a substitute for this disposable real-host gate.
