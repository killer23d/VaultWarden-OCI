# Post-PR #226 Production Simplicity Audit

## Executive Summary

This is a report-only audit of the current `delta` branch after PR #226
(`a7aca1c Merge pull request #226 from killer23d/codex/fix-post-pr224-operation-contracts`).

The core post-PR #226 operation-guard architecture is now directionally coherent:
startup, backup, restore, maintenance, update, environment sync, secrets mutation,
systemd installation, health repair, permission repair, and uninstall generally use
the shared `flock` operation guard or a justified specific lock. I did not find a
new broad architecture problem that should displace the PR #224 / PR #226 guard work.

The remaining production-readiness risk is simpler and more operator-facing:

- The top-level Makefile root policy has drifted from the operator command API. A
  few documented Make targets now have no working privilege form.
- `dashboard.sh` exposes broken Make calls and status fields that can report green
  or healthy when the underlying check was not actually performed.
- The test inventory has already split: `make test-unit`, direct GitHub Actions
  calls, and uncalled permanent tests no longer describe one coherent regression
  contract.
- Several test filenames and doc entries still describe historical fix context or
  old target behavior rather than the permanent production contract.

Recommended direction: keep the architecture, reduce the command surface, fix the
root-policy drift, reduce the dashboard to a corrected operations dashboard, and
introduce one canonical Bash test runner that GitHub Actions and developer docs call.

## Audit Baseline

- Repository: `https://github.com/killer23d/VaultWarden-OCI`
- Branch audited: `delta`
- Audited HEAD: `a7aca1c` (`Merge pull request #226 ...`)
- Initial cloned status: `## delta...origin/delta`
- Scope: report only. No code, branch, commit, or PR changes were made.
- Prior architecture context used: `reports/post-pr224-repository-wide-contract-audit.md`
  and the PR #226 operation-guard fixes.

Inspection covered:

- `Makefile`, `dashboard.sh`, top-level dispatcher scripts, `utilities/*.sh`,
  `lib/*.sh`, `systemd/*.service`, `systemd/*.timer`.
- `README.md`, `RUNBOOK.md`, `docs/COMMAND-REFERENCE.md`,
  `docs/OPERATIONS.md`, `docs/CONFIGURATION.md`,
  `docs/TROUBLESHOOTING.md`, `docs/SCRIPTS.md`.
- All 30 shell tests under `tests/`.
- `.github/workflows/doc-drift.yml`.

## Findings

### F-01 - Operator Make targets for secrets and email have no working privilege form

- Severity: Medium
- Confidence: High
- Area: operator workflow, Makefile surface
- Exact files: `Makefile`, `utilities/secrets-list.sh`,
  `utilities/secrets-edit.sh`, `utilities/maintenance-email.sh`,
  `RUNBOOK.md`, `docs/SCRIPTS.md`, `docs/SECURITY.md`,
  `docs/CONFIGURATION.md`, `docs/COMMAND-REFERENCE.md`
- Exact targets: `edit-secrets`, `test-secrets`, `test-email`, `health-email`

Current behavior:

- `Makefile:270-285` exposes `edit-secrets`, `test-secrets`, and `test-email`
  without `$(call require-root)`.
- The scripts they call require root:
  `utilities/secrets-list.sh:45`, `utilities/secrets-edit.sh:43-60`, and
  `utilities/maintenance-email.sh:227`.
- `ROOT_ALLOWED_TARGETS` in `Makefile:76-86` does not include
  `edit-secrets`, `test-secrets`, `test-email`, or `health-email`.
- Therefore non-root `make edit-secrets`, `make test-secrets`, and
  `make test-email` reach a root-required script and fail; `sudo make ...`
  is rejected by the Makefile root guard before the target runs.
- Documentation advertises these targets as operator commands:
  `RUNBOOK.md:60`, `RUNBOOK.md:155`, `docs/SCRIPTS.md:523`,
  `docs/SCRIPTS.md:681`, `docs/SCRIPTS.md:784-786`,
  `docs/SCRIPTS.md:796`, `docs/SECURITY.md:1003`,
  `docs/CONFIGURATION.md:215`, `docs/COMMAND-REFERENCE.md:23-25`.
- `Makefile:259` also tells the operator to use `make edit-secrets` after
  secrets already exist.

Concrete problem:

Supported production workflows for secret editing, secret decryption validation,
and email diagnostics can fail whichever obvious Make form the operator tries.
This is exactly the kind of junior-operator breakage the root target guard is
supposed to prevent.

Why it matters for this project:

Secret editing and email verification are normal small-team production tasks.
The direct script forms still exist, but the top-level Makefile is intended to be
the supported operator/admin command API.

Minimal fix direction:

- Decide whether these are supported Make API targets. If yes, add
  `$(call require-root)` to each root-required target and include the target names
  in `ROOT_ALLOWED_TARGETS`.
- Add or remove `health-email` intentionally from `.PHONY` and root policy.
- If the project prefers direct script use for secrets/email, remove or hide the
  Make targets and update all docs, `make help`, and `docs/COMMAND-REFERENCE.md`.

Focused regression recommendation:

- Add a Make/root-policy test that extracts every operator target that invokes a
  root-required script and asserts one of:
  `require-root + ROOT_ALLOWED_TARGETS`, or explicit documentation as a normal-user
  target.
- Extend `tests/test-privilege-contracts.sh`; it already verifies the scripts
  require root but does not verify their Make wrappers have a valid root policy.

### F-02 - Root-run dashboard actions call Make targets rejected by the Makefile root policy

- Severity: Medium
- Confidence: High
- Area: dashboard, operator workflow, Makefile surface
- Exact files: `dashboard.sh`, `Makefile`, `RUNBOOK.md`,
  `docs/OPERATIONS.md`, `docs/TROUBLESHOOTING.md`, `docs/SCRIPTS.md`
- Exact menu items:
  main `d` Full Diagnostic Dump, advanced `5` Systemd Timer Status,
  advanced `6` Prune Docker Resources, identity `1` Test SMTP Delivery in
  direct-root launch mode

Current behavior:

- `dashboard.sh` requires root at startup (`dashboard.sh:1025-1030`).
- The dashboard then calls:
  - `make diagnose` through `run_cmd` (`dashboard.sh:647-648`).
  - `make systemd-status` through `run_cmd` (`dashboard.sh:921-922`).
  - `make prune` through `run_cmd` after its confirmation
    (`dashboard.sh:924-928`).
  - `make test-email` through `run_user_cmd` (`dashboard.sh:979-980`).
- `ROOT_ALLOWED_TARGETS` does not include `diagnose`, `systemd-status`,
  `prune`, or `test-email` (`Makefile:76-86`).
- In the normal `sudo ./dashboard.sh` case, `run_user_cmd` drops
  `test-email` to `SUDO_USER`; that then hits F-01 because the underlying email
  diagnostic requires root. In a direct root shell with no `SUDO_USER`, it is
  rejected by the Makefile root guard.
- The same command drift appears in docs:
  `RUNBOOK.md:63`, `RUNBOOK.md:193`, `RUNBOOK.md:202`,
  `docs/OPERATIONS.md:399`, `docs/TROUBLESHOOTING.md:440`,
  `docs/SCRIPTS.md:826-839`.

Concrete problem:

The dashboard displays these as live operator actions, but the Makefile rejects
them before useful work happens. This is a broken operator surface, not just a
cosmetic label issue.

Why it matters for this project:

The dashboard is explicitly for a junior Linux operator. Broken dashboard actions
send the operator into a failure path during diagnostics and cleanup, exactly when
the interface should be reducing cognitive load.

Minimal fix direction:

- Either make these Make targets root-compatible where that is the supported
  operator API (`diagnose`, `systemd-status`, `prune`, `test-email`) or change
  dashboard actions to call the canonical direct script/command with the correct
  helper.
- Add `diagnose`, `systemd-status`, and `prune` to root policy only if they are
  intentionally safe under root.
- For email, prefer `run_sudo_cmd "sudo ./maintenance.sh test-email --verbose"`
  or fix `make test-email` per F-01.

Focused regression recommendation:

- Add a dashboard static contract test that enumerates every `make -C
  "${REPO_ROOT}" TARGET` action from `dashboard.sh` and checks it against
  `ROOT_ALLOWED_TARGETS` / `ROOT_NEUTRAL_TARGETS` based on the helper used.
- The test should fail if a root-only dashboard action points to a target rejected
  by the root policy.

### F-03 - Dashboard status fields can report green health when the check was absent or incomplete

- Severity: Medium
- Confidence: High
- Area: dashboard, operator workflow
- Exact file: `dashboard.sh`
- Exact status fields: `Secrets health`, `Last backup`, `Last result`,
  `Rclone`, `Email Queue`, `Recent Auth Fails (1h)`

Current behavior:

- `Secrets health` only scans `.env` for `CHANGE_ME` / `CHANGEME`
  (`dashboard.sh:316-344`) and prints `All secrets configured`. It does not check
  `SECRETS_FILE`, SOPS decryptability, the Age key, or runtime secret sync.
- `Last backup` selects an archive with `find ... | sort | tail -1`
  (`dashboard.sh:509-521`), while `Last result` selects by newest mtime across
  typed backup directories (`dashboard.sh:373-408`, `dashboard.sh:523-528`).
  Adjacent fields can therefore refer to different archives.
- `Rclone` prints `Ready` if the binary exists and `RCLONE_REMOTE_NAME` is set
  (`dashboard.sh:411-446`), while explicitly not probing connectivity
  (`dashboard.sh:419-421`).
- `Email Queue` initializes `queue_count=0`; if Docker is unavailable or the
  Postfix container is not running, it never changes and prints `Healthy`
  (`dashboard.sh:547-562`).
- `Recent Auth Fails (1h)` initializes `auth_fails=0`; if Docker is unavailable
  or neither app nor Caddy container is listed, it prints green `0`
  (`dashboard.sh:564-583`).

Concrete problem:

Several status lines conflate "not checked", "not running", or "configured but
not validated" with healthy/pass/ready wording. These are actionable operational
signals, not decorative labels.

Why it matters for this project:

For a mostly set-and-forget 10-user deployment, the dashboard is likely the first
place a junior operator looks. False green status can cause the operator to skip
the exact next command they should run: `sudo make key-health`, an actual rclone
sync/probe, `docker compose ps`, or log inspection.

Minimal fix direction:

- Change status vocabulary:
  - `Secrets health`: `Env placeholders clear; run sudo make key-health` unless
    decryption is actually checked.
  - `Rclone`: `Configured (not probed)` instead of `Ready`.
  - `Email Queue`: `Unknown - postfix not running` or `Unknown - Docker
    unavailable`, not `Healthy`.
  - `Recent Auth Fails`: `Unknown - logs unavailable`, not green `0`.
- Use one archive-selection helper for both `Last backup` and `Last result`.
  Prefer mtime or parsed backup timestamp consistently.

Focused regression recommendation:

- Add a focused dashboard status test with mocked `docker`, `systemctl`, `find`,
  and `.env` cases:
  - Docker unavailable must not produce green email/auth status.
  - Postfix absent must not produce `Email Queue: Healthy`.
  - A placeholder-free `.env` alone must not imply SOPS/Age health.
  - `Last backup` and `Last result` must be derived from the same archive path.

### F-04 - The permanent test inventory has already drifted across Makefile and GitHub Actions

- Severity: Medium
- Confidence: High
- Area: tests structure, test runner, GitHub Actions
- Exact files: `Makefile`, `.github/workflows/doc-drift.yml`, `tests/*.sh`
- Exact targets/jobs: `test-unit`, `functional-tests / Run focused tests`

Current behavior:

- There are 30 shell tests under `tests/`.
- `make test-unit` runs 19 scripts (`Makefile:879-898`).
- GitHub Actions runs `make test-unit` and then directly runs
  `tests/test-crowdsec-config.sh` (`.github/workflows/doc-drift.yml:189-192`).
- No canonical `tests/run-tests.sh` exists.
- The following tests are not reached by `make test-unit`:
  - `tests/test-config-systemd-followup.sh`
  - `tests/test-crowdsec-config.sh`
  - `tests/test-email-refactor.sh`
  - `tests/test-health-operation-contract.sh`
  - `tests/test-maintenance-email-root.sh`
  - `tests/test-post-pr224-operation-contracts.sh`
  - `tests/test-restore-confirmation-safety.sh`
  - `tests/test-secrets-env-systemd-guards.sh`
  - `tests/test-setup-secrets-transaction.sh`
  - `tests/test-startup-lifecycle-guards.sh`
  - `tests/test-systemd-operation-runtime-paths.sh`
- The PR #226 commit touched several permanent operation-contract tests that are
  not in the Make aggregate: `test-health-operation-contract.sh`,
  `test-post-pr224-operation-contracts.sh`,
  `test-restore-confirmation-safety.sh`,
  `test-secrets-env-systemd-guards.sh`,
  `test-startup-lifecycle-guards.sh`, and
  `test-systemd-operation-runtime-paths.sh`.

Concrete problem:

A developer can add a permanent regression test and still miss CI unless they
also remember to edit the Makefile or workflow YAML. This has already happened:
several permanent-looking post-PR #226 contract tests have no aggregate caller.

Why it matters for this project:

The project is intentionally shell-based and small. That is fine, but the test
inventory must have one owner. Manually synchronizing `Makefile`, workflow YAML,
and ad hoc test lists is already producing omissions.

Minimal fix direction:

- Add `tests/run-tests.sh` as the canonical Bash runner.
- Make it the only owner of the permanent default inventory.
- Prefer an explicit ordered list over discovery because several tests use
  temporary repo `.env` mutation with cleanup, platform-aware skips, mocked
  tools, and Linux-only behavior.
- Change GitHub Actions to call `./tests/run-tests.sh all` or a small number of
  stable suites. Do not duplicate individual script names in workflow YAML.
- Remove or demote `make test-unit` from the top-level Makefile. If kept for one
  release as a compatibility alias, it should call the runner, not own a second
  inventory.

Focused regression recommendation:

- Add a runner self-check mode that reports each intended permanent test exactly
  once.
- Add a workflow/doc drift check that fails when GitHub Actions references a
  removed Make test target or an individual `tests/test-*.sh` that should be
  owned by the runner.

### F-05 - The GitHub Actions workflow contains a dead default-branch autofix job

- Severity: Low
- Confidence: High
- Area: GitHub Actions
- Exact file: `.github/workflows/doc-drift.yml`
- Exact job: `shellcheck-autofix`

Current behavior:

- The workflow trigger is only `pull_request` (`.github/workflows/doc-drift.yml:1-15`).
- The `shellcheck-autofix` job claims to run only on pushes to `main`
  (`.github/workflows/doc-drift.yml:194-199`).
- Because the workflow has no `push` trigger, that job is unreachable.

Concrete problem:

CI exposes a job that cannot run. This is stale operator/developer surface in the
repository automation and can confuse maintainers reviewing check coverage or
permissions.

Why it matters for this project:

The requested direction is simpler maintenance, fewer stale entry points, and CI
coherence. A dead write-permission job is extra surface with no benefit.

Minimal fix direction:

- Delete the job, or add an intentional `push` trigger if auto-fix-on-main is
  genuinely desired. Given the project's simplicity goals, deletion is the
  lower-complexity default.

Focused regression recommendation:

- Add a CI lint check that flags jobs whose `if:` condition references an event
  that is not present in the workflow trigger list.

### F-06 - `docs/SCRIPTS.md` still describes old Make target behavior

- Severity: Low
- Confidence: High
- Area: documentation, Makefile surface
- Exact files: `docs/SCRIPTS.md`, `Makefile`
- Exact doc rows: `docs/SCRIPTS.md:832-845`

Current behavior:

`docs/SCRIPTS.md` describes several Make targets inaccurately:

- `make test` is documented as `test-secrets` + `test-email` + Compose config
  (`docs/SCRIPTS.md:832`), but the target runs `test-unit`, `test-secrets`, and
  `test-config` (`Makefile:872-877`).
- `make dry-run` is documented as "All scripts with --dry-run"
  (`docs/SCRIPTS.md:834`), but the target only runs `./startup.sh --dry-run`
  (`Makefile:905-907`).
- `make clean` is documented as Docker cleanup (`docs/SCRIPTS.md:835`), but the
  target only removes `setup.log` (`Makefile:1001-1004`).
- `make clean-all` is documented as Compose volume removal and Docker prune
  (`docs/SCRIPTS.md:836`), but the target only removes `setup.log` after a
  prompt (`Makefile:1010-1020`).
- `make fmt` is documented as Compose/secrets validation (`docs/SCRIPTS.md:845`),
  but the target only prints a Makefile-formatting note (`Makefile:909-910`).

Concrete problem:

This documentation advertises stale or stronger behavior than the Makefile
performs. It is especially confusing while deciding which developer/test targets
should remain in the top-level Makefile.

Why it matters for this project:

A junior operator or maintainer should not need to reconcile the Makefile,
generated command reference, and hand-maintained script docs to know which
command is safe or supported.

Minimal fix direction:

- Update or remove the stale rows as part of the same PR that introduces the
  canonical test runner and Makefile surface cleanup.
- Prefer generated `docs/COMMAND-REFERENCE.md` for exact target descriptions.
- Keep `docs/SCRIPTS.md` focused on script dispatchers and supported operator
  workflows, not stale developer/test aliases.

Focused regression recommendation:

- Extend doc drift checks beyond target existence. For known high-risk command
  rows, assert the documented implementation string matches the current target
  body or remove implementation claims from the table.

## Production Operator Journey Matrix

Legend:

- Guard: global = shared operation guard; specific = narrower duplicate lock;
  read-only = no mutation expected; none = no operation guard expected.
- Contention: prompt = interactive conflict prompt; skip75 = non-interactive
  skip with exit 75; fail = hard failure; N/A = not mutating.

| Journey | Documented command | Make target | Dashboard entry | Dispatcher / implementation | Privilege | Mode | Guard expectation | Contention | Audit result |
|---|---|---:|---|---|---|---|---|---|---|
| Fresh installation | `sudo ./setup.sh install --domain ... --email ...`; `sudo make setup` only after `.env` prepared | `setup` | none | `setup.sh` -> setup utilities | root | mutating | global setup | prompt/skip | Coherent; `make setup` is not a complete no-env bootstrap and docs mostly show direct setup. |
| First startup | `sudo make up` | `up` / `start` | main `1` uses restart, not first-start | `startup.sh` | root | mutating | global + startup specific | prompt/skip75 for systemd | Coherent; dashboard chooses restart rather than first-start. |
| Normal reboot/systemd startup | systemd `vaultwarden-startup.service` | N/A | status only | `startup.sh --skip-pull` | root/systemd | mutating | global + startup specific | skip75 | Coherent after PR #226. |
| Manual start | `sudo make up` | `up` / `start` | no dedicated start | `startup.sh` | root | mutating | global + startup specific | prompt | Coherent. |
| Stop | `sudo make down` | `down` / `stop` | main `2` | `startup.sh stop` | root | mutating | global + startup specific | prompt | Coherent. |
| Restart | `sudo make restart` | `restart` | main `1` | `startup.sh --force` | root | mutating | global + startup specific | prompt | Coherent. |
| Safe restart | `sudo make safe-restart` | `safe-restart` | none | `utilities/safe-restart.sh` | root | mutating | global startup | prompt | Coherent; not exposed in dashboard. |
| Health inspection | `sudo make health`, `health-quick`, `health-report` | yes | main `3` | `utilities/maintenance-health.sh` | root | read-only unless fix | health specific / global only with fix | skip75 for repair | Coherent. |
| Troubleshoot failed stack | `sudo make diagnose`, logs, operations | `diagnose`, logs, operations | main `d`, logs | Make + Docker/systemctl/logs | root expected | read-only | read-only | N/A | `diagnose` is rejected under root policy; dashboard action broken (F-02). |
| Database backup | `sudo make backup` | `backup`, `db-backup` | backup `1` | `backup.sh run db` -> `utilities/backup-run.sh` | root | mutating | global backup | prompt/skip75 under systemd | Coherent. |
| Full backup | `sudo make backup-full` | `backup-full` | backup `2` | `backup.sh run full` | root | mutating | global backup | prompt/skip75 | Coherent. |
| Emergency backup | `sudo make backup-emergency` | `backup-emergency` | none | `backup.sh run emergency` | root | mutating | global backup | prompt | Coherent; dashboard omission acceptable. |
| Offsite backup sync | `sudo ./backup.sh sync`; dashboard options 5-7 | no Make target | backup `5-7` | `backup.sh run db --rclone`, `backup.sh sync` | root | mutating/network | global backup/sync | prompt | Coherent, but dashboard `Rclone: Ready` wording is too strong (F-03). |
| Database-only restore | `sudo make restore-db` | `restore-db` | via interactive restore only | `restore.sh latest db` | root | destructive | global restore | prompt | Coherent. |
| Full restore | `sudo make restore` | `restore` | backup `3` | `restore.sh interactive` | root | destructive | global restore | prompt | Coherent. |
| Emergency restore | `sudo ./restore.sh interactive` / emergency selection | no dedicated Make | backup `3` | `utilities/restore-run.sh` | root | destructive | global restore | prompt | Coherent. |
| Mounted-state disaster recovery | `sudo ./recover.sh --state-dir ... --key ...` | none | none | `recover.sh` | root | mutating | none; standalone DR bootstrap | N/A | Coherent as isolated DR path. |
| Age key rotation | `sudo make key-rotate` | `key-rotate` | none | `utilities/key-rotate.sh` | root | mutating | global + key/secrets | prompt | Coherent. |
| Secret editing/rotation | `sudo ./utilities/secrets-edit.sh`; docs also show `make edit-secrets` | `edit-secrets` broken | secrets `2` direct sudo script | `edit-secrets.sh` / utilities | root | mutating | global + secrets specific | prompt/skip | Direct dashboard script path works; Make path broken (F-01). |
| Environment editing/sync | `sudo make edit-env`, `sudo make sync-env` | yes | none | `utilities/env-edit.sh` | root | mutating | global + env specific | skip75 non-interactive | Coherent. |
| Routine maintenance | `sudo make maintenance` | `maintenance` | none | `maintenance.sh run` | root | mutating | global maintenance | skip75 systemd | Coherent. |
| Database maintenance | `sudo make db-maint` | `db-maint` | advanced `3` | `maintenance.sh db-maint` | root | mutating/stop | global db-maint | skip75 non-interactive | Coherent. |
| Container image update | `sudo make update` | `update` | advanced `2` | `maintenance.sh update --all` | root | mutating | global update | prompt/skip | Coherent. |
| Systemd install/status/removal | `sudo make install-systemd`, `remove-systemd`, `systemd-status` | install/remove OK; status root-policy drift | advanced `5` status | `setup.sh systemd ...` / Make status loop | root for install/remove; status read-only | mutating/read-only | global systemd for install/remove | prompt/skip | Dashboard status broken by root policy (F-02). |
| CrowdSec inspection and IP unban | `sudo make crowdsec-status`, `sudo make unban IP=...` | yes | security `1-5` | Make or direct `cscli` | root | read-only/mutating unban | none | N/A | Coherent; direct dashboard cscli commands bypass Make but are clear. |
| Permission repair | `sudo make fix-permissions` | `fix-permissions` | advanced `4` | `utilities/repair-permissions.sh` | root | mutating | global + permission specific | prompt | Coherent. |
| Uninstall | `sudo make uninstall`; dry run | yes | advanced `7` | `utilities/uninstall-vaultwarden.sh` | root live; dry-run non-root OK | destructive | global uninstall | prompt | Coherent. |

## Top-Level Makefile Scope Audit

Desired principle: the top-level Makefile should primarily be the supported
operator/admin command API.

### Developer/Test Target Classification

| Target | Classification | Keep in top-level Makefile? | Reason | Replacement / change |
|---|---|---:|---|---|
| `test` | C - developer/CI only | No | Owns a second aggregate and currently calls broken root-required `test-secrets` without root. | `./tests/run-tests.sh all`; update PR validation docs. |
| `test-unit` | C - developer/CI only | No, or one-release hidden alias | Owns stale 19-test inventory and omits permanent tests. | `./tests/run-tests.sh all`. |
| `test-config` | B - advanced admin validation | Yes | Useful before startup or after Compose edits; operator-safe if Docker is available. | Move under diagnostics/admin, not Developer/Test. |
| `dry-run` | B - advanced admin safety command | Yes, but rename/describe truthfully | It only previews startup, not all operations. | Description: "Preview startup.sh only"; or `startup-dry-run`. |
| `fmt` | D - obsolete/no-op | No | Only prints "No auto-formatter"; not useful operator/admin API. | Remove; document no formatter if needed. |
| `lint` | C - developer/CI only | No | Shellcheck is already directly in CI; target silently succeeds when shellcheck is missing. | `shellcheck -x --severity=warning ...` in CI; optional `./tests/run-tests.sh lint` if desired. |
| `shellcheck` | C - developer/CI only | No | Alias to `lint`; no operator value. | Same as `lint`. |

### Minimal Resulting Makefile Surface

Keep normal/advanced operator targets:

- Setup/config: `setup`, `sync-env`, `edit-env`, `init-secrets`,
  `edit-secrets` if fixed per F-01.
- Lifecycle/status: `up`, `start`, `down`, `stop`, `restart`,
  `safe-restart`, `status`, `operations`, `logs*`.
- Health/diagnostics: `health`, `health-quick`, `health-report`,
  `test-secrets` if fixed per F-01, `test-email` / `health-email` if fixed,
  `test-config`, `diagnose`.
- Backup/restore: `backup`, `backup-full`, `backup-emergency`,
  `list-backups`, `backup-status`, `restore`, `restore-preflight`,
  `restore-db`, `restore-remote`.
- Secrets/key/admin: `key-health`, `key-install`, `key-backup`,
  `key-escrow`, `key-rotate`, `key-path`, `key-show`, breakglass targets.
- Maintenance/security/systemd: `update`, `update-system`, `update-dns`,
  `maintenance`, `maintenance-full`, `db-maint`, `db-backup`,
  `install-systemd`, `remove-systemd`, `systemd-status`, `timers`,
  `schedule`, `unban`, CrowdSec/security report targets.
- Cleanup/destructive: `fix-permissions`, `prune`, `uninstall`,
  `uninstall-dry-run`.

Remove from operator Makefile or keep only as non-advertised compatibility
aliases to the canonical runner:

- `test`, `test-unit`, `fmt`, `lint`, `shellcheck`, `docs` if docs generation is
  developer-only, and `dev-setup`.

### Root Policy and List Coherence

The Makefile currently has several manually synchronized surfaces:

- `.PHONY` (`Makefile:45-64`)
- `ROOT_ALLOWED_TARGETS` (`Makefile:76-86`)
- `ROOT_NEUTRAL_TARGETS` (`Makefile:88`)
- `make help` hand-written menu (`Makefile:147-183`)
- `make help-all` generated from target comments (`Makefile:186-200`)
- Dashboard compatibility note (`Makefile:140-145`)
- Dashboard hard-coded Make calls

Concrete drift already exists:

- Root-required script wrappers missing root policy: F-01.
- Dashboard Make calls missing root policy: F-02.
- `health-email` exists as an alias (`Makefile:367`) but is absent from
  `.PHONY`, `ROOT_ALLOWED_TARGETS`, and `ROOT_NEUTRAL_TARGETS`.
- `diagnose`, `systemd-status`, and `prune` are documented/dashboard operator
  actions but are not root-allowed.

Minimal list fix:

- Treat root-policy membership as part of each supported target contract.
- Add a test that compares dashboard Make calls, docs-advertised root examples,
  and targets invoking root-required scripts against `ROOT_ALLOWED_TARGETS`.
- Keep `help` smaller than `help-all`, but do not let `help` advertise commands
  whose privilege form is invalid.

## Complete Test-Suite Structure Audit

### Test Domain Matrix

| Test | Primary permanent contract/domain | Production files tested | Type | Temp/mocks/portability | Current caller |
|---|---|---|---|---|---|
| `test-architecture-helpers.sh` | architecture/helper selection | `setup-system.sh`, `setup-crowdsec.sh` | mocked/static helper behavior | no temp | `make test-unit` |
| `test-security-helpers.sh` | security helper contracts | `lib/secrets.sh`, `lib/backup-utils.sh`, Compose | mocked/static | temp; mocked config | `make test-unit` |
| `test-secrets-cli-help.sh` | secrets CLI help and old Bash behavior | secrets utilities | live help/static | temp isolated root; macOS Bash caveat | `make test-unit` |
| `test-privilege-contracts.sh` | root/privilege/operator contracts | Makefile, scripts, dashboard | static + optional live non-root | temp; Linux root optional | `make test-unit` |
| `test-permission-repair-contract.sh` | permission repair contract | repair, runtime permissions, setup/restore/secrets | static | temp | `make test-unit` |
| `test-permission-contract-central.sh` | central permission expectations | health, config, common/log | mocked behavior | temp | `make test-unit` |
| `test-env-edit.sh` | env edit/sync contract | env-edit, setup-env, systemd, migrate | mocked behavior | temp | `make test-unit` |
| `test-migrate-followup.sh` | storage migration contract | `lib/migrate.sh`, storage/setup-storage | mocked behavior | temp | `make test-unit` |
| `test-operator-ui.sh` | operator prompt/output contracts | common/log, backup, db-maint, setup-secrets | static + mocked behavior | temp; mocked docker/sqlite3 | `make test-unit` |
| `test-recover.sh` | mounted-state disaster recovery | `recover.sh`, startup, Compose | mocked behavior | temp; test mode | `make test-unit` |
| `test-restore-run-followup.sh` | restore key/rekey follow-up regressions | restore-run, startup | mocked behavior | temp | `make test-unit` |
| `test-restore-backup-preflight-safety.sh` | restore/backup preflight safety | restore-run, backup-run, backup-utils | static + bash -n | temp | `make test-unit` |
| `test-backup-architecture-policy.sh` | backup architecture/data policy | backup-run, restore-run, docs | static | no temp | `make test-unit` |
| `test-backup-restore-behavior.sh` | backup/restore behavior and start policy | restore-run, setup-systemd, migrate, timers | mocked behavior | temp; mocked age/docker/sqlite3 | `make test-unit` |
| `test-confirmation-prompt-format.sh` | global confirmation prompt format | maintenance-db-maint, repo scan | static scan | no temp; uses rg/grep | `make test-unit` |
| `test-operation-guards.sh` | core operation lock behavior | operations lib, systemd services, backup/restore | static + Linux behavior | temp; Linux `/proc`/flock skips | `make test-unit` |
| `test-start-policy.sh` | restore/migrate/systemd start policy | restore-run, migrate, setup-systemd, timers | static | no temp | `make test-unit` |
| `test-uninstall-vaultwarden.sh` | uninstall dry-run/path contract | uninstall utility, systemd names | mocked/dry-run | temp; writes/restores repo `.env` | `make test-unit` |
| `test-setup-storage-ux.sh` | storage setup UX safety | setup-storage, storage lib, setup | static | no temp | `make test-unit` |
| `test-crowdsec-config.sh` | CrowdSec config/parser/bouncer contract | setup-crowdsec, Compose, docs, acquis | static | no temp | direct GitHub Actions only |
| `test-config-systemd-followup.sh` | config loader/systemd follow-up contracts | config, crypto, setup-systemd, notify | mocked behavior | temp; writes/restores repo `.env` | none |
| `test-email-refactor.sh` | email route helper refactor | email lib | mocked behavior | temp; mocked curl | none |
| `test-health-operation-contract.sh` | health operation/systemd contract | maintenance-health, health service | static | no temp | none |
| `test-maintenance-email-root.sh` | email diagnostic root help | maintenance dispatcher/email utility | static | no temp | none |
| `test-post-pr224-operation-contracts.sh` | operation lock permanent contracts | operations lib, setup-system | static + Linux behavior | temp; Linux skips | none |
| `test-restore-confirmation-safety.sh` | restore destructive confirmation | restore-run | static | no temp | none |
| `test-secrets-env-systemd-guards.sh` | secrets/env/systemd guard contracts | secrets/env/systemd utilities, iptables unit | static + help smoke | temp; Bash 4 skip | none |
| `test-setup-secrets-transaction.sh` | setup-secrets transaction rollback | setup-secrets, secrets lib | mocked behavior | temp; mocked sops | none |
| `test-startup-lifecycle-guards.sh` | startup/safe-restart lifecycle guards | startup, safe-restart, Makefile, startup unit | static | no temp | none |
| `test-systemd-operation-runtime-paths.sh` | systemd runtime paths for operation state | operations lib, guarded services | static | no temp | none |

### Required Caller Map

| Test | Makefile caller | Workflow caller | Runner caller | Direct repository caller |
|---|---|---|---|---|
| `test-architecture-helpers.sh` | `test-unit` | via `make test-unit` | none | none |
| `test-backup-architecture-policy.sh` | `test-unit` | via `make test-unit` | none | reports only |
| `test-backup-restore-behavior.sh` | `test-unit` | via `make test-unit` | none | reports/AGENTS only |
| `test-config-systemd-followup.sh` | none | none | none | none |
| `test-confirmation-prompt-format.sh` | `test-unit` | via `make test-unit` | none | reports only |
| `test-crowdsec-config.sh` | none | direct workflow | none | AGENTS/reports only |
| `test-email-refactor.sh` | none | none | none | none |
| `test-env-edit.sh` | `test-unit` | via `make test-unit` | none | reports only |
| `test-health-operation-contract.sh` | none | none | none | none |
| `test-maintenance-email-root.sh` | none | none | none | none |
| `test-migrate-followup.sh` | `test-unit` | via `make test-unit` | none | none |
| `test-operation-guards.sh` | `test-unit` | via `make test-unit` | none | AGENTS/reports only |
| `test-operator-ui.sh` | `test-unit` | via `make test-unit` | none | AGENTS/reports only |
| `test-permission-contract-central.sh` | `test-unit` | via `make test-unit` | none | reports only |
| `test-permission-repair-contract.sh` | `test-unit` | via `make test-unit` | none | reports only |
| `test-post-pr224-operation-contracts.sh` | none | none | none | none |
| `test-privilege-contracts.sh` | `test-unit` | via `make test-unit` | none | AGENTS/reports only |
| `test-recover.sh` | `test-unit` | via `make test-unit` | none | reports only |
| `test-restore-backup-preflight-safety.sh` | `test-unit` | via `make test-unit` | none | reports only |
| `test-restore-confirmation-safety.sh` | none | none | none | none |
| `test-restore-run-followup.sh` | `test-unit` | via `make test-unit` | none | reports only |
| `test-secrets-cli-help.sh` | `test-unit` | via `make test-unit` | none | reports only |
| `test-secrets-env-systemd-guards.sh` | none | none | none | none |
| `test-security-helpers.sh` | `test-unit` | via `make test-unit` | none | none |
| `test-setup-secrets-transaction.sh` | none | none | none | reports only |
| `test-setup-storage-ux.sh` | `test-unit` | via `make test-unit` | none | reports only |
| `test-start-policy.sh` | `test-unit` | via `make test-unit` | none | AGENTS/reports only |
| `test-startup-lifecycle-guards.sh` | none | none | none | none |
| `test-systemd-operation-runtime-paths.sh` | none | none | none | none |
| `test-uninstall-vaultwarden.sh` | `test-unit` | via `make test-unit` | none | reports only |

### Consolidation and Naming Recommendations

Operation and lifecycle contracts:

- Merge or rename `test-post-pr224-operation-contracts.sh`. Its content is now a
  permanent operation-lock contract, not a PR-history test. Best options:
  - fold it into `test-operation-guards.sh`, or
  - rename to `test-operation-lock-contracts.sh`.
- Keep `test-startup-lifecycle-guards.sh` separate from the core operations
  library suite. It validates startup/safe-restart/systemd entry-point contracts.
- Keep `test-secrets-env-systemd-guards.sh` separate or rename to
  `test-secrets-env-systemd-operation-contracts.sh`; it spans three production
  entry-point families and should be callable as a contract suite.
- Add all of the above to the canonical runner.

Backup, restore, and recovery:

- Keep `test-recover.sh` as a recovery suite; it has a large mocked DR harness.
- Consolidate restore follow-up/safety naming:
  - `test-restore-run-followup.sh` -> `test-restore-key-contracts.sh` or merge
    into a focused `test-restore-contracts.sh`.
  - `test-restore-confirmation-safety.sh` can merge into the restore contract
    suite if the assertion remains easy to locate.
  - Keep `test-restore-backup-preflight-safety.sh` separate if preflight failure
    diagnosis would get buried.
- Do not combine all backup, restore, and recovery tests into one file.

Operator UI:

- `test-confirmation-prompt-format.sh` belongs naturally in the permanent
  operator UI contract. Merge it into `test-operator-ui.sh` only if failure output
  remains clear.
- Add a separate `test-dashboard-contract.sh` or extend `test-operator-ui.sh`
  with dashboard-specific static/mocked checks. The current operator UI test does
  not cover dashboard menu command resolution or false-green status behavior.

Permissions:

- Keep `test-permission-repair-contract.sh` and
  `test-permission-contract-central.sh` separate. One validates the repair utility
  and runtime permission application; the other validates central expected-owner
  contracts.

Setup/configuration/storage/migration:

- Rename historical names:
  - `test-config-systemd-followup.sh` -> `test-config-systemd-contracts.sh`
  - `test-migrate-followup.sh` -> `test-storage-migration-contracts.sh`
- Keep `test-setup-secrets-transaction.sh` separate because it has a detailed
  SOPS transaction harness.
- Keep `test-setup-storage-ux.sh` separate; it is a focused static UX/safety
  contract.

Rename map requiring atomic caller updates:

| Old name | New name | Callers to update |
|---|---|---|
| `tests/test-post-pr224-operation-contracts.sh` | `tests/test-operation-lock-contracts.sh` or merge into `test-operation-guards.sh` | new runner; any PR docs; reports/AGENTS if maintained |
| `tests/test-migrate-followup.sh` | `tests/test-storage-migration-contracts.sh` | `Makefile:test-unit` if retained; new runner; workflow through runner |
| `tests/test-restore-run-followup.sh` | `tests/test-restore-key-contracts.sh` or merge into `test-restore-contracts.sh` | `Makefile:test-unit` if retained; new runner; workflow through runner |
| `tests/test-config-systemd-followup.sh` | `tests/test-config-systemd-contracts.sh` | new runner |

Do not perform any rename without updating tests, Makefile, workflows, and docs
in the same PR.

## Canonical Test Runner Audit

Current authoritative command question:

There is no single authoritative command meaning "run all permanent
non-destructive regression tests expected for CI."

Current commands:

- `make test`: runs `test-unit`, `test-secrets`, and `test-config`. It is not a
  safe CI contract because `test-secrets` requires root via its utility but the
  target is not root-compatible.
- `make test-unit`: owns a stale 19-test explicit list.
- `.github/workflows/doc-drift.yml`: runs `make test-unit` and one direct test.
- Several permanent tests have no aggregate caller.

Recommended runner:

```bash
./tests/run-tests.sh all
./tests/run-tests.sh contracts
./tests/run-tests.sh backup-restore
./tests/run-tests.sh operator-ui
```

Keep suite selectors only if CI or local diagnosis uses them. A simple first pass
can support only `all` plus a few stable domains.

Inventory ownership:

- Prefer an explicit ordered list in `tests/run-tests.sh`.
- Reason: the suite contains Linux-only `/proc`/`flock` behavior, Bash-version
  skips, mocked tools, tests that temporarily write repo `.env` with cleanup, and
  tests that should report explicit SKIP rather than silently pass.
- The runner should print `PASS`, `FAIL`, or `SKIP` distinctly and propagate
  non-zero failure status.

Suggested default order:

1. Architecture/security helper tests.
2. Secrets CLI/help and privilege/root-policy tests.
3. Permission tests.
4. Config/env/systemd/setup/storage/migration tests.
5. Operation/lifecycle/health/start-policy tests.
6. Backup/restore/recovery tests.
7. Operator UI/dashboard tests.
8. CrowdSec/security integration static tests.
9. Uninstall tests.

## GitHub Actions and CI Contract Audit

### Workflow Inventory

Only one workflow exists: `.github/workflows/doc-drift.yml`.

Trigger and permissions:

- Trigger: `pull_request` with path filters for docs, utilities, libs, shell
  scripts, Makefile, systemd, tests, secrets schema, env/compose examples, and
  `.gitignore`.
- Global permissions: `contents: read`.
- `shellcheck-autofix` requests `contents: write` at job level but is unreachable
  because the workflow has no `push` trigger (F-05).

### CI Execution Matrix

| Workflow | Trigger | Job | Command | Tests/contracts reached | Environment assumptions |
|---|---|---|---|---|---|
| Doc Drift Check | PR path filters | `doc-drift` | install pinned `yq` via curl + sha256 + sudo install | Tooling for command reference generation | Ubuntu, network, sudo, sha256sum |
| Doc Drift Check | PR path filters | `doc-drift` | stale-term grep | Specific stale docs terms only | GNU grep/sed/bash |
| Doc Drift Check | PR path filters | `doc-drift` | Makefile target existence scan | Verifies docs mention existing targets only | Does not validate privilege or behavior |
| Doc Drift Check | PR path filters | `doc-drift` | script flag existence scan | Fixed flag list for backup/update/setup/uninstall | Static grep only |
| Doc Drift Check | PR path filters | `doc-drift` | unpinned version grep | Version pin policy | Static grep only |
| Doc Drift Check | PR path filters | `doc-drift` | systemd hardening grep | Unit hardening directives | Static grep only |
| Doc Drift Check | PR path filters | `doc-drift` | `bash utilities/write-command-reference.sh` + diff | Generated command reference freshness | Ubuntu, `yq` v4.53.3, no Docker needed due env |
| Doc Drift Check | PR path filters | `shellcheck` | `find . -type f -name '*.sh' | xargs shellcheck -x --severity=warning` | All shell scripts static shellcheck | Ubuntu, shellcheck installed on runner image |
| Doc Drift Check | PR path filters | `functional-tests` | install age, apache2-utils, python3-argon2, pinned yq, pinned sops | Test dependencies | Ubuntu, sudo, network |
| Doc Drift Check | PR path filters | `functional-tests` | `make test-unit` | 19 Make-listed tests | Bash, sops/age/yq installed, Linux where needed |
| Doc Drift Check | PR path filters | `functional-tests` | `tests/test-crowdsec-config.sh` | CrowdSec static contract | Bash/grep only |
| Doc Drift Check | no effective trigger | `shellcheck-autofix` | shellcheck diff + git apply + auto-commit | None in practice | Dead job unless push trigger added |

### Migration Map

| Old CI command/test | New suite/test | Coverage preserved? | Notes |
|---|---|---:|---|
| `make test-unit` | `./tests/run-tests.sh all` | Yes, if runner includes the 19 current scripts | Preserve order initially. |
| `tests/test-crowdsec-config.sh` | included in `./tests/run-tests.sh all` or `./tests/run-tests.sh security` | Yes | No special CI environment required; static test. |
| Uncalled PR #226 operation tests | included in `./tests/run-tests.sh contracts` and `all` | Yes | Add exact scripts before deleting `make test-unit`. |
| Shellcheck job | unchanged direct shellcheck | Yes | Do not route shellcheck through Make unless runner has a clear `lint` mode. |
| Doc drift generation | unchanged | Yes | Keep workflow trigger/permissions unchanged except deleting dead autofix job. |

Workflow names/job names:

- Preserve workflow and job names unless required-check settings are reviewed.
- Changing `functional-tests` command from `make test-unit` to
  `./tests/run-tests.sh all` should not require a job rename.

## Dashboard Audit

Recommendation: **B - keep with focused corrections and simplification**, with a
strong bias toward making it mostly read-only except for a few high-value,
root-correct actions.

Do not remove it yet. The dashboard gives useful scan value for a junior
operator, but it should stop exposing stale/broken Make actions and should use
truthful status labels.

### Visible Menu Command Matrix

| Menu | Key | Label | Command reached | Helper | Privilege/mode | Works from root dashboard? | Notes |
|---|---|---|---|---|---|---:|---|
| Main | `1` | Start/Restart Stack | `make restart` | `run_sudo_cmd` | root mutating | Yes | Root-allowed. |
| Main | `2` | Stop Stack | `make down` | `run_sudo_cmd` | root mutating | Yes | Confirmation present. |
| Main | `3` | Quick Health Check | `make health` | `run_sudo_cmd` | root read/repair | Yes | Label says quick but command is full `health`, not `health-quick`; minor label drift. |
| Main | `4` | View App Logs | `docker logs vaultwarden_app` | direct | read-only | Yes | Bypasses Make; acceptable. |
| Main | `d` | Full Diagnostic Dump | `make diagnose` | `run_cmd` | root/read-only | No | Rejected by root policy (F-02). |
| Backup | `1` | Incremental DB Backup | `backup.sh run db` | `run_sudo_cmd` | root mutating | Yes | Guarded by backup script. |
| Backup | `2` | Full System Backup | `backup.sh run full` | `run_sudo_cmd` | root mutating | Yes | Guarded. |
| Backup | `3` | Interactive Restore | `restore.sh interactive` | `run_sudo_cmd` | root destructive | Yes | Guarded; utility confirmation. |
| Backup | `4` | Backup Status / Health | `make backup-status` | `run_sudo_cmd` | root read-only | Yes | Root-allowed. |
| Backup | `5` | Sync Latest Backup | `backup.sh run db --rclone` | `run_sudo_cmd` | root mutating/network | Yes | Label says latest backup, command creates/syncs new DB backup. Rename label. |
| Backup | `6` | Full Verify + Sync | `backup.sh run db --full-verification --rclone` | `run_sudo_cmd` | root mutating/network | Yes | DB-only despite "Full Verify" wording. |
| Backup | `7` | Copy All Local Backups | `backup.sh sync` | `run_sudo_cmd` | root mutating/network | Yes | Coherent. |
| Security | `1` | View Active Bans | `sudo cscli decisions list` | direct | root read-only | Yes | Coherent. |
| Security | `2` | Unban an IP | `sudo cscli decisions delete` | direct | root mutating | Yes | Validates IPv4 only. |
| Security | `3` | View Security Report | `make security-report` | `run_cmd` | root read-only | Yes | Root-allowed. |
| Security | `4` | Tail CrowdSec Logs | `make logs-crowdsec` | `run_cmd` | root read-only | Yes | Root-allowed, but `run_cmd` label lacks sudo. |
| Security | `5` | CrowdSec Metrics | `cscli metrics` | `run_sudo_cmd` | root read-only | Yes | Coherent. |
| Secrets | `1` | Key Health Check | `make key-health` | `run_cmd` | root read-only | Yes | Root-allowed, label lacks sudo. |
| Secrets | `2` | Edit Secrets | `utilities/secrets-edit.sh` | `run_sudo_cmd` | root mutating | Yes | Correct direct path; bypasses broken Make target. |
| Secrets | `3` | Generate Escrow Backup | `make key-escrow` | `run_cmd` | root mutating | Yes | Root-allowed. |
| Secrets | `4` | Breakglass Admin Status | `make breakglass-status` | `run_cmd` | root read-only | Yes | Root-allowed. |
| Advanced | `1` | Export Recovery Kit | `secrets-export-recovery-kit.sh` | `run_user_cmd` | likely secret-bearing | Maybe | Needs explicit privilege review; exporting secrets as normal user may be intentional but should be tested. |
| Advanced | `2` | Update Stack Images | `make update` | `run_cmd` | root mutating | Yes | Root-allowed. |
| Advanced | `3` | Database Maintenance | `make db-maint` | `run_cmd` | root mutating | Yes | Root-allowed. |
| Advanced | `4` | Fix File Permissions | `make fix-permissions` | `run_cmd` | root mutating | Yes | Root-allowed. |
| Advanced | `5` | Systemd Timer Status | `make systemd-status` | `run_cmd` | read-only | No | Rejected by root policy (F-02). |
| Advanced | `6` | Prune Docker Resources | `make prune` | `run_cmd` | destructive-ish cleanup | No | Rejected by root policy after dashboard confirmation (F-02). |
| Advanced | `7` | Uninstall | `make uninstall` | `run_cmd` | root destructive | Yes | Confirmation present and target root-allowed. |
| Identity | `1` | Test SMTP Delivery | `make test-email` | `run_user_cmd` | root-required diagnostic | No | Fails as normal user, root-rejected if no `SUDO_USER` (F-01/F-02). |
| Identity | `2` | Tail Auth & Access Drops | `docker logs caddy | grep ...` | direct | read-only | Yes | Empty output is not explained. |
| Identity | `3` | Rotate Vault Admin Token | `secrets-rotate.sh admin_token` | `run_cmd` | root mutating | Yes when root | Direct script requires root; dashboard is root. |
| Identity | `4` | View Breakglass Status | `make breakglass-status` | `run_cmd` | root read-only | Yes | Duplicate of Secrets `4`. |

Dashboard simplification:

- Keep read-only live stats only if their labels are truthful.
- Keep high-value actions: restart, stop, health, logs, backup, restore,
  operations, key health, edit secrets, update, db-maint, permission repair,
  uninstall.
- Remove or hide duplicate/less reliable actions until they have tests:
  duplicate breakglass status, direct auth grep, possibly recovery-kit export
  from dashboard.
- Do not add a TUI framework.

## Command and Entry-Point Coherence

Concrete drift found:

- Make root policy vs operator targets: F-01 and F-02.
- Dashboard labels:
  - Main `3` says Quick Health Check but runs `make health`.
  - Backup `5` says sync latest backup but creates a new DB backup with rclone.
  - Backup `6` says full verify + sync but runs DB backup verification/sync.
- `docs/SCRIPTS.md` stale Make rows: F-06.
- Direct docs under `README.md` and `docs/OPERATIONS.md` generally use the
  correct `sudo make ...` production form.
- `RUNBOOK.md` is more mixed and frequently omits `sudo` for root-required Make
  targets. Most of those targets at least print a clear sudo hint, but the
  F-01/F-02 targets have no valid Make form and need correction.

No concrete stale removed script entry point was found among:

- `setup.sh`, `startup.sh`, `backup.sh`, `restore.sh`, `recover.sh`,
  `maintenance.sh`, `edit-secrets.sh`.
- `systemd/*.service` and `systemd/*.timer`.

## Truthful Status and Success Semantics

Reportable status wording issues are in F-03.

Other inspected success/skip semantics:

- Backup run summary distinguishes local backup, verification, and offsite sync.
  Existing `tests/test-operator-ui.sh` covers the backup summary branch.
- Database maintenance success messages are inside the health success branch.
  Existing `tests/test-operator-ui.sh` covers that regression.
- Operation contention skip uses exit 75 and explicit warnings in the shared
  operation library; systemd units generally document and accept 75 where
  expected.
- Platform skips in `test-post-pr224-operation-contracts.sh` and
  `test-secrets-env-systemd-guards.sh` print `PASS`/`SKIP`-style messages
  explicitly enough for local output, but the canonical runner should preserve
  SKIP as distinct from PASS.

## Test Coverage Gap Audit

Recommended focused tests:

1. Make root-policy wrapper test:
   - Every target that invokes a root-required script must be root-allowed and
     call `require-root`, or be explicitly classified as normal-user.
   - This catches `edit-secrets`, `test-secrets`, `test-email`, and future drift.

2. Dashboard command resolution test:
   - Parse `dashboard.sh` visible Make actions.
   - Assert root dashboard actions are compatible with `ROOT_ALLOWED_TARGETS` /
     `ROOT_NEUTRAL_TARGETS`.
   - Assert helper classification (`run_cmd`, `run_sudo_cmd`, `run_user_cmd`) is
     intentional for each menu entry.

3. Dashboard status truthfulness test:
   - Docker unavailable / Postfix stopped must not display green email queue.
   - Docker unavailable / app logs unavailable must not display green auth `0`.
   - Placeholder-free `.env` must not be called full secrets health.
   - Last backup timestamp and last result must use the same selected archive.

4. Canonical runner self-test:
   - The runner executes every intended permanent test exactly once.
   - Suite failures propagate non-zero.
   - Linux-only unsupported cases produce visible SKIP.

5. Workflow drift test:
   - Workflow commands do not reference removed Make test targets.
   - Workflow commands do not list individual permanent tests when the runner
     owns the inventory.
   - Workflow `if:` event predicates are reachable from declared triggers.

## Final Recommendation

Production-readiness posture after PR #226:

- Core guarded architecture: acceptable for the stated small-team project.
- Operator command surface: not yet production-polished because several Make and
  dashboard commands are broken under the current root policy.
- Dashboard: keep, but correct it and make status wording less ambitious.
- Tests/CI: introduce a canonical shell runner before more permanent regression
  tests are added.
- Makefile: remove developer/test clutter from the top-level operator API except
  for genuinely useful admin diagnostics (`test-config`, startup dry-run), and
  ensure every retained operator target has a valid privilege form.

The final cleanup PR should be atomic across:

- `tests/` and `tests/run-tests.sh`
- `Makefile`
- `.github/workflows/doc-drift.yml`
- dashboard command/status tests
- affected docs and generated `docs/COMMAND-REFERENCE.md`

---

## Third-Pass Validation Addendum

Date: 2026-07-05

This is a closure pass over the same post-PR #226 `delta` state. It re-validates
the original findings and checks only adjacent operator/maintenance contracts:
Make privilege forms, dashboard truthfulness, recovery exit semantics, test
inventory, CI callers, and operator docs. It does **not** reopen the shared
`flock` architecture or recommend enterprise tooling.

### Third-Pass Verdict

F-01 through F-06 remain valid. F-01/F-02/F-03 are broader than originally
reported, and the original journey matrix overstates fresh-install and recovery
coherence.

**READY AFTER FOCUSED FIXES — one bounded atomic simplification PR remains the
recommended path. No new architecture phase is warranted.**

### Validation of Original Findings

| Finding | Verdict | Third-pass adjustment |
|---|---|---|
| F-01 Make privilege drift | **VALID** | Expand to `key-path` and `key-show`; decide whether both key-status targets are useful. |
| F-02 broken dashboard actions | **VALID** | Recovery-kit export is confirmed broken; after email/export fixes, `run_user_cmd` may have no valid caller. |
| F-03 false-green / over-strong dashboard status | **VALID** | Expand to timer unknown state, `mailq` failure, broad auth heuristic, restart labelled `safe`, and backup/status labels. |
| F-04 test inventory drift | **VALID** | Add a definitive disposition for all 30 tests; `test-email-refactor.sh` is also historical naming and has a hard `rg` dependency. |
| F-05 dead workflow autofix job | **VALID** | Delete the job; do not build a generic workflow semantic linter for one workflow. |
| F-06 stale `docs/SCRIPTS.md` rows | **VALID** | RUNBOOK root/ordering drift is higher priority and deserves a Medium finding. |

## Additional High-Confidence Findings

### TP-01 - CI path filters miss workflow, README, and RUNBOOK changes

- Severity: Medium
- Confidence: High
- Exact file: `.github/workflows/doc-drift.yml`

The PR path filter omits `.github/workflows/**`, `README.md`, and `RUNBOOK.md`.
The job nevertheless scans `README.md`, while `RUNBOOK.md` is not included in
the stale-term or Make-target scans. A workflow-only or README-only PR can bypass
checks that claim to cover those surfaces, and RUNBOOK command drift is invisible.

Minimal fix: add the three paths and include `RUNBOOK.md` in the existing docs
scans. Preserve workflow/job names and permissions. Delete the dead autofix job.
Do not add reusable workflows or a generic YAML/workflow linter.

### TP-02 - Fresh-install RUNBOOK orders secret rotation before secrets exist

- Severity: Medium
- Confidence: High
- Exact files: `RUNBOOK.md`, `edit-secrets.sh`, `setup.sh`

RUNBOOK tells a first-time operator to run Cloudflare `edit-secrets.sh rotate`
commands before the full setup step. `edit-secrets.sh` requires root and refuses
operational subcommands until `SECRETS_FILE` exists. Full setup creates env in
phase 3 and bootstraps encrypted secrets in phase 4; `setup.sh` itself prints the
Cloudflare rotation commands only after bootstrap.

Minimal fix: document setup/bootstrap first, then `sudo ./edit-secrets.sh rotate
...`, then CrowdSec setup, then root-operated start/health verification. Reuse
`setup.sh`'s existing sequence; do not add another setup orchestrator.

### TP-03 - Dashboard recovery-kit export is definitely broken from normal launch

- Severity: Medium
- Confidence: High
- Exact files: `dashboard.sh`, `utilities/secrets-export-recovery-kit.sh`

The dashboard requires root and documents `sudo ./dashboard.sh`. Its
`run_user_cmd` drops to `SUDO_USER`, and recovery-kit export is routed through
that helper. The export utility explicitly requires root. Normal sudo dashboard
launch therefore drops privileges and the visible export action fails.

Minimal fix: execute recovery-kit export in the root context. Email diagnostic is
also root-operated. After those actions are corrected, delete `run_user_cmd` if
it has no legitimate caller. Do not add an execution-policy registry.

### TP-04 - `key-path` and `key-show` have no truthful production privilege form

- Severity: Medium
- Confidence: High
- Exact files: `Makefile`, `lib/crypto.sh`, command docs

`key-path` resolves only readable keys. The canonical production key is
`/etc/vaultwarden/age-key.txt`, root-owned `0600` under a root-owned directory.
`key-path` is not root-allowed, so non-root can fail to resolve the real key while
`sudo make key-path` is rejected. `key-show` can similarly report `MISSING` to a
normal user and is also rejected under sudo.

Minimal fix: keep `key-health` authoritative. Prefer removing redundant
`key-path` and retaining at most one root-correct lightweight `key-show` for
path/public-recipient status. Keep decryptability claims in `key-health`.

### TP-05 - `recover.sh` returns zero after failed post-recovery health

- Severity: Medium
- Confidence: High
- Exact files: `recover.sh`, `tests/test-recover.sh`

On `/alive` failure, recovery prints `Health check: FAIL`, says not to treat the
service as healthy, and prints next steps. The branch ends with successful
`echo`s, so `run_startup_health` returns zero and the script exits successfully.
The existing recovery test explicitly preserves this zero-exit behavior.

Minimal fix: return non-zero for failed post-recovery health while preserving
successfully promoted recovery artifacts. Do **not** simply add `return 1`: the
current EXIT cleanup rolls promoted artifacts back on non-zero. Add one small
committed-artifacts state after promotion/env update, exclude committed state
from rollback, then return non-zero on health failure. Update the test to require
non-zero plus preserved ciphertext/key/policy/manifest and the current next-step
text.

### TP-06 - `systemd-status` duplicates canonical status and mislabels unit states

- Severity: Medium
- Confidence: High
- Exact files: `Makefile`, `utilities/setup-systemd.sh`

The Make target owns a smaller hard-coded unit list and does `systemctl status ...
|| echo "unit: not found"`. `systemctl status` is non-zero for inactive/failed as
well as missing units, so installed failed units can be reported as `not found`.
The loop also omits startup and managed service units. `setup-systemd.sh` already
owns the canonical timer/service/startup arrays and status action.

Minimal fix: route `make systemd-status` to the existing root-operated systemd
status action and delete the duplicate Make loop. Do not build another unit
registry.

### TP-07 - `make unban` masks all `cscli` delete errors as harmless success

- Severity: Medium
- Confidence: High
- Exact files: `Makefile`, `dashboard.sh`

`make unban` uses `cscli ... && success || "not found/may have expired"`. The
fallback echo succeeds, so permission/LAPI/database/command errors become exit 0
and benign not-found wording. The dashboard separately duplicates unban and only
validates IPv4.

Minimal fix: preserve generic `cscli` failure as non-zero and print its failure
output. Use not-found wording only when positively identified. Route dashboard
unban through the corrected canonical target and let `cscli` validate supported
IP forms; do not build a custom IPv4/IPv6 parser.

### TP-08 - Backup/status labels claim health or incrementality not performed

- Severity: Medium
- Confidence: High
- Exact files: `Makefile`, `dashboard.sh`, `utilities/backup-run.sh`, `lib/backup-utils.sh`

DB backup mode is an encrypted standalone SQLite snapshot, but Make/dashboard
call it `incremental`. `backup-status` is described as a health summary but only
calls `backup.sh list`; the list path inventories type/file/size/age/metadata and
does not verify/decrypt. Main `status` likewise says backup health while showing
inventory/age. Dashboard `Sync Latest Backup` creates a new DB backup and syncs
it, and `Full Verify + Sync` fully verifies a new **DB** backup, not a full-system
backup.

Minimal fix: rename rather than add work: `DB snapshot backup`, `Backup
Inventory`, `Create + Sync New DB Backup`, and `Create + Fully Verify + Sync DB
Backup`. Keep decrypt/integrity checks in `backup.sh verify` or comprehensive
health; do not make dashboard refresh perform live decrypts.

### TP-09 - `make status` can print `Active bans: 0` when `cscli` failed

- Severity: Medium
- Confidence: High
- Exact file: `Makefile`

The active-CrowdSec path counts a `cscli | tail | wc -l` pipeline with stderr
discarded. The recipe shell has no `pipefail`; failed `cscli` can still leave the
last pipeline command successful with zero. `0` is a successful query result, not
an unknown query state.

Minimal fix: capture `cscli` output and status before counting. Print a numeric
count only on query success; otherwise print `unknown (cscli query failed)`.
Do not add a status cache or monitoring backend.

### TP-10 - `key-backup` says offline while creating another local file

- Severity: Medium
- Confidence: High
- Exact files: `Makefile`, `RUNBOOK.md`, command docs

The target says it backs up the Age key offline, but copies it to
`$HOME/age-key-backup-<timestamp>.txt` on the same host and only then tells the
operator to store it offline. This is a local transfer copy, not completed
offline custody.

Minimal fix: remove the target in favor of the recovery-kit/offline-recipient
flow, or rename it to `Create local Age key copy for manual offline transfer` and
end with a prominent `NOT OFFLINE YET` warning. Do not add USB detection or
removable-media automation.

### TP-11 - Dashboard status/safety wording still overstates several probes

- Severity: Medium
- Confidence: High
- Exact files: `dashboard.sh`, `Makefile`

- Main `Start/Restart Stack (safe)` executes ordinary `make restart`; the repo has
  a distinct `safe-restart` rollback workflow.
- Timers says `(systemd not available)` whenever no VaultWarden timer lines are
  returned; absent units and query failure are different states.
- Email Queue calls zero `Healthy`; even a successful empty queue proves only
  `0 queued`, not end-to-end mail health. A failed `mailq` must also be Unknown.
- Recent Auth Fails greps broad `invalid|fail` text from app/Caddy logs, which is
  not a reliable authentication-failure classifier.

Minimal fix: remove `(safe)` or route to `safe-restart`; use no-timers/Unknown
states; show `0 queued`/`N queued`/Unknown; remove the auth counter or rename it to
a generic failure-match count. For this small project, removal is preferable to
building a log-classification parser.

### TP-12 - `backup.sh --help` loads project environment before help/version parsing

- Severity: Low
- Confidence: High
- Exact files: `utilities/backup-run.sh`, `backup.sh`, generated command reference

`backup-run.sh` calls `load_project_environment || exit 1` before parsing help or
version. The generated command reference therefore records backup help as
unavailable/requiring environment. Harmless information requests should not need
production state.

Minimal fix: parse help/version first, then load project environment only for
operational subcommands; regenerate command reference.

## Corrected Journey Classifications

| Journey | Original result | Third-pass result |
|---|---|---|
| Fresh installation | Coherent | **Broken docs order** — secret rotation precedes secrets bootstrap and omits sudo. |
| Mounted-state recovery | Coherent | **Misleading exit status** — failed health returns success. |
| Troubleshoot failed stack | Broken via `diagnose` | **Wider status drift** — duplicate systemd status and false-zero CrowdSec count. |
| CrowdSec unban | Coherent | **Broken failure semantics** — generic delete errors become benign success. |
| Database backup | Coherent | **Implementation coherent; label misleading** — snapshot, not incremental. |
| Backup status | Coherent | **Inventory only, not health**. |
| Key inspection | Not separately flagged | **Privilege form broken/redundant**. |

All other original journey conclusions remain unchanged.

## Definitive 30-Test Disposition Map

| Current test | Action / final destination |
|---|---|
| `test-architecture-helpers.sh` | KEEP |
| `test-security-helpers.sh` | KEEP |
| `test-secrets-cli-help.sh` | KEEP; add backup help/version assertions if convenient |
| `test-privilege-contracts.sh` | KEEP + EXTEND for Make/key/dashboard privilege contracts |
| `test-permission-repair-contract.sh` | KEEP |
| `test-permission-contract-central.sh` | KEEP |
| `test-env-edit.sh` | KEEP |
| `test-migrate-followup.sh` | RENAME -> `test-storage-migration-contracts.sh` |
| `test-operator-ui.sh` | KEEP; MERGE confirmation-prompt format assertions |
| `test-recover.sh` | KEEP + UPDATE health-failure exit/artifact assertions |
| `test-restore-run-followup.sh` | MERGE/RENAME -> `test-restore-contracts.sh` |
| `test-restore-backup-preflight-safety.sh` | KEEP |
| `test-backup-architecture-policy.sh` | KEEP |
| `test-backup-restore-behavior.sh` | KEEP |
| `test-confirmation-prompt-format.sh` | MERGE -> `test-operator-ui.sh` |
| `test-operation-guards.sh` | KEEP |
| `test-start-policy.sh` | KEEP |
| `test-uninstall-vaultwarden.sh` | KEEP |
| `test-setup-storage-ux.sh` | KEEP |
| `test-crowdsec-config.sh` | KEEP; canonical runner owns it, not workflow YAML |
| `test-config-systemd-followup.sh` | RENAME -> `test-config-systemd-contracts.sh` |
| `test-email-refactor.sh` | RENAME -> `test-email-contracts.sh`; add `rg` -> `grep` fallback |
| `test-health-operation-contract.sh` | KEEP |
| `test-maintenance-email-root.sh` | MERGE -> `test-email-contracts.sh` |
| `test-post-pr224-operation-contracts.sh` | RENAME -> `test-operation-lock-contracts.sh` |
| `test-restore-confirmation-safety.sh` | MERGE -> `test-restore-contracts.sh` |
| `test-secrets-env-systemd-guards.sh` | RENAME -> `test-secrets-env-systemd-operation-contracts.sh` |
| `test-setup-secrets-transaction.sh` | KEEP |
| `test-startup-lifecycle-guards.sh` | KEEP |
| `test-systemd-operation-runtime-paths.sh` | MERGE -> `test-operation-lock-contracts.sh` |

`test-email-refactor.sh` now protects permanent routing/fallback/TLS/attachment,
header-injection, rate-limit, secret-resolution, and trap contracts; `refactor`
is historical naming. Its hard `rg` call should use the existing prompt-format
test's `rg`-then-`grep` fallback pattern before the new runner makes it a normal
local/CI test.

### Canonical runner recommendation

Start with exactly one supported invocation:

```bash
./tests/run-tests.sh all
```

Use one explicit ordered inventory. The runner should preserve child output,
print concise RUN/PASS/FAIL wrappers, propagate non-zero failures, and compare the
explicit list against `tests/test-*.sh` so an unlisted or duplicate permanent
test fails immediately. Individual tests keep their own visible SKIP messages;
do not invent a new skip protocol merely for the runner.

Keep strict ShellCheck as its existing direct workflow job.

Do **not** initially add domain selectors, metadata/YAML/JSON manifests, a test
registration API, Bats/pytest solely for organization, or a second tests Makefile.
Add a suite selector only when CI or a real debugging workflow has an actual
caller for it.

## Corrected GitHub Actions Migration

1. Add `.github/workflows/**`, `README.md`, and `RUNBOOK.md` to PR path filters.
2. Include `RUNBOOK.md` in stale-term and Make-target reference scans.
3. Change `functional-tests` from `make test-unit` plus direct CrowdSec execution
   to:

   ```bash
   ./tests/run-tests.sh all
   ```

4. Keep the direct strict ShellCheck job unchanged.
5. Delete `shellcheck-autofix`; do not add a push trigger to preserve a dead
   auto-write job.
6. Preserve workflow/job names, read permission, and PR trigger model apart from
   path-filter expansion.
7. Do not list individual permanent tests in workflow YAML once the runner owns
   inventory.

No reusable workflow, composite action, generated matrix, or CI framework is
needed.

## Corrected Final Production Fix Scope

### Must fix before production

1. Valid privilege forms for retained operator targets, including the F-01/F-02
   targets and `key-path`/`key-show` decision.
2. Broken dashboard diagnostics, systemd status, prune, email, and recovery-kit
   actions.
3. Failed post-recovery health returns non-zero without rolling back committed
   recovery artifacts.
4. Preserve real `cscli` unban/query failures; no benign success or false ban zero.
5. Correct RUNBOOK sudo forms and fresh-install bootstrap/secret-rotation order.
6. Add `tests/run-tests.sh all` as the single permanent regression inventory and
   migrate GitHub Actions atomically, including path-filter coverage.
7. Correct dashboard unknown/false-health semantics and make last backup/result
   use the same selected archive.

### Worth fixing in the same simplification PR

- Delete `run_user_cmd` if unused after root-correct dashboard actions.
- Correct ordinary restart `(safe)` wording and backup/inventory/create+sync labels.
- Rename/merge historical tests per the disposition map; remove hard `rg` from
  the newly canonical email contract test.
- Make backup help/version side-effect-free and regenerate command reference.
- Correct `key-backup` offline-custody wording or remove the redundant target.
- Remove `test`, `test-unit`, `fmt`, `lint`, and `shellcheck` from the operator
  Makefile after callers migrate; retain/reclassify only real admin diagnostics.
- Delete duplicate status loops/dead helpers rather than keeping compatibility
  layers without a real caller.

### Leave alone

- PR #224/#226 shared `flock` operation-guard architecture.
- The replacement-VM standalone DR model for `recover.sh`; no recovery daemon,
  state machine, or second lock framework.
- Docker Compose/systemd/SOPS/Age architecture.
- Bash tests and large focused restore/recovery harnesses where merging hurts
  diagnosis.
- Existing workflow/job names and direct strict ShellCheck job.

## Third-Pass Final Recommendation

**READY AFTER FOCUSED FIXES — one bounded atomic simplification PR recommended.**

The third pass found no reason for an enterprise redesign or another broad lock
audit. Remaining work is concrete integration cleanup: valid privilege forms,
truthful exit/status/labels, correct first-run docs, one regression inventory
owner, and CI that runs when those contracts change.

Implementation bias:

> route to an existing canonical path, rename an over-strong label, preserve a
> real error, or delete a duplicate surface before adding any new abstraction.


---

## Fourth-Pass Challenge Addendum

Date: 2026-07-05

This pass deliberately challenged the report rather than extending its original
checklist. The method was:

1. try to disprove or downgrade F-01 through F-06 and TP-01 through TP-12;
2. trace the primary new-user deployment guide that README designates as the
   golden path;
3. trace the existing `smoke-test` and `drill` commands because they explicitly
   claim pre-production/go-live confidence;
4. re-read recovery rollback and signal paths around TP-05; and
5. compare human-readable success with process exit status for backup and
   systemd automation validation.

The scope remains intentionally small-team and shell-native. No new framework,
daemon, registry, state database, policy engine, TUI framework, or CI platform is
recommended.

### Fourth-Pass Verdict

The fourth pass **increases confidence in the architectural conclusion** but
**reduces confidence in the current production-readiness conclusion** until the
bounded final PR is complete.

The shared PR #224/#226 operation-guard design still does not need replacement.
However, four existing confidence mechanisms are less trustworthy than the third
pass reported:

- `recover.sh` rollback/signal handling is not one complete transaction;
- `smoke-test.sh` can declare production readiness with required checks skipped
  and probes the wrong Vaultwarden readiness path;
- `pre-production-drill.sh` can pass with unrehearsed restore paths and does not
  execute the restart sequence its help claims to validate; and
- quick backup verification and systemd timer validation can detect meaningful
  failure but still return process success.

**NOT READY for production at the current audited commit. One bounded atomic fix
PR is still sufficient; multiple architecture phases are not justified.**

This is a stricter verdict than the third pass only because the fourth pass found
false-success conditions in recovery/validation paths that are themselves used to
decide whether the host is ready.

## Fourth-Pass Revalidation of Earlier Findings

| Earlier item | Fourth-pass result | Adjustment |
|---|---|---|
| F-01 / F-02 Make and dashboard privilege drift | **VALID** | No downgrade. `make setup` adds another broken advertised Make entry point. |
| F-03 dashboard truthfulness | **VALID** | No downgrade. The same false-ready pattern also exists in pre-production validators. |
| F-04 canonical test inventory | **VALID** | Strengthened: smoke/drill/recovery transaction semantics need focused tests before joining the single runner. |
| F-05 dead workflow job | **VALID** | No change; delete rather than expand CI. |
| F-06 / TP-02 docs drift | **VALID** | Strengthened because README's designated `docs/DEPLOYMENT.md` golden path was not in the original inspected-doc list and contains current root/path drift. |
| TP-05 recovery health exit | **VALID BUT INCOMPLETE** | The implementation direction must account for incomplete rollback and signal traps before changing the health exit. |
| TP-08 backup wording | **VALID BUT INCOMPLETE** | Quick-verification failure also returns zero, so this is process-status truthfulness, not only labels. |
| TP-12 backup help side effect | **VALID LOW** | Remains cleanup/QoL; do not let it distract from the findings below. |

## Additional High-Confidence Findings

### TP-13 - Advertised `sudo make setup` cannot perform the first-time setup it claims

- Severity: Medium
- Confidence: High
- Exact files: `Makefile`, `setup.sh`, generated/help documentation

Current behavior:

- The Makefile usage banner advertises `sudo make setup` as first-time
  installation.
- The `setup` target refuses to run until `.env` already exists, then invokes
  `./setup.sh` without `install`, `--domain`, or `--email`.
- `setup.sh` initializes `DOMAIN` and `ADMIN_EMAIL` to empty and explicitly exits
  when a full-setup invocation lacks either value.

Therefore the advertised Make entry point is internally contradictory: a true
first install has no generated `.env`, while a prepared `.env` still does not
supply the required setup CLI values because `setup.sh` does not read them into
its setup parser.

Minimal fix direction:

- Prefer one golden path: `sudo ./setup.sh install --domain ... --email ...`.
- Remove `setup` from the advertised operator Make API and usage banner unless a
  real external caller requires it.
- If compatibility requires retaining the target, make it a clearly hidden alias
  with an explicit `DOMAIN=` / `EMAIL=` contract and pass those arguments to
  `setup.sh install`; do not add another setup configuration layer.

Focused regression test:

- Assert every advertised first-install command reaches the full setup parser with
  a valid way to provide domain and email.

### TP-14 - Recovery rollback and signal handling do not cover one complete recovery transaction

- Severity: High
- Confidence: High
- Exact files: `recover.sh`, `tests/test-recover.sh`
- Extends: TP-05

Current behavior:

- `recover.sh` installs `cleanup` directly for `EXIT`, `INT`, and `TERM`.
- `cleanup` returns `0`; it does not exit `130`/`143` for signals.
- With this Bash trap shape, a signal handler can run cleanup and execution can
  continue after the interrupted command. The fourth-pass shell reproduction of
  the same trap shape observed `TERM -> cleanup -> next statement -> exit 0`.
- Recovery backs up/restores ciphertext, active key, SOPS policy, and manifest.
- It does **not** back up or restore `install.env`.
- `update_env_files` mutates `install.env` one key at a time and may also create
  `.vw-data-volume`.
- Any later non-zero path, including a non-zero `startup.sh`, triggers cleanup
  rollback of promoted secrets/key/policy/manifest but leaves already-written
  `install.env` values and the created sentinel outside that rollback.

Concrete failure scenario:

Recovery promotes a new key/ciphertext/policy, updates part or all of
`install.env`, then startup fails or the process receives TERM. Cleanup can restore
the old cryptographic artifacts while leaving runtime env pointed at the new key
path/storage values, or can run cleanup on a signal and allow the script to
continue into later phases with staging/workdir state already removed.

Minimal fix direction:

- Back up `install.env` before mutation and record whether `.vw-data-volume`
  existed before recovery.
- Include both in rollback until the recovery transaction reaches a single
  explicit committed state.
- Replace direct `INT`/`TERM` cleanup traps with handlers that perform rollback/
  cleanup and exit `130`/`143`.
- Define one small `RECOVERY_COMMITTED=true` boundary only after ciphertext, key,
  policy, manifest, and install env are promoted and validated together.
- After that boundary, startup or `/alive` failure must return non-zero **without
  rolling back committed recovery artifacts** and must preserve the existing
  operator next-step text.

This is a few state booleans and backups inside `recover.sh`; it is not a recovery
state machine or new transaction framework.

Focused regression tests:

- TERM/INT after staging must exit with the signal status and must not continue to
  the next phase.
- Inject failure after the first `atomic_set_env`; old `install.env`, manifest,
  cryptographic artifacts, and sentinel state must be restored.
- Inject startup failure after the commit boundary; return non-zero and preserve
  the new committed artifacts.
- Keep TP-05's failed `/alive` case non-zero with committed artifacts preserved.

### TP-15 - The production smoke test can return ready with required checks skipped and probes the wrong readiness endpoint

- Severity: High
- Confidence: High
- Exact files: `utilities/smoke-test.sh`, `docker-compose.yml.example`,
  `utilities/maintenance-health.sh`

Current behavior:

- The smoke test says exit `0` means all checks passed and describes itself as the
  before/after-go-live production readiness check.
- Missing canonical project environment makes environment-dependent checks SKIP.
- Docker or Compose unavailable makes Compose validation SKIP.
- Missing `cscli` makes CrowdSec SKIP even though CrowdSec is mandatory in the
  project boundary.
- It checks only the DB/full backup timers, while the managed systemd timer set
  also includes health, maintenance, DNS update, and firewall update timers.
- Final success is based only on `_FAIL == 0`. SKIP does not block exit `0`, and
  the summary prints `All checks passed — stack is ready for production.`
- The HTTP readiness probe requires `200` from `/api/alive`. The repository's
  normal health implementation checks `/alive`, the Compose Vaultwarden
  healthcheck uses `/alive`, Caddy exposes `/alive`, and Vaultwarden's upstream
  Docker healthcheck also uses `${base_path}/alive`.

A host can therefore receive a production-ready exit/result with required checks
not performed; on a healthy normal route, the smoke test also probes a different
readiness endpoint from every canonical health path.

Minimal fix direction:

- Use `/alive`, not `/api/alive`.
- In production smoke mode, make unavailable required subsystems FAIL, not SKIP:
  project env, Docker/Compose, CrowdSec tooling/service, and the managed timer
  readiness required by the project.
- Reserve SKIP for an explicitly optional check or an operator-supplied skip mode.
- Exit `0` only when no required check failed or remained unperformed.
- Reuse the existing six managed timer names or route to existing systemd
  validation logic after TP-20 is corrected; do not create a readiness registry.

Focused regression test:

- Mock env/Docker/cscli/timer availability and assert any required unperformed
  check prevents `ready for production` and returns non-zero.
- Assert the readiness URL is `/alive`.

### TP-16 - The pre-production drill can pass unrehearsed paths and does not test the restart sequence it claims

- Severity: Medium
- Confidence: High
- Exact file: `utilities/pre-production-drill.sh`

Current behavior:

- Help says the drill rehearses all critical operational paths and validates the
  stack restart sequence before go-live.
- `drill_stack_restart_sequence` only runs `docker compose config --quiet` and
  checks that `vaultwarden`, `caddy`, `postfix`, and `init-permissions` are defined.
  It does not run startup, restart, or safe-restart.
- With no DB backup, the restore-path check SKIPs even when `--skip-restore` was
  not requested.
- With no full backup, the full restore smoke-test SKIPs.
- Without `sqlite3`, DB restore integrity SKIPs.
- Final success depends only on `_STEPS_FAILED == 0`; skipped steps can still end
  with `Drill PASSED — all rehearsed paths are operational.`
- `drill_backup_verify` first announces the archive it selected by age-day logic,
  then calls `backup-run.sh verify` without passing that archive. The backup
  verifier independently chooses the newest archive by mtime, so the named
  `backup-found` archive and the actually verified archive can differ.
- The drill also installs `perform_cleanup` directly for HUP/INT/TERM; the shared
  cleanup helper returns normally and does not terminate the script.

Minimal fix direction:

- Rename `Stack Restart Sequence` to `Compose restart preflight` and remove the
  restart-validation claim; a truly non-destructive drill should not restart
  production merely to justify the label.
- When restore rehearsal is not explicitly skipped, absence of the required DB/
  full backup or `sqlite3` should FAIL the drill.
- Make explicit `--skip-email` / `--skip-restore` the only normal source of SKIP.
- Remove the drill's independent `backup-found` preselection or make the verifier
  itself print/return the exact archive it verified. Prefer one selection path.
- Use signal traps that clean up and exit with the signal status.

Focused regression test:

- No backup without `--skip-restore` must return non-zero.
- Explicit `--skip-restore` may return success if all remaining required steps pass.
- The summary must not say all rehearsed paths are operational when required steps
  were implicitly skipped.
- The displayed verified archive must be the archive actually passed through full
  verification.

### TP-17 - Quick backup verification failure returns process success

- Severity: Medium
- Confidence: High
- Exact files: `utilities/backup-run.sh`, `tests/test-operator-ui.sh`,
  `docs/BACKUP-RESTORE.md`

Current behavior:

- A failed quick verification sets `verify_failed=true` and
  `verification_status="quick verification FAILED"`.
- Requested offsite sync is disabled with `skipped because verification failed`.
- The operator is warned: `do not treat it as verified` and manual inspection is
  required.
- The common success tail then exits `0` even on that branch.
- Existing operator-UI tests intentionally verify the warning/success-message
  split but do not require a non-zero exit for failed verification.
- The backup/restore guide states that no backup should report success with an
  unverified or partial database.

Scheduled DB/full units currently request `--full-verification`, so this finding
primarily affects the normal manual `sudo make backup` / `sudo ./backup.sh run db`
path and any caller relying on its exit status. It is still a supported operator
contract and should be truthful.

Minimal fix direction:

- Preserve the failed archive for manual inspection if that remains intentional.
- Preserve the current warning and summary.
- Return non-zero after the summary when quick verification failed.
- Do not mark the archive as offsite-synced and do not emit the verified-success
  completion line.
- Use ordinary failure status rather than adding a backup-status taxonomy unless a
  real caller needs distinct codes.

Focused regression test:

- Mock quick verification failure; assert archive preservation, no rclone sync,
  failed verification summary, no success line, and non-zero process exit.

### TP-18 - README's designated deployment golden path contains current root and rclone path drift

- Severity: Medium
- Confidence: High
- Exact files: `README.md`, `docs/DEPLOYMENT.md`, `utilities/setup-systemd.sh`

Current behavior:

- README explicitly tells new operators to start with `docs/DEPLOYMENT.md`.
- The original simplicity audit did not include that file in its inspected-doc
  list.
- Deployment Phase 4 tells the operator to run `./startup.sh` and
  `./maintenance.sh health` without sudo despite the current root-operated
  lifecycle/health contract.
- The same guide recommends `RCLONE_CONFIG=/etc/rclone/rclone.conf` for systemd
  backups.
- The current systemd installer manages and repairs
  `/etc/vaultwarden/rclone.conf`, discovers conventional user/root rclone config
  sources, and syncs the canonical installed path into runtime env state.

Minimal fix direction:

- Make the deployment guide use `sudo make up` and `sudo make health`.
- Recommend `sudo make edit-env` rather than presenting direct edits as the normal
  operator path where command coherence matters.
- Document `/etc/vaultwarden/rclone.conf` as the canonical installed systemd
  location and describe `rclone config` as the source-generation step.
- Include `docs/DEPLOYMENT.md` in the final doc/coherence checks and the existing
  workflow docs scans. Do not add a documentation framework.

Focused regression test:

- Extend the existing docs command scan to the deployment guide and assert the
  golden-path lifecycle examples use supported privilege forms and the canonical
  installed rclone path.

### TP-19 - `setup-secrets --skip-validation` is a documented no-op flag

- Severity: Low
- Confidence: High
- Exact files: `utilities/setup-secrets.sh`, generated command reference

Current behavior:

- Configure help advertises `--skip-validation` as `Skip token/SMTP validation`.
- Argument parsing sets `SKIP_VALIDATION=true`.
- The script's own ShellCheck comment states the variable is a documented option
  whose validation-skip logic is a `future placeholder`.
- No configure branch consumes the variable to alter validation behavior.

Minimal fix direction:

- Remove the flag and help text until a real supported need exists.
- Regenerate `docs/COMMAND-REFERENCE.md`.
- Do not implement a validation framework merely to preserve a dead option.

Focused regression test:

- Existing generated-command-reference freshness is enough after removal; no new
  dedicated test is required.

### TP-20 - Systemd install and validation can detect unhealthy managed timers but return success

- Severity: High
- Confidence: High
- Exact files: `utilities/setup-systemd.sh`, systemd timer units

Current behavior:

- When timers are started during install, setup-systemd waits for all six managed
  timers to become active and have a next trigger.
- If the count remains unhealthy, it logs `Not all managed timers are healthy`
  and prints per-timer diagnostics.
- The diagnostic return is explicitly ignored with `|| true` and installation
  continues to `Installation complete.` with exit `0`.
- `validate_installation` also treats unhealthy managed timers as warnings.
- A warning-only validation prints `Validation passed with ... warning(s)` and
  returns `0`.

For this project's set-and-forget model, scheduled DB/full backup, health repair,
maintenance, DNS refresh, and firewall refresh are production controls. A command
explicitly installing or validating automation must not return success when those
timers are known inactive or have no next trigger.

Minimal fix direction:

- In `install --enable-now` / start-policy `auto`, return non-zero after reporting
  if any managed timer remains unhealthy after the existing settle loop.
- In `validate`, count unhealthy managed timers as validation errors, not warning-
  only results.
- Preserve manual/install-only policy: when the operator explicitly chose not to
  start timers now, the installer may succeed with the current explicit
  `installed but not started by operator start policy` wording.
- Reuse `_report_unhealthy_managed_timers`; do not add a timer health service or
  another registry.

Focused regression test:

- Mock one active timer with no next trigger and one inactive timer.
- Auto-start install and validate must both return non-zero and name the unhealthy
  units.
- Manual start policy may succeed without claiming timers are active/scheduled.

## Fourth-Pass Corrected Production Priority

### Production blockers in the bounded final PR

1. **TP-14 recovery transaction/signal semantics.** This supersedes the narrower
   TP-05 implementation direction.
2. **TP-15 smoke-test readiness truthfulness and `/alive` endpoint.** A go-live
   validator must not return ready when required checks were skipped.
3. **TP-20 systemd timer install/validation exit semantics.** Known unhealthy
   automation must return non-zero.
4. **TP-17 backup verification exit semantics.** Failed verification must not be a
   successful command exit.
5. Existing F-01/F-02/TP-03 privilege and broken-dashboard actions.
6. Existing F-03/TP-09/TP-11 false-green dashboard/Make status semantics.
7. TP-13 broken advertised `make setup` path and TP-02/TP-18 golden-path docs.
8. F-04/TP-01 canonical runner and CI caller/path migration so all permanent
   regression contracts actually run.

### Same-PR simplification/QoL work

- TP-16 drill wording/implicit-skip/archive-selection corrections.
- TP-19 removal of the dead `--skip-validation` flag.
- TP-08 backup/inventory/create+sync label corrections.
- TP-10 `key-backup` custody wording or target removal.
- TP-12 backup help/version side-effect cleanup.
- Test renames/merges from the third-pass 30-test disposition map.
- Delete dead helpers such as `run_user_cmd` if the corrected dashboard has no
  remaining caller.

### Still explicitly leave alone

- Shared `flock` operation architecture from PR #224/#226.
- Bash/Make/Docker Compose/systemd/SOPS/Age architecture.
- Standalone replacement-host recovery concept.
- Full restore/recovery test harnesses where consolidation would hide diagnosis.
- Direct strict ShellCheck workflow job and existing workflow/job names.

## Required Focused Regression Additions From the Fourth Pass

Keep these inside the existing Bash test model and canonical runner:

1. Recovery transaction test:
   - signal exits and no continuation;
   - partial `install.env` update rollback;
   - sentinel pre-existence restoration;
   - post-commit startup/health failure preserves committed artifacts and exits
     non-zero.
2. Smoke-test contract:
   - required unavailable checks cannot yield production-ready exit `0`;
   - `/alive` is the readiness route;
   - all six managed timers are represented by the readiness contract.
3. Drill contract:
   - implicit missing restore prerequisites fail;
   - explicit skip flags are the only normal skips;
   - no restart claim without a restart;
   - named verified archive equals actual verification target.
4. Backup exit contract:
   - quick verification failure preserves the archive but returns non-zero and
     skips offsite sync.
5. Systemd validation contract:
   - unhealthy/no-next-trigger timer makes auto-start install and validation fail;
   - manual install-only policy remains a truthful success.
6. Setup/docs contract:
   - advertised first-install command can provide domain/email;
   - deployment golden path uses current root-operated commands and canonical
     installed rclone path.

Do not add a new test framework for these. Extend the permanent Bash contracts,
then let `./tests/run-tests.sh all` own the inventory as already recommended.

## Fourth-Pass Final Recommendation

**NOT READY at the audited commit — READY AFTER ONE BOUNDED ATOMIC FIX PR.**

Confidence is higher because the fourth pass attacked the report's own weak
assumptions and found the remaining risk concentrated in a small set of concrete
false-success/rollback contracts. The architecture is still appropriate for a
ten-user small-team appliance. The final PR should be implementation cleanup, not
design expansion.

The acceptance rule should now be:

> a production-readiness, recovery, backup, or automation-validation command may
> return zero only when the state it claims to validate actually passed; explicit
> operator skips must be named as skips and must never silently become READY.


---

## Final Implementation Feasibility and Activation Addendum

Date: 2026-07-05

This final pass asks a narrower question than the prior audits:

> If the bounded fix PR implements this report, will the corrected behavior
> actually be the behavior used by CI and by an already-installed production
> host, or are there hidden deployment/caller gaps that would leave old code
> running after merge?

The answer is **yes after one explicit supported activation step, but not from a
Git commit alone**. That distinction is important and is now part of the report's
acceptance contract.

### Final Feasibility Verdict

The report's implementation scope is technically feasible as one bounded atomic
PR. The proposed fixes do not require a new framework or architectural phase.

Two final corrections are required to make the implementation specification
exact:

1. TP-17 must discard a quick-verification-failed archive and sidecars before
   retention/success notification logic, rather than preserve the failed archive
   in the normal backup tree.
2. Installed systemd runtime split-brain must become a validation error, and the
   post-merge activation command must be explicit. Systemd services run root-owned
   copies under `/opt/vaultwarden-scripts`; `git pull` does not update those files.

With those corrections, the findings and minimal fix directions are internally
coherent and should work through existing Bash/Make/systemd paths.

**NOT READY at the audited commit — READY AFTER ONE BOUNDED ATOMIC FIX PR AND THE
DOCUMENTED POST-PULL SYSTEMD ACTIVATION STEP.**

## Correction to TP-17 - Failed quick-verification archives must not remain eligible as normal backups

- Severity: High
- Confidence: High
- Exact files: `utilities/backup-run.sh`, `lib/backup-utils.sh`,
  `utilities/restore-run.sh`, `tests/test-operator-ui.sh`
- Supersedes the fourth-pass TP-17 recommendation to preserve the failed archive

The fourth pass correctly found that quick verification failure returns zero, but
its proposed archive-preservation direction was too permissive.

Current execution order after a quick verification failure is:

1. set `verify_failed=true`;
2. send the verification warning email when `--email` was requested;
3. disable requested rclone sync;
4. continue through backup size reporting;
5. run local retention cleanup;
6. potentially prune remote backups when sync remains enabled for other paths;
7. enter the normal completion-email block, whose subject is
   `[VaultWarden] Backup completed: ...` even when its body says
   `quick (FAILED — see warning email)`;
8. print the failed-verification summary and warning; and
9. exit `0`.

Keeping the failed `.age` file in the normal `db/full/emergency` directory also
leaves it visible to ordinary `*.age` inventory and restore selection. Interactive
restore lists every matching `.age` archive, and `latest` selection uses the normal
backup directories. A known failed-verification archive must not remain eligible
as an ordinary restore candidate.

The local retention step is the more serious automatic interaction: a failed new
backup can still run retention and delete older archives before the command finally
reports the verification warning. That is the opposite of the desired failure
contract.

### Correct minimal fix

Match the existing full-verification failure philosophy:

- on quick verification failure, set the failed verification/offsite summary
  state and send the existing warning notification if requested;
- print one truthful failed-verification summary;
- log that the failed archive is being discarded;
- delete the archive and all normal sidecars:
  `.meta`, `.sha256`, and `.sha256.hmac`;
- return ordinary non-zero failure immediately;
- do not run local retention;
- do not run remote pruning;
- do not send the later `Backup completed` email; and
- do not emit the verified-success completion line.

No quarantine directory, failed-backup registry, or new backup state taxonomy is
justified for this project. If a quick checksum/decrypt probe failed, preserve the
warning/log evidence and keep older verified backups; discard the unusable new
archive.

### Correct focused regression test

Mock quick verification failure and assert all of the following in one harness:

- process exit is non-zero;
- failed archive and all normal sidecars are absent;
- rclone sync was not called;
- local retention cleanup was not called;
- remote pruning was not called;
- the verification-warning notification may be sent once when email is enabled;
- no `[VaultWarden] Backup completed:` notification is sent;
- no `Backup completed successfully` line is emitted; and
- the summary says verification failed and offsite sync was skipped when requested.

This supersedes the TP-17 regression wording that required archive preservation.

## TP-21 - Repository updates do not activate corrected systemd runtime code, and split-brain validation can still return zero

- Severity: High
- Confidence: High
- Exact files: `utilities/setup-systemd.sh`, `Makefile`, systemd units,
  deployment/update documentation

### Current deployment contract

`setup-systemd.sh` already documents the important fact:

> Run after every `git pull` to keep `/opt/` in sync.

Installation copies these runtime artifacts from the repository:

- `maintenance.sh`, `backup.sh`, and `restore.sh`;
- selected `utilities/*.sh`, including `maintenance-health.sh`,
  `backup-run.sh`, and `restore-run.sh`;
- the entire `lib/` tree; and
- managed service/timer unit files into `/etc/systemd/system`.

The timer/service units execute `/opt/vaultwarden-scripts/...` copies. Therefore:

- merging a PR changes Git;
- `git pull` changes the repository checkout;
- direct repo commands use the new scripts; but
- already-installed systemd jobs continue using their old `/opt` copies until the
  systemd installer is re-run.

`make update` is not a repository updater or installed-script synchronizer. It
updates host packages and Docker images through the maintenance update path. It
must not be treated as activation for a newly merged code change.

### Current validation gap

`validate_installation` has an existing repo-vs-installed SHA check for its
`scripts_to_check` list, but a mismatch is only a warning. Warning-only validation
returns `0`.

The validator also does not content-compare:

- repository `lib/` files against their installed `/opt/.../lib/` counterparts;
- ordinary managed service files against the repository unit source; or
- managed timer files against the repository unit source.

Only the rendered startup service has a full expected-vs-installed content
comparison.

This means a host can run stale timer code and still receive a zero exit from a
command whose help says `Verify installed state matches repo; detect split-brain`.
It also means the final PR could correctly fix `backup-run.sh` in Git while the
daily systemd backup keeps executing the pre-fix installed copy.

### Minimal fix direction

Strengthen the existing validator; do not add a self-updater.

1. Change repo-vs-installed SHA mismatch for every item in the existing
   `scripts_to_check` list from warning to validation error.
2. For every regular file present under repository `lib/`, compare it with the
   same relative path under `/opt/vaultwarden-scripts/lib/`:
   - missing installed counterpart = error;
   - content mismatch = error.
   Extra unreferenced historical files under installed `lib/` do not need to fail
   validation in this PR; the active scripts and expected repository libraries are
   the material contract.
3. For every unit in the existing `SERVICES` and `TIMERS` arrays, compare the
   repository source file with `/etc/systemd/system/<unit>`:
   - missing = existing error;
   - content mismatch = error.
4. Keep the existing freshly rendered comparison for
   `vaultwarden-startup.service`.
5. Keep TP-20's requirement that unhealthy managed timers are validation errors.
6. A zero `validate` exit must now mean:
   - expected managed scripts are installed and executable;
   - expected repository libraries match installed libraries;
   - expected managed unit files match repository unit files;
   - the rendered startup service matches current repo/state configuration;
   - required env/key permissions pass; and
   - all six managed timers are enabled, active, and have a next trigger.

Reuse `scripts_to_check`, `SERVICES`, `TIMERS`, and the existing SHA helper. Do not
create an install manifest, package manager, updater daemon, or artifact registry.

### Focused regression test

In the existing systemd contract harness, create a temporary repo and installed
tree and assert:

- stale installed `utilities/backup-run.sh` makes validation non-zero;
- stale installed `lib/backup-utils.sh` makes validation non-zero;
- stale installed `vaultwarden-db-backup.service` makes validation non-zero;
- a freshly rendered stale startup unit remains non-zero as today;
- all matching artifacts plus healthy timers returns zero; and
- the output names the exact stale artifact and says to re-run systemd install.

## Exact automatic-execution contract after the final PR

The project should distinguish repository automation from host activation.

| Event | Expected automatic behavior after final PR |
|---|---|
| Commit pushed to an **open implementation PR** | Existing `pull_request` workflow runs automatically; path filters must include all final migration surfaces. |
| Functional CI job | Runs exactly `./tests/run-tests.sh all`; the runner owns individual permanent test inventory. |
| Strict ShellCheck job | Continues to run directly and independently. |
| Merge to `delta` | Repository contains corrected code; no claim that Git can directly mutate an installed production host. |
| `git pull --ff-only` on an existing host | Direct repo commands use new code immediately; existing systemd services/timers may still use old `/opt` copies. |
| `sudo ./setup.sh systemd install --enable-now` on a healthy existing production host | Copies current managed scripts/libs/units, regenerates runtime env, daemon-reloads, enables/starts timer units, and—after TP-20—fails if any managed timer remains unhealthy. |
| `sudo ./setup.sh systemd validate` | After TP-20/TP-21, returns zero only when installed runtime matches repo and managed timers are healthy. |
| Future timer/service runs | Automatically execute the newly installed `/opt` code. |
| Boot | Enabled startup/timer units continue normal automatic behavior; no new updater daemon is required. |

### Important GitHub Actions scope note

The current workflow trigger is `pull_request`, not `push`.

Therefore the statement `CI runs automatically on commit` is accurate only when
the commit is pushed to an open PR and causes a pull-request synchronize event.
Direct commits to `delta` are not covered by this workflow trigger.

The final fix is already specified as a PR, so no push trigger is required for
this bounded work. Do not redesign CI merely to cover direct-to-branch development.
The implementation agent must create/update the PR and wait for its checks rather
than treating a local commit as automatically validated.

## Precise smoke-test integration after TP-20 and TP-21

The fourth pass said the smoke test should represent all six managed timers. The
final feasibility pass narrows the implementation so test inventory does not drift
again.

Do **not** add a second six-timer array to `smoke-test.sh`.

After TP-20 and TP-21, the existing systemd validator becomes the canonical
automation-readiness contract. Replace the narrow DB/full timer smoke check with a
required systemd automation validation check that invokes the repository's
existing systemd validator, for example the equivalent of:

```bash
"${SCRIPT_DIR}/utilities/setup-systemd.sh" validate
```

The smoke test should capture that command's success/failure and record:

- PASS only on validator exit `0`;
- FAIL on any non-zero result, with a concise instruction to run the validator
  directly for full diagnostics.

This one call covers:

- installed `/opt` split-brain after TP-21;
- managed unit/source drift after TP-21;
- env/key/install permissions already checked by the validator; and
- all six timer health contracts after TP-20.

Keep the smoke test's separate container/TLS/HTTP/secrets/backup/CrowdSec/disk
checks because those are live stack readiness probes rather than installation
consistency checks.

Also apply TP-15 exactly:

- readiness URL is `/alive`;
- required project environment, Docker/Compose, systemd automation validation, and
  CrowdSec availability are FAIL when unavailable;
- explicit optional checks may remain SKIP; and
- `_FAIL == 0` may produce `ready for production` only when no required check was
  left unperformed.

No readiness registry is needed.

## Precise drill backup-verification integration

The fourth pass correctly found that `pre-production-drill.sh` selects and names
one archive, then calls `backup-run.sh verify`, whose verifier independently
selects the newest archive by mtime.

Do not add a new `--file` API solely for the drill.

The existing backup verifier already owns canonical latest-backup selection and
prints its exact `Target: <file> [type: ...]` before performing full verification.
The drill should remove its independent `newest/newest_age/newest_type` selection
in `drill_backup_verify` and invoke the canonical verifier directly.

On success, the drill may record the verifier's target line or simply report that
canonical latest-backup full verification passed. On failure, preserve the
verifier's concise tail in the failed-step detail.

This gives one selection path and avoids another backup-selection helper.

The separate full-archive restore smoke-test may continue selecting one exact full
backup and decrypting/listing that exact file itself because that function actually
operates on the same file it names.

## Post-Merge Activation Procedure for an Existing Healthy Host

A Git commit cannot update root-owned `/opt` and `/etc/systemd/system` on a remote
VM. The supported post-merge activation is therefore explicit and short.

After the final fix PR is merged to `delta`, on an **existing healthy production
host**:

```bash
cd ~/VaultWarden-OCI
git pull --ff-only
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

Expected contract after the final PR:

1. install copies the merged managed runtime to `/opt` and current units to
   `/etc/systemd/system`;
2. install returns non-zero if auto-started managed timers are not healthy;
3. validate returns non-zero if installed runtime is stale or timers are unhealthy;
4. smoke returns non-zero for a missing required subsystem, stale automation
   install, wrong readiness endpoint response, or live production failure; and
5. only then may the host be treated as production-ready.

`--enable-now` is appropriate here because this sequence is specifically for an
already-healthy production host that is ready for scheduled jobs. It is **not** the
DR/manual-inspection sequence.

## Recovery or Manual-Inspection Host Activation

Preserve the existing restore safety choice. On a replacement/recovery host that
is not yet ready to run scheduled jobs:

```bash
sudo ./setup.sh systemd install --no-enable-now
```

That install may succeed while timers are intentionally not active. Do not call a
successful manual install `production ready`.

After storage, secrets, rclone, DNS/firewall, and Vaultwarden readiness have been
inspected:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

This preserves operator-controlled DR startup while giving normal production a
deterministic activation gate.

## Final Implementation Acceptance Matrix

| Contract | Exact acceptance condition |
|---|---|
| Recovery pre-commit failure | Old ciphertext/key/policy/manifest/install.env/sentinel state restored; signal handlers exit and do not continue. |
| Recovery post-commit startup or `/alive` failure | New committed recovery artifacts remain; command exits non-zero with next steps. |
| Quick backup verification failure | Failed archive/sidecars discarded; no retention, remote pruning, success email, or offsite sync; command exits non-zero. |
| Systemd auto-start install | All six managed timers active with next trigger or install exits non-zero. |
| Systemd validation | Installed managed scripts/libs/units match repo and all production timers are healthy or validation exits non-zero. |
| Smoke readiness | `/alive` used; required unavailable checks are failures; canonical systemd validation passes; zero means genuinely ready. |
| Drill | Only explicit skip flags produce normal skips; no restart claim without a restart; canonical verifier owns latest-backup selection. |
| CI | Open-PR commits automatically run canonical all-tests runner plus direct strict ShellCheck; workflow YAML does not own individual test inventory. |
| Existing production host after merge | One explicit `systemd install --enable-now` activation copies merged runtime; validate + smoke prove the activated state. |

## Final Final Recommendation

**The report is now sufficiently precise to implement. Stop auditing and execute
one bounded atomic fix PR.**

The final feasibility pass found no need for enterprise complexity. It found one
deployment truth that must remain explicit:

> Git commits update the repository; the existing systemd installer activates
> managed runtime code on the host. Do not hide that privilege boundary behind a
> self-updater.

After TP-20/TP-21, the activation path is fail-closed and self-checking. After the
corrected TP-17, a failed backup verification cannot prune older backups or remain
eligible as a normal restore candidate. After TP-14/TP-15/TP-16, recovery and the
two pre-production confidence tools have truthful failure semantics.

One PR, one canonical test inventory, one supported systemd installer, and one
explicit post-pull activation step are enough for this project.


---

## Final Scope-Pressure and Small-Team Realism Addendum

Date: 2026-07-05

This pass audits the **report itself** for overreach.

The question is not whether more cleanup can be imagined. The question is:

> Which changes are necessary to make this ten-user, set-and-forget appliance
> truthful and fail-closed, and which recommendations merely increase diff size,
> review risk, or long-term abstraction surface?

The pressure test used these rejection rules:

- reject a second source of truth when an existing canonical path can be called;
- reject generic transaction/readiness/install abstractions for one caller;
- reject test-file churn that changes no protected behavior;
- reject developer-surface deletion merely to make the Makefile shorter; and
- prefer deleting a weak derived status over building a parser to make it look
  authoritative.

### Scope-Pressure Verdict

**The production blockers remain valid, but the previous report over-scoped the
cleanup portion of the final PR.**

The final PR is realistic as one bounded PR **only after the scope cuts and
implementation clarifications below supersede the earlier rename/merge and broad
Makefile-cleanup recommendations**.

No new production architecture is justified. The shared operation guard,
Bash/Make/systemd/Compose/SOPS/Age model, and explicit post-pull systemd activation
remain correct.

**Current code is still NOT READY. The report is implementation-ready after this
scope trim. One bounded PR with a few coherent commits is sufficient.**

## Scope Cut SP-01 - Defer the historical test rename/merge map

The third-pass `Definitive 30-Test Disposition Map` was useful for understanding
overlap, but it is too prescriptive as acceptance criteria for the production fix
PR.

Renaming historical files such as:

- `test-migrate-followup.sh`;
- `test-config-systemd-followup.sh`;
- `test-email-refactor.sh`;
- `test-post-pr224-operation-contracts.sh`; and
- `test-secrets-env-systemd-guards.sh`

does not repair a runtime contract.

Merging prompt/email/restore/operation test pairs in the same PR also increases
diff size and makes review blame harder exactly when recovery, backup, systemd, and
production-readiness semantics are changing.

### Superseding direction

- Keep the current permanent `tests/test-*.sh` filenames in this final PR.
- Add focused assertions to the existing closest contract tests.
- Let `./tests/run-tests.sh all` explicitly inventory the current filenames.
- Keep the runner self-check that fails when a permanent `test-*.sh` file is
  unlisted or listed twice.
- Defer historical rename/merge cleanup to a future no-behavior-change PR, or never
  do it if the names are not causing real maintenance cost.

The earlier 30-test rename/merge map remains analysis history, **not final-PR
acceptance criteria**.

Recommended existing test homes for the final fixes:

- TP-14 recovery: extend `tests/test-recover.sh`.
- TP-17 backup failure semantics: extend the existing backup/operator behavior
  coverage, preferably `tests/test-operator-ui.sh` or
  `tests/test-backup-restore-behavior.sh` based on the harness reused.
- TP-20 start policy/timer health: extend `tests/test-start-policy.sh`.
- TP-21 installed runtime drift: extend
  `tests/test-config-systemd-followup.sh`.
- Make/dashboard privilege truth: extend `tests/test-privilege-contracts.sh` and
  `tests/test-operator-ui.sh`.

Do not create one test file per TP finding number.

## SP-02 - Canonical `all` is feasible, but one current test must stop rewriting the checkout's real `.env`

The fourth/final passes recommended making all 30 permanent Bash tests part of the
canonical runner. The scope-pressure pass inspected the currently unrun tests for
host mutation, package/systemd side effects, root requirements, and CI assumptions.

Result:

- the previously unrun operation, restore, secrets, health, systemd-path, email,
  and startup tests are static checks or temporary harnesses;
- they do not justify suite selectors or another test framework; and
- `./tests/run-tests.sh all` remains realistic.

One hygiene issue must be fixed first:

- `tests/test-config-systemd-followup.sh` backs up the checkout's actual `.env`;
- writes test content to `$ROOT/.env`; and
- relies on its EXIT trap to restore the operator file.

A normal failure is cleaned up, but SIGKILL, host interruption, or an external
termination that prevents the EXIT trap can leave a real checkout's operator
configuration replaced by test data.

### Minimal fix

Do not add a new production config override.

`lib/config.sh` already derives repo `.env` from `PROJECT_ROOT` at source/load
time and already supports `VW_CONFIG_INSTALLED_ENV_FILE` for the installed env
path.

Update the test harness to:

1. create a temporary fake repo root containing the test `.env`;
2. export `PROJECT_ROOT` to that temporary root before sourcing the real
   `lib/config.sh` by its explicit original path; and
3. continue using `VW_CONFIG_INSTALLED_ENV_FILE` for the temporary installed env.

The canonical runner must never transiently rewrite a production checkout's real
`.env`.

## Scope Cut SP-03 - Keep `test-unit` as a thin alias; do not delete developer conveniences wholesale

The earlier report recommended removing `test`, `test-unit`, `fmt`, `lint`, and
`shellcheck` from the Makefile after CI migration.

That is broader than the production problem.

The Makefile already places these under `Developer/Test — Testing & Development`.
A developer alias is not operator complexity when it does not own duplicate state.

### Superseding direction

- `./tests/run-tests.sh all` is the only permanent test inventory owner.
- Keep `make test-unit` as a thin delegating alias:
  `./tests/run-tests.sh all`.
- The workflow must call the runner directly, not the Make alias.
- `lint`/`shellcheck` may remain as developer conveniences.
- `fmt` may be removed if naturally touched because it is informational/no-op, but
  its removal is not production acceptance criteria.
- `test` may remain if its broader local semantics are truthful; it must not carry
  another individual permanent-test list.

The final PR must remove **duplicate inventory**, not developer convenience for its
own sake.

## SP-04 - Simplify TP-14 implementation: behavior-level recovery transaction, not prescribed per-key failure choreography

TP-14 remains a production blocker. The current facts are unchanged:

- direct `cleanup` INT/TERM traps can return and allow execution to continue;
- rollback does not cover `install.env`;
- live `install.env` is mutated one key at a time;
- the block-mode sentinel may be created before a later failure; and
- post-promotion startup/health failure needs a non-zero exit without rolling back
  a valid new recovery identity.

However, the earlier regression wording `inject failure after the first
atomic_set_env` dictates too much implementation shape.

### Preferred minimal implementation shape

Keep the transaction local to `recover.sh`:

- create staged copies of `install.env` and the recovery manifest;
- apply all env/manifest edits to those staged files;
- create staging files in the target directories so final `mv` promotion remains
  same-filesystem and atomic per file;
- back up the old live files as the current code already does for other artifacts;
- promote ciphertext, key, policy, staged install env, and staged manifest under
  the existing rollback scope;
- create/confirm the block-volume sentinel before startup when block mode requires
  it, remembering only whether recovery itself created it;
- set one `RECOVERY_COMMITTED=true` boundary after the promoted recovery identity
  and env/manifest references validate together;
- before that boundary, any failure restores the old live artifacts and removes a
  sentinel created by this run;
- after that boundary, startup or `/alive` failure returns non-zero but preserves
  the committed recovery artifacts; and
- use explicit INT/TERM handlers that clean/rollback as appropriate and exit
  `130`/`143`.

A few booleans and staged files inside `recover.sh` are enough.

Do **not** add:

- an operation journal;
- a recovery state database;
- a generic transaction library;
- a recovery state machine; or
- a dependency on the setup-secrets transaction internals.

### Superseding recovery test acceptance

Test observable behavior rather than an exact internal line:

1. a signal before commit exits `130`/`143`, does not continue, and restores the
   old recovery identity/config state;
2. an injected pre-commit env/manifest promotion failure restores old
   ciphertext/key/policy/install.env/manifest and removes only a sentinel created
   by that run;
3. post-commit startup failure returns non-zero and preserves the new committed
   artifacts;
4. post-commit `/alive` failure returns non-zero and preserves the new committed
   artifacts plus existing operator next steps.

### Sentinel concern inspected and not elevated

`recover.sh` currently touches `.vw-data-volume` in block mode and does not remove
an existing sentinel in boot mode.

This pass traced `lib/storage.sh`: boot mode is selected by blank
`DATA_VOLUME_DEVICE`, and the boot-mode readiness path does not inspect the
sentinel. The sentinel is authoritative only in separate-volume mode after a
configured device/mount passes validation.

Therefore **do not add generic boot-mode sentinel cleanup**. An operator may
explicitly choose boot semantics for a mounted path, and automatically deleting a
pre-existing marker is unnecessary/destructive policy. Track/remove only a
sentinel that the current recovery run itself created before commit.

## SP-05 - Simplify smoke readiness: zero means no FAIL and no SKIP

TP-15 remains valid, but the prior `required versus optional` implementation
wording invites a readiness classification layer that this project does not need.

`smoke-test.sh` exposes no explicit skip flags. Yet current code can record SKIP
for:

- unavailable project environment dependent checks;
- Docker/Compose unavailable;
- a container still starting;
- unavailable `systemd-analyze`/`systemctl`;
- unexpected admin endpoint status;
- missing `cscli`; and
- unreadable disk free-space information.

The final result currently checks only `_FAIL == 0`.

### Superseding minimal contract

Keep the existing PASS/FAIL/SKIP result shape for readable diagnostics, but:

> production-ready exit `0` requires `_FAIL == 0` **and** `_SKIP == 0`.

There is no need for a readiness registry or per-check required/optional metadata.
If a future operator skip flag is intentionally added, its final summary can be
designed then. Today there are no smoke skip flags, so an unperformed check must
not coexist with `ready for production`.

Also apply these small corrections:

1. Use `/alive`, not `/api/alive`.
2. Replace the narrow two-timer check with one call to the corrected canonical
   `utilities/setup-systemd.sh validate` from TP-20/TP-21.
3. Remove `check_startup_unit` and `check_startup_service` from smoke once canonical
   systemd validation is used. They duplicate install validation, and requiring
   `vaultwarden-startup.service` to be currently active can falsely fail a fresh
   healthy install: the installer enables the boot oneshot but does not start it
   during a normal systemd install.
4. Required container readiness must reuse
   `_VW_DEFAULT_CRITICAL_SERVICES` from `lib/defaults.sh`, which currently contains
   only `vaultwarden` and `caddy`. Do not hard-code a second service-policy array.
5. For those expected critical services, `healthy` is PASS, `starting` is SKIP
   (therefore not ready yet), and `none`/unhealthy/not-running is FAIL. Both current
   critical services define Compose healthchecks, so `health=none` is not a valid
   production-ready state.
6. Postfix is deliberately absent from the canonical critical-service list.
   Do not make an optional/best-effort relay sidecar a production-readiness blocker
   when direct/API email paths may be valid. Actual email delivery belongs in the
   existing drill/email diagnostic path.
7. CrowdSec PASS requires its service to be active **and** an actual `cscli`/LAPI
   query to succeed. A CLI/query failure is not `0 decisions` and not PASS.

The smoke summary may keep a Skipped count. When any skip exists, print a concise
`NOT READY — one or more checks were not completed` result and exit non-zero.

## SP-06 - Simplify dashboard truthfulness by deleting weak derived status

F-03/TP-11 correctly identified false-green dashboard language. The earlier
recommendation to make `Last backup` and `Last result` use the same archive still
preserves a weak derived status: `.sha256`/`.meta` sidecar presence is not proof of
a successful current verification, and pre-fix failed archives may still exist.

Do not build a backup-result parser or status cache.

### Superseding dashboard direction

- Delete `_last_backup_result` and remove the `Last result` line entirely.
- Keep one `Last backup` timestamp/name chosen by actual mtime.
- Rename `Secrets health` to `Config placeholders`; the current code only scans
  repo `.env` for placeholder text.
- Label rclone `Configured (not probed)` when binary/config naming is present;
  preserve `Not configured`/`Not installed` states.
- Email queue output is `0 queued`, `N queued`, or `Unknown`. Never call an empty
  queue `Healthy`, and do not turn a failed/missing `mailq` check into zero.
- Remove `Recent Auth Fails (1h)` completely. The broad `invalid|fail` grep is not
  an authentication classifier and is not worth replacing with a log parser in this
  project.
- CrowdSec decision query failure displays `Unknown`; capture the `cscli` result
  before counting.
- A failed systemd timer query displays `Unknown`. A successful query with no
  VaultWarden timer lines may say `No VaultWarden timers listed`.
- Remove `(safe)` from the ordinary restart menu label. Do not reroute normal
  restart to `safe-restart` merely to preserve the adjective.
- Correct the backup menu labels to DB snapshot/inventory/create+sync semantics
  already identified in TP-08.
- Route dashboard unban through the corrected `make unban` target and let `cscli`
  validate supported address forms; remove the dashboard-only IPv4 parser.
- Run recovery-kit export and email diagnostics in root context. Delete
  `run_user_cmd` if those fixes leave no caller.

This is a net code deletion/simplification, not a dashboard subsystem redesign.

## SP-07 - Keep Make developer conveniences; fix only broken operator contracts and duplicate implementations

The final Makefile scope should be smaller than the earlier report proposed.

### Required

- Fix F-01/F-02 root policy for retained root-operated targets used by help or the
  dashboard.
- Route `systemd-status` to the existing `setup-systemd.sh status` action; delete
  the duplicate hard-coded unit loop.
- Fix `unban` so a real `cscli` error remains non-zero. Do not convert every
  failure into `not found/may have expired` success.
- Fix the `status` CrowdSec query so numeric zero is printed only after a successful
  `cscli` query; otherwise print Unknown.
- Remove `key-path` and keep `key-health` authoritative; retain at most one
  root-correct lightweight `key-show` if still useful.
- Correct `key-backup` wording or remove the target. A copy under `$HOME` is not
  offline custody.
- Remove `make setup` from advertised first-install documentation/help. Keep one
  real golden path:
  `sudo ./setup.sh install --domain ... --email ...`.
- After caller search, either delete the broken `setup` target or keep only a
  hidden guidance target that prints the exact `setup.sh install` usage and exits
  non-zero. Do not build an interactive Make setup parser or another config layer.
- While the Makefile is already touched, correct the top usage examples for
  root-operated `safe-restart`, `status`, `health`, and `logs` to use `sudo`.

### Explicitly not required

- wholesale deletion of `lint`/`shellcheck`;
- historical test target renaming;
- a Make privilege registry or policy file;
- a new command router; or
- compatibility aliases for every removed descriptive label.

## SP-08 - Drill semantics need truthful explicit-skip wording, not more orchestration

TP-16 remains valid and its non-destructive boundary should remain.

Implement the smallest correction:

- rename `Stack Restart Sequence` to `Compose restart preflight`;
- remove help/summary claims that an actual restart was rehearsed;
- let canonical `backup-run.sh verify` own latest-backup selection and remove the
  drill's independent latest archive selector;
- if `--skip-restore` was not passed, missing DB/full restore prerequisites or
  missing `sqlite3` are failures;
- `--skip-email` and `--skip-restore` remain explicit supported SKIPs; and
- when explicit skips exist and no failure occurred, say `all non-skipped steps
  passed` rather than `all steps passed` or `all rehearsed paths are operational`.

Do not make the non-destructive drill restart production. Do not add a drill
workflow engine or another backup verification API.

## SP-09 - Day-2 operations docs must name repository-code activation explicitly

TP-21 is technically correct, and `setup-systemd.sh --help` already says to run it
after every `git pull` to keep `/opt/` in sync.

The operator-facing day-2 guide still has a gap: `docs/OPERATIONS.md` has an
`Update Operations` section for container images and host packages, but no
repository-code update procedure.

Add one small `Repository code update` subsection for an existing healthy
production host:

```bash
cd ~/VaultWarden-OCI
git pull --ff-only
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

State explicitly that:

- `git pull` updates the checkout;
- systemd install activates managed repo code in `/opt` and current unit files;
- validate proves installed runtime matches the checkout and timers are healthy;
- smoke proves live readiness; and
- recovery/manual-inspection hosts keep the existing `--no-enable-now` safety
  window until ready.

Do not add `make update-code`, a git-pull daemon, unattended repository updates,
or a self-updater.

## Final Scope After Pressure Testing

### Production correctness — must be in the final PR

1. F-01/F-02/TP-03 root-policy and broken dashboard root-action contracts.
2. TP-14 recovery pre-commit rollback, signal exits, one explicit commit boundary,
   and non-zero post-commit startup/health failure without rollback.
3. Corrected TP-17 quick-verification failure: discard failed archive/sidecars
   immediately; no retention/pruning/success email/offsite work; non-zero exit.
4. TP-20 systemd auto-start install and validation fail on unhealthy/no-next-trigger
   managed timers.
5. TP-21 installed runtime validation fails on stale managed scripts, expected repo
   libraries, or managed units.
6. TP-15/SP-05 smoke readiness: `/alive`, canonical systemd validation, canonical
   critical services, successful CrowdSec query, and no READY with any FAIL/SKIP.
7. TP-07/TP-09 real CrowdSec command failures remain errors/Unknown rather than
   benign success or numeric zero.
8. TP-13/TP-02/TP-18 first-install command/order/root/rclone path corrections.
9. F-04/TP-01 canonical Bash runner, checkout-safe test harness, direct workflow
   call, workflow/docs path filters, RUNBOOK/DEPLOYMENT scan coverage, and dead
   autofix-job deletion.
10. F-03/TP-08/TP-11/SP-06 dashboard and backup/status wording simplification by
    deletion/renaming rather than stronger unsupported claims.

### Tiny same-file cleanup — acceptable when already touching the file

- backup help/version before environment loading;
- dead `run_user_cmd` deletion after caller removal;
- `key-backup` truthful custody wording/removal;
- Makefile top usage sudo examples;
- `setup-secrets --skip-validation` removal **only if setup-secrets is already
  materially touched for another required change**; otherwise defer it;
- no-op `fmt` removal if naturally adjacent, otherwise defer it.

### Explicitly deferred from this production PR

- all historical test renames and test-file merges;
- wholesale removal of developer Make targets;
- a generic recovery transaction library;
- readiness metadata/registries;
- an install manifest or package manager for `/opt`;
- a self-updater or git-pull daemon;
- a status cache/monitoring database;
- a dashboard/TUI framework;
- a test framework migration; and
- further repo-wide architecture audits before implementing the known blockers.

## Recommended One-PR Commit Shape

One PR remains realistic, but one giant undifferentiated commit is not required.
Prefer a few coherent commits inside the same bounded PR:

1. **Fail-closed runtime contracts** — recovery, backup verification, CrowdSec
   command status, systemd install/validate split-brain and timer health.
2. **Operator truthfulness** — smoke, drill, dashboard, Make routing/labels/root
   policy.
3. **Canonical regression execution** — runner, existing focused test extensions,
   `.env`-safe test harness, workflow caller/path migration, dead CI job removal.
4. **Golden-path documentation** — RUNBOOK/DEPLOYMENT/OPERATIONS/SCRIPTS and
   regenerated command reference as required by actual code changes.

These are review boundaries, not architecture phases or separate PRs.

## Final Small-Team Implementation Guardrail

For the implementation agent:

> Do not introduce a new generic abstraction unless at least two existing
> production callers in this PR demonstrably need the same behavior and routing to
> an existing canonical helper is insufficient.

In particular, prefer:

- a local boolean over a state model;
- a staged file over a transaction framework;
- a direct `cmp`/existing SHA loop over an install manifest;
- a thin Make alias over duplicate inventory;
- one canonical validator call over copied readiness lists; and
- deleting a misleading dashboard field over building a parser to justify it.

## Final Scope-Pressure Recommendation

**REPORT READY — ONE BOUNDED PR IS REALISTIC AFTER THIS SCOPE TRIM.**

The additional pass did not uncover an enterprise-scale design problem. It did the
opposite: it identified where the audit itself was starting to ask for unnecessary
renames, merges, target deletion, and classification machinery.

The remaining production work is concrete and finite:

- truthful exit status;
- complete local recovery rollback before one commit boundary;
- installed-runtime activation/validation;
- one canonical regression inventory;
- no false READY/Healthy/PASS claims; and
- correct first-install/day-2 documentation.

Stop broad auditing after this addendum. Implement the bounded scope above, review
the resulting PR against the final acceptance conditions, activate it with the
documented systemd install step, then validate and smoke-test the actual host.

