# Post-PR #224 Repository-Wide Contract Audit

## Executive Summary

This is an independent report-only audit of the current `delta` branch after PR #224 introduced the shared operation-guard architecture.

The current architecture is coherent in its core guarded paths: backup, restore, routine maintenance, updates, CrowdSec setup, storage migration, health repair, key rotation, permission repair, and uninstall generally acquire the shared guard or an intentionally narrower lock. The shared library also correctly treats kernel `flock` state, not lock-file existence, as the authority for active ownership.

However, the repository is not yet consistently applying that architecture across all supported mutating entry points. I confirmed six actionable gaps:

- **F-01 (High):** `operation_release` explicitly unlocks the global `flock`, which can release shared protection while an inherited mutating child still continues.
- **F-02 (High):** supported startup/restart paths are unguarded and can overlap restore, migration, key, backup, or maintenance work.
- **F-03 (High):** supported secrets configure/edit/rotate paths mutate SOPS secrets, Age policy, and runtime secret files without the operation guard.
- **F-04 (Medium):** `vaultwarden-iptables.service` does not match the installed script layout or guarded-script runtime contract.
- **F-05 (Medium):** `add-apt-repository` remains outside `operation_package_run`, and package-child detection can miss it.
- **F-06 (Medium):** supported environment and systemd install/configuration paths mutate generated config and installed automation without operation coordination.

Because F-01 through F-03 are high-impact operation-guard correctness defects, this audit recommends blocking production-ready status until they are fixed.

## Audit Baseline

- Repository: `https://github.com/killer23d/VaultWarden-OCI`
- Branch audited: `delta`
- Audited HEAD: `d7e09ee031754b25b1a4e2db04b9c6ec60f89135`
- Initial status: `## delta...origin/delta`
- Final status before this report write: clean worktree on `delta`
- PR #224 merge context: `81f6b96ff09b3c208c542be9c25cf81a72968472` (`Add shared operation guards`)

Recent relevant history at audit start:

```text
d7e09ee docs: restructure post-PR #224 contract audit report to match constraints
0d11e44 docs: add post-PR #224 repository-wide contract audit report
d44b036 Update AGENTS.md
119b751 Merge pull request #225 from killer23d/delta
81f6b96 Merge pull request #224 from killer23d/codex/add-shared-operation-guards
```

PR #224 added the shared operation library and tests, including `lib/operations.sh`, `tests/test-operation-guards.sh`, and `utilities/operations-status.sh`.

## Scope and Method

I treated the current repository as the source of truth, not PR descriptions, previous reports, tests, or comments. I inspected the repository-wide file inventory, operation acquisition sites, direct locks, package-manager commands, systemd units, supported Make/direct/script entry points, and high-risk workflow call graphs.

Primary inspection areas included:

- Top-level operator entry points: `setup.sh`, `startup.sh`, `backup.sh`, `restore.sh`, `maintenance.sh`, `edit-secrets.sh`, `recover.sh`, `Makefile`.
- Shared libraries: especially `lib/operations.sh`, `lib/migrate.sh`, `lib/secrets.sh`, `lib/runtime-permissions.sh`, `lib/docker.sh`, `lib/storage.sh`.
- Setup/configuration utilities under `utilities/`.
- Backup, restore, maintenance, update, DNS, firewall, CrowdSec, storage, key rotation, permission repair, uninstall, and secrets workflows.
- All `systemd/` services and timers.
- Tests under `tests/`, with special attention to the operation-guard, privilege, backup/restore, start-policy, operator UI, and CrowdSec tests.
- Operator documentation and generated command references where they affect supported execution semantics.

I did not perform destructive host operations such as real setup, restore, package upgrade, firewall mutation, storage migration, key rotation against real secrets, uninstall, or CrowdSec reset.

## Architecture Reconstructed from Current Code

### Operation Ownership and Concurrency Contract

`lib/operations.sh` defines the shared operation contract. The canonical global lock is `VW_OPERATIONS_LOCK`, defaulting to `/run/lock/vaultwarden-operations.lock`. Runtime metadata lives under `VW_OPERATIONS_STATE_DIR`, defaulting to `/run/vaultwarden-oci/operations`.

The intended model is:

- Mutating workflows that can conflict globally acquire the global operation lock through `operation_acquire`.
- Duplicate-sensitive workflows may also acquire a specific lock.
- Read-only or diagnostic paths may avoid the global lock.
- Metadata is descriptive and operator-facing; kernel `flock` ownership is authoritative.
- Lock-file path existence is not treated as proof of an active operation.

Confirmed global or guarded mutating paths include backup, restore, routine maintenance, managed update, database maintenance, DNS update, firewall update, CrowdSec setup, setup, setup-system child path, storage setup/migration, key rotation, permission repair, and uninstall.

### Nested Workflow and Inherited Lock Contract

Nested scripts are expected to reuse the parent global lock when the parent exports:

```text
VW_OPERATION_INHERITED_FD
VW_OPERATION_PARENT_STATE
VW_OPERATION_PARENT_TOKEN
VW_OPERATION_PARENT_ID
```

`operation_acquire` validates inherited locks by checking `/proc/$$/fd/<fd>`, matching the descriptor target against `VW_OPERATIONS_LOCK`, and matching the parent state token while the state remains `running` (`lib/operations.sh:643-654`). If validation succeeds, the child sets `OPERATION_OWNS_GLOBAL=false` and `OPERATION_OWNS_STATE=false` (`lib/operations.sh:695-702`).

That design is reasonable for foreground nested calls, but its safety depends on normal release preserving the inherited lock until the last mutating child exits. F-01 shows that current release behavior violates that requirement.

### Interruption and Stop Contract

The library supports conflict prompts, verified owner metadata, descendant discovery, controlled stop, and force-stop. It tries to avoid stale PID reuse by storing `pid_start`, and it captures descendant identities before signalling.

The intended stop contract is:

- Verify owner before acting.
- Refuse to automatically terminate active apt/dpkg work.
- Signal operation-owned children before the wrapper.
- Verify descendants and the lock have actually cleared.
- Treat stale or unverifiable metadata cautiously.

This is broadly sound, but the explicit global unlock in `operation_release` can still clear the authoritative lock before a surviving inherited child finishes.

### Package-Manager Contract

`operation_package_run` is the intended wrapper for apt/dpkg commands. It captures command output through `tee`, preserves the command exit code with `PIPESTATUS[0]`, retries only recognized package-lock contention, restores the caller's errexit state, and warns that apt/dpkg is never automatically terminated.

Most current apt/dpkg paths use the wrapper. One supported package-repository path still bypasses it: `utilities/setup-system.sh` runs `add-apt-repository -y universe` directly.

### Systemd Contention Contract

Timer-driven backup and maintenance services generally delegate to script-owned operation guards rather than duplicating `flock` in unit files. Backup units treat exit `75` as a clean skip. Maintenance treats `75` as expected contention. DNS/firewall/health paths convert expected contention to success where the script chooses clean skip semantics.

The main mismatch is `vaultwarden-iptables.service`: its installed script layout does not match `setup-firewall.sh` path discovery, and the unit does not provide the same runtime lock/state write paths or contention exit contract used by other guarded services.

### Operator Status Contract

`sudo make operations` delegates to `utilities/operations-status.sh`, which calls `operation_list`. The status command lists known operation IDs, then dynamically includes unknown state files found on disk. This is useful for active/interrupted state, but its static known-ID list is slightly incomplete; see Low-Severity Opportunities.

## Repository-Wide Coverage

### Entry Points Reviewed

Reviewed supported entry points included:

- `sudo make setup`, `up`, `restart`, `safe-restart`, `backup`, `restore`, `update`, `maintenance`, `health`, `operations`, `sync-env`, `edit-env`, `init-secrets`, `edit-secrets`, `systemd-*`, `key-*`, `repair-permissions`, `uninstall`.
- Direct scripts: `setup.sh`, `startup.sh`, `backup.sh`, `restore.sh`, `maintenance.sh`, `edit-secrets.sh`, `recover.sh`.
- Direct utilities under `utilities/`, including setup, storage, secrets, env, systemd, firewall, DNS, CrowdSec, backup/restore, maintenance, key rotation, permission repair, and uninstall utilities.
- Systemd service and timer entry points under `systemd/`.
- Parent/nested paths from setup, restore, startup, maintenance, migration, and uninstall workflows.

### Mutating Workflows Reviewed

Reviewed mutating workflow families included package installation/update, systemd installation, Docker/Compose start/stop/recreate/pull, Vaultwarden state and SQLite backup/restore, storage setup/migration, secrets and SOPS policy mutation, Age key rotation, runtime Docker secret staging, CrowdSec installation/configuration, firewall and DNS mutation, permissions repair, uninstall/destructive cleanup, generated config rendering, and recovery workflows.

### Direct Locks Reviewed

Direct locks reviewed:

- Shared operation lock in `lib/operations.sh`.
- Specific operation locks such as backup, setup, maintenance, health, DNS, firewall, update, restore, permission repair, uninstall, storage migration/setup, and key rotation.
- `lib/migrate.sh` duplicate migration lock.
- `utilities/setup-secrets.sh` break-glass account lock.
- `utilities/notify-failure.sh` notification de-duplication lock.
- xtables coordination through system tooling and unit runtime paths.

The retained non-operation direct locks are generally justified as resource, duplicate-run, or cooldown locks rather than replacements for the global operation guard.

### Systemd Services and Timers Reviewed

Reviewed:

- `vaultwarden-db-backup.service` / `.timer`
- `vaultwarden-full-backup.service` / `.timer`
- `vaultwarden-maintenance.service` / `.timer`
- `vaultwarden-health.service` / `.timer`
- `vaultwarden-dns-update.service` / `.timer`
- `vaultwarden-firewall-update.service` / `.timer`
- `vaultwarden-iptables.service`
- `vaultwarden-startup.service`
- `vaultwarden-notify-failure.service`
- `vaultwarden-notify-failure@.service`

### High-Risk Workflow Traces

Deeper traces were performed for setup, startup/restart, safe restart, backup, full/emergency backup, restore, storage setup/migration, maintenance, managed update, DNS update, firewall setup/update, CrowdSec setup, health repair, Age key rotation, secrets setup/edit/rotate, permission repair, uninstall, and systemd install/validate/start behavior.

## Findings

### F-01: Inherited Global Operation Lock Can Be Explicitly Released While a Mutating Child Continues

**Severity:** High  
**Confidence:** Medium  
**Affected path:** `lib/operations.sh` — `operation_release`  
**Execution path:** guarded parent workflow with inherited mutating child; for example `setup.sh` invoking setup utilities or `restore-run.sh` invoking guarded descendants while the child inherited the global lock descriptor.  
**Contract violated:** the shared guard must cover the real conflicting mutation scope, including operation-owned nested children.

#### Current behavior

When a parent owns the global lock, `operation_release` explicitly runs `flock -u "$OPERATION_LOCK_FD"` before closing the descriptor:

```bash
if [[ "$OPERATION_OWNS_GLOBAL" == "true" && -n "${OPERATION_LOCK_FD:-}" ]]; then
    flock -u "$OPERATION_LOCK_FD" 2>/dev/null || true
    { eval "exec ${OPERATION_LOCK_FD}>&-"; } 2>/dev/null || true
    OPERATION_LOCK_FD=""
fi
```

On Linux, `flock` locks are associated with the open file description. A child that inherited the same descriptor relies on that same lock. Explicitly unlocking from the parent descriptor unlocks the shared lock even if the child still has its inherited descriptor open.

The code correctly avoids releasing from non-owning children (`OPERATION_OWNS_GLOBAL=false`), but it does not protect the inverse case: the owning parent releases while an inherited child continues.

#### Evidence

- Inherited child validation and non-ownership: `lib/operations.sh:643-654`, `lib/operations.sh:695-702`.
- Parent exports inherited FD/state/token: `lib/operations.sh:734-742`.
- Explicit unlock on release: `lib/operations.sh:756-775`.
- `setup.sh` acquires the global guard before calling child setup utilities: `setup.sh:448-451`, then calls `utilities/setup-system.sh`, `setup-storage.sh`, `setup-env.sh`, `setup-secrets.sh`, and `setup-firewall.sh` at `setup.sh:486-525`.
- `setup.sh` handles `INT` and `TERM` by calling `operation_release` immediately: `setup.sh:459-461`.
- The existing inherited-child test covers `kill -KILL "$$"` only, where the parent cannot run `operation_release`: `tests/test-operation-guards.sh:380-452`.

#### Realistic trigger

An operator runs full setup or another guarded parent workflow over SSH. A child utility is actively mutating host state. The parent shell receives `TERM`/`INT` or otherwise runs its cleanup trap while the child survives long enough to continue. The parent calls `operation_release 143`, explicitly unlocks the global flock, and exits while the child continues.

#### Operator or production impact

A second operator, timer, or Make target can acquire the global operation lock while the first operation-owned child is still mutating state. That creates exactly the class of overlap PR #224 was meant to prevent: package, setup, firewall, storage, config, or service lifecycle work can run concurrently with a still-active nested mutation.

#### Why existing safeguards are insufficient

The child's inherited descriptor is not enough if the parent explicitly unlocks the shared open file description. Metadata verification may become conservative, but the authoritative lock has already been released.

#### Why existing tests did not prevent or expose this

`tests/test-operation-guards.sh` validates the orphan-child case by killing the parent with `KILL`, which bypasses traps and therefore bypasses `operation_release`. It does not test `TERM`, `INT`, normal parent cleanup, or explicit `operation_release` while an inherited child remains alive.

### Suggested remediation

**Target**

`lib/operations.sh` — `operation_release`

**Suggested change**

Do not explicitly unlock the global flock. Close the owning descriptor and allow the kernel to release the lock only after the last inherited descriptor is closed. Keep explicit unlock behavior only for locks that are never intentionally inherited, or remove explicit unlocks consistently if descriptor-close semantics are acceptable.

**Why this is minimal**

It preserves the existing shell architecture, inherited-FD design, operation metadata, and status tooling. It changes only the release mechanism so the current inherited-lock contract becomes true.

**Suggested patch**

```diff
@@
     if [[ "$OPERATION_OWNS_GLOBAL" == "true" && -n "${OPERATION_LOCK_FD:-}" ]]; then
-        flock -u "$OPERATION_LOCK_FD" 2>/dev/null || true
         { eval "exec ${OPERATION_LOCK_FD}>&-"; } 2>/dev/null || true
         OPERATION_LOCK_FD=""
     fi
```

Consider adding a short comment explaining that the global lock is intentionally released by closing the last inherited descriptor, not by `LOCK_UN` on a possibly shared open file description.

**Suggested regression test**

```bash
test_inherited_child_survives_parent_release() {
    # Parent acquires the global operation lock.
    # Child sources lib/operations.sh, validates inherited global FD, and stays alive.
    # Parent calls operation_release 143 and exits normally.
    # While child is alive, a contender using --non-interactive skip must exit 75.
    # The contender must not enter until the child exits.
}
```

**Validation**

```bash
tests/test-operation-guards.sh
```

Run the new focused test on Ubuntu with real util-linux `flock` and `/proc` semantics.

### F-02: Supported Startup and Restart Paths Bypass the Operation Guard

**Severity:** High  
**Confidence:** High  
**Affected path:** `startup.sh`, `Makefile`, `utilities/safe-restart.sh`, `systemd/vaultwarden-startup.service`  
**Execution path:** `sudo make up`, `sudo make restart`, `sudo make safe-restart`, `sudo ./startup.sh`, `sudo ./startup.sh --force`, `vaultwarden-startup.service`  
**Contract violated:** service lifecycle and runtime secret/config mutation must not overlap restore, storage migration, key rotation, backups, or other globally guarded destructive operations.

#### Current behavior

`startup.sh` sources common libraries but not `lib/operations.sh`, and it never calls `operation_acquire` (`startup.sh:12-21`, `startup.sh:809-831`). It mutates runtime and service state by:

- loading/generated environment state (`startup.sh:238-255`);
- repairing permissions (`startup.sh:817-818`);
- creating persistent state and log directories (`startup.sh:303-378`);
- exporting Docker secrets under `/run/vaultwarden-oci/secrets` (`startup.sh:540-552`);
- pruning project Docker resources (`startup.sh:556-570`);
- running guarded child DNS/firewall helpers but continuing if they skip/fail (`startup.sh:621-643`, `startup.sh:686-723`);
- pulling images (`startup.sh:579-599`);
- removing/recreating/starting containers (`startup.sh:649-681`).

`make up` and `make restart` call `sync-env` and then `startup.sh` without a surrounding operation guard (`Makefile:296-333`, `Makefile:347-357`). `safe-restart.sh` snapshots the Compose model, then runs `startup.sh --force --skip-pull` and rollback Compose operations without its own operation guard (`utilities/safe-restart.sh:55-100`). `vaultwarden-startup.service` runs `startup.sh --skip-pull` directly and has no `SuccessExitStatus=75` contract (`systemd/vaultwarden-startup.service:12-15`).

#### Evidence

- `startup.sh` library imports omit `lib/operations.sh`: `startup.sh:12-21`.
- Startup mutations occur in `main`: `startup.sh:817-831`.
- Make startup targets call `sync-env` then `startup.sh`: `Makefile:296-333`, `Makefile:347-357`.
- Safe restart calls `startup.sh --force --skip-pull` and rollback `docker compose up`: `utilities/safe-restart.sh:80-100`.
- Systemd startup unit runs the unguarded script: `systemd/vaultwarden-startup.service:12-15`.

#### Realistic trigger

A restore is in progress and has stopped services or promoted partially restored state. A second shell, boot/startup service, or operator runs `sudo make up`, `sudo make restart`, or `sudo systemctl start vaultwarden-startup.service`. Startup can recreate runtime secrets and start containers against partially restored or migrated state.

Another realistic trigger is storage migration: while data is being moved and service start policy is intentionally controlled, startup can create directories, refresh runtime secrets, or start the stack against the wrong state root.

#### Operator or production impact

Vaultwarden can come online against incomplete restore or migration state. Runtime secret files can be regenerated from old or mid-change SOPS data. Docker containers can be removed or recreated while another operation expects the stack to remain stopped. A junior operator may see startup success even though the underlying guarded operation is still active or failed.

#### Why existing safeguards are insufficient

Some child helpers called by startup have their own guards, but the core startup mutation is Docker and runtime-secret lifecycle work in `startup.sh` itself. Child DNS/firewall skips do not prevent `docker compose up`.

Restore calling startup as a nested child while restore holds the global lock is not the problem; the problem is top-level supported startup paths.

#### Why existing tests did not prevent or expose this

`tests/test-privilege-contracts.sh` asserts that Make startup paths require root, but it does not assert that startup acquires the operation guard. `tests/test-start-policy.sh` checks start-policy documentation and systemd timer behavior, not global guard coverage for `startup.sh`.

### Suggested remediation

**Target**

`startup.sh`, `systemd/vaultwarden-startup.service`, and Make startup targets.

**Suggested change**

Source `lib/operations.sh` in `startup.sh` and acquire a startup operation guard before any mutation. Use interactive conflict handling for TTY operators and non-interactive skip semantics for systemd. Release in `EXIT`, `INT`, `HUP`, and `TERM` traps. Add `SuccessExitStatus=0 75` to the startup unit. Ensure Make `sync-env` either runs inside the same guarded startup path or is itself guarded through F-06.

**Why this is minimal**

It reuses the repository's existing shell guard library and keeps startup as the service lifecycle entry point.

**Suggested patch**

```diff
@@ startup.sh
 source "${SCRIPT_DIR}/lib/storage.sh"
+source "${SCRIPT_DIR}/lib/operations.sh"

@@ main() {
+  local _ops_policy="fail"
+  [[ -t 0 ]] || _ops_policy="skip"
+  operation_acquire \
+    --id startup \
+    --label "Startup" \
+    --specific-lock /run/lock/vaultwarden-startup.lock \
+    --non-interactive "$_ops_policy" || exit $?
+  trap 'rc=$?; operation_release "$rc"; exit "$rc"' EXIT
+  trap 'operation_release 130; exit 130' INT
+  trap 'operation_release 143; exit 143' HUP TERM
+  operation_set_phase "startup" "Preparing runtime and starting services"
   load_environment || exit 1
```

```diff
@@ systemd/vaultwarden-startup.service
 ExecStart=/bin/bash @PROJECT_ROOT@/startup.sh --skip-pull
+SuccessExitStatus=0 75
```

**Suggested regression test**

```bash
test_startup_blocks_during_restore_lock() {
    # Hold VW_OPERATIONS_LOCK with a fake restore operation.
    # Run startup.sh with mocked docker/secrets helpers and --skip-pull.
    # In non-interactive mode it must exit 75 before docker compose up.
}
```

**Validation**

```bash
tests/test-operation-guards.sh
tests/test-start-policy.sh
```

### F-03: Supported Secrets Configure/Edit/Rotate Paths Mutate Secrets Without Operation Coordination

**Severity:** High  
**Confidence:** High  
**Affected path:** `setup.sh`, `edit-secrets.sh`, `utilities/setup-secrets.sh`, `utilities/secrets-edit.sh`, `utilities/secrets-rotate.sh`  
**Execution path:** `sudo ./setup.sh secrets`, `sudo utilities/setup-secrets.sh configure`, `sudo ./edit-secrets.sh edit`, `sudo ./edit-secrets.sh rotate FIELD`, `sudo utilities/secrets-edit.sh`, `sudo utilities/secrets-rotate.sh FIELD`  
**Contract violated:** SOPS secrets, Age key material, recipient policy, and runtime secret staging must not be concurrently changed with restore, key rotation, startup, backup snapshotting, or another secrets mutation.

#### Current behavior

`setup.sh` dispatches supported `secrets` and `systemd` subcommands before acquiring the setup operation guard (`setup.sh:435-443`, guard starts at `setup.sh:448-451`). `utilities/setup-secrets.sh` does not source `lib/operations.sh` and does not call `operation_acquire` before bootstrap/configure mutations (`utilities/setup-secrets.sh:2460-2492`).

`edit-secrets.sh` requires root and dispatches to secrets utilities, but it does not acquire an operation guard (`edit-secrets.sh:60-100`). `utilities/secrets-edit.sh` decrypts, edits, re-encrypts, updates SOPS recipients, and atomically moves the encrypted file into place without the guard (`utilities/secrets-edit.sh:188-308`). `utilities/secrets-rotate.sh` decrypts, patches, re-encrypts, updates recipients, moves `secrets.yaml`, and best-effort exports runtime secrets without the guard (`utilities/secrets-rotate.sh:221-431`).

#### Evidence

- `setup.sh secrets` direct exec before guard: `setup.sh:435-443`.
- Full setup guard only begins after those phase dispatches: `setup.sh:448-451`.
- `setup-secrets.sh` bootstrap creates Age key, `/etc/vaultwarden/age-key.txt`, `.env` updates, `.sops.yaml`, and `secrets.yaml`: `utilities/setup-secrets.sh:2142-2347`.
- `setup-secrets.sh` transaction promotes ciphertext, `.sops.yaml`, and DR manifest: `utilities/setup-secrets.sh:2027-2121`.
- `secrets-edit.sh` promotes encrypted output: `utilities/secrets-edit.sh:270-308`.
- `secrets-rotate.sh` promotes encrypted output and exports runtime secrets: `utilities/secrets-rotate.sh:377-431`.

#### Realistic trigger

An operator rotates a secret with `sudo ./edit-secrets.sh rotate admin_token` while guarded Age key rotation or restore is running. The unguarded rotate decrypts the old file, the guarded operation rekeys or restores `secrets.yaml`, and the unguarded rotate later moves its staged ciphertext over the guarded result.

Another trigger is `sudo ./setup.sh secrets` during restore or startup. It can update `.sops.yaml`, `secrets.yaml`, `/etc/vaultwarden/age-key.txt`, `.env`, and runtime secret files while another operation assumes those inputs are stable.

#### Operator or production impact

Secrets can be reverted, re-encrypted to the wrong recipient set, exported inconsistently to runtime Docker secret files, or snapshotted mid-transition. That can break future backup/restore, make the running stack use stale credentials, or undermine a completed key rotation.

#### Why existing safeguards are insufficient

The secrets transaction protects against partial local promotion inside one script, but it does not serialize against other repository workflows that read or write the same files. Root checks and atomic `mv` do not provide cross-workflow ordering.

#### Why existing tests did not prevent or expose this

`tests/test-setup-secrets-transaction.sh` tests transaction rollback behavior, not cross-workflow locking. `tests/test-privilege-contracts.sh` verifies root and permission behavior. `tests/test-operation-guards.sh` does not assert that secrets configure/edit/rotate acquire the shared operation guard.

### Suggested remediation

**Target**

`utilities/setup-secrets.sh`, `utilities/secrets-edit.sh`, `utilities/secrets-rotate.sh`, and optionally `edit-secrets.sh` dispatcher tests.

**Suggested change**

Acquire the shared operation guard for mutating secrets subcommands. Let full setup pass the inherited global FD to `setup-secrets.sh bootstrap`; direct `setup.sh secrets` and direct utilities should acquire their own guard. Read-only `view`/`list` can remain unguarded unless they write recovery output or runtime state.

**Why this is minimal**

It reuses existing operation inheritance rather than introducing a new secrets lock model. It preserves the current transaction code and only wraps it in repository-wide coordination.

**Suggested patch**

```diff
@@ utilities/setup-secrets.sh
 source "${PROJECT_ROOT}/lib/common.sh"
 init_common_lib "$0"
+source "${PROJECT_ROOT}/lib/operations.sh"

@@ main() {
     load_project_environment || exit 1
+    case "$subcmd" in
+        bootstrap|configure|breakglass)
+            operation_acquire \
+              --id secrets \
+              --label "Secrets" \
+              --specific-lock /run/lock/vaultwarden-secrets.lock || exit $?
+            trap 'rc=$?; operation_release "$rc"; exit "$rc"' EXIT
+            trap 'operation_release 130; exit 130' INT
+            trap 'operation_release 143; exit 143' HUP TERM
+            operation_set_phase "$subcmd" "Secrets ${subcmd}"
+            ;;
+    esac
```

```diff
@@ utilities/secrets-rotate.sh
 source "${PROJECT_ROOT}/lib/common.sh"
 init_common_lib "$0"
+source "${PROJECT_ROOT}/lib/operations.sh"
+operation_acquire --id secrets --label "Secrets" \
+  --specific-lock /run/lock/vaultwarden-secrets.lock || exit $?
+trap 'rc=$?; operation_release "$rc"; perform_cleanup; exit "$rc"' EXIT
```

Apply the same pattern to `utilities/secrets-edit.sh` for write mode.

**Suggested regression test**

```bash
test_secrets_rotate_skips_when_restore_lock_is_active() {
    # Hold the global operations lock as restore.
    # Invoke secrets-rotate with mocked sops/secret collectors.
    # It must not decrypt, patch, mv, or export runtime secrets while restore is active.
}
```

**Validation**

```bash
tests/test-operation-guards.sh
tests/test-setup-secrets-transaction.sh
```

### F-04: `vaultwarden-iptables.service` Does Not Match the Installed Script Layout or Guarded Runtime Contract

**Severity:** Medium  
**Confidence:** High  
**Affected path:** `systemd/vaultwarden-iptables.service`, `utilities/setup-systemd.sh`, `utilities/setup-firewall.sh`  
**Execution path:** `sudo ./setup.sh systemd install`, then `systemctl start vaultwarden-iptables.service` or boot/Docker restart  
**Contract violated:** systemd entry points must execute the same supported script semantics as direct invocation, and guarded services must be able to write lock/state paths and distinguish expected contention from failure.

#### Current behavior

`utilities/setup-systemd.sh` copies `lib/` to `/opt/vaultwarden-scripts/lib/`, but flat-installs `utilities/setup-firewall.sh` as `/opt/vaultwarden-scripts/setup-firewall.sh` (`utilities/setup-systemd.sh:647-706`, `utilities/setup-systemd.sh:718-737`). The script computes:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/log.sh"
```

When flat-installed at `/opt/vaultwarden-scripts/setup-firewall.sh`, `PROJECT_ROOT` becomes `/opt`, so it tries to source `/opt/lib/log.sh`, not `/opt/vaultwarden-scripts/lib/log.sh`.

The unit also runs `setup-firewall.sh --phase iptables` without a non-interactive skip policy, without `SuccessExitStatus=75`, and with `ReadWritePaths=/run/xtables.lock` only (`systemd/vaultwarden-iptables.service:26-40`). The script itself acquires the global operation guard in non-dry-run mode (`utilities/setup-firewall.sh:541-555`) and can run `operation_package_run apt-get install` for `netfilter-persistent` (`utilities/setup-firewall.sh:507-525`).

#### Evidence

- Flat install special case: `utilities/setup-systemd.sh:703-706`, `utilities/setup-systemd.sh:721-724`.
- Script path discovery assumes parent repo root: `utilities/setup-firewall.sh:6-19`.
- Unit flat path and limited write paths: `systemd/vaultwarden-iptables.service:26-40`.
- Guard acquisition in the script: `utilities/setup-firewall.sh:541-555`.
- Package install path inside iptables phase: `utilities/setup-firewall.sh:507-525`.
- Focused local simulation of the installed layout failed before help output:

```text
./setup-firewall.sh: line 10: .../tmp.../lib/log.sh: No such file or directory
simulated_flat_install_rc=1
```

#### Realistic trigger

An operator installs systemd automation with `sudo ./setup.sh systemd install`. On boot, Docker restart, or manual `systemctl start vaultwarden-iptables.service`, the service invokes the flat-installed script. It fails before reapplying NAT/DOCKER-USER rules. If the layout were fixed without unit/guard adjustments, contention with another operation would likely be treated as unit failure rather than expected skip.

#### Operator or production impact

Firewall/NAT remediation intended to run after Docker starts does not run through the installed unit. A host can miss expected egress NAT or DOCKER-USER hardening after boot or Docker changes. If contention occurs after path repair, expected lock contention can produce noisy service failures instead of clean skip semantics.

#### Why existing safeguards are insufficient

Direct repo invocation of `utilities/setup-firewall.sh` works because the script resides under `utilities/`. The systemd-installed path is different. Existing start-policy tests check StartLimit placement but do not simulate the installed script layout or verify the firewall script can source `lib/` after installation.

#### Why existing tests did not prevent or expose this

`tests/test-start-policy.sh` checks the unit file text but not an installed-layout smoke test. `utilities/setup-systemd.sh validate` checks that `/opt/vaultwarden-scripts/setup-firewall.sh` exists and is executable, but not that it can source libraries or run `--help`.

### Suggested remediation

**Target**

`utilities/setup-systemd.sh`, `systemd/vaultwarden-iptables.service`, `utilities/setup-firewall.sh`

**Suggested change**

Preserve the `utilities/` install path for `setup-firewall.sh` and update the unit to call `/opt/vaultwarden-scripts/utilities/setup-firewall.sh`. Add lock/state write paths and expected-contention handling. Alternatively, if flat install must remain, make `setup-firewall.sh` explicitly detect `/opt/vaultwarden-scripts/lib`.

**Why this is minimal**

Keeping the structured utility path matches the script's existing self-location model and avoids adding special-case path logic to the firewall script.

**Suggested patch**

```diff
@@ utilities/setup-systemd.sh
-        utilities/setup-firewall.sh   # flat-installed (basename only) for iptables.service compatibility
+        utilities/setup-firewall.sh
@@
-        if [[ "$script" == "utilities/setup-firewall.sh" ]]; then
-            dest="$OPT_SCRIPTS_DIR/$(basename "$script")"
-        else
-            dest="$OPT_SCRIPTS_DIR/$script"
-        fi
+        dest="$OPT_SCRIPTS_DIR/$script"
```

```diff
@@ systemd/vaultwarden-iptables.service
-ExecStart=/bin/bash /opt/vaultwarden-scripts/setup-firewall.sh --phase iptables
+ExecStart=/bin/bash /opt/vaultwarden-scripts/utilities/setup-firewall.sh --phase iptables --auto
+SuccessExitStatus=0 75
@@
-RuntimeDirectory=vaultwarden-iptables
+RuntimeDirectory=vaultwarden vaultwarden-iptables
 Environment=TMPDIR=/run/vaultwarden-iptables
-ReadWritePaths=/run/xtables.lock
+ReadWritePaths=/run/xtables.lock /run/lock /run/vaultwarden
```

Also update `setup-firewall.sh` acquisition for non-TTY/systemd skip behavior:

```diff
-operation_acquire --id setup --label "Setup" || exit $?
+_policy="fail"; [[ -t 0 ]] || _policy="skip"
+operation_acquire --id setup --label "Setup" --non-interactive "$_policy" || exit $?
```

**Suggested regression test**

```bash
test_iptables_installed_layout_can_source_libs() {
    tmp=$(mktemp -d)
    mkdir -p "$tmp/opt/vaultwarden-scripts"
    cp -R lib "$tmp/opt/vaultwarden-scripts/lib"
    cp -R utilities "$tmp/opt/vaultwarden-scripts/utilities"
    (cd "$tmp/opt/vaultwarden-scripts" &&
      bash utilities/setup-firewall.sh --help >/dev/null)
}
```

**Validation**

```bash
tests/test-start-policy.sh
sudo utilities/setup-systemd.sh validate
```

### F-05: `add-apt-repository` Bypasses the Package Helper and Package-Child Detection

**Severity:** Medium  
**Confidence:** High  
**Affected path:** `utilities/setup-system.sh`, `lib/operations.sh`  
**Execution path:** `sudo ./setup.sh install`, `sudo utilities/setup-system.sh` on Ubuntu hosts without `universe` enabled  
**Contract violated:** package-manager work must use output-aware retry semantics and must not be automatically terminated by operation stop/force-stop.

#### Current behavior

`utilities/setup-system.sh` wraps most apt/dpkg commands with `operation_package_run`, but `ensure_universe_enabled` runs:

```bash
add-apt-repository -y universe 2>/dev/null || { ... }
```

This command can mutate apt sources and invoke apt/dpkg-related work. It is outside the retry/output classifier and hides stderr. The package-child detector only checks process `comm` names:

```bash
apt|apt-get|dpkg|unattended-upgrade|unattended-upgr)
```

It does not include `add-apt-repository`, `apt-add-repository`, or command-line inspection for those scripts.

#### Evidence

- Direct `add-apt-repository`: `utilities/setup-system.sh:369-386`.
- Wrapped apt commands nearby: `utilities/setup-system.sh:385`, `utilities/setup-system.sh:395`, `utilities/setup-system.sh:403`, `utilities/setup-system.sh:442`, `utilities/setup-system.sh:455`, `utilities/setup-system.sh:649`.
- Package-child detector: `lib/operations.sh:386-397`.
- `operation_package_run` classifier: `lib/operations.sh:852-890`.

#### Realistic trigger

On a new Ubuntu host where `universe` is not enabled, setup runs `add-apt-repository`. If apt/dpkg locks are held by unattended upgrades or another apt job, the command can fail without the helper's wait/retry behavior. If an operator uses `make operations` stop/force-stop during this period, detection may not classify the active descendant as package-manager work and may terminate it.

#### Operator or production impact

Setup can fail unnecessarily during normal apt lock contention, and a force-stop can violate the project's package-manager safety contract by interrupting repository/package state mutation.

#### Why existing safeguards are insufficient

Fallback manual source-file creation is only used after `add-apt-repository` fails. It does not give the direct path retry semantics or package-stop protection. Hiding stderr with `2>/dev/null` also suppresses the output the classifier would need.

#### Why existing tests did not prevent or expose this

`tests/test-operation-guards.sh` asserts CrowdSec package calls use `operation_package_run`; it does not perform an all-repository package command inventory. `tests/test-crowdsec-config.sh` is CrowdSec-specific.

### Suggested remediation

**Target**

`utilities/setup-system.sh` and `lib/operations.sh`

**Suggested change**

Run `add-apt-repository` through `operation_package_run` without discarding stderr, and extend package-child detection to recognize repository-helper command lines.

**Why this is minimal**

It keeps the existing dependency setup flow and package helper. No new package management abstraction is needed.

**Suggested patch**

```diff
@@ utilities/setup-system.sh
-        if command -v add-apt-repository >/dev/null 2>&1; then
-            add-apt-repository -y universe 2>/dev/null || {
+        if command -v add-apt-repository >/dev/null 2>&1; then
+            operation_package_run add-apt-repository -y universe || {
                 log_warn "add-apt-repository failed — adding universe source manually"
```

```diff
@@ lib/operations.sh
-            apt|apt-get|dpkg|unattended-upgrade|unattended-upgr)
+            apt|apt-get|dpkg|unattended-upgrade|unattended-upgr|add-apt-repository|apt-add-repository)
                 return 0
```

If `comm` is not reliable for script interpreters, extend `_operation_related_rows` or `_operation_has_package_manager_child` to inspect `/proc/<pid>/cmdline` for `add-apt-repository` and `apt-add-repository`.

**Suggested regression test**

```bash
test_setup_system_add_apt_repository_uses_package_helper() {
    grep -Fq 'operation_package_run add-apt-repository -y universe' utilities/setup-system.sh
}
```

**Validation**

```bash
tests/test-operation-guards.sh
```

### F-06: Supported Env and Systemd Configuration Paths Mutate Install State Without Operation Coordination

**Severity:** Medium  
**Confidence:** High  
**Affected path:** `setup.sh`, `utilities/setup-systemd.sh`, `utilities/setup-env.sh`, `utilities/env-edit.sh`, `Makefile`  
**Execution path:** `sudo ./setup.sh systemd install`, `sudo utilities/setup-systemd.sh install`, `sudo utilities/setup-env.sh ...`, `sudo utilities/env-edit.sh sync`, `sudo make sync-env`, `sudo make edit-env`  
**Contract violated:** supported mutating install/configuration paths should not have weaker safety merely because the operator chose a direct script or Make helper.

#### Current behavior

`setup.sh systemd` dispatches directly to `utilities/setup-systemd.sh` before the setup operation guard (`setup.sh:435-443`). `utilities/setup-systemd.sh` does not source `lib/operations.sh`; its install path copies scripts and libraries to `/opt/vaultwarden-scripts`, installs `/etc/vaultwarden/age-key.txt`, copies rclone config, regenerates runtime env files, installs unit files, reloads systemd, enables startup, and enables timers (`utilities/setup-systemd.sh:634-914`).

`utilities/setup-env.sh` writes `.env`, generated state artifacts, `dr-manifest.env`, recovery card, and `docker-compose.yml` without an operation guard (`utilities/setup-env.sh:286-337`, `utilities/setup-env.sh:339-370`). `utilities/env-edit.sh sync` copies repo `.env` into `${PROJECT_STATE_DIR}/config/install.env` and `/etc/vaultwarden/vaultwarden.env`; `edit` modifies repo `.env` and then calls sync (`utilities/env-edit.sh:250-325`). Make exposes these as supported root targets (`Makefile:262-268`).

#### Evidence

- Early `setup.sh systemd` dispatch: `setup.sh:435-443`.
- Systemd install mutating path: `utilities/setup-systemd.sh:634-914`.
- Systemd install regenerates env files through `env-edit sync`: `utilities/setup-systemd.sh:599-607`, `utilities/setup-systemd.sh:837`.
- Setup-env `.env` promotion: `utilities/setup-env.sh:286-290`.
- Setup-env state artifacts and manifest: `utilities/setup-env.sh:295-337`.
- Setup-env Compose promotion: `utilities/setup-env.sh:339-370`.
- Env sync/edit mutations: `utilities/env-edit.sh:250-325`.
- Make targets: `Makefile:262-268`.

#### Realistic trigger

An operator runs `sudo ./setup.sh systemd install` after a pull while a scheduled backup or maintenance operation is running from `/opt/vaultwarden-scripts`. The install path can replace scripts/libs and regenerate runtime env files while jobs are active or just about to spawn child utilities.

Another trigger is `sudo make sync-env` or `sudo utilities/env-edit.sh edit` while restore/startup/update uses the previously loaded environment, resulting in split current/next runtime configuration and misleading installed env state.

#### Operator or production impact

Installed automation can be refreshed mid-operation, generated runtime env can change while another operation assumes a stable config snapshot, and timers may be enabled while install itself is not visible through `make operations`. This is less immediately destructive than F-02/F-03, but it is a real supported-path safety mismatch.

#### Why existing safeguards are insufficient

Root checks, atomic file moves, and idempotence do not coordinate with other repository workflows. `setup-systemd.sh install` is documented as a direct supported command, not a private internal helper.

#### Why existing tests did not prevent or expose this

Current tests focus start-policy, permissions, generated env correctness, and direct help behavior. They do not assert that supported env/systemd mutation paths acquire or inherit the operation guard.

### Suggested remediation

**Target**

`utilities/setup-systemd.sh`, `utilities/setup-env.sh`, `utilities/env-edit.sh`, and Make/startup integration.

**Suggested change**

Add operation acquisition to mutating subcommands:

- `setup-systemd.sh install` and `remove`: global guard with specific systemd lock.
- `setup-env.sh` non-dry-run writes: global guard or inherited global guard.
- `env-edit.sh sync` and `edit`: global guard or inherited global guard.
- `status`/`validate` read-only paths should remain unguarded unless they mutate.

Coordinate with F-02 so `make up` does not release the guard between `sync-env` and `startup`.

**Why this is minimal**

It keeps the existing scripts and direct operator paths, and reuses inherited operation semantics where setup/startup already owns the guard.

**Suggested patch**

```diff
@@ utilities/setup-systemd.sh
 source "${PROJECT_ROOT}/lib/common.sh"
 init_common_lib "$0"
+source "${PROJECT_ROOT}/lib/operations.sh"

@@ install_units() {
+    operation_acquire \
+      --id systemd-install \
+      --label "Systemd install" \
+      --specific-lock /run/lock/vaultwarden-systemd.lock || exit $?
+    trap 'rc=$?; operation_release "$rc"; exit "$rc"' EXIT
+    operation_set_phase "install" "Installing systemd automation"
```

```diff
@@ utilities/env-edit.sh
+source "${PROJECT_ROOT}/lib/operations.sh"
@@ _cmd_sync() {
+  operation_acquire --id env-sync --label "Environment sync" \
+    --specific-lock /run/lock/vaultwarden-env.lock || return $?
+  trap 'rc=$?; operation_release "$rc"; return "$rc"' RETURN
```

Use an implementation pattern that avoids returning from a top-level trap incorrectly; the pseudodiff is behavioral, not byte-for-byte.

**Suggested regression test**

```bash
test_env_sync_respects_active_restore_operation() {
    # Hold the global operation lock as restore.
    # Invoke env-edit sync with temp PROJECT_STATE_DIR and VW_SYNC_ETC_DIR.
    # It must not write install.env or vaultwarden.env while restore is active.
}
```

**Validation**

```bash
tests/test-operation-guards.sh
tests/test-env-edit.sh
tests/test-start-policy.sh
```

## Low-Severity Opportunities

### L-01: `operation_list` Static ID Inventory Omits Some Current Operation IDs

`_operation_known_label` knows `maintenance-db` and `storage-setup` (`lib/operations.sh:777-795`), and current scripts use `maintenance-db`, `storage-setup`, and `health-check` (`utilities/maintenance-db-maint.sh:209-213`, `utilities/setup-storage.sh:546-555`, `utilities/maintenance-health.sh:147-153`). But `operation_list` statically lists:

```text
crowdsec-setup maintenance backup restore setup storage-migration update key-rotate uninstall health-repair dns-update firewall-update permission-repair
```

at `lib/operations.sh:832-849`, omitting those IDs.

Dynamic state-file discovery still shows an active/previous unknown operation if a state file exists, so this is not a main finding. The polish improvement is to add all current operation IDs to the static idle list so `sudo make operations` presents the complete known operation model even before a state file exists.

## Rejected Candidate Findings

### Health Check `--no-global`

**Candidate concern:** health inspection uses `operation_acquire --no-global`.  
**Why it initially looked risky:** it is an operation-acquire call outside the global lock.  
**Why current code or project scope makes it non-finding:** non-fix health mode is an observation path with a specific health lock, and `--fix` uses the global guard as `health-repair`. This preserves operator visibility during unrelated operations.

### Failure Notification Direct `flock`

**Candidate concern:** `utilities/notify-failure.sh` uses direct `flock`.  
**Why it initially looked risky:** direct locks can bypass the new shared operation architecture.  
**Why current code or project scope makes it non-finding:** this is a notification de-duplication/cooldown lock, not a mutating operation guard. It should not wait behind the failed operation's global lock.

### Migration Direct Lock

**Candidate concern:** `lib/migrate.sh` retains direct `flock`.  
**Why it initially looked risky:** direct storage locks can conflict with operation lock ordering.  
**Why current code or project scope makes it non-finding:** current storage migration acquires the global operation guard before migration work, and the direct migration lock is duplicate-copy protection for one resource.

### Conservative Global Serialization

**Candidate concern:** backup, maintenance, update, restore, key rotation, and uninstall serialize broadly.  
**Why it initially looked risky:** some operations could theoretically run in parallel.  
**Why current code or project scope makes it non-finding:** this is a small deployment, and conservative serialization is safer than maximizing concurrency. I found no practical harm from this over-serialization.

### Source-Pattern Tests

**Candidate concern:** several tests enforce source patterns rather than runtime behavior.  
**Why it initially looked risky:** static tests can miss runtime regressions.  
**Why current code or project scope makes it non-finding:** source-pattern tests are useful for architecture policy. Test weakness is called out only where it failed to cover a demonstrated defect.

### Backup and Maintenance systemd Exit `75`

**Candidate concern:** systemd units may hide real failures by treating `75` as success.  
**Why it initially looked risky:** `SuccessExitStatus=75` can hide failures if scripts misuse that code.  
**Why current code or project scope makes it non-finding:** backup and maintenance acquisition paths intentionally use `--non-interactive skip`, and the units document expected contention. I did not find a path where a real backup/rclone failure is converted to `75`.

## Runtime Validation Limits

The audit environment was macOS-like and did not provide the full target runtime:

- No real util-linux `flock` command was available.
- `/proc` descriptor and process-start semantics were not available.
- Systemd was not available.
- Docker/Compose runtime validation was not available.
- Ubuntu apt/dpkg behavior could not be exercised.
- Root/sudo production flows were not executed.
- OCI, Cloudflare, CrowdSec live services, and real secrets were not used.
- The local `/bin/bash` behaved like Bash 3 for associative arrays; scripts using `declare -A` failed under `set -u` with `DEBUG: unbound variable`. This is a local test-environment limitation, not a confirmed Ubuntu production defect.

The F-01 inherited-lock finding depends on Linux `flock` open-file-description semantics. I could not reproduce it locally because the host lacks real `flock` and `/proc`, but the current code and Linux semantics make the path strongly traceable. It should be verified on Ubuntu with real `flock`.

I did run one non-destructive installed-layout simulation for `vaultwarden-iptables.service` by copying `setup-firewall.sh` and `lib/` to a temp directory in the same layout used by `setup-systemd.sh`; it failed to source `lib/log.sh` from the expected path. That supports F-04.

## Tests and Commands Run

Baseline and git state:

```text
git status --short --branch
  ## delta...origin/delta

git rev-parse --abbrev-ref HEAD
  delta

git rev-parse HEAD
  d7e09ee031754b25b1a4e2db04b9c6ec60f89135
```

Validation:

```text
find . -path './.git' -prune -o -type f -name '*.sh' -print0 | xargs -0 -n 1 bash -n
  PASS

find . -path './.git' -prune -o -type f -name '*.sh' -print0 | xargs -0 shellcheck
  FAIL: default ShellCheck reported info-level findings.

find . -path './.git' -prune -o -type f -name '*.sh' -print0 | xargs -0 shellcheck --severity=warning
  PASS

tests/test-operation-guards.sh
  FAIL in local environment: lib/log.sh associative-array path failed under local Bash; holder operation did not acquire lock.

tests/test-privilege-contracts.sh
  FAIL in local environment during command-reference generation after help commands hit the same local Bash issue. The generated docs change was restored.

tests/test-backup-restore-behavior.sh
  FAIL in local environment: same local Bash issue before restore plan probe completed.

tests/test-start-policy.sh
  PASS

tests/test-operator-ui.sh
  FAIL in local environment: same local Bash issue.

tests/test-crowdsec-config.sh
  PASS

make test-unit
  FAIL in local environment after several tests passed; local Bash issue appeared and the run later stopped at permission-repair contract output.

temporary installed-layout simulation for setup-firewall.sh
  FAIL as expected for F-04: flat-installed script looked for ../lib instead of installed sibling lib.
```

After test cleanup and before writing this report, the worktree was clean. The only intended repository modification from this audit is this report file.

## Final Assessment

1. **Is the shared operation-guard architecture internally coherent in current `delta`?**  
   Mostly yes. The global/specific lock model, inherited lock validation, metadata, status, and package helper form a coherent architecture. F-01 shows one core lock-lifetime defect in release semantics.

2. **Did PR #224 miss any mutating supported workflow that requires the global or a narrower operation guard?**  
   Yes. Startup/restart, secrets configure/edit/rotate, env sync/edit, setup-env, and setup-systemd install/remove are supported mutating paths with missing coordination.

3. **Is any workflow guarded too narrowly, with lock lifetime shorter than actual mutation lifetime?**  
   Yes. F-01 can release the global lock before an inherited mutating child exits.

4. **Can a nested workflow incorrectly acquire, inherit, update, or release operation state?**  
   Yes. Inheritance validation is sound, but parent release can undermine the inherited lock. Non-owning child phase updates are otherwise an intentional current design.

5. **Can a parent terminate or release while an operation-owned mutating child continues?**  
   Yes. F-01 is exactly this failure mode.

6. **Can controlled stop or force-stop realistically signal the wrong process or miss a relevant operation-owned process?**  
   I did not confirm wrong-process signalling for the core PID identity logic. I did confirm F-05: package-child detection can miss `add-apt-repository`, allowing unsafe termination of package-related work.

7. **Is apt/dpkg activity consistently protected from unsafe automated termination?**  
   Not fully. Most apt/dpkg paths are protected, but F-05 leaves `add-apt-repository` outside the helper and detector.

8. **Are all package-manager paths using appropriate output-aware retry semantics?**  
   No. `add-apt-repository -y universe` bypasses `operation_package_run`.

9. **Do systemd services correctly distinguish expected contention exit 75 from real failure?**  
   Mostly for backup/maintenance/DNS/firewall/health paths. `vaultwarden-iptables.service` does not yet match the guarded contention contract.

10. **Can systemd stop or timeout semantics undermine the operation library's safety behavior?**  
   For the reviewed scheduled backup/maintenance paths, I did not confirm a systemd timeout defect. `vaultwarden-iptables.service` has a more immediate execution/layout and lock-path mismatch.

11. **Does `sudo make operations` truthfully guide an operator after an interruption or SSH disconnect?**  
   Generally yes for active/stale state, with a low-severity completeness issue: the static operation list omits some current IDs.

12. **Do supported Make, direct-script, systemd, parent, restore, and recovery entry points provide consistent safety?**  
   No. Startup/restart, secrets, env, and systemd install paths differ materially by entry point.

13. **Are final success and failure states truthful?**  
   I did not confirm a broad success-message defect in backup/restore/maintenance. F-04 can make the iptables unit fail before doing its intended work, and F-02 can make startup success unsafe when it overlaps another operation.

14. **Are existing tests protecting the important runtime contracts?**  
   Partially. They protect many source contracts, but they miss parent `operation_release` with a live inherited child, startup guard coverage, secrets guard coverage, installed firewall layout, and all-repository package-helper coverage.

15. **Did the complete repository review identify any additional Critical, High, or Medium gaps?**  
   Yes: F-01 through F-06.

16. **What exact findings should be handed to a coding agent for one focused follow-up PR?**  
   Hand off F-01, F-02, F-03, F-04, F-05, and F-06. Prioritize F-01 through F-03 first because they block production-ready status.

Blocking finding IDs: F-01, F-02, F-03

BLOCK PRODUCTION-READY STATUS
