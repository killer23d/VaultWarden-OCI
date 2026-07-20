# Codex implementation brief: health recovery hardening

Repository: `killer23d/VaultWarden-OCI`

Working branch: `agent/harden-health-recovery-follow-up`

Current stacked base: `agent/fix-health-recovery-alerts` (PR #273)

Final target after PR #273 merges: `delta`

## Objective

Create a small, reviewable follow-up that addresses two residual quality risks from PR #273:

1. Remove the brittle `awk` function extraction and `eval` execution used by `tests/suites/operations/case-health-alerts.bash`.
2. Prevent a successfully delivered recovery notification from being sent again when closing or archiving the active incident fails and the normal recovery cooldown later expires.

Use pragmatic small-team engineering: prefer a narrow, understandable design over a framework or broad refactor.

## Required initial inspection

Before editing:

1. Read PR #273 and its final diff.
2. Confirm whether PR #273 has merged.
3. If #273 is still open, keep this PR stacked on `agent/fix-health-recovery-alerts`.
4. If #273 has merged, update this branch onto the latest `delta` and retarget the PR to `delta`.
5. Inspect the complete alert-state lifecycle in `utilities/maintenance-health.sh`, including incident creation, parsing, recovery cooldown acquisition/release, delivery, archive/cleanup, and new-incident creation.
6. Inspect existing test helpers and repository conventions before adding a new helper or library.

Do not copy unrelated commits or alter unrelated health checks.

## Workstream 1: replace the brittle test harness

### Problem

`case-health-alerts.bash` extracts shell functions from `maintenance-health.sh` with `awk` and evaluates them with `eval`. This couples tests to formatting and brace layout, obscures static analysis, and requires `SC2034` suppression for fixture variables.

### Desired outcome

Tests should call the real production functions through a stable, sourceable seam. Formatting-only edits to the production script must not break the test loader.

### Preferred approaches

Choose the smallest approach that fits the repository cleanly:

1. **Preferred when cohesive:** extract only the incident/recovery helpers under test into a small sourceable library, such as `lib/health-alerts.sh`, and source it from both `maintenance-health.sh` and the tests.
2. **Acceptable when smaller:** move only the relevant helper definitions to a source-safe top-level section of `maintenance-health.sh`, guard command execution with the standard Bash direct-execution check, and source the script from tests.

Relevant helpers may include only what is needed for the contract tests, such as:

- `_incident_sanitize`
- `_incident_set_check`
- `_incident_load`
- `_incident_format_duration`
- recovery delivery-state helpers introduced by this PR
- `_notify_recovery`

Bash dynamic scoping may be preserved where already relied upon, but document the required variable contract near the functions or library entry point.

### Constraints

- Do not add a test-only execution mode to production unless there is no cleaner source-safe seam.
- Do not introduce a shell testing framework.
- Do not retain `awk` function extraction or `eval` for these tests.
- Remove no-longer-needed `SC2034` suppressions when static analysis can now see the fixture usage.
- Keep test doubles limited to external side effects such as email delivery, time, hostname, and deliberately simulated filesystem failures.
- Preserve at least one test using the real incident parser and real serialized incident format.
- Reduce duplication and test length where practical, but do not sacrifice behavior coverage merely to reduce line count.

## Workstream 2: make successful recovery delivery idempotent

### Problem

The current sequence sends the recovery email and then moves the active incident to a recovered path. If the email succeeds but the move fails, the active incident remains. The normal cooldown prevents an immediate duplicate, but the same incident can become eligible again after the cooldown expires.

### Required contract

Once `_send_notification` has returned success for incident ID `X`, future health cycles must not send another recovery email for incident `X`, even if active-incident archival or deletion failed.

At the same time:

- A failed email delivery must remain retryable.
- A crashed or abandoned pre-delivery attempt must not suppress recovery forever.
- A genuinely new incident must not be blocked by state from an older incident.
- State must remain bounded, atomic, and restrictive (`0600` for files and existing directory policy for parent directories).
- Logs must distinguish delivery failure, delivery success with cleanup failure, stale pending state, and operator-remediation cases.
- Do not claim strict exactly-once email semantics under total filesystem failure; document the precise guarantee implemented.

### Recommended small-team design

Implement a single bounded, incident-scoped recovery delivery-state file in the existing alert-state directory. Keep the format simple and validated, for example:

- incident ID
- phase: `pending` or `delivered`
- updated timestamp or epoch

Use atomic temporary-file plus rename writes and enforce `0600`.

Expected lifecycle:

1. Load and validate the active incident.
2. Inspect delivery state for that incident.
3. If state is `delivered` for the same incident:
   - do not send again;
   - retry closing/archiving the active incident;
   - retain actionable evidence and logging if cleanup still fails.
4. If state is a recent `pending` lease for the same incident:
   - suppress a concurrent duplicate attempt.
5. If `pending` is stale:
   - treat it as abandoned and permit a retry.
6. Before attempting email, atomically record `pending` for the incident.
7. If email fails:
   - remove or invalidate `pending`;
   - preserve the active incident;
   - return nonzero.
8. If email succeeds:
   - atomically transition the state to `delivered`;
   - then close/archive the active incident;
   - keep `delivered` state if cleanup fails so later cycles cannot resend.
9. When the incident is successfully closed, remove obsolete delivery state when safe.
10. Ensure new incident creation cannot inherit a stale delivered marker for a different incident ID.

If an even smaller design provides the same observable contract and handles abandoned pre-send attempts safely, use it and explain why it is simpler.

Avoid an unbounded file per incident, a database, a daemon, or changes to the SMTP layer.

## Required regression coverage

Keep the suite focused and readable. Cover at minimum:

1. Healthy run without an incident: no delivery state, cooldown, or email.
2. Invalid incident: preserved; no delivery state and no email.
3. Valid incident: one recovery email and normal closure.
4. Email failure: nonzero; pending state cleared; incident retained; next cycle may retry.
5. Recent pending state: concurrent duplicate suppressed.
6. Stale pending state: abandoned attempt may retry.
7. Email success followed by active-incident `mv` failure: delivered state retained; later cycle does not resend; cleanup is retried or actionable warning remains.
8. Email success followed by recovered-file deletion failure: no duplicate; bounded evidence remains.
9. Delivered state for a different incident ID: does not suppress the new incident after normal cooldown rules.
10. Corrupt delivery-state file: handled conservatively with an explicit warning and no silent data loss.
11. Real parser coverage for valid and invalid serialized incidents remains.
12. The obsolete generic no-incident recovery message remains absent.

Prefer table-driven helpers or concise fixture functions where that improves readability.

## Compatibility requirements

Preserve PR #273 behavior:

- Healthy steady state remains silent.
- Invalid incident evidence remains preserved.
- Recovery cooldown is not acquired before incident validation.
- Failed delivery remains nonzero and retryable.
- Successful recovery remains incident-correlated.
- The separate maintenance `SUCCESS` summary email is unchanged.
- Existing state-file size and sanitization bounds remain enforced.
- `set -euo pipefail` compatibility is mandatory.

## Validation

Run at minimum:

```bash
bash -n utilities/maintenance-health.sh
bash -n tests/suites/operations/case-health-alerts.bash
bash -n tests/suites/security/case-email.bash
bash -n tests/run-tests.sh

./tests/run-tests.sh operations
./tests/run-tests.sh security
./tests/run-tests.sh foundation
./tests/run-tests.sh data-protection
./tests/run-tests.sh all

find . -type f \( -name '*.sh' -o -name '*.bash' \) -print0 \
  | xargs -0 shellcheck -x --severity=warning

git diff --check
```

Run any additional repository checks affected by newly sourced files or libraries.

## PR discipline

- Keep this as a separate follow-up PR from #273.
- Keep the PR draft until implementation and CI are complete.
- Prefer one or two coherent commits; squash before merge if the history becomes iterative.
- Update the PR body with the selected design and its failure guarantees.
- Remove this temporary Codex implementation brief before marking the PR ready, unless the repository maintainers explicitly want it retained as durable documentation.
- Do not merge automatically.

## Final report

Report:

1. Selected test seam and why it is the smallest maintainable option.
2. Lines and helpers removed from the old extraction/eval harness.
3. Delivery-state format and lifecycle.
4. Exact guarantees and unavoidable degraded-filesystem limitation.
5. Tests added or simplified.
6. Exact validation commands and results.
7. Final diff scope and any deliberately deferred work.
