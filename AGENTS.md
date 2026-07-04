# AGENTS.md — VaultWarden-OCI Independent Operator-Safety Review

## Purpose

This agent session is an independent, read-only post-implementation review of recent operator UI and operator-safety changes in VaultWarden-OCI.

The review follows PRs #219, #220, and #221 and the closure of:

```text
reports/operator-ui-preliminary-scan.md
```

The prior report and those PRs are evidence and historical context.

They are not ground truth.

Assume the previous audit may have been competently implemented but may still contain:

* incomplete assumptions
* missed execution paths
* semantic regressions
* overly narrow findings
* tests that validate source text without validating behavior
* final status messages that do not truthfully represent runtime state

The objective is not to confirm that the prior report was completed.

The objective is to independently determine whether the current `delta` branch still contains meaningful operator-safety problems or regressions that the original scan and PRs #219–#221 missed.

---

## Project context

VaultWarden-OCI is a small-team, self-hosted Vaultwarden deployment for Oracle Cloud Infrastructure on Ubuntu.

The intended production environment is a small workgroup of approximately 10 users.

The primary operator may be a junior Linux or Docker administrator.

The system is intended to be largely "set and forget" and may only receive close operator attention during an incident, restore, recovery, key operation, or maintenance event.

Project priorities, in order:

1. Security
2. Reliable backup, restore, and disaster recovery
3. Truthful and clear operator guidance
4. Simple junior-operator workflows
5. Minimal moving parts
6. Avoid enterprise-style complexity unless clearly justified

A few hours of downtime may be acceptable.

Silent data loss, misleading recovery success, lost key custody, incomplete backups presented as complete, or operator guidance that causes an unsafe action are not acceptable.

---

## Branch and review baseline

Primary working branch:

```text
delta
```

Historical review baseline:

```text
reports/operator-ui-preliminary-scan.md
```

Relevant implementation sequence:

```text
PR #219
PR #220
PR #221
```

PR #219 addressed the first concrete operator-safety findings.

PR #220 introduced a deliberately small shared operator UI helper layer and selectively adopted it.

PR #221 performed a closure pass, addressed remaining selected observations, and recorded intentional limitations in the preliminary report.

Read the current preliminary report first, including:

```text
# Implementation Status
## Remaining Observation Resolution
## Closure Conclusion
```

Inspect the current `delta` implementation after reading the report.

Use PRs #219–#221 and relevant git history to understand why code changed.

Do not simply walk the report finding-by-finding and mark each item complete.

The report is prior evidence, not the audit checklist.

---

## Review mode: read-only

This is a report-only audit.

Do not modify functional code.

Do not fix findings.

Do not refactor scripts.

Do not rewrite documentation.

Do not regenerate generated files unless required only to validate drift; restore any generated output before finishing.

Do not create a pull request.

The only intended repository change is the new review report:

```text
reports/operator-ui-independent-post-closure-review.md
```

Code changes proposed in the report are suggestions only.

Provide practical remediation snippets or minimal pseudodiffs, but do not apply them.

---

## Architecture and operational invariants

Preserve these assumptions unless direct current-code evidence demonstrates a defect.

### Privilege model

Lifecycle and maintenance are root-operated.

Commands such as:

```text
sudo make up
sudo make restart
```

are expected.

Do not recommend converting the project back to a normal-user-operated lifecycle merely for convention.

### Secrets model

SOPS + Age is the intended secrets model.

The live operational Age private key is distinct from the offline recovery Age key.

The offline recovery Age private key must never be stored persistently on the server.

Runtime Docker secrets are staged under:

```text
/run/vaultwarden-oci/secrets
```

Persistent state normally resides under:

```text
/var/lib/vaultwarden
```

Do not weaken key-custody warnings, explicit save acknowledgements, or exact-token gates.

### Backup model

Backup tiers are:

```text
db
full
emergency
```

Emergency backups may contain sensitive recovery material and require independent protection.

The project expects a 3-2-1 backup strategy.

Do not assume that "archive created" means:

* verified
* synced offsite
* restorable
* complete disaster recovery coverage

Those states must be distinguished where operator output claims them.

### Security model

Cloudflare and CrowdSec are intentional components.

Do not recommend removing them merely to simplify the stack.

### Scope model

This is a small deployment.

Do not recommend:

* plugin frameworks
* provider registries
* generalized terminal UI frameworks
* broad command frameworks
* new services
* large dependency additions
* enterprise orchestration

unless a demonstrated current defect cannot reasonably be solved with a narrow change.

---

## Existing operator UI direction

The current branch contains shared helpers including:

```text
operator_attention
operator_confirm_yes_no
operator_next_steps
```

Existing exact typed confirmations may include tokens such as:

```text
YES
UNINSTALL
DELETE-BACKUPS
SAVED
VW_FORCE_ACK
DATA_VOLUME_FORCE_FORMAT
DATA_VOLUME_EXISTING_FS_OK
```

Do not assume visual uniformity is more important than safety.

Ordinary reversible choices may use explicit `yes/no` prompts.

Irreversible deletion, destructive format, key-loss, key-custody, and comparable high-consequence actions may intentionally use exact typed acknowledgements.

Do not raise a finding merely because a specialized confirmation does not use the shared helper.

There must be a real operator-safety, semantic, reliability, or truthfulness problem.

---

## Primary review questions

Independently answer the following.

### 1. Were PRs #219–#221 semantically appropriate?

Inspect the implemented behavior rather than only the PR descriptions.

Look for changes to:

* return codes
* control flow
* `set -e` interactions
* cancellation semantics
* EOF handling
* blank input
* invalid input
* timeout behavior
* TTY checks
* stdout versus stderr
* quiet or JSON output
* automation paths
* `--force`
* dry-run or inspect behavior
* service stop/start sequencing
* health-check interpretation

A UI helper conversion must not silently alter a stronger existing safety contract.

### 2. Did the new shared helper layer introduce subtle problems?

Review the helpers and their call sites.

Specifically consider:

```text
operator_attention
operator_confirm_yes_no
operator_next_steps
```

Inspect interactions with:

```text
_should_log
LOG_LEVEL
LOG_COLORS
TTY detection
stdin
stdout
stderr
set -e
set -u
set -o pipefail
command substitution
pipelines
functions used in conditional expressions
```

Ask whether helper return codes can accidentally terminate a script or change behavior depending on caller context.

Ask whether messages can disappear because of logging level even when operator action is required.

Ask whether prompts can run in paths intended to be machine-readable or non-interactive.

Do not invent a theoretical issue. Trace a realistic execution path.

### 3. Did the original scan miss an adjacent high-risk operator flow?

Prioritize:

```text
backup
restore
recover
Age key rotation
secrets setup or rekey
storage setup or migration
break-glass operations
maintenance that stops or restarts services
host and container update paths
destructive Make targets
final health or success reporting
```

Use targeted inspection.

Do not re-audit every shell file from scratch.

Follow call graphs and shared helpers where evidence points.

### 4. Are final status messages truthful?

This is a primary audit theme.

Search for execution paths resembling:

```text
operation partially failed
    ->
final output says success
```

Examples to challenge:

* health check failed but service described as running or healthy
* backup archive exists but verification failed
* offsite sync failed or was skipped but backup protection is implied complete
* restart command returned but service health was not checked
* disaster-recovery material was skipped but summary implies independent recovery protection
* a restore or recovery step partially promoted state but final output presents complete success
* notification failed but operator is told alerting is configured
* required manual Cloudflare or CrowdSec action remains but setup is described as fully complete

Distinguish:

```text
created
promoted
configured
started
running
healthy
verified
synced
restorable
complete
```

These are not interchangeable states.

### 5. Do tests validate behavior strongly enough?

Review tests added or changed around PRs #219–#221.

Source-pattern and `grep` policy tests are allowed and can be useful.

However, ask whether a dangerous regression can occur while the test remains green.

Look for tests that prove only:

```text
a helper call exists
a string exists
a success phrase is absent from source
a particular literal command appears
```

when the important contract is runtime behavior.

Prefer realistic shell harness tests for high-risk state transitions when existing project patterns make them practical.

Do not demand end-to-end infrastructure testing for every message.

Raise a test-gap finding only when a meaningful current behavior is insufficiently protected.

### 6. Did the closure report make an incorrect assumption?

Challenge the decisions recorded in:

```text
## Remaining Observation Resolution
```

Do not reopen an item merely because another implementation style is possible.

Reopen an item only when current code evidence shows:

* an unsafe execution path
* misleading operator state
* weaker confirmation semantics
* automation regression
* backup/restore/recovery reliability risk
* a practical junior-operator trap

---

## Finding threshold

Be skeptical.

Do not create findings to fill the report.

A clean review with zero Critical, High, or Medium findings is acceptable.

Only call something a finding when there is direct, reproducible, or strongly traceable evidence.

A confirmed finding should normally have:

1. Exact file and function or target
2. Relevant execution path
3. Current behavior
4. Evidence from current code or a focused command
5. Realistic operator impact
6. Explanation of why the preliminary scan or PRs #219–#221 did not already resolve it
7. Narrow suggested remediation
8. Practical code snippet or pseudodiff
9. Focused validation recommendation

Do not raise findings for:

* visual inconsistency alone
* personal wording preference
* script length
* missing abstraction
* duplicated presentation code
* hypothetical unsupported operating systems
* a macOS-only validation limitation when Ubuntu production behavior is unaffected
* enterprise-grade hardening outside this project's threat model
* broad "best practice" claims without a current defect

---

## Severity scale

### Critical

A realistic path to:

* data loss
* secret or private-key exposure
* unrecoverable restore failure
* loss of required recovery material
* major production outage caused by current behavior

### High

A concrete security, backup, restore, recovery, or destructive-operation problem that should be corrected before treating `delta` as production-ready.

### Medium

A real operator-safety, reliability, semantic, or test-protection defect worth correcting soon.

The impact must be practical for this project.

### Low

Minor but worthwhile safety or clarity improvement.

Only include Low findings when unusually useful.

Do not flood the report with polish items.

### Note

Observation or runtime validation limit.

Not a required fix.

---

## Mandatory remediation snippets

Every Critical, High, or Medium finding must include a practical proposed fix.

Do not merely say:

```text
improve error handling
add validation
make the wording clearer
use the helper
add a test
```

Show what should change.

For each Critical, High, or Medium finding include:

```text
### Suggested remediation
```

Then provide:

```text
Target
Suggested change
Why this is minimal
Suggested patch
Validation
```

Preferred format:

````markdown
### Suggested remediation

**Target**

`path/to/file` — `function_name`

**Suggested change**

Briefly describe the narrow behavioral change.

**Why this is minimal**

Explain why this fixes the demonstrated defect without changing unrelated semantics.

**Suggested patch**

```diff
@@
- existing behavior
+ proposed narrow behavior
```

**Validation**

```bash
focused-test-or-command
```
````

The patch does not need to apply byte-for-byte if surrounding current code makes a compact pseudodiff clearer.

However:

* use real current variable names where known
* use real current helper names
* preserve existing project style
* preserve existing operational gates
* do not invent a new framework for a one-call-site issue
* show enough code that another coding agent can understand the intended implementation

When a finding requires a test change, also provide a focused test snippet when practical.

Example:

````markdown
**Suggested regression test**

```bash
test_partial_failure_does_not_report_success() {
    ...
}
```
````

For Low findings, snippets are optional.

For Notes and runtime validation limits, provide a focused validation approach instead of pretending a code fix is confirmed.

Do not apply these snippets to the repository during this review.

---

## Review strategy

Use the following order.

### Phase 1 — establish current state

Record:

```bash
git status --short
git branch --show-current
git rev-parse HEAD
git log --oneline --decorate -20
```

Confirm the review is against current `delta`.

Record the exact commit in the report.

### Phase 2 — read prior evidence

Read:

```text
reports/operator-ui-preliminary-scan.md
```

Pay special attention to its closure section.

Inspect the changes and history associated with PRs #219, #220, and #221.

Build a concise mental map of:

```text
problem
    ->
implemented change
    ->
new helper or call path
    ->
test coverage
```

Do not write a report section that simply repeats all five original UI findings.

### Phase 3 — inspect helper semantics

Review the shared operator helpers in their actual library context.

Identify all current meaningful call sites.

Trace caller behavior.

Pay special attention to prompts used inside:

```bash
if ...
if ! ...
command || ...
set -e
```

and paths with non-TTY stdin.

### Phase 4 — truthful-state audit

Target final status and summary output in high-risk workflows.

Trace the state variable or command result that justifies each important success claim.

Where wording says:

```text
healthy
verified
complete
running
synced
configured
```

confirm the preceding code actually established that state.

### Phase 5 — adjacent missed-item hunt

Use the prior report to avoid repeating already settled cosmetic questions.

Inspect nearby high-risk paths not fully exercised by the original findings.

Follow evidence.

Stop broadening scope when there is no realistic operator impact.

### Phase 6 — test quality review

Map the important behavior changed by PRs #219–#221 to the current regression tests.

Identify only meaningful protection gaps.

Where practical, run focused tests and controlled shell harnesses.

### Phase 7 — report

Create:

```text
reports/operator-ui-independent-post-closure-review.md
```

Do not modify functional code.

---

## Validation expectations

Run checks appropriate to the inspected areas.

At minimum:

```bash
git status --short
git branch --show-current
git rev-parse HEAD
bash -n backup.sh restore.sh startup.sh recover.sh maintenance.sh setup.sh edit-secrets.sh
find utilities lib -name '*.sh' -print0 | xargs -0 bash -n
```

Run the focused tests associated with operator UI, recovery, restore, backup, and privilege behavior when available.

Examples may include:

```bash
tests/test-operator-ui.sh
tests/test-confirmation-prompt-format.sh
tests/test-recover.sh
tests/test-backup-restore-behavior.sh
tests/test-restore-run-followup.sh
tests/test-privilege-contracts.sh
```

Run:

```bash
make test-unit
```

when the environment supports it.

Run focused ShellCheck on inspected or implicated shell files when ShellCheck is installed.

Do not perform a broad `shfmt` rewrite.

Do not alter files simply to make ShellCheck or formatting output quieter.

If a validation command cannot run because:

* a dependency is missing
* Docker is unavailable
* the environment is not Ubuntu
* privileged runtime state is unavailable

record the limitation precisely.

Do not convert the limitation into a confirmed finding.

---

## Report structure

Use this structure:

```markdown
# Independent Operator UI Post-Closure Review

## Executive Summary

## Review Baseline

## Scope and Method

## Prior Closure Decisions Challenged

## Findings

### F-01: ...

Severity:
Confidence:

Affected path:
Execution path:

Current behavior:

Evidence:

Operator impact:

Why the prior scan / PR closure missed this:

Suggested remediation:

Suggested regression test:

Validation:

## Low-Severity Opportunities

## Runtime Validation Limits

## Tests and Commands Run

## Final Assessment
```

If there are no confirmed findings, say so clearly.

Do not manufacture findings.

For each finding, state confidence as:

```text
High
Medium
Low
```

Only Critical, High, and Medium severity items belong in the primary Findings section.

Exceptionally useful Low items may appear under:

```text
## Low-Severity Opportunities
```

Keep that section small.

---

## Final assessment

The report must directly answer:

1. Were the changes in PRs #219–#221 appropriate?
2. Did they introduce a semantic or operator-safety regression?
3. Did the preliminary scan miss any confirmed Critical, High, or Medium issue?
4. Are any closure decisions in the report incorrect based on current code?
5. Are current tests protecting the important behavior rather than only the source wording?
6. Is additional operator UI remediation justified?
7. What exact findings, if any, should be handed to a coding agent?

End with one recommendation:

```text
NO FURTHER UI REMEDIATION NEEDED
```

or:

```text
TARGETED FOLLOW-UP RECOMMENDED
```

or:

```text
BLOCK PRODUCTION-READY STATUS
```

For `TARGETED FOLLOW-UP RECOMMENDED`, list only the finding IDs that should be implemented.

For `BLOCK PRODUCTION-READY STATUS`, identify the blocking finding IDs.

Do not implement the fixes.
