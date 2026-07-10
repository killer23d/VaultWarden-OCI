# Post-Sprint Emergent Contract and Failure-Semantics Audit

## 1. Executive Summary

**Verdict: RED — production-blocking defects confirmed.**

The executable `delta` tree at `c60b647bb9987ff65fb81b0d40f4eb5a1cfffb8b` was reviewed in two independent static-analysis passes after PR #241. The audit confirmed **7 production-reachable defects: 0 Critical, 2 High, 4 Medium, and 1 Low**. It found **0 standalone coverage-only gaps** and identified **10 production-host validation items** that belong in real Ubuntu 24.04 Noble acceptance rather than another static backlog.

The two High findings are bounded but production-blocking under the current project contracts. Operational Age/SOPS key rotation can be interrupted after the new canonical key is promoted but before matching ciphertext is promoted, leaving key generation N+1 paired with ciphertext generation N and breaking the normal retry path. CrowdSec LAPI port reassignment can be interrupted after only part of its installed configuration cohort is rewritten; a normal rerun does not necessarily converge the stale consumers, while required bouncer startup failures can still be flattened into warning/success text and a final `CrowdSec setup complete` summary.

The four Medium findings are typed-status or safety-prerequisite defects: deep database maintenance `--force` also bypasses a failed safety backup despite help defining it only as confirmation bypass; startup calls health contention exit `75` a critical health failure; safe restart calls warning-only rollback health exit `1` a rollback failure; and recovery-notification delivery failure is swallowed after the cooldown is committed and then logged as sent. The Low finding is a current backup-producer/maintenance-consumer filename grammar drift that prevents intended cleanup of a successful temporary deep-maintenance safety backup.

**One bounded final code-fix PR is recommended before production-host acceptance.** The fixes are local owner/caller corrections and focused regressions in existing permanent suites. No transaction framework, state database, generic status registry, new test framework, or enterprise architecture is required.

After those findings are closed and the canonical 15-suite runner plus normal GitHub checks pass on the exact fix head, the evidence is clean enough to **stop broad static audits and move to real Noble production-host acceptance**. Further static review should be triggered by an observed acceptance failure or a materially changed production contract.

## 2. Audited Baseline

| Item | Audited value |
|---|---|
| Repository | `killer23d/VaultWarden-OCI` |
| Executable branch | `delta` |
| Exact executable HEAD | `c60b647bb9987ff65fb81b0d40f4eb5a1cfffb8b` |
| HEAD subject | `docs: align agent guidance with current restore contracts` |
| Audit branch | `audit/post-sprint-emergent-contract-failure-semantics` |
| Audit-branch start state | GitHub comparison to `delta`: `identical`, ahead `0`, behind `0`, changed files `0` |
| Audit date | 2026-07-10 |
| Report relationship to baseline | This report is not part of the executable baseline and was written only after the executable HEAD was pinned. |

`AGENTS.md` at the audited HEAD was read in full before analysis. The current HEAD commit changes guidance, not executable production code. PR #241 is merged beneath the pinned HEAD; its resulting executable tree, not its PR description, was audited.

Recent sprint context was reconstructed from current history and tree state around PRs #224 through #241: operation guards and typed contention; lifecycle and privilege behavior; CLI/parser ownership; Noble/dependency ownership; permanent test consolidation and ownership cleanup; secrets schema/runtime apply; CrowdSec Workers apply behavior; installed systemd runtime; retention/offsite semantics; and restore/DR transaction boundaries.

The audit branch was created directly from the exact executable SHA. The local execution environment could not resolve `github.com`, so no mutable local clone was used for repository reads or writes. The clean starting-state equivalent was established by creating the audit branch from the exact SHA and comparing it to `delta` before the report write; GitHub reported the refs identical with no changed files.

## 3. Scope and Non-Scope

This was a **report-only post-sprint emergent-contract audit**. No production code, tests, workflows, `AGENTS.md`, existing reports, or documentation outside this new report were modified.

The audit inventoried and traced the current operator entry points `setup.sh`, `startup.sh`, `backup.sh`, `restore.sh`, `maintenance.sh`, `edit-secrets.sh`, `recover.sh`, `dashboard.sh`, and `Makefile`; relevant current owners under `lib/*.sh` and `utilities/*.sh`; systemd install/runtime producers and managed service/timer contracts; `docker-compose.yml.example`, `.env.example`, `secrets-schema.yaml`, CrowdSec/Caddy surfaces; `.github/workflows/`; `tests/run-tests.sh`; and the current 15 permanent `tests/test-*.sh` domain owners. Deep traces concentrated on status propagation, interruption boundaries, generated/installed convergence, selected-plan prerequisites, path trust, truth after partial success, retention/offsite/restore cohorts, key/secrets promotion, health/notification semantics, CrowdSec installed-config convergence, and test blind spots.

The current executable tree and canonical configuration were the source of truth. Existing reports and PR descriptions were historical context only. Old finding IDs were not used as the starting checklist, and closed prior defects were not copied into this report.

No destructive production-host operation was run. No real package install/removal, systemd activation, Docker lifecycle, block-device migration, UFW/iptables change, CrowdSec deployment, Cloudflare call, rclone remote mutation, destructive restore, live key rotation, or real email delivery was performed.

The canonical suite `./tests/run-tests.sh all` was **not run** because the source tree was inspected through the authenticated GitHub connector and a local repository checkout was unavailable. This report does not claim that the canonical suite passed. Existing tests were read as executable regression contracts; historical/current CI context was not represented as a test run performed by this audit.

The only local Git command aimed at GitHub was:

```text
git ls-remote https://github.com/killer23d/VaultWarden-OCI.git refs/heads/delta
```

Result: **exit 128**, `Could not resolve host: github.com`.

For report syntax validation, the exact final report content was placed in a disposable local Git worktree. `git diff --check` returned **exit 0**. In that worktree, `git diff --name-only` returned only:

```text
reports/post-sprint-emergent-contract-failure-semantics-audit.md
```

Repository changed-file scope is separately verified by GitHub branch comparison before opening the pull request.

Connector-backed source validation included pinning `delta`, reading `AGENTS.md`, reviewing the recent sprint history and changed-file context, reading prior post-PR reports for historical coverage, tracing the current executable owners/consumers/tests, performing the two independent methods below, and confirming the audit branch was identical to `delta` before the report write.

## 4. Current Production Contracts Reconstructed

### Supported host/platform

Ubuntu 24.04 LTS Noble only, on `amd64` or `arm64`. Architecture selection, Noble validation, pinned yq/SOPS acquisition, and setup-owned dependency verification are architecture contracts. This is a small-team Vaultwarden appliance, not a generic multi-distribution installer.

### Privilege

Production lifecycle and day-2 mutation are root-operated. Root ownership is intentional for `/etc/vaultwarden`, installed environment/key material, persistent secrets/config state, and `/run/vaultwarden-oci` managed secret material. The `vaultwarden` group coordinates locks; it is not a service execution identity. Make/dashboard wrappers must not create a second self-escalation or privilege model.

### Operation guards and exit `75`

`lib/operations.sh` owns operation concurrency. The global `flock` is authoritative for mutating operations; specific locks serialize domains. Operation state is metadata, not a lock substitute. Exit `75` means expected contention/clean skip only where the owning operation defines it. Callers must preserve or deliberately interpret it; they must not turn it into generic success, generic failure, or a completed health result.

### Lifecycle

`startup.sh` owns guarded startup/restart sequencing: environment synchronization, storage readiness, runtime secret materialization, Compose validation/start, and post-start health. Health exit `0` is healthy; exit `1` is completed with warnings; higher typed exits are hard health failures. Safe restart may roll back a failed candidate generation, but its final status must distinguish candidate failure, successful rollback with warnings, and failed/unknown rollback validation.

### Environment/config

Operator-authored `.env` is synchronized into root-owned persistent `PROJECT_STATE_DIR/config/install.env` and `/etc/vaultwarden/vaultwarden.env`. Runtime-only SOPS/rclone overrides belong in generated runtime env, not repo `.env`. Data-volume configuration must pass storage preflight before generated env promotion. Individual generated env outputs use staged/atomic replacement and return downstream failure.

### Secrets/schema/runtime materialization

`secrets-schema.yaml` is the structural owner of managed secret fields, transforms, collection rules, requiredness, and apply types. Encrypted `secrets.yaml` is the source state. Runtime secret reconciliation must stage/decrypt/validate the active set before mutating `/run/vaultwarden-oci/secrets`, revoke inactive managed files, and return nonzero when reconciliation is incomplete. Apply failures after encrypted-state mutation must remain visible to the caller.

### Installed systemd runtime

Repository scripts/libraries/units are copied by `utilities/setup-systemd.sh` into `/opt/vaultwarden-scripts` and `/etc/systemd/system`. Installed runtime can differ from repository source, so install/validate must preserve path grammar, copied library closure, unit content, permissions, timer policy, and stale-runtime detection. systemd units that own contention skip explicitly allow `SuccessExitStatus=0 75` where appropriate.

### Backup tiers and recovery-point cohort semantics

The supported tiers are DB, full, and emergency. A verified primary is required for backup success. Requested offsite delivery is distinct from local backup success. The current restore consumer uses emergency `*.age.meta` `encryption_mode` to dispatch decryption, so emergency archive plus `.meta` are one recovery-point cohort. Current offsite code correctly returns hard-incomplete status when that restore-critical metadata is missing, unusable, or not delivered; checksum/HMAC sidecars retain separate warning semantics.

### Retention

Retention is per tier, preserves the newest parseable timestamped archive even when older than the configured window, and skips destructive primary deletion when timestamps cannot be safely interpreted. Remote pruning removes the primary and matching known companions as one cohort. Maintenance dry-run delegates canonical backup retention selection.

### Restore transaction/commit/start policy

Current full/emergency restore performs selected-plan prerequisite checks before service stop/destructive promotion, stages and validates archive layout, tracks promotion/rollback, repairs runtime permissions, and marks a committed generation only after promotion validation. Pre-commit failure or signal rolls back. Post-commit failures do not roll back the committed generation or restart an old generation; exact manual next steps are reported. Service-start and health statuses remain distinct after commit.

### Storage

Boot-volume state defaults to `/var/lib/vaultwarden`. With `DATA_VOLUME_DEVICE`, `PROJECT_STATE_DIR` must converge with the configured mount, the mount must be active, and `.vw-data-volume` participates in identity safety. Migration state supports explicit resume/abort behavior and lives outside the moving state root. Uninstall refuses destructive data-volume cleanup when expected mount/sentinel identity is not proven.

### CrowdSec/Cloudflare

CrowdSec is a host service with local API, firewall bouncer, and Cloudflare Workers bouncer when proxying is enabled. Schema-managed Worker credentials render through `lib/crowdsec-worker.sh`, which stages and YAML-validates generated Worker config and verifies the required service where requested. The local LAPI port is a separate installed-config cohort: the engine, local API credentials, firewall bouncer, and Worker bouncer must agree on one port. Because CrowdSec plus Cloudflare edge enforcement is mandatory for this project, setup must not report completion when required bouncer enforcement is inactive.

### Email/failure notification

Normal production mail is Postfix-sidecar first with current fallback policy. Notification callers may intentionally use a dead-letter/sentinel contract, but a caller that says a notification was sent must have successful delivery from the mail owner. Cooldown state must not suppress a retry after delivery failure unless another durable failure owner tracks that retry.

### Tests/CI

`tests/run-tests.sh` is a closed 15-suite permanent inventory. It rejects duplicate entries, missing listed suites, and unlisted permanent `tests/test-*.sh`. Canonical ownership is domain-based: architecture/toolchain; security/privilege; permissions; configuration/environment; secrets; operations; lifecycle; systemd; email; storage/setup; backup; restore/recovery; operator UI; CrowdSec; uninstall. CI and permanent tests are regression controls, not substitutes for real Noble acceptance.

## 5. Recent Sprint Churn Map

| Contract area | Recent churn | Interaction risk challenged |
|---|---|---|
| Concurrency | operation-guard expansion, inherited locks, exit `75` | typed skip lost/reinterpreted by lifecycle/aggregates |
| Lifecycle | startup/root model, safe restart, health ownership | warning/skip statuses flattened into failure/rollback |
| CLI ownership | parser/help normalization | flags gaining hidden safety semantics |
| Noble/dependencies | supported-host and package ownership | fatal prerequisites discovered after mutation |
| Test ownership | PR #228 consolidation, PR #239 cleanup | semantic assertion removed without replacement |
| Secret state/apply | schema materialization, Worker apply | source mutation succeeds while consumer remains stale |
| Key rotation | root-operated Age/SOPS rotation | multi-artifact generation split on signal |
| Generated config | Worker apply and CrowdSec setup | stale/mixed installed generation reported complete |
| systemd runtime | copy/validation and drop-in correction | repository N versus installed N-1 interaction |
| Backup/retention | typed offsite results, newest preservation | primary/critical companion or retention-owner drift |
| Restore/DR | PR #241 transaction closure | late prerequisites and pre/post-commit confusion |
| Operator truth | completion text, health, notification | partial child result represented healthy/sent/complete |

Churn itself was not a finding. Each confirmed defect required a concrete current code path and resulting state/status.

## 6. Pass One — Systematic Contract Audit Results

Pass One reconstructed producers, direct callers, aggregate callers, systemd/Make/dashboard endpoints, tests, and operator text without starting from old report finding IDs.

| Area | Result | Pass-one result |
|---|---|---|
| Failure/status propagation | Candidate findings | startup health `75`; safe-restart rollback health `1`; recovery-send result |
| Interruption/partial mutation | Candidate finding | key rotation promotes canonical key before matching ciphertext with no live-generation rollback on signal |
| Test contract preservation | Clean structurally; finding-linked blind spots | 15-suite inventory/domain ownership coherent; no standalone lost production contract proven |
| Generated/installed convergence | Candidate + clean areas | DB safety-backup filename drift; env/runtime secret/emergency offsite/restore convergence otherwise preserved |
| Prerequisite timing | Candidate finding | DB `--force` continues after failed safety backup before service stop/WAL/VACUUM |
| Path trust | Clean statically | storage/uninstall mount-sentinel checks and known-path permission repair bounded; real mount/kernel behavior remains host validation |
| Truth after partial success | Candidate findings | failed recovery notification logged sent; DB safety backup not identified for intended cleanup |

Pass One produced six candidates: the key-rotation cohort split; hidden DB `--force` safety-backup bypass; startup health `75` misclassification; safe-restart warning flattening; recovery-notification false success/cooldown suppression; and DB safety-backup naming drift.

Pass One rejected or downgraded several plausible issues. Setup firewall warnings did not by themselves prove false production readiness because setup retains explicit security/start/automation next steps. `setup-systemd.sh install` is structurally interruptible, but no exact current incompatible N/N-1 helper/caller generation pair was proven. Secrets edit/rotate Worker apply failures preserve nonzero status. Environment sync uses atomic per-output replacement and returns downstream failure. Runtime secret reconciliation stages/decrypts/validates before installed mutation and returns later failure. The old emergency `.meta` offsite gap is closed by current restore-critical cohort handling.

## 7. Pass Two — Independent Adversarial Cross-Check

Pass Two stopped using the Pass One candidate list as its starting point. It treated the same pinned HEAD as a fresh codebase and began from recent churn, production consumers, operator-visible endpoints, direct helper bypasses, and concrete negative paths.

### Churn-driven review

The highest-risk implementations were reselected by contract type: operation/health status, startup/safe restart, schema/runtime apply, key rotation, installed systemd runtime, backup/offsite/retention, restore commit boundaries, and CrowdSec generated/installed configuration. The central question was: **did fix B preserve assumptions introduced by fix A?**

This independently exposed that typed health statuses hardened in maintenance are not consistently interpreted by startup/safe restart, and that the staged/rollback transaction shape now present in secrets setup and recovery is not used by operational key rotation. It also found a CrowdSec LAPI-port installed-config cohort that Pass One had not modeled.

### Reverse producer/consumer tracing

Pass Two traced backward from:

```text
startup/safe-restart status text
  <- lifecycle mapper/rollback validator
  <- health rc 0 / 1 / 2 / 3 / 4 / 75

“Recovery notification sent” + cooldown
  <- _notify_recovery
  <- _send_notification result

current SOPS decrypt consumer
  <- canonical Age key path
  <- key-rotate promotion order
  <- old/new ciphertext generation

VACUUM/destructive DB boundary
  <- safety backup result
  <- --force public contract and branch

DB safety-backup cleanup predicate
  <- maintenance filename search
  <- perform_db_backup filename producer

restore emergency decrypt dispatch
  <- metadata parser
  <- remote pull/upload/sync
  <- emergency backup producer

CrowdSec engine/bouncer consumers
  <- config.yaml + local_api_credentials.yaml + bouncer URLs
  <- _cs_fix_port_conflict sequential sed -i producer
```

### Canonical-helper bypass scan

Direct lifecycle, Docker/Compose, package, SOPS/Age, rclone, retention, systemd, and destructive commands were not findings merely because they were direct. Two material weaker paths survived:

* `utilities/key-rotate.sh` directly promotes a coupled key/policy/ciphertext generation without the promotion tracking/rollback shape already used by `utilities/setup-secrets.sh` and `recover.sh` for similarly coupled generations.
* `utilities/setup-crowdsec.sh::_cs_fix_port_conflict` rewrites four LAPI-coupled installed files in place. That is materially weaker than the staged generated-config discipline in `lib/crowdsec-worker.sh`, and a normal setup rerun does not first reconcile a preexisting split port cohort.

### Negative-path scenario attack

| Scenario | Exact current result |
|---|---|
| Read-only health holds health lock when startup reaches post-start health | child `75`; startup wildcard calls it critical and fails |
| Candidate startup fails; old stack restored; rollback health returns warning-only `1` | safe restart calls rollback validation failed and exits `2` |
| Health recovers; recovery mail send fails | cooldown remains; failure swallowed; log says sent; later retry suppressed |
| `maintenance db-maint --force`; safety backup fails | code logs abort, then auto-continues because force is set; stop/WAL/VACUUM begins without fresh safety backup |
| TERM after new system Age key install but before rekeyed secrets promotion | new canonical key + old ciphertext remain; staging removed; retry fails initial decrypt |
| Successful deep-maintenance safety backup | producer writes `db_backup_...sqlite3.age`; cleanup searches `vaultwarden-db-*.age`; temporary backup remains |
| Emergency primary succeeds but critical `.meta` fails | correctly hard-incomplete; remote point not called complete; old hypothesis rejected |
| `setup-systemd` interrupted during copy | partial generation structurally possible, but no exact incompatible current N/N-1 pair proven; rejected as code defect |
| TERM after CrowdSec engine port rewrite before credentials/bouncer URLs | engine may start on new port while consumers stay old; normal rerun can skip rewrite; bouncer failures are warning/ignored paths; completion text reachable |

### Test blind-spot challenge

* `tests/test-secrets.sh` has behavioral rollback tests for setup-secrets ciphertext transactions, but no injected signal between key-rotate live promotions.
* `tests/test-backup.sh` has backup/offsite/retention harnesses, but no deep-DB `--force` backup-failure path and no maintenance cleanup-consumer test for current DB filename grammar.
* `tests/test-lifecycle.sh` protects lifecycle wiring/guards, but does not execute startup health mapping with `75` or safe-restart rollback validation with health `1`.
* `tests/test-email.sh` protects mail routes/MIME/caller trap behavior, but not `_notify_recovery` cooldown/send-result semantics.
* `tests/test-crowdsec.sh` has Worker render/apply behavior, but no LAPI port interruption/convergence test and no assertion that required bouncer startup failure blocks completion.

### Required reconciliation

| Pass One candidate | Disposition after Pass Two |
|---|---|
| Key rotation key/ciphertext split | **CONFIRMED BY BOTH PASSES — EFS-01** |
| DB `--force` bypass after failed safety backup | **CONFIRMED BY BOTH PASSES — EFS-02** |
| Startup health `75` critical mapping | **CONFIRMED AFTER PASS-TWO REFINEMENT — EFS-03**; scheduled timer mechanism rejected, read-only health contention confirmed |
| Safe-restart rollback health `1` flattened | **CONFIRMED BY BOTH PASSES — EFS-04** |
| Recovery send failure swallowed/cooldown retained | **CONFIRMED BY BOTH PASSES — EFS-05** |
| DB safety-backup filename cleanup drift | **CONFIRMED BY BOTH PASSES — EFS-07** |
| setup-systemd interrupted copy concern | **REJECTED AS FALSE POSITIVE**; no exact current incompatible pair proven |
| setup firewall warning/zero concern | **DOWNGRADED**; no false production-ready claim proven |

### New finding found only in Pass Two

**EFS-06** was found only in Pass Two. Pass One concentrated on the named schema-managed CrowdSec Worker apply owner and traced owner-to-caller status, so it did not model `/etc/crowdsec/config.yaml`, `local_api_credentials.yaml`, the firewall-bouncer config, and the Worker-bouncer config as one installed LAPI-port generation. Reverse tracing from `cscli` and both bouncer consumers exposed the split-cohort interruption path. The helper-bypass scan then showed the four in-place `sed -i` rewrites, and the negative-path trace proved that later setup phases can still reach completion text after required bouncer activation is inactive.

## 8. Confirmed Findings Summary

| ID | Severity | Confidence | Area | Pass discovered | Summary |
|---|---|---|---|---|---|
| EFS-01 | High | High | key rotation / interruption | Both | signal between key and ciphertext promotion leaves canonical key unable to decrypt live secrets and normal retry fails |
| EFS-02 | Medium | High | DB maintenance / prerequisite timing | Both | `--force` silently bypasses failed required safety backup before availability-affecting DB maintenance |
| EFS-03 | Medium | High | lifecycle / typed contention | Pass One, refined by Pass Two | read-only health contention `75` is called critical post-start health failure |
| EFS-04 | Medium | High | safe restart / typed health | Both | warning-only rollback health `1` is converted to rollback failure `2` |
| EFS-05 | Medium | High | notification / truth | Both | failed recovery mail remains cooled down and is logged as sent |
| EFS-06 | High | High | CrowdSec / generated installed config | Pass Two | interrupted LAPI port cohort can stay split while required bouncer failures still reach setup-complete text |
| EFS-07 | Low | High | DB maintenance / producer-consumer grammar | Both | cleanup searches obsolete DB backup filename grammar and leaves the temporary safety backup |

## 9. Detailed Confirmed Findings

### EFS-01 — Operational key rotation can promote a new canonical key before matching ciphertext

**Severity:** High
**Confidence:** High

**Affected files/functions:** `utilities/key-rotate.sh` live promotion and signal/exit cleanup. Comparison owners: `utilities/setup-secrets.sh::_ss_commit_ciphertext_transaction` and `recover.sh`. Regression owner: `tests/test-secrets.sh`.

**Current production contract:** the canonical operational Age key and encrypted `secrets.yaml` must be one decryptable generation. A failed or interrupted pre-commit rotation must leave the old live generation usable or restore it automatically. Retry must not require the operator to discover a hidden backup directory and manually reconstruct the cohort.

**Contract disagreement:** key rotation stages and validates generation N+1, but live promotion installs the new system key before the rekeyed ciphertext. Its INT/TERM/HUP cleanup releases the operation lock and removes staging; it does not track or roll back already-promoted live artifacts. In contrast, current secrets setup/recovery transaction owners track promotion and restore the prior generation on pre-commit failure/signal.

**Concrete execution/failure sequence:** (1) key A decrypts ciphertext A; (2) rotation stages key B, policy B, ciphertext B and validates the staged result; (3) live promotion installs canonical `/etc/vaultwarden/age-key.txt` B; (4) TERM/HUP/INT arrives before ciphertext B is installed; (5) cleanup removes staging and releases the lock; (6) live state is key B + ciphertext A; (7) normal retry resolves key B and fails its initial decrypt validation of ciphertext A.

**Actual resulting state/status:** the operation exits due to signal with an incomplete operation record, but the canonical key no longer decrypts the current encrypted secrets. Startup, backup HMAC-key loading, and secret-authoring consumers can fail. The ordinary rotate retry cannot self-heal because it validates decryption before it can stage the next generation.

**Operator/production impact:** a realistic SSH loss/signal can turn routine operational key rotation into a secrets-availability outage requiring manual recovery from `/root/vw-age-rotation-backups`. This is a major recovery-path defect, though not an unrecoverable secret loss when the backup directory survives.

**Why safeguards are insufficient:** pre-promotion staging validation proves B/B is valid but does not protect the live A/A cohort after the first live install. The operation lock prevents concurrent mutation but does not roll back process interruption.

**Why tests miss it:** `tests/test-secrets.sh` exercises transaction rollback for setup-secrets, including signal injection around ciphertext promotion, but does not execute `key-rotate.sh` with a signal injected between live key and ciphertext promotion.

**Pass discovery:** confirmed independently by both passes.

**Narrow fix direction:** add local promotion tracking to `key-rotate.sh`; retain known-good A artifacts until B key/policy/ciphertext have all been promoted and B decrypts the live ciphertext. On pre-commit error/signal, restore promoted members from the existing rotation backup and validate A/A. Do not add a generic transaction framework.

**Production fix shape:**

```diff
+ROTATE_COMMITTED=false
+PROMOTED_SYSTEM_KEY=false
+PROMOTED_REPO_KEY=false
+PROMOTED_CIPHERTEXT=false
+rollback_live_rotation() {
+  [[ "$ROTATE_COMMITTED" == true ]] && return 0
+  [[ "$PROMOTED_CIPHERTEXT" == true ]] && install -m 600 "$backup/secrets.yaml" "$SECRETS_FILE"
+  [[ "$PROMOTED_REPO_KEY" == true ]] && install -m 600 "$backup/repo-age-key.txt" "$repo_key"
+  [[ "$PROMOTED_SYSTEM_KEY" == true ]] && install -m 600 -o root -g root "$backup/system-age-key.txt" "$system_key"
+}
+trap 'rc=$?; rollback_live_rotation; operation_release "$rc"; exit "$rc"' EXIT
 install -m 600 -o root -g root "$staged_key" "$system_key"
+PROMOTED_SYSTEM_KEY=true
 ...
 install -m 600 "$staged_secrets" "$SECRETS_FILE"
+PROMOTED_CIPHERTEXT=true
+SOPS_AGE_KEY_FILE="$system_key" sops -d "$SECRETS_FILE" >/dev/null
+ROTATE_COMMITTED=true
```

**Regression test shape — `tests/test-secrets.sh`:**

```bash
# Inject TERM immediately after canonical system-key promotion.
VW_TEST_KEY_ROTATE_SIGNAL_AFTER=system-key run_key_rotate || rc=$?
[[ "$rc" -eq 143 ]] || fail "expected TERM status"
SOPS_AGE_KEY_FILE="$old_key" sops -d "$secrets" >/dev/null \
  || fail "interrupted rotation did not restore old decryptable generation"
run_key_rotate || fail "normal retry after interrupted rotation did not converge"
```

**Documentation impact:** none expected beyond changing retry wording if implementation messages change.

**Complexity assessment:** local rollback/promotion tracking in the owning script is sufficient; no transaction framework or recovery state machine is needed.

### EFS-02 — Deep DB `--force` silently bypasses a failed safety backup

**Severity:** Medium
**Confidence:** High

**Affected file/function:** `utilities/maintenance-db-maint.sh::show_help` and `run_deep_db_maintenance`. Regression owner: `tests/test-backup.sh`.

**Current production contract:** deep maintenance automatically creates an encrypted DB safety backup before stopping Vaultwarden and entering WAL/optimization/`VACUUM` work. Public CLI help defines `--force` as “Skip confirmation prompt.” It does not advertise bypass of a failed safety prerequisite.

**Contract disagreement:** after the backup command fails, the code logs that deep maintenance is aborting, but `DB_DEEP_FORCE=true` takes a separate branch that logs `Proceeding without safety backup (--force specified)` and continues automatically. The public flag contract and safety prerequisite owner disagree.

**Exact failure sequence:** run `maintenance.sh db-maint --force`; `backup-run.sh run db` fails due to key/disk/tool/backup error; the non-force branch would require an explicit second confirmation, but force skips that decision; Vaultwarden is stopped and WAL/optimization/`VACUUM` begins without a freshly proven rollback point.

**Actual state/status:** an availability-affecting database mutation proceeds after the automatic safety-backup prerequisite failed. The command may ultimately return success, so the failed safety boundary is not represented in final status.

**Impact:** bounded recoverability risk during a manually requested destructive maintenance workflow. Existing older backups may exist, but the workflow explicitly promised a fresh pre-maintenance safety point.

**Why safeguards are insufficient:** `--force` is a confirmation bypass, not documented as “continue without backup.” The earlier warning is not a prerequisite because code deliberately crosses the boundary after it.

**Why tests miss it:** backup tests protect DB backup creation and retention but do not execute the maintenance caller with a mocked backup failure under `--force`.

**Pass discovery:** both.

**Narrow fix direction:** make failed automatic safety backup fatal regardless of `--force`, or add a separately named explicit dangerous override only if the project truly requires it. The current boundary should fail closed.

**Production fix shape:**

```diff
 if ! "$PROJECT_ROOT/utilities/backup-run.sh" run db; then
-  if [[ "$DB_DEEP_FORCE" == false ]]; then
-    operator_confirm_yes_no "Proceed without safety backup?" "no" 300 || return 1
-  else
-    log_warn "Proceeding without safety backup (--force specified)"
-  fi
+  log_error "Safety backup failed; refusing deep database maintenance."
+  return 1
 fi
```

**Regression test — `tests/test-backup.sh`:** mock `backup-run.sh run db` to exit nonzero, invoke deep maintenance with `--force`, assert nonzero and assert the mocked stop/SQLite mutation commands were never reached.

**Documentation impact:** none; the fix aligns implementation with current help.

**Complexity assessment:** one caller branch and one focused mocked regression.

### EFS-03 — Startup calls health contention exit `75` a critical health failure

**Severity:** Medium
**Confidence:** High

**Affected files/functions:** `startup.sh::run_health_check`; typed result owner `utilities/maintenance-health.sh`; systemd context `systemd/vaultwarden-health.service`. Regression owner: `tests/test-lifecycle.sh`.

**Current production contract:** health `0` means healthy, `1` completed with warnings, `2+` typed hard failure, and `75` means expected duplicate health contention/clean skip where the health lock is already owned. A skipped health check has not proven health failure.

**Contract disagreement:** startup handles `0`, handles `1` as warnings, and sends every other status—including `75`—to the wildcard `CRITICAL failures detected` branch.

**Concrete path:** an operator/dashboard starts a read-only health check, which holds the health-specific lock but not the global mutator lock; startup legitimately runs concurrently; services start; startup reaches internal post-start health; the child cannot acquire the health lock and exits `75`; startup calls this critical and returns failure. This is **not** a scheduled timer race: the systemd unit runs `health --fix`, which participates in the global operation guard.

**Actual status/state:** the stack may have started successfully, but startup exits nonzero as a critical health failure. A safe-restart caller can then roll back an otherwise good candidate generation.

**Impact:** false lifecycle failure and unnecessary rollback/operator intervention under realistic concurrent read-only diagnostics.

**Why safeguards are insufficient:** the health owner and systemd unit preserve `75`; startup discards the typed meaning.

**Why tests miss it:** lifecycle tests protect wiring/guards but do not behaviorally stub internal health to return `75` and assert startup mapping.

**Pass discovery:** Pass One candidate, refined and confirmed by Pass Two after rejecting the incorrect timer-overlap mechanism.

**Narrow fix direction:** retry a small finite number of times on `75`; if contention persists, return/report explicit health unknown/contended nonzero. Never call `75` healthy or critical without a real health execution.

**Production fix shape:**

```diff
 health_rc=0
 VAULTWARDEN_INTERNAL_HEALTH_CHECK=true "$health_script" health || health_rc=$?
+if (( health_rc == 75 )); then
+  sleep 2
+  health_rc=0
+  VAULTWARDEN_INTERNAL_HEALTH_CHECK=true "$health_script" health || health_rc=$?
+fi
 case "$health_rc" in
   0) ... ;;
   1) ... ;;
+  75) log_error "Post-start health is unknown: health check remained contended"; return 75 ;;
   *) log_error "CRITICAL failures detected"; return "$health_rc" ;;
 esac
```

**Regression test — `tests/test-lifecycle.sh`:** stub health as `75` then `0` and assert startup succeeds after retry; stub persistent `75` and assert explicit contended/unknown nonzero with no critical-health wording.

**Documentation impact:** none expected.

**Complexity assessment:** typed caller correction only.

### EFS-04 — Safe restart converts warning-only rollback health `1` into rollback failure `2`

**Severity:** Medium
**Confidence:** High

**Affected files/functions:** `utilities/safe-restart.sh` rollback validation; `utilities/maintenance-health.sh` typed result owner. Regression owner: `tests/test-lifecycle.sh`.

**Current production contract:** health exit `1` means completed with warnings. Startup already accepts that status as a warning result. Safe restart exit `2` is reserved for the materially worse state where rollback/start/validation failed and manual recovery is required.

**Contract disagreement:** rollback validation uses a Boolean `if maintenance-health.sh health; then ... else ... exit 2`. Any nonzero status, including warning-only `1`, enters the rollback-failed path.

**Failure sequence:** candidate startup fails; safe restart restores the previous stack; prior containers start; health completes and returns `1` for warnings; shell `if` treats `1` as false; safe restart logs that rollback containers started but health still reports failures and exits `2`.

**Actual status/state:** old generation is restored and operational with warnings, but the caller/operator receives the manual-recovery rollback-failure status.

**Impact:** false severe recovery state, unnecessary operator intervention, and incorrect automation classification.

**Why safeguards are insufficient:** the health owner is typed, but safe restart consumes it as Boolean.

**Why tests miss it:** no behavioral rollback test injects health rc `1`.

**Pass discovery:** both.

**Narrow fix direction:** capture health status explicitly: `0` healthy rollback; `1` successful rollback with warnings and final safe-restart rc `1`; hard or persistent unknown/contended result -> rc `2`.

**Production fix shape:**

```diff
-if VAULTWARDEN_INTERNAL_HEALTH_CHECK=true "$health" health; then
-  log_success "Rollback healthy"
-else
-  log_error "Rollback containers started but health still reports failures"
-  exit 2
-fi
+rollback_health_rc=0
+VAULTWARDEN_INTERNAL_HEALTH_CHECK=true "$health" health || rollback_health_rc=$?
+case "$rollback_health_rc" in
+  0) log_success "Rollback healthy" ;;
+  1) log_warn "Rollback restored the prior stack with health warnings"; exit 1 ;;
+  *) log_error "Rollback health validation failed/unknown (rc=$rollback_health_rc)"; exit 2 ;;
+esac
```

**Regression test — `tests/test-lifecycle.sh`:** force candidate startup failure, mock successful prior-stack start and health rc `1`, assert final rc `1`, warning text, and absence of rollback-failed/manual-recovery classification.

**Documentation impact:** none.

**Complexity assessment:** local typed-status preservation.

### EFS-05 — Failed recovery notification is cooled down and logged as sent

**Severity:** Medium
**Confidence:** High

**Affected file/function:** `utilities/maintenance-health.sh::_notify_recovery`, compared with `_notify_failures`. Regression owner: `tests/test-email.sh`.

**Current production contract:** a recovery notification should be called sent only after `_send_notification` succeeds. A delivery failure should not consume the recovery cooldown unless another durable retry/dead-letter owner exists. `_notify_failures` already releases its cooldown on failed send.

**Contract disagreement:** `_notify_recovery` acquires recovery cooldown, calls `_send_notification ... || true`, and unconditionally logs `Recovery notification sent`. It does not release the cooldown on failure and has no equivalent durable notification-failure sentinel owner for this recovery path.

**Failure sequence:** prior failure state transitions to recovered; recovery cooldown is acquired/committed; SMTP/provider delivery fails; send status is swallowed; `Recovery notification sent` is logged; subsequent recovery notification attempts are suppressed until the cooldown expires (default path is up to 86400 seconds).

**Actual result:** no email was delivered, operator text says sent, and the next retry is intentionally blocked by state committed before delivery.

**Impact:** set-and-forget recovery truth is false and the operator can miss the recovery transition for the cooldown window.

**Why safeguards are insufficient:** the delivery owner returns nonzero correctly; this caller discards it. The OnFailure notifier's durable `NOTIFY_FAILED_<unit>` sentinel is not present here.

**Why tests miss it:** email tests cover route/MIME/caller traps, not maintenance recovery cooldown/send-result behavior.

**Pass discovery:** both.

**Narrow fix direction:** preserve the send result. On failure, release/remove the recovery cooldown state and log delivery failure; only log sent on rc `0`.

**Production fix shape:**

```diff
-_send_notification "$subject" "$body" || true
-log_info "Recovery notification sent"
+if _send_notification "$subject" "$body"; then
+  log_info "Recovery notification sent"
+else
+  _release_alert_cooldown recovery
+  log_warn "Recovery notification delivery failed; cooldown released for retry"
+  return 1
+fi
```

**Regression test — `tests/test-email.sh`:** source/execute the recovery caller with `_send_notification` returning nonzero; assert nonzero, cooldown state removed/released, no `sent` text, then assert a second attempt is not suppressed.

**Documentation impact:** none.

**Complexity assessment:** one caller result and cooldown predicate.

### EFS-06 — Interrupted CrowdSec LAPI port rewrite can remain split while setup still reports completion

**Severity:** High
**Confidence:** High

**Affected file/functions:** `utilities/setup-crowdsec.sh::_cs_fix_port_conflict`, `_cs_start_service`, `_cs_ensure_fw_bouncer_key`, bouncer registration paths, Phase 8 service activation, and final summary. Regression owner: `tests/test-crowdsec.sh`.

**Current production contract:** engine config, `local_api_credentials.yaml`, firewall-bouncer `api_url`, and Worker-bouncer `lapi_url` form one local LAPI-port cohort. When Cloudflare proxying is enabled, mandatory CrowdSec host/firewall and Cloudflare edge enforcement must be active or setup must return nonzero with truthful retry state. `CrowdSec setup complete` requires those predicates.

**Contract disagreement:** `_cs_fix_port_conflict` rewrites the four installed files sequentially with in-place `sed -i`. Signal traps release the operation lock and exit without restoring already-written files. A later normal rerun resolves the engine's new port and can start CrowdSec there, so no port-conflict branch necessarily re-runs solely because consumers remain stale. Stale local API credentials can make `cscli` fail; several registration commands use `|| true`; `_cs_ensure_fw_bouncer_key` can generate/write a local key and log success even if LAPI registration failed. Phase 8 ignores firewall-bouncer start failure and only warns when it never becomes active. Worker `systemctl enable --now` failure logs an error but is immediately followed by unconditional `enabled and started` success text. The final `CrowdSec setup complete` summary remains reachable.

**Exact failure sequence:** (1) cohort uses port 8080; (2) setup chooses 8090; (3) first `sed -i` changes `/etc/crowdsec/config.yaml` to 8090; (4) TERM/HUP/INT arrives before the other three files; (5) signal trap releases lock, leaving engine 8090/consumers 8080; (6) normal rerun reads engine port 8090 and can start CrowdSec, so `_cs_fix_port_conflict` is not necessarily re-entered; (7) `cscli` via stale local credentials fails and bouncer registration failures are swallowed in multiple paths; (8) firewall bouncer cannot authenticate/start, but `enable --now ... || true` and later warning preserve forward progress; (9) Worker service start can fail but success text is still printed; (10) setup reaches `Services enabled` and `CrowdSec setup complete`.

**Actual state/status:** engine can be running while one or both enforcement consumers are inactive/stale, yet setup may exit zero and print strong completion text.

**Impact:** a security-boundary false success in a project that explicitly requires CrowdSec with Cloudflare edge enforcement. This can leave the operator believing mandatory enforcement is active when it is not.

**Why safeguards are insufficient:** the global operation lock prevents concurrent mutation but does not roll back signal interruption. Worker apply staging covers Worker credential rendering, not the separate engine/local-credential/firewall/Worker LAPI-port cohort. Service checks are warning/ignored paths rather than completion predicates.

**Why tests miss it:** `tests/test-crowdsec.sh` protects Worker render/apply behavior but does not inject a signal between LAPI-port file promotions, seed a mixed engine/consumer cohort and rerun setup, or assert that required bouncer activation failure blocks setup completion.

**Pass discovery:** Pass Two only. Pass One missed it because it focused on the named Worker apply owner and traced outward; reverse tracing from `cscli` and both bouncer consumers exposed the separate LAPI-port cohort.

**Narrow fix direction:** in the existing CrowdSec setup owner, stage/validate the four port-coupled edits, retain originals, promote them as a bounded cohort, and restore promoted members on pre-commit failure/signal. At every normal rerun, compare the selected engine port with local credentials and existing bouncer URLs; if split, reconcile through the same helper. Make firewall-bouncer activation fatal when required. With proxy enabled and non-autonomous mode, require Worker service activation/active verification. Print completion only after required predicates pass.

**Production fix shape:**

```diff
+_cs_validate_lapi_port_cohort "$selected_port" || {
+  log_warn "Detected split CrowdSec LAPI port cohort; reconciling"
+  _cs_reconcile_lapi_port_cohort "$selected_port" || exit 1
+}

- sed -i ... /etc/crowdsec/config.yaml
- sed -i ... /etc/crowdsec/local_api_credentials.yaml
- sed -i ... "$fw_cfg"
- sed -i ... "$worker_cfg"
+_cs_stage_lapi_port_cohort "$old_port" "$new_port" "$tmpdir" || return 1
+_cs_validate_staged_lapi_port_cohort "$new_port" "$tmpdir" || return 1
+_cs_promote_lapi_port_cohort_with_rollback "$tmpdir" || return 1

-systemctl enable --now crowdsec-firewall-bouncer || true
+systemctl enable --now crowdsec-firewall-bouncer || return 1
+systemctl is-active --quiet crowdsec-firewall-bouncer || return 1

-systemctl enable --now crowdsec-cloudflare-worker-bouncer || log_error ...
-log_success "crowdsec-cloudflare-worker-bouncer enabled and started."
+systemctl enable --now crowdsec-cloudflare-worker-bouncer || return 1
+systemctl is-active --quiet crowdsec-cloudflare-worker-bouncer || return 1
+log_success "crowdsec-cloudflare-worker-bouncer enabled and started."
```

**Regression tests — `tests/test-crowdsec.sh`:** inject TERM after first port promotion and assert all four files remain on the old port; seed engine `8090` with consumers `8080`, run the reconciliation path, and assert all four converge to `8090`; mock Worker or firewall-bouncer start failure and assert nonzero, no `enabled and started`, and no `CrowdSec setup complete`.

**Documentation impact:** only targeted retry/completion wording if exact operator messages change; no architecture rewrite.

**Complexity assessment:** one local four-file cohort helper plus truthful required-service predicates. No generic transaction framework or new service manager is needed.

### EFS-07 — Deep-maintenance cleanup searches obsolete DB backup filename grammar

**Severity:** Low
**Confidence:** High

**Affected files/functions:** `utilities/maintenance-db-maint.sh::run_deep_db_maintenance`; producer `utilities/backup-run.sh::perform_db_backup`. Regression owner: `tests/test-backup.sh`.

**Current production contract:** deep maintenance creates an automatic temporary DB safety backup and, after successful maintenance, identifies that backup for success-only cleanup so ordinary retained backups are not needlessly accumulated by this internal prerequisite.

**Contract disagreement:** the current backup producer writes `db_backup_<timestamp>.sqlite3.age`; maintenance searches for `vaultwarden-db-*.age`. The consumer grammar no longer matches the producer.

**Failure sequence:** safety backup succeeds; producer creates `db_backup_20260710-....sqlite3.age` plus sidecars; maintenance searches the backup directory for `vaultwarden-db-*.age`; no file matches; `safety_backup_file` remains empty; success-only cleanup does nothing.

**Actual state/status:** deep maintenance can return success but its temporary safety backup and sidecars remain until normal retention eventually removes them.

**Impact:** bounded disk/retention inconsistency and misleading cleanup intent, not a recovery-point loss.

**Why safeguards are insufficient:** ordinary retention eventually bounds the file, but it does not make this success-only cleanup contract work.

**Why tests miss it:** backup tests validate producer grammar and retention but do not execute the maintenance cleanup consumer against a real/mocked current producer result.

**Pass discovery:** both.

**Narrow fix direction:** consume the exact backup path emitted/returned by the backup owner where practical; otherwise search the current canonical `db_backup_*.sqlite3.age` grammar and delete only that newly created cohort.

**Production fix shape:**

```diff
-safety_backup_file="$(find "$db_backup_dir" -name 'vaultwarden-db-*.age' ... | head -1)"
+safety_backup_file="$(find "$db_backup_dir" -maxdepth 1 -type f \
+  -name 'db_backup_*.sqlite3.age' -newer "$backup_start_marker" \
+  -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)"
```

A stronger local shape is for the backup caller to capture the producer's exact returned path and use it for cleanup.

**Regression test — `tests/test-backup.sh`:** run/mock successful DB backup creation using the current producer grammar, complete deep maintenance successfully, and assert the newly created archive plus `.sha256`, `.sha256.hmac`, and `.meta` cohort is removed while an older retained DB backup remains.

**Documentation impact:** none.

**Complexity assessment:** one stale consumer grammar or exact-path capture fix.

## 10. Coverage Gaps Only

**Standalone coverage-only gaps: 0.**

The semantic test-consolidation review did not prove a current production contract that was deleted from permanent coverage without either equivalent/stronger current ownership or a corresponding confirmed code defect above. The current 15-suite organization remains coherent:

* architecture owns supported host/toolchain/dependency contracts;
* permissions owns filesystem permission contracts;
* security/privilege owns root enforcement and security helper contracts;
* configuration/environment owns sync and caller wiring;
* lifecycle owns lifecycle sequencing and guard integration;
* backup owns backup/offsite/retention/verification behavior;
* restore/recovery owns restore transaction and recovery behavior;
* operator UI owns observable operator behavior;
* secrets owns schema/encrypted state/runtime materialization and secret workflows;
* CrowdSec owns CrowdSec setup/Worker apply behavior.

The missing behaviors identified by this audit are not listed here as generic coverage opportunities because each is attached to a proven production defect and has an existing canonical suite owner identified in Section 9.

The audit also found several source-position/grep assertions in current suites, but did not label them defects solely for being static. Behavioral regressions are specifically recommended where the confirmed defects depend on exit status, signal timing, retry, or child-result interpretation.

## 11. Production-Host Validation Requirements

These are real-host acceptance needs, not static code defects.

| # | Noble host validation | Why static review is insufficient |
|---|---|---|
| 1 | clean Noble `amd64` and `arm64` setup dependency install, yq/SOPS verification, apt/dpkg recovery | real package/repository/postinst behavior |
| 2 | systemd install/validate, timer activation policy, reboot, `/opt` runtime replacement, `SuccessExitStatus=75` | PID1/unit/drop-in/timer semantics |
| 3 | Docker Engine + Compose plugin startup, init-permissions, service health, safe restart | daemon/network/container/runtime behavior |
| 4 | OCI attached block-volume setup/adoption/migration, mount sentinel, fstab, reboot/mount guard, resume/abort | block device, UUID, mount and OCI attachment behavior |
| 5 | UFW/nftables/iptables and CrowdSec firewall-bouncer enforcement against Docker paths | kernel/netfilter/backend behavior |
| 6 | CrowdSec engine/firewall/Worker end-to-end on Cloudflare, including LAPI, route, KV/edge enforcement and fail-open route configuration | external service and real daemon behavior |
| 7 | rclone remote preflight, DB/full/emergency cohort upload, remote verification/pruning, and restore discovery | actual remote/provider semantics |
| 8 | destructive full/emergency restore and real operational Age rotation on disposable host, including injected TERM/HUP and retry | real filesystem/service/key behavior |
| 9 | notification delivery through Postfix/provider plus systemd OnFailure and health failure/recovery cooldown/retry | external SMTP/provider and systemd-triggered delivery |
| 10 | go-live acceptance over realistic reboot, backup, maintenance, failure-notification, recovery, and operator-card workflows | validates integrated set-and-forget appliance behavior |

## 12. Rejected Hypotheses and False Positives

| Suspected issue | Disposition | Reason |
|---|---|---|
| Secrets edit/credential rotation can return success after Worker apply failure | Rejected | callers capture apply failure, provide retry guidance, and return nonzero after post-edit work |
| Scheduled health timer creates EFS-03 | Rejected mechanism | timer runs `health --fix` and owns global operation guard; confirmed path is concurrent read-only health |
| Emergency `.meta` is still best-effort offsite | Rejected | one-backup sync hard-fails incomplete critical metadata; sync-all validates retained emergency metadata and includes `*.age.meta` |
| Env sync can report success while runtime env stays stale | Rejected | per-output atomic replacement, downstream nonzero, retry convergence |
| Runtime secret reconciliation claims success after staging failure | Rejected | active set is staged/decrypted/schema-validated before mutation and later failures return nonzero |
| Any interrupted `setup-systemd` copy is automatically a confirmed mixed-generation defect | Rejected | structural interruption exists, but no exact incompatible current helper/caller N/N-1 pair was proven |
| `setup.sh` zero after firewall warning means operator is told production is ready | Downgraded | staged summary retains explicit security/start/automation next steps and does not claim production readiness |
| Restore still discovers selected archive/rekey prerequisites after stop | Rejected | current #241-resulting code checks selected archive tools and rekey/SOPS prerequisites before destructive boundary |
| Uninstall can recursively delete an unmounted configured data-volume path | Rejected | separate-volume content deletion requires absolute path, active mount, and `.vw-data-volume`; unmounted nonempty path refused |
| Permission repair broad-chmods arbitrary state | Rejected | explicit central known-path contracts and service-specific runtime repair |
| OnFailure notifier swallowing mail failure is the same as EFS-05 | Rejected | OnFailure path writes durable `NOTIFY_FAILED_<unit>` sentinel consumed by health; recovery caller has no equivalent owner |
| UFW per-CIDR tolerance proves rule loss | Host validation only | static code does not prove a specific Noble UFW/netfilter command failure |

The rejected list demonstrates that Pass Two removed weak hypotheses rather than accumulating every suspicious construct.

## 13. Recommended Targeted Fix Scope

Create **one bounded final emergent-contract closure PR** before production-host acceptance. Close only EFS-01 through EFS-07 and add focused behavioral regressions to existing canonical suites.

### Likely production files

* `utilities/key-rotate.sh`
* `utilities/maintenance-db-maint.sh`
* `startup.sh`
* `utilities/safe-restart.sh`
* `utilities/maintenance-health.sh`
* `utilities/setup-crowdsec.sh`

### Existing permanent test suites

* `tests/test-secrets.sh` — EFS-01 signal/promotion rollback and retry
* `tests/test-backup.sh` — EFS-02 failed safety backup under `--force`; EFS-07 current DB backup grammar cleanup
* `tests/test-lifecycle.sh` — EFS-03 typed `75` retry/unknown result; EFS-04 rollback health `1` preservation
* `tests/test-email.sh` — EFS-05 failed recovery-send cooldown release/truthful message
* `tests/test-crowdsec.sh` — EFS-06 LAPI-port cohort rollback/convergence and required bouncer fail-closed activation

### Fix grouping discipline

Keep the PR as contract closure, not another audit/refactor:

* track/rollback one key-rotation promotion cohort;
* fail one DB prerequisite closed and correct one stale filename consumer;
* preserve two typed health results in lifecycle callers;
* preserve one notification send result/cooldown predicate;
* make one CrowdSec installed-config cohort interrupt-safe/convergent and make required service completion truthful.

### Documentation impact

No broad documentation update is expected. The DB fix aligns code with existing `--force` help. Lifecycle/notification fixes preserve current typed semantics. Key rotation can keep the current operator workflow. CrowdSec documentation should change only if exact retry/completion wording changes; otherwise the code should make current completion text true.

### Explicitly out of scope

Kubernetes, HA, Redis, distributed locks, workflow engines, transaction frameworks, recovery state machines, state databases, plugin/provider registries, generic CLI frameworks, generic cloud abstractions, new monitoring stacks, redesign of the root-operated model, redesign of `flock`, generic status/dependency/path/backup-companion registries, broad Makefile/test consolidation, new permanent test files/frameworks, workflow changes, and another repository-wide audit report.

## 14. Final Recommendation

**Production is blocked pending the confirmed High-risk fixes.**

Make one bounded final code-fix PR for EFS-01 through EFS-07, with focused behavioral regressions in the five existing domain suites above. Require `./tests/run-tests.sh all` and the repository's normal GitHub checks to pass on the exact fix head. Then move directly to disposable Ubuntu 24.04 Noble production-host acceptance and go-live validation.

After the confirmed findings are closed, **stop broad static audits**. The current codebase has already received repeated repository-wide review, and this independent Pass Two rejected multiple plausible but unproven hypotheses. Remaining uncertainty is dominated by real package, systemd, Docker, mount, firewall, CrowdSec/Cloudflare, rclone, destructive restore/key-rotation, and mail-delivery behavior on the supported host—not by another broad grep/static pass.

The next static review should be triggered by a concrete acceptance failure or a materially changed production contract, not by a desire to manufacture another backlog.
