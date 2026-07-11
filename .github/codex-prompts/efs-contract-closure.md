# Codex Task: Close EFS-01 through EFS-07

## Mission

Implement the seven confirmed findings in `reports/post-sprint-emergent-contract-failure-semantics-audit.md` as one bounded production-fix pull request against `delta`.

The current `delta` executable tree is still the audited executable tree; changes after audit baseline `c60b647bb9987ff65fb81b0d40f4eb5a1cfffb8b` only added the report. Revalidate every touched path before editing and treat current executable code as the source of truth.

Read `AGENTS.md` in full before changing code. Follow its production boundary, Bash conventions, source-of-truth order, test ownership, scope discipline, and truthful validation requirements.

## Non-negotiable constraints

- Work only on branch `agent/efs-contract-closure-20260710`, based on `delta`.
- Keep the patch limited to EFS-01 through EFS-07 and their focused regressions.
- Use small local owner/caller corrections. Do not introduce a generic transaction framework, state database, registry, workflow engine, daemon, scheduler, new test framework, or new permanent test file.
- Do not modify `AGENTS.md` or rewrite the audit report.
- Do not perform unrelated cleanup, broad refactoring, formatting churn, or architecture changes.
- Preserve Ubuntu 24.04 Noble, `amd64`/`arm64`, root-operated lifecycle, systemd, Docker Compose, SOPS/Age, and existing operation-guard contracts.
- Never hide a real error with `|| true`, never report success before the required predicate is true, and preserve typed exit statuses deliberately.
- Do not run local CI suites or CI-equivalent validation commands. In particular, do not run `./tests/run-tests.sh all`, ShellCheck, the permanent test scripts, Docker Compose validation, or destructive/host-level commands. You may inspect code, tests, workflows, `git status`, `git diff`, and use `git diff --check` only.
- Before editing, inspect `.github/workflows/` and `tests/run-tests.sh` so the implementation is designed for the repository's actual GitHub checks and path filters. Do not change workflows unless a verified workflow defect prevents the relevant existing checks from running.
- Push each issue commit separately so GitHub Actions evaluates the real history. Do not merge the PR and do not squash the issue commits.
- Never claim a local test or CI check passed unless it actually ran and passed.

## Required commit discipline

Create one self-contained commit for each issue, including its production change and focused regression in the existing owning suite. Use these commit subjects, or equally clear subjects containing the EFS ID:

1. `fix(secrets): make Age rotation interruption-safe [EFS-01]`
2. `fix(backup): fail deep maintenance closed on backup failure [EFS-02]`
3. `fix(lifecycle): preserve health contention during startup [EFS-03]`
4. `fix(lifecycle): preserve rollback health warnings [EFS-04]`
5. `fix(email): retry failed recovery notifications [EFS-05]`
6. `fix(crowdsec): reconcile the LAPI port cohort atomically [EFS-06]`
7. `fix(backup): clean the current DB safety-backup cohort [EFS-07]`

If a GitHub check exposes a defect in one issue's commit, add a narrowly scoped follow-up commit named `fixup(EFS-XX): ...`; do not mix fixes for different EFS IDs. Keep the seven primary commits intact.

After all issue commits are present, remove this prompt file in a final commit such as `chore: remove completed Codex task brief`. The final PR diff must contain only production code, focused tests, and any materially required operator wording.

## EFS-01 — Interruption-safe operational Age rotation

Owners: `utilities/key-rotate.sh`, regression in `tests/test-secrets.sh`.

Current defect: the live system key is installed before the matching ciphertext. INT/HUP/TERM cleanup removes staging and releases the operation lock but does not restore already-promoted live artifacts. A signal can leave key generation N+1 paired with ciphertext generation N, and a normal retry then fails its initial decrypt.

Required behavior:

- Treat the system key, repository key, SOPS policy, encrypted `secrets.yaml`, and any promoted canonical environment references as one bounded live generation.
- Retain known-good originals before the first live promotion.
- Track exactly which live members have been promoted and whether the new generation has committed.
- On any pre-commit error or INT/HUP/TERM, restore only promoted members from the known-good backup, restore correct ownership/modes, and validate that the restored canonical key decrypts the restored live ciphertext.
- Preserve the original exit/signal status and release the operation guard exactly once.
- Commit only after all intended live members are promoted and the canonical system key successfully decrypts live `secrets.yaml`.
- Do not roll back after commit.
- A normal retry after injected interruption must converge without manual reconstruction from `/root/vw-age-rotation-backups`.
- Use a narrow, test-only injection hook consistent with existing repository test conventions; it must be inert unless explicitly enabled.

Regression requirements in `tests/test-secrets.sh`:

- Inject TERM immediately after the first canonical key promotion.
- Assert the signal-derived nonzero status.
- Assert the old live generation is restored and decryptable.
- Assert no staged sensitive material is left behind.
- Run the normal rotation path again in the harness and assert retry convergence.

## EFS-02 — `--force` must not bypass a failed safety backup

Owner: `utilities/maintenance-db-maint.sh`, regression in `tests/test-backup.sh`.

Current defect: public help defines `--force` as confirmation bypass, but a failed automatic safety backup enters a branch that continues into service stop/WAL/VACUUM when `--force` is set.

Required behavior:

- A failed pre-maintenance DB safety backup is fatal regardless of `--force`.
- Return nonzero before `docker compose stop`, WAL checkpoint, optimize, or `VACUUM`.
- Remove misleading `Proceeding without safety backup (--force specified)` behavior.
- Keep `--force` limited to skipping the initial operator confirmation.
- Keep help unchanged unless implementation wording requires a small clarification.

Regression requirements in `tests/test-backup.sh`:

- Mock `utilities/backup-run.sh run db` to fail.
- Invoke deep maintenance with `--force`.
- Assert nonzero, truthful abort wording, and that stop/SQLite mutation commands were never reached.

## EFS-03 — Startup must preserve health contention status

Owner: `startup.sh`, typed status owner `utilities/maintenance-health.sh`, regression in `tests/test-lifecycle.sh`.

Current defect: post-start health handles `0` and `1`, but wildcard handling calls every other code—including clean duplicate-health contention `75`—a critical health failure.

Required behavior:

- Capture the health status explicitly.
- On `75`, perform a small bounded retry with a short, testable delay.
- If a retry executes health and returns `0` or `1`, preserve the normal healthy/warning mapping.
- If contention remains, report health as unknown/contended, not healthy and not a critical executed-health failure.
- Return a deliberate nonzero typed result for persistent contention; preserve `75` unless a stronger existing caller contract requires another explicit mapping.
- Do not describe a skipped health execution as `CRITICAL failures detected`.

Regression requirements in `tests/test-lifecycle.sh`:

- Stub health to return `75` then `0`; assert startup retries and succeeds.
- Stub persistent `75`; assert explicit unknown/contended wording, nonzero typed status, and absence of critical-health wording.

## EFS-04 — Safe restart must preserve warning-only rollback health

Owner: `utilities/safe-restart.sh`, typed status owner `utilities/maintenance-health.sh`, regression in `tests/test-lifecycle.sh`.

Current defect: rollback validation consumes health as Boolean, so warning-only rc `1` is classified as rollback failure rc `2`.

Required behavior:

- Capture rollback health status explicitly.
- `0`: prior stack restored and healthy.
- `1`: prior stack restored with health warnings; return final rc `1` with truthful warning text.
- Hard failure, crash, or persistent unknown/contended result: return rc `2` with manual-recovery classification.
- Do not label rc `1` as incomplete rollback or manual recovery.

Regression requirements in `tests/test-lifecycle.sh`:

- Force candidate startup failure.
- Mock successful prior-stack start and rollback health rc `1`.
- Assert final rc `1`, warning-only recovery wording, and absence of rollback-failed/manual-recovery wording.

## EFS-05 — Failed recovery notification must remain retryable and truthful

Owner: `utilities/maintenance-health.sh`, regression in `tests/test-email.sh`.

Current defect: `_notify_recovery` commits the cooldown, discards `_send_notification` failure, and unconditionally logs `Recovery notification sent`.

Required behavior:

- Only log `Recovery notification sent` after confirmed successful delivery.
- When delivery is unavailable or fails, return nonzero from the delivery owner/caller as appropriate, release the `recovery` cooldown, and log truthful retryable failure wording.
- Preserve existing failure-alert behavior: failed sends release their per-check cooldown.
- Do not create a new durable queue/state subsystem.

Regression requirements in `tests/test-email.sh`:

- Make `_send_notification` fail and invoke recovery notification.
- Assert nonzero, no `sent` message, and removal/release of `recovery.cooldown`.
- Assert a second attempt is not suppressed by the prior failed delivery.
- Cover the `email unavailable` path if it can currently return success without delivery.

## EFS-06 — CrowdSec LAPI port cohort must be atomic, convergent, and fail closed

Owner: `utilities/setup-crowdsec.sh`, regression in `tests/test-crowdsec.sh`.

Current defect: engine config, local API credentials, firewall-bouncer URL, and Worker-bouncer URL are rewritten sequentially in place. A signal can leave a split installed generation. A normal rerun can start the engine on the new port without reconciling stale consumers. Registration/start failures are swallowed or downgraded, and strong success/completion text remains reachable while required enforcement is inactive.

Required behavior:

- Model these installed files as one local LAPI-port cohort when present:
  - `/etc/crowdsec/config.yaml`
  - `/etc/crowdsec/local_api_credentials.yaml`
  - `/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml`
  - `/etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml`
- Stage edits in a root-only temporary directory, preserve original modes/ownership, validate every staged file references the selected port in its canonical field, and only then promote.
- Track promoted files and restore originals on pre-commit error or INT/HUP/TERM. Preserve the signal/error status and operation-guard cleanup.
- At every normal rerun, compare the engine-selected port with local credentials and existing bouncer URLs. If any existing member is stale, reconcile it through the same cohort helper even when no active socket conflict triggers port reassignment.
- Do not write/log a fresh bouncer key as successfully registered when the `cscli bouncers add` operation failed. Propagate required registration failures.
- Firewall-bouncer enable/start and active verification are mandatory completion predicates.
- When `CLOUDFLARE_PROXY_ENABLED=true` and non-autonomous mode is selected, the Worker-bouncer unit must exist, enable/start must succeed, and active verification must pass.
- Do not print `enabled and started`, `Services enabled`, or `CrowdSec setup complete` until all required predicates for the selected mode are true.
- Keep autonomous-mode behavior distinct; do not require a daemon when the current autonomous contract intentionally has none.
- Do not add a generic transaction framework or new service manager.

Regression requirements in `tests/test-crowdsec.sh`:

- Inject TERM after the first cohort member promotion and assert all four existing files retain the old port.
- Seed engine port `8090` with consumers on `8080`, run the normal reconciliation path, and assert convergence to `8090` without requiring another socket conflict.
- Mock firewall-bouncer start or active verification failure; assert nonzero and no completion text.
- With proxy enabled and non-autonomous mode, mock Worker-bouncer start/active failure; assert nonzero and no false success text.
- Cover bouncer registration failure so a local key is not presented as registered success.

## EFS-07 — Clean the actual DB safety-backup cohort

Owners: `utilities/maintenance-db-maint.sh`, producer `utilities/backup-run.sh::perform_db_backup`, regression in `tests/test-backup.sh`.

Current defect: the producer writes `db_backup_<timestamp>.sqlite3.age`, while maintenance searches `vaultwarden-db-*.age`, so successful maintenance never identifies its temporary safety backup for cleanup.

Required behavior:

- Prefer consuming the exact backup path emitted by the canonical backup owner when that can be done reliably without parsing mixed human logs.
- Otherwise retain the existing start marker and select only a newly created archive matching canonical `db_backup_*.sqlite3.age` grammar in the DB backup directory.
- On successful maintenance, delete only that exact new primary and its known cohort sidecars: `.sha256`, `.sha256.hmac`, and `.meta`.
- Preserve older retained DB backups.
- On failed/incomplete maintenance, retain the safety-backup cohort and report it truthfully.

Regression requirements in `tests/test-backup.sh`:

- Create/mock a successful safety backup using current producer grammar.
- Complete deep maintenance successfully.
- Assert the newly created primary and known sidecars are removed.
- Assert an older retained DB backup remains.

## GitHub Actions and PR handling

Before coding, inspect the actual workflow YAML and branch checks. Design the changes for the canonical permanent inventory in `tests/run-tests.sh`, strict Bash/ShellCheck expectations, generated/invariant checks, and any path filters that apply to the touched files.

Because local CI execution is prohibited for this task:

- Push each issue commit and inspect the GitHub checks that actually run.
- Fix only verified failures and keep every follow-up scoped to its EFS ID.
- Do not infer or claim success from static inspection.
- In the PR body, include a seven-row EFS-to-commit mapping and a validation section that explicitly says local CI/test suites were not run by instruction.
- Report the exact GitHub checks and conclusions only after they complete on the final head.
- Leave the PR as draft until all required GitHub checks pass. Do not merge.

## Final review checklist

- Seven primary EFS commits exist and remain separate.
- Each production change has focused regression coverage in the existing canonical suite owner.
- No new permanent test file or framework exists.
- No unrelated files, broad refactors, generated artifacts, secrets, runtime state, backups, or workflow churn are present.
- Operator success/failure wording matches actual state.
- Signal traps preserve status, rollback pre-commit mutation, and release locks exactly once.
- The prompt file has been removed from the final diff.
- PR remains draft, targets `delta`, and truthfully records what was and was not validated.
