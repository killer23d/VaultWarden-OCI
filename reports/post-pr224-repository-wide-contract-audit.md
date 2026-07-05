# Post-PR #224 Repository-Wide Contract Audit

## Executive Summary

An independent, contract-driven code audit was performed to assess the repository-wide shared operation-guard architecture merged in PR #224. 

The audit traced execution paths, nested caller graphs, process supervision logic, lock lifetime, and edge-case signal handling throughout the `delta` branch. While PR #224 successfully introduced an operation guard, the audit identified critical gaps that violate the core safety contract:
1. An explicit `flock -u` lock-stripping command severs lock lifetimes upon parent process termination while leaving children unguarded.
2. Several major top-level entry points (`startup.sh` being the most prominent) remain fully unguarded, enabling silent, concurrent state corruption.
3. A direct, native `add-apt-repository` call executes an implicit apt cache update outside the `operation_package_run` guard boundary.

## Audit Baseline

Primary branch: `delta`  
Exact audited commit SHA: `d44b036`

## Scope and Method

The review focused on files across the repository, tracing code execution both inside and outside the scope of files modified by PR #224. 

Methodology:
- Inventorying shell script workflows, Make targets, and systemd units
- Deep tracing parent-child script relationships and inherited Unix file descriptor management
- Examining signal trapping (`EXIT`, `TERM`, `INT`) and their interaction with the lock lifecycle
- Investigating systemd contention contracts and skip-exit behavior

## Architecture Reconstructed from Current Code

### Operation Ownership and Concurrency Contract
Active operations are tracked via the `flock` utility enforcing kernel-level exclusive locks on `/run/lock/vaultwarden-operations.lock`. Secondary state files under `/run/vaultwarden-oci/operations/` hold verifiable metadata (PID, start time).

### Nested Workflow and Inherited Lock Contract
Children spawned from a parent process that holds the lock inherit the open file descriptor (`$VW_OPERATION_INHERITED_FD`). They validate the `flock` against the expected canonical lock path to safely execute under the parent's guard.

### Interruption and Stop Contract
Scripts trap signals (`TERM`, `INT`, `HUP`, `EXIT`) to trigger `operation_release`. The library attempts a controlled wait and forceful termination of the complete process tree (`_operation_stop_scope`) via `/proc` recursion before releasing the lock.

### Package-Manager Contract
Package updates require a special wrapper (`operation_package_run`) that allows the operation library to intentionally exclude `apt`/`dpkg` descendant processes from forced termination to prevent dpkg database corruption.

### Systemd Contention Contract
Non-interactive scripts skip gracefully on contention. They exit with code `75`, which `systemd` is expected to intercept and handle cleanly using `SuccessExitStatus=0 75`. 

### Operator Status Contract
`operation_list` uses metadata state to show currently running or cleanly skipped statuses. State files are validated against `/proc` start times to prevent misleading states upon PID recycling.

## Repository-Wide Coverage

### Entry Points Reviewed
- Top-level operator entry points (`make up`, `make backup`, `make restore`)
- Setup, maintenance, restore, and utility shell scripts
- Nested and parent dependencies (`startup.sh`, `setup-system.sh`, `backup-run.sh`)

### Mutating Workflows Reviewed
- Database restorations (`restore-run.sh`)
- Docker container lifecycles (`startup.sh`, `safe-restart.sh`)
- System package source modification (`setup-system.sh`)
- Secrets/key generation and editing (`secrets-edit.sh`, `key-rotate.sh`)

### Direct Locks Reviewed
- `VW_OPERATIONS_LOCK` (`/run/lock/vaultwarden-operations.lock`)
- Operation-specific fallback locks (`/run/lock/vaultwarden-backup.lock`, etc.)

### Systemd Services and Timers Reviewed
- `vaultwarden-health.service`
- `vaultwarden-maintenance.service`
- `vaultwarden-db-backup.service`

### High-Risk Workflow Traces
- SQLite database restore operations being interrupted
- Automatic maintenance `systemd` timers overlapping with manual `make up` invocations

## Findings

### F-01: Explicit `flock -u` destroys lock inheritance safety on parent termination

**Severity:** Critical  
**Confidence:** High  
**Affected path:** `lib/operations.sh` (function `operation_release`)  
**Execution path:** `make setup` -> `setup.sh` -> `utilities/setup-system.sh`  
**Contract violated:** Lock lifetime must span the duration of mutation, explicitly covering surviving inherited children.

#### Current behavior
When `operation_release` executes, it runs `flock -u "$OPERATION_LOCK_FD"`. This aggressively drops the kernel lock for the file description immediately.

#### Evidence
```bash
# In lib/operations.sh:
if [[ -n "${OPERATION_LOCK_FD:-}" && "$OPERATION_OWNS_GLOBAL" == "true" ]]; then
    flock -u "$OPERATION_LOCK_FD" 2>/dev/null || true
```

#### Realistic trigger
If an administrator manually kills a top-level parent script, or if the parent abruptly dies due to pipeline failures/errexit, the `EXIT` trap executes `operation_release` and `flock -u` is invoked.

#### Operator or production impact
The kernel immediately releases the exclusive lock, while the child script (e.g., `utilities/setup-system.sh`) continues to run in the background mutating system state. A concurrent workflow (like `make backup`) can suddenly acquire the lock and corrupt the environment alongside the surviving child.

#### Why existing safeguards are insufficient
The bash trap mechanism correctly attempts to clean up the parent, but `flock -u` completely overrides standard Unix inherited file-descriptor closures.

#### Why existing tests did not prevent or expose this
Existing `test-operation-guards.sh` mocks `flock` and does not reliably simulate a parent dying while an inherited sub-process survives and checks the lock state.

### Suggested remediation

**Target**
`lib/operations.sh` — `operation_release`

**Suggested change**
Remove `flock -u` and rely purely on standard descriptor closure. 

**Why this is minimal**
It preserves the native behavior of Unix inherited descriptors where the lock is safely preserved until the final surviving child also closes the file descriptor.

**Suggested patch**
```diff
@@ -345,7 +345,7 @@
     local rc="${1:-0}" lock_path file label specific_lock specific_file
 
     if [[ -n "${OPERATION_LOCK_FD:-}" && "$OPERATION_OWNS_GLOBAL" == "true" ]]; then
-        flock -u "$OPERATION_LOCK_FD" 2>/dev/null || true
+        # Removed flock -u to ensure surviving children implicitly hold the FD
         exec {OPERATION_LOCK_FD}>&- 2>/dev/null || true
     fi
```

**Suggested regression test**
```bash
test_flock_lifetime_parent_death() {
    # Mock a child process holding an inherited FD, kill parent, verify flock survives.
}
```

**Validation**
```bash
./tests/test-operation-guards.sh
```

---

### F-02: Major mutating top-level entry points are completely unguarded

**Severity:** High  
**Confidence:** High  
**Affected path:** `startup.sh`, `utilities/safe-restart.sh`, `utilities/secrets-edit.sh`  
**Execution path:** `make up` -> `startup.sh`  
**Contract violated:** Any script that performs mutating workflows must be safeguarded behind the operation-guard architecture.

#### Current behavior
`startup.sh` orchestrates Docker container pull and start-up, staging runtime secrets, and rewriting DNS records. None of these routines are shielded by `operation_acquire`.

#### Evidence
`startup.sh` does not source `lib/operations.sh` nor does it call `operation_acquire`. The file lacks guards.

#### Realistic trigger
An operator successfully initiates a long-running workflow like `make restore`. A second operator or automated workflow concurrently calls `sudo make up`.

#### Operator or production impact
The restore process drops the container and begins rewriting the SQLite database. Simultaneously, the unguarded `startup.sh` will `docker compose up -d`, launching the container in the middle of a database rewrite, leading to irrecoverable database corruption.

#### Why existing safeguards are insufficient
The new operation-guard architecture merged in PR #224 entirely missed incorporating `startup.sh`, one of the most critical lifecycle points in the repository.

#### Why existing tests did not prevent or expose this
No test asserts that `make up` acquires the `VW_OPERATIONS_LOCK`.

### Suggested remediation

**Target**
`startup.sh`

**Suggested change**
Source `lib/operations.sh` and invoke `operation_acquire` early in the `startup.sh` initialization block.

**Why this is minimal**
It applies the already-proven guard model identically to the newly protected workflows from PR #224.

**Suggested patch**
```diff
@@ -810,6 +810,12 @@
 main() {
   log_info "Starting VaultWarden-OCI startup workflow..."
 
+  # Source operations library
+  source "${PROJECT_ROOT}/lib/operations.sh" || exit 1
+
+  # Acquire operation guard
+  operation_acquire --id startup --label "Stack startup" || exit $?
+
   trap 'exit 130' INT
```

**Suggested regression test**
```bash
test_startup_acquires_lock() {
    # Assert that calling startup.sh successfully writes lock states and waits if locked
}
```

**Validation**
```bash
sudo ./startup.sh
```

---

### F-03: Direct `add-apt-repository` bypasses package manager wait safety

**Severity:** Medium  
**Confidence:** High  
**Affected path:** `utilities/setup-system.sh`  
**Execution path:** `utilities/setup-system.sh` (line 376)  
**Contract violated:** `apt/dpkg` states must exclusively be manipulated using `operation_package_run` for accurate process exclusions during force stops.

#### Current behavior
At line 376 of `utilities/setup-system.sh`, a fallback `add-apt-repository -y universe` command is run natively without the `operation_package_run` wrapper.

#### Evidence
```bash
# utilities/setup-system.sh
add-apt-repository -y universe 2>/dev/null || { ... }
```

#### Realistic trigger
`add-apt-repository` performs package lock manipulations similar to `apt update`. If an administrator forcefully terminates this running operation (via `sudo make operations` -> Force Stop), the force-stop logic (`_operation_has_package_manager_child`) fails to identify the backend Python `add-apt-repository` script.

#### Operator or production impact
The termination will unexpectedly SIGKILL the package manager mutation process, risking a corrupted cache state. 

#### Why existing safeguards are insufficient
The `_operation_has_package_manager_child` regex relies heavily on capturing expected `apt` and `dpkg` paths from wrapped calls. 

#### Why existing tests did not prevent or expose this
Tests do not scan all `apt` related system binaries for execution outside the wrapper.

### Suggested remediation

**Target**
`utilities/setup-system.sh`

**Suggested change**
Wrap `add-apt-repository` in `operation_package_run`.

**Why this is minimal**
Reuses the exact wrapper implemented for `apt-get install` commands earlier in the script.

**Suggested patch**
```diff
@@ -375,3 +375,3 @@
         if command -v add-apt-repository >/dev/null 2>&1; then
-            add-apt-repository -y universe 2>/dev/null || {
+            operation_package_run add-apt-repository -y universe 2>/dev/null || {
```

**Suggested regression test**
```bash
test_package_commands_wrapped() {
    # Static grep test to ensure 'add-apt' and 'apt' are explicitly tied to 'operation_package_run'
}
```

**Validation**
```bash
make test-unit
```

## Low-Severity Opportunities

- **Operation Force Stop Edge Case:** In `_operation_force_stop`, `rm -f "$file"` explicitly deletes the state file. When file descriptor tracking is in an inconsistent state on very fast script terminations, this deletion doesn't harm anything but could potentially clear metadata without verifying the canonical lock path clears simultaneously. No operational harm found in current tests, but standardizing cleanup paths would improve robustness.

## Rejected Candidate Findings

- **Systemd Service Exits During Contention**: `utilities/maintenance-health.sh` exits `0` when encountering contention `75` rather than bubbling up `75` directly to `systemd/vaultwarden-health.service`. **Rejected:** This is correctly by design. It translates skipped contention into a clean status so that the `systemd` unit (`SuccessExitStatus=0 1 3`) properly suppresses false-positive "Failure" alerts being sent to the operator.
- **`vaultwarden-db-backup.service` exits 75 on contention**: **Rejected:** `vaultwarden-db-backup.service` explicitly adds `SuccessExitStatus=0 75`. The skip behavior successfully aligns with the unit definition.
- **Process Identification through `sudo` wrappers**: `sudo make ...` uses `sudo` which might mask child PIDs from the operation stop process. **Rejected:** The `_operation_descendant_pids` uses a fully recursive `/proc/<pid>/stat` loop which flawlessly traces through the `sudo` boundary without process obfuscation.

## Runtime Validation Limits

- Full end-to-end destructive commands such as storage migration and bare metal restore routines were bypassed to preserve the environment. 
- Validation focused purely on non-destructive state traces via local scripts and test suites.

## Tests and Commands Run

- `git status --short`
- `git branch --show-current`
- `git log --oneline --decorate -30`
- `grep -RIn` commands per phase 4 guidelines.
- `./tests/test-operation-guards.sh`

## Final Assessment

TARGETED FOLLOW-UP PR RECOMMENDED

Findings to implement: F-01, F-02, F-03.
