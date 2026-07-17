# Independent Script Codebase Quality and Modularity Audit

**Repository:** `killer23d/VaultWarden-OCI`  
**Audited branch:** `delta`  
**Audited commit:** `cc3a7a510e1a037a3be0a1da8a919cd25638215a`  
**Audit date:** 2026-07-17  
**Audit type:** report-only, independent static architecture and implementation review

## 1. Decision summary

### Verdict

**Healthy with bounded cleanup opportunities.**

The repository does not exhibit broad helper sprawl, indiscriminate abstraction, or uncontrolled duplication. Its most important production domains—operation guards, backup/restore, secret custody, runtime permissions, environment synchronization, systemd installation, CrowdSec reconciliation, and test execution—have recognizable owners and deliberate safety boundaries.

A broad refactor is **not justified**. The appropriate next step is a small sequence of owner-focused corrections:

1. align the destructive `setup.sh --force` acknowledgement contract;
2. make operation-lock file preparation unconditionally owned by `lib/operations.sh` rather than dependent on whether `lib/common.sh` was sourced first;
3. correct misuse of the shared `require_root()` interface;
4. align dashboard environment reads with the accepted `.env` value grammar;
5. decide explicitly whether `recover.sh` is allowed only on an offline replacement host or must participate in the shared operation guard.

### Finding totals

| Severity | Confirmed E1/E2 | E3 risk | E4 investigation |
|---|---:|---:|---:|
| Critical | 0 | 0 | 0 |
| High | 0 | 0 | 0 |
| Medium | 2 | 1 | 0 |
| Low | 2 | 0 | 0 |
| Informational | 0 | 0 | 4 |

No direct production-host behavior was executed. Confirmed findings are statically demonstrated against the exact audited SHA.

### Top concrete risks

1. `setup.sh --force` advertises either an environment acknowledgement or an interactive acknowledgement, but currently requires the environment acknowledgement before it will display the prompt.
2. Operation lock-file ownership and mode depend on source order: `lib/operations.sh` uses a different fallback when `lib/common.sh::_ensure_lock_file` is unavailable.
3. Some callers pass prose into `require_root()` even though the shared helper treats its arguments as command arguments, producing incorrect remediation commands.
4. `dashboard.sh` implements a reduced `.env` parser that does not follow the canonical quote-handling grammar.
5. `recover.sh` performs a multi-artifact recovery promotion before invoking guarded startup, while the replacement-host/offline assumption is documented but not enforced.

### Top bounded cleanup opportunities

1. Move the lock-file preparation policy into `lib/operations.sh` or a narrowly owned operations dependency.
2. Standardize `require_root()` usage and document its signature.
3. Let dashboard reads reuse a side-effect-free canonical environment value reader.
4. Add a permanent regression for the `setup.sh --force` acknowledgement modes.
5. Add a recovery concurrency contract test or an explicit offline-host preflight.

### Areas that should remain unchanged

1. The local transaction and rollback logic in `recover.sh` should not be replaced by a generic transaction framework.
2. Backup, full restore, emergency restore, and state-volume recovery should remain distinct workflows.
3. Spinner descriptor cleanup should remain local to `lib/log.sh`; forcing the logging library to source the operations library would worsen coupling.
4. CrowdSec email control may retain its specialized transaction and commit-marker protocol.
5. The four public test-suite names should remain stable even when internal cases are reorganized.

### Recommended first PR

A small PR addressing **SCQ-001** and **SCQ-003** only. Both are operator-interface corrections with limited production surface and focused regression requirements.

Another full repository-wide static audit is not warranted until these bounded findings are addressed or a substantial new subsystem is introduced. After closure, effort should move toward Noble production-host acceptance, interruption testing, restore rehearsal, and installed-runtime validation.

## 2. Audit identity and limitations

The audit was pinned to commit `cc3a7a510e1a037a3be0a1da8a919cd25638215a` before the report branch was created.

The review used the GitHub repository API and structured source retrieval. An executable checkout was not available in the audit runtime. A local clone attempt could not resolve `github.com`, so repository commands such as `bash -n`, ShellCheck, the permanent test suites, and `git diff --check` could not be executed locally.

Consequently:

- E1 runtime reproduction was not claimed;
- E2 findings are based on complete visible control flow and directly conflicting current code contracts;
- E3 findings describe exact conditions required to create risk;
- prior pull requests were used only for provenance and deliberate-design context;
- no live installation, service, firewall, backup, restore, CrowdSec, Docker, rclone, SOPS, Age, or systemd operation was executed.

The base branch was not modified. The audit was written on `agent/independent-script-quality-audit-20260717` as one report-only commit.

## 3. Scope and methodology

### Scope

The review covered the repository's primary shell-bearing surfaces:

- public top-level scripts;
- `lib/*.sh` shared libraries;
- `utilities/*.sh` production utilities;
- `tests/run-tests.sh`, `tests/test-architecture.sh`, test helpers, and four suite trees;
- Makefile shell recipes and public targets;
- systemd installation, unit inventory, and installed-runtime copy behavior;
- dashboard command callers;
- Docker/Compose and GitHub Actions command boundaries where they affect shell contracts;
- current architecture, script ownership, project-boundary, operations, security, backup/restore, CrowdSec, email, and test documentation;
- recent helper and transaction provenance.

### Two-pass method

**Pass 1 — public-entry-point tracing.** Public commands were traced toward their owning utilities and libraries. High-risk workflows received deeper review: setup, startup, environment synchronization, secrets, operation guards, systemd installation, backup, restore, recovery, permission repair, CrowdSec email control, and test dispatch.

**Pass 2 — owner-to-caller challenge.** Shared helpers and policies were traced outward to identify bypasses, source-order dependencies, local reimplementations, and false-positive duplication. Similar implementations were challenged against differences in privilege, rollback, interruption, and state ownership before consolidation was recommended.

### Evidence levels

- **E1:** directly reproduced executable behavior;
- **E2:** statically confirmed by all relevant visible paths;
- **E3:** strong risk with an exact trigger condition, but no runtime reproduction;
- **E4:** incomplete investigation lead.

Only E1/E2 items are counted as confirmed defects.

## 4. Repository architecture assessment

The documented architecture substantially matches the implementation:

- `backup.sh` and `restore.sh` are true `exec` dispatchers into `utilities/backup-run.sh` and `utilities/restore-run.sh`.
- `maintenance.sh` dispatches to focused maintenance utilities.
- `edit-secrets.sh` dispatches to focused secret operations.
- `setup.sh` remains a substantial orchestrator, but delegates platform setup, environment generation, storage, secrets, firewall, CrowdSec, and systemd behavior to owning utilities.
- `startup.sh` is larger than a thin dispatcher, but its responsibilities form one coherent lifecycle transaction: environment synchronization, state preflight, permission preparation, secret materialization, network reconciliation, Compose reconciliation, readiness, and health interpretation.
- `lib/operations.sh` provides the dominant concurrency contract.
- `lib/config.sh` provides the dominant environment precedence and atomic environment mutation contract.
- `lib/runtime-permissions.sh` provides the dominant service-specific post-restore permission repair contract.
- backup and restore remain intentionally separate from state-volume recovery.
- installed automation is explicitly copied into `/opt/vaultwarden-scripts` and checked by the systemd setup path.

The codebase is therefore modular by **domain ownership**, not by minimizing file size. This is the appropriate model for the project.

## 5. Scorecard

| Category | Score | Confidence | Rationale |
|---|---:|---|---|
| Architecture and ownership | 8/10 | High | Clear dispatchers and domain owners; lock-file preparation and some policy remain in `common.sh`. |
| Modularity and cohesion | 8/10 | High | Large high-risk workflows are cohesive; `common.sh` has accumulated several unrelated policy families. |
| Reuse and duplication control | 8/10 | High | Recent code generally reuses canonical helpers; remaining duplicates are mostly local transaction boundaries or presentation code. |
| Correctness and failure semantics | 8/10 | Medium-high | Strong typed status and rollback behavior; one confirmed destructive CLI contract mismatch and minor diagnostic misuse. |
| Security and privilege handling | 9/10 | High | Root boundaries, SOPS/Age custody, restrictive temporary state, and operator-owned file preservation are prominent. |
| Concurrency and interruption safety | 8/10 | Medium-high | Shared guard and descriptor isolation are strong; recovery's unguarded promotion remains an explicit risk decision. |
| Idempotence, rollback, state consistency | 9/10 | High | Backup, restore, recovery, CrowdSec, and env synchronization use bounded local transactions and validation. |
| Operational efficiency | 8/10 | Medium | No material algorithmic inefficiency found; some repeated parsing/scanning is acceptable at this deployment scale. |
| Testability and regression coverage | 9/10 | High | Four coherent suites and extensive negative/interruption tests; several identified interface drifts lack focused tests. |
| Documentation and operator-interface consistency | 8/10 | High | Documentation is extensive and generally aligned; `--force`, root hints, and dashboard parsing show bounded drift. |
| **Total** | **83/100** | **High for static architecture; medium for live behavior** | **Healthy with bounded cleanup opportunities.** |

## 6. Script and implementation ownership map

### Public entry points

| Entry point | Actual role | Assessment |
|---|---|---|
| `setup.sh` | installation orchestrator and phase dispatcher | Cohesive but large; delegates core implementation correctly. |
| `startup.sh` | lifecycle transaction | Large but cohesive; correct owner for end-to-end startup behavior. |
| `maintenance.sh` | maintenance dispatcher | Thin and appropriately stable. |
| `backup.sh` | `exec` dispatcher | Exemplary thin entry point. |
| `restore.sh` | `exec` dispatcher | Exemplary thin entry point. |
| `edit-secrets.sh` | secret-operation dispatcher | Thin; sources common facilities for diagnostics/version. |
| `recover.sh` | replacement-host state recovery transaction | Intentionally specialized; should not be collapsed into restore. |
| `dashboard.sh` | interactive operator UI | Large presentation layer; mostly delegates mutation to public commands. |
| `caddy/entrypoint.sh` | container-specific startup | Correctly component-local. |

### Canonical policy owners

| Policy | Current owner | Assessment |
|---|---|---|
| environment precedence and loading | `lib/config.sh` | Clear owner; source-time override capture is an implicit API. |
| atomic `.env` mutation | `lib/config.sh::_set_env_var` | Robust canonical helper. |
| operation serialization and metadata | `lib/operations.sh` | Strong owner, except lock-file creation policy is external/optional. |
| root checks and general shell helpers | `lib/common.sh` | Canonical, but signature is insufficiently explicit to callers. |
| logging and spinner lifecycle | `lib/log.sh` | Cohesive; standalone design is valuable. |
| backup semantics | `utilities/backup-run.sh` + `lib/backup-utils.sh` | Appropriate split. |
| restore semantics | `utilities/restore-run.sh` | Large but appropriate local transaction owner. |
| state-volume recovery | `recover.sh` | Correctly separate from ordinary restore. |
| runtime permission repair | `lib/runtime-permissions.sh` + known-path policy in `lib/common.sh` | Effective but ownership boundary is slightly diffuse. |
| installed runtime/systemd | `utilities/setup-systemd.sh` | Clear and extensively validated. |
| CrowdSec email transaction | `utilities/crowdsec-email.sh` + `utilities/setup-crowdsec.sh` | Specialized transaction is justified. |
| test inventory | `tests/run-tests.sh` | Stable four-suite public surface. |

## 7. Duplicate and near-duplicate implementation analysis

### Consolidation candidates

| Behavior | Implementations | Disposition |
|---|---|---|
| lock-file preparation | `lib/common.sh::_ensure_lock_file`; fallback in `lib/operations.sh::_operation_try_lock_into`; precreation list in `utilities/setup-systemd.sh` | Consolidate **policy ownership** in operations; keep setup-systemd precreation as installation enforcement. |
| environment value reading | `lib/config.sh::_read_env_value`; `utilities/env-edit.sh::_read_repo_env_value`; `dashboard.sh::_read_env_var`; `recover.sh::read_env_value` | Reuse canonical semantics where side effects are not required. Retain recovery-specific manifest parsing if its stricter grammar is intentional. |
| root diagnostics | `lib/common.sh::require_root`; local root wrappers/messages | Fix helper signature/caller use rather than adding another helper. |
| known-path permission checks | `lib/common.sh` policy tables; `lib/runtime-permissions.sh`; `utilities/repair-permissions.sh` reporting wrappers | Keep layered ownership, but document that `common.sh` owns known private paths and runtime-permissions owns recursive service trees. |

### Intentional specialization—not duplication to remove

1. `recover.sh::atomic_set_env` is part of a multi-file staged recovery generation. Replacing it mechanically with the general `_set_env_var` helper would not remove the need for recovery-local staging and rollback.
2. `utilities/crowdsec-email.sh::write_flag` participates in a wrapper/setup commit-marker handshake and must preserve its transaction semantics.
3. Spinner descriptor cleanup in `lib/log.sh` duplicates the concept of `operation_run_without_guard_fds`, but the logging library is intentionally standalone and must not acquire an operations dependency.
4. Backup verification and restore verification share cryptographic/file-integrity mechanics but have different success and destructive-boundary contracts.
5. Runtime permission repair and startup's narrow directory preparation should not be collapsed into one broad recursive permission function.

## 8. Modularity, coupling, and implicit APIs

### Strengths

- High-risk workflows keep local rollback state near the mutations it protects.
- Public dispatchers preserve stable operator interfaces without duplicating implementation.
- Tests frequently invoke full entry points as well as extracted functions.
- systemd validation checks both repository and installed-runtime surfaces.
- generated command documentation limits hand-maintained grammar drift.

### Bounded weaknesses

`lib/common.sh` currently owns several unrelated policy families: general shell utilities, root handling, permission tables, operation lock-file preparation, rclone ownership behavior, cleanup registration, HTTP/download helpers, and entropy waiting. This has not yet become an unmaintainable framework, but it creates owner ambiguity. The solution is **not** a broad split. Only policy with a clear existing owner should move—for example, lock preparation into operations.

`lib/config.sh` captures selected caller overrides at source time (`lib/config.sh:22-28`). This is an implicit source-order contract: an entry point must set overrides before the first source of config. The current canonical source blocks mostly respect this. Future agents should not set those overrides later and assume `load_project_environment()` will preserve them.

`lib/runtime-permissions.sh` intentionally relies on `get_config_value`, `fix_known_path_permissions`, and logging functions supplied by its caller. That dependency is currently explicit in owning callers but should remain covered by source-order tests.

## 9. Efficiency analysis

No material performance defect was confirmed.

The repository invokes external tools frequently because it is an orchestration system. Most calls occur during setup, maintenance, backup, restore, or 60-second dashboard refreshes, where clarity and correctness dominate micro-optimization.

Observations:

- Dashboard backup discovery scans the configured backup tree on redraw. This is acceptable for the small-team retention model, but could become visible with very large remote/local histories.
- Startup performs multiple filesystem permission and readiness passes. These are operationally justified and bounded by a small state tree, except recursive log normalization should remain monitored.
- systemd validation computes hashes and checks multiple unit lists. This is desirable drift detection, not waste.
- backup/restore use temporary copies to establish verified transaction boundaries; reducing those copies without measured storage pressure would weaken reasoning.
- environment parsing is repeated across a few read-only surfaces; the primary cost is semantic drift, not CPU time.

No cache, daemon, database, or new language is warranted.

## 10. Security, privilege, concurrency, and interruption

### Security and privilege

The codebase consistently treats root-operated mutation as the production contract. SOPS/Age key distinctions, temporary secret cleanup, permission normalization, and operator-owned file preservation are prominent.

A recurring strength is that help/version paths are usually handled before root enforcement. Direct script paths, not only Make wrappers, generally enforce privilege.

The main privilege weakness is diagnostic rather than authorization: callers misuse the shared root helper's argument contract, documented in SCQ-003.

### Concurrency

`lib/operations.sh` provides global and operation-specific locks, typed non-interactive contention, owner verification, interruption metadata, and child-descriptor isolation. Recent lock inheritance hardening is reflected in both `operation_run_without_guard_fds()` and spinner cleanup.

The principal open design decision is recovery. `recover.sh` stages and promotes secrets, a new operational key, SOPS policy, installed environment, recovery manifest, sentinel state, and repository `.env` before guarded startup begins. The documented replacement-host workflow reduces expected overlap but does not technically prevent it. See SCQ-005.

### Idempotence and rollback

The codebase is unusually strong for Bash in this area:

- atomic same-directory promotion is common;
- prior existence and metadata are often preserved;
- local transaction state distinguishes promotion from commit;
- signal cleanup is scoped;
- backup verification is part of success;
- restore separates preflight, destructive boundaries, promotion, startup, and final health;
- CrowdSec reconciliation protects operator-owned files;
- environment sync fails closed on detached configured storage.

These local transactions should remain local rather than being folded into a generic transaction framework.

## 11. Public command, documentation, and installed-runtime consistency

Public command grammar is generally well defended by generated references and tests. The primary confirmed grammar mismatch is `setup.sh --force`.

Installed runtime is explicitly acknowledged as separate from the Git checkout. `utilities/setup-systemd.sh` owns copies under `/opt/vaultwarden-scripts`, installed environment/key files under `/etc/vaultwarden`, unit installation, start policy, and validation. This is a strong architecture choice.

The systemd installer necessarily contains explicit unit and lock-file cohorts. These are policy assertions at an installation boundary, not automatically harmful duplication. They should be protected by drift tests rather than replaced by a registry.

## 12. Test architecture assessment

The four public suites—foundation, security, operations, and data-protection—form a coherent stable interface. Test cases are physically separated enough to preserve independent timeout/failure boundaries.

Strengths include:

- direct entry-point tests;
- static contract checks combined with behavioral harnesses;
- signal and rollback injection;
- lock descriptor tests;
- read-only checkout runner tests;
- systemd verification where available;
- generated-document drift checks;
- explicit platform skips.

Gaps relevant to this report:

- no focused regression currently prevents the `setup.sh --force` help/gate contradiction;
- no test establishes the exact argument contract of `require_root()` across callers passing prose versus command arguments;
- dashboard environment parsing is not tested against quoted values accepted by `lib/config.sh`;
- recovery tests cover transaction rollback deeply but do not establish a shared-operation/offline-host concurrency contract.

## 13. Confirmed findings

### SCQ-001 — `setup.sh --force` advertises alternative acknowledgements but requires both

**Severity:** Medium  
**Evidence:** E2 — statically confirmed  
**Confidence:** High

**Affected code:** `setup.sh:105-112`, `setup.sh:267-286`

The help states that the operator may set `VW_FORCE_ACK=I_UNDERSTAND_LOSING_OLD_BACKUPS` **or** answer at the interactive prompt. The implementation first exits with status 2 when the environment acknowledgement is missing. Only after that check succeeds does an interactive TTY receive the `Type YES` prompt.

Therefore the interactive path requires both mechanisms, contrary to the advertised contract.

**Impact:** This fails safely and does not increase destructive risk, but it makes the documented interactive recovery-kit acknowledgement impossible. Operators following help text are blocked, automation behavior is ambiguous, and tests may not represent the intended safety policy.

**Canonical owner:** `setup.sh` destructive setup gate.

**Recommended correction:** Choose and document one of two explicit policies:

- environment token for non-interactive runs and `YES` prompt as the alternative for interactive runs; or
- environment token plus prompt as deliberate two-factor acknowledgement.

The current wording strongly indicates the first policy. Implement it locally in `setup.sh`; do not add an acknowledgement framework.

**Tests:** Interactive missing-token/YES success, interactive NO refusal, non-interactive missing-token refusal, non-interactive valid-token success, and dry-run exemption.

**Non-goals:** Do not weaken recovery-kit warnings or let `--force` bypass the operation guard.

### SCQ-002 — Operation lock-file policy changes depending on source order

**Severity:** Medium  
**Evidence:** E2 — statically confirmed  
**Confidence:** High

**Affected code:** `lib/common.sh:438-495`, `lib/operations.sh:166-181`, `utilities/setup-systemd.sh:443-490`

`lib/common.sh::_ensure_lock_file()` defines the intended runtime policy: `root:vaultwarden`, mode `0660`, with a pre-setup fallback and actionable diagnostics. `lib/operations.sh::_operation_try_lock_into()` uses that policy only when the function happens to be defined. Otherwise it independently creates the parent and file and applies mode `0600`.

This means the operations subsystem's behavior depends on whether `lib/common.sh` was sourced before `lib/operations.sh`. The operation guard is documented as being owned by `lib/operations.sh`, but one of its core security/availability policies is optional and externally supplied.

`utilities/setup-systemd.sh` also precreates a known lock cohort as `root:vaultwarden 0660`; that is appropriate installation enforcement, but it highlights the intended policy difference from the operations fallback.

**Impact:** A standalone or differently ordered operations caller can create a root-only lock file. Later non-root/shared-group callers may fail to open the same lock and report contention or permission failures inconsistent with the production design.

**Canonical owner:** `lib/operations.sh`.

**Recommended correction:** Move the narrow lock-file preparation function into `lib/operations.sh`, or make operations explicitly source a narrowly owned dependency. Keep setup-systemd's cohort creation as installation-time enforcement. Do not create a registry or generic lock framework.

**Tests:** Source `operations.sh` standalone and after `common.sh`; assert identical lock mode/ownership policy and failure diagnostics.

**Non-goals:** Do not infer lock ownership from pathname existence, delete old lock files, or alter the current `flock` architecture.

### SCQ-003 — Some callers pass prose to `require_root()` as though it accepts a custom message

**Severity:** Low  
**Evidence:** E2 — statically confirmed  
**Confidence:** High

**Affected code:** `lib/common.sh:148-154`, `startup.sh:121-125`, `utilities/env-edit.sh:283-285`

`require_root()` always prints a generic error, then appends every argument to a generated command hint:

```text
Re-run with: sudo <caller> <arguments>
```

This works for callers such as `require_root "$command"`. Other callers pass a complete English sentence, expecting it to replace the error message. The resulting hint treats the sentence as shell arguments, producing a command that cannot be executed as written.

**Impact:** Authorization still fails correctly, but operator remediation is misleading on supported direct entry points.

**Canonical owner:** `lib/common.sh::require_root` and its callers.

**Recommended correction:** Document and enforce one signature. The smallest change is to keep arguments as command arguments and update prose callers to call `require_root` with actual CLI arguments or no argument. A custom-message option may be added only if multiple current callers need it and it remains unambiguous.

**Tests:** Non-root invocation should assert the exact recommended command for startup, env sync, and CrowdSec email subcommands.

### SCQ-004 — Dashboard environment parsing does not follow the accepted quoted-value grammar

**Severity:** Low  
**Evidence:** E2 — statically confirmed  
**Confidence:** High

**Affected code:** `dashboard.sh:32-54`, `lib/config.sh:104-120`, `utilities/env-edit.sh:118-127`

The canonical environment loader accepts values surrounded by single or double quotes and strips those quotes. The environment editor's read-only helper does the same. Dashboard's `_read_env_var()` performs `grep | cut | head` and returns the raw value.

A valid line such as:

```text
PROJECT_STATE_DIR="/var/lib/vaultwarden"
```

is interpreted by the canonical loader as `/var/lib/vaultwarden`, but dashboard stores the quote characters in `STATE_DIR`. The same applies to `BACKUP_DIR`, `TZ`, and `RCLONE_REMOTE_NAME`, causing incorrect filesystem checks or display behavior.

**Impact:** Bounded operator-UI inconsistency. Production mutation remains delegated to canonical scripts.

**Canonical owner:** side-effect-free environment value semantics in `lib/config.sh`.

**Recommended correction:** Reuse or expose a side-effect-free canonical value reader with quote handling. Do not source and apply the entire environment solely to draw the dashboard.

**Tests:** Dashboard status with unquoted, single-quoted, and double-quoted state, backup, timezone, and rclone values.

## 14. Strong risk requiring an explicit design decision

### SCQ-005 — Recovery promotion is outside the shared operation guard

**Severity:** Medium risk  
**Evidence:** E3 — strong risk  
**Confidence:** Medium-high

**Affected code:** `recover.sh:1-18`, `recover.sh:96-137`, `recover.sh:387-455`, `recover.sh:539-555`, `lib/operations.sh:868-900`

`recover.sh` does not source `lib/operations.sh`, acquire the global guard, or register a recovery operation. Before invoking `startup.sh`, it can promote:

- encrypted SOPS state;
- a new operational Age key;
- `.sops.yaml` policy;
- persistent `install.env`;
- the recovery manifest;
- the data-volume sentinel;
- repository `.env`.

The workflow is documented as replacement-host recovery and requires the exact repository commit from the manifest. That context may intentionally assume an offline host on which timers and other mutating workflows are not active.

**Trigger condition:** An operator invokes `recover.sh` on a host where a backup, environment sync, secret/key operation, setup/systemd operation, or timer-managed task can run concurrently before recovery reaches guarded startup.

**Potential impact:** Competing workflows can observe or alter a partially promoted recovery generation. The recovery-local rollback protects its own writes but cannot roll back another concurrent process.

**Recommended decision:** Choose one explicit contract:

1. **Offline replacement-host only:** enforce that managed services/timers are absent or inactive and fail before staging/promotion when the host is operational; document why no operation guard is needed.
2. **May run on an initialized host:** acquire the shared operation guard before backup/staging and register `recover` in operation status and installed lock preparation.

Do not add a recovery daemon, database, or generic transaction framework.

**Required validation:** A focused test proving either the offline-host refusal boundary or shared-guard serialization. Production-host recovery rehearsal remains necessary.

## 15. Informational observations and guardrails

### INFO-001 — `common.sh` is approaching an ownership threshold

It is not yet a reason for a broad split. Future policy should move into it only when no clearer owner exists. Lock preparation already has a clearer owner and is the highest-value extraction.

### INFO-002 — Source-time configuration override capture is intentional but fragile

`lib/config.sh:22-28` captures selected caller overrides once. Entry points must set those values before first sourcing config. Add tests when changing source order; do not add more implicit override variables casually.

### INFO-003 — Explicit systemd cohorts are acceptable duplication

Timer, service, root-required, writable-path, and lock-file lists represent different systemd boundary assertions. A generic registry would increase complexity. Protect alignment with tests and generated validation instead.

### INFO-004 — High line counts do not imply poor modularity

`startup.sh`, `utilities/restore-run.sh`, `utilities/setup-systemd.sh`, and `utilities/setup-crowdsec.sh` are large because they own safety-critical end-to-end workflows. Split only when a stable policy owner and compatible transaction boundary are demonstrated.

## 16. Change-impact scenarios

| Hypothetical change | Current impact | Maintainability assessment |
|---|---|---|
| Change canonical runtime path | defaults/config, systemd templates/installer, docs/tests, permission contracts | Manageable but requires cross-surface validation. |
| Add non-secret environment key | `.env.example`, config consumers, env sync/status, docs/generated reference | Clear workflow; dashboard may require local update if displayed. |
| Add secret with apply action | schema, secret utilities, owning apply path, docs/tests | Strong schema ownership; moderate but explicit. |
| Add health check | maintenance-health owner, result aggregation, tests/docs | Coherent owner; avoid new top-level helper. |
| Change shared exit code | owning workflow, Make/systemd callers, aggregation, tests/docs | High cross-surface risk; current tests help. |
| Add systemd-managed operation | utility, unit/timer, installer cohorts, `/opt` copy validation, lock/status lists | Explicit but manually distributed; tests are essential. |
| Change backup naming | backup creation, inventory, retention, remote sync, restore discovery, tests/docs | High-risk cohort change; clear owners exist. |
| Change runtime permission | common known-path policy or runtime-permissions tree, health/setup/systemd writable paths, tests/docs | Distributed by necessary system boundaries. |
| Add CrowdSec reconciliation setting | `.env`, setup/reconciler, health/status, docs/tests | Strong local owner; preserve operator files. |
| Deprecate Make target | Makefile, dashboard, docs, generated reference, compatibility tests | Bounded when callers are searched first. |

## 17. Architectural invariant matrix

| Invariant | Owner | Enforcement | Confidence |
|---|---|---|---|
| privileged mutation requires root | entry points + `lib/common.sh` | direct checks before mutation | High |
| conflicting mutation is serialized | `lib/operations.sh` | global/specific `flock` and metadata | High, except recovery decision |
| lock pathname age is not authoritative | `lib/operations.sh` / common lock prep | kernel `flock` checks | High |
| secret state is encrypted persistently | SOPS/Age secret owners | encrypted state + transient runtime files | High |
| backup success requires verification | backup owner | verifier gates success/retention | High |
| restore preflights before destructive mutation | restore owner | selected archive/storage/key checks | High |
| operator-owned config is preserved | setup/CrowdSec/restore owners | marked blocks, staging, rollback | High |
| help/version should be side-effect free | public entry points | early dispatch | High |
| installed runtime must be validated after Git changes | setup-systemd | copy/hash/unit/env validation | High |
| timeout/EOF fails safely | operator confirmation owners | bounded reads and explicit outcomes | High |

## 18. Recommended bounded PR sequence

### PR 1 — Correct operator contract drift

**Findings:** SCQ-001, SCQ-003  
**Expected files:** `setup.sh`, `lib/common.sh` only if signature clarification is required, affected callers, focused foundation/security tests, generated command reference if help changes.  
**Files that should not change:** backup, restore, CrowdSec transactions, systemd architecture.  
**Risk:** Small.  
**Rollback:** Revert the focused commit.  
**Review complexity:** Small.

### PR 2 — Put lock-file preparation under operations ownership

**Finding:** SCQ-002  
**Expected files:** `lib/operations.sh`, `lib/common.sh`, focused operation/permission tests, possibly setup-systemd assertions.  
**Files that should not change:** operation acquisition semantics, exit 75 behavior, stale metadata handling.  
**Risk:** Medium because lock permissions affect systemd and interactive callers.  
**Rollback:** Restore prior function location/fallback.  
**Review complexity:** Medium.

### PR 3 — Align dashboard environment reads

**Finding:** SCQ-004  
**Expected files:** `dashboard.sh`, possibly `lib/config.sh`, operator UI tests.  
**Risk:** Small.  
**Rollback:** Restore local parser.  
**Review complexity:** Small.

### PR 4 — Decide and enforce recovery concurrency contract

**Finding:** SCQ-005  
**Expected files:** `recover.sh`, `lib/operations.sh` and operation/systemd cohorts only if shared guard is chosen, recovery tests, disaster-recovery documentation.  
**Risk:** Medium-high; requires production-model decision before implementation.  
**Rollback:** Revert contract enforcement.  
**Review complexity:** Medium.

## 19. Future helper decision gate

Before adding a helper, require affirmative evidence for these questions:

1. What existing function or module owns this policy?
2. Can the owner or callers be corrected instead?
3. Is the behavior genuinely shared rather than textually similar?
4. Are success, failure, privilege, rollback, and interruption contracts compatible?
5. Does the helper have a stable domain contract?
6. Does it reduce conceptual complexity rather than only line count?
7. Does it avoid new globals and source-order dependencies?
8. Can tests protect both owner and caller boundaries?
9. Is a local function clearer and safer?
10. Is no helper the better solution?

A new shared helper should normally require at least two current production callers with compatible contracts. Do not extract a generic function that immediately needs mode flags to reconstruct separate workflows.

## 20. Validation performed

Performed through the connected GitHub repository at the pinned SHA:

- confirmed repository and `delta` ref;
- captured exact audited SHA;
- read current `AGENTS.md` and authoritative architecture/script documentation;
- traced public entry points and high-risk implementations;
- reviewed current shared libraries and source relationships;
- inspected current test contracts and recent helper provenance;
- created a dedicated branch from the exact audited SHA;
- created exactly one report file on that branch;
- changed no production code.

## 21. Validation not performed

Not performed because an executable checkout was unavailable in the audit runtime:

```text
bash -n over all shell files
ShellCheck
./tests/run-tests.sh list
./tests/run-tests.sh foundation
./tests/run-tests.sh security
./tests/run-tests.sh operations
./tests/run-tests.sh data-protection
./tests/run-tests.sh all
git diff --check
Docker Compose validation
systemd-analyze verify
```

No live-host setup, systemd installation, firewall mutation, CrowdSec reconciliation, backup, restore, recovery, key rotation, rclone transfer, or email delivery test was performed.

CI on the report-only pull request may validate repository-wide non-destructive checks, but this report does not pre-claim those results.

## 22. Final verdict

VaultWarden-OCI's script codebase is **healthy with bounded cleanup opportunities**.

The repository has more evidence of deliberate local safety boundaries than of helper sprawl. Recent development has generally moved generic policy toward canonical owners while preserving specialized recovery, restore, backup, and CrowdSec transactions. The remaining issues are narrow ownership and interface inconsistencies, not architectural collapse.

The correct response is a small number of focused PRs—not a consolidation sprint, framework extraction, language rewrite, or broad file reorganization.

## Appendix A — Primary shell-bearing inventory

### Public/component entry points

- `backup.sh`
- `dashboard.sh`
- `edit-secrets.sh`
- `maintenance.sh`
- `recover.sh`
- `restore.sh`
- `setup.sh`
- `startup.sh`
- `caddy/entrypoint.sh`

### Shared libraries

- `lib/backup-utils.sh`
- `lib/common.sh`
- `lib/config.sh`
- `lib/crowdsec-worker.sh`
- `lib/crypto.sh`
- `lib/defaults.sh`
- `lib/docker.sh`
- `lib/email.sh`
- `lib/log.sh`
- `lib/maintenance-utils.sh`
- `lib/migrate.sh`
- `lib/operations.sh`
- `lib/runtime-permissions.sh`
- `lib/schema.sh`
- `lib/secrets.sh`
- `lib/storage.sh`
- `lib/validate.sh`

### Production utilities

- `utilities/backup-run.sh`
- `utilities/crowdsec-email.sh`
- `utilities/crowdsec-worker-apply.sh`
- `utilities/env-edit.sh`
- `utilities/key-rotate.sh`
- `utilities/maintenance-db-maint.sh`
- `utilities/maintenance-email.sh`
- `utilities/maintenance-health.sh`
- `utilities/maintenance-run.sh`
- `utilities/maintenance-update-dns.sh`
- `utilities/maintenance-update-firewall.sh`
- `utilities/maintenance-update.sh`
- `utilities/notify-failure.sh`
- `utilities/operations-status.sh`
- `utilities/pre-production-drill.sh`
- `utilities/repair-permissions.sh`
- `utilities/restore-run.sh`
- `utilities/safe-restart.sh`
- `utilities/secrets-edit.sh`
- `utilities/secrets-export-recovery-kit.sh`
- `utilities/secrets-list.sh`
- `utilities/secrets-rotate.sh`
- `utilities/secrets-view.sh`
- `utilities/setup-crowdsec.sh`
- `utilities/setup-env.sh`
- `utilities/setup-firewall.sh`
- `utilities/setup-secrets.sh`
- `utilities/setup-storage.sh`
- `utilities/setup-system.sh`
- `utilities/setup-systemd.sh`
- `utilities/smoke-test.sh`
- `utilities/uninstall-vaultwarden.sh`
- `utilities/write-command-reference.sh`

### Test shell surfaces

- `tests/run-tests.sh`
- `tests/test-architecture.sh`
- `tests/lib/test-root.bash`
- `tests/suites/foundation/case-config-env.bash`
- `tests/suites/foundation/case-permissions.bash`
- `tests/suites/foundation/case-runner-contracts.bash`
- `tests/suites/foundation/case-storage-setup.bash`
- `tests/suites/foundation/case-systemd.bash`
- `tests/suites/security/case-email.bash`
- `tests/suites/security/case-secrets.bash`
- `tests/suites/security/case-security-privileges.bash`
- `tests/suites/operations/case-crowdsec.bash`
- `tests/suites/operations/case-crowdsec-notifications.bash`
- `tests/suites/operations/case-lifecycle.bash`
- `tests/suites/operations/case-lock-fd-hygiene.bash`
- `tests/suites/operations/case-operations.bash`
- `tests/suites/operations/case-operator-ui.bash`
- `tests/suites/operations/case-uninstall.bash`
- `tests/suites/data-protection/case-backup.bash`
- `tests/suites/data-protection/case-restore-recovery.bash`

Additional shell command surfaces exist in the Makefile, systemd units, Docker/Compose definitions, GitHub Actions, templates, and generated command documentation; they were treated as callers and contract boundaries rather than independent shell modules.

## Appendix B — Finding summary

| ID | Severity | Evidence | Confidence | Domain | Canonical owner | Recommended action | Scope |
|---|---|---|---|---|---|---|---|
| SCQ-001 | Medium | E2 | High | setup CLI safety | `setup.sh` | align acknowledgement modes/help/tests | Small |
| SCQ-002 | Medium | E2 | High | operation locking | `lib/operations.sh` | own lock-file preparation unconditionally | Medium |
| SCQ-003 | Low | E2 | High | privilege diagnostics | `lib/common.sh` + callers | clarify signature and correct callers | Small |
| SCQ-004 | Low | E2 | High | dashboard/config | `lib/config.sh` semantics | reuse side-effect-free canonical reader | Small |
| SCQ-005 | Medium risk | E3 | Medium-high | recovery concurrency | `recover.sh` / operations contract | enforce offline-only or acquire guard | Medium |
