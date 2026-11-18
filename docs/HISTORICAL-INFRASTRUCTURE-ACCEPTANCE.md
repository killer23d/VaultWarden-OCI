# Historical infrastructure and disposable-host acceptance

**Archive only — not a runnable gate or operating procedure.**
Consolidated November 18, 2026 UTC. This is the sole current historical
record of the retired OCI/Cloudflare provider, restored-host, and rc.11/rc.12
operator acceptance files. Current software instructions are
[Host acceptance](HOST-ACCEPTANCE.md),
[Development / release policy](DEVELOPMENT.md#software-release-readiness-versus-site-deployment),
[Install](INSTALL.md), [Recovery](RECOVERY.md), and
[OCI administration](OCI-CLOUD-SHELL-AND-PRIVATE-SSH.md).

**Immutable evidence source:** [pre-consolidation commit 1a59e5501c6a28ed990a1fe9745afa23273fcbfc](https://github.com/killer23d/VaultWarden-OCI/tree/1a59e5501c6a28ed990a1fe9745afa23273fcbfc).
All removed scripts, tests, complete operator transcripts and dated
runbooks remain recoverable *byte-for-byte* from Git history, not active
release tooling. The manifest below links to each original file.

## Evidence and authority

- Historic `PASS`, `HOLD`, `BLOCKED`, `PENDING`, `INTERRUPTED`,
  and `NOT RUN` belong only to their specific host, date, software
  candidate, approval and tool contract. Never retroactively relabel
  an interrupted or blocked attempt because a later correction passed.
- The user confirmed the inspected OCI VMs, Cloudflare zone/network,
  recovered Vaultwarden data and old offsite objects are
  **non-production laboratory/reference assets**. They are not
  automatically available as blank-data release targets.
- Some original one-shot scripts can format disks, restore data, change
  Cloudflare/firewall, write/prune backup objects, send mail or reboot.
  They were pinned to historical hosts and **must not be replayed**.
- No Age private identity, kit passphrase, plaintext SOPS, token,
  account secret or owner-private host evidence is in this archive.
- OCI/Cloudflare configuration inventory and public transport are
  *different* from product fail-closed host/Docker-origin enforcement.
  The latter stays a **required** software security gate and has
  permanent regression coverage; dropping dated provider audits does
  not remove this requirement.

## Condensed operator chronology

| Date / gate | Recorded observation | Limitation |
| --- | --- | --- |
| Oct 30–31, 2026, rc.11 A0–A6 | Real Ubuntu 26.04 ARM64, separate disk, original Box ciphertext, off-host Age/manifest/SQLite, encrypted-kit cancel and stopped-only restore: **PASS** | Not live production deployment |
| Oct 30–31, rc.11 B0/B1/B2/C1 | Local origin/CrowdSec, authorized dev Caddy/Vaultwarden/Cloudflare/SMTP, checked offsite backup, four timers, natural backup firing **2026-10-31 03:23:17 UTC**, and genuine reboot: **PASS** | Operational evidence is for rc.11, not an uninterrupted rc.13 installation; inbox delivery was not independently proved |
| Oct 31, rc.12 D1 | Fresh blank 50 GiB disk was formatted and mounted; first install **INTERRUPTED** | Root cause not fully established; NOT a clean-install PASS |
| Oct 31, rc.12 D1R/D2 | Proven same-volume continuation (no reformat), SOPS cross-filesystem publish correction, operational/offline Age and encrypted ZIP explicit-path identity: **PASS** | First-pass install and full rc.12 live operation still unproved |
| Nov 1–4, rc.12 P0–P8L-R | Read-only recovery/doctor inventories, known Box ciphertext, off-host crypto verification, guided restored test state, local host foundation and postboot evidence contained distinct PASS/HOLD/BLOCKED results. P8L-R classified **8 eligible** ciphertexts, one undersized fixture quarantined | Stopped/generated runtime path absence is not proof of disk damage; offsite reference state never becomes disposable |
| Nov 4–5, P8M | On fresh disposable restored-data ARM64 test host, original ciphertext verified and stopped-only restore actually completed: **RESTORED/0**; 121 focused tests PASS | Test data restored, hence **not blank** for rc.13 destructive acceptance |
| Nov 5, P8N/P8O | Postrestore read-only **HOLD/0**, later consented **FOUNDATION/0** local Cloudflare origin/CrowdSec security controls | Neither is external origin packet denial or an approval to start the public app |
| Nov 5, P8P/P8Q/P8R | Actual cold reboot changed boot identity; first P8P **BLOCKED/2**; independent P8Q **READONLY/0**; corrected local origin rearm **REARMED/0** | Original P8P remains BLOCKED, not retroactively PASS |
| Nov 5, P8S-A/B/C | Recovered disk/SOPS/SQLite, stopped units, no app listeners, local both-family origin firewall guard; 22 source tests PASS, **HOLD/0** | External OCI/Cloudflare and test-only origin path PENDING |
| Nov 5–13, P8T | Original strict **OCI-only Cloudflare-source** ingress gate **BLOCKED/2** with globally sourced TCP80/443 in inspected list. Later selected private SSH remediation **PASS** (public TCP22/80 denied, private management tested) | Historical strict public TCP443 BLOCKED remains; revised layered architecture permits transport 443 only behind a separately proven fail-closed host filter |
| Nov 6–17, P8U | Source-integrated rc.13 Cloudflare API-first dual-stack LKG/expiry and ordered DOCKER-USER fail-closed runtime policy | No actual rc.13 install on the recovered reference VM |
| Nov 13–17, P8V-A | Provider GET-only batch **16 PASS / 12 PENDING / 0 BLOCKED / 1 NOT RUN — HOLD/1**; IPv6 VNIC/subnet lists explicitly empty | Unscoped/provider metadata and real packet path not proved |
| Nov 13–17, P8V-B | Ubuntu 26.04 ARM64 stopped-host check **8 PASS / 4 PENDING / 0 BLOCKED / 1 NOT RUN — HOLD/1**, 52 offline source tests PASS | Installed rc.12/recovered data; LKG stale, Docker bridge absent while stopped, no external packet witness |
| Nov 17, P8V-C/D | P8V-C **9 PASS / 30 PENDING — HOLD/1**; public DNS proposal **1 PASS / 7 PENDING — HOLD/1** with recursive DNS unavailable/incomplete | No verified DNS absence, Worker isolation or live canary |
| Nov 17–18, test Cloudflare routing | Operator reported exact DNS target = **this test VM**, wildcard = **effective** (operator label), Worker Route = intended test policy, Custom Domain = intended test Worker, independent review **completed** | Exact DNS usually takes precedence over applicable wildcard; reported label alone cannot prove effective DNS behavior. Candidate had **recovered data** |
| Nov 18 UTC, fresh rc.13 P0/P1 | New `vaultwarden-oci-8` Ubuntu 26.04 ARM64, clean pinned source `86288578def00b116e519e41108b7bdf6a2b84ed`, 8 focused tests, one 50 GiB blank unmounted nonboot disk with stable alias: **P0 exit 0**. Supported installer no-mutation **P1 dry-run exit 0** | OCI volume attachment/format approval, off-host Age private-key custody, live install, Cloudflare, SMTP, recovery and packet proof not established |
| Nov 18 UTC, Git index correction | Prior root Git status refreshed a root-owned `.git/index`; a shell status substitution wrongly assumed empty stdout meant clean. Operator repaired **only index ownership**, SHA unchanged; `GIT_INDEX_EXIT=0`; regression fixed in PR #429 | The earlier shell clean-status claim was invalid, but P1 installer dry-run itself passed. P2 has not run |

## Durable lessons for software acceptance

1. Keep exact source/version pins, dedicated nonboot storage, independent
   offline Age custody, rootless/limited runtime and user-safe dry runs.
2. Keep permanent CI/integration contracts for Cloudflare range validity
   and expiry, exact Docker forwarding/NAT/userland-proxy denial,
   Caddy/trusted proxies, CrowdSec host/Worker separation, encrypted
   recovery, update/rollback and reboot integrity. Do **not** mistake
   removal of obsolete provider scripts for removal of product security.
3. Every fresh release needs a genuinely **blank-data** disposable
   target for install, local function, remote test-only encrypted
   backup/readback and guided recovery. A recovered-data VM cannot
   substitute for this.
4. OCI VCN, subnet, NSG/security-list union, private SSH, and Cloudflare
   DNS/Worker routing are **site administrator setup** documented in
   current guides. Their historical provider scans are optional
   reference, not independent software-release gates.
5. A passing CI or a clean installer dry-run is **not** production GO.
   The actual rc.13 installation, live origin-path checks, test-only
   restore and source release decision remain separate, truthful
   statuses until operator-approved execution.

## Original source recovery (read-only Git inspection)

These commands only display historical source from the immutable
pre-cleanup commit; they do not interact with OCI, Cloudflare or hosts.

```bash
git show 1a59e5501c6a28ed990a1fe9745afa23273fcbfc:docs/PRODUCTION-ACCEPTANCE-UBUNTU2604.md
git show 1a59e5501c6a28ed990a1fe9745afa23273fcbfc:docs/P8T-PRIVATE-SSH-REMEDIATION-CLOSEOUT.md
git show 1a59e5501c6a28ed990a1fe9745afa23273fcbfc:tests/host-acceptance/21-b1-dev-operating-acceptance.sh
git show 1a59e5501c6a28ed990a1fe9745afa23273fcbfc:tests/host-acceptance/production-p8v-oci-provider-batch-readonly.py
```

## Complete retired file index

All paths below are absent from the **active** tree after consolidation,
but still available via the linked immutable pre-cleanup source.

### Chronological acceptance documentation (22 files)

- [`docs/ACCEPTANCE-HANDOFF.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/ACCEPTANCE-HANDOFF.md)
- [`docs/P8M-BATCHED-CRYPTO-RESTORE-NEW-VM.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/P8M-BATCHED-CRYPTO-RESTORE-NEW-VM.md)
- [`docs/P8N-POSTRESTORE-READINESS.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/P8N-POSTRESTORE-READINESS.md)
- [`docs/P8O-BATCHED-LOCAL-SECURITY.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/P8O-BATCHED-LOCAL-SECURITY.md)
- [`docs/P8P-BATCHED-REBOOT-PERSISTENCE.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/P8P-BATCHED-REBOOT-PERSISTENCE.md)
- [`docs/P8Q-POSTBOOT-READONLY-DIAGNOSTIC.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/P8Q-POSTBOOT-READONLY-DIAGNOSTIC.md)
- [`docs/P8R-POSTBOOT-ORIGIN-REARM-BATCH.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/P8R-POSTBOOT-ORIGIN-REARM-BATCH.md)
- [`docs/P8S-A-STOPPED-STATE.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/P8S-A-STOPPED-STATE.md)
- [`docs/P8S-B-ORIGIN-STARTUP-CONTRACT.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/P8S-B-ORIGIN-STARTUP-CONTRACT.md)
- [`docs/P8S-C-EXTERNAL-ISOLATION-HOLD.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/P8S-C-EXTERNAL-ISOLATION-HOLD.md)
- [`docs/P8T-BATCHED-EXTERNAL-ISOLATION-READONLY.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/P8T-BATCHED-EXTERNAL-ISOLATION-READONLY.md)
- [`docs/P8T-PRIVATE-SSH-REMEDIATION-CLOSEOUT.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/P8T-PRIVATE-SSH-REMEDIATION-CLOSEOUT.md)
- [`docs/P8T-SECURITY-LIST-IMPACT.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/P8T-SECURITY-LIST-IMPACT.md)
- [`docs/P8U-LAYERED-ORIGIN-RELEASE.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/P8U-LAYERED-ORIGIN-RELEASE.md)
- [`docs/P8V-CANARY-ISOLATION-HOLD-20261117.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/P8V-CANARY-ISOLATION-HOLD-20261117.md)
- [`docs/P8V-FIRST-RUN-HOLD-AND-READONLY-DIAGNOSTICS.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/P8V-FIRST-RUN-HOLD-AND-READONLY-DIAGNOSTICS.md)
- [`docs/P8V-GROUPED-OCI-PROVIDER-READONLY.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/P8V-GROUPED-OCI-PROVIDER-READONLY.md)
- [`docs/P8V-LAYERED-ORIGIN-ACCEPTANCE-PLAN.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/P8V-LAYERED-ORIGIN-ACCEPTANCE-PLAN.md)
- [`docs/P8V-PRECANARY-GROUPED-READONLY.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/P8V-PRECANARY-GROUPED-READONLY.md)
- [`docs/P8V-READONLY-GATES-AND-CANARY-CONSENT.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/P8V-READONLY-GATES-AND-CANARY-CONSENT.md)
- [`docs/PRODUCTION-ACCEPTANCE-UBUNTU2604.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/PRODUCTION-ACCEPTANCE-UBUNTU2604.md)
- [`docs/PRODUCTION-READINESS.md`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/docs/PRODUCTION-READINESS.md)


### Pinned historical host/operator scripts (50 files)

- [`tests/host-acceptance/01-readonly-audit.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/01-readonly-audit.sh)
- [`tests/host-acceptance/02-fresh-host-preflight.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/02-fresh-host-preflight.sh)
- [`tests/host-acceptance/03-selected-volume-dryrun.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/03-selected-volume-dryrun.sh)
- [`tests/host-acceptance/04-pinned-install-authorized.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/04-pinned-install-authorized.sh)
- [`tests/host-acceptance/05-kit-public-recipient.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/05-kit-public-recipient.py)
- [`tests/host-acceptance/06-kit-public-only-ubuntu.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/06-kit-public-only-ubuntu.py)
- [`tests/host-acceptance/07-kit-identity-match-ubuntu.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/07-kit-identity-match-ubuntu.py)
- [`tests/host-acceptance/08-post-install-failure-diagnostic.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/08-post-install-failure-diagnostic.sh)
- [`tests/host-acceptance/09-sops-failure-investigation.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/09-sops-failure-investigation.sh)
- [`tests/host-acceptance/10-verified-sops-download-probe.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/10-verified-sops-download-probe.sh)
- [`tests/host-acceptance/11-precise-setup-failure-classifier.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/11-precise-setup-failure-classifier.sh)
- [`tests/host-acceptance/12-resume-a2-existing-filesystem.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/12-resume-a2-existing-filesystem.sh)
- [`tests/host-acceptance/13-a2r-final-readonly-attestation.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/13-a2r-final-readonly-attestation.sh)
- [`tests/host-acceptance/14-a3-box-ciphertext-integrity.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/14-a3-box-ciphertext-integrity.sh)
- [`tests/host-acceptance/15-a4-real-box-recovery-verify.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/15-a4-real-box-recovery-verify.sh)
- [`tests/host-acceptance/16-a5-kit-cancel-helper.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/16-a5-kit-cancel-helper.py)
- [`tests/host-acceptance/17-a5-forced-cancel-real-box-restore.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/17-a5-forced-cancel-real-box-restore.sh)
- [`tests/host-acceptance/18-a6-fast-prepost-attestation.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/18-a6-fast-prepost-attestation.sh)
- [`tests/host-acceptance/19-bc-consolidated-readiness.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/19-bc-consolidated-readiness.sh)
- [`tests/host-acceptance/20-b0-foundational-security-with-consent.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/20-b0-foundational-security-with-consent.sh)
- [`tests/host-acceptance/21-b1-dev-operating-acceptance.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/21-b1-dev-operating-acceptance.sh)
- [`tests/host-acceptance/22-c1-dev-reboot-and-notifications.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/22-c1-dev-reboot-and-notifications.sh)
- [`tests/host-acceptance/23-b2-natural-timer-witness.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/23-b2-natural-timer-witness.sh)
- [`tests/host-acceptance/24-rc12-clean-install-ubuntu2604-arm64.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/24-rc12-clean-install-ubuntu2604-arm64.sh)
- [`tests/host-acceptance/25-rc12-real-encrypted-kit-path.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/25-rc12-real-encrypted-kit-path.py)
- [`tests/host-acceptance/26-rc12-resume-proven-existing-filesystem.sh`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/26-rc12-resume-proven-existing-filesystem.sh)
- [`tests/host-acceptance/production-cryptographic-readiness.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-cryptographic-readiness.py)
- [`tests/host-acceptance/production-p8m-batched-crypto-restore-newvm.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-p8m-batched-crypto-restore-newvm.py)
- [`tests/host-acceptance/production-p8n-postrestore-readiness.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-p8n-postrestore-readiness.py)
- [`tests/host-acceptance/production-p8o-batched-local-security.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-p8o-batched-local-security.py)
- [`tests/host-acceptance/production-p8p-batched-reboot-persistence-newvm.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-p8p-batched-reboot-persistence-newvm.py)
- [`tests/host-acceptance/production-p8q-postboot-readonly-diagnostic.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-p8q-postboot-readonly-diagnostic.py)
- [`tests/host-acceptance/production-p8r-postboot-origin-rearm-batch.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-p8r-postboot-origin-rearm-batch.py)
- [`tests/host-acceptance/production-p8s-a-stopped-state-preflight.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-p8s-a-stopped-state-preflight.py)
- [`tests/host-acceptance/production-p8t-external-boundary-readonly.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-p8t-external-boundary-readonly.py)
- [`tests/host-acceptance/production-p8t-oci-cloud-shell-readonly.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-p8t-oci-cloud-shell-readonly.py)
- [`tests/host-acceptance/production-p8t-oci-security-list-impact-readonly.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-p8t-oci-security-list-impact-readonly.py)
- [`tests/host-acceptance/production-p8t-private-ssh-policy.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-p8t-private-ssh-policy.py)
- [`tests/host-acceptance/production-p8v-dns-proposal-readonly.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-p8v-dns-proposal-readonly.py)
- [`tests/host-acceptance/production-p8v-host-layered-readonly.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-p8v-host-layered-readonly.py)
- [`tests/host-acceptance/production-p8v-oci-layered-readonly.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-p8v-oci-layered-readonly.py)
- [`tests/host-acceptance/production-p8v-oci-provider-batch-readonly.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-p8v-oci-provider-batch-readonly.py)
- [`tests/host-acceptance/production-p8v-precanary-readonly.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-p8v-precanary-readonly.py)
- [`tests/host-acceptance/production-postboot-origin-rearm-consent.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-postboot-origin-rearm-consent.py)
- [`tests/host-acceptance/production-postfoundation-isolation-readiness.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-postfoundation-isolation-readiness.py)
- [`tests/host-acceptance/production-postrestore-preactivation.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-postrestore-preactivation.py)
- [`tests/host-acceptance/production-real-restore-acceptance.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-real-restore-acceptance.py)
- [`tests/host-acceptance/production-reboot-persistence-consent.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-reboot-persistence-consent.py)
- [`tests/host-acceptance/production-recovery-source-preflight.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-recovery-source-preflight.py)
- [`tests/host-acceptance/production-security-foundation-consent.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/host-acceptance/production-security-foundation-consent.py)


### Tests only of retired host-gate scripts (26 files)

- [`tests/test_host_acceptance_rc12_gate_syntax.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_host_acceptance_rc12_gate_syntax.py)
- [`tests/test_production_cryptographic_readiness.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_cryptographic_readiness.py)
- [`tests/test_production_p8m_batched_crypto_restore_newvm.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_p8m_batched_crypto_restore_newvm.py)
- [`tests/test_production_p8n_postrestore_readiness.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_p8n_postrestore_readiness.py)
- [`tests/test_production_p8o_batched_local_security.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_p8o_batched_local_security.py)
- [`tests/test_production_p8p_batched_reboot_persistence.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_p8p_batched_reboot_persistence.py)
- [`tests/test_production_p8q_postboot_readonly.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_p8q_postboot_readonly.py)
- [`tests/test_production_p8r_postboot_origin_rearm_batch.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_p8r_postboot_origin_rearm_batch.py)
- [`tests/test_production_p8s_a_stopped_state.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_p8s_a_stopped_state.py)
- [`tests/test_production_p8t_cloudshell.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_p8t_cloudshell.py)
- [`tests/test_production_p8t_external_boundary.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_p8t_external_boundary.py)
- [`tests/test_production_p8t_impact.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_p8t_impact.py)
- [`tests/test_production_p8t_private_ssh_policy.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_p8t_private_ssh_policy.py)
- [`tests/test_production_p8v_dns_proposal.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_p8v_dns_proposal.py)
- [`tests/test_production_p8v_host_layered.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_p8v_host_layered.py)
- [`tests/test_production_p8v_integrated_source_pins.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_p8v_integrated_source_pins.py)
- [`tests/test_production_p8v_oci_layered.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_p8v_oci_layered.py)
- [`tests/test_production_p8v_oci_provider_batch.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_p8v_oci_provider_batch.py)
- [`tests/test_production_p8v_precanary.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_p8v_precanary.py)
- [`tests/test_production_postboot_origin_rearm_consent.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_postboot_origin_rearm_consent.py)
- [`tests/test_production_postfoundation_isolation_readiness.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_postfoundation_isolation_readiness.py)
- [`tests/test_production_postrestore_preactivation.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_postrestore_preactivation.py)
- [`tests/test_production_real_restore_acceptance.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_real_restore_acceptance.py)
- [`tests/test_production_reboot_persistence_consent.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_reboot_persistence_consent.py)
- [`tests/test_production_recovery_source_preflight.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_recovery_source_preflight.py)
- [`tests/test_production_security_foundation_consent.py`](https://github.com/killer23d/VaultWarden-OCI/blob/1a59e5501c6a28ed990a1fe9745afa23273fcbfc/tests/test_production_security_foundation_consent.py)
