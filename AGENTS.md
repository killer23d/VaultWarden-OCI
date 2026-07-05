# AGENTS.md — VaultWarden-OCI Post-PR #224 Repository-Wide Contract Audit

## Purpose

This agent session is an independent, report-only, repository-wide audit of the current `delta` branch of VaultWarden-OCI after the merge of PR #224.

PR #224 introduced a shared repo-wide operation-guard architecture and changed coordination behavior across a large portion of the repository.

The audit is intentionally broader than a PR review.

The objective is **not** to confirm that PR #224 was implemented as described.

The objective is to inspect the complete current repository and determine whether the architecture now chosen by the repository is applied correctly and consistently across every supported execution path.

Assume PR #224 may have been competently designed and implemented while still containing or exposing:

* missed entry points
* incomplete workflow migration
* incorrect nesting assumptions
* operation guard gaps
* over-broad serialization
* under-broad serialization
* inherited-lock defects
* lock lifetime defects
* stale or misleading operation metadata
* unsafe interruption behavior
* incorrect signal or child-process handling
* package-manager retry gaps
* systemd semantic mismatches
* unsupported direct-script behavior
* entry-point-dependent behavior
* partial-failure success reporting
* tests that verify source structure without protecting runtime behavior
* documentation that no longer matches executable behavior
* adjacent pre-existing defects made more important by the new architecture

The audit must follow evidence through the current code.

Do not assume PR descriptions, previous reports, comments, tests, or documentation are ground truth.

---

## Project context

VaultWarden-OCI is a small-team self-hosted Vaultwarden deployment for Oracle Cloud Infrastructure on Ubuntu.

The intended production environment is approximately 10 users.

The primary operator may be a junior Linux or Docker administrator.

The system is intended to be largely "set and forget" and may receive close operator attention primarily during:

* incidents
* failed health checks
* backup problems
* restore
* disaster recovery
* storage migration
* key operations
* CrowdSec or firewall problems
* maintenance
* updates

Project priorities, in order:

1. Security
2. Reliable backup, restore, and disaster recovery
3. Truthful operator state and failure reporting
4. Safe interruption and concurrency behavior
5. Simple junior-operator workflows
6. Minimal moving parts
7. Avoid enterprise-style complexity unless a demonstrated defect requires it

A few hours of downtime may be acceptable.

The following are not acceptable:

* silent data loss
* secret or private-key exposure
* incomplete restore presented as successful
* backup protection presented as complete when required protection failed
* concurrent destructive or mutating operations corrupting state
* unsafe termination of package-manager work
* lock bypasses hidden behind `--force`
* stale metadata causing unsafe operator action
* systemd treating a real operation failure as expected contention
* expected timer contention generating false incident alerts
* an SSH disconnect leaving the operator with unsafe recovery instructions
* direct script invocation silently having weaker safety than the Makefile path
* a parent workflow releasing shared protection while an operation-owned child is still mutating state

---

## Branch and audit baseline

Primary branch:

```text
delta
```

The audit must use the current `delta` HEAD at the start of the review.

Record:

```bash
git status --short
git branch --show-current
git rev-parse HEAD
git log --oneline --decorate -30
```

Record the exact audited commit SHA in the report.

PR #224 is historical context and an important risk signal because it changed the repository-wide coordination architecture.

Relevant merged PR:

```text
PR #224 — Add shared operation guards
```

Inspect PR #224 through local git history where available.

Useful commands may include:

```bash
git log --all --oneline --decorate --grep='operation guard'
git show --stat 81f6b96ff09b3c208c542be9c25cf81a72968472
git show --summary 81f6b96ff09b3c208c542be9c25cf81a72968472
git diff 7eac97e9df1df781859d159f0c77c17e17722e9f..97f1b9502279a891ffc2623c74f367cc6396e36e
```

Do not depend on those exact SHAs if current local history presents PR #224 differently because of merge strategy or subsequent history.

The **current `delta` implementation is the audit target**.

PR #224 is evidence of intended architecture, not ground truth.

---

## Previous reports and prior work

Read the existing files under:

```text
reports/
```

Use them to understand:

* previous findings
* project decisions
* intentionally accepted limitations
* previously rejected overengineering
* known historical problem areas

Previous reports are not the audit checklist.

Do not perform a shallow closure review of an old report.

Do not assume an old finding is still present.

Do not assume a closed finding cannot have reappeared through another path.

Do not avoid raising a current defect merely because an earlier report did not mention it.

The required mindset is:

```text
current repository
    ->
derive actual architecture and contracts
    ->
inventory all supported entry points and mutating workflows
    ->
trace complete execution paths
    ->
challenge contract coverage
    ->
report only confirmed or strongly traceable defects
```

Not:

```text
old report
    ->
check boxes
    ->
declare complete
```

---

## Review mode: report only

This is a read-only code audit with one report artifact.

Do not fix findings.

Do not modify functional code.

Do not refactor scripts.

Do not rewrite documentation.

Do not update tests.

Do not update systemd units.

Do not regenerate committed generated documentation except temporarily for drift comparison when safe.

Do not create a pull request.

Do not create a fix branch.

Do not commit.

Do not push.

Do not modify `AGENTS.md` during the audit.

The operator may have installed this `AGENTS.md` specifically for the audit session. Any pre-existing `AGENTS.md` working-tree change is not an audit finding and must not be reverted or altered.

The only audit output to create or update is:

```text
reports/post-pr224-repository-wide-contract-audit.md
```

Suggested patches and test snippets belong inside the report only.

Before finishing, verify that no audit command unintentionally changed functional repository files.

---

## Audit philosophy

This is a **contract-driven forensic audit**.

Before searching for defects, reconstruct what the repository currently promises.

A finding must normally demonstrate a mismatch between:

```text
chosen repository contract
        and
actual current execution behavior
```

or demonstrate a concrete pre-existing defect discovered while tracing a high-risk current execution path.

Do not judge the repository primarily against generic enterprise best practices.

Do not recommend a different architecture merely because another architecture is common.

Do not optimize for abstraction purity.

Do not optimize for maximum concurrency.

Do not optimize for support of hypothetical future deployments.

Prioritize practical production safety for this repository.

---

## Architecture and operational invariants

Preserve these project decisions unless current code demonstrates that the implementation violates its own intended contract.

### Privilege model

Lifecycle and maintenance operations are root-operated.

Expected commands include:

```text
sudo make up
sudo make restart
sudo make backup
sudo make restore
sudo make update
```

Do not recommend converting the project back to a normal-user-operated lifecycle merely for convention.

Inspect privilege enforcement for consistency between:

* Make targets
* direct scripts
* nested script calls
* systemd services
* recovery paths

A privilege mismatch is a finding only when it creates a real supported-path failure, security problem, or unsafe state.

### Secrets model

SOPS + Age is the intended secrets architecture.

The live operational Age private key is separate from the offline recovery Age key.

The offline recovery Age private key must never be stored persistently on the server.

Runtime Docker secrets are staged under:

```text
/run/vaultwarden-oci/secrets
```

Persistent state normally resides under:

```text
/var/lib/vaultwarden
```

Do not weaken:

* offline key custody
* exact save acknowledgements
* explicit key-loss warnings
* key rotation safety gates
* recovery-material protection

### Backup model

Backup tiers are:

```text
db
full
emergency
```

The project expects a 3-2-1 backup strategy.

Emergency backups may contain sensitive clone-grade recovery material and require independent protection.

Distinguish:

```text
created
encrypted
verified
synced
offsite
restorable
complete DR protection
```

These are not equivalent states.

### Security model

Cloudflare and CrowdSec are intentional mandatory architecture components for the deployed design.

Do not recommend removing them merely to simplify the project.

### Scope model

This is a small deployment.

Do not recommend:

* a lock daemon
* a job queue
* a workflow database
* a persistent operations database
* Redis
* distributed locking
* Kubernetes
* a plugin architecture
* a YAML operation registry
* a generalized workflow engine
* a terminal UI framework
* a new privileged control service
* broad dependency additions
* enterprise orchestration

unless a confirmed current defect cannot reasonably be fixed with the existing shell and systemd architecture.

For ordinary findings, prefer narrow changes to:

```text
lib/operations.sh
existing common helpers
specific workflow scripts
existing systemd units
existing shell tests
operator documentation
```

---

## Current operation-guard architecture to reconstruct

Do not merely read this section and assume the implementation is correct.

Use it as a starting hypothesis that must be checked against current code.

The shared operation library is:

```text
lib/operations.sh
```

Important current concepts include:

```text
VW_OPERATIONS_LOCK
VW_OPERATIONS_STATE_DIR

operation_acquire
operation_set_phase
operation_release
operation_conflict_prompt
operation_package_run
operation_list
```

Important internal behavior includes:

```text
_operation_validate_inherited_global
_operation_find_state_for_lock
_operation_verify_owner
_operation_pid_start
_operation_lock_is_held
_operation_stop_scope
_operation_request_stop
_operation_force_stop
_operation_capture_descendant_identities
_operation_identity_is_live
_operation_has_package_manager_child
_operation_output_is_package_lock_error
```

The canonical global operation lock is expected to be:

```text
/run/lock/vaultwarden-operations.lock
```

Runtime operation metadata is expected under:

```text
/run/vaultwarden-oci/operations
```

The kernel `flock` is authoritative for active ownership.

Lock-file existence alone must not be interpreted as proof that an operation is active.

Operation metadata is descriptive and used for verified operator interaction.

Current metadata concepts include:

```text
owner
operation
label
state
pid
pid_start
script
started
started_epoch
phase
phase_name
lock_path
specific_lock
token
completed
result
```

The audit must independently determine whether those concepts are applied safely.

---

## Mandatory pre-finding work

Do not write a finding until the following work has been substantially completed.

### 1. Build a complete repository inventory

Inventory the repository.

At minimum, inspect:

```bash
find . -type f -not -path './.git/*' | sort
```

Classify relevant files into:

```text
top-level operator entry points
Makefile targets
shared shell libraries
setup and bootstrap workflows
storage workflows
backup workflows
restore and recovery workflows
maintenance workflows
update workflows
security workflows
secret and key workflows
permission workflows
uninstall/destructive workflows
systemd services
systemd timers
notification/failure handling
tests
documentation
generated documentation
CI/workflows
```

Do not limit inspection to files changed by PR #224.

A primary purpose of this audit is finding files PR #224 may have missed.

### 2. Build the mutating-workflow inventory

Identify every script or Make target capable of changing:

* packages
* systemd configuration or state
* Docker/Compose state
* Vaultwarden state
* SQLite state
* backup state
* storage mounts or filesystems
* persistent state directories
* secrets
* Age keys
* SOPS recipient policy
* CrowdSec state
* firewall rules
* Cloudflare DNS or security integration
* permissions or ownership
* host configuration
* generated configuration
* install state
* recovery state

For every mutating workflow, record internally:

```text
workflow
operator-visible entry point(s)
direct script path
systemd path
parent workflow callers
nested child workflows
requires global guard?
requires operation-specific guard?
operation id
interactive or non-interactive
expected contention behavior
service stop/start behavior
important destructive phase
package-manager use
success/failure reporting path
```

This matrix is required audit work even if the full raw matrix is not reproduced in the final report.

### 3. Build the supported-entry-point map

Inspect behavior through:

```text
make target
direct script invocation
systemd service
systemd timer
parent script
nested child script
setup workflow
restore workflow
recovery workflow
```

Determine which paths are supported by current documentation and help output.

Do not demand equivalence for unsupported private invocation patterns.

For supported paths, ask:

```text
Does the same underlying operation receive the same safety contract?
```

A finding may exist when supported entry-point choice changes:

* guard ownership
* contention handling
* privilege behavior
* timeout behavior
* interaction requirements
* exit status
* service restart behavior
* final verification
* operation metadata
* failure notification behavior

without an intentional reason.

### 4. Build the call graph

Follow real calls.

Search broadly for:

```bash
grep -RIn --exclude-dir=.git \
  -E '(^|[[:space:]])(\./)?(setup|startup|backup|restore|recover|maintenance|edit-secrets)\.sh|utilities/[A-Za-z0-9._/-]+\.sh' \
  .

grep -RIn --exclude-dir=.git \
  -E 'operation_acquire|operation_set_phase|operation_release|operation_package_run|VW_OPERATION_' \
  .

grep -RIn --exclude-dir=.git \
  -E 'systemctl|docker compose|apt-get|apt |dpkg|mkfs|mount|umount|rsync|sqlite3|sops|age-key|ufw|iptables|nft|cscli|curl' \
  -- '*.sh' Makefile systemd 2>/dev/null
```

Use more precise searches as needed.

Do not infer nesting solely from filenames.

Trace actual branches and argument combinations.

### 5. Reconstruct the operation contract

Before findings, write a concise internal contract for:

```text
global acquisition
specific-lock acquisition
nested acquisition
inherited global lock validation
metadata ownership
metadata update
phase ownership
normal release
failure release
EXIT trap behavior
TERM behavior
INT behavior
child process behavior
package-manager behavior
interactive contention
non-interactive contention
systemd contention
status inspection
controlled stop
force stop
stale metadata
unverifiable owner metadata
```

Then audit current workflows against the reconstructed contract.

---

## Primary audit question 1 — Was every meaningful mutating workflow classified correctly?

Do not assume every mutating script needs the global operation lock.

Do not assume serialization is always safer.

For each mutating workflow determine whether:

```text
A. it must be globally exclusive
B. it may safely nest under a globally guarded parent
C. it requires a narrower specific lock
D. it is intentionally independent
E. it is a cooldown/de-duplication path rather than a mutating operation
F. it is read-only
```

Challenge both directions.

### Under-guarding

Look for realistic paths where two operations can overlap and interfere through:

* package management
* service lifecycle
* Docker lifecycle
* config rendering
* secrets staging
* backup source mutation
* restore promotion
* storage movement
* permissions repair
* firewall mutation
* CrowdSec mutation
* key rotation
* SOPS policy changes
* uninstall
* recovery

### Over-guarding

Also look for operations unnecessarily placed behind the global lock when doing so creates a practical safety problem.

Examples:

* a health observation path blocked for the full duration of an unrelated operation
* an operator unable to inspect critical read-only state during recovery
* failure notification requiring a lock held by the failed operation
* status tooling accidentally acquiring the lock it is trying to inspect

Only raise over-guarding when the effect is practically harmful.

Do not raise a finding merely because more parallelism is theoretically possible.

---

## Primary audit question 2 — Are nested workflows and inherited locks correct?

This is a major audit theme.

Trace all parent/child workflow combinations.

Potential parent families include:

```text
setup
maintenance
update
restore
recover
storage setup
storage migration
health repair
key rotation
uninstall
```

For each real nested call, determine:

1. Which process originally acquired the global lock?
2. Which file descriptor owns or references the flock?
3. Is the descriptor inherited by the child?
4. Are `VW_OPERATION_INHERITED_FD`, `VW_OPERATION_PARENT_STATE`, and `VW_OPERATION_PARENT_TOKEN` present?
5. Does the child validate the inherited descriptor against the canonical lock path?
6. Does the child validate parent state and token?
7. Does the child reuse parent metadata or create its own metadata?
8. Can the child overwrite the parent phase?
9. Is that phase replacement intentional?
10. Can a child call `operation_release` and release shared protection it does not own?
11. What happens when the parent exits unexpectedly while a child still holds the inherited descriptor?
12. What happens if the parent state changes from `running` while an already-started child continues?
13. Can nested behavior differ when the child is called directly?
14. Can a shell, `sudo`, `env`, process substitution, pipeline, command substitution, or wrapper close or alter the inherited descriptor?
15. Do background processes inherit the operation lock unintentionally?
16. Can a long-lived daemon or unrelated process accidentally keep the global lock alive?

Do not treat these as theoretical questions.

Trace real current calls.

A finding requires a realistic repository execution path.

---

## Primary audit question 3 — Is lock lifetime equal to mutation lifetime?

This is a central correctness contract.

For every guarded workflow ask:

```text
When does mutation begin?
When is the lock acquired?
When does the last operation-owned mutation end?
When is the lock actually released?
```

Look for:

```text
acquire after mutation already started
release before child completion
release before service reconciliation
release before config promotion
release before verification
release while background process still mutates state
EXIT trap releasing after wrapper failure while child survives
subshell FD inheritance extending lock unexpectedly
daemonized process retaining the FD
specific lock released before duplicate-sensitive work ends
```

The operation guard does not need to cover read-only post-operation presentation unless concurrent mutation would make the result unsafe.

Do not demand excessively broad lock duration.

The important requirement is:

```text
the shared guard must cover the real conflicting mutation scope
```

---

## Primary audit question 4 — Are operation IDs and metadata semantics truthful?

Inventory all `operation_acquire` call sites.

Check:

* operation ID uniqueness
* operation ID stability
* label accuracy
* state-file naming collisions
* direct versus nested invocation
* phase updates
* final state
* result code
* completion timestamp
* script identity
* stale metadata handling

Challenge same-ID behavior.

For example, ask whether two semantically distinct workflows use the same operation ID in a way that:

* overwrites state unexpectedly
* hides useful interrupted-state information
* causes `make operations` to misrepresent what happened
* creates misleading phase output

Also challenge different-ID behavior.

Ask whether the same logical operation uses multiple IDs depending on entry point, producing confusing or unsafe status.

Metadata is not required to be a permanent audit log.

Do not demand history retention.

The requirement is truthful current/interrupted operation guidance.

---

## Primary audit question 5 — Are owner and PID identity checks safe?

Inspect:

```text
_operation_pid_start
_operation_verify_owner
_operation_pid_identity
_operation_identity_is_live
```

Challenge:

* PID reuse
* malformed `/proc/<pid>/stat`
* process names containing unusual characters
* kernel differences relevant to supported Ubuntu
* process disappearance between checks
* TOCTOU windows before signalling
* re-verification before force termination
* identity capture of descendants
* descendants created after the initial capture
* reparenting
* double-fork behavior
* shell wrappers
* pipelines
* `sudo`
* `tee`
* package-manager subprocesses

A theoretical race is not automatically a finding.

Demonstrate a realistic repository process tree and practical consequence.

Do not require perfect adversarial process supervision from shell.

The attacker model is not an untrusted root process deliberately forging `/proc` state.

Prioritize accidental misidentification and unsafe operator signalling.

---

## Primary audit question 6 — Are controlled stop and force-stop scopes correct?

Inspect the real stop algorithm and process trees created by guarded workflows.

Trace:

```text
descendant discovery
identity capture
TERM ordering
wait behavior
KILL ordering
wrapper termination
lock-clear verification
package-manager exclusion
remaining-child verification
```

Ask:

* Does the code signal the correct scope?
* Can it miss an operation-owned child that matters?
* Can it include an unrelated process?
* Is child-before-wrapper ordering appropriate for current workflows?
* Can a child spawn another mutating child after descendant identities are captured?
* Can the wrapper continue and create new children while its existing descendants receive TERM?
* Does the wrapper have traps that respond predictably to TERM?
* Can a shell trap invoke `operation_release` before a child actually stops?
* Does force-stop truthfully verify that the mutation scope ended?
* Can lock clear while a surviving mutation continues?
* Can a non-package workflow indirectly own active apt/dpkg work that is missed by package-child detection?
* Can package-manager detection falsely block stop because of a short-lived or unrelated descendant?

Do not recommend `systemd-run`, cgroups, or a process supervisor merely for architectural elegance.

If the current shell implementation has a confirmed gap, first propose the narrowest repair compatible with existing architecture.

---

## Primary audit question 7 — Are interruption and signal semantics correct?

Inspect guarded scripts for:

```bash
trap
EXIT
TERM
INT
HUP
ERR
wait
background jobs
pipelines
subshells
```

Trace realistic interruption during important phases.

At minimum consider:

```text
SSH disconnect
terminal closes
SIGTERM
SIGINT
systemd stop
systemd timeout
script error under set -e
explicit exit
command failure inside if
command failure inside ! condition
pipeline failure
child ignores TERM
parent dies unexpectedly
```

Do not assume SSH disconnect automatically kills every command.

Inspect how the actual scripts are launched.

For each important workflow determine whether interruption can leave:

* partial state
* accurate interrupted metadata
* stale `running` metadata
* a lock still legitimately held by a child
* a lock released while mutation continues
* services stopped
* partially promoted restore state
* partially changed firewall/CrowdSec state
* incomplete package configuration

Partial state is not automatically a defect.

The report should distinguish:

```text
expected resumable/reconcilable interruption
        from
unsafe or misleading interruption semantics
```

---

## Primary audit question 8 — Is package-manager handling consistently safe?

Inventory every supported use of:

```text
apt
apt-get
dpkg
unattended-upgrade
package install/update paths
```

Search the entire repository, not only PR #224 files.

Determine whether each active package-manager path:

* is within the intended operation scope
* uses `operation_package_run` where appropriate
* preserves the command's real exit status
* retries only confirmed lock contention
* does not kill apt/dpkg
* does not delete apt/dpkg lock files
* does not convert non-lock failures into retries
* does not hide output needed for diagnosis
* behaves correctly with `set -e`
* behaves correctly in a pipeline using `tee`
* restores the caller's errexit state
* does not leak temporary files containing unexpectedly sensitive output
* removes temporary output files on all ordinary paths

Review the lock-error classifier against realistic Ubuntu apt/dpkg output.

Do not demand recognition of every hypothetical localized error message.

Raise a gap only when a plausible supported production path can be mishandled.

Inspect whether any direct package commands remain outside the helper for a justified reason.

---

## Primary audit question 9 — Do systemd semantics match script semantics?

Inventory all files under:

```text
systemd/
```

For every service and timer, map:

```text
ExecStart
user/root identity
environment
working directory
timeout
KillMode
success exit statuses
restart policy
failure notification
timer overlap behavior
writable paths
runtime directories
```

Pay special attention to guarded services.

Challenge:

### Exit 75

Expected non-interactive contention may return:

```text
75
```

For every path intended to skip on contention, verify:

* the script actually requests non-interactive `skip` policy
* the script propagates 75 rather than converting it to 1 or 0
* wrapper functions do not swallow 75
* `set -e` does not alter intended handling
* the systemd unit treats 75 as expected where intended
* expected skip does not trigger false failure notification
* a real non-contention failure cannot accidentally become 75

### Timeouts and stopping

Ask:

* Can systemd terminate the wrapper while operation children continue?
* Does current `KillMode` match the operation stop architecture?
* Can a service timeout during legitimate apt/dpkg waiting?
* Does a systemd stop path conflict with the library's refusal to kill package-manager activity?
* Can systemd itself kill apt/dpkg even though the interactive operation library promises not to do so?
* Is the promise specifically about the guarded interactive stop helper, or does documentation imply a broader guarantee?

Report the actual contract accurately.

### Writable paths and hardening

Verify guarded services can actually write:

```text
/run/lock
/run/vaultwarden-oci/operations
```

and any other required runtime paths under current hardening directives.

Do not request hardening directives merely for checklist completeness.

---

## Primary audit question 10 — Are all entry points semantically consistent?

For every high-risk workflow compare:

```text
sudo make <target>
sudo ./script.sh ...
systemd service
parent workflow
nested child workflow
```

where those are supported current paths.

Challenge differences in:

* root checks
* environment loading
* state directory resolution
* operation guard acquisition
* non-interactive mode
* confirmation prompts
* backup prerequisites
* stop/start choices
* final health checks
* operation release
* exit code
* notification

A Make target may intentionally provide additional presentation.

That is not a finding.

A direct script may intentionally be internal.

That is not a finding when documentation and code consistently treat it as internal.

Raise findings for real supported-path safety or semantic divergence.

---

## Primary audit question 11 — Are destructive and recovery workflows protected throughout?

Perform deeper traces for:

```text
restore
recover
storage setup
storage migration
Age key rotation
secrets setup/rekey
emergency backup
uninstall
permission repair
CrowdSec force reset
firewall changes
database maintenance
managed update
```

For each ask:

```text
What is the point of no return?
What state must not be concurrently changed?
Is the guard held before that point?
What nested operation runs?
What happens on failure?
What happens on interrupt?
What does the final message claim?
Can the operator safely rerun?
Does --force change guard behavior?
```

`--force` must not silently become a concurrency bypass unless the repository explicitly documents an extraordinary break-glass contract.

Search for:

```text
--force
skip lock
skip ops
SKIP_OPS
flock
rm *lock*
unlink *lock*
```

Challenge all current bypass-like behavior.

Do not assume the presence of the word `force` is a defect.

Trace semantics.

---

## Primary audit question 12 — Are retained direct locks still justified and correctly composed?

PR #224 intentionally retained some narrower locks.

Current examples may include:

```text
migration duplicate-copy protection
break-glass account mutation
notification cooldown/de-duplication
health alert/recovery cooldown
xtables coordination
```

Find all direct `flock` use in the current repository.

For every direct lock classify it.

Ask:

* Is this truly independent of the global operation guard?
* Is it a resource lock, cooldown lock, or operation lock?
* Is lock ordering consistent?
* Can global-lock → specific-lock and specific-lock → global-lock paths create deadlock?
* Can two paths acquire the same set of locks in opposite order?
* Can a narrow lock survive longer than expected through FD inheritance?
* Does stale-lock deletion guidance remain?
* Does any script treat lock-file existence as active ownership?

Do not force all locks into `lib/operations.sh`.

A separate lock is valid when it protects a genuinely separate contract.

---

## Primary audit question 13 — Is `make operations` truthful and operationally useful?

Inspect:

```text
utilities/operations-status.sh
operation_list
_operation_list_one
_operation_find_state_for_lock
_operation_describe_state
```

Challenge:

* known operation ID inventory
* dynamic unknown IDs
* stale state
* interrupted state
* complete state shown as idle
* failed state
* elapsed time after completion
* current process verification
* active global lock with no verifiable metadata
* multiple stale `running` files
* one active operation plus stale files
* parent metadata reused by nested children
* nested phase updates
* specific-lock-only operations
* no-global operations
* missing state file
* malformed state file

The status command is a local operator tool, not an audit-history UI.

Do not demand historical dashboards.

Ask whether a junior operator can use its current output to make the safe next decision after an SSH disconnect.

---

## Primary audit question 14 — Are final states and success messages truthful?

This remains a repository-wide audit theme.

Trace important final messages.

Challenge execution paths resembling:

```text
partial failure
    ->
cleanup or fallback
    ->
success-looking summary
```

Distinguish:

```text
created
installed
configured
promoted
started
running
healthy
verified
synced
protected
restorable
complete
```

Examples to challenge:

* operation state records `complete` despite a meaningful nested failure
* operation state records `failed` but operator output claims completion
* backup archive exists but verification failed
* offsite sync failed but protection is described as complete
* service started but health was not established
* restore promoted state but startup failed
* recovery rekeyed secrets but final validation failed
* firewall config was written but enforcement failed
* CrowdSec package installed but bouncer configuration failed
* maintenance skipped a requested phase but reports complete maintenance
* system update failed but later cleanup masks the exit code
* failure notification failed but operator is told notification succeeded

Trace the variable and return code establishing every important success claim.

---

## Primary audit question 15 — Do tests protect behavior strongly enough?

Review the complete `tests/` tree.

Pay special attention to:

```text
tests/test-operation-guards.sh
tests/test-privilege-contracts.sh
tests/test-backup-restore-behavior.sh
tests/test-start-policy.sh
tests/test-operator-ui.sh
tests/test-crowdsec-config.sh
```

Do not dismiss source-pattern tests.

They are useful for architecture policy.

But distinguish:

```text
source contract test
        from
behavioral regression test
```

Ask whether important behavior can regress while current tests remain green.

Current operation tests include a mix of shell harness behavior and source assertions.

Challenge gaps around:

* real nested lock inheritance
* descriptor closure
* parent death
* surviving child mutation
* late-spawned descendants
* stop races
* specific-lock composition
* systemd exit-code propagation
* operation ID collisions
* metadata corruption
* `set -e` behavior
* package helper caller errexit state
* pipeline behavior
* direct-script versus Make paths
* real operation call graphs

Do not require full OCI, Cloudflare, Docker, or destructive end-to-end infrastructure tests for every contract.

Recommend focused shell harnesses when practical.

A test-gap finding belongs in the main Findings section only when:

1. meaningful current behavior is insufficiently protected, and
2. there is either a demonstrated defect or an unusually fragile critical contract with a realistic regression path.

Do not create findings merely to increase test coverage percentages.

---

## Primary audit question 16 — Did documentation and generated references drift from executable behavior?

Inspect:

```text
README.md
docs/
Makefile help
script --help output
utilities/write-command-reference.sh
generated command references
recovery card
troubleshooting guidance
operations documentation
CrowdSec documentation
```

Search for obsolete advice such as:

```text
delete the lock file
remove the lock
use --force to bypass
use --skip-ops-lock
wait indefinitely
rerun with --force
```

Trace all documented commands to current behavior.

Prioritize incorrect instructions that can lead a junior operator to:

* interrupt a valid operation
* bypass a safety gate
* misinterpret contention
* assume a stale lock file is active
* think a failed operation completed
* restart services too early during DR
* mishandle Age keys
* damage package-manager state

Do not raise cosmetic wording findings.

Generated documentation drift should identify the source-of-truth generator when applicable.

---

## Required whole-repository searches

Use appropriate variants of the following.

These are starting points, not the complete audit.

### Operation architecture

```bash
grep -RIn --exclude-dir=.git \
  -E 'operation_acquire|operation_set_phase|operation_release|operation_package_run|operation_list|VW_OPERATION_|VW_OPERATIONS_' \
  .
```

### All locks

```bash
grep -RIn --exclude-dir=.git \
  -E 'flock|/run/lock|lockfile|lock file|LOCK_FILE|LOCK_PATH|\.lock' \
  .
```

### Bypass and force semantics

```bash
grep -RIn --exclude-dir=.git \
  -E -- '--force|skip[-_ ]?(ops|operation|lock)|SKIP.*LOCK|FORCE.*LOCK|rm .*lock|unlink .*lock' \
  .
```

### Package management

```bash
grep -RIn --exclude-dir=.git \
  -E 'apt-get|(^|[^[:alnum:]_])apt([^[:alnum:]_]|$)|dpkg|unattended-upgr' \
  .
```

### Signals and background behavior

```bash
grep -RIn --exclude-dir=.git \
  -E 'trap |SIGTERM|TERM|SIGINT|INT|SIGHUP|HUP|wait|\&$|nohup|setsid|disown' \
  -- '*.sh' systemd Makefile 2>/dev/null
```

### Systemd contention and failure semantics

```bash
grep -RIn --exclude-dir=.git \
  -E 'SuccessExitStatus|ExecStart|ExecCondition|OnFailure|Timeout|KillMode|Restart=|RuntimeDirectory|ReadWritePaths|ProtectSystem' \
  systemd
```

### Mutating commands

```bash
grep -RIn --exclude-dir=.git \
  -E 'systemctl|docker compose|apt-get|dpkg|mkfs|mount|umount|rsync|sqlite3|sops|age|ufw|iptables|nft|cscli|install -|chmod|chown|mv |rm |cp |curl ' \
  -- '*.sh' Makefile 2>/dev/null
```

### Operator success-state language

```bash
grep -RIn --exclude-dir=.git \
  -Ei 'success|successful|complete|completed|healthy|verified|restorable|synced|protected|configured|running|finished' \
  -- '*.sh' Makefile docs README.md 2>/dev/null
```

Review results contextually.

Do not turn grep output directly into findings.

---

## Finding threshold

Be skeptical.

Do not manufacture findings.

A clean review is acceptable.

A confirmed finding should normally contain:

1. Exact file and function, target, or unit
2. Exact supported execution path
3. Current behavior
4. Contract being violated
5. Code evidence
6. Realistic trigger
7. Practical consequence for this project
8. Explanation of why existing tests do not prevent or expose the issue
9. Narrow remediation
10. Practical suggested patch or pseudodiff
11. Focused regression-test suggestion
12. Confidence rating

A finding must be:

```text
reproducible
or
directly traceable through current code
or
supported by a focused shell harness demonstrating the behavior
```

Do not raise findings for:

* visual inconsistency alone
* wording preference
* script length
* duplication alone
* lack of abstraction
* functions being "too large"
* use of Bash
* lack of Python
* lack of structured metadata formats
* lack of persistent operation history
* theoretical unsupported operating systems
* macOS-only test limitations when Ubuntu behavior is unaffected
* enterprise-grade orchestration gaps
* hypothetical malicious root processes
* a race with no realistic current workflow trigger
* source-pattern tests merely being source-pattern tests
* serialization that is conservative but harmless for this 10-user deployment
* accepted downtime of a few hours
* style-only ShellCheck observations

---

## Severity scale

### Critical

A realistic current path to:

* data loss
* secret or private-key exposure
* unrecoverable restore or DR failure
* loss of required recovery material
* unsafe concurrent destructive mutation with severe consequences
* broad production outage that a normal supported workflow can trigger

### High

A concrete security, backup, restore, recovery, destructive-operation, or operation-guard correctness defect that should be corrected before treating `delta` as production-ready.

Examples may include:

* guard released while a real mutating child continues
* supported mutating workflow entirely missing required coordination
* force-stop can realistically signal unrelated processes
* real package-manager workflow can be automatically terminated despite the stated safety contract
* systemd converts real failures into expected contention
* restore/recovery final state is materially misleading

### Medium

A real operator-safety, reliability, concurrency, interruption, semantic, or meaningful regression-protection defect worth correcting soon.

The impact must be practical for this project.

### Low

Minor but worthwhile correctness or operator-safety improvement.

Include only unusually useful Low items.

Do not flood the report with polish.

### Note

Observation, design tradeoff, or runtime validation limitation.

Not a required fix.

---

## Confidence scale

For every finding use:

```text
High
Medium
Low
```

### High confidence

Current code directly demonstrates the execution path, or a focused harness reproduces it.

### Medium confidence

The path is strongly traceable but depends on a runtime detail that could not be reproduced in the audit environment.

### Low confidence

The concern requires production validation.

Low-confidence concerns normally belong under runtime validation limits or targeted observations, not as major findings.

Do not use dramatic severity with weak confidence without clearly explaining the uncertainty.

---

## Mandatory remediation guidance

Every Critical, High, or Medium finding must include a practical proposed repair.

Do not merely say:

```text
improve locking
handle the error
fix the race
add validation
use best practices
add a test
refactor this
```

Use:

````markdown
### Suggested remediation

**Target**

`path/to/file` — `function_name`

**Suggested change**

Describe the narrow behavioral change.

**Why this is minimal**

Explain why this repairs the demonstrated contract violation without changing unrelated architecture.

**Suggested patch**

```diff
@@
- current behavior
+ narrow proposed behavior
````

**Suggested regression test**

```bash
test_descriptive_contract_name() {
    ...
}
```

**Validation**

```bash
focused-test-or-command
```

````

Use real current:

- function names
- variables
- operation IDs
- scripts
- unit names

when known.

The pseudodiff does not need to apply byte-for-byte.

It must be concrete enough for a coding agent to implement without reinterpreting the finding.

Do not apply the patch.

For Low findings, a patch is optional.

For runtime-validation limits, provide a targeted validation approach instead of pretending a code defect is confirmed.

---

## Review strategy

Use this order.

### Phase 1 — Establish exact current state

Run:

```bash
git status --short
git branch --show-current
git rev-parse HEAD
git log --oneline --decorate -30
````

Confirm current `delta`.

Record the SHA.

### Phase 2 — Read project context and prior reports

Read:

```text
README.md
AGENTS.md
reports/
docs/OPERATIONS.md
docs/TROUBLESHOOTING.md
docs/COMMAND-REFERENCE.md
docs/SCRIPTS.md
docs/CROWDSEC.md
```

Inspect relevant git history, particularly PR #224.

Do not write findings yet.

### Phase 3 — Complete repository inventory

Inventory every file.

Classify entry points and mutating workflows.

Identify files not touched by PR #224 that can still perform overlapping state mutation.

### Phase 4 — Build operation and lock matrices

Build the internal workflow matrix and direct-lock inventory.

Map every `operation_acquire` call.

Map every direct `flock`.

Map all package-manager calls.

Map all systemd service/timer entry points.

### Phase 5 — Build call graph and nested-workflow graph

Trace real shell calls and Make target calls.

Identify parent/child operations.

Trace inherited operation state and FDs.

### Phase 6 — Audit the shared library itself

Inspect `lib/operations.sh` line by line in context.

Challenge:

```text
lock acquisition
specific lock ordering
metadata
PID identity
descendant discovery
stop behavior
package detection
interactive contention
non-interactive contention
inherited validation
phase writes
release
status
package retry
```

### Phase 7 — Audit every mutating workflow against the contract

This is a full repository pass.

Do not stop after reviewing the 42 files changed in PR #224.

Explicitly inspect files that were not modified by PR #224.

### Phase 8 — Deep trace high-risk workflows

Perform deeper end-to-end code traces for:

```text
setup
backup
full backup
emergency backup
restore
recover
storage setup
storage migration
maintenance
managed update
system package update
CrowdSec setup
firewall setup/update
DNS update
health repair
Age key rotation
secrets setup/rekey
permission repair
uninstall
database maintenance
```

### Phase 9 — Audit systemd semantics

Map script exit behavior to service interpretation.

Challenge contention, stopping, timeouts, and failure notification.

### Phase 10 — Audit tests

Map important contracts to tests.

Use focused harnesses where safe.

Do not alter tests.

### Phase 11 — Audit operator guidance

Compare current executable behavior to docs and generated references.

Focus only on consequential drift.

### Phase 12 — Challenge candidate findings

Before including each finding, ask:

```text
Is this current?
Is the path supported?
Can I trace the trigger?
Is there practical impact?
Is the repository contract actually violated?
Is another existing safeguard already sufficient?
Am I proposing enterprise complexity for a small deployment?
Can I show a narrower repair?
```

Discard weak findings.

### Phase 13 — Write one report

Create:

```text
reports/post-pr224-repository-wide-contract-audit.md
```

Do not modify functional files.

---

## Validation expectations

Use non-destructive validation appropriate to a report-only audit.

At minimum run:

```bash
git status --short
git branch --show-current
git rev-parse HEAD
```

Run Bash syntax checks:

```bash
find . -type f -name '*.sh' -not -path './.git/*' -print0 \
  | xargs -0 bash -n
```

Run focused tests relevant to the contracts being audited.

At minimum attempt, when the environment supports them:

```bash
tests/test-operation-guards.sh
tests/test-privilege-contracts.sh
tests/test-backup-restore-behavior.sh
tests/test-start-policy.sh
tests/test-operator-ui.sh
tests/test-crowdsec-config.sh
```

Run:

```bash
make test-unit
```

when the environment supports it and the test suite is non-destructive in the current environment.

Run focused ShellCheck when installed.

A broad read-only ShellCheck pass is acceptable:

```bash
find . -type f -name '*.sh' -not -path './.git/*' -print0 \
  | xargs -0 shellcheck -x --severity=warning
```

Do not perform a broad `shfmt` rewrite.

Do not fix lint findings.

Do not run real destructive workflows against the host.

Do not run:

```text
setup
restore
recover
uninstall
storage formatting
storage migration against real devices
firewall mutation
CrowdSec reset
key rotation against real secrets
host package upgrade
```

merely to increase audit confidence.

Prefer temporary directories, mocked commands, shell harnesses, and existing tests.

If a command cannot run because:

* Docker is unavailable
* the environment is not Ubuntu
* `/proc` behavior differs
* real util-linux `flock` is unavailable
* sudo/root is unavailable
* systemd is unavailable
* OCI is unavailable
* Cloudflare access is unavailable
* required dependency is missing

record the limitation precisely.

Do not convert an environment limitation into a confirmed finding.

---

## Required report structure

Create exactly:

```text
reports/post-pr224-repository-wide-contract-audit.md
```

Use this structure:

````markdown
# Post-PR #224 Repository-Wide Contract Audit

## Executive Summary

## Audit Baseline

## Scope and Method

## Architecture Reconstructed from Current Code

### Operation Ownership and Concurrency Contract

### Nested Workflow and Inherited Lock Contract

### Interruption and Stop Contract

### Package-Manager Contract

### Systemd Contention Contract

### Operator Status Contract

## Repository-Wide Coverage

### Entry Points Reviewed

### Mutating Workflows Reviewed

### Direct Locks Reviewed

### Systemd Services and Timers Reviewed

### High-Risk Workflow Traces

## Findings

### F-01: ...

**Severity:**  
**Confidence:**  
**Affected path:**  
**Execution path:**  
**Contract violated:**

#### Current behavior

#### Evidence

#### Realistic trigger

#### Operator or production impact

#### Why existing safeguards are insufficient

#### Why existing tests did not prevent or expose this

### Suggested remediation

**Target**

**Suggested change**

**Why this is minimal**

**Suggested patch**

```diff
...
````

**Suggested regression test**

```bash
...
```

**Validation**

```bash
...
```

## Low-Severity Opportunities

## Rejected Candidate Findings

## Runtime Validation Limits

## Tests and Commands Run

## Final Assessment

````

---

## Rejected candidate findings

Include a concise section:

```text
## Rejected Candidate Findings
````

This section is important for a broad audit.

Record only meaningful candidates that received serious investigation but were rejected.

For each, briefly state:

```text
Candidate concern
Why it initially looked risky
Why current code or project scope makes it non-finding
```

Examples of useful rejected candidates:

* retained direct lock is intentionally a cooldown lock
* conservative global serialization is harmless for this deployment
* metadata is not historical by design
* nested child phase replacement is intentional and truthful
* an internal script is not a supported direct operator path
* a source-pattern test appropriately enforces architecture policy

Do not turn this into a diary of every search.

The purpose is to demonstrate that the audit challenged the architecture without padding the Findings section.

---

## Final assessment requirements

The report must directly answer:

1. Is the shared operation-guard architecture internally coherent in current `delta`?
2. Did PR #224 miss any mutating supported workflow that requires the global or a narrower operation guard?
3. Is any workflow guarded too narrowly, with lock lifetime shorter than actual mutation lifetime?
4. Can a nested workflow incorrectly acquire, inherit, update, or release operation state?
5. Can a parent terminate or release while an operation-owned mutating child continues?
6. Can controlled stop or force-stop realistically signal the wrong process or miss a relevant operation-owned process?
7. Is apt/dpkg activity consistently protected from unsafe automated termination?
8. Are all package-manager paths using appropriate output-aware retry semantics?
9. Do systemd services correctly distinguish expected contention exit 75 from real failure?
10. Can systemd stop or timeout semantics undermine the operation library's safety behavior?
11. Does `sudo make operations` truthfully guide an operator after an interruption or SSH disconnect?
12. Do supported Make, direct-script, systemd, parent, restore, and recovery entry points provide consistent safety?
13. Are final success and failure states truthful?
14. Are existing tests protecting the important runtime contracts?
15. Did the complete repository review identify any additional Critical, High, or Medium gaps?
16. What exact findings should be handed to a coding agent for one focused follow-up PR?

End with exactly one overall recommendation:

```text
NO FOLLOW-UP REQUIRED
```

or:

```text
TARGETED FOLLOW-UP PR RECOMMENDED
```

or:

```text
BLOCK PRODUCTION-READY STATUS
```

For:

```text
TARGETED FOLLOW-UP PR RECOMMENDED
```

list only the finding IDs recommended for implementation.

For:

```text
BLOCK PRODUCTION-READY STATUS
```

identify the blocking finding IDs.

Do not say the repository is fully bug-free.

Assess the contracts and repository state actually reviewed.

---

## Final agent rule

Depth is more important than finding count.

Do not stop because the obvious PR #224 files look correct.

Do not stop after tests pass.

Do not stop after auditing `lib/operations.sh`.

The core purpose of this session is to find the forgotten execution path, mismatched caller, nested workflow, retained lock, direct package command, systemd semantic mismatch, interruption edge, or stale operator instruction that a large repo-wide architectural change can miss.

At the same time:

Do not invent problems.

Trace the repository completely.

Challenge the architecture aggressively.

Report only evidence.
