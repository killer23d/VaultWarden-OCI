# Post-PR #224 Repository-Wide Contract Audit

**Target:** `VaultWarden-OCI` (`delta` branch)
**Scope:** Complete repository (post-PR #224 shared operation-guard architecture).
**Execution Mode:** Read-only / Independent Verification.

## Executive Summary

An independent, contract-driven code audit was performed to assess the repository-wide shared operation-guard architecture merged in PR #224. 

The audit traced execution paths, nested caller graphs, process supervision logic, lock lifetime, and edge-case signal handling throughout the `delta` branch. While PR #224 successfully introduced an operation guard, the audit identified three major actionable gaps that violate the core safety contract:

1. **A critical lock lifetime defect during parent termination** resulting from an explicit `flock -u` override that strips the shared guard from surviving, actively mutating child processes.
2. **Several major top-level entry points remain fully unguarded**, most notably `startup.sh`, enabling concurrent mutations (e.g. database restore and Docker service startup) to silently corrupt the stack. 
3. **An un-wrapped `add-apt-repository` call** that executes an internal package-manager cache update outside the safety of `operation_package_run`.

The sections below outline the specifics of these findings.

---

## Findings

### Finding 1: Explicit `flock -u` destroys lock inheritance safety on parent termination

**Severity:** Critical
**Location:** `lib/operations.sh:operation_release()`
**Defect:** `operation_release` explicitly calls `flock -u` on the inherited lock file descriptor.

**Traceability:**
1. A parent process (e.g., `setup.sh`) acquires the global lock using `operation_acquire`, opening a file descriptor to `/run/lock/vaultwarden-operations.lock` and mapping it via the kernel `flock`.
2. The parent spawns a child (e.g., `utilities/setup-system.sh`). The child seamlessly inherits the open file descriptor.
3. If the operator sends a `kill -TERM` strictly to the parent PID (or the parent crashes via `set -e` or pipeline failure), the parent's `EXIT`/`TERM` trap invokes `operation_release`.
4. `operation_release` executes `flock -u "$OPERATION_LOCK_FD"`.
5. Because `flock(2)` locks are associated with the *open file description* in the kernel, explicitly calling `flock -u` on *any* duplicated file descriptor immediately releases the lock globally for that description.
6. The kernel lock is instantly freed, while the child script (`utilities/setup-system.sh`) continues mutating system state in the background.
7. A concurrent workflow (e.g., `make backup`) can immediately acquire the global lock and interfere with the surviving, actively mutating child.

**Contract violation:**
Lock lifetime is explicitly severed from the real mutation lifetime upon parent termination. If `operation_release` simply closed its file descriptor (`exec ...>&-`), the kernel would naturally maintain the lock until the surviving child also closed its descriptor, perfectly preserving safety. 

**Recommendation:**
Remove `flock -u "$OPERATION_LOCK_FD"` and `flock -u "$OPERATION_SPECIFIC_LOCK_FD"` in `operation_release`. Rely strictly on standard descriptor closure (`exec ...>&-` or natural bash exit cleanup) so that any inherited file descriptor in an active child safely keeps the kernel lock alive until the final child exits.

---

### Finding 2: Major mutating top-level entry points are completely unguarded

**Severity:** High
**Locations:** `startup.sh`, `utilities/safe-restart.sh`, `utilities/secrets-edit.sh`, `utilities/secrets-rotate.sh`, `utilities/env-edit.sh`
**Defect:** These fully exposed mutating scripts do not call `operation_acquire`.

**Traceability:**
1. `startup.sh` directly orchestrates state mutations (running `docker compose pull`, staging runtime secrets, writing DNS records, and triggering `docker compose up -d`).
2. It lacks any `operation_acquire` guard logic.
3. If an operator triggers `sudo make restore` (which begins safely deleting the container and rewriting the SQLite database), another operator or automated workflow triggering `sudo make up` will concurrently run `startup.sh`.
4. `startup.sh` silently proceeds without lock contention, causing Docker to start the `vaultwarden` container in the middle of a `sqlite3` database rewrite, which could irreparably corrupt the SQLite state.
5. The same exposure exists for `safe-restart.sh` (which manipulates Docker lifecycle), `secrets-edit.sh` (which mutates the age-encrypted secrets YAML concurrently with backup paths), and `env-edit.sh`.

**Contract violation:**
The repository promises shared protection across supported mutating workflows, but critical container lifecycle entry points (`startup.sh` being the most prominent) completely bypassed the PR #224 migration. 

**Recommendation:**
Add standard `operation_acquire` guards (using `OPERATION_OWNS_GLOBAL`) to all of the exposed entry points mentioned above. 

---

### Finding 3: Direct `add-apt-repository` bypasses package manager wait safety

**Severity:** Low / Moderate
**Location:** `utilities/setup-system.sh` (around line 376)
**Defect:** `add-apt-repository` mutates package manager configuration and executes an implicit cache update without being wrapped in `operation_package_run`.

**Traceability:**
1. At line 376 of `utilities/setup-system.sh`, the script falls back to executing `add-apt-repository -y universe`.
2. By default in modern Ubuntu, `add-apt-repository` invokes a backend Python apt implementation that often refreshes the cache lock similarly to `apt update`.
3. Because it is executed natively outside of `operation_package_run`, if an operator triggers `sudo make operations` -> `Force Stop` while this command is running, the descendant identity capture loop might not wait properly. The `_operation_has_package_manager_child` logic explicitly excludes termination for safe `apt`, `apt-get`, and `dpkg` paths, but misses the `add-apt-repository` python process.
4. The system could dangerously force-terminate the script in the middle of a package source rewrite.

**Contract violation:**
Any process manipulating the dpkg/apt lock or state is expected to use `operation_package_run` for correct force-stop exclusions.

**Recommendation:**
Wrap the invocation of `add-apt-repository` in `operation_package_run` just like the native `apt-get` calls, e.g.:
`operation_package_run add-apt-repository -y universe`

---

## Conclusion

The shared operation-guard architecture successfully intercepts standard interactive collisions and systemd timer contention for most maintenance operations. 

However, the explicit `flock -u` stripping on script termination actively breaks the safety provided by Unix inherited file descriptors. Furthermore, leaving `startup.sh` fully unguarded leaves a significant window for silent state corruption if services are manually started during sensitive IO tasks like restores or system re-provisioning. Fixing these defects requires minimal changes and conforms strictly to the intended shell architecture.
