# rc.14 VM8 temporary production-acceptance harness

**Temporary acceptance branch — never merge these host scripts to `v2` or to PR #436.**

This directory holds the exact six one-shot scripts prepared for the disposable
`ubuntu@vaultwarden-oci-8` Ubuntu 26.04 ARM64 host. They are uploaded here
**only to avoid manual script uploads**. Once accepted, archive the concise
results in `docs/HOST-ACCEPTANCE.md` and delete this temporary branch.

The tested **application** candidate remains independently pinned to
`92b9300f96125d19105cc1d4865024cb49612b28`
on `feature/cf-free-auto-fail-open`; the harness branch's commit is not
an application release. Existing selected rc.13 remains until Phase 01 explicitly
health-gates the supported updater and verifies its encrypted pre-update recovery.

| Phase | Script | Gate |
| --- | --- | --- |
| 01 | `01-upgrade.sh` | rc.13→rc.14 exact-source update through installed updater; verified .vwrec, source and doctor |
| 02 | `02-controlled-stop-rearm.sh` | Known upstream exit1 normalized only after Route cleanup; one new invocation and Fail Open |
| 03 | `03-preboot-reboot.sh` | Reversible DNS-condition guard, opt-in boot unit and app target enablement, real reboot |
| 04 | `04-postboot-verify.sh` | Kernel boot, original data, rc.14, app, new Worker Route Fail Open, all four timers |
| 05 | `05-scheduled-operations.sh` | Actual four scheduled services including local-only encrypted backup, DNS writer skipped |
| 06 | `06-safe-cleanup.sh` | Disable target/timers/boot rearm before removing test-only DNS condition |

**No automatic retries.** Do not rerun an already-started phase after HOLD.
The only automatic work is within the approved one-shot service and explicitly
bounded read-only provider checks. Keep tokens, private journals and the encrypted
recovery evidence off GitHub and out of chat; report only printed PASS/HOLD
markers and private evidence directory paths.

**Download procedure:** take a GitHub *commit SHA* for this temporary branch
and fetch all six files and `SHA256SUMS.txt` from
`https://raw.githubusercontent.com/killer23d/VaultWarden-OCI/<commit>/tests/host-acceptance/rc14-vm8/<name>`,
verify `sha256sum --check SHA256SUMS.txt` and `bash -n`, then execute the first
phase with `bash 01-upgrade.sh`. Always fetch by immutable SHA, never a moving
branch URL. Run later phases one at a time. Reconnect over approved private
OCI access after the genuine reboot (Phase 03); no public SSH is necessary.

**Important scope limit:** the suite contains a reversible test-only
`ConditionPathExists` override for the public Cloudflare DNS writer. It
prevents a scheduled health job from changing DNS on the disposable VM; do
not remove it while the target or any timer remains active. The cleanup script
checks previous private PASS receipts, disables automation, and only then
removes that override. If a phase HOLDs after a partial mutation, diagnose
and reconcile the exact state before proceeding; the successful cleanup
sequence must never be invoked as a blind recovery operation.

**CI check:** `tests/test_rc14_vm8_script_bundle.py` checks the exact pinned
SHA-256 for every script, parses embedded Python, validates Bash syntax, and
checks phase boundaries. Static CI is not a substitute for live VM8 results.
