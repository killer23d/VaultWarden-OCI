# Independent Operator UI Post-Closure Review

## Executive Summary

This is an independent, read-only review of the `delta` branch after
PRs #219, #220, and #221 closed the preliminary operator-UI scan.

The review independently re-examined shared helpers, confirmation semantics,
return-code and `set -e` interactions, final-status truthfulness, backup,
restore, recovery, key-rotation, break-glass, maintenance, and update flows.

**Result:** PRs #219–#221 were appropriate and did not introduce semantic
regressions.  The shared helper layer (`operator_attention`,
`operator_confirm_yes_no`, `operator_next_steps`) is well-constructed and
correctly fail-closed on timeout, EOF, and invalid input.

One **Medium** finding was identified: `utilities/maintenance-db-maint.sh`
prints unconditional success messages ("VaultWarden is back online",
"Deep database maintenance complete!") even when the post-VACUUM health check
fails.  This is a pre-existing truthful-state issue adjacent to, but not
caused by, the UI-02 fix in PR #219.  The original scan noted the timeout
default (UI-02) but did not trace the health-check-failure output path.

No Critical or High findings were identified.

## Review Baseline

| Item | Value |
|---|---|
| Branch | `delta` |
| Commit | `a18d3ebaf6624882b2075d5a2617e719da9be12d` |
| Prior report | `reports/operator-ui-preliminary-scan.md` |
| Implementation PRs | #219, #220, #221 |
| Review date | 2026-07-04 |
| Review mode | Read-only; no functional code changes |

## Scope and Method

### Phases completed

1. **Establish current state** — confirmed `delta` branch at `a18d3eb`,
   clean working tree.

2. **Read prior evidence** — read the full preliminary scan including the
   closure section and observation resolution table.  Inspected the git log
   for PRs #219–#221 to map each change to the original finding.

3. **Inspect helper semantics** — reviewed `operator_attention`,
   `operator_confirm_yes_no`, and `operator_next_steps` in
   `lib/common.sh:169-262`.
   Traced all call sites.  Analysed `_should_log` gating, `set -e`
   interactions, EOF handling, timeout behavior, non-TTY fallback, and
   return-code semantics.

4. **Truthful-state audit** — traced final status output in `recover.sh`,
   `utilities/maintenance-db-maint.sh`, `utilities/maintenance-update.sh`,
   `utilities/backup-run.sh`, `utilities/maintenance-run.sh`,
   `utilities/safe-restart.sh`, `startup.sh`, and `utilities/key-rotate.sh`.

5. **Adjacent missed-item hunt** — inspected `Makefile` targets
   `update-system` and `breakglass-remove`, `setup-crowdsec.sh` manual-action
   output, `setup-secrets.sh` offline-recipient skip wording, and
   `key-rotate.sh` SAVED gate EOF behavior.

6. **Test quality review** — reviewed `tests/test-operator-ui.sh`,
   `tests/test-recover.sh`, `tests/test-backup-restore-behavior.sh`,
   `tests/test-confirmation-prompt-format.sh`,
   `tests/test-restore-run-followup.sh`, `tests/test-privilege-contracts.sh`,
   `tests/test-uninstall-vaultwarden.sh`, `tests/test-setup-storage-ux.sh`,
   and `tests/test-start-policy.sh`.

### Files inspected (targeted, not exhaustive)

- `lib/common.sh` — shared operator helpers
- `lib/log.sh` — `_should_log`, log-level gating
- `recover.sh` — disaster-recovery flow and health check
- `utilities/maintenance-db-maint.sh` — deep DB maintenance
- `utilities/maintenance-update.sh` — update and restart
- `utilities/maintenance-run.sh` — routine maintenance summary
- `utilities/key-rotate.sh` — Age key rotation and SAVED gate
- `utilities/backup-run.sh` — backup summary, verification, offsite sync
- `utilities/restore-run.sh` — destructive restore confirmation
- `utilities/safe-restart.sh` — safe restart with rollback
- `utilities/setup-crowdsec.sh` — final manual-action summary
- `utilities/setup-secrets.sh` — offline-recipient skip wording
- `startup.sh` — startup health check and final status
- `Makefile` — `update-system`, `breakglass-remove` targets

## Prior Closure Decisions Challenged

Each closure decision from `reports/operator-ui-preliminary-scan.md` was
independently reviewed against current code.

### UI-01: `recover.sh` health-check wording — **Closure upheld**

Current `recover.sh:345-367`
correctly branches:

- On health-check success: `"Recovery complete. Vaultwarden passed health check at $alive_url"`
- On health-check failure: `"Recovery artifacts were promoted, but Vaultwarden did not pass the health check."` plus actionable next commands.

The test at
`tests/test-recover.sh:351-363`
validates both paths, including assertions that "is running" never appears on
health failure.

The decision to preserve exit 0 on health failure (because recovery artifacts
*were* successfully promoted) is documented and tested.  This is a defensible
design choice for a disaster-recovery script where the primary mission —
rekeying and promoting secrets — succeeded.

### UI-02: Deep-maintenance timeout default — **Closure upheld**

Current `utilities/maintenance-db-maint.sh:78-84`
correctly fails closed on timeout and empty input.  The prompt shows
`(default: no)`.  The secondary "proceed without safety backup" prompt at
line 107 also correctly fails closed on timeout via `|| confirm_no_backup="no"`.

### UI-03: Shared helper layer — **Closure upheld**

The helpers in `lib/common.sh:169-262`
are minimal, well-scoped, and correctly integrated.  `operator_confirm_yes_no`
does not gate on `_should_log` — it always displays the prompt and always reads
input.  This is the correct semantic: a confirmation prompt must never be
silently suppressed by log level.

### UI-04: Key/passphrase role wording — **Closure upheld**

The preflight plan at `recover.sh:195-205` distinguishes the offline recovery
key, the manifest, the live key target, and the new operational key.

The emergency passphrase wording at `utilities/backup-run.sh:1262-1264` states:
`"This passphrase protects only the emergency backup capsule."`

The offline-recipient skip wording at `utilities/setup-secrets.sh:1892-1899`
explains the recovery consequence.

### UI-05: Final summaries — **Closure upheld with one adjacent gap**

The structured summary at `utilities/backup-run.sh:1365-1373` reports type,
file, verification, and offsite status.

The manual Cloudflare action block at `utilities/setup-crowdsec.sh:1431-1443`
uses `operator_next_steps` with a `log_info` fallback.

One adjacent gap was found in `maintenance-db-maint.sh` (see F-01 below).
This was not part of UI-05 itself but is in the same class of truthful
final-status reporting.

### Observation: `make breakglass-remove` — **Closure upheld**

The `breakglass-remove` target at `Makefile:867-870` no longer passes
`--force`, preserving the utility's interactive confirmation.

### Observation: `make update-system` — **Closure upheld**

The `update-system` target at `Makefile:760-772` clearly distinguishes the
direct host update from the managed workflow and warns about service restarts.

## Findings

### F-01: `maintenance-db-maint.sh` prints "VaultWarden is back online" after failed health check

**Severity:** Medium
**Confidence:** High

**Affected path:**
`utilities/maintenance-db-maint.sh` — `run_deep_db_maintenance`

**Execution path:**

```text
run_deep_db_maintenance
  → stop vaultwarden (line 119)
  → integrity check, WAL checkpoint, optimize, VACUUM (lines 126–149)
  → docker compose up -d vaultwarden (line 155)
  → wait_for_service_ready "vaultwarden" 45 → FAILS (line 157)
  → log_error "vaultwarden did not become healthy in time" (line 161)
  → FALLS THROUGH to line 164
  → log_success "VaultWarden is back online"          ← MISLEADING
  → log_success "Deep database maintenance complete!"  ← MISLEADING
  → [[ "$maintenance_successful" == "true" ]] returns 1 (line 189)
```

**Current behavior:**

Lines `utilities/maintenance-db-maint.sh:164`
and `utilities/maintenance-db-maint.sh:166`
unconditionally print success messages after `docker compose up -d`, regardless
of whether the subsequent `wait_for_service_ready` health check passed.

The function does return non-zero via line 189 when
`maintenance_successful` is false, so the caller's exit code is correct.
However, the operator has already read two green success lines:

```
✓ VaultWarden is back online
✓ Deep database maintenance complete!
```

immediately after:

```
✗ vaultwarden did not become healthy in time
```

**Evidence:**

From current code at `utilities/maintenance-db-maint.sh:157-166`:

```bash
if wait_for_service_ready "vaultwarden" 45; then
    log_success "All critical services are healthy"
    maintenance_successful=true
else
    log_error "vaultwarden did not become healthy in time"
    log_info "Check logs: docker compose logs vaultwarden"
fi
log_success "VaultWarden is back online"          # unconditional
echo ""
log_success "Deep database maintenance complete!" # unconditional
```

Verified via `git show c03adea:utilities/maintenance-db-maint.sh` that
this pattern pre-dates PRs #219–#221.  Line 159 (then numbered 159) was
already unconditional before the UI-02 fix.

**Operator impact:**

A junior operator running `sudo make db-maint` sees VaultWarden stopped
for maintenance.  If the container fails to become healthy after VACUUM
(e.g., due to disk pressure, a corrupted WAL, or a Docker issue), the
operator sees a red error line immediately followed by two green success
lines.  Under stress, the success lines may reassure the operator that
service is restored, delaying further investigation.

The safety backup cleanup guard at line 175 correctly checks
`maintenance_successful`, so the backup is retained.  The exit code
propagation is also correct.  The issue is purely in the terminal output
contradicting itself.

**Why the prior scan / PR closure missed this:**

The original scan (UI-02) focused on the timeout-defaults-to-yes problem
in the confirmation prompt.  PR #219 correctly fixed the timeout behavior
but did not trace the post-VACUUM health-check failure output path.
The closure pass confirmed the prompt fix and did not re-audit the
downstream status messages.

### Suggested remediation

**Target**

`utilities/maintenance-db-maint.sh` — `run_deep_db_maintenance`,
lines 157–166

**Suggested change**

Move the "back online" and "complete" messages inside the success branch
of the health check.  On failure, print a clear warning instead.

**Why this is minimal**

This changes only the conditional structure around two `log_success` calls
and adds one `log_warn` call on the failure path.  It does not change the
function's return-code behavior, the safety-backup retention logic, or
the `wait_for_service_ready` call.

**Suggested patch**

```diff
@@ utilities/maintenance-db-maint.sh — run_deep_db_maintenance
     if wait_for_service_ready "vaultwarden" 45; then
         log_success "All critical services are healthy"
         maintenance_successful=true
+        log_success "VaultWarden is back online"
+        echo ""
+        log_success "Deep database maintenance complete!"
     else
         log_error "vaultwarden did not become healthy in time"
         log_info "Check logs: docker compose logs vaultwarden"
+        log_warn "VaultWarden was restarted but did not pass the health check."
+        log_warn "Do not treat the service as healthy until: docker compose ps shows healthy."
     fi
-    log_success "VaultWarden is back online"
-    echo ""
-    log_success "Deep database maintenance complete!"
```

**Suggested regression test**

```bash
# In a test harness with mocked wait_for_service_ready returning non-zero:
test_db_maint_health_failure_no_false_success() {
    # Arrange: mock wait_for_service_ready to fail
    wait_for_service_ready() { return 1; }
    export -f wait_for_service_ready

    local out
    out=$(run_deep_db_maintenance 2>&1)

    # Assert: misleading success messages must not appear
    if echo "$out" | grep -q 'VaultWarden is back online'; then
        fail 'health failure must not say VaultWarden is back online'
    fi
    if echo "$out" | grep -q 'Deep database maintenance complete!'; then
        fail 'health failure must not say maintenance complete'
    fi
    # Assert: warning is present
    echo "$out" | grep -q 'did not pass the health check' \
        || fail 'health failure warning missing'
}
```

**Validation**

```bash
# After applying the patch, run with a mocked failing health check:
# 1. Source the db-maint function in a test harness
# 2. Override wait_for_service_ready to return 1
# 3. Assert output does not contain "VaultWarden is back online"
# 4. Assert output contains the health-failure warning
# 5. Assert function returns non-zero
```

## Low-Severity Opportunities

### L-01: `operator_next_steps` is silently suppressed when `LOG_LEVEL=WARN`

`operator_next_steps` at
`lib/common.sh:253`
gates on `_should_log "INFO"`.  If a caller sets `LOG_LEVEL=WARN` (or
higher), the entire next-steps block is suppressed with `return 0`.

This affects:

- `backup-run.sh` backup summary (already guarded by `QUIET`)
- `setup-crowdsec.sh` Cloudflare manual-action block (has a `log_info`
  fallback that is also suppressed at `WARN`)

In practice, `LOG_LEVEL=WARN` during interactive backup or CrowdSec setup
is unlikely.  Both callers also have their important state communicated
through `log_success`/`log_warn`/`log_error` calls that use higher log
levels.

No current operator-safety defect was demonstrated, but if future call
sites use `operator_next_steps` for safety-critical post-action guidance,
the `_should_log` gating could silently hide it.

**No code change recommended at this time.**  If future adoption of
`operator_next_steps` expands to safety-critical paths, consider gating
at `WARN` level instead of `INFO`, or removing the `_should_log` gate
entirely (the `QUIET` guard in callers already handles the machine-readable
suppression case).

### L-02: `key-rotate.sh` SAVED loop exits uncleanly on EOF

The SAVED gate at `utilities/key-rotate.sh:354-358`:

```bash
while [[ "$saved" != "SAVED" ]]; do
    read -r -p "Type SAVED after copying the recovery kit offline: " saved
    [[ "$saved" == "SAVED" ]] || log_warn "Please type exactly: SAVED"
done
```

Under `set -euo pipefail` (line 9), if `read` encounters EOF (terminal
closed, piped stdin exhausted), it returns 1.  Because `read` is in the
loop body (not in a conditional), `set -e` terminates the script
immediately without a useful message.

The key has already been promoted (lines 310–322) and the recovery kit
written (lines 328–344) at this point, so this is not a data-loss
scenario.  The operator simply sees the script exit silently instead of
a clear "EOF received" message.

This is fail-closed behavior (the script does not falsely report SAVED),
but the silent exit could confuse an operator who expected a clean
cancellation message.  The `ASSUME_YES` guard at line 352 already skips
the loop for automation.

**No change recommended at this time.**  If addressed, adding
`|| { log_warn "EOF on SAVED prompt — recovery kit was written to $kit_file"; break; }`
to the `read` call would provide a useful message without changing the
fail-closed behavior.

## Runtime Validation Limits

| Area | Limitation |
|---|---|
| `wait_for_service_ready` behavior | Cannot execute without a running Docker environment and VaultWarden stack. The F-01 finding is confirmed from static control-flow analysis. |
| `maintenance-update.sh` post-restart health | `apply_updates_and_restart` says "Services restarted successfully" after `docker compose up -d` returns 0 without verifying container health. This is a truthful-state observation, but `startup.sh` (which runs its own health check) is used for the primary `sudo make up` path, and `apply_updates_and_restart` is only used by the update flow where the compose command itself is the restart mechanism. Classified as a design note, not a finding. |
| `test-privilege-contracts.sh` COMMAND-REFERENCE staleness | This test regenerates `docs/COMMAND-REFERENCE.md` and diffs it. It fails on macOS because some `--help` outputs require root. This is an environment-sensitive test limitation, not an operator-safety regression. |
| ShellCheck | Ran ShellCheck 0.11.0 on `recover.sh`, `utilities/maintenance-db-maint.sh`, `utilities/key-rotate.sh`, `utilities/maintenance-update.sh`, and `lib/common.sh` — clean (no warnings). Broad project-wide ShellCheck deferred to CI. |

## Tests and Commands Run

### Commands run (previous session, before usage interruption)

```bash
# Phase 1 — state
git status --short                    # clean
git branch --show-current             # delta
git rev-parse HEAD                    # a18d3ebaf6624882b2075d5a2617e719da9be12d
git log --oneline --decorate -20      # confirmed PR history

# Phase 2 — syntax validation
bash -n backup.sh restore.sh startup.sh recover.sh maintenance.sh setup.sh edit-secrets.sh
find utilities lib -name '*.sh' -print0 | xargs -0 bash -n
# Both passed.

# Phase 3 — focused tests
bash tests/test-operator-ui.sh                   # passed
bash tests/test-confirmation-prompt-format.sh    # passed
bash tests/test-recover.sh                       # 14/14 passed
bash tests/test-backup-restore-behavior.sh       # passed
bash tests/test-restore-run-followup.sh          # 11/11 passed
bash tests/test-start-policy.sh                  # passed
bash tests/test-setup-storage-ux.sh              # passed
bash tests/test-uninstall-vaultwarden.sh         # passed
bash tests/test-privilege-contracts.sh           # failed (COMMAND-REFERENCE staleness — environment limitation, not a finding)

# Phase 4 — ShellCheck
shellcheck -x -S warning recover.sh utilities/maintenance-db-maint.sh \
    utilities/key-rotate.sh utilities/maintenance-update.sh lib/common.sh
# Clean — no warnings.

# Phase 5 — git history
git diff c03adea..9e19766 -- utilities/maintenance-db-maint.sh   # confirmed UI-02 fix
git show c03adea:utilities/maintenance-db-maint.sh | grep -n "VaultWarden is back online"
# Confirmed line 164 pre-dates PRs #219–#221.

# Cleanup
git checkout -- docs/COMMAND-REFERENCE.md    # restored generated file
```

### Commands run (this continuation session)

```bash
git status --short && git diff --stat && git branch --show-current && git rev-parse HEAD
# Clean working tree, delta, a18d3eb
```

### Commands NOT run (deferred to CI)

```bash
make test-unit
make test
# Individual test-*.sh re-runs not repeated
# Broad ShellCheck not re-run
# Docker/Compose runtime validation not possible
```

## Final Assessment

### 1. Were the changes in PRs #219–#221 appropriate?

**Yes.**  PR #219 correctly fixed the two highest-priority findings (UI-01
health-check wording, UI-02 timeout default).  PR #220 introduced a
well-designed shared helper layer that is correctly fail-closed.  PR #221
performed a closure pass that left intentional limitations documented.

### 2. Did they introduce a semantic or operator-safety regression?

**No.**  The shared helpers (`operator_attention`, `operator_confirm_yes_no`,
`operator_next_steps`) are semantically correct.  `operator_confirm_yes_no`
correctly does not gate on `_should_log`, ensuring confirmation prompts are
never silently suppressed.  Return codes, `set -e` interactions, EOF handling,
timeout behavior, and non-TTY fallback were all independently verified.

### 3. Did the preliminary scan miss any confirmed Critical, High, or Medium issue?

**One Medium issue (F-01).**  The unconditional "VaultWarden is back online" /
"Deep database maintenance complete!" messages in `maintenance-db-maint.sh`
are a pre-existing truthful-state issue that was adjacent to, but not surfaced
by, the UI-02 timeout fix.

### 4. Are any closure decisions in the report incorrect based on current code?

**No.**  All five closure decisions (UI-01 through UI-05) and the observation
resolutions are supported by current code evidence.

### 5. Are current tests protecting the important behavior rather than only the source wording?

**Mostly yes.**  Key behavioral tests include:

- `test-recover.sh` — 14 tests covering rollback, health failure messaging,
  artifact promotion, and permission contracts using a mock-harness approach
  that validates runtime behavior, not just source patterns.
- `test-operator-ui.sh` — tests `operator_confirm_yes_no` runtime behavior
  (default-yes, default-no, timeout fail-closed) alongside source-pattern
  checks.

Some tests in `test-operator-ui.sh` (lines 43–94) and
`test-backup-restore-behavior.sh` use `grep -Fq` source-pattern matching.
These verify that specific helper calls and wording exist in source but
cannot detect if surrounding control flow changes the effective behavior.
However, the important behavioral contracts (confirm-fail-closed,
health-failure-messaging, backup-verification-branching) are covered by
either runtime tests or control-flow-sensitive `awk` block extraction.

No test-gap finding is raised because the existing test quality is
appropriate for this project's scale and the tested behaviors are the
right ones.

### 6. Is additional operator UI remediation justified?

**Yes — one targeted fix (F-01).**

### 7. What exact findings should be handed to a coding agent?

**F-01** only.

---

**TARGETED FOLLOW-UP RECOMMENDED**

Finding IDs for implementation: **F-01**
