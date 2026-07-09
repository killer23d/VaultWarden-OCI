# Post-PR #233 Cross-Subsystem Contract Bug Audit

## Executive Summary

This is a report-only audit of the `delta` branch immediately after PR #233. The
audited executable baseline is commit
`3faf7a31295b45a0d97eb2699fc97ab1de69df59` (`Merge pull request #233 from
killer23d/codex/secrets-schema-contract-closure`). The later commit that adds
this report is documentation-only and is not part of the audited executable
baseline.

Verdict: the repository is not clean. I found three confirmed cross-subsystem
contract bugs:

| ID | Severity | Confidence | Contract mismatch |
| --- | --- | --- | --- |
| CT-01 | Medium | High | DNS and firewall update leaf scripts convert operation-lock contention exit 75 into exit 0, so skipped work is reported as success. |
| CT-02 | Medium | High | rclone config discovery advertises `/root/.config/rclone/rclone.conf`, but the shared validator rejects every `/root` path. |
| CT-03 | High | High | Local and remote retention claim to preserve the most recent backup, but delete every archive older than retention when more than one stale archive exists. |

The PR #233 secrets-schema closure itself looks mostly coherent: schema apply
types are closed, Compose restart targets are schema-validated, CrowdSec Worker
keys use a narrow config renderer, runtime secret export is schema-driven, and
tests cover the main schema/apply invariants.

## Audit Baseline

| Field | Value |
| --- | --- |
| Repository | `https://github.com/killer23d/VaultWarden-OCI.git` |
| Local worktree | `/Users/TIS/Documents/Codex/2026-07-06/work-on-https-github-com-killer23d/VaultWarden-OCI` |
| Branch | `delta` |
| Audited executable HEAD | `3faf7a31295b45a0d97eb2699fc97ab1de69df59` |
| Audited HEAD subject | `Merge pull request #233 from killer23d/codex/secrets-schema-contract-closure` |
| Audited HEAD date | `2026-07-09T09:19:55-07:00` |
| Audited HEAD author | `Kwan Ho Philip Kwong <16860382+killer23d@users.noreply.github.com>` |
| Worktree at audit start | Clean (`git status --short` produced no output) |
| Report commit | To be created after this report file only; not included in the executable audit baseline. |

Baseline commands performed before audit:

```text
git fetch origin delta
git checkout delta
git pull --ff-only origin delta
git status --short
git branch --show-current
git rev-parse HEAD
git log --oneline --decorate -30
```

Recent history at the audited baseline:

```text
3faf7a3 (HEAD -> delta, origin/delta) Merge pull request #233 from killer23d/codex/secrets-schema-contract-closure
bc78766 Close remaining secrets contract gaps
6178f7f Close secrets schema apply contract
f541b0d fix(notify): align dead-letter sentinel path
52f057b test(permissions): cover Caddy config first-start contract
2e9cdac fix(caddy): align init config mount with runtime
48572b6 Merge pull request #231 from killer23d/codex/noble-production-readiness-closure
0571fc1 fix(setup): own zstd backup dependency
600373e test(backup): assert zstd setup ownership
e1f1022 fix(docs): align final production support wording
2d118af fix(security): finalize recovery kit attachment encryption
14fe321 Merge pull request #232 from killer23d/codex/finalize-existing-pr-#231
90e29e4 fix(readiness): close final PR blockers
b758deb fix(ci): satisfy shellcheck on sops validation
370c631 fix(setup): enforce selected SOPS version
723958c fix(readiness): close Noble production blockers
8314f54 Update final production readiness report
bd8a5e7 Add final production readiness audit
2837fc1 Update AGENTS.md
2d15153 Merge pull request #230 from killer23d/codex/cli-contract-consistency
096e25f fix(storage): preserve outer CLI mode precedence
3032385 fix(storage): preserve CLI precedence after env load
e594e5c fix(storage): parse migration CLI once
dc61ccc fix(cli): tighten migration option scope
a31f3fc fix(cli): normalize script command contracts
a8dd6ac Merge pull request #229 from killer23d/codex/fix-uninstall-test-reset-gaps
a0f96ff test: Fix test suite strict ShellCheck SC2034 warnings
b731c7c Fix uninstall/test-reset firewall gaps, SC2086 and test regressions
6757c97 fix(firewall): resolve Cloudflare UFW ownership gap
ab61242 fix uninstall test-reset cleanup gaps
```

## What This Audit Defines as a Contract Bug

A contract bug is a production-reachable disagreement where two or more
components encode incompatible expectations for the same behavior. Examples:

- A producer advertises a state, path, exit code, or file format that a consumer
  rejects.
- A systemd unit, Make target, dashboard action, or wrapper interprets a script
  result differently from the script/library contract.
- Tests or documented invariants protect one side of a behavior while another
  production caller violates it.
- A backup, restore, secrets, storage, or firewall invariant is true in one
  subsystem and false in another subsystem that depends on it.

This audit does not treat spelling issues, style drift, speculative hardening,
or intentionally documented differences as findings.

## Scope and Method

I read `AGENTS.md` first, then audited the current `delta` HEAD for cross-surface
contracts across:

- Top-level operator APIs: `setup.sh`, `startup.sh`, `backup.sh`, `restore.sh`,
  `maintenance.sh`, `edit-secrets.sh`, `recover.sh`, `dashboard.sh`, `Makefile`.
- Shared libraries: `lib/config.sh`, `lib/common.sh`, `lib/operations.sh`,
  `lib/secrets.sh`, `lib/schema.sh`, `lib/backup-utils.sh`,
  `lib/crowdsec-worker.sh`, storage/migration helpers.
- Structured utilities under `utilities/`, especially setup, systemd, secrets,
  maintenance, backup, restore, firewall, DNS, CrowdSec, uninstall, and
  environment sync utilities.
- `systemd/` unit and timer files.
- `docker-compose.yml.example`, `.env.example`, `.sops.yaml` handling, and
  `secrets-schema.yaml`.
- Active docs under `docs/` and top-level README-style operator guidance where
  relevant to production behavior.
- Tests under `tests/` and `.github/workflows/` where they encode contracts or
  reveal coverage gaps.

This was a static contract audit. I did not run the full integration test suite,
Docker, systemd, rclone, SOPS decryption, or destructive backup/restore flows.

## Current Production Contracts Reconstructed

- Supported production matrix: Ubuntu 24.04 LTS Noble only, `amd64`/`arm64`,
  root-operated lifecycle, Docker Engine plus Compose plugin, Cloudflare,
  systemd automation, and boot-volume or attached block/data-volume storage.
- Setup owns host dependency installation and validation: pinned SOPS v3.13.2,
  pinned Mike Farah `yq` v4.53.3, `zstd`, `python3-yaml`, Docker Compose plugin,
  and Noble/architecture preflight.
- Runtime environment is split: repo `.env` stays operator-editable; root-owned
  generated env files live under `${PROJECT_STATE_DIR}/config/install.env` and
  `/etc/vaultwarden/vaultwarden.env`.
- Secrets are SOPS+Age managed. The operational Age key is installed at
  `/etc/vaultwarden/age-key.txt`; offline recovery Age material is not supposed
  to persist on the server.
- `secrets-schema.yaml` is the single committed secret-key schema. It defines
  key names, placeholders, collection mode, requiredness, transforms, and closed
  apply types.
- Runtime Docker secret files are recreated under `/run/vaultwarden-oci/secrets`
  from encrypted secrets at startup and after secret edits/rotations.
- The shared operation guard in `lib/operations.sh` is the authoritative kernel
  lock contract. Expected noninteractive contention is exit 75.
- systemd scheduled jobs must treat expected contention as a clean skip while
  preserving real nonzero failures for `OnFailure=` notification.
- Backups have three tiers: `db`, `full`, and `emergency`. Full/emergency archives
  inject a verified DB snapshot, exclude runtime secret files and operational Age
  keys where appropriate, write integrity sidecars, and support offsite rclone.
- Restore preflights archive layout/storage mode, prompts or requires explicit
  force for destructive operations, creates pre-restore snapshots, rotates Age
  key material unless skipped, repairs permissions, then starts through
  `startup.sh` rather than directly starting Compose.
- Storage mode is fail-closed: when a block/data volume is configured, production
  paths must verify the mount before writing persistent state.
- CrowdSec/Cloudflare integration uses SOPS-managed Cloudflare Worker secrets,
  rendered bouncer config, host firewall updates, and uninstall/test-reset cleanup
  of managed rules and caches.
- Email is Postfix-first for production SMTP delivery, with API/direct fallback
  paths where documented; recovery-kit attachments use SMTP attachment delivery.

## Contract Surface Coverage

| Surface | Coverage result |
| --- | --- |
| Host OS, arch, dependency pins | Coherent. Setup, CI drift checks, and tests align on Noble, `amd64`/`arm64`, SOPS v3.13.2, Mike Farah `yq` v4.53.3, `zstd`, and PyYAML. |
| Top-level CLI, Make, dashboard | Mostly coherent. Public wrappers delegate to structured utilities and root policy is tested. CT-01 affects DNS/firewall command result semantics. |
| Runtime env and storage mode | Coherent in sampled paths. Separate-volume state checks and systemd drop-ins align with the fail-closed mount contract. |
| Secrets schema and PR #233 changes | Coherent. Schema validation closes apply types and targets; CrowdSec Worker keys are not exposed as Compose services. |
| Runtime secret export | Coherent. Startup and edit/rotate paths export schema-managed files to `/run/vaultwarden-oci/secrets`; tests cover stale/inactive cleanup and push placeholders. |
| Operation guard and systemd exit codes | Partially incoherent. Core guard/tests/systemd backups encode exit 75; DNS/firewall leaf scripts mask 75 to 0. See CT-01. |
| Docker/Compose runtime | Coherent in sampled contracts: secret names, Caddy config mount, Postfix mutability exception, service names, and health assumptions align with tests. |
| Backup tiers, verification, and offsite | Partially incoherent. Archive creation/verification contracts are strong; rclone config and retention contracts fail. See CT-02 and CT-03. |
| Restore/recovery | Coherent in sampled paths. Restore uses startup path, storage preflight, archive tool checks, Age rotation, and permission repair. |
| CrowdSec/Cloudflare | Mostly coherent. Schema-driven Worker config apply is closed; firewall/DNS update exit semantics affected by CT-01. |
| Email/failure notification | Coherent in sampled contracts; notification helper resolves secrets and dead-letter sentinel path is recently aligned. |
| Uninstall/test-reset | Coherent in sampled paths. Managed timers, services, containers, networks, subnets, CrowdSec, and firewall cleanup are represented in tests. |
| Tests/CI | Good static coverage for recent closure areas, but missing focused regressions for the three findings. |

## Confirmed Findings

| ID | Severity | Affected contract | Primary impact |
| --- | --- | --- | --- |
| CT-01 | Medium | Operation guard exit 75, systemd/Make/maintenance status semantics, DNS/firewall maintenance | Expected lock-contention skips are silently reported as successful DNS/firewall updates. |
| CT-02 | Medium | rclone config discovery and validation for backup/restore/offsite sync | A valid root-owned rclone config can be discovered and then immediately rejected, disabling offsite operations. |
| CT-03 | High | Backup retention safety across local cleanup, remote pruning, backup rotate, and maintenance | A stale backup set can be pruned to zero recovery points despite the preservation contract. |

### CT-01 - DNS/firewall update scripts mask operation-lock contention as success

Severity: Medium
Confidence: High

Contract sides:

- Shared guard contract: noninteractive skip policy returns exit 75 when another
  VaultWarden operation is active. Evidence: `lib/operations.sh:592-597`.
- Tests encode that same contract: `tests/test-operations.sh:141-155` expects
  noninteractive contention to skip with exit 75.
- systemd units for comparable scheduled operations preserve that signal:
  `systemd/vaultwarden-db-backup.service:60-64`,
  `systemd/vaultwarden-maintenance.service:45-47`, and
  `systemd/vaultwarden-iptables.service:27-29`.
- DNS/firewall leaf scripts disagree by converting guard exit 75 into process
  exit 0: `utilities/maintenance-update-dns.sh:410-418` and
  `utilities/maintenance-update-firewall.sh:232-240`.
- The direct systemd services call those leaf paths through `maintenance.sh`
  (`systemd/vaultwarden-dns-update.service:20`,
  `systemd/vaultwarden-firewall-update.service:13`) and therefore cannot
  distinguish "updated" from "skipped due to active operation."
- Operator entry points such as `Makefile:750-753` and direct shell callers
  report command success from process exit status.

Realistic trigger:

1. A backup, restore, setup, startup, or other mutating operation holds the
   shared operation lock.
2. A DNS update timer, firewall update timer, `sudo make update-dns`, or direct
   `sudo ./maintenance.sh update-firewall` runs noninteractively.
3. `operation_acquire --non-interactive skip` returns 75.
4. The leaf script maps 75 to 0 and exits success.

Actual failure mode:

The operation is skipped but automation and operator surfaces see success. For
DNS this can hide a stale public IP until the next hourly run. For firewall
refresh this can hide a skipped Cloudflare CIDR update for the weekly timer
interval. In aggregate maintenance, `utilities/maintenance-run.sh:161-170` and
`utilities/maintenance-run.sh:187-194` can classify a skipped child update as a
successful update because the child returned 0.

Operator impact:

The operator does not get a failure notification, nonzero shell status, or
summary signal that work was skipped. The status model is especially misleading
for long-interval firewall refresh.

Why tests/CI missed it:

Tests assert the library-level skip code and several systemd `SuccessExitStatus`
contracts, but they do not exercise the DNS/firewall leaf wrappers with
`operation_acquire` returning 75 and do not require the DNS/firewall units to
accept 75 directly.

Minimal remediation direction:

Propagate exit 75 from `maintenance-update-dns.sh` and
`maintenance-update-firewall.sh` instead of converting it to 0. Add
`SuccessExitStatus=0 75` to the DNS/firewall service units, matching backup and
iptables precedent. In aggregate maintenance, treat child exit 75 as a clean
"skipped due to active operation" status rather than success or critical failure.

Regression coverage recommendation:

Add a test that sources or stubs each leaf script with `operation_acquire`
returning 75 and asserts the process exits 75. Add static assertions that
`vaultwarden-dns-update.service` and `vaultwarden-firewall-update.service`
declare `SuccessExitStatus=0 75`.

### CT-02 - rclone resolver advertises `/root` config that validator rejects

Severity: Medium
Confidence: High

Contract sides:

- The shared rclone resolver auto-discovers config in five priority locations,
  including `/root/.config/rclone/rclone.conf`. Evidence:
  `lib/backup-utils.sh:802-843`, specifically `lib/backup-utils.sh:828-830`.
- `setup-systemd` treats that same root config as a valid source to install to
  `/etc/vaultwarden/rclone.conf`: `utilities/setup-systemd.sh:857-883`.
- The shared validator rejects every path whose canonical path is `/root` or
  under `/root`: `lib/backup-utils.sh:860-873`.
- Backup consumers resolve and then validate the result:
  `utilities/backup-run.sh:896-908`. Offsite run/sync/prune call that path at
  `utilities/backup-run.sh:767-769`, `utilities/backup-run.sh:924-925`, and
  `utilities/backup-run.sh:996-997`.
- Restore remote listing mirrors the same resolver/validator contract:
  `utilities/restore-run.sh:469-483`.
- Current tests cover explicit `RCLONE_CONFIG` success but not the root fallback:
  `tests/test-security-privileges.sh:75-98`.

Realistic trigger:

1. The operator configures rclone as root, leaving the only available config at
   `/root/.config/rclone/rclone.conf`.
2. `RCLONE_CONFIG` is unset and `/etc/vaultwarden/rclone.conf` has not yet been
   created by `setup-systemd`, or the operator runs a direct/manual offsite
   command before systemd install.
3. `sudo ./backup.sh run db --rclone`, `sudo ./backup.sh sync`, or
   `sudo ./restore.sh interactive --remote` calls the resolver.
4. The resolver returns `/root/.config/rclone/rclone.conf`; the validator rejects
   it as a sensitive path.

Actual failure mode:

Offsite backup, offsite sync, remote pruning, or remote restore fails before
contacting the remote, despite a config path that the repository itself
auto-discovered and that `setup-systemd` is willing to copy into the canonical
runtime location.

Operator impact:

The root-operated backup/restore path can reject valid rclone credentials with
an error that appears to blame the operator's config path. The workaround is to
manually set `RCLONE_CONFIG` to a non-`/root` file or run systemd install to copy
the config first, but the direct CLI contract does not state that the resolver's
own root fallback is unusable.

Why tests/CI missed it:

The test suite checks `_resolve_rclone_config_arg` only with an explicit
temporary `RCLONE_CONFIG` path. It does not cover auto-discovery fallback order,
root-run rclone defaults, or the resolver/validator round trip for `/root`.

Minimal remediation direction:

Choose one contract and apply it consistently:

- If `/root/.config/rclone/rclone.conf` is supported, allow exactly that rclone
  config path after regular-file, ownership, and world-writable checks, while
  continuing to reject unrelated sensitive `/root` paths.
- If `/root` configs are not supported for direct runtime use, remove the root
  fallback from `_resolve_rclone_config`, update setup/docs to state that direct
  backup/restore requires `/etc/vaultwarden/rclone.conf` or explicit
  `RCLONE_CONFIG`, and fail with that guidance.

Regression coverage recommendation:

Add a test around `_resolve_rclone_config` plus `validate_rclone_config_path`
that simulates each fallback location. Include the `/root/.config/rclone/rclone.conf`
case and assert either successful validation or a resolver refusal before the
validator is called, depending on the chosen policy.

### CT-03 - Retention can delete every stale backup despite last-backup preservation contract

Severity: High
Confidence: High

Contract sides:

- Local retention documents a safety guard before deletion: if there is only one
  backup, deletion is skipped so the last good backup is preserved.
  Evidence: `lib/backup-utils.sh:543-549` and `lib/backup-utils.sh:566-568`.
- The local implementation only checks the pre-prune count and then deletes
  every `.age` archive older than retention: `lib/backup-utils.sh:579-594`.
  It never sorts candidates or exempts the newest archive.
- Remote pruning states the stronger contract directly: "Always preserve at
  least the most recent backup, regardless of age."
  Evidence: `utilities/backup-run.sh:1023-1027`.
- The remote implementation then iterates every remote `.age` file and deletes
  each one older than retention: `utilities/backup-run.sh:1031-1061`. It also
  never exempts the newest remote archive.
- Production callers rely on these cleanup paths from backup rotation,
  maintenance, post-backup cleanup, sync, and remote prune:
  `utilities/backup-run.sh:1530-1573`, `utilities/backup-run.sh:1736-1745`,
  `utilities/backup-run.sh:943-970`, and `lib/maintenance-utils.sh:132-153`.
- Existing tests check that a failed quick verification skips retention before
  exit, but not that retention preserves the last recovery point:
  `tests/test-operator-ui.sh:82-92`.

Realistic trigger:

1. A host has two `full` backups whose embedded filename timestamps are both
   older than `BACKUP_RETENTION_FULL_DAYS`.
2. No fresh backup is created, for example because the operator runs
   `sudo ./backup.sh rotate`, routine maintenance cleanup runs, or remote prune
   runs against an old remote folder.
3. The pre-count is greater than one, so cleanup proceeds.
4. Every archive is older than retention, so every archive is deleted.

Actual failure mode:

The local backup directory or remote backup folder can be pruned to zero `.age`
archives for a backup type. Sidecars are removed along with their primaries.

Operator impact:

An operator can lose the last usable recovery point for a tier merely by running
retention on an all-stale set. This is most dangerous after a period of failed
backups, disabled timers, host outage, or migration where existing backups are
old but still the only recovery material.

Why tests/CI missed it:

Tests cover backup verification ordering and many archive format invariants, but
there is no functional retention test with two stale archives where the newest
must survive. Remote pruning has no mock rclone test for the same invariant.

Minimal remediation direction:

For each backup type, compute the newest archive by embedded timestamp first and
exclude it from deletion regardless of age. Apply the same rule to local cleanup,
dry-run output, and remote pruning. When timestamps are unparsable, keep the
current conservative "skip deletion" behavior.

Regression coverage recommendation:

Add a local retention test with two stale `.age` files and sidecars, asserting
the newest archive and its sidecars remain. Add a remote-prune mock test where
rclone lists two stale archives and assert the newest remote archive is not
deleted.

## Cross-Contract Pattern Analysis

The three findings share one pattern: a local helper encoded a safety or
discovery contract, but the next consumer collapsed a meaningful distinction.

- CT-01 collapses "skipped due to active operation" into "succeeded".
- CT-02 collapses "auto-discovered supported config" into "sensitive path
  refusal".
- CT-03 collapses "preserve the newest recovery point" into "delete every file
  over the age threshold after a pre-count check".

The repo has strong tests around individual helpers and recent PR #233 schema
closure, but fewer tests around whole producer-consumer paths: helper output
feeding a leaf wrapper, auto-discovery feeding a validator, and retention policy
feeding destructive cleanup loops.

## Checked and Coherent Contracts

- `AGENTS.md` production matrix is reflected in setup host checks: Ubuntu 24.04
  Noble, `amd64`/`arm64`, Docker official apt repo, Compose plugin, pinned SOPS,
  pinned Mike Farah `yq`, `zstd`, and PyYAML.
- `setup.sh` public phases and structured utilities align with root-operated
  lifecycle expectations.
- Runtime env generation keeps repo `.env` separate from root-owned
  `${PROJECT_STATE_DIR}/config/install.env` and `/etc/vaultwarden/vaultwarden.env`.
- `secrets-schema.yaml` closes the allowed apply types and validates Compose
  targets against `docker-compose.yml.example`.
- PR #233's CrowdSec Worker secret apply path is coherent: schema keys use
  `crowdsec_worker_config`, `secrets-rotate.sh` calls the dedicated apply helper,
  and `lib/crowdsec-worker.sh` renders/validates the bouncer config without
  treating the Worker service as a Compose service.
- Runtime Docker secret export is schema-driven and cleans inactive/stale managed
  files while preserving unknown operator files; tests cover SMTP sentinels,
  retired backup passphrase cleanup, and push placeholders.
- Compose secret names consumed by Vaultwarden, Caddy, and Postfix match runtime
  secret file names.
- Restore uses `startup.sh --skip-pull` after destructive restore instead of
  directly starting Compose, and it performs storage preflight, snapshots,
  rekey/rotation, permission repair, and manual-start safety checks.
- Separate-volume storage setup verifies mounts before writing state and systemd
  install appends data mount `ReadWritePaths` drop-ins instead of editing base
  units.
- Uninstall/test-reset coverage includes current timers, services, containers,
  networks, Docker subnets, CrowdSec artifacts, Cloudflare UFW cache behavior,
  and runtime cleanup.

## Regressed Historical Contracts

I did not run a full `git bisect` or historical replay, so I am not assigning
the findings to PR #233. The regressions are against current repository
contracts visible at the audited HEAD:

- CT-01 regresses the shared operation-guard exit 75 contract protected by
  `tests/test-operations.sh` and by existing systemd scheduled-job unit patterns.
- CT-02 regresses the rclone auto-discovery contract because a path returned by
  the shared resolver is rejected by the immediately following shared validator.
- CT-03 regresses the backup retention safety contract stated by the local and
  remote retention implementations themselves.

## Low-Confidence Investigation Items

None retained. Items that looked suspicious but were rejected as findings are
listed below.

## Not Findings / Accepted Differences

- The DNS/firewall systemd units lacking `SuccessExitStatus=75` is not, by
  itself, the root bug at HEAD because the leaf scripts currently mask exit 75.
  The root contract bug is the masking; the unit status should be fixed as part
  of remediation.
- systemd services running as root are accepted. The repo's current contract is
  root-operated lifecycle with least privilege enforced through sandboxing and
  root-owned secrets, not user-level services.
- Postfix not using `read_only: true` is accepted because tests and comments
  document the upstream image mutating `/scripts` at startup.
- Restore post-start health warnings do not make the restore fail after services
  start; this appears intentional so a successful data restore is not converted
  into a destructive rollback solely because health needs operator follow-up.
- Backup rclone sidecar partial upload returning 2 is accepted because scheduled
  backup units only mark 0 and 75 as success. A primary upload with missing
  sidecars should remain visible as a non-successful job.
- `.sops.yaml` staying generated/uncommitted is accepted; docs and setup
  contracts explain that it is deployment-specific.

## Suggested Remediation Order

1. Fix CT-03 first. It can delete the last recovery point and has the largest
   disaster-recovery blast radius.
2. Fix CT-01 next. It can silently hide skipped DNS/firewall maintenance and
   undermines the lock-status contract operators rely on.
3. Fix CT-02 after that. It blocks direct offsite backup/restore in a common
   root-operated rclone configuration, but has a manual workaround through
   explicit `RCLONE_CONFIG` or systemd install.

## Validation Performed

- Read current `AGENTS.md` before auditing and again after fast-forwarding
  `delta`.
- Established the required branch baseline with fetch, checkout, pull, status,
  branch, HEAD SHA, and recent log.
- Performed static line-level inspection across requested top-level scripts,
  libraries, structured utilities, systemd units/timers, Compose example, env
  example, secrets schema, docs, tests, and workflows.
- Checked exact producer/consumer evidence for each confirmed finding with
  path:line references.
- Verified the worktree was clean before creating this report.

Full tests, systemd execution, Docker Compose execution, live rclone operations,
SOPS decryption, backup creation, and restore drills were not run for this
report-only audit.

## Audit Limitations

- This was a static audit, not a runtime production simulation.
- No real Cloudflare, CrowdSec, rclone remote, email provider, Docker daemon, or
  systemd timer behavior was exercised.
- No secret material was decrypted.
- No historical bisect was performed, so findings are not attributed to a
  specific PR unless the current evidence directly names the contract.
- Some docs are generated from command/help surfaces; I inspected active docs for
  contract drift but did not regenerate docs.

## Final Verdict

Post-PR #233 `delta` is materially improved around secrets-schema closure, but
the repository still has three confirmed cross-subsystem contract bugs. The
highest-risk issue is backup retention pruning all stale recovery points. The
other two issues affect the operation-guard skip signal and direct rclone
offsite backup/restore usability.

No production code, tests, CI, generated docs, Makefile, AGENTS instructions, or
other repo files were changed by this audit. This report is the only intended
content change.
